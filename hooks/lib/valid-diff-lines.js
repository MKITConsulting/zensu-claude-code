#!/usr/bin/env node
// valid-diff-lines.js — unified-diff anchor validator for PR inline comments.
//
// GitHub's reviews API 422-rejects an inline comment whose (path, line, side)
// anchor does not land on a commentable line of the PR diff. This lib parses a
// unified diff (git diff / gh pr diff output) into per-file sets of commentable
// line numbers and answers anchor queries so the publish flow can validate and
// remap BEFORE posting instead of losing comments to the API.
//
//   RIGHT side = added (+) and context ( ) lines, numbered by the NEW file.
//   LEFT side  = removed (-) and context ( ) lines, numbered by the OLD file.
//
// Renames resolve to the NEW path (+++ b/<path>); a deleted file (+++ /dev/null)
// keeps its old path with LEFT lines only; binary files and "\ No newline"
// markers are skipped; quoted paths (core.quotepath octal escapes) are
// unquoted; file headers are only recognized OUTSIDE hunk bodies so content
// lines starting with "--"/"++" cannot desync the counters; malformed hunks
// fail soft (file skipped, parsing continues). Owned and consumed by the
// skills/pr-team-review publish flow (no hook consumer); zero dependencies,
// CommonJS with the sibling libs' require.main CLI/module split.
//
// CLI mode (diff on stdin):
//   node valid-diff-lines.js <path> <line> [RIGHT|LEFT]
// prints exactly one of:
//   valid        — (path, line) is a commentable anchor on the given side
//   remap <n>    — invalid, nearest commentable line on that side is <n>
//                  (minimal distance, capped at 40 lines; a tie prefers the
//                  FOLLOWING line)
//   none         — no commentable line within reach on that side (or bad
//                  usage / unparseable input / oversized input)
// Always exits 0 — verdicts are data, `none` is the fail-soft answer.

"use strict";

const HUNK = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/;
const REMAP_MAX_DISTANCE = 40;
const STDIN_MAX_BYTES = 50 * 1024 * 1024;

function unquotePath(p) {
  if (p.length >= 2 && p.charAt(0) === '"' && p.charAt(p.length - 1) === '"') {
    const inner = p.slice(1, -1);
    const ESC = { t: 9, n: 10, r: 13, b: 8, f: 12, v: 11, a: 7, "\\": 92, '"': 34 };
    const bytes = [];
    for (let i = 0; i < inner.length; i++) {
      const c = inner.charCodeAt(i);
      if (c !== 92) {
        bytes.push(c);
        continue;
      }
      if (i + 1 >= inner.length) return p;
      const n = inner.charAt(i + 1);
      if (n >= "0" && n <= "7") {
        bytes.push(parseInt(inner.slice(i + 1, i + 4), 8));
        i += 3;
      } else if (ESC[n] !== undefined) {
        bytes.push(ESC[n]);
        i += 1;
      } else {
        bytes.push(inner.charCodeAt(i + 1));
        i += 1;
      }
    }
    p = Buffer.from(bytes).toString("utf8");
  }
  return p;
}

function stripPrefix(p) {
  p = unquotePath(p);
  if (p.startsWith("a/") || p.startsWith("b/")) return p.slice(2);
  return p;
}

function parseDiff(text) {
  const files = Object.create(null);
  const lines = String(text || "").split("\n");
  let oldPath = "";
  let newPath = "";
  let right = null;
  let left = null;
  let oldN = 0;
  let newN = 0;
  let oldLeft = 0;
  let newLeft = 0;
  let inHunk = false;
  let skipFile = false;

  function open(path, leftPath) {
    const key = path !== "/dev/null" ? path : leftPath;
    if (!key) return;
    if (!files[key]) files[key] = { right: new Set(), left: new Set() };
    right = files[key].right;
    left = files[key].left;
  }

  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (l.startsWith("diff --git ")) {
      oldPath = "";
      newPath = "";
      right = null;
      left = null;
      inHunk = false;
      skipFile = false;
      continue;
    }
    if (skipFile) continue;
    const h = l.match(HUNK);
    if (h) {
      if (!right) open(newPath, oldPath);
      if (!right) {
        skipFile = true;
        continue;
      }
      oldN = parseInt(h[1], 10);
      newN = parseInt(h[3], 10);
      oldLeft = h[2] === undefined ? 1 : parseInt(h[2], 10);
      newLeft = h[4] === undefined ? 1 : parseInt(h[4], 10);
      inHunk = true;
      continue;
    }
    if (inHunk && (oldLeft > 0 || newLeft > 0)) {
      if (l.startsWith("\\")) continue;
      if (l.startsWith("+")) {
        if (newLeft > 0) {
          right.add(newN);
          newN++;
          newLeft--;
        }
      } else if (l.startsWith("-")) {
        if (oldLeft > 0) {
          left.add(oldN);
          oldN++;
          oldLeft--;
        }
      } else {
        if (newLeft > 0 && oldLeft > 0) {
          right.add(newN);
          left.add(oldN);
          newN++;
          oldN++;
          newLeft--;
          oldLeft--;
        } else {
          inHunk = false;
        }
      }
      continue;
    }
    inHunk = false;
    if (l.startsWith("Binary files ")) {
      skipFile = true;
      continue;
    }
    if (l.startsWith("--- ")) {
      oldPath = stripPrefix(l.slice(4).trim());
      continue;
    }
    if (l.startsWith("+++ ")) {
      newPath = stripPrefix(l.slice(4).trim());
      open(newPath, oldPath);
      continue;
    }
  }

  const out = Object.create(null);
  for (const k of Object.keys(files)) {
    out[k] = {
      right: Array.from(files[k].right).sort((a, b) => a - b),
      left: Array.from(files[k].left).sort((a, b) => a - b),
    };
  }
  return out;
}

function sideLines(parsed, path, side) {
  const f = parsed ? parsed[path] : undefined;
  if (!f) return null;
  const arr = side === "LEFT" ? f.left : f.right;
  return Array.isArray(arr) ? arr : null;
}

function isValidAnchor(parsed, path, line, side) {
  const arr = sideLines(parsed, path, side);
  if (!arr) return false;
  return arr.indexOf(line) >= 0;
}

function nearestAnchor(parsed, path, line, side) {
  const arr = sideLines(parsed, path, side);
  if (!arr || arr.length === 0) return null;
  let best = null;
  let bestDist = Infinity;
  for (const n of arr) {
    const d = Math.abs(n - line);
    if (d < bestDist || (d === bestDist && best !== null && n > best)) {
      best = n;
      bestDist = d;
    }
  }
  if (bestDist > REMAP_MAX_DISTANCE) return null;
  return best;
}

function isValidRight(parsed, path, line) {
  return isValidAnchor(parsed, path, line, "RIGHT");
}

function nearestRight(parsed, path, line) {
  return nearestAnchor(parsed, path, line, "RIGHT");
}

function cliMain(argv, stdinText) {
  const path = argv[0];
  const lineArg = argv[1];
  const sideRaw = argv[2] === undefined ? "" : String(argv[2]).trim();
  const sideArg = sideRaw === "" ? "RIGHT" : sideRaw.toUpperCase();
  const line = parseInt(lineArg, 10);
  if (!path || lineArg === undefined || !/^\d+$/.test(String(lineArg).trim())) {
    return "none";
  }
  if (sideArg !== "RIGHT" && sideArg !== "LEFT") {
    return "none";
  }
  let parsed;
  try {
    parsed = parseDiff(stdinText);
  } catch (_) {
    return "none";
  }
  if (isValidAnchor(parsed, path, line, sideArg)) return "valid";
  const near = nearestAnchor(parsed, path, line, sideArg);
  if (near === null) return "none";
  return "remap " + near;
}

if (require.main === module) {
  let buf = "";
  let bytes = 0;
  let overflow = false;
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (c) => {
    if (overflow) return;
    bytes += Buffer.byteLength(c, "utf8");
    if (bytes > STDIN_MAX_BYTES) {
      overflow = true;
      buf = "";
      return;
    }
    buf += c;
  });
  process.stdin.on("end", () => {
    let verdict;
    if (overflow) {
      verdict = "none";
    } else {
      try {
        verdict = cliMain(process.argv.slice(2), buf);
      } catch (_) {
        verdict = "none";
      }
    }
    process.stdout.write(verdict + "\n");
  });
} else {
  module.exports = {
    parseDiff,
    isValidAnchor,
    nearestAnchor,
    isValidRight,
    nearestRight,
    cliMain,
  };
}
