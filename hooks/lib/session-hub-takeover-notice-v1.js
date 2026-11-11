'use strict';

const fs = require('fs');

const COMMAND_NAME = '/session-hub:session-trail';
const MAX_PAYLOAD_CHARS = 256 * 1024;
const MAX_ROOT_CHARS = 4096;
const REMINDER_OPEN = '<system-reminder>';
const REMINDER_CLOSE = '</system-reminder>';
const COMMAND_TAG = /<(command-message|command-name|command-args)>([\s\S]*?)<\/\1>/g;
const TAKEOVER_ARGUMENTS = /^takeover(?:\s|$)/;
const CONTROL_CHARACTER = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/;

function withoutReminders(text) {
  let rest = text;
  for (;;) {
    rest = rest.replace(/^\s+/, '');
    if (!rest.startsWith(REMINDER_OPEN)) return rest;
    const end = rest.indexOf(REMINDER_CLOSE);
    if (end < 0) return rest;
    rest = rest.slice(end + REMINDER_CLOSE.length);
  }
}

function takesOver(argumentsText) {
  return TAKEOVER_ARGUMENTS.test(argumentsText);
}

function tagsTakeOver(body) {
  const tags = new Map();
  for (const [, name, value] of body.matchAll(COMMAND_TAG)) {
    if (tags.has(name)) return false;
    tags.set(name, value);
  }
  if (body.replace(COMMAND_TAG, '').trim() !== '') return false;
  if (tags.get('command-name') !== COMMAND_NAME || !tags.has('command-args')) return false;
  return takesOver(tags.get('command-args').trim());
}

function isTakeoverPrompt(prompt) {
  if (typeof prompt !== 'string' || prompt.length > MAX_PAYLOAD_CHARS) return false;
  const body = withoutReminders(prompt).trim();
  if (body.startsWith(COMMAND_NAME)) {
    const rest = body.slice(COMMAND_NAME.length);
    if (!/^\s/.test(rest)) return false;
    return takesOver(rest.replace(/^\s+/, ''));
  }
  if (body.startsWith('<command-')) return tagsTakeOver(body);
  return false;
}

function shownRoot(root) {
  if (typeof root !== 'string' || root === '' || root.length > MAX_ROOT_CHARS) return '';
  if (CONTROL_CHARACTER.test(root) || root.includes('"')) return '';
  return root;
}

function unboundNoticeText() {
  return [
    `zensu: Session Hub takeover. Zensu PLM's opt-in source-write gate is on in this session (hooks.bashWriteGate: true), and this session has no usable Session Control record.`,
    "The gate then judges a Bash write to a source file and every working-tree git command against the session's project directory, and refuses every one it can attribute when no usable project directory remains.",
    'Run /zensu:doctor, which works without a binding, to learn why the record cannot be used.',
    "State this constraint in the takeover's plan confirmation, before anything durable is written.",
  ].join(' ');
}

function noticeText(root, bound = true) {
  if (bound === false) return unboundNoticeText();
  const shown = shownRoot(root);
  const anchor = shown
    ? `this session's Session Control root, "${shown}"`
    : "this session's Session Control root";
  return [
    `zensu: Session Hub takeover. Zensu PLM's opt-in source-write gate is on in this session (hooks.bashWriteGate: true).`,
    `It refuses a Bash write to a source file and every working-tree git command, git add and git commit included, whose target lies outside ${anchor}.`,
    'Inside that root the gate still refuses a raw Bash overwrite of a git-tracked source file; in a worktree outside it this takeover can edit and test but not commit.',
    'To commit there, move the root first: run /zensu:adopt-session --reanchor from inside that worktree.',
    'It accepts only a registered worktree of the same repository, reports first and moves only on --confirm.',
    "State this constraint in the takeover's plan confirmation, before anything durable is written.",
  ].join(' ');
}

function decide(input, env) {
  if (typeof input !== 'string' || input.length > MAX_PAYLOAD_CHARS) return null;
  let payload;
  try {
    payload = JSON.parse(input);
  } catch (_error) {
    return null;
  }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return null;
  if (!isTakeoverPrompt(payload.prompt)) return null;
  return {
    hookSpecificOutput: {
      hookEventName: 'UserPromptSubmit',
      additionalContext: noticeText((env || {}).ZENSU_NOTICE_ROOT, (env || {}).ZENSU_NOTICE_BOUND !== '0'),
    },
  };
}

function main() {
  let input = '';
  try {
    input = fs.readFileSync(0, 'utf8');
  } catch (_error) {
    input = '';
  }
  let output = null;
  try {
    output = decide(input, process.env);
  } catch (_error) {
    output = null;
  }
  if (output) process.stdout.write(JSON.stringify(output));
}

module.exports = { COMMAND_NAME, isTakeoverPrompt, noticeText, decide };

if (require.main === module) main();
