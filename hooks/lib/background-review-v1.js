'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { REVIEWER_TYPES } = require('./claude-principal-v1.js');
const { ensurePrivateDirectory } = require('./review-evidence-lease-v1.js');
const { REVIEWER_SUBAGENT_TYPE } = require('./reviewer-spawn-denial-v1.js');
const { claimableTicket } = require('./review-ticket-state-v1.js');

const SCHEMA = 'background-review-v1';
const STORE_SEGMENTS = Object.freeze(['background-review', 'v1']);
const RECORDS_SEGMENT = 'records';
const FANOUT_SEGMENT = 'fanout';
const SESSION_KEY_RE = /^scv1_[0-9a-f]{64}$/;
const AGENT_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{2,63}$/;
const FANOUT_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{2,63}\.json$/;
const TICKET_RE = /^[A-Za-z0-9_-]{1,96}$/;
const STATUS_RE = /^[a-z][a-z_-]{0,31}$/;
const CONTROL_RE = /[\u0000-\u001f\u007f]/;
const HEADER_FIRST_LINE = 'PRE-MERGED FINDINGS (fan-out)';
const TICKET_PREFIX = 'REVIEW-TICKET: ';
const ENVELOPE_PREFIXES = Object.freeze(['ZENSU-DELEGATED-CALLER: ', 'AUTOPILOT-BINDING: ', 'AUTOPILOT-STAGE: ']);
const ENVELOPES = Object.freeze({ standalone: 2, bound: 5 });
const RECORD_KEYS = Object.freeze(['agent_id', 'header', 'launched_at_ms', 'schema', 'session_key', 'ticket']);
const FANOUT_KEYS = Object.freeze(['agent_id', 'launched_at_ms', 'schema', 'session_key', 'subagent_type']);
const FANOUT_TYPES = Object.freeze([...REVIEWER_TYPES]
  .filter((type) => type.startsWith('zensu:') && type !== REVIEWER_SUBAGENT_TYPE));
const VERDICTS = Object.freeze(['claim', 'ended', 'none']);
const ARRIVALS = Object.freeze(['handback', 'notification']);
const WAIT_KINDS = Object.freeze(['consume', 'fanout']);
const ASYNC_STATUS = 'async_launched';
const COMPLETED_STATUS = 'completed';
const HANDBACK_FRAME_LINE = '[Subagent hand-back]';
const LIMITS = Object.freeze({
  maxPayloadBytes: 8 * 1024 * 1024,
  maxRecordBytes: 16 * 1024,
  maxStateBytes: 4 * 1024 * 1024,
  maxHeaderLineChars: 512,
  maxFanoutEntries: 32,
  maxFanoutNames: 256,
  waitTtlMs: 60 * 60 * 1000,
  idleMs: 24 * 60 * 60 * 1000,
  clockSkewMs: 5 * 60 * 1000,
});

class BackgroundReviewError extends Error {
  constructor(message) {
    super(message);
    this.name = 'BackgroundReviewError';
  }
}

function fail(message) {
  throw new BackgroundReviewError(message);
}

function limitsWith(overrides) {
  return Object.freeze({ ...LIMITS, ...(overrides || {}) });
}

function ttlMinutes(limits = LIMITS) {
  return Math.floor(limits.waitTtlMs / 60000);
}

function isPlainObject(value) {
  return !!value && typeof value === 'object' && !Array.isArray(value);
}

function exactKeys(value, keys) {
  return isPlainObject(value) && Object.keys(value).sort().join(',') === [...keys].sort().join(',');
}

function requireSessionKey(sessionKey) {
  if (typeof sessionKey !== 'string' || !SESSION_KEY_RE.test(sessionKey)) fail('invalid session key');
  return sessionKey;
}

function headerProblem(header, ticket, limits = LIMITS) {
  if (!Array.isArray(header)) return 'header is not a list';
  if (header.length !== ENVELOPES.standalone && header.length !== ENVELOPES.bound) return 'header length';
  for (const line of header) {
    if (typeof line !== 'string' || line === '' || line.length > limits.maxHeaderLineChars) return 'header line shape';
    if (CONTROL_RE.test(line)) return 'header line carries a control character';
  }
  if (header[0] !== HEADER_FIRST_LINE) return 'header first line';
  if (header[1] !== `${TICKET_PREFIX}${ticket}`) return 'header ticket line';
  if (header.length === ENVELOPES.bound) {
    for (let index = 0; index < ENVELOPE_PREFIXES.length; index += 1) {
      const line = header[index + 2];
      if (!line.startsWith(ENVELOPE_PREFIXES[index]) || line.length === ENVELOPE_PREFIXES[index].length) {
        return 'header envelope line';
      }
    }
  }
  return null;
}

function validateRecord(record, expected = {}, limits = LIMITS) {
  if (!exactKeys(record, RECORD_KEYS)) return 'record keys';
  if (record.schema !== SCHEMA) return 'record schema';
  if (typeof record.session_key !== 'string' || !SESSION_KEY_RE.test(record.session_key)) return 'record session key';
  if (expected.sessionKey !== undefined && record.session_key !== expected.sessionKey) return 'record session mismatch';
  if (typeof record.ticket !== 'string' || !TICKET_RE.test(record.ticket)) return 'record ticket';
  if (typeof record.agent_id !== 'string' || !AGENT_ID_RE.test(record.agent_id)) return 'record agent id';
  if (!Number.isSafeInteger(record.launched_at_ms) || record.launched_at_ms < 0) return 'record launch time';
  return headerProblem(record.header, record.ticket, limits);
}

function validateFanout(entry, expected = {}) {
  if (!exactKeys(entry, FANOUT_KEYS)) return 'fanout keys';
  if (entry.schema !== SCHEMA) return 'fanout schema';
  if (typeof entry.session_key !== 'string' || !SESSION_KEY_RE.test(entry.session_key)) return 'fanout session key';
  if (expected.sessionKey !== undefined && entry.session_key !== expected.sessionKey) return 'fanout session mismatch';
  if (typeof entry.agent_id !== 'string' || !AGENT_ID_RE.test(entry.agent_id)) return 'fanout agent id';
  if (expected.agentId !== undefined && entry.agent_id !== expected.agentId) return 'fanout agent mismatch';
  if (!FANOUT_TYPES.includes(entry.subagent_type)) return 'fanout subagent type';
  if (!Number.isSafeInteger(entry.launched_at_ms) || entry.launched_at_ms < 0) return 'fanout launch time';
  return null;
}

function storeLocations(pluginData) {
  let root;
  try {
    root = ensurePrivateDirectory(pluginData, STORE_SEGMENTS);
  } catch (error) {
    fail(`background review store unavailable: ${error.message}`);
  }
  return {
    root,
    records: ensurePrivateDirectory(root, [RECORDS_SEGMENT]),
    fanout: ensurePrivateDirectory(root, [FANOUT_SEGMENT]),
  };
}

function recordFileName(sessionKey) {
  return `${requireSessionKey(sessionKey)}.json`;
}

function syncDirectory(directory) {
  if (process.platform === 'win32') return;
  let descriptor;
  try {
    descriptor = fs.openSync(directory, 'r');
    fs.fsyncSync(descriptor);
  } catch { } finally {
    if (descriptor !== undefined) {
      try { fs.closeSync(descriptor); } catch { }
    }
  }
}

function writeFileAtomic(directory, name, text) {
  const target = path.join(directory, name);
  const temporary = path.join(directory, `.${name}.${crypto.randomBytes(6).toString('hex')}.tmp`);
  const descriptor = fs.openSync(temporary, 'wx', 0o600);
  try {
    fs.writeFileSync(descriptor, text);
    fs.fsyncSync(descriptor);
  } catch (error) {
    try { fs.closeSync(descriptor); } catch { }
    try { fs.unlinkSync(temporary); } catch { }
    throw error;
  }
  fs.closeSync(descriptor);
  try {
    fs.renameSync(temporary, target);
  } catch (error) {
    try { fs.unlinkSync(temporary); } catch { }
    throw error;
  }
  syncDirectory(directory);
  return target;
}

function readBoundedFile(filePath, maxBytes) {
  let descriptor;
  try {
    const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0) | (fs.constants.O_NONBLOCK || 0);
    descriptor = fs.openSync(filePath, flags);
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile()) return { invalid: 'not-regular' };
    if (stat.size > maxBytes) return { invalid: 'oversized' };
    const buffer = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < stat.size) {
      const read = fs.readSync(descriptor, buffer, offset, stat.size - offset, offset);
      if (read === 0) break;
      offset += read;
    }
    return { text: buffer.subarray(0, offset).toString('utf8') };
  } catch (error) {
    return { invalid: error && error.code === 'ENOENT' ? 'absent' : 'unreadable' };
  } finally {
    if (descriptor !== undefined) {
      try { fs.closeSync(descriptor); } catch { }
    }
  }
}

function issuedTicket(stateFile, sessionKey, limits = LIMITS) {
  if (typeof stateFile !== 'string' || stateFile === '' || !path.isAbsolute(stateFile)) return null;
  const loaded = readBoundedFile(stateFile, limits.maxStateBytes);
  if (loaded.invalid) return null;
  let state;
  try {
    state = JSON.parse(loaded.text);
  } catch {
    return null;
  }
  const ticket = claimableTicket(state, sessionKey);
  return typeof ticket === 'string' && TICKET_RE.test(ticket) ? ticket : null;
}

function loadRecord(file, sessionKey, limits = LIMITS) {
  const loaded = readBoundedFile(file, limits.maxRecordBytes);
  if (loaded.invalid) return { record: null, reason: loaded.invalid };
  let record;
  try {
    record = JSON.parse(loaded.text);
  } catch {
    return { record: null, reason: 'unparseable' };
  }
  const problem = validateRecord(record, { sessionKey }, limits);
  if (problem) return { record: null, reason: 'invalid' };
  return { record, text: loaded.text };
}

function sweepIdle(records, keepName, limits = LIMITS, now = Date.now()) {
  let names;
  try {
    names = fs.readdirSync(records);
  } catch {
    return 0;
  }
  let removed = 0;
  for (const name of names) {
    if (name === keepName) continue;
    const file = path.join(records, name);
    let stat;
    try {
      stat = fs.lstatSync(file);
    } catch {
      continue;
    }
    if (stat.isDirectory()) continue;
    if (now - stat.mtimeMs < limits.idleMs) continue;
    try { fs.unlinkSync(file); removed += 1; } catch { }
  }
  return removed;
}

function sweepIdleFanout(fanoutRoot, keepKey, limits = LIMITS, now = Date.now()) {
  let names;
  try {
    names = fs.readdirSync(fanoutRoot);
  } catch {
    return 0;
  }
  let removed = 0;
  for (const name of names) {
    if (name === keepKey) continue;
    const entry = path.join(fanoutRoot, name);
    let stat;
    try {
      stat = fs.lstatSync(entry);
    } catch {
      continue;
    }
    if (now - stat.mtimeMs < limits.idleMs) continue;
    try {
      if (stat.isDirectory()) fs.rmSync(entry, { recursive: true, force: true });
      else fs.unlinkSync(entry);
      removed += 1;
    } catch { }
  }
  return removed;
}

function headerFromPrompt(prompt, envelope) {
  if (typeof prompt !== 'string' || !Object.prototype.hasOwnProperty.call(ENVELOPES, envelope)) return null;
  return prompt.split(/\r?\n/).slice(0, ENVELOPES[envelope]);
}

function launchAgentId(response) {
  if (!isPlainObject(response)) return null;
  const agentId = response.agentId;
  return typeof agentId === 'string' && AGENT_ID_RE.test(agentId) ? agentId : null;
}

function recordLaunch(payload, options, limits = LIMITS) {
  const sessionKey = requireSessionKey(options.sessionKey);
  if (!isPlainObject(payload)) return { recorded: false, reason: 'payload' };
  const input = isPlainObject(payload.tool_input) ? payload.tool_input : {};
  const agentId = launchAgentId(payload.tool_response);
  if (!agentId) return { recorded: false, reason: 'agent-id' };
  const header = headerFromPrompt(input.prompt, options.envelope);
  if (!header) return { recorded: false, reason: 'envelope' };
  const ticketLine = typeof header[1] === 'string' ? header[1] : '';
  const ticket = ticketLine.startsWith(TICKET_PREFIX) ? ticketLine.slice(TICKET_PREFIX.length) : '';
  if (!TICKET_RE.test(ticket)) return { recorded: false, reason: 'ticket' };
  if (issuedTicket(options.stateFile, sessionKey, limits) !== ticket) return { recorded: false, reason: 'ticket-not-issued' };
  const now = options.now === undefined ? Date.now() : options.now;
  const record = {
    schema: SCHEMA,
    session_key: sessionKey,
    ticket,
    agent_id: agentId,
    header,
    launched_at_ms: now,
  };
  if (validateRecord(record, { sessionKey }, limits)) return { recorded: false, reason: 'header' };
  let locations;
  try {
    locations = storeLocations(options.pluginData);
  } catch {
    return { recorded: false, reason: 'store' };
  }
  const name = recordFileName(sessionKey);
  sweepIdle(locations.records, name, limits, now);
  sweepIdleFanout(locations.fanout, sessionKey, limits, now);
  try {
    writeFileAtomic(locations.records, name, `${JSON.stringify(record)}\n`);
  } catch {
    return { recorded: false, reason: 'write' };
  }
  return { recorded: true, agentId, ticket, ttlMinutes: ttlMinutes(limits) };
}

function fanoutDirectory(locations, sessionKey) {
  const directory = path.join(locations.fanout, requireSessionKey(sessionKey));
  try {
    const stat = fs.lstatSync(directory);
    return stat.isDirectory() && !stat.isSymbolicLink() ? directory : null;
  } catch {
    return null;
  }
}

function fanoutEntries(directory, sessionKey, limits = LIMITS) {
  let names;
  try {
    names = fs.readdirSync(directory);
  } catch {
    return [];
  }
  const entries = [];
  for (const name of names.slice(0, limits.maxFanoutNames)) {
    if (!FANOUT_NAME_RE.test(name)) continue;
    const file = path.join(directory, name);
    const loaded = readBoundedFile(file, limits.maxRecordBytes);
    if (loaded.invalid) continue;
    let entry;
    try {
      entry = JSON.parse(loaded.text);
    } catch {
      continue;
    }
    if (validateFanout(entry, { sessionKey, agentId: name.slice(0, -'.json'.length) })) continue;
    entries.push({ file, text: loaded.text, entry });
  }
  return entries;
}

function fanoutFresh(entry, limits, now) {
  const age = now - entry.launched_at_ms;
  return age >= -limits.clockSkewMs && age < limits.waitTtlMs;
}

function pruneFanout(entries, limits, now) {
  const fresh = [];
  for (const item of entries) {
    if (fanoutFresh(item.entry, limits, now)) fresh.push(item);
    else consumeRecord(item.file, item.text, limits);
  }
  return fresh;
}

function recordFanout(payload, options, limits = LIMITS) {
  const sessionKey = requireSessionKey(options.sessionKey);
  if (!isPlainObject(payload)) return { recorded: false, reason: 'payload' };
  const input = isPlainObject(payload.tool_input) ? payload.tool_input : {};
  if (!FANOUT_TYPES.includes(input.subagent_type)) return { recorded: false, reason: 'subagent-type' };
  const response = payload.tool_response;
  if (!isPlainObject(response) || response.status !== ASYNC_STATUS) return { recorded: false, reason: 'not-async' };
  const agentId = launchAgentId(response);
  if (!agentId) return { recorded: false, reason: 'agent-id' };
  const now = options.now === undefined ? Date.now() : options.now;
  const entry = {
    schema: SCHEMA,
    session_key: sessionKey,
    agent_id: agentId,
    subagent_type: input.subagent_type,
    launched_at_ms: now,
  };
  let locations;
  let directory;
  try {
    locations = storeLocations(options.pluginData);
    directory = ensurePrivateDirectory(locations.fanout, [sessionKey]);
  } catch {
    return { recorded: false, reason: 'store' };
  }
  sweepIdle(locations.records, recordFileName(sessionKey), limits, now);
  sweepIdleFanout(locations.fanout, sessionKey, limits, now);
  const fresh = pruneFanout(fanoutEntries(directory, sessionKey, limits), limits, now);
  if (!fresh.some((item) => item.entry.agent_id === agentId) && fresh.length >= limits.maxFanoutEntries) {
    return { recorded: false, reason: 'full' };
  }
  try {
    writeFileAtomic(directory, `${agentId}.json`, `${JSON.stringify(entry)}\n`);
  } catch {
    return { recorded: false, reason: 'write' };
  }
  return { recorded: true, agentId, ttlMinutes: ttlMinutes(limits) };
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function promptLines(prompt) {
  return prompt.split('\n').map((line) => line.replace(/\r$/, ''));
}

function scanLines(lines, agentId) {
  if (!Array.isArray(lines) || typeof agentId !== 'string' || !AGENT_ID_RE.test(agentId)) {
    return { arrival: null };
  }
  const frame = `<agent-message from="${agentId}">`;
  for (let index = 0; index + 1 < lines.length; index += 1) {
    if (lines[index] === frame && lines[index + 1].startsWith(HANDBACK_FRAME_LINE)) {
      return { arrival: 'handback', status: COMPLETED_STATUS };
    }
  }
  const idLine = new RegExp(`^<task-id>[ \\t]*${escapeRegExp(agentId)}[ \\t]*</task-id>$`);
  let status = null;
  let block = null;
  for (const line of lines) {
    if (line === '<task-notification>') {
      block = [];
      continue;
    }
    if (block === null) continue;
    if (line !== '</task-notification>') {
      block.push(line);
      continue;
    }
    const entries = block;
    block = null;
    if (!entries.some((entry) => idLine.test(entry))) continue;
    const found = entries.map((entry) => /^<status>[ \t]*([^<\s]*)[ \t]*<\/status>$/.exec(entry)).find(Boolean);
    const value = found && STATUS_RE.test(found[1]) ? found[1] : 'unknown';
    if (value === COMPLETED_STATUS) return { arrival: 'notification', status: COMPLETED_STATUS };
    status = value;
  }
  return status ? { arrival: 'notification', status } : { arrival: null };
}

function scanPrompt(prompt, agentId) {
  if (typeof prompt !== 'string') return { arrival: null };
  return scanLines(promptLines(prompt), agentId);
}

function handbackReports(prompt) {
  if (typeof prompt !== 'string') return [];
  const lines = promptLines(prompt);
  const reports = [];
  for (let index = 0; index + 1 < lines.length; index += 1) {
    const open = /^<agent-message from="([^"]*)">$/.exec(lines[index]);
    if (!open || !AGENT_ID_RE.test(open[1]) || !lines[index + 1].startsWith(HANDBACK_FRAME_LINE)) continue;
    const close = lines.indexOf('</agent-message>', index + 2);
    const body = lines.slice(index + 2, close === -1 ? lines.length : close);
    const indent = (line) => /^ */.exec(line)[0].length;
    const widths = body.filter((line) => line.trim() !== '').map(indent);
    const strip = widths.length ? Math.min(...widths) : 0;
    reports.push({ agentId: open[1], report: body.map((line) => line.slice(Math.min(strip, indent(line)))).join('\n') });
    index = close === -1 ? lines.length : close;
  }
  return reports;
}

function consumeRecord(file, expectedText, limits = LIMITS) {
  const taken = `${file}.${crypto.randomBytes(6).toString('hex')}.consumed`;
  try {
    fs.renameSync(file, taken);
  } catch {
    return false;
  }
  const loaded = readBoundedFile(taken, limits.maxRecordBytes);
  if (!loaded.invalid && loaded.text === expectedText) {
    try { fs.unlinkSync(taken); } catch { }
    return true;
  }
  try {
    fs.linkSync(taken, file);
  } catch { }
  try { fs.unlinkSync(taken); } catch { }
  return false;
}

function retireFanoutArrivals(locations, sessionKey, lines, limits = LIMITS) {
  const directory = fanoutDirectory(locations, sessionKey);
  if (!directory) return 0;
  let retired = 0;
  for (const item of fanoutEntries(directory, sessionKey, limits)) {
    if (!scanLines(lines, item.entry.agent_id).arrival) continue;
    if (consumeRecord(item.file, item.text, limits)) retired += 1;
  }
  return retired;
}

function none(reason, retired = 0) {
  return { verdict: 'none', reason, retired };
}

function matchArrival(payload, options, limits = LIMITS) {
  const sessionKey = requireSessionKey(options.sessionKey);
  const prompt = isPlainObject(payload) && typeof payload.prompt === 'string' ? payload.prompt : null;
  if (prompt === null) return none('prompt');
  let locations;
  try {
    locations = storeLocations(options.pluginData);
  } catch {
    return none('store');
  }
  const lines = promptLines(prompt);
  const retired = retireFanoutArrivals(locations, sessionKey, lines, limits);
  const file = path.join(locations.records, recordFileName(sessionKey));
  const loaded = loadRecord(file, sessionKey, limits);
  if (!loaded.record) return none(loaded.reason, retired);
  const scan = scanLines(lines, loaded.record.agent_id);
  if (!scan.arrival) return none('no-arrival', retired);
  if (issuedTicket(options.stateFile, sessionKey, limits) !== loaded.record.ticket) {
    consumeRecord(file, loaded.text, limits);
    return none('stale-ticket', retired);
  }
  if (scan.status === COMPLETED_STATUS) {
    return { verdict: 'claim', arrival: scan.arrival, record: loaded.record, retired };
  }
  if (!consumeRecord(file, loaded.text, limits)) return none('consumed-elsewhere', retired);
  return { verdict: 'ended', status: scan.status, record: loaded.record, retired };
}

function retireRecord(options, limits = LIMITS) {
  const sessionKey = requireSessionKey(options.sessionKey);
  if (typeof options.agentId !== 'string' || !AGENT_ID_RE.test(options.agentId)) {
    return { retired: false, reason: 'agent-id' };
  }
  let locations;
  try {
    locations = storeLocations(options.pluginData);
  } catch {
    return { retired: false, reason: 'store' };
  }
  const file = path.join(locations.records, recordFileName(sessionKey));
  const loaded = loadRecord(file, sessionKey, limits);
  if (!loaded.record) return { retired: false, reason: loaded.reason };
  if (loaded.record.agent_id !== options.agentId) return { retired: false, reason: 'other-agent' };
  if (!consumeRecord(file, loaded.text, limits)) return { retired: false, reason: 'consumed-elsewhere' };
  return { retired: true };
}

function consumeWait(locations, sessionKey, options, limits, now) {
  const loaded = loadRecord(path.join(locations.records, recordFileName(sessionKey)), sessionKey, limits);
  if (!loaded.record) return { wait: false, reason: loaded.reason === 'absent' ? 'none' : loaded.reason };
  if (issuedTicket(options.stateFile, sessionKey, limits) !== loaded.record.ticket) return { wait: false, reason: 'ticket' };
  const age = now - loaded.record.launched_at_ms;
  if (age < -limits.clockSkewMs) return { wait: false, reason: 'clock' };
  if (age >= limits.waitTtlMs) return { wait: false, reason: 'expired' };
  return {
    wait: true,
    kind: 'consume',
    agentId: loaded.record.agent_id,
    ageMinutes: Math.max(0, Math.floor(age / 60000)),
    count: 1,
    ttlMinutes: ttlMinutes(limits),
  };
}

function fanoutWait(locations, sessionKey, limits, now) {
  const directory = fanoutDirectory(locations, sessionKey);
  if (!directory) return { wait: false };
  const fresh = pruneFanout(fanoutEntries(directory, sessionKey, limits), limits, now);
  if (fresh.length === 0) return { wait: false };
  const newest = fresh.reduce((best, item) => (item.entry.launched_at_ms > best.entry.launched_at_ms ? item : best));
  return {
    wait: true,
    kind: 'fanout',
    agentId: newest.entry.agent_id,
    ageMinutes: Math.max(0, Math.floor((now - newest.entry.launched_at_ms) / 60000)),
    count: fresh.length,
    ttlMinutes: ttlMinutes(limits),
  };
}

function waitVerdict(options, limits = LIMITS) {
  const sessionKey = requireSessionKey(options.sessionKey);
  const now = options.now === undefined ? Date.now() : options.now;
  let locations;
  try {
    locations = storeLocations(options.pluginData);
  } catch {
    return { wait: false, reason: 'store' };
  }
  const consume = consumeWait(locations, sessionKey, options, limits, now);
  if (consume.wait) return consume;
  const fanout = fanoutWait(locations, sessionKey, limits, now);
  return fanout.wait ? fanout : consume;
}

function matchLine(result) {
  if (result.verdict === 'claim') {
    return JSON.stringify({
      verdict: 'claim',
      arrival: result.arrival,
      agentId: result.record.agent_id,
      ticket: result.record.ticket,
      prompt: result.record.header.join('\n'),
      retired: result.retired,
    });
  }
  if (result.verdict === 'ended') {
    return JSON.stringify({
      verdict: 'ended',
      status: result.status,
      agentId: result.record.agent_id,
      ticket: result.record.ticket,
      retired: result.retired,
    });
  }
  return JSON.stringify({ verdict: 'none', reason: result.reason, retired: result.retired || 0 });
}

function recordLine(result) {
  return result.recorded
    ? `recorded agent=${result.agentId} ttl=${result.ttlMinutes}`
    : `unrecorded reason=${result.reason}`;
}

function waitLine(result) {
  return result.wait
    ? `wait kind=${result.kind} agent=${result.agentId} age=${result.ageMinutes} count=${result.count} ttl=${result.ttlMinutes}`
    : `nowait reason=${result.reason}`;
}

function retireLine(result) {
  return result.retired ? 'retired' : `kept reason=${result.reason}`;
}

function readStdin(maxBytes) {
  const raw = fs.readFileSync(0);
  if (raw.length > maxBytes) return null;
  return raw.toString('utf8');
}

function parsePayload(text) {
  if (typeof text !== 'string' || text === '') return null;
  try {
    const payload = JSON.parse(text);
    return isPlainObject(payload) ? payload : null;
  } catch {
    return null;
  }
}

function envOptions(env) {
  return {
    pluginData: env.ZENSU_BR_PLUGIN_DATA,
    sessionKey: env.ZENSU_BR_SESSION_KEY,
    stateFile: env.ZENSU_BR_STATE_FILE,
    envelope: env.ZENSU_BR_ENVELOPE,
    agentId: env.ZENSU_BR_AGENT,
  };
}

function main(argv, env = process.env, io = {}) {
  const mode = argv[0];
  const stdinText = io.stdin !== undefined ? io.stdin : null;
  const write = io.write || ((text) => process.stdout.write(text));
  const readInput = (max) => (stdinText !== null ? stdinText : readStdin(max));
  if (mode === 'record' || mode === 'fanout') {
    const writer = mode === 'record' ? recordLaunch : recordFanout;
    let result;
    try {
      const payload = parsePayload(readInput(LIMITS.maxPayloadBytes));
      result = payload ? writer(payload, envOptions(env)) : { recorded: false, reason: 'payload' };
    } catch {
      result = { recorded: false, reason: 'fault' };
    }
    write(`${recordLine(result)}\n`);
    return result.recorded ? 0 : 3;
  }
  if (mode === 'match') {
    let result;
    try {
      const payload = parsePayload(readInput(LIMITS.maxPayloadBytes));
      result = payload ? matchArrival(payload, envOptions(env)) : none('payload');
    } catch {
      result = none('fault');
    }
    write(`${matchLine(result)}\n`);
    return 0;
  }
  if (mode === 'retire') {
    let result;
    try {
      result = retireRecord(envOptions(env));
    } catch {
      result = { retired: false, reason: 'fault' };
    }
    write(`${retireLine(result)}\n`);
    return 0;
  }
  if (mode === 'wait') {
    let result;
    try {
      result = waitVerdict(envOptions(env));
    } catch {
      result = { wait: false, reason: 'fault' };
    }
    write(`${waitLine(result)}\n`);
    return 0;
  }
  process.stderr.write('usage: background-review-v1.js record|fanout|match|retire|wait\n');
  return 2;
}

module.exports = {
  SCHEMA,
  STORE_SEGMENTS,
  RECORDS_SEGMENT,
  FANOUT_SEGMENT,
  RECORD_KEYS,
  FANOUT_KEYS,
  FANOUT_TYPES,
  VERDICTS,
  ARRIVALS,
  WAIT_KINDS,
  ENVELOPES,
  LIMITS,
  AGENT_ID_RE,
  BackgroundReviewError,
  limitsWith,
  ttlMinutes,
  validateRecord,
  validateFanout,
  headerProblem,
  storeLocations,
  issuedTicket,
  headerFromPrompt,
  recordLaunch,
  recordFanout,
  scanPrompt,
  handbackReports,
  consumeRecord,
  matchArrival,
  retireRecord,
  waitVerdict,
  matchLine,
  recordLine,
  waitLine,
  retireLine,
  main,
};

if (require.main === module) {
  let code = 0;
  try {
    code = main(process.argv.slice(2));
  } catch {
    code = 2;
  }
  process.exitCode = code;
}
