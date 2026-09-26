'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const LIB = path.join(__dirname, '..', '..', 'hooks', 'lib', 'review-ledger-v1.js');
const ledger = require(LIB);
const scope = require(path.join(__dirname, '..', '..', 'hooks', 'lib', 'review-round-scope-v1.js'));

const TEMP_DIRS = [];

test.after(() => {
  for (const dir of TEMP_DIRS) fs.rmSync(dir, { recursive: true, force: true });
});

function tempDir() {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'review-ledger-')));
  TEMP_DIRS.push(dir);
  return dir;
}

function line(id, disposition, severity, anchor, summary) {
  return 'FINDING LEDGER — ' + id + ' ' + disposition + ' ' + severity + ' ' + anchor + ' | ' + summary;
}

const ROUND_ONE = [
  'TDD STARTED — demo | steps: 2',
  line('R1-F1', 'routed', 'IMPORTANT', 'src/a.ts:12', 'missing null guard'),
  line('R1-F2', 'deferred', 'SUGGESTION', 'src/b.ts:4', 'rename helper'),
  line('R1-F3', 'neutralized', 'SUGGESTION', 'src/c.ts:9', 'judge ruled a false positive'),
  'R1-F1 IMPL completed — files: src/a.ts | guard added',
  line('R1-F1', 'fixed', 'IMPORTANT', 'src/a.ts:12', 'guard added'),
];

test('a well-formed line parses into id, disposition, severity, anchor and summary', () => {
  const parsed = ledger.parseLedgerLine(line('R2-F7', 'routed', 'CRITICAL', 'src/x.ts:30', 'wrong branch taken'));
  assert.deepEqual(parsed, {
    malformed: false,
    id: 'R2-F7',
    round: 2,
    index: 7,
    disposition: 'routed',
    severity: 'CRITICAL',
    anchor: 'src/x.ts:30',
    summary: 'wrong branch taken',
  });
});

test('a timestamp prefix, a hyphen dash and a trailing carriage return are tolerated', () => {
  const parsed = ledger.parseLedgerLine('[+00:12:03] FINDING LEDGER - R1-F1 deferred IMPORTANT src/a.ts:3 | late find\r');
  assert.equal(parsed.malformed, false);
  assert.equal(parsed.id, 'R1-F1');
  assert.equal(parsed.summary, 'late find');
});

test('lines that are not ledger lines are ignored, including a mid-line mention', () => {
  assert.equal(ledger.parseLedgerLine('R1-F1 IMPL completed — files: src/a.ts'), null);
  assert.equal(ledger.parseLedgerLine('note: FINDING LEDGER lines follow'), null);
  assert.equal(ledger.parseLedgerLine(''), null);
});

test('the latest line per id wins and a routed entry without a fix stays open', () => {
  const r = ledger.ledgerState({ text: ROUND_ONE.join('\n') });
  assert.equal(r.status, 'ok');
  assert.deepEqual(r.entries.map((e) => e.id + ':' + e.state), [
    'R1-F1:fixed',
    'R1-F2:deferred',
    'R1-F3:neutralized',
  ]);
  const unfixed = ledger.ledgerState({ text: line('R1-F1', 'routed', 'IMPORTANT', 'src/a.ts:12', 'guard') });
  assert.equal(unfixed.entries[0].state, 'routed-unfixed');
  assert.equal(unfixed.open, 1);
});

test('open counts deferred and routed-unfixed entries only', () => {
  const text = ROUND_ONE.concat([
    line('R2-F1', 'routed', 'CRITICAL', 'src/d.ts:1', 'regression in fix'),
    line('R2-F2', 'deferred', 'IMPORTANT', 'src/e.ts:2', 'pre-existing robustness gap'),
  ]).join('\n');
  const r = ledger.ledgerState({ text });
  assert.equal(r.status, 'ok');
  assert.equal(r.open, 3);
});

test('entries sort by origin round, then by index', () => {
  const text = [
    line('R1-F10', 'deferred', 'SUGGESTION', 'src/a.ts:1', 'ten'),
    line('R1-F2', 'deferred', 'SUGGESTION', 'src/a.ts:2', 'two'),
    line('R2-F1', 'deferred', 'SUGGESTION', 'src/a.ts:3', 'next round'),
  ].join('\n');
  assert.deepEqual(ledger.ledgerState({ text }).entries.map((e) => e.id), ['R1-F2', 'R1-F10', 'R2-F1']);
});

test('REVIEW BUDGET RESET starts a new generation and drops the earlier entries', () => {
  const text = ROUND_ONE.concat([
    'REVIEW BUDGET RESET — budget granted again',
    line('R1-F1', 'routed', 'IMPORTANT', 'src/z.ts:5', 'new generation finding'),
  ]).join('\n');
  const r = ledger.ledgerState({ text });
  assert.equal(r.status, 'ok');
  assert.equal(r.generation, 2);
  assert.deepEqual(r.entries.map((e) => e.id + ':' + e.anchor), ['R1-F1:src/z.ts:5']);
});

test('an earlier-round registration without a reset marker is degraded, never merged', () => {
  const text = [
    line('R2-F1', 'routed', 'IMPORTANT', 'src/a.ts:1', 'round two'),
    line('R1-F1', 'routed', 'IMPORTANT', 'src/b.ts:1', 'looks like an unmarked reset'),
  ].join('\n');
  const r = ledger.ledgerState({ text });
  assert.equal(r.status, 'degraded');
  assert.equal(r.reason, 'round-regression');
});

test('a fixed line for an earlier round is not a regression', () => {
  const text = ROUND_ONE.concat([
    line('R2-F1', 'deferred', 'IMPORTANT', 'src/d.ts:1', 'late important'),
    line('R1-F2', 'fixed', 'SUGGESTION', 'src/b.ts:4', 'fixed in the self-review round'),
  ]).join('\n');
  const r = ledger.ledgerState({ text });
  assert.equal(r.status, 'ok');
  assert.equal(r.entries.find((e) => e.id === 'R1-F2').state, 'fixed');
});

test('a fixed line for an unknown id creates a closed entry', () => {
  const r = ledger.ledgerState({ text: line('R1-F4', 'fixed', 'SUGGESTION', 'src/a.ts:1', 'fixed') });
  assert.equal(r.status, 'ok');
  assert.equal(r.open, 0);
});

test('a malformed ledger line degrades the whole ledger', () => {
  const bad = [
    'FINDING LEDGER — R1-F1 skipped IMPORTANT src/a.ts:1 | unknown disposition',
    'FINDING LEDGER — R1-F1 routed MAJOR src/a.ts:1 | unknown severity',
    'FINDING LEDGER — R1-X1 routed IMPORTANT src/a.ts:1 | bad id',
    'FINDING LEDGER — R1-F1 routed IMPORTANT src/a.ts:1 no separator',
    'FINDING LEDGER — R0-F1 routed IMPORTANT src/a.ts:1 | round zero',
    'FINDING LEDGER — R1-F1 routed IMPORTANT src/a.ts:0 | line zero',
  ];
  for (const b of bad) {
    const r = ledger.ledgerState({ text: ROUND_ONE.concat([b]).join('\n') });
    assert.equal(r.status, 'degraded', b);
    assert.equal(r.reason, 'malformed-line', b);
  }
});

test('unsafe anchors degrade while the project placeholder and a bare dash are accepted', () => {
  for (const anchor of ['/etc/passwd:1', '../up.ts:2', '.zensu/state/x.json:3', '~/x.ts:4', 'C:/w/a.ts:5', '<home>/x.ts:6']) {
    const r = ledger.ledgerState({ text: line('R1-F1', 'routed', 'IMPORTANT', anchor, 'x') });
    assert.equal(r.status, 'degraded', anchor);
  }
  assert.equal(ledger.parseAnchor('<project>/src/a.ts:3'), 'src/a.ts:3');
  assert.equal(ledger.parseAnchor('-'), '-');
  assert.equal(ledger.parseAnchor('src\\a.ts:7'), 'src/a.ts:7');
});

test('a line range anchor is kept as its first line, as the verification gate reads it', () => {
  assert.equal(ledger.parseAnchor('src/a.ts:10-20'), 'src/a.ts:10');
  const r = ledger.ledgerState({ text: line('R1-F1', 'deferred', 'IMPORTANT', 'src/a.ts:10-20', 'range') });
  assert.equal(r.status, 'ok');
  assert.equal(r.entries[0].anchor, 'src/a.ts:10');
  assert.equal(ledger.parseAnchor('src/a.ts:10-'), null);
});

test('a shell-active anchor degrades while a plain dollar sign stays valid', () => {
  for (const anchor of ['src/`x`.ts:1', 'src/$(x).ts:2', 'src/${x}.ts:3']) {
    const r = ledger.ledgerState({ text: line('R1-F1', 'routed', 'IMPORTANT', anchor, 'x') });
    assert.equal(r.status, 'degraded', anchor);
    assert.equal(r.reason, 'malformed-line', anchor);
  }
  assert.equal(ledger.parseAnchor('routes/posts.$slug.tsx:4'), 'routes/posts.$slug.tsx:4');
});

test('a summary never hands shell-active text back to a caller', () => {
  const parsed = ledger.parseLedgerLine(line('R1-F1', 'deferred', 'SUGGESTION', 'src/a.ts:1', 'call `run` via $(cmd) or ${v} for $5'));
  assert.equal(parsed.summary, "call 'run' via $ (cmd) or $ {v} for $5");
});

test('a control byte inside the summary is malformed', () => {
  const r = ledger.ledgerState({ text: line('R1-F1', 'deferred', 'SUGGESTION', 'src/a.ts:1', 'tab\there') });
  assert.equal(r.status, 'degraded');
  assert.equal(r.reason, 'malformed-line');
});

test('a registration that reuses an id degrades, a repeated identical one does not', () => {
  const afterFix = ROUND_ONE.concat([line('R1-F1', 'routed', 'IMPORTANT', 'src/a.ts:12', 'unmarked reset reuses R1-F1')]);
  assert.equal(ledger.ledgerState({ text: afterFix.join('\n') }).reason, 'id-reused');
  const switched = [
    line('R1-F1', 'deferred', 'IMPORTANT', 'src/a.ts:1', 'deferred first'),
    line('R1-F1', 'routed', 'IMPORTANT', 'src/a.ts:1', 'routed later'),
  ];
  assert.equal(ledger.ledgerState({ text: switched.join('\n') }).reason, 'id-reused');
  const repeated = [
    line('R2-F1', 'deferred', 'IMPORTANT', 'src/a.ts:1', 'deferred at classification'),
    line('R2-F1', 'deferred', 'IMPORTANT', 'src/a.ts:1', 'deferred again by the fix directive'),
  ];
  const r = ledger.ledgerState({ text: repeated.join('\n') });
  assert.equal(r.status, 'ok');
  assert.equal(r.entries[0].summary, 'deferred again by the fix directive');
});

test('a problem before a reset marker does not degrade the new generation', () => {
  const text = [
    'FINDING LEDGER — R1-F1 routed MAJOR src/a.ts:1 | unknown severity',
    line('R2-F1', 'routed', 'IMPORTANT', 'src/a.ts:1', 'round two'),
    line('R1-F2', 'routed', 'IMPORTANT', 'src/a.ts:2', 'regression'),
    'REVIEW BUDGET RESET',
    line('R1-F1', 'deferred', 'IMPORTANT', 'src/b.ts:3', 'new generation'),
  ].join('\n');
  const r = ledger.ledgerState({ text });
  assert.equal(r.status, 'ok');
  assert.equal(r.generation, 2);
  assert.deepEqual(r.entries.map((e) => e.id), ['R1-F1']);
});

test('report mode lists every parseable entry and names the first problem', () => {
  const text = ROUND_ONE.concat([
    'FINDING LEDGER — R1-F9 routed IMPORTANT src/a.ts:0 | line zero',
    line('R2-F1', 'deferred', 'IMPORTANT', 'src/d.ts:2', 'still listed'),
  ]).join('\n');
  assert.equal(ledger.ledgerState({ text }).status, 'degraded');
  const r = ledger.ledgerState({ text, report: true });
  assert.equal(r.status, 'partial');
  assert.equal(r.reason, 'malformed-line');
  assert.deepEqual(r.entries.map((e) => e.id + ':' + e.state), ['R1-F1:fixed', 'R1-F2:deferred', 'R1-F3:neutralized', 'R2-F1:deferred']);
  assert.equal(r.open, 2);
  const out = ledger.render(r).split('\n');
  assert.equal(out.length, 5);
  assert.equal(out[4], 'summary status=partial generation=1 entries=4 open=2 reason=malformed-line');
});

test('report mode keeps the first entries past the cap and a read failure stays degraded', () => {
  const many = [];
  for (let i = 1; i <= ledger.MAX_ENTRIES + 3; i++) {
    many.push(line('R1-F' + i, 'deferred', 'SUGGESTION', 'src/a.ts:1', 'n' + i));
  }
  const r = ledger.ledgerState({ text: many.join('\n'), report: true });
  assert.equal(r.status, 'partial');
  assert.equal(r.reason, 'truncated');
  assert.equal(r.entries.length, ledger.MAX_ENTRIES);
  assert.equal(ledger.ledgerState({ report: true }).status, 'degraded');
});

test('a log larger than the shared read cap is degraded', () => {
  const root = tempDir();
  const log = path.join(root, 'run.log');
  fs.writeFileSync(log, Buffer.alloc(scope.FILE_MAX_BYTES + 1, 0x61));
  const r = ledger.ledgerState({ log, root });
  assert.equal(r.status, 'degraded');
  assert.equal(r.reason, 'log-too-large');
});

test('a long summary is shortened, not rejected', () => {
  const r = ledger.ledgerState({ text: line('R1-F1', 'deferred', 'SUGGESTION', 'src/a.ts:1', 'x'.repeat(500)) });
  assert.equal(r.status, 'ok');
  assert.equal(r.entries[0].summary.length, ledger.MAX_TEXT);
});

test('a log without ledger lines answers empty', () => {
  const r = ledger.ledgerState({ text: 'TDD STARTED — demo\nR1-S1 IMPL completed — files: a.ts' });
  assert.equal(r.status, 'empty');
  assert.equal(r.reason, 'no-entries');
});

test('more entries than the cap degrade instead of dropping findings', () => {
  const many = [];
  for (let i = 1; i <= ledger.MAX_ENTRIES + 1; i++) {
    many.push(line('R1-F' + i, 'deferred', 'SUGGESTION', 'src/a.ts:1', 'n' + i));
  }
  const r = ledger.ledgerState({ text: many.join('\n') });
  assert.equal(r.status, 'degraded');
  assert.equal(r.reason, 'truncated');
});

test('an unreadable, outside-root or unanchored log is degraded', () => {
  const root = tempDir();
  const outside = tempDir();
  const outsideLog = path.join(outside, 'run.log');
  fs.writeFileSync(outsideLog, ROUND_ONE.join('\n'));
  assert.equal(ledger.ledgerState({ log: path.join(root, 'absent.log') }).reason, 'log-unreadable');
  assert.equal(ledger.ledgerState({ log: outsideLog, root }).reason, 'log-outside-root');
  assert.equal(ledger.ledgerState({ log: outsideLog, root: path.join(root, 'absent') }).reason, 'bad-root');
  assert.equal(ledger.ledgerState({}).reason, 'no-log');
});

test('a log inside the root is read', () => {
  const root = tempDir();
  const log = path.join(root, 'run.log');
  fs.writeFileSync(log, ROUND_ONE.join('\r\n'));
  const r = ledger.ledgerState({ log, root });
  assert.equal(r.status, 'ok');
  assert.equal(r.entries.length, 3);
});

test('render prints entries only for an ok or partial ledger and always ends in a summary', () => {
  const ok = ledger.render(ledger.ledgerState({ text: ROUND_ONE.join('\n') })).split('\n');
  assert.equal(ok[0], 'entry R1-F1 fixed IMPORTANT src/a.ts:12 | guard added');
  assert.equal(ok[ok.length - 1], 'summary status=ok generation=1 entries=3 open=1');
  const bad = ledger.render(ledger.ledgerState({ text: 'FINDING LEDGER — broken' })).split('\n');
  assert.deepEqual(bad, ['summary status=degraded generation=1 entries=0 open=0 reason=malformed-line']);
});

test('the CLI reads --log and --root and never reports ok without a log', () => {
  const root = tempDir();
  const log = path.join(root, 'run.log');
  fs.writeFileSync(log, ROUND_ONE.join('\n'));
  assert.match(ledger.cliMain(['--log', log, '--root', root]), /summary status=ok generation=1 entries=3 open=1$/);
  assert.match(ledger.cliMain([]), /^summary status=degraded .*reason=no-log$/);
});

test('the CLI --report flag selects the lenient read', () => {
  const root = tempDir();
  const log = path.join(root, 'run.log');
  fs.writeFileSync(log, ROUND_ONE.concat(['FINDING LEDGER — broken']).join('\n'));
  assert.match(ledger.cliMain(['--log', log, '--root', root]), /^summary status=degraded .*reason=malformed-line$/);
  assert.match(ledger.cliMain(['--report', '--log', log, '--root', root]), /summary status=partial generation=1 entries=3 open=1 reason=malformed-line$/);
});
