#!/usr/bin/env node
'use strict';

const fs = require('node:fs');

class StableFileReadError extends Error {}

function boundedError() {
  return new StableFileReadError('file must be a bounded regular file');
}

function changedError() {
  return new StableFileReadError('file changed during inspection');
}

function sameIdentity(left, right) {
  return left.dev === right.dev
    && left.ino === right.ino
    && left.size === right.size
    && left.mtimeMs === right.mtimeMs
    && left.ctimeMs === right.ctimeMs;
}

function readStableRegularFile(
  file,
  { maxBytes, minBytes = 0 } = {},
  openFile = fs.openSync,
) {
  if (typeof file !== 'string' || !file || /[\0\r\n]/.test(file)
      || !Number.isSafeInteger(maxBytes) || maxBytes < 0
      || !Number.isSafeInteger(minBytes) || minBytes < 0 || minBytes > maxBytes
      || typeof openFile !== 'function') {
    throw boundedError();
  }
  let before;
  try {
    before = fs.lstatSync(file);
  } catch (_error) {
    throw boundedError();
  }
  if (!before.isFile() || before.isSymbolicLink()
      || before.size < minBytes || before.size > maxBytes) {
    throw boundedError();
  }

  const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0);
  let descriptor;
  try {
    descriptor = openFile(file, flags);
    const opened = fs.fstatSync(descriptor);
    if (!opened.isFile() || opened.size < minBytes || opened.size > maxBytes) {
      throw boundedError();
    }
    if (!sameIdentity(before, opened)) throw changedError();

    const buffer = Buffer.alloc(opened.size);
    let offset = 0;
    while (offset < buffer.length) {
      const read = fs.readSync(descriptor, buffer, offset, buffer.length - offset, offset);
      if (read === 0) throw changedError();
      offset += read;
    }
    const overflow = Buffer.alloc(1);
    if (fs.readSync(descriptor, overflow, 0, 1, opened.size) !== 0) throw changedError();
    const after = fs.fstatSync(descriptor);
    if (!sameIdentity(opened, after)) throw changedError();
    return { buffer, stat: after };
  } catch (error) {
    if (error instanceof StableFileReadError) throw error;
    throw changedError();
  } finally {
    if (descriptor !== undefined) {
      try { fs.closeSync(descriptor); } catch (_error) { /* already closed */ }
    }
  }
}

module.exports = {
  StableFileReadError,
  readStableRegularFile,
};
