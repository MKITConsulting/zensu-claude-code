'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const STATE_FILE = process.env.FAKE_ZENSU_STATE;
const CALLS_FILE = process.env.FAKE_ZENSU_CALLS;
const STAGE_RANK = { claimed: 0, planning: 1, implementing: 2, pr_open: 3, reviewing: 4, validating: 5, ready_for_merge: 6 };
const BRANCH_PREFIX = 'wo-';
const GIT_REF_RE = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$/;
const COMMAND_WORDS = new Set(['git', 'npm', 'npx', 'yarn', 'go', 'make', 'docker', 'kubectl', 'curl', 'bash', 'sh',
  'node', 'python', 'rm', 'cd', 'ls', 'cat', 'echo', 'export', 'zensu', 'gh', 'glab', 'claude', 'sudo']);

const argv = process.argv.slice(2);

function load() {
  return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
}

function save(state) {
  const temp = `${STATE_FILE}.tmp-${process.pid}`;
  fs.writeFileSync(temp, `${JSON.stringify(state, null, 2)}\n`);
  fs.renameSync(temp, STATE_FILE);
}

function logCall() {
  if (!CALLS_FILE) return;
  fs.appendFileSync(CALLS_FILE, `${JSON.stringify({ argv, token: Boolean(process.env.ZENSU_SESSION_TOKEN) })}\n`);
}

function usage(message) {
  process.stderr.write(`error: ${message}\n`);
  process.exit(1);
}

let state;

function errorFormat() {
  if (!state) return 'json';
  if (state.printCodes === false) return 'bare';
  return ['json', 'line', 'bare'].includes(state.errorFormat) ? state.errorFormat : 'json';
}

function apiFail(status, code, message) {
  const format = errorFormat();
  const suffix = format === 'bare' ? `(status ${status})` : `(status ${status}, code ${code})`;
  const context = state && state.errorContext ? `; ${state.errorContext}` : '';
  process.stderr.write(`error: ${message} ${suffix}${context}\n`);
  if (state && state.errorContinuation) process.stderr.write(`${state.errorContinuation}\n`);
  if (format === 'json' && argv.includes('--json')) {
    process.stderr.write(`${JSON.stringify({ error: { status, code, message: `${message}${context}` } })}\n`);
  }
  process.exit(1);
}

function printJson(value) {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
  process.exit(0);
}

function now() {
  return Number.isFinite(state.now) ? state.now : Date.now();
}

function iso(ms) {
  return new Date(ms).toISOString();
}

function parseFlags(args) {
  const flags = { _: [] };
  const multi = new Set(['option', 'requirement', 'path']);
  const booleans = new Set(['json', 'blocking', 'help', 'minimal-json']);
  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (!token.startsWith('--')) {
      flags._.push(token);
      continue;
    }
    let name = token.slice(2);
    let value;
    const eq = name.indexOf('=');
    if (eq >= 0) {
      value = name.slice(eq + 1);
      name = name.slice(0, eq);
    } else if (booleans.has(name)) {
      value = true;
    } else {
      value = args[index + 1];
      if (value === undefined) usage(`flag needs an argument: --${name}`);
      index += 1;
    }
    if (multi.has(name)) {
      flags[name] = [...(flags[name] || []), value];
    } else {
      flags[name] = value;
    }
  }
  return flags;
}

function injected(command) {
  const queue = Array.isArray(state.failNext) ? state.failNext : [];
  const index = queue.findIndex((entry) => entry.command === command);
  if (index < 0) return;
  const entry = queue[index];
  entry.times = (entry.times || 1) - 1;
  if (entry.times <= 0) queue.splice(index, 1);
  save(state);
  apiFail(entry.status, entry.code, entry.message || `injected failure for ${command}`);
}

function requireSessionToken(verb) {
  const token = process.env.ZENSU_SESSION_TOKEN || '';
  if (!token) usage(`zensu ${verb} runs inside a work order session; set ZENSU_SESSION_TOKEN to the session token of its claim`);
  if (state.mode === 'revoked' || token !== state.token) apiFail(401, 'invalid_session_token', 'session token expired or revoked');
}

function requireOrder(id) {
  if (!state.order || String(id || '').toLowerCase() !== state.order.id.toLowerCase()) {
    apiFail(403, 'session_order_mismatch', 'the session token belongs to another work order');
  }
}

function requireLive() {
  if (state.mode === 'ended') apiFail(401, 'invalid_session_token', 'session token expired or revoked');
  if (state.staleAttempt || !(state.order.lease_expires_at > now())) {
    apiFail(409, 'stale_attempt', 'the order is held by another attempt or its lease expired; stop without further forge writes');
  }
}

function endSession(status, blockedKind, reason) {
  state.order.status = status;
  state.order.blocked_kind = blockedKind || null;
  state.order.blocked_reason = blockedKind ? reason : null;
  state.mode = 'ended';
}

function runtimeCap() {
  if (!state.runtimeCap) return;
  endSession('blocked', 'runtime_cap', 'max_order_runtime_minutes reached');
  save(state);
  apiFail(409, 'runtime_cap', 'the session reached max_order_runtime_minutes; the order is blocked(runtime_cap) and the session must stop');
}

function renewLease() {
  const seconds = state.order.claim_confirmed_at ? state.policy.lease_minutes * 60 : (state.confirmWindowSeconds || 120);
  state.order.lease_expires_at = now() + seconds * 1000;
  state.order.heartbeat_at = iso(now());
  return seconds;
}

function publicOrder() {
  const order = { ...state.order };
  order.lease_expires_at = Number.isFinite(order.lease_expires_at) ? iso(order.lease_expires_at) : null;
  return order;
}

function answered() {
  return (state.questions || []).filter((question) => question.status === 'answered' || question.status === 'auto_answered');
}

function guardProse(field, text, required) {
  if (typeof text !== 'string' || text.trim() === '') {
    if (required) apiFail(422, 'invalid_detail', `${field} is required`);
    return;
  }
  if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(text)) apiFail(422, 'content_not_allowed', `content_not_allowed: ${field}: control_characters`);
  if (Buffer.byteLength(text) > 2048) apiFail(422, 'content_not_allowed', `content_not_allowed: ${field}: too_long`);
  if (/```/.test(text) || /`[^`]*`/.test(text) && /`(git|zensu|npm|gh|bash) /.test(text)) {
    apiFail(422, 'content_not_allowed', `content_not_allowed: ${field}: code_block`);
  }
  for (const line of text.split(/\r?\n/)) {
    const words = line.trim().split(/\s+/);
    if (words.length >= 2 && COMMAND_WORDS.has(words[0]) && /^[-a-z]/.test(words[1]) && !['the', 'a', 'an', 'and', 'to'].includes(words[1])) {
      apiFail(422, 'content_not_allowed', `content_not_allowed: ${field}: command_line`);
    }
  }
}

function recordEvent(fields) {
  const event = {
    id: crypto.randomUUID(),
    work_order_id: state.order.id,
    attempt: state.order.attempt,
    actor_kind: 'session',
    client_session_id: state.order.client_session_id,
    occurred_at: iso(now()),
    ...fields,
  };
  state.events.push(event);
  return event;
}

function replayLookup(clientEventId, type, toStatus) {
  const prior = state.events.find((event) => event.client_event_id === clientEventId);
  if (!prior) return null;
  const matches = prior.event_type === type && prior.attempt === state.order.attempt
    && (toStatus === null || prior.to_status === toStatus);
  if (!matches) apiFail(409, 'client_event_id_reused', 'clientEventId was already used for another event');
  return prior;
}

function validClientEvent(flags) {
  const id = flags['client-event-id'];
  if (typeof id !== 'string' || !/^[A-Za-z0-9._:-]{8,64}$/.test(id)) {
    apiFail(422, 'invalid_client_event_id', 'clientEventId must be 8 to 64 characters of letters, digits, dot, underscore, colon or dash');
  }
  if (!flags['client-name'] || !flags['client-version']) apiFail(422, 'invalid_client', 'clientName and clientVersion are required');
}

function orderBranchPrefix() {
  return state.spec && typeof state.spec.branch_prefix === 'string' ? state.spec.branch_prefix : BRANCH_PREFIX;
}

function validateBranch(branch) {
  const prefix = orderBranchPrefix();
  if (!branch.startsWith(prefix)) apiFail(422, 'invalid_branch', `order branches must start with ${prefix}`);
  const malformed = !GIT_REF_RE.test(branch) || branch.includes('..') || branch.includes('//') || branch.endsWith('/') || branch.endsWith('.')
    || branch.split('/').some((component) => component.startsWith('.') || component.endsWith('.lock'));
  if (malformed) apiFail(422, 'invalid_branch', 'branch is not a valid branch name');
}

function workGet(flags) {
  requireSessionToken('work get');
  if (state.mode === 'ended') apiFail(401, 'invalid_session_token', 'session token expired or revoked');
  requireOrder(flags._[0]);
  injected('get');
  const approved = (state.approvals || []).some((approval) => approval.spec_hash === state.order.spec_hash);
  printJson({
    ...publicOrder(),
    spec: { branch_prefix: BRANCH_PREFIX, ...(state.spec || { title: 'Fake order spec', requirements: [] }) },
    plan: state.plan,
    policy: state.policy,
    questions: state.questions || [],
    decision_log: [],
    implementation_plan_approved: approved,
    lane: null,
  });
}

function workHeartbeat(flags) {
  requireSessionToken('work heartbeat');
  requireOrder(flags._[0]);
  injected('heartbeat');
  requireLive();
  runtimeCap();
  const seconds = renewLease();
  state.heartbeats = (state.heartbeats || 0) + 1;
  save(state);
  printJson({ order: publicOrder(), lease_seconds: seconds, head_sha: state.order.head_sha || null, answers: answered() });
}

function applyStage(flags, clientEventId) {
  const target = flags.stage;
  if (!(target in STAGE_RANK) || target === 'claimed') apiFail(422, 'invalid_status', 'status must be one of planning, implementing, pr_open, reviewing, validating, ready_for_merge');
  if (flags['autopilot-stage'] !== undefined && !/^[A-Z][A-Z0-9_]{0,39}$/.test(flags['autopilot-stage'])) {
    apiFail(422, 'invalid_autopilot_stage', 'autopilotStage must be an upper-case stage name');
  }
  if (flags.head !== undefined && !/^([0-9a-f]{40}|[0-9a-f]{64})$/.test(flags.head)) {
    apiFail(422, 'invalid_head_sha', 'headSha must be the full commit SHA');
  }
  if (flags.branch !== undefined) validateBranch(String(flags.branch));
  const prNumber = flags['pr-number'] !== undefined ? Number(flags['pr-number']) : null;
  if (flags['pr-url'] !== undefined) {
    const expected = `${state.order.repository}/pull/${prNumber}`;
    if (flags['pr-url'] !== expected) apiFail(422, 'invalid_pr_url', 'the PR link must be the canonical link of the order repository');
  }
  const current = state.order.status;
  const currentRank = STAGE_RANK[current];
  if (currentRank === undefined || current === 'ready_for_merge') apiFail(409, 'invalid_transition', `invalid work order transition from "${current}" to "${target}"`);
  if (current === 'claimed' && !state.order.claim_confirmed_at) apiFail(409, 'claim_not_confirmed', 'the daemon has not confirmed this claim yet');
  if (target !== 'ready_for_merge') runtimeCap();
  const targetRank = STAGE_RANK[target];
  const hasPr = (state.order.pr_number !== null || prNumber !== null) && (state.order.pr_url !== null || flags['pr-url'] !== undefined);
  if (targetRank < currentRank) apiFail(409, 'invalid_transition', `invalid work order transition from "${current}" to "${target}"`);
  if (targetRank >= 3 && !hasPr) apiFail(422, 'pr_required', 'pr_open and later stages need prUrl and prNumber');
  if (target === 'ready_for_merge' && !flags.head && !state.order.head_sha) apiFail(422, 'head_required', 'ready_for_merge needs the PR head SHA');
  if (targetRank >= 4 && currentRank < 2) apiFail(409, 'invalid_transition', `invalid work order transition from "${current}" to "${target}"`);
  if (state.order.pr_number !== null && prNumber !== null && state.order.pr_number !== prNumber) apiFail(409, 'pr_mismatch', 'the order already has a different pull request');
  if (currentRank <= 1 && targetRank >= 2 && state.policy.plan_approval === 'required'
      && !(state.approvals || []).some((approval) => approval.spec_hash === state.order.spec_hash)) {
    apiFail(409, 'plan_approval_required', 'the product requires a human plan approval before implementation: move to planning, attach the plan as an artifact, then block with plan_approval and wait for a person to approve it');
  }
  if (flags['autopilot-run-id']) state.order.autopilot_run_id = flags['autopilot-run-id'];
  if (flags.branch) state.order.branch = flags.branch;
  if (flags['pr-url']) state.order.pr_url = flags['pr-url'];
  if (prNumber !== null) state.order.pr_number = prNumber;
  if (flags.head) state.order.head_sha = flags.head;
  state.order.status = target;
  const event = recordEvent({
    client_event_id: clientEventId,
    event_type: 'stage',
    from_status: current,
    to_status: target,
    autopilot_stage: flags['autopilot-stage'] || null,
    head_sha: flags.head || null,
    client_name: flags['client-name'],
    client_version: flags['client-version'],
    detail: {},
  });
  if (target === 'ready_for_merge') {
    state.mode = 'ended';
  } else {
    renewLease();
    if (state.gateRefusal && ((target === 'implementing' && currentRank <= 1) || (targetRank >= 3 && currentRank < 3))) {
      endSession('blocked', 'gate_refused', state.gateRefusal);
    }
  }
  return event;
}

function applyArtifact(flags, clientEventId) {
  const kinds = ['plan', 'report', 'evidence', 'pr', 'other'];
  if (!kinds.includes(flags.artifact)) apiFail(422, 'invalid_detail', 'detail.kind must be one of plan, report, evidence, pr, other');
  if (!flags.url && !flags.path) apiFail(422, 'invalid_detail', 'an artifact names a url or a path');
  if (flags.sha !== undefined && !/^[0-9a-fA-F]{7,64}$/.test(flags.sha)) apiFail(422, 'invalid_sha', 'detail.sha must be a commit SHA');
  guardProse('detail.summary', flags.summary, false);
  runtimeCap();
  renewLease();
  return recordEvent({
    client_event_id: clientEventId,
    event_type: 'artifact',
    from_status: state.order.status,
    to_status: state.order.status,
    client_name: flags['client-name'],
    client_version: flags['client-version'],
    detail: { kind: flags.artifact, url: flags.url || undefined, path: (Array.isArray(flags.path) ? flags.path[flags.path.length - 1] : flags.path) || undefined, sha: flags.sha || undefined, summary: flags.summary || undefined },
  });
}

function applyBlocked(flags, clientEventId) {
  const kind = flags.blocked;
  if (kind !== 'plan_approval' && kind !== 'worker_error') apiFail(422, 'invalid_blocked_kind', 'a session may block with plan_approval or worker_error; questions use the questions route');
  guardProse('detail.reason', flags.reason, true);
  if (kind === 'plan_approval') {
    if (state.order.status !== 'planning') apiFail(409, 'invalid_transition', `invalid work order transition from "${state.order.status}" to "blocked(plan_approval)"`);
    if (state.policy.plan_approval !== 'required') apiFail(409, 'plan_approval_not_required', 'the product approves plans automatically; continue with implementing');
  } else {
    if (state.order.status === 'claimed' && !state.order.claim_confirmed_at) apiFail(409, 'claim_not_confirmed', 'the daemon has not confirmed this claim yet');
    state.order.failed_attempts = (state.order.failed_attempts || 0) + 1;
  }
  const from = state.order.status;
  endSession('blocked', kind, flags.reason);
  return recordEvent({
    client_event_id: clientEventId,
    event_type: 'blocked',
    from_status: from,
    to_status: 'blocked',
    client_name: flags['client-name'],
    client_version: flags['client-version'],
    detail: { blocked_kind: kind, reason: flags.reason },
  });
}

function workEvent(flags) {
  const selected = ['stage', 'artifact', 'blocked'].filter((name) => flags[name] !== undefined);
  if (selected.length !== 1) usage('exactly one of --stage, --artifact or --blocked is required');
  if (flags.stage !== undefined && flags.detail !== undefined) usage('--detail does not apply to --stage events; stage events carry only their flags');
  if (flags.blocked !== undefined && !flags.reason) usage('--blocked needs --reason');
  requireSessionToken('work event');
  requireOrder(flags._[0]);
  injected('event');
  const clientEventId = flags['client-event-id'] || `cli-${crypto.randomBytes(12).toString('hex')}`;
  flags['client-event-id'] = clientEventId;
  const type = selected[0];
  const replay = replayLookup(clientEventId, type, type === 'stage' ? flags.stage : null);
  if (replay) printJson({ event: replay, order: publicOrder(), replay: true });
  requireLive();
  validClientEvent(flags);
  let event;
  if (type === 'stage') event = applyStage(flags, clientEventId);
  else if (type === 'artifact') event = applyArtifact(flags, clientEventId);
  else event = applyBlocked(flags, clientEventId);
  save(state);
  printJson({ event, order: publicOrder(), replay: false });
}

function workAsk(flags) {
  if (!flags.category || !flags.question) usage('--category and --question are required');
  if (!flags.blocking && !flags['default-option']) usage('--default-option is required unless --blocking is set');
  requireSessionToken('work ask');
  requireOrder(flags._[0]);
  injected('ask');
  const clientEventId = flags['client-event-id'] || `cli-${crypto.randomBytes(12).toString('hex')}`;
  const prior = state.events.find((event) => event.client_event_id === clientEventId);
  if (prior) {
    if (prior.event_type !== 'question') apiFail(409, 'client_event_id_reused', 'clientEventId was already used for another event');
    const question = state.questions.find((entry) => entry.id === prior.detail.question_id);
    printJson({ question, order: publicOrder(), escalated: false, replay: true });
  }
  requireLive();
  guardProse('question', flags.question, true);
  if (!flags.blocking) runtimeCap();
  const asked = state.questions.filter((entry) => entry.work_order_id === state.order.id).length;
  const question = {
    id: crypto.randomUUID(),
    work_plan_id: state.order.work_plan_id,
    work_order_id: state.order.id,
    category: flags.category,
    question: flags.question,
    options: flags.option || [],
    default_option: flags['default-option'] || null,
    blocking: Boolean(flags.blocking),
    requirement_ids: flags.requirement || [],
    status: 'awaiting_human',
    answer: null,
  };
  state.questions.push(question);
  recordEvent({ client_event_id: clientEventId, event_type: 'question', from_status: state.order.status, to_status: state.order.status, detail: { question_id: question.id, blocking: question.blocking } });
  let escalated = false;
  if (asked >= state.policy.max_questions_per_order) {
    endSession('blocked', 'escalated', 'underspecified');
    escalated = true;
  } else if (question.blocking) {
    endSession('blocked', flags.category === 'scope' ? 'spec_change' : 'question', `question:${question.id}`);
  } else {
    renewLease();
  }
  save(state);
  printJson({ question, order: publicOrder(), escalated, replay: false });
}

function workFollowup(flags) {
  if (!flags.title || !flags.rationale) usage('--title and --rationale are required');
  if (!['low', 'medium', 'high', 'critical'].includes(flags.severity)) usage('--severity must be one of low, medium, high, critical');
  requireSessionToken('work followup');
  requireOrder(flags._[0]);
  injected('followup');
  const clientEventId = flags['client-event-id'] || `cli-${crypto.randomBytes(12).toString('hex')}`;
  const prior = state.events.find((event) => event.client_event_id === clientEventId);
  if (prior) printJson({ event: prior, replay: true });
  requireLive();
  guardProse('title', flags.title, true);
  guardProse('rationale', flags.rationale, true);
  state.followups = state.followups || [];
  if (state.followups.length >= 20) apiFail(409, 'followup_limit_reached', 'an attempt reports at most 20 follow-ups');
  state.followups.push({ title: flags.title, rationale: flags.rationale, severity: flags.severity, paths: flags.path || [] });
  const event = recordEvent({ client_event_id: clientEventId, event_type: 'followup', from_status: state.order.status, to_status: state.order.status, detail: { title: flags.title } });
  save(state);
  printJson({ event, replay: false });
}

function workEvents(flags) {
  requireSessionToken('work events');
  if (state.mode === 'ended') apiFail(401, 'invalid_session_token', 'session token expired or revoked');
  requireOrder(flags._[0]);
  const page = Number(flags.page || 1);
  const perPage = Number(flags['per-page'] || 20);
  const all = [...(state.historyEvents || []), ...state.events];
  printJson({ data: all.slice((page - 1) * perPage, page * perPage), total: all.length });
}

function pulseStart(flags) {
  if (!flags['work-order']) {
    printJson({ id: 'pulse-local-session' });
  }
  requireSessionToken('pulse start --work-order');
  if (state.mode === 'ended') apiFail(401, 'invalid_session_token', 'session token expired or revoked');
  requireOrder(flags['work-order']);
  injected('pulse');
  state.pulse = { attempt: state.order.attempt, clientName: flags['client-name'] || null, clientVersion: flags['client-version'] || null };
  save(state);
  if (state.trackingDisabled) printJson({ status: 'tracking_disabled' });
  printJson({ id: `pulse-${state.order.attempt}` });
}

function main() {
  logCall();
  if (argv[0] === '--version' || argv[0] === 'version') {
    process.stdout.write('zensu 0.8.0-fake\n');
    process.exit(0);
  }
  state = load();
  const [noun, verb, ...rest] = argv;
  if (noun === 'work') {
    if (state.noWork) usage('unknown command "work" for "zensu"');
    if (verb === undefined || verb === '--help' || verb === 'help') {
      process.stdout.write('Dispatch, run and decide work orders\n');
      process.exit(0);
    }
    const flags = parseFlags(rest);
    switch (verb) {
      case 'get': return workGet(flags);
      case 'heartbeat': return workHeartbeat(flags);
      case 'event': return workEvent(flags);
      case 'ask': return workAsk(flags);
      case 'followup': return workFollowup(flags);
      case 'events': return workEvents(flags);
      default:
        return apiFail(403, 'interactive_user_required', 'this decision needs a person signed in to Zensu');
    }
  }
  if (noun === 'pulse' && verb === 'start') return pulseStart(parseFlags(rest));
  process.stdout.write('{}\n');
  process.exit(0);
}

main();
