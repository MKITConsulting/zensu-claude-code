#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { readStableRegularFile } = require('./safe-file-read.js');

const HASH_DOMAIN = Buffer.from('zensu.session-control/v1/session-id\0', 'utf8');
const RUNTIME_DOMAIN = Buffer.from('zensu.session-control/v1/runtime-digest\0', 'utf8');
const SESSION_KEY_RE = /^scv1_([a-f0-9]{64})$/;
const HASH_RE = /^sha256:([a-f0-9]{64})$/;
const MAX_JSON_BYTES = 1024 * 1024;
const MAX_RUNTIME_FILES = 10000;
const MAX_RUNTIME_FILE_BYTES = 4 * 1024 * 1024;
const MAX_RUNTIME_TOTAL_BYTES = 64 * 1024 * 1024;
const CONTEXT_KEYS = [
  'created_at',
  'host',
  'plugin_data',
  'plugin_root',
  'plugin_version',
  'principal_profiles',
  'project_root',
  'runtime_digest',
  'schema',
  'schema_version',
  'session_id_hash',
  'source_revision',
];
const PROFILE_KEYS = ['evidence_worker', 'host', 'main', 'reviewer'];
const INITIAL_WORKFLOW_KEYS = [
  'active',
  'actor',
  'bypasses',
  'chainDone',
  'codeReviewDone',
  'deferredReviewClaim',
  'history',
  'implComplete',
  'last_event',
  'phase',
  'reviewRound',
  'reviewTicket',
  'reviewTicketConsumed',
  'revision',
  'schema',
  'schema_version',
  'selfReviewFixed',
  'session_id_hash',
  'step_id',
  'stopBlockCount',
  'updated_at',
  'vanilla',
  'workflowActive',
  'workflowTools',
  'workflow_state',
];

class IndependentVerifierError extends Error {}

function fail(message) {
  throw new IndependentVerifierError(`independent upgrade verifier: ${message}`);
}

function requireText(value, label) {
  if (typeof value !== 'string' || value.trim() === '') fail(`${label} is invalid`);
  return value;
}

function exactKeys(value, expected, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || Object.keys(value).sort().join('\0') !== expected.join('\0')) {
    fail(`${label} schema is invalid`);
  }
}

function sessionIdHash(sessionId) {
  const value = requireText(sessionId, 'session id');
  const key = SESSION_KEY_RE.exec(value);
  if (key) return `sha256:${key[1]}`;
  if (HASH_RE.test(value)) return value;
  const digest = crypto.createHash('sha256').update(HASH_DOMAIN).update(value, 'utf8').digest('hex');
  return `sha256:${digest}`;
}

function sessionKey(sessionId) {
  const value = requireText(sessionId, 'session id');
  if (SESSION_KEY_RE.test(value)) return value;
  return `scv1_${sessionIdHash(value).slice('sha256:'.length)}`;
}

function stableFile(file, maxBytes, minBytes = 0) {
  let snapshot;
  try {
    snapshot = readStableRegularFile(file, { maxBytes, minBytes });
  } catch (_error) {
    fail('file is not a stable bounded regular file');
  }
  if (snapshot.stat.nlink > 1) fail('multi-linked files are forbidden');
  return snapshot.buffer;
}

function readJson(file) {
  const buffer = stableFile(file, MAX_JSON_BYTES, 1);
  try {
    return JSON.parse(buffer.toString('utf8'));
  } catch (_error) {
    fail('record is invalid JSON');
  }
}

function canonicalDirectory(input, label) {
  requireText(input, label);
  if (/[\0\r\n]/.test(input)) fail(`${label} is invalid`);
  let canonical;
  let stat;
  try {
    canonical = fs.realpathSync.native(input);
    stat = fs.lstatSync(input);
  } catch (_error) {
    fail(`${label} is unavailable`);
  }
  if (canonical !== path.resolve(input) || stat.isSymbolicLink() || !stat.isDirectory()) {
    fail(`${label} must be a canonical real directory`);
  }
  return canonical;
}

function inside(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === '' || (relative !== '..' && !relative.startsWith(`..${path.sep}`)
    && !path.isAbsolute(relative));
}

function manifestEntry(root, value, label) {
  const raw = requireText(value, label).replace(/^\$\{(?:CLAUDE_)?PLUGIN_ROOT\}/, root);
  const candidate = path.isAbsolute(raw) ? path.resolve(raw) : path.resolve(root, raw);
  if (!inside(root, candidate)) fail(`${label} escapes plugin root`);
  if (!fs.existsSync(candidate)) fail(`${label} is missing`);
  return candidate;
}

function runtimeEntries(root, manifest) {
  const entries = new Set([path.join(root, '.claude-plugin', 'plugin.json')]);
  for (const directory of ['hooks', 'agents', 'skills', 'docs', 'templates']) {
    const candidate = path.join(root, directory);
    if (fs.existsSync(candidate)) entries.add(candidate);
  }
  for (const file of ['README.md', 'CHANGELOG.md', 'LICENSE']) {
    const candidate = path.join(root, file);
    if (fs.existsSync(candidate)) entries.add(candidate);
  }
  const add = (value, label) => {
    if (typeof value === 'string') {
      entries.add(manifestEntry(root, value, label));
    } else if (Array.isArray(value)) {
      value.forEach((entry, index) => add(entry, `${label}[${index}]`));
    }
  };
  for (const field of ['hooks', 'agents', 'skills', 'mcpServers']) {
    if (manifest[field] !== undefined) add(manifest[field], `plugin manifest ${field}`);
  }
  if (manifest.mcpServers !== undefined) {
    for (const relative of ['scripts', 'mcp-runtime/package.json', 'mcp-runtime/package-lock.json']) {
      const candidate = path.join(root, relative);
      if (fs.existsSync(candidate)) entries.add(candidate);
    }
  }
  return [...entries];
}

function collectRuntimeFiles(root, manifest) {
  const files = new Map();
  const visit = (candidate) => {
    let stat;
    try { stat = fs.lstatSync(candidate); }
    catch (_error) { fail('runtime entry is unavailable'); }
    if (stat.isSymbolicLink()) fail('runtime symlinks are forbidden');
    if (stat.isFile()) {
      if (stat.size > MAX_RUNTIME_FILE_BYTES) fail('runtime file exceeds size limit');
      const relative = path.relative(root, candidate).split(path.sep).join('/');
      files.set(relative, { file: candidate, size: stat.size });
      if (files.size > MAX_RUNTIME_FILES) fail('runtime file count exceeds limit');
      return;
    }
    if (!stat.isDirectory()) fail('runtime entry type is unsupported');
    for (const child of fs.readdirSync(candidate).sort()) visit(path.join(candidate, child));
  };
  for (const entry of runtimeEntries(root, manifest)) visit(entry);
  return [...files.entries()].sort(([left], [right]) => left.localeCompare(right));
}

function computeClaudeRuntimeDigest(pluginRoot) {
  const root = canonicalDirectory(pluginRoot, 'plugin root');
  const manifest = readJson(path.join(root, '.claude-plugin', 'plugin.json'));
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)
      || manifest.name !== 'zensu' || typeof manifest.version !== 'string'
      || manifest.version.trim() === '') {
    fail('Claude plugin manifest is invalid');
  }
  const digest = crypto.createHash('sha256').update(RUNTIME_DOMAIN);
  let totalBytes = 0;
  for (const [relative, entry] of collectRuntimeFiles(root, manifest)) {
    totalBytes += entry.size;
    if (totalBytes > MAX_RUNTIME_TOTAL_BYTES) fail('runtime assets exceed total size limit');
    const content = stableFile(entry.file, MAX_RUNTIME_FILE_BYTES);
    if (content.length !== entry.size) fail('runtime file changed during digest');
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

function readAndValidateContext(file, expected) {
  const context = readJson(file);
  exactKeys(context, CONTEXT_KEYS, 'context');
  exactKeys(context.principal_profiles, PROFILE_KEYS, 'context principal profile');
  const digest = requireText(expected.runtimeDigest, 'expected runtime digest');
  const values = {
    schema: 'zensu.session-control',
    schema_version: 1,
    host: 'claude',
    session_id_hash: sessionIdHash(expected.sessionId),
    project_root: expected.projectRoot,
    plugin_root: expected.pluginRoot,
    plugin_data: expected.pluginData,
    plugin_version: expected.pluginVersion,
    source_revision: digest,
    runtime_digest: digest,
  };
  for (const [field, value] of Object.entries(values)) {
    if (context[field] !== value) fail(`context ${field} mismatch`);
  }
  if (!HASH_RE.test(digest) || !Number.isFinite(Date.parse(context.created_at))) {
    fail('context provenance is invalid');
  }
  const profiles = {
    main: 'main-v1',
    reviewer: 'reviewer-readonly-v1',
    evidence_worker: 'evidence-worker-v1',
    host: 'host-profile-v1',
  };
  if (Object.entries(profiles).some(([field, value]) => context.principal_profiles[field] !== value)) {
    fail('context principal profiles mismatch');
  }
  return context;
}

function readAndValidateInitialWorkflow(file, expected) {
  const state = readJson(file);
  exactKeys(state, INITIAL_WORKFLOW_KEYS, 'initial workflow');
  const scalar = {
    schema: 'zensu.workflow-state',
    schema_version: 1,
    session_id_hash: sessionIdHash(expected.sessionId),
    workflow_state: 'idle',
    revision: 1,
    last_event: 'session-start',
    actor: 'main-v1',
    active: false,
    vanilla: false,
    implComplete: false,
    chainDone: false,
    codeReviewDone: false,
    selfReviewFixed: false,
    workflowActive: false,
    reviewTicket: '',
    reviewTicketConsumed: true,
    reviewRound: 0,
    stopBlockCount: 0,
    deferredReviewClaim: '',
    phase: 'UNINITIALIZED',
    step_id: '',
  };
  for (const [field, value] of Object.entries(scalar)) {
    if (state[field] !== value) fail(`initial workflow ${field} mismatch`);
  }
  if (!Number.isFinite(Date.parse(state.updated_at))
      || !Array.isArray(state.workflowTools) || state.workflowTools.length !== 0
      || !Array.isArray(state.bypasses) || state.bypasses.length !== 0
      || !Array.isArray(state.history) || state.history.length !== 0) {
    fail('initial workflow collections or timestamp are invalid');
  }
  return state;
}

module.exports = {
  IndependentVerifierError,
  computeClaudeRuntimeDigest,
  readAndValidateContext,
  readAndValidateInitialWorkflow,
  sessionIdHash,
  sessionKey,
};
