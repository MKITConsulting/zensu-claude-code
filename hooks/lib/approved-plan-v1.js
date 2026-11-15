"use strict";

const childProcess = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const nodePath = require("path");
const { readPlanFile, platformNoFollow, PLAN_FILE_MAX_BYTES, REASONS } = require("./plan-payload-v1.js");

const APPROVED_PLAN_PREFIX = "autopilot-approved-plan-";

const APPROVED_PLAN_FAILURES = {
  DIGEST: "approved-plan-digest-invalid",
  ROOT: "approved-plan-project-root-rejected",
  STATE_DIRECTORY: "approved-plan-state-directory-rejected",
  MISSING: "approved-plan-missing",
  MISMATCH: "approved-plan-digest-mismatch",
  WRITE: "approved-plan-write-failed",
  UNREADABLE: "approved-plan-unreadable",
  LINKED: "approved-plan-linked",
  EMPTY: "approved-plan-empty",
  TOO_LARGE: "approved-plan-too-large",
};

const PLAN_CRITERIA_CONTENT_EXITS = Object.freeze([0, 3, 4, 5]);

const PLAN_CRITERIA_TIMEOUT_MS = 60000;

const AC_RE = /^AC-([0-9]+)([a-z]?)$/;

const sha256Hex = (bytes) => crypto.createHash("sha256").update(bytes).digest("hex");

const readFailure = (failure) => {
  if (failure === REASONS.SYMLINK) return APPROVED_PLAN_FAILURES.LINKED;
  if (failure === REASONS.EMPTY) return APPROVED_PLAN_FAILURES.EMPTY;
  if (failure === REASONS.TOO_LARGE) return APPROVED_PLAN_FAILURES.TOO_LARGE;
  return APPROVED_PLAN_FAILURES.UNREADABLE;
};

const syncDirectory = (directory) => {
  if (process.platform === "win32") return;
  let descriptor = null;
  try {
    descriptor = fs.openSync(directory, "r");
    fs.fsyncSync(descriptor);
  } catch (_) {
  } finally {
    if (descriptor !== null) {
      try { fs.closeSync(descriptor); } catch (_) {}
    }
  }
};

const approvedPlanStem = (sha) =>
  typeof sha === "string" && /^[0-9a-f]{64}$/.test(sha) ? `${APPROVED_PLAN_PREFIX}${sha}` : null;

const approvedPlanRelPath = (sha) => {
  const stem = approvedPlanStem(sha);
  return stem === null ? null : `.zensu/state/${stem}.md`;
};

const approvedPlanDirectory = (projectRoot, create) => {
  if (typeof projectRoot !== "string" || !nodePath.isAbsolute(projectRoot)
    || projectRoot.indexOf(String.fromCharCode(0)) >= 0) return { failure: APPROVED_PLAN_FAILURES.ROOT };
  let directory = projectRoot;
  for (const segment of [".zensu", "state"]) {
    directory = nodePath.join(directory, segment);
    let stat = null;
    try {
      stat = fs.lstatSync(directory);
    } catch (error) {
      if (!create) {
        return { failure: error && error.code === "ENOENT" ? APPROVED_PLAN_FAILURES.MISSING : APPROVED_PLAN_FAILURES.STATE_DIRECTORY };
      }
      if (!error || error.code !== "ENOENT") return { failure: APPROVED_PLAN_FAILURES.STATE_DIRECTORY };
      try {
        fs.mkdirSync(directory, { mode: 0o700 });
        stat = fs.lstatSync(directory);
      } catch (_) {
        return { failure: APPROVED_PLAN_FAILURES.STATE_DIRECTORY };
      }
    }
    if (stat.isSymbolicLink() || !stat.isDirectory()) return { failure: APPROVED_PLAN_FAILURES.STATE_DIRECTORY };
  }
  return { directory };
};

const readApprovedPlan = (projectRoot, sha) => {
  const stem = approvedPlanStem(sha);
  if (stem === null) return { ok: false, reason: APPROVED_PLAN_FAILURES.DIGEST };
  const located = approvedPlanDirectory(projectRoot, false);
  if (located.failure) return { ok: false, reason: located.failure };
  const planPath = nodePath.join(located.directory, `${stem}.md`);
  try {
    fs.lstatSync(planPath);
  } catch (error) {
    return { ok: false, reason: error && error.code === "ENOENT" ? APPROVED_PLAN_FAILURES.MISSING : APPROVED_PLAN_FAILURES.UNREADABLE };
  }
  const read = readPlanFile(planPath);
  if (read.failure) return { ok: false, reason: readFailure(read.failure) };
  if (sha256Hex(read.bytes) !== sha) return { ok: false, reason: APPROVED_PLAN_FAILURES.MISMATCH };
  return { ok: true, path: planPath, rel: approvedPlanRelPath(sha), stem, bytes: read.bytes };
};

const storeApprovedPlan = (projectRoot, sha, bytes) => {
  const stem = approvedPlanStem(sha);
  if (stem === null) return { ok: false, reason: APPROVED_PLAN_FAILURES.DIGEST };
  if (!Buffer.isBuffer(bytes) || bytes.length < 1) return { ok: false, reason: APPROVED_PLAN_FAILURES.EMPTY };
  if (bytes.length > PLAN_FILE_MAX_BYTES) return { ok: false, reason: APPROVED_PLAN_FAILURES.TOO_LARGE };
  if (sha256Hex(bytes) !== sha) return { ok: false, reason: APPROVED_PLAN_FAILURES.MISMATCH };
  const existing = readApprovedPlan(projectRoot, sha);
  if (existing.ok) return { ok: true, path: existing.path, rel: existing.rel, stem, reused: true };
  const located = approvedPlanDirectory(projectRoot, true);
  if (located.failure) return { ok: false, reason: located.failure };
  const planPath = nodePath.join(located.directory, `${stem}.md`);
  const temporary = nodePath.join(located.directory, `.${stem}.${crypto.randomBytes(6).toString("hex")}.tmp`);
  let descriptor = null;
  try {
    descriptor = fs.openSync(temporary,
      fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | platformNoFollow(), 0o600);
    let written = 0;
    while (written < bytes.length) written += fs.writeSync(descriptor, bytes, written, bytes.length - written, written);
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = null;
    fs.renameSync(temporary, planPath);
    syncDirectory(located.directory);
  } catch (_) {
    if (descriptor !== null) {
      try { fs.closeSync(descriptor); } catch (_) {}
    }
    try { fs.unlinkSync(temporary); } catch (_) {}
    return { ok: false, reason: APPROVED_PLAN_FAILURES.WRITE };
  }
  const stored = readApprovedPlan(projectRoot, sha);
  if (!stored.ok) return { ok: false, reason: stored.reason };
  return { ok: true, path: stored.path, rel: stored.rel, stem, reused: false };
};

const listedRows = (stdout) => {
  const byId = new Map();
  for (const line of String(stdout || "").split("\n")) {
    if (line === "") continue;
    const parts = line.split("\t");
    if (parts.length < 3) continue;
    const [id, state] = parts;
    if (!AC_RE.test(id) || (state !== "active" && state !== "deprecated")) continue;
    const previous = byId.get(id);
    if (!previous || (previous.state === "deprecated" && state === "active")) byId.set(id, { id, state, text: parts.slice(2).join(" ") });
  }
  return [...byId.values()];
};

const listerVerdict = (result, planPath, label) => {
  if (result.error) {
    const cause = result.error.code || result.error.message || "error";
    return { status: "error", kind: "spawn", detail: `spawn-${result.error.code || "error"}`, cause };
  }
  const raw = String(result.stderr || "").trim().split("\n").filter(Boolean).pop() || "";
  const message = label === null ? raw : raw.split(planPath).join(label);
  if (result.signal) return { status: "error", kind: "signal", detail: `signal-${result.signal}`, cause: result.signal, message };
  if (!PLAN_CRITERIA_CONTENT_EXITS.includes(result.status)) {
    return { status: "error", kind: "exit", detail: `exit-${result.status}`, exit: result.status, message };
  }
  if (result.status === 3) return { status: "no-section", exit: 3, message };
  if (result.status === 5) return { status: "unparseable", exit: 5, message };
  const rows = listedRows(result.stdout);
  if (result.status === 4 && rows.length === 0) return { status: "unusable", exit: 4, message };
  return { status: "ok", exit: result.status, rows };
};

const runLister = (lister, planPath, options) => childProcess.spawnSync(options.bashPath || "bash",
  ["--noprofile", "--norc", lister, "--list", "--plan", planPath], {
    encoding: "utf8",
    timeout: options.timeoutMs || PLAN_CRITERIA_TIMEOUT_MS,
    maxBuffer: 16 * 1024 * 1024,
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],
  });

const listRequirementRows = (plan, options = {}) => {
  const lister = options.lister || nodePath.join(options.libDir || __dirname, "zensu-plan-requirements.sh");
  if (typeof lister !== "string" || (typeof plan !== "string" && !Buffer.isBuffer(plan))) {
    return { status: "error", kind: "input", detail: "input-rejected" };
  }
  if (typeof plan === "string") return listerVerdict(runLister(lister, plan, options), plan, null);
  let directory = null;
  try {
    directory = fs.mkdtempSync(nodePath.join(options.tmpDirectory || os.tmpdir(), "zensu-plan-criteria-"));
    const copy = nodePath.join(directory, "plan.md");
    fs.writeFileSync(copy, plan, { flag: "wx", mode: 0o600 });
    return listerVerdict(runLister(lister, copy, options), copy, options.label || "the approved plan");
  } catch (error) {
    return { status: "error", kind: "copy", detail: `copy-${(error && error.code) || "error"}`, cause: (error && (error.code || error.message)) || "error" };
  } finally {
    if (directory !== null) {
      try { fs.rmSync(directory, { recursive: true, force: true }); } catch (_) {}
    }
  }
};

const listPlanCriteria = (bytes, options = {}) => {
  if (!Buffer.isBuffer(bytes)) return { status: "unreadable", detail: "input-rejected" };
  const listed = listRequirementRows(bytes, options);
  if (listed.status === "error") return { status: "unreadable", detail: listed.detail };
  const active = listed.status === "ok" ? listed.rows.filter((row) => row.state === "active").length : 0;
  return active > 0 ? { status: "ok", active } : { status: "unusable", detail: `exit-${listed.exit}` };
};

module.exports = {
  APPROVED_PLAN_PREFIX, APPROVED_PLAN_FAILURES, PLAN_CRITERIA_CONTENT_EXITS, AC_RE, approvedPlanStem, approvedPlanRelPath,
  readApprovedPlan, storeApprovedPlan, listRequirementRows, listPlanCriteria,
};
