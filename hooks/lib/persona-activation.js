#!/usr/bin/env node
// persona-activation.js — repo-local review-persona activation for the
// /zensu:tdd review fan-out. Owned and consumed by the tdd skill's Phase 6
// step-10 fan-out (no hook consumer).
//
// Projects extend the review panel by dropping agent definitions at
// .claude/agents/zensu-review-*.md. Each may declare an `activation:`
// frontmatter field — a comma-separated list of glob patterns matched against
// the changed-file paths of the implementation. This helper decides, fully
// deterministically, which personas join the fan-out batch:
//
//   spawn <name>                      — joins the batch
//   skip <name> no-activation-match   — declared globs, none matched
//   skip <name> malformed             — unreadable / bad frontmatter / symlink
//                                       / name not matching
//                                       ^zensu-review-[A-Za-z0-9_-]+$ / name
//                                       not equal to the filename stem
//   drop <name> over-cap              — eligible, but the 5-spawn cap was hit
//
// The persona name doubles as the Agent-tool subagent_type and the finding
// ID prefix, so its shape is validated hard (single token, reserved
// zensu-review- namespace, equal to the filename stem) — a file failing the
// shape check is skipped as malformed, never spawned.
//
// Files are processed in lexicographic filename order; under cap pressure
// glob-MATCHED personas take the slots before always-join ones (relevance
// wins), each group lexicographic. Glob semantics: `**` crosses directory
// separators on a segment boundary (`**/domain/**` matches `src/domain/x`
// but NOT `src/subdomain/x`), `*` and `?` stay within one path segment, a
// pattern without `/` also matches the basename, comma separates
// alternatives (OR), items may be double- or single-quoted. Globs longer
// than 256 chars or with more than 16 wildcard runs are treated as
// non-matching (regex-cost bound); consecutive wildcard runs collapse.
// Symlinked directory entries are skipped. Missing dir or no personas → no
// output. Always exits 0 — a helper failure must never abort the review
// chain.
//
// CLI (changed-file paths newline-separated on stdin):
//   node persona-activation.js <personas-dir>

"use strict";

const fs = require("fs");
const path = require("path");

const SPAWN_CAP = 5;
const GLOB_MAX_LENGTH = 256;
const GLOB_MAX_WILDCARD_RUNS = 16;
const NAME_SHAPE = /^zensu-review-[A-Za-z0-9_-]+$/;

function globToRegExp(glob) {
  let re = "";
  let runs = 0;
  for (let i = 0; i < glob.length; i++) {
    const c = glob.charAt(i);
    if (c === "*") {
      const boundedLeft = i === 0 || glob.charAt(i - 1) === "/";
      let deep = false;
      while (glob.charAt(i) === "*") {
        if (glob.charAt(i + 1) === "*") deep = true;
        i++;
      }
      i--;
      runs++;
      const next = glob.charAt(i + 1);
      if (deep && boundedLeft && next === "/") {
        re += "(?:.*/)?";
        i++;
      } else if (deep && boundedLeft && next === "") {
        re += ".*";
      } else {
        re += "[^/]*";
      }
    } else if (c === "?") {
      runs++;
      re += "[^/]";
    } else if ("\\^$.|+()[]{}".indexOf(c) >= 0) {
      re += "\\" + c;
    } else {
      re += c;
    }
  }
  if (runs > GLOB_MAX_WILDCARD_RUNS) return null;
  return new RegExp("^" + re + "$");
}

function matchActivation(globsCsv, changedPaths) {
  const globs = String(globsCsv || "")
    .split(",")
    .map((g) => g.trim().replace(/^["']|["']$/g, ""))
    .filter(Boolean);
  if (globs.length === 0) return false;
  for (const g of globs) {
    if (g.length > GLOB_MAX_LENGTH) continue;
    let rx;
    try {
      rx = globToRegExp(g);
    } catch (_) {
      continue;
    }
    if (!rx) continue;
    const basenameToo = g.indexOf("/") < 0;
    for (const p of changedPaths) {
      if (rx.test(p)) return true;
      if (basenameToo && rx.test(path.posix.basename(p))) return true;
    }
  }
  return false;
}

function parsePersona(filePath) {
  let text;
  try {
    text = fs.readFileSync(filePath, "utf8");
  } catch (_) {
    return null;
  }
  const lines = text.split(/\r?\n/);
  if (lines[0].trim() !== "---") return null;
  let name = "";
  let activation;
  for (let i = 1; i < lines.length; i++) {
    const l = lines[i];
    if (l.trim() === "---") break;
    const m = l.match(/^(name|activation):[ \t]*(.*)$/);
    if (!m) continue;
    const val = m[2].trim().replace(/^["']|["']$/g, "");
    if (m[1] === "name") name = val;
    else activation = val;
  }
  if (!name) return null;
  return { name, activation };
}

function decide(personasDir, changedPaths) {
  let entries;
  try {
    entries = fs.readdirSync(personasDir);
  } catch (_) {
    return [];
  }
  const files = entries
    .filter((f) => /^zensu-review-.*\.md$/.test(f))
    .sort();
  const matched = [];
  const alwaysJoin = [];
  const rejected = [];
  for (const f of files) {
    const rawStem = f.replace(/\.md$/, "");
    const stem = NAME_SHAPE.test(rawStem) ? rawStem : "invalid-filename";
    const full = path.join(personasDir, f);
    let st;
    try {
      st = fs.lstatSync(full);
    } catch (_) {
      st = null;
    }
    if (!st || st.isSymbolicLink()) {
      rejected.push("skip " + stem + " malformed");
      continue;
    }
    const persona = parsePersona(full);
    if (!persona || !NAME_SHAPE.test(persona.name) || persona.name !== stem) {
      rejected.push("skip " + stem + " malformed");
      continue;
    }
    if (persona.activation === undefined) {
      alwaysJoin.push(persona.name);
    } else if (matchActivation(persona.activation, changedPaths)) {
      matched.push(persona.name);
    } else {
      rejected.push("skip " + persona.name + " no-activation-match");
    }
  }
  const out = [];
  let spawned = 0;
  for (const name of matched.concat(alwaysJoin)) {
    if (spawned >= SPAWN_CAP) {
      out.push("drop " + name + " over-cap");
    } else {
      spawned++;
      out.push("spawn " + name);
    }
  }
  return out.concat(rejected);
}

if (require.main === module) {
  let buf = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (c) => {
    buf += c;
  });
  process.stdin.on("end", () => {
    let lines = [];
    try {
      const changed = buf
        .split("\n")
        .map((s) => s.trim())
        .filter(Boolean);
      lines = decide(process.argv[2] || "", changed);
    } catch (_) {
      lines = [];
    }
    if (lines.length) process.stdout.write(lines.join("\n") + "\n");
  });
} else {
  module.exports = {
    globToRegExp,
    matchActivation,
    parsePersona,
    decide,
    SPAWN_CAP,
  };
}
