'use strict';

const fs = require('node:fs');
const path = require('node:path');

const MODES = new Set(['regular', 'regular-or-absent', 'directory', 'directory-or-absent']);

function within(base, candidate) {
  const rel = path.relative(base, candidate);
  return rel === '' || (rel !== '..' && !rel.startsWith(`..${path.sep}`) && !path.isAbsolute(rel));
}

function regularMode(mode) {
  return mode === 'regular' || mode === 'regular-or-absent';
}

function literalLeafSafe(target, mode) {
  let link = null;
  try { link = fs.lstatSync(target); } catch (_) { link = null; }
  if (link && link.isSymbolicLink()) return false;
  let followed = null;
  try { followed = fs.statSync(target); } catch (_) { followed = null; }
  if (!followed) return true;
  return regularMode(mode) ? followed.isFile() : followed.isDirectory();
}

function anchorFor(trusted, target) {
  const candidates = trusted.filter((value) => within(value, target)).sort((a, b) => b.length - a.length);
  if (candidates[0]) return candidates[0];
  let cursor = path.dirname(target);
  for (;;) {
    try {
      const st = fs.lstatSync(cursor);
      if (st.isDirectory() && !st.isSymbolicLink()) return cursor;
    } catch (error) {
      if (error.code !== 'ENOENT') return '';
    }
    const parent = path.dirname(cursor);
    if (parent === cursor) return '';
    cursor = parent;
  }
}

function pathSafe(trusted, input, mode) {
  if (typeof input !== 'string' || input === '' || !MODES.has(mode)) return false;
  if (!literalLeafSafe(input, mode)) return false;
  const target = path.resolve(input);
  const anchor = anchorFor(trusted, target);
  if (!anchor) return false;
  let physicalAnchor;
  try { physicalAnchor = fs.realpathSync(anchor); } catch (_) { return false; }
  const rel = path.relative(anchor, target);
  if (rel === '..' || rel.startsWith(`..${path.sep}`) || path.isAbsolute(rel)) return false;
  const parts = rel ? rel.split(path.sep).filter(Boolean) : [];
  let current = physicalAnchor;
  let missing = false;
  for (let i = 0; i < parts.length; i += 1) {
    current = path.join(current, parts[i]);
    const leaf = i === parts.length - 1;
    if (missing) continue;
    let st;
    try { st = fs.lstatSync(current); } catch (error) {
      if (error.code !== 'ENOENT') return false;
      missing = true;
      continue;
    }
    if (st.isSymbolicLink()) return false;
    if (!leaf && !st.isDirectory()) return false;
    if (leaf) {
      if (regularMode(mode) && (!st.isFile() || st.nlink !== 1)) return false;
      if (!regularMode(mode) && !st.isDirectory()) return false;
    }
  }
  return !(missing && (mode === 'regular' || mode === 'directory'));
}

function pathsSafe(roots, pairs) {
  if (!Array.isArray(roots) || roots.length !== 3) return false;
  if (!Array.isArray(pairs) || pairs.length === 0 || pairs.length % 2 !== 0) return false;
  try {
    const trusted = roots.filter(Boolean).map((value) => path.resolve(value));
    for (let pair = 0; pair < pairs.length; pair += 2) {
      if (!pathSafe(trusted, pairs[pair], pairs[pair + 1])) return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

function pathsSafeArgv(argv) {
  if (!Array.isArray(argv)) return false;
  return pathsSafe(argv.slice(0, 3), argv.slice(3));
}

module.exports = { pathsSafe, pathsSafeArgv };
