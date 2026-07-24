#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { CLAUDE_CREDENTIAL_NAMES, credentialFreeEnvironment } = require('./upgrade-environment.js');

class UpgradeLinuxSandboxError extends Error {}

const BWRAP = '/usr/bin/bwrap';
const BASE_SYSTEM_ROOTS = Object.freeze([
  '/usr',
  '/bin',
  '/lib',
  '/lib64',
  '/etc/ssl',
  '/etc/ca-certificates',
]);
const NETWORK_RESOLUTION_FILES = Object.freeze([
  '/etc/resolv.conf',
  '/etc/hosts',
  '/etc/nsswitch.conf',
]);
const EXECUTABLE_ROOTS = Object.freeze(['/usr', '/bin', '/opt']);
const OPT_ROOT = '/opt';
const EXECUTABLE_HEADER_BYTES = 512;
const MAX_ARGUMENT_PAYLOAD_BYTES = 1024 * 1024;
const MAX_NETWORK_CONFIG_BYTES = 1024 * 1024;

function sandboxError(message) {
  return new UpgradeLinuxSandboxError(`upgrade Linux sandbox: ${message}`);
}

function sameIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino;
}

function sameExecutableIdentity(left, right) {
  return sameIdentity(left, right)
    && left.size === right.size
    && left.mode === right.mode
    && left.uid === right.uid
    && left.mtimeMs === right.mtimeMs
    && left.ctimeMs === right.ctimeMs;
}

function captureCanonicalDirectory(input, label, runtime = fs) {
  if (typeof input !== 'string' || !path.isAbsolute(input) || /[\0\r\n]/.test(input)) {
    throw sandboxError(`${label} is invalid`);
  }
  let before;
  let after;
  let canonical;
  try {
    before = runtime.lstatSync(input);
    canonical = runtime.realpathSync.native(input);
    after = runtime.lstatSync(input);
  } catch (_error) {
    throw sandboxError(`${label} is unavailable`);
  }
  if (!before.isDirectory() || before.isSymbolicLink()
      || !after.isDirectory() || after.isSymbolicLink()
      || canonical !== input || !sameIdentity(before, after)) {
    throw sandboxError(`${label} must be a canonical real directory`);
  }
  return {
    canonical,
    dev: after.dev,
    ino: after.ino,
    mode: after.mode,
    uid: after.uid,
  };
}

function evaluatorUid(runtime) {
  if (Number.isSafeInteger(runtime?.evaluatorUid) && runtime.evaluatorUid >= 0) {
    return runtime.evaluatorUid;
  }
  if (typeof process.geteuid === 'function') return process.geteuid();
  throw sandboxError('evaluator ownership cannot be established');
}

function requireOwnedDirectory(identity, label, runtime) {
  if (identity.uid !== evaluatorUid(runtime)
      || !Number.isInteger(identity.mode)
      || (identity.mode & 0o077) !== 0) {
    throw sandboxError(`${label} is not evaluator-owned and private`);
  }
}

function revalidateDirectoryIdentity(identity, label, runtime, owned = false) {
  const current = captureCanonicalDirectory(identity.canonical, label, runtime);
  if (!sameIdentity(identity, current)) throw sandboxError(`${label} identity changed`);
  if (owned) requireOwnedDirectory(current, label, runtime);
  return current;
}

function captureCanonicalExecutable(input, label, runtime = fs) {
  if (typeof input !== 'string' || !path.isAbsolute(input) || /[\0\r\n]/.test(input)) {
    throw sandboxError(`${label} is invalid`);
  }
  let before;
  let after;
  let canonical;
  try {
    before = runtime.lstatSync(input);
    canonical = runtime.realpathSync.native(input);
    after = runtime.lstatSync(input);
  } catch (_error) {
    throw sandboxError(`${label} is unavailable`);
  }
  if (!before.isFile() || before.isSymbolicLink()
      || !after.isFile() || after.isSymbolicLink()
      || canonical !== input || !sameExecutableIdentity(before, after)
      || !Number.isInteger(after.mode) || (after.mode & 0o111) === 0
      || !Number.isInteger(after.uid)
      || !Number.isSafeInteger(after.size) || after.size < 0
      || !Number.isFinite(after.mtimeMs) || !Number.isFinite(after.ctimeMs)) {
    throw sandboxError(`${label} must be a canonical executable file`);
  }
  return {
    canonical,
    dev: after.dev,
    ino: after.ino,
    mode: after.mode,
    uid: after.uid,
    size: after.size,
    mtimeMs: after.mtimeMs,
    ctimeMs: after.ctimeMs,
  };
}

function revalidateExecutableIdentity(identity, label, runtime) {
  const current = captureCanonicalExecutable(identity.canonical, label, runtime);
  if (!sameExecutableIdentity(identity, current)) {
    throw sandboxError(`${label} identity changed`);
  }
  return current;
}

function captureNetworkResolutionFile(input, runtime) {
  let suppliedBefore;
  let suppliedAfter;
  let targetBefore;
  let targetAfter;
  let opened;
  let canonical;
  let descriptor;
  try {
    suppliedBefore = runtime.lstatSync(input);
    canonical = runtime.realpathSync.native(input);
    targetBefore = runtime.lstatSync(canonical);
    descriptor = runtime.openSync(
      canonical,
      runtime.constants.O_RDONLY | (runtime.constants.O_NOFOLLOW || 0),
    );
    opened = runtime.fstatSync(descriptor);
    suppliedAfter = runtime.lstatSync(input);
    targetAfter = runtime.lstatSync(canonical);
  } catch (_error) {
    throw sandboxError('network resolver configuration is unavailable');
  } finally {
    if (descriptor !== undefined) {
      try { runtime.closeSync(descriptor); }
      catch (_error) {
        throw sandboxError('network resolver configuration is unavailable');
      }
    }
  }
  const suppliedIsSafe = suppliedBefore.isFile() || suppliedBefore.isSymbolicLink();
  if (!suppliedIsSafe
      || (!suppliedAfter.isFile() && !suppliedAfter.isSymbolicLink())
      || !sameExecutableIdentity(suppliedBefore, suppliedAfter)
      || suppliedAfter.uid !== 0
      || (suppliedAfter.isFile() && (suppliedAfter.mode & 0o022) !== 0)
      || !targetBefore.isFile() || targetBefore.isSymbolicLink()
      || !opened.isFile() || opened.isSymbolicLink?.()
      || !targetAfter.isFile() || targetAfter.isSymbolicLink()
      || !sameExecutableIdentity(targetBefore, opened)
      || !sameExecutableIdentity(targetBefore, targetAfter)
      || targetAfter.uid !== 0
      || (targetAfter.mode & 0o022) !== 0
      || !Number.isSafeInteger(targetAfter.size)
      || targetAfter.size <= 0
      || targetAfter.size > MAX_NETWORK_CONFIG_BYTES) {
    throw sandboxError('network resolver configuration is unsafe');
  }
  return {
    requested: input,
    canonical,
    suppliedDev: suppliedAfter.dev,
    suppliedIno: suppliedAfter.ino,
    suppliedMode: suppliedAfter.mode,
    suppliedUid: suppliedAfter.uid,
    suppliedSize: suppliedAfter.size,
    suppliedMtimeMs: suppliedAfter.mtimeMs,
    suppliedCtimeMs: suppliedAfter.ctimeMs,
    targetDev: targetAfter.dev,
    targetIno: targetAfter.ino,
    targetMode: targetAfter.mode,
    targetUid: targetAfter.uid,
    targetSize: targetAfter.size,
    targetMtimeMs: targetAfter.mtimeMs,
    targetCtimeMs: targetAfter.ctimeMs,
  };
}

function revalidateNetworkResolutionFile(identity, runtime) {
  const current = captureNetworkResolutionFile(identity.requested, runtime);
  if (JSON.stringify(current) !== JSON.stringify(identity)) {
    throw sandboxError('network resolver configuration identity changed');
  }
}

function readExecutableHeader(identity, label, runtime) {
  const noFollow = runtime?.constants?.O_NOFOLLOW;
  const readOnly = runtime?.constants?.O_RDONLY;
  if (!Number.isInteger(noFollow) || !Number.isInteger(readOnly)
      || typeof runtime.openSync !== 'function'
      || typeof runtime.readSync !== 'function'
      || typeof runtime.fstatSync !== 'function'
      || typeof runtime.closeSync !== 'function') {
    throw sandboxError('executable inspection runtime is incomplete');
  }
  let descriptor;
  const buffer = Buffer.alloc(EXECUTABLE_HEADER_BYTES);
  let bytesRead;
  try {
    descriptor = runtime.openSync(identity.canonical, readOnly | noFollow);
    const opened = runtime.fstatSync(descriptor);
    if (!opened.isFile() || opened.isSymbolicLink?.()
        || !sameExecutableIdentity(identity, opened)) {
      throw sandboxError(`${label} identity changed while reading its header`);
    }
    bytesRead = runtime.readSync(
      descriptor,
      buffer,
      0,
      buffer.length,
      0,
    );
  } catch (error) {
    if (error instanceof UpgradeLinuxSandboxError) throw error;
    throw sandboxError(`${label} header cannot be inspected`);
  } finally {
    if (descriptor !== undefined) {
      try { runtime.closeSync(descriptor); }
      catch (_error) { throw sandboxError(`${label} header cannot be inspected`); }
    }
  }
  revalidateExecutableIdentity(identity, label, runtime);
  const header = buffer.subarray(0, bytesRead);
  if (header.length >= 4
      && header[0] === 0x7f
      && header[1] === 0x45
      && header[2] === 0x4c
      && header[3] === 0x46) {
    return { kind: 'elf', line: null };
  }
  if (header.length >= 2 && header[0] === 0x23 && header[1] === 0x21) {
    const newline = header.indexOf(0x0a);
    if (newline < 0) throw sandboxError(`${label} shebang exceeds its bounded header`);
    const line = header.subarray(2, newline).toString('utf8').trim();
    if (!line || /[\0\r]/.test(line)) throw sandboxError(`${label} shebang is invalid`);
    return { kind: 'shebang', line };
  }
  throw sandboxError(`${label} format is unsupported`);
}

function inside(parent, child) {
  const relative = path.relative(parent, child);
  return relative === '' || (relative !== '..' && !relative.startsWith(`..${path.sep}`)
    && !path.isAbsolute(relative));
}

function requireExecutableRoot(identity, label) {
  if (!EXECUTABLE_ROOTS.some((root) => inside(root, identity.canonical))) {
    throw sandboxError(`${label} is outside the read-only executable roots`);
  }
}

function resolvePathExecutable(name, environment, runtime) {
  if (!/^[A-Za-z0-9._-]+$/.test(name)
      || typeof environment.PATH !== 'string'
      || !environment.PATH) {
    throw sandboxError('command runtime cannot be resolved');
  }
  for (const directory of environment.PATH.split(':')) {
    if (!directory || !path.isAbsolute(directory) || /[\0\r\n]/.test(directory)) {
      throw sandboxError('command runtime PATH is unsafe');
    }
    const candidate = path.join(directory, name);
    try {
      runtime.lstatSync(candidate);
    } catch (error) {
      if (error?.code === 'ENOENT') continue;
      throw sandboxError('command runtime cannot be inspected');
    }
    return captureCanonicalExecutable(candidate, 'command runtime', runtime);
  }
  throw sandboxError('command runtime cannot be resolved');
}

// Keep runtime discovery deliberately narrower than a shell: an evaluator may
// launch one native ELF command, one direct native shebang interpreter, or the
// exact `#!/usr/bin/env NAME` form resolved through the child PATH. Flags,
// interpreter chains, relative paths, and shell parsing fail closed. This is
// also the sole authority for deciding whether the read-only /opt mount exists.
function resolveCommandRuntime(command, environment, runtime) {
  const header = readExecutableHeader(command, 'command', runtime);
  if (header.kind === 'elf') return null;
  const tokens = header.line.split(/[ \t]+/);
  let runtimeExecutable;
  if (tokens[0] === '/usr/bin/env') {
    const envExecutable = captureCanonicalExecutable(
      tokens[0],
      'command env interpreter',
      runtime,
    );
    requireExecutableRoot(envExecutable, 'command env interpreter');
    if (tokens.length !== 2) {
      throw sandboxError('command env shebang is unsupported; use one exact runtime name');
    }
    runtimeExecutable = resolvePathExecutable(tokens[1], environment, runtime);
  } else {
    if (!path.isAbsolute(tokens[0]) || tokens.length !== 1) {
      throw sandboxError('command shebang is unsupported');
    }
    runtimeExecutable = captureCanonicalExecutable(
      tokens[0],
      'command interpreter',
      runtime,
    );
  }
  requireExecutableRoot(runtimeExecutable, 'command runtime');
  const runtimeHeader = readExecutableHeader(
    runtimeExecutable,
    'command runtime',
    runtime,
  );
  if (runtimeHeader.kind !== 'elf') {
    throw sandboxError('command runtime must be a native executable');
  }
  return runtimeExecutable;
}

function requireBubblewrap({
  platform = process.platform,
  runtime = fs,
  executable = BWRAP,
} = {}) {
  if (platform !== 'linux') {
    throw sandboxError('candidate containment is supported only on Linux; no child was started');
  }
  if (executable !== BWRAP) throw sandboxError('bubblewrap path is not evaluator-owned');
  let stat;
  let canonical;
  try {
    stat = runtime.lstatSync(executable);
    canonical = runtime.realpathSync.native(executable);
  } catch (_error) {
    throw sandboxError('bubblewrap is unavailable');
  }
  if (!stat.isFile() || stat.isSymbolicLink() || canonical !== executable
      || (stat.mode & 0o111) === 0 || (stat.uid !== undefined && stat.uid !== 0)) {
    throw sandboxError('bubblewrap identity is unsafe');
  }
  return executable;
}

function safeEnvironment(environment, allowedCredential = null) {
  if (!environment || typeof environment !== 'object' || Array.isArray(environment)) {
    throw sandboxError('child environment is invalid');
  }
  const result = {};
  for (const [name, value] of Object.entries(environment)) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)
        || typeof value !== 'string' || /[\0\r\n]/.test(value)) {
      throw sandboxError('child environment entry is invalid');
    }
    if (CLAUDE_CREDENTIAL_NAMES.includes(name) && name !== allowedCredential) {
      throw sandboxError('unexpected Claude credential would cross the sandbox boundary');
    }
    result[name] = value;
  }
  if (allowedCredential !== null
      && (!CLAUDE_CREDENTIAL_NAMES.includes(allowedCredential)
        || typeof result[allowedCredential] !== 'string'
        || !result[allowedCredential])) {
    throw sandboxError('the exact allowed Claude credential is missing');
  }
  return result;
}

function encodeArgumentPayload(args) {
  if (!Array.isArray(args) || args.length === 0
      || args.some((entry) => typeof entry !== 'string' || /[\0]/.test(entry))) {
    throw sandboxError('argument payload is invalid');
  }
  const payload = Buffer.from(`${args.join('\0')}\0`, 'utf8');
  if (payload.length === 0 || payload.length > MAX_ARGUMENT_PAYLOAD_BYTES) {
    throw sandboxError('argument payload exceeds its bounded surface');
  }
  return payload;
}

function buildBubblewrapInvocation({
  command,
  args,
  cwd,
  disposableRoot,
  writableRoots,
  environment,
  allowedCredential = null,
  environmentArgumentFd = null,
  shareNetwork = true,
  platform = process.platform,
  runtime = fs,
} = {}) {
  const executable = requireBubblewrap({ platform, runtime });
  if (typeof command !== 'string' || !path.isAbsolute(command) || /[\0\r\n]/.test(command)
      || !Array.isArray(args) || args.some((entry) => typeof entry !== 'string' || /[\0]/.test(entry))
      || typeof disposableRoot !== 'string'
      || !Array.isArray(writableRoots) || writableRoots.length === 0
      || (environmentArgumentFd !== null && environmentArgumentFd !== 3)
      || typeof shareNetwork !== 'boolean') {
    throw sandboxError('invocation contract is invalid');
  }
  const disposableIdentity = captureCanonicalDirectory(
    disposableRoot,
    'disposable root',
    runtime,
  );
  requireOwnedDirectory(disposableIdentity, 'disposable root', runtime);
  const cwdIdentity = captureCanonicalDirectory(cwd, 'working directory', runtime);
  requireOwnedDirectory(cwdIdentity, 'working directory', runtime);
  const writableIdentities = [];
  const writableByCanonical = new Set();
  for (const entry of writableRoots) {
    const identity = captureCanonicalDirectory(entry, 'writable root', runtime);
    if (!inside(disposableIdentity.canonical, identity.canonical)) {
      throw sandboxError('writable root is outside the evaluator-owned disposable root');
    }
    requireOwnedDirectory(identity, 'writable root', runtime);
    if (!writableByCanonical.has(identity.canonical)) {
      writableByCanonical.add(identity.canonical);
      writableIdentities.push(identity);
    }
  }
  if (!inside(disposableIdentity.canonical, cwdIdentity.canonical)
      || !writableIdentities.some((identity) => inside(
        identity.canonical,
        cwdIdentity.canonical,
      ))) {
    throw sandboxError('working directory is outside the writable sandbox roots');
  }
  const commandIdentity = captureCanonicalExecutable(command, 'command', runtime);
  requireExecutableRoot(commandIdentity, 'command');
  const childEnvironment = safeEnvironment(environment, allowedCredential);
  const commandRuntime = resolveCommandRuntime(
    commandIdentity,
    childEnvironment,
    runtime,
  );
  const requiresOpt = inside(OPT_ROOT, commandIdentity.canonical)
    || (commandRuntime !== null && inside(OPT_ROOT, commandRuntime.canonical));
  const sandboxArgs = [
    '--unshare-user',
    '--unshare-pid',
    '--unshare-ipc',
    '--unshare-uts',
    '--unshare-cgroup',
    '--die-with-parent',
    '--new-session',
  ];
  if (!shareNetwork) sandboxArgs.push('--unshare-net');
  sandboxArgs.push(
    '--proc', '/proc',
    '--dev', '/dev',
    '--tmpfs', '/tmp',
    '--dir', '/etc',
  );
  const systemRoots = requiresOpt
    ? [...BASE_SYSTEM_ROOTS, OPT_ROOT]
    : BASE_SYSTEM_ROOTS;
  for (const root of systemRoots) {
    try {
      const stat = runtime.lstatSync(root);
      if (stat.isDirectory() || stat.isSymbolicLink()) {
        sandboxArgs.push('--ro-bind', root, root);
      }
    } catch (error) {
      if (error?.code !== 'ENOENT' || root === OPT_ROOT) {
        throw sandboxError('system runtime root is unsafe');
      }
    }
  }
  const networkResolutionIdentities = [];
  if (shareNetwork) {
    for (const file of NETWORK_RESOLUTION_FILES) {
      const identity = captureNetworkResolutionFile(file, runtime);
      networkResolutionIdentities.push(identity);
      sandboxArgs.push('--ro-bind', identity.canonical, file);
    }
  }
  for (const identity of writableIdentities) {
    sandboxArgs.push('--bind', identity.canonical, identity.canonical);
  }
  revalidateDirectoryIdentity(
    disposableIdentity,
    'disposable root',
    runtime,
    true,
  );
  revalidateDirectoryIdentity(cwdIdentity, 'working directory', runtime, true);
  for (const identity of writableIdentities) {
    revalidateDirectoryIdentity(identity, 'writable root', runtime, true);
  }
  revalidateExecutableIdentity(commandIdentity, 'command', runtime);
  if (commandRuntime !== null) {
    revalidateExecutableIdentity(commandRuntime, 'command runtime', runtime);
  }
  for (const identity of networkResolutionIdentities) {
    revalidateNetworkResolutionFile(identity, runtime);
  }
  sandboxArgs.push('--chdir', cwdIdentity.canonical);
  const environmentArgs = ['--clearenv'];
  for (const name of Object.keys(childEnvironment).sort()) {
    environmentArgs.push('--setenv', name, childEnvironment[name]);
  }
  let argumentInput = null;
  if (environmentArgumentFd === null) {
    sandboxArgs.push(...environmentArgs);
  } else {
    argumentInput = {
      fd: environmentArgumentFd,
      payload: encodeArgumentPayload(environmentArgs),
    };
    sandboxArgs.push('--args', String(environmentArgumentFd));
  }
  sandboxArgs.push('--', command, ...args);
  return {
    command: executable,
    args: sandboxArgs,
    env: credentialFreeEnvironment(process.env),
    ...(argumentInput === null ? {} : { argumentInput }),
    containment: shareNetwork
      ? 'linux-bwrap-pid-mount-v1'
      : 'linux-bwrap-pid-net-mount-v1',
  };
}

module.exports = {
  BWRAP,
  UpgradeLinuxSandboxError,
  buildBubblewrapInvocation,
  requireBubblewrap,
};
