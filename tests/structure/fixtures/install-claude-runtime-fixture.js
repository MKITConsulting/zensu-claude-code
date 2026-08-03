#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

class InstallerFailure extends Error {
  constructor(message) {
    super(message);
    this.name = 'InstallerFailure';
  }
}

function fail(message) {
  throw new InstallerFailure(message);
}

function normalized(input) {
  const value = path.normalize(input);
  return process.platform === 'win32' ? value.toLowerCase() : value;
}

function sameIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino;
}

function pathExists(target) {
  try {
    fs.lstatSync(target);
    return true;
  } catch (error) {
    if (error?.code === 'ENOENT' || error?.code === 'ENOTDIR') return false;
    throw error;
  }
}

function captureDirectoryIdentity(target, label, expectedCanonical = null) {
  const absolute = path.resolve(target);
  const before = fs.lstatSync(absolute, { bigint: true });
  if (!before.isDirectory() || before.isSymbolicLink()) {
    fail(`${label} is not a real directory`);
  }
  const canonical = fs.realpathSync.native(absolute);
  const after = fs.lstatSync(absolute, { bigint: true });
  if (!after.isDirectory() || after.isSymbolicLink() || !sameIdentity(before, after)) {
    fail(`${label} identity changed during verification`);
  }
  if (expectedCanonical !== null && normalized(canonical) !== normalized(expectedCanonical)) {
    fail(`${label} canonical path changed during verification`);
  }
  return {
    canonical,
    dev: after.dev,
    ino: after.ino,
    path: absolute,
  };
}

function revalidateDirectoryIdentity(identity, label) {
  const current = captureDirectoryIdentity(identity.path, label, identity.canonical);
  if (!sameIdentity(current, identity)) {
    fail(`${label} identity changed`);
  }
  return current;
}

function uniqueSibling(parentIdentity, prefix) {
  for (let attempt = 0; attempt < 8; attempt += 1) {
    const name = `${prefix}${crypto.randomBytes(24).toString('hex')}`;
    const candidate = path.join(parentIdentity.canonical, name);
    if (!pathExists(candidate)) return candidate;
  }
  fail('could not allocate an unpredictable sibling path');
}

function createDirectoryAt(target, parentIdentity, label) {
  revalidateDirectoryIdentity(parentIdentity, 'cache parent');
  try {
    fs.mkdirSync(target, { mode: 0o700 });
  } catch (error) {
    if (error?.code === 'EEXIST') {
      fail(`${label} must not exist`);
    }
    throw error;
  }
  // Capture the new root before any injectable hook can observe its path. The
  // directory is already the final runtime root; it is never published through
  // a predictable destination or a rename.
  return captureDirectoryIdentity(target, label, target);
}

function createUniqueChildDirectory(parentIdentity, prefix, label) {
  for (let attempt = 0; attempt < 8; attempt += 1) {
    const candidate = uniqueSibling(parentIdentity, prefix);
    try {
      return createDirectoryAt(candidate, parentIdentity, label);
    } catch (error) {
      if (error instanceof InstallerFailure && error.message === `${label} must not exist`) {
        continue;
      }
      throw error;
    }
  }
  fail('could not create an unpredictable sibling directory');
}

function cleanupCreatedDirectory(identity, parentIdentity, label, hooks) {
  revalidateDirectoryIdentity(parentIdentity, 'cache parent');
  const expected = revalidateDirectoryIdentity(identity, label);
  const quarantine = uniqueSibling(parentIdentity, '.zensu-runtime-quarantine-');

  if (typeof hooks.beforeQuarantineRename === 'function') {
    hooks.beforeQuarantineRename({
      identity: expected,
      label,
      parent: parentIdentity,
      quarantine,
    });
  }

  revalidateDirectoryIdentity(parentIdentity, 'cache parent');
  fs.renameSync(expected.path, quarantine);

  const quarantined = captureDirectoryIdentity(quarantine, label, quarantine);
  revalidateDirectoryIdentity(parentIdentity, 'cache parent');
  if (!sameIdentity(quarantined, expected)) {
    fail(`refusing to remove ${label} because its identity changed during quarantine`);
  }
  if (pathExists(expected.path)) {
    fail(`refusing to remove ${label} because its original path was recreated`);
  }

  const immediatelyBeforeRemoval = revalidateDirectoryIdentity(quarantined, label);
  if (!sameIdentity(immediatelyBeforeRemoval, expected)) {
    fail(`refusing to remove ${label} because its quarantine identity changed`);
  }
  fs.rmSync(quarantine, { recursive: true, force: false });
  if (pathExists(quarantine)) fail(`${label} cleanup did not complete`);
}

function prospectiveCanonicalPath(input) {
  let cursor = path.resolve(input);
  const missing = [];
  while (!pathExists(cursor)) {
    const parent = path.dirname(cursor);
    if (parent === cursor) fail('cache parent has no existing directory ancestor');
    missing.unshift(path.basename(cursor));
    cursor = parent;
  }
  const stat = fs.lstatSync(cursor);
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    fail('cache parent ancestor must be a real directory');
  }
  return path.resolve(fs.realpathSync.native(cursor), ...missing);
}

function isInside(parentInput, childInput) {
  const parent = normalized(parentInput);
  const child = normalized(childInput);
  const relative = path.relative(parent, child);
  return relative === '' || (relative !== '..' && !relative.startsWith(`..${path.sep}`)
    && !path.isAbsolute(relative));
}

function gitEnvironment() {
  return {
    PATH: process.env.PATH || '',
    HOME: process.env.HOME || '',
    TMPDIR: process.env.TMPDIR || '',
    TEMP: process.env.TEMP || '',
    TMP: process.env.TMP || '',
    LANG: 'C',
    LC_ALL: 'C',
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_CONFIG_GLOBAL: process.platform === 'win32' ? 'NUL' : '/dev/null',
    GIT_NO_REPLACE_OBJECTS: '1',
    GIT_TERMINAL_PROMPT: '0',
  };
}

function install(argv, hooks = {}) {
  const [sourceInput, cacheParentInput, version, revision] = argv;
  if (!sourceInput || !cacheParentInput || !/^\d+\.\d+\.\d+$/.test(version || '')
      || !/^[a-f0-9]{40,64}$/.test(revision || '')) {
    fail('usage: install-claude-runtime-fixture.js SOURCE CACHE_PARENT VERSION REVISION');
  }

  const source = fs.realpathSync.native(sourceInput);
  const plannedCacheParent = prospectiveCanonicalPath(cacheParentInput);
  if (isInside(source, plannedCacheParent)) {
    fail('cache parent must be outside the source checkout');
  }

  fs.mkdirSync(plannedCacheParent, { recursive: true, mode: 0o700 });
  const parentIdentity = captureDirectoryIdentity(
    plannedCacheParent,
    'cache parent',
    plannedCacheParent,
  );
  if (normalized(parentIdentity.canonical) !== normalized(plannedCacheParent)) {
    fail('planned cache parent canonical path changed while creating it');
  }
  revalidateDirectoryIdentity(parentIdentity, 'cache parent');

  const entries = [
    '.claude-plugin',
    '.mcp.json',
    'hooks',
    'agents',
    'skills',
    'docs',
    'templates',
    'scripts',
    'mcp-runtime/package.json',
    'mcp-runtime/package-lock.json',
    'README.md',
    'CHANGELOG.md',
    'LICENSE',
  ];

  function git(args, encoding = 'utf8', maxBuffer = 16 * 1024 * 1024) {
    const result = spawnSync('git', ['-C', source, ...args], {
      encoding,
      env: gitEnvironment(),
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 60000,
      killSignal: 'SIGKILL',
      maxBuffer,
    });
    if (result.error || result.signal || result.status !== 0) {
      fail(`Git ${args[0]} failed or exceeded its bound`);
    }
    return result.stdout;
  }

  const resolvedRevision = String(git(['rev-parse', '--verify', `${revision}^{commit}`])).trim();
  if (resolvedRevision !== revision) fail('requested Git revision is unavailable');

  const rawTree = git([
    'ls-tree', '-rz', '--full-tree', revision, '--', ...entries,
  ]);
  const treeEntries = [];
  const seen = new Set();
  let totalBytes = 0;
  for (const raw of rawTree.split('\0')) {
    if (!raw) continue;
    const match = raw.match(/^([0-9]{6}) ([a-z]+) ([a-f0-9]{40,64})\t(.+)$/);
    if (!match) fail('Git tree entry is malformed');
    const [, mode, type, objectId, relative] = match;
    if (mode === '120000') fail('tracked symlink is forbidden in runtime fixture');
    if (type !== 'blob' || (mode !== '100644' && mode !== '100755')) {
      fail('runtime fixture supports only regular Git blobs');
    }
    if (!/^[A-Za-z0-9._/-]+$/.test(relative)
        || relative.startsWith('/') || relative.endsWith('/')
        || relative.split('/').some((part) => !part || part === '.' || part === '..')
        || !entries.some((entry) => relative === entry || relative.startsWith(`${entry}/`))
        || seen.has(relative)) {
      fail('Git tree path is unsafe or duplicated');
    }
    seen.add(relative);
    treeEntries.push({
      mode,
      objectId,
      relative,
    });
  }

  for (const required of [
    '.claude-plugin/plugin.json',
    '.claude-plugin/marketplace.json',
  ]) {
    if (!seen.has(required)) fail(`required tracked runtime file is missing: ${required}`);
  }

  function replaceRegularJson(file, value) {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink()) fail('mutable fixture manifest is not a regular file');
    const temporary = `${file}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.tmp`;
    let descriptor;
    try {
      descriptor = fs.openSync(temporary, 'wx', 0o600);
      fs.writeFileSync(descriptor, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
      fs.fsyncSync(descriptor);
    } finally {
      if (descriptor !== undefined) fs.closeSync(descriptor);
    }
    fs.renameSync(temporary, file);
  }

  let runtime = null;
  let runtimeIdentity = null;
  try {
    runtimeIdentity = createUniqueChildDirectory(
      parentIdentity,
      `.zensu-runtime-v${version}-`,
      'runtime directory',
    );
    runtime = runtimeIdentity.path;
    if (typeof hooks.afterFinalRootCreated === 'function') {
      hooks.afterFinalRootCreated({
        parent: parentIdentity,
        runtime: runtimeIdentity,
      });
    }

    for (const entry of treeEntries) {
      const content = git(
        ['cat-file', 'blob', entry.objectId],
        null,
        9 * 1024 * 1024,
      );
      totalBytes += content.length;
      if (content.length > 8 * 1024 * 1024 || totalBytes > 96 * 1024 * 1024
          || treeEntries.length > 12000) {
        fail('runtime fixture exceeds its bounded surface');
      }
      revalidateDirectoryIdentity(parentIdentity, 'cache parent');
      revalidateDirectoryIdentity(runtimeIdentity, 'runtime directory');
      const target = path.resolve(runtime, ...entry.relative.split('/'));
      if (!isInside(runtime, target)) fail('runtime fixture path escaped its final directory');
      fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
      fs.writeFileSync(target, content, {
        flag: 'wx',
        mode: entry.mode === '100755' ? 0o700 : 0o600,
      });
    }

    const manifestFile = path.join(runtime, '.claude-plugin', 'plugin.json');
    const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
    if (manifest.version !== version) {
      manifest.version = version;
      replaceRegularJson(manifestFile, manifest);
    }
    const marketplaceFile = path.join(runtime, '.claude-plugin', 'marketplace.json');
    const marketplace = JSON.parse(fs.readFileSync(marketplaceFile, 'utf8'));
    if (!Array.isArray(marketplace.plugins) || marketplace.plugins.length !== 1
        || marketplace.plugins[0]?.name !== manifest.name) {
      fail('marketplace fixture does not contain the exact plugin entry');
    }
    marketplace.plugins[0].version = version;
    if (marketplace.plugins[0].source?.source === 'github') {
      marketplace.plugins[0].source.ref = `v${version}`;
    }
    replaceRegularJson(marketplaceFile, marketplace);

    if (typeof hooks.beforeFinalRootReady === 'function') {
      hooks.beforeFinalRootReady({
        parent: parentIdentity,
        runtime: runtimeIdentity,
      });
    }
    const ready = revalidateDirectoryIdentity(runtimeIdentity, 'runtime directory');
    revalidateDirectoryIdentity(parentIdentity, 'cache parent');
    if (typeof hooks.afterFinalRootReady === 'function') {
      hooks.afterFinalRootReady({
        parent: parentIdentity,
        runtime: ready,
      });
    }
    revalidateDirectoryIdentity(parentIdentity, 'cache parent');
    revalidateDirectoryIdentity(runtimeIdentity, 'runtime directory');
    return ready.canonical;
  } catch (error) {
    const cleanupErrors = [];
    if (runtime !== null) {
      try {
        cleanupCreatedDirectory(
          runtimeIdentity,
          parentIdentity,
          'runtime directory',
          hooks,
        );
      } catch (cleanupError) {
        cleanupErrors.push(cleanupError);
      }
    }
    if (cleanupErrors.length > 0) {
      fail('installer cleanup could not prove ownership');
    }
    throw error;
  }
}

module.exports = {
  InstallerFailure,
  install,
};

if (require.main === module) {
  try {
    process.stdout.write(`${install(process.argv.slice(2))}\n`);
  } catch (error) {
    const message = error instanceof InstallerFailure
      ? error.message
      : 'unexpected installer failure';
    process.stderr.write(`install-claude-runtime-fixture: ${message}\n`);
    process.exitCode = 1;
  }
}
