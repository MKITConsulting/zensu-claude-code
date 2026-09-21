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
  assert.ok(!/the history entry recording it could not\nbe written/.test(r.out),
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
  assert.match(r.out, /the history entry recording it could not/,
    "a genuine history-write failure must still warn");
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
    const r = (() => {
      const chunks = [];
      const write = process.stdout.write.bind(process.stdout);
      process.stdout.write = (c) => { chunks.push(String(c)); return true; };
      let code;
      try {
        code = skewed.renderRestoreRoot({}, false, {
          verdict: () => ({ ok: false, reason: "record-unreadable" }),
        });
      } finally { process.stdout.write = write; }
      return { code, out: chunks.join("") };
    })();
    assert.strictEqual(r.code, 1);
    assert.match(r.out, /NOT restorable \(/);
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
    const chunks = [];
    const write = process.stdout.write.bind(process.stdout);
    process.stdout.write = (c) => { chunks.push(String(c)); return true; };
    let code;
    try {
      code = skewed.renderRestoreRoot({}, false, {
        verdict: () => ({ ok: false }),
      });
    } finally { process.stdout.write = write; }
    const out = chunks.join("");
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
// The seam is the same shape renderRestoreRoot already takes, so the arm is
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

// The case above cannot FAIL: the guarded fallback beside the shared predicate applies
// a rule that agrees with it on every input the case supplies, so deleting the export
// from the core leaves it green. What is worth holding is the EQUIVALENCE itself — the
// core's own comment records that these three spellings had already diverged once on
// which provenance values count — so drive the same inputs through a core WITHOUT the
// export and require the two verdicts to agree. They did not: the core refuses a
// non-object baseline outright while the fallback read `undefined.provenance` as "not
// recorded and not existing" and warned about a rebuild that never happened.
test("the guarded fallback agrees with the shared predicate on every input", () => {
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
      "control: the clone really lacks it, so `skewed` takes the fallback");
    const sid = "scv1_" + "a".repeat(64);
    const warns = (mod, baseline) =>
      /WARNING: the rebuild succeeded but its provenance entry/
        .test(mod.renderBaselineNotes(baseline, sid));
    const inputs = [
      { rebuilt: true, provenance: "recorded" },
      { rebuilt: true, provenance: "existing" },
      { rebuilt: true, provenance: "unavailable" },
      { rebuilt: true },
      "not-an-object",
      42,
    ];
    for (const baseline of inputs) {
      assert.strictEqual(warns(skewed, baseline), warns(report, baseline),
        "fallback and shared predicate disagree on " + JSON.stringify(baseline));
    }
    // MEASURED, and it contradicted the hypothesis this case was written for: the two
    // were expected to diverge on a truthy NON-OBJECT baseline, because the core
    // refuses one outright while the fallback is a bare pair of inequalities. They do
    // not, and the reason is placement rather than agreement — the fallback sits
    // inside `if (baseline.rebuilt)`, which a non-object never enters. Recorded here
    // rather than dropped: the equivalence holds for a reason the fallback's own text
    // does not state, so a later edit that hoists the check out of that branch
    // reintroduces the divergence with this case still green.
    //
    // The bite is therefore a THIRD clone whose fallback really is the plausible wrong
    // rule — a bare `!== "recorded"`, the spelling the core's comment says these three
    // carriers had already drifted to. Without it the loop above would report agreement
    // between two identical implementations and nothing else.
    const bad = fs.mkdtempSync(path.join(os.tmpdir(), "zensu-provenance-drift-"));
    try {
      for (const name of fs.readdirSync(lib)) {
        const from = path.join(lib, name);
        if (fs.statSync(from).isFile()) fs.copyFileSync(from, path.join(bad, name));
      }
      fs.writeFileSync(path.join(bad, "session-control-core-v1.js"),
        'const real = require(' + JSON.stringify(CORE_PATH) + ');\n'
        + 'const clone = Object.assign({}, real);\n'
        + 'delete clone.baselineProvenanceUnrecorded;\n'
        + 'module.exports = clone;\n');
      const reportPath = path.join(bad, "session-adopt-report-v1.js");
      const src = fs.readFileSync(reportPath, "utf8");
      const intact = ': (baseline.provenance !== "recorded" && baseline.provenance !== "existing");';
      assert.ok(src.includes(intact),
        "control: the fallback this mutation rewrites is still spelled as expected");
      fs.writeFileSync(reportPath,
        src.replace(intact, ': (baseline.provenance !== "recorded");'));
      const drifted = require(reportPath);
      assert.strictEqual(
        warns(drifted, { rebuilt: true, provenance: "existing" }), true,
        "control: the drifted fallback really does warn on `existing`");
      assert.notStrictEqual(
        warns(drifted, { rebuilt: true, provenance: "existing" }),
        warns(report, { rebuilt: true, provenance: "existing" }),
        "the comparison above must be able to see a divergent fallback");
    } finally {
      fs.rmSync(bad, { recursive: true, force: true });
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
