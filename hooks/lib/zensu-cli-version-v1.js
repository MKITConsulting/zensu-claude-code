'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const MIN_VERSION = '0.10.0';
const FLOOR_REASON = 'older releases print only the first 100 ghost-scan candidates and read only the first page of wiki lists';
const INSTALL = Object.freeze({
  homebrew: 'brew install --cask mkitconsulting/tap/zensu',
  homebrewUpgrade: 'brew upgrade --cask zensu',
  script: 'curl -fsSL https://zensu.dev/install.sh | sh',
  powershell: 'irm https://zensu.dev/install.ps1 | iex',
});
const STATES = Object.freeze({
  OK: 'ok',
  OLD: 'old',
  DEV: 'dev',
  UNREAD: 'unread',
  ABSENT: 'absent',
  CWD_RELATIVE: 'cwd-relative',
});
const WINDOWS_LOOKUP = Object.freeze(['zensu.exe', 'zensu.cmd', 'zensu']);
const POSIX_LOOKUP = Object.freeze(['zensu']);
const VERSION_TIMEOUT_MS = 5000;
const MAX_VERSION_OUTPUT_BYTES = 4096;
const MAX_VERSION_LENGTH = 64;
const SEMVER = '\\d+\\.\\d+\\.\\d+(?:-[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?';
const VERSION_RE = new RegExp(`^${SEMVER}$`);
const LINE_RE = new RegExp(`^zensu v?(${SEMVER}|dev)(?:\\s|$)`);

function result(state, version = '') {
  return { state, version };
}

function validVersion(value) {
  return typeof value === 'string' && value.length <= MAX_VERSION_LENGTH && VERSION_RE.test(value);
}

function parseVersionLine(line) {
  const match = typeof line === 'string' ? line.match(LINE_RE) : null;
  if (!match) return '';
  return match[1] === 'dev' || validVersion(match[1]) ? match[1] : '';
}

function parts(version) {
  const plain = version.split('+')[0];
  const dash = plain.indexOf('-');
  return {
    core: (dash === -1 ? plain : plain.slice(0, dash)).split('.').map(Number),
    pre: dash === -1 ? [] : plain.slice(dash + 1).split('.'),
  };
}

function compareIdentifiers(a, b) {
  const numericA = /^\d+$/.test(a);
  const numericB = /^\d+$/.test(b);
  if (numericA && numericB) return Math.sign(Number(a) - Number(b));
  if (numericA !== numericB) return numericA ? -1 : 1;
  return a < b ? -1 : (a > b ? 1 : 0);
}

function compareVersions(a, b) {
  const left = parts(a);
  const right = parts(b);
  for (let index = 0; index < 3; index += 1) {
    if (left.core[index] !== right.core[index]) return left.core[index] < right.core[index] ? -1 : 1;
  }
  if (left.pre.length === 0 || right.pre.length === 0) return Math.sign(right.pre.length - left.pre.length);
  for (let index = 0; index < Math.min(left.pre.length, right.pre.length); index += 1) {
    const order = compareIdentifiers(left.pre[index], right.pre[index]);
    if (order !== 0) return order;
  }
  return Math.sign(left.pre.length - right.pre.length);
}

function classify(version) {
  if (version === 'dev') return STATES.DEV;
  if (!validVersion(version)) return STATES.UNREAD;
  return compareVersions(version, MIN_VERSION) < 0 ? STATES.OLD : STATES.OK;
}

function firstLine(file) {
  const handle = fs.openSync(file, 'r');
  try {
    const buffer = Buffer.alloc(MAX_VERSION_OUTPUT_BYTES);
    const size = fs.readSync(handle, buffer, 0, buffer.length, 0);
    return buffer.subarray(0, size).toString('utf8').split(/\r?\n/)[0];
  } finally {
    fs.closeSync(handle);
  }
}

function reportedLine(binary, env, timeoutMs, platform) {
  if (platform === 'win32' && /\.(cmd|bat)$/i.test(binary)) return '';
  let dir;
  try { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-cli-probe-')); }
  catch (_error) { return ''; }
  const out = path.join(dir, 'version.txt');
  try {
    const fd = fs.openSync(out, 'w', 0o600);
    try {
      spawnSync(binary, ['--version'], {
        stdio: ['ignore', fd, 'ignore'],
        env: Object.assign({}, env, { ZENSU_NO_UPDATE_CHECK: '1' }),
        timeout: timeoutMs,
        killSignal: 'SIGKILL',
        windowsHide: true,
      });
    } finally {
      fs.closeSync(fd);
    }
    return firstLine(out);
  } catch (_error) {
    return '';
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function probe(options = {}) {
  const binary = typeof options.binary === 'string' ? options.binary : '';
  if (binary === '') return result(STATES.ABSENT);
  const version = parseVersionLine(reportedLine(
    binary,
    options.env || process.env,
    options.timeoutMs || VERSION_TIMEOUT_MS,
    options.platform || process.platform,
  ));
  return version ? result(classify(version), version) : result(STATES.UNREAD);
}

function executable(file, platform) {
  try {
    if (!fs.statSync(file).isFile()) return false;
    if (platform !== 'win32') fs.accessSync(file, fs.constants.X_OK);
    return true;
  } catch (_error) {
    return false;
  }
}

function binaryNames(platform = process.platform) {
  return platform === 'win32' ? WINDOWS_LOOKUP : POSIX_LOOKUP;
}

function lookup(env, platform, cwd) {
  const names = binaryNames(platform);
  const value = env ? env.PATH || env.Path || '' : '';
  let unstable = null;
  for (const entry of String(value).split(platform === 'win32' ? ';' : ':')) {
    const relative = entry === '' || !path.isAbsolute(entry);
    if (relative && unstable === null) unstable = entry;
    const dir = relative ? path.resolve(cwd, entry) : entry;
    for (const name of names) {
      const candidate = path.join(dir, name);
      if (executable(candidate, platform)) return { binary: candidate, unstable };
    }
  }
  return { binary: '', unstable: null };
}

function findBinary(env = process.env, platform = process.platform, cwd = process.cwd()) {
  return lookup(env, platform, cwd).binary;
}

function installedVersion(env = process.env, platform = process.platform, cwd = process.cwd(), timeoutMs = VERSION_TIMEOUT_MS) {
  const found = lookup(env, platform, cwd);
  if (found.unstable !== null) return Object.assign(result(STATES.CWD_RELATIVE), { entry: found.unstable });
  if (found.binary === '') return result(STATES.ABSENT);
  return Object.assign(probe({ binary: found.binary, env, platform, timeoutMs }), { binary: found.binary });
}

function cliMain(argv, out) {
  let binary = null;
  let onPath = false;
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--binary' && typeof argv[index + 1] === 'string') {
      binary = argv[index + 1];
      index += 1;
    } else if (argv[index] === '--lookup') {
      onPath = true;
    } else {
      return false;
    }
  }
  if (onPath === (binary !== null)) return false;
  const found = onPath ? installedVersion() : probe({ binary });
  out.write(`state=${found.state}\nversion=${found.version}\nfloor=${MIN_VERSION}\n`);
  return true;
}

module.exports = {
  FLOOR_REASON,
  INSTALL,
  MIN_VERSION,
  STATES,
  VERSION_TIMEOUT_MS,
  binaryNames,
  classify,
  cliMain,
  compareVersions,
  findBinary,
  installedVersion,
  parseVersionLine,
  probe,
  validVersion,
};

if (require.main === module) {
  if (!cliMain(process.argv.slice(2), process.stdout)) {
    process.stderr.write('usage: zensu-cli-version-v1.js (--lookup | --binary <path>)\n');
    process.exitCode = 2;
  }
}
