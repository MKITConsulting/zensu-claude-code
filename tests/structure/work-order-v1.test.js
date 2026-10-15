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
    ZENSU_API_URL: 'http://127.0.0.1:9',
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_CONFIG_NOSYSTEM: '1',
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
      plan: { base_branch: 'main', integration_branch: 'plan/widgets' },
      order: {
        id: ORDER,
        work_plan_id: '11111111-1111-4111-8111-111111111111',
        repository: 'github.com/acme/widgets',
        kind: 'implement',
        status: 'claimed',
        attempt: 1,
        client_session_id: CLIENT_SESSION,
        claim_confirmed_at: new Date().toISOString(),
        lease_expires_at: Date.now() + 1800000,
        spec_hash: 'a'.repeat(64),
        spec_stale: false,
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
  assert.equal(result.summary.integrationBranch, 'plan/widgets');
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

test('the fake takes the pull request links the service takes and refuses the rest', () => {
  const box = sandbox();
  const context = startedContext(box, { order: { repository: 'gitlab.com/acme/widgets', status: 'implementing' } });
  const send = (url, number, key) => wo.sendEvent(context, ['--stage', 'pr_open', '--pr-url', url, '--pr-number', String(number),
    '--client-event-id', wo.clientEventId('r', key)], { env: box.env, target: 'pr_open' });
  for (const [url, number, key] of [
    ['https://github.com/acme/widgets/pull/7', 7, 'other-host'],
    ['https://gitlab.com/acme/widgets/-/merge_requests/7?x=1', 7, 'query'],
    ['https://gitlab.com/acme/widgets/-/merge_requests/8', 7, 'mismatch'],
    ['https://gitlab.com/acme/widgets/../widgets/-/merge_requests/7', 7, 'dot-segment'],
  ]) {
    const refused = send(url, number, key);
    assert.equal(refused.verdict, wo.VERDICTS.FINAL, url);
    assert.equal(refused.failure.code, 'invalid_pr_url', url);
  }
  assert.equal(send('https://GitLab.com/Acme/Widgets/-/merge_requests/7', 7, 'gitlab').verdict, wo.VERDICTS.OK);
  assert.equal(box.fake().order.pr_url, 'https://gitlab.com/acme/widgets/-/merge_requests/7');
  const second = wo.sendEvent(context, ['--stage', 'reviewing', '--pr-url', 'https://gitlab.com/acme/widgets/-/merge_requests/8', '--pr-number', '8',
    '--client-event-id', wo.clientEventId('r', 'second-pr')], { env: box.env, target: 'reviewing' });
  assert.equal(second.verdict, wo.VERDICTS.FINAL);
  assert.equal(second.failure.code, 'pr_mismatch');
});

test('the fake answers an expired lease with 401 and speaks the service response shapes', () => {
  const box = sandbox();
  const context = startedContext(box, { order: { status: 'implementing' } });
  const upper = 'C'.repeat(40);
  assert.equal(wo.sendEvent(context, ['--stage', 'implementing', '--head', upper, '--client-event-id', wo.clientEventId('r', 'upper')], { env: box.env, target: 'implementing' }).verdict, wo.VERDICTS.OK);
  assert.equal(box.fake().order.head_sha, 'c'.repeat(40));
  const bad = wo.sendEvent(context, ['--stage', 'implementing', '--head', 'abc', '--client-event-id', wo.clientEventId('r', 'bad-head')], { env: box.env, target: 'implementing' });
  assert.equal(bad.failure.code, 'invalid_sha');
  const filed = wo.runZensu(['work', 'followup', ORDER, '--title', 'Cache the list', '--rationale', 'It is read on every request.', '--severity', 'low',
    '--client-event-id', wo.clientEventId('f', 'shape'), '--json'], { env: box.env });
  assert.deepEqual(Object.keys(filed.json).sort(), ['event', 'order', 'replay']);
  const linked = box.fake().pulse.id;
  const pulse = wo.runZensu(['pulse', 'start', '--work-order', ORDER, '--client-name', wo.CLIENT_NAME, '--client-version', '1.0.0', '--json'], { env: box.env });
  assert.match(pulse.json.id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.equal(pulse.json.work_order_id, ORDER);
  assert.deepEqual([pulse.json.id, pulse.json.created], [linked, false]);
  box.mutate((state) => { state.order.attempt = 2; });
  const next = wo.runZensu(['pulse', 'start', '--work-order', ORDER, '--client-name', wo.CLIENT_NAME, '--client-version', '1.0.0', '--json'], { env: box.env });
  assert.equal(next.json.created, true);
  assert.notEqual(next.json.id, linked);
  box.mutate((state) => { state.order.attempt = 1; });
  const events = wo.runZensu(['work', 'events', ORDER, '--page', '1', '--per-page', '50', '--json'], { env: box.env });
  assert.deepEqual(Object.keys(events.json).sort(), ['data', 'page', 'perPage', 'total']);
  box.mutate((state) => { state.now = Date.now() + 3600000; });
  for (const argv of [['work', 'heartbeat', ORDER, '--json'], ['work', 'get', ORDER, '--json'], ['work', 'events', ORDER, '--json'],
    ['work', 'event', ORDER, '--stage', 'implementing', '--client-name', wo.CLIENT_NAME, '--client-version', '1.0.0', '--client-event-id', wo.clientEventId('r', 'late'), '--json']]) {
    const outcome = wo.runZensu(argv, { env: box.env });
    assert.equal(outcome.status, 401, argv.join(' '));
    assert.equal(outcome.code, 'invalid_session_token', argv.join(' '));
  }
});

test('the fake counts follow-ups per attempt, as the service does', () => {
  const box = sandbox();
  const context = startedContext(box);
  const seeded = (attempt) => Array.from({ length: 20 }, (_, index) => ({ title: `Follow-up ${index}`, rationale: 'r', severity: 'low', paths: [], attempt }));
  box.mutate((state) => { state.followups = seeded(1); state.order.attempt = 2; });
  const next = wo.followup(context, { env: box.env, title: 'Index widgets by owner', rationale: 'The owner filter scans the table.', severity: 'medium' });
  assert.equal(next.exit, wo.EXIT.OK, next.message);
  box.mutate((state) => { state.followups = [...seeded(1), ...seeded(2)]; });
  const limited = wo.followup(context, { env: box.env, title: 'Paginate the widget list', rationale: 'Long lists load slowly.', severity: 'low' });
  assert.equal(limited.exit, wo.EXIT.REFUSED);
  assert.match(limited.message, /followup_limit_reached/);
  assert.match(limited.message, /file no more follow-ups in this attempt/);
});

test('push refuses a working branch without the order branch prefix before any forge write', () => {
  const box = sandbox();
  const context = startedContext(box, { order: { status: 'implementing' } });
  const gitEnv = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1', GIT_AUTHOR_NAME: 'Test', GIT_AUTHOR_EMAIL: 'test@example.invalid', GIT_COMMITTER_NAME: 'Test', GIT_COMMITTER_EMAIL: 'test@example.invalid' };
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

test('start stops with exit 3 when the session environment names no Zensu host for the token', () => {
  const box = sandbox();
  box.seed();
  const env = { ...box.env };
  delete env.ZENSU_API_URL;
  const result = wo.start({ env, projectRoot: box.project, sessionKey: box.sessionKey, orderId: ORDER });
  assert.equal(result.exit, wo.EXIT.NO_CLI, result.message);
  assert.match(result.message, /ZENSU_API_URL/);
  assert.doesNotMatch(result.message, /did not answer/);
  assert.equal(wo.loadContext({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey }), null);
  box.mutate((state) => { state.failNext = [{ command: 'get', status: 503, code: 'unavailable', times: 1 }]; });
  const transient = wo.start({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey, orderId: ORDER });
  assert.equal(transient.exit, wo.EXIT.TRANSIENT);
  const malformed = wo.start({ env: { ...box.env, ZENSU_SESSION_TOKEN: 'bad' }, projectRoot: box.project, sessionKey: box.sessionKey, orderId: ORDER });
  assert.equal(malformed.exit, wo.EXIT.NO_CLI, malformed.message);
  assert.match(malformed.message, /must hold a work order session token/);
  assert.match(malformed.message, /zst_ session token of its claim/);
  assert.doesNotMatch(malformed.message, /ZENSU_API_URL/);
  assert.equal(wo.describeFailure({ status: null, message: 'unknown flag: --bogus\n' }), 'the zensu CLI failed without a status: unknown flag: --bogus');
  assert.equal(wo.describeFailure({ status: null, message: '' }), 'no answer from Zensu');
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
    state.questions.push({ id: 'q-answered', work_order_id: ORDER, category: 'technical_choice', question: 'Which queue?', answer: 'Use the existing queue.', status: 'answered', blocking: false });
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

function writeBoundRun(box, stage = 'PLANNING', events = DONE_LEDGER.slice(0, 1)) {
  const dir = path.join(box.project, '.zensu', 'state');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, `autopilot-run-${RUN}.json`), JSON.stringify({
    runId: RUN, stage, events, evidence: {}, workOrder: { orderId: ORDER, attempt: 1, specHash: 'a'.repeat(64) },
  }));
}

const GIT_ENV = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1', GIT_AUTHOR_NAME: 'Test', GIT_AUTHOR_EMAIL: 'test@example.invalid', GIT_COMMITTER_NAME: 'Test', GIT_COMMITTER_EMAIL: 'test@example.invalid' };

function gitProject(box, branch = `wo-${ORDER.slice(0, 8)}`) {
  const remote = path.join(box.root, 'remote.git');
  const git = (...args) => execFileSync('git', args, { encoding: 'utf8', env: GIT_ENV, stdio: ['ignore', 'pipe', 'pipe'] });
  git('init', '-q', '--bare', remote);
  git('-C', box.project, 'init', '-q');
  git('-C', box.project, 'config', 'user.name', 'Test');
  git('-C', box.project, 'config', 'user.email', 'test@example.invalid');
  git('-C', box.project, 'checkout', '-q', '-b', branch);
  git('-C', box.project, 'remote', 'add', 'origin', remote);
  fs.writeFileSync(path.join(box.project, 'README.md'), 'widgets\n');
  git('-C', box.project, 'add', 'README.md');
  git('-C', box.project, 'commit', '-q', '-m', 'init');
  return (...args) => git('-C', box.project, ...args);
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

test('a DONE run whose pr_open stage Zensu refuses ends blocked with worker_error naming the refusal', () => {
  const box = sandbox();
  const context = startedContext(box);
  wo.markerRun(context, RUN);
  writeRun(box, 'OPEN_PR', DONE_LEDGER.slice(0, 7));
  assert.equal(wo.drain(context, { env: box.env }).verdict, wo.VERDICTS.OK);
  writeRun(box, 'DONE', DONE_LEDGER);
  box.mutate((state) => { state.failNext = [{ command: 'event', status: 422, code: 'invalid_pr_url', times: 1 }]; });
  const result = wo.finish(context, { env: box.env });
  assert.equal(result.exit, wo.EXIT.ENDED, result.message);
  assert.match(result.message, /refused the pr_open stage \(status 422, code invalid_pr_url\)/);
  const order = box.fake().order;
  assert.equal(order.blocked_kind, 'worker_error');
  assert.match(order.blocked_reason, /pr open stage with code invalid_pr_url/);
  assert.equal(stageCalls(box).filter((call) => call.stage === 'ready_for_merge').length, 0);
  assert.equal(wo.readState(context.files.ended).delivered, true);
});

test('the post-tool update tells the model when Zensu refuses a stage, and names a lease lost on a drained event', () => {
  const box = sandbox();
  const context = startedContext(box);
  wo.markerRun(context, RUN);
  writeRun(box, 'OPEN_PR', DONE_LEDGER.slice(0, 7));
  assert.equal(wo.drain(context, { env: box.env }).verdict, wo.VERDICTS.OK);
  writeRun(box, 'TEAM_REVIEW', DONE_LEDGER.slice(0, 8));
  box.mutate((state) => { state.failNext = [{ command: 'event', status: 422, code: 'invalid_pr_url', times: 1 }]; });
  const refused = wo.postToolUpdate(context, { tool_name: 'Read', tool_input: {} }, { env: box.env });
  assert.match(refused.additionalContext, /refused the pr_open stage/);
  assert.match(refused.additionalContext, /--finish --reason/);
  box.mutate((state) => { state.staleAttempt = true; });
  const lost = wo.postToolUpdate(context, { tool_name: 'Read', tool_input: {} }, { env: box.env });
  assert.match(lost.additionalContext, /is lost \(stale_attempt\)/);
  assert.equal(wo.forgeWriteVerdict(context).allowed, false);
});

test('a block reason Zensu refuses as prose is sent once more as a safe sentence', () => {
  const box = sandbox();
  const context = startedContext(box);
  wo.markerRun(context, RUN);
  writeRun(box, 'GATES', DONE_LEDGER.slice(0, 4));
  const result = wo.finish(context, { env: box.env, reason: 'npm test fails on the integration branch, so the change cannot be validated.' });
  assert.equal(result.exit, wo.EXIT.ENDED, result.message);
  assert.match(result.message, /refused the stated reason as prose/);
  const order = box.fake().order;
  assert.equal(order.blocked_kind, 'worker_error');
  assert.equal(order.blocked_reason, 'The session ended before its Autopilot run reached a ready pull request.');
  assert.equal(wo.readState(context.files.ended).delivered, true);
  const blocks = stageCalls(box).filter((call) => call.blocked === 'worker_error');
  assert.equal(blocks.length, 2);
  assert.equal(blocks[0].id, blocks[1].id);
});

test('a working branch without the order prefix is left out of drained stages and ready_for_merge, which Zensu then accepts', () => {
  const box = sandbox();
  const context = startedContext(box);
  gitProject(box, 'main');
  wo.markerRun(context, RUN);
  writeRun(box, 'TEAM_REVIEW', DONE_LEDGER.slice(0, 8));
  assert.equal(wo.drain(context, { env: box.env }).verdict, wo.VERDICTS.OK);
  writeRun(box, 'DONE', DONE_LEDGER);
  const result = wo.finish(context, { env: box.env });
  assert.equal(result.exit, wo.EXIT.OK, result.message);
  const calls = stageCalls(box);
  assert.ok(calls.some((call) => call.stage === 'pr_open'));
  assert.ok(calls.some((call) => call.stage === 'ready_for_merge'));
  assert.equal(calls.filter((call) => call.argv.includes('--branch')).length, 0);
  assert.equal(box.fake().order.status, 'ready_for_merge');
});

test('a DONE run whose ready_for_merge Zensu refuses ends blocked with worker_error naming it', () => {
  const box = sandbox();
  const context = startedContext(box);
  wo.markerRun(context, RUN);
  writeRun(box, 'DELIVER', DONE_LEDGER.slice(0, 12));
  assert.equal(wo.drain(context, { env: box.env }).verdict, wo.VERDICTS.OK);
  writeRun(box, 'DONE', DONE_LEDGER);
  box.mutate((state) => { state.failNext = [{ command: 'event', status: 422, code: 'invalid_pr_url', times: 1 }]; });
  const result = wo.finish(context, { env: box.env });
  assert.equal(result.exit, wo.EXIT.ENDED, result.message);
  assert.match(result.message, /refused the ready_for_merge stage \(status 422, code invalid_pr_url\)/);
  const order = box.fake().order;
  assert.equal(order.blocked_kind, 'worker_error');
  assert.match(order.blocked_reason, /ready for merge stage with code invalid_pr_url/);
  assert.equal(stageCalls(box).filter((call) => call.stage === 'ready_for_merge').length, 1);
  assert.equal(wo.readState(context.files.ended).delivered, true);
});

test('a refused stage on a DONE run is named in the block, also when the stated reason or the Stop fallback would hide it', () => {
  for (const variant of ['prose', 'stop']) {
    const box = sandbox();
    const context = startedContext(box);
    wo.markerRun(context, RUN);
    writeRun(box, 'OPEN_PR', DONE_LEDGER.slice(0, 7));
    assert.equal(wo.drain(context, { env: box.env }).verdict, wo.VERDICTS.OK, variant);
    writeRun(box, 'DONE', DONE_LEDGER);
    box.mutate((state) => { state.failNext = [{ command: 'event', status: 422, code: 'invalid_pr_url', times: 1 }]; });
    if (variant === 'prose') {
      const result = wo.finish(context, { env: box.env, reason: 'gh pr view shows the pull request open, but Zensu refused its link.' });
      assert.equal(result.exit, wo.EXIT.ENDED, result.message);
    } else {
      let decided = null;
      for (let stop = 0; stop < 5; stop += 1) {
        decided = wo.stopDecision(context, { env: box.env });
        if (decided.decision !== 'block') break;
      }
      assert.equal(decided.decision, 'allow');
    }
    const order = box.fake().order;
    assert.equal(order.blocked_kind, 'worker_error', variant);
    assert.match(order.blocked_reason, /pr open stage with code invalid_pr_url/, variant);
  }
});

test('a terminal event whose answer never arrived is replayed on the next renewal instead of reading as a lost lease', () => {
  const block = sandbox();
  const blockContext = startedContext(block);
  wo.markerRun(blockContext, RUN);
  writeRun(block, 'GATES', DONE_LEDGER.slice(0, 4));
  assert.equal(wo.drain(blockContext, { env: block.env }).verdict, wo.VERDICTS.OK);
  block.mutate((state) => { state.dropAnswers = 1000; });
  const unanswered = wo.finish(blockContext, { env: block.env, reason: 'The gates fail on a missing database migration.' });
  assert.equal(unanswered.exit, wo.EXIT.TRANSIENT, unanswered.message);
  assert.equal(block.fake().order.blocked_kind, 'worker_error');
  assert.ok(wo.readState(blockContext.files.outbox).inflight);
  block.mutate((state) => { state.dropAnswers = 0; });
  assert.equal(wo.renew(blockContext, { env: block.env, force: true }).verdict, 'ended');
  assert.equal(wo.readState(blockContext.files.lost), null);
  assert.deepEqual([wo.readState(blockContext.files.ended).kind, wo.readState(blockContext.files.ended).delivered], ['blocked:worker_error', true]);
  assert.equal(wo.readState(blockContext.files.outbox).inflight, null);

  const merge = sandbox();
  const mergeContext = startedContext(merge);
  wo.markerRun(mergeContext, RUN);
  writeRun(merge, 'DELIVER', DONE_LEDGER.slice(0, 12));
  assert.equal(wo.drain(mergeContext, { env: merge.env }).verdict, wo.VERDICTS.OK);
  writeRun(merge, 'DONE', DONE_LEDGER);
  merge.mutate((state) => { state.dropAnswers = 1000; });
  assert.equal(wo.finish(mergeContext, { env: merge.env }).exit, wo.EXIT.TRANSIENT);
  merge.mutate((state) => { state.dropAnswers = 0; });
  assert.equal(wo.renew(mergeContext, { env: merge.env, force: true }).verdict, 'ended');
  assert.deepEqual([wo.readState(mergeContext.files.ended).kind, wo.readState(mergeContext.files.ended).outcome], ['ready_for_merge', 'success']);

  const asked = sandbox();
  const askContext = startedContext(asked);
  asked.mutate((state) => { state.dropAnswers = 1000; });
  const question = wo.ask(askContext, { env: asked.env, category: 'clarification', question: 'Should deleted widgets stay visible to admins?', blocking: true });
  assert.equal(question.exit, wo.EXIT.TRANSIENT, question.message);
  asked.mutate((state) => { state.dropAnswers = 0; });
  assert.equal(wo.renew(askContext, { env: asked.env, force: true }).verdict, 'ended');
  assert.equal(wo.readState(askContext.files.ended).kind, 'blocked:question');

  const revoked = sandbox();
  const revokedContext = startedContext(revoked);
  wo.markerRun(revokedContext, RUN);
  writeRun(revoked, 'GATES', DONE_LEDGER.slice(0, 4));
  assert.equal(wo.drain(revokedContext, { env: revoked.env }).verdict, wo.VERDICTS.OK);
  revoked.mutate((state) => { state.dropAnswers = 1000; });
  assert.equal(wo.finish(revokedContext, { env: revoked.env, reason: 'The gates fail on a missing database migration.' }).exit, wo.EXIT.TRANSIENT);
  revoked.mutate((state) => { state.dropAnswers = 0; state.mode = 'revoked'; });
  assert.equal(wo.renew(revokedContext, { env: revoked.env, force: true }).verdict, wo.VERDICTS.LOST);
  assert.ok(wo.readState(revokedContext.files.lost));
});

test('a block Zensu refuses for another reason writes no ended marker, so a later finish still reports it', () => {
  const box = sandbox();
  const context = startedContext(box);
  wo.markerRun(context, RUN);
  writeRun(box, 'GATES', DONE_LEDGER.slice(0, 4));
  assert.equal(wo.drain(context, { env: box.env }).verdict, wo.VERDICTS.OK);
  box.mutate((state) => { state.failNext = [{ command: 'event', status: 422, code: 'field_not_allowed', times: 1 }]; });
  const reason = 'The gates fail on a missing database migration.';
  const refused = wo.finish(context, { env: box.env, reason });
  assert.equal(refused.exit, wo.EXIT.REFUSED);
  assert.equal(wo.readState(context.files.ended), null);
  const delivered = wo.finish(context, { env: box.env, reason });
  assert.equal(delivered.exit, wo.EXIT.ENDED, delivered.message);
  assert.equal(box.fake().order.blocked_kind, 'worker_error');
});

test('a push of an unchanged head after a stage advance gets its own event id, and a refused head is final', () => {
  const box = sandbox();
  const context = startedContext(box, { order: { status: 'implementing' } });
  gitProject(box);
  const first = wo.push(context, { env: box.env });
  assert.equal(first.exit, wo.EXIT.OK, first.message);
  box.mutate((state) => { state.order.status = 'reviewing'; state.order.pr_url = 'https://github.com/acme/widgets/pull/7'; state.order.pr_number = 7; });
  const again = wo.push(context, { env: box.env });
  assert.equal(again.exit, wo.EXIT.OK, again.message);
  const pushes = stageCalls(box).filter((call) => call.argv.includes('--head'));
  assert.deepEqual(pushes.map((call) => call.stage), ['implementing', 'reviewing']);
  assert.notEqual(pushes[0].id, pushes[1].id);
  box.mutate((state) => { state.failNext = [{ command: 'event', status: 409, code: 'client_event_id_reused', times: 1 }]; });
  const refused = wo.push(context, { env: box.env });
  assert.equal(refused.exit, wo.EXIT.REFUSED);
  assert.match(refused.message, /client_event_id_reused/);
});

test('a plan-approval block that Zensu does not need sends the session back to --bind-spec', () => {
  const box = sandbox();
  const context = startedContext(box);
  gitProject(box);
  wo.markerRun(context, RUN);
  writeRun(box, 'PLANNING', DONE_LEDGER.slice(0, 1));
  fs.mkdirSync(path.join(box.project, '.zensu', 'plans'), { recursive: true });
  fs.writeFileSync(path.join(box.project, '.zensu', 'plans', `${ORDER}.md`), '# Plan\n\nRender the widget.\n');
  const result = wo.planApproval(context, { env: box.env });
  assert.equal(result.exit, wo.EXIT.REFUSED, result.message);
  assert.match(result.message, /run --bind-spec/);
  assert.equal(result.cancelRun, undefined);
  assert.equal(wo.readState(context.files.ended), null);
});

test('a plan artifact whose summary Zensu refuses is sent once more with the fixed summary', () => {
  const box = sandbox();
  const context = startedContext(box, { policy: { plan_approval: 'required', lease_minutes: 30, max_questions_per_order: 5, max_order_runtime_minutes: 240 } });
  gitProject(box);
  wo.markerRun(context, RUN);
  writeRun(box, 'PLANNING', DONE_LEDGER.slice(0, 1));
  fs.mkdirSync(path.join(box.project, '.zensu', 'plans'), { recursive: true });
  fs.writeFileSync(path.join(box.project, '.zensu', 'plans', `${ORDER}.md`), '# Plan\n\nRender the widget list.\n');
  box.mutate((state) => { state.failNext = [{ command: 'event', flag: 'artifact', status: 422, code: 'content_not_allowed', message: 'content_not_allowed: detail.summary: code_block; send metadata and short prose only, never code, commands, logs or diffs', times: 1 }]; });
  const result = wo.planApproval(context, { env: box.env });
  assert.equal(result.exit, wo.EXIT.OK, result.message);
  const artifacts = box.fake().events.filter((event) => event.event_type === 'artifact');
  assert.equal(artifacts.length, 1);
  assert.equal(artifacts[0].detail.summary, 'Implementation plan for this work order.');
  assert.equal(artifacts[0].detail.url, `https://github.com/acme/widgets/blob/${artifacts[0].detail.sha}/.zensu/plans/${ORDER}.md`);
  assert.equal(box.fake().order.blocked_kind, 'plan_approval');
});

test('a plan link Zensu refuses as invalid_url is dropped, and the artifact goes once more with path and commit only', () => {
  const box = sandbox();
  const context = startedContext(box, {
    policy: { plan_approval: 'required', lease_minutes: 30, max_questions_per_order: 5, max_order_runtime_minutes: 240 },
    order: { repository: 'github.com/acme/sk-payments-gateway-service' },
  });
  gitProject(box);
  wo.markerRun(context, RUN);
  writeRun(box, 'PLANNING', DONE_LEDGER.slice(0, 1));
  fs.mkdirSync(path.join(box.project, '.zensu', 'plans'), { recursive: true });
  fs.writeFileSync(path.join(box.project, '.zensu', 'plans', `${ORDER}.md`), '# Plan\n\nRender the payment list.\n');
  const result = wo.planApproval(context, { env: box.env });
  assert.equal(result.exit, wo.EXIT.OK, result.message);
  const sent = box.calls().filter((argv) => argv[0] === 'work' && argv[1] === 'event' && argv.includes('--artifact'));
  assert.deepEqual(sent.map((argv) => argv.includes('--url')), [true, false]);
  const artifacts = box.fake().events.filter((event) => event.event_type === 'artifact');
  assert.equal(artifacts.length, 1);
  assert.equal(artifacts[0].detail.url, undefined);
  assert.equal(artifacts[0].detail.path, `.zensu/plans/${ORDER}.md`);
  assert.equal(result.value.link, null);
  assert.equal(box.fake().order.blocked_kind, 'plan_approval');
});

test('the approved plan is the last plan artifact of the attempt whose plan the last approval of the spec hash approved', () => {
  const spec = 'b'.repeat(64);
  const events = [
    { event_type: 'artifact', attempt: 1, detail: { kind: 'plan', sha: '1'.repeat(40), path: '.zensu/plans/x.md' } },
    { event_type: 'approved', attempt: 1, detail: { subject: 'implementation_plan', spec_hash: 'c'.repeat(64) } },
    { event_type: 'artifact', attempt: 2, detail: { kind: 'report', sha: '9'.repeat(40), path: 'r.md' } },
    { event_type: 'artifact', attempt: 2, detail: JSON.stringify({ kind: 'plan', sha: '2'.repeat(40), path: '.zensu/plans/x.md' }) },
    { event_type: 'approved', attempt: 2, detail: { subject: 'implementation_plan', spec_hash: spec } },
    { event_type: 'artifact', attempt: 3, detail: { kind: 'plan', sha: '3'.repeat(40), path: '.zensu/plans/x.md' } },
  ];
  assert.equal(wo.approvedPlanCommit(events, spec).sha, '2'.repeat(40));
  assert.equal(wo.approvedPlanCommit(events, 'd'.repeat(64)), null);
  const fastClock = [
    { event_type: 'approved', attempt: 1, detail: { subject: 'implementation_plan', spec_hash: spec } },
    { event_type: 'artifact', attempt: 1, detail: { kind: 'plan', sha: '4'.repeat(40), path: '.zensu/plans/x.md' } },
    { event_type: 'blocked', attempt: 1, detail: { blocked_kind: 'plan_approval' } },
  ];
  assert.equal(wo.approvedPlanCommit(fastClock, spec).sha, '4'.repeat(40));
  const recut = [
    { event_type: 'artifact', attempt: 1, detail: { kind: 'plan', sha: '5'.repeat(40), path: '.zensu/plans/x.md' } },
    { event_type: 'approved', attempt: 1, detail: { subject: 'implementation_plan', spec_hash: 'c'.repeat(64) } },
    { event_type: 'approved', attempt: 2, detail: { subject: 'implementation_plan', spec_hash: spec } },
    { event_type: 'artifact', attempt: 2, detail: { kind: 'plan', sha: '6'.repeat(40), path: '.zensu/plans/x.md' } },
  ];
  assert.equal(wo.approvedPlanCommit(recut, spec).sha, '6'.repeat(40));
  assert.equal(wo.approvedPlanCommit([{ event_type: 'approved', attempt: 1, detail: { subject: 'implementation_plan', spec_hash: spec } }], spec), null);
});

test('bind-spec blocks an order Zensu marked spec_stale although its spec hash is unchanged', () => {
  const box = sandbox();
  const context = startedContext(box);
  wo.markerRun(context, RUN);
  writeBoundRun(box);
  box.mutate((state) => { state.order.spec_stale = true; });
  const result = wo.bindSpec(context, { env: box.env, runId: RUN });
  assert.equal(result.exit, wo.EXIT.ENDED, result.message);
  const order = box.fake().order;
  assert.equal(order.blocked_kind, 'worker_error');
  assert.match(order.blocked_reason, /spec changed while the session ran/);
  assert.equal(stageCalls(box).filter((call) => call.stage === 'implementing').length, 0);
});

test('bind-spec refuses a working branch without the order branch prefix before it sends any event', () => {
  const box = sandbox();
  const context = startedContext(box);
  gitProject(box, 'feature/widgets');
  wo.markerRun(context, RUN);
  writeBoundRun(box);
  const result = wo.bindSpec(context, { env: box.env, runId: RUN });
  assert.equal(result.exit, wo.EXIT.REFUSED, result.message);
  assert.match(result.message, /feature\/widgets does not start with wo-/);
  assert.match(result.message, /workBranch/);
  assert.equal(stageCalls(box).length, 0);
  assert.equal(wo.readState(context.files.ended), null);
});

test('bind-spec and plan-approval exit 8 on a refused planning stage, and a spec-change block keeps a refusal or a lost lease apart', () => {
  for (const verb of ['bindSpec', 'planApproval']) {
    const box = sandbox();
    const context = startedContext(box);
    wo.markerRun(context, RUN);
    writeBoundRun(box);
    fs.mkdirSync(path.join(box.project, '.zensu', 'plans'), { recursive: true });
    fs.writeFileSync(path.join(box.project, '.zensu', 'plans', `${ORDER}.md`), '# Plan\n\nRender the widget.\n');
    box.mutate((state) => { state.failNext = [{ command: 'event', status: 422, code: 'invalid_autopilot_run_id', times: 1 }]; });
    const result = wo[verb](context, { env: box.env, runId: RUN });
    assert.equal(result.exit, wo.EXIT.REFUSED, `${verb}: ${result.message}`);
    assert.match(result.message, /refused the planning stage \(status 422, code invalid_autopilot_run_id\)/, verb);
  }
  for (const [status, code, exit] of [[422, 'field_not_allowed', wo.EXIT.REFUSED], [401, 'invalid_session_token', wo.EXIT.LOST]]) {
    const box = sandbox();
    const context = startedContext(box);
    wo.markerRun(context, RUN);
    writeBoundRun(box);
    box.mutate((state) => { state.order.spec_stale = true; state.failNext = [{ command: 'event', flag: 'blocked', status, code, times: 1 }]; });
    const result = wo.bindSpec(context, { env: box.env, runId: RUN });
    assert.equal(result.exit, exit, `${code}: ${result.message}`);
    assert.notEqual(box.fake().order.status, 'blocked', code);
    if (exit === wo.EXIT.LOST) {
      assert.ok(wo.readState(context.files.lost), code);
    } else {
      assert.equal(wo.readState(context.files.ended), null, code);
      assert.equal(wo.readState(context.files.lost), null, code);
    }
  }
});

test('bind-spec hands over a plan-wide decision made after --start, and an automatic answer is no plan-wide decision', () => {
  const box = sandbox();
  const context = startedContext(box);
  wo.markerRun(context, RUN);
  writeBoundRun(box);
  const sibling = { work_plan_id: '11111111-1111-4111-8111-111111111111', work_order_id: '33333333-3333-4333-8333-333333333333', scope: 'plan', category: 'product_decision' };
  box.mutate((state) => {
    state.questions = [
      { ...sibling, id: 'q-auto', question: 'Which date format do lists use?', answer: 'Lists use the ISO date format.', status: 'auto_answered' },
      { ...sibling, id: 'q-later', question: 'Which currency do prices use?', answer: 'Prices are in euro across the plan.', status: 'answered' },
    ];
  });
  const bound = wo.bindSpec(context, { env: box.env, runId: RUN });
  assert.equal(bound.exit, wo.EXIT.OK, bound.message);
  const update = wo.postToolUpdate(context, { tool_name: 'Read', tool_input: {} }, { env: box.env });
  assert.match(update.additionalContext, /decided these questions for the whole work plan/);
  assert.match(update.additionalContext, /Prices are in euro across the plan/);
  assert.doesNotMatch(update.additionalContext, /ISO date format/);
});

test('the plan blob link takes the scheme-less repository Zensu stores and an https one alike', () => {
  const sha = 'e'.repeat(40);
  const file = `.zensu/plans/${ORDER}.md`;
  assert.equal(wo.blobLink('github.com/acme/widgets', sha, file), `https://github.com/acme/widgets/blob/${sha}/${file}`);
  assert.equal(wo.blobLink('https://github.com/acme/widgets.git', sha, file), `https://github.com/acme/widgets/blob/${sha}/${file}`);
  assert.equal(wo.blobLink('gitlab.com/group/project', sha, file), `https://gitlab.com/group/project/-/blob/${sha}/${file}`);
  assert.equal(wo.blobLink('bitbucket.org/acme/widgets', sha, file), null);
  assert.equal(wo.blobLink('http://github.com/acme/widgets', sha, file), null);
  assert.equal(wo.blobLink('', sha, file), null);
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
    'zensu work policy get --product p1': 'order-file',
    'zensu work list': 'order-file',
    'zensu work questions --plan p1': 'order-file',
    'zensu work repositories list --product p1': 'order-file',
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
    'env -i HOME=x zensu work get 1': 'token',
    'env - HOME=x zensu products list': 'token',
    'env --ignore-environment zensu work get 1': 'token',
    'env -vi zensu work get 1': 'token',
    'zensu --api-url https://h work event 1 --stage implementing': 'token-host',
    "zensu --api-url '' work heartbeat 1": 'token-host',
    'zensu --api-url=https://h work get 1': 'token-host',
    'ZENSU_API_URL=https://h zensu work get 1': 'token-host',
    'CLAUDE_PLUGIN_DATA=x ZENSU_API_URL=https://h bash "$WO" --start --order 1': 'token-host',
    'export ZENSU_API_URL=https://h': 'token-host',
    'unset ZENSU_API_URL': 'token-host',
    'env -u ZENSU_API_URL zensu work get 1': 'token-host',
    "zensu $'work' event 1 --stage ready_for_merge": 'helper-verb',
    'zensu $"work" heartbeat 1': 'helper-verb',
    "zensu $'\\x77ork' heartbeat 1": 'helper-verb',
    "$'git' push origin HEAD": 'push',
    "gh $'pr' create --fill": 'open-pr',
    "bash -c -- 'git push'": 'shell-option',
    "bash -c -e 'zensu work event 1'": 'shell-option',
  };
  for (const [command, code] of Object.entries(denied)) {
    const analysis = wo.analyzeBash(command);
    assert.ok(analysis.deny, command);
    assert.equal(analysis.deny.code, code, command);
  }
  const allowed = [
    'git status', 'git commit -m "do not git push here"', 'git log --oneline -3', 'printenv PATH', 'set -e',
    'export PATH=/usr/bin:$PATH', 'zensu work get 1234 --json', 'zensu work ask 1234 --category scope --question "Which?" --default-option a',
    'zensu work followup 1234 --title t --rationale r --severity low', 'zensu work events 1234 --json', 'gh pr view 7', 'echo hello',
    "cat <<'MSG' > /tmp/m\ngit push is a step\nMSG", 'local x=1', 'echo $ZENSU_API_URL', "echo $'a\\tb'", 'env -0 zensu work get 1',
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

test('ask refuses inputs Zensu would refuse before it runs the CLI', () => {
  const box = sandbox();
  const context = startedContext(box);
  const base = { env: box.env, category: 'technical_choice', question: 'Which queue library should the worker use?', options: ['pg-boss', 'bullmq'], defaultOption: 'pg-boss' };
  const cases = [
    [{ defaultOption: 'pg-boss (recommended)' }, /--default-option must repeat one --option verbatim/],
    [{ category: 'design' }, /--category must be one of clarification/],
    [{ options: Array.from({ length: 11 }, (_, index) => `option ${index}`), defaultOption: 'option 0' }, /at most 10 times/],
    [{ options: ['pg-boss', ' pg-boss '] }, /given twice/],
    [{ options: ['pg-boss', 'x'.repeat(301)] }, /at most 300 bytes/],
    [{ options: ['pg-boss', ' '] }, /every --option needs text/],
    [{ requirements: ['AC-1'] }, /must look like AC-001/],
  ];
  for (const [overrides, rule] of cases) {
    const result = wo.ask(context, { ...base, ...overrides });
    assert.equal(result.exit, wo.EXIT.USAGE, JSON.stringify(overrides).slice(0, 80));
    assert.match(result.message, rule);
  }
  assert.equal(box.calls().filter((argv) => argv[0] === 'work' && argv[1] === 'ask').length, 0);
});

test('ask takes one requirement id per flag, while the fake splits a comma-joined value as the CLI does', () => {
  const box = sandbox();
  const context = startedContext(box);
  const refused = wo.ask(context, { env: box.env, category: 'clarification', question: 'Should deleted widgets stay visible?', options: ['no', 'yes'], defaultOption: 'no', requirements: ['AC-001,AC-002'] });
  assert.equal(refused.exit, wo.EXIT.USAGE);
  assert.match(refused.message, /one id per flag/);
  assert.equal(box.calls().filter((argv) => argv[0] === 'work' && argv[1] === 'ask').length, 0);
  const split = wo.runZensu(['work', 'ask', ORDER, '--category', 'clarification', '--question', 'Should deleted widgets stay visible?',
    '--option', 'no', '--default-option', 'no', '--requirement', 'AC-001,AC-002', '--client-event-id', wo.clientEventId('ask', 'split'), '--json'], { env: box.env });
  assert.equal(split.exitCode, 0, split.message);
  assert.deepEqual(box.fake().questions[0].requirement_ids, ['AC-001', 'AC-002']);
});

test('the fake refuses a question the way the service does', () => {
  const box = sandbox();
  startedContext(box);
  const ask = (extra) => wo.runZensu(['work', 'ask', ORDER, '--category', 'technical_choice', '--question', 'Which queue library should the worker use?',
    '--client-event-id', wo.clientEventId('ask', JSON.stringify(extra)), ...extra, '--json'], { env: box.env });
  const cases = [
    [[...Array.from({ length: 11 }, (_, index) => ['--option', `option ${index}`]).flat(), '--default-option', 'option 0'], 'invalid_options'],
    [['--option', 'a', '--option', 'a', '--default-option', 'a'], 'invalid_options'],
    [['--option', 'x'.repeat(301), '--default-option', 'x'.repeat(301)], 'content_not_allowed'],
    [['--option', 'a', '--option', 'b', '--default-option', 'c'], 'invalid_default'],
    [['--option', 'a', '--default-option', 'a', '--requirement', 'AC-1'], 'invalid_requirements'],
  ];
  for (const [extra, code] of cases) {
    const outcome = ask(extra);
    assert.equal(outcome.status, 422, code);
    assert.equal(outcome.code, code);
  }
  const category = wo.runZensu(['work', 'ask', ORDER, '--category', 'design', '--question', 'Which queue?', '--default-option', 'a', '--json'], { env: box.env });
  assert.equal(category.code, 'invalid_category');
  assert.equal(box.fake().questions.length, 0);
});

test('a question asked again as blocking is a new question, and only a blocking scope question blocks with spec_change', () => {
  const box = sandbox();
  const context = startedContext(box);
  const scope = wo.ask(context, { env: box.env, category: 'scope', question: 'Should archived widgets be listed too?', options: ['no', 'yes'], defaultOption: 'no' });
  assert.equal(scope.exit, wo.EXIT.OK, scope.message);
  assert.equal(scope.value.ended, false);
  assert.equal(box.fake().order.status, 'claimed');
  const escalated = wo.ask(context, { env: box.env, category: 'scope', question: 'Should archived widgets be listed too?', blocking: true });
  assert.equal(escalated.exit, wo.EXIT.ENDED, escalated.message);
  assert.equal(escalated.value.replay, false);
  assert.equal(box.fake().questions.length, 2);
  assert.equal(box.fake().order.blocked_kind, 'spec_change');
  assert.equal(wo.readState(context.files.ended).kind, 'blocked:spec_change');
});

test('a question past the order limit escalates the order and ends the session', () => {
  const box = sandbox();
  const context = startedContext(box, { policy: { plan_approval: 'auto', lease_minutes: 30, max_questions_per_order: 1, max_order_runtime_minutes: 240 } });
  const first = wo.ask(context, { env: box.env, category: 'clarification', question: 'Should the list paginate?', options: ['yes', 'no'], defaultOption: 'yes' });
  assert.equal(first.exit, wo.EXIT.OK, first.message);
  const second = wo.ask(context, { env: box.env, category: 'clarification', question: 'Should the list sort by name?', options: ['yes', 'no'], defaultOption: 'yes' });
  assert.equal(second.exit, wo.EXIT.ENDED, second.message);
  assert.equal(box.fake().order.blocked_kind, 'escalated');
  assert.equal(wo.readState(context.files.ended).kind, 'blocked:escalated');
});

test('a decision a person made for the whole plan reaches the model as a plan-wide decision, and heartbeats carry only this order', () => {
  const box = sandbox();
  box.seed({
    questions: [
      { id: 'q-sibling', work_plan_id: '11111111-1111-4111-8111-111111111111', work_order_id: '33333333-3333-4333-8333-333333333333', scope: 'plan', category: 'product_decision', question: 'Which currency do prices use?', answer: 'Prices are in euro across the plan.', status: 'answered' },
      { id: 'q-sibling-local', work_plan_id: '11111111-1111-4111-8111-111111111111', work_order_id: '33333333-3333-4333-8333-333333333333', scope: 'order', category: 'clarification', question: 'Which table holds sizes?', answer: 'The sizes table.', status: 'answered' },
    ],
  });
  const started = wo.start({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey, orderId: ORDER });
  assert.equal(started.exit, wo.EXIT.OK, started.message);
  const context = wo.loadContext({ env: box.env, projectRoot: box.project, sessionKey: box.sessionKey });
  const beat = wo.renew(context, { env: box.env, force: true });
  assert.deepEqual(beat.answers, []);
  const update = wo.postToolUpdate(context, { tool_name: 'Read', tool_input: {} }, { env: box.env });
  assert.match(update.additionalContext, /decided these questions for the whole work plan/);
  assert.match(update.additionalContext, /Prices are in euro across the plan/);
  assert.doesNotMatch(update.additionalContext, /sizes table/);
  assert.doesNotMatch(update.additionalContext, /this order asked earlier/);
  assert.equal(wo.postToolUpdate(context, { tool_name: 'Read', tool_input: {} }, { env: box.env }).additionalContext, null);
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

test('followup refuses inputs the CLI or Zensu would refuse before it runs the CLI', () => {
  const box = sandbox();
  const context = startedContext(box);
  const base = { env: box.env, title: 'Add an index on widgets.owner_id', rationale: 'The list query scans the table.', severity: 'medium' };
  const cases = [
    [{ severity: 'major' }, /--severity must be one of low, medium, high, critical/],
    [{ paths: ['src/auth/'] }, /clean relative file path/],
    [{ paths: ['./src/a.ts'] }, /clean relative file path/],
    [{ paths: ['src/**'] }, /clean relative file path/],
    [{ paths: Array.from({ length: 21 }, (_, index) => `src/file${index}.ts`) }, /at most 20 times/],
    [{ title: 'x'.repeat(201) }, /--title holds at most 200 bytes/],
  ];
  for (const [overrides, rule] of cases) {
    const result = wo.followup(context, { ...base, ...overrides });
    assert.equal(result.exit, wo.EXIT.USAGE, JSON.stringify(overrides).slice(0, 80));
    assert.match(result.message, rule);
  }
  assert.equal(box.calls().filter((argv) => argv[0] === 'work' && argv[1] === 'followup').length, 0);
  const filed = wo.followup(context, { ...base, paths: ['src/widgets/list.ts', '.github/workflows/ci.yml'] });
  assert.equal(filed.exit, wo.EXIT.OK, filed.message);
});

test('a refused question or follow-up names the rule Zensu gave and what to shorten', () => {
  const box = sandbox();
  const context = startedContext(box);
  box.mutate((state) => { state.failNext = [{ command: 'followup', status: 422, code: 'content_not_allowed', message: 'content_not_allowed: rationale: too_long; send metadata and short prose only, never code, commands, logs or diffs', times: 1 }]; });
  const followup = wo.followup(context, { env: box.env, title: 'Cache the widget list', rationale: 'The list is read on every request.', severity: 'low' });
  assert.equal(followup.exit, wo.EXIT.REFUSED);
  assert.match(followup.message, /content_not_allowed: rationale: too_long/);
  assert.match(followup.message, /shorten rationale and file it again/);
  const asked = wo.ask(context, { env: box.env, category: 'technical_choice', question: 'git checkout the old branch first?', options: ['yes', 'no'], defaultOption: 'no' });
  assert.equal(asked.exit, wo.EXIT.REFUSED);
  assert.match(asked.message, /question: command_line/);
  assert.match(asked.message, /rewrite it as plain prose and ask again/);
  const filed = wo.followup(context, { env: box.env, title: 'Cache the widget list', rationale: 'The list is read on every request.', severity: 'low' });
  assert.equal(filed.exit, wo.EXIT.OK, filed.message);
  const refiled = wo.followup(context, { env: box.env, title: 'Cache the widget list', rationale: 'npm install fails on the list page', severity: 'low' });
  assert.equal(refiled.exit, wo.EXIT.REFUSED, refiled.message);
  assert.match(refiled.message, /rationale: command_line/);
  assert.equal(box.fake().followups.length, 1);
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
  const { proseViolation } = require(FAKE);
  for (const plan of [
    '# Plan: Highlight <code> blocks\nWrap logs in <pre> tags.\nTraceback (most recent call last) stays visible.',
    'Exception in thread "main" is logged\u2028goroutine 7 [running]\u0085panic: boom',
    'npm install x\n$ make\n- git push origin main\n    indented\n    twice\n    thrice',
    'diff --git a/x b/x\n@@ -1,2 +1,2 @@\n--- a/x\n+++ b/x',
  ]) {
    const text = wo.planSummary(plan);
    assert.equal(proseViolation(text), null, text);
    assert.doesNotMatch(text, /<(pre|code)|Traceback \(|Exception in thread "|goroutine \d+ \[/);
  }
});

test('the fake guards prose with the service rules in both directions and with the per-field caps', () => {
  const { proseViolation } = require(FAKE);
  for (const text of ['pnpm install fails', '$ make', '<code>x</code>', 'Traceback (most recent call last)', '- npm install x', 'Run `git push --force` now', 'C:\\> dir']) {
    assert.notEqual(proseViolation(text), null, text);
  }
  for (const text of ['go ahead with the default', 'node version 20', 'make test fails', 'Use ``` fences in docs', 'make sure the index exists']) {
    assert.equal(proseViolation(text), null, text);
  }
  assert.equal(proseViolation('x'.repeat(201), 200), 'too_long');
  assert.equal(proseViolation('x'.repeat(301), 300), 'too_long');
  assert.equal(proseViolation('tab\there', 300), null);
  assert.equal(proseViolation('bell\u0007', 300), 'control_characters');
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
