#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const verifier = path.resolve(__dirname, '..', 'verify-results.js');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-reset-results-test-'));
const ids = ['reset-cas-happy', 'reset-invalid-state', 'reset-sidecar-isolation'];

function verify(rows, expected) {
  const file = path.join(temporary, `${Math.random()}.json`);
  fs.writeFileSync(file, JSON.stringify({ results: { results: rows } }));
  const result = spawnSync(process.execPath, [verifier, file], { encoding: 'utf8' });
  assert.equal(result.status, expected, result.stderr || result.stdout);
}

function row(id) {
  return {
    success: true,
    vars: { scenario_id: id },
    response: { output: '[reset-review-limit-attestation] {}\n' },
  };
}

try {
  const valid = ids.flatMap((id) => [row(id), row(id), row(id)]);
  verify(valid, 0);
  verify(valid.slice(0, 8), 1);
  const duplicate = valid.map((entry) => JSON.parse(JSON.stringify(entry)));
  duplicate[8].vars.scenario_id = 'reset-cas-happy';
  verify(duplicate, 1);
  const failing = valid.map((entry) => JSON.parse(JSON.stringify(entry)));
  failing[0].success = false;
  verify(failing, 1);
  process.stdout.write('reset results.test.js: PASS\n');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
