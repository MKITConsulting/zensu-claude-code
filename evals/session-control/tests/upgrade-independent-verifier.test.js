#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const {
  IndependentVerifierError,
  computeClaudeRuntimeDigest,
  readAndValidateContext,
  readAndValidateInitialWorkflow,
  sessionIdHash,
  sessionKey,
} = require('../lib/upgrade-independent-verifier.js');

const RUNTIME_DOMAIN = Buffer.from('zensu.session-control/v1/runtime-digest\0', 'utf8');

function temporaryDirectory(label) {
  return fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), label)));
}

function write(root, relative, contents) {
  const file = path.join(root, relative);
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, contents, { mode: 0o600 });
  return file;
}

function pluginFixture() {
  const root = temporaryDirectory('zensu-independent-runtime-');
  write(root, '.claude-plugin/plugin.json', JSON.stringify({
    name: 'zensu',
    version: '9.9.9',
    hooks: '${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json',
    agents: ['./agents/reviewer.md'],
    skills: [],
    mcpServers: { zensu: { command: 'node' } },
  }));
  write(root, 'hooks/hooks.json', '{"hooks":{}}\n');
  write(root, 'hooks/entry.sh', '#!/bin/bash\nexit 0\n');
  write(root, 'agents/reviewer.md', '# reviewer\n');
  write(root, 'docs/contract.md', '# contract\n');
  write(root, 'templates/prompt.md', '# prompt\n');
  write(root, 'README.md', '# Zensu\n');
  write(root, 'scripts/server.js', 'process.exit(0);\n');
  write(root, 'mcp-runtime/package.json', '{"name":"zensu-mcp"}\n');
  write(root, 'mcp-runtime/package-lock.json', '{"lockfileVersion":3}\n');
  return root;
}

function manualDigest(root) {
  const relativeFiles = [
    '.claude-plugin/plugin.json',
    'agents/reviewer.md',
    'docs/contract.md',
    'hooks/entry.sh',
    'hooks/hooks.json',
    'mcp-runtime/package-lock.json',
    'mcp-runtime/package.json',
    'README.md',
    'scripts/server.js',
    'templates/prompt.md',
  ].sort((left, right) => left.localeCompare(right));
  const digest = crypto.createHash('sha256').update(RUNTIME_DOMAIN);
  for (const relative of relativeFiles) {
    const content = fs.readFileSync(path.join(root, relative));
    digest.update(String(Buffer.byteLength(relative)), 'utf8');
    digest.update('\0');
    digest.update(relative, 'utf8');
    digest.update('\0');
    digest.update(String(content.length), 'utf8');
    digest.update('\0');
    digest.update(content);
    digest.update('\0');
  }
  return `sha256:${digest.digest('hex')}`;
}

function contextRecord(expected) {
  return {
    schema: 'zensu.session-control',
    schema_version: 1,
    host: 'claude',
    session_id_hash: sessionIdHash(expected.sessionId),
    project_root: expected.projectRoot,
    plugin_root: expected.pluginRoot,
    plugin_data: expected.pluginData,
    plugin_version: expected.pluginVersion,
    source_revision: expected.runtimeDigest,
    runtime_digest: expected.runtimeDigest,
    created_at: '2026-07-23T12:34:56.000Z',
    principal_profiles: {
      main: 'main-v1',
      reviewer: 'reviewer-readonly-v1',
      evidence_worker: 'evidence-worker-v1',
      host: 'host-profile-v1',
    },
  };
}

function workflowRecord(sessionId) {
  return {
    active: false,
    vanilla: false,
    implComplete: false,
    chainDone: false,
    codeReviewDone: false,
    selfReviewFixed: false,
    workflowActive: false,
    workflowTools: [],
    bypasses: [],
    reviewTicket: '',
    reviewTicketConsumed: true,
    reviewRound: 0,
    stopBlockCount: 0,
    deferredReviewClaim: '',
    phase: 'UNINITIALIZED',
    step_id: '',
    history: [],
    schema: 'zensu.workflow-state',
    schema_version: 1,
    session_id_hash: sessionIdHash(sessionId),
    workflow_state: 'idle',
    revision: 1,
    last_event: 'session-start',
    updated_at: '2026-07-23T12:34:56.000Z',
    actor: 'main-v1',
  };
}

test('derives session hashes and canonical keys without candidate code', () => {
  const id = 'candidate-session';
  const expectedHash = `sha256:${crypto.createHash('sha256')
    .update(Buffer.from('zensu.session-control/v1/session-id\0', 'utf8'))
    .update(id, 'utf8').digest('hex')}`;
  assert.equal(sessionIdHash(id), expectedHash);
  assert.equal(sessionIdHash(expectedHash), expectedHash);
  assert.equal(sessionIdHash(`scv1_${expectedHash.slice(7)}`), expectedHash);
  assert.equal(sessionKey(id), `scv1_${expectedHash.slice(7)}`);
  assert.equal(sessionKey(`scv1_${expectedHash.slice(7)}`), `scv1_${expectedHash.slice(7)}`);
  assert.throws(() => sessionKey(''), IndependentVerifierError);
});

test('computes the exact Claude runtime digest from evaluator-owned rules', () => {
  const root = pluginFixture();
  try {
    assert.equal(computeClaudeRuntimeDigest(root), manualDigest(root));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('rejects invalid manifests, escaped references, symlinks, and hard links', () => {
  const invalid = temporaryDirectory('zensu-independent-invalid-');
  const escaped = temporaryDirectory('zensu-independent-escaped-');
  const linked = pluginFixture();
  try {
    write(invalid, '.claude-plugin/plugin.json', '{"name":"other","version":"1"}');
    assert.throws(() => computeClaudeRuntimeDigest(invalid), /manifest is invalid/);

    write(escaped, '.claude-plugin/plugin.json', '{"name":"zensu","version":"1","hooks":"..\\/outside"}');
    assert.throws(() => computeClaudeRuntimeDigest(escaped), /escapes plugin root/);

    const target = path.join(linked, 'hooks', 'entry.sh');
    const symlink = path.join(linked, 'hooks', 'symlink.sh');
    try {
      fs.symlinkSync(target, symlink);
      assert.throws(() => computeClaudeRuntimeDigest(linked), /symlinks are forbidden/);
      fs.unlinkSync(symlink);
    } catch (error) {
      if (!['EPERM', 'EACCES', 'ENOSYS'].includes(error?.code)) throw error;
    }
    const hardlink = path.join(linked, 'hooks', 'hardlink.sh');
    try {
      fs.linkSync(target, hardlink);
      assert.throws(() => computeClaudeRuntimeDigest(linked), /multi-linked files are forbidden/);
    } catch (error) {
      if (!['EPERM', 'EACCES', 'ENOSYS'].includes(error?.code)) throw error;
    }
    assert.throws(() => computeClaudeRuntimeDigest(path.join(linked, 'missing')), /unavailable/);
  } finally {
    fs.rmSync(invalid, { recursive: true, force: true });
    fs.rmSync(escaped, { recursive: true, force: true });
    fs.rmSync(linked, { recursive: true, force: true });
  }
});

test('descriptor-safely validates an exact raw context record', () => {
  const root = pluginFixture();
  const projectRoot = temporaryDirectory('zensu-independent-project-');
  const pluginData = temporaryDirectory('zensu-independent-data-');
  const records = temporaryDirectory('zensu-independent-records-');
  try {
    const expected = {
      sessionId: 'session-context',
      projectRoot,
      pluginRoot: root,
      pluginData,
      pluginVersion: '9.9.9',
      runtimeDigest: computeClaudeRuntimeDigest(root),
    };
    const record = contextRecord(expected);
    const file = write(records, 'context.json', `${JSON.stringify(record)}\n`);
    assert.deepEqual(readAndValidateContext(file, expected), record);

    write(records, 'context.json', `${JSON.stringify({ ...record, unexpected: true })}\n`);
    assert.throws(() => readAndValidateContext(file, expected), /context schema is invalid/);
    write(records, 'context.json', `${JSON.stringify({ ...record, project_root: pluginData })}\n`);
    assert.throws(() => readAndValidateContext(file, expected), /project_root mismatch/);
    write(records, 'context.json', `${JSON.stringify({
      ...record,
      principal_profiles: { ...record.principal_profiles, reviewer: 'main-v1' },
    })}\n`);
    assert.throws(() => readAndValidateContext(file, expected), /principal profiles mismatch/);
    write(records, 'context.json', `${JSON.stringify({ ...record, created_at: 'not-a-time' })}\n`);
    assert.throws(() => readAndValidateContext(file, expected), /provenance is invalid/);
    write(records, 'context.json', '{');
    assert.throws(() => readAndValidateContext(file, expected), /invalid JSON/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
    fs.rmSync(projectRoot, { recursive: true, force: true });
    fs.rmSync(pluginData, { recursive: true, force: true });
    fs.rmSync(records, { recursive: true, force: true });
  }
});

test('descriptor-safely validates the exact initial workflow baseline', () => {
  const root = temporaryDirectory('zensu-independent-workflow-');
  try {
    const sessionId = 'session-workflow';
    const record = workflowRecord(sessionId);
    const file = write(root, 'state.json', `${JSON.stringify(record)}\n`);
    assert.deepEqual(readAndValidateInitialWorkflow(file, { sessionId }), record);

    write(root, 'state.json', `${JSON.stringify({ ...record, revision: 2 })}\n`);
    assert.throws(() => readAndValidateInitialWorkflow(file, { sessionId }), /revision mismatch/);
    write(root, 'state.json', `${JSON.stringify({ ...record, unexpected: true })}\n`);
    assert.throws(() => readAndValidateInitialWorkflow(file, { sessionId }), /schema is invalid/);
    write(root, 'state.json', `${JSON.stringify({ ...record, history: [{}] })}\n`);
    assert.throws(() => readAndValidateInitialWorkflow(file, { sessionId }), /collections or timestamp/);
    write(root, 'state.json', `${JSON.stringify({ ...record, updated_at: 'invalid' })}\n`);
    assert.throws(() => readAndValidateInitialWorkflow(file, { sessionId }), /collections or timestamp/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
