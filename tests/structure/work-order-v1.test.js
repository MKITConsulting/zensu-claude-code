'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const MODULE = path.join(__dirname, '..', '..', 'hooks', 'lib', 'work-order-v1.js');
const FAKE = path.join(__dirname, 'lib-fake-zensu-work.js');
const wo = require(MODULE);

const ORDER = '22222222-2222-4222-8222-222222222222';
const CLIENT_SESSION = 'wo-session-0001';
const TOKEN = 'zst_fake_session_token';

function sandbox() {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'wo-unit-')));
  const bin = path.join(root, 'bin');
  const project = path.join(root, 'project');
  fs.mkdirSync(bin);
  fs.mkdirSync(project);
  fs.writeFileSync(path.join(bin, 'zensu'), `#!/bin/bash\nexec node ${JSON.stringify(FAKE)} "$@"\n`, { mode: 0o755 });
  const stateFile = path.join(root, 'fake-state.json');
  const callsFile = path.join(root, 'calls.jsonl');
  const env = {
    ...process.env,
    PATH: `${bin}${path.delimiter}${process.env.PATH}`,
    FAKE_ZENSU_STATE: stateFile,
    FAKE_ZENSU_CALLS: callsFile,
    ZENSU_SESSION_TOKEN: TOKEN,
    ZENSU_WORK_ORDER_RETRY_MS: '1',
    ZENSU_WORK_ORDER_RETRY_BUDGET_MS: '50',
  };
  const seed = (overrides = {}) => {
    const state = {
      token: TOKEN,
      printCodes: true,
      mode: 'live',
      now: null,
      staleAttempt: false,
      runtimeCap: false,
      gateRefusal: null,
      confirmWindowSeconds: 120,
      failNext: [],
      approvals: [],
      events: [],
      historyEvents: [],
      questions: [],
      followups: [],
      policy: { plan_approval: 'auto', lease_minutes: 30, max_questions_per_order: 5, max_order_runtime_minutes: 240 },
      plan: { base_branch: 'main', integration_branch: 'integration/widgets' },
      order: {
        id: ORDER,
        work_plan_id: '11111111-1111-4111-8111-111111111111',
        repository: 'https://github.com/acme/widgets',
        kind: 'implement',
        status: 'claimed',
        attempt: 1,
        client_session_id: CLIENT_SESSION,
        claim_confirmed_at: new Date().toISOString(),
        lease_expires_at: Date.now() + 1800000,
        spec_hash: 'a'.repeat(64),
        branch: null,
        pr_url: null,
        pr_number: null,
        head_sha: null,
        autopilot_run_id: null,
      },
    };
    const merged = { ...state, ...overrides, order: { ...state.order, ...(overrides.order || {}) } };
    fs.writeFileSync(stateFile, JSON.stringify(merged, null, 2));
  };
  const fake = () => JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  const mutate = (fn) => {
    const state = fake();
    fn(state);
    fs.writeFileSync(stateFile, JSON.stringify(state, null, 2));
  };
  const calls = () => (fs.existsSync(callsFile)
    ? fs.readFileSync(callsFile, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line).argv)
    : []);
  const sessionKey = wo.sessionKeyOf(CLIENT_SESSION);
  return { root, project, env, seed, fake, mutate, calls, sessionKey };
}

test('classifyFailure maps the CLI error grammar onto verdicts', () => {
  const v = wo.VERDICTS;
  assert.equal(wo.classifyFailure({ exitCode: 0 }).verdict, v.OK);
  assert.equal(wo.classifyFailure({ exitCode: 1, status: 409, code: 'stale_attempt' }).verdict, v.LOST);
  assert.equal(wo.classifyFailure({ exitCode: 1, status: 409, code: 'runtime_cap' }).verdict, v.LOST);
  assert.equal(wo.classifyFailure({ exitCode: 1, status: 401, code: null }).verdict, v.LOST);
  assert.equal(wo.classifyFailure({ exitCode: 1, status: 401, code: 'invalid_session_token' }).verdict, v.LOST);
  assert.equal(wo.classifyFailure({ exitCode: 1, status: 403, code: 'session_order_mismatch' }).verdict, v.LOST);
  assert.equal(wo.classifyFailure({ exitCode: 1, status: 403, code: 'event_actor_not_allowed' }).verdict, v.FINAL);
  assert.equal(wo.classifyFailure({ exitCode: 1, status: 403, code: null }).verdict, v.LOST);
  assert.equal(wo.classifyFailure({ exitCode: 1, status: 404, code: 'work_orders_disabled' }).verdict, v.LOST);
  assert.equal(wo.classifyFailure({ exitCode: 1, status: 409, code: 'claim_not_confirmed' }).verdict, v.RETRY);
  assert.equal(wo.classifyFailure({ exitCode: 1, status: 409, code: 'event_in_flight' }).verdict, v.RETRY);
  assert.equal(wo.classifyFailure({ exitCode: 1, status: 503, code: 'draining' }).verdict, v.RETRY);
  assert.equal(wo.classifyFailure({ exitCode: 1, status: 409, code: 'invalid_transition' }).verdict, v.FINAL);
  assert.equal(wo.classifyFailure({ exitCode: 1, status: 409, code: 'plan_approval_required' }).verdict, v.FINAL);
  assert.equal(wo.classifyFailure({ exitCode: 1, status: 422, code: 'pr_required' }).verdict, v.FINAL);
  assert.equal(wo.classifyFailure({ exitCode: 1, status: 409, code: null }).verdict, v.AMBIGUOUS);
  assert.equal(wo.classifyFailure({ exitCode: 1, status: 500, code: null }).verdict, v.TRANSIENT);
  assert.equal(wo.classifyFailure({ exitCode: 1, status: 429, code: 'rate_limited' }).verdict, v.TRANSIENT);
  assert.equal(wo.classifyFailure({ exitCode: null, status: null, code: null }).verdict, v.TRANSIENT);
});

test('cliOutcome reads the status and the optional code from the last error line', () => {
  const coded = wo.cliOutcome({ status: 1, stdout: '', stderr: 'notice: update available\nerror: the order is held by another attempt (status 409, code stale_attempt)\n' });
  assert.equal(coded.status, 409);
  assert.equal(coded.code, 'stale_attempt');
  const bare = wo.cliOutcome({ status: 1, stdout: '', stderr: 'error: session token expired or revoked (status 401)\n' });
  assert.equal(bare.status, 401);
  assert.equal(bare.code, null);
  const usage = wo.cliOutcome({ status: 1, stdout: '', stderr: 'error: --category and --question are required\n' });
  assert.equal(usage.status, null);
  const missing = wo.cliOutcome({ error: Object.assign(new Error('spawn zensu ENOENT'), { code: 'ENOENT' }) });
  assert.equal(missing.missing, true);
  assert.equal(missing.status, null);
  const ok = wo.cliOutcome({ status: 0, stdout: '{}', stderr: 'error: (status 409, code stale_attempt)' });
  assert.equal(ok.status, null);
  const raw = wo.cliOutcome({ status: 1, stdout: '', stderr: 'error: request failed (status 502, code bad_gateway): <html>(status 200)</html>\n' });
  assert.equal(raw.status, 502);
  assert.equal(raw.code, 'bad_gateway');
  const rawBare = wo.cliOutcome({ status: 1, stdout: '', stderr: 'error: request failed (status 500): upstream (status 409, code stale_attempt)\n' });
  assert.equal(rawBare.status, 500);
  assert.equal(rawBare.code, null);
});

test('cliOutcome prefers the JSON error line the CLI writes under --json', () => {
  const both = wo.cliOutcome({
    status: 1,
    stdout: '',
    stderr: 'error: the session reached max_order_runtime_minutes (status 409, code runtime_cap)\n{"error":{"status":409,"code":"runtime_cap","message":"the session reached max_order_runtime_minutes"}}\n',
  });
  assert.equal(both.status, 409);
  assert.equal(both.code, 'runtime_cap');
  assert.match(both.message, /max_order_runtime_minutes/);
  const messageOnly = wo.cliOutcome({ status: 1, stdout: '', stderr: 'error: dial tcp: connection refused\n{"error":{"message":"dial tcp: connection refused"}}\n' });
  assert.equal(messageOnly.status, null);
  assert.equal(messageOnly.code, null);
  const badCode = wo.cliOutcome({ status: 1, stdout: '', stderr: '{"error":{"status":409,"code":"Stale-Attempt","message":"x"}}\n' });
  assert.equal(badCode.status, 409);
  assert.equal(badCode.code, null);
  const brokenJson = wo.cliOutcome({ status: 1, stdout: '', stderr: 'error: lost (status 409, code stale_attempt)\n{"error":\n' });
  assert.equal(brokenJson.code, 'stale_attempt');
});

test('the fake speaks every CLI error form the harness parses', () => {
  for (const [format, expectedCode] of [['json', 'stale_attempt'], ['line', 'stale_attempt'], ['bare', null]]) {
    const box = sandbox();
    box.seed({ errorFormat: format, staleAttempt: true });
    const outcome = wo.runZensu(['work', 'heartbeat', ORDER, '--json'], { env: box.env });
    assert.equal(outcome.exitCode, 1, format);
    assert.equal(outcome.status, 409, format);
    assert.equal(outcome.code, expectedCode, format);
    assert.equal(outcome.stderr.trim().split('\n').length, format === 'json' ? 2 : 1, format);
  }
});

test('clientEventId is deterministic, prefixed and inside the backend pattern', () => {
  const first = wo.clientEventId('run_abc', 'start');
  assert.equal(first, wo.clientEventId('run_abc', 'start'));
  assert.notEqual(first, wo.clientEventId('run_abc', 'start2'));
  assert.notEqual(wo.clientEventId('a', 'bc'), wo.clientEventId('ab', 'c'));
  assert.match(first, /^zcc-[0-9a-f]{40}$/);
  assert.match(first, /^[A-Za-z0-9._:-]{8,64}$/);
});

test('the ledger maps onto forward-only order stages and never sends pr_open at the request', () => {
  const event = (eventId, eventType, toStage, payload = {}) => ({ eventId, eventType, toStage, payload });
  const run = {
    runId: 'run_map',
    events: [
      event('start', 'START', 'PLANNING'),
      event('order-spec-bound', 'ORDER_SPEC_BOUND', 'AWAIT_TDD'),
      event('tdd-1', 'TDD_STARTED', 'TDD_RUNNING'),
      event('done-1', 'TDD_CHAIN_DONE', 'GATES'),
      event('gates', 'GATES_PASSED', 'CONVERGE'),
      event('conv', 'CONVERGENCE_PASSED', 'OPEN_PR'),
      event('pr-req', 'PR_OPEN_REQUESTED', 'OPEN_PR'),
      event('pr', 'PR_OPENED', 'TEAM_REVIEW', { pr: { number: 7, url: 'https://github.com/acme/widgets/pull/7', headSha: 'b'.repeat(40) } }),
      event('tr-req', 'TEAM_REVIEW_REQUESTED', 'TEAM_REVIEW'),
      event('tr-pub', 'TEAM_REVIEW_PUBLISHED', 'FIX_FINDINGS'),
      event('fix', 'FIX_REQUIRED', 'AWAIT_TDD'),
      event('tdd-2', 'TDD_STARTED', 'TDD_RUNNING'),
      event('done-2', 'TDD_CHAIN_DONE', 'FIX_FINDINGS'),
      event('cleared', 'FINDINGS_CLEARED', 'VALIDATE'),
      event('val', 'VALIDATION_PASSED', 'DELIVER'),
      event('deliv', 'DELIVERY_COMPLETE', 'DONE', { headSha: 'c'.repeat(40) }),
    ],
  };
  const planned = wo.planStageEvents(run);
  assert.deepEqual(planned.map((entry) => entry.status), ['planning', 'implementing', 'pr_open', 'reviewing', 'validating', 'ready_for_merge']);
  assert.equal(planned[2].autopilotEventId, 'pr');
  assert.equal(planned[2].pr.number, 7);
  assert.equal(planned[3].autopilotEventId, 'tr-req');
  assert.equal(planned[5].headSha, 'c'.repeat(40));
  assert.equal(new Set(planned.map((entry) => entry.clientEventId)).size, planned.length);
  assert.deepEqual(wo.planStageEvents(run, wo.STAGE_RANK.pr_open).map((entry) => entry.status), ['reviewing', 'validating', 'ready_for_merge']);
  const requestedOnly = { runId: 'run_req', events: run.events.slice(0, 7) };
  assert.ok(!wo.planStageEvents(requestedOnly).some((entry) => entry.status === 'pr_open'));
  assert.deepEqual(wo.planStageEvents(run).map((entry) => entry.clientEventId), wo.planStageEvents(run).map((entry) => entry.clientEventId));
});

test('renew cadence is min(60 s, lease / 5) and the lease expires after lease_seconds', () => {
  assert.equal(wo.renewInterval(300), 60000);
  assert.equal(wo.renewInterval(1800), 60000);
  assert.equal(wo.renewInterval(120), 24000);
  assert.equal(wo.renewDue(null, 0), true);
  assert.equal(wo.renewDue({ lastSuccessAt: 1000, leaseSeconds: 120 }, 1000 + 23999), false);
  assert.equal(wo.renewDue({ lastSuccessAt: 1000, leaseSeconds: 120 }, 1000 + 24000), true);
  assert.equal(wo.leaseExpired({ lastSuccessAt: 1000, leaseSeconds: 300 }, 1000 + 300000), false);
  assert.equal(wo.leaseExpired({ lastSuccessAt: 1000, leaseSeconds: 300 }, 1000 + 300001), true);
  assert.equal(wo.leaseExpired(null, 0), true);
});

test('loadContext is inert without the token or the marker and refuses a marker of another session', () => {
  const box = sandbox();
  assert.equal(wo.loadContext({ env: { ...box.env, ZENSU_SESSION_TOKEN: '' }, projectRoot: box.project, sessionKey: box.sessionKey }), null);
  assert.equal(wo.loadContext({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey }), null);
  const files = wo.sessionFiles(box.project, box.sessionKey);
  wo.writeState(box.project, files.marker, { sessionKey: box.sessionKey, clientSessionKey: wo.sessionKeyOf('another-session-99'), orderId: ORDER, attempt: 1 });
  const refused = wo.loadContext({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey });
  assert.ok(refused && refused.fault);
  assert.equal(wo.forgeWriteVerdict(refused).allowed, false);
  wo.writeState(box.project, files.marker, { sessionKey: box.sessionKey, clientSessionKey: box.sessionKey, orderId: ORDER, attempt: 1 });
  const bound = wo.loadContext({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey });
  assert.equal(bound.fault, null);
  assert.equal(bound.marker.orderId, ORDER);
});

test('state files refuse symlinks, hard links, oversized bodies and foreign schemas', () => {
  const box = sandbox();
  const files = wo.sessionFiles(box.project, box.sessionKey);
  wo.writeState(box.project, files.lease, { leaseSeconds: 60, lastSuccessAt: 1 });
  assert.equal(wo.readState(files.lease).leaseSeconds, 60);
  const link = path.join(files.dir, 'link.json');
  fs.symlinkSync(files.lease, link);
  assert.throws(() => wo.readState(link), /unsafe/);
  const hard = path.join(files.dir, 'hard.json');
  fs.linkSync(files.lease, hard);
  assert.throws(() => wo.readState(files.lease), /unsafe/);
  fs.unlinkSync(hard);
  const foreign = path.join(files.dir, 'foreign.json');
  fs.writeFileSync(foreign, JSON.stringify({ schemaVersion: 99 }));
  assert.throws(() => wo.readState(foreign), /invalid/);
  const big = path.join(files.dir, 'big.json');
  fs.writeFileSync(big, `{"schemaVersion":1,"pad":"${'x'.repeat(1024 * 1024)}"}`);
  assert.throws(() => wo.readState(big), /unsafe/);
  assert.equal(wo.readState(path.join(files.dir, 'absent.json')), null);
});

test('createOnce writes a marker exactly once', () => {
  const box = sandbox();
  const files = wo.sessionFiles(box.project, box.sessionKey);
  assert.equal(wo.createOnce(box.project, files.lost, { code: 'stale_attempt' }), true);
  assert.equal(wo.createOnce(box.project, files.lost, { code: 'other' }), false);
  assert.equal(wo.readState(files.lost).code, 'stale_attempt');
  assert.deepEqual(fs.readdirSync(files.dir).filter((name) => name.includes('.tmp-')), []);
});

test('forge writes are denied when the lease is lost, the session ended, or no renewal succeeded within the lease', () => {
  const box = sandbox();
  const files = wo.sessionFiles(box.project, box.sessionKey);
  const marker = { sessionKey: box.sessionKey, clientSessionKey: box.sessionKey, orderId: ORDER, attempt: 1 };
  wo.writeState(box.project, files.marker, marker);
  const context = wo.loadContext({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey });
  assert.equal(wo.forgeWriteVerdict(context, 5000).allowed, false);
  wo.writeState(box.project, files.lease, { leaseSeconds: 300, lastSuccessAt: 1000 });
  assert.equal(wo.forgeWriteVerdict(context, 1000 + 299000).allowed, true);
  assert.equal(wo.forgeWriteVerdict(context, 1000 + 301000).allowed, false);
  wo.markEnded(context, { outcome: 'success', kind: 'ready_for_merge', delivered: true, at: 1 });
  assert.match(wo.forgeWriteVerdict(context, 2000).reason, /ended/);
  fs.unlinkSync(files.ended);
  wo.markLost(context, { code: 'stale_attempt', via: 'event', at: 1 });
  assert.match(wo.forgeWriteVerdict(context, 2000).reason, /lost \(stale_attempt\)/);
});

test('answers are queued once and handed out once', () => {
  const box = sandbox();
  const files = wo.sessionFiles(box.project, box.sessionKey);
  wo.writeState(box.project, files.marker, { sessionKey: box.sessionKey, clientSessionKey: box.sessionKey, orderId: ORDER, attempt: 1 });
  const context = wo.loadContext({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey });
  const answer = { id: 'q1', category: 'technical_choice', question: 'Which store?', answer: 'Use Postgres.', status: 'answered' };
  assert.equal(wo.recordAnswers(context, [answer]).length, 1);
  assert.equal(wo.recordAnswers(context, [answer]).length, 0);
  assert.deepEqual(wo.takePendingAnswers(context).map((entry) => entry.id), ['q1']);
  assert.deepEqual(wo.takePendingAnswers(context), []);
  assert.equal(wo.recordAnswers(context, [answer, { id: 'q2', answer: '' }]).length, 0);
});

test('start reads the order, writes the marker, renews and links Pulse', () => {
  const box = sandbox();
  box.seed();
  const result = wo.start({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey, orderId: ORDER });
  assert.equal(result.exit, wo.EXIT.OK, result.message);
  assert.equal(result.summary.action, 'implement');
  assert.equal(result.summary.integrationBranch, 'integration/widgets');
  assert.equal(result.summary.pulse, 'linked');
  assert.equal(result.summary.leaseSeconds, 1800);
  const context = wo.loadContext({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey });
  assert.equal(context.marker.orderId, ORDER);
  assert.equal(wo.forgeWriteVerdict(context).allowed, true);
  assert.equal(box.fake().pulse.clientName, 'zensu-claude-code');
  assert.equal(box.fake().pulse.clientVersion, wo.pluginVersion());
  const again = wo.start({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey, orderId: ORDER });
  assert.equal(again.exit, wo.EXIT.OK);
});

test('start refuses without the token, without zensu work, and for an order of another session', () => {
  const box = sandbox();
  box.seed();
  const noToken = wo.start({ env: { ...box.env, ZENSU_SESSION_TOKEN: '' }, projectRoot: box.project, sessionKey: box.sessionKey, orderId: ORDER });
  assert.equal(noToken.exit, wo.EXIT.NOT_BOUND);
  assert.equal(box.calls().length, 0);
  box.mutate((state) => { state.noWork = true; });
  const noWork = wo.start({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey, orderId: ORDER });
  assert.equal(noWork.exit, wo.EXIT.NO_CLI);
  assert.match(noWork.message, /no `zensu work` command/);
  box.mutate((state) => { state.noWork = false; state.order.client_session_id = 'another-session-99'; });
  const foreign = wo.start({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey, orderId: ORDER });
  assert.equal(foreign.exit, wo.EXIT.NOT_BOUND);
  assert.match(foreign.message, /another session/);
  assert.equal(wo.loadContext({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey }), null);
});

test('an unsupported kind ends with blocked(worker_error) naming the kind', () => {
  const box = sandbox();
  box.seed({ order: { kind: 'verify' } });
  const result = wo.start({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey, orderId: ORDER });
  assert.equal(result.exit, wo.EXIT.ENDED);
  assert.equal(result.summary.action, 'stop');
  assert.equal(result.summary.delivered, true);
  const state = box.fake();
  assert.equal(state.order.status, 'blocked');
  assert.equal(state.order.blocked_kind, 'worker_error');
  assert.match(state.order.blocked_reason, /kind verify/);
  const blocked = state.events.find((event) => event.event_type === 'blocked');
  assert.equal(blocked.client_name, 'zensu-claude-code');
  assert.match(blocked.client_event_id, /^zcc-/);
  const context = wo.loadContext({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey });
  const ended = wo.readState(context.files.ended);
  assert.equal(ended.outcome, 'failure');
  assert.equal(ended.delivered, true);
  assert.equal(wo.forgeWriteVerdict(context).allowed, false);
});

test('renew writes the lease-lost marker on stale_attempt, runtime_cap, a revoked key and a codeless 409', () => {
  for (const [label, setup] of [
    ['stale', (state) => { state.staleAttempt = true; }],
    ['runtime cap', (state) => { state.runtimeCap = true; }],
    ['revoked', (state) => { state.mode = 'revoked'; }],
    ['codeless', (state) => { state.staleAttempt = true; state.printCodes = false; }],
  ]) {
    const box = sandbox();
    box.seed();
    assert.equal(wo.start({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey, orderId: ORDER }).exit, wo.EXIT.OK, label);
    box.mutate(setup);
    const context = wo.loadContext({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey });
    const beat = wo.renew(context, { env: box.env, force: true });
    assert.equal(beat.verdict, wo.VERDICTS.LOST, label);
    assert.equal(wo.forgeWriteVerdict(context).allowed, false, label);
    assert.equal(wo.renew(context, { env: box.env, force: true }).verdict, wo.VERDICTS.LOST, label);
  }
});

test('renew is throttled and a transient failure keeps the lease', () => {
  const box = sandbox();
  box.seed();
  assert.equal(wo.start({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey, orderId: ORDER }).exit, wo.EXIT.OK);
  const context = wo.loadContext({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey });
  const before = box.fake().heartbeats;
  assert.equal(wo.renew(context, { env: box.env }).verdict, 'fresh');
  assert.equal(box.fake().heartbeats, before);
  box.mutate((state) => { state.failNext = [{ command: 'heartbeat', status: 503, code: 'unavailable', times: 1 }]; });
  assert.equal(wo.renew(context, { env: box.env, force: true }).verdict, wo.VERDICTS.TRANSIENT);
  assert.equal(wo.forgeWriteVerdict(context).allowed, true);
  assert.equal(wo.renew(context, { env: box.env, force: true }).verdict, wo.VERDICTS.OK);
});

test('renew queues the answers of non-blocking questions', () => {
  const box = sandbox();
  box.seed();
  assert.equal(wo.start({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey, orderId: ORDER }).exit, wo.EXIT.OK);
  box.mutate((state) => {
    state.questions.push({ id: 'q-answered', category: 'technical_choice', question: 'Which queue?', answer: 'Use the existing queue.', status: 'answered', blocking: false });
  });
  const context = wo.loadContext({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey });
  const beat = wo.renew(context, { env: box.env, force: true });
  assert.deepEqual(beat.answers.map((answer) => answer.id), ['q-answered']);
  assert.equal(wo.takePendingAnswers(context)[0].answer, 'Use the existing queue.');
});

test('sendEvent retries claim_not_confirmed, classifies a codeless 409 by probing, and stops on 401', () => {
  const box = sandbox();
  box.seed();
  assert.equal(wo.start({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey, orderId: ORDER }).exit, wo.EXIT.OK);
  const context = wo.loadContext({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey });
  box.mutate((state) => { state.failNext = [{ command: 'event', status: 409, code: 'claim_not_confirmed', times: 1 }]; });
  const planning = wo.sendEvent(context, ['--stage', 'planning', '--client-event-id', wo.clientEventId('r', 'start')], { env: { ...box.env, ZENSU_WORK_ORDER_RETRY_BUDGET_MS: '5000' } });
  assert.equal(planning.verdict, wo.VERDICTS.OK);
  assert.equal(box.fake().order.status, 'planning');
  box.mutate((state) => { state.policy.plan_approval = 'required'; state.printCodes = false; });
  const refused = wo.sendEvent(context, ['--stage', 'implementing', '--client-event-id', wo.clientEventId('r', 'bound')], { env: box.env, target: 'implementing' });
  assert.equal(refused.verdict, wo.VERDICTS.FINAL);
  assert.equal(refused.failure.code, 'plan_approval_required');
  assert.equal(wo.forgeWriteVerdict(context).allowed, true);
  const sameStatus = wo.sendEvent(context, ['--stage', 'planning', '--client-event-id', wo.clientEventId('r', 'again')], { env: box.env, target: 'planning' });
  assert.equal(sameStatus.verdict, wo.VERDICTS.OK);
  box.mutate((state) => { state.mode = 'revoked'; });
  const revoked = wo.sendEvent(context, ['--stage', 'planning', '--client-event-id', wo.clientEventId('r', 'x')], { env: box.env });
  assert.equal(revoked.verdict, wo.VERDICTS.LOST);
  assert.equal(wo.forgeWriteVerdict(context).allowed, false);
});

test('a replay with the same client event id succeeds after the session ended itself', () => {
  const box = sandbox();
  box.seed({ order: { status: 'implementing', pr_url: 'https://github.com/acme/widgets/pull/9', pr_number: 9 } });
  assert.equal(wo.start({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey, orderId: ORDER }).exit, wo.EXIT.OK);
  const context = wo.loadContext({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey });
  const id = wo.clientEventId('run_done', 'deliv');
  const args = ['--stage', 'ready_for_merge', '--head', 'd'.repeat(40), '--client-event-id', id];
  assert.equal(wo.sendEvent(context, args, { env: box.env, terminal: true }).verdict, wo.VERDICTS.OK);
  assert.equal(box.fake().mode, 'ended');
  const replay = wo.sendEvent(context, args, { env: box.env, terminal: true });
  assert.equal(replay.verdict, wo.VERDICTS.OK);
  assert.equal(replay.replay, true);
  const fresh = wo.sendEvent(context, ['--stage', 'ready_for_merge', '--head', 'd'.repeat(40), '--client-event-id', wo.clientEventId('run_done', 'other')], { env: box.env, terminal: true });
  assert.equal(fresh.verdict, wo.VERDICTS.LOST);
});

test('the module CLI is inert outside work-order mode', () => {
  const box = sandbox();
  const out = execFileSync(process.execPath, [MODULE, 'status'], {
    env: { ...box.env, ZENSU_SESSION_TOKEN: '', WO_PROJECT_ROOT: box.project, WO_SESSION_KEY: box.sessionKey },
    encoding: 'utf8',
  });
  assert.deepEqual(JSON.parse(out), { mode: 'inert' });
  assert.equal(box.calls().length, 0);
  assert.equal(fs.existsSync(path.join(box.project, '.zensu')), false);
});
