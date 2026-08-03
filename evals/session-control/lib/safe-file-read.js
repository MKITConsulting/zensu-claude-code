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
    && left.mtimeNs === right.mtimeNs
    && left.ctimeNs === right.ctimeNs;
}

function readStableRegularFile(
  file,
  { maxBytes, minBytes = 0, bigint: exactStats = false } = {},
  openFile = fs.openSync,
) {
  if (typeof file !== 'string' || !file || /[\0\r\n]/.test(file)
      || !Number.isSafeInteger(maxBytes) || maxBytes < 0
      || !Number.isSafeInteger(minBytes) || minBytes < 0 || minBytes > maxBytes
      || typeof exactStats !== 'boolean'
      || typeof openFile !== 'function') {
    throw boundedError();
  }
  const minimumSize = BigInt(minBytes);
  const maximumSize = BigInt(maxBytes);
  let before;
  try {
    before = fs.lstatSync(file, { bigint: true });
  } catch (_error) {
    throw boundedError();
  }
  if (!before.isFile() || before.isSymbolicLink()
      || before.size < minimumSize || before.size > maximumSize) {
    throw boundedError();
  }

  const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0);
  let descriptor;
  try {
    descriptor = openFile(file, flags);
    const opened = fs.fstatSync(descriptor, { bigint: true });
    if (!opened.isFile() || opened.isSymbolicLink()
        || opened.size < minimumSize || opened.size > maximumSize) {
      throw boundedError();
    }
    if (!sameIdentity(before, opened)) throw changedError();

    const size = Number(opened.size);
    const buffer = Buffer.alloc(size);
    let offset = 0;
    while (offset < buffer.length) {
      const read = fs.readSync(descriptor, buffer, offset, buffer.length - offset, offset);
      if (read === 0) throw changedError();
      offset += read;
    }
    const overflow = Buffer.alloc(1);
    if (fs.readSync(descriptor, overflow, 0, 1, size) !== 0) throw changedError();
    const after = fs.fstatSync(descriptor, { bigint: true });
    if (!sameIdentity(opened, after)) throw changedError();
    if (exactStats) return { buffer, stat: after };

    const compatible = fs.fstatSync(descriptor);
    const final = fs.fstatSync(descriptor, { bigint: true });
    if (!compatible.isFile() || compatible.isSymbolicLink()
        || compatible.size !== size || !sameIdentity(after, final)) {
      throw changedError();
    }
    return { buffer, stat: compatible };
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
