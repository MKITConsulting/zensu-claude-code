'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const os = require('node:os');
const childProcess = require('node:child_process');

const RECEIPT_SCHEMAS = Object.freeze({ 'edit-landing-v1': 1, 'edit-landing-v2': 2 });
const MAX_RECEIPT_BYTES = 4 * 1024 * 1024;
const EXIT = Object.freeze({ ok: 0, usage: 2, none: 3 });
const SCOPE_SCHEMA = 'edit-landing-scope-v1';
const PREDICATE_SCHEMA = 'edit-landing-predicates-v1';
const LIMITS = {
  claims: 2000,
  literals: 100,
  literalBytes: 4096,
  proofFileBytes: 8 * 1024 * 1024,
  snapshotBytes: 64 * 1024 * 1024,
  scopeBytes: MAX_RECEIPT_BYTES,
};
const NEW_GENERATION = 'arm a new generation with --tdd-begin, which starts an empty audit scope';
const RECEIPT_DIRECTORY = Object.freeze(['.zensu', 'state']);
const RECEIPT_PREFIX = 'edit-landing-';
const RECEIPT_NAME_RE = /^edit-landing-.+\.json$/;
const HASH_CHUNK_BYTES = 1024 * 1024;
const GIT_TIMEOUT_MS = 10000;
const UNRESOLVED_COUNTERS = Object.freeze(['pending', 'notLanded', 'unverified']);
const CHECKPOINT_FAILURE = 'The current audit has not completed. Re-run it; its cumulative scope is preserved.';
const GIT_FAILURE = 'The latest audit did not complete because git failed. Re-run the audit once git works again; its cumulative scope is preserved.';
const RECOVERY_GUIDANCE = 'Keep the original --baseline, --session-epoch and --dirty-before inputs or omit them so the persisted scope supplies them, and add --predicates with current literal/hash proofs where a claim is PENDING. Use --inventory for read-only inspection.';

class AuditScopeError extends Error {}

function auditFail(message) {
  throw new AuditScopeError(message);
}

function core() {
  return require('./session-control-core-v1.js');
}

function receiptFile(root, sessionKey) {
  if (typeof sessionKey !== 'string' || sessionKey === '' || /[\\/\x00-\x1f\x7f]/.test(sessionKey)) {
    auditFail('the receipt path needs a resolved session key');
  }
  return path.join(root, ...RECEIPT_DIRECTORY, `${RECEIPT_PREFIX}${sessionKey}.json`);
}

const noFollowFlag = () => (process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW) ? fs.constants.O_NOFOLLOW : 0);

function readBoundedJson(filePath, maxBytes) {
  let descriptor;
  let before;
  try {
    before = fs.lstatSync(filePath);
    if (before.isSymbolicLink()) return { invalid: 'unreadable (symlink)' };
    const noFollow = process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW) ? fs.constants.O_NOFOLLOW : 0;
    const flags = fs.constants.O_RDONLY | noFollow | (fs.constants.O_NONBLOCK || 0);
    descriptor = fs.openSync(filePath, flags);
  } catch (error) {
    if (error && error.code === 'ENOENT') return { absent: true };
    return { invalid: `unreadable (${(error && error.code) || 'error'})` };
  }
  try {
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile()) return { invalid: 'not a regular file' };
    if (stat.dev !== before.dev || stat.ino !== before.ino) return { invalid: 'unreadable (replaced)' };
    if (stat.size > maxBytes) return { invalid: 'oversized' };
    const buffer = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < stat.size) {
      const read = fs.readSync(descriptor, buffer, offset, stat.size - offset, offset);
      if (read <= 0) break;
      offset += read;
    }
    if (offset !== stat.size) return { invalid: 'short read' };
    return { value: JSON.parse(buffer.toString('utf8')) };
  } catch (error) {
    return { invalid: error && error.code ? `unreadable (${error.code})` : 'unparseable' };
  } finally {
    try { fs.closeSync(descriptor); } catch { }
  }
}

function canonical(target) {
  try {
    return fs.realpathSync(target);
  } catch {
    return path.resolve(target);
  }
}

function isOutside(relative) {
  return relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative);
}

function resolveRunLog(projectRoot, logValue) {
  if (typeof projectRoot !== 'string' || projectRoot === '') return { reason: 'no project root is bound' };
  if (typeof logValue !== 'string' || logValue === '') return { reason: 'no run log was named' };
  const root = canonical(path.resolve(projectRoot));
  const logsDirRaw = path.join(root, '.zensu', 'logs');
  try {
    if (fs.lstatSync(logsDirRaw).isSymbolicLink()) return { reason: 'the project .zensu/logs directory is a symlink' };
  } catch { }
  const logsDir = canonical(logsDirRaw);
  if (isOutside(path.relative(root, logsDir))) return { reason: 'the project .zensu/logs directory resolves outside the project root' };
  const raw = path.resolve(root, logValue);
  const resolved = path.join(canonical(path.dirname(raw)), path.basename(raw));
  const relative = path.relative(logsDir, resolved);
  if (relative === '' || isOutside(relative)) return { reason: 'the run log is not inside the project .zensu/logs directory' };
  if (!resolved.endsWith('.log')) return { reason: 'the run log does not end in .log' };
  return {
    root,
    logRel: path.relative(root, resolved).split(path.sep).join('/'),
    stem: path.basename(resolved, '.log'),
  };
}

function receiptRunLog(options) {
  const loaded = readBoundedJson(options.receiptPath, options.maxBytes || MAX_RECEIPT_BYTES);
  if (loaded.absent) return { status: 'absent' };
  if (loaded.invalid) return { status: 'invalid', reason: `the edit-landing receipt is ${loaded.invalid}` };
  const receipt = loaded.value;
  const version = receipt && typeof receipt === 'object' && Object.prototype.hasOwnProperty.call(RECEIPT_SCHEMAS, receipt.schema)
    ? RECEIPT_SCHEMAS[receipt.schema]
    : 0;
  if (!version || typeof receipt.log !== 'string' || receipt.log === '') {
    return { status: 'invalid', reason: 'the edit-landing receipt names no run log under a known schema' };
  }
  const resolved = resolveRunLog(options.projectRoot, receipt.log);
  if (resolved.reason) return { status: 'invalid', reason: resolved.reason };
  return { status: 'ok', root: resolved.root, logRel: resolved.logRel, stem: resolved.stem };
}

const digest = (value) => crypto.createHash('sha256').update(value).digest('hex');
const same = (left, right) => JSON.stringify(left) === JSON.stringify(right);

function openRegular(file) {
  let stat;
  try {
    stat = fs.lstatSync(file);
  } catch (error) {
    auditFail(`an audit input cannot be read (${(error && error.code) || 'error'})`);
  }
  if (stat.isSymbolicLink() || !stat.isFile()) auditFail('an audit input is not a regular file');
  const descriptor = fs.openSync(file, fs.constants.O_RDONLY | noFollowFlag() | (fs.constants.O_NONBLOCK || 0));
  const opened = fs.fstatSync(descriptor);
  if (opened.ino !== stat.ino || opened.dev !== stat.dev || opened.size !== stat.size) {
    fs.closeSync(descriptor);
    auditFail('an audit input changed while it was opened');
  }
  return { descriptor, stat: opened };
}

function boundedFile(file, limit) {
  const { descriptor, stat } = openRegular(file);
  try {
    if (stat.nlink !== 1) auditFail('an audit input is hard-linked elsewhere');
    if (stat.size > limit) auditFail(`an audit input exceeds the ${limit}-byte limit`);
    const buffer = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < stat.size) {
      const read = fs.readSync(descriptor, buffer, offset, stat.size - offset, offset);
      if (read <= 0) break;
      offset += read;
    }
    if (offset !== stat.size) auditFail('an audit input returned a short read');
    return buffer;
  } finally {
    fs.closeSync(descriptor);
  }
}

function hashClaimedFile(file, budget) {
  const { descriptor, stat } = openRegular(file);
  try {
    if (stat.size > budget.remaining) {
      auditFail(`the claimed files exceed the ${LIMITS.snapshotBytes}-byte snapshot budget of one audit generation; claim source files rather than generated artifacts, or ${NEW_GENERATION}`);
    }
    const hash = crypto.createHash('sha256');
    const chunk = Buffer.alloc(Math.min(HASH_CHUNK_BYTES, Math.max(stat.size, 1)));
    let offset = 0;
    while (offset < stat.size) {
      const read = fs.readSync(descriptor, chunk, 0, Math.min(chunk.length, stat.size - offset), offset);
      if (read <= 0) break;
      hash.update(chunk.subarray(0, read));
      offset += read;
    }
    if (offset !== stat.size) auditFail('a claimed file returned a short read');
    budget.remaining -= stat.size;
    return { bytes: stat.size, sha256: hash.digest('hex') };
  } finally {
    fs.closeSync(descriptor);
  }
}

function relativeFile(value) {
  if (typeof value !== 'string' || value === '' || value.length > 4096 || /[\x00-\x1f\x7f\\]/.test(value)
      || path.isAbsolute(value) || path.posix.isAbsolute(value) || path.posix.normalize(value) !== value
      || value.split('/').some((part) => part === '..' || part === '.' || part === '' || part === '.git')) {
    auditFail('expected a normalized repository-relative path inside the project');
  }
  return value;
}

function claimPath(value) {
  try {
    return relativeFile(value);
  } catch {
    return null;
  }
}

function snapshot(root, file, budget = { remaining: LIMITS.snapshotBytes }) {
  relativeFile(file);
  const parts = file.split('/');
  let target = root;
  for (let index = 0; index < parts.length; index++) {
    target = path.join(target, parts[index]);
    let stat;
    try {
      stat = fs.lstatSync(target);
    } catch (error) {
      if (error.code === 'ENOENT' || error.code === 'ENOTDIR') return { path: file, exists: false };
      auditFail(`a claimed path cannot be inspected (${error.code || 'error'})`);
    }
    const last = index === parts.length - 1;
    if (stat.isSymbolicLink()) {
      if (!last) return { path: file, exists: true, kind: 'beyond-link' };
      let linked;
      try {
        linked = fs.readlinkSync(target);
      } catch (error) {
        auditFail(`a claimed link cannot be read (${error.code || 'error'})`);
      }
      return { path: file, exists: true, kind: 'link', sha256: digest(linked) };
    }
    if (!last && !stat.isDirectory()) return { path: file, exists: false };
    if (last && !stat.isFile()) return { path: file, exists: true, kind: stat.isDirectory() ? 'directory' : 'special' };
  }
  return { path: file, exists: true, kind: 'file', ...hashClaimedFile(target, budget) };
}

function realDirectory(value, label) {
  if (typeof value !== 'string' || value === '') auditFail(`${label} is required`);
  let resolved;
  try {
    resolved = fs.realpathSync(value);
  } catch (error) {
    auditFail(`${label} cannot be resolved (${error.code || 'error'})`);
  }
  if (!fs.statSync(resolved).isDirectory()) auditFail(`${label} is not a directory`);
  return resolved;
}

function logPrefix(log, previous) {
  const { descriptor, stat } = openRegular(log);
  try {
    if (stat.nlink !== 1) auditFail('an audit input is hard-linked elsewhere');
    const rewritten = `the audited run log was rewritten or truncated since the previous audit; keep its append-only history, or ${NEW_GENERATION}`;
    if (previous && (!Number.isSafeInteger(previous.bytes) || previous.bytes < 0 || typeof previous.sha256 !== 'string'
        || stat.size < previous.bytes)) {
      auditFail(rewritten);
    }
    const want = previous ? previous.bytes : null;
    const whole = crypto.createHash('sha256');
    let prefixDigest = want === 0 ? digest(Buffer.alloc(0)) : null;
    const chunk = Buffer.alloc(HASH_CHUNK_BYTES);
    let offset = 0;
    while (offset < stat.size) {
      let length = Math.min(chunk.length, stat.size - offset);
      if (want !== null && offset < want && offset + length > want) length = want - offset;
      const read = fs.readSync(descriptor, chunk, 0, length, offset);
      if (read <= 0) break;
      whole.update(chunk.subarray(0, read));
      offset += read;
      if (want !== null && offset === want) prefixDigest = whole.copy().digest('hex');
    }
    if (offset !== stat.size) auditFail('an audit input returned a short read');
    if (previous && prefixDigest !== previous.sha256) auditFail(rewritten);
    return { bytes: stat.size, sha256: whole.digest('hex') };
  } finally {
    fs.closeSync(descriptor);
  }
}

function sessionKeyOf(session) {
  return session ? core().sessionKey(session) : null;
}

function workflowState(root, session) {
  if (!session) return { status: 'none' };
  const engine = core();
  const file = engine.adoptionWorkflowStatePath(root, session);
  const loaded = readBoundedJson(file, MAX_RECEIPT_BYTES);
  if (loaded.absent) return { status: 'absent' };
  if (loaded.invalid) return { status: 'invalid', reason: `it is ${loaded.invalid}` };
  const value = loaded.value;
  if (!value || typeof value !== 'object' || value.schema !== engine.WORKFLOW_SCHEMA
      || value.session_id_hash !== engine.sessionIdHash(session)) {
    return { status: 'invalid', reason: 'it belongs to another session or carries another schema' };
  }
  const chain = engine.workflowChainSnapshot(value, session);
  if (!chain) return { status: 'invalid', reason: 'its chain fields do not validate' };
  return { status: 'ok', active: chain.active === true && chain.chainDone !== true, chain };
}

function scopeLogValue(root, log) {
  const relative = path.relative(root, log);
  return isOutside(relative) ? log : relative.split(path.sep).join('/');
}

function auditedLog(value) {
  if (typeof value !== 'string' || value === '') auditFail('the run log is required');
  let stat;
  try {
    stat = fs.lstatSync(value);
  } catch (error) {
    auditFail(`the run log cannot be read (${error.code || 'error'})`);
  }
  if (stat.isSymbolicLink() || !stat.isFile()) auditFail('the run log is not a regular file');
  return fs.realpathSync(value);
}

function prepareScope(options) {
  const root = realDirectory(options.root, 'the project root');
  const claimRoot = options.claimRoot ? realDirectory(options.claimRoot, 'the audited repository root') : root;
  const log = auditedLog(options.log);
  const sessionKey = sessionKeyOf(options.session);
  let previous = null;
  let legacyUnresolved = false;
  if (options.receipt && options.receipt !== '-') {
    const loaded = readBoundedJson(options.receipt, MAX_RECEIPT_BYTES);
    if (loaded.invalid) auditFail(`the previous receipt is ${loaded.invalid}, so its audit scope cannot be inherited and it is not replaced silently`);
    if (!loaded.absent) {
      const value = loaded.value;
      if (!value || typeof value !== 'object' || Array.isArray(value) || !Object.prototype.hasOwnProperty.call(RECEIPT_SCHEMAS, value.schema)) {
        auditFail('the previous receipt is not an edit-landing receipt, so it is not replaced silently');
      }
      if (value.auditScope === undefined) {
        legacyUnresolved = value.clean !== true || UNRESOLVED_COUNTERS.some((field) => Number(value[field]) > 0);
      } else {
        const scope = value.auditScope;
        if (!scope || typeof scope !== 'object' || scope.schema !== SCOPE_SCHEMA) auditFail('the previous receipt carries an unknown audit scope');
        if (scope.sessionKey !== sessionKey || scope.root !== root) auditFail('the previous receipt belongs to another session or project');
        if (scope.log !== log) {
          auditFail('this receipt is bound to another run log; audit the log it names, or arm a new generation with --tdd-begin, which retires the receipt');
        }
        previous = scope;
      }
    }
  }
  const priorClaimRoot = previous ? (previous.claimRoot === null ? null : (previous.claimRoot || previous.root)) : undefined;
  if (!options.gitFault && typeof priorClaimRoot === 'string' && priorClaimRoot !== claimRoot) {
    auditFail('the audited repository root changed since the previous audit');
  }
  const prefix = logPrefix(log, previous && previous.logPrefix);
  const inherited = (name, flag, supplied) => {
    const persisted = previous && typeof previous[name] === 'string' ? previous[name] : '';
    if (supplied === undefined) return persisted;
    if (persisted !== '' && supplied !== persisted) {
      auditFail(`${flag} cannot be changed or cleared within this generation; omit it and the audit inherits the persisted value`);
    }
    return supplied;
  };
  const dirty = new Set(previous && Array.isArray(previous.dirty) ? previous.dirty : []);
  if (options.dirty !== undefined) {
    if (!options.dirty) auditFail('--dirty-before requires an existing file');
    for (const line of boundedFile(options.dirty, MAX_RECEIPT_BYTES).toString('utf8').split(/\r?\n/)) {
      if (line !== '') dirty.add(relativeFile(line));
    }
  }
  return {
    schema: SCOPE_SCHEMA,
    root,
    claimRoot: options.gitFault ? (previous ? priorClaimRoot : null) : claimRoot,
    log,
    sessionKey,
    baseline: inherited('baseline', '--baseline', options.baseline),
    epoch: inherited('epoch', '--session-epoch', options.epoch),
    dirty: [...dirty].sort(),
    logPrefix: prefix,
    previous,
    legacyUnresolved,
  };
}

function safeDestination(receiptPath) {
  if (typeof receiptPath !== 'string' || !path.isAbsolute(receiptPath) || /(^|[\\/])edit-landing-\.json$/.test(receiptPath)) {
    auditFail('the receipt destination must be an absolute path with a resolved session key');
  }
  const missing = [];
  let existing = path.dirname(receiptPath);
  for (;;) {
    let present = false;
    try {
      fs.lstatSync(existing);
      present = true;
    } catch (error) {
      if (error.code !== 'ENOENT') auditFail(`a receipt ancestor cannot be inspected (${error.code || 'error'})`);
    }
    if (present) break;
    const parent = path.dirname(existing);
    if (parent === existing) auditFail('the receipt destination has no existing ancestor');
    missing.unshift(path.basename(existing));
    existing = parent;
  }
  let current;
  try {
    current = fs.realpathSync(existing);
  } catch (error) {
    auditFail(`a receipt ancestor cannot be resolved (${error.code || 'error'})`);
  }
  if (!fs.statSync(current).isDirectory()) auditFail('a receipt ancestor is not a directory');
  for (const part of missing) {
    current = path.join(current, part);
    try { fs.mkdirSync(current); } catch (error) { if (error.code !== 'EEXIST') auditFail('a receipt ancestor cannot be created'); }
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink() || !stat.isDirectory()) auditFail('a receipt ancestor changed into a link while it was created');
  }
  const target = path.join(current, path.basename(receiptPath));
  try {
    const stat = fs.lstatSync(target);
    if (stat.isSymbolicLink() || !stat.isFile() || stat.nlink !== 1) auditFail('the receipt destination is not a single-linked regular file');
  } catch (error) {
    if (error instanceof AuditScopeError) throw error;
    if (error.code !== 'ENOENT') auditFail(`the receipt destination cannot be inspected (${error.code || 'error'})`);
  }
  return target;
}

function writeReceiptAtomically(receiptPath, value) {
  const target = safeDestination(receiptPath);
  const encoded = `${JSON.stringify(value)}\n`;
  if (Buffer.byteLength(encoded) > LIMITS.scopeBytes) {
    auditFail(`the audit scope exceeds the ${LIMITS.scopeBytes}-byte receipt limit; claim fewer files in this generation, or ${NEW_GENERATION}`);
  }
  const temporary = `${target}.scope-${crypto.randomUUID()}`;
  try {
    fs.writeFileSync(temporary, encoded, { flag: 'wx', mode: 0o600 });
    fs.renameSync(temporary, target);
  } finally {
    try { fs.unlinkSync(temporary); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
}

function persistedScope(scope) {
  const previous = scope.previous || {};
  const value = {
    ...scope,
    claims: Array.isArray(scope.claims) ? scope.claims : (previous.claims || []),
    snapshots: scope.snapshots || previous.snapshots || {},
    observedFiles: scope.observedFiles || previous.observedFiles || [],
    tree: scope.tree === undefined ? (previous.tree || null) : scope.tree,
  };
  delete value.previous;
  delete value.legacyUnresolved;
  delete value.certified;
  delete value.proved;
  return value;
}

function checkpointScope(scope, receiptPath, session) {
  if (!receiptPath || receiptPath === '-') return;
  const auditScope = persistedScope(scope);
  const claims = auditScope.claims.length;
  writeReceiptAtomically(receiptPath, {
    schema: 'edit-landing-v2',
    session: session || '',
    log: scopeLogValue(scope.root, scope.log),
    claims,
    landed: 0,
    notLanded: 0,
    unverified: claims,
    pending: 0,
    exemptIgnored: 0,
    exemptVerified: 0,
    clean: false,
    auditFailure: CHECKPOINT_FAILURE,
    auditScope,
  });
}

function parseManifest(file) {
  const text = boundedFile(file, MAX_RECEIPT_BYTES).toString('utf8');
  if (text === '') return [];
  const fields = text.split('\0');
  if (fields.pop() !== '' || fields.length % 3 !== 0) auditFail('the claim manifest is malformed');
  const records = [];
  for (let index = 0; index < fields.length; index += 3) {
    if (fields[index] === '') auditFail('the claim manifest is malformed');
    records.push({ step: fields[index], raw: fields[index + 1], path: fields[index + 2] === '' ? null : claimPath(fields[index + 2]) });
  }
  if (records.length > LIMITS.claims) {
    auditFail(`the run log names more than ${LIMITS.claims} claimed files; name each file once per step, or ${NEW_GENERATION}`);
  }
  return records;
}

function literalList(value) {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > LIMITS.literals
      || !value.every((entry) => typeof entry === 'string' && entry.trim() !== '' && Buffer.byteLength(entry) <= LIMITS.literalBytes)) {
    auditFail(`a predicate literal list must hold at most ${LIMITS.literals} nonblank strings of at most ${LIMITS.literalBytes} bytes; prove the claim with fewer, shorter literals`);
  }
  return value;
}

function verifyPredicates(root, file, claims, snapshots, observedFiles, baseline) {
  if (!file) return new Set();
  let loaded;
  try {
    loaded = JSON.parse(boundedFile(file, MAX_RECEIPT_BYTES).toString('utf8'));
  } catch (error) {
    if (error instanceof AuditScopeError) throw error;
    auditFail('the predicate proof document is not valid JSON');
  }
  if (!loaded || typeof loaded !== 'object' || Array.isArray(loaded) || loaded.schema !== PREDICATE_SCHEMA
      || !Array.isArray(loaded.claims) || loaded.claims.length === 0 || loaded.claims.length > LIMITS.claims
      || Object.keys(loaded).some((key) => key !== 'schema' && key !== 'claims')) {
    auditFail(`the predicate proof document must be {"schema":"${PREDICATE_SCHEMA}","claims":[…]} with 1 to ${LIMITS.claims} entries`);
  }
  const proved = new Set();
  for (const proof of loaded.claims) {
    if (!proof || typeof proof !== 'object' || Array.isArray(proof) || typeof proof.step !== 'string'
        || proof.step === '' || proof.step.length > 512) {
      auditFail('every predicate proof needs the exact claim step label');
    }
    const filePath = relativeFile(proof.path);
    const matches = claims.map((claim, index) => (claim.step === proof.step && claim.path === filePath ? index : -1)).filter((index) => index >= 0);
    if (matches.length === 0) auditFail('a predicate proof names no claim of this run log');
    const current = snapshots[filePath];
    if (proof.missing === true) {
      if (Object.keys(proof).some((key) => !['step', 'path', 'missing'].includes(key))) auditFail('a deletion proof carries only step, path and missing');
      if (current.exists) auditFail('a deletion proof names a path that still exists');
      if (!observedFiles.has(filePath)) {
        const changes = require('./review-packet-v1.js').collectChanges({ root, baseline: baseline || '' });
        if (changes.kind !== 'git' || !changes.changed_files.includes(filePath)) {
          auditFail('a deletion proof needs a file this audit observed earlier, or a git deletion of a tracked file');
        }
      }
    } else {
      if (Object.keys(proof).some((key) => !['step', 'path', 'sha256', 'present', 'absent'].includes(key))) auditFail('a predicate proof carries an unknown field');
      if (!current.exists || current.kind !== 'file') auditFail('a literal predicate proof needs an existing regular file');
      if (typeof proof.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(proof.sha256) || proof.sha256 !== current.sha256) {
        auditFail('a predicate proof hash is stale or invalid; hash the current file bytes');
      }
      const present = literalList(proof.present);
      const absent = literalList(proof.absent);
      if (present.length === 0 && absent.length === 0) auditFail('a predicate proof needs at least one present or absent literal');
      if (current.bytes > LIMITS.proofFileBytes) {
        auditFail(`a literal predicate proof reads its file whole, and a claimed file exceeds the ${LIMITS.proofFileBytes}-byte limit; withdraw that claim with CLAIM WITHDRAWN instead`);
      }
      const content = boundedFile(path.join(root, filePath), LIMITS.proofFileBytes);
      if (digest(content) !== current.sha256) auditFail('a claimed file changed while its predicate proof was checked');
      const text = content.toString('utf8');
      if (present.some((literal) => !text.includes(literal)) || absent.some((literal) => text.includes(literal))) {
        auditFail('a literal predicate does not hold on the current file');
      }
    }
    for (const index of matches) proved.add(index + 1);
  }
  return proved;
}

function prepareClaims(scope, manifest, predicates) {
  const claims = parseManifest(manifest);
  const old = scope.previous;
  if (old) {
    const priorClaims = Array.isArray(old.claims) ? old.claims : null;
    if (!priorClaims || priorClaims.length > claims.length || priorClaims.some((claim, index) => claim.step !== claims[index].step
        || claim.raw !== claims[index].raw)) {
      auditFail('the claims the previous audit recorded were rewritten or removed from the run log');
    }
  }
  const claimRoot = scope.claimRoot || scope.root;
  const snapshots = Object.create(null);
  const budget = { remaining: LIMITS.snapshotBytes };
  for (const claim of claims) {
    if (!claim.path || Object.prototype.hasOwnProperty.call(snapshots, claim.path)) continue;
    snapshots[claim.path] = snapshot(claimRoot, claim.path, budget);
  }
  const dirty = new Set(scope.dirty);
  const certified = [];
  const priorSnapshots = old && old.snapshots && typeof old.snapshots === 'object' ? old.snapshots : {};
  const observedFiles = new Set(old && Array.isArray(old.observedFiles) ? old.observedFiles
    : Object.entries(priorSnapshots).filter(([, value]) => value && value.exists).map(([file]) => file));
  for (const [file, value] of Object.entries(snapshots)) if (value.exists) observedFiles.add(file);
  if (scope.legacyUnresolved) for (const claim of claims) if (claim.path) dirty.add(claim.path);
  if (old) {
    for (let index = 0; index < claims.length; index++) {
      const claim = claims[index];
      const prior = old.claims[index];
      if (!claim.path) continue;
      const moved = Boolean(prior) && prior.path !== claim.path;
      if (moved) dirty.add(claim.path);
      if (prior && !moved && prior.certified === true && same(priorSnapshots[claim.path], snapshots[claim.path])) certified.push(index + 1);
      if (Object.prototype.hasOwnProperty.call(priorSnapshots, claim.path)) dirty.add(claim.path);
    }
  }
  const proved = [...verifyPredicates(claimRoot, predicates, claims, snapshots, observedFiles, scope.baseline)];
  const result = { ...scope, dirty: [...dirty].sort(), claims, snapshots: { ...snapshots }, observedFiles: [...observedFiles].sort(), certified, proved };
  delete result.previous;
  delete result.legacyUnresolved;
  return result;
}

function gitTop(root) {
  const result = childProcess.spawnSync('git', ['-C', root, 'rev-parse', '--show-toplevel'], {
    env: require('./evidence-run-v1.js').gitEnvironment(),
    encoding: 'utf8',
    timeout: GIT_TIMEOUT_MS,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error || result.status !== 0) return null;
  const top = String(result.stdout).trim();
  return top === '' ? null : canonical(top);
}

function currentClaimRoot(root) {
  const where = require('./evidence-run-v1.js').workTree(root);
  if (where.applicable === false) return root;
  if (where.applicable !== true) auditFail(`the current tree is unavailable: ${where.reason}`);
  const top = gitTop(root);
  if (!top) auditFail('the current tree is unavailable: git rev-parse --show-toplevel failed');
  return top;
}

function measuredTree(root) {
  const evidence = require('./evidence-run-v1.js');
  const where = evidence.workTree(root);
  if (where.applicable === false) return { kind: 'explicit-no-git' };
  if (where.applicable !== true) auditFail(`the current tree is unavailable: ${where.reason}`);
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-landing-tree-'));
  try {
    const result = evidence.computeTree(root, scratch, { ...evidence.LIMITS, gitTimeoutMs: GIT_TIMEOUT_MS },
      { workflowStateAtEveryDepth: true });
    if (result.tree) return { kind: 'git', tree: result.tree };
    if (result.limited === true) return { kind: 'git', tree: null, reason: result.reason };
    return auditFail(`the current tree is unavailable: ${result.reason}`);
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

function finishScope(scope, landedFile, bareWired) {
  const landed = new Set(boundedFile(landedFile, MAX_RECEIPT_BYTES).toString('utf8').split('\n').filter(Boolean).map(Number));
  const claimRoot = scope.claimRoot || scope.root;
  const budget = { remaining: LIMITS.snapshotBytes };
  for (const [file, old] of Object.entries(scope.snapshots || {})) {
    if (!same(old, snapshot(claimRoot, file, budget))) auditFail('a claimed file changed while the audit ran');
  }
  if (!same(scope.logPrefix, logPrefix(scope.log))) auditFail('the run log changed while the audit ran');
  const wired = Number(bareWired || 0);
  if (!Number.isSafeInteger(wired) || wired < 0) auditFail('the count of WIRED entries without a files: list is not a count');
  const result = {
    ...scope,
    claims: scope.claims.map((claim, index) => ({ ...claim, certified: landed.has(index + 1) })),
    bareWired: wired,
    tree: measuredTree(claimRoot),
  };
  return persistedScope(result);
}

function gradedBareWired(scope) {
  return Number.isSafeInteger(scope.bareWired) && scope.bareWired >= 0 ? scope.bareWired : 0;
}

function failedReceipt(file) {
  const loaded = readBoundedJson(file, MAX_RECEIPT_BYTES);
  if (loaded.absent || loaded.invalid || !loaded.value || typeof loaded.value !== 'object' || Array.isArray(loaded.value)) {
    auditFail('the earlier receipt could not be read, so its audit scope could not be preserved');
  }
  return { ...loaded.value, clean: false, auditFailure: GIT_FAILURE };
}

function receiptFresh(options) {
  const loaded = readBoundedJson(options.receiptPath, MAX_RECEIPT_BYTES);
  if (loaded.absent) auditFail('no edit-landing receipt exists for this session; run the audit');
  if (loaded.invalid) auditFail(`the edit-landing receipt is ${loaded.invalid}`);
  const receipt = loaded.value;
  if (!receipt || typeof receipt !== 'object' || !Object.prototype.hasOwnProperty.call(RECEIPT_SCHEMAS, receipt.schema)) {
    auditFail('the edit-landing receipt carries no known schema');
  }
  const scope = receipt.auditScope;
  if (!scope || typeof scope !== 'object' || scope.schema !== SCOPE_SCHEMA) {
    auditFail(receipt.auditFailure ? 'the latest audit did not complete; re-run it'
      : 'the receipt carries no audit scope; re-run the audit so the terminus can check it against the current tree');
  }
  const root = realDirectory(options.projectRoot, 'the project root');
  if (scope.root !== root) auditFail('the receipt belongs to another project root');
  if (scope.sessionKey !== sessionKeyOf(options.session)) auditFail('the receipt belongs to another session');
  if (receipt.auditFailure) {
    if (options.requireClean !== false) auditFail('the latest audit did not complete; re-run it');
    return receipt;
  }
  const resolved = resolveRunLog(root, receipt.log);
  if (resolved.reason) auditFail(`the receipt's run log is not usable: ${resolved.reason}`);
  if (path.join(root, ...resolved.logRel.split('/')) !== scope.log) auditFail('the receipt names another run log than its audit scope');
  logPrefix(scope.log, scope.logPrefix);
  if (typeof options.manifest !== 'string' || options.manifest === '') auditFail('the current claim manifest is required');
  const now = parseManifest(options.manifest);
  const audited = Array.isArray(scope.claims) ? scope.claims : [];
  if (now.length !== audited.length || now.some((claim, index) => claim.step !== audited[index].step || claim.raw !== audited[index].raw)) {
    auditFail('the run log holds edit claims the receipt has not graded; re-run the audit');
  }
  if (Number(options.bareWired || 0) !== gradedBareWired(scope)) {
    auditFail('the run log holds a WIRED entry with no files: list that the receipt has not graded; re-run the audit');
  }
  if (options.requireClean !== false && (receipt.clean !== true || !Number.isSafeInteger(receipt.claims) || receipt.claims < 1
      || receipt.landed !== receipt.claims || UNRESOLVED_COUNTERS.some((field) => receipt[field] !== 0))) {
    auditFail('the receipt is not clean; resolve its pending, unverified or unlanded claims');
  }
  const claimRoot = scope.claimRoot || scope.root;
  if (currentClaimRoot(root) !== claimRoot) auditFail('the audited repository root changed after the receipt; re-run the audit');
  const budget = { remaining: LIMITS.snapshotBytes };
  for (const [file, old] of Object.entries(scope.snapshots || {})) {
    if (!same(old, snapshot(claimRoot, file, budget))) auditFail('a claimed file changed after the receipt; re-run the audit with current predicate proofs');
  }
  if (!scope.tree || !same(scope.tree, measuredTree(claimRoot))) auditFail('the working tree changed after the receipt; re-run the audit');
  return receipt;
}

const shellQuote = (value) => (/^[A-Za-z0-9_\/.,:=@%+-]+$/.test(String(value)) ? String(value) : `'${String(value).replace(/'/g, "'\\''")}'`);
const UNSAFE_OPERAND = /[\x00-\x1f\x7f]/;

function auditRecoveryCommand({ helper, projectRoot, sessionKey, log }) {
  const operand = (value, placeholder) => (typeof value === 'string' && value !== '' && !UNSAFE_OPERAND.test(value) ? value : placeholder);
  return ['bash', operand(helper, 'zensu-edit-landing.sh'), '--log', operand(log, '<run log>'),
    '--project', operand(projectRoot, '<project root>'), '--session', operand(sessionKey, '<session key>')].map(shellQuote).join(' ');
}

function boundLog(root, sessionKey, fallback) {
  const bound = receiptRunLog({ receiptPath: receiptFile(root, sessionKey), projectRoot: root });
  if (bound.status === 'ok') return path.join(root, ...bound.logRel.split('/'));
  return fallback ? canonical(path.resolve(fallback)) : '';
}

function sessionGate(options) {
  const ambient = options.ambientSession;
  if (!ambient) return { mode: 'standalone' };
  const root = realDirectory(options.projectRoot, 'the project root');
  const state = workflowState(root, ambient);
  if (state.status === 'absent' || state.status === 'none') return { mode: 'standalone' };
  if (state.status === 'ok' && !state.active) return { mode: 'standalone' };
  const key = sessionKeyOf(ambient);
  const command = auditRecoveryCommand({ helper: options.helper, projectRoot: root, sessionKey: key, log: boundLog(root, key, options.log) });
  if (state.status === 'invalid') {
    return { mode: 'refuse', reason: `the workflow state of this Claude session (${key}) cannot be trusted: ${state.reason}`, command };
  }
  return { mode: 'refuse', reason: 'an active workflow requires the explicit --session operand', command };
}

function writeScopeFlags(dir, scope) {
  fs.writeFileSync(path.join(dir, 'baseline'), scope.baseline || '');
  fs.writeFileSync(path.join(dir, 'epoch'), scope.epoch || '');
  for (const field of ['dirty', 'certified', 'proved']) {
    const values = scope[field] || [];
    fs.writeFileSync(path.join(dir, field), values.length ? `${values.join('\n')}\n` : '');
  }
}

function writeScopeState(dir, scope) {
  if (typeof dir !== 'string' || dir === '') auditFail('the scope directory is missing');
  const encoded = JSON.stringify(scope);
  if (Buffer.byteLength(encoded) > LIMITS.scopeBytes * 4) {
    auditFail(`the audit scope exceeds its ${LIMITS.scopeBytes * 4}-byte working limit; claim fewer files in this generation, or ${NEW_GENERATION}`);
  }
  fs.writeFileSync(path.join(dir, 'scope.json'), encoded);
  writeScopeFlags(dir, scope);
}

function readScopeState(dir) {
  if (typeof dir !== 'string' || dir === '') auditFail('the scope directory is missing');
  return JSON.parse(boundedFile(path.join(dir, 'scope.json'), LIMITS.scopeBytes * 4).toString('utf8'));
}

function freshVerb(env, stdout, stderr) {
  const requireClean = env.ZENSU_ELR_ALLOW_UNCLEAN !== '1';
  let receipt;
  try {
    receipt = receiptFresh({
      receiptPath: env.ZENSU_ELR_RECEIPT,
      projectRoot: env.ZENSU_ELR_PROJECT_ROOT,
      session: env.ZENSU_ELR_SESSION,
      manifest: env.ZENSU_ELR_MANIFEST || '',
      bareWired: env.ZENSU_ELR_BARE_WIRED || 0,
      requireClean,
    });
  } catch (error) {
    if (!(error instanceof AuditScopeError)) throw error;
    let command = '';
    try {
      const root = realDirectory(env.ZENSU_ELR_PROJECT_ROOT, 'the project root');
      const key = sessionKeyOf(env.ZENSU_ELR_SESSION);
      command = auditRecoveryCommand({ helper: env.ZENSU_ELR_HELPER || path.join(__dirname, 'zensu-edit-landing.sh'),
        projectRoot: root, sessionKey: key, log: boundLog(root, key, '') });
    } catch { }
    stderr.write(`EDIT LANDING RECEIPT STALE — ${error.message}.\n`);
    if (command) stderr.write(`Run: ${command}\n${RECOVERY_GUIDANCE}\n`);
    return 1;
  }
  if (!requireClean && receipt.auditFailure) {
    stdout.write('EDIT LANDING RECEIPT INCOMPLETE — the latest audit of this session did not complete; the receipt records clean=false and is carried as incomplete.\n');
    return EXIT.ok;
  }
  const unverified = treeUnverifiedReason(receipt);
  const described = unverified === null ? 'the run log, the claimed files and the working tree' : 'the run log and the claimed files';
  if (unverified !== null) stderr.write(`${treeUnverifiedLine(unverified)}\n`);
  if (!requireClean) {
    stdout.write(`EDIT LANDING RECEIPT CURRENT — the receipt still describes ${described}; it records clean=${receipt.clean === true}.\n`);
    return EXIT.ok;
  }
  stdout.write(`EDIT LANDING RECEIPT FRESH — the receipt is clean and still describes ${described}.\n`);
  return EXIT.ok;
}

function treeUnverifiedReason(receipt) {
  const tree = receipt && receipt.auditScope && receipt.auditScope.tree;
  if (!tree || tree.kind !== 'git' || tree.tree !== null) return null;
  return typeof tree.reason === 'string' && tree.reason !== '' ? tree.reason : 'the tree could not be fingerprinted';
}

function treeUnverifiedLine(reason) {
  return `TREE UNVERIFIED — ${reason}; the receipt binds the run log and the claimed files, not the rest of the working tree.`;
}

function main(argv, env = process.env, stdout = process.stdout, stderr = process.stderr) {
  const verb = argv[0];
  try {
    if (verb === 'receipt-log') {
      const receipt = receiptRunLog({ receiptPath: env.ZENSU_ELR_RECEIPT || '', projectRoot: env.ZENSU_ELR_PROJECT_ROOT || '' });
      if (receipt.status !== 'ok') return EXIT.none;
      stdout.write(receipt.logRel);
      return EXIT.ok;
    }
    if (verb === 'receipt-claims') {
      const loaded = readBoundedJson(env.ZENSU_ELR_RECEIPT || '', MAX_RECEIPT_BYTES);
      const receipt = loaded.value;
      if (!receipt || typeof receipt !== 'object' || !Object.prototype.hasOwnProperty.call(RECEIPT_SCHEMAS, receipt.schema)
          || !Number.isSafeInteger(receipt.claims) || receipt.claims < 0) return EXIT.none;
      stdout.write(String(receipt.claims));
      return EXIT.ok;
    }
    if (verb === 'tree-note') {
      const loaded = readBoundedJson(env.ZENSU_ELR_RECEIPT || '', MAX_RECEIPT_BYTES);
      if (!loaded.value || typeof loaded.value !== 'object') return EXIT.none;
      const reason = treeUnverifiedReason(loaded.value);
      if (reason !== null) stdout.write(`${treeUnverifiedLine(reason)}\n`);
      return EXIT.ok;
    }
    if (verb === 'session-gate') {
      const verdict = sessionGate({ ambientSession: env.ZEL_AMBIENT_SESSION || '', projectRoot: env.ZEL_ROOT || '',
        log: env.ZEL_LOG || '', helper: env.ZEL_HELPER || '' });
      if (verdict.mode === 'standalone') return EXIT.ok;
      stderr.write(`AUDIT SESSION REQUIRED — ${verdict.reason}; no claim was graded and no receipt was written.\n`);
      stderr.write(`Run: ${verdict.command}\n${RECOVERY_GUIDANCE}\n`);
      return EXIT.usage;
    }
    if (verb === 'scope-prepare') {
      const scope = prepareScope({
        root: env.ZEL_ROOT,
        claimRoot: env.ZEL_CLAIM_ROOT,
        log: env.ZEL_LOG,
        session: env.ZEL_SESSION || '',
        receipt: env.ZEL_SCOPE_SOURCE || '',
        baseline: env.ZEL_BASELINE_SEEN === '1' ? (env.ZEL_BASELINE || '') : undefined,
        epoch: env.ZEL_EPOCH_SEEN === '1' ? (env.ZEL_EPOCH || '') : undefined,
        dirty: env.ZEL_DIRTY_SEEN === '1' ? (env.ZEL_DIRTY || '') : undefined,
        gitFault: env.ZEL_GIT_FAULT === '1',
      });
      if (env.ZEL_DISCARD === '1' && env.ZEL_SESSION) {
        const state = workflowState(scope.root, env.ZEL_SESSION);
        if (state.status === 'invalid') auditFail(`this session's workflow state cannot be trusted: ${state.reason}`);
        if (state.status === 'ok' && state.active) {
          auditFail('an active workflow requires the receipt-producing audit; drop --receipt - (use --inventory for read-only inspection)');
        }
      }
      if (env.ZEL_CHECKPOINT === '1') checkpointScope(scope, env.ZEL_RECEIPT || '', env.ZEL_SESSION || '');
      writeScopeState(env.ZEL_SCOPE_DIR, scope);
      return EXIT.ok;
    }
    if (verb === 'scope-claims') {
      const dir = env.ZEL_SCOPE_DIR;
      writeScopeState(dir, prepareClaims(readScopeState(dir), env.ZEL_MANIFEST, env.ZEL_PREDICATES || ''));
      return EXIT.ok;
    }
    if (verb === 'scope-finish') {
      const dir = env.ZEL_SCOPE_DIR;
      stdout.write(JSON.stringify(finishScope(readScopeState(dir), path.join(dir, 'landed'), env.ZEL_BARE_WIRED)));
      return EXIT.ok;
    }
    if (verb === 'failed') {
      stdout.write(`${JSON.stringify(failedReceipt(env.ZENSU_ELR_RECEIPT))}\n`);
      return EXIT.ok;
    }
    if (verb === 'fresh') return freshVerb(env, stdout, stderr);
    stderr.write('usage: edit-landing-receipt-v1.js receipt-log|receipt-claims|tree-note|session-gate|scope-prepare|scope-claims|scope-finish|failed|fresh\n');
    return EXIT.usage;
  } catch (error) {
    const message = error instanceof AuditScopeError ? error.message : `unexpected audit failure (${error && error.message ? error.message : error})`;
    stderr.write(`edit-landing audit: ${message}\n`);
    return EXIT.usage;
  }
}

module.exports = {
  RECEIPT_SCHEMAS,
  MAX_RECEIPT_BYTES,
  LIMITS,
  NEW_GENERATION,
  RECEIPT_NAME_RE,
  EXIT,
  SCOPE_SCHEMA,
  PREDICATE_SCHEMA,
  AuditScopeError,
  receiptFile,
  logPrefix,
  treeUnverifiedReason,
  treeUnverifiedLine,
  readBoundedJson,
  canonical,
  isOutside,
  resolveRunLog,
  receiptRunLog,
  relativeFile,
  snapshot,
  workflowState,
  prepareScope,
  checkpointScope,
  prepareClaims,
  verifyPredicates,
  finishScope,
  failedReceipt,
  receiptFresh,
  auditRecoveryCommand,
  sessionGate,
  main,
};

if (require.main === module) {
  process.exitCode = main(process.argv.slice(2));
}
