"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");

const lib = require(path.join(__dirname, "..", "..", "hooks", "lib", "round-prepare-v1.js"));
const ledgerLib = require(path.join(__dirname, "..", "..", "hooks", "lib", "review-ledger-v1.js"));

function tempDir() {
  return fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), "round-prepare-")));
}

function project() {
  const top = tempDir();
  fs.mkdirSync(path.join(top, ".zensu", "state"), { recursive: true });
  fs.mkdirSync(path.join(top, ".zensu", "logs"), { recursive: true });
  return {
    top,
    log: path.join(top, ".zensu", "logs", "run.log"),
    snapshot: path.join(top, ".zensu", "state", "round-snapshot-test.json"),
    changes: path.join(top, ".zensu", "state", "changes.txt"),
    audit: path.join(top, ".zensu", "state", "audit.txt"),
  };
}

function sha(text) {
  return "sha256:" + crypto.createHash("sha256").update(text).digest("hex");
}

function pendingLine(step, file) {
  return (
    "PENDING PREDICATE — " + step + ": " + file +
    " was already dirty before this round; union membership is not evidence — re-read the target predicate"
  );
}

function input(p, round, extra) {
  return Object.assign(
    {
      round,
      top: p.top,
      log: p.log,
      snapshotFile: p.snapshot,
      changeSetFile: p.changes,
      auditFile: p.audit,
      incremental: true,
      activation: true,
      convergence: true,
      panel: "lean",
      now: 1000,
    },
    extra || {}
  );
}

test("parseRound accepts 0, a fix round number and self-review, and nothing else", () => {
  assert.deepEqual(lib.parseRound("0"), { kind: "first", label: "0", number: 0 });
  assert.deepEqual(lib.parseRound("3"), { kind: "fix", label: "3", number: 3 });
  assert.deepEqual(lib.parseRound("999999"), { kind: "fix", label: "999999", number: 999999 });
  assert.deepEqual(lib.parseRound("self-review"), { kind: "self-review", label: "self-review", number: null });
  for (const bad of ["", "-1", "01", "1000000", "1.0", "SR", "self", " 1", null, undefined]) {
    assert.equal(lib.parseRound(bad), null, String(bad));
  }
});

test("a claim label names a finding id only inside its own round", () => {
  const two = lib.parseRound("2");
  assert.equal(lib.findingIdOf("R2-F3", two), "R2-F3");
  assert.equal(lib.findingIdOf("R2-R1-F4", two), "R1-F4");
  assert.equal(lib.findingIdOf("R2", two), null);
  assert.equal(lib.findingIdOf("R2-fix", two), null);
  assert.equal(lib.findingIdOf("R1-F3", two), null);
  assert.equal(lib.findingIdOf("R22-F1", two), null);
  assert.equal(lib.labelInRound("R2", two), true);
  assert.equal(lib.labelInRound("R22-F1", two), false);
  const sr = lib.parseRound("self-review");
  assert.equal(lib.findingIdOf("SR-R2-F1", sr), "R2-F1");
  assert.equal(lib.findingIdOf("SR-F1", sr), null);
  assert.equal(lib.labelInRound("S1", sr), false);
  assert.equal(lib.labelInRound("R1-F1", lib.parseRound("0")), false);
});

test("audit verdict lines parse into kind, step and file", () => {
  assert.deepEqual(lib.parseAuditLine("EDIT LANDED — R1-F1: hooks/a.sh"), {
    kind: "landed",
    step: "R1-F1",
    file: "hooks/a.sh",
    line: "EDIT LANDED — R1-F1: hooks/a.sh",
  });
  const notLanded = lib.parseAuditLine("EDIT NOT LANDED — R1-F2: claimed docs/x.md, git shows no change");
  assert.equal(notLanded.kind, "not-landed");
  assert.equal(notLanded.file, "docs/x.md");
  const pending = lib.parseAuditLine(
    "PENDING PREDICATE — R1-F3: src/b.js was already dirty before this round; union membership is not evidence — re-read the target predicate"
  );
  assert.equal(pending.kind, "pending");
  assert.equal(pending.file, "src/b.js");
  const outside = lib.parseAuditLine(
    "PENDING PREDICATE — R1-F3: src/b.js mtime is newer than session start, but this is not a git work tree — re-read the target predicate"
  );
  assert.equal(outside.kind, "pending-outside-git");
  const foreign = lib.parseAuditLine('UNVERIFIED (foreign root) — R1-F4: claimed "x" resolves outside the audited root /r');
  assert.equal(foreign.kind, "unverified");
  assert.equal(foreign.step, "R1-F4");
  const bare = lib.parseAuditLine(
    "UNVERIFIED — a WIRED entry at run-log line 7 (step R1-W) names no files: list and cannot be graded"
  );
  assert.equal(bare.kind, "unverified");
  assert.equal(bare.step, "R1-W");
  const none = lib.parseAuditLine(
    "UNVERIFIED (no claims logged) — the run log holds no IMPL/WIRED files: entry, so nothing could be audited"
  );
  assert.equal(none.kind, "no-claims");
  assert.equal(lib.parseAuditLine("EDIT LANDED (untracked-by-design) — build/out.js"), null);
  assert.equal(lib.parseAuditLine("EDIT LANDING AUDIT — claims=1 landed=1 not_landed=0 unverified=0 pending=0"), null);
});

test("a file digest names its content, its absence, a directory and a link", () => {
  const dir = tempDir();
  fs.writeFileSync(path.join(dir, "a.txt"), "alpha");
  fs.mkdirSync(path.join(dir, "sub"));
  fs.symlinkSync("a.txt", path.join(dir, "link"));
  assert.equal(lib.digestFile(dir, "a.txt"), sha("alpha"));
  assert.equal(lib.digestFile(dir, "gone.txt"), "absent");
  assert.equal(lib.digestFile(dir, "sub"), "directory");
  assert.match(lib.digestFile(dir, "link"), /^link:[0-9a-f]{64}$/);
  const all = lib.digestFiles(dir, ["a.txt", "../escape", ".zensu/state/x.json", "/abs", "a.txt"]);
  assert.deepEqual(Object.keys(all.files), ["a.txt", ".zensu/state/x.json"]);
  assert.equal(all.files[".zensu/state/x.json"], "absent");
  assert.equal(all.truncated, 0);
});

test("a path past the hash bound or with no digest is recorded unhashed, and one past the record bound is counted", () => {
  const dir = tempDir();
  const big = path.join(dir, "big.bin");
  fs.writeFileSync(big, "");
  fs.truncateSync(big, lib.LIMITS.maxFileBytes + 1);
  assert.equal(lib.digestFile(dir, "big.bin"), null);
  assert.equal(lib.digestFiles(dir, ["big.bin"]).files["big.bin"], "unhashed");
  fs.unlinkSync(big);
  const names = Array.from({ length: lib.LIMITS.maxRecorded + 2 }, (_, index) => "f" + index);
  const all = lib.digestFiles(dir, names);
  assert.equal(Object.keys(all.files).length, lib.LIMITS.maxRecorded);
  assert.equal(all.truncated, 2);
  assert.equal(all.files["f" + (lib.LIMITS.maxFiles - 1)], "absent");
  assert.equal(all.files["f" + lib.LIMITS.maxFiles], "unhashed");
});

test("a snapshot round-trips, keeps the newest rounds and refuses a foreign or broken file", () => {
  const p = project();
  const chain = { name: "run.log", generation: 0, lastFixRound: 5 };
  let doc = null;
  for (let round = 0; round <= 5; round += 1) {
    doc = lib.recordRound(doc, p.top, chain, String(round), { at: round, baseline: "", files: { "a.txt": "absent" }, truncated: 0 });
  }
  assert.deepEqual(Object.keys(doc.rounds).sort(), ["2", "3", "4", "5"]);
  assert.equal(doc.log, "run.log");
  assert.equal(doc.generation, 0);
  assert.equal(lib.writeSnapshot(p.snapshot, doc).ok, true);
  const read = lib.readSnapshot(p.snapshot, p.top);
  assert.equal(read.ok, true);
  assert.equal(lib.resolveStart(read, lib.parseRound("5"), chain).entry.at, 4);
  assert.equal(lib.resolveStart(read, lib.parseRound("self-review"), chain).entry.at, 5);
  assert.deepEqual(lib.resolveStart(read, lib.parseRound("2"), chain), { entry: null, reason: "no entry for round 1" });
  assert.equal(lib.resolveStart(read, lib.parseRound("0"), chain).reason, "round-0");
  assert.equal(lib.resolveStart(read, lib.parseRound("5"), chain, "020c6fe52c8e1ead9f9608914f961186a39e38b4").reason, "other-baseline");
  assert.equal(lib.readSnapshot(p.snapshot, p.top + "-other").reason, "other-work-tree");
  fs.writeFileSync(p.snapshot, "{not json");
  assert.equal(lib.readSnapshot(p.snapshot, p.top).reason, "unparseable");
  fs.writeFileSync(p.snapshot, JSON.stringify({ schema: lib.SCHEMA, top: p.top, rounds: {} }));
  assert.equal(lib.readSnapshot(p.snapshot, p.top).reason, "unknown-schema");
  fs.writeFileSync(p.snapshot, JSON.stringify({ schema: lib.SCHEMA, top: p.top, log: "logs/run.log", generation: 0, rounds: {} }));
  assert.equal(lib.readSnapshot(p.snapshot, p.top).reason, "unknown-schema");
  fs.writeFileSync(p.snapshot, JSON.stringify({ schema: lib.SCHEMA, top: p.top, log: "run.log", generation: -1, rounds: {} }));
  assert.equal(lib.readSnapshot(p.snapshot, p.top).reason, "unknown-schema");
  fs.writeFileSync(p.snapshot, JSON.stringify({ schema: lib.SCHEMA, top: p.top, log: "run.log", generation: 0, rounds: { x: {} } }));
  assert.equal(lib.readSnapshot(p.snapshot, p.top).reason, "malformed");
  fs.writeFileSync(p.snapshot, JSON.stringify({ schema: lib.SCHEMA, top: p.top, log: "run.log", generation: 0, rounds: { 1: { at: 1, files: {}, truncated: 0 } } }));
  assert.equal(lib.readSnapshot(p.snapshot, p.top).reason, "malformed");
  assert.equal(lib.readSnapshot(path.join(p.top, "none.json"), p.top).reason, "missing");
  fs.unlinkSync(p.snapshot);
  fs.symlinkSync(path.join(p.top, "elsewhere.json"), p.snapshot);
  assert.equal(lib.writeSnapshot(p.snapshot, doc).ok, false);
  assert.equal(fs.existsSync(path.join(p.top, "elsewhere.json")), false);
});

test("round 0, another run log, another generation or another work tree starts a fresh snapshot", () => {
  const chain = { name: "run.log", generation: 0 };
  const entry = (at) => ({ at, baseline: "", files: {}, truncated: 0 });
  let doc = lib.recordRound(null, "/top", chain, "0", entry(0));
  doc = lib.recordRound(doc, "/top", chain, "1", entry(1));
  assert.deepEqual(Object.keys(doc.rounds).sort(), ["0", "1"]);
  assert.deepEqual(Object.keys(lib.recordRound(doc, "/top", chain, "0", entry(2)).rounds), ["0"]);
  assert.deepEqual(Object.keys(lib.recordRound(doc, "/top", { name: "other.log", generation: 0 }, "2", entry(2)).rounds), ["2"]);
  assert.deepEqual(Object.keys(lib.recordRound(doc, "/elsewhere", chain, "2", entry(2)).rounds), ["2"]);
  const reset = lib.recordRound(doc, "/top", { name: "run.log", generation: 1 }, "1", entry(3));
  assert.deepEqual(Object.keys(reset.rounds), ["1"]);
  assert.equal(reset.generation, 1);
});

test("a round-start snapshot of another run log or review generation is not used", () => {
  const chain = { name: "run.log", generation: 1, lastFixRound: 2 };
  let doc = lib.recordRound(null, "/top", chain, "0", { at: 0, baseline: "", files: {}, truncated: 0 });
  doc = lib.recordRound(doc, "/top", chain, "1", { at: 1, baseline: "", files: {}, truncated: 0 });
  const read = { ok: true, doc };
  assert.equal(lib.resolveStart(read, lib.parseRound("2"), chain).entry.at, 1);
  assert.equal(lib.resolveStart(read, lib.parseRound("2"), Object.assign({}, chain, { name: "other.log" })).reason, "other-chain");
  assert.equal(lib.resolveStart(read, lib.parseRound("2"), Object.assign({}, chain, { generation: 2 })).reason, "other-generation");
  assert.equal(lib.resolveStart(read, lib.parseRound("self-review"), chain).reason, "no entry for round 2");
  assert.equal(lib.resolveStart(read, lib.parseRound("self-review"), Object.assign({}, chain, { lastFixRound: 1 })).entry.at, 1);
  assert.equal(lib.resolveStart({ ok: false, reason: "missing" }, lib.parseRound("1"), chain).reason, "missing");
});

test("the chain read counts reset generations, splits the claims at the last reset and finds the last fix round", () => {
  const p = project();
  writeLog(p, [
    "S1 IMPL completed — files: a.js",
    "R1-F1 IMPL completed — files: a.js",
    "EDIT LANDING AUDIT STARTED — round fix-3",
    "CLAIM WITHDRAWN — R1-F1: a.js",
    "REVIEW BUDGET RESET — review rounds restart at 1",
    "[2026-10-27 10:00:00] R1-F1 IMPL completed — files: b.js",
    "R1-F2 IMPL completed — files: c.js",
    "CLAIM WITHDRAWN — R1-F2: c.js",
    "[2026-10-27 10:01:00] CLAIM WITHDRAWN — R1-F9",
    "EDIT LANDING AUDIT STARTED — round fix-2",
    "EDIT LANDING AUDIT STARTED — round self-review",
    "SR-R1-F1 IMPL completed — files: a.js",
  ]);
  const chain = lib.chainOf(p.log);
  assert.equal(chain.name, "run.log");
  assert.equal(chain.generation, 1);
  assert.deepEqual(Array.from(chain.preReset), ["S1", "R1-F1"]);
  assert.deepEqual(Array.from(chain.postFiles.get("R1-F1")), ["b.js"]);
  assert.deepEqual(Array.from(chain.fixStarts.entries()), [[2, 9]]);
  assert.deepEqual(Array.from(chain.postClaims.entries()), [["R1-F1", 5], ["R1-F2", 6], ["SR-R1-F1", 11]]);
  assert.deepEqual(chain.withdrawals, [
    { label: "R1-F2", file: "c.js", index: 7 },
    { label: "R1-F9", file: null, index: 8 },
  ]);
  assert.equal(chain.lastFixRound, 2);
  writeLog(p, ["R3-F1 IMPL completed — files: a.js"]);
  assert.equal(lib.chainOf(p.log).lastFixRound, 3);
  assert.equal(lib.chainOf(p.log).generation, 0);
});

test("landing in a round compares each dirty claimed file with the round-start snapshot", () => {
  const round = lib.parseRound("1");
  const start = { at: 0, truncated: 0, files: { "src/edited.js": "sha256:old", "src/same.js": "sha256:same" } };
  const current = { "src/edited.js": "sha256:new", "src/same.js": "sha256:same", "src/new.js": "sha256:n" };
  const lines = [
    "EDIT LANDED — R1-F1: src/new.js",
    "PENDING PREDICATE — R1-F1: src/edited.js was already dirty before this round; union membership is not evidence — re-read the target predicate",
    "PENDING PREDICATE — R1-F2: src/same.js was already dirty before this round; union membership is not evidence — re-read the target predicate",
    "PENDING PREDICATE — S1: src/edited.js was already dirty before this round; union membership is not evidence — re-read the target predicate",
    "EDIT NOT LANDED — S2: claimed docs/gone.md, git shows no change",
    "EDIT LANDED — S3: src/new.js",
  ];
  const result = lib.resolveLanding({ auditLines: lines, round, start, current });
  const byStep = Object.fromEntries(result.steps.map((step) => [step.step, step.state]));
  assert.deepEqual(byStep, { "R1-F1": "landed", "R1-F2": "not-landed" });
  assert.equal(result.otherPending, 1);
  assert.ok(result.carried.includes("EDIT NOT LANDED — S2: claimed docs/gone.md, git shows no change"));
  assert.ok(!result.carried.some((line) => line.startsWith("EDIT LANDED")));
});

test("without a round-start snapshot no claim of the round counts as landed", () => {
  const round = lib.parseRound("1");
  const result = lib.resolveLanding({
    auditLines: ["EDIT LANDED — R1-F1: src/new.js"],
    round,
    start: null,
    current: { "src/new.js": "sha256:n" },
  });
  assert.equal(result.steps[0].state, "unresolved");
  const missingHash = lib.resolveLanding({
    auditLines: [
      "PENDING PREDICATE — R1-F1: src/x.js was already dirty before this round; union membership is not evidence — re-read the target predicate",
    ],
    round,
    start: { at: 0, truncated: 0, files: {} },
    current: { "src/x.js": "sha256:x" },
  });
  assert.equal(missingHash.steps[0].state, "unresolved");
});

test("a digest that names no content leaves a claim unresolved, and so does a new file against a truncated start", () => {
  const round = lib.parseRound("1");
  const start = { at: 0, truncated: 0, files: { "a.js": "unhashed", dir: "directory", "b.js": "sha256:b", "c.js": "absent" } };
  const current = { "a.js": "sha256:a2", dir: "directory", "b.js": "unhashed", "c.js": "sha256:c" };
  const result = lib.resolveLanding({
    auditLines: [pendingLine("R1-F1", "a.js"), pendingLine("R1-F2", "dir"), pendingLine("R1-F3", "b.js"), pendingLine("R1-F4", "c.js")],
    round,
    start,
    current,
  });
  const byStep = Object.fromEntries(result.steps.map((step) => [step.step, step.state]));
  assert.deepEqual(byStep, { "R1-F1": "unresolved", "R1-F2": "unresolved", "R1-F3": "unresolved", "R1-F4": "landed" });
  const landed = ["EDIT LANDED — R1-F1: new.js"];
  const truncated = lib.resolveLanding({ auditLines: landed, round, start: { at: 0, truncated: 3, files: {} }, current: { "new.js": "sha256:n" } });
  assert.equal(truncated.steps[0].state, "unresolved");
  const complete = lib.resolveLanding({ auditLines: landed, round, start: { at: 0, truncated: 0, files: {} }, current: { "new.js": "sha256:n" } });
  assert.equal(complete.steps[0].state, "landed");
});

test("a claim withdrawn after it was logged is withdrawn, and a withdrawal logged before the claim is not", () => {
  const p = project();
  writeLog(p, [
    "CLAIM WITHDRAWN — R1-F3: c.js",
    "R1-F1 IMPL completed — files: a.js, b.js",
    "R1-F2 IMPL completed — files: c.js",
    "R1-F3 IMPL completed — files: c.js",
    "CLAIM WITHDRAWN — R1-F1: b.js",
    "CLAIM WITHDRAWN — R1-F2",
  ]);
  const result = lib.resolveLanding({
    auditLines: [
      pendingLine("R1-F1", "a.js"),
      pendingLine("R1-F1", "b.js"),
      "EDIT NOT LANDED — R1-F2: claimed c.js, git shows no change",
      "EDIT NOT LANDED — R1-F3: claimed c.js, git shows no change",
    ],
    round: lib.parseRound("1"),
    start: { at: 0, truncated: 0, files: { "a.js": "sha256:a", "b.js": "sha256:b" } },
    current: { "a.js": "sha256:a2", "b.js": "sha256:b" },
    chain: lib.chainOf(p.log),
  });
  const byStep = Object.fromEntries(result.steps.map((step) => [step.step, step]));
  assert.equal(byStep["R1-F1"].state, "landed");
  assert.deepEqual(byStep["R1-F1"].files.map((item) => item.outcome), ["landed", "withdrawn"]);
  assert.equal(byStep["R1-F2"].state, "withdrawn");
  assert.equal(byStep["R1-F3"].state, "not-landed");
});

test("a dirty file whose content changed back to the committed one in this round counts as landed", () => {
  const round = lib.parseRound("1");
  const start = { at: 0, truncated: 0, files: { "a.js": "sha256:dirty", "b.js": "sha256:same" } };
  const now = { "a.js": "sha256:committed", "b.js": "sha256:same" };
  const auditLines = [
    "EDIT NOT LANDED — R1-F1: claimed a.js, git shows no change",
    "EDIT NOT LANDED — R1-F2: claimed b.js, git shows no change",
    "EDIT NOT LANDED — R1-F3: claimed c.js, git shows no change",
  ];
  const result = lib.resolveLanding({ auditLines, round, start, current: {}, digestNow: (rel) => now[rel] || "absent" });
  const byStep = Object.fromEntries(result.steps.map((step) => [step.step, step.state]));
  assert.deepEqual(byStep, { "R1-F1": "landed", "R1-F2": "not-landed", "R1-F3": "not-landed" });
  assert.equal(result.carried.length, 3);
  const blind = lib.resolveLanding({ auditLines, round, start, current: {} });
  assert.equal(blind.steps[0].state, "not-landed");
});

test("one changed file that two labels of the round claim leaves both unresolved", () => {
  const result = lib.resolveLanding({
    auditLines: [pendingLine("R2-F1", "a.js"), pendingLine("R2-R1-F3", "a.js"), pendingLine("R2-F2", "b.js")],
    round: lib.parseRound("2"),
    start: { at: 0, truncated: 0, files: { "a.js": "sha256:a", "b.js": "sha256:b" } },
    current: { "a.js": "sha256:a2", "b.js": "sha256:b2" },
  });
  const byStep = Object.fromEntries(result.steps.map((step) => [step.step, step]));
  assert.equal(byStep["R2-F1"].state, "unresolved");
  assert.equal(byStep["R2-R1-F3"].state, "unresolved");
  assert.equal(byStep["R2-F1"].files[0].shared, true);
  assert.equal(byStep["R2-F2"].state, "landed");
});

test("a label claimed only before a review budget reset is an earlier claim, and one claimed on both sides is graded by its post-reset files", () => {
  const p = project();
  writeLog(p, [
    "R1-F1 IMPL completed — files: a.js",
    "R1-F2 IMPL completed — files: b.js, d.js",
    "REVIEW BUDGET RESET — review rounds restart at 1",
    "R1-F2 IMPL completed — files: ./b.js",
    "R1-F3 IMPL completed — files: c.js",
  ]);
  const options = {
    round: lib.parseRound("1"),
    start: { at: 0, baseline: "", truncated: 0, files: { "a.js": "sha256:a", "b.js": "sha256:b", "c.js": "sha256:c", "d.js": "sha256:d" } },
    current: { "a.js": "sha256:a2", "b.js": "sha256:b", "c.js": "sha256:c2", "d.js": "sha256:d" },
    chain: lib.chainOf(p.log),
  };
  const result = lib.resolveLanding(
    Object.assign({ auditLines: [pendingLine("R1-F1", "a.js"), pendingLine("R1-F2", "b.js"), pendingLine("R1-F2", "d.js"), pendingLine("R1-F3", "c.js")] }, options)
  );
  const byStep = Object.fromEntries(result.steps.map((step) => [step.step, step]));
  assert.equal(byStep["R1-F2"].state, "not-landed");
  assert.deepEqual(byStep["R1-F2"].files, [{ file: "b.js", outcome: "unchanged" }]);
  assert.equal(byStep["R1-F3"].state, "landed");
  assert.equal(byStep["R1-F1"], undefined);
  assert.equal(result.otherPending, 2);
  const blind = lib.resolveLanding(
    Object.assign({ auditLines: ["UNVERIFIED — a WIRED entry at run-log line 4 (step R1-F2) names no files: list and cannot be graded"] }, options)
  );
  assert.equal(blind.steps[0].state, "unresolved");
});

function ledger(lines) {
  const top = tempDir();
  const log = path.join(top, "run.log");
  fs.writeFileSync(log, lines.join("\n") + "\n");
  return ledgerLib.ledgerState({ log, root: top });
}

test("a fixed ledger line is written only for an open entry a landed claim of the round names", () => {
  const round = lib.parseRound("2");
  const state = ledger([
    "FINDING LEDGER — R1-F1 routed CRITICAL src/a.js:3 | first",
    "FINDING LEDGER — R1-F2 parked IMPORTANT src/b.js:4 | second",
    "FINDING LEDGER — R1-F3 routed CRITICAL src/f.js:8 | sixth",
    "FINDING LEDGER — R1-F3 fixed CRITICAL src/f.js:8 | sixth",
    "FINDING LEDGER — R1-F4 deferred SUGGESTION src/g.js:9 | seventh",
    "FINDING LEDGER — R2-F1 routed CRITICAL src/c.js:5 | third",
    "FINDING LEDGER — R2-F2 neutralized IMPORTANT src/d.js:6 | fourth",
    "FINDING LEDGER — R2-F3 deferred SUGGESTION src/e.js:7 | fifth",
  ]);
  assert.equal(state.status, "ok");
  const steps = [
    { step: "R2-F1", state: "landed" },
    { step: "R2-R1-F2", state: "landed" },
    { step: "R2-F2", state: "landed" },
    { step: "R2-F3", state: "not-landed" },
    { step: "R2-R1-F1", state: "unresolved" },
    { step: "R2-cleanup", state: "landed" },
    { step: "R2-F9", state: "landed" },
    { step: "R2-F1", state: "landed" },
    { step: "R2-R1-F3", state: "landed" },
    { step: "R2-R1-F4", state: "landed" },
  ];
  const result = lib.fixedLines({ round, ledger: state, steps });
  assert.deepEqual(result.fixedIds, ["R2-F1", "R1-F2", "R1-F4"]);
  assert.deepEqual(result.lines, [
    "FINDING LEDGER — R2-F1 fixed CRITICAL src/c.js:5 | third",
    "FINDING LEDGER — R1-F2 fixed IMPORTANT src/b.js:4 | second",
    "FINDING LEDGER — R1-F4 fixed SUGGESTION src/g.js:9 | seventh",
  ]);
  assert.ok(result.notes.some((note) => note.includes("R1-F3 is fixed, so no fixed line was written")));
  for (const line of result.lines) {
    const parsed = ledgerLib.parseLedgerLine(line);
    assert.equal(parsed.malformed, false);
    assert.equal(parsed.disposition, "fixed");
  }
  assert.ok(result.notes.some((note) => note.includes("R2-F2 is neutralized")));
  assert.ok(result.notes.some((note) => note.includes("R2-cleanup names no ledger id")));
  assert.ok(result.notes.some((note) => note.includes("R2-F9, which has no ledger entry")));
});

test("a ledger that is not ok writes no fixed line and says why", () => {
  const result = lib.fixedLines({
    round: lib.parseRound("1"),
    ledger: { status: "degraded", reason: "malformed-line", entries: [] },
    steps: [{ step: "R1-F1", state: "landed" }],
  });
  assert.deepEqual(result.lines, []);
  assert.equal(result.ledgerStatus, "degraded (malformed-line)");
  assert.equal(lib.fixedLines({ round: lib.parseRound("1"), ledger: null, steps: [] }).ledgerStatus, "unavailable (unread)");
});

test("the panel narrows to the round delta plus open anchors only on an ok scope", () => {
  const changeSet = ["src/a.js", "src/b.js", "docs/c.md", ".zensu/logs/run.log"];
  const openEntries = [{ anchor: "src/b.js:12" }, { anchor: "-" }, { anchor: ".zensu/x:1" }];
  const narrowed = lib.packetFiles({ changeSet, openEntries, incremental: true, scope: { status: "ok", files: ["src/a.js"] } });
  assert.deepEqual(narrowed.panel, ["src/a.js", "src/b.js"]);
  assert.deepEqual(narrowed.judge, ["docs/c.md", "src/a.js", "src/b.js"]);
  assert.equal(narrowed.narrowed, true);
  const degraded = lib.packetFiles({ changeSet, openEntries, incremental: true, scope: { status: "degraded", files: [] } });
  assert.deepEqual(degraded.panel, ["docs/c.md", "src/a.js", "src/b.js"]);
  assert.equal(degraded.reason, "scope-degraded");
  const off = lib.packetFiles({ changeSet, openEntries, incremental: false, scope: null });
  assert.equal(off.reason, "incremental-off");
  assert.deepEqual(off.panel, off.judge);
  assert.equal(lib.anchorPath("src/x.js:4-9"), "src/x.js");
  assert.equal(lib.anchorPath("../x.js:4"), null);
});

test("aspect activation runs over an empty change set when the key is off", () => {
  const lean = lib.activationFor(["docs/a.md"], { activation: false, panel: "lean" });
  assert.deepEqual(lean.spawn, ["correctness"]);
  assert.deepEqual(
    lean.skipped.map((item) => item.aspect + ":" + item.reason).sort(),
    ["design:re-review-lean-panel", "security:re-review-lean-panel"]
  );
  const full = lib.activationFor(["docs/a.md"], { activation: true, panel: "full" });
  assert.ok(full.skipped.some((item) => item.reason === "documentation-only-changeset"));
});

function writeLog(p, lines) {
  fs.writeFileSync(p.log, lines.join("\n") + "\n");
}

test("round 0 records the snapshot and prints no packet", () => {
  const p = project();
  fs.writeFileSync(path.join(p.top, "a.js"), "one");
  fs.writeFileSync(p.changes, "a.js\n");
  writeLog(p, ["TDD STARTED — x"]);
  const result = lib.prepare(input(p, "0"));
  assert.equal(result.status, "ok");
  assert.deepEqual(result.log, ["ROUND PREPARE — round 0 recorded the round-start snapshot (1 changed files)"]);
  const read = lib.readSnapshot(p.snapshot, p.top);
  assert.equal(read.ok, true);
  assert.equal(read.doc.rounds["0"].files["a.js"], sha("one"));
});

test("a fix round attributes its landed claims, writes fixed lines and the next snapshot", () => {
  const p = project();
  fs.writeFileSync(path.join(p.top, "a.js"), "one");
  fs.writeFileSync(path.join(p.top, "b.js"), "two");
  fs.writeFileSync(p.changes, "a.js\nb.js\n");
  writeLog(p, ["S1 IMPL completed — files: a.js, b.js"]);
  assert.equal(lib.prepare(input(p, "0")).status, "ok");
  fs.writeFileSync(path.join(p.top, "a.js"), "one fixed");
  writeLog(p, [
    "S1 IMPL completed — files: a.js, b.js",
    "FINDING LEDGER — R1-F1 routed CRITICAL a.js:1 | broken",
    "FINDING LEDGER — R1-F2 parked IMPORTANT b.js:2 | later",
    "R1-F1 IMPL completed — files: a.js",
  ]);
  const tally = "EDIT LANDING AUDIT — claims=3 landed=0 not_landed=1 unverified=0 pending=2 exempt_ignored=0 exempt_verified=0";
  const earlier = "EDIT NOT LANDED — S2: claimed docs/gone.md, git shows no change";
  fs.writeFileSync(
    p.audit,
    [
      "PENDING PREDICATE — S1: a.js was already dirty before this round; union membership is not evidence — re-read the target predicate",
      "PENDING PREDICATE — R1-F1: a.js was already dirty before this round; union membership is not evidence — re-read the target predicate",
      earlier,
      tally,
    ].join("\n") + "\n"
  );
  const result = lib.prepare(input(p, "1"));
  assert.equal(result.status, "ok");
  assert.ok(result.log.includes("FINDING LEDGER — R1-F1 fixed CRITICAL a.js:1 | broken"));
  assert.ok(result.log.includes("ROUND LANDING — R1-F1: landed (files=1 changed=1 unchanged=0 unresolved=0 failed=0)"));
  for (const line of [earlier, tally, "ROUND LANDING — R1-F1: landed (files=1 changed=1 unchanged=0 unresolved=0 failed=0)"]) {
    assert.ok(result.log.includes(line), line);
    assert.ok(result.out.includes(line), line);
  }
  assert.ok(!result.out.some((line) => line.startsWith("PENDING PREDICATE")));
  assert.ok(result.out.includes("pending_earlier_claims: 1 (earlier rounds, graded there)"));
  assert.ok(result.out.includes("fixed: R1-F1"));
  assert.ok(result.out.some((line) => line.startsWith("open R1-F2 parked IMPORTANT b.js:2")));
  assert.ok(result.out.includes("changed_files (round-delta): a.js, b.js"));
  assert.ok(result.out.includes("judge_changed_files: a.js, b.js"));
  assert.ok(result.out.includes("spawn: correctness"));
  assert.ok(result.log.includes("ASPECT SKIPPED — design (re-review-lean-panel)"));
  assert.deepEqual(result.diff, ["a.js", "b.js"]);
  const read = lib.readSnapshot(p.snapshot, p.top);
  assert.equal(read.doc.rounds["1"].files["a.js"], sha("one fixed"));
});

test("a round whose claim left its file unchanged stops and keeps the round-start snapshot", () => {
  const p = project();
  fs.writeFileSync(path.join(p.top, "a.js"), "one");
  fs.writeFileSync(p.changes, "a.js\n");
  writeLog(p, ["FINDING LEDGER — R1-F1 routed CRITICAL a.js:1 | broken", "R1-F1 IMPL completed — files: a.js"]);
  assert.equal(lib.prepare(input(p, "0")).status, "ok");
  fs.writeFileSync(
    p.audit,
    "PENDING PREDICATE — R1-F1: a.js was already dirty before this round; union membership is not evidence — re-read the target predicate\n"
  );
  const result = lib.prepare(input(p, "1"));
  assert.equal(result.status, "stopped");
  assert.ok(
    result.out.includes(
      "ROUND PREPARE STOPPED — edit-landing: 1 claim(s) of this round did not land in this round: R1-F1 (a.js unchanged); " +
        "the verdict lines above name each kind: land the edit, or log CLAIM WITHDRAWN — <label>: <file> for a claim that cannot land (CLAIM WITHDRAWN — <label> for one listed with no file), then run the verb again"
    )
  );
  assert.ok(!result.log.some((line) => line.startsWith("FINDING LEDGER")));
  const read = lib.readSnapshot(p.snapshot, p.top);
  assert.deepEqual(Object.keys(read.doc.rounds), ["0"]);
});

test("a claim withdrawn after the stop lets the same round run again and writes no fixed line for it", () => {
  const p = project();
  fs.writeFileSync(path.join(p.top, "a.js"), "one");
  fs.writeFileSync(path.join(p.top, "b.js"), "two");
  fs.writeFileSync(p.changes, "a.js\nb.js\n");
  writeLog(p, ["TDD STARTED — x"]);
  assert.equal(lib.prepare(input(p, "0")).status, "ok");
  fs.writeFileSync(path.join(p.top, "a.js"), "one fixed");
  const lines = [
    "FINDING LEDGER — R1-F1 routed CRITICAL a.js:1 | broken",
    "FINDING LEDGER — R1-F2 routed CRITICAL b.js:1 | also broken",
    "R1-F1 IMPL completed — files: a.js",
    "R1-F2 IMPL completed — files: b.js",
  ];
  writeLog(p, lines);
  fs.writeFileSync(p.audit, [pendingLine("R1-F1", "a.js"), pendingLine("R1-F2", "b.js")].join("\n") + "\n");
  const stopped = lib.prepare(input(p, "1"));
  assert.equal(stopped.status, "stopped");
  assert.ok(stopped.out.some((line) => line.includes("did not land in this round: R1-F2 (b.js unchanged)")));
  writeLog(p, lines.concat(["CLAIM WITHDRAWN — R1-F2: b.js"]));
  const result = lib.prepare(input(p, "1"));
  assert.equal(result.status, "ok");
  assert.ok(result.log.includes("ROUND LANDING — R1-F2: withdrawn (files=1 changed=0 unchanged=0 unresolved=0 failed=0 withdrawn=1)"));
  assert.ok(result.out.includes("withdrawn_claims: R1-F2"));
  assert.ok(result.out.includes("fixed: R1-F1"));
  assert.ok(result.out.some((line) => line.startsWith("open R1-F2 routed-unfixed CRITICAL b.js:1")));
  assert.deepEqual(Object.keys(lib.readSnapshot(p.snapshot, p.top).doc.rounds).sort(), ["0", "1"]);
});

test("a fix round counts a file restored to its committed content as landed and leaves a file two labels share unresolved", () => {
  const p = project();
  fs.writeFileSync(path.join(p.top, "a.js"), "dirty");
  fs.writeFileSync(path.join(p.top, "b.js"), "two");
  fs.writeFileSync(p.changes, "a.js\nb.js\n");
  writeLog(p, ["TDD STARTED — x"]);
  assert.equal(lib.prepare(input(p, "0")).status, "ok");
  fs.writeFileSync(path.join(p.top, "a.js"), "committed");
  fs.writeFileSync(path.join(p.top, "b.js"), "two fixed");
  writeLog(p, [
    "FINDING LEDGER — R1-F1 routed CRITICAL a.js:1 | broken",
    "FINDING LEDGER — R1-F2 routed CRITICAL b.js:1 | also broken",
    "FINDING LEDGER — R1-F3 routed CRITICAL b.js:9 | third",
    "R1-F1 IMPL completed — files: a.js",
    "R1-F2 IMPL completed — files: b.js",
    "R1-F3 IMPL completed — files: b.js",
  ]);
  fs.writeFileSync(
    p.audit,
    ["EDIT NOT LANDED — R1-F1: claimed a.js, git shows no change", pendingLine("R1-F2", "b.js"), pendingLine("R1-F3", "b.js")].join("\n") + "\n"
  );
  const result = lib.prepare(input(p, "1"));
  assert.equal(result.status, "ok");
  assert.ok(result.log.includes("ROUND LANDING — R1-F1: landed (files=1 changed=1 unchanged=0 unresolved=0 failed=0)"));
  assert.ok(result.log.includes("ROUND LANDING — R1-F2: unresolved (files=1 changed=0 unchanged=0 unresolved=1 failed=0 shared=1)"));
  assert.ok(result.out.includes("fixed: R1-F1"));
  assert.ok(result.out.includes("unresolved_claims: R1-F2, R1-F3"));
  assert.deepEqual(
    result.log.filter((line) => line.startsWith("FINDING LEDGER")),
    ["FINDING LEDGER — R1-F1 fixed CRITICAL a.js:1 | broken"]
  );
});

test("a snapshot recorded for another run log is not used, and the round records one for its own", () => {
  const p = project();
  fs.writeFileSync(path.join(p.top, "a.js"), "one");
  fs.writeFileSync(p.changes, "a.js\n");
  const other = path.join(p.top, ".zensu", "logs", "other.log");
  fs.writeFileSync(other, "TDD STARTED — other\n");
  assert.equal(lib.prepare(input(p, "0", { log: other })).status, "ok");
  fs.writeFileSync(path.join(p.top, "a.js"), "two");
  writeLog(p, ["FINDING LEDGER — R1-F1 routed CRITICAL a.js:1 | broken", "R1-F1 IMPL completed — files: a.js"]);
  fs.writeFileSync(p.audit, pendingLine("R1-F1", "a.js") + "\n");
  const result = lib.prepare(input(p, "1"));
  assert.equal(result.status, "ok");
  assert.ok(result.out.some((line) => line.startsWith("ROUND LANDING UNAVAILABLE — no round-start snapshot (other-chain)")));
  assert.ok(!result.log.some((line) => line.startsWith("FINDING LEDGER")));
  assert.ok(result.out.includes("unresolved_claims: R1-F1"));
  const read = lib.readSnapshot(p.snapshot, p.top);
  assert.equal(read.doc.log, "run.log");
  assert.deepEqual(Object.keys(read.doc.rounds), ["1"]);
});

test("a review budget reset retires the snapshot of the earlier generation", () => {
  const p = project();
  fs.writeFileSync(path.join(p.top, "a.js"), "one");
  fs.writeFileSync(p.changes, "a.js\n");
  writeLog(p, ["TDD STARTED — x"]);
  assert.equal(lib.prepare(input(p, "0")).status, "ok");
  fs.writeFileSync(path.join(p.top, "a.js"), "two");
  writeLog(p, [
    "TDD STARTED — x",
    "REVIEW BUDGET RESET — review rounds restart at 1",
    "FINDING LEDGER — R1-F1 routed CRITICAL a.js:1 | broken",
    "R1-F1 IMPL completed — files: a.js",
  ]);
  fs.writeFileSync(p.audit, pendingLine("R1-F1", "a.js") + "\n");
  const result = lib.prepare(input(p, "1"));
  assert.equal(result.status, "ok");
  assert.ok(result.out.some((line) => line.startsWith("ROUND LANDING UNAVAILABLE — no round-start snapshot (other-generation)")));
  assert.ok(!result.log.some((line) => line.startsWith("FINDING LEDGER")));
  const read = lib.readSnapshot(p.snapshot, p.top);
  assert.equal(read.doc.generation, 1);
  assert.deepEqual(Object.keys(read.doc.rounds), ["1"]);
});

test("a refused receipt stops the round before any claim is attributed and keeps the round-start snapshot", () => {
  const p = project();
  fs.writeFileSync(path.join(p.top, "a.js"), "one");
  fs.writeFileSync(p.changes, "a.js\n");
  writeLog(p, ["FINDING LEDGER — R1-F1 routed CRITICAL a.js:1 | broken", "R1-F1 IMPL completed — files: a.js"]);
  assert.equal(lib.prepare(input(p, "0")).status, "ok");
  fs.writeFileSync(path.join(p.top, "a.js"), "one fixed");
  const refusal = "RECEIPT REFUSED — the receipt could not be written to <project>/.zensu/state/edit-landing-x.json";
  fs.writeFileSync(
    p.audit,
    [
      "PENDING PREDICATE — R1-F1: a.js was already dirty before this round; union membership is not evidence — re-read the target predicate",
      "EDIT LANDING AUDIT — claims=1 landed=0 not_landed=0 unverified=0 pending=1 exempt_ignored=0 exempt_verified=0",
      refusal,
    ].join("\n") + "\n"
  );
  const result = lib.prepare(input(p, "1"));
  assert.equal(result.status, "fault");
  assert.ok(result.log.includes(refusal));
  assert.ok(result.out.includes(refusal));
  assert.ok(result.out.some((line) => line.startsWith("ROUND PREPARE STOPPED — edit-landing: the audit graded the claims but could not write its receipt")));
  assert.ok(!result.log.some((line) => line.startsWith("FINDING LEDGER") || line.startsWith("ROUND LANDING")));
  assert.deepEqual(result.diff, []);
  const read = lib.readSnapshot(p.snapshot, p.top);
  assert.deepEqual(Object.keys(read.doc.rounds), ["0"]);
});

test("a partial ledger still names the entries it read, and an unreadable one is disclosed with no fixed line", () => {
  const p = project();
  fs.writeFileSync(path.join(p.top, "a.js"), "one");
  fs.writeFileSync(p.changes, "a.js\n");
  writeLog(p, ["TDD STARTED — x"]);
  assert.equal(lib.prepare(input(p, "0")).status, "ok");
  fs.writeFileSync(path.join(p.top, "a.js"), "two");
  const lines = ["FINDING LEDGER — R1-F1 routed CRITICAL a.js:1 | broken", "FINDING LEDGER — R1-F2 routed", "R1-F1 IMPL completed — files: a.js"];
  writeLog(p, lines);
  fs.writeFileSync(p.audit, pendingLine("R1-F1", "a.js") + "\n");
  const partial = lib.prepare(input(p, "1"));
  assert.equal(partial.status, "ok");
  assert.ok(partial.log.includes("FINDING LEDGER — R1-F1 fixed CRITICAL a.js:1 | broken"));
  assert.ok(partial.out.some((entry) => entry.startsWith("ledger_note: the ledger report read answered partial (")));
  const outside = tempDir();
  const foreignLog = path.join(outside, "run.log");
  fs.writeFileSync(foreignLog, lines.join("\n") + "\n");
  fs.writeFileSync(path.join(p.top, "a.js"), "three");
  fs.writeFileSync(p.audit, pendingLine("R1-F1", "a.js") + "\n");
  const unavailable = lib.prepare(input(p, "1", { log: foreignLog }));
  assert.equal(unavailable.status, "ok");
  const line = unavailable.out.find((entry) => entry.startsWith("ROUND LEDGER UNAVAILABLE — degraded ("));
  assert.ok(line, unavailable.out.join("\n"));
  assert.ok(unavailable.log.includes(line));
  assert.ok(!unavailable.log.some((entry) => entry.startsWith("FINDING LEDGER")));
  assert.ok(unavailable.out.includes("fixed: none"));
});

test("a missing snapshot is disclosed and writes no fixed line", () => {
  const p = project();
  fs.writeFileSync(path.join(p.top, "a.js"), "one");
  fs.writeFileSync(p.changes, "a.js\n");
  writeLog(p, ["FINDING LEDGER — R1-F1 routed CRITICAL a.js:1 | broken", "R1-F1 IMPL completed — files: a.js"]);
  fs.writeFileSync(p.audit, "EDIT LANDED — R1-F1: a.js\n");
  const result = lib.prepare(input(p, "1"));
  assert.equal(result.status, "ok");
  assert.ok(result.log.some((line) => line.startsWith("ROUND LANDING UNAVAILABLE — no round-start snapshot (missing)")));
  assert.ok(!result.log.some((line) => line.startsWith("FINDING LEDGER")));
  assert.ok(result.out.includes("unresolved_claims: R1-F1"));
});

test("the self-review round writes fixed lines and no packet", () => {
  const p = project();
  fs.writeFileSync(path.join(p.top, "a.js"), "one");
  fs.writeFileSync(p.changes, "a.js\n");
  writeLog(p, ["FINDING LEDGER — R1-F1 parked IMPORTANT a.js:1 | later"]);
  assert.equal(lib.prepare(input(p, "0")).status, "ok");
  fs.writeFileSync(path.join(p.top, "a.js"), "two");
  writeLog(p, ["FINDING LEDGER — R1-F1 parked IMPORTANT a.js:1 | later", "SR-R1-F1 IMPL completed — files: a.js"]);
  fs.writeFileSync(
    p.audit,
    "PENDING PREDICATE — SR-R1-F1: a.js was already dirty before this round; union membership is not evidence — re-read the target predicate\n"
  );
  const result = lib.prepare(input(p, "self-review"));
  assert.equal(result.status, "ok");
  assert.ok(result.log.includes("FINDING LEDGER — R1-F1 fixed IMPORTANT a.js:1 | later"));
  assert.ok(!result.out.some((line) => line.startsWith("changed_files")));
  assert.deepEqual(Object.keys(lib.readSnapshot(p.snapshot, p.top).doc.rounds), ["0"]);
});

test("the self-review round starts from the last fix round the log shows, never from an older snapshot", () => {
  const p = project();
  fs.writeFileSync(path.join(p.top, "a.js"), "one");
  fs.writeFileSync(p.changes, "a.js\n");
  writeLog(p, ["TDD STARTED — x"]);
  assert.equal(lib.prepare(input(p, "0")).status, "ok");
  fs.writeFileSync(path.join(p.top, "a.js"), "two");
  writeLog(p, [
    "FINDING LEDGER — R1-F1 parked IMPORTANT a.js:1 | later",
    "EDIT LANDING AUDIT STARTED — round fix-1",
    "SR-R1-F1 IMPL completed — files: a.js",
  ]);
  fs.writeFileSync(p.audit, pendingLine("SR-R1-F1", "a.js") + "\n");
  const result = lib.prepare(input(p, "self-review"));
  assert.equal(result.status, "ok");
  assert.ok(
    result.out.includes(
      "ROUND LANDING UNAVAILABLE — no round-start snapshot (no entry for round 1), so no claim of this round could be attributed and no fixed line was written"
    )
  );
  assert.ok(!result.log.some((line) => line.startsWith("FINDING LEDGER")));
  assert.ok(result.out.includes("unresolved_claims: SR-R1-F1"));
});

test("the convergence key off skips the ledger and says so", () => {
  const p = project();
  fs.writeFileSync(path.join(p.top, "a.js"), "one");
  fs.writeFileSync(p.changes, "a.js\n");
  writeLog(p, ["FINDING LEDGER — R1-F1 routed CRITICAL a.js:1 | broken"]);
  assert.equal(lib.prepare(input(p, "0")).status, "ok");
  fs.writeFileSync(path.join(p.top, "a.js"), "two");
  fs.writeFileSync(
    p.audit,
    "PENDING PREDICATE — R1-F1: a.js was already dirty before this round; union membership is not evidence — re-read the target predicate\n"
  );
  const result = lib.prepare(input(p, "1", { convergence: false, incremental: false }));
  assert.equal(result.status, "ok");
  assert.ok(!result.log.some((line) => line.startsWith("FINDING LEDGER") || line.startsWith("ROUND LEDGER")));
  assert.deepEqual(
    result.out.filter((line) => line.startsWith("open_ledger")),
    ["open_ledger: off (hooks.reviewConvergence is off); no fixed line was written"]
  );
  assert.ok(result.out.includes("changed_files (incremental-off): a.js"));
});

test("the claim grammar is the audit's: up to five label tokens, three dash spellings and the bare WIRED form", () => {
  assert.deepEqual(lib.claimOf("R2-Step 3 IMPL completed — files: ./a.js, <project>/b.js | note"), { label: "R2-Step 3", files: ["a.js", "b.js"] });
  assert.deepEqual(lib.claimOf("[10:00] R1-F1 IMPL completed - files: c.js"), { label: "R1-F1", files: ["c.js"] });
  assert.deepEqual(lib.claimOf("R1-F1 WIRED – files: d.js e.js"), { label: "R1-F1", files: ["d.js", "e.js"] });
  assert.deepEqual(lib.claimOf("S1 WIRED (verified, no change)"), { label: "S1", files: [] });
  assert.deepEqual(lib.claimOf("R1-W WIRED"), { label: "R1-W", files: [] });
  assert.deepEqual(lib.claimOf("IMPL completed — files: x.js"), { label: "(none)", files: ["x.js"] });
  assert.equal(lib.claimOf("a b c d e f IMPL completed — files: x.js"), null);
  assert.equal(lib.claimOf('R1 "quoted" IMPL completed — files: x.js'), null);
  assert.equal(lib.claimOf("PENDING PREDICATE — R1-F1 IMPL completed — files: a.js"), null);
  assert.equal(lib.claimOf("FINDING LEDGER — R1-F1 routed CRITICAL a.js:1 | broken"), null);
  const p = project();
  writeLog(p, ["R2-Step 3 IMPL completed — files: a.js", "CLAIM WITHDRAWN — R2-Step 3: a.js"]);
  const result = lib.resolveLanding({
    auditLines: [pendingLine("R2-Step 3", "a.js")],
    round: lib.parseRound("2"),
    start: { at: 0, baseline: "", truncated: 0, files: { "a.js": "sha256:a" } },
    current: { "a.js": "sha256:a" },
    chain: lib.chainOf(p.log),
  });
  assert.equal(result.steps[0].state, "withdrawn");
});

test("a start entry recorded under another baseline is not used, so a claim the entry lacks gets no fixed line", () => {
  const p = project();
  fs.writeFileSync(path.join(p.top, "a.js"), "dirty");
  fs.writeFileSync(path.join(p.top, "x.js"), "committed after the baseline, never touched in the round");
  fs.writeFileSync(p.changes, "a.js\n");
  writeLog(p, ["TDD STARTED — x"]);
  assert.equal(lib.prepare(input(p, "0", { baseline: "" })).status, "ok");
  writeLog(p, ["TDD STARTED — x", "FINDING LEDGER — R1-F1 routed CRITICAL x.js:1 | broken", "R1-F1 IMPL completed — files: x.js"]);
  fs.writeFileSync(p.changes, "a.js\nx.js\n");
  fs.writeFileSync(p.audit, "EDIT LANDED — R1-F1: x.js\n");
  const other = lib.prepare(input(p, "1", { baseline: "020c6fe52c8e1ead9f9608914f961186a39e38b4" }));
  assert.ok(other.out.some((line) => line.startsWith("ROUND LANDING UNAVAILABLE — no round-start snapshot (other-baseline)")));
  assert.ok(!other.log.some((line) => line.startsWith("FINDING LEDGER — R1-F1 fixed")));
  assert.equal(lib.readSnapshot(p.snapshot, p.top).doc.rounds["1"].baseline, "020c6fe52c8e1ead9f9608914f961186a39e38b4");
  const env = { ZENSU_RP_ROUND: "2", ZENSU_RP_TOP: p.top, ZENSU_RP_LOG: p.log, ZENSU_RP_SNAPSHOT: p.snapshot, ZENSU_RP_CHANGES: p.changes };
  assert.equal(lib.cliMain(["start-paths"], env).code, 3);
  assert.equal(lib.cliMain(["start-paths"], Object.assign({ ZENSU_RP_BASELINE: "020c6fe52c8e1ead9f9608914f961186a39e38b4" }, env)).code, 0);
});

test("an UNVERIFIED claim of the round names the label-only withdrawal, and that withdrawal clears it", () => {
  const p = project();
  fs.writeFileSync(path.join(p.top, "a.js"), "one");
  fs.writeFileSync(p.changes, "a.js\n");
  writeLog(p, ["TDD STARTED — x"]);
  assert.equal(lib.prepare(input(p, "0")).status, "ok");
  const lines = ["TDD STARTED — x", "R1-F1 IMPL completed — files: elsewhere/a.js"];
  writeLog(p, lines);
  fs.writeFileSync(p.audit, 'UNVERIFIED (foreign root) — R1-F1: claimed "elsewhere/a.js" resolves outside the audited root /r\n');
  const stopped = lib.prepare(input(p, "1"));
  assert.equal(stopped.status, "stopped");
  assert.ok(stopped.out.some((line) => line.includes("R1-F1 (no file unverified)") && line.includes("(CLAIM WITHDRAWN — <label> for one listed with no file)")));
  writeLog(p, lines.concat(["CLAIM WITHDRAWN — R1-F1"]));
  const result = lib.prepare(input(p, "1"));
  assert.equal(result.status, "ok");
  assert.ok(result.out.includes("withdrawn_claims: R1-F1"));
});

test("claims logged since the round began without its prefix are disclosed", () => {
  const p = project();
  fs.writeFileSync(path.join(p.top, "a.js"), "one");
  fs.writeFileSync(p.changes, "a.js\n");
  writeLog(p, ["S1 IMPL completed — files: a.js"]);
  const zero = lib.prepare(input(p, "0"));
  const lines = [
    "S1 IMPL completed — files: a.js",
    zero.log[0],
    "R1-F1 IMPL completed — files: a.js",
    "F2 IMPL completed — files: a.js",
    "EDIT LANDING AUDIT STARTED — round fix-1",
    "R2-F1 IMPL completed — files: a.js",
    "R1-F3 IMPL completed — files: a.js",
  ];
  writeLog(p, lines);
  const chain = lib.chainOf(p.log);
  assert.deepEqual(lib.unprefixedClaims(chain, lib.parseRound("1")), ["F2", "R2-F1"]);
  assert.deepEqual(lib.unprefixedClaims(chain, lib.parseRound("2")), ["R1-F3"]);
  assert.deepEqual(lib.unprefixedClaims(chain, lib.parseRound("3")), []);
  fs.writeFileSync(path.join(p.top, "a.js"), "two");
  writeLog(p, lines.slice(0, 4));
  fs.writeFileSync(p.audit, pendingLine("R1-F1", "a.js") + "\n");
  const result = lib.prepare(input(p, "1"));
  assert.ok(result.out.includes("unprefixed_claims: F2 (logged since this round began without the R1- prefix, so no fixed line can name their findings)"));
});

test("a fixed line names an entry carried across a reset by its generation qualifier", () => {
  const top = tempDir();
  const log = path.join(top, "run.log");
  fs.writeFileSync(
    log,
    ["FINDING LEDGER — R1-F1 parked IMPORTANT a.js:1 | first", "REVIEW BUDGET RESET — review rounds restart at 1", "FINDING LEDGER — R1-F1 routed CRITICAL b.js:2 | second"].join("\n") + "\n"
  );
  const report = ledgerLib.ledgerState({ log, root: top, report: true });
  assert.equal(report.status, "ok");
  assert.equal(lib.findingIdOf("SR-G1:R1-F1", lib.parseRound("self-review")), "G1:R1-F1");
  assert.equal(lib.findingIdOf("R2-G1:R1-F1", lib.parseRound("2")), "G1:R1-F1");
  const result = lib.fixedLines({ round: lib.parseRound("self-review"), ledger: report, steps: [{ step: "SR-G1:R1-F1", state: "landed" }, { step: "SR-R1-F1", state: "landed" }] });
  assert.deepEqual(result.lines, ["FINDING LEDGER — G1:R1-F1 fixed IMPORTANT a.js:1 | first", "FINDING LEDGER — R1-F1 fixed CRITICAL b.js:2 | second"]);
  for (const line of result.lines) assert.equal(ledgerLib.parseLedgerLine(line).malformed, false);
});

test("the packet lists leave out a nested state directory and every path the user's own excludes ignore", () => {
  const files = lib.packetFiles({
    changeSet: ["a.js", "sub/.zensu/logs/run.log", "secret.env"],
    openEntries: [{ anchor: "secret.env:1" }],
    incremental: true,
    scope: { status: "ok", files: ["a.js", "secret.env"] },
    ignored: ["secret.env"],
  });
  assert.deepEqual(files.panel, ["a.js"]);
  assert.deepEqual(files.judge, ["a.js"]);
  const p = project();
  fs.writeFileSync(path.join(p.top, "a.js"), "one");
  fs.writeFileSync(path.join(p.top, "secret.env"), "token");
  fs.writeFileSync(p.changes, "a.js\nsecret.env\n");
  const ignoredFile = path.join(p.top, ".zensu", "state", "ignored.txt");
  fs.writeFileSync(ignoredFile, "secret.env\n");
  writeLog(p, ["TDD STARTED — x"]);
  assert.equal(lib.prepare(input(p, "0")).status, "ok");
  fs.writeFileSync(p.audit, "");
  const result = lib.prepare(input(p, "1", { ignoredFile }));
  assert.equal(result.status, "ok");
  assert.deepEqual(result.diff, ["a.js"]);
  assert.ok(result.out.includes("user_ignored: 1 changed path(s) your own git excludes ignore are left out of the packet lists and the round diff"));
  assert.ok(result.out.includes("judge_changed_files: a.js"));
});

test("a refused round argument changes nothing", () => {
  const p = project();
  fs.writeFileSync(p.changes, "");
  const result = lib.prepare(input(p, "x"));
  assert.equal(result.status, "refused");
  assert.equal(fs.existsSync(p.snapshot), false);
});

test("the CLI renders log, diff, out and status lines and reports start paths", () => {
  const rendered = lib.render({ status: "ok", log: ["L"], out: ["O"], diff: ["d.js"] });
  assert.equal(rendered, "log L\ndiff d.js\nout O\nstatus ok\n");
  const p = project();
  fs.writeFileSync(path.join(p.top, "a.js"), "one");
  fs.writeFileSync(p.changes, "a.js\n");
  writeLog(p, ["TDD STARTED — x"]);
  const env = {
    ZENSU_RP_ROUND: "1",
    ZENSU_RP_TOP: p.top,
    ZENSU_RP_LOG: p.log,
    ZENSU_RP_SNAPSHOT: p.snapshot,
    ZENSU_RP_CHANGES: p.changes,
  };
  assert.equal(lib.cliMain(["start-paths"], env).code, 3);
  assert.equal(lib.prepare(input(p, "0")).status, "ok");
  assert.deepEqual(lib.cliMain(["start-paths"], env), { code: 0, stdout: "a.js\n", stderr: "" });
  assert.equal(lib.cliMain(["other"], env).code, 2);
  assert.equal(lib.inputFromEnvironment({ ZENSU_RP_PANEL: "weird" }).panel, "lean");
});
