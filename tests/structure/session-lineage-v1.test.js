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
import { execFileSync } from 'node:child_process';

const mod = await import(new URL('../../skills/session-trail/scripts/session-lineage-v1.mjs', import.meta.url));

const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-lineage-unit-'));
const ep = (id, extra = {}) => ({ sessionId: id, ...extra });
// `recordedAt` is now REQUIRED to be a canonical ISO-8601 UTC instant, because it
// is the sole ordering and dedupe key and nothing used to parse it. The fixtures
// used ordinals (`'1'`, `'2'`), which the validation correctly refuses — `iso`
// keeps the ordinal readable at the call sites while producing a real instant, and
// preserves the property those call sites rely on: ordinal order IS string order.
const iso = (n) => new Date(Date.UTC(2026, 0, 1, 0, 0, Number(n))).toISOString();
const edge = (from, to, at) => ({
  schemaVersion: 1,
  from: mod.makeEndpoint(ep(from)),
  to: mod.makeEndpoint(ep(to)),
  repo: { name: 'r', root: '/r' },
  reason: 'manual',
  inferred: false,
  recordedAt: iso(at),
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
  // Against a LITERAL, not against ENDPOINT_KEYS. That constant is
  // Object.freeze(Object.keys(makeEndpoint({}))), so comparing it with
  // Object.keys(makeEndpoint(x)) puts the same expression on both sides: deleting
  // `title` from the constructor moved both and the assertion stayed green. The
  // third line is what keeps the exported constant honest; the first two are what
  // make a key removal in the constructor fail.
  const EXPECTED = ['sessionId', 'accountUuid', 'appPid', 'pid', 'cwd', 'worktree', 'branch', 'title'];
  const a = mod.makeEndpoint({ sessionId: 's' });
  const b = mod.makeEndpoint({ sessionId: 's', cwd: '/x', extra: 'ignored' });
  assert.deepEqual(Object.keys(a), EXPECTED);
  assert.deepEqual(Object.keys(b), EXPECTED);
  assert.deepEqual([...mod.ENDPOINT_KEYS], EXPECTED);
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
  assert.equal(mod.classifyEdge(edge('a', 'b', 3)).ok, true);
});

test('recordedAt must be a canonical ISO instant, because it is the ordering and dedupe key', () => {
  // It decides the read order, which successor `walkChain` follows and which
  // duplicate `dedupeEdges` keeps, and it used to pass through `boundText` only —
  // which accepts any non-empty string. `zzzz` sorted after every real timestamp.
  const withAt = (at) => ({ ...edge('a', 'b', 1), recordedAt: at });
  for (const bad of ['zzzz', '1', '2026-01-01', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00.000+01:00',
    '2026-02-31T00:00:00.000Z', '', null, 42]) {
    assert.equal(mod.classifyEdge(withAt(bad)).reason, mod.EDGE_REFUSALS.MALFORMED, String(bad));
  }
  assert.equal(mod.classifyEdge(withAt('2026-01-01T00:00:00.000Z')).ok, true);
  assert.equal(mod.isIsoInstant('2026-01-01T00:00:00.000Z'), true);
  assert.equal(mod.isIsoInstant('2026-02-31T00:00:00.000Z'), false);
});

test('classifyEdge returns a closed key set, so an unbounded field cannot ride through', () => {
  // The `...raw` spread admitted every key outside the six this function
  // overwrites — untouched by `boundText`, up to the 256 KiB record cap — and
  // these objects reach `lineage --where --json` verbatim.
  const raw = { ...edge('a', 'b', 1), evil: 'x'.repeat(5000), nested: { also: 'here' } };
  const out = mod.classifyEdge(raw);
  assert.equal(out.ok, true);
  assert.equal(out.edge.evil, undefined);
  assert.equal(out.edge.nested, undefined);
  assert.deepEqual(Object.keys(out.edge).sort(),
    ['from', 'inferred', 'reason', 'recordedAt', 'recordedBy', 'repo', 'schemaVersion', 'to']);
});

test('one comparison rule orders, dedupes and walks, and it is not locale-dependent', () => {
  // Two spellings of one comparison let dedupe keep a record the sort then ordered
  // by a different rule, and `localeCompare` with no arguments resolves the host
  // locale, so the order depended on the runtime ICU build and on LANG/LC_ALL.
  assert.equal(mod.compareRecordedAt({ recordedAt: iso(1) }, { recordedAt: iso(2) }) < 0, true);
  assert.equal(mod.compareRecordedAt({ recordedAt: iso(2) }, { recordedAt: iso(1) }) > 0, true);
  assert.equal(mod.compareRecordedAt({ recordedAt: iso(1) }, { recordedAt: iso(1) }), 0);
  assert.equal(mod.compareRecordedAt({}, {}), 0);
});

test('a chain that returns to an earlier session reports the return instead of ending silently', () => {
  // SKILL.md flow 3 step 6 teaches the shape: after a reset the user goes back to
  // the original window and runs `adopt`, so the store holds A>B and later B>A.
  // The `seen` filter cut the walk at B and rendered a one-hop chain as complete.
  const edges = [edge('a', 'b', 1), edge('b', 'a', 2)];
  const out = mod.walkChain('a', edges);
  assert.equal(out.links.length, 1);
  assert.equal(out.truncated, false);
  assert.equal(out.returns.length, 1);
  assert.equal(out.returns[0].at, 'b');
  assert.deepEqual(out.returns[0].backTo, ['a']);
  // A chain that simply ends reports no return, so the field discriminates.
  assert.deepEqual(mod.walkChain('a', [edge('a', 'b', 1)]).returns, []);
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
  assert.equal(out.find((e) => e.to.sessionId === 'b').recordedAt, iso(2));
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

test('the ledger dir refuses a symlinked component it creates, and accepts a symlinked CEILING', () => {
  // The ceiling is the directory the CALLER named — `~/.claude` is a symlink under
  // chezmoi/stow — so type-checking it made every ledger write fail permanently
  // while blaming the ledger. Only the components this module creates are judged.
  const root = tmp();
  const real = path.join(root, 'real-config');
  const link = path.join(root, 'config');
  fs.mkdirSync(real);
  let linked = true;
  try { fs.symlinkSync(real, link, 'dir'); } catch { linked = false; }
  if (linked && fs.lstatSync(link).isSymbolicLink()) {
    const edges = path.join(link, 'zensu', 'session-lineage', 'v1', 'edges');
    mod.ensureLedgerDir(edges, link);
    assert.equal(fs.statSync(edges).isDirectory(), true);
    // and a symlink BELOW the ceiling is still refused.
    const root2 = tmp();
    const cfg2 = path.join(root2, 'cfg');
    fs.mkdirSync(path.join(cfg2, 'zensu'), { recursive: true });
    const target = path.join(root2, 'elsewhere');
    fs.mkdirSync(target);
    fs.symlinkSync(target, path.join(cfg2, 'zensu', 'session-lineage'), 'dir');
    assert.throws(() => mod.ensureLedgerDir(path.join(cfg2, 'zensu', 'session-lineage', 'v1', 'edges'), cfg2),
      /symlinked ledger path/);
    fs.rmSync(root2, { recursive: true, force: true });
  }
  fs.rmSync(root, { recursive: true, force: true });
});

test('an edge record never overwrites an existing name, and the retry loop is what handles it', () => {
  // `rename` REPLACES silently, so the five-attempt loop was guarding the only
  // create that cannot realistically collide (a pid-scoped temp with 48 bits of
  // entropy) while the create that decides the record's identity overwrote
  // whatever was there. `link` fails EEXIST, so the retry now retries a collision.
  const root = tmp();
  const edges = path.join(root, 'edges');
  mod.ensureLedgerDir(edges, root);
  const now = 1767225600000;
  const first = mod.writeEdge(edges, edge('a', 'b', 1), now, root);
  const planted = path.join(edges, path.basename(first));
  const before = fs.readFileSync(planted, 'utf8');
  const second = mod.writeEdge(edges, edge('c', 'd', 2), now, root);
  assert.notEqual(path.basename(second), path.basename(first), 'a second record took its own name');
  assert.equal(fs.readFileSync(planted, 'utf8'), before, 'the first record was not overwritten');
  assert.equal(fs.readdirSync(edges).filter((n) => n.endsWith('.json')).length, 2);
  // No temp file survives either half.
  assert.deepEqual(fs.readdirSync(edges).filter((n) => n.endsWith('.tmp')), []);
  fs.rmSync(root, { recursive: true, force: true });
});

test('a FIFO planted in the ledger cannot block the read', { skip: process.platform === 'win32' }, () => {
  // The type check runs after the open, so it cannot protect the open itself: on
  // POSIX `open(fifo, O_RDONLY)` blocks until a writer arrives, and this directory
  // is writable by every session on the host. O_NONBLOCK is what makes it return.
  const root = tmp();
  const edges = path.join(root, 'edges');
  mod.ensureLedgerDir(edges, root);
  let made = false;
  try {
    execFileSync('mkfifo', [path.join(edges, 'blocking.json')], { stdio: 'ignore' });
    made = true;
  } catch { /* no mkfifo on this host */ }
  if (made) {
    const out = mod.readEdges(edges);
    assert.equal(out.edges.length, 0);
    assert.equal(out.refused.length, 1);
    assert.equal(out.refused[0].reason, mod.EDGE_REFUSALS.UNREADABLE);
  }
  fs.rmSync(root, { recursive: true, force: true });
});
