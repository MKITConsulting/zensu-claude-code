#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const REPOSITORY = 'MKITConsulting/zensu-claude-code';
const REVISION_RE = /^[0-9a-f]{40,64}$/;
const VERSION_RE = /^[0-9]+\.[0-9]+\.[0-9]+$/;

function fail(message) {
  throw new Error(`local marketplace fixture: ${message}`);
}

function realDirectory(input, label) {
  if (typeof input !== 'string' || !input) fail(`${label} is missing`);
  let stat;
  try { stat = fs.lstatSync(input); }
  catch (_error) { fail(`${label} is unavailable`); }
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail(`${label} must be a real directory`);
  return fs.realpathSync(input);
}

function readJson(root, relative, label) {
  const file = path.join(root, relative);
  let stat;
  try { stat = fs.lstatSync(file); }
  catch (_error) { fail(`${label} is unavailable`); }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || stat.size > 1024 * 1024) {
    fail(`${label} is not a safe regular file`);
  }
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (_error) { fail(`${label} is invalid JSON`); }
}

function git(args, options = {}) {
  const result = spawnSync('git', args, {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    env: {
      PATH: process.env.PATH || '',
      HOME: process.env.HOME || '',
      TMPDIR: process.env.TMPDIR || '/tmp',
      LANG: 'C',
      LC_ALL: 'C',
      GIT_CONFIG_NOSYSTEM: '1',
      GIT_CONFIG_GLOBAL: '/dev/null',
      GIT_TERMINAL_PROMPT: '0',
    },
    ...options,
  });
  if (result.status !== 0) {
    const detail = (result.stderr || '').trim().split('\n').slice(-1)[0];
    fail(`git ${args[0]} failed${detail ? `: ${detail}` : ''}`);
  }
  return (result.stdout || '').trim();
}

function head(root) {
  return git(['-C', root, 'rev-parse', 'HEAD']);
}

function status(root) {
  return git(['-C', root, 'status', '--porcelain=v1', '--untracked-files=all']);
}

function validateProductionMarketplace(pluginRoot) {
  const plugin = readJson(pluginRoot, '.claude-plugin/plugin.json', 'plugin manifest');
  const marketplace = readJson(pluginRoot, '.claude-plugin/marketplace.json', 'production marketplace');
  if (plugin?.name !== 'zensu' || typeof plugin.version !== 'string'
      || !VERSION_RE.test(plugin.version)) {
    fail('plugin manifest does not identify a semantic-versioned zensu plugin');
  }
  if (!Array.isArray(marketplace?.plugins) || marketplace.plugins.length !== 1
      || marketplace.plugins[0]?.name !== 'zensu'
      || marketplace.plugins[0]?.version !== plugin.version) {
    fail('production marketplace and plugin manifest are not version-aligned');
  }
  const source = marketplace.plugins[0].source;
  if (!source || typeof source !== 'object' || Array.isArray(source)
      || source.source !== 'github' || source.repo !== REPOSITORY
      || source.ref !== `v${plugin.version}`
      || JSON.stringify(Object.keys(source).sort()) !== JSON.stringify(['ref', 'repo', 'source'])) {
    fail('production marketplace source is not pinned to its immutable release tag');
  }
  return marketplace;
}

function rejectUnsafeTrackedEntries(pluginRoot) {
  const listing = git(['-C', pluginRoot, 'ls-files', '--stage', '-z']);
  for (const entry of listing.split('\0')) {
    if (!entry) continue;
    const mode = entry.slice(0, entry.indexOf(' '));
    if (mode === '120000' || mode === '160000') {
      fail('exact checkout contains a symlink or submodule entry');
    }
  }
}

function createFixture(sourceInput, targetInput, expectedRevision) {
  const sourceRoot = realDirectory(sourceInput, 'source root');
  if (!REVISION_RE.test(expectedRevision || '')) {
    fail('expected revision must be an exact lowercase Git object id');
  }
  if (head(sourceRoot) !== expectedRevision) fail('source HEAD does not match the exact expected revision');
  if (status(sourceRoot)) fail('source checkout must be clean');

  const targetParent = realDirectory(path.dirname(path.resolve(targetInput)), 'fixture parent');
  const targetRoot = path.resolve(targetParent, path.basename(path.resolve(targetInput)));
  if (fs.existsSync(targetRoot)) fail('fixture target must not exist');

  let created = false;
  try {
    fs.mkdirSync(targetRoot, { mode: 0o700 });
    created = true;
    const pluginRoot = path.join(targetRoot, 'plugin');
    git([
      '-c', 'protocol.file.allow=always',
      '-c', 'core.hooksPath=/dev/null',
      'clone', '--no-local', '--no-hardlinks', '--no-checkout', '--', sourceRoot, pluginRoot,
    ]);
    git(['-C', pluginRoot, '-c', 'core.hooksPath=/dev/null',
      'checkout', '--detach', '--force', expectedRevision]);

    if (head(pluginRoot) !== expectedRevision || status(pluginRoot)) {
      fail('local clone is not the exact clean expected revision');
    }
    if (head(sourceRoot) !== expectedRevision || status(sourceRoot)) {
      fail('source checkout changed while creating the fixture');
    }
    rejectUnsafeTrackedEntries(pluginRoot);
    const marketplace = validateProductionMarketplace(pluginRoot);
    const localMarketplace = JSON.parse(JSON.stringify(marketplace));
    localMarketplace.plugins[0].source = './plugin';

    const metadataRoot = path.join(targetRoot, '.claude-plugin');
    fs.mkdirSync(metadataRoot, { mode: 0o700 });
    const marketplaceFile = path.join(metadataRoot, 'marketplace.json');
    fs.writeFileSync(marketplaceFile, `${JSON.stringify(localMarketplace, null, 2)}\n`, {
      encoding: 'utf8', mode: 0o600, flag: 'wx',
    });

    if (head(pluginRoot) !== expectedRevision || status(pluginRoot)) {
      fail('exact plugin clone changed while writing local marketplace metadata');
    }
    if (head(sourceRoot) !== expectedRevision || status(sourceRoot)) {
      fail('source checkout changed while finalizing the fixture');
    }
    return targetRoot;
  } catch (error) {
    if (created) fs.rmSync(targetRoot, { recursive: true, force: true });
    throw error;
  }
}

function main() {
  const [sourceRoot, targetRoot, expectedRevision] = process.argv.slice(2);
  if (!sourceRoot || !targetRoot || !expectedRevision || process.argv.length !== 5) {
    fail('usage: create-local-marketplace-fixture.js SOURCE_ROOT TARGET_ROOT EXPECTED_REVISION');
  }
  process.stdout.write(`${createFixture(sourceRoot, targetRoot, expectedRevision)}\n`);
}

try { main(); }
catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
}
