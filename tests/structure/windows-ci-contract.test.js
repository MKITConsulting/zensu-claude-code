'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const YAML = require('yaml');

const root = path.resolve(__dirname, '..', '..');
const readJson = (relative) => JSON.parse(fs.readFileSync(path.join(root, relative), 'utf8'));
const manifest = readJson('tests/profiles/windows-ci.v1.json');
const catalog = readJson('tests/profiles/windows-ci-command-catalog.v1.json');
const legacyCanary = readJson('tests/profiles/windows-legacy-canary.v1.json');
const workflow = YAML.parse(
  fs.readFileSync(path.join(root, '.github', 'workflows', 'ci.yml'), 'utf8'),
);
const testsReadme = fs.readFileSync(path.join(root, 'tests', 'README.md'), 'utf8');
const expectedProfiles = [
  'windows-reset-session',
  'windows-leases-routing',
  'windows-native-state',
  'windows-installed-core',
];
const expectedCommandCount = 39;
const expectedCommandDigest = '6ab18c4b7ffcad7b652d8adcdcad1cf053f08ee008f6ee75ebf348f1b6231265';

function allSuites() {
  return Object.values(manifest.profiles).flatMap((profile) => profile.suites);
}

function key(entry) {
  return JSON.stringify([entry.runner, entry.path, entry.args]);
}

function checkoutSteps(job) {
  return (job.steps || []).filter(
    (step) => typeof step.uses === 'string' && step.uses.startsWith('actions/checkout@'),
  );
}

test('manifest and audited command catalog expose one exact four-profile inventory', () => {
  assert.deepEqual(Object.keys(manifest.profiles), expectedProfiles);
  const manifestCommands = allSuites().map(key).sort();
  const catalogCommands = catalog.commands.map(key).sort();
  assert.deepEqual(manifestCommands, catalogCommands);
  assert.equal(catalogCommands.length, expectedCommandCount);
  assert.equal(
    crypto.createHash('sha256').update(JSON.stringify(catalogCommands)).digest('hex'),
    expectedCommandDigest,
  );
  assert.equal(new Set(catalogCommands).size, catalogCommands.length);
  for (const [profileId, profile] of Object.entries(manifest.profiles)) {
    assert.equal(profile.platform, 'win32', profileId);
    assert.equal(profile.profileTimeoutMs, 1800000, profileId);
    assert.ok(profile.suites.length > 0, profileId);
  }
});

test('Windows suites are created inside one kill-on-close Job Object before they run', () => {
  const runner = fs.readFileSync(path.join(root, 'tests', 'run-profile.js'), 'utf8');
  const supervisor = fs.readFileSync(
    path.join(root, 'tests', 'profile-suite-supervisor.js'),
    'utf8',
  );
  const jobHelper = fs.readFileSync(
    path.join(root, 'tests', 'windows-profile-job.ps1'),
    'utf8',
  );
  assert.match(runner, /windows-profile-job\.ps1/);
  assert.match(runner, /revalidateFileBinding[\s\S]*windows job helper/);
  assert.match(supervisor, /process\.platform !== 'win32'/);
  assert.match(supervisor, /WindowsPowerShell[\s\S]*powershell\.exe/);
  assert.match(supervisor, /-ExecutionPolicy[\s\S]*Bypass[\s\S]*-File/);
  assert.match(supervisor, /supervisorPid:\s*process\.pid/);
  assert.match(supervisor, /ownerPid:\s*process\.ppid/);
  for (const boundary of [
    'CreateJobObject',
    'JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE',
    'SetInformationJobObject',
    'PROC_THREAD_ATTRIBUTE_JOB_LIST',
    'PROC_THREAD_ATTRIBUTE_HANDLE_LIST',
    'InitializeProcThreadAttributeList',
    'UpdateProcThreadAttribute',
    'GetHandleInformation',
    'CREATE_UNICODE_ENVIRONMENT',
    'BuildEnvironmentBlock',
    'CREATE_SUSPENDED',
    'EXTENDED_STARTUPINFO_PRESENT',
    'CreateProcessW',
    'ResumeThread',
    'OpenProcess',
    'WaitForMultipleObjects',
    'profile controller exited before the suite root',
    'TerminateJobObject',
    'QueryInformationJobObject',
  ]) {
    assert.match(jobHelper, new RegExp(boundary), boundary);
  }
  assert.ok(
    jobHelper.indexOf('UpdateProcThreadAttribute(job list)')
      < jobHelper.indexOf('Check(\n                CreateProcessW('),
    'the atomic Job Object process attribute must be ready before process creation',
  );
});

test('all current Windows canary boundaries remain represented exactly once', () => {
  const paths = allSuites().map((suite) => suite.path);
  const oneEach = legacyCanary.commands
    .map((command) => command.replace(/^bash /, ''))
    .filter((candidate) => candidate !== 'tests/structure/test-deferred-review-claim.sh');
  for (const expected of oneEach) {
    assert.equal(paths.filter((candidate) => candidate === expected).length, 1, expected);
  }
  assert.equal(
    paths.filter((candidate) => candidate === 'tests/structure/test-deferred-review-claim.sh').length,
    4,
  );
});

test('previously hidden native Windows contracts are explicit and monoliths are forbidden', () => {
  const paths = new Set(allSuites().map((suite) => suite.path));
  for (const required of [
    'tests/structure/test-msys-special-plugin-module-boundaries.sh',
    'tests/structure/test-versioned-plugin-upgrade.sh',
    'tests/structure/test-autopilot-state-machine.sh',
    'tests/structure/test-vcs-review-marker-reconcile.sh',
    'tests/structure/test-claude-promptfoo-wrapper.sh',
    'tests/structure/test-promptfoo-session-upgrade.sh',
    'evals/session-control/tests/coverage-report.test.js',
    'evals/session-control/tests/runtime-fixture-installer.test.js',
    'evals/session-control/tests/upgrade-process.test.js',
    'evals/session-control/tests/upgrade-provider-selftest.js',
    'evals/session-control/tests/safe-file-read.test.js',
    'evals/session-control/tests/upgrade-hook-contract.test.js',
    'evals/session-control/tests/upgrade-linux-sandbox.test.js',
    'evals/reset-review-limit/run-self-check.sh',
  ]) {
    assert.equal(paths.has(required), true, required);
  }
  for (const forbidden of [
    'tests/run-all.sh',
    'evals/config-gate/run-eval.sh',
    'evals/session-control/run-self-check.sh',
    'evals/session-control/tests/enforce-upgrade-coverage.js',
  ]) {
    assert.equal(paths.has(forbidden), false, forbidden);
  }
});

test('slow profile lifecycle coverage has an independent measured deadline', () => {
  const suites = manifest.profiles['windows-installed-core'].suites;
  const metadata = suites.find((suite) => suite.id === 'windows-ci-metadata-contract');
  const lifecycle = suites.find((suite) => suite.id === 'windows-profile-lifecycle-contract');
  assert.deepEqual(metadata, {
    id: 'windows-ci-metadata-contract',
    runner: 'bash',
    path: 'tests/structure/test-windows-ci-contract.sh',
    args: ['metadata'],
    timeoutMs: 180000,
  });
  assert.deepEqual(lifecycle, {
    id: 'windows-profile-lifecycle-contract',
    runner: 'bash',
    path: 'tests/structure/test-windows-ci-contract.sh',
    args: ['lifecycle'],
    timeoutMs: 420000,
  });
  const contractRunner = fs.readFileSync(
    path.join(root, 'tests', 'structure', 'test-windows-ci-contract.sh'),
    'utf8',
  );
  assert.match(contractRunner, /metadata\)[\s\S]*windows-ci-contract\.test\.js/);
  assert.match(contractRunner, /lifecycle\)[\s\S]*profile-runner\.test\.js/);
  assert.match(contractRunner, /all\)[\s\S]*profile-runner\.test\.js/);
});

test('observation matrix has an internal cleanup reserve and provenance-bound artifacts', () => {
  const job = workflow.jobs?.['windows-shard-observation'];
  assert.ok(job);
  assert.equal(job.name, 'Windows shard observation (${{ matrix.profile }})');
  assert.equal(job['runs-on'], 'windows-latest');
  assert.equal(job['timeout-minutes'], 35);
  assert.equal(job['continue-on-error'], true);
  assert.equal(job.strategy?.['fail-fast'], false);
  assert.deepEqual(job.strategy?.matrix?.profile, expectedProfiles);
  assert.equal(job.permissions?.contents, 'read');
  assert.ok(Object.values(manifest.profiles).every(
    (profile) => profile.profileTimeoutMs <= (job['timeout-minutes'] - 5) * 60000,
  ));

  const checkouts = checkoutSteps(job);
  assert.equal(checkouts.length, 1);
  assert.equal(checkouts[0].uses, 'actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5');
  assert.equal(checkouts[0].with?.['fetch-depth'], 0);
  assert.equal(checkouts[0].with?.['persist-credentials'], false);
  const run = job.steps.find((step) => step.name === 'Run Windows contract profile');
  assert.equal(run?.run, 'node tests/run-profile.js "${{ matrix.profile }}"');
  assert.equal(run?.['continue-on-error'], undefined);
  assert.equal(run?.env?.ZENSU_PROFILE_REPORT_DIR, '${{ runner.temp }}/windows-profile-reports');
  assert.equal(run?.env?.ZENSU_PROFILE_SOURCE_SHA, '${{ github.sha }}');
  assert.equal(run?.env?.GITHUB_RUN_ATTEMPT, '${{ github.run_attempt }}');
  const record = job.steps.find((step) => step.name === 'Record observation outcome');
  assert.equal(record?.if, 'always()');
  assert.equal(record?.env?.PROFILE_OUTCOME, '${{ steps.profile.outcome }}');
  const upload = job.steps.find(
    (step) => typeof step.uses === 'string' && step.uses.startsWith('actions/upload-artifact@'),
  );
  assert.equal(upload?.if, 'always()');
  assert.equal(
    upload?.with?.name,
    'windows-profile-${{ matrix.profile }}-${{ github.sha }}-${{ github.run_attempt }}',
  );
  assert.equal(
    upload?.with?.path,
    '${{ runner.temp }}/windows-profile-reports/${{ matrix.profile }}.json',
  );
  assert.equal(upload?.with?.['if-no-files-found'], 'error');
  assert.equal(JSON.stringify(job).includes('secrets.'), false);
});

test('the legacy Windows canary body is byte-semantically pinned and emits its outcome', () => {
  const job = workflow.jobs?.test;
  assert.equal(job?.name, 'Deterministic suite (${{ matrix.os }})');
  assert.deepEqual(job?.strategy?.matrix?.os, ['ubuntu-latest', 'windows-latest']);
  const canary = job.steps.find((step) => step.name === 'Windows path and Core lease canary');
  assert.deepEqual(
    canary.run.split(/\r?\n/).map((line) => line.trim()).filter(Boolean),
    legacyCanary.commands,
  );
  assert.equal(job.steps.some((step) => step.run === 'bash tests/run-all.sh'), true);
  const record = job.steps.find((step) => step.name === 'Record legacy Windows outcome');
  assert.match(record?.if || '', /always\(\).*runner\.os == 'Windows'/);
  assert.equal(record?.env?.ZENSU_LEGACY_OUTCOME, '${{ job.status }}');
  const upload = job.steps.find((step) => step.name === 'Upload legacy Windows outcome');
  assert.equal(upload?.with?.name, 'windows-legacy-${{ github.sha }}-${{ github.run_attempt }}');
  assert.equal(upload?.with?.['if-no-files-found'], 'error');
});

test('one non-blocking summary validates exact same-run shard and legacy evidence', () => {
  const job = workflow.jobs?.['windows-observation-summary'];
  assert.ok(job);
  assert.deepEqual(job.needs, ['test', 'windows-shard-observation']);
  assert.equal(job.if, 'always()');
  assert.equal(job['continue-on-error'], true);
  assert.equal(job.permissions?.actions, 'read');
  const downloads = job.steps.filter(
    (step) => typeof step.uses === 'string' && step.uses.startsWith('actions/download-artifact@'),
  );
  assert.equal(downloads.length, 2);
  assert.ok(downloads.every(
    (step) => step.uses === 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093',
  ));
  assert.equal(
    downloads[0].with.pattern,
    'windows-profile-*-${{ github.sha }}-${{ github.run_attempt }}',
  );
  assert.equal(downloads[0].with['merge-multiple'], true);
  assert.equal(
    downloads[1].with.name,
    'windows-legacy-${{ github.sha }}-${{ github.run_attempt }}',
  );
  const summarize = job.steps.find((step) => step.name === 'Validate same-run parity evidence');
  assert.match(summarize.run, /summarize-windows-observation\.js summarize/);
  assert.equal(summarize.env.GITHUB_RUN_ATTEMPT, '${{ github.run_attempt }}');
  const upload = job.steps.find((step) => step.name === 'Upload aggregate observation evidence');
  assert.equal(upload.with.name, 'windows-observation-${{ github.sha }}-${{ github.run_attempt }}');
  assert.equal(upload.with['if-no-files-found'], 'error');
});

test('the documented cutover gate is machine-auditable and keeps paid Linux gates unchanged', () => {
  assert.match(testsReadme, /at least 14 days and 10 representative/);
  assert.match(testsReadme, /100% successful outcomes from both/);
  assert.match(testsReadme, /no missing suite, timeout, or incomplete timing report/);
  assert.match(testsReadme, /audit-ledger/);
  assert.match(testsReadme, /ten distinct Git revisions/);
  assert.match(testsReadme, /`Deterministic suite \(windows-latest\)`/);
  assert.match(testsReadme, /separate scheduled, read-only Windows safety workflow/);
  assert.match(testsReadme, /Release and Session\s+Control Nightly remain/);
  assert.doesNotMatch(testsReadme, /move the full Windows suite to\s+nightly\/release coverage/);
});
