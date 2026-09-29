'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');

const PLUGIN_ROOT = fs.realpathSync.native(path.resolve(__dirname, '..', '..'));
const core = require(path.join(PLUGIN_ROOT, 'hooks', 'lib', 'session-control-core-v1.js'));
const reanchor = require(path.join(PLUGIN_ROOT, 'hooks', 'lib', 'session-reanchor-v1.js'));
const worktreeKeep = require(path.join(PLUGIN_ROOT, 'hooks', 'lib', 'worktree-keep-v1.js'));
const sweep = require(path.join(PLUGIN_ROOT, 'hooks', 'lib', 'review-evidence-sweep-v1.js'));

const R = reanchor.REANCHOR_REFUSALS;

function writeRuntime(root, version) {
  const files = {
    '.claude-plugin/plugin.json': JSON.stringify({ name: 'zensu', version }),
    'hooks/lib/runtime.js': 'module.exports = 1;\n',
    'agents/reviewer.md': '# reviewer\n',
    'skills/sample/SKILL.md': '# skill\n',
    'docs/runtime-guide.md': '# runtime guide\n',
    'templates/review.md': '# review template\n',
    'README.md': '# plugin readme\n',
    'CHANGELOG.md': '# plugin changelog\n',
    'LICENSE': 'test license\n',
  };
  for (const [relative, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(root, relative)), { recursive: true });
    fs.writeFileSync(path.join(root, relative), content);
  }
  return root;
}

function makeRuntimeRoot() {
  const base = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'reanchor-runtime-')));
  return { base, root: writeRuntime(path.join(base, 'zensu', '9.8.7'), '9.8.7') };
}

const RUNTIME = makeRuntimeRoot();
const RUNTIME_ROOT = RUNTIME.root;
test.after(() => fs.rmSync(RUNTIME.base, { recursive: true, force: true }));
const GIT_ENV = {
  ...worktreeKeep.gitEnvironment(process.env),
  GIT_AUTHOR_NAME: 'reanchor-test',
  GIT_AUTHOR_EMAIL: 'reanchor@example.invalid',
  GIT_COMMITTER_NAME: 'reanchor-test',
  GIT_COMMITTER_EMAIL: 'reanchor@example.invalid',
};

function git(cwd, args) {
  return execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], env: GIT_ENV });
}

const AUTOPILOT_ENV = Object.fromEntries(Object.entries(process.env)
  .filter(([name]) => !['ZENSU_PROJECT_ROOT', 'ZENSU_SESSION_KEY', 'ZENSU_SESSION_CONTEXT', 'CLAUDE_ENV_FILE'].includes(name)));

function autopilot(root, ...args) {
  return spawnSync('bash', ['-c', 'source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-autopilot-state.sh" && "$@"', 'reanchor-unit', ...args], {
    encoding: 'utf8',
    stdio: ['ignore', 'ignore', 'ignore'],
    env: { ...AUTOPILOT_ENV, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT, CLAUDE_PROJECT_DIR: root },
  }).status;
}

function deadPid() {
  return spawnSync(process.execPath, ['-e', '']).pid;
}

function anchorRecord(key, root, overrides) {
  const now = Date.now();
  return {
    schemaVersion: 1,
    sessionKey: key,
    worktreeRoot: root,
    branch: null,
    head: null,
    recordedAt: now,
    lastSeenAt: now,
    drift: null,
    endedAt: null,
    ...overrides,
  };
}

function mint(f, sessionId, projectRoot, pluginRoot) {
  core.registerContext({
    recordsDir: f.recordsDir,
    host: 'claude',
    sessionId,
    projectRoot,
    pluginRoot: pluginRoot || RUNTIME_ROOT,
    pluginData: f.pluginData,
  });
  core.initializeWorkflowState({ projectRoot, sessionId });
}

function fixture(t) {
  const base = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'reanchor-unit-')));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const repo = path.join(base, 'repo');
  fs.mkdirSync(repo);
  git(repo, ['init', '-q', '-b', 'main']);
  fs.writeFileSync(path.join(repo, '.gitignore'), '.claude/\n.zensu/\n');
  git(repo, ['add', '.gitignore']);
  git(repo, ['commit', '-q', '-m', 'seed']);
  const worktree = (name) => {
    const dir = path.join(repo, '.claude', 'worktrees', name);
    git(repo, ['worktree', 'add', '-q', '-b', `claude/${name}`, dir]);
    return fs.realpathSync.native(dir);
  };
  const a = worktree('a');
  const b = worktree('b');
  const pluginData = path.join(base, 'plugin-data');
  fs.mkdirSync(pluginData, { mode: 0o700 });
  const configDir = path.join(base, 'config');
  fs.mkdirSync(path.join(configDir, 'sessions'), { recursive: true });
  const sessionId = `reanchor-unit-${path.basename(base)}`;
  const f = {
    base,
    repo: fs.realpathSync.native(repo),
    a,
    b,
    worktree,
    pluginData: fs.realpathSync.native(pluginData),
    configDir,
    sessionId,
    key: core.sessionKey(sessionId),
  };
  f.recordsDir = path.join(f.pluginData, 'session-control', 'v1', 'records');
  f.recordFile = path.join(f.recordsDir, `${f.key}.json`);
  f.register = (name, entry) => fs.writeFileSync(path.join(configDir, 'sessions', name), JSON.stringify(entry));
  f.request = (overrides) => ({
    recordsDir: f.recordsDir,
    sessionId,
    host: 'claude',
    pluginData: f.pluginData,
    executingPluginRoot: RUNTIME_ROOT,
    targetDirectory: b,
    environment: { CLAUDE_CONFIG_DIR: configDir },
    worktreeKeep: false,
    worktreeKeepIdleHours: 72,
    ...overrides,
  });
  mint(f, sessionId, a);
  f.register(`${process.pid}.json`, { pid: process.pid, sessionId, cwd: b });
  return f;
}

function historyPhases(projectRoot, sessionId) {
  const state = core.readWorkflowState({ projectRoot, sessionId });
  return (state.history || []).map((entry) => entry.phase);
}

test('worktreeIdentity names the worktree top and the shared common directory, and null outside git', (t) => {
  const f = fixture(t);
  const sub = path.join(f.b, 'deep', 'er');
  fs.mkdirSync(sub, { recursive: true });
  const fromB = reanchor.worktreeIdentity(sub);
  const fromA = reanchor.worktreeIdentity(f.a);
  assert.equal(fromB.top, f.b);
  assert.equal(fromA.top, f.a);
  assert.equal(fromB.commonDir, fromA.commonDir);
  assert.equal(fromB.commonDir, fs.realpathSync.native(path.join(f.repo, '.git')));
  const plain = path.join(f.base, 'plain');
  fs.mkdirSync(plain);
  assert.equal(reanchor.worktreeIdentity(plain), null);
  assert.equal(reanchor.worktreeIdentity(path.join(f.base, 'absent')), null);
});

test('registeredWorktrees lists the main and linked worktrees and marks a deleted one prunable', (t) => {
  const f = fixture(t);
  const gone = f.worktree('gone');
  fs.rmSync(gone, { recursive: true, force: true });
  const listed = reanchor.registeredWorktrees(f.a);
  const byPath = new Map(listed.map((entry) => [entry.path, entry]));
  assert.equal(byPath.get(f.repo).prunable, false);
  assert.equal(byPath.get(f.a).canonical, f.a);
  assert.equal(byPath.get(f.b).prunable, false);
  assert.equal(byPath.get(gone).prunable, true);
  assert.equal(byPath.get(gone).canonical, null);
});

test('owningWorktree picks the deepest registered worktree that contains a path', (t) => {
  const f = fixture(t);
  const listed = reanchor.registeredWorktrees(f.a);
  assert.equal(reanchor.owningWorktree(listed, path.join(f.b, 'src', 'x.swift')), f.b);
  assert.equal(reanchor.owningWorktree(listed, path.join(f.repo, 'README.md')), f.repo);
  assert.equal(reanchor.owningWorktree(listed, f.base), null);
});

test('a sibling worktree of the same repository is movable and the report writes nothing', (t) => {
  const f = fixture(t);
  const before = fs.readFileSync(f.recordFile, 'utf8');
  const verdict = reanchor.reanchorVerdict(f.request());
  assert.equal(verdict.ok, true, JSON.stringify(verdict));
  assert.equal(verdict.recordedRoot, f.a);
  assert.equal(verdict.targetRoot, f.b);
  assert.equal(verdict.targetDocument, 'missing');
  assert.equal(fs.readFileSync(f.recordFile, 'utf8'), before);
  assert.equal(fs.existsSync(path.join(f.b, '.zensu')), false);
});

test('a subdirectory of the sibling worktree resolves to that worktree top-level', (t) => {
  const f = fixture(t);
  const sub = path.join(f.b, 'Sources', 'Logging');
  fs.mkdirSync(sub, { recursive: true });
  const verdict = reanchor.reanchorVerdict(f.request({ targetDirectory: sub }));
  assert.equal(verdict.ok, true, JSON.stringify(verdict));
  assert.equal(verdict.targetRoot, f.b);
  assert.equal(verdict.requestedDirectory, fs.realpathSync.native(sub));
});

test('the recorded worktree itself refuses as already-anchored', (t) => {
  const f = fixture(t);
  assert.equal(reanchor.reanchorVerdict(f.request({ targetDirectory: f.a })).reason, R.ALREADY_ANCHORED);
});

test('a worktree of another repository refuses as different-repository', (t) => {
  const f = fixture(t);
  const other = path.join(f.base, 'other');
  fs.mkdirSync(other);
  git(other, ['init', '-q', '-b', 'main']);
  git(other, ['commit', '-q', '--allow-empty', '-m', 'seed']);
  const verdict = reanchor.reanchorVerdict(f.request({ targetDirectory: other }));
  assert.equal(verdict.reason, R.DIFFERENT_REPOSITORY);
});

test('a directory outside any git worktree refuses as target-not-in-a-worktree', (t) => {
  const f = fixture(t);
  const plain = path.join(f.base, 'plain');
  fs.mkdirSync(plain);
  assert.equal(reanchor.reanchorVerdict(f.request({ targetDirectory: plain })).reason, R.TARGET_NOT_IN_WORKTREE);
  assert.equal(reanchor.reanchorVerdict(f.request({ targetDirectory: undefined })).reason, R.TARGET_NOT_IN_WORKTREE);
});

test('a directory borrowing another worktree gitdir is not a registered worktree', (t) => {
  const f = fixture(t);
  const spoof = path.join(f.base, 'spoof');
  fs.mkdirSync(spoof);
  const admin = git(f.b, ['rev-parse', '--path-format=absolute', '--git-dir']).trim();
  fs.writeFileSync(path.join(spoof, '.git'), `gitdir: ${admin}\n`);
  assert.equal(reanchor.reanchorVerdict(f.request({ targetDirectory: spoof })).reason, R.TARGET_NOT_REGISTERED);
});

test('a live foreign session working in the target claims it', (t) => {
  const f = fixture(t);
  f.register('900001.json', { pid: process.pid, sessionId: 'foreign-cwd', cwd: path.join(f.b, 'src') });
  const verdict = reanchor.reanchorVerdict(f.request());
  assert.equal(verdict.reason, R.CLAIMED);
  assert.match(verdict.detail.join('\n'), /working directory/);
});

test('a live foreign session whose recorded project root is the target claims it', (t) => {
  const f = fixture(t);
  mint(f, 'foreign-recorded', f.b);
  f.register('900002.json', { pid: process.pid, sessionId: 'foreign-recorded', cwd: f.repo });
  const verdict = reanchor.reanchorVerdict(f.request());
  assert.equal(verdict.reason, R.CLAIMED);
  assert.match(verdict.detail.join('\n'), /recorded project root/);
});

test('a worktree that contains the recorded root refuses instead of widening the anchor', (t) => {
  const f = fixture(t);
  const sub = path.join(f.b, 'Sources');
  fs.mkdirSync(sub);
  mint(f, 'nested-root', sub);
  f.register('900003.json', { pid: process.pid, sessionId: 'nested-root', cwd: sub });
  const widened = reanchor.reanchorVerdict(f.request({ sessionId: 'nested-root', targetDirectory: f.b }));
  assert.equal(widened.reason, R.TARGET_CONTAINS_RECORDED_ROOT);
  assert.equal(reanchor.reanchorVerdict(f.request({ targetDirectory: f.repo })).reason, R.TARGET_CONTAINS_RECORDED_ROOT);
});

test('a checkout that contains other registered worktrees refuses and names each of them', (t) => {
  const f = fixture(t);
  const outside = path.join(f.base, 'outside');
  git(f.repo, ['worktree', 'add', '-q', '-b', 'claude/outside', outside]);
  const outsideRoot = fs.realpathSync.native(outside);
  mint(f, 'outside-root', outsideRoot);
  f.register('900013.json', { pid: process.pid, sessionId: 'outside-root', cwd: outsideRoot });
  const verdict = reanchor.reanchorVerdict(f.request({ sessionId: 'outside-root', targetDirectory: f.repo }));
  assert.equal(verdict.reason, R.TARGET_CONTAINS_WORKTREES);
  assert.deepEqual([...verdict.detail].sort(), [f.a, f.b].sort());
});

test('a live foreign session in the main checkout does not claim a nested sibling worktree', (t) => {
  const f = fixture(t);
  f.register('900004.json', { pid: process.pid, sessionId: 'foreign-main', cwd: f.repo });
  assert.equal(reanchor.reanchorVerdict(f.request()).ok, true);
});

test('a registry entry whose process has exited claims nothing', (t) => {
  const f = fixture(t);
  f.register('900005.json', { pid: deadPid(), sessionId: 'foreign-dead', cwd: f.b });
  assert.equal(reanchor.reanchorVerdict(f.request()).ok, true);
});

test('another session live worktree-keep anchor in the target claims it', (t) => {
  const f = fixture(t);
  const foreignKey = core.sessionKey('foreign-anchor');
  assert.equal(worktreeKeep.writeAnchor(f.b, foreignKey, anchorRecord(foreignKey, f.b)).ok, true);
  const verdict = reanchor.reanchorVerdict(f.request());
  assert.equal(verdict.reason, R.CLAIMED);
  assert.match(verdict.detail.join('\n'), /live worktree-keep anchor/);
});

test('another session anchor this build cannot validate claims the target too', (t) => {
  const f = fixture(t);
  const foreignKey = core.sessionKey('foreign-garbled');
  fs.mkdirSync(path.join(f.b, '.zensu', 'state'), { recursive: true });
  fs.writeFileSync(path.join(f.b, '.zensu', 'state', `worktree-anchor-${foreignKey}.json`), 'not json');
  const verdict = reanchor.reanchorVerdict(f.request());
  assert.equal(verdict.reason, R.CLAIMED);
  assert.match(verdict.detail.join('\n'), /cannot validate/);
});

test('an ended foreign anchor and this session own anchor claim nothing', (t) => {
  const f = fixture(t);
  const foreignKey = core.sessionKey('foreign-ended');
  const ended = anchorRecord(foreignKey, f.b, { endedAt: Date.now() });
  assert.equal(worktreeKeep.writeAnchor(f.b, foreignKey, ended).ok, true);
  assert.equal(worktreeKeep.writeAnchor(f.b, f.key, anchorRecord(f.key, f.b)).ok, true);
  assert.equal(reanchor.reanchorVerdict(f.request()).ok, true);
});

test('a live registry entry without a working directory fails closed', (t) => {
  const f = fixture(t);
  f.register('900014.json', { pid: process.pid, sessionId: 'foreign-no-cwd' });
  const verdict = reanchor.reanchorVerdict(f.request());
  assert.equal(verdict.reason, R.LIVE_SESSIONS_UNVERIFIABLE);
  assert.match(verdict.detail.join('\n'), /names no working directory/);
});

test('worktree-keep anchors that cannot be listed fail closed', (t) => {
  const f = fixture(t);
  t.mock.method(worktreeKeep, 'listAnchors', () => ({ ok: false, reason: 'EACCES', live: [], stale: [], reapable: [], rejected: [] }));
  const verdict = reanchor.reanchorVerdict(f.request());
  assert.equal(verdict.reason, R.LIVE_SESSIONS_UNVERIFIABLE);
  assert.match(verdict.detail.join('\n'), /cannot be listed \(EACCES\)/);
});

test('a live-session registry with more than 1024 entries fails closed', (t) => {
  const f = fixture(t);
  for (let index = 0; index < 1024; index += 1) {
    fs.writeFileSync(path.join(f.configDir, 'sessions', `${800000 + index}.json`), '{}');
  }
  const verdict = reanchor.reanchorVerdict(f.request());
  assert.equal(verdict.reason, R.LIVE_SESSIONS_UNVERIFIABLE);
  assert.match(verdict.detail.join('\n'), /holds more than 1024 entries/);
});

test('a missing live-session registry fails closed as live-sessions-unverifiable', (t) => {
  const f = fixture(t);
  const verdict = reanchor.reanchorVerdict(f.request({ environment: { CLAUDE_CONFIG_DIR: path.join(f.base, 'none') } }));
  assert.equal(verdict.reason, R.LIVE_SESSIONS_UNVERIFIABLE);
});

test('a registry that does not list this session fails closed', (t) => {
  const f = fixture(t);
  fs.rmSync(path.join(f.configDir, 'sessions', `${process.pid}.json`));
  const verdict = reanchor.reanchorVerdict(f.request());
  assert.equal(verdict.reason, R.LIVE_SESSIONS_UNVERIFIABLE);
  assert.match(verdict.detail.join('\n'), /this session is not in the live-session registry/);
});

test('an unreadable registry entry fails closed while its pid lives and is ignored once it is dead', (t) => {
  const f = fixture(t);
  f.register(`${deadPid()}.json`, 'garbled');
  fs.writeFileSync(path.join(f.configDir, 'sessions', `${deadPid()}.json`), '{not json');
  assert.equal(reanchor.reanchorVerdict(f.request()).ok, true);
  fs.writeFileSync(path.join(f.configDir, 'sessions', `${process.ppid}.json`), '{not json');
  const verdict = reanchor.reanchorVerdict(f.request());
  assert.equal(verdict.reason, R.LIVE_SESSIONS_UNVERIFIABLE);
  assert.match(verdict.detail.join('\n'), /cannot be read/);
});

test('a live foreign session whose record cannot be read fails closed', (t) => {
  const f = fixture(t);
  const foreignId = 'foreign-broken-record';
  fs.writeFileSync(path.join(f.recordsDir, `${core.sessionKey(foreignId)}.json`), '{broken');
  f.register('900006.json', { pid: process.pid, sessionId: foreignId, cwd: f.repo });
  const verdict = reanchor.reanchorVerdict(f.request());
  assert.equal(verdict.reason, R.LIVE_SESSIONS_UNVERIFIABLE);
  assert.match(verdict.detail.join('\n'), /record of live session/);
});

test('open work under the recorded root refuses as workflow-in-progress until the chain reaches its terminus', (t) => {
  const f = fixture(t);
  const arm = (mutation) => core.mutateWorkflowState({
    projectRoot: f.a,
    sessionId: f.sessionId,
    workflowState: 'test_state',
    event: 'test-event',
  }, (state) => { mutation(state); return state; });
  arm((state) => { state.active = true; state.chainDone = false; });
  const armed = reanchor.reanchorVerdict(f.request());
  assert.equal(armed.reason, R.WORKFLOW_IN_PROGRESS);
  assert.match(armed.detail.join('\n'), /armed review chain/);
  arm((state) => { state.chainDone = true; });
  assert.equal(reanchor.reanchorVerdict(f.request()).ok, true);
});

test('workflowInProgress names every kind of open work and nothing for an idle or finished document', () => {
  assert.equal(reanchor.workflowInProgress({ active: false }), '');
  assert.equal(reanchor.workflowInProgress({ active: true, chainDone: true }), '');
  assert.match(reanchor.workflowInProgress({ active: true, chainDone: false }), /armed review chain/);
  assert.match(reanchor.workflowInProgress({ workflowActive: true }), /skill workflow/);
  assert.match(reanchor.workflowInProgress({ autopilotRunId: 'run-1' }), /Autopilot/);
  assert.match(reanchor.workflowInProgress({ deferredReviewClaim: 'dc_x' }), /deferred review/);
  assert.match(reanchor.workflowInProgress({ reviewRearm: {} }), /review rearm/);
  assert.equal(reanchor.workflowInProgress({ autopilotRunId: '', deferredReviewClaim: '' }), '');
});

test('an open Autopilot run this session owns refuses although no chain links it, and a cancelled one does not', (t) => {
  const f = fixture(t);
  assert.equal(autopilot(f.a, 'autopilot_begin_run', 'unit-open-run', f.key, f.a), 0);
  const open = reanchor.reanchorVerdict(f.request());
  assert.equal(open.reason, R.WORKFLOW_IN_PROGRESS);
  assert.match(open.detail.join('\n'), /an Autopilot run this session owns \(unit-open-run, stage PLANNING\)/);
  assert.equal(autopilot(f.a, 'autopilot_apply_event', 'unit-open-run', 'unit-cancel', 'CANCEL', '{}', f.a), 0);
  assert.equal(reanchor.reanchorVerdict(f.request()).ok, true);
});

test('an Autopilot run another session owns under the recorded root is not this session\'s open work', (t) => {
  const f = fixture(t);
  assert.equal(autopilot(f.a, 'autopilot_begin_run', 'unit-foreign-run', core.sessionKey('foreign-autopilot'), f.a), 0);
  assert.equal(reanchor.reanchorVerdict(f.request()).ok, true);
});

test('Autopilot state that cannot be read cleanly fails closed', (t) => {
  const f = fixture(t);
  const noShell = reanchor.reanchorVerdict(f.request({ bashPath: path.join(f.base, 'no-such-bash') }));
  assert.equal(noShell.reason, R.AUTOPILOT_UNVERIFIABLE);
  assert.match(noShell.detail.join('\n'), /did not finish/);
  assert.equal(autopilot(f.a, 'autopilot_begin_run', 'unit-orphan-run', f.key, f.a), 0);
  const stateDir = path.join(f.a, '.zensu', 'state');
  for (const name of fs.readdirSync(stateDir).filter((entry) => entry.startsWith('autopilot-active-'))) {
    fs.rmSync(path.join(stateDir, name));
  }
  const orphan = reanchor.reanchorVerdict(f.request());
  assert.equal(orphan.reason, R.AUTOPILOT_UNVERIFIABLE);
  assert.match(orphan.detail.join('\n'), /answered 2/);
});

test('an Autopilot lease the reader cannot take refuses instead of reading as no run', (t) => {
  const f = fixture(t);
  assert.equal(autopilot(f.a, 'autopilot_begin_run', 'unit-leased-run', f.key, f.a), 0);
  const stateDir = path.join(f.a, '.zensu', 'state');
  const binding = { lockDirectory: stateDir, resourcePath: path.join(stateDir, 'autopilot'), ownerPid: process.pid };
  const lease = core.acquireExternalProcessLock(binding);
  let verdict;
  try {
    verdict = reanchor.reanchorVerdict(f.request());
  } finally {
    core.releaseExternalProcessLock({ ...binding, token: lease.token });
  }
  assert.equal(verdict.reason, R.AUTOPILOT_UNVERIFIABLE, JSON.stringify(verdict));
  assert.match(verdict.detail.join('\n'), /answered 5 \(the Autopilot lock or state storage could not be read\)/);
  assert.equal(reanchor.reanchorVerdict(f.request()).reason, R.WORKFLOW_IN_PROGRESS);
});

test('an Autopilot reader that prints no run or cannot load its library fails closed', (t) => {
  const f = fixture(t);
  const stub = (name, body) => {
    const file = path.join(f.base, name);
    fs.writeFileSync(file, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
    return file;
  };
  for (const body of ['exit 0', `printf '%s' '{"stage":"PLANNING"}'`, `printf '%s' 'not json'`]) {
    const verdict = reanchor.reanchorVerdict(f.request({ bashPath: stub(`shell-${crypto.randomUUID()}`, body) }));
    assert.equal(verdict.reason, R.AUTOPILOT_UNVERIFIABLE, body);
    assert.match(verdict.detail.join('\n'), /printed no run/, body);
  }
  const unloaded = reanchor.reanchorVerdict(f.request({ bashPath: stub('unloaded-shell', 'exit 97') }));
  assert.equal(unloaded.reason, R.AUTOPILOT_UNVERIFIABLE);
  assert.match(unloaded.detail.join('\n'), /answered 97 \(the Autopilot state library did not load\)/);
});

test('a BASH_ENV file cannot turn an open Autopilot run of this session into no run', (t) => {
  const f = fixture(t);
  assert.equal(autopilot(f.a, 'autopilot_begin_run', 'unit-bash-env-run', f.key, f.a), 0);
  const bashEnv = path.join(f.base, 'bash-env.sh');
  fs.writeFileSync(bashEnv, 'exit 1\n');
  const previous = process.env.BASH_ENV;
  process.env.BASH_ENV = bashEnv;
  t.after(() => {
    if (previous === undefined) delete process.env.BASH_ENV;
    else process.env.BASH_ENV = previous;
  });
  const verdict = reanchor.reanchorVerdict(f.request());
  assert.equal(verdict.reason, R.WORKFLOW_IN_PROGRESS, JSON.stringify(verdict));
});

test('a cheap refusal is never hidden behind the Autopilot rung', (t) => {
  const f = fixture(t);
  const noShell = path.join(f.base, 'no-such-bash');
  assert.equal(reanchor.reanchorVerdict(f.request({ bashPath: noShell, targetDirectory: f.a })).reason, R.ALREADY_ANCHORED);
  assert.equal(reanchor.reanchorVerdict(f.request({ bashPath: noShell, targetDirectory: f.repo })).reason, R.TARGET_CONTAINS_RECORDED_ROOT);
  const plain = path.join(f.base, 'plain');
  fs.mkdirSync(plain);
  assert.equal(reanchor.reanchorVerdict(f.request({ bashPath: noShell, targetDirectory: plain })).reason, R.TARGET_NOT_IN_WORKTREE);
  assert.equal(reanchor.reanchorVerdict(f.request({ bashPath: noShell })).reason, R.AUTOPILOT_UNVERIFIABLE);
});

test('a missing workflow document under the recorded root refuses as workflow-document-unusable', (t) => {
  const f = fixture(t);
  fs.rmSync(core.adoptionWorkflowStatePath(f.a, f.sessionId));
  assert.equal(reanchor.reanchorVerdict(f.request()).reason, R.WORKFLOW_UNUSABLE);
});

test('an unsafe workflow document for this session under the target refuses and is left alone', (t) => {
  const f = fixture(t);
  const target = core.adoptionWorkflowStatePath(f.b, f.sessionId);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.symlinkSync(path.join(f.base, 'elsewhere.json'), target);
  assert.equal(reanchor.reanchorVerdict(f.request()).reason, R.TARGET_WORKFLOW_UNUSABLE);
  assert.equal(fs.lstatSync(target).isSymbolicLink(), true);
});

test('a vanished recorded root refuses as recorded-root-missing', (t) => {
  const f = fixture(t);
  const d = f.worktree('d');
  mint(f, 'vanished-root', d);
  fs.rmSync(d, { recursive: true, force: true });
  const verdict = reanchor.reanchorVerdict(f.request({ sessionId: 'vanished-root' }));
  assert.equal(verdict.reason, R.RECORDED_ROOT_MISSING);
  assert.match(reanchor.REANCHOR_REMEDY[verdict.reason], /--restore-root/);
});

test('a recorded root outside any git worktree refuses as recorded-root-not-in-a-worktree', (t) => {
  const f = fixture(t);
  const plain = fs.realpathSync.native(fs.mkdtempSync(path.join(f.base, 'plain-')));
  mint(f, 'plain-root', plain);
  f.register('900007.json', { pid: process.pid, sessionId: 'plain-root', cwd: f.b });
  const verdict = reanchor.reanchorVerdict(f.request({ sessionId: 'plain-root' }));
  assert.equal(verdict.reason, R.RECORDED_ROOT_NOT_IN_WORKTREE);
});

test('a foreign plugin-data store and a runtime that does not serve the record both refuse', (t) => {
  const f = fixture(t);
  const otherData = path.join(f.base, 'other-data');
  fs.mkdirSync(otherData, { mode: 0o700 });
  assert.equal(reanchor.reanchorVerdict(f.request({ pluginData: otherData })).reason, R.PLUGIN_DATA);
  assert.equal(reanchor.reanchorVerdict(f.request({ executingPluginRoot: f.base })).reason, R.NOT_SERVED);
  assert.match(reanchor.REANCHOR_REMEDY[R.NOT_SERVED], /\/zensu:adopt-session first/);
});

test('a record minted by a pruned installation refuses as not served', (t) => {
  const f = fixture(t);
  const pruned = writeRuntime(path.join(RUNTIME.base, 'zensu', `9.8.6-${path.basename(f.base)}`), '9.8.6');
  mint(f, 'pruned-minter', f.a, pruned);
  f.register('900015.json', { pid: process.pid, sessionId: 'pruned-minter', cwd: f.b });
  fs.rmSync(pruned, { recursive: true, force: true });
  const verdict = reanchor.reanchorVerdict(f.request({ sessionId: 'pruned-minter' }));
  assert.equal(verdict.reason, R.NOT_SERVED);
});

test('an unreadable record refuses as record-unreadable', (t) => {
  const f = fixture(t);
  fs.writeFileSync(f.recordFile, '{}');
  assert.equal(reanchor.reanchorVerdict(f.request()).reason, R.RECORD_UNREADABLE);
});

test('performReanchor moves the anchor, keeps every other record field and records provenance on both sides', (t) => {
  const f = fixture(t);
  const before = JSON.parse(fs.readFileSync(f.recordFile, 'utf8'));
  const beforeBytes = fs.readFileSync(f.recordFile, 'utf8');
  const outcome = reanchor.performReanchor(f.request(), { now: () => Date.parse('2026-09-29T12:00:00.000Z') });
  assert.equal(outcome.ok, true, JSON.stringify(outcome));
  const after = JSON.parse(fs.readFileSync(f.recordFile, 'utf8'));
  assert.equal(after.project_root, f.b);
  assert.deepEqual({ ...after, project_root: before.project_root }, before);
  assert.equal(outcome.supersededFile, path.join(f.recordsDir, `${f.key}.superseded-reanchor-20260929T120000000Z.json`));
  assert.equal(fs.readFileSync(outcome.supersededFile, 'utf8'), beforeBytes);
  assert.equal(outcome.documentCreated, true);
  assert.equal(outcome.provenance, 'recorded');
  assert.equal(outcome.previousProvenance, 'recorded');
  assert.ok(historyPhases(f.b, f.sessionId).includes(reanchor.REANCHOR_HISTORY_PHASE));
  assert.ok(historyPhases(f.a, f.sessionId).includes(reanchor.REANCHOR_HISTORY_PHASE));
  const entry = core.readWorkflowState({ projectRoot: f.b, sessionId: f.sessionId }).history
    .find((item) => item.phase === reanchor.REANCHOR_HISTORY_PHASE);
  assert.equal(entry.reason, `${reanchor.REANCHOR_HISTORY_REASON_PREFIX}${f.a} -> ${f.b}`);
  assert.equal(core.readContext({ recordsDir: f.recordsDir, sessionId: f.sessionId, expectedHost: 'claude' }).project_root, f.b);
  assert.equal(outcome.keep.state, 'disabled');
});

test('performReanchor derives its verdict inside the repository lock and then the session lock', (t) => {
  const f = fixture(t);
  const original = core.withFileLock;
  const keys = [];
  t.mock.method(core, 'withFileLock', (directory, key, callback) => original(directory, key, () => {
    keys.push(key);
    if (key === f.key) f.register('900016.json', { pid: process.pid, sessionId: 'foreign-inside-lock', cwd: f.b });
    return callback();
  }));
  const beforeBytes = fs.readFileSync(f.recordFile, 'utf8');
  const outcome = reanchor.performReanchor(f.request());
  assert.equal(outcome.ok, false);
  assert.equal(outcome.verdict.reason, R.CLAIMED);
  const commonDir = fs.realpathSync.native(path.join(f.repo, '.git'));
  assert.deepEqual(keys, [`reanchor-${crypto.createHash('sha256').update(commonDir).digest('hex')}`, f.key]);
  assert.equal(fs.readFileSync(f.recordFile, 'utf8'), beforeBytes);
});

test('performReanchor creates the missing target document before it swaps the record', (t) => {
  const f = fixture(t);
  const order = [];
  const initialize = core.initializeWorkflowStateDetailed;
  const supersede = core.supersedeContextRecord;
  t.mock.method(core, 'initializeWorkflowStateDetailed', (options) => { order.push('document'); return initialize(options); });
  t.mock.method(core, 'supersedeContextRecord', (...args) => { order.push('record'); return supersede(...args); });
  const outcome = reanchor.performReanchor(f.request());
  assert.equal(outcome.ok, true, JSON.stringify(outcome));
  assert.deepEqual(order, ['document', 'record']);
});

test('performReanchor refuses to write a record that names anything but the verified worktree', (t) => {
  const f = fixture(t);
  const build = core.buildContext;
  t.mock.method(core, 'buildContext', (options) => ({ ...build(options), project_root: f.a }));
  const beforeBytes = fs.readFileSync(f.recordFile, 'utf8');
  const outcome = reanchor.performReanchor(f.request());
  assert.equal(outcome.ok, false);
  assert.equal(outcome.failed, true);
  assert.match(outcome.cause, /different directory than the verified worktree/);
  assert.equal(fs.readFileSync(f.recordFile, 'utf8'), beforeBytes);
  assert.deepEqual(fs.readdirSync(f.recordsDir).filter((name) => name.includes('superseded')), []);
});

test('a failure after the swap is reported by its own row and does not undo the move', (t) => {
  const f = fixture(t);
  t.mock.method(core, 'mutateWorkflowState', () => { throw new Error('history unavailable'); });
  t.mock.method(worktreeKeep, 'run', () => { throw new Error('keep unavailable'); });
  const outcome = reanchor.performReanchor(f.request({ worktreeKeep: true }));
  assert.equal(outcome.ok, true, JSON.stringify(outcome));
  assert.equal(outcome.provenance, 'unavailable');
  assert.equal(outcome.previousProvenance, 'unavailable');
  assert.match(outcome.provenanceCause, /history unavailable/);
  assert.equal(outcome.keep.state, 'fault');
  assert.equal(outcome.keep.faults.length, 2);
  assert.equal(JSON.parse(fs.readFileSync(f.recordFile, 'utf8')).project_root, f.b);
  const rendered = reanchor.renderReanchorOutcome(outcome);
  assert.equal(rendered.code, 0);
  assert.match(rendered.text, /WARNING: the move succeeded but a provenance entry could not be written/);
  assert.equal((rendered.text.match(/^  keep fault +: .*keep unavailable/gm) || []).length, 2);
});

test('an intact target document is reused, and a second move takes the anchor back', (t) => {
  const f = fixture(t);
  core.initializeWorkflowState({ projectRoot: f.b, sessionId: f.sessionId });
  const verdict = reanchor.reanchorVerdict(f.request());
  assert.equal(verdict.ok, true, JSON.stringify(verdict));
  assert.equal(verdict.targetDocument, 'present');
  const first = reanchor.performReanchor(f.request(), { now: () => Date.parse('2026-09-29T12:00:00.000Z') });
  assert.equal(first.ok, true, JSON.stringify(first));
  assert.equal(first.documentCreated, false);
  const back = reanchor.performReanchor(f.request({ targetDirectory: f.a }), { now: () => Date.parse('2026-09-29T12:05:00.000Z') });
  assert.equal(back.ok, true, JSON.stringify(back));
  assert.equal(back.previousRoot, f.b);
  assert.equal(back.projectRoot, f.a);
  assert.equal(back.documentCreated, false);
  assert.notEqual(back.supersededFile, first.supersededFile);
  assert.equal(core.readContext({ recordsDir: f.recordsDir, sessionId: f.sessionId, expectedHost: 'claude' }).project_root, f.a);
  const count = (root) => historyPhases(root, f.sessionId).filter((phase) => phase === reanchor.REANCHOR_HISTORY_PHASE).length;
  assert.equal(count(f.a), 2);
  assert.equal(count(f.b), 2);
});

test('performReanchor moves this session\'s markers, replaces a stale copy and leaves a linked one in place', (t) => {
  const f = fixture(t);
  const stateA = path.join(f.a, '.zensu', 'state');
  const stateB = path.join(f.b, '.zensu', 'state');
  fs.writeFileSync(path.join(stateA, `tdd-mode-${f.key}.json`), '{"mode":"strict"}\n');
  fs.writeFileSync(path.join(stateA, `delivery-route-${f.key}.json`), '{"route":"tdd"}\n');
  fs.symlinkSync(path.join(f.base, 'elsewhere.json'), path.join(stateA, `zen-mode-${f.key}.json`));
  fs.mkdirSync(stateB, { recursive: true });
  fs.writeFileSync(path.join(stateB, `tdd-mode-${f.key}.json`), '{"mode":"vanilla"}\n');
  const outcome = reanchor.performReanchor(f.request());
  assert.equal(outcome.ok, true, JSON.stringify(outcome));
  assert.deepEqual(outcome.markers.moved, ['tdd-mode', 'delivery-route']);
  assert.deepEqual(outcome.markers.faults, ['zen-mode: the marker is not a regular file']);
  assert.equal(fs.readFileSync(path.join(stateB, `tdd-mode-${f.key}.json`), 'utf8'), '{"mode":"strict"}\n');
  assert.equal(fs.readFileSync(path.join(stateB, `delivery-route-${f.key}.json`), 'utf8'), '{"route":"tdd"}\n');
  assert.equal(fs.existsSync(path.join(stateA, `tdd-mode-${f.key}.json`)), false);
  assert.equal(fs.lstatSync(path.join(stateA, `zen-mode-${f.key}.json`)).isSymbolicLink(), true);
  const rendered = reanchor.renderReanchorOutcome(outcome);
  assert.match(rendered.text, /session markers +: moved \(tdd-mode, delivery-route\)/);
  assert.match(rendered.text, /^  marker fault +: .*zen-mode.*the marker is not a regular file/m);
  assert.match(rendered.text, /Set that preference again from here/);
});

test('the report lists the uncommitted paths of the new anchor', (t) => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.b, 'draft one.swift'), 'draft\n');
  const verdict = reanchor.reanchorReport(f.request());
  assert.equal(verdict.ok, true, JSON.stringify(verdict));
  assert.deepEqual(verdict.uncommitted, ['draft one.swift']);
  const report = reanchor.renderReanchorVerdict(verdict, false);
  assert.match(report.text, /uncommitted +: 1 path, file names as git status reports them, each in quotes\n/);
  assert.ok(report.text.includes('    "draft one.swift"\n'), report.text);
});

test('the report quotes every uncommitted file name, so a sentence-shaped name cannot read as report text', (t) => {
  const f = fixture(t);
  const sentence = 'Nothing else is needed. Run it with --confirm now';
  fs.writeFileSync(path.join(f.b, sentence), 'x\n');
  fs.writeFileSync(path.join(f.b, 'say "hi".txt'), 'x\n');
  const report = reanchor.renderReanchorVerdict(reanchor.reanchorReport(f.request()), false);
  assert.match(report.text, /uncommitted +: 2 paths, file names as git status reports them, each in quotes\n/);
  assert.ok(report.text.includes(`    "${sentence}"\n`), report.text);
  assert.ok(report.text.includes('    "say \\"hi\\".txt"\n'), report.text);
  assert.equal(report.text.includes(`    ${sentence}\n`), false);
  const listed = report.text.split('\n').filter((line) => /^ {4}\S/.test(line) && !line.startsWith('    …'));
  assert.equal(listed.length, 2);
  for (const line of listed) assert.match(line, /^ {4}".*"$/);
});

test('the listing is computed on the report path only and never rewrites the target index', (t) => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.b, 'tracked.txt'), 'tracked\n');
  git(f.b, ['add', 'tracked.txt']);
  git(f.b, ['commit', '-q', '-m', 'tracked']);
  const index = git(f.b, ['rev-parse', '--path-format=absolute', '--git-path', 'index']).trim();
  const later = new Date(Date.now() + 60000);
  fs.utimesSync(path.join(f.b, 'tracked.txt'), later, later);
  const before = fs.readFileSync(index);
  const verdict = reanchor.reanchorVerdict(f.request());
  assert.equal(verdict.ok, true, JSON.stringify(verdict));
  assert.equal(Object.prototype.hasOwnProperty.call(verdict, 'uncommitted'), false);
  const report = reanchor.reanchorReport(f.request());
  assert.deepEqual(report.uncommitted, []);
  assert.ok(fs.readFileSync(index).equals(before), 'a read-only report must not rewrite the index of the target');
});

test('performReanchor re-derives the verdict under the lock and changes nothing when it no longer holds', (t) => {
  const f = fixture(t);
  assert.equal(reanchor.reanchorVerdict(f.request()).ok, true);
  const beforeBytes = fs.readFileSync(f.recordFile, 'utf8');
  f.register('900008.json', { pid: process.pid, sessionId: 'foreign-late', cwd: f.b });
  const outcome = reanchor.performReanchor(f.request());
  assert.equal(outcome.ok, false);
  assert.equal(outcome.verdict.reason, R.CLAIMED);
  assert.equal(fs.readFileSync(f.recordFile, 'utf8'), beforeBytes);
  assert.equal(fs.existsSync(path.join(f.b, '.zensu')), false);
  assert.deepEqual(fs.readdirSync(f.recordsDir).filter((name) => name.includes('superseded')), []);
});

test('performReanchor sets aside leases bound to the old root and keeps a lease already bound to the new one', (t) => {
  const f = fixture(t);
  const leaseDir = path.join(f.pluginData, 'review-evidence', 'v1', 'records', f.key);
  fs.mkdirSync(leaseDir, { recursive: true, mode: 0o700 });
  for (const dir of [path.join(f.pluginData, 'review-evidence'), path.join(f.pluginData, 'review-evidence', 'v1'),
    path.join(f.pluginData, 'review-evidence', 'v1', 'records'), leaseDir]) fs.chmodSync(dir, 0o700);
  const oldId = `rel1_${'a'.repeat(32)}`;
  const newId = `rel1_${'b'.repeat(32)}`;
  fs.writeFileSync(path.join(leaseDir, `${oldId}.json`), JSON.stringify({ lease_id: oldId, plugin_root: RUNTIME_ROOT, project_root: f.a }));
  fs.writeFileSync(path.join(leaseDir, `${newId}.json`), JSON.stringify({ lease_id: newId, plugin_root: RUNTIME_ROOT, project_root: f.b }));
  const outcome = reanchor.performReanchor(f.request());
  assert.equal(outcome.ok, true, JSON.stringify(outcome));
  assert.equal(outcome.leases.discarded, 1);
  assert.deepEqual(outcome.leases.failed, []);
  assert.deepEqual(fs.readdirSync(leaseDir), [`${newId}.json`]);
  assert.ok(fs.existsSync(path.join(f.pluginData, 'review-evidence', 'v1', 'superseded', f.key, `${oldId}.json`)));
});

test('discardSupersededLeases without a project root keeps every owned lease, as before', (t) => {
  const f = fixture(t);
  const leaseDir = path.join(f.pluginData, 'review-evidence', 'v1', 'records', f.key);
  fs.mkdirSync(leaseDir, { recursive: true, mode: 0o700 });
  for (const dir of [path.join(f.pluginData, 'review-evidence'), path.join(f.pluginData, 'review-evidence', 'v1'),
    path.join(f.pluginData, 'review-evidence', 'v1', 'records'), leaseDir]) fs.chmodSync(dir, 0o700);
  const id = `rel1_${'c'.repeat(32)}`;
  fs.writeFileSync(path.join(leaseDir, `${id}.json`), JSON.stringify({ lease_id: id, plugin_root: RUNTIME_ROOT, project_root: f.a }));
  const kept = sweep.discardSupersededLeases(f.pluginData, f.key, RUNTIME_ROOT);
  assert.equal(kept.discarded, 0);
  const moved = sweep.discardSupersededLeases(f.pluginData, f.key, RUNTIME_ROOT, f.b);
  assert.equal(moved.discarded, 1);
});

test('performReanchor ages this session keep anchor in the old worktree and writes one in the new worktree', (t) => {
  const f = fixture(t);
  const nowMs = Date.now();
  const idleMs = worktreeKeep.idleMsFromHours(72);
  const started = worktreeKeep.run('session-start', { cwd: f.a, sessionKey: f.key, source: 'startup', nowMs, idleMs, idleHours: 72 });
  assert.equal(started.managed, true);
  const outcome = reanchor.performReanchor(f.request({ worktreeKeep: true }));
  assert.equal(outcome.ok, true, JSON.stringify(outcome));
  assert.match(outcome.keep.state, /^moved/);
  const old = worktreeKeep.readAnchor(f.a, f.key);
  assert.equal(old.status, 'ok');
  assert.equal(typeof old.record.endedAt, 'number');
  const fresh = worktreeKeep.readAnchor(f.b, f.key);
  assert.equal(fresh.status, 'ok');
  assert.equal(fresh.record.worktreeRoot, f.b);
  assert.equal(fresh.record.endedAt, null);
});

test('supersedeContextRecord copies the old bytes aside and refuses to overwrite an existing set-aside record', (t) => {
  const base = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'reanchor-supersede-')));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const file = path.join(base, 'record.json');
  const aside = path.join(base, 'record.aside.json');
  fs.writeFileSync(file, '{"generation":1}\n');
  core.supersedeContextRecord(file, aside, { generation: 2 });
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).generation, 2);
  assert.equal(fs.readFileSync(aside, 'utf8'), '{"generation":1}\n');
  assert.throws(() => core.supersedeContextRecord(file, aside, { generation: 3 }), (error) => error.message.includes(aside));
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).generation, 2);
});

test('the adopt-session skill names every refusal reason the re-anchor can print', () => {
  const skill = fs.readFileSync(path.join(PLUGIN_ROOT, 'skills', 'adopt-session', 'SKILL.md'), 'utf8');
  const missing = Object.values(R).filter((reason) => !skill.includes(`\`${reason}\``));
  assert.deepEqual(missing, []);
});

test('every refusal reason carries its own remedy', () => {
  for (const reason of Object.values(R)) {
    assert.equal(typeof reanchor.REANCHOR_REMEDY[reason], 'string', reason);
    assert.ok(reanchor.REANCHOR_REMEDY[reason].length > 20, reason);
  }
});

test('the open-work remedy cancels an own Autopilot run through the event path, which the release skill leaves to the owner', () => {
  const remedy = reanchor.REANCHOR_REMEDY[R.WORKFLOW_IN_PROGRESS];
  assert.match(remedy, /zensu-log\.sh --autopilot-event --run <run id> --event CANCEL/);
  assert.doesNotMatch(remedy, /cancelled by \/zensu:autopilot-release/);
  const release = fs.readFileSync(path.join(PLUGIN_ROOT, 'skills', 'autopilot-release', 'SKILL.md'), 'utf8');
  assert.match(release, /Cancel that one the ordinary way, through `--autopilot-event --event CANCEL`/);
});

test('the verdict renderer states a refusal with its remedy and detail, and never proceeds', () => {
  const rendered = reanchor.renderReanchorVerdict({ ok: false, reason: R.CLAIMED, detail: ['live session pid 7'] }, true);
  assert.equal(rendered.code, 1);
  assert.equal(rendered.proceed, false);
  assert.match(rendered.text, /NOT MOVABLE \(claimed-by-live-session\)/);
  assert.ok(rendered.text.includes(reanchor.REANCHOR_REMEDY[R.CLAIMED]));
  assert.match(rendered.text, /  - live session pid 7/);
  assert.match(rendered.text, /Nothing was changed\./);
});

test('the verdict renderer names both roots and the uncommitted paths before --confirm and proceeds silently with it', () => {
  const pending = Array.from({ length: 12 }, (_, index) => `src/file-${index}.swift`);
  const verdict = { ok: true, recordedRoot: '/work/repo/a', targetRoot: '/work/repo/b', targetDocument: 'missing', uncommitted: pending };
  const report = reanchor.renderReanchorVerdict(verdict, false);
  assert.equal(report.code, 0);
  assert.equal(report.proceed, false);
  assert.match(report.text, /MOVABLE/);
  assert.match(report.text, /recorded root +: \/work\/repo\/a/);
  assert.match(report.text, /new anchor +: \/work\/repo\/b/);
  assert.match(report.text, /uncommitted +: 12 paths/);
  assert.ok(report.text.includes('    "src/file-9.swift"\n'), report.text);
  assert.ok(!report.text.includes('src/file-10.swift'));
  assert.match(report.text, / … 2 more\n/);
  assert.match(report.text, /absolute path, or that none of these sources shows, is not detected/);
  assert.match(report.text, /Run the same command with --confirm/);
  assert.doesNotMatch(report.text, /every workflow verb/);
  assert.match(report.text, /the Bash tool\nreturns there after a command that leaves it/);
  assert.match(report.text, /start a fresh session there for a new \/zensu:tdd chain/);
  assert.match(reanchor.renderReanchorVerdict({ ...verdict, uncommitted: null }, false).text, /uncommitted +: unknown \(git status failed\)/);
  assert.deepEqual(reanchor.renderReanchorVerdict(verdict, true), { text: '', code: 0, proceed: true });
});

test('the outcome renderer reports a move, its unrecorded provenance, a failure and a late refusal', () => {
  const moved = reanchor.renderReanchorOutcome({
    ok: true,
    previousRoot: '/work/repo/a',
    projectRoot: '/work/repo/b',
    supersededFile: '/data/rec.superseded-reanchor-x.json',
    documentCreated: true,
    provenance: 'unavailable',
    provenanceCause: 'session-control-v1: locked',
    previousProvenance: 'recorded',
    previousProvenanceCause: null,
    leases: { discarded: 2, failed: [] },
    keep: { state: 'moved', faults: [] },
  });
  assert.equal(moved.code, 0);
  assert.match(moved.text, /MOVED/);
  assert.match(moved.text, /project +: \/work\/repo\/b/);
  assert.match(moved.text, /leases set aside +: 2/);
  assert.match(moved.text, /WARNING: the move succeeded but a provenance entry could not be written/);
  assert.doesNotMatch(moved.text, /no\s+restart/);
  assert.match(moved.text, /with a leading cd into the project above, and start a fresh session there for a new\n\/zensu:tdd chain\./);
  const failed = reanchor.renderReanchorOutcome({ ok: false, failed: true, cause: 'boom' });
  assert.equal(failed.code, 1);
  assert.match(failed.text, /FAILED/);
  assert.match(failed.text, /\/zensu:doctor/);
  const late = reanchor.renderReanchorOutcome({ ok: false, verdict: { ok: false, reason: R.CLAIMED, detail: [] } });
  assert.equal(late.code, 1);
  assert.match(late.text, /NOT MOVABLE/);
});

test('liveRegistryDirectory honours CLAUDE_CONFIG_DIR and defaults to the home configuration', () => {
  assert.equal(reanchor.liveRegistryDirectory({ CLAUDE_CONFIG_DIR: '/cfg/claude' }), path.join('/cfg/claude', 'sessions'));
  assert.equal(reanchor.liveRegistryDirectory({}), path.join(os.homedir(), '.claude', 'sessions'));
  assert.equal(reanchor.liveRegistryDirectory({ CLAUDE_CONFIG_DIR: '   ' }), path.join(os.homedir(), '.claude', 'sessions'));
});

test('the outcome renderer names stuck leases and an unswept store, warns, and exits non-zero', () => {
  const rendered = reanchor.renderReanchorOutcome({
    ok: true,
    previousRoot: '/work/repo/a',
    projectRoot: '/work/repo/b',
    supersededFile: '/data/rec.superseded-reanchor-x.json',
    documentCreated: false,
    provenance: 'recorded',
    provenanceCause: null,
    previousProvenance: 'recorded',
    previousProvenanceCause: null,
    leases: { discarded: 0, failed: [`rel1_${'d'.repeat(32)}.json`], unsafe: 'destination', unsafeAt: '/data/review-evidence/v1/superseded' },
    keep: { state: 'disabled', faults: [] },
  });
  assert.equal(rendered.code, 1);
  assert.match(rendered.text, /MOVED \(lease sweep incomplete\)/);
  assert.match(rendered.text, /stuck lease +: rel1_d{32}\.json/);
  assert.match(rendered.text, /lease store +: not swept \(destination\)/);
  assert.match(rendered.text, /lease store at +: \/data\/review-evidence\/v1\/superseded/);
  assert.match(rendered.text, /WARNING: the review-evidence lease store of this session was not fully swept/);
  assert.match(rendered.text, /do not run it again/);
});

test('main refuses a malformed session identity and an unsafe record store before reading anything', (t) => {
  const f = fixture(t);
  const env = {
    CLAUDE_CODE_SESSION_ID: `scv1_${'e'.repeat(64)}`,
    ZREANCHOR_PLUGIN_DATA: f.pluginData,
    ZREANCHOR_PLUGIN_ROOT: RUNTIME_ROOT,
    ZREANCHOR_TARGET: f.b,
    CLAUDE_CONFIG_DIR: f.configDir,
  };
  const badId = reanchor.main(env);
  assert.equal(badId.code, 1);
  assert.match(badId.text, /NOT MOVABLE \(session-id-unusable\)/);
  const bare = path.join(f.base, 'bare-data');
  fs.mkdirSync(bare, { mode: 0o700 });
  const badStore = reanchor.main({ ...env, CLAUDE_CODE_SESSION_ID: f.sessionId, ZREANCHOR_PLUGIN_DATA: bare });
  assert.equal(badStore.code, 1);
  assert.match(badStore.text, /NOT MOVABLE \(private-record-store-unsafe\)/);
});

test('main reports without writing and moves the anchor only with ZREANCHOR_CONFIRM=1', (t) => {
  const f = fixture(t);
  const env = {
    CLAUDE_CODE_SESSION_ID: f.sessionId,
    ZREANCHOR_PLUGIN_DATA: f.pluginData,
    ZREANCHOR_PLUGIN_ROOT: RUNTIME_ROOT,
    ZREANCHOR_TARGET: f.b,
    ZREANCHOR_WORKTREE_KEEP: '0',
    ZREANCHOR_WORKTREE_KEEP_IDLE_HOURS: '72',
    CLAUDE_CONFIG_DIR: f.configDir,
  };
  const before = fs.readFileSync(f.recordFile, 'utf8');
  const report = reanchor.main(env);
  assert.equal(report.code, 0, report.text);
  assert.match(report.text, /MOVABLE/);
  assert.equal(fs.readFileSync(f.recordFile, 'utf8'), before);
  const moved = reanchor.main({ ...env, ZREANCHOR_CONFIRM: '1' });
  assert.equal(moved.code, 0, moved.text);
  assert.match(moved.text, /MOVED/);
  assert.equal(JSON.parse(fs.readFileSync(f.recordFile, 'utf8')).project_root, f.b);
  const again = reanchor.main({ ...env, ZREANCHOR_CONFIRM: '1' });
  assert.equal(again.code, 1);
  assert.match(again.text, /NOT MOVABLE \(already-anchored\)/);
});

test('main takes the session identity from CLAUDE_CODE_SESSION_ID only', (t) => {
  const f = fixture(t);
  const refused = reanchor.main({
    ZREANCHOR_SESSION_ID: f.sessionId,
    ZREANCHOR_PLUGIN_DATA: f.pluginData,
    ZREANCHOR_PLUGIN_ROOT: RUNTIME_ROOT,
    ZREANCHOR_TARGET: f.b,
    CLAUDE_CONFIG_DIR: f.configDir,
  });
  assert.equal(refused.code, 1);
  assert.match(refused.text, /NOT MOVABLE \(session-id-unusable\)/);
});
