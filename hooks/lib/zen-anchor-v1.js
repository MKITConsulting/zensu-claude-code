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
// READ from its `RECOVERABLE_SHAPES` / `DEAD_END_SHAPES` rather than restated.
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
  // KNOWN RESIDUAL, and it is the SAME class the `chain-closed` entry below was
  // rewritten to remove — stated here rather than left for the next reader to
  // rediscover. Both shapes are reached from `codeReviewDone === true`, and that
  // flag does not mean the review PASSED: `zensu-tdd-phase.sh`'s bound max-round
  // handoff states its own postcondition as "outcome=max-rounds +
  // codeReviewDone=true while chainDone stays false". So a chain whose review
  // exhausted its budget without converging still renders `✓review`, which the
  // directive publishes as "finished and passed".
  //
  // It is NOT fixed here because every in-vocabulary answer is worse or larger.
  // `done: 1` would render `▶review` for a review that is over — the opposite
  // false claim. The honest mark is `✗`, which this module already renders for a
  // stuck shape, but "stuck" is decided by the owner's shape sets and neither of
  // these is in them. The real fix is an OUTCOME signal: `chainOutcome` is a
  // workflow-state key (`'' | 'pass' | 'no-changes' | 'max-rounds'`) that
  // `classifyChain` does not put on its report. Surfacing it there — additively —
  // and rendering `✗review` for `max-rounds` closes the class for good. That is a
  // change to the classifier's report shape and belongs in its own commit.
  'awaiting-self-review': Object.freeze({ done: 2 }),
  'self-review-unbindable': Object.freeze({ done: 2 }),
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
// passed" — was a claim this module had no evidence for. The classifier does not
// expose one: `chainOutcome` (`'' | 'pass' | 'no-changes' | 'max-rounds'`) is a
// workflow-state key that `classifyChain` does not put on its report.
//
// Mapping `chain-closed` to `null` removed the only consumer, so the derivation,
// its `unreviewedDone` rung and the `options.reviewed` parameter all went with
// it. Do NOT reintroduce a "reviewed" input without a real outcome signal: the
// cheap-looking spelling is the one that shipped the false claim.

// Read from the owner, never restated here. A shape the classifier calls stuck
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
  const recoverable = source.RECOVERABLE_SHAPES;
  const deadEnd = source.DEAD_END_SHAPES;
  if (!Array.isArray(recoverable) || !recoverable.length) return null;
  if (!Array.isArray(deadEnd) || !deadEnd.length) return null;
  return recoverable.concat(deadEnd);
}

// shape -> the anchor line the model renders verbatim, or ANCHOR_NONE.
// An unknown shape, a non-string, and BOTH inert shapes — `no-session` and
// `chain-closed` — answer ANCHOR_NONE. That is the fail-open direction: a
// missing anchor costs a line of presentation, while a wrong one misreports
// where the session stands.
//
// It takes NO options. The signature was `(shape, options)` while `chain-closed`
// still rendered; every position now follows from the shape alone, so a caller
// has nothing left to supply and cannot influence what a shape renders.
function anchorToken(shape) {
  if (typeof shape !== 'string') return ANCHOR_NONE;
  if (!Object.prototype.hasOwnProperty.call(SHAPE_POSITION, shape)) return ANCHOR_NONE;
  const position = SHAPE_POSITION[shape];
  if (!position) return ANCHOR_NONE;
  const stuck = stuckShapes();
  if (stuck === null) return ANCHOR_NONE;
  const done = position.done;
  const running = stuck.indexOf(shape) >= 0 ? MARK_BLOCKED : MARK_RUNNING;
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

module.exports = {
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
