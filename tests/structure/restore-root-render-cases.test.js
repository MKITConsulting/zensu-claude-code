"use strict";

// Drives the renderRestoreVerdict / performRestore / renderRestoreOutcome branches.
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

// Drives the two returning renderers the way main() does: resolve the verdict, render
// it, and go on to the write only when that render says to. Nothing here touches a
// global — the renderers hand back their text, which is the whole point of the split.
// The recorded root is a PARAMETER, not a literal. `main()` passes
// `restoreVerdict.projectRoot` — the root the verdict itself carried — so a helper that
// substitutes a fixed `/tmp/gone` cannot show a case where the rendered root and the
// judged root disagree, and every case built on it asserts against a path no verdict
// produced. `run.projectRoot` defaults to the same literal so the existing cases are
// byte-identical.
function withCore(overrides, run) {
  const confirmed = run.confirmed === true;
  const verdict = overrides.restoreRootVerdict({});
  const pre = report.renderRestoreVerdict(verdict, confirmed);
  if (!pre.proceed) return { code: pre.code, out: pre.text };
  const projectRoot = run.projectRoot !== undefined
    ? run.projectRoot
    : (verdict && verdict.projectRoot !== undefined ? verdict.projectRoot : "/tmp/gone");
  const post = report.renderRestoreOutcome(report.performRestore({}, projectRoot, {
    restore: overrides.restoreWorkflowProjectRoot,
    repairBaseline: overrides.repairWorkflowBaseline,
  }));
  return { code: post.code, out: pre.text + post.text };
}

test("the caller's root is what the raced arm renders, and nothing else supplies it", () => {
  // COVERAGE, not a bite. `performRestore`'s second parameter never reaches the WRITER —
  // `runRestore(request)` takes the request alone and resolves the root from the record —
  // so its only job is to bind `<path>` in the raced arm's own output. The raced THROW
  // carries `created` and nothing else, so this parameter is the sole source there: pass
  // the wrong one and the report tells the reader to run `git worktree add` against a
  // directory no verdict judged. `R15` pins the other half, that `main()` supplies the
  // verdict's own root.
  const raced = Object.assign(new Error("already present"), {
    code: realCore.RESTORE_ALREADY_PRESENT_CODE,
    created: ["/judged/root"],
  });
  const outcome = report.performRestore({}, "/judged/root", {
    restore: () => { throw raced; },
    repairBaseline: () => ({ provenance: "recorded" }),
  });
  assert.strictEqual(outcome.racedProjectRoot, "/judged/root");
  assert.match(report.renderRestoreOutcome(outcome).text, /\/judged\/root/,
    "the rendered disclosure binds <path> to the root the caller judged");
});

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

// The RESTORED-arm provenance WARNING must fire only when the history write was
// ATTEMPTED. restoreWorkflowProjectRoot sets `provenance: "unavailable"` with
// `provenanceCause: null` and SKIPS mutateWorkflowState entirely when baselineError is
// set — so a guard keyed on `provenance !== "recorded"` names a write failure that
// never happened, and does it in the same run that prints the actionable
// `--confirm` remedy fifteen lines below. Two cases, because "absent on the skipped
// path" alone passes for a renderer that deleted the warning outright.
test("no provenance WARNING when the history write was never attempted", () => {
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, missing: ["/tmp/x"] }),
    restoreWorkflowProjectRoot: () => ({
      projectRoot: "/tmp/x",
      created: ["/tmp/x"],
      provenance: "unavailable",
      provenanceCause: null,
      baselineError: "session-control-v1: workflow document is present but unreadable",
    }),
  }, { confirmed: true });
  assert.ok(!/the history entry recording it could/.test(r.out),
    "the warning names a write that the core never attempted on this path");
  // The run must still say what DID go wrong, or suppressing the warning would have
  // traded a false sentence for silence.
  assert.match(r.out, /capability gate denies every tool/);
});

test("the provenance WARNING still fires when the history write itself failed", () => {
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, missing: ["/tmp/x"] }),
    restoreWorkflowProjectRoot: () => ({
      projectRoot: "/tmp/x",
      created: ["/tmp/x"],
      provenance: "unavailable",
      provenanceCause: "session-control-v1: history write refused",
      baseline: { provenance: "recorded" },
    }),
  }, { confirmed: true });
  assert.match(r.out, /the history entry recording it could/,
    "a genuine history-write failure must still warn");
});

// THE HEADER CONTRACT OF `restoreBaselineRows`: an unestablished baseline is its own
// state and its own non-zero exit. The RACED caller honours it (`return racedBaseline ?
// 0 : 1`); the RESTORED branch branched only on `baselineError`, so a result carrying
// neither a baseline nor a fault rendered the "not established" row and then the
// unqualified closing line under the headline RESTORED, and exited 0. It is LATENT
// rather than live — every arm of the shipped core sets exactly one of the two, and
// `core` is required relatively from the same tree — so this case reaches it through
// the `deps.restore` seam, which is the only caller that can. A latent contract
// violation is still one: the next core arm that returns a falsy baseline would print
// a clean RESTORED over a document nobody established.
test("a restore that establishes no baseline and reports no fault exits non-zero", () => {
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, missing: ["/tmp/x"] }),
    restoreWorkflowProjectRoot: () => ({
      projectRoot: "/tmp/x",
      created: ["/tmp/x"],
      provenance: "recorded",
      provenanceCause: null,
      baseline: null,
      baselineError: null,
    }),
  }, { confirmed: true });
  assert.strictEqual(r.code, 1, "an unestablished baseline is its own non-zero exit");
  assert.ok(!/no restart is needed/.test(r.out),
    "the unqualified closing line must not print over a document nobody established");
  assert.match(r.out, /could not be established/,
    "the run must say what it could not establish rather than going quiet");
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

// THE OWNERSHIP REFUSAL NAMES A DIFFERENT COMPONENT FROM ITS SIBLING, so it cannot
// borrow its sibling's label. `restoreRootComponentLadder` reports the NEAREST existing
// component for every other UNSAFE_ANCESTOR cause, but the ownership cause comes from
// `restoreAncestorChainOffender`, which walks DOWN from the filesystem root and returns
// the FIRST component that fails — the HIGHEST one on the path, which is routinely a
// grandparent several levels above the nearest existing one. Calling that "nearest
// existing" is a false claim in a row an operator acts on with a chmod.
test("the ownership refusal does not call its offender the nearest existing component", () => {
  const r = withCore({
    restoreRootVerdict: () => ({
      ok: false,
      reason: realCore.RESTORE_ROOT_REFUSALS.UNSAFE_ANCESTOR_OWNERSHIP,
      at: "/tmp/shared",
    }),
  }, {});
  assert.strictEqual(r.code, 1);
  assert.match(r.out, /  offending ancestor : \/tmp\/shared/);
  assert.ok(!/nearest existing : \/tmp\/shared/.test(r.out),
    "the row must not claim a position this walk never established");
  assert.ok(!/The nearest existing directory on the way to the recorded root is not one/
    .test(r.out), "and neither must the remedy prose that reads it");
});

// ...and the SIBLING cause still uses the label that is true of it, or the fix would
// have renamed a row that was correct.
test("the non-ownership ancestor refusal keeps the nearest-existing label", () => {
  const r = withCore({
    restoreRootVerdict: () => ({
      ok: false,
      reason: realCore.RESTORE_ROOT_REFUSALS.UNSAFE_ANCESTOR,
      at: "/tmp/linked",
    }),
  }, {});
  assert.match(r.out, /  nearest existing : \/tmp\/linked/);
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

// --- what the rendered text must say, on the arms a user actually reads ------
//
// Every one of these five is a sentence that was either missing or unqualified. They
// are graded on the RENDERED output rather than on the source, because the source is
// a template string and a source pin passes whatever %s expands to.

// The pre-confirm block is the surface where the user DECIDES, and it was the only
// carrier stating the root is "gone" without the caveat both Stop-hook arms carry:
// an ENOENT cannot tell a deleted directory from a moved or renamed one, or from an
// unmounted volume. CLAUDE.md holds every mirror of this claim to "not reachable",
// never "gone", and this carrier was outside that roster.
test("the pre-confirm block does not claim the root is gone rather than unreachable", () => {
  const r = withCore({
    restoreRootVerdict: () => ({
      ok: true,
      projectRoot: "/tmp/x/root",
      nearestExisting: "/tmp/x",
      missing: ["/tmp/x/root"],
    }),
  }, { confirmed: false });
  assert.strictEqual(r.code, 0);
  assert.match(r.out, /RESTORABLE/);
  assert.match(r.out, /moved or renamed/i,
    "the one surface where the user decides must carry the caveat both Stop arms carry");
  assert.match(r.out, /moving it back/i,
    "and must name the better remedy when the directory was moved rather than deleted");
});

// The raced arm writes a fresh baseline and exits 0. Every OTHER arm that writes one
// prints RESTORE_DISCLOSURE first, so this was the one path on which a user got a
// rebuilt document without being told the chain state under that root is gone.
test("the already-restored arm states what the rebuild cost", () => {
  const raced = new Error("raced");
  raced.code = realCore.RESTORE_ALREADY_PRESENT_CODE;
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, missing: ["/tmp/x"] }),
    restoreWorkflowProjectRoot: () => { throw raced; },
    repairWorkflowBaseline: () => ({ provenance: "recorded" }),
  }, { confirmed: true });
  assert.strictEqual(r.code, 0);
  assert.match(r.out, /ALREADY RESTORED/);
  assert.match(r.out, /What this repairs, and what it does NOT/,
    "an arm that writes a baseline owes the same disclosure as every other one");
});

// A failed provenance write on the RESTORE's own history entry rendered as two quiet
// label rows under the headline RESTORED, then exited 0. All three sibling paths
// treat the identical value as a WARNING, and PROJECT_ROOT_RESTORED is this feature's
// only provenance mechanism — an unwritten entry means the repair left no trace.
test("a failed restore provenance write is a warning, not a quiet label row", () => {
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
  assert.match(r.out, /WARNING: /,
    "the sibling paths all warn on this value; this one must too");
  assert.match(r.out, /unrecorded/i,
    "and must say what was lost: the repair happened and left no durable trace");
});

// The disclosure prescribed `git worktree add <path> <branch>` — but by the time the
// user reads it on the success path, repairWorkflowBaseline has already created
// <path>/.zensu/state, and git refuses a non-empty target. The command was therefore
// unrunnable at exactly the moment it was offered.
test("the disclosure does not prescribe a command the repair makes unrunnable", () => {
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, projectRoot: "/tmp/x", missing: ["/tmp/x"] }),
  }, { confirmed: false });
  assert.match(r.out, /git worktree add/);
  assert.match(r.out, /not empty|non-empty|--force/i,
    "the repair leaves .zensu under the root, so a plain `git worktree add` refuses");
});

// "No restart is needed" was the last line printed and the only imperative one, over
// a directory with no git repo, no branch and no history. The realistic incident is a
// session's worth of work written into an untracked stub.
test("the closing success line carries its operational cost", () => {
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, missing: ["/tmp/x"] }),
    restoreWorkflowProjectRoot: () => ({
      projectRoot: "/tmp/x",
      created: ["/tmp/x"],
      provenance: "recorded",
      baseline: { provenance: "recorded" },
    }),
  }, { confirmed: true });
  assert.strictEqual(r.code, 0);
  assert.match(r.out, /anchored again/);
  assert.match(r.out, /untracked/i,
    "an unqualified all-clear invites a session's work into a directory with no repository");
});

// --- a core that predates the restore must not kill the whole report ---------
//
// RESTORE_REMEDY built its computed keys from core.RESTORE_ROOT_REFUSALS at MODULE
// scope, so a core without that export made `require` of this file throw a TypeError
// before main() ran — taking down the ORDINARY `--confirm` adoption too, which is the
// one command that repairs a wedged session. The same file already typeof-guards
// three other new core symbols for exactly that skew, so the posture was internally
// inconsistent.
//
// The copy is a real one: the module and its siblings are copied into a temp tree and
// the core is replaced by a stub that exports everything EXCEPT the new constant. A
// stub in the live tree would poison the module cache for every case in this file.
test("a core without RESTORE_ROOT_REFUSALS leaves the report loadable", () => {
  const fs = require("node:fs");
  const os = require("node:os");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "zensu-restore-skew-"));
  try {
    const lib = path.join(ROOT, "hooks", "lib");
    for (const name of fs.readdirSync(lib)) {
      const from = path.join(lib, name);
      if (fs.statSync(from).isFile()) fs.copyFileSync(from, path.join(dir, name));
    }
    // The stub re-exports the real core minus the one constant this file must not
    // hard-depend on. Everything else the report reads stays exactly as shipped.
    fs.writeFileSync(path.join(dir, "session-control-core-v1.js"),
      'const real = require(' + JSON.stringify(CORE_PATH) + ');\n'
      + 'const clone = Object.assign({}, real);\n'
      + 'delete clone.RESTORE_ROOT_REFUSALS;\n'
      + 'module.exports = clone;\n');
    let skewed;
    assert.doesNotThrow(() => {
      skewed = require(path.join(dir, "session-adopt-report-v1.js"));
    }, "a core without the restore vocabulary must not break require of the report");
    // The ordinary adoption path still renders: that is the half the skew was taking
    // down, and it is the one that repairs a wedged session.
    assert.strictEqual(typeof skewed.renderBaselineNotes, "function");
    assert.strictEqual(typeof skewed.main, "function");
    // ...and the restore arm degrades with a named reason rather than silently
    // rendering a refusal it cannot explain.
    const r = skewed.renderRestoreVerdict({ ok: false, reason: "record-unreadable" }, false);
    assert.strictEqual(r.code, 1);
    assert.match(r.text, /NOT restorable \(/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// --- a PARTIALLY skewed core must not manufacture a remedy -------------------
//
// The lazy table guards only that RESTORE_ROOT_REFUSALS is an object. A core missing
// individual MEMBERS computes `[undefined]` for each one, so every missing member
// collapses onto the single string key "undefined" and the last literal wins. A
// verdict whose `reason` is itself undefined then finds that key through
// hasOwnProperty, skips the no-remedy fallback, and renders a remedy for a refusal
// nobody identified — the one outcome that fallback exists to prevent.
test("a partially skewed core renders no remedy rather than a collapsed one", () => {
  const fs = require("node:fs");
  const os = require("node:os");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "zensu-remedy-skew-"));
  try {
    const lib = path.join(ROOT, "hooks", "lib");
    for (const name of fs.readdirSync(lib)) {
      const from = path.join(lib, name);
      if (fs.statSync(from).isFile()) fs.copyFileSync(from, path.join(dir, name));
    }
    fs.writeFileSync(path.join(dir, "session-control-core-v1.js"),
      'const real = require(' + JSON.stringify(CORE_PATH) + ');\n'
      + 'const clone = Object.assign({}, real);\n'
      + 'const reasons = Object.assign({}, real.RESTORE_ROOT_REFUSALS);\n'
      + 'delete reasons.UNSAFE_ANCESTOR;\n'
      + 'delete reasons.TOO_MANY_MISSING_COMPONENTS;\n'
      + 'clone.RESTORE_ROOT_REFUSALS = reasons;\n'
      + 'module.exports = clone;\n');
    const skewed = require(path.join(dir, "session-adopt-report-v1.js"));
    const rendered = skewed.renderRestoreVerdict({ ok: false }, false);
    const out = rendered.text;
    const code = rendered.code;
    assert.strictEqual(code, 1);
    assert.match(out, /No remedy is known for this refusal/,
      "an unidentified refusal must fall through, never inherit a collapsed key");
    assert.ok(!/Too many directories on the way/.test(out),
      "the last member dropped by the skew must not become the answer for every refusal");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// --- the rebuild's provenance CAUSE survives the repair ----------------------
//
// repairWorkflowBaseline splits a failed provenance write into `provenance:
// "unavailable"` plus a separate `provenanceCause`, and renderBaselineNotes reads
// both. repairBaseline composed its return by hand and copied only `provenance`,
// so the cause row was unreachable on the one path that repairs in place — the
// diagnostic the previous release printed was silently deleted.
//
// The seam is the same shape performRestore already takes, so the arm is
// drivable without touching the module cache.
test("repairBaseline carries the rebuild's provenance cause", () => {
  const baseline = report.repairBaseline(
    { sessionId: "s" },
    { state: realCore.BASELINE_STATES.MISSING },
    { repairBaseline: () => ({ provenance: "unavailable", provenanceCause: "disk full", path: "/p" }) },
  );
  assert.strictEqual(baseline.provenance, "unavailable");
  assert.strictEqual(baseline.provenanceCause, "disk full",
    "the cause must survive, or the row that renders it can never fire");
  assert.strictEqual(baseline.rebuilt, true);
});

test("a repair that recorded its provenance carries no cause", () => {
  const baseline = report.repairBaseline(
    { sessionId: "s" },
    { state: realCore.BASELINE_STATES.MISSING },
    { repairBaseline: () => ({ provenance: "recorded", path: "/p" }) },
  );
  assert.strictEqual(baseline.provenance, "recorded");
  assert.ok(!baseline.provenanceCause, "a clean rebuild has no cause to report");
});

// The renderer end of the same pair: given the repaired shape, the WARNING and the
// cause row both render. Without the copy above this case passes while the real
// path prints neither.
test("renderBaselineNotes renders the cause a repair carried through", () => {
  const out = report.renderBaselineNotes(
    { state: realCore.BASELINE_STATES.PRESENT, rebuilt: true, provenance: "unavailable", provenanceCause: "disk full" },
    "scv1_" + "a".repeat(64),
  );
  assert.match(out, /WARNING: the rebuild succeeded but its provenance entry could not be written/);
  assert.match(out, /provenance cause : disk full/);
});

// renderBaselineNotes must ask the CORE's predicate rather than spelling the rule
// itself: the core states that `baselineProvenanceUnrecorded` has three carriers,
// and this file was the one still hand-spelling `provenance !== "recorded"`, so the
// claim was short by one. `existing` is the discriminator — the shared predicate
// excludes it because nothing was rebuilt, a bare inequality does not.
test("renderBaselineNotes uses the shared unrecorded-provenance predicate", () => {
  const out = report.renderBaselineNotes(
    { state: realCore.BASELINE_STATES.PRESENT, rebuilt: true, provenance: "existing" },
    "scv1_" + "a".repeat(64),
  );
  assert.ok(!/WARNING: the rebuild succeeded but its provenance entry/.test(out),
    "`existing` means nothing was rebuilt, so there is no provenance entry to miss");
});

// The case above cannot FAIL on its own: `renderBaselineNotes` stays silent for
// `existing` whether the shared predicate decided that or a local twin did. What is
// worth holding is what a core WITHOUT the export does, and that answer CHANGED. A
// guarded fallback used to stand beside each call and re-spell the rule from the raw
// value the core's own header forbids consumers to compare — it guessed where the core
// prescribes withholding, and it had already drifted from the owner once.
// `provenanceUnrecorded` is THREE-VALUED now: `null` is "this check could not be made",
// and every writer that consumes it must SAY so. A silent fall-through is the failure
// this repository names as worse than the finding it replaces — a check that never ran
// reading exactly like a clean one.
test("a core without the provenance predicate discloses a missing check, never a verdict", () => {
  const fs = require("node:fs");
  const os = require("node:os");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "zensu-provenance-skew-"));
  try {
    const lib = path.join(ROOT, "hooks", "lib");
    for (const name of fs.readdirSync(lib)) {
      const from = path.join(lib, name);
      if (fs.statSync(from).isFile()) fs.copyFileSync(from, path.join(dir, name));
    }
    fs.writeFileSync(path.join(dir, "session-control-core-v1.js"),
      'const real = require(' + JSON.stringify(CORE_PATH) + ');\n'
      + 'const clone = Object.assign({}, real);\n'
      + 'delete clone.baselineProvenanceUnrecorded;\n'
      + 'module.exports = clone;\n');
    const skewed = require(path.join(dir, "session-adopt-report-v1.js"));
    assert.strictEqual(typeof realCore.baselineProvenanceUnrecorded, "function",
      "control: the shipped core really exports the predicate this clone removes");
    assert.strictEqual(
      typeof require(path.join(dir, "session-control-core-v1.js")).baselineProvenanceUnrecorded,
      "undefined",
      "control: the clone really lacks it, so `skewed` cannot answer");
    const sid = "scv1_" + "a".repeat(64);
    const baseline = {
      state: realCore.BASELINE_STATES.PRESENT,
      rebuilt: true,
      provenance: "unavailable",
    };

    // THE THREE WRITERS that consume the predicate. Only `renderBaselineNotes` is
    // exported, so the other two are reached through `renderRestoreOutcome`: the raced
    // arm renders `restoreBaselineRows`, the restored arm renders
    // `restoreProvenanceRows`. A fourth consumer has to be added here — the whole point
    // of the three-valued return is that none of them may answer from a rule of its own.
    const notes = skewed.renderBaselineNotes(baseline, sid);
    const raced = skewed.renderRestoreOutcome({
      kind: "raced",
      racedMade: 1,
      racedBaseline: { provenance: "unavailable" },
      racedBaselineError: null,
      racedTamper: false,
    }).text;
    const restored = skewed.renderRestoreOutcome({
      kind: "restored",
      restored: {
        projectRoot: "/p/root",
        created: ["/p/root"],
        baseline: { provenance: "recorded" },
        provenance: "unavailable",
      },
    }).text;

    for (const [where, text] of [["renderBaselineNotes", notes],
      ["restoreBaselineRows", raced],
      ["restoreProvenanceRows", restored]]) {
      assert.match(text, /could not be checked/,
        where + " must say the check could not be made");
      assert.match(text, /not an\n?\s*all-clear|A missing check, not an/,
        where + " must say a missing check is not an all-clear");
      assert.ok(!/WARNING/.test(text),
        where + " must not manufacture a verdict it could not reach");
    }
    // The restored arm renders BOTH writers, so a generic needle there is satisfied by
    // the baseline row alone. This one is the provenance writer's own sentence.
    assert.match(restored, /whether that provenance entry was written could not be checked/,
      "restoreProvenanceRows discloses on its own, not through its neighbour");

    // CONTROL, in BOTH directions. The SHIPPED core answers, so the same input reaches a
    // real verdict and claims no missing check — without this the loop above would pass
    // against a module that disclosed unconditionally.
    const realNotes = report.renderBaselineNotes(baseline, sid);
    assert.match(realNotes, /WARNING: the rebuild succeeded but its provenance entry/,
      "control: with the export present the verdict IS reached");
    assert.ok(!/could not be checked/.test(realNotes),
      "control: a check that ran never claims it was unreachable");
    // And `existing` stays silent under the shipped core — the value the retired local
    // twin warned about, which is what made it a divergence rather than a copy.
    const existing = report.renderBaselineNotes(
      { state: realCore.BASELINE_STATES.PRESENT, rebuilt: true, provenance: "existing" },
      sid,
    );
    assert.ok(!/WARNING: the rebuild succeeded but its provenance entry/.test(existing),
      "`existing` means nothing was rebuilt, so there is no provenance entry to miss");
    assert.ok(!/could not be checked/.test(existing),
      "a reachable check that answered `false` is not a missing one");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// --- the two renderers return their lines instead of writing them ------------
//
// Every sibling renderer in session-adopt-report-v1.js — renderBaselineDiagnosis,
// renderBaselineNotes, renderLeaseWarnings — opens `const out = []; const w =
// (line) => out.push(line);` and RETURNS. The former renderRestoreRoot wrote straight to
// process.stdout and returned only an exit code, which is the write-only shape the
// renderLeaseWarnings lesson was about, and it forced every case above to intercept
// a global. These cases pin the returning shape: plain object literals in, text and
// an exit code out, no module cache and no global touched.

test("renderRestoreVerdict returns a refusal's text and exit code", () => {
  const r = report.renderRestoreVerdict(
    { ok: false, reason: realCore.RESTORE_ROOT_REFUSALS.RECORD_UNREADABLE },
    false,
  );
  assert.strictEqual(typeof r.text, "string", "the renderer returns text");
  assert.strictEqual(r.code, 1);
  assert.strictEqual(r.proceed, false, "a refusal never proceeds to the write");
  assert.match(r.text, /NOT restorable \(/);
});

test("renderRestoreVerdict reports an unconfirmed run without proceeding", () => {
  const r = report.renderRestoreVerdict(
    { ok: true, projectRoot: "/p/root", nearestExisting: "/p", missing: ["/p/root"] },
    false,
  );
  assert.strictEqual(r.code, 0);
  assert.strictEqual(r.proceed, false, "without --confirm nothing is written");
  assert.match(r.text, /RESTORABLE/);
  assert.match(r.text, /Nothing has been changed/);
});

test("renderRestoreVerdict proceeds only when the verdict is ok and confirmed", () => {
  const r = report.renderRestoreVerdict(
    { ok: true, projectRoot: "/p/root", nearestExisting: "/p", missing: ["/p/root"] },
    true,
  );
  assert.strictEqual(r.proceed, true);
  assert.strictEqual(r.text, "", "a proceeding verdict prints nothing of its own");
});

test("renderRestoreOutcome returns the RESTORED text and exit code", () => {
  const r = report.renderRestoreOutcome({
    kind: "restored",
    restored: {
      projectRoot: "/p/root",
      created: ["/p/root"],
      baseline: { provenance: "recorded" },
      provenance: "recorded",
    },
  });
  assert.strictEqual(r.code, 0);
  assert.match(r.text, /RESTORED/);
  assert.match(r.text, /anchored again/);
});

test("renderRestoreOutcome returns the FAILED text and exit code", () => {
  const r = report.renderRestoreOutcome({
    kind: "failed",
    error: { message: "session-control-v1: mkdir refused" },
  });
  assert.strictEqual(r.code, 1);
  assert.match(r.text, /FAILED/);
  assert.match(r.text, /mkdir refused/);
});

test("renderRestoreOutcome returns the raced text and exit code", () => {
  const r = report.renderRestoreOutcome({
    kind: "raced",
    racedMade: 2,
    racedBaseline: { provenance: "recorded" },
    racedBaselineError: null,
    racedTamper: false,
  });
  assert.strictEqual(r.code, 0);
  assert.match(r.text, /ALREADY RESTORED/);
  assert.match(r.text, /created\s+: 2/);
});

// --- the raced arm reports the provenance it now writes ---------------------
//
// A raced-partial run no longer throws out of the core's loop: it completes, writes
// its PROJECT_ROOT_RESTORED entry and returns `alreadyPresent`. That makes this arm
// a provenance-WRITING one, so it owes the same two rows and the same WARNING the
// RESTORED arm prints. The throw path still carries none, and must not grow them.

test("a raced run that recorded its provenance reports it", () => {
  const r = report.renderRestoreOutcome({
    kind: "raced",
    racedMade: 2,
    racedBaseline: { provenance: "recorded" },
    racedBaselineError: null,
    racedTamper: false,
    racedProvenance: "recorded",
    racedProvenanceCause: null,
  });
  assert.strictEqual(r.code, 0);
  assert.match(r.text, /provenance {7}: recorded/);
  assert.ok(!/WARNING: the component\(s\)/.test(r.text),
    "a recorded entry is not a warning");
});

test("a raced run whose provenance write failed warns and names the cause", () => {
  const r = report.renderRestoreOutcome({
    kind: "raced",
    racedMade: 2,
    racedBaseline: { provenance: "recorded" },
    racedBaselineError: null,
    racedTamper: false,
    racedProvenance: "unavailable",
    racedProvenanceCause: "disk full",
  });
  assert.strictEqual(r.code, 0);
  assert.match(r.text, /provenance cause : disk full/);
  assert.match(r.text, /WARNING: the component\(s\) this run created are recorded nowhere/);
});

// --- the raced arm owes what the RESTORED arm owes --------------------------
//
// Three gaps, one cause: the raced arm grew into a writing arm and its returns were
// never re-ordered against the sibling's. The disclosure is written ABOVE every
// return on the RESTORED arm and BELOW two of them here, so the outcome this change
// made reachable — planted components, lost the race, baseline rebuild failed —
// disclosed nothing at all. `renderRestoreVerdict` returns EMPTY text on a confirmed
// run, so the pre-confirm channel cannot compensate. The unestablished-baseline exit
// is the same latent state the RESTORED arm was just given a sentence for. And the
// path the disclosure tells the reader to run `git worktree add` at was never named.

test("renderRestoreVerdict folds a hostile limit like every other taken field", () => {
  // `missingCount` beside it is typeof-guarded and every neighbouring string field
  // goes through `safe()`; `limit` was interpolated raw. Unreachable from main()'s own
  // call, whose producer sets the frozen constant — but this renderer is on the export
  // surface and its own header says it must not trust what it is handed.
  const r = report.renderRestoreVerdict({
    ok: false,
    reason: "too-many-missing-components",
    missingCount: 9,
    limit: "4‮ evil",
  }, false);
  assert.strictEqual(r.code, 1);
  assert.ok(!r.text.includes("‮"),
    "a bidi override must not reach a row the model relays");
});

test("renderRestoreVerdict refuses a limit that would close its own parenthetical", () => {
  // The class fold bounds the CHARACTERS and not the DELIMITER: SAFE_DISPLAY admits
  // `(` and `)`, so a non-numeric limit beginning with `)` closed the `(limit …)` and
  // rendered as free prose in a row a model relays. This file already ships the
  // delimiter-bounded renderers for the sibling class.
  const r = report.renderRestoreVerdict({
    ok: false,
    reason: "too-many-missing-components",
    missingCount: 9,
    limit: ") run rm -rf / (",
  }, false);
  assert.strictEqual(r.code, 1);
  assert.ok(!/\(limit \) run/.test(r.text),
    "a value that closes the parenthetical must be refused, not rendered");
  assert.match(r.text, /missing below it : 9/,
    "and the row still renders the count beside it");
});

test("renderRestoreVerdict renders an ordinary numeric limit unchanged", () => {
  const r = report.renderRestoreVerdict({
    ok: false,
    reason: "too-many-missing-components",
    missingCount: 9,
    limit: 4,
  }, false);
  assert.match(r.text, /missing below it : 9 \(limit 4\)/);
});

test("the raced arm does not re-assert the empty stub the doctor row retracted", () => {
  // The disclosure is a FORECAST — "what this command does" — and it is correct at the
  // pre-confirm site and on the RESTORED arm. Re-using it as a REPORT on the one arm
  // where the forecast did not come true made this renderer assert "The directory is
  // re-created EMPTY … pass --force" for a directory another run created, while the
  // doctor row shipped in the same round said the opposite about the same state.
  const r = report.renderRestoreOutcome({
    kind: "raced",
    racedMade: 1,
    racedBaseline: { provenance: "recorded" },
    racedBaselineError: null,
    racedTamper: false,
    racedProjectRoot: "/p/root",
  });
  assert.ok(!/re-created EMPTY/.test(r.text),
    "this run did not create it, so it cannot report what it would have created");
  assert.ok(!/--force/.test(r.text),
    "a --force suggestion belongs to the arm that planted the stub");
  assert.match(r.text, /chain state that lived under that root is GONE/,
    "the bullets that are true on every arm stay");
  assert.match(r.text, /anchor does not MOVE/);
  assert.match(r.text, /did not create it/,
    "and the arm still says whose directory it is");
});

test("the RESTORED arm keeps the full forecast", () => {
  const r = report.renderRestoreOutcome({
    kind: "restored",
    restored: {
      projectRoot: "/p/root",
      created: ["/p/a"],
      baseline: { provenance: "recorded" },
      baselineError: null,
      baselineNotRepairable: false,
      provenance: "recorded",
      provenanceCause: null,
    },
  });
  assert.match(r.text, /re-created EMPTY/,
    "this arm DID plant the stub, so the forecast is the report");
  assert.match(r.text, /--force/);
});

test("the pre-confirm verdict keeps the full forecast", () => {
  const r = report.renderRestoreVerdict({
    ok: true,
    projectRoot: "/p/root",
    nearestExisting: "/p",
    missing: ["/p/root"],
  }, false);
  assert.match(r.text, /re-created EMPTY/,
    "nothing has happened yet, so the forecast is exactly what is owed");
});

test("a raced run whose baseline rebuild failed still discloses the cost", () => {
  const r = report.renderRestoreOutcome({
    kind: "raced",
    racedMade: 1,
    racedBaseline: null,
    racedBaselineError: "session-control-v1: rebuild refused",
    racedTamper: false,
    racedProjectRoot: "/p/root",
  });
  assert.strictEqual(r.code, 1);
  assert.match(r.text, /What this repairs, and what it does NOT:/,
    "the arm that writes a directory owes the disclosure whatever the baseline did");
  assert.match(r.text, /workflow document is NOT/);
});

test("a raced run whose baseline was TAMPERED still discloses the cost", () => {
  const r = report.renderRestoreOutcome({
    kind: "raced",
    racedMade: 1,
    racedBaseline: null,
    racedBaselineError: "session-control-v1: unsafe",
    racedTamper: true,
    racedProjectRoot: "/p/root",
  });
  assert.strictEqual(r.code, 1);
  assert.match(r.text, /What this repairs, and what it does NOT:/);
});

test("a raced run whose tamper check could not be made withholds the rebuild remedy", () => {
  // `restoreNotRepairable` is THREE-VALUED: `null` is "this check could not be made",
  // which is what an executing core without `isBaselineNotRepairable` produces. The
  // renderer read the field with a bare truth test, so `null` took the `false` arm and
  // prescribed `/zensu:adopt-session --confirm` — the operation that DECLINES on the
  // tamper this run could not rule out. Withholding a check is not evidence there is
  // nothing to withhold.
  const r = report.renderRestoreOutcome({
    kind: "raced",
    racedMade: 1,
    racedBaseline: null,
    racedBaselineError: "session-control-v1: something went wrong",
    racedTamper: null,
    racedProjectRoot: "/p/root",
  });
  assert.strictEqual(r.code, 1);
  assert.match(r.text, /could not be checked/,
    "a withheld check is disclosed, never answered");
  assert.doesNotMatch(r.text, /adopt-session --confirm to rebuild/,
    "the rebuild remedy is the operation that declines on the tamper this could not rule out");
  assert.match(r.text, /zensu:doctor/, "the reader still gets somewhere to go");
});

test("a raced run with a known tamper still takes the tamper arm", () => {
  // The control for the case above: `false` and `null` must not render alike, and
  // `true` keeps the note it always had.
  const known = report.renderRestoreOutcome({
    kind: "raced",
    racedMade: 1,
    racedBaseline: null,
    racedBaselineError: "session-control-v1: unsafe",
    racedTamper: true,
    racedProjectRoot: "/p/root",
  });
  assert.match(known.text, /must not be: something is at that path/);
  const clear = report.renderRestoreOutcome({
    kind: "raced",
    racedMade: 1,
    racedBaseline: null,
    racedBaselineError: "session-control-v1: write failed",
    racedTamper: false,
    racedProjectRoot: "/p/root",
  });
  assert.match(clear.text, /adopt-session --confirm to rebuild/,
    "a check that WAS made and came back clean keeps the rebuild remedy");
});

test("a raced run that established no baseline says so and exits non-zero", () => {
  const r = report.renderRestoreOutcome({
    kind: "raced",
    racedMade: 1,
    racedBaseline: null,
    racedBaselineError: null,
    racedTamper: false,
    racedProjectRoot: "/p/root",
  });
  assert.strictEqual(r.code, 1);
  assert.match(r.text, /could not be established/,
    "exit 1 with no sentence is the gap the RESTORED arm was just fixed for");
});

test("the raced arm names the recorded project root the disclosure points at", () => {
  const r = report.renderRestoreOutcome({
    kind: "raced",
    racedMade: 1,
    racedBaseline: { provenance: "recorded" },
    racedBaselineError: null,
    racedTamper: false,
    racedProjectRoot: "/p/root",
  });
  assert.match(r.text, /recorded project : \/p\/root/,
    "`git worktree add <path>` is useless while <path> is bound nowhere in the output");
});

test("the raced arm omits the project row when the outcome carries no root", () => {
  const r = report.renderRestoreOutcome({
    kind: "raced",
    racedMade: 0,
    racedBaseline: { provenance: "recorded" },
    racedBaselineError: null,
    racedTamper: false,
  });
  assert.ok(!/recorded project : /.test(r.text),
    "the throw path has no root to name and must not invent one");
});

test("a raced provenance failure beside a baseline fault suppresses the warning", () => {
  // The second conjunct of `racedProvenance !== "recorded" && !racedBaselineError`.
  // Both existing provenance cases pass `racedBaselineError: null`, so the conjunct
  // that decides this combination had no case: the core SKIPS the history write
  // entirely when the baseline failed, so `provenance` is non-recorded on a path
  // where nothing was ever attempted, and warning there names a failure that did
  // not happen.
  const r = report.renderRestoreOutcome({
    kind: "raced",
    racedMade: 2,
    racedBaseline: null,
    racedBaselineError: "session-control-v1: rebuild refused",
    racedTamper: false,
    racedProvenance: "unavailable",
    racedProvenanceCause: null,
    racedProjectRoot: "/p/root",
  });
  assert.strictEqual(r.code, 1);
  assert.match(r.text, /provenance {7}: unavailable/);
  assert.ok(!/WARNING: the component\(s\)/.test(r.text),
    "nothing was written to fail, so no warning is owed");
});

test("the raced THROW arm names the root the disclosure points at", () => {
  // `main()` computed the verdict as an inline argument and retained nothing, so
  // `performRestore` had no root and this arm could not name one — while the disclosure
  // beside it says to run `git worktree add <path>`. The error object genuinely carries
  // only `created`; the CALL SITE is what holds the root.
  const raced = new Error("session-control-v1: already present");
  raced.code = realCore.RESTORE_ALREADY_PRESENT_CODE;
  raced.created = ["/p/a"];
  const outcome = report.performRestore({}, "/p/root", {
    restore: () => { throw raced; },
    repairBaseline: () => ({ provenance: "recorded" }),
  });
  assert.strictEqual(outcome.kind, "raced");
  assert.strictEqual(outcome.racedProjectRoot, "/p/root");
  const r = report.renderRestoreOutcome(outcome);
  assert.match(r.text, /recorded project : \/p\/root/);
});

test("performRestore carries the already-present baseline through its own arm", () => {
  // `core.isBaselineAlreadyPresent(baselineRepairFault)` had no executed case
  // anywhere: no case threw an error carrying the code through performRestore.
  const fault = new Error("session-control-v1: baseline already present");
  fault.code = realCore.BASELINE_ALREADY_PRESENT_CODE;
  const raced = new Error("session-control-v1: already present");
  raced.code = realCore.RESTORE_ALREADY_PRESENT_CODE;
  raced.created = ["/p/a"];
  const outcome = report.performRestore({}, "", {
    restore: () => { throw raced; },
    repairBaseline: () => { throw fault; },
  });
  assert.strictEqual(outcome.kind, "raced");
  assert.deepStrictEqual(outcome.racedBaseline, { provenance: "existing" });
  assert.strictEqual(outcome.racedBaselineError, null);
  assert.strictEqual(outcome.racedTamper, false);
});

test("the raced THROW path carries no provenance rows", () => {
  const r = report.renderRestoreOutcome({
    kind: "raced",
    racedMade: 0,
    racedBaseline: { provenance: "recorded" },
    racedBaselineError: null,
    racedTamper: false,
  });
  assert.ok(!/provenance/.test(r.text),
    "nothing was written on that path, so nothing is claimed");
});

test("performRestore maps the returned already-present flag to the raced outcome", () => {
  const outcome = report.performRestore({}, "/p/root", {
    restore: () => ({
      projectRoot: "/p/root",
      created: ["/p/a", "/p/a/b"],
      baseline: { provenance: "recorded" },
      baselineError: null,
      baselineNotRepairable: false,
      provenance: "recorded",
      provenanceCause: null,
      alreadyPresent: true,
    }),
  });
  assert.strictEqual(outcome.kind, "raced",
    "a returned flag must reach the same arm the throw does");
  assert.strictEqual(outcome.racedMade, 2);
  assert.strictEqual(outcome.racedProvenance, "recorded");
});

// THE FLAG PATH MUST BE THREE-VALUED, exactly as the THROW path beside it is. The
// throw path routes through `restoreNotRepairable`, which answers `null` when the
// loaded core exports no `isBaselineNotRepairable` — the core-too-old case — and the
// renderer has a disclosure arm for precisely that value. The flag path coerced with
// `Boolean(...)`, which reads `undefined` as `false`, so against such a core the
// disclosure arm was unreachable from here and the run fell through to the `--confirm`
// rebuild remedy that this arm's own text says the repair DECLINES.
test("the returned tamper flag discloses rather than answering when the core omits it", () => {
  const outcome = report.performRestore({}, "/p/root", {
    restore: () => ({
      projectRoot: "/p/root",
      created: ["/p/a"],
      baseline: null,
      baselineError: "session-control-v1: something",
      // baselineNotRepairable deliberately ABSENT - an older core returns no such key.
      provenance: "recorded",
      alreadyPresent: true,
    }),
  });
  assert.strictEqual(outcome.racedTamper, null,
    "an absent key is 'not checked', never 'checked and clean'");
});

// ...and the two decided values still travel unchanged, or the fix would have turned
// every ordinary raced run into a disclosure.
test("the returned tamper flag still carries a decided value in both directions", () => {
  const decided = (value) => report.performRestore({}, "/p/root", {
    restore: () => ({
      projectRoot: "/p/root",
      created: ["/p/a"],
      baseline: null,
      baselineError: "session-control-v1: something",
      baselineNotRepairable: value,
      provenance: "recorded",
      alreadyPresent: true,
    }),
  }).racedTamper;
  assert.strictEqual(decided(true), true);
  assert.strictEqual(decided(false), false);
});

test("performRestore leaves an ordinary restore on the restored arm", () => {
  const outcome = report.performRestore({}, "/p/root", {
    restore: () => ({
      projectRoot: "/p/root",
      created: ["/p/root"],
      baseline: { provenance: "recorded" },
      provenance: "recorded",
      alreadyPresent: false,
    }),
  });
  assert.strictEqual(outcome.kind, "restored",
    "control: the flag is what selects the raced arm, not the presence of `created`");
});

// THE REMEDY MUST SURVIVE `--confirm`. `renderRestoreVerdict` looks every refusal up
// in RESTORE_REMEDY_TABLE, but a refusal raised AFTER the user confirmed travels the
// FAILED arm, which rendered `error.message` alone. The ownership refusals are the
// case that matters: the pre-confirm ladder catches an ancestor that was already
// wrong, so the ones reaching this arm are the RACE-window ones — where the operator
// has the least context and most needs the chmod-or-move instruction.
test("a post-confirm refusal that names a known reason still carries its remedy", () => {
  const text = report.renderRestoreOutcome({
    kind: "failed",
    error: {
      message: "recorded project root is not restorable: "
        + realCore.RESTORE_ROOT_REFUSALS.UNSAFE_ANCESTOR_OWNERSHIP,
    },
  }).text;
  assert.ok(/chmod/.test(text), "the ownership remedy names the chmod");
  assert.ok(/move the project under a parent you own/.test(text),
    "and the other half of it");
});

// ...and a failure whose message names no refusal reason gets NO remedy, or the arm
// would attach a confident instruction to a cause nobody identified.
test("a post-confirm failure naming no reason is offered no remedy", () => {
  const text = report.renderRestoreOutcome({
    kind: "failed",
    error: { message: "recorded project root could not be created at /p/a: EACCES" },
  }).text;
  assert.ok(!/chmod/.test(text), "control: no remedy is invented for an unnamed cause");
  assert.ok(/Run \/zensu:doctor/.test(text), "the generic close still stands");
});

test("neither renderer writes to process.stdout", () => {
  const fs = require("node:fs");
  const src = fs.readFileSync(REPORT_PATH, "utf8");
  const body = (name) => {
    const at = src.indexOf("function " + name + "(");
    assert.ok(at >= 0, name + " is defined");
    const next = src.indexOf("\nfunction ", at + 1);
    return src.slice(at, next === -1 ? src.length : next);
  };
  for (const name of ["renderRestoreVerdict", "renderRestoreOutcome"]) {
    assert.ok(
      !body(name).includes("process.stdout.write"),
      name + " must build into `out` and return, never write a global",
    );
    assert.ok(
      /const out = \[\];/.test(body(name)) && /const w = \(/.test(body(name)),
      name + " must use the file's own out/w renderer shape",
    );
  }
});

test("the verdict factory seam is gone from the report module", () => {
  const fs = require("node:fs");
  const src = fs.readFileSync(REPORT_PATH, "utf8");
  assert.ok(
    !src.includes("deps.verdict"),
    "main() resolves core.restoreRootVerdict itself; no injectable verdict factory remains",
  );
});

test("no case in this file intercepts the stdout writer", () => {
  const fs = require("node:fs");
  const self = fs.readFileSync(__filename, "utf8");
  // ASSEMBLED, never written out: a check that greps its own file for a literal
  // matches the literal it is written with, which is how a self-referential scan
  // reports a violation that is only its own text. This repository records that
  // hazard more than once; the concatenation is what keeps the needle out of the
  // haystack.
  const needle = "process.stdout" + ".write" + " =";
  const hits = self.split("\n").filter((line) => line.includes(needle)).length;
  assert.strictEqual(hits, 0,
    "the returning renderers make a global interception unnecessary");
  // CONTROL: the needle must be able to match at all, or the assertion above is
  // satisfied by a scan that could never find anything.
  assert.ok(("a " + needle + " b").includes(needle), "control: the needle matches");
});

// --- Round 4 -------------------------------------------------------------------
// Six findings against this module, every one of them about a rule that exists once
// and is then re-spelled somewhere else in the same file.

test("the raced arm does not warn about an `existing` provenance", () => {
  // The module owns ONE predicate for "the rebuild happened and its history entry did
  // not" — `provenanceUnrecorded`, which excludes BOTH "recorded" and "existing". The
  // raced arm re-spelled it inline as `!== "recorded"` alone, so a raced run whose
  // baseline was already present warned that its own work was recorded nowhere.
  const err = new Error("already restored");
  err.code = realCore.RESTORE_ALREADY_PRESENT_CODE;
  err.created = ["/tmp/gone/a"];
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, projectRoot: "/tmp/gone", missing: ["a"] }),
    restoreWorkflowProjectRoot: () => { throw err; },
    repairWorkflowBaseline: () => ({ state: "rebuilt", provenance: "existing" }),
  }, { confirmed: true });
  assert.ok(
    !r.out.includes("its provenance entry could not"),
    "an `existing` provenance IS recorded, so the raced arm must not warn",
  );
});

test("the raced arm still warns when the provenance really is unrecorded", () => {
  const err = new Error("already restored");
  err.code = realCore.RESTORE_ALREADY_PRESENT_CODE;
  err.created = ["/tmp/gone/a"];
  const r = withCore({
    restoreRootVerdict: () => ({ ok: true, projectRoot: "/tmp/gone", missing: ["a"] }),
    restoreWorkflowProjectRoot: () => { throw err; },
    repairWorkflowBaseline: () => ({ state: "rebuilt", provenance: "unavailable" }),
  }, { confirmed: true });
  assert.match(r.out, /its provenance entry could not/,
    "control: the warning still fires for a genuinely unrecorded provenance");
});

test("the provenance rows have ONE writer", () => {
  const fs = require("node:fs");
  const src = fs.readFileSync(REPORT_PATH, "utf8");
  // Scoped to the RETURNING renderers by their `w(` spelling. The adoption renderer in
  // the same file writes the same label through `process.stdout.write` against a
  // different source, so a bare label count would grade a neighbouring feature.
  const rows = src.split("\n").filter((l) => l.includes('w("  provenance       : "')).length;
  assert.strictEqual(rows, 1,
    "the raced and restored arms hand-copied this row and had already diverged twice");
  // CONTROL: the needle matches at all, so the count above is not satisfied by a scan
  // that could never find anything.
  assert.ok(rows > 0, "control: the row spelling is findable");
});

test("no core predicate is re-spelled as a local fallback", () => {
  const fs = require("node:fs");
  const src = fs.readFileSync(REPORT_PATH, "utf8");
  // The core states the policy for an unresolvable export: WITHHOLD, never guess. Two
  // guards here answered anyway from a local copy of the rule, and one compared the raw
  // constant the core's own header forbids consumers to use.
  assert.ok(
    !src.includes("core.BASELINE_NOT_REPAIRABLE_CODE"),
    "the PREDICATE is the guard; the raw code must not be compared outside the core",
  );
  assert.ok(
    !src.includes('baseline.provenance !== "recorded"'),
    "provenanceUnrecorded is the core's rule; a local re-spelling can diverge from it",
  );
});

test("performRestore takes the recorded root as a parameter, not through the seam", () => {
  const err = new Error("already restored");
  err.code = realCore.RESTORE_ALREADY_PRESENT_CODE;
  err.created = ["/tmp/gone/a"];
  const outcome = report.performRestore({}, "/tmp/gone", {
    restore: () => { throw err; },
    repairBaseline: () => ({ state: "rebuilt", provenance: "recorded" }),
  });
  assert.strictEqual(outcome.racedProjectRoot, "/tmp/gone",
    "the root is production data, so it must not ride in the test seam");
});

test("renderRestoreVerdict returns a discriminated kind", () => {
  const refused = report.renderRestoreVerdict(
    { ok: false, reason: realCore.RESTORE_ROOT_REFUSALS.ROOT_PRESENT }, false);
  assert.strictEqual(refused.kind, "refused");
  const preview = report.renderRestoreVerdict(
    { ok: true, projectRoot: "/tmp/gone", missing: ["a"] }, false);
  assert.strictEqual(preview.kind, "report");
  const go = report.renderRestoreVerdict(
    { ok: true, projectRoot: "/tmp/gone", missing: ["a"] }, true);
  assert.strictEqual(go.kind, "proceed");
});

test("an unrecognised outcome kind is refused, never announced as a restore", () => {
  const r = report.renderRestoreOutcome({ kind: "invented-kind" });
  assert.notStrictEqual(r.code, 0, "an unrecognised kind must not exit 0");
  assert.ok(!r.text.includes("RESTORED\n"),
    "an unrecognised kind must not be announced as a successful restore");
  assert.ok(r.text.includes("invented-kind"),
    "the residual arm names the value it could not read");
});

test("a refusal reason that would close its own parenthetical is refused", () => {
  // The same bound this renderer already applies to `limit` twenty lines below, on the
  // stated ground that it is on the export surface and must not trust what it is handed.
  const r = report.renderRestoreVerdict({ ok: false, reason: "bad) Note. run something" }, false);
  assert.ok(
    !r.text.includes("bad) Note."),
    "a reason carrying `)` must not be rendered inside the headline's parenthetical",
  );
  assert.match(r.text, /NOT restorable/, "the headline still renders");
});
