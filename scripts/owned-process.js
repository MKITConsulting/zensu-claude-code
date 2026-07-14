#!/usr/bin/env node
'use strict';

const { spawn } = require('node:child_process');

const args = process.argv.slice(2);
if (args.length === 0) {
  process.stderr.write('zensu owned process: missing command\n');
  process.exit(64);
}

function signalGroup(pid, signal) {
  try { process.kill(-pid, signal); return true; }
  catch (error) {
    if (error.code === 'ESRCH') return false;
    throw error;
  }
}

function groupAlive(pid) {
  try { process.kill(-pid, 0); return true; }
  catch (error) {
    if (error.code === 'ESRCH') return false;
    if (error.code === 'EPERM') return true;
    throw error;
  }
}

async function waitForGroupExit(pid, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (groupAlive(pid) && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  return !groupAlive(pid);
}

const child = spawn(args[0], args.slice(1), {
  cwd: process.cwd(),
  env: process.env,
  detached: true,
  stdio: 'inherit',
});

let finishing = false;
let childResult;

async function stopGroup() {
  signalGroup(child.pid, 'SIGTERM');
  if (!await waitForGroupExit(child.pid, 2000)) {
    signalGroup(child.pid, 'SIGKILL');
    if (!await waitForGroupExit(child.pid, 3000)) throw new Error('owned process group survived SIGKILL');
  }
}

async function finish(exitCode) {
  if (finishing) return;
  finishing = true;
  try {
    await stopGroup();
    process.exit(exitCode);
  } catch (error) {
    process.stderr.write(`zensu owned process: ${error.message}\n`);
    process.exit(1);
  }
}

child.once('error', (error) => {
  process.stderr.write(`zensu owned process: ${error.message}\n`);
  process.exit(127);
});
child.once('exit', (code, signal) => {
  childResult = code === null ? 128 + ({ SIGHUP: 1, SIGINT: 2, SIGTERM: 15 }[signal] || 1) : code;
  finish(childResult);
});

process.on('SIGHUP', () => finish(129));
process.on('SIGINT', () => finish(130));
process.on('SIGTERM', () => finish(143));
