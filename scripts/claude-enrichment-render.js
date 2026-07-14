#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
const { protectFraming, sanitize } = require('./claude-stream-render.js');

const MAX_FILES = 100;
const MAX_FILE_BYTES = 1024 * 1024;
const MAX_OUTPUT_BYTES = 1024 * 1024 - 128;

let outputBytes = 0;
let outputCapped = false;

function emit(value) {
  if (outputCapped) return;
  const line = `${value}\n`;
  const bytes = Buffer.byteLength(line);
  if (outputBytes + bytes > MAX_OUTPUT_BYTES) {
    process.stdout.write('[enrichment_warning] output limit reached\n');
    outputCapped = true;
    return;
  }
  process.stdout.write(line);
  outputBytes += bytes;
}

function openSafe(file, root) {
  const info = fs.lstatSync(file);
  if (!info.isFile() || info.isSymbolicLink()) throw new Error('unsafe enrichment file');
  const physical = fs.realpathSync(file);
  if (!physical.startsWith(`${root}${path.sep}`)) throw new Error('out-of-root enrichment file');
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  if (!fs.fstatSync(fd).isFile()) {
    fs.closeSync(fd);
    throw new Error('non-regular enrichment file');
  }
  return fd;
}

async function renderLines(file, heading, root) {
  emit('');
  emit(`===== ${heading} =====`);
  const fd = openSafe(file, root);
  const size = fs.fstatSync(fd).size;
  const input = fs.createReadStream(null, { fd, autoClose: true, encoding: 'utf8', start: 0, end: MAX_FILE_BYTES - 1 });
  const lines = readline.createInterface({ input, crlfDelay: Infinity });
  for await (const line of lines) emit(protectFraming(sanitize(line)));
  if (size > MAX_FILE_BYTES) emit('[enrichment_warning] input file truncated');
}

function renderFsm(file, root) {
  emit('');
  emit(`===== fsm state: ${protectFraming(sanitize(path.basename(file)))} =====`);
  let state;
  let fd;
  try {
    fd = openSafe(file, root);
    const size = fs.fstatSync(fd).size;
    if (size > MAX_FILE_BYTES) throw new Error('oversized');
    state = JSON.parse(fs.readFileSync(fd, 'utf8'));
    fs.closeSync(fd);
    fd = undefined;
  } catch (_error) {
    if (fd !== undefined) fs.closeSync(fd);
    emit('[fsm-state-invalid]');
    return;
  }
  emit(`[fsm-state-final] phase=${protectFraming(sanitize(state.phase || 'UNINITIALIZED'))} step=${protectFraming(sanitize(state.step_id || '?'))}`);
  for (const item of Array.isArray(state.history) ? state.history.slice(0, 1000) : []) {
    emit(`[fsm-history] step=${protectFraming(sanitize(item?.step || '?'))} phase=${protectFraming(sanitize(item?.phase || '?'))} ts=${protectFraming(sanitize(item?.ts || '?'))}`);
  }
}

async function main() {
  const rawArgs = process.argv.slice(2);
  if (rawArgs[0] !== '--root' || !rawArgs[1]) throw new Error('missing enrichment root');
  const root = fs.realpathSync(rawArgs[1]);
  const args = rawArgs.slice(2, 2 + MAX_FILES * 2);
  for (let index = 0; index < args.length && !outputCapped; index += 2) {
    const kind = args[index];
    const file = args[index + 1];
    if (kind === '--synthetic-uninitialized') {
      emit('');
      emit('[fsm-state-final] phase=UNINITIALIZED step=(none)');
      continue;
    }
    if (!file || !fs.existsSync(file)) continue;
    if (kind === '--hook') await renderLines(file, 'hook events', root);
    else if (kind === '--witness') await renderLines(file, `witness: ${protectFraming(sanitize(path.basename(file)))}`, root);
    else if (kind === '--fsm') renderFsm(file, root);
  }
}

main().catch(() => {
  emit('[enrichment_warning] unsafe or unreadable enrichment input');
  process.exitCode = 1;
});
