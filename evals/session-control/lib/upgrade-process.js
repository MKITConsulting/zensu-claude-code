#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const {
  CLAUDE_CREDENTIAL_NAMES,
} = require('./upgrade-environment.js');

class UpgradeProcessError extends Error {}

const TEST_LAUNCH_LEDGER_FILE = 'ZENSU_UPGRADE_TEST_LAUNCH_LEDGER_FILE';
const TEST_MODE = 'ZENSU_UPGRADE_TEST_MODE';
const MAX_ARGUMENT_INPUT_BYTES = 1024 * 1024;
let launchLedgerHookForTest = null;

const DEFAULT_PROCESS_RUNTIME = Object.freeze({
  platform: process.platform,
  kill(pid, signal) {
    return process.kill(pid, signal);
  },
  spawn,
  spawnSync,
});

function processError(message) {
  return new UpgradeProcessError(`upgrade process: ${message}`);
}

function validLabel(label) {
  return typeof label === 'string' && label && !/[\0\r\n]/.test(label);
}

function effectiveEnvironment(options) {
  return options.env === undefined ? process.env : options.env;
}

function credentialNamesPresent(environment) {
  if (!environment || typeof environment !== 'object') return [];
  return CLAUDE_CREDENTIAL_NAMES.filter(
    (name) => typeof environment[name] === 'string' && environment[name] !== '',
  );
}

function childOptionsWithoutLedgerTarget(options) {
  const environment = effectiveEnvironment(options);
  if (!environment || typeof environment !== 'object'
      || !Object.prototype.hasOwnProperty.call(environment, TEST_LAUNCH_LEDGER_FILE)) {
    return { ...options };
  }
  const childEnvironment = { ...environment };
  delete childEnvironment[TEST_LAUNCH_LEDGER_FILE];
  return { ...options, env: childEnvironment };
}

function emitLaunchLedgerForTest(label, mode, spawnAttempted, options) {
  if (process.env[TEST_MODE] !== '1') return;
  const record = Object.freeze({
    label,
    mode,
    spawn_attempted: spawnAttempted,
    credential_names_present: Object.freeze(
      credentialNamesPresent(effectiveEnvironment(options)),
    ),
  });
  if (launchLedgerHookForTest) {
    try {
      launchLedgerHookForTest(record);
    } catch (_error) {
      throw processError('test launch ledger hook failed');
    }
  }
  const ledgerFile = process.env[TEST_LAUNCH_LEDGER_FILE] || '';
  if (!ledgerFile) return;
  if (!pathIsAbsoluteSafe(ledgerFile)) {
    throw processError('test launch ledger target is invalid');
  }
  try {
    fs.appendFileSync(ledgerFile, `${JSON.stringify(record)}\n`, {
      encoding: 'utf8',
      flag: 'a',
      mode: 0o600,
    });
  } catch (_error) {
    throw processError('test launch ledger could not record attempt');
  }
}

function pathIsAbsoluteSafe(value) {
  return typeof value === 'string'
    && path.isAbsolute(value)
    && !/[\0\r\n]/.test(value);
}

function setLaunchLedgerHookForTest(hook) {
  if (process.env[TEST_MODE] !== '1') {
    throw processError('test launch ledger hook requires test mode');
  }
  if (hook !== null && typeof hook !== 'function') {
    throw processError('test launch ledger hook is invalid');
  }
  launchLedgerHookForTest = hook;
}

function terminateTimedOutSyncGroup(result, runtime) {
  if (runtime.platform === 'win32'
      || !Number.isSafeInteger(result?.pid) || result.pid <= 0) return;
  try {
    runtime.kill(-result.pid, 'SIGKILL');
  } catch (error) {
    if (error?.code !== 'ESRCH') {
      throw processError('timed-out synchronous helper tree could not be terminated');
    }
  }
}

function runSyncBounded(
  command,
  args,
  options = {},
  {
    label,
    timeoutMs,
    maxBuffer = 16 * 1024 * 1024,
    trustedEvaluatorCommand = false,
    runtime = DEFAULT_PROCESS_RUNTIME,
  } = {},
) {
  if (typeof command !== 'string' || !command || !Array.isArray(args)
      || !validLabel(label)
      || !Number.isSafeInteger(timeoutMs) || timeoutMs <= 0
      || !Number.isSafeInteger(maxBuffer) || maxBuffer <= 0
      || !runtime || typeof runtime.platform !== 'string'
      || typeof runtime.spawnSync !== 'function'
      || typeof runtime.kill !== 'function') {
    throw processError('synchronous process policy is invalid');
  }
  if (trustedEvaluatorCommand !== true) {
    throw processError(
      'synchronous execution is restricted to trusted evaluator-owned helpers',
    );
  }
  const childOptions = childOptionsWithoutLedgerTarget(options);
  emitLaunchLedgerForTest(label, 'sync_bounded', true, options);
  const result = runtime.spawnSync(command, args, {
    ...childOptions,
    detached: runtime.platform === 'win32' ? false : true,
    windowsHide: true,
    timeout: timeoutMs,
    killSignal: 'SIGKILL',
    maxBuffer,
  });
  if (result.error?.code === 'ETIMEDOUT') {
    terminateTimedOutSyncGroup(result, runtime);
    throw processError(`${label} exceeded its time bound`);
  }
  if (result.error) throw processError(`${label} could not start or complete`);
  if (result.signal) throw processError(`${label} ended by signal`);
  return result;
}

function requireSupportedTreeHost(runtime) {
  if (runtime.platform === 'win32') {
    throw processError(
      'Windows process-tree containment is unsupported; no child process was started',
    );
  }
}

function spawnProcessTree(
  command,
  args,
  options = {},
  { label } = {},
  runtime = DEFAULT_PROCESS_RUNTIME,
) {
  if (typeof command !== 'string' || !command || !Array.isArray(args)
      || !validLabel(label)
      || !runtime || typeof runtime.platform !== 'string'
      || typeof runtime.spawn !== 'function') {
    throw processError('process-tree invocation is invalid');
  }
  if (runtime.platform === 'win32') {
    emitLaunchLedgerForTest(label, 'process_tree', false, options);
    requireSupportedTreeHost(runtime);
  }
  const childOptions = childOptionsWithoutLedgerTarget(options);
  emitLaunchLedgerForTest(label, 'process_tree', true, options);
  const child = runtime.spawn(command, args, {
    ...childOptions,
    detached: true,
    windowsHide: true,
  });
  const tree = {
    child,
    closed: false,
    closeResult: null,
    exit: null,
  };
  tree.exit = new Promise((resolve) => {
    child.once('close', (status, signal) => {
      tree.closed = true;
      tree.closeResult = { status, signal };
      resolve(tree.closeResult);
    });
    child.once('error', () => {
      // StreamSession owns the redacted spawn-error detail. Keeping a listener
      // here prevents an unhandled EventEmitter error before `close` arrives.
    });
  });
  return tree;
}

async function runProcessTreeBounded(
  command,
  args,
  options = {},
  {
    label,
    timeoutMs,
    maxBuffer = 16 * 1024 * 1024,
    graceMs = 1000,
    forceMs = 5000,
    trustedEvaluatorCommand = false,
    argumentInput = null,
  } = {},
  runtime = DEFAULT_PROCESS_RUNTIME,
) {
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0
      || !Number.isSafeInteger(maxBuffer) || maxBuffer <= 0
      || !Number.isSafeInteger(graceMs) || graceMs < 0
      || !Number.isSafeInteger(forceMs) || forceMs <= 0
      || (argumentInput !== null
        && (argumentInput?.fd !== 3
          || !Buffer.isBuffer(argumentInput?.payload)
          || argumentInput.payload.length === 0
          || argumentInput.payload.length > MAX_ARGUMENT_INPUT_BYTES))) {
    throw processError('bounded process-tree policy is invalid');
  }
  if (trustedEvaluatorCommand !== true) {
    throw processError(
      'bounded process-tree execution is restricted to trusted evaluator-owned helpers',
    );
  }
  const encoding = options.encoding;
  if (encoding !== undefined && encoding !== 'utf8' && encoding !== 'utf-8') {
    throw processError('bounded process-tree encoding is unsupported');
  }
  const boundedArgumentInput = argumentInput === null
    ? null
    : {
      fd: argumentInput.fd,
      payload: Buffer.from(argumentInput.payload),
    };
  const spawnOptions = {
    ...options,
    stdio: boundedArgumentInput === null
      ? ['ignore', 'pipe', 'pipe']
      : ['ignore', 'pipe', 'pipe', 'pipe'],
  };
  delete spawnOptions.encoding;
  const tree = spawnProcessTree(
    command,
    args,
    spawnOptions,
    { label },
    runtime,
  );
  let stdoutBytes = 0;
  let stderrBytes = 0;
  const stdout = [];
  const stderr = [];
  let outputFailure = null;
  let argumentFailure = null;
  let argumentSettled = boundedArgumentInput === null;
  let settleArgument;
  const argumentDelivery = boundedArgumentInput === null
    ? Promise.resolve()
    : new Promise((resolve) => {
      settleArgument = (error = null) => {
        if (argumentSettled) return;
        argumentSettled = true;
        if (error) {
          argumentFailure = processError(`${label} argument payload delivery failed`);
        }
        resolve();
      };
    });
  const capture = (chunks, key) => (chunk) => {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    if (key === 'stdout') stdoutBytes += buffer.length;
    else stderrBytes += buffer.length;
    if (stdoutBytes + stderrBytes > maxBuffer) {
      outputFailure = processError(`${label} exceeded its output bound`);
      return;
    }
    chunks.push(buffer);
  };
  tree.child.stdout.on('data', capture(stdout, 'stdout'));
  tree.child.stderr.on('data', capture(stderr, 'stderr'));
  if (boundedArgumentInput !== null) {
    const input = tree.child.stdio?.[boundedArgumentInput.fd];
    if (!input || typeof input.end !== 'function' || typeof input.once !== 'function') {
      settleArgument(new Error('missing argument input'));
    } else {
      input.once('error', () => settleArgument(new Error('argument input error')));
      input.once('finish', () => settleArgument());
      input.once('close', () => {
        if (!argumentSettled) settleArgument(new Error('argument input closed'));
      });
      tree.exit.then(() => {
        if (!argumentSettled) settleArgument(new Error('process closed before argument input'));
      });
      try {
        input.end(boundedArgumentInput.payload);
      } catch (_error) {
        settleArgument(new Error('argument input write failed'));
      }
    }
  }

  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; }, timeoutMs);
  timer.unref?.();
  try {
    while ((!tree.closed || !argumentSettled)
        && !timedOut && !outputFailure && !argumentFailure) {
      const waits = [
        tree.exit,
        new Promise((resolve) => setTimeout(resolve, 25)),
      ];
      if (!argumentSettled) waits.push(argumentDelivery);
      await Promise.race(waits);
    }
    if (timedOut || outputFailure || argumentFailure) {
      await terminateProcessTree(tree, { graceMs, forceMs, runtime });
      if (outputFailure) throw outputFailure;
      if (argumentFailure) throw argumentFailure;
      throw processError(`${label} exceeded its time bound`);
    }
    await argumentDelivery;
    await tree.exit;
    if (processTreeAlive(tree, runtime)) {
      await terminateProcessTree(tree, { graceMs, forceMs, runtime });
    }
  } finally {
    clearTimeout(timer);
    boundedArgumentInput?.payload.fill(0);
  }
  const stdoutBuffer = Buffer.concat(stdout);
  const stderrBuffer = Buffer.concat(stderr);
  return {
    status: tree.closeResult.status,
    signal: tree.closeResult.signal,
    stdout: encoding ? stdoutBuffer.toString(encoding) : stdoutBuffer,
    stderr: encoding ? stderrBuffer.toString(encoding) : stderrBuffer,
  };
}

function posixGroupAlive(pid, runtime) {
  try {
    runtime.kill(-pid, 0);
    return true;
  } catch (error) {
    if (error?.code === 'ESRCH') return false;
    if (error?.code === 'EPERM') return true;
    throw error;
  }
}

function processTreeAlive(tree, runtime = DEFAULT_PROCESS_RUNTIME) {
  if (!tree?.child || !Number.isSafeInteger(tree.child.pid) || tree.child.pid <= 0) return false;
  requireSupportedTreeHost(runtime);
  return posixGroupAlive(tree.child.pid, runtime);
}

function signalProcessTree(tree, signal, runtime = DEFAULT_PROCESS_RUNTIME) {
  if (!processTreeAlive(tree, runtime)) return;
  try { runtime.kill(-tree.child.pid, signal); }
  catch (error) {
    if (error?.code !== 'ESRCH') throw processError('POSIX process-group termination failed');
  }
}

async function waitUntil(predicate, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!predicate()) return true;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  return !predicate();
}

async function terminateProcessTree(
  tree,
  {
    graceMs = 5000,
    forceMs = 5000,
    runtime = DEFAULT_PROCESS_RUNTIME,
  } = {},
) {
  if (!tree?.child || typeof tree.exit?.then !== 'function'
      || !Number.isSafeInteger(graceMs) || graceMs < 0
      || !Number.isSafeInteger(forceMs) || forceMs <= 0
      || !runtime || typeof runtime !== 'object'
      || typeof runtime.platform !== 'string'
      || typeof runtime.kill !== 'function') {
    throw processError('process-tree termination policy is invalid');
  }
  requireSupportedTreeHost(runtime);
  if (processTreeAlive(tree, runtime)) signalProcessTree(tree, 'SIGTERM', runtime);
  if (!await waitUntil(() => processTreeAlive(tree, runtime), graceMs)) {
    signalProcessTree(tree, 'SIGKILL', runtime);
    if (!await waitUntil(() => processTreeAlive(tree, runtime), forceMs)) {
      throw processError('process tree survived forced termination');
    }
  }
  if (!tree.closed && !await waitUntil(() => !tree.closed, forceMs)) {
    throw processError('direct process did not emit close after tree termination');
  }
  await tree.exit;
  return tree.closeResult;
}

module.exports = {
  UpgradeProcessError,
  processTreeAlive,
  runProcessTreeBounded,
  runSyncBounded,
  setLaunchLedgerHookForTest,
  signalProcessTree,
  spawnProcessTree,
  terminateProcessTree,
};
