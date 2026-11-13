'use strict';
const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');

const AUTH_DIR_NAME = 'auth';
const STATE_FILE_NAME = 'storage-state.json';
const ARTIFACT_DIR_NAME = 'artifact';
const IGNORE_FILE_NAME = '.gitignore';
const IGNORE_BODY = '*\n';
const RUNS_DIR_NAME = 'verify-feature-runs';
const ZENSU_DIR_NAME = '.zensu';
const AUTH_SESSION_PREFIX = 'zensu-verify-auth-';
const AUTH_GUARD_HOOK_FILE = 'pre-verify-auth-guard.sh';
const AUTH_GUARD_TOOLS = Object.freeze(['Read', 'Grep', 'Glob', 'NotebookEdit', 'Edit', 'Write', 'MultiEdit', 'Bash', 'PowerShell']);
const AUTH_GUARD_MATCHER = '.*';
const AUTH_GUARD_PROBE_TOOLS = Object.freeze([...AUTH_GUARD_TOOLS, 'mcp__server__read_file']);
const STATE_LINE_KEY = 'STORAGE_STATE';
const MAX_STATE_BYTES = 1024 * 1024;
const MAX_COOKIES = 256;
const MAX_ORIGINS = 64;
const STATE_KEYS = Object.freeze(['cookies', 'origins']);
const COOKIE_KEYS = Object.freeze(['name', 'value', 'domain', 'path', 'expires', 'httpOnly', 'secure', 'sameSite', 'partitionKey', '_crHasCrossSiteAncestor']);
const COOKIE_STRINGS = Object.freeze(['name', 'value', 'domain']);
const COOKIE_BOOLEANS = Object.freeze(['httpOnly', 'secure', '_crHasCrossSiteAncestor']);
const ORIGIN_KEYS = Object.freeze(['origin', 'localStorage']);
const ENTRY_KEYS = Object.freeze(['name', 'value']);
const SAME_SITE = Object.freeze(['Strict', 'Lax', 'None']);
const TEMP_STATE_RE = /^\.storage-state\.json\.[0-9a-f]{12}\.tmp$/;
const FAULTS = Object.freeze({
  MISSING: 'missing',
  UNSAFE: 'unsafe',
  TOO_LARGE: 'too-large',
  NOT_JSON: 'not-json',
  SHAPE: 'shape',
  SCOPE: 'scope',
  EMPTY: 'empty',
});
const POSIX = process.platform !== 'win32';

function isAuthSession(name) {
  return typeof name === 'string' && name.startsWith(AUTH_SESSION_PREFIX);
}

function plainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.getPrototypeOf(value) === Object.prototype;
}

function keysWithin(value, allowed) {
  return Object.keys(value).every((key) => allowed.includes(key));
}

function canonicalOrigin(value) {
  if (typeof value !== 'string' || value === '') return '';
  try {
    return new URL(value).origin === value ? value : '';
  } catch (_error) {
    return '';
  }
}

function hostnameOf(origin) {
  try {
    return new URL(origin).hostname.replace(/^\[|\]$/g, '').toLowerCase();
  } catch (_error) {
    return '';
  }
}

function unbracketed(text) {
  const match = /^\[([^\]]*)\]$/.exec(text);
  return match ? match[1] : text;
}

function domainMatches(domain, host) {
  if (typeof domain !== 'string' || typeof host !== 'string' || domain === '' || host === '') return false;
  const lowered = domain.toLowerCase();
  const dotted = lowered.startsWith('.');
  const bare = unbracketed(dotted ? lowered.slice(1) : lowered);
  if (bare === '') return false;
  if (host === bare) return true;
  return dotted && net.isIP(host) === 0 && host.endsWith(`.${bare}`);
}

function cookieShape(cookie) {
  if (!plainObject(cookie) || !keysWithin(cookie, COOKIE_KEYS)) return false;
  if (!COOKIE_STRINGS.every((key) => typeof cookie[key] === 'string')) return false;
  if (cookie.name === '') return false;
  const bare = cookie.domain.replace(/^\./, '');
  if (!(/^[A-Za-z0-9._-]+$/.test(bare) || net.isIP(unbracketed(bare)) === 6)) return false;
  if (cookie.path !== undefined && typeof cookie.path !== 'string') return false;
  if (cookie.expires !== undefined && (typeof cookie.expires !== 'number' || !Number.isFinite(cookie.expires))) return false;
  if (COOKIE_BOOLEANS.some((key) => cookie[key] !== undefined && typeof cookie[key] !== 'boolean')) return false;
  if (cookie.sameSite !== undefined && !SAME_SITE.includes(cookie.sameSite)) return false;
  return cookie.partitionKey === undefined || typeof cookie.partitionKey === 'string';
}

function originShape(entry) {
  if (!plainObject(entry) || !keysWithin(entry, ORIGIN_KEYS)) return false;
  if (canonicalOrigin(entry.origin) === '' || !Array.isArray(entry.localStorage)) return false;
  return entry.localStorage.every((item) => plainObject(item) && keysWithin(item, ENTRY_KEYS)
    && typeof item.name === 'string' && typeof item.value === 'string');
}

function normalizedState(value) {
  return {
    cookies: value.cookies === undefined ? [] : value.cookies,
    origins: value.origins === undefined ? [] : value.origins,
  };
}

function stateShape(value) {
  if (!plainObject(value) || !keysWithin(value, STATE_KEYS)) return false;
  const { cookies, origins } = normalizedState(value);
  if (!Array.isArray(cookies) || !Array.isArray(origins)) return false;
  if (cookies.length > MAX_COOKIES || origins.length > MAX_ORIGINS) return false;
  return cookies.every(cookieShape) && origins.every(originShape);
}

function scopeHosts(origins) {
  return [...new Set((Array.isArray(origins) ? origins : []).map(hostnameOf).filter(Boolean))];
}

function cookieInScope(cookie, hosts) {
  return hosts.some((host) => domainMatches(cookie.domain, host));
}

function inScope(state, origins) {
  const hosts = scopeHosts(origins);
  const normalized = normalizedState(state);
  return normalized.cookies.every((cookie) => cookieInScope(cookie, hosts))
    && normalized.origins.every((entry) => origins.includes(entry.origin));
}

function scopeState(state, origins) {
  const hosts = scopeHosts(origins);
  const normalized = normalizedState(state);
  return {
    cookies: normalized.cookies.filter((cookie) => cookieInScope(cookie, hosts)),
    origins: normalized.origins.filter((entry) => origins.includes(entry.origin)),
  };
}

function emptyState(state) {
  const normalized = normalizedState(state);
  return normalized.cookies.length === 0 && normalized.origins.length === 0;
}

function parseState(text) {
  if (typeof text !== 'string') return { ok: false, fault: FAULTS.NOT_JSON };
  if (Buffer.byteLength(text, 'utf8') > MAX_STATE_BYTES) return { ok: false, fault: FAULTS.TOO_LARGE };
  let value;
  try {
    value = JSON.parse(text);
  } catch (_error) {
    return { ok: false, fault: FAULTS.NOT_JSON };
  }
  if (!stateShape(value)) return { ok: false, fault: FAULTS.SHAPE };
  return { ok: true, state: normalizedState(value) };
}

function dirState(dir) {
  try {
    return fs.lstatSync(dir).isDirectory() ? 'ok' : 'unsafe';
  } catch (error) {
    return error && (error.code === 'ENOENT' || error.code === 'ENOTDIR') ? 'missing' : 'unsafe';
  }
}

function readFlags() {
  const { O_RDONLY, O_NOFOLLOW, O_NONBLOCK } = fs.constants;
  return POSIX ? O_RDONLY | (O_NOFOLLOW || 0) | (O_NONBLOCK || 0) : O_RDONLY;
}

function readBounded(file, options = {}) {
  let before;
  try {
    before = fs.lstatSync(file);
  } catch (error) {
    return { ok: false, fault: error && (error.code === 'ENOENT' || error.code === 'ENOTDIR') ? FAULTS.MISSING : FAULTS.UNSAFE };
  }
  if (!before.isFile() || before.nlink !== 1) return { ok: false, fault: FAULTS.UNSAFE };
  let fd;
  try {
    fd = fs.openSync(file, readFlags());
  } catch (error) {
    return { ok: false, fault: error && error.code === 'ENOENT' ? FAULTS.MISSING : FAULTS.UNSAFE };
  }
  try {
    const info = fs.fstatSync(fd);
    if (!info.isFile() || info.nlink !== 1 || info.ino !== before.ino || info.dev !== before.dev) return { ok: false, fault: FAULTS.UNSAFE };
    if (options.ownerOnly && POSIX) {
      if ((info.mode & 0o077) !== 0) return { ok: false, fault: FAULTS.UNSAFE };
      if (typeof process.getuid === 'function' && info.uid !== process.getuid()) return { ok: false, fault: FAULTS.UNSAFE };
    }
    if (info.size > MAX_STATE_BYTES) return { ok: false, fault: FAULTS.TOO_LARGE };
    const buffer = Buffer.alloc(MAX_STATE_BYTES + 1);
    let length = 0;
    while (length < buffer.length) {
      const read = fs.readSync(fd, buffer, length, buffer.length - length, null);
      if (read === 0) break;
      length += read;
    }
    if (length > MAX_STATE_BYTES) return { ok: false, fault: FAULTS.TOO_LARGE };
    return { ok: true, text: buffer.subarray(0, length).toString('utf8') };
  } catch (_error) {
    return { ok: false, fault: FAULTS.UNSAFE };
  } finally {
    try {
      fs.closeSync(fd);
    } catch (_error) {
      fd = null;
    }
  }
}

function checkStateFile(file, origins) {
  const directory = dirState(path.dirname(file));
  if (directory !== 'ok') return { ok: false, fault: directory === 'missing' ? FAULTS.MISSING : FAULTS.UNSAFE };
  const read = readBounded(file, { ownerOnly: true });
  if (!read.ok) return read;
  const parsed = parseState(read.text);
  if (!parsed.ok) return parsed;
  if (!inScope(parsed.state, origins)) return { ok: false, fault: FAULTS.SCOPE };
  if (emptyState(parsed.state)) return { ok: false, fault: FAULTS.EMPTY };
  return { ok: true, state: parsed.state };
}

function runDirLayout(runDir) {
  if (typeof runDir !== 'string' || !path.isAbsolute(runDir)) return { ok: false };
  const runsDir = path.dirname(runDir);
  const zensuDir = path.dirname(runsDir);
  if (runsDir === runDir || zensuDir === runsDir) return { ok: false };
  if (path.basename(runsDir) !== RUNS_DIR_NAME || path.basename(zensuDir) !== ZENSU_DIR_NAME) return { ok: false };
  return { ok: true, projectRoot: path.dirname(zensuDir), runsDir };
}

function statePathFor(runDir) {
  return path.join(runDir, AUTH_DIR_NAME, STATE_FILE_NAME);
}

function configRunDir(configPath) {
  try {
    return fs.realpathSync.native(path.dirname(configPath));
  } catch (_error) {
    return '';
  }
}

function consumeStateFile(configPath) {
  const runDir = configRunDir(configPath);
  if (runDir === '' || !runDirLayout(runDir).ok) return { removed: false, reason: 'no-run-directory' };
  const file = statePathFor(runDir);
  if (dirState(path.dirname(file)) !== 'ok') return { removed: false, reason: 'no-auth-directory' };
  let info;
  try {
    info = fs.lstatSync(file);
  } catch (error) {
    return { removed: false, reason: error && error.code === 'ENOENT' ? 'absent' : 'unreadable' };
  }
  if (info.isDirectory()) return { removed: false, reason: 'not-a-file' };
  try {
    fs.unlinkSync(file);
  } catch (error) {
    return { removed: false, reason: `unlink-failed:${error && error.code ? error.code : 'unknown'}` };
  }
  return { removed: true, file };
}

function removeLeaf(file) {
  let info;
  try {
    info = fs.lstatSync(file);
  } catch (error) {
    if (error && error.code === 'ENOENT') return;
    throw error;
  }
  if (info.isDirectory()) throw new Error('the auth directory holds a directory where the state file belongs');
  fs.unlinkSync(file);
}

function prepareAuthDir(runDir) {
  const authDir = path.join(runDir, AUTH_DIR_NAME);
  const state = dirState(authDir);
  if (state === 'unsafe') throw new Error('the run directory carries an auth entry that is not a plain directory');
  if (state === 'missing') {
    fs.mkdirSync(authDir, { mode: 0o700 });
  } else {
    const foreign = fs.readdirSync(authDir).filter((name) => ![IGNORE_FILE_NAME, STATE_FILE_NAME, ARTIFACT_DIR_NAME].includes(name)
      && !TEMP_STATE_RE.test(name));
    if (foreign.length > 0) throw new Error('the run directory auth folder holds entries this helper did not write; start a fresh run directory');
  }
  if (POSIX) fs.chmodSync(authDir, 0o700);
  const ignoreFile = path.join(authDir, IGNORE_FILE_NAME);
  let ignoreInfo = null;
  try {
    ignoreInfo = fs.lstatSync(ignoreFile);
  } catch (error) {
    if (!error || error.code !== 'ENOENT') throw error;
  }
  if (ignoreInfo === null) {
    fs.writeFileSync(ignoreFile, IGNORE_BODY, { mode: 0o600, flag: 'wx' });
  } else if (!ignoreInfo.isFile() || fs.readFileSync(ignoreFile, 'utf8') !== IGNORE_BODY) {
    throw new Error('the run directory auth folder carries an ignore file this helper did not write');
  }
  for (const name of fs.readdirSync(authDir)) {
    if (TEMP_STATE_RE.test(name)) removeLeaf(path.join(authDir, name));
  }
  removeLeaf(path.join(authDir, STATE_FILE_NAME));
  const artifactDir = path.join(authDir, ARTIFACT_DIR_NAME);
  fs.rmSync(artifactDir, { recursive: true, force: true });
  fs.mkdirSync(artifactDir, { mode: 0o700 });
  if (POSIX) fs.chmodSync(artifactDir, 0o700);
  return { authDir, artifactDir, statePath: path.join(authDir, STATE_FILE_NAME) };
}

function removeArtifactDir(artifactDir) {
  try {
    fs.rmSync(artifactDir, { recursive: true, force: true });
    return true;
  } catch (_error) {
    return false;
  }
}

function discardAuthState(runDir) {
  if (!runDirLayout(runDir).ok) return { ok: false, reason: `the run directory must be <project>/${ZENSU_DIR_NAME}/${RUNS_DIR_NAME}/<leaf>` };
  const authDir = path.join(runDir, AUTH_DIR_NAME);
  const state = dirState(authDir);
  if (state === 'missing') return { ok: true, removed: false };
  if (state !== 'ok') return { ok: false, reason: 'the run directory carries an auth entry that is not a plain directory' };
  try {
    fs.rmSync(authDir, { recursive: true, force: true });
  } catch (_error) {
    return { ok: false, reason: 'the auth directory of the run could not be removed' };
  }
  return { ok: true, removed: true };
}

function writeStateFile(file, state) {
  const body = `${JSON.stringify(normalizedState(state))}\n`;
  if (Buffer.byteLength(body, 'utf8') > MAX_STATE_BYTES) return { ok: false, fault: FAULTS.TOO_LARGE };
  const temp = path.join(path.dirname(file), `.${STATE_FILE_NAME}.${crypto.randomBytes(6).toString('hex')}.tmp`);
  try {
    const fd = fs.openSync(temp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
    try {
      fs.writeSync(fd, body);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    if (POSIX) fs.chmodSync(temp, 0o600);
    fs.renameSync(temp, file);
  } catch (_error) {
    try {
      fs.unlinkSync(temp);
    } catch (_ignore) {
      return { ok: false, fault: FAULTS.UNSAFE };
    }
    return { ok: false, fault: FAULTS.UNSAFE };
  }
  return { ok: true, file };
}

function artifactLine(stdout) {
  if (typeof stdout !== 'string') return { ok: false };
  const text = stdout.replace(/\r?\n$/, '');
  const prefix = `${STATE_LINE_KEY}=`;
  if (/[\r\n]/.test(text) || !text.startsWith(prefix) || text.length === prefix.length) return { ok: false };
  return { ok: true, value: text.slice(prefix.length) };
}

function artifactFile(value, artifactDir) {
  if (typeof value !== 'string' || !path.isAbsolute(value) || /[\0]/.test(value)) return { ok: false };
  let info;
  let realDir;
  let realArtifactDir;
  try {
    info = fs.lstatSync(value);
    realDir = fs.realpathSync.native(path.dirname(value));
    realArtifactDir = fs.realpathSync.native(artifactDir);
  } catch (_error) {
    return { ok: false };
  }
  if (!info.isFile() || info.nlink !== 1) return { ok: false };
  if (realDir !== realArtifactDir && !realDir.startsWith(`${realArtifactDir}${path.sep}`)) return { ok: false };
  return { ok: true, file: path.join(realDir, path.basename(value)) };
}

module.exports = {
  ARTIFACT_DIR_NAME,
  AUTH_DIR_NAME,
  AUTH_GUARD_HOOK_FILE,
  AUTH_GUARD_MATCHER,
  AUTH_GUARD_PROBE_TOOLS,
  AUTH_GUARD_TOOLS,
  AUTH_SESSION_PREFIX,
  COOKIE_KEYS,
  FAULTS,
  IGNORE_BODY,
  IGNORE_FILE_NAME,
  MAX_COOKIES,
  MAX_ORIGINS,
  MAX_STATE_BYTES,
  ORIGIN_KEYS,
  RUNS_DIR_NAME,
  STATE_FILE_NAME,
  STATE_KEYS,
  STATE_LINE_KEY,
  ZENSU_DIR_NAME,
  artifactFile,
  artifactLine,
  canonicalOrigin,
  checkStateFile,
  consumeStateFile,
  discardAuthState,
  domainMatches,
  emptyState,
  inScope,
  isAuthSession,
  parseState,
  prepareAuthDir,
  readBounded,
  removeArtifactDir,
  runDirLayout,
  scopeState,
  stateShape,
  statePathFor,
  writeStateFile,
};
