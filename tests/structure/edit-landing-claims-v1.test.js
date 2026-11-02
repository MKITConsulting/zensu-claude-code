"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const MODULE = path.join(__dirname, "..", "..", "hooks", "lib", "edit-landing-claims-v1.js");
const lib = require(MODULE);

function tempDir() {
  return fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), "edit-landing-claims-")));
}

function rowsOf(lines, options) {
  return lib.auditRows(lines.join("\n") + "\n", options);
}

function listing(paths) {
  return { paths: new Set(paths), changed: new Set() };
}

test("claimLine keeps the anchored grammar of the audit", () => {
  assert.deepEqual(lib.claimLine("[12:00:00] S1 IMPL completed — files: a.ts, b.ts | note").label, "S1");
  assert.equal(lib.claimLine("S1 IMPL completed — files: a.ts | note").text, " a.ts ");
  assert.equal(lib.claimLine("FIX ROUND 2 S3 IMPL completed – files: a.ts").label, "FIX ROUND 2 S3");
  assert.equal(lib.claimLine("S1 WIRED - files: a.ts").kind, "files");
  assert.equal(lib.claimLine("IMPL completed — files: a.ts").label, "(none)");
  assert.deepEqual(lib.claimLine("S1 WIRED (verified, no change) — x.ts: checked"), { kind: "verified", label: "S1" });
  assert.deepEqual(lib.claimLine("T05 WIRED into the router"), { kind: "wired", label: "T05" });
  assert.equal(lib.claimLine("a b c d e f IMPL completed — files: a.ts"), null);
  assert.equal(lib.claimLine("note 'IMPL completed — files:' was quoted"), null);
});

test("claimLine skips every verdict head, the correction heads included", () => {
  for (const head of lib.VERDICT_HEADS) {
    assert.equal(lib.claimLine(head + "— S1 IMPL completed — files: a.ts"), null, head);
  }
  assert.equal(lib.claimLine("[ts] CLAIM RETRACTED — S1 (line 3, correction line 9): S1 WIRED x"), null);
});

test("claimLine records the line head and the commentary tail", () => {
  const claim = lib.claimLine("[ts] S2 IMPL completed — files: a.ts b.ts | moved helpers");
  assert.equal(claim.head, "[ts] S2 IMPL completed — files:");
  assert.equal(claim.tail, "| moved helpers");
});

test("splitFiles splits only at commas outside brace and parenthesis groups", () => {
  assert.deepEqual(lib.splitFiles(" a.ts, b/{c,d}.ts ,src/x.ts (new, small), , e.ts"), [
    "a.ts",
    "b/{c,d}.ts",
    "src/x.ts (new, small)",
    "e.ts",
  ]);
  assert.deepEqual(lib.splitFiles("app/(group)/page.tsx, [id].tsx"), ["app/(group)/page.tsx", "[id].tsx"]);
});

test("expandBraces expands comma groups, nesting and ranges like the shell", () => {
  assert.deepEqual(lib.expandBraces("l/{en,de}/s.json"), ["l/en/s.json", "l/de/s.json"]);
  assert.deepEqual(lib.expandBraces("{a,b{c,d}}x"), ["ax", "bcx", "bdx"]);
  assert.deepEqual(lib.expandBraces("{a{b,c}}"), ["{ab}", "{ac}"]);
  assert.deepEqual(lib.expandBraces("v{1..3}.ts"), ["v1.ts", "v2.ts", "v3.ts"]);
  assert.deepEqual(lib.expandBraces("v{08..10}"), ["v08", "v09", "v10"]);
  assert.deepEqual(lib.expandBraces("{c..a}"), ["c", "b", "a"]);
  assert.deepEqual(lib.expandBraces("{a,}x"), ["ax", "x"]);
});

test("expandBraces leaves literal groups alone and refuses what it cannot expand", () => {
  assert.deepEqual(lib.expandBraces("{{cookiecutter.slug}}/a.py"), ["{{cookiecutter.slug}}/a.py"]);
  assert.deepEqual(lib.expandBraces("a{b"), ["a{b"]);
  assert.deepEqual(lib.expandBraces("{solo}"), ["{solo}"]);
  assert.equal(lib.expandBraces("{1..10..2}"), null);
  assert.equal(lib.expandBraces("{0..999}"), null);
  assert.equal(lib.expandBraces("{a,b}{c,d}{e,f}{g,h}{i,j}{k,l}{m,n}{o,p}{q,r}"), null);
});

test("tokenClass treats brackets as path characters", () => {
  assert.equal(lib.tokenClass("www/src/pages/blog/[...slug].astro"), "path");
  assert.equal(lib.tokenClass("app/(group)/page.tsx"), "path");
  assert.equal(lib.tokenClass("l/{en,de}/s.json"), "brace");
  assert.equal(lib.tokenClass("l/*/ghost.json"), "glob");
  assert.equal(lib.tokenClass("src/a.ts (new)"), "prose");
  assert.equal(lib.tokenClass("{1..10..2}"), "pattern");
});

test("globRegex keeps single stars inside one segment and lets double stars cross", () => {
  assert.ok(lib.globRegex("l/*/ghost.json").test("l/en/ghost.json"));
  assert.ok(!lib.globRegex("l/*/ghost.json").test("l/en/x/ghost.json"));
  assert.ok(lib.globRegex("src/**/*.ts").test("src/a/b/c.ts"));
  assert.ok(lib.globRegex("src/**/*.ts").test("src/c.ts"));
  assert.ok(lib.globRegex("a?.md").test("ab.md"));
  assert.ok(lib.globRegex("[id]/*.ts").test("[id]/x.ts"));
  assert.ok(!lib.globRegex("[id]/*.ts").test("i/x.ts"));
});

test("auditRows grades every brace member as a literal claim", () => {
  const rows = rowsOf(["S12 IMPL completed — files: l/{en,de}/s.json, t.ts"], listing([]));
  assert.deepEqual(rows, [
    ["G", 1, "S12", "l/en/s.json"],
    ["G", 1, "S12", "l/de/s.json"],
    ["G", 1, "S12", "t.ts"],
  ]);
});

test("auditRows grades every glob match and reports a glob without matches", () => {
  const ctx = listing(["l/en/ghost.json", "l/de/ghost.json", "l/en/other.json"]);
  assert.deepEqual(rowsOf(["S11 IMPL completed — files: l/*/ghost.json"], ctx), [
    ["G", 1, "S11", "l/de/ghost.json"],
    ["G", 1, "S11", "l/en/ghost.json"],
  ]);
  assert.deepEqual(rowsOf(["S11 IMPL completed — files: missing/*.json"], ctx), [
    ["M", 1, "S11", "glob-none", "missing/*.json", "0"],
  ]);
});

test("auditRows asks for a listing on demand and otherwise reports an unlisted glob", () => {
  const lines = ["S11 IMPL completed — files: l/*/ghost.json"];
  assert.deepEqual(rowsOf(lines, { onDemand: true }), [["N"]]);
  assert.deepEqual(rowsOf(lines, {}), [["P", 1, "S11", "l/*/ghost.json"]]);
});

test("auditRows reports prose and unexpandable tokens with their candidates", () => {
  const rows = rowsOf([
    "S3 IMPL completed — files: src/a.ts src/b.ts",
    "S4 IMPL completed — files: the parser module",
    "S5 IMPL completed — files: v{1..10..2}.ts",
  ], listing([]));
  assert.deepEqual(rows, [
    ["M", 1, "S3", "prose", "src/a.ts src/b.ts", "1", "src/a.ts", "src/b.ts"],
    ["M", 2, "S4", "prose", "the parser module", "0"],
    ["M", 3, "S5", "pattern", "v{1..10..2}.ts", "0"],
  ]);
});

test("a token that exists as written or changed is a literal claim, spaces and pattern characters included", () => {
  const root = tempDir();
  fs.mkdirSync(path.join(root, "My Docs"), { recursive: true });
  fs.writeFileSync(path.join(root, "My Docs", "a b.md"), "x\n");
  const rows = rowsOf([
    "S1 IMPL completed — files: My Docs/a b.md, gone {x,y}.txt, My Docs/c d.md",
  ], { roots: [root], changed: new Set(["gone {x,y}.txt"]), paths: new Set() });
  assert.deepEqual(rows, [
    ["G", 1, "S1", "My Docs/a b.md"],
    ["G", 1, "S1", "gone {x,y}.txt"],
    ["M", 1, "S1", "prose", "My Docs/c d.md", "1", "Docs/c", "d.md"],
  ]);
});

test("auditRows keeps bare WIRED and verified entries apart", () => {
  assert.deepEqual(rowsOf(["T05 WIRED into the router", "T06 WIRED (verified, no change) — r.ts: ok"], listing([])), [
    ["W", 1, "T05"],
    ["V", 2],
  ]);
});

test("a valid prose correction retires the token and grades the listed paths", () => {
  const rows = rowsOf([
    "S3 IMPL completed — files: src/a.ts (new), lib.ts",
    "CLAIM CORRECTED — S3 (line 1): src/a.ts",
  ], listing([]));
  assert.deepEqual(rows, [
    ["T", 1, "S3", "src/a.ts (new)"],
    ["G", 1, "S3", "lib.ts"],
    ["G", 2, "S3", "src/a.ts"],
  ]);
});

test("a correction prints a retraction for every not-claimed candidate", () => {
  const rows = rowsOf([
    "S3 IMPL completed — files: src/a.ts (pattern from docs/x.md)",
    "CLAIM CORRECTED — S3 (line 1): src/a.ts | not claimed: docs/x.md",
  ], listing([]));
  assert.deepEqual(rows.slice(1), [
    ["G", 2, "S3", "src/a.ts"],
    ["R", 2, "S3", 1, "docs/x.md"],
  ]);
});

test("a correction narrows an over-broad glob only with every match accounted for", () => {
  const ctx = listing(["l/en/ghost.json", "l/de/ghost.json"]);
  const narrowed = rowsOf([
    "S11 IMPL completed — files: l/*/ghost.json",
    "CLAIM CORRECTED — S11 (line 1): l/en/ghost.json | not claimed: l/de/ghost.json",
  ], ctx);
  assert.deepEqual(narrowed, [
    ["T", 1, "S11", "l/*/ghost.json"],
    ["G", 2, "S11", "l/en/ghost.json"],
    ["R", 2, "S11", 1, "l/de/ghost.json"],
  ]);
  const partial = rowsOf([
    "S11 IMPL completed — files: l/*/ghost.json",
    "CLAIM CORRECTED — S11 (line 1): l/en/ghost.json",
  ], ctx);
  assert.deepEqual(partial[partial.length - 1], ["I", 2, "incomplete"]);
});

test("a glob without matches is accounted for by a listed path the pattern accepts", () => {
  const rows = rowsOf([
    "S11 IMPL completed — files: new/*.ts",
    "CLAIM CORRECTED — S11 (line 1): new/a.ts",
  ], listing([]));
  assert.deepEqual(rows, [["T", 1, "S11", "new/*.ts"], ["G", 2, "S11", "new/a.ts"]]);
  const outside = rowsOf([
    "S11 IMPL completed — files: new/*.ts",
    "CLAIM CORRECTED — S11 (line 1): old/a.ts",
  ], listing([]));
  assert.deepEqual(outside[outside.length - 1], ["I", 2, "not-a-candidate"]);
});

test("an invalid correction is ignored with a fixed reason and never counts", () => {
  const base = "S3 IMPL completed — files: src/a.ts (new)";
  const cases = [
    [["CLAIM CORRECTED — S3 (line 2): src/a.ts", base], "target-not-earlier"],
    [["note", "CLAIM CORRECTED — S3 (line 1): src/a.ts"], "target-not-a-claim"],
    [[base, "CLAIM CORRECTED — S9 (line 1): src/a.ts"], "label-mismatch"],
    [["S3 IMPL completed — files: src/a.ts", "CLAIM CORRECTED — S3 (line 1): src/a.ts"], "nothing-to-correct"],
    [[base, "CLAIM CORRECTED — S3 (line 1): src/*.ts"], "malformed-entry"],
    [[base, "CLAIM CORRECTED — S3 (line 1): src/other.ts"], "not-a-candidate"],
    [[base, "CLAIM CORRECTED — S3 (line 1): src/a.ts, src/a.ts"], "duplicate-entry"],
    [[base, "CLAIM CORRECTED — S3 (line 1): | not claimed: src/a.ts, src/a.ts"], "duplicate-entry"],
    [["S3 IMPL completed — files: src/a.ts src/b.ts", "CLAIM CORRECTED — S3 (line 1): src/a.ts"], "incomplete"],
    [[base, "CLAIM CORRECTED — S3: src/a.ts"], "malformed-line"],
    [[base, "CLAIM CORRECTED — S3 (line 1): src/a.ts | drop: x"], "malformed-line"],
  ];
  for (const [lines, reason] of cases) {
    const rows = rowsOf(lines, listing([]));
    const ignored = rows.filter((row) => row[0] === "I");
    assert.equal(ignored.length, 1, lines.join(" / "));
    assert.equal(ignored[0][2], reason, lines.join(" / "));
    assert.ok(lib.IGNORE_REASONS.includes(reason));
    assert.ok(!rows.some((row) => row[0] === "T"), lines.join(" / "));
  }
});

test("the latest valid correction of a line wins and the earlier one is superseded", () => {
  const rows = rowsOf([
    "S3 IMPL completed — files: src/a.ts docs/x.md",
    "CLAIM CORRECTED — S3 (line 1): src/a.ts, docs/x.md",
    "CLAIM CORRECTED — S3 (line 1): src/a.ts | not claimed: docs/x.md",
  ], listing([]));
  assert.deepEqual(rows, [
    ["T", 1, "S3", "src/a.ts docs/x.md"],
    ["I", 2, "superseded"],
    ["G", 3, "S3", "src/a.ts"],
    ["R", 3, "S3", 1, "docs/x.md"],
  ]);
});

test("an opaque token can only be retracted, and a literal never", () => {
  const rows = rowsOf([
    "S4 IMPL completed — files: the parser module, src/p.ts",
    "CLAIM CORRECTED — S4 (line 1): | not claimed: the parser module",
  ], listing([]));
  assert.deepEqual(rows, [
    ["T", 1, "S4", "the parser module"],
    ["G", 1, "S4", "src/p.ts"],
    ["R", 2, "S4", 1, "the parser module"],
  ]);
  const literal = rowsOf([
    "S4 IMPL completed — files: the parser module, src/p.ts",
    "CLAIM CORRECTED — S4 (line 1): | not claimed: the parser module, src/p.ts",
  ], listing([]));
  assert.deepEqual(literal[literal.length - 1], ["I", 2, "not-a-candidate"]);
});

test("appendCheck refuses patterns and prose and prints an exact fix where one exists", () => {
  const brace = lib.appendCheck("S12 IMPL completed — files: l/{en,de}/s.json, t.ts | i18n", { roots: [] });
  assert.equal(brace.ok, false);
  assert.deepEqual(brace.offending, [{ kind: "brace", token: "l/{en,de}/s.json" }]);
  assert.equal(brace.fix, "S12 IMPL completed — files: l/en/s.json, l/de/s.json, t.ts | i18n");
  const spaces = lib.appendCheck("S3 IMPL completed — files: src/a.ts src/b.ts", { roots: [] });
  assert.equal(spaces.fix, "S3 IMPL completed — files: src/a.ts, src/b.ts");
  const glob = lib.appendCheck("S11 IMPL completed — files: l/*/g.json", { roots: [] });
  assert.equal(glob.ok, false);
  assert.equal(glob.fix, null);
  const prose = lib.appendCheck("S3 IMPL completed — files: src/a.ts (new)", { roots: [] });
  assert.equal(prose.fix, null);
});

test("appendCheck accepts well-formed claims, other lines and tokens that exist as written", () => {
  const root = tempDir();
  fs.mkdirSync(path.join(root, "odd {a,b}"), { recursive: true });
  assert.equal(lib.appendCheck("S1 IMPL completed — files: www/[...slug].astro, a.ts | note", { roots: [] }).ok, true);
  assert.equal(lib.appendCheck("CHECKPOINT — PASS | cmd: x y", { roots: [] }).ok, true);
  assert.equal(lib.appendCheck("S1 IMPL completed — files: odd {a,b}", { roots: [root] }).ok, true);
});

test("appendCheck refuses a malformed correction and checks its target in the log", () => {
  const logLines = ["S3 IMPL completed — files: src/a.ts (new)", "S4 IMPL completed — files: b.ts"];
  assert.deepEqual(lib.appendCheck("CLAIM CORRECTED — S3: src/a.ts", {}), { ok: false, kind: "correction", reason: "malformed-line" });
  assert.equal(lib.appendCheck("CLAIM CORRECTED — S3 (line 1): src/*.ts", { logLines }).reason, "malformed-entry");
  assert.equal(lib.appendCheck("CLAIM CORRECTED — S3 (line 3): src/a.ts", { logLines }).reason, "target-not-earlier");
  assert.equal(lib.appendCheck("CLAIM CORRECTED — S9 (line 1): src/a.ts", { logLines }).reason, "label-mismatch");
  assert.equal(lib.appendCheck("CLAIM CORRECTED — S4 (line 2): b.ts", { logLines }).reason, "nothing-to-correct");
  assert.equal(lib.appendCheck("CLAIM CORRECTED — S3 (line 1): src/a.ts", { logLines }).ok, true);
});

test("the CLI prints sanitized rows and refuses an append with exit 1", () => {
  const dir = tempDir();
  const log = path.join(dir, "run.log");
  fs.writeFileSync(log, "S1 IMPL completed — files: a\tb.ts, c.ts\n");
  const rows = spawnSync(process.execPath, [MODULE, "rows", "--log", log], { encoding: "utf8" });
  assert.equal(rows.status, 0);
  assert.equal(rows.stdout, "M\t1\tS1\tprose\ta\u007fb.ts\t1\tb.ts\nG\t1\tS1\tc.ts\n");
  const message = path.join(dir, "message.txt");
  fs.writeFileSync(message, "S2 IMPL completed — files: x/{a,b}.ts\n");
  const refused = spawnSync(process.execPath, [MODULE, "check-append", "--message-file", message, "--log", log], { encoding: "utf8" });
  assert.equal(refused.status, 1);
  assert.equal(refused.stdout, "token\tbrace\tx/{a,b}.ts\nfix\tS2 IMPL completed — files: x/a.ts, x/b.ts\n");
  fs.writeFileSync(message, "S2 IMPL completed — files: x/a.ts\n");
  assert.equal(spawnSync(process.execPath, [MODULE, "check-append", "--message-file", message], { encoding: "utf8" }).status, 0);
  assert.equal(spawnSync(process.execPath, [MODULE, "rows"], { encoding: "utf8" }).status, 2);
  assert.equal(spawnSync(process.execPath, [MODULE, "nope"], { encoding: "utf8" }).status, 2);
});

test("a quoted or bracketed entry is prose, and the fix the writer prints unwraps every word", () => {
  assert.equal(lib.tokenClass("(tests/a.test.ts)"), "prose");
  assert.equal(lib.tokenClass("\"src/a.ts\""), "prose");
  assert.equal(lib.tokenClass("app/(marketing)/page.tsx"), "path");
  const mixed = lib.appendCheck("S1 IMPL completed — files: src/a.ts (tests/a.test.ts)", { roots: [] });
  assert.equal(mixed.ok, false);
  assert.equal(mixed.fix, "S1 IMPL completed — files: src/a.ts, tests/a.test.ts");
  const wrapped = lib.appendCheck("S2 IMPL completed — files: `src/b.ts`", { roots: [] });
  assert.equal(wrapped.ok, false);
  assert.equal(wrapped.fix, "S2 IMPL completed — files: src/b.ts");
  const rows = lib.auditRows("S3 IMPL completed — files: (src/c.ts)\n", { root: tempDir(), project: "" });
  assert.deepEqual(rows, [["M", 1, "S3", "prose", "(src/c.ts)", "1", "src/c.ts"]]);
});

test("a bare dot-slash word is no candidate, so the correction it leaves is satisfiable and the writer prints no inexact fix", () => {
  const dir = tempDir();
  const rows = lib.auditRows("S1 IMPL completed — files: changes under ./ and src/a.ts\n", { root: dir, project: "" });
  assert.deepEqual(rows, [["M", 1, "S1", "prose", "changes under ./ and src/a.ts", "1", "src/a.ts"]]);
  const log = "S1 IMPL completed — files: changes under ./ and src/a.ts\nCLAIM CORRECTED — S1 (line 1): src/a.ts\n";
  const corrected = lib.auditRows(log, { root: dir, project: "" });
  assert.deepEqual(corrected.filter((row) => row[0] === "G"), [["G", 2, "S1", "src/a.ts"]]);
  assert.equal(corrected.some((row) => row[0] === "I"), false);
  assert.equal(lib.appendCheck("S2 IMPL completed — files: ./ src/b.ts", { roots: [] }).fix, null);
});
