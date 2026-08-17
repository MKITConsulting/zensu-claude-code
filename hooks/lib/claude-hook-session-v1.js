#!/usr/bin/env node
'use strict';

// Rebuild the five helper-private Session Control bindings from standard
// Claude inputs: hook payloads provide session_id, while model-side helper
// calls provide CLAUDE_CODE_SESSION_ID. Ambient ZENSU_* values are deliberately
// ignored: the private, immutable context record is the only authority. The
// all-tool capability gate imports the same resolver.
//
// argv modes: (none) binds from a hook payload on stdin and prints the five
// exports; `model-bind` does the same from CLAUDE_CODE_SESSION_ID;
// `unregistered` answers by EXIT STATUS ONLY — 0 when Session Control has never
// registered the session, 1 for every other state including a record that
// exists and disagrees; `orphaned-project-root` answers by exit status — 0 when
// a record exists, validates in every other respect, and its recorded project
// root is simply gone — and on a match prints that dead path so callers can
// name it; `model-orphaned-project-root` is the same question asked from
// CLAUDE_CODE_SESSION_ID, for the model-side /zensu:doctor;
// `incompatible-runtime` and its `model-` twin answer by exit status — 0 when
// the record is intact and the SOLE disagreement is a declared-incompatible
// executing lineage — and on a match print `recorded<TAB>executing`. None of the
// five prints bindings: a session in any of those states must stay unbound. The
// first four exist so the gates can tell the two RELAXABLE bind failures apart
// from each other and from all the rest; the fifth names a state that is NOT
// relaxable — a workflow document is still reachable there — and exists so the
// diagnosis stops being reported as "no record", which is false.

const fs = require('node:fs');
const path = require('node:path');
const core = require('./session-control-core-v1.js');
const hostPaths = require('./claude-path-v1.js');

const MAX_PAYLOAD_BYTES = 1024 * 1024;
const ALLOWED_EVENTS = new Set([
  'SessionStart',
  'PreToolUse',
  'PostToolUse',
  'Stop',
  'UserPromptSubmit',
]);

function fail(message) {
  throw new Error(`claude hook session binder: ${message}`);
}

function canonicalDirectory(value, label, rejectAlias = false) {
  if (typeof value !== 'string' || value.trim() === '' || /[\0\r\n]/.test(value)) {
    fail(`${label} is unavailable or unsafe`);
  }
  const requested = path.resolve(hostPaths.normalizeHostPathInput(value, label));
  let supplied;
  let canonical;
  try {
    supplied = fs.lstatSync(requested);
    canonical = fs.realpathSync.native(requested);
  } catch {
    fail(`${label} does not exist`);
  }
  if (rejectAlias && supplied.isSymbolicLink()) fail(`${label} must not be a symlink`);
  const stat = fs.lstatSync(canonical);
  if (stat.isSymbolicLink() || !stat.isDirectory()) fail(`${label} must be a real directory`);
  return canonical;
}

function privateRecordsDirectory(pluginData, allowMissing = false) {
  let current = pluginData;
  for (const segment of ['session-control', 'v1', 'records']) {
    current = path.join(current, segment);
    let stat;
    try {
      stat = fs.lstatSync(current);
    } catch (error) {
      if (allowMissing && error.code === 'ENOENT') return null;
      fail('private Session Control record directory is missing');
    }
    if (stat.isSymbolicLink() || !stat.isDirectory()) {
      fail('private Session Control record directory is unsafe');
    }
    if (process.platform !== 'win32' && (stat.mode & 0o077) !== 0) {
      fail('private Session Control record directory permissions are unsafe');
    }
    if (typeof process.getuid === 'function' && stat.uid !== process.getuid()) {
      fail('private Session Control record directory ownership is unsafe');
    }
  }
  if (fs.realpathSync.native(current) !== current) {
    fail('private Session Control record directory is aliased');
  }
  return current;
}

// True ONLY when Session Control has no record for this session at all — the
// records directory or the record file is simply absent. That is the 0.17.0
// upgrade state: Session Control shipped in that release, and a resume/compact
// SessionStart requires a record it never mints, so every session predating the
// update is unbindable forever and cannot be repaired in place.
//
// It is deliberately NOT true when a record EXISTS and disagrees with reality —
// runtime digest drift, a foreign plugin root, plugin data, or project root,
// tampering. A present-but-wrong record is a security signal and must keep
// failing every gate closed. Anything other than a clean ENOENT answers false,
// so an unreadable, unsafe, or ambiguous state also stays closed.
function unregisteredSession(payload, environment = process.env) {
  try {
    validateSessionId(payload.session_id);
    const executedPluginRoot = canonicalDirectory(path.resolve(__dirname, '..', '..'), 'executed plugin root');
    if (canonicalDirectory(environment.CLAUDE_PLUGIN_ROOT, 'CLAUDE_PLUGIN_ROOT') !== executedPluginRoot) {
      return false;
    }
    const pluginData = canonicalDirectory(environment.CLAUDE_PLUGIN_DATA, 'CLAUDE_PLUGIN_DATA', true);
    const recordsDir = privateRecordsDirectory(pluginData, true);
    if (recordsDir === null) return true;
    try {
      fs.lstatSync(path.join(recordsDir, `${core.sessionKey(payload.session_id)}.json`));
    } catch (error) {
      return error.code === 'ENOENT';
    }
    return false;
  } catch {
    return false;
  }
}

// The SECOND relaxable bind failure, and deliberately a separate predicate from
// unregisteredSession above: there a record is absent, here a record is present
// and intact and only the directory it points at is gone. Both mean no workflow
// state is reachable, but they are different diagnoses with different remedies,
// so the gates must be able to tell them apart rather than share one widened
// check.
//
// Returns the dead recorded project root, or null when this is not that state.
// Any additional disagreement, any unreadable or ambiguous state, and any
// exception answers null, so the caller keeps failing closed.
function resolveOrphanedProjectRoot(payload, environment = process.env) {
  try {
    validateSessionId(payload.session_id);
    const executedPluginRoot = canonicalDirectory(path.resolve(__dirname, '..', '..'), 'executed plugin root');
    if (canonicalDirectory(environment.CLAUDE_PLUGIN_ROOT, 'CLAUDE_PLUGIN_ROOT') !== executedPluginRoot) {
      return null;
    }
    const pluginData = canonicalDirectory(environment.CLAUDE_PLUGIN_DATA, 'CLAUDE_PLUGIN_DATA', true);
    const recordsDir = privateRecordsDirectory(pluginData, true);
    if (recordsDir === null) return null;
    const context = core.readOrphanedProjectRootContext({
      recordsDir,
      sessionId: payload.session_id,
      expectedHost: 'claude',
    });
    // The same two identity checks resolveHookSession applies, because
    // readOrphanedProjectRootContext validates the record against itself and
    // cannot see the running installation.
    //
    // Since semver-compatible binding the plugin-root check is itself
    // lineage-relaxed, so state the property that actually holds: a vanished
    // project root may be relaxed ALONGSIDE an executing root that is a
    // declared-compatible upgrade of the recorded one — that combination is
    // deliberate, because neither disagreement can anchor a workflow document.
    // What is still never relaxed alongside it is an INCOMPATIBLE root, a
    // differing plugin_data, or any other disagreement readContext rejects.
    if (!core.servesRecordedRuntime(context, executedPluginRoot, 'claude')) return null;
    if (context.plugin_data !== pluginData) return null;
    return context.project_root;
  } catch {
    return null;
  }
}

function orphanedProjectRootSession(payload, environment = process.env) {
  return resolveOrphanedProjectRoot(payload, environment) !== null;
}

// The THIRD bind-failure diagnosis, and a THIRD separate predicate — never a
// widening of either one above. Those two answer "is there anything left to
// enforce"; this one answers "is the record fine and only the runtime serving it
// declared incompatible". A plugin update that lands mid-session produces
// exactly that: the record is intact, its digest still verifies against the root
// it was minted under, and runtimeLineageCompatible refuses because at major 0
// the minor is the breaking axis.
//
// It is NOT a relaxable state. A workflow document IS reachable here, so
// relaxing a write gate would waive a live guarantee — unlike the two states
// above, where nothing is left to waive. What it buys is a NAME: the doctor row,
// the Stop release and the deny text can state the real cause and both versions
// instead of falling through to "no valid record", which is false and sends the
// user hunting for a record that is sitting intact in plugin data.
//
// Uses the STRICT reader on purpose. Every other check must pass, including the
// recorded project root still existing — a vanished root is the OTHER diagnosis
// and has its own predicate. Two disagreements are never one diagnosis, so a
// record that is both orphaned and lineage-incompatible answers null here and is
// classified by the orphan predicate, which is the heavier remedy.
//
// Returns { recorded, executing } — both declared versions — or null when this
// is not that state. Any additional disagreement, any unreadable or ambiguous
// state, and any exception answers null, so the caller keeps failing closed.
function resolveIncompatibleRuntime(payload, environment = process.env) {
  try {
    validateSessionId(payload.session_id);
    const executedPluginRoot = canonicalDirectory(path.resolve(__dirname, '..', '..'), 'executed plugin root');
    if (canonicalDirectory(environment.CLAUDE_PLUGIN_ROOT, 'CLAUDE_PLUGIN_ROOT') !== executedPluginRoot) {
      return null;
    }
    const pluginData = canonicalDirectory(environment.CLAUDE_PLUGIN_DATA, 'CLAUDE_PLUGIN_DATA', true);
    const recordsDir = privateRecordsDirectory(pluginData, true);
    if (recordsDir === null) return null;
    const context = core.readContext({
      recordsDir,
      sessionId: payload.session_id,
      expectedHost: 'claude',
    });
    if (context.plugin_data !== pluginData) return null;
    // The disagreement must be the lineage and nothing else: if this root DOES
    // serve the record, the bind failed for some other reason and naming the
    // lineage would be a wrong diagnosis.
    if (core.servesRecordedRuntime(context, executedPluginRoot, 'claude')) return null;
    const executing = core.executingPluginVersion(executedPluginRoot, 'claude');
    // A root that declares nothing readable is not a lineage claim — it is a
    // root that cannot be identified — so it is not this state either.
    if (typeof executing !== 'string' || executing === '') return null;
    return { recorded: context.plugin_version, executing };
  } catch {
    return null;
  }
}

function incompatibleRuntimeSession(payload, environment = process.env) {
  return resolveIncompatibleRuntime(payload, environment) !== null;
}

function validateSessionId(sessionId) {
  if (
    typeof sessionId !== 'string'
    || sessionId.trim() === ''
    || sessionId.length > 4096
    || /[\0\r\n]/.test(sessionId)
  ) {
    fail('session id is unavailable or unsafe');
  }
  if (/^(?:scv1_[a-f0-9]{64}|sha256:[a-f0-9]{64})$/.test(sessionId)) {
    fail('host session id must be raw, not a derived Session Control identifier');
  }
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
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    fail('hook payload must be an object');
  }
  if (payload.hook_event_name !== undefined && !ALLOWED_EVENTS.has(payload.hook_event_name)) {
    fail('unsupported hook event');
  }
  validateSessionId(payload.session_id);
  return payload;
}

function shellQuote(value) {
  if (typeof value !== 'string' || /[\0\r\n]/.test(value)) fail('binding value is unsafe');
  return `'${value.replaceAll("'", "'\\''")}'`;
}

function resolveHookSession(payload, environment = process.env) {
  validateSessionId(payload.session_id);
  const executedPluginRoot = canonicalDirectory(path.resolve(__dirname, '..', '..'), 'executed plugin root');
  const declaredPluginRoot = canonicalDirectory(environment.CLAUDE_PLUGIN_ROOT, 'CLAUDE_PLUGIN_ROOT');
  if (declaredPluginRoot !== executedPluginRoot) fail('CLAUDE_PLUGIN_ROOT does not match the executing plugin');

  const pluginData = canonicalDirectory(environment.CLAUDE_PLUGIN_DATA, 'CLAUDE_PLUGIN_DATA', true);
  const recordsDir = privateRecordsDirectory(pluginData);
  const sessionKey = core.sessionKey(payload.session_id);
  const context = core.readContext({ recordsDir, sessionId: payload.session_id, expectedHost: 'claude' });
  // Equal root, or a declared-compatible upgrade of it: a plugin update that
  // lands mid-session moves the executing root while the record stays valid
  // against its own (see readContextInternal, which recomputes the digest and
  // re-reads the manifest against the RECORDED root). plugin_data below is NOT
  // relaxed — it is what keeps an inline/dev source and an installed
  // marketplace plugin on separate record stores.
  if (!core.servesRecordedRuntime(context, executedPluginRoot, 'claude')) {
    fail('context plugin root is not a compatible lineage of the executing plugin');
  }
  if (context.plugin_data !== pluginData) fail('context plugin data does not match CLAUDE_PLUGIN_DATA');

  return {
    context,
    pluginRoot: executedPluginRoot,
    pluginData,
    projectRoot: context.project_root,
    contextFile: path.join(recordsDir, `${sessionKey}.json`),
    recordsDir,
    sessionKey,
  };
}

// SessionStart hooks with the same matcher run concurrently. A fresh startup
// therefore cannot require the Session Control sibling to have created its
// record already. Prefer a valid record when one exists (including retries),
// reject any unsafe existing record, and otherwise use Claude's stable project
// environment. The mutable payload cwd is never a project authority.
function resolveFreshHookProject(payload, environment = process.env) {
  validateSessionId(payload.session_id);
  const executedPluginRoot = canonicalDirectory(path.resolve(__dirname, '..', '..'), 'executed plugin root');
  const declaredPluginRoot = canonicalDirectory(environment.CLAUDE_PLUGIN_ROOT, 'CLAUDE_PLUGIN_ROOT');
  if (declaredPluginRoot !== executedPluginRoot) fail('CLAUDE_PLUGIN_ROOT does not match the executing plugin');

  const pluginData = canonicalDirectory(environment.CLAUDE_PLUGIN_DATA, 'CLAUDE_PLUGIN_DATA', true);
  const recordsDir = privateRecordsDirectory(pluginData, true);
  if (recordsDir) {
    const sessionKey = core.sessionKey(payload.session_id);
    const recordFile = path.join(recordsDir, `${sessionKey}.json`);
    let recordStat;
    try {
      recordStat = fs.lstatSync(recordFile);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    if (recordStat) {
      if (recordStat.isSymbolicLink() || !recordStat.isFile() || recordStat.nlink !== 1) {
        fail('private Session Control record is unsafe');
      }
      return resolveHookSession(payload, environment).projectRoot;
    }
  }

  return canonicalDirectory(environment.CLAUDE_PROJECT_DIR, 'CLAUDE_PROJECT_DIR');
}

function main() {
  let payload;
  if (process.argv[2] === 'unregistered') {
    // Exit 0 only for a session Session Control has never registered. Shell
    // gates use it to tell that one recoverable state apart from every other
    // bind failure, which must stay fail-closed.
    if (process.argv.length !== 3) fail('unregistered does not accept arguments');
    process.exitCode = unregisteredSession(readPayload()) ? 0 : 1;
    return;
  }
  if (process.argv[2] === 'orphaned-project-root' || process.argv[2] === 'model-orphaned-project-root') {
    // Exit 0 only when the sole disagreement is a project root that no longer
    // exists, and on a match print that dead path so the caller can name what
    // to re-create instead of calling the record merely "invalid". The two
    // spellings differ only in where the session id comes from: a hook payload
    // on stdin, or CLAUDE_CODE_SESSION_ID for the model-side /zensu:doctor.
    // Never any bindings — a session in this state must stay unbound.
    const mode = process.argv[2];
    if (process.argv.length !== 3) fail(`${mode} does not accept arguments`);
    let sessionPayload;
    if (mode === 'model-orphaned-project-root') {
      const hostSessionId = process.env.CLAUDE_CODE_SESSION_ID;
      validateSessionId(hostSessionId);
      sessionPayload = { session_id: hostSessionId };
    } else {
      sessionPayload = readPayload();
    }
    const orphanedRoot = resolveOrphanedProjectRoot(sessionPayload);
    if (orphanedRoot === null) {
      process.exitCode = 1;
      return;
    }
    process.stdout.write(`${orphanedRoot}\n`);
    return;
  }
  if (process.argv[2] === 'incompatible-runtime' || process.argv[2] === 'model-incompatible-runtime') {
    // Exit 0 only when the record is intact and the SOLE disagreement is that
    // the executing runtime declares an incompatible lineage, and on a match
    // print `recorded<TAB>executing` so the caller can name both versions
    // instead of reporting an anonymous mismatch. The two spellings differ only
    // in where the session id comes from, exactly as the orphan pair does.
    // Never any bindings: this state stays unbound until it is adopted.
    const mode = process.argv[2];
    if (process.argv.length !== 3) fail(`${mode} does not accept arguments`);
    let sessionPayload;
    if (mode === 'model-incompatible-runtime') {
      const hostSessionId = process.env.CLAUDE_CODE_SESSION_ID;
      validateSessionId(hostSessionId);
      sessionPayload = { session_id: hostSessionId };
    } else {
      sessionPayload = readPayload();
    }
    const versions = resolveIncompatibleRuntime(sessionPayload);
    if (versions === null) {
      process.exitCode = 1;
      return;
    }
    process.stdout.write(`${versions.recorded}\t${versions.executing}\n`);
    return;
  }
  if (process.argv[2] === 'model-bind') {
    if (process.argv.length !== 3) fail('model-bind does not accept arguments');
    const hostSessionId = process.env.CLAUDE_CODE_SESSION_ID;
    validateSessionId(hostSessionId);
    payload = { session_id: hostSessionId };
  } else {
    if (process.argv.length !== 2) fail('unsupported command-line mode');
    payload = readPayload();
  }
  const binding = resolveHookSession(payload);

  const values = {
    ZENSU_CLAUDE_PLUGIN_ROOT: binding.pluginRoot,
    ZENSU_SESSION_KEY: binding.sessionKey,
    ZENSU_SESSION_CONTEXT: binding.contextFile,
    ZENSU_RUNTIME_DIGEST: binding.context.runtime_digest,
    ZENSU_PROJECT_ROOT: binding.projectRoot,
  };
  for (const [name, value] of Object.entries(values)) {
    process.stdout.write(`export ${name}=${shellQuote(value)}\n`);
  }
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

module.exports = {
  incompatibleRuntimeSession,
  orphanedProjectRootSession,
  resolveFreshHookProject,
  resolveHookSession,
  resolveIncompatibleRuntime,
  resolveOrphanedProjectRoot,
  unregisteredSession,
};
