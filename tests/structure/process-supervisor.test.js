'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const test = require('node:test');

const supervisor = path.resolve(__dirname, '../../scripts/process-supervisor.js');
const { UNREACHABLE_EXIT_CODE, groupAlive, probeGroup, signalGroup, waitForGroupExit } = require(supervisor);
const lease = 'a'.repeat(64);
const posixProcessGroups = process.platform === 'win32'
  ? { skip: 'native Windows has no POSIX process-group signaling; the local adapter requires macOS, Linux, or WSL' }
  : {};
const zombieOnlyGroup = process.platform !== 'darwin'
  ? { skip: 'only macOS answers EPERM for a group that holds nothing but zombies; Linux reports it alive until it is reaped' }
  : spawnSync('perl', ['-e', '1']).status === 0 ? {} : { skip: 'perl is unavailable to build the zombie fixture' };

function waitFor(file, predicate = fs.existsSync) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 10000;
    const poll = () => {
      if (predicate(file)) { resolve(); return; }
      if (Date.now() >= deadline) { reject(new Error(`timed out waiting for ${file}`)); return; }
      setTimeout(poll, 20);
    };
    poll();
  });
}

function hasContent(file) {
  try { return fs.statSync(file).size > 0; }
  catch (_error) { return false; }
}

function processState(pid) {
  return spawnSync('ps', ['-o', 'stat=', '-p', String(pid)], { encoding: 'utf8' }).stdout.trim();
}

function exitCodeOf(child, timeoutMs = 12000) {
  if (child.exitCode !== null) return Promise.resolve(child.exitCode);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('supervisor did not exit')), timeoutMs);
    child.once('exit', (code) => { clearTimeout(timer); resolve(code); });
  });
}

function closedLoopbackPort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

test('lease-authenticated supervisor reports status and tears down its owned process group', posixProcessGroups, async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-supervisor-'));
  const ready = path.join(root, 'service.ready');
  const log = path.join(root, 'service.log');
  const childEnv = path.join(root, 'child-env');
  const processHandle = spawn(process.execPath, [supervisor, 'start', ready, log, root,
    process.execPath, '-e', `require('node:fs').writeFileSync(${JSON.stringify(childEnv)}, process.env.ZENSU_VERIFY_RUNTIME_LEASE || 'absent'); setInterval(() => {}, 1000)`], {
    env: { ...process.env, ZENSU_VERIFY_RUNTIME_LEASE: lease },
    stdio: 'ignore',
  });
  try {
    await waitFor(ready);
    await waitFor(childEnv);
    assert.equal(fs.readFileSync(childEnv, 'utf8'), 'absent');
    const status = spawnSync(process.execPath, [supervisor, 'status', ready], {
      env: { ...process.env, ZENSU_VERIFY_RUNTIME_LEASE: lease },
      encoding: 'utf8',
    });
    assert.equal(status.status, 0, status.stderr);
    const childPid = JSON.parse(status.stdout).childPid;
    assert.doesNotThrow(() => process.kill(childPid, 0));

    const rejected = spawnSync(process.execPath, [supervisor, 'status', ready], {
      env: { ...process.env, ZENSU_VERIFY_RUNTIME_LEASE: 'b'.repeat(64) },
      encoding: 'utf8',
    });
    assert.notEqual(rejected.status, 0);

    const stopped = spawnSync(process.execPath, [supervisor, 'stop', ready], {
      env: { ...process.env, ZENSU_VERIFY_RUNTIME_LEASE: lease },
      encoding: 'utf8',
    });
    assert.equal(stopped.status, 0, stopped.stderr);
    await waitFor(ready, (candidate) => !fs.existsSync(candidate));
    assert.throws(() => process.kill(childPid, 0), /ESRCH/);
  } finally {
    try { processHandle.kill('SIGTERM'); } catch (_error) {}
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('stop waits for and SIGKILLs a descendant that survives SIGTERM', posixProcessGroups, async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-supervisor-tree-'));
  const ready = path.join(root, 'service.ready');
  const log = path.join(root, 'service.log');
  const descendantFile = path.join(root, 'descendant.pid');
  const descendant = `process.on("SIGTERM",()=>{});require("node:fs").writeFileSync(${JSON.stringify(descendantFile)},String(process.pid));setInterval(()=>{},1000)`;
  const script = `
    const { spawn } = require('node:child_process');
    spawn(process.execPath, ['-e', ${JSON.stringify(descendant)}], { stdio: 'ignore' });
    setInterval(() => {}, 1000);
  `;
  const processHandle = spawn(process.execPath, [supervisor, 'start', ready, log, root,
    process.execPath, '-e', script], {
    env: { ...process.env, ZENSU_VERIFY_RUNTIME_LEASE: lease },
    stdio: 'ignore',
  });
  try {
    await waitFor(ready);
    await waitFor(descendantFile, hasContent);
    const descendantPid = Number(fs.readFileSync(descendantFile, 'utf8'));
    assert.doesNotThrow(() => process.kill(descendantPid, 0));
    const started = Date.now();
    const stopped = spawnSync(process.execPath, [supervisor, 'stop', ready], {
      env: { ...process.env, ZENSU_VERIFY_RUNTIME_LEASE: lease },
      encoding: 'utf8',
      timeout: 12000,
    });
    assert.equal(stopped.status, 0, stopped.stderr);
    assert.ok(Date.now() - started >= 4900, 'stop acknowledgement arrived before TERM timeout and KILL');
    assert.throws(() => process.kill(descendantPid, 0), /ESRCH/);
  } finally {
    try { processHandle.kill('SIGTERM'); } catch (_error) {}
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('stop succeeds when the whole child tree exits at once and leaves only an unreaped leader', posixProcessGroups, async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-supervisor-zombie-'));
  const ready = path.join(root, 'service.ready');
  const log = path.join(root, 'service.log');
  const descendantFile = path.join(root, 'descendant.pid');
  const script = `
    const { spawn } = require('node:child_process');
    const fs = require('node:fs');
    const child = spawn(process.execPath, ['-e', 'setInterval(()=>{},1000)'], { stdio: 'ignore' });
    fs.writeFileSync(${JSON.stringify(descendantFile)}, String(child.pid));
    setInterval(() => {}, 1000);
  `;
  const processHandle = spawn(process.execPath, [supervisor, 'start', ready, log, root,
    process.execPath, '-e', script], {
    env: { ...process.env, ZENSU_VERIFY_RUNTIME_LEASE: lease },
    stdio: 'ignore',
  });
  try {
    await waitFor(ready);
    await waitFor(descendantFile, hasContent);
    const descendantPid = Number(fs.readFileSync(descendantFile, 'utf8'));
    const stopped = spawnSync(process.execPath, [supervisor, 'stop', ready], {
      env: { ...process.env, ZENSU_VERIFY_RUNTIME_LEASE: lease },
      encoding: 'utf8',
      timeout: 12000,
    });
    assert.equal(stopped.status, 0, stopped.stderr);
    assert.equal(fs.existsSync(ready), false);
    assert.equal(await exitCodeOf(processHandle), 0);
    assert.throws(() => process.kill(descendantPid, 0), /ESRCH/);
  } finally {
    try { processHandle.kill('SIGTERM'); } catch (_error) {}
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('stop succeeds when the owned group holds only a zombie that a process outside the group never reaps', zombieOnlyGroup, async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-supervisor-zombie-only-'));
  const ready = path.join(root, 'service.ready');
  const log = path.join(root, 'service.log');
  const zombieFile = path.join(root, 'zombie.pid');
  const holderFile = path.join(root, 'holder.pid');
  const script = [
    'my ($zombie_file, $holder_file) = @ARGV;',
    'my $leader = $$;',
    'if (fork() == 0) {',
    '  setpgrp(0, 0);',
    '  if (fork() == 0) {',
    '    setpgrp(0, $leader) or exit 1;',
    '    open(my $out, ">", $zombie_file) or exit 1;',
    '    print $out $$;',
    '    close $out;',
    '    exit 0;',
    '  }',
    '  open(my $out, ">", $holder_file) or exit 1;',
    '  print $out $$;',
    '  close $out;',
    '  sleep 60;',
    '  exit 0;',
    '}',
    'sleep 60;',
  ].join('\n');
  const processHandle = spawn(process.execPath, [supervisor, 'start', ready, log, root,
    'perl', '-e', script, zombieFile, holderFile], {
    env: { ...process.env, ZENSU_VERIFY_RUNTIME_LEASE: lease },
    stdio: 'ignore',
  });
  let holderPid = null;
  try {
    await waitFor(ready);
    await waitFor(holderFile, hasContent);
    holderPid = Number(fs.readFileSync(holderFile, 'utf8'));
    await waitFor(zombieFile, hasContent);
    const zombiePid = Number(fs.readFileSync(zombieFile, 'utf8'));
    await waitFor(zombieFile, () => processState(zombiePid).startsWith('Z'));
    const stopped = spawnSync(process.execPath, [supervisor, 'stop', ready], {
      env: { ...process.env, ZENSU_VERIFY_RUNTIME_LEASE: lease },
      encoding: 'utf8',
      timeout: 15000,
    });
    assert.equal(stopped.status, 0, stopped.stderr);
    assert.equal(fs.existsSync(ready), false);
    assert.equal(await exitCodeOf(processHandle), 0);
  } finally {
    if (holderPid) { try { process.kill(holderPid, 'SIGKILL'); } catch (_error) {} }
    try { processHandle.kill('SIGTERM'); } catch (_error) {}
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('the group probe tells gone from unsignalable, a stop wait ends on EPERM only at its deadline, and any other error still throws', async () => {
  const original = process.kill;
  const answer = (code) => {
    process.kill = () => {
      if (code === null) return true;
      const error = new Error(code);
      error.code = code;
      throw error;
    };
  };
  try {
    answer(null);
    assert.equal(probeGroup(4242), 'alive');
    assert.equal(groupAlive(4242), true);
    answer('ESRCH');
    assert.equal(probeGroup(4242), 'gone');
    assert.equal(signalGroup(4242, 'SIGTERM'), false);
    assert.equal(await waitForGroupExit(4242, 5000), 'gone');
    answer('EPERM');
    assert.equal(probeGroup(4242), 'unsignalable');
    assert.equal(groupAlive(4242), false);
    assert.equal(signalGroup(4242, 'SIGTERM'), false);
    const started = Date.now();
    assert.equal(await waitForGroupExit(4242, 200), 'unsignalable');
    assert.ok(Date.now() - started >= 195, 'an EPERM probe ended the wait before its deadline');
    answer('EINVAL');
    assert.throws(() => probeGroup(4242), /failed to probe owned process group: EINVAL/);
    assert.throws(() => signalGroup(4242, 'SIGKILL'), /failed to send SIGKILL to owned process group: EINVAL/);
  } finally {
    process.kill = original;
  }
});

test('a request to an endpoint no supervisor answers exits with the unreachable code', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-supervisor-stale-'));
  const ready = path.join(root, 'service.ready');
  try {
    const port = await closedLoopbackPort();
    fs.writeFileSync(ready, `${JSON.stringify({ version: 1, supervisorPid: process.pid, port })}\n`, { mode: 0o600 });
    for (const action of ['status', 'stop']) {
      const result = spawnSync(process.execPath, [supervisor, action, ready], {
        env: { ...process.env, ZENSU_VERIFY_RUNTIME_LEASE: lease },
        encoding: 'utf8',
      });
      assert.equal(result.status, UNREACHABLE_EXIT_CODE, `${action}: ${result.stderr}`);
      assert.match(result.stderr, /no supervisor answers at the recorded endpoint/);
    }
    assert.equal(UNREACHABLE_EXIT_CODE, 3);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('a child spawn failure never publishes a ready endpoint', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-supervisor-spawn-'));
  const ready = path.join(root, 'service.ready');
  const log = path.join(root, 'service.log');
  try {
    const failed = spawnSync(process.execPath, [supervisor, 'start', ready, log, root,
      path.join(root, 'missing-command')], {
      env: { ...process.env, ZENSU_VERIFY_RUNTIME_LEASE: lease },
      encoding: 'utf8',
    });
    assert.notEqual(failed.status, 0);
    assert.equal(fs.existsSync(ready), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
