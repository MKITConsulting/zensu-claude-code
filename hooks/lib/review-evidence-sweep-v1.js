'use strict';

// Superseded-lease sweep for a runtime adoption.
//
// review-evidence-lease-v1.js compares its recorded plugin_root STRICTLY and
// listRecords propagates the first failure, so a single lease minted before an
// adoption fails every later lease operation for that session. A lease is a
// short-lived evidence reservation — losing one costs a repeat, not a guarantee
// — so the cheapest correct resolution is to set the superseded ones ASIDE
// (moved, never deleted) once the record has been re-minted.
//
// WHY THIS IS ITS OWN MODULE. It used to live in session-control-core-v1.js and
// hand-copy five elements out of the lease module: LEASE_ID_RE, MAX_RECORD_BYTES,
// ensurePrivateDirectory, the store layout and the ownership predicate. Only two
// of those were pinned, and both pins compared source SPELLINGS rather than
// behaviour, so a moved layout could make the sweep a silent no-op with the suite
// still green. The core cannot simply require the owner — review-evidence-lease-v1.js
// requires claude-hook-session-v1.js, which requires session-control-core-v1.js, so
// that direction is a CYCLE. The seam therefore runs the other way: the sweep moved
// HERE, where requiring the owner is acyclic, and the adoption entry script
// (zensu-session-adopt.sh, which already requires both) calls it after adoptContext.
//
// The stated cost, recorded in CLAUDE.md before this move: the sweep is now a HOST
// obligation rather than part of the cross-host core half. A port that takes the
// core delta alone gets an adoption that never sweeps.

const fs = require('node:fs');
const path = require('node:path');

const lease = require('./review-evidence-lease-v1.js');

const {
  LEASE_ID_RE,
  MAX_RECORD_BYTES,
  REVIEW_EVIDENCE_SEGMENTS,
  leaseRecordIsOwned,
} = lease;

// The ONE value `readLeaseEntry`'s `mode` option accepts. It exists so the win32
// branch — where O_NOFOLLOW is unavailable — is reachable from a POSIX host, and it
// is a STRING on purpose: compared, never OR-ed, so no caller can widen the open.
const LSTAT_PRECHECK_MODE = 'lstat-precheck';

// The one spelling of "private enough to be a rename destination". Platform-gated
// exactly as ensurePrivateDirectory's own pair is: win32 has no comparable mode or
// uid semantics here, so the check is skipped there rather than guessed at.
//
// The uid conjunct is unreachable in CI — every suite runs as the same user that
// created the fixture — so do not read a passing suite as evidence that it works.
// Only the mode arm is exercised.
function privateEnough(stat) {
  if (process.platform === 'win32') return true;
  if ((stat.mode & 0o077) !== 0) return false;
  if (typeof process.getuid === 'function' && stat.uid !== process.getuid()) return false;
  return true;
}

// Creates and validates the destination chain, one segment at a time, and answers
// whether it is safe to rename into.
//
// `modeChecked` is a PARAMETER rather than a literal in the middle of the loop,
// because the leaf-vs-ancestor asymmetry is the whole subtlety here and it used to
// be thirty lines of prose plus an `if (segment === 'superseded')` mid-walk.
//
// The SHAPE check runs on every component; the PERMISSION check does not.
//
// Shape, per segment: an ancestor swapped to a symlink is how the rename race is
// won, and mkdir neither fails on nor reports one. Checking only the leaf left that
// open, so the walk closes it. Create and check ONE segment at a time — a single
// recursive mkdir up front resolves an existing symlinked component and creates the
// leaf THROUGH it, and only then does the walk notice. Interleaving costs nothing.
//
// Permissions, only for `modeChecked` segments and the leaf: `review-evidence` and
// `v1` are SHARED and this function does not own them. Their mode belongs to
// ensurePrivateDirectory, which REPAIRS with a chmod per segment where this one may
// only look — so refusing here on an ancestor some earlier version created at 0755
// would turn a working sweep into a destination refusal for a permission this code
// never manages. `superseded` and the leaf are different: this function is their
// only creator, the mkdir tolerates EEXIST (so it neither chmods nor fails on an
// existing directory), and renameSync resolves `superseded` as a non-final
// component — a writable one is enough to redirect every moved lease out of the
// store.
//
// The shape it mirrors is privateRecordsDirectory in claude-hook-session-v1.js —
// check, never repair. Do not "align" it with ensurePrivateDirectory: a read-side
// guard that silently widens or narrows a mode is a worse defect than the one it
// would be fixing.
// Returns `{ ok, at }`. `at` NAMES the component that was refused, and that is not
// cosmetic: this walk refuses on four distinct components — `review-evidence`, `v1`,
// `superseded` and `superseded/<key>` — and a bare `false` collapsed all four into
// one `destination` verdict whose report then sent the operator to inspect the leaf.
// Plant a regular file at `superseded` and the leaf CANNOT exist, because its parent
// is a file; the operator was being told to look at a path that could not be there.
function asideIsSafe(base, segments, modeChecked) {
  const modeCheckedSet = modeChecked instanceof Set
    ? modeChecked
    : new Set(Array.isArray(modeChecked) ? modeChecked : []);
  let current = base;
  try {
    for (let index = 0; index < segments.length; index += 1) {
      const segment = segments[index];
      current = path.join(current, segment);
      try {
        fs.mkdirSync(current, { mode: 0o700 });
      } catch (error) {
        if (!error || error.code !== 'EEXIST') return { ok: false, at: current };
      }
      const stat = fs.lstatSync(current);
      if (stat.isSymbolicLink() || !stat.isDirectory()) return { ok: false, at: current };
      const isLeaf = index === segments.length - 1;
      if ((isLeaf || modeCheckedSet.has(segment)) && !privateEnough(stat)) {
        return { ok: false, at: current };
      }
    }
    // Last: realpath resolves every component at once, so one call covers the whole
    // chain against a link the lstat pass above could still have raced. It cannot say
    // WHICH component was aliased, so the leaf is named — the honest answer is "the
    // chain ending here", and that is the path the operator can inspect.
    const leaf = path.join(base, ...segments);
    if (fs.realpathSync.native(leaf) !== leaf) return { ok: false, at: leaf };
    return { ok: true, at: '' };
  } catch {
    return { ok: false, at: current };
  }
}

// Reads one store entry, or answers null for anything the owner's listRecords would
// refuse to read. Separated from the sweep loop so every refusal arm is reachable
// without arranging a whole store around it: before this, none of the four had ever
// been driven by a test.
//
// `options.noFollow` exists to make the win32 path reachable on a POSIX host. On
// win32 O_NOFOLLOW is unavailable and the flag is 0 — openSync then FOLLOWS a
// symlink and fstat describes the TARGET, so a symlinked entry whose target is a
// valid lease naming the executing root used to be KEPT. The owner disagrees:
// canonicalExisting refuses a symlink with no win32 gate and runs before every
// readRecord, so the sweep was keeping an entry listRecords still rejects — the exact
// wedge it exists to clear, surviving a clean set-aside count. A path-level lstat
// before the open restores the verdict. It does NOT close the TOCTOU that O_NOFOLLOW
// closes; nothing available here can.
function readLeaseEntry(file, options) {
  const settings = options || {};
  // A MODE, never a flag mask. `options.mode` is COMPARED against the one accepted
  // string and never OR-ed into the open, so a caller can only take the STRICTER
  // path — the win32 branch, where O_NOFOLLOW does not exist — and can never widen
  // it. Taking a caller-supplied number verbatim let `O_CREAT` through, which would
  // make this reader CREATE the file it reports unreadable. The repo already pins
  // exactly this shape for plan-payload-v1.js's reader; this is the same rule.
  const noFollow = settings.mode === LSTAT_PRECHECK_MODE
    ? 0
    : (process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW)
      ? fs.constants.O_NOFOLLOW : 0);
  const maxBytes = Number.isInteger(settings.maxBytes) ? settings.maxBytes : MAX_RECORD_BYTES;
  try {
    if (!noFollow && fs.lstatSync(file).isSymbolicLink()) return null;
    // O_NONBLOCK is not optional here, it is the half that stops the hang: O_NOFOLLOW
    // refuses a symlink, but opening a FIFO directly blocks in open(2) itself, before
    // fstat can say what it is.
    const nonBlock = Number.isInteger(fs.constants.O_NONBLOCK) ? fs.constants.O_NONBLOCK : 0;
    const descriptor = fs.openSync(file, fs.constants.O_RDONLY | noFollow | nonBlock);
    try {
      // Decide on the DESCRIPTOR, not the path: the entry can be swapped between an
      // lstat and a read, and holding the fd pins the inode the read will consume.
      const entry = fs.fstatSync(descriptor);
      if (!entry.isFile() || entry.size > maxBytes) return null;
      return JSON.parse(fs.readFileSync(descriptor, 'utf8'));
    } finally {
      fs.closeSync(descriptor);
    }
  } catch {
    return null;
  }
}

// Moves one entry into the set-aside directory. Answers 'moved', 'collision', 'gone'
// or 'failed'.
//
// It is a link/unlink pair rather than a rename because rename(2) REPLACES an
// existing destination silently — so a colliding entry under superseded/<key> was
// destroyed with no report, contradicting the "MOVED (never deleted)" contract this
// sweep is documented under. Seventy lines away the record path already takes the
// opposite decision (COPYFILE_EXCL) for exactly this reason.
//
// A vanished source is 'gone', not 'failed': a .tmp unlinked by its own writer's
// finally block is not a stuck lease, and reporting it as one named a file that no
// longer exists.
function moveAside(sourceFile, targetFile) {
  let sourceStat;
  try {
    sourceStat = fs.lstatSync(sourceFile);
  } catch (error) {
    return error && error.code === 'ENOENT' ? 'gone' : 'failed';
  }
  // The source EXISTS at this point — the lstat above proved it — so an ENOENT from
  // either move primitive is ambiguous between a source that vanished under us and a
  // destination that did. Both arms re-check the source to decide, rather than only
  // the regular-file one.
  const goneOrFailed = () => {
    try {
      fs.lstatSync(sourceFile);
      return 'failed';
    } catch {
      return 'gone';
    }
  };
  if (sourceStat.isSymbolicLink()) {
    // MEASURED, not assumed: linkSync FOLLOWS a symlink on at least macOS, which
    // would hard-link the link's TARGET — possibly a file outside this store —
    // into superseded/ and leave that stray link behind. rename(2) moves the link
    // itself, which is what the sweep wants. The cost is that the collision check
    // becomes a separate lstat, so this one narrow branch carries a TOCTOU the
    // link/unlink pair does not. A symlinked entry is already an anomaly the owner
    // rejects outright, so the exposure is bounded to entries that are being
    // removed anyway.
    try {
      fs.lstatSync(targetFile);
      return 'collision';
    } catch { /* absent — proceed */ }
    try {
      fs.renameSync(sourceFile, targetFile);
      return 'moved';
    } catch (error) {
      return error && error.code === 'ENOENT' ? goneOrFailed() : 'failed';
    }
  }
  try {
    fs.linkSync(sourceFile, targetFile);
  } catch (error) {
    if (error && error.code === 'EEXIST') return 'collision';
    if (error && error.code === 'ENOENT') return goneOrFailed();
    return 'failed';
  }
  try {
    fs.unlinkSync(sourceFile);
  } catch {
    // Both copies now exist. That is stuck, not moved: the store still carries the
    // entry that wedges listRecords.
    return 'failed';
  }
  return 'moved';
}

// Re-checks the destination after the loop. This does NOT close the rename race —
// Node exposes no renameat — but it converts a SILENT redirect of every moved lease
// into the reported outcome the entry script already renders, at one syscall per
// adoption. The residual shrinks from "undetected for the life of the store" to
// "detected at the end of the sweep".
function destinationStillSafe(asideDirectory) {
  try {
    return fs.realpathSync.native(asideDirectory) === asideDirectory;
  } catch {
    return false;
  }
}

// The sweep proper, run with the store's lock already held.
function sweepUnderLock(pluginData, key, executingPluginRoot) {
  const recordsDirectory = path.join(pluginData, ...REVIEW_EVIDENCE_SEGMENTS, 'records', key);
  // The owning module reaches this directory only through ensurePrivateDirectory,
  // which rejects a symlink, an alias and unsafe permissions or ownership. This
  // sweep may only LOOK — repairing would fight the owner — so it re-applies the
  // part that matters before it renames anything: a symlinked or aliased records
  // directory is left ALONE rather than swept through.
  try {
    const stat = fs.lstatSync(recordsDirectory);
    // `unsafe` distinguishes a store this sweep REFUSED to touch from the ordinary
    // "no lease was ever minted" case. Both discard nothing; only one of them is a
    // clean outcome, and the caller must be able to say which. It also names WHICH
    // directory it refused: the two live in different places and have different
    // remedies — `source` is this session's own lease records directory,
    // `destination` the shared `superseded/` one. Reported as a bare true, a planted
    // link at the destination sent the operator to the directory the sweep had just
    // read successfully, and went uninvestigated.
    if (stat.isSymbolicLink() || !stat.isDirectory()) return { discarded: 0, failed: [], unsafe: 'source', unsafeAt: recordsDirectory };
    if (fs.realpathSync.native(recordsDirectory) !== recordsDirectory) {
      return { discarded: 0, failed: [], unsafe: 'source', unsafeAt: recordsDirectory };
    }
  } catch (error) {
    return {
      discarded: 0,
      failed: [],
      unsafe: error && error.code !== 'ENOENT' ? 'source' : '',
      unsafeAt: error && error.code !== 'ENOENT' ? recordsDirectory : '',
    };
  }
  let entries;
  try {
    entries = fs.readdirSync(recordsDirectory);
  } catch (error) {
    // ONE shape on every path — a scalar here would hand the caller `undefined` for
    // both fields and make the reporter throw AFTER the record swap had already
    // succeeded, reporting failure for a completed adoption.
    //
    // NOT the ordinary "no lease was ever minted" case: the lstat guard above has
    // already established that this directory exists, is a real directory and is
    // canonical, and it is what answers ENOENT. What reaches this catch is EACCES,
    // EPERM, EMFILE or a race — a directory that exists and cannot be read, which is
    // precisely the state the caller must not be told was clean.
    return {
      discarded: 0,
      failed: [],
      unsafe: error && error.code === 'ENOENT' ? '' : 'source',
      unsafeAt: error && error.code === 'ENOENT' ? '' : recordsDirectory,
    };
  }
  // Nothing to sweep: return BEFORE the destination guard, so an adoption with an
  // existing-but-empty records directory neither creates superseded/<key> nor can
  // report a destination warning about leases that do not exist.
  if (entries.length === 0) return { discarded: 0, failed: [], unsafe: '', unsafeAt: '' };
  const asideSegments = [...REVIEW_EVIDENCE_SEGMENTS, 'superseded', key];
  const asideDirectory = path.join(pluginData, ...asideSegments);
  let discarded = 0;
  const failed = [];
  // `unsafe` carries the whole diagnosis, exactly as the three source-unsafe returns
  // do. Listing every entry as `failed` here would name leases the keep-branch would
  // have left alone, and the reporter would print two contradictory warnings about
  // the same sweep.
  // The destination chain is created and validated LAZILY, on the first entry that
  // actually needs moving. Running it up front materialized superseded/<key> for a
  // session whose leases are all valid — the same "create nothing for a session that
  // needs nothing" property the no-lease pre-check exists for, one case wider — and
  // let a run that moved nothing still report a destination WARNING.
  let destinationReady = false;
  const ensureDestination = () => {
    if (destinationReady) return { ok: true, at: '' };
    const verdict = asideIsSafe(pluginData, asideSegments, ['superseded']);
    destinationReady = verdict.ok;
    return verdict;
  };
  for (const name of entries.sort()) {
    // EVERY entry listRecords would reject, not only the `.json` ones: it fails the
    // whole set on an unexpected name, so a leftover `.tmp` from a killed lease write
    // wedges it exactly as hard as a stale record would.
    const file = path.join(recordsDirectory, name);
    // An entry that is not a regular file, is larger than the cap listRecords holds
    // its records to, or does not parse, is one that reader would reject anyway — so
    // readLeaseEntry answers null and the entry falls through to the move branch.
    const record = readLeaseEntry(file);
    // An unreadable lease is moved aside too: listRecords would fail on it just as
    // hard, and leaving it would defeat the whole point of this sweep.
    //
    // leaseRecordIsOwned is the owner's own predicate, and it is a SUBSET of what
    // listRecords accepts — stated as a subset because that is what it is. NOT
    // mirrored: that reader also rejects a multiply-linked record file, a
    // non-canonical spelling, and every other validateRecord violation. A symlink and
    // an oversized entry USED to belong on that list and no longer do — the
    // O_NOFOLLOW open and the size cap above send both to the move branch. An entry
    // failing only what is still on that list, while naming the executing root, is
    // therefore KEPT and keeps wedging later lease operations — a residual, not the
    // main gap, because a lease can only name the executing root if that runtime
    // minted it, and none can be minted while the session is unbound.
    //
    // ONE item on that residual list is NOT bounded by that argument, and it is the
    // one to watch: the LEASE SCHEMA. This predicate never looks at `record.schema`
    // or `record.schema_version`, which the owner declares and `readRecord`
    // enforces. So a release that bumps the lease schema is invisible here — every
    // lease naming the executing root is kept, the new reader rejects each one,
    // `listRecords` propagates the first failure, and the session is wedged for
    // review evidence AFTER an adoption that reported `leases set aside : 0`. The
    // session looks repaired and is not. A schema bump is precisely the case where
    // the executing runtime DID mint the record and still cannot read it, so
    // "only the executing runtime could have minted it" does not cover it.
    //
    // This is also where the authorising argument for adoption stops. Schema
    // equality closes itself only for the two documents `validateContext` and
    // `validateWorkflowState` own; it does not close itself for this store, nor —
    // by the same reasoning — for the attestation shape or any strict `exactKeys`
    // validator, both of which the breaking-axis list in CLAUDE.md names. Adding the
    // check means pinning a `LEASE_RECORD_SCHEMA_VERSION` alongside it; it is not
    // done here, and the gap is stated rather than implied.
    if (leaseRecordIsOwned(name, record, executingPluginRoot)) continue;
    // No mkdir here: asideIsSafe() already created AND validated the directory. What
    // that buys is one fewer way to CREATE the target — it does not close the race.
    // link(2) resolves every non-final component, so a link swapped in at
    // asideDirectory after the guard still redirects each move; destinationStillSafe
    // below is what makes such a redirect visible rather than silent.
    //
    // State the residual against what the guard actually establishes. asideIsSafe()
    // refuses a symlinked component anywhere in the chain, so the swap has to happen
    // AFTER it looked — and the leaf it lands in is 0700 and owner-checked. What it
    // does NOT establish is the mode of the shared ancestors, which belong to
    // ensurePrivateDirectory: where those are group-writable the race needs no
    // same-uid access at all. So: bounded by a same-uid attacker on a store whose
    // ancestors are private, unbounded on one where they are not, and never closed
    // either way.
    const destination = ensureDestination();
    if (!destination.ok) {
      // `unsafe` carries the whole diagnosis, exactly as the source-unsafe returns
      // do. Listing every entry as `failed` here would name leases the keep-branch
      // would have left alone.
      return { discarded, failed, unsafe: 'destination', unsafeAt: destination.at };
    }
    const outcome = moveAside(file, path.join(asideDirectory, name));
    if (outcome === 'moved') {
      discarded += 1;
    } else if (outcome !== 'gone') {
      // A lease that could NOT be moved is reported separately, never folded into the
      // success count and never swallowed. Counting only successes would render a
      // partial sweep as a clean adoption while the exact wedge this sweep exists to
      // prevent survives. 'gone' is the one outcome that is neither: the entry is no
      // longer in the store, which is what the sweep wanted, and naming it stuck
      // would point the operator at a file that does not exist.
      failed.push(name);
    }
  }
  // Every return carries the same keys, and `unsafe` is a total string — empty for a
  // clean sweep, `source` or `destination` otherwise. One field, not a boolean plus a
  // scope: the two would be two spellings of one fact, and the "unknown scope" arm a
  // caller wrote for the boolean could never be reached. `unsafeAt` names the
  // offending component when there is one.
  if (destinationReady && !destinationStillSafe(asideDirectory)) {
    return { discarded, failed, unsafe: 'destination', unsafeAt: asideDirectory };
  }
  return { discarded, failed, unsafe: '', unsafeAt: '' };
}

// The public entry point: the sweep, serialized on the lease store's OWN lock.
//
// Every mutating entry point in review-evidence-lease-v1.js runs inside withLock on
// review-evidence/v1/locks/<sessionKey>.lock, and this sweep used to acquire nothing
// — so a concurrent createLease could have the .tmp file it was still writing moved
// out from under it, and the lease creation then failed with ENOENT. The window is
// real rather than theoretical: the adoption releases the records lock before this
// runs, and the session is bound again from that instant.
//
// The owner's withLock is deliberately the one used. The core's withFileLock
// RECLAIMS a stale lock; this store's does not, and importing the core policy here
// would let the sweep unlink a live owner's lock.
//
// Taking that lock runs the owner's storage() constructor, which REFUSES a symlinked
// or aliased store rather than repairing it. That refusal must reach the caller as a
// verdict, never as a throw: this runs AFTER the record swap, so an exception here
// would report failure for an adoption that has already succeeded.
function discardSupersededLeases(pluginData, key, executingPluginRoot) {
  const recordsDirectory = path.join(pluginData, ...REVIEW_EVIDENCE_SEGMENTS, 'records', key);
  // UNLOCKED pre-check, and it is not an optimization. `withLock` runs the owner's
  // storage() CONSTRUCTOR, which ensurePrivateDirectory-creates the store root, this
  // records leaf and the locks directory. Taking the lock unconditionally therefore
  // materialized the whole store for every session that had never minted a lease —
  // and made the source guard's own ENOENT arm unreachable through this entry point,
  // because the directory it tests for absence had just been created by the lock.
  //
  // A store that appears between this check and the lock belongs to a concurrent
  // writer, and its leases are new rather than superseded, so skipping is the right
  // answer for that window too.
  try {
    fs.lstatSync(recordsDirectory);
  } catch (error) {
    if (error && error.code === 'ENOENT') {
      return { discarded: 0, failed: [], unsafe: '', unsafeAt: '' };
    }
    return { discarded: 0, failed: [], unsafe: 'source', unsafeAt: recordsDirectory };
  }
  try {
    // A two-field binding, synthesised rather than obtained from bindWorker. What
    // withLock and storage read IS those two fields today; if a future version reads
    // a third, the throw lands in the catch below and is rendered as a store-shape
    // refusal — a silent MISDIAGNOSIS after the record swap rather than a crash,
    // which is why the narrow owner-side entry point is the real fix.
    return lease.withLock(
      { pluginData, sessionKey: key },
      () => sweepUnderLock(pluginData, key, executingPluginRoot),
    );
  } catch (error) {
    // Distinguish the two throws this catch can see. The owner's storage()
    // constructor refuses a store whose SHAPE is wrong; withLock itself refuses
    // when the lock is held or abandoned. Collapsing both into 'source' sent the
    // operator to inspect a records directory that was fine, and discarded the
    // owner's own remedy sentence — the two have different causes and different
    // fixes, so they get different scopes.
    const message = error && error.message ? String(error.message) : '';
    if (/lock is busy or abandoned/i.test(message)) {
      return { discarded: 0, failed: [], unsafe: 'locked', unsafeAt: '' };
    }
    // Re-probe the records directory so a shape refusal can still NAME the
    // component. storage() throws before sweepUnderLock's own guard can run, so
    // without this the four source returns that collect unsafeAt are unreachable
    // through this entry point and the report prints its generic text.
    let unsafeAt = '';
    try {
      const stat = fs.lstatSync(recordsDirectory);
      if (stat.isSymbolicLink() || !stat.isDirectory()
        || fs.realpathSync.native(recordsDirectory) !== recordsDirectory) {
        unsafeAt = recordsDirectory;
      }
    } catch { /* leave it unnamed rather than guess */ }
    return { discarded: 0, failed: [], unsafe: 'source', unsafeAt };
  }
}

module.exports = {
  asideIsSafe,
  destinationStillSafe,
  discardSupersededLeases,
  moveAside,
  privateEnough,
  readLeaseEntry,
  // Re-exported so a caller that already has this module does not need the owner too
  // just to spell the store's id shape in a message.
  LEASE_ID_RE,
  LSTAT_PRECHECK_MODE,
};
