#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const core = require('./session-control-core-v1.js');
const principals = require('./claude-principal-v1.js');

const MAX_PAYLOAD_BYTES = 1024 * 1024;
const REVIEWER_READ_TOOLS = new Set(['Read', 'Grep', 'Glob']);
const SHELL_TOOLS = new Set(['Bash', 'shell', 'exec', 'exec_command', 'terminal', 'command']);
const SPAWN_OR_CONTROL_TOOLS = new Set([
  'Agent',
  'Task',
  'spawn_agent',
  'followup_task',
  'send_message',
  'Skill',
  'update_goal',
  'update_plan',
]);
const HOST_SAFE_TOOLS = new Set(['Read', 'Grep', 'Glob', 'Edit', 'Write', 'MultiEdit', 'NotebookEdit', 'apply_patch']);
const HASH_RE = /^sha256:[a-f0-9]{64}$/;
const CONTROL_TOKENS = [
  'ZENSU_CLAUDE_PLUGIN_ROOT',
  'ZENSU_SESSION_KEY',
  'ZENSU_SESSION_CONTEXT',
  'ZENSU_RUNTIME_DIGEST',
  'ZENSU_PROJECT_ROOT',
  'CLAUDE_PLUGIN_DATA',
  'main-v1',
  'session-control',
  'session_control',
  'zensu-log.sh',
  'tdd-phase-',
  'workflow-state',
  'render-main',
];

function deny(reason) {
  process.stdout.write(`${JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: `reviewer-capability-v1 deny: ${reason}`,
    },
  })}\n`);
}

function parsePayload() {
  const raw = fs.readFileSync(0);
  if (raw.length === 0 || raw.length > MAX_PAYLOAD_BYTES) {
    throw new Error('trusted hook payload is empty or too large');
  }
  const payload = JSON.parse(raw.toString('utf8'));
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    throw new Error('trusted hook payload must be an object');
  }
  if (payload.hook_event_name && payload.hook_event_name !== 'PreToolUse') {
    throw new Error('unexpected hook event');
  }
  if (typeof payload.tool_name !== 'string' || payload.tool_name.trim() === '') {
    throw new Error('tool name is unavailable');
  }
  if (
    typeof payload.session_id !== 'string'
    || payload.session_id.trim() === ''
    || payload.session_id.length > 4096
    || /[\0\r\n]/.test(payload.session_id)
  ) {
    throw new Error('session id is unavailable or unsafe');
  }
  if (typeof payload.cwd !== 'string' || payload.cwd.trim() === '' || /[\0\r\n]/.test(payload.cwd)) {
    throw new Error('tool cwd is unavailable or unsafe');
  }
  for (const field of ['agent_id', 'agent_type']) {
    if (
      Object.prototype.hasOwnProperty.call(payload, field)
      && (
        typeof payload[field] !== 'string'
        || payload[field].trim() === ''
        || payload[field].length > 512
        || /[\0\r\n]/.test(payload[field])
      )
    ) {
      throw new Error(`${field} is unsafe`);
    }
  }
  if (!payload.tool_input || typeof payload.tool_input !== 'object' || Array.isArray(payload.tool_input)) {
    payload.tool_input = {};
  }
  return payload;
}

function environmentText(name) {
  const value = process.env[name];
  if (typeof value !== 'string' || value.trim() === '' || /[\0\r\n]/.test(value)) {
    throw new Error(`${name} is missing or unsafe`);
  }
  return value;
}

function canonicalDirectory(value, label, rejectAlias = false) {
  if (typeof value !== 'string' || value.trim() === '' || /[\0\r\n]/.test(value)) {
    throw new Error(`${label} is missing or unsafe`);
  }
  const requested = path.resolve(value);
  let supplied;
  try {
    supplied = fs.lstatSync(requested);
  } catch {
    throw new Error(`${label} does not exist`);
  }
  if (supplied.isSymbolicLink() && rejectAlias) throw new Error(`${label} must not be a symlink`);
  let canonical;
  try {
    canonical = fs.realpathSync.native(requested);
  } catch {
    throw new Error(`${label} does not exist`);
  }
  const stat = fs.lstatSync(canonical);
  if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error(`${label} must be a real directory`);
  return canonical;
}

function contextFile(value, expected) {
  if (typeof value !== 'string' || value.trim() === '' || /[\0\r\n]/.test(value)) {
    throw new Error('ZENSU_SESSION_CONTEXT is missing or unsafe');
  }
  const requested = path.resolve(value);
  if (requested !== expected) throw new Error('session context path does not match session_id and plugin data');
  let stat;
  try {
    stat = fs.lstatSync(requested);
  } catch {
    throw new Error('session context record is missing');
  }
  if (stat.isSymbolicLink() || !stat.isFile() || stat.size > MAX_PAYLOAD_BYTES) {
    throw new Error('session context record is unsafe');
  }
  if (fs.realpathSync.native(requested) !== requested) {
    throw new Error('session context record is not canonical');
  }
  return requested;
}

function revalidateWorkflowState(options) {
  // SessionStart always creates one project-bound baseline CAS record. Validate
  // its existing path before calling the core reader so deletion can never
  // turn an armed or idle Session Control session into "never active".
  const zensuDirectory = path.join(options.projectRoot, '.zensu');
  const stateDirectory = path.join(zensuDirectory, 'state');
  for (const [candidate, label] of [
    [zensuDirectory, 'activated workflow root'],
    [stateDirectory, 'activated workflow state directory'],
  ]) {
    let stat;
    try {
      stat = fs.lstatSync(candidate);
    } catch {
      throw new Error(`${label} is missing`);
    }
    if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error(`${label} is unsafe`);
    if (fs.realpathSync.native(candidate) !== candidate) throw new Error(`${label} is not canonical`);
  }
  const stateFile = path.join(
    stateDirectory,
    `tdd-phase-${core.sessionKey(options.sessionId)}.json`,
  );
  let stateStat;
  try {
    stateStat = fs.lstatSync(stateFile);
  } catch {
    throw new Error('activated workflow CAS state is missing');
  }
  if (
    stateStat.isSymbolicLink()
    || !stateStat.isFile()
    || stateStat.nlink !== 1
    || stateStat.size > MAX_PAYLOAD_BYTES
  ) {
    throw new Error('activated workflow CAS state is unsafe');
  }
  core.readWorkflowState({
    projectRoot: options.projectRoot,
    sessionId: options.sessionId,
  });
}

function revalidateSessionContext(payload) {
  const executedPluginRoot = canonicalDirectory(path.resolve(__dirname, '..', '..'), 'executed plugin root');
  const hostPluginRoot = canonicalDirectory(environmentText('CLAUDE_PLUGIN_ROOT'), 'CLAUDE_PLUGIN_ROOT');
  const exportedPluginRoot = canonicalDirectory(
    environmentText('ZENSU_CLAUDE_PLUGIN_ROOT'),
    'ZENSU_CLAUDE_PLUGIN_ROOT',
  );
  if (hostPluginRoot !== executedPluginRoot || exportedPluginRoot !== executedPluginRoot) {
    throw new Error('plugin root does not match the executing installed plugin');
  }

  const pluginData = canonicalDirectory(environmentText('CLAUDE_PLUGIN_DATA'), 'CLAUDE_PLUGIN_DATA', true);
  const projectRoot = canonicalDirectory(environmentText('ZENSU_PROJECT_ROOT'), 'ZENSU_PROJECT_ROOT');
  const payloadProject = canonicalDirectory(payload.cwd, 'PreToolUse cwd');
  if (payloadProject !== projectRoot) throw new Error('tool project does not match the immutable session context');

  const sessionKey = core.sessionKey(payload.session_id);
  if (environmentText('ZENSU_SESSION_KEY') !== sessionKey) {
    throw new Error('session key does not match the PreToolUse session_id');
  }
  const recordsDir = path.join(pluginData, 'session-control', 'v1', 'records');
  const expectedContext = path.join(recordsDir, `${sessionKey}.json`);
  contextFile(environmentText('ZENSU_SESSION_CONTEXT'), expectedContext);

  const context = core.readContext({ recordsDir, sessionId: payload.session_id, expectedHost: 'claude' });
  if (context.plugin_root !== executedPluginRoot) throw new Error('context plugin root mismatch');
  if (context.plugin_data !== pluginData) throw new Error('context plugin data mismatch');
  if (context.project_root !== projectRoot) throw new Error('context project mismatch');
  const exportedDigest = environmentText('ZENSU_RUNTIME_DIGEST');
  if (!HASH_RE.test(exportedDigest) || exportedDigest !== context.runtime_digest) {
    throw new Error('exported runtime digest does not match the immutable context');
  }
  revalidateWorkflowState({
    recordsDir,
    sessionId: payload.session_id,
    projectRoot,
  });
  return {
    context,
    pluginRoot: executedPluginRoot,
    pluginData,
    projectRoot,
    contextFile: expectedContext,
  };
}

function inputStrings(input) {
  const strings = [];
  const pending = [input];
  let visited = 0;
  while (pending.length > 0) {
    const value = pending.pop();
    visited += 1;
    if (visited > 20000) throw new Error('tool input is too complex');
    if (typeof value === 'string') strings.push(value);
    else if (Array.isArray(value)) pending.push(...value);
    else if (value && typeof value === 'object') pending.push(...Object.values(value));
  }
  return strings;
}

function isInside(base, candidate) {
  const relative = path.relative(base, candidate);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function canonicalCandidate(projectRoot, value) {
  if (typeof value !== 'string' || value.trim() === '' || /[\0\r\n]/.test(value)) return null;
  const requested = path.resolve(projectRoot, value);
  let current = path.parse(requested).root;
  let pending = path.relative(current, requested).split(path.sep).filter(Boolean);
  let symlinkBudget = 40;
  while (pending.length > 0) {
    const segment = pending.shift();
    const candidate = path.join(current, segment);
    let info;
    try {
      info = fs.lstatSync(candidate);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      return path.resolve(candidate, ...pending);
    }
    if (info.isSymbolicLink()) {
      symlinkBudget -= 1;
      if (symlinkBudget < 0) throw new Error('tool path has too many symbolic links');
      const target = path.resolve(path.dirname(candidate), fs.readlinkSync(candidate));
      current = path.parse(target).root;
      pending = [
        ...path.relative(current, target).split(path.sep).filter(Boolean),
        ...pending,
      ];
      continue;
    }
    if (pending.length > 0 && !info.isDirectory()) {
      throw new Error('tool path traverses a non-directory component');
    }
    current = candidate;
  }
  return path.resolve(current);
}

function pathInputs(input) {
  const values = [];
  const pending = [input];
  let visited = 0;
  while (pending.length > 0) {
    const current = pending.pop();
    if (!current || typeof current !== 'object') continue;
    visited += 1;
    if (visited > 20000) throw new Error('tool path input is too complex');
    for (const [key, value] of Object.entries(current)) {
      if (/(?:^|_)(?:file_?path|path|paths|files|directory|root|cwd|workdir)$/i.test(key)) {
        if (typeof value === 'string') values.push(value);
        else if (Array.isArray(value)) values.push(...value.filter((entry) => typeof entry === 'string'));
      }
      if (Array.isArray(value)) pending.push(...value);
      else if (value && typeof value === 'object') pending.push(value);
    }
  }
  for (const value of inputStrings(input)) {
    for (const match of value.matchAll(/^\*\*\* (?:(?:Add|Update|Delete) File:|Move to:) (.+)$/gm)) {
      values.push(match[1]);
    }
  }
  return values;
}

function protectedAccessViolation(payload, trusted) {
  const directPaths = pathInputs(payload.tool_input);
  const candidates = directPaths.map((value) => canonicalCandidate(trusted.projectRoot, value));
  const protectedRoots = [
    trusted.contextFile,
    path.join(trusted.pluginData, 'session-control'),
    path.join(trusted.projectRoot, '.zensu'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'session-control-core-v1.js'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'claude-session-control-v1.js'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'reviewer-capability-v1.js'),
    path.join(trusted.pluginRoot, 'hooks', 'session-start-session-control.sh'),
  ].map((value) => path.resolve(value));

  if (candidates.some((candidate) => candidate && !isInside(trusted.projectRoot, candidate))) {
    return 'file access must remain inside the immutable project root';
  }

  if (candidates.some((candidate) => candidate && protectedRoots.some((root) => isInside(root, candidate)))) {
    return 'the requested path is protected Session Control or workflow state';
  }

  if (['Grep', 'Glob'].includes(payload.tool_name)) {
    if (candidates.length === 0) {
      return `${payload.tool_name} requires an explicit search root outside protected state`;
    }
    if (candidates.some((candidate) => protectedRoots.some((root) => isInside(candidate, root)))) {
      return `${payload.tool_name} search root contains protected Session Control or workflow state`;
    }
    const patternFields = ['pattern', 'glob', 'exclude', 'include'];
    for (const field of patternFields) {
      const value = payload.tool_input[field];
      const values = Array.isArray(value) ? value : [value];
      for (const pattern of values) {
        if (typeof pattern !== 'string') continue;
        const normalized = pattern.replaceAll('\\', '/');
        if (
          path.isAbsolute(pattern)
          || /(?:^|\/)\.\.(?:\/|$)/.test(normalized)
          || /(?:^|\/)\.zensu(?:\/|$)/.test(normalized)
          || normalized.includes('session-control')
        ) {
          return `${payload.tool_name} pattern may reach protected state`;
        }
      }
    }
  }
  return null;
}

function neutralViolation(payload, trusted) {
  if (SHELL_TOOLS.has(payload.tool_name)) {
    return 'host-profile-v1 cannot invoke shell or command-execution tools';
  }
  if (SPAWN_OR_CONTROL_TOOLS.has(payload.tool_name) || payload.tool_name.startsWith('mcp__')) {
    return 'host-profile-v1 cannot invoke agent, workflow-control, Skill, or MCP tools';
  }
  if (!HOST_SAFE_TOOLS.has(payload.tool_name)) {
    return `host-profile-v1 cannot invoke unapproved tool ${payload.tool_name}`;
  }

  const protectedPaths = [
    trusted.contextFile,
    path.join(trusted.pluginData, 'session-control'),
    path.join(trusted.projectRoot, '.zensu'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'session-control-core-v1.js'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'claude-session-control-v1.js'),
    path.join(trusted.pluginRoot, 'hooks', 'session-start-session-control.sh'),
  ].map((value) => value.replaceAll('\\', '/'));
  const strings = [payload.tool_name, ...inputStrings(payload.tool_input)];
  for (const original of strings) {
    const value = original.replaceAll('\\', '/');
    if (CONTROL_TOKENS.some((token) => value.includes(token))) {
      return 'host-profile-v1 cannot access Session Control, workflow-root state, or main-v1 identity';
    }
    if (/(?:^|\/)\.zensu(?:\/|$)/.test(value)) {
      return 'host-profile-v1 cannot access the workflow root';
    }
    if (protectedPaths.some((protectedPath) => value.includes(protectedPath))) {
      return 'host-profile-v1 cannot access a protected Session Control path';
    }
  }
  const pathViolation = protectedAccessViolation(payload, trusted);
  if (pathViolation) return pathViolation;
  return null;
}

function main() {
  let payload;
  try {
    payload = parsePayload();
  } catch (error) {
    deny(error.message);
    return;
  }

  let trusted;
  try {
    // SubagentStart cannot block tool execution. Therefore this first all-tool
    // hook revalidates every wrapper-exported field and the current runtime
    // digest before any principal-specific capability decision is considered.
    trusted = revalidateSessionContext(payload);
  } catch (error) {
    deny(`immutable context revalidation failed: ${error.message}`);
    return;
  }

  const principal = principals.classifyPreToolPayload(payload);
  if (principal === principals.PRINCIPALS.MAIN) return;
  if (principal === principals.PRINCIPALS.REVIEWER) {
    if (REVIEWER_READ_TOOLS.has(payload.tool_name)) {
      try {
        const violation = protectedAccessViolation(payload, trusted);
        if (violation) deny(`reviewer-readonly-v1 ${violation}`);
        else return;
      } catch (error) {
        deny(`reviewer-readonly-v1 path validation failed: ${error.message}`);
      }
      return;
    }
    deny(`reviewer-readonly-v1 cannot invoke ${payload.tool_name}; only Read, Grep, and Glob are allowed`);
    return;
  }
  try {
    const violation = neutralViolation(payload, trusted);
    if (violation) deny(violation);
  } catch (error) {
    deny(`host-profile-v1 input validation failed: ${error.message}`);
  }
}

main();
