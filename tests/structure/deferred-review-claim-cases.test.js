'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const root = path.resolve(__dirname, '..', '..');
const sourcePath = path.join(__dirname, 'test-deferred-review-claim.sh');
const manifestPath = path.join(root, 'tests', 'profiles', 'windows-ci.v1.json');
const {
  buildSelectedScript,
  discoverCases,
  exitCodeFor,
  main,
  parseRequestedCases,
  runScript,
} = require('./deferred-review-claim-cases.js');

const expectedCaseIds = [
  'P0',
  'P1',
  'P2',
  'P3',
  'L1',
  'L2',
  'C1',
  'C2',
  'C2f',
  'C2c',
  'C2d',
  'C2e',
  'C2b',
  'C3',
  'C4u',
  'C4t',
  'C4d',
  'C4s',
  'C4s-done',
  'C4s-transfer',
  'C4sf',
  'C4sr',
  'C4r',
  'C4rc',
  'C4ro',
  'C4ri',
  'C4rib',
  'C4ris',
  'C4risb',
  'C4',
  'C5',
  'C6',
  'C6a',
  'C6b',
  'C7',
  'C8',
];

test('discovers exactly the 36 isolated deferred-review cases in source order', () => {
  const source = fs.readFileSync(sourcePath, 'utf8');
  const discovered = discoverCases(source);
  assert.deepEqual(discovered.map(({ id }) => id), expectedCaseIds);
  assert.equal(new Set(discovered.map(({ id }) => id)).size, 36);
});

test('the four Windows profiles assign every case exactly once', () => {
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  const assigned = [];
  for (const profile of Object.values(manifest.profiles)) {
    const deferred = profile.suites.filter(
      (suite) => suite.path === 'tests/structure/test-deferred-review-claim.sh',
    );
    assert.equal(deferred.length, 1);
    assert.deepEqual(deferred[0].args.slice(0, 1), ['--cases']);
    assigned.push(...deferred[0].args[1].split(','));
  }
  assert.equal(new Set(assigned).size, assigned.length);
  assert.deepEqual(
    [...assigned].sort(),
    [...expectedCaseIds].sort(),
  );
});

test('every manifest shard generates valid Bash with exactly its assigned case ids', () => {
  const source = fs.readFileSync(sourcePath, 'utf8');
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-cases-shards-'));
  try {
    for (const [profileId, profile] of Object.entries(manifest.profiles)) {
      const entry = profile.suites.find(
        (suite) => suite.path === 'tests/structure/test-deferred-review-claim.sh',
      );
      const requested = entry.args[1].split(',');
      const generated = buildSelectedScript(source, requested);
      const file = path.join(directory, `${profileId}.sh`);
      fs.writeFileSync(file, generated, { mode: 0o700 });
      const syntax = spawnSync('bash', ['-n', file], { encoding: 'utf8', timeout: 30000 });
      assert.equal(syntax.status, 0, syntax.stderr);
      const checks = new Set(
        [...generated.matchAll(/^\s*check "([A-Za-z0-9-]+)\s/gm)].map((match) => match[1]),
      );
      assert.deepEqual([...checks].sort(), [...requested].sort(), profileId);
    }
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('case selection rejects empty, duplicate, and unknown identifiers', () => {
  const available = new Set(expectedCaseIds);
  assert.throws(() => parseRequestedCases('', available), /must not be empty/);
  assert.throws(() => parseRequestedCases('P0,P0', available), /duplicate case/);
  assert.throws(() => parseRequestedCases('missing', available), /unknown case/);
});

test('selected scripts retain shared setup and footer but exclude other case bodies', () => {
  const source = fs.readFileSync(sourcePath, 'utf8');
  const generated = buildSelectedScript(source, ['P2', 'C8']);
  assert.match(generated, /^#!\/bin\/bash/);
  assert.match(generated, /setup_case reset_without_artifacts/);
  assert.match(generated, /check "P2 /);
  assert.match(generated, /setup_case lease_refresh_none/);
  assert.match(generated, /check "C8 /);
  assert.doesNotMatch(generated, /setup_case owner_pid_liveness/);
  assert.doesNotMatch(generated, /check "P1 /);
  assert.match(generated, /test-deferred-review-claim: \$PASS PASS/);
});

test('the public selector lists cases and executes one real isolated case', () => {
  const listed = spawnSync('bash', [sourcePath, '--list-cases'], {
    cwd: root,
    encoding: 'utf8',
    timeout: 30000,
  });
  assert.equal(listed.status, 0, listed.stderr);
  assert.deepEqual(listed.stdout.trim().split(/\r?\n/), expectedCaseIds);

  const selected = spawnSync('bash', [sourcePath, '--cases', 'P2'], {
    cwd: root,
    encoding: 'utf8',
    timeout: 60000,
  });
  assert.equal(selected.status, 0, selected.stderr || selected.stdout);
  assert.match(selected.stdout, /PASS  P2 /);
  assert.doesNotMatch(selected.stdout, /PASS  P1 /);
  assert.match(selected.stdout, /test-deferred-review-claim: 1 PASS \/ 0 FAIL/);
});

test('the public selector fails closed before running duplicate or unknown cases', () => {
  for (const value of ['P2,P2', 'P2,missing']) {
    const rejected = spawnSync('bash', [sourcePath, '--cases', value], {
      cwd: root,
      encoding: 'utf8',
      timeout: 30000,
    });
    assert.equal(rejected.status, 2);
    assert.match(rejected.stderr, /duplicate case|unknown case/);
    assert.doesNotMatch(rejected.stdout, / PASS /);
  }
});

test('source discovery fails closed on malformed boundaries and ambiguous ids', () => {
  assert.throws(() => discoverCases(''), /non-empty text/);
  assert.throws(() => discoverCases(null), /non-empty text/);
  assert.throws(
    () => discoverCases('#!/bin/bash\nPID_WIRING_OK=1\ncheck "P0 ok"\n'),
    /boundaries are incomplete/,
  );
  assert.throws(
    () => discoverCases(
      '#!/bin/bash\nsetup_case early\ncheck "P1 ok"\nPID_WIRING_OK=1\ncheck "P0 ok"\necho "----"\n',
    ),
    /boundaries are out of order/,
  );
  assert.throws(
    () => discoverCases(
      '#!/bin/bash\nPID_WIRING_OK=1\ncheck "P0 ok"\nsetup_case one\ntrue\necho "----"\n',
    ),
    /exactly one unique check id/,
  );
  assert.throws(
    () => discoverCases(
      '#!/bin/bash\nPID_WIRING_OK=1\ncheck "P0 ok"\nsetup_case one\ncheck "P0 again"\necho "----"\n',
    ),
    /duplicate case ids/,
  );
});

test('selection helpers reject whitespace and malformed direct lists', () => {
  const available = new Set(expectedCaseIds);
  assert.throws(() => parseRequestedCases(null, available), /must not be empty/);
  assert.throws(() => parseRequestedCases('P0, P1', available), /without spaces/);
  const source = fs.readFileSync(sourcePath, 'utf8');
  assert.throws(() => buildSelectedScript(source, []), /must not be empty/);
  assert.throws(() => buildSelectedScript(source, ['P0', 'P0']), /duplicate case/);
  assert.throws(() => buildSelectedScript(source, ['missing']), /unknown case/);
});

test('exit mapping and direct script execution preserve child outcomes', () => {
  assert.equal(exitCodeFor({ status: 7, signal: null }), 7);
  assert.equal(exitCodeFor({ status: null, signal: 'SIGINT' }), 130);
  assert.equal(exitCodeFor({ status: null, signal: 'SIGTERM' }), 143);
  assert.equal(exitCodeFor({ status: null, signal: 'SIGUSR1' }), 1);

  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-cases-outcome-'));
  try {
    const script = path.join(directory, 'exit-seven.sh');
    fs.writeFileSync(script, '#!/bin/bash\nexit 7\n', { mode: 0o700 });
    assert.equal(runScript(script), 7);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('injectable main covers list, all, selected cleanup, and usage', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-cases-main-'));
  try {
    const syntheticSource = [
      '#!/bin/bash',
      'PASS=0',
      'PID_WIRING_OK=1',
      'check "P0 preflight"',
      'setup_case one',
      'check "P1 one"',
      'echo "----"',
      'echo "done"',
      '',
    ].join('\n');
    const syntheticPath = path.join(directory, 'source.sh');
    fs.writeFileSync(syntheticPath, syntheticSource, { mode: 0o700 });

    const listed = [];
    assert.equal(main({
      argv: ['--list-cases'],
      sourcePath: syntheticPath,
      stdout: { write(value) { listed.push(String(value)); } },
    }), 0);
    assert.equal(listed.join(''), 'P0\nP1\n');

    const allCalls = [];
    assert.equal(main({
      argv: ['--all'],
      sourcePath: syntheticPath,
      runScriptFn(script) {
        allCalls.push(script);
        return 9;
      },
    }), 9);
    assert.deepEqual(allCalls, [syntheticPath]);

    let selectedPath;
    assert.equal(main({
      argv: ['--cases', 'P1'],
      sourcePath: syntheticPath,
      runScriptFn(script) {
        selectedPath = script;
        assert.match(fs.readFileSync(script, 'utf8'), /check "P1 one"/);
        assert.doesNotMatch(fs.readFileSync(script, 'utf8'), /check "P0 preflight"/);
        return 0;
      },
    }), 0);
    assert.equal(fs.existsSync(selectedPath), false);

    assert.throws(
      () => main({ argv: [], sourcePath: syntheticPath }),
      /usage:/,
    );
    assert.throws(
      () => main({ argv: ['--list-cases', 'extra'], sourcePath: syntheticPath }),
      /usage:/,
    );
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
