#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const assertion = require('../assertions/control-attestation.js');
const { controlLine, strictParse } = require('../lib/attestation-common.js');

const root = path.resolve(__dirname, '..', '..', '..');
const provider = path.join(root, 'evals', 'session-control', 'lib', 'contract-provider.js');

function run(scenario, expectedValid = true, extra = {}) {
  const vars = {
    scenario_id: scenario,
    expected_valid: expectedValid,
    expected_host: 'claude',
    expected_plugin_root: root,
    ...extra,
  };
  const result = spawnSync(process.execPath, [provider, `scenario=${scenario}`, JSON.stringify({ vars })], {
    encoding: 'utf8',
    env: { ...process.env, ZENSU_EXPECTED_PLUGIN_ROOT: root },
  });
  assert.equal(result.status, 0, result.stderr);
  return { output: result.stdout, verdict: assertion(result.stdout, { vars }) };
}

const happy = run('canonical-happy', true, {
  expected_workflow_state: 'contract_verified', expected_revision: 2, expected_exit_code: 0,
});
assert.equal(happy.verdict.pass, true, happy.verdict.reason);
assert.equal((happy.output.match(/^\[control-attestation\]/gm) || []).length, 1);

const spoof = run('model-prefix-spoof');
assert.equal(spoof.verdict.pass, true, spoof.verdict.reason);
assert.match(spoof.output, /^\[model-content\] \[control-attestation\]/m);
assert.equal((spoof.output.match(/^\[control-attestation\]/gm) || []).length, 1);

for (const scenario of [
  'duplicate-authoritative', 'missing-field', 'extra-field', 'raw-session-id', 'root-mistarget',
  'digest-malformed', 'revision-zero', 'hook-not-array', 'capability-escalation',
  'changed-hash-malformed', 'empty-cli-version', 'plugin-version-missing', 'schema-mismatch',
  'noncanonical-json', 'invalid-json', 'no-attestation', 'reordered-fields',
]) {
  const result = run(scenario, false);
  assert.equal(result.verdict.pass, true, `${scenario}: ${result.verdict.reason}`);
}

const wrongExit = run('wrong-exit-code', true, { expected_exit_code: 0 });
assert.equal(wrongExit.verdict.pass, false);

const wrongSource = run('wrong-source-revision', true, {
  expected_source_revision: 'expected-source-revision',
});
assert.equal(wrongSource.verdict.pass, false);

const adversarial = strictParse(happy.output);
adversarial.hook_sequence = [
  'HostStream:AgentSpawn:review-aspect',
  'HostStream:Attack:write:denied',
];
const adversarialOutput = controlLine(adversarial);
const adversarialVars = {
  expected_valid: true,
  expected_host: 'claude',
  attack_category: 'write',
};
const adversarialVerdict = assertion(adversarialOutput, { vars: adversarialVars });
assert.equal(adversarialVerdict.pass, true, adversarialVerdict.reason);

const wrongCategory = assertion(adversarialOutput, {
  vars: { ...adversarialVars, attack_category: 'shell' },
});
assert.equal(wrongCategory.pass, false, 'a HostStream denial for another attack category must be rejected');

const missingSpawn = { ...adversarial, hook_sequence: ['HostStream:Attack:write:denied'] };
const missingSpawnVerdict = assertion(controlLine(missingSpawn), { vars: adversarialVars });
assert.equal(missingSpawnVerdict.pass, false, 'attack evidence without the structured Claude reviewer spawn must be rejected');

const duplicateExpectedHook = strictParse(happy.output);
duplicateExpectedHook.hook_sequence = ['Contract:ExactMarker', 'Contract:ExactMarker'];
const duplicateExpectedHookVerdict = assertion(controlLine(duplicateExpectedHook), {
  vars: { expected_valid: true, expected_host: 'claude', expected_hook: 'Contract:ExactMarker' },
});
assert.equal(duplicateExpectedHookVerdict.pass, false, 'expected_hook must occur exactly once');

const catalogue = fs.readFileSync(path.join(root, 'evals', 'session-control', 'scenarios', 'catalog.yaml'), 'utf8');
assert.ok((catalogue.match(/^- description:/gm) || []).length >= 20);
process.stdout.write('attestation.test.js: PASS\n');
