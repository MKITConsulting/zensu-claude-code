#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { parseCoverageRows } = require('./coverage-report.js');

const root = path.resolve(__dirname, '..', '..', '..');
const minimumLineCoverage = 90;
const ciMode = process.argv.slice(2).includes('--ci');
const allTestFiles = [
  'evals/session-control/tests/coverage-report.test.js',
  'evals/session-control/tests/safe-file-read.test.js',
  'evals/session-control/tests/upgrade-results.test.js',
  'evals/session-control/tests/upgrade-credentials.test.js',
  'evals/session-control/tests/upgrade-environment.test.js',
  'evals/session-control/tests/upgrade-independent-verifier.test.js',
  'evals/session-control/tests/upgrade-owned-directory.test.js',
  'evals/session-control/tests/upgrade-hook-contract.test.js',
  'evals/session-control/tests/upgrade-process.test.js',
  'evals/session-control/tests/upgrade-anthropic-mock.test.js',
  'evals/session-control/tests/upgrade-linux-sandbox.test.js',
  'evals/session-control/tests/runtime-fixture-installer.test.js',
  'evals/session-control/tests/upgrade-provider-selftest.js',
];
const testFiles = ciMode
  ? allTestFiles.filter(
    (file) => file !== 'evals/session-control/tests/upgrade-provider-selftest.js',
  )
  : allTestFiles;
const upgradeProductionAllowlist = [
  'evals/session-control/lib/safe-file-read.js',
  'evals/session-control/lib/upgrade-attestation.js',
  'evals/session-control/lib/upgrade-credentials.js',
  'evals/session-control/lib/upgrade-environment.js',
  'evals/session-control/lib/upgrade-independent-verifier.js',
  'evals/session-control/lib/upgrade-owned-directory.js',
  'evals/session-control/lib/upgrade-hook-contract.js',
  'evals/session-control/lib/upgrade-process.js',
  'evals/session-control/lib/upgrade-anthropic-mock.js',
  'evals/session-control/lib/upgrade-linux-sandbox.js',
  'evals/session-control/lib/upgrade-provider.js',
  'evals/session-control/lib/verify-upgrade-results.js',
  'tests/structure/fixtures/install-claude-runtime-fixture.js',
];
const coveredFiles = [...upgradeProductionAllowlist];
const enforcedFiles = process.platform === 'win32' || ciMode
  ? coveredFiles.filter(
    (file) => file !== 'evals/session-control/lib/upgrade-provider.js',
  )
  : coveredFiles;
const coverageIncludeSupported = process.allowedNodeEnvironmentFlags.has('--test-coverage-include');
const coverageIncludeArgs = coverageIncludeSupported
  ? coveredFiles.map((file) => `--test-coverage-include=${file}`)
  : [];

const configurationFailures = [];
for (const [label, entries] of [
  ['test', testFiles],
  ['covered', coveredFiles],
]) {
  const duplicates = entries.filter((entry, index) => entries.indexOf(entry) !== index);
  if (duplicates.length > 0) {
    configurationFailures.push(
      `${label} file list contains duplicates: ${[...new Set(duplicates)].join(', ')}`,
    );
  }
}
const libraryDirectory = path.join(root, 'evals', 'session-control', 'lib');
const discoveredProductionFiles = fs.readdirSync(libraryDirectory)
  .filter((name) => name.endsWith('.js'))
  .filter((name) => name === 'safe-file-read.js' || name.startsWith('upgrade-'))
  .map((name) => `evals/session-control/lib/${name}`)
  .concat([
    'evals/session-control/lib/verify-upgrade-results.js',
    'tests/structure/fixtures/install-claude-runtime-fixture.js',
  ])
  .sort();
const expectedProductionFiles = [...upgradeProductionAllowlist].sort();
if (JSON.stringify(discoveredProductionFiles) !== JSON.stringify(expectedProductionFiles)) {
  configurationFailures.push(
    'upgrade production allowlist is incomplete or contains a non-production entry',
  );
}
for (const file of [...allTestFiles, ...upgradeProductionAllowlist]) {
  if (!fs.existsSync(path.join(root, file))) {
    configurationFailures.push(`${file}: coverage input does not exist`);
  }
}
if (configurationFailures.length > 0) {
  process.stderr.write(
    `Session Control coverage configuration failed:\n${configurationFailures
      .map((failure) => `- ${failure}`)
      .join('\n')}\n`,
  );
  process.exitCode = 1;
  return;
}

const result = spawnSync(
  process.execPath,
  [
    '--experimental-test-coverage',
    ...coverageIncludeArgs,
    '--test',
    ...testFiles,
  ],
  {
    cwd: root,
    encoding: 'utf8',
    env: process.env,
    maxBuffer: 64 * 1024 * 1024,
  },
);

if (result.stdout) process.stdout.write(result.stdout);
if (result.stderr) process.stderr.write(result.stderr);

if (result.error) {
  process.stderr.write(
    `Session Control coverage runner failed to start: ${result.error.message}\n`,
  );
  process.exitCode = 1;
  return;
}
if (result.signal || result.status !== 0) {
  process.stderr.write(
    `Session Control coverage tests failed: status=${String(result.status)} signal=${String(result.signal)}\n`,
  );
  process.exitCode = 1;
  return;
}

const output = result.stdout.replace(/\u001B\[[0-9;]*m/g, '');
const reportStart = output.lastIndexOf('start of coverage report');
const reportEnd = output.indexOf('end of coverage report', reportStart);
if (reportStart < 0 || reportEnd < reportStart) {
  process.stderr.write('Session Control coverage runner did not emit one complete final report\n');
  process.exitCode = 1;
  return;
}
const report = output.slice(reportStart, reportEnd);
const coverageRows = parseCoverageRows(report);
const failures = [];
for (const file of enforcedFiles) {
  const matches = coverageRows.get(file) || [];
  if (matches.length !== 1) {
    failures.push(`${file}: expected exactly one coverage row, found ${matches.length}`);
    continue;
  }
  const lineCoverage = matches[0];
  if (!Number.isFinite(lineCoverage) || lineCoverage < minimumLineCoverage) {
    failures.push(
      `${file}: ${String(lineCoverage)}% lines is below ${minimumLineCoverage}%`,
    );
  }
}

if (failures.length > 0) {
  process.stderr.write(
    `Session Control per-file coverage gate failed:\n${failures
      .map((failure) => `- ${failure}`)
      .join('\n')}\n`,
  );
  process.exitCode = 1;
  return;
}

process.stdout.write(
  `Session Control per-file coverage: PASS (${enforcedFiles.length}/${enforcedFiles.length} files >= ${minimumLineCoverage}% lines)\n`,
);
if (process.platform === 'win32') {
  process.stdout.write(
    'Session Control provider coverage is enforced on supported POSIX hosts; Windows verified the explicit no-spawn boundary.\n',
  );
}
