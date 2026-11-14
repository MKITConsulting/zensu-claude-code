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

const sha256Hex = (bytes) => crypto.createHash("sha256").update(bytes).digest("hex");

const readFailure = (failure) => {
  if (failure === REASONS.SYMLINK) return APPROVED_PLAN_FAILURES.LINKED;
  if (failure === REASONS.EMPTY) return APPROVED_PLAN_FAILURES.EMPTY;
  if (failure === REASONS.TOO_LARGE) return APPROVED_PLAN_FAILURES.TOO_LARGE;
  return APPROVED_PLAN_FAILURES.UNREADABLE;
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

const listPlanCriteria = (bytes, options = {}) => {
  const lister = options.lister || nodePath.join(__dirname, "zensu-plan-requirements.sh");
  if (!Buffer.isBuffer(bytes) || typeof lister !== "string") return { status: "unreadable", detail: "input-rejected" };
  let directory = null;
  try {
    directory = fs.mkdtempSync(nodePath.join(options.tmpDirectory || os.tmpdir(), "zensu-plan-criteria-"));
    const copy = nodePath.join(directory, "plan.md");
    fs.writeFileSync(copy, bytes, { flag: "wx", mode: 0o600 });
    const result = childProcess.spawnSync(options.bashPath || "bash", ["--noprofile", "--norc", lister, "--list", "--plan", copy], {
      encoding: "utf8",
      timeout: options.timeoutMs || PLAN_CRITERIA_TIMEOUT_MS,
      maxBuffer: 16 * 1024 * 1024,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (result.error) return { status: "unreadable", detail: `spawn-${result.error.code || "error"}` };
    if (result.signal) return { status: "unreadable", detail: `signal-${result.signal}` };
    if (!PLAN_CRITERIA_CONTENT_EXITS.includes(result.status)) return { status: "unreadable", detail: `exit-${result.status}` };
    let active = 0;
    for (const line of String(result.stdout || "").split("\n")) {
      const fields = line.split("\t");
      if (fields.length >= 3 && /^AC-[0-9]/.test(fields[0]) && fields[1] === "active") active += 1;
    }
    return active > 0 ? { status: "ok", active } : { status: "unusable", detail: `exit-${result.status}` };
  } catch (error) {
    return { status: "unreadable", detail: `copy-${(error && error.code) || "error"}` };
  } finally {
    if (directory !== null) {
      try { fs.rmSync(directory, { recursive: true, force: true }); } catch (_) {}
    }
  }
};

module.exports = {
  APPROVED_PLAN_PREFIX, APPROVED_PLAN_FAILURES, PLAN_CRITERIA_CONTENT_EXITS, approvedPlanStem, approvedPlanRelPath,
  readApprovedPlan, storeApprovedPlan, listPlanCriteria,
};
