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
const nativeStructureInventory = readJson('tests/profiles/windows-native-structure.v1.json');
const workflow = YAML.parse(
  fs.readFileSync(path.join(root, '.github', 'workflows', 'ci.yml'), 'utf8'),
);
const safetyWorkflow = YAML.parse(
  fs.readFileSync(path.join(root, '.github', 'workflows', 'windows-safety.yml'), 'utf8'),
);
const testsReadme = fs.readFileSync(path.join(root, 'tests', 'README.md'), 'utf8');
const expectedProfiles = [
  'windows-shard-1',
  'windows-shard-2',
  'windows-shard-3',
  'windows-shard-4',
  'windows-shard-5',
  'windows-shard-6',
  'windows-shard-7',
];
const expectedCommandCount = 40;
const expectedCommandDigest = 'fbd52a9ecb349600f6135670a8cc1bcd21396ea88cb60f6fd701616e9acc2791';

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

test('manifest and audited command catalog expose one exact bounded profile inventory', () => {
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

test('every structure test with a native Windows marker is audited and covered or excluded', () => {
  assert.equal(nativeStructureInventory.schemaVersion, 1);
  assert.ok(Array.isArray(nativeStructureInventory.markers));
  assert.ok(nativeStructureInventory.markers.length > 0);
  assert.ok(Array.isArray(nativeStructureInventory.required));
  assert.ok(Array.isArray(nativeStructureInventory.excluded));

  const candidates = fs.readdirSync(path.join(root, 'tests', 'structure'))
    .filter((name) => /^test-.*\.sh$/.test(name))
    .map((name) => `tests/structure/${name}`)
    .filter((relative) => {
      const source = fs.readFileSync(path.join(root, relative), 'utf8');
      return nativeStructureInventory.markers.some((marker) => new RegExp(marker, 'i').test(source));
    })
    .sort();
  const required = [...nativeStructureInventory.required].sort();
  const excluded = nativeStructureInventory.excluded.map((entry) => entry.path).sort();
  assert.deepEqual([...new Set([...required, ...excluded])].sort(), candidates);
  assert.equal(new Set([...required, ...excluded]).size, required.length + excluded.length);

  const paths = allSuites().map((suite) => suite.path);
  for (const relative of required) {
    assert.equal(paths.filter((candidate) => candidate === relative).length, 1, relative);
  }
  for (const entry of nativeStructureInventory.excluded) {
    assert.equal(typeof entry.reason, 'string', entry.path);
    assert.ok(entry.reason.length >= 20, entry.path);
    assert.equal(paths.includes(entry.path), false, entry.path);
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
    'evals/session-control/tests/coverage-report.test.js',
    'evals/session-control/tests/runtime-fixture-installer.test.js',
    'evals/session-control/tests/upgrade-process.test.js',
    'evals/session-control/tests/upgrade-provider-selftest.js',
    'evals/session-control/tests/safe-file-read.test.js',
    'evals/session-control/tests/upgrade-hook-contract.test.js',
    'evals/session-control/tests/upgrade-linux-sandbox.test.js',
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
  // Looked up across the whole manifest on purpose. What this test is about is
  // that these two carry their OWN measured deadlines, which has nothing to do
  // with which shard they land in — and profile membership is now balanced by
  // runtime, so naming one here would break on the next rebalance.
  const suites = allSuites();
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

test('blocking Windows shard matrix has an internal cleanup reserve and provenance-bound artifacts', () => {
  const job = workflow.jobs?.['windows-shards'];
  assert.ok(job);
  assert.equal(job.name, 'Windows contract shard (${{ matrix.profile }})');
  assert.equal(job['runs-on'], 'windows-latest');
  assert.equal(job['timeout-minutes'], 35);
  assert.equal(job['continue-on-error'], undefined);
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
  const record = job.steps.find((step) => step.name === 'Record shard outcome');
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

test('pull-request deterministic suite remains complete and Ubuntu-only', () => {
  const job = workflow.jobs?.test;
  assert.match(job?.name ?? '', /^Deterministic suite \(ubuntu-latest /);
  assert.equal(job?.['runs-on'], 'ubuntu-latest');
  assert.equal(job.steps.some((step) => step.name === 'Windows path and Core lease canary'), false);
  assert.equal(JSON.stringify(job).includes('windows-latest'), false);
  assert.equal(JSON.stringify(job).includes('windows-legacy'), false);

  // "Complete" used to mean "one job runs everything", which is why this asserted
  // `strategy === undefined`. It now means "complete ACROSS the matrix": the suite
  // is sharded, and that the shards are an exact partition of the enforced
  // inventory is proven by tests/structure/test-run-all-sharding.sh S3, not here.
  // What stays this test's job is that the split is derived and Ubuntu-only.
  assert.ok(Array.isArray(job?.strategy?.matrix?.shard));
  assert.ok(job.strategy.matrix.shard.length > 1);
  // A shard that dies must not cancel its siblings, or one failure hides the rest.
  assert.equal(job.strategy['fail-fast'], false);

  const runner = job.steps.find(
    (step) => typeof step.run === 'string' && step.run.includes('tests/run-all.sh'),
  );
  assert.ok(runner, 'the deterministic suite job must still invoke run-all.sh');
  // --ci and nothing but --ci: the Promptfoo modes stay local-only.
  assert.match(runner.run, /bash tests\/run-all\.sh --ci\b/);
  // Both halves of the spec come from the matrix. A literal total beside the
  // shard list is the one edit that drops suites while every shard stays green.
  assert.equal(runner.env?.JOB_INDEX, '${{ strategy.job-index }}');
  assert.equal(runner.env?.JOB_TOTAL, '${{ strategy.job-total }}');
  assert.equal(/--shard=\d+\/\d+/.test(runner.run), false);
});

test('one stable blocking check validates exact same-run shard evidence', () => {
  const job = workflow.jobs?.['windows-shard-summary'];
  assert.ok(job);
  assert.equal(job.name, 'Deterministic suite (windows-latest)');
  assert.deepEqual(job.needs, ['windows-shards']);
  assert.equal(job.if, "${{ always() && !startsWith(github.head_ref, 'release/') }}");
  assert.equal(job['continue-on-error'], undefined);
  assert.equal(job.permissions?.actions, 'read');
  const downloads = job.steps.filter(
    (step) => typeof step.uses === 'string' && step.uses.startsWith('actions/download-artifact@'),
  );
  assert.equal(downloads.length, 1);
  assert.ok(downloads.every(
    (step) => step.uses === 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093',
  ));
  assert.equal(
    downloads[0].with.pattern,
    'windows-profile-*-${{ github.sha }}-${{ github.run_attempt }}',
  );
  assert.equal(downloads[0].with['merge-multiple'], true);
  const summarize = job.steps.find((step) => step.name === 'Validate blocking shard evidence');
  assert.match(summarize.run, /summarize-windows-observation\.js summarize-shards/);
  assert.match(summarize.run, /test "\$ZENSU_SHARD_JOB_RESULT" = success/);
  assert.equal(summarize.env.ZENSU_SHARD_JOB_RESULT, '${{ needs.windows-shards.result }}');
  assert.equal(summarize.env.GITHUB_RUN_ATTEMPT, '${{ github.run_attempt }}');
  const upload = job.steps.find((step) => step.name === 'Upload aggregate shard evidence');
  assert.equal(upload.with.name, 'windows-shards-${{ github.sha }}-${{ github.run_attempt }}');
  assert.equal(upload.with['if-no-files-found'], 'error');
});

test('scheduled Windows safety workflow partitions the exact former monolith read-only', () => {
  assert.equal(safetyWorkflow.name, 'Windows full safety suite');
  assert.deepEqual(Object.keys(safetyWorkflow.on || {}).sort(), ['schedule', 'workflow_dispatch']);
  assert.deepEqual(safetyWorkflow.on?.schedule, [{ cron: '17 3 * * 0' }]);
  assert.equal(Object.hasOwn(safetyWorkflow.on || {}, 'workflow_dispatch'), true);
  assert.deepEqual(safetyWorkflow.permissions, { contents: 'read' });
  assert.equal(safetyWorkflow.defaults?.run?.shell, 'bash');
  assert.deepEqual(safetyWorkflow.concurrency, {
    group: 'windows-full-safety-${{ github.ref }}',
    'cancel-in-progress': false,
  });
  const job = safetyWorkflow.jobs?.['windows-full-safety-shards'];
  assert.ok(job);
  assert.equal(
    job.name,
    'Windows full safety (${{ matrix.kind }} ${{ matrix.shard }}/${{ matrix.total }})',
  );
  assert.equal(job['runs-on'], 'windows-latest');
  assert.equal(job['timeout-minutes'], 240);
  assert.equal(job.strategy?.['fail-fast'], false);
  assert.equal(job.strategy?.['max-parallel'], 15);
  const include = job.strategy?.matrix?.include;
  assert.equal(include.length, 15);
  assert.deepEqual(
    include.filter((entry) => entry.kind === 'canary'),
    [1, 2, 3, 4].map((shard) => ({ kind: 'canary', shard, total: 4 })),
  );
  assert.deepEqual(
    include.filter((entry) => entry.kind === 'structure'),
    [1, 2, 3, 4, 5, 6, 7, 8].map((shard) => ({ kind: 'structure', shard, total: 8 })),
  );
  assert.deepEqual(
    include.filter((entry) => entry.kind === 'offline'),
    [1, 2, 3].map((shard) => ({ kind: 'offline', shard, total: 3 })),
  );
  const run = job.steps.find((step) => step.name === 'Run bounded Windows safety shard');
  assert.equal(
    run?.run,
    'node tests/run-windows-safety-shard.js "${{ matrix.kind }}" "${{ matrix.shard }}" "${{ matrix.total }}"',
  );
  assert.equal(checkoutSteps(job)[0].with?.['persist-credentials'], false);
  assert.equal(JSON.stringify(safetyWorkflow).includes('secrets.'), false);
});

test('the documented cutover keeps Promptfoo local-only', () => {
  assert.match(testsReadme, /blocking Windows contract profiles/);
  assert.match(testsReadme, /scheduled,\s+read-only Windows safety workflow/);
  assert.match(testsReadme, /weekly and manually dispatchable/);
  assert.match(
    testsReadme,
    /complete deterministic non-Promptfoo suite remains blocking on Ubuntu/,
  );
  assert.match(testsReadme, /`Deterministic suite \(windows-latest\)`/);
  assert.match(testsReadme, /Promptfoo suites are local-only/);
  assert.doesNotMatch(testsReadme, /at least 14 days and 10 representative/);
});
