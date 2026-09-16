'use strict';

// Unit contract for `hooks/lib/review-ticket-claim-v1.js`, the ONE implementation
// of the review-ticket claim predicate. Two `node -e` programs consume it — the
// claim transaction in `hooks/lib/zensu-tdd-phase.sh` and the disclosure arming
// read in `hooks/post-review-tdd-delegate.sh` — and before the extraction each
// carried its own hand-written copy of the conjunct set. The ONE-SIDED pin that
// compared them could not see the dangerous direction: a hook STRICTER than the
// claim answers "no ticket outstanding" for a chain the claim would accept, so
// `decline()` returns at its first guard and every disclosure in that file goes
// silent with the whole test surface green.
//
// Driven from `tests/structure/test-post-review-tdd-scope.sh`, because
// `tests/run-all.sh` discovers only `tests/structure/test-*.sh`.

const test = require('node:test');
const assert = require('node:assert');
const path = require('node:path');

const ROOT = process.env.ZENSU_PLUGIN_ROOT
  || path.resolve(__dirname, '..', '..');
const mod = require(path.join(ROOT, 'hooks', 'lib', 'review-ticket-claim-v1.js'));

const KEY = 'scv1_' + 'a'.repeat(64);
const HASH = 'sha256:' + 'a'.repeat(64);

function doc(over) {
  return Object.assign({
    session_id_hash: HASH,
    phase: 'IMPL',
    history: [],
    bypasses: [],
    active: true,
    vanilla: false,
    implComplete: true,
    chainDone: false,
    codeReviewDone: false,
    selfReviewFixed: false,
    reviewTicket: 'tkt-abc',
    reviewTicketConsumed: false,
    reviewRound: 0,
  }, over || {});
}

test('the module is zero-dependency and host-neutral', () => {
  const src = require('node:fs')
    .readFileSync(path.join(ROOT, 'hooks', 'lib', 'review-ticket-claim-v1.js'), 'utf8');
  assert.equal(/\brequire\s*\(/.test(src), false,
    'the claim predicate must load in any host without pulling a sibling in');
  assert.equal(/\bprocess\.env\b/.test(src), false,
    'every anchor arrives as an argument; the module names no environment variable');
});

test('reviewTicketShapeOk mirrors _tdd_review_ticket_shape_ok', () => {
  assert.equal(mod.reviewTicketShapeOk('a'), true);
  assert.equal(mod.reviewTicketShapeOk('A-z_0'), true);
  assert.equal(mod.reviewTicketShapeOk('x'.repeat(96)), true);
  assert.equal(mod.reviewTicketShapeOk('x'.repeat(97)), false, 'the owner caps at 96');
  assert.equal(mod.reviewTicketShapeOk(''), false, 'the owner refuses an empty ticket');
  assert.equal(mod.reviewTicketShapeOk('has space'), false);
  assert.equal(mod.reviewTicketShapeOk('semi;colon'), false);
  assert.equal(mod.reviewTicketShapeOk(null), false);
  assert.equal(mod.reviewTicketShapeOk(undefined), false);
  assert.equal(mod.reviewTicketShapeOk(123), false, 'a non-string is not a ticket');
});

test('chainLiveForClaim accepts the shape both carriers accepted before the extraction', () => {
  assert.equal(mod.chainLiveForClaim(doc(), KEY), true);
});

test('chainLiveForClaim refuses a foreign or malformed session hash', () => {
  assert.equal(mod.chainLiveForClaim(doc({ session_id_hash: 'sha256:' + 'b'.repeat(64) }), KEY), false);
  assert.equal(mod.chainLiveForClaim(doc({ session_id_hash: '' }), KEY), false);
  assert.equal(mod.chainLiveForClaim(doc(), ''), false, 'an empty session key can never match');
  assert.equal(mod.chainLiveForClaim(doc(), 'not-a-session-key'), false);
});

test('chainLiveForClaim refuses a non-object document', () => {
  assert.equal(mod.chainLiveForClaim(null, KEY), false);
  assert.equal(mod.chainLiveForClaim('a string', KEY), false);
  assert.equal(mod.chainLiveForClaim([], KEY), false, 'an array is not a workflow document');
});

test('chainLiveForClaim enforces every chain-state conjunct', () => {
  // Each of these is a conjunct BOTH carriers applied by hand before the
  // extraction. The set is asserted member by member so a conjunct dropped from
  // the module fails here rather than silently widening who may claim a ticket.
  const refusals = [
    { active: false }, { active: 'true' },
    { implComplete: false }, { implComplete: 'true' },
    { chainDone: true }, { chainDone: 'false' },
    { codeReviewDone: true }, { codeReviewDone: 'false' },
    { vanilla: 'false' }, { vanilla: null },
    { selfReviewFixed: 'false' }, { selfReviewFixed: 0 },
    { phase: 42 }, { phase: null },
    { history: 'not-an-array' }, { history: null },
    { bypasses: 'not-an-array' }, { bypasses: {} },
    { reviewRound: -1 }, { reviewRound: 1.5 }, { reviewRound: '0' },
    { reviewRound: Number.MAX_SAFE_INTEGER },
  ];
  refusals.forEach((over) => {
    assert.equal(mod.chainLiveForClaim(doc(over), KEY), false,
      'expected refusal for ' + JSON.stringify(over));
  });
});

test('chainLiveForClaim does NOT judge the ticket slot', () => {
  // The split is what lets one predicate serve both carriers: the claim adds its
  // own ticket EQUALITY and the hook asks for the outstanding value instead.
  assert.equal(mod.chainLiveForClaim(doc({ reviewTicket: '', reviewTicketConsumed: true }), KEY), true);
});

test('ticketSlotOutstanding is the unclaimed-ticket half', () => {
  assert.equal(mod.ticketSlotOutstanding(doc()), true);
  assert.equal(mod.ticketSlotOutstanding(doc({ reviewTicketConsumed: true })), false);
  assert.equal(mod.ticketSlotOutstanding(doc({ reviewTicketConsumed: 'false' })), false);
  assert.equal(mod.ticketSlotOutstanding(doc({ reviewTicket: '' })), false);
  assert.equal(mod.ticketSlotOutstanding(doc({ reviewTicket: 'has space' })), false);
  assert.equal(mod.ticketSlotOutstanding(doc({ reviewTicket: 'x'.repeat(97) })), false);
  assert.equal(mod.ticketSlotOutstanding(null), false);
});

test('outstandingTicket answers the value or the empty string, never a guess', () => {
  assert.equal(mod.outstandingTicket(doc(), KEY), 'tkt-abc');
  assert.equal(mod.outstandingTicket(doc({ reviewTicketConsumed: true }), KEY), '');
  assert.equal(mod.outstandingTicket(doc({ active: false }), KEY), '',
    'a dead chain holds no outstanding ticket');
  assert.equal(mod.outstandingTicket(doc(), 'scv1_' + 'b'.repeat(64)), '',
    'another session never reads this chain as outstanding');
});

test('claimableWith adds the ticket EQUALITY the claim owns', () => {
  assert.equal(mod.claimableWith(doc(), KEY, 'tkt-abc'), true);
  assert.equal(mod.claimableWith(doc(), KEY, 'tkt-other'), false);
  assert.equal(mod.claimableWith(doc(), KEY, ''), false);
  assert.equal(mod.claimableWith(doc({ reviewTicketConsumed: true }), KEY, 'tkt-abc'), false,
    'a consumed ticket can never be claimed again');
  assert.equal(mod.claimableWith(doc({ active: false }), KEY, 'tkt-abc'), false);
});

test('claimableWith and the hook pair answer the same question about one document', () => {
  // The property the extraction exists for: there is no document the hook reads
  // as "no outstanding ticket" while the claim would accept it, nor the reverse.
  // Before the extraction that agreement was a one-sided source comparison.
  const cases = [doc(), doc({ active: false }), doc({ chainDone: true }),
    doc({ reviewTicketConsumed: true }), doc({ reviewTicket: 'x'.repeat(97) }),
    doc({ codeReviewDone: true }), doc({ reviewRound: 3 })];
  cases.forEach((state) => {
    const armed = mod.chainLiveForClaim(state, KEY) && mod.ticketSlotOutstanding(state);
    const claimable = mod.claimableWith(state, KEY, state.reviewTicket);
    assert.equal(armed, claimable,
      'arming and claiming disagreed about ' + JSON.stringify(state.reviewTicket));
  });
});
