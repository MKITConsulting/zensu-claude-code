'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const lib = require('../../hooks/lib/zensu-evidence-crosscheck.js');

const LOG_PATH = '/p/.zensu/logs/2026-01-01-0000_tdd-x.log';

function witnessLine(cmd, tail, interrupted, prefix) {
  return (
    (prefix || '') +
    'BASH cmd=' + JSON.stringify(cmd) +
    ' exit=?' +
    ' tail=' + JSON.stringify(tail) +
    ' interrupted=' + (interrupted ? 'true' : 'false')
  );
}

function loggingCommandFor(claimLine) {
  return (
    "printf '%s%s\\n' \"$(bash zensu-log.sh timestamp 1)\" " +
    JSON.stringify(claimLine).replace(/"/g, '\\"') +
    ' >> ' + LOG_PATH
  );
}

// The `append` verb replaced the hand-rolled redirect above as the documented
// log writer. It carries no `>>` at all, so `redirectTargets` finds nothing and
// LOG_DIR_FRAGMENT is never consulted for this shape: the exclusion rests
// ENTIRELY on LOG_WRITE_MARKER matching the claim marker inside `--message`.
// That is worth stating rather than assuming, because it means an `append`
// whose message carries no CHECKPOINT/AUDIT marker is NOT excluded — the case
// below pins that, so the boundary is visible instead of inferred.
function appendCommandFor(claimLine) {
  return (
    'bash zensu-log.sh append --log ' + LOG_PATH + ' --message ' +
    JSON.stringify(claimLine).replace(/"/g, '\\"') + ' --start 1'
  );
}

function withTemp(fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-xcheck-'));
  try {
    return fn(dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test('parseClaims extracts cmd and result from CHECKPOINT and AUDIT lines', () => {
  const log = [
    'TDD STARTED — x | steps: 1',
    'S1 CHECKPOINT — cmd="npm test" exit=0 result="PASS"',
    'AUDIT — cmd="bash tests/run-all.sh --ci" exit=0 result="PASS 122/0"',
    'S1 IMPL completed — files: a.js',
  ].join('\n');
  const claims = lib.parseClaims(log);
  assert.strictEqual(claims.length, 2);
  assert.strictEqual(claims[0].cmd, 'npm test');
  assert.strictEqual(claims[0].result, 'PASS');
  assert.strictEqual(claims[1].cmd, 'bash tests/run-all.sh --ci');
  assert.strictEqual(claims[1].result, 'PASS 122/0');
});

test('parseClaims keeps a command containing double quotes intact', () => {
  const log = 'AUDIT — cmd="grep -F \\"a b\\" file" exit=0 result="PASS"';
  const claims = lib.parseClaims(log);
  assert.strictEqual(claims.length, 1);
  assert.strictEqual(claims[0].cmd, 'grep -F \\"a b\\" file');
});

test('parseClaims reports a via= escape entry instead of a cmd claim', () => {
  const log = 'AUDIT — via=McpTestRunner claim="suite green"';
  const claims = lib.parseClaims(log);
  assert.strictEqual(claims.length, 1);
  assert.strictEqual(claims[0].kind, 'via');
  assert.strictEqual(claims[0].tool, 'McpTestRunner');
  assert.strictEqual(claims[0].claim, 'suite green');
});

test('a cmd claim whose command contains via= is not read as a via escape', () => {
  const log = 'AUDIT — cmd="curl --via=proxy https://x" exit=0 result="PASS"';
  const claims = lib.parseClaims(log);
  assert.strictEqual(claims.length, 1);
  assert.strictEqual(claims[0].kind, 'cmd');
  assert.strictEqual(claims[0].cmd, 'curl --via=proxy https://x');
});

test('a command that failed and then re-ran green is verified, not contradicted', () => {
  const claims = lib.parseClaims('AUDIT — cmd="npm test" exit=0 result="PASS"');
  const entries = lib.parseWitness(
    [
      witnessLine('npm test', 'tests 3\nfail 2', false, ''),
      witnessLine('npm test', 'tests 3\nfail 0', false, ''),
    ].join('\n'),
    LOG_PATH
  );
  assert.strictEqual(entries.length, 2);
  assert.strictEqual(lib.crossCheck(claims, entries, true)[0].verdict, 'verified');
});

test('a claimed pass is contradicted only when every matching run failed', () => {
  const claims = lib.parseClaims('AUDIT — cmd="npm test" exit=0 result="PASS"');
  const entries = lib.parseWitness(
    [
      witnessLine('npm test', 'fail 2', false, ''),
      witnessLine('npm test', 'fail 1', false, ''),
    ].join('\n'),
    LOG_PATH
  );
  assert.strictEqual(lib.crossCheck(claims, entries, true)[0].verdict, 'contradiction');
});

test('parseWitness JSON-decodes cmd and tail and tolerates a timestamp prefix', () => {
  const text = [
    witnessLine('npm test', 'pass 3\nfail 0', false, ''),
    witnessLine('npm run build', 'done', false, '[10:11:12] '),
  ].join('\n');
  const entries = lib.parseWitness(text, LOG_PATH);
  assert.strictEqual(entries.length, 2);
  assert.strictEqual(entries[0].cmd, 'npm test');
  assert.strictEqual(entries[0].tail, 'pass 3\nfail 0');
  assert.strictEqual(entries[1].cmd, 'npm run build');
});

test('parseWitness skips malformed lines without throwing', () => {
  const text = [
    'garbage',
    'BASH cmd=not-json exit=? tail="x" interrupted=false',
    'BASH cmd="unterminated exit=? tail="x" interrupted=false',
    witnessLine('npm test', 'ok', false, ''),
    '',
  ].join('\n');
  const entries = lib.parseWitness(text, LOG_PATH);
  assert.strictEqual(entries.length, 1);
  assert.strictEqual(entries[0].cmd, 'npm test');
});

test('the AUDIT-logging command must not corroborate its own claim', () => {
  const claimLine = 'AUDIT — cmd="bash tests/run-all.sh --ci" exit=0 result="PASS"';
  const witness = witnessLine(loggingCommandFor(claimLine), '', false, '');
  const claims = lib.parseClaims(claimLine);
  const entries = lib.parseWitness(witness, LOG_PATH);
  assert.strictEqual(entries.length, 1);
  assert.strictEqual(entries[0].logWriting, true);
  const results = lib.crossCheck(claims, entries, true);
  assert.strictEqual(results[0].verdict, 'gap');
});

test('the append-verb logging command must not corroborate its own claim', () => {
  const claimLine = 'AUDIT — cmd="bash tests/run-all.sh --ci" exit=0 result="PASS"';
  const witness = witnessLine(appendCommandFor(claimLine), '', false, '');
  const claims = lib.parseClaims(claimLine);
  const entries = lib.parseWitness(witness, LOG_PATH);
  assert.strictEqual(entries.length, 1);
  assert.strictEqual(entries[0].logWriting, true);
  const results = lib.crossCheck(claims, entries, true);
  assert.strictEqual(results[0].verdict, 'gap');
});

test('an append whose message carries no claim marker is NOT log-writing', () => {
  // The complement of the case above, and the reason its comment can be trusted:
  // strip the marker and the same command shape stops being excluded, which
  // shows the verdict comes from LOG_WRITE_MARKER and not from the `--log`
  // operand. If this ever flips, `redirectTargets` learned the operand and the
  // comment above must be rewritten.
  assert.strictEqual(
    lib.isLogWritingCommand('bash zensu-log.sh append --log ' + LOG_PATH + ' --message "TDD STARTED"',
      LOG_PATH),
    false
  );
});

test('a redirect into .zensu/logs marks the command log-writing even without a claim marker', () => {
  assert.strictEqual(
    lib.isLogWritingCommand('printf hello >> /repo/.zensu/logs/run.log', LOG_PATH),
    true
  );
  assert.strictEqual(
    lib.isLogWritingCommand('printf hello >> "$WT/.zensu/logs/run.log"', LOG_PATH),
    true
  );
  assert.strictEqual(
    lib.isLogWritingCommand('printf hello | tee -a /repo/.zensu/logs/run.log', LOG_PATH),
    true
  );
  assert.strictEqual(lib.isLogWritingCommand('npm test', LOG_PATH), false);
});

test('a redirect into the run log by basename marks the command log-writing', () => {
  assert.strictEqual(
    lib.isLogWritingCommand('printf x >> /elsewhere/2026-01-01-0000_tdd-x.log', LOG_PATH),
    true
  );
});

test('matching is exact equality, not substring containment', () => {
  const claims = lib.parseClaims('AUDIT — cmd="npm test" exit=0 result="PASS"');
  const superstring = lib.parseWitness(witnessLine('npm test --watch', 'ok', false, ''), LOG_PATH);
  assert.strictEqual(lib.crossCheck(claims, superstring, true)[0].verdict, 'gap');
  const exact = lib.parseWitness(witnessLine('npm test', 'ok', false, ''), LOG_PATH);
  assert.strictEqual(lib.crossCheck(claims, exact, true)[0].verdict, 'verified');
});

test('corroboration scans the tail only — a cmd containing "error" does not contradict', () => {
  const claims = lib.parseClaims('AUDIT — cmd="npm run test:error-paths" exit=0 result="PASS"');
  const entries = lib.parseWitness(
    witnessLine('npm run test:error-paths', 'pass 12', false, ''),
    LOG_PATH
  );
  assert.strictEqual(lib.crossCheck(claims, entries, true)[0].verdict, 'verified');
});

test('a failure marker in the tail contradicts a claimed pass', () => {
  const claims = lib.parseClaims('AUDIT — cmd="npm test" exit=0 result="PASS"');
  const entries = lib.parseWitness(witnessLine('npm test', 'tests 3\nfail 2', false, ''), LOG_PATH);
  const results = lib.crossCheck(claims, entries, true);
  assert.strictEqual(results[0].verdict, 'contradiction');
});

test('a zero failure count is not a failure marker', () => {
  assert.strictEqual(lib.failureMarker({ tail: 'test-x: 24 PASS / 0 FAIL', interrupted: false }), null);
  assert.strictEqual(lib.failureMarker({ tail: 'tests 3\npass 3\nfail 0', interrupted: false }), null);
  assert.strictEqual(lib.failureMarker({ tail: 'failures: 0', interrupted: false }), null);
});

test('interrupted=true contradicts a claimed pass', () => {
  const claims = lib.parseClaims('AUDIT — cmd="npm test" exit=0 result="PASS"');
  const entries = lib.parseWitness(witnessLine('npm test', '', true, ''), LOG_PATH);
  assert.strictEqual(lib.crossCheck(claims, entries, true)[0].verdict, 'contradiction');
});

test('a non-green result is never contradicted', () => {
  const claims = lib.parseClaims('AUDIT — cmd="npm test" exit=1 result="FAIL 2"');
  const entries = lib.parseWitness(witnessLine('npm test', 'fail 2', false, ''), LOG_PATH);
  assert.strictEqual(lib.crossCheck(claims, entries, true)[0].verdict, 'verified');
});

test('isGreen accepts green verdicts and rejects failure verdicts', () => {
  assert.strictEqual(lib.isGreen('PASS'), true);
  assert.strictEqual(lib.isGreen('PASS 122/0'), true);
  assert.strictEqual(lib.isGreen('all green'), true);
  assert.strictEqual(lib.isGreen('FAIL 2'), false);
  assert.strictEqual(lib.isGreen('passed with 1 error'), false);
  assert.strictEqual(lib.isGreen(''), false);
});

test('an unavailable witness makes every claim a gap', () => {
  const claims = lib.parseClaims(
    ['AUDIT — cmd="a" exit=0 result="PASS"', 'AUDIT — cmd="b" exit=0 result="PASS"'].join('\n')
  );
  const results = lib.crossCheck(claims, [], false);
  assert.deepStrictEqual(results.map((r) => r.verdict), ['gap', 'gap']);
});

test('render emits the documented wording and preserves claim order', () => {
  const claims = lib.parseClaims(
    [
      'AUDIT — cmd="a" exit=0 result="PASS"',
      'AUDIT — via=Runner claim="green"',
      'AUDIT — cmd="b" exit=0 result="PASS"',
    ].join('\n')
  );
  const entries = lib.parseWitness(witnessLine('a', 'ok', false, ''), LOG_PATH);
  const out = lib.render(lib.crossCheck(claims, entries, true));
  assert.deepStrictEqual(out, [
    'verified cmd="a"',
    'via=Runner claim="green" (known limitation — no witness cross-check possible)',
    'EVIDENCE GAP — cmd="b" claimed but not in witness log',
  ]);
});

test('run exits 0 when every claim is verified', () => {
  withTemp((dir) => {
    const log = path.join(dir, 'run.log');
    const witness = path.join(dir, 'witness.log');
    fs.writeFileSync(log, 'AUDIT — cmd="npm test" exit=0 result="PASS"\n');
    fs.writeFileSync(witness, witnessLine('npm test', 'pass 3', false, '') + '\n');
    const r = lib.run(['--log', log, '--witness', witness]);
    assert.strictEqual(r.code, 0);
    assert.ok(r.out.some((l) => l === 'verified cmd="npm test"'));
    assert.ok(r.out.some((l) => l.includes('verified=1 gaps=0 contradictions=0')));
  });
});

test('run exits 1 on a gap and 1 on a contradiction', () => {
  withTemp((dir) => {
    const log = path.join(dir, 'run.log');
    const witness = path.join(dir, 'witness.log');
    fs.writeFileSync(log, 'AUDIT — cmd="npm test" exit=0 result="PASS"\n');
    fs.writeFileSync(witness, witnessLine('other', 'ok', false, '') + '\n');
    assert.strictEqual(lib.run(['--log', log, '--witness', witness]).code, 1);
    fs.writeFileSync(witness, witnessLine('npm test', 'FAIL 2 tests', false, '') + '\n');
    assert.strictEqual(lib.run(['--log', log, '--witness', witness]).code, 1);
  });
});

test('run fails closed when the witness log is missing but claims exist', () => {
  withTemp((dir) => {
    const log = path.join(dir, 'run.log');
    fs.writeFileSync(log, 'AUDIT — cmd="npm test" exit=0 result="PASS"\n');
    const r = lib.run(['--log', log, '--witness', path.join(dir, 'absent.log')]);
    assert.strictEqual(r.code, 1);
    assert.ok(r.out.some((l) => l.includes('witness log unreadable')));
  });
});

test('run exits 2 on a missing run log and 0 with --allow-missing-log', () => {
  withTemp((dir) => {
    const absent = path.join(dir, 'absent.log');
    const witness = path.join(dir, 'witness.log');
    fs.writeFileSync(witness, '');
    assert.strictEqual(lib.run(['--log', absent, '--witness', witness]).code, 2);
    const r = lib.run(['--log', absent, '--witness', witness, '--allow-missing-log']);
    assert.strictEqual(r.code, 0);
    assert.ok(r.out.some((l) => l.includes('no evidence claims to cross-check')));
  });
});

test('run exits 0 with a clear message when the log carries no claims', () => {
  withTemp((dir) => {
    const log = path.join(dir, 'run.log');
    const witness = path.join(dir, 'witness.log');
    fs.writeFileSync(log, 'TDD STARTED — x | steps: 1\nS1 IMPL completed — files: a.js\n');
    fs.writeFileSync(witness, '');
    const r = lib.run(['--log', log, '--witness', witness]);
    assert.strictEqual(r.code, 0);
    assert.deepStrictEqual(r.out, ['EVIDENCE CROSS-CHECK — no evidence claims to cross-check']);
  });
});

test('run exits 2 without both required arguments', () => {
  assert.strictEqual(lib.run([]).code, 2);
  assert.strictEqual(lib.run(['--log', '/x']).code, 2);
});

test('END-TO-END: a run whose only witness entry is the logging printf reports a gap', () => {
  withTemp((dir) => {
    const log = path.join(dir, 'run.log');
    const witness = path.join(dir, 'witness.log');
    const claimLine = 'AUDIT — cmd="bash tests/run-all.sh --ci" exit=0 result="PASS"';
    fs.writeFileSync(log, claimLine + '\n');
    fs.writeFileSync(
      witness,
      witnessLine(
        "printf '%s\\n' " + JSON.stringify(claimLine).replace(/"/g, '\\"') + ' >> ' + log,
        '',
        false,
        ''
      ) + '\n'
    );
    const r = lib.run(['--log', log, '--witness', witness]);
    assert.strictEqual(r.code, 1);
    assert.ok(r.out.some((l) => l.startsWith('EVIDENCE GAP')));
    assert.ok(!r.out.some((l) => l.startsWith('verified')));
  });
});
