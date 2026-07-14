'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const test = require('node:test');

const supervisor = path.resolve(__dirname, '../../scripts/process-supervisor.js');
const lease = 'a'.repeat(64);
const posixProcessGroups = process.platform === 'win32'
  ? { skip: 'native Windows has no POSIX process-group signaling; the local adapter requires macOS, Linux, or WSL' }
  : {};

function waitFor(file, predicate = fs.existsSync) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 3000;
    const poll = () => {
      if (predicate(file)) { resolve(); return; }
      if (Date.now() >= deadline) { reject(new Error(`timed out waiting for ${file}`)); return; }
      setTimeout(poll, 20);
    };
    poll();
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
  const script = `
    const { spawn } = require('node:child_process');
    const fs = require('node:fs');
    const child = spawn(process.execPath, ['-e', 'process.on("SIGTERM",()=>{});setInterval(()=>{},1000)'], { stdio: 'ignore' });
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
    await waitFor(descendantFile);
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
