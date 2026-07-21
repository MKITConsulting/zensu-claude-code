#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawn } = require('node:child_process');
const control = require('../lib/concurrency-control.js');
const core = require('../../../hooks/lib/session-control-core-v1.js');

const root = path.resolve(__dirname, '..', '..', '..');
const revision = execFileSync('git', ['-C', root, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-concurrency-barrier-'));
const childSource = `
const control=require(process.argv[1]);
try {
  const value=control.register(process.argv[2],process.argv[3],process.argv[4],process.argv[5],{timeoutMs:Number(process.argv[6])});
  process.stdout.write(JSON.stringify(value));
} catch (error) { process.stderr.write(error.message+'\\n'); process.exit(1); }
`;

function run(shared, session, timeoutMs = 30000) {
  const child = spawn(process.execPath, ['-e', childSource, path.join(root, 'evals/session-control/lib/concurrency-control.js'),
    shared, root, revision, session, String(timeoutMs)], { stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => { stdout += chunk; });
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  const done = new Promise((resolve) => child.on('close', (status, signal) => resolve({ status, signal, stdout, stderr })));
  return { child, done };
}

async function waitFor(predicate, timeoutMs = 3000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error('timed out waiting for selftest condition');
}

async function successfulBarrier() {
  const shared = path.join(temporary, 'success');
  const sessions = Array.from({ length: 12 }, (_unused, index) => `success-${index}`);
  const processes = sessions.map((session) => run(shared, session));
  const results = await Promise.all(processes.map(({ done }) => done));
  for (const result of results) assert.equal(result.status, 0, result.stderr);
  const evidence = control.verify(shared, root, revision, sessions.map((session) => core.sessionIdHash(session)));
  assert.equal(evidence.participant_count, 12);
  assert.equal(evidence.generation_count, 3);
  assert.equal(evidence.barrier_capacity, 4);
  assert.equal(evidence.overlap_verified, true);
  assert.deepEqual(fs.readdirSync(path.join(shared, 'barrier', 'locks')), []);
  assert.deepEqual(fs.readdirSync(path.join(shared, 'barrier', 'ready')), []);
  assert.deepEqual(fs.readdirSync(path.join(shared, 'barrier', 'releases')), []);

  fs.writeFileSync(path.join(shared, 'barrier', 'ready', 'leftover.ready'), 'attack\n');
  assert.throws(() => control.verify(shared, root, revision, sessions.map((session) => core.sessionIdHash(session))), /ready directory is not clean/);
  fs.unlinkSync(path.join(shared, 'barrier', 'ready', 'leftover.ready'));

  const stateFile = path.join(shared, 'barrier', 'state.json');
  const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  state.generations[0].participants.push({ ...state.generations[0].participants[0], host_session_hash: core.sessionIdHash('fifth') });
  fs.writeFileSync(stateFile, `${JSON.stringify(state)}\n`);
  assert.throws(() => control.verify(shared, root, revision, sessions.map((session) => core.sessionIdHash(session))), /generation 1 is invalid/);
}

async function duplicateFails() {
  const shared = path.join(temporary, 'duplicate');
  const processes = ['duplicate', 'duplicate', 'unique-a', 'unique-b'].map((session) => run(shared, session, 500));
  const results = await Promise.all(processes.map(({ done }) => done));
  assert.ok(results.every((result) => result.status !== 0));
  assert.ok(results.some((result) => /duplicate host session/.test(result.stderr)));
  assert.deepEqual(fs.readdirSync(path.join(shared, 'barrier', 'locks')), []);
}

async function timeoutFails() {
  const shared = path.join(temporary, 'timeout');
  const result = await run(shared, 'alone', 100).done;
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /timed out waiting for exactly four ready participants/);
  assert.deepEqual(fs.readdirSync(path.join(shared, 'barrier', 'locks')), []);
}

async function crashFails() {
  const shared = path.join(temporary, 'crash');
  const first = run(shared, 'crash-a', 1000);
  const second = run(shared, 'crash-b', 1000);
  const third = run(shared, 'crash-c', 1000);
  await waitFor(() => {
    const ready = path.join(shared, 'barrier', 'ready');
    return fs.existsSync(ready) && fs.readdirSync(ready).length === 3;
  });
  first.child.kill('SIGKILL');
  const fourth = run(shared, 'crash-d', 500);
  const results = await Promise.all([first.done, second.done, third.done, fourth.done]);
  assert.ok(results.every((result) => result.status !== 0 || result.signal));
  assert.ok(results.some((result) => /crashed before release|generation failed/.test(result.stderr)));
  const activeLocks = fs.readdirSync(path.join(shared, 'barrier', 'locks'))
    .filter((name) => name.endsWith('.lock') || name.endsWith('.recovery'));
  assert.deepEqual(activeLocks, []);
}

(async () => {
  try {
    await successfulBarrier();
    await duplicateFails();
    await timeoutFails();
    await crashFails();
    process.stdout.write('concurrency-barrier-selftest.js: PASS\n');
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
})().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exit(1);
});
