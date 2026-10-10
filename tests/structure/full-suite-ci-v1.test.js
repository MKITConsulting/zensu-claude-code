'use strict';

const assert = require('node:assert/strict');
const childProcess = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const LIB_DIR = path.join(__dirname, '..', '..', 'hooks', 'lib');
const contract = require(path.join(LIB_DIR, 'ci-contract-v1.js'));
const policy = require(path.join(LIB_DIR, 'full-suite-policy-v1.js'));
const evr = require(path.join(LIB_DIR, 'evidence-run-v1.js'));
const { writeGhStub } = require(path.join(__dirname, 'fixtures', 'gh-api-stub.js'));

const SESSION = `scv1_${'c'.repeat(64)}`;
const REPO = 'acme/app';
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
  return { ghPath: stub.ghPath, env: stub.env, calls: () => (fs.existsSync(calls) ? fs.readFileSync(calls, 'utf8').trim().split('\n').filter(Boolean) : []) };
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
  assert.match(contract.verify(verifyOptions(root, data, gh, { mode: 'cache', now: NOW + HOUR })).reason, /changed since it was verified/);
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
