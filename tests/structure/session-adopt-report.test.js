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
    assert.equal(rendered.includes(threat), false, `raw ${escape(threat)} survived`);
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
    '/Users/müller/projekte/kunde',
    '/Users/josé/proyectos/app',
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
