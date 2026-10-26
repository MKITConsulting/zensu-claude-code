'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const packets = require('./review-packet-v1.js');
const principal = require('./claude-principal-v1.js');
const background = require('./background-review-v1.js');

const RECORD_SCHEMA = 'zensu-review-gate-record-v1';
const MAX_PAYLOAD_BYTES = 16 * 1024 * 1024;
const MAX_RECORD_BYTES = 64 * 1024;
const MAX_RECORDS = 400;
const PERSONA_RE = /^zensu-review-[A-Za-z0-9_-]+$/;
const PLUGIN_SCOPE = 'zensu:';
const REVIEWER_ROLES = new Map([['review-aspect', 'aspect'], ['review-judge', 'judge']]);
const RECORD_NAME_RE = /^record-r(\d+)-(\d+)-(\d+)-([0-9a-f]{12})\.json$/;
const PACKET_NAME_RE = /^packet-r(\d+)\.json$/;
const DELIVERY_STUB_RE = /^This agent's report was delivered to you as a message from /;
const PACKET_INVALID_RE = /^REVIEW PACKET INVALID\b/m;
const ROLES = Object.freeze(['aspect', 'persona', 'judge-primary', 'judge-second', 'consume']);
const PACKET_STATES = Object.freeze(['ok', 'absent', 'duplicate', 'unterminated']);
const LAUNCHED = 'async_launched';
const AGENT_ID_RE = background.AGENT_ID_RE;
const EVENTS = Object.freeze(['PostToolUse', 'UserPromptSubmit']);

class ReviewGateError extends Error {}

function fail(message) {
  throw new ReviewGateError(message);
}

function classify(type) {
  if (typeof type !== 'string') return null;
  if (type.startsWith(PLUGIN_SCOPE) && principal.REVIEWER_TYPES.has(type)) {
    return REVIEWER_ROLES.get(type.slice(PLUGIN_SCOPE.length)) || null;
  }
  return PERSONA_RE.test(type) ? 'persona' : null;
}

function lastLine(prompt) {
  const lines = String(prompt).replace(/\r\n?/g, '\n').split('\n').map((line) => line.trim()).filter(Boolean);
  return lines.length ? lines[lines.length - 1] : '';
}

function reportText(response) {
  if (!response || typeof response !== 'object' || Array.isArray(response)) return { text: '', source: 'none' };
  const handback = response.handbackReport;
  if (handback && typeof handback === 'object' && typeof handback.text === 'string' && handback.text.trim() !== '') {
    return { text: handback.text, source: 'handback' };
  }
  let text = '';
  if (typeof response.content === 'string') text = response.content;
  else if (Array.isArray(response.content)) {
    text = response.content.filter((block) => block && block.type === 'text' && typeof block.text === 'string')
      .map((block) => block.text).join('\n');
  }
  if (text.trim() === '' || DELIVERY_STUB_RE.test(text.trim())) return { text: '', source: 'none' };
  return { text, source: 'content' };
}

function launchedAgent(response) {
  if (!response || typeof response !== 'object' || response.status !== LAUNCHED) return null;
  return typeof response.agentId === 'string' && AGENT_ID_RE.test(response.agentId) ? response.agentId : null;
}

function clip(value, limit) {
  return String(value).replace(/[\x00-\x1f\x7f]/g, ' ').slice(0, limit);
}

function heading(text) {
  const match = /^## Aspect: (.+?)\s*$/m.exec(text);
  return match ? clip(match[1], 80) : null;
}

function judgeFailure(report, status) {
  if (status !== 'completed') return `the judge run ended with status ${clip(status || 'unknown', 40)}`;
  if (!report.text) return 'no judge report reached the hook';
  if (PACKET_INVALID_RE.test(report.text)) return 'the judge answered REVIEW PACKET INVALID';
  if (!/^## Aspect: judge\s*$/m.test(report.text)) return 'the report has no "## Aspect: judge" heading';
  if (!/^- \(no findings\)\s*$/m.test(report.text) && !/^- \[(?:CRITICAL|IMPORTANT|SUGGESTION)\] JUDGE-\d+\b/m.test(report.text)) {
    return 'the report lists neither a JUDGE finding nor "- (no findings)"';
  }
  return null;
}

function writeRecord(store, record) {
  const name = `record-r${record.round}-${record.at}-${process.pid}-${crypto.randomBytes(6).toString('hex')}.json`;
  packets.writeAtomic(path.join(store, name), JSON.stringify(record));
}

function readRecord(file) {
  const loaded = packets.readBounded(file, MAX_RECORD_BYTES);
  if (!loaded.bytes) return null;
  let record;
  try {
    record = JSON.parse(loaded.bytes.toString('utf8'));
  } catch {
    return null;
  }
  const valid = record && record.schema === RECORD_SCHEMA && Number.isSafeInteger(record.round) && record.round >= 0
    && Number.isSafeInteger(record.at) && ROLES.includes(record.role) && PACKET_STATES.includes(record.packet)
    && (record.packetSha === null || (typeof record.packetSha === 'string' && /^[0-9a-f]{64}$/.test(record.packetSha)))
    && (record.identity === null || typeof record.identity === 'string')
    && (record.valid === null || typeof record.valid === 'boolean')
    && (record.agentId === undefined || record.agentId === null || (typeof record.agentId === 'string' && AGENT_ID_RE.test(record.agentId)));
  return valid ? record : null;
}

function listStore(store) {
  let names;
  try {
    const stat = fs.lstatSync(store);
    if (stat.isSymbolicLink() || !stat.isDirectory()) fail('the review gate store is not a real directory');
    names = fs.readdirSync(store);
  } catch (error) {
    if (error.code === 'ENOENT') return { packetRounds: [], records: [], files: [] };
    if (error instanceof ReviewGateError) throw error;
    fail(`the review gate store cannot be read (${error.code || 'error'})`);
  }
  const packetRounds = [];
  const records = [];
  const files = [];
  for (const name of names.sort()) {
    const packet = PACKET_NAME_RE.exec(name);
    if (packet) {
      packetRounds.push(Number(packet[1]));
      continue;
    }
    if (!RECORD_NAME_RE.test(name)) continue;
    files.push(name);
    const record = readRecord(path.join(store, name));
    if (record) records.push(record);
  }
  records.sort((left, right) => left.at - right.at);
  return { packetRounds, records, files };
}

function prune(store) {
  const { files } = listStore(store);
  if (files.length <= MAX_RECORDS) return;
  const ordered = files.map((name) => ({ name, at: Number(RECORD_NAME_RE.exec(name)[2]) })).sort((left, right) => left.at - right.at);
  for (const entry of ordered.slice(0, ordered.length - MAX_RECORDS)) fs.rmSync(path.join(store, entry.name), { force: true });
}

function describe(record) {
  if (record.role === 'judge-primary') return 'primary zensu:review-judge';
  if (record.role === 'judge-second') return 'second zensu:review-judge run';
  const name = record.identity ? record.identity.slice(record.identity.indexOf(':') + 1) : '';
  return `${record.type || record.role} reviewer${name ? ` "${name}"` : ''}`;
}

function shellQuote(value) {
  const text = String(value);
  return /^[A-Za-z0-9_\/.,:=@%+-]+$/.test(text) ? text : `'${text.replace(/'/g, "'\\''")}'`;
}

function remedyCommands(root, session) {
  let key = String(session || '');
  try {
    key = require('./session-control-core-v1.js').sessionKey(session);
  } catch { }
  const base = (verb) => ['node', path.join(__dirname, 'review-packet-v1.js'), verb, '--root', root, '--session', key].map(shellQuote).join(' ');
  return {
    show: base('show'),
    create: `${base('create')} --input <a JSON file in ${path.join(root, ...packets.REVIEW_INPUT_SEGMENTS)} holding ${packets.INPUT_FIELDS.join(', ')}>`,
  };
}

function packetProblem(state) {
  if (state === 'absent') return 'no REVIEW PACKET v1 block';
  if (state === 'duplicate') return 'more than one REVIEW PACKET v1 block';
  return 'an unterminated REVIEW PACKET v1 block';
}

function primaryFailures(records, canonical) {
  return records.filter((entry) => entry.role === 'judge-primary' && entry.round === canonical.round
    && entry.at >= canonical.createdAt && entry.packet === 'ok' && entry.packetSha === canonical.sha256);
}

function recordObservation(options) {
  const payload = options.payload || {};
  const input = payload.tool_input && typeof payload.tool_input === 'object' ? payload.tool_input : {};
  const kind = classify(input.subagent_type);
  if (!kind) return { recorded: false };
  const root = packets.canonicalRoot(options.root);
  const state = packets.chainState(root, options.session);
  if (state.status !== 'ok' || !state.reviewable) return { recorded: false };
  const prompt = typeof input.prompt === 'string' ? input.prompt : '';
  const role = kind === 'judge' ? (lastLine(prompt) === 'judge_run: second' ? 'judge-second' : 'judge-primary') : kind;
  const packet = packets.extractPacket(prompt);
  const response = payload.tool_response;
  const status = response && typeof response === 'object' && typeof response.status === 'string' ? response.status : '';
  const launched = status === LAUNCHED;
  const report = launched ? { text: '', source: 'none' } : reportText(response);
  const name = heading(report.text);
  const reason = role === 'judge-primary' && !launched ? judgeFailure(report, status) : null;
  const store = packets.ensureStore(root, options.session);
  let canonical = null;
  try {
    canonical = packets.readPacketRecord(store, state.round);
  } catch (error) {
    if (!(error instanceof packets.ReviewPacketError)) throw error;
  }
  const record = {
    schema: RECORD_SCHEMA,
    round: state.round,
    at: (options.now || Date.now)(),
    type: clip(input.subagent_type, 80),
    role,
    identity: launched ? null : (role.startsWith('judge') ? role : (name ? `${kind}:${name}` : null)),
    packet: packet.status,
    packetSha: packet.sha256 || null,
    status: clip(status, 40),
    reportSource: report.source,
    valid: role === 'judge-primary' && !launched ? reason === null : null,
    reason,
    agentId: launchedAgent(response),
  };
  writeRecord(store, record);
  prune(store);
  return { recorded: true, record, canonical, packetText: packet.text || '', store, commands: remedyCommands(root, options.session) };
}

function recordHandback(options) {
  const payload = options.payload || {};
  const frames = background.handbackReports(payload.prompt);
  if (frames.length === 0) return [];
  const root = packets.canonicalRoot(options.root);
  const state = packets.chainState(root, options.session);
  if (state.status !== 'ok' || !state.reviewable) return [];
  const records = listStore(packets.storeDirectory(root, options.session)).records.filter((entry) => entry.round === state.round);
  const results = [];
  for (const frame of frames) {
    const runs = records.filter((entry) => entry.agentId === frame.agentId);
    const launch = runs.filter((entry) => entry.status === LAUNCHED && entry.role !== 'consume').pop();
    const kind = launch ? classify(launch.type) : null;
    if (!kind || runs.some((entry) => entry.status !== LAUNCHED)) continue;
    const report = { text: frame.report, source: 'handback-prompt' };
    const name = heading(report.text);
    const reason = launch.role === 'judge-primary' ? judgeFailure(report, 'completed') : null;
    const store = packets.ensureStore(root, options.session);
    let canonical = null;
    try {
      canonical = packets.readPacketRecord(store, state.round);
    } catch (error) {
      if (!(error instanceof packets.ReviewPacketError)) throw error;
    }
    const record = {
      schema: RECORD_SCHEMA,
      round: state.round,
      at: (options.now || Date.now)(),
      type: launch.type,
      role: launch.role,
      identity: launch.role.startsWith('judge') ? launch.role : (name ? `${kind}:${name}` : null),
      packet: launch.packet,
      packetSha: launch.packetSha,
      status: 'completed',
      reportSource: report.source,
      valid: launch.role === 'judge-primary' ? reason === null : null,
      reason,
      agentId: frame.agentId,
    };
    writeRecord(store, record);
    prune(store);
    records.push(record);
    results.push({ recorded: true, record, canonical, packetText: null, store, commands: remedyCommands(root, options.session) });
  }
  return results;
}

function observationAdvice(result) {
  if (!result.recorded) return '';
  const { record, canonical, commands } = result;
  const who = describe(record);
  const notes = [];
  if (!canonical) {
    notes.push(`REVIEW PACKET NOT CREATED — review round ${record.round} has no canonical packet, so this ${who} result cannot count toward the round. Run ${commands.create}, then spawn this round's reviewers with the block it prints, copied unchanged.`);
  } else if (record.packet !== 'ok') {
    notes.push(`REVIEW PACKET MISSING — the ${who} prompt carried ${packetProblem(record.packet)}. Do not merge its findings; spawn it again with the block ${commands.show} prints, copied unchanged.`);
  } else if (record.packetSha !== canonical.sha256) {
    const where = result.packetText === null ? '' : ` at packet line ${packets.firstDifference(canonical.text, result.packetText)}`;
    notes.push(`REVIEW PACKET MISMATCH — the ${who} prompt differs from review round ${record.round}'s canonical packet${where}. Do not merge its findings; spawn it again with the block ${commands.show} prints, copied unchanged.`);
  }
  if (record.role === 'judge-primary' && record.valid === false) {
    const failed = canonical ? primaryFailures(listStore(result.store).records, canonical).filter((entry) => entry.valid === false) : [];
    if (failed.length >= 2) {
      notes.push(`REVIEW INCOMPLETE — the primary judge failed twice on review round ${record.round}'s packet (${record.reason}). Stop the review chain here: keep both results, do not spawn the consume reviewer, and report the chain as pending.`);
    } else {
      notes.push(`PRIMARY JUDGE INCOMPLETE — ${record.reason}. Spawn the primary zensu:review-judge once more with the same canonical packet (on the import path after the step-3 panel its fallback runs); the second judge run never substitutes for it.`);
    }
  }
  return notes.join(' ');
}

function consumeRefusal(cause, next) {
  return { pass: false, message: `REVIEW INCOMPLETE — ${cause}. The review ticket was NOT consumed and the review chain did not advance. Next: ${next}.` };
}

function checkConsume(options) {
  const payload = options.payload || {};
  const arrival = options.event === 'UserPromptSubmit';
  const input = !arrival && payload.tool_input && typeof payload.tool_input === 'object' ? payload.tool_input : {};
  const prompt = typeof input.prompt === 'string' ? input.prompt : '';
  const agent = arrival ? options.agent : null;
  const root = packets.canonicalRoot(options.root);
  const state = packets.chainState(root, options.session);
  if (state.status !== 'ok') return { pass: false, hold: true, reason: `state-${state.status}` };
  if (!state.reviewable) return { pass: true, reason: 'not-reviewable' };
  if (options.ticket !== undefined && (state.ticket !== options.ticket || state.ticketConsumed || state.codeReviewDone)) {
    return { pass: true, reason: 'not-current-ticket' };
  }
  const commands = remedyCommands(root, options.session);
  const consumeAgain = 'spawn zensu:code-reviewer again with the same two header lines';
  const respawnConsume = `${consumeAgain} and the block ${commands.show} prints, copied unchanged`;
  let report = reportText(payload.tool_response);
  if (arrival) {
    const frame = background.handbackReports(payload.prompt).filter((entry) => entry.agentId === agent).pop();
    report = { text: frame ? frame.report : '', source: frame ? 'handback-prompt' : 'none' };
  }
  if (PACKET_INVALID_RE.test(report.text)) {
    return consumeRefusal('the consume reviewer answered REVIEW PACKET INVALID', respawnConsume);
  }
  const store = packets.storeDirectory(root, options.session);
  const listing = listStore(store);
  const round = state.round;
  let supplied = packets.extractPacket(prompt);
  if (arrival) {
    const launch = listing.records.filter((entry) => entry.round === round && entry.role === 'consume' && entry.agentId === agent).pop();
    supplied = launch ? { status: launch.packet, sha256: launch.packetSha, text: null } : { status: 'absent', unchecked: true };
  }
  const runs = listing.records.filter((entry) => entry.status !== LAUNCHED);
  if (listing.packetRounds.length === 0 && runs.length === 0 && supplied.status === 'absent') {
    return { pass: true, reason: 'not-engaged' };
  }
  const canonical = packets.readPacketRecord(store, round);
  const rerun = `spawn this round's reviewers with the block it prints and merge their findings, then ${consumeAgain} and that block`;
  if (!canonical) {
    return consumeRefusal(`review round ${round} has no canonical packet`, `run ${commands.create}, ${rerun}`);
  }
  if (supplied.unchecked) {
    return consumeRefusal(`the background consume reviewer ${agent} was not checked by the review gate at its launch`, respawnConsume);
  }
  if (supplied.status !== 'ok') {
    return consumeRefusal(`the consume prompt carries ${packetProblem(supplied.status)}`, respawnConsume);
  }
  if (supplied.sha256 !== canonical.sha256) {
    if (supplied.text === null) {
      return consumeRefusal(`review round ${round}'s canonical packet changed after the background consume reviewer ${agent} was launched`, respawnConsume);
    }
    return consumeRefusal(`the consume prompt's packet differs from review round ${round}'s canonical packet at packet line ${packets.firstDifference(canonical.text, supplied.text)}`, respawnConsume);
  }
  const now = packets.currentScope(root, canonical.scope.baseline || '', canonical.scope.kind === 'git' ? undefined : canonical.scope.changedFiles);
  const drift = packets.scopeDifference(canonical.scope, now);
  if (drift) {
    return consumeRefusal(`${drift} since review round ${round}'s packet was created`, `re-run the step 5b edit-landing audit, run ${commands.create} again, ${rerun}`);
  }
  if (canonical.receiptMode === 'receipt') {
    const receipt = packets.readReceipt(root, options.session);
    if (receipt.sha256 !== canonical.receiptSha256) {
      return consumeRefusal(`the edit-landing receipt changed since review round ${round}'s packet was created`, `run ${commands.create} again, ${rerun}`);
    }
  } else if (canonical.receiptMode === 'none' && !packets.receiptAbsent(root, options.session)) {
    return consumeRefusal(`an edit-landing receipt was written after review round ${round}'s packet recorded none`, `run ${commands.create} again, ${rerun}`);
  }
  const ofRound = listing.records.filter((entry) => entry.round === round);
  const unreported = (roles) => ofRound.filter((entry) => entry.status === LAUNCHED && roles.includes(entry.role) && entry.agentId
    && !ofRound.some((other) => other.agentId === entry.agentId && other.status !== LAUNCHED)).length;
  const waitHint = (count) => (count === 0 ? '' : `; ${count === 1 ? 'one background reviewer launch of this round has' : `${count} background reviewer launches of this round have`} sent no hand-back the hook could read yet, so wait for ${count === 1 ? 'it' : 'them'} first, and where the host delivers no hand-back, as outside auto mode, ask the user whether to set hooks.reviewPacketGate to false, which reviews this project without the gate`);
  const latest = new Map();
  for (const entry of ofRound) if (entry.identity) latest.set(entry.identity, entry);
  const respawnReviewer = `spawn that reviewer again with the block ${commands.show} prints, merge its findings in place of the earlier ones, then ${consumeAgain} and that block`;
  for (const entry of latest.values()) {
    if (entry.at < canonical.createdAt) {
      return consumeRefusal(`the latest ${describe(entry)} run of review round ${round} predates the round's canonical packet`, respawnReviewer);
    }
    if (entry.packet !== 'ok' || entry.packetSha !== canonical.sha256) {
      return consumeRefusal(`the latest ${describe(entry)} run of review round ${round} saw ${entry.packet !== 'ok' ? packetProblem(entry.packet) : 'another packet than the canonical one'}`, respawnReviewer);
    }
  }
  if (latest.size === 0) {
    return consumeRefusal(`no reviewer of review round ${round} reported on its canonical packet`, `spawn this round's reviewers with the block ${commands.show} prints and merge their findings, then ${consumeAgain} and that block${waitHint(unreported(['aspect', 'persona', 'judge-primary', 'judge-second']))}`);
  }
  const recent = ofRound.filter((entry) => entry.at >= canonical.createdAt);
  const required = options.judge === 'on' && (round === 0 || options.panel === 'full');
  if (required) {
    const primaries = primaryFailures(recent, canonical);
    if (!primaries.some((entry) => entry.valid === true)) {
      const failed = primaries.filter((entry) => entry.valid === false);
      if (failed.length >= 2) {
        return consumeRefusal(`the primary judge failed twice on review round ${round}'s packet (${failed[failed.length - 1].reason})`,
          'stop the review chain here, keep both results and report the chain as pending; the second judge run never substitutes for the primary');
      }
      return consumeRefusal(`no primary zensu:review-judge run completed a substantive report on review round ${round}'s canonical packet${failed.length ? ` (${failed[0].reason})` : ''}`,
        `spawn the primary zensu:review-judge with that block and the merged panel findings, merge its deltas, then ${consumeAgain} and the block; the second judge run never substitutes for it${waitHint(unreported(['judge-primary']))}`);
    }
  }
  const launchAgent = arrival ? null : launchedAgent(payload.tool_response);
  if (launchAgent) {
    writeRecord(packets.ensureStore(root, options.session), {
      schema: RECORD_SCHEMA,
      round,
      at: (options.now || Date.now)(),
      type: clip(input.subagent_type || '', 80),
      role: 'consume',
      identity: null,
      packet: supplied.status,
      packetSha: supplied.sha256,
      status: LAUNCHED,
      reportSource: 'none',
      valid: null,
      reason: null,
      agentId: launchAgent,
    });
    prune(store);
  }
  return { pass: true, reason: 'ok' };
}

function resetStore(options) {
  const root = packets.canonicalRoot(options.root);
  const store = packets.storeDirectory(root, options.session);
  let stat;
  try {
    stat = fs.lstatSync(store);
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    fail(`the review gate store cannot be read (${error.code || 'error'})`);
  }
  if (stat.isSymbolicLink() || !stat.isDirectory()) fs.rmSync(store, { force: true });
  else fs.rmSync(store, { recursive: true, force: true });
  return true;
}

function readPayload(descriptor = 0) {
  let bytes;
  try {
    bytes = fs.readFileSync(descriptor);
  } catch (error) {
    fail(`the hook payload cannot be read (${error.code || 'error'})`);
  }
  if (bytes.length > MAX_PAYLOAD_BYTES) fail('the hook payload is larger than the review gate reads');
  let value;
  try {
    value = JSON.parse(bytes.toString('utf8'));
  } catch {
    fail('the hook payload is not JSON');
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail('the hook payload is not a JSON object');
  return value;
}

function additionalContext(message, event = 'PostToolUse') {
  return `${JSON.stringify({ hookSpecificOutput: { hookEventName: event, additionalContext: message } })}\n`;
}

function eventFlag(value) {
  if (value === undefined) return 'PostToolUse';
  if (!EVENTS.includes(value)) fail('--event must be PostToolUse or UserPromptSubmit');
  return value;
}

function main(argv, io = {}) {
  const stdout = io.stdout || process.stdout;
  const stderr = io.stderr || process.stderr;
  const [verb, ...args] = argv;
  try {
    if (verb === 'record') {
      const flags = packets.parseFlags(args, ['--root', '--session', '--event']);
      const event = eventFlag(flags['--event']);
      let advice = '';
      try {
        const payload = io.payload || readPayload();
        const options = { root: flags['--root'], session: flags['--session'], payload };
        const results = event === 'UserPromptSubmit' ? recordHandback(options) : [recordObservation(options)];
        advice = results.map(observationAdvice).filter(Boolean).join(' ');
      } catch (error) {
        advice = `REVIEW GATE UNAVAILABLE — this reviewer result could not be recorded (${clip(error.message, 300)}), so it cannot count toward the review round; the consume review stays refused until a recorded run exists.`;
      }
      if (advice) stdout.write(additionalContext(advice, event));
      return 0;
    }
    if (verb === 'check') {
      const flags = packets.parseFlags(args, ['--root', '--session', '--judge', '--panel', '--ticket', '--event', '--agent']);
      if (!['on', 'off'].includes(flags['--judge'])) fail('--judge must be on or off');
      if (!['lean', 'full'].includes(flags['--panel'])) fail('--panel must be lean or full');
      const event = eventFlag(flags['--event']);
      if ((event === 'UserPromptSubmit') !== (flags['--agent'] !== undefined)) fail('--agent names the background consume reviewer and goes with --event UserPromptSubmit only');
      if (flags['--agent'] !== undefined && !AGENT_ID_RE.test(flags['--agent'])) fail('--agent is not an agent id');
      const payload = io.payload || readPayload();
      const verdict = checkConsume({ root: flags['--root'], session: flags['--session'], payload, judge: flags['--judge'], panel: flags['--panel'],
        ticket: flags['--ticket'], event, agent: flags['--agent'] });
      if (verdict.pass) {
        stdout.write(`pass ${verdict.reason}\n`);
        return 0;
      }
      if (verdict.hold) {
        stdout.write(`hold ${verdict.reason}\n`);
        return 3;
      }
      stdout.write(`${verdict.message}\n`);
      return 1;
    }
    if (verb === 'reset') {
      const flags = packets.parseFlags(args, ['--root', '--session']);
      resetStore({ root: flags['--root'], session: flags['--session'] });
      return 0;
    }
    fail('usage: review-gate-v1.js record|check|reset --root <dir> --session <id> [--event PostToolUse|UserPromptSubmit] [--judge on|off --panel lean|full [--ticket <review ticket>] [--agent <agent id>]]');
  } catch (error) {
    const known = error instanceof ReviewGateError || error instanceof packets.ReviewPacketError;
    stderr.write(`review-gate-v1: ${known ? error.message : `unexpected failure (${error.message})`}\n`);
    return 2;
  }
}

module.exports = {
  ReviewGateError,
  RECORD_SCHEMA,
  MAX_RECORDS,
  classify,
  reportText,
  heading,
  judgeFailure,
  listStore,
  recordObservation,
  recordHandback,
  observationAdvice,
  checkConsume,
  remedyCommands,
  resetStore,
  main,
};

if (require.main === module) {
  process.exitCode = main(process.argv.slice(2));
}
