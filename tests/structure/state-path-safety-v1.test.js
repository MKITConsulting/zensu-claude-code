'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const { pathsSafe, pathsSafeArgv } = require('../../hooks/lib/state-path-safety-v1.js');

const WIN32 = process.platform === 'win32';

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-path-safety-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const state = path.join(root, '.zensu', 'state');
  fs.mkdirSync(state, { recursive: true });
  const file = path.join(state, 'tdd-phase.json');
  fs.writeFileSync(file, '{}\n');
  return { root, state, file };
}

function dirLink(target, link) {
  fs.symlinkSync(target, link, WIN32 ? 'junction' : 'dir');
}

test('a regular leaf and a directory below a trusted root pass, and every mode honours absence', (t) => {
  const { root, state, file } = fixture(t);
  const missing = path.join(state, 'missing.json');
  assert.equal(pathsSafe([root, '', ''], [state, 'directory', file, 'regular']), true);
  assert.equal(pathsSafe([root, '', ''], [missing, 'regular-or-absent']), true);
  assert.equal(pathsSafe([root, '', ''], [missing, 'regular']), false);
  assert.equal(pathsSafe([root, '', ''], [path.join(state, 'new'), 'directory-or-absent']), true);
  assert.equal(pathsSafe([root, '', ''], [path.join(state, 'new'), 'directory']), false);
  assert.equal(pathsSafe([root, '', ''], [path.join(root, 'absent', 'deeper', 'x.json'), 'regular-or-absent']), true);
});

test('a symlinked ancestor below the anchor is refused even though the leaf itself is a plain file', (t) => {
  const { root, file } = fixture(t);
  const elsewhere = path.join(root, 'elsewhere');
  fs.mkdirSync(path.join(elsewhere, 'state'), { recursive: true });
  fs.writeFileSync(path.join(elsewhere, 'state', 'tdd-phase.json'), '{}\n');
  fs.rmSync(path.join(root, '.zensu'), { recursive: true, force: true });
  dirLink(elsewhere, path.join(root, '.zensu'));
  assert.equal(fs.statSync(file).isFile(), true);
  assert.equal(pathsSafe([root, '', ''], [file, 'regular']), false);
  assert.equal(pathsSafe([root, '', ''], [path.dirname(file), 'directory']), false);
});

test('a symlinked leaf is refused in every mode, including the absent-tolerant ones', (t) => {
  const { root, state, file } = fixture(t);
  const link = path.join(state, 'link.json');
  fs.symlinkSync(file, link, 'file');
  const dangling = path.join(state, 'dangling.json');
  fs.symlinkSync(path.join(state, 'nowhere.json'), dangling, 'file');
  for (const mode of ['regular', 'regular-or-absent']) {
    assert.equal(pathsSafe([root, '', ''], [link, mode]), false, mode);
    assert.equal(pathsSafe([root, '', ''], [dangling, mode]), false, `${mode} dangling`);
  }
});

test('a hard-linked regular leaf is refused, which no shell leaf test can see', (t) => {
  const { root, state, file } = fixture(t);
  const twin = path.join(state, 'twin.json');
  fs.linkSync(file, twin);
  assert.equal(fs.lstatSync(file).isFile(), true);
  assert.equal(pathsSafe([root, '', ''], [file, 'regular']), false);
  assert.equal(pathsSafe([root, '', ''], [file, 'regular-or-absent']), false);
  fs.unlinkSync(twin);
  assert.equal(pathsSafe([root, '', ''], [file, 'regular']), true);
});

test('a leaf of the wrong kind is refused: a directory for a regular mode, a file for a directory mode', (t) => {
  const { root, state, file } = fixture(t);
  assert.equal(pathsSafe([root, '', ''], [state, 'regular-or-absent']), false);
  assert.equal(pathsSafe([root, '', ''], [file, 'directory-or-absent']), false);
});

test('a FIFO is refused as a regular leaf', { skip: WIN32 && 'no FIFOs on win32' }, (t) => {
  const { root, state } = fixture(t);
  const fifo = path.join(state, 'fifo.json');
  const made = spawnSync('mkfifo', [fifo]);
  assert.equal(made.status, 0, String(made.stderr));
  assert.equal(pathsSafe([root, '', ''], [fifo, 'regular-or-absent']), false);
});

test('a component the walk cannot inspect refuses instead of reading as absent', {
  skip: (WIN32 || (typeof process.getuid === 'function' && process.getuid() === 0)) && 'directory permissions do not bind here',
}, (t) => {
  const { root, state, file } = fixture(t);
  fs.chmodSync(state, 0o000);
  let verdict;
  try {
    verdict = pathsSafe([root, '', ''], [file, 'regular-or-absent']);
  } finally {
    fs.chmodSync(state, 0o700);
  }
  assert.equal(verdict, false);
});

test('a file standing where a directory component belongs refuses the walk', (t) => {
  const { root, file } = fixture(t);
  assert.equal(pathsSafe([root, '', ''], [path.join(file, 'child.json'), 'regular-or-absent']), false);
});

test('a trusted root that is itself a symlink is resolved once and the walk continues below it', (t) => {
  const { root, state, file } = fixture(t);
  const alias = `${root}-alias`;
  dirLink(root, alias);
  t.after(() => fs.rmSync(alias, { force: true }));
  const aliased = path.join(alias, path.relative(root, file));
  assert.equal(pathsSafe([alias, '', ''], [aliased, 'regular']), true);
  fs.linkSync(file, path.join(state, 'twin.json'));
  assert.equal(pathsSafe([alias, '', ''], [aliased, 'regular']), false);
});

test('a path outside every trusted root is walked below its nearest real ancestor', (t) => {
  const { root, state, file } = fixture(t);
  const other = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-path-safety-other-'));
  t.after(() => fs.rmSync(other, { recursive: true, force: true }));
  assert.equal(pathsSafe([other, '', ''], [file, 'regular']), true);
  const real = path.join(root, 'real-state');
  fs.renameSync(state, real);
  dirLink(real, state);
  assert.equal(fs.statSync(file).isFile(), true);
  assert.equal(pathsSafe([other, '', ''], [file, 'regular']), false);
});

test('a directory whose name starts with two dots stays inside its anchor and is walked', (t) => {
  const { root } = fixture(t);
  const dotted = path.join(root, '..bak');
  fs.mkdirSync(dotted);
  fs.writeFileSync(path.join(dotted, 'x.json'), '{}\n');
  assert.equal(pathsSafe([root, '', ''], [path.join(dotted, 'x.json'), 'regular']), true);
  fs.linkSync(path.join(dotted, 'x.json'), path.join(dotted, 'y.json'));
  assert.equal(pathsSafe([root, '', ''], [path.join(dotted, 'x.json'), 'regular']), false);
});

test('a malformed request refuses: wrong root count, empty or odd pairs, an unknown mode, an empty path', (t) => {
  const { root, file } = fixture(t);
  assert.equal(pathsSafe([root, ''], [file, 'regular']), false);
  assert.equal(pathsSafe([root, '', '', ''], [file, 'regular']), false);
  assert.equal(pathsSafe('nope', [file, 'regular']), false);
  assert.equal(pathsSafe([root, '', ''], []), false);
  assert.equal(pathsSafe([root, '', ''], [file]), false);
  assert.equal(pathsSafe([root, '', ''], 'nope'), false);
  assert.equal(pathsSafe([root, '', ''], [file, 'file']), false);
  assert.equal(pathsSafe([root, '', ''], ['', 'regular-or-absent']), false);
  assert.equal(pathsSafe([root, '', ''], [file, 'regular', file, 'regular-or-absent', file, 'nope']), false);
});

test('the argv form takes three roots and then pairs, and refuses anything else', (t) => {
  const { root, file } = fixture(t);
  assert.equal(pathsSafeArgv([root, '', '', file, 'regular']), true);
  assert.equal(pathsSafeArgv([root, '', '', file]), false);
  assert.equal(pathsSafeArgv([root, '', '']), false);
  assert.equal(pathsSafeArgv([]), false);
  assert.equal(pathsSafeArgv(undefined), false);
  assert.equal(pathsSafeArgv(`${root} ${file} regular`), false);
});
