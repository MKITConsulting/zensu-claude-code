'use strict';

// Unit driver for discardSupersededLeases — the superseded-lease sweep the
// adoption runs after it re-mints a session's Session Control record.
//
// It exists because the sweep used to be reachable only through a full
// synthetic install plus a session lifecycle: every branch cost one end-to-end
// row in test-versioned-plugin-upgrade.sh, and three of its return shapes were
// not reachable from there at all. Review of PR #252 recorded that as the
// direct cost of the function being unexported, alongside the five lease-store
// elements it used to hand-copy from review-evidence-lease-v1.js.
//
// WHY THE SWEEP IS NOT IN session-control-core-v1.js ANY MORE. The obvious
// seam — the core requiring the owner and consuming its exports — is a require
// CYCLE: review-evidence-lease-v1.js requires claude-hook-session-v1.js, which
// requires session-control-core-v1.js. So the sweep moved the other way, into
// this module, which may require the owner freely (sweep -> lease ->
// hook-session -> core is acyclic). That is the ENTRY-POINT seam CLAUDE.md
// already prescribes, and its stated cost is that the sweep becomes a host
// obligation: zensu-session-adopt.sh calls it after adoptContext instead of
// adoptContext calling it internally.
//
// Registered with the tree runner through test-versioned-plugin-upgrade.sh,
// which drives it the same way it drives the recognizer and lineage suites —
// tests/run-all.sh discovers only test-*.sh, so an undriven *.test.js never
// runs at all.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const LIB = path.join(__dirname, '..', '..', 'hooks', 'lib');
const CORE_FILE = path.join(LIB, 'session-control-core-v1.js');
const LEASE_FILE = path.join(LIB, 'review-evidence-lease-v1.js');
const SWEEP_FILE = path.join(LIB, 'review-evidence-sweep-v1.js');

const lease = require(LEASE_FILE);

// Required per test rather than at module scope. A top-level require of a file
// that does not exist yet aborts the whole file, so exactly one case reports and
// the other ten never run — which is the difference between a RED that names
// every missing property and one that names only the first.
function sweep() {
  return require(SWEEP_FILE);
}

// A session key is 'scv1_' plus 64 hex characters; the sweep only ever joins it
// as a path segment, so any well-formed one serves.
const KEY = `scv1_${'a'.repeat(64)}`;
const LEASE_ID = `rel1_${'b'.repeat(32)}`;

function tempRoot() {
  // realpath: on macOS mkdtemp answers /var/... while the kernel spells it
  // /private/var/..., and the sweep compares realpath against its own join.
  return fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-sweep-')));
}

function recordsDir(pluginData) {
  return path.join(pluginData, 'review-evidence', 'v1', 'records', KEY);
}

function asideDir(pluginData) {
  return path.join(pluginData, 'review-evidence', 'v1', 'superseded', KEY);
}

function seedLease(pluginData, name, body) {
  const dir = recordsDir(pluginData);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  fs.writeFileSync(path.join(dir, name), body, { mode: 0o600 });
  return path.join(dir, name);
}

function leaseBody(overrides) {
  return JSON.stringify(Object.assign({
    schema: 'zensu.review-evidence-lease',
    schema_version: 1,
    lease_id: LEASE_ID,
    plugin_root: '/executing/root',
  }, overrides || {}));
}

// ── The seam ────────────────────────────────────────────────────────────────
// PR #252 review, finding #3: five elements were hand-copied out of
// review-evidence-lease-v1.js and only two of them were pinned — and both pins
// compared source SPELLINGS rather than behaviour. CLAUDE.md's own rule for
// this function ("if it needs a fourth correction, take the seam") had already
// fired, so the copies are gone and the owner exports them instead.

test('S1 the sweep is exported so its branches are reachable without a session lifecycle', () => {
  assert.equal(typeof sweep().discardSupersededLeases, 'function');
});

test('S1 the owner exports the lease-store elements the sweep needs', () => {
  assert.ok(lease.LEASE_ID_RE instanceof RegExp, 'LEASE_ID_RE is exported');
  assert.equal(typeof lease.MAX_RECORD_BYTES, 'number');
  assert.equal(typeof lease.ensurePrivateDirectory, 'function');
  assert.ok(Array.isArray(lease.REVIEW_EVIDENCE_SEGMENTS), 'the store layout is exported');
  assert.equal(typeof lease.leaseRecordIsOwned, 'function', 'the ownership predicate is exported');
});

test('S1 neither the core nor the sweep keeps a private copy of the owner\'s literals', () => {
  // Source-level, deliberately: a behavioural check cannot see a SECOND copy of
  // a rule that happens to agree today. This is the same reason
  // fixture-mutation-watch.test.js pins its single-implementation property at
  // source level. BOTH files are checked — testing only the core would go green
  // the moment the sweep moved out, carrying its copies with it.
  for (const file of [CORE_FILE, SWEEP_FILE]) {
    const source = fs.readFileSync(file, 'utf8');
    assert.equal(
      source.includes('rel1_[a-f0-9]{32}'), false,
      `${path.basename(file)}: the lease id shape must come from the owner, not a copy`,
    );
    assert.equal(
      /8\s*\*\s*1024\s*\*\s*1024/.test(source), false,
      `${path.basename(file)}: the record size cap must come from the owner, not a copy`,
    );
  }
});

test('S1 the sweep no longer lives in the core, and the core does not call it', () => {
  // The entry-point seam in one assertion: the cycle makes a core-side sweep
  // impossible to keep honest, so the core must not carry it at all.
  const source = fs.readFileSync(CORE_FILE, 'utf8');
  assert.equal(source.includes('function discardSupersededLeases'), false);
  assert.equal(source.includes('discardSupersededLeases('), false);
});

test('S1 the ownership predicate agrees with the reader it mirrors', () => {
  assert.equal(
    lease.leaseRecordIsOwned(`${LEASE_ID}.json`, JSON.parse(leaseBody()), '/executing/root'),
    true,
  );
  // Each conjunct on its own.
  assert.equal(
    lease.leaseRecordIsOwned('not-a-lease.json', JSON.parse(leaseBody()), '/executing/root'),
    false,
  );
  assert.equal(
    lease.leaseRecordIsOwned(`${LEASE_ID}.tmp`, JSON.parse(leaseBody()), '/executing/root'),
    false,
  );
  assert.equal(
    lease.leaseRecordIsOwned(`${LEASE_ID}.json`, JSON.parse(leaseBody({ lease_id: `rel1_${'c'.repeat(32)}` })), '/executing/root'),
    false,
  );
  assert.equal(
    lease.leaseRecordIsOwned(`${LEASE_ID}.json`, JSON.parse(leaseBody()), '/other/root'),
    false,
  );
  assert.equal(lease.leaseRecordIsOwned(`${LEASE_ID}.json`, null, '/executing/root'), false);
});

// ── asideIsSafe at module scope ─────────────────────────────────────────────
// Finding #7: the walk's leaf-vs-ancestor asymmetry was 30 lines of prose plus
// an `if (segment === 'superseded')` in the middle of the loop, and no row
// planted an unsafe shape at review-evidence, v1 or superseded.

test('S1 asideIsSafe is reachable and takes its mode-checked segments as a parameter', () => {
  assert.equal(typeof sweep().asideIsSafe, 'function');
  assert.equal(sweep().asideIsSafe.length >= 2, true, 'base plus segments, not a closure over both');
});

// ── Baseline behaviour the later steps build on ─────────────────────────────

test('S1 a lease naming the executing root is kept', () => {
  const pluginData = tempRoot();
  seedLease(pluginData, `${LEASE_ID}.json`, leaseBody());
  const result = sweep().discardSupersededLeases(pluginData, KEY, '/executing/root');
  assert.deepEqual(result, { discarded: 0, failed: [], unsafe: '', unsafeAt: '' });
  assert.equal(fs.existsSync(path.join(recordsDir(pluginData), `${LEASE_ID}.json`)), true);
});

test('S1 a lease naming the superseded root is set aside, never deleted', () => {
  const pluginData = tempRoot();
  seedLease(pluginData, `${LEASE_ID}.json`, leaseBody({ plugin_root: '/previous/root' }));
  const result = sweep().discardSupersededLeases(pluginData, KEY, '/executing/root');
  assert.equal(result.discarded, 1);
  assert.deepEqual(result.failed, []);
  assert.equal(result.unsafe, '');
  assert.equal(fs.existsSync(path.join(recordsDir(pluginData), `${LEASE_ID}.json`)), false);
  assert.equal(fs.existsSync(path.join(asideDir(pluginData), `${LEASE_ID}.json`)), true);
});

test('S9 a session with no lease store has nothing created for it', () => {
  // SELF-REVIEW FINDING, introduced by taking the owner's lock in S2. withLock runs
  // storage(), which is a CONSTRUCTOR: it calls ensurePrivateDirectory for the store
  // root, the records leaf and the locks directory. So every adoption of a session
  // that never minted a lease was materializing the whole store — and, worse, the
  // source guard's lstat ENOENT arm became unreachable through the public entry
  // point, because the directory it tests for absence was created moments earlier by
  // the lock. The sibling case below is named for that arm and had stopped
  // exercising it.
  const pluginData = tempRoot();
  const result = sweep().discardSupersededLeases(pluginData, KEY, '/executing/root');
  assert.deepEqual(result, { discarded: 0, failed: [], unsafe: '', unsafeAt: '' });
  assert.deepEqual(fs.readdirSync(pluginData), [],
    'a no-lease sweep must create nothing at all');
});

test('S1 an absent records directory is the clean no-lease case, not a refusal', () => {
  const pluginData = tempRoot();
  assert.deepEqual(
    sweep().discardSupersededLeases(pluginData, KEY, '/executing/root'),
    { discarded: 0, failed: [], unsafe: '', unsafeAt: '' },
  );
});

test('S1 an existing-but-empty records directory creates no superseded leaf', () => {
  // Finding #6: this early return is what makes the armed-fixture rows in the
  // shell suite positive controls, and nothing exercised it.
  const pluginData = tempRoot();
  fs.mkdirSync(recordsDir(pluginData), { recursive: true, mode: 0o700 });
  assert.deepEqual(
    sweep().discardSupersededLeases(pluginData, KEY, '/executing/root'),
    { discarded: 0, failed: [], unsafe: '', unsafeAt: '' },
  );
  assert.equal(fs.existsSync(asideDir(pluginData)), false);
});

test('S1 every return spells the clean verdict identically', () => {
  // Finding #7's tail: one return said `unsafe: ""` while its siblings said ''.
  const source = fs.readFileSync(SWEEP_FILE, 'utf8');
  assert.equal(source.includes('unsafe: ""'), false);
});

// ── S2: sweep correctness ───────────────────────────────────────────────────
// Four review findings, each of which needed the sweep broken into pieces small
// enough to reach. Before this the only entry point was the whole function, so a
// refusal arm could only be driven by arranging the filesystem to reach it — which
// is exactly why several of them had never been driven at all.

test('S2 asideIsSafe names the component it refused, not a bare false', () => {
  // Finding #20: asideIsSafe refuses on four distinct components and returned a
  // bare false for all of them, which collapsed to unsafe: "destination". The
  // report then told the operator to inspect superseded/<key> — a path that cannot
  // exist when its own parent is the offending file.
  const pluginData = tempRoot();
  fs.mkdirSync(path.join(pluginData, 'review-evidence', 'v1'), { recursive: true, mode: 0o700 });
  const blocker = path.join(pluginData, 'review-evidence', 'v1', 'superseded');
  fs.writeFileSync(blocker, 'not a directory', { mode: 0o600 });

  const verdict = sweep().asideIsSafe(pluginData, ['review-evidence', 'v1', 'superseded', KEY], ['superseded']);
  assert.equal(verdict.ok, false);
  assert.equal(verdict.at, blocker, 'the refused component is the file, not the leaf below it');
});

test('S2 asideIsSafe reports ok with no offending component on a clean chain', () => {
  const pluginData = tempRoot();
  const verdict = sweep().asideIsSafe(pluginData, ['review-evidence', 'v1', 'superseded', KEY], ['superseded']);
  assert.equal(verdict.ok, true);
  assert.equal(verdict.at, '');
});

test('S2 the win32 read path rejects a symlinked entry without O_NOFOLLOW', () => {
  // Finding #9: noFollow is forced to 0 on win32, and there openSync follows the
  // link while fstat describes the TARGET — so a symlink whose target is a valid
  // lease naming the executing root was KEPT, while canonicalExisting in the owner
  // rejects it with no win32 gate. The sweep then reported a clean set-aside count
  // for a store listRecords still refuses.
  //
  // Driven through the explicit noFollow option so the branch is reachable on a
  // POSIX host, where O_NOFOLLOW exists and would otherwise mask it.
  const pluginData = tempRoot();
  const target = seedLease(pluginData, `${LEASE_ID}.json`, leaseBody());
  const link = path.join(recordsDir(pluginData), `rel1_${'d'.repeat(32)}.json`);
  fs.symlinkSync(target, link);
  // The W167/W168 rule: confirm the link is a real symlink before asserting on it.
  assert.notEqual(fs.realpathSync.native(link), link);

  assert.equal(sweep().readLeaseEntry(link, { noFollow: 0 }), null,
    'a symlinked entry is unreadable even where O_NOFOLLOW is unavailable');
  // Positive control on the same host: the real file still reads.
  assert.notEqual(sweep().readLeaseEntry(target, { noFollow: 0 }), null);
});

test('S2 the read path refuses an oversized entry and an unparseable one', () => {
  const pluginData = tempRoot();
  const good = seedLease(pluginData, `${LEASE_ID}.json`, leaseBody());
  const junk = path.join(recordsDir(pluginData), 'not-json.json');
  fs.writeFileSync(junk, '{ this is not json', { mode: 0o600 });
  assert.equal(sweep().readLeaseEntry(junk), null);
  assert.notEqual(sweep().readLeaseEntry(good), null);
  assert.equal(sweep().readLeaseEntry(good, { maxBytes: 4 }), null, 'over the cap is unreadable');
});

test('S2 moveAside distinguishes moved, collision and gone', () => {
  // Finding #12: rename(2) replaces an existing destination silently, so a colliding
  // entry under superseded/<key> was DESTROYED with no report — contradicting the
  // "MOVED (never deleted)" contract in the entry script's own header. And a source
  // that vanished (a .tmp unlinked by its own writer) threw ENOENT and was reported
  // as a stuck lease, naming a file that no longer exists.
  const root = tempRoot();
  const from = path.join(root, 'from');
  const to = path.join(root, 'to');
  fs.mkdirSync(from, { mode: 0o700 });
  fs.mkdirSync(to, { mode: 0o700 });

  fs.writeFileSync(path.join(from, 'a.json'), 'A', { mode: 0o600 });
  assert.equal(sweep().moveAside(path.join(from, 'a.json'), path.join(to, 'a.json')), 'moved');
  assert.equal(fs.readFileSync(path.join(to, 'a.json'), 'utf8'), 'A');

  fs.writeFileSync(path.join(from, 'b.json'), 'NEW', { mode: 0o600 });
  fs.writeFileSync(path.join(to, 'b.json'), 'EXISTING', { mode: 0o600 });
  assert.equal(sweep().moveAside(path.join(from, 'b.json'), path.join(to, 'b.json')), 'collision');
  assert.equal(fs.readFileSync(path.join(to, 'b.json'), 'utf8'), 'EXISTING',
    'a collision must never destroy what is already set aside');

  assert.equal(sweep().moveAside(path.join(from, 'gone.json'), path.join(to, 'gone.json')), 'gone');
});

test('S2 a collision is reported as stuck, never as a clean set-aside', () => {
  const pluginData = tempRoot();
  seedLease(pluginData, `${LEASE_ID}.json`, leaseBody({ plugin_root: '/previous/root' }));
  fs.mkdirSync(asideDir(pluginData), { recursive: true, mode: 0o700 });
  fs.writeFileSync(path.join(asideDir(pluginData), `${LEASE_ID}.json`), 'ALREADY THERE', { mode: 0o600 });

  const result = sweep().discardSupersededLeases(pluginData, KEY, '/executing/root');
  assert.equal(result.discarded, 0);
  assert.deepEqual(result.failed, [`${LEASE_ID}.json`]);
  assert.equal(fs.readFileSync(path.join(asideDir(pluginData), `${LEASE_ID}.json`), 'utf8'), 'ALREADY THERE');
});

test('S2 destinationStillSafe catches a destination swapped after the guard ran', () => {
  // The re-check does not CLOSE the rename race — Node exposes no renameat — but it
  // converts a silent redirect of every moved lease into a reported outcome.
  const root = tempRoot();
  const real = path.join(root, 'real');
  const elsewhere = path.join(root, 'elsewhere');
  fs.mkdirSync(real, { mode: 0o700 });
  fs.mkdirSync(elsewhere, { mode: 0o700 });
  assert.equal(sweep().destinationStillSafe(real), true);

  const swapped = path.join(root, 'swapped');
  fs.symlinkSync(elsewhere, swapped);
  assert.notEqual(fs.realpathSync.native(swapped), swapped);
  assert.equal(sweep().destinationStillSafe(swapped), false);
  assert.equal(sweep().destinationStillSafe(path.join(root, 'absent')), false);
});

test('S2 the sweep runs under the lease store\'s own lock', () => {
  // Finding #5: every mutating entry point in review-evidence-lease-v1.js runs
  // inside withLock on review-evidence/v1/locks/<sessionKey>.lock, and the sweep
  // acquired nothing — so a concurrent createLease could have its .tmp moved out
  // from under it. The lease module's withLock never reclaims a lock; the core's
  // withFileLock does, and importing that policy here would let the sweep unlink a
  // live owner's lock.
  const source = fs.readFileSync(SWEEP_FILE, 'utf8');
  // A CALL, not a mention: the module's own comment names withFileLock to say why it
  // is the wrong policy here, and a bare substring pin cannot tell the two apart.
  assert.equal(/\bwithFileLock\s*\(/.test(source), false,
    'the core reclaiming lock policy must not be CALLED on this store');
  assert.ok(/lease\.withLock\s*\(/.test(source), 'the sweep takes the owner\'s lock');

  // Behavioural half: a sweep leaves the store's lock directory behind, which is
  // only created by the owner's own storage() constructor.
  const pluginData = tempRoot();
  seedLease(pluginData, `${LEASE_ID}.json`, leaseBody({ plugin_root: '/previous/root' }));
  const result = sweep().discardSupersededLeases(pluginData, KEY, '/executing/root');
  assert.equal(result.discarded, 1);
  assert.equal(fs.existsSync(path.join(pluginData, 'review-evidence', 'v1', 'locks')), true);
});

test('S2 an unopenable store is refused as source rather than thrown', () => {
  // Taking the owner's lock means its constructor can throw — on a symlinked or
  // aliased store it refuses rather than repairing. That must reach the caller as a
  // verdict, because this runs AFTER the record swap: a throw here would report
  // failure for an adoption that already succeeded.
  const pluginData = tempRoot();
  const evidence = path.join(pluginData, 'review-evidence');
  fs.writeFileSync(evidence, 'not a directory', { mode: 0o600 });
  const result = sweep().discardSupersededLeases(pluginData, KEY, '/executing/root');
  assert.equal(result.unsafe, 'source');
  assert.equal(result.discarded, 0);
  assert.deepEqual(result.failed, []);
});

test('S2b a file ancestor is named as the blocker on the host that reports ENOENT', () => {
  // win32 answers ENOENT — not ENOTDIR — for a path whose ancestor is a FILE, so
  // discardSupersededLeases took its "no store here" arm and reported a clean sweep
  // over a store it never opened. windows-shard-2 is where that surfaced; S2 above
  // cannot show it, because on POSIX the ENOTDIR arm answers first and the ENOENT
  // branch is never entered. This drives the re-derivation directly, so the fix has
  // an executed case on every host rather than only on the one that failed.
  const pluginData = tempRoot();
  const evidence = path.join(pluginData, 'review-evidence');
  fs.writeFileSync(evidence, 'not a directory', { mode: 0o600 });
  const leaf = path.join(pluginData, 'review-evidence', 'v1', 'records', KEY);
  assert.equal(sweep().firstNonTraversableAncestor(pluginData, leaf), evidence);

  // Discrimination: a store that is merely ABSENT must not be named, or every
  // session that never minted a lease would be reported as a malformed store.
  const empty = tempRoot();
  assert.equal(
    sweep().firstNonTraversableAncestor(empty, path.join(empty, 'review-evidence', 'v1', 'records', KEY)),
    '',
  );

  // A real directory chain is traversable all the way down and names nothing.
  const whole = tempRoot();
  const full = path.join(whole, 'review-evidence', 'v1', 'records', KEY);
  fs.mkdirSync(full, { recursive: true, mode: 0o700 });
  assert.equal(sweep().firstNonTraversableAncestor(whole, full), '');
});

// ── S4: the refusal arms that had never been driven ─────────────────────────

test('S4 the per-segment superseded permission check is reachable and load-bearing', (t) => {
  // Finding #8: AC-C12b plants 0777 at the LEAF and then explicitly chmods
  // `superseded` back to 0700, forcing this check to pass so the walk refuses one
  // line later. Its own claim — delete the mode pair and the row goes red — was
  // therefore true of the LEAF pair, not this one. Deleting the per-segment check
  // left the whole suite green.
  // A real SKIP, not a bare return: node:test records a returning case as a PASS, so
  // five of these reported green on the Windows shard with nothing asserted.
  if (process.platform === 'win32') return t.skip('win32: privateEnough is a documented no-op');
  const pluginData = tempRoot();
  const segments = ['review-evidence', 'v1', 'superseded', KEY];
  // Build the chain, then widen `superseded` only — the leaf stays private, so the
  // leaf pair cannot be what refuses.
  fs.mkdirSync(path.join(pluginData, ...segments), { recursive: true, mode: 0o700 });
  fs.chmodSync(path.join(pluginData, 'review-evidence', 'v1', 'superseded'), 0o777);
  fs.chmodSync(path.join(pluginData, ...segments), 0o700);

  const verdict = sweep().asideIsSafe(pluginData, segments, ['superseded']);
  assert.equal(verdict.ok, false, 'a world-writable superseded must refuse');
  assert.equal(verdict.at, path.join(pluginData, 'review-evidence', 'v1', 'superseded'));

  // The discrimination: with `superseded` NOT in the mode-checked set, the same
  // chain is accepted. That is what proves the refusal came from this check and not
  // from the leaf pair or the shape walk.
  const withoutCheck = sweep().asideIsSafe(pluginData, segments, []);
  assert.equal(withoutCheck.ok, true);
});

test('S4 a shared ancestor at 0755 is NOT refused', (t) => {
  // The other half of the asymmetry, and it has to hold or the sweep starts failing
  // on a permission it does not manage: `review-evidence` and `v1` belong to
  // ensurePrivateDirectory, which repairs them with a chmod. This function may only
  // look.
  if (process.platform === 'win32') return t.skip('win32: privateEnough is a documented no-op');
  const pluginData = tempRoot();
  const segments = ['review-evidence', 'v1', 'superseded', KEY];
  fs.mkdirSync(path.join(pluginData, ...segments), { recursive: true, mode: 0o700 });
  fs.chmodSync(path.join(pluginData, 'review-evidence'), 0o755);
  const verdict = sweep().asideIsSafe(pluginData, segments, ['superseded']);
  assert.equal(verdict.ok, true, 'a shared ancestor mode is not this function to judge');
});

test('S4 a FIFO entry is refused rather than hung on', (t) => {
  // The exact hang this guard was written to stop, and no fixture had ever
  // demonstrated it being stopped. A bare readFileSync on a FIFO blocks forever and
  // raises nothing a catch can see — and the sweep runs AFTER the record swap, so a
  // hang leaves the one repair the user can still invoke stuck half-done.
  if (process.platform === 'win32') return t.skip('win32: privateEnough is a documented no-op');
  const pluginData = tempRoot();
  seedLease(pluginData, `${LEASE_ID}.json`, leaseBody());
  const fifo = path.join(recordsDir(pluginData), `rel1_${'9'.repeat(32)}.json`);
  const made = require('node:child_process').spawnSync('mkfifo', [fifo], { stdio: 'ignore' });
  if (made.status !== 0) return t.skip('mkfifo is unavailable on this host');
  // Confirm it really is a FIFO before asserting on it — the same rule W167/W168
  // apply to `ln -s`, for the same reason: a tool that exits 0 is not evidence.
  assert.equal(fs.lstatSync(fifo).isFIFO(), true);

  // If this guard regressed, this call does not fail — it never returns.
  assert.equal(sweep().readLeaseEntry(fifo), null);

  // And the sweep moves it aside, because listRecords would reject it too.
  const result = sweep().discardSupersededLeases(pluginData, KEY, '/executing/root');
  assert.equal(result.discarded, 1);
  assert.equal(fs.existsSync(path.join(asideDir(pluginData), path.basename(fifo))), true);
});

test('S4 a directory entry in the records store is refused, not read', (t) => {
  if (process.platform === 'win32') return t.skip('win32: privateEnough is a documented no-op');
  const pluginData = tempRoot();
  seedLease(pluginData, `${LEASE_ID}.json`, leaseBody());
  const dir = path.join(recordsDir(pluginData), `rel1_${'8'.repeat(32)}.json`);
  fs.mkdirSync(dir, { mode: 0o700 });
  assert.equal(sweep().readLeaseEntry(dir), null);
});

test('S4 the size cap the reader uses is the owner\'s, not a test-only one', () => {
  // The S2 case drove the comparison through an injected maxBytes, which proves the
  // branch runs but not that the shipped default is the owner's value.
  const pluginData = tempRoot();
  // Driven through the DEFAULT, with no options argument: the previous form
  // compared the owner's constant against a literal in this file, which is the
  // fixture value, and never observed the value readLeaseEntry actually resolves.
  // Replacing that default with a private 4096 left it green.
  const file = seedLease(pluginData, `${LEASE_ID}.json`, leaseBody());
  assert.notEqual(sweep().readLeaseEntry(file), null, 'an ordinary lease is under the cap');
  const oversize = path.join(recordsDir(pluginData), `rel1_${'6'.repeat(32)}.json`);
  // One byte past the owner's cap, written as valid JSON so only the SIZE can be
  // what refuses it.
  const padding = 'x'.repeat(lease.MAX_RECORD_BYTES);
  fs.writeFileSync(oversize, JSON.stringify({ pad: padding }), { mode: 0o600 });
  assert.ok(fs.statSync(oversize).size > lease.MAX_RECORD_BYTES);
  assert.equal(sweep().readLeaseEntry(oversize), null,
    'the shipped default is the owner cap, not a private one');
});

test('F4 the withLock refusal is converted to a verdict, not thrown', (t) => {
  // The case named for this arm returned at the unlocked pre-check instead: a
  // regular file at <pluginData>/review-evidence makes the pre-check lstat fail
  // ENOTDIR before withLock is ever entered. To reach the catch, the records
  // directory has to EXIST and be readable while the owner's storage() constructor
  // refuses something — here an aliased store root.
  if (process.platform === 'win32') return t.skip('win32: the alias refusal is platform-gated');
  const root = tempRoot();
  const real = path.join(root, 'real-data');
  fs.mkdirSync(path.join(real, 'review-evidence', 'v1', 'records', KEY), { recursive: true, mode: 0o700 });
  fs.writeFileSync(path.join(real, 'review-evidence', 'v1', 'records', KEY, `${LEASE_ID}.json`),
    leaseBody({ plugin_root: '/previous/root' }), { mode: 0o600 });
  const aliased = path.join(root, 'aliased-data');
  fs.symlinkSync(real, aliased);
  if (fs.realpathSync.native(aliased) === aliased) return t.skip('this host did not create a real symlink');

  // The pre-check succeeds through the link; storage() is what refuses.
  const result = sweep().discardSupersededLeases(aliased, KEY, '/executing/root');
  assert.equal(result.unsafe, 'source', 'a constructor refusal is a verdict, never a throw');
  assert.equal(result.discarded, 0);
  assert.deepEqual(result.failed, []);
});

// ── F2: the fix round for the consolidated review ───────────────────────────

test('F2 the read seam is a MODE, not a flag mask a caller can widen', () => {
  // The repo already pins this shape for plan-payload-v1.js: a caller may take the
  // STRICTER path, never widen the open. Taking settings.noFollow verbatim and
  // OR-ing it into openSync let a caller inject O_CREAT, so the reader would CREATE
  // the file it reports unreadable.
  const pluginData = tempRoot();
  const target = seedLease(pluginData, `${LEASE_ID}.json`, leaseBody());
  const absent = path.join(recordsDir(pluginData), `rel1_${'7'.repeat(32)}.json`);

  assert.equal(typeof sweep().LSTAT_PRECHECK_MODE, 'string');
  // The documented seam still reaches the win32 branch.
  assert.notEqual(sweep().readLeaseEntry(target, { mode: sweep().LSTAT_PRECHECK_MODE }), null);
  // A mask cannot get in: passing O_CREAT must neither widen the open nor create.
  assert.equal(sweep().readLeaseEntry(absent, { mode: fs.constants.O_CREAT }), null);
  assert.equal(fs.existsSync(absent), false, 'the reader must never create the file it reads');
});

test('F2 a store whose leases are all owned creates no superseded leaf', () => {
  // The S9 property was incomplete: asideIsSafe ran for any non-empty store, before
  // the keep/move loop, so a session whose leases are ALL valid still had the
  // destination chain materialized.
  const pluginData = tempRoot();
  seedLease(pluginData, `${LEASE_ID}.json`, leaseBody());
  const result = sweep().discardSupersededLeases(pluginData, KEY, '/executing/root');
  assert.deepEqual(result, { discarded: 0, failed: [], unsafe: '', unsafeAt: '' });
  assert.equal(fs.existsSync(asideDir(pluginData)), false,
    'nothing needed moving, so nothing may be created');
});

test('F2 the symlink arm distinguishes a vanished source from a vanished destination', (t) => {
  if (process.platform === 'win32') return t.skip('win32: privateEnough is a documented no-op');
  const root = tempRoot();
  const from = path.join(root, 'from');
  fs.mkdirSync(from, { mode: 0o700 });
  fs.symlinkSync(path.join(root, 'nowhere'), path.join(from, 'link.json'));
  assert.equal(fs.lstatSync(path.join(from, 'link.json')).isSymbolicLink(), true);
  // The source EXISTS (it is a dangling link, which lstat still sees), so an ENOENT
  // from the rename is the DESTINATION's, and that is 'failed', not 'gone'.
  assert.equal(
    sweep().moveAside(path.join(from, 'link.json'), path.join(root, 'absent-dir', 'link.json')),
    'failed',
  );
});

test('F2 a busy lock answers its own scope, not a store-shape refusal', () => {
  const source = fs.readFileSync(SWEEP_FILE, 'utf8');
  assert.ok(/unsafe: 'locked'/.test(source), 'the lock failure has its own scope');
  assert.equal(/catch \{\s*\n\s*return \{ discarded: 0, failed: \[\], unsafe: 'source', unsafeAt: '' \};/.test(source), false,
    'the bare catch that discarded the error is gone');
});
