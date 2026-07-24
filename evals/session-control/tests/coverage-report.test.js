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
