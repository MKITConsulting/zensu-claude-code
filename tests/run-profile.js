#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawn } = require('node:child_process');
const { loadProfileContract } = require('./windows-profile-contract.js');

const EXIT_SUITE = 1;
const EXIT_MANIFEST = 2;
const MANIFEST_RELATIVE_PATH = 'tests/profiles/windows-ci.v1.json';
const CATALOG_RELATIVE_PATH = 'tests/profiles/windows-ci-command-catalog.v1.json';
const SUPERVISOR_RELATIVE_PATH = 'tests/profile-suite-supervisor.js';
const WINDOWS_JOB_HELPER_RELATIVE_PATH = 'tests/windows-profile-job.ps1';
const MAX_TIMEOUT_MS = 60 * 60 * 1000;
const MAX_PROFILE_TIMEOUT_MS = 60 * 60 * 1000;
const HEARTBEAT_MS = 30 * 1000;
const PROFILE_SANDBOX_PREFIX = 'zp-';
const PROFILE_ID = /^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/;
const SUITE_ID = /^[a-z0-9](?:[a-z0-9-]{0,126}[a-z0-9])?$/;
const ROOT_KEYS = new Set(['schemaVersion', 'profiles']);
const PROFILE_KEYS = new Set(['platform', 'profileTimeoutMs', 'suites']);
const SUITE_KEYS = new Set(['id', 'runner', 'path', 'args', 'timeoutMs']);
const CATALOG_KEYS = new Set(['schemaVersion', 'commands']);
const CATALOG_COMMAND_KEYS = new Set(['runner', 'path', 'args']);
const SAFE_ENVIRONMENT_KEYS = [
  'PATH',
  'SystemRoot',
  'SYSTEMROOT',
  'WINDIR',
  'ComSpec',
  'COMSPEC',
  'PATHEXT',
  'CI',
  'GITHUB_ACTIONS',
  'RUNNER_OS',
  'RUNNER_ARCH',
  'NUMBER_OF_PROCESSORS',
  'PROCESSOR_ARCHITECTURE',
  'PROCESSOR_IDENTIFIER',
  'TERM',
  'COLORTERM',
  'NO_COLOR',
  'LANG',
  'LC_ALL',
  'LC_CTYPE',
  'MSYSTEM',
  'MSYS',
  'CHERE_INVOKING',
  'SHELL',
];
const FORBIDDEN_ARGUMENT = /^(?:--live(?:=|$)|--(?:require|import|eval|loader|experimental-loader|inspect|inspect-brk|env-file|input-type)(?:=|$)|-(?:e|r)$)/i;

class ManifestError extends Error {}

function isPlainObject(value) {
  return value !== null
    && typeof value === 'object'
    && !Array.isArray(value)
    && Object.getPrototypeOf(value) === Object.prototype;
}

function requirePlainObject(value, label) {
  if (!isPlainObject(value)) throw new ManifestError(`${label} must be an object`);
}

function rejectUnknownKeys(value, allowed, label) {
  const unknown = Object.keys(value).filter((key) => !allowed.has(key));
  if (unknown.length > 0) {
    throw new ManifestError(`${label} has unknown key(s): ${unknown.join(', ')}`);
  }
}

function canonicalRoot(root) {
  const resolved = fs.realpathSync.native(path.resolve(root));
  if (!fs.statSync(resolved).isDirectory()) {
    throw new ManifestError('repository root must be a directory');
  }
  return resolved;
}

function serializeStat(info) {
  return {
    dev: info.dev.toString(),
    ino: info.ino.toString(),
    mode: info.mode.toString(),
    size: info.size.toString(),
    nlink: info.nlink.toString(),
  };
}

function captureRelativeFile(root, relative, label) {
  if (typeof relative !== 'string' || relative.length === 0) {
    throw new ManifestError(`${label} path must be a non-empty string`);
  }
  if (/[\u0000-\u001f\u007f\\]/.test(relative)) {
    throw new ManifestError(`${label} path must use printable forward-slash repo-relative syntax`);
  }
  if (path.posix.isAbsolute(relative) || /^[a-zA-Z]:/.test(relative)) {
    throw new ManifestError(`${label} path must be repo-relative`);
  }
  const normalized = path.posix.normalize(relative);
  if (normalized !== relative || relative === '.' || relative.startsWith('../')) {
    throw new ManifestError(`${label} path traversal is forbidden`);
  }

  const components = [];
  let cursor = root;
  for (const segment of relative.split('/')) {
    cursor = path.join(cursor, segment);
    let info;
    try {
      info = fs.lstatSync(cursor, { bigint: true });
    } catch (error) {
      if (error.code === 'ENOENT') {
        throw new ManifestError(`${label} path does not exist: ${relative}`);
      }
      throw error;
    }
    if (info.isSymbolicLink()) {
      throw new ManifestError(`${label} path must not traverse a symlink: ${relative}`);
    }
    components.push({ path: cursor, ...serializeStat(info) });
  }
  const resolved = fs.realpathSync.native(cursor);
  const boundary = path.relative(root, resolved);
  if (boundary === '..' || boundary.startsWith(`..${path.sep}`) || path.isAbsolute(boundary)) {
    throw new ManifestError(`${label} path resolves outside the repository`);
  }
  const final = fs.statSync(resolved, { bigint: true });
  if (!final.isFile()) throw new ManifestError(`${label} path must be a regular file`);
  if (final.nlink !== 1n) throw new ManifestError(`${label} path must not be multiply linked`);
  const source = fs.readFileSync(resolved);
  return Object.freeze({
    absolutePath: resolved,
    components: Object.freeze(components.map((entry) => Object.freeze(entry))),
    sha256: crypto.createHash('sha256').update(source).digest('hex'),
  });
}

function revalidateFileBinding(root, relative, expected, label) {
  const actual = captureRelativeFile(root, relative, label);
  if (actual.absolutePath !== expected.absolutePath
      || actual.sha256 !== expected.sha256
      || JSON.stringify(actual.components) !== JSON.stringify(expected.components)) {
    throw new ManifestError(`${label} identity or content drifted after validation`);
  }
  return actual;
}

function validateArgument(value, label) {
  if (typeof value !== 'string' || value.length > 4096 || /[\u0000\r\n]/.test(value)) {
    throw new ManifestError(`${label} must be a bounded single-line string`);
  }
  if (FORBIDDEN_ARGUMENT.test(value)) {
    throw new ManifestError(`${label} must not enable live/API or interpreter preload mode`);
  }
  return value;
}

function commandKey(runner, relativePath, args) {
  return JSON.stringify([runner, relativePath, args]);
}

function validateManifest(manifest, rootInput, options = {}) {
  const root = canonicalRoot(rootInput);
  requirePlainObject(manifest, 'manifest');
  rejectUnknownKeys(manifest, ROOT_KEYS, 'manifest');
  if (manifest.schemaVersion !== 1) {
    throw new ManifestError('manifest schemaVersion must be 1');
  }
  requirePlainObject(manifest.profiles, 'manifest profiles');
  const profileEntries = Object.entries(manifest.profiles);
  if (profileEntries.length === 0) throw new ManifestError('manifest profiles must not be empty');

  const profiles = new Map();
  const suiteIds = new Set();
  const commandKeys = new Set();
  for (const [profileId, profile] of profileEntries) {
    if (!PROFILE_ID.test(profileId)) throw new ManifestError(`invalid profile id: ${profileId}`);
    requirePlainObject(profile, `profile ${profileId}`);
    rejectUnknownKeys(profile, PROFILE_KEYS, `profile ${profileId}`);
    if (!['darwin', 'linux', 'win32'].includes(profile.platform)) {
      throw new ManifestError(`profile ${profileId} platform is unsupported`);
    }
    if (options.requiredPlatform && profile.platform !== options.requiredPlatform) {
      throw new ManifestError(`profile ${profileId} platform must be ${options.requiredPlatform}`);
    }
    if (!Number.isInteger(profile.profileTimeoutMs)
        || profile.profileTimeoutMs < 1
        || profile.profileTimeoutMs > MAX_PROFILE_TIMEOUT_MS) {
      throw new ManifestError(
        `profile ${profileId} profileTimeoutMs must be an integer between 1 and ${MAX_PROFILE_TIMEOUT_MS}`,
      );
    }
    if (!Array.isArray(profile.suites) || profile.suites.length === 0) {
      throw new ManifestError(`profile ${profileId} suites must be a non-empty array`);
    }
    const suites = profile.suites.map((entry, index) => {
      const label = `profile ${profileId} suite ${index + 1}`;
      requirePlainObject(entry, label);
      rejectUnknownKeys(entry, SUITE_KEYS, label);
      if (!SUITE_ID.test(entry.id)) throw new ManifestError(`${label} has invalid id`);
      if (suiteIds.has(entry.id)) throw new ManifestError(`duplicate suite id: ${entry.id}`);
      suiteIds.add(entry.id);
      if (!['bash', 'node'].includes(entry.runner)) {
        throw new ManifestError(`${label} runner must be bash or node`);
      }
      const binding = captureRelativeFile(root, entry.path, label);
      if (!Array.isArray(entry.args)) throw new ManifestError(`${label} args must be an array`);
      const args = entry.args.map((value, argumentIndex) => (
        validateArgument(value, `${label} arg ${argumentIndex + 1}`)
      ));
      if (!Number.isInteger(entry.timeoutMs)
          || entry.timeoutMs < 1
          || entry.timeoutMs > MAX_TIMEOUT_MS) {
        throw new ManifestError(
          `${label} timeoutMs must be an integer between 1 and ${MAX_TIMEOUT_MS}`,
        );
      }
      const key = commandKey(entry.runner, entry.path, args);
      if (commandKeys.has(key)) {
        throw new ManifestError(`duplicate suite command: ${entry.runner} ${entry.path}`);
      }
      if (options.approvedCommands && !options.approvedCommands.has(key)) {
        throw new ManifestError(`${label} command is absent from the audited catalog`);
      }
      commandKeys.add(key);
      return Object.freeze({
        id: entry.id,
        runner: entry.runner,
        path: entry.path,
        absolutePath: binding.absolutePath,
        binding,
        args: Object.freeze(args),
        timeoutMs: entry.timeoutMs,
      });
    });
    profiles.set(profileId, Object.freeze({
      id: profileId,
      platform: profile.platform,
      profileTimeoutMs: profile.profileTimeoutMs,
      suites: Object.freeze(suites),
    }));
  }
  if (options.approvedCommands) {
    const missing = [...options.approvedCommands].filter((key) => !commandKeys.has(key));
    if (missing.length > 0) throw new ManifestError('audited catalog contains unassigned commands');
  }
  return Object.freeze({
    root,
    manifestSha256: crypto.createHash('sha256').update(JSON.stringify(manifest)).digest('hex'),
    profiles,
  });
}

function loadJson(root, relative, label) {
  const binding = captureRelativeFile(root, relative, label);
  let source;
  try {
    source = fs.readFileSync(binding.absolutePath, 'utf8');
  } catch (error) {
    throw new ManifestError(`failed to read ${relative}: ${error.message}`);
  }
  let value;
  try {
    value = JSON.parse(source);
  } catch (error) {
    throw new ManifestError(`invalid JSON in ${relative}: ${error.message}`);
  }
  revalidateFileBinding(root, relative, binding, label);
  return { value, source, binding };
}

function loadApprovedCommands(root) {
  const { value, source, binding } = loadJson(root, CATALOG_RELATIVE_PATH, 'command catalog');
  requirePlainObject(value, 'command catalog');
  rejectUnknownKeys(value, CATALOG_KEYS, 'command catalog');
  if (value.schemaVersion !== 1 || !Array.isArray(value.commands) || value.commands.length === 0) {
    throw new ManifestError('command catalog schema is invalid');
  }
  const commands = new Set();
  for (const [index, entry] of value.commands.entries()) {
    const label = `command catalog entry ${index + 1}`;
    requirePlainObject(entry, label);
    rejectUnknownKeys(entry, CATALOG_COMMAND_KEYS, label);
    if (!['bash', 'node'].includes(entry.runner)) throw new ManifestError(`${label} runner is invalid`);
    captureRelativeFile(root, entry.path, label);
    if (!Array.isArray(entry.args)) throw new ManifestError(`${label} args must be an array`);
    const args = entry.args.map((argument, argumentIndex) => (
      validateArgument(argument, `${label} arg ${argumentIndex + 1}`)
    ));
    const key = commandKey(entry.runner, entry.path, args);
    if (commands.has(key)) throw new ManifestError(`${label} duplicates an audited command`);
    commands.add(key);
  }
  return Object.freeze({
    commands,
    sha256: crypto.createHash('sha256').update(source).digest('hex'),
    binding,
  });
}

function loadAndValidateManifest(rootInput) {
  const root = canonicalRoot(rootInput);
  const catalog = loadApprovedCommands(root);
  const { value, source, binding } = loadJson(root, MANIFEST_RELATIVE_PATH, 'profile manifest');
  const validated = validateManifest(value, root, {
    requiredPlatform: 'win32',
    approvedCommands: catalog.commands,
  });
  let contract;
  try {
    contract = loadProfileContract(root);
  } catch (error) {
    throw new ManifestError(`failed to load the complete Windows profile contract: ${error.message}`);
  }
  const manifestSha256 = crypto.createHash('sha256').update(source).digest('hex');
  if (contract.manifestSha256 !== manifestSha256
      || contract.commandCatalogSha256 !== catalog.sha256) {
    throw new ManifestError('complete Windows profile contract drifted during validation');
  }
  return Object.freeze({
    ...validated,
    manifestSha256,
    catalogSha256: catalog.sha256,
    profileContractSha256: contract.profileContractSha256,
    manifestBinding: binding,
    catalogBinding: catalog.binding,
    manifestPath: path.join(root, ...MANIFEST_RELATIVE_PATH.split('/')),
  });
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function raceWithTimeout(promise, timeoutMs) {
  let timer;
  const timeoutToken = Symbol('timeout');
  try {
    return await Promise.race([
      promise,
      new Promise((resolve) => { timer = setTimeout(() => resolve(timeoutToken), timeoutMs); }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

function groupAlive(pid) {
  try {
    process.kill(-pid, 0);
    return true;
  } catch (error) {
    if (error.code === 'ESRCH') return false;
    if (error.code === 'EPERM') return true;
    throw error;
  }
}

async function waitForGroupExit(pid, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (groupAlive(pid) && Date.now() < deadline) await delay(50);
  return !groupAlive(pid);
}

function spawnAndWait(command, args, options, timeoutMs) {
  return new Promise((resolve) => {
    const child = spawn(command, args, options);
    let settled = false;
    let timer;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolve(result);
    };
    child.once('error', (error) => finish({ status: null, signal: null, error }));
    child.once('close', (status, signal) => finish({ status, signal, error: null }));
    timer = setTimeout(() => {
      try { child.kill('SIGKILL'); } catch (_error) {}
      finish({
        status: null,
        signal: null,
        error: new Error(`cleanup command timed out after ${timeoutMs}ms`),
      });
    }, timeoutMs);
  });
}

async function terminateOwnedTree(child, platform, environment) {
  if (!child.pid) throw new Error('owned suite process has no pid');
  if (platform === 'win32') {
    const systemRoot = environment.SystemRoot
      || environment.SYSTEMROOT
      || process.env.SystemRoot
      || process.env.SYSTEMROOT;
    if (!systemRoot) throw new Error('SystemRoot is unavailable for taskkill');
    const taskkill = path.join(systemRoot, 'System32', 'taskkill.exe');
    const result = await spawnAndWait(
      taskkill,
      ['/PID', String(child.pid), '/T', '/F'],
      { stdio: 'ignore', windowsHide: true },
      10000,
    );
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`taskkill failed with exit ${String(result.status)}`);
    return { status: 'terminated', mechanism: 'windows-job-object-taskkill-tree' };
  }
  try {
    process.kill(-child.pid, 'SIGTERM');
  } catch (error) {
    if (error.code === 'ESRCH') return { status: 'terminated', mechanism: 'already-exited' };
    throw error;
  }
  if (await waitForGroupExit(child.pid, 1500)) {
    return { status: 'terminated', mechanism: 'process-group-term' };
  }
  try {
    process.kill(-child.pid, 'SIGKILL');
  } catch (error) {
    if (error.code !== 'ESRCH') throw error;
  }
  if (!await waitForGroupExit(child.pid, 3000)) {
    throw new Error('owned suite process group survived SIGKILL');
  }
  return { status: 'terminated', mechanism: 'process-group-kill' };
}

function monotonicMilliseconds(start) {
  return Number(process.hrtime.bigint() - start) / 1_000_000;
}

function ensureSafeDirectory(directory) {
  const absolute = path.resolve(directory);
  if (fs.existsSync(absolute)) {
    const requested = fs.lstatSync(absolute);
    if (requested.isSymbolicLink() || !requested.isDirectory()) {
      throw new ManifestError(`report directory is unsafe: ${absolute}`);
    }
  } else {
    fs.mkdirSync(absolute, { recursive: true, mode: 0o700 });
  }
  const resolved = fs.realpathSync.native(absolute);
  const parsed = path.parse(resolved);
  let cursor = parsed.root;
  for (const segment of resolved.slice(parsed.root.length).split(path.sep).filter(Boolean)) {
    cursor = path.join(cursor, segment);
    const info = fs.lstatSync(cursor);
    if (info.isSymbolicLink() || !info.isDirectory()) {
      throw new ManifestError(`report directory traverses an unsafe component: ${cursor}`);
    }
  }
  try { fs.chmodSync(absolute, 0o700); } catch (_error) {}
  return resolved;
}

function atomicWriteJson(file, value) {
  const directory = ensureSafeDirectory(path.dirname(file));
  const destination = path.join(directory, path.basename(file));
  if (fs.existsSync(destination)) {
    const info = fs.lstatSync(destination);
    if (info.isSymbolicLink() || !info.isFile() || info.nlink !== 1) {
      throw new ManifestError('report destination must be a singly linked regular file');
    }
  }
  const temporary = `${destination}.${process.pid}.${crypto.randomBytes(12).toString('hex')}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, {
    encoding: 'utf8',
    mode: 0o600,
    flag: 'wx',
  });
  try {
    fs.renameSync(temporary, destination);
  } catch (error) {
    try { fs.unlinkSync(temporary); } catch (_cleanupError) {}
    throw error;
  }
}

function lookupEnvironment(environment, key, platform) {
  if (platform !== 'win32') return environment[key];
  const found = Object.keys(environment).find((candidate) => candidate.toUpperCase() === key.toUpperCase());
  return found ? environment[found] : undefined;
}

function buildSuiteEnvironment(environment, sandboxRoot, platform) {
  const result = {};
  const includedKeys = new Set();
  for (const key of SAFE_ENVIRONMENT_KEYS) {
    const normalizedKey = platform === 'win32' ? key.toUpperCase() : key;
    if (includedKeys.has(normalizedKey)) continue;
    const value = lookupEnvironment(environment, key, platform);
    if (typeof value === 'string' && !/[\u0000\r\n]/.test(value)) {
      result[key] = value;
      includedKeys.add(normalizedKey);
    }
  }
  const home = path.join(sandboxRoot, 'home');
  const temporary = path.join(sandboxRoot, 'tmp');
  const appData = path.join(home, 'AppData', 'Roaming');
  const localAppData = path.join(home, 'AppData', 'Local');
  for (const directory of [home, temporary, appData, localAppData]) {
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  }
  Object.assign(result, {
    HOME: home,
    USERPROFILE: home,
    APPDATA: appData,
    LOCALAPPDATA: localAppData,
    TMPDIR: temporary,
    TMP: temporary,
    TEMP: temporary,
    ZENSU_PROFILE_OFFLINE: '1',
  });
  return result;
}

function resolveExecutable(name, environment, platform) {
  const pathValue = lookupEnvironment(environment, 'PATH', platform);
  if (!pathValue) throw new ManifestError(`PATH is unavailable while resolving ${name}`);
  const suffixes = platform === 'win32'
    ? ['', ...(lookupEnvironment(environment, 'PATHEXT', platform) || '.EXE;.CMD;.BAT')
      .split(';').map((entry) => entry.toLowerCase())]
    : [''];
  for (const directory of pathValue.split(path.delimiter).filter(Boolean)) {
    for (const suffix of suffixes) {
      const candidate = path.join(directory, `${name}${suffix}`);
      try {
        const resolved = fs.realpathSync.native(candidate);
        if (fs.statSync(resolved).isFile()) return resolved;
      } catch (_error) {}
    }
  }
  throw new ManifestError(`trusted ${name} executable was not found on PATH`);
}

function commandForSuite(suite, bashExecutable) {
  if (suite.runner === 'bash') {
    return { command: bashExecutable, args: [suite.absolutePath, ...suite.args] };
  }
  return { command: process.execPath, args: [...suite.args, suite.absolutePath] };
}

function forwardWithBackpressure(stream, output) {
  let resolveCompletion;
  const completion = new Promise((resolve) => {
    resolveCompletion = resolve;
  });
  let completed = false;
  const complete = () => {
    if (completed) return;
    completed = true;
    resolveCompletion();
  };
  stream.on('data', (chunk) => {
    const accepted = output.write(chunk);
    if (accepted === false && typeof stream.pause === 'function' && typeof output.once === 'function') {
      stream.pause();
      output.once('drain', () => stream.resume());
    }
  });
  stream.once('end', complete);
  stream.once('close', complete);
  stream.once('error', complete);
  return completion;
}

function readableCompletion(stream) {
  return new Promise((resolve) => {
    let completed = false;
    const complete = () => {
      if (completed) return;
      completed = true;
      resolve();
    };
    stream.once('end', complete);
    stream.once('close', complete);
    stream.once('error', complete);
  });
}

function readSupervisorResult(stream) {
  return new Promise((resolve) => {
    let buffer = '';
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      resolve(value);
    };
    stream.setEncoding('utf8');
    stream.on('data', (chunk) => {
      buffer += chunk;
      if (Buffer.byteLength(buffer, 'utf8') > 64 * 1024) {
        finish({ protocolError: 'supervisor result exceeded its bound' });
        return;
      }
      const newline = buffer.indexOf('\n');
      if (newline < 0) return;
      try {
        const value = JSON.parse(buffer.slice(0, newline));
        if (!isPlainObject(value)
            || value.schemaVersion !== 1
            || value.type !== 'suite-result'
            || !Object.hasOwn(value, 'exitCode')
            || !Object.hasOwn(value, 'signal')
            || !Object.hasOwn(value, 'spawnError')) {
          throw new Error('shape');
        }
        finish({ value });
      } catch (_error) {
        finish({ protocolError: 'supervisor result was invalid' });
      }
    });
    stream.once('error', (error) => finish({ protocolError: error.message }));
    stream.once('end', () => finish({ protocolError: 'supervisor result ended early' }));
  });
}

async function executeSuite({
  suite,
  root,
  environment,
  output,
  platform,
  onActiveCleanup,
  bashExecutable,
  supervisorPath,
  windowsJobHelperPath,
  effectiveTimeoutMs,
  timeoutScope,
  terminateProcessTree = terminateOwnedTree,
  heartbeatMs = HEARTBEAT_MS,
  cleanupCloseTimeoutMs = 5000,
}) {
  revalidateFileBinding(root, suite.path, suite.binding, `suite ${suite.id}`);
  const command = commandForSuite(suite, bashExecutable);
  const payload = Buffer.from(JSON.stringify({
    ...command,
    cwd: root,
    environment,
    windowsJobHelper: windowsJobHelperPath,
  }), 'utf8').toString('base64url');
  const startedAt = new Date().toISOString();
  const started = process.hrtime.bigint();
  output.write(`\n=== START ${suite.id} (timeout ${effectiveTimeoutMs}ms) ===\n`);
  const child = spawn(process.execPath, [supervisorPath, payload], {
    cwd: root,
    env: environment,
    detached: platform !== 'win32',
    stdio: ['ignore', 'pipe', 'pipe', 'pipe'],
    windowsHide: true,
  });
  const stdoutCompleted = forwardWithBackpressure(child.stdout, output);
  const stderrCompleted = forwardWithBackpressure(child.stderr, output);
  const resultChannelCompleted = readableCompletion(child.stdio[3]);
  const supervisorResult = readSupervisorResult(child.stdio[3]);
  const wrapperClosed = new Promise((resolve) => {
    child.once('close', (exitCode, signal) => resolve({ exitCode, signal }));
  });
  let wrapperSpawnError = null;
  child.once('error', (error) => { wrapperSpawnError = error; });

  let cleanupPromise = null;
  const ensureCleanup = () => {
    if (!cleanupPromise) {
      cleanupPromise = (async () => {
        try {
          return await terminateProcessTree(child, platform, environment);
        } catch (firstError) {
          if (terminateProcessTree !== terminateOwnedTree) {
            try {
              const fallback = await terminateOwnedTree(child, platform, environment);
              throw Object.assign(new Error(
                `${firstError.message}; fallback ${fallback.mechanism} recovered the process tree`,
              ), { recovered: fallback });
            } catch (fallbackError) {
              if (fallbackError.recovered) throw fallbackError;
              throw new Error(`${firstError.message}; fallback cleanup failed: ${fallbackError.message}`);
            }
          }
          await delay(100);
          try {
            return await terminateOwnedTree(child, platform, environment);
          } catch (retryError) {
            throw new Error(`${firstError.message}; cleanup retry failed: ${retryError.message}`);
          }
        }
      })();
    }
    return cleanupPromise;
  };
  onActiveCleanup(ensureCleanup);

  const heartbeat = setInterval(() => {
    output.write(`--- HEARTBEAT ${suite.id} elapsed=${Math.round(monotonicMilliseconds(started))}ms ---\n`);
  }, heartbeatMs);
  let completion;
  try {
    completion = await raceWithTimeout(
      Promise.race([
        supervisorResult.then((result) => ({ kind: 'result', result })),
        wrapperClosed.then((result) => ({ kind: 'wrapper-close', result })),
      ]),
      effectiveTimeoutMs,
    );
  } finally {
    clearInterval(heartbeat);
  }

  let status = 'failed';
  let exitCode = null;
  let signal = null;
  let spawnError = null;
  if (typeof completion === 'symbol') {
    status = 'timed_out';
  } else if (completion.kind === 'result') {
    if (completion.result.protocolError) {
      status = 'spawn_error';
      spawnError = completion.result.protocolError;
    } else {
      ({ exitCode, signal, spawnError } = completion.result.value);
      if (spawnError) status = 'spawn_error';
      else status = exitCode === 0 && signal === null ? 'passed' : 'failed';
    }
  } else {
    exitCode = completion.result.exitCode;
    signal = completion.result.signal;
    status = 'spawn_error';
    spawnError = wrapperSpawnError?.message || 'suite supervisor exited before reporting';
  }

  let cleanup;
  let cleanupFailure = null;
  try {
    cleanup = await ensureCleanup();
  } catch (error) {
    cleanup = {
      status: error.recovered ? 'failed_recovered' : 'failed',
      mechanism: error.recovered?.mechanism || null,
      error: error.message,
    };
    cleanupFailure = error;
  }
  let finalClose = await raceWithTimeout(wrapperClosed, cleanupCloseTimeoutMs);
  if (typeof finalClose === 'symbol') {
    let recovery = null;
    let recoveryError = null;
    try {
      recovery = await terminateOwnedTree(child, platform, environment);
    } catch (error) {
      recoveryError = error;
    }
    finalClose = await raceWithTimeout(wrapperClosed, cleanupCloseTimeoutMs);
    const message = typeof finalClose === 'symbol'
      ? `suite supervisor survived cleanup recovery${recoveryError ? `: ${recoveryError.message}` : ''}`
      : 'suite supervisor required cleanup recovery after the primary cleanup returned';
    cleanup = {
      status: typeof finalClose === 'symbol' ? 'failed' : 'failed_recovered',
      mechanism: recovery?.mechanism || cleanup.mechanism || null,
      error: message,
    };
    cleanupFailure ||= new Error(message);
  }
  const streamsCompleted = await raceWithTimeout(
    Promise.all([stdoutCompleted, stderrCompleted, resultChannelCompleted]),
    cleanupCloseTimeoutMs,
  );
  if (typeof streamsCompleted === 'symbol') {
    const message = 'suite supervisor streams remained open after process cleanup';
    cleanup = {
      status: 'failed',
      mechanism: cleanup.mechanism || null,
      error: message,
    };
    cleanupFailure ||= new Error(message);
  }
  onActiveCleanup(null);
  const durationMs = monotonicMilliseconds(started);
  output.write(`=== ${status.toUpperCase()} ${suite.id} (${Math.round(durationMs)}ms) ===\n`);
  return {
    result: {
      id: suite.id,
      path: suite.path,
      args: [...suite.args],
      executedSha256: suite.binding.sha256,
      timeoutMs: suite.timeoutMs,
      effectiveTimeoutMs,
      timeoutScope: status === 'timed_out' ? timeoutScope : null,
      status,
      exitCode,
      signal,
      startedAt,
      endedAt: new Date().toISOString(),
      durationMs,
      cleanup,
      ...(spawnError ? { spawnError } : {}),
    },
    cleanupFailure,
  };
}

function boundedProvenance(value, label) {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value !== 'string' || value.length > 256 || /[\u0000\r\n]/.test(value)) {
    throw new ManifestError(`${label} is invalid`);
  }
  return value;
}

function reportDirectoryFromEnvironment(environment, platform) {
  const requested = environment.ZENSU_PROFILE_REPORT_DIR;
  if (!requested) return undefined;
  if (typeof requested !== 'string' || /[\u0000\r\n]/.test(requested) || !path.isAbsolute(requested)) {
    throw new ManifestError('ZENSU_PROFILE_REPORT_DIR must be an absolute path');
  }
  if (environment.GITHUB_ACTIONS === 'true') {
    const runnerTemp = lookupEnvironment(environment, 'RUNNER_TEMP', platform);
    if (!runnerTemp || !path.isAbsolute(runnerTemp)) {
      throw new ManifestError('RUNNER_TEMP is required for GitHub Actions profile reports');
    }
    const boundary = path.relative(path.resolve(runnerTemp), path.resolve(requested));
    if (boundary === '..' || boundary.startsWith(`..${path.sep}`) || path.isAbsolute(boundary)) {
      throw new ManifestError('profile report directory must remain below RUNNER_TEMP');
    }
  }
  return requested;
}

async function runProfile({
  manifest,
  profileId,
  root: rootInput,
  reportDirectory,
  environment = process.env,
  output = process.stdout,
  platform = process.platform,
  installSignalHandlers = false,
  signalEmitter = process,
  terminateProcessTree = terminateOwnedTree,
  heartbeatMs = HEARTBEAT_MS,
  cleanupCloseTimeoutMs = 5000,
  sourceGitRevision = null,
  runId = null,
  runAttempt = null,
  eventName = null,
  runnerImage = null,
  supervisorPath = path.join(__dirname, 'profile-suite-supervisor.js'),
  windowsJobHelperPath = path.join(__dirname, 'windows-profile-job.ps1'),
}) {
  const validated = manifest?.profiles instanceof Map
    ? manifest
    : validateManifest(manifest, rootInput);
  const profile = validated.profiles.get(profileId);
  if (!profile) throw new ManifestError(`unknown profile: ${profileId}`);
  if (profile.platform !== platform) {
    throw new ManifestError(`profile ${profileId} requires ${profile.platform}, current platform is ${platform}`);
  }
  const supervisorBinding = captureRelativeFile(
    path.dirname(supervisorPath),
    path.basename(supervisorPath),
    'suite supervisor',
  );
  const windowsJobHelperBinding = captureRelativeFile(
    path.dirname(windowsJobHelperPath),
    path.basename(windowsJobHelperPath),
    'windows job helper',
  );
  const reports = ensureSafeDirectory(
    reportDirectory || fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-windows-profile-report-')),
  );
  const reportPath = path.join(reports, `${profileId}.json`);
  // Keep the runner-owned prefix deliberately short. Windows suites create
  // security-bound filenames containing multiple SHA-256 values below this
  // root; a descriptive prefix can exhaust Git/Win32 path headroom before the
  // contract under test is reached.
  const sandboxRoot = fs.mkdtempSync(path.join(os.tmpdir(), PROFILE_SANDBOX_PREFIX));
  const suiteEnvironment = buildSuiteEnvironment(environment, sandboxRoot, platform);
  const bashExecutable = resolveExecutable('bash', environment, platform);
  const started = process.hrtime.bigint();
  const report = {
    schemaVersion: 3,
    manifestSha256: validated.manifestSha256,
    commandCatalogSha256: validated.catalogSha256 || null,
    profileContractSha256: validated.profileContractSha256
      || crypto.createHash('sha256')
        .update(`unit-test:${validated.manifestSha256}:${validated.catalogSha256 || ''}`)
        .digest('hex'),
    sourceGitRevision: boundedProvenance(sourceGitRevision, 'sourceGitRevision'),
    runId: boundedProvenance(runId, 'runId'),
    runAttempt: boundedProvenance(runAttempt, 'runAttempt'),
    eventName: boundedProvenance(eventName, 'eventName'),
    runnerImage: boundedProvenance(runnerImage, 'runnerImage'),
    profile: profileId,
    profileTimeoutMs: profile.profileTimeoutMs,
    platform,
    nodeVersion: process.version,
    status: 'running',
    startedAt: new Date().toISOString(),
    endedAt: null,
    durationMs: null,
    suites: [],
  };
  atomicWriteJson(reportPath, report);

  let activeCleanup = null;
  let interrupted = null;
  let signalWork = null;
  const signalHandlers = new Map();
  if (installSignalHandlers) {
    const signals = [['SIGINT', 130], ['SIGTERM', 143]];
    if (platform === 'win32') signals.push(['SIGBREAK', 131]);
    for (const [signalName, exitCode] of signals) {
      const handler = () => {
        if (interrupted) return;
        interrupted = { signalName, exitCode };
        report.status = 'cancelled';
        signalWork = (async () => {
          if (activeCleanup) {
            try {
              await activeCleanup();
            } catch (error) {
              report.cleanupError = error.message;
            }
          }
        })();
      };
      signalEmitter.on(signalName, handler);
      signalHandlers.set(signalName, handler);
    }
  }

  let abort = false;
  try {
    for (const suite of profile.suites) {
      if (abort || interrupted) break;
      revalidateFileBinding(
        path.dirname(supervisorPath),
        path.basename(supervisorPath),
        supervisorBinding,
        'suite supervisor',
      );
      revalidateFileBinding(
        path.dirname(windowsJobHelperPath),
        path.basename(windowsJobHelperPath),
        windowsJobHelperBinding,
        'windows job helper',
      );
      const elapsed = monotonicMilliseconds(started);
      const remaining = Math.floor(profile.profileTimeoutMs - elapsed);
      if (remaining <= 0) {
        report.profileDeadlineExceeded = true;
        abort = true;
        break;
      }
      const execution = await executeSuite({
        suite,
        root: validated.root,
        environment: suiteEnvironment,
        output,
        platform,
        onActiveCleanup(cleanup) { activeCleanup = cleanup; },
        bashExecutable,
        supervisorPath,
        windowsJobHelperPath,
        effectiveTimeoutMs: Math.min(suite.timeoutMs, remaining),
        timeoutScope: remaining < suite.timeoutMs ? 'profile' : 'suite',
        terminateProcessTree,
        heartbeatMs,
        cleanupCloseTimeoutMs,
      });
      report.suites.push(execution.result);
      atomicWriteJson(reportPath, report);
      if (execution.cleanupFailure) abort = true;
      if (execution.result.timeoutScope === 'profile') report.profileDeadlineExceeded = true;
    }
    if (signalWork) await signalWork;
    if (interrupted) report.status = 'cancelled';
    else if (abort || report.suites.some((suite) => suite.status !== 'passed')) report.status = 'failed';
    else report.status = 'passed';
    report.endedAt = new Date().toISOString();
    report.durationMs = monotonicMilliseconds(started);
    atomicWriteJson(reportPath, report);
  } finally {
    for (const [signalName, handler] of signalHandlers) {
      signalEmitter.removeListener(signalName, handler);
    }
    if (!report.suites.some((suite) => suite.cleanup.status === 'failed')) {
      fs.rmSync(sandboxRoot, { recursive: true, force: true });
    }
  }
  return {
    exitCode: report.status === 'passed' ? 0 : (interrupted?.exitCode || EXIT_SUITE),
    report,
    reportPath,
  };
}

function readGitRevision(root, environment, platform) {
  const git = resolveExecutable('git', environment, platform);
  const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-git-env-'));
  let revision;
  try {
    revision = execFileSync(git, ['-C', root, 'rev-parse', 'HEAD'], {
      encoding: 'utf8',
      env: buildSuiteEnvironment(environment, sandbox, platform),
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 10000,
    }).trim();
  } catch (_error) {
    throw new ManifestError('failed to resolve the checked-out Git revision');
  } finally {
    fs.rmSync(sandbox, { recursive: true, force: true });
  }
  if (!/^[a-f0-9]{40}$/i.test(revision)) throw new ManifestError('checked-out Git revision is invalid');
  const expected = environment.ZENSU_PROFILE_SOURCE_SHA || environment.GITHUB_SHA;
  if (expected && revision.toLowerCase() !== String(expected).toLowerCase()) {
    throw new ManifestError('checked-out Git revision does not match the workflow source SHA');
  }
  return revision.toLowerCase();
}

async function main({
  root = path.resolve(__dirname, '..'),
  argv = process.argv.slice(2),
  stdout = process.stdout,
  stderr = process.stderr,
  environment = process.env,
  platform = process.platform,
  installSignalHandlers = true,
  sourceGitRevision = null,
  terminateProcessTree = terminateOwnedTree,
  supervisorPath = path.join(__dirname, 'profile-suite-supervisor.js'),
  windowsJobHelperPath = path.join(__dirname, 'windows-profile-job.ps1'),
} = {}) {
  try {
    const validated = loadAndValidateManifest(root);
    const [profileId, ...extra] = argv;
    if (extra.length > 0 || !profileId) {
      throw new ManifestError('usage: node tests/run-profile.js <profile-id>|--validate');
    }
    if (profileId === '--validate') {
      stdout.write(`windows profile manifest: PASS (${validated.profiles.size} profiles)\n`);
      return 0;
    }
    const revision = sourceGitRevision || readGitRevision(validated.root, environment, platform);
    const result = await runProfile({
      manifest: validated,
      profileId,
      root,
      reportDirectory: reportDirectoryFromEnvironment(environment, platform),
      environment,
      output: stdout,
      platform,
      installSignalHandlers,
      terminateProcessTree,
      supervisorPath,
      windowsJobHelperPath,
      sourceGitRevision: revision,
      runId: environment.GITHUB_RUN_ID,
      runAttempt: environment.GITHUB_RUN_ATTEMPT,
      eventName: environment.GITHUB_EVENT_NAME,
      runnerImage: environment.ImageOS || environment.RUNNER_OS,
    });
    stdout.write(`Windows profile report: ${result.reportPath}\n`);
    return result.exitCode;
  } catch (error) {
    if (!(error instanceof ManifestError)) throw error;
    stderr.write(`windows profile manifest error: ${error.message}\n`);
    return EXIT_MANIFEST;
  }
}

if (require.main === module) {
  main()
    .then((exitCode) => { process.exitCode = exitCode; })
    .catch((error) => {
      process.stderr.write(`windows profile runner failure: ${error.stack || error.message}\n`);
      process.exitCode = EXIT_SUITE;
    });
}

module.exports = {
  EXIT_MANIFEST,
  EXIT_SUITE,
  ManifestError,
  atomicWriteJson,
  buildSuiteEnvironment,
  captureRelativeFile,
  loadAndValidateManifest,
  main,
  raceWithTimeout,
  runProfile,
  spawnAndWait,
  terminateOwnedTree,
  validateManifest,
};
