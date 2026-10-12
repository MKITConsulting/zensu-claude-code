'use strict';

const fs = require('node:fs');
const path = require('node:path');

const ALLOW_TOOLS = ['Read', 'Glob', 'Grep', 'LS', 'LSP', 'WebSearch', 'WebFetch', 'BashOutput', 'TodoWrite', 'TaskCreate', 'TaskUpdate', 'TaskList', 'TaskGet', 'ToolSearch'];
const SETUP_TOOLS = ['EnterWorktree'];
const PLAIN = /^[^;&|<>$`\\\r\n]*$/;
const QUIET = /\s+([12]?>\s*\/dev\/null|2>&1)(?=\s|$)/g;
const READ_COMMAND = /^(ls|cat|head|tail|wc|pwd|tree|file|stat|cd|grep|egrep|fgrep|rg|find)(\s|$)|^git\s+(-C\s+\S+\s+)?(--no-pager\s+)?(status|log|diff|show|ls-files|rev-parse)(\s|$)|^(node\s+--test|npm\s+(run\s+)?test|pnpm\s+(run\s+)?test)(\s|$)/;
const UNSAFE_FLAG = /(^|\s)(--output|--ext-diff|--pre|--watch|--test-reporter-destination|-exec|-execdir|-delete|-ok|-okdir|-fprint|-fprint0|-fprintf|-fls)(=|\s|$)/;
const FOLLOW = /^tail\s(.*\s)?(-[A-Za-z0-9]*[fF][A-Za-z0-9]*|--follow)(=|\s|$)/;
const SETUP_COMMAND = /^git\s+(-C\s+\S+\s+)?(worktree|checkout|switch|branch)(\s|$)/;
const SEPARATOR = /\s*(?:&&|\|\||;|\|)\s*/;
const END_REASON = 'Not available in this environment; end your turn now with one sentence naming what you would do next.';
const CONTINUE_REASON = 'No person can answer questions in this run; continue without an answer.';
const SETUP_REASON = 'Worktrees and branches are not available in this environment; work in the current directory.';
const LIMIT = 4000;

function bounded(value, limit) {
  const text = typeof value === 'string' ? value : value == null ? '' : JSON.stringify(value);
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
}

function flattenQuestion(input) {
  const parts = [];
  const questions = input && Array.isArray(input.questions) ? input.questions : [];
  for (const q of questions) {
    if (!q || typeof q !== 'object') continue;
    for (const key of ['header', 'question']) if (typeof q[key] === 'string') parts.push(q[key]);
    for (const o of Array.isArray(q.options) ? q.options : []) {
      if (!o || typeof o !== 'object') continue;
      for (const key of ['label', 'description']) if (typeof o[key] === 'string') parts.push(o[key]);
    }
  }
  if (!parts.length && input && typeof input.question === 'string') parts.push(input.question);
  return bounded(parts.join(' | '), LIMIT);
}

function bashPart(raw) {
  const part = raw.replace(QUIET, '');
  if (!PLAIN.test(part)) return 'other';
  if (READ_COMMAND.test(part) && !UNSAFE_FLAG.test(part) && !FOLLOW.test(part)) return 'read';
  if (SETUP_COMMAND.test(part)) return 'setup';
  return 'other';
}

function bashDecision(command) {
  const parts = command.trim().split(SEPARATOR);
  const kinds = parts.map((p) => (p === '' ? 'other' : bashPart(p)));
  if (kinds.every((k) => k === 'read')) return 'ALLOW';
  if (kinds.every((k) => k !== 'other')) return 'SETUP';
  return 'END';
}

function decide(tool, input) {
  if (ALLOW_TOOLS.includes(tool)) return 'ALLOW';
  if (SETUP_TOOLS.includes(tool)) return 'SETUP';
  if (tool === 'Bash') return bashDecision(String((input && input.command) || ''));
  if (tool === 'AskUserQuestion') return 'CONTINUE';
  return 'END';
}

function reasonFor(decision) {
  if (decision === 'CONTINUE') return CONTINUE_REASON;
  if (decision === 'SETUP') return SETUP_REASON;
  return END_REASON;
}

function record(tool, input, id, decision) {
  const entry = { id: id || '', tool, decision };
  if (tool === 'Skill') entry.skill = bounded((input && (input.skill || input.name || input.command)) || '', 200);
  if (tool === 'Bash') entry.command = bounded((input && input.command) || '', 400);
  if (input && (input.file_path || input.path || input.pattern)) entry.path = bounded(input.file_path || input.path || input.pattern, 400);
  if (tool === 'AskUserQuestion') entry.question = flattenQuestion(input);
  return entry;
}

function append(dir, entry) {
  if (!dir) return;
  try {
    const file = path.join(dir, 'hook.log');
    const seq = fs.existsSync(file) ? fs.readFileSync(file, 'utf8').split('\n').filter((l) => l.startsWith('probe ')).length + 1 : 1;
    fs.appendFileSync(file, `probe ${JSON.stringify({ seq, ...entry })}\n`, { mode: 0o600 });
  } catch (_) {
    return;
  }
}

function main(raw, dir) {
  let payload = {};
  try { payload = JSON.parse(raw || '{}'); } catch (_) { payload = {}; }
  const tool = typeof payload.tool_name === 'string' ? payload.tool_name : '';
  const input = payload.tool_input && typeof payload.tool_input === 'object' ? payload.tool_input : {};
  const decision = decide(tool, input);
  append(dir, record(tool, input, payload.tool_use_id, decision));
  if (decision === 'ALLOW') return '';
  return JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reasonFor(decision) } });
}

if (require.main === module) {
  let raw = '';
  process.stdin.on('data', (chunk) => { raw += chunk; });
  process.stdin.on('end', () => {
    const out = main(raw, process.env.ZENSU_ROUTE_EVAL_DIR || '');
    if (out) process.stdout.write(`${out}\n`);
  });
}

module.exports = {
  ALLOW_TOOLS,
  SETUP_TOOLS,
  READ_COMMAND,
  UNSAFE_FLAG,
  FOLLOW,
  QUIET,
  SETUP_COMMAND,
  END_REASON,
  CONTINUE_REASON,
  SETUP_REASON,
  bashDecision,
  decide,
  reasonFor,
  flattenQuestion,
  record,
  main,
};
