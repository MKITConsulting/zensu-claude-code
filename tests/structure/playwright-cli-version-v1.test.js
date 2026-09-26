'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const MODULE = path.resolve(__dirname, '../../hooks/lib/playwright-cli-version-v1.js');
const version = require(MODULE);
const POSIX = process.platform !== 'win32';
const NONE = Object.freeze({ source: 'unread', version: '', owner: '' });

function tempDir(t) {
  const dir = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-cli-version-')));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function stub(file, body) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  return file;
}

function manifest(dir, value) {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'package.json'), typeof value === 'string' ? value : JSON.stringify(value));
}

function installed(t, doc) {
  const root = tempDir(t);
  const pkg = path.join(root, 'lib', 'node_modules', '@playwright', 'cli');
  const log = path.join(root, 'calls.log');
  stub(path.join(pkg, 'cli.js'), `printf '%s\\n' "$*" >> '${log}'\nprintf '9.9.9\\n'`);
  if (doc !== undefined) manifest(pkg, doc);
  fs.mkdirSync(path.join(root, 'bin'));
  const binary = path.join(root, 'bin', 'playwright-cli');
  fs.symlinkSync(path.join(pkg, 'cli.js'), binary);
  return { root, binary, log };
}

function calls(log) {
  return fs.existsSync(log) ? fs.readFileSync(log, 'utf8').split('\n').filter(Boolean) : [];
}

test('the version comes from the @playwright/cli manifest the binary resolves to, and the binary never runs', { skip: !POSIX }, (t) => {
  const { binary, log } = installed(t, { name: '@playwright/cli', version: '0.1.21' });
  assert.deepEqual(version.probe({ binary, execute: true }), { source: 'manifest', version: '0.1.21', owner: '@playwright/cli' });
  assert.deepEqual(calls(log), []);
});

test('a prerelease or build suffix is kept whole', { skip: !POSIX }, (t) => {
  for (const value of ['0.1.21-beta.1', '0.1.21+build.7', '1.0.0-rc.1+sha.abc']) {
    const { binary } = installed(t, { name: '@playwright/cli', version: value });
    assert.equal(version.probe({ binary }).version, value);
  }
});

test('a manifest naming another package is reported as foreign and the binary never runs', { skip: !POSIX }, (t) => {
  const { binary, log } = installed(t, { name: 'not-playwright', version: '0.1.21' });
  assert.deepEqual(version.probe({ binary, execute: true }), { source: 'foreign', version: '', owner: 'not-playwright' });
  assert.deepEqual(calls(log), []);
});

test('an unparseable, oversized, unnamed or unversioned manifest is malformed and the binary never runs', { skip: !POSIX }, (t) => {
  const docs = [
    '{not json',
    JSON.stringify({ name: '@playwright/cli', version: '0.1.21', pad: 'x'.repeat(70000) }),
    { version: '0.1.21' },
    { name: 42, version: '0.1.21' },
    { name: 'Bad Name!', version: '0.1.21' },
    { name: '@playwright/cli' },
    { name: '@playwright/cli', version: '0.1' },
    { name: '@playwright/cli', version: '0.1.21\n❌ forged' },
  ];
  for (const doc of docs) {
    const { binary, log } = installed(t, doc);
    assert.deepEqual(version.probe({ binary, execute: true }), { source: 'malformed', version: '', owner: '' }, JSON.stringify(doc).slice(0, 60));
    assert.deepEqual(calls(log), []);
  }
});

test('the nearest manifest decides, within four directories of the resolved binary', { skip: !POSIX }, (t) => {
  const root = tempDir(t);
  const binary = stub(path.join(root, 'a', 'b', 'c', 'd', 'playwright-cli'), 'exit 0');
  manifest(root, { name: '@playwright/cli', version: '0.1.21' });
  assert.deepEqual(version.probe({ binary }), NONE);
  manifest(path.join(root, 'a'), { name: '@playwright/cli', version: '0.1.21' });
  assert.equal(version.probe({ binary }).source, 'manifest');
  manifest(path.join(root, 'a', 'b', 'c'), { name: 'my-project', version: '1.0.0' });
  assert.deepEqual(version.probe({ binary }), { source: 'foreign', version: '', owner: 'my-project' });
});

test('an npm shim beside node_modules resolves through the sibling package manifest', (t) => {
  const root = tempDir(t);
  const binary = path.join(root, 'npm', 'playwright-cli.cmd');
  fs.mkdirSync(path.dirname(binary), { recursive: true });
  fs.writeFileSync(binary, '@echo off\r\n');
  manifest(path.join(root, 'npm', 'node_modules', '@playwright', 'cli'), { name: '@playwright/cli', version: '0.1.21' });
  assert.deepEqual(version.probe({ binary }), { source: 'manifest', version: '0.1.21', owner: '@playwright/cli' });
});

test('the npm shim sibling manifest outranks a stray package.json in a directory above the shim', (t) => {
  const root = tempDir(t);
  const binary = path.join(root, 'npm', 'playwright-cli.cmd');
  fs.mkdirSync(path.dirname(binary), { recursive: true });
  fs.writeFileSync(binary, '@echo off\r\n');
  manifest(root, { name: 'my-home', version: '1.0.0' });
  manifest(path.join(root, 'npm', 'node_modules', '@playwright', 'cli'), { name: '@playwright/cli', version: '0.1.21' });
  assert.deepEqual(version.probe({ binary }), { source: 'manifest', version: '0.1.21', owner: '@playwright/cli' });
});

test('without a manifest the binary reports its own version once, with stdin closed and the update notifier off', { skip: !POSIX }, (t) => {
  const root = tempDir(t);
  const log = path.join(root, 'calls.log');
  const binary = stub(path.join(root, 'bin', 'playwright-cli'),
    `read -r ignored\nprintf '%s|%s\\n' "$*" "\${NO_UPDATE_NOTIFIER:-}" >> '${log}'\nprintf 'Version 9.8.7-beta.2 (build 4)\\nnotice: 7.7.7 is available\\n'`);
  assert.deepEqual(version.probe({ binary, execute: true }), { source: 'self-reported', version: '9.8.7-beta.2', owner: '' });
  assert.deepEqual(calls(log), ['--version|1']);
  assert.deepEqual(version.probe({ binary }), NONE);
  assert.deepEqual(calls(log), ['--version|1']);
  const silent = stub(path.join(root, 'silent', 'playwright-cli'), 'printf "no version here\\n"');
  assert.deepEqual(version.probe({ binary: silent, execute: true }), NONE);
});

test('a binary that never answers is cut off by the bound on every host', { skip: !POSIX }, (t) => {
  assert.equal(version.VERSION_TIMEOUT_MS, 5000);
  const root = tempDir(t);
  for (const body of ['exec sleep 20', 'sleep 20\nprintf "1.2.3\\n"']) {
    const binary = stub(path.join(root, String(body.length), 'playwright-cli'), body);
    const started = Date.now();
    assert.deepEqual(version.probe({ binary, execute: true, timeoutMs: 300 }), NONE, body);
    assert.ok(Date.now() - started < 5000, body);
  }
});

test('findBinary walks PATH like command -v and skips a directory or a non-executable file', { skip: !POSIX }, (t) => {
  const root = tempDir(t);
  const [a, b, c] = ['a', 'b', 'c'].map((name) => path.join(root, name));
  fs.mkdirSync(path.join(a, 'playwright-cli'), { recursive: true });
  fs.mkdirSync(b);
  fs.writeFileSync(path.join(b, 'playwright-cli'), 'x', { mode: 0o644 });
  const found = stub(path.join(c, 'playwright-cli'), 'exit 0');
  assert.equal(version.findBinary({ PATH: [a, b, c].join(path.delimiter) }), found);
  assert.equal(version.findBinary({ PATH: [a, b].join(path.delimiter) }), '');
  assert.equal(version.findBinary({}), '');
});

test('findBinary reads an empty PATH entry as the working directory and a relative one against it, as the shell does', { skip: !POSIX }, (t) => {
  const root = tempDir(t);
  const work = path.join(root, 'work');
  const here = stub(path.join(work, 'playwright-cli'), 'exit 0');
  const relative = stub(path.join(work, 'rel', 'bin', 'playwright-cli'), 'exit 0');
  const absolute = stub(path.join(root, 'abs', 'playwright-cli'), 'exit 0');
  const abs = path.dirname(absolute);
  assert.equal(version.findBinary({ PATH: ['', abs].join(':') }, 'linux', work), here);
  assert.equal(version.findBinary({ PATH: ['rel/bin', abs].join(':') }, 'linux', work), relative);
  assert.equal(version.findBinary({ PATH: [abs, '', 'rel/bin'].join(':') }, 'linux', work), absolute);
  assert.equal(version.findBinary({ PATH: ['', abs].join(':') }, 'linux', path.join(root, 'abs')), absolute);
});

test('installedVersion refuses to measure through a PATH entry the shell reads against the working directory, and names it', { skip: !POSIX }, (t) => {
  const { root, log } = installed(t, { name: '@playwright/cli', version: '0.1.21' });
  const bin = path.join(root, 'bin');
  const empty = path.join(root, 'empty');
  fs.mkdirSync(empty);
  const unstable = (entry) => ({ source: 'cwd-relative', version: '', owner: '', entry });
  assert.deepEqual(version.installedVersion({ PATH: ['', bin].join(':') }, 'linux', empty), unstable(''));
  assert.deepEqual(version.installedVersion({ PATH: ['node_modules/.bin', bin].join(':') }, 'linux', empty), unstable('node_modules/.bin'));
  assert.deepEqual(version.installedVersion({ PATH: ['bin'].join(':') }, 'linux', root), unstable('bin'));
  assert.deepEqual(version.installedVersion({ PATH: [bin, '', 'node_modules/.bin'].join(':') }, 'linux', empty),
    { source: 'manifest', version: '0.1.21', owner: '@playwright/cli' });
  assert.deepEqual(version.installedVersion({ PATH: ['', 'nowhere'].join(':') }, 'linux', empty), { source: 'absent', version: '', owner: '' });
  assert.deepEqual(calls(log), []);
});

test('installedVersion reads the manifest of the binary on PATH and never runs it', { skip: !POSIX }, (t) => {
  const { root, log } = installed(t, { name: '@playwright/cli', version: '0.1.21' });
  assert.deepEqual(version.installedVersion({ PATH: path.join(root, 'bin') }), { source: 'manifest', version: '0.1.21', owner: '@playwright/cli' });
  assert.deepEqual(version.installedVersion({ PATH: path.join(root, 'nowhere') }), { source: 'absent', version: '', owner: '' });
  assert.deepEqual(calls(log), []);
});

test('the CLI prints one key per line and nothing a report could mistake for a row', { skip: !POSIX }, (t) => {
  const run = (args) => spawnSync(process.execPath, [MODULE, ...args], { encoding: 'utf8', env: { PATH: process.env.PATH } });
  const good = installed(t, { name: '@playwright/cli', version: '0.1.21' });
  assert.equal(run(['--binary', good.binary]).stdout, 'source=manifest\nversion=0.1.21\nowner=@playwright/cli\n');
  const forged = installed(t, { name: 'evil\n❌ row', version: '0.1.21' });
  assert.equal(run(['--binary', forged.binary]).stdout, 'source=malformed\nversion=\nowner=\n');
  assert.equal(run(['--binary', '']).stdout, 'source=absent\nversion=\nowner=\n');
  const bad = run(['--bogus']);
  assert.equal(bad.status, 2);
  assert.equal(bad.stdout, '');
  const lookup = (entries) => spawnSync(process.execPath, [MODULE, '--lookup'], { encoding: 'utf8', env: { PATH: entries.join(':') }, cwd: good.root });
  assert.equal(lookup([path.join(good.root, 'bin')]).stdout, 'source=manifest\nversion=0.1.21\nowner=@playwright/cli\n');
  assert.equal(lookup(['bin']).stdout, 'source=cwd-relative\nversion=\nowner=\n');
  assert.equal(lookup(['', path.join(good.root, 'bin')]).stdout, 'source=cwd-relative\nversion=\nowner=\n');
  const both = run(['--lookup', '--binary', good.binary]);
  assert.equal(both.status, 2);
  assert.equal(both.stdout, '');
  const printed = [];
  assert.equal(version.cliMain(['--binary', ''], { write: (text) => printed.push(text) }), true);
  assert.deepEqual(printed, ['source=absent\nversion=\nowner=\n']);
});
