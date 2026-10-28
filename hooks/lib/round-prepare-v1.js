"use strict";

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

const ledgerLib = require(path.join(__dirname, "review-ledger-v1.js"));
const scopeLib = require(path.join(__dirname, "review-round-scope-v1.js"));
const activationLib = require(path.join(__dirname, "aspect-activation-v1.js"));

const SCHEMA = "round-snapshot-v1";
const LIMITS = Object.freeze({
  maxFiles: 5000,
  maxRecorded: 20000,
  maxFileBytes: 64 * 1024 * 1024,
  maxSnapshotBytes: 16 * 1024 * 1024,
  keptRounds: 4,
  maxRound: 999999,
});
const UNHASHED = "unhashed";
const NON_CONTENT = new Set([UNHASHED, "directory"]);
const FAILED_OUTCOMES = new Set(["not-landed", "unverified", "unchanged"]);
const CLAIM_MARKERS = Object.freeze([
  "IMPL completed — files:",
  "IMPL completed – files:",
  "IMPL completed - files:",
  "WIRED — files:",
  "WIRED – files:",
  "WIRED - files:",
  "WIRED (verified, no change)",
]);
const VERDICT_HEADS = Object.freeze(["EDIT LANDED ", "EDIT NOT LANDED ", "EDIT LANDING AUDIT ", "PENDING PREDICATE ", "UNVERIFIED ", "RECEIPT REFUSED "]);
const LABEL_TOKEN_BUDGET = 5;
const PROJECT_PREFIX = "<project>/";
const FIX_LABEL = /^R([1-9][0-9]{0,5})(?:-|$)/;
const AUDIT_START = /^\s*(?:\[[^\]]*\]\s*)?EDIT LANDING AUDIT STARTED — round fix-([1-9][0-9]{0,5})\s*$/;
const ROUND_ZERO_LINE = "ROUND PREPARE — round 0 recorded the round-start snapshot";
const ROUND_ZERO = /^\s*(?:\[[^\]]*\]\s*)?ROUND PREPARE — round 0 recorded the round-start snapshot\b/;
const WITHDRAWN = /^\s*(?:\[[^\]]*\]\s*)?CLAIM WITHDRAWN — (.+)$/;
const ROUND_ARG = /^(0|[1-9][0-9]{0,5}|self-review)$/;
const FINDING_ID = /^(?:G[1-9][0-9]{0,5}:)?R([1-9][0-9]{0,5})-F([1-9][0-9]{0,4})$/;
const LOCAL_ID = /^F[1-9][0-9]{0,4}$/;
const FIXABLE_STATES = new Set(["routed-unfixed", "parked", "deferred"]);
const OPEN_STATES = new Set(["routed-unfixed", "parked", "deferred"]);
const VERDICT = /^(EDIT LANDED|EDIT NOT LANDED|PENDING PREDICATE|UNVERIFIED(?: \([a-z -]+\))?) — (.+)$/;
const DIRTY_TAIL = " was already dirty before this round";
const NOT_LANDED_HEAD = "claimed ";
const NOT_LANDED_TAIL = ", git shows no change";
const BARE_WIRED = /^a WIRED entry at run-log line [0-9]+ \(step (.+)\) names no files: list and cannot be graded$/;
const STATE_DIRECTORY = ".zensu";
const AUDIT_CLOSE = /^(EDIT LANDING AUDIT — |RECEIPT REFUSED — )/;
const RECEIPT_REFUSED = /^RECEIPT REFUSED — /;

function parseRound(value) {
  const text = String(value == null ? "" : value);
  if (!ROUND_ARG.test(text)) return null;
  if (text === "self-review") return { kind: "self-review", label: "self-review", number: null };
  const number = Number(text);
  if (number === 0) return { kind: "first", label: "0", number: 0 };
  return { kind: "fix", label: text, number };
}

function roundPrefix(round) {
  return round.kind === "self-review" ? "SR" : "R" + round.number;
}

function labelInRound(label, round) {
  if (!round || round.kind === "first") return false;
  const prefix = roundPrefix(round);
  const text = String(label == null ? "" : label);
  return text === prefix || text.startsWith(prefix + "-");
}

function findingIdOf(label, round) {
  if (!labelInRound(label, round)) return null;
  const rest = String(label).slice(roundPrefix(round).length + 1);
  if (round.kind === "fix" && LOCAL_ID.test(rest)) return roundPrefix(round) + "-" + rest;
  if (FINDING_ID.test(rest)) return rest;
  return null;
}

function parseAuditLine(line) {
  const text = String(line == null ? "" : line).replace(/\r$/, "");
  const match = VERDICT.exec(text);
  if (!match) return null;
  const head = match[1];
  const body = match[2];
  if (head.startsWith("UNVERIFIED")) {
    const bare = BARE_WIRED.exec(body);
    if (bare) return { kind: "unverified", step: bare[1], file: null, line: text };
    if (head === "UNVERIFIED (no claims logged)") return { kind: "no-claims", step: null, file: null, line: text };
    const cut = body.indexOf(": ");
    if (cut < 1) return { kind: "unverified", step: null, file: null, line: text };
    return { kind: "unverified", step: body.slice(0, cut), file: null, line: text };
  }
  const cut = body.indexOf(": ");
  if (cut < 1) return null;
  const step = body.slice(0, cut);
  const rest = body.slice(cut + 2);
  if (head === "EDIT LANDED") return { kind: "landed", step, file: rest, line: text };
  if (head === "EDIT NOT LANDED") {
    let file = null;
    if (rest.startsWith(NOT_LANDED_HEAD) && rest.endsWith(NOT_LANDED_TAIL)) {
      file = rest.slice(NOT_LANDED_HEAD.length, rest.length - NOT_LANDED_TAIL.length);
    }
    return { kind: "not-landed", step, file, line: text };
  }
  const dirty = rest.indexOf(DIRTY_TAIL);
  if (dirty > 0) return { kind: "pending", step, file: rest.slice(0, dirty), line: text };
  return { kind: "pending-outside-git", step, file: null, line: text };
}

function sha256Of(fd, size) {
  const hash = crypto.createHash("sha256");
  const chunk = Buffer.alloc(Math.min(Math.max(size, 1), 1024 * 1024));
  let position = 0;
  for (;;) {
    const read = fs.readSync(fd, chunk, 0, chunk.length, position);
    if (read === 0) break;
    hash.update(chunk.subarray(0, read));
    position += read;
    if (position > LIMITS.maxFileBytes) return null;
  }
  return "sha256:" + hash.digest("hex");
}

function digestFile(root, rel) {
  const full = path.join(root, rel);
  let stat;
  try {
    stat = fs.lstatSync(full);
  } catch (error) {
    return error && error.code === "ENOENT" ? "absent" : null;
  }
  if (stat.isSymbolicLink()) {
    try {
      return "link:" + crypto.createHash("sha256").update(fs.readlinkSync(full)).digest("hex");
    } catch (_) {
      return null;
    }
  }
  if (stat.isDirectory()) return "directory";
  if (!stat.isFile() || stat.size > LIMITS.maxFileBytes) return null;
  let fd;
  try {
    fd = fs.openSync(full, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0) | (fs.constants.O_NONBLOCK || 0));
    const opened = fs.fstatSync(fd);
    if (!opened.isFile() || opened.ino !== stat.ino) return null;
    return sha256Of(fd, opened.size);
  } catch (_) {
    return null;
  } finally {
    if (fd !== undefined) {
      try {
        fs.closeSync(fd);
      } catch (_) {}
    }
  }
}

function safeRelative(rel) {
  const text = String(rel == null ? "" : rel);
  if (text === "" || text.includes("\0") || /[\u0000-\u001f\u007f]/.test(text)) return false;
  if (path.isAbsolute(text) || /^[A-Za-z]:/.test(text)) return false;
  return !text.split(/[\\/]/).includes("..");
}

function reviewable(rel) {
  return !String(rel).split(/[\\/]/).includes(STATE_DIRECTORY);
}

function normalizeClaimFile(entry) {
  let rel = String(entry).trim();
  if (rel.startsWith(PROJECT_PREFIX)) rel = rel.slice(PROJECT_PREFIX.length);
  while (rel.startsWith("./")) rel = rel.slice(2);
  return rel;
}

function claimOf(line) {
  let entry = String(line == null ? "" : line).replace(/^\s+/, "");
  if (entry.startsWith("[")) {
    const close = entry.indexOf("]");
    if (close > 0) entry = entry.slice(close + 1).replace(/^\s+/, "");
  }
  if (VERDICT_HEADS.some((head) => entry.startsWith(head))) return null;
  let marker = null;
  let at = -1;
  for (const candidate of CLAIM_MARKERS) {
    const found = entry.indexOf(candidate);
    if (found >= 0 && (at < 0 || found < at)) {
      marker = candidate;
      at = found;
    }
  }
  if (marker !== null) {
    const lead = entry.slice(0, at);
    const tokens = lead.split(/\s+/).filter((token) => token !== "");
    if (!/['"|]/.test(lead) && tokens.length <= LABEL_TOKEN_BUDGET) {
      const files = marker.endsWith("files:")
        ? entry.slice(at + marker.length).split("|")[0].split(/[,\s]+/).map(normalizeClaimFile).filter((rel) => rel !== "")
        : [];
      return { label: tokens.length ? tokens.join(" ") : "(none)", files };
    }
  }
  const step = entry.split(/\s/, 1)[0];
  if (step === "" || !entry.slice(step.length).replace(/^\s+/, "").startsWith("WIRED")) return null;
  return { label: step, files: [] };
}

function digestFiles(root, paths) {
  const files = Object.create(null);
  let recorded = 0;
  let hashed = 0;
  let truncated = 0;
  for (const rel of paths) {
    if (!safeRelative(rel) || Object.prototype.hasOwnProperty.call(files, rel)) continue;
    if (recorded >= LIMITS.maxRecorded) {
      truncated += 1;
      continue;
    }
    recorded += 1;
    if (hashed >= LIMITS.maxFiles) {
      files[rel] = UNHASHED;
      continue;
    }
    hashed += 1;
    const digest = digestFile(root, rel);
    files[rel] = digest === null ? UNHASHED : digest;
  }
  return { files, truncated };
}

function isContent(digest) {
  return typeof digest === "string" && !NON_CONTENT.has(digest);
}

function digestOf(files, rel) {
  return files && rel !== null && Object.prototype.hasOwnProperty.call(files, rel) ? files[rel] : undefined;
}

function validSnapshotEntry(entry) {
  if (!entry || typeof entry !== "object" || Array.isArray(entry)) return false;
  if (!Number.isFinite(entry.at) || typeof entry.files !== "object" || entry.files === null || Array.isArray(entry.files)) return false;
  if (!Number.isInteger(entry.truncated) || entry.truncated < 0 || typeof entry.baseline !== "string") return false;
  return Object.keys(entry.files).every((rel) => safeRelative(rel) && typeof entry.files[rel] === "string");
}

function readSnapshot(file, top) {
  let stat;
  try {
    stat = fs.lstatSync(file);
  } catch (error) {
    return { ok: false, reason: error && error.code === "ENOENT" ? "missing" : "unreadable" };
  }
  if (stat.isSymbolicLink() || !stat.isFile()) return { ok: false, reason: "not-a-regular-file" };
  if (stat.size > LIMITS.maxSnapshotBytes) return { ok: false, reason: "oversized" };
  let doc;
  try {
    doc = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (_) {
    return { ok: false, reason: "unparseable" };
  }
  if (!doc || doc.schema !== SCHEMA || typeof doc.rounds !== "object" || doc.rounds === null || Array.isArray(doc.rounds)) {
    return { ok: false, reason: "unknown-schema" };
  }
  if (typeof doc.log !== "string" || doc.log === "" || /[\\/]/.test(doc.log) || !Number.isInteger(doc.generation) || doc.generation < 0) {
    return { ok: false, reason: "unknown-schema" };
  }
  if (doc.top !== top) return { ok: false, reason: "other-work-tree" };
  for (const label of Object.keys(doc.rounds)) {
    if (!/^(0|[1-9][0-9]{0,5})$/.test(label) || !validSnapshotEntry(doc.rounds[label])) {
      return { ok: false, reason: "malformed" };
    }
  }
  return { ok: true, doc };
}

function chainOf(logFile) {
  const lines = logFile ? readLines(logFile) : [];
  let resetIndex = -1;
  let generation = 0;
  lines.forEach((line, index) => {
    if (scopeLib.RESET.test(line)) {
      resetIndex = index;
      generation += 1;
    }
  });
  const claims = [];
  const preReset = new Set();
  const postClaims = new Map();
  const postFiles = new Map();
  const withdrawals = [];
  const fixStarts = new Map();
  let roundZero = -1;
  let lastFixRound = 0;
  lines.forEach((line, index) => {
    const claim = claimOf(line);
    if (claim) {
      if (index < resetIndex) {
        preReset.add(claim.label);
        return;
      }
      claims.push({ label: claim.label, index });
      if (!postClaims.has(claim.label)) {
        postClaims.set(claim.label, index);
        postFiles.set(claim.label, new Set());
      }
      for (const rel of claim.files) postFiles.get(claim.label).add(rel);
      const fix = FIX_LABEL.exec(claim.label);
      if (fix) lastFixRound = Math.max(lastFixRound, Number(fix[1]));
      return;
    }
    if (index <= resetIndex) return;
    if (ROUND_ZERO.test(line)) {
      roundZero = index;
      return;
    }
    const started = AUDIT_START.exec(line);
    if (started) {
      fixStarts.set(Number(started[1]), index);
      lastFixRound = Math.max(lastFixRound, Number(started[1]));
      return;
    }
    const withdrawn = WITHDRAWN.exec(line);
    if (withdrawn) {
      const body = withdrawn[1].trim();
      const cut = body.indexOf(": ");
      withdrawals.push({ label: cut > 0 ? body.slice(0, cut) : body, file: cut > 0 ? body.slice(cut + 2) : null, index });
    }
  });
  return {
    name: logFile ? path.basename(logFile) : "",
    generation,
    claims,
    preReset,
    postClaims,
    postFiles,
    withdrawals,
    fixStarts,
    roundZero,
    lastFixRound,
  };
}

function roundBoundary(chain, round) {
  const previous = round.kind === "fix" ? round.number - 1 : chain.lastFixRound;
  if (previous === 0) return chain.roundZero;
  return chain.fixStarts.has(previous) ? chain.fixStarts.get(previous) : -1;
}

function unprefixedClaims(chain, round) {
  if (!round || round.kind === "first") return [];
  const boundary = roundBoundary(chain, round);
  if (boundary < 0) return [];
  return uniqueSorted(chain.claims.filter((claim) => claim.index > boundary && !labelInRound(claim.label, round)).map((claim) => claim.label));
}

function resolveStart(read, round, chain, baseline) {
  if (!round || round.kind === "first") return { entry: null, reason: "round-0" };
  if (!read || !read.ok) return { entry: null, reason: read ? read.reason : "unread" };
  const doc = read.doc;
  if (doc.log !== chain.name) return { entry: null, reason: "other-chain" };
  if (doc.generation !== chain.generation) return { entry: null, reason: "other-generation" };
  const label = String(round.kind === "fix" ? round.number - 1 : chain.lastFixRound);
  const entry = Object.prototype.hasOwnProperty.call(doc.rounds, label) ? doc.rounds[label] : null;
  if (!entry) return { entry: null, reason: "no entry for round " + label };
  if (entry.baseline !== (baseline || "")) return { entry: null, reason: "other-baseline" };
  return { entry, reason: "" };
}

function recordRound(doc, top, chain, label, entry) {
  const same = Boolean(doc) && label !== "0" && doc.top === top && doc.log === chain.name && doc.generation === chain.generation;
  const next = { schema: SCHEMA, top, log: chain.name, generation: chain.generation, rounds: same ? Object.assign({}, doc.rounds) : {} };
  next.rounds[label] = entry;
  const labels = Object.keys(next.rounds).map(Number).sort((a, b) => b - a);
  for (const old of labels.slice(LIMITS.keptRounds)) delete next.rounds[String(old)];
  return next;
}

function writeSnapshot(file, doc) {
  const dir = path.dirname(file);
  let dirStat;
  try {
    dirStat = fs.lstatSync(dir);
  } catch (_) {
    return { ok: false, reason: "state-directory-missing" };
  }
  if (dirStat.isSymbolicLink() || !dirStat.isDirectory()) return { ok: false, reason: "state-directory" };
  try {
    const existing = fs.lstatSync(file);
    if (existing.isSymbolicLink() || !existing.isFile()) return { ok: false, reason: "not-a-regular-file" };
  } catch (error) {
    if (!error || error.code !== "ENOENT") return { ok: false, reason: "unreadable" };
  }
  const temp = path.join(dir, "." + path.basename(file) + "." + process.pid + "." + crypto.randomBytes(6).toString("hex"));
  let fd;
  try {
    fd = fs.openSync(temp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | (fs.constants.O_NOFOLLOW || 0), 0o600);
    fs.writeFileSync(fd, JSON.stringify(doc) + "\n");
    fs.closeSync(fd);
    fd = undefined;
    fs.renameSync(temp, file);
    return { ok: true };
  } catch (_) {
    if (fd !== undefined) {
      try {
        fs.closeSync(fd);
      } catch (__) {}
    }
    try {
      fs.unlinkSync(temp);
    } catch (__) {}
    return { ok: false, reason: "write-failed" };
  }
}

function compareDigests(before, now) {
  if (!isContent(before) || !isContent(now)) return "unresolved";
  return before === now ? "unchanged" : "landed";
}

function landingOutcome(parsed, start, current, digestNow) {
  if (parsed.kind === "unverified") return "unverified";
  if (parsed.kind === "not-landed") {
    const before = start ? digestOf(start.files, parsed.file) : undefined;
    if (!isContent(before) || typeof digestNow !== "function") return "not-landed";
    const now = digestNow(parsed.file);
    return isContent(now) && now !== before ? "landed" : "not-landed";
  }
  if (!start || parsed.kind === "pending-outside-git") return "unresolved";
  const before = digestOf(start.files, parsed.file);
  if (parsed.kind === "landed" && before === undefined) return start.truncated > 0 ? "unresolved" : "landed";
  return before === undefined ? "unresolved" : compareDigests(before, digestOf(current, parsed.file));
}

function withdrawnClaim(chain, label, file) {
  const first = chain.postClaims.get(label);
  if (first === undefined) return false;
  return chain.withdrawals.some((item) => item.label === label && item.index > first && (item.file === null || item.file === file));
}

const NO_CHAIN = Object.freeze({
  name: "",
  generation: 0,
  claims: [],
  preReset: new Set(),
  postClaims: new Map(),
  postFiles: new Map(),
  withdrawals: [],
  fixStarts: new Map(),
  roundZero: -1,
  lastFixRound: 0,
});

function resolveLanding(options) {
  const round = options.round;
  const start = options.start || null;
  const current = options.current || {};
  const chain = options.chain || NO_CHAIN;
  const steps = new Map();
  const carried = [];
  let otherPending = 0;
  for (const raw of options.auditLines || []) {
    const parsed = parseAuditLine(raw);
    if (!parsed) continue;
    const named = parsed.step !== null && labelInRound(parsed.step, round);
    const earlierGeneration = named && chain.preReset.has(parsed.step);
    const bothSides = earlierGeneration && chain.postClaims.has(parsed.step);
    const ownFile = bothSides && parsed.file !== null && chain.postFiles.get(parsed.step).has(parsed.file);
    if (!named || (earlierGeneration && !bothSides) || (bothSides && parsed.file !== null && !ownFile)) {
      if (parsed.kind === "pending" || parsed.kind === "pending-outside-git") otherPending += 1;
      else if (parsed.kind !== "landed") carried.push(parsed.line);
      continue;
    }
    if (!steps.has(parsed.step)) steps.set(parsed.step, { step: parsed.step, files: [] });
    let outcome = bothSides && !ownFile ? "unresolved" : landingOutcome(parsed, start, current, options.digestNow);
    if (withdrawnClaim(chain, parsed.step, parsed.file)) outcome = "withdrawn";
    if (parsed.kind !== "landed") carried.push(parsed.line);
    steps.get(parsed.step).files.push({ file: parsed.file, outcome });
  }
  const owners = new Map();
  for (const entry of steps.values()) {
    for (const item of entry.files) {
      if (item.file === null || item.outcome === "withdrawn") continue;
      if (!owners.has(item.file)) owners.set(item.file, new Set());
      owners.get(item.file).add(entry.step);
    }
  }
  for (const entry of steps.values()) {
    for (const item of entry.files) {
      if (item.outcome === "landed" && owners.get(item.file).size > 1) {
        item.outcome = "unresolved";
        item.shared = true;
      }
    }
  }
  const results = [];
  for (const entry of steps.values()) {
    const live = entry.files.filter((item) => item.outcome !== "withdrawn");
    let state = "landed";
    if (entry.files.length > 0 && live.length === 0) state = "withdrawn";
    else if (live.some((item) => FAILED_OUTCOMES.has(item.outcome))) state = "not-landed";
    else if (live.length === 0 || live.some((item) => item.outcome !== "landed")) state = "unresolved";
    results.push({ step: entry.step, files: entry.files, state });
  }
  return { steps: results, carried, otherPending };
}

function fixedLines(options) {
  const round = options.round;
  const ledger = options.ledger;
  const lines = [];
  const fixedIds = [];
  const notes = [];
  if (!ledger || (ledger.status !== "ok" && ledger.status !== "partial")) {
    const status = ledger ? ledger.status : "unavailable";
    const reason = ledger && ledger.reason ? ledger.reason : "unread";
    return { lines, fixedIds, notes, usable: false, ledgerStatus: status + " (" + reason + ")" };
  }
  if (ledger.status === "partial") {
    notes.push("the ledger report read answered partial (" + (ledger.reason || "unknown") + "), so only the entries it could read can get a fixed line");
  }
  const byId = new Map(ledger.entries.map((entry) => [entry.id, entry]));
  for (const result of options.steps || []) {
    if (result.state !== "landed") continue;
    const id = findingIdOf(result.step, round);
    if (!id) {
      notes.push(result.step + " names no ledger id");
      continue;
    }
    if (fixedIds.includes(id)) continue;
    const entry = byId.get(id);
    if (!entry) {
      notes.push(result.step + " names " + id + ", which has no ledger entry");
      continue;
    }
    if (!FIXABLE_STATES.has(entry.state)) {
      notes.push(id + " is " + entry.state + ", so no fixed line was written");
      continue;
    }
    const line = "FINDING LEDGER — " + id + " fixed " + entry.severity + " " + entry.anchor + " | " + entry.summary;
    const parsed = ledgerLib.parseLedgerLine(line);
    if (!parsed || parsed.malformed || parsed.id !== id || parsed.disposition !== "fixed") {
      notes.push(id + " could not be rendered as a valid ledger line");
      continue;
    }
    lines.push(line);
    fixedIds.push(id);
  }
  return { lines, fixedIds, notes, usable: true, ledgerStatus: ledger.status };
}

function anchorPath(anchor) {
  const text = String(anchor == null ? "" : anchor);
  if (text === "" || text === "-") return null;
  const cut = text.lastIndexOf(":");
  const rel = cut > 0 && /^[0-9]/.test(text.slice(cut + 1)) ? text.slice(0, cut) : text;
  return safeRelative(rel) ? rel : null;
}

function uniqueSorted(list) {
  return Array.from(new Set(list)).sort();
}

function packetFiles(options) {
  const ignored = new Set(options.ignored || []);
  const keep = (rel) => safeRelative(rel) && reviewable(rel) && !ignored.has(rel);
  const changeSet = uniqueSorted((options.changeSet || []).filter(keep));
  const openPaths = [];
  for (const entry of options.openEntries || []) {
    const rel = anchorPath(entry.anchor);
    if (rel && keep(rel)) openPaths.push(rel);
  }
  const scope = options.scope;
  if (options.incremental && scope && scope.status === "ok") {
    const delta = scope.files.filter(keep);
    return { panel: uniqueSorted(delta.concat(openPaths)), judge: changeSet, narrowed: true, reason: "round-delta" };
  }
  const reason = options.incremental ? "scope-" + (scope ? scope.status : "unavailable") : "incremental-off";
  return { panel: changeSet, judge: changeSet, narrowed: false, reason };
}

function activationFor(files, options) {
  const report = activationLib.activate(options.activation ? files : [], { panel: options.panel, round: "re" });
  const verdicts = report && Array.isArray(report.verdicts) ? report.verdicts : [];
  return {
    spawn: verdicts.filter((verdict) => verdict.spawn).map((verdict) => verdict.aspect),
    skipped: verdicts.filter((verdict) => !verdict.spawn).map((verdict) => ({ aspect: verdict.aspect, reason: verdict.reason })),
  };
}

function readLines(file) {
  if (!file) return [];
  return fs.readFileSync(file, "utf8").split("\n").map((line) => line.replace(/\r$/, "")).filter((line) => line !== "");
}

function prepare(input) {
  const round = parseRound(input.round);
  const out = [];
  const log = [];
  if (!round) return { status: "refused", log, out: ["ROUND PREPARE REFUSED — --round must be 0, a fix round number or self-review"], diff: [] };
  const changeSet = readLines(input.changeSetFile);
  const chain = chainOf(input.log);
  const snapshotRead = readSnapshot(input.snapshotFile, input.top);
  const baseline = input.baseline || "";
  const start = resolveStart(snapshotRead, round, chain, baseline);
  const current = digestFiles(input.top, changeSet);
  const nextEntry = { at: input.now, baseline, files: current.files, truncated: current.truncated };
  const finish = (status, diff) => {
    if (status === "ok" && round.kind !== "self-review") {
      const doc = snapshotRead.ok ? snapshotRead.doc : null;
      const written = writeSnapshot(input.snapshotFile, recordRound(doc, input.top, chain, round.label, nextEntry));
      if (!written.ok) {
        out.push("ROUND PREPARE — the snapshot for the next round was not written (" + written.reason + "); the next round cannot attribute fixes to its own edits");
      } else if (round.kind === "first") {
        log.push(ROUND_ZERO_LINE + " (" + Object.keys(current.files).length + " changed files)");
      }
    }
    return { status, log, out, diff: diff || [] };
  };
  if (round.kind === "first") {
    out.push(ROUND_ZERO_LINE + " (" + Object.keys(current.files).length + " changed files)");
    return finish("ok");
  }
  const auditLines = readLines(input.auditFile);
  const landing = resolveLanding({
    auditLines,
    round,
    start: start.entry,
    current: current.files,
    chain,
    digestNow: (rel) => (safeRelative(rel) ? digestFile(input.top, rel) : null),
  });
  const closing = auditLines.filter((line) => AUDIT_CLOSE.test(line));
  for (const line of landing.carried) log.push(line);
  for (const line of closing) log.push(line);
  for (const line of landing.carried) if (!line.startsWith("PENDING PREDICATE — ")) out.push(line);
  for (const line of closing) out.push(line);
  if (closing.some((line) => RECEIPT_REFUSED.test(line))) {
    out.push("ROUND PREPARE STOPPED — edit-landing: the audit graded the claims but could not write its receipt; resolve the RECEIPT REFUSED line above, then run the verb again");
    return { status: "fault", log, out, diff: [] };
  }
  for (const result of landing.steps) {
    const count = (outcome) => result.files.filter((item) => item.outcome === outcome).length;
    const withdrawn = count("withdrawn");
    const failed = result.files.length - count("landed") - count("unchanged") - count("unresolved") - withdrawn;
    const shared = result.files.filter((item) => item.shared).length;
    const line =
      "ROUND LANDING — " + result.step + ": " + result.state +
      " (files=" + result.files.length + " changed=" + count("landed") + " unchanged=" + count("unchanged") +
      " unresolved=" + count("unresolved") + " failed=" + failed +
      (withdrawn ? " withdrawn=" + withdrawn : "") + (shared ? " shared=" + shared : "") + ")";
    log.push(line);
    out.push(line);
  }
  if (!start.entry) {
    const line = "ROUND LANDING UNAVAILABLE — no round-start snapshot (" + start.reason + "), so no claim of this round could be attributed and no fixed line was written";
    log.push(line);
    out.push(line);
  }
  if (landing.otherPending) out.push("pending_earlier_claims: " + landing.otherPending + " (earlier rounds, graded there)");
  const withdrawnSteps = landing.steps.filter((result) => result.state === "withdrawn").map((result) => result.step);
  if (withdrawnSteps.length) out.push("withdrawn_claims: " + withdrawnSteps.join(", "));
  const unprefixed = unprefixedClaims(chain, round);
  if (unprefixed.length) {
    out.push("unprefixed_claims: " + unprefixed.join(", ") + " (logged since this round began without the " + roundPrefix(round) + "- prefix, so no fixed line can name their findings)");
  }
  const failed = landing.steps.filter((result) => result.state === "not-landed");
  if (failed.length) {
    const detail = failed
      .map((result) => {
        const files = result.files.filter((item) => FAILED_OUTCOMES.has(item.outcome));
        return result.step + " (" + files.map((item) => (item.file === null ? "no file" : item.file) + " " + item.outcome).join(", ") + ")";
      })
      .join("; ");
    out.push(
      "ROUND PREPARE STOPPED — edit-landing: " + failed.length + " claim(s) of this round did not land in this round: " + detail +
        "; the verdict lines above name each kind: land the edit, or log CLAIM WITHDRAWN — <label>: <file> for a claim that cannot land (CLAIM WITHDRAWN — <label> for one listed with no file), then run the verb again"
    );
    return { status: "stopped", log, out, diff: [] };
  }
  let fixed = { lines: [], fixedIds: [], notes: [], usable: false, ledgerStatus: "off" };
  let report = null;
  if (input.convergence) {
    report = ledgerLib.ledgerState({ log: input.log, root: input.top, report: true });
    fixed = fixedLines({ round, ledger: report, steps: landing.steps });
    for (const line of fixed.lines) log.push(line);
    if (!fixed.usable) {
      const line = "ROUND LEDGER UNAVAILABLE — " + fixed.ledgerStatus + "; no fixed line was written";
      log.push(line);
      out.push(line);
    }
  } else {
    out.push("open_ledger: off (hooks.reviewConvergence is off); no fixed line was written");
  }
  for (const note of fixed.notes) out.push("ledger_note: " + note);
  out.push("fixed: " + (fixed.fixedIds.length ? fixed.fixedIds.join(", ") : "none"));
  out.push("unresolved_claims: " + (landing.steps.filter((result) => result.state === "unresolved").map((result) => result.step).join(", ") || "none"));
  if (round.kind === "self-review") return finish("ok");
  let openEntries = [];
  if (input.convergence) {
    if (report.status === "ok" || report.status === "partial") {
      openEntries = report.entries.filter((entry) => OPEN_STATES.has(entry.state) && !fixed.fixedIds.includes(entry.id));
    }
    out.push("open_ledger: " + (report.status === "ok" || report.status === "partial" ? openEntries.length + " open" : report.status + " (" + report.reason + ")"));
    for (const entry of openEntries) out.push("open " + entry.id + " " + entry.state + " " + entry.severity + " " + entry.anchor + " | " + entry.summary);
  }
  const scope = input.incremental ? scopeLib.roundScope({ log: input.log, round: round.number, root: input.top }) : null;
  const ignored = readLines(input.ignoredFile);
  const files = packetFiles({ changeSet, openEntries, scope, incremental: input.incremental, ignored });
  const hidden = changeSet.filter((rel) => ignored.includes(rel)).length;
  if (hidden) out.push("user_ignored: " + hidden + " changed path(s) your own git excludes ignore are left out of the packet lists and the round diff");
  const activation = activationFor(files.panel, { activation: input.activation, panel: input.panel });
  for (const skipped of activation.skipped) log.push("ASPECT SKIPPED — " + skipped.aspect + " (" + skipped.reason + ")");
  out.push("changed_files (" + files.reason + "): " + (files.panel.length ? files.panel.join(", ") : "none"));
  out.push("judge_changed_files: " + (files.judge.length ? files.judge.join(", ") : "none"));
  out.push("spawn: " + (activation.spawn.length ? activation.spawn.join(", ") : "none"));
  return finish("ok", files.panel);
}

function render(result) {
  const lines = [];
  for (const line of result.log) lines.push("log " + line);
  for (const rel of result.diff) lines.push("diff " + rel);
  for (const line of result.out) lines.push("out " + line);
  lines.push("status " + result.status);
  return lines.join("\n") + "\n";
}

function startPaths(input) {
  const round = parseRound(input.round);
  if (!round || round.kind === "first") return { ok: false, reason: "no-round-start" };
  const start = resolveStart(readSnapshot(input.snapshotFile, input.top), round, chainOf(input.log), input.baseline);
  if (!start.entry) return { ok: false, reason: start.reason };
  return { ok: true, paths: Object.keys(start.entry.files).sort() };
}

function inputFromEnvironment(env) {
  return {
    round: env.ZENSU_RP_ROUND,
    top: env.ZENSU_RP_TOP,
    log: env.ZENSU_RP_LOG,
    snapshotFile: env.ZENSU_RP_SNAPSHOT,
    changeSetFile: env.ZENSU_RP_CHANGES,
    auditFile: env.ZENSU_RP_AUDIT || "",
    ignoredFile: env.ZENSU_RP_IGNORED || "",
    baseline: env.ZENSU_RP_BASELINE || "",
    incremental: env.ZENSU_RP_INCREMENTAL === "on",
    activation: env.ZENSU_RP_ACTIVATION === "on",
    convergence: env.ZENSU_RP_CONVERGENCE === "on",
    panel: env.ZENSU_RP_PANEL === "full" ? "full" : "lean",
    now: Date.now(),
  };
}

function cliMain(argv, env) {
  const input = inputFromEnvironment(env);
  if (argv[0] === "start-paths") {
    const start = startPaths(input);
    if (!start.ok) return { code: 3, stdout: "", stderr: "round-prepare: no round-start snapshot (" + start.reason + ")\n" };
    return { code: 0, stdout: start.paths.length ? start.paths.join("\n") + "\n" : "", stderr: "" };
  }
  if (argv[0] === "prepare") {
    const result = prepare(input);
    return { code: 0, stdout: render(result), stderr: "" };
  }
  return { code: 2, stdout: "", stderr: "round-prepare: unknown mode\n" };
}

if (require.main === module) {
  let result;
  try {
    result = cliMain(process.argv.slice(2), process.env);
  } catch (error) {
    result = { code: 2, stdout: "", stderr: "round-prepare: internal error (" + (error && error.message ? error.message : "unknown") + ")\n" };
  }
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  process.exitCode = result.code;
}

module.exports = {
  SCHEMA,
  LIMITS,
  parseRound,
  labelInRound,
  findingIdOf,
  parseAuditLine,
  digestFile,
  digestFiles,
  readSnapshot,
  claimOf,
  chainOf,
  unprefixedClaims,
  resolveStart,
  recordRound,
  writeSnapshot,
  resolveLanding,
  fixedLines,
  anchorPath,
  packetFiles,
  activationFor,
  prepare,
  render,
  startPaths,
  inputFromEnvironment,
  cliMain,
};
