'use strict';
// Unit pins for hooks/lib/zen-anchor-v1.js — the owner of the zen-mode
// chain-progress anchor's step vocabulary and of the shape -> line mapping.
//
// Driven from tests/structure/test-zen-mode.sh (tests/run-all.sh discovers only
// test-*.sh), which also asserts a case-count floor: `node --test` exits 0 for a
// file registering zero cases, so a floor is what keeps a silently emptied file
// from reading as agreement.
//
// The set check below drives `chainShape` rather than reading a table. A
// membership test against `NEXT_COMMAND` alone would reproduce the blindness
// CLAUDE.md records for `INERT_SHAPES`: renaming the literal a classifier
// RETURNS while leaving a table key in place kept the copy agreeing while a real
// chain rendered as something else. Both directions are pinned here — the matrix
// proves what the classifier produces, the key parity proves nothing was added
// to the classifier without reaching this module.

const test = require('node:test');
const assert = require('node:assert');
const path = require('node:path');
const fs = require('node:fs');

const LIB = path.join(__dirname, '..', '..', 'hooks', 'lib');
const anchor = require(path.join(LIB, 'zen-anchor-v1.js'));
const chain = require(path.join(LIB, 'chain-recovery-v1.js'));

// One state per shape `chainShape` can return. Fields are the normalized shape
// `normalizeChainState` produces; `chainShape` reads them directly, so a plain
// object is the honest driver here.
function state(over) {
  return Object.assign({
    active: true,
    implComplete: true,
    chainDone: false,
    codeReviewDone: false,
    selfReviewFixed: false,
    reviewTicket: '',
    reviewTicketConsumed: true,
    reviewRound: 0,
  }, over);
}

const MATRIX = [
  ['no-session', state({ active: false }), 'fresh'],
  ['implementing', state({ implComplete: false }), 'fresh'],
  ['chain-closed', state({ chainDone: true }), 'fresh'],
  ['awaiting-self-review', state({
    codeReviewDone: true, reviewTicket: 't1', reviewTicketConsumed: true, reviewRound: 1,
  }), 'fresh'],
  ['self-review-unbindable', state({
    codeReviewDone: true, reviewTicket: 't1', reviewTicketConsumed: false, reviewRound: 1,
  }), 'fresh'],
  ['review-in-flight', state({
    reviewTicket: 't1', reviewTicketConsumed: true, reviewRound: 1,
  }), 'fresh'],
  ['ticket-unclaimed', state({ reviewTicket: 't1', reviewTicketConsumed: false }), 'fresh'],
  ['ticket-spent', state({ reviewTicket: 't1', reviewTicketConsumed: true }), 'fresh'],
  ['wedged-stale-rearm', state({ reviewTicket: 't1' }), 'stale'],
  ['ticket-lost', state({ reviewRound: 2 }), 'fresh'],
  ['ready-for-review', state({}), 'fresh'],
];

test('the matrix really produces the shape it claims', () => {
  for (const [expected, s, receipt] of MATRIX) {
    assert.strictEqual(chain.chainShape(s, receipt), expected);
  }
});

test('every shape the classifier produces is mapped by this module', () => {
  const produced = new Set(MATRIX.map(([, s, r]) => chain.chainShape(s, r)));
  const mapped = new Set(Object.keys(anchor.SHAPE_POSITION));
  assert.deepStrictEqual([...produced].sort(), [...mapped].sort());
});

test('no shape reached the classifier without reaching this module', () => {
  // Against the owner's own TOTAL set, not against `NEXT_COMMAND`'s keys. The
  // key set was a PROXY: the invariant "chainShape cannot return a shape
  // NEXT_COMMAND does not answer for" is enforced nowhere in that module, so a
  // twelfth literal added to `chainShape` alone passed this check, the MATRIX
  // check (hand-written) and the mapping check together — the exact drift this
  // file's header claims to pin.
  assert.ok(Array.isArray(chain.ALL_SHAPES) && chain.ALL_SHAPES.length > 0);
  assert.deepStrictEqual(
    [...chain.ALL_SHAPES].sort(),
    Object.keys(anchor.SHAPE_POSITION).sort()
  );
});

test('the owner\'s total set really is what its classifier returns', () => {
  // The literals are read out of `chainShape`'s own SOURCE, so `ALL_SHAPES` is
  // pinned to the function rather than to another hand-written list. Scoped to
  // that function's body: the file carries `return` statements elsewhere.
  const src = fs.readFileSync(path.join(LIB, 'chain-recovery-v1.js'), 'utf8');
  const from = src.indexOf('function chainShape(');
  assert.ok(from > 0, 'chainShape is not locatable in the owner');
  const body = src.slice(from, src.indexOf('\n}', from));
  // Whole RETURN STATEMENTS, then every literal inside them — two of them are
  // ternaries, so `return '...'` alone captured one arm and missed the other,
  // which made this check report eight shapes for a classifier that returns
  // eleven. One literal in that set is not a shape: `'stale'` is the rearm
  // receipt this function COMPARES against, and it is named here rather than
  // filtered by shape so a real shape can never be excused as an operand.
  const NOT_A_SHAPE = new Set(['stale']);
  const literals = new Set();
  for (const stmt of body.match(/return [^;]*;/g) || []) {
    for (const m of stmt.matchAll(/'([a-z][a-z-]*)'/g)) literals.add(m[1]);
  }
  const returned = [...literals].filter((l) => !NOT_A_SHAPE.has(l));
  assert.ok(returned.length >= 10, `only ${returned.length} shape literals found`);
  assert.deepStrictEqual(returned.sort(), [...chain.ALL_SHAPES].sort());
});

test('an armed chain renders every step, in order, exactly once', () => {
  for (const shape of Object.keys(anchor.SHAPE_POSITION)) {
    const token = anchor.anchorToken(shape);
    if (anchor.SHAPE_POSITION[shape] === null) continue;
    assert.ok(anchor.anchorTokenSafe(token), shape + ' produced an unsafe token: ' + token);
    assert.ok(token.startsWith(anchor.ANCHOR_PREFIX + ' '), shape + ': ' + token);
    const rendered = token.slice(anchor.ANCHOR_PREFIX.length + 1).split(' ');
    assert.deepStrictEqual(rendered.map((cell) => cell.slice(1)), [...anchor.ANCHOR_STEPS]);
  }
});

test('an inert, unknown or non-string shape renders no anchor', () => {
  assert.strictEqual(anchor.anchorToken('no-session'), anchor.ANCHOR_NONE);
  assert.strictEqual(anchor.anchorToken('a-shape-nobody-defined'), anchor.ANCHOR_NONE);
  assert.strictEqual(anchor.anchorToken(''), anchor.ANCHOR_NONE);
  assert.strictEqual(anchor.anchorToken(null), anchor.ANCHOR_NONE);
  assert.strictEqual(anchor.anchorToken(undefined), anchor.ANCHOR_NONE);
  assert.strictEqual(anchor.anchorToken(42), anchor.ANCHOR_NONE);
  assert.strictEqual(anchor.anchorToken({ shape: 'implementing' }), anchor.ANCHOR_NONE);
});

test('the marks follow rule 6: done before, current at, pending after', () => {
  assert.strictEqual(anchor.anchorToken('implementing'), 'Zensu: ▶implement ·review ·self-review');
  assert.strictEqual(anchor.anchorToken('ready-for-review'), 'Zensu: ✓implement ▶review ·self-review');
  assert.strictEqual(anchor.anchorToken('awaiting-self-review'), 'Zensu: ✓implement ✓review ▶self-review');
});

test('the failed mark is READ from the owner, never restated here', () => {
  // Rule 6 puts ✗ and ▶ on ONE axis, outcome — a chain that cannot advance is
  // not running. WHICH shapes those are belongs to chain-recovery-v1.js, and an
  // earlier revision restated it wrongly: it marked `ticket-spent` and
  // `ticket-lost` as failures under a comment claiming the owner treated them as
  // wedged, while the owner calls neither wedged nor dead-ended and its own
  // remedy for both is an ordinary advance instruction.
  const stuck = [...chain.RECOVERABLE_SHAPES, ...chain.DEAD_END_SHAPES];
  assert.ok(stuck.length >= 2, 'the owner exposes no stuck shapes to derive from');
  for (const shape of Object.keys(anchor.SHAPE_POSITION)) {
    const token = anchor.anchorToken(shape);
    if (token === anchor.ANCHOR_NONE || shape === 'chain-closed') continue;
    const failed = token.includes(anchor.MARK_BLOCKED);
    assert.strictEqual(failed, stuck.includes(shape), `${shape}: ${token}`);
  }
  assert.strictEqual(anchor.anchorToken('ticket-spent'), 'Zensu: ✓implement ▶review ·self-review');
  assert.strictEqual(anchor.anchorToken('ticket-lost'), 'Zensu: ✓implement ▶review ·self-review');
  assert.strictEqual(anchor.anchorToken('wedged-stale-rearm'), 'Zensu: ✓implement ✗review ·self-review');
  assert.strictEqual(
    anchor.anchorToken('self-review-unbindable'),
    'Zensu: ✓implement ✓review ✗self-review'
  );
});

test('a closed chain never claims a review that did not run', () => {
  // `chainShape` answers `chain-closed` on `chainDone === true` BEFORE it looks
  // at any ticket or round, and the zero-change `--chain-done` terminus sets that
  // flag with no ticket and no round. Three ticks there would tell the user a
  // review finished and passed when none ever ran — presentation asserting a
  // substantive fact, which the zen-mode SCOPE rule forbids outright.
  assert.strictEqual(anchor.anchorToken('chain-closed'), 'Zensu: ✓implement ·review ·self-review');
  assert.strictEqual(
    anchor.anchorToken('chain-closed', { reviewed: false }),
    'Zensu: ✓implement ·review ·self-review'
  );
  // Only an explicit `true` buys the ticks; anything else reads as unreviewed.
  for (const junk of [undefined, null, {}, { reviewed: 'yes' }, { reviewed: 1 }]) {
    assert.strictEqual(
      anchor.anchorToken('chain-closed', junk),
      'Zensu: ✓implement ·review ·self-review',
      JSON.stringify(junk)
    );
  }
  assert.strictEqual(
    anchor.anchorToken('chain-closed', { reviewed: true }),
    'Zensu: ✓implement ✓review ✓self-review'
  );
  // The anchor keeps `chain-closed` although the doctor's foreign-chain row
  // excludes it as inert: the turn that CLOSES a chain is exactly the turn whose
  // anchor says so. A deliberate difference of purpose, not drift.
  assert.ok(chain.INERT_SHAPES.includes('chain-closed'));
  assert.ok(chain.INERT_SHAPES.includes('no-session'));
  assert.strictEqual(anchor.anchorToken('no-session'), anchor.ANCHOR_NONE);
});

test('the reviewed input is derived here, from classifier fields only', () => {
  // This derivation used to live in the hook, where no unit case could reach it
  // and where every port was asked to re-implement the one rule whose failure
  // mode is a false completion claim. It reads only fields `classifyChain` puts
  // on its report, so it is host-neutral and belongs beside the mapping it feeds.
  assert.strictEqual(anchor.reviewedFromReport({ codeReviewDone: true }), true);
  assert.strictEqual(anchor.reviewedFromReport({ reviewRound: 1 }), true);
  assert.strictEqual(anchor.reviewedFromReport({ reviewRound: 7 }), true);
  // The shape the guard exists for: a zero-change `--chain-done`, closed with no
  // ticket, no round and no reviewer.
  assert.strictEqual(
    anchor.reviewedFromReport({ chainDone: true, codeReviewDone: false, reviewRound: 0 }),
    false
  );
  for (const junk of [undefined, null, 'yes', 42, []]) {
    assert.strictEqual(anchor.reviewedFromReport(junk), false, JSON.stringify(junk));
  }
  // End to end through the mapping, which is the pairing that actually renders.
  assert.strictEqual(
    anchor.anchorToken('chain-closed', {
      reviewed: anchor.reviewedFromReport({ chainDone: true, codeReviewDone: false, reviewRound: 0 }),
    }),
    'Zensu: ✓implement ·review ·self-review'
  );
  assert.strictEqual(
    anchor.anchorToken('chain-closed', {
      reviewed: anchor.reviewedFromReport({ chainDone: true, codeReviewDone: true, reviewRound: 2 }),
    }),
    'Zensu: ✓implement ✓review ✓self-review'
  );
});

test('the token predicate refuses every character the substitution cannot carry', () => {
  // The hook splices this value into a JSON string by parameter expansion.
  // A quote breaks the JSON; a backslash, an ampersand or the separator changes
  // what the replacement means; a newline splits the directive.
  for (const bad of [
    'Zensu: ▶implement"',
    'Zensu: ▶implement\\',
    'Zensu: ▶implement&',
    'Zensu: ▶implement|',
    'Zensu: ▶implement\n',
    'Zensu: implement',
    'Zensu:',
    'none ',
    ' none',
    'Zensu: ▶Implement',
    'anything else',
    '',
  ]) {
    assert.strictEqual(anchor.anchorTokenSafe(bad), false, JSON.stringify(bad));
  }
  assert.strictEqual(anchor.anchorTokenSafe(anchor.ANCHOR_NONE), true);
  assert.strictEqual(anchor.anchorTokenSafe('Zensu: ▶implement ·review ·self-review'), true);
});

test('the exported vocabulary is frozen so no consumer can mutate it', () => {
  assert.ok(Object.isFrozen(anchor.ANCHOR_STEPS));
  assert.ok(Object.isFrozen(anchor.SHAPE_POSITION));
  assert.strictEqual(anchor.ANCHOR_STEPS.length, 3);
});
