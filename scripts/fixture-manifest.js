#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const EXCLUDED_PATHS = Object.freeze([
  '.git',
  '.verify-runtime',
  '.verify-feature-runtime',
  '.zensu/hook-events.log',
  '.zensu/logs',
  '.zensu/state',
  '.zensu/verify-feature-runs',
]);

function excluded(relativePath) {
  return EXCLUDED_PATHS.some((entry) => relativePath === entry || relativePath.startsWith(`${entry}/`));
}

function record(root, relativePath) {
  const absolute = path.join(root, relativePath);
  const info = fs.lstatSync(absolute);
  const mode = info.mode & 0o777;
  if (info.isSymbolicLink()) {
    return { path: relativePath, type: 'symlink', mode, target: fs.readlinkSync(absolute) };
  }
  if (info.isFile()) {
    return {
      path: relativePath,
      type: 'file',
      mode,
      size: info.size,
      sha256: crypto.createHash('sha256').update(fs.readFileSync(absolute)).digest('hex'),
    };
  }
  if (info.isDirectory()) return { path: relativePath, type: 'directory', mode };
  throw new Error(`unsupported fixture entry type: ${relativePath}`);
}

function snapshot(root) {
  const physicalRoot = fs.realpathSync(root);
  const records = [];
  const visit = (relativeDirectory) => {
    const absoluteDirectory = relativeDirectory ? path.join(physicalRoot, relativeDirectory) : physicalRoot;
    for (const name of fs.readdirSync(absoluteDirectory).sort()) {
      const relativePath = relativeDirectory ? `${relativeDirectory}/${name}` : name;
      if (excluded(relativePath)) continue;
      const entry = record(physicalRoot, relativePath);
      records.push(entry);
      if (entry.type === 'directory') visit(relativePath);
    }
  };
  visit('');
  return records;
}

function assertNoSymlinks(root) {
  const physicalRoot = fs.realpathSync(root);
  const visit = (absoluteDirectory) => {
    for (const entry of fs.readdirSync(absoluteDirectory, { withFileTypes: true })) {
      const absolute = path.join(absoluteDirectory, entry.name);
      const info = fs.lstatSync(absolute);
      if (info.isSymbolicLink()) throw new Error(`symlinked fixture entry is forbidden: ${path.relative(physicalRoot, absolute)}`);
      if (info.isDirectory()) visit(absolute);
      else if (!info.isFile()) throw new Error(`unsupported fixture entry: ${path.relative(physicalRoot, absolute)}`);
    }
  };
  visit(physicalRoot);
}

function gitControlSnapshot(root) {
  const git = path.join(root, '.git');
  if (!fs.existsSync(git) || !fs.lstatSync(git).isDirectory()) return null;
  const candidates = ['HEAD', 'packed-refs'];
  const head = fs.readFileSync(path.join(git, 'HEAD'), 'utf8').trim();
  if (head.startsWith('ref: ')) candidates.push(head.slice(5));
  const records = candidates.sort().flatMap((relativePath) => {
    const absolute = path.join(git, relativePath);
    if (!fs.existsSync(absolute)) return [];
    const info = fs.lstatSync(absolute);
    if (!info.isFile() || info.isSymbolicLink()) throw new Error(`unsafe git control entry: ${relativePath}`);
    return [{
      path: `.git/${relativePath}`,
      size: info.size,
      sha256: crypto.createHash('sha256').update(fs.readFileSync(absolute)).digest('hex'),
    }];
  });
  const semanticIndex = execFileSync('git', ['-C', root, 'ls-files', '-v', '--stage', '-z'], {
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' },
  });
  records.push({
    path: '.git/index-semantic',
    size: semanticIndex.length,
    sha256: crypto.createHash('sha256').update(semanticIndex).digest('hex'),
  });
  return records;
}

function digest(root) {
  return crypto.createHash('sha256').update(JSON.stringify({
    version: 1,
    records: snapshot(root),
    gitControl: gitControlSnapshot(fs.realpathSync(root)),
  })).digest('hex');
}

module.exports = { assertNoSymlinks, EXCLUDED_PATHS, digest, gitControlSnapshot, snapshot };

if (require.main === module) {
  try {
    if (process.argv[2] === '--assert-no-symlinks' && process.argv.length === 4) {
      assertNoSymlinks(process.argv[3]);
    } else if (process.argv.length === 3) {
      process.stdout.write(`${digest(process.argv[2])}\n`);
    } else {
      throw new Error('usage: fixture-manifest.js [--assert-no-symlinks] <fixture-root>');
    }
  } catch (error) {
    process.stderr.write(`fixture manifest: ${error.message}\n`);
    process.exitCode = 1;
  }
}
