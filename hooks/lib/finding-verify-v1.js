#!/usr/bin/env node
// finding-verify-v1.js — deterministic anchor grader for fan-out review findings.
//
// Every Zensu review fan-out merges N agent findings lists and then acts on them:
// auto-fix rounds (/zensu:tdd), a published forge review (/zensu:pr-team-review),
// a verdict report (/zensu:plan-review). This lib is stage 1 of the verification
// gate that sits between "an agent said it" and "we act on it". It is model-free
// by construction, so it is the floor that cannot itself hallucinate: it only
// answers whether a finding's file:line anchor corresponds to something real.
// Stage 2 — deciding whether the finding's claim about that line is true — is the
// main thread's own read and is deliberately NOT automated here.
//
// Verdicts, one per findings line:
//   anchor-ok          file exists under root, line within EOF, path in changed set
//   off-changeset      file + line real, but the path is not in the changed set
//   line-out-of-range  file real, line past EOF (or line 0) — hard hallucination
//   phantom-path       nothing (or no regular file) at that path — hard hallucination
//   out-of-root        escapes --root, or targets .git/.zensu — rejected, never read
//   no-anchor          no path:line token on the line (meta lines such as Panel-FP:)
//
// Innocence rule: a verdict accuses only what it can prove. A file larger than the
// read cap skips the range check and is graded by changed-set membership alone,
// because an ungradable anchor is not a false one.
//
// Stdin carries both inputs behind markers, so one call needs no temp file and has
// no ARG_MAX ceiling. CHANGED-FILES is optional (an absent set makes every real
// anchor off-changeset); FINDINGS is required:
//
//   CHANGED-FILES
//   src/a.ts
//   FINDINGS
//   - [CRITICAL] src/a.ts:42 — issue. Evidence: ... Fix: ...
//
// Findings are matched by the FIRST path:line token on the line, never by format,
// so the same lib serves the /zensu:tdd aspect text, pr-team-review's JSON-derived
// anchors, and plan-review's code references — each caller emits one line per
// finding and matches results back by index.
//
// CLI mode (input on stdin):
//   node finding-verify-v1.js --root <abs-path>
// prints one line per non-blank findings line:
//   <n> <verdict> <path>:<line>          (or "-" as the anchor when no-anchor)
//   <n> line-out-of-range <path>:<line> lines=<count>
// optionally followed by:
//   truncated dropped=<n>                (findings beyond MAX_FINDINGS, never silent)
// and always terminated by:
//   summary ok=<n> off-changeset=<n> out-of-range=<n> phantom=<n> out-of-root=<n> no-anchor=<n> total=<n>
//
// Always exits 0 — verdicts are data. Unusable input (over-cap stdin, missing
// FINDINGS marker, unusable root) yields a total=0 summary, which the caller
// detects as a mismatch against its own finding count and reports as degraded
// rather than as a clean pass. Zero dependencies, CommonJS with the sibling libs'
// require.main CLI/module split.

"use strict";

const fs = require("node:fs");
const path = require("node:path");

const STDIN_MAX_BYTES = 4 * 1024 * 1024;
const FILE_MAX_BYTES = 8 * 1024 * 1024;
const MAX_FINDINGS = 2000;
const DENIED_SEGMENTS = new Set([".git", ".zensu"]);
const CHANGED_MARKER = "CHANGED-FILES";
const FINDINGS_MARKER = "FINDINGS";
const ANCHOR = /(?:^|[\s(\[<"'`])((?:\.{0,2}\/)?[A-Za-z0-9_.@+~-][^\s:"'<>|`]*):(\d+)(?![0-9])/;

function parseInput(text) {
  const lines = String(text == null ? "" : text).split("\n");
  let findingsAt = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].trim() === FINDINGS_MARKER) {
      findingsAt = i;
      break;
    }
  }
  if (findingsAt < 0) return null;
  let changedAt = -1;
  for (let i = 0; i < findingsAt; i++) {
    if (lines[i].trim() === CHANGED_MARKER) {
      changedAt = i;
      break;
    }
  }
  const changedFiles = [];
  if (changedAt >= 0) {
    for (let i = changedAt + 1; i < findingsAt; i++) {
      const entry = lines[i].trim();
      if (entry !== "") changedFiles.push(entry);
    }
  }
  const findings = [];
  for (let i = findingsAt + 1; i < lines.length; i++) {
    if (lines[i].trim() !== "") findings.push(lines[i]);
  }
  return { changedFiles, findings };
}

function extractAnchor(line) {
  const m = ANCHOR.exec(String(line == null ? "" : line));
  if (!m) return null;
  return { path: m[1], line: parseInt(m[2], 10) };
}

function containedPath(rootReal, candidate) {
  let abs;
  try {
    abs = path.resolve(rootReal, candidate);
  } catch (_) {
    return null;
  }
  const back = path.relative(rootReal, abs);
  if (back === "" || back.startsWith("..") || path.isAbsolute(back)) return null;
  const segments = back.split(path.sep);
  for (const segment of segments) {
    if (DENIED_SEGMENTS.has(segment)) return null;
  }
  return abs;
}

function countLines(text) {
  let count = 0;
  for (let i = 0; i < text.length; i++) {
    if (text.charCodeAt(i) === 10) count++;
  }
  if (text.length > 0 && text.charCodeAt(text.length - 1) !== 10) count++;
  return count;
}

function measureFile(abs, rootReal, cache) {
  if (cache.has(abs)) return cache.get(abs);
  let measured;
  let stat = null;
  try {
    stat = fs.statSync(abs);
  } catch (_) {
    stat = null;
  }
  if (!stat || !stat.isFile()) {
    measured = { state: "missing" };
  } else {
    let real;
    try {
      real = fs.realpathSync(abs);
    } catch (_) {
      real = null;
    }
    if (real === null || containedPath(rootReal, real) === null) {
      measured = { state: "escaped" };
    } else if (stat.size > FILE_MAX_BYTES) {
      measured = { state: "unmeasured" };
    } else {
      let text;
      try {
        text = fs.readFileSync(abs, "utf8");
      } catch (_) {
        text = null;
      }
      measured = text === null
        ? { state: "unmeasured" }
        : { state: "measured", lines: countLines(text) };
    }
  }
  cache.set(abs, measured);
  return measured;
}

function verifyFindings(options) {
  const opts = options || {};
  const findings = Array.isArray(opts.findings) ? opts.findings : [];
  const dropped = findings.length > MAX_FINDINGS ? findings.length - MAX_FINDINGS : 0;
  const graded = dropped > 0 ? findings.slice(0, MAX_FINDINGS) : findings;
  let rootReal = null;
  try {
    const stat = fs.statSync(opts.root);
    if (stat.isDirectory()) rootReal = fs.realpathSync(opts.root);
  } catch (_) {
    rootReal = null;
  }
  if (rootReal === null) return { results: [], dropped: 0 };

  const changed = new Set();
  for (const entry of Array.isArray(opts.changedFiles) ? opts.changedFiles : []) {
    const abs = containedPath(rootReal, entry);
    if (abs !== null) changed.add(abs);
  }

  const cache = new Map();
  const results = [];
  for (const raw of graded) {
    const anchor = extractAnchor(raw);
    if (anchor === null) {
      results.push({ verdict: "no-anchor", anchor: null });
      continue;
    }
    const abs = containedPath(rootReal, anchor.path);
    if (abs === null) {
      results.push({ verdict: "out-of-root", anchor });
      continue;
    }
    const measured = measureFile(abs, rootReal, cache);
    if (measured.state === "missing") {
      results.push({ verdict: "phantom-path", anchor });
      continue;
    }
    if (measured.state === "escaped") {
      results.push({ verdict: "out-of-root", anchor });
      continue;
    }
    if (measured.state === "measured" && (anchor.line < 1 || anchor.line > measured.lines)) {
      results.push({ verdict: "line-out-of-range", anchor, lines: measured.lines });
      continue;
    }
    results.push({ verdict: changed.has(abs) ? "anchor-ok" : "off-changeset", anchor });
  }
  return { results, dropped };
}

function render(report) {
  const counts = {
    "anchor-ok": 0,
    "off-changeset": 0,
    "line-out-of-range": 0,
    "phantom-path": 0,
    "out-of-root": 0,
    "no-anchor": 0,
  };
  const out = [];
  report.results.forEach((result, index) => {
    counts[result.verdict]++;
    const anchor = result.anchor === null ? "-" : result.anchor.path + ":" + result.anchor.line;
    const detail = result.verdict === "line-out-of-range" ? " lines=" + result.lines : "";
    out.push(String(index + 1) + " " + result.verdict + " " + anchor + detail);
  });
  if (report.dropped > 0) out.push("truncated dropped=" + report.dropped);
  out.push(
    "summary ok=" + counts["anchor-ok"]
    + " off-changeset=" + counts["off-changeset"]
    + " out-of-range=" + counts["line-out-of-range"]
    + " phantom=" + counts["phantom-path"]
    + " out-of-root=" + counts["out-of-root"]
    + " no-anchor=" + counts["no-anchor"]
    + " total=" + report.results.length,
  );
  return out.join("\n");
}

function parseArgs(argv) {
  let root = "";
  for (let i = 0; i < argv.length; i++) {
    const arg = String(argv[i]);
    if (arg === "--root") {
      root = argv[i + 1] === undefined ? "" : String(argv[i + 1]);
      i++;
    } else if (arg.startsWith("--root=")) {
      root = arg.slice("--root=".length);
    }
  }
  return { root };
}

function cliMain(argv, stdinText) {
  const empty = render({ results: [], dropped: 0 });
  const { root } = parseArgs(Array.isArray(argv) ? argv : []);
  if (root === "") return empty;
  let parsed;
  try {
    parsed = parseInput(stdinText);
  } catch (_) {
    return empty;
  }
  if (parsed === null) return empty;
  try {
    return render(verifyFindings({
      root,
      changedFiles: parsed.changedFiles,
      findings: parsed.findings,
    }));
  } catch (_) {
    return empty;
  }
}

if (require.main === module) {
  let buf = "";
  let bytes = 0;
  let overflow = false;
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    if (overflow) return;
    bytes += Buffer.byteLength(chunk, "utf8");
    if (bytes > STDIN_MAX_BYTES) {
      overflow = true;
      buf = "";
      return;
    }
    buf += chunk;
  });
  process.stdin.on("end", () => {
    let out;
    if (overflow) {
      out = render({ results: [], dropped: 0 });
    } else {
      try {
        out = cliMain(process.argv.slice(2), buf);
      } catch (_) {
        out = render({ results: [], dropped: 0 });
      }
    }
    process.stdout.write(out + "\n");
  });
} else {
  module.exports = {
    parseInput,
    extractAnchor,
    verifyFindings,
    render,
    cliMain,
    STDIN_MAX_BYTES,
    FILE_MAX_BYTES,
    MAX_FINDINGS,
  };
}
