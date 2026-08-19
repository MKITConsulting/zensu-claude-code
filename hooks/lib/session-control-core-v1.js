'use strict';

const crypto = require('node:crypto');
const childProcess = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const SCHEMA = 'zensu.session-control';
const SCHEMA_VERSION = 1;
const WORKFLOW_SCHEMA = 'zensu.workflow-state';
const ATTESTATION_SCHEMA = 'zensu.control-attestation';
const HASH_DOMAIN = Buffer.from('zensu.session-control/v1/session-id\0', 'utf8');
const RUNTIME_DOMAIN = Buffer.from('zensu.session-control/v1/runtime-digest\0', 'utf8');
const DARWIN_PROCESS_START_DOMAIN = Buffer.from('zensu.process-start/darwin-v1\0', 'utf8');
const EXTERNAL_PROCESS_LOCK_DOMAIN = Buffer.from('zensu.external-process-lock/v1\0', 'utf8');
const SESSION_KEY_RE = /^scv1_([a-f0-9]{64})$/;
const HASH_RE = /^sha256:([a-f0-9]{64})$/;
const HOSTS = new Set(['codex', 'claude']);
const MAX_RUNTIME_FILES = 10000;
const MAX_RUNTIME_FILE_BYTES = 4 * 1024 * 1024;
const MAX_RUNTIME_TOTAL_BYTES = 64 * 1024 * 1024;
const MAX_JSON_BYTES = 1024 * 1024;
const LOCK_STALE_MS = 30000;
const EXTERNAL_LOCK_POLL_MS = 50;
const EXTERNAL_LOCK_DEFAULT_ATTEMPTS = 200;
const LOCK_TOKEN_RE = /^[a-f0-9]{48}$/;
const LOCK_IDENTITY_RE = /^[a-z0-9._:-]{1,160}$/;
const TRANSIENT_LOCK_SNAPSHOT_ERROR_RE = /^session-control-v1: (?:file identity changed while opening|file (?:path )?changed while reading|missing file): /;
const DARWIN_PROCESS_START_RE = /^(Sun|Mon|Tue|Wed|Thu|Fri|Sat) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) ([1-9]|[12][0-9]|3[01]) ([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9] [0-9]{4}$/;
const WORKFLOW_RESERVED_FIELDS = new Set([
  'schema',
  'schema_version',
  'session_id',
  'session_id_hash',
  'workflow_state',
  'revision',
  'last_event',
  'updated_at',
  'actor',
]);

function fail(message) {
  throw new Error(`session-control-v1: ${message}`);
}

function requireText(value, label) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} must be a non-empty string`);
  }
  return value;
}

function requireHost(host) {
  requireText(host, 'host');
  if (!HOSTS.has(host)) {
    fail(`unsupported host "${host}"`);
  }
  return host;
}

function sessionIdHash(sessionId) {
  const value = requireText(sessionId, 'session id');
  const keyMatch = SESSION_KEY_RE.exec(value);
  if (keyMatch) {
    return `sha256:${keyMatch[1]}`;
  }
  const hashMatch = HASH_RE.exec(value);
  if (hashMatch) {
    return value;
  }
  const digest = crypto.createHash('sha256').update(HASH_DOMAIN).update(value, 'utf8').digest('hex');
  return `sha256:${digest}`;
}

function sessionKey(sessionId) {
  const value = requireText(sessionId, 'session id');
  const keyMatch = SESSION_KEY_RE.exec(value);
  if (keyMatch) {
    return value;
  }
  return `scv1_${sessionIdHash(value).slice('sha256:'.length)}`;
}

function canonicalDirectory(input, label) {
  const value = requireText(input, label);
  if (/[\0\r\n]/.test(value)) {
    fail(`${label} is unsafe`);
  }
  let canonical;
  try {
    canonical = fs.realpathSync.native(value);
  } catch {
    fail(`${label} does not exist`);
  }
  const stat = fs.lstatSync(canonical);
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    fail(`${label} must be a real directory`);
  }
  return canonical;
}

function isInside(base, candidate) {
  const relative = path.relative(base, candidate);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function ensureDescendantDirectory(baseInput, targetInput) {
  const base = canonicalDirectory(baseInput, 'directory base');
  const requestedBase = path.resolve(baseInput);
  const requestedTarget = path.resolve(targetInput);
  const target = isInside(requestedBase, requestedTarget)
    ? path.join(base, path.relative(requestedBase, requestedTarget))
    : requestedTarget;
  if (!isInside(base, target)) {
    fail('directory target escapes its trusted base');
  }
  const relative = path.relative(base, target);
  let current = base;
  if (relative === '') {
    return current;
  }
  for (const part of relative.split(path.sep)) {
    current = path.join(current, part);
    if (!fs.existsSync(current)) {
      try {
        fs.mkdirSync(current, { mode: 0o700 });
      } catch (error) {
        if (error.code !== 'EEXIST') throw error;
      }
    }
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink()) {
      fail(`symlink directory rejected: ${current}`);
    }
    if (!stat.isDirectory()) {
      fail(`expected directory: ${current}`);
    }
  }
  return current;
}

function sameFileIdentity(left, right) {
  if (!left || !right) return false;
  const inodeKnown = left.ino !== 0 && right.ino !== 0;
  if (inodeKnown) return left.dev === right.dev && left.ino === right.ino;
  return left.birthtimeMs === right.birthtimeMs && left.mode === right.mode;
}

function readRegularFileSnapshot(
  file,
  maxBytes = MAX_JSON_BYTES,
  missingAllowed = false,
  allowMultipleLinks = false,
) {
  const noFollow = process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW)
    ? fs.constants.O_NOFOLLOW : 0;
  let descriptor;
  let pathBefore = null;
  const parent = path.dirname(file);
  const parentBefore = fs.lstatSync(parent);
  if (parentBefore.isSymbolicLink() || !parentBefore.isDirectory()) {
    fail(`unsafe parent directory: ${parent}`);
  }
  try {
    // O_NOFOLLOW is not available on every Windows Node build. In that case,
    // bracket open() with lstat/fstat identity checks instead of trusting the
    // path lookup performed before the descriptor exists.
    if (noFollow === 0) {
      try {
        pathBefore = fs.lstatSync(file);
      } catch (error) {
        if (missingAllowed && error.code === 'ENOENT') return null;
        if (error.code === 'ENOENT') fail(`missing file: ${file}`);
        throw error;
      }
      if (pathBefore.isSymbolicLink()) fail(`symlink file rejected: ${file}`);
    }
    try {
      descriptor = fs.openSync(file, fs.constants.O_RDONLY | noFollow);
    } catch (error) {
      if (missingAllowed && error.code === 'ENOENT') return null;
      if (error.code === 'ELOOP' || error.code === 'EMLINK') {
        fail(`symlink file rejected: ${file}`);
      }
      if (error.code === 'ENOENT') fail(`missing file: ${file}`);
      throw error;
    }

    const before = fs.fstatSync(descriptor);
    if (!before.isFile()) fail(`not a regular file: ${file}`);
    if (!allowMultipleLinks && before.nlink > 1) fail(`multi-linked file rejected: ${file}`);
    if (before.size > maxBytes) fail(`file exceeds size limit: ${file}`);
    if (pathBefore && !sameFileIdentity(pathBefore, before)) {
      fail(`file identity changed while opening: ${file}`);
    }

    const data = Buffer.alloc(before.size);
    let offset = 0;
    while (offset < data.length) {
      const read = fs.readSync(descriptor, data, offset, data.length - offset, null);
      if (read === 0) fail(`file changed while reading: ${file}`);
      offset += read;
    }

    const after = fs.fstatSync(descriptor);
    if (
      !sameFileIdentity(before, after)
      || before.size !== after.size
      || before.mtimeMs !== after.mtimeMs
      || before.ctimeMs !== after.ctimeMs
    ) {
      fail(`file changed while reading: ${file}`);
    }
    let pathAfter;
    try {
      pathAfter = fs.lstatSync(file);
    } catch (error) {
      if (error.code === 'ENOENT') fail(`file path changed while reading: ${file}`);
      throw error;
    }
    if (pathAfter.isSymbolicLink() || !sameFileIdentity(after, pathAfter)) {
      fail(`file path changed while reading: ${file}`);
    }
    const parentAfter = fs.lstatSync(parent);
    if (
      parentAfter.isSymbolicLink()
      || !parentAfter.isDirectory()
      || !sameFileIdentity(parentBefore, parentAfter)
    ) {
      fail(`parent directory changed while reading: ${file}`);
    }
    return { data, stat: after };
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
}

function readRegularFile(file, maxBytes = MAX_JSON_BYTES) {
  return readRegularFileSnapshot(file, maxBytes).data;
}

function readJson(file) {
  const data = readRegularFile(file);
  try {
    return JSON.parse(data.toString('utf8'));
  } catch {
    fail(`invalid JSON: ${file}`);
  }
}

function manifestPath(pluginRoot, host) {
  const manifestDirectory = requireHost(host) === 'codex' ? '.codex-plugin' : '.claude-plugin';
  return path.join(pluginRoot, manifestDirectory, 'plugin.json');
}

function pluginMetadata(pluginRootInput, host) {
  const pluginRoot = canonicalDirectory(pluginRootInput, 'plugin root');
  const file = manifestPath(pluginRoot, host);
  if (!fs.existsSync(file)) {
    fail(`host-specific plugin manifest is missing: ${file}`);
  }
  const manifest = readJson(file);
  if (manifest.name !== 'zensu') {
    fail('plugin manifest must identify zensu');
  }
  requireText(manifest.version, 'plugin version');
  return { pluginRoot, manifest, manifestFile: file };
}

// A record minted by an EARLIER installation of this same plugin may still be
// served by the running one when the two declare a compatible lineage. That is
// the ordinary consequence of a plugin update landing while a session is live:
// the record stays valid in every respect and only the version directory it
// names is no longer the executing one. Before this predicate existed such a
// session denied every tool for the rest of its life, including the read-only
// diagnostic that reports the state.
//
// The axis is semver with the one clause the specification leaves to the
// publisher: while major is 0 the MINOR number is the breaking axis, so 0.17.1
// and 0.17.2 share a lineage and 0.17.x and 0.18.0 do not. Without that clause
// "same major" would make 0.9.2 compatible with 0.17.2. A downgrade is never
// compatible — only the newer tree can be expected to understand the older
// one's state, never the reverse — so the executing version must be at least
// the recorded one. `CLAUDE.md` "Runtime Lineage" states which changes force
// the breaking bump; this function cannot verify that policy was followed, it
// only encodes what the version numbers then mean.
//
// Components are bounded at nine digits so the numeric comparison below stays
// exact. An unbounded run would let two distinct spellings above 2^53 collapse
// to one Number and tie, which the loop reads as compatible — accepting a
// downgrade. No real manifest reaches that magnitude; the bound is here because
// the predicate is exported cross-host and its input is a file on disk.
const RUNTIME_VERSION_RE = /^(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})$/;

function parseRuntimeVersion(value) {
  if (typeof value !== 'string') return null;
  const match = RUNTIME_VERSION_RE.exec(value);
  return match === null ? null : [Number(match[1]), Number(match[2]), Number(match[3])];
}

function runtimeLineageCompatible(recordedVersion, executingVersion) {
  const recorded = parseRuntimeVersion(recordedVersion);
  const executing = parseRuntimeVersion(executingVersion);
  if (recorded === null || executing === null) return false;
  if (recorded[0] !== executing[0]) return false;
  if (recorded[0] === 0 && recorded[1] !== executing[1]) return false;
  for (let index = 0; index < recorded.length; index += 1) {
    if (executing[index] !== recorded[index]) return executing[index] > recorded[index];
  }
  return true;
}

// The single identity a compatible upgrade may change is the version DIRECTORY.
// Three conditions, all required, and none of them waives an integrity check:
//
//   - The two roots are siblings under one parent. Every marketplace install of
//     the same plugin lands beside the versions it replaces, while a working
//     checkout loaded through a development flag lives in a repository and is
//     never a sibling of a cache entry — so it cannot adopt an installed
//     session's record no matter which version its manifest declares. That
//     bound is structural rather than a claim about any host's environment.
//   - The executing manifest parses and shares the recorded lineage.
//   - The RECORDED runtime is still measured exactly as before: readContext
//     computes the digest against the recorded root and requires that root's
//     manifest to still declare the recorded version. This predicate decides
//     only WHICH runtime may serve a record, never whether the record is sound.
//
// The cost is stated plainly in `docs/session-control.md`: the pin weakens from
// "the measured code is the enforcing code" to "the enforcing code shares a
// declared-compatible lineage with the measured code".
//
// It is the site-level decision every root comparison shares, so the five call
// sites hold ONE implementation between them instead of five hand-copies.
//
// This is a PREDICATE and never throws. An executing root with no readable
// zensu manifest is not a lineage claim — it is a root that cannot be
// identified at all — so it answers false and each call site denies with its
// OWN message. Letting pluginMetadata's exception escape instead would replace
// every site's deny reason with a manifest error and force all five to wrap the
// call; the verdict would be the same, the diagnosis would not. The shape guards
// make "never throws" true for ANY input, not just a validated context: this
// seam is exported cross-host, so a port may hand it an object it assembled
// itself, in a path where an exception is not the documented outcome.
function servesRecordedRuntime(context, executedPluginRoot, host) {
  if (!context || typeof context !== 'object' || Array.isArray(context)) return false;
  if (typeof context.plugin_root !== 'string') return false;
  if (context.plugin_root === executedPluginRoot) return true;
  if (typeof executedPluginRoot !== 'string') return false;
  if (path.dirname(context.plugin_root) !== path.dirname(executedPluginRoot)) return false;
  let executingVersion;
  try {
    executingVersion = pluginMetadata(executedPluginRoot, host).manifest.version;
  } catch {
    return false;
  }
  return runtimeLineageCompatible(context.plugin_version, executingVersion);
}

// The version a root DECLARES, or null when it declares nothing readable. It
// exists so a caller that has already been refused by servesRecordedRuntime can
// NAME the two versions instead of reporting an anonymous disagreement — the
// whole difference between "start a fresh session" and "0.17.2 recorded, 0.18.0
// executing".
//
// TOTAL and never throws, for the same reason servesRecordedRuntime is a
// predicate: every caller is already on a failure path, and an exception there
// would replace a precise diagnosis with a manifest error. A null answer means
// the root could not be identified at all, which callers report as such rather
// than guessing a number.
function executingPluginVersion(pluginRootInput, host) {
  try {
    return pluginMetadata(pluginRootInput, host).manifest.version;
  } catch {
    return null;
  }
}

function localManifestEntry(pluginRoot, value, label) {
  const raw = requireText(value, label)
    .replace(/^\$\{(?:CLAUDE_|CODEX_)?PLUGIN_ROOT\}/, pluginRoot);
  const candidate = path.isAbsolute(raw) ? path.resolve(raw) : path.resolve(pluginRoot, raw);
  if (!isInside(pluginRoot, candidate)) {
    fail(`${label} escapes plugin root`);
  }
  if (!fs.existsSync(candidate)) {
    fail(`${label} is missing: ${candidate}`);
  }
  return candidate;
}

function manifestRuntimeEntries(pluginRoot, host, manifest) {
  const entries = new Set([manifestPath(pluginRoot, host)]);
  for (const directory of ['hooks', 'agents', 'skills', 'docs', 'templates']) {
    const candidate = path.join(pluginRoot, directory);
    if (fs.existsSync(candidate)) {
      entries.add(candidate);
    }
  }
  for (const file of ['README.md', 'CHANGELOG.md', 'LICENSE']) {
    const candidate = path.join(pluginRoot, file);
    if (fs.existsSync(candidate)) entries.add(candidate);
  }

  const addReferences = (value, label) => {
    if (typeof value === 'string') {
      entries.add(localManifestEntry(pluginRoot, value, label));
      return;
    }
    if (Array.isArray(value)) {
      value.forEach((entry, index) => addReferences(entry, `${label}[${index}]`));
    }
  };
  for (const field of ['hooks', 'agents', 'skills', 'mcpServers']) {
    if (manifest[field] !== undefined) {
      addReferences(manifest[field], `plugin manifest ${field}`);
    }
  }

  // MCP manifests activate executable plugin runtime outside hooks/agents/skills.
  // Include the launcher scripts and their lockfile-backed metadata so an active
  // session detects changes to every byte that can affect the launched server.
  if (manifest.mcpServers !== undefined) {
    for (const relative of ['scripts', 'mcp-runtime/package.json', 'mcp-runtime/package-lock.json']) {
      const candidate = path.join(pluginRoot, relative);
      if (fs.existsSync(candidate)) entries.add(candidate);
    }
  }
  return [...entries];
}

function collectRuntimeFiles(pluginRoot, host, manifest) {
  const entries = manifestRuntimeEntries(pluginRoot, host, manifest);

  const files = new Map();
  const visit = (candidate) => {
    const stat = fs.lstatSync(candidate);
    if (stat.isSymbolicLink()) {
      fail(`runtime symlink rejected: ${candidate}`);
    }
    if (stat.isFile()) {
      if (stat.size > MAX_RUNTIME_FILE_BYTES) {
        fail(`runtime file exceeds size limit: ${candidate}`);
      }
      const relative = path.relative(pluginRoot, candidate).split(path.sep).join('/');
      files.set(relative, { file: candidate, size: stat.size });
      if (files.size > MAX_RUNTIME_FILES) {
        fail('runtime file count exceeds limit');
      }
      return;
    }
    if (!stat.isDirectory()) {
      fail(`unsupported runtime entry: ${candidate}`);
    }
    const children = fs.readdirSync(candidate).sort();
    for (const child of children) {
      visit(path.join(candidate, child));
    }
  };

  for (const entry of entries) {
    visit(entry);
  }
  return [...files.values()].sort((left, right) => {
    const a = path.relative(pluginRoot, left.file).split(path.sep).join('/');
    const b = path.relative(pluginRoot, right.file).split(path.sep).join('/');
    return a.localeCompare(b);
  });
}

function computeRuntimeDigest(pluginRootInput, hostInput) {
  const host = requireHost(hostInput);
  const { pluginRoot, manifest } = pluginMetadata(pluginRootInput, host);
  const files = collectRuntimeFiles(pluginRoot, host, manifest);
  const digest = crypto.createHash('sha256').update(RUNTIME_DOMAIN);
  let totalBytes = 0;
  for (const entry of files) {
    totalBytes += entry.size;
    if (totalBytes > MAX_RUNTIME_TOTAL_BYTES) {
      fail('runtime assets exceed total size limit');
    }
    const relative = path.relative(pluginRoot, entry.file).split(path.sep).join('/');
    const content = readRegularFile(entry.file, MAX_RUNTIME_FILE_BYTES);
    if (content.length !== entry.size) {
      fail(`runtime file changed during digest: ${entry.file}`);
    }
    digest.update(String(Buffer.byteLength(relative)), 'utf8');
    digest.update('\0');
    digest.update(relative, 'utf8');
    digest.update('\0');
    digest.update(String(content.length), 'utf8');
    digest.update('\0');
    digest.update(content);
    digest.update('\0');
  }
  return `sha256:${digest.digest('hex')}`;
}

function nowIso() {
  return new Date().toISOString();
}

function buildContext(options) {
  const host = requireHost(options.host);
  const projectRoot = canonicalDirectory(options.projectRoot, 'project root');
  const { pluginRoot, manifest } = pluginMetadata(options.pluginRoot, host);
  const pluginData = canonicalDirectory(options.pluginData, 'plugin data');
  const createdAt = options.createdAt || nowIso();
  if (!Number.isFinite(Date.parse(createdAt))) {
    fail('createdAt must be an ISO-compatible timestamp');
  }
  if (Object.prototype.hasOwnProperty.call(options, 'sourceRevision')
      || Object.prototype.hasOwnProperty.call(options, 'sourceRevisionAuthority')) {
    fail('source revision overrides are unsupported; source_revision is the runtime content digest');
  }
  // Compute the runtime identity exactly once. Session provenance is always
  // content-addressed; Git identity belongs only in wrapper-owned evidence.
  const runtimeDigest = computeRuntimeDigest(pluginRoot, host);

  return {
    schema: SCHEMA,
    schema_version: SCHEMA_VERSION,
    host,
    session_id_hash: sessionIdHash(options.sessionId),
    project_root: projectRoot,
    plugin_root: pluginRoot,
    plugin_data: pluginData,
    plugin_version: manifest.version,
    source_revision: runtimeDigest,
    runtime_digest: runtimeDigest,
    created_at: createdAt,
    principal_profiles: {
      main: 'main-v1',
      reviewer: 'reviewer-readonly-v1',
      evidence_worker: 'evidence-worker-v1',
      host: 'host-profile-v1',
    },
  };
}

// `options.allowMissingProjectRoot` waives ONE check and nothing else: whether
// the recorded project root still exists on disk. It defaults to off, so every
// caller that does not opt in keeps the strict behaviour. The only opt-in
// caller is readOrphanedProjectRootContext, which separately PROVES the path is
// absent — waiving the check does not mean the field is unvalidated, because
// the requireText loop below still rejects a missing, blank, or unsafe value.
function validateContext(context, expectedHost, options) {
  const allowMissingProjectRoot = Boolean(options && options.allowMissingProjectRoot);
  if (!context || typeof context !== 'object' || Array.isArray(context)) {
    fail('context record must be an object');
  }
  if (context.schema !== SCHEMA || context.schema_version !== SCHEMA_VERSION) {
    fail('context schema mismatch');
  }
  requireHost(context.host);
  if (expectedHost && context.host !== expectedHost) {
    fail('context host mismatch');
  }
  if (!HASH_RE.test(context.session_id_hash || '')) {
    fail('context session hash is invalid');
  }
  if (
    !context.principal_profiles
    || context.principal_profiles.main !== 'main-v1'
    || context.principal_profiles.reviewer !== 'reviewer-readonly-v1'
    || context.principal_profiles.evidence_worker !== 'evidence-worker-v1'
    || context.principal_profiles.host !== 'host-profile-v1'
  ) {
    fail('context principal profiles are invalid');
  }
  for (const field of ['project_root', 'plugin_root', 'plugin_data', 'plugin_version', 'runtime_digest', 'created_at', 'source_revision']) {
    requireText(context[field], `context ${field}`);
  }
  if (!allowMissingProjectRoot) {
    canonicalDirectory(context.project_root, 'context project root');
  }
  canonicalDirectory(context.plugin_root, 'context plugin root');
  canonicalDirectory(context.plugin_data, 'context plugin data');
  if (!HASH_RE.test(context.runtime_digest)) {
    fail('context runtime digest is invalid');
  }
  if (!HASH_RE.test(context.source_revision) || context.source_revision !== context.runtime_digest) {
    fail('context source revision must equal its runtime content digest');
  }
  return context;
}

function contextRecordFile(recordsDir, sessionId) {
  return path.join(recordsDir, `${sessionKey(sessionId)}.json`);
}

function sleep(milliseconds) {
  const buffer = new SharedArrayBuffer(4);
  Atomics.wait(new Int32Array(buffer), 0, 0, milliseconds);
}

function processStartIdentity(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return null;
  try {
    if (process.platform === 'linux') {
      const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
      const commandEnd = stat.lastIndexOf(')');
      if (commandEnd < 0) return null;
      const fields = stat.slice(commandEnd + 2).trim().split(/\s+/);
      const startTicks = fields[19];
      if (!startTicks || !/^\d+$/.test(startTicks)) return null;
      let bootId = 'unknown-boot';
      try {
        bootId = fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim();
      } catch {
        // startTicks is still stronger than PID-only ownership on Linux.
      }
      const identity = `linux:${bootId}:${startTicks}`;
      return LOCK_IDENTITY_RE.test(identity) ? identity : null;
    }
    if (process.platform === 'darwin') {
      const started = childProcess.execFileSync('/bin/ps', ['-p', String(pid), '-o', 'lstart='], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
        timeout: 1000,
        env: {
          PATH: '/usr/bin:/bin',
          LC_ALL: 'C',
          LANG: 'C',
          TZ: 'UTC',
        },
      }).trim().replace(/\s+/g, ' ');
      if (!DARWIN_PROCESS_START_RE.test(started)) return null;
      const digest = crypto.createHash('sha256')
        .update(DARWIN_PROCESS_START_DOMAIN)
        .update(started, 'utf8')
        .digest('hex');
      return `darwin:${digest}`;
    }
  } catch {
    // A platform or permission that cannot expose process start identity falls
    // back to conservative PID liveness. It never treats uncertainty as dead.
  }
  return null;
}

let ownProcessStartIdentity;
function currentProcessStartIdentity() {
  if (ownProcessStartIdentity === undefined) {
    ownProcessStartIdentity = processStartIdentity(process.pid) || null;
  }
  return ownProcessStartIdentity;
}

function lockOwner(file) {
  let snapshot = null;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      snapshot = readRegularFileSnapshot(file, 4096, true, true);
      break;
    } catch (error) {
      if (!TRANSIENT_LOCK_SNAPSHOT_ERROR_RE.test(error.message)) throw error;
      try {
        fs.lstatSync(file);
      } catch (statError) {
        if (statError.code === 'ENOENT') return null;
        throw statError;
      }
    }
  }
  if (!snapshot) {
    // Lock artifacts are intentionally short-lived. A generation that changes
    // throughout all descriptor reads is treated as contended, never stale;
    // createOwnedArtifact() still prevents entry while its path exists.
    return null;
  }
  let owner = null;
  try {
    owner = JSON.parse(snapshot.data.toString('utf8'));
  } catch {
    // Corrupt artifacts fail closed while fresh and can only be reclaimed
    // after the stale threshold using inode identity below.
  }
  if (
    !owner
    || !Number.isSafeInteger(owner.pid)
    || owner.pid <= 0
    || typeof owner.token !== 'string'
    || !LOCK_TOKEN_RE.test(owner.token)
    || (
      owner.release_token_digest !== undefined
      && (
        typeof owner.release_token_digest !== 'string'
        || !HASH_RE.test(owner.release_token_digest)
      )
    )
    || !Number.isFinite(Date.parse(owner.created_at || ''))
    || (
      owner.process_start_identity !== undefined
      && owner.process_start_identity !== null
      && (
        typeof owner.process_start_identity !== 'string'
        || !LOCK_IDENTITY_RE.test(owner.process_start_identity)
      )
    )
  ) owner = null;
  return { stat: snapshot.stat, owner };
}

function processIsAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

function sameArtifact(left, right) {
  if (!left || !right) return false;
  if (!sameFileIdentity(left.stat, right.stat)) return false;
  if (left.owner && right.owner && left.owner.token !== right.owner.token) return false;
  if (Boolean(left.owner) !== Boolean(right.owner)) return false;
  return left.stat.size === right.stat.size;
}

function removeArtifactIfSame(file, snapshot) {
  let current;
  try {
    current = lockOwner(file);
  } catch {
    return false;
  }
  if (!sameArtifact(current, snapshot)) return false;
  const quarantine = path.join(
    path.dirname(file),
    `.${path.basename(file)}.${process.pid}.${crypto.randomBytes(24).toString('hex')}.quarantine`,
  );
  try {
    fs.renameSync(file, quarantine);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    return false;
  }
  const quarantined = lockOwner(quarantine);
  if (!sameArtifact(quarantined, snapshot)) {
    // rename() may have moved a replacement that won after the first identity
    // check. Restore it with a no-clobber hard link and never delete it.
    try {
      fs.linkSync(quarantine, file);
      fs.unlinkSync(quarantine);
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      fail('lock replacement race could not be restored safely');
    }
    return false;
  }
  fs.unlinkSync(quarantine);
  return true;
}

function assertDirectoryIdentity(directory, expected, label = 'lock directory') {
  if (!expected) return;
  let actual;
  try {
    actual = fs.lstatSync(directory);
  } catch {
    fail(`${label} identity changed`);
  }
  if (actual.isSymbolicLink() || !actual.isDirectory() || !sameFileIdentity(actual, expected)) {
    fail(`${label} identity changed`);
  }
}

function createOwnedArtifact(
  file,
  kind,
  ownerOverride = null,
  expectedDirectory = null,
  tokenSink = null,
) {
  const directory = path.dirname(file);
  const token = crypto.randomBytes(24).toString('hex');
  const temporary = path.join(directory, `.${path.basename(file)}.${process.pid}.${token}.candidate`);
  const ownerPid = ownerOverride ? ownerOverride.pid : process.pid;
  const ownerIdentity = ownerOverride
    ? ownerOverride.processStartIdentity
    : currentProcessStartIdentity();
  const releaseTokenDigest = ownerOverride ? (ownerOverride.releaseTokenDigest ?? null) : null;
  if (!Number.isSafeInteger(ownerPid) || ownerPid <= 0) fail('lock owner pid is invalid');
  if (
    ownerIdentity !== null
    && (typeof ownerIdentity !== 'string' || !LOCK_IDENTITY_RE.test(ownerIdentity))
  ) {
    fail('lock owner process identity is invalid');
  }
  if (releaseTokenDigest !== null && !HASH_RE.test(releaseTokenDigest)) {
    fail('lock release capability digest is invalid');
  }
  const owner = {
    pid: ownerPid,
    token,
    kind,
    created_at: nowIso(),
    process_start_identity: ownerIdentity,
  };
  if (releaseTokenDigest !== null) owner.release_token_digest = releaseTokenDigest;
  if (tokenSink !== null && typeof tokenSink !== 'function') {
    fail('lock token sink must be a function');
  }
  let descriptor;
  let temporaryCreated = false;
  let linked = false;
  let expectedArtifact = null;
  try {
    if (tokenSink) tokenSink(token);
    assertDirectoryIdentity(directory, expectedDirectory);
    descriptor = fs.openSync(temporary, 'wx', 0o600);
    temporaryCreated = true;
    assertDirectoryIdentity(directory, expectedDirectory);
    fs.writeFileSync(descriptor, JSON.stringify(owner));
    fs.fsyncSync(descriptor);
    expectedArtifact = { stat: fs.fstatSync(descriptor), owner };
    fs.closeSync(descriptor);
    descriptor = undefined;
    assertDirectoryIdentity(directory, expectedDirectory);
    fs.linkSync(temporary, file);
    linked = true;
    assertDirectoryIdentity(directory, expectedDirectory);
    const snapshot = lockOwner(file);
    if (!snapshot || !snapshot.owner || snapshot.owner.token !== token) {
      fail('new lock identity could not be verified');
    }
    return snapshot;
  } catch (error) {
    if (linked && expectedArtifact) {
      removeArtifactIfSame(file, expectedArtifact);
    }
    if (error.code === 'EEXIST' && !linked) return null;
    throw error;
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    if (temporaryCreated) {
      try {
        fs.unlinkSync(temporary);
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
    }
  }
}

function artifactIsStale(snapshot) {
  if (!snapshot) return false;
  if (!snapshot.owner) {
    return Date.now() - snapshot.stat.mtimeMs > LOCK_STALE_MS;
  }
  if (!processIsAlive(snapshot.owner.pid)) return true;
  if (snapshot.owner.process_start_identity) {
    const actual = snapshot.owner.pid === process.pid
      ? currentProcessStartIdentity()
      : processStartIdentity(snapshot.owner.pid);
    if (actual && actual !== snapshot.owner.process_start_identity) return true;
  }
  return false;
}

function reclaimStaleArtifact(file) {
  const snapshot = lockOwner(file);
  if (!artifactIsStale(snapshot)) return false;
  return removeArtifactIfSame(file, snapshot);
}

function withRecoverySentinel(lockDirectory, key, callback, expectedDirectory = null) {
  const recoveryFile = path.join(lockDirectory, `.${key}.recovery`);
  let recovery = null;
  for (let attempt = 0; attempt < 500; attempt += 1) {
    assertDirectoryIdentity(lockDirectory, expectedDirectory);
    if (fs.existsSync(recoveryFile)) reclaimStaleArtifact(recoveryFile);
    recovery = createOwnedArtifact(recoveryFile, 'recovery', null, expectedDirectory);
    if (recovery) break;
    sleep(20);
  }
  if (!recovery) fail('timed out acquiring recovery sentinel');
  try {
    return callback();
  } finally {
    if (!removeArtifactIfSame(recoveryFile, recovery)) {
      fail('recovery sentinel ownership changed');
    }
  }
}

function recoverStaleLock(lockDirectory, key, lockFile, expectedDirectory = null) {
  return withRecoverySentinel(lockDirectory, key, () => {
    const current = lockOwner(lockFile);
    if (artifactIsStale(current) && !removeArtifactIfSame(lockFile, current)) {
      fail('stale lock identity changed during recovery');
    }
  }, expectedDirectory);
}

function releaseOwnedLock(lockDirectory, key, lockFile, acquired, expectedDirectory = null) {
  return withRecoverySentinel(lockDirectory, key, () => {
    const current = lockOwner(lockFile);
    if (!sameArtifact(current, acquired)) {
      fail('lock ownership changed before release');
    }
    if (!removeArtifactIfSame(lockFile, acquired)) {
      fail('lock identity changed during release');
    }
  }, expectedDirectory);
}

function withFileLock(lockDirectory, key, callback) {
  const directory = canonicalDirectory(lockDirectory, 'lock directory');
  if (!/^[a-zA-Z0-9._-]{1,160}$/.test(key)) fail('lock key has an invalid format');
  if (typeof callback !== 'function') fail('lock callback must be a function');
  const lockFile = path.join(directory, `.${key}.lock`);
  const recoveryFile = path.join(directory, `.${key}.recovery`);
  let acquired;
  for (let attempt = 0; attempt < 500; attempt += 1) {
    if (fs.existsSync(recoveryFile)) {
      reclaimStaleArtifact(recoveryFile);
      sleep(20);
      continue;
    }
    acquired = createOwnedArtifact(lockFile, 'lock');
    if (acquired) {
      // A recovery owner may have won immediately after our pre-check. Do not
      // enter the critical section until that generation has completed.
      if (!fs.existsSync(recoveryFile)) break;
      releaseOwnedLock(directory, key, lockFile, acquired);
      acquired = undefined;
    } else {
      recoverStaleLock(directory, key, lockFile);
    }
    sleep(20);
  }
  if (!acquired) {
    fail('timed out acquiring per-session lock');
  }
  try {
    return callback();
  } finally {
    releaseOwnedLock(directory, key, lockFile, acquired);
  }
}

function externalProcessLockBinding(options) {
  if (!options || typeof options !== 'object' || Array.isArray(options)) {
    fail('external process lock options are invalid');
  }
  const lockDirectoryInput = requireText(options.lockDirectory, 'lock directory');
  const resourceInput = requireText(options.resourcePath, 'lock resource path');
  if (!path.isAbsolute(lockDirectoryInput) || !path.isAbsolute(resourceInput)) {
    fail('external process lock paths must be absolute');
  }
  if (/[\0\r\n]/.test(lockDirectoryInput) || /[\0\r\n]/.test(resourceInput)) {
    fail('external process lock path is unsafe');
  }

  const requestedDirectory = path.resolve(lockDirectoryInput);
  const requestedResource = path.resolve(resourceInput);
  const requestedParent = path.dirname(requestedResource);
  const resourceName = path.basename(requestedResource);
  if (requestedResource === requestedParent || resourceName === '.' || resourceName === '..') {
    fail('external process lock resource must be a file path');
  }

  const directoryInputStat = fs.lstatSync(requestedDirectory);
  const parentInputStat = fs.lstatSync(requestedParent);
  if (
    directoryInputStat.isSymbolicLink()
    || !directoryInputStat.isDirectory()
    || parentInputStat.isSymbolicLink()
    || !parentInputStat.isDirectory()
  ) {
    fail('external process lock directory is unsafe');
  }

  const directory = fs.realpathSync.native(requestedDirectory);
  const resourceParent = fs.realpathSync.native(requestedParent);
  if (directory !== resourceParent) {
    fail('external process lock resource must use the lock directory');
  }
  const directoryStat = fs.lstatSync(directory);
  if (directoryStat.isSymbolicLink() || !directoryStat.isDirectory()) {
    fail('external process lock directory is unsafe');
  }

  const resourcePath = path.join(resourceParent, resourceName);
  try {
    const resourceStat = fs.lstatSync(resourcePath);
    if (resourceStat.isSymbolicLink() || !resourceStat.isFile() || resourceStat.nlink !== 1) {
      fail('external process lock resource is unsafe');
    }
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }

  const digest = crypto.createHash('sha256')
    .update(EXTERNAL_PROCESS_LOCK_DOMAIN)
    .update(resourcePath, 'utf8')
    .digest('hex');
  const key = `external-${digest}`;
  return {
    directory,
    directoryStat,
    resourcePath,
    key,
    lockFile: path.join(directory, `.${key}.lock`),
    recoveryFile: path.join(directory, `.${key}.recovery`),
  };
}

function externalProcessLockPath(options) {
  return externalProcessLockBinding(options).lockFile;
}

function externalProcessLockAttemptLimit(value) {
  if (value === undefined) return EXTERNAL_LOCK_DEFAULT_ATTEMPTS;
  if (!Number.isSafeInteger(value) || value < 1 || value > 500) {
    fail('external process lock attempt limit is invalid');
  }
  return value;
}

function externalProcessReleaseTokenDigest(token) {
  if (typeof token !== 'string' || !LOCK_TOKEN_RE.test(token)) {
    fail('external process lock token is invalid');
  }
  return `sha256:${crypto.createHash('sha256')
    .update(EXTERNAL_PROCESS_LOCK_DOMAIN)
    .update('release-capability\0', 'utf8')
    .update(token, 'utf8')
    .digest('hex')}`;
}

function constantTimeTextEqual(left, right) {
  if (typeof left !== 'string' || typeof right !== 'string') return false;
  const leftBuffer = Buffer.from(left, 'utf8');
  const rightBuffer = Buffer.from(right, 'utf8');
  return leftBuffer.length === rightBuffer.length
    && crypto.timingSafeEqual(leftBuffer, rightBuffer);
}

function requireExternalProcessOwnerAuthority(ownerPid) {
  if (!Number.isSafeInteger(ownerPid) || ownerPid <= 0) {
    fail('external process lock owner pid is invalid');
  }
  if (ownerPid !== process.pid && ownerPid !== process.ppid) {
    fail('external process lock owner authority must identify the current process or parent process');
  }
}

function externalProcessOwnerIsStable(ownerPid) {
  if (ownerPid !== process.pid && ownerPid !== process.ppid) return false;
  return processIsAlive(ownerPid);
}

function externalIdentityProbeAttempt(attempt) {
  const ordinal = (attempt + 20) / 20;
  return Number.isInteger(ordinal) && (ordinal & (ordinal - 1)) === 0;
}

function externalArtifactNeedsRecovery(snapshot, attempt) {
  if (!snapshot) return false;
  if (!snapshot.owner || !processIsAlive(snapshot.owner.pid)) {
    return artifactIsStale(snapshot);
  }
  if (!snapshot.owner.process_start_identity) return false;
  // A live PID cannot become a different process without first going dead.
  // Probe at 0, 1, 3, and 7 seconds during the bounded ten-second wait. This
  // remains conservative while avoiding a /bin/ps burst on every 50 ms poll.
  return externalIdentityProbeAttempt(attempt) && artifactIsStale(snapshot);
}

function acquireExternalProcessLock(options) {
  const binding = externalProcessLockBinding(options);
  const ownerPid = options.ownerPid;
  requireExternalProcessOwnerAuthority(ownerPid);
  if (!processIsAlive(ownerPid)) {
    fail('external process lock owner is not alive');
  }
  const attemptLimit = externalProcessLockAttemptLimit(options.attemptLimit);
  const tokenSink = options.tokenSink === undefined ? null : options.tokenSink;
  if (tokenSink !== null && typeof tokenSink !== 'function') {
    fail('external process lock token sink must be a function');
  }
  let ownerProcessStartIdentity = null;
  let releaseToken = null;
  let owner = null;
  let acquired = null;

  for (let attempt = 0; attempt < attemptLimit; attempt += 1) {
    if (!externalProcessOwnerIsStable(ownerPid)) {
      fail('external process lock owner changed before publication');
    }
    assertDirectoryIdentity(binding.directory, binding.directoryStat);
    if (fs.existsSync(binding.recoveryFile)) {
      reclaimStaleArtifact(binding.recoveryFile);
      sleep(EXTERNAL_LOCK_POLL_MS);
      continue;
    }
    if (fs.existsSync(binding.lockFile)) {
      const current = lockOwner(binding.lockFile);
      if (externalArtifactNeedsRecovery(current, attempt)) {
        recoverStaleLock(
          binding.directory,
          binding.key,
          binding.lockFile,
          binding.directoryStat,
        );
      }
      sleep(EXTERNAL_LOCK_POLL_MS);
      continue;
    }
    if (!owner) {
      ownerProcessStartIdentity = processStartIdentity(ownerPid);
      releaseToken = crypto.randomBytes(24).toString('hex');
      owner = {
        pid: ownerPid,
        processStartIdentity: ownerProcessStartIdentity,
        releaseTokenDigest: externalProcessReleaseTokenDigest(releaseToken),
      };
    }
    acquired = createOwnedArtifact(
      binding.lockFile,
      'external-process-lock',
      owner,
      binding.directoryStat,
      tokenSink ? () => tokenSink(releaseToken) : null,
    );
    if (acquired) {
      if (!fs.existsSync(binding.recoveryFile)) break;
      releaseOwnedLock(
        binding.directory,
        binding.key,
        binding.lockFile,
        acquired,
        binding.directoryStat,
      );
      acquired = null;
    }
    sleep(EXTERNAL_LOCK_POLL_MS);
  }

  if (!acquired) {
    fail('timed out acquiring external process lock');
  }
  if (!externalProcessOwnerIsStable(ownerPid)) {
    releaseOwnedLock(
      binding.directory,
      binding.key,
      binding.lockFile,
      acquired,
      binding.directoryStat,
    );
    fail('external process lock owner changed during acquisition');
  }

  return {
    token: releaseToken,
    lockFile: binding.lockFile,
    ownerPid,
    processStartIdentity: ownerProcessStartIdentity,
  };
}

function releaseExternalProcessLock(options) {
  const binding = externalProcessLockBinding(options);
  const ownerPid = options.ownerPid;
  const token = options.token;
  requireExternalProcessOwnerAuthority(ownerPid);
  if (typeof token !== 'string' || !LOCK_TOKEN_RE.test(token)) {
    fail('external process lock token is invalid');
  }

  const acquired = lockOwner(binding.lockFile);
  const tokenMatches = acquired && acquired.owner && acquired.owner.release_token_digest
    ? constantTimeTextEqual(
      acquired.owner.release_token_digest,
      externalProcessReleaseTokenDigest(token),
    )
    : Boolean(acquired && acquired.owner && acquired.owner.token === token);
  if (
    !acquired
    || !acquired.owner
    || acquired.owner.kind !== 'external-process-lock'
    || acquired.owner.pid !== ownerPid
    || !tokenMatches
  ) {
    fail('external process lock ownership does not match release token');
  }
  if (!processIsAlive(ownerPid)) {
    fail('external process lock owner is not alive at release');
  }
  if (acquired.owner.process_start_identity) {
    const actualIdentity = processStartIdentity(ownerPid);
    if (actualIdentity && actualIdentity !== acquired.owner.process_start_identity) {
      fail('external process lock owner identity changed before release');
    }
  }

  releaseOwnedLock(
    binding.directory,
    binding.key,
    binding.lockFile,
    acquired,
    binding.directoryStat,
  );
  return true;
}

// Git Bash may interpose a different native parent process for each Node
// invocation even while the same Bash critical section remains alive. The
// release capability is therefore stable across invocations. Only its digest
// is stored in the lock artifact, so read access to that artifact does not grant
// release authority. Descriptor-backed identity checks still protect removal.
function releaseExternalProcessLockByToken(options) {
  const binding = externalProcessLockBinding(options);
  const token = options.token;
  if (typeof token !== 'string' || !LOCK_TOKEN_RE.test(token)) {
    fail('external process lock token is invalid');
  }
  const acquired = lockOwner(binding.lockFile);
  const digest = externalProcessReleaseTokenDigest(token);
  if (!acquired) {
    fail('external process lock is missing at capability release');
  }
  if (!acquired.owner) {
    fail('external process lock owner is unreadable at capability release');
  }
  if (acquired.owner.kind !== 'external-process-lock') {
    fail('external process lock kind changed before capability release');
  }
  if (typeof acquired.owner.release_token_digest !== 'string') {
    fail('external process lock has no capability digest');
  }
  if (!constantTimeTextEqual(acquired.owner.release_token_digest, digest)) {
    fail(`external process lock release token digest mismatch (${acquired.owner.release_token_digest} != ${digest})`);
  }
  releaseOwnedLock(
    binding.directory,
    binding.key,
    binding.lockFile,
    acquired,
    binding.directoryStat,
  );
  return true;
}

function contextComparable(context) {
  return {
    schema: context.schema,
    schema_version: context.schema_version,
    host: context.host,
    session_id_hash: context.session_id_hash,
    project_root: context.project_root,
    plugin_root: context.plugin_root,
    plugin_data: context.plugin_data,
    plugin_version: context.plugin_version,
    source_revision: context.source_revision,
    runtime_digest: context.runtime_digest,
    principal_profiles: context.principal_profiles,
  };
}

function registerContext(options) {
  const pluginData = canonicalDirectory(options.pluginData, 'plugin data');
  const recordsDir = ensureDescendantDirectory(options.pluginData, options.recordsDir);
  const locksDir = ensureDescendantDirectory(pluginData, path.join(path.dirname(recordsDir), 'locks'));
  const key = sessionKey(options.sessionId);
  const file = contextRecordFile(recordsDir, key);

  return withFileLock(locksDir, key, () => {
    if (fs.existsSync(file)) {
      const existing = validateContext(readJson(file), options.host);
      const expected = buildContext({ ...options, createdAt: existing.created_at });
      if (JSON.stringify(contextComparable(existing)) !== JSON.stringify(contextComparable(expected))) {
        fail('immutable session context mismatch');
      }
      return existing;
    }

    const context = buildContext(options);
    atomicCreateJson(file, context);
    return context;
  });
}

function readContextInternal(options) {
  const recordsDirInput = requireText(options.recordsDir, 'records directory');
  if (!fs.existsSync(recordsDirInput)) {
    fail('context record directory is missing');
  }
  const recordsDir = canonicalDirectory(recordsDirInput, 'records directory');
  const file = contextRecordFile(recordsDir, options.sessionId);
  const context = validateContext(readJson(file), options.expectedHost, {
    allowMissingProjectRoot: options.allowMissingProjectRoot,
  });
  if (context.session_id_hash !== sessionIdHash(options.sessionId)) {
    fail('context session hash mismatch');
  }
  const currentDigest = computeRuntimeDigest(context.plugin_root, context.host);
  if (currentDigest !== context.runtime_digest) {
    fail('context runtime digest mismatch');
  }
  const { manifest } = pluginMetadata(context.plugin_root, context.host);
  if (manifest.version !== context.plugin_version) {
    fail('context plugin version mismatch');
  }
  return context;
}

function readContext(options) {
  return readContextInternal({ ...options, allowMissingProjectRoot: false });
}

// One of the two bind failures a caller may treat as "nothing left to enforce"
// (the other is a session with no record at all, which never reaches this
// reader): every part of the record validates exactly as readContext demands,
// and its recorded project root is simply gone — the harness recycled or the user deleted that
// worktree. The workflow document lives at <project_root>/.zensu/state/, so it
// died with the directory: no review chain and no Autopilot run remain
// reachable, which is the same argument that already releases a session with no
// record at all.
//
// Deliberately NOT this state, and therefore still fail-closed: a root that
// EXISTS but no longer matches (a symlinked, moved, or re-created directory), a
// dangling symlink or a file at that path, and any record that disagrees about
// anything ELSE — plugin root, plugin data, session hash, runtime digest,
// plugin version, schema, or principal profiles. Those are integrity signals,
// not a vanished worktree, and a second disagreement is never relaxed alongside
// the first. Throws on every one of them; returns the context only for the
// exact state described above.
// Control characters and DEL. canonicalDirectory rejects a subset of these on
// the strict path; the orphan reader skips that function for its EXISTENCE
// check and must not lose its shape check with it.
const UNSAFE_PATH_CHARACTERS = new RegExp('[\\u0000-\\u001f\\u007f]');

function readOrphanedProjectRootContext(options) {
  const context = readContextInternal({ ...options, allowMissingProjectRoot: true });
  // Waiving canonicalDirectory waives its EXISTENCE check, which is the point —
  // but it would also waive that function's shape validation, and this value is
  // not inert: callers print it to stderr and into the /zensu:doctor report,
  // which the doctor skill renders verbatim. Without these two guards a record
  // whose project_root alone was edited to an absent path carrying newlines or
  // ANSI escapes would classify as the relaxable state and get its bytes echoed
  // into a terminal and into the model's context — a record the strict
  // readContext fails closed on. Re-apply the shape half, so EXISTENCE stays
  // the only waived check.
  if (UNSAFE_PATH_CHARACTERS.test(context.project_root)) {
    fail('context project root is unsafe');
  }
  if (!path.isAbsolute(context.project_root)) {
    fail('context project root must be absolute');
  }
  // lstat, never realpath: realpath follows a symlink and would report a
  // dangling link as absent, quietly turning a present-but-wrong root into the
  // relaxable state.
  try {
    fs.lstatSync(context.project_root);
  } catch (error) {
    if (error.code === 'ENOENT') return context;
    fail('context project root is unreadable');
  }
  // Unreachable — fail() always throws. Stated rather than followed by a
  // `return context`, which would hand back a root that still exists if fail()
  // ever stopped throwing: the exact value this reader must never return.
  fail('context project root still exists');
}

// ---------------------------------------------------------------------------
// Adoption — serving an intact record from a declared-incompatible lineage.
// ---------------------------------------------------------------------------
//
// runtimeLineageCompatible decides who may serve a record from the DECLARED
// versions, and while the plugin is at major 0 a differing minor is a refusal.
// That rule is unchanged and is not weakened here. What it cannot see is whether
// the persisted shapes actually moved — and when they did not, its refusal
// wedges a session the running code could read perfectly well. Every write
// channel is denied, so the user cannot repair it, and before the diagnosis
// existed they were not even told why.
//
// Adoption is the one explicit, verified exit — and deliberately NOT a ledgered
// one: the bypass ledger records gate ESCAPES so that everything rendered under
// "Gates bypassed" is true, and adoption escapes no gate. Its provenance is a
// workflow history entry, exactly as `--chain-recover`'s is. It is authorised by
// SCHEMA EQUALITY rather than by the version numbers, because the schema is what
// the bytes on disk are actually held to — and that gate CLOSES ITSELF:
//
//   - the record's own `schema_version` is enforced by validateContext, so a
//     future SCHEMA_VERSION bump makes readContext throw and adoption refuses
//     without anyone having to remember to add a check;
//   - the workflow document's `schema` and `schema_version` are enforced by
//     validateWorkflowState, for the same reason and with the same consequence.
//
// A release that genuinely breaks a persisted shape is therefore non-adoptable
// by construction, not by policy. Everything else below is identity: the record
// must still be provably the one it claims to be, and the runtime taking it over
// must be a sibling installation of the one that minted it.
//
// What adoption does NOT do: it never rewrites a record (the old one is set
// aside under a new name and stays readable), never touches the workflow
// document's decision fields, and never relaxes plugin_data — the boundary that
// keeps a development checkout and an installed marketplace plugin on separate
// record stores.
// The ONE spelling of the workflow document's location. workflowStateDirectory
// composes it with the creating helpers; adoptionWorkflowStatePath composes it
// without them. Both must agree, or the read-only probe and the read it guards
// resolve to different files.
const WORKFLOW_STATE_SEGMENTS = ['.zensu', 'state'];
const WORKFLOW_STATE_PREFIX = 'tdd-phase-';

const ADOPTION_REFUSALS = {
  RECORD_UNREADABLE: 'record-unreadable',
  PLUGIN_DATA: 'plugin-data-mismatch',
  ALREADY_SERVED: 'already-served',
  NOT_SIBLING: 'not-a-sibling-installation',
  EXECUTING_UNIDENTIFIED: 'executing-runtime-unidentified',
  BACKWARDS: 'executing-runtime-older',
  WORKFLOW_SCHEMA: 'workflow-schema-mismatch',
};

// A version reaches a FILENAME below, so it is held to a strict shape first. The
// record schema only requireText's plugin_version, so without this a crafted
// manifest could steer the superseded record anywhere in the tree.
const ADOPTION_SAFE_VERSION_RE = /^[0-9A-Za-z][0-9A-Za-z.+-]{0,63}$/;

// A hand-copy of LEASE_ID_RE in review-evidence-lease-v1.js. That module cannot be
// required from here (it requires the binder, which requires this core), and the
// sweep has to agree with its listRecords about which entries are valid — an
// entry this predicate keeps but listRecords rejects leaves the wedge intact.
const LEASE_RECORD_ID_RE = /^rel1_[a-f0-9]{32}$/;

// A hand-copy of MAX_RECORD_BYTES in review-evidence-lease-v1.js, for the same
// reason LEASE_RECORD_ID_RE is one: the sweep must agree with listRecords about
// which entries are readable, and that module cannot be required from here. An
// entry over this cap is one listRecords would reject, so the sweep moves it
// rather than reading it.
const LEASE_RECORD_MAX_BYTES = 8 * 1024 * 1024;

function adoptionRefusal(reason) {
  return { ok: false, reason };
}

// The workflow document's path WITHOUT creating anything. workflowStateFile
// resolves through ensureDescendantDirectory, which mkdirs every missing
// component — fine for a writer, wrong for a read-only probe. Both the
// adoptability report and the provenance guard need to ask "is there a document"
// without answering "there is now".
function adoptionWorkflowStatePath(projectRoot, sessionId) {
  // Composed from the SAME segment constants workflowStateDirectory uses, so the
  // guard and the read it guards can never resolve to different files. A separate
  // spelling would let a layout move skip the workflow-schema condition entirely
  // — silently removing one conjunct of the self-closing property the whole
  // authorising argument rests on. Named rather than numbered on purpose: the
  // ordinal moved once already when a condition was removed, and a stale number
  // here points at a check that no longer exists.
  return path.join(
    projectRoot,
    ...WORKFLOW_STATE_SEGMENTS,
    `${WORKFLOW_STATE_PREFIX}${sessionKey(sessionId)}.json`,
  );
}

// Never throws: every caller is on a failure path already, and an exception
// would replace a named condition with a stack trace. A refusal always names
// exactly which of the conditions was not met.
function adoptableRecord(options) {
  let executingPluginRoot;
  let pluginData;
  let context;
  try {
    executingPluginRoot = canonicalDirectory(options.executingPluginRoot, 'executing plugin root');
    pluginData = canonicalDirectory(options.pluginData, 'plugin data');
    // Condition 1 — the record is still provably itself. readContext recomputes
    // the runtime digest against the RECORDED root and re-reads that root's
    // manifest, so a forged or hand-edited record cannot reach adoption; it also
    // enforces the context schema and that the recorded project root exists.
    context = readContext({
      recordsDir: options.recordsDir,
      sessionId: options.sessionId,
      expectedHost: options.host,
    });
  } catch {
    return adoptionRefusal(ADOPTION_REFUSALS.RECORD_UNREADABLE);
  }
  // Condition 2 — the record store boundary is never relaxed.
  if (context.plugin_data !== pluginData) return adoptionRefusal(ADOPTION_REFUSALS.PLUGIN_DATA);
  // There is deliberately NO condition on the CALLER's project root, and
  // `options.projectRoot` is not read at all. It was one once, refusing as
  // `project-root-mismatch` whenever the supplied directory was not the recorded
  // one, and it made this repair unreachable in exactly the state it exists for.
  //
  // Two reasons, and the second is why the first was not enough to keep it:
  //
  //   - It protected nothing. The anchor is carried FROM the record —
  //     adoptContext passes `verdict.context.project_root` to buildContext — and
  //     no write here is located by the caller's value. The write bound is
  //     readContext (session hash, digest recomputed against the RECORDED root,
  //     that root's declared version) plus the sibling-root and plugin_data
  //     checks; the entry script's own header states it that way and never named
  //     this comparison.
  //   - It contradicted the module. resolveHookSession answers
  //     `projectRoot: context.project_root` under "The mutable payload cwd is
  //     never a project authority" — every gate binds to the record. This was the
  //     single place that let a caller-supplied directory outrank it.
  //
  // The two disagree in practice: the record is minted from the SessionStart
  // payload cwd, while the adoption is handed CLAUDE_PROJECT_DIR, a literal the
  // skill renders from the harness. A fork whose cwd was a worktree records that
  // worktree while the harness still reports the origin repo, and `cd` cannot
  // change the latter — so the condition was unsatisfiable from inside the very
  // session it was refusing. A record whose project root is GONE is still
  // refused, as `record-unreadable`: validateContext canonicalizes it at
  // condition 1.
  //
  // Condition 3 — nothing to adopt when this runtime already serves the record.
  // Refusing here keeps adoption from being a way to re-mint a healthy session.
  if (servesRecordedRuntime(context, executingPluginRoot, context.host)) {
    return adoptionRefusal(ADOPTION_REFUSALS.ALREADY_SERVED);
  }
  // Condition 4 — the same structural bound servesRecordedRuntime applies: a
  // marketplace install lands beside the versions it replaces, a development
  // checkout never does, so a --plugin-dir tree cannot adopt an installed
  // session's record no matter what its manifest declares.
  if (path.dirname(context.plugin_root) !== path.dirname(executingPluginRoot)) {
    return adoptionRefusal(ADOPTION_REFUSALS.NOT_SIBLING);
  }
  const executingVersion = executingPluginVersion(executingPluginRoot, context.host);
  if (typeof executingVersion !== 'string'
    || !ADOPTION_SAFE_VERSION_RE.test(executingVersion)
    || !ADOPTION_SAFE_VERSION_RE.test(context.plugin_version)) {
    return adoptionRefusal(ADOPTION_REFUSALS.EXECUTING_UNIDENTIFIED);
  }
  // Condition 5 — never backwards. Only a newer tree can be expected to
  // understand an older one's state; the reverse is the direction that loses
  // data, and it stays refused here exactly as it is in runtimeLineageCompatible.
  const recordedParts = parseRuntimeVersion(context.plugin_version);
  const executingParts = parseRuntimeVersion(executingVersion);
  if (recordedParts === null || executingParts === null) {
    return adoptionRefusal(ADOPTION_REFUSALS.EXECUTING_UNIDENTIFIED);
  }
  for (let index = 0; index < recordedParts.length; index += 1) {
    if (executingParts[index] !== recordedParts[index]) {
      if (executingParts[index] < recordedParts[index]) {
        return adoptionRefusal(ADOPTION_REFUSALS.BACKWARDS);
      }
      break;
    }
  }
  // Condition 6 — the workflow document, when there is one, must be readable by
  // THIS runtime. validateWorkflowState enforces `schema` and `schema_version`,
  // so a real persisted-shape break refuses here. A missing document is not a
  // disagreement: there is no shape to disagree about, and adoption leaves the
  // session exactly as able to mint one as a fresh session would be.
  //
  // The path is joined by hand rather than through workflowStateFile, which goes
  // via ensureDescendantDirectory and CREATES the missing components. This
  // predicate is the read-only half of the command, and "without --confirm it is
  // read-only" is the premise the gate widening rests on — a probe that mkdirs
  // <project>/.zensu/state would falsify it.
  const workflowFile = adoptionWorkflowStatePath(context.project_root, options.sessionId);
  if (fs.existsSync(workflowFile)) {
    try {
      readWorkflowState({ projectRoot: context.project_root, sessionId: options.sessionId });
    } catch {
      return adoptionRefusal(ADOPTION_REFUSALS.WORKFLOW_SCHEMA);
    }
  }
  return {
    ok: true,
    context,
    recorded: context.plugin_version,
    executing: executingVersion,
  };
}

// Stale leases are moved OUT of the records directory, never renamed inside it:
// listRecords fails on any entry that does not end in `.json`, so a set-aside
// file left in place would be strictly worse than the stale lease it replaced.
//
// Why they must go at all: review-evidence-lease-v1.js compares its recorded
// plugin_root STRICTLY and listRecords propagates the first failure, so a single
// lease minted before the adoption would fail every later lease operation for
// this session. A lease is a short-lived evidence reservation — losing one costs
// a repeat, not a guarantee — so this is the cheapest correct resolution, and it
// sets them aside rather than deleting them.
function discardSupersededLeases(pluginData, key, executingPluginRoot) {
  const recordsDirectory = path.join(pluginData, 'review-evidence', 'v1', 'records', key);
  // The owning module reaches this directory only through ensurePrivateDirectory,
  // which rejects a symlink, an alias and unsafe permissions or ownership. This
  // copy cannot call that constructor (the dependency runs the other way), so it
  // re-applies the part that matters before it renames anything: a symlinked or
  // aliased records directory is left ALONE rather than swept through.
  try {
    const stat = fs.lstatSync(recordsDirectory);
    // `unsafe` distinguishes a store this sweep REFUSED to touch from the
    // ordinary "no lease was ever minted" case. Both discard nothing; only one of
    // them is a clean outcome, and the caller must be able to say which. It also
    // names WHICH directory it refused: the two live in different places and have
    // different remedies — `source` is this session's own lease records directory,
    // `destination` the shared `superseded/` one. Reported as a bare true, a
    // planted link at the destination sent the operator to the directory the sweep
    // had just read successfully, and went uninvestigated.
    if (stat.isSymbolicLink() || !stat.isDirectory()) return { discarded: 0, failed: [], unsafe: 'source' };
    if (fs.realpathSync.native(recordsDirectory) !== recordsDirectory) {
      return { discarded: 0, failed: [], unsafe: 'source' };
    }
  } catch (error) {
    return { discarded: 0, failed: [], unsafe: error && error.code !== 'ENOENT' ? 'source' : false };
  }
  let entries;
  try {
    entries = fs.readdirSync(recordsDirectory);
  } catch (error) {
    // ONE shape on every path — a scalar here would hand the caller `undefined`
    // for both fields and make the reporter throw AFTER the record swap had
    // already succeeded, reporting failure for a completed adoption.
    //
    // NOT the ordinary "no lease was ever minted" case, whatever an older
    // comment here claimed: the lstat guard above has already established that
    // this directory exists, is a real directory and is canonical, and it is
    // what answers ENOENT. What reaches this catch is EACCES, EPERM, EMFILE or a
    // race — a directory that exists and cannot be read, which is precisely the
    // state the caller must not be told was clean. It carries the same `source`
    // diagnosis as the guard above, and the ENOENT arm stays clean for the race.
    return {
      discarded: 0,
      failed: [],
      unsafe: error && error.code === 'ENOENT' ? false : 'source',
    };
  }
  const asideDirectory = path.join(pluginData, 'review-evidence', 'v1', 'superseded', key);
  let discarded = 0;
  const failed = [];
  // The DESTINATION gets the same treatment as the source. mkdirSync with
  // `recursive` does NOT fail on an existing symlink-to-directory, so without
  // this a pre-created link there would quietly receive every moved lease while
  // the sweep still reported a clean count.
  // The SHAPE check runs on every component; the PERMISSION check stays on the
  // leaf. Those are two different questions and only one of them is this
  // function's to ask.
  //
  // Shape, per segment: an ancestor swapped to a symlink is how the rename race
  // below is won, and `recursive` mkdir neither fails on nor reports one. Checking
  // only the leaf left that open, so the walk closes it.
  //
  // Permissions, leaf only, and deliberately NOT per segment: `review-evidence`
  // and `v1` are SHARED and this function does not own them. Their mode is
  // `ensurePrivateDirectory`'s to set — that reader REPAIRS with a chmod per
  // segment (review-evidence-lease-v1.js) where this one may only look, so
  // refusing here on an ancestor that some earlier version created at 0755 would
  // turn a working sweep into a destination refusal for a permission this code
  // never manages. The leaf is different because it is the one component this
  // function creates WHEN ABSENT — and the check earns its place precisely when it
  // was not absent: `recursive` mkdir neither chmods nor fails on an existing
  // directory, so on any second adoption of the same session key, or against a
  // leaf another local process pre-created, the mode it finds is not one this
  // function set. Refusing a hostile pre-existing leaf is the whole job.
  //
  // The shape it mirrors is privateRecordsDirectory in claude-hook-session-v1.js
  // — check, never repair. Do not "align" it with ensurePrivateDirectory: a
  // read-side guard that silently widens or narrows a mode is a worse defect than
  // the one it would be fixing.
  const asideIsSafe = () => {
    try {
      fs.mkdirSync(asideDirectory, { recursive: true, mode: 0o700 });
      let current = pluginData;
      for (const segment of ['review-evidence', 'v1', 'superseded', key]) {
        current = path.join(current, segment);
        const stat = fs.lstatSync(current);
        if (stat.isSymbolicLink() || !stat.isDirectory()) return false;
      }
      const leaf = fs.lstatSync(asideDirectory);
      if (process.platform !== 'win32') {
        if ((leaf.mode & 0o077) !== 0) return false;
        if (typeof process.getuid === 'function' && leaf.uid !== process.getuid()) return false;
      }
      // Last: realpath resolves every component at once, so one call covers the
      // whole chain against a link the lstat pass above could still have raced.
      if (fs.realpathSync.native(asideDirectory) !== asideDirectory) return false;
      return true;
    } catch {
      return false;
    }
  };
  // `unsafe` carries the whole diagnosis, exactly as the three source-unsafe
  // returns do. Listing every entry as `failed` here would name leases the
  // keep-branch would have left alone, and the reporter would print two
  // contradictory warnings about the same sweep.
  if (!asideIsSafe()) return { discarded: 0, failed: [], unsafe: 'destination' };
  for (const name of entries.sort()) {
    // EVERY entry listRecords would reject, not only the `.json` ones: it fails
    // the whole set on an unexpected name, so a leftover `.tmp` from a killed
    // lease write wedges it exactly as hard as a stale record would.
    const file = path.join(recordsDirectory, name);
    let record;
    try {
      // lstat and cap BEFORE the read, because a bare readFileSync on a FIFO
      // blocks forever and raises nothing a catch can see — and this runs AFTER
      // adoptContext has already swapped the record, so a hang here leaves the one
      // repair the user can still invoke stuck half-done with no other channel to
      // finish it. An entry that is not a regular file, or is larger than the cap
      // listRecords holds its records to, is one that reader would reject anyway,
      // so it falls through to the move branch exactly as an unparseable one does.
      const entry = fs.lstatSync(file);
      if (!entry.isFile() || entry.size > LEASE_RECORD_MAX_BYTES) throw new Error('unreadable');
      record = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch {
      record = null;
    }
    // An unreadable lease is moved aside too: listRecords would fail on it just
    // as hard, and leaving it would defeat the whole point of this sweep.
    // Keep a SUPERSET of what listRecords accepts — stated as a superset because
    // that is what it is. Three of that reader's conjuncts are mirrored here (the
    // id shape, lease_id agreeing with the filename, and the executing root),
    // which is what stops an entry it rejects from being kept on plugin_root
    // alone. NOT mirrored: it also rejects a symlinked or multiply-linked record
    // file, a non-canonical spelling, an oversized one, and every validateRecord
    // violation. An entry failing only those while naming the executing root is
    // therefore KEPT and keeps wedging later lease operations — a residual, not
    // the main gap, because a lease can only name the executing root if that
    // runtime minted it, and none can be minted while the session is unbound.
    // The id shape is a hand-copy of LEASE_ID_RE in review-evidence-lease-v1.js,
    // pinned by test-versioned-plugin-upgrade.sh; keep the two in step.
    const leaseId = name.endsWith('.json') ? name.slice(0, -5) : '';
    if (LEASE_RECORD_ID_RE.test(leaseId)
      && record && typeof record === 'object'
      && record.lease_id === leaseId
      && record.plugin_root === executingPluginRoot) {
      continue;
    }
    try {
      // No mkdir here: asideIsSafe() already created AND validated the directory.
      // What that buys is one fewer way to CREATE the target — it does not close the
      // race. rename(2) resolves every non-final component, so a link swapped in at
      // asideDirectory after the guard still redirects each move.
      //
      // State the residual against what the guard actually establishes.
      // asideIsSafe() refuses a symlinked component anywhere in the chain, so the
      // swap has to happen AFTER it looked — and the leaf it lands in is 0700 and
      // owner-checked. What it does NOT establish is the mode of the shared
      // ancestors, which belong to ensurePrivateDirectory: where those are
      // group-writable the race needs no same-uid access at all. So: bounded by a
      // same-uid attacker on a store whose ancestors are private, unbounded on one
      // where they are not, and never closed either way.
      fs.renameSync(file, path.join(asideDirectory, name));
      discarded += 1;
    } catch {
      // A lease that could NOT be moved is reported separately, never folded
      // into the success count and never swallowed. Counting only successes
      // would render a partial sweep as a clean adoption while the exact wedge
      // this sweep exists to prevent survives.
      failed.push(name);
    }
  }
  return { discarded, failed };
}

const ADOPTION_HISTORY_PHASE = 'RUNTIME_ADOPTED';
const ADOPTION_HISTORY_REASON_PREFIX = 'runtime-adopted: ';

// Performs the adoption re-checked UNDER the records lock. The precondition is
// deliberately evaluated twice — once by the caller to report, once here to act
// — because between the two the plugin could have changed again.
function adoptContext(options) {
  const pluginData = canonicalDirectory(options.pluginData, 'plugin data');
  const recordsDir = ensureDescendantDirectory(options.pluginData, options.recordsDir);
  const locksDir = ensureDescendantDirectory(pluginData, path.join(path.dirname(recordsDir), 'locks'));
  const key = sessionKey(options.sessionId);
  const file = contextRecordFile(recordsDir, key);

  const adopted = withFileLock(locksDir, key, () => {
    const verdict = adoptableRecord({ ...options, pluginData, recordsDir });
    if (!verdict.ok) fail(`record is not adoptable: ${verdict.reason}`);
    const executingPluginRoot = canonicalDirectory(options.executingPluginRoot, 'executing plugin root');
    // created_at is carried over on purpose: the session began when it began,
    // and rewriting that would erase the only provenance the record still holds
    // about its own origin.
    const next = buildContext({
      host: verdict.context.host,
      sessionId: options.sessionId,
      projectRoot: verdict.context.project_root,
      pluginRoot: executingPluginRoot,
      pluginData,
      createdAt: verdict.context.created_at,
    });
    // Set aside, never overwrite. "The record is immutable" stays literally true:
    // no record is ever rewritten, a second one is minted beside it, and the
    // first stays readable under a name that says what happened to it.
    const supersededFile = path.join(
      recordsDir,
      `${key}.superseded-${verdict.recorded}.json`,
    );
    // The existence check is the COPY's own O_EXCL, never a separate existsSync:
    // that call resolves through symlinks, so a dangling link at the superseded
    // name would answer false and copyFileSync would then write the record
    // through it — and the rollback would unlink the link, leaving the collateral
    // write behind. COPYFILE_EXCL refuses both, atomically, with no TOCTOU window.
    // COPY aside, then replace in place — never rename-then-create. A rename
    // first leaves a window in which `<key>.json` resolves to nothing, and a
    // clean ENOENT there is `unregisteredSession`, the MOST relaxed state of all
    // (the Stop hook releases on it). A process death in that window would turn
    // a repairable lineage break into a permanently record-less session with a
    // live workflow document still on disk — strictly worse than what is being
    // repaired, and beyond the reach of any rollback.
    //
    // copyFileSync rather than linkSync on purpose: atomicWriteJson refuses a
    // target with nlink > 1, so a hard link would make the very next step fail.
    // atomicWriteJson writes a temp file and renames it over the target, so at
    // every instant the record name resolves to either the old bytes or the new.
    try {
      fs.copyFileSync(file, supersededFile, fs.constants.COPYFILE_EXCL);
    } catch (error) {
      if (error && error.code === 'EEXIST') {
        // Names the file, because this is also the crash-resume shape — a death
        // between the copy and the swap leaves it behind — and the session has
        // no other write channel to find it with.
        fail(`a superseded record already exists and adoption would overwrite it: ${supersededFile}`);
      }
      throw error;
    }
    try {
      atomicWriteJson(file, next);
    } catch (error) {
      // atomicWriteJson commits by rename and then re-checks the parent
      // directory's identity, so a throw can land AFTER the new record is in
      // place. Unlinking the copy then would destroy the only remaining bytes of
      // the superseded record while the adoption has in fact landed — the one
      // outcome worse than reporting a failure. Re-read the record and keep the
      // copy when the new bytes are already there.
      let committed = false;
      let readable = false;
      try {
        committed = JSON.stringify(readJson(file)) === JSON.stringify(next);
        readable = true;
      } catch { readable = false; }
      // Only an unambiguous "not committed" removes the copy. An unreadable
      // re-read is INDETERMINATE, and if the record did commit that copy is the
      // last readable image of the superseded record — deleting it on a guess is
      // the one outcome worse than reporting a failure.
      if (readable && !committed) {
        try { fs.unlinkSync(supersededFile); } catch { /* nothing better to try */ }
      }
      throw error;
    }
    return {
      context: next,
      supersededFile,
      recorded: verdict.recorded,
      executing: verdict.executing,
      projectRoot: verdict.context.project_root,
    };
  });

  // Provenance is a workflow history entry and NOT a record field, so the
  // context record keeps the exact shape every other release reads. It is
  // recorded after the swap because it is provenance, not a precondition: a
  // failure here is reported to the caller, never smoothed over, and never
  // reverts an adoption that already succeeded.
  let provenance = 'recorded';
  // A session with no workflow document is a state adoptableRecord explicitly
  // blesses ("a missing document is not a disagreement"), so it must not be
  // routed through the failure branch below — mutateWorkflowState fails closed on
  // a missing baseline, and the caller renders that as an anomaly worth
  // reporting. Say plainly that there was nothing to write to instead.
  if (!fs.existsSync(adoptionWorkflowStatePath(adopted.projectRoot, options.sessionId))) {
    provenance = 'no-workflow-document';
  } else {
    try {
      mutateWorkflowState({
        projectRoot: adopted.projectRoot,
        sessionId: options.sessionId,
        actor: 'main-v1',
        workflowState: 'runtime_adopted',
        event: 'runtime-adopted',
      }, (state) => {
        const history = Array.isArray(state.history) ? state.history : [];
        // `ts`, never `timestamp`: that is the key validateWorkflowExtensions
        // validates and the one both existing history writers in
        // zensu-tdd-phase.sh set. A different spelling would make this the one
        // entry every ts-keyed reader sees as untimestamped.
        history.push({
          step: '',
          phase: ADOPTION_HISTORY_PHASE,
          ts: nowIso(),
          reason: `${ADOPTION_HISTORY_REASON_PREFIX}${adopted.recorded} -> ${adopted.executing}`,
        });
        state.history = history;
        return state;
      });
    } catch (error) {
      provenance = `unavailable: ${error && error.message ? error.message : 'unknown'}`;
    }
  }

  const leases = discardSupersededLeases(pluginData, key, adopted.context.plugin_root);

  return {
    ...adopted,
    provenance,
    leasesDiscarded: leases.discarded,
    leasesFailed: leases.failed,
    leasesUnsafe: Boolean(leases.unsafe),
    // WHICH directory the sweep refused, so the reporter can name it. Kept beside
    // the boolean rather than replacing it: every existing reader branches on the
    // boolean, and a truthy string would have carried them silently.
    leasesUnsafeScope: typeof leases.unsafe === 'string' ? leases.unsafe : '',
  };
}

function renderMainContext(contextInput) {
  const context = validateContext(contextInput);
  return [
    '[zensu-session-context]',
    `schema_version=${context.schema_version}`,
    `host=${context.host}`,
    `session_id_hash=${context.session_id_hash}`,
    `project_root=${JSON.stringify(context.project_root)}`,
    `plugin_root=${JSON.stringify(context.plugin_root)}`,
    `runtime_digest=${context.runtime_digest}`,
    'principal=main-v1',
  ].join(' ');
}

function renderReviewerContext(contextInput) {
  const context = validateContext(contextInput);
  return [
    '[zensu-reviewer-context]',
    `schema_version=${context.schema_version}`,
    `host=${context.host}`,
    `session_id_hash=${context.session_id_hash}`,
    `project_root=${JSON.stringify(context.project_root)}`,
    `plugin_root=${JSON.stringify(context.plugin_root)}`,
    `runtime_digest=${context.runtime_digest}`,
    'principal=reviewer-readonly-v1.',
    'The reviewer must not write, spawn, mutate workflow state, invoke mutating control or MCP tools, or impersonate main.',
    'Grep and Glob must name a concrete safe source/docs/test subtree; an omitted path or project/plugin/plugin-data ancestor is denied because it could traverse protected state.',
  ].join(' ');
}

function renderEvidenceWorkerContext(contextInput) {
  const context = validateContext(contextInput);
  return [
    '[zensu-evidence-worker-context]',
    `schema_version=${context.schema_version}`,
    `host=${context.host}`,
    `project_root=${JSON.stringify(context.project_root)}`,
    `runtime_digest=${context.runtime_digest}`,
    'principal=evidence-worker-v1.',
    'Only Read, Grep, and Glob are available and every call is confined by a private, agent-bound evidence lease.',
    'No lease id, plugin-data path, raw session id, private selector, command, mutation, messaging, task, nested-agent, Skill, MCP, Web, or memory capability is available.',
    'Return exactly one raw schema-valid JSON result for the assigned kind and role.',
  ].join(' ');
}

function renderHostContext(contextInput) {
  const context = validateContext(contextInput);
  return [
    '[zensu-host-context]',
    `schema_version=${context.schema_version}`,
    `host=${context.host}`,
    `project_root=${JSON.stringify(context.project_root)}`,
    `runtime_digest=${context.runtime_digest}`,
    'principal=host-profile-v1.',
    'Non-command tools remain governed by this agent definition and Claude Code host permissions; every command-execution tool is denied by the Zensu capability gate.',
    'Grep and Glob must name a concrete safe subtree; an omitted path or project/plugin/plugin-data ancestor is denied because it could traverse protected state.',
    'Session selectors are not authority: this neutral agent must not access Session Control or workflow-root state, claim main-v1, or mutate Zensu workflow state.',
  ].join(' ');
}

function workflowStateDirectory(projectRootInput) {
  // Reduced over the segment list rather than destructured: a third segment must
  // not be silently dropped here while adoptionWorkflowStatePath's spread picks
  // it up, which is exactly the split the shared constant exists to prevent.
  return WORKFLOW_STATE_SEGMENTS.reduce(
    (parent, segment) => ensureDescendantDirectory(parent, path.join(parent, segment)),
    canonicalDirectory(projectRootInput, 'project root'),
  );
}

function resolveWorkflowStateDirectory(options) {
  if (options.stateDirectory !== undefined) {
    fail('workflow state directory overrides are unsupported');
  }
  return workflowStateDirectory(options.projectRoot);
}

function workflowStateFile(projectRoot, sessionId) {
  return path.join(
    workflowStateDirectory(projectRoot),
    `${WORKFLOW_STATE_PREFIX}${sessionKey(sessionId)}.json`,
  );
}

function validateWorkflowToken(value, label) {
  requireText(value, label);
  if (!/^[a-z][a-z0-9_-]{0,63}$/.test(value)) {
    fail(`${label} has an invalid format`);
  }
  return value;
}

const WORKFLOW_BOOLEAN_EXTENSIONS = [
  'active',
  'vanilla',
  'implComplete',
  'chainDone',
  'codeReviewDone',
  'selfReviewFixed',
  'workflowActive',
  'reviewTicketConsumed',
];

const WORKFLOW_INTEGER_EXTENSIONS = [
  'reviewRound',
  'stopBlockCount',
  'autopilotAttempt',
];

function validateWorkflowString(value, label, allowEmpty = false) {
  if (
    typeof value !== 'string'
    || (!allowEmpty && value.length === 0)
    || /[\u0000-\u001f\u007f]/.test(value)
  ) {
    fail(`${label} is invalid`);
  }
  return value;
}

function validateWorkflowExtensions(state) {
  for (const field of WORKFLOW_BOOLEAN_EXTENSIONS) {
    if (Object.prototype.hasOwnProperty.call(state, field) && typeof state[field] !== 'boolean') {
      fail(`workflow extension ${field} must be boolean`);
    }
  }

  for (const field of WORKFLOW_INTEGER_EXTENSIONS) {
    if (
      Object.prototype.hasOwnProperty.call(state, field)
      && (!Number.isSafeInteger(state[field]) || state[field] < 0 || state[field] > 1000000)
    ) {
      fail(`workflow extension ${field} must be a bounded non-negative integer`);
    }
  }

  if (Object.prototype.hasOwnProperty.call(state, 'phase')) {
    validateWorkflowString(state.phase, 'workflow phase');
  }
  if (Object.prototype.hasOwnProperty.call(state, 'step_id')) {
    validateWorkflowString(state.step_id, 'workflow step_id', true);
  }

  if (Object.prototype.hasOwnProperty.call(state, 'history')) {
    if (!Array.isArray(state.history)) fail('workflow history must be an array');
    for (const [index, entry] of state.history.entries()) {
      if (
        !entry
        || typeof entry !== 'object'
        || Array.isArray(entry)
        || (Object.getPrototypeOf(entry) !== Object.prototype && Object.getPrototypeOf(entry) !== null)
      ) {
        fail(`workflow history entry ${index} must be an object`);
      }
      validateWorkflowString(entry.step, `workflow history entry ${index} step`, true);
      validateWorkflowString(entry.phase, `workflow history entry ${index} phase`);
      if (Object.prototype.hasOwnProperty.call(entry, 'ts')) {
        if (typeof entry.ts !== 'string' || !Number.isFinite(Date.parse(entry.ts))) {
          fail(`workflow history entry ${index} timestamp is invalid`);
        }
      }
      if (Object.prototype.hasOwnProperty.call(entry, 'reason') && typeof entry.reason !== 'string') {
        fail(`workflow history entry ${index} reason must be a string`);
      }
    }
  }

  for (const field of ['workflowTools', 'bypasses']) {
    if (!Object.prototype.hasOwnProperty.call(state, field)) continue;
    if (!Array.isArray(state[field])) fail(`workflow extension ${field} must be an array`);
    for (const [index, value] of state[field].entries()) {
      validateWorkflowString(value, `workflow extension ${field}[${index}]`);
    }
  }

  for (const field of [
    'reviewTicket',
    'deferredReviewClaim',
    'autopilotRunId',
    'autopilotReturnStage',
    'chainId',
    'chainOutcome',
  ]) {
    if (Object.prototype.hasOwnProperty.call(state, field)) {
      validateWorkflowString(state[field], `workflow extension ${field}`, true);
    }
  }

  if (Object.prototype.hasOwnProperty.call(state, 'reviewRearm')) {
    const marker = state.reviewRearm;
    const exactKeys = [
      'attempt',
      'chainId',
      'consumedTicketSha256',
      'retire',
      'runId',
      'schemaVersion',
      'status',
    ];
    if (
      !marker
      || typeof marker !== 'object'
      || Array.isArray(marker)
      || Object.keys(marker).sort().join(',') !== exactKeys.join(',')
      || marker.schemaVersion !== 1
      || marker.status !== 'pending'
      || !Number.isSafeInteger(marker.attempt)
      || marker.attempt < 1
      || marker.attempt > 999
      || typeof marker.retire !== 'boolean'
      || !/^[A-Za-z0-9][A-Za-z0-9_.:-]{2,127}$/.test(marker.runId || '')
      || !/^[A-Za-z0-9][A-Za-z0-9_.:-]{2,127}$/.test(marker.chainId || '')
      || !/^[a-f0-9]{64}$/.test(marker.consumedTicketSha256 || '')
    ) {
      fail('workflow extension reviewRearm is invalid');
    }
  }

  if (Object.prototype.hasOwnProperty.call(state, 'deferredReviewCancellation')) {
    const marker = state.deferredReviewCancellation;
    const keys = [
      'cancellationId',
      'claimId',
      'mode',
      'origin',
      'ownerSessionId',
      'resetBinding',
      'resultRevision',
      'schemaVersion',
      'sourceRevision',
    ];
    if (
      !marker
      || typeof marker !== 'object'
      || Array.isArray(marker)
      || Object.keys(marker).sort().join(',') !== keys.join(',')
      || marker.schemaVersion !== 1
      || !/^drc_[A-Za-z0-9_-]+$/.test(marker.cancellationId || '')
      || marker.cancellationId.length > 96
      || !/^dc_[A-Za-z0-9_-]+$/.test(marker.claimId || '')
      || marker.claimId.length > 96
      || !['release-only', 'reset'].includes(marker.mode)
      || !['linked', 'unseeded'].includes(marker.origin)
      || !Number.isSafeInteger(marker.sourceRevision)
      || marker.sourceRevision < 1
      || marker.resultRevision !== marker.sourceRevision + 1
      || state.session_id_hash !== sessionIdHash(marker.ownerSessionId)
      || !deferredReviewResetBindingIsValid(marker.resetBinding)
      || (marker.mode === 'release-only' && marker.resetBinding !== null)
    ) {
      fail('workflow deferredReviewCancellation marker is invalid');
    }
    canonicalControlSessionKey(marker.ownerSessionId, 'cancellation owner');
  }
}

function stampWorkflowState(
  input,
  sessionId,
  workflowStateInput,
  eventInput,
  updatedAtInput,
  authoritativePreviousRevision,
) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    fail('workflow state must be an object');
  }
  const workflowState = validateWorkflowToken(workflowStateInput, 'workflow state');
  const event = validateWorkflowToken(eventInput, 'workflow event');
  const hash = sessionIdHash(sessionId);
  if (input.revision !== undefined && (!Number.isSafeInteger(input.revision) || input.revision < 0)) {
    fail('workflow revision is invalid');
  }
  const previousRevision = authoritativePreviousRevision === undefined
    ? (input.revision || 0)
    : authoritativePreviousRevision;
  if (!Number.isSafeInteger(previousRevision) || previousRevision < 0) {
    fail('workflow revision is invalid');
  }
  if (previousRevision === Number.MAX_SAFE_INTEGER) {
    fail('workflow revision overflow');
  }
  const updatedAt = updatedAtInput || nowIso();
  if (!Number.isFinite(Date.parse(updatedAt))) {
    fail('updatedAt must be an ISO-compatible timestamp');
  }
  const extension = {};
  for (const [field, value] of Object.entries(input)) {
    if (!WORKFLOW_RESERVED_FIELDS.has(field)) extension[field] = value;
  }
  const next = {
    ...extension,
    schema: WORKFLOW_SCHEMA,
    schema_version: SCHEMA_VERSION,
    session_id_hash: hash,
    workflow_state: workflowState,
    revision: previousRevision + 1,
    last_event: event,
    updated_at: updatedAt,
    actor: 'main-v1',
  };
  return validateWorkflowState(next, sessionId);
}

function validateWorkflowState(state, sessionId) {
  if (
    !state
    || typeof state !== 'object'
    || Array.isArray(state)
    || state.schema !== WORKFLOW_SCHEMA
    || state.schema_version !== SCHEMA_VERSION
  ) {
    fail('workflow state schema mismatch');
  }
  if (state.session_id_hash !== sessionIdHash(sessionId)) {
    fail('workflow session hash mismatch');
  }
  if (!Number.isSafeInteger(state.revision) || state.revision < 1) {
    fail('workflow revision is invalid');
  }
  validateWorkflowToken(state.workflow_state, 'workflow state');
  validateWorkflowToken(state.last_event, 'workflow event');
  if (typeof state.updated_at !== 'string' || !Number.isFinite(Date.parse(state.updated_at))) {
    fail('workflow updated_at is invalid');
  }
  if (state.actor !== 'main-v1') {
    fail('workflow actor is invalid');
  }
  if (Object.prototype.hasOwnProperty.call(state, 'session_id')) {
    fail('raw session identifier is forbidden in workflow state');
  }
  validateWorkflowExtensions(state);
  return state;
}

function atomicWriteJson(file, value) {
  if (fs.existsSync(file)) {
    const existing = fs.lstatSync(file);
    if (existing.isSymbolicLink()) fail('symlink state file rejected');
    if (!existing.isFile()) fail('non-regular state file rejected');
    if (existing.nlink > 1) fail('multi-linked state file rejected');
  }
  const temporary = path.join(
    path.dirname(file),
    `.${path.basename(file)}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.tmp`,
  );
  const parent = path.dirname(file);
  const parentBefore = fs.lstatSync(parent);
  if (parentBefore.isSymbolicLink() || !parentBefore.isDirectory()) {
    fail(`unsafe state parent directory: ${parent}`);
  }
  let descriptor;
  try {
    descriptor = fs.openSync(temporary, 'wx', 0o600);
    fs.writeFileSync(descriptor, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    const parentAtCommit = fs.lstatSync(parent);
    if (
      parentAtCommit.isSymbolicLink()
      || !parentAtCommit.isDirectory()
      || !sameFileIdentity(parentBefore, parentAtCommit)
    ) {
      fail(`state parent directory changed before commit: ${file}`);
    }
    fs.renameSync(temporary, file);
    const parentAfter = fs.lstatSync(parent);
    if (!sameFileIdentity(parentBefore, parentAfter)) {
      fail(`state parent directory changed during commit: ${file}`);
    }
  } finally {
    if (descriptor !== undefined) {
      fs.closeSync(descriptor);
    }
    try {
      fs.unlinkSync(temporary);
    } catch {
      // The successful rename removes the temporary path.
    }
  }
}

function atomicCreateJson(file, value) {
  const parent = path.dirname(file);
  const parentBefore = fs.lstatSync(parent);
  if (parentBefore.isSymbolicLink() || !parentBefore.isDirectory()) {
    fail(`unsafe immutable-record parent directory: ${parent}`);
  }
  const temporary = path.join(
    parent,
    `.${path.basename(file)}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.candidate`,
  );
  let descriptor;
  try {
    descriptor = fs.openSync(temporary, 'wx', 0o600);
    fs.writeFileSync(descriptor, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    const parentAtCommit = fs.lstatSync(parent);
    if (!sameFileIdentity(parentBefore, parentAtCommit)) {
      fail(`immutable-record parent changed before commit: ${file}`);
    }
    try {
      // link(2) is an atomic no-clobber publication on the same filesystem.
      // Unlike rename(2), it cannot replace a planted symlink or another
      // session-start writer's already-published immutable record.
      fs.linkSync(temporary, file);
    } catch (error) {
      if (error.code === 'EEXIST') fail(`immutable record already exists: ${file}`);
      throw error;
    }
    fs.unlinkSync(temporary);
    const parentAfterCommit = fs.lstatSync(parent);
    if (!sameFileIdentity(parentBefore, parentAfterCommit)) {
      fail(`immutable-record parent changed during commit: ${file}`);
    }
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    try {
      fs.unlinkSync(temporary);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
  const final = fs.lstatSync(file);
  if (!final.isFile() || final.isSymbolicLink() || final.nlink !== 1) {
    fail(`immutable record final identity is unsafe: ${file}`);
  }
}

function workflowStateLockTarget(options) {
  const key = sessionKey(options.sessionId);
  const stateDirectory = resolveWorkflowStateDirectory(options);
  return {
    key,
    stateDirectory,
    file: path.join(stateDirectory, `${WORKFLOW_STATE_PREFIX}${key}.json`),
  };
}

function readWorkflowStateUnderLock(target) {
  if (!fs.existsSync(target.file)) {
    fail('project-bound workflow baseline is missing');
  }
  return validateWorkflowState(readJson(target.file), target.key);
}

function withWorkflowStateLock(options, callback) {
  if (typeof callback !== 'function') fail('workflow state lock callback must be a function');
  const target = workflowStateLockTarget(options);
  return withFileLock(target.stateDirectory, `state-${target.key}`, () => callback(
    readWorkflowStateUnderLock(target),
    target,
  ));
}

function commitWorkflowStateUnderLock(target, previous, options, mutation) {
  const previousRevision = previous.revision;
  if (
    options.expectedRevision !== undefined
    && (!Number.isSafeInteger(options.expectedRevision) || options.expectedRevision !== previousRevision)
  ) {
    fail(`stale workflow revision (expected ${options.expectedRevision}, current ${previousRevision})`);
  }
  const draft = mutation(JSON.parse(JSON.stringify(previous)));
  if (!draft || typeof draft !== 'object' || Array.isArray(draft)) {
    fail('workflow mutation must return an object');
  }
  const next = stampWorkflowState(
    draft,
    target.key,
    options.workflowState,
    options.event,
    options.updatedAt,
    previousRevision,
  );
  validateWorkflowState(next, target.key);
  atomicWriteJson(target.file, next);
  return next;
}

function mutateWorkflowState(options, mutation) {
  const actor = options.actor || 'main-v1';
  if (actor !== 'main-v1') {
    fail(`principal "${actor}" is denied workflow mutation`);
  }
  if (typeof mutation !== 'function') fail('workflow mutation must be a function');
  validateWorkflowToken(options.workflowState, 'workflow state');
  validateWorkflowToken(options.event, 'workflow event');
  return withWorkflowStateLock(options, (previous, target) => (
    commitWorkflowStateUnderLock(target, previous, options, mutation)
  ));
}

function initializeWorkflowState(options) {
  const key = sessionKey(options.sessionId);
  const stateDirectory = workflowStateDirectory(options.projectRoot);
  const file = path.join(stateDirectory, `${WORKFLOW_STATE_PREFIX}${key}.json`);
  return withFileLock(stateDirectory, `state-${key}`, () => {
    if (fs.existsSync(file)) return validateWorkflowState(readJson(file), key);
    const initial = stampWorkflowState({
      active: false,
      vanilla: false,
      implComplete: false,
      chainDone: false,
      codeReviewDone: false,
      selfReviewFixed: false,
      workflowActive: false,
      workflowTools: [],
      bypasses: [],
      reviewTicket: '',
      reviewTicketConsumed: true,
      reviewRound: 0,
      stopBlockCount: 0,
      deferredReviewClaim: '',
      phase: 'UNINITIALIZED',
      step_id: '',
      history: [],
    }, key, 'idle', 'session-start', undefined, 0);
    atomicWriteJson(file, initial);
    return initial;
  });
}

function transitionWorkflowState(options) {
  return mutateWorkflowState(options, (state) => state);
}

function resetReviewBudget(options) {
  if (!Number.isSafeInteger(options.expectedRevision) || options.expectedRevision < 1) {
    fail('review budget reset requires an exact expectedRevision');
  }
  return mutateWorkflowState({
    projectRoot: options.projectRoot,
    sessionId: options.sessionId,
    actor: options.actor,
    expectedRevision: options.expectedRevision,
    workflowState: 'review_rearmed',
    event: 'review-budget-reset',
  }, (state) => {
    if (state.active !== true || state.implComplete !== true) {
      fail('review budget reset requires an active completed implementation');
    }
    state.reviewRound = 0;
    state.stopBlockCount = 0;
    state.chainDone = false;
    state.codeReviewDone = false;
    state.selfReviewFixed = false;
    return state;
  });
}

function readWorkflowState(options) {
  if (options.stateDirectory !== undefined) {
    fail('workflow state directory overrides are unsupported');
  }
  const file = workflowStateFile(options.projectRoot, options.sessionId);
  return validateWorkflowState(readJson(file), options.sessionId);
}

function readWorkflowStateSnapshot(projectRoot, sessionId) {
  const file = workflowStateFile(projectRoot, sessionId);
  const snapshot = readRegularFileSnapshot(file);
  let value;
  try {
    value = JSON.parse(snapshot.data.toString('utf8'));
  } catch {
    fail(`invalid JSON: ${file}`);
  }
  return {
    file,
    snapshot,
    state: validateWorkflowState(value, sessionId),
  };
}

function canonicalControlSessionKey(input, label) {
  const value = requireText(input, label);
  const key = sessionKey(value);
  if (value !== key || !/^scv1_[a-f0-9]{64}$/.test(value)) {
    fail(`${label} must be a canonical Session Control key`);
  }
  return key;
}

function currentClaudeSessionContext(options) {
  const currentSessionId = canonicalControlSessionKey(
    options.currentSessionId,
    'current session id',
  );
  const projectRoot = canonicalDirectory(options.projectRoot, 'project root');
  const pluginRoot = canonicalDirectory(options.pluginRoot, 'plugin root');
  const runtimeDigest = requireText(options.runtimeDigest, 'runtime digest');
  if (!HASH_RE.test(runtimeDigest)) fail('runtime digest is invalid');

  const contextFile = path.resolve(requireText(options.currentContextFile, 'current context file'));
  const contextStat = fs.lstatSync(contextFile);
  if (
    !contextStat.isFile()
    || contextStat.isSymbolicLink()
    || contextStat.nlink !== 1
    || fs.realpathSync.native(contextFile) !== contextFile
  ) {
    fail('current context file is unsafe');
  }
  const recordsDir = canonicalDirectory(path.dirname(contextFile), 'records directory');
  if (contextFile !== contextRecordFile(recordsDir, currentSessionId)) {
    fail('current context file does not match the current session');
  }

  const current = readContext({
    recordsDir,
    sessionId: currentSessionId,
    expectedHost: 'claude',
  });
  const expectedRecordsDir = path.join(current.plugin_data, 'session-control', 'v1', 'records');
  if (recordsDir !== expectedRecordsDir) {
    fail('records directory is outside current Claude plugin data');
  }
  // The plugin root is the one field a compatible mid-session upgrade legitimately
  // moves. The digest pair is NOT relaxed and does not need to be: the caller is
  // handed the RECORD's own digest (claude-hook-session-v1.js exports
  // ZENSU_RUNTIME_DIGEST from binding.context.runtime_digest), so these two stay
  // equal across an upgrade while pluginRoot is the executing one. Measuring the
  // executing tree here instead would compare it against a digest the caller
  // never claimed, and refuse every command in exactly the upgraded session this
  // rule exists to keep alive.
  if (
    current.project_root !== projectRoot
    || !servesRecordedRuntime(current, pluginRoot, 'claude')
    || current.runtime_digest !== runtimeDigest
    || current.source_revision !== runtimeDigest
  ) {
    fail('current context provenance does not match the executing runtime');
  }

  return {
    currentSessionId,
    projectRoot,
    recordsDir,
    current,
  };
}

function relatedClaudeSessionContexts(options, ownerSessionId) {
  const binding = currentClaudeSessionContext(options);
  const ownerKey = canonicalControlSessionKey(ownerSessionId, 'owner session id');

  const owner = readContext({
    recordsDir: binding.recordsDir,
    sessionId: ownerKey,
    expectedHost: 'claude',
  });
  for (const field of [
    'schema',
    'schema_version',
    'host',
    'project_root',
    'plugin_root',
    'plugin_data',
    'plugin_version',
    'source_revision',
    'runtime_digest',
  ]) {
    if (owner[field] !== binding.current[field]) {
      fail(`owner context ${field} does not match current context`);
    }
  }
  if (JSON.stringify(owner.principal_profiles) !== JSON.stringify(binding.current.principal_profiles)) {
    fail('owner context principal profiles do not match current context');
  }

  return {
    ...binding,
    ownerSessionId: ownerKey,
    owner,
  };
}

function deferredReviewClaimFile(options, projectRoot, allowMissing = false) {
  const stateDirectory = workflowStateDirectory(projectRoot);
  const expectedFile = path.join(stateDirectory, 'pending-review.json.claim');
  const claimFile = path.resolve(requireText(options.claimFile, 'claim file'));
  if (claimFile !== expectedFile) {
    fail('deferred-review claim path is invalid');
  }
  let claimStat;
  try {
    claimStat = fs.lstatSync(claimFile);
  } catch (error) {
    if (error.code === 'ENOENT' && allowMissing) return claimFile;
    if (error.code === 'ENOENT') fail('deferred-review claim is missing');
    throw error;
  }
  if (claimStat.nlink !== 1) {
    fail('multi-linked deferred-review claim rejected');
  }
  if (
    claimStat.isSymbolicLink()
    || !claimStat.isFile()
    || fs.realpathSync.native(claimFile) !== claimFile
  ) {
    fail('deferred-review claim path is invalid');
  }
  return claimFile;
}

function deferredReviewResetBindingIsValid(binding) {
  const keys = ['attempt', 'chainId', 'runId'];
  return binding === null || (
    binding
    && typeof binding === 'object'
    && !Array.isArray(binding)
    && Object.keys(binding).sort().join(',') === keys.join(',')
    && Number.isSafeInteger(binding.attempt)
    && binding.attempt >= 1
    && binding.attempt <= 999
    && /^[A-Za-z0-9][A-Za-z0-9_.:-]{2,127}$/.test(binding.runId || '')
    && /^[A-Za-z0-9][A-Za-z0-9_.:-]{2,127}$/.test(binding.chainId || '')
  );
}

function validateDeferredReviewClaimValue(claim) {
  if (!claim || typeof claim !== 'object' || Array.isArray(claim)) {
    fail('deferred-review claim must be an object');
  }
  if (
    typeof claim.claimId !== 'string'
    || !/^dc_[A-Za-z0-9_-]+$/.test(claim.claimId)
    || claim.claimId.length > 96
  ) {
    fail('deferred-review claim id is invalid');
  }
  canonicalControlSessionKey(claim.ownerSessionId, 'deferred-review owner');
  if (!Number.isSafeInteger(claim.ownerPid) || claim.ownerPid <= 0) {
    fail('deferred-review owner pid is invalid');
  }
  if (
    claim.ownerProcessStartIdentity !== null
    && (
      typeof claim.ownerProcessStartIdentity !== 'string'
      || !LOCK_IDENTITY_RE.test(claim.ownerProcessStartIdentity)
    )
  ) {
    fail('deferred-review owner process identity is invalid');
  }
  if (typeof claim.handoffEmitted !== 'boolean') {
    fail('deferred-review handoff flag is invalid');
  }
  if (claim.transfer !== undefined && claim.cancellation !== undefined) {
    fail('deferred-review cancellation and transfer receipts are mutually exclusive');
  }
  if (claim.cancellation !== undefined) {
    const cancellation = claim.cancellation;
    const keys = [
      'cancellationId',
      'claimId',
      'clearedOwnerRevision',
      'mode',
      'origin',
      'ownerRevision',
      'ownerSessionId',
      'resetBinding',
      'schemaVersion',
      'stage',
    ];
    const resetBinding = cancellation && cancellation.resetBinding;
    if (
      !cancellation
      || typeof cancellation !== 'object'
      || Array.isArray(cancellation)
      || Object.keys(cancellation).sort().join(',') !== keys.join(',')
      || cancellation.schemaVersion !== 1
      || !['prepared', 'state-cleared'].includes(cancellation.stage)
      || !/^drc_[A-Za-z0-9_-]+$/.test(cancellation.cancellationId || '')
      || cancellation.cancellationId.length > 96
      || cancellation.claimId !== claim.claimId
      || cancellation.ownerSessionId !== claim.ownerSessionId
      || !['release-only', 'reset'].includes(cancellation.mode)
      || !['linked', 'unseeded'].includes(cancellation.origin)
      || (cancellation.mode === 'release-only' && cancellation.origin !== 'linked')
      || (cancellation.origin === 'unseeded' && claim.handoffEmitted !== false)
      || !Number.isSafeInteger(cancellation.ownerRevision)
      || cancellation.ownerRevision < 1
      || (
        cancellation.stage === 'prepared'
          ? cancellation.clearedOwnerRevision !== null
          : cancellation.clearedOwnerRevision !== cancellation.ownerRevision + 1
      )
      || !deferredReviewResetBindingIsValid(resetBinding)
      || (cancellation.mode === 'release-only' && cancellation.resetBinding !== null)
    ) {
      fail('deferred-review cancellation receipt is invalid');
    }
    canonicalControlSessionKey(cancellation.ownerSessionId, 'cancellation owner');
  }
  if (claim.transfer !== undefined) {
    const transfer = claim.transfer;
    const keys = [
      'claimId',
      'fromOwnerRevision',
      'fromOwnerSessionId',
      'retiredOwnerRevision',
      'schemaVersion',
      'stage',
      'toOwnerSessionId',
    ];
    if (
      !transfer
      || typeof transfer !== 'object'
      || Array.isArray(transfer)
      || Object.keys(transfer).sort().join(',') !== keys.sort().join(',')
      || transfer.schemaVersion !== 1
      || transfer.claimId !== claim.claimId
      || !['prepared', 'owner-retired'].includes(transfer.stage)
      || !Number.isSafeInteger(transfer.fromOwnerRevision)
      || transfer.fromOwnerRevision < 1
      || (
        transfer.stage === 'prepared'
          ? transfer.retiredOwnerRevision !== null
          : transfer.retiredOwnerRevision !== transfer.fromOwnerRevision + 1
      )
    ) {
      fail('deferred-review transfer receipt is invalid');
    }
    canonicalControlSessionKey(transfer.fromOwnerSessionId, 'transfer source owner');
    canonicalControlSessionKey(transfer.toOwnerSessionId, 'transfer target owner');
    if (
      transfer.fromOwnerSessionId === transfer.toOwnerSessionId
      || ![transfer.fromOwnerSessionId, transfer.toOwnerSessionId].includes(claim.ownerSessionId)
    ) {
      fail('deferred-review transfer receipt ownership is inconsistent');
    }
  }
  return claim;
}

function readDeferredReviewClaimSnapshot(options, projectRoot) {
  const claimFile = deferredReviewClaimFile(options, projectRoot);
  const snapshot = readRegularFileSnapshot(claimFile);
  let claim;
  try {
    claim = JSON.parse(snapshot.data.toString('utf8'));
  } catch {
    fail(`invalid JSON: ${claimFile}`);
  }
  return {
    claimFile,
    snapshot,
    claim: validateDeferredReviewClaimValue(claim),
  };
}

function readDeferredReviewClaim(options, projectRoot) {
  return readDeferredReviewClaimSnapshot(options, projectRoot).claim;
}

function withDeferredReviewClaimLock(projectRoot, callback) {
  if (typeof callback !== 'function') fail('deferred-review claim lock callback must be a function');
  const stateDirectory = workflowStateDirectory(projectRoot);
  return withFileLock(stateDirectory, 'deferred-review-claim', callback);
}

function requireDeferredReviewClaimSnapshot(options, projectRoot, expected, message) {
  const latest = readDeferredReviewClaimSnapshot(options, projectRoot);
  if (!sameRegularSnapshot(latest.snapshot, expected.snapshot)) {
    fail(message);
  }
  return latest;
}

function deferredOwnerProcessIsAlive(claim) {
  if (!processIsAlive(claim.ownerPid)) return false;
  if (!claim.ownerProcessStartIdentity) return true;
  const actual = claim.ownerPid === process.pid
    ? currentProcessStartIdentity()
    : processStartIdentity(claim.ownerPid);
  return actual === null || actual === claim.ownerProcessStartIdentity;
}

function deferredReviewStateIsIdle(state) {
  return state.active === false
    && state.implComplete === false
    && state.chainDone === false
    && state.codeReviewDone === false
    && state.selfReviewFixed === false
    && state.reviewTicket === ''
    && state.reviewTicketConsumed === true
    && state.reviewRound === 0
    && state.stopBlockCount === 0
    && state.deferredReviewClaim === '';
}

function deferredReviewStateCanSeed(state) {
  return deferredReviewStateIsIdle(state) || state.chainDone === true;
}

function deferredReviewStateIsRetired(state, transfer) {
  return state.revision === transfer.fromOwnerRevision + 1
    && state.last_event === 'deferred-review-transfer'
    && deferredReviewStateIsIdle(state);
}

function deferredReviewClaimIsStale(claimSnapshot, ttlHours) {
  if (!Number.isSafeInteger(ttlHours) || ttlHours < 0 || ttlHours > 8760) {
    fail('deferred-review ownership ttl is invalid');
  }
  if (ttlHours === 0) return false;
  const claimTimestamp = typeof claimSnapshot.claim.ts === 'string'
    ? Date.parse(claimSnapshot.claim.ts)
    : Number.NaN;
  const timestamp = Number.isFinite(claimTimestamp)
    ? claimTimestamp
    : claimSnapshot.snapshot.stat.mtimeMs;
  return Number.isFinite(timestamp)
    && Date.now() - timestamp >= ttlHours * 60 * 60 * 1000;
}

// A contending Stop hook needs a cheap, mutation-free proof that another
// session already owns the deferred review. Keep this separate from
// inspectDeferredReviewOwner(): that recovery API may advance transfer or
// cancellation receipts. Two descriptor-backed snapshots on each artifact
// provide one stable overlap without joining the contended Outer lock or
// introducing a second lock queue.
function deferredReviewOwnedByOther(options) {
  const binding = currentClaudeSessionContext(options);
  const ttlHours = options.ttlHours;
  if (!Number.isSafeInteger(ttlHours) || ttlHours < 0 || ttlHours > 8760) {
    fail('deferred-review ownership ttl is invalid');
  }

  const firstClaim = readDeferredReviewClaimSnapshot(options, binding.projectRoot);
  const claim = firstClaim.claim;
  if (
    claim.ownerSessionId === binding.currentSessionId
    || claim.transfer !== undefined
    || claim.cancellation !== undefined
  ) {
    return false;
  }

  const contexts = relatedClaudeSessionContexts(options, claim.ownerSessionId);
  const firstState = readWorkflowStateSnapshot(
    contexts.projectRoot,
    contexts.ownerSessionId,
  );
  const secondClaim = readDeferredReviewClaimSnapshot(options, binding.projectRoot);
  const secondState = readWorkflowStateSnapshot(
    contexts.projectRoot,
    contexts.ownerSessionId,
  );
  if (
    !sameRegularSnapshot(firstClaim.snapshot, secondClaim.snapshot)
    || !sameRegularSnapshot(firstState.snapshot, secondState.snapshot)
  ) {
    return false;
  }

  const stableClaim = secondClaim.claim;
  const state = secondState.state;
  if (
    stableClaim.ownerSessionId !== contexts.ownerSessionId
    || stableClaim.transfer !== undefined
    || stableClaim.cancellation !== undefined
  ) {
    return false;
  }

  const ownerAlive = deferredOwnerProcessIsAlive(stableClaim);
  if (state.deferredReviewClaim !== stableClaim.claimId) {
    return stableClaim.handoffEmitted === false
      && deferredReviewStateCanSeed(state)
      && ownerAlive;
  }
  if (state.chainDone === true || state.active !== true || state.implComplete !== true) {
    return false;
  }
  return ownerAlive || (
    stableClaim.handoffEmitted === true
    && !deferredReviewClaimIsStale(secondClaim, ttlHours)
  );
}

function cancelStalePreparedDeferredReviewTransfer(options, claim, inspectedState) {
  const transfer = claim.transfer;
  if (!transfer || transfer.stage !== 'prepared') {
    fail('stale deferred-review transfer cancellation requires a prepared receipt');
  }
  const projectRoot = canonicalDirectory(options.projectRoot, 'project root');
  const expected = readDeferredReviewClaimSnapshot(options, projectRoot);
  if (!sameClaimValue(expected.claim, claim)) {
    fail('deferred-review claim changed before stale transfer cancellation');
  }
  return withDeferredReviewClaimLock(projectRoot, () => (
    withWorkflowStateLock({
      projectRoot,
      sessionId: transfer.fromOwnerSessionId,
    }, (lockedState) => {
      if (lockedState.revision !== inspectedState.revision) {
        fail('source state changed before stale transfer cancellation');
      }
      if (deferredReviewStateIsRetired(lockedState, transfer)) {
        fail('retired deferred-review transfer cannot be cancelled');
      }
      const latest = requireDeferredReviewClaimSnapshot(
        options,
        projectRoot,
        expected,
        'deferred-review claim changed before stale transfer cancellation',
      );
      if (!sameClaimValue(latest.claim, claim)) {
        fail('deferred-review claim changed before stale transfer cancellation');
      }
      delete latest.claim.transfer;
      atomicWriteJson(latest.claimFile, latest.claim);
      return readDeferredReviewClaim(options, projectRoot);
    })
  ));
}

function inspectDeferredReviewOwner(options) {
  if (typeof options.claimStale !== 'boolean') fail('claimStale must be boolean');
  const projectRoot = canonicalDirectory(options.projectRoot, 'project root');
  const claim = readDeferredReviewClaim(options, projectRoot);
  const contexts = relatedClaudeSessionContexts(options, claim.ownerSessionId);
  const state = readWorkflowState({
    projectRoot: contexts.projectRoot,
    sessionId: contexts.ownerSessionId,
  });

  if (claim.cancellation) {
    const linked = state.deferredReviewClaim === claim.claimId;
    const cleared = stateHasDeferredReviewCancellation(state, claim.cancellation);
    const unseededPrepared = stateMatchesPreparedUnseededCancellation(
      state,
      claim,
      claim.cancellation,
    );
    const recoverableUnseededReceipt = claim.cancellation.stage === 'prepared'
      && claim.cancellation.origin === 'unseeded';
    const coherent = claim.cancellation.stage === 'prepared'
      ? linked || cleared || unseededPrepared || recoverableUnseededReceipt
      : cleared;
    if (!coherent) {
      fail('deferred-review cancellation state does not match its receipt');
    }
    if (cleared) {
      return { status: 'cancelled', ownerRevision: state.revision, claim };
    }
    return { status: 'cancelling', ownerRevision: state.revision, claim };
  }

  if (claim.transfer) {
    const transfer = claim.transfer;
    // A durable receipt is a single-target recovery capability. Other
    // principals may observe it, but must never continue or steal it.
    relatedClaudeSessionContexts(options, transfer.fromOwnerSessionId);
    relatedClaudeSessionContexts(options, transfer.toOwnerSessionId);
    if (contexts.currentSessionId !== transfer.toOwnerSessionId) {
      return { status: 'owned', ownerRevision: state.revision, claim };
    }
    if (claim.ownerSessionId === transfer.fromOwnerSessionId) {
      if (
        transfer.stage === 'prepared'
        && state.revision === transfer.fromOwnerRevision
        && state.active === true
        && state.implComplete === true
        && state.chainDone === false
        && state.deferredReviewClaim === claim.claimId
      ) {
        return { status: 'transfer', ownerRevision: state.revision, claim };
      }
      if (deferredReviewStateIsRetired(state, transfer)) {
        return { status: 'owner-retired', ownerRevision: state.revision, claim };
      }
      if (transfer.stage === 'prepared') {
        cancelStalePreparedDeferredReviewTransfer(options, claim, state);
        return inspectDeferredReviewOwner(options);
      }
      fail('deferred-review transfer source state does not match its receipt');
    }
    if (
      claim.ownerSessionId !== transfer.toOwnerSessionId
      || transfer.stage !== 'owner-retired'
    ) {
      fail('deferred-review transfer target ownership is invalid');
    }
    if (state.deferredReviewClaim === claim.claimId) {
      if (state.active !== true || state.implComplete !== true || state.chainDone !== false) {
        fail('deferred-review transfer target state is inconsistent');
      }
      return { status: 'current', ownerRevision: state.revision, claim };
    }
    if (deferredReviewStateIsIdle(state)) {
      return { status: 'unseeded', ownerRevision: state.revision, claim };
    }
    fail('deferred-review transfer target state does not match its receipt');
  }

  const ownerAlive = deferredOwnerProcessIsAlive(claim);
  const exactClaim = state.deferredReviewClaim === claim.claimId;
  if (!exactClaim) {
    if (claim.handoffEmitted === true) {
      return { status: 'cancelled', ownerRevision: state.revision, claim };
    }
    if (deferredReviewStateCanSeed(state) && !ownerAlive) {
      return { status: 'unseeded', ownerRevision: state.revision, claim };
    }
    if (deferredReviewStateCanSeed(state) && ownerAlive) {
      return { status: 'owned', ownerRevision: state.revision, claim };
    }
    fail('deferred-review claim does not match its owner workflow state');
  }
  if (state.chainDone === true) {
    return { status: 'done', ownerRevision: state.revision, claim };
  }
  if (state.active !== true || state.implComplete !== true) {
    fail('deferred-review owner workflow state is not transferable');
  }
  if (contexts.ownerSessionId === contexts.currentSessionId) {
    return { status: 'current', ownerRevision: state.revision, claim };
  }
  if (ownerAlive || (claim.handoffEmitted === true && options.claimStale !== true)) {
    return { status: 'owned', ownerRevision: state.revision, claim };
  }
  return { status: 'transfer', ownerRevision: state.revision, claim };
}

function retireDeferredReviewOwner(options) {
  const expectedRevision = options.expectedRevision;
  if (!Number.isSafeInteger(expectedRevision) || expectedRevision < 1) {
    fail('expected owner revision is invalid');
  }
  const projectRoot = canonicalDirectory(options.projectRoot, 'project root');
  const expectedClaim = readDeferredReviewClaimSnapshot(options, projectRoot);
  const claim = expectedClaim.claim;
  if (
    !claim.transfer
    || claim.transfer.stage !== 'prepared'
    || claim.transfer.claimId !== claim.claimId
    || claim.transfer.fromOwnerSessionId !== claim.ownerSessionId
    || claim.transfer.toOwnerSessionId !== options.currentSessionId
    || claim.transfer.fromOwnerRevision !== expectedRevision
  ) {
    fail('prepared transfer receipt does not match retirement request');
  }
  const contexts = relatedClaudeSessionContexts(options, claim.ownerSessionId);
  const current = readWorkflowState({
    projectRoot: contexts.projectRoot,
    sessionId: contexts.ownerSessionId,
  });
  const alreadyRetired = deferredReviewStateIsRetired(current, claim.transfer);
  if (alreadyRetired) return current;
  if (typeof options.claimStale !== 'boolean') fail('claimStale must be boolean');
  if (
    deferredOwnerProcessIsAlive(claim)
    || (claim.handoffEmitted === true && options.claimStale !== true)
  ) {
    fail('deferred-review owner is still live or its handoff lease is fresh');
  }
  if (
    current.revision !== expectedRevision
    || current.active !== true
    || current.implComplete !== true
    || current.chainDone !== false
    || current.deferredReviewClaim !== claim.claimId
  ) {
    fail('deferred-review owner changed before retirement');
  }
  return withDeferredReviewClaimLock(projectRoot, () => (
    withWorkflowStateLock({
      projectRoot: contexts.projectRoot,
      sessionId: contexts.ownerSessionId,
    }, (state, target) => {
      if (
        state.revision !== expectedRevision
        || state.active !== true
        || state.implComplete !== true
        || state.chainDone !== false
        || state.deferredReviewClaim !== claim.claimId
      ) {
        fail('deferred-review owner changed during retirement');
      }
      const latest = requireDeferredReviewClaimSnapshot(
        options,
        projectRoot,
        expectedClaim,
        'deferred-review claim changed during retirement',
      );
      if (!sameClaimValue(latest.claim, claim)) {
        fail('deferred-review claim changed during retirement');
      }
      if (
        deferredOwnerProcessIsAlive(latest.claim)
        || (latest.claim.handoffEmitted === true && options.claimStale !== true)
      ) {
        fail('deferred-review owner became live before retirement');
      }
      return commitWorkflowStateUnderLock(target, state, {
        expectedRevision,
        workflowState: state.workflow_state,
        event: 'deferred-review-transfer',
      }, (draft) => {
        draft.active = false;
        draft.implComplete = false;
        draft.chainDone = false;
        draft.codeReviewDone = false;
        draft.selfReviewFixed = false;
        draft.reviewTicket = '';
        draft.reviewTicketConsumed = true;
        draft.reviewRound = 0;
        draft.stopBlockCount = 0;
        draft.deferredReviewClaim = '';
        return draft;
      });
    })
  ));
}

function sameClaimValue(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function processStartIdentityForPid(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) {
    fail('process id is invalid');
  }
  return processStartIdentity(pid);
}

function prepareDeferredReviewTransfer(options) {
  const inspection = inspectDeferredReviewOwner(options);
  if (!['transfer', 'owner-retired'].includes(inspection.status)) {
    fail('deferred-review claim is not eligible for transfer preparation');
  }
  const claim = inspection.claim;
  if (claim.transfer) {
    if (
      claim.transfer.toOwnerSessionId !== options.currentSessionId
      || claim.transfer.fromOwnerRevision !== (
        inspection.status === 'owner-retired'
          ? inspection.ownerRevision - 1
          : inspection.ownerRevision
      )
    ) {
      fail('existing deferred-review transfer receipt does not match recovery');
    }
    return claim;
  }
  const projectRoot = canonicalDirectory(options.projectRoot, 'project root');
  const currentSessionId = canonicalControlSessionKey(options.currentSessionId, 'current session id');
  const expected = readDeferredReviewClaimSnapshot(options, projectRoot);
  if (!sameClaimValue(expected.claim, claim)) {
    fail('deferred-review claim changed before transfer preparation');
  }
  return withDeferredReviewClaimLock(projectRoot, () => (
    withWorkflowStateLock({
      projectRoot,
      sessionId: claim.ownerSessionId,
    }, (state) => {
      if (
        state.revision !== inspection.ownerRevision
        || state.active !== true
        || state.implComplete !== true
        || state.chainDone !== false
        || state.deferredReviewClaim !== claim.claimId
      ) {
        fail('source state changed before transfer preparation');
      }
      const latest = requireDeferredReviewClaimSnapshot(
        options,
        projectRoot,
        expected,
        'deferred-review claim changed before transfer preparation',
      );
      if (!sameClaimValue(latest.claim, claim)) {
        fail('deferred-review claim changed before transfer preparation');
      }
      latest.claim.transfer = {
        schemaVersion: 1,
        stage: 'prepared',
        claimId: latest.claim.claimId,
        fromOwnerSessionId: latest.claim.ownerSessionId,
        toOwnerSessionId: currentSessionId,
        fromOwnerRevision: inspection.ownerRevision,
        retiredOwnerRevision: null,
      };
      atomicWriteJson(latest.claimFile, latest.claim);
      return readDeferredReviewClaim(options, projectRoot);
    })
  ));
}

function markDeferredReviewOwnerRetired(options) {
  const expectedRevision = options.expectedRevision;
  if (!Number.isSafeInteger(expectedRevision) || expectedRevision < 1) {
    fail('expected owner revision is invalid');
  }
  const inspection = inspectDeferredReviewOwner(options);
  if (inspection.status !== 'owner-retired') {
    fail('deferred-review owner retirement is not durable');
  }
  const claim = inspection.claim;
  if (
    !claim.transfer
    || claim.transfer.fromOwnerRevision !== expectedRevision
    || claim.transfer.toOwnerSessionId !== options.currentSessionId
  ) {
    fail('deferred-review retirement receipt does not match the request');
  }
  if (claim.transfer.stage === 'owner-retired') return claim;
  const projectRoot = canonicalDirectory(options.projectRoot, 'project root');
  const expected = readDeferredReviewClaimSnapshot(options, projectRoot);
  if (!sameClaimValue(expected.claim, claim)) {
    fail('deferred-review claim changed before retirement acknowledgement');
  }
  return withDeferredReviewClaimLock(projectRoot, () => (
    withWorkflowStateLock({
      projectRoot,
      sessionId: claim.transfer.fromOwnerSessionId,
    }, (state) => {
      if (
        state.revision !== inspection.ownerRevision
        || !deferredReviewStateIsRetired(state, claim.transfer)
      ) {
        fail('source state changed before retirement acknowledgement');
      }
      const latest = requireDeferredReviewClaimSnapshot(
        options,
        projectRoot,
        expected,
        'deferred-review claim changed before retirement acknowledgement',
      );
      if (!sameClaimValue(latest.claim, claim)) {
        fail('deferred-review claim changed before retirement acknowledgement');
      }
      latest.claim.transfer.stage = 'owner-retired';
      latest.claim.transfer.retiredOwnerRevision = expectedRevision + 1;
      atomicWriteJson(latest.claimFile, latest.claim);
      return readDeferredReviewClaim(options, projectRoot);
    })
  ));
}

function unassignedDeferredReviewClaim(options, projectRoot) {
  const claimFile = deferredReviewClaimFile(options, projectRoot);
  const value = JSON.parse(readRegularFile(claimFile).toString('utf8'));
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail('pending deferred-review marker must be an object');
  }
  const ownershipFields = [
    'claimId',
    'ownerSessionId',
    'ownerPid',
    'ownerProcessStartIdentity',
    'handoffEmitted',
    'transfer',
    'cancellation',
  ];
  if (ownershipFields.some((field) => Object.prototype.hasOwnProperty.call(value, field))) {
    return null;
  }
  if (
    !Array.isArray(value.files)
    || value.files.some((file) => typeof file !== 'string' || /[\u0000-\u001f\u007f]/.test(file))
    || typeof value.summary !== 'string'
    || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(value.summary)
    || (
      value.ts !== undefined
      && (typeof value.ts !== 'string' || !Number.isFinite(Date.parse(value.ts)))
    )
  ) {
    fail('pending deferred-review marker payload is invalid');
  }
  return value;
}

function assignDeferredReviewClaim(options) {
  const binding = currentClaudeSessionContext(options);
  const ownerPid = options.ownerPid;
  if (!Number.isSafeInteger(ownerPid) || ownerPid <= 0) {
    fail('deferred-review assignee process id is invalid');
  }
  if (!processIsAlive(ownerPid)) {
    fail('deferred-review assignee process is not alive');
  }
  if (typeof options.claimStale !== 'boolean') fail('claimStale must be boolean');
  if (!['none', 'relative', 'wall'].includes(options.logStyle)) {
    fail('deferred-review log style is invalid');
  }
  const claimFile = deferredReviewClaimFile(options, binding.projectRoot);
  let expectedSnapshot;
  let expectedValue;
  let claimId;
  let unassigned = false;
  let claim = unassignedDeferredReviewClaim(options, binding.projectRoot);
  if (claim) {
    if (options.claimStale) fail('stale unassigned deferred-review marker must not be adopted');
    unassigned = true;
    expectedSnapshot = readRegularFileSnapshot(claimFile);
    try {
      expectedValue = JSON.parse(expectedSnapshot.data.toString('utf8'));
    } catch {
      fail(`invalid JSON: ${claimFile}`);
    }
    if (!sameClaimValue(expectedValue, claim)) {
      fail('deferred-review marker changed before claim assignment');
    }
    claimId = `dc_${crypto.randomBytes(16).toString('hex')}`;
  } else {
    const inspection = inspectDeferredReviewOwner(options);
    if (!['unseeded', 'owner-retired'].includes(inspection.status)) {
      fail('deferred-review claim is not assignable');
    }
    claim = inspection.claim;
    if (claim.transfer) {
      if (
        claim.transfer.stage !== 'owner-retired'
        || claim.transfer.toOwnerSessionId !== binding.currentSessionId
        || ![
          claim.transfer.fromOwnerSessionId,
          claim.transfer.toOwnerSessionId,
        ].includes(claim.ownerSessionId)
      ) {
        fail('deferred-review transfer receipt is not assignable');
      }
    } else if (inspection.status !== 'unseeded') {
      fail('deferred-review transfer receipt is missing');
    }
    const expected = readDeferredReviewClaimSnapshot(options, binding.projectRoot);
    if (!sameClaimValue(expected.claim, claim)) {
      fail('deferred-review claim changed before claim assignment');
    }
    expectedSnapshot = expected.snapshot;
    expectedValue = expected.claim;
    claimId = claim.claimId;
  }
  const targetState = readWorkflowState({
    projectRoot: binding.projectRoot,
    sessionId: binding.currentSessionId,
  });
  if (!deferredReviewStateCanSeed(targetState)) {
    fail('deferred-review assignee state cannot begin a new generation');
  }
  return withDeferredReviewClaimLock(binding.projectRoot, () => (
    withWorkflowStateLock({
      projectRoot: binding.projectRoot,
      sessionId: binding.currentSessionId,
    }, (state) => {
      if (
        state.revision !== targetState.revision
        || !deferredReviewStateCanSeed(state)
      ) {
        fail('target state changed before claim assignment');
      }
      const latestSnapshot = readRegularFileSnapshot(claimFile);
      if (!sameRegularSnapshot(latestSnapshot, expectedSnapshot)) {
        fail('deferred-review claim changed before claim assignment');
      }
      let latest;
      try {
        latest = JSON.parse(latestSnapshot.data.toString('utf8'));
      } catch {
        fail(`invalid JSON: ${claimFile}`);
      }
      if (!sameClaimValue(latest, expectedValue)) {
        fail('deferred-review claim changed before claim assignment');
      }
      if (!unassigned) validateDeferredReviewClaimValue(latest);
      latest.claimId = claimId;
      latest.ownerSessionId = binding.currentSessionId;
      if (!processIsAlive(ownerPid)) {
        fail('deferred-review assignee process is not alive before publication');
      }
      latest.ownerPid = ownerPid;
      latest.ownerProcessStartIdentity = processStartIdentity(ownerPid);
      latest.handoffEmitted = false;
      if (options.logStyle === 'none') delete latest.ts;
      else latest.ts = nowIso().replace(/\.\d{3}Z$/, 'Z');
      validateDeferredReviewClaimValue(latest);
      atomicWriteJson(claimFile, latest);
      return readDeferredReviewClaim(options, binding.projectRoot);
    })
  ));
}

function finalizeDeferredReviewTransfer(options) {
  const binding = currentClaudeSessionContext(options);
  const expected = readDeferredReviewClaimSnapshot(options, binding.projectRoot);
  const claim = expected.claim;
  if (!claim.transfer) return claim;
  if (
    claim.ownerSessionId !== binding.currentSessionId
    || claim.transfer.toOwnerSessionId !== binding.currentSessionId
    || claim.transfer.stage !== 'owner-retired'
  ) {
    fail('deferred-review transfer cannot be finalized by this principal');
  }
  const targetState = readWorkflowState({
    projectRoot: binding.projectRoot,
    sessionId: binding.currentSessionId,
  });
  if (
    targetState.active !== true
    || targetState.implComplete !== true
    || targetState.chainDone !== false
    || targetState.deferredReviewClaim !== claim.claimId
  ) {
    fail('deferred-review transfer target was not seeded');
  }
  return withDeferredReviewClaimLock(binding.projectRoot, () => (
    withWorkflowStateLock({
      projectRoot: binding.projectRoot,
      sessionId: binding.currentSessionId,
    }, (state) => {
      if (
        state.revision !== targetState.revision
        || state.active !== true
        || state.implComplete !== true
        || state.chainDone !== false
        || state.deferredReviewClaim !== claim.claimId
      ) {
        fail('target state changed before transfer finalization');
      }
      const latest = requireDeferredReviewClaimSnapshot(
        options,
        binding.projectRoot,
        expected,
        'deferred-review claim changed before transfer finalization',
      );
      if (!sameClaimValue(latest.claim, claim)) {
        fail('deferred-review claim changed before transfer finalization');
      }
      delete latest.claim.transfer;
      atomicWriteJson(latest.claimFile, latest.claim);
      return readDeferredReviewClaim(options, binding.projectRoot);
    })
  ));
}

function acknowledgeDeferredReviewHandoff(options) {
  const binding = currentClaudeSessionContext(options);
  const ownerPid = options.ownerPid;
  if (!Number.isSafeInteger(ownerPid) || ownerPid <= 0) {
    fail('deferred-review handoff process id is invalid');
  }
  if (!processIsAlive(ownerPid)) {
    fail('deferred-review handoff process is not alive');
  }
  if (!['none', 'relative', 'wall'].includes(options.logStyle)) {
    fail('deferred-review log style is invalid');
  }
  const targetState = readWorkflowState({
    projectRoot: binding.projectRoot,
    sessionId: binding.currentSessionId,
  });
  if (targetState.deferredReviewClaim === '') {
    return withWorkflowStateLock({
      projectRoot: binding.projectRoot,
      sessionId: binding.currentSessionId,
    }, (state) => {
      if (
        state.revision !== targetState.revision
        || state.deferredReviewClaim !== ''
      ) {
        fail('target state changed before handoff acknowledgement');
      }
      return null;
    });
  }
  const expected = readDeferredReviewClaimSnapshot(options, binding.projectRoot);
  const claim = expected.claim;
  if (
    claim.ownerSessionId !== binding.currentSessionId
    || claim.claimId !== targetState.deferredReviewClaim
  ) {
    fail('deferred-review handoff claim does not match its target state');
  }
  if (
    claim.transfer
    && (
      claim.transfer.stage !== 'owner-retired'
      || claim.transfer.toOwnerSessionId !== binding.currentSessionId
    )
  ) {
    fail('deferred-review transfer cannot be acknowledged by this principal');
  }
  return withDeferredReviewClaimLock(binding.projectRoot, () => (
    withWorkflowStateLock({
      projectRoot: binding.projectRoot,
      sessionId: binding.currentSessionId,
    }, (state) => {
      if (
        state.revision !== targetState.revision
        || state.active !== true
        || state.implComplete !== true
        || state.chainDone !== false
        || state.deferredReviewClaim !== claim.claimId
      ) {
        fail('target state changed before handoff acknowledgement');
      }
      const latest = requireDeferredReviewClaimSnapshot(
        options,
        binding.projectRoot,
        expected,
        'deferred-review claim changed before handoff acknowledgement',
      );
      if (
        !sameClaimValue(latest.claim, claim)
        || latest.claim.ownerSessionId !== binding.currentSessionId
        || latest.claim.claimId !== state.deferredReviewClaim
      ) {
        fail('deferred-review claim changed before handoff acknowledgement');
      }
      if (
        latest.claim.transfer
        && (
          latest.claim.transfer.stage !== 'owner-retired'
          || latest.claim.transfer.toOwnerSessionId !== binding.currentSessionId
        )
      ) {
        fail('deferred-review transfer changed before handoff acknowledgement');
      }
      if (!processIsAlive(ownerPid)) {
        fail('deferred-review handoff process is not alive before publication');
      }
      latest.claim.ownerPid = ownerPid;
      latest.claim.ownerProcessStartIdentity = processStartIdentity(ownerPid);
      latest.claim.handoffEmitted = true;
      if (options.logStyle === 'none') delete latest.claim.ts;
      else latest.claim.ts = nowIso().replace(/\.\d{3}Z$/, 'Z');
      delete latest.claim.transfer;
      atomicWriteJson(latest.claimFile, latest.claim);
      return readDeferredReviewClaim(options, binding.projectRoot);
    })
  ));
}

function deferredReviewCancellationOptions(options) {
  const mode = options.mode;
  if (!['release-only', 'reset'].includes(mode)) {
    fail('deferred-review cancellation mode is invalid');
  }
  const resetBinding = options.resetBinding === undefined ? null : options.resetBinding;
  if (
    !deferredReviewResetBindingIsValid(resetBinding)
    || (mode === 'release-only' && resetBinding !== null)
  ) {
    fail('deferred-review cancellation reset binding is invalid');
  }
  return { mode, resetBinding };
}

function sameDeferredReviewResetBinding(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function deferredReviewCancellationMarker(receipt) {
  return {
    schemaVersion: 1,
    cancellationId: receipt.cancellationId,
    claimId: receipt.claimId,
    ownerSessionId: receipt.ownerSessionId,
    mode: receipt.mode,
    origin: receipt.origin,
    sourceRevision: receipt.ownerRevision,
    resultRevision: receipt.ownerRevision + 1,
    resetBinding: receipt.resetBinding,
  };
}

function stateHasDeferredReviewCancellation(state, receipt) {
  return sameClaimValue(
    state.deferredReviewCancellation,
    deferredReviewCancellationMarker(receipt),
  ) && state.deferredReviewClaim === '';
}

function stateMatchesDeferredReviewResetBinding(state, resetBinding) {
  const linkKeys = [
    'autopilotRunId',
    'autopilotAttempt',
    'autopilotReturnStage',
    'chainId',
    'chainOutcome',
  ];
  if (resetBinding === null) {
    return linkKeys.every((key) => !Object.prototype.hasOwnProperty.call(state, key));
  }
  return state.autopilotRunId === resetBinding.runId
    && state.autopilotAttempt === resetBinding.attempt
    && state.chainId === resetBinding.chainId;
}

function stateCanBeginUnseededDeferredReviewReset(state, claim, request) {
  return request.mode === 'reset'
    && claim.handoffEmitted === false
    && state.deferredReviewClaim === ''
    && deferredReviewStateCanSeed(state)
    && stateMatchesDeferredReviewResetBinding(state, request.resetBinding);
}

function stateMatchesPreparedUnseededCancellation(state, claim, receipt) {
  return receipt.stage === 'prepared'
    && receipt.mode === 'reset'
    && receipt.origin === 'unseeded'
    && receipt.claimId === claim.claimId
    && receipt.ownerSessionId === claim.ownerSessionId
    && receipt.ownerRevision === state.revision
    && claim.handoffEmitted === false
    && state.deferredReviewClaim === ''
    && deferredReviewStateCanSeed(state)
    && stateMatchesDeferredReviewResetBinding(state, receipt.resetBinding);
}

function claimIsAssignedUnseededTransferTarget(claim, currentSessionId) {
  return Boolean(claim.transfer)
    && claim.ownerSessionId === currentSessionId
    && claim.transfer.stage === 'owner-retired'
    && claim.transfer.toOwnerSessionId === currentSessionId;
}

function resetDeferredReviewState(state) {
  state.active = false;
  state.implComplete = false;
  state.chainDone = false;
  state.codeReviewDone = false;
  state.selfReviewFixed = false;
  state.workflowActive = false;
  state.workflowTools = [];
  state.vanilla = false;
  state.bypasses = [];
  state.reviewTicket = '';
  state.reviewTicketConsumed = true;
  state.reviewRound = 0;
  state.stopBlockCount = 0;
  state.deferredReviewClaim = '';
  state.phase = 'UNINITIALIZED';
  state.step_id = '';
  state.history = [];
  delete state.reviewRearm;
  delete state.autopilotRunId;
  delete state.autopilotAttempt;
  delete state.autopilotReturnStage;
  delete state.chainId;
  delete state.chainOutcome;
  return state;
}

function cancellationResult(receipt) {
  return {
    status: 'cancelled',
    claimId: receipt.claimId,
    cancellationId: receipt.cancellationId,
    mode: receipt.mode,
    ownerRevision: receipt.ownerRevision,
    clearedOwnerRevision: receipt.clearedOwnerRevision,
  };
}

function supersededCancellationResult(receipt) {
  return {
    status: 'superseded',
    claimId: receipt.claimId,
    cancellationId: receipt.cancellationId,
    mode: receipt.mode,
    ownerRevision: receipt.ownerRevision,
    clearedOwnerRevision: receipt.ownerRevision,
  };
}

function cancelDeferredReviewClaim(options) {
  const binding = currentClaudeSessionContext(options);
  const request = deferredReviewCancellationOptions(options);
  const claimFile = deferredReviewClaimFile(options, binding.projectRoot, true);
  return withDeferredReviewClaimLock(binding.projectRoot, () => {
    let claimSnapshot;
    try {
      claimSnapshot = readDeferredReviewClaimSnapshot(options, binding.projectRoot);
    } catch (error) {
      if (!fs.existsSync(claimFile)) {
        return withWorkflowStateLock({
          projectRoot: binding.projectRoot,
          sessionId: binding.currentSessionId,
        }, (state) => {
          if (state.deferredReviewClaim !== '') {
            fail('deferred-review claim artifact is missing for active owner state');
          }
          return { status: 'absent', mode: request.mode };
        });
      }
      throw error;
    }
    const initialClaim = claimSnapshot.claim;
    relatedClaudeSessionContexts(options, initialClaim.ownerSessionId);
    if (
      !initialClaim.cancellation
      && initialClaim.ownerSessionId !== binding.currentSessionId
    ) {
      fail('only the deferred-review owner may cancel its claim');
    }
    const resettableAssignedTransfer = request.mode === 'reset'
      && claimIsAssignedUnseededTransferTarget(initialClaim, binding.currentSessionId);
    if (initialClaim.transfer && !resettableAssignedTransfer) {
      fail('deferred-review transfer must be finalized before cancellation');
    }
    if (
      initialClaim.cancellation
      && (
        initialClaim.cancellation.mode !== request.mode
        || !sameDeferredReviewResetBinding(
          initialClaim.cancellation.resetBinding,
          request.resetBinding,
        )
      )
    ) {
      fail('deferred-review cancellation request does not match its durable receipt');
    }

    return withWorkflowStateLock({
      projectRoot: binding.projectRoot,
      sessionId: initialClaim.ownerSessionId,
    }, (state, target) => {
      let latest = requireDeferredReviewClaimSnapshot(
        options,
        binding.projectRoot,
        claimSnapshot,
        'deferred-review claim changed before cancellation',
      );
      if (!sameClaimValue(latest.claim, initialClaim)) {
        fail('deferred-review claim changed before cancellation');
      }
      let receipt = latest.claim.cancellation;
      if (!receipt) {
        const linked = state.deferredReviewClaim === latest.claim.claimId;
        const unseededReset = stateCanBeginUnseededDeferredReviewReset(
          state,
          latest.claim,
          request,
        );
        const assignedTransfer = claimIsAssignedUnseededTransferTarget(
          latest.claim,
          binding.currentSessionId,
        );
        if (latest.claim.transfer && !(unseededReset && assignedTransfer)) {
          fail('deferred-review transfer must be finalized before cancellation');
        }
        if (!linked && !unseededReset) {
          fail('deferred-review owner state changed before cancellation');
        }
        if (request.mode === 'reset' && !stateMatchesDeferredReviewResetBinding(state, request.resetBinding)) {
          fail('deferred-review reset binding does not match owner state');
        }
        receipt = {
          schemaVersion: 1,
          stage: 'prepared',
          cancellationId: `drc_${crypto.randomBytes(16).toString('hex')}`,
          claimId: latest.claim.claimId,
          ownerSessionId: latest.claim.ownerSessionId,
          mode: request.mode,
          origin: linked ? 'linked' : 'unseeded',
          ownerRevision: state.revision,
          clearedOwnerRevision: null,
          resetBinding: request.resetBinding,
        };
        delete latest.claim.transfer;
        latest.claim.cancellation = receipt;
        atomicWriteJson(latest.claimFile, latest.claim);
        latest = readDeferredReviewClaimSnapshot(options, binding.projectRoot);
      }

      if (stateHasDeferredReviewCancellation(state, receipt)) {
        if (receipt.stage === 'prepared') {
          receipt.stage = 'state-cleared';
          receipt.clearedOwnerRevision = receipt.ownerRevision + 1;
          latest.claim.cancellation = receipt;
          atomicWriteJson(latest.claimFile, latest.claim);
          latest = readDeferredReviewClaimSnapshot(options, binding.projectRoot);
        }
      } else if (
        receipt.stage === 'prepared'
        && (
          (
            receipt.origin === 'linked'
            && state.deferredReviewClaim === receipt.claimId
          )
          || stateMatchesPreparedUnseededCancellation(state, latest.claim, receipt)
        )
      ) {
        if (request.mode === 'reset' && !stateMatchesDeferredReviewResetBinding(state, request.resetBinding)) {
          fail('deferred-review reset binding changed before cancellation');
        }
        if (
          state.deferredReviewClaim === receipt.claimId
          && state.revision !== receipt.ownerRevision
        ) {
          receipt.ownerRevision = state.revision;
          receipt.clearedOwnerRevision = null;
          latest.claim.cancellation = receipt;
          atomicWriteJson(latest.claimFile, latest.claim);
          latest = readDeferredReviewClaimSnapshot(options, binding.projectRoot);
        }
        const marker = deferredReviewCancellationMarker(receipt);
        const cleared = commitWorkflowStateUnderLock(target, state, {
          expectedRevision: receipt.ownerRevision,
          workflowState: request.mode === 'reset' ? 'idle' : state.workflow_state,
          event: request.mode === 'reset' ? 'deferred-review-reset' : 'deferred-review-release',
        }, (draft) => {
          if (request.mode === 'reset') resetDeferredReviewState(draft);
          else draft.deferredReviewClaim = '';
          draft.deferredReviewCancellation = marker;
          return draft;
        });
        if (!stateHasDeferredReviewCancellation(cleared, receipt)) {
          fail('deferred-review cancellation state receipt was not persisted');
        }
        receipt.stage = 'state-cleared';
        receipt.clearedOwnerRevision = marker.resultRevision;
        latest.claim.cancellation = receipt;
        atomicWriteJson(latest.claimFile, latest.claim);
        latest = readDeferredReviewClaimSnapshot(options, binding.projectRoot);
      } else if (
        receipt.stage === 'prepared'
        && receipt.origin === 'unseeded'
        && latest.claim.handoffEmitted === false
        && state.revision > receipt.ownerRevision
        && state.deferredReviewClaim === ''
      ) {
        if (!removeRegularFileIfSame(latest.claimFile, latest.snapshot)) {
          fail('deferred-review claim changed before superseded cancellation removal');
        }
        return supersededCancellationResult(receipt);
      } else {
        fail('deferred-review cancellation state does not match its receipt');
      }

      receipt = latest.claim.cancellation;
      if (
        !receipt
        || receipt.stage !== 'state-cleared'
        || !stateHasDeferredReviewCancellation(
          readWorkflowStateUnderLock(target),
          receipt,
        )
      ) {
        fail('deferred-review cancellation did not reach its durable state');
      }
      if (!removeRegularFileIfSame(latest.claimFile, latest.snapshot)) {
        fail('deferred-review claim changed before cancellation removal');
      }
      return cancellationResult(receipt);
    });
  });
}

function sameRegularSnapshot(left, right) {
  return Boolean(left)
    && Boolean(right)
    && sameFileIdentity(left.stat, right.stat)
    && left.stat.size === right.stat.size
    && left.data.equals(right.data);
}

function removeRegularFileIfSame(file, snapshot) {
  const current = readRegularFileSnapshot(file, MAX_JSON_BYTES, true);
  if (!sameRegularSnapshot(current, snapshot)) return false;
  const quarantine = path.join(
    path.dirname(file),
    `.${path.basename(file)}.${process.pid}.${crypto.randomBytes(24).toString('hex')}.quarantine`,
  );
  try {
    fs.renameSync(file, quarantine);
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
  const moved = readRegularFileSnapshot(quarantine, MAX_JSON_BYTES);
  if (!sameRegularSnapshot(moved, snapshot)) {
    try {
      fs.linkSync(quarantine, file);
      fs.unlinkSync(quarantine);
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      fail('deferred-review claim replacement race could not be restored safely');
    }
    return false;
  }
  fs.unlinkSync(quarantine);
  return true;
}

function clearTerminalDeferredReviewClaim(options) {
  const binding = currentClaudeSessionContext(options);
  const inspection = inspectDeferredReviewOwner(options);
  if (!['done', 'cancelled'].includes(inspection.status)) {
    fail('deferred-review claim is not terminal');
  }
  if (inspection.status === 'done' && inspection.claim.handoffEmitted !== true) {
    fail('deferred-review done claim has no durable handoff acknowledgement');
  }
  const expected = readDeferredReviewClaimSnapshot(options, binding.projectRoot);
  if (!sameClaimValue(expected.claim, inspection.claim)) {
    fail('deferred-review claim changed before terminal removal');
  }
  return withDeferredReviewClaimLock(binding.projectRoot, () => (
    withWorkflowStateLock({
      projectRoot: binding.projectRoot,
      sessionId: inspection.claim.ownerSessionId,
    }, (state, target) => {
      const terminalStateMatches = inspection.status === 'done'
        ? state.deferredReviewClaim === inspection.claim.claimId && state.chainDone === true
        : inspection.claim.cancellation
          ? stateHasDeferredReviewCancellation(state, inspection.claim.cancellation)
          : state.deferredReviewClaim !== inspection.claim.claimId
            && inspection.claim.handoffEmitted === true;
      if (state.revision !== inspection.ownerRevision || !terminalStateMatches) {
        fail('owner state changed before terminal removal');
      }
      const latest = requireDeferredReviewClaimSnapshot(
        options,
        binding.projectRoot,
        expected,
        'deferred-review claim changed before terminal removal',
      );
      if (!sameClaimValue(latest.claim, inspection.claim)) {
        fail('deferred-review claim changed before terminal removal');
      }
      let resultingOwnerRevision = state.revision;
      if (inspection.status === 'done') {
        const cleared = commitWorkflowStateUnderLock(target, state, {
          expectedRevision: inspection.ownerRevision,
          workflowState: state.workflow_state,
          event: 'deferred-review-complete',
        }, (draft) => {
          draft.deferredReviewClaim = '';
          return draft;
        });
        resultingOwnerRevision = cleared.revision;
      }
      if (!removeRegularFileIfSame(latest.claimFile, latest.snapshot)) {
        fail('deferred-review claim changed before terminal removal');
      }
      return {
        status: inspection.status,
        claimId: inspection.claim.claimId,
        resultingOwnerRevision,
      };
    })
  ));
}

function sortedObject(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    fail('changedFileHashes must be an object');
  }
  const entries = [];
  for (const key of Object.keys(input).sort()) {
    const value = input[key];
    if (typeof value !== 'string' || !HASH_RE.test(value)) {
      fail(`invalid changed file hash for ${key}`);
    }
    entries.push([key, value]);
  }
  // Object.fromEntries uses CreateDataProperty, so a legitimate file named
  // "__proto__" remains an own data property instead of invoking the legacy
  // Object.prototype setter and disappearing from the attestation.
  return Object.fromEntries(entries);
}

function createAttestation(options) {
  const context = validateContext(options.context);
  const state = validateWorkflowState(options.state, context.session_id_hash);
  if (
    !Array.isArray(options.hookSequence)
    || options.hookSequence.length === 0
    || options.hookSequence.some((entry) => typeof entry !== 'string' || entry.trim() === '')
  ) {
    fail('hookSequence must be a non-empty array of strings');
  }
  if (!Number.isSafeInteger(options.exitCode)) {
    fail('exitCode must be an integer');
  }
  if (Object.prototype.hasOwnProperty.call(options, 'sourceRevision')
      || Object.prototype.hasOwnProperty.call(options, 'sourceRevisionAuthority')) {
    fail('sourceRevision/sourceRevisionAuthority overrides are unsupported in attestations');
  }
  // `resolved_plugin_root`, `runtime_digest` and `plugin_version` all name the
  // runtime the session was BOUND to. Once a compatible upgrade may serve that
  // record they no longer name the runtime that ran, so the attestation states
  // both. The executing DIGEST is MEASURED here rather than accepted from the
  // caller — there is no option to supply it — so the pair cannot disagree with
  // the tree it claims to describe, and an executing root outside the recorded
  // lineage is refused instead of recorded.
  //
  // The root itself IS a caller input, and deliberately so: a wrapper run
  // installs the runtime under its own target and has to be able to say which
  // tree ran (evals/session-control/assertions/control-attestation.js compares
  // both root fields against that target). Self-deriving it from __dirname would
  // name this module's tree instead and make the field unassertable. It is not
  // an unchecked input — servesRecordedRuntime below refuses anything that is
  // not the recorded root or a declared-compatible sibling of it.
  //
  // The emitted key set and its ORDER are mirrored by ATTESTATION_FIELDS in
  // evals/session-control/lib/attestation-common.js, which compares by value AND
  // by position; every port keeps its own copy. Editing the object below without
  // that list rejects every attestation this function produces.
  if (Object.prototype.hasOwnProperty.call(options, 'executingRuntimeDigest')) {
    fail('executingRuntimeDigest overrides are unsupported in attestations');
  }
  const executingPluginRoot = options.executingPluginRoot === undefined
    ? context.plugin_root
    : canonicalDirectory(options.executingPluginRoot, 'executingPluginRoot');
  if (!servesRecordedRuntime(context, executingPluginRoot, context.host)) {
    fail('executingPluginRoot must share the immutable context runtime lineage');
  }
  const executingRuntimeDigest = executingPluginRoot === context.plugin_root
    ? context.runtime_digest
    : computeRuntimeDigest(executingPluginRoot, context.host);
  return {
    schema: ATTESTATION_SCHEMA,
    schema_version: SCHEMA_VERSION,
    host: context.host,
    session_id_hash: context.session_id_hash,
    resolved_plugin_root: context.plugin_root,
    runtime_digest: context.runtime_digest,
    executing_plugin_root: executingPluginRoot,
    executing_runtime_digest: executingRuntimeDigest,
    workflow_state: state.workflow_state,
    revision: state.revision,
    hook_sequence: [...options.hookSequence],
    reviewer_capabilities: options.reviewerCapabilities === context.principal_profiles.reviewer
      ? options.reviewerCapabilities
      : fail('reviewerCapabilities must match the immutable reviewer profile'),
    changed_file_hashes: sortedObject(options.changedFileHashes),
    cli_version: requireText(options.cliVersion, 'cliVersion'),
    plugin_version: options.pluginVersion === undefined || options.pluginVersion === context.plugin_version
      ? context.plugin_version
      : fail('pluginVersion must match the immutable context'),
    source_revision: context.source_revision,
    exit_code: options.exitCode,
  };
}

function parseOptions(args) {
  const options = {};
  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (!token.startsWith('--')) {
      fail(`unexpected argument "${token}"`);
    }
    const name = token.slice(2);
    const value = args[index + 1];
    if (value === undefined || value.startsWith('--')) {
      fail(`missing value for --${name}`);
    }
    options[name] = value;
    index += 1;
  }
  return options;
}

function runCli(argv) {
  const [command, ...rest] = argv;
  if (command === 'session-key') {
    if (rest.length !== 1) fail('session-key expects exactly one value');
    process.stdout.write(`${sessionKey(rest[0])}\n`);
    return;
  }
  const options = parseOptions(rest);
  if (command === 'runtime-digest') {
    process.stdout.write(`${computeRuntimeDigest(options['plugin-root'], options.host)}\n`);
    return;
  }
  if (command === 'resolve' || command === 'render-main' || command === 'render-reviewer' || command === 'render-host') {
    const context = readContext({
      recordsDir: options['records-dir'],
      sessionId: options['session-id'],
      expectedHost: options.host,
    });
    if (command === 'resolve') {
      const field = requireText(options.field, 'field');
      if (!Object.prototype.hasOwnProperty.call(context, field) || typeof context[field] === 'object') {
        fail('unsupported context field');
      }
      process.stdout.write(`${context[field]}\n`);
    } else {
      const rendered = command === 'render-main'
        ? renderMainContext(context)
        : command === 'render-reviewer'
          ? renderReviewerContext(context)
          : renderHostContext(context);
      process.stdout.write(`${rendered}\n`);
    }
    return;
  }
  if (command === 'transition') {
    const state = transitionWorkflowState({
      projectRoot: options['project-root'],
      sessionId: options['session-id'],
      workflowState: options['workflow-state'],
      event: options.event,
      actor: options.actor,
      expectedRevision: options['expected-revision'] === undefined ? undefined : Number(options['expected-revision']),
    });
    process.stdout.write(`${JSON.stringify(state)}\n`);
    return;
  }
  fail('unknown command');
}

module.exports = {
  SCHEMA,
  SCHEMA_VERSION,
  WORKFLOW_SCHEMA,
  ATTESTATION_SCHEMA,
  sessionIdHash,
  sessionKey,
  computeRuntimeDigest,
  runtimeLineageCompatible,
  servesRecordedRuntime,
  executingPluginVersion,
  buildContext,
  registerContext,
  readContext,
  readOrphanedProjectRootContext,
  ADOPTION_REFUSALS,
  ADOPTION_HISTORY_PHASE,
  ADOPTION_HISTORY_REASON_PREFIX,
  adoptableRecord,
  adoptContext,
  renderMainContext,
  renderReviewerContext,
  renderEvidenceWorkerContext,
  renderHostContext,
  stampWorkflowState,
  initializeWorkflowState,
  mutateWorkflowState,
  transitionWorkflowState,
  resetReviewBudget,
  readWorkflowState,
  inspectDeferredReviewOwner,
  deferredReviewOwnedByOther,
  prepareDeferredReviewTransfer,
  retireDeferredReviewOwner,
  markDeferredReviewOwnerRetired,
  assignDeferredReviewClaim,
  finalizeDeferredReviewTransfer,
  acknowledgeDeferredReviewHandoff,
  cancelDeferredReviewClaim,
  clearTerminalDeferredReviewClaim,
  processStartIdentityForPid,
  createAttestation,
  externalProcessLockPath,
  acquireExternalProcessLock,
  releaseExternalProcessLock,
  releaseExternalProcessLockByToken,
  withFileLock,
  atomicWriteJson,
  atomicCreateJson,
};

if (require.main === module) {
  try {
    runCli(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
