#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { strictParse } = require('../lib/attestation-common.js');

const root = path.resolve(__dirname, '..', '..', '..');
const provider = path.join(root, 'evals', 'session-control', 'lib', 'contract-provider.js');

const result = spawnSync(process.execPath, [
  provider,
  'scenario=pretool-deleted-cas-deny',
  JSON.stringify({ vars: { scenario_id: 'pretool-deleted-cas-deny' } }),
], {
  cwd: root,
  encoding: 'utf8',
  env: process.env,
  timeout: 30000,
});

assert.equal(result.status, 0, result.stderr || result.stdout);
const attestation = strictParse(result.stdout);
assert.equal(attestation.host, 'claude');
assert.equal(attestation.workflow_state, 'contract_verified');
assert.equal(attestation.revision, 2);
assert.equal(attestation.exit_code, 0);
process.stdout.write('contract-provider.test.js: PASS\n');
