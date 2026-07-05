#!/usr/bin/env node
'use strict';

// Resolve the ACTIVE Claude Code session's project directory (absolute) in a
// cwd-INDEPENDENT way, for non-hook Bash callers where CLAUDE_PROJECT_DIR is
// unset (Claude Code injects it only into hook environments, not Bash tool
// calls). A git worktree makes cwd != the launch/project root, so cwd- and
// git-toplevel-based anchoring both diverge from the value hooks see as
// CLAUDE_PROJECT_DIR. Every transcript entry, however, carries a "cwd" field
// equal to that launch/project root (stable across a subshell `cd`), so the
// active transcript is the one reliable bridge.
//
// Output contract: prints the resolved absolute project dir, or NOTHING (empty)
// when no active transcript can be identified. Empty is deliberate — the caller
// (hooks/lib/zensu-log.sh) only exports CLAUDE_PROJECT_DIR when this prints a
// value, so a miss leaves the pre-existing `${CLAUDE_PROJECT_DIR:-.}` behavior
// exactly unchanged. Always exits 0.
//
// Resolution tiers (mirrors hooks/lib/resolve-session-id.js candidate logic):
//   1. ZENSU_TRANSCRIPT_PATH (a .jsonl) -> parse its cwd directly.
//   2. Global scan of every ~/.claude/projects/<subdir>/*.jsonl (base overridable
//      via ZENSU_PROJECTS_DIR) newest-first, honoring the ZENSU_BASH_START mtime
//      cutoff (argv[2]) and the ZENSU_OWN_CMD tail-match tie-break, then parse
//      the chosen transcript's cwd.

const fs = require('fs');
const path = require('path');
const os = require('os');

function projectsBase() {
  if (process.env.ZENSU_PROJECTS_DIR) return process.env.ZENSU_PROJECTS_DIR;
  return path.join(os.homedir(), '.claude', 'projects');
}

// Nanosecond-epoch cutoff (same shape/guards as resolve-session-id.js): a bare
// `date +%s%N` is 19 digits; anything shorter (e.g. an unexpanded "%N") or
// non-numeric is rejected so the caller self-inits to Date.now(). Keep the
// 18-length guard in lockstep with resolve-session-id.js's copy — both encode
// the same 19-digit-nanosecond contract.
function parseCutoffMs(arg) {
  if (!arg) return null;
  const s = String(arg).trim();
  if (!/^[0-9]+$/.test(s)) return null;
  if (s.length < 18) return null;
  try {
    return Number(BigInt(s) / 1000000n);
  } catch (_) {
    return null;
  }
}

function readTail(filePath, byteLen) {
  let fd;
  try {
    fd = fs.openSync(filePath, 'r');
    const size = fs.fstatSync(fd).size;
    const start = Math.max(0, size - byteLen);
    const len = size - start;
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, start);
    return buf.toString('utf8');
  } catch (_) {
    return '';
  } finally {
    if (fd !== undefined) {
      try { fs.closeSync(fd); } catch (_) {}
    }
  }
}

function readHead(filePath, byteLen) {
  let fd;
  try {
    fd = fs.openSync(filePath, 'r');
    const size = fs.fstatSync(fd).size;
    const len = Math.min(size, byteLen);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, 0);
    return buf.toString('utf8');
  } catch (_) {
    return '';
  } finally {
    if (fd !== undefined) {
      try { fs.closeSync(fd); } catch (_) {}
    }
  }
}

// Parse the first JSONL record that carries a non-empty string `cwd`. Scans from
// the top over a bounded head — cwd appears on the first substantive entry
// (queue-operation preamble lines omit it, but they are tiny). A head truncated
// mid-line only risks the final element, which we never reach once an earlier
// line yields a cwd.
function cwdFromTranscript(filePath) {
  const head = readHead(filePath, 262144);
  if (!head) return '';
  const lines = head.split('\n');
  for (const ln of lines) {
    const s = ln.trim();
    if (!s || s.charCodeAt(0) !== 0x7b /* { */) continue;
    let obj;
    try {
      obj = JSON.parse(s);
    } catch (_) {
      continue;
    }
    if (obj && typeof obj.cwd === 'string' && obj.cwd) return obj.cwd;
  }
  return '';
}

function listAllCandidates(base) {
  let subdirs;
  try {
    subdirs = fs.readdirSync(base, { withFileTypes: true });
  } catch (_) {
    return [];
  }
  const out = [];
  for (const ent of subdirs) {
    let dirPath;
    try {
      if (ent.isDirectory()) {
        dirPath = path.join(base, ent.name);
      } else if (ent.isSymbolicLink()) {
        const full = path.join(base, ent.name);
        if (!fs.statSync(full).isDirectory()) continue;
        dirPath = full;
      } else {
        continue;
      }
    } catch (_) {
      continue;
    }
    let files;
    try {
      files = fs.readdirSync(dirPath);
    } catch (_) {
      continue;
    }
    for (const name of files) {
      if (!name.endsWith('.jsonl')) continue;
      const full = path.join(dirPath, name);
      let mtimeMs;
      try {
        mtimeMs = fs.statSync(full).mtimeMs;
      } catch (_) {
        continue;
      }
      out.push({ full, mtimeMs });
    }
  }
  out.sort((a, b) => b.mtimeMs - a.mtimeMs);
  return out;
}

function main() {
  // Tier 1 — explicit transcript path.
  const transcriptPath = process.env.ZENSU_TRANSCRIPT_PATH || '';
  if (transcriptPath && String(transcriptPath).endsWith('.jsonl')) {
    const cwd = cwdFromTranscript(String(transcriptPath));
    if (cwd) {
      process.stdout.write(cwd);
      return 0;
    }
  }

  // Tier 2 — global active-transcript scan.
  const helperStartMs = Date.now();
  let files = listAllCandidates(projectsBase());

  const parsedCutoffMs = parseCutoffMs(process.argv[2]);
  const cutoffMs = parsedCutoffMs !== null ? parsedCutoffMs : helperStartMs;
  files = files.filter((f) => f.mtimeMs <= cutoffMs);

  if (files.length > 0) {
    let chosen = null;
    if (files.length > 1 && process.env.ZENSU_OWN_CMD) {
      const needle = process.env.ZENSU_OWN_CMD;
      for (const f of files) {
        const tail = readTail(f.full, 4096);
        if (tail.indexOf(needle) !== -1) {
          chosen = f;
          break;
        }
      }
    }
    if (!chosen) chosen = files[0];
    const cwd = cwdFromTranscript(chosen.full);
    if (cwd) {
      process.stdout.write(cwd);
      return 0;
    }
  }

  process.stdout.write('');
  return 0;
}

process.exit(main());
