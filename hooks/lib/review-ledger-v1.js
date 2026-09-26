#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const scope = require("./review-round-scope-v1.js");

const MAX_ENTRIES = 500;
const MAX_TEXT = 200;
const PROJECT_PREFIX = "<project>/";
const PREFIX = /^\s*(?:\[[^\]]*\]\s*)?FINDING LEDGER\b/;
const LINE = /^\s*(?:\[[^\]]*\]\s*)?FINDING LEDGER\s*[—–-]\s*R([1-9][0-9]{0,5})-F([1-9][0-9]{0,4})\s+(routed|deferred|neutralized|fixed)\s+(CRITICAL|IMPORTANT|SUGGESTION)\s+(\S+)\s*\|\s*(\S.*)$/;
const ANCHOR = /^(.+):([1-9][0-9]{0,6})(?:-[1-9][0-9]{0,6})?$/;
const SHELL_ACTIVE = /`|\$[({]/;
const REGISTRATIONS = new Set(["routed", "deferred", "neutralized"]);
const OPEN_STATES = new Set(["deferred", "routed-unfixed"]);
const LISTED = new Set(["ok", "partial"]);

function parseAnchor(raw) {
  const value = String(raw == null ? "" : raw);
  if (value === "-") return "-";
  const m = ANCHOR.exec(value);
  if (!m) return null;
  let file = m[1];
  if (SHELL_ACTIVE.test(file)) return null;
  if (file.startsWith(PROJECT_PREFIX)) file = file.slice(PROJECT_PREFIX.length);
  if (/^(?:~|<home>)(?:[\\/]|$)/.test(file)) return null;
  const rel = scope.safeRelativePath(file);
  if (rel === null) return null;
  return rel + ":" + m[2];
}

function inertText(text) {
  return String(text).replace(/`/g, "'").replace(/\$(?=[({])/g, "$ ");
}

function parseLedgerLine(line) {
  const text = String(line == null ? "" : line).replace(/\r$/, "");
  if (!PREFIX.test(text)) return null;
  const m = LINE.exec(text);
  if (!m) return { malformed: true };
  const anchor = parseAnchor(m[5]);
  if (anchor === null) return { malformed: true };
  let summary = m[6].trim();
  if (/[\u0000-\u001f\u007f]/.test(summary)) return { malformed: true };
  summary = inertText(summary);
  if (summary.length > MAX_TEXT) summary = summary.slice(0, MAX_TEXT - 1) + "…";
  const round = parseInt(m[1], 10);
  const index = parseInt(m[2], 10);
  return {
    malformed: false,
    id: "R" + round + "-F" + index,
    round,
    index,
    disposition: m[3],
    severity: m[4],
    anchor,
    summary,
  };
}

function degraded(reason, generation) {
  return { status: "degraded", reason, generation: generation || 0, entries: [], open: 0 };
}

function stateOf(disposition) {
  return disposition === "routed" ? "routed-unfixed" : disposition;
}

function ledgerState(options) {
  const opts = options || {};
  const report = opts.report === true;
  let rootReal = "";
  if (typeof opts.root === "string" && opts.root.trim() !== "") {
    try {
      rootReal = fs.realpathSync.native(opts.root);
    } catch (_) {
      return degraded("bad-root", 0);
    }
  }
  let text = opts.text;
  if (typeof text !== "string") {
    const read = scope.readLog(opts.log, rootReal);
    if (!read.ok) return degraded(read.reason, 0);
    text = read.text;
  }
  let generation = 1;
  let entries = new Map();
  let maxRound = 0;
  let issue = "";
  for (const raw of text.split("\n")) {
    const line = raw.replace(/\r$/, "");
    if (scope.RESET.test(line)) {
      generation += 1;
      entries = new Map();
      maxRound = 0;
      issue = "";
      continue;
    }
    const parsed = parseLedgerLine(line);
    if (parsed === null) continue;
    if (parsed.malformed) {
      issue = issue || "malformed-line";
      continue;
    }
    const current = entries.get(parsed.id);
    if (REGISTRATIONS.has(parsed.disposition)) {
      if (parsed.round < maxRound) issue = issue || "round-regression";
      else maxRound = parsed.round;
      if (current && current.state !== stateOf(parsed.disposition)) issue = issue || "id-reused";
    }
    if (!current && entries.size >= MAX_ENTRIES) {
      issue = issue || "truncated";
      continue;
    }
    entries.set(parsed.id, {
      id: parsed.id,
      round: parsed.round,
      index: parsed.index,
      state: stateOf(parsed.disposition),
      severity: parsed.severity,
      anchor: parsed.anchor,
      summary: parsed.summary,
    });
  }
  if (issue && !report) return degraded(issue, generation);
  const list = Array.from(entries.values()).sort((a, b) => a.round - b.round || a.index - b.index);
  const open = list.filter((entry) => OPEN_STATES.has(entry.state)).length;
  if (issue) return { status: "partial", reason: issue, generation, entries: list, open };
  if (list.length === 0) {
    return { status: "empty", reason: "no-entries", generation, entries: [], open: 0 };
  }
  return { status: "ok", reason: "", generation, entries: list, open };
}

function render(report) {
  const listed = LISTED.has(report.status);
  const lines = [];
  if (listed) {
    for (const entry of report.entries) {
      lines.push(
        "entry " + entry.id + " " + entry.state + " " + entry.severity + " " + entry.anchor + " | " + entry.summary
      );
    }
  }
  let summary =
    "summary status=" +
    report.status +
    " generation=" +
    report.generation +
    " entries=" +
    (listed ? report.entries.length : 0) +
    " open=" +
    (listed ? report.open : 0);
  if (report.status !== "ok") summary += " reason=" + report.reason;
  lines.push(summary);
  return lines.join("\n");
}

function parseArgs(argv) {
  let log = "";
  let root = "";
  let report = false;
  for (let i = 0; i < argv.length; i++) {
    const arg = String(argv[i]);
    const next = argv[i + 1] === undefined ? "" : String(argv[i + 1]);
    if (arg === "--log") {
      log = next;
      i++;
    } else if (arg === "--root") {
      root = next;
      i++;
    } else if (arg === "--report") {
      report = true;
    }
  }
  return { log, root, report };
}

function cliMain(argv) {
  const args = parseArgs(argv || []);
  return render(ledgerState({ log: args.log, root: args.root, report: args.report }));
}

if (require.main === module) {
  let out;
  try {
    out = cliMain(process.argv.slice(2));
  } catch (_) {
    out = "summary status=degraded generation=0 entries=0 open=0 reason=internal";
  }
  process.stdout.write(out + "\n");
  process.exitCode = 0;
} else {
  module.exports = {
    LINE,
    PREFIX,
    MAX_ENTRIES,
    MAX_TEXT,
    parseAnchor,
    parseLedgerLine,
    ledgerState,
    render,
    cliMain,
  };
}
