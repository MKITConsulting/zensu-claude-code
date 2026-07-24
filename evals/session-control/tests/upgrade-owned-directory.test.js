#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const {
  OwnedDirectoryError,
  captureOwnedDirectory,
  quarantineAndRemoveOwnedDirectory,
  revalidateOwnedDirectory,
} = require('../lib/upgrade-owned-directory.js');

function fixture() {
  const parent = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-owned-parent-')));
  const owned = path.join(parent, 'owned');
  fs.mkdirSync(owned);
  fs.writeFileSync(path.join(owned, 'payload'), 'owned\n');
  return {
    parent,
    parentIdentity: captureOwnedDirectory(parent, 'fixture parent'),
    owned,
    ownedIdentity: captureOwnedDirectory(owned, 'fixture root'),
  };
}

test('quarantines an unchanged owned directory before recursive removal', () => {
  const value = fixture();
  quarantineAndRemoveOwnedDirectory(
    value.ownedIdentity,
    value.parentIdentity,
    'fixture root',
  );
  assert.equal(fs.existsSync(value.owned), false);
  assert.deepEqual(fs.readdirSync(value.parent), []);
  fs.rmdirSync(value.parent);
});

test('refuses to delete a path substituted after the last identity check', () => {
  const value = fixture();
  const original = path.join(value.parent, 'original-owned');
  let swappedQuarantine = '';
  const runtime = {
    existsSync: fs.existsSync,
    lstatSync: fs.lstatSync,
    realpathSync: fs.realpathSync.native,
    randomBytes: crypto.randomBytes,
    rmSync() {
      assert.fail('substituted directory must never reach recursive removal');
    },
    renameSync(from, to) {
      fs.renameSync(from, original);
      fs.mkdirSync(from);
      fs.writeFileSync(path.join(from, 'unrelated'), 'survive\n');
      fs.renameSync(from, to);
      swappedQuarantine = to;
    },
  };
  assert.throws(
    () => quarantineAndRemoveOwnedDirectory(
      value.ownedIdentity,
      value.parentIdentity,
      'fixture root',
      runtime,
    ),
    OwnedDirectoryError,
  );
  assert.equal(fs.readFileSync(path.join(original, 'payload'), 'utf8'), 'owned\n');
  assert.equal(
    fs.readFileSync(path.join(swappedQuarantine, 'unrelated'), 'utf8'),
    'survive\n',
  );
  fs.rmSync(value.parent, { recursive: true, force: true });
});

test('rejects non-canonical paths and identity drift', () => {
  const value = fixture();
  const moved = path.join(value.parent, 'moved');
  fs.renameSync(value.owned, moved);
  fs.mkdirSync(value.owned);
  assert.throws(
    () => revalidateOwnedDirectory(value.ownedIdentity, 'fixture root'),
    /identity changed/,
  );
  assert.throws(
    () => captureOwnedDirectory('relative', 'relative'),
    /path is invalid/,
  );
  fs.rmSync(value.parent, { recursive: true, force: true });
});
