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
const localOnlyProfile = readJson('tests/profiles/promptfoo-local-only.v1.json');
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
  // Shard 7 is solo for the same reason shard 8 is, and it got there the same way.
  // `stop-enforcer-self-review-routing` carried a 1500000 ms cap against a measured
  // 1487825 ms (run 33433936017, green on main) — 99.2% of its own ceiling, which is
  // "budget AT the measurement", the error the shard-8 note below ends by naming. The
  // next run over the same content (33437827832) was killed at 1500142 ms. Its
  // neighbour `review-worker-evidence-lease` (measured 137147 ms) moved to shard 8,
  // which AT THAT TIME held two suites measuring ~292 s inside an 1800000 ms envelope —
  // read the shard-8 note below for its current membership rather than this clause, which
  // is history and said "now" for a round after a third suite landed there, and the cap
  // rose to 1700000 — about 14% over the last completing measurement, with ~100 s of
  // profile budget left so a slow run still surfaces as a suite TIMED_OUT rather than
  // as a profile abort that truncates the tail silently.
  //
  // 14% is thin against the 29% run-to-run spread this repo records for THIS suite,
  // and 1800000 is the hard envelope, so the raise cannot be larger without moving
  // `timeout-minutes` and every profile's `profileTimeoutMs` together. The durable
  // fix is the one shard 8 got: find why this suite needs 25 minutes on Windows.
  // Until then, expect this cap to bind again.
  'windows-shard-7',
  // Shard 8 now carries THREE suites — `session-trail-lineage`, `review-worker-evidence-lease`
  // and `plan-payload-path-transport`, one paragraph each below — and it was created for one.
  // NAME them rather than only counting: this line read "two suites" while the paragraph below
  // already described the third and the manifest already listed its id, and CLAUDE.md
  // designates this note as the authoritative carrier, so the numeral was the one thing a
  // reader could not check against anything. A member added here is added to that list too.
  // Measured on run 32998414210, `session-trail-lineage`
  // took 893084 ms of shard 3's 1800000 ms envelope; the eight suites there summed to
  // 1800072 ms and `windows-profile-lifecycle-contract` was granted 139971 ms of its
  // own 420000 ms cap and aborted. No other shard had 893 s of headroom either — the
  // measured job durations that run were 1630, 1187, 1886, 1779, 1008, 1011 and 1516
  // seconds — so the suite needed a shard of its own, not a different neighbour.
  //
  // Every one of those numbers described a suite whose Windows wall clock was almost
  // entirely a stalled subprocess, and they are kept only so the sizing lesson is not
  // relearned. 893084 ms (run 32998414210, completed) and >900138 ms (33018717088,
  // killed at 229 of 288) both measured trail.mjs's win32 process probe timing out
  // 115 times at 8000 ms — about 920 s of the 997 s. Once the probe was fixed, run
  // 33054489866 reported PASSED session-trail-lineage (154673 ms), 280 PASS / 0 FAIL /
  // 4 SKIP. The cap is 600000: 3.9x the real measurement, generous against the
  // run-to-run spread this repo records elsewhere, and deliberately BELOW the ~650 s a
  // reintroduced stall would cost, so that regression trips the cap instead of merely
  // making CI slow. The 1500000 it briefly carried was ten times the measurement and
  // would have hidden exactly that. Budget against the measurement with headroom —
  // never at it, which is what 900000 did, and never so far above it that the cap
  // stops being a tripwire.
  //
  // The second suite arrived later: `review-worker-evidence-lease` was moved off
  // shard 7 (see the note above) because this shard had the headroom and that one had
  // none. 154673 + 137147 ms of measured work against an 1800000 ms envelope.
  //
  // The THIRD suite is `plan-payload-path-transport`, and it is the same error a third
  // time: 848420 ms measured against a 900000 ms cap on run 34069644202 — 94.3%, which
  // is "budget AT the measurement" once more. Run 34110308541 was killed at 900152 ms,
  // and because shard 4's four suites had summed to 1737578 ms of its 1800000 ms
  // envelope (96.5%), the kill starved its neighbour too: `tdd-state-junction-safety`
  // was granted 95474 ms of its own 180000 ms cap and aborted. Two red checks, one
  // cause. Neither number could be raised in place — the shard had 62 s left — so the
  // suite moved here. Re-derive the remainder from the two measurements this note already
  // carries rather than trusting a figure: 154673 + 137147 = 291820 ms of resident work
  // against the 1800000 ms envelope leaves 1508180 ms, about 1508 s. The clause here read
  // 1427 s with no term accounting for the 81 s difference, which is the base-does-not-add-up
  // defect this repository records for its own sizing notes. The cap rose
  // to 1200000: about 41% over the last completing measurement, which covers the 29%
  // run-to-run spread this repo records elsewhere while staying far below the 10x that
  // stopped shard 8's own cap being a tripwire. It runs LAST on purpose, so its own cap
  // binds before the profile envelope and a slow run surfaces as a suite TIMED_OUT
  // rather than as an abort that truncates the tail silently.
  'windows-shard-8',
  // Shard 9 is solo, and it exists because TWO suites needed shard 8's headroom in the
  // same release and only one of them fits. `post-review-self-review-handoff` reported
  // TIMED_OUT at 720126 ms against its 720000 ms cap on shard 5 (run 33804565979, job
  // 100811827008), after roughly 200 lines of new cases. The SHARD was not what bound
  // — that job finished in 21m5s inside the 1800000 ms envelope — so the per-suite cap
  // had to rise, and raising it in place would have left shard 5's worst case at about
  // 27 of its 30 minutes.
  //
  // It cannot join shard 8: 292 s of resident work plus 848 s of measured
  // `plan-payload-path-transport` plus this suite's own 720 s lower bound is about
  // 1860 s against an 1800000 ms envelope, which is the abort-truncates-the-tail
  // failure both notes above are written about. The arithmetic, not a preference,
  // is what put it on a shard of its own.
  //
  // The cap shipped at 1080000, stated openly as NOT a measurement: the only figure
  // that existed was the 720126 ms at which the suite had been killed, a lower bound,
  // and 1080000 was 50% above it so the first green run could report a real number.
  //
  // It did, and it landed 1.5% under: run 34135206712 reported
  // `PASSED post-review-self-review-handoff (1064039ms)` against that 1080000 ms cap,
  // with the job itself finishing in 19m21s. That is "budget AT the measurement" for
  // the fourth time in these notes — green by sixteen seconds, against a run-to-run
  // spread this repo records elsewhere as 29%. The next run was a coin flip. The
  // 50%-over placeholder was reasoned from a lower bound that turned out to sit far
  // below the truth, which is the standing hazard of sizing against a kill rather
  // than against a completion.
  //
  // The cap is 1500000 now: about 41% over the measured 1064039 ms, the same margin
  // shard 8 took for `plan-payload-path-transport` and for the same stated reason —
  // it covers the recorded spread while staying far below the 10x that stopped an
  // earlier cap being a tripwire. The shard is solo, so the suite receives the whole
  // 1800000 ms envelope and its own cap binds first, which is what makes a slow run
  // surface as a suite TIMED_OUT rather than as an abort that truncates the tail.
  'windows-shard-9',
];
const expectedCommandCount = 43;
const expectedCommandDigest = '759e33875689db60325a145b8357f592c9d2f0fe2418883b651d2673a4eea2df';

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
    // A suite never receives its configured `timeoutMs`: `tests/run-profile.js`
    // grants `Math.min(suite.timeoutMs, remaining)`, where `remaining` is the
    // shard envelope minus everything already spent. A cap at or above that
    // envelope can therefore never bind, and an overrun then surfaces as a
    // PROFILE abort that truncates the tail of whichever suite ran last —
    // silently — instead of as the visible suite `TIMED_OUT` the cap exists to
    // produce. The note at the top of this file states that rule; until this
    // assertion nothing enforced it.
    for (const suite of profile.suites) {
      assert.ok(
        suite.timeoutMs < profile.profileTimeoutMs,
        `${profileId}/${suite.id}: cap ${suite.timeoutMs} cannot bind before the ${profile.profileTimeoutMs} envelope`,
      );
    }
  }
});

// The shard REBALANCES this repository records in prose are asserted by nothing on their own:
// expectedProfiles already lists every shard, so moving a suite between two of them turns no
// check red. Each entry below is a rebalance that was made for a measured reason, so putting it
// back has to be a deliberate edit here rather than a silent one in the manifest.
const expectedShardHomes = {
  'plan-payload-path-transport': 'windows-shard-8',
  'stop-enforcer-self-review-routing': 'windows-shard-7',
  'session-trail-lineage': 'windows-shard-8',
};

test('measured shard rebalances stay where they were moved', () => {
  const homes = new Map();
  for (const [profileId, profile] of Object.entries(manifest.profiles)) {
    for (const suite of profile.suites) {
      assert.equal(homes.has(suite.id), false, `${suite.id} is registered on more than one shard`);
      homes.set(suite.id, profileId);
    }
  }
  for (const [suiteId, expectedProfile] of Object.entries(expectedShardHomes)) {
    assert.equal(homes.get(suiteId), expectedProfile, `${suiteId} shard home`);
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
  const ciStructureTests = new Set(localOnlyProfile.ciStructureTests || []);
  for (const entry of nativeStructureInventory.excluded) {
    assert.equal(typeof entry.reason, 'string', entry.path);
    assert.ok(entry.reason.length >= 20, entry.path);
    assert.equal(paths.includes(entry.path), false, entry.path);
    // The load-bearing half of an exclusion that keeps its coverage elsewhere. A
    // reason may only CLAIM `ciStructureTests` membership if the suite is really
    // in that array — otherwise the entry reads as "still covered weekly" while
    // the suite runs on no Windows host at all, which is a silent coverage drop
    // wearing the words of a deliberate scope decision. Keyed on the claim, not
    // on every entry: an exclusion is free to say the suite is unsupported there.
    if (/ciStructureTests/.test(entry.reason)) {
      assert.ok(ciStructureTests.has(path.basename(entry.path)),
        `${entry.path} claims ciStructureTests membership but is not in that array`);
    }
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

// The two operator-facing suite documents restate the profile inventory in prose and in a
// table, and both were HAND-HELD: `tests/SUITE-OVERVIEW.md` says in its own §7 that this
// file pins "exactly these nine keys and the 43-entry total", which is a claim about a
// check that did not exist — nothing compared either document to the manifest, so a shard
// added, renamed or rebalanced left both of them asserting a layout the JSON no longer has.
// Everything here is DERIVED from `manifest.profiles`; no count and no member list is
// written down twice. Member comparison is order-insensitive by design: the JSON's order
// decides which suite runs last inside a shard and the prose table does not claim to
// reproduce it, so requiring the order would fail on a rebalance that changed nothing a
// reader of these documents depends on.
const NUMBER_WORDS = [
  'zero', 'one', 'two', 'three', 'four', 'five', 'six',
  'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve',
];

// The SUITE-SIZE figures, which the profile arm below does not touch and nothing else
// owned. §1 and §2 of SUITE-OVERVIEW restate 150 = 143 + 7, and 143 + 5 = 148 executed,
// across five hand-maintained statements in two sections — while
// `tests/profiles/promptfoo-local-only.v1.json` already owns all three inputs and
// `run-all.sh` refuses to run at all when that manifest and the directory disagree. So a
// suite added to `ciStructureTests` left both sections contradicting the manifest with
// every other check in this file green, which is the same drift the profile arm was
// extended to catch one table row up. Derived here rather than restated, and matched over
// WHITESPACE-FLATTENED SECTION SLICES for the two reasons the §7 needles give: these rows
// are ordinary wrapped markdown, so a break can fall between any two words, and slicing
// first is what keeps the needle about the row instead of about the file.
test('tests/SUITE-OVERVIEW.md restates the structure-suite totals the local-only manifest owns', () => {
  const suiteOverview = fs.readFileSync(path.join(root, 'tests', 'SUITE-OVERVIEW.md'), 'utf8');
  const ciSuites = localOnlyProfile.ciStructureTests.length;
  const localSuites = localOnlyProfile.localStructureTests.length;
  const offlineSuites = localOnlyProfile.ciOfflineSuites.length;
  const allSuites = ciSuites + localSuites;
  const executed = ciSuites + offlineSuites;
  const section = (heading) => {
    const chunk = suiteOverview.split(/^## /m).find((c) => c.startsWith(heading));
    assert.ok(chunk, `tests/SUITE-OVERVIEW.md has no "## ${heading}" section`);
    return chunk;
  };
  const sectionFlat = (heading) => section(heading).replace(/\s+/g, ' ');

  const totalsFlat = sectionFlat('1. Totals');
  assert.ok(
    totalsFlat.includes(`**${allSuites}** — ${ciSuites} CI-blocking + ${localSuites} Promptfoo local-only`),
    `tests/SUITE-OVERVIEW.md §1 does not split ${allSuites} into ${ciSuites} CI-blocking + ${localSuites} local-only`,
  );
  // The reconciliation row states the same three numbers a second way, and its arithmetic
  // is the part a bare count cannot check: the gap it names must be the local-only set.
  // The separator below is a literal U+2212 MINUS SIGN and NOT a hyphen-minus — the one
  // substitution that would make this needle match nothing while reading identically in a
  // diff. Do NOT claim it is written as an escape and that this source stays ASCII: an
  // earlier wording did, and both halves were false — there is no `−` anywhere in
  // this file, and the em dashes in these comments and in the §1 needle above are already
  // non-ASCII. A comment that promises a protection the source does not carry is worse
  // than no comment, because the next maintainer edits the needle trusting it.
  assert.ok(
    totalsFlat.includes(
      `**${ciSuites} structure suites + ${offlineSuites} offline evals = ${executed} executed**`,
    ),
    `tests/SUITE-OVERVIEW.md §1 does not reconcile ${ciSuites} + ${offlineSuites} to ${executed} executed`,
  );
  assert.ok(
    totalsFlat.includes(`the ${localSuites} Promptfoo local-only suites`)
      && totalsFlat.includes(`the whole ${allSuites} − ${ciSuites} gap`),
    `tests/SUITE-OVERVIEW.md §1 does not name the ${allSuites} − ${ciSuites} gap as the ${localSuites} local-only suites`,
  );
  // ROW-ANCHORED and compared by EQUALITY, for the reason the profiles row below states in
  // full. A bare `| **N** |` needle is satisfied by ANY §1 row whose count cell reads N,
  // and §1 carries a Live-E2E row directly beneath the offline one: raising
  // `ciOfflineSuites` from 5 to 7 while updating only the reconciliation prose would have
  // been satisfied by that neighbour, with the Offline-eval row still stating 5 — the exact
  // drift this assertion exists to catch, passing for the wrong row.
  const offlineRow = section('1. Totals')
    .split('\n')
    .find((line) => line.startsWith('| Offline eval suites'));
  assert.ok(offlineRow, 'tests/SUITE-OVERVIEW.md §1 has no Offline eval suites row');
  assert.equal(
    offlineRow.split('|').map((cell) => cell.trim())[2],
    `**${offlineSuites}**`,
    `tests/SUITE-OVERVIEW.md §1 restates an offline-eval count the manifest does not own (${offlineRow})`,
  );

  const modesFlat = sectionFlat('2. Run modes');
  assert.ok(
    modesFlat.includes(`all ${allSuites} structure suites + ${offlineSuites} offline evals`),
    `tests/SUITE-OVERVIEW.md §2 does not state ${allSuites} structure suites + ${offlineSuites} offline evals`,
  );
  assert.ok(
    modesFlat.includes(`${ciSuites} CI structure suites (${localSuites} Promptfoo ones skipped as \`LOCAL\`)`),
    `tests/SUITE-OVERVIEW.md §2 does not state the --ci selection as ${ciSuites} with ${localSuites} skipped`,
  );
});

test('both suite documents restate the profile inventory the manifest owns', () => {
  const suiteOverview = fs.readFileSync(path.join(root, 'tests', 'SUITE-OVERVIEW.md'), 'utf8');
  const profileIds = Object.keys(manifest.profiles);
  const profileCount = profileIds.length;
  const entryTotal = Object.values(manifest.profiles).reduce(
    (sum, profile) => sum + profile.suites.length,
    0,
  );
  const countWord = NUMBER_WORDS[profileCount];
  assert.ok(countWord, `no spelled form for a ${profileCount}-profile manifest`);

  // README: the per-profile invocation block and the spelled count.
  for (const id of profileIds) {
    assert.ok(
      testsReadme.includes(`node tests/run-profile.js ${id}`),
      `tests/README.md does not show how to run ${id}`,
    );
  }
  assert.ok(
    testsReadme.includes(`into ${countWord} bounded profiles`),
    `tests/README.md does not spell the ${profileCount}-profile count`,
  );
  assert.ok(
    testsReadme.includes(`all ${countWord} profiles`)
      && testsReadme.includes(`exactly those ${countWord}`),
    `tests/README.md does not spell the ${profileCount}-profile count in the blocking-CI paragraph`,
  );

  // SUITE-OVERVIEW: the §7 prose totals and the per-shard table.
  //
  // The prose needles run over a WHITESPACE-FLATTENED copy. Both of these sentences are
  // ordinary wrapped markdown, so a break can fall between any two of their words; an earlier
  // spelling tolerated a newline at exactly ONE hardcoded position, which meant a re-wrap that
  // moved the break one word either way failed the check for a document that still said the
  // right thing. Flattening is what makes the needle about the SENTENCE rather than about the
  // column the editor happened to wrap at.
  // SCOPED to §7, and derived BEFORE the prose needles rather than after them. Both
  // needles ran over the whole flattened document, so they were satisfied by the
  // sentences occurring anywhere at all — including in a §7 that had been moved,
  // renamed or emptied — which is the same presence-in-the-file-rather-than-in-the-cell
  // weakness the table rows below already avoid by slicing first.
  const overviewSection = suiteOverview
    .split(/^## /m)
    .find((chunk) => chunk.startsWith('7. Windows contract profiles'));
  assert.ok(overviewSection, 'tests/SUITE-OVERVIEW.md has no §7 Windows contract profiles section');
  const overviewFlat = overviewSection.replace(/\s+/g, ' ');
  assert.ok(
    overviewFlat.includes(`${profileCount} bounded profiles, ${entryTotal} suite entries`),
    `tests/SUITE-OVERVIEW.md §7 does not state ${profileCount} profiles / ${entryTotal} entries`,
  );
  assert.ok(
    overviewFlat.includes(`exactly these ${countWord} keys and the ${entryTotal}-entry total`),
    `tests/SUITE-OVERVIEW.md §7 does not name this file as the pin for ${countWord} keys / ${entryTotal} entries`,
  );
  // The THIRD restatement, which sat outside both needles: §1's totals table carries the
  // same figures in its own words, so a tenth shard left §1 contradicting §7 with every
  // assertion green. It is matched as a row rather than as flattened prose, because that
  // is the shape whose drift the table below cannot see either.
  //
  // SCOPED to §1 and compared by EQUALITY, and both halves of that are load-bearing. The
  // row lookup ran over the WHOLE document, so a row with this lead-in anywhere at all
  // satisfied it — including one left behind in a §1 that had been moved or emptied,
  // which is the same weakness the §7 slice above was added to remove. And the figures
  // were tested as SUBSTRINGS, so `143 suite entries` satisfied a needle written for 43
  // and `**19**` satisfied one written for 9: the pin was strictly weaker than the
  // drift it exists to catch. The whole cell is built from the manifest and compared
  // whole, which also picks up the row's THIRD restatement, the shard RANGE, that
  // neither earlier needle asserted at all — a tenth shard has to move the `…`-9`` end
  // of it, and until now nothing said so.
  const overviewTotalsSection = suiteOverview
    .split(/^## /m)
    .find((chunk) => chunk.startsWith('1. Totals'));
  assert.ok(overviewTotalsSection, 'tests/SUITE-OVERVIEW.md has no §1 Totals section');
  const overviewTotalsRow = overviewTotalsSection
    .split('\n')
    .find((line) => line.startsWith('| Windows contract profiles |'));
  assert.ok(overviewTotalsRow, 'tests/SUITE-OVERVIEW.md §1 has no Windows contract profiles row');
  const overviewTotalsCell = overviewTotalsRow.split('|').map((cell) => cell.trim())[2];
  const expectedTotalsCell =
    `**${profileCount}** (\`windows-shard-1\`…\`-${profileCount}\`, ${entryTotal} suite entries)`;
  assert.equal(
    overviewTotalsCell,
    expectedTotalsCell,
    `tests/SUITE-OVERVIEW.md §1 restates a profile/range/entry total the manifest does not own (${overviewTotalsRow})`,
  );
  for (const [id, profile] of Object.entries(manifest.profiles)) {
    const row = suiteOverview
      .split('\n')
      .find((line) => line.startsWith(`| \`${id}\` |`));
    assert.ok(row, `tests/SUITE-OVERVIEW.md §7 has no table row for ${id}`);
    const cells = row.split('|').map((cell) => cell.trim());
    assert.equal(
      cells[2],
      String(profile.suites.length),
      `${id}: documented entry count disagrees with the manifest`,
    );
    assert.deepEqual(
      cells[3].split(',').map((name) => name.trim()).sort(),
      profile.suites.map((suite) => suite.id).sort(),
      `${id}: documented members disagree with the manifest`,
    );
  }

  // BOTH DIRECTIONS. The loops above walk the manifest and ask whether each entry is
  // documented, which is only half of the drift this arm is named for: a shard RENAMED or
  // REMOVED leaves an orphan run line and an orphan table row that no manifest-driven walk
  // can see, and the count assertions do not catch it either once `profileCount` and
  // `entryTotal` are restored. `expectedProfiles` above bounds the exposure to a rename the
  // author updated deliberately; it does not close it. So the documented id SETS are derived
  // back out of both files and compared for equality, which fails on an extra member as
  // loudly as on a missing one.
  const wanted = [...profileIds].sort();
  // A leading `-` is excluded so the runner's own flag spellings (`--validate`) are not
  // read as profile ids; only a real id can start with an alphanumeric.
  const readmeDocumented = [
    ...testsReadme.matchAll(/node tests\/run-profile\.js ([A-Za-z0-9][A-Za-z0-9._-]*)/g),
  ].map((m) => m[1]);
  assert.deepEqual(
    [...new Set(readmeDocumented)].sort(),
    wanted,
    'tests/README.md documents a profile set the manifest does not own',
  );
  // SCOPED to §7 rather than filtered by id shape: this document carries many other
  // backtick-led tables, and a shape filter would quietly exempt exactly the orphan row
  // whose id no longer looks like the others. The slice is the one derived above the
  // prose needles, so both halves of this check read the same section.
  const overviewDocumented = overviewSection
    .split('\n')
    .map((line) => line.match(/^\| `([A-Za-z0-9][A-Za-z0-9._-]*)` \|/))
    .filter(Boolean)
    .map((m) => m[1]);
  assert.deepEqual(
    [...new Set(overviewDocumented)].sort(),
    wanted,
    'tests/SUITE-OVERVIEW.md §7 documents a profile set the manifest does not own',
  );
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
