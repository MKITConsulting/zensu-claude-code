'use strict';

const fs = require('node:fs');

const DESKTOP_RECORD_MAX_BYTES = 8 * 1024 * 1024;
const READ_AGAIN_BUDGET = 16;

function writableOnlyByCaller(stat) {
  if (process.platform !== 'win32' && (stat.mode & 0o022) !== 0) return false;
  return typeof process.getuid !== 'function' || stat.uid === process.getuid();
}

function anyOwnerOrMode() {
  return true;
}

function realDirectory(target, accept) {
  if (typeof accept !== 'function') throw new TypeError('realDirectory needs an accept policy');
  try {
    const stat = fs.lstatSync(target);
    return !stat.isSymbolicLink() && stat.isDirectory() && accept(stat);
  } catch (_) {
    return false;
  }
}

function ownedRegularFile(target) {
  try {
    const stat = fs.lstatSync(target);
    return stat.isFile() && writableOnlyByCaller(stat);
  } catch (_) {
    return false;
  }
}

function pause(milliseconds) {
  try {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
    return true;
  } catch (_) {
    return false;
  }
}

function readBoundedBytes(file, maxBytes, scratch) {
  let stat;
  try {
    stat = fs.lstatSync(file);
  } catch (error) {
    return { state: error && error.code === 'ENOENT' ? 'missing' : 'refused' };
  }
  if (stat.isSymbolicLink() || !stat.isFile() || stat.size > maxBytes || !writableOnlyByCaller(stat)) {
    return { state: 'refused' };
  }
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0) | (fs.constants.O_NONBLOCK || 0));
  } catch (error) {
    return { state: error && error.code === 'ENOENT' ? 'missing' : 'refused' };
  }
  try {
    const opened = fs.fstatSync(fd);
    if (!opened.isFile() || opened.size > maxBytes || !writableOnlyByCaller(opened)) return { state: 'refused' };
    const capacity = opened.size + 1;
    let buffer;
    if (scratch) {
      if (!Buffer.isBuffer(scratch.buffer) || scratch.buffer.length < capacity) {
        scratch.buffer = Buffer.allocUnsafe(Math.max(capacity, Buffer.isBuffer(scratch.buffer) ? scratch.buffer.length * 2 : 0));
      }
      buffer = scratch.buffer;
    } else {
      buffer = Buffer.alloc(capacity);
    }
    let length = 0;
    let againBudget = READ_AGAIN_BUDGET;
    for (;;) {
      let count;
      try {
        count = fs.readSync(fd, buffer, length, capacity - length, null);
      } catch (error) {
        if (!error || (error.code !== 'EAGAIN' && error.code !== 'EWOULDBLOCK')) throw error;
        if (againBudget === 0) return { state: 'changing' };
        againBudget -= 1;
        pause(1);
        continue;
      }
      if (count === 0) break;
      length += count;
      if (length === capacity) return { state: 'changing' };
    }
    return { state: 'read', bytes: buffer.subarray(0, length) };
  } catch (_) {
    return { state: 'refused' };
  } finally {
    fs.closeSync(fd);
  }
}

function readBoundedFile(file, maxBytes) {
  const read = readBoundedBytes(file, maxBytes);
  return read.state === 'read' ? { state: 'read', text: read.bytes.toString('utf8') } : read;
}

module.exports = {
  DESKTOP_RECORD_MAX_BYTES,
  READ_AGAIN_BUDGET,
  writableOnlyByCaller,
  anyOwnerOrMode,
  realDirectory,
  ownedRegularFile,
  readBoundedBytes,
  readBoundedFile,
};
