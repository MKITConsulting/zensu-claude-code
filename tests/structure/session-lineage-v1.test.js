// Unit contract for skills/session-trail/scripts/session-lineage-v1.mjs.
//
// The shape lattice and the refusal table are what a unit layer can pin and the
// end-to-end bash suite cannot: a bash check can observe that a chain renders,
// not that a cycle terminates by the `seen` set rather than by luck, nor that a
// record one schema version ahead is refused with a DIFFERENT reason than a
// corrupt one. Driven from test-session-trail-lineage.sh so tests/run-all.sh,
// which discovers only test-*.sh, actually executes it.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const mod = await import(new URL('../../skills/session-trail/scripts/session-lineage-v1.mjs', import.meta.url));

const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-lineage-unit-'));
const ep = (id, extra = {}) => ({ sessionId: id, ...extra });
const edge = (from, to, at) => ({
  schemaVersion: 1,
  from: mod.makeEndpoint(ep(from)),
  to: mod.makeEndpoint(ep(to)),
  repo: { name: 'r', root: '/r' },
  reason: 'manual',
  inferred: false,
  recordedAt: at,
  recordedBy: 'adopt',
});

test('the directory segment is derived from the schema constant, not hand-written', () => {
  const p = mod.ledgerPaths('/cfg');
  assert.ok(p.edges.includes(`v${mod.LEDGER_SCHEMA_VERSION}`));
  assert.ok(p.labels.endsWith('labels.json'));
});

test('bounded text flattens newlines and truncates, so a value cannot fabricate a line', () => {
  assert.equal(mod.boundText('a\nb'), 'a b');
  assert.equal(mod.boundText('   '), null);
  assert.equal(mod.boundText(null), null);
  // The control/format half of the class, which `\s` alone also satisfies — so
  // without these two the widening could be reverted with every assertion green.
  assert.ok(!mod.boundText('a\u001bb').includes('\u001b'), 'ESC must not survive');
  assert.ok(!mod.boundText('a\u202Eb').includes('\u202E'), 'a bidi override must not survive');
  const long = mod.boundText('x'.repeat(500));
  assert.ok(long.length <= 200);
  assert.ok(long.endsWith('…'));
});

test('every endpoint has the same key set, whichever producer built it', () => {
  const a = mod.makeEndpoint({ sessionId: 's' });
  const b = mod.makeEndpoint({ sessionId: 's', cwd: '/x', extra: 'ignored' });
  assert.deepEqual(Object.keys(a), mod.ENDPOINT_KEYS);
  assert.deepEqual(Object.keys(b), mod.ENDPOINT_KEYS);
  assert.equal(b.extra, undefined);
});

test('the edge repo comes from the handed-over work, never from a caller-supplied endpoint', () => {
  const e = mod.buildEdge({
    from: ep('a'), to: ep('b', { worktree: '/taker/elsewhere' }),
    workRoot: '/work/real', repoRootOf: (r) => r,
    reason: 'rate_limit', recordedBy: 'takeover', inferred: false, at: 'T',
  });
  assert.equal(e.repo.root, '/work/real');
  assert.equal(e.to.worktree, '/taker/elsewhere');
  assert.equal(e.toolVersion, undefined, 'no field may name the producing build while carrying the schema number');
});

test('a newer schema is refused with a different reason than a corrupt record', () => {
  assert.equal(mod.classifyEdge({ schemaVersion: 99, from: { sessionId: 'a' }, to: { sessionId: 'b' } }).reason, mod.EDGE_REFUSALS.SCHEMA_NEWER);
  assert.equal(mod.classifyEdge({ schemaVersion: 0, from: { sessionId: 'a' }, to: { sessionId: 'b' } }).reason, mod.EDGE_REFUSALS.SCHEMA_OLDER);
  assert.equal(mod.classifyEdge({ schemaVersion: 1, from: {}, to: { sessionId: 'b' } }).reason, mod.EDGE_REFUSALS.MALFORMED);
  assert.equal(mod.classifyEdge(null).reason, mod.EDGE_REFUSALS.MALFORMED);
  assert.equal(mod.classifyEdge(edge('a', 'b', 'T')).ok, true);
});

test('an unreadable directory is reported apart from an absent one', () => {
  const root = tmp();
  assert.equal(mod.readEdges(path.join(root, 'nope')).directoryError, null, 'absent is not an error');
  const asFile = path.join(root, 'edges');
  fs.writeFileSync(asFile, 'x');
  assert.equal(mod.readEdges(asFile).directoryError, 'ENOTDIR');
  fs.rmSync(root, { recursive: true, force: true });
});

test('a symlinked ledger path is refused rather than followed', { skip: process.platform === 'win32' }, () => {
  const root = tmp();
  const real = path.join(root, 'real');
  fs.mkdirSync(real, { recursive: true });
  const link = path.join(root, 'link');
  fs.symlinkSync(real, link);
  const named = new RegExp(link.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  assert.throws(() => mod.ensureLedgerDir(path.join(link, 'edges'), root), /symlink/);
  assert.throws(() => mod.ensureLedgerDir(path.join(link, 'edges'), root), named,
    'the refusal must name the planted link, not whichever ancestor happened to be one');
  fs.rmSync(root, { recursive: true, force: true });
});

test('the chain walk terminates on a cycle and reports the fork it did not take', () => {
  const cyc = [edge('a', 'b', '1'), edge('b', 'a', '2')];
  const w = mod.walkChain('a', cyc);
  assert.ok(w.links.length < 64, 'the seen set, not the hop bound, is what stops it');
  assert.equal(mod.chainRoots(cyc).length >= 1, true, 'a cycle still yields a root, never silence beside a non-zero count');

  const fork = [edge('a', 'b', '1'), edge('a', 'c', '2')];
  const f = mod.walkChain('a', fork);
  assert.equal(f.links[0].to.sessionId, 'c', 'the LATEST branch is the one "where is this now" wants');
  assert.equal(f.forks.length, 1);
  assert.deepEqual(f.forks[0].alsoTo, ['b']);
});

test('counts collapse per session pair, keeping the newest record', () => {
  const dup = [edge('a', 'b', '1'), edge('a', 'b', '2'), edge('a', 'c', '3')];
  const out = mod.dedupeEdges(dup);
  assert.equal(out.length, 2);
  assert.equal(out.find((e) => e.to.sessionId === 'b').recordedAt, '2');
});

test('labels keep two namespaces and are bounded', () => {
  const norm = mod.normalizeLabels({ accounts: { a: 'x\ny' }, windows: { 123: 'w' }, junk: 1 });
  assert.equal(norm.accounts.a, 'x y');
  assert.equal(norm.windows['123'], 'w');
  assert.equal(norm.junk, undefined);
  assert.deepEqual(mod.normalizeLabels(null), mod.emptyLabels());
  // Parsed from text so the keys are real own-properties, which is how a planted
  // labels.json would carry them.
  const hostile = mod.normalizeLabels(JSON.parse('{"accounts":{"__proto__":"x","constructor":"y"}}'));
  assert.equal(Object.getPrototypeOf(hostile.accounts), null, 'the map keeps a null prototype');
  assert.equal(hostile.accounts.toString, undefined, 'no inherited member is reachable');
});

test('the hop bound is reported when it bites', () => {
  const chain = [edge('a', 'b', '1'), edge('b', 'c', '2'), edge('c', 'd', '3')];
  assert.equal(mod.walkChain('a', chain, 2).truncated, true);
  assert.equal(mod.walkChain('a', chain).truncated, false);
});

test('an oversized or non-regular ledger entry is refused, not read', () => {
  const root = tmp();
  const p = mod.ledgerPaths(root);
  mod.writeEdge(p.edges, edge('a', 'b', '1'), 1, root);
  fs.writeFileSync(path.join(p.edges, '2-oversize.json'), 'x'.repeat(300 * 1024));
  const out = mod.readEdges(p.edges);
  assert.equal(out.edges.length, 1, 'the good record still reads');
  assert.equal(out.refused.length, 1, 'the oversized one is refused, not parsed');
  fs.rmSync(root, { recursive: true, force: true });
});

test('labels land by rename, so a concurrent reader never sees a half-written file', () => {
  const root = tmp();
  const p = mod.ledgerPaths(root);
  mod.writeLabels(p.labels, { ...mod.emptyLabels(), accounts: { a: 'One' } }, root);
  assert.equal(mod.readLabels(p.labels).labels.accounts.a, 'One');
  const strays = fs.readdirSync(path.dirname(p.labels)).filter((n) => n.endsWith('.tmp'));
  assert.deepEqual(strays, [], 'no temp file is left behind');
  fs.rmSync(root, { recursive: true, force: true });
});

test('an unreadable label file is reported, not silently reported as "no labels"', () => {
  const root = tmp();
  const p = mod.ledgerPaths(root);
  fs.mkdirSync(path.dirname(p.labels), { recursive: true });
  fs.writeFileSync(p.labels, 'not json');
  const r = mod.readLabels(p.labels);
  assert.equal(r.unreadable, true);
  assert.deepEqual(r.labels, mod.emptyLabels());
  fs.rmSync(root, { recursive: true, force: true });
});

test('the host session id is refused before it can become a path component', () => {
  assert.equal(mod.isSafeHostSessionId('local_8a7e6341-3416-42a7-a1c5-ff42e1856935'), true);
  assert.equal(mod.isSafeHostSessionId('../../../../etc/passwd'), false);
  assert.equal(mod.isSafeHostSessionId('a/b'), false);
  assert.equal(mod.isSafeHostSessionId('..'), false);
  assert.equal(mod.isSafeHostSessionId(''), false);
  assert.equal(mod.isSafeHostSessionId(null), false);
});

test('record file names carry no character Windows forbids', () => {
  const n = mod.edgeFileName(1787321711000);
  assert.ok(!n.includes(':'));
  assert.match(n, /^\d+-[0-9a-f]{16}\.json$/);
  assert.notEqual(n, mod.edgeFileName(1787321711000), 'names are unpredictable, not a function of the clock alone');
});

test('an edge record is created exclusively and never overwrites a sibling', () => {
  const root = tmp();
  const p = mod.ledgerPaths(root);
  const a = mod.writeEdge(p.edges, edge('a', 'b', '1'), 1, root);
  const b = mod.writeEdge(p.edges, edge('a', 'c', '2'), 1, root);
  assert.notEqual(a, b);
  assert.equal(mod.readEdges(p.edges).edges.length, 2);
  if (process.platform !== 'win32') {
    assert.equal(fs.statSync(p.edges).mode & 0o777, 0o700);
    assert.equal(fs.statSync(a).mode & 0o777, 0o600);
  }
  fs.rmSync(root, { recursive: true, force: true });
});

test('the ceiling bounds the lstat walk, so an ancestor symlink ABOVE it is not reached', { skip: process.platform === 'win32' }, () => {
  const root = tmp();
  // The discriminating pair. A symlink sits above the ceiling; below it the tree is
  // ordinary. Bounded by `base`, the walk never sees the link and the call succeeds;
  // unbounded, it climbs into the link and refuses. Either assertion alone proves
  // nothing -- the success half would pass with `stopAt` ignored entirely, and the
  // failure half would pass with the walk bounded at any depth at all.
  const real = path.join(root, 'real');
  fs.mkdirSync(real, { recursive: true });
  const via = path.join(root, 'via');
  fs.symlinkSync(real, via);
  const base = path.join(via, 'cfg');
  const p = mod.ledgerPaths(base);
  mod.ensureLedgerDir(p.edges, base);
  assert.ok(fs.existsSync(p.edges), 'bounded at the ceiling, the ledger directory is created');
  assert.throws(() => mod.ensureLedgerDir(path.join(p.edges, 'deeper')), /symlink/,
    'unbounded, the same walk climbs into the ancestor symlink and refuses');
  // Stated rather than implied: `stopAt` bounds the WALK, not the mkdir. The mkdir
  // is recursive, so every missing ancestor below the leaf is still created -- the
  // ceiling is a refusal bound, never a creation bound.
  assert.ok(fs.existsSync(base), 'the ceiling itself is created by the recursive mkdir');
  fs.rmSync(root, { recursive: true, force: true });
});

test('a NUL-only session id is refused, because trim() and boundText disagree about empty', () => {
  // trim() strips WhiteSpace and LineTerminator only, so "\u0000" survives the raw
  // guard; boundText replaces the whole Cc/Cf class and yields null. Judging the raw
  // half alone shipped an edge whose sessionId was null into every renderer.
  const raw = JSON.parse('{"schemaVersion":1,"from":{"sessionId":"\\u0000"},"to":{"sessionId":"b"},"repo":{"name":"r","root":"/r"},"reason":"manual","inferred":false,"recordedAt":"1","recordedBy":"adopt"}');
  const r = mod.classifyEdge(raw);
  assert.equal(r.ok, false);
  assert.equal(r.reason, mod.EDGE_REFUSALS.MALFORMED);
  // The positive control: an ordinary id still classifies, so the guard did not
  // simply start refusing everything.
  assert.equal(mod.classifyEdge(edge('a', 'b', '1')).ok, true);
});
