#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const core = require('./session-control-core-v1.js');
const principals = require('./claude-principal-v1.js');

const MAX_PAYLOAD_BYTES = 1024 * 1024;
const ENVIRONMENT_KEYS = [
  'ZENSU_CLAUDE_PLUGIN_ROOT',
  'ZENSU_SESSION_KEY',
  'ZENSU_SESSION_CONTEXT',
  'ZENSU_RUNTIME_DIGEST',
  'ZENSU_PROJECT_ROOT',
];

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
  return payload;
}

function canonicalDirectory(value, label, rejectAlias = false) {
  if (typeof value !== 'string' || value.trim() === '' || /[\0\r\n]/.test(value)) fail(`${label} is unsafe`);
  if (rejectAlias) {
    let supplied;
    try {
      supplied = fs.lstatSync(path.resolve(value));
    } catch {
      fail(`${label} does not exist`);
    }
    if (supplied.isSymbolicLink()) fail(`${label} must not be a symlink`);
  }
  let canonical;
  try {
    canonical = fs.realpathSync.native(value);
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

function shellQuote(value) {
  if (typeof value !== 'string' || /[\0\r\n]/.test(value)) fail('environment export value is unsafe');
  return `'${value.replaceAll("'", "'\\''")}'`;
}

function sameFileIdentity(left, right) {
  if (!left || !right) return false;
  const inodeKnown = left.ino !== 0 && right.ino !== 0;
  if (inodeKnown) return left.dev === right.dev && left.ino === right.ino;
  return left.birthtimeMs === right.birthtimeMs && left.mode === right.mode;
}

function appendEnvironmentBlock(values) {
  const input = process.env.CLAUDE_ENV_FILE;
  if (typeof input !== 'string' || input.trim() === '' || /[\0\r\n]/.test(input)) {
    fail('CLAUDE_ENV_FILE is unavailable or unsafe');
  }
  const file = path.resolve(input);
  const parent = path.dirname(file);
  let parentBefore;
  let pathBefore;
  try {
    parentBefore = fs.lstatSync(parent);
    pathBefore = fs.lstatSync(file);
  } catch {
    fail('CLAUDE_ENV_FILE or its parent does not exist');
  }
  if (parentBefore.isSymbolicLink() || !parentBefore.isDirectory()) {
    fail('CLAUDE_ENV_FILE parent must be a real directory');
  }
  if (
    pathBefore.isSymbolicLink()
    || !pathBefore.isFile()
    || pathBefore.nlink !== 1
    || pathBefore.size > MAX_PAYLOAD_BYTES
  ) {
    fail('CLAUDE_ENV_FILE must be a bounded single-link regular file');
  }

  const invalidation = ENVIRONMENT_KEYS.map((key) => `unset ${key}`);
  const exports = ENVIRONMENT_KEYS.map((key) => `export ${key}=${shellQuote(values[key])}`);
  const block = Buffer.from(`${[...invalidation, ...exports].join('\n')}\n`, 'utf8');
  if (pathBefore.size + block.length > MAX_PAYLOAD_BYTES) fail('CLAUDE_ENV_FILE would exceed its size limit');

  const noFollow = Number.isInteger(fs.constants.O_NOFOLLOW) ? fs.constants.O_NOFOLLOW : 0;
  let descriptor;
  try {
    descriptor = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_APPEND | noFollow);
    const opened = fs.fstatSync(descriptor);
    const pathAtOpen = fs.lstatSync(file);
    const parentAtOpen = fs.lstatSync(parent);
    if (
      !opened.isFile()
      || opened.nlink !== 1
      || pathAtOpen.isSymbolicLink()
      || pathAtOpen.nlink !== 1
      || !sameFileIdentity(pathBefore, opened)
      || !sameFileIdentity(opened, pathAtOpen)
      || !sameFileIdentity(parentBefore, parentAtOpen)
    ) {
      fail('CLAUDE_ENV_FILE identity changed while opening');
    }

    // One O_APPEND write keeps invalidation and replacement exports in one
    // indivisible record even when multiple cold starts append concurrently.
    const written = fs.writeSync(descriptor, block, 0, block.length);
    if (written !== block.length) fail('CLAUDE_ENV_FILE environment block write was partial');
    fs.fsyncSync(descriptor);

    const after = fs.fstatSync(descriptor);
    const pathAfter = fs.lstatSync(file);
    const parentAfter = fs.lstatSync(parent);
    if (
      !after.isFile()
      || after.nlink !== 1
      || pathAfter.isSymbolicLink()
      || pathAfter.nlink !== 1
      || !sameFileIdentity(opened, after)
      || !sameFileIdentity(after, pathAfter)
      || !sameFileIdentity(parentBefore, parentAfter)
      || after.size > MAX_PAYLOAD_BYTES
    ) {
      fail('CLAUDE_ENV_FILE or its parent changed during append');
    }
  } catch (error) {
    if (error.code === 'ELOOP' || error.code === 'EMLINK') {
      fail('CLAUDE_ENV_FILE must not be a symlink');
    }
    throw error;
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
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
  const pluginRoot = authoritativePluginRoot();
  rejectSourceRevisionOverride();
  const pluginData = canonicalDirectory(process.env.CLAUDE_PLUGIN_DATA, 'CLAUDE_PLUGIN_DATA', true);
  const controlRoot = ensurePrivatePath(pluginData, ['session-control', 'v1']);
  const recordsDir = ensurePrivatePath(controlRoot, ['records']);
  ensurePrivatePath(controlRoot, ['locks']);

  let context;
  if (payload.hook_event_name === 'SessionStart') {
    const projectRoot = canonicalDirectory(payload.cwd, 'SessionStart cwd');
    context = core.registerContext({
      recordsDir,
      host: 'claude',
      sessionId: payload.session_id,
      projectRoot,
      pluginRoot,
      pluginData,
    });
    core.initializeWorkflowState({
      projectRoot: context.project_root,
      sessionId: payload.session_id,
    });
    const key = core.sessionKey(payload.session_id);
    appendEnvironmentBlock({
      ZENSU_CLAUDE_PLUGIN_ROOT: context.plugin_root,
      ZENSU_SESSION_KEY: key,
      ZENSU_SESSION_CONTEXT: path.join(recordsDir, `${key}.json`),
      ZENSU_RUNTIME_DIGEST: context.runtime_digest,
      ZENSU_PROJECT_ROOT: context.project_root,
    });
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
    if (payload.cwd && canonicalDirectory(payload.cwd, 'SubagentStart cwd') !== context.project_root) {
      fail('SubagentStart project does not match the parent session');
    }
  }

  let principal = principals.PRINCIPALS.MAIN;
  if (payload.hook_event_name === 'SubagentStart') {
    principal = principals.classifySubagent(payload.agent_type, payload.agent_id);
  }
  const additionalContext = principal === principals.PRINCIPALS.REVIEWER
    ? core.renderReviewerContext(context)
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
