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
  'BUILD STARTED — demo | steps: 2',
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
    line('R2-F1', 'deferred', 'SUGGESTION', 'src/a.ts:1', 'deferred at classification'),
    line('R2-F1', 'deferred', 'SUGGESTION', 'src/a.ts:1', 'deferred again by the fix directive'),
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
  const r = ledger.ledgerState({ text: 'BUILD STARTED — demo\nR1-S1 IMPL completed — files: a.ts' });
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

test('a same-state registration with another anchor reuses the id and degrades', () => {
  const text = [
    line('R2-F1', 'deferred', 'IMPORTANT', 'src/a.ts:1', 'panel finding'),
    line('R2-F1', 'deferred', 'IMPORTANT', 'src/b.ts:9', 'judge finding given the same id'),
  ].join('\n');
  const r = ledger.ledgerState({ text });
  assert.equal(r.status, 'degraded');
  assert.equal(r.reason, 'id-reused');
});

test('a same-state, same-anchor repeat of an earlier round is idempotent, not a regression', () => {
  const text = [
    line('R1-F4', 'deferred', 'IMPORTANT', 'src/a.ts:5', 'first registration'),
    line('R2-F1', 'deferred', 'SUGGESTION', 'src/b.ts:2', 'round two finding'),
    line('R1-F4', 'deferred', 'IMPORTANT', 'src/a.ts:5', 'repeated registration'),
  ].join('\n');
  const r = ledger.ledgerState({ text });
  assert.equal(r.status, 'ok');
  assert.equal(r.entries.length, 2);
  assert.equal(r.entries.find((e) => e.id === 'R1-F4').summary, 'repeated registration');
});

test('a parked line on an earlier-round id is an open transition that carries the new severity', () => {
  const text = [
    line('R1-F2', 'deferred', 'SUGGESTION', 'src/b.ts:4', 'rated low in round one'),
    line('R2-F1', 'deferred', 'SUGGESTION', 'src/c.ts:1', 'round two finding'),
    line('R1-F2', 'parked', 'IMPORTANT', 'src/b.ts:6', 're-raised as important and deferred'),
  ].join('\n');
  const r = ledger.ledgerState({ text });
  assert.equal(r.status, 'ok');
  const parked = r.entries.find((e) => e.id === 'R1-F2');
  assert.equal(parked.state, 'parked');
  assert.equal(parked.severity, 'IMPORTANT');
  assert.equal(parked.anchor, 'src/b.ts:6');
  assert.equal(r.open, 2);
});

test('a parked line for an unknown id creates an open entry', () => {
  const r = ledger.ledgerState({ text: line('R2-F3', 'parked', 'IMPORTANT', 'src/a.ts:8', 'parked at classification') });
  assert.equal(r.status, 'ok');
  assert.equal(r.entries[0].state, 'parked');
  assert.equal(r.open, 1);
});

test('the report read carries open entries across a reset under a generation-qualified id', () => {
  const text = [
    line('R3-F2', 'deferred', 'IMPORTANT', 'src/a.ts:9', 'robustness gap'),
    line('R3-F3', 'neutralized', 'SUGGESTION', 'src/a.ts:20', 'ruled a false positive'),
    line('R3-F4', 'routed', 'CRITICAL', 'src/d.ts:2', 'routed but never fixed'),
    'REVIEW BUDGET RESET — review rounds restart at 1',
    line('R1-F1', 'routed', 'IMPORTANT', 'src/z.ts:5', 'new generation finding'),
  ].join('\n');
  const report = ledger.ledgerState({ text, report: true });
  assert.equal(report.status, 'ok');
  assert.equal(report.generation, 2);
  assert.deepEqual(report.entries.map((e) => e.id + ':' + e.state), [
    'G1:R3-F2:deferred',
    'G1:R3-F4:routed-unfixed',
    'R1-F1:routed-unfixed',
  ]);
  assert.equal(report.open, 3);
  const routing = ledger.ledgerState({ text });
  assert.deepEqual(routing.entries.map((e) => e.id), ['R1-F1']);
});

test('a qualified fixed line closes the carried entry and the routing read ignores it', () => {
  const text = [
    line('R3-F2', 'deferred', 'IMPORTANT', 'src/a.ts:9', 'robustness gap'),
    'REVIEW BUDGET RESET',
    line('G1:R3-F2', 'fixed', 'IMPORTANT', 'src/a.ts:9', 'fixed in the self-review round'),
  ].join('\n');
  const report = ledger.ledgerState({ text, report: true });
  assert.equal(report.status, 'ok');
  assert.equal(report.entries[0].id, 'G1:R3-F2');
  assert.equal(report.entries[0].state, 'fixed');
  assert.equal(report.open, 0);
  const routing = ledger.ledgerState({ text });
  assert.equal(routing.status, 'empty');
});

test('a generation qualifier on a registration or a parked line is malformed', () => {
  for (const disposition of ['routed', 'deferred', 'neutralized', 'parked']) {
    const parsed = ledger.parseLedgerLine(line('G1:R3-F2', disposition, 'IMPORTANT', 'src/a.ts:9', 'qualified'));
    assert.equal(parsed.malformed, true, disposition);
  }
  const fixed = ledger.parseLedgerLine(line('G2:R3-F2', 'fixed', 'IMPORTANT', 'src/a.ts:9', 'qualified'));
  assert.equal(fixed.id, 'G2:R3-F2');
  assert.equal(fixed.carried, 2);
});

test('the report read treats an unmarked id reuse as a generation boundary instead of overwriting', () => {
  const text = [
    line('R1-F1', 'deferred', 'IMPORTANT', 'src/a.ts:1', 'earlier generation'),
    line('R1-F1', 'routed', 'IMPORTANT', 'src/b.ts:2', 'unmarked reset reuses the id'),
  ].join('\n');
  const report = ledger.ledgerState({ text, report: true });
  assert.equal(report.status, 'partial');
  assert.equal(report.reason, 'id-reused');
  assert.deepEqual(report.entries.map((e) => e.id + ':' + e.anchor), ['G1:R1-F1:src/a.ts:1', 'R1-F1:src/b.ts:2']);
  assert.equal(ledger.ledgerState({ text }).reason, 'id-reused');
});

test('the report read treats a round regression as a generation boundary', () => {
  const text = [
    line('R2-F1', 'deferred', 'IMPORTANT', 'src/a.ts:1', 'round two of the earlier generation'),
    line('R1-F1', 'routed', 'IMPORTANT', 'src/b.ts:2', 'unmarked reset starts at round one'),
  ].join('\n');
  const report = ledger.ledgerState({ text, report: true });
  assert.equal(report.status, 'partial');
  assert.equal(report.reason, 'round-regression');
  assert.deepEqual(report.entries.map((e) => e.id), ['G1:R2-F1', 'R1-F1']);
  assert.equal(report.open, 2);
});

test('a deferred repeat of a parked entry at the same anchor is idempotent and keeps it parked', () => {
  const text = [
    line('R2-F1', 'parked', 'IMPORTANT', 'src/a.ts:1', 'parked at classification'),
    line('R2-F1', 'deferred', 'IMPORTANT', 'src/a.ts:1', 'deferred again by the fix directive'),
  ].join('\n');
  const routing = ledger.ledgerState({ text });
  assert.equal(routing.status, 'ok');
  assert.equal(routing.entries.length, 1);
  assert.equal(routing.entries[0].state, 'parked');
  assert.equal(routing.entries[0].summary, 'parked at classification');
  const report = ledger.ledgerState({ text, report: true });
  assert.equal(report.status, 'ok');
  assert.deepEqual(report.entries.map((e) => e.id + ':' + e.state), ['R2-F1:parked']);
  const moved = [
    line('R2-F1', 'parked', 'IMPORTANT', 'src/a.ts:1', 'parked at classification'),
    line('R2-F1', 'deferred', 'IMPORTANT', 'src/b.ts:4', 'same id at another anchor'),
  ].join('\n');
  assert.equal(ledger.ledgerState({ text: moved }).reason, 'id-reused');
});

test('an idempotent lower-round repeat keeps the highest round, so a new id below it still regresses', () => {
  const text = [
    line('R1-F4', 'deferred', 'IMPORTANT', 'src/a.ts:5', 'first registration'),
    line('R2-F1', 'deferred', 'SUGGESTION', 'src/b.ts:2', 'round two finding'),
    line('R1-F4', 'deferred', 'IMPORTANT', 'src/a.ts:5', 'repeated registration'),
    line('R1-F9', 'deferred', 'SUGGESTION', 'src/c.ts:1', 'new id below the highest round'),
  ].join('\n');
  const routing = ledger.ledgerState({ text });
  assert.equal(routing.status, 'degraded');
  assert.equal(routing.reason, 'round-regression');
  const report = ledger.ledgerState({ text, report: true });
  assert.equal(report.status, 'partial');
  assert.equal(report.reason, 'round-regression');
  assert.equal(report.generation, 2);
  assert.deepEqual(report.entries.map((e) => e.id), ['G1:R1-F4', 'G1:R2-F1', 'R1-F9']);
});

test('the report read counts carried entries against the entry cap', () => {
  const lines = [];
  for (let i = 1; i < ledger.MAX_ENTRIES; i++) {
    lines.push(line('R1-F' + i, 'deferred', 'SUGGESTION', 'src/a.ts:' + i, 'earlier generation finding'));
  }
  lines.push('REVIEW BUDGET RESET');
  for (let i = 1; i <= 3; i++) {
    lines.push(line('R1-F' + i, 'deferred', 'SUGGESTION', 'src/b.ts:' + i, 'new generation finding'));
  }
  const report = ledger.ledgerState({ text: lines.join('\n'), report: true });
  assert.equal(report.status, 'partial');
  assert.equal(report.reason, 'truncated');
  assert.equal(report.entries.length, ledger.MAX_ENTRIES);
});

test('the report read carries open entries across two boundaries in generation order', () => {
  const text = [
    line('R3-F2', 'deferred', 'IMPORTANT', 'src/a.ts:9', 'first generation finding'),
    'REVIEW BUDGET RESET',
    line('R1-F1', 'deferred', 'IMPORTANT', 'src/b.ts:3', 'second generation finding'),
    'REVIEW BUDGET RESET',
    line('R1-F1', 'routed', 'IMPORTANT', 'src/c.ts:7', 'third generation finding'),
  ];
  const report = ledger.ledgerState({ text: text.join('\n'), report: true });
  assert.equal(report.status, 'ok');
  assert.equal(report.generation, 3);
  assert.deepEqual(report.entries.map((e) => e.id), ['G1:R3-F2', 'G2:R1-F1', 'R1-F1']);
  const closed = text.concat([line('G1:R3-F2', 'fixed', 'IMPORTANT', 'src/a.ts:9', 'fixed in the self-review round')]);
  const after = ledger.ledgerState({ text: closed.join('\n'), report: true });
  assert.deepEqual(after.entries.map((e) => e.id + ':' + e.state), [
    'G1:R3-F2:fixed',
    'G2:R1-F1:deferred',
    'R1-F1:routed-unfixed',
  ]);
  assert.equal(after.open, 2);
});

function convergenceProject(lines, receipt) {
  const root = tempDir();
  fs.mkdirSync(path.join(root, '.zensu', 'logs'), { recursive: true });
  fs.mkdirSync(path.join(root, '.zensu', 'state'), { recursive: true });
  if (lines !== null) fs.writeFileSync(path.join(root, '.zensu', 'logs', 'chain.log'), lines.join('\n') + '\n');
  const receiptPath = path.join(root, '.zensu', 'state', 'edit-landing-scv1_test.json');
  if (receipt !== null) {
    fs.writeFileSync(receiptPath, JSON.stringify(receipt || { schema: 'edit-landing-v2', log: '.zensu/logs/chain.log', claims: 0 }));
  }
  return { root, receipt: receiptPath };
}

function finalReview(round) {
  return ledger.FINAL_REVIEW_HEAD + round;
}

function converge(project, extra) {
  return ledger.convergence(Object.assign({ receipt: project.receipt, projectRoot: project.root, finalRound: 2 }, extra || {}));
}

test('openDefect names routed-unfixed, parked and deferred IMPORTANT or CRITICAL entries', () => {
  const entry = (state, severity) => ({ id: 'R1-F1', state, severity });
  assert.equal(ledger.openDefect(entry('routed-unfixed', 'SUGGESTION')), true);
  assert.equal(ledger.openDefect(entry('parked', 'IMPORTANT')), true);
  assert.equal(ledger.openDefect(entry('deferred', 'IMPORTANT')), true);
  assert.equal(ledger.openDefect(entry('deferred', 'CRITICAL')), true);
  assert.equal(ledger.openDefect(entry('deferred', 'SUGGESTION')), false);
  assert.equal(ledger.openDefect(entry('fixed', 'CRITICAL')), false);
  assert.equal(ledger.openDefect(entry('neutralized', 'IMPORTANT')), false);
  assert.equal(ledger.openDefect(null), false);
  assert.equal(ledger.openDefect('parked'), false);
});

test('a ledger whose only open entries are deferred suggestions converges', () => {
  const project = convergenceProject(ROUND_ONE.concat([
    line('R2-F1', 'deferred', 'SUGGESTION', 'src/d.ts:2', 'tighten wording'),
    finalReview(2),
  ]));
  const verdict = converge(project);
  assert.equal(verdict.converged, true);
  assert.equal(verdict.reason, 'converged');
  assert.equal(
    verdict.line,
    ledger.CONVERGENCE_HEAD + 'converged | the findings ledger holds no routed-unfixed or parked entry and no deferred IMPORTANT or CRITICAL entry (4 entries, 2 deferred suggestions still open)'
  );
});

test('an open defect keeps the attempt unconverged and names at most five ids', () => {
  const parked = convergenceProject(ROUND_ONE.concat([
    line('R2-F1', 'parked', 'IMPORTANT', 'src/d.ts:2', 'missing bound'),
    finalReview(2),
  ]));
  const one = converge(parked);
  assert.equal(one.converged, false);
  assert.equal(one.reason, 'open-defects');
  assert.equal(one.line, ledger.CONVERGENCE_HEAD + 'not converged | the findings ledger holds 1 open defect: R2-F1 parked IMPORTANT');
  const many = [];
  for (let i = 1; i <= 6; i++) many.push(line('R2-F' + i, 'routed', 'CRITICAL', 'src/e.ts:' + i, 'unfixed blocker'));
  const six = convergenceProject(many.concat([finalReview(2)]));
  const verdict = converge(six);
  assert.equal(verdict.converged, false);
  assert.match(verdict.line, /holds 6 open defects: R2-F1 routed-unfixed CRITICAL, .*R2-F5 routed-unfixed CRITICAL, …$/);
  assert.doesNotMatch(verdict.line, /R2-F6/);
});

test('a deferred CRITICAL entry is an open defect, a fixed one is not', () => {
  const lines = [line('R2-F1', 'deferred', 'CRITICAL', 'src/f.ts:4', 'not reproduced')];
  const open = convergenceProject(lines.concat([finalReview(2)]));
  assert.equal(converge(open).converged, false);
  const closed = convergenceProject(lines.concat([line('R2-F1', 'fixed', 'CRITICAL', 'src/f.ts:4', 'fixed by self-review'), finalReview(2)]));
  assert.equal(converge(closed).converged, true);
});

test('an open entry carried across a reset stays a defect until a qualified fixed line closes it', () => {
  const lines = [
    line('R2-F1', 'parked', 'IMPORTANT', 'src/g.ts:5', 'parked before the reset'),
    'REVIEW BUDGET RESET',
    line('R1-F1', 'deferred', 'SUGGESTION', 'src/h.ts:1', 'new generation suggestion'),
  ];
  const carried = convergenceProject(lines.concat([finalReview(2)]));
  const open = converge(carried);
  assert.equal(open.converged, false);
  assert.match(open.line, /G1:R2-F1 parked IMPORTANT$/);
  const closed = convergenceProject(lines.concat([line('G1:R2-F1', 'fixed', 'IMPORTANT', 'src/g.ts:5', 'fixed in self-review'), finalReview(2)]));
  assert.equal(converge(closed).converged, true);
});

test('a ledger that is not status=ok never converges', () => {
  const partial = convergenceProject(ROUND_ONE.concat(['FINDING LEDGER — broken line', finalReview(2)]));
  const verdict = converge(partial);
  assert.equal(verdict.reason, 'ledger-partial');
  assert.match(verdict.line, /answered status=partial \(malformed-line\)$/);
  const empty = convergenceProject(['BUILD STARTED — demo | steps: 1', finalReview(2)]);
  const none = converge(empty);
  assert.equal(none.converged, false);
  assert.equal(none.reason, 'ledger-empty');
  const missing = convergenceProject(null);
  const unread = converge(missing);
  assert.equal(unread.converged, false);
  assert.equal(unread.reason, 'ledger-degraded');
  assert.match(unread.line, /answered status=degraded \(log-unreadable\)$/);
});

test('convergence needs the setting and a receipt that names the run log', () => {
  const project = convergenceProject(ROUND_ONE.concat([finalReview(2)]));
  const off = converge(project, { enabled: false });
  assert.equal(off.converged, false);
  assert.equal(off.reason, 'disabled');
  assert.match(off.line, /hooks\.reviewConvergence is off/);
  const absent = convergenceProject(ROUND_ONE.concat([finalReview(2)]), null);
  const noReceipt = converge(absent);
  assert.equal(noReceipt.reason, 'no-receipt');
  const foreign = convergenceProject(ROUND_ONE.concat([finalReview(2)]), { schema: 'edit-landing-v9', log: '.zensu/logs/chain.log', claims: 0 });
  const unknown = converge(foreign);
  assert.equal(unknown.reason, 'receipt');
  assert.match(unknown.line, /names no run log under a known schema, so no run log is bound to this chain$/);
  const outside = convergenceProject(ROUND_ONE.concat([finalReview(2)]), { schema: 'edit-landing-v2', log: '../chain.log', claims: 0 });
  assert.equal(converge(outside).reason, 'receipt');
});

test('convergence needs the review round that met the cap and a FINAL REVIEW LEDGERED line for it', () => {
  const lines = ROUND_ONE.concat([line('R2-F1', 'deferred', 'SUGGESTION', 'src/d.ts:2', 'tighten wording')]);
  const unmarked = convergenceProject(lines);
  const noRound = ledger.convergence({ receipt: unmarked.receipt, projectRoot: unmarked.root });
  assert.equal(noRound.converged, false);
  assert.equal(noRound.reason, 'final-round');
  assert.equal(
    noRound.line,
    ledger.CONVERGENCE_HEAD + "not converged | the chain's review round could not be read, so the review that met the cap cannot be matched to the findings ledger"
  );
  for (const bad of [0, -1, 1.5, '2', null]) assert.equal(converge(unmarked, { finalRound: bad }).reason, 'final-round');
  const missing = converge(unmarked);
  assert.equal(missing.converged, false);
  assert.equal(missing.reason, 'final-review-unledgered');
  assert.equal(
    missing.line,
    ledger.CONVERGENCE_HEAD + "not converged | no 'FINAL REVIEW LEDGERED — R2' line follows the last review budget reset, so the findings of the review that met the cap may never have reached the ledger"
  );
  assert.equal(converge(convergenceProject(lines.concat([finalReview(1)]))).reason, 'final-review-unledgered');
  assert.equal(converge(convergenceProject([finalReview(2), 'REVIEW BUDGET RESET'].concat(lines))).reason, 'final-review-unledgered');
  assert.equal(converge(convergenceProject(lines.concat(['note: ' + finalReview(2)]))).reason, 'final-review-unledgered');
  assert.equal(converge(convergenceProject(lines.concat(['[2026-11-15 10:00:00] ' + finalReview(2) + ' ']))).converged, true);
  assert.equal(converge(convergenceProject(lines.concat(['FINAL REVIEW LEDGERED - R2']))).converged, true);
  assert.equal(ledger.finalReviewLedgered([finalReview(3), 'REVIEW BUDGET RESET', finalReview(2)].join('\n'), 2), true);
  assert.equal(ledger.finalReviewLedgered([finalReview(2), 'REVIEW BUDGET RESET', finalReview(3)].join('\n'), 2), false);
});

test('a ledger line lost before the last reset keeps the attempt unconverged while the report read stays ok', () => {
  const lines = [
    'FINDING LEDGER — broken line',
    'REVIEW BUDGET RESET',
    line('R1-F1', 'deferred', 'SUGGESTION', 'src/h.ts:1', 'new generation suggestion'),
    finalReview(2),
  ];
  const verdict = converge(convergenceProject(lines));
  assert.equal(verdict.converged, false);
  assert.equal(verdict.reason, 'ledger-lost');
  assert.match(verdict.line, /could not read a line before its last review budget reset \(malformed-line\)$/);
  const report = ledger.ledgerState({ text: lines.join('\n'), report: true });
  assert.equal(report.status, 'ok');
  assert.equal(report.lost, 'malformed-line');
  const routing = ledger.ledgerState({ text: lines.join('\n') });
  assert.equal(routing.status, 'ok');
  assert.equal(routing.lost, undefined);
  const twice = ledger.ledgerState({
    text: ['FINDING LEDGER — first broken line', 'REVIEW BUDGET RESET', 'FINDING LEDGER — second broken line', 'REVIEW BUDGET RESET', line('R1-F1', 'deferred', 'SUGGESTION', 'src/h.ts:1', 'third generation')].join('\n'),
    report: true,
  });
  assert.equal(twice.status, 'ok');
  assert.equal(twice.lost, 'malformed-line');
});

test('a parked line for an earlier deferred suggestion blocks convergence, and a carried id cannot be parked', () => {
  const parked = convergenceProject([
    line('R1-F1', 'deferred', 'SUGGESTION', 'src/i.ts:3', 'deferred as a suggestion'),
    line('R1-F1', 'parked', 'IMPORTANT', 'src/i.ts:3', 'the final review raised it again as important'),
    finalReview(2),
  ]);
  const verdict = converge(parked);
  assert.equal(verdict.converged, false);
  assert.equal(verdict.line, ledger.CONVERGENCE_HEAD + 'not converged | the findings ledger holds 1 open defect: R1-F1 parked IMPORTANT');
  const carried = convergenceProject([
    line('R1-F1', 'deferred', 'SUGGESTION', 'src/i.ts:3', 'deferred as a suggestion'),
    'REVIEW BUDGET RESET',
    line('G1:R1-F1', 'parked', 'IMPORTANT', 'src/i.ts:3', 'a carried id takes only a fixed line'),
    finalReview(2),
  ]);
  assert.equal(converge(carried).reason, 'ledger-partial');
});

test('reviewRoundOf reads a positive review round from a bounded regular file only', () => {
  const dir = tempDir();
  const file = path.join(dir, 'tdd-phase-scv1_test.json');
  fs.writeFileSync(file, JSON.stringify({ reviewRound: 2 }));
  assert.equal(ledger.reviewRoundOf(file), 2);
  for (const value of [0, -1, 1.5, '2', null]) {
    fs.writeFileSync(file, JSON.stringify({ reviewRound: value }));
    assert.equal(ledger.reviewRoundOf(file), null);
  }
  fs.writeFileSync(file, '{not json');
  assert.equal(ledger.reviewRoundOf(file), null);
  fs.writeFileSync(file, JSON.stringify({ reviewRound: 2, pad: 'x'.repeat(1048576) }));
  assert.equal(ledger.reviewRoundOf(file), null);
  assert.equal(ledger.reviewRoundOf(path.join(dir, 'absent.json')), null);
  assert.equal(ledger.reviewRoundOf(dir), null);
  assert.equal(ledger.reviewRoundOf(''), null);
  assert.equal(ledger.reviewRoundOf(undefined), null);
  fs.writeFileSync(file, JSON.stringify({ reviewRound: 3 }));
  const link = path.join(dir, 'linked.json');
  let linked = true;
  try {
    fs.symlinkSync(file, link);
  } catch (_) {
    linked = false;
  }
  if (linked) assert.equal(ledger.reviewRoundOf(link), null);
  assert.equal(ledger.reviewRoundOf(file), 3);
});

test('convergenceMain writes one line and answers 0 only for a converged ledger', () => {
  const written = [];
  const stdout = { write: (text) => written.push(text) };
  const project = convergenceProject(ROUND_ONE.concat([finalReview(2)]));
  const state = path.join(project.root, '.zensu', 'state', 'tdd-phase-scv1_test.json');
  fs.writeFileSync(state, JSON.stringify({ reviewRound: 2 }));
  const env = { ZENSU_RL_RECEIPT: project.receipt, ZENSU_RL_PROJECT_ROOT: project.root, ZENSU_RL_STATE: state };
  assert.equal(ledger.convergenceMain(env, stdout), 0);
  assert.equal(written.length, 1);
  assert.ok(written[0].startsWith(ledger.CONVERGENCE_HEAD + 'converged | '));
  assert.ok(!written[0].includes('\n'));
  assert.equal(ledger.convergenceMain(Object.assign({}, env, { ZENSU_RL_CONVERGENCE: 'off' }), stdout), 3);
  assert.ok(written[1].startsWith(ledger.CONVERGENCE_HEAD + 'not converged | hooks.reviewConvergence is off'));
  assert.equal(ledger.convergenceMain(Object.assign({}, env, { ZENSU_RL_STATE: '' }), stdout), 3);
  assert.ok(written[2].startsWith(ledger.CONVERGENCE_HEAD + "not converged | the chain's review round could not be read"));
  fs.writeFileSync(state, JSON.stringify({ reviewRound: 3 }));
  assert.equal(ledger.convergenceMain(env, stdout), 3);
  assert.ok(written[3].includes("no 'FINAL REVIEW LEDGERED — R3' line follows"));
  assert.equal(ledger.convergenceMain({}, stdout), 3);
  assert.ok(written[4].startsWith(ledger.CONVERGENCE_HEAD + 'not converged | '));
});
