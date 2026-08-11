// plan-payload-v1.js — resolve the approved plan out of an ExitPlanMode hook payload.
//
// Extracted from the node -e block in hooks/plan-approved-delegate.sh so the
// decision can be unit-tested and so the sibling ports (zensu-codex,
// zensu-kiro, zensu-antigravity) can take a delta instead of re-deriving it.
// The hook keeps the reason-code -> BLOCK_CODE mapping and owns every emission.
//
// THE FOUR SOURCES, in precedence order. `live` records whether the CURRENT
// Claude Code build can populate the carrier at all:
//
//   1. tool_input.plan          live: NO  — see the stripping note below
//   2. tool_input.planFilePath  live: NO  — same
//   3. tool_response.plan       live: YES — what the harness delivers today
//   4. tool_response.filePath   live: YES — the file the harness saved
//
// Sources 1-2 are kept ranked FIRST on purpose: a host that does declare the
// fields (or an older build) must keep its existing meaning, and a caller that
// passes an explicit plan must not be overridden by the harness copy.
//
// Retiring them is not a four-check edit, and the roster of checks that bind
// them lives in ONE place: CLAUDE.md section "Plan-Gate Payload Sources". The
// trigger is a RE-CAPTURE, not a hunch — only a fresh capture from every
// supported host can show that none of them populates tool_input any more.
//
// SOURCES is THIS host's table and the module owns it. resolveApprovedPlan
// takes a table argument so the unit suite can drive the walk with a synthetic
// one; a port does not call in with its own table, it edits SOURCES in its copy
// of this file. The argument refuses an empty or malformed table rather than
// substituting ours, so a port that tries the other way fails closed.
//
// Fields are read by NAME and never by scanning text. The rendered response a
// model sees carries a "Your plan has been saved to: <path>" preamble, but the
// plan body is model-authored: mining that text would let plan prose inject its
// own preamble line and name the path this reader opens.
//
// The digest the caller records is over `buffer` when a file fed the plan and
// over the transported string otherwise, so source 3 binds the bytes that
// travelled, not the file at source 4's path. The two agreed byte-for-byte in
// the captured payload this was built against; they are not contracted to.

"use strict";

const fs = require("fs");
const nodePath = require("path");

const PLAN_FILE_MAX_BYTES = 4 * 1024 * 1024;

const REASONS = {
  MISSING: "INVALID_PLAN_PAYLOAD",
  FIELD_TYPE: "PLAN_PAYLOAD_FIELD_TYPE_REJECTED",
  UNREADABLE: "PLAN_FILE_UNREADABLE",
  PATH_REJECTED: "PLAN_FILE_PATH_REJECTED",
  NOT_REGULAR: "PLAN_FILE_NOT_REGULAR",
  EMPTY: "PLAN_FILE_EMPTY",
  TOO_LARGE: "PLAN_FILE_TOO_LARGE",
  SYMLINK: "PLAN_FILE_SYMLINK_REJECTED",
};

const SOURCES = [
  { carrier: "tool_input", field: "plan", kind: "text", label: "tool_input.plan", live: false },
  { carrier: "tool_input", field: "planFilePath", kind: "path", label: "tool_input.planFilePath", live: false },
  { carrier: "tool_response", field: "plan", kind: "text", label: "tool_response.plan", live: true },
  { carrier: "tool_response", field: "filePath", kind: "path", label: "tool_response.filePath", live: true },
];

const refuse = (reason, source) => ({ ok: false, reason, source: source || "" });

// A carrier contributes named fields only when it is a plain object. Anything
// else — a string, an array, null — carries no field to read and is absent.
const carrierOf = (payload, name) => {
  const raw = payload && payload[name];
  return raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
};

const readPlanFile = (planPath) => {
  if (planPath.indexOf(String.fromCharCode(0)) >= 0) return { failure: REASONS.PATH_REJECTED };
  if (!nodePath.isAbsolute(planPath)) return { failure: REASONS.PATH_REJECTED };
  if (/^[\\/]{2}/.test(planPath)) return { failure: REASONS.PATH_REJECTED };
  const noFollow = process.platform !== "win32" && Number.isInteger(fs.constants.O_NOFOLLOW)
    ? fs.constants.O_NOFOLLOW : 0;
  const nonBlock = Number.isInteger(fs.constants.O_NONBLOCK) ? fs.constants.O_NONBLOCK : 0;
  let failure = "";
  let before = null;
  let bytes = null;
  if (noFollow === 0) {
    try { before = fs.lstatSync(planPath); } catch (_) { return { failure: REASONS.UNREADABLE }; }
    if (before.isSymbolicLink()) return { failure: REASONS.SYMLINK };
  }
  let descriptor = null;
  try {
    descriptor = fs.openSync(planPath, fs.constants.O_RDONLY | noFollow | nonBlock);
  } catch (error) {
    failure = error && (error.code === "ELOOP" || error.code === "EMLINK")
      ? REASONS.SYMLINK : REASONS.UNREADABLE;
  }
  if (descriptor !== null) {
    try {
      const stat = fs.fstatSync(descriptor);
      if (before !== null && (before.dev !== stat.dev || before.ino !== stat.ino)) failure = REASONS.SYMLINK;
      else if (!stat.isFile()) failure = REASONS.NOT_REGULAR;
      else if (stat.nlink !== 1) failure = REASONS.SYMLINK;
      else if (stat.size < 1) failure = REASONS.EMPTY;
      else if (stat.size > PLAN_FILE_MAX_BYTES) failure = REASONS.TOO_LARGE;
      else {
        const buffer = Buffer.alloc(stat.size);
        let filled = 0;
        while (filled < stat.size) {
          const chunk = fs.readSync(descriptor, buffer, filled, stat.size - filled, filled);
          if (chunk < 1) break;
          filled += chunk;
        }
        if (filled !== stat.size) failure = REASONS.UNREADABLE;
        else bytes = buffer;
      }
    } catch (_) { failure = REASONS.UNREADABLE; }
    try { fs.closeSync(descriptor); } catch (_) {}
  }
  if (failure) return { failure };
  if (bytes === null) return { failure: REASONS.UNREADABLE };
  return { bytes };
};

// Returns {ok:true, plan, buffer, source} or {ok:false, reason, source}.
// `buffer` is null when the plan travelled as text; the caller digests it then.
const resolveApprovedPlan = (payload, sources) => {
  // "omitted" and "supplied but unusable" are different answers. Substituting
  // this host's table for a port's empty one would hand it carriers it never
  // chose — two of which open a payload-named file — so only omission falls back.
  const table = sources === undefined ? SOURCES : sources;
  if (!Array.isArray(table) || !table.length) return refuse(REASONS.MISSING, "");
  // Prototype-free: `"constructor" in {}` is true, so a plain object would let a
  // carrier named after an inherited member read Object.prototype instead of the
  // payload and resolve a function's name as a plan.
  const carriers = Object.create(null);
  for (const source of table) {
    if (!(source.carrier in carriers)) carriers[source.carrier] = carrierOf(payload, source.carrier);
  }
  for (const source of table) {
    const carrier = carriers[source.carrier];
    const value = carrier[source.field];
    if (value === undefined || value === null) continue;
    if (typeof value !== "string") return refuse(REASONS.FIELD_TYPE, source.label);
    if (!value) continue;
    if (source.kind === "text") return { ok: true, plan: value, buffer: null, source: source.label };
    // Anything that is not an explicit "path" is a table defect, not a plan. Do
    // NOT fall through to the file reader: an entry meant to carry plan TEXT
    // would then have its bytes opened as a path.
    if (source.kind !== "path") return refuse(REASONS.FIELD_TYPE, source.label);
    const read = readPlanFile(value);
    if (read.failure) return refuse(read.failure, source.label);
    const plan = read.bytes.toString("utf8");
    if (!plan) return refuse(REASONS.EMPTY, source.label);
    return { ok: true, plan, buffer: read.bytes, source: source.label };
  }
  return refuse(REASONS.MISSING, "");
};

module.exports = { resolveApprovedPlan, readPlanFile, PLAN_FILE_MAX_BYTES, REASONS, SOURCES };
