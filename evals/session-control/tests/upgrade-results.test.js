#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const assertion = require('../assertions/upgrade-attestation.js');
const {
  EXECUTION_MODES,
  OLD_RELEASE_REVISION,
  line,
  REQUIRED_SEQUENCE,
} = require('../lib/upgrade-attestation.js');

const verifier = path.resolve(__dirname, '..', 'lib', 'verify-upgrade-results.js');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-upgrade-results-selftest-'));
const revision = '1'.repeat(40);
const RECEIPT_KEYS = Object.freeze([
  'schema',
  'schema_version',
  'host',
  'mode',
  'gate',
  'execution_mode',
  'authenticated_canary_status',
  'candidate_model_backend',
  'candidate_containment',
  'source_git_revision',
  'old_release_ref',
  'old_release_revision',
  'old_version',
  'candidate_installed_version',
  'candidate_version_synthetic',
  'old_runtime_digest',
  'candidate_runtime_digest',
  'lifecycle_evidence_count',
  'promptfoo_version',
  'claude_code_version',
  'evidence_digest',
]);

function digest(value) {
  return `sha256:${crypto.createHash('sha256').update(value).digest('hex')}`;
}

function evidence(executionMode = EXECUTION_MODES.authoritative) {
  return {
    schema: 'zensu.session-control-upgrade-evidence',
    schema_version: 2,
    host: 'claude',
    gate: 'passed',
    execution_mode: executionMode,
    authenticated_canary_status: executionMode === EXECUTION_MODES.authoritative
      ? 'passed-plugin-free-live'
      : executionMode === EXECUTION_MODES.diagnostic
        ? 'not-applicable-hermetic-existing-login-test' : 'passed-deterministic-fake',
    candidate_model_backend: executionMode === EXECUTION_MODES.authoritative
      ? 'deterministic-loopback-anthropic-mock' : 'deterministic-fake-cli',
    candidate_containment: executionMode === EXECUTION_MODES.authoritative
      ? 'linux-bwrap-pid-mount-with-nested-hook-net-v1'
      : 'deterministic-fake-process-tree',
    host_config_cache_canary_status: executionMode === EXECUTION_MODES.authoritative
      ? 'not-applicable-isolated-home'
      : executionMode === EXECUTION_MODES.diagnostic
        ? 'unchanged-local-diagnostic' : 'not-applicable-test-mode',
    claude_code_version: '2.1.211',
    source_git_revision: revision,
    old_release_ref: 'v0.16.1',
    old_release_revision: OLD_RELEASE_REVISION,
    old_version: '0.16.1',
    candidate_source_version: '0.16.1',
    candidate_installed_version: '0.16.2',
    candidate_version_synthetic: true,
    old_runtime_digest: digest('old'),
    candidate_runtime_digest: digest('candidate'),
    old_session_id_hash: digest('old-session'),
    candidate_session_id_hash: digest('candidate-session'),
    old_process_result_count: 3,
    fresh_process_result_count: 1,
    hook_sequence: [...REQUIRED_SEQUENCE],
  };
}

function verify(value, expectedStatus, publishEvidence = true) {
  const resultFile = path.join(temporary, `${crypto.randomUUID()}.json`);
  const evidenceFile = `${resultFile}.evidence.json`;
  fs.writeFileSync(resultFile, JSON.stringify({
    results: {
      results: [{
        success: true,
        vars: { scenario_id: 'upgrade-v0161-side-by-side' },
        response: { output: typeof value === 'string' ? value : line(value) },
      }],
    },
  }));
  const args = [verifier, resultFile, revision];
  if (publishEvidence) args.push(evidenceFile);
  const result = spawnSync(process.execPath, args, {
    encoding: 'utf8',
  });
  assert.equal(result.status, expectedStatus, result.stderr || result.stdout);
  if (expectedStatus === 0 && publishEvidence) {
    const receipt = JSON.parse(fs.readFileSync(evidenceFile, 'utf8'));
    assert.deepEqual(Object.keys(receipt), RECEIPT_KEYS);
    assert.equal(receipt.schema, 'zensu.session-control-upgrade-suite-evidence');
    assert.equal(receipt.schema_version, 2);
    assert.equal(receipt.host, 'claude');
    assert.equal(receipt.mode, 'upgrade');
    assert.equal(receipt.gate, 'passed');
    assert.equal(
      receipt.execution_mode,
      'authoritative-split-auth-canary-contained-candidate',
    );
    assert.equal(receipt.authenticated_canary_status, 'passed-plugin-free-live');
    assert.equal(
      receipt.candidate_model_backend,
      'deterministic-loopback-anthropic-mock',
    );
    assert.equal(
      receipt.candidate_containment,
      'linux-bwrap-pid-mount-with-nested-hook-net-v1',
    );
    assert.equal(receipt.source_git_revision, revision);
    assert.equal(receipt.old_release_ref, 'v0.16.1');
    assert.equal(receipt.old_release_revision, OLD_RELEASE_REVISION);
    assert.equal(receipt.old_version, '0.16.1');
    assert.equal(receipt.candidate_installed_version, '0.16.2');
    assert.equal(receipt.candidate_version_synthetic, true);
    assert.equal(receipt.old_runtime_digest, digest('old'));
    assert.equal(receipt.candidate_runtime_digest, digest('candidate'));
    assert.equal(receipt.lifecycle_evidence_count, REQUIRED_SEQUENCE.length);
    assert.equal(receipt.promptfoo_version, '0.121.18');
    assert.equal(receipt.claude_code_version, '2.1.211');
    assert.match(receipt.evidence_digest, /^sha256:[a-f0-9]{64}$/);
    const canonicalReceipt = Object.fromEntries(
      RECEIPT_KEYS
        .filter((key) => key !== 'evidence_digest')
        .map((key) => [key, receipt[key]]),
    );
    assert.equal(
      receipt.evidence_digest,
      digest(JSON.stringify(canonicalReceipt)),
      'receipt digest must independently bind the exact schema-v2 receipt fields',
    );
    assert.doesNotMatch(
      JSON.stringify(receipt),
      /(?:"(?:response|prompt|session_id)"\s*:|\/private\/|\/Users\/)/,
    );
  } else assert.equal(fs.existsSync(evidenceFile), false);
  return result;
}

try {
  const canonical = evidence();
  const assertionResult = assertion(line(canonical), {
    vars: { expected_source_revision: '0'.repeat(40) },
  });
  const withRevision = assertion(line(canonical), {
    vars: { expected_source_revision: revision },
  });
  assert.equal(assertionResult.pass, false);
  assert.equal(withRevision.pass, true);
  verify(canonical, 0);
  const diagnostic = evidence(EXECUTION_MODES.diagnostic);
  assert.match(verify(diagnostic, 0, false).stdout, /NON-AUTHORITATIVE/);
  verify(diagnostic, 1, true);
  const fake = evidence(EXECUTION_MODES.fake);
  assert.match(verify(fake, 0, false).stdout, /NON-AUTHORITATIVE/);
  verify(fake, 1, true);

  for (const mutate of [
    (value) => { value.schema_version = 1; },
    (value) => { value.unexpected_boundary = true; },
    (value) => { delete value.candidate_containment; },
    (value) => { value.authenticated_canary_status = 'passed-deterministic-fake'; },
    (value) => { value.candidate_model_backend = 'deterministic-fake-cli'; },
    (value) => { value.candidate_containment = 'deterministic-fake-process-tree'; },
    (value) => { value.host_config_cache_canary_status = 'not-applicable-test-mode'; },
    (value) => { value.hook_sequence.splice(4, 1); },
    (value) => { value.hook_sequence.reverse(); },
    (value) => { value.old_runtime_digest = value.candidate_runtime_digest; },
    (value) => { value.old_session_id_hash = value.candidate_session_id_hash; },
    (value) => { value.old_process_result_count = 2; },
    (value) => { value.candidate_installed_version = '0.16.1'; },
    (value) => { value.old_release_revision = '2'.repeat(40); },
  ]) {
    const invalid = evidence();
    mutate(invalid);
    let output;
    try { output = line(invalid); }
    catch (_error) { output = `[control-upgrade-attestation] ${JSON.stringify(invalid)}`; }
    verify(output, 1);
  }
  process.stdout.write('upgrade-results.test.js: PASS\n');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
