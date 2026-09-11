'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const floor = require('./verify-navigation-floor-v1.js');

const CONSENT_MATCHER = 'mcp__(plugin_zensu_)?playwright__browser_(navigate|tabs)';
const NAVIGATION_TOOL_RE = /^mcp__(plugin_zensu_)?playwright__browser_(navigate|tabs)$/;
const MEMORY_VERSION = 1;
const MEMORY_NAME_PREFIX = 'verify-consent-';
const MEMORY_NAME_RE = new RegExp(`^${MEMORY_NAME_PREFIX}scv1_[a-f0-9]{64}\\.json$`);
const MAX_MEMORY_BYTES = 65536;
const MAX_RECORDS = 512;
// The vocabulary names what the recorder can OBSERVE, never what a human did. PostToolUse
// carries no evidence that anyone answered a prompt, so `prompt` claimed more than the record
// could establish — a reader of the report Consent block took it as "a person approved this
// origin" when it meant "the pre hook would have asked". `asked` states the raised prompt and
// nothing beyond it.
const DECIDED_BY = Object.freeze(['asked', 'remembered', 'policy-mode']);
// The EXECUTION MARKER's own verdict vocabulary, owned once the way DECIDED_BY owns the memory's.
// It was hand-spelled at seven sites — the writer's coercion, both validators, the weakest-verdict
// selector, the caller's ternary and, across a process boundary, the doctor probe and its shell
// suites — for a two-value set whose sibling field already had an owner. The WEAKEST member is
// NAMED rather than taken by index, because the doctor's row prefers it so a declined prompt is
// disclosed, and an index would break silently on a reorder.
const EVIDENCE_VERDICT_ALLOWED = 'allowed';
const EVIDENCE_VERDICT_WEAKEST = 'asked';
const EVIDENCE_VERDICTS = Object.freeze([EVIDENCE_VERDICT_ALLOWED, EVIDENCE_VERDICT_WEAKEST]);

const REASONS = Object.freeze({
  NOT_A_NAVIGATION: 'not-a-navigation',
  POLICY_MODE: 'policy-mode',
  MEMORY_HIT: 'origin-in-session-memory',
  NEW_ORIGIN: 'new-origin-needs-consent',
  REMOTE_NEEDS_POLICY: `remote-target-needs-parent-environment-policy: ${floor.CONSENT_REMOTE_REASON}`,
  PAYLOAD_UNREADABLE: 'hook-payload-unreadable',
  TARGET_UNREADABLE: 'navigation-target-unreadable',
  MEMORY_UNREADABLE: 'consent-memory-unreadable',
  MEMORY_PATH_REFUSED: 'consent-memory-path-refused',
  EVIDENCE_PATH_REFUSED: 'consent-evidence-path-refused',
});

// Attached only to the denies a foreign server can actually cause — the origin
// classification and the remote refusal. A payload fault or a crashed hook is not
// explained by this note, and a deny that guesses at its own cause sends the reader after
// the wrong thing. The remedy is deliberately ONE: launching with a navigation policy
// would turn this gate off for every target, including the remote ones the floor exists to
// refuse, which under this note's own premise leaves nothing behind it.
const FOREIGN_SERVER_NOTE = 'This gate matches on the tool name alone, and the bare mcp__playwright__ spelling belongs to any MCP server keyed "playwright". If this navigation is not a /zensu:verify-feature run, the tool is served by a different server and this refusal is not about your request: the remedy is to rename that server key, which is the user\'s own configuration to change — ask them, and never edit an MCP server configuration on their behalf to widen what this gate allows.';

// Derived from the floor's own vocabulary rather than hand-listed, so a reason added there
// carries the note without an edit here and a reason removed there cannot leave a dead arm.
function foreignServerNoteApplies(reason) {
  if (typeof reason !== 'string' || !reason) return false;
  if (reason.startsWith('remote-target-needs-parent-environment-policy')) return true;
  return Object.values(floor.FLOOR_REASONS).includes(reason);
}

function payloadFromRaw(raw, accumulationFailed) {
  if (accumulationFailed) return null;
  // An empty read is the likeliest fault, not an empty object: the wrapper's
  // "$(cat 2>/dev/null || true)" turns a stdin failure into "". Parsing that as {}
  // produced a payload with no tool_name, which the decider allowed silently.
  if (typeof raw !== 'string' || raw.trim() === '') return null;
  try {
    return JSON.parse(raw);
  } catch (_error) {
    return null;
  }
}

function targetOf(toolName, toolInput) {
  if (typeof toolName !== 'string' || !NAVIGATION_TOOL_RE.test(toolName)) return null;
  const input = toolInput && typeof toolInput === 'object' ? toolInput : {};
  if (/browser_navigate$/.test(toolName)) {
    return typeof input.url === 'string' ? input.url : null;
  }
  if (input.action === 'new' && typeof input.url === 'string' && input.url) return input.url;
  return null;
}

// targetOf answers null for two different things, and only one of them is benign: an ordinary
// tab operation genuinely is not a navigation, while a call the matcher accepts in a shape
// contracted to carry a URL is a navigation whose target could not be read. Without this
// separation both produced allow/not-a-navigation, preEnvelope returned null, and the hook
// wrote nothing — which the host reads as allow. It is deliberately SHAPE-based rather than
// "the target is null", so the discrimination survives a change to targetOf.
function navigationExpected(toolName, toolInput) {
  if (typeof toolName !== 'string' || !NAVIGATION_TOOL_RE.test(toolName)) return false;
  if (/browser_navigate$/.test(toolName)) return true;
  const input = toolInput && typeof toolInput === 'object' ? toolInput : {};
  return input.action === 'new';
}

function normalizeRoutes(declaredRoutes) {
  if (!Array.isArray(declaredRoutes)) return [];
  const routes = [];
  for (const route of declaredRoutes) {
    const normalized = floor.normalizeRoute(route);
    if (normalized !== null && !routes.includes(normalized)) routes.push(normalized);
  }
  return routes;
}

// Date.parse accepts "July 4, 2026" and "2026-02-31T00:00:00.000Z", so validity is not the
// same question as shape. Same SHAPE rule, and the same reason, as isIsoInstant in
// skills/session-trail/scripts/session-lineage-v1.mjs: a stamp only orders correctly for the
// fixed-width UTC spelling toISOString() produces, which is the only spelling this module
// writes. Not the same PREDICATE — that owner additionally bounds the future against
// MAX_FUTURE_SKEW_MS, which this copy deliberately omits because nothing here orders on the
// stamp: records are appended and deduped on (origin, route), so a future stamp costs an
// audit line its true time and changes no decision.
const ISO_INSTANT_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

// TOTAL by construction: the regex admits two digits per field, so `9999-99-99T99:99:99.999Z`
// matches the shape and produces an invalid Date, and `toISOString()` raises RangeError on one.
// Every caller here is a guard over a session-writable file, and two of them sit outside any
// enclosing try — a throw there escaped `liveEvidenceOrigins` entirely, so one planted marker
// made the broker answer `unjudged` and refuse EVERY loopback origin in the project, naming a
// plugin-tree fault that had not occurred. A predicate is not a guard if it can throw.
function isIsoInstant(value) {
  if (typeof value !== 'string' || !ISO_INSTANT_RE.test(value)) return false;
  try { return new Date(value).toISOString() === value; }
  catch (_error) { return false; }
}

// The record's route is deliberately judged more loosely than a DECLARED route, and the
// two are not the same question. A declared route is recipe-authored and must be glob-free,
// which is why floor.normalizeRoute refuses "*". A record's route is whatever the URL parser
// produced for a navigation that already happened, so applying the stricter rule here would
// refuse to record a real visit to a path containing "*" — and a route that cannot be
// recorded asks again on every navigation. What the looser rule must never do is reach a
// human unbounded, which is why promptRoute bounds it at the render.
function validRecord(record) {
  return record && typeof record === 'object'
    && typeof record.origin === 'string' && record.origin.length > 0
    && typeof record.route === 'string' && record.route.startsWith('/')
    && DECIDED_BY.includes(record.decidedBy)
    && isIsoInstant(record.at);
}

function emptyMemory() {
  return { version: MEMORY_VERSION, records: [] };
}

function readMemory(memoryPath) {
  if (typeof memoryPath !== 'string' || !memoryPath) return { ok: true, records: [], absent: true };
  let info;
  try { info = fs.lstatSync(memoryPath); }
  catch (error) {
    if (error && error.code === 'ENOENT') return { ok: true, records: [], absent: true };
    return { ok: false, reason: REASONS.MEMORY_UNREADABLE, records: [] };
  }
  if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1 || info.size > MAX_MEMORY_BYTES) {
    return { ok: false, reason: REASONS.MEMORY_UNREADABLE, records: [] };
  }
  let parsed;
  try { parsed = JSON.parse(fs.readFileSync(memoryPath, 'utf8')); }
  catch (_error) { return { ok: false, reason: REASONS.MEMORY_UNREADABLE, records: [] }; }
  if (!parsed || typeof parsed !== 'object' || parsed.version !== MEMORY_VERSION || !Array.isArray(parsed.records)
      || parsed.records.length > MAX_RECORDS || !parsed.records.every(validRecord)) {
    return { ok: false, reason: REASONS.MEMORY_UNREADABLE, records: [] };
  }
  return { ok: true, records: parsed.records, absent: false };
}

function memoryPathAllowed(memoryPath, projectRoot) {
  return statePathAllowed(memoryPath, projectRoot, MEMORY_NAME_RE);
}

// The containment rule the consent memory has always applied, taken as a parameter so the
// execution-evidence marker beside it cannot drift into a second, weaker copy of it. Only the
// NAME shape differs between the two artifacts; the directory, the component checks and the
// leaf rules are one implementation.
// The REASON is a parameter because the two artifacts are different files: reporting an
// evidence-path fault as `consent-memory-path-refused` names the wrong file class and sends the
// reader to inspect the memory path for a fault in the marker path.
//
// `refuseHardLink` is a parameter for a reason the memory half does not share. Both writers
// publish by `renameSync`, which repoints a NAME and never truncates the linked inode, so the
// conjunct defends nothing the rename has not already closed — while one `ln` in this
// session-writable directory would make every later write fail. For the MEMORY that is a lost
// record; for the EVIDENCE marker it is a permanent refusal of every loopback navigation, which
// is a worse outcome than the write it was meant to guard. CLAUDE.md records the identical
// decision for the zen-mode marker writers. The memory keeps its pre-existing behaviour rather
// than being changed under a fix for a different artifact.
function statePathAllowed(memoryPath, projectRoot, nameRe, reason = REASONS.MEMORY_PATH_REFUSED, refuseHardLink = true) {
  if (typeof memoryPath !== 'string' || !path.isAbsolute(memoryPath)) return { ok: false, reason };
  if (typeof projectRoot !== 'string' || !path.isAbsolute(projectRoot)) return { ok: false, reason };
  if (!nameRe.test(path.basename(memoryPath))) return { ok: false, reason };
  let rootReal;
  try { rootReal = fs.realpathSync.native(projectRoot); }
  catch (_error) { return { ok: false, reason }; }
  const stateDir = evidenceDirFor(rootReal);
  if (path.dirname(memoryPath) !== stateDir) return { ok: false, reason };
  if (!stateComponentsSafe(rootReal)) return { ok: false, reason };
  let leaf = null;
  try { leaf = fs.lstatSync(memoryPath); }
  catch (error) {
    if (!error || error.code !== 'ENOENT') return { ok: false, reason };
  }
  if (leaf && (!leaf.isFile() || leaf.isSymbolicLink() || (refuseHardLink && leaf.nlink !== 1))) {
    return { ok: false, reason };
  }
  return { ok: true, stateDir };
}

// ONE owner for the `.zensu/state` layout AMONG THIS MODULE'S JS CONSUMERS, and the qualifier is
// the load-bearing half. Before this the segments were joined independently in the module, in the
// broker and in the doctor wrapper, and a layout change would have made the broker refuse loudly
// while the doctor rendered green over a marker one path away. What is NOT covered: both consent
// HOOKS still spell `<root>/.zensu/state` in shell (`pre-browser-navigation-consent.sh` builds the
// memory path, `post-browser-navigation-consent.sh` builds it and mkdirs it plus its two symlink
// guards), and `session-control-core-v1.js` declares its own `WORKFLOW_STATE_SEGMENTS` twin. A
// layout change is therefore a multi-site edit and this constant does not make it one edit — say
// "one owner for the JS consumers", never "one owner".
const STATE_SEGMENTS = Object.freeze(['.zensu', 'state']);

function evidenceDirFor(projectRoot) {
  return path.join(projectRoot, ...STATE_SEGMENTS);
}

// The WRITER validated every directory component and the READER validated none, so with `.zensu`
// a symlink the writer refused while the reader sourced markers from the link target. Both halves
// apply the same walk now.
function stateComponentsSafe(rootReal) {
  let seen = rootReal;
  for (const segment of STATE_SEGMENTS) {
    seen = path.join(seen, segment);
    let info;
    try { info = fs.lstatSync(seen); }
    catch (_error) { return false; }
    if (!info.isDirectory() || info.isSymbolicLink()) return false;
  }
  return true;
}

function appendRecord(memoryPath, record, options = {}) {
  if (!validRecord(record)) return { ok: false, reason: 'record-invalid' };
  const allowed = memoryPathAllowed(memoryPath, options.projectRoot);
  if (!allowed.ok) return allowed;
  const current = readMemory(memoryPath);
  // An unreadable memory is refused, never rebuilt from empty. Rebuilding renamed over the
  // file and discarded every previously approved origin with no signal at all: the result
  // was ok, so runPost's stderr disclosure never fired and the user was asked again for
  // origins they had already approved. An absent file is the ordinary first write and is
  // the only case that legitimately starts from zero.
  if (!current.ok) return { ok: false, reason: current.reason || REASONS.MEMORY_UNREADABLE };
  const records = current.records.slice();
  if (records.some((entry) => entry.origin === record.origin && entry.route === record.route)) {
    return { ok: true, records, duplicate: true };
  }
  if (records.length >= MAX_RECORDS) return { ok: false, reason: 'memory-full' };
  records.push({ origin: record.origin, route: record.route, decidedBy: record.decidedBy, at: record.at });
  const body = `${JSON.stringify({ version: MEMORY_VERSION, records })}\n`;
  // The writer must never produce a file its own reader refuses. validRecord bounds no route
  // length and MAX_RECORDS bounds only the count, so 512 ordinary records — or one navigation
  // to a route longer than the cap — would exceed MAX_MEMORY_BYTES and make every later read
  // fail, leaving an approved origin asking on every navigation with nothing to repair it.
  if (Buffer.byteLength(body) > MAX_MEMORY_BYTES) return { ok: false, reason: 'memory-would-exceed-read-cap' };
  const temp = path.join(allowed.stateDir, `.${path.basename(memoryPath)}.${process.pid}.${crypto.randomBytes(6).toString('hex')}.tmp`);
  try {
    const fd = fs.openSync(temp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
    try {
      fs.writeSync(fd, body);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(temp, memoryPath);
  } catch (error) {
    try { fs.unlinkSync(temp); } catch (_ignore) { /* nothing to remove */ }
    return { ok: false, reason: `memory-write-failed:${error && error.code ? error.code : 'unknown'}` };
  }
  return { ok: true, records, duplicate: false };
}

// --- Per-session execution evidence -----------------------------------------------------
//
// The broker enters consent mode when it can lstat this hook and find it in a hooks.json under
// its OWN tree. That is a claim a file makes, never a fact about the running session, and the
// fallback is more permissive than the state it replaced: before consent mode, no policy meant
// no navigation at all. Three reachable ways to get the permissive half without the gate —
// hooks disabled host-side, a broker launched from a different tree than the one whose registry
// the host loaded, and a plugin swap while the long-lived MCP process holds a mode it resolved
// once at start.
//
// This marker is the positive evidence that closes them. It says the gate RAN, in this session,
// for this ORIGIN — never that a human approved anything, which a PreToolUse hook cannot know.
// It is deliberately short-lived: the gate rewrites it on every decision, so a live one is
// milliseconds old on the legitimate path, and a stale one cannot stand in for a gate that did
// not run for the navigation actually in flight.
// The name carries the session key AND a digest of the origin. With one file per session a
// second decided origin renamed over the first, destroying evidence for an origin that had not
// been approved yet; two navigations in flight together clobbered one another and the earlier
// one was refused. Keying on the origin makes them coexist, and the reader already walks the
// directory rather than opening one path, so nothing downstream changes.
const EVIDENCE_NAME_PREFIX = 'verify-consent-exec-';
const EVIDENCE_NAME_RE = new RegExp(`^${EVIDENCE_NAME_PREFIX}scv1_[a-f0-9]{64}-[a-f0-9]{16}\\.json$`);
// The marker gets its own schema discriminator rather than sharing the consent memory's. The two
// artifacts have different lifetimes — the marker expires in minutes, the memory lasts the
// session — and `appendRecord` deliberately REFUSES an unreadable memory rather than rebuilding
// it, so a bump made to move the marker's body would have made every project's memory unreadable
// with no writer able to repair it.
const EVIDENCE_VERSION = 1;
// The walk is bounded like the memory's record cap: a long-lived project accumulates one marker
// per (session, origin) and an unbounded walk would grow without limit on the interactive
// approval path. `reapExpiredEvidence` removes what no reader can honour, which bounds the
// accumulation but does not replace this cap — a project can hold more LIVE markers than the
// budget, and exhausting it is reported through `truncated` rather than read as an empty walk.
const MAX_EVIDENCE_FILES = 512;

function evidenceOriginTag(origin) {
  return crypto.createHash('sha256').update(String(origin)).digest('hex').slice(0, 16);
}
const MAX_EVIDENCE_BYTES = 4096;
const MAX_EVIDENCE_AGE_MS = 5 * 60 * 1000;
// The SWEEP's age bound, deliberately LARGER than the reader's default window, and the gap is what
// keeps one diagnosis reachable. `liveEvidenceOrigins` takes `maxAgeMs` as an option, and the
// broker's expiry probe drives it with `Number.MAX_SAFE_INTEGER` — that widened read is the only
// thing that can answer `expired`, which is how a slow human answer is told apart from a gate that
// never ran. A sweep clocked on the reader's own window would delete exactly the marker that
// diagnosis needs, and any later marker write anywhere in the project would do it, because the
// sweep is neither session- nor origin-scoped. So the reaper removes what NO reader can honour at
// ANY window immediately, and holds an age-expired marker for one further window before removing
// it. State the bound rather than claiming the two rules cannot diverge: they diverge on purpose,
// on this one axis, and nowhere else.
const MAX_EVIDENCE_REAP_AGE_MS = 2 * MAX_EVIDENCE_AGE_MS;

function evidencePathAllowed(evidencePath, projectRoot) {
  return statePathAllowed(evidencePath, projectRoot, EVIDENCE_NAME_RE, REASONS.EVIDENCE_PATH_REFUSED, false);
}

// The evidence path is DERIVED from the memory path rather than resolved a second time, so the
// session key is spelled once and the two artifacts cannot name different sessions. A memory
// path that does not carry the memory shape yields no evidence path at all: with no bound
// session there is no key to bind a marker to, and the broker then refuses to self-approve,
// which is the fail-closed direction.
function evidencePathFor(memoryPath, origin) {
  if (typeof memoryPath !== 'string' || memoryPath === '') return '';
  if (typeof origin !== 'string' || origin === '') return '';
  const name = path.basename(memoryPath);
  if (!MEMORY_NAME_RE.test(name)) return '';
  const stem = name.replace(MEMORY_NAME_PREFIX, EVIDENCE_NAME_PREFIX).replace(/\.json$/, '');
  return path.join(path.dirname(memoryPath), `${stem}-${evidenceOriginTag(origin)}.json`);
}

function writeExecutionEvidence(evidencePath, origin, options = {}) {
  // The origin is re-classified rather than trusted: a marker is only ever written for a target
  // the floor admits, so a refused address can never leave evidence a later read would honour.
  const classified = floor.classifyOrigin(origin, true);
  if (!classified.ok || classified.mode !== 'local' || classified.origin !== origin) {
    return { ok: false, reason: 'evidence-origin-refused' };
  }
  const allowed = evidencePathAllowed(evidencePath, options.projectRoot);
  if (!allowed.ok) return allowed;
  // The NAME must carry the origin this body names. `evidencePathAllowed` shape-tests the name and
  // never compares its tag to the origin, and the tag is what makes two decided origins coexist —
  // so a caller handing the tag for origin A with a body naming origin B would rename over A's
  // marker and destroy evidence for an origin that was never approved. `runPre` derives the path
  // from the origin and so agrees by construction, but this function is exported and a second
  // caller is reachable.
  if (!path.basename(evidencePath).endsWith(`-${evidenceOriginTag(origin)}.json`)) {
    return { ok: false, reason: 'evidence-origin-tag-mismatch' };
  }
  const at = typeof options.at === 'string' ? options.at : new Date().toISOString();
  if (!isIsoInstant(at)) return { ok: false, reason: 'evidence-stamp-invalid' };
  // The VERDICT travels with the marker. Without it the broker cannot tell an
  // asked-and-refused execution from an asked-and-approved one, and in the plugin-swap route
  // this feature exists for, a declined origin would be self-approved unprompted inside the
  // marker's window. A caller that names no verdict gets `asked`, the weaker of the two.
  const verdict = options.verdict === EVIDENCE_VERDICT_ALLOWED ? EVIDENCE_VERDICT_ALLOWED : EVIDENCE_VERDICT_WEAKEST;
  const body = `${JSON.stringify({ version: EVIDENCE_VERSION, origin, verdict, at })}\n`;
  if (Buffer.byteLength(body) > MAX_EVIDENCE_BYTES) return { ok: false, reason: 'evidence-too-large' };
  // SWEPT BEFORE THE PUBLISH, and the order is about a window rather than tidiness. The wrapper
  // captures this process's stdout in a command substitution, which reads to EOF, so nothing the
  // module writes reaches the host until the process EXITS — every instruction between the rename
  // and exit therefore widens the interval in which a killed hook leaves a live marker behind with
  // no decision delivered. The sweep is up to `MAX_EVIDENCE_FILES` read-and-parse rounds, which is
  // the largest thing that was in that interval. Best effort in its own try, for the reason the
  // previous placement made concrete: a throw escaping it must never report a marker as unwritten.
  try { reapExpiredEvidence(allowed.stateDir, new Date().toISOString()); }
  catch (_ignore) { /* best effort: a marker that cannot be removed costs nothing */ }
  const temp = path.join(allowed.stateDir, `.${path.basename(evidencePath)}.${process.pid}.${crypto.randomBytes(6).toString('hex')}.tmp`);
  try {
    const fd = fs.openSync(temp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
    try {
      fs.writeSync(fd, body);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(temp, evidencePath);
  } catch (error) {
    try { fs.unlinkSync(temp); } catch (_ignore) { /* nothing to remove */ }
    return { ok: false, reason: `evidence-write-failed:${error && error.code ? error.code : 'unknown'}` };
  }
  return { ok: true, origin, verdict, at };
}

// Markers are otherwise never removed, and the reader's walk is budgeted, so an accumulating
// project would eventually push a live marker outside the examined set and refuse a navigation
// with a message naming a gate that did run. Reaping happens at the one site that already holds
// a validated state directory, and is best effort: a marker that cannot be removed costs nothing.
//
// The candidate set is EVERYTHING THE READER CAN NEVER HONOUR, not just what has expired. Reaping
// only well-formed expired markers left the one class that actually exhausts the budget: a
// correctly-named file whose body the reader refuses — `{}`, a wrong schema version, a foreign
// origin, an unknown verdict, a stamp in the FUTURE — is skipped by every reader forever and by
// the old reaper too, while `liveEvidenceOrigins` counts it against `MAX_EVIDENCE_FILES` BEFORE
// parsing. Since the broker's granting read is unscoped, enough of those refused every loopback
// origin in the project with a durable message naming a cause that had not occurred.
//
// TWO bounds are deliberate and neither is cosmetic. A non-regular entry is left alone: this
// verb may only remove what it can prove is a dead marker, and a directory or a symlink at that
// name is tamper evidence rather than litter. And the candidate is re-`lstat`ed IMMEDIATELY
// before the unlink and skipped when dev/ino/mtime moved, because `writeExecutionEvidence`
// publishes by rename onto exactly these names — without the re-check an interleaving deleted a
// FRESH marker, which is the failure this function exists to prevent.
//
// The reap is NOT session-scoped, so a write in one session removes a sibling session's dead
// markers too. That is deliberate — the budget it protects is project-wide, and the entries it
// removes are ones no reader in any session could have honoured — and it is disclosed in
// docs/gates.md beside the window rather than left to be discovered.
// BUDGETED to `MAX_EVIDENCE_FILES`, the same cap the reader carries, and the reason is not
// symmetry: this walk runs inside the PreToolUse hook that GATES the navigation, and it reads
// and parses every candidate rather than only stat-ing it. `.zensu/state/` is writable from
// inside a session through an ungated Bash redirect, so an unbounded walk let the contents of
// that directory decide how long the gating hook takes to answer — one readdir plus N
// read-and-parse rounds per decided navigation. Exhausting the budget is not reported here: the
// reap is a best-effort sweep rather than an answer, and the READER is what tells a caller that
// a walk did not finish.
//
// The counter is returned so the bound has an executed case; nothing in production reads it.
function reapExpiredEvidence(stateDir, nowIso) {
  const now = Date.parse(nowIso);
  if (!Number.isFinite(now)) return 0;
  let names;
  try { names = fs.readdirSync(stateDir); }
  catch (_error) { return 0; }
  let examined = 0;
  for (const name of names) {
    if (!EVIDENCE_NAME_RE.test(name)) continue;
    if (examined >= MAX_EVIDENCE_FILES) break;
    examined += 1;
    const candidate = path.join(stateDir, name);
    try {
      const info = fs.lstatSync(candidate);
      if (!info.isFile() || info.isSymbolicLink()) continue;
      if (evidenceStillHonourable(candidate, info, now)) continue;
      const before = fs.lstatSync(candidate);
      if (before.dev !== info.dev || before.ino !== info.ino || before.mtimeMs !== info.mtimeMs) continue;
      fs.unlinkSync(candidate);
    } catch (_error) { /* a marker that will not be read is a marker that will not be reaped */ }
  }
  return examined;
}

// The reap candidate test, stated as the reader's own liveness rule so the two cannot drift into
// removing a marker a reader would still honour. Anything this answers false for is refused by
// every reader for as long as it exists.
// The STAT-level half of that rule, owned once. Both the reader and the reaper apply it, and
// splitting it was a real defect rather than a tidiness point: the reader refused `nlink !== 1`
// while the reaper's own predicate checked only the size, so a live hard-linked marker was
// refused by every reader AND reported honourable by the sweep — unreadable and unreapable at
// once, holding a walk-budget slot the sweep exists to free. A stat rule added to one side alone
// cannot reintroduce that now, because there is one side.
function evidenceStatUsable(info) {
  return info.isFile() && !info.isSymbolicLink() && info.nlink === 1 && info.size <= MAX_EVIDENCE_BYTES;
}

// The BODY half of the liveness rule, owned once beside the stat half. Unifying only the stat
// rule left this ladder spelled twice, which is the same drift class one level down: a rule
// tightened on the reader alone would make the sweep report honourable what no reader honours.
// The WINDOW is a parameter rather than a constant precisely because the two callers legitimately
// use different ones — see `MAX_EVIDENCE_REAP_AGE_MS`.
function evidenceBodyLive(parsed, now, maxAge) {
  if (!parsed || typeof parsed !== 'object' || parsed.version !== EVIDENCE_VERSION) return false;
  if (typeof parsed.origin !== 'string' || parsed.origin === '' || !isIsoInstant(parsed.at)) return false;
  const reread = floor.classifyOrigin(parsed.origin, true);
  if (!reread.ok || reread.mode !== 'local' || reread.origin !== parsed.origin) return false;
  if (!EVIDENCE_VERDICTS.includes(parsed.verdict)) return false;
  const age = now - Date.parse(parsed.at);
  return age >= 0 && age <= maxAge;
}

function evidenceStillHonourable(candidate, info, now) {
  if (!evidenceStatUsable(info)) return false;
  let parsed;
  try { parsed = JSON.parse(fs.readFileSync(candidate, 'utf8')); }
  catch (_error) { return false; }
  return evidenceBodyLive(parsed, now, MAX_EVIDENCE_REAP_AGE_MS);
}

// The reader takes a DIRECTORY rather than a path because its caller is the broker, which has no
// session key: it can only ask whether SOME gate in this project recorded a decision for this
// origin. Every fault answers false — this is the evidence half of a fail-closed check, so an
// unreadable directory, an unparseable marker or a marker that is not a plain file must never
// read as a pass.
function executionEvidencePresent(stateDir, origin, options = {}) {
  if (typeof origin !== 'string' || origin === '') return false;
  return liveEvidenceOrigins(stateDir, Object.assign({}, options, { wantOrigin: origin })).origins.includes(origin);
}

// The doctor asks a DIFFERENT question from the broker's: not "may this origin be approved" but
// "did the gate run at all in this session". Sharing one walk is what keeps the two answers from
// disagreeing about which markers are live — a diagnostic that judged staleness by its own rule
// would report a gate as never executed while the broker was honouring its marker.
// `read` is what separates "the directory held no live marker" from "the directory could not be
// read", and the doctor needs that split: rendering an unreadable state directory as a clean
// green row is the same benign-looking silence the execution row exists to remove.
function executionEvidenceSeen(stateDir, options = {}) {
  const walk = liveEvidenceOrigins(stateDir, options);
  // The reported origin is the one the caller ASKED about when it named one, and otherwise the
  // one carrying the WEAKER verdict. `origins[0]` was `readdirSync` order: with one `allowed`
  // and one `asked` marker live — two origins decided inside the window, ordinary in a
  // multi-origin verify run — the doctor's row flipped between runs for identical state and
  // could drop the declined-prompt disclosure entirely.
  //
  // A NAMED origin scopes the ANSWER, not only the label. When `wantOrigin` was supplied but not
  // live, control fell to the selector below and returned `present: true` carrying a DIFFERENT
  // origin — so `present` reported on the directory rather than on the question that was asked.
  // The broker's authorization path was correct only because its caller conjoined
  // `seen.origin === origin`, a compensation this function neither announced nor guaranteed.
  let chosen = '';
  if (typeof options.wantOrigin === 'string' && options.wantOrigin !== '') {
    chosen = walk.origins.includes(options.wantOrigin) ? options.wantOrigin : '';
  } else {
    for (const origin of walk.origins) {
      if (chosen === '') chosen = origin;
      if (walk.verdicts[origin] === EVIDENCE_VERDICT_WEAKEST) { chosen = origin; break; }
    }
  }
  return { present: chosen !== '', read: walk.read, truncated: walk.truncated, origin: chosen, verdict: chosen === '' ? '' : (walk.verdicts[chosen] || '') };
}

// The EXECUTION verdict, classified here rather than a second time by each consumer. The doctor
// probe hand-wrote this ladder inside a `node -e` string and encoded it in exit statuses, which
// put the answer on the same channel as every way a process can die and left the two classifiers
// held against nothing. The record's shape belongs to this module, so the reading of it does too.
// Every fault is `unjudged`: a walk that could not be read and one that did not FINISH are both
// missing checks rather than clean reads, which is the benign-looking silence this vocabulary
// exists to remove.
const EXECUTION_VERDICTS = Object.freeze(['ran', 'ran-asked', 'none', 'unjudged']);

function classifyExecution(seen) {
  if (!seen || typeof seen !== 'object') return 'unjudged';
  // Answered on what was FOUND before the walk's completeness is weighed: a budget-exhausted walk
  // that still carries this session's marker has established the execution it was asked about.
  if (seen.present === true) {
    return seen.verdict === EVIDENCE_VERDICT_ALLOWED ? 'ran' : 'ran-asked';
  }
  if (seen.read !== true || seen.truncated === true) return 'unjudged';
  return 'none';
}

// `sessionKey` binds the walk to ONE session's markers. The broker has no session key and passes
// none — its question is deliberately project-scoped, and the carriers say so — but the doctor
// does have one, and a row claiming "executed in this session" must not be satisfied by a
// sibling session's marker.
function liveEvidenceOrigins(stateDir, options = {}) {
  const found = { origins: [], verdicts: {}, read: false, truncated: false };
  if (typeof stateDir !== 'string' || stateDir === '') return found;
  const now = Number.isFinite(options.now) ? options.now : Date.now();
  const maxAge = Number.isFinite(options.maxAgeMs) ? options.maxAgeMs : MAX_EVIDENCE_AGE_MS;
  const wanted = typeof options.sessionKey === 'string' && options.sessionKey !== ''
    ? `${EVIDENCE_NAME_PREFIX}${options.sessionKey}-`
    : '';
  // The anchor is REQUIRED, and that is the fail-closed direction rather than a convenience.
  // The containment walk is checked AGAINST this root, so a call that supplies none has nothing
  // to verify — and while it was optional the module's DEFAULT was open: `executionEvidencePresent
  // (dir, origin)` read whatever directory it was handed, through a symlinked `.zensu` or `state`.
  // One caller was hardened against that (the broker refuses an anchorless policy), but the
  // module is the cross-host half a port copies, so the permissive default is how the class comes
  // back. An anchorless call now answers `read: false`, which every consumer already renders as
  // "could not be judged" rather than as an empty directory.
  if (typeof options.projectRoot !== 'string' || options.projectRoot === '') return found;
  let rootReal;
  try { rootReal = fs.realpathSync.native(options.projectRoot); }
  catch (_error) { return found; }
  if (path.join(rootReal, ...STATE_SEGMENTS) !== stateDir || !stateComponentsSafe(rootReal)) return found;
  let names;
  try { names = fs.readdirSync(stateDir); }
  catch (_error) { return found; }
  found.read = true;
  let examined = 0;
  for (const name of names) {
    if (!EVIDENCE_NAME_RE.test(name)) continue;
    // The session filter runs BEFORE the budget, so a session-scoped walk cannot be starved by
    // markers other sessions left in the same project — `readdirSync` is unordered, so which
    // entries a budget spent on foreign names would have covered is filesystem-dependent.
    if (wanted !== '' && !name.startsWith(wanted)) continue;
    if (examined >= MAX_EVIDENCE_FILES) { found.truncated = true; break; }
    examined += 1;
    const candidate = path.join(stateDir, name);
    let info;
    try { info = fs.lstatSync(candidate); }
    catch (_error) { continue; }
    if (!evidenceStatUsable(info)) continue;
    let parsed;
    try { parsed = JSON.parse(fs.readFileSync(candidate, 'utf8')); }
    catch (_error) { continue; }
    // ONE owner for the body rule, shared with the reaper. It re-classifies the origin on READ as
    // well as on write, because the value comes from a session-writable file and is handed back to
    // callers; it admits BOTH verdicts, because the ask path IS the primary route — first
    // navigation to a new origin asks, and the broker reads the marker after the human answers —
    // so refusing `asked` would refuse the feature's own main route; and it treats a FUTURE stamp
    // as outside the window rather than absolute-valued, so a skewed or planted marker cannot hold
    // the window open. The residual it does NOT close is stated in the carriers: a prompt the
    // human DECLINED leaves an `asked` marker live for its window, so an origin declined and then
    // re-navigated while the gate is not running is admitted. Closing that needs a signal the gate
    // cannot emit before the answer exists.
    if (!evidenceBodyLive(parsed, now, maxAge)) continue;
    found.origins.push(parsed.origin);
    found.verdicts[parsed.origin] = parsed.verdict;
    // The broker asks about ONE origin and never reads the rest of the list, so stopping here
    // keeps the interactive approval path off a full directory parse.
    if (typeof options.wantOrigin === 'string' && options.wantOrigin === parsed.origin) break;
  }
  return found;
}

const MAX_PROMPT_ROUTE = 120;
const MAX_PROMPT_ROUTES = 12;
const MAX_PROMPT_ROUTES_TEXT = 320;

// The prompt is the human's only control, so nothing rendered into it may be unbounded or
// carry a control byte: the route comes from a URL a caller supplied, and the declared list
// is recipe-authored. Bounding happens at the render rather than at the validator, because a
// route that fails validation is not recorded and then asks again on every navigation.
function promptRoute(route) {
  const clean = (typeof route === 'string' ? route : '').replace(/[\u0000-\u001f\u007f]/g, '');
  return clean.length > MAX_PROMPT_ROUTE ? `${clean.slice(0, MAX_PROMPT_ROUTE)}…` : clean;
}

// Two bounds, because the count bound alone does not bound the text: MAX_PROMPT_ROUTES routes
// at MAX_PROMPT_ROUTE characters each render about 1.5 KB, which pushed the consent-scope
// sentence past the point where a surface truncates. Whichever bound bites first stops the
// list, and the dropped count is always stated so the human knows the list is partial.
function promptRoutes(routes) {
  const shown = [];
  let width = 0;
  for (const route of routes.slice(0, MAX_PROMPT_ROUTES)) {
    const rendered = promptRoute(route);
    const cost = shown.length === 0 ? rendered.length : rendered.length + 2;
    if (shown.length > 0 && width + cost > MAX_PROMPT_ROUTES_TEXT) break;
    shown.push(rendered);
    width += cost;
  }
  const dropped = routes.length - shown.length;
  const list = shown.join(', ');
  return dropped > 0 ? `${list} (and ${dropped} more)` : list;
}

function promptText({ origin, route, mode, declaredRoutes }) {
  const routes = normalizeRoutes(declaredRoutes);
  // The remote arm is unreachable today: decide denies every non-local mode before the only
  // call site, and AC-018 admits literal-loopback origins only. It is kept for a future
  // elicitation channel, so a reader does not conclude consent mode prompts for remote targets.
  const modeWord = mode === 'remote' ? 'a deployed (remote) target' : 'a local loopback target';
  const lines = [];
  // Server-neutral on purpose. The matcher accepts the bare mcp__playwright__ spelling, which
  // belongs to any MCP server keyed "playwright", so this gate cannot know that the caller is a
  // /zensu:verify-feature run — and a prompt that asserts a requester it cannot observe is asking
  // the human to decide on a false premise. The foreign-server note preEnvelope attaches to an
  // ask is the other half of this: it names the doubt instead of hiding it.
  lines.push(`A browser navigation was requested to ${origin} (${modeWord}), starting with the route ${promptRoute(route)}.`);
  // The scope sentence comes before the route list on purpose. It is the only line that tells
  // the human what a Yes grants, and the route list is recipe-controlled content that would
  // otherwise push it past the point where a surface truncates.
  // "read" understated the grant. The broker's approved set gates NAVIGATION, and every later
  // interaction happens inside a page it already admitted — click, type, form submission — so a
  // Yes buys interaction, not just reading. A GET is not a read either: it can change state.
  lines.push(`Answering Yes approves this origin for the rest of the session: the model may then open, read and interact with (click, type, submit forms on) any page on ${origin}, screenshots included, without asking again. Consent is per origin, never per route.`);
  if (routes.length > 0) lines.push(`The run declares these routes as synthetic-safe: ${promptRoutes(routes)}.`);
  lines.push('Answer No to keep the browser closed for this origin; the run then reports PARTIAL.');
  return lines.join(' ');
}

function decide({ toolName, toolInput, records, declaredRoutes, policyPresent }) {
  const target = targetOf(toolName, toolInput);
  if (target === null) return { verdict: 'allow', reason: REASONS.NOT_A_NAVIGATION };
  // The floor runs BEFORE the policy-mode allow, so policy mode narrows who is asked and never
  // what is reachable. A valid policy enumerates its own targets, so an address the floor refuses
  // was never in it and applying the floor costs a legitimate policy nothing — while skipping it
  // made one environment variable a total bypass of the address rules, link-local metadata
  // services included.
  const classified = floor.classifyOrigin(target, true);
  if (!classified.ok) {
    return { verdict: 'deny', reason: classified.reason, target, origin: classified.origin || null };
  }
  const { origin, pathname: route, mode } = classified;
  // Remote is legitimate here and only here: a policy is exactly what the floor's remote refusal
  // below tells the user to supply, and the broker enforces that policy's own targets and pins.
  if (policyPresent) {
    return { verdict: 'allow', reason: REASONS.POLICY_MODE, target, origin, route, mode, decidedBy: 'policy-mode' };
  }
  if (mode !== 'local') {
    return { verdict: 'deny', reason: REASONS.REMOTE_NEEDS_POLICY, target, origin, route, mode };
  }
  // Consent is per ORIGIN, and that is the whole rule. The prompt tells the human that a Yes
  // opens every page on the origin, and the broker's own consent mode enforces exactly this
  // (assertAllowedUrl tests policy.approved.has(target.origin) with no route check). A
  // per-route re-prompt on top of that promised one thing and enforced another, and the route
  // set it kept was re-read from the live recipe on every record — including records written
  // for navigations that were never prompted — so a session could widen the recipe and launder
  // a route into the silently-allowed set. Keeping one rule in all three carriers is what
  // removes that class rather than patching it.
  const known = Array.isArray(records) ? records : [];
  if (known.some((entry) => entry.origin === origin)) {
    return { verdict: 'allow', reason: REASONS.MEMORY_HIT, target, origin, route, mode, decidedBy: 'remembered' };
  }
  return {
    verdict: 'ask',
    reason: REASONS.NEW_ORIGIN,
    target, origin, route, mode, decidedBy: 'asked',
    prompt: promptText({ origin, route, mode, declaredRoutes }),
  };
}

// The POST path's own ladder. It shares `decide`'s floor and its ordering and deliberately
// stops short of building a prompt: PostToolUse never shows one, and constructing it there was
// what made the recorder infer a human decision from a re-run of the pre-navigation state. A
// `null` label means there is nothing to record — not a navigation, or an address the floor
// refuses — and the caller skips rather than writing a record it cannot justify.
function recordLabel({ toolName, toolInput, records, policyPresent }) {
  const target = targetOf(toolName, toolInput);
  if (target === null) return { label: null, reason: REASONS.NOT_A_NAVIGATION };
  const classified = floor.classifyOrigin(target, true);
  if (!classified.ok) return { label: null, reason: classified.reason };
  const { origin, pathname: route, mode } = classified;
  if (policyPresent) return { label: 'policy-mode', origin, route, mode };
  if (mode !== 'local') return { label: null, reason: REASONS.REMOTE_NEEDS_POLICY };
  const known = Array.isArray(records) ? records : [];
  if (known.some((entry) => entry.origin === origin)) return { label: 'remembered', origin, route, mode };
  return { label: 'asked', origin, route, mode };
}

function preEnvelope(decision) {
  if (decision.verdict === 'allow') return null;
  return {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: decision.verdict,
      // An ask carries the note unconditionally, and that is the SAME doubt the neutral opening
      // creates rather than a second rule: this gate cannot know which server serves the tool,
      // so every prompt it raises may be about a navigation that is not a verify-feature run.
      // A deny stays CONDITIONAL, because there the note explains a cause and must not be
      // attached to a payload fault it does not explain.
      permissionDecisionReason: decision.verdict === 'ask'
        ? `${decision.prompt} ${FOREIGN_SERVER_NOTE}`
        : `Zensu browser consent gate denied the navigation: ${decision.reason}${foreignServerNoteApplies(decision.reason) ? ` ${FOREIGN_SERVER_NOTE}` : ''}`,
    },
  };
}

const MAX_RECIPE_BYTES = 262144;
const RECIPE_NAMES = Object.freeze(['runtime.yaml', 'autopilot.yaml']);

// The ONE resolution of which recipe governs a project. Both hooks and the doctor row
// used to spell this ladder themselves, so a one-sided edit could make the pre hook
// decide against one file while the post hook recorded against another, or make the
// doctor report a recipe the hooks never load.
function resolveRecipeFile(projectRoot) {
  if (typeof projectRoot !== 'string' || !projectRoot) return '';
  // The .zensu component is judged too, not only the leaf. lstat declines to follow the FINAL
  // component alone, so a symlinked directory was traversed as an ordinary intermediate one and
  // the declared-route set could be read from a file outside the project — the same rule
  // memoryPathAllowed applies to the state directory it opens.
  const zensuDir = path.join(projectRoot, '.zensu');
  let dirInfo;
  try { dirInfo = fs.lstatSync(zensuDir); }
  catch (_error) { return ''; }
  if (!dirInfo.isDirectory() || dirInfo.isSymbolicLink()) return '';
  for (const name of RECIPE_NAMES) {
    const candidate = path.join(zensuDir, name);
    let info;
    try { info = fs.lstatSync(candidate); }
    catch (_error) { continue; }
    if (info.isFile() && !info.isSymbolicLink()) return candidate;
  }
  return '';
}

function declaredRoutesFromRecipe(text) {
  const lines = String(text).split(/\r?\n/);
  // Anchored on the validate: parent and on depth, so one file cannot mean two things to this
  // reader and to a YAML parser: a stray evidenceSafety: at another level is not this key.
  const validateAt = lines.findIndex((line) => /^validate:\s*$/.test(line));
  if (validateAt === -1) return [];
  const validateIndent = 0;
  let start = -1;
  for (let index = validateAt + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (!line.trim()) continue;
    const indent = (line.match(/^\s*/) || [''])[0].length;
    if (indent <= validateIndent) break;
    if (/^\s*evidenceSafety:\s*$/.test(line)) { start = index; break; }
  }
  if (start === -1) return [];
  const blockIndent = (lines[start].match(/^\s*/) || [''])[0].length;
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (!line.trim()) continue;
    const indent = (line.match(/^\s*/) || [''])[0].length;
    if (indent <= blockIndent) break;
    const flow = line.match(/^\s*routes:\s*\[(.*)\]\s*$/);
    if (flow) {
      return normalizeRoutes(flow[1].split(',').map((item) => item.trim().replace(/^["']|["']$/g, '')).filter(Boolean));
    }
    if (/^\s*routes:\s*$/.test(line)) {
      const routes = [];
      for (let inner = index + 1; inner < lines.length; inner += 1) {
        const item = lines[inner].match(/^\s*-\s*(.+?)\s*$/);
        if (!item) break;
        routes.push(item[1].replace(/^["']|["']$/g, ''));
      }
      return normalizeRoutes(routes);
    }
  }
  return [];
}

function readRecipeRoutes(recipeFile) {
  if (typeof recipeFile !== 'string' || !recipeFile) return [];
  let info;
  try { info = fs.lstatSync(recipeFile); }
  catch (_error) { return []; }
  if (!info.isFile() || info.isSymbolicLink() || info.size > MAX_RECIPE_BYTES) return [];
  try {
    return declaredRoutesFromRecipe(fs.readFileSync(recipeFile, 'utf8'));
  } catch (_error) {
    return [];
  }
}

// The declared routes come from the guarded recipe read and from nowhere else. An
// environment override sat here and short-circuited the branch carrying the lstat,
// symlink and size guards, with no production producer and no hook clearing it — an
// inherited value from the launching shell would have widened the silent-allow set.
function readInputs(env) {
  const projectRoot = env.ZENSU_VERIFY_PROJECT_ROOT || '';
  const declared = readRecipeRoutes(resolveRecipeFile(projectRoot));
  return {
    memoryPath: env.ZENSU_VERIFY_CONSENT_MEMORY || '',
    projectRoot,
    declaredRoutes: declared,
    // "Present" means a policy the BROKER would accept, never merely a non-empty variable.
    // Boolean(env) disarmed this gate for any value at all, including one the broker refuses at
    // startup — so the hook stood down while the broker denied every navigation, and the user
    // got neither a prompt nor a working browser. The check is the floor's synchronous
    // top-level contract, so no DNS is reached from a PreToolUse hook.
    policyPresent: typeof env.ZENSU_VERIFY_NAVIGATION_POLICY_V1 === 'string'
      && env.ZENSU_VERIFY_NAVIGATION_POLICY_V1 !== ''
      && floor.policyContractFault(env.ZENSU_VERIFY_NAVIGATION_POLICY_V1) === '',
  };
}

function responseFailed(toolResponse) {
  if (!toolResponse || typeof toolResponse !== 'object') return false;
  if (toolResponse.isError === true) return true;
  const content = Array.isArray(toolResponse.content) ? toolResponse.content : [];
  return content.some((item) => item && typeof item.text === 'string' && item.text.startsWith('Zensu browser broker rejected the operation'));
}

// ONE read for both hooks, so a read and a write can never disagree about which file is this
// session's memory. An UNSET path is "no memory configured", never a refusal: the pre hook
// exports an empty value when no session is bound and prints its own accurate line there, and
// reporting that as a refused path names a path nobody supplied.
function readConsentMemory(memoryPath, projectRoot) {
  if (typeof memoryPath !== 'string' || memoryPath === '') return { ok: true, records: [], absent: true };
  const allowed = memoryPathAllowed(memoryPath, projectRoot);
  if (!allowed.ok) return { ok: false, reason: allowed.reason, records: [] };
  return readMemory(memoryPath);
}

function runPre(payload, env, out, err) {
  if (!payload || typeof payload !== 'object' || typeof payload.tool_name !== 'string') {
    out.write(JSON.stringify(preEnvelope({ verdict: 'deny', reason: REASONS.PAYLOAD_UNREADABLE })));
    return true;
  }
  const inputs = readInputs(env);
  const memory = readConsentMemory(inputs.memoryPath, inputs.projectRoot);
  if (!memory.ok) err.write(`zensu: verify consent memory ignored (${memory.reason}); the navigation will ask again\n`);
  const decision = decide({
    toolName: payload.tool_name,
    toolInput: payload.tool_input,
    records: memory.records,
    declaredRoutes: inputs.declaredRoutes,
    policyPresent: inputs.policyPresent,
  });
  // Pre-hook only, per its own finding: runPost's skip is correct, because a memory write for
  // a navigation that never resolved a target has nothing to record.
  if (decision.reason === REASONS.NOT_A_NAVIGATION && navigationExpected(payload.tool_name, payload.tool_input)) {
    out.write(JSON.stringify(preEnvelope({ verdict: 'deny', reason: REASONS.TARGET_UNREADABLE })));
    return true;
  }
  // AC-103: record that the gate EXECUTED for this origin, before the verdict is emitted. The
  // broker reads this marker at approval time, so a session whose hooks never ran leaves none
  // and consent mode refuses to self-approve rather than falling back to something MORE
  // permissive than the deny-everything state it replaced.
  //
  // Written for every verdict but DENY, and only for an origin the floor calls local. A denied
  // navigation never reaches the broker, so a marker for it would record an execution that
  // granted nothing; an ASK is recorded because the hook returns before the human answers and
  // the call only reaches the broker at all when the answer was yes.
  //
  // POLICY mode is excluded, and that is a security bound rather than an optimisation: `decide`
  // returns allow with reason `policy-mode` WITHOUT testing the target against the policy's own
  // targets — it delegates that to the broker — so a marker minted there asserts a clearance no
  // gate gave. The broker's granting read carries no session key, so a consent-mode broker in
  // the same project would then self-approve that origin inside the window, unprompted. An
  // aligned policy-mode session never enters consent mode, so the marker has no consumer there
  // and the skip costs nothing.
  //
  // The ENVELOPE IS EMITTED FIRST, and the order is a safety property rather than layout. For a
  // new origin the envelope is the `ask`, and the marker written for it carries verdict `asked`,
  // which the broker treats as a clearance. With the marker published first, a hook process tree
  // that died before the envelope reached stdout — a host PreToolUse timeout killing the group, a
  // SIGKILL, an OOM — left a live self-approving marker behind while no prompt was ever raised.
  // The wrapper's `|| deny` catches an ordinary non-zero exit, so that path needs the wrapper
  // killed too, and whether this host admits a call after a timed-out hook is UNVERIFIED; the
  // reorder is taken anyway because it is free and fail-closed in the other direction — a lost
  // marker refuses, where a lost envelope approved.
  const envelope = preEnvelope(decision);
  let emitted = false;
  if (envelope) { out.write(JSON.stringify(envelope)); emitted = true; }
  if (decision.verdict !== 'deny' && decision.reason !== REASONS.POLICY_MODE
    && decision.mode === 'local' && typeof decision.origin === 'string') {
    const evidencePath = evidencePathFor(inputs.memoryPath, decision.origin);
    if (evidencePath === '') {
      // Distinguished from every other fault on purpose: with no bound Session Control record
      // there is no key to bind a marker to, the broker will refuse the navigation the human is
      // about to be asked about, and the operator needs to hear that rather than a path fault.
      err.write('zensu: verify consent execution evidence not written (no bound session) — this session cannot complete a consent-mode navigation; run /zensu:doctor\n');
    } else {
      const written = writeExecutionEvidence(evidencePath, decision.origin, {
        projectRoot: inputs.projectRoot,
        verdict: decision.reason === REASONS.NEW_ORIGIN ? EVIDENCE_VERDICT_WEAKEST : EVIDENCE_VERDICT_ALLOWED,
      });
      if (!written.ok) err.write(`zensu: verify consent execution evidence not written (${written.reason}); the broker will not self-approve this origin\n`);
    }
  }
  // This function's OWN report, for a caller that returns normally. It is deliberately NOT what
  // the CLI catch reads: a throw abandons a return, so a flag assigned from this call is still
  // false in the catch on every path, including the one where the envelope was already written.
  // The CLI hands in a `recordingStream` for that reason. Writing a deny envelope unconditionally
  // there appended a SECOND object to a stdout that already carried one — two concatenated
  // objects are not valid JSON — while the process still exited 0, so the wrapper forwarded a
  // malformed decision instead of denying.
  return emitted;
}

function runPost(payload, env, err) {
  // Same test as runPre: a payload with no readable tool name is unreadable, not a
  // navigation that happened to be skipped. It DISCLOSES, because the CLI entry point
  // discards this return value and sets no exit code — without the write the fault is
  // observationally identical to the silent skip it replaced, and the module's two other
  // memory faults both report on this same channel.
  if (!payload || typeof payload !== 'object' || typeof payload.tool_name !== 'string') {
    err.write(`zensu: verify consent memory not written (${REASONS.PAYLOAD_UNREADABLE})\n`);
    return { ok: false, reason: REASONS.PAYLOAD_UNREADABLE };
  }
  if (responseFailed(payload.tool_response)) return { ok: true, skipped: 'navigation-rejected-by-broker' };
  const inputs = readInputs(env);
  const memory = readConsentMemory(inputs.memoryPath, inputs.projectRoot);
  const labelled = recordLabel({
    toolName: payload.tool_name,
    toolInput: payload.tool_input,
    records: memory.records,
    policyPresent: inputs.policyPresent,
  });
  if (labelled.label === null) return { ok: true, skipped: labelled.reason };
  const result = appendRecord(
    inputs.memoryPath,
    { origin: labelled.origin, route: labelled.route, decidedBy: labelled.label, at: new Date().toISOString() },
    { projectRoot: inputs.projectRoot },
  );
  if (!result.ok) err.write(`zensu: verify consent memory not written (${result.reason})\n`);
  return result;
}

// A throw ABANDONS an assignment, so `emitted = runPre(...)` can never be true inside the
// caller's catch — the value that survives is what the STREAM saw. This wrapper is that record:
// the CLI hands it to `runPre` in place of `process.stdout` and the catch asks it, rather than a
// flag the throw skipped over.
function recordingStream(out) {
  const state = { emitted: false };
  return {
    emitted: () => state.emitted,
    write: (chunk) => { state.emitted = true; return out.write(chunk); },
  };
}

module.exports = {
  CONSENT_MATCHER,
  recordingStream,
  DECIDED_BY,
  FOREIGN_SERVER_NOTE,
  MAX_EVIDENCE_AGE_MS,
  MAX_EVIDENCE_BYTES,
  MAX_MEMORY_BYTES,
  MAX_PROMPT_ROUTE,
  MAX_PROMPT_ROUTES,
  MAX_PROMPT_ROUTES_TEXT,
  MAX_RECIPE_BYTES,
  MAX_RECORDS,
  MEMORY_NAME_RE,
  EVIDENCE_NAME_PREFIX,
  MEMORY_NAME_PREFIX,
  EVIDENCE_VERSION,
  EVIDENCE_VERDICTS,
  EVIDENCE_VERDICT_ALLOWED,
  EVIDENCE_VERDICT_WEAKEST,
  MAX_EVIDENCE_FILES,
  MAX_EVIDENCE_REAP_AGE_MS,
  EXECUTION_VERDICTS,
  classifyExecution,
  evidenceBodyLive,
  MEMORY_VERSION,
  STATE_SEGMENTS,
  NAVIGATION_TOOL_RE,
  REASONS,
  RECIPE_NAMES,
  appendRecord,
  decide,
  declaredRoutesFromRecipe,
  emptyMemory,
  evidenceDirFor,
  evidenceOriginTag,
  evidencePathAllowed,
  evidencePathFor,
  executionEvidencePresent,
  executionEvidenceSeen,
  // Exported for its BOUND alone: the reap runs inside the gating hook and nothing in production
  // reads the count, so without a handle the budget would ship with no executed case.
  reapBudgetSpent: reapExpiredEvidence,
  foreignServerNoteApplies,
  isIsoInstant,
  memoryPathAllowed,
  navigationExpected,
  normalizeRoutes,
  payloadFromRaw,
  preEnvelope,
  promptRoute,
  promptRoutes,
  promptText,
  readConsentMemory,
  readInputs,
  readMemory,
  readRecipeRoutes,
  recordLabel,
  resolveRecipeFile,
  responseFailed,
  runPost,
  runPre,
  statePathAllowed,
  targetOf,
  validRecord,
  writeExecutionEvidence,
};

if (require.main === module) {
  const mode = process.argv[2];
  if (mode !== 'pre' && mode !== 'post') {
    process.stderr.write('usage: verify-consent-v1.js pre|post\n');
    process.exitCode = 2;
  } else {
    let raw = '';
    let accumulationFailed = false;
    let settled = false;
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => {
      if (accumulationFailed) return;
      try { raw += chunk; } catch (_error) { accumulationFailed = true; raw = ''; }
    });
    const finalize = () => {
      if (settled) return;
      settled = true;
      const payload = payloadFromRaw(raw, accumulationFailed);
      const recorder = recordingStream(process.stdout);
      try {
        if (mode === 'pre') runPre(payload, process.env, recorder, process.stderr);
        else runPost(payload, process.env, process.stderr);
      } catch (error) {
        if (mode === 'pre') {
          // The deny envelope is written ONLY when the stream carries nothing yet: a second object
          // on a stdout that already carries one is not valid JSON, and the wrapper captures the
          // whole stream. The RECORDER is what makes that observable — a throw abandons runPre's
          // return, so a flag assigned from that call is false here on every path and the guard
          // could never fire. What makes the wrapper DENY rather than forward whatever it
          // captured is the non-zero status below; this guard only keeps the stream well-formed.
          if (!recorder.emitted()) {
            process.stdout.write(JSON.stringify(preEnvelope({ verdict: 'deny', reason: `hook-failed:${error && error.code ? error.code : 'unknown'}` })));
          }
          process.exitCode = 2;
        } else {
          process.stderr.write('zensu: verify consent memory not written (hook failed)\n');
        }
      }
    };
    process.stdin.on('error', () => { accumulationFailed = true; raw = ''; finalize(); });
    process.stdin.on('end', finalize);
    process.stdin.on('close', finalize);
  }
}
