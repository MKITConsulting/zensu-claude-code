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
      repairBaseline: overrides.repairWorkflowBaseline,
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
    // The arm now owes the OTHER half of the repair, so a case about the created
    // count has to say what the document did — without a fake the real repair runs
    // against an empty request and the arm correctly refuses.
    repairWorkflowBaseline: () => ({ provenance: "recorded" }),
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

// --- the arms the round-5 review found unexercised --------------------------

test("the benign race counts the components this run planted above the root", () => {
  // `verdict.projectRoot` is the LAST missing component, so a race on it can follow
  // components this run really did create. The single-component fixture above makes
  // "created nothing" true and therefore cannot see the other tail at all.
  const raced = new Error("raced");
  raced.code = realCore.RESTORE_ALREADY_PRESENT_CODE;
  raced.created = ["/tmp/a", "/tmp/b"];
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, missing: ["/tmp/a", "/tmp/b", "/tmp/c"] }),
    restoreWorkflowProjectRoot: () => { throw raced; },
    repairWorkflowBaseline: () => ({ provenance: "recorded" }),
  }, { confirmed: true });
  assert.strictEqual(r.code, 0);
  assert.match(r.out, /created {10}: 2\n/);
  assert.match(r.out, /it did create the 2 component\(s\) above it, counted here/);
  assert.ok(!r.out.includes("created nothing"));
});

test("the benign race still owes the workflow document, and says so when it is missing", () => {
  // All three raced throws fire ABOVE repairWorkflowBaseline, so this arm used to
  // report ALREADY RESTORED and exit 0 with the second half of the repair never
  // attempted and never checked — the same end state the sibling arm exits 1 for,
  // because until the document exists the capability gate denies every tool.
  const raced = new Error("raced");
  raced.code = realCore.RESTORE_ALREADY_PRESENT_CODE;
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, missing: ["/tmp/x"] }),
    restoreWorkflowProjectRoot: () => { throw raced; },
    repairWorkflowBaseline: () => {
      throw new Error("session-control-v1: workflow document is present but unreadable");
    },
  }, { confirmed: true });
  assert.strictEqual(r.code, 1, "a half repair must not report success");
  assert.match(r.out, /ALREADY RESTORED/);
  assert.match(r.out, /workflow baseline: NOT rebuilt\n/);
  assert.match(r.out, /baseline cause {3}: /);
  assert.match(r.out, /capability gate denies every tool/);
});

test("the benign race rebuilds the document it still owes and then exits 0", () => {
  const raced = new Error("raced");
  raced.code = realCore.RESTORE_ALREADY_PRESENT_CODE;
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, missing: ["/tmp/x"] }),
    restoreWorkflowProjectRoot: () => { throw raced; },
    repairWorkflowBaseline: () => ({ provenance: "recorded" }),
  }, { confirmed: true });
  assert.strictEqual(r.code, 0);
  assert.match(r.out, /ALREADY RESTORED/);
  assert.match(r.out, /workflow baseline: rebuilt\n/);
});

test("the FAILED arm counts what it planted before it failed", () => {
  const failure = new Error("session-control-v1: recorded project root could not be created at /tmp/c: EACCES");
  failure.created = ["/tmp/a", "/tmp/b"];
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, missing: ["/tmp/a", "/tmp/b", "/tmp/c"] }),
    restoreWorkflowProjectRoot: () => { throw failure; },
  }, { confirmed: true });
  assert.strictEqual(r.code, 1);
  assert.match(r.out, /FAILED/);
  assert.match(r.out, /created {10}: 2 \(component\(s\) this run planted before it failed\)/);
});

test("a rebuild whose provenance entry failed is its own sentence", () => {
  // The row reads `baseline.provenance` only to tell "existing" from everything
  // else, so a rebuild that succeeded while its BASELINE_REBUILT history write
  // failed rendered as a clean `rebuilt` and exited 0. The loss compounds: a
  // missing history entry is also what silences the doctor's own rebuilt row, so
  // it disappears from both surfaces at once.
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, missing: ["/tmp/x"] }),
    restoreWorkflowProjectRoot: () => ({
      projectRoot: "/tmp/x",
      created: ["/tmp/x"],
      provenance: "recorded",
      baseline: {
        provenance: "unavailable",
        provenanceCause: "session-control-v1: workflow state is not writable",
      },
    }),
  }, { confirmed: true });
  assert.strictEqual(r.code, 0, "the rebuild itself succeeded");
  assert.match(r.out, /workflow baseline: rebuilt\n/);
  assert.match(r.out, /WARNING: the workflow document was rebuilt but its provenance entry/);
  assert.match(r.out, /baseline provenance cause : /);
});

test("the root-present remedy names the state this command can leave behind", () => {
  // Re-running the command after an interrupted --confirm cannot finish the job:
  // the strict read now SUCCEEDS, so the verdict is root-present and this refusal
  // is what the user reads. Telling them "the cause is a different one" is a claim
  // the code has not earned about a state it produces itself.
  const r = withCore({
    restoreRootVerdict: () => ({
      ok: false,
      reason: realCore.RESTORE_ROOT_REFUSALS.ROOT_PRESENT,
    }),
  }, {});
  assert.strictEqual(r.code, 1);
  assert.match(r.out, /interrupted/);
  assert.match(r.out, /adopt-session --confirm/);
  assert.ok(!r.out.includes("the cause is a different one"));
});

// --- the arms the round-2 consolidation found unexercised or wrong ---------

test("a workflow document that cannot be repaired is not sent to the rebuild remedy", () => {
  // repairWorkflowBaseline throws BASELINE_NOT_REPAIRABLE_CODE for an UNSAFE or
  // UNREADABLE document, and this module's own renderBaselineDiagnosis refuses to
  // offer a rebuild for exactly that state: something IS at that path, and rebuilding
  // over it would destroy the evidence. Folding it into the generic baselineError sent
  // the operator into a command that declines by design.
  const tamper = new Error("session-control-v1: workflow document is not a regular file");
  tamper.code = realCore.BASELINE_NOT_REPAIRABLE_CODE;
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, missing: ["/tmp/x"] }),
    restoreWorkflowProjectRoot: () => ({
      projectRoot: "/tmp/x",
      created: ["/tmp/x"],
      provenance: "recorded",
      baselineError: "session-control-v1: workflow document is not a regular file",
      baselineNotRepairable: true,
    }),
  }, { confirmed: true });
  assert.strictEqual(r.code, 1);
  assert.match(r.out, /workflow baseline: NOT rebuilt/);
  assert.match(r.out, /something is at that path/);
  assert.ok(!/adopt-session --confirm to rebuild/.test(r.out),
    "a non-repairable document must not be routed to the rebuild remedy");
});

test("the raced arm reports a non-repairable document without offering the rebuild", () => {
  const raced = new Error("raced");
  raced.code = realCore.RESTORE_ALREADY_PRESENT_CODE;
  const tamper = new Error("session-control-v1: workflow document is a symbolic link");
  tamper.code = realCore.BASELINE_NOT_REPAIRABLE_CODE;
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, missing: ["/tmp/x"] }),
    restoreWorkflowProjectRoot: () => { throw raced; },
    repairWorkflowBaseline: () => { throw tamper; },
  }, { confirmed: true });
  assert.strictEqual(r.code, 1);
  assert.match(r.out, /ALREADY RESTORED/);
  assert.match(r.out, /something is at that path/);
  assert.ok(!/adopt-session --confirm to rebuild/.test(r.out));
});

test("a baseline that was never established is not reported as rebuilt", () => {
  const raced = new Error("raced");
  raced.code = realCore.RESTORE_ALREADY_PRESENT_CODE;
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, missing: ["/tmp/x"] }),
    restoreWorkflowProjectRoot: () => { throw raced; },
    repairWorkflowBaseline: () => null,
  }, { confirmed: true });
  assert.match(r.out, /workflow baseline: not established/);
  assert.ok(!/workflow baseline: rebuilt/.test(r.out),
    "absence of information must not render as a positive claim");
  assert.strictEqual(r.code, 1);
});

test("the RESTORED branch renders a top-level provenance cause", () => {
  // The restore's OWN history write can fail while the rebuild succeeded. The row
  // existed with only a negative assertion naming it, which would have passed
  // unchanged if the row were deleted.
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, missing: ["/tmp/x"] }),
    restoreWorkflowProjectRoot: () => ({
      projectRoot: "/tmp/x",
      created: ["/tmp/x"],
      provenance: "unavailable",
      provenanceCause: "session-control-v1: workflow state is not writable",
      baseline: { provenance: "recorded" },
    }),
  }, { confirmed: true });
  assert.strictEqual(r.code, 0);
  assert.match(r.out, /provenance {7}: unavailable\n/);
  assert.match(r.out, /provenance cause : /);
  assert.ok(!/"provenance/.test(r.out), "the row label must not be folded");
});

test("the FAILED branch names a component that landed in the wrong tree", () => {
  const moved = new Error("session-control-v1: recorded project root is not restorable: unsafe-ancestor");
  moved.created = ["/tmp/a"];
  moved.misplaced = "/tmp/a/b";
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, missing: ["/tmp/a", "/tmp/a/b"] }),
    restoreWorkflowProjectRoot: () => { throw moved; },
  }, { confirmed: true });
  assert.strictEqual(r.code, 1);
  assert.match(r.out, /misplaced {8}: /);
  assert.match(r.out, /\/tmp\/a\/b/);
});

test("an unreadable ancestor is labelled unreadable, never as the nearest existing one", () => {
  const r = withCore({
    restoreRootVerdict: () => ({
      ok: false,
      reason: realCore.RESTORE_ROOT_REFUSALS.UNSAFE_ANCESTOR,
      at: "/tmp/locked/inner/gone",
      atUnreadable: true,
    }),
  }, {});
  assert.strictEqual(r.code, 1);
  assert.match(r.out, /  could not be read : /);
  // Scoped to the ROW. The remedy PROSE legitimately says "the nearest existing
  // directory" — it is describing the check, not labelling this value.
  assert.ok(!/ {2}nearest existing : /.test(r.out),
    "a path whose lstat just failed has not been proven to exist");
});
