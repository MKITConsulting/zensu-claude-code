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
  // A REPORT OBJECT IS NOW A SUPPORTED INPUT, so the old assertion that any
  // object renders nothing was replaced rather than retrofitted: what is still
  // `none` is a report whose `shape` is absent, non-string, unmapped or inert.
  assert.strictEqual(anchor.anchorToken({}), anchor.ANCHOR_NONE);
  assert.strictEqual(anchor.anchorToken({ shape: 42 }), anchor.ANCHOR_NONE);
  assert.strictEqual(anchor.anchorToken({ shape: 'a-shape-nobody-defined' }), anchor.ANCHOR_NONE);
  assert.strictEqual(anchor.anchorToken({ shape: 'no-session' }), anchor.ANCHOR_NONE);
  assert.strictEqual(
    anchor.anchorToken({ shape: 'implementing' }),
    'Zensu: ▶implement ·review ·self-review'
  );
});

test('the marks follow rule 6: done before, current at, pending after', () => {
  assert.strictEqual(anchor.anchorToken('implementing'), 'Zensu: ▶implement ·review ·self-review');
  assert.strictEqual(anchor.anchorToken('ready-for-review'), 'Zensu: ✓implement ▶review ·self-review');
  // The self-review stage is outcome-dependent, so the string form alone can no
  // longer reach it — the outcome-aware cases at the end of this file own it.
  assert.strictEqual(
    anchor.anchorToken({
      shape: 'awaiting-self-review',
      linkage: 'bound',
      autopilot: { outcome: '' },
    }),
    'Zensu: ✓implement ✓review ▶self-review'
  );
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
  // `self-review-unbindable` is outcome-dependent, so it needs a report to render
  // at all. The owner-derived blocked mark still decides the CURRENT step: with a
  // converged outcome the position is `done: 2` and the owner's stuck set is what
  // puts ✗ on `self-review`, exactly as before.
  assert.strictEqual(
    anchor.anchorToken({
      shape: 'self-review-unbindable',
      linkage: 'bound',
      autopilot: { outcome: '' },
    }),
    'Zensu: ✓implement ✓review ✗self-review'
  );
});

test('a closed chain renders NO anchor at all', () => {
  // Both earlier readings of `chain-closed` asserted something untrue. `done: 3`
  // claimed passes: `chainShape` answers `chain-closed` on `chainDone === true`
  // before it looks at any ticket or round, and the classifier report carries no
  // `chainOutcome`, so a chain closed on `max-rounds` was indistinguishable from
  // one that passed while the directive publishes the tick as "finished and
  // passed". The unreviewed fallback `done: 1` claimed the opposite, rendering
  // `·review` — "not yet reached" — for a chain that is over.
  //
  // The persistence is what made either one more than a one-turn slip: the
  // workflow document survives `--chain-done`, and the hook re-resolves on every
  // prompt with no recency bound, so the line kept rendering over unrelated work.
  assert.strictEqual(anchor.anchorToken('chain-closed'), anchor.ANCHOR_NONE);
  // Both inert shapes now agree, which is how the owner already groups them.
  assert.ok(chain.INERT_SHAPES.includes('chain-closed'));
  assert.ok(chain.INERT_SHAPES.includes('no-session'));
  for (const shape of chain.INERT_SHAPES) {
    assert.strictEqual(anchor.anchorToken(shape), anchor.ANCHOR_NONE, shape);
  }
  // The key stays in SHAPE_POSITION so the parity check against ALL_SHAPES still
  // covers it; only its VALUE is null.
  assert.ok(Object.prototype.hasOwnProperty.call(anchor.SHAPE_POSITION, 'chain-closed'));
  assert.strictEqual(anchor.SHAPE_POSITION['chain-closed'], null);
});

test('no shape renders a completion claim for the whole chain', () => {
  // The directive publishes the tick as "a step that finished and passed", so a
  // fully ticked line asserts that the review AND the self-review both passed.
  // Nothing in the classifier report can establish that, which is why no shape
  // may produce it. This is the invariant the `chain-closed` rewrite bought; it
  // is asserted over the whole set rather than for that one shape, so a future
  // entry cannot reintroduce the claim somewhere else.
  const allTicked = anchor.ANCHOR_PREFIX
    + anchor.ANCHOR_STEPS.map((s) => ' ' + anchor.MARK_DONE + s).join('');
  for (const shape of Object.keys(anchor.SHAPE_POSITION)) {
    assert.notStrictEqual(anchor.anchorToken(shape), allTicked, shape);
  }
});

test('anchorToken takes no SECOND argument, so no options object can influence a position', () => {
  // The signature was `(shape, options)` while `chain-closed` consulted a
  // `reviewed` flag the hook derived. That flag was the false-completion input,
  // and it is gone. What replaced it is NOT "the shape alone": the FIRST argument
  // may now be the classifier report, and `outcomePosition` reads
  // `report.autopilot.outcome` off it. That input is bounded MONOTONE elsewhere
  // in this file — it can only refine a position the shape leaves unmapped. This
  // case owns the second-argument half: passing junk there must change nothing.
  assert.strictEqual(anchor.anchorToken.length, 1);
  for (const junk of [undefined, null, {}, { reviewed: true }, { reviewed: 'yes' }, 42]) {
    assert.strictEqual(
      anchor.anchorToken('implementing', junk),
      'Zensu: \u25b6implement \u00b7review \u00b7self-review',
      JSON.stringify(junk)
    );
    assert.strictEqual(anchor.anchorToken('chain-closed', junk), anchor.ANCHOR_NONE);
  }
});

test('a degraded owner renders no anchor rather than guessing', () => {
  // The guard these `return null` arms provide was added after a measured
  // defect: `DEAD_END_SHAPES` was not exported, the first spelling defaulted to
  // the running mark, and every dead-ended chain rendered as running with the
  // suite green. Until `stuckShapes` took an owner parameter the arms were
  // unreachable from any check, because the unit file always requires the real
  // sibling. The parameter exists for this test and for nothing else.
  //
  // THE STUBS FOLLOWED THE INPUT SHAPE. They supplied the two SUBSETS, which the
  // consumer stopped reading when it began consuming the owner`s own
  // `STUCK_SHAPES` composition — so every one of them landed on the same
  // `!Array.isArray(undefined)` disjunct and the length and non-array arms had no
  // executed case left. That is the "left the executed case behind" shape one
  // file over from where it was being fixed.
  assert.strictEqual(anchor.stuckShapes({ STUCK_SHAPES: [] }), null);
  assert.strictEqual(anchor.stuckShapes({ STUCK_SHAPES: 'wedged-stale-rearm' }), null);
  assert.strictEqual(anchor.stuckShapes({}), null);
  // The subsets alone are no longer enough, which is the property the swap bought:
  // a consumer that went back to concatenating them would answer non-null here.
  assert.strictEqual(
    anchor.stuckShapes({ RECOVERABLE_SHAPES: ['a'], DEAD_END_SHAPES: ['b'] }),
    null,
  );
  // The seam control: the value comes FROM the owner rather than being rebuilt.
  assert.deepStrictEqual(anchor.stuckShapes({ STUCK_SHAPES: ['x'] }), ['x']);
  // The positive control: the real owner still yields a usable set, so the
  // refusals above cannot be satisfied by a function that answers null always.
  const real = anchor.stuckShapes();
  assert.ok(Array.isArray(real) && real.length >= 2);
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

// --- Outcome-aware review mark (PR #285 review finding, zen-anchor-v1.js:108) ---
//
// `awaiting-self-review` and `self-review-unbindable` are both reached from
// `codeReviewDone === true`, and that flag does NOT mean the review passed: the
// bound max-round handoff sets it with `outcome=max-rounds`. Rendering `✓review`
// there publishes "finished and passed" for a review that ran out of budget.
//
// The evidence for the outcome already exists on the classifier's report, but
// ONLY under bound linkage: `chainOutcome` is one of the five Autopilot link
// fields, deleted from a standalone document at begin. So the honest answer
// splits by linkage — render the failed mark when the outcome proves it, render
// the passed mark when a bound report proves the review ended without that
// stamp, and render NOTHING when no outcome signal exists at all.

function boundReport(over) {
  return Object.assign({
    shape: 'awaiting-self-review',
    linkage: 'bound',
    autopilot: {
      runId: 'run-1',
      attempt: 1,
      returnStage: 'GATES',
      chainId: 'chain-1',
      outcome: '',
    },
  }, over);
}

test('a review that ran out of budget renders as failed, never as passed', () => {
  for (const shape of ['awaiting-self-review', 'self-review-unbindable']) {
    const report = boundReport({ shape });
    report.autopilot = Object.assign({}, report.autopilot, { outcome: 'max-rounds' });
    assert.strictEqual(
      anchor.anchorToken(report),
      'Zensu: ✓implement ✗review ·self-review',
      shape
    );
  }
});

test('a bound review that ended without the max-rounds stamp renders as passed', () => {
  // The two ways to reach `codeReviewDone === true` are convergence and the
  // max-round handoff, and only the second stamps the outcome. So an absent
  // stamp on a BOUND report is evidence of convergence — which is exactly the
  // evidence a standalone document cannot supply.
  for (const outcome of ['', 'pass']) {
    const report = boundReport({});
    report.autopilot = Object.assign({}, report.autopilot, { outcome });
    assert.strictEqual(
      anchor.anchorToken(report),
      'Zensu: ✓implement ✓review ▶self-review',
      JSON.stringify(outcome)
    );
  }
});

test('with no outcome signal the self-review stage renders no anchor', () => {
  // A standalone chain carries no `chainOutcome` at all, so neither mark can be
  // justified: `✓review` claims a pass this module cannot see, and `▶review`
  // claims a review that is over is still running. The sibling `chain-closed`
  // entry already answers `null` under the identical evidence gap.
  for (const shape of ['awaiting-self-review', 'self-review-unbindable']) {
    assert.strictEqual(anchor.anchorToken(shape), anchor.ANCHOR_NONE, shape);
    assert.strictEqual(
      anchor.anchorToken({ shape, linkage: 'standalone', autopilot: null }),
      anchor.ANCHOR_NONE,
      shape
    );
    assert.strictEqual(
      anchor.anchorToken({ shape, linkage: 'partial', autopilot: null }),
      anchor.ANCHOR_NONE,
      shape
    );
  }
});

test('a report form cannot promote a shape the table renders without an outcome', () => {
  // The report input is MONOTONE by construction: it is consulted only for the
  // two shapes reached from `codeReviewDone === true`. Every other shape follows
  // from the shape alone, so a forged `autopilot.outcome` changes nothing.
  for (const outcome of ['max-rounds', 'pass', 'no-changes', '']) {
    assert.strictEqual(
      anchor.anchorToken({ shape: 'implementing', linkage: 'bound', autopilot: { outcome } }),
      'Zensu: ▶implement ·review ·self-review',
      outcome
    );
    assert.strictEqual(
      anchor.anchorToken({ shape: 'chain-closed', linkage: 'bound', autopilot: { outcome } }),
      anchor.ANCHOR_NONE,
      outcome
    );
  }
});

test('a degraded owner throws so the hook classifies it instead of reading health', () => {
  // `stuckShapes` returning null used to become ANCHOR_NONE, which the hook
  // accepts as a healthy token — so an owner whose STUCK_SHAPES export is
  // removed, renamed or emptied silently disabled the anchor for EVERY shape.
  // The hook already classifies a throw as `anchor render`; the outcome is still
  // no anchor, and the difference is that it is disclosed.
  const os = require('node:os');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zen-anchor-degraded-'));
  try {
    fs.copyFileSync(path.join(LIB, 'zen-anchor-v1.js'), path.join(dir, 'zen-anchor-v1.js'));
    fs.writeFileSync(
      path.join(dir, 'chain-recovery-v1.js'),
      'module.exports = { STUCK_SHAPES: [], RECOVERABLE_SHAPES: [], DEAD_END_SHAPES: [] };\n'
    );
    const degraded = require(path.join(dir, 'zen-anchor-v1.js'));
    assert.strictEqual(degraded.stuckShapes(), null);
    assert.throws(
      () => degraded.anchorToken('implementing'),
      /STUCK_SHAPES/,
      'a degraded owner must throw rather than answer none'
    );
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('the outcome the anchor reads is the one the real classifier emits', () => {
  // THE SEAM, not a hand-built stand-in. Every case above supplies its own report
  // object, which certifies the mapping and NOT the contract that
  // `classifyChain` actually puts the outcome where `anchorToken` looks for it -
  // exactly the caller-mock gap a cross-layer pairing exists to close. This runs
  // the owner over a real bound document and feeds its output straight in.
  const bound = {
    active: true,
    implComplete: true,
    chainDone: false,
    codeReviewDone: true,
    selfReviewFixed: false,
    vanilla: false,
    reviewTicket: 't1',
    reviewTicketConsumed: true,
    reviewRound: 1,
    phase: 'IMPL',
    history: [],
    bypasses: [],
    deferredReviewClaim: '',
    autopilotRunId: 'run-seam',
    autopilotAttempt: 1,
    autopilotReturnStage: 'GATES',
    chainId: 'chain-seam',
    chainOutcome: 'max-rounds',
  };
  const report = chain.classifyChain(bound);
  assert.strictEqual(report.shape, 'awaiting-self-review');
  assert.strictEqual(report.linkage, 'bound');
  assert.strictEqual(report.autopilot.outcome, 'max-rounds');
  assert.strictEqual(anchor.anchorToken(report), 'Zensu: ✓implement ✗review ·self-review');

  const converged = chain.classifyChain(Object.assign({}, bound, { chainOutcome: '' }));
  assert.strictEqual(converged.autopilot.outcome, '');
  assert.strictEqual(anchor.anchorToken(converged), 'Zensu: ✓implement ✓review ▶self-review');
});

test('a row naming an outcome the owner does not declare THROWS at load', () => {
  // THE MUTATION THIS FILE EXISTS TO KILL. The allowlist used to be a hand copy,
  // so `max-round` for `max-rounds` dropped the ✗review mark for a
  // budget-exhausted bound review while every check stayed green - the totality
  // loop accepts `none` as a non-empty string, and `anchorNoneIsExpected` then
  // answered true so the hook`s disclosure stayed quiet as well.
  //
  // Applied to a COPY, against a stub owner that still declares a domain: that is
  // what separates a stale row here from a DEGRADED owner, which must stay
  // loadable so `stuckShapes` can raise its own error instead.
  const dir = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'zen-anchor-stale-'));
  const src = fs.readFileSync(path.join(LIB, 'zen-anchor-v1.js'), 'utf8');
  assert.ok(src.includes("'max-rounds': Object.freeze("), 'the row to mutate is not locatable');
  fs.writeFileSync(
    path.join(dir, 'zen-anchor-v1.js'),
    src.replace("'max-rounds': Object.freeze(", "'max-round': Object.freeze("),
  );
  fs.writeFileSync(
    path.join(dir, 'chain-recovery-v1.js'),
    'module.exports = { CHAIN_OUTCOMES: Object.freeze([\'\', \'pass\', \'no-changes\', \'max-rounds\']),'
    + ' STUCK_SHAPES: Object.freeze([\'wedged-stale-rearm\']), ALL_SHAPES: Object.freeze([]) };',
  );
  assert.throws(
    () => require(path.join(dir, 'zen-anchor-v1.js')),
    /max-round/,
    'a stale outcome row loaded silently - the mark would vanish with every check green',
  );
});

test('outcomePosition is a positive allowlist: an unrecognised outcome renders nothing', () => {
  // FORWARD COUPLING, and the reason this places a SUBSET rather than running a
  // ternary. `chain-recovery-v1.js` exports and freezes `CHAIN_OUTCOMES`, and
  // `linkage: 'bound'` is granted only for a member of it - so today the
  // else-branch is reachable for `''`, `pass` and `no-changes` only. A FIFTH
  // member added there reaches this function with no edit here and, under a
  // ternary, inherits the PASSED mark silently. Placing a subset makes that case
  // render nothing instead, which is this module's stated fail-open direction.
  //
  // This comment used to say the constant was NOT exported - a premise the same
  // changeset had already made false, and which this file then contradicted 108
  // lines further down. The table is derived from that export now, so a stale row
  // throws at load rather than silently dropping a mark.
  for (const shape of ['awaiting-self-review', 'self-review-unbindable']) {
    for (const outcome of ['', 'pass']) {
      const t = anchor.anchorToken({ shape, linkage: 'bound', autopilot: { outcome } });
      assert.match(t, /✓review/, `${shape}/${JSON.stringify(outcome)} must render the passed mark`);
    }
    assert.match(
      anchor.anchorToken({ shape, linkage: 'bound', autopilot: { outcome: 'max-rounds' } }),
      /✗review/,
      `${shape}/max-rounds must render the failed mark`,
    );
    for (const outcome of ['no-changes', 'cancelled', 'PASS', 'passed', 'unknown-future-member']) {
      assert.strictEqual(
        anchor.anchorToken({ shape, linkage: 'bound', autopilot: { outcome } }),
        anchor.ANCHOR_NONE,
        `${shape}/${outcome} must render no anchor rather than inherit a mark`,
      );
    }
  }
});

test('the two blocked-mark authorities are OR-ed, so an outcome can never clear one the owner asserts', () => {
  // `stuckShapes` reads the owner's own STUCK_SHAPES and is the authority for a
  // shape the classifier calls stuck. `position.blocked` is NOT a second copy of
  // that set - it is a per-POSITION verdict for the two shapes whose MARK the
  // shape alone cannot settle. MEASURED: `self-review-unbindable` IS in the
  // owner's stuck set and `awaiting-self-review` is not, so the two overlap on
  // exactly one of them, and the contract that keeps that safe is the OR: an
  // outcome may ADD the failed mark, never clear one the owner asserts. A ternary
  // that returned `blocked: false` into an AND would silently promote a wedged
  // chain to running.
  const stuck = anchor.stuckShapes();
  assert.ok(Array.isArray(stuck) && stuck.length, 'the owner must expose a stuck set');
  for (const shape of ['awaiting-self-review', 'self-review-unbindable']) {
    if (stuck.indexOf(shape) < 0) continue;
    for (const outcome of ['', 'pass', 'max-rounds']) {
      // The mark lands on whichever step is CURRENT for that position, so the
      // property is that a failed mark is present at all - not which step wears it.
      assert.match(
        anchor.anchorToken({ shape, linkage: 'bound', autopilot: { outcome } }),
        /✗/,
        `${shape} is stuck per the owner, so ${JSON.stringify(outcome)} must not clear the failed mark`,
      );
    }
  }
  // And the failed-mark case elsewhere in this file iterates the STRING input, so
  // neither of these two shapes is reached there at all.
  assert.strictEqual(anchor.anchorToken('awaiting-self-review'), anchor.ANCHOR_NONE);
  assert.strictEqual(anchor.anchorToken('self-review-unbindable'), anchor.ANCHOR_NONE);
});

test('anchorNoneIsExpected answers for every shape, so the hook keeps no copy of the rule', () => {
  // The hook has to tell a LEGITIMATE `none` from a degraded module answering
  // `none`, and it derived that from `SHAPE_POSITION[shape]` being truthy. That
  // went silent the moment two shapes mapped to null while still being
  // producible through a report: `mapped` is true and the entry is null, so the
  // gate was false and a degraded module disclosed nothing at exactly the two
  // shapes this feature added. The rule belongs to the module that owns the
  // mapping; a consumer cannot check a producer it does not own.
  assert.strictEqual(typeof anchor.anchorNoneIsExpected, 'function');

  // Inert shapes: `none` is the correct answer and no fault.
  for (const shape of ['no-session', 'chain-closed']) {
    assert.strictEqual(anchor.anchorNoneIsExpected({ shape }), true, shape);
  }
  // A shape with a real position: `none` is never legitimate there.
  assert.strictEqual(anchor.anchorNoneIsExpected({ shape: 'implementing' }), false);
  // An unknown shape has no row at all, so `none` is a fault the hook must name.
  assert.strictEqual(anchor.anchorNoneIsExpected({ shape: 'not-a-shape' }), false);
  assert.strictEqual(anchor.anchorNoneIsExpected(null), false);

  // The two outcome-dependent shapes: legitimate without a placeable outcome,
  // a fault with one.
  for (const shape of ['awaiting-self-review', 'self-review-unbindable']) {
    assert.strictEqual(anchor.anchorNoneIsExpected({ shape }), true, `${shape}/standalone`);
    assert.strictEqual(
      anchor.anchorNoneIsExpected({ shape, linkage: 'partial', autopilot: null }),
      true,
      `${shape}/partial`,
    );
    assert.strictEqual(
      anchor.anchorNoneIsExpected({ shape, linkage: 'bound', autopilot: { outcome: 'no-changes' } }),
      true,
      `${shape}/unplaceable-outcome`,
    );
    for (const outcome of ['', 'pass', 'max-rounds']) {
      assert.strictEqual(
        anchor.anchorNoneIsExpected({ shape, linkage: 'bound', autopilot: { outcome } }),
        false,
        `${shape}/${JSON.stringify(outcome)} is placeable, so none is a fault`,
      );
    }
  }
});

test('the outcome allowlist is keyed on the owner exported value domain, and its rows are frozen', () => {
  // The allowlist RE-SPELLS a value domain `chain-recovery-v1.js` owned but
  // neither froze nor exported, so a renamed member left a dead key here and in
  // this file's own literals. Reading the owner's array closes the addition
  // direction the roster note already covers AND the rename direction it does
  // not. The rows are frozen to match `SHAPE_POSITION`, whose every entry is:
  // `outcomePosition` hands a row out by reference, so an unfrozen row is a
  // shared object a future in-module caller could mutate for every later render.
  assert.ok(Array.isArray(chain.CHAIN_OUTCOMES), 'the owner must export CHAIN_OUTCOMES');
  assert.ok(Object.isFrozen(chain.CHAIN_OUTCOMES), 'CHAIN_OUTCOMES must be frozen like its sibling tables');
  for (const shape of ['awaiting-self-review', 'self-review-unbindable']) {
    for (const outcome of chain.CHAIN_OUTCOMES) {
      const token = anchor.anchorToken({ shape, linkage: 'bound', autopilot: { outcome } });
      assert.ok(
        typeof token === 'string' && token.length > 0,
        `${shape}/${outcome} must render a decided value, never undefined`,
      );
    }
  }
  // Every key the allowlist places must be a member the owner still declares.
  //
  // READ FROM THE PRODUCER, never re-spelled here. This list used to be a THIRD
  // hand copy of the same three strings, so it bound a copy to the owner rather
  // than binding the MODULE to the owner: a typo in the module - `max-round` for
  // `max-rounds` - left this literal listing three valid members, left the
  // totality loop above green because `none` is a non-empty string, and silently
  // dropped the ✗review mark for a budget-exhausted bound review, with
  // `anchorNoneIsExpected` then answering true so the hook`s own disclosure
  // stayed quiet too.
  const placed = anchor.placedOutcomes();
  assert.ok(Array.isArray(placed) && placed.length > 0, 'the module must expose the outcomes it places');
  for (const key of placed) {
    assert.ok(
      chain.CHAIN_OUTCOMES.indexOf(key) >= 0,
      `the allowlist places ${JSON.stringify(key)}, which the owner no longer declares`,
    );
  }
  // The rows themselves are frozen.
  const row = anchor.anchorToken({ shape: 'awaiting-self-review', linkage: 'bound', autopilot: { outcome: 'pass' } });
  assert.match(row, /✓review/);
  const src = fs.readFileSync(path.join(__dirname, '..', '..', 'hooks', 'lib', 'zen-anchor-v1.js'), 'utf8');
  const table = src.slice(src.indexOf('const OUTCOME_POSITION'), src.indexOf('function outcomePosition'));
  assert.ok(table.length > 0, 'the outcome table could not be sliced');
  const rows = table.match(/\{ done:/g) || [];
  const frozenRows = table.match(/Object\.freeze\(\{ done:/g) || [];
  assert.strictEqual(
    frozenRows.length,
    rows.length,
    `every outcome row must be frozen like SHAPE_POSITION's, got ${frozenRows.length} of ${rows.length}`,
  );
});
