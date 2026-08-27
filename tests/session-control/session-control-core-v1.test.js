#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const corePath = process.env.SESSION_CONTROL_CORE;
assert.ok(corePath, 'SESSION_CONTROL_CORE must identify the host copy under test');
const core = require(path.resolve(corePath));

const RAW_SESSION = 'session/raw id with spaces';
const CREATED_AT = '2026-07-15T20:16:00.000Z';
const AMBIENT_GIT_SHA = 'a'.repeat(40);
const WINDOWS = process.platform === 'win32';
const WINDOWS_SYMLINK_SKIP = WINDOWS
  ? 'Windows runners do not guarantee unprivileged symbolic-link creation'
  : false;

function fixture(host = 'codex') {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-session-control-'));
  const projectRoot = path.join(root, 'project');
  const pluginRoot = path.join(root, 'plugin');
  const pluginData = path.join(root, 'plugin-data');
  const recordsDir = host === 'claude'
    ? path.join(pluginData, 'session-control', 'v1', 'records')
    : path.join(pluginData, 'session-control', host, 'v1', 'records');
  fs.mkdirSync(projectRoot, { recursive: true });
  fs.mkdirSync(pluginRoot, { recursive: true });
  fs.mkdirSync(pluginData, { recursive: true });
  const manifestDir = host === 'codex' ? '.codex-plugin' : '.claude-plugin';
  fs.mkdirSync(path.join(pluginRoot, manifestDir), { recursive: true });
  fs.writeFileSync(
    path.join(pluginRoot, manifestDir, 'plugin.json'),
    JSON.stringify({ name: 'zensu', version: '9.8.7' }),
  );
  fs.mkdirSync(path.join(pluginRoot, 'hooks', 'lib'), { recursive: true });
  fs.writeFileSync(path.join(pluginRoot, 'hooks', 'lib', 'runtime.js'), 'module.exports = 1;\n');
  fs.mkdirSync(path.join(pluginRoot, 'agents'), { recursive: true });
  fs.writeFileSync(path.join(pluginRoot, 'agents', 'reviewer.md'), '# reviewer\n');
  fs.mkdirSync(path.join(pluginRoot, 'skills', 'sample'), { recursive: true });
  fs.writeFileSync(path.join(pluginRoot, 'skills', 'sample', 'SKILL.md'), '# skill\n');
  fs.mkdirSync(path.join(pluginRoot, 'docs'), { recursive: true });
  fs.writeFileSync(path.join(pluginRoot, 'docs', 'runtime-guide.md'), '# runtime guide\n');
  fs.mkdirSync(path.join(pluginRoot, 'templates'), { recursive: true });
  fs.writeFileSync(path.join(pluginRoot, 'templates', 'review.md'), '# review template\n');
  fs.writeFileSync(path.join(pluginRoot, 'README.md'), '# plugin readme\n');
  fs.writeFileSync(path.join(pluginRoot, 'CHANGELOG.md'), '# plugin changelog\n');
  fs.writeFileSync(path.join(pluginRoot, 'LICENSE'), 'test license\n');
  return { root, projectRoot, pluginRoot, pluginData, recordsDir, host };
}

function register(f, overrides = {}) {
  return core.registerContext({
    recordsDir: f.recordsDir,
    host: f.host,
    sessionId: RAW_SESSION,
    projectRoot: f.projectRoot,
    pluginRoot: f.pluginRoot,
    pluginData: f.pluginData,
    createdAt: CREATED_AT,
    ...overrides,
  });
}

function initialize(f, sessionId = RAW_SESSION) {
  return core.initializeWorkflowState({ projectRoot: f.projectRoot, sessionId });
}

function runNode(source, args = []) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['-e', source, ...args], {
      env: { ...process.env, SESSION_CONTROL_CORE: path.resolve(corePath) },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', (code, signal) => resolve({ code, signal, stdout, stderr }));
  });
}

function assertKilled(child, label) {
  const details = `${label}, code=${child.code}, signal=${child.signal}, stderr=${child.stderr}`;
  const reportedSignal = child.signal === 'SIGKILL';
  // The Windows runner reports this emulated forced termination through the
  // exit code rather than ChildProcess.signalCode.
  const windowsForcedExit = WINDOWS
    && child.signal === null
    && Number.isInteger(child.code)
    && child.code !== 0;
  assert.ok(reportedSignal || windowsForcedExit, details);
}

function deferredFixture(options = {}) {
  const f = fixture('claude');
  if (options.legacyHostSegment === true) {
    f.recordsDir = path.join(f.pluginData, 'session-control', 'claude', 'v1', 'records');
  }
  const currentSessionId = core.sessionKey(options.currentSession || 'deferred-current');
  const ownerSessionId = core.sessionKey(options.ownerSession || 'deferred-owner');
  const currentContext = register(f, { sessionId: currentSessionId });
  const ownerContext = register(f, { sessionId: ownerSessionId });
  initialize(f, currentSessionId);
  initialize(f, ownerSessionId);
  const projectRoot = currentContext.project_root;
  const stateDirectory = path.join(projectRoot, '.zensu', 'state');
  const claimFile = path.join(stateDirectory, 'pending-review.json.claim');
  const currentContextFile = fs.realpathSync.native(path.join(
    f.recordsDir,
    `${currentSessionId}.json`,
  ));
  const ownerContextFile = fs.realpathSync.native(path.join(
    f.recordsDir,
    `${ownerSessionId}.json`,
  ));
  return {
    ...f,
    projectRoot,
    pluginRoot: currentContext.plugin_root,
    pluginData: currentContext.plugin_data,
    recordsDir: fs.realpathSync.native(f.recordsDir),
    stateDirectory,
    claimFile,
    currentSessionId,
    ownerSessionId,
    currentContext,
    ownerContext,
    currentContextFile,
    ownerContextFile,
    runtimeDigest: currentContext.runtime_digest,
    claimId: options.claimId || 'dc_unit_deferred_review',
  };
}

function seedDeferredOwner(f, overrides = {}) {
  return core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: f.ownerSessionId,
    workflowState: 'review_pending',
    event: 'unit-seed-deferred',
    expectedRevision: 1,
  }, (state) => ({
    ...state,
    active: true,
    implComplete: true,
    chainDone: false,
    codeReviewDone: false,
    selfReviewFixed: false,
    reviewTicket: '',
    reviewTicketConsumed: true,
    reviewRound: 0,
    stopBlockCount: 0,
    deferredReviewClaim: f.claimId,
    ...overrides,
  }));
}

function deferredClaim(f, overrides = {}) {
  return {
    claimId: f.claimId,
    ownerSessionId: f.ownerSessionId,
    ownerPid: process.pid,
    ownerProcessStartIdentity: null,
    handoffEmitted: false,
    ...overrides,
  };
}

function preparedTransfer(f, ownerRevision, overrides = {}) {
  return {
    schemaVersion: 1,
    claimId: f.claimId,
    fromOwnerRevision: ownerRevision,
    fromOwnerSessionId: f.ownerSessionId,
    retiredOwnerRevision: null,
    stage: 'prepared',
    toOwnerSessionId: f.currentSessionId,
    ...overrides,
  };
}

function preparedCancellation(f, ownerRevision, overrides = {}) {
  return {
    schemaVersion: 1,
    stage: 'prepared',
    cancellationId: 'drc_unit_deferred_review',
    claimId: f.claimId,
    ownerSessionId: f.ownerSessionId,
    mode: 'release-only',
    origin: 'linked',
    ownerRevision,
    clearedOwnerRevision: null,
    resetBinding: null,
    ...overrides,
  };
}

function writeDeferredClaim(f, overrides = {}) {
  const claim = deferredClaim(f, overrides);
  core.atomicWriteJson(f.claimFile, claim);
  return claim;
}

// FR-002: currentClaudeSessionContext carries its own copy of the plugin-root
// comparison, and it is the one call site no gate-level suite reaches. Under an
// equal root servesRecordedRuntime short-circuits before any manifest read, so a
// test that never varies the root cannot tell the relaxed comparison from the
// byte equality it replaced. These build a sibling plugin root that differs only
// in its declared version — the fixture declares 9.8.7, a non-zero major, so a
// minor step forward is compatible and a major step is not.
function siblingPluginRoot(f, version) {
  // A real sibling of the RECORDED root, because servesRecordedRuntime requires
  // one: every marketplace install lands beside the versions it replaces, and a
  // root elsewhere on disk is refused however compatible its version reads.
  const root = fs.mkdtempSync(path.join(path.dirname(f.pluginRoot), 'zensu-lineage-sibling-'));
  const manifestDir = f.currentContext.host === 'codex' ? '.codex-plugin' : '.claude-plugin';
  fs.mkdirSync(path.join(root, manifestDir), { recursive: true });
  fs.writeFileSync(
    path.join(root, manifestDir, 'plugin.json'),
    JSON.stringify({ name: 'zensu', version }),
  );
  return fs.realpathSync.native(root);
}

function inspectDeferredOptions(f, overrides = {}) {
  return {
    currentContextFile: f.currentContextFile,
    currentSessionId: f.currentSessionId,
    projectRoot: f.projectRoot,
    pluginRoot: f.pluginRoot,
    runtimeDigest: f.runtimeDigest,
    claimFile: f.claimFile,
    claimStale: false,
    ...overrides,
  };
}

function retireDeferredOptions(f, ownerRevision, overrides = {}) {
  return {
    ...inspectDeferredOptions(f),
    expectedRevision: ownerRevision,
    ...overrides,
  };
}

function assignDeferredOptions(f, overrides = {}) {
  return {
    ...inspectDeferredOptions(f),
    ownerPid: process.pid,
    logStyle: 'none',
    ...overrides,
  };
}

function currentProcessStartIdentity() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-process-identity-'));
  const lockFile = path.join(root, '.identity.lock');
  let identity = null;
  core.withFileLock(root, 'identity', () => {
    identity = JSON.parse(fs.readFileSync(lockFile, 'utf8')).process_start_identity;
  });
  return identity || null;
}

function assertClaimBytesUnchanged(f, before) {
  assert.deepEqual(fs.readFileSync(f.claimFile), before);
}

async function killDeferredCancellationAt(f, options, killpoint) {
  const stateFile = path.join(f.stateDirectory, `tdd-phase-${options.currentSessionId}.json`);
  const child = await runNode(`
    const fs = require('node:fs');
    const path = require('node:path');
    const core = require(process.env.SESSION_CONTROL_CORE);
    const options = JSON.parse(process.argv[1]);
    const killpoint = process.argv[2];
    const stateFile = path.resolve(process.argv[3]);
    const claimFile = path.resolve(process.argv[4]);
    const originalRename = fs.renameSync;
    fs.renameSync = function injectedRename(source, destination) {
      const target = path.resolve(String(destination));
      let value = null;
      try { value = JSON.parse(fs.readFileSync(source, 'utf8')); } catch (_) {}
      const result = originalRename.call(fs, source, destination);
      const prepared = target === claimFile
        && value && value.cancellation && value.cancellation.stage === 'prepared';
      const stateCas = target === stateFile
        && value && value.deferredReviewClaim === '' && value.deferredReviewCancellation;
      const stateCleared = target === claimFile
        && value && value.cancellation && value.cancellation.stage === 'state-cleared';
      if ((killpoint === 'prepared' && prepared)
          || (killpoint === 'state-cas' && stateCas)
          || (killpoint === 'state-cleared' && stateCleared)) {
        process.kill(process.pid, 'SIGKILL');
      }
      return result;
    };
    core.cancelDeferredReviewClaim(options);
  `, [JSON.stringify(options), killpoint, stateFile, f.claimFile]);
  assertKilled(child, `expected ${killpoint} killpoint`);
}

function rewriteJson(file, mutation) {
  const value = JSON.parse(fs.readFileSync(file, 'utf8'));
  const next = mutation(value) || value;
  fs.writeFileSync(file, `${JSON.stringify(next, null, 2)}\n`, { mode: 0o600 });
  return next;
}

function withAfterFileReadInjection(file, nthRead, injection, action) {
  const target = path.resolve(file);
  const originalOpen = fs.openSync;
  const originalClose = fs.closeSync;
  const tracked = new Set();
  let reads = 0;
  let injected = false;
  fs.openSync = function patchedOpen(candidate, flags, ...rest) {
    const descriptor = originalOpen.call(fs, candidate, flags, ...rest);
    if (path.resolve(String(candidate)) === target) tracked.add(descriptor);
    return descriptor;
  };
  fs.closeSync = function patchedClose(descriptor) {
    const shouldCount = tracked.delete(descriptor);
    const result = originalClose.call(fs, descriptor);
    if (shouldCount) {
      reads += 1;
      if (!injected && reads === nthRead) {
        injected = true;
        injection();
      }
    }
    return result;
  };
  try {
    const result = action();
    assert.equal(injected, true, `expected injection after read ${nthRead} of ${file}`);
    return result;
  } finally {
    fs.openSync = originalOpen;
    fs.closeSync = originalClose;
  }
}

test('exports the versioned schemas', () => {
  assert.equal(core.SCHEMA, 'zensu.session-control');
  assert.equal(core.SCHEMA_VERSION, 1);
  assert.equal(core.WORKFLOW_SCHEMA, 'zensu.workflow-state');
});

test('hashes session identifiers with a domain-separated SHA-256 value', () => {
  const hash = core.sessionIdHash(RAW_SESSION);
  assert.match(hash, /^sha256:[a-f0-9]{64}$/);
  assert.equal(hash, core.sessionIdHash(RAW_SESSION));
  assert.notEqual(hash, `sha256:${require('node:crypto').createHash('sha256').update(RAW_SESSION).digest('hex')}`);
});

test('creates a filesystem-safe key without exposing the raw session identifier', () => {
  const key = core.sessionKey(RAW_SESSION);
  assert.match(key, /^scv1_[a-f0-9]{64}$/);
  assert.ok(!key.includes('session'));
  assert.equal(core.sessionKey(key), key);
});

test('rejects empty session identifiers', () => {
  assert.throws(() => core.sessionIdHash(''), /session/i);
  assert.throws(() => core.sessionIdHash('   '), /session/i);
});

test('computes a deterministic runtime digest over runtime assets', () => {
  const f = fixture();
  const first = core.computeRuntimeDigest(f.pluginRoot, f.host);
  const second = core.computeRuntimeDigest(f.pluginRoot, f.host);
  assert.match(first, /^sha256:[a-f0-9]{64}$/);
  assert.equal(first, second);
});

test('runtime digest changes when a runtime asset changes', () => {
  const f = fixture();
  const before = core.computeRuntimeDigest(f.pluginRoot, f.host);
  fs.appendFileSync(path.join(f.pluginRoot, 'hooks', 'lib', 'runtime.js'), '// changed\n');
  assert.notEqual(core.computeRuntimeDigest(f.pluginRoot, f.host), before);
});

test('runtime digest binds skill-read documentation', () => {
  const f = fixture();
  const before = core.computeRuntimeDigest(f.pluginRoot, f.host);
  fs.appendFileSync(path.join(f.pluginRoot, 'docs', 'runtime-guide.md'), 'changed\n');
  assert.notEqual(core.computeRuntimeDigest(f.pluginRoot, f.host), before);
});

test('runtime digest binds skill-read templates', () => {
  const f = fixture();
  const before = core.computeRuntimeDigest(f.pluginRoot, f.host);
  fs.appendFileSync(path.join(f.pluginRoot, 'templates', 'review.md'), 'changed\n');
  assert.notEqual(core.computeRuntimeDigest(f.pluginRoot, f.host), before);
});

test('runtime digest binds every top-level help source', () => {
  const f = fixture();
  let before = core.computeRuntimeDigest(f.pluginRoot, f.host);
  for (const file of ['README.md', 'CHANGELOG.md', 'LICENSE']) {
    fs.appendFileSync(path.join(f.pluginRoot, file), `${file} changed\n`);
    const after = core.computeRuntimeDigest(f.pluginRoot, f.host);
    assert.notEqual(after, before, `${file} must be runtime-bound`);
    before = after;
  }
});

test('runtime digest rejects symlinks below runtime roots', { skip: WINDOWS_SYMLINK_SKIP }, () => {
  const f = fixture();
  fs.symlinkSync(path.join(f.pluginRoot, 'README-target'), path.join(f.pluginRoot, 'hooks', 'linked'));
  assert.throws(() => core.computeRuntimeDigest(f.pluginRoot, f.host), /symlink/i);
});

test('fails closed when a regular runtime file changes during descriptor-backed read', () => {
  const f = fixture();
  const target = fs.realpathSync.native(path.join(f.pluginRoot, 'hooks', 'lib', 'runtime.js'));
  const originalOpen = fs.openSync;
  const originalRead = fs.readSync;
  let targetDescriptor = null;
  let raced = false;
  fs.openSync = function patchedOpen(file, flags, ...rest) {
    const descriptor = originalOpen.call(fs, file, flags, ...rest);
    if (path.resolve(String(file)) === path.resolve(target) && typeof flags === 'number') {
      targetDescriptor = descriptor;
    }
    return descriptor;
  };
  fs.readSync = function patchedRead(descriptor, ...args) {
    if (descriptor === targetDescriptor && !raced) {
      raced = true;
      const writer = originalOpen.call(fs, target, 'a');
      try {
        fs.writeSync(writer, '// raced\n');
      } finally {
        fs.closeSync(writer);
      }
    }
    return originalRead.call(fs, descriptor, ...args);
  };
  try {
    assert.throws(() => core.computeRuntimeDigest(f.pluginRoot, f.host), /changed.*read|changed.*digest/i);
    assert.equal(raced, true);
  } finally {
    fs.openSync = originalOpen;
    fs.readSync = originalRead;
  }
});

test('runtime digest requires the host-specific manifest', () => {
  const f = fixture('codex');
  assert.throws(() => core.computeRuntimeDigest(f.pluginRoot, 'claude'), /manifest/i);
});

test('Claude runtime digest includes manifest-activated MCP config and launchers', () => {
  const f = fixture('claude');
  const manifestFile = path.join(f.pluginRoot, '.claude-plugin', 'plugin.json');
  fs.writeFileSync(manifestFile, JSON.stringify({ name: 'zensu', version: '9.8.7', mcpServers: './.mcp.json' }));
  fs.writeFileSync(path.join(f.pluginRoot, '.mcp.json'), JSON.stringify({
    mcpServers: { example: { command: '${CLAUDE_PLUGIN_ROOT}/scripts/example.sh' } },
  }));
  fs.mkdirSync(path.join(f.pluginRoot, 'scripts'));
  fs.writeFileSync(path.join(f.pluginRoot, 'scripts', 'example.sh'), '#!/bin/sh\nexit 0\n');
  const before = core.computeRuntimeDigest(f.pluginRoot, 'claude');
  fs.appendFileSync(path.join(f.pluginRoot, '.mcp.json'), '\n');
  const afterConfig = core.computeRuntimeDigest(f.pluginRoot, 'claude');
  assert.notEqual(afterConfig, before);
  fs.appendFileSync(path.join(f.pluginRoot, 'scripts', 'example.sh'), '# changed\n');
  assert.notEqual(core.computeRuntimeDigest(f.pluginRoot, 'claude'), afterConfig);
});

test('builds an immutable context with canonical roots and profiles', () => {
  const f = fixture();
  const context = core.buildContext({
    host: f.host,
    sessionId: RAW_SESSION,
    projectRoot: f.projectRoot,
    pluginRoot: f.pluginRoot,
    pluginData: f.pluginData,
    createdAt: CREATED_AT,
  });
  assert.equal(context.schema, core.SCHEMA);
  assert.equal(context.schema_version, 1);
  assert.equal(context.host, 'codex');
  assert.equal(context.session_id_hash, core.sessionIdHash(RAW_SESSION));
  assert.equal(context.project_root, fs.realpathSync.native(f.projectRoot));
  assert.equal(context.plugin_root, fs.realpathSync.native(f.pluginRoot));
  assert.equal(context.plugin_version, '9.8.7');
  assert.equal(context.principal_profiles.main, 'main-v1');
  assert.equal(context.principal_profiles.reviewer, 'reviewer-readonly-v1');
  assert.equal(context.principal_profiles.host, 'host-profile-v1');
  assert.equal(context.created_at, CREATED_AT);
  assert.equal(context.source_revision, context.runtime_digest);
  assert.notEqual(context.source_revision, 'unknown');
});

test('rejects every source revision override, including the retired authority pair', () => {
  const f = fixture();
  const options = {
    host: f.host,
    sessionId: RAW_SESSION,
    projectRoot: f.projectRoot,
    pluginRoot: f.pluginRoot,
    pluginData: f.pluginData,
    createdAt: CREATED_AT,
  };
  const contentDigest = core.computeRuntimeDigest(f.pluginRoot, f.host);
  for (const override of [
    { sourceRevision: AMBIENT_GIT_SHA },
    { sourceRevision: AMBIENT_GIT_SHA, sourceRevisionAuthority: 'verified-runtime-provenance-v1' },
    { sourceRevisionAuthority: 'verified-runtime-provenance-v1' },
    { sourceRevision: contentDigest },
    { sourceRevision: 'not-a-revision' },
  ]) {
    assert.throws(() => core.buildContext({ ...options, ...override }), /overrides are unsupported/i);
  }
});

test('rejects unsupported hosts', () => {
  const f = fixture();
  assert.throws(() => core.buildContext({ ...f, sessionId: RAW_SESSION, host: 'kiro' }), /host/i);
});

test('registers one private immutable record per session', () => {
  const f = fixture();
  const context = register(f);
  const record = path.join(f.recordsDir, `${core.sessionKey(RAW_SESSION)}.json`);
  assert.deepEqual(JSON.parse(fs.readFileSync(record, 'utf8')), context);
});

test('never replaces a planted immutable-record symlink', {
  skip: WINDOWS_SYMLINK_SKIP,
}, () => {
  const f = fixture();
  fs.mkdirSync(f.recordsDir, { recursive: true });
  const record = path.join(f.recordsDir, `${core.sessionKey(RAW_SESSION)}.json`);
  const missing = path.join(f.root, 'missing-record-target');
  fs.symlinkSync(missing, record);
  assert.throws(() => register(f), /immutable record already exists|EEXIST/);
  assert.equal(fs.lstatSync(record).isSymbolicLink(), true);
  assert.equal(fs.existsSync(missing), false);
});

test('registers a POSIX-private immutable record', {
  skip: WINDOWS ? 'Windows ACLs do not expose POSIX 0600 semantics' : false,
}, () => {
  const f = fixture();
  register(f);
  const record = path.join(f.recordsDir, `${core.sessionKey(RAW_SESSION)}.json`);
  assert.equal(fs.statSync(record).mode & 0o777, 0o600);
});

test('never persists the raw host session identifier', () => {
  const f = fixture();
  register(f);
  const persisted = fs.readFileSync(path.join(f.recordsDir, `${core.sessionKey(RAW_SESSION)}.json`), 'utf8');
  assert.ok(!persisted.includes(RAW_SESSION));
});

test('reuses an identical immutable record idempotently', () => {
  const f = fixture();
  const first = register(f);
  const second = register(f, { createdAt: '2099-01-01T00:00:00.000Z' });
  assert.deepEqual(second, first);
});

test('registers one immutable record under true multi-process contention', async () => {
  const f = fixture();
  const options = {
    recordsDir: f.recordsDir,
    host: f.host,
    sessionId: RAW_SESSION,
    projectRoot: f.projectRoot,
    pluginRoot: f.pluginRoot,
    pluginData: f.pluginData,
    createdAt: CREATED_AT,
  };
  const source = 'const c=require(process.env.SESSION_CONTROL_CORE);c.registerContext(JSON.parse(process.argv[1]));';
  const results = await Promise.all(Array.from({ length: 12 }, () => runNode(source, [JSON.stringify(options)])));
  for (const result of results) assert.equal(result.code, 0, result.stderr);
  const records = fs.readdirSync(f.recordsDir).filter((entry) => entry.endsWith('.json'));
  assert.deepEqual(records, [`${core.sessionKey(RAW_SESSION)}.json`]);
  const resolved = core.readContext({
    recordsDir: f.recordsDir,
    sessionId: RAW_SESSION,
    expectedHost: f.host,
  });
  assert.equal(resolved.source_revision, resolved.runtime_digest);
});

test('recovers valid dead lock and recovery generations immediately', () => {
  const f = fixture();
  const locks = path.join(f.pluginData, 'session-control', f.host, 'v1', 'locks');
  fs.mkdirSync(locks, { recursive: true });
  const key = core.sessionKey(RAW_SESSION);
  const staleOwner = JSON.stringify({ pid: 2147483647, token: 'a'.repeat(48), created_at: CREATED_AT });
  for (const suffix of ['lock', 'recovery']) {
    const file = path.join(locks, `.${key}.${suffix}`);
    fs.writeFileSync(file, staleOwner, { mode: 0o600 });
  }
  const context = register(f);
  assert.equal(context.source_revision, context.runtime_digest);
  assert.equal(fs.existsSync(path.join(locks, `.${key}.lock`)), false);
  assert.equal(fs.existsSync(path.join(locks, `.${key}.recovery`)), false);
});

test('retries a lock generation whose identity changes between lstat and open', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-lock-open-race-'));
  const lockFile = path.join(fs.realpathSync.native(root), '.open-race.lock');
  // Prime the process-start cache under the real platform before simulating
  // Windows so this test cannot alter later PID-reuse checks in this process.
  core.withFileLock(root, 'platform-cache-prime', () => {});
  fs.writeFileSync(lockFile, JSON.stringify({
    pid: 2147483647,
    token: 'e'.repeat(48),
    created_at: CREATED_AT,
  }), { mode: 0o600 });

  const originalOpen = fs.openSync;
  const originalFstat = fs.fstatSync;
  const platformDescriptor = Object.getOwnPropertyDescriptor(process, 'platform');
  let raceDescriptor = null;
  let injected = false;
  fs.openSync = function patchedOpen(file, flags, ...rest) {
    const descriptor = originalOpen.call(fs, file, flags, ...rest);
    if (!injected && path.resolve(String(file)) === path.resolve(lockFile)) {
      raceDescriptor = descriptor;
    }
    return descriptor;
  };
  fs.fstatSync = function patchedFstat(descriptor, ...rest) {
    const stat = originalFstat.call(fs, descriptor, ...rest);
    if (descriptor !== raceDescriptor || injected) return stat;
    injected = true;
    return new Proxy(stat, {
      get(target, property) {
        if (property === 'ino') return target.ino === 0 ? 1 : target.ino + 1;
        if (property === 'birthtimeMs') return target.birthtimeMs + 1;
        const value = Reflect.get(target, property, target);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    });
  };

  try {
    // Force the same lstat/open identity bracket used by Node on Windows even
    // when this deterministic regression test runs on a POSIX developer host.
    Object.defineProperty(process, 'platform', { ...platformDescriptor, value: 'win32' });
    assert.equal(core.withFileLock(root, 'open-race', () => 'recovered'), 'recovered');
    assert.equal(injected, true);
    assert.equal(fs.existsSync(lockFile), false);
  } finally {
    Object.defineProperty(process, 'platform', platformDescriptor);
    fs.openSync = originalOpen;
    fs.fstatSync = originalFstat;
  }
});

test('does not classify unrelated errors whose paths mention a transient phrase', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-lock-error-path-'));
  const lockFile = path.join(fs.realpathSync.native(root), '.error-path.lock');
  fs.writeFileSync(lockFile, JSON.stringify({
    pid: 2147483647,
    token: 'f'.repeat(48),
    created_at: CREATED_AT,
  }), { mode: 0o600 });

  const originalOpen = fs.openSync;
  const unrelatedError = new Error(`EACCES: permission denied, open '${path.join(root, 'missing file')}'`);
  unrelatedError.code = 'EACCES';
  let matchingOpenCalls = 0;
  fs.openSync = function patchedOpen(file, flags, ...rest) {
    if (path.resolve(String(file)) === path.resolve(lockFile)) {
      matchingOpenCalls += 1;
      if (matchingOpenCalls === 1) throw unrelatedError;
      throw new Error('unrelated lock snapshot error was retried');
    }
    return originalOpen.call(fs, file, flags, ...rest);
  };

  try {
    assert.throws(
      () => core.withFileLock(root, 'error-path', () => {}),
      (error) => error === unrelatedError,
    );
    assert.equal(matchingOpenCalls, 1);
  } finally {
    fs.openSync = originalOpen;
  }
});

test('never reclaims an old lock whose owner process is still alive', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-live-lock-'));
  const lockFile = path.join(root, '.liveowner.lock');
  const owner = { pid: process.pid, token: 'b'.repeat(48), created_at: CREATED_AT };
  fs.writeFileSync(lockFile, JSON.stringify(owner), { mode: 0o600 });
  const stale = new Date(Date.now() - 60000);
  fs.utimesSync(lockFile, stale, stale);
  const source = 'const c=require(process.env.SESSION_CONTROL_CORE);c.withFileLock(process.argv[1],"liveowner",()=>{});';
  const child = spawn(process.execPath, ['-e', source, root], {
    env: { ...process.env, SESSION_CONTROL_CORE: path.resolve(corePath) },
    stdio: 'ignore',
  });
  let exited = false;
  const closed = new Promise((resolve) => child.on('close', (code, signal) => {
    exited = true;
    resolve({ code, signal });
  }));
  await new Promise((resolve) => setTimeout(resolve, 250));
  assert.equal(exited, false);
  assert.deepEqual(JSON.parse(fs.readFileSync(lockFile, 'utf8')), owner);
  child.kill('SIGTERM');
  await closed;
  fs.unlinkSync(lockFile);
});

test('recovers a lock left at a SIGKILL kill point', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-lock-kill-'));
  const source = 'const c=require(process.env.SESSION_CONTROL_CORE);c.withFileLock(process.argv[1],"killpoint",()=>process.kill(process.pid,"SIGKILL"));';
  const killed = await runNode(source, [root]);
  assert.notEqual(killed.code, 0);
  const lockFile = path.join(root, '.killpoint.lock');
  assert.equal(fs.existsSync(lockFile), true);
  assert.equal(core.withFileLock(root, 'killpoint', () => 'recovered'), 'recovered');
  assert.equal(fs.existsSync(lockFile), false);
});

test('uses process start identity to reject a live but PID-reused owner', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-pid-reuse-'));
  const probeFile = path.join(root, '.probe.lock');
  let actualIdentity = null;
  core.withFileLock(root, 'probe', () => {
    actualIdentity = JSON.parse(fs.readFileSync(probeFile, 'utf8')).process_start_identity;
  });
  if (!actualIdentity) {
    t.skip('this platform does not expose a portable process start identity');
    return;
  }
  const lockFile = path.join(root, '.pidreuse.lock');
  fs.writeFileSync(lockFile, JSON.stringify({
    pid: process.pid,
    token: 'c'.repeat(48),
    created_at: new Date().toISOString(),
    process_start_identity: 'mismatched-process-start',
  }), { mode: 0o600 });
  assert.equal(core.withFileLock(root, 'pidreuse', () => 'recovered'), 'recovered');
  assert.equal(fs.existsSync(lockFile), false);
});

test('keeps a fresh corrupt lock for the TTL instead of guessing its owner is dead', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-corrupt-lock-'));
  const lockFile = path.join(root, '.corrupt.lock');
  fs.writeFileSync(lockFile, '{broken', { mode: 0o600 });
  const source = 'const c=require(process.env.SESSION_CONTROL_CORE);c.withFileLock(process.argv[1],"corrupt",()=>{});';
  const child = spawn(process.execPath, ['-e', source, root], {
    env: { ...process.env, SESSION_CONTROL_CORE: path.resolve(corePath) },
    stdio: 'ignore',
  });
  let exited = false;
  const closed = new Promise((resolve) => child.on('close', (code, signal) => {
    exited = true;
    resolve({ code, signal });
  }));
  await new Promise((resolve) => setTimeout(resolve, 250));
  assert.equal(exited, false);
  assert.equal(fs.readFileSync(lockFile, 'utf8'), '{broken');
  child.kill('SIGTERM');
  await closed;
  fs.unlinkSync(lockFile);
});

test('never deletes a replacement that races lock release', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-lock-replace-'));
  const canonicalRoot = fs.realpathSync.native(root);
  const lockFile = path.join(canonicalRoot, '.replacement.lock');
  const displaced = path.join(canonicalRoot, '.original.displaced');
  const replacement = {
    pid: process.pid,
    token: 'd'.repeat(48),
    created_at: new Date().toISOString(),
  };
  const originalRename = fs.renameSync;
  let injected = false;
  try {
    assert.throws(() => core.withFileLock(root, 'replacement', () => {
      fs.renameSync = function patchedRename(source, destination) {
        if (!injected && path.resolve(source) === path.resolve(lockFile)) {
          injected = true;
          originalRename.call(fs, source, displaced);
          fs.writeFileSync(source, JSON.stringify(replacement), { mode: 0o600 });
        }
        return originalRename.call(fs, source, destination);
      };
    }), /identity changed|ownership changed/i);
    assert.equal(injected, true);
    assert.deepEqual(JSON.parse(fs.readFileSync(lockFile, 'utf8')), replacement);
  } finally {
    fs.renameSync = originalRename;
    if (fs.existsSync(lockFile)) fs.unlinkSync(lockFile);
    if (fs.existsSync(displaced)) fs.unlinkSync(displaced);
  }
});

test('fails closed when a session is rebound to another project', () => {
  const f = fixture();
  register(f);
  const otherProject = path.join(f.root, 'other-project');
  fs.mkdirSync(otherProject);
  assert.throws(() => register(f, { projectRoot: otherProject }), /immutable|mismatch|project/i);
});

test('fails closed when runtime assets drift inside an active session', () => {
  const f = fixture();
  register(f);
  fs.appendFileSync(path.join(f.pluginRoot, 'skills', 'sample', 'SKILL.md'), 'drift\n');
  assert.throws(() => register(f), /runtime|mismatch|immutable/i);
});

test('rejects arbitrary source provenance persisted in a context record', () => {
  const f = fixture();
  register(f);
  const record = path.join(f.recordsDir, `${core.sessionKey(RAW_SESSION)}.json`);
  const persisted = JSON.parse(fs.readFileSync(record, 'utf8'));
  for (const sourceRevision of [
    'arbitrary-ambient-value',
    AMBIENT_GIT_SHA,
    `sha256:${'0'.repeat(64)}`,
  ]) {
    persisted.source_revision = sourceRevision;
    fs.writeFileSync(record, `${JSON.stringify(persisted, null, 2)}\n`);
    assert.throws(() => core.readContext({
      recordsDir: f.recordsDir,
      sessionId: RAW_SESSION,
      expectedHost: f.host,
    }), /source revision/i);
  }
});

test('resolves and verifies a registered context', () => {
  const f = fixture('claude');
  register(f);
  const resolved = core.readContext({
    recordsDir: f.recordsDir,
    sessionId: RAW_SESSION,
    expectedHost: 'claude',
  });
  assert.equal(resolved.host, 'claude');
  assert.equal(resolved.plugin_root, fs.realpathSync.native(f.pluginRoot));
});

test('creates one complete project-bound workflow baseline at SessionStart', () => {
  const f = fixture();
  register(f);
  const baseline = initialize(f);
  assert.equal(baseline.schema, core.WORKFLOW_SCHEMA);
  assert.equal(baseline.revision, 1);
  assert.equal(baseline.workflow_state, 'idle');
  assert.deepEqual({
    active: baseline.active,
    vanilla: baseline.vanilla,
    implComplete: baseline.implComplete,
    chainDone: baseline.chainDone,
    codeReviewDone: baseline.codeReviewDone,
    selfReviewFixed: baseline.selfReviewFixed,
    workflowActive: baseline.workflowActive,
    workflowTools: baseline.workflowTools,
    bypasses: baseline.bypasses,
    reviewRound: baseline.reviewRound,
    stopBlockCount: baseline.stopBlockCount,
    phase: baseline.phase,
    step_id: baseline.step_id,
    history: baseline.history,
  }, {
    active: false,
    vanilla: false,
    implComplete: false,
    chainDone: false,
    codeReviewDone: false,
    selfReviewFixed: false,
    workflowActive: false,
    workflowTools: [],
    bypasses: [],
    reviewRound: 0,
    stopBlockCount: 0,
    phase: 'UNINITIALIZED',
    step_id: '',
    history: [],
  });
  assert.ok(!JSON.stringify(baseline).includes(RAW_SESSION));
});

test('baseline initialization is idempotent and never resets an existing workflow', () => {
  const f = fixture();
  register(f);
  initialize(f);
  const active = core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'active',
    event: 'tdd-begin',
  }, (state) => ({ ...state, active: true }));
  const repeated = initialize(f);
  assert.equal(repeated.revision, active.revision);
  assert.equal(repeated.active, true);
  assert.equal(fs.existsSync(path.join(f.pluginData, '.workflow-activations')), false);
});

test('resetReviewBudget re-arms the complete review budget in one CAS revision', () => {
  const f = fixture();
  initialize(f);
  const seeded = core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'review_exhausted',
    event: 'test-seed',
    expectedRevision: 1,
  }, (state) => ({
    ...state,
    active: true,
    implComplete: true,
    reviewRound: 3,
    stopBlockCount: 2,
    chainDone: true,
    codeReviewDone: true,
    selfReviewFixed: true,
  }));
  const reset = core.resetReviewBudget({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    expectedRevision: seeded.revision,
  });
  assert.equal(reset.revision, seeded.revision + 1);
  assert.deepEqual({
    active: reset.active,
    implComplete: reset.implComplete,
    reviewRound: reset.reviewRound,
    stopBlockCount: reset.stopBlockCount,
    chainDone: reset.chainDone,
    codeReviewDone: reset.codeReviewDone,
    selfReviewFixed: reset.selfReviewFixed,
  }, {
    active: true,
    implComplete: true,
    reviewRound: 0,
    stopBlockCount: 0,
    chainDone: false,
    codeReviewDone: false,
    selfReviewFixed: false,
  });
});

test('resetReviewBudget stale revision and failed preconditions preserve exact state bytes', () => {
  for (const testCase of [
    { label: 'stale revision', active: true, implComplete: true, expectedRevision: 1, pattern: /stale workflow revision/i },
    { label: 'inactive workflow', active: false, implComplete: true, expectedRevision: 2, pattern: /active completed implementation/i },
    { label: 'incomplete implementation', active: true, implComplete: false, expectedRevision: 2, pattern: /active completed implementation/i },
  ]) {
    const f = fixture();
    initialize(f);
    core.mutateWorkflowState({
      projectRoot: f.projectRoot,
      sessionId: RAW_SESSION,
      workflowState: 'test_seed',
      event: 'test-seed',
      expectedRevision: 1,
    }, (state) => ({ ...state, active: testCase.active, implComplete: testCase.implComplete, reviewRound: 3 }));
    const file = path.join(f.projectRoot, '.zensu', 'state', `tdd-phase-${core.sessionKey(RAW_SESSION)}.json`);
    const before = fs.readFileSync(file);
    assert.throws(() => core.resetReviewBudget({
      projectRoot: f.projectRoot,
      sessionId: RAW_SESSION,
      expectedRevision: testCase.expectedRevision,
    }), testCase.pattern, testCase.label);
    assert.deepEqual(fs.readFileSync(file), before, `${testCase.label} must preserve exact bytes`);
  }
});

test('resetReviewBudget rejects invalid state without repair or byte changes', () => {
  const f = fixture();
  initialize(f);
  const file = path.join(f.projectRoot, '.zensu', 'state', `tdd-phase-${core.sessionKey(RAW_SESSION)}.json`);
  const state = JSON.parse(fs.readFileSync(file, 'utf8'));
  state.reviewRound = '3';
  fs.writeFileSync(file, `${JSON.stringify(state, null, 2)}\n`);
  const before = fs.readFileSync(file);
  assert.throws(() => core.resetReviewBudget({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    expectedRevision: 1,
  }), /reviewRound|bounded non-negative integer/i);
  assert.deepEqual(fs.readFileSync(file), before);
});

test('fails closed for a missing context', () => {
  const f = fixture();
  fs.mkdirSync(f.recordsDir, { recursive: true });
  const expectedFile = path.join(
    fs.realpathSync.native(f.recordsDir),
    `${core.sessionKey(RAW_SESSION)}.json`,
  );
  assert.throws(
    () => core.readContext({ recordsDir: f.recordsDir, sessionId: RAW_SESSION }),
    (error) => error.message === `session-control-v1: missing file: ${expectedFile}`,
  );
});

test('renders main context without the raw session identifier', () => {
  const f = fixture();
  const rendered = core.renderMainContext(register(f));
  assert.match(rendered, /^\[zensu-session-context\]/);
  assert.match(rendered, /principal=main-v1/);
  assert.ok(!rendered.includes(RAW_SESSION));
});

test('renders an explicit reviewer read-only contract', () => {
  const f = fixture();
  const rendered = core.renderReviewerContext(register(f));
  assert.match(rendered, /reviewer-readonly-v1/);
  assert.match(rendered, /must not write, spawn, mutate workflow state, invoke mutating control or MCP tools, or impersonate main/i);
});

test('renders a neutral host profile without main or reviewer authority', () => {
  const f = fixture();
  const context = register(f);
  const rendered = core.renderHostContext(context);
  assert.match(rendered, /^\[zensu-host-context\]/);
  assert.match(rendered, /principal=host-profile-v1/);
  assert.doesNotMatch(rendered, /principal=main-v1/);
  assert.doesNotMatch(rendered, /principal=reviewer-readonly-v1/);
  assert.doesNotMatch(rendered, /(?:plugin_root|plugin_data|session_id|session_id_hash|ZENSU_|CLAUDE_PLUGIN_DATA)=/);
  assert.ok(!rendered.includes(context.plugin_root));
});

test('increments workflow revision atomically on every mutation', () => {
  const f = fixture();
  register(f);
  initialize(f);
  const first = core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'red',
    event: 'red-start',
    updatedAt: CREATED_AT,
  });
  const second = core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'green',
    event: 'green-pass',
    expectedRevision: 2,
    updatedAt: CREATED_AT,
  });
  assert.equal(first.revision, 2);
  assert.equal(second.revision, 3);
  assert.equal(second.workflow_state, 'green');
});

test('strictly validates gate-relevant workflow extensions while preserving unknown extensions', () => {
  const valid = {
    active: true,
    vanilla: false,
    implComplete: false,
    chainDone: false,
    codeReviewDone: false,
    selfReviewFixed: false,
    workflowActive: true,
    phase: 'RED_FAIL',
    step_id: 'S1',
    history: [{ step: 'S1', phase: 'RED_FAIL', ts: CREATED_AT, reason: 'expected failure' }],
    workflowTools: ['link_test', 'create_revision'],
    bypasses: ['ZENSU_TDD_GATE'],
    future_extension: { nested: ['remains', 'accepted'] },
  };
  const stamped = core.stampWorkflowState(valid, RAW_SESSION, 'red_fail', 'phase-red_fail', CREATED_AT);
  assert.deepEqual(stamped.future_extension, valid.future_extension);

  const malformed = [
    ...['active', 'vanilla', 'implComplete', 'chainDone', 'codeReviewDone', 'selfReviewFixed', 'workflowActive']
      .map((field) => ({ [field]: 'false' })),
    { phase: [] },
    { phase: 'IMPL\nforged' },
    { step_id: 7 },
    { history: {} },
    { history: [null] },
    { history: [{}] },
    { history: [{ step: 1, phase: 'RED_FAIL' }] },
    { history: [{ step: 'S1', phase: false }] },
    { history: [{ step: 'S1', phase: 'RED_FAIL', ts: 'not-a-date' }] },
    { history: [{ step: 'S1', phase: 'RED_FAIL', reason: {} }] },
    { workflowTools: {} },
    { workflowTools: ['link_test', 7] },
    { workflowTools: ['link_test\nforged'] },
    { bypasses: 'ZENSU_TDD_GATE' },
    { bypasses: ['ZENSU_TDD_GATE', 7] },
  ];
  for (const extension of malformed) {
    assert.throws(
      () => core.stampWorkflowState(extension, RAW_SESSION, 'control', 'extension-check', CREATED_AT),
      /workflow/i,
    );
  }
});

test('keeps every reserved workflow field and revision under core ownership', () => {
  const f = fixture();
  initialize(f);
  core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'red',
    event: 'first',
    updatedAt: CREATED_AT,
  });
  const reset = core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'green',
    event: 'reset_attempt',
    updatedAt: CREATED_AT,
  }, () => ({
    schema: 'attacker.schema',
    schema_version: 99,
    session_id: RAW_SESSION,
    session_id_hash: `sha256:${'0'.repeat(64)}`,
    workflow_state: 'attacker',
    revision: 0,
    last_event: 'attacker',
    updated_at: 'not-a-date',
    actor: 'reviewer-readonly-v1',
    extension: 'preserved',
  }));
  assert.equal(reset.revision, 3);
  assert.equal(reset.schema, core.WORKFLOW_SCHEMA);
  assert.equal(reset.schema_version, 1);
  assert.equal(reset.session_id_hash, core.sessionIdHash(RAW_SESSION));
  assert.equal(reset.workflow_state, 'green');
  assert.equal(reset.last_event, 'reset_attempt');
  assert.equal(reset.actor, 'main-v1');
  assert.equal(reset.session_id, undefined);
  assert.equal(reset.extension, 'preserved');

  const jump = core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'review',
    event: 'jump_attempt',
    updatedAt: CREATED_AT,
  }, (state) => ({ ...state, revision: Number.MAX_SAFE_INTEGER }));
  assert.equal(jump.revision, 4);
});

test('fails closed instead of overflowing MAX_SAFE_INTEGER workflow revision', () => {
  const f = fixture();
  const stateDirectory = path.join(f.projectRoot, '.zensu', 'state');
  fs.mkdirSync(stateDirectory, { recursive: true });
  const file = path.join(stateDirectory, `tdd-phase-${core.sessionKey(RAW_SESSION)}.json`);
  const maximum = core.stampWorkflowState(
    { revision: Number.MAX_SAFE_INTEGER - 1 },
    RAW_SESSION,
    'review',
    'maximum_revision',
    CREATED_AT,
  );
  assert.equal(maximum.revision, Number.MAX_SAFE_INTEGER);
  core.atomicWriteJson(file, maximum);
  assert.throws(() => core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'review',
    event: 'overflow_attempt',
    updatedAt: CREATED_AT,
  }), /overflow/i);
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).revision, Number.MAX_SAFE_INTEGER);
  assert.throws(() => core.stampWorkflowState(
    { revision: Number.MAX_SAFE_INTEGER },
    RAW_SESSION,
    'review',
    'overflow_attempt',
    CREATED_AT,
  ), /overflow/i);
});

test('serializes true concurrent workflow mutations without lost revisions', async () => {
  const f = fixture();
  initialize(f);
  const options = {
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'red',
    event: 'parallel_write',
  };
  const source = 'const c=require(process.env.SESSION_CONTROL_CORE);c.transitionWorkflowState(JSON.parse(process.argv[1]));';
  const results = await Promise.all(Array.from({ length: 16 }, () => runNode(source, [JSON.stringify(options)])));
  for (const result of results) assert.equal(result.code, 0, result.stderr);
  assert.equal(core.readWorkflowState({ projectRoot: f.projectRoot, sessionId: RAW_SESSION }).revision, 17);
});

test('fails closed on corrupt workflow JSON instead of resetting revision', () => {
  const f = fixture();
  initialize(f);
  const stateDirectory = path.join(f.projectRoot, '.zensu', 'state');
  fs.mkdirSync(stateDirectory, { recursive: true });
  const file = path.join(stateDirectory, `tdd-phase-${core.sessionKey(RAW_SESSION)}.json`);
  fs.writeFileSync(file, '{broken');
  assert.throws(() => core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'red',
    event: 'must_not_reset',
  }), /invalid JSON/i);
  assert.equal(fs.readFileSync(file, 'utf8'), '{broken');
});

test('stamps host workflow objects with the same revision contract', () => {
  const first = core.stampWorkflowState(
    { session_id: RAW_SESSION, custom: true },
    RAW_SESSION,
    'red_write',
    'phase-red_write',
    CREATED_AT,
  );
  const second = core.stampWorkflowState(first, RAW_SESSION, 'red_fail', 'phase-red_fail', CREATED_AT);
  assert.equal(first.schema, core.WORKFLOW_SCHEMA);
  assert.equal(first.revision, 1);
  assert.equal(second.revision, 2);
  assert.equal(second.custom, true);
  assert.equal(second.session_id, undefined);
  assert.equal(second.session_id_hash, core.sessionIdHash(RAW_SESSION));
  assert.ok(!JSON.stringify(second).includes(RAW_SESSION));
});

test('denies workflow mutation by a reviewer principal', () => {
  const f = fixture();
  assert.throws(
    () => core.transitionWorkflowState({
      projectRoot: f.projectRoot,
      sessionId: RAW_SESSION,
      workflowState: 'red',
      event: 'attack',
      actor: 'reviewer-readonly-v1',
    }),
    /reviewer|principal|denied/i,
  );
});

test('rejects stale workflow compare-and-swap revisions', () => {
  const f = fixture();
  initialize(f);
  core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'red',
    event: 'red-start',
  });
  assert.throws(
    () => core.transitionWorkflowState({
      projectRoot: f.projectRoot,
      sessionId: RAW_SESSION,
      workflowState: 'green',
      event: 'stale',
      expectedRevision: 1,
    }),
    /revision|stale/i,
  );
});

test('isolates workflow state by hashed session key', () => {
  const f = fixture();
  initialize(f, 'one');
  initialize(f, 'two');
  core.transitionWorkflowState({ projectRoot: f.projectRoot, sessionId: 'one', workflowState: 'red', event: 'one' });
  core.transitionWorkflowState({ projectRoot: f.projectRoot, sessionId: 'two', workflowState: 'green', event: 'two' });
  assert.equal(core.readWorkflowState({ projectRoot: f.projectRoot, sessionId: 'one' }).workflow_state, 'red');
  assert.equal(core.readWorkflowState({ projectRoot: f.projectRoot, sessionId: 'two' }).workflow_state, 'green');
});

test('rejects a symlinked workflow state directory', { skip: WINDOWS_SYMLINK_SKIP }, () => {
  const f = fixture();
  const outside = path.join(f.root, 'outside');
  fs.mkdirSync(outside);
  fs.mkdirSync(path.join(f.projectRoot, '.zensu'));
  fs.symlinkSync(outside, path.join(f.projectRoot, '.zensu', 'state'));
  assert.throws(
    () => core.transitionWorkflowState({
      projectRoot: f.projectRoot,
      sessionId: RAW_SESSION,
      workflowState: 'red',
      event: 'unsafe',
    }),
    /symlink/i,
  );
});

test('rejects every explicit workflow state directory override on every host', () => {
  const f = fixture();
  const outside = path.join(f.root, 'override-target');
  fs.mkdirSync(outside);
  // Overrides are rejected by API contract before the candidate path is ever
  // inspected, so this coverage is portable and must also run on Windows.
  for (const stateDirectory of [outside, '.zensu/state', path.join(f.root, 'missing-override')]) {
    assert.throws(() => core.transitionWorkflowState({
      projectRoot: f.projectRoot,
      stateDirectory,
      sessionId: RAW_SESSION,
      workflowState: 'red',
      event: 'unsafe_override',
    }), /overrides are unsupported/i);
    assert.throws(() => core.readWorkflowState({
      projectRoot: f.projectRoot,
      stateDirectory,
      sessionId: RAW_SESSION,
    }), /overrides are unsupported/i);
  }
});

test('refuses workflow mutation when the SessionStart baseline is absent or deleted', () => {
  const f = fixture();
  assert.throws(() => core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'red',
    event: 'missing-baseline',
  }), /baseline is missing/i);
  initialize(f);
  const file = path.join(f.projectRoot, '.zensu', 'state', `tdd-phase-${core.sessionKey(RAW_SESSION)}.json`);
  fs.unlinkSync(file);
  assert.throws(() => core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'red',
    event: 'deleted-baseline',
  }), /baseline is missing/i);
});

test('resets the complete review budget in one expected-revision CAS', () => {
  const f = fixture();
  initialize(f);
  const armed = core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'review_exhausted',
    event: 'seed-review-budget',
  }, (state) => ({
    ...state,
    active: true,
    implComplete: true,
    reviewRound: 4,
    stopBlockCount: 7,
    chainDone: true,
    codeReviewDone: true,
    selfReviewFixed: true,
  }));
  const file = path.join(f.projectRoot, '.zensu', 'state', `tdd-phase-${core.sessionKey(RAW_SESSION)}.json`);
  const beforeStale = fs.readFileSync(file);
  assert.throws(() => core.resetReviewBudget({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    expectedRevision: armed.revision - 1,
  }), /stale workflow revision/i);
  assert.deepEqual(fs.readFileSync(file), beforeStale);

  const reset = core.resetReviewBudget({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    expectedRevision: armed.revision,
  });
  assert.equal(reset.revision, armed.revision + 1);
  assert.equal(reset.workflow_state, 'review_rearmed');
  assert.equal(reset.reviewRound, 0);
  assert.equal(reset.stopBlockCount, 0);
  assert.equal(reset.chainDone, false);
  assert.equal(reset.codeReviewDone, false);
  assert.equal(reset.selfReviewFixed, false);

  const afterReset = fs.readFileSync(file);
  assert.throws(() => core.resetReviewBudget({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    expectedRevision: armed.revision,
  }), /stale workflow revision/i);
  assert.deepEqual(fs.readFileSync(file), afterReset);
});

test('rejects review-budget reset precondition failure without changing bytes', () => {
  const f = fixture();
  initialize(f);
  const incomplete = core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'active',
    event: 'seed-incomplete-workflow',
  }, (state) => ({ ...state, active: true, implComplete: false, reviewRound: 2 }));
  const file = path.join(f.projectRoot, '.zensu', 'state', `tdd-phase-${core.sessionKey(RAW_SESSION)}.json`);
  const before = fs.readFileSync(file);
  assert.throws(() => core.resetReviewBudget({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    expectedRevision: incomplete.revision,
  }), /active completed implementation/i);
  assert.deepEqual(fs.readFileSync(file), before);
});

// The lineage axis is policy, not arithmetic: while major is 0 the MINOR number
// carries the breaking change, so the table below is the contract and not an
// incidental consequence of comparing three integers. A downgrade never
// qualifies in either regime.
test('runtime lineage compatibility follows the declared semver axis', () => {
  const compatible = [
    ['0.17.1', '0.17.2'],
    ['0.17.0', '0.17.0'],
    ['1.2.3', '1.9.0'],
    ['1.2.3', '1.2.3'],
    ['2.0.0', '2.0.1'],
  ];
  const incompatible = [
    ['0.17.2', '0.17.1'],
    ['0.17.2', '0.18.0'],
    ['0.18.0', '0.17.2'],
    ['0.9.2', '0.17.2'],
    ['1.9.0', '1.2.3'],
    ['1.2.3', '2.0.0'],
    ['2.0.0', '1.9.9'],
    ['0.17', '0.17.1'],
    ['0.17.1', '0.17.1-beta'],
    ['0.17.1', '0.17.01'],
    ['0.17.1', 'v0.17.2'],
    ['', '0.17.1'],
    [null, '0.17.1'],
    ['0.17.1', undefined],
    [{ toString: () => '0.17.2' }, '0.17.2'],
  ];
  for (const [recorded, executing] of compatible) {
    assert.equal(
      core.runtimeLineageCompatible(recorded, executing),
      true,
      `${recorded} -> ${executing} must be compatible`,
    );
  }
  for (const [recorded, executing] of incompatible) {
    assert.equal(
      core.runtimeLineageCompatible(recorded, executing),
      false,
      `${JSON.stringify(recorded)} -> ${JSON.stringify(executing)} must be incompatible`,
    );
  }
});

function versionedPluginRoot(parent, version) {
  const root = path.join(parent, version);
  fs.mkdirSync(path.join(root, '.claude-plugin'), { recursive: true });
  fs.writeFileSync(
    path.join(root, '.claude-plugin', 'plugin.json'),
    JSON.stringify({ name: 'zensu', version }),
  );
  return root;
}

// Siblinghood is what keeps the relaxation from reaching a working checkout: a
// development root declaring a compatible version is not beside the cache entry
// it would otherwise adopt, and the executing manifest is the only place the
// executing version may come from.
test('only a compatible sibling installation may serve a record', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-lineage-'));
  const cache = path.join(root, 'cache');
  const elsewhere = path.join(root, 'checkout');
  const recorded = versionedPluginRoot(cache, '0.17.1');
  const patch = versionedPluginRoot(cache, '0.17.2');
  const minor = versionedPluginRoot(cache, '0.18.0');
  const older = versionedPluginRoot(cache, '0.17.0');
  const detached = versionedPluginRoot(elsewhere, '0.17.2');
  const context = { plugin_root: recorded, plugin_version: '0.17.1' };

  assert.equal(core.servesRecordedRuntime(context, recorded, 'claude'), true);
  assert.equal(core.servesRecordedRuntime(context, patch, 'claude'), true);
  assert.equal(core.servesRecordedRuntime(context, minor, 'claude'), false);
  assert.equal(core.servesRecordedRuntime(context, older, 'claude'), false);
  assert.equal(core.servesRecordedRuntime(context, detached, 'claude'), false);

  // The version is read from the manifest, never inferred from the directory
  // name, so a directory renamed to a compatible number changes nothing.
  const masquerade = path.join(cache, '0.17.3');
  fs.mkdirSync(path.join(masquerade, '.claude-plugin'), { recursive: true });
  fs.writeFileSync(
    path.join(masquerade, '.claude-plugin', 'plugin.json'),
    JSON.stringify({ name: 'zensu', version: '0.18.0' }),
  );
  assert.equal(core.servesRecordedRuntime(context, masquerade, 'claude'), false);

  // An unreadable or foreign manifest is a refusal, never an exception that
  // would take a gate's fail-closed branch for the whole session.
  const unmanifested = path.join(cache, '0.17.4');
  fs.mkdirSync(unmanifested, { recursive: true });
  assert.equal(core.servesRecordedRuntime(context, unmanifested, 'claude'), false);
  const foreign = path.join(cache, '0.17.5');
  fs.mkdirSync(path.join(foreign, '.claude-plugin'), { recursive: true });
  fs.writeFileSync(
    path.join(foreign, '.claude-plugin', 'plugin.json'),
    JSON.stringify({ name: 'other', version: '0.17.2' }),
  );
  assert.equal(core.servesRecordedRuntime(context, foreign, 'claude'), false);
  assert.equal(core.servesRecordedRuntime(context, path.join(cache, 'absent'), 'claude'), false);
});

test('creates a schema-versioned trusted attestation', () => {
  const f = fixture();
  const context = register(f);
  initialize(f);
  const state = core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'review',
    event: 'review-start',
    updatedAt: CREATED_AT,
  });
  const attestation = core.createAttestation({
    context,
    state,
    hookSequence: ['SessionStart', 'SubagentStart', 'PreToolUse'],
    reviewerCapabilities: 'reviewer-readonly-v1',
    changedFileHashes: { 'src/example.js': `sha256:${'d'.repeat(64)}` },
    cliVersion: 'test-cli',
    pluginVersion: context.plugin_version,
    exitCode: 0,
  });
  assert.equal(attestation.schema, 'zensu.control-attestation');
  assert.equal(attestation.schema_version, 1);
  assert.equal(attestation.session_id_hash, context.session_id_hash);
  assert.equal(attestation.resolved_plugin_root, context.plugin_root);
  assert.equal(attestation.runtime_digest, context.runtime_digest);
  // AC-012: the runtime that RAN. With no upgrade in play the caller supplies no
  // executing root, so it defaults to the recorded one and the two pairs agree.
  // The divergent case — where they must NOT agree — is asserted separately in
  // "attestations name the executing runtime alongside the bound one".
  assert.equal(attestation.executing_plugin_root, context.plugin_root);
  assert.equal(attestation.executing_runtime_digest, context.runtime_digest);
  assert.equal(attestation.workflow_state, 'review');
  assert.equal(attestation.revision, 2);
  assert.deepEqual(attestation.hook_sequence, ['SessionStart', 'SubagentStart', 'PreToolUse']);
  assert.equal(attestation.exit_code, 0);
  // The key SEQUENCE, not just its length: ATTESTATION_FIELDS is compared by
  // value AND by position on the eval side, so a reorder or an equal-count
  // rename here would pass a count assertion and reject every attestation there.
  const attestationFields = require(path.join(
    __dirname, '..', '..', 'evals', 'session-control', 'lib', 'attestation-common.js',
  )).ATTESTATION_FIELDS;
  assert.deepEqual(Object.keys(attestation), [...attestationFields]);
  assert.equal(Object.keys(attestation).length, 17);
  assert.ok(!JSON.stringify(attestation).includes(RAW_SESSION));
});

// After a compatible upgrade the bound fields and the executing fields name
// different trees, and the executing digest is measured from that tree rather
// than accepted from the caller — there is no option to supply it.
test('rejects incomplete or context-divergent attestations', () => {
  const f = fixture();
  const context = register(f);
  initialize(f);
  const state = core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'review',
    event: 'review_start',
  });
  const valid = {
    context,
    state,
    hookSequence: ['SessionStart'],
    reviewerCapabilities: 'reviewer-readonly-v1',
    changedFileHashes: {},
    cliVersion: 'test-cli',
    exitCode: 0,
  };
  assert.throws(() => core.createAttestation({ ...valid, hookSequence: [] }), /hookSequence/i);
  assert.throws(() => core.createAttestation({ ...valid, reviewerCapabilities: 'main-v1' }), /reviewerCapabilities/i);
  assert.throws(() => core.createAttestation({ ...valid, pluginVersion: 'other' }), /pluginVersion/i);
  assert.throws(() => core.createAttestation({ ...valid, sourceRevision: context.source_revision }), /sourceRevision/i);
  assert.throws(() => core.createAttestation({ ...valid, sourceRevision: 'other' }), /sourceRevision/i);
  assert.throws(() => core.createAttestation({
    ...valid,
    sourceRevisionAuthority: 'verified-runtime-provenance-v1',
  }), /sourceRevisionAuthority/i);
  // AC-012: the executing DIGEST is evidence and a caller may never spell it —
  // it is measured from whichever tree the root names. The ROOT is a caller
  // input, because a wrapper run has to be able to say which tree it installed
  // and ran, but only inside the recorded lineage: a root that is neither the
  // recorded one nor a declared-compatible sibling of it is refused rather than
  // recorded.
  assert.throws(() => core.createAttestation({
    ...valid,
    executingRuntimeDigest: context.runtime_digest,
  }), /executingRuntimeDigest/i);
  assert.throws(() => core.createAttestation({
    ...valid,
    executingPluginRoot: os.tmpdir(),
  }), /runtime lineage/i);
  assert.doesNotThrow(() => core.createAttestation({ ...valid, executingPluginRoot: undefined }));
  assert.throws(() => core.createAttestation({
    ...valid,
    changedFileHashes: { bad: 'sha256:deadbeef' },
  }), /changed file hash/i);
});

test('attestations name the executing runtime alongside the bound one', () => {
  const f = fixture();
  const context = register(f);
  initialize(f);
  const state = core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'review',
    event: 'review-start',
    updatedAt: CREATED_AT,
  });
  const attest = (executingPluginRoot) => core.createAttestation({
    context,
    state,
    executingPluginRoot,
    hookSequence: ['SessionStart'],
    reviewerCapabilities: 'reviewer-readonly-v1',
    changedFileHashes: {},
    cliVersion: 'test-cli',
    exitCode: 0,
  });

  const upgraded = path.join(f.root, 'plugin-next');
  fs.cpSync(f.pluginRoot, upgraded, { recursive: true });
  fs.writeFileSync(
    path.join(upgraded, '.codex-plugin', 'plugin.json'),
    JSON.stringify({ name: 'zensu', version: '9.8.8' }),
  );
  const attestation = attest(upgraded);
  assert.equal(attestation.resolved_plugin_root, context.plugin_root);
  assert.equal(attestation.runtime_digest, context.runtime_digest);
  assert.equal(attestation.plugin_version, context.plugin_version);
  assert.equal(attestation.executing_plugin_root, fs.realpathSync.native(upgraded));
  assert.equal(
    attestation.executing_runtime_digest,
    core.computeRuntimeDigest(upgraded, context.host),
  );
  assert.notEqual(attestation.executing_runtime_digest, context.runtime_digest);
  assert.equal(Object.keys(attestation).length, 17);

  const foreign = path.join(f.root, 'plugin-foreign');
  fs.cpSync(f.pluginRoot, foreign, { recursive: true });
  fs.writeFileSync(
    path.join(foreign, '.codex-plugin', 'plugin.json'),
    JSON.stringify({ name: 'zensu', version: '10.0.0' }),
  );
  assert.throws(() => attest(foreign), /runtime lineage/i);
  assert.throws(() => attest(path.join(f.root, 'absent')), /executingPluginRoot/i);
});

test('FR-002 currentClaudeSessionContext accepts a compatible executing root and refuses a breaking one', () => {
  const f = deferredFixture({ ownerSession: 'lineage-current-context' });
  seedDeferredOwner(f);
  writeDeferredClaim(f);
  const base = { ...inspectDeferredOptions(f), ttlHours: 6 };
  delete base.claimStale;
  const PROVENANCE = /current context provenance does not match the executing runtime/i;

  // Control: the recorded root itself is accepted, so a failure below is about
  // the lineage rule and not about the fixture.
  assert.doesNotThrow(() => core.deferredReviewOwnedByOther(base), PROVENANCE);

  // A minor step forward at a non-zero major is a compatible lineage. The call
  // must get PAST the provenance check — whatever it decides afterwards.
  const compatible = siblingPluginRoot(f, '9.9.0');
  try {
    core.deferredReviewOwnedByOther({ ...base, pluginRoot: compatible });
  } catch (error) {
    assert.doesNotMatch(error.message, PROVENANCE);
  }

  // A major step is breaking, and a downgrade never binds.
  for (const version of ['10.0.0', '9.7.0']) {
    const breaking = siblingPluginRoot(f, version);
    assert.throws(
      () => core.deferredReviewOwnedByOther({ ...base, pluginRoot: breaking }),
      PROVENANCE,
      `executing ${version} must be refused at the provenance check`,
    );
  }

  // A root carrying no zensu manifest cannot be identified, so it is refused
  // rather than answering true through the predicate's swallowed read.
  const hostless = fs.realpathSync.native(
    fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-lineage-hostless-')),
  );
  assert.throws(
    () => core.deferredReviewOwnedByOther({ ...base, pluginRoot: hostless }),
    PROVENANCE,
  );
});

test('preserves prototype-shaped changed filenames in trusted attestations', () => {
  const f = fixture();
  const context = register(f);
  const state = initialize(f);
  const changedFileHashes = Object.fromEntries([
    ['__proto__', `sha256:${'a'.repeat(64)}`],
    ['constructor', `sha256:${'b'.repeat(64)}`],
  ]);
  const attestation = core.createAttestation({
    context,
    state,
    hookSequence: ['SessionStart'],
    reviewerCapabilities: 'reviewer-readonly-v1',
    changedFileHashes,
    cliVersion: 'test-cli',
    exitCode: 0,
  });
  assert.equal(Object.prototype.hasOwnProperty.call(attestation.changed_file_hashes, '__proto__'), true);
  assert.equal(attestation.changed_file_hashes.__proto__, `sha256:${'a'.repeat(64)}`);
  assert.equal(attestation.changed_file_hashes.constructor, `sha256:${'b'.repeat(64)}`);
});

test('serializes concurrent workflow counter increments without lost updates', async () => {
  const f = fixture();
  const stateDirectory = path.join(f.projectRoot, '.zensu', 'state');
  initialize(f);
  core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'active',
    event: 'activate',
  }, (state) => ({ ...state, active: true, stopBlockCount: 0 }));
  const increment = `
    const core = require(process.env.SESSION_CONTROL_CORE);
    core.mutateWorkflowState({
      projectRoot: process.argv[1],
      sessionId: process.argv[2],
      workflowState: 'stop_guard',
      event: 'counter-stop_blocks',
    }, (state) => {
      state.stopBlockCount = (state.stopBlockCount || 0) + 1;
      return state;
    });
  `;
  const results = await Promise.all([
    runNode(increment, [f.projectRoot, RAW_SESSION]),
    runNode(increment, [f.projectRoot, RAW_SESSION]),
  ]);
  assert.deepEqual(results.map((result) => result.code), [0, 0]);
  const final = core.readWorkflowState({ projectRoot: f.projectRoot, sessionId: RAW_SESSION });
  assert.equal(final.stopBlockCount, 2);
  assert.equal(final.revision, 4);
});

test('rejects malformed or out-of-range workflow counters', () => {
  const f = fixture();
  const stateDirectory = path.join(f.projectRoot, '.zensu', 'state');
  initialize(f);
  core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: RAW_SESSION,
    workflowState: 'active',
    event: 'activate',
  }, (state) => ({ ...state, active: true, reviewRound: 0, stopBlockCount: 0 }));
  const file = path.join(stateDirectory, `tdd-phase-${core.sessionKey(RAW_SESSION)}.json`);
  const baseline = JSON.parse(fs.readFileSync(file, 'utf8'));
  for (const value of ['5', -1, 1000001, 1.5]) {
    fs.writeFileSync(file, `${JSON.stringify({ ...baseline, reviewRound: value })}\n`);
    assert.throws(
      () => core.readWorkflowState({ projectRoot: f.projectRoot, sessionId: RAW_SESSION }),
      /reviewRound|bounded non-negative integer/i,
    );
  }
});

test('rejects multi-linked trusted runtime files', () => {
  const f = fixture();
  const manifest = path.join(f.pluginRoot, f.host === 'codex' ? '.codex-plugin' : '.claude-plugin', 'plugin.json');
  fs.linkSync(manifest, path.join(f.root, 'manifest-alias.json'));
  assert.throws(() => core.computeRuntimeDigest(f.pluginRoot, f.host), /multi-linked/i);
});

test('stores Claude contexts in the plugin-data v1 records directory without a host segment', () => {
  const f = fixture('claude');
  assert.equal(
    f.recordsDir,
    path.join(f.pluginData, 'session-control', 'v1', 'records'),
  );
  assert.equal(f.recordsDir.split(path.sep).includes('claude'), false);
});

test('deferred-review cancellation receipts use an exact schema and are exclusive with transfer', () => {
  const valid = deferredFixture({ ownerSession: 'cancellation-schema-valid' });
  const owner = seedDeferredOwner(valid);
  writeDeferredClaim(valid, { cancellation: preparedCancellation(valid, owner.revision) });
  const inspected = core.inspectDeferredReviewOwner(inspectDeferredOptions(valid, {
    currentContextFile: valid.ownerContextFile,
    currentSessionId: valid.ownerSessionId,
  }));
  assert.equal(inspected.status, 'cancelling');

  const invalidReceipts = [
    (f, revision) => ({ ...preparedCancellation(f, revision), extra: true }),
    (f, revision) => ({ ...preparedCancellation(f, revision), mode: 'erase-everything' }),
    (f, revision) => ({
      ...preparedCancellation(f, revision),
      stage: 'state-cleared',
      clearedOwnerRevision: null,
    }),
  ];
  for (const [index, makeReceipt] of invalidReceipts.entries()) {
    const f = deferredFixture({ ownerSession: `cancellation-schema-invalid-${index}` });
    const seeded = seedDeferredOwner(f);
    writeDeferredClaim(f, { cancellation: makeReceipt(f, seeded.revision) });
    assert.throws(
      () => core.inspectDeferredReviewOwner(inspectDeferredOptions(f, {
        currentContextFile: f.ownerContextFile,
        currentSessionId: f.ownerSessionId,
      })),
      /cancellation receipt is invalid/i,
    );
  }

  const exclusive = deferredFixture({ ownerSession: 'cancellation-schema-exclusive' });
  const exclusiveOwner = seedDeferredOwner(exclusive);
  writeDeferredClaim(exclusive, {
    cancellation: preparedCancellation(exclusive, exclusiveOwner.revision),
    transfer: preparedTransfer(exclusive, exclusiveOwner.revision),
  });
  assert.throws(
    () => core.inspectDeferredReviewOwner(inspectDeferredOptions(exclusive)),
    /mutually exclusive|cancellation.*transfer/i,
  );
});

test('cancels an owned deferred claim in release-only mode with one durable state receipt', () => {
  const f = deferredFixture({ ownerSession: 'release-only-cancellation' });
  const owner = seedDeferredOwner(f, {
    reviewTicket: 'rt_keep_this_generation',
    reviewTicketConsumed: false,
    reviewRound: 4,
    stopBlockCount: 13,
    phase: 'GREEN_PASS',
    step_id: 'keep-step',
  });
  writeDeferredClaim(f);
  const options = inspectDeferredOptions(f, {
    currentContextFile: f.ownerContextFile,
    currentSessionId: f.ownerSessionId,
    mode: 'release-only',
  });

  const cancelled = core.cancelDeferredReviewClaim(options);
  assert.equal(cancelled.status, 'cancelled');
  assert.equal(cancelled.claimId, f.claimId);
  assert.equal(cancelled.mode, 'release-only');
  assert.match(cancelled.cancellationId, /^drc_[a-f0-9]{32}$/);
  assert.equal(fs.existsSync(f.claimFile), false);

  const state = core.readWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: f.ownerSessionId,
  });
  assert.equal(state.revision, owner.revision + 1);
  assert.equal(state.last_event, 'deferred-review-release');
  assert.equal(state.workflow_state, owner.workflow_state);
  assert.equal(state.deferredReviewClaim, '');
  for (const field of [
    'active', 'implComplete', 'chainDone', 'codeReviewDone', 'selfReviewFixed',
    'reviewTicket', 'reviewTicketConsumed', 'reviewRound', 'stopBlockCount',
    'phase', 'step_id',
  ]) {
    assert.deepEqual(state[field], owner[field], `release-only must preserve ${field}`);
  }
  assert.deepEqual(state.deferredReviewCancellation, {
    schemaVersion: 1,
    cancellationId: cancelled.cancellationId,
    claimId: f.claimId,
    ownerSessionId: f.ownerSessionId,
    mode: 'release-only',
    origin: 'linked',
    sourceRevision: owner.revision,
    resultRevision: owner.revision + 1,
    resetBinding: null,
  });

  const beforeRepeat = fs.readFileSync(path.join(
    f.stateDirectory,
    `tdd-phase-${f.ownerSessionId}.json`,
  ));
  assert.equal(core.cancelDeferredReviewClaim(options).status, 'absent');
  assert.deepEqual(fs.readFileSync(path.join(
    f.stateDirectory,
    `tdd-phase-${f.ownerSessionId}.json`,
  )), beforeRepeat);
});

test('cancels an owned deferred claim in reset mode to an idle audited state', () => {
  const f = deferredFixture({ ownerSession: 'reset-cancellation' });
  const owner = seedDeferredOwner(f, {
    workflowActive: true,
    workflowTools: ['Bash'],
    bypasses: ['unit-bypass'],
    reviewTicket: 'rt_reset_generation',
    reviewTicketConsumed: false,
    reviewRound: 3,
    stopBlockCount: 7,
    vanilla: true,
    phase: 'GREEN_PASS',
    step_id: 'reset-step',
    history: [{ step: 'reset-step', phase: 'GREEN_PASS' }],
  });
  writeDeferredClaim(f);
  const cancelled = core.cancelDeferredReviewClaim(inspectDeferredOptions(f, {
    currentContextFile: f.ownerContextFile,
    currentSessionId: f.ownerSessionId,
    mode: 'reset',
    resetBinding: null,
  }));
  assert.equal(cancelled.status, 'cancelled');
  assert.equal(cancelled.mode, 'reset');
  assert.equal(fs.existsSync(f.claimFile), false);

  const state = core.readWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: f.ownerSessionId,
  });
  assert.equal(state.revision, owner.revision + 1);
  assert.equal(state.last_event, 'deferred-review-reset');
  assert.equal(state.workflow_state, 'idle');
  assert.equal(state.deferredReviewClaim, '');
  assert.equal(state.active, false);
  assert.equal(state.implComplete, false);
  assert.equal(state.chainDone, false);
  assert.equal(state.codeReviewDone, false);
  assert.equal(state.selfReviewFixed, false);
  assert.equal(state.workflowActive, false);
  assert.deepEqual(state.workflowTools, []);
  assert.deepEqual(state.bypasses, []);
  assert.equal(state.reviewTicket, '');
  assert.equal(state.reviewTicketConsumed, true);
  assert.equal(state.reviewRound, 0);
  assert.equal(state.stopBlockCount, 0);
  assert.equal(state.vanilla, false);
  assert.equal(state.phase, 'UNINITIALIZED');
  assert.equal(state.step_id, '');
  assert.deepEqual(state.history, []);
  assert.equal(state.deferredReviewCancellation.mode, 'reset');
  assert.equal(state.deferredReviewCancellation.sourceRevision, owner.revision);
  assert.equal(state.deferredReviewCancellation.resultRevision, owner.revision + 1);
});

test('owner-only reset cancels an assigned unseeded claim and recovers its prepared receipt', async () => {
  const f = deferredFixture({ ownerSession: 'reset-unseeded-owner' });
  writeDeferredClaim(f, { ownerPid: 2147483647, handoffEmitted: false });
  const ownerOptions = inspectDeferredOptions(f, {
    currentContextFile: f.ownerContextFile,
    currentSessionId: f.ownerSessionId,
    mode: 'reset',
    resetBinding: null,
  });
  assert.equal(core.inspectDeferredReviewOwner(ownerOptions).status, 'unseeded');

  await killDeferredCancellationAt(f, ownerOptions, 'prepared');
  assert.equal(core.inspectDeferredReviewOwner(ownerOptions).status, 'cancelling');
  const recovered = core.cancelDeferredReviewClaim(ownerOptions);
  assert.equal(recovered.status, 'cancelled');
  assert.equal(recovered.mode, 'reset');
  assert.equal(fs.existsSync(f.claimFile), false);
  const state = core.readWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: f.ownerSessionId,
  });
  assert.equal(state.active, false);
  assert.equal(state.deferredReviewClaim, '');
  assert.equal(state.deferredReviewCancellation.sourceRevision, 1);
  assert.equal(state.deferredReviewCancellation.resultRevision, 2);

  const stale = deferredFixture({ ownerSession: 'reset-unseeded-stale-owner' });
  writeDeferredClaim(stale, { ownerPid: 2147483647, handoffEmitted: false });
  const staleOptions = inspectDeferredOptions(stale, {
    currentContextFile: stale.ownerContextFile,
    currentSessionId: stale.ownerSessionId,
    mode: 'reset',
    resetBinding: null,
  });
  await killDeferredCancellationAt(stale, staleOptions, 'prepared');
  assert.equal(JSON.parse(fs.readFileSync(stale.claimFile, 'utf8')).cancellation.origin, 'unseeded');
  core.mutateWorkflowState({
    projectRoot: stale.projectRoot,
    sessionId: stale.ownerSessionId,
    workflowState: 'red',
    event: 'tdd-begin',
    expectedRevision: 1,
  }, (current) => ({ ...current, active: true, implComplete: false }));
  const staleStateFile = path.join(
    stale.stateDirectory,
    `tdd-phase-${stale.ownerSessionId}.json`,
  );
  const freshState = fs.readFileSync(staleStateFile);
  assert.equal(core.inspectDeferredReviewOwner(staleOptions).status, 'cancelling');
  const superseded = core.cancelDeferredReviewClaim(staleOptions);
  assert.equal(superseded.status, 'superseded');
  assert.equal(superseded.ownerRevision, 1);
  assert.equal(superseded.clearedOwnerRevision, 1);
  assert.equal(fs.existsSync(stale.claimFile), false);
  assert.deepEqual(fs.readFileSync(staleStateFile), freshState);

  const relinked = deferredFixture({ ownerSession: 'reset-unseeded-relinked-owner' });
  core.mutateWorkflowState({
    projectRoot: relinked.projectRoot,
    sessionId: relinked.ownerSessionId,
    workflowState: 'review_pending',
    event: 'unit-relink-unseeded-claim',
    expectedRevision: 1,
  }, (current) => ({
    ...current,
    active: true,
    implComplete: true,
    deferredReviewClaim: relinked.claimId,
  }));
  writeDeferredClaim(relinked, {
    ownerPid: 2147483647,
    cancellation: preparedCancellation(relinked, 1, {
      mode: 'reset',
      origin: 'unseeded',
    }),
  });
  const relinkedBefore = fs.readFileSync(relinked.claimFile);
  assert.throws(
    () => core.cancelDeferredReviewClaim(inspectDeferredOptions(relinked, {
      currentContextFile: relinked.ownerContextFile,
      currentSessionId: relinked.ownerSessionId,
      mode: 'reset',
      resetBinding: null,
    })),
    /cancellation state does not match its receipt/i,
  );
  assertClaimBytesUnchanged(relinked, relinkedBefore);

  const incoherent = deferredFixture({ ownerSession: 'reset-unseeded-incoherent-owner' });
  const incoherentStateFile = path.join(
    incoherent.stateDirectory,
    `tdd-phase-${incoherent.ownerSessionId}.json`,
  );
  rewriteJson(incoherentStateFile, (current) => ({
    ...current,
    active: true,
    implComplete: false,
  }));
  writeDeferredClaim(incoherent, {
    ownerPid: 2147483647,
    cancellation: preparedCancellation(incoherent, 1, {
      mode: 'reset',
      origin: 'unseeded',
    }),
  });
  const incoherentBefore = fs.readFileSync(incoherent.claimFile);
  assert.throws(
    () => core.cancelDeferredReviewClaim(inspectDeferredOptions(incoherent, {
      currentContextFile: incoherent.ownerContextFile,
      currentSessionId: incoherent.ownerSessionId,
      mode: 'reset',
      resetBinding: null,
    })),
    /cancellation state does not match its receipt/i,
  );
  assertClaimBytesUnchanged(incoherent, incoherentBefore);

  const acknowledged = deferredFixture({ ownerSession: 'reset-unseeded-acknowledged-owner' });
  core.transitionWorkflowState({
    projectRoot: acknowledged.projectRoot,
    sessionId: acknowledged.ownerSessionId,
    workflowState: 'idle',
    event: 'unit-newer-unlinked-revision',
    expectedRevision: 1,
  });
  writeDeferredClaim(acknowledged, {
    ownerPid: 2147483647,
    handoffEmitted: true,
    cancellation: preparedCancellation(acknowledged, 1, {
      mode: 'reset',
      origin: 'unseeded',
    }),
  });
  const acknowledgedBefore = fs.readFileSync(acknowledged.claimFile);
  assert.throws(
    () => core.cancelDeferredReviewClaim(inspectDeferredOptions(acknowledged, {
      currentContextFile: acknowledged.ownerContextFile,
      currentSessionId: acknowledged.ownerSessionId,
      mode: 'reset',
      resetBinding: null,
    })),
    /cancellation receipt is invalid/i,
  );
  assertClaimBytesUnchanged(acknowledged, acknowledgedBefore);

  const foreign = deferredFixture({ ownerSession: 'reset-unseeded-foreign-owner' });
  writeDeferredClaim(foreign, { ownerPid: 2147483647, handoffEmitted: false });
  const before = fs.readFileSync(foreign.claimFile);
  assert.throws(
    () => core.cancelDeferredReviewClaim({
      ...inspectDeferredOptions(foreign),
      mode: 'reset',
      resetBinding: null,
    }),
    /only the deferred-review owner may cancel/i,
  );
  assertClaimBytesUnchanged(foreign, before);

  const done = deferredFixture({ ownerSession: 'reset-unseeded-done-owner' });
  core.mutateWorkflowState({
    projectRoot: done.projectRoot,
    sessionId: done.ownerSessionId,
    workflowState: 'review_done',
    event: 'unit-unlinked-done-owner',
    expectedRevision: 1,
  }, (current) => ({
    ...current,
    active: true,
    implComplete: true,
    chainDone: true,
    deferredReviewClaim: '',
  }));
  writeDeferredClaim(done, { ownerPid: 2147483647, handoffEmitted: false });
  const doneCancelled = core.cancelDeferredReviewClaim(inspectDeferredOptions(done, {
    currentContextFile: done.ownerContextFile,
    currentSessionId: done.ownerSessionId,
    mode: 'reset',
    resetBinding: null,
  }));
  assert.equal(doneCancelled.status, 'cancelled');
  const resetDoneState = core.readWorkflowState({
    projectRoot: done.projectRoot,
    sessionId: done.ownerSessionId,
  });
  assert.equal(resetDoneState.active, false);
  assert.equal(resetDoneState.chainDone, false);
});

test('reset atomically converts an assigned unseeded target transfer into cancellation', async () => {
  const f = deferredFixture({
    currentSession: 'reset-unseeded-transfer-target',
    ownerSession: 'reset-unseeded-transfer-source',
  });
  const source = seedDeferredOwner(f);
  writeDeferredClaim(f, { ownerPid: 2147483647 });
  const targetOptions = inspectDeferredOptions(f);
  core.prepareDeferredReviewTransfer(targetOptions);
  core.retireDeferredReviewOwner(retireDeferredOptions(f, source.revision));
  core.markDeferredReviewOwnerRetired({
    ...targetOptions,
    expectedRevision: source.revision,
  });
  const assigned = core.assignDeferredReviewClaim(assignDeferredOptions(f));
  assert.equal(assigned.ownerSessionId, f.currentSessionId);
  assert.equal(assigned.transfer.stage, 'owner-retired');
  assert.equal(core.inspectDeferredReviewOwner(targetOptions).status, 'unseeded');

  const cancelled = core.cancelDeferredReviewClaim({
    ...targetOptions,
    mode: 'reset',
    resetBinding: null,
  });
  assert.equal(cancelled.status, 'cancelled');
  assert.equal(cancelled.mode, 'reset');
  assert.equal(fs.existsSync(f.claimFile), false);
  const targetState = core.readWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: f.currentSessionId,
  });
  assert.equal(targetState.active, false);
  assert.equal(targetState.deferredReviewClaim, '');
  assert.equal(targetState.deferredReviewCancellation.claimId, f.claimId);
  assert.equal(targetState.deferredReviewCancellation.ownerSessionId, f.currentSessionId);

  const stale = deferredFixture({
    currentSession: 'reset-stale-transfer-target',
    ownerSession: 'reset-stale-transfer-source',
  });
  const staleSource = seedDeferredOwner(stale);
  writeDeferredClaim(stale, { ownerPid: 2147483647 });
  const staleTargetOptions = inspectDeferredOptions(stale, {
    mode: 'reset',
    resetBinding: null,
  });
  core.prepareDeferredReviewTransfer(staleTargetOptions);
  core.retireDeferredReviewOwner(retireDeferredOptions(stale, staleSource.revision));
  core.markDeferredReviewOwnerRetired({
    ...staleTargetOptions,
    expectedRevision: staleSource.revision,
  });
  core.assignDeferredReviewClaim(assignDeferredOptions(stale));
  await killDeferredCancellationAt(stale, staleTargetOptions, 'prepared');
  const staleReceipt = JSON.parse(fs.readFileSync(stale.claimFile, 'utf8'));
  assert.equal(staleReceipt.transfer, undefined);
  assert.equal(staleReceipt.cancellation.origin, 'unseeded');
  core.mutateWorkflowState({
    projectRoot: stale.projectRoot,
    sessionId: stale.currentSessionId,
    workflowState: 'red',
    event: 'tdd-begin',
    expectedRevision: 1,
  }, (current) => ({ ...current, active: true, implComplete: false }));
  const staleTargetStateFile = path.join(
    stale.stateDirectory,
    `tdd-phase-${stale.currentSessionId}.json`,
  );
  const staleTargetState = fs.readFileSync(staleTargetStateFile);
  const staleRecovered = core.cancelDeferredReviewClaim(staleTargetOptions);
  assert.equal(staleRecovered.status, 'superseded');
  assert.equal(staleRecovered.ownerRevision, 1);
  assert.equal(fs.existsSync(stale.claimFile), false);
  assert.deepEqual(fs.readFileSync(staleTargetStateFile), staleTargetState);
});

test('binds a deferred cancellation state marker to the exact owner state', () => {
  const f = deferredFixture({ ownerSession: 'cancellation-marker-owner-binding' });
  seedDeferredOwner(f);
  writeDeferredClaim(f);
  core.cancelDeferredReviewClaim(inspectDeferredOptions(f, {
    currentContextFile: f.ownerContextFile,
    currentSessionId: f.ownerSessionId,
    mode: 'release-only',
  }));
  const stateFile = path.join(f.stateDirectory, `tdd-phase-${f.ownerSessionId}.json`);
  rewriteJson(stateFile, (state) => {
    state.deferredReviewCancellation.ownerSessionId = f.currentSessionId;
    return state;
  });
  assert.throws(
    () => core.readWorkflowState({ projectRoot: f.projectRoot, sessionId: f.ownerSessionId }),
    /deferredReviewCancellation marker is invalid/i,
  );
});

test('recovers each deferred cancellation killpoint and preserves later legitimate state revisions', async () => {
  for (const killpoint of ['prepared', 'state-cas', 'state-cleared']) {
    const f = deferredFixture({ ownerSession: `cancellation-killpoint-${killpoint}` });
    seedDeferredOwner(f, { reviewTicket: `rt_${killpoint}`, reviewTicketConsumed: false });
    writeDeferredClaim(f);
    const options = inspectDeferredOptions(f, {
      currentContextFile: f.ownerContextFile,
      currentSessionId: f.ownerSessionId,
      mode: 'release-only',
    });
    await killDeferredCancellationAt(f, options, killpoint);

    const crashedClaim = JSON.parse(fs.readFileSync(f.claimFile, 'utf8'));
    assert.ok(crashedClaim.cancellation, `${killpoint} must leave a durable receipt`);
    if (killpoint === 'state-cas') {
      const afterCas = core.readWorkflowState({
        projectRoot: f.projectRoot,
        sessionId: f.ownerSessionId,
      });
      assert.equal(afterCas.deferredReviewClaim, '');
      assert.ok(afterCas.deferredReviewCancellation);
      core.transitionWorkflowState({
        projectRoot: f.projectRoot,
        sessionId: f.ownerSessionId,
        workflowState: afterCas.workflow_state,
        event: 'unit-legitimate-post-cancel-revision',
        expectedRevision: afterCas.revision,
      });
    }

    const inspected = core.inspectDeferredReviewOwner({ ...options, claimStale: false });
    assert.equal(
      inspected.status,
      killpoint === 'prepared' ? 'cancelling' : 'cancelled',
    );
    const recovered = core.cancelDeferredReviewClaim(options);
    assert.equal(recovered.status, 'cancelled');
    assert.equal(fs.existsSync(f.claimFile), false);
    const final = core.readWorkflowState({
      projectRoot: f.projectRoot,
      sessionId: f.ownerSessionId,
    });
    assert.equal(final.deferredReviewClaim, '');
    assert.equal(final.deferredReviewCancellation.cancellationId, recovered.cancellationId);
  }
});

test('rebases a prepared deferred cancellation receipt after a legitimate linked-state revision', async () => {
  const f = deferredFixture({ ownerSession: 'cancellation-prepared-rebase' });
  const owner = seedDeferredOwner(f);
  writeDeferredClaim(f);
  const options = inspectDeferredOptions(f, {
    currentContextFile: f.ownerContextFile,
    currentSessionId: f.ownerSessionId,
    mode: 'release-only',
  });
  await killDeferredCancellationAt(f, options, 'prepared');
  const advanced = core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: f.ownerSessionId,
    workflowState: owner.workflow_state,
    event: 'unit-legitimate-prepared-revision',
    expectedRevision: owner.revision,
  });
  const recovered = core.cancelDeferredReviewClaim(options);
  assert.equal(recovered.ownerRevision, advanced.revision);
  assert.equal(recovered.clearedOwnerRevision, advanced.revision + 1);
  assert.equal(fs.existsSync(f.claimFile), false);
});

test('allows a related foreign principal to remove an exact post-CAS cancellation receipt', async () => {
  const f = deferredFixture({ ownerSession: 'cancellation-foreign-recovery' });
  seedDeferredOwner(f);
  writeDeferredClaim(f);
  const ownerOptions = inspectDeferredOptions(f, {
    currentContextFile: f.ownerContextFile,
    currentSessionId: f.ownerSessionId,
    mode: 'release-only',
  });
  await killDeferredCancellationAt(f, ownerOptions, 'state-cas');

  const foreignOptions = inspectDeferredOptions(f);
  const inspected = core.inspectDeferredReviewOwner(foreignOptions);
  assert.equal(inspected.status, 'cancelled');
  const cleared = core.clearTerminalDeferredReviewClaim(foreignOptions);
  assert.equal(cleared.status, 'cancelled');
  assert.equal(cleared.claimId, f.claimId);
  assert.equal(fs.existsSync(f.claimFile), false);
});

test('allows a related foreign principal to resume but never initiate cancellation', async () => {
  const f = deferredFixture({ ownerSession: 'cancellation-foreign-resume' });
  seedDeferredOwner(f);
  writeDeferredClaim(f);
  const ownerOptions = inspectDeferredOptions(f, {
    currentContextFile: f.ownerContextFile,
    currentSessionId: f.ownerSessionId,
    mode: 'release-only',
  });
  await killDeferredCancellationAt(f, ownerOptions, 'prepared');
  const pending = core.inspectDeferredReviewOwner(inspectDeferredOptions(f));
  assert.equal(pending.status, 'cancelling');
  const resumed = core.cancelDeferredReviewClaim({
    ...inspectDeferredOptions(f),
    mode: 'release-only',
  });
  assert.equal(resumed.status, 'cancelled');
  assert.equal(fs.existsSync(f.claimFile), false);

  const notPrepared = deferredFixture({ ownerSession: 'cancellation-foreign-initiate' });
  seedDeferredOwner(notPrepared);
  writeDeferredClaim(notPrepared);
  const before = fs.readFileSync(notPrepared.claimFile);
  assert.throws(
    () => core.cancelDeferredReviewClaim({
      ...inspectDeferredOptions(notPrepared),
      mode: 'release-only',
    }),
    /only the deferred-review owner may cancel/i,
  );
  assertClaimBytesUnchanged(notPrepared, before);
});

test('deferred-review inspection distinguishes current, live-owned, and dead-owner transfer states', () => {
  const live = deferredFixture({ ownerSession: 'live-owner' });
  const liveState = seedDeferredOwner(live);
  writeDeferredClaim(live);
  const owned = core.inspectDeferredReviewOwner(inspectDeferredOptions(live));
  assert.equal(owned.status, 'owned');
  assert.equal(owned.ownerRevision, liveState.revision);
  assert.equal(owned.claim.ownerSessionId, live.ownerSessionId);

  const current = core.inspectDeferredReviewOwner(inspectDeferredOptions(live, {
    currentContextFile: live.ownerContextFile,
    currentSessionId: live.ownerSessionId,
  }));
  assert.equal(current.status, 'current');
  assert.equal(current.ownerRevision, liveState.revision);

  const dead = deferredFixture({ ownerSession: 'dead-owner' });
  const deadState = seedDeferredOwner(dead);
  writeDeferredClaim(dead, { ownerPid: 2147483647 });
  const transferable = core.inspectDeferredReviewOwner(inspectDeferredOptions(dead));
  assert.equal(transferable.status, 'transfer');
  assert.equal(transferable.ownerRevision, deadState.revision);
});

test('handoff claims stay owned until both the process is dead and the claim is stale', () => {
  const live = deferredFixture({ ownerSession: 'live-stale-handoff-owner' });
  const liveOwner = seedDeferredOwner(live);
  writeDeferredClaim(live, {
    ownerPid: process.pid,
    ownerProcessStartIdentity: currentProcessStartIdentity(),
    handoffEmitted: true,
  });
  const liveAndStale = core.inspectDeferredReviewOwner(inspectDeferredOptions(
    live,
    { claimStale: true },
  ));
  assert.equal(liveAndStale.status, 'owned');
  assert.equal(liveAndStale.ownerRevision, liveOwner.revision);

  const f = deferredFixture();
  const owner = seedDeferredOwner(f);
  writeDeferredClaim(f, {
    ownerPid: 2147483647,
    handoffEmitted: true,
  });
  const fresh = core.inspectDeferredReviewOwner(inspectDeferredOptions(f));
  assert.equal(fresh.status, 'owned');
  assert.equal(fresh.ownerRevision, owner.revision);
  const stale = core.inspectDeferredReviewOwner(inspectDeferredOptions(f, { claimStale: true }));
  assert.equal(stale.status, 'transfer');
  assert.equal(stale.ownerRevision, owner.revision);
});

test('read-only foreign deferred ownership accepts only a live owner or fresh handoff', () => {
  const ownedOptions = (fixtureValue, overrides = {}) => {
    const options = inspectDeferredOptions(fixtureValue);
    delete options.claimStale;
    return { ...options, ttlHours: 6, ...overrides };
  };
  const live = deferredFixture({ ownerSession: 'read-only-live-owner' });
  seedDeferredOwner(live);
  writeDeferredClaim(live);
  const liveStateFile = path.join(
    live.stateDirectory,
    `tdd-phase-${live.ownerSessionId}.json`,
  );
  const liveClaimBefore = fs.readFileSync(live.claimFile);
  const liveStateBefore = fs.readFileSync(liveStateFile);
  assert.equal(
    core.deferredReviewOwnedByOther(ownedOptions(live)),
    true,
  );
  assert.deepEqual(fs.readFileSync(live.claimFile), liveClaimBefore);
  assert.deepEqual(fs.readFileSync(liveStateFile), liveStateBefore);

  const assignmentWindow = deferredFixture({ ownerSession: 'read-only-assignment-window' });
  writeDeferredClaim(assignmentWindow);
  assert.equal(
    core.deferredReviewOwnedByOther(ownedOptions(assignmentWindow)),
    true,
  );

  const freshHandoff = deferredFixture({ ownerSession: 'read-only-fresh-handoff' });
  seedDeferredOwner(freshHandoff);
  writeDeferredClaim(freshHandoff, {
    ownerPid: 2147483647,
    handoffEmitted: true,
  });
  assert.equal(
    core.deferredReviewOwnedByOther(ownedOptions(freshHandoff)),
    true,
  );

  const staleHandoff = deferredFixture({ ownerSession: 'read-only-stale-handoff' });
  seedDeferredOwner(staleHandoff);
  writeDeferredClaim(staleHandoff, {
    ownerPid: 2147483647,
    handoffEmitted: true,
    ts: '2000-01-01T00:00:00Z',
  });
  assert.equal(
    core.deferredReviewOwnedByOther(ownedOptions(staleHandoff)),
    false,
  );

  const deadUnacknowledged = deferredFixture({ ownerSession: 'read-only-dead-unacknowledged' });
  seedDeferredOwner(deadUnacknowledged);
  writeDeferredClaim(deadUnacknowledged, { ownerPid: 2147483647 });
  assert.equal(
    core.deferredReviewOwnedByOther(ownedOptions(deadUnacknowledged)),
    false,
  );

  const current = deferredFixture({ ownerSession: 'read-only-current-owner' });
  seedDeferredOwner(current);
  writeDeferredClaim(current);
  assert.equal(
    core.deferredReviewOwnedByOther(ownedOptions(current, {
      currentContextFile: current.ownerContextFile,
      currentSessionId: current.ownerSessionId,
    })),
    false,
  );

  const done = deferredFixture({ ownerSession: 'read-only-done-owner' });
  seedDeferredOwner(done, { chainDone: true });
  writeDeferredClaim(done, { handoffEmitted: true });
  assert.equal(
    core.deferredReviewOwnedByOther(ownedOptions(done)),
    false,
  );

  const transferring = deferredFixture({ ownerSession: 'read-only-transfer-owner' });
  const transferState = seedDeferredOwner(transferring);
  writeDeferredClaim(transferring, {
    transfer: preparedTransfer(transferring, transferState.revision),
  });
  const transferClaimBefore = fs.readFileSync(transferring.claimFile);
  assert.equal(
    core.deferredReviewOwnedByOther(ownedOptions(transferring)),
    false,
  );
  assert.deepEqual(fs.readFileSync(transferring.claimFile), transferClaimBefore);

  const cancelling = deferredFixture({ ownerSession: 'read-only-cancellation-owner' });
  const cancellationState = seedDeferredOwner(cancelling);
  writeDeferredClaim(cancelling, {
    cancellation: preparedCancellation(cancelling, cancellationState.revision),
  });
  const cancellationClaimBefore = fs.readFileSync(cancelling.claimFile);
  assert.equal(
    core.deferredReviewOwnedByOther(ownedOptions(cancelling)),
    false,
  );
  assert.deepEqual(fs.readFileSync(cancelling.claimFile), cancellationClaimBefore);
});

test('process start identity prevents a live PID reuse from retaining a deferred claim', (t) => {
  const actualIdentity = currentProcessStartIdentity();
  if (!actualIdentity) {
    t.skip('this platform does not expose a portable process start identity');
    return;
  }
  const f = deferredFixture();
  seedDeferredOwner(f);
  writeDeferredClaim(f, {
    ownerPid: process.pid,
    ownerProcessStartIdentity: 'linux:deliberately-mismatched:1',
  });
  assert.equal(core.inspectDeferredReviewOwner(inspectDeferredOptions(f)).status, 'transfer');
});

test('deferred-review inspection reports done, cancelled, and never-seeded owners explicitly', () => {
  const done = deferredFixture({ ownerSession: 'done-owner' });
  const doneState = seedDeferredOwner(done, { chainDone: true });
  writeDeferredClaim(done, { ownerPid: 2147483647 });
  const completed = core.inspectDeferredReviewOwner(inspectDeferredOptions(done));
  assert.equal(completed.status, 'done');
  assert.equal(completed.ownerRevision, doneState.revision);

  const cancelled = deferredFixture({ ownerSession: 'cancelled-owner' });
  writeDeferredClaim(cancelled, { handoffEmitted: true });
  const cancelledResult = core.inspectDeferredReviewOwner(inspectDeferredOptions(cancelled));
  assert.equal(cancelledResult.status, 'cancelled');
  assert.equal(cancelledResult.ownerRevision, 1);

  const unseeded = deferredFixture({ ownerSession: 'unseeded-owner' });
  writeDeferredClaim(unseeded, { ownerPid: 2147483647 });
  const unseededResult = core.inspectDeferredReviewOwner(inspectDeferredOptions(unseeded));
  assert.equal(unseededResult.status, 'unseeded');
  assert.equal(unseededResult.ownerRevision, 1);
});

test('mismatched live owner state fails closed and preserves exact claim bytes', () => {
  const f = deferredFixture();
  core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: f.ownerSessionId,
    workflowState: 'red',
    event: 'unit-mismatched-owner',
    expectedRevision: 1,
  }, (state) => ({ ...state, active: true, implComplete: false }));
  writeDeferredClaim(f);
  const before = fs.readFileSync(f.claimFile);
  assert.throws(
    () => core.inspectDeferredReviewOwner(inspectDeferredOptions(f)),
    /does not match.*workflow state/i,
  );
  assertClaimBytesUnchanged(f, before);
});

test('deferred-review APIs require canonical current and owner principals', () => {
  const rawCurrent = deferredFixture({ ownerSession: 'canonical-owner-one' });
  seedDeferredOwner(rawCurrent);
  writeDeferredClaim(rawCurrent, { ownerPid: 2147483647 });
  const currentBefore = fs.readFileSync(rawCurrent.claimFile);
  assert.throws(
    () => core.inspectDeferredReviewOwner(inspectDeferredOptions(rawCurrent, {
      currentSessionId: 'raw-current-principal',
    })),
    /current session id.*canonical/i,
  );
  assertClaimBytesUnchanged(rawCurrent, currentBefore);

  const rawOwner = deferredFixture({ ownerSession: 'canonical-owner-two' });
  seedDeferredOwner(rawOwner);
  writeDeferredClaim(rawOwner, {
    ownerSessionId: 'raw-owner-principal',
    ownerPid: 2147483647,
  });
  const ownerBefore = fs.readFileSync(rawOwner.claimFile);
  assert.throws(
    () => core.inspectDeferredReviewOwner(inspectDeferredOptions(rawOwner)),
    /deferred-review owner.*canonical/i,
  );
  assertClaimBytesUnchanged(rawOwner, ownerBefore);
});

test('deferred-review inspection binds exact Claude provenance and preserves the claim on mismatch', () => {
  const cases = [
    {
      label: 'executing runtime digest',
      prepare(f, options) { options.runtimeDigest = `sha256:${'0'.repeat(64)}`; },
      pattern: /provenance.*runtime|executing runtime/i,
    },
    {
      label: 'executing plugin root',
      prepare(f, options) {
        const other = path.join(f.root, 'other-executing-plugin');
        fs.mkdirSync(other);
        options.pluginRoot = other;
      },
      pattern: /provenance.*runtime|executing runtime/i,
    },
    {
      label: 'current project root',
      prepare(f) {
        const other = path.join(f.root, 'other-current-project');
        fs.mkdirSync(other);
        rewriteJson(f.currentContextFile, (context) => ({
          ...context,
          project_root: fs.realpathSync.native(other),
        }));
      },
      pattern: /provenance.*runtime|executing runtime/i,
    },
    {
      label: 'owner project root',
      prepare(f) {
        const other = path.join(f.root, 'other-owner-project');
        fs.mkdirSync(other);
        rewriteJson(f.ownerContextFile, (context) => ({
          ...context,
          project_root: fs.realpathSync.native(other),
        }));
      },
      pattern: /owner context project_root.*current context/i,
    },
    {
      label: 'owner plugin data',
      prepare(f) {
        const other = path.join(f.root, 'other-owner-plugin-data');
        fs.mkdirSync(other);
        rewriteJson(f.ownerContextFile, (context) => ({
          ...context,
          plugin_data: fs.realpathSync.native(other),
        }));
      },
      pattern: /owner context plugin_data.*current context/i,
    },
    {
      label: 'owner host',
      prepare(f) {
        rewriteJson(f.ownerContextFile, (context) => ({ ...context, host: 'codex' }));
      },
      pattern: /context host mismatch/i,
    },
    {
      label: 'owner principal profiles',
      prepare(f) {
        rewriteJson(f.ownerContextFile, (context) => ({
          ...context,
          principal_profiles: { ...context.principal_profiles, extension: 'forged' },
        }));
      },
      pattern: /principal profiles.*current context/i,
    },
  ];

  for (const testCase of cases) {
    const f = deferredFixture({ ownerSession: `provenance-${testCase.label}` });
    seedDeferredOwner(f);
    writeDeferredClaim(f, { ownerPid: 2147483647 });
    const options = inspectDeferredOptions(f);
    testCase.prepare(f, options);
    const before = fs.readFileSync(f.claimFile);
    assert.throws(
      () => core.inspectDeferredReviewOwner(options),
      testCase.pattern,
      testCase.label,
    );
    assertClaimBytesUnchanged(f, before);
  }
});

test('rejects the retired host-segment Claude records path without changing the claim', () => {
  const f = deferredFixture({ legacyHostSegment: true });
  seedDeferredOwner(f);
  writeDeferredClaim(f, { ownerPid: 2147483647 });
  const before = fs.readFileSync(f.claimFile);
  assert.throws(
    () => core.inspectDeferredReviewOwner(inspectDeferredOptions(f)),
    /records directory is outside current Claude plugin data/i,
  );
  assertClaimBytesUnchanged(f, before);
});

test('rejects multi-linked current and owner context records without changing the claim', () => {
  for (const role of ['current', 'owner']) {
    const f = deferredFixture({ ownerSession: `multi-link-${role}` });
    seedDeferredOwner(f);
    writeDeferredClaim(f, { ownerPid: 2147483647 });
    const contextFile = role === 'current' ? f.currentContextFile : f.ownerContextFile;
    fs.linkSync(contextFile, path.join(f.root, `${role}-context-alias.json`));
    const before = fs.readFileSync(f.claimFile);
    assert.throws(
      () => core.inspectDeferredReviewOwner(inspectDeferredOptions(f)),
      /multi-link|unsafe/i,
      role,
    );
    assertClaimBytesUnchanged(f, before);
  }
});

test('rejects a symlinked current context record without changing the claim', {
  skip: WINDOWS_SYMLINK_SKIP,
}, () => {
  const f = deferredFixture();
  seedDeferredOwner(f);
  writeDeferredClaim(f, { ownerPid: 2147483647 });
  const target = path.join(f.root, 'current-context-target.json');
  fs.renameSync(f.currentContextFile, target);
  fs.symlinkSync(target, f.currentContextFile);
  const before = fs.readFileSync(f.claimFile);
  assert.throws(
    () => core.inspectDeferredReviewOwner(inspectDeferredOptions(f)),
    /current context file is unsafe|symlink/i,
  );
  assertClaimBytesUnchanged(f, before);
});

test('rejects a multi-linked claim artifact fail closed', () => {
  const multi = deferredFixture({ ownerSession: 'multi-linked-claim' });
  seedDeferredOwner(multi);
  writeDeferredClaim(multi, { ownerPid: 2147483647 });
  fs.linkSync(multi.claimFile, path.join(multi.root, 'claim-alias.json'));
  const multiBefore = fs.readFileSync(multi.claimFile);
  assert.throws(
    () => core.inspectDeferredReviewOwner(inspectDeferredOptions(multi)),
    /multi-linked/i,
  );
  assertClaimBytesUnchanged(multi, multiBefore);
});

test('rejects a symlinked claim artifact fail closed', {
  skip: WINDOWS_SYMLINK_SKIP,
}, () => {
  const linked = deferredFixture({ ownerSession: 'symlinked-claim' });
  seedDeferredOwner(linked);
  writeDeferredClaim(linked, { ownerPid: 2147483647 });
  const target = path.join(linked.root, 'claim-target.json');
  fs.renameSync(linked.claimFile, target);
  fs.symlinkSync(target, linked.claimFile);
  const targetBefore = fs.readFileSync(target);
  assert.throws(
    () => core.inspectDeferredReviewOwner(inspectDeferredOptions(linked)),
    /claim path is invalid|symlink/i,
  );
  assert.deepEqual(fs.readFileSync(target), targetBefore);
});

test('validates prepared transfer receipts and preserves malformed receipt bytes', () => {
  const valid = deferredFixture({ ownerSession: 'valid-transfer-receipt' });
  const validOwner = seedDeferredOwner(valid);
  writeDeferredClaim(valid, {
    ownerPid: 2147483647,
    transfer: preparedTransfer(valid, validOwner.revision),
  });
  const inspected = core.inspectDeferredReviewOwner(inspectDeferredOptions(valid));
  assert.equal(inspected.status, 'transfer');
  assert.deepEqual(inspected.claim.transfer, preparedTransfer(valid, validOwner.revision));

  const malformedReceipts = [
    {
      label: 'extra key',
      build(f, revision) { return preparedTransfer(f, revision, { extra: true }); },
      pattern: /transfer receipt is invalid/i,
    },
    {
      label: 'claim id mismatch',
      build(f, revision) { return preparedTransfer(f, revision, { claimId: 'dc_other_claim' }); },
      pattern: /transfer receipt is invalid/i,
    },
    {
      label: 'raw target owner',
      build(f, revision) { return preparedTransfer(f, revision, { toOwnerSessionId: 'raw-target-owner' }); },
      pattern: /transfer target owner.*canonical/i,
    },
    {
      label: 'same source and target',
      build(f, revision) { return preparedTransfer(f, revision, { toOwnerSessionId: f.ownerSessionId }); },
      pattern: /ownership is inconsistent/i,
    },
    {
      label: 'unknown stage',
      build(f, revision) { return preparedTransfer(f, revision, { stage: 'committed' }); },
      pattern: /transfer receipt is invalid/i,
    },
    {
      label: 'wrong retired revision',
      build(f, revision) {
        return preparedTransfer(f, revision, {
          stage: 'owner-retired',
          retiredOwnerRevision: revision,
        });
      },
      pattern: /transfer receipt is invalid/i,
    },
  ];
  for (const testCase of malformedReceipts) {
    const f = deferredFixture({ ownerSession: `malformed-${testCase.label}` });
    const owner = seedDeferredOwner(f);
    writeDeferredClaim(f, {
      ownerPid: 2147483647,
      transfer: testCase.build(f, owner.revision),
    });
    const before = fs.readFileSync(f.claimFile);
    assert.throws(
      () => core.inspectDeferredReviewOwner(inspectDeferredOptions(f)),
      testCase.pattern,
      testCase.label,
    );
    assertClaimBytesUnchanged(f, before);
  }
});

test('runs the complete durable transfer receipt lifecycle through finalization', () => {
  const f = deferredFixture();
  const owner = seedDeferredOwner(f);
  writeDeferredClaim(f, { ownerPid: 2147483647 });

  const prepared = core.prepareDeferredReviewTransfer(inspectDeferredOptions(f));
  assert.deepEqual(prepared.transfer, preparedTransfer(f, owner.revision));
  const preparedBytes = fs.readFileSync(f.claimFile);
  assert.deepEqual(
    core.prepareDeferredReviewTransfer(inspectDeferredOptions(f)),
    prepared,
  );
  assertClaimBytesUnchanged(f, preparedBytes);

  const retired = core.retireDeferredReviewOwner(retireDeferredOptions(f, owner.revision));
  assert.equal(retired.revision, owner.revision + 1);
  const acknowledged = core.markDeferredReviewOwnerRetired({
    ...inspectDeferredOptions(f),
    expectedRevision: owner.revision,
  });
  assert.equal(acknowledged.transfer.stage, 'owner-retired');
  assert.equal(acknowledged.transfer.retiredOwnerRevision, retired.revision);
  const acknowledgedBytes = fs.readFileSync(f.claimFile);
  assert.deepEqual(core.markDeferredReviewOwnerRetired({
    ...inspectDeferredOptions(f),
    expectedRevision: owner.revision,
  }), acknowledged);
  assertClaimBytesUnchanged(f, acknowledgedBytes);

  const assigned = core.assignDeferredReviewClaim(assignDeferredOptions(f));
  assert.equal(assigned.ownerSessionId, f.currentSessionId);
  assert.equal(assigned.ownerPid, process.pid);
  assert.equal(assigned.handoffEmitted, false);
  assert.equal(assigned.transfer.stage, 'owner-retired');
  assert.equal(assigned.transfer.toOwnerSessionId, f.currentSessionId);

  const current = core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: f.currentSessionId,
    workflowState: 'review_pending',
    event: 'unit-seed-transfer-target',
    expectedRevision: 1,
  }, (state) => ({
    ...state,
    active: true,
    implComplete: true,
    chainDone: false,
    deferredReviewClaim: assigned.claimId,
  }));
  const finalized = core.finalizeDeferredReviewTransfer(inspectDeferredOptions(f));
  assert.equal(finalized.ownerSessionId, f.currentSessionId);
  assert.equal(finalized.transfer, undefined);
  const finalizedBytes = fs.readFileSync(f.claimFile);
  assert.deepEqual(core.finalizeDeferredReviewTransfer(inspectDeferredOptions(f)), finalized);
  assertClaimBytesUnchanged(f, finalizedBytes);
  core.acknowledgeDeferredReviewHandoff({
    ...inspectDeferredOptions(f),
    ownerPid: process.pid,
    logStyle: 'none',
  });

  const done = core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: f.currentSessionId,
    workflowState: 'review_done',
    event: 'unit-complete-transfer-target',
    expectedRevision: current.revision,
  }, (state) => ({ ...state, chainDone: true }));
  const cleared = core.clearTerminalDeferredReviewClaim(inspectDeferredOptions(f));
  assert.deepEqual(cleared, {
    status: 'done',
    claimId: finalized.claimId,
    resultingOwnerRevision: done.revision + 1,
  });
  assert.equal(fs.existsSync(f.claimFile), false);
});

test('never cancels a transfer source or target before exact finalization', () => {
  const source = deferredFixture({ ownerSession: 'cancellation-transfer-source' });
  const sourceOwner = seedDeferredOwner(source);
  writeDeferredClaim(source, {
    ownerPid: 2147483647,
    transfer: preparedTransfer(source, sourceOwner.revision),
  });
  const sourceBefore = fs.readFileSync(source.claimFile);
  assert.throws(
    () => core.cancelDeferredReviewClaim(inspectDeferredOptions(source, {
      currentContextFile: source.ownerContextFile,
      currentSessionId: source.ownerSessionId,
      mode: 'release-only',
    })),
    /transfer must be finalized before cancellation/i,
  );
  assertClaimBytesUnchanged(source, sourceBefore);

  const target = deferredFixture({ ownerSession: 'cancellation-transfer-target' });
  const targetOwner = seedDeferredOwner(target);
  writeDeferredClaim(target, { ownerPid: 2147483647 });
  core.prepareDeferredReviewTransfer(inspectDeferredOptions(target));
  core.retireDeferredReviewOwner(retireDeferredOptions(target, targetOwner.revision));
  core.markDeferredReviewOwnerRetired({
    ...inspectDeferredOptions(target),
    expectedRevision: targetOwner.revision,
  });
  const assigned = core.assignDeferredReviewClaim(assignDeferredOptions(target));
  core.mutateWorkflowState({
    projectRoot: target.projectRoot,
    sessionId: target.currentSessionId,
    workflowState: 'review_pending',
    event: 'unit-seed-cancellation-transfer-target',
    expectedRevision: 1,
  }, (state) => ({
    ...state,
    active: true,
    implComplete: true,
    chainDone: false,
    deferredReviewClaim: assigned.claimId,
  }));
  const targetBefore = fs.readFileSync(target.claimFile);
  assert.throws(
    () => core.cancelDeferredReviewClaim({
      ...inspectDeferredOptions(target),
      mode: 'release-only',
    }),
    /transfer must be finalized before cancellation/i,
  );
  assertClaimBytesUnchanged(target, targetBefore);

  core.finalizeDeferredReviewTransfer(inspectDeferredOptions(target));
  const cancelled = core.cancelDeferredReviewClaim({
    ...inspectDeferredOptions(target),
    mode: 'release-only',
  });
  assert.equal(cancelled.status, 'cancelled');
  assert.equal(fs.existsSync(target.claimFile), false);
});

test('requires the exact reset binding before cancelling a bound deferred claim', () => {
  const f = deferredFixture({ ownerSession: 'cancellation-reset-binding' });
  seedDeferredOwner(f, {
    autopilotRunId: 'run-reset-binding',
    autopilotAttempt: 2,
    autopilotReturnStage: 'GATES',
    chainId: 'chain-reset-binding',
  });
  writeDeferredClaim(f);
  const base = inspectDeferredOptions(f, {
    currentContextFile: f.ownerContextFile,
    currentSessionId: f.ownerSessionId,
    mode: 'reset',
  });
  const before = fs.readFileSync(f.claimFile);
  assert.throws(
    () => core.cancelDeferredReviewClaim({ ...base, resetBinding: null }),
    /reset binding does not match owner state/i,
  );
  assertClaimBytesUnchanged(f, before);
  const cancelled = core.cancelDeferredReviewClaim({
    ...base,
    resetBinding: {
      runId: 'run-reset-binding',
      attempt: 2,
      chainId: 'chain-reset-binding',
    },
  });
  assert.equal(cancelled.status, 'cancelled');
  const state = core.readWorkflowState({ projectRoot: f.projectRoot, sessionId: f.ownerSessionId });
  assert.equal(Object.prototype.hasOwnProperty.call(state, 'autopilotRunId'), false);
  assert.equal(Object.prototype.hasOwnProperty.call(state, 'autopilotAttempt'), false);
  assert.equal(Object.prototype.hasOwnProperty.call(state, 'chainId'), false);
});

test('cancellation rejects symlink and hardlink claim artifacts without changing their targets', {
  skip: WINDOWS_SYMLINK_SKIP,
}, () => {
  const linked = deferredFixture({ ownerSession: 'cancellation-symlink-claim' });
  seedDeferredOwner(linked);
  writeDeferredClaim(linked);
  const target = path.join(linked.root, 'cancellation-claim-target.json');
  fs.renameSync(linked.claimFile, target);
  fs.symlinkSync(target, linked.claimFile);
  const targetBefore = fs.readFileSync(target);
  assert.throws(
    () => core.cancelDeferredReviewClaim(inspectDeferredOptions(linked, {
      currentContextFile: linked.ownerContextFile,
      currentSessionId: linked.ownerSessionId,
      mode: 'release-only',
    })),
    /claim path is invalid|symlink/i,
  );
  assert.deepEqual(fs.readFileSync(target), targetBefore);

  const multi = deferredFixture({ ownerSession: 'cancellation-hardlink-claim' });
  seedDeferredOwner(multi);
  writeDeferredClaim(multi);
  const alias = path.join(multi.root, 'cancellation-claim-alias.json');
  fs.linkSync(multi.claimFile, alias);
  const multiBefore = fs.readFileSync(multi.claimFile);
  assert.throws(
    () => core.cancelDeferredReviewClaim(inspectDeferredOptions(multi, {
      currentContextFile: multi.ownerContextFile,
      currentSessionId: multi.ownerSessionId,
      mode: 'release-only',
    })),
    /multi-linked/i,
  );
  assert.deepEqual(fs.readFileSync(alias), multiBefore);
});

test('cancellation exact removal preserves a concurrent replacement claim', () => {
  const f = deferredFixture({ ownerSession: 'cancellation-removal-replacement' });
  seedDeferredOwner(f);
  writeDeferredClaim(f);
  const replacement = {
    files: ['src/queued-after-cancel.js'],
    summary: 'Queued after cancellation',
    ts: CREATED_AT,
  };
  const originalRename = fs.renameSync;
  let raced = false;
  fs.renameSync = function patchedRename(source, destination) {
    const sourcePath = path.resolve(String(source));
    const result = originalRename.call(fs, source, destination);
    if (!raced && sourcePath === path.resolve(f.claimFile) && String(destination).includes('.quarantine')) {
      raced = true;
      core.atomicWriteJson(f.claimFile, replacement);
    }
    return result;
  };
  try {
    const cancelled = core.cancelDeferredReviewClaim(inspectDeferredOptions(f, {
      currentContextFile: f.ownerContextFile,
      currentSessionId: f.ownerSessionId,
      mode: 'release-only',
    }));
    assert.equal(cancelled.status, 'cancelled');
    assert.equal(raced, true);
    assert.deepEqual(JSON.parse(fs.readFileSync(f.claimFile, 'utf8')), replacement);
  } finally {
    fs.renameSync = originalRename;
  }
});

test('claim assignment and handoff acknowledgement reject an already-dead owner PID', () => {
  const assignment = deferredFixture({ ownerSession: 'dead-pid-assignment' });
  const marker = {
    files: ['src/dead-pid.js'],
    summary: 'Dead PID assignment',
    ts: CREATED_AT,
  };
  core.atomicWriteJson(assignment.claimFile, marker);
  const assignmentBefore = fs.readFileSync(assignment.claimFile);
  assert.throws(
    () => core.assignDeferredReviewClaim(assignDeferredOptions(assignment, {
      ownerPid: 2147483647,
    })),
    /assignee process.*not alive|owner pid.*dead/i,
  );
  assertClaimBytesUnchanged(assignment, assignmentBefore);

  const handoff = deferredFixture({ ownerSession: 'dead-pid-handoff' });
  core.mutateWorkflowState({
    projectRoot: handoff.projectRoot,
    sessionId: handoff.currentSessionId,
    workflowState: 'review_pending',
    event: 'unit-seed-dead-pid-handoff',
    expectedRevision: 1,
  }, (state) => ({
    ...state,
    active: true,
    implComplete: true,
    chainDone: false,
    deferredReviewClaim: handoff.claimId,
  }));
  writeDeferredClaim(handoff, { ownerSessionId: handoff.currentSessionId });
  const handoffBefore = fs.readFileSync(handoff.claimFile);
  assert.throws(
    () => core.acknowledgeDeferredReviewHandoff({
      ...inspectDeferredOptions(handoff),
      ownerPid: 2147483647,
      logStyle: 'none',
    }),
    /handoff process.*not alive|owner pid.*dead/i,
  );
  assertClaimBytesUnchanged(handoff, handoffBefore);
});

test('adopts a fresh unassigned marker only into an idle canonical baseline', () => {
  const f = deferredFixture();
  const marker = {
    files: ['src/feature.js'],
    summary: 'Implement deferred review',
    ts: CREATED_AT,
  };
  core.atomicWriteJson(f.claimFile, marker);
  const assigned = core.assignDeferredReviewClaim(assignDeferredOptions(f));
  assert.match(assigned.claimId, /^dc_[a-f0-9]{32}$/);
  assert.equal(assigned.ownerSessionId, f.currentSessionId);
  assert.equal(assigned.ownerPid, process.pid);
  assert.equal(assigned.ownerProcessStartIdentity, core.processStartIdentityForPid(process.pid));
  assert.equal(assigned.handoffEmitted, false);
  assert.equal(assigned.ts, undefined);
  assert.deepEqual(assigned.files, marker.files);
  assert.equal(assigned.summary, marker.summary);
  assert.equal(assigned.transfer, undefined);
  assert.equal(core.processStartIdentityForPid(2147483647), null);
  assert.throws(() => core.processStartIdentityForPid(0), /process id is invalid/i);
});

test('claim assignment rejects stale, malformed, non-idle, and already-owned markers byte-identically', () => {
  const cases = [
    {
      label: 'stale unassigned marker',
      seed(f) {
        core.atomicWriteJson(f.claimFile, { files: [], summary: 'stale marker' });
      },
      options: { claimStale: true },
      pattern: /stale unassigned.*must not be adopted/i,
    },
    {
      label: 'malformed unassigned marker',
      seed(f) {
        core.atomicWriteJson(f.claimFile, { files: ['bad\nfile'], summary: 'invalid marker' });
      },
      options: {},
      pattern: /marker payload is invalid/i,
    },
    {
      label: 'non-idle assignee baseline',
      seed(f) {
        core.atomicWriteJson(f.claimFile, { files: [], summary: 'valid marker' });
        core.mutateWorkflowState({
          projectRoot: f.projectRoot,
          sessionId: f.currentSessionId,
          workflowState: 'red',
          event: 'unit-nonidle-assignee',
          expectedRevision: 1,
        }, (state) => ({ ...state, active: true }));
      },
      options: {},
      pattern: /assignee state cannot begin a new generation/i,
    },
    {
      label: 'live existing owner',
      seed(f) {
        seedDeferredOwner(f);
        writeDeferredClaim(f);
      },
      options: {},
      pattern: /claim is not assignable/i,
    },
  ];
  for (const testCase of cases) {
    const f = deferredFixture({ ownerSession: `assign-${testCase.label}` });
    testCase.seed(f);
    const before = fs.readFileSync(f.claimFile);
    assert.throws(
      () => core.assignDeferredReviewClaim(assignDeferredOptions(f, testCase.options)),
      testCase.pattern,
      testCase.label,
    );
    assertClaimBytesUnchanged(f, before);
  }
});

test('transfer preparation, acknowledgement, finalization, and terminal clear reject invalid stages', () => {
  const live = deferredFixture({ ownerSession: 'prepare-live-owner' });
  seedDeferredOwner(live);
  writeDeferredClaim(live);
  const liveBefore = fs.readFileSync(live.claimFile);
  assert.throws(
    () => core.prepareDeferredReviewTransfer(inspectDeferredOptions(live)),
    /not eligible for transfer preparation/i,
  );
  assertClaimBytesUnchanged(live, liveBefore);

  const unretired = deferredFixture({ ownerSession: 'ack-unretired-owner' });
  const unretiredOwner = seedDeferredOwner(unretired);
  writeDeferredClaim(unretired, {
    ownerPid: 2147483647,
    transfer: preparedTransfer(unretired, unretiredOwner.revision),
  });
  const unretiredBefore = fs.readFileSync(unretired.claimFile);
  assert.throws(
    () => core.markDeferredReviewOwnerRetired({
      ...inspectDeferredOptions(unretired),
      expectedRevision: unretiredOwner.revision,
    }),
    /retirement is not durable/i,
  );
  assertClaimBytesUnchanged(unretired, unretiredBefore);

  const unseeded = deferredFixture({ ownerSession: 'finalize-unseeded-target' });
  const unseededOwner = seedDeferredOwner(unseeded);
  writeDeferredClaim(unseeded, { ownerPid: 2147483647 });
  core.prepareDeferredReviewTransfer(inspectDeferredOptions(unseeded));
  core.retireDeferredReviewOwner(retireDeferredOptions(unseeded, unseededOwner.revision));
  core.markDeferredReviewOwnerRetired({
    ...inspectDeferredOptions(unseeded),
    expectedRevision: unseededOwner.revision,
  });
  core.assignDeferredReviewClaim(assignDeferredOptions(unseeded));
  const unseededBefore = fs.readFileSync(unseeded.claimFile);
  assert.throws(
    () => core.finalizeDeferredReviewTransfer(inspectDeferredOptions(unseeded)),
    /transfer target was not seeded/i,
  );
  assertClaimBytesUnchanged(unseeded, unseededBefore);

  const nonterminal = deferredFixture({ ownerSession: 'clear-nonterminal-owner' });
  seedDeferredOwner(nonterminal);
  writeDeferredClaim(nonterminal);
  const nonterminalBefore = fs.readFileSync(nonterminal.claimFile);
  assert.throws(
    () => core.clearTerminalDeferredReviewClaim(inspectDeferredOptions(nonterminal)),
    /claim is not terminal/i,
  );
  assertClaimBytesUnchanged(nonterminal, nonterminalBefore);
});

test('terminal claim clear never deletes a concurrent replacement', () => {
  const f = deferredFixture();
  seedDeferredOwner(f, { chainDone: true });
  writeDeferredClaim(f, { ownerPid: 2147483647, handoffEmitted: true });
  const replacement = deferredClaim(f, {
    claimId: 'dc_terminal_clear_winner',
    ownerPid: 2147483647,
  });
  const originalRename = fs.renameSync;
  const displaced = path.join(f.root, 'terminal-claim-displaced.json');
  let injected = false;
  fs.renameSync = function patchedRename(source, destination) {
    if (!injected && path.resolve(source) === path.resolve(f.claimFile)) {
      injected = true;
      originalRename.call(fs, source, displaced);
      core.atomicWriteJson(f.claimFile, replacement);
    }
    return originalRename.call(fs, source, destination);
  };
  try {
    assert.throws(
      () => core.clearTerminalDeferredReviewClaim(inspectDeferredOptions(f)),
      /replacement race|changed before terminal removal/i,
    );
    assert.equal(injected, true);
    assert.deepEqual(JSON.parse(fs.readFileSync(f.claimFile, 'utf8')), replacement);
  } finally {
    fs.renameSync = originalRename;
  }
});

test('retirement revalidates live owners and fresh handoff leases before CAS', () => {
  const f = deferredFixture();
  const owner = seedDeferredOwner(f);
  writeDeferredClaim(f, {
    ownerPid: process.pid,
    transfer: preparedTransfer(f, owner.revision),
  });
  const stateFile = path.join(f.stateDirectory, `tdd-phase-${f.ownerSessionId}.json`);
  const stateBefore = fs.readFileSync(stateFile);
  const claimBefore = fs.readFileSync(f.claimFile);
  assert.throws(
    () => core.retireDeferredReviewOwner(retireDeferredOptions(f, owner.revision)),
    /owner.*live|not transferable|transfer.*denied/i,
  );
  assert.deepEqual(fs.readFileSync(stateFile), stateBefore);
  assertClaimBytesUnchanged(f, claimBefore);

  const handoff = deferredFixture({ ownerSession: 'fresh-handoff-retirement' });
  const handoffOwner = seedDeferredOwner(handoff);
  writeDeferredClaim(handoff, {
    ownerPid: 2147483647,
    handoffEmitted: true,
    transfer: preparedTransfer(handoff, handoffOwner.revision),
  });
  const handoffStateFile = path.join(
    handoff.stateDirectory,
    `tdd-phase-${handoff.ownerSessionId}.json`,
  );
  const handoffStateBefore = fs.readFileSync(handoffStateFile);
  const handoffClaimBefore = fs.readFileSync(handoff.claimFile);
  assert.throws(
    () => core.retireDeferredReviewOwner(retireDeferredOptions(handoff, handoffOwner.revision)),
    /handoff lease is fresh|owner.*live/i,
  );
  assert.deepEqual(fs.readFileSync(handoffStateFile), handoffStateBefore);
  assertClaimBytesUnchanged(handoff, handoffClaimBefore);
  const retired = core.retireDeferredReviewOwner(retireDeferredOptions(
    handoff,
    handoffOwner.revision,
    { claimStale: true },
  ));
  assert.equal(retired.revision, handoffOwner.revision + 1);
});

test('retires a foreign deferred owner with one exact CAS and is idempotent', () => {
  const f = deferredFixture();
  const owner = seedDeferredOwner(f);
  const prepared = preparedTransfer(f, owner.revision);
  writeDeferredClaim(f, {
    ownerPid: 2147483647,
    transfer: prepared,
  });
  const claimBefore = fs.readFileSync(f.claimFile);
  const retired = core.retireDeferredReviewOwner(retireDeferredOptions(f, owner.revision));
  assert.equal(retired.revision, owner.revision + 1);
  assert.equal(retired.last_event, 'deferred-review-transfer');
  assert.deepEqual({
    active: retired.active,
    implComplete: retired.implComplete,
    chainDone: retired.chainDone,
    codeReviewDone: retired.codeReviewDone,
    selfReviewFixed: retired.selfReviewFixed,
    reviewTicket: retired.reviewTicket,
    reviewTicketConsumed: retired.reviewTicketConsumed,
    reviewRound: retired.reviewRound,
    stopBlockCount: retired.stopBlockCount,
    deferredReviewClaim: retired.deferredReviewClaim,
  }, {
    active: false,
    implComplete: false,
    chainDone: false,
    codeReviewDone: false,
    selfReviewFixed: false,
    reviewTicket: '',
    reviewTicketConsumed: true,
    reviewRound: 0,
    stopBlockCount: 0,
    deferredReviewClaim: '',
  });
  assertClaimBytesUnchanged(f, claimBefore);

  const repeated = core.retireDeferredReviewOwner(retireDeferredOptions(f, owner.revision));
  assert.deepEqual(repeated, retired);
  assertClaimBytesUnchanged(f, claimBefore);

  writeDeferredClaim(f, {
    ownerPid: 2147483647,
    transfer: {
      ...prepared,
      stage: 'owner-retired',
      retiredOwnerRevision: retired.revision,
    },
  });
  const recovered = core.inspectDeferredReviewOwner(inspectDeferredOptions(f));
  assert.equal(recovered.status, 'owner-retired');
  assert.equal(recovered.ownerRevision, retired.revision);
});

test('retirement rejects a stale owner revision without changing state or claim bytes', () => {
  const f = deferredFixture();
  const owner = seedDeferredOwner(f);
  writeDeferredClaim(f, {
    ownerPid: 2147483647,
    transfer: preparedTransfer(f, owner.revision),
  });
  core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: f.ownerSessionId,
    workflowState: owner.workflow_state,
    event: 'unit-owner-race',
    expectedRevision: owner.revision,
  });
  const stateFile = path.join(f.stateDirectory, `tdd-phase-${f.ownerSessionId}.json`);
  const stateBefore = fs.readFileSync(stateFile);
  const claimBefore = fs.readFileSync(f.claimFile);
  assert.throws(
    () => core.retireDeferredReviewOwner(retireDeferredOptions(f, owner.revision)),
    /owner changed before retirement/i,
  );
  assert.deepEqual(fs.readFileSync(stateFile), stateBefore);
  assertClaimBytesUnchanged(f, claimBefore);
});

test('retirement rejects a claim swap after inspection and preserves the replacement bytes', () => {
  const f = deferredFixture();
  const owner = seedDeferredOwner(f);
  writeDeferredClaim(f, { ownerPid: 2147483647 });
  const inspected = core.inspectDeferredReviewOwner(inspectDeferredOptions(f));
  assert.equal(inspected.status, 'transfer');

  const replacementClaimId = 'dc_replacement_claim';
  f.claimId = replacementClaimId;
  writeDeferredClaim(f, {
    ownerPid: 2147483647,
    transfer: preparedTransfer(f, owner.revision),
  });
  const stateFile = path.join(f.stateDirectory, `tdd-phase-${f.ownerSessionId}.json`);
  const stateBefore = fs.readFileSync(stateFile);
  const replacementBefore = fs.readFileSync(f.claimFile);
  assert.throws(
    () => core.retireDeferredReviewOwner(retireDeferredOptions(f, inspected.ownerRevision)),
    /owner changed before retirement/i,
  );
  assert.deepEqual(fs.readFileSync(stateFile), stateBefore);
  assertClaimBytesUnchanged(f, replacementBefore);
});

test('retirement requires an exact prepared receipt and canonical transfer target', () => {
  const noReceipt = deferredFixture({ ownerSession: 'retire-without-receipt' });
  const noReceiptOwner = seedDeferredOwner(noReceipt);
  writeDeferredClaim(noReceipt, { ownerPid: 2147483647 });
  const noReceiptBefore = fs.readFileSync(noReceipt.claimFile);
  assert.throws(
    () => core.retireDeferredReviewOwner(retireDeferredOptions(noReceipt, noReceiptOwner.revision)),
    /prepared transfer receipt/i,
  );
  assertClaimBytesUnchanged(noReceipt, noReceiptBefore);

  const wrongTarget = deferredFixture({ ownerSession: 'retire-wrong-target' });
  const wrongTargetOwner = seedDeferredOwner(wrongTarget);
  writeDeferredClaim(wrongTarget, {
    ownerPid: 2147483647,
    transfer: preparedTransfer(wrongTarget, wrongTargetOwner.revision),
  });
  const wrongTargetBefore = fs.readFileSync(wrongTarget.claimFile);
  assert.throws(
    () => core.retireDeferredReviewOwner(retireDeferredOptions(wrongTarget, wrongTargetOwner.revision, {
      currentSessionId: 'raw-transfer-target',
    })),
    /prepared transfer receipt|canonical/i,
  );
  assertClaimBytesUnchanged(wrongTarget, wrongTargetBefore);

  const committed = deferredFixture({ ownerSession: 'retire-committed-receipt' });
  const committedOwner = seedDeferredOwner(committed);
  writeDeferredClaim(committed, {
    ownerPid: 2147483647,
    transfer: {
      ...preparedTransfer(committed, committedOwner.revision),
      stage: 'owner-retired',
      retiredOwnerRevision: committedOwner.revision + 1,
    },
  });
  const committedBefore = fs.readFileSync(committed.claimFile);
  assert.throws(
    () => core.retireDeferredReviewOwner(retireDeferredOptions(committed, committedOwner.revision)),
    /prepared transfer receipt/i,
  );
  assertClaimBytesUnchanged(committed, committedBefore);
});

test('claim replacement during inspection is detected without overwriting the winner', () => {
  const f = deferredFixture();
  seedDeferredOwner(f);
  writeDeferredClaim(f, { ownerPid: 2147483647 });
  const target = fs.realpathSync.native(f.claimFile);
  const replacement = deferredClaim(f, {
    claimId: 'dc_concurrent_winner',
    ownerPid: 2147483647,
  });
  const originalOpen = fs.openSync;
  const originalRead = fs.readSync;
  let claimDescriptor = null;
  let raced = false;
  fs.openSync = function patchedOpen(file, flags, ...rest) {
    const isClaim = path.resolve(String(file)) === path.resolve(target)
      && typeof flags === 'number';
    if (WINDOWS && isClaim && !raced) {
      // Windows does not permit rename-over-open. Race the bracketed
      // lstat/open sequence instead, which exercises the same identity guard.
      raced = true;
      core.atomicWriteJson(f.claimFile, replacement);
    }
    const descriptor = originalOpen.call(fs, file, flags, ...rest);
    if (!WINDOWS && isClaim) {
      claimDescriptor = descriptor;
    }
    return descriptor;
  };
  fs.readSync = function patchedRead(descriptor, ...args) {
    if (!WINDOWS && descriptor === claimDescriptor && !raced) {
      raced = true;
      core.atomicWriteJson(f.claimFile, replacement);
    }
    return originalRead.call(fs, descriptor, ...args);
  };
  try {
    assert.throws(
      () => core.inspectDeferredReviewOwner(inspectDeferredOptions(f)),
      /file identity changed while opening|file path changed while reading|file changed while reading/i,
    );
    assert.equal(raced, true);
    assert.deepEqual(JSON.parse(fs.readFileSync(f.claimFile, 'utf8')), replacement);
  } finally {
    fs.openSync = originalOpen;
    fs.readSync = originalRead;
  }
});

test('transfer preparation rejects a concurrent source revision without poisoning later inspection', () => {
  const f = deferredFixture({ ownerSession: 'prepare-source-revision-race' });
  const owner = seedDeferredOwner(f);
  writeDeferredClaim(f, { ownerPid: 2147483647 });
  const stateFile = path.join(f.stateDirectory, `tdd-phase-${f.ownerSessionId}.json`);
  let advanced;

  withAfterFileReadInjection(stateFile, 1, () => {
    advanced = core.transitionWorkflowState({
      projectRoot: f.projectRoot,
      sessionId: f.ownerSessionId,
      workflowState: owner.workflow_state,
      event: 'unit-prepare-source-race',
      expectedRevision: owner.revision,
    });
  }, () => {
    assert.throws(
      () => core.prepareDeferredReviewTransfer(inspectDeferredOptions(f)),
      /source state changed before transfer preparation/i,
    );
  });

  const persisted = JSON.parse(fs.readFileSync(f.claimFile, 'utf8'));
  assert.equal(persisted.transfer, undefined);
  const inspected = core.inspectDeferredReviewOwner(inspectDeferredOptions(f));
  assert.equal(inspected.status, 'transfer');
  assert.equal(inspected.ownerRevision, advanced.revision);
});

test('inspection cancels a stale prepared receipt and exposes the current transferable revision', () => {
  const f = deferredFixture({ ownerSession: 'recover-stale-prepared-receipt' });
  const owner = seedDeferredOwner(f);
  writeDeferredClaim(f, {
    ownerPid: 2147483647,
    transfer: preparedTransfer(f, owner.revision),
  });
  const advanced = core.transitionWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: f.ownerSessionId,
    workflowState: owner.workflow_state,
    event: 'unit-stale-prepared-receipt',
    expectedRevision: owner.revision,
  });

  const inspected = core.inspectDeferredReviewOwner(inspectDeferredOptions(f));
  assert.equal(inspected.status, 'transfer');
  assert.equal(inspected.ownerRevision, advanced.revision);
  assert.equal(inspected.claim.transfer, undefined);
  assert.equal(JSON.parse(fs.readFileSync(f.claimFile, 'utf8')).transfer, undefined);
});

test('terminal clear revalidates the inspected owner revision under the canonical state lock', () => {
  const f = deferredFixture({ ownerSession: 'terminal-clear-state-race' });
  const owner = seedDeferredOwner(f, { chainDone: true });
  writeDeferredClaim(f, { ownerPid: 2147483647, handoffEmitted: true });
  const claimBefore = fs.readFileSync(f.claimFile);
  const stateFile = path.join(f.stateDirectory, `tdd-phase-${f.ownerSessionId}.json`);

  withAfterFileReadInjection(stateFile, 1, () => {
    core.mutateWorkflowState({
      projectRoot: f.projectRoot,
      sessionId: f.ownerSessionId,
      workflowState: owner.workflow_state,
      event: 'unit-terminal-clear-rearm',
      expectedRevision: owner.revision,
    }, (state) => ({ ...state, chainDone: false }));
  }, () => {
    assert.throws(
      () => core.clearTerminalDeferredReviewClaim(inspectDeferredOptions(f)),
      /owner state changed before terminal removal/i,
    );
  });

  assertClaimBytesUnchanged(f, claimBefore);
  const current = core.readWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: f.ownerSessionId,
  });
  assert.equal(current.chainDone, false);
  assert.equal(current.deferredReviewClaim, f.claimId);
});

test('recovers a crash after terminal done-state CAS before exact claim removal', async () => {
  const f = deferredFixture({ ownerSession: 'terminal-done-state-cas-crash' });
  seedDeferredOwner(f, { chainDone: true });
  writeDeferredClaim(f, { ownerPid: 2147483647, handoffEmitted: true });
  const options = inspectDeferredOptions(f);
  const stateFile = path.join(f.stateDirectory, `tdd-phase-${f.ownerSessionId}.json`);
  const child = await runNode(`
    const fs = require('node:fs');
    const path = require('node:path');
    const core = require(process.env.SESSION_CONTROL_CORE);
    const options = JSON.parse(process.argv[1]);
    const stateFile = path.resolve(process.argv[2]);
    const originalRename = fs.renameSync;
    fs.renameSync = function injectedRename(source, destination) {
      let value = null;
      try { value = JSON.parse(fs.readFileSync(source, 'utf8')); } catch (_) {}
      const result = originalRename.call(fs, source, destination);
      if (path.resolve(String(destination)) === stateFile
          && value && value.last_event === 'deferred-review-complete') {
        process.kill(process.pid, 'SIGKILL');
      }
      return result;
    };
    core.clearTerminalDeferredReviewClaim(options);
  `, [JSON.stringify(options), stateFile]);
  assertKilled(child, 'expected terminal done-state CAS killpoint');
  assert.equal(fs.existsSync(f.claimFile), true);
  const inspected = core.inspectDeferredReviewOwner(options);
  assert.equal(inspected.status, 'cancelled');
  assert.deepEqual(core.clearTerminalDeferredReviewClaim(options), {
    status: 'cancelled',
    claimId: f.claimId,
    resultingOwnerRevision: inspected.ownerRevision,
  });
  assert.equal(fs.existsSync(f.claimFile), false);
});

test('transfer finalization revalidates the inspected target revision under the canonical state lock', () => {
  const f = deferredFixture({ ownerSession: 'finalize-target-state-race' });
  const owner = seedDeferredOwner(f);
  writeDeferredClaim(f, { ownerPid: 2147483647 });
  core.prepareDeferredReviewTransfer(inspectDeferredOptions(f));
  core.retireDeferredReviewOwner(retireDeferredOptions(f, owner.revision));
  core.markDeferredReviewOwnerRetired({
    ...inspectDeferredOptions(f),
    expectedRevision: owner.revision,
  });
  const assigned = core.assignDeferredReviewClaim(assignDeferredOptions(f));
  const target = core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: f.currentSessionId,
    workflowState: 'review_pending',
    event: 'unit-finalize-target-seed',
    expectedRevision: 1,
  }, (state) => ({
    ...state,
    active: true,
    implComplete: true,
    chainDone: false,
    deferredReviewClaim: assigned.claimId,
  }));
  const claimBefore = fs.readFileSync(f.claimFile);
  const stateFile = path.join(f.stateDirectory, `tdd-phase-${f.currentSessionId}.json`);

  withAfterFileReadInjection(stateFile, 1, () => {
    core.mutateWorkflowState({
      projectRoot: f.projectRoot,
      sessionId: f.currentSessionId,
      workflowState: 'idle',
      event: 'unit-finalize-target-reset',
      expectedRevision: target.revision,
    }, (state) => ({
      ...state,
      active: false,
      implComplete: false,
      chainDone: false,
      deferredReviewClaim: '',
    }));
  }, () => {
    assert.throws(
      () => core.finalizeDeferredReviewTransfer(inspectDeferredOptions(f)),
      /target state changed before transfer finalization/i,
    );
  });

  assertClaimBytesUnchanged(f, claimBefore);
  assert.equal(JSON.parse(fs.readFileSync(f.claimFile, 'utf8')).transfer.stage, 'owner-retired');
});

test('owner retirement revalidates exact claim bytes inside the owner state lock', () => {
  const f = deferredFixture({ ownerSession: 'retire-same-id-claim-swap' });
  const owner = seedDeferredOwner(f);
  const transfer = preparedTransfer(f, owner.revision);
  writeDeferredClaim(f, { ownerPid: 2147483647, transfer });
  const stateFile = path.join(f.stateDirectory, `tdd-phase-${f.ownerSessionId}.json`);
  const stateBefore = fs.readFileSync(stateFile);
  const replacement = deferredClaim(f, {
    ownerPid: 2147483647,
    handoffEmitted: true,
    ts: CREATED_AT,
    transfer,
  });

  withAfterFileReadInjection(stateFile, 2, () => {
    core.atomicWriteJson(f.claimFile, replacement);
  }, () => {
    assert.throws(
      () => core.retireDeferredReviewOwner(retireDeferredOptions(
        f,
        owner.revision,
        { claimStale: true },
      )),
      /claim changed during retirement/i,
    );
  });

  assert.deepEqual(fs.readFileSync(stateFile), stateBefore);
  assert.deepEqual(JSON.parse(fs.readFileSync(f.claimFile, 'utf8')), replacement);
});

test('claim assignment revalidates the idle target revision under its canonical state lock', () => {
  const f = deferredFixture({ currentSession: 'assignment-target-state-race' });
  const marker = { files: ['src/race.js'], summary: 'assignment race' };
  core.atomicWriteJson(f.claimFile, marker);
  const markerBefore = fs.readFileSync(f.claimFile);
  const stateFile = path.join(f.stateDirectory, `tdd-phase-${f.currentSessionId}.json`);

  withAfterFileReadInjection(stateFile, 1, () => {
    core.mutateWorkflowState({
      projectRoot: f.projectRoot,
      sessionId: f.currentSessionId,
      workflowState: 'active',
      event: 'unit-assignment-target-race',
      expectedRevision: 1,
    }, (state) => ({ ...state, active: true }));
  }, () => {
    assert.throws(
      () => core.assignDeferredReviewClaim(assignDeferredOptions(f)),
      /target state changed before claim assignment/i,
    );
  });

  assertClaimBytesUnchanged(f, markerBefore);
});

test('handoff acknowledgement finalizes receipts and writes the lease under the target state lock', () => {
  const f = deferredFixture({ ownerSession: 'handoff-ack-transfer-owner' });
  const owner = seedDeferredOwner(f);
  writeDeferredClaim(f, { ownerPid: 2147483647 });
  core.prepareDeferredReviewTransfer(inspectDeferredOptions(f));
  core.retireDeferredReviewOwner(retireDeferredOptions(f, owner.revision));
  core.markDeferredReviewOwnerRetired({
    ...inspectDeferredOptions(f),
    expectedRevision: owner.revision,
  });
  const assigned = core.assignDeferredReviewClaim(assignDeferredOptions(f));
  core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: f.currentSessionId,
    workflowState: 'review_pending',
    event: 'unit-handoff-ack-seed',
    expectedRevision: 1,
  }, (state) => ({
    ...state,
    active: true,
    implComplete: true,
    chainDone: false,
    deferredReviewClaim: assigned.claimId,
  }));

  const acknowledged = core.acknowledgeDeferredReviewHandoff({
    ...inspectDeferredOptions(f),
    ownerPid: process.pid,
    logStyle: 'none',
  });
  assert.equal(acknowledged.ownerSessionId, f.currentSessionId);
  assert.equal(acknowledged.ownerPid, process.pid);
  assert.equal(acknowledged.ownerProcessStartIdentity, core.processStartIdentityForPid(process.pid));
  assert.equal(acknowledged.handoffEmitted, true);
  assert.equal(acknowledged.transfer, undefined);
  assert.equal(acknowledged.ts, undefined);
});

test('handoff acknowledgement rejects a concurrent terminal transition without changing the claim', () => {
  const f = deferredFixture({ currentSession: 'handoff-ack-state-race' });
  const current = core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: f.currentSessionId,
    workflowState: 'review_pending',
    event: 'unit-handoff-ack-current',
    expectedRevision: 1,
  }, (state) => ({
    ...state,
    active: true,
    implComplete: true,
    chainDone: false,
    deferredReviewClaim: f.claimId,
  }));
  writeDeferredClaim(f, {
    ownerSessionId: f.currentSessionId,
    ownerPid: 2147483647,
  });
  const claimBefore = fs.readFileSync(f.claimFile);
  const stateFile = path.join(f.stateDirectory, `tdd-phase-${f.currentSessionId}.json`);

  withAfterFileReadInjection(stateFile, 1, () => {
    core.mutateWorkflowState({
      projectRoot: f.projectRoot,
      sessionId: f.currentSessionId,
      workflowState: 'review_done',
      event: 'unit-handoff-ack-terminal-race',
      expectedRevision: current.revision,
    }, (state) => ({ ...state, chainDone: true }));
  }, () => {
    assert.throws(
      () => core.acknowledgeDeferredReviewHandoff({
        ...inspectDeferredOptions(f),
        ownerPid: process.pid,
        logStyle: 'none',
      }),
      /target state changed before handoff acknowledgement/i,
    );
  });

  assertClaimBytesUnchanged(f, claimBefore);
});

test('handoff acknowledgement rejects a concurrent target reset without changing the claim', () => {
  const f = deferredFixture({ currentSession: 'handoff-ack-reset-race' });
  const current = core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: f.currentSessionId,
    workflowState: 'review_pending',
    event: 'unit-handoff-ack-before-reset',
    expectedRevision: 1,
  }, (state) => ({
    ...state,
    active: true,
    implComplete: true,
    chainDone: false,
    deferredReviewClaim: f.claimId,
  }));
  writeDeferredClaim(f, {
    ownerSessionId: f.currentSessionId,
    ownerPid: 2147483647,
  });
  const claimBefore = fs.readFileSync(f.claimFile);
  const stateFile = path.join(f.stateDirectory, `tdd-phase-${f.currentSessionId}.json`);

  withAfterFileReadInjection(stateFile, 1, () => {
    core.mutateWorkflowState({
      projectRoot: f.projectRoot,
      sessionId: f.currentSessionId,
      workflowState: 'idle',
      event: 'unit-handoff-ack-reset-race',
      expectedRevision: current.revision,
    }, (state) => ({
      ...state,
      active: false,
      implComplete: false,
      chainDone: false,
      deferredReviewClaim: '',
    }));
  }, () => {
    assert.throws(
      () => core.acknowledgeDeferredReviewHandoff({
        ...inspectDeferredOptions(f),
        ownerPid: process.pid,
        logStyle: 'none',
      }),
      /target state changed before handoff acknowledgement/i,
    );
  });

  assertClaimBytesUnchanged(f, claimBefore);
  const reset = core.readWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: f.currentSessionId,
  });
  assert.equal(reset.active, false);
  assert.equal(reset.deferredReviewClaim, '');
});

test('handoff acknowledgement revalidates exact claim bytes inside the target state lock', () => {
  const f = deferredFixture({ currentSession: 'handoff-ack-claim-swap' });
  core.mutateWorkflowState({
    projectRoot: f.projectRoot,
    sessionId: f.currentSessionId,
    workflowState: 'review_pending',
    event: 'unit-handoff-ack-before-claim-swap',
    expectedRevision: 1,
  }, (state) => ({
    ...state,
    active: true,
    implComplete: true,
    chainDone: false,
    deferredReviewClaim: f.claimId,
  }));
  writeDeferredClaim(f, {
    ownerSessionId: f.currentSessionId,
    ownerPid: 2147483647,
  });
  const replacement = deferredClaim(f, {
    ownerSessionId: f.currentSessionId,
    ownerPid: 2147483647,
    handoffEmitted: true,
    ts: CREATED_AT,
  });
  const stateFile = path.join(f.stateDirectory, `tdd-phase-${f.currentSessionId}.json`);

  withAfterFileReadInjection(stateFile, 2, () => {
    core.atomicWriteJson(f.claimFile, replacement);
  }, () => {
    assert.throws(
      () => core.acknowledgeDeferredReviewHandoff({
        ...inspectDeferredOptions(f),
        ownerPid: process.pid,
        logStyle: 'none',
      }),
      /claim changed before handoff acknowledgement/i,
    );
  });

  assert.deepEqual(JSON.parse(fs.readFileSync(f.claimFile, 'utf8')), replacement);
});

test('Darwin process identity invokes trusted ps with a deterministic environment', async (t) => {
  if (process.platform !== 'darwin') {
    t.skip('Darwin process identity contract only applies on Darwin');
    return;
  }
  const started = 'Wed Jul 16 12:34:56 2026';
  const source = String.raw`
    const childProcess = require('node:child_process');
    let invocation = null;
    childProcess.execFileSync = (file, args, options) => {
      invocation = { file, args, options };
      return ${JSON.stringify(`${started}\n`)};
    };
    const core = require(process.env.SESSION_CONTROL_CORE);
    const identity = core.processStartIdentityForPid(process.pid);
    process.stdout.write(JSON.stringify({ identity, invocation }));
  `;
  const result = await runNode(source);
  assert.equal(result.code, 0, result.stderr);
  const observed = JSON.parse(result.stdout);
  const digest = crypto.createHash('sha256')
    .update('zensu.process-start/darwin-v1\0', 'utf8')
    .update(started, 'utf8')
    .digest('hex');
  assert.equal(observed.identity, `darwin:${digest}`);
  assert.equal(observed.invocation.file, '/bin/ps');
  assert.deepEqual(observed.invocation.args, ['-p', String(observed.invocation.args[1]), '-o', 'lstart=']);
  assert.match(observed.invocation.args[1], /^[1-9][0-9]*$/);
  assert.deepEqual(observed.invocation.options.env, {
    PATH: '/usr/bin:/bin',
    LC_ALL: 'C',
    LANG: 'C',
    TZ: 'UTC',
  });
  assert.equal(observed.invocation.options.encoding, 'utf8');
  assert.deepEqual(observed.invocation.options.stdio, ['ignore', 'pipe', 'ignore']);
  assert.equal(observed.invocation.options.timeout, 1000);
});

test('Darwin process identity rejects malformed ps output', async (t) => {
  if (process.platform !== 'darwin') {
    t.skip('Darwin process identity contract only applies on Darwin');
    return;
  }
  const source = String.raw`
    const childProcess = require('node:child_process');
    childProcess.execFileSync = () => 'not a process timestamp\n';
    const core = require(process.env.SESSION_CONTROL_CORE);
    const identity = core.processStartIdentityForPid(process.pid);
    process.stdout.write(JSON.stringify(identity));
  `;
  const result = await runNode(source);
  assert.equal(result.code, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout), null);
});

test('external process lease release tolerates unavailable identity after direct ownership proof', async (t) => {
  if (process.platform !== 'darwin') {
    t.skip('Darwin injection covers transient ps unavailability');
    return;
  }
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-external-release-identity-null-'));
  const resourcePath = path.join(root, 'state.json');
  fs.writeFileSync(resourcePath, '{}\n', { mode: 0o600 });
  const source = String.raw`
    const childProcess = require('node:child_process');
    let calls = 0;
    childProcess.execFileSync = () => {
      calls += 1;
      if (calls === 1) return 'Wed Jul 16 12:34:56 2026\n';
      throw new Error('transient ps failure');
    };
    const core = require(process.env.SESSION_CONTROL_CORE);
    const lockDirectory = process.argv[1];
    const resourcePath = process.argv[2];
    const acquired = core.acquireExternalProcessLock({
      lockDirectory,
      resourcePath,
      ownerPid: process.pid,
    });
    core.releaseExternalProcessLock({
      lockDirectory,
      resourcePath,
      ownerPid: process.pid,
      token: acquired.token,
    });
  `;
  const result = await runNode(source, [root, resourcePath]);
  assert.equal(result.code, 0, result.stderr);
});

test('external process lease never steals an old lock from a live owner', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-external-live-'));
  const resourcePath = path.join(root, 'state.json');
  fs.writeFileSync(resourcePath, '{}\n', { mode: 0o600 });
  const acquired = core.acquireExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
  });
  const before = fs.readFileSync(acquired.lockFile);
  const old = new Date(Date.now() - 60000);
  fs.utimesSync(acquired.lockFile, old, old);
  assert.throws(() => core.acquireExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
    attemptLimit: 2,
  }), /timed out acquiring external process lock/i);
  assert.deepEqual(fs.readFileSync(acquired.lockFile), before);
  assert.equal(core.releaseExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
    token: acquired.token,
  }), true);
  assert.equal(fs.existsSync(acquired.lockFile), false);
});

test('external process lease contention never publishes a candidate against a live lock', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-external-contention-fast-path-'));
  const resourcePath = path.join(root, 'state.json');
  fs.writeFileSync(resourcePath, '{}\n', { mode: 0o600 });
  const acquired = core.acquireExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
  });
  let tokenPublications = 0;
  assert.throws(() => core.acquireExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
    attemptLimit: 3,
    tokenSink: () => { tokenPublications += 1; },
  }), /timed out acquiring external process lock/i);
  assert.equal(tokenPublications, 0);
  core.releaseExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
    token: acquired.token,
  });
});

test('external process lease acquisition rejects an unrelated live owner PID', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-external-owner-authority-'));
  const resourcePath = path.join(root, 'state.json');
  fs.writeFileSync(resourcePath, '{}\n', { mode: 0o600 });
  const unrelated = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: 'ignore' });
  let accidentallyAcquired = null;
  try {
    assert.throws(() => {
      accidentallyAcquired = core.acquireExternalProcessLock({
        lockDirectory: root,
        resourcePath,
        ownerPid: unrelated.pid,
        attemptLimit: 1,
      });
    }, /current process|parent process|owner authority/i);
  } finally {
    if (accidentallyAcquired) {
      core.releaseExternalProcessLock({
        lockDirectory: root,
        resourcePath,
        ownerPid: unrelated.pid,
        token: accidentallyAcquired.token,
      });
    }
    unrelated.kill('SIGTERM');
  }
});

test('external process lease release rejects an unrelated live owner PID', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-external-release-authority-'));
  const resourcePath = path.join(root, 'state.json');
  fs.writeFileSync(resourcePath, '{}\n', { mode: 0o600 });
  const unrelated = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: 'ignore' });
  const lockFile = core.externalProcessLockPath({ lockDirectory: root, resourcePath });
  const token = '9'.repeat(48);
  fs.writeFileSync(lockFile, JSON.stringify({
    pid: unrelated.pid,
    token,
    kind: 'external-process-lock',
    created_at: new Date().toISOString(),
    process_start_identity: core.processStartIdentityForPid(unrelated.pid),
  }), { mode: 0o600 });
  try {
    assert.throws(() => core.releaseExternalProcessLock({
      lockDirectory: root,
      resourcePath,
      ownerPid: unrelated.pid,
      token,
    }), /current process|parent process|owner authority/i);
    assert.equal(fs.existsSync(lockFile), true);
  } finally {
    unrelated.kill('SIGTERM');
    if (fs.existsSync(lockFile)) fs.unlinkSync(lockFile);
  }
});

test('external process lease token capability releases across a different process', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-external-token-release-'));
  const resourcePath = path.join(root, 'state.json');
  fs.writeFileSync(resourcePath, '{}\n', { mode: 0o600 });
  const acquired = core.acquireExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
  });
  const artifact = JSON.parse(fs.readFileSync(acquired.lockFile, 'utf8'));
  assert.match(artifact.release_token_digest, /^sha256:[a-f0-9]{64}$/);
  assert.notEqual(artifact.token, acquired.token);
  assert.equal(fs.readFileSync(acquired.lockFile, 'utf8').includes(acquired.token), false);
  const source = String.raw`
    const core = require(process.env.SESSION_CONTROL_CORE);
    core.releaseExternalProcessLockByToken({
      lockDirectory: process.argv[1],
      resourcePath: process.argv[2],
      token: process.argv[3],
    });
  `;
  const released = await runNode(source, [root, resourcePath, acquired.token]);
  assert.equal(released.code, 0, released.stderr);
  assert.equal(fs.existsSync(acquired.lockFile), false);
});

test('external process lease artifact identity is not a release capability', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-external-artifact-token-'));
  const resourcePath = path.join(root, 'state.json');
  fs.writeFileSync(resourcePath, '{}\n', { mode: 0o600 });
  const acquired = core.acquireExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
  });
  const artifact = JSON.parse(fs.readFileSync(acquired.lockFile, 'utf8'));
  assert.throws(() => core.releaseExternalProcessLockByToken({
    lockDirectory: root,
    resourcePath,
    token: artifact.token,
  }), /token|ownership/i);
  assert.equal(fs.existsSync(acquired.lockFile), true);
  core.releaseExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
    token: acquired.token,
  });
});

test('external process lease binds an absent resource through its canonical parent', () => {
  const outer = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-external-absent-'));
  const root = path.join(outer, 'state');
  fs.mkdirSync(root);
  const resourcePath = path.join(root, 'pending-review.json');
  const acquired = core.acquireExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
  });
  assert.equal(fs.existsSync(resourcePath), false);
  assert.equal(path.dirname(acquired.lockFile), fs.realpathSync.native(root));
  assert.equal(acquired.lockFile, core.externalProcessLockPath({ lockDirectory: root, resourcePath }));
  core.releaseExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
    token: acquired.token,
  });
});

test('external process lease rejects symlinked resource bindings', (t) => {
  if (WINDOWS) {
    t.skip(WINDOWS_SYMLINK_SKIP);
    return;
  }
  const outer = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-external-symlink-'));
  const root = path.join(outer, 'state');
  fs.mkdirSync(root);
  const target = path.join(outer, 'target.json');
  const resourcePath = path.join(root, 'pending-review.json');
  fs.writeFileSync(target, '{}\n');
  fs.symlinkSync(target, resourcePath);
  assert.throws(() => core.externalProcessLockPath({
    lockDirectory: root,
    resourcePath,
  }), /symlink|unsafe/i);

  const alias = path.join(outer, 'state-alias');
  fs.symlinkSync(root, alias, 'dir');
  assert.throws(() => core.externalProcessLockPath({
    lockDirectory: root,
    resourcePath: path.join(alias, 'absent.json'),
  }), /symlink|unsafe/i);
});

test('external process lease fails closed when its parent is swapped during acquisition', () => {
  const outer = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-external-parent-swap-'));
  const root = path.join(outer, 'state');
  const displaced = path.join(outer, 'state-displaced');
  fs.mkdirSync(root);
  const resourcePath = path.join(root, 'pending-review.json');
  const lockFile = core.externalProcessLockPath({ lockDirectory: root, resourcePath });
  const originalOpen = fs.openSync;
  let injected = false;
  try {
    fs.openSync = function patchedOpen(file, flags, ...rest) {
      if (!injected && String(file).endsWith('.candidate')) {
        injected = true;
        fs.renameSync(root, displaced);
        fs.mkdirSync(root);
        fs.writeFileSync(path.join(root, 'sentinel.txt'), 'replacement\n');
      }
      return originalOpen.call(fs, file, flags, ...rest);
    };
    assert.throws(() => core.acquireExternalProcessLock({
      lockDirectory: root,
      resourcePath,
      ownerPid: process.pid,
      attemptLimit: 1,
    }), /directory|parent|identity|changed|unsafe/i);
    assert.equal(injected, true);
    assert.equal(fs.readFileSync(path.join(root, 'sentinel.txt'), 'utf8'), 'replacement\n');
    assert.equal(fs.existsSync(lockFile), false);
  } finally {
    fs.openSync = originalOpen;
  }
});

test('external process lease reclaims an artifact left by a killed owner', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-external-kill-'));
  const resourcePath = path.join(root, 'state.json');
  fs.writeFileSync(resourcePath, '{}\n', { mode: 0o600 });
  const source = String.raw`
    const core = require(process.env.SESSION_CONTROL_CORE);
    core.acquireExternalProcessLock({
      lockDirectory: process.argv[1],
      resourcePath: process.argv[2],
      ownerPid: process.pid,
    });
    process.kill(process.pid, 'SIGKILL');
  `;
  const killed = await runNode(source, [root, resourcePath]);
  assert.notEqual(killed.code, 0);
  const lockFile = core.externalProcessLockPath({ lockDirectory: root, resourcePath });
  assert.equal(fs.existsSync(lockFile), true);
  const acquired = core.acquireExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
  });
  assert.equal(acquired.lockFile, lockFile);
  assert.equal(core.releaseExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
    token: acquired.token,
  }), true);
  assert.equal(fs.existsSync(lockFile), false);
});

test('external process lease rejects a wrong release token without changing the lock', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-external-token-'));
  const resourcePath = path.join(root, 'state.json');
  fs.writeFileSync(resourcePath, '{}\n', { mode: 0o600 });
  const acquired = core.acquireExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
  });
  const before = fs.readFileSync(acquired.lockFile);
  assert.throws(() => core.releaseExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
    token: 'f'.repeat(48),
  }), /token|ownership/i);
  assert.deepEqual(fs.readFileSync(acquired.lockFile), before);
  assert.throws(() => core.releaseExternalProcessLockByToken({
    lockDirectory: root,
    resourcePath,
    token: 'e'.repeat(48),
  }), /token|ownership/i);
  assert.deepEqual(fs.readFileSync(acquired.lockFile), before);
  core.releaseExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
    token: acquired.token,
  });
});

test('external process lease release preserves a racing replacement generation', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-external-replace-'));
  const resourcePath = path.join(root, 'state.json');
  fs.writeFileSync(resourcePath, '{}\n', { mode: 0o600 });
  const acquired = core.acquireExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
  });
  const displaced = path.join(root, '.external-original.displaced');
  const replacement = {
    pid: process.pid,
    token: 'e'.repeat(48),
    kind: 'external-process-lock',
    created_at: new Date().toISOString(),
    process_start_identity: core.processStartIdentityForPid(process.pid),
  };
  const originalRename = fs.renameSync;
  let injected = false;
  try {
    fs.renameSync = function patchedRename(source, destination) {
      if (!injected && path.resolve(source) === path.resolve(acquired.lockFile)) {
        injected = true;
        originalRename.call(fs, source, displaced);
        fs.writeFileSync(source, JSON.stringify(replacement), { mode: 0o600 });
      }
      return originalRename.call(fs, source, destination);
    };
    assert.throws(() => core.releaseExternalProcessLock({
      lockDirectory: root,
      resourcePath,
      ownerPid: process.pid,
      token: acquired.token,
    }), /identity changed|ownership changed/i);
    assert.equal(injected, true);
    assert.deepEqual(JSON.parse(fs.readFileSync(acquired.lockFile, 'utf8')), replacement);
  } finally {
    fs.renameSync = originalRename;
    if (fs.existsSync(acquired.lockFile)) fs.unlinkSync(acquired.lockFile);
    if (fs.existsSync(displaced)) fs.unlinkSync(displaced);
  }
});

test('external process lease stays contended when a live owner identity is unavailable', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-external-null-identity-'));
  const resourcePath = path.join(root, 'state.json');
  fs.writeFileSync(resourcePath, '{}\n', { mode: 0o600 });
  const lockFile = core.externalProcessLockPath({ lockDirectory: root, resourcePath });
  const owner = {
    pid: process.pid,
    token: 'a'.repeat(48),
    kind: 'external-process-lock',
    created_at: CREATED_AT,
    process_start_identity: null,
  };
  fs.writeFileSync(lockFile, JSON.stringify(owner), { mode: 0o600 });
  const old = new Date(Date.now() - 60000);
  fs.utimesSync(lockFile, old, old);
  assert.throws(() => core.acquireExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
    attemptLimit: 2,
  }), /timed out acquiring external process lock/i);
  assert.deepEqual(JSON.parse(fs.readFileSync(lockFile, 'utf8')), owner);
  fs.unlinkSync(lockFile);
});

test('external process lease reclaims a live PID with a mismatched start identity', async (t) => {
  const actualIdentity = core.processStartIdentityForPid(process.pid);
  if (!actualIdentity) {
    if (process.platform === 'darwin') {
      const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-external-pid-reuse-darwin-'));
      const resourcePath = path.join(root, 'state.json');
      fs.writeFileSync(resourcePath, '{}\n', { mode: 0o600 });
      const source = String.raw`
        const childProcess = require('node:child_process');
        const fs = require('node:fs');
        childProcess.execFileSync = () => 'Wed Jul 16 12:34:56 2026\n';
        const core = require(process.env.SESSION_CONTROL_CORE);
        const lockDirectory = process.argv[1];
        const resourcePath = process.argv[2];
        const lockFile = core.externalProcessLockPath({ lockDirectory, resourcePath });
        fs.writeFileSync(lockFile, JSON.stringify({
          pid: process.pid,
          token: 'b'.repeat(48),
          kind: 'external-process-lock',
          created_at: new Date().toISOString(),
          process_start_identity: 'darwin:' + '0'.repeat(64),
        }), { mode: 0o600 });
        const acquired = core.acquireExternalProcessLock({
          lockDirectory,
          resourcePath,
          ownerPid: process.pid,
        });
        core.releaseExternalProcessLock({
          lockDirectory,
          resourcePath,
          ownerPid: process.pid,
          token: acquired.token,
        });
      `;
      const result = await runNode(source, [root, resourcePath]);
      assert.equal(result.code, 0, result.stderr);
      return;
    }
    t.skip('this platform cannot establish the current process start identity');
    return;
  }
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-external-pid-reuse-'));
  const resourcePath = path.join(root, 'state.json');
  fs.writeFileSync(resourcePath, '{}\n', { mode: 0o600 });
  const lockFile = core.externalProcessLockPath({ lockDirectory: root, resourcePath });
  fs.writeFileSync(lockFile, JSON.stringify({
    pid: process.pid,
    token: 'b'.repeat(48),
    kind: 'external-process-lock',
    created_at: new Date().toISOString(),
    process_start_identity: 'darwin:mismatched-process-start',
  }), { mode: 0o600 });
  const acquired = core.acquireExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
  });
  assert.notEqual(acquired.token, 'b'.repeat(48));
  core.releaseExternalProcessLock({
    lockDirectory: root,
    resourcePath,
    ownerPid: process.pid,
    token: acquired.token,
  });
});

// requireAbsentDirectoryPath was exported "for the unit layer alone" and had no unit
// consumer at all — the same dead-export class this PR removes one file over. These four
// cases are what make the export honest, and the predicate backs
// orphanedProjectRootSession, so its rules are load-bearing rather than cosmetic.
//
// Written platform-neutrally ON PURPOSE: this suite runs on the Windows shard, where a
// POSIX literal such as '/a/b' IS absolute but is NOT a path.resolve fixed point, so a
// hardcoded POSIX path would trip the normalization rule for a reason unrelated to the
// property under test. Every value is therefore built from path.resolve and path.sep.
// The non-normalized case asserts its own premise first: without that line a change to
// path.resolve would leave the case vacuous rather than red.
const ABSENT_PROBE = path.resolve(os.tmpdir(), 'zensu-absent-probe');

test('requireAbsentDirectoryPath accepts an absolute, normalized path', () => {
  assert.equal(core.requireAbsentDirectoryPath(ABSENT_PROBE, 'probe'), ABSENT_PROBE);
});

test('requireAbsentDirectoryPath rejects a control character', () => {
  const value = ABSENT_PROBE + String.fromCharCode(7);
  assert.throws(
    () => core.requireAbsentDirectoryPath(value, 'probe'),
    /^Error: session-control-v1: probe is unsafe$/,
  );
});

test('requireAbsentDirectoryPath rejects a relative path', () => {
  assert.throws(
    () => core.requireAbsentDirectoryPath(path.join('relative', 'probe'), 'probe'),
    /^Error: session-control-v1: probe must be absolute$/,
  );
});

test('requireAbsentDirectoryPath rejects an absolute path that is not normalized', () => {
  const value = ['a', '..', 'b'].reduce((acc, segment) => acc + path.sep + segment, ABSENT_PROBE);
  assert.notEqual(path.resolve(value), value);
  assert.throws(
    () => core.requireAbsentDirectoryPath(value, 'probe'),
    /^Error: session-control-v1: probe must be normalized$/,
  );
});
