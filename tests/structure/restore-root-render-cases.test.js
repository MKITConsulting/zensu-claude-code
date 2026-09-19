"use strict";

// Drives renderRestoreRoot's branches.
//
// It is exported with a comment saying it is exported "so every arm is drivable
// from a unit test", and for one review round nothing drove it: the refusal arm —
// the ONLY reader of RESTORE_REMEDY and of its no-remedy fallback — plus the race,
// FAILED, baselineError and already-present arms had no executed case anywhere.
// The shell suite reaches RESTORABLE and RESTORED through real armed fixtures; the
// five arms below are the ones a fixture cannot reach, because each needs the core
// to answer something a healthy tree never produces.
//
// The renderer takes a `deps` seam, so this file supplies plain fakes and touches no
// module cache. An earlier form swapped the core in and out of the global
// require.cache — a seam novel in this tree that reached every hook in hooks/lib to
// test one function, and that left the report's transitive requires cached against
// the first stub.

const test = require("node:test");
const assert = require("node:assert");
const path = require("node:path");

const ROOT = path.join(__dirname, "..", "..");
const CORE_PATH = require.resolve(path.join(ROOT, "hooks/lib/session-control-core-v1.js"));
const REPORT_PATH = require.resolve(path.join(ROOT, "hooks/lib/session-adopt-report-v1.js"));

const realCore = require(CORE_PATH);
const report = require(REPORT_PATH);

function withCore(overrides, run) {
  const chunks = [];
  const write = process.stdout.write.bind(process.stdout);
  process.stdout.write = (c) => { chunks.push(String(c)); return true; };
  let code;
  try {
    code = report.renderRestoreRoot({}, run.confirmed === true, {
      verdict: overrides.restoreRootVerdict,
      restore: overrides.restoreWorkflowProjectRoot,
    });
  } finally {
    process.stdout.write = write;
  }
  return { code, out: chunks.join("") };
}

test("a refusal renders its own remedy row and exits 1", () => {
  for (const reason of Object.values(realCore.RESTORE_ROOT_REFUSALS)) {
    const r = withCore({ restoreRootVerdict: () => ({ ok: false, reason }) }, {});
    assert.strictEqual(r.code, 1, reason);
    assert.match(r.out, /NOT restorable \(/, reason);
    assert.ok(r.out.includes(reason), `names the reason: ${reason}`);
    assert.ok(
      !r.out.includes("No remedy is known for this refusal"),
      `${reason} must not fall through to the no-remedy text`,
    );
  }
});

test("an unknown refusal falls back rather than rendering nothing", () => {
  const r = withCore({ restoreRootVerdict: () => ({ ok: false, reason: "invented-reason" }) }, {});
  assert.strictEqual(r.code, 1);
  assert.match(r.out, /No remedy is known for this refusal/);
});

test("a refusal carrying a ladder result renders the nearest existing component", () => {
  const r = withCore({
    restoreRootVerdict: () => ({
      ok: false,
      reason: realCore.RESTORE_ROOT_REFUSALS.TOO_MANY_MISSING_COMPONENTS,
      at: "/tmp/still-here",
      missingCount: 9,
      limit: 4,
    }),
  }, {});
  assert.match(r.out, /nearest existing : \/tmp\/still-here/);
  assert.match(r.out, /missing below it : 9 \(limit 4\)/);
});

test("the benign race reports that this run created nothing, and exits 0", () => {
  const raced = new Error("raced");
  raced.code = realCore.RESTORE_ALREADY_PRESENT_CODE;
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, missing: ["/tmp/x"] }),
    restoreWorkflowProjectRoot: () => { throw raced; },
  }, { confirmed: true });
  assert.strictEqual(r.code, 0);
  assert.match(r.out, /ALREADY RESTORED/);
  assert.match(r.out, /created nothing/);
});

test("any other throw is FAILED, claims nothing about the session, and exits 1", () => {
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, missing: ["/tmp/x"] }),
    restoreWorkflowProjectRoot: () => { throw new Error("session-control-v1: recorded project root could not be created at /tmp/x: EACCES"); },
  }, { confirmed: true });
  assert.strictEqual(r.code, 1);
  assert.match(r.out, /FAILED/);
  assert.match(r.out, /Nothing is claimed about the session state/);
  assert.ok(!/could not be re-created: "/.test(r.out), "the FAILED label must not be folded");
  // Positive twin: the foreign message IS folded, on its own row.
  assert.match(r.out, /cause {12}: "/);
  assert.ok(!r.out.includes("ALREADY RESTORED"));
});

test("a rebuilt directory with no document exits 1 and says the gate still denies", () => {
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, missing: ["/tmp/x"] }),
    restoreWorkflowProjectRoot: () => ({
      projectRoot: "/tmp/x",
      created: ["/tmp/x"],
      provenance: "unavailable",
      baselineError: "session-control-v1: workflow document is present but unreadable",
    }),
  }, { confirmed: true });
  assert.strictEqual(r.code, 1, "a half repair must not report success");
  assert.match(r.out, /workflow baseline: NOT rebuilt\n/);
  // The LABEL must survive even though the cause carries a foreign `: `. Composed
  // into one string, the pair rule quoted the whole row, label included.
  assert.match(r.out, /baseline cause {3}: /);
  assert.ok(!/workflow baseline: "/.test(r.out), "the row label must not be folded");
  assert.match(r.out, /provenance {7}: unavailable\n/);
  // The cause is NOT duplicated here — `baseline cause` above already carries it.
  assert.ok(!/provenance cause/.test(r.out), "the same message must not appear on two rows");
  // The label must survive the fold even though the cause carries a foreign `: `.
  assert.match(r.out, /capability gate denies every tool/);
});

test("an already-present baseline is reported as such rather than as rebuilt", () => {
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, missing: ["/tmp/x"] }),
    restoreWorkflowProjectRoot: () => ({
      projectRoot: "/tmp/x",
      created: ["/tmp/x"],
      provenance: "recorded",
      baseline: { provenance: "existing" },
    }),
  }, { confirmed: true });
  assert.strictEqual(r.code, 0);
  assert.match(r.out, /workflow baseline: already present/);
  assert.match(r.out, /provenance {7}: recorded/);
  assert.ok(!r.out.includes("NOT rebuilt"));
});
