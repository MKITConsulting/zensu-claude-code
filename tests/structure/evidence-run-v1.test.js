'use strict';

const assert = require('node:assert/strict');
const childProcess = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const LIB = path.join(__dirname, '..', '..', 'hooks', 'lib', 'evidence-run-v1.js');
const evr = require(LIB);

const SESSION = `scv1_${'a'.repeat(64)}`;
const OTHER_SESSION = `scv1_${'b'.repeat(64)}`;
const FAKE_TOKEN = `ghp_${'Q7mZ'.repeat(9)}`;

function tempDir(label) {
  return fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), `evr-${label}-`)));
}

function sh(cwd, command) {
  return childProcess.execSync(command, { cwd, stdio: ['ignore', 'pipe', 'pipe'], encoding: 'utf8' });
}

function gitRepo() {
  const root = tempDir('repo');
  sh(root, 'git init -q && git config user.email t@example.invalid && git config user.name tester && git config commit.gpgsign false');
  fs.writeFileSync(path.join(root, 'a.txt'), 'one\n');
  fs.mkdirSync(path.join(root, 'sub'));
  fs.writeFileSync(path.join(root, 'sub', 'b.txt'), 'two\n');
  sh(root, 'git add -A && git commit -q -m init');
  return root;
}

function pluginData() {
  return tempDir('data');
}

function collector() {
  const sink = { text: '', write(chunk) { sink.text += String(chunk); return true; } };
  return sink;
}

function baseRecord(overrides = {}) {
  return {
    schema: evr.SCHEMA,
    id: evr.newRecordId(1790000000000),
    session_key: SESSION,
    project_root: '/tmp/project',
    scope: 'full',
    command: 'npm test',
    cwd: '/tmp/project',
    state: 'completed',
    pid: 12345,
    started_at: '2026-09-26T10:00:00.000Z',
    finished_at: '2026-09-26T10:01:00.000Z',
    duration_ms: 60000,
    exit_code: 0,
    signal: null,
    tree_start: 'c'.repeat(40),
    tree_start_reason: null,
    tree_end: 'c'.repeat(40),
    tree_end_reason: null,
    plugin_version: '0.21.1',
    log_bytes: 10,
    log_truncated: false,
    ...overrides,
  };
}

async function runIn(root, data, options = {}) {
  const stdout = collector();
  const stderr = collector();
  const runLogLinePath = path.join(tempDir('line'), 'line');
  const code = await evr.run({
    pluginData: data,
    sessionKey: SESSION,
    projectRoot: root,
    cwd: root,
    scope: 'full',
    show: 'tail',
    bashPath: 'bash',
    env: process.env,
    runLogLinePath,
    stdout,
    stderr,
    ...options,
  });
  let line = '';
  try { line = fs.readFileSync(runLogLinePath, 'utf8'); } catch { }
  return { code, stdout: stdout.text, stderr: stderr.text, line };
}

function recordsOf(data, session = SESSION) {
  const directory = path.join(data, 'evidence-run', 'v1', 'records', session);
  return fs.readdirSync(directory).filter((name) => name.endsWith('.json')).sort()
    .map((name) => JSON.parse(fs.readFileSync(path.join(directory, name), 'utf8')));
}

function verdictFor(root, data, options = {}) {
  return evr.verdict({
    pluginData: data,
    sessionKey: SESSION,
    projectRoot: root,
    gateMode: 'required',
    remedyPrefix: 'RUNNER',
    ...options,
  });
}

function deadPid() {
  const child = childProcess.spawnSync(process.execPath, ['-e', 'process.stdout.write(String(process.pid))'], { encoding: 'utf8' });
  return Number(child.stdout);
}

test('record ids are well formed and sort by creation time', () => {
  const early = evr.newRecordId(1000);
  const late = evr.newRecordId(2000);
  assert.match(early, /^er1_[0-9]{13}_[0-9a-f]{12}$/);
  assert.ok(early < late);
});

test('the store rejects a malformed session key', () => {
  assert.throws(() => evr.storeLocations(pluginData(), 'not-a-key'), /invalid session key/);
});

test('the store creates private per-session directories', { skip: process.platform === 'win32' }, () => {
  const data = pluginData();
  const locations = evr.storeLocations(data, SESSION);
  for (const directory of [locations.root, locations.records, locations.logs, locations.scratch]) {
    assert.equal(fs.statSync(directory).mode & 0o777, 0o700);
  }
  assert.equal(locations.records, path.join(data, 'evidence-run', 'v1', 'records', SESSION));
});

test('a complete record validates', () => {
  assert.equal(evr.validateRecord(baseRecord()), null);
});

test('a record with an extra or missing key is rejected', () => {
  assert.equal(evr.validateRecord({ ...baseRecord(), extra: 1 }), 'unexpected key set');
  const missing = baseRecord();
  delete missing.cwd;
  assert.equal(evr.validateRecord(missing), 'unexpected key set');
});

test('a record bound elsewhere is rejected', () => {
  assert.equal(evr.validateRecord(baseRecord(), { sessionKey: OTHER_SESSION }), 'bound to another session');
  assert.equal(evr.validateRecord(baseRecord(), { projectRoot: '/elsewhere' }), 'bound to another project root');
  assert.equal(evr.validateRecord(baseRecord({ schema: 'evidence-run-v0' })), 'unknown schema');
});

test('state and result fields must agree', () => {
  assert.equal(evr.validateRecord(baseRecord({ state: 'running' })), 'running record carries a result');
  assert.equal(evr.validateRecord(baseRecord({ exit_code: null })), 'completed record carries no exit code');
  assert.equal(evr.validateRecord(baseRecord({ tree_end: 'not-a-tree' })), 'malformed tree_end');
});

test('records round-trip through the atomic writer and the hardened reader', () => {
  const locations = evr.storeLocations(pluginData(), SESSION);
  const record = baseRecord();
  const target = evr.writeRecordAtomic(locations.records, record);
  assert.deepEqual(evr.readRecordFile(target).record, record);
  assert.deepEqual(fs.readdirSync(locations.records), [`${record.id}.json`]);
});

test('the reader refuses symlinks, oversized files and garbage', { skip: process.platform === 'win32' }, () => {
  const locations = evr.storeLocations(pluginData(), SESSION);
  const real = path.join(locations.scratch, 'real.json');
  fs.writeFileSync(real, JSON.stringify(baseRecord()));
  const link = path.join(locations.records, 'link.json');
  fs.symlinkSync(real, link);
  assert.match(evr.readRecordFile(link).invalid, /unreadable/);
  const garbage = path.join(locations.records, 'garbage.json');
  fs.writeFileSync(garbage, '{not json');
  assert.equal(evr.readRecordFile(garbage).invalid, 'unparseable');
  assert.equal(evr.readRecordFile(real, { ...evr.LIMITS, maxRecordBytes: 10 }).invalid, 'oversized');
});

test('the tree id is stable for the same content and survives a commit', () => {
  const root = gitRepo();
  const scratch = tempDir('scratch');
  const first = evr.computeTree(root, scratch);
  assert.match(first.tree, /^[0-9a-f]{40}/);
  assert.equal(evr.computeTree(root, scratch).tree, first.tree);
  fs.writeFileSync(path.join(root, 'a.txt'), 'changed\n');
  const edited = evr.computeTree(root, scratch);
  assert.notEqual(edited.tree, first.tree);
  sh(root, 'git commit -q -am edit');
  assert.equal(evr.computeTree(root, scratch).tree, edited.tree);
});

test('the tree id sees untracked files but ignores .zensu', () => {
  const root = gitRepo();
  const scratch = tempDir('scratch');
  const base = evr.computeTree(root, scratch).tree;
  fs.mkdirSync(path.join(root, '.zensu', 'logs'), { recursive: true });
  fs.writeFileSync(path.join(root, '.zensu', 'logs', 'run.log'), 'noise\n');
  assert.equal(evr.computeTree(root, scratch).tree, base);
  fs.writeFileSync(path.join(root, 'new.txt'), 'new\n');
  assert.notEqual(evr.computeTree(root, scratch).tree, base);
});

test('a gitignored .zensu with tracked files inside still fingerprints and stays excluded', () => {
  const root = gitRepo();
  const scratch = tempDir('scratch');
  fs.writeFileSync(path.join(root, '.gitignore'), '.zensu/*\n!.zensu/config.json\n');
  fs.mkdirSync(path.join(root, '.zensu', 'logs'), { recursive: true });
  fs.writeFileSync(path.join(root, '.zensu', 'config.json'), '{}\n');
  sh(root, 'git add .gitignore .zensu/config.json && git commit -q -m zensu');
  const base = evr.computeTree(root, scratch);
  assert.match(base.tree, /^[0-9a-f]{40}/, base.reason || '');
  fs.writeFileSync(path.join(root, '.zensu', 'logs', 'run.log'), 'noise\n');
  fs.writeFileSync(path.join(root, '.zensu', 'config.json'), '{"changed":true}\n');
  assert.equal(evr.computeTree(root, scratch).tree, base.tree);
});

test('git runs with a scrubbed environment and the C locale so recorded reasons stay English', () => {
  const saved = { GIT_DIR: process.env.GIT_DIR, LANGUAGE: process.env.LANGUAGE };
  process.env.GIT_DIR = '/elsewhere';
  process.env.LANGUAGE = 'de';
  try {
    const env = evr.gitEnvironment({ GIT_INDEX_FILE: '/tmp/index' });
    assert.equal(env.GIT_DIR, undefined);
    assert.equal(env.LANGUAGE, undefined);
    assert.equal(env.LC_ALL, 'C');
    assert.equal(env.GIT_OPTIONAL_LOCKS, '0');
    assert.equal(env.GIT_INDEX_FILE, '/tmp/index');
  } finally {
    for (const [name, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
  }
});

test('the real index is left untouched by fingerprinting', () => {
  const root = gitRepo();
  fs.writeFileSync(path.join(root, 'untracked.txt'), 'x\n');
  evr.computeTree(root, tempDir('scratch'));
  assert.match(sh(root, 'git status --porcelain'), /^\?\? untracked\.txt/m);
});

test('a nested project root fingerprints its own subtree', () => {
  const root = gitRepo();
  const scratch = tempDir('scratch');
  const top = evr.computeTree(root, scratch).tree;
  const nested = evr.computeTree(path.join(root, 'sub'), scratch).tree;
  assert.match(nested, /^[0-9a-f]{40}/);
  assert.notEqual(nested, top);
  fs.writeFileSync(path.join(root, 'a.txt'), 'outside the nested root\n');
  assert.equal(evr.computeTree(path.join(root, 'sub'), scratch).tree, nested);
});

test('a directory outside git yields no tree id and a reason', () => {
  const result = evr.computeTree(tempDir('plain'), tempDir('scratch'));
  assert.equal(result.tree, null);
  assert.equal(result.reason, 'not a git work tree');
});

test('the untracked bound disables fingerprinting with a reason', () => {
  const root = gitRepo();
  fs.writeFileSync(path.join(root, 'u1.txt'), 'x');
  fs.writeFileSync(path.join(root, 'u2.txt'), 'y');
  const result = evr.computeTree(root, tempDir('scratch'), { ...evr.LIMITS, untrackedMaxFiles: 1 });
  assert.equal(result.tree, null);
  assert.match(result.reason, /more than 1 untracked files/);
});

test('changed paths between two trees are listed', () => {
  const root = gitRepo();
  const scratch = tempDir('scratch');
  const before = evr.computeTree(root, scratch).tree;
  fs.writeFileSync(path.join(root, 'sub', 'b.txt'), 'edited\n');
  const after = evr.computeTree(root, scratch).tree;
  assert.deepEqual(evr.changedPaths(root, before, after), ['sub/b.txt']);
});

test('display strings redact roots, withhold secrets and strip control bytes', () => {
  const root = '/Users/someone/project';
  assert.equal(evr.screen(`cd ${root}/pkg && npm test`, root), 'cd <project>/pkg && npm test');
  assert.equal(evr.screen(`TOKEN=${FAKE_TOKEN} npm test`, root), evr.WITHHELD);
  assert.equal(evr.screen('a\tb`c`\nd', root), "a b'c' d");
  assert.equal(evr.screen('x'.repeat(500), root).length, evr.LIMITS.displayMax);
});

test('shell quoting survives single quotes', () => {
  assert.equal(evr.shellQuote("it's"), "'it'\\''s'");
  assert.equal(sh(tempDir('q'), `printf '%s' ${evr.shellQuote("a 'b' $c")}`), "a 'b' $c");
});

test('the full-suite command resolves from config and refuses a different explicit one', () => {
  assert.deepEqual(evr.resolveCommand('full', null, 'npm test'), { command: 'npm test' });
  assert.deepEqual(evr.resolveCommand('full', 'npm test', 'npm test'), { command: 'npm test' });
  assert.match(evr.resolveCommand('full', 'true', 'npm test').error, /differs from evidence\.fullSuiteCommand/);
  assert.match(evr.resolveCommand('full', null, null).error, /no full-suite command/);
  assert.match(evr.resolveCommand('lint', null, 'npm test').error, /--scope lint requires --cmd/);
  assert.deepEqual(evr.resolveCommand('lint', 'npm run lint', 'npm test'), { command: 'npm run lint' });
  const oversized = 'x'.repeat(evr.LIMITS.maxCommandBytes + 1);
  assert.match(evr.resolveCommand('full', null, oversized).error, /too long/);
  assert.match(evr.resolveCommand('scoped', oversized, null).error, /too long/);
  assert.match(evr.resolveCommand('full', null, 'a\0b').error, /NUL byte/);
});

test('the child environment drops plugin bindings and restores the caller project dir', () => {
  const env = {
    PATH: '/usr/bin',
    ZENSU_SESSION_KEY: SESSION,
    ZENSU_PROJECT_ROOT: '/x',
    CLAUDE_PLUGIN_DATA: '/data',
    CLAUDE_PLUGIN_ROOT: '/root',
    CLAUDE_PROJECT_DIR: '/bound',
    ZENSU_EVR_SCOPE: 'full',
    CLAUDE_CODE_SESSION_ID: 'host',
  };
  assert.deepEqual(evr.childEnvironment(env, '/caller'), { PATH: '/usr/bin', CLAUDE_PROJECT_DIR: '/caller', CLAUDE_CODE_SESSION_ID: 'host' });
  assert.deepEqual(evr.childEnvironment(env, undefined), { PATH: '/usr/bin', CLAUDE_CODE_SESSION_ID: 'host' });
});

test('a green full run records exit 0, prints the tail and a summary, and emits a run-log line', async () => {
  const root = gitRepo();
  const data = pluginData();
  const result = await runIn(root, data, { command: 'echo hello-from-suite' });
  assert.equal(result.code, 0);
  assert.match(result.stdout, /full output: .*\.log/);
  assert.match(result.stdout, /hello-from-suite/);
  assert.match(result.stdout, /zensu evidence-run: scope=full exit=0 .* record=er1_/);
  assert.match(result.line, /^EVIDENCE RUN — scope=full exit=0 .* \| cmd: echo hello-from-suite\n$/);
  const [record] = recordsOf(data);
  assert.equal(record.state, 'completed');
  assert.equal(record.exit_code, 0);
  assert.equal(record.tree_start, record.tree_end);
  assert.match(record.tree_end, /^[0-9a-f]{40}/);
});

test('a red run passes its exit code through', async () => {
  const root = gitRepo();
  const data = pluginData();
  const result = await runIn(root, data, { command: 'echo broken; exit 3' });
  assert.equal(result.code, 3);
  assert.equal(recordsOf(data)[0].exit_code, 3);
  assert.match(result.stdout, /exit=3/);
});

test('pipefail makes a failing pipeline fail', async () => {
  const result = await runIn(gitRepo(), pluginData(), { command: 'false | cat' });
  assert.equal(result.code, 1);
});

test('the default output is the tail and --show all prints everything', async () => {
  const root = gitRepo();
  const lines = 'for i in $(seq 1 20); do echo line-$i; done';
  const tail = await runIn(root, pluginData(), { command: lines, limits: { tailLines: 5 } });
  assert.doesNotMatch(tail.stdout, /line-15\n/);
  assert.match(tail.stdout, /line-16\nline-17\nline-18\nline-19\nline-20\n/);
  const all = await runIn(root, pluginData(), { command: lines, show: 'all', limits: { tailLines: 5 } });
  assert.match(all.stdout, /line-1\n/);
  assert.match(all.stdout, /line-20\n/);
});

test('the child sees no plugin bindings, the caller project dir and the caller cwd', async () => {
  const root = gitRepo();
  const env = { ...process.env, ZENSU_SESSION_KEY: SESSION, CLAUDE_PLUGIN_DATA: '/secret-data', CLAUDE_PROJECT_DIR: '/bound' };
  const result = await runIn(root, pluginData(), {
    scope: 'scoped',
    cwd: path.join(root, 'sub'),
    env,
    callerProjectDir: '/caller-dir',
    command: 'echo "key=${ZENSU_SESSION_KEY-unset} data=${CLAUDE_PLUGIN_DATA-unset} pd=${CLAUDE_PROJECT_DIR-unset}"; pwd',
  });
  assert.equal(result.code, 0);
  assert.match(result.stdout, /key=unset data=unset pd=\/caller-dir/);
  assert.match(result.stdout, /\/sub\n/);
});

test('a scoped run carries no tree id', async () => {
  const data = pluginData();
  await runIn(gitRepo(), data, { scope: 'lint', command: 'true' });
  const [record] = recordsOf(data);
  assert.equal(record.scope, 'lint');
  assert.equal(record.tree_start, null);
  assert.equal(record.tree_end, null);
});

test('a usage error writes no record', async () => {
  const data = pluginData();
  const result = await runIn(gitRepo(), data, { command: null });
  assert.equal(result.code, 2);
  assert.match(result.stderr, /no full-suite command/);
  assert.equal(fs.existsSync(path.join(data, 'evidence-run', 'v1', 'records', SESSION)), false);
});

test('a signal to the runner kills the suite and records an interrupted run', { skip: process.platform === 'win32' }, async () => {
  const root = gitRepo();
  const data = pluginData();
  const transport = tempDir('transport');
  fs.writeFileSync(path.join(transport, 'command'), 'sleep 30');
  const runner = childProcess.spawn(process.execPath, [LIB, 'run'], {
    env: {
      ...process.env,
      ZENSU_EVR_DIR: transport,
      ZENSU_EVR_PLUGIN_DATA: data,
      ZENSU_EVR_SESSION_KEY: SESSION,
      ZENSU_EVR_PROJECT_ROOT: root,
      ZENSU_EVR_SCOPE: 'scoped',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  runner.stdout.on('data', (chunk) => { output += chunk; });
  await new Promise((resolve) => {
    const poll = setInterval(() => {
      if (output.includes('full output:')) { clearInterval(poll); resolve(); }
    }, 20);
  });
  runner.kill('SIGTERM');
  const code = await new Promise((resolve) => runner.once('exit', (exitCode) => resolve(exitCode)));
  assert.equal(code, 143);
  const [record] = recordsOf(data);
  assert.equal(record.state, 'interrupted');
  assert.equal(record.signal, 'SIGTERM');
  assert.equal(record.exit_code, 143);
});

test('a missing record blocks with a runnable remedy', () => {
  const result = verdictFor(gitRepo(), pluginData());
  assert.equal(result.state, 'missing');
  assert.equal(result.passes, false);
  assert.match(result.lines[0], /^FULL SUITE — missing \| no full-suite run is recorded .* \| run: RUNNER --cmd '<your full test command>'$/);
});

test('a green run on the current tree passes', async () => {
  const root = gitRepo();
  const data = pluginData();
  await runIn(root, data, { command: 'true' });
  const result = verdictFor(root, data);
  assert.equal(result.state, 'pass');
  assert.equal(result.passes, true);
  assert.match(result.lines[0], /^FULL SUITE — pass \| exit 0 on the current tree .* cmd: true \| gate: required$/);
});

test('a red newest run blocks as failed and names the command to re-run', async () => {
  const root = gitRepo();
  const data = pluginData();
  await runIn(root, data, { command: 'exit 4' });
  const result = verdictFor(root, data);
  assert.equal(result.state, 'failed');
  assert.match(result.lines[0], /exited 4/);
  assert.match(result.lines[0], /run: RUNNER --cmd 'exit 4'$/);
});

test('an edit after a green run makes the record stale and lists the path', async () => {
  const root = gitRepo();
  const data = pluginData();
  await runIn(root, data, { command: 'true' });
  fs.writeFileSync(path.join(root, 'a.txt'), 'edited after the run\n');
  const result = verdictFor(root, data);
  assert.equal(result.state, 'stale');
  assert.match(result.lines[0], /files changed since: a\.txt/);
});

test('a flaky red-then-green pair on one tree passes with a disclosure', async () => {
  const root = gitRepo();
  const data = pluginData();
  await runIn(root, data, { command: 'exit 1' });
  await runIn(root, data, { command: 'true' });
  const result = verdictFor(root, data);
  assert.equal(result.state, 'pass');
  assert.match(result.lines[1], /flaky: 1 earlier run\(s\) on this same tree did not pass/);
});

test('a suite that edits tracked files is reported as mutated during the run', async () => {
  const root = gitRepo();
  const data = pluginData();
  await runIn(root, data, { command: 'echo rewritten > a.txt' });
  const result = verdictFor(root, data);
  assert.equal(result.state, 'mutated-during-run');
  assert.match(result.lines[0], /the tree changed while the suite ran .*: a\.txt/);
});

test('a live running record blocks as running and a dead one reads as interrupted', () => {
  const root = gitRepo();
  const data = pluginData();
  const locations = evr.storeLocations(data, SESSION);
  const running = baseRecord({
    id: evr.newRecordId(Date.now()),
    project_root: root,
    state: 'running',
    pid: process.pid,
    started_at: new Date().toISOString(),
    finished_at: null,
    duration_ms: null,
    exit_code: null,
  });
  evr.writeRecordAtomic(locations.records, running);
  const live = verdictFor(root, data);
  assert.equal(live.state, 'running');
  assert.match(live.lines[0], /wait for it to finish, then close the chain again .*\| gate: required$/);
  evr.writeRecordAtomic(locations.records, { ...running, pid: deadPid() });
  const dead = verdictFor(root, data);
  assert.equal(dead.state, 'interrupted');
  assert.match(dead.lines[0], /\| run: RUNNER --cmd 'npm test'$/);
});

test('a configured command that differs from the newest run blocks as command-mismatch', async () => {
  const root = gitRepo();
  const data = pluginData();
  await runIn(root, data, { command: 'true' });
  const result = verdictFor(root, data, { configuredCommand: 'npm test' });
  assert.equal(result.state, 'command-mismatch');
  assert.match(result.lines[0], /run: RUNNER$/);
});

test('an unreadable newest record blocks as invalid', async () => {
  const root = gitRepo();
  const data = pluginData();
  await runIn(root, data, { command: 'true' });
  const locations = evr.storeLocations(data, SESSION);
  fs.writeFileSync(path.join(locations.records, `${evr.newRecordId(Date.now() + 60000)}.json`), '{broken');
  const result = verdictFor(root, data);
  assert.equal(result.state, 'invalid');
  assert.match(result.lines[0], /cannot be trusted .*unparseable/);
});

test('a project outside git is not gated and says why', () => {
  const result = verdictFor(tempDir('plain'), pluginData());
  assert.equal(result.state, 'not-applicable');
  assert.equal(result.passes, true);
  assert.match(result.lines[0], /^FULL SUITE — not-applicable \| the project is not a git repository, so no run can be bound to a tree \| gate: required$/);
});

test('a work tree that cannot be fingerprinted passes on exit 0 with a disclosure', async () => {
  const root = gitRepo();
  const data = pluginData();
  await runIn(root, data, { command: 'true' });
  fs.writeFileSync(path.join(root, 'untracked.txt'), 'x\n');
  const result = verdictFor(root, data, { limits: { untrackedMaxFiles: 0 } });
  assert.equal(result.state, 'pass-tree-unverified');
  assert.equal(result.passes, true);
  assert.match(result.lines[0], /more than 0 untracked files\), so freshness is unverified/);
});

test('the escape skips the record check only where the gate applies', () => {
  const inRepo = verdictFor(gitRepo(), pluginData(), { escape: true });
  assert.equal(inRepo.state, 'escaped');
  assert.equal(inRepo.passes, true);
  assert.match(inRepo.lines[0], /^FULL SUITE — escaped \| ZENSU_FULL_SUITE_GATE=off switched this check off, so no run was read \| gate: required$/);
  const outside = verdictFor(tempDir('plain'), pluginData(), { escape: true });
  assert.equal(outside.state, 'not-applicable');
});

test('a git fault in the applicability probe fails closed', () => {
  const vanished = verdictFor(path.join(tempDir('gone'), 'missing'), pluginData());
  assert.equal(vanished.state, 'unavailable');
  assert.equal(vanished.passes, false);
  assert.match(vanished.lines[0], /^FULL SUITE — unavailable \| the evidence store could not be read \(git rev-parse failed: /);
  const unbound = verdictFor('', pluginData());
  assert.equal(unbound.state, 'unavailable');
  assert.match(unbound.lines[0], /no project root is bound/);
  const escapedFault = verdictFor(path.join(tempDir('gone'), 'missing'), pluginData(), { escape: true });
  assert.equal(escapedFault.state, 'escaped');
});

test('advisory mode discloses without blocking and an unknown mode acts as required', () => {
  const root = gitRepo();
  const data = pluginData();
  const advisory = verdictFor(root, data, { gateMode: 'advisory' });
  assert.equal(advisory.passes, true);
  assert.match(advisory.lines[0], /^FULL SUITE — missing \(advisory, not blocking\)/);
  const unknown = verdictFor(root, data, { gateMode: 'sometimes' });
  assert.equal(unknown.passes, false);
  assert.equal(unknown.mode, 'required');
  assert.match(unknown.lines[0], /value 'sometimes' is not recognized .* treated as required/);
});

test('if-stale skips a run whose green record is fresh and runs otherwise', async () => {
  const root = gitRepo();
  const data = pluginData();
  await runIn(root, data, { command: 'true' });
  const skipped = await runIn(root, data, { command: 'true', ifStale: true });
  assert.equal(skipped.code, 0);
  assert.match(skipped.stdout, /skipped \(--if-stale\)/);
  assert.equal(recordsOf(data).length, 1);
  fs.writeFileSync(path.join(root, 'a.txt'), 'edit\n');
  await runIn(root, data, { command: 'true', ifStale: true });
  assert.equal(recordsOf(data).length, 2);
});

test('retention keeps the newest records per session and drops their logs', async () => {
  const root = gitRepo();
  const data = pluginData();
  for (let index = 0; index < 5; index += 1) {
    await runIn(root, data, { scope: 'scoped', command: 'true', limits: { maxRecordsPerSession: 3 } });
  }
  assert.equal(recordsOf(data).length, 3);
  const logs = fs.readdirSync(path.join(data, 'evidence-run', 'v1', 'logs', SESSION));
  assert.equal(logs.length, 3);
});

test('idle sessions are swept and the current one is kept', () => {
  const data = pluginData();
  const current = evr.storeLocations(data, SESSION);
  const other = evr.storeLocations(data, OTHER_SESSION);
  const old = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
  for (const directory of [other.records, other.logs, current.records]) fs.utimesSync(directory, old, old);
  assert.equal(evr.sweepIdleSessions(current, SESSION, evr.LIMITS), 1);
  assert.equal(fs.existsSync(other.records), false);
  assert.equal(fs.existsSync(current.records), true);
});

test('an oversized log keeps its head and tail with a marker', () => {
  const file = path.join(tempDir('log'), 'big.log');
  fs.writeFileSync(file, `${'h'.repeat(100)}${'m'.repeat(1000)}${'t'.repeat(100)}`);
  const result = evr.truncateLogMiddle(file, { ...evr.LIMITS, maxLogBytes: 200 });
  assert.equal(result.truncated, true);
  const text = fs.readFileSync(file, 'utf8');
  assert.ok(text.startsWith('h'.repeat(100)));
  assert.ok(text.endsWith('t'.repeat(100)));
  assert.match(text, /1000 bytes removed from the middle/);
});

test('the tail reader returns the last lines only', () => {
  const file = path.join(tempDir('tail'), 'out.log');
  fs.writeFileSync(file, 'a\nb\nc\nd\n');
  assert.deepEqual(evr.readTail(file, 2, evr.LIMITS), ['c', 'd']);
});

test('the verdict CLI exits 1 on a block and 0 on a pass', async () => {
  const root = gitRepo();
  const data = pluginData();
  const env = {
    ...process.env,
    ZENSU_EVR_PLUGIN_DATA: data,
    ZENSU_EVR_SESSION_KEY: SESSION,
    ZENSU_EVR_PROJECT_ROOT: root,
  };
  const transport = tempDir('transport');
  const stateOf = () => fs.readFileSync(path.join(transport, 'verdict-state'), 'utf8');
  const blocked = childProcess.spawnSync(process.execPath, [LIB, 'verdict'], { env: { ...env, ZENSU_EVR_DIR: transport }, encoding: 'utf8' });
  assert.equal(blocked.status, 1);
  assert.match(blocked.stderr, /FULL SUITE — missing/);
  assert.equal(stateOf(), 'missing');
  const escaped = childProcess.spawnSync(process.execPath, [LIB, 'verdict'], { env: { ...env, ZENSU_EVR_DIR: transport, ZENSU_EVR_ESCAPE: '1' }, encoding: 'utf8' });
  assert.equal(escaped.status, 0);
  assert.equal(stateOf(), 'escaped');
  await runIn(root, data, { command: 'true' });
  const passed = childProcess.spawnSync(process.execPath, [LIB, 'verdict'], { env: { ...env, ZENSU_EVR_DIR: transport }, encoding: 'utf8' });
  assert.equal(passed.status, 0);
  assert.match(passed.stderr, /FULL SUITE — pass/);
  assert.equal(stateOf(), 'pass');
  const unavailable = childProcess.spawnSync(process.execPath, [LIB, 'verdict'], { env: { ...env, ZENSU_EVR_PROJECT_ROOT: path.join(root, 'missing') }, encoding: 'utf8' });
  assert.equal(unavailable.status, 2);
});
