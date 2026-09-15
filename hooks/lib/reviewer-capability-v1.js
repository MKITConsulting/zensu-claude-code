#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const core = require('./session-control-core-v1.js');
const hostPaths = require('./claude-path-v1.js');
const principals = require('./claude-principal-v1.js');
const hookSession = require('./claude-hook-session-v1.js');
const evidenceLeases = require('./review-evidence-lease-v1.js');
const doctorInvocation = require('./zensu-doctor-invocation.js');

// The FOURTH consumer of the `recorded`/`executing` pair, and the one outside the
// shell family that shares a degradation policy. `zensu_emit_hook_session_deny`,
// stop-chain-enforcer.sh and zensu-doctor.sh all hold the pair to a shape before
// printing it, because a plugin_version is only requireText-validated: a newline
// in it splits one deny reason into several that read as separate hook messages.
// The same alternation, the same `(unreadable)` substitution.
const SAFE_VERSION = /^[0-9A-Za-z][0-9A-Za-z.+-]{0,63}$/;
const safeVersion = (value) => (
  typeof value === 'string' && SAFE_VERSION.test(value) ? value : '(unreadable)'
);

// The refusal token of a failed automatic adoption reaches the deny reason the
// same way the version pair does, so it is held to the token grammar the binder
// produces (ZENSU_SAFE_REFUSAL_RE in zensu-session.sh is the shell twin).
const SAFE_REFUSAL = /^[a-z][a-z0-9-]{0,63}$/;
const safeRefusal = (value) => (
  typeof value === 'string' && SAFE_REFUSAL.test(value) ? value : '(unknown)'
);

// HAND COPY of `_zensu_adoption_refusal_remedy` in hooks/lib/zensu-session.sh —
// the shell emitter cannot be reached from JS and this gate spells its own deny.
// Keep the two in step sentence for sentence; a reason missing here gets the
// generic remedy, never a wrong one.
const ADOPTION_REFUSAL_REMEDIES = Object.freeze({
  'executing-runtime-older': 'The running installation is OLDER than the one that minted the record (a downgrade or a --plugin-dir checkout), so re-install the newer version, or start a fresh Claude Code session on this one',
  'workflow-schema-mismatch': 'The persisted workflow shape really did change between the two versions, so a fresh Claude Code session is the only way forward',
  'not-a-sibling-installation': 'The running installation is not a sibling of the recorded one (for example a --plugin-dir checkout beside an installed plugin), so a fresh Claude Code session on this installation is the way forward',
  'plugin-data-mismatch': 'The record belongs to a different plugin data store than this installation uses, so a fresh Claude Code session is the way forward',
  'record-unreadable': 'The record disagrees with the running installation for a reason adoption does not admit; run /zensu:doctor, which names the check that failed',
  'executing-runtime-unidentified': 'The running installation declares no usable version, so repair the plugin installation first',
  'opted-out': 'hooks.sessionAutoAdopt is false in your Zensu config, so run /zensu:adopt-session --confirm yourself; the manual path ignores the opt-out',
  'adopted-concurrently': 'A sibling hook adopted the record in the meantime and it serves now, so simply retry this call',
  'not-completed': 'The adoption did not complete (a lock timeout, or a superseded record left by an interrupted adoption), so retry this call; if it persists, /zensu:adopt-session prints the full report',
  'lock-timeout': 'The adoption did not complete (a lock timeout, or a superseded record left by an interrupted adoption), so retry this call; if it persists, /zensu:adopt-session prints the full report',
  'superseded-record-exists': 'A superseded record from an interrupted adoption is already in place; /zensu:adopt-session names the file, and moving it aside lets the adoption complete',
});
const GENERIC_ADOPTION_REMEDY = 'Run /zensu:adopt-session for the full report, and /zensu:adopt-session --confirm to retry the adoption by hand';
const adoptionRefusalRemedy = (reason) => (
  Object.prototype.hasOwnProperty.call(ADOPTION_REFUSAL_REMEDIES, reason)
    ? ADOPTION_REFUSAL_REMEDIES[reason]
    : GENERIC_ADOPTION_REMEDY
);

// The user-facing announcement of an adoption THIS process performed. One JSON
// object on the allow path carrying no permissionDecision, so the host's
// deny > defer > ask > allow precedence is untouched: `additionalContext` is the
// documented PreToolUse field, `systemMessage` the user-facing common field.
// The superseded record is named by its basename — `<key>.superseded-<ver>.json`,
// both parts shape-checked by the core — never by its absolute path.
// Provenance is one of `recorded`, `no-workflow-document` or `unavailable: <why>`;
// the third carries an error message, so it is bounded to a printable class
// rather than trusted into the notice verbatim.
const SAFE_PROVENANCE = /^[A-Za-z0-9 .,:;_()'/-]{1,200}$/;
const safeProvenance = (value) => (
  typeof value === 'string' && SAFE_PROVENANCE.test(value) ? value : '(unrenderable)'
);

function adoptionNotice(adoption) {
  const leases = adoption.leases && Number.isInteger(adoption.leases.discarded) ? adoption.leases.discarded : 0;
  const kept = typeof adoption.supersededFile === 'string' ? path.basename(adoption.supersededFile) : '(unknown)';
  const orphan = adoption.orphanedProjectRoot
    ? ' The recorded project root is still gone, so Edit, Write, MultiEdit and any writing Bash command stay denied until that exact directory is re-created.'
    : '';
  return `zensu: the Zensu plugin was updated from ${safeVersion(adoption.recorded)} to ${safeVersion(adoption.executing)} while this session was running; its Session Control record was adopted automatically on this tool call (previous record kept beside it as ${kept}; provenance ${safeProvenance(adoption.provenance)}; ${leases} review-evidence lease(s) from before the update set aside, so a review that was in flight must be re-gathered).${orphan} /zensu:doctor shows the details; nothing else to do.`;
}

function announceAdoption(adoption) {
  const text = adoptionNotice(adoption);
  process.stdout.write(`${JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      additionalContext: text,
    },
    systemMessage: text,
  })}\n`);
}

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

// The ONE cause in this file that has an in-place remedy, tagged rather than
// matched by message text. A deny that names a remedy is worth having only if it
// names it for the right cause, and a substring test against prose is how that
// claim goes quietly wrong on the next reword.
//
// Tagged ONLY for a clean ENOENT. `is unsafe` and `is not canonical` are tamper
// shapes and stay on the generic wording: something is sitting at that path, and
// offering a rebuild there would tell the user to build over the evidence.
const BASELINE_MISSING_CODE = 'ZENSU_WORKFLOW_BASELINE_MISSING';

function baselineMissing(message) {
  const error = new Error(message);
  error.code = BASELINE_MISSING_CODE;
  return error;
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
    } catch (error) {
      // A clean ENOENT is the repairable shape: the repair's own
      // initializeWorkflowState creates these components. Every other errno is
      // NOT absence and keeps the generic wording.
      if (error && error.code === 'ENOENT') throw baselineMissing(`${label} is missing`);
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
  } catch (error) {
    if (error && error.code === 'ENOENT') {
      throw baselineMissing('activated workflow CAS state is missing');
    }
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
  // Opts into the automatic adoption: a record the version numbers refuse but
  // adoptableRecord admits is re-minted by the binder before the strict re-read,
  // and `binding.adoption` (spread into the trusted context below) carries the
  // verdict so the allow path can announce it once.
  const binding = hookSession.resolveHookSession(payload, process.env, { autoAdopt: true });
  const projectRoot = canonicalDirectory(binding.projectRoot, 'context project root');
  revalidateWorkflowState({
    sessionId: payload.session_id,
    projectRoot,
  });
  return {
    ...binding,
    projectRoot,
  };
}

function pathResolutionProfile(payload, principal) {
  if (principal === principals.PRINCIPALS.REVIEWER) return 'reviewer-readonly-v1';
  if (principals.PLM_TYPES.has(payload.agent_type)) return 'zensu-plm-readonly-v1';
  return 'host-profile-v1';
}

function unusableWorkingDirectoryReason(profile, error) {
  return `${profile} cannot resolve tool paths: this session's working directory no longer `
    + `names a usable directory (${error.message}). A git worktree removed while the session `
    + `was still inside it is one way to reach this state. The Session Control binding itself `
    + `is intact, and this check does not apply to the main thread, which resolves no tool `
    + `path against that directory. Report this to the main thread — which can re-create the `
    + `directory or move the session to one that exists — rather than retrying.`;
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
    // Two states are not capability violations, and this hook runs on matcher
    // ".*" — so if it denies, it denies EVERY tool, /zensu:doctor included, and
    // the relaxation the Bash gate grants would never be reached.
    //
    // A session Session Control never registered is the 0.17.0 upgrade state:
    // that release introduced the record, and a resume/compact SessionStart
    // requires one it never mints. A session whose recorded project root no
    // longer exists is the deleted-or-recycled-worktree state: the record is
    // intact, the directory it names is gone, and with it the workflow document
    // that lived inside it. Neither can prove anything by denying, and denying
    // leaves no way to run /zensu:doctor and read why, so the main thread —
    // which the MAIN branch below returns unrestricted anyway — keeps exactly
    // the capabilities it had before Session Control existed.
    //
    // Every other principal stays fail-closed in both states: a reviewer or
    // worker that cannot prove its lease must not run. So does a record that
    // EXISTS and disagrees about anything else, which is a security signal that
    // keeps denying for everyone, main thread included.
    // The recognized commands are the third case, and unlike the two above they
    // are NOT a relaxable-state question: they hold in EVERY bind failure,
    // including a record that exists and disagrees. That is the state a
    // mid-session plugin upgrade produces, and denying it here put /zensu:doctor
    // behind the very defect it reports — this gate matches every tool, so a deny
    // here is reached before the Bash gates ever run. It admits exactly two
    // recognized commands for the main thread: hooks/lib/zensu-doctor.sh, which
    // writes nothing, and hooks/lib/zensu-session-adopt.sh, which writes its own
    // session's record, one workflow history entry, a move of its own stale
    // review-evidence leases, and — with --confirm on an already-served refusal
    // only — its own missing workflow document plus that document's .zensu
    // ancestors in the recorded project (`.zensu` and not `.zensu/state`: the mkdir
    // creates BOTH components, and `.zensu` is not inside `.zensu/state` — the adopt
    // header makes that argument and two carriers still spelled the narrower one),
    // and carries its own justification in its
    // header. A
    // remedy the user cannot invoke is not a remedy.
    //
    // This gate is the FIFTH denier in the incompatible-runtime state, and the
    // only one that does NOT route through `zensu_emit_hook_session_deny` —
    // `isRecognizedInvocation` is false for every non-Bash tool, so an Edit
    // reaches the catch below. It spells the same lineage cause itself there.
    if (principals.classifyPreToolPayload(payload) === principals.PRINCIPALS.MAIN
        && (hookSession.unregisteredSession(payload)
          || hookSession.orphanedProjectRootSession(payload)
          || doctorInvocation.isRecognizedInvocation(payload))) {
      return;
    }
    // The binder ADOPTS before it denies now, so a typed refusal here means the
    // automatic adoption itself was refused, opted out, or did not complete —
    // and the verdict travels on the error, so no second probe re-derives it.
    // The CAUSE is for everyone; the REMEDY is MAIN-only, for the reason the
    // fallback arm below states.
    if (core.isAdoptionRefusal(error) && error.adoption && typeof error.adoption === 'object') {
      const adoption = error.adoption;
      const reason = safeRefusal(adoption.reason);
      const recorded = safeVersion(adoption.recorded);
      const executing = safeVersion(adoption.executing);
      // The same two causes the shell scopes spell, chosen by the reader that
      // answered: a pruned minting installation is its own named state, and the
      // downgrade sentence stays with it because that predicate is blind to lineage.
      const cause = adoption.prunedPluginRoot
        ? `this session's Session Control record is intact, but the Zensu installation that minted it (version ${recorded}) has been removed from the plugin cache, so the running installation (${executing}) cannot re-verify the record. Zensu tried to adopt the record automatically for this session and it was REFUSED: ${reason}.`
        : `this session's Session Control record is readable, and the running Zensu installation declares an incompatible lineage — the record was minted by ${recorded} and ${executing} is executing. Zensu tried to adopt the record automatically for this session and it was REFUSED: ${reason}.`;
      if (principals.classifyPreToolPayload(payload) === principals.PRINCIPALS.MAIN) {
        const tail = adoption.prunedPluginRoot
          ? 'This predicate is deliberately blind to lineage, so a DOWNGRADE reaches this state too, and there adoption refuses as executing-runtime-older and re-installing the newer version is the way back.'
          : 'If the recorded project root is ALSO gone — a deleted or recycled worktree — an adoption still clears the lineage break, but Edit, Write and MultiEdit stay denied afterwards, and so does any Bash command the source-write gate can attribute as a write, until that exact directory is re-created; /zensu:doctor names the path when that is the case.';
        deny(`${cause} ${adoptionRefusalRemedy(reason)}. /zensu:adopt-session reports the same refusal in full, and /zensu:adopt-session --confirm retries the adoption by hand; both stay reachable in this state. ${tail}`);
        return;
      }
      deny(`${cause} The repair writes the immutable record and is reserved for the main thread, so it is not available here — report this to the main thread rather than retrying.`);
      return;
    }
    // The FIFTH denier in the incompatible-runtime state, and it used to be the
    // only one left on generic wording — an Edit produced "revalidation failed"
    // here while the Edit gate said the session could be repaired in place. Two
    // denies contradicting each other about the one bind failure that HAS an
    // in-place remedy is exactly what CLAUDE.md forbids, so this branch names the
    // same cause and remedy the four gates emitting the shell scope do.
    //
    // The predicate matches TWO states — with and without a vanished recorded
    // project root — and this gate is on the `.*` matcher, so an Edit lands here:
    // precisely the tool that stays denied after the adoption. The limit is
    // therefore stated the same way the shell scope states it, as a conditional
    // clause true in both halves. Offering the repair without it is the defect,
    // not the nicety; this branch shipped without it for one round.
    // The CAUSE is for everyone; only the REMEDY is MAIN-only. Two separate
    // decisions, and collapsing them was a real regression this branch shipped for
    // one review round.
    //
    // The remedy half: `/zensu:adopt-session --confirm` WRITES the immutable record,
    // and `zensu_doctor_allowed` conjoins `zensu_hook_is_main_principal` — so a
    // reviewer, an evidence worker or any neutral child that reached this catch
    // would be handed a command every gate refuses it. Deny text is model-read
    // content: pointing a read-only principal at a privileged write is the shape
    // this repo treats as a defect, not a nicety.
    //
    // The cause half: withholding the diagnosis TOO dropped a non-main principal
    // back to `immutable context revalidation failed`, which names neither the
    // lineage break nor either version — a cause-free deny in the one bind failure
    // that has a name and an in-place repair. `safeVersion` already renders the
    // pair safely for any principal, so there was never a reason to hide it. A
    // constrained child is told what happened and who can fix it.
    const lineage = hookSession.resolveIncompatibleRuntime(payload);
    if (lineage) {
      const cause = `this session's Session Control record is readable, and the running Zensu installation declares an incompatible lineage — the record was minted by ${safeVersion(lineage.recorded)} and ${safeVersion(lineage.executing)} is executing.`;
      if (principals.classifyPreToolPayload(payload) === principals.PRINCIPALS.MAIN) {
        deny(`${cause} Zensu adopts such a record automatically on the first hook contact; that did not bind this session, so run /zensu:adopt-session for the full report and /zensu:adopt-session --confirm to retry the adoption by hand; both stay reachable in this state. If the recorded project root is ALSO gone — a deleted or recycled worktree — an adoption still clears the lineage break, but Edit, Write and MultiEdit stay denied afterwards, and so does any Bash command the source-write gate can attribute as a write, until that exact directory is re-created; /zensu:doctor names the path when that is the case.`);
        return;
      }
      deny(`${cause} The repair writes the immutable record and is reserved for the main thread, so it is not available here — report this to the main thread rather than retrying.`);
      return;
    }
    // The other named state with the same in-place remedy, and the FIFTH denier
    // for it — the same five as the lineage state above, counted the same way:
    // the four emitting gates plus this one. The installation that minted the
    // record was pruned from the plugin cache. Disjoint from the lineage question above, so the order of
    // the two is immaterial.
    const pruned = hookSession.resolvePrunedPluginRoot(payload);
    if (pruned) {
      deny(`this session's Session Control record is intact, but the Zensu installation that minted it (version ${pruned.recorded}) has been removed from the plugin cache, so the running installation (${pruned.executing}) cannot re-verify the record. Zensu adopts such a record automatically on the first hook contact; that did not bind this session, so run /zensu:adopt-session for the full report and /zensu:adopt-session --confirm to retry the adoption by hand; both stay reachable in this state. The refusal names its own cause and remedy: this predicate is deliberately blind to lineage, so a DOWNGRADE reaches this state too, and there adoption refuses as executing-runtime-older and re-installing the newer version is the way back — a persisted shape that really did change is the case that needs a fresh Claude Code session.`);
      return;
    }
    // The SECOND named cause, and the second one with an in-place remedy. It sits
    // below the lineage branch deliberately: the two are mutually exclusive in
    // practice — a lineage break throws inside resolveHookSession, before this
    // file ever reaches the workflow document — and where they are not, adoption
    // is the correct remedy, because the repair below requires a SERVED record.
    //
    // The generic wording is what this branch removes. "immutable context
    // revalidation failed: activated workflow CAS state is missing" is accurate
    // and names no way out, in a state where this hook denies every tool and the
    // only reachable commands are the two the Bash recognizer admits.
    if (error && error.code === BASELINE_MISSING_CODE) {
      // The reachability clause is PLATFORM-QUALIFIED on purpose. zensu-doctor-invocation.js
      // sets PLATFORM_SUPPORTED = process.platform !== "win32" and gates both recognizers on
      // it, so on win32 the Bash recognizer admits NEITHER command and an unconditional
      // "both stay reachable" is false in the one state where a wrong remedy has no fallback.
      deny("this session's Session Control record is intact and served by the running Zensu installation, but the workflow document it anchors is missing — a deleted and re-created worktree loses it, because .zensu/state/ is gitignored. It is NOT read as \"no chain was ever active\": that is why every tool is denied. Run /zensu:adopt-session to see the diagnosis, and /zensu:adopt-session --confirm to rebuild the document. On macOS and Linux both stay reachable in this state; on Windows the Bash recognizer admits neither, so start a fresh Claude Code session instead. Rebuilding is a loss, not a restore — a review chain that was live when the document vanished is gone.");
      return;
    }
    deny(`immutable context revalidation failed: ${error.message}`);
    return;
  }

  const principal = principals.classifyPreToolPayload(payload);
  if (principal === principals.PRINCIPALS.MAIN) {
    // Announce only an adoption THIS process performed: `trusted.adoption` is
    // set by the binder for the one invocation that won the records lock, so a
    // concurrent sibling gate never repeats the line. Main thread only — a
    // confined child's context is not where a session-level notice belongs.
    if (trusted.adoption) announceAdoption(trusted.adoption);
    return;
  }
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
  try {
    trusted = { ...trusted, toolCwd: canonicalDirectory(payload.cwd, 'PreToolUse cwd') };
  } catch (error) {
    deny(unusableWorkingDirectoryReason(pathResolutionProfile(payload, principal), error));
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
