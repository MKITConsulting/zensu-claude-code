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
const NOFOLLOW = process.platform !== "win32" && Number.isInteger(fs.constants.O_NOFOLLOW)
  ? fs.constants.O_NOFOLLOW
  : 0;

function readBoundedFile(file) {
  let fd;
  try { fd = fs.openSync(file, fs.constants.O_RDONLY | NOFOLLOW); } catch { return null; }
  try {
    // fstat, not lstat: the properties are asserted on the descriptor that will
    // actually be read, so a path swapped to a symlink after a check cannot be
    // followed and a file that grows after a check cannot beat the cap.
    const st = fs.fstatSync(fd);
    if (!st.isFile() || st.size > MAX_RECORD_BYTES) return null;
    const buf = Buffer.allocUnsafe(Math.min(st.size, MAX_RECORD_BYTES));
    let off = 0;
    while (off < buf.length) {
      const n = fs.readSync(fd, buf, off, buf.length - off, off);
      if (n <= 0) break;
      off += n;
    }
    return buf.subarray(0, off).toString('utf8');
  } catch {
    return null;
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

export function boundLabel(value) {
  return boundText(value, LABEL_MAX);
}

function isNonEmptyString(v) {
  return typeof v === 'string' && v.trim() !== '';
}

// `repo.name` is printed into the CHAIN header a reader acts on, so it is bounded
// on both sides like every other persisted string — it was the one pair that was
// bounded on neither.
export function normalizeRepo(raw) {
  const r = raw && typeof raw === 'object' ? raw : {};
  return { name: boundText(r.name), root: boundText(r.root) };
}

export function ledgerPaths(configRoot) {
  const base = path.join(configRoot, 'zensu', 'session-lineage', `v${LEDGER_SCHEMA_VERSION}`);
  return { base, edges: path.join(base, 'edges'), labels: path.join(base, 'labels.json') };
}

// The partition above is what makes this necessary. When LEDGER_SCHEMA_VERSION moves
// to 2, `readEdges` opens `.../v2/edges`, gets a clean ENOENT, and returns the
// deliberate "absent is not an error" empty result -- so every recorded handover
// reads as "no handover has been recorded yet", and the empty-state arm then offers
// to reconstruct the lost history as GUESSES. That is the one wrong answer this
// feature exists to prevent, delivered by an ordinary plugin upgrade rather than by
// any rare condition.
//
// This does NOT migrate anything. It reports that records exist one directory over,
// so the empty answer is disclosed instead of silent. Migration is still the open
// decision; being wrong out loud is the part that could not wait for it.
export function siblingLedgerVersions(configRoot) {
  const root = path.join(configRoot, 'zensu', 'session-lineage');
  const mine = `v${LEDGER_SCHEMA_VERSION}`;
  let names;
  try { names = fs.readdirSync(root); } catch { return []; }
  const found = [];
  for (const n of names) {
    if (n === mine || !/^v\d+$/.test(n)) continue;
    let count = 0;
    try {
      for (const f of fs.readdirSync(path.join(root, n, 'edges'))) {
        if (f.endsWith('.json') && !f.startsWith('.')) count += 1;
      }
    } catch { continue; }
    if (count > 0) found.push({ version: n, records: count });
  }
  // Newest first, so a reader sees the most likely source of the missing history at
  // the top rather than having to scan an arbitrary directory order.
  return found.sort((a, b) => Number(b.version.slice(1)) - Number(a.version.slice(1)));
}

// Refused rather than created when any component is a symlink or a non-directory.
// The store is machine-wide and every session can write the config root, so a
// symlink planted at the leaf would redirect every record AND take the chmod with
// it — fs.chmodSync follows links, and there is no lchmod on Linux. This mirrors
// review-evidence-lease-v1.js's ensurePrivateDirectory. Deliberate DELTA, stated
// rather than implied: that function also re-lstats after chmod and rejects a
// group/other-readable mode, a foreign uid and an aliased realpath. Those three
// are NOT carried here — this guard covers the symlink and non-directory half
// only, and the check-then-create ordering leaves a window a local attacker with
// write access to the config root could race.
export function ensureLedgerDir(edgesDir, stopAt = null) {
  // Bounded ABOVE by the root the caller named. Climbing past it inspected
  // directories the user never chose — and on macOS /var is a symlink, so a config
  // root under it made every write fail permanently while blaming the ledger.
  const parts = [];
  let cur = edgesDir;
  const ceiling = stopAt ? path.resolve(stopAt) : null;
  for (let i = 0; i < 8 && cur && cur !== path.dirname(cur); i += 1) {
    parts.unshift(cur);
    if (ceiling && path.resolve(cur) === ceiling) break;
    cur = path.dirname(cur);
  }
  for (const p of parts) {
    let st;
    try { st = fs.lstatSync(p); } catch { continue; }
    if (st.isSymbolicLink()) throw new Error(`refusing to use a symlinked ledger path: ${p}`);
    if (!st.isDirectory()) throw new Error(`ledger path exists and is not a directory: ${p}`);
  }
  fs.mkdirSync(edgesDir, { recursive: true, mode: 0o700 });
  // Windows has no meaningful mode equivalent and fs.chmodSync is inert there.
  // Stated rather than implied: on Windows the records inherit the user profile's
  // ACLs, which is the whole of their confidentiality.
  if (process.platform !== 'win32') fs.chmodSync(edgesDir, 0o700);
}

// No ':' anywhere — legal on POSIX, forbidden on Windows, so an ISO timestamp in
// the name would make every edge unwritable there. crypto over Math.random costs
// nothing and removes the question entirely.
export function edgeFileName(now) {
  return `${now}-${crypto.randomBytes(8).toString('hex')}.json`;
}

export function writeEdge(edgesDir, edge, now, stopAt = null) {
  ensureLedgerDir(edgesDir, stopAt);
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const file = path.join(edgesDir, edgeFileName(now));
    try {
      // Landed by rename, like the labels file: a plain create-then-write leaves a
      // zero-byte window in which a concurrent reader counts a spurious unreadable
      // record and tells the user the output is incomplete.
      const tmp = path.join(edgesDir, `.edge-${process.pid}-${crypto.randomBytes(6).toString('hex')}.tmp`);
      fs.writeFileSync(tmp, `${JSON.stringify(edge, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
      try {
        fs.renameSync(tmp, file);
      } catch (e2) {
        try { fs.unlinkSync(tmp); } catch { /* the rename failure is the real error */ }
        throw e2;
      }
      return file;
    } catch (e) {
      if (e && e.code === 'EEXIST') continue;
      throw e;
    }
  }
  throw new Error(`could not create a unique edge record in ${edgesDir}`);
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
    cwd: boundText(src.cwd),
    worktree: boundText(src.worktree),
    branch: boundText(src.branch),
    title: boundText(src.title),
  };
}

export const ENDPOINT_KEYS = Object.freeze(Object.keys(makeEndpoint({})));

// `repoRoot` is derived from the HANDED-OVER work, never from the recording
// process's directory. The documented takeover route runs from a window in a
// different repo, so filing the edge under the recorder's repo made the default,
// repo-scoped `lineage` render nothing in the repo where the work actually lives
// — an empty answer indistinguishable from "no handover happened", which is the
// one wrong answer this feature exists to prevent.
export function buildEdge({ from, to, workRoot, repoRootOf, reason, recordedBy, inferred, at }) {
  const root = workRoot ? (repoRootOf(workRoot) || workRoot) : null;
  return {
    schemaVersion: LEDGER_SCHEMA_VERSION,
    from: makeEndpoint(from),
    to: makeEndpoint(to),
    repo: normalizeRepo({ name: root ? path.basename(root) : null, root }),
    reason: boundText(reason) || 'manual',
    inferred: inferred === true,
    recordedAt: at,
    recordedBy: boundText(recordedBy),
  };
}

// Refusal reasons are distinct on purpose: a record this build cannot read
// because the schema moved is a different fact from a corrupt one, and blaming
// the ledger for a version skew sends the reader looking in the wrong place.
export const EDGE_REFUSALS = Object.freeze({
  UNREADABLE: 'unreadable',
  SCHEMA_NEWER: 'schema-newer',
  SCHEMA_OLDER: 'schema-older',
  MALFORMED: 'malformed',
});

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
  return {
    ok: true,
    edge: {
      ...raw,
      from,
      to,
      repo: normalizeRepo(raw.repo),
      reason: boundText(raw.reason) || 'manual',
      recordedAt: boundText(raw.recordedAt),
      recordedBy: boundText(raw.recordedBy),
    },
  };
}

// `directoryError` is reported separately from a per-record refusal: an
// unreadable DIRECTORY must never render as "nothing was recorded".
export function readEdges(edgesDir) {
  const edges = [];
  const refused = [];
  let names;
  try {
    names = fs.readdirSync(edgesDir);
  } catch (e) {
    if (e && e.code === 'ENOENT') return { edges, refused, directoryError: null };
    return { edges, refused, directoryError: e && e.code ? e.code : 'EUNKNOWN' };
  }
  for (const n of names) {
    if (!n.endsWith('.json') || n.startsWith('.')) continue;
    let raw;
    const text = readBoundedFile(path.join(edgesDir, n));
    if (text === null) { refused.push({ file: n, reason: EDGE_REFUSALS.UNREADABLE }); continue; }
    try { raw = JSON.parse(text); } catch {
      refused.push({ file: n, reason: EDGE_REFUSALS.UNREADABLE });
      continue;
    }
    const verdict = classifyEdge(raw);
    if (!verdict.ok) { refused.push({ file: n, reason: verdict.reason }); continue; }
    edges.push({ ...verdict.edge, file: n });
  }
  edges.sort((a, b) => String(a.recordedAt || '').localeCompare(String(b.recordedAt || '')));
  return { edges, refused, directoryError: null };
}

// Collapsed at READ time, never at write time: the store stays an append-only
// event log, but a user asking "how many handovers" means distinct handovers, and
// re-running `takeover` is a documented, routine step.
export function dedupeEdges(edges) {
  const bySide = new Map();
  for (const e of edges) {
    const key = `${e.from.sessionId}>${e.to.sessionId}`;
    const prev = bySide.get(key);
    if (!prev || String(e.recordedAt || '') > String(prev.recordedAt || '')) bySide.set(key, e);
  }
  return [...bySide.values()].sort((a, b) => String(a.recordedAt || '').localeCompare(String(b.recordedAt || '')));
}

// The ledger is a GRAPH, so the walk reports forks instead of dropping them. The
// `seen` set and the hop bound are the termination guarantee: a mistaken pair of
// edges can describe a cycle, and a wrong answer is recoverable where a hang is
// not. When a node has several unvisited successors the walk follows the LATEST
// and records the others, because "where is this now" wants the newest branch.
export function walkChain(sessionId, edges, maxHops = 64) {
  const byFrom = new Map();
  for (const e of edges) {
    if (!byFrom.has(e.from.sessionId)) byFrom.set(e.from.sessionId, []);
    byFrom.get(e.from.sessionId).push(e);
  }
  const links = [];
  const forks = [];
  const seen = new Set([sessionId]);
  let cur = sessionId;
  for (let hop = 0; hop < maxHops; hop += 1) {
    const candidates = (byFrom.get(cur) || [])
      .filter((e) => !seen.has(e.to.sessionId))
      .sort((a, b) => String(b.recordedAt || '').localeCompare(String(a.recordedAt || '')));
    if (!candidates.length) break;
    const [next, ...rest] = candidates;
    if (rest.length) forks.push({ at: cur, taken: next.to.sessionId, alsoTo: rest.map((e) => e.to.sessionId) });
    links.push(next);
    seen.add(next.to.sessionId);
    cur = next.to.sessionId;
  }
  // Surfaced, not swallowed: a chain cut at the bound must not render as complete.
  return { links, forks, truncated: links.length >= maxHops };
}

// A cycle makes every `from` also a `to`, which yields no roots at all — and a
// non-zero handover count rendered above no chain is worse than a wrong chain.
// Every session not reachable from a computed root therefore becomes a root of
// its own, so a cycle renders as something rather than as silence.
export function chainRoots(edges) {
  const targets = new Set(edges.map((e) => e.to.sessionId));
  const roots = [];
  for (const e of edges) {
    if (!targets.has(e.from.sessionId) && !roots.includes(e.from.sessionId)) roots.push(e.from.sessionId);
  }
  const covered = new Set();
  for (const r of roots) {
    covered.add(r);
    for (const l of walkChain(r, edges).links) covered.add(l.to.sessionId);
  }
  for (const e of edges) {
    if (!covered.has(e.from.sessionId)) {
      roots.push(e.from.sessionId);
      covered.add(e.from.sessionId);
      for (const l of walkChain(e.from.sessionId, edges).links) covered.add(l.to.sessionId);
    }
  }
  return roots;
}

// Two namespaces, tagged, because the keys are different kinds of thing: an
// account UUID is stable, an OS pid is reused after its process exits. One flat map
// left no way to tell the two apart in the file, so an account UUID and a pid could
// collide outright.
//
// What the split does NOT fix, stated because the older wording here read as if it
// did: reuse INSIDE the `windows` namespace. A pid is reused once its process exits,
// nothing reaps a `windows` entry, and `endpointLabel` resolves a PERSISTED endpoint's
// appPid through the CURRENT labels file -- so a label assigned today renames a
// handover recorded months ago whose appPid happens to match. Pid reuse rewrites
// history here rather than only the present, and it bites hardest exactly where the
// desktop store is unreachable, because there the pid is not the fallback route to a
// name, it is the only one. Qualifying the key with a process identity is the fix and
// is not implemented; the residual is named in CLAUDE.md rather than left in a comment
// that claims it away.
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
  for (const [k, v] of Object.entries(accounts)) {
    const bounded = boundLabel(v);
    if (bounded) out.accounts[k] = bounded;
  }
  for (const [k, v] of Object.entries(windows)) {
    const bounded = boundLabel(v);
    if (bounded) out.windows[k] = bounded;
  }
  return out;
}

// Landed by rename over an O_EXCL temp in the same directory. The plain
// truncating write this replaces was the one write in the store that ignored the
// discipline the edge records were given: two concurrent labels lost one
// silently, and a crash mid-write left JSON that the reader swallows into "no
// labels at all".
export function writeLabels(labelsFile, labels, stopAt = null) {
  // The base directory, not a reconstructed edges path: `ledgerPaths` owns the
  // layout, and writing a label used to create `edges/` as a side effect.
  ensureLedgerDir(path.dirname(labelsFile), stopAt);
  const tmp = path.join(path.dirname(labelsFile), `.labels-${process.pid}-${crypto.randomBytes(6).toString('hex')}.tmp`);
  fs.writeFileSync(tmp, `${JSON.stringify(labels, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
  try {
    fs.renameSync(tmp, labelsFile);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch { /* the rename failure is the real error */ }
    throw e;
  }
}

export function readLabels(labelsFile) {
  if (!fs.existsSync(labelsFile)) return { labels: emptyLabels(), unreadable: false, schemaMismatch: false };
  const raw = readBoundedFile(labelsFile);
  if (raw === null) return { labels: emptyLabels(), unreadable: true, schemaMismatch: false };
  let parsed;
  try { parsed = JSON.parse(raw); } catch { return { labels: emptyLabels(), unreadable: true, schemaMismatch: false }; }
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
