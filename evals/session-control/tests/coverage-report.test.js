#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { parseCoverageRows } = require('./coverage-report.js');

test('parses hierarchical coverage rows from Node 20 and newer TAP markers', () => {
  const rows = parseCoverageRows([
    '# evals                                |        |          |         |',
    '#  session-control                     |        |          |         |',
    '#   lib                                |        |          |         |',
    '#    upgrade-attestation.js            |  91.25 |    80.00 |  100.00 |',
    'ℹ tests                                |        |          |         |',
    'ℹ  structure                           |        |          |         |',
    'ℹ   fixtures                           |        |          |         |',
    'ℹ    install-claude-runtime-fixture.js |  92.50 |    75.00 |  100.00 |',
  ].join('\n'));

  assert.deepEqual(
    rows.get('evals/session-control/lib/upgrade-attestation.js'),
    [91.25],
  );
  assert.deepEqual(
    rows.get('tests/structure/fixtures/install-claude-runtime-fixture.js'),
    [92.5],
  );
});

test('keeps same-named coverage rows separated by their complete paths', () => {
  const rows = parseCoverageRows([
    '# evals                             |        |          |         |',
    '#  session-control                  |        |          |         |',
    '#   assertions                     |        |          |         |',
    '#    upgrade-attestation.js         |  80.00 |    70.00 |  100.00 |',
    '#   lib                            |        |          |         |',
    '#    upgrade-attestation.js         |  95.00 |    90.00 |  100.00 |',
  ].join('\n'));

  assert.deepEqual(
    rows.get('evals/session-control/assertions/upgrade-attestation.js'),
    [80],
  );
  assert.deepEqual(
    rows.get('evals/session-control/lib/upgrade-attestation.js'),
    [95],
  );
});

test('normalizes Windows coverage paths to repository separators', () => {
  const rows = parseCoverageRows([
    '# evals\\session-control\\lib\\safe-file-read.js |  90.43 |    84.00 |  100.00 |',
    'ℹ evals\\session-control\\lib\\upgrade-process.js |  90.80 |    88.00 |  100.00 |',
  ].join('\n'));

  assert.deepEqual(
    rows.get('evals/session-control/lib/safe-file-read.js'),
    [90.43],
  );
  assert.deepEqual(
    rows.get('evals/session-control/lib/upgrade-process.js'),
    [90.8],
  );
});

test('keeps mixed-separator duplicate rows fail closed after normalization', () => {
  const rows = parseCoverageRows([
    '# evals\\session-control\\lib\\safe-file-read.js |  90.43 |    84.00 |  100.00 |',
    '# evals/session-control/lib/safe-file-read.js  |  91.25 |    85.00 |  100.00 |',
  ].join('\n'));

  assert.deepEqual(
    rows.get('evals/session-control/lib/safe-file-read.js'),
    [90.43, 91.25],
  );
  assert.equal(
    rows.has('evals\\session-control\\lib\\safe-file-read.js'),
    false,
  );
});
