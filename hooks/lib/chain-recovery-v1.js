'use strict';

const AUTOPILOT_LINK_FIELDS = [
  'autopilotRunId',
  'autopilotAttempt',
  'autopilotReturnStage',
  'chainId',
  'chainOutcome',
];

const REARM_MARKER_KEYS = Object.freeze([
  'attempt',
  'chainId',
  'consumedTicketSha256',
  'retire',
  'runId',
  'schemaVersion',
  'status',
].sort());

const RETURN_STAGES = Object.freeze(['GATES', 'CONVERGE', 'FIX_FINDINGS', 'VALIDATE', 'COVER']);
const RECOVERY_HISTORY_PHASE = 'CHAIN_RECOVERED';
const RECOVERY_HISTORY_REASON_PREFIX = 'chain-recovered: ';
const CHAIN_OUTCOMES = ['', 'pass', 'no-changes', 'max-rounds'];
// FROZEN like every other exported shape table. `RECOVERABLE_SHAPES` is exported and feeds
// `recoverable`, the flag that authorizes `--chain-recover`, while `STUCK_SHAPES` spreads it
// at load — so a mutation would move `recoverable` and `blocked` without moving `wedged`.
const RECOVERABLE_SHAPES = Object.freeze(['wedged-stale-rearm']);
const DEAD_END_SHAPES = Object.freeze(['self-review-unbindable']);
const STUCK_SHAPES = Object.freeze([...RECOVERABLE_SHAPES, ...DEAD_END_SHAPES]);
// EVERY literal `chainShape` can return. The subsets above answer "is this shape
// stuck"; nothing answered "is this every shape", so a consumer that needs the
// total set had to use `NEXT_COMMAND`'s key set as a proxy — an invariant this
// module never enforced. Keep in step with `chainShape` below; the sibling suite
// derives the literals from that function's own source and compares them here, so
// a shape added there without a row lands as a red check rather than as a
// consumer silently answering nothing for a real chain.
const ALL_SHAPES = Object.freeze([
  'no-session',
  'implementing',
  'chain-closed',
  'awaiting-self-review',
  'self-review-unbindable',
  'review-in-flight',
  'ticket-unclaimed',
  'ticket-spent',
  'wedged-stale-rearm',
  'ticket-lost',
  'ready-for-review',
]);
// The shapes that carry no work forward. Exported so a consumer never hand-copies
// them; keep in step with the literals `chainShape` returns below. See CLAUDE.md
// §"Chain Shape & Rearm Receipt".
const INERT_SHAPES = Object.freeze(['no-session', 'chain-closed']);

const NEXT_COMMAND = Object.freeze({
  'no-session': 'run /zensu:tdd to arm a chain',
  implementing: 'zensu-log.sh --tdd-complete once the implementation is done',
  'chain-closed': 'none — this chain already reached its terminus',
  'awaiting-self-review':
    '/zensu:self-review (or /zensu:reset-review-limit to grant another auto-fix budget)',
  'self-review-unbindable':
    'run /zensu:tdd for the current task — codeReviewDone is set but no consumed ticket can bind the terminal self-review, and neither /zensu:self-review nor /zensu:reset-review-limit can repair that; a fresh --tdd-begin is the only exit',
  'review-in-flight':
    'zensu-log.sh --code-review-done --claimed-review-ticket <the ticket from --current-review-ticket>',
  'ticket-unclaimed':
    'let the spawned reviewer finish, or issue a fresh ticket with zensu-log.sh --review-ticket and re-spawn zensu:code-reviewer',
  'ticket-spent':
    'zensu-log.sh --review-ticket, then spawn zensu:code-reviewer — the retained ticket is already consumed and cannot be claimed again',
  'ticket-lost':
    'zensu-log.sh --review-ticket, then spawn zensu:code-reviewer — the consumed rounds stand, so the next completion counts against the same budget',
  'ready-for-review': 'zensu-log.sh --review-ticket, then spawn zensu:code-reviewer',
  'wedged-stale-rearm': 'zensu-log.sh --chain-recover',
});

const BLOCKED_RECOVERY_COMMAND = Object.freeze({
  'partial-link':
    'run /zensu:tdd for a fresh generation — the Autopilot linkage is incomplete and cannot be repaired in place',
  'deferred-claim':
    'cancel the outstanding deferred-review claim first; recovery never rewrites a claimed generation',
  'ticket-slot':
    'this document carries an inconsistent review-ticket slot; recovery never rewrites it, because doing so would satisfy the no-ticket review terminus. Start a fresh generation with /zensu:tdd',
  'flag-state':
    'this generation already latched selfReviewFixed, so neither the reviewer chain nor a budget reset applies — start a fresh generation with /zensu:tdd',
  'claim-unknown':
    'this document has no readable deferredReviewClaim field, so recovery cannot prove no deferred-review claim is outstanding; it refuses rather than guess — start a fresh generation with /zensu:tdd',
  'link-shape':
    'this document carries a rearm receipt without a complete Autopilot binding, which no writer in this plugin can produce; recovery only repairs a bound generation, so start a fresh one with /zensu:tdd',
});

const STALE_RECEIPT_CAVEAT =
  ' (note: this chain also carries a rearm receipt that disagrees with its own document, so no FRESH ticket can be issued — finish this generation with what it already holds, or start a fresh one with /zensu:tdd; on a standalone chain a budget reset drops the receipt as a side effect, on a bound one it does not)';

const REQUIRED_BOOLEANS = [
  'active',
  'implComplete',
  'chainDone',
  'codeReviewDone',
  'selfReviewFixed',
  'reviewTicketConsumed',
];

const REQUIRED_STRINGS = ['reviewTicket', 'phase'];
const REQUIRED_ARRAYS = ['history', 'bypasses'];

const hasOwn = (state, field) => Object.prototype.hasOwnProperty.call(state, field);

const naturalOr = (value, fallback) => (
  Number.isSafeInteger(value) && value >= 0 ? value : fallback
);

function normalizeChainState(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    throw new Error('chain state must be an object');
  }
  for (const field of REQUIRED_BOOLEANS.concat(['vanilla'])) {
    if (typeof input[field] !== 'boolean') {
      throw new Error(`chain state field ${field} must be a boolean`);
    }
  }
  for (const field of REQUIRED_STRINGS) {
    if (typeof input[field] !== 'string') {
      throw new Error(`chain state field ${field} must be a string`);
    }
  }
  for (const field of REQUIRED_ARRAYS) {
    if (!Array.isArray(input[field])) {
      throw new Error(`chain state field ${field} must be an array`);
    }
  }
  if (!Number.isSafeInteger(input.reviewRound) || input.reviewRound < 0) {
    throw new Error('chain state field reviewRound must be a natural number');
  }
  const normalized = { ...input };
  normalized.deferredReviewClaimKnown = typeof input.deferredReviewClaim === 'string';
  normalized.deferredReviewClaim = normalized.deferredReviewClaimKnown
    ? input.deferredReviewClaim
    : '';
  normalized.stopBlockCount = naturalOr(input.stopBlockCount, 0);
  normalized.implStopCount = naturalOr(input.implStopCount, 0);
  return normalized;
}

function isLinkId(value) {
  return typeof value === 'string'
    && value.length > 0
    && value.length <= 128
    && /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/.test(value);
}

function autopilotLinkage(state) {
  const present = AUTOPILOT_LINK_FIELDS.filter((field) => hasOwn(state, field));
  if (present.length === 0) return { linkage: 'standalone', autopilot: null };
  const complete = present.length === AUTOPILOT_LINK_FIELDS.length
    && isLinkId(state.autopilotRunId)
    && Number.isInteger(state.autopilotAttempt)
    && state.autopilotAttempt >= 1
    && state.autopilotAttempt <= 999
    && RETURN_STAGES.includes(state.autopilotReturnStage)
    && isLinkId(state.chainId)
    && CHAIN_OUTCOMES.includes(state.chainOutcome);
  if (!complete) return { linkage: 'partial', autopilot: null };
  return {
    linkage: 'bound',
    autopilot: {
      runId: state.autopilotRunId,
      attempt: state.autopilotAttempt,
      returnStage: state.autopilotReturnStage,
      chainId: state.chainId,
      outcome: state.chainOutcome,
    },
  };
}

function rearmReceiptVerdict(input) {
  const state = input && typeof input === 'object' && !Array.isArray(input) ? input : {};
  if (!hasOwn(state, 'reviewRearm')) return 'none';
  const marker = state.reviewRearm;
  const bound = marker
    && typeof marker === 'object'
    && !Array.isArray(marker)
    && Object.keys(marker).sort().join(',') === REARM_MARKER_KEYS.join(',')
    && marker.schemaVersion === 1
    && marker.status === 'pending'
    && typeof marker.runId === 'string'
    && marker.runId === state.autopilotRunId
    && marker.attempt === state.autopilotAttempt
    && typeof marker.chainId === 'string'
    && marker.chainId === state.chainId
    && typeof marker.consumedTicketSha256 === 'string'
    && /^[a-f0-9]{64}$/.test(marker.consumedTicketSha256)
    && marker.retire === false;
  return bound ? 'valid' : 'stale';
}

function isTicketShaped(value) {
  return typeof value === 'string'
    && value.length > 0
    && value.length <= 96
    && /^[A-Za-z0-9_-]+$/.test(value);
}

function selfReviewTicketBindable(state) {
  const alreadyBound = isTicketShaped(state.reviewTicket)
    && state.reviewTicketConsumed === true
    && state.reviewRound >= 1;
  const mintable = state.reviewTicket === ''
    && state.reviewTicketConsumed === true
    && state.reviewRound === 0;
  return alreadyBound || mintable;
}

function chainShape(state, rearmReceipt) {
  if (state.active !== true) return 'no-session';
  if (state.implComplete !== true) return 'implementing';
  if (state.chainDone === true) return 'chain-closed';
  if (state.codeReviewDone === true) {
    return selfReviewTicketBindable(state) ? 'awaiting-self-review' : 'self-review-unbindable';
  }
  const ticketPresent = state.reviewTicket !== '';
  if (ticketPresent && state.reviewTicketConsumed === true && state.reviewRound >= 1) {
    return 'review-in-flight';
  }
  if (ticketPresent && state.reviewTicketConsumed === false) return 'ticket-unclaimed';
  if (ticketPresent) return rearmReceipt === 'stale' ? 'wedged-stale-rearm' : 'ticket-spent';
  if (rearmReceipt === 'stale') return 'wedged-stale-rearm';
  if (state.reviewRound >= 1) return 'ticket-lost';
  return 'ready-for-review';
}

const STALE_RECEIPT_CAVEAT_SHAPES = ['ticket-unclaimed', 'awaiting-self-review'];

// The one branch below that interpolates state into a command string, and the reason it
// needs no quoting is a PRECONDITION rather than a property of this function: it is
// reachable only under `linkage === 'bound'`, which `autopilotLinkage` grants only when
// both ids pass `isLinkId` (no whitespace, no shell metacharacter) and the attempt is an
// integer in 1..999. Consumers relay `nextCommand` verbatim — the doctor's chain rows
// print it as a remedy to run — so WIDENING `isLinkId` is what would open that channel,
// and the widening and this interpolation must be re-decided together. Noted here rather
// than only at a consumer, because a consumer cannot check a producer it does not own.
function shapeCommand(shape, linkage, autopilot, rearmReceipt) {
  if (STALE_RECEIPT_CAVEAT_SHAPES.indexOf(shape) >= 0 && rearmReceipt === 'stale') {
    return NEXT_COMMAND[shape] + STALE_RECEIPT_CAVEAT;
  }
  if (shape !== 'implementing' || linkage !== 'bound' || !autopilot) return NEXT_COMMAND[shape];
  return `zensu-log.sh --tdd-complete --autopilot-run ${autopilot.runId}`
    + ` --autopilot-attempt ${autopilot.attempt} --chain-id ${autopilot.chainId}`;
}

function blockedRecoveryReason(state, linkage) {
  if (linkage === 'partial') return 'partial-link';
  if (linkage !== 'bound') return 'link-shape';
  if (!state.deferredReviewClaimKnown) return 'claim-unknown';
  if (state.deferredReviewClaim !== '') return 'deferred-claim';
  if (state.reviewTicketConsumed !== true) return 'ticket-slot';
  return 'flag-state';
}

function classifyChain(input) {
  const state = normalizeChainState(input);
  const { linkage, autopilot } = autopilotLinkage(state);
  const rearmReceipt = rearmReceiptVerdict(state);
  const shape = chainShape(state, rearmReceipt);
  const wedged = STUCK_SHAPES.includes(shape);
  const recoverable = RECOVERABLE_SHAPES.includes(shape)
    && linkage === 'bound'
    && state.deferredReviewClaimKnown
    && state.deferredReviewClaim === ''
    && state.active === true
    && state.implComplete === true
    && state.chainDone === false
    && state.codeReviewDone === false
    && state.selfReviewFixed === false
    && state.reviewTicketConsumed === true;

  const blocked = RECOVERABLE_SHAPES.includes(shape) && !recoverable;
  const nextCommandId = blocked ? blockedRecoveryReason(state, linkage) : shape;
  const nextCommand = blocked
    ? BLOCKED_RECOVERY_COMMAND[nextCommandId]
    : shapeCommand(shape, linkage, autopilot, rearmReceipt);

  return {
    shape,
    wedged,
    deadEnd: DEAD_END_SHAPES.includes(shape),
    recoverable,
    nextCommandId,
    nextCommand,
    linkage,
    autopilot,
    rearmReceipt,
    active: state.active,
    vanilla: state.vanilla,
    implComplete: state.implComplete,
    chainDone: state.chainDone,
    codeReviewDone: state.codeReviewDone,
    selfReviewFixed: state.selfReviewFixed,
    deferredReviewClaim: state.deferredReviewClaimKnown
      ? (state.deferredReviewClaim === '' ? 'none' : 'present')
      : 'unknown',
    reviewTicketPresent: state.reviewTicket !== '',
    reviewTicketConsumed: state.reviewTicketConsumed,
    claimedReviewTicketPresent: state.reviewTicket !== ''
      && state.reviewTicketConsumed === true
      && state.reviewRound >= 1,
    reviewRound: state.reviewRound,
    stopBlockCount: state.stopBlockCount,
    implStopCount: state.implStopCount,
    revision: Number.isSafeInteger(state.revision) ? state.revision : null,
    lastEvent: typeof state.last_event === 'string' ? state.last_event : null,
    recoveries: countRecoveries(state),
  };
}

function countRecoveries(state) {
  if (!Array.isArray(state.history)) return 0;
  return state.history.filter((entry) => (
    entry
    && typeof entry === 'object'
    && entry.phase === RECOVERY_HISTORY_PHASE
    && typeof entry.reason === 'string'
    && entry.reason.startsWith(RECOVERY_HISTORY_REASON_PREFIX)
  )).length;
}

module.exports = {
  ALL_SHAPES,
  BLOCKED_RECOVERY_COMMAND,
  DEAD_END_SHAPES,
  INERT_SHAPES,
  NEXT_COMMAND,
  REARM_MARKER_KEYS,
  RECOVERABLE_SHAPES,
  RECOVERY_HISTORY_PHASE,
  RECOVERY_HISTORY_REASON_PREFIX,
  RETURN_STAGES,
  autopilotLinkage,
  chainShape,
  classifyChain,
  isLinkId,
  normalizeChainState,
  rearmReceiptVerdict,
};
