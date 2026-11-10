'use strict';

const fs = require('node:fs');

const VERSION_RE = /^[0-9]+\.[0-9]+\.[0-9]+$/;
const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const REF_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

class BumpRefusal extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'BumpRefusal';
    this.code = code;
  }
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function canonicalText(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

function namedEntry(marketplace, name) {
  if (typeof name !== 'string' || !NAME_RE.test(name)) {
    throw new BumpRefusal('bad-name', `plugin name is not a plain name: ${JSON.stringify(name)}`);
  }
  if (!isObject(marketplace) || !Array.isArray(marketplace.plugins)) {
    throw new BumpRefusal('no-plugins', 'the marketplace has no plugins array');
  }
  const matches = marketplace.plugins.filter((entry) => isObject(entry) && entry.name === name);
  if (matches.length !== 1) {
    throw new BumpRefusal(
      'entry-count',
      `the marketplace holds ${matches.length} entries named ${name}, not exactly one`,
    );
  }
  return matches[0];
}

function bumpMarketplaceEntry(marketplace, { name, version, ref = null } = {}) {
  if (typeof version !== 'string' || !VERSION_RE.test(version)) {
    throw new BumpRefusal('bad-version', `version is not MAJOR.MINOR.PATCH: ${JSON.stringify(version)}`);
  }
  if (ref !== null && (typeof ref !== 'string' || !REF_RE.test(ref))) {
    throw new BumpRefusal('bad-ref', `ref is not a plain tag name: ${JSON.stringify(ref)}`);
  }
  const next = structuredClone(marketplace);
  const entry = namedEntry(next, name);
  if (typeof entry.version !== 'string') {
    throw new BumpRefusal('no-version', `the entry named ${name} carries no version string`);
  }
  if (ref !== null) {
    if (!isObject(entry.source) || typeof entry.source.ref !== 'string') {
      throw new BumpRefusal('no-source-ref', `the entry named ${name} has no source object carrying a ref`);
    }
    entry.source.ref = ref;
  }
  entry.version = version;
  return next;
}

function bumpMarketplaceFile(file, options) {
  const stat = fs.lstatSync(file);
  if (!stat.isFile()) {
    throw new BumpRefusal('not-regular', `${file} is not a regular file`);
  }
  const text = fs.readFileSync(file, 'utf8');
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new BumpRefusal('not-json', `${file} is not valid JSON`);
  }
  if (canonicalText(parsed) !== text) {
    throw new BumpRefusal(
      'not-canonical',
      `${file} is not in canonical form (two-space JSON.stringify output and one trailing newline)`,
    );
  }
  const output = canonicalText(bumpMarketplaceEntry(parsed, options));
  fs.writeFileSync(file, output);
  return output;
}

function main(argv) {
  if (argv.length !== 4) {
    process.stderr.write('usage: bump-marketplace-entry.js MARKETPLACE_JSON PLUGIN_NAME VERSION REF\n');
    return 2;
  }
  const [file, name, version, ref] = argv;
  try {
    bumpMarketplaceFile(file, { name, version, ref });
  } catch (error) {
    if (error instanceof BumpRefusal) {
      process.stderr.write(`bump-marketplace-entry: refused (${error.code}): ${error.message}\n`);
      return 1;
    }
    const message = error && error.message ? error.message : String(error);
    process.stderr.write(`bump-marketplace-entry: ${message}\n`);
    return 1;
  }
  return 0;
}

module.exports = {
  BumpRefusal,
  canonicalText,
  namedEntry,
  bumpMarketplaceEntry,
  bumpMarketplaceFile,
  main,
};

if (require.main === module) {
  process.exitCode = main(process.argv.slice(2));
}
