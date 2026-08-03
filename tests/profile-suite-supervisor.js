#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

const MAX_ENCODED_PAYLOAD_BYTES = 24 * 1024;
const MAX_DECODED_PAYLOAD_BYTES = 16 * 1024;
const KEEPALIVE_MS = 60 * 1000;
const WINDOWS_JOB_HELPER_FAILURE_EXIT = 125;

function fail(message) {
  try {
    fs.writeSync(3, `${JSON.stringify({
      schemaVersion: 1,
      type: 'suite-result',
      exitCode: null,
      signal: null,
      spawnError: message,
    })}\n`);
  } catch (_error) {}
  process.exitCode = 1;
}

function readPayload(argument) {
  if (typeof argument !== 'string' || argument.length === 0
      || Buffer.byteLength(argument, 'utf8') > MAX_ENCODED_PAYLOAD_BYTES) {
    throw new Error('supervisor payload is missing or too large');
  }
  const decoded = Buffer.from(argument, 'base64url');
  if (decoded.length > MAX_DECODED_PAYLOAD_BYTES) {
    throw new Error('supervisor payload is missing or too large');
  }
  let value;
  try {
    value = JSON.parse(decoded.toString('utf8'));
  } catch (_error) {
    throw new Error('supervisor payload is invalid');
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || typeof value.command !== 'string' || !Array.isArray(value.args)
      || !pathIsAbsolute(value.command)
      || typeof value.cwd !== 'string' || !pathIsAbsolute(value.cwd)
      || !value.environment || typeof value.environment !== 'object'
      || Array.isArray(value.environment)
      || typeof value.windowsJobHelper !== 'string'
      || !pathIsAbsolute(value.windowsJobHelper)
      || value.args.some((entry) => typeof entry !== 'string')
      || Object.entries(value.environment).some(([key, entry]) => (
        !/^[^=\u0000\r\n]+$/.test(key)
        || typeof entry !== 'string'
        || /[\u0000\r\n]/.test(entry)
      ))) {
    throw new Error('supervisor payload contract is invalid');
  }
  return value;
}

function encodePayload(value) {
  const decoded = Buffer.from(JSON.stringify(value), 'utf8');
  const encoded = decoded.toString('base64url');
  if (decoded.length > MAX_DECODED_PAYLOAD_BYTES
      || Buffer.byteLength(encoded, 'utf8') > MAX_ENCODED_PAYLOAD_BYTES) {
    throw new Error('supervisor payload is missing or too large');
  }
  return encoded;
}

function commandForPlatform(payload) {
  if (process.platform !== 'win32') return payload;
  const systemRoot = process.env.SystemRoot || process.env.SYSTEMROOT;
  if (!systemRoot || !path.isAbsolute(systemRoot)) {
    throw new Error('Windows SystemRoot is unavailable');
  }
  const powershell = fs.realpathSync.native(path.join(
    systemRoot,
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
  ));
  if (!fs.statSync(powershell).isFile()) {
    throw new Error('Windows PowerShell is unavailable');
  }
  return {
    command: powershell,
    args: [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      payload.windowsJobHelper,
      encodePayload({
        ...payload,
        supervisorPid: process.pid,
        ownerPid: process.ppid,
      }),
    ],
  };
}

function pathIsAbsolute(value) {
  return value.startsWith('/') || /^[a-zA-Z]:[\\/]/.test(value);
}

function forward(stream, destination) {
  stream.on('data', (chunk) => {
    if (!destination.write(chunk) && typeof stream.pause === 'function') {
      stream.pause();
      destination.once('drain', () => stream.resume());
    }
  });
}

function holdForParentCleanup() {
  const keepalive = setInterval(() => {}, KEEPALIVE_MS);
  keepalive.ref();
}

function main() {
  const encodedPayload = process.argv[2];
  const payload = readPayload(encodedPayload);
  const invocation = commandForPlatform(payload);
  const child = spawn(invocation.command, invocation.args, {
    cwd: payload.cwd,
    env: payload.environment,
    detached: false,
    stdio: ['ignore', 'pipe', 'pipe'],
    windowsHide: true,
  });
  forward(child.stdout, process.stdout);
  forward(child.stderr, process.stderr);
  let emitted = false;
  const emit = (result) => {
    if (emitted) return;
    emitted = true;
    fs.writeSync(3, `${JSON.stringify({
      schemaVersion: 1,
      type: 'suite-result',
      ...result,
    })}\n`);
    holdForParentCleanup();
  };
  child.once('error', (error) => emit({
    exitCode: null,
    signal: null,
    spawnError: error.message,
  }));
  child.once('close', (exitCode, signal) => {
    const helperFailed = process.platform === 'win32'
      && exitCode === WINDOWS_JOB_HELPER_FAILURE_EXIT;
    emit({
      exitCode: helperFailed ? null : exitCode,
      signal,
      spawnError: helperFailed ? 'windows profile job supervisor failed' : null,
    });
  });
}

try {
  main();
} catch (error) {
  fail(error.message);
}
