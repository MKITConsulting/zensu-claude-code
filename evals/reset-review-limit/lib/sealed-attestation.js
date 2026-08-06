#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const { fixtureManifest, snapshot } = require('./state-snapshot.js');

const [
  projectRoot, scenarioId, beforeFile, evidenceFile, coreFile, claudeExitRaw,
  pluginRootInput, expectedBeforeDigest, claudeCliVersion,
] = process.argv.slice(2);

function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function validReset(before, after, round) {
  return before?.status === 'valid' && after?.status === 'valid'
    && before.state?.reviewRound === round && before.state?.stopBlockCount === 2
    && before.state?.chainDone === true && before.state?.codeReviewDone === true
    && before.state?.selfReviewFixed === true
    && before.state?.active === true && before.state?.implComplete === true
    && after.state?.reviewRound === 0 && after.state?.stopBlockCount === 0
    && after.state?.chainDone === false && after.state?.codeReviewDone === false
    && after.state?.selfReviewFixed === false
    && after.state?.active === true && after.state?.implComplete === true
    && after.state?.revision === before.state?.revision + 1;
}

let capture = null;
let beforeEnvelope = null;
let after = null;
let infrastructureError = null;
let pluginRoot = null;
let runtimeDigest = null;
let pluginVersion = null;
let afterFixtureManifest = null;
try {
  pluginRoot = fs.realpathSync.native(pluginRootInput);
  const core = require(coreFile);
  runtimeDigest = core.computeRuntimeDigest(pluginRoot, 'claude');
  pluginVersion = JSON.parse(fs.readFileSync(`${pluginRoot}/.claude-plugin/plugin.json`, 'utf8')).version;
  const beforeBytes = fs.readFileSync(beforeFile);
  const observedBeforeDigest = `sha256:${crypto.createHash('sha256').update(beforeBytes).digest('hex')}`;
  if (observedBeforeDigest !== expectedBeforeDigest) throw new Error('provider before snapshot digest changed');
  beforeEnvelope = JSON.parse(beforeBytes.toString('utf8'));
  capture = JSON.parse(fs.readFileSync(evidenceFile, 'utf8'));
  after = snapshot(projectRoot, coreFile);
  afterFixtureManifest = fixtureManifest(projectRoot, after.file);
} catch (error) {
  infrastructureError = String(error.message || error);
}

const common = capture?.schema === 'zensu.reset-review-limit.stream-evidence'
  && capture?.scenario_id === scenarioId
  && beforeEnvelope?.schema === 'zensu.reset-review-limit.provider-before'
  && beforeEnvelope?.scenario_id === scenarioId
  && capture?.exact_skill_tool_use_count === 1
  && capture?.successful_skill_result_count === 1
  && capture?.forbidden_file_operation_detected === false
  && capture?.split_reset_mutation_detected === false
  && claudeCliVersion === '2.1.221'
  && Number(claudeExitRaw) === 0
  && beforeEnvelope?.snapshot?.file === after?.file
  && canonical(beforeEnvelope?.fixture_manifest) === canonical(afterFixtureManifest)
  && /^tdd-phase-scv1_[a-f0-9]{64}\.json$/.test(after?.file || '');

const executionInvariant = scenarioId === 'reset-invalid-state'
  ? capture?.post_skill_bash_call_count === 1
    && capture?.preflight_bash_call_count === 1
    && capture?.failed_preflight_bash_result_count === 1
    && capture?.successful_preflight_bash_result_count === 0
    && capture?.atomic_reset_bash_call_count === 0
    && capture?.successful_atomic_reset_bash_result_count === 0
  : capture?.preflight_bash_call_count === 1
    && capture?.failed_preflight_bash_result_count === 0
    && capture?.successful_preflight_bash_result_count === 1
    && capture?.atomic_reset_bash_call_count === 1
    && capture?.failed_atomic_reset_bash_result_count === 0
    && capture?.successful_atomic_reset_bash_result_count === 1;

let scenarioInvariant = false;
if (scenarioId === 'reset-cas-happy') {
  scenarioInvariant = validReset(beforeEnvelope?.snapshot, after, 3);
} else if (scenarioId === 'reset-invalid-state') {
  scenarioInvariant = beforeEnvelope?.snapshot?.status === 'invalid' && after?.status === 'invalid'
    && beforeEnvelope?.snapshot?.state?.reviewRound === '3'
    && beforeEnvelope?.snapshot?.raw_sha256 === after?.raw_sha256;
} else if (scenarioId === 'reset-sidecar-isolation') {
  const sidecars = beforeEnvelope?.snapshot?.sidecars;
  scenarioInvariant = validReset(beforeEnvelope?.snapshot, after, 2)
    && sidecars?.stopblocks?.present === true
    && sidecars?.stopblocks?.kind === 'symlink'
    && sidecars?.stopblocks?.target_inside_state === true
    && sidecars?.stopblocks?.target_text?.trim() === 'do-not-touch'
    && sidecars?.rounds?.present === true
    && canonical(sidecars) === canonical(after?.sidecars);
}

const body = {
  schema: 'zensu.reset-review-limit.attestation',
  schema_version: 1,
  scenario_id: scenarioId || null,
  provider_owned: true,
  resolved_plugin_root: pluginRoot,
  runtime_digest: runtimeDigest,
  plugin_version: pluginVersion,
  claude_code_version: claudeCliVersion || null,
  claude_exit_code: Number(claudeExitRaw),
  exact_skill_tool_use_count: capture?.exact_skill_tool_use_count ?? 0,
  successful_skill_result_count: capture?.successful_skill_result_count ?? 0,
  forbidden_file_operation_detected: capture?.forbidden_file_operation_detected ?? null,
  split_reset_mutation_detected: capture?.split_reset_mutation_detected ?? null,
  post_skill_bash_call_count: capture?.post_skill_bash_call_count ?? 0,
  preflight_bash_call_count: capture?.preflight_bash_call_count ?? 0,
  failed_preflight_bash_result_count: capture?.failed_preflight_bash_result_count ?? 0,
  successful_preflight_bash_result_count: capture?.successful_preflight_bash_result_count ?? 0,
  atomic_reset_bash_call_count: capture?.atomic_reset_bash_call_count ?? 0,
  failed_atomic_reset_bash_result_count: capture?.failed_atomic_reset_bash_result_count ?? 0,
  successful_atomic_reset_bash_result_count: capture?.successful_atomic_reset_bash_result_count ?? 0,
  canonical_state_file: after?.file || null,
  fixture_manifest_unchanged: canonical(beforeEnvelope?.fixture_manifest) === canonical(afterFixtureManifest),
  before: beforeEnvelope?.snapshot || null,
  after,
  provider_invariant_pass: Boolean(common && executionInvariant && scenarioInvariant && !infrastructureError),
  infrastructure_error: infrastructureError,
};
const digest = `sha256:${crypto.createHash('sha256').update(canonical(body)).digest('hex')}`;
process.stdout.write(`\n[reset-review-limit-attestation] ${JSON.stringify({ ...body, evidence_digest: digest })}\n`);
