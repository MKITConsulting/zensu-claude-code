'use strict';

const assert = require('node:assert/strict');
const childProcess = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const YAML = require('yaml');

const ROOT = path.join(__dirname, '..', '..');
const runner = require(path.join(ROOT, 'tests', 'run-clock-shift.js'));

const PRELOAD = runner.PRELOAD;
const RUNNER = path.join(ROOT, 'tests', 'run-clock-shift.js');
const ALLOWLIST = path.join(ROOT, 'tests', 'profiles', 'clock-shift-allowlist.v1.json');
const SCHEDULED = path.join(ROOT, '.github', 'workflows', 'scheduled.yml');
const PULL_REQUEST_WORKFLOW = path.join(ROOT, '.github', 'workflows', 'ci.yml');
const VARIABLE = 'ZENSU_TEST_CLOCK_SHIFT_DAYS';
const DAY_MS = 24 * 60 * 60 * 1000;
const TOLERANCE_MS = 1000;

const PROBE = [
  'const real = () => performance.timeOrigin + performance.now();',
  'class Later extends Date {}',
  'process.stdout.write(JSON.stringify({',
  '  now: Date.now() - real(),',
  '  constructed: new Date().getTime() - real(),',
  '  called: Date.parse(Date()) - real(),',
  '  subclass: new Later().getTime() - real(),',
  '  subclassWithArgument: new Later(5).getTime(),',
  '  explicit: new Date(0).getTime(),',
  '  undefinedArgument: Number.isNaN(new Date(undefined).getTime()),',
  "  parse: Date.parse('2026-01-01T00:00:00.000Z'),",
  '  utc: Date.UTC(2026, 0, 1),',
  '  instance: new Date() instanceof Date,',
  '  tag: Object.prototype.toString.call(new Date()),',
  '  constructorIsDate: new Date().constructor === Date,',
  "  installed: Object.prototype.hasOwnProperty.call(globalThis, Symbol.for('zensu.testClockShift')),",
  '}));',
].join('\n');

function tempDir(label) {
  return fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), `clock-shift-${label}-`)));
}

function cleanEnv(extra = {}) {
  const env = { ...process.env };
  delete env.NODE_OPTIONS;
  delete env[VARIABLE];
  return { ...env, ...extra };
}

function probe(args, env) {
  const result = childProcess.spawnSync(process.execPath, [...args, '-e', PROBE], { env, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}

function near(actual, expected, tolerance = TOLERANCE_MS) {
  assert.ok(Math.abs(actual - expected) <= tolerance, `expected ${expected} ± ${tolerance}, got ${actual}`);
}

function assertUnshifted(out) {
  near(out.now, 0);
  near(out.constructed, 0);
  near(out.called, 0, 2 * TOLERANCE_MS);
  assert.equal(out.installed, false);
}

function assertShifted(out, days) {
  const shiftMs = Math.round(days * DAY_MS);
  near(out.now, shiftMs);
  near(out.constructed, shiftMs);
  near(out.called, shiftMs, 2 * TOLERANCE_MS);
  near(out.subclass, shiftMs);
  assert.equal(out.installed, true);
}

test('the preload leaves the clock alone when the shift is unset, empty or zero', () => {
  assertUnshifted(probe(['--require', PRELOAD], cleanEnv()));
  assertUnshifted(probe(['--require', PRELOAD], cleanEnv({ [VARIABLE]: '' })));
  assertUnshifted(probe(['--require', PRELOAD], cleanEnv({ [VARIABLE]: '0' })));
});

test('the preload shifts Date.now, new Date() and Date() without arguments, and nothing else', () => {
  const out = probe(['--require', PRELOAD], cleanEnv({ [VARIABLE]: '45' }));
  assertShifted(out, 45);
  assert.equal(out.subclassWithArgument, 5);
  assert.equal(out.explicit, 0);
  assert.equal(out.undefinedArgument, true);
  assert.equal(out.parse, 1767225600000);
  assert.equal(out.utc, 1767225600000);
  assert.equal(out.instance, true);
  assert.equal(out.tag, '[object Date]');
  assert.equal(out.constructorIsDate, true);
});

test('the preload takes a negative or fractional number of days', () => {
  assertShifted(probe(['--require', PRELOAD], cleanEnv({ [VARIABLE]: '-1.5' })), -1.5);
  assertShifted(probe(['--require', PRELOAD], cleanEnv({ [VARIABLE]: '0.25' })), 0.25);
});

test('the preload refuses a malformed shift instead of running on the real clock', () => {
  for (const raw of ['45d', '1e3', ' 45', '45 ', '+45', 'NaN', '0x10', '.5', '4 5', '--45']) {
    const result = childProcess.spawnSync(process.execPath, ['--require', PRELOAD, '-e', 'process.stdout.write("ran")'], {
      env: cleanEnv({ [VARIABLE]: raw }),
      encoding: 'utf8',
    });
    assert.notEqual(result.status, 0, `${JSON.stringify(raw)} was accepted`);
    assert.equal(result.stdout, '');
    assert.match(result.stderr, /ZENSU_TEST_CLOCK_SHIFT_DAYS must be a decimal number of days/);
  }
});

test('a second copy of the preload in one process does not shift twice', () => {
  const directory = tempDir('copy');
  const copy = path.join(directory, 'clock-shift.cjs');
  fs.copyFileSync(PRELOAD, copy);
  assertShifted(probe(['--require', PRELOAD, '--require', copy], cleanEnv({ [VARIABLE]: '45' })), 45);
});

test('NODE_OPTIONS in the form the runner writes carries the shift into grandchild processes', () => {
  const directory = path.join(tempDir('spaced'), 'with space');
  fs.mkdirSync(directory);
  const copy = path.join(directory, 'clock-shift.cjs');
  fs.copyFileSync(PRELOAD, copy);
  const env = runner.childEnvironment(cleanEnv(), 45);
  env.NODE_OPTIONS = env.NODE_OPTIONS.replace(JSON.stringify(PRELOAD), JSON.stringify(copy));
  const parent = [
    "const { execFileSync } = require('node:child_process');",
    `process.stdout.write(execFileSync(process.execPath, ['-e', ${JSON.stringify(PROBE)}], { encoding: 'utf8' }));`,
  ].join('\n');
  const result = childProcess.spawnSync(process.execPath, ['-e', parent], { env, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assertShifted(JSON.parse(result.stdout), 45);
});

test('the runner appends its preload to NODE_OPTIONS, drops the nested-run marker and names the variable the preload reads', () => {
  const env = runner.childEnvironment({ NODE_OPTIONS: '--max-old-space-size=4096', KEPT: 'yes', NODE_TEST_CONTEXT: 'child-v8' }, 45);
  assert.equal(env.NODE_OPTIONS, `--max-old-space-size=4096 --require ${JSON.stringify(PRELOAD)}`);
  assert.equal(env[VARIABLE], '45');
  assert.equal(env.KEPT, 'yes');
  assert.equal(Object.prototype.hasOwnProperty.call(env, 'NODE_TEST_CONTEXT'), false);
  assert.equal(runner.childEnvironment({ NODE_OPTIONS: '  ' }, 7).NODE_OPTIONS, `--require ${JSON.stringify(PRELOAD)}`);
  assert.equal(runner.SHIFT_VARIABLE, VARIABLE);
  assert.ok(fs.readFileSync(PRELOAD, 'utf8').includes(`'${VARIABLE}'`));
});

function entry(overrides = {}) {
  return {
    file: 'tests/structure/a.test.js',
    test: 'reads a file age',
    dependency: 'file-mtime',
    reason: 'the code under test compares a real file mtime with Date.now()',
    ...overrides,
  };
}

function allowlist(entries = [entry()], overrides = {}) {
  return { schemaVersion: 1, shiftDays: 45, entries, ...overrides };
}

test('the allowlist validator refuses every malformed shape', () => {
  assert.doesNotThrow(() => runner.validateAllowlist(allowlist()));
  const cases = [
    [null, /exactly the keys/],
    [[], /exactly the keys/],
    [{ ...allowlist(), extra: true }, /exactly the keys/],
    [allowlist(undefined, { schemaVersion: 2 }), /schemaVersion must be 1/],
    [allowlist(undefined, { shiftDays: 0 }), /positive whole number/],
    [allowlist(undefined, { shiftDays: 1.5 }), /positive whole number/],
    [allowlist(undefined, { shiftDays: '45' }), /positive whole number/],
    [allowlist(undefined, { entries: {} }), /entries must be an array/],
    [allowlist([{ ...entry(), extra: 1 }]), /entry 0 must have exactly the keys/],
    [allowlist([{ file: 'a.test.js', test: 't', dependency: 'file-mtime' }]), /entry 0 must have exactly the keys/],
    [allowlist([entry({ file: '../a.test.js' })]), /relative \*\.test\.js path/],
    [allowlist([entry({ file: 'tests/./a.test.js' })]), /relative \*\.test\.js path/],
    [allowlist([entry({ file: '/abs/a.test.js' })]), /relative \*\.test\.js path/],
    [allowlist([entry({ file: 'tests/a.js' })]), /relative \*\.test\.js path/],
    [allowlist([entry({ test: '  ' })]), /top-level test of at most 300/],
    [allowlist([entry({ test: 'x'.repeat(301) })]), /top-level test of at most 300/],
    [allowlist([entry({ dependency: 'wall-clock' })]), /dependency must be one of/],
    [allowlist([entry({ reason: 'too short' })]), /reason of at least 20/],
    [allowlist([entry(), entry()]), /entry 1 repeats tests\/structure\/a\.test\.js > reads a file age/],
  ];
  for (const [value, pattern] of cases) {
    assert.throws(() => runner.validateAllowlist(value), (error) => error instanceof runner.ClockShiftError && pattern.test(error.message));
  }
});

function eventLine(root, file, name, outcome, message = null) {
  return JSON.stringify({ outcome, file: path.join(root, file), name, failureType: null, message });
}

test('outcomes are keyed by file and top-level test, and a crashed file by the file alone', () => {
  const root = tempDir('collect');
  const files = ['a.test.js', 'b.test.js'].map((name) => path.join(root, name));
  for (const file of files) fs.writeFileSync(file, '');
  const lines = [
    eventLine(root, 'a.test.js', 'passes', 'pass'),
    eventLine(root, 'a.test.js', 'twice', 'pass'),
    eventLine(root, 'a.test.js', 'twice', 'fail', 'second run failed'),
    eventLine(root, 'a.test.js', 'skipped', 'skip'),
    eventLine(root, 'b.test.js', path.join(root, 'b.test.js'), 'fail', 'test failed'),
    '',
  ];
  const collected = runner.collectOutcomes(lines, root, files);
  assert.deepEqual([...collected.seenFiles].sort(), ['a.test.js', 'b.test.js']);
  assert.deepEqual([...collected.results.values()].map((result) => [result.file, result.test, result.outcome]), [
    ['a.test.js', 'passes', 'pass'],
    ['a.test.js', 'twice', 'fail'],
    ['a.test.js', 'skipped', 'skip'],
    ['b.test.js', null, 'fail'],
  ]);
  assert.throws(() => runner.collectOutcomes([eventLine(root, 'c.test.js', 'x', 'pass')], root, files), /outside this run/);
});

function collectedOf(results, seenFiles) {
  return {
    results: new Map(results.map((result) => [JSON.stringify([result.file, result.test]), { message: null, ...result }])),
    seenFiles: new Set(seenFiles),
  };
}

test('the verdict separates allowed, unexpected, stale and unexercised results', () => {
  const list = allowlist([
    entry({ file: 'a.test.js', test: 'allowed failure' }),
    entry({ file: 'a.test.js', test: 'now passes' }),
    entry({ file: 'a.test.js', test: 'renamed away' }),
    entry({ file: 'a.test.js', test: 'skipped here' }),
  ]);
  const collected = collectedOf([
    { file: 'a.test.js', test: 'allowed failure', outcome: 'fail' },
    { file: 'a.test.js', test: 'now passes', outcome: 'pass' },
    { file: 'a.test.js', test: 'skipped here', outcome: 'skip' },
    { file: 'a.test.js', test: 'new failure', outcome: 'fail', message: 'boom' },
    { file: 'b.test.js', test: null, outcome: 'fail', message: 'test failed' },
  ], ['a.test.js', 'b.test.js']);
  const verdict = runner.judge(list, collected, ['a.test.js', 'b.test.js', 'c.test.js'], false);
  assert.deepEqual(verdict.allowed, [{ file: 'a.test.js', test: 'allowed failure', dependency: 'file-mtime' }]);
  assert.deepEqual(verdict.unexpected, [
    { file: 'a.test.js', test: 'new failure', message: 'boom' },
    { file: 'b.test.js', test: null, message: 'test failed' },
    { file: 'c.test.js', test: null, message: 'the file reported no test result' },
  ]);
  assert.deepEqual(verdict.stale.map((item) => [item.test, item.why]), [
    ['now passes', 'it passes under the shifted clock'],
    ['renamed away', 'no top-level test of this name ran'],
  ]);
  assert.deepEqual(verdict.unexercised, [{ file: 'a.test.js', test: 'skipped here', outcome: 'skip' }]);
});

test('an entry for a file outside the run is stale in a full run and ignored in a partial one', () => {
  const list = allowlist([entry({ file: 'gone.test.js', test: 'anything' })]);
  const collected = collectedOf([{ file: 'a.test.js', test: 'passes', outcome: 'pass' }], ['a.test.js']);
  assert.deepEqual(runner.judge(list, collected, ['a.test.js'], false).stale.map((item) => item.why), ['its file is not one of the unit files this run covers']);
  assert.deepEqual(runner.judge(list, collected, ['a.test.js'], true).stale, []);
});

const CLOCK_FILE = [
  "const test = require('node:test');",
  "const assert = require('node:assert/strict');",
  'const real = () => performance.timeOrigin + performance.now();',
  "test('reads the real clock', () => {",
  "  assert.ok(Math.abs(Date.now() - real()) < 60000, 'Date is shifted');",
  '});',
  "test('ignores the clock', () => {",
  '  assert.equal(1 + 1, 2);',
  '});',
  '',
].join('\n');

function sandbox() {
  const root = tempDir('runner');
  fs.writeFileSync(path.join(root, 'clock.test.js'), CLOCK_FILE);
  fs.writeFileSync(path.join(root, 'crash.test.js'), "require('node:test');\nthrow new Error('load failure');\n");
  return root;
}

function runRunner(root, entries, files, extraArgs = []) {
  const list = path.join(root, 'allowlist.json');
  fs.writeFileSync(list, JSON.stringify(allowlist(entries)));
  const summary = path.join(root, 'summary.json');
  const result = childProcess.spawnSync(process.execPath, [
    RUNNER, '--root', root, '--allowlist', list, '--summary', summary, ...extraArgs, ...files.map((file) => path.join(root, file)),
  ], { cwd: root, env: cleanEnv(), encoding: 'utf8' });
  return { ...result, summary: fs.existsSync(summary) ? JSON.parse(fs.readFileSync(summary, 'utf8')) : null };
}

test('the runner passes when every failure under the shift is allowlisted', () => {
  const root = sandbox();
  const result = runRunner(root, [entry({ file: 'clock.test.js', test: 'reads the real clock' })], ['clock.test.js']);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /^clock-shift: ALLOWED clock\.test\.js > reads the real clock \[file-mtime\]$/m);
  assert.match(result.stdout, /^clock-shift: PASS — no failure outside the allowlist and no stale entry \(1 allowed\)$/m);
  assert.equal(result.summary.shiftDays, 45);
  assert.equal(result.summary.files, 1);
  assert.deepEqual(result.summary.unexpected, []);
  assert.deepEqual(result.summary.stale, []);
});

test('the runner fails on a failure outside the allowlist and on a file that crashes', () => {
  const root = sandbox();
  const result = runRunner(root, [], ['clock.test.js', 'crash.test.js']);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.deepEqual(result.summary.unexpected.map((item) => [item.file, item.test]), [
    ['clock.test.js', 'reads the real clock'],
    ['crash.test.js', null],
  ]);
  assert.match(result.summary.unexpected[0].message, /Date is shifted/);
  assert.match(result.stdout, /^clock-shift: FAIL — 2 failure\(s\) outside the allowlist, 0 stale allowlist entries$/m);
});

test('the runner fails on an entry whose test passes or no longer exists', () => {
  const root = sandbox();
  const result = runRunner(root, [
    entry({ file: 'clock.test.js', test: 'reads the real clock' }),
    entry({ file: 'clock.test.js', test: 'ignores the clock' }),
    entry({ file: 'clock.test.js', test: 'was renamed' }),
  ], ['clock.test.js']);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.deepEqual(result.summary.stale.map((item) => [item.test, item.why]), [
    ['ignores the clock', 'it passes under the shifted clock'],
    ['was renamed', 'no top-level test of this name ran'],
  ]);
  assert.match(result.stdout, /^clock-shift: STALE clock\.test\.js > ignores the clock — it passes under the shifted clock; remove or correct its allowlist entry$/m);
});

test('the runner refuses a malformed allowlist, an unknown option and a file outside its root', () => {
  const root = sandbox();
  const malformed = runRunner(root, [entry({ dependency: 'wall-clock' })], ['clock.test.js']);
  assert.equal(malformed.status, 2);
  assert.match(malformed.stderr, /^clock-shift: allowlist entry 0 dependency must be one of /m);
  assert.equal(malformed.summary, null);
  const unknown = runRunner(root, [], ['clock.test.js'], ['--days']);
  assert.equal(unknown.status, 2);
  assert.match(unknown.stderr, /unknown option --days; usage: run-clock-shift\.js/);
  const outside = runRunner(root, [], ['../elsewhere.test.js']);
  assert.equal(outside.status, 2);
  assert.match(outside.stderr, /is not inside /);
});

function unquote(literal) {
  const body = literal.slice(1, -1);
  return body.replace(/\\(u\{[0-9a-fA-F]+\}|u[0-9a-fA-F]{4}|x[0-9a-fA-F]{2}|[\s\S])/g, (_match, sequence) => {
    if (sequence.startsWith('u{')) return String.fromCodePoint(parseInt(sequence.slice(2, -1), 16));
    if (sequence.startsWith('u') && sequence.length === 5) return String.fromCharCode(parseInt(sequence.slice(1), 16));
    if (sequence.startsWith('x') && sequence.length === 3) return String.fromCharCode(parseInt(sequence.slice(1), 16));
    return { n: '\n', t: '\t', r: '\r', b: '\b', f: '\f', v: '\v', 0: '\0' }[sequence] ?? sequence;
  });
}

function topLevelTests(source) {
  const names = [];
  const pattern = /^test\(\s*('(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"|`(?:[^`\\$]|\\.)*`)/gm;
  for (const match of source.matchAll(pattern)) names.push(unquote(match[1]));
  return names;
}

test('every shipped allowlist entry names a top-level test its file registers', () => {
  const shipped = runner.loadAllowlist(ALLOWLIST);
  assert.equal(shipped.shiftDays, 45);
  for (const item of shipped.entries) {
    const file = path.join(ROOT, item.file);
    assert.ok(fs.existsSync(file), `${item.file} does not exist`);
    assert.ok(item.file.startsWith('tests/structure/'), `${item.file} is not a tests/structure unit file`);
    assert.ok(topLevelTests(fs.readFileSync(file, 'utf8')).includes(item.test), `${item.file} registers no top-level test named ${JSON.stringify(item.test)}`);
  }
  assert.deepEqual(topLevelTests("test('it\\'s \\u0041', () => {});\ntest(\"two\", () => {});\n  test('nested', () => {});\n"), ["it's A", 'two']);
});

test('the scheduled workflow runs the pass daily and on dispatch on ubuntu, and the pull-request workflow does not run it', () => {
  const scheduled = YAML.parse(fs.readFileSync(SCHEDULED, 'utf8'));
  assert.deepEqual(Object.keys(scheduled.on).sort(), ['schedule', 'workflow_dispatch']);
  assert.equal(scheduled.on.schedule.length, 1);
  assert.match(scheduled.on.schedule[0].cron, /^\d{1,2} \d{1,2} \* \* \*$/);
  assert.deepEqual(scheduled.permissions, { contents: 'read' });
  const jobs = Object.values(scheduled.jobs);
  assert.ok(jobs.length > 0);
  for (const job of jobs) assert.equal(job['runs-on'], 'ubuntu-latest');
  const runs = jobs.flatMap((job) => job.steps || []).map((step) => step.run).filter(Boolean);
  assert.ok(runs.includes('node tests/run-clock-shift.js'), `no step runs the pass: ${JSON.stringify(runs)}`);
  assert.doesNotMatch(fs.readFileSync(PULL_REQUEST_WORKFLOW, 'utf8'), /run-clock-shift|clock-shift/);
});
