#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const core = require('./session-control-core-v1.js');
const hostPaths = require('./claude-path-v1.js');
const principals = require('./claude-principal-v1.js');
const hookSession = require('./claude-hook-session-v1.js');
const evidenceLeases = require('./review-evidence-lease-v1.js');

const MAX_PAYLOAD_BYTES = 1024 * 1024;
const REVIEWER_READ_TOOLS = new Set(['Read', 'Grep', 'Glob']);
const COMMAND_TOOLS = new Set(['Bash', 'shell', 'exec', 'exec_command', 'terminal', 'command']);
const MUTATING_FILE_TOOLS = new Set([
  'Write',
  'Edit',
  'MultiEdit',
  'NotebookEdit',
  'apply_patch',
]);
const ZENSU_MCP_READ_RE = /^(?:list_|get_|search_|suggest_|view_|validate_|analyze_journey_health$|ghost_get_candidates$|pulse_(?:start_session|end_session|session_summary)$)/;

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
  if (payload.hook_event_name !== 'PreToolUse') {
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

function canonicalDirectory(value, label, rejectAlias = false) {
  if (typeof value !== 'string' || value.trim() === '' || /[\0\r\n]/.test(value)) {
    throw new Error(`${label} is missing or unsafe`);
  }
  const requested = path.resolve(hostPaths.normalizeHostPathInput(value, label));
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
  const binding = hookSession.resolveHookSession(payload);
  const projectRoot = canonicalDirectory(binding.projectRoot, 'context project root');
  const toolCwd = canonicalDirectory(payload.cwd, 'PreToolUse cwd');
  revalidateWorkflowState({
    sessionId: payload.session_id,
    projectRoot,
  });
  return {
    ...binding,
    projectRoot,
    toolCwd,
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

function isMultiplyLinkedFile(candidate) {
  let stat;
  try {
    stat = fs.lstatSync(candidate);
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
  return stat.isFile() && stat.nlink > 1;
}

function canonicalCandidate(projectRoot, value) {
  if (typeof value !== 'string' || value.trim() === '' || /[\0\r\n]/.test(value)) return null;
  const normalizedValue = hostPaths.normalizeHostPathInput(value, 'tool path');
  const requested = path.resolve(projectRoot, normalizedValue);
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
    // Preserve the filesystem's canonical spelling for every existing path
    // segment. On case-insensitive macOS/Windows filesystems, lstat accepts a
    // case-variant alias while path.relative remains string/case based; keeping
    // the requested spelling here would let that alias evade root comparisons.
    current = fs.realpathSync.native(candidate);
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

function traversalAccessViolation(payload, trusted, protectedRoots, candidates) {
  if (!['Grep', 'Glob'].includes(payload.tool_name)) return null;

  // Traversal tools can expose descendants while naming only an ancestor as
  // their input. Direct-target checks are therefore insufficient: a Grep at
  // the project root reaches .zensu, and a Glob at a plugin-data ancestor
  // reveals private records. When the host-default path is omitted, cwd is
  // the effective traversal root and must pass the same bidirectional check.
  const traversalRoots = candidates.length > 0 ? candidates : [trusted.toolCwd];
  if (traversalRoots.some((candidate) => candidate && protectedRoots.some((root) => (
    isInside(root, candidate) || isInside(candidate, root)
  )))) {
    return 'traversal root may reach protected Session Control or workflow state';
  }

  // Grep.pattern is a content regex and may legitimately mention protected
  // terminology. Only its path filters are traversal patterns. Glob.pattern
  // is itself a path pattern and must be checked alongside its aliases.
  const fields = payload.tool_name === 'Grep'
    ? ['glob', 'include', 'exclude']
    : ['pattern', 'glob', 'include', 'exclude'];
  for (const field of fields) {
    const raw = payload.tool_input[field];
    const patterns = Array.isArray(raw) ? raw : [raw];
    for (const pattern of patterns) {
      if (typeof pattern !== 'string') continue;
      const normalized = pattern.replaceAll('\\', '/');
      if (
        path.isAbsolute(pattern)
        || /(?:^|\/)\.\.(?:\/|$)/.test(normalized)
        || /(?:^|\/)\.zensu(?:\/|$)/.test(normalized)
      ) {
        return `${payload.tool_name} pattern may escape into protected state`;
      }
    }
  }
  return null;
}

function protectedAccessViolation(payload, trusted) {
  const directPaths = pathInputs(payload.tool_input);
  const candidates = directPaths.map((value) => canonicalCandidate(trusted.toolCwd, value));
  const protectedRoots = [
    trusted.contextFile,
    path.join(trusted.pluginData, 'session-control'),
    path.join(trusted.pluginData, 'review-evidence'),
    path.join(trusted.projectRoot, '.zensu'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'session-control-core-v1.js'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'claude-session-control-v1.js'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'claude-hook-session-v1.js'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'reviewer-capability-v1.js'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'review-evidence-lease-v1.js'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'review-evidence-hook-v1.js'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'zensu-review-evidence.sh'),
    path.join(trusted.pluginRoot, 'hooks', 'review-evidence-subagent-start.sh'),
    path.join(trusted.pluginRoot, 'hooks', 'review-evidence-subagent-stop.sh'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'zensu-session.sh'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'zensu-log.sh'),
    path.join(trusted.pluginRoot, 'hooks', 'session-start-session-control.sh'),
  ].map((value) => path.resolve(value));

  if (candidates.some((candidate) => candidate && !isInside(trusted.projectRoot, candidate))) {
    return 'file access must remain inside the immutable project root';
  }

  if (candidates.some((candidate) => candidate && protectedRoots.some((root) => isInside(root, candidate)))) {
    return 'the requested path is protected Session Control or workflow state';
  }

  const traversalViolation = traversalAccessViolation(
    payload, trusted, protectedRoots, candidates,
  );
  if (traversalViolation) return traversalViolation;
  return null;
}

function neutralViolation(payload, trusted) {
  // A shell is an arbitrary-code capability. Inspecting its source text for
  // protected words cannot establish confinement: environment enumeration,
  // variables, substitutions, aliases, or an interpreter can reconstruct any
  // selector/path after PreToolUse. Neutral children therefore receive no
  // command-execution tool at all. Main remains unchanged, while exact
  // reviewer/PLM identities are already restricted to Read/Grep/Glob above.
  if (COMMAND_TOOLS.has(payload.tool_name)) {
    return 'host-profile-v1 cannot invoke command-execution tools';
  }

  const zensuMcpTool = /^mcp__.*zensu/i.test(payload.tool_name)
    ? payload.tool_name.split('__').at(-1)
    : null;
  if (zensuMcpTool && !ZENSU_MCP_READ_RE.test(zensuMcpTool)) {
    return 'host-profile-v1 cannot invoke mutating Zensu MCP tools';
  }

  const protectedRoots = [
    trusted.contextFile,
    path.join(trusted.pluginData, 'session-control'),
    path.join(trusted.pluginData, 'review-evidence'),
    path.join(trusted.projectRoot, '.zensu'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'session-control-core-v1.js'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'claude-session-control-v1.js'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'claude-hook-session-v1.js'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'reviewer-capability-v1.js'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'review-evidence-lease-v1.js'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'review-evidence-hook-v1.js'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'zensu-review-evidence.sh'),
    path.join(trusted.pluginRoot, 'hooks', 'review-evidence-subagent-start.sh'),
    path.join(trusted.pluginRoot, 'hooks', 'review-evidence-subagent-stop.sh'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'zensu-session.sh'),
    path.join(trusted.pluginRoot, 'hooks', 'session-start-session-control.sh'),
    path.join(trusted.pluginRoot, 'hooks', 'pre-reviewer-capability-gate.sh'),
    path.join(trusted.pluginRoot, 'hooks', 'lib', 'zensu-log.sh'),
  ].map((value) => path.resolve(value));
  const candidates = pathInputs(payload.tool_input)
    .map((value) => canonicalCandidate(trusted.toolCwd, value));

  // Neutral children may write project files and external review reports, but
  // the installed plugin and its private data store are authorities for future
  // capability decisions. Protect both canonical trees from every standard
  // file-mutation tool. canonicalCandidate resolves existing and dangling
  // symlink aliases before this comparison, so a project-local alias cannot be
  // used to persist modified runtime bytes or a forged next-session record.
  const immutableRuntimeRoots = [trusted.pluginRoot, trusted.pluginData]
    .map((value) => path.resolve(value));
  if (
    MUTATING_FILE_TOOLS.has(payload.tool_name)
    && candidates.some((candidate) => candidate
      && immutableRuntimeRoots.some((root) => isInside(root, candidate)))
  ) {
    return 'host-profile-v1 cannot mutate the installed plugin runtime or private plugin data';
  }

  // realpath cannot distinguish hard links. A project-local hard link can
  // therefore name the same inode as a plugin-runtime file without living
  // below pluginRoot. Standard mutation tools must fail closed for every
  // existing multiply-linked file; ordinary nlink=1 project/report files and
  // new files keep their normal host semantics.
  if (
    MUTATING_FILE_TOOLS.has(payload.tool_name)
    && candidates.some((candidate) => candidate && isMultiplyLinkedFile(candidate))
  ) {
    return 'host-profile-v1 cannot mutate multiply linked files';
  }

  if (candidates.some((candidate) => candidate
      && protectedRoots.some((root) => isInside(root, candidate)))) {
    return 'host-profile-v1 cannot access a protected Session Control path';
  }

  const traversalViolation = traversalAccessViolation(
    payload, trusted, protectedRoots, candidates,
  );
  if (traversalViolation) return `host-profile-v1 ${traversalViolation}`;
  return null;
}

function readOnlyViolation(payload, trusted, profile) {
  if (!REVIEWER_READ_TOOLS.has(payload.tool_name)) {
    return `${profile} cannot invoke ${payload.tool_name}; only Read, Grep, and Glob are allowed`;
  }
  const violation = protectedAccessViolation(payload, trusted);
  return violation ? `${profile} ${violation}` : null;
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
  if (principal === principals.PRINCIPALS.EVIDENCE_WORKER) {
    try {
      const violation = evidenceLeases.toolViolation(payload, trusted);
      if (violation) {
        deny(violation.startsWith('evidence-worker-v1')
          ? violation : `evidence-worker-v1 ${violation}`);
      }
    } catch (error) {
      deny(`evidence-worker-v1 validation failed: ${error.message}`);
    }
    return;
  }
  if (principal === principals.PRINCIPALS.REVIEWER) {
    try {
      const violation = readOnlyViolation(payload, trusted, 'reviewer-readonly-v1');
      if (violation) deny(violation);
    } catch (error) {
      deny(`reviewer-readonly-v1 path validation failed: ${error.message}`);
    }
    return;
  }
  if (principals.PLM_TYPES.has(payload.agent_type)) {
    try {
      const violation = readOnlyViolation(payload, trusted, 'zensu-plm-readonly-v1');
      if (violation) deny(violation);
    } catch (error) {
      deny(`zensu-plm-readonly-v1 path validation failed: ${error.message}`);
    }
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
