'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const STATE_FILE = process.env.FAKE_ZENSU_STATE;
const CALLS_FILE = process.env.FAKE_ZENSU_CALLS;
const STAGE_RANK = { claimed: 0, planning: 1, implementing: 2, pr_open: 3, reviewing: 4, validating: 5, ready_for_merge: 6 };
const BRANCH_PREFIX = 'wo-';
const GIT_REF_RE = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$/;
const COMMAND_WORDS = new Set(['sudo', 'git', 'npm', 'pnpm', 'npx', 'yarn', 'go', 'make', 'docker', 'docker-compose', 'kubectl',
  'helm', 'terraform', 'curl', 'wget', 'pip', 'pip3', 'python', 'python3', 'node', 'deno', 'bun', 'bash', 'sh', 'zsh', 'cd', 'ls',
  'cat', 'rm', 'mv', 'cp', 'chmod', 'chown', 'psql', 'mysql', 'sqlite3', 'redis-cli', 'brew', 'apt', 'apt-get', 'yum', 'dnf',
  'cargo', 'rustc', 'javac', 'java', 'mvn', 'gradle', 'ssh', 'scp', 'rsync', 'tar', 'grep', 'sed', 'awk', 'find', 'xargs',
  'export', 'source', 'eval', 'echo', 'printf', 'claude', 'zensu', 'gh', 'glab', 'aws', 'gcloud', 'az']);
const PACKAGE_VERBS = ['install', 'i', 'run', 'add', 'exec', 'test', 'ci', 'publish', 'remove', 'update'];
const SUBCOMMAND_PAIRS = {
  git: ['push', 'pull', 'commit', 'checkout', 'rebase', 'merge', 'reset', 'clone', 'log', 'diff', 'status', 'add', 'fetch', 'stash',
    'cherry-pick', 'revert', 'tag', 'branch', 'switch', 'restore'],
  npm: PACKAGE_VERBS,
  pnpm: PACKAGE_VERBS,
  yarn: PACKAGE_VERBS,
  go: ['test', 'build', 'run', 'vet', 'mod', 'get', 'install', 'generate'],
  docker: ['run', 'exec', 'build', 'compose', 'push', 'pull', 'rm', 'stop', 'start', 'logs'],
  kubectl: ['get', 'apply', 'exec', 'logs', 'delete', 'describe', 'port-forward', 'rollout', 'edit'],
  helm: ['install', 'upgrade', 'uninstall', 'template'],
  terraform: ['plan', 'apply', 'init', 'destroy', 'import'],
  cargo: ['build', 'run', 'test', 'install'],
  pip: ['install', 'uninstall'],
  pip3: ['install', 'uninstall'],
  brew: ['install', 'upgrade', 'uninstall'],
  apt: ['install', 'remove', 'purge', 'update', 'upgrade'],
  'apt-get': ['install', 'remove', 'purge', 'update', 'upgrade'],
  yum: ['install', 'remove', 'update', 'upgrade'],
  dnf: ['install', 'remove', 'update', 'upgrade'],
  gh: ['pr', 'issue', 'api', 'repo', 'run', 'release'],
  glab: ['pr', 'issue', 'api', 'repo', 'run', 'release'],
  claude: ['-p', '--print', 'mcp', 'config'],
  zensu: ['work', 'plan', 'auth', 'features', 'pulse', 'worker'],
};
const PROSE_FOLLOWERS = new Set(['the', 'a', 'an', 'ahead', 'sure', 'out', 'it', 'that', 'this', 'these', 'those', 'all', 'any', 'some',
  'why', 'how', 'what', 'where', 'when', 'which', 'who', 'whether', 'if', 'and', 'or', 'to', 'for', 'in', 'on', 'of',
  'with', 'by', 'from', 'into', 'up', 'our', 'your', 'their', 'its', 'my', 'we', 'you', 'they', 'them', 'us', 'me',
  'each', 'every', 'no', 'not']);
const SHELL_MARKERS = ['|', '&&', '||', ';', '>', '<', '$(', '`', '~/', './', '../'];
const RE2_SPACE = '[\\t\\n\\f\\r ]';
const DIFF_LINE_RES = [/^@@ -\d+(,\d+)? \+\d+(,\d+)? @@/, /^diff --git /, /^index [0-9a-f]{7,}\.\.[0-9a-f]{7,}/, /^(--- a\/|\+\+\+ b\/|--- \/dev\/null|\+\+\+ \/dev\/null)/];
const STACK_HEADER_RES = [/goroutine \d+ \[/, /^panic: /, new RegExp(`^${RE2_SPACE}*File ".+", line \\d+`)];
const STACK_FRAME_RES = [
  new RegExp(`^${RE2_SPACE}+at [^\\t\\n\\f\\r ].*\\(.*:\\d+(:\\d+)?\\)${RE2_SPACE}*$`),
  new RegExp(`^${RE2_SPACE}+at [^\\t\\n\\f\\r ]+\\.[^\\t\\n\\f\\r ]+\\([A-Za-z0-9_$]+\\.java:\\d+\\)`),
  new RegExp(`^${RE2_SPACE}+[^\\t\\n\\f\\r ]+\\.go:\\d+( \\+0x[0-9a-f]+)?${RE2_SPACE}*$`),
  new RegExp(`^${RE2_SPACE}+from [^\\t\\n\\f\\r ]+:\\d+:in `),
  new RegExp(`^#\\d+${RE2_SPACE}+0x[0-9a-f]+ in `),
];
const HTML_CODE_TAG_RE = new RegExp(`<(pre|code)(${RE2_SPACE}|>)`, 'i');
const FENCE_LINE_RE = /^ {0,3}(```|~~~)/;
const INLINE_CODE_RE = /`([^`\n]+)`/g;
const WINDOWS_PROMPT_RE = new RegExp(`^(PS [A-Za-z]:\\\\[^>]*>|[A-Za-z]:\\\\>)${RE2_SPACE}*[^\\t\\n\\f\\r ]`);
const FLAG_TOKEN_RE = new RegExp(`${RE2_SPACE}--?[A-Za-z]`);
const MAKE_TARGET_RE = /^make [a-z][a-z0-9_-]*$/;
const SCRIPT_FILE_RE = /^[\w.-]+\.(py|js|mjs|cjs|ts|sh|bash|zsh|rb|pl|php|go|jar|sql)$/;
const LEADING_MARKER_RE = /^(?:>[ \t]*|(?:[-*+\u2022]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?)/;
const FIELD_SPLIT_RE = new RegExp(`${RE2_SPACE}+`);
const SECRET_RES = [
  /-----BEGIN [A-Z ]*PRIVATE KEY/,
  /\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b/,
  /\bgithub_pat_[A-Za-z0-9_]{22,}\b/,
  /\bglpat-[A-Za-z0-9_-]{20,}\b/,
  /\b(AKIA|ASIA)[0-9A-Z]{16}\b/,
  /\bxox[abposr]-[A-Za-z0-9-]{10,}\b/,
  /\bsk-ant-[A-Za-z0-9_-]{20,}/,
  /\bsk-(proj-)?[A-Za-z0-9_-]{20,}/,
  /\b(sk|rk)_(live|test)_[A-Za-z0-9]{16,}\b/,
  /\bAIza[0-9A-Za-z_-]{35}\b/,
  /\bzsk_[0-9a-f]{16,}\b/,
  /\bzst_[A-Za-z0-9_-]{20,}/,
  /\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/,
  /:\/\/[^/\s:@]+:[^/\s@]+@/,
];
const REDACT_SPACE = '[\\t\\n\\f\\r \\p{Z}\\u0085]';
const BEARER_RE = new RegExp(`\\b(bearer${REDACT_SPACE}+)([A-Za-z0-9._~+/=-]{16,})`, 'iu');
const BASIC_TOKEN_RE = new RegExp(`(\\bauthorization["']?${REDACT_SPACE}*[:=]${REDACT_SPACE}*["']?)?\\b(basic${REDACT_SPACE}+)([A-Za-z0-9+/]{8,}={0,2})`, 'giu');
const ASSIGNMENT_RE = new RegExp(`\\b((?:[A-Za-z0-9]+[_-])*[A-Za-z0-9]*(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|client[_-]?secret))(["']?${REDACT_SPACE}*(?::=|=>|[:=])${REDACT_SPACE}*["']?)([^\\t\\n\\f\\r \\p{Z}\\u0085"',;]{6,})`, 'giu');
const CLI_VERSION = '0.8.0-fake';
const DEFAULT_API_URL = 'https://api.zensu.dev';
const PLAN_PATH_RE = /^[\p{L}\p{Nd}._\-\/+@~()[\]{}=, ]+$/u;
const PR_PATH_RE = /^\/(?:pull|pulls|pull-requests|merge_requests|-\/merge_requests)\/([1-9][0-9]{0,9})$/;

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
  if (argv.includes('--json')) process.stderr.write(`${JSON.stringify({ error: { message } })}\n`);
  process.exit(1);
}

function apiUrlFlag() {
  const index = argv.indexOf('--api-url');
  if (index >= 0 && argv[index + 1]) return argv[index + 1];
  const joined = argv.find((arg) => arg.startsWith('--api-url='));
  return joined ? joined.slice('--api-url='.length) : '';
}

function validPlanPath(entry) {
  if (entry === '' || entry === '.' || Buffer.byteLength(entry) > 512 || entry.trim() !== entry) return false;
  if (entry.startsWith('/') || entry.endsWith('/') || path.posix.normalize(entry) !== entry || entry.split('/').includes('..')) return false;
  return PLAN_PATH_RE.test(entry);
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
  if (state && Number.isSafeInteger(state.dropAnswers) && state.dropAnswers > 0 && argv[0] === 'work' && (argv[1] === 'event' || argv[1] === 'ask')) {
    state.dropAnswers -= 1;
    save(state);
    process.stderr.write('error: read tcp 127.0.0.1:52144->127.0.0.1:18080: read: connection reset by peer\n');
    if (argv.includes('--json')) process.stderr.write(`${JSON.stringify({ error: { message: 'read: connection reset by peer' } })}\n`);
    process.exit(1);
  }
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
    if (name === 'requirement') {
      flags[name] = [...(flags[name] || []), ...String(value).split(',')];
    } else if (multi.has(name)) {
      flags[name] = [...(flags[name] || []), value];
    } else {
      flags[name] = value;
    }
  }
  return flags;
}

function injected(command, flags = {}) {
  const queue = Array.isArray(state.failNext) ? state.failNext : [];
  const index = queue.findIndex((entry) => entry.command === command && (!entry.flag || flags[entry.flag] !== undefined));
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
  if (!token.startsWith('zst_')) usage('ZENSU_SESSION_TOKEN must hold a work order session token (zst_\u2026)');
  if (!process.env.ZENSU_API_URL && !apiUrlFlag() && !state.storedApiUrl) {
    usage(`ZENSU_SESSION_TOKEN needs the host that issued it: set ZENSU_API_URL or pass --api-url; a session token is never sent to the built-in default ${DEFAULT_API_URL}`);
  }
  if (state.mode === 'revoked' || token !== state.token) apiFail(401, 'invalid_session_token', 'session token expired or revoked');
}

function requireOrder(id) {
  if (!state.order || String(id || '').toLowerCase() !== state.order.id.toLowerCase()) {
    apiFail(403, 'session_order_mismatch', 'the session token belongs to another work order');
  }
}

function sessionEnded() {
  return state.mode === 'ended' || !(state.order.lease_expires_at > now());
}

function requireLive() {
  if (sessionEnded()) apiFail(401, 'invalid_session_token', 'session token expired or revoked');
  if (state.staleAttempt) {
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

function isAnswered(question) {
  return question.status === 'answered' || question.status === 'auto_answered';
}

function answered() {
  return (state.questions || []).filter((question) => question.work_order_id === state.order.id && isAnswered(question));
}

function decisionLog() {
  return (state.questions || []).filter((question) => question.work_plan_id === state.order.work_plan_id && question.scope === 'plan' && question.status === 'answered');
}

function hasDiff(lines) {
  return lines.some((line) => DIFF_LINE_RES.some((pattern) => pattern.test(line)));
}

function hasStackTrace(text, lines) {
  if (text.includes('Traceback (most recent call last)') || text.includes('Exception in thread "')) return true;
  let frames = 0;
  for (const line of lines) {
    if (STACK_HEADER_RES.some((pattern) => pattern.test(line))) return true;
    if (STACK_FRAME_RES.some((pattern) => pattern.test(line))) frames += 1;
  }
  return frames >= 2;
}

function hasCodeBlock(text, lines) {
  if (HTML_CODE_TAG_RE.test(text)) return true;
  let indented = 0;
  for (const line of lines) {
    if (FENCE_LINE_RE.test(line)) return true;
    if ((line.startsWith('\t') || line.startsWith('    ')) && line.trim() !== '') {
      indented += 1;
      if (indented >= 3) return true;
      continue;
    }
    indented = 0;
  }
  return false;
}

function looksLikeCommand(line) {
  if (WINDOWS_PROMPT_RE.test(line)) return true;
  for (const prompt of ['$ ', '% ', '>>> ']) {
    if (line.startsWith(prompt) && line.slice(prompt.length).trim() !== '') return true;
  }
  if (line.startsWith('# ')) {
    const fields = line.slice(2).trim().split(FIELD_SPLIT_RE);
    return COMMAND_WORDS.has(fields[0]);
  }
  const fields = line.trim().split(FIELD_SPLIT_RE);
  if (!COMMAND_WORDS.has(fields[0])) return false;
  if (fields[0] === 'make' && MAKE_TARGET_RE.test(line.trim())) return true;
  if (fields.length >= 2) {
    if ((SUBCOMMAND_PAIRS[fields[0]] || []).includes(fields[1])) return true;
    if (fields[0] === 'sudo') return true;
  }
  const rest = line.slice(fields[0].length).trim();
  if (rest === '') return false;
  if (FLAG_TOKEN_RE.test(` ${rest}`)) return true;
  if (SHELL_MARKERS.some((marker) => rest.includes(marker))) return true;
  if (PROSE_FOLLOWERS.has(String(fields[1] || '').toLowerCase())) return false;
  return fields.slice(1).some((field) => field.includes('/') || SCRIPT_FILE_RE.test(field));
}

function isCommand(raw) {
  let line = raw.replace(/^[ \t]+/, '');
  while (line !== '') {
    if (looksLikeCommand(line)) return true;
    const prefix = LEADING_MARKER_RE.exec(line);
    if (!prefix || prefix[0] === '') return false;
    line = line.slice(prefix[0].length);
  }
  return false;
}

function hasCommandLine(text, lines) {
  if (lines.some(isCommand)) return true;
  for (const match of text.matchAll(INLINE_CODE_RE)) {
    if (isCommand(match[1])) return true;
  }
  return false;
}

function proseViolation(text, maxBytes = 2048) {
  if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(text)) return 'control_characters';
  if (Buffer.byteLength(text) > maxBytes) return 'too_long';
  const normalized = text.replace(/\r\n|\r|\u0085|\u2028|\u2029/g, '\n');
  const lines = normalized.split('\n');
  if (hasDiff(lines)) return 'diff_hunk';
  if (hasStackTrace(normalized, lines)) return 'stack_trace';
  if (hasCodeBlock(normalized, lines)) return 'code_block';
  if (hasCommandLine(normalized, lines)) return 'command_line';
  return null;
}

function guardProse(field, text, required, maxBytes = 2048) {
  const trimmed = typeof text === 'string' ? text.trim() : '';
  if (!trimmed) {
    if (required) apiFail(422, 'missing_field', `${field} is required`);
    return '';
  }
  const reason = proseViolation(trimmed, maxBytes);
  if (reason) apiFail(422, 'content_not_allowed', `content_not_allowed: ${field}: ${reason}; send metadata and short prose only, never code, commands, logs or diffs`);
  return trimmed;
}

function recordEvent(fields) {
  const event = {
    id: crypto.randomUUID(),
    work_order_id: state.order.id,
    attempt: state.order.attempt,
    actor_kind: 'session',
    client_session_id: state.order.client_session_id,
    occurred_at: iso(now() + (Number.isFinite(state.clientSkewMs) ? state.clientSkewMs : 0)),
    created_at: iso(now()),
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

function validatePrUrl(raw, prNumber) {
  const fail = (message) => apiFail(422, 'invalid_pr_url', message);
  if (raw.length > 2048) fail('prUrl is too long');
  const parts = /^https:\/\/([^/?#@\s]+)(\/[^?#\s]*)$/i.exec(raw);
  if (!parts) fail('prUrl must be an https link without credentials, query or fragment');
  const rawPath = parts[2];
  if (rawPath.includes('%') || rawPath.endsWith('/') || path.posix.normalize(rawPath) !== rawPath) {
    fail('prUrl must not contain dot segments, doubled or encoded separators');
  }
  const hostPath = `${parts[1]}${rawPath}`.toLowerCase();
  const prefix = String(state.order.repository || '').toLowerCase();
  if (!hostPath.startsWith(`${prefix}/`)) fail("prUrl must point into the order's repository");
  const match = PR_PATH_RE.exec(hostPath.slice(prefix.length));
  if (!match) fail('prUrl must be the pull request link <repository>/pull/<number> or <repository>/-/merge_requests/<number>');
  const number = Number(match[1]);
  if (number > 1000000000) fail('prUrl names an invalid pull request number');
  const expected = prNumber !== null ? prNumber : state.order.pr_number;
  if (expected !== null && expected !== undefined && expected !== number) fail('prUrl and prNumber name different pull requests');
  return `https://${prefix}${match[0]}`;
}

function validateBranch(branch) {
  const prefix = orderBranchPrefix();
  if (!branch.startsWith(prefix)) apiFail(422, 'invalid_branch', `order branches must start with ${prefix}`);
  const malformed = !GIT_REF_RE.test(branch) || branch.includes('..') || branch.includes('//') || branch.endsWith('/') || branch.endsWith('.')
    || branch.split('/').some((component) => component.startsWith('.') || component.endsWith('.lock'));
  if (malformed) apiFail(422, 'invalid_branch', 'branch is not a valid branch name');
}

function defaultSpec() {
  return {
    feature: { id: '55555555-5555-4555-8555-555555555555', reference: 'F-1', title: 'Fake order spec' },
    revision: { id: '66666666-6666-4666-8666-666666666666', version: '1', scope_summary: 'Render the widget list.', acceptance_criteria: ['The widget list renders.'] },
    repository: state.order.repository,
    base_branch: state.plan.base_branch,
    integration_branch: state.plan.integration_branch,
    requirements: [{ id: 'AC-001', tags: ['ui'] }],
    paths: [],
  };
}

function workGet(flags) {
  requireSessionToken('work get');
  if (sessionEnded()) apiFail(401, 'invalid_session_token', 'session token expired or revoked');
  requireOrder(flags._[0]);
  injected('get');
  const approved = (state.approvals || []).some((approval) => approval.spec_hash === state.order.spec_hash);
  printJson({
    ...publicOrder(),
    spec: { branch_prefix: BRANCH_PREFIX, ...(state.spec || defaultSpec()) },
    plan: state.plan,
    policy: state.policy,
    questions: (state.questions || []).filter((question) => question.work_order_id === state.order.id),
    decision_log: decisionLog(),
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
  if (flags.head !== undefined) {
    flags.head = String(flags.head).toLowerCase();
    if (!/^([0-9a-f]{40}|[0-9a-f]{64})$/.test(flags.head)) apiFail(422, 'invalid_sha', 'headSha must be the full commit SHA');
  }
  if (flags.branch !== undefined) validateBranch(String(flags.branch));
  const prNumber = flags['pr-number'] !== undefined ? Number(flags['pr-number']) : null;
  const prUrl = flags['pr-url'] !== undefined ? validatePrUrl(String(flags['pr-url']), prNumber) : null;
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
  if (prUrl) state.order.pr_url = prUrl;
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

function isBasicCredential(token) {
  const trimmed = token.replace(/=+$/, '');
  if (trimmed.length % 4 === 1) return false;
  let text = null;
  try {
    text = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.from(trimmed, 'base64'));
  } catch (_) {
    return false;
  }
  return text.includes(':') && !/[\u0000-\u001f\u007f-\u009f]/.test(text);
}

function redactChanges(text) {
  if (SECRET_RES.some((pattern) => pattern.test(text)) || BEARER_RE.test(text)) return true;
  if ([...text.matchAll(BASIC_TOKEN_RE)].some((match) => match[1] || isBasicCredential(match[3]))) return true;
  return [...text.matchAll(ASSIGNMENT_RE)].some((match) => !match[3].startsWith('[REDACTED'));
}

function applyArtifact(flags, clientEventId) {
  const kinds = ['plan', 'report', 'evidence', 'pr', 'other'];
  if (!kinds.includes(flags.artifact)) apiFail(422, 'invalid_detail', 'detail.kind must be one of plan, report, evidence, pr, other');
  if (!flags.url && !flags.path) apiFail(422, 'invalid_detail', 'an artifact names a url or a path');
  if (flags.url) {
    const url = String(flags.url);
    if (url.length > 2048) apiFail(422, 'invalid_url', 'detail.url is too long');
    let parsed = null;
    try {
      parsed = new URL(url);
    } catch (_) {
      parsed = null;
    }
    if (!parsed || parsed.protocol !== 'https:' || !parsed.host || parsed.username || parsed.password) {
      apiFail(422, 'invalid_url', 'detail.url must be an https link without credentials');
    }
    if (redactChanges(url)) apiFail(422, 'invalid_url', 'detail.url must not carry a secret');
  }
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

function probeOutbox(clientEventId) {
  if (typeof state.outboxProbe !== 'string') return;
  let inflight = [];
  try {
    const outbox = JSON.parse(fs.readFileSync(state.outboxProbe, 'utf8'));
    inflight = (Array.isArray(outbox.inflight) ? outbox.inflight : []).map((record) => {
      const args = Array.isArray(record.args) ? record.args : [];
      return args.indexOf('--client-event-id') >= 0 ? args[args.indexOf('--client-event-id') + 1] : null;
    });
  } catch (_) {
    inflight = [];
  }
  state.outboxSeen = [...(Array.isArray(state.outboxSeen) ? state.outboxSeen : []), { id: clientEventId || null, inflight }];
  save(state);
}

function workEvent(flags) {
  const selected = ['stage', 'artifact', 'blocked'].filter((name) => flags[name] !== undefined);
  if (selected.length !== 1) usage('exactly one of --stage, --artifact or --blocked is required');
  if (flags.stage !== undefined && flags.detail !== undefined) usage('--detail does not apply to --stage events; stage events carry only their flags');
  if (flags.blocked !== undefined && !flags.reason) usage('--blocked needs --reason');
  requireSessionToken('work event');
  requireOrder(flags._[0]);
  probeOutbox(flags['client-event-id']);
  injected('event', flags);
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

function validateQuestion(flags) {
  const categories = ['clarification', 'technical_choice', 'product_decision', 'scope', 'risk', 'external'];
  if (!categories.includes(flags.category)) apiFail(422, 'invalid_category', `category must be one of ${categories.join(', ')}`);
  guardProse('question', flags.question, true);
  const options = flags.option || [];
  if (options.length > 10) apiFail(422, 'invalid_options', 'at most 10 options');
  const seen = new Set();
  options.forEach((option, index) => {
    const trimmed = guardProse(`options[${index}]`, option, true, 300);
    if (seen.has(trimmed)) apiFail(422, 'invalid_options', 'options must be distinct');
    seen.add(trimmed);
  });
  const fallback = guardProse('defaultOption', flags['default-option'], false, 300);
  if (!flags.blocking && !fallback) apiFail(422, 'default_required', 'a non-blocking question needs the default the session continues with');
  if (fallback && options.length > 0 && !seen.has(fallback)) apiFail(422, 'invalid_default', 'defaultOption must be one of the options');
  const requirements = flags.requirement || [];
  if (requirements.length > 20) apiFail(422, 'invalid_requirements', 'at most 20 requirement IDs per question');
  if (requirements.some((id) => !/^(AC|FR|IF)-[0-9]{3,6}$/.test(id))) apiFail(422, 'invalid_requirements', 'requirement IDs must look like AC-001, FR-001 or IF-001');
}

function workAsk(flags) {
  if (!flags.category || !flags.question) usage('--category and --question are required');
  if (!flags.blocking && !flags['default-option']) usage('--default-option is required unless --blocking is set');
  requireSessionToken('work ask');
  requireOrder(flags._[0]);
  probeOutbox(flags['client-event-id']);
  injected('ask');
  validateQuestion(flags);
  const clientEventId = flags['client-event-id'] || `cli-${crypto.randomBytes(12).toString('hex')}`;
  const prior = state.events.find((event) => event.client_event_id === clientEventId);
  if (prior) {
    if (prior.event_type !== 'question') apiFail(409, 'client_event_id_reused', 'clientEventId was already used for another event');
    const question = state.questions.find((entry) => entry.id === prior.detail.question_id);
    printJson({ question, order: publicOrder(), escalated: false, replay: true });
  }
  requireLive();
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
  recordEvent({ client_event_id: clientEventId, event_type: 'question', from_status: state.order.status, to_status: state.order.status, client_name: 'zensu-cli', client_version: CLI_VERSION, detail: { question_id: question.id, blocking: question.blocking } });
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
  const paths = flags.path || [];
  if (paths.length > 20) usage('at most 20 --path values');
  for (const entry of paths) {
    if (!validPlanPath(entry)) usage(`--path ${JSON.stringify(entry)} must be a clean relative file path without wildcards`);
  }
  requireSessionToken('work followup');
  requireOrder(flags._[0]);
  injected('followup');
  const clientEventId = flags['client-event-id'] || `cli-${crypto.randomBytes(12).toString('hex')}`;
  const prior = state.events.find((event) => event.client_event_id === clientEventId);
  if (sessionEnded()) {
    if (prior) printJson({ event: prior, order: publicOrder(), replay: true });
    apiFail(401, 'invalid_session_token', 'session token expired or revoked');
  }
  guardProse('title', flags.title, true, 200);
  guardProse('rationale', flags.rationale, true);
  if (prior) printJson({ event: prior, order: publicOrder(), replay: true });
  requireLive();
  state.followups = state.followups || [];
  if (state.followups.filter((entry) => entry.attempt === state.order.attempt).length >= 20) {
    apiFail(409, 'followup_limit_reached', 'an attempt reports at most 20 follow-ups');
  }
  state.followups.push({ title: flags.title, rationale: flags.rationale, severity: flags.severity, paths, attempt: state.order.attempt });
  const event = recordEvent({ client_event_id: clientEventId, event_type: 'followup', from_status: state.order.status, to_status: state.order.status, client_name: 'zensu-cli', client_version: CLI_VERSION, detail: { title: flags.title } });
  save(state);
  printJson({ event, order: publicOrder(), replay: false });
}

function workEvents(flags) {
  requireSessionToken('work events');
  if (sessionEnded()) apiFail(401, 'invalid_session_token', 'session token expired or revoked');
  requireOrder(flags._[0]);
  const page = Number(flags.page || 1);
  const perPage = Number(flags['per-page'] || 20);
  const key = (event) => [String(event.occurred_at || ''), String(event.created_at || ''), String(event.id || '')];
  const all = [...(state.historyEvents || []), ...state.events].sort((left, right) => {
    const [a, b] = [key(left), key(right)];
    for (let index = 0; index < a.length; index += 1) {
      if (a[index] !== b[index]) return a[index] < b[index] ? -1 : 1;
    }
    return 0;
  });
  printJson({ data: all.slice((page - 1) * perPage, page * perPage), total: all.length, page, perPage });
}

function pulseStart(flags) {
  if (!flags['work-order']) {
    printJson({ id: 'pulse-local-session' });
  }
  requireSessionToken('pulse start --work-order');
  if (sessionEnded()) apiFail(401, 'invalid_session_token', 'session token expired or revoked');
  requireOrder(flags['work-order']);
  injected('pulse');
  const previous = state.pulse && state.pulse.attempt === state.order.attempt && typeof state.pulse.id === 'string' ? state.pulse : null;
  state.pulse = {
    attempt: state.order.attempt,
    clientName: flags['client-name'] || null,
    clientVersion: flags['client-version'] || null,
    id: previous ? previous.id : null,
    startedAt: previous ? previous.startedAt : iso(now()),
  };
  save(state);
  if (state.trackingDisabled) printJson({ status: 'tracking_disabled' });
  state.pulse.id = state.pulse.id || crypto.randomUUID();
  save(state);
  printJson({ id: state.pulse.id, work_order_id: state.order.id, attempt: state.order.attempt, created: !previous, started_at: state.pulse.startedAt, ended_at: null });
}

function main() {
  logCall();
  if (argv[0] === '--version' || argv[0] === 'version') {
    process.stdout.write(`zensu ${CLI_VERSION}\n`);
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
      case 'list':
        if (process.env.ZENSU_SESSION_TOKEN) return apiFail(403, 'session_order_mismatch', 'a session token reads only its own work order');
        return apiFail(403, 'interactive_user_required', 'this decision needs a person signed in to Zensu');
      case 'questions':
      case 'policy':
      case 'repositories':
        if (process.env.ZENSU_SESSION_TOKEN) return apiFail(401, 'unauthorized', 'invalid token');
        return apiFail(403, 'interactive_user_required', 'this decision needs a person signed in to Zensu');
      default:
        return apiFail(403, 'interactive_user_required', 'this decision needs a person signed in to Zensu');
    }
  }
  if (noun === 'pulse' && verb === 'start') return pulseStart(parseFlags(rest));
  process.stdout.write('{}\n');
  process.exit(0);
}

if (require.main === module) main();
else module.exports = { proseViolation };
