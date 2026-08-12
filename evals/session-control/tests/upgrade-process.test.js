#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { EventEmitter } = require('node:events');
const { PassThrough } = require('node:stream');
const {
  processTreeAlive,
  runProcessTreeBounded,
  runSyncBounded,
  setLaunchLedgerHookForTest,
  signalProcessTree,
  spawnProcessTree,
  terminateProcessTree,
} = require('../lib/upgrade-process.js');

function alive(pid) {
  // A non-positive pid is never a process. process.kill(0, sig) signals the
  // CALLER'S OWN process group and process.kill(-1, sig) every process the user
  // may signal, so either would report "alive" forever and no assertion here
  // could ever fail. Number('') is 0, which is exactly what reading a pid file
  // in the window between its creation and its first write produces — so this
  // guard is what turns that race into a loud failure instead of a silent one.
  if (!Number.isSafeInteger(pid) || pid <= 0) {
    throw new Error(`refusing to probe a non-process pid: ${JSON.stringify(pid)}`);
  }
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error?.code === 'ESRCH') return false;
    throw error;
  }
}

function processError(code) {
  return Object.assign(new Error(code), { code });
}

function runtime(platform, kill, spawnSync = () => ({ status: 0 }), spawn = () => {}) {
  return { platform, kill, spawnSync, spawn };
}

// Wait for a USABLE pid, not for the inode. fs.existsSync goes true the instant
// writeFileSync creates the file — O_CREAT|O_TRUNC happens before the write — so
// an existence check hands the reader an empty file, Number('') is 0, and the
// fixture then probes this process's own group instead of the grandchild.
async function waitForPid(file, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  let last = '';
  while (Date.now() < deadline) {
    try {
      last = fs.readFileSync(file, 'utf8').trim();
      const pid = Number(last);
      if (last !== '' && Number.isSafeInteger(pid) && pid > 0) return pid;
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(
    `timed out waiting for a usable pid in the process-tree fixture (last read: ${JSON.stringify(last)})`,
  );
}

test('bounds synchronous probes without hiding ordinary nonzero status', () => {
  const nonzero = runSyncBounded(
    process.execPath,
    ['-e', 'process.exit(7)'],
    { encoding: 'utf8' },
    {
      label: 'nonzero fixture',
      timeoutMs: 1000,
      trustedEvaluatorCommand: true,
    },
  );
  assert.equal(nonzero.status, 7);
  assert.throws(() => runSyncBounded(
    process.execPath,
    ['-e', 'setTimeout(() => {}, 5000)'],
    { encoding: 'utf8' },
    {
      label: 'sleeping fixture',
      timeoutMs: 100,
      trustedEvaluatorCommand: true,
    },
  ), /sleeping fixture exceeded its time bound/);
});

test('refuses untrusted synchronous execution before attempting a spawn', () => {
  let spawnCalls = 0;
  const injected = runtime(
    'linux',
    () => {},
    () => {
      spawnCalls += 1;
      return { status: 0 };
    },
  );
  assert.throws(() => runSyncBounded(
    'candidate-controlled-command',
    [],
    {},
    {
      label: 'untrusted fixture',
      timeoutMs: 1000,
      runtime: injected,
    },
  ), /restricted to trusted evaluator-owned helpers/);
  assert.equal(spawnCalls, 0);
});

test('kills the complete POSIX group after a trusted synchronous helper timeout', () => {
  const signals = [];
  const timedOut = runtime(
    'linux',
    (pid, signal) => signals.push({ pid, signal }),
    () => ({
      pid: 424242,
      status: null,
      signal: 'SIGKILL',
      error: processError('ETIMEDOUT'),
    }),
  );
  assert.throws(() => runSyncBounded(
    'trusted-helper',
    [],
    {},
    {
      label: 'trusted timeout fixture',
      timeoutMs: 1000,
      trustedEvaluatorCommand: true,
      runtime: timedOut,
    },
  ), /trusted timeout fixture exceeded its time bound/);
  assert.deepEqual(signals, [{ pid: -424242, signal: 'SIGKILL' }]);
});

test('rejects a trusted synchronous helper reported as signalled on every host', () => {
  const signalled = runtime(
    'win32',
    () => {},
    () => ({ status: null, signal: 'SIGTERM' }),
  );
  assert.throws(() => runSyncBounded(
    'trusted-helper',
    [],
    {},
    {
      label: 'signalled fixture',
      timeoutMs: 1000,
      trustedEvaluatorCommand: true,
      runtime: signalled,
    },
  ), /signalled fixture ended by signal/);
});

test('propagates a real signal through the default POSIX synchronous runtime', {
  skip: process.platform === 'win32',
}, () => {
  assert.throws(() => runSyncBounded(
    process.execPath,
    ['-e', "process.kill(process.pid, 'SIGTERM')"],
    {},
    {
      label: 'POSIX signalled fixture',
      timeoutMs: 1000,
      trustedEvaluatorCommand: true,
    },
  ), /POSIX signalled fixture ended by signal/);
});

test('rejects invalid synchronous and process-tree invocations', async () => {
  assert.throws(() => runSyncBounded(
    '',
    [],
    {},
    {
      label: 'invalid fixture',
      timeoutMs: 1000,
      trustedEvaluatorCommand: true,
    },
  ), /synchronous process policy is invalid/);
  assert.throws(() => runSyncBounded(
    '/definitely/missing/zensu-process-fixture',
    [],
    {},
    {
      label: 'missing fixture',
      timeoutMs: 1000,
      trustedEvaluatorCommand: true,
    },
  ), /missing fixture could not start or complete/);
  assert.throws(
    () => spawnProcessTree('', [], {}, { label: 'invalid fixture' }),
    /process-tree invocation is invalid/,
  );
  assert.throws(
    () => spawnProcessTree(
      'fixture',
      [],
      {},
      { label: 'invalid runtime fixture' },
      { platform: 'linux' },
    ),
    /process-tree invocation is invalid/,
  );
  await assert.rejects(
    terminateProcessTree({}),
    /process-tree termination policy is invalid/,
  );
});

test('tracks a spawn error without raising an unhandled EventEmitter error', {
  skip: process.platform === 'win32',
}, async () => {
  const tree = spawnProcessTree('/definitely/missing/zensu-process-tree-fixture', [], {
    stdio: 'ignore',
  }, { label: 'missing tree fixture' });
  const result = await tree.exit;
  assert.equal(tree.closed, true);
  assert.equal(result.status, -2);
});

test('tracks an injected detached POSIX process lifecycle on every CI host', async () => {
  const child = new EventEmitter();
  child.pid = 424242;
  let invocation;
  const injected = {
    platform: 'linux',
    spawn(command, args, options) {
      invocation = { command, args, options };
      return child;
    },
  };
  const tree = spawnProcessTree('fixture-command', ['one', 'two'], {
    cwd: '/fixture',
    stdio: 'ignore',
  }, { label: 'injected tree fixture' }, injected);
  assert.deepEqual(invocation, {
    command: 'fixture-command',
    args: ['one', 'two'],
    options: {
      cwd: '/fixture',
      stdio: 'ignore',
      detached: true,
      windowsHide: true,
    },
  });
  child.emit('error', new Error('expected injected spawn error'));
  child.emit('close', 7, 'SIGTERM');
  assert.deepEqual(await tree.exit, { status: 7, signal: 'SIGTERM' });
  assert.equal(tree.closed, true);
});

test('classifies process-tree liveness errors conservatively', async () => {
  const tree = { child: { pid: 424242 } };
  assert.equal(processTreeAlive(null), false);
  const missing = runtime('darwin', () => { throw processError('ESRCH'); });
  assert.equal(processTreeAlive(tree, missing), false);
  assert.doesNotThrow(() => signalProcessTree(tree, 'SIGTERM', missing));

  const protectedProcess = runtime('darwin', () => { throw processError('EPERM'); });
  assert.equal(processTreeAlive(tree, protectedProcess), true);

  const unexpected = runtime('darwin', () => { throw processError('EACCES'); });
  assert.throws(() => processTreeAlive(tree, unexpected), /EACCES/);
});

test('wraps unexpected POSIX process-group termination failures', async () => {
  let calls = 0;
  const failing = runtime(
    'darwin',
    () => {
      calls += 1;
      if (calls === 1) return;
      throw processError('EACCES');
    },
  );
  assert.throws(
    () => signalProcessTree({ child: { pid: 424242 } }, 'SIGTERM', failing),
    /POSIX process-group termination failed/,
  );

  calls = 0;
  const vanished = runtime(
    'darwin',
    () => {
      calls += 1;
      if (calls === 1) return;
      throw processError('ESRCH');
    },
  );
  assert.doesNotThrow(
    () => signalProcessTree({ child: { pid: 424242 } }, 'SIGTERM', vanished),
  );
});

test('fails closed before spawning any process tree on Windows', async () => {
  let spawnCalls = 0;
  const windows = {
    platform: 'win32',
    kill() {
      throw new Error('Windows liveness must not be inferred from the root PID');
    },
    spawn() {
      spawnCalls += 1;
      throw new Error('must not spawn');
    },
  };
  assert.throws(
    () => spawnProcessTree('credential-bearing-cli', ['probe'], {
      env: { ANTHROPIC_API_KEY: 'opaque-test-value' },
    }, { label: 'Windows credential fixture' }, windows),
    /Windows process-tree containment is unsupported; no child process was started/,
  );
  assert.equal(spawnCalls, 0);
  assert.throws(
    () => processTreeAlive({ child: { pid: 424242 } }, windows),
    /Windows process-tree containment is unsupported/,
  );
  assert.throws(
    () => signalProcessTree({ child: { pid: 424242 } }, 'SIGKILL', windows),
    /Windows process-tree containment is unsupported/,
  );
  await assert.rejects(
    terminateProcessTree({
      child: { pid: 424242 },
      closed: false,
      exit: new Promise(() => {}),
    }, {
      graceMs: 0,
      forceMs: 1,
      runtime: windows,
    }),
    /Windows process-tree containment is unsupported/,
  );
});

test('reports forced-survival and missing-close termination failures', async () => {
  const never = new Promise(() => {});
  await assert.rejects(
    terminateProcessTree({
      child: { pid: 424242 },
      closed: false,
      exit: never,
    }, {
      graceMs: 0,
      forceMs: 1,
      runtime: runtime('darwin', () => {}),
    }),
    /process tree survived forced termination/,
  );

  await assert.rejects(
    terminateProcessTree({
      child: { pid: 424242 },
      closed: false,
      exit: never,
    }, {
      graceMs: 0,
      forceMs: 1,
      runtime: runtime('darwin', () => { throw processError('ESRCH'); }),
    }),
    /direct process did not emit close/,
  );

  const alreadyClosed = {
    child: { pid: 424242 },
    closed: true,
    closeResult: { status: 0, signal: null },
    exit: Promise.resolve({ status: 0, signal: null }),
  };
  assert.deepEqual(
    await terminateProcessTree(alreadyClosed, {
      graceMs: 0,
      forceMs: 1,
      runtime: runtime('darwin', () => { throw processError('ESRCH'); }),
    }),
    { status: 0, signal: null },
  );
});

// Both pins below reproduce, deterministically, a race that was measured at
// roughly 1-in-100 and 1-in-22 of a full run of this file.
test('a pid file that is created before it is written never resolves to a probe of our own group', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-pid-window-'));
  const pidFile = path.join(temporary, 'grandchild.pid');
  try {
    // Exactly the state fs.writeFileSync passes through: created, still empty.
    fs.writeFileSync(pidFile, '');
    await assert.rejects(
      waitForPid(pidFile, 150),
      /timed out waiting for a usable pid/,
      'an empty pid file must time out, never read as pid 0',
    );
    // The guard that makes the same mistake loud everywhere else in this file.
    assert.throws(() => alive(Number('')), /refusing to probe a non-process pid/);
    assert.throws(() => alive(0), /refusing to probe a non-process pid/);
    assert.throws(() => alive(-1), /refusing to probe a non-process pid/);

    setTimeout(() => fs.writeFileSync(pidFile, String(process.pid)), 40);
    assert.equal(await waitForPid(pidFile, 5000), process.pid, 'a late write is still picked up');
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

test('a process group whose last member is a zombie is terminated, not reported as a failure', {
  skip: process.platform === 'win32',
}, async () => {
  // macOS/BSD answer kill(-pgid, sig) with EPERM once the only member left is
  // defunct. posixGroupAlive reads that as "not yet confirmed gone" and waits;
  // signalProcessTree must not read the same code as a termination fault.
  const tree = spawnProcessTree(process.execPath, ['-e', 'setInterval(()=>{},1000)'], {
    stdio: ['ignore', 'ignore', 'ignore'],
  }, { label: 'zombie group fixture' });
  const denied = { platform: process.platform, spawnSync: () => ({ status: 0 }), spawn: () => {},
    kill: (pid, signal) => {
      if (pid < 0) throw processError('EPERM');
      return process.kill(pid, signal);
    } };
  try {
    assert.doesNotThrow(
      () => signalProcessTree(tree, 'SIGTERM', denied),
      'EPERM on our own group id means nothing is left to signal',
    );
  } finally {
    await terminateProcessTree(tree, { graceMs: 100, forceMs: 5000 });
  }
});

test('terminates the complete spawned POSIX process group', {
  skip: process.platform === 'win32',
}, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-process-tree-'));
  const pidFile = path.join(temporary, 'grandchild.pid');
  const childScript = [
    "const fs=require('node:fs');",
    "const {spawn}=require('node:child_process');",
    "const child=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{stdio:'ignore'});",
    // Publish the pid atomically: rename within a directory is atomic on POSIX,
    // so the reader can never observe the file half-written. waitForPid would
    // survive a torn write on its own; writing it this way means the window
    // does not exist at all.
    "fs.writeFileSync(process.argv[1]+'.tmp',String(child.pid));",
    "fs.renameSync(process.argv[1]+'.tmp',process.argv[1]);",
    "setInterval(()=>{},1000);",
  ].join('');
  const tree = spawnProcessTree(process.execPath, ['-e', childScript, pidFile], {
    stdio: ['ignore', 'ignore', 'ignore'],
  }, { label: 'complete POSIX group fixture' });
  try {
    const grandchildPid = await waitForPid(pidFile);
    assert.notEqual(grandchildPid, tree.child.pid, 'the fixture must publish the grandchild, not the child');
    assert.equal(alive(tree.child.pid), true);
    assert.equal(alive(grandchildPid), true);
    await terminateProcessTree(tree, {
      graceMs: 500,
      forceMs: 5000,
    });
    assert.equal(alive(tree.child.pid), false);
    assert.equal(alive(grandchildPid), false);
  } finally {
    try {
      await terminateProcessTree(tree, { graceMs: 100, forceMs: 1000 });
    } catch (_error) {
      // The assertions above surface a failed cleanup with the original detail.
    }
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

test('records redacted launch metadata and never forwards the ledger target', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-launch-ledger-'));
  const ledger = path.join(temporary, 'launches.jsonl');
  const originalMode = process.env.ZENSU_UPGRADE_TEST_MODE;
  const originalLedger = process.env.ZENSU_UPGRADE_TEST_LAUNCH_LEDGER_FILE;
  const hookRecords = [];
  process.env.ZENSU_UPGRADE_TEST_MODE = '1';
  process.env.ZENSU_UPGRADE_TEST_LAUNCH_LEDGER_FILE = ledger;
  setLaunchLedgerHookForTest((record) => hookRecords.push(record));
  try {
    const result = runSyncBounded(
      process.execPath,
      ['-e', [
        "const present=Object.hasOwn(process.env,'ZENSU_UPGRADE_TEST_LAUNCH_LEDGER_FILE');",
        'process.stdout.write(String(present));',
      ].join('')],
      {
        encoding: 'utf8',
        env: {
          ...process.env,
          ANTHROPIC_API_KEY: 'never-record-this-api-value',
          CLAUDE_CODE_OAUTH_TOKEN: 'never-record-this-oauth-value',
        },
      },
      {
        label: 'credential metadata fixture',
        timeoutMs: 1000,
        trustedEvaluatorCommand: true,
      },
    );
    assert.equal(result.stdout, 'false');
    const lines = fs.readFileSync(ledger, 'utf8').trim().split('\n').map(JSON.parse);
    assert.deepEqual(lines, [{
      label: 'credential metadata fixture',
      mode: 'sync_bounded',
      spawn_attempted: true,
      credential_names_present: ['ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN'],
    }]);
    assert.deepEqual(hookRecords, lines);
    const serialized = fs.readFileSync(ledger, 'utf8');
    assert.doesNotMatch(serialized, /never-record-this-(?:api|oauth)-value/);
  } finally {
    setLaunchLedgerHookForTest(null);
    if (originalMode === undefined) delete process.env.ZENSU_UPGRADE_TEST_MODE;
    else process.env.ZENSU_UPGRADE_TEST_MODE = originalMode;
    if (originalLedger === undefined) {
      delete process.env.ZENSU_UPGRADE_TEST_LAUNCH_LEDGER_FILE;
    } else {
      process.env.ZENSU_UPGRADE_TEST_LAUNCH_LEDGER_FILE = originalLedger;
    }
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

test('records a zero-launch Windows decision before failing closed', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-windows-ledger-'));
  const ledger = path.join(temporary, 'launches.jsonl');
  const originalMode = process.env.ZENSU_UPGRADE_TEST_MODE;
  const originalLedger = process.env.ZENSU_UPGRADE_TEST_LAUNCH_LEDGER_FILE;
  process.env.ZENSU_UPGRADE_TEST_MODE = '1';
  process.env.ZENSU_UPGRADE_TEST_LAUNCH_LEDGER_FILE = ledger;
  let spawnCalls = 0;
  const windows = {
    platform: 'win32',
    kill() {},
    spawn() {
      spawnCalls += 1;
      throw new Error('must not spawn');
    },
  };
  try {
    assert.throws(
      () => spawnProcessTree(
        'credential-bearing-cli',
        ['probe'],
        { env: { ANTHROPIC_API_KEY: 'never-record-this-value' } },
        { label: 'Windows pre-spawn fixture' },
        windows,
      ),
      /Windows process-tree containment is unsupported/,
    );
    assert.equal(spawnCalls, 0);
    const record = JSON.parse(fs.readFileSync(ledger, 'utf8').trim());
    assert.deepEqual(record, {
      label: 'Windows pre-spawn fixture',
      mode: 'process_tree',
      spawn_attempted: false,
      credential_names_present: ['ANTHROPIC_API_KEY'],
    });
    assert.doesNotMatch(fs.readFileSync(ledger, 'utf8'), /never-record-this-value/);
  } finally {
    if (originalMode === undefined) delete process.env.ZENSU_UPGRADE_TEST_MODE;
    else process.env.ZENSU_UPGRADE_TEST_MODE = originalMode;
    if (originalLedger === undefined) {
      delete process.env.ZENSU_UPGRADE_TEST_LAUNCH_LEDGER_FILE;
    } else {
      process.env.ZENSU_UPGRADE_TEST_LAUNCH_LEDGER_FILE = originalLedger;
    }
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

test('fails closed before spawn when launch-ledger instrumentation is unsafe', () => {
  const originalMode = process.env.ZENSU_UPGRADE_TEST_MODE;
  const originalLedger = process.env.ZENSU_UPGRADE_TEST_LAUNCH_LEDGER_FILE;
  let spawnCalls = 0;
  const injected = runtime(
    'linux',
    () => {},
    () => {
      spawnCalls += 1;
      return { status: 0 };
    },
  );
  process.env.ZENSU_UPGRADE_TEST_MODE = '1';
  process.env.ZENSU_UPGRADE_TEST_LAUNCH_LEDGER_FILE = 'relative-ledger.jsonl';
  try {
    assert.throws(() => runSyncBounded(
      'trusted-helper',
      [],
      {},
      {
        label: 'invalid ledger target',
        timeoutMs: 1000,
        trustedEvaluatorCommand: true,
        runtime: injected,
      },
    ), /test launch ledger target is invalid/);
    assert.equal(spawnCalls, 0);

    delete process.env.ZENSU_UPGRADE_TEST_LAUNCH_LEDGER_FILE;
    setLaunchLedgerHookForTest(() => { throw new Error('tampered hook'); });
    assert.throws(() => runSyncBounded(
      'trusted-helper',
      [],
      {},
      {
        label: 'failing ledger hook',
        timeoutMs: 1000,
        trustedEvaluatorCommand: true,
        runtime: injected,
      },
    ), /test launch ledger hook failed/);
    assert.equal(spawnCalls, 0);
  } finally {
    setLaunchLedgerHookForTest(null);
    if (originalMode === undefined) delete process.env.ZENSU_UPGRADE_TEST_MODE;
    else process.env.ZENSU_UPGRADE_TEST_MODE = originalMode;
    if (originalLedger === undefined) {
      delete process.env.ZENSU_UPGRADE_TEST_LAUNCH_LEDGER_FILE;
    } else {
      process.env.ZENSU_UPGRADE_TEST_LAUNCH_LEDGER_FILE = originalLedger;
    }
  }
});

test('does not permit production code to install a test launch-ledger hook', () => {
  const originalMode = process.env.ZENSU_UPGRADE_TEST_MODE;
  delete process.env.ZENSU_UPGRADE_TEST_MODE;
  try {
    assert.throws(
      () => setLaunchLedgerHookForTest(() => {}),
      /test launch ledger hook requires test mode/,
    );
  } finally {
    if (originalMode !== undefined) process.env.ZENSU_UPGRADE_TEST_MODE = originalMode;
  }
});

test('runs trusted evaluator helpers asynchronously inside a bounded process tree', {
  skip: process.platform === 'win32',
}, async () => {
  const result = await runProcessTreeBounded(
    process.execPath,
    ['-e', "process.stdout.write('out');process.stderr.write('err');process.exit(6)"],
    { encoding: 'utf8' },
    {
      label: 'async helper fixture',
      timeoutMs: 1000,
      trustedEvaluatorCommand: true,
    },
  );
  assert.deepEqual(result, {
    status: 6,
    signal: null,
    stdout: 'out',
    stderr: 'err',
  });
  await assert.rejects(
    runProcessTreeBounded(
      process.execPath,
      ['-e', 'setInterval(() => {}, 1000)'],
      { encoding: 'utf8' },
      {
        label: 'async timeout fixture',
        timeoutMs: 50,
        graceMs: 100,
        forceMs: 5000,
        trustedEvaluatorCommand: true,
      },
    ),
    /async timeout fixture exceeded its time bound/,
  );
});

test('exercises the bounded asynchronous tree contract on every CI host', async () => {
  function injectedRuntime({ hang = false } = {}) {
    let alive = true;
    let child;
    return {
      platform: 'linux',
      spawn() {
        child = new EventEmitter();
        child.pid = 424242;
        child.stdout = new PassThrough();
        child.stderr = new PassThrough();
        if (!hang) {
          process.nextTick(() => {
            child.stdout.end('injected-out');
            child.stderr.end('injected-err');
            alive = false;
            child.emit('close', 4, null);
          });
        }
        return child;
      },
      kill(_pid, signal) {
        if (!alive) throw processError('ESRCH');
        if (signal === 0) return;
        alive = false;
        process.nextTick(() => child.emit('close', null, signal));
      },
    };
  }

  assert.deepEqual(
    await runProcessTreeBounded(
      'trusted-injected-helper',
      [],
      { encoding: 'utf8' },
      {
        label: 'injected async helper',
        timeoutMs: 1000,
        trustedEvaluatorCommand: true,
      },
      injectedRuntime(),
    ),
    {
      status: 4,
      signal: null,
      stdout: 'injected-out',
      stderr: 'injected-err',
    },
  );
  await assert.rejects(
    runProcessTreeBounded(
      'trusted-injected-helper',
      [],
      { encoding: 'utf8' },
      {
        label: 'injected async timeout',
        timeoutMs: 50,
        graceMs: 100,
        forceMs: 1000,
        trustedEvaluatorCommand: true,
      },
      injectedRuntime({ hang: true }),
    ),
    /injected async timeout exceeded its time bound/,
  );
});

test('terminates an async helper tree when combined output exceeds its bound', async () => {
  let alive = true;
  let child;
  const signals = [];
  const injected = {
    platform: 'linux',
    spawn() {
      child = new EventEmitter();
      child.pid = 424242;
      child.stdout = new PassThrough();
      child.stderr = new PassThrough();
      process.nextTick(() => {
        child.stdout.write('123');
        child.stderr.write('456');
      });
      return child;
    },
    kill(_pid, signal) {
      if (!alive) throw processError('ESRCH');
      if (signal === 0) return;
      signals.push(signal);
      alive = false;
      process.nextTick(() => child.emit('close', null, signal));
    },
  };
  await assert.rejects(
    runProcessTreeBounded(
      'trusted-injected-helper',
      [],
      { encoding: 'utf8' },
      {
        label: 'async output fixture',
        timeoutMs: 1000,
        maxBuffer: 5,
        graceMs: 100,
        forceMs: 1000,
        trustedEvaluatorCommand: true,
      },
      injected,
    ),
    /async output fixture exceeded its output bound/,
  );
  assert.deepEqual(signals, ['SIGTERM']);
});

test('rejects unsafe async policies and encodings before spawn', async () => {
  let spawnCalls = 0;
  const injected = {
    platform: 'linux',
    spawn() {
      spawnCalls += 1;
      throw new Error('must not spawn');
    },
  };
  await assert.rejects(
    runProcessTreeBounded(
      'candidate-controlled-command',
      [],
      {},
      { label: 'untrusted async fixture', timeoutMs: 1000 },
      injected,
    ),
    /restricted to trusted evaluator-owned helpers/,
  );
  await assert.rejects(
    runProcessTreeBounded(
      'trusted-helper',
      [],
      { encoding: 'utf16le' },
      {
        label: 'unsupported encoding fixture',
        timeoutMs: 1000,
        trustedEvaluatorCommand: true,
      },
      injected,
    ),
    /encoding is unsupported/,
  );
  await assert.rejects(
    runProcessTreeBounded(
      'trusted-helper',
      [],
      {},
      {
        label: 'invalid bound fixture',
        timeoutMs: 0,
        trustedEvaluatorCommand: true,
      },
      injected,
    ),
    /bounded process-tree policy is invalid/,
  );
  assert.equal(spawnCalls, 0);
});

test('delivers one bounded opaque argument payload on inherited FD 3', {
  skip: process.platform === 'win32',
}, async () => {
  const payload = Buffer.from('--clearenv\0--setenv\0ANTHROPIC_API_KEY\0opaque-fixture\0');
  const result = await runProcessTreeBounded(
    process.execPath,
    ['-e', [
      "const fs=require('node:fs');",
      "const crypto=require('node:crypto');",
      "const value=fs.readFileSync(3);",
      "process.stdout.write(crypto.createHash('sha256').update(value).digest('hex'));",
    ].join('')],
    { encoding: 'utf8' },
    {
      label: 'FD 3 argument fixture',
      timeoutMs: 5000,
      trustedEvaluatorCommand: true,
      argumentInput: { fd: 3, payload },
    },
  );
  assert.equal(
    result.stdout,
    require('node:crypto').createHash('sha256').update(payload).digest('hex'),
  );
  assert.equal(result.status, 0);
});

test('fails closed and terminates the tree when FD 3 delivery breaks', {
  skip: process.platform === 'win32',
}, async () => {
  const secret = 'opaque-argument-value-must-not-enter-diagnostics';
  await assert.rejects(
    runProcessTreeBounded(
      process.execPath,
      ['-e', [
        "const fs=require('node:fs');",
        'fs.closeSync(3);',
        'setInterval(()=>{},1000);',
      ].join('')],
      { encoding: 'utf8' },
      {
        label: 'broken FD 3 fixture',
        timeoutMs: 5000,
        graceMs: 0,
        forceMs: 5000,
        trustedEvaluatorCommand: true,
        argumentInput: {
          fd: 3,
          payload: Buffer.from(secret.repeat(15000)),
        },
      },
    ),
    (error) => {
      assert.match(error.message, /broken FD 3 fixture argument payload delivery failed/);
      assert.doesNotMatch(error.message, new RegExp(secret));
      return true;
    },
  );
});

test('a termination fault never replaces the reason the run was abandoned', {
  skip: process.platform === 'win32',
}, async () => {
  // This is what made the FD-3 flake present as the WRONG error rather than as a
  // cleanup warning: the teardown ran before the diagnosis was thrown, so its
  // own failure surfaced in place of it. Driven here with a kill that refuses
  // for a reason the lib does not tolerate, so the fault is deterministic.
  const { spawn } = require('node:child_process');
  const secret = 'opaque-argument-value-must-not-enter-diagnostics';
  let treePid = null;
  const refusing = {
    platform: process.platform,
    spawnSync: () => ({ status: 0 }),
    spawn: (...args) => { const child = spawn(...args); treePid = child.pid; return child; },
    kill: (pid, signal) => {
      if (pid < 0) throw processError('EACCES');
      return process.kill(pid, signal);
    },
  };
  try {
    await assert.rejects(
      runProcessTreeBounded(
        process.execPath,
        ['-e', ["const fs=require('node:fs');", 'fs.closeSync(3);', 'setInterval(()=>{},1000);'].join('')],
        { encoding: 'utf8' },
        {
          label: 'masking fixture',
          timeoutMs: 5000,
          graceMs: 0,
          forceMs: 100,
          trustedEvaluatorCommand: true,
          argumentInput: { fd: 3, payload: Buffer.from(secret.repeat(15000)) },
        },
        refusing,
      ),
      (error) => {
        assert.match(error.message, /masking fixture argument payload delivery failed/);
        assert.doesNotMatch(error.message, new RegExp(secret));
        assert.equal(error.cause?.code, 'EACCES', 'the cleanup fault travels as the cause, it is not discarded');
        return true;
      },
    );
  } finally {
    // The lib never got to kill the tree, because this runtime refused.
    if (treePid) { try { process.kill(-treePid, 'SIGKILL'); } catch (_error) { /* already gone */ } }
  }
});

test('rejects invalid argument-input policies before any spawn attempt', async () => {
  let spawnCalls = 0;
  const injected = runtime(
    'linux',
    () => {},
    () => ({ status: 0 }),
    () => {
      spawnCalls += 1;
      throw new Error('must not spawn');
    },
  );
  for (const argumentInput of [
    { fd: 2, payload: Buffer.from('x') },
    { fd: 3, payload: Buffer.alloc(0) },
    { fd: 3, payload: 'not-a-buffer' },
    { fd: 3, payload: Buffer.alloc((1024 * 1024) + 1) },
  ]) {
    await assert.rejects(
      runProcessTreeBounded(
        'fixture',
        [],
        {},
        {
          label: 'invalid argument fixture',
          timeoutMs: 1000,
          trustedEvaluatorCommand: true,
          argumentInput,
        },
        injected,
      ),
      /bounded process-tree policy is invalid/,
    );
  }
  assert.equal(spawnCalls, 0);
});
