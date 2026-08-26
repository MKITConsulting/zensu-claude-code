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
  // Read off the EXPORTED regex rather than the file's text. The rule moved into
  // hooks/lib/zensu-safe-display-v1.js — a dependency-free leaf both report
  // renderers require — and a source grep of this file went red for a rule that had
  // not changed at all. The pattern text is what the assertion was ever about, and
  // RegExp#source carries it wherever the constant lives, so this pins the same
  // three properties without pinning the address.
  const pattern = report().SAFE_DISPLAY.source;
  assert.ok(/\\p\{L\}/.test(pattern), 'letters come from the Unicode property');
  assert.ok(/\\p\{N\}/.test(pattern), 'numbers come from the Unicode property');
  assert.ok(/\\p\{M\}/.test(pattern), 'combining marks are admitted, or accented forms break');
  assert.ok(report().SAFE_DISPLAY.unicode, 'the u flag is what makes those properties mean anything');
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
