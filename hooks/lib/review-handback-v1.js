'use strict';

const fs = require('node:fs');
const core = require('./session-control-core-v1.js');

const CONSUME_MARKER = 'PRE-MERGED FINDINGS (fan-out)';
const REVIEWER_TYPE = 'zensu:code-reviewer';
const FRAME_PREFIX = '[Subagent hand-back]';
const BODY_INDENT = '  ';
const OPEN_LINE_RE = /^<agent-message from="([A-Za-z0-9_-]{1,128})"[^>]*>$/;
const CLOSE_LINE = '</agent-message>';
const PREAMBLE_RE = /^Another Claude session sent a message(?: while you were working)?:$/;
const LEADING_REMINDER_RE = /^<system-reminder>[\s\S]*?<\/system-reminder>/;
const MAX_STATE_BYTES = 1024 * 1024;

function stripLeadingReminders(prompt) {
  let rest = prompt;
  for (;;) {
    const trimmed = rest.replace(/^\s+/, '');
    const reminder = LEADING_REMINDER_RE.exec(trimmed);
    if (!reminder) return trimmed;
    rest = trimmed.slice(reminder[0].length);
  }
}

function parseHandback(prompt) {
  if (typeof prompt !== 'string' || prompt.length === 0) return null;
  const lines = stripLeadingReminders(prompt).replace(/\s+$/, '').split('\n');
  if (lines.length > 0 && PREAMBLE_RE.test(lines[0])) lines.shift();
  if (lines.length < 3) return null;
  const open = OPEN_LINE_RE.exec(lines[0]);
  if (!open || lines[lines.length - 1] !== CLOSE_LINE) return null;
  const body = lines.slice(1, -1);
  const frames = body.filter((line) => line.startsWith(FRAME_PREFIX));
  if (frames.length !== 1) return null;
  if (!body.every((line) => line.startsWith(FRAME_PREFIX) || line.startsWith(BODY_INDENT))) return null;
  return { from: open[1] };
}

function readState(stateFile) {
  const stat = fs.lstatSync(stateFile);
  if (!stat.isFile() || stat.size > MAX_STATE_BYTES) return null;
  return JSON.parse(fs.readFileSync(stateFile, 'utf8'));
}

function liveBinding(state) {
  if (!state || typeof state !== 'object' || Array.isArray(state)) return null;
  const binding = state.reviewHandback;
  if (!core.reviewHandbackShapeOk(binding)) return null;
  const live = state.active === true
    && state.implComplete === true
    && state.chainDone === false
    && state.codeReviewDone === false
    && state.reviewTicket === binding.ticket
    && state.reviewTicketConsumed === false;
  return live ? binding : null;
}

function reviewHeader(binding) {
  return [CONSUME_MARKER, `REVIEW-TICKET: ${binding.ticket}`, ...binding.envelope].join('\n');
}

function handbackReviewInput(payload, state) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return null;
  const handback = parseHandback(payload.prompt);
  if (!handback) return null;
  const binding = liveBinding(state);
  if (!binding || binding.agentId !== handback.from) return null;
  return {
    hook_event_name: 'UserPromptSubmit',
    session_id: payload.session_id,
    tool_input: { subagent_type: REVIEWER_TYPE, prompt: reviewHeader(binding) },
    tool_response: { status: 'handback', agentId: binding.agentId },
  };
}

function boundReviewerInFlight(payload, state) {
  const binding = liveBinding(state);
  if (!binding || !payload || typeof payload !== 'object') return null;
  const { RUNNING_TASK_STATUSES } = require('./external-review-v1.js');
  const tasks = Array.isArray(payload.background_tasks) ? payload.background_tasks : [];
  const running = tasks.some((task) => task
    && typeof task === 'object'
    && task.id === binding.agentId
    && typeof task.status === 'string'
    && RUNNING_TASK_STATUSES.includes(task.status.toLowerCase())
    && (task.agent_type === undefined || task.agent_type === REVIEWER_TYPE));
  return running ? binding.agentId : null;
}

function readStdin() {
  return fs.readFileSync(0, 'utf8');
}

function stateArgument(argv) {
  const index = argv.indexOf('--state');
  if (index < 0 || typeof argv[index + 1] !== 'string' || argv[index + 1] === '') return null;
  return argv[index + 1];
}

function main(argv) {
  const mode = argv[0];
  const stateFile = stateArgument(argv);
  if (!stateFile || (mode !== 'handback-input' && mode !== 'stop-wait')) return 2;
  let payload;
  let state;
  try {
    payload = JSON.parse(readStdin());
    state = readState(stateFile);
  } catch {
    return 1;
  }
  if (mode === 'handback-input') {
    const input = handbackReviewInput(payload, state);
    if (!input) return 1;
    process.stdout.write(JSON.stringify(input));
    return 0;
  }
  const agentId = boundReviewerInFlight(payload, state);
  if (!agentId) return 1;
  process.stdout.write(`wait agent=${agentId}`);
  return 0;
}

if (require.main === module) {
  process.exitCode = main(process.argv.slice(2));
}

module.exports = {
  CONSUME_MARKER,
  FRAME_PREFIX,
  parseHandback,
  liveBinding,
  reviewHeader,
  handbackReviewInput,
  boundReviewerInFlight,
};
