'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const root = fs.realpathSync.native(path.resolve(__dirname, '..', '..', '..'));
const core = require(path.join(root, 'hooks', 'lib', 'session-control-core-v1.js'));
const expectedRuntimeDigest = core.computeRuntimeDigest(root, 'claude');
const expectedPluginVersion = JSON.parse(fs.readFileSync(path.join(root, '.claude-plugin', 'plugin.json'), 'utf8')).version;

function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function fail(reason) {
  return { pass: false, score: 0, reason };
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

module.exports = (output, context = {}) => {
  const matches = [...String(output).matchAll(/^\[reset-review-limit-attestation\] (\{[^\r\n]+\})$/gm)];
  if (matches.length !== 1) return fail(`expected exactly one provider-owned attestation, got ${matches.length}`);
  let attestation;
  try { attestation = JSON.parse(matches[0][1]); }
  catch (_error) { return fail('provider-owned attestation is invalid JSON'); }

  const digest = attestation.evidence_digest;
  const body = { ...attestation };
  delete body.evidence_digest;
  const expectedDigest = `sha256:${crypto.createHash('sha256').update(canonical(body)).digest('hex')}`;
  if (digest !== expectedDigest) return fail('provider-owned evidence digest mismatch');

  const vars = context.vars || context.test?.vars || {};
  const scenario = String(vars.scenario_id || '');
  if (attestation.schema !== 'zensu.reset-review-limit.attestation'
      || attestation.schema_version !== 1
      || attestation.provider_owned !== true
      || attestation.scenario_id !== scenario) return fail('attestation envelope or scenario binding mismatch');
  let resolvedPluginRoot;
  try { resolvedPluginRoot = fs.realpathSync.native(attestation.resolved_plugin_root); }
  catch (_error) { return fail('attested plugin root is unavailable'); }
  if (resolvedPluginRoot !== root || attestation.runtime_digest !== expectedRuntimeDigest
      || attestation.plugin_version !== expectedPluginVersion
      || attestation.claude_code_version !== '2.1.211') {
    return fail('attested runtime does not match this exact checkout');
  }
  if (attestation.claude_exit_code !== 0
      || attestation.exact_skill_tool_use_count !== 1
      || attestation.successful_skill_result_count !== 1) return fail('exact successful Skill tool_use evidence is missing');
  if (attestation.forbidden_file_operation_detected !== false
      || attestation.split_reset_mutation_detected !== false) {
    return fail('forbidden file operation or split reset mutation evidence was observed');
  }
  if (!/^tdd-phase-scv1_[a-f0-9]{64}\.json$/.test(attestation.canonical_state_file || '')
      || attestation.before?.file !== attestation.canonical_state_file
      || attestation.after?.file !== attestation.canonical_state_file) return fail('canonical state file binding mismatch');
  if (attestation.fixture_manifest_unchanged !== true) return fail('fixture changed outside the canonical CAS state bytes');

  let invariant = false;
  if (scenario === 'reset-cas-happy') {
    invariant = validReset(attestation.before, attestation.after, 3)
      && attestation.preflight_bash_call_count === 1
      && attestation.failed_preflight_bash_result_count === 0
      && attestation.successful_preflight_bash_result_count === 1
      && attestation.atomic_reset_bash_call_count === 1
      && attestation.failed_atomic_reset_bash_result_count === 0
      && attestation.successful_atomic_reset_bash_result_count === 1;
  } else if (scenario === 'reset-invalid-state') {
    invariant = attestation.before?.status === 'invalid' && attestation.after?.status === 'invalid'
      && attestation.before?.state?.reviewRound === '3'
      && attestation.before?.raw_sha256 === attestation.after?.raw_sha256
      && attestation.post_skill_bash_call_count === 1
      && attestation.preflight_bash_call_count === 1
      && attestation.failed_preflight_bash_result_count === 1
      && attestation.successful_preflight_bash_result_count === 0
      && attestation.atomic_reset_bash_call_count === 0
      && attestation.successful_atomic_reset_bash_result_count === 0;
  } else if (scenario === 'reset-sidecar-isolation') {
    const sidecars = attestation.before?.sidecars;
    invariant = validReset(attestation.before, attestation.after, 2)
      && attestation.preflight_bash_call_count === 1
      && attestation.failed_preflight_bash_result_count === 0
      && attestation.successful_preflight_bash_result_count === 1
      && attestation.atomic_reset_bash_call_count === 1
      && attestation.failed_atomic_reset_bash_result_count === 0
      && attestation.successful_atomic_reset_bash_result_count === 1
      && sidecars?.stopblocks?.present === true
      && sidecars?.stopblocks?.kind === 'symlink'
      && sidecars?.stopblocks?.target_inside_state === true
      && sidecars?.stopblocks?.target_text?.trim() === 'do-not-touch'
      && sidecars?.rounds?.present === true
      && canonical(sidecars) === canonical(attestation.after?.sidecars);
  }
  if (!invariant || attestation.provider_invariant_pass !== true || attestation.infrastructure_error !== null) {
    return fail('independent post-run CAS/state/sidecar invariant failed');
  }
  return { pass: true, score: 1, reason: 'provider-owned Skill and independent CAS/state evidence verified' };
};
