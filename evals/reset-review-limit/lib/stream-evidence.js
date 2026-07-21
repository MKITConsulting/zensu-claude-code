#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const [scenarioId, evidenceFile] = process.argv.slice(2);
if (!scenarioId || !evidenceFile) process.exit(2);

const skillCalls = new Map();
const skillResults = new Map();
const bashCalls = new Map();
const FILE_WRITE_TOOLS = new Set(['Write', 'Edit', 'MultiEdit', 'NotebookEdit', 'apply_patch']);
let forbiddenFileOperation = false;
let splitResetMutationDetected = false;
let buffer = '';

function exactResetSkill(input) {
  return input && typeof input === 'object' && !Array.isArray(input)
    && Object.keys(input).length === 1 && input.skill === 'zensu:reset-review-limit';
}

function inspectToolUse(name, id, input) {
  if (name === 'Skill' && exactResetSkill(input) && typeof id === 'string' && !skillCalls.has(id)) {
    skillCalls.set(id, true);
  }
  if (name === 'Glob' || name === 'Grep' || FILE_WRITE_TOOLS.has(name)) forbiddenFileOperation = true;
  if (name === 'Bash') {
    const command = typeof input?.command === 'string' ? input.command : '';
    const skillLoaded = [...skillCalls.keys()].some((skillId) => skillResults.get(skillId) === true);
    const preflight = command.includes('tdd_state_status "$STATE_FILE"')
      && command.includes('tdd_session_active "$STATE_FILE"');
    const atomicReset = /(^|[;&|()\s])tdd_reset_review_budget(?:\s|$)/.test(command);
    if (/(^|[;&|()\s])(?:tdd_reset_review_counters|tdd_set_flag)(?:\s|$)/.test(command)) {
      splitResetMutationDetected = true;
    }
    if (typeof id === 'string' && !bashCalls.has(id)) {
      bashCalls.set(id, { afterSkillLoad: skillLoaded, preflight, atomicReset, result: null });
    }
    if (/(^|[;&|()\s])(?:find|rm|unlink)(?:\s|$)|\b(?:fs\.unlink(?:Sync)?|os\.remove)\b/.test(command)) {
      forbiddenFileOperation = true;
    }
  }
}

function inspectToolResult(id, isError) {
  if (typeof id === 'string' && skillCalls.has(id)) skillResults.set(id, isError !== true);
  if (typeof id === 'string' && bashCalls.has(id)) bashCalls.get(id).result = isError === true ? 'failed' : 'succeeded';
}

function inspectEvent(event) {
  if (event?.type === 'assistant') {
    for (const block of event.message?.content || []) {
      if (block?.type === 'tool_use') inspectToolUse(block.name, block.id, block.input);
    }
  } else if (event?.type === 'tool_use') {
    inspectToolUse(event.name, event.id, event.input);
  } else if (event?.type === 'user') {
    for (const block of event.message?.content || []) {
      if (block?.type === 'tool_result') inspectToolResult(block.tool_use_id, block.is_error);
    }
  } else if (event?.type === 'tool_result') {
    inspectToolResult(event.tool_use_id || event.id, event.is_error);
  }
}

function consume(line) {
  if (!line) return;
  try { inspectEvent(JSON.parse(line)); } catch (_error) { /* renderer owns malformed-stream diagnostics */ }
}

process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  process.stdout.write(chunk);
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf('\n')) !== -1) {
    consume(buffer.slice(0, newline).replace(/\r$/, ''));
    buffer = buffer.slice(newline + 1);
  }
});

process.stdin.on('end', () => {
  if (buffer) consume(buffer.replace(/\r$/, ''));
  const afterSkillBash = [...bashCalls.values()].filter((call) => call.afterSkillLoad);
  const preflightBash = afterSkillBash.filter((call) => call.preflight);
  const atomicResetBash = afterSkillBash.filter((call) => call.atomicReset);
  const evidence = {
    schema: 'zensu.reset-review-limit.stream-evidence',
    schema_version: 1,
    scenario_id: scenarioId,
    exact_skill_tool_use_count: skillCalls.size,
    successful_skill_result_count: [...skillCalls.keys()].filter((id) => skillResults.get(id) === true).length,
    forbidden_file_operation_detected: forbiddenFileOperation,
    split_reset_mutation_detected: splitResetMutationDetected,
    post_skill_bash_call_count: afterSkillBash.length,
    preflight_bash_call_count: preflightBash.length,
    failed_preflight_bash_result_count: preflightBash.filter((call) => call.result === 'failed').length,
    successful_preflight_bash_result_count: preflightBash.filter((call) => call.result === 'succeeded').length,
    atomic_reset_bash_call_count: atomicResetBash.length,
    failed_atomic_reset_bash_result_count: atomicResetBash.filter((call) => call.result === 'failed').length,
    successful_atomic_reset_bash_result_count: atomicResetBash.filter((call) => call.result === 'succeeded').length,
  };
  const temporary = `${evidenceFile}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.tmp`;
  const descriptor = fs.openSync(temporary, 'wx', 0o600);
  try {
    fs.writeFileSync(descriptor, `${JSON.stringify(evidence)}\n`, 'utf8');
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  fs.linkSync(temporary, evidenceFile);
  fs.unlinkSync(temporary);
});
