#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const MAX_CONTRACT_FILE_BYTES = 4 * 1024 * 1024;
const MANIFEST_PATH = 'tests/profiles/windows-ci.v1.json';
const CATALOG_PATH = 'tests/profiles/windows-ci-command-catalog.v1.json';
const RUNTIME_PATHS = Object.freeze([
  '.github/workflows/ci.yml',
  MANIFEST_PATH,
  CATALOG_PATH,
  'tests/run-profile.js',
  'tests/profile-suite-supervisor.js',
  'tests/windows-profile-job.ps1',
  'tests/windows-profile-contract.js',
  'tests/summarize-windows-observation.js',
]);

class ProfileContractError extends Error {}

function validateRelativePath(relative, label) {
  if (typeof relative !== 'string'
      || relative.length === 0
      || /[\u0000-\u001f\u007f\\]/.test(relative)
      || path.posix.isAbsolute(relative)
      || /^[a-zA-Z]:/.test(relative)
      || path.posix.normalize(relative) !== relative
      || relative === '.'
      || relative.startsWith('../')) {
    throw new ProfileContractError(`${label} path is invalid`);
  }
  return relative;
}

function readBoundedFile(root, relative, label) {
  validateRelativePath(relative, label);
  let cursor = root;
  for (const segment of relative.split('/')) {
    cursor = path.join(cursor, segment);
    const component = fs.lstatSync(cursor, { bigint: true });
    if (component.isSymbolicLink()) {
      throw new ProfileContractError(`${label} path must not traverse a symlink`);
    }
  }
  const before = fs.lstatSync(cursor, { bigint: true });
  if (!before.isFile() || before.nlink !== 1n
      || before.size > BigInt(MAX_CONTRACT_FILE_BYTES)) {
    throw new ProfileContractError(`${label} must be a bounded singly linked regular file`);
  }
  const source = fs.readFileSync(cursor);
  const after = fs.lstatSync(cursor, { bigint: true });
  if (after.dev !== before.dev
      || after.ino !== before.ino
      || after.size !== before.size
      || after.mtimeMs !== before.mtimeMs) {
    throw new ProfileContractError(`${label} changed while it was being read`);
  }
  return source;
}

function parseJson(source, label) {
  try {
    return JSON.parse(source.toString('utf8'));
  } catch (error) {
    throw new ProfileContractError(`${label} is invalid JSON: ${error.message}`);
  }
}

function sha256(source) {
  return crypto.createHash('sha256').update(source).digest('hex');
}

function loadProfileContract(rootInput = path.resolve(__dirname, '..')) {
  const root = fs.realpathSync.native(path.resolve(rootInput));
  if (!fs.statSync(root).isDirectory()) {
    throw new ProfileContractError('contract root must be a directory');
  }
  const manifestSource = readBoundedFile(root, MANIFEST_PATH, 'profile manifest');
  const catalogSource = readBoundedFile(root, CATALOG_PATH, 'command catalog');
  const manifest = parseJson(manifestSource, 'profile manifest');
  const catalog = parseJson(catalogSource, 'command catalog');
  if (!manifest || manifest.schemaVersion !== 1
      || !manifest.profiles || typeof manifest.profiles !== 'object'
      || Array.isArray(manifest.profiles)
      || !catalog || catalog.schemaVersion !== 1 || !Array.isArray(catalog.commands)) {
    throw new ProfileContractError('Windows profile contract schema is invalid');
  }

  const referencedPaths = new Set(RUNTIME_PATHS);
  const profiles = {};
  const suiteIds = new Set();
  for (const [profileId, profile] of Object.entries(manifest.profiles)) {
    if (!profile || typeof profile !== 'object' || Array.isArray(profile)
        || !Number.isInteger(profile.profileTimeoutMs)
        || !Array.isArray(profile.suites) || profile.suites.length === 0) {
      throw new ProfileContractError(`profile ${profileId} contract is invalid`);
    }
    profiles[profileId] = {
      profileTimeoutMs: profile.profileTimeoutMs,
      suites: profile.suites.map((suite, index) => {
        const label = `profile ${profileId} suite ${index + 1}`;
        if (!suite || typeof suite !== 'object' || Array.isArray(suite)
            || typeof suite.id !== 'string' || suiteIds.has(suite.id)
            || typeof suite.path !== 'string' || !Array.isArray(suite.args)
            || suite.args.some((argument) => typeof argument !== 'string')) {
          throw new ProfileContractError(`${label} contract is invalid`);
        }
        suiteIds.add(suite.id);
        validateRelativePath(suite.path, label);
        referencedPaths.add(suite.path);
        return {
          id: suite.id,
          path: suite.path,
          args: [...suite.args],
        };
      }),
    };
  }

  const files = [...referencedPaths].sort().map((relative) => {
    const source = relative === MANIFEST_PATH
      ? manifestSource
      : relative === CATALOG_PATH
        ? catalogSource
        : readBoundedFile(root, relative, `contract file ${relative}`);
    return { path: relative, sha256: sha256(source) };
  });
  const fileHashes = new Map(files.map((entry) => [entry.path, entry.sha256]));
  for (const profile of Object.values(profiles)) {
    for (const suite of profile.suites) {
      suite.executedSha256 = fileHashes.get(suite.path);
      Object.freeze(suite.args);
      Object.freeze(suite);
    }
    Object.freeze(profile.suites);
    Object.freeze(profile);
  }

  return Object.freeze({
    schemaVersion: 1,
    manifestSha256: sha256(manifestSource),
    commandCatalogSha256: sha256(catalogSource),
    profileContractSha256: sha256(Buffer.from(JSON.stringify({
      schemaVersion: 1,
      files,
    }))),
    profiles: Object.freeze(profiles),
    files: Object.freeze(files.map((entry) => Object.freeze(entry))),
  });
}

module.exports = {
  ProfileContractError,
  RUNTIME_PATHS,
  loadProfileContract,
};
