'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

const PLUGIN_DIR = fs.realpathSync(path.resolve(__dirname, '..', '..'));
const LIB_DIR = path.join(PLUGIN_DIR, 'hooks', 'lib');
const AUDIT = path.join(LIB_DIR, 'zensu-edit-landing.sh');
const helper = require(path.join(LIB_DIR, 'edit-landing-receipt-v1.js'));
const core = require(path.join(LIB_DIR, 'session-control-core-v1.js'));
const hash = (value) => crypto.createHash('sha256').update(value).digest('hex');

function baseEnv(base) {
  const env = {
    PATH: process.env.PATH,
    HOME: path.join(base, 'home'),
    XDG_CONFIG_HOME: path.join(base, 'config'),
    TMPDIR: path.join(base, 'tmp'),
    GIT_CONFIG_NOSYSTEM: '1',
    LC_ALL: 'C',
  };
  for (const directory of [env.HOME, env.XDG_CONFIG_HOME, env.TMPDIR]) fs.mkdirSync(directory, { recursive: true });
  return env;
}

function writeWorkflow(root, session, { active = true, chainDone = false } = {}) {
  const document = core.stampWorkflowState({
    phase: 'IMPL',
    history: [],
    bypasses: [],
    active,
    vanilla: true,
    implComplete: false,
    chainDone,
    codeReviewDone: false,
    selfReviewFixed: false,
    reviewTicket: '',
    reviewTicketConsumed: false,
    reviewRound: 0,
    stopBlockCount: 0,
  }, session, 'active', 'tdd_begin');
  const file = core.adoptionWorkflowStatePath(root, session);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(document));
  return file;
}

function fixture(t, options = {}) {
  const base = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'landing-scope-')));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const env = baseEnv(base);
  const hooks = path.join(base, 'no-hooks');
  fs.mkdirSync(hooks);
  const root = path.join(base, 'repo');
  fs.mkdirSync(root);
  const git = (...args) => {
    const result = spawnSync('git', ['-C', root, '-c', 'user.email=t@example.invalid', '-c', 'user.name=zensu-test',
      '-c', 'commit.gpgsign=false', '-c', `core.hooksPath=${hooks}`, ...args], { env, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  const withGit = options.git !== false;
  fs.mkdirSync(path.join(root, '.zensu', 'logs'), { recursive: true });
  fs.writeFileSync(path.join(root, '.gitignore'), '.zensu/\n');
  fs.writeFileSync(path.join(root, 'a.js'), 'before\n');
  if (withGit) {
    git('init', '-q');
    git('add', '-A');
    git('commit', '-qm', 'baseline');
  }
  const baseline = withGit ? git('rev-parse', 'HEAD') : '';
  const session = crypto.randomUUID();
  const key = core.sessionKey(session);
  const log = path.join(root, '.zensu', 'logs', 'run.log');
  fs.writeFileSync(log, 'T01 IMPL completed — files: a.js\n');
  const receipt = path.join(root, '.zensu', 'state', `edit-landing-${key}.json`);
  const dirty = path.join(base, 'dirty.txt');
  fs.writeFileSync(dirty, 'a.js\n');
  const proof = path.join(base, 'proof.json');
  fs.writeFileSync(path.join(root, 'a.js'), 'after\n');
  const run = (args, { status, extraEnv = {} } = {}) => {
    const result = spawnSync('bash', [AUDIT, ...args], { env: { ...env, ...extraEnv }, cwd: root, encoding: 'utf8', timeout: 120000 });
    assert.equal(result.error, undefined, result.error && result.error.message);
    if (status !== undefined) assert.equal(result.status, status, `${result.stdout}${result.stderr}`);
    return result;
  };
  const audit = (args = [], status = 0, extraEnv = {}) => run(['--log', log, '--project', root, '--session', session, ...args], { status, extraEnv });
  const check = (status) => run(['--check-receipt', '--project', root, '--session', session], { status });
  const load = (file = receipt) => JSON.parse(fs.readFileSync(file, 'utf8'));
  const putProof = (steps = ['T01'], overrides = {}, file = 'a.js') => {
    const content = fs.readFileSync(path.join(root, file));
    fs.writeFileSync(proof, JSON.stringify({
      schema: helper.PREDICATE_SCHEMA,
      claims: steps.map((step) => ({ step, path: file, sha256: hash(content), present: ['after'], absent: ['before'], ...overrides })),
    }));
    return proof;
  };
  return { base, env, root, git, session, key, log, receipt, dirty, proof, baseline, run, audit, check, load, putProof };
}

test('omitting --dirty-before cannot launder a pending receipt; a literal/hash proof clears it', (t) => {
  const f = fixture(t);
  f.audit(['--dirty-before', f.dirty], 1);
  assert.equal(f.load().pending, 1);
  f.audit([], 1);
  assert.equal(f.load().pending, 1, 'the retry inherits the persisted dirty scope');
  assert.match(f.check(1).stderr, /not clean/);
  f.audit(['--predicates', f.putProof()]);
  assert.match(f.check(0).stdout, /EDIT LANDING RECEIPT FRESH/);
  f.audit();
  assert.equal(f.load().pending, 0, 'an unchanged certified claim stays certified on a retry');
  assert.equal(f.load().clean, true);
});

test('sealing refuses a claimed file or a run log that changed while the audit ran, and the checkpoint stays nonclean', (t) => {
  const f = fixture(t);
  const manifest = path.join(f.base, 'manifest');
  fs.writeFileSync(manifest, 'T01\0a.js\0a.js\0');
  const landed = path.join(f.base, 'landed');
  fs.writeFileSync(landed, '1\n');
  const prepare = () => helper.prepareClaims(helper.prepareScope({ root: f.root, log: f.log, session: f.session }), manifest, '');
  const claimed = prepare();
  helper.checkpointScope(claimed, f.receipt, f.session);
  fs.writeFileSync(path.join(f.root, 'a.js'), 'changed while sealing\n');
  assert.throws(() => helper.finishScope(claimed, landed, 0), /a claimed file changed while the audit ran/);
  const logged = prepare();
  fs.appendFileSync(f.log, 'a note appended while the audit ran\n');
  assert.throws(() => helper.finishScope(logged, landed, 0), /the run log changed while the audit ran/);
  assert.equal(f.load().clean, false);
  assert.equal(typeof f.load().auditFailure, 'string');
  assert.match(f.check(1).stderr, /did not complete/);
  const sealed = helper.finishScope(prepare(), landed, 0);
  assert.equal(sealed.claims[0].certified, true);
});

test('a later round keeps unchanged certified claims and needs a proof for its new claim', (t) => {
  const f = fixture(t);
  f.audit();
  fs.appendFileSync(f.log, 'SR1 IMPL completed — files: a.js\n');
  f.audit([], 1);
  assert.equal(f.load().landed, 1);
  assert.equal(f.load().pending, 1);
  f.audit(['--predicates', f.putProof(['SR1'])]);
  assert.equal(f.load().claims, 2);
  f.check(0);
});

test('changed certified content needs a current proof even when --dirty-before is omitted', (t) => {
  const f = fixture(t);
  f.audit();
  fs.writeFileSync(path.join(f.root, 'a.js'), 'after second\n');
  assert.match(f.check(1).stderr, /a claimed file changed after the receipt/);
  f.audit([], 1);
  assert.equal(f.load().pending, 1);
  f.audit(['--predicates', f.putProof(['T01'], { present: ['after second'] })]);
  f.check(0);
});

test('the persisted baseline survives a mid-run commit and cannot be changed or cleared', (t) => {
  const f = fixture(t);
  f.audit(['--baseline', f.baseline]);
  fs.writeFileSync(path.join(f.root, 'b.js'), 'new\n');
  f.git('add', '-A');
  f.git('commit', '-qm', 'implementation');
  fs.appendFileSync(f.log, 'T02 IMPL completed — files: b.js\n');
  const inherited = f.audit();
  assert.match(inherited.stdout, /EDIT LANDED — T02: b\.js/, 'the inherited baseline keeps a committed claim verifiable');
  assert.equal(f.load().auditScope.baseline, f.baseline);
  assert.match(f.audit(['--baseline', ''], 2).stderr, /--baseline cannot be changed or cleared/);
  assert.match(f.audit(['--baseline', f.git('rev-parse', 'HEAD')], 2).stderr, /--baseline cannot be changed or cleared/);
  assert.equal(f.load().clean, true, 'a refused operand leaves the clean receipt as it was');
});

test('an append-only log and recorded claims cannot be rewritten to drop pending work', (t) => {
  const f = fixture(t);
  f.audit(['--dirty-before', f.dirty], 1);
  fs.writeFileSync(f.log, 'T02 IMPL completed — files: a.js\n');
  assert.match(f.audit([], 2).stderr, /rewritten or truncated/);
  assert.equal(f.load().pending, 1);
  assert.match(f.check(1).stderr, /rewritten or truncated|not clean/);
});

test('the freshness check accepts ordinary appends and rejects new claims, bare WIRED entries, tree edits and a retired receipt', (t) => {
  const f = fixture(t);
  f.audit();
  fs.appendFileSync(f.log, 'ACCEPTANCE — 1/1 passed\nEDIT LANDED — T01: a.js\nEDIT LANDING AUDIT — claims=1\nT01 WIRED (verified, no change) — glob\nTDD COMPLETE — 1 IMPL, 1 WIRED\n');
  f.check(0);
  fs.writeFileSync(path.join(f.root, 'new.js'), 'unclaimed\n');
  assert.match(f.check(1).stderr, /working tree changed after the receipt/);
  fs.unlinkSync(path.join(f.root, 'new.js'));
  f.check(0);
  fs.appendFileSync(f.log, 'SR1 WIRED — files: a.js\n');
  assert.match(f.check(1).stderr, /edit claims the receipt has not graded/);
  f.audit(['--predicates', f.putProof(['SR1'])]);
  f.check(0);
  fs.appendFileSync(f.log, 'S9 WIRED\n');
  assert.match(f.check(1).stderr, /WIRED entry with no files: list/);
  fs.renameSync(f.receipt, `${f.receipt}.superseded-x`);
  assert.match(f.check(1).stderr, /no edit-landing receipt exists/);
});

test('an alternate receipt inherits the canonical pending scope, cannot clear it and leaves it untouched', (t) => {
  const f = fixture(t);
  f.audit(['--dirty-before', f.dirty], 1);
  const before = fs.readFileSync(f.receipt, 'utf8');
  const alternate = path.join(f.base, 'alternate.json');
  f.audit(['--receipt', alternate], 1);
  assert.equal(f.load(alternate).pending, 1);
  assert.equal(fs.readFileSync(f.receipt, 'utf8'), before);
  f.audit(['--receipt', alternate, '--predicates', f.putProof()]);
  assert.equal(f.load(alternate).clean, true);
  assert.equal(f.load().clean, false);
  f.audit([], 1);
  assert.equal(f.load().pending, 1);
  assert.match(f.audit(['--receipt', '-'], 1).stdout, /PENDING PREDICATE — T01: a\.js/);
});

test('predicate proofs fail closed for a wrong hash, empty or false literals, unknown fields and foreign steps', (t) => {
  const f = fixture(t);
  f.audit(['--dirty-before', f.dirty], 1);
  for (const overrides of [{ sha256: '0'.repeat(64) }, { present: [], absent: [] }, { present: ['not in this file'] },
    { command: 'touch forbidden' }, { present: [''] }, { absent: ['after'] }]) {
    const result = f.audit(['--predicates', f.putProof(['T01'], overrides)], 2);
    assert.doesNotMatch(result.stdout, /EDIT LANDED/);
    assert.equal(f.load().clean, false);
  }
  assert.equal(fs.existsSync(path.join(f.root, 'forbidden')), false);
  assert.match(f.audit(['--predicates', f.putProof(['T99'])], 2).stderr, /names no claim/);
  fs.writeFileSync(f.proof, '{not json');
  assert.match(f.audit(['--predicates', f.proof], 2).stderr, /not valid JSON/);
  fs.writeFileSync(f.proof, JSON.stringify({ schema: 'other', claims: [] }));
  assert.match(f.audit(['--predicates', f.proof], 2).stderr, /predicate proof document must be/);
  assert.match(f.audit(['--predicates', f.putProof(['T01'], { path: '../a.js' })], 2).stderr, /normalized repository-relative path/);
  f.audit([], 1);
  assert.equal(f.load().pending, 1);
});

test('a missing --dirty-before file fails before any checkpoint is written', (t) => {
  const f = fixture(t);
  assert.match(f.audit(['--dirty-before', path.join(f.base, 'missing')], 2).stderr, /cannot be read/);
  assert.equal(fs.existsSync(f.receipt), false);
  fs.writeFileSync(f.dirty, './a.js\n');
  assert.match(f.audit(['--dirty-before', f.dirty], 2).stderr, /normalized repository-relative path/);
  assert.equal(fs.existsSync(f.receipt), false);
});

test('a claim on a symlinked leaf or a directory is snapshotted without wedging the audit', (t) => {
  if (process.platform === 'win32') {
    t.skip('symbolic links need elevated rights on Windows');
    return;
  }
  const f = fixture(t);
  f.audit(['--dirty-before', f.dirty], 1);
  fs.renameSync(path.join(f.root, 'a.js'), path.join(f.root, 'target.js'));
  fs.symlinkSync('target.js', path.join(f.root, 'a.js'));
  f.audit([], 1);
  assert.equal(f.load().auditScope.snapshots['a.js'].kind, 'link');
  assert.match(f.audit(['--predicates', f.putProof()], 2).stderr, /existing regular file/);
  fs.mkdirSync(path.join(f.root, 'src'));
  fs.writeFileSync(path.join(f.root, 'src', 'x.js'), 'x\n');
  fs.appendFileSync(f.log, 'T02 IMPL completed — files: src\n');
  f.audit([], 1);
  assert.equal(f.load().auditScope.snapshots.src.kind, 'directory');
  assert.equal(f.load().clean, false);
});

test('outside git a claim is verified by an explicit proof and stays bound to its content', (t) => {
  const f = fixture(t, { git: false });
  f.audit([], 1);
  f.audit(['--predicates', f.putProof()]);
  assert.equal(f.load().auditScope.tree.kind, 'explicit-no-git');
  f.check(0);
  fs.writeFileSync(path.join(f.root, 'a.js'), 'later\n');
  assert.match(f.check(1).stderr, /a claimed file changed after the receipt/);
});

test('a legacy pending receipt cannot be laundered on its first scoped audit', (t) => {
  const f = fixture(t);
  fs.mkdirSync(path.dirname(f.receipt), { recursive: true });
  fs.writeFileSync(f.receipt, JSON.stringify({ schema: 'edit-landing-v2', session: f.session, log: '.zensu/logs/run.log',
    claims: 1, landed: 0, notLanded: 0, unverified: 0, pending: 1, clean: false }));
  f.audit([], 1);
  assert.equal(f.load().pending, 1);
  f.audit(['--predicates', f.putProof()]);
  f.check(0);
});

test('an unresolved bare claim can acquire its real path once it lands, with an explicit proof', (t) => {
  const f = fixture(t);
  fs.writeFileSync(f.log, 'T01 IMPL completed — files: README.md\n');
  f.audit([], 1);
  assert.equal(f.load().auditScope.claims[0].path, null);
  fs.writeFileSync(path.join(f.root, 'README.md'), 'actual new content\n');
  f.audit([], 1);
  assert.equal(f.load().pending, 1, 'a claim whose path was unresolved earlier is never certified by membership');
  fs.writeFileSync(f.proof, JSON.stringify({ schema: helper.PREDICATE_SCHEMA, claims: [{ step: 'T01', path: 'README.md',
    sha256: hash('actual new content\n'), present: ['actual new content'] }] }));
  f.audit(['--predicates', f.proof]);
  f.check(0);
});

test('a .zensu configuration claim keeps its snapshot and its freshness check', (t) => {
  const f = fixture(t);
  fs.writeFileSync(f.log, 'T01 IMPL completed — files: .zensu/config.json\n');
  fs.writeFileSync(path.join(f.root, '.zensu', 'config.json'), '{"enabled":true}\n');
  f.audit();
  assert.equal(f.load().auditScope.snapshots['.zensu/config.json'].exists, true);
  f.check(0);
  fs.writeFileSync(path.join(f.root, '.zensu', 'config.json'), '{"enabled":false}\n');
  assert.match(f.check(1).stderr, /a claimed file changed after the receipt/);
});

test('an invalid first-attempt proof still persists the dirty scope before it fails', (t) => {
  const f = fixture(t);
  f.audit(['--dirty-before', f.dirty, '--predicates', f.putProof(['T01'], { sha256: '0'.repeat(64) })], 2);
  assert.equal(f.load().clean, false);
  assert.deepEqual(f.load().auditScope.dirty, ['a.js']);
  f.audit([], 1);
  assert.equal(f.load().pending, 1);
  f.audit(['--predicates', f.putProof()]);
  f.check(0);
});

test('a git fault keeps the dirty scope and invalidates an earlier clean receipt until a real retry', (t) => {
  const f = fixture(t);
  const bin = path.join(f.base, 'failing-bin');
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'git'), '#!/bin/sh\necho "fatal: synthetic git failure" >&2\nexit 128\n', { mode: 0o755 });
  const failing = { PATH: `${bin}${path.delimiter}${process.env.PATH}` };
  const first = f.audit(['--dirty-before', f.dirty], 2, failing);
  assert.match(first.stdout, /EDIT LANDING AUDIT FAULT — .*synthetic git failure/);
  assert.match(first.stdout, /marked nonclean and keeps its audit scope/);
  assert.doesNotMatch(first.stdout, /EDIT LANDED|EDIT LANDING AUDIT —/);
  assert.equal(f.load().clean, false);
  assert.match(f.load().auditFailure, /git failed/);
  f.audit([], 1);
  assert.equal(f.load().pending, 1);
  f.audit(['--predicates', f.putProof()]);
  f.check(0);
  f.audit([], 2, failing);
  assert.equal('workTree' in f.load(), false, 'a fault checkpoint of a chain that works in the project root records no work tree');
  const refused = f.check(1);
  assert.match(refused.stderr, /did not complete/);
  assert.deepEqual(recoveryOf(refused.stderr).words, ['bash', AUDIT, '--log', f.log, '--project', f.root, '--session', f.key]);
  f.audit();
  f.check(0);
});

test('an active workflow refuses an audit with --receipt - while --inventory stays read-only', (t) => {
  const f = fixture(t);
  writeWorkflow(f.root, f.session);
  assert.match(f.audit(['--receipt', '-', '--dirty-before', f.dirty], 2).stderr, /requires the receipt-producing audit/);
  assert.equal(fs.existsSync(f.receipt), false);
  const inventory = f.run(['--inventory', '--log', f.log, '--project', f.root], { status: 0 });
  assert.match(inventory.stdout, /claimed-files=1/);
  writeWorkflow(f.root, f.session, { chainDone: true });
  f.audit(['--receipt', '-'], 0);
});

test('a nested project root binds its own session receipt while claims stay repository-relative', (t) => {
  const f = fixture(t);
  const projectRoot = path.join(f.root, 'nested');
  fs.mkdirSync(path.join(projectRoot, '.zensu', 'logs'), { recursive: true });
  const log = path.join(projectRoot, '.zensu', 'logs', 'nested.log');
  fs.writeFileSync(log, 'T01 IMPL completed — files: nested/new.js\n');
  fs.writeFileSync(path.join(projectRoot, 'new.js'), 'new content\n');
  f.run(['--log', log, '--project', projectRoot, '--session', f.session], { status: 0 });
  const receipt = JSON.parse(fs.readFileSync(path.join(projectRoot, '.zensu', 'state', path.basename(f.receipt)), 'utf8'));
  assert.equal(receipt.auditScope.root, projectRoot);
  assert.equal(receipt.auditScope.claimRoot, f.root);
  f.run(['--check-receipt', '--project', projectRoot, '--session', f.session], { status: 0 });
});

test('a nested project root keeps its receipt fresh across its own run-log appends and workflow writes', (t) => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.root, '.gitignore'), '.zensu/state/\n');
  const projectRoot = path.join(f.root, 'nested');
  fs.mkdirSync(path.join(projectRoot, '.zensu', 'logs'), { recursive: true });
  const log = path.join(projectRoot, '.zensu', 'logs', 'nested.log');
  fs.writeFileSync(log, 'T01 IMPL completed — files: nested/new.js\n');
  fs.writeFileSync(path.join(projectRoot, 'new.js'), 'new content\n');
  f.run(['--log', log, '--project', projectRoot, '--session', f.session], { status: 0 });
  const check = (status) => f.run(['--check-receipt', '--project', projectRoot, '--session', f.session], { status });
  check(0);
  fs.appendFileSync(log, 'EDIT LANDING AUDIT — claims=1 landed=1\n');
  fs.mkdirSync(path.join(projectRoot, '.zensu', 'reviews'), { recursive: true });
  fs.writeFileSync(path.join(projectRoot, '.zensu', 'reviews', 'findings-round-1.json'), '{}\n');
  check(0);
  fs.writeFileSync(path.join(projectRoot, 'other.js'), 'outside the workflow state\n');
  assert.match(check(1).stderr, /the working tree changed after the receipt/);
});

test('a deletion proof needs a file the audit observed earlier and survives a pending audit', (t) => {
  const f = fixture(t, { git: false });
  fs.mkdirSync(path.join(f.root, 'src'));
  fs.writeFileSync(f.log, 'T01 IMPL completed — files: src/missing.js\n');
  f.audit([], 1);
  fs.writeFileSync(f.proof, JSON.stringify({ schema: helper.PREDICATE_SCHEMA, claims: [{ step: 'T01', path: 'src/missing.js', missing: true }] }));
  assert.match(f.audit(['--predicates', f.proof], 2).stderr, /observed earlier, or a git deletion/);
  fs.writeFileSync(path.join(f.root, 'src', 'missing.js'), 'exists now\n');
  f.audit([], 1);
  fs.unlinkSync(path.join(f.root, 'src', 'missing.js'));
  f.audit([], 1);
  f.audit(['--predicates', f.proof]);
  f.check(0);
});

test('a later ignore rule cannot clear a persisted pending dirty claim', (t) => {
  const f = fixture(t);
  fs.mkdirSync(path.join(f.root, 'src'));
  fs.writeFileSync(path.join(f.root, 'src', 'new.js'), 'after\n');
  fs.writeFileSync(f.log, 'T01 IMPL completed — files: src/new.js\n');
  fs.writeFileSync(f.dirty, 'src/new.js\n');
  f.audit(['--dirty-before', f.dirty], 1);
  fs.appendFileSync(path.join(f.root, '.gitignore'), 'src/new.js\n');
  f.audit([], 1);
  assert.equal(f.load().pending, 1);
});

test('the scope binds its run log and refuses another log in the same generation', (t) => {
  const f = fixture(t);
  f.audit();
  const other = path.join(f.root, '.zensu', 'logs', 'other.log');
  fs.writeFileSync(other, 'T01 IMPL completed — files: a.js\n');
  assert.match(f.run(['--log', other, '--project', f.root, '--session', f.session], { status: 2 }).stderr, /bound to another run log/);
  assert.equal(f.load().clean, true);
  f.check(0);
});

test('without --session the audit announces a standalone run, and --inventory stays silent', (t) => {
  const f = fixture(t);
  const standalone = f.run(['--log', f.log, '--project', f.root], { status: 0 });
  assert.match(standalone.stderr, /STANDALONE AUDIT — this run names no --session/);
  assert.equal(fs.existsSync(f.receipt), false);
  assert.match(f.run(['--log', f.log, '--project', f.root, '--receipt', '-'], { status: 0 }).stderr, /STANDALONE AUDIT/);
  const explicit = path.join(f.base, 'explicit.json');
  assert.doesNotMatch(f.run(['--log', f.log, '--project', f.root, '--receipt', explicit], { status: 0 }).stderr, /STANDALONE AUDIT/);
  assert.equal(f.load(explicit).auditScope.sessionKey, null);
  writeWorkflow(f.root, f.session);
  const inventory = f.run(['--inventory', '--log', f.log, '--project', f.root], { status: 0, extraEnv: { CLAUDE_CODE_SESSION_ID: f.session } });
  assert.match(inventory.stdout, /claimed-files=1/);
  assert.doesNotMatch(inventory.stderr, /STANDALONE|SESSION REQUIRED/);
});

test('an active Claude workflow refuses an audit without --session and names the exact recovery command', (t) => {
  const f = fixture(t);
  writeWorkflow(f.root, f.session);
  f.audit(['--dirty-before', f.dirty], 1);
  const other = path.join(f.root, '.zensu', 'logs', 'other.log');
  fs.writeFileSync(other, 'T01 IMPL completed — files: a.js\n');
  const refused = f.run(['--log', other, '--project', f.root], { status: 2, extraEnv: { CLAUDE_CODE_SESSION_ID: f.session } });
  assert.match(refused.stderr, /AUDIT SESSION REQUIRED — an active workflow requires the explicit --session operand/);
  assert.doesNotMatch(refused.stdout, /EDIT LANDED|EDIT LANDING AUDIT/);
  assert.equal(f.load().pending, 1, 'the refusal leaves the bound receipt untouched');
  const line = refused.stderr.split('\n').find((entry) => entry.startsWith('Run: '));
  assert.ok(line, refused.stderr);
  const parsed = spawnSync('bash', ['-c', `set -- ${line.slice(5)}; printf '%s\\0' "$@"`], { encoding: 'utf8' });
  assert.equal(parsed.status, 0, parsed.stderr);
  assert.deepEqual(parsed.stdout.split('\0').slice(0, -1), ['bash', AUDIT, '--log', f.log, '--project', f.root, '--session', f.key]);
  const recovered = spawnSync('bash', ['-c', line.slice(5)], { env: f.env, cwd: f.root, encoding: 'utf8' });
  assert.equal(recovered.status, 1, recovered.stdout + recovered.stderr);
  assert.match(recovered.stdout, /PENDING PREDICATE — T01: a\.js/);
});

test('an untrustworthy workflow state of the ambient session refuses instead of passing as standalone', (t) => {
  const f = fixture(t);
  const file = writeWorkflow(f.root, f.session);
  for (const content of ['{"schema":"zensu.workflow-state"}', 'not json']) {
    fs.writeFileSync(file, content);
    const refused = f.run(['--log', f.log, '--project', f.root], { status: 2, extraEnv: { CLAUDE_CODE_SESSION_ID: f.session } });
    assert.match(refused.stderr, /cannot be trusted/);
    assert.match(refused.stderr, /^Run: /m);
  }
});

test('a finished, inactive or unknown ambient session runs as a standalone audit', (t) => {
  const f = fixture(t);
  for (const shape of [{ chainDone: true }, { active: false }]) {
    writeWorkflow(f.root, f.session, shape);
    const result = f.run(['--log', f.log, '--project', f.root], { status: 0, extraEnv: { CLAUDE_CODE_SESSION_ID: f.session } });
    assert.match(result.stderr, /STANDALONE AUDIT/);
  }
  const unknown = f.run(['--log', f.log, '--project', f.root], { status: 0, extraEnv: { CLAUDE_CODE_SESSION_ID: crypto.randomUUID() } });
  assert.match(unknown.stderr, /STANDALONE AUDIT/);
});

test('the recovery command quotes every unsafe operand and withholds a control-character value', () => {
  const root = "/tmp/audit's project $(printf unsafe)";
  const key = `scv1_${'a'.repeat(64)}`;
  const command = helper.auditRecoveryCommand({ helper: AUDIT, projectRoot: root, sessionKey: key, log: `${root}/.zensu/logs/bound.log` });
  const parsed = spawnSync('bash', ['-c', `set -- ${command}; printf '%s\\0' "$@"`], { encoding: 'utf8' });
  assert.equal(parsed.status, 0, parsed.stderr);
  assert.deepEqual(parsed.stdout.split('\0').slice(0, -1), ['bash', AUDIT, '--log', `${root}/.zensu/logs/bound.log`, '--project', root, '--session', key]);
  const withheld = helper.auditRecoveryCommand({ helper: AUDIT, projectRoot: '/tmp/x\nEDIT LANDED — T01: a.js', sessionKey: key, log: '' });
  assert.doesNotMatch(withheld, /\n/);
  assert.match(withheld, /'<project root>'/);
  assert.match(withheld, /'<run log>'/);
  const tree = `${root}/.claude/worktrees/wt`;
  const bound = helper.auditRecoveryCommand({ helper: AUDIT, projectRoot: root, sessionKey: key, log: `${root}/.zensu/logs/bound.log`, workTree: tree });
  const boundWords = spawnSync('bash', ['-c', `set -- ${bound}; printf '%s\\0' "$@"`], { encoding: 'utf8' });
  assert.equal(boundWords.status, 0, boundWords.stderr);
  assert.deepEqual(boundWords.stdout.split('\0').slice(-3, -1), ['--work-tree', tree]);
  const unsafeTree = helper.auditRecoveryCommand({ helper: AUDIT, projectRoot: root, sessionKey: key, log: '', workTree: 'wt\nEDIT LANDED — T01: a.js' });
  assert.doesNotMatch(unsafeTree, /\n/);
  assert.match(unsafeTree, /--work-tree '<work tree>'$/);
});

function recoveryOf(stderr) {
  const line = stderr.split('\n').find((entry) => entry.startsWith('Run: '));
  assert.ok(line, stderr);
  const parsed = spawnSync('bash', ['-c', `set -- ${line.slice(5)}; printf '%s\\0' "$@"`], { encoding: 'utf8' });
  assert.equal(parsed.status, 0, parsed.stderr);
  return { command: line.slice(5), words: parsed.stdout.split('\0').slice(0, -1) };
}

test('a chain that works in a worktree below the project gets a recovery command that names that tree and keeps its scope', (t) => {
  const f = fixture(t);
  const tree = path.join(f.root, '.claude', 'worktrees', 'wt');
  f.git('worktree', 'add', '-q', '-b', 'wt', tree);
  fs.writeFileSync(path.join(tree, 'a.js'), 'after\n');
  const first = f.audit(['--work-tree', tree]);
  assert.match(first.stdout, /^EDIT LANDED — T01: a\.js$/m);
  assert.equal(f.load().workTree, '.claude/worktrees/wt');
  fs.writeFileSync(path.join(tree, 'a.js'), 'later\n');
  const stale = f.check(1);
  assert.match(stale.stderr, /a claimed file changed after the receipt/);
  const recovery = recoveryOf(stale.stderr);
  assert.deepEqual(recovery.words, ['bash', AUDIT, '--log', f.log, '--project', f.root, '--session', f.key, '--work-tree', tree]);
  const recovered = spawnSync('bash', ['-c', recovery.command], { env: f.env, cwd: f.root, encoding: 'utf8' });
  assert.equal(recovered.status, 1, recovered.stdout + recovered.stderr);
  assert.match(recovered.stdout, /^PENDING PREDICATE — T01: a\.js /m);
  assert.equal(f.load().workTree, '.claude/worktrees/wt');
  assert.equal(f.load().auditScope.claims[0].landedOnce, true, 'the scope of the work tree was kept, so the claim keeps its landing evidence');
  writeWorkflow(f.root, f.session);
  const gated = f.run(['--log', f.log, '--project', f.root], { status: 2, extraEnv: { CLAUDE_CODE_SESSION_ID: f.session } });
  assert.match(gated.stderr, /AUDIT SESSION REQUIRED/);
  assert.deepEqual(recoveryOf(gated.stderr).words.slice(-2), ['--work-tree', tree]);
});

test('a git fault during an audit of a worktree chain keeps the recorded work tree, so the recovery command still names it', (t) => {
  const f = fixture(t);
  const tree = path.join(f.root, '.claude', 'worktrees', 'wt');
  f.git('worktree', 'add', '-q', '-b', 'wt', tree);
  fs.writeFileSync(path.join(tree, 'a.js'), 'after\n');
  f.audit(['--work-tree', tree]);
  assert.equal(f.load().auditScope.claims[0].certified, true);
  fs.writeFileSync(path.join(tree, 'a.js'), 'later\n');
  const bin = path.join(f.base, 'failing-bin');
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'git'), '#!/bin/sh\necho "fatal: synthetic git failure" >&2\nexit 128\n', { mode: 0o755 });
  const faulted = f.audit(['--work-tree', tree], 2, { PATH: `${bin}${path.delimiter}${process.env.PATH}` });
  assert.match(faulted.stdout, /EDIT LANDING AUDIT FAULT — .*synthetic git failure/);
  assert.match(f.load().auditFailure, /git failed/);
  assert.equal(f.load().auditScope.claimRoot, tree, 'the fault keeps the scope on the work tree');
  assert.equal(f.load().workTree, '.claude/worktrees/wt', 'the fault checkpoint records the work tree its scope is bound to');
  const refused = f.check(1);
  assert.match(refused.stderr, /did not complete/);
  const line = refused.stderr.split('\n').find((entry) => entry.startsWith('Run: '));
  assert.ok(line, refused.stderr);
  const words = spawnSync('bash', ['-c', `set -- ${line.slice(5)}; printf '%s\\0' "$@"`], { encoding: 'utf8' });
  assert.equal(words.status, 0, words.stderr);
  assert.deepEqual(words.stdout.split('\0').slice(0, -1), ['bash', AUDIT, '--log', f.log, '--project', f.root, '--session', f.key, '--work-tree', tree]);
  const recovered = spawnSync('bash', ['-c', line.slice(5)], { env: f.env, cwd: f.root, encoding: 'utf8' });
  assert.equal(recovered.status, 1, recovered.stdout + recovered.stderr);
  assert.match(recovered.stdout, /^PENDING PREDICATE — T01: a\.js /m);
  assert.equal(f.load().workTree, '.claude/worktrees/wt');
  assert.equal(f.load().auditScope.claims[0].landedOnce, true, 'the retry continued the scope of the work tree, so the claim keeps its landing evidence');
});

test('a receipt whose recorded work tree no reader can use prints the placeholder in its recovery command, which fails as written', (t) => {
  const f = fixture(t);
  const tree = path.join(f.root, '.claude', 'worktrees', 'wt');
  f.git('worktree', 'add', '-q', '-b', 'wt', tree);
  fs.writeFileSync(path.join(tree, 'a.js'), 'after\n');
  f.audit(['--work-tree', tree]);
  fs.writeFileSync(f.receipt, JSON.stringify({ ...f.load(), workTree: '../elsewhere' }));
  const unusable = fs.readFileSync(f.receipt, 'utf8');
  const refused = f.check(1);
  assert.match(refused.stderr, /EDIT LANDING RECEIPT STALE — the receipt names a work tree that is not a path inside the project/);
  const recovery = recoveryOf(refused.stderr);
  assert.deepEqual(recovery.words, ['bash', AUDIT, '--log', f.log, '--project', f.root, '--session', f.key, '--work-tree', '<work tree>']);
  const asWritten = spawnSync('bash', ['-c', recovery.command], { env: f.env, cwd: f.root, encoding: 'utf8' });
  assert.equal(asWritten.status, 2, asWritten.stdout + asWritten.stderr);
  assert.match(asWritten.stderr, /work tree not found/);
  assert.equal(fs.readFileSync(f.receipt, 'utf8'), unusable, 'the command as written grades nothing and leaves the receipt alone');
  writeWorkflow(f.root, f.session);
  const gated = f.run(['--log', f.log, '--project', f.root], { status: 2, extraEnv: { CLAUDE_CODE_SESSION_ID: f.session } });
  assert.match(gated.stderr, /AUDIT SESSION REQUIRED/);
  assert.deepEqual(recoveryOf(gated.stderr).words.slice(-2), ['--work-tree', '<work tree>']);
});

test('a git fault on a work tree whose path claimPath rejects still records it, so the recovery command asks for the tree', (t) => {
  if (process.platform === 'win32') {
    t.skip('a backslash separates path segments on Windows, so no directory name can hold one');
    return;
  }
  const f = fixture(t);
  const tree = path.join(f.root, '.claude', 'worktrees', 'w\\t');
  f.git('worktree', 'add', '-q', '-b', 'odd', tree);
  fs.writeFileSync(path.join(tree, 'a.js'), 'after\n');
  f.audit(['--work-tree', tree]);
  assert.equal(f.load().workTree, '.claude/worktrees/w\\t', 'the sealed receipt records the path as the audit was given it');
  assert.equal(f.load().auditScope.claims[0].certified, true);
  const sealed = f.check(1);
  assert.match(sealed.stderr, /the receipt names a work tree that is not a path inside the project/);
  assert.deepEqual(recoveryOf(sealed.stderr).words.slice(-2), ['--work-tree', '<work tree>'], 'the sealed receipt prints the placeholder too');
  fs.writeFileSync(path.join(tree, 'a.js'), 'later\n');
  const bin = path.join(f.base, 'failing-bin');
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'git'), '#!/bin/sh\necho "fatal: synthetic git failure" >&2\nexit 128\n', { mode: 0o755 });
  const faulted = f.audit(['--work-tree', tree], 2, { PATH: `${bin}${path.delimiter}${process.env.PATH}` });
  assert.match(faulted.stdout, /EDIT LANDING AUDIT FAULT — .*synthetic git failure/);
  assert.match(f.load().auditFailure, /git failed/);
  assert.equal(f.load().auditScope.claimRoot, tree, 'the fault keeps the scope on the work tree');
  assert.equal(f.load().workTree, '.claude/worktrees/w\\t', 'the fault checkpoint records the work tree its scope is bound to, as the sealed receipt did');
  const refused = f.check(1);
  assert.match(refused.stderr, /did not complete/);
  const recovery = recoveryOf(refused.stderr);
  assert.deepEqual(recovery.words, ['bash', AUDIT, '--log', f.log, '--project', f.root, '--session', f.key, '--work-tree', '<work tree>']);
  const asWritten = spawnSync('bash', ['-c', recovery.command], { env: f.env, cwd: f.root, encoding: 'utf8' });
  assert.equal(asWritten.status, 2, asWritten.stdout + asWritten.stderr);
  assert.match(asWritten.stderr, /work tree not found/);
  assert.equal(f.load().auditScope.claimRoot, tree, 'the command as written did not audit the anchor, so the scope stays on the work tree');
  const retried = f.audit(['--work-tree', tree], 1);
  assert.match(retried.stdout, /^PENDING PREDICATE — T01: a\.js /m);
  assert.equal(f.load().auditScope.claims[0].landedOnce, true, 'the retry with the real tree continued the scope, so the claim keeps its landing evidence');
});

test('a checkpoint records the work tree of its scope as written, and none for a claim root at or outside the project root', (t) => {
  const s = scratch(t, 'landing-checkpoint-');
  const log = s.write('.zensu/logs/run.log', 'T01 IMPL completed — files: a.js\n');
  const receiptPath = helper.receiptFile(s.base, `scv1_${'b'.repeat(64)}`);
  const checkpoint = (claimRoot, workTree) => {
    helper.checkpointScope({ schema: helper.SCOPE_SCHEMA, root: s.base, claimRoot, log, dirty: [], baseline: '', claims: [] }, receiptPath, 'x', workTree);
    return JSON.parse(fs.readFileSync(receiptPath, 'utf8'));
  };
  assert.equal(checkpoint(path.join(s.base, 'a', 'b')).workTree, 'a/b');
  for (const name of ['w\x7ft', '.git']) {
    refuses(() => helper.relativeFile(`nested/${name}`), /normalized repository-relative path/);
    assert.equal(checkpoint(path.join(s.base, 'nested', name)).workTree, `nested/${name}`, 'a path claimPath rejects is recorded as it is');
  }
  for (const claimRoot of [s.base, path.dirname(s.base), path.join(path.dirname(s.base), 'sibling'), '', undefined]) {
    assert.equal('workTree' in checkpoint(claimRoot), false, `the claim root ${JSON.stringify(claimRoot)} records no work tree`);
  }
  assert.equal(checkpoint(path.join(s.base, 'a', 'b'), 'named/by/the/audit').workTree, 'named/by/the/audit', 'a work tree the audit hands over is recorded before the one of the scope');
});

test('--check-receipt refuses a missing, pending or interrupted receipt and its own malformed operands', (t) => {
  const f = fixture(t);
  assert.match(f.check(1).stderr, /no edit-landing receipt exists/);
  f.audit(['--dirty-before', f.dirty], 1);
  const pending = f.check(1);
  assert.match(pending.stderr, /EDIT LANDING RECEIPT STALE — the receipt is not clean/);
  assert.match(pending.stderr, /^Run: /m);
  assert.match(pending.stderr, /whose supersededBy names the replacing step/);
  assert.doesNotMatch(pending.stderr.split('\n').find((line) => line.startsWith('Run: ')), /--work-tree/);
  f.audit(['--predicates', f.putProof(['T01'], { sha256: '0'.repeat(64) })], 2);
  assert.match(f.check(1).stderr, /did not complete/);
  f.run(['--check-receipt', '--project', f.root], { status: 2 });
  f.run(['--check-receipt', '--project', f.root, '--session', f.session, '--log', f.log], { status: 2 });
  f.run(['--check-receipt', '--inventory', '--project', f.root, '--session', f.session], { status: 2 });
  f.run(['--check-receipt', '--project', f.root, '--session', f.session, '--predicates', f.proof], { status: 2 });
});

test('a bare WIRED entry the audit graded keeps the receipt current but not clean, and a later one makes it stale', (t) => {
  const f = fixture(t);
  fs.appendFileSync(f.log, 'S2 WIRED\n');
  f.audit([], 1);
  assert.equal(f.load().auditScope.bareWired, 1);
  assert.equal(f.load().unverified, 1);
  const allow = (status) => f.run(['--check-receipt', '--allow-unclean', '--project', f.root, '--session', f.session], { status });
  assert.match(allow(0).stdout, /^EDIT LANDING RECEIPT CURRENT — .*clean=false\.$/m);
  assert.match(f.check(1).stderr, /EDIT LANDING RECEIPT STALE — the receipt is not clean/);
  fs.appendFileSync(f.log, 'S3 WIRED\n');
  assert.match(allow(1).stderr, /WIRED entry with no files: list that the receipt has not graded/);
  f.audit([], 1);
  assert.equal(f.load().auditScope.bareWired, 2);
  allow(0);
});

test('an audit that did not complete is carried as incomplete under --allow-unclean and refused without it', (t) => {
  const f = fixture(t);
  f.audit(['--dirty-before', f.dirty], 1);
  f.audit(['--predicates', f.putProof(['T01'], { sha256: '0'.repeat(64) })], 2);
  assert.ok(f.load().auditFailure);
  const allowed = f.run(['--check-receipt', '--allow-unclean', '--project', f.root, '--session', f.session], { status: 0 });
  assert.match(allowed.stdout, /^EDIT LANDING RECEIPT INCOMPLETE — the latest audit of this session did not complete; the receipt records clean=false and is carried as incomplete\.$/m);
  assert.match(f.check(1).stderr, /EDIT LANDING RECEIPT STALE — the latest audit did not complete; re-run it\./);
  const other = crypto.randomUUID();
  fs.copyFileSync(f.receipt, path.join(f.root, '.zensu', 'state', `edit-landing-${core.sessionKey(other)}.json`));
  const foreign = f.run(['--check-receipt', '--allow-unclean', '--project', f.root, '--session', other], { status: 1 });
  assert.match(foreign.stderr, /the receipt belongs to another session/);
});

test('receipt-claims prints the claim count of a known-schema receipt and answers none otherwise', (t) => {
  const f = fixture(t);
  const claims = (file) => {
    const chunks = [];
    const code = helper.main(['receipt-claims'], { ZENSU_ELR_RECEIPT: file }, { write: (value) => chunks.push(String(value)) }, { write: () => {} });
    return { code, out: chunks.join('') };
  };
  assert.deepEqual(claims(f.receipt), { code: helper.EXIT.none, out: '' });
  fs.writeFileSync(f.log, 'TDD START — no claims\n');
  f.run(['--log', f.log, '--project', f.root, '--session', f.session]);
  assert.deepEqual(claims(f.receipt), { code: helper.EXIT.ok, out: '0' });
  const planted = path.join(f.base, 'planted.json');
  for (const value of [{ schema: 'edit-landing-v9', claims: 0 }, { schema: 'edit-landing-v2', claims: '0' }, { schema: 'edit-landing-v2', claims: -1 }, [0]]) {
    fs.writeFileSync(planted, JSON.stringify(value));
    assert.equal(claims(planted).code, helper.EXIT.none, JSON.stringify(value));
  }
});

function sink() {
  const chunks = [];
  return { write: (value) => chunks.push(String(value)), text: () => chunks.join('') };
}

function scratch(t, prefix) {
  const base = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const write = (name, content) => {
    const file = path.join(base, name);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, content);
    return file;
  };
  return { base, write };
}

const manifestOf = (records) => `${records.map((record) => record.join('\0')).join('\0')}\0`;
const refuses = (fn, pattern) => assert.throws(fn, (error) => error instanceof helper.AuditScopeError && pattern.test(error.message));

test('every audit bound refuses with its remedy, and the run log is hashed in chunks with no size bound', (t) => {
  const s = scratch(t, 'landing-bounds-');
  const saved = { ...helper.LIMITS };
  t.after(() => Object.assign(helper.LIMITS, saved));
  s.write('a.js', 'after\n');
  s.write('b.js', 'other\n');
  const manifest = s.write('manifest', manifestOf([
    ['T01', 'T01 IMPL completed — files: a.js', 'a.js'],
    ['T02', 'T02 IMPL completed — files: b.js', 'b.js'],
  ]));
  const scope = { schema: helper.SCOPE_SCHEMA, root: s.base, claimRoot: s.base, dirty: [], baseline: '', previous: null, legacyUnresolved: false };
  helper.LIMITS.claims = 1;
  refuses(() => helper.prepareClaims(scope, manifest, ''),
    /more than 1 claimed files; name each file once per step, or arm a new generation with --tdd-begin, which starts an empty audit scope$/);
  helper.LIMITS.claims = saved.claims;
  helper.LIMITS.snapshotBytes = 8;
  refuses(() => helper.prepareClaims(scope, manifest, ''),
    /exceed the 8-byte snapshot budget of one audit generation; claim source files rather than generated artifacts, or arm a new generation/);
  helper.LIMITS.snapshotBytes = saved.snapshotBytes;
  const prepared = helper.prepareClaims(scope, manifest, '');
  const proof = (entry) => s.write('proof.json', JSON.stringify({
    schema: helper.PREDICATE_SCHEMA,
    claims: [{ step: 'T01', path: 'a.js', sha256: prepared.snapshots['a.js'].sha256, ...entry }],
  }));
  const verify = (file) => [...helper.verifyPredicates(s.base, file, prepared.claims, prepared.snapshots, new Set(['a.js']), '').proved];
  helper.LIMITS.literals = 1;
  refuses(() => verify(proof({ present: ['af', 'ter'] })), /at most 1 nonblank strings of at most 4096 bytes; prove the claim with fewer, shorter literals$/);
  helper.LIMITS.literals = saved.literals;
  helper.LIMITS.literalBytes = 2;
  refuses(() => verify(proof({ present: ['after'] })), /at most 100 nonblank strings of at most 2 bytes/);
  helper.LIMITS.literalBytes = saved.literalBytes;
  helper.LIMITS.proofFileBytes = 3;
  refuses(() => verify(proof({ present: ['after'] })), /a claimed file exceeds the 3-byte limit; withdraw that claim with CLAIM WITHDRAWN instead$/);
  helper.LIMITS.proofFileBytes = saved.proofFileBytes;
  assert.deepEqual(verify(proof({ present: ['after'] })), [1]);
  const log = s.write('.zensu/logs/run.log', 'T01 IMPL completed — files: a.js\n');
  helper.LIMITS.scopeBytes = 64;
  const receiptPath = helper.receiptFile(s.base, `scv1_${'a'.repeat(64)}`);
  refuses(() => helper.checkpointScope({ ...prepared, log }, receiptPath, 'x'),
    /the audit scope exceeds the 64-byte receipt limit; claim fewer files in this generation, or arm a new generation/);
  helper.LIMITS.scopeBytes = 16;
  const scopeDir = fs.mkdtempSync(path.join(s.base, 'scope-'));
  const out = sink();
  const err = sink();
  assert.equal(helper.main(['scope-prepare'], { ZEL_ROOT: s.base, ZEL_LOG: log, ZEL_SCOPE_DIR: scopeDir, ZEL_SESSION: '' }, out, err), helper.EXIT.usage);
  assert.match(err.text(), /the audit scope exceeds its 64-byte working limit; claim fewer files in this generation, or arm a new generation/);
  helper.LIMITS.scopeBytes = saved.scopeBytes;
  const content = Buffer.concat([Buffer.alloc(17 * 1024 * 1024, 'a'), Buffer.from('tail\n')]);
  const big = s.write('big.log', content);
  const whole = helper.logPrefix(big);
  assert.deepEqual(whole, { bytes: content.length, sha256: hash(content) });
  const cut = 1024 * 1024 + 7;
  assert.deepEqual(helper.logPrefix(big, { bytes: cut, sha256: hash(content.subarray(0, cut)) }), whole);
  assert.deepEqual(helper.logPrefix(big, { bytes: 0, sha256: hash(Buffer.alloc(0)) }), whole);
  refuses(() => helper.logPrefix(big, { bytes: cut, sha256: hash('another prefix') }),
    /rewritten or truncated since the previous audit; keep its append-only history, or arm a new generation/);
  refuses(() => helper.logPrefix(big, { bytes: content.length + 1, sha256: whole.sha256 }), /rewritten or truncated/);
});

test('a claim whose path resolution moved is graded again instead of aborting the audit', (t) => {
  const s = scratch(t, 'landing-moved-');
  s.write('a.js', 'v1\n');
  s.write('nested/a.js', 'v1\n');
  const raw = 'T01 IMPL completed — files: a.js';
  const scope = {
    schema: helper.SCOPE_SCHEMA,
    root: s.base,
    claimRoot: s.base,
    dirty: [],
    baseline: '',
    legacyUnresolved: false,
    previous: {
      claims: [{ step: 'T01', raw, path: 'a.js', certified: true }],
      snapshots: { 'a.js': helper.snapshot(s.base, 'a.js') },
      observedFiles: ['a.js'],
    },
  };
  const moved = helper.prepareClaims(scope, s.write('moved', manifestOf([['T01', raw, 'nested/a.js']])), '');
  assert.deepEqual(moved.certified, [], 'a moved claim is never certified from its earlier resolution');
  assert.ok(moved.dirty.includes('nested/a.js'));
  const lost = helper.prepareClaims(scope, s.write('lost', manifestOf([['T01', raw, '']])), '');
  assert.deepEqual(lost.certified, []);
  assert.deepEqual(helper.prepareClaims(scope, s.write('same', manifestOf([['T01', raw, 'a.js']])), '').certified, [1]);
  const rewritten = helper.prepareClaims(scope, s.write('rewritten', manifestOf([['T01', 'T01 IMPL completed — files: b.js', 'b.js']])), '');
  assert.deepEqual(rewritten.certified, [], 'a claim the reader spells differently is graded as a new claim');
  s.write('c.js', 'v1\n');
  const reordered = helper.prepareClaims(scope, s.write('reordered', manifestOf([['T00', 'T00 IMPL completed — files: c.js', 'c.js'], ['T01', raw, 'a.js']])), '');
  assert.deepEqual(reordered.certified, [2], 'a claim keeps its certification wherever the reader now places it');
  assert.throws(() => helper.prepareClaims({ ...scope, previous: { ...scope.previous, claims: 'none' } }, s.write('broken', manifestOf([['T01', raw, 'a.js']])), ''),
    /were rewritten or removed from the run log/);
});

test('a tree the fingerprint cannot measure seals its reason, is disclosed, and stays fresh while the reason holds', (t) => {
  const f = fixture(t);
  const bulk = path.join(f.root, 'bulk');
  fs.mkdirSync(bulk);
  for (let index = 0; index <= 20000; index += 1) fs.writeFileSync(path.join(bulk, `f${index}`), '');
  const audit = f.audit();
  assert.match(audit.stdout,
    /^TREE UNVERIFIED — more than 20000 untracked files; the receipt binds the run log and the claimed files, not the rest of the working tree\.$/m);
  assert.deepEqual(f.load().auditScope.tree, { kind: 'git', tree: null, reason: 'more than 20000 untracked files' });
  const fresh = f.check(0);
  assert.match(fresh.stdout, /EDIT LANDING RECEIPT FRESH — the receipt is clean and still describes the run log and the claimed files\./);
  assert.match(fresh.stderr, /^TREE UNVERIFIED — more than 20000 untracked files;/m);
  fs.writeFileSync(path.join(bulk, 'f0'), 'outside every claim\n');
  f.check(0);
  fs.writeFileSync(path.join(f.root, 'a.js'), 'changed again\n');
  assert.match(f.check(1).stderr, /a claimed file changed after the receipt/);
});

test('a sealed unmeasured tree is stale once its reason changes, and a git failure stays a fault', (t) => {
  const f = fixture(t);
  f.audit();
  const receipt = f.load();
  receipt.auditScope.tree = { kind: 'git', tree: null, reason: 'more than 20000 untracked files' };
  fs.writeFileSync(f.receipt, JSON.stringify(receipt));
  const manifest = path.join(f.base, 'manifest');
  fs.writeFileSync(manifest, manifestOf(receipt.auditScope.claims.map((claim) => [claim.step, claim.raw, claim.path || ''])));
  const evidence = require(path.join(LIB_DIR, 'evidence-run-v1.js'));
  const original = evidence.computeTree;
  t.after(() => { evidence.computeTree = original; });
  const env = { ZENSU_ELR_RECEIPT: f.receipt, ZENSU_ELR_PROJECT_ROOT: f.root, ZENSU_ELR_SESSION: f.session, ZENSU_ELR_MANIFEST: manifest, ZENSU_ELR_BARE_WIRED: '0' };
  const fresh = () => {
    const out = sink();
    const err = sink();
    return { code: helper.main(['fresh'], env, out, err), out: out.text(), err: err.text() };
  };
  evidence.computeTree = () => ({ tree: null, reason: 'more than 20000 untracked files', limited: true });
  const held = fresh();
  assert.equal(held.code, 0, held.err);
  assert.equal(held.err, `${helper.treeUnverifiedLine('more than 20000 untracked files')}\n`);
  evidence.computeTree = () => ({ tree: null, reason: 'untracked files exceed 512 MiB', limited: true });
  const moved = fresh();
  assert.equal(moved.code, 1);
  assert.match(moved.err, /the working tree changed after the receipt/);
  evidence.computeTree = () => ({ tree: null, reason: 'git write-tree failed' });
  assert.match(fresh().err, /EDIT LANDING RECEIPT STALE — the current tree is unavailable: git write-tree failed/);
});

test('receiptFile names the receipt the audit writes, and tree-note speaks only for an unmeasured tree', (t) => {
  const f = fixture(t);
  f.audit();
  assert.equal(helper.receiptFile(f.root, f.key), f.receipt);
  assert.ok(helper.RECEIPT_NAME_RE.test(path.basename(f.receipt)));
  for (const bad of ['', 'a/b', 'a\\b', 'a\nb', undefined]) {
    assert.throws(() => helper.receiptFile(f.root, bad), /needs a resolved session key/, JSON.stringify(bad));
  }
  const note = (file) => {
    const out = sink();
    return { code: helper.main(['tree-note'], { ZENSU_ELR_RECEIPT: file }, out, sink()), out: out.text() };
  };
  assert.deepEqual(note(f.receipt), { code: 0, out: '' });
  const receipt = f.load();
  receipt.auditScope.tree = { kind: 'git', tree: null, reason: 'more than 20000 untracked files' };
  fs.writeFileSync(f.receipt, JSON.stringify(receipt));
  assert.deepEqual(note(f.receipt), { code: 0, out: `${helper.treeUnverifiedLine('more than 20000 untracked files')}\n` });
  assert.equal(note(path.join(f.base, 'absent.json')).code, helper.EXIT.none);
});

function writeProofs(f, entries, file = 'a.js') {
  const content = fs.readFileSync(path.join(f.root, file));
  fs.writeFileSync(f.proof, JSON.stringify({
    schema: helper.PREDICATE_SCHEMA,
    claims: entries.map((entry) => ({ path: file, sha256: hash(content), ...entry })),
  }));
  return f.proof;
}

function replacedClaim(t) {
  const f = fixture(t);
  f.audit();
  fs.writeFileSync(path.join(f.root, 'a.js'), 'neutral\n');
  fs.appendFileSync(f.log, 'R1-F9 IMPL completed — files: a.js\n');
  return f;
}

const REPLACING = { step: 'R1-F9', present: ['neutral'] };
const REPLACED = { step: 'T01', absent: ['after'], supersededBy: 'R1-F9' };
const landingFlags = (f) => f.load().auditScope.claims.map((claim) => claim.landedOnce === true);

test('a certified claim whose edit a later proven claim removed is graded superseded with a supersede proof', (t) => {
  const f = replacedClaim(t);
  const pending = f.audit([], 1);
  assert.match(pending.stdout, /^PENDING PREDICATE — T01: a\.js /m);
  assert.match(pending.stdout, /^PENDING PREDICATE — R1-F9: a\.js /m);
  assert.equal(f.load().pending, 2);
  assert.deepEqual(landingFlags(f), [true, true]);
  const result = f.audit(['--predicates', writeProofs(f, [REPLACING, REPLACED])]);
  assert.match(result.stdout, /^EDIT SUPERSEDED — T01: a\.js, replaced by R1-F9$/m);
  assert.match(result.stdout, /^EDIT LANDED \(verified predicate or unchanged prior certification\) — R1-F9: a\.js$/m);
  assert.match(result.stdout,
    /^EDIT LANDING AUDIT — claims=2 landed=2 not_landed=0 unverified=0 pending=0 exempt_ignored=0 exempt_verified=0 exempt_superseded=1$/m);
  const receipt = f.load();
  assert.equal(receipt.clean, true);
  assert.equal(receipt.claims, 2);
  assert.equal(receipt.landed, 2);
  assert.equal(receipt.exemptSuperseded, 1);
  assert.deepEqual(receipt.auditScope.claims.map(({ step, certified, supersededBy, landedOnce }) => ({ step, certified, supersededBy, landedOnce })), [
    { step: 'T01', certified: false, supersededBy: 'R1-F9', landedOnce: true },
    { step: 'R1-F9', certified: true, supersededBy: undefined, landedOnce: undefined },
  ]);
  assert.match(f.check(0).stdout, /EDIT LANDING RECEIPT FRESH/);
});

test('a later audit keeps a claim superseded while the bytes are unchanged and grades it pending again once they change', (t) => {
  const f = replacedClaim(t);
  f.audit(['--predicates', writeProofs(f, [REPLACING, REPLACED])]);
  const kept = f.audit();
  assert.match(kept.stdout, /^EDIT SUPERSEDED — T01: a\.js, replaced by R1-F9$/m);
  assert.equal(f.load().exemptSuperseded, 1);
  assert.equal(f.load().clean, true);
  f.check(0);
  fs.writeFileSync(path.join(f.root, 'a.js'), 'neutral again\n');
  assert.match(f.check(1).stderr, /a claimed file changed after the receipt/);
  const changed = f.audit([], 1);
  assert.match(changed.stdout, /^PENDING PREDICATE — T01: a\.js /m);
  assert.doesNotMatch(changed.stdout, /EDIT SUPERSEDED|exempt_superseded/);
  assert.equal(f.load().pending, 2);
  assert.equal('exemptSuperseded' in f.load(), false);
  assert.equal(f.load().auditScope.claims[0].supersededBy, undefined);
  assert.deepEqual(landingFlags(f), [true, true]);
  f.audit(['--predicates', writeProofs(f, [{ step: 'R1-F9', present: ['neutral again'] }, REPLACED])]);
  assert.equal(f.load().exemptSuperseded, 1);
  f.check(0);
});

test('a supersede proof fails the audit with its own sentence for every rule it breaks', (t) => {
  const refused = (f, entries, pattern) => {
    const result = f.audit(['--predicates', writeProofs(f, entries)], 2);
    assert.match(result.stderr, pattern);
    assert.doesNotMatch(result.stdout, /EDIT SUPERSEDED|EDIT LANDED/);
    assert.equal(f.load().clean, false);
  };
  const f = replacedClaim(t);
  refused(f, [REPLACING, { ...REPLACED, supersededBy: 'T01' }], /names its own step as the replacing step/);
  refused(f, [REPLACING, { ...REPLACED, present: ['neutral'] }], /a supersede proof carries no present literal/);
  refused(f, [REPLACING, { step: 'T01', supersededBy: 'R1-F9' }], /a supersede proof needs at least one absent literal/);
  refused(f, [REPLACING, { ...REPLACED, supersededBy: '' }], /needs the exact step label of the replacing claim/);
  refused(f, [REPLACING, { ...REPLACED, supersededBy: 'R9-F9' }], /names a replacing step with no later claim on that file/);
  refused(f, [REPLACED], /names a replacing claim that is not landed in this audit/);
  refused(f, [REPLACING, { step: 'T01', absent: ['after'] }, REPLACED], /names a claim that is landed; a landed claim needs no supersede/);
  refused(f, [REPLACING, { ...REPLACED, absent: ['neutral'] }], /a literal predicate does not hold/);
  f.audit(['--predicates', writeProofs(f, [REPLACING, REPLACED])]);
  assert.equal(f.load().exemptSuperseded, 1, 'the refusals left the scope a valid proof still closes');

  const certified = fixture(t);
  certified.audit();
  fs.appendFileSync(certified.log, 'R1-F9 IMPL completed — files: a.js\n');
  refused(certified, [{ step: 'R1-F9', present: ['after'] }, { step: 'T01', absent: ['before'], supersededBy: 'R1-F9' }],
    /names a claim that is landed; a landed claim needs no supersede/);

  const earlier = fixture(t);
  fs.writeFileSync(earlier.log, 'R0 IMPL completed — files: a.js\nT01 IMPL completed — files: a.js\n');
  earlier.audit();
  fs.writeFileSync(path.join(earlier.root, 'a.js'), 'neutral\n');
  refused(earlier, [{ step: 'R0', present: ['neutral'] }, { ...REPLACED, supersededBy: 'R0' }],
    /names a replacing step with no later claim on that file/);

  const unlanded = fixture(t);
  unlanded.audit(['--dirty-before', unlanded.dirty], 1);
  fs.writeFileSync(path.join(unlanded.root, 'a.js'), 'neutral\n');
  fs.appendFileSync(unlanded.log, 'R1-F9 IMPL completed — files: a.js\n');
  refused(unlanded, [REPLACING, REPLACED], /names a claim for which this audit scope records no landing/);
});

test('a fix-round claim gains landing evidence in the audit that first sees it only when its file changed and no other step newly claims it', (t) => {
  const f = fixture(t);
  f.audit();
  fs.appendFileSync(f.log, 'R1-F1 IMPL completed — files: a.js\n');
  f.audit([], 1);
  assert.deepEqual(landingFlags(f), [false, false], 'an unchanged file is no evidence for the claim that first names it');
  fs.writeFileSync(path.join(f.root, 'a.js'), 'after\nround two\n');
  fs.appendFileSync(f.log, 'R2-F1 IMPL completed — files: a.js\n');
  f.audit([], 1);
  assert.deepEqual(landingFlags(f), [true, false, true]);

  const shared = fixture(t);
  shared.audit();
  fs.writeFileSync(path.join(shared.root, 'a.js'), 'after\nshared\n');
  fs.appendFileSync(shared.log, 'R1-F1 IMPL completed — files: a.js\nR1-F2 IMPL completed — files: a.js\n');
  shared.audit([], 1);
  assert.deepEqual(landingFlags(shared), [true, false, false], 'two steps that newly claim one file share no evidence');
});

test('a later fix that removes an earlier fix supersedes it through the landing evidence of the round that made it', (t) => {
  const f = fixture(t);
  f.audit();
  fs.writeFileSync(path.join(f.root, 'a.js'), 'after\nround one\n');
  fs.appendFileSync(f.log, 'R1-F1 IMPL completed — files: a.js\n');
  f.audit([], 1);
  fs.writeFileSync(path.join(f.root, 'a.js'), 'after\nround two\n');
  fs.appendFileSync(f.log, 'R2-F1 IMPL completed — files: a.js\n');
  f.audit([], 1);
  assert.equal(f.load().pending, 3);
  const result = f.audit(['--predicates', writeProofs(f, [
    { step: 'T01', present: ['after'], absent: ['before'] },
    { step: 'R2-F1', present: ['round two'] },
    { step: 'R1-F1', absent: ['round one'], supersededBy: 'R2-F1' },
  ])]);
  assert.match(result.stdout, /^EDIT SUPERSEDED — R1-F1: a\.js, replaced by R2-F1$/m);
  assert.match(result.stdout, /claims=3 landed=3 .* exempt_superseded=1$/m);
  f.check(0);
});

test('a file a later step deleted supersedes the claim that created it through the deletion form', (t) => {
  const f = fixture(t);
  fs.mkdirSync(path.join(f.root, 'src'));
  fs.writeFileSync(path.join(f.root, 'src', 'gone.js'), 'created\n');
  fs.writeFileSync(f.log, 'T01 IMPL completed — files: src/gone.js\n');
  f.audit();
  fs.unlinkSync(path.join(f.root, 'src', 'gone.js'));
  fs.appendFileSync(f.log, 'R1-F2 IMPL completed — files: src/gone.js\n');
  const deletion = (extra) => {
    fs.writeFileSync(f.proof, JSON.stringify({ schema: helper.PREDICATE_SCHEMA, claims: [
      { step: 'R1-F2', path: 'src/gone.js', missing: true },
      { step: 'T01', path: 'src/gone.js', missing: true, supersededBy: 'R1-F2', ...extra },
    ] }));
    return f.proof;
  };
  assert.match(f.audit(['--predicates', deletion({ sha256: '0'.repeat(64) })], 2).stderr,
    /a deletion proof carries only step, path, missing and supersededBy/);
  const result = f.audit(['--predicates', deletion({})]);
  assert.match(result.stdout, /^EDIT SUPERSEDED — T01: src\/gone\.js, replaced by R1-F2$/m);
  assert.equal(f.load().exemptSuperseded, 1);
  assert.equal(f.load().clean, true);
  f.check(0);
});

test('a chain without a supersede proof keeps its tally line, its receipt keys and its claim entries', (t) => {
  const f = fixture(t);
  const first = f.audit();
  assert.match(first.stdout, /^EDIT LANDING AUDIT — claims=1 landed=1 not_landed=0 unverified=0 pending=0 exempt_ignored=0 exempt_verified=0$/m);
  const receipt = f.load();
  assert.deepEqual(Object.keys(receipt),
    ['schema', 'session', 'log', 'claims', 'landed', 'notLanded', 'unverified', 'pending', 'exemptIgnored', 'exemptVerified', 'clean', 'auditScope']);
  assert.deepEqual(Object.keys(receipt.auditScope.claims[0]), ['step', 'raw', 'path', 'certified']);
  assert.equal('superseded' in receipt.auditScope, false);
  assert.equal('landedOnce' in receipt.auditScope, false);
  fs.writeFileSync(path.join(f.root, 'a.js'), 'after second\n');
  fs.appendFileSync(f.log, 'SR1 IMPL completed — files: a.js\n');
  const second = f.audit(['--predicates', f.putProof(['T01', 'SR1'], { present: ['after second'] })]);
  assert.doesNotMatch(second.stdout, /EDIT SUPERSEDED|exempt_superseded/);
  assert.equal('exemptSuperseded' in f.load(), false);
  assert.deepEqual(f.load().auditScope.claims.map((claim) => Object.keys(claim)), [
    ['step', 'raw', 'path', 'certified'],
    ['step', 'raw', 'path', 'certified'],
  ]);
});
