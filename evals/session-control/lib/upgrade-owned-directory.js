#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

class OwnedDirectoryError extends Error {}

const DEFAULT_RUNTIME = Object.freeze({
  existsSync: fs.existsSync,
  lstatSync: fs.lstatSync,
  realpathSync: fs.realpathSync.native,
  renameSync: fs.renameSync,
  rmSync: fs.rmSync,
  randomBytes: crypto.randomBytes,
});

function fail(message) {
  throw new OwnedDirectoryError(`owned directory: ${message}`);
}

function validPath(input, label) {
  if (typeof input !== 'string' || !path.isAbsolute(input) || /[\0\r\n]/.test(input)) {
    fail(`${label} path is invalid`);
  }
  return path.resolve(input);
}

function sameIdentity(left, right) {
  return left.dev === right.dev
    && left.ino === right.ino
    && left.mode === right.mode;
}

function captureOwnedDirectory(input, label, runtime = DEFAULT_RUNTIME) {
  const expected = validPath(input, label);
  let before;
  let after;
  let canonical;
  try {
    before = runtime.lstatSync(expected, { bigint: true });
    canonical = runtime.realpathSync(expected);
    after = runtime.lstatSync(expected, { bigint: true });
  } catch (_error) {
    fail(`${label} is unavailable`);
  }
  if (!before.isDirectory() || before.isSymbolicLink()
      || !after.isDirectory() || after.isSymbolicLink()
      || !sameIdentity(before, after) || canonical !== expected) {
    fail(`${label} is not the expected canonical directory`);
  }
  return Object.freeze({
    path: expected,
    canonical,
    dev: after.dev,
    ino: after.ino,
    mode: after.mode,
  });
}

function revalidateOwnedDirectory(identity, label, runtime = DEFAULT_RUNTIME) {
  const current = captureOwnedDirectory(identity.path, label, runtime);
  if (current.canonical !== identity.canonical || !sameIdentity(current, identity)) {
    fail(`${label} identity changed`);
  }
  return current;
}

function quarantineAndRemoveOwnedDirectory(
  identity,
  parentIdentity,
  label,
  runtime = DEFAULT_RUNTIME,
) {
  revalidateOwnedDirectory(parentIdentity, `${label} parent`, runtime);
  revalidateOwnedDirectory(identity, label, runtime);
  if (path.dirname(identity.path) !== parentIdentity.path) {
    fail(`${label} is not a direct child of its owned parent`);
  }
  const quarantine = path.join(
    parentIdentity.path,
    `.${path.basename(identity.path)}.cleanup-${runtime.randomBytes(16).toString('hex')}`,
  );
  if (runtime.existsSync(quarantine)) fail(`${label} quarantine path already exists`);
  try {
    runtime.renameSync(identity.path, quarantine);
  } catch (_error) {
    fail(`${label} could not be quarantined`);
  }
  revalidateOwnedDirectory(parentIdentity, `${label} parent`, runtime);
  const quarantined = captureOwnedDirectory(quarantine, `${label} quarantine`, runtime);
  if (!sameIdentity(quarantined, identity) || runtime.existsSync(identity.path)) {
    fail(`${label} quarantine identity changed`);
  }
  try {
    runtime.rmSync(quarantine, { recursive: true, force: false });
  } catch (_error) {
    fail(`${label} quarantine could not be removed`);
  }
  if (runtime.existsSync(quarantine)) fail(`${label} quarantine removal did not complete`);
}

module.exports = {
  OwnedDirectoryError,
  captureOwnedDirectory,
  quarantineAndRemoveOwnedDirectory,
  revalidateOwnedDirectory,
};
