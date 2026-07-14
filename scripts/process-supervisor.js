#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const { spawn } = require('node:child_process');

const MAX_REQUEST_BYTES = 4096;

function fail(message) {
  process.stderr.write(`zensu process supervisor: ${message}\n`);
  process.exit(1);
}

function lease() {
  const value = process.env.ZENSU_VERIFY_RUNTIME_LEASE || '';
  if (!/^[a-f0-9]{64}$/.test(value)) fail('a valid runtime lease is required');
  return value;
}

function equalLease(left, right) {
  if (typeof left !== 'string' || left.length !== right.length) return false;
  return crypto.timingSafeEqual(Buffer.from(left), Buffer.from(right));
}

function signalGroup(pid, signal) {
  try { process.kill(-pid, signal); return true; }
  catch (error) {
    if (error.code === 'ESRCH') return false;
    throw new Error(`failed to send ${signal} to owned process group: ${error.code || error.message}`);
  }
}

function groupAlive(pid) {
  try { process.kill(-pid, 0); return true; }
  catch (error) {
    if (error.code === 'ESRCH') return false;
    throw new Error(`failed to probe owned process group: ${error.code || error.message}`);
  }
}

async function waitForGroupExit(pid, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (groupAlive(pid) && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  return !groupAlive(pid);
}

async function start(readyPath, logPath, cwd, command, commandArgs) {
  const expectedLease = lease();
  let terminationRequested = false;
  const requestEarlyTermination = () => { terminationRequested = true; };
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, requestEarlyTermination);
  for (const value of [readyPath, logPath, cwd]) {
    if (!path.isAbsolute(value)) fail('all supervisor paths must be absolute');
  }
  if (!fs.statSync(cwd).isDirectory()) fail('service working directory is invalid');
  if (fs.existsSync(readyPath)) fail('supervisor ownership path already exists');

  const logFd = fs.openSync(logPath, 'a', 0o600);
  const childEnv = { ...process.env };
  delete childEnv.ZENSU_VERIFY_RUNTIME_LEASE;
  const child = spawn(command, commandArgs, {
    cwd,
    env: childEnv,
    detached: true,
    stdio: ['ignore', logFd, logFd],
  });
  fs.closeSync(logFd);

  await new Promise((resolve, reject) => {
    child.once('spawn', resolve);
    child.once('error', reject);
  }).catch((error) => {
    fs.appendFileSync(logPath, `supervisor child error: ${error.message}\n`);
    throw error;
  });

  let stopping = false;
  child.once('error', (error) => {
    fs.appendFileSync(logPath, `supervisor child error: ${error.message}\n`);
  });

  const cleanupPaths = () => {
    for (const candidate of [readyPath]) {
      try { fs.unlinkSync(candidate); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
  };
  let stopPromise;
  const stop = async () => {
    if (stopPromise) return stopPromise;
    stopping = true;
    stopPromise = (async () => {
      signalGroup(child.pid, 'SIGTERM');
      if (!await waitForGroupExit(child.pid, 5000)) {
        signalGroup(child.pid, 'SIGKILL');
        if (!await waitForGroupExit(child.pid, 3000)) {
          throw new Error('owned process group survived SIGKILL');
        }
      }
      cleanupPaths();
    })();
    return stopPromise;
  };

  const server = net.createServer((socket) => {
    let buffer = '';
    socket.setEncoding('utf8');
    socket.on('data', (chunk) => {
      buffer += chunk;
      if (Buffer.byteLength(buffer) > MAX_REQUEST_BYTES) {
        socket.end('{"ok":false,"error":"request-too-large"}\n');
        return;
      }
      const newline = buffer.indexOf('\n');
      if (newline === -1) return;
      let request;
      try { request = JSON.parse(buffer.slice(0, newline)); }
      catch (_error) { socket.end('{"ok":false,"error":"invalid-request"}\n'); return; }
      if (!equalLease(request.lease, expectedLease)) {
        socket.end('{"ok":false,"error":"lease-rejected"}\n');
        return;
      }
      if (request.action === 'status') {
        socket.end(`${JSON.stringify({ ok: !stopping && groupAlive(child.pid), childPid: child.pid })}\n`);
        return;
      }
      if (request.action !== 'stop') {
        socket.end('{"ok":false,"error":"unknown-action"}\n');
        return;
      }
      stop().then(() => {
        socket.end('{"ok":true}\n', () => {
          server.close(() => process.exit(0));
        });
      }).catch((error) => socket.end(`${JSON.stringify({ ok: false, error: error.message })}\n`, () => fail(error.message)));
    });
  });
  server.on('error', (error) => {
    fs.appendFileSync(logPath, `supervisor socket error: ${error.message}\n`);
    terminate();
  });

  const terminate = () => {
    stop().then(() => {
      if (server.listening) server.close(() => process.exit(0));
      else process.exit(0);
    }).catch((error) => fail(error.message));
  };
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.removeListener(signal, requestEarlyTermination);
  }
  process.on('SIGINT', terminate);
  process.on('SIGTERM', terminate);
  process.on('SIGHUP', terminate);
  process.on('uncaughtException', (error) => {
    fs.appendFileSync(logPath, `supervisor failure: ${error.message}\n`);
    terminate();
  });

  if (terminationRequested) {
    terminate();
    return;
  }

  server.listen({ host: '127.0.0.1', port: 0, exclusive: true }, () => {
    const address = server.address();
    fs.writeFileSync(readyPath, `${JSON.stringify({
      version: 1,
      supervisorPid: process.pid,
      port: address.port,
    })}\n`, {
      mode: 0o600,
      flag: 'wx',
    });
  });
}

async function request(readyPath, action) {
  const runtimeLease = lease();
  const info = fs.lstatSync(readyPath);
  if (!info.isFile() || info.isSymbolicLink()) fail('supervisor endpoint is invalid');
  const endpoint = JSON.parse(fs.readFileSync(readyPath, 'utf8'));
  if (endpoint.version !== 1 || !Number.isInteger(endpoint.port) || endpoint.port < 1024
      || endpoint.port > 65535 || !Number.isInteger(endpoint.supervisorPid) || endpoint.supervisorPid < 1) {
    fail('supervisor endpoint is invalid');
  }
  const response = await new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: '127.0.0.1', port: endpoint.port });
    let buffer = '';
    const timeoutMs = action === 'stop' ? 10000 : 3000;
    const timer = setTimeout(() => { socket.destroy(); reject(new Error('supervisor request timed out')); }, timeoutMs);
    socket.setEncoding('utf8');
    socket.on('connect', () => socket.write(`${JSON.stringify({ lease: runtimeLease, action })}\n`));
    socket.on('data', (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf('\n');
      if (newline === -1) return;
      clearTimeout(timer);
      socket.end();
      try { resolve(JSON.parse(buffer.slice(0, newline))); }
      catch (_error) { reject(new Error('invalid supervisor response')); }
    });
    socket.on('error', (error) => { clearTimeout(timer); reject(error); });
  });
  if (!response.ok) fail(response.error || 'supervisor rejected request');
  process.stdout.write(`${JSON.stringify(response)}\n`);
}

async function main() {
  const [action, ...args] = process.argv.slice(2);
  if (action === 'start') {
    if (args.length < 5) fail('usage: start <ready> <log> <cwd> <command> [args...]');
    await start(args[0], args[1], args[2], args[3], args.slice(4));
    return;
  }
  if (['status', 'stop'].includes(action) && args.length === 1) {
    await request(args[0], action);
    return;
  }
  fail('unknown supervisor action');
}

if (require.main === module) {
  main().catch((error) => fail(error.message));
}

module.exports = { equalLease, groupAlive, signalGroup, waitForGroupExit };
