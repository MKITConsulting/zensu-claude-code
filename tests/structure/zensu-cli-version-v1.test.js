'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const MODULE = path.resolve(__dirname, '../../hooks/lib/zensu-cli-version-v1.js');
const cli = require(MODULE);
const POSIX = process.platform !== 'win32';

function tempDir(t) {
  const dir = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-cli-floor-')));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function fakeZensu(t, body) {
  const root = tempDir(t);
  const bin = path.join(root, 'bin');
  fs.mkdirSync(bin);
  const log = path.join(root, 'calls.log');
  const binary = path.join(bin, 'zensu');
  fs.writeFileSync(binary, `#!/bin/sh\nprintf '%s|%s\\n' "\${ZENSU_NO_UPDATE_CHECK:-unset}" "$*" >> '${log}'\n${body}\n`, { mode: 0o755 });
  return { root, bin, binary, log };
}

function calls(log) {
  return fs.existsSync(log) ? fs.readFileSync(log, 'utf8').split('\n').filter(Boolean) : [];
}

function collect() {
  let text = '';
  return { write(chunk) { text += chunk; return true; }, text: () => text };
}

test('the floor is zensu-cli 0.10.0 and the install commands are the four published ones', () => {
  assert.equal(cli.MIN_VERSION, '0.10.0');
  assert.deepEqual(cli.INSTALL, {
    homebrew: 'brew install --cask mkitconsulting/tap/zensu',
    homebrewUpgrade: 'brew upgrade --cask zensu',
    script: 'curl -fsSL https://zensu.dev/install.sh | sh',
    powershell: 'irm https://zensu.dev/install.ps1 | iex',
  });
  assert.ok(Object.isFrozen(cli.INSTALL));
  assert.match(cli.FLOOR_REASON, /^[a-z][^\n.]*[a-z]$/);
});

test('the version is read from the first word after zensu on the version line', () => {
  const cases = [
    ['zensu 0.10.0 (commit 4c4f4eb, built 2026-10-17T10:00:00Z)', '0.10.0'],
    ['zensu v0.10.1 (commit abc, built now)', '0.10.1'],
    ['zensu 0.10.0-rc.1 (commit abc, built now)', '0.10.0-rc.1'],
    ['zensu 1.2.3+build.7 (commit abc, built now)', '1.2.3+build.7'],
    ['zensu dev (commit none, built unknown)', 'dev'],
    ['zensu 0.10.0', '0.10.0'],
    ['zensu 0.10 (commit abc, built now)', ''],
    ['zensu version 0.10.0', ''],
    ['playwright-cli 0.10.0', ''],
    [' zensu 0.10.0 (commit abc, built now)', ''],
    ['zensu developer (commit none, built unknown)', ''],
    ['', ''],
    [undefined, ''],
  ];
  for (const [line, expected] of cases) assert.equal(cli.parseVersionLine(line), expected, String(line));
});

test('a version below the floor is old, a prerelease of the floor included, and a development build is dev', () => {
  const cases = [
    ['0.9.0', 'old'],
    ['0.9.99', 'old'],
    ['0.10.0-rc.1', 'old'],
    ['0.10.0', 'ok'],
    ['0.10.0+build.5', 'ok'],
    ['0.10.1', 'ok'],
    ['0.11.0', 'ok'],
    ['1.0.0', 'ok'],
    ['dev', 'dev'],
    ['', 'unread'],
    ['0.10', 'unread'],
    ['x'.repeat(65), 'unread'],
  ];
  for (const [version, expected] of cases) assert.equal(cli.classify(version), expected, version);
});

test('prereleases order by their identifiers and sit below the release', () => {
  const ordered = ['0.10.0-alpha', '0.10.0-alpha.1', '0.10.0-alpha.beta', '0.10.0-beta', '0.10.0-beta.2', '0.10.0-beta.11', '0.10.0-rc.1', '0.10.0'];
  for (let index = 1; index < ordered.length; index += 1) {
    assert.equal(cli.compareVersions(ordered[index - 1], ordered[index]), -1, `${ordered[index - 1]} < ${ordered[index]}`);
    assert.equal(cli.compareVersions(ordered[index], ordered[index - 1]), 1, `${ordered[index]} > ${ordered[index - 1]}`);
  }
  assert.equal(cli.compareVersions('0.10.0', '0.10.0+build.1'), 0);
  assert.equal(cli.compareVersions('0.10.0', '0.9.10'), 1);
  assert.equal(cli.compareVersions('0.9.10', '0.10.0'), -1);
});

test('the probe runs zensu --version once with the update check switched off', { skip: !POSIX }, (t) => {
  const { binary, log } = fakeZensu(t, "printf 'zensu 0.9.0 (commit 4c4f4eb, built 2026-10-13T15:09:40Z)\\n'");
  assert.deepEqual(cli.probe({ binary, env: Object.assign({}, process.env, { ZENSU_NO_UPDATE_CHECK: '' }) }), { state: 'old', version: '0.9.0' });
  assert.deepEqual(calls(log), ['1|--version']);
});

test('a release at the floor is ok and a development build is dev', { skip: !POSIX }, (t) => {
  const release = fakeZensu(t, "printf 'zensu 0.10.0 (commit abc, built now)\\n'");
  assert.deepEqual(cli.probe({ binary: release.binary }), { state: 'ok', version: '0.10.0' });
  const dev = fakeZensu(t, "printf 'zensu dev (commit none, built unknown)\\n'");
  assert.deepEqual(cli.probe({ binary: dev.binary }), { state: 'dev', version: 'dev' });
});

test('output without a version line, a version on a later line or a failing binary is unread', { skip: !POSIX }, (t) => {
  for (const body of ["printf 'something else\\n'", "printf '\\nzensu 0.10.0 (commit abc, built now)\\n'", 'exit 1', "printf 'zensu 0.10.0 (commit abc, built now)\\n' >&2"]) {
    const { binary } = fakeZensu(t, body);
    assert.deepEqual(cli.probe({ binary }), { state: 'unread', version: '' }, body);
  }
});

test('a hanging binary is killed at the timeout and reads as unread', { skip: !POSIX }, (t) => {
  const { binary } = fakeZensu(t, 'sleep 5');
  const started = Date.now();
  assert.deepEqual(cli.probe({ binary, timeoutMs: 200 }), { state: 'unread', version: '' });
  assert.ok(Date.now() - started < 4000, 'the probe returned before the binary finished');
});

test('a cmd or bat shim is never run on win32', (t) => {
  const root = tempDir(t);
  const log = path.join(root, 'ran');
  const shim = path.join(root, 'zensu.cmd');
  fs.writeFileSync(shim, `#!/bin/sh\ntouch '${log}'\n`, { mode: 0o755 });
  assert.deepEqual(cli.probe({ binary: shim, platform: 'win32' }), { state: 'unread', version: '' });
  assert.equal(fs.existsSync(log), false);
  assert.deepEqual(cli.probe({ binary: '' }), { state: 'absent', version: '' });
});

test('the lookup walks PATH and probes the first zensu it finds', { skip: !POSIX }, (t) => {
  const { bin, binary, log } = fakeZensu(t, "printf 'zensu 0.10.2 (commit abc, built now)\\n'");
  const empty = tempDir(t);
  const found = cli.installedVersion({ PATH: `${empty}:${bin}` }, 'linux', empty);
  assert.deepEqual(found, { state: 'ok', version: '0.10.2', binary });
  assert.deepEqual(calls(log), ['1|--version']);
  assert.deepEqual(cli.installedVersion({ PATH: empty }, 'linux', empty), { state: 'absent', version: '' });
});

test('an empty or relative PATH entry before zensu answers cwd-relative and runs nothing', { skip: !POSIX }, (t) => {
  const { root, bin, log } = fakeZensu(t, "printf 'zensu 0.10.0 (commit abc, built now)\\n'");
  for (const value of [`:${bin}`, `bin:${bin}`, `./bin`, `${tempDir(t)}::${bin}`]) {
    const found = cli.installedVersion({ PATH: value }, 'linux', root);
    assert.equal(found.state, 'cwd-relative', value);
    assert.equal(found.version, '');
  }
  assert.deepEqual(calls(log), []);
});

test('the PATH walk decides as the playwright-cli probe walk does over the same fixtures', { skip: !POSIX }, (t) => {
  const playwright = require(path.resolve(__dirname, '../../hooks/lib/playwright-cli-version-v1.js'));
  const work = tempDir(t);
  const abs = path.join(work, 'abs');
  const rel = path.join(work, 'rel', 'bin');
  const empty = path.join(work, 'empty');
  for (const dir of [abs, rel, empty]) fs.mkdirSync(dir, { recursive: true });
  for (const dir of [abs, rel, work]) {
    for (const name of ['zensu', 'playwright-cli']) fs.writeFileSync(path.join(dir, name), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  }
  const layouts = [[abs], [empty, abs], ['', abs], ['rel/bin', abs], [abs, '', 'rel/bin'], ['rel/bin'], [empty], [empty, 'rel/missing']];
  for (const layout of layouts) {
    const env = { PATH: layout.join(':') };
    const zensuFound = cli.findBinary(env, 'linux', work);
    const playwrightFound = playwright.findBinary(env, 'linux', work);
    assert.equal(zensuFound && path.dirname(zensuFound), playwrightFound && path.dirname(playwrightFound), env.PATH);
    const zensuRelative = cli.installedVersion(env, 'linux', work, 200).state === cli.STATES.CWD_RELATIVE;
    const playwrightRelative = playwright.installedVersion(env, 'linux', work).source === playwright.SOURCES.CWD_RELATIVE;
    assert.equal(zensuRelative, playwrightRelative, env.PATH);
  }
});

test('the work-order refusal for a missing CLI names the floor of this module', (t) => {
  const workOrder = require(path.resolve(__dirname, '../../hooks/lib/work-order-v1.js'));
  const refused = workOrder.probe({ env: { PATH: tempDir(t) } });
  assert.deepEqual(refused, { ok: false, reason: `the zensu CLI is not on PATH; install zensu-cli ${cli.MIN_VERSION} or later` });
});

test('the command line answers state, version and floor, and refuses anything else', { skip: !POSIX }, (t) => {
  const { binary } = fakeZensu(t, "printf 'zensu 0.9.0 (commit abc, built now)\\n'");
  const out = collect();
  assert.equal(cli.cliMain(['--binary', binary], out), true);
  assert.equal(out.text(), 'state=old\nversion=0.9.0\nfloor=0.10.0\n');
  for (const argv of [[], ['--binary'], ['--lookup', '--binary', binary], ['--execute'], ['--lookup', 'extra']]) {
    const refused = collect();
    assert.equal(cli.cliMain(argv, refused), false, argv.join(' '));
    assert.equal(refused.text(), '');
  }
});
