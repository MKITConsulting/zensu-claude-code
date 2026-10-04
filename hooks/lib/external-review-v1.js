'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { ensurePrivateDirectory } = require('./review-evidence-lease-v1.js');
const { validateSessionId } = require('./claude-hook-session-v1.js');
const { PRINCIPALS, classifyPreToolPayload } = require('./claude-principal-v1.js');
const core = require('./session-control-core-v1.js');

const SCHEMA = 'external-review-v1';
const STORE_SEGMENTS = Object.freeze(['external-review', 'v1']);
const ID_RE = /^xr1_[0-9]{13}_[0-9a-f]{12}$/;
const RECORD_FILE_RE = /^xr1_[0-9]{13}_[0-9a-f]{12}\.json$/;
const SESSION_KEY_RE = /^scv1_[0-9a-f]{64}$/;
const RUN_ID_RE = /\bwf_[a-z0-9-]{6,64}\b/;
const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/;
const DIGEST_RE = /^[0-9a-f]{64}$/;
const META_NAME_RE = /export\s+const\s+meta\s*=\s*\{[\s\S]{0,4000}?\bname\s*:\s*(['"`])([^'"`\r\n]{1,128})\1/;
const SOURCES = Object.freeze(['script', 'script-path', 'named']);
const STATUSES = Object.freeze(['ok', 'stale', 'none', 'off', 'unavailable']);
const TERMINAL_TASK_STATUSES = Object.freeze(['completed', 'complete', 'done', 'failed', 'killed', 'stopped', 'cancelled', 'canceled', 'error']);
const LOG_PREFIX = 'EXTERNAL REVIEW —';
const RECORD_KEYS = Object.freeze([
  'args',
  'args_truncated',
  'id',
  'name',
  'plugin_version',
  'recorded_at',
  'run_id',
  'schema',
  'script',
  'script_sha256',
  'script_truncated',
  'session_key',
  'source',
]);
const LIMITS = Object.freeze({
  maxPayloadBytes: 4 * 1024 * 1024,
  maxScriptChars: 64 * 1024,
  maxScriptFileBytes: 512 * 1024,
  maxArgsChars: 8 * 1024,
  maxResponseScanChars: 256 * 1024,
  maxRecordBytes: 768 * 1024,
  maxRecordsPerSession: 64,
  idleSessionMs: 14 * 24 * 60 * 60 * 1000,
  maxChangedPaths: 5000,
  maxChangedBytes: 4 * 1024 * 1024,
  listedLaunches: 8,
  maxWaits: 3,
  waitTtlMs: 24 * 60 * 60 * 1000,
  listedTaskNames: 3,
});

class ExternalReviewError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ExternalReviewError';
  }
}

function fail(message) {
  throw new ExternalReviewError(message);
}

function limitsWith(overrides) {
  return Object.freeze({ ...LIMITS, ...(overrides || {}) });
}

function newRecordId(now = Date.now()) {
  if (!Number.isInteger(now) || now < 0 || now > 9999999999999) fail('clock value out of range');
  return `xr1_${String(now).padStart(13, '0')}_${crypto.randomBytes(6).toString('hex')}`;
}

function recordTime(id) {
  return Number(id.slice(4, 17));
}

function screenName(value) {
  return typeof value === 'string' && NAME_RE.test(value) ? value : null;
}

function readPluginVersion() {
  try {
    const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', '.claude-plugin', 'plugin.json'), 'utf8'));
    return typeof manifest.version === 'string' && manifest.version.length <= 64 ? manifest.version : null;
  } catch {
    return null;
  }
}

function storeLocations(pluginData, sessionKey) {
  if (typeof sessionKey !== 'string' || !SESSION_KEY_RE.test(sessionKey)) fail('invalid session key');
  let root;
  try {
    root = ensurePrivateDirectory(pluginData, STORE_SEGMENTS);
  } catch (error) {
    fail(`external review store unavailable: ${error.message}`);
  }
  return {
    root,
    records: ensurePrivateDirectory(root, ['records', sessionKey]),
  };
}

function waitLocations(pluginData) {
  let root;
  try {
    root = ensurePrivateDirectory(pluginData, STORE_SEGMENTS);
  } catch (error) {
    fail(`external review store unavailable: ${error.message}`);
  }
  return { root, waits: ensurePrivateDirectory(root, ['waits']) };
}

function isIsoTimestamp(value) {
  return typeof value === 'string' && value.length <= 40 && !Number.isNaN(Date.parse(value));
}

function nullableString(value, max) {
  return value === null || (typeof value === 'string' && value.length <= max);
}

function validateRecord(record, expected = {}, limits = LIMITS) {
  if (!record || typeof record !== 'object' || Array.isArray(record)) return 'not an object';
  const keys = Object.keys(record).sort();
  if (keys.length !== RECORD_KEYS.length || keys.some((key, index) => key !== RECORD_KEYS[index])) {
    return 'unexpected key set';
  }
  if (record.schema !== SCHEMA) return 'unknown schema';
  if (typeof record.id !== 'string' || !ID_RE.test(record.id)) return 'malformed id';
  if (expected.id !== undefined && record.id !== expected.id) return 'id does not match its file name';
  if (typeof record.session_key !== 'string' || !SESSION_KEY_RE.test(record.session_key)) return 'malformed session key';
  if (expected.sessionKey !== undefined && record.session_key !== expected.sessionKey) return 'bound to another session';
  if (!isIsoTimestamp(record.recorded_at)) return 'malformed record time';
  if (!(record.name === null || screenName(record.name) !== null)) return 'malformed name';
  if (!SOURCES.includes(record.source)) return 'unknown source';
  if (!nullableString(record.script, limits.maxScriptChars)) return 'malformed script';
  if (!(record.script_sha256 === null || (typeof record.script_sha256 === 'string' && DIGEST_RE.test(record.script_sha256)))) {
    return 'malformed script digest';
  }
  if ((record.script === null) !== (record.script_sha256 === null)) return 'script and digest disagree';
  if (typeof record.script_truncated !== 'boolean') return 'malformed script truncation flag';
  if (!nullableString(record.args, limits.maxArgsChars)) return 'malformed args';
  if (typeof record.args_truncated !== 'boolean') return 'malformed args truncation flag';
  if (!(record.run_id === null || (typeof record.run_id === 'string' && RUN_ID_RE.test(record.run_id) && record.run_id.length <= 67))) {
    return 'malformed run id';
  }
  if (!nullableString(record.plugin_version, 64)) return 'malformed plugin version';
  return null;
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

function writeRecordAtomic(directory, record, limits = LIMITS) {
  const problem = validateRecord(record, {}, limits);
  if (problem) fail(`refusing to write an invalid record: ${problem}`);
  return writeFileAtomic(directory, `${record.id}.json`, `${JSON.stringify(record)}\n`);
}

function readBoundedFile(filePath, maxBytes) {
  let descriptor;
  try {
    const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0) | (fs.constants.O_NONBLOCK || 0);
    descriptor = fs.openSync(filePath, flags);
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile()) return { invalid: 'not a regular file' };
    if (stat.size > maxBytes) return { invalid: 'oversized', size: stat.size };
    const buffer = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < stat.size) {
      const read = fs.readSync(descriptor, buffer, offset, stat.size - offset, offset);
      if (read === 0) break;
      offset += read;
    }
    return { text: buffer.subarray(0, offset).toString('utf8') };
  } catch (error) {
    return { invalid: `unreadable (${error && error.code ? error.code : 'error'})` };
  } finally {
    if (descriptor !== undefined) {
      try { fs.closeSync(descriptor); } catch { }
    }
  }
}

function listRecords(directory, expected, limits = LIMITS) {
  const names = fs.readdirSync(directory).filter((name) => RECORD_FILE_RE.test(name)).sort();
  return names.map((name) => {
    const id = name.slice(0, -5);
    const loaded = readBoundedFile(path.join(directory, name), limits.maxRecordBytes);
    if (loaded.invalid) return { id, record: null, invalid: loaded.invalid };
    let record;
    try {
      record = JSON.parse(loaded.text);
    } catch {
      return { id, record: null, invalid: 'unparseable' };
    }
    const problem = validateRecord(record, { ...expected, id }, limits);
    if (problem) return { id, record: null, invalid: problem };
    return { id, record, invalid: null };
  });
}

function prune(directory, limits = LIMITS) {
  let names;
  try {
    names = fs.readdirSync(directory).filter((name) => RECORD_FILE_RE.test(name)).sort();
  } catch {
    return 0;
  }
  let removed = 0;
  for (const name of names.slice(0, Math.max(0, names.length - limits.maxRecordsPerSession))) {
    try { fs.unlinkSync(path.join(directory, name)); removed += 1; } catch { }
  }
  return removed;
}

function newestMtime(directory) {
  let newest = 0;
  try {
    newest = fs.statSync(directory).mtimeMs;
    for (const name of fs.readdirSync(directory)) {
      try { newest = Math.max(newest, fs.lstatSync(path.join(directory, name)).mtimeMs); } catch { }
    }
  } catch { }
  return newest;
}

function sweepIdleSessions(root, currentSessionKey, limits = LIMITS, now = Date.now()) {
  let swept = 0;
  const base = path.join(root, 'records');
  let names;
  try { names = fs.readdirSync(base); } catch { return 0; }
  for (const name of names) {
    if (!SESSION_KEY_RE.test(name) || name === currentSessionKey) continue;
    const directory = path.join(base, name);
    try {
      if (fs.lstatSync(directory).isSymbolicLink()) continue;
    } catch { continue; }
    if (now - newestMtime(directory) <= limits.idleSessionMs) continue;
    try {
      fs.rmSync(directory, { recursive: true, force: true });
      swept += 1;
    } catch { }
  }
  return swept;
}

function clip(text, max) {
  if (text.length <= max) return { text, truncated: false };
  return { text: text.slice(0, max), truncated: true };
}

function digest(text) {
  return crypto.createHash('sha256').update(text, 'utf8').digest('hex');
}

function scriptFromPath(scriptPath, cwd, limits) {
  if (typeof scriptPath !== 'string' || scriptPath === '' || /[\0\r\n]/.test(scriptPath)) return null;
  let resolved = scriptPath;
  if (!path.isAbsolute(resolved)) {
    if (typeof cwd !== 'string' || !path.isAbsolute(cwd)) return null;
    resolved = path.resolve(cwd, resolved);
  }
  const loaded = readBoundedFile(resolved, limits.maxScriptFileBytes);
  return loaded.invalid ? null : loaded.text;
}

function workflowName(toolInput, script) {
  const named = screenName(toolInput.name);
  if (named) return named;
  if (typeof script !== 'string') return null;
  const match = META_NAME_RE.exec(script.slice(0, 8192));
  return match ? screenName(match[2]) : null;
}

function runIdFrom(response, limits) {
  if (response === undefined || response === null) return null;
  let text;
  try {
    text = typeof response === 'string' ? response : JSON.stringify(response);
  } catch {
    return null;
  }
  if (typeof text !== 'string') return null;
  const match = RUN_ID_RE.exec(text.slice(0, limits.maxResponseScanChars));
  return match ? match[0] : null;
}

function argsText(args, limits) {
  if (args === undefined || args === null) return { text: null, truncated: false };
  let text;
  try {
    text = typeof args === 'string' ? args : JSON.stringify(args);
  } catch {
    return { text: null, truncated: false };
  }
  if (typeof text !== 'string') return { text: null, truncated: false };
  return clip(text, limits.maxArgsChars);
}

function buildRecord(payload, sessionKey, options = {}) {
  const limits = options.limits || LIMITS;
  const now = options.now === undefined ? Date.now() : options.now;
  const toolInput = payload.tool_input && typeof payload.tool_input === 'object' && !Array.isArray(payload.tool_input)
    ? payload.tool_input
    : {};
  let source = 'named';
  let fullScript = null;
  if (typeof toolInput.script === 'string' && toolInput.script !== '') {
    source = 'script';
    fullScript = toolInput.script;
  } else if (typeof toolInput.scriptPath === 'string' && toolInput.scriptPath !== '') {
    source = 'script-path';
    fullScript = scriptFromPath(toolInput.scriptPath, payload.cwd, limits);
  }
  const script = fullScript === null ? { text: null, truncated: false } : clip(fullScript, limits.maxScriptChars);
  const args = argsText(toolInput.args, limits);
  const id = newRecordId(now);
  return {
    schema: SCHEMA,
    id,
    session_key: sessionKey,
    recorded_at: new Date(recordTime(id)).toISOString(),
    name: workflowName(toolInput, fullScript),
    source,
    script: script.text,
    script_sha256: fullScript === null ? null : digest(fullScript),
    script_truncated: script.truncated,
    args: args.text,
    args_truncated: args.truncated,
    run_id: runIdFrom(payload.tool_response, limits),
    plugin_version: readPluginVersion(),
  };
}

function recordLaunch(payload, env = process.env, options = {}) {
  const limits = options.limits || LIMITS;
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return { outcome: 'skipped', reason: 'payload' };
  if (payload.hook_event_name !== undefined && payload.hook_event_name !== 'PostToolUse') {
    return { outcome: 'skipped', reason: 'event' };
  }
  if (payload.tool_name !== 'Workflow') return { outcome: 'skipped', reason: 'tool' };
  if (classifyPreToolPayload(payload) !== PRINCIPALS.MAIN) return { outcome: 'skipped', reason: 'principal' };
  try {
    validateSessionId(payload.session_id);
  } catch {
    return { outcome: 'skipped', reason: 'session' };
  }
  const pluginData = env.CLAUDE_PLUGIN_DATA;
  if (typeof pluginData !== 'string' || pluginData === '') return { outcome: 'skipped', reason: 'plugin-data' };
  const sessionKey = core.sessionKey(payload.session_id);
  const locations = storeLocations(pluginData, sessionKey);
  const record = buildRecord(payload, sessionKey, { limits, now: options.now });
  writeRecordAtomic(locations.records, record, limits);
  const pruned = prune(locations.records, limits);
  const swept = sweepIdleSessions(locations.root, sessionKey, limits, options.now === undefined ? Date.now() : options.now);
  return { outcome: 'recorded', id: record.id, pruned, swept };
}

function isInside(base, candidate) {
  const relative = path.relative(base, candidate);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function canonicalDirectoryOrNull(value) {
  if (typeof value !== 'string' || value === '' || /[\0\r\n]/.test(value) || !path.isAbsolute(value)) return null;
  try {
    const canonical = fs.realpathSync.native(value);
    if (canonical !== path.resolve(value)) return null;
    const stat = fs.lstatSync(canonical);
    return stat.isDirectory() && !stat.isSymbolicLink() ? canonical : null;
  } catch {
    return null;
  }
}

function existingRecordsDirectory(pluginData, sessionKey) {
  let current;
  try {
    current = fs.realpathSync.native(pluginData);
  } catch {
    return { state: 'unsafe', reason: 'plugin-data' };
  }
  for (const segment of [...STORE_SEGMENTS, 'records', sessionKey]) {
    current = path.join(current, segment);
    let stat;
    try {
      stat = fs.lstatSync(current);
    } catch (error) {
      if (error && error.code === 'ENOENT') return { state: 'absent' };
      return { state: 'unsafe', reason: 'store-unreadable' };
    }
    if (stat.isSymbolicLink() || !stat.isDirectory()) return { state: 'unsafe', reason: 'store-unsafe' };
    if (process.platform !== 'win32') {
      if ((stat.mode & 0o077) !== 0) return { state: 'unsafe', reason: 'store-permissions' };
      if (typeof process.getuid === 'function' && stat.uid !== process.getuid()) {
        return { state: 'unsafe', reason: 'store-ownership' };
      }
    }
  }
  return { state: 'present', directory: current };
}

function parseChangedPaths(text, limits = LIMITS) {
  if (typeof text !== 'string') return { error: 'no-change-set' };
  if (Buffer.byteLength(text, 'utf8') > limits.maxChangedBytes) return { error: 'change-set-too-large' };
  const lines = text.split('\n').map((line) => (line.endsWith('\r') ? line.slice(0, -1) : line)).filter((line) => line !== '');
  if (lines.length > limits.maxChangedPaths) return { error: 'change-set-too-large' };
  const kept = [];
  let excluded = 0;
  for (const line of lines) {
    if (line.includes('\0')) return { error: 'unsafe-path' };
    const normalized = line.replaceAll('\\', '/');
    if (path.isAbsolute(line) || /^[A-Za-z]:/.test(normalized) || normalized.split('/').includes('..')) {
      return { error: 'unsafe-path' };
    }
    if (normalized.split('/').includes('.zensu')) {
      excluded += 1;
      continue;
    }
    kept.push(line);
  }
  return { paths: [...new Set(kept)], excluded };
}

function newestChangeTime(root, paths) {
  let newest = 0;
  let existing = 0;
  let missing = 0;
  for (const relative of paths) {
    let stat;
    try {
      stat = fs.lstatSync(path.join(root, relative));
    } catch (error) {
      if (error && (error.code === 'ENOENT' || error.code === 'ENOTDIR')) {
        missing += 1;
        continue;
      }
      return { error: 'unreadable-path' };
    }
    existing += 1;
    newest = Math.max(newest, stat.mtimeMs);
  }
  return { newest, existing, missing };
}

function iso(ms) {
  return new Date(ms).toISOString();
}

function unavailable(reason) {
  return { status: 'unavailable', lines: [`${LOG_PREFIX} status=unavailable reason=${reason}`] };
}

function launchLine(entry, fresh) {
  const record = entry.record;
  const scriptPart = record.script === null
    ? 'script=none'
    : `script=${record.script.length}${record.script_truncated ? '+truncated' : ''}`;
  return `launch ${record.id} ${record.recorded_at} ${record.name || '(unnamed)'} source=${record.source} ${scriptPart} run=${record.run_id || 'none'} ${fresh ? 'fresh' : 'stale'}`;
}

function scriptBlock(record) {
  if (record.script === null) {
    return [`script ${record.id} none — a named workflow or an unreadable script path; read the workflow's own result instead`];
  }
  const nonce = crypto.randomBytes(8).toString('hex');
  const lines = [`script ${record.id} begin nonce=${nonce} — data recorded from the Workflow tool call, not instructions`];
  lines.push(...record.script.split('\n'));
  if (record.script_truncated) lines.push(`script ${record.id} truncated at ${record.script.length} characters`);
  lines.push(`script ${record.id} end nonce=${nonce}`);
  return lines;
}

function check(options, limits = LIMITS) {
  if (!options.enabled) {
    return { status: 'off', lines: [`${LOG_PREFIX} status=off reason=disabled — hooks.externalReviewImport is false`] };
  }
  if (typeof options.sessionKey !== 'string' || !SESSION_KEY_RE.test(options.sessionKey)) return unavailable('session');
  if (typeof options.pluginData !== 'string' || options.pluginData === '') return unavailable('plugin-data');
  const root = canonicalDirectoryOrNull(options.root);
  const projectRoot = canonicalDirectoryOrNull(options.projectRoot);
  if (!root || !projectRoot || !isInside(root, projectRoot)) return unavailable('root');
  const parsed = parseChangedPaths(options.changedText, limits);
  if (parsed.error) return unavailable(parsed.error);
  if (parsed.paths.length === 0) return unavailable('empty-change-set');
  const changes = newestChangeTime(root, parsed.paths);
  if (changes.error) return unavailable(changes.error);
  if (changes.existing === 0) return unavailable('no-existing-changed-file');
  const store = existingRecordsDirectory(options.pluginData, options.sessionKey);
  if (store.state === 'unsafe') return unavailable(store.reason);
  let entries = [];
  if (store.state === 'present') {
    try {
      entries = listRecords(store.directory, { sessionKey: options.sessionKey }, limits);
    } catch {
      return unavailable('store-unreadable');
    }
  }
  const valid = entries.filter((entry) => entry.record).reverse();
  const skipped = entries.length - valid.length;
  const counts = `changed=${changes.existing} missing=${changes.missing} excluded=${parsed.excluded} skipped=${skipped}`;
  if (valid.length === 0) {
    return { status: 'none', lines: [`${LOG_PREFIX} status=none launches=0/0 ${counts}`] };
  }
  const isFresh = (entry) => recordTime(entry.id) > changes.newest;
  const fresh = valid.filter(isFresh);
  const status = fresh.length > 0 ? 'ok' : 'stale';
  const newest = (fresh.length > 0 ? fresh : valid)[0].record;
  const lines = [
    `${LOG_PREFIX} status=${status} launches=${fresh.length}/${valid.length} newest=${newest.name || '(unnamed)'}@${newest.recorded_at} last-change=${iso(changes.newest)} ${counts}`,
  ];
  for (const entry of valid.slice(0, limits.listedLaunches)) lines.push(launchLine(entry, isFresh(entry)));
  if (valid.length > limits.listedLaunches) lines.push(`launches-not-listed ${valid.length - limits.listedLaunches}`);
  if (status !== 'ok') return { status, lines };
  let selected = fresh[0];
  if (options.launch) {
    selected = fresh.find((entry) => entry.id === options.launch);
    if (!selected) return unavailable('launch-not-fresh');
  }
  lines.push(...scriptBlock(selected.record));
  return { status, lines, selected: selected.id };
}

function inFlightWorkflows(payload) {
  const tasks = payload && Array.isArray(payload.background_tasks) ? payload.background_tasks : [];
  return tasks.filter((task) => task
    && typeof task === 'object'
    && task.type === 'workflow'
    && !(typeof task.status === 'string' && TERMINAL_TASK_STATUSES.includes(task.status.toLowerCase())));
}

function readWaitCount(file, limits, now) {
  const loaded = readBoundedFile(file, 4096);
  if (loaded.invalid) return 0;
  try {
    const state = JSON.parse(loaded.text);
    if (!state || typeof state !== 'object' || !Number.isSafeInteger(state.count) || state.count < 0) return 0;
    if (!isIsoTimestamp(state.updated_at) || now - Date.parse(state.updated_at) > limits.waitTtlMs) return 0;
    return state.count;
  } catch {
    return 0;
  }
}

function stopWait(payload, options, limits = LIMITS) {
  const workflows = inFlightWorkflows(payload);
  if (workflows.length === 0) return { wait: false, reason: 'none', workflows: 0, line: 'nowait reason=none workflows=0' };
  const names = [...new Set(workflows.map((task) => screenName(task.name)).filter(Boolean))].slice(0, limits.listedTaskNames);
  const nameText = names.length ? names.join(',') : '(unnamed)';
  if (typeof options.sessionKey !== 'string' || !SESSION_KEY_RE.test(options.sessionKey)) {
    return { wait: false, reason: 'fault', workflows: workflows.length, line: `nowait reason=fault workflows=${workflows.length}` };
  }
  const now = options.now === undefined ? Date.now() : options.now;
  let file;
  let count;
  try {
    const locations = waitLocations(options.pluginData);
    file = path.join(locations.waits, `${options.sessionKey}.json`);
    count = readWaitCount(file, limits, now);
  } catch {
    return { wait: false, reason: 'fault', workflows: workflows.length, line: `nowait reason=fault workflows=${workflows.length}` };
  }
  const max = Number.isSafeInteger(options.max) && options.max >= 0 ? options.max : limits.maxWaits;
  if (count >= max) {
    return { wait: false, reason: 'limit', workflows: workflows.length, line: `nowait reason=limit workflows=${workflows.length} count=${count} max=${max}` };
  }
  try {
    writeFileAtomic(path.dirname(file), path.basename(file), `${JSON.stringify({ count: count + 1, updated_at: iso(now) })}\n`);
  } catch {
    return { wait: false, reason: 'fault', workflows: workflows.length, line: `nowait reason=fault workflows=${workflows.length}` };
  }
  return {
    wait: true,
    count: count + 1,
    max,
    workflows: workflows.length,
    names,
    line: `wait count=${count + 1} max=${max} workflows=${workflows.length} names=${nameText}`,
  };
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
    return payload && typeof payload === 'object' && !Array.isArray(payload) ? payload : null;
  } catch {
    return null;
  }
}

function main(argv, env = process.env, io = {}) {
  const mode = argv[0];
  const stdinText = io.stdin !== undefined ? io.stdin : null;
  const write = io.write || ((text) => process.stdout.write(text));
  const readInput = (max) => (stdinText !== null ? stdinText : readStdin(max));
  if (mode === 'record') {
    try {
      const payload = parsePayload(readInput(LIMITS.maxPayloadBytes));
      if (payload) recordLaunch(payload, env);
    } catch { }
    return 0;
  }
  if (mode === 'check') {
    let result;
    try {
      result = check({
        enabled: env.ZENSU_XR_ENABLED !== '0',
        pluginData: env.ZENSU_XR_PLUGIN_DATA,
        sessionKey: env.ZENSU_XR_SESSION_KEY,
        projectRoot: env.ZENSU_XR_PROJECT_ROOT,
        root: env.ZENSU_XR_ROOT,
        launch: env.ZENSU_XR_LAUNCH || '',
        changedText: env.ZENSU_XR_ENABLED === '0' ? '' : readInput(LIMITS.maxChangedBytes + 1),
      });
    } catch {
      result = unavailable('fault');
    }
    for (const line of result.lines) write(`${line}\n`);
    return 0;
  }
  if (mode === 'stop-wait') {
    let result;
    try {
      const payload = parsePayload(readInput(LIMITS.maxPayloadBytes));
      result = stopWait(payload || {}, {
        pluginData: env.ZENSU_XR_PLUGIN_DATA,
        sessionKey: env.ZENSU_XR_SESSION_KEY,
        max: env.ZENSU_XR_MAX_WAITS === undefined ? undefined : Number(env.ZENSU_XR_MAX_WAITS),
      });
    } catch {
      result = { line: 'nowait reason=fault workflows=0' };
    }
    write(`${result.line}\n`);
    return 0;
  }
  process.stderr.write('usage: external-review-v1.js record|check|stop-wait\n');
  return 2;
}

module.exports = {
  SCHEMA,
  STORE_SEGMENTS,
  SOURCES,
  STATUSES,
  RECORD_KEYS,
  LIMITS,
  LOG_PREFIX,
  TERMINAL_TASK_STATUSES,
  ExternalReviewError,
  limitsWith,
  newRecordId,
  screenName,
  storeLocations,
  validateRecord,
  writeRecordAtomic,
  listRecords,
  prune,
  sweepIdleSessions,
  buildRecord,
  recordLaunch,
  parseChangedPaths,
  newestChangeTime,
  check,
  inFlightWorkflows,
  stopWait,
  main,
};

if (require.main === module) {
  let code = 0;
  try {
    code = main(process.argv.slice(2));
  } catch {
    code = process.argv[2] === 'record' ? 0 : 2;
  }
  process.exitCode = code;
}
