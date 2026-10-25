'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { msysDrivePrefix } = require('./claude-path-v1.js');

const HOST_SESSION_RE = /^local_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const UNSAFE_PATH_RE = /[\0\t\r\n]/;
const DESKTOP_RECORD_MAX_BYTES = 8 * 1024 * 1024;
const CONTEXT_RECORD_MAX_BYTES = 1024 * 1024;
const GIT_TIMEOUT_MS = 3000;
const READ_AGAIN_BUDGET = 16;
const STORE_SEGMENTS = Object.freeze(['Claude', 'claude-code-sessions']);
const EMPTY_FIELD = '-';

const KINDS = Object.freeze({
  LINKED: 'linked',
  NONE: 'none',
  UNRESOLVED: 'unresolved',
});

const REPOSITORY = Object.freeze({
  SAME: 'same',
  FOREIGN: 'foreign',
  UNKNOWN: 'unknown',
});

const TURNS = Object.freeze({
  FIRST: 'first',
  LATER: 'later',
});

const REASONS = Object.freeze({
  RESOLVED: 'resolved',
  NO_HOST_SESSION: 'no-host-session',
  MALFORMED_HOST_SESSION: 'malformed-host-session',
  MALFORMED_ACCOUNT: 'malformed-account',
  NO_SESSION_ID: 'no-session-id',
  NO_SESSION_STORE: 'no-session-store',
  OWN_RECORD_MISSING: 'own-record-missing',
  OWN_RECORD_UNREADABLE: 'own-record-unreadable',
  OWN_RECORD_REFUSED: 'own-record-refused',
  OWN_RECORD_MISMATCH: 'own-record-mismatch',
  CLI_SESSION_MISMATCH: 'cli-session-mismatch',
  NOT_LINKED: 'not-linked',
  MALFORMED_PARENT: 'malformed-parent',
  PARENT_RECORD_UNAVAILABLE: 'parent-record-unavailable',
  PARENT_SESSION_UNKNOWN: 'parent-session-unknown',
  RECORDS_UNAVAILABLE: 'records-unavailable',
  PARENT_CONTEXT_UNAVAILABLE: 'parent-context-unavailable',
  PARENT_ROOT_UNAVAILABLE: 'parent-root-unavailable',
  RESOLVER_FAILED: 'resolver-failed',
});

function verdict(kind, reason, extra = {}) {
  return Object.freeze({
    kind,
    reason,
    parentRoot: extra.parentRoot || null,
    parentKey: extra.parentKey || null,
    repository: extra.repository || null,
    turn: extra.turn || null,
  });
}

function turnOf(record) {
  const completed = record.completedTurns;
  return completed === undefined || completed === null || completed === 0 ? TURNS.FIRST : TURNS.LATER;
}

function realDirectory(target) {
  try {
    const stat = fs.lstatSync(target);
    return !stat.isSymbolicLink() && stat.isDirectory();
  } catch (_) {
    return false;
  }
}

function storeCandidates(platform, env) {
  const override = typeof env.ZENSU_CCD_STORE === 'string' ? env.ZENSU_CCD_STORE.trim() : '';
  if (override !== '') {
    const store = msysDrivePrefix(override, platform);
    return (platform === 'win32' ? path.win32 : path).isAbsolute(store) ? [store] : [];
  }
  const home = typeof env.HOME === 'string' && env.HOME !== '' ? env.HOME : '';
  const bases = [];
  if (platform === 'darwin') {
    if (home) bases.push(path.join(home, 'Library', 'Application Support'));
  } else if (platform === 'win32') {
    for (const name of ['APPDATA', 'LOCALAPPDATA']) {
      if (typeof env[name] === 'string' && env[name].trim() !== '') bases.push(env[name].trim());
    }
  } else {
    if (typeof env.XDG_CONFIG_HOME === 'string' && env.XDG_CONFIG_HOME.trim() !== '') {
      bases.push(env.XDG_CONFIG_HOME.trim());
    }
    if (home) bases.push(path.join(home, '.config'));
  }
  return bases.filter((base) => path.isAbsolute(base)).map((base) => path.join(base, ...STORE_SEGMENTS));
}

function sessionDirectory(platform, env, account, organization) {
  for (const store of storeCandidates(platform, env)) {
    const accountDir = path.join(store, account);
    const organizationDir = path.join(accountDir, organization);
    if (realDirectory(store) && realDirectory(accountDir) && realDirectory(organizationDir)) {
      return organizationDir;
    }
  }
  return null;
}

function pause(milliseconds) {
  try {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
    return true;
  } catch (_) {
    return false;
  }
}

function readBoundedFile(file, maxBytes) {
  let stat;
  try {
    stat = fs.lstatSync(file);
  } catch (error) {
    return { state: error && error.code === 'ENOENT' ? 'missing' : 'refused' };
  }
  if (stat.isSymbolicLink() || !stat.isFile() || stat.size > maxBytes) return { state: 'refused' };
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0) | (fs.constants.O_NONBLOCK || 0));
  } catch (error) {
    return { state: error && error.code === 'ENOENT' ? 'missing' : 'refused' };
  }
  try {
    const opened = fs.fstatSync(fd);
    if (!opened.isFile() || opened.size > maxBytes) return { state: 'refused' };
    const buffer = Buffer.alloc(opened.size + 1);
    let length = 0;
    let againBudget = READ_AGAIN_BUDGET;
    for (;;) {
      let count;
      try {
        count = fs.readSync(fd, buffer, length, buffer.length - length, null);
      } catch (error) {
        if (!error || (error.code !== 'EAGAIN' && error.code !== 'EWOULDBLOCK')) throw error;
        if (againBudget === 0) return { state: 'changing' };
        againBudget -= 1;
        pause(1);
        continue;
      }
      if (count === 0) break;
      length += count;
      if (length === buffer.length) return { state: 'changing' };
    }
    return { state: 'read', text: buffer.toString('utf8', 0, length) };
  } catch (_) {
    return { state: 'refused' };
  } finally {
    fs.closeSync(fd);
  }
}

function parseObject(text) {
  try {
    const value = JSON.parse(text);
    return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
  } catch (_) {
    return null;
  }
}

function readDesktopRecord(directory, hostSession) {
  const file = readBoundedFile(path.join(directory, `${hostSession}.json`), DESKTOP_RECORD_MAX_BYTES);
  if (file.state === 'changing') return { state: 'unreadable' };
  if (file.state !== 'read') return file;
  const record = parseObject(file.text);
  return record ? { state: 'read', record } : { state: 'unreadable' };
}

function gitEnvironment(env) {
  const out = {};
  for (const [name, value] of Object.entries(env)) {
    if (!name.startsWith('GIT_')) out[name] = value;
  }
  return out;
}

function gitCommonDirectory(root, env, run) {
  try {
    const out = run('git', ['--no-optional-locks', '-C', root, 'rev-parse', '--path-format=absolute', '--git-common-dir'], {
      env: gitEnvironment(env),
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: GIT_TIMEOUT_MS,
    });
    const value = String(out).trim();
    if (value === '' || !path.isAbsolute(value) || UNSAFE_PATH_RE.test(value)) return null;
    return fs.realpathSync.native(value);
  } catch (_) {
    return null;
  }
}

function compareRepositories(ownRoot, parentRoot, env, run) {
  if (typeof ownRoot !== 'string' || !path.isAbsolute(ownRoot)) return REPOSITORY.UNKNOWN;
  const own = gitCommonDirectory(ownRoot, env, run);
  const parent = gitCommonDirectory(parentRoot, env, run);
  if (!own || !parent) return REPOSITORY.UNKNOWN;
  return own === parent ? REPOSITORY.SAME : REPOSITORY.FOREIGN;
}

function readParentRoot(pluginData, expected, deps) {
  let recordsDirectory;
  try {
    recordsDirectory = deps.recordsDirectory(pluginData);
  } catch (_) {
    return { reason: REASONS.RECORDS_UNAVAILABLE };
  }
  const file = readBoundedFile(path.join(recordsDirectory, `${expected.key}.json`), CONTEXT_RECORD_MAX_BYTES);
  if (file.state !== 'read') return { reason: REASONS.PARENT_CONTEXT_UNAVAILABLE };
  const context = parseObject(file.text);
  if (
    !context
    || context.schema !== expected.schema.name
    || context.schema_version !== expected.schema.version
    || context.session_id_hash !== expected.hash
  ) {
    return { reason: REASONS.PARENT_CONTEXT_UNAVAILABLE };
  }
  const root = context.project_root;
  if (typeof root !== 'string' || !path.isAbsolute(root) || UNSAFE_PATH_RE.test(root)) {
    return { reason: REASONS.PARENT_CONTEXT_UNAVAILABLE };
  }
  try {
    if (!realDirectory(root) || fs.realpathSync.native(root) !== root) {
      return { reason: REASONS.PARENT_ROOT_UNAVAILABLE };
    }
  } catch (_) {
    return { reason: REASONS.PARENT_ROOT_UNAVAILABLE };
  }
  return { root };
}

function controlCore() {
  return require('./session-control-core-v1.js');
}

function defaultDeps() {
  return {
    sessionKey: (value) => controlCore().sessionKey(value),
    sessionIdHash: (value) => controlCore().sessionIdHash(value),
    contextSchema: () => ({ name: controlCore().SCHEMA, version: controlCore().SCHEMA_VERSION }),
    recordsDirectory: (pluginData) => {
      const binder = require('./claude-hook-session-v1.js');
      return binder.privateRecordsDirectory(binder.canonicalDirectory(pluginData, 'CLAUDE_PLUGIN_DATA', true));
    },
    run: execFileSync,
  };
}

function resolveLinkedSession(input = {}) {
  const env = input.env || process.env;
  const platform = input.platform || process.platform;
  const deps = Object.assign(defaultDeps(), input.deps || {});
  const hostSession = env.CLAUDE_CODE_HOST_SESSION_ID;
  if (typeof hostSession !== 'string' || hostSession === '') return verdict(KINDS.NONE, REASONS.NO_HOST_SESSION);
  if (!HOST_SESSION_RE.test(hostSession)) return verdict(KINDS.NONE, REASONS.MALFORMED_HOST_SESSION);
  const account = env.CLAUDE_CODE_ACCOUNT_UUID;
  const organization = env.CLAUDE_CODE_ORGANIZATION_UUID;
  if (!UUID_RE.test(String(account || '')) || !UUID_RE.test(String(organization || ''))) {
    return verdict(KINDS.NONE, REASONS.MALFORMED_ACCOUNT);
  }
  const sessionId = input.sessionId;
  if (typeof sessionId !== 'string' || sessionId === '') return verdict(KINDS.NONE, REASONS.NO_SESSION_ID);
  const directory = sessionDirectory(platform, env, account, organization);
  if (!directory) return verdict(KINDS.NONE, REASONS.NO_SESSION_STORE);

  const own = readDesktopRecord(directory, hostSession);
  if (own.state === 'missing') return verdict(KINDS.UNRESOLVED, REASONS.OWN_RECORD_MISSING);
  if (own.state === 'unreadable') return verdict(KINDS.UNRESOLVED, REASONS.OWN_RECORD_UNREADABLE);
  if (own.state !== 'read') return verdict(KINDS.NONE, REASONS.OWN_RECORD_REFUSED);
  if (own.record.sessionId !== hostSession) return verdict(KINDS.NONE, REASONS.OWN_RECORD_MISMATCH);
  const ownCli = own.record.cliSessionId;
  if (ownCli !== undefined && ownCli !== null && ownCli !== sessionId) {
    return verdict(KINDS.NONE, REASONS.CLI_SESSION_MISMATCH);
  }
  const spawnedFrom = own.record.spawnedFrom;
  if (!spawnedFrom || typeof spawnedFrom !== 'object' || Array.isArray(spawnedFrom)) {
    return verdict(KINDS.NONE, REASONS.NOT_LINKED);
  }
  const parentSession = spawnedFrom.sessionId;
  if (typeof parentSession !== 'string' || !HOST_SESSION_RE.test(parentSession) || parentSession === hostSession) {
    return verdict(KINDS.NONE, REASONS.MALFORMED_PARENT);
  }
  const turn = turnOf(own.record);

  const parent = readDesktopRecord(directory, parentSession);
  if (parent.state !== 'read' || parent.record.sessionId !== parentSession) {
    return verdict(KINDS.LINKED, REASONS.PARENT_RECORD_UNAVAILABLE, { turn });
  }
  const parentCli = parent.record.cliSessionId;
  if (typeof parentCli !== 'string' || !UUID_RE.test(parentCli)) {
    return verdict(KINDS.LINKED, REASONS.PARENT_SESSION_UNKNOWN, { turn });
  }
  let expected;
  try {
    expected = {
      key: deps.sessionKey(parentCli),
      hash: deps.sessionIdHash(parentCli),
      schema: deps.contextSchema(),
    };
  } catch (_) {
    return verdict(KINDS.LINKED, REASONS.PARENT_SESSION_UNKNOWN, { turn });
  }
  const parentRoot = readParentRoot(input.pluginData, expected, deps);
  if (!parentRoot.root) return verdict(KINDS.LINKED, parentRoot.reason, { turn });
  const repository = compareRepositories(input.projectRoot, parentRoot.root, env, deps.run);
  return verdict(KINDS.LINKED, REASONS.RESOLVED, {
    parentRoot: parentRoot.root,
    parentKey: expected.key,
    repository,
    turn,
  });
}

function renderVerdict(result) {
  return [
    result.kind,
    result.reason,
    result.parentRoot || EMPTY_FIELD,
    result.parentKey || EMPTY_FIELD,
    result.repository || EMPTY_FIELD,
    result.turn || EMPTY_FIELD,
  ].join('\t');
}

function main() {
  let result;
  try {
    result = resolveLinkedSession({
      env: process.env,
      sessionId: process.env.ZENSU_LINKED_SESSION_ID,
      projectRoot: process.env.ZENSU_LINKED_PROJECT_ROOT,
      pluginData: process.env.CLAUDE_PLUGIN_DATA,
    });
  } catch (_) {
    result = verdict(KINDS.NONE, REASONS.RESOLVER_FAILED);
  }
  process.stdout.write(`${renderVerdict(result)}\n`);
}

if (require.main === module) main();

module.exports = {
  KINDS,
  REPOSITORY,
  REASONS,
  TURNS,
  HOST_SESSION_RE,
  DESKTOP_RECORD_MAX_BYTES,
  CONTEXT_RECORD_MAX_BYTES,
  storeCandidates,
  resolveLinkedSession,
  renderVerdict,
};
