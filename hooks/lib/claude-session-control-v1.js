#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const core = require('./session-control-core-v1.js');
const hostPaths = require('./claude-path-v1.js');
const principals = require('./claude-principal-v1.js');

const MAX_PAYLOAD_BYTES = 1024 * 1024;
const MAX_SESSION_SOURCE_LENGTH = 64;
// The host's own SessionStart sources are startup, clear, fork, resume and
// compact. Only the fresh ones are named: `fork` mints a NEW host session id
// for a copied conversation, so it can only ever arrive without a record.
// Everything unnamed — the continuations, plus any source the host adds after
// this build — registers a fresh record when none exists and reuses the
// existing one otherwise, because refusing an unknown source leaves the whole
// session unbindable rather than merely ungated.
const FRESH_SESSION_SOURCES = new Set(['startup', 'clear', 'fork']);

function fail(message) {
  throw new Error(`claude session-control adapter: ${message}`);
}

function readPayload() {
  const raw = fs.readFileSync(0);
  if (raw.length === 0 || raw.length > MAX_PAYLOAD_BYTES) fail('hook payload is empty or too large');
  let payload;
  try {
    payload = JSON.parse(raw.toString('utf8'));
  } catch {
    fail('hook payload is invalid JSON');
  }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) fail('hook payload must be an object');
  if (!['SessionStart', 'SubagentStart'].includes(payload.hook_event_name)) fail('unsupported hook event');
  if (
    typeof payload.session_id !== 'string'
    || payload.session_id.trim() === ''
    || payload.session_id.length > 4096
    || /[\0\r\n]/.test(payload.session_id)
  ) {
    fail('session id is unavailable or unsafe');
  }
  if (/^(?:scv1_[a-f0-9]{64}|sha256:[a-f0-9]{64})$/.test(payload.session_id)) {
    fail('host session id must be raw, not a derived Session Control identifier');
  }
  if (payload.hook_event_name === 'SessionStart' && !isUsableSessionSource(payload.source)) {
    fail('SessionStart source is unavailable or unsupported');
  }
  return payload;
}

function isUsableSessionSource(source) {
  return typeof source === 'string'
    && source.trim() !== ''
    && source.length <= MAX_SESSION_SOURCE_LENGTH
    && !/[\0\r\n]/.test(source);
}

function canonicalDirectory(value, label, rejectAlias = false) {
  if (typeof value !== 'string' || value.trim() === '' || /[\0\r\n]/.test(value)) fail(`${label} is unsafe`);
  const normalizedValue = hostPaths.normalizeHostPathInput(value, label);
  if (rejectAlias) {
    let supplied;
    try {
      supplied = fs.lstatSync(path.resolve(normalizedValue));
    } catch {
      fail(`${label} does not exist`);
    }
    if (supplied.isSymbolicLink()) fail(`${label} must not be a symlink`);
  }
  let canonical;
  try {
    canonical = fs.realpathSync.native(normalizedValue);
  } catch {
    fail(`${label} does not exist`);
  }
  const stat = fs.lstatSync(canonical);
  if (stat.isSymbolicLink() || !stat.isDirectory()) fail(`${label} must be a real directory`);
  return canonical;
}

function ensurePrivatePath(baseInput, segments) {
  let current = canonicalDirectory(baseInput, 'private path base', true);
  for (const segment of segments) {
    current = path.join(current, segment);
    if (!fs.existsSync(current)) {
      try {
        fs.mkdirSync(current, { mode: 0o700 });
      } catch (error) {
        // Another cold start may have created the same private generation after
        // existsSync(). Validate that winner below instead of treating EEXIST
        // as a startup failure.
        if (error.code !== 'EEXIST') throw error;
      }
    }
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink() || !stat.isDirectory()) fail('private control path is unsafe');
    if (process.platform !== 'win32') {
      fs.chmodSync(current, 0o700);
      if ((fs.lstatSync(current).mode & 0o077) !== 0) fail('private control path permissions are unsafe');
    }
  }
  return current;
}

function authoritativePluginRoot() {
  const root = canonicalDirectory(path.resolve(__dirname, '..', '..'), 'executed plugin root');
  for (const variable of ['CLAUDE_PLUGIN_ROOT', 'PLUGIN_ROOT', 'ZENSU_PLUGIN_ROOT']) {
    if (!process.env[variable]) continue;
    if (canonicalDirectory(process.env[variable], variable) !== root) {
      fail(`${variable} does not match the executed plugin installation`);
    }
  }
  return root;
}

function hookOutput(event, additionalContext) {
  return {
    hookSpecificOutput: {
      hookEventName: event,
      additionalContext,
    },
  };
}

function rejectSourceRevisionOverride() {
  for (const variable of ['ZENSU_SOURCE_REVISION', 'ZENSU_SOURCE_REVISION_AUTHORITY']) {
    if (process.env[variable] !== undefined) {
      fail(`${variable} is unsupported; session source provenance is content-addressed`);
    }
  }
}

function main() {
  const payload = readPayload();
  // SessionStart also carries agent_type for top-level `claude --agent`
  // sessions. Use the same trusted-payload classifier as PreToolUse so only a
  // host session with neither agent field receives main-v1. Exact reviewers
  // stay read-only and every other explicit or partial identity stays neutral.
  const principal = payload.hook_event_name === 'SubagentStart'
    ? principals.classifySubagent(payload.agent_type, payload.agent_id)
    : principals.classifyPreToolPayload(payload);
  const pluginRoot = authoritativePluginRoot();
  rejectSourceRevisionOverride();
  const pluginData = canonicalDirectory(process.env.CLAUDE_PLUGIN_DATA, 'CLAUDE_PLUGIN_DATA', true);
  const controlRoot = ensurePrivatePath(pluginData, ['session-control', 'v1']);
  const recordsDir = ensurePrivatePath(controlRoot, ['records']);
  ensurePrivatePath(controlRoot, ['locks']);

  let context;
  if (payload.hook_event_name === 'SessionStart') {
    const key = core.sessionKey(payload.session_id);
    const recordFile = path.join(recordsDir, `${key}.json`);
    const eventCwd = canonicalDirectory(payload.cwd, 'SessionStart cwd');
    const isFresh = FRESH_SESSION_SOURCES.has(payload.source);
    if (fs.existsSync(recordFile)) {
      // Resume/compact occurs after CwdChanged and may report a descendant or
      // external detached-worktree cwd. Reuse the immutable record anchor;
      // cwd is host location metadata and must never become a rebind request.
      // Only a known-fresh source must still land in the recorded project: an
      // unknown one may well be a continuation the host added after this build.
      context = core.readContext({
        recordsDir,
        sessionId: payload.session_id,
        expectedHost: 'claude',
      });
      if (context.plugin_root !== pluginRoot) fail('SessionStart plugin root does not match the existing session');
      if (context.plugin_data !== pluginData) fail('SessionStart plugin data does not match the existing session');
      if (isFresh && eventCwd !== context.project_root) {
        fail('fresh SessionStart cwd does not match the existing session project');
      }
      core.readWorkflowState({
        projectRoot: context.project_root,
        sessionId: payload.session_id,
      });
    } else {
      // No record for this session id, whatever the source claims: a fork, a
      // resume whose private record was pruned, or a continuation across a
      // plugin upgrade. Register it exactly like a cold start instead of
      // failing — refusing here creates no record, and no record fails every
      // stateful hook closed for the rest of the session. It grants nothing a
      // plain `startup` would not: a fresh anchor and a baseline workflow
      // document. Inherited chain state is deliberately NOT reconstructed —
      // the host payload carries no parent session id.
      context = core.registerContext({
        recordsDir,
        host: 'claude',
        sessionId: payload.session_id,
        projectRoot: eventCwd,
        pluginRoot,
        pluginData,
      });
      core.initializeWorkflowState({
        projectRoot: context.project_root,
        sessionId: payload.session_id,
      });
    }
  } else {
    context = core.readContext({
      recordsDir,
      sessionId: payload.session_id,
      expectedHost: 'claude',
    });
    if (context.plugin_root !== pluginRoot) {
      fail('SubagentStart plugin root does not match the parent session');
    }
    if (context.plugin_data !== pluginData) {
      fail('SubagentStart plugin data does not match the parent session');
    }
    if (payload.cwd) {
      // CwdChanged may move an otherwise bound session into an external
      // detached worktree. The host payload is trusted location metadata, not
      // a session authenticator; session_id plus the private record remain the
      // immutable binding.
      canonicalDirectory(payload.cwd, 'SubagentStart cwd');
    }
  }

  const additionalContext = principal === principals.PRINCIPALS.REVIEWER
    ? core.renderReviewerContext(context)
    : principal === principals.PRINCIPALS.EVIDENCE_WORKER
      ? core.renderEvidenceWorkerContext(context)
    : principal === principals.PRINCIPALS.MAIN
      ? core.renderMainContext(context)
      : core.renderHostContext(context);
  process.stdout.write(`${JSON.stringify(hookOutput(payload.hook_event_name, additionalContext))}\n`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
}
