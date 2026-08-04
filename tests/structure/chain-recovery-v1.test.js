'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');

const chain = require(path.join(__dirname, '..', '..', 'hooks', 'lib', 'chain-recovery-v1.js'));

const RECEIPT = {
  schemaVersion: 1,
  status: 'pending',
  runId: 'run-1',
  attempt: 2,
  chainId: 'chain-1',
  consumedTicketSha256: 'a'.repeat(64),
  retire: false,
};

const DISAGREEING = Object.freeze({ ...{
  schemaVersion: 1,
  status: 'pending',
  runId: 'run-other',
  attempt: 2,
  chainId: 'chain-1',
  consumedTicketSha256: 'a'.repeat(64),
  retire: false,
} });

const BOUND_LINK = {
  autopilotRunId: 'run-1',
  autopilotAttempt: 2,
  autopilotReturnStage: 'GATES',
  chainId: 'chain-1',
  chainOutcome: '',
};

function doc(overrides) {
  return Object.assign({
    active: true,
    vanilla: true,
    implComplete: true,
    chainDone: false,
    codeReviewDone: false,
    selfReviewFixed: false,
    reviewTicket: '',
    reviewTicketConsumed: true,
    reviewRound: 0,
    stopBlockCount: 0,
    deferredReviewClaim: '',
    phase: 'UNINITIALIZED',
    step_id: '',
    history: [],
    bypasses: [],
  }, overrides);
}

test('a document missing a safety field is rejected, never defaulted', () => {
  for (const field of [
    'active', 'implComplete', 'chainDone', 'codeReviewDone', 'selfReviewFixed',
    'reviewTicketConsumed', 'reviewTicket', 'reviewRound', 'vanilla', 'phase',
    'history', 'bypasses',
  ]) {
    const sparse = doc({});
    delete sparse[field];
    assert.throws(() => chain.classifyChain(sparse), new RegExp(field), `missing ${field}`);
  }
});

test('non-object input is rejected', () => {
  for (const value of [null, undefined, 'x', 7, []]) {
    assert.throws(() => chain.classifyChain(value));
  }
});

test('an absent deferred-review claim is readable but never reads as "no claim"', () => {
  const sparse = doc({});
  delete sparse.stopBlockCount;
  delete sparse.deferredReviewClaim;
  const report = chain.classifyChain(sparse);
  assert.equal(report.stopBlockCount, 0);
  assert.equal(report.shape, 'ready-for-review');
  assert.equal(report.deferredReviewClaim, 'unknown');

  const wedged = doc(Object.assign({ reviewRearm: DISAGREEING }, BOUND_LINK));
  delete wedged.deferredReviewClaim;
  const blocked = chain.classifyChain(wedged);
  assert.equal(blocked.recoverable, false);
  assert.equal(blocked.nextCommandId, 'claim-unknown');
  assert.match(blocked.nextCommand, /cannot prove no deferred-review claim/);
});

test('the shape lattice ranks live capabilities above the wedge', () => {
  const cases = [
    [doc({ active: false }), 'no-session'],
    [doc({ implComplete: false }), 'implementing'],
    [doc({ chainDone: true }), 'chain-closed'],
    [doc({ codeReviewDone: true }), 'awaiting-self-review'],
    [doc({ reviewTicket: 'rt_1', reviewTicketConsumed: true, reviewRound: 1 }), 'review-in-flight'],
    [doc({ reviewTicket: 'rt_1', reviewTicketConsumed: false }), 'ticket-unclaimed'],
    [doc({ reviewTicket: 'rt_1', reviewTicketConsumed: false, reviewRearm: RECEIPT }), 'ticket-unclaimed'],
    [doc({ reviewTicket: 'rt_1', reviewTicketConsumed: true, reviewRound: 0 }), 'ticket-spent'],
    [doc({ reviewRearm: RECEIPT }), 'wedged-stale-rearm'],
    [doc({ reviewRound: 2 }), 'ticket-lost'],
    [doc({}), 'ready-for-review'],
  ];
  for (const [state, expected] of cases) {
    const report = chain.classifyChain(state);
    assert.equal(report.shape, expected, JSON.stringify(expected));
    assert.equal(typeof report.nextCommand, 'string', `${expected} nextCommand`);
    assert.ok(report.nextCommand.length > 0, `${expected} nextCommand is empty`);
    assert.equal(typeof report.nextCommandId, 'string');
  }
});

test('an inconsistent ticket slot is refused, because normalizing it would satisfy the no-ticket review terminus', () => {
  const report = chain.classifyChain(
    doc(Object.assign({ reviewTicketConsumed: false, reviewRearm: DISAGREEING }, BOUND_LINK)),
  );
  assert.equal(report.shape, 'wedged-stale-rearm');
  assert.equal(report.recoverable, false);
  assert.equal(report.nextCommandId, 'ticket-slot');
});

test('an unclaimed ticket alongside a stale receipt warns that a fresh ticket will refuse', () => {
  const report = chain.classifyChain(
    doc({ reviewTicket: 'rt_1', reviewTicketConsumed: false, reviewRearm: RECEIPT }),
  );
  assert.equal(report.shape, 'ticket-unclaimed');
  assert.match(report.nextCommand, /rearm receipt that disagrees/);
});

test('a complete but invalid Autopilot link reads as partial, never as bound', () => {
  const deviations = [
    { autopilotAttempt: 0 },
    { autopilotAttempt: 1000 },
    { autopilotReturnStage: 'NOPE' },
    { autopilotRunId: 'x'.repeat(129) },
    { autopilotRunId: 'has space' },
    { chainOutcome: 'bogus' },
  ];
  const disagreeing = Object.assign({}, RECEIPT, { runId: 'run-other' });
  for (const deviation of deviations) {
    const state = doc(Object.assign({ reviewRearm: disagreeing }, BOUND_LINK, deviation));
    const report = chain.classifyChain(state);
    assert.equal(report.linkage, 'partial', JSON.stringify(deviation));
    assert.equal(report.wedged, true, JSON.stringify(deviation));
    assert.equal(report.recoverable, false, JSON.stringify(deviation));
    assert.equal(report.nextCommandId, 'partial-link', JSON.stringify(deviation));
  }
});

test('the receipt key list is the exact shared schema, sorted and frozen', () => {
  assert.deepEqual([...chain.REARM_MARKER_KEYS], [
    'attempt',
    'chainId',
    'consumedTicketSha256',
    'retire',
    'runId',
    'schemaVersion',
    'status',
  ]);
  assert.equal(Object.isFrozen(chain.REARM_MARKER_KEYS), true);
  assert.equal(Object.isFrozen(chain.RETURN_STAGES), true);
  assert.deepEqual([...chain.RETURN_STAGES], ['GATES', 'CONVERGE', 'FIX_FINDINGS', 'VALIDATE', 'COVER']);
});

test('codeReviewDone with an unbindable self-review ticket gets its own shape and remedy', () => {
  const bindable = chain.classifyChain(doc({
    codeReviewDone: true, reviewTicket: 'rt_1', reviewTicketConsumed: true, reviewRound: 1,
  }));
  assert.equal(bindable.shape, 'awaiting-self-review');

  const legacy = chain.classifyChain(doc({ codeReviewDone: true }));
  assert.equal(legacy.shape, 'awaiting-self-review');

  const unbindable = chain.classifyChain(doc({ codeReviewDone: true, reviewRound: 2 }));
  assert.equal(unbindable.shape, 'self-review-unbindable');
  assert.match(unbindable.nextCommand, /\/zensu:tdd/);
  assert.match(unbindable.nextCommand, /can repair that/);
  assert.notEqual(unbindable.nextCommand, chain.NEXT_COMMAND['awaiting-self-review']);
});

test('a retained consumed ticket plus a disagreeing receipt is wedged AND recoverable', () => {
  const spent = doc({ reviewTicket: 'rt_1', reviewTicketConsumed: true, reviewRound: 0 });
  assert.equal(chain.classifyChain(spent).shape, 'ticket-spent');
  assert.equal(chain.classifyChain(spent).wedged, false);

  const spentWedged = chain.classifyChain(
    Object.assign({}, spent, BOUND_LINK, { reviewRearm: DISAGREEING }),
  );
  assert.equal(spentWedged.shape, 'wedged-stale-rearm');
  assert.equal(spentWedged.recoverable, true);
});

test('the recovery counter ignores a history entry a caller could forge with --phase', () => {
  const forged = chain.classifyChain(doc({
    history: [{ step: 'x', phase: chain.RECOVERY_HISTORY_PHASE }],
  }));
  assert.equal(forged.recoveries, 0);
});

test('the report counts durable recovery history entries', () => {
  const repaired = chain.classifyChain(doc({
    history: [
      { step: '', phase: 'IMPL' },
      { step: '', phase: chain.RECOVERY_HISTORY_PHASE, reason: 'chain-recovered: x' },
      { step: '', phase: 'GREEN_PASS' },
      { step: '', phase: chain.RECOVERY_HISTORY_PHASE, reason: 'chain-recovered: y' },
    ],
  }));
  assert.equal(repaired.recoveries, 2);
  assert.equal(chain.classifyChain(doc({})).recoveries, 0);
});

test('the report exposes the revision and last event so a repair is verifiable', () => {
  const report = chain.classifyChain(doc({ revision: 7, last_event: 'chain-recovered' }));
  assert.equal(report.revision, 7);
  assert.equal(report.lastEvent, 'chain-recovered');
  const bare = chain.classifyChain(doc({}));
  assert.equal(bare.revision, null);
  assert.equal(bare.lastEvent, null);
});

test('a receipt that agrees with its own bound document is not stale', () => {
  const bound = doc(Object.assign({ reviewRearm: RECEIPT }, BOUND_LINK));
  assert.equal(chain.rearmReceiptVerdict(bound), 'valid');
  assert.equal(chain.classifyChain(bound).shape, 'ready-for-review');
});

test('every receipt deviation is stale, so the issuer fails closed', () => {
  const deviations = [
    { retire: true },
    { status: 'done' },
    { schemaVersion: 2 },
    { attempt: 3 },
    { chainId: 'chain-other' },
    { runId: 'run-other' },
    { consumedTicketSha256: 'z'.repeat(64) },
  ];
  for (const deviation of deviations) {
    const state = doc(Object.assign({}, BOUND_LINK, {
      reviewRearm: Object.assign({}, RECEIPT, deviation),
    }));
    assert.equal(chain.rearmReceiptVerdict(state), 'stale', JSON.stringify(deviation));
  }
  const extraKey = doc(Object.assign({}, BOUND_LINK, {
    reviewRearm: Object.assign({ extra: 1 }, RECEIPT),
  }));
  assert.equal(chain.rearmReceiptVerdict(extraKey), 'stale');
  assert.equal(chain.rearmReceiptVerdict(doc({})), 'none');
});

test('a standalone document carrying a receipt is refused as corrupt input, never repaired', () => {
  const standalone = chain.classifyChain(doc({ reviewRearm: RECEIPT }));
  assert.equal(standalone.shape, 'wedged-stale-rearm');
  assert.equal(standalone.linkage, 'standalone');
  assert.equal(standalone.wedged, true);
  assert.equal(standalone.recoverable, false);
  assert.equal(standalone.nextCommandId, 'link-shape');
  assert.match(standalone.nextCommand, /no writer in this plugin can produce/);
});

test('wedged means cannot-advance, so a dead end reports it too and keeps its own remedy', () => {
  const deadEnd = chain.classifyChain(doc({ codeReviewDone: true, reviewRound: 2 }));
  assert.equal(deadEnd.shape, 'self-review-unbindable');
  assert.equal(deadEnd.wedged, true);
  assert.equal(deadEnd.deadEnd, true);
  assert.equal(deadEnd.recoverable, false);
  assert.equal(deadEnd.nextCommandId, 'self-review-unbindable');
  assert.equal(deadEnd.nextCommand, chain.NEXT_COMMAND['self-review-unbindable']);

  const healthy = chain.classifyChain(doc({}));
  assert.equal(healthy.wedged, false);
  assert.equal(healthy.deadEnd, false);
});

test('recovery is blocked by linkage, claim and flag state, each with its own reason', () => {
  const partial = doc({ chainId: 'chain-1', reviewRearm: RECEIPT });
  assert.equal(chain.classifyChain(partial).linkage, 'partial');
  assert.equal(chain.classifyChain(partial).recoverable, false);
  assert.equal(chain.classifyChain(partial).nextCommandId, 'partial-link');

  const claimed = doc(Object.assign({ deferredReviewClaim: 'dc_1', reviewRearm: DISAGREEING }, BOUND_LINK));
  assert.equal(chain.classifyChain(claimed).recoverable, false);
  assert.equal(chain.classifyChain(claimed).nextCommandId, 'deferred-claim');

  const latched = doc(Object.assign({ selfReviewFixed: true, reviewRearm: DISAGREEING }, BOUND_LINK));
  assert.equal(chain.classifyChain(latched).recoverable, false);
  assert.equal(chain.classifyChain(latched).nextCommandId, 'flag-state');

  const bound = doc(Object.assign({}, BOUND_LINK, {
    reviewRearm: Object.assign({}, RECEIPT, { runId: 'run-other' }),
  }));
  assert.equal(chain.classifyChain(bound).linkage, 'bound');
  assert.equal(chain.classifyChain(bound).recoverable, true);
});

test('the report never carries the ticket value and never omits a shape command', () => {
  const inFlight = chain.classifyChain(
    doc({ reviewTicket: 'rt_secret', reviewTicketConsumed: true, reviewRound: 1 }),
  );
  assert.equal(JSON.stringify(inFlight).includes('rt_secret'), false);
  assert.equal(inFlight.claimedReviewTicketPresent, true);
  assert.equal(inFlight.reviewTicketPresent, true);

  for (const shape of Object.keys(chain.NEXT_COMMAND)) {
    assert.ok(chain.NEXT_COMMAND[shape].length > 0, shape);
  }
  for (const reason of Object.keys(chain.BLOCKED_RECOVERY_COMMAND)) {
    assert.ok(chain.BLOCKED_RECOVERY_COMMAND[reason].length > 0, reason);
  }
});

test('a bound implementing chain is told the bound completion form', () => {
  const report = chain.classifyChain(doc(Object.assign({ implComplete: false }, BOUND_LINK)));
  assert.equal(report.shape, 'implementing');
  assert.match(report.nextCommand, /--autopilot-run run-1/);
  assert.match(report.nextCommand, /--autopilot-attempt 2/);
  assert.match(report.nextCommand, /--chain-id chain-1/);

  const standalone = chain.classifyChain(doc({ implComplete: false }));
  assert.equal(standalone.nextCommand, chain.NEXT_COMMAND.implementing);
});

test('classifyChain never mutates the document it is handed', () => {
  const state = doc({ reviewRearm: RECEIPT });
  const before = JSON.stringify(state);
  chain.classifyChain(state);
  assert.equal(JSON.stringify(state), before);
});
