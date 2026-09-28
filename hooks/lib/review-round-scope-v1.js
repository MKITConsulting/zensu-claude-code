#!/usr/bin/env node
// review-round-scope-v1.js — deterministic round-delta extractor for the
// /zensu:tdd auto-fix loop.
//
// Phase 6 step 10 used to re-review the WHOLE diff on every auto-fix round. An
// aspect agent re-reading a file that has not changed since the previous round
// cannot produce a new finding — same lines, same evidence — so rounds 2..N paid
// a full fan-out for redundant coverage. Measured on this repository's own
// subagent transcripts, one aspect agent ingests ~513k context tokens over ~40
// internal turns, so a full fan-out (five aspects + judge + consume reviewer) is
// the dominant cost of the chain and every repeated round multiplies it.
//
// This lib answers ONE question: which files did THIS round's own fixes touch?
// The run log already carries the answer — every routed round logs its edits as
//   R<round>-<step> IMPL completed — files: a.ts, b.ts | ...
// so the delta is derivable without a new persisted field and without trusting
// the model to re-derive a file list it already wrote down.
//
// FAIL-OPEN BY CONTRACT, and this is the whole safety argument: a delta that
// cannot be established is NOT an empty delta. `status=empty` and
// `status=degraded` both mean "caller must use the full diff", and TRUNCATION at
// either cap is a degraded cause: a delta that lost a path is incomplete, and
// narrowing to an incomplete delta would skip a file this round changed. Only `status=ok`
// with a non-empty file list licenses a narrowed packet. Reading an unusable log
// as "nothing changed this round" would silently review nothing, which is worse
// than the redundancy this lib removes.
//
// The JUDGE is deliberately out of scope here. Cross-cutting drift into files
// this round did NOT touch is exactly what a delta hides, so the caller keeps
// feeding zensu:review-judge the full cumulative diff. This lib narrows the
// single-perspective panel only.
//
// CLI:
//   node review-round-scope-v1.js --log <path> --round <n> [--root <abs-path>]
// prints one line per delta file:
//   file <repo-relative-path>
// optionally followed by:
//   truncated dropped=<n>            (paths beyond either cap; forces status=degraded)
// and always terminated by:
//   summary status=<ok|empty|degraded> round=<n> files=<n> claims=<n>
//
// Always exits 0 — a scope verdict is data, not a gate. Zero dependencies,
// CommonJS with the sibling libs' require.main CLI/module split.

"use strict";

const fs = require("node:fs");
const path = require("node:path");

const FILE_MAX_BYTES = 8 * 1024 * 1024;
const MAX_FILES = 500;
const MAX_CLAIM_FILES = 200;
const DENIED_SEGMENTS = new Set([".git", ".zensu"]);

// `R12-S3 IMPL completed — files: a, b | rest` and the bare `R12 IMPL ...` form.
// The dash class admits the em dash the skill prescribes AND the plain hyphen a
// real run log has already used, because a claim the extractor cannot see is a
// claim that silently drops out of the delta.
const CLAIM = /^\s*(?:\[[^\]]*\]\s*)?R(\d+)(?:-[A-Za-z0-9_.+-]+)?\s+IMPL\s+completed\s*[—–-]\s*files:\s*([^|]*)/;
const RESET = /^\s*(?:\[[^\]]*\]\s*)?REVIEW BUDGET RESET\b/;

function claimRound(line) {
  const m = CLAIM.exec(String(line == null ? "" : line));
  if (!m) return null;
  const round = parseInt(m[1], 10);
  if (!Number.isInteger(round) || round < 1) return null;
  return { round, files: m[2] };
}

function splitFiles(blob) {
  return String(blob == null ? "" : blob)
    .split(/[,\s]+/)
    .map((entry) => entry.trim())
    .filter((entry) => entry !== "");
}

function safeRelativePath(candidate) {
  const raw = String(candidate == null ? "" : candidate).trim();
  if (raw === "") return null;
  if (raw.length > 4096) return null;
  if (/[\u0000-\u001f\u007f]/.test(raw)) return null;
  if (path.isAbsolute(raw) || /^[A-Za-z]:[\\/]/.test(raw)) return null;
  const normalized = raw.split("\\").join("/").replace(/^\.\//, "");
  if (normalized === "") return null;
  const segments = normalized.split("/");
  for (const segment of segments) {
    if (segment === "" || segment === "." || segment === "..") return null;
    if (DENIED_SEGMENTS.has(segment)) return null;
  }
  return normalized;
}

function readLog(logPath, rootReal) {
  if (typeof logPath !== "string" || logPath.trim() === "") {
    return { ok: false, reason: "no-log" };
  }
  let abs;
  try {
    abs = path.resolve(logPath);
  } catch (_) {
    return { ok: false, reason: "unresolvable-log" };
  }
  if (rootReal) {
    const back = path.relative(rootReal, abs);
    if (back === "" || back.startsWith("..") || path.isAbsolute(back)) {
      return { ok: false, reason: "log-outside-root" };
    }
  }
  let stat;
  try {
    stat = fs.lstatSync(abs);
  } catch (_) {
    return { ok: false, reason: "log-unreadable" };
  }
  if (!stat.isFile()) return { ok: false, reason: "log-not-a-file" };
  if (stat.size > FILE_MAX_BYTES) return { ok: false, reason: "log-too-large" };
  let text;
  try {
    text = fs.readFileSync(abs, "utf8");
  } catch (_) {
    return { ok: false, reason: "log-unreadable" };
  }
  return { ok: true, text };
}

function roundScope(options) {
  const opts = options || {};
  const round = Number(opts.round);
  if (!Number.isInteger(round) || round < 1) {
    return { status: "degraded", reason: "bad-round", round: 0, files: [], claims: 0, dropped: 0 };
  }

  let rootReal = "";
  if (typeof opts.root === "string" && opts.root.trim() !== "") {
    try {
      rootReal = fs.realpathSync.native(opts.root);
    } catch (_) {
      return { status: "degraded", reason: "bad-root", round, files: [], claims: 0, dropped: 0 };
    }
  }

  let text = opts.text;
  if (typeof text !== "string") {
    const read = readLog(opts.log, rootReal);
    if (!read.ok) {
      return { status: "degraded", reason: read.reason, round, files: [], claims: 0, dropped: 0 };
    }
    text = read.text;
  }

  const seen = new Set();
  const files = [];
  let claims = 0;
  let dropped = 0;
  for (const line of text.split("\n")) {
    if (RESET.test(line)) {
      seen.clear();
      files.length = 0;
      claims = 0;
      dropped = 0;
      continue;
    }
    const claim = claimRound(line);
    if (!claim || claim.round !== round) continue;
    claims += 1;
    const all = splitFiles(claim.files);
    if (all.length > MAX_CLAIM_FILES) dropped += all.length - MAX_CLAIM_FILES;
    const entries = all.slice(0, MAX_CLAIM_FILES);
    for (const entry of entries) {
      const rel = safeRelativePath(entry);
      if (rel === null || seen.has(rel)) continue;
      if (files.length >= MAX_FILES) {
        dropped += 1;
        continue;
      }
      seen.add(rel);
      files.push(rel);
    }
  }

  files.sort();
  if (dropped > 0) {
    return { status: "degraded", reason: "truncated", round, files, claims, dropped };
  }
  if (files.length === 0) {
    return { status: "empty", reason: claims === 0 ? "no-claims" : "no-usable-paths", round, files, claims, dropped };
  }
  return { status: "ok", reason: "", round, files, claims, dropped };
}

function render(report) {
  const lines = [];
  for (const file of report.files) lines.push("file " + file);
  if (report.dropped > 0) lines.push("truncated dropped=" + report.dropped);
  lines.push(
    "summary status=" +
      report.status +
      " round=" +
      report.round +
      " files=" +
      report.files.length +
      " claims=" +
      report.claims
  );
  return lines.join("\n");
}

function parseArgs(argv) {
  let log = "";
  let root = "";
  let round = 0;
  for (let i = 0; i < argv.length; i++) {
    const arg = String(argv[i]);
    const next = argv[i + 1] === undefined ? "" : String(argv[i + 1]);
    if (arg === "--log") {
      log = next;
      i++;
    } else if (arg === "--root") {
      root = next;
      i++;
    } else if (arg === "--round") {
      round = Number(next);
      i++;
    }
  }
  return { log, root, round };
}

function cliMain(argv) {
  const { log, root, round } = parseArgs(Array.isArray(argv) ? argv : []);
  return render(roundScope({ log, root, round }));
}

if (require.main === module) {
  let out;
  try {
    out = cliMain(process.argv.slice(2));
  } catch (_) {
    out = "summary status=degraded round=0 files=0 claims=0";
  }
  process.stdout.write(out + "\n");
  process.exitCode = 0;
} else {
  module.exports = {
    CLAIM,
    RESET,
    FILE_MAX_BYTES,
    MAX_FILES,
    MAX_CLAIM_FILES,
    claimRound,
    safeRelativePath,
    readLog,
    roundScope,
    render,
    cliMain,
  };
}
