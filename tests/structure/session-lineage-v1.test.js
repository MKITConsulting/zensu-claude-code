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
// Fixed-width UTC, because that is the only shape `isIsoInstant` accepts and the only
// one whose code-unit order is chronological. The bare ordinals these fixtures used to
// pass were readable but not records: they parsed, so nothing refused them, and they
// sorted by code unit against real stamps.
const at = (n) => `2026-01-0${n}T00:00:00.000Z`;

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
  // A real stamp, not the former placeholder `'T'`: `recordedAt` is now judged
  // (it decides the dedupe survivor and the branch the walk prefers), so an
  // unparseable value is MALFORMED. This case is about the schema table, and its
  // fixture must not also be asserting that the timestamp is opaque.
  assert.equal(mod.classifyEdge(edge('a', 'b', '2026-01-01T00:00:00.000Z')).ok, true);
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
  const cyc = [edge('a', 'b', at(1)), edge('b', 'a', at(2))];
  const w = mod.walkChain('a', cyc);
  assert.ok(w.links.length < 64, 'the seen set, not the hop bound, is what stops it');
  assert.equal(mod.chainRoots(cyc).length >= 1, true, 'a cycle still yields a root, never silence beside a non-zero count');

  const fork = [edge('a', 'b', at(1)), edge('a', 'c', at(2))];
  const f = mod.walkChain('a', fork);
  assert.equal(f.links[0].to.sessionId, 'c', 'the LATEST branch is the one "where is this now" wants');
  assert.equal(f.forks.length, 1);
  assert.deepEqual(f.forks[0].alsoTo, ['b']);
});

test('counts collapse per session pair, keeping the newest record', () => {
  const dup = [edge('a', 'b', at(1)), edge('a', 'b', at(2)), edge('a', 'c', at(3))];
  const out = mod.dedupeEdges(dup);
  assert.equal(out.length, 2);
  assert.equal(out.find((e) => e.to.sessionId === 'b').recordedAt, at(2));
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
  const chain = [edge('a', 'b', at(1)), edge('b', 'c', at(2)), edge('c', 'd', at(3))];
  assert.equal(mod.walkChain('a', chain, 2).truncated, true);
  assert.equal(mod.walkChain('a', chain).truncated, false);
});

test('an oversized or non-regular ledger entry is refused, not read', () => {
  // BOTH halves of the name, because `readBoundedFile` guards them separately and
  // the oversized fixture alone left `!st.isFile()` untested — a one-line deletion
  // this case would have stayed green through. That guard is what stops a directory
  // or a FIFO named `<n>.json`, planted in a machine-wide session-writable
  // directory, from being opened at all.
  const root = tmp();
  const p = mod.ledgerPaths(root);
  mod.writeEdge(p.edges, edge('a', 'b', at(1)), 1, root);
  fs.writeFileSync(path.join(p.edges, '2-oversize.json'), 'x'.repeat(300 * 1024));
  fs.mkdirSync(path.join(p.edges, '3-directory.json'));
  let planted = 2;
  if (process.platform !== 'win32') {
    try {
      execFileSync('mkfifo', [path.join(p.edges, '4-fifo.json')], { stdio: 'ignore' });
      planted = 3;
    } catch { /* no mkfifo on this host */ }
  }
  const out = mod.readEdges(p.edges);
  assert.equal(out.edges.length, 1, 'the good record still reads');
  assert.equal(out.refused.length, planted, 'every non-record entry is refused, not parsed');
  // The non-regular ones carry the DISTINCT reason, not the generic one: the remedy
  // for "something else is sitting on this name" is not the remedy for a bad read,
  // and collapsing them would let the guard be replaced by the size check alone.
  const byName = new Map(out.refused.map((r) => [r.file, r.reason]));
  assert.equal(byName.get('3-directory.json'), mod.EDGE_REFUSALS.NOT_A_FILE);
  if (planted === 3) assert.equal(byName.get('4-fifo.json'), mod.EDGE_REFUSALS.NOT_A_FILE);
  fs.rmSync(root, { recursive: true, force: true });
});

test('labels land by rename, so a concurrent reader never sees a half-written file', () => {
  // The rename is OBSERVED, not inferred. Reading the value back and finding no
  // stray `.tmp` both hold for the plain truncating write this replaced: the value
  // reads back either way, and no temp survives because none was ever created. What
  // discriminates is the INODE — a rename publishes a new one over the name, while a
  // truncating write keeps the old one — so the file is written twice and the two
  // identities are compared.
  const root = tmp();
  const p = mod.ledgerPaths(root);
  mod.writeLabels(p.labels, { ...mod.emptyLabels(), accounts: { a: 'One' } }, root);
  assert.equal(mod.readLabels(p.labels).labels.accounts.a, 'One');
  const first = fs.statSync(p.labels);
  mod.writeLabels(p.labels, { ...mod.emptyLabels(), accounts: { a: 'Two' } }, root);
  const second = fs.statSync(p.labels);
  assert.equal(mod.readLabels(p.labels).labels.accounts.a, 'Two', 'the second write is the one that reads back');
  assert.notEqual(second.ino, first.ino, 'the second write published a NEW inode, i.e. it landed by rename');
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
  const a = mod.writeEdge(p.edges, edge('a', 'b', at(1)), 1, root);
  const b = mod.writeEdge(p.edges, edge('a', 'c', at(2)), 1, root);
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

test('recordedAt is judged by SHAPE, because the ordering is a string compare', () => {
  // Every comparison in the module ranks `recordedAt` by code unit, which is only
  // chronological for the fixed-width UTC spelling `toISOString()` produces. The guard
  // was `Number.isFinite(Date.parse(...))`, which judges VALIDITY and not shape.
  // Measured against that guard before this landed, all three were accepted:
  //   "July 4, 2026"             parses, sorts ABOVE every real stamp, is EARLIER
  //   "9999"                     the very value the ordering comment names as the
  //                              motivating defect -- still accepted, still outranks
  //                              every record for as long as the store keeps it
  //   "2026-02-31T00:00:00.000Z" accepted as a February date meaning 3 March
  // The store is append-only and machine-wide, so one such record wins the dedupe
  // survivor, the branch the walk prefers and the `--where` answer, permanently.
  const withStamp = (stamp) => ({ ...edge('a', 'b', at(1)), recordedAt: stamp });
  for (const bad of ['July 4, 2026', '9999', '2026-02-31T00:00:00.000Z', '2026-08-25T12:00:00Z', '']) {
    const r = mod.classifyEdge(withStamp(bad));
    assert.equal(r.ok, false, `${JSON.stringify(bad)} must be refused`);
    assert.equal(r.reason, mod.EDGE_REFUSALS.MALFORMED);
  }
  // The predicate itself, so the refusals above cannot be satisfied by a guard that
  // rejects everything, and so the accepted spelling is stated once.
  assert.equal(mod.isIsoInstant('2026-08-25T12:00:00.000Z'), true);
  assert.equal(mod.isIsoInstant(new Date().toISOString()), true,
    'the shape every writer in this tree produces must be the shape the reader accepts');
  assert.equal(mod.classifyEdge(edge('a', 'b', at(1))).ok, true);
});

test('a NUL-only session id is refused, because trim() and boundText disagree about empty', () => {
  // trim() strips WhiteSpace and LineTerminator only, so "\u0000" survives the raw
  // guard; boundText replaces the whole Cc/Cf class and yields null. Judging the raw
  // half alone shipped an edge whose sessionId was null into every renderer.
  const raw = JSON.parse('{"schemaVersion":1,"from":{"sessionId":"\\u0000"},"to":{"sessionId":"b"},"repo":{"name":"r","root":"/r"},"reason":"manual","inferred":false,"recordedAt":"2026-01-01T00:00:00.000Z","recordedBy":"adopt"}');
  const r = mod.classifyEdge(raw);
  assert.equal(r.ok, false);
  assert.equal(r.reason, mod.EDGE_REFUSALS.MALFORMED);
  // The positive control: an ordinary id still classifies, so the guard did not
  // simply start refusing everything.
  assert.equal(mod.classifyEdge(edge('a', 'b', at(1))).ok, true);
});

// --- S1: the confidence tier, and that it DECIDES rather than merely displays ---

test('the confidence tier is an ordered, closed vocabulary', () => {
  // Ordered because dedupe and the walk rank by it; closed because it reaches a
  // renderer and a persisted record.
  assert.deepEqual(mod.CONFIDENCE_ORDER, ['inferred', 'provisional', 'confirmed']);
  assert.equal(mod.confidenceRank('confirmed') > mod.confidenceRank('provisional'), true);
  assert.equal(mod.confidenceRank('provisional') > mod.confidenceRank('inferred'), true);
  // An unknown or absent tier must not outrank a real one.
  assert.equal(mod.confidenceRank('nonsense'), mod.confidenceRank('inferred'));
  assert.equal(mod.confidenceRank(undefined), mod.confidenceRank('inferred'));
});

test('a record with no tier is provisional, not demoted to a guess', () => {
  // The two branches of normalizeConfidence must not answer the same thing. A record
  // written before the field existed, or by a caller that has not been taught the
  // tier yet, was recorded by takeover or adopt — never by backfill, which sets
  // `inferred`. Reading it as `inferred` would mark every such handover a guess and
  // let any tier-carrying record displace it; reading it as `confirmed` would claim
  // an approval nobody gave. Provisional is the only honest answer.
  assert.equal(mod.normalizeConfidence(undefined, false), 'provisional');
  assert.equal(mod.normalizeConfidence(undefined, true), 'inferred');
  assert.equal(mod.normalizeConfidence('nonsense', false), 'provisional');
  // A legacy record must therefore outrank a backfilled guess for the same pair.
  const legacy = { ...edge('a', 'b', at(1)) };
  delete legacy.confidence;
  const guess = { ...edge('a', 'b', at(3)), confidence: 'inferred', inferred: true };
  const kept = mod.dedupeEdges([mod.classifyEdge(legacy).edge, guess]);
  assert.equal(kept[0].confidence, 'provisional');
});

test('buildEdge records the confidence tier the caller names', () => {
  const e = mod.buildEdge({
    from: ep('a'), to: ep('b'), workRoot: null, repoRootOf: () => null,
    reason: 'manual', recordedBy: 'takeover', confidence: 'provisional', at: '1',
  });
  assert.equal(e.confidence, 'provisional');
  // `inferred` stays derivable for backward readability, but the tier is the truth.
  assert.equal(e.inferred, false);
  const g = mod.buildEdge({
    from: ep('a'), to: ep('b'), workRoot: null, repoRootOf: () => null,
    reason: 'rate_limit', recordedBy: 'backfill', confidence: 'inferred', at: '2',
  });
  assert.equal(g.confidence, 'inferred');
  assert.equal(g.inferred, true);
});

test('a measured handover is never displaced by a later-written guess', () => {
  // The defect this pins: dedupeEdges ranked by recordedAt alone, and
  // lineageBackfill stamps every guess with the moment --apply ran — so one
  // backfill permanently promoted guesses above measurements for the same pair.
  const measured = { ...edge('a', 'b', '2026-02-01T00:00:00.000Z'), confidence: 'confirmed' };
  const guess = { ...edge('a', 'b', '2026-08-01T00:00:00.000Z'), confidence: 'inferred', inferred: true };
  const kept = mod.dedupeEdges([measured, guess]);
  assert.equal(kept.length, 1);
  assert.equal(kept[0].confidence, 'confirmed', 'the measurement must survive, not the newer guess');
  // Positive control: between two records of the SAME tier, newer still wins, so
  // the tier rule did not simply freeze the first record it saw.
  const older = { ...edge('c', 'd', '2026-02-01T00:00:00.000Z'), confidence: 'confirmed' };
  const newer = { ...edge('c', 'd', '2026-08-01T00:00:00.000Z'), confidence: 'confirmed' };
  const kept2 = mod.dedupeEdges([older, newer]);
  assert.equal(kept2[0].recordedAt, '2026-08-01T00:00:00.000Z');
});

// --- S8: the labels document bounds its keys and does not lose a concurrent update ---

test('a label KEY is bounded, not only its value', () => {
  // Values went through boundLabel; keys were stored verbatim. writeLabels then
  // serialised whatever came back, so an oversized key round-tripped forever — and
  // once labels.json crossed MAX_RECORD_BYTES the reader refused it permanently:
  // every existing label silently vanished from every rendered chain, and `label`
  // failed with "move it aside and re-run" from then on.
  const huge = 'k'.repeat(5000);
  const norm = mod.normalizeLabels({ schemaVersion: 1, accounts: { [huge]: 'One' }, windows: {} });
  const keys = Object.keys(norm.accounts);
  assert.equal(keys.length, 1);
  assert.equal(keys[0].length <= 120, true, `a key must be bounded (got ${keys[0].length})`);
});

test('a labels file from another schema is reported, not silently emptied', () => {
  // normalizeLabels returns an EMPTY map on mismatch, and an empty map is what the
  // writer would then overwrite the user's real labels with. The reader's own
  // comment says so; nothing pinned it.
  const root = tmp();
  const p = mod.ledgerPaths(root);
  fs.mkdirSync(path.dirname(p.labels), { recursive: true });
  fs.writeFileSync(p.labels, JSON.stringify({ schemaVersion: 99, accounts: { a: 'One' }, windows: {} }));
  const r = mod.readLabels(p.labels);
  assert.equal(r.schemaMismatch, true);
  assert.equal(r.unreadable, false);
  assert.deepEqual(r.labels, mod.emptyLabels());
  fs.rmSync(root, { recursive: true, force: true });
});

test('a concurrent label update is merged, not silently lost', () => {
  // writeLabels landed atomically but replaced the WHOLE document, and the
  // read-modify-write around it was unguarded. Two windows labelling two different
  // accounts lost one of them — and a lost label is not a gap: the map still
  // resolves the OLD name and renders it with full confidence, while the process
  // that lost the update printed success.
  const root = tmp();
  const p = mod.ledgerPaths(root);
  mod.ensureLedgerDir(path.dirname(p.labels), root);
  // updateLabels owns the whole read-modify-write, so the mutation is applied to
  // whatever is on disk at write time rather than to a copy the caller read earlier.
  // Owning the cycle is also what makes a REMOVAL expressible: with a plain
  // "merge the caller's map", an absent key is indistinguishable from a cleared one.
  mod.updateLabels(p.labels, (cur) => { cur.accounts.b = 'theirs'; return cur; }, root);
  mod.updateLabels(p.labels, (cur) => { cur.accounts.a = 'mine'; return cur; }, root);
  const after = mod.readLabels(p.labels).labels;
  assert.equal(after.accounts.a, 'mine');
  assert.equal(after.accounts.b, 'theirs', 'the other writer\'s key must survive');
  // And a removal is expressible through the same seam.
  mod.updateLabels(p.labels, (cur) => { delete cur.accounts.b; return cur; }, root);
  assert.equal(mod.readLabels(p.labels).labels.accounts.b, undefined);
  fs.rmSync(root, { recursive: true, force: true });
});

// --- S7: the walk says WHY it stopped, and does not call a cut chain complete ---

test('a chain that returns to an earlier session is reported as revisited', () => {
  // The documented reset flow produces exactly this: adopt records A>B, then after
  // the reset the user resumes the original window and adopts back, recording B>A.
  // walkChain took A>B, filtered B>A through `seen`, and broke — with forks empty
  // and truncated false, indistinguishable from a chain that genuinely ended. The
  // renderer then printed CONTINUED IN B with no caveat while the newest edge in the
  // ledger said the work came back to A.
  const back = [
    { ...edge('a', 'b', at(1)), confidence: 'confirmed' },
    { ...edge('b', 'a', at(2)), confidence: 'confirmed' },
  ];
  const w = mod.walkChain('a', back);
  assert.equal(w.links.length, 1);
  assert.equal(w.revisited, true, 'the walk stopped because every successor was already seen — say so');
  // Positive control: a chain that really ends carries neither flag.
  const plain = mod.walkChain('a', [{ ...edge('a', 'b', at(1)), confidence: 'confirmed' }]);
  assert.equal(plain.revisited, false);
  assert.equal(plain.truncated, false);
});

test('truncated reports a successor that actually remains, not the link count', () => {
  // `links.length >= maxHops` is a false positive for a chain of exactly maxHops
  // links that ends naturally, and it also reports true for maxHops 0 with an empty
  // walk. Both made the renderer print "longer than shown" about a complete answer.
  const three = [
    { ...edge('a', 'b', at(1)), confidence: 'confirmed' },
    { ...edge('b', 'c', at(2)), confidence: 'confirmed' },
    { ...edge('c', 'd', at(3)), confidence: 'confirmed' },
  ];
  assert.equal(mod.walkChain('a', three, 3).truncated, false, 'exactly maxHops links, and nothing was cut');
  assert.equal(mod.walkChain('a', three, 2).truncated, true, 'a successor really does remain here');
  assert.equal(mod.walkChain('a', three, 0).truncated, true, 'a bound of zero cuts a chain that has successors');
});

// --- S6: the record lands exclusively, and the retry guards the name it claims ---

test('an existing destination record is never replaced', () => {
  // The retry loop caught EEXIST, but the only exclusive create was on the TEMP
  // name — pid plus 48 bits, which does not collide. The destination was produced
  // by renameSync, which replaces an existing target silently on POSIX and on
  // Windows, so the loop could not deliver the uniqueness its own terminal message
  // claims: "could not create a unique edge record". A deterministic name generator
  // is the seam that makes the claim testable at all; `now` is already a parameter
  // for the same reason.
  const root = tmp();
  const p = mod.ledgerPaths(root);
  mod.ensureLedgerDir(p.edges, root);
  const taken = path.join(p.edges, 'fixed.json');
  fs.writeFileSync(taken, '{"mine":true}');
  let calls = 0;
  const names = () => (calls++ === 0 ? 'fixed.json' : 'free.json');
  const written = mod.writeEdge(p.edges, edge('a', 'b', '2026-01-01T00:00:00.000Z'), 1, root, names);
  assert.equal(path.basename(written), 'free.json', 'the collision must be retried onto a fresh name');
  assert.equal(fs.readFileSync(taken, 'utf8'), '{"mine":true}', 'the pre-existing record must survive untouched');
  fs.rmSync(root, { recursive: true, force: true });
});

test('a name that never comes free exhausts the retry rather than clobbering', () => {
  const root = tmp();
  const p = mod.ledgerPaths(root);
  mod.ensureLedgerDir(p.edges, root);
  fs.writeFileSync(path.join(p.edges, 'always.json'), '{"mine":true}');
  assert.throws(
    () => mod.writeEdge(p.edges, edge('a', 'b', '2026-01-01T00:00:00.000Z'), 1, root, () => 'always.json'),
    /could not create a unique edge record/,
  );
  // And the attempts must not litter: every temp is cleaned up on the failure path.
  const strays = fs.readdirSync(p.edges).filter((n) => n.startsWith('.edge-'));
  assert.deepEqual(strays, [], 'a failed write must leave no temp file behind');
  fs.rmSync(root, { recursive: true, force: true });
});

// --- S5: the directory guard bounds what it inspects, and proves the mode it sets ---

test('a symlinked config root does not refuse every write', { skip: process.platform === 'win32' }, () => {
  // The ancestor walk pushed each component into the checked set BEFORE testing the
  // ceiling, so the config root itself was lstat'd and refused when it was a symlink
  // — which is the ordinary shape under a dotfile manager (stow, chezmoi). Every
  // takeover, adopt and label then failed, while the read side mapped the missing
  // directory to "No handover has been recorded yet": the one wrong answer this
  // feature exists to prevent. The ceiling is the root the CALLER named, i.e. the
  // trust anchor, not an attacker-planted leaf.
  const root = tmp();
  const real = path.join(root, 'real-config');
  fs.mkdirSync(real);
  const link = path.join(root, 'cfg');
  fs.symlinkSync(real, link);
  const p = mod.ledgerPaths(link);
  assert.doesNotThrow(() => mod.ensureLedgerDir(p.edges, link), 'a symlinked ceiling is the user\'s own choice');
  assert.equal(fs.existsSync(p.edges), true);
  fs.rmSync(root, { recursive: true, force: true });
});

test('a path survives as the path it was, or not at all', () => {
  // boundText treats its input as PROSE: it collapses whitespace RUNS to a single
  // space and ellipsizes past the cap. Applied to a path that silently produced a
  // DIFFERENT directory that still looked valid — `/Users/me/My  Projects` was
  // persisted as `/Users/me/My Projects` — and a long path became a truncation
  // that still parsed. A truncated path is a WRONG answer; an absent one is a
  // missing answer a reader can act on. Both properties were unpinned: the change
  // that introduced boundPath broke no existing check.
  const spaced = '/Users/me/My  Projects/api';
  assert.equal(mod.makeEndpoint({ worktree: spaced }).worktree, spaced,
    'a doubled space is part of the path, not prose to be tidied');
  assert.equal(mod.makeEndpoint({ worktree: '/x'.repeat(4000) }).worktree, null,
    'past the cap the answer is absent, never a truncation that still parses');
  assert.equal(mod.normalizeRepo({ name: 'r', root: spaced }).root, spaced,
    'the repo root is a path too');
});

test('an omitted provenance marker ranks as a GUESS, never above one', () => {
  // The store is machine-wide and writable by every local process. Nothing here can
  // authenticate provenance — a planted record can still claim 'confirmed' — but an
  // OMITTED marker used to answer 'provisional', which outranks 'inferred', so the
  // cheapest possible forgery was to leave the field out. A record must SAY what it
  // is to be ranked above a guess.
  assert.equal(mod.normalizeConfidence(undefined, undefined), 'inferred',
    'said nothing must not outrank a record that honestly declared itself inferred');
  assert.equal(mod.normalizeConfidence(undefined, false), 'provisional',
    'an explicit legacy inferred:false still gets the default');
  assert.equal(mod.normalizeConfidence(undefined, true), 'inferred');
  assert.equal(mod.normalizeConfidence('confirmed', undefined), 'confirmed',
    'a known value still wins over the fallback');
});

test('the READ and DELETE sides accept the same symlinked ceiling the write side does', { skip: process.platform === 'win32' }, () => {
  // The write side was relaxed at the ceiling deliberately (the case above). The
  // round-2 ancestor guard judged the ceiling instead, so on the ordinary
  // dotfile-manager layout records kept being WRITTEN while readEdges answered
  // ESYMLINK and removeEdgeFiles refused every name — `lineage --forget`, the only
  // way a machine-wide record ever leaves, permanently unavailable exactly where
  // records keep arriving. The existing read-side case supplies a REAL directory as
  // the ceiling, so it could not see this.
  const root = tmp();
  const real = path.join(root, 'real-config');
  fs.mkdirSync(real);
  const link = path.join(root, 'cfg');
  fs.symlinkSync(real, link);
  const p2 = mod.ledgerPaths(link);
  mod.ensureLedgerDir(p2.edges, link);
  assert.equal(mod.ledgerPathUnlinked(p2.edges, link), true,
    'the ceiling is a BOUND on the walk, not a candidate for it');
  const written = mod.writeEdge(p2.edges, {
    schemaVersion: 1, from: { sessionId: 'aaaaaaaa' }, to: { sessionId: 'bbbbbbbb' },
    repo: { name: 'r', root: '/r' }, reason: 'manual', inferred: false,
    recordedAt: '2026-01-01T00:00:00.000Z', recordedBy: 'adopt',
  }, Date.parse('2026-01-01T00:00:00.000Z'), link);
  const read = mod.readEdges(p2.edges, link);
  assert.equal(read.directoryError, null, 'a tree the write side accepts must be readable');
  assert.equal(read.edges.length, 1);
  const gone = mod.removeEdgeFiles(p2.edges, [path.basename(written)], link);
  assert.equal(gone.removed.length, 1, 'and the retraction channel must work there too');
  assert.deepEqual(gone.failed, []);
  fs.rmSync(root, { recursive: true, force: true });
});

test('the READ side still refuses a symlinked component below a symlinked ceiling', { skip: process.platform === 'win32' }, () => {
  // The discriminator for the case above: relaxing the ceiling must not relax the
  // walk, or the fix is indistinguishable from deleting the guard.
  const root = tmp();
  const real = path.join(root, 'real-config');
  fs.mkdirSync(real);
  const link = path.join(root, 'cfg');
  fs.symlinkSync(real, link);
  const p2 = mod.ledgerPaths(link);
  fs.mkdirSync(path.dirname(p2.edges), { recursive: true });
  const elsewhere = path.join(root, 'elsewhere');
  fs.mkdirSync(elsewhere);
  fs.symlinkSync(elsewhere, p2.edges);
  assert.equal(mod.ledgerPathUnlinked(p2.edges, link), false);
  assert.equal(mod.readEdges(p2.edges, link).directoryError, 'ESYMLINK');
  fs.rmSync(root, { recursive: true, force: true });
});

test('readLabels refuses a symlinked ancestor, as its own writer already does', { skip: process.platform === 'win32' }, () => {
  // The THIRD reader of this store. readEdges and removeEdgeFiles took the ceiling
  // in round 2 and this one did not, so read and write disagreed about the same
  // tree: writeLabels refuses a symlinked ancestor through ensureLedgerDir, while
  // readLabels resolved straight through it. readBoundedFile's O_NOFOLLOW declines
  // the FINAL component only, which is the same gap the ancestor walk exists for.
  const root = tmp();
  const p2 = mod.ledgerPaths(root);
  fs.mkdirSync(path.dirname(path.dirname(p2.labels)), { recursive: true });
  const elsewhere = path.join(root, 'elsewhere');
  fs.mkdirSync(elsewhere);
  fs.writeFileSync(path.join(elsewhere, 'labels.json'), JSON.stringify({ schemaVersion: 1, accounts: { a: 'planted' }, windows: {} }));
  fs.symlinkSync(elsewhere, path.dirname(p2.labels));
  const got = mod.readLabels(p2.labels, root);
  assert.equal(got.unreadable, true, 'a label document reached through a symlinked ancestor is refused, not rendered');
  assert.deepEqual(Object.keys(got.labels.accounts), [], 'and nothing from it reaches a caller');
  fs.rmSync(root, { recursive: true, force: true });
});

test('updateLabels threads its ceiling into its own read, not only into the write', { skip: process.platform === 'win32' }, () => {
  // It held `stopAt`, passed it to writeLabels and omitted it from readLabels. Since
  // readLabels' guard is conditional, that omission performed NO ancestor check — so
  // the read half of one read-modify-write resolved through a symlinked `v1/` that
  // its own write half refuses. The planted document must never reach `mutate`.
  const root = tmp();
  const p2 = mod.ledgerPaths(root);
  fs.mkdirSync(path.dirname(path.dirname(p2.labels)), { recursive: true });
  const elsewhere = path.join(root, 'elsewhere');
  fs.mkdirSync(elsewhere);
  fs.writeFileSync(path.join(elsewhere, 'labels.json'), JSON.stringify({ schemaVersion: 1, accounts: { planted: 'x' }, windows: {} }));
  fs.symlinkSync(elsewhere, path.dirname(p2.labels));
  let sawPlanted = false;
  assert.throws(() => mod.updateLabels(p2.labels, (cur) => {
    if (Object.prototype.hasOwnProperty.call(cur.accounts, 'planted')) sawPlanted = true;
    return cur;
  }, root), 'the write half already refused this tree; the read half must not reach it either');
  assert.equal(sawPlanted, false, 'nothing from outside the ceiling reaches the mutator');
  fs.rmSync(root, { recursive: true, force: true });
});

test('otherSchemaLedgers refuses a symlinked base rather than enumerating through it', { skip: process.platform === 'win32' }, () => {
  // It readdirSync's <root>/zensu/session-lineage with no guard, and readdirSync
  // follows a symlinked final component. Read-only, but it renders a path and a
  // count as "records this machine already holds".
  const root = tmp();
  const elsewhere = path.join(root, 'elsewhere');
  fs.mkdirSync(path.join(elsewhere, 'v0', 'edges'), { recursive: true });
  fs.writeFileSync(path.join(elsewhere, 'v0', 'edges', '1-aaaaaaaa.json'), '{}');
  fs.mkdirSync(path.join(root, 'zensu'), { recursive: true });
  fs.symlinkSync(elsewhere, path.join(root, 'zensu', 'session-lineage'));
  assert.deepEqual(mod.otherSchemaLedgers(root), [],
    'a planted directory must not be reported as a migration this machine holds');
  fs.rmSync(root, { recursive: true, force: true });
});

test('a symlinked component BELOW the ceiling is still refused', { skip: process.platform === 'win32' }, () => {
  // The discriminating half: relaxing the ceiling must not relax the walk. Without
  // this the fix above is indistinguishable from deleting the guard.
  const root = tmp();
  const cfg = path.join(root, 'cfg');
  fs.mkdirSync(path.join(cfg, 'zensu'), { recursive: true });
  const elsewhere = path.join(root, 'elsewhere');
  fs.mkdirSync(elsewhere);
  // Plant the link at the `session-lineage` level, strictly below the named ceiling.
  fs.symlinkSync(elsewhere, path.join(cfg, 'zensu', 'session-lineage'));
  const p = mod.ledgerPaths(cfg);
  assert.throws(() => mod.ensureLedgerDir(p.edges, cfg), /symlinked ledger path/);
  fs.rmSync(root, { recursive: true, force: true });
});

test('a component the walk cannot inspect is refused, not skipped as if absent', { skip: process.platform === 'win32' || process.getuid() === 0 }, () => {
  // `catch { continue; }` treated EVERY lstat failure as "not there yet". ENOENT
  // genuinely is; EACCES and ELOOP mean the check did not happen, and the code then
  // proceeded to mkdir having proven nothing. The module argues exactly this
  // distinction for its own refusal table.
  const root = tmp();
  const cfg = path.join(root, 'cfg');
  fs.mkdirSync(path.join(cfg, 'zensu'), { recursive: true });
  fs.chmodSync(path.join(cfg, 'zensu'), 0o000);
  const p = mod.ledgerPaths(cfg);
  try {
    assert.throws(() => mod.ensureLedgerDir(p.edges, cfg), /could not check ledger path/);
  } finally {
    fs.chmodSync(path.join(cfg, 'zensu'), 0o700);
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('the mode the guard sets is verified, not assumed', { skip: process.platform === 'win32' }, () => {
  // chmodSync SUCCEEDING is not evidence the mode took: on a filesystem that ignores
  // POSIX modes the call is a silent no-op and so is `mode: 0o600` on the records.
  // A pre-existing group-readable directory is the observable case here.
  const root = tmp();
  const p = mod.ledgerPaths(root);
  fs.mkdirSync(p.edges, { recursive: true, mode: 0o755 });
  fs.chmodSync(p.edges, 0o755);
  mod.ensureLedgerDir(p.edges, root);
  const mode = fs.lstatSync(p.edges).mode & 0o777;
  assert.equal(mode & 0o077, 0, `the ledger directory must not stay group/other-readable (got ${mode.toString(8)})`);
  fs.rmSync(root, { recursive: true, force: true });
});

// --- S4: a refusal names its own cause, and neither the open nor the count is unbounded ---

const writeEdgeFile = (dir, name, obj) => {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, name), typeof obj === 'string' ? obj : JSON.stringify(obj));
};

test('each refusal cause is reported under its own name, not collapsed into one', () => {
  // The module argues for exactly this three lines above its own refusal table:
  // a record it cannot read for one reason must not be reported as another. Five
  // distinct causes reached the reader as `unreadable`, so a user who chmod'd the
  // ledger, one with a corrupt record and one with a planted directory all saw the
  // same sentence and could not tell which they had.
  const root = tmp();
  const p = mod.ledgerPaths(root);
  writeEdgeFile(p.edges, '1-ok.json', edge('a', 'b', '2026-01-01T00:00:00.000Z'));
  writeEdgeFile(p.edges, '2-corrupt.json', 'not json at all');
  writeEdgeFile(p.edges, '3-oversize.json', { pad: 'x'.repeat(300 * 1024) });
  fs.mkdirSync(path.join(p.edges, '4-dir.json'));
  const out = mod.readEdges(p.edges);
  const reasons = Object.fromEntries(out.refused.map((r) => [r.file, r.reason]));
  assert.equal(out.edges.length, 1, 'the one good record still reads');
  assert.equal(reasons['2-corrupt.json'], mod.EDGE_REFUSALS.CORRUPT);
  assert.equal(reasons['3-oversize.json'], mod.EDGE_REFUSALS.OVERSIZE);
  assert.equal(reasons['4-dir.json'], mod.EDGE_REFUSALS.NOT_A_FILE);
  fs.rmSync(root, { recursive: true, force: true });
});

test('the record COUNT is bounded, and the truncation is reported rather than silent', () => {
  // Each record was capped at 256 KiB; nothing capped how many were enumerated,
  // read and parsed. In a directory every session on the machine can write, that
  // is an unbounded multiplier on a bounded quantity.
  const root = tmp();
  const p = mod.ledgerPaths(root);
  for (let i = 0; i < mod.MAX_EDGE_RECORDS + 5; i += 1) {
    writeEdgeFile(p.edges, `${String(i).padStart(6, '0')}-e.json`, edge(`s${i}`, `t${i}`, '2026-01-01T00:00:00.000Z'));
  }
  const out = mod.readEdges(p.edges);
  assert.equal(out.edges.length <= mod.MAX_EDGE_RECORDS, true, 'the cap must actually bind');
  assert.equal(out.truncated, true, 'a bounded read must say so — a silent cap reads as a complete answer');
  fs.rmSync(root, { recursive: true, force: true });
});

// A hang is the failure mode under test, so this case carries its own deadline —
// without it a missing O_NONBLOCK stalls the whole runner instead of failing.
test('the open cannot block on a non-regular entry', { skip: process.platform === 'win32' }, () => {
  // O_RDONLY on a FIFO blocks until a writer appears, and O_NOFOLLOW does not
  // change that. readEdges reaches the open for every *.json entry, so one planted
  // FIFO wedged every lineage, --where, --diagnose, instances and takeover on the
  // machine, with no timeout above it. The fstat/isFile checks cannot protect the
  // open itself — they run after it.
  const root = tmp();
  const p = mod.ledgerPaths(root);
  fs.mkdirSync(p.edges, { recursive: true });
  writeEdgeFile(p.edges, '1-ok.json', edge('a', 'b', '2026-01-01T00:00:00.000Z'));
  execFileSync('mkfifo', [path.join(p.edges, '2-fifo.json')]);
  // No writer will ever open the other end. `openSync` blocks the EVENT LOOP, so
  // node:test's own timeout could never fire — the deadline has to come from outside
  // the blocked process. The read therefore runs in a child that execFileSync kills:
  // a killed child is the RED signal, a clean exit the GREEN one.
  const modUrl = new URL('../../skills/session-trail/scripts/session-lineage-v1.mjs', import.meta.url).href;
  const probe = `import(${JSON.stringify(modUrl)}).then((m) => {`
    + `const o = m.readEdges(${JSON.stringify(p.edges)});`
    + `const f = o.refused.find((r) => r.file === '2-fifo.json');`
    + `process.stdout.write(JSON.stringify({ edges: o.edges.length, reason: f && f.reason }));`
    + `});`;
  let raw;
  try {
    raw = execFileSync(process.execPath, ['--input-type=module', '-e', probe], { timeout: 8000, encoding: 'utf8' });
  } catch (e) {
    assert.fail(`the read did not return within 8s — the open blocked on the fifo (${e.signal || e.code})`);
  }
  const out = JSON.parse(raw);
  assert.equal(out.edges, 1, 'the ordinary record beside the fifo still reads');
  assert.equal(out.reason, mod.EDGE_REFUSALS.NOT_A_FILE);
  fs.rmSync(root, { recursive: true, force: true });
});

// --- S3: the persisted endpoint keeps only what a reader actually consumes ---

test('the persisted endpoint carries neither title nor cwd', () => {
  // Both were written on every endpoint of every edge and read by no renderer:
  // printChain, lineage --where and the instances lineage column between them read
  // sessionId, worktree, branch, appPid and pid. They were also the two most
  // sensitive fields — a session title summarises what someone was working on and
  // can name a client; cwd is finer-grained than worktree. Collection without a
  // purpose, in a store that is durable, machine-wide and outside every repository.
  assert.equal(mod.ENDPOINT_KEYS.includes('title'), false);
  assert.equal(mod.ENDPOINT_KEYS.includes('cwd'), false);
  const e = mod.makeEndpoint({ sessionId: 's', title: 'Acme migration', cwd: '/clients/acme/api' });
  assert.equal(e.title, undefined);
  assert.equal(e.cwd, undefined);
  // The fields a renderer DOES read must survive, or this becomes a different bug.
  const full = mod.makeEndpoint({ sessionId: 's', worktree: '/w', branch: 'b', appPid: 7, pid: 8, accountUuid: 'u' });
  assert.deepEqual(mod.ENDPOINT_KEYS, ['sessionId', 'accountUuid', 'appPid', 'pid', 'worktree', 'branch']);
  assert.equal(full.worktree, '/w');
  assert.equal(full.branch, 'b');
  assert.equal(full.appPid, 7);
});

// --- S2: the accepted record is a CLOSED shape, and the field that orders it is judged ---

test('an unknown key from an untrusted record does not survive classification', () => {
  // The ledger directory is writable by every session on this machine, and the
  // accepted edge is emitted verbatim into `lineage --where --json`'s links. A
  // `...raw` spread carried any key, unbounded up to the record cap, into a
  // payload a model reads.
  const raw = { ...edge('a', 'b', '2026-01-01T00:00:00.000Z'), smuggled: 'x'.repeat(400), toolVersion: '9.9.9' };
  const r = mod.classifyEdge(raw);
  assert.equal(r.ok, true);
  assert.equal(r.edge.smuggled, undefined, 'an unknown key must not survive');
  assert.equal(r.edge.toolVersion, undefined);
  // The whole key set, not one name: a rule about the shape cannot be pinned by
  // naming a single field that happens to be absent.
  assert.deepEqual(Object.keys(r.edge), [
    'schemaVersion', 'from', 'to', 'repo', 'reason', 'confidence', 'inferred', 'recordedAt', 'recordedBy',
  ]);
});

test('a non-boolean inferred is coerced, never carried through as truthy', () => {
  const raw = { ...edge('a', 'b', '2026-01-01T00:00:00.000Z'), inferred: 'no', confidence: 'confirmed' };
  const r = mod.classifyEdge(raw);
  assert.equal(r.ok, true);
  assert.equal(r.edge.inferred, false, '"no" is truthy — coercion must not read it as a guess');
});

test('an unparseable recordedAt is refused, because it decides the order of every chain', () => {
  // It selects the dedupe survivor, the branch the walk prefers, and the --where
  // answer. One record carrying "9999" sorted after every ISO stamp forever.
  const bad = { ...edge('a', 'b', 'not-a-date') };
  const r = mod.classifyEdge(bad);
  assert.equal(r.ok, false);
  assert.equal(r.reason, mod.EDGE_REFUSALS.MALFORMED);
  // Positive control: a real ISO stamp still classifies.
  assert.equal(mod.classifyEdge(edge('a', 'b', '2026-01-01T00:00:00.000Z')).ok, true);
});

test('a self-referential edge is refused rather than counted with no chain to show', () => {
  // chainRoots promotes it to a root, walkChain filters it by `seen`, and the
  // renderer skips an empty link list — so it rendered as a handover count above
  // nothing at all, the exact shape chainRoots exists to prevent.
  const r = mod.classifyEdge(edge('a', 'a', '2026-01-01T00:00:00.000Z'));
  assert.equal(r.ok, false);
  assert.equal(r.reason, mod.EDGE_REFUSALS.MALFORMED);
});

test('the dedupe key cannot be spelled by two different pairs', () => {
  // `>` is not in boundText's stripped class, so "a>b" is a legal sessionId and
  // the old `${from}>${to}` key collapsed two unrelated edges into one.
  const one = { ...edge('a>b', 'c', '2026-01-01T00:00:00.000Z'), confidence: 'confirmed' };
  const two = { ...edge('a', 'b>c', '2026-01-02T00:00:00.000Z'), confidence: 'confirmed' };
  assert.equal(mod.dedupeEdges([one, two]).length, 2, 'two distinct pairs must stay two records');
});

test('the walk prefers a measured successor over a newer guessed one', () => {
  const chain = [
    { ...edge('a', 'b', '2026-02-01T00:00:00.000Z'), confidence: 'confirmed' },
    { ...edge('a', 'z', '2026-08-01T00:00:00.000Z'), confidence: 'inferred', inferred: true },
  ];
  const w = mod.walkChain('a', chain);
  assert.equal(w.links[0].to.sessionId, 'b', 'a guess must not headline the chain');
  assert.equal(w.forks.length, 1, 'the guessed branch is still reported, never dropped');
  assert.deepEqual(w.forks[0].alsoTo, ['z']);
});

// --- S11: the removal path, whose refusals no bash check can reach -----------
// test-session-trail-lineage.sh proves `lineage --forget --apply` removes the
// right records and leaves the rest. It cannot reach the branches below: every
// name it can produce comes from readdirSync and is a well-formed single
// component by construction. This is the one layer that can hand the function a
// name no directory listing would ever yield.

test('a name that is not a single path component is refused, never resolved', () => {
  assert.equal(mod.isEdgeFileName('a.json'), true);
  assert.equal(mod.isEdgeFileName('../a.json'), false, 'a traversal must not normalise into an unlink outside the ledger');
  assert.equal(mod.isEdgeFileName('sub/a.json'), false);
  assert.equal(mod.isEdgeFileName('.hidden.json'), false, 'the reader skips dot names, so the removal must not claim one');
  assert.equal(mod.isEdgeFileName('a.txt'), false);
  assert.equal(mod.isEdgeFileName(''), false);
  assert.equal(mod.isEdgeFileName(null), false);
});

test('a refused name is reported as kept, and the record beside it still goes', () => {
  const root = tmp();
  const dir = path.join(root, 'edges');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, '1-aaaaaaaaaaaaaaaa.json'), '{}');
  const outside = path.join(root, 'outside.json');
  fs.writeFileSync(outside, '{}');
  const r = mod.removeEdgeFiles(dir, ['../outside.json', '1-aaaaaaaaaaaaaaaa.json']);
  assert.deepEqual(r.removed, ['1-aaaaaaaaaaaaaaaa.json'], 'one bad name must not cost the batch');
  assert.equal(r.failed.length, 1);
  assert.equal(r.failed[0].reason, 'name-refused');
  assert.equal(fs.existsSync(outside), true, 'a traversal name must leave its target standing');
  assert.equal(fs.existsSync(path.join(dir, '1-aaaaaaaaaaaaaaaa.json')), false);
});

test('a record that is already gone is reported, not thrown', () => {
  const dir = tmp();
  fs.writeFileSync(path.join(dir, '2-bbbbbbbbbbbbbbbb.json'), '{}');
  const r = mod.removeEdgeFiles(dir, ['1-aaaaaaaaaaaaaaaa.json', '2-bbbbbbbbbbbbbbbb.json']);
  assert.deepEqual(r.removed, ['2-bbbbbbbbbbbbbbbb.json']);
  assert.equal(r.failed[0].reason, 'ENOENT');
});

test('a directory sitting in the ledger is refused, not removed', () => {
  const dir = tmp();
  fs.mkdirSync(path.join(dir, 'nested.json'));
  const r = mod.removeEdgeFiles(dir, ['nested.json']);
  assert.deepEqual(r.removed, []);
  assert.equal(r.failed[0].reason, 'not-a-file');
});

test('a symlinked record is refused rather than unlinked', { skip: process.platform === 'win32' ? 'symlink creation needs privileges on win32' : false }, () => {
  const root = tmp();
  const dir = path.join(root, 'edges');
  fs.mkdirSync(dir, { recursive: true });
  const real = path.join(root, 'real.json');
  fs.writeFileSync(real, '{}');
  fs.symlinkSync(real, path.join(dir, 'link.json'));
  // Unlinking the link would report a record destroyed while the file it names
  // survives — and readBoundedFile opens O_NOFOLLOW, so it was never readable here.
  const r = mod.removeEdgeFiles(dir, ['link.json']);
  assert.deepEqual(r.removed, []);
  assert.equal(r.failed[0].reason, 'not-a-file');
  assert.equal(fs.existsSync(real), true);
});

test('the walk takes ONE source of successors, never a pair that can disagree', () => {
  // R10 added a fourth parameter so a shared index could be threaded through, and
  // left the third-party `edges` argument in place beside it. Once an index was
  // supplied `edges` was DEAD — two parameters describing one thing, and the walk
  // silently followed whichever one the caller got right. `chainRoots` had the same
  // pair, where the two are not even interchangeable: it iterates `edges` to
  // discover roots and hands the index to the walk, so a disagreeing pair yields
  // roots from one set and chains from the other.
  const real = [edge('a', 'b', at(1))];
  const decoy = [edge('a', 'c', at(1))];
  const w = mod.walkChain('a', real, 64, mod.indexBySource(decoy));
  assert.deepEqual(w.links.map((l) => l.to.sessionId), ['b'],
    'a fourth argument must not be able to redirect the walk away from the edges it was given');
  // And the index may be handed in AS the source, which is the whole reason that
  // parameter existed: the caller still avoids one rebuild per root.
  const viaIndex = mod.walkChain('a', mod.indexBySource(real));
  assert.deepEqual(viaIndex.links.map((l) => l.to.sessionId), ['b'],
    'a prebuilt index is a valid edge source');
  assert.deepEqual(mod.chainRoots(mod.indexBySource(real) instanceof Map ? real : real), ['a'],
    'root discovery is unchanged');
});

test('the root decision and the rendered chain are ONE traversal, not two', () => {
  // `chainRoots` walked every root to decide coverage and threw the walk away, so
  // both renderers re-walked the same edges from the same roots. The wasted pass is
  // the small half; the shape is the half that bites, because the DECISION and the
  // RENDERED chain were independent traversals of the same data and nothing in
  // either could notice them disagreeing.
  const edges = [edge('a', 'b', at(1)), edge('b', 'c', at(2)), edge('x', 'y', at(3))];
  const { roots, walks } = mod.chainWalks(edges);
  assert.deepEqual(roots, ['a', 'x'], 'root discovery is unchanged');
  // Every root carries a walk. The renderers destructure `walks.get(root)` directly,
  // so a root without one is a TypeError mid-render rather than a missing chain.
  for (const r of roots) assert.ok(walks.get(r), `root ${r} must carry the walk it was decided by`);
  assert.deepEqual([...walks.keys()].sort(), [...roots].sort(),
    'the map holds exactly the roots, so a stale entry cannot render as a chain');
  for (const r of roots) {
    assert.deepEqual(walks.get(r).links.map((l) => l.to.sessionId),
      mod.walkChain(r, edges).links.map((l) => l.to.sessionId),
      'the returned walk is the walk a caller would have repeated');
  }
  // A cycle yields no roots in the first pass, so every promoted root must also
  // carry a walk — that arm builds its roots in a different loop.
  const cyc = [edge('p', 'q', at(1)), edge('q', 'p', at(2))];
  const cw = mod.chainWalks(cyc);
  assert.ok(cw.roots.length > 0, 'a cycle still renders as something rather than as silence');
  for (const r of cw.roots) assert.ok(cw.walks.get(r), 'a promoted root carries its walk too');
  // And the array-only reduction keeps working for callers that only need it.
  assert.deepEqual(mod.chainRoots(edges), roots);
});

test('the record cap bounds the WORK, not only the count', () => {
  // MAX_EDGE_RECORDS caps how many records are read; it did not cap what is done
  // with them. `chainRoots` tested root membership with a linear `includes` inside
  // a loop over every edge and re-walked each root, and `walkChain` rebuilt its
  // adjacency map on every call — so a ledger any session on the machine can fill
  // to the cap turned `lineage` into a machine-wide CPU sink. Measured before the
  // fix on this host: n=2000 took 315 ms and n=5000 took 1669 ms, a 5.3x rise for
  // 2.5x the input, which puts the cap's own 20 000 at roughly 27 s.
  //
  // Driven in a CHILD with a deadline for the same reason the O_NONBLOCK case is:
  // the failure mode is "takes far too long", and a synchronous call cannot be
  // interrupted by the runner's own timeout. The margin is deliberately wide —
  // roughly 200x after the fix, and the pre-fix figure is ~2.7x the deadline — so
  // a loaded CI box moves the number without flipping the verdict.
  const src = `
    const mod = await import(${JSON.stringify(new URL('../../skills/session-trail/scripts/session-lineage-v1.mjs', import.meta.url).href)});
    const edges = [];
    for (let i = 0; i < mod.MAX_EDGE_RECORDS; i += 1) {
      edges.push({ from: { sessionId: 'a' + i }, to: { sessionId: 'b' + i },
        recordedAt: '2026-01-01T00:00:00.000Z', confidence: 'confirmed' });
    }
    const roots = mod.chainRoots(edges);
    if (roots.length !== mod.MAX_EDGE_RECORDS) throw new Error('roots=' + roots.length);
    process.stdout.write('ok');
  `;
  const out = execFileSync(process.execPath, ['--input-type=module', '-e', src], {
    encoding: 'utf8', timeout: 10000, stdio: ['ignore', 'pipe', 'pipe'],
  });
  assert.equal(out, 'ok', 'every disjoint pair is still its own root — the bound must not change the answer');
});

test('an unreadable record is refused under its OWN name, not collapsed into another', { skip: process.platform === 'win32' ? 'file modes are not enforced this way on win32' : (process.getuid() === 0 ? 'root reads through a 000 mode' : false) }, () => {
  // The refusal table's whole argument is that a record it cannot read for one
  // reason must not be reported as another — and UNREADABLE was the one member
  // asserted nowhere on either layer, which a review found. `readBoundedFile`
  // returns it from the open-failure and mid-read-failure paths.
  const root = tmp();
  const p = mod.ledgerPaths(root);
  mod.writeEdge(p.edges, edge('a', 'b', '2026-01-01T00:00:00.000Z'), 1, root);
  const denied = path.join(p.edges, '9-denied.json');
  fs.writeFileSync(denied, '{}');
  fs.chmodSync(denied, 0o000);
  const out = mod.readEdges(p.edges);
  const reasons = Object.fromEntries(out.refused.map((r) => [r.file, r.reason]));
  assert.equal(reasons['9-denied.json'], mod.EDGE_REFUSALS.UNREADABLE);
  assert.equal(out.edges.length, 1, 'the readable record still reads');
  fs.chmodSync(denied, 0o600);
  fs.rmSync(root, { recursive: true, force: true });
});

test('a labels update that cannot land is reported, never silently dropped', () => {
  // The retry and its exhaustion are the mechanism the whole lost-update fix rests
  // on, and neither branch had a test on either layer. `attempts` is already a
  // parameter, so the terminal throw is reachable without touching production code.
  const root = tmp();
  const p = mod.ledgerPaths(root);
  mod.writeLabels(p.labels, mod.emptyLabels(), root);
  let landed = 0;
  assert.throws(() => mod.updateLabels(p.labels, (cur) => {
    // Another writer lands between the read and the write, every time.
    const other = mod.emptyLabels();
    other.accounts.theirs = `v${landed += 1}`;
    mod.writeLabels(p.labels, other, root);
    cur.accounts.mine = 'x';
    return cur;
  }, root, 2), /could not land a labels update in 2 attempts/);
  // And the loser's own key is NOT on disk: reporting the failure is the point,
  // but silently having written it anyway would be worse than either outcome.
  assert.equal(mod.readLabels(p.labels).labels.accounts.mine, undefined);
  assert.equal(landed, 2, 'both attempts ran, so the bound is what stopped it');
  fs.rmSync(root, { recursive: true, force: true });
});

test('a labels update redoes itself on the winner copy rather than overwriting it', () => {
  const root = tmp();
  const p = mod.ledgerPaths(root);
  mod.writeLabels(p.labels, mod.emptyLabels(), root);
  let interfered = false;
  const next = mod.updateLabels(p.labels, (cur) => {
    if (!interfered) {
      interfered = true;
      const other = mod.emptyLabels();
      other.accounts.theirs = 'landed first';
      mod.writeLabels(p.labels, other, root);
    }
    cur.accounts.mine = 'landed second';
    return cur;
  }, root, 5);
  // The redo is what makes this a merge rather than a race: both keys survive.
  assert.equal(next.accounts.theirs, 'landed first');
  assert.equal(next.accounts.mine, 'landed second');
  fs.rmSync(root, { recursive: true, force: true });
});

test('a symlinked ANCESTOR is refused on the read and delete paths, not only the leaf', { skip: process.platform === 'win32' ? 'symlink creation needs privileges on win32' : false }, () => {
  // The leaf check was not enough, and the module already argues why one level up
  // is different: `lstat` declines to follow only the FINAL component. With
  // `session-lineage` a symlink, `readEdges` reported no directoryError at all and
  // `path.join(edgesDir, name)` in `removeEdgeFiles` resolved straight through it —
  // so `lineage --forget --apply` unlinked a file OUTSIDE the ledger directory.
  // Reproduced end-to-end through the CLI before this guard existed.
  const root = tmp();
  const outside = path.join(root, 'outside');
  fs.mkdirSync(path.join(outside, `v${mod.LEDGER_SCHEMA_VERSION}`, 'edges'), { recursive: true });
  const victim = path.join(outside, `v${mod.LEDGER_SCHEMA_VERSION}`, 'edges', '1-aaaaaaaaaaaaaaaa.json');
  fs.writeFileSync(victim, JSON.stringify(edge('a', 'b', '2026-01-01T00:00:00.000Z')));
  fs.mkdirSync(path.join(root, 'zensu'), { recursive: true });
  fs.symlinkSync(outside, path.join(root, 'zensu', 'session-lineage'));
  const p = mod.ledgerPaths(root);

  const read = mod.readEdges(p.edges, root);
  assert.equal(read.directoryError, 'ESYMLINK', 'the read must refuse a symlinked ancestor, not just a symlinked leaf');
  assert.equal(read.edges.length, 0);

  const gone = mod.removeEdgeFiles(p.edges, ['1-aaaaaaaaaaaaaaaa.json'], root);
  assert.deepEqual(gone.removed, [], 'nothing may be unlinked through a symlinked ancestor');
  assert.equal(fs.existsSync(victim), true, 'the file outside the ledger must still be there');
  fs.rmSync(root, { recursive: true, force: true });
});

test('an ordinary ledger still reads and removes with the ceiling supplied', () => {
  // The control the case above needs: a guard that refused everything would satisfy
  // both of its assertions and make the store unusable.
  const root = tmp();
  const p = mod.ledgerPaths(root);
  mod.writeEdge(p.edges, edge('a', 'b', '2026-01-01T00:00:00.000Z'), 1, root);
  const read = mod.readEdges(p.edges, root);
  assert.equal(read.directoryError, null);
  assert.equal(read.edges.length, 1);
  const gone = mod.removeEdgeFiles(p.edges, [read.edges[0].file], root);
  assert.deepEqual(gone.failed, []);
  assert.equal(gone.removed.length, 1);
  fs.rmSync(root, { recursive: true, force: true });
});

// --- S21: a store the schema moved out from under ---------------------------

test('a foreign schema directory is reported with the relation, not just found', () => {
  const root = tmp();
  const base = path.dirname(mod.ledgerPaths(root).base);
  for (const [dir, n] of [['v0', 2], ['v9', 1]]) {
    fs.mkdirSync(path.join(base, dir, 'edges'), { recursive: true });
    for (let i = 0; i < n; i += 1) fs.writeFileSync(path.join(base, dir, 'edges', `${i}-a.json`), '{}');
  }
  const out = mod.otherSchemaLedgers(root);
  assert.deepEqual(out.map((o) => [o.version, o.relation, o.records]), [[0, 'older', 2], [9, 'newer', 1]]);
  // "older" means this build can be taught to read it; "newer" means the plugin is
  // behind. The remedies differ, so the caller must not have to infer which it is.
  fs.rmSync(root, { recursive: true, force: true });
});

test('the CURRENT schema directory is never reported as foreign', () => {
  const root = tmp();
  const p = mod.ledgerPaths(root);
  fs.mkdirSync(p.edges, { recursive: true });
  fs.writeFileSync(path.join(p.edges, '1-a.json'), '{}');
  assert.deepEqual(mod.otherSchemaLedgers(root), []);
  fs.rmSync(root, { recursive: true, force: true });
});

test('an empty foreign directory is not a migration, and neither is a stray name', () => {
  const root = tmp();
  const base = path.dirname(mod.ledgerPaths(root).base);
  // Empty: reporting it would send the operator hunting for records nobody wrote.
  fs.mkdirSync(path.join(base, 'v0', 'edges'), { recursive: true });
  // Not a version directory at all, and one whose `edges` is a file rather than a
  // directory — both must be stepped over rather than counted.
  fs.mkdirSync(path.join(base, 'backup', 'edges'), { recursive: true });
  fs.writeFileSync(path.join(base, 'backup', 'edges', '1-a.json'), '{}');
  fs.mkdirSync(path.join(base, 'v7'), { recursive: true });
  fs.writeFileSync(path.join(base, 'v7', 'edges'), 'not a directory');
  assert.deepEqual(mod.otherSchemaLedgers(root), []);
  fs.rmSync(root, { recursive: true, force: true });
});

test('a symlinked EDGES directory is stepped over, not read through', { skip: process.platform === 'win32' ? 'symlink creation needs privileges on win32' : false }, () => {
  const root = tmp();
  const base = path.dirname(mod.ledgerPaths(root).base);
  const real = path.join(root, 'elsewhere');
  fs.mkdirSync(real, { recursive: true });
  fs.writeFileSync(path.join(real, '1-a.json'), '{}');
  fs.mkdirSync(path.join(base, 'v0'), { recursive: true });
  fs.symlinkSync(real, path.join(base, 'v0', 'edges'));
  // The count this returns becomes an instruction the operator acts on, and the
  // config root is writable by every session on the machine.
  assert.deepEqual(mod.otherSchemaLedgers(root), []);
  fs.rmSync(root, { recursive: true, force: true });
});

test('a symlinked VERSION directory is stepped over too', { skip: process.platform === 'win32' ? 'symlink creation needs privileges on win32' : false }, () => {
  // The case above plants the link at the LEAF, which an lstat of the leaf catches
  // on its own — so it passed while a link one level up was resolved as an ordinary
  // intermediate component and its edges/ enumerated. Found in review, reproduced,
  // and pinned here at the level that was actually open.
  const root = tmp();
  const base = path.dirname(mod.ledgerPaths(root).base);
  const real = path.join(root, 'elsewhere');
  fs.mkdirSync(path.join(real, 'edges'), { recursive: true });
  fs.writeFileSync(path.join(real, 'edges', '1-a.json'), '{}');
  fs.mkdirSync(base, { recursive: true });
  fs.symlinkSync(real, path.join(base, 'v0'));
  assert.deepEqual(mod.otherSchemaLedgers(root), []);
  fs.rmSync(root, { recursive: true, force: true });
});

test('a missing store answers empty rather than throwing', () => {
  assert.deepEqual(mod.otherSchemaLedgers(path.join(tmp(), 'nothing-here')), []);
});

test('a competing write that lands while the replacement is being staged is still detected', () => {
  // The fingerprint was described as read "immediately before the landing", but
  // `writeLabels` then ran `ensureLedgerDir` and a full temp write before reaching
  // `renameSync` — so a writer landing inside that span was overwritten silently, and
  // the process that lost the update printed success and exited 0. Only the rename may
  // sit inside the checked window.
  //
  // The staging step is injected because it IS the window: interfering from `mutate`
  // reaches only the half the check already caught.
  const root = tmp();
  const p = mod.ledgerPaths(root);
  mod.writeLabels(p.labels, mod.emptyLabels(), root);
  let interfered = false;
  const stage = (labelsFile, labels, stopAt) => {
    if (!interfered) {
      interfered = true;
      const theirs = mod.emptyLabels();
      theirs.accounts.other = 'Theirs';
      mod.writeLabels(labelsFile, theirs, stopAt);
    }
    return mod.stageLabels(labelsFile, labels, stopAt);
  };
  const out = mod.updateLabels(p.labels, (l) => {
    const next = mod.normalizeLabels(l);
    next.accounts.mine = 'Mine';
    return next;
  }, root, 5, stage);
  assert.equal(interfered, true, 'the interference has to have happened for this to mean anything');
  assert.equal(out.accounts.mine, 'Mine', 'our own update still lands');
  assert.equal(out.accounts.other, 'Theirs', 'and the competing write is not silently overwritten');
  assert.equal(mod.readLabels(p.labels, root).labels.accounts.other, 'Theirs');
  fs.rmSync(root, { recursive: true, force: true });
});

test('the successor index is ordered once, so no hop re-sorts the bucket it stands on', () => {
  // The per-root index rebuild is gone, but each hop still re-filtered, re-sorted and
  // re-copied the successor list of its own node, and `chainWalks` runs one walk per
  // root — so many roots into one hub with many successors paid for one sorted pass
  // per root over the same bucket. Sorting inside the index puts the ordering rule in
  // ONE place and leaves the walk with a filter.
  const hub = [
    edge('h', 'x', at(1)),
    { ...edge('h', 'y', at(2)), confidence: 'confirmed' },
    edge('h', 'z', at(3)),
  ];
  const idx = mod.indexBySource(hub);
  const order = idx.get('h').map((e) => e.to.sessionId);
  // Confidence first, then newest — the same rule `dedupeEdges` and the walk apply,
  // which is exactly why it must not be spelled twice.
  assert.deepEqual(order, ['y', 'z', 'x']);
  // And the walk still answers what it answered before: the index is the only thing
  // that moved.
  assert.equal(mod.walkChain('h', hub).links[0].to.sessionId, 'y');
});

test('a record that vanished during the scan is not reported as an I/O fault', () => {
  // The store is machine-wide and append-only, and `--forget --apply` unlinks records
  // while other windows are reading: a name listed by readdir and gone by the open is
  // the NORMAL case for this concurrency model, not a disk or permission problem.
  // Reported as UNREADABLE it entered `refused`, and a non-empty `refused` blocks
  // `--backfill --apply` — so one window's routine cleanup made an unrelated backfill
  // in another window refuse and write nothing.
  //
  // The listing is injected for the same reason `writeEdge` already accepts `nameFor`:
  // winning the race against a real unlink is not reproducible, while the behaviour
  // under test — a real open, a real ENOENT, the classification and the exclusion —
  // is exercised end to end.
  const root = tmp();
  const p = mod.ledgerPaths(root);
  fs.mkdirSync(p.edges, { recursive: true });
  fs.writeFileSync(path.join(p.edges, '1-a.json'), JSON.stringify(edge('a', 'b', at(1))));
  // The vocabulary first, and asserted as a VALUE rather than as a difference: an
  // absent key is unequal to everything, so `notEqual` alone passed against a reason
  // that did not exist.
  assert.equal(typeof mod.EDGE_REFUSALS.VANISHED, 'string');
  assert.notEqual(mod.EDGE_REFUSALS.VANISHED, mod.EDGE_REFUSALS.UNREADABLE);
  // The seam has to be HONOURED, or the case below proves nothing: a listing naming
  // only the vanished record must yield no edges at all, which the real readdir —
  // holding the surviving file — could never produce.
  const gone = mod.readEdges(p.edges, null, mod.MAX_EDGE_RECORDS, () => ['2-gone.json']);
  assert.equal(gone.edges.length, 0, 'the injected listing decides what is opened');
  assert.deepEqual(gone.refused, [], 'a vanished record is not something a human can act on');
  const out = mod.readEdges(p.edges, null, mod.MAX_EDGE_RECORDS, () => ['1-a.json', '2-gone.json']);
  assert.equal(out.edges.length, 1, 'the surviving record still reads');
  assert.deepEqual(out.refused, [], 'and the vanished neighbour still does not block it');
  fs.rmSync(root, { recursive: true, force: true });
});

test('a stamp far above now is refused, so an append-only store cannot be permanently outranked', () => {
  // The `9999` outcome the ordering comment names as the motivating defect, reached
  // through a spelling that satisfies every existing guard: the shape matches,
  // Date.parse is finite, and the round-trip reproduces it exactly. Such a record then
  // wins the dedupe survivor, the branch preference and the `--where` answer for as
  // long as the store keeps it, which is forever.
  assert.equal(mod.isIsoInstant('9999-12-31T23:59:59.999Z'), false);
  assert.equal(mod.isIsoInstant(new Date(Date.now() + 3 * 86400000).toISOString()), false);
  // The past stays unbounded — a real ledger is mostly history, and a record is not
  // suspicious for being old.
  assert.equal(mod.isIsoInstant('2020-01-01T00:00:00.000Z'), true);
  // And a small skew is still a legitimate now: refusing at exactly `Date.now()` would
  // reject a record this machine had just written.
  assert.equal(mod.isIsoInstant(new Date(Date.now() + 60000).toISOString()), true);
  // The refusal has to reach the record, not only the predicate.
  const far = { ...edge('a', 'b', at(1)), recordedAt: '9999-12-31T23:59:59.999Z' };
  const v = mod.classifyEdge(far);
  assert.equal(v.ok, false);
  assert.equal(v.reason, mod.EDGE_REFUSALS.MALFORMED);
});

test('a revisit is reported even when the node it happened at also has a continuation', () => {
  // The documented reset flow (adopt a>b, then adopt b>a from the original window)
  // is only invisible when the node ALSO leads somewhere: the filter drops the seen
  // successor silently and `forks` is built from the filtered list, so neither
  // channel mentions it. Assigning the flag in the no-candidates arm alone made it
  // depend on the revisit being the LAST option rather than on it having happened.
  const shape = [
    { ...edge('a', 'b', at(1)), confidence: 'confirmed' },
    { ...edge('b', 'a', at(2)), confidence: 'confirmed' },
    { ...edge('b', 'c', at(3)), confidence: 'confirmed' },
  ];
  const w = mod.walkChain('a', shape);
  assert.equal(w.links.length, 2, 'the walk still follows the continuation');
  assert.equal(w.revisited, true, 'a dropped successor is a revisit whether or not the walk stopped there');
  // Positive control on the same shape minus the continuation: the terminal arm this
  // change keeps as the `||` case must still answer true on its own.
  assert.equal(mod.walkChain('a', shape.slice(0, 2)).revisited, true);
  // And a chain that genuinely ends still reports neither.
  assert.equal(mod.walkChain('a', [shape[0]]).revisited, false);
});

test('the cap keeps the NEWEST records, so a store past it still answers about today', () => {
  // Exercised through the optional `max` rather than by planting MAX_EDGE_RECORDS+1
  // files: the DIRECTION of the slice is the whole property, and twenty thousand
  // writes would buy nothing but wall clock on the Windows shard this suite already
  // saturates.
  const root = tmp();
  const p = mod.ledgerPaths(root);
  fs.mkdirSync(p.edges, { recursive: true });
  for (let i = 1; i <= 4; i += 1) {
    fs.writeFileSync(path.join(p.edges, `${i}-r.json`), JSON.stringify(edge(`s${i}`, `t${i}`, at(i))));
  }
  const out = mod.readEdges(p.edges, null, 3);
  assert.equal(out.truncated, true, 'a bounded read must still say it was bounded');
  const ids = out.edges.map((e) => e.from.sessionId).sort();
  assert.deepEqual(ids, ['s2', 's3', 's4'], 'the OLDEST record is the one dropped, never the newest');
  // The one input the implementation comment singles out. `slice(-0)` is `slice(0)`,
  // which returns EVERYTHING, so this line is red for the shorthand and green for the
  // arithmetic that replaced it — and nothing else in the suite distinguishes them.
  assert.equal(mod.readEdges(p.edges, null, 0).edges.length, 0, 'a cap of zero admits nothing');
  // A seam may only TIGHTEN. A caller asking for more than the module's own bound gets
  // the module's bound, or the cap on a machine-wide directory is caller policy.
  assert.equal(mod.readEdges(p.edges, null, mod.MAX_EDGE_RECORDS + 1000).edges.length, 4);
  // And the injected listing is held to the same NAME rule the real one satisfies
  // structurally: a name that is not a single path component is refused, not joined.
  const escaped = mod.readEdges(p.edges, null, mod.MAX_EDGE_RECORDS, () => ['../outside.json', '1-r.json']);
  assert.equal(escaped.edges.length, 1, 'only the well-named record is read');
  assert.deepEqual(escaped.refused.map((r) => r.file), ['../outside.json']);
  fs.rmSync(root, { recursive: true, force: true });
});

test('the future bound is the declared constant, not merely an order of magnitude', () => {
  // Both sides of the boundary, against a FIXED clock and the exported value. The
  // behavioural case above brackets the bound between a minute and three days, which
  // any value in that range satisfies — so the constant itself was unpinned and could
  // move without a red.
  const T = Date.parse('2026-06-01T00:00:00.000Z');
  const at = (ms) => new Date(T + ms).toISOString();
  assert.equal(mod.isIsoInstant(at(mod.MAX_FUTURE_SKEW_MS), T), true, 'exactly at the bound is still now');
  assert.equal(mod.isIsoInstant(at(mod.MAX_FUTURE_SKEW_MS + 1), T), false, 'one millisecond past it is not');
});
