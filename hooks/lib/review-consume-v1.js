#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const SCHEMA = 'zensu-review-consume/v1';
const REVIEWER_TYPE = 'zensu:code-reviewer';
const LEAD_IN = 'review-consume-v1';
const DIRECTORY_PREFIX = 'review-consume-';
const SESSION_KEY_RE = /^scv1_[0-9a-f]{64}$/;
const TICKET_RE = /^[A-Za-z0-9_-]{1,96}$/;
const AGENT_ID_RE = /^[A-Za-z0-9_-]{1,128}$/;
const LINK_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_.:-]{2,127}$/;
const RETURN_STAGES = Object.freeze(['GATES', 'CONVERGE', 'FIX_FINDINGS', 'VALIDATE', 'COVER']);
const LAUNCH_KEYS = Object.freeze(
  ['schema', 'ticket', 'agentId', 'kind', 'run', 'attempt', 'chain', 'stage', 'launchedAt'].sort(),
);
const STOP_KEYS = Object.freeze(['schema', 'agentId', 'agentType', 'stoppedAt'].sort());
const WAIT_KEYS = Object.freeze(['schema', 'ticket', 'count', 'updatedAt'].sort());
const LIMITS = Object.freeze({
  maxRecordBytes: 4096,
  maxLaunches: 32,
  maxWaits: 3,
  maxPayloadBytes: 1024 * 1024,
});
const NOFOLLOW = fs.constants.O_NOFOLLOW || 0;

class ReviewConsumeError extends Error {}

function fail(message) {
  throw new ReviewConsumeError(`review-consume-v1: ${message}`);
}

function exactKeys(value, keys) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).sort().join(',') === keys.join(',');
}

function isTimestamp(value) {
  return typeof value === 'string' && value.length <= 40 && Number.isFinite(Date.parse(value));
}

function validEnvelope(kind, run, attempt, chain, stage) {
  if (kind === 'standalone') return run === '-' && attempt === 0 && chain === '-' && stage === '-';
  if (kind !== 'bound') return false;
  return LINK_ID_RE.test(run) && Number.isInteger(attempt) && attempt >= 1 && attempt <= 999
    && LINK_ID_RE.test(chain) && RETURN_STAGES.includes(stage);
}

function validLaunch(record) {
  return exactKeys(record, LAUNCH_KEYS) && record.schema === SCHEMA
    && typeof record.ticket === 'string' && TICKET_RE.test(record.ticket)
    && typeof record.agentId === 'string' && AGENT_ID_RE.test(record.agentId)
    && validEnvelope(record.kind, record.run, record.attempt, record.chain, record.stage)
    && isTimestamp(record.launchedAt);
}

function validStop(record, agentId) {
  return exactKeys(record, STOP_KEYS) && record.schema === SCHEMA
    && record.agentId === agentId && record.agentType === REVIEWER_TYPE
    && isTimestamp(record.stoppedAt);
}

function validWait(record) {
  return exactKeys(record, WAIT_KEYS) && record.schema === SCHEMA
    && typeof record.ticket === 'string' && TICKET_RE.test(record.ticket)
    && Number.isSafeInteger(record.count) && record.count >= 0
    && isTimestamp(record.updatedAt);
}

function requireRealDirectory(directory) {
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail(`${directory} is not a real directory`);
}

function stateDirectory(projectRoot) {
  if (typeof projectRoot !== 'string' || projectRoot === '' || !path.isAbsolute(projectRoot)) {
    fail('the project root must be an absolute path');
  }
  return path.join(projectRoot, '.zensu', 'state');
}

function sessionDirectory(projectRoot, sessionKey) {
  if (typeof sessionKey !== 'string' || !SESSION_KEY_RE.test(sessionKey)) fail('the session key is malformed');
  return path.join(stateDirectory(projectRoot), `${DIRECTORY_PREFIX}${sessionKey}`);
}

function existingSessionDirectory(projectRoot, sessionKey) {
  const directory = sessionDirectory(projectRoot, sessionKey);
  let stat;
  try {
    stat = fs.lstatSync(directory);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail('the session record directory is not a real directory');
  requireRealDirectory(path.dirname(directory));
  requireRealDirectory(path.dirname(path.dirname(directory)));
  return directory;
}

function ensureSessionDirectory(projectRoot, sessionKey) {
  const directory = sessionDirectory(projectRoot, sessionKey);
  requireRealDirectory(path.dirname(path.dirname(directory)));
  requireRealDirectory(path.dirname(directory));
  try {
    fs.mkdirSync(directory, { mode: 0o700 });
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
  }
  requireRealDirectory(directory);
  return directory;
}

function readRecord(file) {
  let descriptor;
  try {
    descriptor = fs.openSync(file, fs.constants.O_RDONLY | NOFOLLOW);
  } catch (error) {
    if (error.code === 'ENOENT') return { missing: true };
    return { invalid: true };
  }
  try {
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile() || stat.size > LIMITS.maxRecordBytes) return { invalid: true };
    const buffer = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < stat.size) {
      const read = fs.readSync(descriptor, buffer, offset, stat.size - offset, offset);
      if (read === 0) break;
      offset += read;
    }
    return { value: JSON.parse(buffer.subarray(0, offset).toString('utf8')) };
  } catch {
    return { invalid: true };
  } finally {
    fs.closeSync(descriptor);
  }
}

function writeRecord(directory, name, value) {
  const text = `${JSON.stringify(value)}\n`;
  if (Buffer.byteLength(text) > LIMITS.maxRecordBytes) fail('the record is too large');
  const temporary = path.join(directory, `.${name}.${crypto.randomBytes(8).toString('hex')}.tmp`);
  const descriptor = fs.openSync(
    temporary,
    fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | NOFOLLOW,
    0o600,
  );
  try {
    fs.writeSync(descriptor, text);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  try {
    fs.renameSync(temporary, path.join(directory, name));
  } catch (error) {
    fs.rmSync(temporary, { force: true });
    throw error;
  }
}

function launchFile(directory, agentId) {
  return path.join(directory, `launch-${agentId}.json`);
}

function stopFile(directory, agentId) {
  return path.join(directory, `stop-${agentId}.json`);
}

function waitFile(directory) {
  return path.join(directory, 'wait.json');
}

function listLaunches(directory) {
  const launches = [];
  for (const name of fs.readdirSync(directory)) {
    const match = /^launch-([A-Za-z0-9_-]{1,128})\.json$/.exec(name);
    if (!match) continue;
    const loaded = readRecord(path.join(directory, name));
    if (loaded.value && validLaunch(loaded.value) && loaded.value.agentId === match[1]) {
      launches.push(loaded.value);
    }
  }
  return launches;
}

function stopOf(directory, agentId) {
  const loaded = readRecord(stopFile(directory, agentId));
  return loaded.value && validStop(loaded.value, agentId) ? loaded.value : null;
}

function prune(directory, keep) {
  const launches = listLaunches(directory)
    .sort((a, b) => Date.parse(b.launchedAt) - Date.parse(a.launchedAt));
  for (const stale of launches.slice(keep)) {
    fs.rmSync(launchFile(directory, stale.agentId), { force: true });
    fs.rmSync(stopFile(directory, stale.agentId), { force: true });
  }
}

function recordLaunch(options) {
  const record = {
    schema: SCHEMA,
    ticket: options.ticket,
    agentId: options.agentId,
    kind: options.kind,
    run: options.run,
    attempt: options.attempt,
    chain: options.chain,
    stage: options.stage,
    launchedAt: new Date(options.now === undefined ? Date.now() : options.now).toISOString(),
  };
  if (!validLaunch(record)) fail('the launch record is malformed');
  const directory = ensureSessionDirectory(options.projectRoot, options.sessionKey);
  writeRecord(directory, path.basename(launchFile(directory, record.agentId)), record);
  prune(directory, LIMITS.maxLaunches);
  return record;
}

function recordStop(options) {
  if (options.agentType !== REVIEWER_TYPE) return { recorded: false, reason: 'agent-type' };
  if (typeof options.agentId !== 'string' || !AGENT_ID_RE.test(options.agentId)) {
    return { recorded: false, reason: 'agent-id' };
  }
  const directory = existingSessionDirectory(options.projectRoot, options.sessionKey);
  if (!directory) return { recorded: false, reason: 'no-launch' };
  const launch = readRecord(launchFile(directory, options.agentId));
  if (!launch.value || !validLaunch(launch.value) || launch.value.agentId !== options.agentId) {
    return { recorded: false, reason: 'no-launch' };
  }
  if (stopOf(directory, options.agentId)) return { recorded: false, reason: 'already-stopped' };
  writeRecord(directory, path.basename(stopFile(directory, options.agentId)), {
    schema: SCHEMA,
    agentId: options.agentId,
    agentType: REVIEWER_TYPE,
    stoppedAt: new Date(options.now === undefined ? Date.now() : options.now).toISOString(),
  });
  return { recorded: true, reason: 'stopped' };
}

function lookup(options) {
  if (typeof options.ticket !== 'string' || !TICKET_RE.test(options.ticket)) fail('the ticket is malformed');
  const directory = existingSessionDirectory(options.projectRoot, options.sessionKey);
  if (!directory) return { status: 'none' };
  const launches = listLaunches(directory).filter((launch) => launch.ticket === options.ticket);
  if (launches.length === 0) return { status: 'none' };
  const stopped = launches
    .map((launch) => ({ launch, stop: stopOf(directory, launch.agentId) }))
    .filter((entry) => entry.stop)
    .sort((a, b) => Date.parse(a.stop.stoppedAt) - Date.parse(b.stop.stoppedAt));
  if (stopped.length === 0) return { status: 'running', launches: launches.length };
  return { status: 'stopped', launch: stopped[0].launch };
}

function currentTicket(options) {
  const core = require('./session-control-core-v1.js');
  const state = core.readWorkflowState({ projectRoot: options.projectRoot, sessionId: options.sessionKey });
  if (state.active !== true || state.implComplete !== true || state.chainDone !== false) return null;
  if (state.reviewTicketConsumed !== false) return null;
  if (typeof state.reviewTicket !== 'string' || !TICKET_RE.test(state.reviewTicket)) return null;
  return state.reviewTicket;
}

function clearWait(options) {
  const directory = existingSessionDirectory(options.projectRoot, options.sessionKey);
  if (directory) fs.rmSync(waitFile(directory), { force: true });
}

function stopWait(options) {
  const max = Number.isSafeInteger(options.max) && options.max >= 0 ? options.max : LIMITS.maxWaits;
  const ticket = currentTicket(options);
  if (!ticket) {
    clearWait(options);
    return { status: 'none', line: 'none' };
  }
  const found = lookup({ ...options, ticket });
  if (found.status === 'none') {
    clearWait(options);
    return { status: 'none', line: 'none' };
  }
  if (found.status === 'stopped') {
    clearWait(options);
    return { status: 'stopped', ticket, line: `stopped ticket=${ticket}` };
  }
  const directory = ensureSessionDirectory(options.projectRoot, options.sessionKey);
  const loaded = readRecord(waitFile(directory));
  const count = loaded.value && validWait(loaded.value) && loaded.value.ticket === ticket ? loaded.value.count : 0;
  if (count >= max) {
    return { status: 'limit', ticket, count, max, line: `limit ticket=${ticket} count=${count} max=${max}` };
  }
  writeRecord(directory, 'wait.json', {
    schema: SCHEMA,
    ticket,
    count: count + 1,
    updatedAt: new Date(options.now === undefined ? Date.now() : options.now).toISOString(),
  });
  return {
    status: 'wait',
    ticket,
    count: count + 1,
    max,
    line: `wait ticket=${ticket} count=${count + 1} max=${max}`,
  };
}

function reset(options) {
  const directory = existingSessionDirectory(options.projectRoot, options.sessionKey);
  if (directory) fs.rmSync(directory, { recursive: true, force: true });
}

function parseFlags(argv, required, optional = []) {
  const flags = {};
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    if (![...required, ...optional].includes(name) || index + 1 >= argv.length || Object.hasOwn(flags, name)) {
      fail(`unexpected argument ${JSON.stringify(name)}`);
    }
    flags[name] = argv[index + 1];
  }
  for (const name of required) if (!Object.hasOwn(flags, name)) fail(`missing ${name}`);
  return flags;
}

function environmentOptions(env) {
  return { projectRoot: env.ZENSU_RC_PROJECT_ROOT, sessionKey: env.ZENSU_RC_SESSION_KEY };
}

function readStdin() {
  const raw = fs.readFileSync(0);
  if (raw.length === 0 || raw.length > LIMITS.maxPayloadBytes) return null;
  try {
    const payload = JSON.parse(raw.toString('utf8'));
    return payload && typeof payload === 'object' && !Array.isArray(payload) ? payload : null;
  } catch {
    return null;
  }
}

function stopFromPayload(payload, env) {
  if (!payload || payload.hook_event_name !== 'SubagentStop' || payload.agent_type !== REVIEWER_TYPE) {
    return { recorded: false, reason: 'not-a-reviewer-stop' };
  }
  const hookSession = require('./claude-hook-session-v1.js');
  const binding = hookSession.bindAndDisclose(payload, env, { autoAdopt: true }, LEAD_IN);
  return recordStop({
    projectRoot: binding.projectRoot,
    sessionKey: binding.sessionKey,
    agentId: payload.agent_id,
    agentType: payload.agent_type,
  });
}

function main(argv, env = process.env, io = {}) {
  const mode = argv[0];
  const write = io.write || ((text) => process.stdout.write(text));
  if (mode === 'stop') {
    try {
      stopFromPayload(io.payload !== undefined ? io.payload : readStdin(), env);
    } catch { }
    return 0;
  }
  if (mode === 'launch') {
    const flags = parseFlags(argv.slice(1), ['--ticket', '--agent', '--kind', '--run', '--attempt', '--chain', '--stage']);
    if (!/^(0|[1-9][0-9]{0,2})$/.test(flags['--attempt'])) fail('the attempt is malformed');
    recordLaunch({
      ...environmentOptions(env),
      ticket: flags['--ticket'],
      agentId: flags['--agent'],
      kind: flags['--kind'],
      run: flags['--run'],
      attempt: Number(flags['--attempt']),
      chain: flags['--chain'],
      stage: flags['--stage'],
    });
    return 0;
  }
  if (mode === 'lookup') {
    const flags = parseFlags(argv.slice(1), ['--ticket']);
    const found = lookup({ ...environmentOptions(env), ticket: flags['--ticket'] });
    if (found.status === 'none') {
      write('none\n');
      return 3;
    }
    if (found.status === 'running') {
      write('running\n');
      return 4;
    }
    const launch = found.launch;
    write(`${['stopped', launch.agentId, launch.kind, launch.run, launch.attempt, launch.chain, launch.stage].join('\t')}\n`);
    return 0;
  }
  if (mode === 'wait') {
    const flags = parseFlags(argv.slice(1), [], ['--max']);
    if (Object.hasOwn(flags, '--max') && !/^(0|[1-9][0-9]{0,2})$/.test(flags['--max'])) fail('the wait bound is malformed');
    let result;
    try {
      result = stopWait({
        ...environmentOptions(env),
        max: Object.hasOwn(flags, '--max') ? Number(flags['--max']) : undefined,
      });
    } catch {
      result = { line: 'fault' };
    }
    write(`${result.line}\n`);
    return 0;
  }
  if (mode === 'reset') {
    parseFlags(argv.slice(1), []);
    reset(environmentOptions(env));
    return 0;
  }
  process.stderr.write('usage: review-consume-v1.js launch|stop|lookup|wait|reset\n');
  return 2;
}

module.exports = {
  SCHEMA,
  REVIEWER_TYPE,
  LIMITS,
  ReviewConsumeError,
  sessionDirectory,
  recordLaunch,
  recordStop,
  lookup,
  stopWait,
  reset,
  main,
};

if (require.main === module) {
  let code;
  try {
    code = main(process.argv.slice(2));
  } catch (error) {
    if (process.argv[2] === 'stop') {
      code = 0;
    } else {
      process.stderr.write(`${error && error.message ? error.message : String(error)}\n`);
      code = 5;
    }
  }
  process.exitCode = code;
}
