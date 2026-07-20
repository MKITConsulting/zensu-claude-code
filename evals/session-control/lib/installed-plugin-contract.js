#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const core = require('../../../hooks/lib/session-control-core-v1.js');

const PLUGIN_ID = 'zensu@zensu';
const CLI_VERSION = '2.1.211';
const SCHEMA = 'zensu.claude-installed-plugin';
const KEYS = [
  'schema',
  'schema_version',
  'plugin_id',
  'scope',
  'source_root',
  'installed_plugin_root',
  'isolated_home',
  'source_git_revision',
  'runtime_digest',
  'plugin_version',
  'cli_version',
  'registry',
];

function fail(message) {
  throw new Error(`installed plugin contract: ${message}`);
}

function readJson(fileInput, label) {
  let file;
  try { file = fs.realpathSync(fileInput); }
  catch (_error) { fail(`${label} is unavailable`); }
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 4 * 1024 * 1024) {
    fail(`${label} is not a safe JSON file`);
  }
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (_error) { fail(`${label} is invalid JSON`); }
}

function realDirectory(input, label) {
  if (typeof input !== 'string' || !input) fail(`${label} is missing`);
  let stat;
  try { stat = fs.lstatSync(input); }
  catch (_error) { fail(`${label} is unavailable`); }
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail(`${label} must be a real directory`);
  return fs.realpathSync.native(input);
}

function inside(parent, child) {
  const relative = path.relative(parent, child);
  return relative !== '' && relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function requireRevision(value) {
  if (typeof value !== 'string' || !/^[0-9a-f]{40,64}$/.test(value)) {
    fail('expected source revision must be an exact lowercase Git object id');
  }
  return value;
}

function gitHead(sourceRoot) {
  const result = spawnSync('git', ['-C', sourceRoot, 'rev-parse', 'HEAD'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (result.status !== 0) fail('source root has no Git HEAD');
  return result.stdout.trim();
}

function pluginManifest(root, label) {
  const manifest = readJson(path.join(root, '.claude-plugin', 'plugin.json'), `${label} manifest`);
  if (manifest.name !== 'zensu' || typeof manifest.version !== 'string' || !manifest.version) {
    fail(`${label} manifest does not identify a versioned zensu plugin`);
  }
  return manifest;
}

function registryEntry(home, installedRoot, expectedRevision) {
  const registryFile = path.join(home, '.claude', 'plugins', 'installed_plugins.json');
  const registry = readJson(registryFile, 'Claude installed-plugin registry');
  const entries = registry?.plugins?.[PLUGIN_ID];
  if (!Array.isArray(entries) || entries.length !== 1) {
    fail('Claude installed-plugin registry does not contain exactly one zensu@zensu entry');
  }
  const entry = entries[0];
  if (entry?.scope !== 'user' || typeof entry.installPath !== 'string') {
    fail('Claude installed-plugin registry entry has the wrong scope or path');
  }
  const registryRoot = realDirectory(entry.installPath, 'registry installPath');
  if (registryRoot !== installedRoot) fail('Claude registry installPath does not match plugin list');
  if (entry.gitCommitSha !== expectedRevision) fail('installed plugin registry SHA does not match the exact source revision');
  return entry;
}

function settingsEntry(home) {
  const settings = readJson(path.join(home, '.claude', 'settings.json'), 'isolated Claude settings');
  const enabled = settings?.enabledPlugins;
  if (!enabled || typeof enabled !== 'object' || Array.isArray(enabled)
      || Object.keys(enabled).length !== 1 || enabled[PLUGIN_ID] !== true) {
    fail('isolated Claude settings do not enable exactly zensu@zensu');
  }
}

function runtimeEvidence(sourceRoot, installedRoot) {
  const sourceDigest = core.computeRuntimeDigest(sourceRoot, 'claude');
  const installedDigest = core.computeRuntimeDigest(installedRoot, 'claude');
  if (!/^sha256:[0-9a-f]{64}$/.test(sourceDigest)
      || !/^sha256:[0-9a-f]{64}$/.test(installedDigest)) {
    fail('runtime digest is malformed');
  }
  if (sourceDigest !== installedDigest) fail('installed runtime is not byte-identical to source runtime');
  return sourceDigest;
}

function commonEvidence(sourceInput, installedInput, homeInput, revisionInput, cliVersion) {
  const sourceRoot = realDirectory(sourceInput, 'source root');
  const installedRoot = realDirectory(installedInput, 'installed plugin root');
  const home = realDirectory(homeInput, 'isolated HOME');
  const revision = requireRevision(revisionInput);
  if (cliVersion !== CLI_VERSION) fail(`Claude CLI must be exactly ${CLI_VERSION}`);
  if (gitHead(sourceRoot) !== revision) fail('source checkout HEAD does not match the exact expected revision');
  if (sourceRoot === installedRoot) fail('installed plugin root must be separate from the source checkout');

  const cacheRoot = path.join(home, '.claude', 'plugins', 'cache', 'zensu', 'zensu');
  if (!inside(cacheRoot, installedRoot)) fail('installed plugin root is outside the isolated Claude cache');

  const sourceManifest = pluginManifest(sourceRoot, 'source');
  const installedManifest = pluginManifest(installedRoot, 'installed');
  if (sourceManifest.version !== installedManifest.version) fail('source and installed plugin versions differ');
  registryEntry(home, installedRoot, revision);
  settingsEntry(home);
  const runtimeDigest = runtimeEvidence(sourceRoot, installedRoot);
  return { sourceRoot, installedRoot, home, revision, runtimeDigest, pluginVersion: sourceManifest.version };
}

function resolve(listFile, sourceInput, homeInput, revisionInput, cliVersion) {
  const list = readJson(listFile, 'Claude plugin list output');
  if (!Array.isArray(list)) fail('Claude plugin list output must be an array');
  const matches = list.filter((entry) => entry?.id === PLUGIN_ID);
  if (matches.length !== 1) fail('Claude plugin list must contain exactly one zensu@zensu entry');
  const selected = matches[0];
  if (selected.scope !== 'user' || selected.enabled !== true || typeof selected.installPath !== 'string') {
    fail('Claude plugin list entry must be enabled at user scope with an installPath');
  }
  const installedRoot = realDirectory(selected.installPath, 'plugin list installPath');
  const evidence = commonEvidence(sourceInput, installedRoot, homeInput, revisionInput, cliVersion);
  if (selected.version !== evidence.pluginVersion) fail('Claude plugin list version differs from the installed manifest');
  return {
    schema: SCHEMA,
    schema_version: 1,
    plugin_id: PLUGIN_ID,
    scope: 'user',
    source_root: evidence.sourceRoot,
    installed_plugin_root: evidence.installedRoot,
    isolated_home: evidence.home,
    source_git_revision: evidence.revision,
    runtime_digest: evidence.runtimeDigest,
    plugin_version: evidence.pluginVersion,
    cli_version: CLI_VERSION,
    registry: 'claude-plugin-cli',
  };
}

function verify(manifestFile, sourceInput, installedInput, homeInput, revisionInput, cliVersion) {
  const manifest = readJson(manifestFile, 'installation manifest');
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)
      || JSON.stringify(Object.keys(manifest).sort()) !== JSON.stringify([...KEYS].sort())) {
    fail('installation manifest has an unexpected shape');
  }
  if (manifest.schema !== SCHEMA || manifest.schema_version !== 1
      || manifest.plugin_id !== PLUGIN_ID || manifest.scope !== 'user'
      || manifest.registry !== 'claude-plugin-cli') {
    fail('installation manifest identity is invalid');
  }
  const evidence = commonEvidence(sourceInput, installedInput, homeInput, revisionInput, cliVersion);
  const expected = {
    source_root: evidence.sourceRoot,
    installed_plugin_root: evidence.installedRoot,
    isolated_home: evidence.home,
    source_git_revision: evidence.revision,
    runtime_digest: evidence.runtimeDigest,
    plugin_version: evidence.pluginVersion,
    cli_version: CLI_VERSION,
  };
  for (const [key, value] of Object.entries(expected)) {
    if (manifest[key] !== value) fail(`installation manifest ${key} does not match current evidence`);
  }
  return manifest;
}

function main() {
  const [command, ...args] = process.argv.slice(2);
  let output;
  if (command === 'resolve' && args.length === 5) output = resolve(...args);
  else if (command === 'verify' && args.length === 6) output = verify(...args);
  else fail('usage: installed-plugin-contract.js resolve LIST SOURCE HOME REVISION CLI_VERSION | verify MANIFEST SOURCE INSTALLED HOME REVISION CLI_VERSION');
  process.stdout.write(`${JSON.stringify(output)}\n`);
}

try { main(); }
catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
}
