'use strict';

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const childProcess = require('node:child_process');
const { ensurePrivateDirectory } = require('./review-evidence-lease-v1.js');
const { redact, defaultHome } = require('./zensu-artifact-redact-v1.js');
const { scan } = require('./secret-patterns.js');

const SCHEMA = 'evidence-run-v1';
const STORE_SEGMENTS = Object.freeze(['evidence-run', 'v1']);
const SCOPES = Object.freeze(['full', 'lint', 'build', 'coverage', 'scoped', 'acceptance']);
const TREE_SCOPES = Object.freeze(['full', 'scoped', 'acceptance']);
const TEST_SCOPES = Object.freeze(['full', 'scoped']);
const RECORD_STATES = Object.freeze(['running', 'completed', 'interrupted']);
const GATE_MODES = Object.freeze(['required', 'advisory']);
const VERDICT_STATES = Object.freeze([
  'pass',
  'pass-tree-unverified',
  'deferred-ci',
  'running',
  'failed',
  'interrupted',
  'stale',
  'mutated-during-run',
  'missing',
  'command-mismatch',
  'invalid',
  'unavailable',
  'not-applicable',
  'escaped',
]);
const PASSING_STATES = Object.freeze(['pass', 'pass-tree-unverified', 'deferred-ci', 'not-applicable', 'escaped']);
const ID_RE = /^er1_[0-9]{13}_[0-9a-f]{12}$/;
const RECORD_FILE_RE = /^er1_[0-9]{13}_[0-9a-f]{12}\.json$/;
const LOG_FILE_RE = /^er1_[0-9]{13}_[0-9a-f]{12}\.log$/;
const SESSION_KEY_RE = /^scv1_[0-9a-f]{64}$/;
const TREE_RE = /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/;
const NO_WORK_TREE_RE = /not a git repository|cannot change to|must be run in a work tree/i;
const LEADING_CD_RE = /^\s*\(?\s*cd\s+(?:'([^']*)'|"([^"$`\\]*)"|([^\s'"$`\\;&|()<>*?[\]{}!#~-][^\s'"$`\\;&|()<>*?[\]{}!#]*))\s*(?:&&|;|\n)/;
const RECORD_KEYS = Object.freeze([
  'command',
  'cwd',
  'duration_ms',
  'exit_code',
  'finished_at',
  'id',
  'log_bytes',
  'log_truncated',
  'pid',
  'plugin_version',
  'project_root',
  'schema',
  'scope',
  'session_key',
  'signal',
  'started_at',
  'state',
  'tree_end',
  'tree_end_reason',
  'tree_start',
  'tree_start_reason',
]);
const LIMITS = Object.freeze({
  maxRecordBytes: 256 * 1024,
  maxCommandBytes: 64 * 1024,
  maxRecordsPerSession: 40,
  idleSessionMs: 14 * 24 * 60 * 60 * 1000,
  maxLogBytes: 5 * 1024 * 1024,
  tailLines: 80,
  tailReadBytes: 256 * 1024,
  displayMax: 200,
  listedPaths: 10,
  untrackedMaxFiles: 20000,
  untrackedMaxBytes: 512 * 1024 * 1024,
  gitTimeoutMs: 120000,
  killGraceMs: 2000,
  maxRunMs: 12 * 60 * 60 * 1000,
});
const GIT_SCRUBBED_ENV = Object.freeze([
  'GIT_DIR',
  'GIT_WORK_TREE',
  'GIT_INDEX_FILE',
  'GIT_COMMON_DIR',
  'GIT_OBJECT_DIRECTORY',
  'GIT_ALTERNATE_OBJECT_DIRECTORIES',
  'GIT_CEILING_DIRECTORIES',
  'GIT_DISCOVERY_ACROSS_FILESYSTEM',
  'GIT_NAMESPACE',
  'GIT_PREFIX',
  'GIT_CONFIG',
  'GIT_CONFIG_GLOBAL',
  'GIT_CONFIG_SYSTEM',
  'GIT_CONFIG_COUNT',
  'GIT_CONFIG_PARAMETERS',
]);
const CHILD_SCRUBBED_ENV = Object.freeze([
  'ZENSU_CLAUDE_PLUGIN_ROOT',
  'ZENSU_SESSION_KEY',
  'ZENSU_SESSION_CONTEXT',
  'ZENSU_RUNTIME_DIGEST',
  'ZENSU_PROJECT_ROOT',
  'ZENSU_OWN_CMD',
  'CLAUDE_PLUGIN_DATA',
  'CLAUDE_PLUGIN_ROOT',
  'CLAUDE_PROJECT_DIR',
]);
const TRANSPORT_PREFIX = 'ZENSU_EVR_';
const WITHHELD = '[withheld: the command text matches a secret pattern]';

class EvidenceRunError extends Error {
  constructor(message) {
    super(message);
    this.name = 'EvidenceRunError';
  }
}

function fail(message) {
  throw new EvidenceRunError(message);
}

function limitsWith(overrides) {
  return Object.freeze({ ...LIMITS, ...(overrides || {}) });
}

function newRecordId(now = Date.now()) {
  if (!Number.isInteger(now) || now < 0 || now > 9999999999999) fail('clock value out of range');
  return `er1_${String(now).padStart(13, '0')}_${crypto.randomBytes(6).toString('hex')}`;
}

function storeLocations(pluginData, sessionKey) {
  if (typeof sessionKey !== 'string' || !SESSION_KEY_RE.test(sessionKey)) fail('invalid session key');
  let root;
  try {
    root = ensurePrivateDirectory(pluginData, STORE_SEGMENTS);
  } catch (error) {
    fail(`evidence store unavailable: ${error.message}`);
  }
  return {
    root,
    records: ensurePrivateDirectory(root, ['records', sessionKey]),
    logs: ensurePrivateDirectory(root, ['logs', sessionKey]),
    scratch: ensurePrivateDirectory(root, ['scratch']),
  };
}

function isIsoTimestamp(value) {
  return typeof value === 'string' && value.length <= 40 && !Number.isNaN(Date.parse(value));
}

function nullableString(value, max) {
  return value === null || (typeof value === 'string' && value.length <= max);
}

function nullableInteger(value, min, max) {
  return value === null || (Number.isInteger(value) && value >= min && value <= max);
}

function validateRecord(record, expected = {}) {
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
  if (typeof record.project_root !== 'string' || record.project_root === '') return 'malformed project root';
  if (expected.projectRoot !== undefined && record.project_root !== expected.projectRoot) return 'bound to another project root';
  if (!SCOPES.includes(record.scope)) return 'unknown scope';
  if (typeof record.command !== 'string' || record.command === '' || Buffer.byteLength(record.command) > LIMITS.maxCommandBytes) {
    return 'malformed command';
  }
  if (typeof record.cwd !== 'string' || record.cwd === '') return 'malformed cwd';
  if (!RECORD_STATES.includes(record.state)) return 'unknown state';
  if (!Number.isInteger(record.pid) || record.pid <= 0) return 'malformed pid';
  if (!isIsoTimestamp(record.started_at)) return 'malformed start time';
  if (!(record.finished_at === null || isIsoTimestamp(record.finished_at))) return 'malformed finish time';
  if (!nullableInteger(record.duration_ms, 0, Number.MAX_SAFE_INTEGER)) return 'malformed duration';
  if (!nullableInteger(record.exit_code, 0, 999)) return 'malformed exit code';
  if (!nullableString(record.signal, 32)) return 'malformed signal';
  for (const key of ['tree_start', 'tree_end']) {
    if (!(record[key] === null || (typeof record[key] === 'string' && TREE_RE.test(record[key])))) return `malformed ${key}`;
  }
  for (const key of ['tree_start_reason', 'tree_end_reason']) {
    if (!nullableString(record[key], 400)) return `malformed ${key}`;
  }
  if (!nullableString(record.plugin_version, 64)) return 'malformed plugin version';
  if (!nullableInteger(record.log_bytes, 0, Number.MAX_SAFE_INTEGER)) return 'malformed log size';
  if (typeof record.log_truncated !== 'boolean') return 'malformed log truncation flag';
  if (record.state === 'running') {
    if (record.finished_at !== null || record.exit_code !== null || record.duration_ms !== null) return 'running record carries a result';
  } else {
    if (record.finished_at === null || record.duration_ms === null) return 'finished record carries no finish time';
    if (record.state === 'completed' && record.exit_code === null) return 'completed record carries no exit code';
  }
  return null;
}

function readRecordFile(filePath, limits = LIMITS) {
  let descriptor;
  try {
    const before = fs.lstatSync(filePath);
    if (before.isSymbolicLink()) return { invalid: 'unreadable (symlink)' };
    const noFollow = process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW) ? fs.constants.O_NOFOLLOW : 0;
    const flags = fs.constants.O_RDONLY | noFollow | (fs.constants.O_NONBLOCK || 0);
    descriptor = fs.openSync(filePath, flags);
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile()) return { invalid: 'not a regular file' };
    if (stat.dev !== before.dev || stat.ino !== before.ino) return { invalid: 'unreadable (replaced)' };
    if (stat.size > limits.maxRecordBytes) return { invalid: 'oversized' };
    const buffer = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < stat.size) {
      const read = fs.readSync(descriptor, buffer, offset, stat.size - offset, offset);
      if (read === 0) break;
      offset += read;
    }
    return { record: JSON.parse(buffer.subarray(0, offset).toString('utf8')) };
  } catch (error) {
    if (error && error.code) return { invalid: `unreadable (${error.code})` };
    return { invalid: 'unparseable' };
  } finally {
    if (descriptor !== undefined) {
      try { fs.closeSync(descriptor); } catch { }
    }
  }
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

function writeRecordAtomic(directory, record) {
  const problem = validateRecord(record);
  if (problem) fail(`refusing to write an invalid record: ${problem}`);
  const target = path.join(directory, `${record.id}.json`);
  const temporary = path.join(directory, `.${record.id}.${crypto.randomBytes(6).toString('hex')}.tmp`);
  const descriptor = fs.openSync(temporary, 'wx', 0o600);
  try {
    fs.writeFileSync(descriptor, `${JSON.stringify(record)}\n`);
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

function listRecords(locations, expected, limits = LIMITS) {
  let names;
  try {
    names = fs.readdirSync(locations.records);
  } catch (error) {
    fail(`evidence records unreadable: ${error.code || error.message}`);
  }
  return names
    .filter((name) => RECORD_FILE_RE.test(name))
    .sort()
    .map((name) => {
      const id = name.slice(0, -5);
      const loaded = readRecordFile(path.join(locations.records, name), limits);
      if (loaded.invalid) return { id, record: null, invalid: loaded.invalid };
      const problem = validateRecord(loaded.record, { ...expected, id });
      if (problem) return { id, record: null, invalid: problem };
      return { id, record: loaded.record, invalid: null };
    });
}

function gitEnvironment(extra) {
  const env = { ...process.env };
  for (const name of GIT_SCRUBBED_ENV) delete env[name];
  env.GIT_OPTIONAL_LOCKS = '0';
  env.LC_ALL = 'C';
  env.LANG = 'C';
  delete env.LANGUAGE;
  env.GIT_TERMINAL_PROMPT = '0';
  return { ...env, ...(extra || {}) };
}

function git(root, args, options = {}) {
  const result = childProcess.spawnSync('git', ['-C', root, ...args], {
    env: gitEnvironment(options.env),
    encoding: options.encoding === 'buffer' ? 'buffer' : 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    timeout: options.timeoutMs || LIMITS.gitTimeoutMs,
    windowsHide: true,
    input: options.input,
    stdio: [options.input === undefined ? 'ignore' : 'pipe', 'pipe', 'pipe'],
  });
  if (result.error) return { ok: false, reason: result.error.code === 'ETIMEDOUT' ? 'git timed out' : `git unavailable (${result.error.code || result.error.message})` };
  if (result.status !== 0) {
    const stderr = String(result.stderr || '').trim().split('\n')[0] || `exit ${result.status}`;
    return { ok: false, reason: `git ${args[0]} failed: ${stderr.slice(0, 160)}` };
  }
  return { ok: true, stdout: result.stdout };
}

function workTree(projectRoot, limits = LIMITS) {
  const result = childProcess.spawnSync('git', ['-C', projectRoot, 'rev-parse', '--is-inside-work-tree'], {
    env: gitEnvironment(),
    encoding: 'utf8',
    timeout: limits.gitTimeoutMs,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error && result.error.code === 'ENOENT') return { applicable: false, reason: 'git is not installed' };
  if (result.error) {
    return { applicable: null, reason: result.error.code === 'ETIMEDOUT' ? 'git timed out' : `git unavailable (${result.error.code || result.error.message})` };
  }
  if (result.status === 0) {
    return String(result.stdout).trim() === 'true'
      ? { applicable: true, reason: null }
      : { applicable: false, reason: 'the project root is not inside a git work tree' };
  }
  const stderr = String(result.stderr || '');
  if (/not a git repository/i.test(stderr)) return { applicable: false, reason: 'the project is not a git repository' };
  return { applicable: null, reason: `git rev-parse failed: ${(stderr.trim().split('\n')[0] || `exit ${result.status}`).slice(0, 160)}` };
}

function runDirectory(projectRoot, requested, limits = LIMITS) {
  if (!requested) return { cwd: projectRoot, moved: false };
  const anchor = git(projectRoot, ['rev-parse', '--show-toplevel'], { timeoutMs: limits.gitTimeoutMs });
  const top = anchor.ok ? anchor.stdout.trim() : '';
  if (top !== '') {
    const here = git(requested, ['rev-parse', '--show-toplevel'], { timeoutMs: limits.gitTimeoutMs });
    return here.ok && here.stdout.trim() === top ? { cwd: requested, moved: false } : { cwd: projectRoot, moved: true };
  }
  const relative = path.relative(projectRoot, requested);
  if (relative === '' || (relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative))) {
    return { cwd: requested, moved: false };
  }
  return { cwd: projectRoot, moved: true };
}

function computeTree(projectRoot, scratchDirectory, limits = LIMITS) {
  const inside = git(projectRoot, ['rev-parse', '--is-inside-work-tree']);
  if (!inside.ok || inside.stdout.trim() !== 'true') return { tree: null, reason: 'not a git work tree' };
  const prefix = git(projectRoot, ['rev-parse', '--show-prefix']);
  if (!prefix.ok) return { tree: null, reason: prefix.reason };
  const indexPath = git(projectRoot, ['rev-parse', '--path-format=absolute', '--git-path', 'index']);
  if (!indexPath.ok) return { tree: null, reason: indexPath.reason };
  const untracked = git(projectRoot, ['ls-files', '--others', '--exclude-standard', '-z', '--', '.', ':(exclude).zensu'], { encoding: 'buffer' });
  if (!untracked.ok) return { tree: null, reason: untracked.reason };
  const untrackedPaths = untracked.stdout.toString('utf8').split('\0').filter(Boolean);
  if (untrackedPaths.length > limits.untrackedMaxFiles) {
    return { tree: null, reason: `more than ${limits.untrackedMaxFiles} untracked files` };
  }
  let untrackedBytes = 0;
  for (const relative of untrackedPaths) {
    try {
      untrackedBytes += fs.lstatSync(path.join(projectRoot, relative)).size;
    } catch { }
    if (untrackedBytes > limits.untrackedMaxBytes) {
      return { tree: null, reason: `untracked files exceed ${Math.round(limits.untrackedMaxBytes / (1024 * 1024))} MiB` };
    }
  }
  const temporaryIndex = path.join(scratchDirectory, `index-${process.pid}-${crypto.randomBytes(6).toString('hex')}`);
  try {
    const source = indexPath.stdout.trim();
    if (source && fs.existsSync(source)) {
      const indexStat = fs.statSync(source);
      fs.copyFileSync(source, temporaryIndex);
      fs.utimesSync(temporaryIndex, indexStat.atime, indexStat.mtime);
    }
    const env = { GIT_INDEX_FILE: temporaryIndex };
    const added = git(projectRoot, ['add', '-A', '--', '.'], { env });
    if (!added.ok) return { tree: null, reason: added.reason };
    const pruned = git(projectRoot, ['rm', '-r', '-f', '--cached', '--ignore-unmatch', '-q', '--', '.zensu'], { env });
    if (!pruned.ok) return { tree: null, reason: pruned.reason };
    const relativePrefix = prefix.stdout.trim();
    const written = git(projectRoot, relativePrefix ? ['write-tree', `--prefix=${relativePrefix}`] : ['write-tree'], { env });
    if (!written.ok) return { tree: null, reason: written.reason };
    const tree = written.stdout.trim();
    if (!TREE_RE.test(tree)) return { tree: null, reason: 'git write-tree returned no tree id' };
    return { tree, reason: null };
  } catch (error) {
    return { tree: null, reason: `tree fingerprint failed (${error.code || error.message})` };
  } finally {
    for (const leftover of [temporaryIndex, `${temporaryIndex}.lock`]) {
      try { fs.unlinkSync(leftover); } catch { }
    }
  }
}

function commandDirectory(command, cwd) {
  if (typeof command !== 'string' || typeof cwd !== 'string' || cwd === '') return cwd;
  const match = LEADING_CD_RE.exec(command);
  if (!match) return cwd;
  const target = [match[1], match[2], match[3]].find((value) => value !== undefined);
  return target ? path.resolve(cwd, target) : cwd;
}

function fingerprintRoot(directory, projectRoot, limits = LIMITS) {
  if (typeof directory !== 'string' || directory === '' || directory === projectRoot) return projectRoot;
  const own = git(projectRoot, ['rev-parse', '--show-toplevel'], { timeoutMs: limits.gitTimeoutMs });
  if (!own.ok) return projectRoot;
  const other = git(directory, ['rev-parse', '--show-toplevel'], { timeoutMs: limits.gitTimeoutMs });
  if (!other.ok) return NO_WORK_TREE_RE.test(other.reason) ? projectRoot : null;
  const ownTop = own.stdout.trim();
  const otherTop = other.stdout.trim();
  if (ownTop === '' || otherTop === '') return projectRoot;
  const relative = path.relative(ownTop, otherTop);
  if (relative === '' || relative.split(/[\\/]/)[0] === '..' || path.isAbsolute(relative)) return projectRoot;
  return otherTop;
}

function computeFingerprint(projectRoot, treeRoot, scratchDirectory, limits = LIMITS) {
  if (treeRoot === null) return { tree: null, reason: 'git could not resolve the work tree the run directory lies in' };
  const own = computeTree(projectRoot, scratchDirectory, limits);
  if (treeRoot === projectRoot || own.tree === null) return own;
  const other = computeTree(treeRoot, scratchDirectory, limits);
  if (other.tree === null) return { tree: null, reason: `work tree: ${other.reason}` };
  const combined = git(projectRoot, ['mktree', '--missing'], { input: `040000 tree ${own.tree}\tproject\n040000 tree ${other.tree}\twork\n` });
  if (!combined.ok) return { tree: null, reason: combined.reason };
  const tree = combined.stdout.trim();
  if (!TREE_RE.test(tree)) return { tree: null, reason: 'git mktree returned no tree id' };
  return { tree, reason: null };
}

function recordRoot(record, projectRoot, limits = LIMITS) {
  if (!record || !TEST_SCOPES.includes(record.scope)) return projectRoot;
  return fingerprintRoot(commandDirectory(record.command, record.cwd), projectRoot, limits);
}

function currentTrees(projectRoot, scratchDirectory, limits = LIMITS) {
  const roots = new Map();
  const trees = new Map();
  const rootOf = (record) => {
    if (!record || !TEST_SCOPES.includes(record.scope)) return projectRoot;
    const key = `${record.cwd}\u0000${record.command}`;
    if (!roots.has(key)) roots.set(key, recordRoot(record, projectRoot, limits));
    return roots.get(key);
  };
  const treeAt = (root) => {
    const key = root === null ? '\u0000' : root;
    if (!trees.has(key)) trees.set(key, computeFingerprint(projectRoot, root, scratchDirectory, limits));
    return trees.get(key);
  };
  return { rootOf, treeAt, of: (entry) => treeAt(entry && entry.record ? rootOf(entry.record) : projectRoot) };
}

function changedPaths(projectRoot, fromTree, toTree, limits = LIMITS) {
  if (!fromTree || !toTree) return null;
  const diff = git(projectRoot, ['diff-tree', '-r', '--name-only', '-z', fromTree, toTree], { encoding: 'buffer' });
  if (!diff.ok) return null;
  return diff.stdout.toString('utf8').split('\0').filter(Boolean).slice(0, limits.listedPaths + 1);
}

function treeParts(projectRoot, tree, limits = LIMITS) {
  const listed = git(projectRoot, ['ls-tree', '-z', tree], { encoding: 'buffer', timeoutMs: limits.gitTimeoutMs });
  if (!listed.ok) return null;
  const parts = {};
  for (const entry of listed.stdout.toString('utf8').split('\0').filter(Boolean)) {
    const match = /^040000 tree ([0-9a-f]{40}(?:[0-9a-f]{24})?)\t(project|work)$/.exec(entry);
    if (!match || parts[match[2]]) return null;
    parts[match[2]] = match[1];
  }
  return parts.project && parts.work ? parts : null;
}

function workPrefix(projectRoot, treeRoot) {
  let base = projectRoot;
  let target = treeRoot;
  try { base = fs.realpathSync.native(projectRoot); } catch { }
  try { target = fs.realpathSync.native(treeRoot); } catch { }
  const relative = path.relative(base, target).split(path.sep).join('/');
  return relative === '' ? '' : `${relative}/`;
}

function measuredLabel(projectRoot, treeRoot, limits = LIMITS) {
  if (typeof treeRoot !== 'string' || treeRoot === projectRoot) return '';
  const location = workPrefix(projectRoot, treeRoot).replace(/\/$/, '');
  return location === '' ? '' : ` of the project and ${screen(location, projectRoot, limits)}`;
}

function fingerprintChanges(projectRoot, treeRoot, fromTree, toTree, limits = LIMITS) {
  if (!fromTree || !toTree || treeRoot === null) return null;
  const from = treeParts(projectRoot, fromTree, limits);
  const to = treeParts(projectRoot, toTree, limits);
  if (treeRoot === projectRoot) return from || to ? null : changedPaths(projectRoot, fromTree, toTree, limits);
  if (!from || !to) return null;
  const own = changedPaths(projectRoot, from.project, to.project, limits);
  const other = changedPaths(treeRoot, from.work, to.work, limits);
  if (own === null || other === null) return null;
  const prefix = workPrefix(projectRoot, treeRoot);
  return [...own, ...other.map((entry) => `${prefix}${entry}`)].slice(0, limits.listedPaths + 1);
}

function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

function effectiveState(record, now = Date.now(), limits = LIMITS) {
  if (record.state !== 'running') return record.state;
  if (!pidAlive(record.pid)) return 'interrupted';
  if (now - Date.parse(record.started_at) > limits.maxRunMs) return 'interrupted';
  return 'running';
}

function screen(text, projectRoot, limits = LIMITS) {
  if (typeof text !== 'string' || text === '') return '';
  const redacted = redact(text, { projectRoot, home: defaultHome() });
  if (scan(redacted).matches.length > 0 || scan(text).matches.length > 0) return WITHHELD;
  let cleaned = redacted.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, ' ').replace(/`/g, "'").replace(/\s+/g, ' ').trim();
  if (cleaned.length > limits.displayMax) cleaned = `${cleaned.slice(0, limits.displayMax - 1)}…`;
  return cleaned;
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function formatDuration(milliseconds) {
  if (!Number.isInteger(milliseconds)) return 'n/a';
  return `${(milliseconds / 1000).toFixed(1)}s`;
}

function shortTree(tree) {
  return typeof tree === 'string' ? tree.slice(0, 12) : '';
}

function treeLabel(record) {
  if (!TREE_SCOPES.includes(record.scope)) return 'n/a';
  if (record.tree_start && record.tree_end && record.tree_start !== record.tree_end) {
    return `mutated-during-run (${shortTree(record.tree_start)} -> ${shortTree(record.tree_end)})`;
  }
  if (record.tree_end) return shortTree(record.tree_end);
  return `unverified (${record.tree_end_reason || record.tree_start_reason || 'no tree id'})`;
}

function exitLabel(record) {
  if (record.exit_code === null) return 'none';
  if (record.state === 'interrupted') return `${record.exit_code} (interrupted${record.signal ? ` by ${record.signal}` : ''})`;
  if (record.signal) return `${record.exit_code} (${record.signal})`;
  return String(record.exit_code);
}

function summaryLine(record, projectRoot, limits = LIMITS) {
  return `zensu evidence-run: scope=${record.scope} exit=${exitLabel(record)} duration=${formatDuration(record.duration_ms)} tree=${treeLabel(record)} record=${record.id} cmd=${screen(record.command, projectRoot, limits)}`;
}

function runLogLine(record, projectRoot, limits = LIMITS) {
  return `EVIDENCE RUN — scope=${record.scope} exit=${exitLabel(record)} duration=${formatDuration(record.duration_ms)} tree=${treeLabel(record)} record=${record.id} | cmd: ${screen(record.command, projectRoot, limits)}`;
}

function normalizeGateMode(value, projectRoot) {
  if (value === undefined || value === null || value === '') return { mode: 'required', disclosure: null };
  if (GATE_MODES.includes(value)) return { mode: value, disclosure: null };
  return {
    mode: 'required',
    disclosure: `FULL SUITE — evidence.fullSuiteGate value ${shellQuote(screen(String(value), projectRoot))} is not recognized (expected required or advisory); treated as required`,
  };
}

function remedyCommand(remedyPrefix, configuredCommand, knownCommand, projectRoot) {
  const prefix = remedyPrefix || 'zensu-log.sh --evidence-run --scope full';
  if (configuredCommand) return prefix;
  if (knownCommand) {
    const rendered = screen(knownCommand, projectRoot);
    if (rendered !== WITHHELD && knownCommand.indexOf('\n') === -1 && knownCommand.length <= LIMITS.displayMax) {
      return `${prefix} --cmd ${shellQuote(knownCommand)}`;
    }
  }
  return `${prefix} --cmd '<your full test command>'`;
}

function decide(entries, currentTree, configuredCommand, limits = LIMITS, now = Date.now()) {
  const stateOf = (entry) => effectiveState(entry.record, now, limits);
  const full = entries.filter((entry) => entry.invalid || entry.record.scope === 'full');
  const newest = full[full.length - 1];
  if (newest && newest.invalid) return { state: 'invalid', entry: newest };
  const valid = full.filter((entry) => !entry.invalid);
  const running = valid.filter((entry) => stateOf(entry) === 'running');
  if (running.length > 0) return { state: 'running', entry: running[running.length - 1] };
  const finished = valid.filter((entry) => stateOf(entry) !== 'running');
  if (finished.length === 0) return { state: 'missing', entry: null };
  if (currentTree.tree === null) {
    const last = finished[finished.length - 1];
    const state = stateOf(last);
    if (state === 'interrupted') return { state: 'interrupted', entry: last };
    if (last.record.exit_code !== 0) return { state: 'failed', entry: last };
    if (configuredCommand && last.record.command !== configuredCommand) return { state: 'command-mismatch', entry: last };
    return { state: 'pass-tree-unverified', entry: last, earlierFailures: 0 };
  }
  const onTree = finished.filter((entry) => entry.record.tree_end === currentTree.tree);
  if (onTree.length > 0) {
    const last = onTree[onTree.length - 1];
    const state = stateOf(last);
    if (state === 'interrupted') return { state: 'interrupted', entry: last };
    if (last.record.tree_start !== last.record.tree_end) return { state: 'mutated-during-run', entry: last };
    if (last.record.exit_code !== 0) return { state: 'failed', entry: last };
    if (configuredCommand && last.record.command !== configuredCommand) return { state: 'command-mismatch', entry: last };
    const earlierFailures = onTree.slice(0, -1).filter((entry) => stateOf(entry) !== 'completed' || entry.record.exit_code !== 0).length;
    return { state: 'pass', entry: last, earlierFailures };
  }
  const last = finished[finished.length - 1];
  const state = stateOf(last);
  if (state === 'interrupted') return { state: 'interrupted', entry: last };
  if (last.record.exit_code !== 0) return { state: 'failed', entry: last };
  return { state: 'stale', entry: last };
}

function decideCi(entries, currentTree, limits = LIMITS, now = Date.now()) {
  const treeOf = typeof currentTree === 'function' ? currentTree : () => currentTree;
  const stateOf = (entry) => effectiveState(entry.record, now, limits);
  const tests = entries.filter((entry) => entry.invalid || TEST_SCOPES.includes(entry.record.scope));
  const newest = tests[tests.length - 1];
  if (newest && newest.invalid) return { state: 'invalid', entry: newest };
  const valid = tests.filter((entry) => !entry.invalid);
  const running = valid.filter((entry) => stateOf(entry) === 'running');
  if (running.length > 0) return { state: 'running', entry: running[running.length - 1] };
  const finished = valid.filter((entry) => stateOf(entry) !== 'running');
  if (finished.length === 0) return { state: 'missing', entry: null };
  const pool = finished.filter((entry) => {
    const tree = treeOf(entry).tree;
    return tree === null || entry.record.tree_end === tree;
  });
  const unbound = pool.some((entry) => treeOf(entry).tree === null);
  const active = treeOf(finished[finished.length - 1]).tree;
  if (active !== null && !pool.some((entry) => entry.record.tree_end === active)) {
    return { state: 'stale', entry: finished[finished.length - 1] };
  }
  if (pool.length === 0) return { state: 'stale', entry: finished[finished.length - 1] };
  const newestByCommand = new Map();
  for (const entry of pool) newestByCommand.set(`${entry.record.scope}\u0000${entry.record.command}`, entry);
  const latest = [...newestByCommand.values()];
  for (const entry of latest) {
    if (stateOf(entry) === 'interrupted') return { state: 'interrupted', entry };
    if (entry.record.tree_start && entry.record.tree_end && entry.record.tree_start !== entry.record.tree_end) {
      return { state: 'mutated-during-run', entry };
    }
    if (entry.record.exit_code !== 0) return { state: 'failed', entry };
  }
  const full = latest.filter((entry) => entry.record.scope === 'full');
  if (!unbound && full.length > 0) return { state: 'pass', entry: full[full.length - 1], earlierFailures: 0 };
  return { state: 'deferred-ci', entry: latest[latest.length - 1], greenCommands: latest.length, unbound };
}

function ciVerdict(context) {
  const { decision, currentTree, treeRoot, projectRoot, gate, gateLabel, lines, options, limits } = context;
  const measured = measuredLabel(projectRoot, treeRoot, limits);
  const policy = options.ciPolicy;
  const record = decision.entry && decision.entry.record;
  const scopedPrefix = options.scopedRemedyPrefix || 'zensu-log.sh --evidence-run --scope scoped';
  const recordText = record ? `record ${record.id}` : 'no record';
  const scopeWord = record ? record.scope : 'test';
  const commandText = record ? screen(record.command, projectRoot, limits) : 'none recorded';
  const listedFor = (fromTree, toTree) => {
    const paths = fingerprintChanges(projectRoot, treeRoot, fromTree, toTree, limits);
    return paths && paths.length > 0
      ? `: ${paths.slice(0, limits.listedPaths).map((entry) => screen(entry, projectRoot, limits)).join(', ')}${paths.length > limits.listedPaths ? ', …' : ''}`
      : '';
  };
  let remedy = `${scopedPrefix} --cmd '<the tests affected by this change>'`;
  if (record && record.scope === 'scoped' && ['failed', 'interrupted', 'mutated-during-run', 'stale'].includes(decision.state)) {
    const rendered = screen(record.command, projectRoot, limits);
    if (rendered !== WITHHELD && record.command.indexOf('\n') === -1 && record.command.length <= LIMITS.displayMax) {
      remedy = `${scopedPrefix} --cmd ${shellQuote(record.command)}`;
    }
  }
  let cause;
  switch (decision.state) {
    case 'pass':
      cause = `a local full-suite run exited 0 on the current tree ${shortTree(currentTree.tree)}${measured} (${recordText}, ${formatDuration(record.duration_ms)})`;
      break;
    case 'deferred-ci':
      cause = decision.unbound
        ? `the newest run of each local test command exited 0 (newest ${recordText}); the tree could not be fingerprinted (${currentTree.reason}), so these runs are not bound to it; the full suite has not run for this change yet — CI runs it when a pull request against ${policy.base} is opened or updated`
        : `the newest run of each local test command on the current tree ${shortTree(currentTree.tree)}${measured} exited 0 (${decision.greenCommands} command(s), newest ${recordText}); the full suite has not run for this change yet — CI runs it when a pull request against ${policy.base} is opened or updated`;
      break;
    case 'running':
      cause = `a ${scopeWord} run is still in progress (${recordText}, pid ${record.pid}); wait for it to finish, then close the chain again`;
      break;
    case 'failed':
      cause = `the newest ${scopeWord} run of this command on the current tree exited ${exitLabel(record)} (${recordText}); fix the failure and run it again`;
      break;
    case 'interrupted':
      cause = `the newest ${scopeWord} run never finished (${recordText}); run it again`;
      break;
    case 'mutated-during-run':
      cause = `the tree${measured} changed while the ${scopeWord} run ran (${recordText})${listedFor(record.tree_start, record.tree_end)}; make the tests leave tracked files untouched, then run them again`;
      break;
    case 'stale':
      cause = `the newest local test run measured an older tree${measured} (${recordText}); files changed since${listedFor(record.tree_end, currentTree.tree)}; run the affected tests again`;
      break;
    case 'missing':
      cause = 'no local test run is recorded for this chain; the full suite runs in CI, but the tests affected by this change still run here';
      break;
    case 'invalid':
      cause = `the newest test record cannot be trusted (${decision.entry.id}: ${decision.entry.invalid}); run the affected tests again`;
      break;
    default:
      cause = `the evidence store could not be read (${decision.reason || 'unknown fault'})`;
  }
  const passes = PASSING_STATES.includes(decision.state);
  if (passes) {
    lines.push(`FULL SUITE — ${decision.state} | ${cause} | cmd: ${commandText} | ${gateLabel}`);
  } else {
    const remedyText = decision.state === 'running' || decision.state === 'unavailable' ? '' : ` | run: ${remedy}`;
    const label = gate.mode === 'advisory' ? `${decision.state} (advisory, not blocking)` : decision.state;
    lines.push(`FULL SUITE — ${label} | ${cause} | cmd: ${commandText} | ${gateLabel}${remedyText}`);
  }
  lines.push(`FULL SUITE — CI contract | ${policy.summary} | decided by: ${policy.decidedBy}`);
  return {
    state: decision.state,
    passes: passes || gate.mode === 'advisory',
    mode: gate.mode,
    lines,
    tree: currentTree.tree,
  };
}

function verdict(options) {
  const limits = limitsWith(options.limits);
  const projectRoot = options.projectRoot;
  const gate = normalizeGateMode(options.gateMode, projectRoot);
  const configuredCommand = typeof options.configuredCommand === 'string' && options.configuredCommand !== '' ? options.configuredCommand : null;
  const lines = [];
  if (gate.disclosure) lines.push(gate.disclosure);
  const gateLabel = `gate: ${gate.mode}`;
  const scope = typeof projectRoot === 'string' && projectRoot !== ''
    ? workTree(projectRoot, limits)
    : { applicable: null, reason: 'no project root is bound' };
  if (scope.applicable === false) {
    lines.push(`FULL SUITE — not-applicable | ${scope.reason}, so no run can be bound to a tree | ${gateLabel}`);
    return { state: 'not-applicable', passes: true, mode: gate.mode, lines, tree: null };
  }
  if (options.escape) {
    lines.push(`FULL SUITE — escaped | ZENSU_FULL_SUITE_GATE=off switched this check off, so no run was read | ${gateLabel}`);
    return { state: 'escaped', passes: true, mode: gate.mode, lines, tree: null };
  }
  const ciMode = Boolean(options.ciPolicy && options.ciPolicy.runner === 'ci');
  if (options.ciPolicy && options.ciPolicy.fault) {
    lines.push(`FULL SUITE — policy unavailable | ${screen(options.ciPolicy.fault, projectRoot, limits)}; this chain is judged as a local chain | ${gateLabel}`);
  }
  if (options.ciPolicy && options.ciPolicy.runner === 'local' && options.ciPolicy.ciRequested === true && typeof options.ciPolicy.reason === 'string') {
    lines.push(`FULL SUITE — local runner | ${screen(options.ciPolicy.reason, projectRoot, limits)} | decided by: ${screen(String(options.ciPolicy.decidedBy || 'default'), projectRoot, limits)}`);
  }
  let decision;
  let currentTree = { tree: null, reason: 'not computed' };
  let treeRoot = projectRoot;
  if (scope.applicable === null) {
    decision = { state: 'unavailable', entry: null, reason: scope.reason };
  } else {
    try {
      const locations = storeLocations(options.pluginData, options.sessionKey);
      const entries = listRecords(locations, { sessionKey: options.sessionKey, projectRoot }, limits);
      const trees = currentTrees(projectRoot, locations.scratch, limits);
      if (ciMode) {
        decision = decideCi(entries, trees.of, limits);
        treeRoot = decision.entry && decision.entry.record ? trees.rootOf(decision.entry.record) : projectRoot;
      } else {
        const full = entries.filter((entry) => entry.record && entry.record.scope === 'full');
        if (typeof options.runCwd === 'string' && options.runCwd !== '') treeRoot = fingerprintRoot(options.runCwd, projectRoot, limits);
        else if (full.length > 0) treeRoot = trees.rootOf(full[full.length - 1].record);
      }
      currentTree = trees.treeAt(treeRoot);
      if (!ciMode) decision = decide(entries, currentTree, configuredCommand, limits);
    } catch (error) {
      decision = { state: 'unavailable', entry: null, reason: error.message };
    }
  }
  if (ciMode) return ciVerdict({ decision, currentTree, treeRoot, projectRoot, gate, gateLabel, lines, options, limits });
  const record = decision.entry && decision.entry.record;
  const knownCommand = configuredCommand || (record && record.command) || null;
  const remedy = remedyCommand(options.remedyPrefix, configuredCommand, record ? record.command : null, projectRoot);
  const commandText = knownCommand ? screen(knownCommand, projectRoot, limits) : 'none recorded';
  const recordText = record ? `record ${record.id}` : 'no record';
  const measured = measuredLabel(projectRoot, treeRoot, limits);
  let cause;
  switch (decision.state) {
    case 'pass':
      cause = `exit 0 on the current tree ${shortTree(currentTree.tree)}${measured} (${recordText}, ${formatDuration(record.duration_ms)})`;
      break;
    case 'pass-tree-unverified':
      cause = `exit 0 (${recordText}, ${formatDuration(record.duration_ms)}); the tree could not be fingerprinted (${currentTree.reason}), so freshness is unverified`;
      break;
    case 'running':
      cause = `a full-suite run is still in progress (${recordText}, pid ${record.pid}); wait for it to finish, then close the chain again`;
      break;
    case 'failed':
      cause = `the newest full-suite run exited ${exitLabel(record)} (${recordText}); fix the failure and run the suite again`;
      break;
    case 'interrupted':
      cause = `the newest full-suite run never finished (${recordText}); run the suite again`;
      break;
    case 'stale': {
      const paths = fingerprintChanges(projectRoot, treeRoot, record.tree_end, currentTree.tree, limits);
      const listed = paths && paths.length > 0
        ? `: ${paths.slice(0, limits.listedPaths).map((entry) => screen(entry, projectRoot, limits)).join(', ')}${paths.length > limits.listedPaths ? ', …' : ''}`
        : '';
      cause = `the newest green full-suite run measured an older tree${measured} (${recordText}); files changed since${listed}`;
      break;
    }
    case 'mutated-during-run': {
      const paths = fingerprintChanges(projectRoot, treeRoot, record.tree_start, record.tree_end, limits);
      const listed = paths && paths.length > 0
        ? `: ${paths.slice(0, limits.listedPaths).map((entry) => screen(entry, projectRoot, limits)).join(', ')}${paths.length > limits.listedPaths ? ', …' : ''}`
        : '';
      cause = `the tree${measured} changed while the suite ran (${recordText})${listed}; make the suite leave tracked files untouched or ignore what it writes, then run it again`;
      break;
    }
    case 'missing':
      cause = 'no full-suite run is recorded for this session';
      break;
    case 'command-mismatch':
      cause = `the newest run on this tree used a different command than evidence.fullSuiteCommand (${recordText})`;
      break;
    case 'invalid':
      cause = `the newest full-suite record cannot be trusted (${decision.entry.id}: ${decision.entry.invalid}); run the suite again`;
      break;
    default:
      cause = `the evidence store could not be read (${decision.reason || 'unknown fault'})`;
  }
  const passes = PASSING_STATES.includes(decision.state);
  if (passes) {
    lines.push(`FULL SUITE — ${decision.state} | ${cause} | cmd: ${commandText} | ${gateLabel}`);
    if (decision.earlierFailures > 0) {
      lines.push(`FULL SUITE — flaky: ${decision.earlierFailures} earlier run(s) on this same tree did not pass`);
    }
  } else {
    const remedyText = decision.state === 'running' || decision.state === 'unavailable' ? '' : ` | run: ${remedy}`;
    const label = gate.mode === 'advisory' ? `${decision.state} (advisory, not blocking)` : decision.state;
    lines.push(`FULL SUITE — ${label} | ${cause} | cmd: ${commandText} | ${gateLabel}${remedyText}`);
  }
  return {
    state: decision.state,
    passes: passes || gate.mode === 'advisory',
    mode: gate.mode,
    lines,
    tree: currentTree.tree,
  };
}

function signalNumber(signal) {
  const number = os.constants.signals[signal];
  return Number.isInteger(number) ? number : 1;
}

function killGroup(child, signal) {
  if (!child || !Number.isInteger(child.pid)) return;
  if (process.platform === 'win32') {
    try {
      childProcess.spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
    } catch { }
    return;
  }
  try {
    process.kill(-child.pid, signal);
  } catch {
    try { child.kill(signal); } catch { }
  }
}

function truncateLogMiddle(logPath, limits) {
  const stat = fs.statSync(logPath);
  if (stat.size <= limits.maxLogBytes) return { bytes: stat.size, truncated: false };
  const half = Math.floor(limits.maxLogBytes / 2);
  const descriptor = fs.openSync(logPath, 'r');
  let head;
  let tail;
  try {
    head = Buffer.alloc(half);
    fs.readSync(descriptor, head, 0, half, 0);
    tail = Buffer.alloc(half);
    fs.readSync(descriptor, tail, 0, half, stat.size - half);
  } finally {
    fs.closeSync(descriptor);
  }
  const marker = Buffer.from(`\n[zensu evidence-run: ${stat.size - 2 * half} bytes removed from the middle of this log]\n`);
  const temporary = `${logPath}.${crypto.randomBytes(6).toString('hex')}.tmp`;
  fs.writeFileSync(temporary, Buffer.concat([head, marker, tail]), { mode: 0o600, flag: 'wx' });
  fs.renameSync(temporary, logPath);
  return { bytes: fs.statSync(logPath).size, truncated: true };
}

function readTail(logPath, lineCount, limits) {
  const stat = fs.statSync(logPath);
  const length = Math.min(stat.size, limits.tailReadBytes);
  const buffer = Buffer.alloc(length);
  const descriptor = fs.openSync(logPath, 'r');
  try {
    fs.readSync(descriptor, buffer, 0, length, stat.size - length);
  } finally {
    fs.closeSync(descriptor);
  }
  const lines = buffer.toString('utf8').split('\n');
  if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop();
  if (length < stat.size && lines.length > 0) lines.shift();
  return lines.slice(-lineCount);
}

function prune(locations, limits, keepIds) {
  let names;
  try {
    names = fs.readdirSync(locations.records).filter((name) => RECORD_FILE_RE.test(name)).sort();
  } catch {
    return 0;
  }
  const byScope = new Map();
  for (const name of names) {
    const loaded = readRecordFile(path.join(locations.records, name), limits);
    const scope = loaded.record && SCOPES.includes(loaded.record.scope) ? loaded.record.scope : '';
    if (!byScope.has(scope)) byScope.set(scope, []);
    byScope.get(scope).push(name);
  }
  let removed = 0;
  for (const group of byScope.values()) {
    const excess = group.length - limits.maxRecordsPerSession;
    for (const name of group.slice(0, Math.max(0, excess))) {
      const id = name.slice(0, -5);
      if (keepIds && keepIds.includes(id)) continue;
      try { fs.unlinkSync(path.join(locations.records, name)); removed += 1; } catch { }
      try { fs.unlinkSync(path.join(locations.logs, `${id}.log`)); } catch { }
    }
  }
  try {
    for (const name of fs.readdirSync(locations.logs)) {
      if (!LOG_FILE_RE.test(name)) continue;
      if (!fs.existsSync(path.join(locations.records, `${name.slice(0, -4)}.json`))) {
        try { fs.unlinkSync(path.join(locations.logs, name)); } catch { }
      }
    }
  } catch { }
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

function sweepIdleSessions(locations, currentSessionKey, limits, now = Date.now()) {
  let swept = 0;
  for (const bucket of ['records', 'logs']) {
    const base = path.join(locations.root, bucket);
    let names;
    try { names = fs.readdirSync(base); } catch { continue; }
    for (const name of names) {
      if (!SESSION_KEY_RE.test(name) || name === currentSessionKey) continue;
      const directory = path.join(base, name);
      try {
        if (fs.lstatSync(directory).isSymbolicLink()) continue;
      } catch { continue; }
      if (now - newestMtime(directory) <= limits.idleSessionMs) continue;
      try {
        fs.rmSync(directory, { recursive: true, force: true });
        if (bucket === 'records') swept += 1;
      } catch { }
    }
  }
  return swept;
}

function readPluginVersion() {
  try {
    const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', '.claude-plugin', 'plugin.json'), 'utf8'));
    return typeof manifest.version === 'string' && manifest.version.length <= 64 ? manifest.version : null;
  } catch {
    return null;
  }
}

function childEnvironment(env, callerProjectDir) {
  const out = { ...env };
  for (const name of Object.keys(out)) {
    if (name.startsWith(TRANSPORT_PREFIX)) delete out[name];
  }
  for (const name of CHILD_SCRUBBED_ENV) delete out[name];
  if (typeof callerProjectDir === 'string') out.CLAUDE_PROJECT_DIR = callerProjectDir;
  return out;
}

function resolveCommand(scope, explicitCommand, configuredCommand) {
  const explicit = typeof explicitCommand === 'string' && explicitCommand.trim() !== '' ? explicitCommand : null;
  const configured = typeof configuredCommand === 'string' && configuredCommand.trim() !== '' ? configuredCommand : null;
  let chosen = explicit;
  if (scope === 'full' && configured) {
    if (explicit && explicit !== configured) {
      return { error: 'refusing --cmd for --scope full: it differs from evidence.fullSuiteCommand; run without --cmd to use the configured command, or change the configuration' };
    }
    chosen = configured;
  }
  if (!chosen) {
    return { error: scope === 'full'
      ? 'no full-suite command: pass --cmd or set evidence.fullSuiteCommand in .zensu/config.json'
      : `--scope ${scope} requires --cmd` };
  }
  if (chosen.indexOf('\0') !== -1) return { error: 'the command contains a NUL byte' };
  if (Buffer.byteLength(chosen) > LIMITS.maxCommandBytes) return { error: 'the command is too long' };
  return { command: chosen };
}

function freshScopedRecord(locations, sessionKey, projectRoot, command, treeRoot, limits) {
  let entries;
  try {
    entries = listRecords(locations, { sessionKey, projectRoot }, limits);
  } catch {
    return null;
  }
  const current = computeFingerprint(projectRoot, treeRoot, locations.scratch, limits);
  if (current.tree === null) return null;
  const same = entries.filter((entry) => !entry.invalid
    && entry.record.scope === 'scoped'
    && entry.record.command === command
    && entry.record.state === 'completed'
    && entry.record.tree_end === current.tree);
  const newest = same[same.length - 1];
  if (!newest || newest.record.exit_code !== 0 || newest.record.tree_start !== newest.record.tree_end) return null;
  return newest;
}

function run(options) {
  const limits = limitsWith(options.limits);
  const stdout = options.stdout || process.stdout;
  const stderr = options.stderr || process.stderr;
  const say = (stream, text) => stream.write(`${text}\n`);
  return new Promise((resolve) => {
    if (!SCOPES.includes(options.scope)) {
      say(stderr, `zensu-log.sh --evidence-run: --scope must be one of ${SCOPES.join(', ')}`);
      resolve(2);
      return;
    }
    const resolved = resolveCommand(options.scope, options.command, options.configuredCommand);
    if (resolved.error) {
      say(stderr, `zensu-log.sh --evidence-run: ${resolved.error}`);
      resolve(2);
      return;
    }
    const projectRoot = options.projectRoot;
    if (options.scope === 'full' && !options.local && options.ciPolicy && options.ciPolicy.runner === 'ci') {
      say(stderr, `zensu-log.sh --evidence-run: this chain runs the full suite in CI (decided by: ${options.ciPolicy.decidedBy}), so it is not run here — this refusal is not a suite failure. Run the tests affected by the change instead with --scope scoped --cmd '<the affected tests>'. Add --local only when the user explicitly asked for a local full-suite run.`);
      say(stderr, `FULL SUITE — CI contract | ${options.ciPolicy.summary}`);
      resolve(2);
      return;
    }
    let locations;
    try {
      locations = storeLocations(options.pluginData, options.sessionKey);
    } catch (error) {
      say(stderr, `zensu-log.sh --evidence-run: ${error.message}`);
      resolve(2);
      return;
    }
    const where = runDirectory(projectRoot, options.cwd, limits);
    const suiteDirectory = commandDirectory(resolved.command, where.cwd);
    const treeRoot = TEST_SCOPES.includes(options.scope) ? fingerprintRoot(suiteDirectory, projectRoot, limits) : projectRoot;
    if (options.ifStale && options.scope === 'scoped') {
      const fresh = freshScopedRecord(locations, options.sessionKey, projectRoot, resolved.command, treeRoot, limits);
      if (fresh) {
        say(stdout, `zensu evidence-run: skipped (--if-stale) — the newest run of this command is green on the current tree ${shortTree(fresh.record.tree_end)} (record ${fresh.record.id})`);
        resolve(0);
        return;
      }
    }
    if (options.ifStale && options.scope === 'full') {
      const current = verdict({
        pluginData: options.pluginData,
        sessionKey: options.sessionKey,
        projectRoot,
        runCwd: suiteDirectory,
        configuredCommand: options.configuredCommand,
        gateMode: 'required',
        remedyPrefix: options.remedyPrefix,
        limits: options.limits,
      });
      if (current.state === 'pass') {
        say(stdout, `zensu evidence-run: skipped (--if-stale) — the newest full-suite record is green on the current tree ${shortTree(current.tree)}`);
        resolve(0);
        return;
      }
    }
    const id = newRecordId(options.now ? options.now() : Date.now());
    const logPath = path.join(locations.logs, `${id}.log`);
    const scriptPath = path.join(locations.scratch, `run-${id}.sh`);
    const startedAt = new Date();
    const treeStart = TREE_SCOPES.includes(options.scope) ? computeFingerprint(projectRoot, treeRoot, locations.scratch, limits) : { tree: null, reason: null };
    if (where.moved) {
      say(stderr, `zensu evidence-run: the working directory is not in the work tree of the bound project root, so the command runs in ${projectRoot}`);
    }
    const record = {
      schema: SCHEMA,
      id,
      session_key: options.sessionKey,
      project_root: projectRoot,
      scope: options.scope,
      command: resolved.command,
      cwd: where.cwd,
      state: 'running',
      pid: process.pid,
      started_at: startedAt.toISOString(),
      finished_at: null,
      duration_ms: null,
      exit_code: null,
      signal: null,
      tree_start: treeStart.tree,
      tree_start_reason: treeStart.reason,
      tree_end: null,
      tree_end_reason: null,
      plugin_version: readPluginVersion(),
      log_bytes: null,
      log_truncated: false,
    };
    let child = null;
    let interruptedBy = null;
    let finished = false;
    const onSignal = (signal) => {
      if (finished) return;
      interruptedBy = interruptedBy || signal;
      if (!child) return;
      killGroup(child, 'SIGTERM');
      const escalate = setTimeout(() => killGroup(child, 'SIGKILL'), limits.killGraceMs);
      if (typeof escalate.unref === 'function') escalate.unref();
    };
    const handlers = ['SIGINT', 'SIGTERM', 'SIGHUP'].map((signal) => {
      const handler = () => onSignal(signal);
      process.on(signal, handler);
      return [signal, handler];
    });
    const release = () => {
      for (const [name, handler] of handlers) process.removeListener(name, handler);
    };
    let logDescriptor;
    try {
      fs.writeFileSync(scriptPath, `set -o pipefail\n${resolved.command}\n`, { mode: 0o600, flag: 'wx' });
      logDescriptor = fs.openSync(logPath, 'wx', 0o600);
      writeRecordAtomic(locations.records, record);
    } catch (error) {
      release();
      say(stderr, `zensu-log.sh --evidence-run: cannot prepare the run (${error.code || error.message})`);
      if (logDescriptor !== undefined) {
        try { fs.closeSync(logDescriptor); } catch { }
      }
      try { fs.unlinkSync(scriptPath); } catch { }
      resolve(2);
      return;
    }
    say(stdout, `zensu evidence-run: record ${id} | scope ${options.scope} | full output: ${logPath}`);
    let spawnFailed = false;
    if (!interruptedBy) {
      try {
        child = childProcess.spawn(options.bashPath || 'bash', ['--noprofile', '--norc', scriptPath], {
          cwd: where.cwd,
          env: childEnvironment(options.env || process.env, options.callerProjectDir),
          stdio: ['ignore', logDescriptor, logDescriptor],
          detached: process.platform !== 'win32',
          windowsHide: true,
        });
      } catch (error) {
        child = null;
        spawnFailed = true;
        fs.writeSync(logDescriptor, `zensu evidence-run: could not start bash (${error.code || error.message})\n`);
      }
    }
    const finish = (code, signal, spawnError) => {
      if (finished) return;
      finished = true;
      release();
      if (child) killGroup(child, 'SIGTERM');
      try { fs.closeSync(logDescriptor); } catch { }
      try { fs.unlinkSync(scriptPath); } catch { }
      const finishedAt = new Date();
      let exitCode;
      if (spawnError) exitCode = 127;
      else if (interruptedBy) exitCode = 128 + signalNumber(interruptedBy);
      else if (code === null || code === undefined) exitCode = 128 + signalNumber(signal);
      else exitCode = code;
      const treeEnd = TREE_SCOPES.includes(options.scope) ? computeFingerprint(projectRoot, treeRoot, locations.scratch, limits) : { tree: null, reason: null };
      let logInfo = { bytes: null, truncated: false };
      try { logInfo = truncateLogMiddle(logPath, limits); } catch { }
      const final = {
        ...record,
        state: interruptedBy ? 'interrupted' : 'completed',
        finished_at: finishedAt.toISOString(),
        duration_ms: Math.max(0, finishedAt.getTime() - startedAt.getTime()),
        exit_code: Math.min(exitCode, 999),
        signal: interruptedBy || signal || null,
        tree_end: treeEnd.tree,
        tree_end_reason: treeEnd.reason,
        log_bytes: logInfo.bytes,
        log_truncated: logInfo.truncated,
      };
      try {
        writeRecordAtomic(locations.records, final);
      } catch (error) {
        say(stderr, `zensu-log.sh --evidence-run: the result record could not be written (${error.code || error.message})`);
      }
      try {
        prune(locations, limits, [id]);
        sweepIdleSessions(locations, options.sessionKey, limits);
      } catch { }
      try {
        if (options.show === 'all') {
          stdout.write(fs.readFileSync(logPath));
        } else {
          const tail = readTail(logPath, limits.tailLines, limits);
          if (tail.length > 0) say(stdout, tail.join('\n'));
        }
      } catch { }
      say(stdout, summaryLine(final, projectRoot, limits));
      if (options.runLogLinePath) {
        try {
          fs.writeFileSync(options.runLogLinePath, `${runLogLine(final, projectRoot, limits)}\n`, { mode: 0o600 });
        } catch { }
      }
      resolve(final.exit_code > 255 ? 255 : final.exit_code);
    };
    if (!child) {
      finish(null, null, spawnFailed);
      return;
    }
    if (interruptedBy) onSignal(interruptedBy);
    child.once('error', () => finish(null, null, true));
    child.once('exit', (code, signal) => finish(code, signal, false));
  });
}

function readTransportFile(directory, name) {
  if (!directory) return null;
  try {
    const value = fs.readFileSync(path.join(directory, name), 'utf8');
    return value;
  } catch {
    return null;
  }
}

function ciPolicyFor(directory, env) {
  if (!directory || readTransportFile(directory, 'ci-config.json') === null) return null;
  try {
    const policy = require('./full-suite-policy-v1.js');
    const inputs = policy.inputsFromTransport(directory, env, {
      pluginData: 'ZENSU_EVR_PLUGIN_DATA',
      sessionKey: 'ZENSU_EVR_SESSION_KEY',
      projectRoot: 'ZENSU_EVR_PROJECT_ROOT',
      marker: 'full-suite-marker',
    });
    const resolved = policy.resolve({ ...inputs, mode: 'cache', requireSnapshot: true, needCandidate: false });
    return policy.verdictInput(resolved, inputs.projectRoot);
  } catch (error) {
    return { runner: 'local', decidedBy: 'default', fault: `the full-suite policy could not be resolved (${error && error.message ? error.message : String(error)})` };
  }
}

function transportOptions(env) {
  const directory = env.ZENSU_EVR_DIR || '';
  const caller = readTransportFile(directory, 'caller-project-dir');
  return {
    pluginData: env.ZENSU_EVR_PLUGIN_DATA,
    sessionKey: env.ZENSU_EVR_SESSION_KEY,
    projectRoot: env.ZENSU_EVR_PROJECT_ROOT,
    cwd: env.ZENSU_EVR_CWD || env.ZENSU_EVR_PROJECT_ROOT,
    scope: env.ZENSU_EVR_SCOPE,
    show: env.ZENSU_EVR_SHOW === 'all' ? 'all' : 'tail',
    ifStale: env.ZENSU_EVR_IF_STALE === '1',
    bashPath: env.ZENSU_EVR_BASH || 'bash',
    command: readTransportFile(directory, 'command'),
    configuredCommand: readTransportFile(directory, 'full-suite-command'),
    gateMode: readTransportFile(directory, 'gate-mode'),
    remedyPrefix: readTransportFile(directory, 'remedy-prefix'),
    scopedRemedyPrefix: readTransportFile(directory, 'remedy-prefix-scoped'),
    local: env.ZENSU_EVR_LOCAL === '1',
    callerProjectDir: caller === null ? undefined : caller,
    escape: env.ZENSU_EVR_ESCAPE === '1',
    runLogLinePath: directory ? path.join(directory, 'run-log-line') : null,
    verdictStatePath: directory ? path.join(directory, 'verdict-state') : null,
    env,
  };
}

async function main(argv, env = process.env) {
  const mode = argv[0];
  const options = transportOptions(env);
  if (mode === 'run') {
    if (options.scope === 'full' && !options.local) options.ciPolicy = ciPolicyFor(env.ZENSU_EVR_DIR || '', env);
    return run(options);
  }
  if (mode === 'verdict') {
    options.ciPolicy = ciPolicyFor(env.ZENSU_EVR_DIR || '', env);
    const result = verdict(options);
    for (const line of result.lines) process.stderr.write(`${line}\n`);
    if (options.verdictStatePath) {
      try { fs.writeFileSync(options.verdictStatePath, result.state); } catch { }
    }
    if (result.state === 'unavailable' && result.mode !== 'advisory') return 2;
    return result.passes ? 0 : 1;
  }
  process.stderr.write('usage: evidence-run-v1.js run|verdict\n');
  return 2;
}

module.exports = {
  SCHEMA,
  SCOPES,
  TREE_SCOPES,
  TEST_SCOPES,
  RECORD_STATES,
  GATE_MODES,
  VERDICT_STATES,
  PASSING_STATES,
  RECORD_KEYS,
  LIMITS,
  STORE_SEGMENTS,
  CHILD_SCRUBBED_ENV,
  GIT_SCRUBBED_ENV,
  WITHHELD,
  EvidenceRunError,
  newRecordId,
  storeLocations,
  validateRecord,
  readRecordFile,
  writeRecordAtomic,
  listRecords,
  gitEnvironment,
  workTree,
  runDirectory,
  computeTree,
  commandDirectory,
  fingerprintRoot,
  computeFingerprint,
  fingerprintChanges,
  changedPaths,
  pidAlive,
  effectiveState,
  screen,
  shellQuote,
  summaryLine,
  runLogLine,
  normalizeGateMode,
  remedyCommand,
  decide,
  decideCi,
  verdict,
  freshScopedRecord,
  resolveCommand,
  childEnvironment,
  truncateLogMiddle,
  readTail,
  prune,
  sweepIdleSessions,
  run,
  main,
};

if (require.main === module) {
  main(process.argv.slice(2)).then((code) => {
    process.exitCode = code;
  }, (error) => {
    process.stderr.write(`evidence-run-v1: ${error && error.message ? error.message : String(error)}\n`);
    process.exitCode = 2;
  });
}
