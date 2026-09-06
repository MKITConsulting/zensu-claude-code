#!/usr/bin/env node
// bash32-substitution-scan.js — find command substitutions that bash 3.2 truncates.
//
// macOS ships GNU bash 3.2.57 as /bin/bash, so it is the DEFAULT shell for every
// hook and helper this plugin runs there. That release extracts a `$( ... )` body
// with a naive scanner (tracks quotes and parens, does not parse), so a token it
// miscounts ends the substitution early. The commonest carrier is a `case` arm in
// the bare `pattern)` form: its `)` closes the substitution at that character, the
// body truncates mid-`case`, and the subshell dies of a syntax error.
//
// The failure is SILENT by default and that is why it needs a guard rather than a
// review habit. `bash -n` on the whole file passes — 3.2 parses a substitution body
// only when it expands it — so nothing at build time notices. At run time the
// assignment merely returns non-zero and the caller takes its else branch. The
// defect this scanner was written for shipped in 0.20.0 and cost /zensu:doctor its
// entire binding verdict: it reported `unbound` for sessions whose record was
// present, readable and already bound (see hooks/lib/zensu-doctor.sh, the comment
// above the ZDOC_SESSION_PAIR substitution).
//
// The ORACLE is exact rather than heuristic: reproduce the naive scanner, take the
// body it would hand to the parser, and ask a real bash to parse it. A body that
// bash cannot parse is a body 3.2 would have failed on. Any bash answers this the
// same way, so the check is identical on a macOS 3.2 host and a Linux 5.x runner —
// the truncated text is a syntax error under every POSIX shell.
//
// The FIX is the POSIX-optional leading paren on the case pattern — `(pattern)` —
// which balances the scanner and parses identically on bash 5.
//
// NOT covered: the sibling 3.2 trap where an apostrophe inside a comment in a
// substitution opens a quote state the scanner never closes. Measured over this
// tree, a detector for it produced five candidates and none of them was real, so
// it is left to the prose warnings at the call sites rather than shipped as a
// check that cries wolf.
//
// Usage: node bash32-substitution-scan.js <root>
// Prints `file:line<TAB>first-body-line` per finding; exit 0 with no findings,
// exit 1 with findings, exit 2 on a usage error.

'use strict';

const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const os = require('os');

const SKIP_DIRS = new Set(['.git', 'node_modules', '.zensu', 'dist', 'build']);

function shellFiles(root) {
  const out = [];
  (function walk(dir) {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (_) {
      return;
    }
    for (const e of entries) {
      if (e.isSymbolicLink()) continue;
      const p = path.join(dir, e.name);
      if (e.isDirectory()) {
        if (!SKIP_DIRS.has(e.name)) walk(p);
      } else if (e.isFile() && e.name.endsWith('.sh')) {
        out.push(p);
      }
    }
  })(root);
  return out.sort();
}

// Walk forward from just past `$(`, counting parens the way bash 3.2 does.
// Returns the index of the `)` it settles on, or -1 when it runs off the end.
function naiveClose(src, j) {
  let depth = 1;
  let sq = false;
  let dq = false;
  for (; j < src.length; j++) {
    const c = src[j];
    if (sq) {
      if (c === "'") sq = false;
      continue;
    }
    if (c === '\\') {
      j++;
      continue;
    }
    if (dq) {
      if (c === '"') dq = false;
      continue;
    }
    if (c === "'") { sq = true; continue; }
    if (c === '"') { dq = true; continue; }
    if (c === '#' && (j === 0 || /[\s;&|(]/.test(src[j - 1]))) {
      while (j < src.length && src[j] !== '\n') j++;
      continue;
    }
    if (c === '(') depth++;
    else if (c === ')') {
      depth--;
      if (depth === 0) return j;
    }
  }
  return -1;
}

// One global pass over the file. The outer quote state matters: a `$(` inside a
// single-quoted string is not a substitution, and treating it as one produced
// five false positives on this tree before the state was tracked.
function substitutions(src) {
  const found = [];
  let sq = false;
  let dq = false;
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (sq) {
      if (c === "'") sq = false;
      continue;
    }
    if (c === '\\') { i++; continue; }
    if (!dq) {
      if (c === "'") { sq = true; continue; }
      if (c === '"') { dq = true; continue; }
      if (c === '#' && (i === 0 || /[\s;&|]/.test(src[i - 1]))) {
        while (i < src.length && src[i] !== '\n') i++;
        continue;
      }
    } else if (c === '"') {
      dq = false;
      continue;
    }
    // Reached inside and outside double quotes alike; `$((` is arithmetic.
    if (c === '$' && src[i + 1] === '(' && src[i + 2] !== '(') {
      const end = naiveClose(src, i + 2);
      if (end < 0) continue;
      found.push({ at: i, body: src.slice(i + 2, end) });
      i = end;
    }
  }
  return found;
}

function parses(body, probePath) {
  fs.writeFileSync(probePath, body);
  return cp.spawnSync('bash', ['-n', probePath], { encoding: 'utf8' }).status === 0;
}

function main() {
  const root = process.argv[2];
  if (!root || !fs.existsSync(root)) {
    process.stderr.write('usage: bash32-substitution-scan.js <root>\n');
    process.exit(2);
  }
  const probeDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bash32scan-'));
  const probePath = path.join(probeDir, 'body.sh');
  let findings = 0;
  let scanned = 0;
  try {
    for (const file of shellFiles(root)) {
      let src;
      try {
        src = fs.readFileSync(file, 'utf8');
      } catch (_) {
        continue;
      }
      scanned++;
      for (const s of substitutions(src)) {
        // A single-line body with no `case` cannot carry this defect and is the
        // overwhelming majority; skipping it keeps the scan off ~thousands of
        // needless bash spawns.
        if (!s.body.includes('\n') && !/\bcase\b/.test(s.body)) continue;
        if (parses(s.body, probePath)) continue;
        findings++;
        const line = src.slice(0, s.at).split('\n').length;
        const first = s.body.split('\n').map((l) => l.trim()).find(Boolean) || '';
        process.stdout.write(
          path.relative(root, file) + ':' + line + '\t' + first + '\n'
        );
      }
    }
  } finally {
    try { fs.rmSync(probeDir, { recursive: true, force: true }); } catch (_) {}
  }
  process.stderr.write('scanned ' + scanned + ' shell file(s); findings ' + findings + '\n');
  process.exit(findings === 0 ? 0 : 1);
}

main();
