'use strict';
// zen-mode chain-progress anchor — the ONE owner of the anchor's step vocabulary
// and of the mapping from a Zensu review-chain shape to a rendered anchor line.
//
// Why this exists. Rule 6 of the zen-mode directive used to ask the MODEL to
// derive its own step names for "anything that spans several turns". It was
// deliberately decoupled from every Zensu component, so the anchor rendered for
// ad-hoc work with no Zensu process behind it — a session answering "what is
// this Python process?" still closed with a four-step progress line. The anchor
// only means anything inside a Zensu-driven development process, so the hook now
// resolves the position itself and hands the model a finished line.
//
// THE DECOUPLING RULE IT DOES NOT BREAK. CLAUDE.md §"zen-mode Chain-Progress
// Anchor" forbids carrying "a second copy of another module's stage vocabulary",
// and it was written after a hand-copy of `zensu-autopilot-state.sh`'s `STAGES`
// turned out to be wrong in three ways. This module copies nothing: the caller
// passes a shape that `chain-recovery-v1.js` PRODUCED, this file's own key set is
// pinned against that module's exported `ALL_SHAPES`, and the BLOCKED set is
// READ from its `STUCK_SHAPES` composition rather than restated.
// An earlier revision did restate it, and was wrong the same way the `STAGES`
// copy had been: it marked `ticket-spent` and `ticket-lost` as failures under a
// comment claiming the owner treated them as wedged, while the owner's own
// remedy for both is an ordinary advance instruction. Two bounds keep the rest
// honest:
//   * `zensu-autopilot-state.sh`'s `STAGES` stays out of scope. That machine is
//     cyclic — `GATES`, `CONVERGE`, `VALIDATE` and `COVER` all re-enter through
//     `toAwaitTdd` — while the four marks are linear, so a retried stage has no
//     defined mark. The review chain does not re-enter, which is what makes it
//     renderable as a position at all.
//   * An UNMAPPED shape answers `ANCHOR_NONE` rather than guessing. A shape added
//     to `chainShape` therefore costs an anchor, never a wrong one.
//
// Host-neutral in the sense that matters for a port: no filesystem, no
// environment, no process exit. It does require ONE sibling — the classifier
// whose shapes it maps — because reading that module is what the paragraph above
// is about. The host half — which document to read, which session key identifies
// it, and how the token reaches the directive — lives in
// `hooks/user-prompt-zen-mode.sh`.
//
// KNOWN RESIDUAL, named rather than implied: the document behind the shape is
// validated STRUCTURALLY only. `validateWorkflowState` derives `session_id_hash`
// from the file's own name, `.zensu/state/` is writable from inside a session,
// and there is no MAC — the same property CLAUDE.md records for the bypass
// ledger. So a rendered `✓review` reports what a readable document CLAIMED, never
// evidence that a review ran. The reachable outputs are the closed set below, so
// this is not a text-injection channel; what it is, is a completion signal a
// co-tenant writer could put in front of the user on every turn.

const chain = require('./chain-recovery-v1.js');

// The steps of the Zensu review chain, in the order a chain traverses them.
// `implement` covers everything up to `--tdd-complete`; `review` covers the
// fan-out, the consume-mode reviewer and every auto-fix round; `self-review`
// covers the terminal `/zensu:self-review` stage that owns `--chain-done`.
const ANCHOR_STEPS = Object.freeze(['implement', 'review', 'self-review']);

// The four marks of rule 6, in the meaning that rule fixes: a step that finished
// and passed, the step running now, one not yet reached, and one that failed or
// is blocked.
const MARK_DONE = '✓';
const MARK_RUNNING = '▶';
const MARK_PENDING = '·';
const MARK_BLOCKED = '✗';

const ANCHOR_PREFIX = 'Zensu:';

// The token that says "render no anchor at all". A word rather than an empty
// string on purpose: the hook substitutes this value into a directive sentence,
// and an empty substitution would leave the model reading a sentence with a
// missing operand instead of an instruction it can follow.
const ANCHOR_NONE = 'none';

// Every literal `chainShape` returns, mapped to how far the chain has PROGRESSED:
// `done` is the number of leading steps that finished and passed, and `mark` is
// the mark for the step at that index (`null` when no step is in play, so the
// remainder renders as not-yet-reached). `null` for the whole entry means the
// chain is not a process worth anchoring.
//
// `mark` is NOT stated per shape: `stuckShapes` reads it from the owner's sets,
// so this file cannot disagree with the module that decides them.
const SHAPE_POSITION = Object.freeze({
  'no-session': null,
  implementing: Object.freeze({ done: 0 }),
  'ready-for-review': Object.freeze({ done: 1 }),
  'ticket-unclaimed': Object.freeze({ done: 1 }),
  'review-in-flight': Object.freeze({ done: 1 }),
  'ticket-spent': Object.freeze({ done: 1 }),
  'ticket-lost': Object.freeze({ done: 1 }),
  'wedged-stale-rearm': Object.freeze({ done: 1 }),
  // THESE TWO ARE OUTCOME-DEPENDENT, so the table cannot answer them alone and
  // deliberately answers `null` — the same "no evidence, render nothing" verdict
  // the `chain-closed` entry below reaches, and `outcomePosition` below is what
  // supplies the missing half when a report carries it.
  //
  // Both shapes are reached from `codeReviewDone === true`, and that flag does
  // not mean the review PASSED: `zensu-tdd-phase.sh`'s bound max-round handoff
  // states its own postcondition as "outcome=max-rounds + codeReviewDone=true
  // while chainDone stays false". A fixed `done: 2` therefore rendered `✓review`
  // — which the directive publishes as "finished and passed" — for a review that
  // ran out of budget without converging, on every prompt, with no recency bound.
  // The other in-vocabulary answers are worse: `done: 1` renders `▶review` for a
  // review that is over, the opposite false claim, and `✗` unconditionally
  // reports every converged chain as failed.
  //
  // KNOWN RESIDUAL, and it is the reason this entry is `null` rather than a
  // second position: the outcome signal exists only under BOUND linkage.
  // `chainOutcome` is one of the five `AUTOPILOT_LINK_FIELDS`, written `""` at a
  // bound begin and DELETED from a standalone document, so a standalone chain at
  // this stage carries no outcome at all and neither mark can be justified for
  // it. Closing that means giving a standalone document its own outcome field,
  // which is a workflow-state schema change and therefore a `minor` release
  // under CLAUDE.md §"Runtime Lineage". The cost of the honest answer is named
  // rather than paid with a false claim: a standalone chain renders no anchor
  // for its self-review stage.
  'awaiting-self-review': null,
  'self-review-unbindable': null,
  // A CLOSED chain renders NO anchor, for the same reason `no-session` does not:
  // it carries no work forward. The owner groups the two itself — `INERT_SHAPES`
  // is `['no-session', 'chain-closed']`, and `NEXT_COMMAND['chain-closed']` reads
  // "none — this chain already reached its terminus".
  //
  // Two earlier spellings both rendered here and both asserted something untrue,
  // which is why this entry is `null` rather than a cleverer position. `done: 3`
  // claimed passes: `chainShape` answers `chain-closed` on `chainDone === true`
  // BEFORE it looks at any ticket or round, and `classifyChain`'s report does not
  // carry `chainOutcome` at all — that field reaches a consumer only as
  // `report.autopilot.outcome`, under bound linkage — so a chain that ran one
  // round and closed on `max-rounds` was indistinguishable from one that passed,
  // while the directive publishes `✓` as "a step that finished and passed". The
  // fallback reading `done: 1` claimed the opposite: it renders `·review`, which
  // that same directive publishes as "not yet reached", for a chain that is over.
  //
  // The PERSISTENCE is what makes either one more than a one-turn slip. The
  // workflow document is not cleared by `--chain-done` — `zensu-tdd-phase.sh`
  // treats `active === true && implComplete === true && chainDone === true` as a
  // regular state — and the hook re-resolves the anchor on EVERY prompt with no
  // recency bound. So a closed chain kept rendering its line over unrelated work
  // for the rest of the session, which is precisely the "anchor rendered for work
  // with no Zensu process behind it" defect this whole module exists to remove.
  //
  // Rendering on the CLOSING turn alone would be defensible, but the shape cannot
  // express it: `chain-closed` cannot distinguish "just closed" from "closed two
  // hours ago". That needs a recency signal the classifier does not supply.
  'chain-closed': null,
});

// The one predicate both the hook and the suites apply to a token. It is
// deliberately NARROW — a prefix, then mark/step pairs, and nothing else — so a
// value that did not come out of this module cannot pass as one that did. That
// is a property of the ANCHOR, not of any transport: it is what lets a consumer
// treat the token as a closed vocabulary rather than as free text. This host
// substitutes the token into a JSON string by shell parameter expansion and
// re-checks it twice more on the way — a grammar re-spelled inside its own node
// program, then a byte test in the shell — because a predicate exported by the
// module being distrusted cannot be the last word. A port with a different
// transport still owes its own check; this predicate is not a substitute for one.
//
// Each interpolated constant is escaped: a mark that happened to be `-`, `]` or
// `^` would otherwise turn the class into a range, close it, or invert it, and
// because `anchorToken` falls back to `ANCHOR_NONE` on a failed match the change
// would be silent rather than loud.
function escapeForClass(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\-]/g, '\\$&');
}

const ANCHOR_TOKEN_RE = new RegExp(
  '^(?:' + escapeForClass(ANCHOR_NONE) + '|' + escapeForClass(ANCHOR_PREFIX)
    + '(?: [' + [MARK_DONE, MARK_RUNNING, MARK_PENDING, MARK_BLOCKED].map(escapeForClass).join('')
    + '][a-z][a-z-]*)+)$'
);

function anchorTokenSafe(token) {
  return typeof token === 'string' && ANCHOR_TOKEN_RE.test(token);
}

// NOTHING here derives whether a review PASSED, and that absence is deliberate.
// An earlier revision carried `reviewedFromReport`, which read
// `codeReviewDone === true || reviewRound >= 1` off the classifier report and
// gated the closed-chain ticks on it. Both operands say a round was ISSUED, never
// that it succeeded, so the rendered `✓` — published to the user as "finished and
// passed" — was a claim this module had no evidence for. `chainOutcome`
// (`'' | 'pass' | 'no-changes' | 'max-rounds'`) is a workflow-state key that
// `classifyChain` does not carry as a TOP-LEVEL report field. It does reach the
// report for a BOUND chain, inside `report.autopilot.outcome`, and
// `outcomePosition` below reads exactly that — deliberately, and only there. For
// a STANDALONE chain there is still no outcome signal anywhere the anchor can
// reach, which is why the two outcome-dependent shapes render nothing at all
// rather than guessing.
//
// Mapping `chain-closed` to `null` removed the only consumer, so the derivation,
// its `unreviewedDone` rung and the `options.reviewed` parameter all went with
// it. Do NOT reintroduce a "reviewed" input without a real outcome signal: the
// cheap-looking spelling is the one that shipped the false claim.

// THE STUCK SET is read from the owner and never restated here. Scope that
// sentence to the SET: `position.blocked` below is not a second copy of it but a
// per-POSITION verdict, for the two shapes whose mark the shape alone cannot
// settle, and the two authorities are OR-ed so an outcome may ADD the failed mark
// and can never clear one the owner asserts. A shape the classifier calls stuck
// renders `✗`; every other in-play shape renders `▶`. Rule 6 puts the two marks
// on ONE axis, outcome, so a chain that cannot advance is not running.
//
// A MISSING export answers null rather than defaulting, and `anchorToken` then
// renders no anchor at all. Defaulting to `▶` was the first spelling and it was
// silently wrong: `DEAD_END_SHAPES` was not exported yet, so every dead-ended
// chain rendered as running with every check green. An owner this module cannot
// read is a state it must not guess through.
// The `owner` parameter is a TEST SEAM and nothing else: production always calls
// this with no argument. It exists because both `return null` guards were
// unreachable from any check — the unit file requires the real sibling, so both
// operands were always present non-empty arrays, and reverting the function to
// the silently-wrong `(recoverable||[]).concat(deadEnd||[])` left every case
// green. A guard added in response to a shipped defect deserves an executed case.
function stuckShapes(owner) {
  const source = owner || chain;
  // THE COMPOSITION IS READ, not restated. The two subsets were read and then
  // concatenated here, which re-derived a constant the owner already computes
  // for its own `wedged` verdict. A third stuck subset added there would be
  // folded into `STUCK_SHAPES` and silently omitted from this copy, so a chain
  // the classifier calls wedged would render the running mark instead of the
  // failed one, with both suites green. That is the `INERT_SHAPES` precedent.
  const stuck = source.STUCK_SHAPES;
  if (!Array.isArray(stuck) || !stuck.length) return null;
  return stuck;
}

// The two outcome-dependent shapes, and the ONLY shapes for which a report's
// `autopilot.outcome` is read. Keeping the set here rather than testing for a
// truthy outcome at the call site is what makes the report input MONOTONE: every
// other shape follows from the shape alone, so a forged outcome on a report
// cannot promote or demote anything.
const OUTCOME_DEPENDENT_SHAPES = Object.freeze(['awaiting-self-review', 'self-review-unbindable']);

// The outcomes this module is willing to place, DERIVED from the owner's own
// value domain rather than spelled beside it. `chain-recovery-v1.js` exports and
// freezes `CHAIN_OUTCOMES`, and `linkage: 'bound'` is granted only for a member
// of it — so a FIFTH member added there reaches this function with no edit here,
// and under a ternary it would inherit the PASSED mark silently. Placing a
// subset makes that case render nothing, which is this module's stated fail-open
// direction.
//
// THE PREVIOUS SPELLING WAS A HAND-COPY, and its failure mode was silent in both
// directions: a typo here — `max-round` for `max-rounds` — dropped the ✗review
// mark for a budget-exhausted bound review, while `anchorNoneIsExpected` then
// answered true so the hook's own disclosure stayed quiet as well. The header
// that justified it also asserted `CHAIN_OUTCOMES` was NOT exported, which the
// same changeset had made false. Deriving removes both: a row naming an outcome
// the owner does not declare now THROWS at load rather than being dropped, which
// is the direction `stuckShapes` already takes for a degraded owner. Note the
// asymmetry the allowlist also fixes: `no-changes` is a real member today and was
// being placed as PASSED, which it is not — it says the attempt changed nothing.
// EVERY ROW IS FROZEN, matching `SHAPE_POSITION` above. `outcomePosition` hands a
// row out BY REFERENCE, so an unfrozen row is a shared object a future in-module
// caller could mutate for every later render - the asymmetry, not a live defect.
const OUTCOME_ROWS = Object.freeze({
  '': Object.freeze({ done: 2, blocked: false }),
  pass: Object.freeze({ done: 2, blocked: false }),
  'max-rounds': Object.freeze({ done: 1, blocked: true }),
});

// LOUD, not silent. A row naming an outcome the owner no longer declares is a
// stale mapping, and dropping it quietly is exactly how the ✗review mark would
// disappear with every check green.
const OUTCOME_POSITION = Object.freeze(
  Object.keys(OUTCOME_ROWS).reduce((acc, outcome) => {
    // TWO DIFFERENT STATES, and collapsing them was wrong. An owner that does not
    // export `CHAIN_OUTCOMES` at all is DEGRADED — the same condition
    // `stuckShapes` answers for, and it must stay loadable so that its own throw
    // is the one the hook reports. A row naming an outcome the owner DOES declare
    // a domain for, and that is not in it, is a STALE MAPPING in this file, and
    // that is what must never be dropped in silence.
    if (Array.isArray(chain.CHAIN_OUTCOMES) && chain.CHAIN_OUTCOMES.indexOf(outcome) < 0) {
      throw new Error(
        'zen-anchor-v1.js: outcome ' + JSON.stringify(outcome) +
        ' is not declared by chain-recovery-v1.js CHAIN_OUTCOMES',
      );
    }
    acc[outcome] = OUTCOME_ROWS[outcome];
    return acc;
  }, {}),
);

// The outcomes this module places, for a consumer that must not re-spell them.
function placedOutcomes() {
  return Object.keys(OUTCOME_POSITION);
}

// The position for an outcome-dependent shape, or null when no outcome signal is
// available or the outcome is not one this module places. `max-rounds` is the one
// stamp the bound max-round handoff leaves; an EMPTY outcome on a bound report at
// these shapes is evidence the review converged, because the two ways to reach
// `codeReviewDone === true` are convergence and that handoff. A standalone report
// carries no outcome field at all and therefore stays null.
function outcomePosition(shape, report) {
  if (OUTCOME_DEPENDENT_SHAPES.indexOf(shape) < 0) return null;
  if (!report || report.linkage !== 'bound') return null;
  const autopilot = report.autopilot;
  if (!autopilot || typeof autopilot !== 'object') return null;
  if (typeof autopilot.outcome !== 'string') return null;
  return Object.prototype.hasOwnProperty.call(OUTCOME_POSITION, autopilot.outcome)
    ? OUTCOME_POSITION[autopilot.outcome]
    : null;
}

// shape -> the anchor line the model renders verbatim, or ANCHOR_NONE.
// An unknown shape, a non-string, and BOTH inert shapes — `no-session` and
// `chain-closed` — answer ANCHOR_NONE. That is the fail-open direction: a
// missing anchor costs a line of presentation, while a wrong one misreports
// where the session stands.
//
// It takes ONE argument and no options. The signature was `(shape, options)`
// while `chain-closed` still rendered, and that flag was the false-completion
// input; the argument here is EITHER a shape string or the classifier's own
// report, never a caller-derived judgement. The report is consulted for the two
// `OUTCOME_DEPENDENT_SHAPES` alone, so a caller still cannot influence what any
// other shape renders.
function anchorToken(input) {
  const report = typeof input === 'string' || !input || typeof input !== 'object' ? null : input;
  const shape = report ? report.shape : input;
  if (typeof shape !== 'string') return ANCHOR_NONE;
  if (!Object.prototype.hasOwnProperty.call(SHAPE_POSITION, shape)) return ANCHOR_NONE;
  const position = SHAPE_POSITION[shape] || outcomePosition(shape, report);
  if (!position) return ANCHOR_NONE;
  const stuck = stuckShapes();
  // A DEGRADED OWNER THROWS rather than answering ANCHOR_NONE. `none` is what a
  // session with no chain armed legitimately renders, so returning it here made
  // an owner whose `STUCK_SHAPES` export was removed, renamed or emptied
  // indistinguishable from ordinary health — silently disabling the anchor for
  // EVERY shape, including the ones that never use the blocked mark. The hook
  // already classifies a throw from this call as `anchor render` and discloses
  // it on stderr; the rendered outcome is still no anchor.
  if (stuck === null) {
    throw new Error('chain-recovery-v1.js: STUCK_SHAPES unavailable, refusing to guess the anchor');
  }
  const done = position.done;
  const running = position.blocked || stuck.indexOf(shape) >= 0 ? MARK_BLOCKED : MARK_RUNNING;
  const rendered = ANCHOR_PREFIX + ANCHOR_STEPS
    .map(function (step, index) {
      let mark = MARK_PENDING;
      if (index < done) mark = MARK_DONE;
      else if (index === done) mark = running;
      return ' ' + mark + step;
    })
    .join('');
  return anchorTokenSafe(rendered) ? rendered : ANCHOR_NONE;
}

// Is `none` a LEGITIMATE answer for this report, or evidence the module is
// degraded? The hook needs that split to name a fault class, and it derived it
// from `SHAPE_POSITION[shape]` being truthy — which went silent the moment two
// shapes mapped to null while remaining producible through a report: `mapped` was
// true and the entry was null, so the gate never fired at exactly the two shapes
// this feature added. The rule belongs here, with the mapping it is about.
//
// `true` for an inert shape, and for an outcome-dependent shape whose report
// carries no placeable outcome — the ordinary standalone case. `false` for a
// shape with a real position, for an outcome-dependent shape whose outcome IS
// placeable, and for a shape with no row at all, which is the unmapped fault.
function anchorNoneIsExpected(input) {
  const report = typeof input === 'string' || !input || typeof input !== 'object' ? null : input;
  const shape = report ? report.shape : input;
  if (typeof shape !== 'string') return false;
  if (!Object.prototype.hasOwnProperty.call(SHAPE_POSITION, shape)) return false;
  if (SHAPE_POSITION[shape]) return false;
  if (OUTCOME_DEPENDENT_SHAPES.indexOf(shape) < 0) return true;
  return outcomePosition(shape, report) === null;
}

// EVERY token this module can produce, deduped. It
// lives here because a CONSUMER cannot check a producer it does not own: four of
// them derived it as `Object.keys(SHAPE_POSITION).map(anchorToken)`, which was
// complete until the classifier report became a legal first argument and then
// silently omitted both report-only tokens - so a carrier legitimately holding
// one was reported as not producible, and a length ceiling was measured against a
// token that is not the longest. Same reasoning, same precedent, as the owner
// exporting `INERT_SHAPES` rather than letting the doctor keep a copy.
// ANCHOR_NONE IS IN THE SET, deliberately: it is a value `anchorToken` really
// returns and a carrier may legitimately hold, so excluding it made every
// scenario rendering `none` read as carrying a token this module cannot produce.
function producibleTokens() {
  const out = new Set([ANCHOR_NONE]);
  for (const shape of Object.keys(SHAPE_POSITION)) out.add(anchorToken(shape));
  for (const shape of OUTCOME_DEPENDENT_SHAPES) {
    for (const outcome of Object.keys(OUTCOME_POSITION)) {
      out.add(anchorToken({ shape, linkage: 'bound', autopilot: { outcome } }));
    }
  }
  return [...out];
}

module.exports = {
  anchorNoneIsExpected,
  placedOutcomes,
  producibleTokens,
  ANCHOR_NONE,
  ANCHOR_PREFIX,
  ANCHOR_STEPS,
  ANCHOR_TOKEN_RE,
  MARK_BLOCKED,
  MARK_DONE,
  MARK_PENDING,
  MARK_RUNNING,
  SHAPE_POSITION,
  anchorToken,
  anchorTokenSafe,
  stuckShapes,
};
