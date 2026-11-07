'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const auth = require('../../hooks/lib/verify-auth-state-v1.js');

const { FAULTS } = auth;
const POSIX = process.platform !== 'win32';
const ORIGIN = 'http://127.0.0.1:4310';
const SECRET = 'eyJhbGciOiJIUzI1NiJ9.secret-token-value';

function tempDir(t, prefix = 'zensu-auth-state-') {
  const dir = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function runDir(t, leaf = 'run1') {
  const root = tempDir(t);
  const dir = path.join(root, '.zensu', 'verify-feature-runs', leaf);
  fs.mkdirSync(dir, { recursive: true });
  return { root, dir: fs.realpathSync.native(dir) };
}

function cookie(overrides = {}) {
  return { name: 'sid', value: SECRET, domain: '127.0.0.1', path: '/', expires: -1, httpOnly: true, secure: false, sameSite: 'Lax', ...overrides };
}

function state(overrides = {}) {
  return { cookies: [cookie()], origins: [{ origin: ORIGIN, localStorage: [{ name: 'token', value: SECRET }] }], ...overrides };
}

function writeState(dir, value, mode = 0o600) {
  const authDir = path.join(dir, auth.AUTH_DIR_NAME);
  fs.mkdirSync(authDir, { recursive: true, mode: 0o700 });
  const file = path.join(authDir, auth.STATE_FILE_NAME);
  fs.writeFileSync(file, typeof value === 'string' ? value : JSON.stringify(value), { mode });
  if (POSIX) fs.chmodSync(file, mode);
  return file;
}

test('the module names one canonical layout, one session prefix and the caps of the specification', () => {
  assert.equal(auth.AUTH_DIR_NAME, 'auth');
  assert.equal(auth.STATE_FILE_NAME, 'storage-state.json');
  assert.equal(auth.ARTIFACT_DIR_NAME, 'artifact');
  assert.equal(auth.IGNORE_FILE_NAME, '.gitignore');
  assert.equal(auth.IGNORE_BODY, '*\n');
  assert.equal(auth.RUNS_DIR_NAME, 'verify-feature-runs');
  assert.equal(auth.ZENSU_DIR_NAME, '.zensu');
  assert.equal(auth.AUTH_SESSION_PREFIX, 'zensu-verify-auth-');
  assert.equal(auth.STATE_LINE_KEY, 'STORAGE_STATE');
  assert.equal(auth.MAX_STATE_BYTES, 1048576);
  assert.equal(auth.MAX_COOKIES, 256);
  assert.equal(auth.MAX_ORIGINS, 64);
  assert.equal(auth.isAuthSession('zensu-verify-auth-run1'), true);
  for (const other of ['zensu-verify-run1', 'zensu-verify-authx', 'Zensu-verify-auth-x', '', null, undefined, 7]) {
    assert.equal(auth.isAuthSession(other), false, String(other));
  }
});

test('a cookie domain matches its own host, and a dotted domain also matches every subdomain but never an address', () => {
  const rows = [
    ['127.0.0.1', '127.0.0.1', true],
    ['localhost', 'localhost', true],
    ['LOCALHOST', 'localhost', true],
    ['localhost', '127.0.0.1', false],
    ['app.example.com', 'app.example.com', true],
    ['.example.com', 'example.com', true],
    ['.example.com', 'app.example.com', true],
    ['example.com', 'app.example.com', false],
    ['.example.com', 'badexample.com', false],
    ['.0.0.1', '127.0.0.1', false],
    ['.', 'example.com', false],
    ['', 'example.com', false],
    ['::1', '::1', true],
  ];
  for (const [domain, host, expected] of rows) assert.equal(auth.domainMatches(domain, host), expected, `${domain} ${host}`);
});

test('storage state parses only the cookie and localStorage shape Playwright writes, and a parse fault never carries the input', () => {
  assert.equal(auth.parseState(JSON.stringify(state())).ok, true);
  assert.deepEqual(auth.parseState('{}').state, { cookies: [], origins: [] });
  const notJson = auth.parseState(SECRET);
  assert.deepEqual(notJson, { ok: false, fault: FAULTS.NOT_JSON });
  assert.equal(JSON.stringify(notJson).includes('eyJ'), false);
  const shapes = [
    state({ credentials: [] }),
    state({ extra: true }),
    state({ cookies: [cookie({ domain: undefined })] }),
    state({ cookies: [cookie({ url: 'http://127.0.0.1/' })] }),
    state({ cookies: [cookie({ name: '' })] }),
    state({ cookies: [cookie({ domain: 'http://127.0.0.1' })] }),
    state({ cookies: [cookie({ sameSite: 'lax' })] }),
    state({ cookies: [cookie({ httpOnly: 'yes' })] }),
    state({ cookies: [cookie({ expires: '1' })] }),
    state({ cookies: [cookie({ value: 7 })] }),
    state({ cookies: {} }),
    state({ origins: [{ origin: ORIGIN, localStorage: [], indexedDB: [] }] }),
    state({ origins: [{ origin: `${ORIGIN}/`, localStorage: [] }] }),
    state({ origins: [{ origin: ORIGIN }] }),
    state({ origins: [{ origin: ORIGIN, localStorage: [{ name: 'a', value: 1 }] }] }),
    state({ origins: [{ origin: ORIGIN, localStorage: [{ name: 'a', value: 'b', extra: 1 }] }] }),
    state({ cookies: Array.from({ length: 257 }, (_value, index) => cookie({ name: `c${index}` })) }),
    state({ origins: Array.from({ length: 65 }, () => ({ origin: ORIGIN, localStorage: [] })) }),
    [],
    null,
    'text',
  ];
  for (const value of shapes) {
    assert.deepEqual(auth.parseState(JSON.stringify(value)), { ok: false, fault: FAULTS.SHAPE }, JSON.stringify(value).slice(0, 80));
  }
  assert.deepEqual(auth.parseState(' '.repeat(auth.MAX_STATE_BYTES + 1)), { ok: false, fault: FAULTS.TOO_LARGE });
  assert.equal(auth.parseState(JSON.stringify(state({ cookies: Array.from({ length: 256 }, (_value, index) => cookie({ name: `c${index}` })) }))).ok, true);
});

test('scope keeps only cookies for a run host and origins equal to a run origin, and an out-of-scope entry fails the scope check', () => {
  const mixed = state({
    cookies: [cookie(), cookie({ name: 'other', domain: 'tracker.example.net' }), cookie({ name: 'any', domain: 'localhost' })],
    origins: [{ origin: ORIGIN, localStorage: [] }, { origin: 'https://other.example.net', localStorage: [] }],
  });
  assert.equal(auth.inScope(mixed, [ORIGIN]), false);
  const scoped = auth.scopeState(mixed, [ORIGIN]);
  assert.deepEqual(scoped.cookies.map((item) => item.name), ['sid']);
  assert.deepEqual(scoped.origins.map((item) => item.origin), [ORIGIN]);
  assert.equal(auth.inScope(scoped, [ORIGIN]), true);
  assert.equal(auth.inScope(mixed, [ORIGIN, 'http://localhost:4310', 'https://tracker.example.net', 'https://other.example.net']), true);
  assert.equal(auth.emptyState(auth.scopeState(mixed, ['https://unrelated.example.org'])), true);
  assert.equal(auth.emptyState({ cookies: [], origins: [] }), true);
  assert.equal(auth.emptyState(scoped), false);
});

test('a state file passes only as a private regular single-link file inside a real auth directory, within its origins', (t) => {
  const { dir } = runDir(t);
  const file = writeState(dir, state());
  assert.equal(auth.checkStateFile(file, [ORIGIN]).ok, true);
  assert.deepEqual(auth.checkStateFile(file, ['http://127.0.0.2:4310']), { ok: false, fault: FAULTS.SCOPE });
  writeState(dir, { cookies: [], origins: [] });
  assert.deepEqual(auth.checkStateFile(file, [ORIGIN]), { ok: false, fault: FAULTS.EMPTY });
  writeState(dir, SECRET);
  assert.deepEqual(auth.checkStateFile(file, [ORIGIN]), { ok: false, fault: FAULTS.NOT_JSON });
  fs.rmSync(file);
  assert.deepEqual(auth.checkStateFile(file, [ORIGIN]), { ok: false, fault: FAULTS.MISSING });
  assert.deepEqual(auth.checkStateFile(path.join(dir, 'nowhere', auth.STATE_FILE_NAME), [ORIGIN]), { ok: false, fault: FAULTS.MISSING });
  if (!POSIX) return;
  writeState(dir, state(), 0o644);
  assert.deepEqual(auth.checkStateFile(file, [ORIGIN]), { ok: false, fault: FAULTS.UNSAFE });
  writeState(dir, state());
  const second = path.join(dir, 'second-link.json');
  fs.linkSync(file, second);
  assert.deepEqual(auth.checkStateFile(file, [ORIGIN]), { ok: false, fault: FAULTS.UNSAFE });
  fs.rmSync(second);
  const elsewhere = path.join(dir, 'elsewhere.json');
  fs.renameSync(file, elsewhere);
  fs.symlinkSync(elsewhere, file);
  assert.deepEqual(auth.checkStateFile(file, [ORIGIN]), { ok: false, fault: FAULTS.UNSAFE });
  fs.rmSync(file);
  fs.rmSync(elsewhere);
  const fifo = spawnSync('mkfifo', [file]);
  if (fifo.status === 0) assert.deepEqual(auth.checkStateFile(file, [ORIGIN]), { ok: false, fault: FAULTS.UNSAFE });
  fs.rmSync(file, { force: true });
  const realAuth = path.join(dir, 'real-auth');
  fs.renameSync(path.join(dir, auth.AUTH_DIR_NAME), realAuth);
  fs.symlinkSync(realAuth, path.join(dir, auth.AUTH_DIR_NAME));
  fs.writeFileSync(path.join(realAuth, auth.STATE_FILE_NAME), JSON.stringify(state()), { mode: 0o600 });
  assert.deepEqual(auth.checkStateFile(file, [ORIGIN]), { ok: false, fault: FAULTS.UNSAFE });
});

test('the run directory layout is exactly <root>/.zensu/verify-feature-runs/<leaf>', () => {
  const root = path.resolve(os.tmpdir(), 'project');
  const good = path.join(root, '.zensu', 'verify-feature-runs', 'abc');
  assert.deepEqual(auth.runDirLayout(good), { ok: true, projectRoot: root, runsDir: path.dirname(good) });
  for (const bad of [
    path.join(root, '.zensu', 'verify-feature-runs'),
    path.join(root, 'zensu', 'verify-feature-runs', 'abc'),
    path.join(root, '.zensu', 'runs', 'abc'),
    path.join(root, '.zensu', 'verify-feature-runs', 'abc', 'deeper'),
    'relative/.zensu/verify-feature-runs/abc',
    '',
    null,
  ]) {
    assert.equal(auth.runDirLayout(bad).ok, false, String(bad));
  }
  assert.equal(auth.statePathFor(good), path.join(good, 'auth', 'storage-state.json'));
});

test('preparing the auth directory makes it private, ignores everything in it and starts a fresh artifact directory', (t) => {
  const { dir } = runDir(t);
  const prepared = auth.prepareAuthDir(dir);
  assert.equal(prepared.authDir, path.join(dir, 'auth'));
  assert.equal(prepared.artifactDir, path.join(dir, 'auth', 'artifact'));
  assert.equal(prepared.statePath, path.join(dir, 'auth', 'storage-state.json'));
  assert.equal(fs.readFileSync(path.join(dir, 'auth', '.gitignore'), 'utf8'), '*\n');
  assert.equal(fs.lstatSync(prepared.artifactDir).isDirectory(), true);
  if (POSIX) {
    assert.equal(fs.statSync(prepared.authDir).mode & 0o777, 0o700);
    assert.equal(fs.statSync(prepared.artifactDir).mode & 0o777, 0o700);
  }
  fs.writeFileSync(path.join(prepared.artifactDir, 'left.json'), 'x');
  fs.writeFileSync(prepared.statePath, 'stale', { mode: 0o600 });
  fs.writeFileSync(path.join(prepared.authDir, '.storage-state.json.0123456789ab.tmp'), 'temp');
  auth.prepareAuthDir(dir);
  assert.equal(fs.existsSync(prepared.statePath), false);
  assert.deepEqual(fs.readdirSync(prepared.artifactDir), []);
  assert.deepEqual(fs.readdirSync(prepared.authDir).sort(), ['.gitignore', 'artifact']);
  fs.writeFileSync(path.join(prepared.authDir, 'foreign.txt'), 'x');
  assert.throws(() => auth.prepareAuthDir(dir), /entries this helper did not write/);
  fs.rmSync(path.join(prepared.authDir, 'foreign.txt'));
  fs.writeFileSync(path.join(prepared.authDir, '.gitignore'), '!keep\n');
  assert.throws(() => auth.prepareAuthDir(dir), /ignore file this helper did not write/);
  fs.rmSync(prepared.authDir, { recursive: true, force: true });
  if (POSIX) {
    const target = path.join(dir, 'target');
    fs.mkdirSync(target);
    fs.symlinkSync(target, prepared.authDir);
    assert.throws(() => auth.prepareAuthDir(dir), /not a plain directory/);
  }
});

test('the state file is written owner-only through a rename, and the canonical file is consumed once', (t) => {
  const { dir } = runDir(t);
  const prepared = auth.prepareAuthDir(dir);
  const written = auth.writeStateFile(prepared.statePath, state());
  assert.deepEqual(written, { ok: true, file: prepared.statePath });
  assert.deepEqual(JSON.parse(fs.readFileSync(prepared.statePath, 'utf8')), state());
  if (POSIX) assert.equal(fs.statSync(prepared.statePath).mode & 0o777, 0o600);
  assert.deepEqual(fs.readdirSync(prepared.authDir).sort(), ['.gitignore', 'artifact', 'storage-state.json']);
  assert.equal(auth.checkStateFile(prepared.statePath, [ORIGIN]).ok, true);
  const config = path.join(dir, 'playwright-cli.json');
  fs.writeFileSync(config, '{}');
  assert.deepEqual(auth.consumeStateFile(config), { removed: true, file: prepared.statePath });
  assert.equal(fs.existsSync(prepared.statePath), false);
  assert.deepEqual(auth.consumeStateFile(config), { removed: false, reason: 'absent' });
  const outside = tempDir(t, 'zensu-auth-outside-');
  fs.mkdirSync(path.join(outside, 'auth'));
  fs.writeFileSync(path.join(outside, 'auth', 'storage-state.json'), 'x');
  assert.deepEqual(auth.consumeStateFile(path.join(outside, 'playwright-cli.json')), { removed: false, reason: 'no-run-directory' });
  assert.equal(fs.existsSync(path.join(outside, 'auth', 'storage-state.json')), true);
  assert.deepEqual(auth.writeStateFile(prepared.statePath, { cookies: [cookie({ value: 'x'.repeat(auth.MAX_STATE_BYTES) })], origins: [] }), { ok: false, fault: FAULTS.TOO_LARGE });
});

test('the login contract is exactly one STORAGE_STATE line, and only a single-link regular file physically inside the artifact directory is accepted', (t) => {
  for (const good of ['STORAGE_STATE=/x/state.json', 'STORAGE_STATE=/x/state.json\n', 'STORAGE_STATE=/x/state.json\r\n']) {
    assert.deepEqual(auth.artifactLine(good), { ok: true, value: '/x/state.json' }, JSON.stringify(good));
  }
  for (const bad of ['', '\n', 'STORAGE_STATE=', 'STORAGE_STATE=/x\nextra', 'note\nSTORAGE_STATE=/x', 'storage_state=/x', ' STORAGE_STATE=/x', 'STORAGE_STATE=/x\n\n', 'TOKEN=/x', null]) {
    assert.equal(auth.artifactLine(bad).ok, false, JSON.stringify(bad));
  }
  const { dir } = runDir(t);
  const prepared = auth.prepareAuthDir(dir);
  const direct = path.join(prepared.artifactDir, 'state.json');
  fs.writeFileSync(direct, '{}');
  assert.deepEqual(auth.artifactFile(direct, prepared.artifactDir), { ok: true, file: direct });
  const nested = path.join(prepared.artifactDir, 'nested', 'deeper');
  fs.mkdirSync(nested, { recursive: true });
  fs.writeFileSync(path.join(nested, 's.json'), '{}');
  assert.equal(auth.artifactFile(path.join(nested, 's.json'), prepared.artifactDir).ok, true);
  assert.equal(auth.artifactFile('relative/state.json', prepared.artifactDir).ok, false);
  assert.equal(auth.artifactFile(path.join(prepared.artifactDir, 'missing.json'), prepared.artifactDir).ok, false);
  assert.equal(auth.artifactFile(path.join(prepared.artifactDir, '..', 'storage-state.json'), prepared.artifactDir).ok, false);
  const outside = tempDir(t, 'zensu-auth-artifact-outside-');
  fs.writeFileSync(path.join(outside, 'state.json'), '{}');
  assert.equal(auth.artifactFile(path.join(outside, 'state.json'), prepared.artifactDir).ok, false);
  if (!POSIX) return;
  fs.symlinkSync(path.join(outside, 'state.json'), path.join(prepared.artifactDir, 'link.json'));
  assert.equal(auth.artifactFile(path.join(prepared.artifactDir, 'link.json'), prepared.artifactDir).ok, false);
  fs.symlinkSync(outside, path.join(prepared.artifactDir, 'escape'));
  assert.equal(auth.artifactFile(path.join(prepared.artifactDir, 'escape', 'state.json'), prepared.artifactDir).ok, false);
  fs.linkSync(direct, path.join(prepared.artifactDir, 'hard.json'));
  assert.equal(auth.artifactFile(direct, prepared.artifactDir).ok, false);
});
