'use strict';

const fs = require('node:fs');
const nodePath = require('node:path');

const PLAN_FILE_MAX_BYTES = 4 * 1024 * 1024;

const EXIT_CODES = Object.freeze({
  INVALID_PLAN_PAYLOAD: 3,
  PLAN_FILE_UNREADABLE: 8,
  PLAN_FILE_PATH_REJECTED: 10,
  PLAN_FILE_NOT_REGULAR: 11,
  PLAN_FILE_EMPTY: 12,
  PLAN_FILE_TOO_LARGE: 13,
  PLAN_FILE_SYMLINK_REJECTED: 14,
  PLAN_PAYLOAD_FIELD_TYPE_REJECTED: 15,
  PLAN_RESPONSE_SHAPE_REJECTED: 16,
});

// A frozen array, not a frozen Set: Object.freeze does not seal a Set's
// contents, so .add/.delete would still work on the allowlist that gates both
// refuse() and exitCodeOf().
const CODE_VALUES = Object.freeze(Object.values(EXIT_CODES));

// `strict` is the per-container drift policy, carried on the declaration rather
// than branched on inside the reader: a new container must state whether a
// present non-object value is drift (refused) or plain absence (descends).
const CONTAINERS = Object.freeze([
  Object.freeze({ name: 'toolResponse', strict: true }),
  Object.freeze({ name: 'toolInput', strict: false }),
]);

// Source ORDER is an authorization decision: the winning source feeds the
// run-marker match as well as the digest. CLAUDE.md carries the rationale and
// the exposure a new source would introduce; this table is the enforced copy.
const PLAN_SOURCES = Object.freeze([
  Object.freeze({ container: 'toolResponse', key: 'plan', kind: 'text' }),
  Object.freeze({ container: 'toolResponse', key: 'filePath', kind: 'file' }),
  Object.freeze({ container: 'toolInput', key: 'plan', kind: 'text' }),
  Object.freeze({ container: 'toolInput', key: 'planFilePath', kind: 'file' }),
]);

// Both tables are validated once, at load time, instead of by per-call runtime
// guards. A malformed entry then throws inside `require`, which the hook's
// evaluator turns into PLAN_EVALUATION_UNAVAILABLE — fail-closed, and it keeps
// the reader loop free of checks that suggest containers arrive from config.
const DECLARED_CONTAINERS = [];
for (const entry of CONTAINERS) {
  if (typeof entry.name !== 'string' || entry.name === '') {
    throw new Error('plan-payload container must declare a non-empty string name');
  }
  if (DECLARED_CONTAINERS.indexOf(entry.name) >= 0) {
    throw new Error('plan-payload container name is declared twice: ' + entry.name);
  }
  DECLARED_CONTAINERS.push(entry.name);
  if (typeof entry.strict !== 'boolean') {
    throw new Error('plan-payload container must declare a boolean strict policy: ' + entry.name);
  }
}
for (const source of PLAN_SOURCES) {
  if (DECLARED_CONTAINERS.indexOf(source.container) < 0) {
    throw new Error('plan-payload source names an unknown container: ' + source.container);
  }
  if (typeof source.key !== 'string' || source.key === '') {
    throw new Error('plan-payload source must declare a non-empty string key: ' + source.container);
  }
  if (source.kind !== 'text' && source.kind !== 'file') {
    throw new Error('plan-payload source names an unknown kind: ' + source.kind);
  }
}

class PlanPayloadRefusal extends Error {
  constructor(exitCode) {
    super('plan-payload refusal ' + exitCode);
    this.name = 'PlanPayloadRefusal';
    this.exitCode = exitCode;
  }
}

function refuse(exitCode) {
  if (!CODE_VALUES.includes(exitCode)) {
    throw new Error('plan-payload refusal code is not in EXIT_CODES: ' + exitCode);
  }
  throw new PlanPayloadRefusal(exitCode);
}

function exitCodeOf(error) {
  return error instanceof PlanPayloadRefusal && CODE_VALUES.includes(error.exitCode)
    ? error.exitCode
    : null;
}

function asObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
}

function normalizeToolResponse(rawResponse) {
  if (rawResponse !== undefined && rawResponse !== null && asObject(rawResponse) === null) {
    refuse(EXIT_CODES.PLAN_RESPONSE_SHAPE_REJECTED);
  }
  return asObject(rawResponse) || {};
}

function readStringField(source, key) {
  const value = (asObject(source) || {})[key];
  if (value === undefined || value === null) return '';
  if (typeof value !== 'string') refuse(EXIT_CODES.PLAN_PAYLOAD_FIELD_TYPE_REJECTED);
  return value;
}

function defaultNoFollowFlag() {
  return process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW)
    ? fs.constants.O_NOFOLLOW
    : 0;
}

// Callers must have established the authorization envelope first — owner
// session, run stage, tool binding and caller origin all live in
// hooks/plan-approved-delegate.sh, not here. See the CLAUDE.md section.
function readPlanFile(planPath, options) {
  if (typeof planPath !== 'string') refuse(EXIT_CODES.PLAN_FILE_PATH_REJECTED);
  if (planPath.indexOf(String.fromCharCode(0)) >= 0) refuse(EXIT_CODES.PLAN_FILE_PATH_REJECTED);
  if (!nodePath.isAbsolute(planPath)) refuse(EXIT_CODES.PLAN_FILE_PATH_REJECTED);
  if (/^[\\/]{2}/.test(planPath)) refuse(EXIT_CODES.PLAN_FILE_PATH_REJECTED);
  const settings = asObject(options) || {};
  // The seam selects between the two intended modes only. It must never accept
  // a caller-supplied flag mask: an arbitrary nonzero value would skip the
  // lstat pre-check AND the dev/ino recheck while contributing no O_NOFOLLOW.
  const noFollow = settings.noFollow === 0 ? 0 : defaultNoFollowFlag();
  const nonBlock = Number.isInteger(fs.constants.O_NONBLOCK) ? fs.constants.O_NONBLOCK : 0;
  let failure = 0;
  let before = null;
  let bytes = null;
  if (noFollow === 0) {
    try { before = fs.lstatSync(planPath); } catch (_) { refuse(EXIT_CODES.PLAN_FILE_UNREADABLE); }
    if (before.isSymbolicLink()) refuse(EXIT_CODES.PLAN_FILE_SYMLINK_REJECTED);
  }
  let descriptor = null;
  try {
    descriptor = fs.openSync(planPath, fs.constants.O_RDONLY | noFollow | nonBlock);
  } catch (error) {
    failure = error && (error.code === 'ELOOP' || error.code === 'EMLINK')
      ? EXIT_CODES.PLAN_FILE_SYMLINK_REJECTED
      : EXIT_CODES.PLAN_FILE_UNREADABLE;
  }
  if (descriptor !== null) {
    try {
      const stat = fs.fstatSync(descriptor);
      if (before !== null && (before.dev !== stat.dev || before.ino !== stat.ino)) failure = EXIT_CODES.PLAN_FILE_SYMLINK_REJECTED;
      else if (!stat.isFile()) failure = EXIT_CODES.PLAN_FILE_NOT_REGULAR;
      else if (stat.nlink !== 1) failure = EXIT_CODES.PLAN_FILE_SYMLINK_REJECTED;
      else if (stat.size < 1) failure = EXIT_CODES.PLAN_FILE_EMPTY;
      else if (stat.size > PLAN_FILE_MAX_BYTES) failure = EXIT_CODES.PLAN_FILE_TOO_LARGE;
      else {
        const buffer = Buffer.alloc(stat.size);
        let filled = 0;
        while (filled < stat.size) {
          const chunk = fs.readSync(descriptor, buffer, filled, stat.size - filled, filled);
          if (chunk < 1) break;
          filled += chunk;
        }
        if (filled !== stat.size) failure = EXIT_CODES.PLAN_FILE_UNREADABLE;
        else bytes = buffer;
      }
    } catch (_) { failure = EXIT_CODES.PLAN_FILE_UNREADABLE; }
    try { fs.closeSync(descriptor); } catch (_) {}
  }
  if (failure) refuse(failure);
  if (bytes === null || bytes.length < 1) refuse(EXIT_CODES.PLAN_FILE_EMPTY);
  return bytes;
}

function readPlanPayload(payload) {
  const supplied = asObject(payload) || {};
  const containers = {};
  for (const entry of CONTAINERS) {
    containers[entry.name] = entry.strict
      ? normalizeToolResponse(supplied[entry.name])
      : asObject(supplied[entry.name]) || {};
  }
  let plan = '';
  let bytes = null;
  let chosen = null;
  for (const source of PLAN_SOURCES) {
    const value = readStringField(containers[source.container], source.key);
    if (!value) continue;
    if (source.kind === 'text') { plan = value; bytes = Buffer.from(value, 'utf8'); }
    else { bytes = readPlanFile(value); plan = bytes.toString('utf8'); }
    chosen = source;
    break;
  }
  if (!plan) refuse(EXIT_CODES.INVALID_PLAN_PAYLOAD);
  // `bytes` is always the canonical digest input, so no caller has to choose
  // between two representations and risk re-encoding invalid UTF-8.
  return { plan, bytes, source: chosen };
}

module.exports = {
  CONTAINERS,
  EXIT_CODES,
  PLAN_FILE_MAX_BYTES,
  PLAN_SOURCES,
  PlanPayloadRefusal,
  defaultNoFollowFlag,
  exitCodeOf,
  normalizeToolResponse,
  readPlanFile,
  readPlanPayload,
  readStringField,
};
