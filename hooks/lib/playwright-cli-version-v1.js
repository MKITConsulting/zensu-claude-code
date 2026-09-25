'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PACKAGE_NAME = '@playwright/cli';
const BINARY_NAMES = Object.freeze(['playwright-cli', 'playwright-cli.cmd', 'playwright-cli.exe', 'playwright-cli.ps1']);
const WINDOWS_LOOKUP = Object.freeze(['playwright-cli.cmd', 'playwright-cli.exe', 'playwright-cli.ps1', 'playwright-cli']);
const POSIX_LOOKUP = Object.freeze(['playwright-cli']);
const MAX_MANIFEST_BYTES = 65536;
const MANIFEST_DIRECTORIES = 4;
const VERSION_TIMEOUT_MS = 5000;
const MAX_VERSION_OUTPUT_BYTES = 4096;
const MAX_VERSION_LENGTH = 64;
const MAX_NAME_LENGTH = 214;
const SEMVER = '\\d+\\.\\d+\\.\\d+(?:-[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?';
const VERSION_RE = new RegExp(`^${SEMVER}$`);
const REPORTED_RE = new RegExp(SEMVER);
const PACKAGE_NAME_RE = /^(?:@[a-z0-9][a-z0-9._~-]*\/)?[a-z0-9][a-z0-9._~-]*$/;
const SOURCES = Object.freeze({
  ABSENT: 'absent',
  MANIFEST: 'manifest',
  FOREIGN: 'foreign',
  MALFORMED: 'malformed',
  SELF_REPORTED: 'self-reported',
  UNREAD: 'unread',
  CWD_RELATIVE: 'cwd-relative',
});

function result(source, version = '', owner = '') {
  return { source, version, owner };
}

function validVersion(value) {
  return typeof value === 'string' && value.length <= MAX_VERSION_LENGTH && VERSION_RE.test(value);
}

function validName(value) {
  return typeof value === 'string' && value.length <= MAX_NAME_LENGTH && PACKAGE_NAME_RE.test(value);
}

function readManifest(file) {
  let info;
  try { info = fs.statSync(file); }
  catch (error) {
    return error && (error.code === 'ENOENT' || error.code === 'ENOTDIR') ? null : result(SOURCES.MALFORMED);
  }
  if (!info.isFile() || info.size > MAX_MANIFEST_BYTES) return result(SOURCES.MALFORMED);
  let doc;
  try {
    const raw = fs.readFileSync(file, 'utf8');
    if (Buffer.byteLength(raw) > MAX_MANIFEST_BYTES) return result(SOURCES.MALFORMED);
    doc = JSON.parse(raw.charCodeAt(0) === 65279 ? raw.slice(1) : raw);
  } catch (_error) {
    return result(SOURCES.MALFORMED);
  }
  if (!doc || typeof doc !== 'object' || Array.isArray(doc) || !validName(doc.name)) return result(SOURCES.MALFORMED);
  if (doc.name !== PACKAGE_NAME) return result(SOURCES.FOREIGN, '', doc.name);
  if (!validVersion(doc.version)) return result(SOURCES.MALFORMED);
  return result(SOURCES.MANIFEST, doc.version, doc.name);
}

function manifestFor(binary) {
  let real;
  try { real = fs.realpathSync(binary); }
  catch (_error) { return null; }
  const shim = readManifest(path.join(path.dirname(path.resolve(binary)), 'node_modules', ...PACKAGE_NAME.split('/'), 'package.json'));
  if (shim) return shim;
  let dir = path.dirname(real);
  for (let hop = 0; hop < MANIFEST_DIRECTORIES; hop += 1) {
    const found = readManifest(path.join(dir, 'package.json'));
    if (found) return found;
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}

function firstReportedVersion(file) {
  const handle = fs.openSync(file, 'r');
  try {
    const buffer = Buffer.alloc(MAX_VERSION_OUTPUT_BYTES);
    const size = fs.readSync(handle, buffer, 0, buffer.length, 0);
    const line = buffer.subarray(0, size).toString('utf8').split(/\r?\n/)[0];
    const match = line.match(REPORTED_RE);
    return match && validVersion(match[0]) ? match[0] : '';
  } finally {
    fs.closeSync(handle);
  }
}

function selfReported(binary, env, timeoutMs, platform) {
  if (platform === 'win32' && /\.(cmd|bat)$/i.test(binary)) return '';
  let dir;
  try { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-cli-version-')); }
  catch (_error) { return ''; }
  const out = path.join(dir, 'version.txt');
  try {
    const fd = fs.openSync(out, 'w', 0o600);
    try {
      spawnSync(binary, ['--version'], {
        stdio: ['ignore', fd, 'ignore'],
        env: Object.assign({}, env, { NO_UPDATE_NOTIFIER: '1' }),
        timeout: timeoutMs,
        killSignal: 'SIGKILL',
        windowsHide: true,
      });
    } finally {
      fs.closeSync(fd);
    }
    return firstReportedVersion(out);
  } catch (_error) {
    return '';
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function probe(options = {}) {
  const binary = typeof options.binary === 'string' ? options.binary : '';
  if (binary === '') return result(SOURCES.ABSENT);
  const found = manifestFor(binary);
  if (found) return found;
  if (!options.execute) return result(SOURCES.UNREAD);
  const reported = selfReported(
    binary,
    options.env || process.env,
    options.timeoutMs || VERSION_TIMEOUT_MS,
    options.platform || process.platform,
  );
  return reported ? result(SOURCES.SELF_REPORTED, reported) : result(SOURCES.UNREAD);
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

function installedVersion(env = process.env, platform = process.platform, cwd = process.cwd(), execute = false) {
  const found = lookup(env, platform, cwd);
  if (found.unstable !== null) return Object.assign(result(SOURCES.CWD_RELATIVE), { entry: found.unstable });
  return probe({ binary: found.binary, env, platform, execute });
}

function cliMain(argv, out) {
  let binary = null;
  let onPath = false;
  let execute = false;
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--binary' && typeof argv[index + 1] === 'string') {
      binary = argv[index + 1];
      index += 1;
    } else if (argv[index] === '--lookup') {
      onPath = true;
    } else if (argv[index] === '--execute') {
      execute = true;
    } else {
      return false;
    }
  }
  if (onPath && binary !== null) return false;
  const found = onPath ? installedVersion(process.env, process.platform, process.cwd(), execute) : probe({ binary: binary || '', execute });
  out.write(`source=${found.source}\nversion=${found.version}\nowner=${found.owner}\n`);
  return true;
}

module.exports = {
  BINARY_NAMES,
  MAX_MANIFEST_BYTES,
  PACKAGE_NAME,
  SOURCES,
  VERSION_TIMEOUT_MS,
  binaryNames,
  cliMain,
  findBinary,
  installedVersion,
  probe,
  validName,
  validVersion,
};

if (require.main === module) {
  if (!cliMain(process.argv.slice(2), process.stdout)) {
    process.stderr.write('usage: playwright-cli-version-v1.js (--binary <path> | --lookup) [--execute]\n');
    process.exitCode = 2;
  }
}
