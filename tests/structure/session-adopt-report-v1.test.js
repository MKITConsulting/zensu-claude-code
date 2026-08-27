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

// ── The colon-confusable guard, in BOTH directions ──────────────────────────
//
// The guard that folds a colon-LOOKING letter had no executed case in either
// direction, and the fixture set had its hole exactly where the risk was: every
// localized fixture above happens to avoid the one category the guard rejected.
//
// The negative direction is the one that matters, and writing it found a real defect.
// The rule was `\p{Lm}`, the whole Modifier_Letter category, justified in the module
// by "modifier letters do not occur in ordinary localized paths". That is false.
// U+30FC KATAKANA-HIRAGANA PROLONGED SOUND MARK is Lm and appears in a large share of
// ordinary Japanese words (データ, サーバー, コーヒー), and U+02BC MODIFIER LETTER
// APOSTROPHE is Lm and carries real orthographies (Oʻzbekiston). Both were folded into
// escape soup — precisely the degradation the wide alphabet exists to prevent, landing
// on exactly the developers whose paths are not ASCII.
//
// Measured rather than assumed: of the colon-confusable characters, only U+02D0 and
// U+02D1 are BOTH Modifier_Letter and admitted by SAFE_DISPLAY. U+FF1A, U+2236, U+A789
// and U+02F8 are not \p{L} at all, so the allowlist already excludes them and the fold
// branch already escapes every colon it emits. The guard therefore names those two
// characters instead of a category.
test('S5 a space-adjacent modifier letter is folded, whatever it is', () => {
  // DERIVED, not enumerated. A named set of colon-confusables cannot be proven
  // complete — the first attempt at this guard listed U+02D0 and U+02D1 and let the
  // whole Lisu tone-letter run U+A4F8-U+A4FD through, which a review seat caught.
  // So this case does not test a list: it walks EVERY code point that is
  // Modifier_Letter AND admitted by SAFE_DISPLAY AND not default-ignorable, and
  // requires each one to fold in all three positions a forgery can occupy.
  //
  // Those three positions are the whole threat. The report renders `label : value`
  // rows, so a forged row needs the confusable to sit BETWEEN two spaces — which,
  // for a value spliced in after `label : `, means either surrounded by spaces of
  // its own, or leading (the separator supplies the space before it), or followed
  // by a space. A trailing one has nothing after it and forges nothing.
  const SAFE = report().SAFE_DISPLAY;
  const shapes = [(c) => `/tmp/p ${c} recorded`, (c) => `${c} y`, (c) => `x ${c}`];
  let checked = 0;
  for (let cp = 0; cp <= 0x10ffff; cp += 1) {
    if (cp >= 0xd800 && cp <= 0xdfff) continue;
    const c = String.fromCodePoint(cp);
    if (!/\p{Lm}/u.test(c) || !SAFE.test(c) || /\p{Default_Ignorable_Code_Point}/u.test(c)) continue;
    checked += 1;
    for (const shape of shapes) {
      const hostile = shape(c);
      assert.notEqual(
        report().safe(hostile), hostile,
        `U+${cp.toString(16).toUpperCase()} must not be returned raw in ${JSON.stringify(hostile)}`,
      );
    }
  }
  assert.ok(checked > 300, `expected the Lm-within-SAFE_DISPLAY set to be large, walked ${checked}`);
});

test('S5 an invisible letter cannot be returned raw', () => {
  // The conjunct this pins was deletable with every other case in this file still
  // green, which is what "uncovered branch" meant here. U+3164 HANGUL FILLER is a
  // LETTER, so SAFE_DISPLAY admits it; it renders as blank, so the value LOOKS like a
  // further `label : value` row; and it introduces no space at all, so neither
  // DOUBLE_SPACE nor PAIR_SEPARATOR fires. The invisible-character guard is the only
  // thing standing between this value and a raw return — which is exactly why its
  // absence has to be observable from this file.
  const hidden = '/tmp/xㅤ:ㅤy';
  const rendered = report().safe(hidden);
  assert.notEqual(rendered, hidden, 'an invisible letter must not be returned raw');
  assert.match(rendered, /^"/, 'it must take the escaping branch');
  assert.equal(/ㅤ/.test(rendered), false, 'and the filler itself must not survive as a raw byte');
});

test('S5 an ordinary path carrying a modifier letter still prints as itself', () => {
  // Each of these is an ordinary directory name, not a threat. If this case ever goes
  // red because the guard widened back to a category, the wide-alphabet promise in the
  // module header has been broken again.
  for (const localized of [
    '/Users/tanaka/データ',
    '/Users/tanaka/サーバー',
    '/Users/anvar/Oʼzbekiston',
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

test('S5 the exported constants predict the exported function', () => {
  // The export list carried SAFE_DISPLAY, DOUBLE_SPACE and NON_ASCII while the function
  // applied three FURTHER rules that were not exported at all, so a reader of the export
  // surface — and CLAUDE.md names this file as a core-half port obligation, so that
  // reader is a porter — saw a strictly weaker fold than the one that ships. This file
  // has already paid for that exact mistake once, in the opposite direction, with
  // foldDisplayHiders.
  //
  // Derived from the FUNCTION, never from a hand-kept list: a new guard added to
  // safeDisplayValue and not exported turns this red on its own, which a literal roster
  // could not do.
  const leaf = require(path.join(LIB, 'zensu-safe-display-v1.js'));
  const source = fs.readFileSync(path.join(LIB, 'zensu-safe-display-v1.js'), 'utf8');
  // BOUND THE SLICE AT THE EXPORT BLOCK. It ran to EOF for one round, which put
  // `module.exports = { SAFE_DISPLAY, … }` inside `body` — so the reverse-direction
  // check below, `body.includes(key)` over the exported keys, was true by construction
  // and could never fail. The check written to catch foldDisplayHiders was itself the
  // vacuous pin this file keeps warning about.
  // The bound is the FUNCTION's own end, not the export block. Two bounds were tried
  // and only this one measures what the check claims. Unbounded ran to EOF, so
  // `module.exports = { … }` sat inside `body` and the reverse check below was true by
  // construction. Bounding at `module.exports` is better but still admits anything
  // DEFINED between the function and the export list: a weak rule declared there and
  // exported finds its own definition text and passes. Only the function body can
  // answer "does safeDisplayValue reference this".
  const startAt = source.indexOf('const safeDisplayValue');
  assert.ok(startAt > 0, 'safeDisplayValue is declared in the leaf module');
  const endAt = source.indexOf('\n};', startAt);
  assert.ok(endAt > startAt, 'safeDisplayValue has a terminating `};` to bound the slice at');
  const body = source.slice(startAt, endAt);
  assert.ok(
    !body.includes('module.exports'),
    'the sliced body must stop before the export list, or the reverse check below reads its own answer',
  );
  const applied = new Set(
    Array.from(body.matchAll(/\b([A-Z][A-Z0-9_]{2,})\.test\(/g), (m) => m[1]),
  );
  assert.ok(applied.size >= 5, `expected the fast path to apply several named rules, saw ${applied.size}`);
  for (const rule of applied) {
    assert.ok(
      Object.prototype.hasOwnProperty.call(leaf, rule),
      `${rule} is applied by safeDisplayValue but is not exported — the constants must describe the function`,
    );
  }

  // THE REVERSE DIRECTION, which is the one this module's history actually failed in.
  // foldDisplayHiders was an EXPORTED rule strictly weaker than the real fold, with no
  // consumer and no executed case; four review seats found it independently. The loop
  // above cannot see that shape at all — it walks what the function APPLIES, and a
  // re-added weak export applies nothing.
  //
  // Containment, never set equality: SPACE_RUN is referenced by the fold branch and
  // deliberately NOT exported, so equality would fail on a module that is correct.
  //
  // EVERY export is judged, not just the SCREAMING_CASE ones. The filter used to skip
  // anything that was not `[A-Z][A-Z0-9_]{2,}`, which skipped exactly the shape this
  // check is named for: foldDisplayHiders is camelCase, so a re-added one was
  // `continue`d past before the assertion ran. Only the entry point is exempt, because
  // it is the function the others are measured against.
  for (const key of Object.keys(leaf)) {
    if (key === 'safeDisplayValue') continue;
    assert.ok(
      body.includes(key),
      `${key} is exported but safeDisplayValue never references it — an exported rule the fold does not apply is what foldDisplayHiders was`,
    );
  }
});

test('S5 the display rule has exactly ONE owner', () => {
  // IDENTITY, not equality. The extraction's whole purpose was to leave one
  // implementation of the fold; reading the re-export can only tell you the value is
  // shaped right, not that it came from the leaf — a private copy re-introduced in
  // either consumer would satisfy every other case in this file. `===` on the regex
  // OBJECT is what a copy cannot satisfy.
  const leaf = require(path.join(LIB, 'zensu-safe-display-v1.js'));
  assert.strictEqual(report().SAFE_DISPLAY, leaf.SAFE_DISPLAY,
    'the report must re-export the leaf rule, never a private copy');
  assert.strictEqual(report().safe, leaf.safeDisplayValue,
    'safe() must BE the leaf function, not a wrapper around a second rule');

  // The doctor renderer is the other consumer, and it is not requirable here (it
  // ends in process.exit). Pin at source that it carries no second spelling of the
  // rule: no Unicode-property class and no bidi range of its own.
  const doctor = fs.readFileSync(path.join(LIB, 'zensu-doctor-report.js'), 'utf8');
  assert.equal(/\\p\{L\}/.test(doctor), false, 'the doctor must not re-author the allowlist');
  assert.equal(/\\u202a/.test(doctor), false, 'the doctor must not re-author the bidi fold');
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

test('S5 the separator is folded in the spelling the consumers actually emit', () => {
  // The rule was written against ` : ` while NEITHER consumer spells a row that way.
  // session-adopt-report-v1.js writes `"  superseded record: "` and the doctor renderer
  // emits rows like `binding: …` — a colon with NO space before it. So a value carrying
  // `: ` forged a row in the exact spelling the report emits, and the fast path returned
  // it raw because PAIR_SEPARATOR did not match. Both spellings must fold; the value is
  // attacker-influenced through project_root, and skills/doctor/SKILL.md tells the model
  // to print these rows verbatim.
  const forgery = '/home/u/superseded record: /tmp/evil';
  const rendered = report().safe(forgery);
  assert.notEqual(rendered, forgery);
  assert.ok(rendered.startsWith('"'), 'a value carrying ": " is JSON-quoted');
});

test('S5 an ordinary colon with no adjacent space still renders raw', () => {
  // The widened rule must not fold a drive letter or a bare `k:v` with no space —
  // otherwise every Windows-spelled root would degrade to the escaped rendering. This
  // is the discrimination that keeps the widening from becoming "escape every colon".
  for (const ordinary of ['C:/Users/u/repo', '/tmp/a:b', 'D:\\work\\repo']) {
    assert.equal(report().safe(ordinary), ordinary,
      `${ordinary} carries no separator-shaped colon and must render as itself`);
  }
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
