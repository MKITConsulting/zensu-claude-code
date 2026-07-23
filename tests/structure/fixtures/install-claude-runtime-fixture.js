#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');

function fail(message) {
  process.stderr.write(`install-claude-runtime-fixture: ${message}\n`);
  process.exit(1);
}

const [sourceInput, destinationInput, version] = process.argv.slice(2);
if (!sourceInput || !destinationInput || !/^\d+\.\d+\.\d+$/.test(version || '')) {
  fail('usage: install-claude-runtime-fixture.js SOURCE DESTINATION VERSION');
}

const source = fs.realpathSync.native(sourceInput);
function prospectiveRealpath(input) {
  let cursor = path.resolve(input);
  const missing = [];
  while (!fs.existsSync(cursor)) {
    const parent = path.dirname(cursor);
    if (parent === cursor) fail('destination has no existing directory ancestor');
    missing.unshift(path.basename(cursor));
    cursor = parent;
  }
  const stat = fs.lstatSync(cursor);
  if (!stat.isDirectory()) fail('destination ancestor must be a directory');
  return path.resolve(fs.realpathSync.native(cursor), ...missing);
}

function normalized(input) {
  const value = path.normalize(input);
  return process.platform === 'win32' ? value.toLowerCase() : value;
}

function isInside(parentInput, childInput) {
  const parent = normalized(parentInput);
  const child = normalized(childInput);
  const relative = path.relative(parent, child);
  return relative === '' || (relative !== '..' && !relative.startsWith(`..${path.sep}`)
    && !path.isAbsolute(relative));
}

const destination = prospectiveRealpath(destinationInput);
if (isInside(source, destination)) {
  fail('destination must be outside the source checkout');
}
if (fs.existsSync(destination)) {
  fail('destination must not exist; runtime fixtures are immutable version roots');
}
fs.mkdirSync(destination, { recursive: true, mode: 0o700 });

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
for (const relative of entries) {
  const from = path.join(source, relative);
  if (!fs.existsSync(from)) continue;
  const to = path.join(destination, relative);
  fs.mkdirSync(path.dirname(to), { recursive: true, mode: 0o700 });
  fs.cpSync(from, to, { recursive: true, force: true, errorOnExist: false });
}

const manifestFile = path.join(destination, '.claude-plugin', 'plugin.json');
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
if (manifest.version !== version) {
  manifest.version = version;
  fs.writeFileSync(manifestFile, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
}
const marketplaceFile = path.join(destination, '.claude-plugin', 'marketplace.json');
const marketplace = JSON.parse(fs.readFileSync(marketplaceFile, 'utf8'));
if (!Array.isArray(marketplace.plugins) || marketplace.plugins.length !== 1
    || marketplace.plugins[0]?.name !== manifest.name) {
  fail('marketplace fixture does not contain the exact plugin entry');
}
marketplace.plugins[0].version = version;
if (marketplace.plugins[0].source?.source === 'github') {
  marketplace.plugins[0].source.ref = `v${version}`;
}
fs.writeFileSync(marketplaceFile, `${JSON.stringify(marketplace, null, 2)}\n`, { mode: 0o600 });
process.stdout.write(`${fs.realpathSync.native(destination)}\n`);
