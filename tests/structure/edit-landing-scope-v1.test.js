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
  assert.match(f.check(1).stderr, /did not complete/);
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
});

test('--check-receipt refuses a missing, pending or interrupted receipt and its own malformed operands', (t) => {
  const f = fixture(t);
  assert.match(f.check(1).stderr, /no edit-landing receipt exists/);
  f.audit(['--dirty-before', f.dirty], 1);
  const pending = f.check(1);
  assert.match(pending.stderr, /EDIT LANDING RECEIPT STALE — the receipt is not clean/);
  assert.match(pending.stderr, /^Run: /m);
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
  const verify = (file) => [...helper.verifyPredicates(s.base, file, prepared.claims, prepared.snapshots, new Set(['a.js']), '')];
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
  assert.throws(() => helper.prepareClaims(scope, s.write('rewritten', manifestOf([['T01', 'T01 IMPL completed — files: b.js', 'b.js']])), ''),
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
