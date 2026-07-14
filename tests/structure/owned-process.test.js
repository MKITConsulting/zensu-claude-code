'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const test = require('node:test');

const ownedProcess = path.resolve(__dirname, '../../scripts/owned-process.js');
const posixProcessGroups = process.platform === 'win32'
  ? { skip: 'native Windows has no POSIX process-group signaling; live evals require macOS, Linux, or WSL' }
  : {};

function waitFor(file) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 4000;
    const poll = () => {
      if (fs.existsSync(file)) { resolve(); return; }
      if (Date.now() >= deadline) { reject(new Error(`timed out waiting for ${file}`)); return; }
      setTimeout(poll, 20);
    };
    poll();
  });
}

function waitForExit(handle) {
  return new Promise((resolve, reject) => {
    handle.once('error', reject);
    handle.once('exit', (code) => resolve(code));
  });
}

test('normal root exit still kills a TERM-resistant background descendant', posixProcessGroups, async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-owned-normal-'));
  const descendantFile = path.join(root, 'descendant.pid');
  const descendantReady = path.join(root, 'descendant.ready');
  const script = `
    const { spawn } = require('node:child_process');
    const fs = require('node:fs');
    const child = spawn(process.execPath, ['-e', ${JSON.stringify(`
      const fs = require('node:fs');
      process.on('SIGTERM', () => {});
      fs.writeFileSync(${JSON.stringify(descendantReady)}, 'ready');
      setInterval(() => {}, 1000);
    `)}], { stdio: 'ignore' });
    while (!fs.existsSync(${JSON.stringify(descendantReady)})) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
    child.unref();
    fs.writeFileSync(${JSON.stringify(descendantFile)}, String(child.pid));
  `;
  const handle = spawn(process.execPath, [ownedProcess, process.execPath, '-e', script], { stdio: 'ignore' });
  try {
    await waitFor(descendantFile);
    const descendant = Number(fs.readFileSync(descendantFile, 'utf8'));
    assert.equal(await waitForExit(handle), 0);
    assert.throws(() => process.kill(descendant, 0), /ESRCH/);
  } finally {
    try { handle.kill('SIGKILL'); } catch (_error) {}
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('a descendant forked by a TERM handler remains inside the owned group and is killed', posixProcessGroups, async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-owned-signal-'));
  const readyFile = path.join(root, 'ready');
  const descendantFile = path.join(root, 'late-descendant.pid');
  const script = `
    const { spawn } = require('node:child_process');
    const fs = require('node:fs');
    fs.writeFileSync(${JSON.stringify(readyFile)}, 'ready');
    process.on('SIGTERM', () => {
      const child = spawn(process.execPath, ['-e', 'process.on("SIGTERM",()=>{});setInterval(()=>{},1000)'], { stdio: 'ignore' });
      fs.writeFileSync(${JSON.stringify(descendantFile)}, String(child.pid));
      setTimeout(() => process.exit(0), 50);
    });
    setInterval(() => {}, 1000);
  `;
  const handle = spawn(process.execPath, [ownedProcess, process.execPath, '-e', script], { stdio: 'ignore' });
  try {
    await waitFor(readyFile);
    handle.kill('SIGTERM');
    await waitFor(descendantFile);
    const descendant = Number(fs.readFileSync(descendantFile, 'utf8'));
    assert.equal(await waitForExit(handle), 143);
    assert.throws(() => process.kill(descendant, 0), /ESRCH/);
  } finally {
    try { handle.kill('SIGKILL'); } catch (_error) {}
    fs.rmSync(root, { recursive: true, force: true });
  }
});
