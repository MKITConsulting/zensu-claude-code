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

test('the status and code are read when context follows the suffix and the message spans lines', () => {
  for (const format of ['json', 'line']) {
    const box = sandbox();
    box.seed({ errorFormat: format, staleAttempt: true, errorContext: 'created before the failure: item 1 (status 500)', errorContinuation: 'second line of the message' });
    const outcome = wo.runZensu(['work', 'heartbeat', ORDER, '--json'], { env: box.env });
    assert.equal(outcome.status, 409, format);
    assert.equal(outcome.code, 'stale_attempt', format);
    assert.equal(wo.classifyFailure(outcome).verdict, wo.VERDICTS.LOST, format);
  }
  const multi = wo.cliOutcome({ status: 1, stdout: '', stderr: 'error: item 3: create failed\nfeature already exists (status 409, code conflict); created before the failure: one\n' });
  assert.equal(multi.status, 409);
  assert.equal(multi.code, 'conflict');
  const flagError = wo.cliOutcome({ status: 1, stdout: '', stderr: 'error: unknown flag --bogus\n{"error":{"message":"unknown flag --bogus"}}\n' });
  assert.equal(flagError.status, null);
  assert.equal(flagError.code, null);
  assert.equal(wo.classifyFailure(flagError).verdict, wo.VERDICTS.TRANSIENT);
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

test('the work branch carries the branch prefix the order spec names', () => {
  assert.equal(wo.branchPrefixOf({ spec: { branch_prefix: 'wo-' } }), 'wo-');
  assert.equal(wo.branchPrefixOf({ spec: { branch_prefix: 'agents/wo-' } }), 'agents/wo-');
  assert.equal(wo.branchPrefixOf({ spec: { branch_prefix: '../x' } }), 'wo-');
  assert.equal(wo.branchPrefixOf({ spec: { branch_prefix: 'a..b' } }), 'wo-');
  assert.equal(wo.branchPrefixOf({}), 'wo-');
  const box = sandbox();
  box.seed();
  const result = wo.start({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey, orderId: ORDER });
  assert.equal(result.exit, wo.EXIT.OK, result.message);
  assert.equal(result.summary.branchPrefix, 'wo-');
  assert.equal(result.summary.workBranch, `wo-${ORDER.slice(0, 8)}`);
  const recorded = sandbox();
  recorded.seed({ order: { branch: 'wo-earlier1' } });
  const resumed = wo.start({ env: recorded.env, projectRoot: recorded.project, sessionKey: recorded.sessionKey, orderId: ORDER });
  assert.equal(resumed.summary.workBranch, 'wo-earlier1');
});

test('the fake refuses a stage branch outside the order branch prefix, as the service does', () => {
  const box = sandbox();
  const context = startedContext(box);
  assert.equal(wo.sendEvent(context, ['--stage', 'planning', '--client-event-id', wo.clientEventId('r', 'start')], { env: box.env }).verdict, wo.VERDICTS.OK);
  const refused = wo.sendEvent(context, ['--stage', 'implementing', '--branch', 'zensu/work-22222222', '--client-event-id', wo.clientEventId('r', 'bound')], { env: box.env, target: 'implementing' });
  assert.equal(refused.verdict, wo.VERDICTS.FINAL);
  assert.equal(refused.failure.code, 'invalid_branch');
  const accepted = wo.sendEvent(context, ['--stage', 'implementing', '--branch', `wo-${ORDER.slice(0, 8)}`, '--client-event-id', wo.clientEventId('r', 'bound-2')], { env: box.env, target: 'implementing' });
  assert.equal(accepted.verdict, wo.VERDICTS.OK);
  assert.equal(box.fake().order.branch, `wo-${ORDER.slice(0, 8)}`);
});

test('push refuses a working branch without the order branch prefix before any forge write', () => {
  const box = sandbox();
  const context = startedContext(box, { order: { status: 'implementing' } });
  const gitEnv = { ...process.env, GIT_AUTHOR_NAME: 'Test', GIT_AUTHOR_EMAIL: 'test@example.invalid', GIT_COMMITTER_NAME: 'Test', GIT_COMMITTER_EMAIL: 'test@example.invalid' };
  const git = (...args) => execFileSync('git', ['-C', box.project, ...args], { encoding: 'utf8', env: gitEnv });
  git('init', '-q');
  git('checkout', '-q', '-b', 'feature/widgets');
  fs.writeFileSync(path.join(box.project, 'a.txt'), 'a\n');
  git('add', 'a.txt');
  git('commit', '-q', '-m', 'init');
  const pushed = wo.push(context, { env: box.env });
  assert.equal(pushed.exit, wo.EXIT.REFUSED);
  assert.match(pushed.message, /feature\/widgets does not start with wo-/);
  assert.equal(box.calls().filter((argv) => argv[0] === 'work' && argv[1] === 'event').length, 0);
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

const HEAD = 'c'.repeat(40);
const RUN = 'run_0123abcd';

function startedContext(box, seedOverrides = {}) {
  box.seed(seedOverrides);
  const started = wo.start({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey, orderId: ORDER });
  assert.equal(started.exit, wo.EXIT.OK, started.message);
  return wo.loadContext({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey });
}

function writeRun(box, stage, events) {
  const dir = path.join(box.project, '.zensu', 'state');
  fs.mkdirSync(dir, { recursive: true });
  const evidence = { pr: { number: 7, url: 'https://github.com/acme/widgets/pull/7', headSha: HEAD } };
  fs.writeFileSync(path.join(dir, `autopilot-run-${RUN}.json`), JSON.stringify({ runId: RUN, stage, events, evidence }));
}

function ledger(...steps) {
  return steps.map(([eventType, toStage, payload = {}], index) => ({
    eventId: index === 0 ? 'start' : `e${index}`, eventType, payload, fromStage: null, toStage,
  }));
}

const DONE_LEDGER = ledger(
  ['START', 'PLANNING'],
  ['ORDER_SPEC_BOUND', 'AWAIT_TDD'],
  ['TDD_STARTED', 'TDD_RUNNING'],
  ['TDD_CHAIN_DONE', 'GATES'],
  ['GATES_PASSED', 'CONVERGE'],
  ['CONVERGENCE_PASSED', 'OPEN_PR'],
  ['PR_OPEN_REQUESTED', 'OPEN_PR'],
  ['PR_OPENED', 'TEAM_REVIEW', { operationKey: 'op', pr: { number: 7, url: 'https://github.com/acme/widgets/pull/7', headSha: HEAD } }],
  ['TEAM_REVIEW_REQUESTED', 'TEAM_REVIEW'],
  ['TEAM_REVIEW_PUBLISHED', 'FIX_FINDINGS'],
  ['FINDINGS_CLEARED', 'VALIDATE'],
  ['VALIDATION_PASSED', 'DELIVER'],
  ['DELIVERY_COMPLETE', 'DONE', { headSha: HEAD }],
);

const stageCalls = (box) => box.calls()
  .filter((argv) => argv[0] === 'work' && argv[1] === 'event')
  .map((argv) => {
    const flag = (name) => (argv.indexOf(name) >= 0 ? argv[argv.indexOf(name) + 1] : null);
    return { stage: flag('--stage'), blocked: flag('--blocked'), id: flag('--client-event-id'), argv };
  });

test('a DONE run reports every stage in order and then ready_for_merge with the full head', () => {
  const box = sandbox();
  const context = startedContext(box);
  assert.deepEqual(wo.markerRun(context, RUN), { runId: RUN });
  writeRun(box, 'DONE', DONE_LEDGER);
  const result = wo.finish(context, { env: box.env });
  assert.equal(result.exit, wo.EXIT.OK, result.message);
  const sent = stageCalls(box);
  assert.deepEqual(sent.map((call) => call.stage),
    ['planning', 'implementing', 'pr_open', 'reviewing', 'validating', 'ready_for_merge']);
  assert.equal(new Set(sent.map((call) => call.id)).size, sent.length);
  assert.equal(sent[0].id, wo.clientEventId(RUN, 'start'));
  const prOpen = sent[2].argv;
  assert.equal(prOpen[prOpen.indexOf('--pr-url') + 1], 'https://github.com/acme/widgets/pull/7');
  assert.equal(prOpen[prOpen.indexOf('--pr-number') + 1], '7');
  assert.equal(prOpen[prOpen.indexOf('--head') + 1], HEAD);
  const ready = sent[5].argv;
  assert.equal(ready[ready.indexOf('--head') + 1], HEAD);
  assert.equal(ready[ready.indexOf('--autopilot-stage') + 1], 'DONE');
  assert.equal(ready[ready.indexOf('--client-name') + 1], 'zensu-claude-code');
  assert.equal(box.fake().order.status, 'ready_for_merge');
  const ended = wo.readState(context.files.ended);
  assert.equal(ended.outcome, 'success');
  assert.equal(ended.kind, 'ready_for_merge');
  const again = wo.finish(context, { env: box.env });
  assert.equal(again.exit, wo.EXIT.OK);
  assert.equal(stageCalls(box).length, sent.length);
});

test('drain sends each stage once, never ready_for_merge, and counts invalid_transition as delivered', () => {
  const box = sandbox();
  const context = startedContext(box);
  wo.markerRun(context, RUN);
  writeRun(box, 'TEAM_REVIEW', DONE_LEDGER.slice(0, 8));
  const first = wo.drain(context, { env: box.env });
  assert.equal(first.verdict, wo.VERDICTS.OK);
  assert.deepEqual(first.sent, ['planning', 'implementing', 'pr_open']);
  const second = wo.drain(context, { env: box.env });
  assert.deepEqual(second.sent, []);
  writeRun(box, 'DONE', DONE_LEDGER);
  box.mutate((state) => { state.failNext = [{ command: 'event', status: 409, code: 'invalid_transition', times: 1 }]; });
  const third = wo.drain(context, { env: box.env });
  assert.equal(third.verdict, wo.VERDICTS.OK);
  assert.deepEqual(third.sent, ['validating']);
  assert.equal(stageCalls(box).filter((call) => call.stage === 'ready_for_merge').length, 0);
});

test('finish without a terminal run needs a reason and then blocks the order with worker_error', () => {
  const box = sandbox();
  const context = startedContext(box);
  wo.markerRun(context, RUN);
  writeRun(box, 'GATES', DONE_LEDGER.slice(0, 4));
  const refused = wo.finish(context, { env: box.env });
  assert.equal(refused.exit, wo.EXIT.REFUSED);
  assert.match(refused.message, /still at GATES/);
  const result = wo.finish(context, { env: box.env, reason: 'The gates fail on a missing database migration.' });
  assert.equal(result.exit, wo.EXIT.ENDED, result.message);
  assert.equal(result.cancelRun, RUN);
  const order = box.fake().order;
  assert.equal(order.status, 'blocked');
  assert.equal(order.blocked_kind, 'worker_error');
  assert.match(order.blocked_reason, /missing database migration/);
  const blocks = stageCalls(box).filter((call) => call.blocked);
  assert.equal(blocks.length, 1);
  assert.deepEqual(stageCalls(box).filter((call) => call.stage).map((call) => call.stage), ['planning', 'implementing']);
  assert.equal(wo.readState(context.files.ended).outcome, 'failure');
});

test('a BLOCKED run finishes without a reason and names its block code', () => {
  const box = sandbox();
  const context = startedContext(box);
  wo.markerRun(context, RUN);
  const run = DONE_LEDGER.slice(0, 4);
  writeRun(box, 'BLOCKED', run);
  const file = path.join(box.project, '.zensu', 'state', `autopilot-run-${RUN}.json`);
  const record = JSON.parse(fs.readFileSync(file, 'utf8'));
  record.blocked = { from: 'GATES', code: 'TDD_MAX_ROUNDS' };
  fs.writeFileSync(file, JSON.stringify(record));
  const result = wo.finish(context, { env: box.env });
  assert.equal(result.exit, wo.EXIT.ENDED, result.message);
  assert.match(box.fake().order.blocked_reason, /did not converge/);
});

test('the approved plan is the last plan artifact before the last approval of the spec hash', () => {
  const spec = 'b'.repeat(64);
  const events = [
    { event_type: 'artifact', detail: { kind: 'plan', sha: '1'.repeat(40), path: '.zensu/plans/x.md' } },
    { event_type: 'approved', detail: { subject: 'implementation_plan', spec_hash: 'c'.repeat(64) } },
    { event_type: 'artifact', detail: { kind: 'report', sha: '9'.repeat(40), path: 'r.md' } },
    { event_type: 'artifact', detail: JSON.stringify({ kind: 'plan', sha: '2'.repeat(40), path: '.zensu/plans/x.md' }) },
    { event_type: 'approved', detail: { subject: 'implementation_plan', spec_hash: spec } },
    { event_type: 'artifact', detail: { kind: 'plan', sha: '3'.repeat(40), path: '.zensu/plans/x.md' } },
  ];
  assert.equal(wo.approvedPlanCommit(events, spec).sha, '2'.repeat(40));
  assert.equal(wo.approvedPlanCommit(events, 'd'.repeat(64)), null);
});

test('the Stop decision blocks until three stops pass without progress, then ends the order', () => {
  const box = sandbox();
  const context = startedContext(box);
  assert.equal(wo.stopDecision(null).decision, 'inert');
  wo.markerRun(context, RUN);
  writeRun(box, 'GATES', DONE_LEDGER.slice(0, 4));
  for (let index = 0; index < 3; index += 1) {
    const decided = wo.stopDecision(context, { env: box.env });
    assert.equal(decided.decision, 'block');
    assert.match(decided.reason, /zensu-work-order\.sh --finish/);
  }
  writeRun(box, 'CONVERGE', DONE_LEDGER.slice(0, 5));
  assert.equal(wo.stopDecision(context, { env: box.env }).decision, 'block');
  assert.equal(wo.stopDecision(context, { env: box.env }).decision, 'block');
  assert.equal(wo.stopDecision(context, { env: box.env }).decision, 'block');
  const closed = wo.stopDecision(context, { env: box.env });
  assert.equal(closed.decision, 'allow');
  assert.equal(closed.cancelRun, RUN);
  assert.equal(box.fake().order.blocked_kind, 'worker_error');
  assert.equal(wo.stopDecision(context, { env: box.env }).decision, 'allow');
});

test('binding answers only for this session\'s order and the push refuses before any write when the lease is stale', () => {
  const box = sandbox();
  assert.deepEqual(wo.binding(null, null), { exit: wo.EXIT.OK, value: null });
  assert.equal(wo.binding(null, ORDER).exit, wo.EXIT.NOT_BOUND);
  const context = startedContext(box);
  assert.equal(wo.binding(context, null).exit, wo.EXIT.NOT_BOUND);
  assert.equal(wo.binding(context, '99999999-9999-4999-8999-999999999999').exit, wo.EXIT.NOT_BOUND);
  assert.deepEqual(wo.binding(context, ORDER.toUpperCase()).value, { orderId: ORDER, attempt: 1, specHash: 'a'.repeat(64) });
  box.mutate((state) => { state.staleAttempt = true; });
  const pushed = wo.push(context, { env: box.env });
  assert.equal(pushed.exit, wo.EXIT.LOST);
  assert.equal(wo.forgeWriteVerdict(context).allowed, false);
  assert.equal(wo.push(context, { env: box.env }).exit, wo.EXIT.LOST);
});

test('the Bash analysis denies raw forge writes, human-gate verbs and token handling, and reads nested commands', () => {
  const denied = {
    'git push origin HEAD': 'push',
    'git -C /tmp/x -c a=b push --force': 'push',
    'cd x && git push': 'push',
    'bash -lc "git push origin main"': 'push',
    'eval git push': 'push',
    'echo $(git push 2>&1)': 'push',
    'env FOO=1 git push': 'push',
    'sudo -u bot git push': 'push',
    'gh pr create --fill': 'open-pr',
    'gh -R acme/w pr merge 7 --squash': 'merge',
    'glab mr merge 3': 'merge',
    'glab mr create --fill': 'open-pr',
    'zensu auth login': 'auth',
    'zensu work approve 1234': 'human-gate',
    'zensu work policy set --plan-approval auto': 'human-gate',
    'zensu plan approve abc': 'human-gate',
    'zensu work event 1234 --stage implementing': 'helper-verb',
    'zensu work heartbeat 1234': 'helper-verb',
    'printenv': 'token',
    'printenv ZENSU_SESSION_TOKEN': 'token',
    'env': 'token',
    'env -0': 'token',
    'set': 'token',
    'export': 'token',
    'declare -p': 'token',
    'echo "$ZENSU_SESSION_TOKEN"': 'token',
    'echo ${ZENSU_SESSION_TOKEN:0:4}': 'token',
    'unset ZENSU_SESSION_TOKEN': 'token',
    'ZENSU_SESSION_TOKEN=x zensu work get 1': 'token',
    'env -u ZENSU_SESSION_TOKEN zensu work get 1': 'token',
    'export ZENSU_SESSION_TOKEN=abc': 'token',
    'cat /proc/self/environ': 'token',
  };
  for (const [command, code] of Object.entries(denied)) {
    const analysis = wo.analyzeBash(command);
    assert.ok(analysis.deny, command);
    assert.equal(analysis.deny.code, code, command);
  }
  const allowed = [
    'git status', 'git commit -m "do not git push here"', 'git log --oneline -3', 'printenv PATH', 'set -e',
    'export PATH=/usr/bin:$PATH', 'zensu work get 1234 --json', 'zensu work ask 1234 --category scope --question "Which?" --default-option a',
    'zensu work followup 1234 --title t --rationale r --severity low', 'zensu work policy get', 'gh pr view 7', 'echo hello',
    "cat <<'MSG' > /tmp/m\ngit push is a step\nMSG", 'local x=1',
  ];
  for (const command of allowed) assert.equal(wo.analyzeBash(command).deny, null, command);
  assert.equal(wo.analyzeBash('gh pr view 7').forge, true);
  assert.equal(wo.analyzeBash('bash hooks/lib/zensu-vcs.sh --pr-state 7').forge, true);
  assert.equal(wo.analyzeBash('bash scripts/build.sh').forge, false);
  assert.equal(wo.analyzeBash('zensu-vcs.sh --pr-state 7').forge, true);
});

test('the gate is inert outside work-order mode and denies prompts, chips and raw pushes inside it', () => {
  const payload = (tool, command) => ({ tool_name: tool, tool_input: command === undefined ? {} : { command } });
  assert.equal(wo.gateDecision(null, payload('AskUserQuestion')), null);
  assert.equal(wo.gateDecision(null, payload('Bash', 'git push')), null);
  const box = sandbox();
  const context = startedContext(box);
  for (const tool of ['AskUserQuestion', 'EnterPlanMode', 'ExitPlanMode']) {
    const decided = wo.gateDecision(context, payload(tool), { env: box.env });
    assert.equal(decided.code, 'ask', tool);
    assert.match(decided.reason, new RegExp(`zensu work ask ${ORDER}`));
  }
  const chip = wo.gateDecision(context, payload('mcp__ccd_session__spawn_task'), { env: box.env });
  assert.match(chip.reason, new RegExp(`zensu work followup ${ORDER}`));
  assert.match(wo.gateDecision(context, payload('Bash', 'git push'), { env: box.env }).reason, /zensu-work-order\.sh --push/);
  assert.equal(wo.gateDecision(context, payload('Bash', 'git status'), { env: box.env }), null);
  assert.equal(wo.gateDecision(context, payload('Read'), { env: box.env }), null);
  wo.markLost(context, { code: 'stale_attempt', via: 'test', at: Date.now() });
  const lost = wo.gateDecision(context, payload('Bash', 'gh pr view 7'), { env: box.env });
  assert.equal(lost.code, 'lease');
  assert.match(lost.reason, /stale_attempt/);
  assert.equal(wo.gateDecision(context, payload('Bash', 'git status'), { env: box.env }), null);
});

test('the gate renews a lease that is due and leaves a fresh one alone', () => {
  const box = sandbox();
  const context = startedContext(box);
  const beats = () => box.calls().filter((argv) => argv[0] === 'work' && argv[1] === 'heartbeat').length;
  const before = beats();
  wo.gateDecision(context, { tool_name: 'Read', tool_input: {} }, { env: box.env, now: () => Date.now() });
  assert.equal(beats(), before);
  wo.gateDecision(context, { tool_name: 'Read', tool_input: {} }, { env: box.env, now: () => Date.now() + 61000 });
  assert.equal(beats(), before + 1);
});

test('ask continues with the default, and a blocking question ends the session', () => {
  const box = sandbox();
  const context = startedContext(box);
  const usage = wo.ask(context, { env: box.env, category: 'scope', question: 'Which table?' });
  assert.equal(usage.exit, wo.EXIT.USAGE);
  const asked = wo.ask(context, { env: box.env, category: 'technical_choice', question: 'Which queue library should the worker use?', options: ['bullmq', 'pg-boss'], defaultOption: 'pg-boss' });
  assert.equal(asked.exit, wo.EXIT.OK, asked.message);
  assert.equal(asked.value.continueWith, 'pg-boss');
  assert.equal(asked.value.ended, false);
  const again = wo.ask(context, { env: box.env, category: 'technical_choice', question: 'Which queue library should the worker use?', options: ['bullmq', 'pg-boss'], defaultOption: 'pg-boss' });
  assert.equal(again.value.replay, true);
  assert.equal(box.fake().questions.length, 1);
  wo.markerRun(context, RUN);
  writeRun(box, 'TDD_RUNNING', DONE_LEDGER.slice(0, 3));
  const blocking = wo.ask(context, { env: box.env, category: 'clarification', question: 'Should deleted widgets stay visible to admins?', blocking: true });
  assert.equal(blocking.exit, wo.EXIT.ENDED, blocking.message);
  assert.equal(blocking.cancelRun, RUN);
  assert.equal(box.fake().order.blocked_kind, 'question');
  const ended = wo.readState(context.files.ended);
  assert.equal(ended.outcome, 'success');
  assert.equal(ended.kind, 'blocked:question');
  assert.equal(wo.forgeWriteVerdict(context).allowed, false);
});

test('followup files once per title and the CLI parser collects repeated flags', () => {
  const box = sandbox();
  const context = startedContext(box);
  const filed = wo.followup(context, { env: box.env, title: 'Add an index on widgets.owner_id', rationale: 'The list query scans the table.', severity: 'medium', paths: ['db/schema.sql'] });
  assert.equal(filed.exit, wo.EXIT.OK, filed.message);
  wo.followup(context, { env: box.env, title: 'Add an index on widgets.owner_id', rationale: 'The list query scans the table.', severity: 'medium' });
  assert.equal(box.fake().followups.length, 1);
  assert.deepEqual(wo.parseArgs(['--option', 'a', '--option', 'b', '--blocking', '--question', 'q', '--requirement', 'AC-001']),
    { option: ['a', 'b'], blocking: true, question: 'q', requirement: ['AC-001'] });
});

test('the post-tool update hands answers over once and ends the session on a blocked direct ask', () => {
  const box = sandbox();
  const context = startedContext(box);
  assert.equal(wo.postToolUpdate(null, { tool_name: 'Read' }), null);
  wo.recordAnswers(context, [{ id: 'q-1', category: 'scope', question: 'Include archived widgets?', answer: 'No, active ones only.', status: 'answered' }]);
  const first = wo.postToolUpdate(context, { tool_name: 'Read', tool_input: {} }, { env: box.env });
  assert.match(first.additionalContext, /active ones only/);
  const second = wo.postToolUpdate(context, { tool_name: 'Read', tool_input: {} }, { env: box.env });
  assert.equal(second.additionalContext, null);
  wo.markerRun(context, RUN);
  writeRun(box, 'TDD_RUNNING', DONE_LEDGER.slice(0, 3));
  const response = { stdout: JSON.stringify({ question: { id: 'q-2', status: 'awaiting_human' }, order: { id: ORDER, status: 'blocked', blocked_kind: 'escalated' }, escalated: true }) };
  const ended = wo.postToolUpdate(context, { tool_name: 'Bash', tool_input: { command: `zensu work ask ${ORDER} --category scope --question "x" --blocking --json` }, tool_response: response }, { env: box.env });
  assert.equal(ended.cancelRun, RUN);
  assert.match(ended.additionalContext, /Stop now/);
  assert.equal(wo.readState(context.files.ended).kind, 'blocked:escalated');
});

test('the plan summary carries no markup, command line or control character', () => {
  const summary = wo.planSummary('# Plan\n\n```bash\ngit push\n```\n- **AC-001** `widgets` render\n<!-- hidden -->\u0007bell');
  assert.ok(!/[`*#<>\u0000-\u001f]/.test(summary), summary);
  assert.ok(summary.length <= 400);
  assert.match(summary, /^Implementation plan\./);
});

test('the order-bound review key matches the state library helper and differs per order and head', () => {
  const head = 'ABCDEF0123456789abcdef0123456789abcdef01';
  const library = path.join(__dirname, '..', '..', 'hooks', 'lib', 'zensu-autopilot-state.sh');
  const fromLibrary = execFileSync('bash', ['-c', 'source "$1" && autopilot_work_order_review_operation_key "$2" "$3"', 'key', library, ORDER.toUpperCase(), head], { encoding: 'utf8' });
  assert.equal(wo.workOrderReviewKey(ORDER, head), fromLibrary);
  assert.match(fromLibrary, /^team-review:v1:[a-f0-9]{64}$/);
  assert.notEqual(wo.workOrderReviewKey(ORDER, head), wo.workOrderReviewKey('33333333-3333-4333-8333-333333333333', head));
  assert.notEqual(wo.workOrderReviewKey(ORDER, head), wo.workOrderReviewKey(ORDER, 'abcdef0'));
});

test('the release plan names only nonterminal runs of earlier attempts of the same order', () => {
  const box = sandbox();
  const dir = path.join(box.project, '.zensu', 'state');
  fs.mkdirSync(dir, { recursive: true });
  const put = (runId, stage, workOrder) => fs.writeFileSync(path.join(dir, `autopilot-run-${runId}.json`),
    JSON.stringify({ runId, stage, events: [], ...(workOrder ? { workOrder } : {}) }));
  put('run_a1_open', 'FIX_FINDINGS', { orderId: ORDER, attempt: 1, specHash: 'a'.repeat(64) });
  put('run_a1_done', 'CANCELLED', { orderId: ORDER, attempt: 1, specHash: 'a'.repeat(64) });
  put('run_a2_open', 'TEAM_REVIEW', { orderId: ORDER, attempt: 2, specHash: 'a'.repeat(64) });
  put('run_other_open', 'GATES', { orderId: '33333333-3333-4333-8333-333333333333', attempt: 1, specHash: 'a'.repeat(64) });
  put('run_plain_open', 'GATES', null);
  fs.writeFileSync(path.join(dir, 'autopilot-run-bad name.json'), '{}');
  assert.deepEqual(wo.releasePlan(box.project, ORDER, 2), ['run_a1_open']);
  assert.deepEqual(wo.releasePlan(box.project, ORDER.toUpperCase(), 3), ['run_a1_open', 'run_a2_open']);
  assert.deepEqual(wo.releasePlan(box.project, ORDER, 1), []);
  assert.deepEqual(wo.releasePlan('relative/path', ORDER, 2), []);
});
