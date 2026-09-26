'use strict';

// Unit contract for hooks/lib/review-round-scope-v1.js — the round-delta
// extractor that narrows an auto-fix round's review packet.
//
// The load-bearing property is the FAIL-OPEN one: `status=ok` is the only verdict
// that licenses a narrowed packet, and every way of failing to establish a delta
// must answer `empty` or `degraded` so the caller keeps the whole diff. A bug that
// turned an unreadable log into "nothing changed this round" would review nothing
// while every check around it stayed green, so the refusal arms are driven
// individually rather than through one happy path.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const LIB = path.join(__dirname, '..', '..', 'hooks', 'lib', 'review-round-scope-v1.js');
const scope = require(LIB);

const TEMP_DIRS = [];

test.after(() => {
  for (const dir of TEMP_DIRS) fs.rmSync(dir, { recursive: true, force: true });
});

function tempDir() {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'review-round-scope-')));
  TEMP_DIRS.push(dir);
  return dir;
}

const LOG = [
  'S1 IMPL completed — files: src/phase5.ts | phase 5 work',
  'R1-S2 IMPL completed — files: src/one.ts | fix round 1',
  'R2-S1 IMPL completed — files: src/two.ts, src/three.ts | fix round 2',
  'R2-S4 IMPL completed - files: src/two.ts | hyphen spelling, same round',
  'R3-S1 IMPL completed — files: src/four.ts',
].join('\n');

test('a round resolves to its own claimed files and nothing else', () => {
  const r = scope.roundScope({ text: LOG, round: 2 });
  assert.equal(r.status, 'ok');
  assert.deepEqual(r.files, ['src/three.ts', 'src/two.ts']);
  assert.equal(r.claims, 2);
});

test('rounds are isolated from each other and from phase-5 claims', () => {
  assert.deepEqual(scope.roundScope({ text: LOG, round: 1 }).files, ['src/one.ts']);
  assert.deepEqual(scope.roundScope({ text: LOG, round: 3 }).files, ['src/four.ts']);
  for (const round of [1, 2, 3]) {
    assert.ok(!scope.roundScope({ text: LOG, round }).files.includes('src/phase5.ts'));
  }
});

test('the plain hyphen spelling is extracted, not only the em dash', () => {
  const r = scope.roundScope({ text: 'R7-S1 IMPL completed - files: only/hyphen.ts', round: 7 });
  assert.equal(r.status, 'ok');
  assert.deepEqual(r.files, ['only/hyphen.ts']);
});

test('files are deduplicated and sorted', () => {
  const text = 'R1-A IMPL completed — files: b.ts, a.ts\nR1-B IMPL completed — files: a.ts';
  const r = scope.roundScope({ text, round: 1 });
  assert.deepEqual(r.files, ['a.ts', 'b.ts']);
  assert.equal(r.claims, 2);
});

test('no claims for the round answers empty, which means "use the whole diff"', () => {
  const r = scope.roundScope({ text: LOG, round: 9 });
  assert.equal(r.status, 'empty');
  assert.equal(r.reason, 'no-claims');
  assert.equal(r.files.length, 0);
});

test('claims whose paths are all refused answer empty, never ok', () => {
  const r = scope.roundScope({ text: 'R1-S1 IMPL completed — files: ../outside.ts', round: 1 });
  assert.equal(r.status, 'empty');
  assert.equal(r.reason, 'no-usable-paths');
});

test('unsafe paths are refused individually while the safe ones survive', () => {
  const text = 'R1-S1 IMPL completed — files: ok.ts, ../up.ts, /abs.ts, .zensu/state/x.json, .git/config';
  const r = scope.roundScope({ text, round: 1 });
  assert.deepEqual(r.files, ['ok.ts']);
});

test('safeRelativePath refuses absolute, traversing, control-byte and denied-segment paths', () => {
  assert.equal(scope.safeRelativePath('src/a.ts'), 'src/a.ts');
  assert.equal(scope.safeRelativePath('./src/a.ts'), 'src/a.ts');
  assert.equal(scope.safeRelativePath('src\\a.ts'), 'src/a.ts');
  assert.equal(scope.safeRelativePath('/etc/passwd'), null);
  assert.equal(scope.safeRelativePath('C:\\win\\a.ts'), null);
  assert.equal(scope.safeRelativePath('../a.ts'), null);
  assert.equal(scope.safeRelativePath('src/../../a.ts'), null);
  assert.equal(scope.safeRelativePath('.zensu/state/a.json'), null);
  assert.equal(scope.safeRelativePath('.git/config'), null);
  assert.equal(scope.safeRelativePath('a\u0000b.ts'), null);
  assert.equal(scope.safeRelativePath('   '), null);
});

test('a bad round number is degraded, never empty', () => {
  for (const round of [0, -1, 'x', undefined, 1.5]) {
    const r = scope.roundScope({ text: LOG, round });
    assert.equal(r.status, 'degraded', 'round ' + String(round));
  }
});

test('a missing log is degraded', () => {
  const root = tempDir();
  const r = scope.roundScope({ log: path.join(root, 'absent.log'), round: 1 });
  assert.equal(r.status, 'degraded');
  assert.equal(r.reason, 'log-unreadable');
});

test('a log that is not a regular file is degraded', () => {
  const root = tempDir();
  const dir = path.join(root, 'a-directory.log');
  fs.mkdirSync(dir);
  const r = scope.roundScope({ log: dir, round: 1 });
  assert.equal(r.status, 'degraded');
  assert.equal(r.reason, 'log-not-a-file');
});

test('a log outside the supplied root is refused', () => {
  const inside = tempDir();
  const outside = tempDir();
  const log = path.join(outside, 'run.log');
  fs.writeFileSync(log, LOG);
  const r = scope.roundScope({ log, round: 2, root: inside });
  assert.equal(r.status, 'degraded');
  assert.equal(r.reason, 'log-outside-root');
});

test('a log inside the supplied root is read', () => {
  const root = tempDir();
  const log = path.join(root, 'run.log');
  fs.writeFileSync(log, LOG);
  const r = scope.roundScope({ log, round: 2, root });
  assert.equal(r.status, 'ok');
  assert.deepEqual(r.files, ['src/three.ts', 'src/two.ts']);
});

test('an unresolvable root is degraded rather than silently unanchored', () => {
  const root = tempDir();
  const r = scope.roundScope({ text: LOG, round: 2, root: path.join(root, 'absent-dir') });
  assert.equal(r.status, 'degraded');
  assert.equal(r.reason, 'bad-root');
});

test('hitting the total cap degrades rather than narrowing to a partial delta', () => {
  const many = [];
  for (let i = 0; i < scope.MAX_FILES + 10; i++) many.push('src/f' + i + '.ts');
  const claims = [];
  for (let i = 0; i < many.length; i += 100) {
    claims.push('R1-S' + i + ' IMPL completed — files: ' + many.slice(i, i + 100).join(', '));
  }
  const r = scope.roundScope({ text: claims.join('\n'), round: 1 });
  assert.equal(r.status, 'degraded');
  assert.equal(r.reason, 'truncated');
  assert.ok(r.dropped > 0);
  assert.ok(scope.render(r).includes('truncated dropped='));
});

test('hitting the per-claim cap degrades too — a dropped path must never be silent', () => {
  const many = [];
  for (let i = 0; i < scope.MAX_CLAIM_FILES + 5; i++) many.push('src/c' + i + '.ts');
  const r = scope.roundScope({ text: 'R1-S1 IMPL completed — files: ' + many.join(', '), round: 1 });
  assert.equal(r.status, 'degraded');
  assert.equal(r.reason, 'truncated');
  assert.equal(r.dropped, 5);
});

test('render emits one file line per path and always a summary', () => {
  const out = scope.render(scope.roundScope({ text: LOG, round: 2 }));
  const lines = out.split('\n');
  assert.deepEqual(lines.slice(0, 2), ['file src/three.ts', 'file src/two.ts']);
  assert.equal(lines[lines.length - 1], 'summary status=ok round=2 files=2 claims=2');
});

test('every degraded and empty render still terminates in a parseable summary', () => {
  for (const opts of [{ round: 0 }, { round: 1, log: '/nope/absent.log' }, { text: '', round: 1 }]) {
    const out = scope.render(scope.roundScope(opts));
    assert.match(out.split('\n').pop(), /^summary status=(empty|degraded) round=\d+ files=0 claims=0$/);
  }
});

test('the CLI never narrows on a verdict the caller must treat as full-diff', () => {
  const out = scope.cliMain(['--round', '1', '--log', '/nope/absent.log']);
  assert.ok(!out.includes('status=ok'));
  assert.ok(out.includes('status=degraded'));
});

test('claims before the last REVIEW BUDGET RESET marker are ignored', () => {
  const text = [
    'R1-F1 IMPL completed — files: src/old.ts',
    'REVIEW BUDGET RESET — generation 2',
    'R1-F1 IMPL completed — files: src/new.ts',
  ].join('\n');
  const r = scope.roundScope({ text, round: 1 });
  assert.equal(r.status, 'ok');
  assert.deepEqual(r.files, ['src/new.ts']);
  assert.equal(r.claims, 1);
});

test('a path claimed again after the reset marker stays in the new delta', () => {
  const text = [
    'R1-S1 IMPL completed — files: src/shared.ts',
    'REVIEW BUDGET RESET',
    'R1-S1 IMPL completed — files: src/shared.ts, src/fresh.ts',
  ].join('\n');
  const r = scope.roundScope({ text, round: 1 });
  assert.equal(r.status, 'ok');
  assert.deepEqual(r.files, ['src/fresh.ts', 'src/shared.ts']);
  assert.equal(r.claims, 1);
});

test('a reset with no later claim for the round answers empty, never the stale delta', () => {
  const text = ['R2-F1 IMPL completed — files: src/old.ts', '[12:00:00] REVIEW BUDGET RESET'].join('\n');
  const r = scope.roundScope({ text, round: 2 });
  assert.equal(r.status, 'empty');
  assert.equal(r.files.length, 0);
});

test('a truncation before the reset does not degrade the new generation', () => {
  const many = [];
  for (let i = 0; i < scope.MAX_CLAIM_FILES + 5; i++) many.push('src/c' + i + '.ts');
  const text = [
    'R1-S1 IMPL completed — files: ' + many.join(', '),
    'REVIEW BUDGET RESET',
    'R1-S2 IMPL completed — files: src/fresh.ts',
  ].join('\n');
  const r = scope.roundScope({ text, round: 1 });
  assert.equal(r.status, 'ok');
  assert.deepEqual(r.files, ['src/fresh.ts']);
});

test('the reset marker matches only at line start and readLog is exported', () => {
  assert.ok(scope.RESET.test('REVIEW BUDGET RESET'));
  assert.ok(scope.RESET.test('[+00:01:02] REVIEW BUDGET RESET — rearmed'));
  assert.ok(!scope.RESET.test('note: REVIEW BUDGET RESET mentioned mid-line'));
  assert.equal(typeof scope.readLog, 'function');
});
