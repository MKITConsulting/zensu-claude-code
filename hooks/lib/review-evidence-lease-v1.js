#!/usr/bin/env node
'use strict';

// Capability-enforced, session-bound evidence leases for the two dedicated
// review workers. This module is intentionally the only implementation used
// by the model-side helper, SubagentStart/SubagentStop hooks, and PreToolUse.

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const hookSession = require('./claude-hook-session-v1.js');
const hostPaths = require('./claude-path-v1.js');

const SCHEMA = 'zensu.review-evidence-lease';
const SCHEMA_VERSION = 1;
const LEASE_ID_RE = /^rel1_[a-f0-9]{32}$/;
const ROLE_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
const HASH_RE = /^sha256:[a-f0-9]{64}$/;
const ALLOWED_KINDS = new Set(['plan-review', 'pr-review']);
const ALLOWED_TOOLS = new Set(['Read', 'Grep', 'Glob']);
const MAX_MANIFEST_BYTES = 1024 * 1024;
const MAX_RECORD_BYTES = 8 * 1024 * 1024;
const MAX_RESULT_BYTES = 128 * 1024;
const MAX_EVIDENCE_FILE_BYTES = 32 * 1024 * 1024;
const MAX_EVIDENCE_TOTAL_BYTES = 256 * 1024 * 1024;

// The store prefix, named once. This module OWNS the layout; the superseded-lease
// sweep in review-evidence-sweep-v1.js has to traverse exactly the chain storage()
// creates, and it consumes this constant rather than re-spelling it. A divergence
// would send the sweep walking a path that does not exist and land it in a blanket
// destination refusal, silently.
const REVIEW_EVIDENCE_SEGMENTS = ['review-evidence', 'v1'];
const MAX_EVIDENCE_FILES = 20000;
const LOCK_WAIT_ATTEMPTS = 200;
const LOCK_WAIT_MS = 25;
const UNSAFE_PATH_TEXT_RE = /[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/u;

function fail(message) {
  throw new Error(`review-evidence-lease-v1: ${message}`);
}

function diagnosticPath(value) {
  let rendered = '';
  for (const character of String(value)) {
    const codePoint = character.codePointAt(0);
    if ((codePoint >= 0 && codePoint <= 0x1f)
        || (codePoint >= 0x7f && codePoint <= 0x9f)
        || (codePoint >= 0x202a && codePoint <= 0x202e)
        || (codePoint >= 0x2066 && codePoint <= 0x2069)) {
      rendered += `\\u{${codePoint.toString(16).padStart(4, '0')}}`;
    } else {
      rendered += character;
    }
    if (rendered.length > 4096) return `${rendered.slice(0, 4096)}...`;
  }
  return rendered;
}

function sha256(data) {
  return `sha256:${crypto.createHash('sha256').update(data).digest('hex')}`;
}

function hashObject(value) {
  return sha256(Buffer.from(JSON.stringify(value), 'utf8'));
}

function requireSafeText(value, label, maxLength = 4096) {
  if (
    typeof value !== 'string'
    || value.trim() === ''
    || value.length > maxLength
    || UNSAFE_PATH_TEXT_RE.test(value)
  ) fail(`${label} is unavailable or unsafe`);
  return value;
}

function requireKind(kind) {
  requireSafeText(kind, 'lease kind', 32);
  if (!ALLOWED_KINDS.has(kind)) fail(`unsupported lease kind "${kind}"`);
  return kind;
}

function kindForAgentType(agentType) {
  if (agentType === 'zensu:plan-review-worker') return 'plan-review';
  if (agentType === 'zensu:pr-review-worker') return 'pr-review';
  return null;
}

function identity(stat) {
  return {
    size: stat.size,
    dev: String(stat.dev),
    ino: String(stat.ino),
    nlink: stat.nlink,
    mode: stat.mode,
    mtime_ms: stat.mtimeMs,
    ctime_ms: stat.ctimeMs,
  };
}

function sameIdentity(left, right) {
  return left.size === right.size
    && left.dev === String(right.dev)
    && left.ino === String(right.ino)
    && left.nlink === right.nlink
    && left.mode === right.mode
    && left.mtime_ms === right.mtimeMs
    && left.ctime_ms === right.ctimeMs;
}

function canonicalExisting(input, label, expected) {
  requireSafeText(input, label);
  const normalizedInput = hostPaths.normalizeHostPathInput(input, label);
  if (!path.isAbsolute(normalizedInput)) fail(`${label} must be an absolute path`);
  const requested = path.resolve(normalizedInput);
  let supplied;
  let canonical;
  try {
    supplied = fs.lstatSync(requested);
    canonical = fs.realpathSync.native(requested);
  } catch {
    fail(`${label} does not exist`);
  }
  if (supplied.isSymbolicLink()) fail(`${label} must not be a symlink`);
  // This also rejects a case-variant alias on a case-insensitive filesystem.
  if (canonical !== requested) fail(`${label} must use its canonical spelling`);
  const stat = fs.lstatSync(canonical);
  if (stat.isSymbolicLink()) fail(`${label} must not be a symlink`);
  if (expected === 'file' && !stat.isFile()) fail(`${label} must be a regular file`);
  if (expected === 'directory' && !stat.isDirectory()) fail(`${label} must be a directory`);
  if (stat.nlink !== 1 && expected === 'file') fail(`${label} must not be multiply linked`);
  return { canonical, stat };
}

function assertSecureWorkspaceRoot(workspaceRoot, initialStat) {
  const parsed = path.parse(workspaceRoot);
  const relative = path.relative(parsed.root, workspaceRoot);
  const segments = relative === '' ? [] : relative.split(path.sep);
  let current = parsed.root;
  for (let index = 0; index < segments.length; index += 1) {
    current = path.join(current, segments[index]);
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink() || !stat.isDirectory()
        || fs.realpathSync.native(current) !== current) {
      fail('review workspace path contains an unsafe or aliased ancestor');
    }
    const leaf = index === segments.length - 1;
    if (process.platform !== 'win32') {
      const currentUid = typeof process.getuid === 'function' ? process.getuid() : null;
      if (!leaf && currentUid !== null && stat.uid !== 0 && stat.uid !== currentUid) {
        fail('review workspace ancestor has an untrusted owner');
      }
      if (!leaf && (stat.mode & 0o022) !== 0) {
        const trustedStickyOwner = (stat.mode & 0o1000) !== 0
          && (currentUid === null || stat.uid === 0 || stat.uid === currentUid);
        if (!trustedStickyOwner) {
          fail('review workspace ancestor is writable without a trusted sticky-bit owner');
        }
      }
      if (leaf) {
        if (typeof process.getuid !== 'function' || stat.uid !== process.getuid()
            || (stat.mode & 0o777) !== 0o700) {
          fail('review workspace root must be owned by the current user with mode 0700');
        }
        if (!sameIdentity(identity(initialStat), stat)) {
          fail('review workspace root changed during security validation');
        }
      }
    }
  }
}

function readFileSnapshot(input, label, maxBytes = MAX_EVIDENCE_FILE_BYTES) {
  const initial = canonicalExisting(input, label, 'file');
  const noFollow = process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW)
    ? fs.constants.O_NOFOLLOW : 0;
  let descriptor;
  try {
    descriptor = fs.openSync(initial.canonical, fs.constants.O_RDONLY | noFollow);
    const before = fs.fstatSync(descriptor);
    if (!before.isFile() || before.nlink !== 1) fail(`${label} changed to an unsafe file`);
    if (before.size > maxBytes) fail(`${label} exceeds the size limit`);
    const data = fs.readFileSync(descriptor);
    const after = fs.fstatSync(descriptor);
    const pathAfter = fs.lstatSync(initial.canonical);
    if (
      !sameIdentity(identity(before), after)
      || before.mtimeMs !== after.mtimeMs
      || before.ctimeMs !== after.ctimeMs
      || !sameIdentity(identity(after), pathAfter)
    ) fail(`${label} changed while it was read`);
    return {
      path: initial.canonical,
      sha256: sha256(data),
      ...identity(after),
      data,
    };
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
}

function isInside(base, candidate) {
  const relative = path.relative(base, candidate);
  return relative === ''
    || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function protectedEvidenceRoots(binding) {
  return [
    binding.pluginData,
    path.join(binding.projectRoot, '.zensu'),
    binding.pluginRoot,
  ].map((entry) => path.resolve(entry));
}

function sensitivePathReason(candidate, data) {
  const normalized = candidate.replaceAll('\\', '/');
  const segments = normalized.split('/').filter(Boolean);
  const lowerSegments = segments.map((entry) => entry.toLowerCase());
  const basename = (lowerSegments.at(-1) || '');
  if (lowerSegments.some((entry) => ['.git', '.zensu', '.ssh', '.aws'].includes(entry))) {
    return 'control or home credential directory';
  }
  if (basename === '.env' || basename.startsWith('.env.')) return 'environment secret file';
  if (/^(?:id_rsa|id_dsa|id_ecdsa|id_ed25519)(?:\.pub)?$/.test(basename)
      || /\.(?:pem|key|p12|pfx|jks|keystore)$/.test(basename)) return 'private key material';
  if (/^(?:credentials|secrets?|tokens?|auth)(?:\.(?:json|ya?ml|toml|ini|txt))?$/.test(basename)
      || ['.netrc', '.npmrc', '.pypirc'].includes(basename)) return 'credential file name';
  const configIndex = lowerSegments.lastIndexOf('.config');
  if (configIndex >= 0 && lowerSegments.slice(configIndex + 1).some((entry) => (
    ['gh', 'glab-cli', 'gcloud', 'op', '1password', 'auth', 'credentials'].includes(entry)
  ))) return 'home config authentication path';
  if (lowerSegments.some((entry, index) => (
    (entry === '.kube' && lowerSegments[index + 1] === 'config')
    || entry === '.azure'
  ))) return 'home authentication path';
  const home = path.resolve(os.homedir());
  const configRoot = path.join(home, '.config');
  if (isInside(configRoot, candidate) && /(?:auth|credential|secret|token|hosts\.yml)/i.test(normalized)) {
    return 'home config authentication path';
  }
  if (data) {
    const content = data.toString('utf8');
    if (/-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----/.test(content)) return 'private key content';
  }
  return null;
}

function assertExactFileAllowed(binding, workspaceRoot, candidate, data) {
  const pluginRoot = path.resolve(binding.pluginRoot);
  const pluginData = path.resolve(binding.pluginData);
  const pluginSkills = path.join(pluginRoot, 'skills');
  const workflowState = path.join(path.resolve(binding.projectRoot), '.zensu');
  if (isInside(pluginData, candidate) || isInside(workflowState, candidate)) {
    fail(`evidence file enters protected runtime/state: ${diagnosticPath(candidate)}`);
  }
  if (isInside(pluginRoot, candidate) && !isInside(pluginSkills, candidate)) {
    fail(`evidence file enters non-skill plugin runtime: ${diagnosticPath(candidate)}`);
  }
  const exactScopeAllowed = isInside(binding.projectRoot, candidate)
    || isInside(workspaceRoot, candidate)
    || isInside(pluginSkills, candidate);
  if (!exactScopeAllowed) {
    fail(`evidence file is outside the project/review workspace: ${diagnosticPath(candidate)}`);
  }
  const sensitive = sensitivePathReason(candidate, data);
  if (sensitive) fail(`evidence file is sensitive (${sensitive}): ${diagnosticPath(candidate)}`);
}

function assertSafeRootAllowed(binding, workspaceRoot, candidate) {
  const projectRoot = path.resolve(binding.projectRoot);
  for (const protectedRoot of protectedEvidenceRoots(binding)) {
    if (isInside(protectedRoot, candidate) || isInside(candidate, protectedRoot)) {
      fail(`safe subtree reaches protected runtime/state: ${diagnosticPath(candidate)}`);
    }
  }
  // Searching the project root (or an ancestor) can reach .zensu even if a
  // pattern looks narrow. A safe root must be a proper descendant or external.
  if (candidate === projectRoot || isInside(candidate, projectRoot)) {
    fail(`safe subtree must not be the project root or its ancestor: ${diagnosticPath(candidate)}`);
  }
  const inProject = isInside(projectRoot, candidate) && candidate !== projectRoot;
  const inWorkspace = isInside(workspaceRoot, candidate) && candidate !== workspaceRoot;
  if (!inProject && !inWorkspace) {
    fail(`safe subtree is outside the project/review workspace: ${diagnosticPath(candidate)}`);
  }
  const segments = candidate.split(path.sep);
  if (segments.includes('.git') || segments.includes('.zensu')) {
    fail(`safe subtree must not enter a control directory: ${diagnosticPath(candidate)}`);
  }
}

function directoryTreeSnapshot(input, label) {
  const root = canonicalExisting(input, label, 'directory');
  const digest = crypto.createHash('sha256');
  let entries = 0;
  let totalSize = 0;

  function update(parts) {
    for (const part of parts) {
      digest.update(String(part), 'utf8');
      digest.update(Buffer.from([0]));
    }
  }

  function walk(directory, relative) {
    const directoryStat = fs.lstatSync(directory);
    if (directoryStat.isSymbolicLink() || !directoryStat.isDirectory()) {
      fail(`${label} contains an unsafe directory`);
    }
    update(['D', relative, directoryStat.size, directoryStat.dev,
      directoryStat.ino, directoryStat.nlink, directoryStat.mode,
      directoryStat.mtimeMs, directoryStat.ctimeMs]);
    const names = fs.readdirSync(directory).sort((left, right) => left.localeCompare(right));
    for (const name of names) {
      if (UNSAFE_PATH_TEXT_RE.test(name)) fail(`${label} contains an unsafe entry name`);
      const child = path.join(directory, name);
      const childRelative = relative ? path.join(relative, name) : name;
      const stat = fs.lstatSync(child);
      if (stat.isSymbolicLink()) {
        fail(`${label} contains a symbolic link: ${diagnosticPath(childRelative)}`);
      }
      const sensitive = sensitivePathReason(child);
      if (sensitive) {
        fail(`${label} contains a sensitive path (${sensitive}): ${diagnosticPath(childRelative)}`);
      }
      entries += 1;
      if (entries > MAX_EVIDENCE_FILES) fail(`${label} contains too many entries`);
      if (stat.isDirectory()) {
        walk(child, childRelative);
      } else if (stat.isFile()) {
        if (stat.nlink !== 1) {
          fail(`${label} contains a multiply linked file: ${diagnosticPath(childRelative)}`);
        }
        const snapshot = readFileSnapshot(child, `${label} entry`, MAX_EVIDENCE_FILE_BYTES);
        const sensitiveContent = sensitivePathReason(child, snapshot.data);
        if (sensitiveContent) {
          fail(`${label} contains sensitive content (${sensitiveContent}): ${diagnosticPath(childRelative)}`);
        }
        totalSize += snapshot.size;
        if (totalSize > MAX_EVIDENCE_TOTAL_BYTES) fail(`${label} exceeds the total size limit`);
        update(['F', childRelative, snapshot.sha256, snapshot.size,
          snapshot.dev, snapshot.ino, snapshot.nlink, snapshot.mode,
          snapshot.mtime_ms, snapshot.ctime_ms]);
      } else {
        fail(`${label} contains a non-regular entry: ${diagnosticPath(childRelative)}`);
      }
    }
  }

  walk(root.canonical, '');
  const rootAfter = fs.lstatSync(root.canonical);
  if (!sameIdentity(identity(root.stat), rootAfter)) fail(`${label} changed while it was hashed`);
  return {
    path: root.canonical,
    sha256: `sha256:${digest.digest('hex')}`,
    ...identity(rootAfter),
    entries,
    total_size: totalSize,
  };
}

function sameSnapshot(expected, actual, directory = false) {
  return expected.path === actual.path
    && expected.sha256 === actual.sha256
    && expected.size === actual.size
    && expected.dev === actual.dev
    && expected.ino === actual.ino
    && expected.nlink === actual.nlink
    && expected.mode === actual.mode
    && expected.mtime_ms === actual.mtime_ms
    && expected.ctime_ms === actual.ctime_ms
    && (!directory || (
      expected.entries === actual.entries
      && expected.total_size === actual.total_size
    ));
}

function ensurePrivateDirectory(base, segments) {
  let current = canonicalExisting(base, 'CLAUDE_PLUGIN_DATA', 'directory').canonical;
  for (const segment of segments) {
    current = path.join(current, segment);
    try {
      fs.mkdirSync(current, { mode: 0o700 });
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
    }
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink() || !stat.isDirectory()) fail('private lease path is unsafe');
    if (process.platform !== 'win32') {
      fs.chmodSync(current, 0o700);
      const checked = fs.lstatSync(current);
      if ((checked.mode & 0o077) !== 0) fail('private lease path permissions are unsafe');
      if (typeof process.getuid === 'function' && checked.uid !== process.getuid()) {
        fail('private lease path ownership is unsafe');
      }
    }
    if (fs.realpathSync.native(current) !== current) fail('private lease path is aliased');
  }
  return current;
}

function storage(binding) {
  const root = ensurePrivateDirectory(binding.pluginData, REVIEW_EVIDENCE_SEGMENTS);
  const records = ensurePrivateDirectory(root, ['records', binding.sessionKey]);
  const locks = ensurePrivateDirectory(root, ['locks']);
  return { root, records, locks };
}

// Does this store entry belong to the executing installation? The superseded-lease
// sweep needs the same answer listRecords reaches, and used to hand-copy the three
// conjuncts. It is a SUBSET of validateRecord on purpose: a caller that keeps an
// entry this returns true for keeps one listRecords may still reject (a multiply
// linked file, a non-canonical spelling, a schema this release no longer reads),
// so a keeper must state that residual rather than claim parity.
//
// `record` is whatever the caller managed to parse — null for an entry it could
// not read at all, which is never owned.
function leaseRecordIsOwned(name, record, executingPluginRoot) {
  const leaseId = typeof name === 'string' && name.endsWith('.json') ? name.slice(0, -5) : '';
  return LEASE_ID_RE.test(leaseId)
    && !!record
    && typeof record === 'object'
    && record.lease_id === leaseId
    && record.plugin_root === executingPluginRoot;
}

function sleep(milliseconds) {
  const signal = new Int32Array(new SharedArrayBuffer(4));
  Atomics.wait(signal, 0, 0, milliseconds);
}

function withLock(binding, callback) {
  const locations = storage(binding);
  const lockFile = path.join(locations.locks, `${binding.sessionKey}.lock`);
  let descriptor;
  const lockValue = `${process.pid}:${crypto.randomBytes(12).toString('hex')}\n`;
  for (let attempt = 0; attempt < LOCK_WAIT_ATTEMPTS; attempt += 1) {
    try {
      descriptor = fs.openSync(lockFile, 'wx', 0o600);
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      try {
        const stat = fs.lstatSync(lockFile);
        if (stat.isSymbolicLink() || !stat.isFile() || stat.nlink !== 1) {
          fail('private lease lock is unsafe');
        }
      } catch (statError) {
        if (statError.code !== 'ENOENT') throw statError;
      }
      // A lock can outlive a crashed process. Never infer ownership from age
      // or PID and never reclaim it here: either can race with a new owner and
      // unlink that owner's live lock. A fresh Claude Code session has a new
      // session key (and therefore a new lock path), which is the safe recovery.
      sleep(LOCK_WAIT_MS);
      continue;
    }
    // Separated from the open. Both used to sit in the same try, and the catch
    // rethrows anything that is not EEXIST — so an ENOSPC or EIO from the write left
    // through that throw with the descriptor OPEN and the lock file on disk, before
    // the release `finally` below was ever entered. Every later lock for this key
    // then spun the full budget and failed as "busy or abandoned", and reclaiming is
    // deliberately forbidden. The file was created 'wx' one statement ago, so this
    // process is unambiguously its only owner and may unlink it unconditionally —
    // the content check the release uses would not match a partial write.
    try {
      fs.writeFileSync(descriptor, lockValue);
      fs.fsyncSync(descriptor);
    } catch (error) {
      try { fs.closeSync(descriptor); } catch { /* best effort */ }
      try { fs.unlinkSync(lockFile); } catch { /* best effort */ }
      descriptor = undefined;
      throw error;
    }
    break;
  }
  if (descriptor === undefined) {
    fail('private lease lock is busy or abandoned; close this Claude Code session and start a fresh session');
  }
  try {
    return callback(locations);
  } finally {
    try { fs.closeSync(descriptor); } catch { /* best effort */ }
    try {
      if (fs.readFileSync(lockFile, 'utf8') === lockValue) fs.unlinkSync(lockFile);
    } catch { /* best effort; never unlink another owner's lock */ }
  }
}

function stripRecordHash(record) {
  const copy = { ...record };
  delete copy.record_hash;
  return copy;
}

function sealRecord(record) {
  const copy = stripRecordHash(record);
  return { ...copy, record_hash: hashObject(copy) };
}

function validateResultValue(value, depth = 0, budget = { nodes: 0 }) {
  budget.nodes += 1;
  if (budget.nodes > 20000 || depth > 20) fail('worker result is too complex');
  if (value === null || typeof value === 'boolean') return;
  if (typeof value === 'string') {
    if (value.length > 32768
        || /[\u0000-\u0008\u000b-\u001f\u007f\u202a-\u202e\u2066-\u2069]/i.test(value)) {
      fail('worker result contains an unsafe string');
    }
    return;
  }
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) fail('worker result contains a non-finite number');
    return;
  }
  if (Array.isArray(value)) {
    if (value.length > 2000) fail('worker result array is too large');
    for (const entry of value) validateResultValue(entry, depth + 1, budget);
    return;
  }
  if (!value || typeof value !== 'object') fail('worker result contains an unsupported value');
  const keys = Object.keys(value);
  if (keys.length > 200) fail('worker result object is too large');
  for (const key of keys) {
    if (key === '__proto__' || key === 'prototype' || key === 'constructor') {
      fail('worker result contains an unsafe key');
    }
    if (key.length > 128
        || /[\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069]/i.test(key)) {
      fail('worker result contains an unsafe key');
    }
    validateResultValue(value[key], depth + 1, budget);
  }
}

function exactKeys(value, required, optional, label) {
  const keys = Object.keys(value).sort();
  const allowed = new Set([...required, ...optional]);
  for (const key of required) {
    if (!Object.prototype.hasOwnProperty.call(value, key)) fail(`${label} is missing "${key}"`);
  }
  for (const key of keys) {
    if (!allowed.has(key)) fail(`${label} contains unknown key "${key}"`);
  }
}

function boundedString(value, label, maximum = 8192, allowEmpty = false) {
  if (typeof value !== 'string' || value.length > maximum
      || /[\u0000-\u0008\u000b-\u001f\u007f\u202a-\u202e\u2066-\u2069]/i.test(value)
      || (!allowEmpty && value.trim() === '')) fail(`${label} must be a bounded string`);
}

function boundedStringArray(value, label, maximumItems, maximumLength = 8192) {
  if (!Array.isArray(value) || value.length > maximumItems) fail(`${label} must be a bounded array`);
  for (const entry of value) boundedString(entry, `${label} entry`, maximumLength);
}

function repositoryRelativePath(value, label) {
  boundedString(value, label, 4096);
  const normalized = value.replaceAll('\\', '/');
  if (UNSAFE_PATH_TEXT_RE.test(value) || value.includes('\\')
      || path.isAbsolute(value) || normalized.startsWith('/')
      || /(?:^|\/)\.\.(?:\/|$)/.test(normalized)
      || /(?:^|\/)\.(?:git|zensu)(?:\/|$)/.test(normalized)) {
    fail(`${label} must be a safe repository-relative path`);
  }
}

function validatePlanResult(result) {
  exactKeys(result,
    ['kind', 'role', 'verdict', 'confidence', 'summary', 'blockers',
      'improvements', 'questions', 'strengths'], [], 'plan-review result');
  if (!['go', 'go-with-changes', 'revise', 'no-go'].includes(result.verdict)) {
    fail('plan-review verdict is invalid');
  }
  if (!['high', 'medium', 'low'].includes(result.confidence)) fail('plan-review confidence is invalid');
  boundedString(result.summary, 'plan-review summary', 8000);
  if (!Array.isArray(result.blockers) || result.blockers.length > 6) {
    fail('plan-review blockers must be an array with at most 6 entries');
  }
  for (const blocker of result.blockers) {
    if (!blocker || typeof blocker !== 'object' || Array.isArray(blocker)) fail('plan-review blocker is invalid');
    exactKeys(blocker, ['issue', 'why', 'plan_ref', 'plan_amendment'], ['evidence'],
      'plan-review blocker');
    boundedString(blocker.issue, 'plan-review blocker issue', 8000);
    boundedString(blocker.why, 'plan-review blocker why', 8000);
    boundedString(blocker.plan_ref, 'plan-review blocker plan_ref', 2048);
    boundedString(blocker.plan_amendment, 'plan-review blocker plan_amendment', 8000);
    if (blocker.evidence !== undefined) boundedString(blocker.evidence, 'plan-review blocker evidence', 8000);
  }
  if (!Array.isArray(result.improvements) || result.improvements.length > 12) {
    fail('plan-review improvements must be an array with at most 12 entries');
  }
  for (const improvement of result.improvements) {
    if (!improvement || typeof improvement !== 'object' || Array.isArray(improvement)) {
      fail('plan-review improvement is invalid');
    }
    exactKeys(improvement, ['issue', 'suggestion', 'plan_ref'], [], 'plan-review improvement');
    boundedString(improvement.issue, 'plan-review improvement issue', 8000);
    boundedString(improvement.suggestion, 'plan-review improvement suggestion', 8000);
    boundedString(improvement.plan_ref, 'plan-review improvement plan_ref', 2048);
  }
  boundedStringArray(result.questions, 'plan-review questions', 16, 8000);
  boundedStringArray(result.strengths, 'plan-review strengths', 16, 8000);
}

function validateCoverageReport(report) {
  if (!report || typeof report !== 'object' || Array.isArray(report)) fail('coverage_report is invalid');
  exactKeys(report,
    ['coverage_source', 'summary', 'changed_production_files', 'uncovered_files',
      'partial_files', 'covered_files', 'notes'], [], 'coverage_report');
  boundedString(report.coverage_source, 'coverage_report coverage_source', 4096);
  if (!/^(?:static(?: \([^\0\r\n]{1,1000}\))?|tool-run|report:[^\0\r\n]{1,4000})$/.test(
    report.coverage_source,
  )) fail('coverage_report coverage_source is invalid');
  boundedString(report.summary, 'coverage_report summary', 8000);
  if (!Number.isInteger(report.changed_production_files)
      || report.changed_production_files < 0 || report.changed_production_files > 100000) {
    fail('coverage_report changed_production_files is invalid');
  }
  if (!Array.isArray(report.uncovered_files) || report.uncovered_files.length > 5000) {
    fail('coverage_report uncovered_files is invalid');
  }
  for (const entry of report.uncovered_files) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) fail('uncovered file entry is invalid');
    exactKeys(entry, ['path', 'reason', 'risk'], [], 'uncovered file entry');
    repositoryRelativePath(entry.path, 'uncovered file path');
    boundedString(entry.reason, 'uncovered file reason', 8000);
    if (!['P1', 'P2', 'P3'].includes(entry.risk)) fail('uncovered file risk is invalid');
  }
  if (!Array.isArray(report.partial_files) || report.partial_files.length > 5000) {
    fail('coverage_report partial_files is invalid');
  }
  for (const entry of report.partial_files) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) fail('partial file entry is invalid');
    exactKeys(entry, ['path', 'uncovered_paths', 'covered_by'], [], 'partial file entry');
    repositoryRelativePath(entry.path, 'partial file path');
    boundedStringArray(entry.uncovered_paths, 'partial file uncovered_paths', 200, 4096);
    if (!Array.isArray(entry.covered_by) || entry.covered_by.length > 200) {
      fail('partial file covered_by is invalid');
    }
    for (const coveredBy of entry.covered_by) repositoryRelativePath(coveredBy, 'partial file covered_by path');
  }
  if (!Array.isArray(report.covered_files) || report.covered_files.length > 5000) {
    fail('coverage_report covered_files is invalid');
  }
  for (const covered of report.covered_files) repositoryRelativePath(covered, 'covered file path');
  boundedStringArray(report.notes, 'coverage_report notes', 200, 8000);
  const classified = [
    ...report.uncovered_files.map((entry) => entry.path),
    ...report.partial_files.map((entry) => entry.path),
    ...report.covered_files,
  ].map((entry) => entry.replaceAll('\\', '/'));
  if (new Set(classified).size !== classified.length) fail('coverage_report classifies a file more than once');
  if (classified.length !== report.changed_production_files) {
    fail('coverage_report changed_production_files does not match its inventory');
  }
}

function validatePrResult(result) {
  const optional = result.role === 'coverage-audit' ? ['coverage_report'] : [];
  exactKeys(result,
    ['kind', 'role', 'verdict_hint', 'summary', 'inline_findings', 'overall_notes', 'positives'],
    optional, 'pr-review result');
  if (!['approve', 'approve-with-comments', 'minor-changes', 'major-changes',
    'request-changes'].includes(result.verdict_hint)) fail('pr-review verdict_hint is invalid');
  boundedString(result.summary, 'pr-review summary', 8000);
  if (!Array.isArray(result.inline_findings) || result.inline_findings.length > 8) {
    fail('pr-review inline_findings must be an array with at most 8 entries');
  }
  for (const finding of result.inline_findings) {
    if (!finding || typeof finding !== 'object' || Array.isArray(finding)) fail('inline finding is invalid');
    exactKeys(finding, ['path', 'line', 'side', 'severity', 'category', 'body'], [], 'inline finding');
    repositoryRelativePath(finding.path, 'inline finding path');
    if (!Number.isInteger(finding.line) || finding.line < 1 || finding.line > 100000000) {
      fail('inline finding line is invalid');
    }
    if (!['RIGHT', 'LEFT'].includes(finding.side)) fail('inline finding side is invalid');
    if (!['P1', 'P2', 'P3'].includes(finding.severity)) fail('inline finding severity is invalid');
    boundedString(finding.category, 'inline finding category', 128);
    boundedString(finding.body, 'inline finding body', 12000);
  }
  boundedStringArray(result.overall_notes, 'pr-review overall_notes', 32, 8000);
  boundedStringArray(result.positives, 'pr-review positives', 32, 8000);
  if (result.role === 'coverage-audit') {
    if (result.coverage_report === undefined) fail('coverage-audit result requires coverage_report');
    validateCoverageReport(result.coverage_report);
  } else if (result.coverage_report !== undefined) {
    fail('only coverage-audit may return coverage_report');
  }
}

function validateWorkerSchema(result, kind, allowedPrPaths, changedProductionPaths) {
  if (result.kind !== kind) fail(`worker result kind must be exactly "${kind}"`);
  if (!ROLE_RE.test(result.role || '')) {
    fail('worker result role must match [a-z0-9][a-z0-9-]{0,63}');
  }
  if (kind === 'plan-review') validatePlanResult(result);
  else if (kind === 'pr-review') {
    validatePrResult(result);
    if (allowedPrPaths) {
      const allowed = new Set(allowedPrPaths);
      for (const finding of result.inline_findings) {
        if (!allowed.has(finding.path.replaceAll('\\', '/'))) {
          fail(`inline finding path is outside the bound name-status set: ${diagnosticPath(finding.path)}`);
        }
      }
      if (result.coverage_report) {
        const coveragePaths = [
          ...result.coverage_report.uncovered_files.map((entry) => entry.path),
          ...result.coverage_report.partial_files.map((entry) => entry.path),
          ...result.coverage_report.covered_files,
        ];
        for (const coveragePath of coveragePaths) {
          if (!allowed.has(coveragePath.replaceAll('\\', '/'))) {
            fail(`coverage path is outside the bound name-status set: ${diagnosticPath(coveragePath)}`);
          }
        }
        const actual = new Set(coveragePaths.map((entry) => entry.replaceAll('\\', '/')));
        const expectedPaths = changedProductionPaths || [];
        const expected = new Set(expectedPaths);
        if (result.coverage_report.changed_production_files !== expectedPaths.length) {
          fail('coverage_report changed_production_files does not match changed-production-files');
        }
        if (actual.size !== expected.size || [...actual].some((entry) => !expected.has(entry))) {
          fail('coverage_report inventory does not exactly match changed-production-files');
        }
      }
    }
  }
  else fail('worker result kind is unsupported');
}

function normalizeWorkerResult(result, kind) {
  if (kind === 'plan-review') {
    return {
      kind: result.kind,
      role: result.role,
      verdict: result.verdict,
      confidence: result.confidence,
      summary: result.summary,
      blockers: result.blockers.map((entry) => ({
        issue: entry.issue,
        why: entry.why,
        plan_ref: entry.plan_ref,
        plan_amendment: entry.plan_amendment,
        ...(entry.evidence !== undefined ? { evidence: entry.evidence } : {}),
      })),
      improvements: result.improvements.map((entry) => ({
        issue: entry.issue,
        suggestion: entry.suggestion,
        plan_ref: entry.plan_ref,
      })),
      questions: [...result.questions],
      strengths: [...result.strengths],
    };
  }
  const normalized = {
    kind: result.kind,
    role: result.role,
    verdict_hint: result.verdict_hint,
    summary: result.summary,
    inline_findings: result.inline_findings.map((entry) => ({
      path: entry.path,
      line: entry.line,
      side: entry.side,
      severity: entry.severity,
      category: entry.category,
      body: entry.body,
    })),
    overall_notes: [...result.overall_notes],
    positives: [...result.positives],
  };
  if (result.role === 'coverage-audit') {
    normalized.coverage_report = {
      coverage_source: result.coverage_report.coverage_source,
      summary: result.coverage_report.summary,
      changed_production_files: result.coverage_report.changed_production_files,
      uncovered_files: result.coverage_report.uncovered_files.map((entry) => ({
        path: entry.path, reason: entry.reason, risk: entry.risk,
      })),
      partial_files: result.coverage_report.partial_files.map((entry) => ({
        path: entry.path,
        uncovered_paths: [...entry.uncovered_paths],
        covered_by: [...entry.covered_by],
      })),
      covered_files: [...result.coverage_report.covered_files],
      notes: [...result.coverage_report.notes],
    };
  }
  return normalized;
}

function computeSealProof(record) {
  return hashObject({
    schema: 'zensu.review-evidence-seal',
    schema_version: 1,
    lease_id: record.lease_id,
    kind: record.kind,
    generation: record.generation,
    session_key: record.session_key,
    runtime_digest: record.runtime_digest,
    max_workers: record.max_workers,
    exact_files: record.exact_files,
    safe_roots: record.safe_roots,
    allowed_pr_paths: record.allowed_pr_paths || null,
    changed_production_paths: record.changed_production_paths || null,
    sealed_at_ms: record.sealed_at_ms,
    seal_revision: record.seal_revision,
    workers: Object.entries(record.workers).sort(([left], [right]) => left.localeCompare(right))
      .map(([agentId, worker]) => ({
        agent_id: agentId,
        agent_type: worker.agent_type,
        result_sha256: worker.result_sha256,
      })),
  });
}

function validateRecord(record, binding, options = {}) {
  if (!record || typeof record !== 'object' || Array.isArray(record)) fail('lease record is invalid');
  exactKeys(record, [
    'schema', 'schema_version', 'lease_id', 'kind', 'generation', 'status',
    'session_key', 'session_id_hash', 'project_root', 'workspace_root',
    'plugin_root', 'plugin_data', 'runtime_digest', 'created_at_ms',
    'expires_at_ms', 'max_workers', 'exact_files', 'safe_roots', 'workers',
    'revision', 'record_hash',
  ], ['allowed_pr_paths', 'changed_production_paths', 'sealed_at_ms', 'seal_revision',
    'seal_proof', 'closed_at_ms', 'close_reason'], 'lease record');
  if (record.schema !== SCHEMA || record.schema_version !== SCHEMA_VERSION) fail('lease record schema is invalid');
  if (!LEASE_ID_RE.test(record.lease_id)) fail('lease id is invalid');
  requireKind(record.kind);
  if (!Number.isInteger(record.generation) || record.generation < 1) fail('lease generation is invalid');
  if (!['active', 'sealed', 'closed'].includes(record.status)) fail('lease status is invalid');
  if (record.session_key !== binding.sessionKey) fail('lease session binding does not match');
  if (record.session_id_hash !== binding.context.session_id_hash) fail('lease session hash does not match');
  if (record.project_root !== binding.projectRoot) fail('lease project binding does not match');
  requireSafeText(record.workspace_root, 'lease workspace root');
  if (!path.isAbsolute(record.workspace_root) || path.resolve(record.workspace_root) !== record.workspace_root) {
    fail('lease workspace root path is invalid');
  }
  if (record.status === 'active' && record.expires_at_ms > Date.now()
      && !options.skipActiveWorkspaceValidation) {
    const workspace = canonicalExisting(record.workspace_root,
      'active lease workspace root', 'directory');
    if (workspace.canonical !== record.workspace_root) fail('active lease workspace root is not canonical');
    assertSecureWorkspaceRoot(workspace.canonical, workspace.stat);
  }
  if (record.plugin_root !== binding.pluginRoot) fail('lease plugin root does not match');
  if (record.plugin_data !== binding.pluginData) fail('lease plugin data does not match');
  if (record.runtime_digest !== binding.context.runtime_digest || !HASH_RE.test(record.runtime_digest)) {
    fail('lease runtime digest does not match');
  }
  if (!Number.isInteger(record.created_at_ms) || !Number.isInteger(record.expires_at_ms)
      || record.expires_at_ms <= record.created_at_ms) fail('lease expiry is invalid');
  if (!Number.isInteger(record.max_workers) || record.max_workers < 1 || record.max_workers > 32) {
    fail('lease max_workers is invalid');
  }
  if (!Number.isInteger(record.revision) || record.revision < 1) fail('lease revision is invalid');
  if (record.status === 'closed') {
    if (!Number.isInteger(record.closed_at_ms) || record.closed_at_ms < record.created_at_ms
        || !['main-close', 'expired'].includes(record.close_reason)) {
      fail('closed lease metadata is invalid');
    }
  } else if (record.closed_at_ms !== undefined || record.close_reason !== undefined) {
    fail('open lease contains closed metadata');
  }
  const sealFields = [record.sealed_at_ms, record.seal_revision, record.seal_proof];
  const hasSeal = sealFields.every((entry) => entry !== undefined);
  if (sealFields.some((entry) => entry !== undefined) && !hasSeal) {
    fail('lease seal metadata is incomplete');
  }
  if (record.status === 'sealed' && !hasSeal) fail('sealed lease is missing its proof');
  if (record.status === 'active' && hasSeal) fail('active lease contains seal metadata');
  if (hasSeal) {
    if (!Number.isInteger(record.sealed_at_ms) || record.sealed_at_ms < record.created_at_ms
        || !Number.isInteger(record.seal_revision) || record.seal_revision < 2
        || record.seal_revision > record.revision || !HASH_RE.test(record.seal_proof)) {
      fail('lease seal metadata is invalid');
    }
    if (record.status === 'sealed' && record.seal_revision !== record.revision) {
      fail('sealed lease revision does not match its seal');
    }
    if (record.status === 'closed' && record.seal_revision >= record.revision) {
      fail('closed sealed lease revision is invalid');
    }
  }
  if (!Array.isArray(record.exact_files) || record.exact_files.length > MAX_EVIDENCE_FILES) {
    fail('lease exact-file set is invalid');
  }
  if (!Array.isArray(record.safe_roots) || record.safe_roots.length > 256) {
    fail('lease safe-root set is invalid');
  }
  if (record.kind === 'pr-review') {
    if (!Array.isArray(record.allowed_pr_paths) || record.allowed_pr_paths.length > 100000) {
      fail('lease allowed_pr_paths is invalid');
    }
    for (const candidate of record.allowed_pr_paths) repositoryRelativePath(candidate, 'allowed PR path');
    if (new Set(record.allowed_pr_paths).size !== record.allowed_pr_paths.length) {
      fail('lease allowed_pr_paths contains duplicates');
    }
    if (!Array.isArray(record.changed_production_paths)
        || record.changed_production_paths.length > MAX_EVIDENCE_FILES) {
      fail('lease changed_production_paths is invalid');
    }
    const allowed = new Set(record.allowed_pr_paths);
    for (const candidate of record.changed_production_paths) {
      repositoryRelativePath(candidate, 'changed production path');
      if (!allowed.has(candidate)) fail('lease changed production path is outside allowed PR paths');
    }
    if (new Set(record.changed_production_paths).size !== record.changed_production_paths.length) {
      fail('lease changed_production_paths contains duplicates');
    }
  } else if (record.allowed_pr_paths !== undefined || record.changed_production_paths !== undefined) {
    fail('plan-review lease must not contain PR path inventories');
  }
  for (const entry of record.exact_files) {
    exactKeys(entry,
      ['path', 'sha256', 'size', 'dev', 'ino', 'nlink', 'mode', 'mtime_ms', 'ctime_ms'],
      [], 'lease exact-file snapshot');
  }
  for (const entry of record.safe_roots) {
    exactKeys(entry,
      ['path', 'sha256', 'size', 'dev', 'ino', 'nlink', 'mode', 'mtime_ms', 'ctime_ms',
        'entries', 'total_size'], [], 'lease safe-root snapshot');
    if (!Number.isInteger(entry.entries) || entry.entries < 0
        || !Number.isInteger(entry.total_size) || entry.total_size < 0) {
      fail('lease safe-root counters are invalid');
    }
  }
  for (const entry of [...record.exact_files, ...record.safe_roots]) {
    if (!entry || typeof entry !== 'object' || !path.isAbsolute(entry.path)
        || !HASH_RE.test(entry.sha256) || !Number.isInteger(entry.size)
        || typeof entry.dev !== 'string' || typeof entry.ino !== 'string'
        || !Number.isInteger(entry.nlink) || !Number.isInteger(entry.mode)
        || typeof entry.mtime_ms !== 'number' || typeof entry.ctime_ms !== 'number') {
      fail('lease evidence snapshot is invalid');
    }
  }
  if (!record.workers || typeof record.workers !== 'object' || Array.isArray(record.workers)) {
    fail('lease worker bindings are invalid');
  }
  const workers = Object.entries(record.workers);
  if (workers.length > record.max_workers) fail('lease exceeds max_workers');
  for (const [agentId, worker] of workers) {
    requireSafeText(agentId, 'bound agent id', 512);
    if (!worker || typeof worker !== 'object' || Array.isArray(worker)) fail('worker binding is invalid');
    exactKeys(worker, ['agent_type', 'status', 'bound_at_ms', 'result_attempts'],
      ['result_error', 'finished_at_ms', 'result', 'result_sha256'], 'worker binding');
    if (kindForAgentType(worker.agent_type) !== record.kind) fail('worker type does not match lease kind');
    if (!['bound', 'retry', 'completed', 'failed', 'revoked'].includes(worker.status)) {
      fail('worker status is invalid');
    }
    if (!Number.isInteger(worker.result_attempts) || worker.result_attempts < 0 || worker.result_attempts > 2) {
      fail('worker result-attempt count is invalid');
    }
    if (!Number.isInteger(worker.bound_at_ms) || worker.bound_at_ms < record.created_at_ms) {
      fail('worker bound timestamp is invalid');
    }
    if (worker.finished_at_ms !== undefined
        && (!Number.isInteger(worker.finished_at_ms) || worker.finished_at_ms < worker.bound_at_ms)) {
      fail('worker finished timestamp is invalid');
    }
    if (worker.result_error !== undefined) boundedString(worker.result_error, 'worker result error', 1024);
    if (worker.result !== undefined) {
      validateResultValue(worker.result);
      if (!HASH_RE.test(worker.result_sha256 || '')) fail('worker result hash is invalid');
      if (hashObject(worker.result) !== worker.result_sha256) fail('worker result hash does not match');
      validateWorkerSchema(worker.result, record.kind, record.allowed_pr_paths,
        record.changed_production_paths);
    } else if (worker.result_sha256 !== undefined) {
      fail('worker result hash exists without a result');
    }
    if (worker.status === 'completed'
        && (worker.result === undefined || worker.finished_at_ms === undefined
          || worker.result_attempts < 1)) {
      fail('completed worker binding is missing its create-once result');
    }
    if (worker.status === 'failed'
        && (worker.result_attempts !== 2 || worker.result_error === undefined
          || worker.finished_at_ms === undefined)) {
      fail('failed worker binding metadata is invalid');
    }
    if (worker.status === 'retry'
        && (worker.result_attempts !== 1 || worker.result_error === undefined)) {
      fail('retry worker binding metadata is invalid');
    }
    if (worker.status === 'bound' && worker.result_attempts !== 0) {
      fail('bound worker binding metadata is invalid');
    }
  }
  if (hasSeal) {
    if (workers.length !== record.max_workers
        || workers.some(([, worker]) => worker.status !== 'completed')) {
      fail('sealed lease does not contain exactly max_workers completed results');
    }
    if (computeSealProof(record) !== record.seal_proof) fail('lease seal proof does not match');
  }
  if (!HASH_RE.test(record.record_hash || '') || hashObject(stripRecordHash(record)) !== record.record_hash) {
    fail('lease record integrity check failed');
  }
  return record;
}

function atomicWriteRecord(recordsDirectory, record) {
  const sealed = sealRecord(record);
  const target = path.join(recordsDirectory, `${sealed.lease_id}.json`);
  const data = Buffer.from(`${JSON.stringify(sealed)}\n`, 'utf8');
  if (data.length > MAX_RECORD_BYTES) fail('lease record exceeds size limit');
  let existing;
  try { existing = fs.lstatSync(target); } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  if (existing && (existing.isSymbolicLink() || !existing.isFile() || existing.nlink !== 1)) {
    fail('existing lease record path is unsafe');
  }
  const temporary = path.join(recordsDirectory,
    `.${sealed.lease_id}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.tmp`);
  let descriptor;
  try {
    descriptor = fs.openSync(temporary, 'wx', 0o600);
    fs.writeFileSync(descriptor, data);
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    fs.renameSync(temporary, target);
    if (process.platform !== 'win32') fs.chmodSync(target, 0o600);
    if (process.platform !== 'win32') {
      const directoryDescriptor = fs.openSync(recordsDirectory, fs.constants.O_RDONLY);
      try { fs.fsyncSync(directoryDescriptor); } finally { fs.closeSync(directoryDescriptor); }
    }
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    try { fs.unlinkSync(temporary); } catch { /* already renamed */ }
  }
  return sealed;
}

function readRecord(file, binding, options = {}) {
  const snapshot = readFileSnapshot(file, 'lease record', MAX_RECORD_BYTES);
  let record;
  try { record = JSON.parse(snapshot.data.toString('utf8')); } catch { fail('lease record JSON is invalid'); }
  return validateRecord(record, binding, options);
}

function listRecords(locations, binding, options = {}) {
  const records = [];
  for (const name of fs.readdirSync(locations.records).sort()) {
    if (!name.endsWith('.json')) fail('private lease record directory contains an unexpected entry');
    const leaseId = name.slice(0, -5);
    if (!LEASE_ID_RE.test(leaseId)) fail('private lease record filename is invalid');
    const file = path.join(locations.records, name);
    const record = readRecord(file, binding, options);
    if (record.lease_id !== leaseId) fail('lease filename and record id do not match');
    records.push(record);
  }
  return records;
}

function activeRecord(records, kind, now = Date.now()) {
  const active = records.filter((record) => record.kind === kind
    && record.status === 'active' && record.expires_at_ms > now);
  if (active.length > 1) fail(`multiple active ${kind} leases exist`);
  return active[0] || null;
}

function manifestPaths(file, label) {
  const snapshot = readFileSnapshot(file, label, MAX_MANIFEST_BYTES);
  let text;
  try { text = new TextDecoder('utf-8', { fatal: true }).decode(snapshot.data); } catch {
    fail(`${label} is not valid UTF-8`);
  }
  if (/\r(?!\n)/.test(text)) fail(`${label} contains unsupported carriage returns`);
  const rawValues = text.replaceAll('\r\n', '\n').split('\n').filter((line) => line !== '');
  if (rawValues.length > MAX_EVIDENCE_FILES) fail(`${label} contains too many paths`);
  const values = [];
  for (const value of rawValues) {
    if (value.trim() !== value || UNSAFE_PATH_TEXT_RE.test(value)) {
      fail(`${label} contains a non-canonical path line`);
    }
    let normalizedValue;
    try {
      normalizedValue = hostPaths.normalizeHostPathInput(value, `${label} path`);
    } catch {
      fail(`${label} contains a non-canonical path line`);
    }
    if (!path.isAbsolute(normalizedValue)) fail(`${label} contains a non-canonical path line`);
    values.push(normalizedValue);
  }
  return { snapshot, values };
}

function nameStatusPaths(file) {
  const snapshot = readFileSnapshot(file, 'name-status file', MAX_MANIFEST_BYTES);
  let text;
  try { text = new TextDecoder('utf-8', { fatal: true }).decode(snapshot.data); } catch {
    fail('name-status file is not valid UTF-8');
  }
  if (text.includes('\0')) fail('name-status file must use tab-separated line format');
  const allowed = new Set();
  for (const line of text.replaceAll('\r\n', '\n').split('\n')) {
    if (line === '') continue;
    const fields = line.split('\t');
    const status = fields.shift();
    if (!/^(?:[ACDMRTUXB]|[RC][0-9]{1,3})$/.test(status || '')) {
      fail('name-status file contains an unsupported status');
    }
    const expectedPaths = /^[RC]/.test(status) ? 2 : 1;
    if (fields.length !== expectedPaths) fail('name-status file contains a malformed record');
    for (const raw of fields) {
      repositoryRelativePath(raw, 'name-status path');
      if (raw.includes('"') || raw.includes('\\')) {
        fail('name-status paths must be unquoted UTF-8 paths; generate with core.quotePath=false');
      }
      allowed.add(raw.replaceAll('\\', '/'));
    }
  }
  return { snapshot, paths: [...allowed].sort() };
}

function changedProductionPaths(file, allowedPrPaths) {
  const snapshot = readFileSnapshot(file, 'changed-production-files file', MAX_MANIFEST_BYTES);
  let text;
  try { text = new TextDecoder('utf-8', { fatal: true }).decode(snapshot.data); } catch {
    fail('changed-production-files file is not valid UTF-8');
  }
  if (/\r(?!\n)/.test(text)) {
    fail('changed-production-files file contains unsupported carriage returns');
  }
  const allowed = new Set(allowedPrPaths);
  const seen = new Set();
  for (const raw of text.replaceAll('\r\n', '\n').split('\n')) {
    if (raw === '') continue;
    repositoryRelativePath(raw, 'changed production path');
    if (raw.trim() !== raw || raw.includes('\\') || raw.includes('"')
        || raw.startsWith('./') || raw.endsWith('/') || path.posix.normalize(raw) !== raw) {
      fail('changed-production-files file contains a non-canonical path');
    }
    if (!allowed.has(raw)) {
      fail('changed-production-files path is outside the bound name-status set');
    }
    if (seen.has(raw)) fail('changed-production-files file contains duplicate paths');
    seen.add(raw);
  }
  if (seen.size > MAX_EVIDENCE_FILES) fail('changed-production-files file contains too many paths');
  return { snapshot, paths: [...seen].sort() };
}

function bindFromModelEnvironment(environment = process.env) {
  const sessionId = requireSafeText(environment.CLAUDE_CODE_SESSION_ID,
    'CLAUDE_CODE_SESSION_ID');
  return hookSession.resolveHookSession({ session_id: sessionId }, environment);
}

function createLease(binding, options) {
  const kind = requireKind(options.kind);
  const filesManifest = manifestPaths(options.filesManifest, 'files manifest');
  const rootsManifest = manifestPaths(options.safeSubtreesManifest, 'safe-subtrees manifest');
  const workspace = canonicalExisting(path.dirname(filesManifest.snapshot.path),
    'review workspace root', 'directory');
  const workspaceRoot = workspace.canonical;
  const filesystemRoot = path.parse(workspaceRoot).root;
  if (workspaceRoot === filesystemRoot) fail('review workspace root must not be the filesystem root');
  for (const protectedRoot of [binding.pluginRoot, binding.pluginData].map((entry) => path.resolve(entry))) {
    if (isInside(protectedRoot, workspaceRoot) || isInside(workspaceRoot, protectedRoot)) {
      fail('review workspace root must not overlap plugin runtime or private plugin data');
    }
  }
  assertSecureWorkspaceRoot(workspaceRoot, workspace.stat);
  if (workspaceRoot !== binding.projectRoot && isInside(workspaceRoot, binding.projectRoot)) {
    fail('review workspace root must not be an ancestor of the project root');
  }
  const nameStatus = kind === 'pr-review' ? nameStatusPaths(options.nameStatusFile) : null;
  const changedProduction = kind === 'pr-review'
    ? changedProductionPaths(options.changedProductionFilesFile, nameStatus.paths) : null;
  const requiredFiles = options.requiredFiles || [];
  const maxWorkers = Number(options.maxWorkers);
  const ttlSeconds = options.ttlSeconds === undefined ? 1800 : Number(options.ttlSeconds);
  if (!Number.isInteger(maxWorkers) || maxWorkers < 1 || maxWorkers > 32) {
    fail('--max-workers must be an integer from 1 through 32');
  }
  if (!Number.isInteger(ttlSeconds) || ttlSeconds < 60 || ttlSeconds > 3600) {
    fail('--ttl-seconds must be an integer from 60 through 3600');
  }

  const exactInputs = [
    options.filesManifest,
    options.safeSubtreesManifest,
    ...(options.nameStatusFile ? [options.nameStatusFile] : []),
    ...(options.changedProductionFilesFile ? [options.changedProductionFilesFile] : []),
    ...requiredFiles,
    ...filesManifest.values,
  ];
  const exactFiles = [];
  const seenFiles = new Set();
  const parsedInputSnapshots = new Map([
    [filesManifest.snapshot.path, filesManifest.snapshot],
    [rootsManifest.snapshot.path, rootsManifest.snapshot],
    ...(nameStatus ? [[nameStatus.snapshot.path, nameStatus.snapshot]] : []),
    ...(changedProduction ? [[changedProduction.snapshot.path, changedProduction.snapshot]] : []),
  ]);
  let totalSize = 0;
  for (const input of exactInputs) {
    const snapshot = readFileSnapshot(input, 'evidence file');
    const parsedSnapshot = parsedInputSnapshots.get(snapshot.path);
    if (parsedSnapshot && !sameSnapshot(parsedSnapshot, snapshot)) {
      fail(`parsed evidence manifest changed during lease creation: ${diagnosticPath(snapshot.path)}`);
    }
    assertExactFileAllowed(binding, workspaceRoot, snapshot.path, snapshot.data);
    if (seenFiles.has(snapshot.path)) continue;
    seenFiles.add(snapshot.path);
    totalSize += snapshot.size;
    if (totalSize > MAX_EVIDENCE_TOTAL_BYTES) fail('exact evidence exceeds the total size limit');
    delete snapshot.data;
    exactFiles.push(snapshot);
  }

  const safeRoots = [];
  const seenRoots = new Set();
  for (const input of rootsManifest.values) {
    const snapshot = directoryTreeSnapshot(input, 'safe subtree');
    assertSafeRootAllowed(binding, workspaceRoot, snapshot.path);
    if (seenRoots.has(snapshot.path)) continue;
    seenRoots.add(snapshot.path);
    safeRoots.push(snapshot);
  }

  return withLock(binding, (locations) => {
    const records = listRecords(locations, binding);
    const now = Date.now();
    let generation = 1;
    for (const record of records.filter((entry) => entry.kind === kind)) {
      generation = Math.max(generation, record.generation + 1);
      if (record.status === 'sealed') {
        fail(`a sealed ${kind} evidence lease must be closed before creating a new generation`);
      }
      if (record.status === 'active') {
        if (record.expires_at_ms > now) {
          fail(`an active ${kind} evidence lease already exists`);
        }
        record.status = 'closed';
        record.closed_at_ms = now;
        record.close_reason = 'expired';
        record.revision += 1;
        for (const worker of Object.values(record.workers)) {
          if (worker.status === 'bound' || worker.status === 'retry') worker.status = 'revoked';
        }
        atomicWriteRecord(locations.records, record);
      }
    }
    const leaseId = `rel1_${crypto.randomBytes(16).toString('hex')}`;
    const record = {
      schema: SCHEMA,
      schema_version: SCHEMA_VERSION,
      lease_id: leaseId,
      kind,
      generation,
      status: 'active',
      session_key: binding.sessionKey,
      session_id_hash: binding.context.session_id_hash,
      project_root: binding.projectRoot,
      workspace_root: workspaceRoot,
      plugin_root: binding.pluginRoot,
      plugin_data: binding.pluginData,
      runtime_digest: binding.context.runtime_digest,
      created_at_ms: now,
      expires_at_ms: now + ttlSeconds * 1000,
      max_workers: maxWorkers,
      exact_files: exactFiles,
      safe_roots: safeRoots,
      ...(nameStatus ? { allowed_pr_paths: nameStatus.paths } : {}),
      ...(changedProduction ? { changed_production_paths: changedProduction.paths } : {}),
      workers: {},
      revision: 1,
    };
    atomicWriteRecord(locations.records, record);
    return leaseId;
  });
}

function selectRecord(records, options, allowClosed = false) {
  let selected;
  if (options.leaseId) {
    if (!LEASE_ID_RE.test(options.leaseId)) fail('lease id is invalid');
    selected = records.find((record) => record.lease_id === options.leaseId);
  } else {
    const kind = requireKind(options.kind);
    const candidates = records.filter((record) => record.kind === kind
      && (allowClosed || record.status === 'active'))
      .sort((left, right) => right.generation - left.generation);
    selected = candidates[0];
  }
  if (!selected) fail('matching evidence lease was not found');
  return selected;
}

function selectRecordForClose(locations, binding, options) {
  const relaxed = { skipActiveWorkspaceValidation: true };
  if (options.leaseId) {
    if (!LEASE_ID_RE.test(options.leaseId)) fail('lease id is invalid');
    const file = path.join(locations.records, `${options.leaseId}.json`);
    let record;
    try { record = readRecord(file, binding, relaxed); } catch (error) {
      if (/ does not exist$/.test(error.message)) fail('matching evidence lease was not found');
      throw error;
    }
    if (record.lease_id !== options.leaseId) fail('lease filename and record id do not match');
    return record;
  }
  return selectRecord(listRecords(locations, binding, relaxed), options, true);
}

function closeLease(binding, options) {
  return withLock(binding, (locations) => {
    // Close is the recovery operation. It authenticates and integrity-checks
    // the private record but deliberately does not require the external live
    // workspace to remain present or secure. Every capability-bearing path
    // (bind/tool/stop/finalize/create) continues to use strict record reads.
    const record = selectRecordForClose(locations, binding, options);
    if (record.status !== 'closed') {
      record.status = 'closed';
      record.closed_at_ms = Date.now();
      record.close_reason = 'main-close';
      record.revision += 1;
      for (const worker of Object.values(record.workers)) {
        if (worker.status === 'bound' || worker.status === 'retry') worker.status = 'revoked';
      }
      atomicWriteRecord(locations.records, record);
    }
    return record.lease_id;
  });
}

function finalizeLease(binding, options) {
  return withLock(binding, (locations) => {
    const record = selectRecord(listRecords(locations, binding), options, true);
    if (record.status === 'sealed') return record.lease_id;
    if (record.status !== 'active') fail('only an active evidence lease can be finalized');
    if (record.expires_at_ms <= Date.now()) fail('expired evidence lease cannot be finalized');
    const workers = Object.values(record.workers);
    if (workers.length !== record.max_workers
        || workers.some((worker) => worker.status !== 'completed')) {
      fail('finalize requires exactly max_workers completed results');
    }
    for (const entry of record.exact_files) revalidateExactFile(entry);
    for (const entry of record.safe_roots) revalidateSafeRoot(entry);
    record.status = 'sealed';
    record.sealed_at_ms = Date.now();
    record.revision += 1;
    record.seal_revision = record.revision;
    record.seal_proof = computeSealProof(record);
    atomicWriteRecord(locations.records, record);
    return record.lease_id;
  });
}

function collectLease(binding, options) {
  return withLock(binding, (locations) => {
    const record = selectRecord(listRecords(locations, binding), options, true);
    if (record.status !== 'sealed'
        && !(record.status === 'closed' && record.seal_proof !== undefined)) {
      fail('evidence lease must be finalized before collect');
    }
    const agentId = requireSafeText(options.agentId, '--agent-id', 512);
    const expectedRole = requireSafeText(options.expectedRole, '--expected-role', 64);
    if (!ROLE_RE.test(expectedRole)) fail('--expected-role has an invalid role id');
    const worker = record.workers[agentId];
    if (!worker) fail('the requested agent_id is not bound to this lease');
    if (worker.status !== 'completed' || !worker.result) fail('the requested worker has no validated result');
    if (worker.result.kind !== record.kind) fail('stored result kind does not match its lease');
    if (worker.result.role !== expectedRole) fail('stored result role does not match --expected-role');
    if (hashObject(worker.result) !== worker.result_sha256) fail('stored result integrity check failed');
    return worker.result;
  });
}

function bindWorker(payload, binding) {
  const kind = kindForAgentType(payload.agent_type);
  if (!kind) return null;
  const agentId = requireSafeText(payload.agent_id, 'worker agent_id', 512);
  return withLock(binding, (locations) => {
    const records = listRecords(locations, binding);
    const record = activeRecord(records, kind);
    if (!record) fail(`no active ${kind} evidence lease is available`);
    const existing = record.workers[agentId];
    if (existing) {
      if (existing.agent_type !== payload.agent_type
          || !['bound', 'retry'].includes(existing.status)) {
        fail('worker agent_id is already bound incompatibly');
      }
      return record.lease_id;
    }
    if (Object.keys(record.workers).length >= record.max_workers) fail('evidence lease max_workers is exhausted');
    record.workers[agentId] = {
      agent_type: payload.agent_type,
      status: 'bound',
      bound_at_ms: Date.now(),
      result_attempts: 0,
    };
    record.revision += 1;
    atomicWriteRecord(locations.records, record);
    return record.lease_id;
  });
}

function hasDuplicateJsonObjectKeys(raw) {
  const duplicate = Symbol('duplicate-json-key');
  const invalid = Symbol('invalid-json-token-stream');
  let index = 0;

  function skipWhitespace() {
    while (index < raw.length && /[\u0009\u000a\u000d\u0020]/.test(raw[index])) index += 1;
  }

  function stringToken() {
    if (raw[index] !== '"') throw invalid;
    const start = index;
    index += 1;
    while (index < raw.length) {
      const code = raw.charCodeAt(index);
      if (raw[index] === '"') {
        index += 1;
        try { return JSON.parse(raw.slice(start, index)); } catch { throw invalid; }
      }
      if (raw[index] === '\\') {
        index += 1;
        if (index >= raw.length) throw invalid;
        const escape = raw[index];
        if (escape === 'u') {
          if (!/^[a-fA-F0-9]{4}$/.test(raw.slice(index + 1, index + 5))) throw invalid;
          index += 5;
          continue;
        }
        if (!'"\\/bfnrt'.includes(escape)) throw invalid;
        index += 1;
        continue;
      }
      if (code <= 0x1f) throw invalid;
      index += 1;
    }
    throw invalid;
  }

  function literalToken(literal) {
    if (!raw.startsWith(literal, index)) throw invalid;
    index += literal.length;
  }

  function numberToken() {
    if (raw[index] === '-') index += 1;
    if (raw[index] === '0') index += 1;
    else {
      if (!/[1-9]/.test(raw[index] || '')) throw invalid;
      while (/[0-9]/.test(raw[index] || '')) index += 1;
    }
    if (raw[index] === '.') {
      index += 1;
      if (!/[0-9]/.test(raw[index] || '')) throw invalid;
      while (/[0-9]/.test(raw[index] || '')) index += 1;
    }
    if (raw[index] === 'e' || raw[index] === 'E') {
      index += 1;
      if (raw[index] === '+' || raw[index] === '-') index += 1;
      if (!/[0-9]/.test(raw[index] || '')) throw invalid;
      while (/[0-9]/.test(raw[index] || '')) index += 1;
    }
  }

  function valueToken(depth) {
    if (depth > 64) throw invalid;
    skipWhitespace();
    const token = raw[index];
    if (token === '{') objectToken(depth + 1);
    else if (token === '[') arrayToken(depth + 1);
    else if (token === '"') stringToken();
    else if (token === 't') literalToken('true');
    else if (token === 'f') literalToken('false');
    else if (token === 'n') literalToken('null');
    else numberToken();
  }

  function objectToken(depth) {
    index += 1;
    skipWhitespace();
    const keys = new Set();
    if (raw[index] === '}') { index += 1; return; }
    while (index < raw.length) {
      const key = stringToken();
      if (keys.has(key)) throw duplicate;
      keys.add(key);
      skipWhitespace();
      if (raw[index] !== ':') throw invalid;
      index += 1;
      valueToken(depth);
      skipWhitespace();
      if (raw[index] === '}') { index += 1; return; }
      if (raw[index] !== ',') throw invalid;
      index += 1;
      skipWhitespace();
    }
    throw invalid;
  }

  function arrayToken(depth) {
    index += 1;
    skipWhitespace();
    if (raw[index] === ']') { index += 1; return; }
    while (index < raw.length) {
      valueToken(depth);
      skipWhitespace();
      if (raw[index] === ']') { index += 1; return; }
      if (raw[index] !== ',') throw invalid;
      index += 1;
      skipWhitespace();
    }
    throw invalid;
  }

  try {
    valueToken(0);
    skipWhitespace();
    if (index !== raw.length) throw invalid;
    return false;
  } catch (error) {
    if (error === duplicate) return true;
    return false; // JSON.parse below remains the canonical syntax validator.
  }
}

function parseWorkerResult(raw, expectedKind, allowedPrPaths, changedProductionPaths) {
  if (typeof raw !== 'string' || Buffer.byteLength(raw, 'utf8') > MAX_RESULT_BYTES) {
    fail('last_assistant_message is missing or too large');
  }
  const trimmed = raw.trim();
  // A wrapping fence or surrounding prose cannot satisfy both structural checks: a fenced
  // payload opens and closes on a backtick. Scanning the whole payload for a fence instead
  // would reject a fence inside a JSON string value — which the pr-team-review personas are
  // explicitly told to emit in an inline finding's `body`.
  if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) {
    fail('last_assistant_message must be one pure JSON object without fences or prose');
  }
  if (hasDuplicateJsonObjectKeys(trimmed)) {
    fail('last_assistant_message contains duplicate JSON object keys');
  }
  let result;
  try { result = JSON.parse(trimmed); } catch { fail('last_assistant_message is not valid JSON'); }
  if (!result || typeof result !== 'object' || Array.isArray(result)) {
    fail('worker result must be a JSON object');
  }
  validateResultValue(result);
  validateWorkerSchema(result, expectedKind, allowedPrPaths, changedProductionPaths);
  return normalizeWorkerResult(result, expectedKind);
}

function storeWorkerResult(payload, binding) {
  const kind = kindForAgentType(payload.agent_type);
  if (!kind) return { action: 'ignore' };
  const agentId = requireSafeText(payload.agent_id, 'worker agent_id', 512);
  return withLock(binding, (locations) => {
    const records = listRecords(locations, binding);
    const matching = records.filter((record) => record.kind === kind
      && Object.prototype.hasOwnProperty.call(record.workers, agentId));
    if (matching.length !== 1) fail('worker is not bound to exactly one evidence lease');
    const record = matching[0];
    const worker = record.workers[agentId];
    if (worker.agent_type !== payload.agent_type) fail('worker type does not match its binding');
    if (record.status !== 'active' || record.expires_at_ms <= Date.now()) {
      fail('worker binding is no longer active');
    }
    if (worker.status === 'completed') {
      let duplicate;
      try {
        duplicate = parseWorkerResult(payload.last_assistant_message, kind, record.allowed_pr_paths,
          record.changed_production_paths);
      } catch {
        fail('completed worker result is create-once');
      }
      if (hashObject(duplicate) !== worker.result_sha256) fail('completed worker result is create-once');
      return { action: 'stored', leaseId: record.lease_id };
    }
    if (!['bound', 'retry'].includes(worker.status)) {
      fail('worker binding is no longer active');
    }

    let result;
    let validationError;
    try {
      result = parseWorkerResult(payload.last_assistant_message, kind, record.allowed_pr_paths,
        record.changed_production_paths);
    } catch (error) {
      validationError = error.message;
    }
    worker.result_attempts += 1;
    if (validationError) {
      worker.result_error = validationError.slice(0, 1024);
      if (worker.result_attempts === 1) {
        worker.status = 'retry';
        record.revision += 1;
        atomicWriteRecord(locations.records, record);
        return { action: 'block', reason: worker.result_error };
      }
      worker.status = 'failed';
      worker.finished_at_ms = Date.now();
      record.revision += 1;
      atomicWriteRecord(locations.records, record);
      return { action: 'failed', reason: worker.result_error };
    }

    const duplicateRole = Object.entries(record.workers).some(([otherId, other]) => (
      otherId !== agentId && other.result && other.result.role === result.role
    ));
    if (duplicateRole) {
      worker.result_error = `worker result role "${result.role}" was already claimed`;
      if (worker.result_attempts === 1) {
        worker.status = 'retry';
        record.revision += 1;
        atomicWriteRecord(locations.records, record);
        return { action: 'block', reason: worker.result_error };
      }
      worker.status = 'failed';
      worker.finished_at_ms = Date.now();
      record.revision += 1;
      atomicWriteRecord(locations.records, record);
      return { action: 'failed', reason: worker.result_error };
    }

    worker.status = 'completed';
    worker.finished_at_ms = Date.now();
    worker.result = result;
    worker.result_sha256 = hashObject(result);
    delete worker.result_error;
    record.revision += 1;
    atomicWriteRecord(locations.records, record);
    return { action: 'stored', leaseId: record.lease_id };
  });
}

function revalidateExactFile(entry) {
  const current = readFileSnapshot(entry.path, 'leased evidence file');
  delete current.data;
  if (!sameSnapshot(entry, current)) {
    fail(`leased evidence file changed: ${diagnosticPath(entry.path)}`);
  }
}

function revalidateSafeRoot(entry) {
  const current = directoryTreeSnapshot(entry.path, 'leased safe subtree');
  if (!sameSnapshot(entry, current, true)) {
    fail(`leased safe subtree changed: ${diagnosticPath(entry.path)}`);
  }
}

function canonicalToolPath(input, cwd, label, expected) {
  requireSafeText(input, label);
  const normalizedInput = hostPaths.normalizeHostPathInput(input, label);
  const requested = path.isAbsolute(normalizedInput)
    ? path.resolve(normalizedInput) : path.resolve(cwd, normalizedInput);
  return canonicalExisting(requested, label, expected).canonical;
}

function traversalPatternViolation(payload) {
  const fields = payload.tool_name === 'Grep'
    ? ['glob', 'include', 'exclude']
    : ['pattern', 'glob', 'include', 'exclude'];
  for (const field of fields) {
    const raw = payload.tool_input[field];
    if (raw === undefined) continue;
    const values = Array.isArray(raw) ? raw : [raw];
    if (values.length === 0) {
      return `${payload.tool_name} path filter has an unsafe grammar`;
    }
    for (const value of values) {
      // Path-filter syntax varies across host/tool versions. Keep the lease
      // boundary independent of those parsers by accepting only a deliberately
      // small relative glob grammar. In particular, no escaping, grouping,
      // alternation, character classes, braces, or extglob operators are
      // accepted, and any ".." substring is denied before interpretation.
      if (typeof value !== 'string'
          || value.length === 0
          || value.length > 4096
          || value.includes('\\')
          || value.includes('..')
          || path.isAbsolute(value)
          || !/^[A-Za-z0-9._/*?-]+$/.test(value)
          || /(?:^|\/)\.(?:git|zensu)(?:\/|$)/i.test(value)) {
        return `${payload.tool_name} pattern escapes the leased traversal root`;
      }
    }
  }
  return null;
}

function toolViolation(payload, binding) {
  const kind = kindForAgentType(payload.agent_type);
  if (!kind) return 'evidence-worker-v1 has an unknown agent type';
  if (!ALLOWED_TOOLS.has(payload.tool_name)) {
    return `evidence-worker-v1 cannot invoke ${payload.tool_name}; only Read, Grep, and Glob are allowed`;
  }
  let agentId;
  try { agentId = requireSafeText(payload.agent_id, 'worker agent_id', 512); } catch (error) {
    return error.message;
  }
  try {
    return withLock(binding, (locations) => {
      const records = listRecords(locations, binding);
      const matching = records.filter((record) => record.kind === kind
        && Object.prototype.hasOwnProperty.call(record.workers, agentId));
      if (matching.length !== 1) return 'evidence-worker-v1 has no unique bound lease';
      const record = matching[0];
      const worker = record.workers[agentId];
      if (record.status !== 'active') return 'evidence-worker-v1 lease is revoked';
      if (record.expires_at_ms <= Date.now()) return 'evidence-worker-v1 lease is expired';
      if (worker.agent_type !== payload.agent_type || !['bound', 'retry'].includes(worker.status)) {
        return 'evidence-worker-v1 agent binding is inactive or mismatched';
      }

      if (payload.tool_name === 'Read') {
        const rawPath = payload.tool_input.file_path ?? payload.tool_input.path;
        if (typeof rawPath !== 'string') return 'evidence-worker-v1 Read requires one explicit file_path';
        const requested = canonicalToolPath(rawPath, binding.projectRoot, 'Read file_path', 'file');
        const entry = record.exact_files.find((candidate) => candidate.path === requested);
        if (!entry) return 'evidence-worker-v1 Read path is not an exact leased file';
        revalidateExactFile(entry);
        return null;
      }

      if (typeof payload.tool_input.path !== 'string') {
        return `evidence-worker-v1 ${payload.tool_name} requires an explicit leased path`;
      }
      const requested = canonicalToolPath(payload.tool_input.path, binding.projectRoot,
        `${payload.tool_name} path`, 'directory');
      const entry = record.safe_roots.find((candidate) => candidate.path === requested);
      if (!entry) return `evidence-worker-v1 ${payload.tool_name} path is not an exact leased traversal root`;
      const patternViolation = traversalPatternViolation(payload);
      if (patternViolation) return patternViolation;
      revalidateSafeRoot(entry);
      return null;
    });
  } catch (error) {
    return `evidence-worker-v1 validation failed: ${error.message}`;
  }
}

function parseCli(argv) {
  const operation = argv[0];
  if (!['create', 'finalize', 'close', 'collect'].includes(operation)) {
    fail('expected create, finalize, close, or collect');
  }
  const options = { requiredFiles: [] };
  const seen = new Set();
  for (let index = 1; index < argv.length; index += 1) {
    const flag = argv[index];
    if (flag === '--required-file') {
      if (index + 1 >= argv.length) fail('--required-file requires a value');
      options.requiredFiles.push(argv[++index]);
      continue;
    }
    const mapping = {
      '--kind': 'kind',
      '--files-manifest': 'filesManifest',
      '--safe-subtrees-manifest': 'safeSubtreesManifest',
      '--max-workers': 'maxWorkers',
      '--ttl-seconds': 'ttlSeconds',
      '--lease-id': 'leaseId',
      '--name-status-file': 'nameStatusFile',
      '--changed-production-files-file': 'changedProductionFilesFile',
      '--agent-id': 'agentId',
      '--expected-role': 'expectedRole',
    };
    const key = mapping[flag];
    if (!key || index + 1 >= argv.length) fail(`unknown or valueless argument "${flag}"`);
    if (seen.has(key)) fail(`duplicate argument "${flag}"`);
    seen.add(key);
    options[key] = argv[++index];
  }
  if (operation === 'create') {
    for (const key of ['kind', 'filesManifest', 'safeSubtreesManifest', 'maxWorkers']) {
      if (options[key] === undefined) fail(`create requires ${key}`);
    }
    if (options.leaseId !== undefined) fail('create does not accept --lease-id');
    if (options.kind === 'pr-review'
        && (options.nameStatusFile === undefined || options.changedProductionFilesFile === undefined)) {
      fail('pr-review create requires --name-status-file and --changed-production-files-file');
    }
    if (options.kind === 'plan-review'
        && (options.nameStatusFile !== undefined || options.changedProductionFilesFile !== undefined)) {
      fail('plan-review create does not accept PR path inventory files');
    }
  } else {
    if ((options.kind === undefined) === (options.leaseId === undefined)) {
      fail(`${operation} requires exactly one of --kind or --lease-id`);
    }
    if (operation === 'collect'
        && (options.agentId === undefined || options.expectedRole === undefined)) {
      fail('collect requires --agent-id and --expected-role');
    }
    if (operation !== 'collect'
        && (options.agentId !== undefined || options.expectedRole !== undefined)) {
      fail(`${operation} does not accept --agent-id or --expected-role`);
    }
    if (options.requiredFiles.length > 0 || options.filesManifest !== undefined
        || options.safeSubtreesManifest !== undefined || options.maxWorkers !== undefined
        || options.ttlSeconds !== undefined || options.nameStatusFile !== undefined
        || options.changedProductionFilesFile !== undefined) {
      fail(`${operation} received create-only arguments`);
    }
  }
  return { operation, options };
}

function cliMain() {
  const parsed = parseCli(process.argv.slice(2));
  const binding = bindFromModelEnvironment();
  if (parsed.operation === 'create') {
    process.stdout.write(`lease_id=${createLease(binding, parsed.options)}\n`);
  } else if (parsed.operation === 'finalize') {
    process.stdout.write(`sealed=${finalizeLease(binding, parsed.options)}\n`);
  } else if (parsed.operation === 'close') {
    process.stdout.write(`closed=${closeLease(binding, parsed.options)}\n`);
  } else {
    process.stdout.write(`${JSON.stringify(collectLease(binding, parsed.options))}\n`);
  }
}

if (require.main === module) {
  try { cliMain(); } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 2;
  }
}

module.exports = {
  bindWorker,
  collectLease,
  createLease,
  finalizeLease,
  kindForAgentType,
  parseWorkerResult,
  sealRecord,
  storeWorkerResult,
  toolViolation,
  // The store's own vocabulary, exported so the superseded-lease sweep consumes
  // it instead of hand-copying it. Five elements used to live as copies in
  // session-control-core-v1.js and only two of them were pinned — and both pins
  // compared source spellings rather than behaviour.
  LEASE_ID_RE,
  MAX_RECORD_BYTES,
  REVIEW_EVIDENCE_SEGMENTS,
  ensurePrivateDirectory,
  leaseRecordIsOwned,
  withLock,
};
