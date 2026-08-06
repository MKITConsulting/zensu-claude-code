'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const {
  ProfileContractError,
  RUNTIME_PATHS,
  loadProfileContract,
} = require('../windows-profile-contract.js');

const repositoryRoot = path.resolve(__dirname, '..', '..');
const current = loadProfileContract(repositoryRoot);

function copyContractRoot() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-profile-contract-'));
  for (const { path: relative } of current.files) {
    const destination = path.join(root, relative);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(path.join(repositoryRoot, relative), destination);
  }
  return root;
}

function mutateJson(root, relative, mutate) {
  const file = path.join(root, relative);
  const value = JSON.parse(fs.readFileSync(file, 'utf8'));
  mutate(value);
  fs.writeFileSync(file, `${JSON.stringify(value)}\n`);
}

test('complete profile contract binds every runtime and referenced suite byte', () => {
  assert.equal(current.schemaVersion, 1);
  assert.match(current.profileContractSha256, /^[a-f0-9]{64}$/);
  assert.ok(RUNTIME_PATHS.every(
    (relative) => current.files.some((entry) => entry.path === relative),
  ));
  assert.equal(
    Object.values(current.profiles).reduce((sum, profile) => sum + profile.suites.length, 0),
    40,
  );
  const root = copyContractRoot();
  try {
    const before = loadProfileContract(root);
    const suite = before.profiles['windows-reset-session'].suites[0];
    fs.appendFileSync(path.join(root, suite.path), '\n# contract drift\n');
    const after = loadProfileContract(root);
    assert.notEqual(after.profileContractSha256, before.profileContractSha256);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('profile contract fails closed on malformed schema, profiles, suites, and paths', () => {
  const mutations = [
    (root) => fs.writeFileSync(
      path.join(root, 'tests/profiles/windows-ci.v1.json'),
      '{',
    ),
    (root) => mutateJson(root, 'tests/profiles/windows-ci.v1.json', (manifest) => {
      manifest.schemaVersion = 2;
    }),
    (root) => mutateJson(root, 'tests/profiles/windows-ci.v1.json', (manifest) => {
      manifest.profiles['windows-reset-session'].suites = [];
    }),
    (root) => mutateJson(root, 'tests/profiles/windows-ci.v1.json', (manifest) => {
      manifest.profiles['windows-reset-session'].suites[0].args = [null];
    }),
    (root) => mutateJson(root, 'tests/profiles/windows-ci.v1.json', (manifest) => {
      manifest.profiles['windows-reset-session'].suites[0].path = '../escape.sh';
    }),
  ];
  for (const mutate of mutations) {
    const root = copyContractRoot();
    try {
      mutate(root);
      assert.throws(() => loadProfileContract(root), ProfileContractError);
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  }
});

test('profile contract rejects symlink and hardlink substitutions', () => {
  for (const linkType of ['symlink', 'hardlink']) {
    const root = copyContractRoot();
    try {
      const relative = current.profiles['windows-reset-session'].suites[0].path;
      const target = path.join(root, relative);
      const replacement = path.join(root, 'replacement.sh');
      fs.writeFileSync(replacement, '#!/bin/bash\nexit 0\n');
      fs.unlinkSync(target);
      if (linkType === 'symlink') fs.symlinkSync(replacement, target);
      else fs.linkSync(replacement, target);
      assert.throws(() => loadProfileContract(root), ProfileContractError);
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  }
});

test('profile contract root must be a directory', () => {
  const file = path.join(os.tmpdir(), `zensu-profile-contract-file-${process.pid}`);
  fs.writeFileSync(file, 'not a directory');
  try {
    assert.throws(() => loadProfileContract(file), /root must be a directory/);
  } finally {
    fs.unlinkSync(file);
  }
});
