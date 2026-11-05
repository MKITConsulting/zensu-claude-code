'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
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
const RUN_ID_EXACT_RE = /^wf_[a-z0-9-]{6,64}$/;
const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/;
const DIGEST_RE = /^[0-9a-f]{64}$/;
const META_NAME_RE = /export\s+const\s+meta\s*=\s*\{[\s\S]{0,4000}?\bname\s*:\s*(['"`])([^'"`\r\n]{1,128})\1/;
const SOURCES = Object.freeze(['script', 'script-path', 'named']);
const STATUSES = Object.freeze(['ok', 'degraded', 'stale', 'none', 'off', 'unavailable']);
const RUNNING_TASK_STATUSES = Object.freeze(['running', 'pending', 'queued', 'in_progress', 'in-progress', 'starting', 'started', 'active']);
const LOG_PREFIX = 'EXTERNAL REVIEW —';
const DEGRADED_PREFIX = 'EXTERNAL REVIEW DEGRADED —';
const TASK_ID_RE = /^[a-z0-9]{4,32}$/;
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
  'task_id',
  'transcript_dir',
]);
const RESULT_SCHEMA = 'zensu-review-result/v1';
const TEMPLATE_FILE = path.join(__dirname, '..', '..', 'templates', 'workflows', 'zensu-review-v1.js');
const STAGED_TEMPLATE_PREFIX = `${path.basename(TEMPLATE_FILE, '.js')}-`;
const RESULT_KEYS = Object.freeze(['agents', 'ceiling', 'dropped', 'findings', 'lenses', 'schema', 'tree']);
const RESULT_AGENT_KEYS = Object.freeze(['failed', 'finished', 'started']);
const RESULT_DROPPED_KEYS = Object.freeze(['count', 'kind', 'lens', 'reason']);
const RESULT_FINDING_KEYS = Object.freeze([
  'confidence',
  'duplicates',
  'evidence',
  'failure_scenario',
  'file',
  'fix',
  'id',
  'lens',
  'line',
  'severity',
  'title',
  'verification',
]);
const RESULT_VERIFICATION_KEYS = Object.freeze(['reason', 'status', 'votes']);
const RESULT_VOTE_KEYS = Object.freeze(['outcome', 'reasoning', 'severity', 'verifier']);
const DROPPED_KINDS = Object.freeze(['finder-failed', 'malformed-finding', 'over-cap', 'over-ceiling', 'over-budget']);
const VERIFICATION_STATUSES = Object.freeze(['upheld', 'refuted', 'unverified']);
const VOTE_OUTCOMES = Object.freeze(['real', 'not-real', 'failed']);
const SEVERITIES = Object.freeze(['CRITICAL', 'IMPORTANT', 'SUGGESTION']);
const LENS_RE = /^[a-z][a-z0-9-]{0,31}$/;
const FINDING_ID_RE = /^[a-z][a-z0-9-]{0,31}-[0-9]{1,4}$/;
const TREE_ID_RE = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
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
  clockSkewMs: 5 * 60 * 1000,
  listedTaskNames: 3,
  maxTranscriptDirChars: 4096,
  maxRunRecordBytes: 32 * 1024 * 1024,
  maxJournalBytes: 64 * 1024 * 1024,
  maxResultLenses: 32,
  maxResultCeiling: 1000,
  maxResultDropped: 512,
  maxResultFindings: 1000,
  maxResultDuplicates: 256,
  maxResultVotes: 8,
  maxResultText: 16 * 1024,
  maxReasonChars: 300,
  maxPrintedText: 2000,
});
const ROOT_ADVICE = Object.freeze({
  'nested-work-tree': () => "the review root is a separate git work tree nested inside this session's work tree, and a chain reviews one work tree; this review runs the aspect panel, and a workflow review of that work tree imports only in a session started in it",
  'nested-in-folder': () => "the review root is a git work tree inside this session's project folder, which is not a git work tree itself, and a chain reviews one root; this review runs the aspect panel, and a workflow review of that work tree imports only in a session started in it",
  outside: () => "the review root lies outside this session's work tree, where no reviewer of this session can read; this review runs the aspect panel, and a workflow review of that directory imports only in a session started in it",
  enclosing: (verdict) => `the review root encloses this session's work tree, so its tree and change times would not be this session's; re-run with --root set to ${verdict.rerun}`,
  subdirectory: (verdict) => `the review root lies below the root of this session's work tree, so its tree would cover only part of it; re-run with --root set to ${verdict.rerun}`,
  'unresolved-root': (verdict) => `the review root is not an absolute, symlink-free path to an existing directory; re-run with --root set to ${verdict.rerun}`,
  'unresolved-project-root': () => "this session's project root is not an absolute, symlink-free path to an existing directory; run /zensu:doctor",
  undetermined: (verdict) => (verdict.rerun
    ? `the work tree of the review root could not be determined, and a root other than this session's own is refused whatever its layout; re-run with --root set to ${verdict.rerun}`
    : "the work tree of this session's project root could not be determined; fix the cause the detail names and re-run"),
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
  if (!isIsoTimestamp(record.recorded_at) || record.recorded_at !== new Date(recordTime(record.id)).toISOString()) {
    return 'malformed record time';
  }
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
  if (!(record.run_id === null || (typeof record.run_id === 'string' && RUN_ID_EXACT_RE.test(record.run_id)))) {
    return 'malformed run id';
  }
  if (!nullableString(record.plugin_version, 64)) return 'malformed plugin version';
  if (!(record.task_id === null || (typeof record.task_id === 'string' && TASK_ID_RE.test(record.task_id)))) {
    return 'malformed task id';
  }
  if (!(record.transcript_dir === null || transcriptDirMatches(record.transcript_dir, record.run_id, limits))) {
    return 'malformed transcript dir';
  }
  return null;
}

function transcriptDirMatches(value, runId, limits = LIMITS) {
  return typeof value === 'string'
    && typeof runId === 'string'
    && value.length <= limits.maxTranscriptDirChars
    && !/[\0\r\n]/.test(value)
    && path.isAbsolute(value)
    && path.basename(value) === runId
    && path.basename(path.dirname(value)) === 'workflows';
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

function sweepStaleWaits(root, limits = LIMITS, now = Date.now()) {
  let swept = 0;
  const base = path.join(root, 'waits');
  let names;
  try { names = fs.readdirSync(base); } catch { return 0; }
  for (const name of names) {
    if (!/^scv1_[0-9a-f]{64}\.json$/.test(name)) continue;
    const file = path.join(base, name);
    try {
      if (now - fs.lstatSync(file).mtimeMs <= limits.waitTtlMs) continue;
      fs.rmSync(file, { force: true });
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

function isPlainObject(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function responseText(response, limits) {
  const strings = [];
  let budget = limits.maxResponseScanChars;
  const visit = (value, depth) => {
    if (budget <= 0 || depth > 4) return;
    if (typeof value === 'string') {
      strings.push(value.slice(0, budget));
      budget -= value.length;
      return;
    }
    if (Array.isArray(value)) {
      for (const entry of value.slice(0, 64)) visit(entry, depth + 1);
      return;
    }
    if (isPlainObject(value)) {
      for (const entry of Object.values(value).slice(0, 64)) visit(entry, depth + 1);
    }
  };
  visit(response, 0);
  return strings.join('\n');
}

function runIdFrom(response, limits) {
  if (response === undefined || response === null) return null;
  if (isPlainObject(response) && typeof response.runId === 'string' && RUN_ID_EXACT_RE.test(response.runId)) {
    return response.runId;
  }
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

function taskIdFrom(response, limits) {
  if (response === undefined || response === null) return null;
  if (isPlainObject(response) && typeof response.taskId === 'string') {
    return TASK_ID_RE.test(response.taskId) ? response.taskId : null;
  }
  const match = /\bTask ID:[ \t]*([a-z0-9]{4,32})\b/.exec(responseText(response, limits));
  return match ? match[1] : null;
}

function transcriptDirFrom(response, runId, limits) {
  if (runId === null || response === undefined || response === null) return null;
  let candidate = null;
  if (isPlainObject(response) && typeof response.transcriptDir === 'string') {
    candidate = response.transcriptDir;
  } else {
    const match = /\bTranscript dir:[ \t]*([^\r\n]+)/.exec(responseText(response, limits));
    candidate = match ? match[1].trim() : null;
  }
  return transcriptDirMatches(candidate, runId, limits) ? candidate : null;
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
  const runId = runIdFrom(payload.tool_response, limits);
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
    run_id: runId,
    task_id: taskIdFrom(payload.tool_response, limits),
    transcript_dir: transcriptDirFrom(payload.tool_response, runId, limits),
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
  const now = options.now === undefined ? Date.now() : options.now;
  const swept = sweepIdleSessions(locations.root, sessionKey, limits, now);
  sweepStaleWaits(locations.root, limits, now);
  return { outcome: 'recorded', id: record.id, pruned, swept };
}

function isInside(base, candidate) {
  const relative = path.relative(base, candidate);
  return relative === '' || (relative.split(path.sep)[0] !== '..' && !path.isAbsolute(relative));
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

function workTreeTopOf(directory) {
  let evidence;
  try {
    evidence = require('./evidence-run-v1.js');
  } catch {
    return { top: null, reason: 'tree-module' };
  }
  return evidence.workTreeTop(directory);
}

function resolveRoot(options) {
  const projectRoot = canonicalDirectoryOrNull(options.projectRoot);
  if (!projectRoot) return { layout: 'unresolved-project-root' };
  const topOf = options.topOf || workTreeTopOf;
  const own = topOf(projectRoot);
  if (own.reason) return { layout: 'undetermined', detail: own.reason };
  const anchor = own.top || projectRoot;
  const rerun = own.top ? 'the top level that git -C <project root> rev-parse --show-toplevel prints' : "this session's project root";
  const root = canonicalDirectoryOrNull(options.root);
  if (!root) return { layout: 'unresolved-root', rerun };
  if (root === anchor) return { root };
  if (isInside(root, anchor)) return { layout: 'enclosing', rerun };
  if (!isInside(anchor, root)) return { layout: 'outside' };
  const other = topOf(root);
  if (other.reason) return { layout: 'undetermined', detail: other.reason, rerun };
  if (other.top && other.top !== anchor) return { layout: own.top ? 'nested-work-tree' : 'nested-in-folder' };
  return { layout: 'subdirectory', rerun };
}

function rootRefusal(verdict) {
  const detail = verdict.detail ? ` detail=${token(verdict.detail)}` : '';
  return `reason=root layout=${verdict.layout}${detail} — ${ROOT_ADVICE[verdict.layout](verdict)}`;
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

function changeTime(stat) {
  return Math.max(stat.mtimeMs, stat.ctimeMs);
}

function nearestParentTime(root, relative) {
  let current = path.dirname(path.join(root, relative));
  while (isInside(root, current)) {
    try {
      return changeTime(fs.lstatSync(current));
    } catch (error) {
      if (!error || (error.code !== 'ENOENT' && error.code !== 'ENOTDIR')) return null;
    }
    if (current === root) break;
    current = path.dirname(current);
  }
  return null;
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
        const parent = nearestParentTime(root, relative);
        if (parent === null) return { error: 'unreadable-path' };
        newest = Math.max(newest, parent);
        continue;
      }
      return { error: 'unreadable-path' };
    }
    existing += 1;
    newest = Math.max(newest, changeTime(stat));
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
  return `launch ${record.id} ${record.recorded_at} ${record.name || '(unnamed)'} source=${record.source} ${scriptPart} run=${record.run_id || 'none'} task=${record.task_id || 'none'} ${fresh ? 'fresh' : 'stale'}`;
}

function exactKeys(value, keys) {
  if (!isPlainObject(value)) return false;
  const actual = Object.keys(value).sort();
  return actual.length === keys.length && actual.every((key, index) => key === keys[index]);
}

function boundedText(value, max, allowEmpty = true) {
  return typeof value === 'string' && value.length <= max && (allowEmpty || value.trim() !== '') && !value.includes('\0');
}

function isCount(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

function validateResultFinding(finding, lenses, limits) {
  if (!exactKeys(finding, RESULT_FINDING_KEYS)) return 'unexpected finding key set';
  if (typeof finding.id !== 'string' || !FINDING_ID_RE.test(finding.id)) return 'malformed finding id';
  if (!lenses.includes(finding.lens) || !finding.id.startsWith(`${finding.lens}-`)) return 'a finding of a lens that was not reviewed';
  if (!boundedText(finding.title, limits.maxResultText, false)) return 'malformed finding title';
  if (!SEVERITIES.includes(finding.severity)) return 'malformed finding severity';
  if (!boundedText(finding.file, 1024) || /[\r\n]/.test(finding.file)) return 'malformed finding file';
  if (!isCount(finding.line)) return 'malformed finding line';
  for (const key of ['evidence', 'failure_scenario', 'fix']) {
    if (!boundedText(finding[key], limits.maxResultText)) return `malformed finding ${key}`;
  }
  if (!Number.isInteger(finding.confidence) || finding.confidence < 0 || finding.confidence > 100) return 'malformed finding confidence';
  if (!Array.isArray(finding.duplicates) || finding.duplicates.length > limits.maxResultDuplicates
    || finding.duplicates.some((id) => typeof id !== 'string' || !FINDING_ID_RE.test(id))) {
    return 'malformed finding duplicates';
  }
  const verification = finding.verification;
  if (!exactKeys(verification, RESULT_VERIFICATION_KEYS) || !VERIFICATION_STATUSES.includes(verification.status)
    || !boundedText(verification.reason, limits.maxReasonChars)) {
    return 'malformed verification';
  }
  if (!Array.isArray(verification.votes) || verification.votes.length > limits.maxResultVotes) return 'malformed votes';
  for (const vote of verification.votes) {
    if (!exactKeys(vote, RESULT_VOTE_KEYS) || !boundedText(vote.verifier, 32, false) || !VOTE_OUTCOMES.includes(vote.outcome)
      || !(vote.severity === '' || SEVERITIES.includes(vote.severity)) || !boundedText(vote.reasoning, limits.maxResultText)) {
      return 'malformed vote';
    }
  }
  if (verification.status === 'upheld' && !verification.votes.some((vote) => vote.outcome === 'real')) {
    return 'an upheld finding without a real vote';
  }
  if (verification.status === 'refuted' && !verification.votes.some((vote) => vote.outcome === 'not-real')) {
    return 'a refuted finding without a not-real vote';
  }
  return null;
}

function validateReviewResult(result, limits = LIMITS) {
  if (!exactKeys(result, RESULT_KEYS)) return 'unexpected key set';
  if (result.schema !== RESULT_SCHEMA) return 'unknown schema';
  if (typeof result.tree !== 'string' || !TREE_ID_RE.test(result.tree)) return 'malformed tree';
  if (!Array.isArray(result.lenses) || result.lenses.length === 0 || result.lenses.length > limits.maxResultLenses
    || result.lenses.some((lens) => typeof lens !== 'string' || !LENS_RE.test(lens))
    || new Set(result.lenses).size !== result.lenses.length) {
    return 'malformed lenses';
  }
  if (!Number.isSafeInteger(result.ceiling) || result.ceiling < result.lenses.length || result.ceiling > limits.maxResultCeiling) {
    return 'malformed ceiling';
  }
  const agents = result.agents;
  if (!exactKeys(agents, RESULT_AGENT_KEYS) || !isCount(agents.started) || !isCount(agents.finished) || !isCount(agents.failed)) {
    return 'malformed agent counts';
  }
  if (agents.finished + agents.failed !== agents.started) return 'agent counts that do not add up';
  if (agents.started > result.ceiling) return 'more agents than the ceiling';
  if (!Array.isArray(result.dropped) || result.dropped.length > limits.maxResultDropped) return 'malformed dropped list';
  for (const entry of result.dropped) {
    if (!exactKeys(entry, RESULT_DROPPED_KEYS) || !DROPPED_KINDS.includes(entry.kind) || !result.lenses.includes(entry.lens)
      || !isCount(entry.count) || !boundedText(entry.reason, limits.maxReasonChars)) {
      return 'malformed dropped entry';
    }
  }
  if (!Array.isArray(result.findings) || result.findings.length > limits.maxResultFindings) return 'malformed findings list';
  const ids = new Set();
  for (const finding of result.findings) {
    const problem = validateResultFinding(finding, result.lenses, limits);
    if (problem) return problem;
    if (ids.has(finding.id)) return 'a duplicate finding id';
    ids.add(finding.id);
  }
  return null;
}

function runRecordPath(record) {
  if (record.run_id === null || record.transcript_dir === null) return null;
  const subagents = path.dirname(path.dirname(record.transcript_dir));
  if (path.basename(subagents) !== 'subagents') return null;
  return path.join(path.dirname(subagents), 'workflows', `${record.run_id}.json`);
}

function readRunRecord(record, limits = LIMITS) {
  const file = runRecordPath(record);
  if (file === null) return { problem: 'launch-unbound' };
  const loaded = readBoundedFile(file, limits.maxRunRecordBytes);
  if (loaded.invalid) {
    return { problem: loaded.invalid === 'oversized' ? 'run-record-oversized' : 'run-record-unreadable', detail: loaded.invalid };
  }
  let parsed;
  try {
    parsed = JSON.parse(loaded.text);
  } catch {
    return { problem: 'run-record-unparseable' };
  }
  if (!isPlainObject(parsed)) return { problem: 'run-record-unparseable' };
  if (parsed.runId !== record.run_id || (record.task_id !== null && parsed.taskId !== record.task_id)) {
    return { problem: 'run-record-mismatch' };
  }
  if (parsed.status !== 'completed') return { problem: 'run-not-completed', detail: `run-status-${token(parsed.status)}` };
  return { script: parsed.script, args: parsed.args, result: parsed.result, progress: parsed.workflowProgress };
}

function launchedFiles(args) {
  let value = args;
  if (typeof value === 'string') {
    try {
      value = JSON.parse(value);
    } catch {
      return null;
    }
  }
  if (!isPlainObject(value) || !Array.isArray(value.changedFiles)) return null;
  return new Set(value.changedFiles
    .filter((entry) => typeof entry === 'string')
    .map((entry) => entry.trim().replaceAll('\\', '/').replace(/^\.\//, '')));
}

function journalCounts(transcriptDir, limits = LIMITS) {
  if (typeof transcriptDir !== 'string' || transcriptDir === '') return { problem: 'no-transcript-dir' };
  const loaded = readBoundedFile(path.join(transcriptDir, 'journal.jsonl'), limits.maxJournalBytes);
  if (loaded.invalid) return { problem: 'journal-unreadable' };
  const latest = new Map();
  const outcomes = new Map();
  let launched = false;
  for (const line of loaded.text.split('\n')) {
    if (line.trim() === '') continue;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      return { problem: 'journal-unparseable' };
    }
    if (!isPlainObject(entry)) return { problem: 'journal-unparseable' };
    if (entry.type === 'launched') {
      launched = true;
    } else if (entry.type === 'started') {
      if (typeof entry.label !== 'string' || typeof entry.agentId !== 'string') return { problem: 'journal-unparseable' };
      latest.set(entry.label, entry.agentId);
    } else if (entry.type === 'result' || entry.type === 'failed') {
      if (typeof entry.agentId !== 'string') return { problem: 'journal-unparseable' };
      outcomes.set(entry.agentId, entry.type);
    }
  }
  if (!launched) return { problem: 'journal-without-launch' };
  let finished = 0;
  let failed = 0;
  let lost = 0;
  for (const agentId of latest.values()) {
    const outcome = outcomes.get(agentId);
    if (outcome === 'result') finished += 1;
    else if (outcome === 'failed') failed += 1;
    else lost += 1;
  }
  return { started: latest.size, finished, failed: failed + lost, lost };
}

function progressCounts(progress) {
  if (!Array.isArray(progress)) return { problem: 'no-progress' };
  const latest = new Map();
  for (const entry of progress) {
    if (!isPlainObject(entry) || entry.type !== 'workflow_agent') continue;
    if (typeof entry.label !== 'string' || typeof entry.state !== 'string') return { problem: 'progress-unparseable' };
    const attempt = Number.isSafeInteger(entry.attempt) ? entry.attempt : 0;
    const previous = latest.get(entry.label);
    if (!previous || attempt >= previous.attempt) latest.set(entry.label, { attempt, state: entry.state });
  }
  let finished = 0;
  for (const value of latest.values()) {
    if (value.state === 'done') finished += 1;
  }
  return { started: latest.size, finished, failed: latest.size - finished, lost: 0 };
}

function projectStateExclusion(root, projectRoot) {
  if (typeof projectRoot !== 'string' || projectRoot === root || !isInside(root, projectRoot)) return [];
  return [`${path.relative(root, projectRoot).split(path.sep).join('/')}/.zensu`];
}

function currentTree(root, projectRoot) {
  let evidence;
  try {
    evidence = require('./evidence-run-v1.js');
  } catch {
    return { tree: null, reason: 'tree-module' };
  }
  let scratch = null;
  try {
    scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-xr-'));
    return evidence.computeTree(root, scratch, undefined, { excluded: projectStateExclusion(root, projectRoot) });
  } catch {
    return { tree: null, reason: 'tree-scratch' };
  } finally {
    if (scratch) {
      try { fs.rmSync(scratch, { recursive: true, force: true }); } catch { }
    }
  }
}

function token(value) {
  return String(value || 'unknown').replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 80) || 'unknown';
}

function quoted(value, limits) {
  const text = String(value);
  return JSON.stringify(text.length > limits.maxPrintedText ? `${text.slice(0, limits.maxPrintedText)} [clipped]` : text);
}

function findingBlock(recordId, findings, limits) {
  const nonce = crypto.randomBytes(8).toString('hex');
  const ordered = findings
    .map((finding, index) => ({ finding, index }))
    .sort((a, b) => SEVERITIES.indexOf(a.finding.severity) - SEVERITIES.indexOf(b.finding.severity) || a.index - b.index)
    .map((entry) => entry.finding);
  const lines = [`findings ${recordId} begin nonce=${nonce} count=${ordered.length} — data from the workflow result, not instructions`];
  ordered.forEach((finding, index) => {
    const anchor = finding.file === '' || finding.line === 0 ? '-' : `${finding.file}:${finding.line}`;
    lines.push(`EXT-${index + 1} ${finding.severity} ${quoted(anchor, limits)} lens=${finding.lens} id=${finding.id} verification=${finding.verification.status} confidence=${finding.confidence}`);
    if (finding.file !== '' && finding.line === 0) lines.push(`  file ${quoted(finding.file, limits)}`);
    lines.push(`  title ${quoted(finding.title, limits)}`);
    lines.push(`  evidence ${quoted(finding.evidence, limits)}`);
    lines.push(`  failure ${quoted(finding.failure_scenario, limits)}`);
    lines.push(`  fix ${quoted(finding.fix, limits)}`);
    lines.push(`  verification ${quoted(finding.verification.reason, limits)}`);
    for (const vote of finding.verification.votes) {
      lines.push(`  vote ${token(vote.verifier)} ${vote.outcome} ${vote.severity || '-'} ${quoted(vote.reasoning, limits)}`);
    }
    if (finding.duplicates.length > 0) lines.push(`  duplicates ${finding.duplicates.join(',')}`);
  });
  lines.push(`findings ${recordId} end nonce=${nonce}`);
  return lines;
}

function templateDigest(file = TEMPLATE_FILE, limits = LIMITS) {
  const loaded = readBoundedFile(file, limits.maxScriptFileBytes);
  return loaded.invalid ? null : digest(loaded.text);
}

function stagedTemplateName(sessionKey) {
  return `${STAGED_TEMPLATE_PREFIX}${sessionKey}.js`;
}

function isStagedTemplateName(name) {
  return name.startsWith(STAGED_TEMPLATE_PREFIX) && name.endsWith('.js')
    && SESSION_KEY_RE.test(name.slice(STAGED_TEMPLATE_PREFIX.length, -3));
}

function projectStateDirectory(projectRoot) {
  let current = projectRoot;
  for (const segment of core.WORKFLOW_STATE_SEGMENTS) {
    current = path.join(current, segment);
    try {
      fs.mkdirSync(current, { mode: 0o700 });
    } catch (error) {
      if (!error || error.code !== 'EEXIST') return null;
    }
    let stat;
    try {
      stat = fs.lstatSync(current);
    } catch {
      return null;
    }
    if (stat.isSymbolicLink() || !stat.isDirectory()) return null;
  }
  return canonicalDirectoryOrNull(current);
}

function sweepStagedTemplates(directory, keep, limits, now) {
  let names;
  try {
    names = fs.readdirSync(directory);
  } catch {
    return 0;
  }
  let swept = 0;
  for (const name of names) {
    if (name === keep || !isStagedTemplateName(name)) continue;
    try {
      const file = path.join(directory, name);
      const stat = fs.lstatSync(file);
      if (!stat.isFile() || now - stat.mtimeMs <= limits.idleSessionMs) continue;
      fs.unlinkSync(file);
      swept += 1;
    } catch { }
  }
  return swept;
}

function stageUnavailable(reason) {
  return { status: 'unavailable', reason, line: `${LOG_PREFIX} stage=unavailable reason=${reason}` };
}

function stageTemplate(options, limits = LIMITS) {
  if (!options.enabled) return stageUnavailable('disabled');
  if (options.judge === false) return stageUnavailable('review-judge-disabled');
  const placed = resolveRoot(options);
  if (placed.layout) return { status: 'unavailable', reason: 'root', line: `${LOG_PREFIX} stage=unavailable ${rootRefusal(placed)}` };
  const root = placed.root;
  const projectRoot = canonicalDirectoryOrNull(options.projectRoot);
  if (typeof options.sessionKey !== 'string' || !SESSION_KEY_RE.test(options.sessionKey)) return stageUnavailable('session');
  const current = (options.treeOf || currentTree)(root, projectRoot);
  if (!current || typeof current.tree !== 'string' || !TREE_ID_RE.test(current.tree)) {
    return stageUnavailable(token(current && current.reason));
  }
  const template = readBoundedFile(options.templateFile || TEMPLATE_FILE, limits.maxScriptFileBytes);
  if (template.invalid) return stageUnavailable('template-unreadable');
  const directory = projectStateDirectory(projectRoot);
  if (!directory) return stageUnavailable('state-directory');
  const name = stagedTemplateName(options.sessionKey);
  let script;
  try {
    script = writeFileAtomic(directory, name, template.text);
  } catch {
    return stageUnavailable('write-failed');
  }
  const staged = readBoundedFile(script, limits.maxScriptFileBytes);
  if (staged.invalid || digest(staged.text) !== digest(template.text)) return stageUnavailable('digest-mismatch');
  sweepStagedTemplates(directory, name, limits, options.now === undefined ? Date.now() : options.now);
  return { status: 'ok', tree: current.tree, script, line: `${LOG_PREFIX} stage=ok tree=${current.tree} script=${script}` };
}

function judgeResult(record, options, limits) {
  const expected = templateDigest(options.templateFile || TEMPLATE_FILE, limits);
  if (expected === null) return { status: 'unavailable', reason: 'template-unreadable' };
  if (record.script_sha256 !== expected) return { status: 'unavailable', reason: 'foreign-script' };
  if (typeof options.resultFile === 'string' && options.resultFile !== ''
    && (record.task_id === null || path.basename(options.resultFile) !== `${record.task_id}.output`)) {
    return { status: 'unavailable', reason: 'result-not-from-launch', detail: record.task_id === null ? 'no-task-id' : `expected ${record.task_id}.output` };
  }
  const run = readRunRecord(record, limits);
  if (run.problem) return { status: 'unavailable', reason: run.problem, detail: run.detail };
  if (typeof run.script !== 'string' || digest(run.script) !== expected) {
    return { status: 'unavailable', reason: 'foreign-script', detail: 'the run record holds another script' };
  }
  const problem = validateReviewResult(run.result, limits);
  if (problem) return { status: 'unavailable', reason: 'foreign-shape', detail: problem };
  const result = run.result;
  const current = (options.treeOf || currentTree)(options.root, options.projectRoot);
  let treeState = 'unverified';
  if (current && typeof current.tree === 'string' && TREE_ID_RE.test(current.tree)) {
    if (current.tree !== result.tree) {
      return { status: 'stale', reason: 'tree', detail: `result-${result.tree.slice(0, 12)}-current-${current.tree.slice(0, 12)}` };
    }
    treeState = 'match';
  }
  const launched = launchedFiles(run.args);
  if (launched === null) return { status: 'unavailable', reason: 'launch-args', detail: 'the run arguments name no changedFiles list' };
  const unreviewed = (options.changedPaths || []).filter((relative) => !launched.has(relative.replaceAll('\\', '/')));
  if (unreviewed.length > 0) {
    return { status: 'unavailable', reason: 'files-not-reviewed', detail: `${unreviewed.length}-changed-files-not-in-the-run-arguments` };
  }
  const reasons = [];
  let runtime = journalCounts(record.transcript_dir, limits);
  let runtimeSource = 'journal';
  if (runtime.problem) {
    const fromProgress = progressCounts(run.progress);
    runtime = fromProgress.problem ? null : fromProgress;
    runtimeSource = fromProgress.problem ? 'none' : 'run-record';
  }
  const agents = result.agents;
  if (runtime === null) reasons.push('runtime-unverifiable');
  else if (runtime.started !== agents.started || runtime.finished !== agents.finished || runtime.failed !== agents.failed) {
    reasons.push('agent-count-mismatch');
  }
  const failed = runtime === null ? agents.failed : Math.max(runtime.failed, agents.failed);
  const started = runtime === null ? agents.started : Math.max(runtime.started, agents.started);
  if (failed > 0) reasons.push('agents-failed');
  const gaps = result.dropped.filter((entry) => entry.kind === 'finder-failed');
  if (gaps.length > 0) reasons.push('finder-failed');
  return {
    status: reasons.length > 0 ? 'degraded' : 'ok',
    reasons,
    summary: `result=${RESULT_SCHEMA} lenses=${result.lenses.join(',')} tree=${treeState} runtime=${runtimeSource} agents=${agents.finished}/${agents.started} findings=${result.findings.length} dropped=${result.dropped.length}`,
    degradedLine: reasons.length > 0 ? `${DEGRADED_PREFIX} ${failed} of ${started} agents failed; ${reasons.join(', ')}` : null,
    gapLines: gaps.map((entry) => `gap ${entry.lens} finder-failed — ${quoted(entry.reason, limits)}`),
    result,
  };
}

function check(options, limits = LIMITS) {
  if (!options.enabled) {
    return { status: 'off', lines: [`${LOG_PREFIX} status=off reason=disabled — hooks.externalReviewImport is false`] };
  }
  if (options.judge === false) {
    return { status: 'off', lines: [`${LOG_PREFIX} status=off reason=review-judge-disabled — the import needs the judge, and hooks.reviewJudge is false`] };
  }
  if (options.changedText === null) return unavailable('change-set-too-large');
  if (typeof options.sessionKey !== 'string' || !SESSION_KEY_RE.test(options.sessionKey)) return unavailable('session');
  if (typeof options.pluginData !== 'string' || options.pluginData === '') return unavailable('plugin-data');
  const placed = resolveRoot(options);
  if (placed.layout) return { status: 'unavailable', lines: [`${LOG_PREFIX} status=unavailable ${rootRefusal(placed)}`] };
  const root = placed.root;
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
  const horizon = (options.now === undefined ? Date.now() : options.now) + limits.clockSkewMs;
  const valid = entries.filter((entry) => entry.record && recordTime(entry.id) <= horizon).reverse();
  const skipped = entries.length - valid.length;
  const counts = `changed=${changes.existing} missing=${changes.missing} excluded=${parsed.excluded} skipped=${skipped}`;
  if (valid.length === 0) {
    return { status: 'none', lines: [`${LOG_PREFIX} status=none launches=0/0 ${counts}`] };
  }
  const isFresh = (entry) => recordTime(entry.id) > changes.newest;
  const fresh = valid.filter(isFresh);
  const status = fresh.length > 0 ? 'ok' : 'stale';
  const launchLabel = (record) => `${record.name || '(unnamed)'}@${record.recorded_at}`;
  const lines = [
    `${LOG_PREFIX} status=stale launches=0/${valid.length} newest=${launchLabel(valid[0].record)} last-change=${iso(changes.newest)} ${counts}`,
  ];
  for (const entry of valid.slice(0, limits.listedLaunches)) lines.push(launchLine(entry, isFresh(entry)));
  if (valid.length > limits.listedLaunches) lines.push(`launches-not-listed ${valid.length - limits.listedLaunches}`);
  if (status !== 'ok') return { status, lines };
  let selected = fresh[0];
  const resultName = typeof options.resultFile === 'string' && options.resultFile !== '' ? path.basename(options.resultFile) : null;
  const byResult = resultName === null ? [] : fresh.filter((entry) => entry.record.task_id !== null && `${entry.record.task_id}.output` === resultName);
  if (options.launch) {
    selected = fresh.find((entry) => entry.id === options.launch);
    if (!selected) return unavailable('launch-not-fresh');
  } else if (fresh.length > 1 && byResult.length === 1) {
    selected = byResult[0];
  } else if (fresh.length > 1) {
    lines[0] = `${LOG_PREFIX} status=unavailable reason=ambiguous-launch launches=${fresh.length}/${valid.length} last-change=${iso(changes.newest)} ${counts} — re-run with --launch <id> of the launch whose task id names the output file you hold`;
    return { status: 'unavailable', lines };
  }
  const head = `launches=${fresh.length}/${valid.length} selected=${launchLabel(selected.record)} id=${selected.id} last-change=${iso(changes.newest)} ${counts}`;
  const verdict = judgeResult(selected.record, { ...options, root, projectRoot: canonicalDirectoryOrNull(options.projectRoot), changedPaths: parsed.paths }, limits);
  if (verdict.status !== 'ok' && verdict.status !== 'degraded') {
    lines[0] = `${LOG_PREFIX} status=${verdict.status} reason=${verdict.reason} ${head}${verdict.detail ? ` detail=${token(verdict.detail)}` : ''}`;
    return { status: verdict.status, lines };
  }
  const reasonPart = verdict.status === 'degraded' ? ` reason=${verdict.reasons.join(',')}` : '';
  lines[0] = `${LOG_PREFIX} status=${verdict.status}${reasonPart} ${head} ${verdict.summary}`;
  if (verdict.degradedLine) lines.splice(1, 0, verdict.degradedLine);
  lines.push(...verdict.gapLines);
  lines.push(...findingBlock(selected.id, verdict.result.findings, limits));
  return { status: verdict.status, lines, selected: selected.id };
}

function inFlightWorkflows(payload) {
  const tasks = payload && Array.isArray(payload.background_tasks) ? payload.background_tasks : [];
  return tasks.filter((task) => task
    && typeof task === 'object'
    && task.type === 'workflow'
    && typeof task.status === 'string'
    && RUNNING_TASK_STATUSES.includes(task.status.toLowerCase()));
}

function clearWait(options) {
  if (typeof options.sessionKey !== 'string' || !SESSION_KEY_RE.test(options.sessionKey)) return false;
  if (typeof options.pluginData !== 'string' || options.pluginData === '') return false;
  try {
    fs.rmSync(path.join(options.pluginData, ...STORE_SEGMENTS, 'waits', `${options.sessionKey}.json`), { force: true });
    return true;
  } catch {
    return false;
  }
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
  if (workflows.length === 0) {
    clearWait(options);
    return { wait: false, reason: 'none', workflows: 0, line: 'nowait reason=none workflows=0' };
  }
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
    sweepStaleWaits(locations.root, limits, now);
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
        judge: env.ZENSU_XR_JUDGE !== '0',
        pluginData: env.ZENSU_XR_PLUGIN_DATA,
        sessionKey: env.ZENSU_XR_SESSION_KEY,
        projectRoot: env.ZENSU_XR_PROJECT_ROOT,
        root: env.ZENSU_XR_ROOT,
        launch: env.ZENSU_XR_LAUNCH || '',
        resultFile: env.ZENSU_XR_RESULT || '',
        changedText: env.ZENSU_XR_ENABLED === '0' || env.ZENSU_XR_JUDGE === '0' ? '' : readInput(LIMITS.maxChangedBytes),
      });
    } catch {
      result = unavailable('fault');
    }
    for (const line of result.lines) write(`${line}\n`);
    return 0;
  }
  if (mode === 'tree') {
    let line;
    try {
      if (env.ZENSU_XR_ENABLED === '0') {
        line = `${LOG_PREFIX} tree=unavailable reason=disabled`;
      } else if (env.ZENSU_XR_JUDGE === '0') {
        line = `${LOG_PREFIX} tree=unavailable reason=review-judge-disabled`;
      } else {
        const placed = resolveRoot({ root: env.ZENSU_XR_ROOT, projectRoot: env.ZENSU_XR_PROJECT_ROOT });
        if (placed.layout) {
          line = `${LOG_PREFIX} tree=unavailable ${rootRefusal(placed)}`;
        } else {
          const current = currentTree(placed.root, canonicalDirectoryOrNull(env.ZENSU_XR_PROJECT_ROOT));
          line = current && typeof current.tree === 'string' && TREE_ID_RE.test(current.tree)
            ? `${LOG_PREFIX} tree=${current.tree}`
            : `${LOG_PREFIX} tree=unavailable reason=${token(current && current.reason)}`;
        }
      }
    } catch {
      line = `${LOG_PREFIX} tree=unavailable reason=fault`;
    }
    write(`${line}\n`);
    return 0;
  }
  if (mode === 'stage') {
    let line;
    try {
      line = stageTemplate({
        enabled: env.ZENSU_XR_ENABLED !== '0',
        judge: env.ZENSU_XR_JUDGE !== '0',
        sessionKey: env.ZENSU_XR_SESSION_KEY,
        projectRoot: env.ZENSU_XR_PROJECT_ROOT,
        root: env.ZENSU_XR_ROOT,
      }).line;
    } catch {
      line = `${LOG_PREFIX} stage=unavailable reason=fault`;
    }
    write(`${line}\n`);
    return 0;
  }
  if (mode === 'stop-wait') {
    let result;
    try {
      const payload = parsePayload(readInput(LIMITS.maxPayloadBytes));
      result = stopWait(payload || {}, {
        pluginData: env.ZENSU_XR_PLUGIN_DATA,
        sessionKey: env.ZENSU_XR_SESSION_KEY,
      });
    } catch {
      result = { line: 'nowait reason=fault workflows=0' };
    }
    write(`${result.line}\n`);
    return 0;
  }
  process.stderr.write('usage: external-review-v1.js record|check|tree|stage|stop-wait\n');
  return 2;
}

module.exports = {
  SCHEMA,
  STORE_SEGMENTS,
  SOURCES,
  STATUSES,
  RECORD_KEYS,
  RESULT_SCHEMA,
  TEMPLATE_FILE,
  RESULT_KEYS,
  DROPPED_KINDS,
  LIMITS,
  LOG_PREFIX,
  DEGRADED_PREFIX,
  RUNNING_TASK_STATUSES,
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
  sweepStaleWaits,
  buildRecord,
  recordLaunch,
  parseChangedPaths,
  resolveRoot,
  newestChangeTime,
  validateReviewResult,
  templateDigest,
  stagedTemplateName,
  stageTemplate,
  runRecordPath,
  readRunRecord,
  journalCounts,
  progressCounts,
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
