'use strict';

// Unit driver for the adoption report payload.
//
// The payload used to be ~180 lines of JavaScript inside a single-quoted shell
// string in zensu-session-adopt.sh. That carrier was already shaping the code —
// every pattern had to be built with `new RegExp("...")` and no apostrophe could
// appear anywhere — and it left `safe()` with no test in either direction, for a
// function whose comment names four concrete threats it exists to close. Review of
// PR #252 recorded that as a carrier problem rather than a style one: the sibling
// recognized command already runs a real file (zensu-doctor-report.js), and the
// PreToolUse recognizer pins only the outer `bash <adopt script>` shape, so moving
// the payload out was unobstructed.
//
// Registered with the tree runner through test-versioned-plugin-upgrade.sh —
// tests/run-all.sh discovers only test-*.sh, so an undriven *.test.js never runs.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const LIB = path.join(__dirname, '..', '..', 'hooks', 'lib');
const REPORT_FILE = path.join(LIB, 'session-adopt-report-v1.js');
const ADOPT_SCRIPT = path.join(LIB, 'zensu-session-adopt.sh');

// Required per test: a top-level require of a file that does not exist yet aborts
// the whole file, so exactly one case would report and the rest would never run.
function report() {
  return require(REPORT_FILE);
}

// ── The carrier ─────────────────────────────────────────────────────────────

test('S5 the report payload is a real module, not a shell string', () => {
  assert.equal(typeof report().safe, 'function');
  const script = fs.readFileSync(ADOPT_SCRIPT, 'utf8');
  assert.equal(/^node -e '/m.test(script), false, 'the node -e payload carrier is gone');
  assert.ok(script.includes('session-adopt-report-v1.js'), 'the script runs the module instead');
});

// ── safe(), in BOTH directions ──────────────────────────────────────────────
// Finding #18: every report assertion in the suite grepped a plain-ASCII mktemp
// path, so `SAFE_DISPLAY.test(text) && !DOUBLE_SPACE.test(text)` was always true and
// the function returned `text` unchanged. Delete the condition, return text
// unconditionally, and the whole suite stayed green.

test('S5 an ordinary path is emitted verbatim', () => {
  // The positive control. Without it a safe() that escaped EVERYTHING would also
  // satisfy the negative cases below.
  const plain = '/Users/someone/projects/my-repo';
  assert.equal(report().safe(plain), plain);
  assert.equal(report().safe('/tmp/zensu-versioned-upgrade-AbC123/project'), '/tmp/zensu-versioned-upgrade-AbC123/project');
});

test('S5 every separator spelling this report emits is folded, not only the spaced one', () => {
  // The guard covered ` : ` while the report emits THREE spellings. `WARNING: `,
  // `NOTE: `, `  superseded record: ` and ` could NOT be set aside: ` all use `: `
  // with no leading space, so a project directory carrying that spelling printed
  // VERBATIM and forged a whole warning line — the lines skills/adopt-session/SKILL.md
  // tells the model to relay word for word. Measured against the shipped function:
  // seven of eight such values passed through unchanged.
  for (const forged of [
    'repo WARNING: inspect /tmp/x',
    'repo NOTE: nothing to do',
    'repo record: /tmp/elsewhere',
    'repo could NOT be set aside: /tmp/x',
    'repo provenance : recorded',
    'repo  padded',
  ]) {
    assert.notEqual(report().safe(forged), forged, `${forged} must not print verbatim`);
  }
});

test('S5 the colon confusables the allowlist admits are folded beside a space', () => {
  // MEASURED against SAFE_DISPLAY rather than assumed: of the known colon
  // confusables, exactly U+003A, U+02D0 (\p{Lm}) and U+A4FD (\p{Lo}) pass it. A guard
  // testing only U+003A left the other two able to paint a separator that reads as one.
  for (const forged of ['repo \u02d0 recorded', 'repo \ua4fd recorded', 'repo\u02d0 recorded']) {
    assert.notEqual(report().safe(forged), forged, 'a confusable colon beside a space is folded');
  }
});

test('S5 an invisible character cannot split the separator guards', () => {
  // MEASURED: nine default-ignorable code points pass the positive allowlist, and each
  // turns `repo X: recorded` back into a value that prints verbatim while still
  // reading as a label. They are letters and marks, so the class admits them; only a
  // property test catches them.
  for (const cp of ['\u034f', '\u115f', '\u1160', '\u17b4', '\u17b5', '\u180b', '\u3164', '\ufe00', '\uffa0']) {
    const forged = `repo ${cp}: recorded`;
    assert.notEqual(report().safe(forged), forged, `U+${cp.codePointAt(0).toString(16)} must not survive`);
  }
});

test('S5 a combining mark on a space is folded, one on a letter is not', () => {
  // MEASURED before it was closed: U+0301 and the spacing visargas U+0903 / U+0F7F all
  // printed VERBATIM. \p{M} is inside the allowlist and neither literal guard carries a
  // mark, so an orphan mark paints on the preceding space and splits the pair.
  for (const forged of ['repo \u0301 recorded', 'repo \u0903 recorded', 'repo \u0f7f recorded', '\u0301repo x']) {
    assert.notEqual(report().safe(forged), forged, 'an orphan mark is folded');
  }
  // The rule is the mark's BASE. A decomposed accent on a letter is an ordinary path
  // and must still print as itself — folding those would degrade the one line this
  // allowlist was widened to keep legible.
  for (const ordinary of ['/Users/jose\u0301/repo', '/srv/cafe\u0301/data', '/home/u\u0308ber/x']) {
    assert.equal(report().safe(ordinary), ordinary, `${JSON.stringify(ordinary)} still prints verbatim`);
  }
});

test('S5 the fallback branch folds the separator too, not only the fast path', () => {
  // The file's own comment states the invariant must hold on BOTH branches. A value
  // that reaches the escape branch for an unrelated reason must not keep a usable
  // `: ` intact.
  const rendered = report().safe('/tmp/a"b project: x');
  assert.ok(rendered.startsWith('"'), 'the escape branch was taken');
  assert.equal(/[^\\]: /.test(rendered), false, 'no usable colon-space survives the fold');
});

test('S5 a character outside the class is quoted and folded to ASCII', () => {
  const hostile = '/tmp/a%b';
  const rendered = report().safe(hostile);
  assert.notEqual(rendered, hostile, 'the escape branch must actually be taken');
  assert.ok(rendered.startsWith('"') && rendered.endsWith('"'), 'the fallback is JSON-quoted');
});

test('S5 a bidi override never survives as a raw byte', () => {
  // The named threat: U+202E can hide or reverse the one line that says which
  // project is being taken over.
  const rendered = report().safe('/tmp/pro‮jeb');
  assert.equal(rendered.includes('‮'), false, 'no raw bidi byte survives');
  assert.ok(rendered.includes('\\u202e'), 'it is folded to an ASCII escape');
  // Every code point in the output is ASCII.
  for (const ch of rendered) assert.ok(ch.charCodeAt(0) < 0x80, `non-ASCII survived: ${ch}`);
});

test('S5 U+2028, U+2029 and U+007F are folded too', () => {
  for (const threat of [' ', ' ', '']) {
    const rendered = report().safe(`/tmp/a${threat}b`);
    assert.equal(rendered.includes(threat), false, `raw ${JSON.stringify(threat)} survived`);
    for (const ch of rendered) assert.ok(ch.charCodeAt(0) < 0x80);
  }
});

// ── Finding #19: a localized path is not a threat ───────────────────────────

test('S5 a localized path prints as itself', () => {
  // SAFE_DISPLAY admitted no letter outside ASCII, so any project path with an
  // umlaut, an accent or CJK took the fold — the degraded rendering of the single
  // line the change exists to add, landing on exactly the developers whose home
  // directory is not pure ASCII.
  for (const localized of [
    '/Users/müller/projects/customer',
    '/Users/josé/projects/app',
    '/Users/田中/プロジェクト',
  ]) {
    assert.equal(report().safe(localized), localized, `${localized} must print as itself`);
  }
});

test('S5 the safe class is expressed by Unicode property, not an ASCII range', () => {
  const source = fs.readFileSync(REPORT_FILE, 'utf8');
  assert.ok(/\\p\{L\}/.test(source), 'letters come from the Unicode property');
  assert.ok(/\\p\{N\}/.test(source), 'numbers come from the Unicode property');
  assert.ok(/\\p\{M\}/.test(source), 'combining marks are admitted, or accented forms break');
});

// ── Finding #17: the same-line label forgery ────────────────────────────────

test('S5 a " : " separator inside a value forces the quoted rendering', () => {
  // SAFE_DISPLAY admits both a space and a colon, and DOUBLE_SPACE rejects only two
  // ADJACENT spaces — so a directory literally named `repo provenance : recorded`
  // passed through raw and forged a further label/value pair after the project line.
  // The attacker model needs no local privilege: project_root is minted from the
  // SessionStart cwd, and validateContext rejects only NUL, CR and LF in it.
  const forgery = '/home/u/repo provenance : recorded';
  const rendered = report().safe(forgery);
  assert.notEqual(rendered, forgery);
  assert.ok(rendered.startsWith('"'), 'a value carrying " : " is JSON-quoted');
});

test('S5 the double-space invariant holds on the fallback branch too', () => {
  // Finding #18's third defect: the fallback applied JSON.stringify plus the
  // non-ASCII fold but NEVER the double-space check, so `/tmp/a"b  project : x` was
  // rendered with the two-space run and the colon intact.
  const rendered = report().safe('/tmp/a"b  project : x');
  assert.equal(/ {2}/.test(rendered), false,
    'no run of two spaces may survive on either branch');
});

// ── Finding #14 tail: the coercion must fail toward reporting ───────────────

test('S5 an unexpected leases.unsafe shape reports rather than reading clean', () => {
  // `typeof leases.unsafe === "string" ? leases.unsafe : ""` mapped every unexpected
  // shape to the CLEAN verdict, so the entire WARNING branch never printed. Failing
  // toward reporting costs the same line.
  const { leasesScope } = report();
  assert.equal(leasesScope({ unsafe: '' }), '');
  assert.equal(leasesScope({ unsafe: 'source' }), 'source');
  assert.equal(leasesScope({ unsafe: 'destination' }), 'destination');
  assert.equal(leasesScope({ unsafe: true }), 'source', 'a truthy non-string still reports');
  assert.equal(leasesScope({ unsafe: 1 }), 'source');
  assert.equal(leasesScope({}), '');
  assert.equal(leasesScope({ unsafe: null }), '');
  assert.equal(leasesScope(null), '');
});

// ── S3 / finding #14: the sweep is ordered behind a one-way door ─────────────
// adoptContext performs four durable steps and only the first two are transactional
// together. A process death between the record swap and the sweep leaves a committed
// adoption with an unswept lease store — and repeating the command does NOT help,
// because the next adoptableRecord now refuses as already-served. The user is left
// holding exactly the lease wedge the sweep exists to clear, with the documented
// remedy no longer applicable.
//
// The sweep cannot move BEFORE the record swap: it lives in its own module now and
// the entry point calls it, which is what the require cycle forced. So the other
// named option is taken — --confirm on an already-served record re-runs the sweep as
// an idempotent repair.

test('S3 an already-served record is repairable in place, but only with --confirm', () => {
  const { shouldRepairInPlace, REMEDY } = report();
  const core = require(path.join(LIB, 'session-control-core-v1.js'));
  const served = { ok: false, reason: core.ADOPTION_REFUSALS.ALREADY_SERVED };

  assert.equal(shouldRepairInPlace(served, true), true);
  // A report-only run must stay strictly read-only. That property is what the
  // recognizer's own justification rests on.
  assert.equal(shouldRepairInPlace(served, false), false);
});

test('S3 no other refusal is repairable, and a clean verdict is not a repair', () => {
  const { shouldRepairInPlace } = report();
  const core = require(path.join(LIB, 'session-control-core-v1.js'));
  for (const reason of Object.values(core.ADOPTION_REFUSALS)) {
    if (reason === core.ADOPTION_REFUSALS.ALREADY_SERVED) continue;
    assert.equal(shouldRepairInPlace({ ok: false, reason }, true), false,
      `${reason} must not be treated as an in-place repair`);
  }
  // Cardinality, so an emptied constant cannot make the loop vacuous, and every
  // refusal has a remedy — the map falls back to a generic sentence for any eighth.
  assert.equal(Object.values(core.ADOPTION_REFUSALS).length, 7);
  for (const reason of Object.values(core.ADOPTION_REFUSALS)) {
    assert.ok(report().REMEDY[reason], reason + ' has no remedy');
  }
  // ok:true is the ordinary adoption path, not the repair path.
  assert.equal(shouldRepairInPlace({ ok: true }, true), false);
  assert.equal(shouldRepairInPlace(null, true), false);
});

test('S3 the already-served remedy no longer claims there is nothing to do', () => {
  // The old text said "Nothing to adopt". With the in-place repair that is only half
  // true: the record needs nothing, the lease store may still be wedged.
  const { REMEDY } = report();
  const core = require(path.join(LIB, 'session-control-core-v1.js'));
  const text = REMEDY[core.ADOPTION_REFUSALS.ALREADY_SERVED];
  assert.ok(text.includes('--confirm'), 'the remedy names the repair that is available');
});

// ── F1 / CRITICAL: the repair swept against the wrong root ──────────────────
// `already-served` does NOT mean the record names the executing installation.
// servesRecordedRuntime is true on the equality fast path AND on the
// lineage-relaxed sibling arm, so under a compatible upgrade the recorded root
// (0.18.1) and the executing root (0.18.2) differ. Leases carry the EXECUTING
// root, so sweeping against the recorded one inverts the selector: the stale
// entries that wedge listRecords are kept and the live ones are moved aside.
// Four reviewers found this independently.

test('F1 the repair sweeps against the EXECUTING root, never the recorded one', () => {
  const { repairSweepRoot } = report();
  const request = {
    executingPluginRoot: '/cache/zensu/zensu/0.18.2',
    pluginData: '/data',
    sessionId: 'sid',
    recordsDir: '/data/session-control/v1/records',
  };
  assert.equal(repairSweepRoot(request), '/cache/zensu/zensu/0.18.2');
  // The discrimination: a recorded root that differs must NOT be what comes back.
  assert.notEqual(repairSweepRoot(request), '/cache/zensu/zensu/0.18.1');
});

test('F1b the repair root is canonicalized to the spelling leases are minted with', (t) => {
  // zensu-session-adopt.sh hands this value over as zensu-host-path.sh rendered it.
  // Leases carry `binding.pluginRoot`, which reached the store through the core's
  // canonicalDirectory — fs.realpathSync.native — and the sweep compares the two as
  // STRINGS. On win32 the renderer's drive-qualified forward-slash spelling and the
  // native one differ, and windows-shard-2 set aside the live lease because of it.
  //
  // Driven here through a symlinked parent, which is a non-canonical spelling every
  // host can produce, so the property has an executed case off Windows too.
  const os = require('node:os');
  const base = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zadopt-root-')));
  const real = path.join(base, 'installed', '0.18.2');
  fs.mkdirSync(real, { recursive: true });
  const link = path.join(base, 'via-link');
  try {
    fs.symlinkSync(path.join(base, 'installed'), link, 'dir');
  } catch {
    return t.skip('this host refused an unprivileged symbolic link');
  }
  const spelled = path.join(link, '0.18.2');
  assert.notEqual(spelled, real, 'the fixture must actually offer two spellings');

  const { repairSweepRoot } = report();
  assert.equal(repairSweepRoot({ executingPluginRoot: spelled }), real);
});

test('F1c an unresolvable repair root falls back instead of throwing', () => {
  // The branch owes the caller a verdict. zensu-session-adopt.sh already proved the
  // root readable, so a failure here means it vanished mid-run — reporting the
  // rendered value is wrong-but-visible; a throw would crash the command after the
  // user asked for a repair.
  const { repairSweepRoot } = report();
  const absent = path.join('/', 'zensu-absent-' + process.pid, '0.18.2');
  assert.equal(repairSweepRoot({ executingPluginRoot: absent }), absent);
});

test('F1 the repair headline is chosen from the verdict, not printed unconditionally', () => {
  const { repairHeadline } = report();
  assert.match(repairHeadline({ discarded: 2, failed: [], unsafe: '' }), /repaired/);
  assert.match(repairHeadline({ discarded: 0, failed: [], unsafe: '' }), /nothing to repair/i);
  // A refused sweep and a stuck lease are NOT repairs.
  assert.match(repairHeadline({ discarded: 0, failed: [], unsafe: 'source' }), /NOT repaired/);
  assert.match(repairHeadline({ discarded: 1, failed: ['a.json'], unsafe: '' }), /NOT repaired/);
});

test('F1 a refused or partial repair exits non-zero', () => {
  const { repairExitCode } = report();
  assert.equal(repairExitCode({ discarded: 2, failed: [], unsafe: '' }), 0);
  assert.equal(repairExitCode({ discarded: 0, failed: [], unsafe: '' }), 0);
  assert.equal(repairExitCode({ discarded: 0, failed: [], unsafe: 'source' }), 1);
  assert.equal(repairExitCode({ discarded: 0, failed: [], unsafe: 'destination' }), 1);
  assert.equal(repairExitCode({ discarded: 1, failed: ['a.json'], unsafe: '' }), 1);
});

test('F1 the refused component is rendered for a source refusal too', () => {
  // The four source returns collect unsafeAt and the report threw it away,
  // rendering it only in the destination arm.
  const { renderLeaseWarnings } = report();
  const source = renderLeaseWarnings({ discarded: 0, failed: [], unsafe: 'source', unsafeAt: '/data/review-evidence/v1/records/scv1_x' });
  assert.ok(source.includes('/data/review-evidence/v1/records/scv1_x'),
    'a source refusal names the component it refused');
  const destination = renderLeaseWarnings({ discarded: 0, failed: [], unsafe: 'destination', unsafeAt: '/data/review-evidence/v1/superseded' });
  assert.ok(destination.includes('/data/review-evidence/v1/superseded'));
});

test('F1 a busy lock is not reported as an unsafe records directory', () => {
  const { renderLeaseWarnings } = report();
  const locked = renderLeaseWarnings({ discarded: 0, failed: [], unsafe: 'locked', unsafeAt: '' });
  assert.match(locked, /lock/i, 'the lock case says so');
  assert.equal(/not a plain directory you own/.test(locked), false,
    'it must not claim the two store-shape causes');
});

// The COMBINED state — recorded project root gone AND minting installation
// pruned — still lands on record-unreadable: readPrunedPluginRootContext pins
// allowMissingProjectRoot off, so validateContext throws on the vanished root
// and the outer catch answers RECORD_UNREADABLE. The remedy has to name that
// conjunction. Excluding pruning with a bare adverb sent exactly those users
// looking for a disagreement that is not there, while pruning was half the cause.
test('F2 the record-unreadable remedy names the pruned-AND-orphaned conjunction rather than excluding pruning outright', () => {
  const core = require(path.join(LIB, 'session-control-core-v1.js'));
  const { REMEDY } = report();
  const text = REMEDY[core.ADOPTION_REFUSALS.RECORD_UNREADABLE];
  assert.match(text, /pruned/i, 'the remedy still speaks to a pruned installation');
  assert.match(text, /project root is (also|ALSO) gone/,
    'it names the conjunction that still lands here');
  assert.equal(/no longer one of these/.test(text), false,
    'the bare exclusion is what made the remedy false in the combined state');
});

// ── WB / the workflow-baseline half of an already-served run ────────────────
// The record needs nothing and the workflow document it ANCHORS can still be
// gone; while it is, the capability gate denies every tool in the session. This
// is the second thing --confirm repairs. See §"Workflow-Baseline Repair" in
// CLAUDE.md.

const CORE = () => require(path.join(LIB, 'session-control-core-v1.js'));

test('WB the fault predicate calls tamper a fault and a healthy document not one', () => {
  const { baselineFault } = report();
  const core = CORE();
  assert.equal(baselineFault(undefined), '', 'no baseline half is not a fault');
  assert.equal(baselineFault({ state: core.BASELINE_STATES.PRESENT }), '',
    'a healthy document is the ordinary state of a lease-only repair run');
  assert.equal(baselineFault({ state: core.BASELINE_STATES.MISSING }), '',
    'missing is what --confirm acts on, not a fault in itself');
  assert.equal(baselineFault({ state: core.BASELINE_STATES.UNSAFE }),
    core.BASELINE_STATES.UNSAFE);
  assert.equal(baselineFault({ state: core.BASELINE_STATES.UNREADABLE }),
    core.BASELINE_STATES.UNREADABLE);
  assert.equal(baselineFault({ refusal: core.BASELINE_REFUSALS.NOT_SERVED }),
    core.BASELINE_REFUSALS.NOT_SERVED, 'a bind refusal is a fault of this half');
  assert.equal(baselineFault({ fault: 'rebuild-failed' }), 'rebuild-failed');
});

test('WB the headline and exit code compose BOTH halves, and either failing is enough', () => {
  const { repairHeadline, repairExitCode } = report();
  const core = CORE();
  const cleanSweep = { discarded: 0, failed: [], unsafe: '' };
  const stuckSweep = { discarded: 1, failed: ['a.json'], unsafe: '' };
  const rebuilt = { state: core.BASELINE_STATES.MISSING, rebuilt: true, provenance: 'recorded' };
  const tampered = { state: core.BASELINE_STATES.UNSAFE };

  assert.match(repairHeadline(cleanSweep, rebuilt), /workflow baseline rebuilt/);
  assert.match(repairHeadline(cleanSweep, tampered), /workflow baseline NOT repaired/);
  assert.match(repairHeadline(cleanSweep, { state: core.BASELINE_STATES.PRESENT }),
    /nothing to repair/i, 'a healthy document plus a clean sweep is still nothing to repair');
  // Both halves reported, never one standing in for the other.
  const both = repairHeadline(stuckSweep, rebuilt);
  assert.match(both, /workflow baseline rebuilt/);
  assert.match(both, /lease store NOT repaired/);

  assert.equal(repairExitCode(cleanSweep, rebuilt), 0);
  assert.equal(repairExitCode(cleanSweep, tampered), 1, 'a refused baseline half exits non-zero');
  assert.equal(repairExitCode(stuckSweep, rebuilt), 1,
    'a rebuilt baseline does not launder a stuck lease');
});

test('WB the report-only diagnosis names the document and the command that repairs it', () => {
  const { renderBaselineDiagnosis } = report();
  const core = CORE();
  const text = renderBaselineDiagnosis({
    state: core.BASELINE_STATES.MISSING,
    path: '/p/.zensu/state/tdd-phase-scv1_' + 'a'.repeat(64) + '.json',
    projectRoot: '/p',
  }, 'sid');
  assert.match(text, /MISSING/);
  assert.ok(text.includes('/p/.zensu/state/tdd-phase-scv1_' + 'a'.repeat(64) + '.json'),
    'the path is named, because the reader is being sent to repair that file');
  assert.match(text, /--confirm/, 'the remedy that exists is named');
  // The cost has to travel with the offer. A user who reads "rebuild" as "restore"
  // will not go looking for the chain that is gone.
  assert.match(text, /loss, not a restore/);
});

test('WB a tamper shape is diagnosed WITHOUT offering the rebuild', () => {
  const { renderBaselineDiagnosis } = report();
  const core = CORE();
  for (const state of [core.BASELINE_STATES.UNSAFE, core.BASELINE_STATES.UNREADABLE]) {
    const text = renderBaselineDiagnosis({ state, path: '/p/x.json', projectRoot: '/p' }, 'sid');
    assert.match(text, /will NOT rebuild it/,
      state + ' says plainly that it is not repaired');
    assert.equal(/--confirm/.test(text), false,
      'offering --confirm here would tell the user to build over the evidence');
  }
});

test('WB a healthy document says nothing, and an unjudgeable one is a missing check', () => {
  const { renderBaselineDiagnosis } = report();
  const core = CORE();
  assert.equal(
    renderBaselineDiagnosis({ state: core.BASELINE_STATES.PRESENT, path: '/p/x.json' }, 'sid'),
    '',
    'the ordinary case adds no noise to an already-served report',
  );
  const unjudged = renderBaselineDiagnosis({ refusal: core.BASELINE_REFUSALS.NOT_SERVED }, 'sid');
  assert.match(unjudged, /could NOT be judged/);
  assert.match(unjudged, /missing check rather than an all-clear/,
    'silence is the one verdict a diagnostic may not give');
});

test('WB the confirm notes report an unrecorded provenance rather than absorbing it', () => {
  const { renderBaselineNotes } = report();
  const core = CORE();
  const clean = renderBaselineNotes({
    state: core.BASELINE_STATES.MISSING, rebuilt: true, provenance: 'recorded', path: '/p/x.json',
  });
  assert.match(clean, /rebuilt at/);
  assert.equal(/WARNING/.test(clean), false, 'a clean rebuild is not a warning');

  const unrecorded = renderBaselineNotes({
    state: core.BASELINE_STATES.MISSING,
    rebuilt: true,
    provenance: 'unavailable: lock busy',
    path: '/p/x.json',
  });
  assert.match(unrecorded, /WARNING/);
  assert.match(unrecorded, /unrecorded in the workflow history/,
    'a real repair with an unwritten provenance is reported, never folded into the success line');

  assert.equal(renderBaselineNotes({ state: core.BASELINE_STATES.PRESENT }), '');
});

test('WB the repair acts on a missing document only, and never reaches the core otherwise', () => {
  const { repairBaseline } = report();
  const core = CORE();
  // A request that would throw if it were ever used. Every non-missing state must
  // return before the core is called, so this stands in for "the core was not
  // reached" without needing a synthetic install.
  const poisoned = null;
  for (const state of [
    core.BASELINE_STATES.PRESENT,
    core.BASELINE_STATES.UNSAFE,
    core.BASELINE_STATES.UNREADABLE,
  ]) {
    const input = { state, path: '/p/x.json' };
    assert.deepEqual(repairBaseline(poisoned, input), input,
      state + ' is returned unchanged, with no write attempted');
  }
  assert.equal(repairBaseline(poisoned, undefined), undefined);
});

test('WB surviving evidence is a closed set, never a listing of the state directory', () => {
  const { survivingEvidence } = report();
  const os = require('node:os');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-evidence-'));
  const stateDir = path.join(root, '.zensu', 'state');
  fs.mkdirSync(stateDir, { recursive: true });
  const core = CORE();
  const key = core.sessionKey('sid');
  for (const name of [
    'pending-review.json',
    'pending-review.json.claim',
    'reviewer-spawn-denied-' + key + '.json',
    'autopilot-active-' + 'b'.repeat(64) + '.json',
    'tdd-phase-' + key + '.json',
    'unrelated-note.json',
    'secrets.env',
  ]) {
    fs.writeFileSync(path.join(stateDir, name), '{}');
  }
  const listed = survivingEvidence(root, 'sid');
  assert.deepEqual(listed, [
    'autopilot-active-' + 'b'.repeat(64) + '.json',
    'pending-review.json',
    'pending-review.json.claim',
    'reviewer-spawn-denied-' + key + '.json',
  ], 'only the closed candidate set is named, sorted');
  // The output is read back by a model, and the directory is session-writable, so
  // an arbitrary filename must never reach it.
  assert.equal(listed.includes('secrets.env'), false);
  assert.equal(listed.includes('unrelated-note.json'), false);
  assert.deepEqual(survivingEvidence(path.join(root, 'absent'), 'sid'), [],
    'an unreadable state directory is an empty list, never a throw');
  assert.deepEqual(survivingEvidence('', 'sid'), []);
  fs.rmSync(root, { recursive: true, force: true });
});

test('WB the two local fail-safes are reached from their PRODUCERS, not only asserted on hand-built objects', () => {
  const { baselineVerdict, repairBaseline, baselineFault } = report();
  const core = CORE();
  // Both catches are exported and documented as this command's fail-safes, and
  // neither was executed: the loop below used to pass a poisoned request only with
  // states that return BEFORE the try, and the fault assertions fed hand-built
  // objects to the predicate rather than to the producer. Removing either
  // try/catch left the suite green while a crashed core threw out of main().
  // KNOWN BOUND, stated rather than faked: `verdict-unavailable` is NOT reachable
  // from here. core.workflowBaselineVerdict wraps its own bind derivation in a
  // try that returns a REFUSAL, so a caller-supplied fault lands as
  // `record-unreadable` and the catch in baselineVerdict only fires for a throw
  // AFTER a successful bind — which needs a real bound record this unit layer
  // does not build. What is asserted here is the reachable half plus the shape
  // the renderer keys on.
  const verdictRefusal = baselineVerdict(null);
  assert.equal(verdictRefusal.refusal, core.BASELINE_REFUSALS.RECORD_UNREADABLE);
  assert.equal(baselineFault(verdictRefusal), core.BASELINE_REFUSALS.RECORD_UNREADABLE);
  assert.equal(baselineFault({ fault: 'verdict-unavailable' }), 'verdict-unavailable');

  const rebuildFault = repairBaseline(null, { state: core.BASELINE_STATES.MISSING, path: '/p/x.json' });
  assert.equal(rebuildFault.fault, 'rebuild-failed');
  assert.ok(rebuildFault.detail && rebuildFault.detail.length > 0);
  assert.equal(baselineFault(rebuildFault), 'rebuild-failed');
});

test('WB a failed rebuild never re-offers the repair that just refused', () => {
  const { repairBaseline, renderBaselineNotes, renderBaselineDiagnosis } = report();
  const core = CORE();
  const failed = repairBaseline(null, { state: core.BASELINE_STATES.MISSING, path: '/p/x.json' });
  // repairBaseline spreads the verdict, so `state` survives as MISSING. With the
  // state branches ahead of the fault branch this rendered "Re-run this command
  // with --confirm to rebuild it" underneath the line saying the rebuild had just
  // been refused — a remedy that is the operation that already failed.
  const diagnosis = renderBaselineDiagnosis(failed, 'sid');
  assert.equal(diagnosis.includes('Re-run this'), false, 'no retry advice after a refused rebuild');
  assert.ok(diagnosis.includes('rebuild-failed'));
  assert.ok(diagnosis.includes('will fail the same way'));
  const notes = renderBaselineNotes(failed, 'sid');
  assert.ok(notes.includes('was NOT repaired'));
  // And the cause plus its detail are stated ONCE, not twice.
  assert.equal(notes.split('rebuild-failed').length - 1, 1, 'the fault token is not printed twice');
});

test('WB the surviving-evidence cap bounds a session-writable directory', () => {
  const { survivingEvidence } = report();
  const os = require('node:os');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-evidence-cap-'));
  const stateDir = path.join(root, '.zensu', 'state');
  fs.mkdirSync(stateDir, { recursive: true });
  // The autopilot pointer is matched by SHAPE, so an unbounded number of entries
  // can match and the cap is the only thing standing between that directory and
  // the model-read report. The previous fixture planted four matching names, so
  // the slice never truncated and the bound was unverified.
  for (let i = 0; i < 15; i += 1) {
    const hex = i.toString(16).padStart(2, '0').repeat(32).slice(0, 64);
    fs.writeFileSync(path.join(stateDir, 'autopilot-active-' + hex + '.json'), '{}');
  }
  const listed = survivingEvidence(root, 'sid');
  assert.equal(listed.length, 12, 'the listing is capped at EVIDENCE_MAX');
  // An unusable session id is an empty list, never a throw and never a partial
  // listing that looks like a finding.
  assert.deepEqual(survivingEvidence(root, ''), []);
  fs.rmSync(root, { recursive: true, force: true });
});
