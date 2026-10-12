'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const SCHEMA_VERSION = 1;
const CLIENT_NAME = 'zensu-claude-code';
const SUPPORTED_KINDS = Object.freeze(['implement']);
const STATE_SEGMENTS = Object.freeze(['.zensu', 'state', 'work-order']);
const MAX_STATE_BYTES = 1024 * 1024;
const MAX_PENDING_ANSWERS = 50;
const MAX_ANSWER_CHARS = 4000;
const RENEW_CEILING_MS = 60000;
const CLI_TIMEOUT_MS = 30000;
const DEFAULT_RETRY_BASE_MS = 2000;
const DEFAULT_RETRY_BUDGET_MS = 150000;
const STAGE_RANK = Object.freeze({
  claimed: 0,
  planning: 1,
  implementing: 2,
  pr_open: 3,
  reviewing: 4,
  validating: 5,
  ready_for_merge: 6,
});
const SESSION_KEY_RE = /^scv1_[a-f0-9]{64}$/;
const ORDER_ID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const CLI_CODE_RE = /^[a-z][a-z0-9_]{0,63}$/;
const CLI_SUFFIX_RE = /\(status (\d{3})(?:, code ([a-z][a-z0-9_]{0,63}))?\)[ \t]*$/;
const CLI_RAW_RE = /^error: request failed \(status (\d{3})(?:, code ([a-z][a-z0-9_]{0,63}))?\):/;
const LOST_CODES = new Set([
  'stale_attempt',
  'runtime_cap',
  'invalid_session_token',
  'session_order_mismatch',
  'session_token_required',
  'work_orders_disabled',
]);
const RETRY_CODES = new Set(['claim_not_confirmed', 'event_in_flight', 'draining']);
const VERDICTS = Object.freeze({
  OK: 'ok',
  LOST: 'lost',
  RETRY: 'retry',
  FINAL: 'final',
  TRANSIENT: 'transient',
  AMBIGUOUS: 'ambiguous',
});
const EXIT = Object.freeze({
  OK: 0,
  USAGE: 2,
  NO_CLI: 3,
  LOST: 4,
  NOT_BOUND: 5,
  ENDED: 6,
  TRANSIENT: 7,
  REFUSED: 8,
});

const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

function pluginVersion() {
  try {
    const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', '.claude-plugin', 'plugin.json'), 'utf8'));
    return typeof manifest.version === 'string' && manifest.version ? manifest.version : '0.0.0';
  } catch (_) {
    return '0.0.0';
  }
}

function sessionKeyOf(rawSessionId) {
  if (typeof rawSessionId !== 'string' || rawSessionId.length === 0) return null;
  try {
    return require('./session-control-core-v1.js').sessionKey(rawSessionId);
  } catch (_) {
    return null;
  }
}

function tokenPresent(env) {
  return isObject(env) && typeof env.ZENSU_SESSION_TOKEN === 'string' && env.ZENSU_SESSION_TOKEN.length > 0;
}

function sessionFiles(projectRoot, sessionKey) {
  if (typeof projectRoot !== 'string' || !path.isAbsolute(projectRoot)) {
    throw new Error('work-order project root must be an absolute path');
  }
  if (!SESSION_KEY_RE.test(String(sessionKey || ''))) {
    throw new Error('work-order session key is invalid');
  }
  const dir = path.join(projectRoot, ...STATE_SEGMENTS);
  const id = sessionKey.slice('scv1_'.length);
  const named = (stem) => path.join(dir, `${stem}-${id}.json`);
  return {
    dir,
    marker: named('marker'),
    order: named('order'),
    lease: named('lease'),
    lost: named('lost'),
    ended: named('ended'),
    outbox: named('outbox'),
    answers: named('answers'),
  };
}

function ensureStateDir(projectRoot) {
  let current = projectRoot;
  for (const segment of STATE_SEGMENTS) {
    current = path.join(current, segment);
    try {
      fs.mkdirSync(current, { mode: 0o700 });
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
    }
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink() || !stat.isDirectory()) {
      throw new Error(`unsafe work-order state directory: ${segment}`);
    }
  }
  return current;
}

function readState(file) {
  let stat;
  try {
    stat = fs.lstatSync(file);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
  if (!stat.isFile() || stat.nlink !== 1 || stat.size > MAX_STATE_BYTES) {
    throw new Error(`unsafe work-order state file: ${path.basename(file)}`);
  }
  let value;
  try {
    value = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    throw new Error(`unreadable work-order state file: ${path.basename(file)}`);
  }
  if (!isObject(value) || value.schemaVersion !== SCHEMA_VERSION) {
    throw new Error(`invalid work-order state file: ${path.basename(file)}`);
  }
  return value;
}

function stateBody(value) {
  const body = `${JSON.stringify({ ...value, schemaVersion: SCHEMA_VERSION }, null, 2)}\n`;
  if (Buffer.byteLength(body) > MAX_STATE_BYTES) throw new Error('work-order state exceeds its size bound');
  return body;
}

function writeTemp(file, body) {
  const temp = `${file}.tmp-${process.pid}-${crypto.randomBytes(6).toString('hex')}`;
  const fd = fs.openSync(temp, 'wx', 0o600);
  try {
    fs.writeFileSync(fd, body, 'utf8');
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  return temp;
}

function writeState(projectRoot, file, value) {
  ensureStateDir(projectRoot);
  const temp = writeTemp(file, stateBody(value));
  try {
    fs.renameSync(temp, file);
  } catch (error) {
    try { fs.unlinkSync(temp); } catch (_) {}
    throw error;
  }
}

function createOnce(projectRoot, file, value) {
  ensureStateDir(projectRoot);
  const temp = writeTemp(file, stateBody(value));
  try {
    fs.linkSync(temp, file);
    return true;
  } catch (error) {
    if (error.code === 'EEXIST') return false;
    try {
      fs.copyFileSync(temp, file, fs.constants.COPYFILE_EXCL);
      return true;
    } catch (copyError) {
      if (copyError.code === 'EEXIST') return false;
      throw copyError;
    }
  } finally {
    try { fs.unlinkSync(temp); } catch (_) {}
  }
}

function loadContext({ env = process.env, projectRoot, sessionKey } = {}) {
  if (!tokenPresent(env)) return null;
  if (typeof projectRoot !== 'string' || !path.isAbsolute(projectRoot)) return null;
  if (!SESSION_KEY_RE.test(String(sessionKey || ''))) return null;
  const files = sessionFiles(projectRoot, sessionKey);
  let marker;
  try {
    marker = readState(files.marker);
  } catch (error) {
    return { projectRoot, sessionKey, files, marker: null, fault: error.message };
  }
  if (!marker) return null;
  if (marker.sessionKey !== sessionKey || marker.clientSessionKey !== sessionKey
      || !ORDER_ID_RE.test(String(marker.orderId || '')) || !Number.isSafeInteger(marker.attempt) || marker.attempt < 1) {
    return { projectRoot, sessionKey, files, marker: null, fault: 'the work-order marker does not bind this session' };
  }
  return { projectRoot, sessionKey, files, marker, fault: null };
}

function cliOutcome(spawned) {
  if (spawned.error) {
    return {
      exitCode: null,
      stdout: '',
      stderr: '',
      status: null,
      code: null,
      message: spawned.error.code === 'ENOENT' ? 'the zensu CLI is not on PATH' : 'the zensu CLI did not answer in time',
      missing: spawned.error.code === 'ENOENT',
    };
  }
  const stdout = typeof spawned.stdout === 'string' ? spawned.stdout : '';
  const stderr = typeof spawned.stderr === 'string' ? spawned.stderr : '';
  const lines = stderr.split(/\r?\n/).filter((line) => line.trim() !== '');
  const errorLine = lines.filter((line) => line.startsWith('error:')).pop() || '';
  const parsed = spawned.status === 0 ? { status: null, code: null } : parseCliError(lines, errorLine);
  return {
    exitCode: spawned.status,
    stdout,
    stderr,
    status: parsed.status,
    code: parsed.code,
    message: (parsed.message || errorLine.replace(/^error:\s*/, '')).slice(0, 500),
    missing: false,
  };
}

function parseCliError(lines, errorLine) {
  const last = lines.length > 0 ? lines[lines.length - 1].trim() : '';
  if (last.startsWith('{')) {
    try {
      const body = JSON.parse(last);
      if (isObject(body) && isObject(body.error)) {
        const status = Number.isSafeInteger(body.error.status) && body.error.status >= 100 && body.error.status <= 599
          ? body.error.status : null;
        const code = typeof body.error.code === 'string' && CLI_CODE_RE.test(body.error.code) ? body.error.code : null;
        const message = typeof body.error.message === 'string' ? body.error.message : '';
        return { status, code, message };
      }
    } catch (_) {}
  }
  const raw = CLI_RAW_RE.exec(errorLine);
  const suffix = raw ? null : CLI_SUFFIX_RE.exec(errorLine);
  const match = raw || suffix;
  if (!match) return { status: null, code: null, message: '' };
  return { status: Number(match[1]), code: match[2] || null, message: '' };
}

function runZensu(args, { env = process.env, cwd, timeoutMs = CLI_TIMEOUT_MS } = {}) {
  const spawned = spawnSync('zensu', args, {
    env,
    cwd,
    encoding: 'utf8',
    timeout: timeoutMs,
    maxBuffer: 32 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
    windowsHide: true,
  });
  const outcome = cliOutcome(spawned);
  outcome.json = null;
  if (outcome.exitCode === 0 && args.includes('--json')) {
    try {
      outcome.json = JSON.parse(outcome.stdout);
    } catch (_) {
      outcome.json = null;
    }
  }
  return outcome;
}

function classifyFailure(outcome) {
  if (outcome && outcome.exitCode === 0) return { verdict: VERDICTS.OK, status: null, code: null };
  const status = outcome ? outcome.status : null;
  const code = outcome ? outcome.code : null;
  if (status === null) return { verdict: VERDICTS.TRANSIENT, status, code };
  if (status === 401) return { verdict: VERDICTS.LOST, status, code };
  if (code) {
    if (LOST_CODES.has(code)) return { verdict: VERDICTS.LOST, status, code };
    if (RETRY_CODES.has(code)) return { verdict: VERDICTS.RETRY, status, code };
    if (status === 429 || status >= 500) return { verdict: VERDICTS.TRANSIENT, status, code };
    return { verdict: VERDICTS.FINAL, status, code };
  }
  if (status === 403 || status === 404) return { verdict: VERDICTS.LOST, status, code };
  if (status === 409) return { verdict: VERDICTS.AMBIGUOUS, status, code };
  if (status === 429 || status >= 500) return { verdict: VERDICTS.TRANSIENT, status, code };
  return { verdict: VERDICTS.FINAL, status, code };
}

function describeFailure(failure) {
  if (!failure || failure.status === null) return 'no answer from Zensu';
  return failure.code ? `status ${failure.status}, code ${failure.code}` : `status ${failure.status}`;
}

function clientEventId(...parts) {
  const digest = crypto.createHash('sha256').update(JSON.stringify(parts.map(String))).digest('hex');
  return `zcc-${digest.slice(0, 40)}`;
}

function stageForLedgerEvent(event) {
  if (!isObject(event)) return null;
  switch (event.eventType) {
    case 'START':
      return 'planning';
    case 'ORDER_SPEC_BOUND':
      return 'implementing';
    case 'PR_OPEN_REQUESTED':
      return null;
    case 'PR_OPENED':
    case 'ORDER_PR_IMPORTED':
      return 'pr_open';
    case 'DELIVERY_COMPLETE':
      return 'ready_for_merge';
    default:
      break;
  }
  switch (event.toStage) {
    case 'AWAIT_TDD':
    case 'TDD_RUNNING':
    case 'GATES':
    case 'CONVERGE':
    case 'OPEN_PR':
      return 'implementing';
    case 'TEAM_REVIEW':
    case 'FIX_FINDINGS':
      return 'reviewing';
    case 'VALIDATE':
    case 'COVER':
      return 'validating';
    default:
      return null;
  }
}

function planStageEvents(run, deliveredRank = 0) {
  if (!isObject(run) || !Array.isArray(run.events)) return [];
  const planned = [];
  let rank = Number.isSafeInteger(deliveredRank) ? deliveredRank : 0;
  for (const event of run.events) {
    const status = stageForLedgerEvent(event);
    if (!status) continue;
    const nextRank = STAGE_RANK[status];
    if (nextRank <= rank) continue;
    rank = nextRank;
    planned.push({
      status,
      rank: nextRank,
      autopilotStage: event.toStage,
      autopilotEventId: event.eventId,
      clientEventId: clientEventId(run.runId, event.eventId),
      pr: (event.eventType === 'PR_OPENED' || event.eventType === 'ORDER_PR_IMPORTED') && isObject(event.payload)
        && isObject(event.payload.pr) ? event.payload.pr : null,
      headSha: event.eventType === 'DELIVERY_COMPLETE' && isObject(event.payload) ? event.payload.headSha : null,
    });
  }
  return planned;
}

function renewInterval(leaseSeconds) {
  if (!(Number.isFinite(leaseSeconds) && leaseSeconds > 0)) return 0;
  return Math.min(RENEW_CEILING_MS, Math.floor((leaseSeconds * 1000) / 5));
}

function renewDue(lease, now) {
  if (!isObject(lease) || !Number.isFinite(lease.lastSuccessAt)) return true;
  return now - lease.lastSuccessAt >= renewInterval(lease.leaseSeconds);
}

function leaseExpired(lease, now) {
  if (!isObject(lease) || !Number.isFinite(lease.lastSuccessAt) || !(lease.leaseSeconds > 0)) return true;
  return now - lease.lastSuccessAt > lease.leaseSeconds * 1000;
}

function safeRead(file) {
  try {
    return { value: readState(file), fault: null };
  } catch (error) {
    return { value: null, fault: error.message };
  }
}

function forgeWriteVerdict(context, now = Date.now()) {
  if (!context) return { allowed: true, reason: null };
  if (context.fault) return { allowed: false, reason: context.fault };
  const lost = safeRead(context.files.lost);
  if (lost.fault || lost.value) {
    const code = lost.value && typeof lost.value.code === 'string' ? lost.value.code : 'unreadable lease-lost marker';
    return { allowed: false, reason: `the lease of work order ${context.marker.orderId} is lost (${code})` };
  }
  const ended = safeRead(context.files.ended);
  if (ended.fault || ended.value) {
    return { allowed: false, reason: `the session of work order ${context.marker.orderId} has ended` };
  }
  const lease = safeRead(context.files.lease);
  if (lease.fault || leaseExpired(lease.value, now)) {
    return {
      allowed: false,
      reason: `no lease renewal of work order ${context.marker.orderId} succeeded within its lease time`,
    };
  }
  return { allowed: true, reason: null };
}

function markLost(context, info) {
  return createOnce(context.projectRoot, context.files.lost, {
    orderId: context.marker.orderId,
    attempt: context.marker.attempt,
    code: info.code,
    via: info.via,
    at: info.at,
  });
}

function markEnded(context, info) {
  return createOnce(context.projectRoot, context.files.ended, {
    orderId: context.marker.orderId,
    attempt: context.marker.attempt,
    outcome: info.outcome,
    kind: info.kind,
    delivered: info.delivered === true,
    reason: typeof info.reason === 'string' ? info.reason.slice(0, 500) : null,
    at: info.at,
  });
}

function boundedText(value) {
  return typeof value === 'string' ? value.slice(0, MAX_ANSWER_CHARS) : null;
}

function recordAnswers(context, answers) {
  if (!Array.isArray(answers) || answers.length === 0) return [];
  const current = safeRead(context.files.answers).value || { delivered: [], pending: [] };
  const delivered = Array.isArray(current.delivered) ? current.delivered.filter((id) => typeof id === 'string') : [];
  const pending = Array.isArray(current.pending) ? current.pending.filter(isObject) : [];
  const known = new Set([...delivered, ...pending.map((entry) => entry.id)]);
  const added = [];
  for (const answer of answers) {
    if (!isObject(answer) || typeof answer.id !== 'string' || known.has(answer.id)) continue;
    if (typeof answer.answer !== 'string' || answer.answer.length === 0) continue;
    known.add(answer.id);
    added.push({
      id: answer.id,
      category: boundedText(answer.category),
      question: boundedText(answer.question),
      answer: boundedText(answer.answer),
      status: boundedText(answer.status),
    });
  }
  if (added.length === 0) return [];
  writeState(context.projectRoot, context.files.answers, {
    delivered: delivered.slice(-500),
    pending: [...pending, ...added].slice(-MAX_PENDING_ANSWERS),
  });
  return added;
}

function takePendingAnswers(context) {
  const current = safeRead(context.files.answers).value;
  if (!current || !Array.isArray(current.pending) || current.pending.length === 0) return [];
  const pending = current.pending.filter(isObject);
  const delivered = Array.isArray(current.delivered) ? current.delivered.filter((id) => typeof id === 'string') : [];
  writeState(context.projectRoot, context.files.answers, {
    delivered: [...delivered, ...pending.map((entry) => entry.id)].slice(-500),
    pending: [],
  });
  return pending;
}

function recordLease(context, body, now) {
  const order = isObject(body.order) ? body.order : {};
  const previous = safeRead(context.files.lease).value || {};
  const leaseSeconds = Number(body.lease_seconds);
  const recordedHead = typeof body.head_sha === 'string' && body.head_sha
    ? body.head_sha
    : (typeof order.head_sha === 'string' && order.head_sha ? order.head_sha : (previous.recordedHead || null));
  const lease = {
    orderId: context.marker.orderId,
    attempt: context.marker.attempt,
    leaseSeconds: Number.isFinite(leaseSeconds) && leaseSeconds > 0 ? leaseSeconds : (previous.leaseSeconds || 0),
    lastSuccessAt: Math.max(now, Number.isFinite(previous.lastSuccessAt) ? previous.lastSuccessAt : 0),
    recordedHead,
    orderStatus: typeof order.status === 'string' ? order.status : (previous.orderStatus || null),
  };
  writeState(context.projectRoot, context.files.lease, lease);
  return lease;
}

function renew(context, { env = process.env, now = Date.now(), force = false, thresholdMs = null } = {}) {
  if (!context || context.fault) return { verdict: 'fault', fault: context ? context.fault : 'not in work-order mode' };
  if (safeRead(context.files.lost).value) return { verdict: VERDICTS.LOST, failure: null };
  if (safeRead(context.files.ended).value) return { verdict: 'ended', failure: null };
  const lease = safeRead(context.files.lease).value;
  const due = thresholdMs === null
    ? renewDue(lease, now)
    : (!isObject(lease) || !Number.isFinite(lease.lastSuccessAt) || now - lease.lastSuccessAt >= thresholdMs);
  if (!force && !due) return { verdict: 'fresh', lease, answers: [] };
  const outcome = runZensu(['work', 'heartbeat', context.marker.orderId, '--json'], { env });
  if (outcome.exitCode === 0 && isObject(outcome.json)) {
    const renewed = recordLease(context, outcome.json, now);
    return { verdict: VERDICTS.OK, lease: renewed, answers: recordAnswers(context, outcome.json.answers) };
  }
  const failure = classifyFailure(outcome);
  if ([VERDICTS.LOST, VERDICTS.AMBIGUOUS, VERDICTS.FINAL].includes(failure.verdict)) {
    markLost(context, { code: failure.code || `status_${failure.status}`, via: 'heartbeat', at: now });
    return { verdict: VERDICTS.LOST, failure };
  }
  return { verdict: failure.verdict === VERDICTS.OK ? VERDICTS.TRANSIENT : failure.verdict, failure };
}

function sleepMs(ms) {
  if (!(ms > 0)) return;
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function retrySettings(env) {
  const base = Number(env && env.ZENSU_WORK_ORDER_RETRY_MS);
  const budget = Number(env && env.ZENSU_WORK_ORDER_RETRY_BUDGET_MS);
  return {
    baseMs: Number.isFinite(base) && base >= 0 && base <= 60000 ? base : DEFAULT_RETRY_BASE_MS,
    budgetMs: Number.isFinite(budget) && budget >= 0 && budget <= 600000 ? budget : DEFAULT_RETRY_BUDGET_MS,
  };
}

function probeAmbiguous(context, { env, now, target }) {
  const beat = renew(context, { env, now, force: true });
  if (beat.verdict !== VERDICTS.OK) {
    return beat.verdict === VERDICTS.LOST || beat.verdict === 'ended'
      ? { verdict: VERDICTS.LOST, code: beat.failure ? beat.failure.code : null }
      : { verdict: VERDICTS.TRANSIENT, code: null };
  }
  const got = runZensu(['work', 'get', context.marker.orderId, '--json'], { env });
  if (got.exitCode !== 0 || !isObject(got.json)) {
    const failure = classifyFailure(got);
    return failure.verdict === VERDICTS.LOST
      ? { verdict: VERDICTS.LOST, code: failure.code }
      : { verdict: VERDICTS.TRANSIENT, code: null };
  }
  const order = got.json;
  if (order.status === 'claimed' && !order.claim_confirmed_at) return { verdict: VERDICTS.RETRY, code: 'claim_not_confirmed' };
  const policy = isObject(order.policy) ? order.policy : {};
  if (target && STAGE_RANK[target] >= STAGE_RANK.implementing && STAGE_RANK[order.status] <= STAGE_RANK.planning
      && policy.plan_approval === 'required' && order.implementation_plan_approved !== true) {
    return { verdict: VERDICTS.FINAL, code: 'plan_approval_required' };
  }
  return { verdict: VERDICTS.FINAL, code: 'invalid_transition' };
}

function sendEvent(context, args, { env = process.env, now = Date.now, target = null, terminal = false } = {}) {
  const settings = retrySettings(env);
  const started = now();
  let delay = settings.baseMs;
  const command = ['work', 'event', context.marker.orderId, ...args,
    '--client-name', CLIENT_NAME, '--client-version', pluginVersion(), '--json'];
  for (;;) {
    const outcome = runZensu(command, { env });
    if (outcome.exitCode === 0 && isObject(outcome.json)) {
      const order = isObject(outcome.json.order) ? outcome.json.order : {};
      if (!terminal && order.status !== 'blocked') recordLease(context, { order, lease_seconds: null }, now());
      return { verdict: VERDICTS.OK, order, replay: outcome.json.replay === true };
    }
    let failure = classifyFailure(outcome);
    if (failure.verdict === VERDICTS.AMBIGUOUS) {
      const probed = probeAmbiguous(context, { env, now: now(), target });
      failure = { verdict: probed.verdict, status: failure.status, code: probed.code };
    }
    if (failure.verdict === VERDICTS.LOST) {
      markLost(context, { code: failure.code || `status_${failure.status}`, via: 'event', at: now() });
      return { verdict: VERDICTS.LOST, failure };
    }
    if (failure.verdict === VERDICTS.FINAL) return { verdict: VERDICTS.FINAL, failure };
    if (now() - started + delay > settings.budgetMs) return { verdict: VERDICTS.TRANSIENT, failure };
    sleepMs(delay);
    delay = Math.min(delay * 2, 30000);
  }
}

function deliverBlocked(context, { env = process.env, now = Date.now, kind = 'worker_error', reason, eventKey }) {
  const prose = String(reason || 'The session stopped without a stated reason.').replace(/\s+/g, ' ').trim().slice(0, 480);
  const sent = sendEvent(context, [
    '--blocked', kind, '--reason', prose, '--client-event-id', clientEventId(context.marker.orderId, context.marker.attempt, 'blocked', eventKey || kind),
  ], { env, now, terminal: true });
  const delivered = sent.verdict === VERDICTS.OK;
  if (delivered || sent.verdict === VERDICTS.LOST || sent.verdict === VERDICTS.FINAL) {
    markEnded(context, {
      outcome: kind === 'plan_approval' && delivered ? 'success' : 'failure',
      kind: `blocked:${kind}`,
      delivered,
      reason: prose,
      at: now(),
    });
  }
  return { ...sent, delivered };
}

function orderSummary(order, context) {
  const policy = isObject(order.policy) ? order.policy : {};
  const plan = isObject(order.plan) ? order.plan : {};
  return {
    orderId: order.id,
    attempt: order.attempt,
    kind: order.kind,
    status: order.status,
    repository: order.repository || null,
    baseBranch: plan.base_branch || null,
    integrationBranch: plan.integration_branch || null,
    branch: order.branch || null,
    prUrl: order.pr_url || null,
    prNumber: Number.isSafeInteger(order.pr_number) ? order.pr_number : null,
    headSha: order.head_sha || null,
    specHash: order.spec_hash || null,
    planApproval: policy.plan_approval || null,
    planApproved: order.implementation_plan_approved === true,
    leaseMinutes: Number.isFinite(policy.lease_minutes) ? policy.lease_minutes : null,
    autopilotRunId: order.autopilot_run_id || null,
    orderFile: context ? context.files.order : null,
  };
}

function probe({ env = process.env } = {}) {
  const outcome = runZensu(['work', '--help'], { env, timeoutMs: 15000 });
  if (outcome.missing) return { ok: false, reason: 'the zensu CLI is not on PATH; install zensu-cli 0.8.0 or later' };
  if (outcome.exitCode !== 0) {
    return { ok: false, reason: 'the installed zensu CLI has no `zensu work` command; install zensu-cli 0.8.0 or later' };
  }
  return { ok: true, reason: null };
}

function start({ env = process.env, projectRoot, sessionKey, orderId, now = Date.now }) {
  if (!tokenPresent(env)) {
    return { exit: EXIT.NOT_BOUND, message: 'ZENSU_SESSION_TOKEN is not set; /zensu:work runs only inside a work order session that a worker started' };
  }
  if (!ORDER_ID_RE.test(String(orderId || ''))) return { exit: EXIT.USAGE, message: 'start needs --order <work-order-id>' };
  if (!SESSION_KEY_RE.test(String(sessionKey || '')) || typeof projectRoot !== 'string' || !path.isAbsolute(projectRoot)) {
    return { exit: EXIT.NOT_BOUND, message: 'the session binding is unavailable' };
  }
  const probed = probe({ env });
  if (!probed.ok) return { exit: EXIT.NO_CLI, message: probed.reason };
  const got = runZensu(['work', 'get', orderId, '--json'], { env });
  if (got.exitCode !== 0 || !isObject(got.json)) {
    const failure = classifyFailure(got);
    if (failure.verdict === VERDICTS.TRANSIENT || failure.verdict === VERDICTS.RETRY || failure.verdict === VERDICTS.OK) {
      return { exit: EXIT.TRANSIENT, message: `Zensu did not answer the order read (${describeFailure(failure)}); try again` };
    }
    return { exit: EXIT.LOST, message: `this session token cannot read work order ${orderId} (${describeFailure(failure)})` };
  }
  const order = got.json;
  if (String(order.id || '').toLowerCase() !== orderId.toLowerCase()) {
    return { exit: EXIT.NOT_BOUND, message: 'Zensu answered with another work order' };
  }
  if (sessionKeyOf(order.client_session_id) !== sessionKey) {
    return { exit: EXIT.NOT_BOUND, message: `work order ${orderId} is claimed for another session` };
  }
  if (!Number.isSafeInteger(order.attempt) || order.attempt < 1) {
    return { exit: EXIT.NOT_BOUND, message: `work order ${orderId} carries no attempt` };
  }
  const files = sessionFiles(projectRoot, sessionKey);
  const existing = readState(files.marker);
  if (existing && (existing.orderId !== order.id || existing.attempt !== order.attempt)) {
    return { exit: EXIT.NOT_BOUND, message: `this session already runs work order ${existing.orderId} attempt ${existing.attempt}` };
  }
  const policy = isObject(order.policy) ? order.policy : {};
  const marker = existing || {
    sessionKey,
    clientSessionKey: sessionKey,
    orderId: order.id,
    attempt: order.attempt,
    kind: order.kind,
    repository: order.repository || null,
    specHash: order.spec_hash || null,
    planApproval: policy.plan_approval || null,
    pluginVersion: pluginVersion(),
    startedAt: now(),
  };
  writeState(projectRoot, files.order, { order });
  if (!existing) writeState(projectRoot, files.marker, marker);
  const context = { projectRoot, sessionKey, files, marker, fault: null };
  const summary = orderSummary(order, context);
  if (safeRead(files.ended).value) {
    return { exit: EXIT.ENDED, message: `the session of work order ${order.id} has already ended`, summary: { ...summary, action: 'stop' } };
  }
  const beat = renew(context, { env, now: now(), force: true });
  if (beat.verdict === VERDICTS.LOST) {
    return { exit: EXIT.LOST, message: `the lease of work order ${order.id} is lost (${describeFailure(beat.failure)}); stop without any forge write`, summary: { ...summary, action: 'stop' } };
  }
  const pulse = runZensu(['pulse', 'start', '--work-order', order.id, '--client-name', CLIENT_NAME,
    '--client-version', pluginVersion(), '--json'], { env });
  summary.pulse = pulse.exitCode === 0
    ? (isObject(pulse.json) && pulse.json.status === 'tracking_disabled' ? 'tracking_disabled' : 'linked')
    : 'unavailable';
  summary.leaseSeconds = beat.lease ? beat.lease.leaseSeconds : null;
  if (!SUPPORTED_KINDS.includes(order.kind)) {
    const reason = `This harness does not run work orders of kind ${String(order.kind).replace(/[^A-Za-z0-9 ]/g, ' ')}. Its manifest supports the kind implement only.`;
    const blocked = deliverBlocked(context, { env, now, reason, eventKey: 'unsupported-kind' });
    return {
      exit: EXIT.ENDED,
      message: blocked.delivered
        ? `work order ${order.id} is of kind ${order.kind}, which this harness does not run; it is blocked with worker_error`
        : `work order ${order.id} is of kind ${order.kind}, which this harness does not run; the block could not be delivered`,
      summary: { ...summary, action: 'stop', delivered: blocked.delivered },
    };
  }
  return { exit: EXIT.OK, message: null, summary: { ...summary, action: order.kind } };
}

function status({ env = process.env, projectRoot, sessionKey, now = Date.now() }) {
  const context = loadContext({ env, projectRoot, sessionKey });
  if (!context) return { mode: 'inert' };
  if (context.fault) return { mode: 'fault', fault: context.fault };
  const forge = forgeWriteVerdict(context, now);
  const lease = safeRead(context.files.lease).value;
  return {
    mode: 'active',
    orderId: context.marker.orderId,
    attempt: context.marker.attempt,
    kind: context.marker.kind,
    leaseSeconds: lease ? lease.leaseSeconds : null,
    lastSuccessAt: lease ? lease.lastSuccessAt : null,
    recordedHead: lease ? lease.recordedHead : null,
    orderStatus: lease ? lease.orderStatus : null,
    lost: Boolean(safeRead(context.files.lost).value),
    ended: safeRead(context.files.ended).value || null,
    forgeWrites: forge.allowed ? 'allowed' : 'denied',
    forgeReason: forge.reason,
  };
}

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith('--')) throw new Error(`unexpected argument ${token}`);
    const name = token.slice(2);
    const value = argv[index + 1];
    if (value === undefined || value.startsWith('--')) {
      options[name] = true;
    } else {
      options[name] = value;
      index += 1;
    }
  }
  return options;
}

function runCli(argv, env = process.env) {
  try {
    return dispatchCli(argv, env);
  } catch (error) {
    process.stderr.write(`zensu work-order: ${error && error.message ? error.message : 'internal fault'}\n`);
    return EXIT.USAGE;
  }
}

function dispatchCli(argv, env) {
  const [verb, ...rest] = argv;
  const options = parseArgs(rest);
  const projectRoot = env.WO_PROJECT_ROOT;
  const sessionKey = env.WO_SESSION_KEY;
  if (verb === 'probe') {
    const probed = probe({ env });
    if (!probed.ok) process.stderr.write(`zensu work-order: ${probed.reason}\n`);
    return probed.ok ? EXIT.OK : EXIT.NO_CLI;
  }
  if (verb === 'start') {
    const result = start({ env, projectRoot, sessionKey, orderId: options.order });
    if (result.summary) process.stdout.write(`${JSON.stringify(result.summary, null, 2)}\n`);
    if (result.message) process.stderr.write(`zensu work-order: ${result.message}\n`);
    return result.exit;
  }
  if (verb === 'status') {
    process.stdout.write(`${JSON.stringify(status({ env, projectRoot, sessionKey }), null, 2)}\n`);
    return EXIT.OK;
  }
  if (verb === 'renew') {
    const context = loadContext({ env, projectRoot, sessionKey });
    if (!context || context.fault) {
      process.stderr.write(`zensu work-order: ${context ? context.fault : 'this session runs no work order'}\n`);
      return EXIT.NOT_BOUND;
    }
    const beat = renew(context, { env, force: options.force === true });
    if (beat.verdict === VERDICTS.LOST) {
      process.stderr.write(`zensu work-order: the lease of work order ${context.marker.orderId} is lost; stop without any forge write\n`);
      return EXIT.LOST;
    }
    if (beat.verdict === 'ended') return EXIT.ENDED;
    if (beat.verdict === VERDICTS.OK || beat.verdict === 'fresh') return EXIT.OK;
    process.stderr.write(`zensu work-order: the lease renewal did not succeed (${describeFailure(beat.failure)})\n`);
    return EXIT.TRANSIENT;
  }
  process.stderr.write('zensu work-order: unknown verb\n');
  return EXIT.USAGE;
}

module.exports = {
  CLIENT_NAME,
  EXIT,
  LOST_CODES,
  RETRY_CODES,
  SCHEMA_VERSION,
  STAGE_RANK,
  STATE_SEGMENTS,
  SUPPORTED_KINDS,
  VERDICTS,
  classifyFailure,
  clientEventId,
  cliOutcome,
  createOnce,
  deliverBlocked,
  describeFailure,
  forgeWriteVerdict,
  leaseExpired,
  loadContext,
  markEnded,
  markLost,
  orderSummary,
  planStageEvents,
  pluginVersion,
  probe,
  readState,
  recordAnswers,
  renew,
  renewDue,
  renewInterval,
  runCli,
  runZensu,
  sendEvent,
  sessionFiles,
  sessionKeyOf,
  stageForLedgerEvent,
  start,
  status,
  takePendingAnswers,
  tokenPresent,
  writeState,
};

if (require.main === module) {
  process.exitCode = runCli(process.argv.slice(2));
}
