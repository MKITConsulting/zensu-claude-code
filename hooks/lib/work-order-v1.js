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
const MAX_DELIVERED_ANSWERS = 500;
const MAX_ANSWER_CHARS = 4000;
const DEFAULT_BRANCH_PREFIX = 'wo-';
const BRANCH_PREFIX_RE = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,62}$/;
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
const CLI_STATUS_RE = /\(status (\d{3})(?:, code ([a-z][a-z0-9_]{0,63}))?\)/;
const NO_ANSWER_RE = /^(?:Get|Head|Post|Put|Patch|Delete|Options) "|^reading response body:|^invalid [a-z ]+ (?:response|list)\b|\b(?:connection refused|connection reset by peer|broken pipe|i\/o timeout|no such host|network is unreachable|context deadline exceeded|TLS handshake timeout|unexpected EOF|server misbehaving)\b/;
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
    answerKeys: named('answer-keys'),
    stop: named('stop'),
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
  const firstError = lines.findIndex((line) => line.startsWith('error:'));
  const errorLine = firstError >= 0 ? lines[firstError] : '';
  const errorText = firstError >= 0
    ? lines.slice(firstError).filter((line) => !line.trim().startsWith('{"error"')).join('\n')
    : '';
  const parsed = spawned.status === 0 ? { status: null, code: null } : parseCliError(lines, errorText);
  const firstLine = firstError < 0 && lines.length > 0 ? lines[0].trim() : '';
  return {
    exitCode: spawned.status,
    stdout,
    stderr,
    status: parsed.status,
    code: parsed.code,
    message: (parsed.message || errorLine.replace(/^error:\s*/, '') || firstLine).slice(0, 500),
    cliError: spawned.status !== 0 && (firstError >= 0 || parsed.json === true),
    missing: false,
  };
}

function parseCliError(lines, errorText) {
  const last = lines.length > 0 ? lines[lines.length - 1].trim() : '';
  if (last.startsWith('{')) {
    try {
      const body = JSON.parse(last);
      if (isObject(body) && isObject(body.error)) {
        const status = Number.isSafeInteger(body.error.status) && body.error.status >= 100 && body.error.status <= 599
          ? body.error.status : null;
        const code = typeof body.error.code === 'string' && CLI_CODE_RE.test(body.error.code) ? body.error.code : null;
        const message = typeof body.error.message === 'string' ? body.error.message : '';
        return { status, code, message, json: true };
      }
    } catch (_) {}
  }
  const match = CLI_STATUS_RE.exec(errorText);
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
  if (status === null) {
    const message = outcome && typeof outcome.message === 'string' ? outcome.message : '';
    const refused = Boolean(outcome && outcome.cliError) && !NO_ANSWER_RE.test(message.trim());
    return { verdict: refused ? VERDICTS.FINAL : VERDICTS.TRANSIENT, status, code, message };
  }
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

function cliRefusal(failure) {
  return Boolean(failure) && failure.status === null && failure.verdict === VERDICTS.FINAL;
}

function cliSaid(failure) {
  return failure && typeof failure.message === 'string' ? failure.message.replace(/\s+/g, ' ').trim() : '';
}

function describeFailure(failure) {
  if (!failure || failure.status === null) {
    const said = cliSaid(failure);
    if (cliRefusal(failure)) return said ? `the zensu CLI refused the call: ${said}` : 'the zensu CLI refused the call';
    return said ? `the zensu CLI failed without a status: ${said}` : 'no answer from Zensu';
  }
  return failure.code ? `status ${failure.status}, code ${failure.code}` : `status ${failure.status}`;
}

function refusedText(what, failure, capital = false) {
  if (!cliRefusal(failure)) return `Zensu refused ${what} (${describeFailure(failure)})`;
  const said = cliSaid(failure);
  return `${capital ? 'The' : 'the'} zensu CLI refused ${what}${said ? ` (${said})` : ''}`;
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
      pr: event.eventType === 'PR_OPENED' && isObject(event.payload)
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

function answerVersion(answer) {
  if (typeof answer.answered_at === 'string' && answer.answered_at.length > 0) return boundedText(answer.answered_at);
  return `sha256:${crypto.createHash('sha256').update(answer.answer, 'utf8').digest('hex')}`;
}

function readAnswers(context) {
  const current = safeRead(context.files.answers).value || {};
  const delivered = new Set();
  for (const id of Array.isArray(current.delivered) ? current.delivered : []) {
    if (typeof id !== 'string') continue;
    delivered.delete(id);
    delivered.add(id);
  }
  const pending = Array.isArray(current.pending) ? current.pending.filter(isObject) : [];
  const stored = safeRead(context.files.answerKeys).value || {};
  const keys = new Map(isObject(stored.keys) ? Object.entries(stored.keys).filter(([, key]) => typeof key === 'string') : []);
  return { delivered, pending, keys };
}

function writeAnswers(context, { delivered, pending, keys = null }) {
  const kept = { delivered: [...delivered].slice(-MAX_DELIVERED_ANSWERS), pending: pending.slice(-MAX_PENDING_ANSWERS) };
  writeState(context.projectRoot, context.files.answers, kept);
  if (!keys) return;
  const live = new Set(kept.delivered);
  for (const entry of pending.slice(0, -MAX_PENDING_ANSWERS)) {
    if (live.has(entry.id)) keys.set(entry.id, '');
  }
  for (const entry of kept.pending) live.add(entry.id);
  writeState(context.projectRoot, context.files.answerKeys, {
    keys: Object.fromEntries([...keys].filter(([id]) => live.has(id))),
  });
}

function recordAnswers(context, answers) {
  if (!Array.isArray(answers) || answers.length === 0) return [];
  const { delivered, pending, keys } = readAnswers(context);
  const queue = pending.slice();
  let adopted = false;
  for (const answer of answers) {
    if (!isObject(answer) || typeof answer.id !== 'string') continue;
    if (typeof answer.answer !== 'string' || answer.answer.length === 0) continue;
    const version = answerVersion(answer);
    const queued = queue.findIndex((entry) => entry.id === answer.id);
    if (queued >= 0) {
      if (queue[queued].version === version) continue;
      queue.splice(queued, 1);
    } else if (delivered.has(answer.id)) {
      if (keys.get(answer.id) === version) continue;
      if (!keys.has(answer.id)) {
        keys.set(answer.id, version);
        adopted = true;
        continue;
      }
    }
    keys.set(answer.id, version);
    queue.push({
      id: answer.id,
      category: boundedText(answer.category),
      question: boundedText(answer.question),
      answer: boundedText(answer.answer),
      status: boundedText(answer.status),
      planWide: answer.planWide === true,
      overturnedAt: boundedText(answer.overturned_at),
      version,
    });
  }
  const added = queue.filter((entry) => !pending.includes(entry));
  if (added.length === 0 && !adopted) return [];
  writeAnswers(context, { delivered, pending: queue, keys });
  return added;
}

function planDecisions(order) {
  const log = isObject(order) && Array.isArray(order.decision_log) ? order.decision_log : [];
  return log.filter((entry) => isObject(entry) && entry.status === 'answered').map((entry) => ({ ...entry, planWide: true }));
}

function takePendingAnswers(context) {
  const { delivered, pending } = readAnswers(context);
  if (pending.length === 0) return [];
  for (const entry of pending) {
    if (typeof entry.id !== 'string') continue;
    delivered.delete(entry.id);
    delivered.add(entry.id);
  }
  writeAnswers(context, { delivered, pending: [] });
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
  if (readOutbox(context).leaseRefusal) writeOutbox(context, { leaseRefusal: null });
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
    return loseLease(context, failure, 'heartbeat', { env, at: now });
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
    if (failure.verdict === VERDICTS.LOST) return { verdict: VERDICTS.LOST, code: failure.code };
    if (cliRefusal(failure)) return { verdict: VERDICTS.FINAL, code: null, failure };
    return { verdict: VERDICTS.TRANSIENT, code: null };
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
      if (!terminal && order.status !== 'blocked' && outcome.json.replay !== true) recordLease(context, { order, lease_seconds: null }, now());
      return { verdict: VERDICTS.OK, order, replay: outcome.json.replay === true };
    }
    let failure = classifyFailure(outcome);
    if (failure.verdict === VERDICTS.AMBIGUOUS) {
      const probed = probeAmbiguous(context, { env, now: now(), target });
      failure = probed.failure || { verdict: probed.verdict, status: failure.status, code: probed.code };
    }
    if (failure.verdict === VERDICTS.LOST) {
      const lost = loseLease(context, failure, 'event', { env, at: now() });
      if (lost.verdict !== VERDICTS.TRANSIENT) return { verdict: lost.verdict, failure };
      failure = lost.failure;
    }
    if (failure.verdict === VERDICTS.FINAL) return { verdict: VERDICTS.FINAL, failure };
    const elapsed = now() - started;
    if (safeRead(context.files.ended).value) return { verdict: 'ended', failure: null };
    if (elapsed + delay > settings.budgetMs) return { verdict: VERDICTS.TRANSIENT, failure };
    sleepMs(delay);
    delay = Math.min(delay * 2, 30000);
  }
}

const SAFE_BLOCK_REASON = 'The session ended before its Autopilot run reached a ready pull request.';
const PROSE_REFUSAL_CODES = new Set(['content_not_allowed', 'missing_field']);

function deliverBlocked(context, { env = process.env, now = Date.now, kind = 'worker_error', reason, eventKey, fallback = SAFE_BLOCK_REASON }) {
  let prose = String(reason || 'The session stopped without a stated reason.').replace(/\s+/g, ' ').trim().slice(0, 480);
  const id = clientEventId(context.marker.orderId, context.marker.attempt, 'blocked', eventKey || kind);
  const ended = { outcome: kind === 'plan_approval' ? 'success' : 'failure', kind: `blocked:${kind}` };
  const send = (text) => {
    const record = { verb: 'event', args: ['--blocked', kind, '--reason', text, '--client-event-id', id], ended };
    rememberTerminal(context, PENDING, record);
    const answer = sendEvent(context, record.args, { env, now, terminal: true });
    rememberTerminal(context, answer, record);
    return answer;
  };
  let sent = send(prose);
  let replaced = null;
  if (sent.verdict === VERDICTS.FINAL && kind === 'worker_error' && sent.failure && PROSE_REFUSAL_CODES.has(sent.failure.code)
      && prose !== fallback) {
    replaced = prose;
    prose = fallback;
    sent = send(prose);
  }
  const delivered = sent.verdict === VERDICTS.OK;
  if (delivered || sent.verdict === VERDICTS.LOST) {
    markEnded(context, {
      outcome: kind === 'plan_approval' && delivered ? 'success' : 'failure',
      kind: `blocked:${kind}`,
      delivered,
      reason: prose,
      at: now(),
    });
  }
  return { ...sent, delivered, reason: prose, replaced };
}

const INFLIGHT_LIMIT = 4;
const PENDING = Object.freeze({ verdict: VERDICTS.TRANSIENT });

function eventIdOf(args) {
  const at = args.indexOf('--client-event-id');
  return at >= 0 ? String(args[at + 1] || '') : '';
}

function inflightRecords(context) {
  const inflight = readOutbox(context).inflight;
  return Array.isArray(inflight) ? inflight.filter((record) => isObject(record) && Array.isArray(record.args)) : [];
}

function forgetTerminal(context, args) {
  const records = inflightRecords(context);
  const kept = records.filter((record) => eventIdOf(record.args) !== eventIdOf(args));
  if (kept.length !== records.length) writeOutbox(context, { inflight: kept });
}

function rememberTerminal(context, sent, record) {
  if (sent.verdict !== VERDICTS.TRANSIENT && sent.verdict !== VERDICTS.RETRY) {
    forgetTerminal(context, record.args);
    return;
  }
  const others = inflightRecords(context).filter((entry) => eventIdOf(entry.args) !== eventIdOf(record.args));
  writeOutbox(context, { inflight: [...others, record].slice(-INFLIGHT_LIMIT) });
}

function replayTerminal(context, { env, at }) {
  let unanswered = null;
  for (const record of inflightRecords(context).reverse()) {
    const argv = record.verb === 'ask'
      ? record.args.map(String)
      : ['work', 'event', context.marker.orderId, ...record.args.map(String), '--client-name', CLIENT_NAME, '--client-version', pluginVersion(), '--json'];
    const outcome = runZensu(argv, { env });
    if (outcome.exitCode !== 0 || !isObject(outcome.json)) {
      const failure = classifyFailure(outcome);
      if ([VERDICTS.TRANSIENT, VERDICTS.RETRY, VERDICTS.OK].includes(failure.verdict)) unanswered = unanswered || { ...failure, verdict: VERDICTS.TRANSIENT };
      else forgetTerminal(context, record.args);
      continue;
    }
    forgetTerminal(context, record.args);
    if (record.verb === 'ask') {
      if (noteAskOutcome(context, outcome.json, () => at)) return { state: 'ended', failure: null };
      continue;
    }
    if (!isObject(record.ended)) continue;
    markEnded(context, { outcome: String(record.ended.outcome), kind: String(record.ended.kind), delivered: true, reason: null, at });
    return { state: 'ended', failure: null };
  }
  return unanswered ? { state: 'unanswered', failure: unanswered } : { state: 'refused', failure: null };
}

function loseLease(context, failure, via, { env, at }) {
  if (safeRead(context.files.ended).value) return { verdict: 'ended', failure: null };
  const replayed = replayTerminal(context, { env, at });
  if (replayed.state === 'ended') return { verdict: 'ended', failure: null };
  const code = failure.code || (cliRefusal(failure) ? 'cli_refused' : `status_${failure.status}`);
  if (replayed.state === 'unanswered' && !leaseExpired(safeRead(context.files.lease).value, at)) {
    writeOutbox(context, { leaseRefusal: { code, via, at } });
    return { verdict: VERDICTS.TRANSIENT, failure: replayed.failure };
  }
  markLost(context, { code, via, at });
  return { verdict: VERDICTS.LOST, failure };
}

function endedResult(context, step, successExit = EXIT.ENDED) {
  const ended = safeRead(context.files.ended).value || {};
  return {
    exit: ended.outcome === 'success' ? successExit : EXIT.ENDED,
    message: `Zensu ended the session of work order ${context.marker.orderId} (${ended.kind || 'unknown'})${step}`,
    ended,
    cancelRun: runToCancel(context),
  };
}

function blockedResult(context, blocked, cause, again) {
  if (blocked.delivered) {
    return { exit: EXIT.ENDED, message: `${cause}; work order ${context.marker.orderId} is blocked with worker_error and the session has ended`, cancelRun: runToCancel(context) };
  }
  if (blocked.verdict === 'ended') return endedResult(context, `; ${cause}`);
  if (blocked.verdict === VERDICTS.LOST) {
    return { exit: EXIT.LOST, message: `${cause}; the lease is lost, so the block could not be reported (${describeFailure(blocked.failure)})`, cancelRun: runToCancel(context) };
  }
  if (blocked.verdict === VERDICTS.FINAL) return { exit: EXIT.REFUSED, message: `${cause}; ${refusedText('the block', blocked.failure)}; end the session` };
  return { exit: EXIT.TRANSIENT, message: `${cause}; the block is not delivered yet (${describeFailure(blocked.failure)}); run ${again} again` };
}

function branchPrefixOf(order) {
  const spec = isObject(order) && isObject(order.spec) ? order.spec : {};
  const prefix = spec.branch_prefix;
  return typeof prefix === 'string' && BRANCH_PREFIX_RE.test(prefix) && !prefix.includes('..') ? prefix : DEFAULT_BRANCH_PREFIX;
}

function orderSummary(order, context) {
  const policy = isObject(order.policy) ? order.policy : {};
  const plan = isObject(order.plan) ? order.plan : {};
  const branchPrefix = branchPrefixOf(order);
  return {
    orderId: order.id,
    attempt: order.attempt,
    kind: order.kind,
    status: order.status,
    repository: order.repository || null,
    baseBranch: plan.base_branch || null,
    integrationBranch: plan.integration_branch || null,
    branch: order.branch || null,
    branchPrefix,
    workBranch: order.branch || `${branchPrefix}${String(order.id || '').slice(0, 8).toLowerCase()}`,
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

const SESSION_TOKEN_HOST_RE = /ZENSU_SESSION_TOKEN needs the host/;
const SESSION_TOKEN_SHAPE_RE = /ZENSU_SESSION_TOKEN must hold/;

function probe({ env = process.env } = {}) {
  const outcome = runZensu(['work', '--help'], { env, timeoutMs: 15000 });
  const floor = require('./zensu-cli-version-v1.js').MIN_VERSION;
  if (outcome.missing) return { ok: false, reason: `the zensu CLI is not on PATH; install zensu-cli ${floor} or later` };
  if (outcome.exitCode !== 0) {
    return { ok: false, reason: `the installed zensu CLI has no \`zensu work\` command; install zensu-cli ${floor} or later` };
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
    const said = String(got.message || '').replace(/\s+/g, ' ').trim();
    if (failure.status === null && got.exitCode !== null && got.exitCode !== 0 && SESSION_TOKEN_HOST_RE.test(said)) {
      return {
        exit: EXIT.NO_CLI,
        message: `the zensu CLI cannot use the session token: ${said}; the worker must start the session with ZENSU_API_URL set to the Zensu host that issued the token`,
      };
    }
    if (failure.status === null && got.exitCode !== null && got.exitCode !== 0 && SESSION_TOKEN_SHAPE_RE.test(said)) {
      return { exit: EXIT.NO_CLI, message: `the zensu CLI cannot use the session token: ${said}; the worker must pass the zst_ session token of its claim` };
    }
    if (cliRefusal(failure)) {
      return { exit: EXIT.NO_CLI, message: `${refusedText('the order read', failure)}; the session cannot run the order with this zensu CLI` };
    }
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
  recordAnswers(context, planDecisions(order));
  const summary = orderSummary(order, context);
  if (safeRead(files.ended).value) {
    return { exit: EXIT.ENDED, message: `the session of work order ${order.id} has already ended`, summary: { ...summary, action: 'stop' } };
  }
  const beat = renew(context, { env, now: now(), force: true });
  if (beat.verdict === 'ended') return { ...endedResult(context, ''), summary: { ...summary, action: 'stop' } };
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
      ...blockedResult(context, blocked, `work order ${order.id} is of kind ${order.kind}, which this harness does not run`, '--start'),
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

const RUN_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_.:-]{2,127}$/;
const FULL_SHA_RE = /^([0-9a-f]{40}|[0-9a-f]{64})$/;
const GIT_ENV_SCRUB = ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY',
  'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_NAMESPACE', 'GIT_CEILING_DIRECTORIES', 'GIT_DISCOVERY_ACROSS_FILESYSTEM'];

function git(projectRoot, args, env = process.env) {
  const childEnv = { ...env };
  for (const name of GIT_ENV_SCRUB) delete childEnv[name];
  const spawned = spawnSync('git', ['-C', projectRoot, ...args], {
    env: childEnv,
    encoding: 'utf8',
    timeout: 120000,
    maxBuffer: 32 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
    windowsHide: true,
  });
  return {
    ok: !spawned.error && spawned.status === 0,
    stdout: typeof spawned.stdout === 'string' ? spawned.stdout : '',
    stderr: typeof spawned.stderr === 'string' ? spawned.stderr : '',
  };
}

function fullSha(projectRoot, sha) {
  if (typeof sha !== 'string' || !/^[0-9a-fA-F]{7,64}$/.test(sha)) return null;
  const lower = sha.toLowerCase();
  if (FULL_SHA_RE.test(lower)) return lower;
  const resolved = git(projectRoot, ['rev-parse', '--verify', '--quiet', `${lower}^{commit}`]);
  const value = resolved.stdout.trim().toLowerCase();
  return resolved.ok && FULL_SHA_RE.test(value) ? value : null;
}

function currentBranch(projectRoot) {
  const branch = git(projectRoot, ['symbolic-ref', '--quiet', '--short', 'HEAD']);
  const value = branch.stdout.trim();
  return branch.ok && value && !/[\s\0]/.test(value) ? value : null;
}

function currentHead(projectRoot) {
  const head = git(projectRoot, ['rev-parse', '--verify', '--quiet', 'HEAD^{commit}']);
  const value = head.stdout.trim().toLowerCase();
  return head.ok && FULL_SHA_RE.test(value) ? value : null;
}

function orderBranchPrefix(context) {
  const snapshot = safeRead(context.files.order).value;
  return branchPrefixOf(snapshot && isObject(snapshot.order) ? snapshot.order : {});
}

function reportableBranch(context) {
  const branch = currentBranch(context.projectRoot);
  return branch && branch.startsWith(orderBranchPrefix(context)) ? branch : null;
}

function foreignBranchMessage(context, branch) {
  return `the working branch ${branch} does not start with ${orderBranchPrefix(context)}, the branch prefix Zensu requires for this order; check out the workBranch named in the --start summary and run this step again`;
}

function readRunRecord(projectRoot, runId) {
  if (!RUN_ID_RE.test(String(runId || ''))) return null;
  const file = path.join(projectRoot, '.zensu', 'state', `autopilot-run-${runId}.json`);
  let stat;
  try {
    stat = fs.lstatSync(file);
  } catch (_) {
    return null;
  }
  if (!stat.isFile() || stat.nlink !== 1 || stat.size > MAX_STATE_BYTES) return null;
  try {
    const run = JSON.parse(fs.readFileSync(file, 'utf8'));
    return isObject(run) && run.runId === runId && Array.isArray(run.events) ? run : null;
  } catch (_) {
    return null;
  }
}

function readOutbox(context) {
  const outbox = safeRead(context.files.outbox).value;
  return isObject(outbox) ? outbox : {};
}

function writeOutbox(context, patch) {
  const current = readOutbox(context);
  writeState(context.projectRoot, context.files.outbox, { ...current, ...patch });
}

function markerRun(context, runId) {
  const outbox = readOutbox(context);
  if (runId) {
    if (!RUN_ID_RE.test(runId)) return { error: 'the run id is invalid' };
    if (outbox.runId && outbox.runId !== runId) {
      return { error: `this session already reports Autopilot run ${outbox.runId} for work order ${context.marker.orderId}` };
    }
    if (!outbox.runId) writeOutbox(context, { runId, deliveredRank: 0 });
    return { runId };
  }
  return outbox.runId ? { runId: outbox.runId } : { error: 'no Autopilot run is bound to this work order yet' };
}

function binding(context, orderId) {
  if (!context) {
    return orderId ? { exit: EXIT.NOT_BOUND, message: 'this session runs no work order' } : { exit: EXIT.OK, value: null };
  }
  if (context.fault) return { exit: EXIT.NOT_BOUND, message: context.fault };
  if (!orderId) {
    return { exit: EXIT.NOT_BOUND, message: `this session runs work order ${context.marker.orderId}; begin its run with --work-order ${context.marker.orderId}` };
  }
  if (String(orderId).toLowerCase() !== context.marker.orderId.toLowerCase()) {
    return { exit: EXIT.NOT_BOUND, message: `this session runs work order ${context.marker.orderId}, not ${orderId}` };
  }
  if (!/^[a-f0-9]{64}$/.test(String(context.marker.specHash || ''))) {
    return { exit: EXIT.NOT_BOUND, message: 'the work-order marker carries no spec hash' };
  }
  return {
    exit: EXIT.OK,
    value: { orderId: context.marker.orderId.toLowerCase(), attempt: context.marker.attempt, specHash: context.marker.specHash },
  };
}

function stageArgs(context, run, planned) {
  const args = ['--stage', planned.status, '--client-event-id', planned.clientEventId,
    '--autopilot-stage', planned.autopilotStage, '--autopilot-run-id', run.runId];
  if (planned.status === 'pr_open' && planned.pr) {
    args.push('--pr-url', String(planned.pr.url), '--pr-number', String(planned.pr.number));
    const head = fullSha(context.projectRoot, planned.pr.headSha);
    if (head) args.push('--head', head);
  }
  const branch = reportableBranch(context);
  if (branch && (planned.status === 'implementing' || planned.status === 'pr_open')) args.push('--branch', branch);
  return args;
}

function noteBlockedOrder(context, order, now) {
  markEnded(context, {
    outcome: 'failure',
    kind: `blocked:${typeof order.blocked_kind === 'string' ? order.blocked_kind : 'unknown'}`,
    delivered: true,
    reason: typeof order.blocked_reason === 'string' ? order.blocked_reason : null,
    at: now(),
  });
}

function drain(context, { env = process.env, now = Date.now } = {}) {
  if (!context || context.fault) return { verdict: 'fault' };
  if (safeRead(context.files.lost).value) return { verdict: VERDICTS.LOST };
  if (safeRead(context.files.ended).value) return { verdict: 'ended' };
  const outbox = readOutbox(context);
  if (!outbox.runId) return { verdict: 'idle', sent: [] };
  const run = readRunRecord(context.projectRoot, outbox.runId);
  if (!run) return { verdict: 'no-run', sent: [] };
  const planned = planStageEvents(run, Number.isSafeInteger(outbox.deliveredRank) ? outbox.deliveredRank : 0)
    .filter((entry) => entry.status !== 'ready_for_merge');
  const sent = [];
  for (const entry of planned) {
    const result = sendEvent(context, stageArgs(context, run, entry), { env, now, target: entry.status });
    if (result.verdict === VERDICTS.OK) {
      if (result.order && result.order.status === 'blocked') {
        noteBlockedOrder(context, result.order, now);
        return { verdict: 'ended', sent };
      }
      writeOutbox(context, { deliveredRank: entry.rank, lastStatus: entry.status });
      sent.push(entry.status);
      continue;
    }
    if (result.verdict === VERDICTS.FINAL && result.failure && result.failure.code === 'invalid_transition') {
      writeOutbox(context, { deliveredRank: entry.rank });
      continue;
    }
    if (result.verdict === VERDICTS.FINAL && result.failure && result.failure.code === 'plan_approval_required') {
      return { verdict: 'plan-approval-required', sent };
    }
    return { verdict: result.verdict, failure: result.failure, sent, refused: entry.status };
  }
  return { verdict: VERDICTS.OK, sent };
}

function refusedStageReason(refused, reason) {
  if (typeof reason === 'string' && reason.trim()) return reason.replace(/`/g, "'");
  const stage = refused && refused.status ? String(refused.status).replace(/_/g, ' ') : 'an earlier';
  const code = refused && refused.failure && refused.failure.code ? ` with code ${refused.failure.code}` : '';
  const who = refused && cliRefusal(refused.failure) ? 'The zensu CLI' : 'Zensu';
  return `${who} refused the ${stage} stage${code}, so the delivered pull request cannot be reported as ready for merge.`;
}

function listOrderEvents(context, env) {
  const all = [];
  for (let page = 1; page <= 50; page += 1) {
    const listed = runZensu(['work', 'events', context.marker.orderId, '--page', String(page), '--per-page', '100', '--json'], { env });
    if (listed.exitCode !== 0 || !isObject(listed.json) || !Array.isArray(listed.json.data)) return { events: null, failure: classifyFailure(listed) };
    all.push(...listed.json.data);
    if (listed.json.data.length < 100 || all.length >= Number(listed.json.total || 0)) return { events: all, failure: null };
  }
  return { events: all, failure: null };
}

function detailOf(event) {
  if (!isObject(event)) return {};
  if (isObject(event.detail)) return event.detail;
  if (typeof event.detail === 'string') {
    try {
      const parsed = JSON.parse(event.detail);
      return isObject(parsed) ? parsed : {};
    } catch (_) {
      return {};
    }
  }
  return {};
}

function approvedPlanCommit(events, specHash) {
  let approvedAttempt = null;
  for (const event of events) {
    const detail = detailOf(event);
    if (event.event_type === 'approved' && detail.subject === 'implementation_plan' && detail.spec_hash === specHash
        && Number.isSafeInteger(event.attempt)) {
      approvedAttempt = event.attempt;
    }
  }
  if (approvedAttempt === null) return null;
  let approvedPlan = null;
  for (const event of events) {
    const detail = detailOf(event);
    if (event.event_type === 'artifact' && event.attempt === approvedAttempt && detail.kind === 'plan' && typeof detail.sha === 'string') {
      approvedPlan = detail;
    }
  }
  return approvedPlan;
}

const PLAN_PATH_RE = /^\.zensu\/plans\/[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.md$/;

function planFileFor(orderId) {
  return `.zensu/plans/${orderId}.md`;
}

function bindSpec(context, { env = process.env, now = Date.now, runId } = {}) {
  if (!context || context.fault) return { exit: EXIT.NOT_BOUND, message: context ? context.fault : 'this session runs no work order' };
  const bound = markerRun(context, runId);
  if (bound.error) return { exit: EXIT.NOT_BOUND, message: bound.error };
  const forge = forgeWriteVerdict(context, now());
  if (!forge.allowed) return { exit: EXIT.LOST, message: forge.reason };
  const run = readRunRecord(context.projectRoot, bound.runId);
  if (!run || !isObject(run.workOrder) || run.workOrder.orderId !== context.marker.orderId.toLowerCase()) {
    return { exit: EXIT.NOT_BOUND, message: `Autopilot run ${bound.runId} is not bound to work order ${context.marker.orderId}` };
  }
  const prior = run.events.find((event) => event.eventType === 'ORDER_SPEC_BOUND');
  if (prior) return { exit: EXIT.OK, value: prior.payload, already: true };
  if (run.stage !== 'PLANNING') return { exit: EXIT.REFUSED, message: `Autopilot run ${bound.runId} is at ${run.stage}, not PLANNING` };
  const branch = currentBranch(context.projectRoot);
  if (branch && !branch.startsWith(orderBranchPrefix(context))) return { exit: EXIT.REFUSED, message: foreignBranchMessage(context, branch) };
  const reported = drain(context, { env, now });
  if (reported.verdict === 'ended') return endedResult(context, '');
  if (reported.verdict === VERDICTS.LOST) return { exit: EXIT.LOST, message: 'the lease is lost; stop without any forge write' };
  if (reported.verdict === VERDICTS.FINAL) {
    return { exit: EXIT.REFUSED, message: `${refusedText(`the ${reported.refused || 'planning'} stage`, reported.failure)}; finish with --reason` };
  }
  if (reported.verdict !== VERDICTS.OK) {
    return { exit: EXIT.TRANSIENT, message: `the planning stage is not reported yet (${describeFailure(reported.failure)}); run --bind-spec again` };
  }
  const got = runZensu(['work', 'get', context.marker.orderId, '--json'], { env });
  if (got.exitCode !== 0 || !isObject(got.json)) {
    let failure = classifyFailure(got);
    if (failure.verdict === VERDICTS.LOST) {
      const lost = loseLease(context, failure, 'get', { env, at: now() });
      if (lost.verdict === 'ended') return endedResult(context, '');
      if (lost.verdict === VERDICTS.LOST) return { exit: EXIT.LOST, message: `the order cannot be read any more (${describeFailure(failure)})` };
      failure = lost.failure;
    }
    if (cliRefusal(failure)) return { exit: EXIT.REFUSED, message: `${refusedText('the order read', failure)}; finish with --reason` };
    return { exit: EXIT.TRANSIENT, message: `Zensu did not answer the order read (${describeFailure(failure)})` };
  }
  const order = got.json;
  writeState(context.projectRoot, context.files.order, { order });
  recordAnswers(context, planDecisions(order));
  if (order.spec_hash !== context.marker.specHash || order.spec_stale === true) {
    const blocked = deliverBlocked(context, { env, now, reason: 'The order spec changed while the session ran, so its plan no longer matches the spec it was dispatched with.', eventKey: 'spec-changed' });
    return blockedResult(context, blocked, 'the order spec changed during the session', '--bind-spec');
  }
  const policy = isObject(order.policy) ? order.policy : {};
  let approvedPlanSha256 = order.spec_hash;
  if (policy.plan_approval === 'required') {
    if (order.implementation_plan_approved !== true) {
      return { exit: EXIT.REFUSED, message: 'plan-approval-required', planApproval: true };
    }
    const listed = listOrderEvents(context, env);
    if (!listed.events && cliRefusal(listed.failure)) {
      return { exit: EXIT.REFUSED, message: `${refusedText('the order timeline read', listed.failure)}; finish with --reason` };
    }
    if (!listed.events) return { exit: EXIT.TRANSIENT, message: `the order timeline could not be read (${describeFailure(listed.failure)})` };
    const plan = approvedPlanCommit(listed.events, order.spec_hash);
    const planPath = plan && typeof plan.path === 'string' && PLAN_PATH_RE.test(plan.path) ? plan.path : planFileFor(context.marker.orderId);
    const planSha = plan && /^[0-9a-fA-F]{7,64}$/.test(String(plan.sha)) ? String(plan.sha).toLowerCase() : null;
    let approved = { ok: false, stdout: '' };
    if (planSha) {
      approved = git(context.projectRoot, ['show', `${planSha}:${planPath}`]);
      if (!approved.ok) {
        git(context.projectRoot, ['fetch', '--quiet', 'origin'], env);
        approved = git(context.projectRoot, ['show', `${planSha}:${planPath}`]);
      }
    }
    let current = null;
    try {
      current = fs.readFileSync(path.join(context.projectRoot, planPath), 'utf8');
    } catch (_) {
      current = null;
    }
    if (!planSha || !approved.ok || current === null || current !== approved.stdout) {
      let reason = 'The plan file on the order branch differs from the plan that was approved, so the session does not implement it.';
      if (!planSha) reason = 'The order timeline names no plan artifact before its approval, so the approved plan cannot be identified.';
      else if (!approved.ok) reason = 'The commit of the approved plan is not reachable from this checkout, so the approved plan cannot be compared.';
      else if (current === null) reason = 'The order branch carries no plan file, so the approved plan cannot be compared.';
      const blocked = deliverBlocked(context, { env, now, reason, eventKey: 'plan-mismatch' });
      return blockedResult(context, blocked, reason.replace(/\.$/, ''), '--bind-spec');
    }
    approvedPlanSha256 = crypto.createHash('sha256').update(approved.stdout, 'utf8').digest('hex');
  }
  const bindingValue = { orderId: context.marker.orderId.toLowerCase(), attempt: context.marker.attempt, specHash: order.spec_hash, approvedPlanSha256 };
  const pastImplementing = () => {
    writeOutbox(context, { deliveredRank: Math.max(readOutbox(context).deliveredRank || 0, STAGE_RANK.implementing) });
    return { exit: EXIT.OK, value: bindingValue };
  };
  if ((STAGE_RANK[order.status] || 0) > STAGE_RANK.implementing) return pastImplementing();
  if (branch && !branch.startsWith(branchPrefixOf(order))) return { exit: EXIT.REFUSED, message: foreignBranchMessage(context, branch) };
  const args = ['--stage', 'implementing', '--client-event-id', clientEventId(bound.runId, 'order-spec-bound'),
    '--autopilot-stage', 'AWAIT_TDD', '--autopilot-run-id', bound.runId];
  if (branch) args.push('--branch', branch);
  const sent = sendEvent(context, args, { env, now, target: 'implementing' });
  if (sent.verdict === 'ended') return endedResult(context, '');
  if (sent.verdict === VERDICTS.FINAL && sent.failure && sent.failure.code === 'invalid_transition') return pastImplementing();
  if (sent.verdict === VERDICTS.OK) {
    if (sent.order && sent.order.status === 'blocked') {
      noteBlockedOrder(context, sent.order, now);
      return { exit: EXIT.ENDED, message: `Zensu blocked work order ${context.marker.orderId} (${sent.order.blocked_kind || 'unknown'})` };
    }
    writeOutbox(context, { deliveredRank: Math.max(readOutbox(context).deliveredRank || 0, STAGE_RANK.implementing), lastStatus: 'implementing' });
    return { exit: EXIT.OK, value: bindingValue };
  }
  if (sent.verdict === VERDICTS.FINAL && sent.failure && sent.failure.code === 'plan_approval_required') {
    return { exit: EXIT.REFUSED, message: 'plan-approval-required', planApproval: true };
  }
  if (sent.verdict === VERDICTS.LOST) return { exit: EXIT.LOST, message: 'the lease is lost; stop without any forge write' };
  if (sent.verdict === VERDICTS.FINAL) return { exit: EXIT.REFUSED, message: `${refusedText('the implementing stage', sent.failure)}; finish with --reason` };
  return { exit: EXIT.TRANSIENT, message: `Zensu did not accept the implementing stage yet (${describeFailure(sent.failure)})` };
}

const BLOCK_REASONS = Object.freeze({
  TDD_MAX_ROUNDS: 'The implementation review did not converge within its round limit.',
  CONVERGENCE_LIMIT: 'The implementation still contradicts the specification after the allowed convergence fixes.',
  WORK_ORDER_STOPPED: 'The session stopped the run before it reached a ready pull request.',
});

function blockReasonFor(run, reason) {
  if (typeof reason === 'string' && reason.trim()) return reason.replace(/`/g, "'");
  if (run && run.stage === 'BLOCKED' && isObject(run.blocked)) {
    const known = BLOCK_REASONS[run.blocked.code];
    if (known) return known;
    const words = String(run.blocked.code || 'unknown').replace(/[^A-Za-z0-9]+/g, ' ').trim().toLowerCase();
    return `The Autopilot run was blocked at stage ${String(run.blocked.from || 'unknown').toLowerCase().replace(/_/g, ' ')} with block code ${words}.`;
  }
  if (run && run.stage === 'CANCELLED') return 'The Autopilot run was cancelled before it reached a ready pull request.';
  return 'The session ended before its Autopilot run reached a ready pull request.';
}

function runToCancel(context) {
  const outbox = readOutbox(context);
  const run = outbox.runId ? readRunRecord(context.projectRoot, outbox.runId) : null;
  return run && !['DONE', 'CANCELLED'].includes(run.stage) ? run.runId : null;
}

function finish(context, { env = process.env, now = Date.now, reason = null } = {}) {
  if (!context || context.fault) return { exit: EXIT.NOT_BOUND, message: context ? context.fault : 'this session runs no work order' };
  const ended = safeRead(context.files.ended).value;
  if (ended) {
    return {
      exit: ended.outcome === 'success' ? EXIT.OK : EXIT.ENDED,
      message: `the session of work order ${context.marker.orderId} has already ended (${ended.kind})`,
      ended,
      cancelRun: runToCancel(context),
    };
  }
  if (safeRead(context.files.lost).value) {
    markEnded(context, { outcome: 'failure', kind: 'lease-lost', delivered: false, reason: 'the lease was lost', at: now() });
    return { exit: EXIT.LOST, message: 'the lease is lost; nothing can be reported any more', cancelRun: runToCancel(context) };
  }
  const outbox = readOutbox(context);
  const run = outbox.runId ? readRunRecord(context.projectRoot, outbox.runId) : null;
  const stage = run ? run.stage : null;
  if (!['DONE', 'BLOCKED', 'CANCELLED'].includes(stage) && !(typeof reason === 'string' && reason.trim())) {
    return {
      exit: EXIT.REFUSED,
      message: run
        ? `Autopilot run ${run.runId} is still at ${stage}; continue it, or pass --reason to stop the work order`
        : 'no Autopilot run reached a terminal stage; continue the work order, or pass --reason to stop it',
    };
  }
  const drained = drain(context, { env, now });
  if (drained.verdict === 'ended') return endedResult(context, ' while its stages were reported', EXIT.OK);
  if (drained.verdict === VERDICTS.LOST) {
    markEnded(context, { outcome: 'failure', kind: 'lease-lost', delivered: false, reason: 'the lease was lost', at: now() });
    return { exit: EXIT.LOST, message: 'the lease is lost; nothing can be reported any more', cancelRun: runToCancel(context) };
  }
  let refused = null;
  if (stage === 'DONE') {
    if (drained.verdict === VERDICTS.FINAL) {
      refused = { status: drained.refused || null, failure: drained.failure };
    } else if (drained.verdict !== VERDICTS.OK) {
      return { exit: EXIT.TRANSIENT, message: `the stages before ready_for_merge are not delivered yet (${describeFailure(drained.failure)}); run --finish again` };
    } else {
      const deliveryEvent = run.events.find((event) => event.eventType === 'DELIVERY_COMPLETE');
      const evidence = isObject(run.evidence) ? run.evidence : {};
      const head = fullSha(context.projectRoot, deliveryEvent && deliveryEvent.payload ? deliveryEvent.payload.headSha : null);
      const pr = isObject(evidence.pr) ? evidence.pr : null;
      if (!head || !pr) return { exit: EXIT.REFUSED, message: 'the delivered head or pull request could not be read from the run record' };
      const args = ['--stage', 'ready_for_merge', '--head', head, '--pr-url', String(pr.url), '--pr-number', String(pr.number),
        '--autopilot-stage', 'DONE', '--autopilot-run-id', run.runId,
        '--client-event-id', clientEventId(run.runId, deliveryEvent.eventId)];
      const branch = reportableBranch(context);
      if (branch) args.push('--branch', branch);
      const record = { verb: 'event', args, ended: { outcome: 'success', kind: 'ready_for_merge' } };
      rememberTerminal(context, PENDING, record);
      const sent = sendEvent(context, args, { env, now, target: 'ready_for_merge', terminal: true });
      rememberTerminal(context, sent, record);
      if (sent.verdict === 'ended') return endedResult(context, '', EXIT.OK);
      if (sent.verdict === VERDICTS.OK) {
        markEnded(context, { outcome: 'success', kind: 'ready_for_merge', delivered: true, reason: null, at: now() });
        return { exit: EXIT.OK, message: `ready_for_merge is reported for work order ${context.marker.orderId}; the session is complete`, delivered: true };
      }
      if (sent.verdict === VERDICTS.TRANSIENT || sent.verdict === VERDICTS.RETRY) {
        return { exit: EXIT.TRANSIENT, message: `ready_for_merge is not delivered yet (${describeFailure(sent.failure)}); run --finish again` };
      }
      if (sent.verdict === VERDICTS.LOST) {
        markEnded(context, { outcome: 'failure', kind: 'ready_for_merge', delivered: false, reason: describeFailure(sent.failure), at: now() });
        return { exit: EXIT.LOST, message: `the lease was lost while ready_for_merge was reported (${describeFailure(sent.failure)})` };
      }
      refused = { status: 'ready_for_merge', failure: sent.failure };
    }
  }
  const prose = refused ? refusedStageReason(refused, reason) : blockReasonFor(run, reason);
  const blocked = deliverBlocked(context, {
    env,
    now,
    reason: prose,
    eventKey: refused ? `refused:${refused.status || 'stage'}` : (run ? `run:${run.runId}` : 'no-run'),
    fallback: refused ? refusedStageReason(refused, null) : blockReasonFor(run, null),
  });
  if (blocked.verdict === 'ended') return endedResult(context, '', EXIT.OK);
  if (blocked.delivered) {
    const cause = refused ? ` because ${refusedText(`the ${refused.status || 'earlier'} stage`, refused.failure)}` : '';
    const swap = blocked.replaced ? `; Zensu refused the stated reason as prose, so the block carries "${blocked.reason}" instead` : '';
    return { exit: EXIT.ENDED, message: `work order ${context.marker.orderId} is blocked with worker_error${cause}${swap}; the session has ended`, delivered: true, cancelRun: runToCancel(context) };
  }
  if (blocked.verdict === VERDICTS.LOST) return { exit: EXIT.LOST, message: 'the lease is lost; the block could not be reported', cancelRun: runToCancel(context) };
  if (blocked.verdict === VERDICTS.FINAL) return { exit: EXIT.REFUSED, message: `${refusedText('the block', blocked.failure)}; end the session`, cancelRun: runToCancel(context) };
  return { exit: EXIT.TRANSIENT, message: `the block is not delivered yet (${describeFailure(blocked.failure)}); run --finish again` };
}

function push(context, { env = process.env, now = Date.now } = {}) {
  if (!context || context.fault) return { exit: EXIT.NOT_BOUND, message: context ? context.fault : 'this session runs no work order' };
  const forge = forgeWriteVerdict(context, now());
  if (!forge.allowed) return { exit: EXIT.LOST, message: `${forge.reason}; no push` };
  const beat = renew(context, { env, now: now(), force: true });
  if (beat.verdict === 'ended') return endedResult(context, '; no push');
  if (beat.verdict !== VERDICTS.OK) {
    return { exit: beat.verdict === VERDICTS.LOST ? EXIT.LOST : EXIT.TRANSIENT, message: `the lease renewal before the push did not succeed (${describeFailure(beat.failure)}); no push` };
  }
  const status = beat.lease.orderStatus;
  if (!(status in STAGE_RANK) || status === 'claimed' || status === 'ready_for_merge') {
    return { exit: EXIT.REFUSED, message: `work order ${context.marker.orderId} is ${status || 'in an unknown status'}; report the planning stage before the first push` };
  }
  const branch = currentBranch(context.projectRoot);
  const head = currentHead(context.projectRoot);
  if (!branch || !head) return { exit: EXIT.REFUSED, message: 'the working tree has no branch or no commit to push' };
  if (!branch.startsWith(orderBranchPrefix(context))) return { exit: EXIT.REFUSED, message: foreignBranchMessage(context, branch) };
  const expect = beat.lease.recordedHead && FULL_SHA_RE.test(String(beat.lease.recordedHead).toLowerCase())
    ? String(beat.lease.recordedHead).toLowerCase() : '';
  const listed = git(context.projectRoot, ['ls-remote', 'origin', `refs/heads/${branch}`], env);
  if (!listed.ok) {
    return { exit: EXIT.TRANSIENT, message: `the remote branch could not be read: ${listed.stderr.trim().split('\n').slice(-1)[0] || 'no detail'}` };
  }
  const remoteHead = (listed.stdout.trim().split(/\s+/)[0] || '').toLowerCase();
  if (remoteHead !== head) {
    const pushed = git(context.projectRoot, ['push', '--porcelain', `--force-with-lease=refs/heads/${branch}:${expect}`, 'origin', `HEAD:refs/heads/${branch}`], env);
    if (!pushed.ok) {
      return {
        exit: EXIT.REFUSED,
        message: `git push refused; the remote branch does not hold the head Zensu recorded for this order (${expect || 'no branch yet'}): ${pushed.stderr.trim().split('\n').slice(-1)[0] || 'no detail'}`,
      };
    }
  }
  const args = ['--stage', status, '--head', head, '--branch', branch,
    '--client-event-id', clientEventId(context.marker.orderId, context.marker.attempt, 'head', status, head)];
  const outbox = readOutbox(context);
  if (outbox.runId) args.push('--autopilot-run-id', outbox.runId);
  const sent = sendEvent(context, args, { env, now, target: status });
  if (sent.verdict === 'ended') return endedResult(context, '; the push landed');
  if (sent.verdict === VERDICTS.LOST) {
    return { exit: EXIT.LOST, message: `the push landed but the lease is lost (${describeFailure(sent.failure)}); stop without any forge write` };
  }
  if (sent.verdict === VERDICTS.FINAL) {
    return { exit: EXIT.REFUSED, message: `the push landed but ${refusedText('to record the new head', sent.failure)}; finish with --reason` };
  }
  if (sent.verdict !== VERDICTS.OK) {
    return { exit: EXIT.TRANSIENT, message: `the push landed but Zensu has not recorded the new head yet (${describeFailure(sent.failure)}); run --push again` };
  }
  const lease = safeRead(context.files.lease).value || {};
  writeState(context.projectRoot, context.files.lease, { ...lease, recordedHead: head });
  return { exit: EXIT.OK, value: { branch, head } };
}

const PR_NUMBER_IN_URL_RE = /\/(?:pull|merge_requests)\/(\d+)(?:[/?#]|$)/;

function locatePullRequest(context, { env, vcs, provider, number }) {
  const located = spawnSync('bash', [vcs, '--locate-pr', '--provider', provider, ...(number ? [String(number)] : [])], {
    env, cwd: context.projectRoot, encoding: 'utf8', timeout: 60000,
  });
  if (located.status !== 0) return null;
  try {
    const parsed = JSON.parse(located.stdout);
    if (!isObject(parsed) || !/^[1-9][0-9]*$/.test(String(parsed.id)) || !/^https:\/\//.test(String(parsed.url))) return null;
    return { number: Number(parsed.id), url: parsed.url, state: parsed.state, base: typeof parsed.base === 'string' ? parsed.base : null, head: parsed.head };
  } catch (_) {
    return null;
  }
}

function existingPullRequest(context, { env, vcs, provider, order, branch }) {
  const fromUrl = typeof order.pr_url === 'string' ? PR_NUMBER_IN_URL_RE.exec(order.pr_url) : null;
  const recorded = Number.isSafeInteger(order.pr_number) && order.pr_number > 0 ? order.pr_number : (fromUrl ? Number(fromUrl[1]) : null);
  if (recorded) {
    const pr = locatePullRequest(context, { env, vcs, provider, number: recorded });
    if (!pr) return { refused: `the pull request #${recorded} this order names could not be read; run --open-pr again, and after three failures finish with --reason` };
    if (pr.state !== 'OPEN') return { refused: `the pull request #${recorded} this order names is ${String(pr.state).toLowerCase()}; finish with --reason, because a person decides what happens to it` };
    if (pr.head !== branch) return { refused: `the pull request #${recorded} this order names belongs to branch ${pr.head}, not ${branch}; finish with --reason` };
    return { pr };
  }
  const pr = locatePullRequest(context, { env, vcs, provider, number: null });
  if (pr && pr.state === 'OPEN' && pr.head === branch) return { pr };
  return {};
}

function openPr(context, { env = process.env, now = Date.now, title, bodyFile, provider } = {}) {
  if (!context || context.fault) return { exit: EXIT.NOT_BOUND, message: context ? context.fault : 'this session runs no work order' };
  if (typeof title !== 'string' || !title.trim() || typeof bodyFile !== 'string' || !bodyFile) {
    return { exit: EXIT.USAGE, message: '--open-pr needs --title and --body-file' };
  }
  const forge = forgeWriteVerdict(context, now());
  if (!forge.allowed) return { exit: EXIT.LOST, message: `${forge.reason}; no pull request` };
  const beat = renew(context, { env, now: now(), force: true });
  if (beat.verdict === 'ended') return endedResult(context, '; no pull request');
  if (beat.verdict !== VERDICTS.OK) {
    return { exit: beat.verdict === VERDICTS.LOST ? EXIT.LOST : EXIT.TRANSIENT, message: `the lease renewal before opening the pull request did not succeed (${describeFailure(beat.failure)})` };
  }
  const branch = currentBranch(context.projectRoot);
  const head = currentHead(context.projectRoot);
  if (!branch || !head || String(beat.lease.recordedHead || '').toLowerCase() !== head) {
    return { exit: EXIT.REFUSED, message: 'push the branch with --push before opening the pull request' };
  }
  const snapshot = safeRead(context.files.order).value;
  const order = snapshot && isObject(snapshot.order) ? snapshot.order : {};
  const plan = isObject(order.plan) ? order.plan : {};
  const base = plan.integration_branch || plan.base_branch || 'main';
  const vcs = path.join(__dirname, 'zensu-vcs.sh');
  let chosen = provider;
  if (!chosen) {
    const detected = spawnSync('bash', [vcs, '--detect', '--repo', context.projectRoot], { env, encoding: 'utf8', timeout: 60000 });
    const match = /^provider=(github|gitlab)$/m.exec(detected.stdout || '');
    chosen = match ? match[1] : null;
  }
  if (!['github', 'gitlab'].includes(chosen)) return { exit: EXIT.REFUSED, message: 'the forge of this repository could not be detected' };
  const existing = existingPullRequest(context, { env, vcs, provider: chosen, order, branch });
  if (existing.refused) return { exit: EXIT.REFUSED, message: existing.refused };
  if (existing.pr) {
    return { exit: EXIT.OK, value: { url: existing.pr.url, number: existing.pr.number, base: existing.pr.base || base, branch, head, imported: true } };
  }
  const opened = spawnSync('bash', [vcs, '--open-pr', '--provider', chosen, '--base', base, '--head', branch, '--title', title, '--body-file', bodyFile], {
    env, cwd: context.projectRoot, encoding: 'utf8', timeout: 120000,
  });
  const url = (opened.stdout || '').trim().split('\n').pop();
  if (opened.status !== 0 || !/^https:\/\//.test(url || '')) {
    return { exit: EXIT.REFUSED, message: `the pull request could not be opened: ${(opened.stderr || '').trim().split('\n').slice(-1)[0] || 'no detail'}` };
  }
  const number = Number(/\/(?:pull|merge_requests)\/(\d+)/.exec(url) ? /\/(?:pull|merge_requests)\/(\d+)/.exec(url)[1] : NaN);
  return { exit: EXIT.OK, value: { url, number: Number.isSafeInteger(number) ? number : null, base, branch, head } };
}

const REVIEW_MARKER_RE = /^<!-- zensu-review:v1:([a-f0-9]{64}):([a-f0-9]{64}):([a-f0-9]{7,64}):([1-9][0-9]{0,5}):part=1\/([1-9][0-9]{0,5}) -->$/;
const MAX_REVIEW_MARKERS = 200;
const TERMINAL_RUN_STAGES = new Set(['DONE', 'CANCELLED']);

function workOrderReviewKey(orderId, headSha) {
  const canonical = `{"headSha":${JSON.stringify(String(headSha).toLowerCase())},"orderId":${JSON.stringify(String(orderId).toLowerCase())}}`;
  return `team-review:v1:${crypto.createHash('sha256').update(canonical).digest('hex')}`;
}

function detectForge(context, env) {
  const vcs = path.join(__dirname, 'zensu-vcs.sh');
  const detected = spawnSync('bash', [vcs, '--detect', '--repo', context.projectRoot], { env, encoding: 'utf8', timeout: 60000 });
  const provider = /^provider=(github|gitlab)$/m.exec(detected.stdout || '');
  const repo = /^repo=(\S+)$/m.exec(detected.stdout || '');
  return { vcs, provider: provider ? provider[1] : null, repo: repo ? repo[1] : null };
}

function commitPresent(projectRoot, sha) {
  return git(projectRoot, ['cat-file', '-e', `${sha}^{commit}`]).ok;
}

function reviewImport(context, { env = process.env, now = Date.now, runId } = {}) {
  if (!context || context.fault) return { exit: EXIT.NOT_BOUND, message: context ? context.fault : 'this session runs no work order' };
  const bound = markerRun(context, runId);
  if (bound.error) return { exit: EXIT.NOT_BOUND, message: bound.error };
  const forge = forgeWriteVerdict(context, now());
  if (!forge.allowed) return { exit: EXIT.LOST, message: forge.reason };
  const run = readRunRecord(context.projectRoot, bound.runId);
  const orderId = context.marker.orderId.toLowerCase();
  if (!run || !isObject(run.workOrder) || run.workOrder.orderId !== orderId) {
    return { exit: EXIT.NOT_BOUND, message: `Autopilot run ${bound.runId} is not bound to work order ${context.marker.orderId}` };
  }
  const prior = run.events.find((event) => event.eventType === 'TEAM_REVIEW_IMPORTED');
  if (prior && isObject(prior.payload)) {
    return { exit: EXIT.OK, value: { imported: true, operationKey: prior.payload.operationKey, headSha: prior.payload.headSha, provider: prior.payload.provider }, already: true };
  }
  const review = isObject(run.effects) && isObject(run.effects.teamReview) ? run.effects.teamReview : {};
  if (run.stage !== 'TEAM_REVIEW' || review.status !== 'none') {
    return { exit: EXIT.REFUSED, message: `Autopilot run ${bound.runId} is at ${run.stage}; --review-import runs at TEAM_REVIEW before TEAM_REVIEW_REQUESTED` };
  }
  const pr = isObject(run.evidence) && isObject(run.evidence.pr) ? run.evidence.pr : null;
  if (!pr || !Number.isSafeInteger(pr.number) || !/^[0-9a-fA-F]{7,64}$/.test(String(pr.headSha))) {
    return { exit: EXIT.REFUSED, message: `Autopilot run ${bound.runId} records no opened pull request` };
  }
  const prHead = String(pr.headSha).toLowerCase();
  const { vcs, provider, repo } = detectForge(context, env);
  if (!provider || !repo) return { exit: EXIT.REFUSED, message: 'the forge of this repository could not be detected' };
  const fresh = { imported: false, operationKey: workOrderReviewKey(orderId, prHead), headSha: prHead, provider };
  const listed = spawnSync('bash', [vcs, '--review-markers', '--provider', provider, '--repo-id', repo, String(pr.number)], {
    env, cwd: context.projectRoot, encoding: 'utf8', timeout: 120000,
  });
  if (listed.status !== 0) {
    return { exit: EXIT.REFUSED, message: 'the team-review markers on the pull request could not be read; run --review-import again, and after three failures finish with --reason' };
  }
  const candidates = [];
  for (const line of String(listed.stdout || '').split('\n').slice(0, MAX_REVIEW_MARKERS)) {
    const match = REVIEW_MARKER_RE.exec(line.trim());
    if (!match || match[4] !== match[5]) continue;
    const headSha = match[3];
    const operationKey = workOrderReviewKey(orderId, headSha);
    if (crypto.createHash('sha256').update(operationKey).digest('hex') !== match[1]) continue;
    candidates.push({ marker: match[0], headSha, operationKey });
  }
  if (candidates.length === 0) return { exit: EXIT.OK, value: fresh };
  if (candidates.some((candidate) => !commitPresent(context.projectRoot, candidate.headSha))) {
    git(context.projectRoot, ['fetch', '--quiet', 'origin'], env);
  }
  let chosen = null;
  for (const candidate of candidates) {
    if (!commitPresent(context.projectRoot, candidate.headSha)) continue;
    if (!git(context.projectRoot, ['merge-base', '--is-ancestor', candidate.headSha, prHead]).ok) continue;
    const counted = git(context.projectRoot, ['rev-list', '--count', `${candidate.headSha}..${prHead}`]);
    const distance = counted.ok ? Number(counted.stdout.trim()) : NaN;
    if (!Number.isSafeInteger(distance)) continue;
    if (!chosen || distance < chosen.distance) chosen = { ...candidate, distance };
  }
  if (!chosen) return { exit: EXIT.OK, value: fresh };
  return {
    exit: EXIT.OK,
    value: {
      imported: true,
      operationKey: chosen.operationKey,
      headSha: chosen.headSha,
      provider,
      payload: { operationKey: chosen.operationKey, marker: chosen.marker, headSha: chosen.headSha, provider },
    },
  };
}

function releasePlan(projectRoot, orderId, belowAttempt) {
  if (typeof projectRoot !== 'string' || !path.isAbsolute(projectRoot) || !ORDER_ID_RE.test(String(orderId || ''))
    || !Number.isSafeInteger(belowAttempt) || belowAttempt < 1) return [];
  const stateDir = path.join(projectRoot, '.zensu', 'state');
  let names;
  try {
    names = fs.readdirSync(stateDir);
  } catch (_) {
    return [];
  }
  const runs = [];
  for (const name of names.sort()) {
    const match = /^autopilot-run-(.+)\.json$/.exec(name);
    if (!match || !RUN_ID_RE.test(match[1])) continue;
    const run = readRunRecord(projectRoot, match[1]);
    if (!run || !isObject(run.workOrder) || run.workOrder.orderId !== String(orderId).toLowerCase()) continue;
    if (!Number.isSafeInteger(run.workOrder.attempt) || run.workOrder.attempt >= belowAttempt) continue;
    if (TERMINAL_RUN_STAGES.has(run.stage)) continue;
    runs.push(run.runId);
  }
  return runs;
}

const TOKEN_VARIABLE = 'ZENSU_SESSION_TOKEN';
const HOST_VARIABLE = 'ZENSU_API_URL';
const ASK_TOOLS = new Set(['AskUserQuestion', 'EnterPlanMode', 'ExitPlanMode']);
const CHIP_TOOLS = new Set(['mcp__ccd_session__spawn_task', 'mcp__ccd_session__start_session']);
const SHELL_KEYWORDS = new Set(['{', '}', '!', 'if', 'then', 'else', 'elif', 'fi', 'do', 'done', 'while', 'until', 'for', 'select', 'case', 'esac', 'function', 'coproc']);
const SHELL_WRAPPERS = new Set(['command', 'builtin', 'exec', 'env', 'sudo', 'doas', 'nohup', 'nice', 'time', 'timeout', 'gtimeout', 'stdbuf', 'xargs']);
const SHELL_INTERPRETERS = new Set(['bash', 'sh', 'zsh', 'dash', 'ksh']);
const VARIABLE_BUILTINS = new Set(['export', 'declare', 'typeset', 'readonly', 'local']);
const SUDO_OPERAND_OPTIONS = new Set(['-u', '-g', '-h', '-p', '-C', '-T', '-r', '-t', '-D', '-R']);
const SESSION_WORK_VERBS = new Set(['get', 'events', 'ask', 'followup']);
const ORDER_FILE_WORK_VERBS = new Set(['list', 'questions']);
const HELPER_WORK_VERBS = new Set(['event', 'heartbeat']);
const HUMAN_PLAN_VERBS = new Set(['push', 'approve', 'finalize', 'abandon', 'confirm-merge', 'followup']);
const WORK_VERB_ALIASES = new Map([['repos', 'repositories']]);
const TOKEN_EXPANSION_RE = /\$\{?[!#]?ZENSU_SESSION_TOKEN(?![A-Za-z0-9_])/;
const PROCESS_ENVIRONMENT_RE = /\/proc\/[^/\s]+\/environ(?![A-Za-z0-9_])/;
const MAX_SHELL_DEPTH = 4;
const SHELL_READINGS = ['posix', 'bash', 'zsh'];
const ENV_SHORT_OPERANDS = new Set(['u', 'C', 'P', 'S', 'a', 'L', 'U']);
const ENV_LONG_OPERANDS = new Set(['unset', 'chdir', 'split-string', 'argv0']);
const VARIABLE_READERS = new Set(['read', 'mapfile', 'readarray', 'getopts']);
const HOOK_RETRY_BUDGET_MS = 5000;

function stripHeredocBodies(text) {
  try {
    return require('./bash-source-write-parse.js').stripHeredocs(text);
  } catch (_) {
    return text;
  }
}

function gitOperandOptions() {
  try {
    return new Set(require('./bash-source-write-parse.js').GIT_OPTS_WITH_OPERAND);
  } catch (_) {
    return new Set(['-C', '-c', '--git-dir', '--work-tree', '--namespace', '--exec-path', '--super-prefix', '--config-env']);
  }
}

function matchingParen(text, open, reading = 'posix') {
  let depth = 0;
  for (let index = open; index < text.length; index += 1) {
    const char = text[index];
    if (char === '\\') {
      index += 1;
      continue;
    }
    if (reading === 'bash' && char === '$' && text[index + 1] === '$') {
      index += 1;
      continue;
    }
    if (reading !== 'posix' && char === '$' && text[index + 1] === "'") {
      index = ansiCStringEnd(text, index + 2);
      continue;
    }
    if (char === "'") {
      const end = text.indexOf("'", index + 1);
      if (end < 0) return text.length;
      index = end;
      continue;
    }
    if (char === '(') depth += 1;
    if (char === ')') {
      depth -= 1;
      if (depth === 0) return index;
    }
  }
  return text.length;
}

const ANSI_ESCAPES = { a: 7, b: 8, e: 27, E: 27, f: 12, n: 10, r: 13, t: 9, v: 11 };

function ansiCStringEnd(text, start) {
  let end = start;
  while (end < text.length && text[end] !== "'") end += text[end] === '\\' ? 2 : 1;
  return Math.min(end, text.length);
}

function ansiCString(text, start) {
  const end = ansiCStringEnd(text, start);
  const body = text.slice(start, end);
  let value = '';
  let cursor = 0;
  while (cursor < body.length) {
    if (body[cursor] !== '\\' || cursor + 1 >= body.length) {
      value += body[cursor];
      cursor += 1;
      continue;
    }
    const code = body[cursor + 1];
    const rest = body.slice(cursor + 2);
    let match = null;
    if (Object.prototype.hasOwnProperty.call(ANSI_ESCAPES, code)) {
      value += String.fromCharCode(ANSI_ESCAPES[code]);
      cursor += 2;
    } else if (/[0-7]/.test(code)) {
      match = /^[0-7]{1,3}/.exec(body.slice(cursor + 1));
      value += String.fromCharCode(parseInt(match[0], 8) & 255);
      cursor += 1 + match[0].length;
    } else if (code === 'x' && (match = /^[0-9A-Fa-f]{1,2}/.exec(rest))) {
      value += String.fromCharCode(parseInt(match[0], 16));
      cursor += 2 + match[0].length;
    } else if ((code === 'u' || code === 'U') && (match = (code === 'u' ? /^[0-9A-Fa-f]{1,4}/ : /^[0-9A-Fa-f]{1,8}/).exec(rest))) {
      const point = parseInt(match[0], 16);
      value += point <= 1114111 ? String.fromCodePoint(point) : '';
      cursor += 2 + match[0].length;
    } else if (code === 'c' && rest.length > 0) {
      value += String.fromCharCode(rest.charCodeAt(0) & 31);
      cursor += 3;
    } else if (code === '\\' || code === "'" || code === '"' || code === '?') {
      value += code;
      cursor += 2;
    } else {
      value += `\\${code}`;
      cursor += 2;
    }
  }
  return { value, end };
}

function shellCommands(text, depth = 0, reading = 'bash') {
  const commands = [];
  if (depth > MAX_SHELL_DEPTH) return commands;
  let words = [];
  let word = null;
  const add = (piece) => {
    word = (word === null ? '' : word) + piece;
  };
  const endWord = () => {
    if (word !== null) words.push(reading === 'zsh' && word.includes('\u0000') ? word.slice(0, word.indexOf('\u0000')) : word);
    word = null;
  };
  const endCommand = () => {
    endWord();
    if (words.length > 0) commands.push(words);
    words = [];
  };
  const nested = (inner) => {
    for (const command of shellCommands(inner, depth + 1, reading)) commands.push(command);
  };
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    const next = text[index + 1];
    if (char === '\\') {
      if (next !== '\n') add(next === undefined ? '' : next);
      index += 1;
      continue;
    }
    if (reading === 'bash' && char === '$' && next === '$') {
      add('$$');
      index += 1;
      continue;
    }
    if (reading !== 'posix' && char === '$' && next === "'") {
      const decoded = ansiCString(text, index + 2);
      add(reading === 'bash' && decoded.value.includes('\u0000') ? decoded.value.slice(0, decoded.value.indexOf('\u0000')) : decoded.value);
      index = decoded.end;
      continue;
    }
    if (reading !== 'posix' && char === '$' && next === '"') continue;
    if (char === "'") {
      const end = text.indexOf("'", index + 1);
      const stop = end < 0 ? text.length : end;
      add(text.slice(index + 1, stop));
      index = stop;
      continue;
    }
    if (char === '"') {
      let cursor = index + 1;
      let value = '';
      while (cursor < text.length && text[cursor] !== '"') {
        if (text[cursor] === '\\' && cursor + 1 < text.length) {
          value += text[cursor + 1];
          cursor += 2;
          continue;
        }
        if (text[cursor] === '$' && text[cursor + 1] === '(') {
          const close = matchingParen(text, cursor + 1, reading);
          nested(text.slice(cursor + 2, close));
          cursor = close + 1;
          continue;
        }
        if (text[cursor] === '`') {
          const end = text.indexOf('`', cursor + 1);
          const stop = end < 0 ? text.length : end;
          nested(text.slice(cursor + 1, stop));
          cursor = stop + 1;
          continue;
        }
        value += text[cursor];
        cursor += 1;
      }
      add(value);
      index = cursor;
      continue;
    }
    if ((char === '$' || char === '<' || char === '>') && next === '(') {
      const close = matchingParen(text, index + 1, reading);
      nested(text.slice(index + 2, close));
      add('');
      index = close;
      continue;
    }
    if (char === '$' && next === '{') {
      const close = text.indexOf('}', index + 2);
      const stop = close < 0 ? text.length : close;
      add(text.slice(index, stop + 1));
      index = stop;
      continue;
    }
    if (char === '`') {
      const end = text.indexOf('`', index + 1);
      const stop = end < 0 ? text.length : end;
      nested(text.slice(index + 1, stop));
      add('');
      index = stop;
      continue;
    }
    if (char === ';' || char === '\n' || char === '|' || char === '&' || char === '(' || char === ')') {
      endCommand();
      continue;
    }
    if (char === ' ' || char === '\t' || char === '\r' || char === '<' || char === '>') {
      endWord();
      continue;
    }
    add(char);
  }
  endCommand();
  return commands;
}

function commandName(word) {
  return String(word || '').split('/').pop();
}

function splitEnvString(operand) {
  return shellCommands(String(operand || ''), 0, 'posix').flat();
}

function interpreterOptionEnd(args) {
  let index = 0;
  while (index < args.length && /^[-+]/.test(args[index])) {
    const word = args[index];
    if (word === '-' || word === '--') return index + 1;
    if (/^--?(?:rcfile|init-file|emulate)$/.test(word)) {
      index += 2;
      continue;
    }
    index += 1 + (word.startsWith('--') ? 0 : (word.slice(1).match(/[oOR]/g) || []).length);
  }
  return index;
}

function leadingCommand(words) {
  words = words.slice();
  const assignments = [];
  const unset = [];
  let bareEnv = false;
  let index = 0;
  const takeAssignments = () => {
    while (index < words.length && /^[A-Za-z_][A-Za-z0-9_]*\+?=/.test(words[index])) {
      assignments.push(words[index].slice(0, words[index].indexOf('=')).replace(/\+$/, ''));
      index += 1;
    }
  };
  for (let guard = 0; guard < 16; guard += 1) {
    while (index < words.length && SHELL_KEYWORDS.has(words[index])) index += 1;
    takeAssignments();
    if (index >= words.length) break;
    const name = commandName(words[index]);
    if (!SHELL_WRAPPERS.has(name)) break;
    index += 1;
    if (name === 'env') {
      while (index < words.length) {
        const option = words[index];
        if (option === '--') {
          index += 1;
          break;
        }
        if (option === '-') {
          unset.push(TOKEN_VARIABLE, HOST_VARIABLE);
          index += 1;
          continue;
        }
        if (option.startsWith('--')) {
          unset.push(TOKEN_VARIABLE, HOST_VARIABLE);
          const key = option.slice(2).split('=')[0];
          const attached = option.includes('=') ? option.slice(option.indexOf('=') + 1) : null;
          index += 1;
          const operand = attached !== null || !ENV_LONG_OPERANDS.has(key) ? attached : String(words[index++] || '');
          if (key === 'unset' && operand !== null) unset.push(operand);
          if (key === 'split-string' && operand !== null) words.splice(index, 0, ...splitEnvString(operand));
          continue;
        }
        if (!option.startsWith('-')) break;
        index += 1;
        for (let at = 1; at < option.length; at += 1) {
          const letter = option[at];
          if (letter === 'i') unset.push(TOKEN_VARIABLE, HOST_VARIABLE);
          if (!ENV_SHORT_OPERANDS.has(letter)) continue;
          const operand = at + 1 < option.length ? option.slice(at + 1) : String(words[index++] || '');
          if (letter === 'u') unset.push(operand);
          if (letter === 'S') words.splice(index, 0, ...splitEnvString(operand));
          break;
        }
      }
      takeAssignments();
      if (index >= words.length) bareEnv = true;
      continue;
    }
    while (index < words.length) {
      const option = words[index];
      if ((name === 'sudo' || name === 'doas') && SUDO_OPERAND_OPTIONS.has(option)) {
        index += 2;
        continue;
      }
      if (name === 'exec' && /^-[A-Za-z]+$/.test(option)) {
        if (option.includes('c')) unset.push(TOKEN_VARIABLE, HOST_VARIABLE);
        index += option.includes('a') ? 2 : 1;
        continue;
      }
      if (option.startsWith('-') || /^[0-9.]+[smhd]?$/.test(option)) {
        index += 1;
        continue;
      }
      break;
    }
  }
  return {
    assignments,
    unset,
    bareEnv,
    name: index < words.length ? commandName(words[index]) : null,
    args: words.slice(index + 1),
  };
}

function plainWords(args, operandOptions = new Set()) {
  const plain = [];
  for (let index = 0; index < args.length; index += 1) {
    const word = args[index];
    if (operandOptions.has(word)) {
      index += 1;
      continue;
    }
    if (word.startsWith('-')) continue;
    plain.push(word);
  }
  return plain;
}

function zensuCommandWords(args) {
  const words = [];
  for (let index = 0; index < args.length && words.length < 3; index += 1) {
    const word = args[index];
    if (word === '--') break;
    if (word === '') continue;
    if (word.startsWith('-')) {
      if (!word.includes('=') && (word.length === 2 || word[1] === '-')) index += 1;
      continue;
    }
    words.push(word);
  }
  return words;
}

function gitSubcommand(args) {
  const operands = gitOperandOptions();
  for (let index = 0; index < args.length; index += 1) {
    const word = args[index];
    if (operands.has(word)) {
      index += 1;
      continue;
    }
    if (word.startsWith('-')) continue;
    return word;
  }
  return null;
}

function bashFinding(code, detail) {
  return { code, detail };
}

function analyzeBash(command, depth = 0) {
  const text = String(command || '');
  const result = { deny: null, forge: false };
  if (!text.trim() || depth > MAX_SHELL_DEPTH) return result;
  if (TOKEN_EXPANSION_RE.test(text)) {
    result.deny = bashFinding('token', 'it expands the session token variable');
    return result;
  }
  if (PROCESS_ENVIRONMENT_RE.test(text)) {
    result.deny = bashFinding('token', 'it reads a process environment file');
    return result;
  }
  const stripped = stripHeredocBodies(text);
  const seen = new Set();
  const readings = SHELL_READINGS.flatMap((reading) => shellCommands(stripped, 0, reading)).filter((words) => {
    const key = JSON.stringify(words);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  for (const words of readings) {
    const lead = leadingCommand(words);
    if (lead.assignments.includes(TOKEN_VARIABLE) || lead.unset.includes(TOKEN_VARIABLE)) {
      result.deny = bashFinding('token', 'it overrides or removes the session token variable');
      return result;
    }
    if (lead.assignments.includes(HOST_VARIABLE) || lead.unset.includes(HOST_VARIABLE)) {
      result.deny = bashFinding('token-host', `it sets or removes ${HOST_VARIABLE}`);
      return result;
    }
    if (lead.bareEnv) {
      result.deny = bashFinding('token', 'it prints the whole environment');
      return result;
    }
    const { name, args } = lead;
    if (!name) continue;
    const named = (variable) => name === variable
      || (name === 'printf' && args.some((arg, index) => arg === `-v${variable}` || (arg === '-v' && args[index + 1] === variable)))
      || (VARIABLE_READERS.has(name) && args.includes(variable))
      || (name === 'let' && args.some((arg) => new RegExp(`(?<![A-Za-z0-9_])${variable}(?![A-Za-z0-9_])`).test(arg)))
      || (VARIABLE_BUILTINS.has(name) && args.some((arg) => /^-[A-Za-z]*n/.test(arg))
        && args.some((arg) => arg.includes('=') && arg.slice(arg.indexOf('=') + 1) === variable));
    if (named(TOKEN_VARIABLE)) {
      result.deny = bashFinding('token', 'it overrides or removes the session token variable');
      return result;
    }
    if (named(HOST_VARIABLE)) {
      result.deny = bashFinding('token-host', `it sets or removes ${HOST_VARIABLE}`);
      return result;
    }
    if (SHELL_INTERPRETERS.has(name) || name === 'eval') {
      const optionEnd = name === 'eval' ? 0 : interpreterOptionEnd(args);
      const at = args.slice(0, optionEnd).findIndex((arg) => /^[-+][A-Za-z]*c[A-Za-z]*$/.test(arg));
      if (at >= 0 && (/[oOR]/.test(args[at].slice(1)) || /^[-+]/.test(String(args[at + 1] || '')))) {
        result.deny = bashFinding('shell-option', `${name} ${args.slice(at, at + 2).join(' ')}`);
        return result;
      }
      const evalWords = name === 'eval' && (args[0] === '--' || args[0] === '-') ? args.slice(1) : args;
      const inner = name === 'eval' ? evalWords.join(' ') : (at >= 0 ? String(args[at + 1] || '') : '');
      if (inner) {
        const innerResult = analyzeBash(inner, depth + 1);
        if (innerResult.deny) return innerResult;
        result.forge = result.forge || innerResult.forge;
      } else if (name !== 'eval' && commandName(plainWords(args)[0]) === 'zensu-vcs.sh') {
        result.forge = true;
      }
      continue;
    }
    if (name === 'printenv') {
      const names = args.filter((arg) => !arg.startsWith('-'));
      if (names.length === 0 || names.includes(TOKEN_VARIABLE)) {
        result.deny = bashFinding('token', 'it prints the environment');
        return result;
      }
      continue;
    }
    if (name === 'set' && args.length === 0) {
      result.deny = bashFinding('token', 'it prints every shell variable');
      return result;
    }
    if (VARIABLE_BUILTINS.has(name)) {
      const names = args.filter((arg) => !arg.startsWith('-')).map((arg) => arg.split('=')[0]);
      if (names.length === 0 && name !== 'local') {
        result.deny = bashFinding('token', 'it prints every exported variable');
        return result;
      }
      if (names.includes(TOKEN_VARIABLE)) {
        result.deny = bashFinding('token', 'it overrides or prints the session token variable');
        return result;
      }
      if (names.includes(HOST_VARIABLE)) {
        result.deny = bashFinding('token-host', `it sets ${HOST_VARIABLE}`);
        return result;
      }
      continue;
    }
    if (name === 'unset' && args.includes(TOKEN_VARIABLE)) {
      result.deny = bashFinding('token', 'it removes the session token variable');
      return result;
    }
    if (name === 'unset' && args.includes(HOST_VARIABLE)) {
      result.deny = bashFinding('token-host', `it removes ${HOST_VARIABLE}`);
      return result;
    }
    if (name === 'git') {
      if (gitSubcommand(args) === 'push') {
        result.deny = bashFinding('push', null);
        return result;
      }
      continue;
    }
    if (name === 'gh' || name === 'glab') {
      result.forge = true;
      const [noun, verb] = plainWords(args, new Set(['-R', '--repo']));
      const request = name === 'gh' ? 'pr' : 'mr';
      if (noun === request && verb === 'create') {
        result.deny = bashFinding('open-pr', null);
        return result;
      }
      if (noun === request && verb === 'merge') {
        result.deny = bashFinding('merge', null);
        return result;
      }
      continue;
    }
    if (name === 'zensu-vcs.sh') {
      result.forge = true;
      continue;
    }
    if (name === 'zensu') {
      if (args.some((arg) => arg === '--api-url' || arg.startsWith('--api-url='))) {
        result.deny = bashFinding('token-host', 'it passes --api-url to zensu');
        return result;
      }
      const [noun, named, third] = zensuCommandWords(args);
      const verb = noun === 'work' ? (WORK_VERB_ALIASES.get(named) || named) : named;
      if (noun === 'auth') {
        result.deny = bashFinding('auth', null);
        return result;
      }
      if (noun === 'work' && verb) {
        if (HELPER_WORK_VERBS.has(verb)) {
          result.deny = bashFinding('helper-verb', `zensu work ${verb}`);
          return result;
        }
        const scoped = (verb === 'policy' || verb === 'repositories') && third ? ` ${third}` : '';
        if (ORDER_FILE_WORK_VERBS.has(verb) || (verb === 'policy' && third === 'get') || (verb === 'repositories' && third === 'list')) {
          result.deny = bashFinding('order-file', `zensu work ${verb}${scoped}`);
          return result;
        }
        if (!SESSION_WORK_VERBS.has(verb)) {
          result.deny = bashFinding('human-gate', `zensu work ${verb}${scoped}`);
          return result;
        }
      }
      if (noun === 'plan' && HUMAN_PLAN_VERBS.has(verb)) {
        const scoped = verb === 'followup' && third ? ` ${third}` : '';
        result.deny = bashFinding('human-gate', `zensu plan ${verb}${scoped}`);
        return result;
      }
    }
  }
  return result;
}

function gateReason(orderId, finding) {
  const lead = `This session runs Zensu work order ${orderId} without a person.`;
  switch (finding.code) {
    case 'ask':
      return `${lead} Nobody can answer a prompt or approve a plan here. Put the question to Zensu with the ask step of /zensu:work (zensu-work-order.sh --ask), which sends zensu work ask ${orderId} with a category, the question and, unless the question blocks, the option you continue with. Zensu binds the plan through zensu-work-order.sh --bind-spec, never plan mode.`;
    case 'chip':
      return `${lead} A task chip and a session started or proposed from here reach nobody. File the follow-up with Zensu through zensu-work-order.sh --followup, which sends zensu work followup ${orderId} with a title, a rationale and a severity.`;
    case 'push':
      return `${lead} A raw git push is not allowed. Run zensu-work-order.sh --push: it renews the lease, pushes with a lease against the head Zensu recorded for the order and reports the new head.`;
    case 'open-pr':
      return `${lead} Open the pull request with zensu-work-order.sh --open-pr --title <title> --body-file <path>, which renews the lease first.`;
    case 'merge':
      return `${lead} A work-order session never merges. It ends with ready_for_merge, and a person merges the pull request.`;
    case 'auth':
      return `${lead} zensu auth is not available here: the session token is the only credential, and the helpers read it themselves.`;
    case 'helper-verb':
      return `${lead} ${finding.detail} is sent by the work-order helper only. Use zensu-work-order.sh --drain for stages, --finish for the outcome and --renew for the lease.`;
    case 'human-gate':
      return `${lead} ${finding.detail} is a decision a person or the worker makes; a work-order session may not run it.`;
    case 'order-file':
      return `${lead} Zensu refuses ${finding.detail} for a session token. Read the order file that orderFile in the --start summary names instead: .order.questions holds the earlier questions with their answers and .order.policy the policy. Answers to non-blocking questions reach you through the work-order hooks.`;
    case 'token':
      return `${lead} The command is refused because ${finding.detail}. Never print, read, unset or override ${TOKEN_VARIABLE}; the helpers read it from the environment themselves.`;
    case 'token-host':
      return `${lead} The command is refused because ${finding.detail}. The session token may reach only the Zensu host the worker configured: never set, change or remove ${HOST_VARIABLE} and never pass --api-url.`;
    case 'shell-option':
      return `${lead} ${finding.detail} puts an option between -c and the command string, which the gate cannot judge. Put the command string right after -c.`;
    case 'lease':
      return `${lead} ${finding.detail}. No push, pull request or other forge command may run any more. Run zensu-work-order.sh --finish once and end the session.`;
    case 'powershell':
      return `${lead} The PowerShell tool is not available here, because this gate judges Bash commands only. Run the command through the Bash tool.`;
    case 'lease-refused':
      return `${lead} ${finding.detail}. No push, pull request or other forge command may run until a lease renewal succeeds. Run zensu-work-order.sh --renew --force and follow its exit code: after exit 0 run the command again, after exit 4 or 6 run zensu-work-order.sh --finish once and end the session, and after exit 7 follow the exit table of /zensu:work.`;
    default:
      return `${lead} The command is not allowed in a work-order session.`;
  }
}

function hookEnv(env) {
  return { ...env, ZENSU_WORK_ORDER_RETRY_BUDGET_MS: String(Math.min(retrySettings(env).budgetMs, HOOK_RETRY_BUDGET_MS)) };
}

function gateDecision(context, payload, { env = process.env, now = Date.now } = {}) {
  if (!context || context.fault || !isObject(payload)) return null;
  const orderId = context.marker.orderId;
  const tool = typeof payload.tool_name === 'string' ? payload.tool_name : '';
  if (ASK_TOOLS.has(tool)) return { code: 'ask', reason: gateReason(orderId, bashFinding('ask', null)) };
  if (CHIP_TOOLS.has(tool)) return { code: 'chip', reason: gateReason(orderId, bashFinding('chip', null)) };
  if (tool === 'PowerShell') return { code: 'powershell', reason: gateReason(orderId, bashFinding('powershell', null)) };
  let analysis = { deny: null, forge: false };
  if (tool === 'Bash') {
    analysis = analyzeBash(isObject(payload.tool_input) ? payload.tool_input.command : '');
    if (analysis.deny) return { code: analysis.deny.code, reason: gateReason(orderId, analysis.deny) };
  }
  if (!safeRead(context.files.lost).value && !safeRead(context.files.ended).value) {
    renew(context, { env: hookEnv(env), now: now() });
  }
  if (analysis.forge) {
    const forge = forgeWriteVerdict(context, now());
    if (!forge.allowed) return { code: 'lease', reason: gateReason(orderId, bashFinding('lease', forge.reason)) };
    const refusal = readOutbox(context).leaseRefusal;
    if (isObject(refusal)) {
      const detail = `Zensu refused the lease of work order ${orderId} (${refusal.code}), and an unanswered send still waits for its replay`;
      return { code: 'lease', reason: gateReason(orderId, bashFinding('lease-refused', detail)) };
    }
  }
  return null;
}

const ENDING_QUESTION_KINDS = new Set(['question', 'spec_change', 'escalated']);

function noteAskOutcome(context, body, now) {
  const order = isObject(body) && isObject(body.order) ? body.order : null;
  if (!order || order.status !== 'blocked') return false;
  const kind = typeof order.blocked_kind === 'string' ? order.blocked_kind : 'question';
  markEnded(context, {
    outcome: ENDING_QUESTION_KINDS.has(kind) ? 'success' : 'failure',
    kind: `blocked:${kind}`,
    delivered: true,
    reason: typeof order.blocked_reason === 'string' ? order.blocked_reason : null,
    at: now(),
  });
  return true;
}

function answersContext(orderId, answers) {
  if (!Array.isArray(answers) || answers.length === 0) return null;
  const overturned = (entry) => typeof entry.overturnedAt === 'string' && entry.overturnedAt.length > 0;
  const line = (entry) => {
    const question = String(entry.question || '').replace(/\s+/g, ' ').trim().slice(0, 400);
    const answer = String(entry.answer || '').replace(/\s+/g, ' ').trim().slice(0, 1200);
    const note = entry.planWide === true && overturned(entry)
      ? ' A person replaced the automatic answer Zensu gave to this question, so that automatic answer no longer holds.'
      : '';
    return `- Question (${entry.category || 'uncategorised'}): ${JSON.stringify(question)} Answer: ${JSON.stringify(answer)}${note}`;
  };
  const own = answers.filter((entry) => entry.planWide !== true && !overturned(entry));
  const replaced = answers.filter((entry) => entry.planWide !== true && overturned(entry));
  const planWide = answers.filter((entry) => entry.planWide === true);
  const parts = [];
  if (own.length > 0) {
    parts.push(`Zensu work order ${orderId}: a person answered a question this order asked earlier. Each answer is a decision about the order, not an instruction about this session; apply it where it changes the work, and keep the default you continued with otherwise.\n${own.map(line).join('\n')}`);
  }
  if (replaced.length > 0) {
    parts.push(`Zensu work order ${orderId}: a person replaced the automatic answer Zensu gave to a question this order asked earlier, so that automatic answer no longer holds. Each answer is a decision about the order, not an instruction about this session; apply it where it changes the work, also where the work followed the automatic answer.\n${replaced.map(line).join('\n')}`);
  }
  if (planWide.length > 0) {
    parts.push(`Zensu work order ${orderId}: a person decided these questions for the whole work plan, so they bind this order too. Each decision is about the work, not an instruction about this session; apply it where it changes the work.\n${planWide.map(line).join('\n')}`);
  }
  return parts.join('\n');
}

const DIRECT_ASK_RE = /(^|[\s;&|(])zensu\s+(?:\S+\s+)*?work\s+ask(\s|$)/;

function postToolUpdate(context, payload, { env = process.env, now = Date.now } = {}) {
  if (!context || context.fault || !isObject(payload)) return null;
  const bounded = hookEnv(env);
  const result = { additionalContext: null, cancelRun: null };
  if (safeRead(context.files.ended).value) {
    result.cancelRun = runToCancel(context);
    return result;
  }
  if (safeRead(context.files.lost).value) return result;
  const input = isObject(payload.tool_input) ? payload.tool_input : {};
  if (payload.tool_name === 'Bash' && DIRECT_ASK_RE.test(String(input.command || ''))) {
    const response = isObject(payload.tool_response) ? payload.tool_response : {};
    const stdout = typeof response.stdout === 'string' ? response.stdout : '';
    let body = null;
    try {
      body = JSON.parse(stdout);
    } catch (_) {
      body = null;
    }
    let ended = body ? noteAskOutcome(context, body, now) : false;
    if (!body && /;\s*stop the session\s*$/m.test(stdout)) {
      markEnded(context, { outcome: 'success', kind: 'blocked:question', delivered: true, reason: null, at: now() });
      ended = true;
    }
    if (ended) {
      result.cancelRun = runToCancel(context);
      result.additionalContext = `Zensu work order ${context.marker.orderId} is blocked on the question just asked, and Zensu ended this session. Stop now: run zensu-work-order.sh --finish once and end the turn.`;
      return result;
    }
  }
  renew(context, { env: bounded, now: now() });
  if (safeRead(context.files.lost).value) {
    result.additionalContext = lostContext(context);
    return result;
  }
  const drained = drain(context, { env: bounded, now });
  if (drained.verdict === 'ended') {
    result.cancelRun = runToCancel(context);
    const ended = safeRead(context.files.ended).value;
    const what = ended && ended.kind === 'ready_for_merge' && ended.outcome === 'success'
      ? `Zensu recorded ready_for_merge for work order ${context.marker.orderId}`
      : `Zensu blocked work order ${context.marker.orderId}`;
    result.additionalContext = `${what} and ended this session. Stop now: run zensu-work-order.sh --finish once and end the turn.`;
    return result;
  }
  if (drained.verdict === VERDICTS.LOST || safeRead(context.files.lost).value) {
    result.additionalContext = lostContext(context);
    return result;
  }
  if (drained.verdict === VERDICTS.FINAL) {
    result.additionalContext = `${refusedText(`the ${drained.refused || 'latest'} stage of work order ${context.marker.orderId}`, drained.failure, true)}, so the order cannot move past it in this session. Stop the work: run zensu-work-order.sh --finish --reason with one plain sentence that names the cause, then end the turn.`;
    return result;
  }
  result.additionalContext = answersContext(context.marker.orderId, takePendingAnswers(context));
  return result;
}

function lostContext(context) {
  const lost = safeRead(context.files.lost).value;
  const code = lost && typeof lost.code === 'string' && CLI_CODE_RE.test(lost.code) ? ` (${lost.code})` : '';
  return `The lease of Zensu work order ${context.marker.orderId} is lost${code}. Stop now without any push, pull request or event: run zensu-work-order.sh --finish once and end the turn.`;
}

function ask(context, { env = process.env, now = Date.now, category, question, options = [], defaultOption = null, blocking = false, requirements = [] } = {}) {
  if (!context || context.fault) return { exit: EXIT.NOT_BOUND, message: context ? context.fault : 'this session runs no work order' };
  if (typeof category !== 'string' || !category || typeof question !== 'string' || !question.trim()) {
    return { exit: EXIT.USAGE, message: '--ask needs --category and --question' };
  }
  if (!blocking && (typeof defaultOption !== 'string' || !defaultOption)) {
    return { exit: EXIT.USAGE, message: '--ask needs --default-option unless --blocking is set' };
  }
  const fault = askInputFault({ category, question, options, defaultOption, requirements });
  if (fault) return { exit: EXIT.USAGE, message: fault };
  const forge = forgeWriteVerdict(context, now());
  if (!forge.allowed) return { exit: EXIT.LOST, message: forge.reason };
  const args = ['work', 'ask', context.marker.orderId, '--category', category, '--question', question,
    '--client-event-id', clientEventId(context.marker.orderId, context.marker.attempt, 'ask', category, question,
      blocking ? 'blocking' : 'continue', defaultOption || '')];
  for (const option of options) args.push('--option', option);
  if (defaultOption) args.push('--default-option', defaultOption);
  if (blocking) args.push('--blocking');
  for (const requirement of requirements) args.push('--requirement', requirement);
  args.push('--json');
  rememberTerminal(context, PENDING, { verb: 'ask', args });
  const outcome = runZensu(args, { env });
  if (outcome.exitCode !== 0 || !isObject(outcome.json)) {
    const failure = classifyFailure(outcome);
    if (failure.verdict === VERDICTS.LOST) {
      forgetTerminal(context, args);
      const lost = loseLease(context, failure, 'ask', { env, at: now() });
      if (lost.verdict === 'ended') return endedResult(context, '; the question was not asked');
      if (lost.verdict === VERDICTS.LOST) return { exit: EXIT.LOST, message: 'the lease is lost; the question was not asked' };
      return { exit: EXIT.TRANSIENT, message: `Zensu did not take the question yet (${describeFailure(lost.failure)}); run --ask again` };
    }
    if (failure.verdict === VERDICTS.TRANSIENT || failure.verdict === VERDICTS.RETRY) {
      rememberTerminal(context, failure, { verb: 'ask', args });
      return { exit: EXIT.TRANSIENT, message: `Zensu did not take the question yet (${describeFailure(failure)}); run --ask again` };
    }
    forgetTerminal(context, args);
    const refused = refusedProse(outcome, failure, 'ask again');
    const next = refused.next || 'continue with your default option, or finish with --reason when the work cannot go on';
    return { exit: EXIT.REFUSED, message: `${refusedText('the question', failure)}${cliRefusal(failure) ? '' : refused.said}; ${next}` };
  }
  const body = outcome.json;
  forgetTerminal(context, args);
  const asked = isObject(body.question) ? body.question : {};
  const value = { questionId: asked.id || null, status: asked.status || null, escalated: body.escalated === true, replay: body.replay === true };
  if (noteAskOutcome(context, body, now)) {
    return {
      exit: EXIT.ENDED,
      value: { ...value, ended: true },
      message: `work order ${context.marker.orderId} waits for a person to answer; the session has ended`,
      cancelRun: runToCancel(context),
    };
  }
  return { exit: EXIT.OK, value: { ...value, ended: false, continueWith: defaultOption || null } };
}

function followup(context, { env = process.env, now = Date.now, title, rationale, severity = 'medium', paths = [] } = {}) {
  if (!context || context.fault) return { exit: EXIT.NOT_BOUND, message: context ? context.fault : 'this session runs no work order' };
  if (typeof title !== 'string' || !title.trim() || typeof rationale !== 'string' || !rationale.trim()) {
    return { exit: EXIT.USAGE, message: '--followup needs --title and --rationale' };
  }
  const fault = followupInputFault({ title, rationale, severity, paths });
  if (fault) return { exit: EXIT.USAGE, message: fault };
  const forge = forgeWriteVerdict(context, now());
  if (!forge.allowed) return { exit: EXIT.LOST, message: forge.reason };
  const args = ['work', 'followup', context.marker.orderId, '--title', title, '--rationale', rationale, '--severity', severity,
    '--client-event-id', clientEventId(context.marker.orderId, context.marker.attempt, 'followup', title)];
  for (const entry of paths) args.push('--path', entry);
  args.push('--json');
  const outcome = runZensu(args, { env });
  if (outcome.exitCode === 0) return { exit: EXIT.OK, value: { filed: true, replay: isObject(outcome.json) && outcome.json.replay === true } };
  const failure = classifyFailure(outcome);
  if (failure.verdict === VERDICTS.LOST) {
    const lost = loseLease(context, failure, 'followup', { env, at: now() });
    if (lost.verdict === 'ended') return endedResult(context, '; the follow-up was not filed');
    if (lost.verdict === VERDICTS.LOST) return { exit: EXIT.LOST, message: 'the lease is lost; the follow-up was not filed' };
    return { exit: EXIT.TRANSIENT, message: `Zensu did not take the follow-up yet (${describeFailure(lost.failure)})` };
  }
  if (failure.verdict === VERDICTS.TRANSIENT || failure.verdict === VERDICTS.RETRY) {
    return { exit: EXIT.TRANSIENT, message: `Zensu did not take the follow-up yet (${describeFailure(failure)})` };
  }
  const refused = refusedProse(outcome, failure, 'file it again');
  let next = 'continue without it';
  if (failure.code === 'followup_limit_reached') next = 'file no more follow-ups in this attempt';
  else if (refused.next) next = refused.next;
  return { exit: EXIT.REFUSED, message: `${refusedText('the follow-up', failure)}${cliRefusal(failure) ? '' : refused.said}; ${next}` };
}

const QUESTION_CATEGORIES = ['clarification', 'technical_choice', 'product_decision', 'scope', 'risk', 'external'];
const QUESTION_OPTIONS = 10;
const OPTION_BYTES = 300;
const QUESTION_REQUIREMENTS = 20;
const REQUIREMENT_ID_RE = /^(AC|FR|IF)-[0-9]{3,6}$/;

function askInputFault({ category, question, options, defaultOption, requirements }) {
  if (!QUESTION_CATEGORIES.includes(category)) return `--category must be one of ${QUESTION_CATEGORIES.join(', ')}`;
  if (Buffer.byteLength(question.trim()) > PROSE_BYTES) return `--question holds at most ${PROSE_BYTES} bytes; shorten it`;
  const list = Array.isArray(options) ? options : [];
  if (list.length > QUESTION_OPTIONS) return `--option may repeat at most ${QUESTION_OPTIONS} times`;
  const seen = new Set();
  for (const option of list) {
    const trimmed = String(option).trim();
    if (!trimmed) return 'every --option needs text';
    if (Buffer.byteLength(trimmed) > OPTION_BYTES) return `every --option holds at most ${OPTION_BYTES} bytes; shorten it`;
    if (seen.has(trimmed)) return `--option ${JSON.stringify(trimmed)} is given twice; the options must be distinct`;
    seen.add(trimmed);
  }
  const fallback = typeof defaultOption === 'string' ? defaultOption.trim() : '';
  if (Buffer.byteLength(fallback) > OPTION_BYTES) return `--default-option holds at most ${OPTION_BYTES} bytes; shorten it`;
  if (fallback && seen.size > 0 && !seen.has(fallback)) return '--default-option must repeat one --option verbatim';
  const ids = Array.isArray(requirements) ? requirements : [];
  if (ids.length > QUESTION_REQUIREMENTS) return `--requirement may repeat at most ${QUESTION_REQUIREMENTS} times`;
  const bad = ids.find((id) => !REQUIREMENT_ID_RE.test(String(id)));
  if (bad !== undefined) return `--requirement ${JSON.stringify(String(bad))} must look like AC-001, FR-001 or IF-001, one id per flag`;
  return null;
}

const FOLLOWUP_SEVERITIES = new Set(['low', 'medium', 'high', 'critical']);
const FOLLOWUP_TITLE_BYTES = 200;
const FOLLOWUP_PATHS = 20;
const PROSE_BYTES = 2048;
const REPOSITORY_PATH_BYTES = 512;
const REPOSITORY_PATH_RE = /^[\p{L}\p{Nd}._\-\/+@~()[\]{}=, ]+$/u;

function cleanRepositoryPath(entry) {
  if (typeof entry !== 'string' || entry === '' || entry === '.' || Buffer.byteLength(entry) > REPOSITORY_PATH_BYTES) return false;
  if (entry.trim() !== entry || entry.startsWith('/') || entry.endsWith('/') || path.posix.normalize(entry) !== entry) return false;
  if (entry.split('/').includes('..')) return false;
  return REPOSITORY_PATH_RE.test(entry);
}

function followupInputFault({ title, rationale, severity, paths }) {
  if (!FOLLOWUP_SEVERITIES.has(severity)) return '--severity must be one of low, medium, high, critical';
  if (Buffer.byteLength(title.trim()) > FOLLOWUP_TITLE_BYTES) return `--title holds at most ${FOLLOWUP_TITLE_BYTES} bytes; shorten it`;
  if (Buffer.byteLength(rationale.trim()) > PROSE_BYTES) return `--rationale holds at most ${PROSE_BYTES} bytes; shorten it`;
  const list = Array.isArray(paths) ? paths : [];
  if (list.length > FOLLOWUP_PATHS) return `--path may repeat at most ${FOLLOWUP_PATHS} times`;
  const bad = list.find((entry) => !cleanRepositoryPath(entry));
  if (bad !== undefined) return `--path ${JSON.stringify(String(bad))} must be a clean relative file path without wildcards, ./ or a trailing slash`;
  return null;
}

function refusedProse(outcome, failure, again) {
  const text = outcome && typeof outcome.message === 'string' ? outcome.message.replace(/\s+/g, ' ').trim() : '';
  const tooLong = /^content_not_allowed: ([A-Za-z0-9_.]+): too_long\b/.exec(text);
  let next = null;
  if (tooLong) next = `shorten ${tooLong[1]} and ${again}`;
  else if (failure.code === 'content_not_allowed') next = `rewrite it as plain prose and ${again}`;
  return { said: text ? `: ${text}` : '', next };
}

const PLAN_SUMMARY_FALLBACK = 'Implementation plan for this work order.';

function planSummary(text) {
  const lines = String(text || '').split(/\r\n|\r|\n|\u0085|\u2028|\u2029/)
    .filter((line) => !/^\s*<!--/.test(line))
    .map((line) => line.replace(/[`*_#>|<()[\]"]/g, ' ').replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').replace(/\s+/g, ' ').trim())
    .filter((line) => line && !/^[-=]{3,}$/.test(line));
  const summary = lines.slice(0, 6).join(' ').slice(0, 360).trim();
  return summary ? `Implementation plan. ${summary}` : PLAN_SUMMARY_FALLBACK;
}

function blobLink(repository, sha, file) {
  const named = String(repository || '').trim().replace(/\.git$/, '').replace(/\/+$/, '');
  const base = /^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(named) ? named : `https://${named}`;
  if (!/^https:\/\/[^/\s]+\/\S+$/.test(base)) return null;
  const host = base.slice('https://'.length).split('/')[0].toLowerCase();
  if (host === 'github.com') return `${base}/blob/${sha}/${file}`;
  if (host === 'gitlab.com' || host.startsWith('gitlab.')) return `${base}/-/blob/${sha}/${file}`;
  return null;
}

function planApproval(context, { env = process.env, now = Date.now } = {}) {
  if (!context || context.fault) return { exit: EXIT.NOT_BOUND, message: context ? context.fault : 'this session runs no work order' };
  const ended = safeRead(context.files.ended).value;
  if (ended) {
    return {
      exit: ended.outcome === 'success' ? EXIT.OK : EXIT.ENDED,
      message: `the session of work order ${context.marker.orderId} has already ended (${ended.kind})`,
      cancelRun: runToCancel(context),
    };
  }
  const file = planFileFor(context.marker.orderId);
  let planText = null;
  try {
    planText = fs.readFileSync(path.join(context.projectRoot, file), 'utf8');
  } catch (_) {
    planText = null;
  }
  if (planText === null || !planText.trim()) return { exit: EXIT.REFUSED, message: `write the implementation plan to ${file} first` };
  const reported = drain(context, { env, now });
  if (reported.verdict === 'ended') return endedResult(context, '', EXIT.OK);
  if (reported.verdict === VERDICTS.LOST) return { exit: EXIT.LOST, message: 'the lease is lost; stop without any forge write' };
  if (reported.verdict === VERDICTS.FINAL) {
    return { exit: EXIT.REFUSED, message: `${refusedText(`the ${reported.refused || 'planning'} stage`, reported.failure)}; finish with --reason` };
  }
  if (reported.verdict !== VERDICTS.OK && reported.verdict !== 'plan-approval-required') {
    return { exit: EXIT.TRANSIENT, message: `the planning stage is not reported yet (${describeFailure(reported.failure)}); run --plan-approval again` };
  }
  const tracked = git(context.projectRoot, ['ls-files', '--error-unmatch', '--', file]);
  const dirty = git(context.projectRoot, ['status', '--porcelain', '--', file]);
  if (!tracked.ok || dirty.stdout.trim()) {
    const added = git(context.projectRoot, ['add', '-f', '--', file], env);
    const committed = added.ok
      ? git(context.projectRoot, ['commit', '-m', `docs(plan): add the implementation plan of work order ${context.marker.orderId.slice(0, 8)}`, '--', file], env)
      : added;
    if (!committed.ok) {
      return { exit: EXIT.REFUSED, message: `the plan file could not be committed: ${committed.stderr.trim().split('\n').slice(-1)[0] || 'no detail'}` };
    }
  }
  const pushed = push(context, { env, now });
  if (pushed.exit !== EXIT.OK) return safeRead(context.files.ended).value ? endedResult(context, '', EXIT.OK) : pushed;
  const sha = pushed.value.head;
  const snapshot = safeRead(context.files.order).value;
  const order = snapshot && isObject(snapshot.order) ? snapshot.order : {};
  const link = blobLink(order.repository || context.marker.repository, sha, file);
  const sendArtifact = (summary, url) => sendEvent(context, ['--artifact', 'plan', '--path', file, '--sha', sha, '--summary', summary,
    '--client-event-id', clientEventId(context.marker.orderId, context.marker.attempt, 'plan-artifact', sha), ...(url ? ['--url', url] : [])], { env, now });
  let summary = planSummary(planText);
  let url = link;
  let artifact = sendArtifact(summary, url);
  for (let retry = 0; retry < 2 && artifact.verdict === VERDICTS.FINAL && artifact.failure; retry += 1) {
    if (artifact.failure.code === 'content_not_allowed' && summary !== PLAN_SUMMARY_FALLBACK) summary = PLAN_SUMMARY_FALLBACK;
    else if (artifact.failure.code === 'invalid_url' && url) url = null;
    else break;
    artifact = sendArtifact(summary, url);
  }
  if (artifact.verdict !== VERDICTS.OK) {
    if (artifact.verdict === 'ended') return endedResult(context, '', EXIT.OK);
    if (artifact.verdict === VERDICTS.LOST) return { exit: EXIT.LOST, message: 'the lease is lost; the plan was not attached' };
    if (artifact.verdict === VERDICTS.FINAL) return { exit: EXIT.REFUSED, message: `${refusedText('the plan artifact', artifact.failure)}; finish with --reason` };
    return { exit: EXIT.TRANSIENT, message: `Zensu did not take the plan artifact yet (${describeFailure(artifact.failure)}); run --plan-approval again` };
  }
  const blocked = deliverBlocked(context, {
    env, now, kind: 'plan_approval', reason: 'The implementation plan is attached and waits for a human approval.', eventKey: `plan-approval:${sha}`,
  });
  if (blocked.verdict === 'ended') return endedResult(context, '', EXIT.OK);
  if (blocked.delivered) {
    return {
      exit: EXIT.OK,
      value: { plan: file, commit: sha, link: url },
      message: `the plan of work order ${context.marker.orderId} waits for approval; the session is complete`,
      cancelRun: runToCancel(context),
    };
  }
  if (blocked.verdict === VERDICTS.LOST) return { exit: EXIT.LOST, message: 'the lease is lost; the approval request was not sent', cancelRun: runToCancel(context) };
  if (blocked.verdict === VERDICTS.FINAL && blocked.failure && blocked.failure.code === 'plan_approval_not_required') {
    return { exit: EXIT.REFUSED, message: 'Zensu approves the plans of this order automatically; run --bind-spec and continue with implementing' };
  }
  if (blocked.verdict === VERDICTS.FINAL) return { exit: EXIT.REFUSED, message: `${refusedText('the approval request', blocked.failure)}; finish with --reason` };
  return { exit: EXIT.TRANSIENT, message: `the approval request is not delivered yet (${describeFailure(blocked.failure)}); run --plan-approval again` };
}

const STOP_BLOCK_BUDGET = 3;
const STOP_RETRY_BUDGET_MS = 20000;

function stopDecision(context, { env = process.env, now = Date.now } = {}) {
  if (!context) return { decision: 'inert' };
  if (context.fault) return { decision: 'allow', note: context.fault };
  if (safeRead(context.files.ended).value) return { decision: 'allow', cancelRun: runToCancel(context) };
  if (safeRead(context.files.lost).value) {
    const closed = finish(context, { env, now });
    return { decision: 'allow', cancelRun: closed.cancelRun || null };
  }
  const outbox = readOutbox(context);
  const run = outbox.runId ? readRunRecord(context.projectRoot, outbox.runId) : null;
  const seen = run ? `${run.runId}:${run.events.length}` : 'no-run';
  const previous = safeRead(context.files.stop).value || {};
  const count = previous.seen === seen && Number.isSafeInteger(previous.count) && previous.count >= 0 ? previous.count : 0;
  if (count < STOP_BLOCK_BUDGET) {
    writeState(context.projectRoot, context.files.stop, { count: count + 1, seen });
    const state = run ? `its Autopilot run ${run.runId} is at ${run.stage}` : 'it has no Autopilot run yet';
    return {
      decision: 'block',
      reason: `Work order ${context.marker.orderId} has no reported outcome and ${state}. A work order session ends only after it reported ready_for_merge or a block. Continue the work, or end it with the finish step of /zensu:work: zensu-work-order.sh --finish once the run is DONE, or the same command with --reason and one plain sentence to stop the order. Never ask a person in this session; a question goes through the ask step of /zensu:work. After ${STOP_BLOCK_BUDGET} stops in a row without progress the session reports the order as blocked on its own.`,
    };
  }
  const bounded = { ...env, ZENSU_WORK_ORDER_RETRY_BUDGET_MS: String(Math.min(retrySettings(env).budgetMs, STOP_RETRY_BUDGET_MS)) };
  const terminalRun = run && ['DONE', 'BLOCKED', 'CANCELLED'].includes(run.stage);
  const closed = finish(context, { env: bounded, now, reason: terminalRun ? null : 'The session stopped without reporting the outcome of its work order.' });
  return { decision: 'allow', cancelRun: closed.cancelRun || runToCancel(context), exit: closed.exit };
}

const REPEATABLE_OPTIONS = new Set(['option', 'requirement', 'path']);
const BOOLEAN_OPTIONS = new Set(['force', 'blocking']);

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith('--')) throw new Error(`unexpected argument ${token}`);
    const name = token.slice(2);
    const value = argv[index + 1];
    if (BOOLEAN_OPTIONS.has(name) || value === undefined || value.startsWith('--')) {
      options[name] = true;
      continue;
    }
    index += 1;
    if (REPEATABLE_OPTIONS.has(name)) {
      options[name] = [...(Array.isArray(options[name]) ? options[name] : []), value];
    } else {
      options[name] = value;
    }
  }
  return options;
}

function readStdinJson() {
  try {
    const parsed = JSON.parse(fs.readFileSync(0, 'utf8'));
    return isObject(parsed) ? parsed : null;
  } catch (_) {
    return null;
  }
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
    if (beat.verdict === 'ended') {
      const ended = endedResult(context, '');
      process.stderr.write(`zensu work-order: ${ended.message}\n`);
      return ended.exit;
    }
    if (beat.verdict === VERDICTS.OK || beat.verdict === 'fresh') return EXIT.OK;
    process.stderr.write(`zensu work-order: the lease renewal did not succeed (${describeFailure(beat.failure)})\n`);
    return EXIT.TRANSIENT;
  }
  const context = loadContext({ env, projectRoot, sessionKey });
  if (verb === 'bound') {
    if (!context || context.fault) return EXIT.NOT_BOUND;
    process.stdout.write('\nbound\n');
    return EXIT.OK;
  }
  const emit = (result) => {
    if (env.WO_EMIT === 'value') {
      if (result.value !== undefined && result.value !== null) process.stdout.write(`${JSON.stringify(result.value)}\n`);
      if (result.message) process.stderr.write(`zensu work-order: ${result.message}\n`);
      return result.exit;
    }
    const body = {};
    if (result.value !== undefined) body.value = result.value;
    if (result.cancelRun) body.cancelRun = result.cancelRun;
    if (result.delivered !== undefined) body.delivered = result.delivered;
    if (result.already) body.already = true;
    if (result.planApproval) body.planApproval = true;
    if (Object.keys(body).length > 0) process.stdout.write(`${JSON.stringify(body)}\n`);
    if (result.message) process.stderr.write(`zensu work-order: ${result.message}\n`);
    return result.exit;
  };
  if (verb === 'binding') {
    const bound = binding(context, typeof options.order === 'string' ? options.order : null);
    if (bound.exit === EXIT.OK && bound.value && typeof options.run === 'string') {
      const outbox = readOutbox(context);
      if (outbox.runId && outbox.runId !== options.run) {
        return emit({ exit: EXIT.NOT_BOUND, message: `this session already reports Autopilot run ${outbox.runId} for work order ${context.marker.orderId}` });
      }
    }
    if (bound.exit === EXIT.OK && bound.value) process.stdout.write(`${JSON.stringify(bound.value)}\n`);
    if (bound.message) process.stderr.write(`zensu work-order: ${bound.message}\n`);
    return bound.exit;
  }
  if (verb === 'bind-run') {
    if (!context || context.fault) return emit({ exit: EXIT.NOT_BOUND, message: context ? context.fault : 'this session runs no work order' });
    const bound = markerRun(context, typeof options.run === 'string' ? options.run : null);
    return emit(bound.error ? { exit: EXIT.NOT_BOUND, message: bound.error } : { exit: EXIT.OK, value: { runId: bound.runId } });
  }
  if (verb === 'bind-spec') return emit(bindSpec(context, { env, runId: typeof options.run === 'string' ? options.run : null }));
  if (verb === 'drain') {
    const drained = drain(context, { env });
    if (drained.verdict === VERDICTS.OK || drained.verdict === 'idle' || drained.verdict === 'no-run') {
      return emit({ exit: EXIT.OK, value: { sent: drained.sent || [] } });
    }
    if (drained.verdict === 'fault') return emit({ exit: EXIT.NOT_BOUND, message: context ? context.fault : 'this session runs no work order' });
    if (drained.verdict === 'ended') return emit(endedResult(context, ''));
    if (drained.verdict === VERDICTS.LOST) return emit({ exit: EXIT.LOST, message: 'the lease is lost; stop without any forge write' });
    if (drained.verdict === 'plan-approval-required') return emit({ exit: EXIT.REFUSED, message: 'plan-approval-required', planApproval: true });
    if (drained.verdict === VERDICTS.FINAL) return emit({ exit: EXIT.REFUSED, message: `${refusedText('a stage', drained.failure)}; finish with --reason` });
    return emit({ exit: EXIT.TRANSIENT, message: `a stage is not reported yet (${describeFailure(drained.failure)})` });
  }
  if (verb === 'finish') return emit(finish(context, { env, reason: typeof options.reason === 'string' ? options.reason : null }));
  if (verb === 'push') return emit(push(context, { env }));
  if (verb === 'open-pr') {
    return emit(openPr(context, {
      env,
      title: typeof options.title === 'string' ? options.title : null,
      bodyFile: typeof options['body-file'] === 'string' ? options['body-file'] : null,
      provider: typeof options.provider === 'string' ? options.provider : null,
    }));
  }
  if (verb === 'review-import') return emit(reviewImport(context, { env, runId: typeof options.run === 'string' ? options.run : null }));
  if (verb === 'release-plan') {
    if (!context || context.fault) return emit({ exit: EXIT.NOT_BOUND, message: context ? context.fault : 'this session runs no work order' });
    const runs = releasePlan(context.projectRoot, context.marker.orderId, context.marker.attempt);
    if (runs.length > 0) process.stdout.write(`${runs.join('\n')}\n`);
    return EXIT.OK;
  }
  const list = (value) => (Array.isArray(value) ? value : (typeof value === 'string' ? [value] : []));
  const text = (value) => (typeof value === 'string' ? value : null);
  if (verb === 'gate') {
    const decided = gateDecision(context, readStdinJson(), { env });
    if (env.WO_EMIT === 'hook') {
      process.stdout.write('\n');
      if (decided) {
        process.stdout.write(`${JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: decided.reason } })}\n`);
      }
    } else if (decided) {
      process.stdout.write(`${JSON.stringify(decided)}\n`);
    }
    return EXIT.OK;
  }
  if (verb === 'post') {
    const updated = postToolUpdate(context, readStdinJson(), { env });
    if (env.WO_EMIT === 'hook') {
      process.stdout.write(`${updated && updated.cancelRun ? updated.cancelRun : ''}\n`);
      if (updated && updated.additionalContext) {
        process.stdout.write(`${JSON.stringify({ hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: updated.additionalContext } })}\n`);
      }
      return EXIT.OK;
    }
    if (updated) process.stdout.write(`${JSON.stringify(updated)}\n`);
    return EXIT.OK;
  }
  if (verb === 'ask') {
    return emit(ask(context, {
      env,
      category: text(options.category),
      question: text(options.question),
      options: list(options.option),
      defaultOption: text(options['default-option']),
      blocking: options.blocking === true,
      requirements: list(options.requirement),
    }));
  }
  if (verb === 'followup') {
    return emit(followup(context, {
      env,
      title: text(options.title),
      rationale: text(options.rationale),
      severity: text(options.severity) || 'medium',
      paths: list(options.path),
    }));
  }
  if (verb === 'plan-approval') return emit(planApproval(context, { env }));
  if (verb === 'stop') {
    const decided = stopDecision(context, { env });
    if (env.WO_EMIT === 'hook') {
      process.stdout.write(`${decided.cancelRun || ''}\n`);
      if (decided.decision === 'block') process.stdout.write(`${JSON.stringify({ decision: 'block', reason: decided.reason })}\n`);
      return EXIT.OK;
    }
    process.stdout.write(`${JSON.stringify(decided)}\n`);
    return EXIT.OK;
  }
  process.stderr.write('zensu work-order: unknown verb\n');
  return EXIT.USAGE;
}

module.exports = {
  CLIENT_NAME,
  EXIT,
  HUMAN_PLAN_VERBS,
  LOST_CODES,
  RETRY_CODES,
  SCHEMA_VERSION,
  SESSION_WORK_VERBS,
  STAGE_RANK,
  STATE_SEGMENTS,
  SUPPORTED_KINDS,
  VERDICTS,
  analyzeBash,
  approvedPlanCommit,
  ask,
  bindSpec,
  binding,
  blobLink,
  branchPrefixOf,
  drain,
  existingPullRequest,
  finish,
  followup,
  gateDecision,
  markerRun,
  openPr,
  parseArgs,
  planApproval,
  planDecisions,
  planSummary,
  postToolUpdate,
  push,
  readRunRecord,
  releasePlan,
  reviewImport,
  shellCommands,
  stopDecision,
  workOrderReviewKey,
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
