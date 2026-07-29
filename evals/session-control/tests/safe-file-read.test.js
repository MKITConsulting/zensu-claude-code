#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { readStableRegularFile } = require('../lib/safe-file-read.js');

function withInode(stat, exactInode) {
  const inode = typeof stat.ino === 'bigint' ? exactInode : Number(exactInode);
  return new Proxy(stat, {
    get(target, property) {
      if (property === 'ino') return inode;
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
}

test('reads a bounded regular file through one validated descriptor', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-safe-read-'));
  try {
    const file = path.join(temporary, 'marker');
    fs.writeFileSync(file, '1234567890123', { mode: 0o600 });
    const value = readStableRegularFile(file, { maxBytes: 13 });
    assert.equal(value.buffer.toString('utf8'), '1234567890123');
    assert.equal(value.stat.size, 13);
    const exact = readStableRegularFile(file, { maxBytes: 13, bigint: true });
    assert.equal(exact.buffer.toString('utf8'), '1234567890123');
    assert.equal(exact.stat.size, 13n);
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

test('rejects descriptor identity changes hidden by Number inode rounding', (context) => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-safe-read-bigint-'));
  const file = path.join(temporary, 'payload');
  fs.writeFileSync(file, 'x', { mode: 0o600 });
  const originalLstatSync = fs.lstatSync.bind(fs);
  const originalFstatSync = fs.fstatSync.bind(fs);
  const pathnameInode = 9007199254740992n;
  const descriptorInode = 9007199254740993n;
  context.mock.method(fs, 'lstatSync', (target, options) => (
    withInode(originalLstatSync(target, options), pathnameInode)
  ));
  context.mock.method(fs, 'fstatSync', (descriptor, options) => (
    withInode(originalFstatSync(descriptor, options), descriptorInode)
  ));
  try {
    assert.equal(Number(pathnameInode), Number(descriptorInode));
    assert.throws(
      () => readStableRegularFile(file, { maxBytes: 1 }),
      /changed during inspection/,
    );
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

test('rejects a pathname replaced between lstat and descriptor open', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-safe-read-swap-'));
  try {
    const file = path.join(temporary, 'payload');
    const moved = path.join(temporary, 'payload-before-swap');
    fs.writeFileSync(file, 'trusted', { mode: 0o600 });
    assert.throws(() => readStableRegularFile(
      file,
      { maxBytes: 64 },
      (target, flags) => {
        fs.renameSync(target, moved);
        fs.writeFileSync(target, 'replacement', { mode: 0o600 });
        return fs.openSync(target, flags);
      },
    ), /changed during inspection/);
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

test('rejects symlinks and files larger than the declared bound', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-safe-read-bound-'));
  try {
    const file = path.join(temporary, 'payload');
    fs.writeFileSync(file, 'too-large', { mode: 0o600 });
    assert.throws(
      () => readStableRegularFile(file, { maxBytes: 3 }),
      /must be a bounded regular file/,
    );
    const link = path.join(temporary, 'payload-link');
    try {
      fs.symlinkSync(file, link);
      assert.throws(
        () => readStableRegularFile(link, { maxBytes: 64 }),
        /must be a bounded regular file/,
      );
    } catch (error) {
      if (!['EPERM', 'EACCES', 'ENOSYS'].includes(error?.code)) throw error;
    }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});
