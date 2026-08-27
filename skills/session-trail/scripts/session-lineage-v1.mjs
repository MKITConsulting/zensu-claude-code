// Session-lineage ledger: the persisted, machine-wide, multi-writer record of
// which session continued which. Extracted from trail.mjs so the schema, the
// read/write pair and the chain walk have one owner with its own unit suite —
// the same shape hooks/lib/chain-recovery-v1.js has, and for the same reason:
// a shape lattice and a refusal table are exactly what a unit layer can pin and
// an end-to-end bash suite cannot.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

// The ledger directory is writable by every session on this machine, so a read is
// as untrusted as a write. A record far above this is not a record.
const MAX_RECORD_BYTES = 256 * 1024;

// Regular files only, size-capped, symlinks refused — trail.mjs bounds its other
// untrusted reads the same way (FULL_READ_LIMIT); the ledger was the exception.
const NOFOLLOW = process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW)
  ? fs.constants.O_NOFOLLOW
  : 0;

// O_RDONLY on a FIFO blocks until a writer opens the other end, and O_NOFOLLOW does
// not change that — so the fstat/isFile assertions below, correct as they are against
// a path swap, cannot protect the OPEN itself: they run after it. The ledger
// directory is writable by every session on this machine, so one planted entry
// wedged every reader on the host with no deadline above it. O_NONBLOCK makes the
// open return immediately and leaves the descriptor-level checks to do their work,
// so the TOCTOU property is kept rather than traded away.
const NONBLOCK = process.platform !== 'win32' && Number.isInteger(fs.constants.O_NONBLOCK)
  ? fs.constants.O_NONBLOCK
  : 0;

// Why a REASON rather than a bare null: five distinct causes — open failure, a
// non-regular entry, a record past the cap, a mid-read error, and (at the caller) a
// JSON syntax error — all reached the reader as one word. The module argues three
// lines above its own refusal table that a record it cannot read for one reason must
// not be reported as another; this is that argument applied to its own reader.
function readBoundedFile(file) {
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | NOFOLLOW | NONBLOCK);
  } catch (e) {
    // ELOOP is O_NOFOLLOW refusing a symlink, ENXIO is O_NONBLOCK refusing a FIFO
    // with no writer: both are "this is not a regular file", not an I/O fault.
    // ENOENT is a third fact again — the entry was listed and is gone — and it is the
    // ordinary outcome of a concurrent `--forget --apply`, not damage.
    const code = e && e.code;
    if (code === 'ELOOP' || code === 'ENXIO') return { text: null, reason: EDGE_REFUSALS.NOT_A_FILE };
    if (code === 'ENOENT') return { text: null, reason: EDGE_REFUSALS.VANISHED };
    return { text: null, reason: EDGE_REFUSALS.UNREADABLE };
  }
  try {
    // fstat, not lstat: the properties are asserted on the descriptor that will
    // actually be read, so a path swapped to a symlink after a check cannot be
    // followed and a file that grows after a check cannot beat the cap.
    const st = fs.fstatSync(fd);
    if (!st.isFile()) return { text: null, reason: EDGE_REFUSALS.NOT_A_FILE };
    if (st.size > MAX_RECORD_BYTES) return { text: null, reason: EDGE_REFUSALS.OVERSIZE };
    const buf = Buffer.allocUnsafe(Math.min(st.size, MAX_RECORD_BYTES));
    let off = 0;
    while (off < buf.length) {
      const n = fs.readSync(fd, buf, off, buf.length - off, off);
      if (n <= 0) break;
      off += n;
    }
    return { text: buf.subarray(0, off).toString('utf8'), reason: null };
  } catch {
    return { text: null, reason: EDGE_REFUSALS.UNREADABLE };
  } finally {
    try { fs.closeSync(fd); } catch { /* the read result is what matters */ }
  }
}

// NOFOLLOW is 0 where the platform lacks it (Windows). Stated rather than
// implied: there the symlink half of this guard does not apply.

// The record shape AND the directory segment. The segment is derived from the
// constant rather than hand-written, so a bump cannot leave the two disagreeing
// — the failure mode that would have made every already-running window read an
// empty directory and report "no handover was ever recorded".
export const LEDGER_SCHEMA_VERSION = 1;

// Every persisted string is bounded at WRITE time and again at READ time —
// endpoints, `reason`, `recordedAt`, `recordedBy` and both `repo` fields. The
// values come from another session's transcript, decoded through a JSON unescape
// that turns \n into a real newline, and they are rendered into numbered chain
// lines a reader acts on. trail.mjs bounds every other third-party value for
// exactly this reason; the ledger adds durable carriers, so it needs the bound
// more, not less.
const FIELD_MAX = 200;
const PATH_MAX = 4096;
const LABEL_MAX = 120;

export function boundText(value, max = FIELD_MAX) {
  if (value === null || value === undefined) return null;
  // Every control and format character, not a three-character denylist: ESC and
  // the rest of C0 survived the old class into a durable record and into a
  // terminal a model then reads back.
  const flat = String(value).replace(/[\p{Cc}\p{Cf}\u2028\u2029\s]+/gu, ' ').trim();
  if (!flat) return null;
  return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
}

export function boundPath(value) {
  if (value === null || value === undefined) return null;
  // Stripped, not replaced by a space: removing the control and format class keeps
  // the SPELLING intact, so a path that survives is the path that was given.
  const flat = String(value).replace(/[\p{Cc}\p{Cf}\u2028\u2029]/gu, '');
  if (!flat || flat.length > PATH_MAX) return null;
  return flat;
}

export function boundLabel(value) {
  return boundText(value, LABEL_MAX);
}

function isNonEmptyString(v) {
  return typeof v === 'string' && v.trim() !== '';
}

// Exactly the spelling `new Date().toISOString()` produces, re-checked through
// `Date.parse` so a rolled-over calendar date is refused rather than silently
// meaning a different day. The SHAPE matters as much as the validity, and that is
// the half `Number.isFinite(Date.parse(...))` alone could not carry: only a
// fixed-width UTC instant makes code-unit order chronological, which is the property
// every comparison in this file rests on. Measured before this landed, with the
// finiteness check as the only guard: `"July 4, 2026"` parsed, sorted ABOVE every
// real stamp, and was actually EARLIER; `"9999"` — the very value the ordering
// comment above names as the motivating defect — was still accepted and outranked
// every record for as long as the append-only store kept it; and
// `"2026-02-31T00:00:00.000Z"` was accepted as a February date meaning 3 March.
//
// The shape and the round-trip together still admitted the far future, which is the
// SAME outcome by a valid spelling: `9999-12-31T23:59:59.999Z` matches, parses, and
// reproduces itself, then outranks every real stamp in a store that only appends —
// permanently, because nothing ever removes it. Only the future is bounded; a ledger
// is mostly history and an old record is not a suspicious one. The skew is a day
// rather than a minute because the value is written by whatever clock the recording
// machine had, and refusing a legitimate handover is the worse of the two errors.
const ISO_INSTANT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
export const MAX_FUTURE_SKEW_MS = 24 * 60 * 60 * 1000;
export function isIsoInstant(value, now = Date.now()) {
  if (typeof value !== 'string' || !ISO_INSTANT.test(value)) return false;
  const t = Date.parse(value);
  if (!Number.isFinite(t) || new Date(t).toISOString() !== value) return false;
  return t <= now + MAX_FUTURE_SKEW_MS;
}

// ONE comparison rule for `recordedAt`, used at every site that orders records.
// There were two: a raw `>` picked the dedupe survivor while `localeCompare` sorted
// the list beside it. `localeCompare` also resolves the host locale, so the order of
// a machine-wide ledger depended on the reader's ICU build — and the values are
// fixed-width UTC ISO stamps, whose code-unit order already IS their chronological
// order. A collator is both the wrong tool and roughly two orders of magnitude slower.
// That premise is ENFORCED rather than assumed: `isIsoInstant` is what refuses any
// other spelling at classification, and without it this comparison silently ranked
// `"July 4, 2026"` above every real stamp.
function recordedAtKey(e) {
  return String((e && e.recordedAt) || '');
}

// Exported because the CLI orders records too, and a rule that only one of two
// files can reach is a rule the other one re-invents — which is exactly what
// happened: a `localeCompare` survived in the consumer and made a machine-wide
// ledger's order depend on the reader's ICU build.
export function byRecordedAtAsc(a, b) {
  const ka = recordedAtKey(a);
  const kb = recordedAtKey(b);
  if (ka < kb) return -1;
  return ka > kb ? 1 : 0;
}

// `repo.name` is printed into the CHAIN header a reader acts on, so it is bounded
// on both sides like every other persisted string — it was the one pair that was
// bounded on neither.
export function normalizeRepo(raw) {
  const r = raw && typeof raw === 'object' ? raw : {};
  return { name: boundText(r.name), root: boundPath(r.root) };
}

export function ledgerPaths(configRoot) {
  const base = path.join(configRoot, 'zensu', 'session-lineage', `v${LEDGER_SCHEMA_VERSION}`);
  return { base, edges: path.join(base, 'edges'), labels: path.join(base, 'labels.json') };
}

// The store lives under `session-lineage/v<schema>/`, so the day the schema moves
// every existing record becomes invisible to the new build — and the empty-ledger
// branch then reads as "nothing was ever recorded" and offers to reconstruct
// GUESSES for handovers the machine still holds as MEASUREMENTS, one directory
// away. This finds those directories so the caller can say so instead.
//
// A directory with no records is NOT reported: an empty `v2/` left behind by a
// rollback would otherwise send the operator hunting for records nobody wrote.
// Counting is bounded by MAX_EDGE_RECORDS for the same reason readEdges is —
// this walks a directory any session on the machine can write.
export function otherSchemaLedgers(configRoot) {
  const base = path.dirname(ledgerPaths(configRoot).base);
  // The level above the two this function already lstats. `readdirSync` follows a
  // symlinked final component, so a link planted at `zensu` or `session-lineage`
  // was enumerated through and its contents rendered as "records this machine
  // already holds". Read-only, but that sentence is what tells an operator NOT to
  // reconstruct — so a planted directory could suppress a legitimate backfill.
  if (!ledgerPathUnlinked(base, configRoot)) return [];
  let names;
  try { names = fs.readdirSync(base); } catch { return []; }
  const out = [];
  for (const name of names) {
    const m = /^v(\d{1,9})$/.exec(name);
    if (!m) continue;
    const version = Number(m[1]);
    if (version === LEDGER_SCHEMA_VERSION) continue;
    const versionDir = path.join(base, name);
    const edges = path.join(versionDir, 'edges');
    let records;
    // BOTH components are lstat'ed, and that is the whole point. Checking only the
    // leaf left the level above open: `lstat` declines to follow the FINAL
    // component only, so a symlink planted at `v0` was resolved as an ordinary
    // intermediate component and its `edges/` enumerated through it. The count
    // reported here becomes an instruction the operator acts on, and the config
    // root is writable by every session on the machine.
    try {
      const vs = fs.lstatSync(versionDir);
      if (vs.isSymbolicLink() || !vs.isDirectory()) continue;
      const es = fs.lstatSync(edges);
      if (es.isSymbolicLink() || !es.isDirectory()) continue;
      // STREAMED, not materialized. This enumeration used to build an array holding
      // every name in a directory the comment above calls writable by every session on
      // the machine — and it now runs on every `lineage` invocation rather than only on
      // an empty store, because the disclosure it feeds must not decay. `opendirSync`
      // walks the same entries in constant memory. The COUNT is deliberately still the
      // true one: the note beside `records` argues that a bounded number rendered as a
      // complete one is the failure to avoid, and streaming keeps that argument intact
      // while removing the allocation it did not need.
      const dir = fs.opendirSync(edges);
      records = 0;
      try {
        for (let ent = dir.readSync(); ent !== null; ent = dir.readSync()) {
          const f = ent.name;
          if (f.endsWith('.json') && !f.startsWith('.')) records += 1;
        }
      } finally {
        try { dir.closeSync(); } catch { /* the count is what matters */ }
      }
    } catch { continue; }
    if (!records) continue;
    out.push({
      version,
      dir: edges,
      // The TRUE count, plus a flag — the clamp bounded only the number reported
      // while the enumeration above was unbounded, so it constrained nothing and
      // rendered a bounded answer as a complete one. `readEdges` reports its own
      // cap the same way, and for the reason stated there.
      records,
      truncated: records > MAX_EDGE_RECORDS,
      // Named rather than inferred by the caller: "older" means this build can be
      // taught to read it, "newer" means it cannot and the plugin is behind.
      relation: version < LEDGER_SCHEMA_VERSION ? 'older' : 'newer',
    });
  }
  return out.sort((a, b) => a.version - b.version);
}

// Refused rather than created when any component is a symlink or a non-directory.
// The store is machine-wide and every session can write the config root, so a
// symlink planted at the leaf would redirect every record AND take the chmod with
// it — fs.chmodSync follows links, and there is no lchmod on Linux. This mirrors
// review-evidence-lease-v1.js's ensurePrivateDirectory. Deliberate DELTA, stated
// rather than implied: that function also re-lstats after chmod and rejects a
// group/other-readable mode, a foreign uid and an aliased realpath. The first of
// those IS carried here — the re-lstat and the mode test are below — so only the
// foreign-uid and aliased-realpath checks are genuinely absent; this guard covers
// the symlink, non-directory and mode half. The check-then-create ordering still
// leaves a window a local attacker with write access to the config root could race.
export function ensureLedgerDir(edgesDir, stopAt = null) {
  // Bounded ABOVE by the root the caller named. Climbing past it inspected
  // directories the user never chose — and on macOS /var is a symlink, so a config
  // root under it made every write fail permanently while blaming the ledger.
  const parts = [];
  let cur = edgesDir;
  const ceiling = stopAt ? path.resolve(stopAt) : null;
  for (let i = 0; i < 8 && cur && cur !== path.dirname(cur); i += 1) {
    // The ceiling is the root the CALLER named — the trust anchor, not a candidate.
    // Checking it too refused a config root that is itself a symlink, which is the
    // ordinary shape under a dotfile manager: every takeover, adopt and label then
    // failed while the read side reported "no handover has been recorded yet".
    // A swapped `~/.claude` would redirect the registry, the transcripts and the
    // handoffs as well, none of which this module guards; the leaf components below
    // it are what it can meaningfully defend.
    if (ceiling && path.resolve(cur) === ceiling) break;
    parts.unshift(cur);
    cur = path.dirname(cur);
  }
  for (const p of parts) {
    let st;
    try {
      st = fs.lstatSync(p);
    } catch (e) {
      // ENOENT is the ordinary "not created yet" case and the whole reason this loop
      // tolerates a gap. EACCES and ELOOP are not: there the check did NOT happen,
      // and continuing would mkdir having proven nothing about the path.
      if (e && e.code === 'ENOENT') continue;
      throw new Error(`could not check ledger path component ${p}: ${(e && e.code) || 'unknown'}`);
    }
    if (st.isSymbolicLink()) throw new Error(`refusing to use a symlinked ledger path: ${p}`);
    if (!st.isDirectory()) throw new Error(`ledger path exists and is not a directory: ${p}`);
  }
  fs.mkdirSync(edgesDir, { recursive: true, mode: 0o700 });
  // Windows has no meaningful mode equivalent and fs.chmodSync is inert there.
  // Stated rather than implied: on Windows the records inherit the user profile's
  // ACLs, which is the whole of their confidentiality.
  if (process.platform !== 'win32') {
    fs.chmodSync(edgesDir, 0o700);
    // chmodSync SUCCEEDING is not evidence the mode took. On a filesystem that
    // ignores POSIX modes — SMB/CIFS, exFAT, many synced-folder mounts, all
    // reachable through `--config-dir` — this call is a silent no-op, and so is
    // `mode: 0o600` on every record written below it. The records then carry session
    // ids, account identifiers, worktree paths and branch names at world-readable
    // permissions with no error and no disclosure anywhere. Re-reading the mode is
    // the only thing that notices, and it is also the one detection the documented
    // check-then-create window would ever get.
    const st = fs.lstatSync(edgesDir);
    if (st.isSymbolicLink()) throw new Error(`refusing to use a symlinked ledger path: ${edgesDir}`);
    if ((st.mode & 0o077) !== 0) {
      throw new Error(`refusing a group/other-accessible ledger directory: ${edgesDir} is ${(st.mode & 0o777).toString(8)}`);
    }
  }
}

// No ':' anywhere — legal on POSIX, forbidden on Windows, so an ISO timestamp in
// the name would make every edge unwritable there. crypto over Math.random costs
// nothing and removes the question entirely.
export function edgeFileName(now) {
  return `${now}-${crypto.randomBytes(8).toString('hex')}.json`;
}

// `nameFor` is injectable for the same reason `now` is: the exclusivity contract is
// otherwise untestable, because the production generator appends 64 bits of
// randomness and a collision cannot be provoked. Production callers pass nothing.
export function writeEdge(edgesDir, edge, now, stopAt = null, nameFor = edgeFileName) {
  ensureLedgerDir(edgesDir, stopAt);
  const body = `${JSON.stringify(edge, null, 2)}\n`;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const file = path.join(edgesDir, nameFor(now));
    // Written to a temp and LINKED into place, never renamed. Both keep the property
    // the temp exists for — a concurrent reader never sees a zero-byte record — but
    // `rename` REPLACES an existing destination silently, so the EEXIST retry below
    // could only ever fire on the temp name, which carries the pid plus 48 bits and
    // does not collide. `link` fails EEXIST on the DESTINATION, which is the name the
    // loop and its terminal message are actually about.
    const tmp = path.join(edgesDir, `.edge-${process.pid}-${crypto.randomBytes(6).toString('hex')}.tmp`);
    try {
      fs.writeFileSync(tmp, body, { flag: 'wx', mode: 0o600 });
    } catch (e) {
      // A temp-name collision is the one case worth another attempt; anything else
      // (ENOSPC, EACCES) will not improve by retrying. Either way nothing landed.
      if (e && e.code === 'EEXIST') continue;
      throw e;
    }
    try {
      fs.linkSync(tmp, file);
      return file;
    } catch (e) {
      if (!(e && e.code === 'EEXIST')) throw e;
      // Destination taken — try a fresh name.
    } finally {
      // Unlinked on EVERY path, not only after a failed landing. A write that died
      // between create and land used to orphan its temp permanently: `readEdges`
      // skips dot-prefixed names, so nothing ever counted it and nothing swept it.
      try { fs.unlinkSync(tmp); } catch { /* best effort — the operation's result stands */ }
    }
  }
  throw new Error(`could not create a unique edge record in ${edgesDir}`);
}

// Every component from `dir` up to `stopAt`, refused if any of them is a symlink.
// The WRITE path has always done this; the read and delete paths checked the LEAF
// only, and `lstat` declines to follow the final component alone — so a symlink at
// `session-lineage/` or `v1/` was resolved as an ordinary intermediate component.
// Reproduced end to end before this existed: `lineage --forget --apply` unlinked a
// record OUTSIDE the ledger directory and reported no error at all.
//
// Returns a boolean rather than throwing, because both callers already have a
// refusal channel of their own and a throw there would abort a whole command.
// Without a ceiling it checks nothing above the directory itself — the caller owns
// how far up the tree it is entitled to look, exactly as `ensureLedgerDir` does.
export function ledgerPathUnlinked(dir, stopAt = null) {
  const ceiling = stopAt ? path.resolve(stopAt) : null;
  let cur = path.resolve(dir);
  // Without a ceiling this checks the directory ITSELF and climbs no further, which
  // is the old leaf-only behaviour and is deliberate: on macOS `/var` is a symlink,
  // so an unbounded climb from a temp-rooted config directory refuses every store
  // under it. `ensureLedgerDir` bounds its own walk for exactly this reason. A
  // caller that wants the ancestors checked must say where its tree begins.
  if (!ceiling) {
    try { return !fs.lstatSync(cur).isSymbolicLink(); } catch (e) { return !!(e && e.code === 'ENOENT'); }
  }
  for (let hop = 0; hop < 64; hop += 1) {
    // The ceiling is tested FIRST, so it is a bound on the walk and never a
    // candidate for it — exactly as `ensureLedgerDir` breaks before pushing the
    // ceiling into its checked set, and for the identical reason its comment gives:
    // a config root that is itself a symlink is the ordinary shape under a dotfile
    // manager, and it is the root the CALLER named, i.e. the trust anchor.
    //
    // Judging it here made the two halves disagree about one tree: the write path
    // kept landing records while this one answered ESYMLINK, so `lineage --forget`
    // — the only way a machine-wide record ever leaves — was permanently
    // unavailable exactly where records kept arriving.
    if (ceiling && cur === ceiling) return true;
    let st;
    try { st = fs.lstatSync(cur); } catch (e) {
      // ENOENT is the ordinary "not created yet" case and says nothing about links.
      if (e && e.code === 'ENOENT') { /* keep climbing */ } else return false;
    }
    if (st && st.isSymbolicLink()) return false;
    const up = path.dirname(cur);
    if (up === cur) return true;
    cur = up;
  }
  return false;
}

// A single path COMPONENT, and nothing more is asserted. The names this guards
// come from `readEdges`, which took them from `readdirSync` — but this is the one
// operation in the store that destroys evidence, so the input is re-checked rather
// than trusted, which is what keeps a crafted `../` from being normalised into an
// unlink outside the ledger. Deliberately NOT matched against the write-side name
// shape: a record that landed under any other spelling is still a record the
// operator is entitled to forget, and refusing it would leave standing exactly the
// un-retractable edge the removal path exists to remove.
export function isEdgeFileName(name) {
  if (typeof name !== 'string' || name === '') return false;
  if (!name.endsWith('.json') || name.startsWith('.')) return false;
  // No control or format character, for the same reason `boundText` strips them
  // from every persisted field: this name is RENDERED into the destructive verb's
  // output, three times, and a POSIX name may contain a newline. The dry run is
  // where an operator decides whether to run `--apply`, so a name able to add a
  // line to it can describe a removal that is not about to happen.
  if (/[\p{Cc}\p{Cf}]/u.test(name)) return false;
  return path.basename(name) === name;
}

// Reports its failures rather than throwing on the first one: a directory holding
// ten matching records must not keep the other nine because one of them is already
// gone, and the caller has to be able to say how many actually went.
// Residual, stated rather than implied, exactly as `ensureLedgerDir` states its
// own: the ancestor check runs ONCE and each iteration then re-derives the path
// with `path.join`, so a directory component swapped for a symlink after the guard
// resolves through the new link. The per-file `lstat`+`unlink` pair is safe on its
// own — `unlink` never follows a final symlink — so the exposure is the directory
// swap, not the leaf. Node exposes no `unlinkat`/dirfd, so it cannot be closed in
// this shape.
export function removeEdgeFiles(edgesDir, names, stopAt = null) {
  const removed = [];
  const failed = [];
  // Checked ONCE, before any unlink: `path.join` resolves through a symlinked
  // ancestor, so without this the loop below deletes files in the link target.
  if (!ledgerPathUnlinked(edgesDir, stopAt)) {
    return { removed, failed: names.map((n) => ({ file: String(n), reason: 'ledger-path-unsafe' })) };
  }
  for (const name of names) {
    if (!isEdgeFileName(name)) { failed.push({ file: String(name), reason: 'name-refused' }); continue; }
    const file = path.join(edgesDir, name);
    try {
      // lstat, never stat, and a symlink is REFUSED rather than unlinked. Removing
      // the link would report a record destroyed while the file it names survives,
      // and `readBoundedFile` opens O_NOFOLLOW — so a symlink here was never a
      // record this ledger could read in the first place.
      const st = fs.lstatSync(file);
      if (!st.isFile()) { failed.push({ file: name, reason: 'not-a-file' }); continue; }
      fs.unlinkSync(file);
      removed.push(name);
    } catch (e) {
      failed.push({ file: name, reason: (e && e.code) || 'unknown' });
    }
  }
  return { removed, failed };
}

// The endpoint shape has ONE constructor, applied to both slots of every edge.
// Two hand-kept producers would let the `to` shape depend on which command wrote
// the record, and every renderer would then degrade silently on the odd one.
export function makeEndpoint(input) {
  const src = input || {};
  return {
    // Bounded like every other field. These two were the exception, and their
    // provenance is a FILENAME and a DIRECTORY NAME — neither validated at source.
    sessionId: boundText(src.sessionId, 128),
    accountUuid: boundText(src.accountUuid, 128),
    appPid: Number.isFinite(src.appPid) ? src.appPid : null,
    pid: Number.isFinite(src.pid) ? src.pid : null,
    worktree: boundPath(src.worktree),
    branch: boundText(src.branch),
  };
}

// `title` and `cwd` are deliberately NOT persisted. Every renderer that consumes a
// stored endpoint — printChain, `lineage --where`, the `instances` lineage column —
// reads sessionId, worktree, branch, appPid and pid; neither of those two was read
// anywhere. They were also the two most sensitive fields in the record: a session
// title summarises what someone was working on and can name a client, and `cwd` is
// finer-grained than `worktree`. Both originate in another session's transcript, and
// this store is durable, machine-wide and outside every repository — so keeping an
// unread copy bought nothing and cost exactly the disclosure this feature is careful
// about everywhere else. `repo.root` still carries the location a reader needs.

export const ENDPOINT_KEYS = Object.freeze(Object.keys(makeEndpoint({})));

// How much the ledger is entitled to claim for one edge, weakest first. It is an
// ORDER, not a label: `dedupeEdges` and `walkChain` rank by it BEFORE `recordedAt`,
// which is the whole point. `inferred` was carried for a while as a boolean that
// every renderer displayed and no decision consulted — and because `--backfill`
// stamps each guess with the moment `--apply` ran, one backfill then promoted
// guesses above measurements at every site that orders by time.
//
// `provisional` exists because generating a takeover brief is not the same event as
// having taken the session over: the brief is written before the human has decided,
// so `takeover` may claim only that much. `--force` carries the user's approval on
// the command line, and `adopt` is the confirmation verb, so both reach `confirmed`.
export const CONFIDENCE_ORDER = Object.freeze(['inferred', 'provisional', 'confirmed']);
// What a record with no readable tier becomes. NOT the floor: a record written
// before this field existed, or by a caller not yet taught the tier, came from
// takeover or adopt — backfill is the one producer that sets `inferred`. Demoting it
// to a guess would let any tier-carrying record displace a real handover; promoting
// it to `confirmed` would claim an approval nobody gave.
const CONFIDENCE_DEFAULT = 'provisional';

// Total, and an unknown value ranks at the FLOOR rather than throwing: the value
// arrives from a machine-wide record any session can write, and a tier nobody
// recognises must never outrank one that is recognised.
export function confidenceRank(value) {
  const i = CONFIDENCE_ORDER.indexOf(value);
  return i === -1 ? 0 : i;
}

export function normalizeConfidence(value, inferred) {
  if (CONFIDENCE_ORDER.includes(value)) return value;
  // A record written before this field existed, or one carrying a value this build
  // does not know: fall back to what the legacy boolean can still tell us.
  // Fails toward GUESS. An omitted marker is not evidence of a measurement, and this
  // store is writable by every local process, so "said nothing" must not outrank a
  // record that honestly declared itself inferred. A legacy record that explicitly
  // says `inferred: false` still gets the default; one that says nothing does not.
  if (inferred === true) return 'inferred';
  return inferred === false ? CONFIDENCE_DEFAULT : 'inferred';
}

export function buildEdge({ from, to, workRoot, repoRootOf, reason, recordedBy, inferred, confidence, at }) {
  const root = workRoot ? (repoRootOf(workRoot) || workRoot) : null;
  const tier = normalizeConfidence(confidence, inferred);
  return {
    schemaVersion: LEDGER_SCHEMA_VERSION,
    from: makeEndpoint(from),
    to: makeEndpoint(to),
    repo: normalizeRepo({ name: root ? path.basename(root) : null, root }),
    reason: boundText(reason) || 'manual',
    confidence: tier,
    // Kept, and DERIVED from the tier rather than from the caller, so the two can
    // never disagree in a persisted record. A reader on an older build still sees
    // the boolean it understands.
    inferred: tier === 'inferred',
    recordedAt: at,
    recordedBy: boundText(recordedBy),
  };
}

// Refusal reasons are distinct on purpose: a record this build cannot read
// because the schema moved is a different fact from a corrupt one, and blaming
// the ledger for a version skew sends the reader looking in the wrong place.
export const EDGE_REFUSALS = Object.freeze({
  // An I/O fault: the open failed for a reason that is not about the file's TYPE,
  // or the read itself died part-way.
  UNREADABLE: 'unreadable',
  // Not a regular file — a directory, a device, a symlink O_NOFOLLOW refused, or a
  // FIFO O_NONBLOCK refused. Distinct from UNREADABLE because the remedy differs:
  // something was PLANTED here, rather than something being wrong with the disk.
  NOT_A_FILE: 'not-a-file',
  // Listed by the directory scan and gone by the open. This is the NORMAL case for
  // the concurrency model the store is built for — `--forget --apply` unlinks records
  // while other windows read — so it is not counted as a refusal at all. Reported as
  // UNREADABLE it entered `refused`, and a non-empty `refused` blocks
  // `--backfill --apply`: one window's routine cleanup made an unrelated backfill in
  // another window refuse and write nothing. The reason is NAMED rather than folded
  // into the exclusion so the branch that drops it says what it is dropping; no
  // consumer counts it, and none needs to — a race is not a finding.
  VANISHED: 'vanished',
  // Past MAX_RECORD_BYTES. The store is machine-wide, so this is a bound being
  // enforced, not a fault — and a user seeing it should look at the record, not the
  // permissions.
  OVERSIZE: 'oversize',
  // Read fine, did not parse. The one cause that means the WRITER was at fault.
  CORRUPT: 'corrupt',
  SCHEMA_NEWER: 'schema-newer',
  SCHEMA_OLDER: 'schema-older',
  MALFORMED: 'malformed',
});

// Each record is capped at MAX_RECORD_BYTES; nothing capped how MANY were
// enumerated, read and parsed. In a directory every session on this machine can
// write, that is an unbounded multiplier on a bounded quantity — and chainRoots then
// re-walks per root over the same attacker-chosen count. The cap is reported through
// `truncated` rather than applied silently, because a bounded answer that reads as a
// complete one is the failure this module exists to avoid.
export const MAX_EDGE_RECORDS = 20000;

export function classifyEdge(raw) {
  if (!raw || typeof raw !== 'object') return { ok: false, reason: EDGE_REFUSALS.MALFORMED };
  if (!Number.isFinite(raw.schemaVersion)) return { ok: false, reason: EDGE_REFUSALS.MALFORMED };
  if (raw.schemaVersion !== LEDGER_SCHEMA_VERSION) {
    return {
      ok: false,
      reason: raw.schemaVersion > LEDGER_SCHEMA_VERSION ? EDGE_REFUSALS.SCHEMA_NEWER : EDGE_REFUSALS.SCHEMA_OLDER,
    };
  }
  // TYPE, not truthiness. Every renderer calls `.toLowerCase()` / `.slice()` on
  // these, and there is no top-level handler — one hand-written record with a
  // number here took `lineage`, `--where` and `instances` down with an uncaught
  // TypeError and lost the buffered output with them.
  if (!raw.from || !raw.to || !isNonEmptyString(raw.from.sessionId) || !isNonEmptyString(raw.to.sessionId)) {
    return { ok: false, reason: EDGE_REFUSALS.MALFORMED };
  }
  // And re-assert on the NORMALIZED value, because the two bounds disagree about
  // what is empty. `isNonEmptyString` uses `trim()`, which strips WhiteSpace and
  // LineTerminator only, so a lone "\u0000" survives it; `boundText` then replaces
  // the whole Cc/Cf class and trims to empty, yielding null. Judging the raw half
  // alone shipped an edge whose sessionId was null straight into the renderers
  // this guard exists to protect.
  const from = makeEndpoint(raw.from);
  const to = makeEndpoint(raw.to);
  if (!from.sessionId || !to.sessionId) {
    return { ok: false, reason: EDGE_REFUSALS.MALFORMED };
  }
  // A session is not its own continuation. Every producer already refuses to write
  // one, so such a record can only be foreign or hand-written — which is precisely
  // the case this function exists to judge. Left accepted it rendered as a non-zero
  // handover count above an empty chain: chainRoots promotes it to a root, walkChain
  // filters it out through `seen`, and the renderer skips the empty link list.
  if (from.sessionId === to.sessionId) {
    return { ok: false, reason: EDGE_REFUSALS.MALFORMED };
  }
  // `recordedAt` selects the dedupe survivor, the branch the walk prefers and the
  // `--where` answer, and it was the one persisted field with no judgement at all.
  // An unparseable stamp sorts by code unit, so "9999" outranked every ISO value
  // for as long as the append-only store kept it.
  const recordedAt = boundText(raw.recordedAt);
  if (!isIsoInstant(recordedAt)) {
    return { ok: false, reason: EDGE_REFUSALS.MALFORMED };
  }
  return {
    ok: true,
    // CLOSED, never a spread. The spread admitted any key an untrusted record
    // carried — unbounded up to MAX_RECORD_BYTES — straight into the `links` array
    // that `lineage --where --json` emits verbatim and a model then reads.
    edge: {
      schemaVersion: raw.schemaVersion,
      from,
      to,
      repo: normalizeRepo(raw.repo),
      reason: boundText(raw.reason) || 'manual',
      confidence: normalizeConfidence(raw.confidence, raw.inferred),
      // Coerced on the way IN as well as on the way out: `"no"` and `0` are both
      // truthy-adjacent spellings that a bare read would have judged wrongly.
      inferred: normalizeConfidence(raw.confidence, raw.inferred) === 'inferred',
      recordedAt,
      recordedBy: boundText(raw.recordedBy),
    },
  };
}

// `directoryError` is reported separately from a per-record refusal: an
// unreadable DIRECTORY must never render as "nothing was recorded".
// `max` is a seam for the unit layer, never a caller policy: the DIRECTION of the
// slice below is the whole property, and planting MAX_EDGE_RECORDS+1 files to observe
// it would cost twenty thousand writes on a Windows shard this suite already saturates.
// `listNames` is the second unit seam, for the same reason `writeEdge` already accepts
// `nameFor`: winning the race against a real unlink is not reproducible, while the
// behaviour that matters — a real open, a real ENOENT, the classification and the
// exclusion below — is exercised end to end once the listing can be chosen.
export function readEdges(edgesDir, stopAt = null, max = MAX_EDGE_RECORDS, listNames = fs.readdirSync) {
  const edges = [];
  const refused = [];
  if (!ledgerPathUnlinked(edgesDir, stopAt)) {
    return { edges, refused, directoryError: 'ESYMLINK', truncated: false };
  }
  let names;
  try {
    names = listNames(edgesDir);
  } catch (e) {
    if (e && e.code === 'ENOENT') return { edges, refused, directoryError: null, truncated: false };
    return { edges, refused, directoryError: e && e.code ? e.code : 'EUNKNOWN', truncated: false };
  }
  // Sorted before the cap so the bound is deterministic rather than whatever order
  // the filesystem happened to hand back.
  //
  // And sliced from the TAIL. `edgeFileName` prefixes every record with `Date.now()`,
  // so ascending order is chronological and taking the HEAD retained the twenty
  // thousand OLDEST records: past the cap every new handover became invisible to
  // `lineage`, `--where`, `instances` and — the half with no recovery — `--forget`,
  // while `writeEdge` went on succeeding. `--backfill --apply` could not repair it
  // either, because it refuses on `truncated`.
  // The name must be a single path COMPONENT. With the default listing that holds
  // structurally, and the filter below was equivalent; once the listing can be
  // supplied, `path.join` would normalise a crafted `../` OUT of the ledger, and
  // `readBoundedFile`'s O_NOFOLLOW binds the final component only. An escaping name is
  // REPORTED rather than dropped, because it is the one shape an operator must see.
  //
  // Deliberately NOT the full `isEdgeFileName`: that predicate also refuses control
  // characters, for the destructive verb's RENDERING, and its own comment says a record
  // under any other spelling is still one the operator is entitled to forget. Applying
  // it here hid such a record from `--forget` — the reader's job is to find records,
  // not to judge how they were named.
  const usable = [];
  // The escape test runs BEFORE the dot-name skip, because `../x.json` begins with a
  // dot: checked the other way round, the one shape this guard exists for is the one
  // shape it silently drops.
  for (const n of names) {
    if (typeof n !== 'string' || !n.endsWith('.json')) continue;
    if (path.basename(n) !== n) { refused.push({ file: n, reason: EDGE_REFUSALS.NOT_A_FILE }); continue; }
    if (n.startsWith('.')) continue;
    usable.push(n);
  }
  const candidates = usable.sort();
  // The seam may only TIGHTEN. Unclamped, a caller could pass a larger `max` and remove
  // the cap entirely — on a directory the comment above MAX_EDGE_RECORDS describes as
  // writable by every session on this machine. Same rule as the plan reader's
  // `openMode`: a caller can take the stricter path, never widen it.
  const cap = Number.isInteger(max) && max >= 0 ? Math.min(max, MAX_EDGE_RECORDS) : MAX_EDGE_RECORDS;
  const truncated = candidates.length > cap;
  // Not `slice(-max)`: a max of 0 makes that `slice(0)`, which returns EVERYTHING —
  // the one input where the shorthand inverts the bound it is spelling.
  for (const n of candidates.slice(Math.max(0, candidates.length - cap))) {
    let raw;
    const read = readBoundedFile(path.join(edgesDir, n));
    if (read.text === null) {
      // A vanished record is a race, not a refusal: counting it would block
      // `--backfill --apply` on another window's ordinary cleanup.
      if (read.reason !== EDGE_REFUSALS.VANISHED) refused.push({ file: n, reason: read.reason });
      continue;
    }
    try { raw = JSON.parse(read.text); } catch {
      refused.push({ file: n, reason: EDGE_REFUSALS.CORRUPT });
      continue;
    }
    const verdict = classifyEdge(raw);
    if (!verdict.ok) { refused.push({ file: n, reason: verdict.reason }); continue; }
    edges.push({ ...verdict.edge, file: n });
  }
  edges.sort(byRecordedAtAsc);
  return { edges, refused, directoryError: null, truncated };
}

// Collapsed at READ time, never at write time: the store stays an append-only
// event log, but a user asking "how many handovers" means distinct handovers, and
// re-running `takeover` is a documented, routine step.
export function dedupeEdges(edges) {
  const bySide = new Map();
  for (const e of edges) {
    // JSON-encoded, not `from>to`: `>` survives boundText, so two different pairs
    // could spell one key and the loser vanished from every count and every line.
    const key = JSON.stringify([e.from.sessionId, e.to.sessionId]);
    const prev = bySide.get(key);
    if (!prev || outranks(e, prev)) bySide.set(key, e);
  }
  return [...bySide.values()].sort(byRecordedAtAsc);
}

// Confidence FIRST, recency second. Ordering by time alone let a `--backfill` guess
// — always stamped with the moment `--apply` ran — supersede a real handover.
function outranks(candidate, incumbent) {
  const dc = confidenceRank(candidate.confidence) - confidenceRank(incumbent.confidence);
  if (dc !== 0) return dc > 0;
  return recordedAtKey(candidate) > recordedAtKey(incumbent);
}

// The ledger is a GRAPH, so the walk reports forks instead of dropping them. The
// `seen` set and the hop bound are the termination guarantee: a mistaken pair of
// edges can describe a cycle, and a wrong answer is recoverable where a hang is
// not. When a node has several unvisited successors the walk follows the LATEST
// and records the others, because "where is this now" wants the newest branch.
// The successor index, built ONCE. `walkChain` rebuilt it on every call, and
// `chainRoots` calls `walkChain` per root — so a ledger filled to MAX_EDGE_RECORDS,
// which any session on this machine can do, made `lineage` quadratic in the record
// count. The cap bounds how many records are READ; it never bounded what is done
// with them. Measured before this: 315 ms at n=2000, 1669 ms at n=5000, which puts
// the cap's own 20 000 at roughly 27 s.
// The buckets are ORDERED here, once, rather than at every hop. `walkChain` re-sorted
// and re-copied the successor list of the node it stood on at each step, and
// `chainWalks` runs one walk per root — so many roots leading into one hub with many
// successors paid for one sorted pass per root over the same bucket. Ordering at build
// time is one pass per bucket for the whole render, and it leaves the ordering RULE in
// a single place: the walk below only filters.
export function successorOrder(a, b) {
  return (confidenceRank(b.confidence) - confidenceRank(a.confidence)) || byRecordedAtAsc(b, a);
}

export function indexBySource(edges) {
  const byFrom = new Map();
  for (const e of edges) {
    if (!byFrom.has(e.from.sessionId)) byFrom.set(e.from.sessionId, []);
    byFrom.get(e.from.sessionId).push(e);
  }
  for (const bucket of byFrom.values()) bucket.sort(successorOrder);
  return byFrom;
}

// `index` is optional and defaults to building one, so every existing caller keeps
// working unchanged; a caller that walks repeatedly over ONE edge set passes it.
// `source` is EITHER an edge array or a prebuilt `indexBySource` map — one
// parameter, never a pair. The signature carried both, and once an index was
// supplied the `edges` argument was dead code: a caller could hand it an array and
// an index built from a DIFFERENT set, and the walk followed the index without a
// word. Two parameters describing one thing is the seam; taking either spelling of
// the one thing closes it while keeping the reason the index existed, which is that
// the caller avoids one rebuild per root.
// PRECONDITION on the Map branch: the buckets must already be in `successorOrder`. The
// walk stopped sorting when `indexBySource` started, so a Map from any other producer
// yields a differently-ordered chain and nothing here can notice. Every caller in this
// tree passes either an array or a Map this module built; a future one must do the same.
export function walkChain(sessionId, source, maxHops = 64) {
  const byFrom = source instanceof Map ? source : indexBySource(source || []);
  const links = [];
  const forks = [];
  const seen = new Set([sessionId]);
  let revisited = false;
  let cur = sessionId;
  for (let hop = 0; hop < maxHops; hop += 1) {
    // Already ordered by `indexBySource` — confidence first, then newest, the same
    // order dedupeEdges applies, so the chain a reader is shown and the record that
    // survives cannot disagree. `filter` preserves it, so no hop sorts.
    const outgoing = byFrom.get(cur) || [];
    const candidates = outgoing.filter((e) => !seen.has(e.to.sessionId));
    // A revisit is what the FILTER did, not where the walk stopped. Assigned only in
    // the terminal arm below, the flag reported a revisit exclusively when the revisit
    // was the last option: A>B, B>A, B>C answered false, because B also led on and the
    // dropped edge appears in neither `candidates` nor `forks`. Measured at this hop it
    // also survives the hop-bound exit, which never reaches that arm at all.
    if (candidates.length !== outgoing.length) revisited = true;
    if (!candidates.length) {
      // WHY the walk stopped is the whole point. "No unseen successor" has two very
      // different causes: the chain genuinely ended, or it led back into a node this
      // walk refuses to revisit — the shape the documented reset flow produces
      // (adopt A>B, then adopt B>A from the original window). Reported as an ordinary
      // end, the renderer printed CONTINUED IN <b> with no caveat while the newest
      // edge in the ledger said the work had come back.
      revisited = revisited || outgoing.some((e) => seen.has(e.to.sessionId));
      break;
    }
    const [next, ...rest] = candidates;
    if (rest.length) forks.push({ at: cur, taken: next.to.sessionId, alsoTo: rest.map((e) => e.to.sessionId) });
    links.push(next);
    seen.add(next.to.sessionId);
    cur = next.to.sessionId;
  }
  // Surfaced, not swallowed: a chain cut at the bound must not render as complete.
  // Computed from what the walk actually LEFT BEHIND, not from the link count:
  // `links.length >= maxHops` was true for a chain of exactly maxHops links that
  // ended naturally, and for maxHops 0 with an empty walk — both made the renderer
  // claim a complete answer was "longer than shown".
  const remaining = (byFrom.get(cur) || []).some((e) => !seen.has(e.to.sessionId));
  return { links, forks, truncated: remaining, revisited };
}

// A cycle makes every `from` also a `to`, which yields no roots at all — and a
// non-zero handover count rendered above no chain is worse than a wrong chain.
// Every session not reachable from a computed root therefore becomes a root of
// its own, so a cycle renders as something rather than as silence.
// No index parameter, for the same reason, and here the pair was worse than dead:
// `edges` decides which roots exist while the index decides where each chain goes,
// so a disagreeing pair returns roots from one set and chains from the other. The
// index is built HERE instead. That is one extra O(n) pass per render next to the
// caller's own — not the per-root rebuild R10 removed, which was the quadratic
// term. Deriving the array back out of a map was the alternative and is rejected:
// flattening groups edges by source key, and the DISCOVERY ORDER of roots is the
// order chains render in.
// Returns the roots AND the walk it already performed for each one. The walks were
// computed here to decide coverage and then thrown away, so every caller re-walked
// the same edges from the same roots — each chain traversed twice. The wasted pass
// is the small half. The shape is the half that bites: the root DECISION and the
// RENDERED chain were independent traversals of the same data, so a change to
// `walkChain`'s branch preference could make them disagree about which chain a root
// even has, with nothing in either function able to notice.
export function chainWalks(edges) {
  const byFrom = indexBySource(edges);
  const targets = new Set(edges.map((e) => e.to.sessionId));
  const roots = [];
  // A Set beside the list, not `roots.includes(...)`: the membership test ran inside
  // a loop over every edge, so it was the second quadratic term after the per-root
  // re-index. The LIST is still what is returned, because the order roots are
  // discovered in is the order chains render in.
  const seenRoot = new Set();
  for (const e of edges) {
    if (!targets.has(e.from.sessionId) && !seenRoot.has(e.from.sessionId)) {
      seenRoot.add(e.from.sessionId);
      roots.push(e.from.sessionId);
    }
  }
  const walks = new Map();
  const covered = new Set();
  const take = (root) => {
    covered.add(root);
    const walk = walkChain(root, byFrom);
    walks.set(root, walk);
    for (const l of walk.links) covered.add(l.to.sessionId);
  };
  for (const r of roots) take(r);
  for (const e of edges) {
    if (!covered.has(e.from.sessionId)) {
      roots.push(e.from.sessionId);
      take(e.from.sessionId);
    }
  }
  return { roots, walks };
}

// `chainRoots` keeps the name and the array shape for callers that only need the
// decision; `chainWalks` is what a caller uses instead of re-walking.
export function chainRoots(edges) {
  return chainWalks(edges).roots;
}

// Two namespaces, tagged, because the keys are different kinds of thing: an
// account UUID is stable, an OS pid is reused after its process exits. One flat
// map made a pid-keyed label silently rename an unrelated window later, and left
// no way to tell the two apart in the file.
export function emptyLabels() {
  // Null-prototype maps: a key named `constructor` or `__proto__` would otherwise
  // resolve to an inherited member and render it as an account's identity.
  return { schemaVersion: LEDGER_SCHEMA_VERSION, accounts: Object.create(null), windows: Object.create(null) };
}

export function labelsSchemaMismatch(raw) {
  return !!raw && typeof raw === 'object' && !Array.isArray(raw)
    && raw.schemaVersion !== undefined && raw.schemaVersion !== LEDGER_SCHEMA_VERSION;
}

export function normalizeLabels(raw) {
  const out = emptyLabels();
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return out;
  // Judged, not merely written: the edges have a refusal table and the labels
  // document advertised a version nothing read. Reported as a MISMATCH rather than
  // reduced to an empty map — an empty map is what the writer then overwrites with.
  if (labelsSchemaMismatch(raw)) return out;
  const accounts = raw.accounts && typeof raw.accounts === 'object' ? raw.accounts : {};
  const windows = raw.windows && typeof raw.windows === 'object' ? raw.windows : {};
  // The KEY is bounded too, and an out-of-shape one is dropped rather than stored.
  // Values went through boundLabel from the start; keys did not, so an oversized one
  // round-tripped through read -> normalize -> write indefinitely. Once labels.json
  // crossed MAX_RECORD_BYTES the reader refused it permanently: every label silently
  // disappeared from every rendered chain, and `label` failed from then on with
  // "move it aside and re-run". Normalisation cannot heal a file it does not bound.
  for (const [k, v] of Object.entries(accounts)) {
    const key = boundLabel(k);
    const bounded = boundLabel(v);
    if (key && bounded) out.accounts[key] = bounded;
  }
  for (const [k, v] of Object.entries(windows)) {
    const key = boundLabel(k);
    const bounded = boundLabel(v);
    if (key && bounded) out.windows[key] = bounded;
  }
  return out;
}

// Landed by rename over an O_EXCL temp in the same directory. The plain
// truncating write this replaces was the one write in the store that ignored the
// discipline the edge records were given: two concurrent labels lost one
// silently, and a crash mid-write left JSON that the reader swallows into "no
// labels at all".
// Split in three so the CHECKED window can be the rename alone. Everything expensive —
// the directory walk and the whole temp write — happens in `stageLabels`, outside it.
//
// None of the three is exported. `stageLabels` derives its temp path from `labelsFile`,
// so within this module no caller can name the rename source or the unlink target,
// which is the confinement the single `writeLabels` had by construction; exporting them
// would hand out an unconfined rename and an unconfined unlink with both operands
// caller-supplied. `writeLabels` remains the composed public writer, and `updateLabels`'
// `stage` seam is what the unit layer injects instead of reaching for a part.
function stageLabels(labelsFile, labels, stopAt = null) {
  // The base directory, not a reconstructed edges path: `ledgerPaths` owns the
  // layout, and writing a label used to create `edges/` as a side effect.
  ensureLedgerDir(path.dirname(labelsFile), stopAt);
  const tmp = path.join(path.dirname(labelsFile), `.labels-${process.pid}-${crypto.randomBytes(6).toString('hex')}.tmp`);
  fs.writeFileSync(tmp, `${JSON.stringify(labels, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
  return tmp;
}

// `removeEdgeFiles`, the module's other destructive verb, spends three checks to avoid
// handing out an unconfined unlink; these two avoid it by staying private instead.
function discardStagedLabels(tmp) {
  try { fs.unlinkSync(tmp); } catch { /* whatever brought us here is the real error */ }
}

function commitLabels(tmp, labelsFile) {
  try {
    fs.renameSync(tmp, labelsFile);
  } catch (e) {
    discardStagedLabels(tmp);
    throw e;
  }
}

export function writeLabels(labelsFile, labels, stopAt = null) {
  commitLabels(stageLabels(labelsFile, labels, stopAt), labelsFile);
}

// Owns the WHOLE read-modify-write, which is what `writeLabels` alone could not.
// `writeLabels` landed atomically but replaced the entire document, and the read that
// produced its argument happened in the caller — so two windows labelling two
// different accounts lost one of them. A lost label is not a missing answer: the map
// still resolves the PREVIOUS name and renders it with exactly the confidence a
// correct one gets, while the process that lost the update printed success and
// exited 0.
//
// The retry is bounded and the check is the file's identity plus size, read
// immediately before the landing — and "immediately" is now literal. It used to be
// read before `writeLabels`, which then ran `ensureLedgerDir` and a full temp write
// before reaching its rename, so a writer landing anywhere in that span was
// overwritten silently while the loser printed success and exited 0. Staging happens
// FIRST and the check sits between it and the rename, which is the only step left
// inside the window. This is still not a lock — two writers can interleave between the
// check and the rename — but the span is now a single syscall, and an update that
// cannot be landed is REPORTED rather than silently dropped.
//
// `stage` is injectable because it IS the window: a test that interferes from `mutate`
// reaches only the half the check already caught.
export function updateLabels(labelsFile, mutate, stopAt = null, attempts = 5, stage = stageLabels) {
  for (let i = 0; i < attempts; i += 1) {
    const before = labelsFingerprint(labelsFile);
    // The ceiling this function already holds. readLabels' guard is CONDITIONAL, so
    // omitting it here performed no ancestor check at all — and readBoundedFile's
    // O_NOFOLLOW covers the final component only, which is the exact gap the walk
    // exists to close. The write half below was already bounded, so the two halves
    // of one read-modify-write disagreed about the same tree.
    const current = readLabels(labelsFile, stopAt);
    if (current.unreadable) throw new Error(`refusing to overwrite an unreadable labels file: ${labelsFile}`);
    if (current.schemaMismatch) throw new Error(`refusing to overwrite a labels file from another schema: ${labelsFile}`);
    const next = mutate(current.labels);
    const staged = stage(labelsFile, next, stopAt);
    if (labelsFingerprint(labelsFile) !== before) {
      // Someone landed first — redo on their copy, and take our unpublished temp file
      // with us rather than leaving it in a machine-wide directory.
      discardStagedLabels(staged);
      continue;
    }
    commitLabels(staged, labelsFile);
    return next;
  }
  throw new Error(`could not land a labels update in ${attempts} attempts — another window kept writing`);
}

function labelsFingerprint(labelsFile) {
  try {
    const st = fs.statSync(labelsFile);
    return `${st.ino}:${st.size}:${st.mtimeMs}`;
  } catch {
    return 'absent';
  }
}

// `stopAt` is the same ceiling `readEdges` and `removeEdgeFiles` take, and this
// reader needs it for the same reason: `readBoundedFile`'s O_NOFOLLOW declines the
// FINAL component alone, so a symlink at `session-lineage/` or `v1/` was resolved as
// an ordinary intermediate component. Its own WRITER already refuses that tree —
// `writeLabels` goes through `ensureLedgerDir` — so without this the two halves
// disagreed about the same directory, and the labels rendered into every window's
// output could be sourced from outside the 0700 tree.
export function readLabels(labelsFile, stopAt = null) {
  if (stopAt && !ledgerPathUnlinked(path.dirname(labelsFile), stopAt)) {
    return { labels: emptyLabels(), unreadable: true, schemaMismatch: false };
  }
  if (!fs.existsSync(labelsFile)) return { labels: emptyLabels(), unreadable: false, schemaMismatch: false };
  const read = readBoundedFile(labelsFile);
  if (read.text === null) return { labels: emptyLabels(), unreadable: true, schemaMismatch: false };
  let parsed;
  try { parsed = JSON.parse(read.text); } catch { return { labels: emptyLabels(), unreadable: true, schemaMismatch: false }; }
  return { labels: normalizeLabels(parsed), unreadable: false, schemaMismatch: labelsSchemaMismatch(parsed) };
}

// A closed shape, because this value becomes a path component. `..` normalises
// out of the store, and the probe returns the first matching account directory —
// so an always-present path would make one account answer for every session, and
// that answer is then persisted as provenance.
const HOST_SESSION_ID_SHAPE = /^[A-Za-z0-9._-]{1,128}$/;

export function isSafeHostSessionId(value) {
  if (typeof value !== 'string' || !HOST_SESSION_ID_SHAPE.test(value)) return false;
  return value !== '.' && value !== '..' && !value.includes('..');
}
