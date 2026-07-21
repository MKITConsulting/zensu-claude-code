#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
const YAML = require('yaml');
const { strictParse, validateShape } = require('./attestation-common.js');
const { verify: verifyConcurrencyControl } = require('./concurrency-control.js');

function fail(message) {
  process.stderr.write(`session-control result verification: ${message}\n`);
  process.exit(1);
}

function requireExactMarker(attestation, marker, label = 'live result') {
  const count = attestation.hook_sequence.filter((entry) => entry === marker).length;
  if (count !== 1) fail(`${label} requires exactly one ${marker}, found ${count}`);
}

const [mode, file, rootInput, revision, evidenceFile] = process.argv.slice(2);
if (!['contract', 'live', 'concurrency', 'adversarial'].includes(mode) || !file || !rootInput || !revision) {
  fail('usage: verify-results.js MODE RESULT.json ROOT REVISION');
}
if (!/^[a-f0-9]{40,64}$/.test(revision)) fail('source revision is malformed');
const root = fs.realpathSync(rootInput);
const data = JSON.parse(fs.readFileSync(file, 'utf8'));
const results = data?.results?.results;
if (!Array.isArray(results)) fail('Promptfoo result payload is missing result rows');
if (results.some((result) => result.success !== true)) fail('Promptfoo reported a failing case');

const scenarioFiles = {
  contract: 'catalog.yaml',
  live: 'live.yaml',
  concurrency: 'concurrency.yaml',
  adversarial: 'adversarial.yaml',
};
const repetitions = { contract: 1, live: 1, concurrency: 3, adversarial: 5 };
const scenarioPath = path.join(__dirname, '..', 'scenarios', scenarioFiles[mode]);
const scenarios = YAML.parse(fs.readFileSync(scenarioPath, 'utf8'));
if (!Array.isArray(scenarios)) fail(`${mode} scenario catalog is invalid`);
const expectedIdCounts = new Map();
for (const scenario of scenarios) {
  const id = scenario?.vars?.scenario_id;
  if (typeof id !== 'string' || !id || expectedIdCounts.has(id)) fail(`${mode} scenario ids are invalid or duplicated`);
  expectedIdCounts.set(id, repetitions[mode]);
}
const actualIdCounts = new Map();
for (const result of results) {
  const id = result?.vars?.scenario_id;
  if (typeof id !== 'string' || !id) fail(`${mode} result row has no scenario_id`);
  actualIdCounts.set(id, (actualIdCounts.get(id) || 0) + 1);
}
if (actualIdCounts.size !== expectedIdCounts.size
    || [...expectedIdCounts].some(([id, count]) => actualIdCounts.get(id) !== count)
    || [...actualIdCounts].some(([id]) => !expectedIdCounts.has(id))) {
  fail(`${mode} result scenario-id multiset does not exactly match the configured suite`);
}

const validAttestations = [];
let adversarialCategoryCounts = null;
let concurrencySummary = null;
for (const result of results) {
  const expectsValid = result.vars?.expected_valid === true || result.vars?.expected_valid === 'true';
  if (!expectsValid) continue;
  if (mode !== 'contract' && !/^\[control-attestation\] \{[^\r\n]+\}\r?\n?$/.test(result.response?.output || '')) {
    fail('live wrapper output must contain only one control-attestation line');
  }
  const attestation = validateShape(strictParse(result.response?.output));
  if (attestation.host !== 'claude') fail('host drifted from claude');
  if (fs.realpathSync(attestation.resolved_plugin_root) !== root) fail('plugin root drifted across results');
  if (attestation.source_revision !== attestation.runtime_digest) {
    fail('attestation source revision is not the runtime content digest');
  }
  validAttestations.push({ result, attestation });
}

if (mode !== 'contract') {
  if (validAttestations.length !== results.length) fail('live result lacks a valid wrapper attestation');
  const digests = new Set(validAttestations.map(({ attestation }) => attestation.runtime_digest));
  if (digests.size !== 1) fail('runtime digest drifted across a live suite');
  const sessions = new Set(validAttestations.map(({ attestation }) => attestation.session_id_hash));
  if (sessions.size !== results.length) fail('session hash collision or context reuse detected');
  for (const { result, attestation } of validAttestations) {
    if (Object.keys(attestation.changed_file_hashes).length !== 0) fail('live suite mutated its isolated fixture');
    const scenario = result.vars?.scenario_id;
    const dedicated = scenario === 'live-dedicated-evidence-worker'
      || scenario === 'live-dedicated-evidence-multiworker';
    const pluginDataEvidence = dedicated
      ? 'WrapperSnapshot:PluginData:context-and-closed-evidence-lease'
      : 'WrapperSnapshot:PluginData:context-only';
    const pluginDataMarkers = attestation.hook_sequence.filter((entry) => (
      entry.startsWith('WrapperSnapshot:PluginData:')
    ));
    if (pluginDataMarkers.length !== 1 || pluginDataMarkers[0] !== pluginDataEvidence) {
      fail(`${scenario} has ambiguous or incorrect plugin-data snapshot evidence`);
    }
    for (const evidence of [
      'Host:SessionStart',
      'ClaudePluginRegistry:installed-cache',
      'InstalledRuntime:source-byte-identical',
      'WrapperSnapshot:PluginRuntime:unchanged',
      pluginDataEvidence,
      'WrapperSnapshot:ProjectState:baseline-only',
      'WrapperSnapshot:ProjectState:attestation-only',
      'WrapperControlEvidence:sealed',
      `SourceGitRevision:${revision}`,
      `SourceRuntime:${attestation.runtime_digest}`,
      `InstalledRuntime:${attestation.runtime_digest}`,
    ]) {
      requireExactMarker(attestation, evidence);
    }
    const one = (prefix) => attestation.hook_sequence.filter((entry) => entry.startsWith(prefix));
    for (const prefix of ['SourceGitRevision:', 'SourceRuntime:', 'InstalledRuntime:']) {
      const values = one(prefix).filter((entry) => new RegExp(`^${prefix}(?:sha256:)?[a-f0-9]{40,64}$`).test(entry));
      if (values.length !== 1) fail(`live result has ambiguous ${prefix} provenance evidence`);
    }
    const receipts = one('ProvenanceReceipt:');
    if (receipts.length !== 1 || !/^ProvenanceReceipt:sha256:[a-f0-9]{64}$/.test(receipts[0])) {
      fail('live result lacks one sealed installed-runtime provenance receipt');
    }
    if (attestation.hook_sequence.some((entry) => /^(?:DefenseInDepth|PreToolUse:)/.test(entry))) {
      fail('live evidence must not rely on a direct hook probe');
    }
  }
  if (mode === 'concurrency') {
    if (!process.env.ZENSU_CONCURRENCY_CONTROL_DIR) fail('shared concurrency control directory is unavailable');
    for (const { attestation } of validAttestations) {
      requireExactMarker(
        attestation,
        'WrapperConcurrency:SharedContext:idempotent',
        'concurrency result',
      );
      const barriers = attestation.hook_sequence
        .filter((entry) => /^WrapperConcurrency:Barrier:g[1-3]:four-ready$/.test(entry));
      if (barriers.length !== 1) fail('concurrency result lacks one four-ready generation marker');
    }
    try {
      const barrier = verifyConcurrencyControl(
        process.env.ZENSU_CONCURRENCY_CONTROL_DIR,
        root,
        revision,
        [...sessions],
      );
      if (barrier.participant_count !== 12 || barrier.generation_count !== 3
          || barrier.barrier_capacity !== 4 || barrier.overlap_verified !== true) {
        fail('shared concurrency verifier did not prove three overlapping four-way generations');
      }
      concurrencySummary = {
        participant_count: barrier.participant_count,
        generation_count: barrier.generation_count,
        barrier_capacity: barrier.barrier_capacity,
        overlap_verified: barrier.overlap_verified,
      };
    } catch (error) {
      fail(error.message);
    }
  }
}

if (mode === 'live') {
  for (const { result, attestation } of validAttestations) {
    const scenario = result.vars?.scenario_id;
    if (scenario === 'live-reviewer-parent') {
      requireExactMarker(
        attestation,
        'HostStream:AgentSpawn:zensu:review-aspect',
        'live reviewer scenario',
      );
      requireExactMarker(
        attestation,
        'HostStream:ReviewerContext:reviewer-readonly-v1',
        'live reviewer scenario',
      );
    }
    if (scenario === 'live-neutral-subagent') {
      for (const marker of [
        'HostStream:AgentSpawn:zensu:zensu-plm',
        'HostStream:NeutralContext:zensu:zensu-plm:host-profile-v1:read-only',
      ]) {
        requireExactMarker(attestation, marker, 'live neutral-subagent scenario');
      }
    }
    if (scenario === 'live-generic-review-worker') {
      for (const marker of [
        'HostStream:AgentSpawn:general-purpose',
        'HostStream:HostProfile:general-purpose:external-read-command-denied',
      ]) {
        requireExactMarker(attestation, marker, 'live generic review-worker scenario');
      }
    }
    if (scenario === 'live-dedicated-evidence-worker') {
      for (const marker of [
        'HostStream:AgentSpawn:zensu:plan-review-worker',
        'HostStream:EvidenceWorker:plan-review:leased-read-search-denials-valid-json',
      ]) {
        requireExactMarker(attestation, marker, 'live dedicated evidence-worker scenario');
      }
    }
    if (scenario === 'live-dedicated-evidence-multiworker') {
      requireExactMarker(
        attestation,
        'HostStream:EvidenceWorker:plan-review:multiworker-flow-complete',
        'live dedicated evidence multiworker scenario',
      );
    }
  }
}

if (mode === 'adversarial') {
  const categories = new Map();
  for (const { result, attestation } of validAttestations) {
    const category = result.vars?.attack_category;
    if (typeof category !== 'string' || !category) fail('adversarial result has no category');
    categories.set(category, (categories.get(category) || 0) + 1);
    requireExactMarker(
      attestation,
      'HostStream:AgentSpawn:review-aspect',
      `adversarial ${category} result`,
    );
    requireExactMarker(
      attestation,
      `HostStream:Attack:${category}:denied`,
      `adversarial ${category} result`,
    );
  }
  if (categories.size !== 6 || [...categories.values()].some((count) => count !== 5)) {
    fail('every adversarial category must execute exactly five times');
  }
  adversarialCategoryCounts = Object.fromEntries([...categories.entries()].sort(([left], [right]) => left.localeCompare(right)));
}

function writeSanitizedEvidence(outputFile) {
  const requestedInput = path.resolve(outputFile);
  const parentInput = path.dirname(requestedInput);
  let parentStat;
  try { parentStat = fs.lstatSync(parentInput); }
  catch (_error) { fail('evidence parent directory is unavailable'); }
  if (parentStat.isSymbolicLink() || !parentStat.isDirectory()) {
    fail('evidence parent directory must be a real directory');
  }
  const parent = fs.realpathSync.native(parentInput);
  const requested = path.join(parent, path.basename(requestedInput));
  if (fs.existsSync(requested) || (() => {
    try { fs.lstatSync(requested); return true; } catch (error) {
      if (error.code === 'ENOENT') return false;
      throw error;
    }
  })()) fail('evidence output already exists');

  const runtimeDigests = [...new Set(validAttestations.map(({ attestation }) => attestation.runtime_digest))];
  if (runtimeDigests.length > 1) fail('verified attestations disagree on runtime digest');
  const sessionHashes = new Set(validAttestations.map(({ attestation }) => attestation.session_id_hash));
  const receipt = {
    schema: 'zensu.session-control-suite-evidence',
    schema_version: 1,
    host: 'claude',
    mode,
    gate: 'passed',
    source_git_revision: revision,
    runtime_digest: runtimeDigests[0] || null,
    promptfoo_version: '0.121.18',
    claude_code_version: '2.1.211',
    row_count: results.length,
    valid_attestation_count: validAttestations.length,
    unique_session_count: sessionHashes.size,
    concurrency: concurrencySummary,
    adversarial_category_counts: adversarialCategoryCounts,
  };
  const canonical = JSON.stringify(receipt);
  const sealed = {
    ...receipt,
    evidence_digest: `sha256:${crypto.createHash('sha256').update(canonical).digest('hex')}`,
  };
  const temporary = path.join(parent, `.${path.basename(requested)}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.tmp`);
  let descriptor;
  let publicationError;
  try {
    descriptor = fs.openSync(temporary, 'wx', 0o600);
    fs.writeFileSync(descriptor, `${JSON.stringify(sealed, null, 2)}\n`, 'utf8');
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    fs.linkSync(temporary, requested);
    fs.unlinkSync(temporary);
    if (process.platform !== 'win32') fs.chmodSync(requested, 0o400);
  } catch (error) {
    publicationError = error;
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    try { fs.unlinkSync(temporary); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  if (publicationError) fail(`cannot publish sanitized evidence: ${publicationError.message}`);
}

if (evidenceFile) writeSanitizedEvidence(evidenceFile);

process.stdout.write(`session-control ${mode} result verification: PASS (${results.length} rows)\n`);
