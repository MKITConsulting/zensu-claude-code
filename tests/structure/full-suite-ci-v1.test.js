'use strict';

const assert = require('node:assert/strict');
const childProcess = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const LIB_DIR = path.join(__dirname, '..', '..', 'hooks', 'lib');
const contract = require(path.join(LIB_DIR, 'ci-contract-v1.js'));
const policy = require(path.join(LIB_DIR, 'full-suite-policy-v1.js'));
const evr = require(path.join(LIB_DIR, 'evidence-run-v1.js'));
const stubLib = require(path.join(__dirname, 'fixtures', 'gh-api-stub.js'));
const { writeGhStub } = stubLib;

const SESSION = `scv1_${'c'.repeat(64)}`;
const REPO = 'acme/app';
const WF = '.github/workflows/ci.yml';
const CLI = path.join(LIB_DIR, 'full-suite-policy-v1.js');
const NOW = Date.parse('2026-09-29T12:00:00.000Z');
const HOUR = 60 * 60 * 1000;
const CLEAN_ENV = Object.fromEntries(Object.entries(process.env).filter(([name]) => !['CI', 'GITHUB_ACTIONS', 'GITLAB_CI', 'TF_BUILD', 'BUILDKITE'].includes(name)));

const WORKFLOW = [
  'name: CI',
  'on:',
  '  pull_request:',
  '    paths-ignore:',
  "      - 'docs/**'",
  '  push:',
  '    branches: [main]',
  'jobs:',
  '  lint:',
  '    runs-on: ubuntu-latest',
  '    steps:',
  '      - run: npm run lint',
  '  test:',
  '    name: test',
  "    if: ${{ !startsWith(github.head_ref, 'release/') }}",
  '    runs-on: ubuntu-latest',
  '    steps:',
  '      - run: npm test',
  '',
].join('\n');

function tempDir(label) {
  return fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), `fsci-${label}-`)));
}

function sh(cwd, command) {
  return childProcess.execSync(command, { cwd, stdio: ['ignore', 'pipe', 'pipe'], encoding: 'utf8' });
}

function project(workflow = WORKFLOW, remote = `https://github.com/${REPO}.git`) {
  const root = tempDir('repo');
  sh(root, 'git init -q && git config user.email t@example.invalid && git config user.name tester && git config commit.gpgsign false');
  fs.mkdirSync(path.join(root, '.github', 'workflows'), { recursive: true });
  if (workflow !== null) fs.writeFileSync(path.join(root, '.github', 'workflows', 'ci.yml'), workflow);
  fs.writeFileSync(path.join(root, 'a.txt'), 'one\n');
  fs.writeFileSync(path.join(root, '.gitignore'), '.zensu/\n');
  sh(root, 'git add -A && git commit -q -m init');
  if (remote) sh(root, `git remote add origin ${remote}`);
  return root;
}

function run(id, created, conclusion = 'success') {
  return { id, conclusion, created_at: new Date(created).toISOString() };
}

function job(name, conclusion, commands = []) {
  return { name, conclusion, steps: [{ name: 'Set up job' }, { name: 'Run actions/checkout@v4' }, ...commands.map((command) => ({ name: `Run ${command}` }))] };
}

function responses(overrides = {}, at = NOW) {
  const base = {
    [`repos/${REPO}`]: { default_branch: 'main', fork: false },
    [`repos/${REPO}/actions/workflows/ci.yml/runs?event=pull_request&status=completed&per_page=20`]: {
      workflow_runs: [run(2, at - 2 * HOUR), run(1, at - 5 * HOUR, 'failure')],
    },
    [`repos/${REPO}/actions/runs/2/jobs?per_page=100`]: { jobs: [job('lint', 'success', ['npm run lint']), job('test', 'success', ['npm test'])] },
    [`repos/${REPO}/actions/runs/1/jobs?per_page=100`]: { jobs: [job('lint', 'success', ['npm run lint']), job('test', 'failure', ['npm test'])] },
    [`repos/${REPO}/branches/main`]: { protection: { required_status_checks: { enforcement_level: 'off', contexts: [] } } },
    [`repos/${REPO}/rules/branches/main`]: [],
  };
  return { ...base, ...overrides };
}

function ghShim(map) {
  const directory = tempDir('gh');
  const fixture = path.join(directory, 'fixture.json');
  const calls = path.join(directory, 'calls.log');
  fs.writeFileSync(fixture, JSON.stringify(map));
  const stub = writeGhStub(directory, fixture, calls);
  return { dir: directory, ghPath: stub.ghPath, env: stub.env, calls: () => (fs.existsSync(calls) ? fs.readFileSync(calls, 'utf8').trim().split('\n').filter(Boolean) : []) };
}

function cacheDirOf(data) {
  return path.join(data, 'ci-contract', 'v1', 'cache');
}

function keyOf(workflow = WF) {
  return crypto.createHash('sha256').update(`${REPO}\n${workflow}`).digest('hex').slice(0, 40);
}

function jobKeyOf(name) {
  return crypto.createHash('sha256').update(name).digest('hex').slice(0, 16);
}

function proofFile(data, blob, workflow = WF, jobName = 'test') {
  return path.join(cacheDirOf(data), `${keyOf(workflow)}.${blob}.${jobKeyOf(jobName)}.json`);
}

function legacyFile(data, workflow = WF) {
  return path.join(cacheDirOf(data), `${keyOf(workflow)}.json`);
}

function workflowFile(tree) {
  return path.join(tree, '.github', 'workflows', 'ci.yml');
}

function blobOf(tree) {
  return crypto.createHash('sha256').update(fs.readFileSync(workflowFile(tree))).digest('hex');
}

function worktreeOf(root, branch, workflow) {
  const tree = path.join(tempDir(`wt-${branch}`), 'tree');
  sh(root, `git worktree add -q ${JSON.stringify(tree)} -b ${branch}`);
  const real = fs.realpathSync(tree);
  fs.writeFileSync(workflowFile(real), workflow);
  sh(real, 'git add -A && git commit -q -m variant');
  return real;
}

function verifyOptions(root, data, gh, extra = {}) {
  return { projectRoot: root, pluginData: data, workflow: 'ci.yml', job: null, localCommand: 'npm test', env: { ...CLEAN_ENV, ...gh.env }, mode: 'refresh', now: NOW, ghPath: gh.ghPath, ...extra };
}

test('the workflow scan reads the pull_request trigger, its filters and the job conditions', () => {
  const scanned = contract.scanWorkflow(WORKFLOW);
  assert.equal(scanned.readable, true);
  assert.equal(scanned.pullRequest, true);
  assert.equal(scanned.pullRequestTarget, false);
  assert.deepEqual(scanned.filters, [{ key: 'paths-ignore', values: ['docs/**'] }]);
  assert.deepEqual(scanned.jobs.map((entry) => [entry.key, entry.condition]), [['lint', null], ['test', "${{ !startsWith(github.head_ref, 'release/') }}"]]);
  assert.deepEqual(contract.conditionsOf(scanned), ['on.pull_request.paths-ignore: docs/**', "job test if: ${{ !startsWith(github.head_ref, 'release/') }}"]);
});

test('the conditions name only the bound job, and every job when no job matches the pattern', () => {
  const scanned = contract.scanWorkflow([
    'on: pull_request',
    'jobs:',
    '  lint:',
    '    if: github.actor != 1',
    '    runs-on: x',
    '  test:',
    '    if: github.event.pull_request.draft == false',
    '    runs-on: x',
    '  windows:',
    '    name: Deterministic suite (windows-latest)',
    '    if: always()',
    '    runs-on: x',
    '',
  ].join('\n'));
  assert.deepEqual(contract.conditionsOf(scanned, 'test (*)'), ['job test if: github.event.pull_request.draft == false']);
  assert.deepEqual(contract.conditionsOf(scanned, 'Deterministic suite (*)'), ['job windows if: always()']);
  assert.equal(contract.conditionsOf(scanned, 'unknown job').length, 3);
  assert.equal(contract.conditionsOf(scanned).length, 3);
});

test('the workflow scan accepts the inline forms and rejects a missing trigger block', () => {
  assert.equal(contract.scanWorkflow('on: [push, pull_request]\njobs: {}\n').pullRequest, true);
  assert.equal(contract.scanWorkflow('"on": pull_request\n').pullRequest, true);
  const flow = contract.scanWorkflow('on: { pull_request: { branches: [main] } }\n');
  assert.equal(flow.pullRequest, true);
  assert.equal(flow.flowTrigger, true);
  const sequence = contract.scanWorkflow('on:\n  - push\n  - pull_request\n');
  assert.equal(sequence.pullRequest, true);
  const target = contract.scanWorkflow('on:\n  pull_request_target:\n    types: [opened]\n');
  assert.equal(target.pullRequest, false);
  assert.equal(target.pullRequestTarget, true);
  assert.equal(contract.scanWorkflow('name: x\njobs: {}\n').readable, false);
  assert.equal(contract.scanWorkflow('# on: pull_request\non: push\n').pullRequest, false);
});

test('the workflow scan folds a block-scalar job name and marks a job that calls a reusable workflow', () => {
  const scanned = contract.scanWorkflow([
    'on: pull_request',
    'jobs:',
    '  build-ubuntu:',
    '    name: >-',
    '      Ubuntu',
    "      ${{ fromJSON(matrix.free-threading) && '(free-threading)' || '' }}",
    '    uses: ./.github/workflows/reusable-ubuntu.yml',
    '  docs:',
    '    name: |',
    '      Docs #1',
    '    runs-on: x',
    '  lint:',
    '    runs-on: x',
    '',
  ].join('\n'));
  assert.deepEqual(scanned.jobs.map((entry) => [entry.key, entry.name, entry.reusable]), [
    ['build-ubuntu', "Ubuntu ${{ fromJSON(matrix.free-threading) && '(free-threading)' || '' }}", true],
    ['docs', 'Docs #1', false],
    ['lint', null, false],
  ]);
});

test('a version runs a job pattern only when a job name template, its matrix suffix or a reusable callee can produce a matching name', () => {
  const scanned = contract.scanWorkflow([
    'on: pull_request',
    'jobs:',
    '  test:',
    '    name: Deterministic suite (ubuntu-latest ${{ strategy.job-index }})',
    '    runs-on: x',
    '  unit:',
    '    runs-on: x',
    '  build-ubuntu:',
    '    name: >-',
    '      Ubuntu',
    "      ${{ fromJSON(matrix.free-threading) && '(free-threading)' || '' }}",
    "      ${{ fromJSON(matrix.bolt) && '(bolt)' || '' }}",
    '    uses: ./.github/workflows/reusable-ubuntu.yml',
    '  build-ios:',
    '    name: >-',
    '      iOS',
    "      ${{ fromJSON(matrix.free-threading) && '(free-threading)' || '' }}",
    '    runs-on: x',
    '  build-san:',
    "    name: Sanitizers${{ '' }}",
    '    uses: ./.github/workflows/reusable-san.yml',
    '  ssl:',
    '    name: Ubuntu SSL tests',
    '    runs-on: x',
    '  integration:',
    '    uses: ./.github/workflows/reusable-integration.yml',
    '  e2e:',
    '    name: End to end',
    '    uses: ./.github/workflows/reusable-e2e.yml',
    '',
  ].join('\n'));
  const runs = (pattern) => contract.versionRuns(scanned, pattern);
  for (const pattern of ['Deterministic suite (*)', 'unit', 'unit (*)', 'unit (ubuntu-latest, 20)', 'Ubuntu / build and test (*)', 'Ubuntu (free-threading) / build and test (*)', 'Ubuntu  (bolt) / build and test (*)', 'iOS', 'iOS (*)', 'Sanitizers / TSan', 'Ubuntu SSL tests (*)', 'integration / build', 'integration (ubuntu) / build', 'End to end / smoke', 'End to end (chrome) / smoke (*)']) {
    assert.equal(runs(pattern), true, pattern);
  }
  for (const pattern of ['lint', 'test', 'Deterministic suite', 'Windows / Build and test (*)', 'Docs / Docs', 'macOS (*)', 'unit tests (*)', 'unit / build', 'unit (ubuntu) / build', 'Deterministic suite (ubuntu-latest 1) / build', '']) {
    assert.equal(runs(pattern), false, pattern);
  }
  const expressionOnly = contract.scanWorkflow('on: pull_request\njobs:\n  job:\n    name: ${{ matrix.full_name }}\n    runs-on: x\n');
  assert.equal(contract.versionRuns(expressionOnly, 'PR - mingw-check'), true);
});

test('the workflow scan decodes quoted names, folds a continued name and reads an inline job body or a jobs block in flow form as any text', () => {
  const scanned = contract.scanWorkflow([
    'on: pull_request',
    'jobs:',
    '  apostrophe:',
    "    name: 'Bob''s tests'",
    '    runs-on: x',
    '  escaped:',
    '    name: "Lint \\"strict\\""',
    '    runs-on: x',
    '  doubled-hash:',
    "    name: 'Bob''s # tests'",
    '    runs-on: x',
    '  escaped-hash:',
    '    name: "Lint \\"a\\" # b"',
    '    runs-on: x',
    '  plain:',
    "    name: Ann's suite # nightly",
    '    runs-on: x',
    '  continued:',
    '    name: Build and',
    '      test',
    '    runs-on: x',
    '  quoted:',
    '    name: "Docs and',
    '      more"',
    '    runs-on: x',
    '  inline: { name: Unit, runs-on: x }',
    '',
  ].join('\n'));
  assert.deepEqual(scanned.jobs.map((entry) => [entry.key, entry.name, entry.inline]), [
    ['apostrophe', "Bob's tests", false],
    ['escaped', 'Lint "strict"', false],
    ['doubled-hash', "Bob's # tests", false],
    ['escaped-hash', 'Lint "a" # b', false],
    ['plain', "Ann's suite", false],
    ['continued', 'Build and test', false],
    ['quoted', 'Docs and more', false],
    ['inline', null, true],
  ]);
  assert.equal(scanned.flowJobs, false);
  for (const pattern of ["Bob's tests", 'Lint "strict"', "Ann's suite (*)", 'Build and test', 'Docs and more', 'Unit']) {
    assert.equal(contract.versionRuns(scanned, pattern), true, pattern);
  }
  const anchored = contract.scanWorkflow('on: pull_request\njobs: &all\n  test: &defaults\n    name: Unit\n    runs-on: x\n  alias: *defaults\n');
  assert.equal(anchored.flowJobs, false);
  assert.deepEqual(anchored.jobs.map((entry) => [entry.key, entry.name, entry.inline]), [['test', 'Unit', false], ['alias', null, true]]);
  assert.equal(contract.versionRuns(contract.scanWorkflow('on: pull_request\njobs: &all\n  test: &defaults\n    name: Unit\n    runs-on: x\n'), 'zzz'), false);
  const flow = contract.scanWorkflow('on: pull_request\njobs: { test: { name: Unit, runs-on: x } }\n');
  assert.equal(flow.flowJobs, true);
  assert.equal(contract.versionRuns(flow, 'Unit'), true);
  assert.ok(contract.conditionsOf(flow, 'Unit').includes('the jobs block is written in flow form, so its jobs were not read'));
  assert.equal(contract.versionRuns(contract.scanWorkflow('on: pull_request\n'), 'Unit'), false);
});

test('the version check honours its limits: a name past maxNameChars reads as any text, a check past maxMatchCells counts as running, and a proposal checks only a group that scores', () => {
  const named = (name) => contract.scanWorkflow(`on: pull_request\njobs:\n  job:\n    name: ${name}\n    runs-on: x\n`);
  const narrow = { ...contract.LIMITS, maxNameChars: 8 };
  assert.equal(contract.versionRuns(named('abcdefghi'), 'zzz', narrow), true);
  assert.equal(contract.versionRuns(named('abcdefgh'), 'zzz', narrow), false);
  assert.equal(contract.versionRuns(named('abcdefgh'), 'abcdefgh', narrow), true);
  assert.equal(contract.versionRuns(named('x'.repeat(contract.LIMITS.maxNameChars + 1)), 'zzz'), true);
  assert.equal(contract.versionRuns(named('x'.repeat(contract.LIMITS.maxNameChars)), 'zzz'), false);
  assert.ok(contract.LIMITS.maxMatchCells >= 1024 * 1024);
  const scanned = contract.scanWorkflow(WORKFLOW);
  assert.equal(contract.versionRuns(scanned, 'no such job'), false);
  assert.equal(contract.versionRuns(scanned, 'no such job', { ...contract.LIMITS, maxMatchCells: 40 }), true);
  assert.equal(contract.versionRuns(scanned, 'x'.repeat(4 * 1024 * 1024)), true);
  const checked = [];
  const proposal = contract.proposeJob([job('lint', 'success', ['npm run lint']), job('test', 'success', ['npm test'])], 'npm test', (pattern) => {
    checked.push(pattern);
    return true;
  });
  assert.equal(proposal, 'test');
  assert.deepEqual(checked, ['test']);
});

test('a workflow path must name a yaml file directly under .github/workflows', () => {
  assert.equal(contract.normalizeWorkflowPath('ci.yml'), '.github/workflows/ci.yml');
  assert.equal(contract.normalizeWorkflowPath('.github/workflows/test.yaml'), '.github/workflows/test.yaml');
  assert.equal(contract.normalizeWorkflowPath('.github/workflows/../../evil.yml'), null);
  assert.equal(contract.normalizeWorkflowPath('ci/ci.yml'), null);
  assert.equal(contract.normalizeWorkflowPath('ci.txt'), null);
  assert.equal(contract.normalizeWorkflowPath(''), null);
});

test('only github.com remotes are supported and other forges are named', () => {
  assert.deepEqual(contract.repoIdentity('https://github.com/acme/app.git'), { provider: 'github', host: 'github.com', repo: 'acme/app' });
  assert.deepEqual(contract.repoIdentity('git@github.com:acme/app.git'), { provider: 'github', host: 'github.com', repo: 'acme/app' });
  assert.equal(contract.repoIdentity('https://gitlab.com/acme/app.git').provider, 'unsupported');
  assert.equal(contract.repoIdentity('').provider, 'unknown');
});

test('every gh api call names github.com, so GH_HOST or a gh login to another host never answers the verification', () => {
  const root = project();
  const gh = ghShim(responses());
  const result = contract.verify(verifyOptions(root, tempDir('data'), gh, { env: { ...CLEAN_ENV, ...gh.env, GH_HOST: 'ghe.example.invalid' } }));
  assert.equal(result.verified, true, result.reason);
  assert.ok(gh.calls().length >= 3);
  assert.ok(gh.calls().every((endpoint) => endpoint.startsWith(`repos/${REPO}`)), gh.calls().join(', '));
});

function runWindowsPreload(fixture, calls, args, env = {}) {
  const output = { 1: '', 2: '' };
  const fakeFs = {
    readFileSync: fs.readFileSync,
    appendFileSync: fs.appendFileSync,
    existsSync: fs.existsSync,
    writeSync: (descriptor, text) => { output[descriptor] += String(text); return String(text).length; },
  };
  const fakeProcess = { execPath: 'C:/stub/gh.exe', argv: ['C:/stub/gh.exe', 'C:/stub/api', ...args], env, exit: (code) => { throw Object.assign(new Error('exit'), { exitCode: code }); } };
  let exitCode = null;
  try {
    new Function('require', 'process', stubLib.windowsPreload(fixture, calls))((name) => (name === 'fs' ? fakeFs : require(name)), fakeProcess);
  } catch (error) {
    if (!error || typeof error.exitCode !== 'number') throw error;
    exitCode = error.exitCode;
  }
  return { exitCode, stdout: output[1], stderr: output[2] };
}

test('the Windows stub preload reads the endpoint past a trailing --hostname flag and answers only github.com', () => {
  const directory = tempDir('preload');
  const fixture = path.join(directory, 'fixture.json');
  const calls = path.join(directory, 'calls.log');
  fs.writeFileSync(fixture, JSON.stringify({ [`repos/${REPO}`]: { default_branch: 'main' } }));
  const pinned = runWindowsPreload(fixture, calls, [`repos/${REPO}`, '--hostname', 'github.com'], { GH_HOST: 'ghe.example.invalid' });
  assert.equal(pinned.exitCode, 0, pinned.stderr);
  assert.deepEqual(JSON.parse(pinned.stdout), { default_branch: 'main' });
  const elsewhere = runWindowsPreload(fixture, calls, [`repos/${REPO}`], { GH_HOST: 'ghe.example.invalid' });
  assert.equal(elsewhere.exitCode, 1);
  assert.equal(elsewhere.stderr, 'error connecting to ghe.example.invalid\n');
  assert.deepEqual(fs.readFileSync(calls, 'utf8').trim().split('\n'), [`repos/${REPO}`, `repos/${REPO}`]);
});

test('the POSIX stub reads the endpoint past a trailing --hostname flag and answers only github.com', () => {
  const directory = tempDir('posix');
  const fixture = path.join(directory, 'fixture.json');
  const calls = path.join(directory, 'calls.log');
  const script = path.join(directory, 'gh-posix.js');
  fs.writeFileSync(fixture, JSON.stringify({ [`repos/${REPO}`]: { default_branch: 'main' } }));
  fs.writeFileSync(script, stubLib.posixScript(fixture, calls));
  const env = { ...CLEAN_ENV, GH_HOST: 'ghe.example.invalid' };
  const pinned = childProcess.spawnSync(process.execPath, [script, 'api', `repos/${REPO}`, '--hostname', 'github.com'], { env, encoding: 'utf8' });
  assert.equal(pinned.status, 0, pinned.stderr);
  assert.deepEqual(JSON.parse(pinned.stdout), { default_branch: 'main' });
  const elsewhere = childProcess.spawnSync(process.execPath, [script, 'api', `repos/${REPO}`], { env, encoding: 'utf8' });
  assert.equal(elsewhere.status, 1);
  assert.equal(elsewhere.stderr, 'error connecting to ghe.example.invalid\n');
  assert.deepEqual(fs.readFileSync(calls, 'utf8').trim().split('\n'), [`repos/${REPO}`, `repos/${REPO}`]);
});

test('a process inside CI never defers the suite to itself', () => {
  assert.equal(contract.insideCi({ CI: 'true' }), true);
  assert.equal(contract.insideCi({ GITHUB_ACTIONS: 'true' }), true);
  assert.equal(contract.insideCi({ CI: 'false' }), false);
  assert.equal(contract.insideCi({}), false);
});

test('matrix jobs group into one pattern and a test job is proposed over a lint job', () => {
  const jobs = [
    job('lint', 'success', ['npm run lint']),
    job('test (ubuntu-latest, 20)', 'success', ['npm test']),
    job('test (windows-latest, 20)', 'failure', ['npm test']),
  ];
  assert.deepEqual(contract.groupJobs(jobs).map((group) => [group.pattern, group.jobs.length]), [['lint', 1], ['test (*)', 2]]);
  assert.equal(contract.proposeJob(jobs, 'npm test'), 'test (*)');
  assert.equal(contract.proposeJob([job('lint', 'success', ['npm run lint'])], ''), null);
  assert.equal(contract.matchesPattern('test (ubuntu-latest, 20)', 'test (*)'), true);
  assert.equal(contract.matchesPattern('test-e2e', 'test (*)'), false);
  assert.deepEqual(contract.commandsForDisplay([job('test', 'success', ['npm ci', 'npm test'])], contract.LIMITS), ['npm test', 'npm ci']);
});

test('the remote proof binds the test job, reads its command and the merge-blocking state', () => {
  const root = project();
  const gh = ghShim(responses({
    [`repos/${REPO}/rules/branches/main`]: [{ type: 'required_status_checks', parameters: { required_status_checks: [{ context: 'test' }] } }],
  }));
  const result = contract.verify(verifyOptions(root, tempDir('data'), gh));
  assert.equal(result.verified, true, result.reason);
  assert.equal(result.workflow, '.github/workflows/ci.yml');
  assert.equal(result.job, 'test');
  assert.deepEqual(result.ciCommands, ['npm test']);
  assert.equal(result.base, 'main');
  assert.equal(result.lastRun.conclusion, 'success');
  assert.equal(result.mergeBlocking, 'yes');
  assert.equal(result.skippedNewer, 0);
  assert.ok(result.conditions.some((entry) => entry.startsWith('job test if:')));
});

test('a job skipped in the newest run is proven by an older run and the skip is counted', () => {
  const root = project();
  const gh = ghShim(responses({
    [`repos/${REPO}/actions/runs/2/jobs?per_page=100`]: { jobs: [job('lint', 'success', ['npm run lint']), job('test', 'skipped', [])] },
  }));
  const result = contract.verify(verifyOptions(root, tempDir('data'), gh, { job: 'test' }));
  assert.equal(result.verified, true, result.reason);
  assert.equal(result.lastRun.id, 1);
  assert.equal(result.lastRun.conclusion, 'failure');
  assert.equal(result.skippedNewer, 1);
  assert.equal(result.mergeBlocking, 'no');
});

test('the remote proof refuses a lint-only pipeline, cancelled runs, forks and old runs', () => {
  const root = project();
  const lintOnly = ghShim(responses({
    [`repos/${REPO}/actions/runs/2/jobs?per_page=100`]: { jobs: [job('lint', 'success', ['npm run lint'])] },
    [`repos/${REPO}/actions/runs/1/jobs?per_page=100`]: { jobs: [job('lint', 'success', ['npm run lint'])] },
  }));
  assert.match(contract.verify(verifyOptions(root, tempDir('data'), lintOnly, { localCommand: '' })).reason, /no job .* looks like a test run/);
  const cancelled = ghShim(responses({
    [`repos/${REPO}/actions/workflows/ci.yml/runs?event=pull_request&status=completed&per_page=20`]: { workflow_runs: [run(3, NOW - HOUR, 'cancelled')] },
  }));
  assert.match(contract.verify(verifyOptions(root, tempDir('data'), cancelled)).reason, /no completed pull_request run that concluded success or failure/);
  const fork = ghShim(responses({ [`repos/${REPO}`]: { default_branch: 'main', fork: true } }));
  assert.match(contract.verify(verifyOptions(root, tempDir('data'), fork)).reason, /fork/);
  const old = ghShim(responses({
    [`repos/${REPO}/actions/workflows/ci.yml/runs?event=pull_request&status=completed&per_page=20`]: { workflow_runs: [run(2, NOW - 40 * 24 * HOUR)] },
  }));
  assert.match(contract.verify(verifyOptions(root, tempDir('data'), old)).reason, /older than 30 days/);
  const skippedEverywhere = ghShim(responses({
    [`repos/${REPO}/actions/runs/2/jobs?per_page=100`]: { jobs: [job('test', 'skipped', [])] },
    [`repos/${REPO}/actions/runs/1/jobs?per_page=100`]: { jobs: [job('test', 'cancelled', [])] },
  }));
  assert.match(contract.verify(verifyOptions(root, tempDir('data'), skippedEverywhere, { job: 'test' })).reason, /did not run to success or failure/);
});

test('the workflow itself must trigger on pull_request and exist', () => {
  const pushOnly = project('on:\n  push:\n    branches: [main]\njobs:\n  test:\n    runs-on: x\n');
  assert.match(contract.verify(verifyOptions(pushOnly, tempDir('data'), ghShim(responses()))).reason, /does not trigger on pull_request/);
  const missing = project(null);
  assert.match(contract.verify(verifyOptions(missing, tempDir('data'), ghShim(responses()))).reason, /does not exist/);
  const gitlab = project(WORKFLOW, 'https://gitlab.com/acme/app.git');
  assert.match(contract.verify(verifyOptions(gitlab, tempDir('data'), ghShim(responses()))).reason, /not supported yet/);
  assert.match(contract.verify(verifyOptions(project(), tempDir('data'), ghShim(responses()), { env: { ...CLEAN_ENV, CI: 'true' } })).reason, /inside a CI pipeline/);
});

test('the cache serves the proof offline, expires by age and is voided by a workflow edit', () => {
  const root = project();
  const data = tempDir('data');
  const gh = ghShim(responses());
  assert.equal(contract.verify(verifyOptions(root, data, gh)).verified, true);
  const networkCalls = gh.calls().length;
  const cached = contract.verify(verifyOptions(root, data, gh, { mode: 'cache', now: NOW + HOUR }));
  assert.equal(cached.verified, true);
  assert.equal(cached.stale, false);
  assert.equal(gh.calls().length, networkCalls);
  const stale = contract.verify(verifyOptions(root, data, gh, { mode: 'cache', now: NOW + 3 * 24 * HOUR }));
  assert.equal(stale.verified, true);
  assert.equal(stale.stale, true);
  assert.match(contract.verify(verifyOptions(root, data, gh, { mode: 'cache', now: NOW + 8 * 24 * HOUR })).reason, /older than 7 days/);
  fs.appendFileSync(path.join(root, '.github', 'workflows', 'ci.yml'), '# edited\n');
  assert.match(contract.verify(verifyOptions(root, data, gh, { mode: 'cache', now: NOW + HOUR })).reason, /in this working tree differs from every verified version, so CI may no longer run what was verified; run --full-suite-policy --refresh$/);
  assert.match(contract.verify(verifyOptions(project(), tempDir('data'), gh, { mode: 'cache' })).reason, /no verification .* is cached yet/);
});

test('a failed refresh keeps a proof inside the grace window and discloses the failure', () => {
  const root = project();
  const data = tempDir('data');
  assert.equal(contract.verify(verifyOptions(root, data, ghShim(responses()))).verified, true);
  const broken = ghShim({ [`repos/${REPO}`]: { __fail: 'error connecting to api.github.com' } });
  const kept = contract.verify(verifyOptions(root, data, broken, { now: NOW + 2 * 24 * HOUR }));
  assert.equal(kept.verified, true);
  assert.equal(kept.stale, true);
  assert.match(kept.refreshFailure, /error connecting/);
  const lost = contract.verify(verifyOptions(root, data, broken, { now: NOW + 9 * 24 * HOUR }));
  assert.equal(lost.verified, false);
});

const DEADLINE_REASON = 'the refresh deadline of 1 s passed before gh api repos/acme/app answered';

test('a refresh stops asking GitHub once its deadline has passed, caps the call in flight and keeps the failure transient', () => {
  assert.equal(contract.LIMITS.refreshDeadlineMs, 60000);
  assert.ok(contract.LIMITS.refreshDeadlineMs < 120000);
  const root = project();
  const data = tempDir('data');
  const gh = ghShim({ ...responses(), __delayMs: 4000 });
  const started = Date.now();
  const result = contract.verify(verifyOptions(root, data, gh, { limits: { refreshDeadlineMs: 1000 } }));
  const elapsed = Date.now() - started;
  assert.equal(result.verified, false);
  assert.equal(result.transient, true);
  assert.equal(result.reason, DEADLINE_REASON);
  assert.deepEqual(gh.calls(), [`repos/${REPO}`]);
  assert.ok(elapsed < 2500, `${elapsed} ms`);
  assert.equal(fs.existsSync(cacheDirOf(data)) ? fs.readdirSync(cacheDirOf(data)).length : 0, 0);
});

test('discovery spends one refresh deadline over all candidate workflows', () => {
  const root = project();
  fs.writeFileSync(path.join(root, '.github', 'workflows', 'pr.yml'), WORKFLOW);
  const gh = ghShim({ ...responses(), __delayMs: 4000 });
  const started = Date.now();
  const result = contract.discover(verifyOptions(root, tempDir('data'), gh, { workflow: undefined, limits: { refreshDeadlineMs: 1000 } }));
  const elapsed = Date.now() - started;
  assert.equal(result.verified, false);
  assert.equal(result.reason, DEADLINE_REASON);
  assert.deepEqual(gh.calls(), [`repos/${REPO}`]);
  assert.ok(elapsed < 2500, `${elapsed} ms`);
});

test('a refresh that disproves the pipeline removes the cached proof, so later cached reads stay local', () => {
  const root = project();
  const data = tempDir('data');
  assert.equal(contract.verify(verifyOptions(root, data, ghShim(responses()))).verified, true);
  const disproved = ghShim(responses({ [`repos/${REPO}`]: { default_branch: 'main', fork: true } }));
  const refreshed = contract.verify(verifyOptions(root, data, disproved, { now: NOW + 2 * 24 * HOUR }));
  assert.equal(refreshed.verified, false);
  assert.match(refreshed.reason, /fork/);
  const cached = contract.verify(verifyOptions(root, data, disproved, { mode: 'cache', now: NOW + 2 * 24 * HOUR }));
  assert.equal(cached.verified, false);
  assert.match(cached.reason, /no verification .* is cached yet/);
});

test('two worktrees of one clone whose workflow files differ keep their own proofs, so neither voids the other', () => {
  const root = project();
  const other = worktreeOf(root, 'other-ci', `${WORKFLOW}# another version\n`);
  const data = tempDir('data');
  const gh = ghShim(responses());
  assert.notEqual(blobOf(root), blobOf(other));
  assert.equal(contract.verify(verifyOptions(root, data, gh)).verified, true);
  assert.equal(contract.verify(verifyOptions(other, data, gh)).verified, true);
  const first = contract.verify(verifyOptions(root, data, gh, { mode: 'cache', now: NOW + HOUR }));
  assert.equal(first.verified, true, first.reason);
  assert.equal(first.job, 'test');
  const second = contract.verify(verifyOptions(other, data, gh, { mode: 'cache', now: NOW + HOUR }));
  assert.equal(second.verified, true, second.reason);
  assert.deepEqual(fs.readdirSync(cacheDirOf(data)).sort(), [path.basename(proofFile(data, blobOf(root))), path.basename(proofFile(data, blobOf(other)))].sort());
  assert.equal(contract.proofName(REPO, WF, blobOf(root), 'test'), path.basename(proofFile(data, blobOf(root))));
});

test('a disproof removes every cached proof of the workflow, the legacy slot included, and spares other workflows', () => {
  const root = project();
  const other = worktreeOf(root, 'other-ci', `${WORKFLOW}# another version\n`);
  const data = tempDir('data');
  const gh = ghShim(responses());
  assert.equal(contract.verify(verifyOptions(root, data, gh)).verified, true);
  assert.equal(contract.verify(verifyOptions(other, data, gh)).verified, true);
  fs.mkdirSync(cacheDirOf(data), { recursive: true });
  const legacy = legacyFile(data);
  const elsewhere = proofFile(data, blobOf(root), '.github/workflows/release.yml');
  fs.writeFileSync(legacy, fs.readFileSync(proofFile(data, blobOf(other))));
  fs.writeFileSync(elsewhere, '{}\n');
  const disproved = ghShim(responses({ [`repos/${REPO}`]: { default_branch: 'main', fork: true } }));
  const refreshed = contract.verify(verifyOptions(root, data, disproved, { now: NOW + 2 * 24 * HOUR }));
  assert.equal(refreshed.verified, false);
  assert.match(refreshed.reason, /fork/);
  assert.deepEqual(fs.readdirSync(cacheDirOf(data)), [path.basename(elsewhere)]);
  const cachedOther = contract.verify(verifyOptions(other, data, disproved, { mode: 'cache', now: NOW + 2 * 24 * HOUR }));
  assert.equal(cachedOther.verified, false);
  assert.match(cachedOther.reason, /no verification .* is cached yet/);
});

test('a refresh prunes proofs older than the grace window and keeps at most maxProofsPerWorkflow, never the one it wrote', () => {
  const root = project();
  const data = tempDir('data');
  const versions = [];
  const refresh = (label, at, limits) => {
    fs.writeFileSync(workflowFile(root), `${WORKFLOW}# ${label}\n`);
    const result = contract.verify(verifyOptions(root, data, ghShim(responses({}, at)), { now: at, limits }));
    assert.equal(result.verified, true, result.reason);
    versions.push(blobOf(root));
  };
  const present = () => versions.map((blob) => fs.existsSync(proofFile(data, blob)));
  refresh('v1', NOW - 8 * 24 * HOUR);
  refresh('v2', NOW);
  assert.deepEqual(present(), [false, true]);
  const bound = { maxProofsPerWorkflow: 3 };
  refresh('v3', NOW + HOUR, bound);
  refresh('v4', NOW + 2 * HOUR, bound);
  assert.deepEqual(present(), [false, true, true, true]);
  refresh('v5', NOW + 3 * HOUR, bound);
  assert.deepEqual(present(), [false, false, true, true, true]);
  refresh('v6', NOW - HOUR, { maxProofsPerWorkflow: 1 });
  assert.deepEqual(present(), [false, false, false, false, false, true]);
  assert.equal(fs.existsSync(legacyFile(data)), false);
  assert.equal(contract.LIMITS.maxProofsPerWorkflow, 16);
});

test('a refresh neither counts nor removes a proof file it cannot read when it prunes', () => {
  const root = project();
  const data = tempDir('data');
  const versions = [];
  const refresh = (label, at, limits) => {
    fs.writeFileSync(workflowFile(root), `${WORKFLOW}# ${label}\n`);
    const result = contract.verify(verifyOptions(root, data, ghShim(responses({}, at)), { now: at, limits }));
    assert.equal(result.verified, true, result.reason);
    versions.push(blobOf(root));
  };
  const present = () => versions.map((blob) => fs.existsSync(proofFile(data, blob)));
  refresh('v1', NOW);
  refresh('v2', NOW + HOUR);
  const unparseable = proofFile(data, 'f'.repeat(64));
  fs.writeFileSync(unparseable, '{ not json\n');
  const misnamed = proofFile(data, 'e'.repeat(64));
  fs.copyFileSync(proofFile(data, versions[0]), misnamed);
  const bound = { maxProofsPerWorkflow: 3 };
  refresh('v3', NOW + 2 * HOUR, bound);
  assert.deepEqual(present(), [true, true, true]);
  refresh('v4', NOW + 3 * HOUR, bound);
  assert.deepEqual(present(), [false, true, true, true]);
  assert.equal(fs.existsSync(unparseable), true);
  assert.equal(fs.existsSync(misnamed), true);
});

test('a legacy slot written by an older installation serves the version it verified, and a refresh never writes that slot', () => {
  const root = project();
  const data = tempDir('data');
  const gh = ghShim(responses());
  assert.equal(contract.verify(verifyOptions(root, data, gh)).verified, true);
  const legacy = legacyFile(data);
  assert.equal(fs.existsSync(legacy), false);
  assert.equal(contract.cacheName(REPO, WF), path.basename(legacy));
  fs.renameSync(proofFile(data, blobOf(root)), legacy);
  const served = contract.verify(verifyOptions(root, data, gh, { mode: 'cache', now: NOW + HOUR }));
  assert.equal(served.verified, true, served.reason);
  const before = fs.readFileSync(legacy, 'utf8');
  fs.appendFileSync(workflowFile(root), '# edited\n');
  assert.match(contract.verify(verifyOptions(root, data, gh, { mode: 'cache', now: NOW + HOUR })).reason, /differs from every verified version/);
  assert.equal(contract.verify(verifyOptions(root, data, gh, { now: NOW + HOUR })).verified, true);
  assert.equal(fs.readFileSync(legacy, 'utf8'), before);
  assert.equal(fs.existsSync(proofFile(data, blobOf(root))), true);
});

test('a proof served from the legacy slot is kept as its own version, so an older installation that rewrites the slot leaves it verified', () => {
  const root = project();
  const other = worktreeOf(root, 'older-install', `${WORKFLOW}# another version\n`);
  const data = tempDir('data');
  const gh = ghShim(responses());
  assert.equal(contract.verify(verifyOptions(other, data, gh)).verified, true);
  assert.equal(contract.verify(verifyOptions(root, data, gh)).verified, true);
  const legacy = legacyFile(data);
  const otherProof = fs.readFileSync(proofFile(data, blobOf(other)));
  fs.rmSync(proofFile(data, blobOf(other)));
  fs.renameSync(proofFile(data, blobOf(root)), legacy);
  const calls = gh.calls().length;
  const served = contract.verify(verifyOptions(root, data, gh, { now: NOW + HOUR }));
  assert.equal(served.verified, true, served.reason);
  assert.equal(gh.calls().length, calls);
  assert.equal(fs.existsSync(proofFile(data, blobOf(root))), true);
  fs.writeFileSync(legacy, otherProof);
  const cached = contract.verify(verifyOptions(root, data, gh, { mode: 'cache', now: NOW + 2 * HOUR }));
  assert.equal(cached.verified, true, cached.reason);
});

test('a fresher legacy proof of the same version and job wins over an expired proof of its own', () => {
  const root = project();
  const data = tempDir('data');
  const early = NOW - 9 * 24 * HOUR;
  assert.equal(contract.verify(verifyOptions(root, data, ghShim(responses({}, early)), { now: early })).verified, true);
  const scratch = tempDir('data');
  const gh = ghShim(responses());
  assert.equal(contract.verify(verifyOptions(root, scratch, gh)).verified, true);
  fs.copyFileSync(proofFile(scratch, blobOf(root)), legacyFile(data));
  const cached = contract.verify(verifyOptions(root, data, gh, { mode: 'cache', now: NOW + HOUR }));
  assert.equal(cached.verified, true, cached.reason);
  assert.equal(JSON.parse(fs.readFileSync(proofFile(data, blobOf(root)), 'utf8')).verifiedAt, new Date(NOW).toISOString());
});

test('one workflow version verified for two jobs keeps one proof per job, so neither job voids the other', () => {
  const root = project();
  const data = tempDir('data');
  const gh = ghShim(responses());
  assert.equal(contract.verify(verifyOptions(root, data, gh, { job: 'test' })).verified, true);
  assert.equal(contract.verify(verifyOptions(root, data, gh, { job: 'lint' })).verified, true);
  const tested = contract.verify(verifyOptions(root, data, gh, { job: 'test', mode: 'cache', now: NOW + HOUR }));
  const linted = contract.verify(verifyOptions(root, data, gh, { job: 'lint', mode: 'cache', now: NOW + HOUR }));
  assert.equal(tested.verified, true, tested.reason);
  assert.equal(linted.verified, true, linted.reason);
  assert.deepEqual(fs.readdirSync(cacheDirOf(data)).sort(), [path.basename(proofFile(data, blobOf(root), WF, 'test')), path.basename(proofFile(data, blobOf(root), WF, 'lint'))].sort());
});

test('a refresh that disproves only its own job removes that job\'s proofs and keeps the proofs of other jobs', () => {
  const root = project(`${WORKFLOW}  e2e:\n    runs-on: ubuntu-latest\n    steps:\n      - run: npm run e2e\n`);
  const data = tempDir('data');
  const gh = ghShim(responses());
  assert.equal(contract.verify(verifyOptions(root, data, gh, { job: 'test' })).verified, true);
  assert.equal(contract.verify(verifyOptions(root, data, gh, { job: 'lint', now: NOW + HOUR })).verified, true);
  const unrun = contract.verify(verifyOptions(root, data, gh, { job: 'e2e', now: NOW + HOUR }));
  assert.equal(unrun.verified, false);
  assert.match(unrun.reason, /job "e2e" did not run to success or failure/);
  assert.equal(contract.verify(verifyOptions(root, data, gh, { job: 'test', mode: 'cache', now: NOW + HOUR })).verified, true);
  const skipped = ghShim(responses({
    [`repos/${REPO}/actions/runs/2/jobs?per_page=100`]: { jobs: [job('lint', 'success', ['npm run lint']), job('test', 'skipped', [])] },
    [`repos/${REPO}/actions/runs/1/jobs?per_page=100`]: { jobs: [job('lint', 'success', ['npm run lint']), job('test', 'cancelled', [])] },
  }));
  const later = NOW + 25 * HOUR;
  const disproved = contract.verify(verifyOptions(root, data, skipped, { job: 'test', now: later }));
  assert.equal(disproved.verified, false);
  assert.match(disproved.reason, /job "test" did not run to success or failure/);
  assert.equal(fs.existsSync(proofFile(data, blobOf(root), WF, 'test')), false);
  const lint = contract.verify(verifyOptions(root, data, skipped, { job: 'lint', mode: 'cache', now: later }));
  assert.equal(lint.verified, true, lint.reason);
});

test('a refresh that fails transiently serves a legacy proof inside the grace window and keeps it as its own version', () => {
  const root = project();
  const other = worktreeOf(root, 'older-slot', `${WORKFLOW}# another version\n`);
  const data = tempDir('data');
  const gh = ghShim(responses());
  assert.equal(contract.verify(verifyOptions(other, data, gh)).verified, true);
  assert.equal(contract.verify(verifyOptions(root, data, gh)).verified, true);
  const otherProof = fs.readFileSync(proofFile(data, blobOf(other)));
  fs.rmSync(proofFile(data, blobOf(other)));
  fs.renameSync(proofFile(data, blobOf(root)), legacyFile(data));
  const broken = ghShim({ [`repos/${REPO}`]: { __fail: 'error connecting to api.github.com' } });
  const kept = contract.verify(verifyOptions(root, data, broken, { now: NOW + 25 * HOUR }));
  assert.equal(kept.verified, true, kept.reason);
  assert.equal(kept.stale, true);
  assert.match(kept.refreshFailure, /error connecting/);
  assert.equal(fs.existsSync(proofFile(data, blobOf(root))), true);
  fs.writeFileSync(legacyFile(data), otherProof);
  const cached = contract.verify(verifyOptions(root, data, broken, { mode: 'cache', now: NOW + 26 * HOUR }));
  assert.equal(cached.verified, true, cached.reason);
});

test('a disproof of one job removes its proofs of every version and a legacy slot holding it, and spares a legacy slot of another job', () => {
  const root = project();
  const other = worktreeOf(root, 'other-version', `${WORKFLOW}# another version\n`);
  const data = tempDir('data');
  const gh = ghShim(responses());
  assert.equal(contract.verify(verifyOptions(root, data, gh, { job: 'test' })).verified, true);
  assert.equal(contract.verify(verifyOptions(other, data, gh, { job: 'test' })).verified, true);
  fs.copyFileSync(proofFile(data, blobOf(other)), legacyFile(data));
  const scratch = tempDir('data');
  assert.equal(contract.verify(verifyOptions(root, scratch, gh, { job: 'lint' })).verified, true);
  const lintProof = fs.readFileSync(proofFile(scratch, blobOf(root), WF, 'lint'));
  const skipped = ghShim(responses({
    [`repos/${REPO}/actions/runs/2/jobs?per_page=100`]: { jobs: [job('lint', 'success', ['npm run lint']), job('test', 'skipped', [])] },
    [`repos/${REPO}/actions/runs/1/jobs?per_page=100`]: { jobs: [job('lint', 'success', ['npm run lint']), job('test', 'cancelled', [])] },
  }));
  const disproved = contract.verify(verifyOptions(root, data, skipped, { job: 'test', now: NOW + 25 * HOUR }));
  assert.equal(disproved.verified, false);
  assert.match(disproved.reason, /job "test" did not run to success or failure/);
  assert.deepEqual(fs.readdirSync(cacheDirOf(data)), []);
  fs.writeFileSync(legacyFile(data), lintProof);
  assert.equal(contract.verify(verifyOptions(root, data, skipped, { job: 'test', now: NOW + 26 * HOUR })).verified, false);
  assert.deepEqual(fs.readdirSync(cacheDirOf(data)), [path.basename(legacyFile(data))]);
});

test('a requested job whose newest run is older than 30 days disproves that job alone and keeps another job\'s proof', () => {
  const root = project();
  const data = tempDir('data');
  assert.equal(contract.verify(verifyOptions(root, data, ghShim(responses()), { job: 'lint' })).verified, true);
  const old = ghShim(responses({
    [`repos/${REPO}/actions/workflows/ci.yml/runs?event=pull_request&status=completed&per_page=20`]: { workflow_runs: [run(2, NOW - 40 * 24 * HOUR)] },
  }));
  const aged = contract.verify(verifyOptions(root, data, old, { job: 'test', now: NOW + HOUR }));
  assert.equal(aged.verified, false);
  assert.match(aged.reason, /job "test" ran is older than 30 days/);
  const lint = contract.verify(verifyOptions(root, data, old, { job: 'lint', mode: 'cache', now: NOW + HOUR }));
  assert.equal(lint.verified, true, lint.reason);
});

const LINT_ONLY = [
  'name: CI',
  'on:',
  '  pull_request:',
  'jobs:',
  '  lint:',
  '    runs-on: ubuntu-latest',
  '    steps:',
  '      - run: npm run lint',
  '',
].join('\n');

const NOT_RUN_HERE = '.github/workflows/ci.yml in this working tree defines no job that runs as "test", so a pull request from this tree would not run it';

test('a workflow version that drops the bound job is unverified in a refresh, asks GitHub nothing for a requested job and keeps the proofs of every other version', () => {
  const root = project();
  const data = tempDir('data');
  const gh = ghShim(responses());
  assert.equal(contract.verify(verifyOptions(root, data, gh, { job: 'test' })).verified, true);
  const before = fs.readdirSync(cacheDirOf(data)).sort();
  const dropped = worktreeOf(root, 'dropped-test', LINT_ONLY);
  const calls = gh.calls().length;
  const requested = contract.verify(verifyOptions(dropped, data, gh, { job: 'test', now: NOW + HOUR }));
  assert.equal(requested.verified, false);
  assert.equal(requested.reason, NOT_RUN_HERE);
  assert.equal(requested.disproves, 'version');
  assert.equal(gh.calls().length, calls);
  const proposed = contract.verify(verifyOptions(dropped, data, gh, { now: NOW + HOUR }));
  assert.equal(proposed.verified, false);
  assert.equal(proposed.reason, NOT_RUN_HERE);
  assert.equal(proposed.transient, false);
  assert.deepEqual(fs.readdirSync(cacheDirOf(data)).sort(), before);
  assert.equal(contract.verify(verifyOptions(root, data, gh, { job: 'test', mode: 'cache', now: NOW + HOUR })).verified, true);
});

test('a cache read never serves an older proof for a workflow version that does not run its job, the legacy slot included', () => {
  const root = project();
  const data = tempDir('data');
  const gh = ghShim(responses());
  assert.equal(contract.verify(verifyOptions(root, data, gh, { job: 'test' })).verified, true);
  const dropped = worktreeOf(root, 'dropped-test', LINT_ONLY);
  const proof = JSON.parse(fs.readFileSync(proofFile(data, blobOf(root)), 'utf8'));
  const foreign = { ...proof, blob: blobOf(dropped) };
  fs.writeFileSync(proofFile(data, blobOf(dropped)), JSON.stringify(foreign));
  const cached = contract.verify(verifyOptions(dropped, data, gh, { mode: 'cache', now: NOW + HOUR }));
  assert.equal(cached.verified, false);
  assert.equal(cached.reason, `${NOT_RUN_HERE}; run --full-suite-policy --refresh`);
  assert.equal(contract.verify(verifyOptions(dropped, data, gh, { job: 'test', mode: 'cache', now: NOW + HOUR })).reason, NOT_RUN_HERE);
  fs.rmSync(proofFile(data, blobOf(dropped)));
  fs.writeFileSync(legacyFile(data), JSON.stringify(foreign));
  assert.equal(contract.verify(verifyOptions(dropped, data, gh, { mode: 'cache', now: NOW + HOUR })).verified, false);
});

test('a refresh without a requested job proposes only a job the workflow version runs', () => {
  const root = project([
    'name: CI',
    'on:',
    '  pull_request:',
    'jobs:',
    '  e2e:',
    '    runs-on: ubuntu-latest',
    '    steps:',
    '      - run: npx playwright test',
    '',
  ].join('\n'));
  const gh = ghShim(responses({
    [`repos/${REPO}/actions/runs/2/jobs?per_page=100`]: { jobs: [job('test', 'success', ['npm test']), job('e2e', 'success', ['npx playwright test'])] },
  }));
  const result = contract.verify(verifyOptions(root, tempDir('data'), gh));
  assert.equal(result.verified, true, result.reason);
  assert.equal(result.job, 'e2e');
  assert.equal(contract.proposeJob([job('test', 'success', ['npm test']), job('e2e', 'success', ['npx playwright test'])], 'npm test'), 'test');
});

const RENAMED = WORKFLOW.replace('  test:\n    name: test\n', '  unit-tests:\n    name: unit-tests\n');

test('a refresh that finds only a job the workflow version lacks removes that version\'s proofs alone, so a later cache read agrees with it', () => {
  const root = project();
  const data = tempDir('data');
  assert.equal(contract.verify(verifyOptions(root, data, ghShim(responses({}, NOW - 30 * HOUR)), { now: NOW - 30 * HOUR })).verified, true);
  const proof = JSON.parse(fs.readFileSync(proofFile(data, blobOf(root)), 'utf8'));
  fs.writeFileSync(proofFile(data, blobOf(root), WF, 'lint'), JSON.stringify({ ...proof, job: 'lint', result: { ...proof.result, job: 'lint' } }));
  fs.writeFileSync(legacyFile(data), JSON.stringify(proof));
  const renamed = worktreeOf(root, 'renamed-test', RENAMED);
  const runs = responses({
    [`repos/${REPO}/actions/runs/2/jobs?per_page=100`]: { jobs: [job('lint', 'success', ['npm run lint']), job('unit-tests', 'success', ['npm test'])] },
    [`repos/${REPO}/actions/runs/1/jobs?per_page=100`]: { jobs: [job('lint', 'success', ['npm run lint']), job('unit-tests', 'failure', ['npm test'])] },
  });
  assert.equal(contract.verify(verifyOptions(renamed, data, ghShim(runs))).verified, true);
  const renamedProof = proofFile(data, blobOf(renamed), WF, 'unit-tests');
  assert.equal(fs.existsSync(renamedProof), true);
  const refreshed = contract.verify(verifyOptions(root, data, ghShim(runs)));
  assert.equal(refreshed.verified, false);
  assert.equal(refreshed.disproves, 'version');
  assert.equal(refreshed.reason, NOT_RUN_HERE.replace('"test"', '"unit-tests"'));
  assert.equal(fs.existsSync(proofFile(data, blobOf(root))), false);
  assert.equal(fs.existsSync(proofFile(data, blobOf(root), WF, 'lint')), false);
  assert.equal(fs.existsSync(legacyFile(data)), false);
  assert.equal(contract.verify(verifyOptions(root, data, ghShim(runs), { mode: 'cache' })).verified, false);
  assert.equal(fs.existsSync(renamedProof), true);
  assert.equal(contract.verify(verifyOptions(renamed, data, ghShim(runs), { mode: 'cache' })).verified, true);
  fs.copyFileSync(renamedProof, legacyFile(data));
  assert.equal(contract.verify(verifyOptions(root, data, ghShim(runs))).disproves, 'version');
  assert.equal(fs.existsSync(legacyFile(data)), true);
});

test('a job disproof without a requested job removes that job\'s proofs and the version\'s own, and spares another worktree\'s proof', () => {
  const root = project(`${WORKFLOW}  integration:\n    name: integration tests\n    if: false\n    runs-on: ubuntu-latest\n    steps:\n      - run: npm run integration\n`);
  const data = tempDir('data');
  assert.equal(contract.verify(verifyOptions(root, data, ghShim(responses({}, NOW - 30 * HOUR)), { now: NOW - 30 * HOUR })).verified, true);
  const rootProof = proofFile(data, blobOf(root));
  assert.equal(fs.existsSync(rootProof), true);
  const renamed = worktreeOf(root, 'unit-tests', RENAMED);
  const proof = JSON.parse(fs.readFileSync(rootProof, 'utf8'));
  const integrationProof = proofFile(data, blobOf(renamed), WF, 'integration tests');
  fs.writeFileSync(integrationProof, JSON.stringify({ ...proof, blob: blobOf(renamed), job: 'integration tests', result: { ...proof.result, job: 'integration tests' } }));
  const runs = responses({
    [`repos/${REPO}/actions/runs/2/jobs?per_page=100`]: { jobs: [job('unit-tests', 'success', ['npm test']), job('integration tests', 'skipped', [])] },
    [`repos/${REPO}/actions/runs/1/jobs?per_page=100`]: { jobs: [job('unit-tests', 'success', ['npm test']), job('integration tests', 'skipped', [])] },
  });
  assert.equal(contract.verify(verifyOptions(renamed, data, ghShim(runs))).verified, true);
  const renamedProof = proofFile(data, blobOf(renamed), WF, 'unit-tests');
  assert.equal(fs.existsSync(renamedProof), true);
  fs.copyFileSync(renamedProof, legacyFile(data));
  const refreshed = contract.verify(verifyOptions(root, data, ghShim(runs)));
  assert.equal(fs.existsSync(legacyFile(data)), true);
  assert.equal(refreshed.verified, false);
  assert.equal(refreshed.disproves, 'job');
  assert.equal(refreshed.job, 'integration tests');
  assert.match(refreshed.reason, /^job "integration tests" did not run to success or failure/);
  assert.equal(fs.existsSync(rootProof), false);
  assert.equal(fs.existsSync(integrationProof), false);
  assert.equal(fs.existsSync(renamedProof), true);
  assert.equal(contract.verify(verifyOptions(renamed, data, ghShim(runs), { mode: 'cache' })).verified, true);
  assert.equal(contract.verify(verifyOptions(root, data, ghShim(runs), { mode: 'cache' })).verified, false);
});

test('a cache read for a requested job the version runs names that job when only proofs of other jobs are cached', () => {
  const root = project();
  const data = tempDir('data');
  assert.equal(contract.verify(verifyOptions(root, data, ghShim(responses()), { job: 'test' })).verified, true);
  const proof = JSON.parse(fs.readFileSync(proofFile(data, blobOf(root)), 'utf8'));
  fs.rmSync(proofFile(data, blobOf(root)));
  fs.writeFileSync(proofFile(data, blobOf(root), WF, 'e2e'), JSON.stringify({ ...proof, job: 'e2e', result: { ...proof.result, job: 'e2e' } }));
  const cached = contract.verify(verifyOptions(root, data, ghShim(responses()), { job: 'test', mode: 'cache', now: NOW + HOUR }));
  assert.equal(cached.verified, false);
  assert.equal(cached.reason, 'no verification of job "test" is cached for this version of .github/workflows/ci.yml; run --full-suite-policy --refresh');
});

test('merge-blocking is unknown unless both branch-protection reads answered or one of them lists the job', () => {
  const answer = (map) => {
    const gh = ghShim(map);
    return contract.mergeBlocking(REPO, 'main', ['test'], 'test', { ghPath: gh.ghPath, env: { ...CLEAN_ENV, ...gh.env }, limits: contract.LIMITS });
  };
  const listed = [{ type: 'required_status_checks', parameters: { required_status_checks: [{ context: 'test' }] } }];
  assert.equal(answer(responses()), 'no');
  assert.equal(answer(responses({ [`repos/${REPO}/rules/branches/main`]: { __fail: 'HTTP 403: Forbidden' } })), 'unknown');
  assert.equal(answer(responses({ [`repos/${REPO}/branches/main`]: { __fail: 'HTTP 403: Forbidden' } })), 'unknown');
  assert.equal(answer(responses({ [`repos/${REPO}/branches/main`]: { __fail: 'HTTP 403: Forbidden' }, [`repos/${REPO}/rules/branches/main`]: listed })), 'yes');
});

test('discovery picks the workflow that runs pull requests', () => {
  const root = project();
  fs.writeFileSync(path.join(root, '.github', 'workflows', 'a-release.yml'), 'on:\n  workflow_dispatch:\njobs:\n  x:\n    runs-on: y\n');
  const result = contract.discover(verifyOptions(root, tempDir('data'), ghShim(responses()), { workflow: undefined }));
  assert.equal(result.verified, true, result.reason);
  assert.equal(result.workflow, '.github/workflows/ci.yml');
  const none = project('on: push\n');
  assert.match(contract.discover(verifyOptions(none, tempDir('data'), ghShim(responses()))).reason, /no workflow .* triggers on pull_request/);
});

function policyInputs(root, data, extra = {}) {
  return { projectRoot: root, pluginData: data, sessionKey: SESSION, markerState: 'none', config: {}, env: CLEAN_ENV, now: NOW + HOUR, ...extra };
}

function verifiedProject(at = NOW) {
  const root = project();
  const data = tempDir('data');
  const gh = ghShim(responses({}, at));
  assert.equal(contract.discover(verifyOptions(root, data, gh, { now: at })).verified, true);
  return { root, data, gh };
}

test('the ladder: nothing recorded asks, and without a verified pipeline it stays local', () => {
  const { root, data } = verifiedProject();
  const ask = policy.resolve({ ...policyInputs(root, data), needCandidate: true });
  assert.equal(ask.runner, 'ask');
  const quiet = policy.resolve(policyInputs(root, data));
  assert.equal(quiet.runner, 'local');
  const bare = policy.resolve({ ...policyInputs(project(), tempDir('data')), needCandidate: true });
  assert.equal(bare.runner, 'local');
  assert.match(bare.reason, /no verified CI pull-request pipeline/);
});

test('the ladder: a ci choice needs the verified pipeline and any local choice wins', () => {
  const { root, data } = verifiedProject();
  const stores = policy.stores(data);
  policy.writeClone(stores, root, 'ci', '.github/workflows/ci.yml', 'test', NOW);
  const ci = policy.resolve(policyInputs(root, data));
  assert.equal(ci.runner, 'ci');
  assert.equal(ci.decidedBy, 'this clone');
  const sessionLocal = policy.resolve(policyInputs(root, data, { markerState: 'local' }));
  assert.equal(sessionLocal.runner, 'local');
  assert.equal(sessionLocal.decidedBy, 'session marker');
  const configLocal = policy.resolve(policyInputs(root, data, { config: { runner: 'local' } }));
  assert.equal(configLocal.runner, 'local');
  assert.equal(configLocal.decidedBy, 'config');
  const sessionCi = policy.resolve(policyInputs(project(), tempDir('data'), { markerState: 'ci' }));
  assert.equal(sessionCi.runner, 'local');
  assert.match(sessionCi.reason, /chose CI full-suite runs, but the CI pull-request pipeline is not verified/);
  const inCi = policy.resolve(policyInputs(root, data, { env: { ...CLEAN_ENV, GITHUB_ACTIONS: 'true' } }));
  assert.equal(inCi.runner, 'local');
  policy.writeClone(stores, root, 'local', null, null, NOW);
  const cloneLocal = policy.resolve(policyInputs(root, data, { markerState: 'ci' }));
  assert.equal(cloneLocal.runner, 'local');
  assert.equal(cloneLocal.decidedBy, 'this clone');
  assert.equal(cloneLocal.reason, 'the record for this clone chose local full-suite runs');
});

test('the clone record is shared by every worktree of the clone', () => {
  const { root, data } = verifiedProject();
  const worktree = path.join(tempDir('wt'), 'tree');
  sh(root, `git worktree add -q ${JSON.stringify(worktree)} -b side`);
  policy.writeClone(policy.stores(data), root, 'ci', '.github/workflows/ci.yml', 'test', NOW);
  const clone = policy.readClone(policy.stores(data), fs.realpathSync(worktree));
  assert.equal(clone && clone.runner, 'ci');
  assert.equal(policy.clearClone(policy.stores(data), root), true);
  assert.equal(policy.readClone(policy.stores(data), root), null);
});

test('the terminus honours CI only when the chain began in CI, so a mid-chain switch only downgrades', () => {
  const { root, data } = verifiedProject();
  const stores = policy.stores(data);
  const terminus = (extra) => policy.resolve({ ...policyInputs(root, data, extra), requireSnapshot: true });
  assert.equal(terminus({ markerState: 'ci' }).runner, 'local');
  assert.match(terminus({ markerState: 'ci' }).reason, /no full-suite snapshot/);
  policy.writeSnapshot(stores, SESSION, root, { runner: 'local', decidedBy: 'default' }, NOW);
  const began = terminus({ markerState: 'ci' });
  assert.equal(began.runner, 'local');
  assert.match(began.reason, /began with the local runner/);
  policy.writeSnapshot(stores, SESSION, root, { runner: 'ci', decidedBy: 'session marker' }, NOW);
  assert.equal(terminus({ markerState: 'ci' }).runner, 'ci');
  assert.equal(terminus({ markerState: 'local' }).runner, 'local');
});

test('a worktree keeps its ci policy and snapshot after a worktree with another workflow file refreshed', () => {
  const root = project();
  const other = worktreeOf(root, 'other-ci', `${WORKFLOW}# another version\n`);
  const data = tempDir('data');
  const gh = ghShim(responses());
  const inputs = (tree) => policyInputs(tree, data, { env: { ...CLEAN_ENV, ...gh.env }, ghPath: gh.ghPath });
  assert.equal(contract.verify(verifyOptions(root, data, gh)).verified, true);
  policy.writeClone(policy.stores(data), root, 'ci', WF, 'test', NOW);
  assert.equal(policy.resolve({ ...inputs(other), mode: 'refresh' }).runner, 'ci');
  const calls = gh.calls().length;
  const cached = policy.resolve(inputs(root));
  assert.equal(cached.runner, 'ci', cached.reason);
  assert.equal(cached.decidedBy, 'this clone');
  const snapshot = policy.snapshotPolicy(inputs(root), NOW + HOUR);
  assert.equal(snapshot.runner, 'ci', snapshot.reason);
  assert.equal(gh.calls().length, calls);
  assert.deepEqual(policy.snapshotLines(snapshot, root), ['full suite: ci | this chain began with the CI runner: .github/workflows/ci.yml, job "test" runs its full suite when a pull request against main is opened or updated | decided by: this clone']);
  policy.writeSnapshot(policy.stores(data), SESSION, root, snapshot, NOW + HOUR);
  assert.equal(policy.resolve({ ...inputs(root), requireSnapshot: true }).runner, 'ci');
});

test('the policy lines name the contract, the deactivation and the rendered answer commands', () => {
  const { root, data } = verifiedProject();
  const ask = policy.resolve({ ...policyInputs(root, data), needCandidate: true, config: { fullSuiteCommand: 'npm test' } });
  const askLines = policy.policyLines(ask, { projectRoot: root, pluginData: data, now: NOW + HOUR });
  assert.match(askLines[0], /^full suite: ask \| candidate CI: \.github\/workflows\/ci\.yml, job "test" runs 'npm test' \| last pull-request run 3 h ago \(success\) \| merge-blocking: no \| conditions: /);
  assert.match(askLines[0], /local full suite: 'npm test'$/);
  assert.match(askLines[1], /zensu-full-suite\.sh' --ci --repo \| this session only: .* --ci --session \| stay local: .* --local --session$/);
  const ci = policy.resolve(policyInputs(root, data, { markerState: 'ci' }));
  const ciLines = policy.policyLines(ci, { projectRoot: root, pluginData: data, now: NOW + HOUR });
  assert.match(ciLines[0], /^full suite: ci \| .* \| decided by: session marker$/);
  assert.match(ciLines[1], /pull request against main is opened or updated \| deactivate: \/zensu:full-suite --local --repo/);
  const local = policy.resolve(policyInputs(project(), tempDir('data'), { markerState: 'local' }));
  assert.deepEqual(policy.policyLines(local, { projectRoot: root }), ['full suite: local | the session marker chose local full-suite runs | decided by: session marker']);
});

function gitRepo() {
  const root = tempDir('evr');
  sh(root, 'git init -q && git config user.email t@example.invalid && git config user.name tester && git config commit.gpgsign false');
  fs.writeFileSync(path.join(root, 'a.txt'), 'one\n');
  sh(root, 'git add -A && git commit -q -m init');
  return root;
}

function sink() {
  const out = { text: '', write(chunk) { out.text += String(chunk); return true; } };
  return out;
}

const CI_POLICY = { runner: 'ci', decidedBy: 'this clone', summary: 'CI: .github/workflows/ci.yml, job "test" runs \'npm test\'', base: 'main' };

async function runner(root, data, options = {}) {
  const stdout = sink();
  const stderr = sink();
  const code = await evr.run({
    pluginData: data,
    sessionKey: SESSION,
    projectRoot: root,
    cwd: root,
    scope: 'scoped',
    command: 'true',
    show: 'tail',
    bashPath: 'bash',
    env: process.env,
    stdout,
    stderr,
    ...options,
  });
  return { code, stdout: stdout.text, stderr: stderr.text };
}

function ciVerdict(root, data, extra = {}) {
  return evr.verdict({ pluginData: data, sessionKey: SESSION, projectRoot: root, gateMode: 'required', scopedRemedyPrefix: 'SCOPED', ciPolicy: CI_POLICY, ...extra });
}

test('in CI mode the runner refuses a full run without writing a record, and --local runs it', async () => {
  const root = gitRepo();
  const data = tempDir('data');
  const refused = await runner(root, data, { scope: 'full', ciPolicy: CI_POLICY });
  assert.equal(refused.code, 2);
  assert.match(refused.stderr, /runs the full suite in CI .* not a suite failure/);
  assert.match(refused.stderr, /^FULL SUITE — CI contract \| CI: /m);
  assert.equal(fs.existsSync(path.join(data, 'evidence-run', 'v1', 'records', SESSION)), false);
  const local = await runner(root, data, { scope: 'full', ciPolicy: CI_POLICY, local: true });
  assert.equal(local.code, 0);
});

test('a scoped run is bound to the tree and --if-stale skips a fresh green one', async () => {
  const root = gitRepo();
  const data = tempDir('data');
  const first = await runner(root, data, { command: 'echo scoped-ok' });
  assert.equal(first.code, 0);
  assert.match(first.stdout, /scope=scoped exit=0 duration=.* tree=[0-9a-f]{12} /);
  const skipped = await runner(root, data, { command: 'echo scoped-ok', ifStale: true });
  assert.match(skipped.stdout, /skipped \(--if-stale\) — the newest run of this command is green/);
  fs.writeFileSync(path.join(root, 'a.txt'), 'two\n');
  const rerun = await runner(root, data, { command: 'echo scoped-ok', ifStale: true });
  assert.doesNotMatch(rerun.stdout, /skipped/);
});

test('in CI mode a green scoped run on the current tree passes as deferred-ci with the contract line', async () => {
  const root = gitRepo();
  const data = tempDir('data');
  await runner(root, data, { command: 'echo scoped-ok' });
  const result = ciVerdict(root, data);
  assert.equal(result.state, 'deferred-ci');
  assert.equal(result.passes, true);
  assert.match(result.lines[0], /^FULL SUITE — deferred-ci \| the newest run of each local test command on the current tree [0-9a-f]{12} exited 0 \(1 command\(s\), newest record er1_.*CI runs it when a pull request against main is opened or updated \| cmd: echo scoped-ok \| gate: required$/);
  assert.equal(result.lines[1], `FULL SUITE — CI contract | ${CI_POLICY.summary} | decided by: this clone`);
});

test('in CI mode a missing, red or stale local run refuses with a scoped remedy', async () => {
  const root = gitRepo();
  const data = tempDir('data');
  const missing = ciVerdict(root, data);
  assert.equal(missing.state, 'missing');
  assert.equal(missing.passes, false);
  assert.match(missing.lines[0], /\| run: SCOPED --cmd '<the tests affected by this change>'$/);
  await runner(root, data, { command: 'echo a' });
  await runner(root, data, { command: 'exit 4' });
  const red = ciVerdict(root, data);
  assert.equal(red.state, 'failed');
  assert.match(red.lines[0], /exited 4 .*\| run: SCOPED --cmd 'exit 4'$/);
  await runner(root, data, { command: 'true' });
  assert.equal(ciVerdict(root, data).state, 'failed');
  fs.writeFileSync(path.join(root, 'a.txt'), 'changed\n');
  const stale = ciVerdict(root, data);
  assert.equal(stale.state, 'stale');
  assert.match(stale.lines[0], /files changed since: a\.txt/);
  const advisory = ciVerdict(root, data, { gateMode: 'advisory' });
  assert.equal(advisory.passes, true);
  assert.match(advisory.lines[0], /^FULL SUITE — stale \(advisory, not blocking\)/);
});

test('in CI mode a green local full run on the current tree still reads as pass', async () => {
  const root = gitRepo();
  const data = tempDir('data');
  await runner(root, data, { scope: 'full', command: 'true', local: true });
  const result = ciVerdict(root, data);
  assert.equal(result.state, 'pass');
  assert.match(result.lines[0], /^FULL SUITE — pass \| a local full-suite run exited 0 on the current tree/);
});

test('a policy fault is disclosed and the chain is judged as a local chain', () => {
  const result = evr.verdict({ pluginData: tempDir('data'), sessionKey: SESSION, projectRoot: gitRepo(), gateMode: 'required', ciPolicy: { runner: 'local', fault: 'boom' } });
  assert.equal(result.state, 'missing');
  assert.match(result.lines[0], /^FULL SUITE — policy unavailable \| boom; this chain is judged as a local chain/);
});

test('a chain that chose CI but closes locally names the reason at the terminus', () => {
  const reason = 'this chain began with the local runner; a switch to CI takes effect with the next chain';
  const requested = evr.verdict({ pluginData: tempDir('data'), sessionKey: SESSION, projectRoot: gitRepo(), gateMode: 'required', ciPolicy: { runner: 'local', decidedBy: 'chain begin', reason, ciRequested: true } });
  assert.equal(requested.state, 'missing');
  assert.equal(requested.lines[0], `FULL SUITE — local runner | ${reason} | decided by: chain begin`);
  assert.match(requested.lines[1], /^FULL SUITE — missing \| /);
  const plain = evr.verdict({ pluginData: tempDir('data'), sessionKey: SESSION, projectRoot: gitRepo(), gateMode: 'required', ciPolicy: { runner: 'local', decidedBy: 'default', reason: 'nothing selects CI full-suite runs for this clone or session', ciRequested: false } });
  assert.equal(plain.lines.some((line) => line.startsWith('FULL SUITE — local runner')), false);
  const { root, data } = verifiedProject();
  policy.writeSnapshot(policy.stores(data), SESSION, root, { runner: 'local', decidedBy: 'default' }, NOW);
  const input = policy.verdictInput(policy.resolve({ ...policyInputs(root, data, { markerState: 'ci' }), requireSnapshot: true }), root);
  assert.deepEqual(input, { runner: 'local', decidedBy: 'chain begin', reason, ciRequested: true });
});

test('the effective CLI answers ci only for a verified clone choice with a ci snapshot', () => {
  const { root, data } = verifiedProject(Date.now());
  const transport = tempDir('transport');
  fs.writeFileSync(path.join(transport, 'ci-config.json'), '{}');
  fs.writeFileSync(path.join(transport, 'marker-state'), 'ci');
  const env = { ...CLEAN_ENV, ZENSU_FSP_DIR: transport, ZENSU_FSP_PLUGIN_DATA: data, ZENSU_FSP_SESSION_KEY: SESSION, ZENSU_FSP_PROJECT_ROOT: root };
  const cli = path.join(LIB_DIR, 'full-suite-policy-v1.js');
  const before = childProcess.spawnSync(process.execPath, [cli, 'effective'], { env, encoding: 'utf8' });
  assert.equal(before.stdout.trim(), 'local');
  const snapshot = childProcess.spawnSync(process.execPath, [cli, 'snapshot'], { env, encoding: 'utf8' });
  assert.equal(snapshot.status, 0, snapshot.stderr);
  const after = childProcess.spawnSync(process.execPath, [cli, 'effective'], { env, encoding: 'utf8' });
  assert.equal(after.stdout.trim(), 'ci');
});

function snapshotCli(root, data, gh, markerState = 'none') {
  const transport = tempDir('transport');
  fs.writeFileSync(path.join(transport, 'ci-config.json'), '{}');
  fs.writeFileSync(path.join(transport, 'marker-state'), markerState);
  const pathKey = Object.keys(CLEAN_ENV).find((name) => name.toUpperCase() === 'PATH') || 'PATH';
  const env = {
    ...CLEAN_ENV,
    ...gh.env,
    [pathKey]: `${gh.dir}${path.delimiter}${CLEAN_ENV[pathKey] || ''}`,
    ZENSU_FSP_DIR: transport,
    ZENSU_FSP_PLUGIN_DATA: data,
    ZENSU_FSP_SESSION_KEY: SESSION,
    ZENSU_FSP_PROJECT_ROOT: root,
  };
  const result = childProcess.spawnSync(process.execPath, [CLI, 'snapshot'], { env, encoding: 'utf8' });
  return { status: result.status, stdout: result.stdout, stderr: result.stderr, snapshot: policy.readSnapshot(policy.stores(data), SESSION) };
}

test('the snapshot refreshes once when a recorded CI choice has no proof for the workflow version in the tree, and prints its ci line', () => {
  const { root, data } = verifiedProject(Date.now());
  policy.writeClone(policy.stores(data), root, 'ci', WF, 'test', Date.now());
  fs.appendFileSync(workflowFile(root), '# checked out from another branch\n');
  const gh = ghShim(responses({}, Date.now()));
  const result = snapshotCli(root, data, gh);
  assert.equal(result.status, 0, result.stderr);
  assert.ok(gh.calls().length > 0, 'the snapshot asked GitHub once more');
  assert.equal(result.snapshot && result.snapshot.runner, 'ci');
  assert.equal(result.snapshot.decidedBy, 'this clone');
  assert.equal(result.stdout, 'full suite: ci | this chain began with the CI runner: .github/workflows/ci.yml, job "test" runs its full suite when a pull request against main is opened or updated | decided by: this clone\n');
  assert.equal(fs.existsSync(proofFile(data, blobOf(root))), true);
});

test('a snapshot whose refresh fails records local and prints the local line with its reason', () => {
  const { root, data } = verifiedProject(Date.now());
  policy.writeClone(policy.stores(data), root, 'ci', WF, 'test', Date.now());
  fs.appendFileSync(workflowFile(root), '# checked out from another branch\n');
  const gh = ghShim({ [`repos/${REPO}`]: { __fail: 'error connecting to api.github.com' } });
  const result = snapshotCli(root, data, gh);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.snapshot && result.snapshot.runner, 'local');
  assert.equal(result.snapshot.decidedBy, 'this clone');
  assert.equal(result.stdout, 'full suite: local | the record for this clone chose CI full-suite runs, but the CI pull-request pipeline is not verified: gh api repos/acme/app failed: error connecting to api.github.com | decided by: this clone | this chain began with the local runner, so it closes only on a local full-suite run, whatever --full-suite-policy printed before\n');
});

test('the --tdd-begin snapshot refresh is bounded by the refresh deadline and records local with its reason', () => {
  const { root, data } = verifiedProject(Date.now());
  policy.writeClone(policy.stores(data), root, 'ci', WF, 'test', Date.now());
  fs.appendFileSync(workflowFile(root), '# checked out from another branch\n');
  const gh = ghShim({ ...responses({}, Date.now()), __delayMs: 4000 });
  const inputs = policyInputs(root, data, { env: { ...CLEAN_ENV, ...gh.env }, ghPath: gh.ghPath, limits: { refreshDeadlineMs: 1000 } });
  const started = Date.now();
  const snapshot = policy.snapshotPolicy(inputs, Date.now());
  const elapsed = Date.now() - started;
  assert.equal(snapshot.runner, 'local');
  assert.equal(snapshot.decidedBy, 'this clone');
  assert.equal(snapshot.contract.reason, DEADLINE_REASON);
  assert.ok(elapsed < 2500, `${elapsed} ms`);
  const [line] = policy.snapshotLines(snapshot, root);
  assert.match(line, /^full suite: local \| the record for this clone chose CI full-suite runs, but the CI pull-request pipeline is not verified: the refresh deadline of 1 s .* \| decided by: this clone \| this chain began with the local runner/);
});

test('a snapshot without any CI choice prints no line and asks GitHub nothing', () => {
  const root = project();
  const data = tempDir('data');
  const gh = ghShim(responses());
  const result = snapshotCli(root, data, gh);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, '');
  assert.deepEqual(gh.calls(), []);
  assert.equal(result.snapshot && result.snapshot.runner, 'local');
  assert.equal(result.snapshot.decidedBy, 'default');
});

test('the snapshot retires the previous chain\'s snapshot before its refresh asks GitHub', () => {
  const { root, data } = verifiedProject(Date.now());
  const stores = policy.stores(data);
  policy.writeClone(stores, root, 'ci', WF, 'test', Date.now());
  policy.writeSnapshot(stores, SESSION, root, { runner: 'ci', decidedBy: 'this clone' }, Date.now());
  fs.appendFileSync(workflowFile(root), '# checked out from another branch\n');
  const probe = path.join(tempDir('probe'), 'probe.log');
  const gh = ghShim({ ...responses({}, Date.now()), __probe: { path: path.join(stores.snapshots, `${SESSION}.json`), out: probe } });
  const result = snapshotCli(root, data, gh);
  assert.equal(result.status, 0, result.stderr);
  const seen = fs.readFileSync(probe, 'utf8').trim().split('\n');
  assert.ok(seen.length > 0, 'the snapshot asked GitHub');
  assert.deepEqual([...new Set(seen)], ['absent']);
  assert.equal(result.snapshot && result.snapshot.runner, 'ci');
});

test('the chain CLI answers with the runner the chain began with, while the policy CLI answers with the cache', () => {
  const { root, data } = verifiedProject(Date.now());
  const stores = policy.stores(data);
  policy.writeClone(stores, root, 'ci', WF, 'test', Date.now());
  const transport = tempDir('transport');
  fs.writeFileSync(path.join(transport, 'ci-config.json'), '{}');
  fs.writeFileSync(path.join(transport, 'marker-state'), 'none');
  const env = { ...CLEAN_ENV, ZENSU_FSP_DIR: transport, ZENSU_FSP_PLUGIN_DATA: data, ZENSU_FSP_SESSION_KEY: SESSION, ZENSU_FSP_PROJECT_ROOT: root };
  const cli = (mode) => childProcess.spawnSync(process.execPath, [CLI, mode], { env, encoding: 'utf8' });
  policy.writeSnapshot(stores, SESSION, root, { runner: 'local', decidedBy: 'default' }, Date.now());
  const began = cli('chain');
  assert.equal(began.status, 0, began.stderr);
  assert.equal(began.stdout, 'full suite: local | this chain began with the local runner; a switch to CI takes effect with the next chain | decided by: chain begin\n');
  assert.match(cli('policy').stdout, /^full suite: ci \| /);
  policy.writeSnapshot(stores, SESSION, root, { runner: 'ci', decidedBy: 'this clone' }, Date.now());
  assert.match(cli('chain').stdout, /^full suite: ci \| .* \| decided by: this clone\n/);
});
