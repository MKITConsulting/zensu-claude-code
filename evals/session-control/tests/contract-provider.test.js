#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { strictParse } = require('../lib/attestation-common.js');
const { MARKERS: evidenceWorkerMarkers } = require('../lib/evidence-worker-contract.js');

const root = path.resolve(__dirname, '..', '..', '..');
const provider = path.join(root, 'evals', 'session-control', 'lib', 'contract-provider.js');

function runScenario(scenario) {
  const result = spawnSync(process.execPath, [
    provider,
    `scenario=${scenario}`,
    JSON.stringify({ vars: { scenario_id: scenario } }),
  ], {
    cwd: root,
    encoding: 'utf8',
    env: process.env,
    timeout: 120000,
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  const attestation = strictParse(result.stdout);
  assert.equal(attestation.host, 'claude');
  assert.equal(attestation.workflow_state, 'contract_verified');
  assert.equal(attestation.revision, 2);
  assert.equal(attestation.exit_code, 0);
  return attestation;
}

runScenario('pretool-deleted-cas-deny');
for (const [scenario, expectedMarker] of [
  ['bare-reviewer-types', 'Contract:SessionStartAgent:Reviewers:reviewer-readonly-v1'],
  ['unknown-neutral-profile', 'Contract:SessionStartAgent:Unknown:host-profile-v1'],
  ['plm-readonly-boundary', 'Contract:ZensuPlm:SessionStart:host-profile-v1:ReadOnly:WriteDenied'],
  ['generic-review-worker-boundary', 'Contract:GeneralPurpose:host-profile-v1:OrdinaryNonCommandToolsAllowed:AllCommandToolsDenied'],
  ['native-helper-binding', 'Contract:NativeSkillBinding:PerCall:EnvFileUntouched:AmbientSelectorsIgnored:ForeignAndDerivedSessionDenied'],
]) {
  const attestation = runScenario(scenario);
  assert.equal(
    attestation.hook_sequence.filter((entry) => entry === expectedMarker).length,
    1,
    `${scenario} did not emit its exact executable contract marker`,
  );
}
for (const [scenario, expectedMarker] of Object.entries(evidenceWorkerMarkers)) {
  const attestation = runScenario(scenario);
  assert.equal(
    attestation.hook_sequence.filter((entry) => entry === expectedMarker).length,
    1,
    `${scenario} did not emit its exact executable evidence-worker marker`,
  );
}
process.stdout.write('contract-provider.test.js: PASS\n');
