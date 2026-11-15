#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const scope = require("./review-round-scope-v1.js");

const MAX_ENTRIES = 500;
const MAX_TEXT = 200;
const PROJECT_PREFIX = "<project>/";
const PREFIX = /^\s*(?:\[[^\]]*\]\s*)?FINDING LEDGER\b/;
const LINE = /^\s*(?:\[[^\]]*\]\s*)?FINDING LEDGER\s*[—–-]\s*(?:G([1-9][0-9]{0,4}):)?R([1-9][0-9]{0,5})-F([1-9][0-9]{0,4})\s+(routed|deferred|neutralized|parked|fixed)\s+(CRITICAL|IMPORTANT|SUGGESTION)\s+(\S+)\s*\|\s*(\S.*)$/;
const ANCHOR = /^(.+):([1-9][0-9]{0,6})(?:-[1-9][0-9]{0,6})?$/;
const SHELL_ACTIVE = /`|\$[({]/;
const REGISTRATIONS = new Set(["routed", "deferred", "neutralized"]);
const OPEN_STATES = new Set(["deferred", "parked", "routed-unfixed"]);
const LISTED = new Set(["ok", "partial"]);
const DEFECT_STATES = new Set(["routed-unfixed", "parked"]);
const BLOCKING_SEVERITIES = new Set(["CRITICAL", "IMPORTANT"]);
const CONVERGENCE_HEAD = "CONVERGENCE — ";
const LISTED_DEFECTS = 5;
const FINAL_REVIEW_HEAD = "FINAL REVIEW LEDGERED — R";
const FINAL_REVIEW = /^\s*(?:\[[^\]]*\]\s*)?FINAL REVIEW LEDGERED\s*[—–-]\s*R([1-9][0-9]{0,5})\s*$/;
const MAX_STATE_BYTES = 1048576;

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
  const carried = m[1] ? parseInt(m[1], 10) : 0;
  if (carried && m[4] !== "fixed") return { malformed: true };
  const anchor = parseAnchor(m[6]);
  if (anchor === null) return { malformed: true };
  let summary = m[7].trim();
  if (/[\u0000-\u001f\u007f]/.test(summary)) return { malformed: true };
  summary = inertText(summary);
  if (summary.length > MAX_TEXT) summary = summary.slice(0, MAX_TEXT - 1) + "…";
  const round = parseInt(m[2], 10);
  const index = parseInt(m[3], 10);
  const parsed = {
    malformed: false,
    id: (carried ? "G" + carried + ":" : "") + "R" + round + "-F" + index,
    round,
    index,
    disposition: m[4],
    severity: m[5],
    anchor,
    summary,
  };
  if (carried) parsed.carried = carried;
  return parsed;
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
  const carried = new Map();
  let maxRound = 0;
  let issue = "";
  let lost = "";
  const nextGeneration = () => {
    if (report) {
      for (const entry of entries.values()) {
        if (!OPEN_STATES.has(entry.state)) continue;
        const id = "G" + generation + ":" + entry.id;
        carried.set(id, Object.assign({}, entry, { id, generation }));
      }
    }
    generation += 1;
    entries = new Map();
    maxRound = 0;
  };
  for (const raw of text.split("\n")) {
    const line = raw.replace(/\r$/, "");
    if (scope.RESET.test(line)) {
      if (report && issue && !lost) lost = issue;
      nextGeneration();
      issue = "";
      continue;
    }
    const parsed = parseLedgerLine(line);
    if (parsed === null) continue;
    if (parsed.malformed) {
      issue = issue || "malformed-line";
      continue;
    }
    if (parsed.carried) {
      const earlier = carried.get(parsed.id);
      if (earlier) earlier.state = "fixed";
      continue;
    }
    let current = entries.get(parsed.id);
    if (REGISTRATIONS.has(parsed.disposition)) {
      let conflict = "";
      if (current) {
        if (current.state === "parked" && parsed.disposition === "deferred" && current.anchor === parsed.anchor) continue;
        if (current.state !== stateOf(parsed.disposition) || current.anchor !== parsed.anchor) conflict = "id-reused";
      } else if (parsed.round < maxRound) {
        conflict = "round-regression";
      }
      if (conflict) {
        issue = issue || conflict;
        if (report) {
          nextGeneration();
          current = undefined;
        }
      }
      if (parsed.round > maxRound) maxRound = parsed.round;
    }
    if (!current && entries.size + carried.size >= MAX_ENTRIES) {
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
  const byOrigin = (a, b) => (a.generation || 0) - (b.generation || 0) || a.round - b.round || a.index - b.index;
  const list = Array.from(carried.values()).sort(byOrigin).concat(Array.from(entries.values()).sort(byOrigin));
  const open = list.filter((entry) => OPEN_STATES.has(entry.state)).length;
  const earlier = lost ? { lost } : {};
  if (issue) return Object.assign({ status: "partial", reason: issue, generation, entries: list, open }, earlier);
  if (list.length === 0) {
    return Object.assign({ status: "empty", reason: "no-entries", generation, entries: [], open: 0 }, earlier);
  }
  return Object.assign({ status: "ok", reason: "", generation, entries: list, open }, earlier);
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

function openDefect(entry) {
  if (!entry || typeof entry !== "object") return false;
  if (DEFECT_STATES.has(entry.state)) return true;
  return entry.state === "deferred" && BLOCKING_SEVERITIES.has(entry.severity);
}

function notConverged(reason, text) {
  return { converged: false, reason, line: CONVERGENCE_HEAD + "not converged | " + text };
}

function ledgerText(logPath, root) {
  let rootReal;
  try {
    rootReal = fs.realpathSync.native(root);
  } catch (_) {
    return { ok: false, reason: "bad-root" };
  }
  return scope.readLog(logPath, rootReal);
}

function finalReviewLedgered(text, round) {
  let seen = false;
  for (const raw of String(text).split("\n")) {
    const line = raw.replace(/\r$/, "");
    if (scope.RESET.test(line)) {
      seen = false;
      continue;
    }
    const match = FINAL_REVIEW.exec(line);
    if (match && Number(match[1]) === round) seen = true;
  }
  return seen;
}

function convergence(options) {
  const opts = options || {};
  if (opts.enabled === false) {
    return notConverged("disabled", "hooks.reviewConvergence is off, so no findings ledger records what the reviews left open");
  }
  const finalRound = opts.finalRound;
  if (!Number.isSafeInteger(finalRound) || finalRound < 1) {
    return notConverged("final-round", "the chain's review round could not be read, so the review that met the cap cannot be matched to the findings ledger");
  }
  let receipts;
  try {
    receipts = require("./edit-landing-receipt-v1.js");
  } catch (_) {
    return notConverged("receipt-reader", "the edit-landing receipt reader could not be loaded, so no run log is bound to this chain");
  }
  const bound = receipts.receiptRunLog({
    receiptPath: typeof opts.receipt === "string" ? opts.receipt : "",
    projectRoot: typeof opts.projectRoot === "string" ? opts.projectRoot : "",
  });
  if (bound.status === "absent") {
    return notConverged("no-receipt", "this session has no edit-landing receipt, so no run log is bound to this chain");
  }
  if (bound.status !== "ok") {
    return notConverged("receipt", (bound.reason || "the edit-landing receipt names no usable run log") + ", so no run log is bound to this chain");
  }
  const read = ledgerText(path.join(bound.root, ...bound.logRel.split("/")), bound.root);
  if (!read.ok) {
    return notConverged(
      "ledger-degraded",
      "the findings ledger of the run log the edit-landing receipt names answered status=degraded (" + read.reason + ")"
    );
  }
  const report = ledgerState({ text: read.text, report: true });
  if (report.status === "empty") {
    return notConverged("ledger-empty", "the findings ledger of the run log the edit-landing receipt names holds no entry, so nothing records what the reviews left open");
  }
  if (report.status !== "ok") {
    return notConverged(
      "ledger-" + report.status,
      "the findings ledger of the run log the edit-landing receipt names answered status=" + report.status + " (" + report.reason + ")"
    );
  }
  if (report.lost) {
    return notConverged(
      "ledger-lost",
      "the findings ledger of the run log the edit-landing receipt names could not read a line before its last review budget reset (" + report.lost + ")"
    );
  }
  const open = report.entries.filter(openDefect);
  if (open.length > 0) {
    const listed = open.slice(0, LISTED_DEFECTS).map((entry) => entry.id + " " + entry.state + " " + entry.severity);
    if (open.length > LISTED_DEFECTS) listed.push("…");
    return notConverged(
      "open-defects",
      "the findings ledger holds " + open.length + " open defect" + (open.length === 1 ? "" : "s") + ": " + listed.join(", ")
    );
  }
  if (!finalReviewLedgered(read.text, finalRound)) {
    return notConverged(
      "final-review-unledgered",
      "no '" + FINAL_REVIEW_HEAD + finalRound + "' line follows the last review budget reset, so the findings of the review that met the cap may never have reached the ledger"
    );
  }
  const deferred = report.entries.filter((entry) => OPEN_STATES.has(entry.state)).length;
  return {
    converged: true,
    reason: "converged",
    line:
      CONVERGENCE_HEAD +
      "converged | the findings ledger holds no routed-unfixed or parked entry and no deferred IMPORTANT or CRITICAL entry (" +
      report.entries.length +
      " entries, " +
      deferred +
      " deferred suggestion" +
      (deferred === 1 ? "" : "s") +
      " still open)",
  };
}

function reviewRoundOf(file) {
  if (typeof file !== "string" || file === "") return null;
  let receipts;
  try {
    receipts = require("./edit-landing-receipt-v1.js");
  } catch (_) {
    return null;
  }
  const loaded = receipts.readBoundedJson(file, MAX_STATE_BYTES);
  if (!loaded || !loaded.value || typeof loaded.value !== "object") return null;
  const value = loaded.value.reviewRound;
  return Number.isSafeInteger(value) && value >= 1 ? value : null;
}

function convergenceMain(env, stdout) {
  const source = env || process.env;
  const out = stdout || process.stdout;
  let verdict;
  try {
    verdict = convergence({
      receipt: source.ZENSU_RL_RECEIPT || "",
      projectRoot: source.ZENSU_RL_PROJECT_ROOT || "",
      enabled: source.ZENSU_RL_CONVERGENCE !== "off",
      finalRound: reviewRoundOf(source.ZENSU_RL_STATE || ""),
    });
  } catch (_) {
    verdict = notConverged("fault", "the convergence check failed inside review-ledger-v1.js");
  }
  out.write(verdict.line);
  return verdict.converged ? 0 : 3;
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
    CONVERGENCE_HEAD,
    FINAL_REVIEW_HEAD,
    openDefect,
    finalReviewLedgered,
    reviewRoundOf,
    convergence,
    convergenceMain,
  };
}
