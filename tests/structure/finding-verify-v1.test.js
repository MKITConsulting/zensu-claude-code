'use strict';

const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const LIB = path.join(__dirname, '..', '..', 'hooks', 'lib', 'finding-verify-v1.js');
const verify = require(LIB);

const TEMP_DIRS = [];

test.after(() => {
  for (const dir of TEMP_DIRS) fs.rmSync(dir, { recursive: true, force: true });
});

function tempDir(prefix) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
  TEMP_DIRS.push(dir);
  return dir;
}

function sandbox() {
  const root = tempDir('finding-verify-');
  fs.mkdirSync(path.join(root, 'src'), { recursive: true });
  fs.writeFileSync(path.join(root, 'src', 'a.js'), 'one\ntwo\nthree\n');
  fs.writeFileSync(path.join(root, 'src', 'b.js'), 'only\n');
  fs.writeFileSync(path.join(root, 'src', 'empty.js'), '');
  return root;
}

function grade(root, findings, changedFiles) {
  return verify.verifyFindings({
    root,
    changedFiles: changedFiles === undefined ? [] : changedFiles,
    findings,
  }).results;
}

function verdicts(root, findings, changedFiles) {
  return grade(root, findings, changedFiles).map((r) => r.verdict);
}

test('a real anchor inside the changed set grades anchor-ok', () => {
  const root = sandbox();
  assert.deepEqual(
    verdicts(root, ['- [CRITICAL] src/a.js:2 — issue.'], ['src/a.js']),
    ['anchor-ok'],
  );
});

test('a real anchor outside the changed set grades off-changeset, never a hard verdict', () => {
  const root = sandbox();
  assert.deepEqual(
    verdicts(root, ['- [IMPORTANT] src/b.js:1 — issue.'], ['src/a.js']),
    ['off-changeset'],
  );
});

test('an absent CHANGED-FILES section makes every real anchor off-changeset', () => {
  const root = sandbox();
  assert.deepEqual(verdicts(root, ['- src/a.js:1 — issue.']), ['off-changeset']);
});

test('a line past EOF grades line-out-of-range and reports the real count', () => {
  const root = sandbox();
  const [result] = grade(root, ['- [CRITICAL] src/a.js:4 — issue.'], ['src/a.js']);
  assert.equal(result.verdict, 'line-out-of-range');
  assert.equal(result.lines, 3);
});

test('line 0 is out of range because no file has one', () => {
  const root = sandbox();
  assert.deepEqual(verdicts(root, ['- src/a.js:0 — issue.'], ['src/a.js']), ['line-out-of-range']);
});

test('every line of an empty file is out of range', () => {
  const root = sandbox();
  const [result] = grade(root, ['- src/empty.js:1 — issue.'], ['src/empty.js']);
  assert.equal(result.verdict, 'line-out-of-range');
  assert.equal(result.lines, 0);
});

test('an invented path grades phantom-path', () => {
  const root = sandbox();
  assert.deepEqual(verdicts(root, ['- [CRITICAL] src/nope.js:1 — issue.']), ['phantom-path']);
});

test('a directory anchor grades phantom-path — there is no source line there', () => {
  const root = sandbox();
  assert.deepEqual(verdicts(root, ['- src:1 — issue.']), ['phantom-path']);
});

test('traversal out of the root is rejected without reading anything', () => {
  const root = sandbox();
  assert.deepEqual(verdicts(root, ['- ../../etc/passwd:1 — issue.']), ['out-of-root']);
});

test('an absolute path outside the root is rejected', () => {
  const root = sandbox();
  assert.deepEqual(verdicts(root, ['- /etc/passwd:1 — issue.']), ['out-of-root']);
});

test('an absolute path inside the root is graded normally', () => {
  const root = sandbox();
  const abs = path.join(root, 'src', 'a.js');
  assert.deepEqual(verdicts(root, ['- ' + abs + ':2 — issue.'], [abs]), ['anchor-ok']);
});

// The anchor is asserted directly rather than through a verdict: a drive-qualified
// path only RESOLVES inside the root on win32, but it must PARSE on every host, or
// this regression is invisible to the Linux gate and only the weekly Windows run
// can see it -- which is how it shipped. Both slash conventions occur: MSYS hands
// back backslashes, zensu-host-path.sh renders forward slashes.
test('a drive-qualified path parses on every platform', () => {
  assert.deepEqual(
    verify.extractAnchor('- C:\\proj\\src\\a.js:2 — issue.'),
    { path: 'C:\\proj\\src\\a.js', line: 2 },
  );
  assert.deepEqual(
    verify.extractAnchor('- D:/proj/src/a.js:2 — issue.'),
    { path: 'D:/proj/src/a.js', line: 2 },
  );
});

test('widening for drive letters did not turn a URL into an anchor', () => {
  assert.equal(verify.extractAnchor('- http://example.com/x:80 — issue.'), null);
  assert.equal(verify.extractAnchor('- Panel-FP: a meta verdict.'), null);
});

test('a symlink escaping the root is rejected after realpath, not read', () => {
  const root = sandbox();
  const outside = tempDir('finding-verify-out-');
  fs.writeFileSync(path.join(outside, 'secret.txt'), 'a\nb\nc\n');
  fs.symlinkSync(path.join(outside, 'secret.txt'), path.join(root, 'link.txt'));
  assert.deepEqual(verdicts(root, ['- link.txt:1 — issue.'], ['link.txt']), ['out-of-root']);
});

test('a symlink staying inside the root is graded normally', () => {
  const root = sandbox();
  fs.symlinkSync(path.join(root, 'src', 'a.js'), path.join(root, 'inside.js'));
  assert.deepEqual(verdicts(root, ['- inside.js:1 — issue.'], ['inside.js']), ['anchor-ok']);
});

test('.git and .zensu are denied even when the file exists', () => {
  const root = sandbox();
  fs.mkdirSync(path.join(root, '.git'), { recursive: true });
  fs.writeFileSync(path.join(root, '.git', 'config'), 'x\n');
  fs.mkdirSync(path.join(root, '.zensu', 'state'), { recursive: true });
  fs.writeFileSync(path.join(root, '.zensu', 'state', 'chain.json'), '{}\n');
  assert.deepEqual(
    verdicts(root, ['- .git/config:1 — issue.', '- .zensu/state/chain.json:1 — issue.']),
    ['out-of-root', 'out-of-root'],
  );
});

test('a denied segment is rejected at any depth', () => {
  const root = sandbox();
  fs.mkdirSync(path.join(root, 'src', '.zensu'), { recursive: true });
  fs.writeFileSync(path.join(root, 'src', '.zensu', 'x.json'), '{}\n');
  assert.deepEqual(verdicts(root, ['- src/.zensu/x.json:1 — issue.']), ['out-of-root']);
});

test('a line with no path:line token grades no-anchor', () => {
  const root = sandbox();
  assert.deepEqual(
    verdicts(root, ['- [SUGGESTION] Panel-FP: the panel misread the guard.']),
    ['no-anchor'],
  );
});

test('a URL is not mistaken for an anchor', () => {
  const root = sandbox();
  assert.deepEqual(verdicts(root, ['- see http://example.com:8080 for context']), ['no-anchor']);
});

test('a path:line:column anchor resolves to path:line', () => {
  const root = sandbox();
  const anchor = verify.extractAnchor('- [CRITICAL] src/a.js:2:17 — issue.');
  assert.deepEqual(anchor, { path: 'src/a.js', line: 2 });
});

test('the first anchor on the line wins over one cited later in the evidence', () => {
  const root = sandbox();
  const anchor = verify.extractAnchor('- src/a.js:1 — issue. Evidence: also see src/b.js:9.');
  assert.deepEqual(anchor, { path: 'src/a.js', line: 1 });
});

test('a file over the read cap is graded by membership, never accused', () => {
  const root = sandbox();
  fs.writeFileSync(path.join(root, 'huge.bin'), Buffer.alloc(verify.FILE_MAX_BYTES + 1, 0x61));
  assert.deepEqual(verdicts(root, ['- huge.bin:999999 — issue.'], ['huge.bin']), ['anchor-ok']);
});

test('parseInput requires the FINDINGS marker and tolerates a missing CHANGED-FILES', () => {
  assert.equal(verify.parseInput('src/a.js\n- src/a.js:1 — issue.'), null);
  assert.deepEqual(
    verify.parseInput('FINDINGS\n- src/a.js:1 — issue.\n'),
    { changedFiles: [], findings: ['- src/a.js:1 — issue.'] },
  );
  assert.deepEqual(
    verify.parseInput('CHANGED-FILES\nsrc/a.js\n\nFINDINGS\n\n- src/a.js:1 — issue.\n'),
    { changedFiles: ['src/a.js'], findings: ['- src/a.js:1 — issue.'] },
  );
});

test('an unusable root yields a total=0 summary instead of a verdict', () => {
  const root = sandbox();
  assert.deepEqual(verify.verifyFindings({ root: path.join(root, 'nope'), findings: ['- src/a.js:1'] }), {
    results: [],
    dropped: 0,
  });
  assert.deepEqual(verify.verifyFindings({ root: path.join(root, 'src', 'a.js'), findings: ['- src/a.js:1'] }), {
    results: [],
    dropped: 0,
  });
});

test('findings beyond the cap are dropped loudly, never silently', () => {
  const root = sandbox();
  const findings = [];
  for (let i = 0; i < verify.MAX_FINDINGS + 3; i++) findings.push('- src/a.js:1 — issue ' + i + '.');
  const report = verify.verifyFindings({ root, changedFiles: ['src/a.js'], findings });
  assert.equal(report.results.length, verify.MAX_FINDINGS);
  assert.equal(report.dropped, 3);
  assert.match(verify.render(report), /^truncated dropped=3$/m);
});

test('render emits one indexed line per finding plus a counting summary', () => {
  const root = sandbox();
  const report = verify.verifyFindings({
    root,
    changedFiles: ['src/a.js'],
    findings: [
      '- src/a.js:1 — real.',
      '- src/nope.js:1 — invented.',
      '- src/a.js:9 — past EOF.',
      '- ../../etc/passwd:1 — traversal.',
      '- Panel-FP: meta.',
      '- src/b.js:1 — off changeset.',
    ],
  });
  assert.deepEqual(verify.render(report).split('\n'), [
    '1 anchor-ok src/a.js:1',
    '2 phantom-path src/nope.js:1',
    '3 line-out-of-range src/a.js:9 lines=3',
    '4 out-of-root ../../etc/passwd:1',
    '5 no-anchor -',
    '6 off-changeset src/b.js:1',
    'summary ok=1 off-changeset=1 out-of-range=1 phantom=1 out-of-root=1 no-anchor=1 total=6',
  ]);
});

test('cliMain degrades to a total=0 summary on every unusable input', () => {
  const root = sandbox();
  const empty = 'summary ok=0 off-changeset=0 out-of-range=0 phantom=0 out-of-root=0 no-anchor=0 total=0';
  assert.equal(verify.cliMain([], 'FINDINGS\n- src/a.js:1'), empty);
  assert.equal(verify.cliMain(['--root', root], 'no marker here'), empty);
  assert.equal(verify.cliMain(['--root', ''], 'FINDINGS\n- src/a.js:1'), empty);
  assert.equal(verify.cliMain(['--root=' + root], 'FINDINGS\n- src/a.js:1'), '1 off-changeset src/a.js:1\n' + empty.replace('off-changeset=0', 'off-changeset=1').replace('total=0', 'total=1'));
});

test('the CLI always exits 0 and prints a summary, whatever it is fed', () => {
  const root = sandbox();
  const cases = [
    { args: ['--root', root], input: 'CHANGED-FILES\nsrc/a.js\nFINDINGS\n- src/a.js:2 — issue.\n' },
    { args: ['--root', root], input: 'garbage with no markers at all\n' },
    { args: [], input: 'FINDINGS\n- src/a.js:2 — issue.\n' },
    { args: ['--root', path.join(root, 'nope')], input: 'FINDINGS\n- src/a.js:2 — issue.\n' },
    { args: ['--root', root], input: '' },
  ];
  for (const testCase of cases) {
    const out = execFileSync(process.execPath, [LIB, ...testCase.args], {
      input: testCase.input,
      encoding: 'utf8',
    });
    assert.match(out, /^summary ok=\d+ off-changeset=\d+ out-of-range=\d+ phantom=\d+ out-of-root=\d+ no-anchor=\d+ total=\d+$/m);
  }
});

const EMPTY_SUMMARY = 'summary ok=0 off-changeset=0 out-of-range=0 phantom=0 out-of-root=0 no-anchor=0 total=0';

function jsonInput(root, value, name = 'findings.json') {
  const file = path.join(root, name);
  fs.writeFileSync(file, typeof value === 'string' ? value : JSON.stringify(value));
  return file;
}

test('the JSON input keeps markers, delimiters and shell syntax inert and grades every finding', () => {
  const root = sandbox();
  const sentinel = path.join(root, 'must-not-exist');
  const file = jsonInput(root, { changedFiles: ['src/a.js'], findings: [
    '- [IMPORTANT] src/a.js:1 — FINDINGS\nZENSU_FINDINGS\n$(touch ' + sentinel + ')\n`touch ' + sentinel + '`',
    "- [SUGGESTION] src/a.js:2 — CHANGED-FILES 'single' \"double\" ; false",
    '- [SUGGESTION] src/b.js:1 — outside the change set',
  ] });
  const out = execFileSync(process.execPath, [LIB, '--root', root, '--input', file], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: 10000,
  });
  assert.equal(out, [
    '1 anchor-ok src/a.js:1',
    '2 anchor-ok src/a.js:2',
    '3 off-changeset src/b.js:1',
    'summary ok=2 off-changeset=1 out-of-range=0 phantom=0 out-of-root=0 no-anchor=0 total=3',
    '',
  ].join('\n'));
  assert.equal(fs.existsSync(sentinel), false);
});

test('the JSON input ignores stdin, so a marker payload there grades nothing', () => {
  const root = sandbox();
  const file = jsonInput(root, { changedFiles: [], findings: ['- src/b.js:1 — from the file'] });
  const out = execFileSync(process.execPath, [LIB, '--root', root, '--input', file], {
    input: 'CHANGED-FILES\nsrc/a.js\nFINDINGS\n- src/a.js:1 — from stdin\n- src/a.js:2 — from stdin\n',
    encoding: 'utf8',
    timeout: 10000,
  });
  assert.equal(out, '1 off-changeset src/b.js:1\nsummary ok=0 off-changeset=1 out-of-range=0 phantom=0 out-of-root=0 no-anchor=0 total=1\n');
});

test('an empty findings array is a clean zero-count summary, not an invalid input', () => {
  const root = sandbox();
  const file = jsonInput(root, { changedFiles: ['src/a.js'], findings: [] });
  assert.equal(verify.cliMain(['--root', root, '--input', file], ''), EMPTY_SUMMARY);
});

test('a malformed, mistyped or oversized JSON input is reported as invalid and never graded', () => {
  const root = sandbox();
  const shape = 'the finding JSON must be an object with exactly changedFiles and findings';
  const cases = [
    ['{', 'the finding JSON does not parse'],
    ['[]', shape],
    [JSON.stringify({ findings: [] }), shape],
    [JSON.stringify({ changedFiles: [], findings: [], extra: 1 }), shape],
    [JSON.stringify({ changedFiles: 'src/a.js', findings: [] }), 'changedFiles must be an array of single-line paths'],
    [JSON.stringify({ changedFiles: ['src/a.js\nsrc/b.js'], findings: [] }), 'changedFiles must be an array of single-line paths'],
    [JSON.stringify({ changedFiles: [], findings: [42] }), 'findings must be an array of non-empty strings'],
    [JSON.stringify({ changedFiles: [], findings: ['   '] }), 'findings must be an array of non-empty strings'],
    [' '.repeat(verify.STDIN_MAX_BYTES + 1), 'the finding JSON file exceeds ' + verify.STDIN_MAX_BYTES + ' bytes'],
  ];
  for (const [text, reason] of cases) {
    const file = jsonInput(root, text);
    assert.equal(verify.cliMain(['--root', root, '--input', file], ''), 'invalid-input ' + reason + '\n' + EMPTY_SUMMARY);
  }
});

test('a JSON input without a usable root or file is reported as invalid', () => {
  const root = sandbox();
  const file = jsonInput(root, { changedFiles: [], findings: ['- src/a.js:1 — x'] });
  const invalid = (reason) => 'invalid-input ' + reason + '\n' + EMPTY_SUMMARY;
  assert.equal(verify.cliMain(['--input', file], ''), invalid('--root is required'));
  assert.equal(verify.cliMain(['--root', path.join(root, 'nope'), '--input', file], ''), invalid('--root is not a directory'));
  assert.equal(verify.cliMain(['--root', root, '--input'], ''), invalid('--input requires a file'));
  assert.equal(verify.cliMain(['--root', root, '--input', path.join(root, 'absent.json')], ''), invalid('the finding JSON file cannot be read'));
  assert.equal(verify.cliMain(['--root', root, '--input', path.join(root, 'src')], ''), invalid('the finding JSON file is not a regular file'));
});

test('a JSON input reached through a symbolic link is refused', { skip: process.platform === 'win32' && 'symbolic links need privileges on win32' }, () => {
  const root = sandbox();
  const target = jsonInput(root, { changedFiles: [], findings: ['- src/a.js:1 — x'] }, 'target.json');
  const link = path.join(root, 'link.json');
  fs.symlinkSync(target, link);
  assert.equal(verify.cliMain(['--root', root, '--input', link], ''), 'invalid-input the finding JSON file is a symbolic link\n' + EMPTY_SUMMARY);
});

test('a graded JSON input in a project review directory is removed, and every other input is kept', () => {
  const root = sandbox();
  const reviews = path.join(root, '.zensu', 'reviews');
  fs.mkdirSync(reviews, { recursive: true });
  const consumed = path.join(reviews, 'findings-round-1.json');
  fs.writeFileSync(consumed, JSON.stringify({ changedFiles: ['src/a.js'], findings: ['- [SUGGESTION] src/a.js:1 — x'] }));
  assert.match(verify.cliMain(['--root', root, '--input', consumed], ''), /^1 anchor-ok src\/a\.js:1\n/);
  assert.equal(fs.existsSync(consumed), false);
  const malformed = path.join(reviews, 'findings-round-2.json');
  fs.writeFileSync(malformed, '{');
  assert.match(verify.cliMain(['--root', root, '--input', malformed], ''), /^invalid-input /);
  assert.equal(fs.existsSync(malformed), true);
  const elsewhere = jsonInput(root, { changedFiles: [], findings: [] });
  assert.equal(verify.cliMain(['--root', root, '--input', elsewhere], ''), EMPTY_SUMMARY);
  assert.equal(fs.existsSync(elsewhere), true);
  const nested = path.join(root, 'pkg', '.zensu', 'reviews');
  fs.mkdirSync(nested, { recursive: true });
  const below = path.join(nested, 'findings-round-1.json');
  fs.writeFileSync(below, JSON.stringify({ changedFiles: [], findings: [] }));
  assert.equal(verify.cliMain(['--root', root, '--input', below], ''), EMPTY_SUMMARY);
  assert.equal(fs.existsSync(below), false);
  const outside = tempDir('finding-verify-outside-');
  fs.mkdirSync(path.join(outside, '.zensu', 'reviews'), { recursive: true });
  const foreign = path.join(outside, '.zensu', 'reviews', 'findings-round-1.json');
  fs.writeFileSync(foreign, JSON.stringify({ changedFiles: [], findings: [] }));
  assert.equal(verify.cliMain(['--root', root, '--input', foreign], ''), EMPTY_SUMMARY);
  assert.equal(fs.existsSync(foreign), true);
});
