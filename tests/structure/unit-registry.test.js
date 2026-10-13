'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const registry = require('./lib-unit-registry.js');

const UNIT = 'tests/structure/sample.test.js';
const DRIVER = 'tests/structure/test-sample.sh';

function makeRoot(t, options = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'unit-registry-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, 'tests', 'structure'), { recursive: true });
  fs.mkdirSync(path.join(root, 'tests', 'profiles'), { recursive: true });
  fs.writeFileSync(path.join(root, UNIT), options.unitSource ?? cases(3));
  fs.writeFileSync(path.join(root, DRIVER), options.driverSource ?? [
    '#!/bin/bash',
    '. "$(dirname "$0")/lib-unit-registry.sh"',
    'unit_check "S1" tests/structure/sample.test.js',
    'unit_check_done "S2"',
    '',
  ].join('\n'));
  fs.writeFileSync(path.join(root, 'tests', 'profiles', 'promptfoo-local-only.v1.json'), JSON.stringify({
    schemaVersion: 1,
    ciStructureTests: ['test-sample.sh'],
    localStructureTests: [],
    nodeDepsStructureTests: [],
    ciOfflineSuites: [],
  }));
  writeRegistry(root, options.files ?? [entry()]);
  fs.writeFileSync(path.join(root, 'tests', 'SUITE-OVERVIEW.md'), [
    '# Overview',
    '<!-- unit-registry:begin totals -->',
    'stale',
    '<!-- unit-registry:end totals -->',
    '## 4',
    '<!-- unit-registry:begin section-4 -->',
    'stale',
    '<!-- unit-registry:end section-4 -->',
    '',
  ].join('\n'));
  return root;
}

function entry(overrides = {}) {
  return {
    path: UNIT,
    registered: 3,
    runs: [{ driver: DRIVER }],
    summary: 'sample cases',
    ...overrides,
  };
}

function writeRegistry(root, files) {
  fs.writeFileSync(path.join(root, registry.REGISTRY_REL), JSON.stringify({ schemaVersion: 1, files }));
}

function cases(count, extra = '') {
  const lines = ["const test = require('node:test');"];
  for (let index = 1; index <= count; index += 1) lines.push(`test('case ${index}', () => {});`);
  if (extra) lines.push(extra);
  return `${lines.join('\n')}\n`;
}

function runNode(root, relative) {
  const env = { ...process.env };
  delete env.NODE_TEST_CONTEXT;
  const run = spawnSync(process.execPath, ['--test', '--test-reporter=tap', relative], { cwd: root, env, encoding: 'utf8' });
  return { text: `${run.stdout}${run.stderr}`, rc: run.status };
}

function grade(t, unitSource, overrides = {}, host = 'linux') {
  const root = makeRoot(t, { unitSource });
  const run = runNode(root, UNIT);
  return registry.verify(entry(overrides), run.text, run.rc, host);
}

function captureMain(argv) {
  let text = '';
  const code = registry.main(argv, { write: (chunk) => { text += chunk; } });
  return { code, text };
}

test('a passing file grades pass with its counts', (t) => {
  const verdict = grade(t, cases(3));
  assert.equal(verdict.ok, true, verdict.message);
  assert.match(verdict.message, /3\/3 passed, 0 skipped \(ceiling 0 on linux\)/);
});

test('an emptied file fails even when the entry declares registered 1', (t) => {
  const verdict = grade(t, '', { registered: 1 });
  assert.equal(verdict.ok, false);
  assert.match(verdict.message, /registers no case of its own; node counted the file itself/);
});

test('a removed case fails with the removal message', (t) => {
  const verdict = grade(t, cases(2));
  assert.equal(verdict.ok, false);
  assert.equal(verdict.message, `${UNIT}: node registered 2, the registry declares 3; 1 case(s) were removed; lower registered only if the removal was intended`);
});

test('an added case fails with the raise message', (t) => {
  const verdict = grade(t, cases(4));
  assert.equal(verdict.ok, false);
  assert.equal(verdict.message, `${UNIT}: node registered 4, the registry declares 3; raise registered to 4 in tests/profiles/unit-files.v1.json`);
});

test('a case switched to skip fails beyond the host ceiling and passes within it', (t) => {
  const source = cases(2, "test('case 3', { skip: true }, () => {});");
  const beyond = grade(t, source);
  assert.equal(beyond.ok, false);
  assert.match(beyond.message, /1 case\(s\) skipped or todo on linux; the registry allows 0 \(case 3\)/);
  assert.equal(grade(t, source, { skips: { linux: 1 } }).ok, true);
  assert.equal(grade(t, source, { skips: { darwin: 1 } }).ok, false);
});

test('a todo case counts against the same ceiling', (t) => {
  const verdict = grade(t, cases(2, "test('case 3', { todo: true }, () => {});"));
  assert.equal(verdict.ok, false);
  assert.match(verdict.message, /skipped or todo on linux/);
});

test('a guard passes only under its exact title', (t) => {
  assert.equal(grade(t, cases(3), { guards: ['case 2'] }).ok, true);
  const renamed = grade(t, cases(3).replace("'case 2'", "'case two'"), { guards: ['case 2'] });
  assert.equal(renamed.ok, false);
  assert.match(renamed.message, /guarded case "case 2" did not pass/);
  const skipped = grade(t, cases(3).replace("test('case 2', ()", "test('case 2', { skip: true }, ()"), { guards: ['case 2'], skips: { linux: 1 } });
  assert.equal(skipped.ok, false);
  assert.match(skipped.message, /guarded case "case 2" did not pass/);
});

test('a failing case fails before any count is compared', (t) => {
  const verdict = grade(t, cases(2, "test('case 3', () => { throw new Error('boom'); });"));
  assert.equal(verdict.ok, false);
  assert.match(verdict.message, /node exited 1 with 1 failing and 0 cancelled case\(s\)/);
});

test('a run without a summary is reported as truncated', () => {
  const verdict = registry.verify(entry(), 'TAP version 13\nok 1 - case 1\n', 0, 'linux');
  assert.equal(verdict.ok, false);
  assert.match(verdict.message, /no TAP summary was read/);
});

test('the TAP parse strips CR, keeps the last summary and unescapes titles', () => {
  const text = [
    'TAP version 13',
    'ok 1 - a \\# b',
    'ok 2 - skipped one # SKIP not here',
    '# tests 9',
    '# tests 2\r',
    '# pass 1\r',
    '# fail 0',
    '# skipped 1',
    'stray line after the summary',
  ].join('\n');
  const parsed = registry.parseTap(text);
  assert.equal(parsed.summary.tests, 2);
  assert.equal(parsed.summary.pass, 1);
  assert.deepEqual(parsed.points.map((point) => [point.name, point.directive]), [['a # b', null], ['skipped one', 'SKIP']]);
});

test('every load error names its cause', (t) => {
  const root = makeRoot(t);
  const expectations = [
    [[entry({ registered: 0 })], /registered must be an integer of at least 1, got 0/],
    [[entry({ registered: '~80' })], /registered must be an integer of at least 1, got "~80"/],
    [[entry(), entry()], /duplicate path tests\/structure\/sample\.test\.js at entries 0 and 1/],
    [[entry({ floor: 3 })], /unknown key "floor"/],
    [[entry({ path: 'tests/structure/missing.test.js' })], /the file does not exist/],
    [[entry({ summary: 'a | b' })], /summary must be one non-empty line without "\|"/],
    [[entry({ skips: { windows: 2 } })], /unknown host class "windows"/],
    [[entry({ skips: { linux: 0 } })], /skips\.linux must be an integer of at least 1/],
    [[entry({ runs: [] })], /runs must list at least one/],
    [[entry({ runs: [{ driver: 'tests/structure/test-missing.sh' }] })], /names a driver that does not exist/],
  ];
  for (const [files, pattern] of expectations) {
    writeRegistry(root, files);
    const { errors } = registry.loadRegistry(root);
    assert.ok(errors.some((error) => pattern.test(error)), `${pattern} not in ${errors.join(' / ')}`);
  }
  fs.writeFileSync(path.join(root, registry.REGISTRY_REL), '{ not json');
  assert.match(registry.loadRegistry(root).errors[0], /not JSON/);
  fs.rmSync(path.join(root, registry.REGISTRY_REL));
  assert.match(registry.loadRegistry(root).errors[0], /unreadable \(ENOENT\)/);
});

test('the census names an unregistered file, a nested registration and a stale count', (t) => {
  const root = makeRoot(t);
  assert.deepEqual(registry.census(root), []);
  fs.writeFileSync(path.join(root, 'tests', 'structure', 'other.test.js'), cases(1));
  assert.deepEqual(registry.census(root), ['tests/structure/other.test.js: no entry in tests/profiles/unit-files.v1.json; add one']);
  fs.rmSync(path.join(root, 'tests', 'structure', 'other.test.js'));
  fs.writeFileSync(path.join(root, UNIT), cases(4));
  assert.deepEqual(registry.census(root), [`${UNIT}: registers 4, the registry declares 3; raise registered to 4 in tests/profiles/unit-files.v1.json`]);
  fs.writeFileSync(path.join(root, UNIT), `${cases(3)}for (const n of [1]) {\n  test('loop ' + n, () => {});\n}\n`);
  assert.match(registry.census(root)[0], /registers a case below column 0/);
});

test('the census refuses a subtest and a describe or it registration, which the static count cannot see', (t) => {
  const root = makeRoot(t);
  fs.writeFileSync(path.join(root, UNIT), `${cases(2)}test('case 3', async (t) => {\n  await t.test('inner', () => {});\n});\n`);
  assert.match(registry.census(root)[0], /registers a case below column 0, as a subtest, or through describe or it/);
  fs.writeFileSync(path.join(root, UNIT), `${cases(3)}describe('group', () => {\n  it('member', () => {});\n});\n`);
  assert.match(registry.census(root)[0], /registers a case below column 0, as a subtest, or through describe or it/);
});

test('in a git work tree the census skips ignored files and still names an untracked unregistered one', (t) => {
  const root = makeRoot(t);
  const fixture = path.join(root, 'tests', 'e2e', 'fixtures', 'probe', 'math.test.js');
  fs.mkdirSync(path.dirname(fixture), { recursive: true });
  fs.writeFileSync(fixture, cases(1));
  fs.writeFileSync(path.join(root, '.gitignore'), 'tests/e2e/fixtures/\n');
  assert.deepEqual(registry.census(root), ['tests/e2e/fixtures/probe/math.test.js: no entry in tests/profiles/unit-files.v1.json; add one']);
  const init = spawnSync('git', ['-C', root, 'init', '-q'], { encoding: 'utf8' });
  assert.equal(init.status, 0, init.stderr);
  assert.deepEqual(registry.census(root), []);
  fs.writeFileSync(path.join(root, 'tests', 'structure', 'other.test.js'), cases(1));
  assert.deepEqual(registry.census(root), ['tests/structure/other.test.js: no entry in tests/profiles/unit-files.v1.json; add one']);
});

test('the rendered regions round-trip and a hand edit is reported with the render command', (t) => {
  const root = makeRoot(t);
  const rendered = registry.render(root);
  assert.deepEqual(rendered.errors, []);
  assert.match(rendered.regions['section-4'], /\| `structure\/sample\.test\.js` \| 3 \| – \| `test-sample\.sh` \| sample cases \|/);
  assert.match(rendered.regions.totals, /\*\*1\*\* suites, 1 CI-blocking \+ 0 Promptfoo local-only/);
  const overviewFile = path.join(root, 'tests', 'SUITE-OVERVIEW.md');
  const stale = fs.readFileSync(overviewFile, 'utf8');
  assert.equal(registry.checkOverview(root, rendered.regions, stale).length, 2);
  const written = registry.writeOverview(stale, rendered.regions).text;
  assert.deepEqual(registry.checkOverview(root, rendered.regions, written), []);
  const emptied = stale.replace('<!-- unit-registry:begin totals -->\nstale\n', '<!-- unit-registry:begin totals -->\n');
  assert.equal(registry.checkOverview(root, rendered.regions, emptied).length, 2);
  assert.deepEqual(registry.checkOverview(root, rendered.regions, registry.writeOverview(emptied, rendered.regions).text), []);
  assert.deepEqual(registry.writeOverview('# no markers\n', rendered.regions).problems, [
    'tests/SUITE-OVERVIEW.md: the totals region markers are missing; restore them and run node tests/structure/lib-unit-registry.js render --write',
  ]);
  const edited = written.replace('| 3 |', '| 4 |');
  assert.deepEqual(registry.checkOverview(root, rendered.regions, edited), [
    'tests/SUITE-OVERVIEW.md: the section-4 region differs from its sources; run node tests/structure/lib-unit-registry.js render --write',
  ]);
});

test('the generated table orders its rows by code point, whatever the locale collates', (t) => {
  const root = makeRoot(t, {
    files: [entry(), entry({ path: 'tests/structure/a_b.test.js', registered: 1 }), entry({ path: 'tests/structure/a-c.test.js', registered: 1 })],
  });
  fs.writeFileSync(path.join(root, 'tests', 'structure', 'a_b.test.js'), cases(1));
  fs.writeFileSync(path.join(root, 'tests', 'structure', 'a-c.test.js'), cases(1));
  const rendered = registry.render(root);
  assert.deepEqual(rendered.errors, []);
  const order = rendered.regions['section-4'].split('\n').filter((line) => line.startsWith('| `')).map((line) => line.split('`')[1]);
  assert.deepEqual(order, ['structure/a-c.test.js', 'structure/a_b.test.js', 'structure/sample.test.js']);
});

test('the driver audit flags each broken convention and passes a clean driver', (t) => {
  const clean = makeRoot(t);
  assert.deepEqual(registry.driverProblems(clean), []);
  const broken = makeRoot(t, {
    driverSource: ['#!/bin/bash', 'exit 0', 'node --test tests/structure/other.test.js', 'unit_run x', ''].join('\n'),
  });
  const problems = registry.driverProblems(broken).join('\n');
  assert.match(problems, /does not source tests\/structure\/lib-unit-registry\.sh/);
  assert.match(problems, /never names tests\/structure\/sample\.test\.js/);
  assert.match(problems, /never calls unit_registry_done or unit_check_done/);
  assert.match(problems, /"exit 0" at line 2 comes before its first unit call at line 4/);
  assert.match(problems, /spawns node --test itself/);
});

test('the driver audit flags an exit 0 inside a top-level branch before the first unit call', (t) => {
  const root = makeRoot(t, {
    driverSource: [
      '#!/bin/bash',
      '. "$(dirname "$0")/lib-unit-registry.sh"',
      'case "$(uname -s)" in',
      '  MINGW*)',
      '    exit 0',
      '    ;;',
      'esac',
      'unit_check "S1" tests/structure/sample.test.js',
      'unit_check_done "S2"',
      '',
    ].join('\n'),
  });
  assert.match(registry.driverProblems(root).join('\n'), /"exit 0" at line 5 comes before its first unit call at line 8/);
});

test('every node --test spawn needs its own unit_grade call, and a check label naming one is no spawn', (t) => {
  const graded = [
    '#!/bin/bash',
    '. "$(dirname "$0")/lib-unit-registry.sh"',
    'node --test --test-reporter=tap tests/structure/sample.test.js > "$LOG" 2>&1',
    'UNIT_RUN_TEE=1 unit_grade tests/structure/sample.test.js "$LOG" "$?"',
    'check "every node --test run is graded through unit_grade" PASS',
    'unit_check_done "S2"',
    '',
  ];
  const root = makeRoot(t, { driverSource: graded.join('\n') });
  assert.deepEqual(registry.driverProblems(root), []);
  const second = [...graded.slice(0, 4), 'OUT="$(cd "$ROOT" && timeout 60 "$NODE" --import x --test tests/structure/other.test.js)"', ...graded.slice(4)];
  fs.writeFileSync(path.join(root, DRIVER), second.join('\n'));
  assert.deepEqual(registry.driverProblems(root), [
    `${DRIVER}: spawns node --test itself 2 time(s) but calls unit_grade 1 time(s); run unit files through unit_run, or grade each run through unit_grade`,
  ]);
});

test('only a CI suite line outside a comment reaches a driver that is not itself a CI suite', (t) => {
  const inner = 'tests/inner/run.sh';
  const root = makeRoot(t, {
    files: [entry({ runs: [{ driver: inner }] })],
    driverSource: ['#!/bin/bash', '# drives tests/inner/run.sh', ''].join('\n'),
  });
  fs.mkdirSync(path.join(root, 'tests', 'inner'), { recursive: true });
  fs.writeFileSync(path.join(root, inner), [
    '#!/bin/bash',
    '. "$ROOT/tests/structure/lib-unit-registry.sh"',
    'unit_check "S1" tests/structure/sample.test.js',
    'unit_check_done "S2"',
    '',
  ].join('\n'));
  assert.match(registry.driverProblems(root).join('\n'), /tests\/inner\/run\.sh: no CI structure suite runs it/);
  fs.writeFileSync(path.join(root, DRIVER), ['#!/bin/bash', 'bash "$ROOT/tests/inner/run.sh"', ''].join('\n'));
  assert.doesNotMatch(registry.driverProblems(root).join('\n'), /no CI structure suite runs it/);
});

test('verify refuses a caller that is not a registered driver and owned names what was never graded', (t) => {
  const root = makeRoot(t);
  const output = path.join(root, 'out.tap');
  const run = runNode(root, UNIT);
  fs.writeFileSync(output, run.text);
  fs.writeFileSync(path.join(root, 'tests', 'structure', 'test-other.sh'), '#!/bin/bash\n');
  const refused = captureMain(['verify', '--root', root, '--cwd', root, '--path', UNIT, '--output', output, '--rc', '0', '--driver', 'tests/structure/test-other.sh', '--mode', '', '--host', 'linux']);
  assert.equal(refused.code, 2);
  assert.match(refused.text, /tests\/structure\/test-other\.sh is not a registered driver of this file/);
  const graded = captureMain(['verify', '--root', root, '--cwd', root, '--path', UNIT, '--output', output, '--rc', '0', '--driver', DRIVER, '--mode', '', '--host', 'linux']);
  assert.equal(graded.code, 0, graded.text);
  const missing = captureMain(['owned', '--root', root, '--cwd', root, '--driver', DRIVER, '--mode', '']);
  assert.equal(missing.code, 1);
  assert.match(missing.text, /never ran or graded tests\/structure\/sample\.test\.js/);
  assert.equal(captureMain(['owned', '--root', root, '--cwd', root, '--driver', DRIVER, '--mode', '', '--', path.join(root, UNIT)]).code, 0);
});

test('the host class is root for uid 0, the platform otherwise', () => {
  assert.equal(registry.hostClass('linux', () => 0), 'root');
  assert.equal(registry.hostClass('linux', () => 1000), 'linux');
  assert.equal(registry.hostClass('darwin', () => 501), 'darwin');
  assert.equal(registry.hostClass('win32', null), 'win32');
});
