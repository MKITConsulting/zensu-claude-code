#!/usr/bin/env node
// aspect-activation-v1.js — deterministic built-in-aspect activation for the
// /zensu:tdd review fan-out.
//
// The panel always spawned all five perspectives regardless of what the change
// set contained, so a documentation-only diff still paid a `security` and an
// `architecture` agent — each ~513k context tokens over ~40 internal turns,
// measured on this repository's own subagent transcripts. This lib decides,
// deterministically, which built-in aspects a given change set can still
// implicate. It is the built-in twin of persona-activation.js, which already
// does the same job for repo-local `zensu-review-*` personas, and it follows
// that file's verdict vocabulary (`spawn` / `skip`) so one caller parses both.
//
// THE RULES ARE DELIBERATELY CONSERVATIVE, because a wrongly skipped aspect is
// a silent loss of review coverage while a wrongly spawned one costs only
// tokens. Only two reductions are claimed, and each is one a full agent could
// not have contradicted anyway:
//
//   conventions  always — repository guidance applies to every file kind
//   bugs         always — any change can carry one, including a test or a doc
//   tests        skip only when the change set is documentation ONLY
//   security     skip only when the change set is documentation ONLY
//   architecture skip when the change set is documentation and/or tests ONLY
//
// `security` deliberately still runs on a tests-only change set: fixtures carry
// credentials, and that is exactly the case a "just tests" heuristic would miss.
// `architecture` does not, because a layering or dependency-direction verdict is
// about production code and a tests-only delta contains none.
//
// FAIL-OPEN BY CONTRACT: an empty, unreadable or unclassifiable change set
// spawns EVERY aspect. A file that is neither documentation nor a test is
// production code, and one such file is enough to spawn the full panel — the
// predicates below therefore answer "is every file X", never "is some file X".
//
// CLI (changed-file paths newline-separated on stdin):
//   node aspect-activation-v1.js
// prints one line per built-in aspect, in ASPECTS order:
//   spawn <aspect>
//   skip <aspect> <reason>
// and always terminates with:
//   summary spawn=<n> skip=<n> kind=<mixed|docs-only|tests-only|docs-and-tests|unknown>
//
// Always exits 0 — an activation verdict is data, not a gate. Zero dependencies,
// CommonJS with the sibling libs' require.main CLI/module split.

"use strict";

const path = require("node:path");

const STDIN_MAX_BYTES = 1 * 1024 * 1024;
const MAX_PATHS = 5000;

const ASPECTS = ["conventions", "bugs", "architecture", "tests", "security"];

const DOC_EXTENSIONS = new Set([".md", ".markdown", ".txt", ".rst", ".adoc"]);
const DOC_DIRECTORIES = new Set(["docs", "doc"]);
const TEST_DIRECTORIES = new Set(["test", "tests", "spec", "specs", "__tests__", "e2e", "evals"]);
const TEST_BASENAME = /(^test[-_.]|[-_.]test\.|[-_.]spec\.|^spec[-_.])/i;

function normalize(candidate) {
  const raw = String(candidate == null ? "" : candidate).trim();
  if (raw === "") return null;
  if (raw.length > 4096) return null;
  if (/[\u0000-\u001f\u007f]/.test(raw)) return null;
  const normalized = raw.split("\\").join("/").replace(/^\.\//, "");
  return normalized === "" ? null : normalized;
}

function isDocumentation(file) {
  const ext = path.posix.extname(file).toLowerCase();
  if (DOC_EXTENSIONS.has(ext)) return true;
  const segments = file.split("/");
  for (let i = 0; i < segments.length - 1; i++) {
    if (DOC_DIRECTORIES.has(segments[i].toLowerCase())) return true;
  }
  return false;
}

function isTest(file) {
  const segments = file.split("/");
  for (let i = 0; i < segments.length - 1; i++) {
    if (TEST_DIRECTORIES.has(segments[i].toLowerCase())) return true;
  }
  return TEST_BASENAME.test(segments[segments.length - 1]);
}

function classify(files) {
  const usable = [];
  for (const candidate of Array.isArray(files) ? files : []) {
    const file = normalize(candidate);
    if (file !== null) usable.push(file);
    if (usable.length >= MAX_PATHS) break;
  }
  if (usable.length === 0) return { kind: "unknown", files: usable };

  let docs = 0;
  let tests = 0;
  for (const file of usable) {
    const doc = isDocumentation(file);
    if (doc) {
      docs += 1;
      continue;
    }
    if (isTest(file)) tests += 1;
  }
  const total = usable.length;
  if (docs === total) return { kind: "docs-only", files: usable };
  if (tests === total) return { kind: "tests-only", files: usable };
  if (docs + tests === total) return { kind: "docs-and-tests", files: usable };
  return { kind: "mixed", files: usable };
}

function activate(files) {
  const { kind } = classify(files);
  const docsOnly = kind === "docs-only";
  const noProductionCode = docsOnly || kind === "tests-only" || kind === "docs-and-tests";

  const verdicts = ASPECTS.map((aspect) => {
    if (aspect === "conventions" || aspect === "bugs") {
      return { aspect, spawn: true, reason: "" };
    }
    if (aspect === "tests" || aspect === "security") {
      return docsOnly
        ? { aspect, spawn: false, reason: "documentation-only-changeset" }
        : { aspect, spawn: true, reason: "" };
    }
    return noProductionCode
      ? { aspect, spawn: false, reason: "no-production-code-in-changeset" }
      : { aspect, spawn: true, reason: "" };
  });

  return { kind, verdicts };
}

function render(report) {
  const lines = [];
  let spawn = 0;
  let skip = 0;
  for (const verdict of report.verdicts) {
    if (verdict.spawn) {
      spawn += 1;
      lines.push("spawn " + verdict.aspect);
    } else {
      skip += 1;
      lines.push("skip " + verdict.aspect + " " + verdict.reason);
    }
  }
  lines.push("summary spawn=" + spawn + " skip=" + skip + " kind=" + report.kind);
  return lines.join("\n");
}

function cliMain(stdinText) {
  const text = String(stdinText == null ? "" : stdinText);
  return render(activate(text.split("\n")));
}

if (require.main === module) {
  let buf = "";
  let over = false;
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    if (over) return;
    buf += chunk;
    if (buf.length > STDIN_MAX_BYTES) {
      over = true;
      buf = "";
    }
  });
  process.stdin.on("end", () => {
    let out;
    try {
      out = cliMain(over ? "" : buf);
    } catch (_) {
      out = render(activate([]));
    }
    process.stdout.write(out + "\n");
    process.exitCode = 0;
  });
} else {
  module.exports = {
    ASPECTS,
    MAX_PATHS,
    normalize,
    isDocumentation,
    isTest,
    classify,
    activate,
    render,
    cliMain,
  };
}
