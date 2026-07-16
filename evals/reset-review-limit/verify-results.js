#!/usr/bin/env node
'use strict';

const fs = require('node:fs');

function fail(message) {
  process.stderr.write(`reset-review-limit result verification: ${message}\n`);
  process.exit(1);
}

const file = process.argv[2];
if (!file) fail('usage: verify-results.js RESULT.json');
const payload = JSON.parse(fs.readFileSync(file, 'utf8'));
const rows = payload?.results?.results;
if (!Array.isArray(rows)) fail('Promptfoo result payload is missing rows');
if (rows.length !== 9 || rows.some((row) => row.success !== true)) {
  fail('Promptfoo must report exactly nine passing rows');
}
const expected = new Map([
  ['reset-cas-happy', 3],
  ['reset-invalid-state', 3],
  ['reset-sidecar-isolation', 3],
]);
const actual = new Map();
for (const row of rows) {
  const id = row?.vars?.scenario_id;
  if (typeof id !== 'string' || !expected.has(id)) fail('result contains an unknown or missing scenario_id');
  actual.set(id, (actual.get(id) || 0) + 1);
  const attestations = [...String(row.response?.output || '').matchAll(/^\[reset-review-limit-attestation\] /gm)];
  if (attestations.length !== 1) fail(`${id} lacks exactly one provider-owned attestation`);
}
if ([...expected].some(([id, count]) => actual.get(id) !== count) || actual.size !== expected.size) {
  fail('scenario-id multiset must be exactly three copies of each configured scenario');
}
process.stdout.write('reset-review-limit result verification: PASS (9 rows; exact 3x3 multiset)\n');
