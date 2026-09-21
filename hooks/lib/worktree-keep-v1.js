'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');

const KEEP_FILENAME = '.worktree-keep';
const KEEP_SOURCE_BUILD = '2.2553.1';
const KEEP_SIGNATURE = 'zensu-claude-code worktree-keep v1';
const KEEP_BODY = KEEP_SIGNATURE + '\n'
  + 'A live Claude Code session bound to this worktree keeps this marker here so the Claude Desktop\n'
  + 'worktree pool neither reuses nor reaps the directory. It is removed when no live session anchor\n'
  + 'remains. See docs/worktree-keep.md in the zensu-claude-code plugin.\n';
const ANCHOR_PREFIX = 'worktree-anchor-';
const ANCHOR_NAME_RE = /^worktree-anchor-(scv1_[a-f0-9]{64})\.json$/;
const SESSION_KEY_RE = /^scv1_[a-f0-9]{64}$/;
const BRANCH_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$/;
const BRANCH_NAME_FORBIDDEN_RE = /\.\.|@\{|\/\/|\/\.|\.lock$|\/$/;
const ANCHOR_SCHEMA_VERSION = 1;
const STATE_SEGMENTS = Object.freeze(['.zensu', 'state']);
const WORKTREES_SEGMENTS = Object.freeze(['.claude', 'worktrees']);
const DEFAULT_IDLE_HOURS = 72;
const MAX_IDLE_HOURS = 8760;
const REAP_FACTOR = 2;
const MAX_ANCHOR_BYTES = 8192;
const MAX_MARKER_BYTES = 4096;
const MAX_EXCLUDE_BYTES = 1024 * 1024;
const MAX_SWEEP_DIRS = 64;
const MAX_ANCHOR_FILES = 256;
const REFRESH_INTERVAL_MS = 10 * 60 * 1000;
const EXCLUDE_COMMENT = '# zensu worktree-keep';
const GIT_TIMEOUT_MS = 5000;
const GIT_ENV_SCRUB = Object.freeze([
  'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR',
  'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES',
  'GIT_CEILING_DIRECTORIES', 'GIT_DISCOVERY_ACROSS_FILESYSTEM',
  'GIT_NAMESPACE', 'GIT_PREFIX', 'GIT_CONFIG', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM',
  'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS',
]);

const UNRENDERABLE_BRANCH = '(unrenderable)';

// Three vocabularies, all exported so no consumer re-spells a member. The doctor renderer
// lives in another file and compares against every one of them, which is exactly the crossing
// this repository records as the expensive kind to get wrong.
const VERDICTS = Object.freeze({ LIVE: 'live', STALE: 'stale', REJECTED: 'rejected', MISSING: 'missing' });
const MARKER_STATES = Object.freeze({ ABSENT: 'absent', OURS: 'ours', FOREIGN: 'foreign', REFUSED: 'refused' });
const ACTIONS = Object.freeze({
  CREATED: 'created',
  REMOVED: 'removed',
  KEPT: 'kept',
  ABSENT: 'absent',
  FOREIGN: 'foreign',
  REFUSED: 'refused',
});
const VERBS = Object.freeze(['session-start', 'prompt', 'session-end']);
const RESUME_SOURCES = Object.freeze(['resume', 'compact']);

function noFollowFlag() {
  return process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW)
    ? fs.constants.O_NOFOLLOW
    : 0;
}

function nonBlockFlag() {
  return Number.isInteger(fs.constants.O_NONBLOCK) ? fs.constants.O_NONBLOCK : 0;
}

function lstatOrNull(target) {
  try {
    return fs.lstatSync(target);
  } catch (error) {
    if (error && error.code === 'ENOENT') return null;
    throw error;
  }
}

function idleMsFromHours(hours) {
  const value = Number(hours);
  if (!Number.isInteger(value) || value < 1 || value > MAX_IDLE_HOURS) {
    return DEFAULT_IDLE_HOURS * 3600000;
  }
  return value * 3600000;
}

function isSessionKey(value) {
  return typeof value === 'string' && SESSION_KEY_RE.test(value);
}

function branchNameOk(value) {
  return typeof value === 'string' && BRANCH_NAME_RE.test(value) && !BRANCH_NAME_FORBIDDEN_RE.test(value);
}

function managedWorktree(cwd) {
  if (typeof cwd !== 'string' || cwd.length === 0 || /[\0\r\n]/.test(cwd)) return null;
  if (!path.isAbsolute(cwd)) return null;
  let real;
  try {
    real = fs.realpathSync.native(cwd);
  } catch {
    return null;
  }
  let dir = real;
  for (let depth = 0; depth < 64; depth += 1) {
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    const grand = path.dirname(parent);
    if (
      path.basename(parent) === WORKTREES_SEGMENTS[1]
      && path.basename(grand) === WORKTREES_SEGMENTS[0]
      && grand !== path.dirname(grand)
    ) {
      const baseRepo = path.dirname(grand);
      const gitEntry = lstatOrNull(path.join(dir, '.git'));
      const baseGit = lstatOrNull(path.join(baseRepo, '.git'));
      if (gitEntry && gitEntry.isFile() && !gitEntry.isSymbolicLink() && baseGit && !baseGit.isSymbolicLink()) {
        return { worktreeRoot: dir, baseRepo, name: path.basename(dir) };
      }
      return null;
    }
    dir = parent;
  }
  return null;
}

function stateDirVerdict(worktreeRoot) {
  let dir = worktreeRoot;
  for (const segment of STATE_SEGMENTS) {
    dir = path.join(dir, segment);
    const info = lstatOrNull(dir);
    if (info === null) return { ok: true, dir: path.join(worktreeRoot, ...STATE_SEGMENTS), exists: false };
    if (info.isSymbolicLink()) return { ok: false, dir, reason: 'state-component-symlink' };
    if (!info.isDirectory()) return { ok: false, dir, reason: 'state-component-not-a-directory' };
  }
  return { ok: true, dir, exists: true };
}

function ensureStateDir(worktreeRoot) {
  const verdict = stateDirVerdict(worktreeRoot);
  if (!verdict.ok) return verdict;
  if (!verdict.exists) {
    fs.mkdirSync(verdict.dir, { recursive: true, mode: 0o700 });
    const again = stateDirVerdict(worktreeRoot);
    if (!again.ok || !again.exists) return { ok: false, dir: verdict.dir, reason: again.reason || 'state-dir-unavailable' };
  }
  return { ok: true, dir: verdict.dir, exists: true };
}

function anchorPath(worktreeRoot, sessionKey) {
  if (!isSessionKey(sessionKey)) throw new Error('worktree-keep: session key has the wrong shape');
  return path.join(worktreeRoot, ...STATE_SEGMENTS, ANCHOR_PREFIX + sessionKey + '.json');
}

function finiteStamp(value) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0;
}

function headOk(value) {
  return value === null || (typeof value === 'string' && /^[0-9a-f]{7,64}$/.test(value));
}

function branchValueOk(value) {
  return value === null || value === UNRENDERABLE_BRANCH || branchNameOk(value);
}

function driftShapeOk(drift) {
  if (drift === null) return true;
  if (!drift || typeof drift !== 'object' || Array.isArray(drift)) return false;
  return branchValueOk(drift.from) && branchValueOk(drift.to) && headOk(drift.head) && finiteStamp(drift.detectedAt);
}

function recordShapeOk(record, sessionKey) {
  if (!record || typeof record !== 'object' || Array.isArray(record)) return false;
  if (record.schemaVersion !== ANCHOR_SCHEMA_VERSION) return false;
  if (record.sessionKey !== sessionKey) return false;
  if (typeof record.worktreeRoot !== 'string' || record.worktreeRoot.length === 0) return false;
  if (!branchValueOk(record.branch)) return false;
  if (!headOk(record.head)) return false;
  if (!finiteStamp(record.recordedAt) || !finiteStamp(record.lastSeenAt)) return false;
  if (!('drift' in record) || !driftShapeOk(record.drift)) return false;
  return true;
}

function openPlainFile(file, maxBytes, options) {
  const opts = options || {};
  const info = lstatOrNull(file);
  if (info === null) return { status: 'missing' };
  if (info.isSymbolicLink()) return { status: 'refused', reason: 'symlink' };
  if (!info.isFile()) return { status: 'refused', reason: 'not-a-regular-file' };
  if (opts.singleLink && info.nlink !== 1) return { status: 'refused', reason: 'hard-link' };
  if (info.size > maxBytes) return { status: 'refused', reason: 'too-large' };
  let fd = null;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | noFollowFlag() | nonBlockFlag());
    const opened = fs.fstatSync(fd);
    if (!opened.isFile() || opened.size > maxBytes) return { status: 'refused', reason: 'changed-under-open' };
    const buffer = Buffer.alloc(opened.size);
    let offset = 0;
    while (offset < opened.size) {
      const read = fs.readSync(fd, buffer, offset, opened.size - offset, offset);
      if (read === 0) break;
      offset += read;
    }
    return { status: 'ok', content: buffer.subarray(0, offset).toString('utf8') };
  } catch (error) {
    if (error && error.code === 'ENOENT') return { status: 'missing' };
    return { status: 'refused', reason: error && error.code ? error.code : 'unreadable' };
  } finally {
    if (fd !== null) {
      try { fs.closeSync(fd); } catch {}
    }
  }
}

function readAnchorFile(file, sessionKey) {
  const opened = openPlainFile(file, MAX_ANCHOR_BYTES, { singleLink: true });
  if (opened.status === 'missing') return { status: VERDICTS.MISSING };
  if (opened.status !== 'ok') return { status: VERDICTS.REJECTED, reason: opened.reason };
  let parsed;
  try {
    parsed = JSON.parse(opened.content);
  } catch {
    return { status: VERDICTS.REJECTED, reason: 'unparseable' };
  }
  if (!recordShapeOk(parsed, sessionKey)) return { status: VERDICTS.REJECTED, reason: 'shape' };
  return { status: 'ok', record: parsed };
}

function readAnchor(worktreeRoot, sessionKey) {
  const dir = stateDirVerdict(worktreeRoot);
  if (!dir.ok) return { status: VERDICTS.REJECTED, reason: dir.reason };
  if (!dir.exists) return { status: VERDICTS.MISSING };
  return readAnchorFile(anchorPath(worktreeRoot, sessionKey), sessionKey);
}

function classifyAnchor(record, nowMs, idleMs) {
  if (!record) return VERDICTS.MISSING;
  const age = nowMs - record.lastSeenAt;
  if (age < 0 || age > idleMs) return VERDICTS.STALE;
  return VERDICTS.LIVE;
}

function reapable(record, nowMs, idleMs) {
  return Math.abs(nowMs - record.lastSeenAt) > idleMs * REAP_FACTOR;
}

function anchorVerdict(worktreeRoot, sessionKey, nowMs, idleMs) {
  const read = readAnchor(worktreeRoot, sessionKey);
  if (read.status !== 'ok') return { verdict: read.status, reason: read.reason, record: null };
  return { verdict: classifyAnchor(read.record, nowMs, idleMs), record: read.record };
}

function writeAnchor(worktreeRoot, sessionKey, record) {
  if (!recordShapeOk(record, sessionKey)) return { ok: false, reason: 'shape' };
  const dir = ensureStateDir(worktreeRoot);
  if (!dir.ok) return { ok: false, reason: dir.reason };
  const target = anchorPath(worktreeRoot, sessionKey);
  const existing = lstatOrNull(target);
  if (existing !== null && (existing.isSymbolicLink() || !existing.isFile() || existing.nlink !== 1)) {
    return { ok: false, reason: 'target-not-a-plain-file' };
  }
  const temp = target + '.tmp-' + process.pid + '-' + crypto.randomBytes(6).toString('hex');
  let fd = null;
  try {
    fd = fs.openSync(temp, 'wx', 0o600);
    fs.writeSync(fd, JSON.stringify(record) + '\n');
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    fd = null;
    fs.renameSync(temp, target);
    return { ok: true, file: target };
  } catch (error) {
    if (fd !== null) {
      try { fs.closeSync(fd); } catch {}
    }
    try { fs.unlinkSync(temp); } catch {}
    return { ok: false, reason: error && error.code ? error.code : 'write-failed' };
  }
}

function removeAnchor(worktreeRoot, sessionKey) {
  const dir = stateDirVerdict(worktreeRoot);
  if (!dir.ok) return { action: ACTIONS.REFUSED, reason: dir.reason };
  if (!dir.exists) return { action: ACTIONS.ABSENT };
  const target = anchorPath(worktreeRoot, sessionKey);
  const info = lstatOrNull(target);
  if (info === null) return { action: ACTIONS.ABSENT };
  if (info.isSymbolicLink() || !info.isFile()) return { action: ACTIONS.REFUSED, reason: 'target-not-a-plain-file' };
  try {
    fs.unlinkSync(target);
    return { action: ACTIONS.REMOVED };
  } catch (error) {
    if (error && error.code === 'ENOENT') return { action: ACTIONS.ABSENT };
    return { action: ACTIONS.REFUSED, reason: error && error.code ? error.code : 'unlink-failed' };
  }
}

function listAnchors(worktreeRoot, nowMs, idleMs) {
  const empty = { live: [], stale: [], reapable: [], rejected: [] };
  const dir = stateDirVerdict(worktreeRoot);
  if (!dir.ok) return { ok: false, reason: dir.reason, ...empty };
  if (!dir.exists) return { ok: true, ...empty };
  let names;
  try {
    names = fs.readdirSync(dir.dir);
  } catch (error) {
    return { ok: false, reason: error && error.code ? error.code : 'unreadable', ...empty };
  }
  const live = [];
  const stale = [];
  const reap = [];
  const rejected = [];
  let examined = 0;
  for (const name of names) {
    const match = ANCHOR_NAME_RE.exec(name);
    if (!match) continue;
    examined += 1;
    if (examined > MAX_ANCHOR_FILES) return { ok: false, reason: 'too-many-anchors', ...empty };
    const read = readAnchorFile(path.join(dir.dir, name), match[1]);
    if (read.status !== 'ok') {
      if (read.status === VERDICTS.REJECTED) rejected.push({ name, reason: read.reason });
      continue;
    }
    const entry = { name, key: match[1], record: read.record };
    if (classifyAnchor(read.record, nowMs, idleMs) === VERDICTS.LIVE) {
      live.push(entry);
    } else {
      stale.push(entry);
      if (reapable(read.record, nowMs, idleMs)) reap.push(entry);
    }
  }
  return { ok: true, live, stale, reapable: reap, rejected };
}

function markerState(worktreeRoot) {
  const file = path.join(worktreeRoot, KEEP_FILENAME);
  const opened = openPlainFile(file, MAX_MARKER_BYTES);
  if (opened.status === 'missing') return { file, state: MARKER_STATES.ABSENT };
  if (opened.status !== 'ok') {
    if (opened.reason === 'too-large') return { file, state: MARKER_STATES.FOREIGN };
    if (opened.reason === 'symlink' || opened.reason === 'not-a-regular-file') return { file, state: MARKER_STATES.REFUSED, reason: 'not-a-plain-file' };
    return { file, state: MARKER_STATES.REFUSED, reason: opened.reason };
  }
  return { file, state: opened.content.split('\n')[0] === KEEP_SIGNATURE ? MARKER_STATES.OURS : MARKER_STATES.FOREIGN };
}

function reconcileKeep(worktreeRoot, nowMs, idleMs, options) {
  const opts = options || {};
  const anchors = listAnchors(worktreeRoot, nowMs, idleMs);
  const reaped = [];
  if (anchors.ok && opts.reap !== false) {
    for (const entry of anchors.reapable) {
      const result = removeAnchor(worktreeRoot, entry.key);
      if (result.action === ACTIONS.REMOVED) reaped.push(entry.key);
    }
  }
  const counts = {
    live: anchors.live.length,
    stale: anchors.stale.length,
    reapable: anchors.reapable.length,
    rejected: anchors.rejected.length,
    reaped: reaped.length,
    anchorsReadable: anchors.ok,
  };
  const marker = markerState(worktreeRoot);
  if (marker.state === MARKER_STATES.REFUSED) return { action: ACTIONS.REFUSED, reason: marker.reason, file: marker.file, ...counts };
  if (marker.state === MARKER_STATES.FOREIGN) return { action: ACTIONS.FOREIGN, file: marker.file, ...counts };
  if (!anchors.ok) return { action: marker.state === MARKER_STATES.OURS ? ACTIONS.KEPT : ACTIONS.ABSENT, reason: anchors.reason, file: marker.file, ...counts };
  if (anchors.live.length > 0) {
    if (marker.state === MARKER_STATES.OURS) return { action: ACTIONS.KEPT, file: marker.file, ...counts };
    try {
      const fd = fs.openSync(marker.file, 'wx', 0o644);
      try {
        fs.writeSync(fd, KEEP_BODY);
      } finally {
        fs.closeSync(fd);
      }
      return { action: ACTIONS.CREATED, file: marker.file, ...counts };
    } catch (error) {
      return { action: ACTIONS.REFUSED, reason: error && error.code ? error.code : 'create-failed', file: marker.file, ...counts };
    }
  }
  if (marker.state === MARKER_STATES.OURS) {
    if (counts.rejected > 0) return { action: ACTIONS.KEPT, reason: 'rejected-anchors', file: marker.file, ...counts };
    try {
      fs.unlinkSync(marker.file);
      return { action: ACTIONS.REMOVED, file: marker.file, ...counts };
    } catch (error) {
      if (error && error.code === 'ENOENT') return { action: ACTIONS.ABSENT, file: marker.file, ...counts };
      return { action: ACTIONS.REFUSED, reason: error.code || 'unlink-failed', file: marker.file, ...counts };
    }
  }
  return { action: ACTIONS.ABSENT, file: marker.file, ...counts };
}

function gitEnvironment(base) {
  const env = { ...(base || process.env) };
  for (const name of GIT_ENV_SCRUB) delete env[name];
  env.GIT_TERMINAL_PROMPT = '0';
  return env;
}

function runGit(cwd, args) {
  try {
    const output = execFileSync('git', args, {
      cwd,
      encoding: 'utf8',
      timeout: GIT_TIMEOUT_MS,
      stdio: ['ignore', 'pipe', 'ignore'],
      env: gitEnvironment(process.env),
    });
    return { ok: true, output: output.trim() };
  } catch (error) {
    return { ok: false, status: error && typeof error.status === 'number' ? error.status : null };
  }
}

function currentBranch(worktreeRoot) {
  const head = runGit(worktreeRoot, ['rev-parse', '--verify', '--quiet', 'HEAD']);
  const ref = runGit(worktreeRoot, ['symbolic-ref', '--short', '--quiet', 'HEAD']);
  if (!head.ok && ref.status !== 1) {
    if (!ref.ok) return { ok: false, branch: null, head: null };
  }
  if (ref.ok && ref.output.length > 0) {
    if (!branchNameOk(ref.output)) {
      return { ok: true, branch: UNRENDERABLE_BRANCH, head: head.ok && head.output ? head.output : null, reason: 'branch-shape' };
    }
    return { ok: true, branch: ref.output, head: head.ok && head.output ? head.output : null };
  }
  if (ref.status === 1) {
    return { ok: true, branch: null, head: head.ok && head.output ? head.output : null };
  }
  return { ok: false, branch: null, head: null };
}

function commonGitDir(baseRepo) {
  const result = runGit(baseRepo, ['rev-parse', '--git-common-dir']);
  if (!result.ok || result.output.length === 0) return null;
  return path.resolve(baseRepo, result.output);
}

function ensureExclude(baseRepo) {
  const common = commonGitDir(baseRepo);
  if (common === null) return { action: ACTIONS.REFUSED, reason: 'git-common-dir-unresolved' };
  const commonInfo = lstatOrNull(common);
  if (commonInfo === null || !commonInfo.isDirectory() || commonInfo.isSymbolicLink()) {
    return { action: ACTIONS.REFUSED, reason: 'git-common-dir-not-a-directory' };
  }
  const infoDir = path.join(common, 'info');
  const infoStat = lstatOrNull(infoDir);
  if (infoStat !== null && (infoStat.isSymbolicLink() || !infoStat.isDirectory())) {
    return { action: ACTIONS.REFUSED, reason: 'info-not-a-directory' };
  }
  const file = path.join(infoDir, 'exclude');
  const opened = openPlainFile(file, MAX_EXCLUDE_BYTES);
  if (opened.status === 'refused') return { action: ACTIONS.REFUSED, reason: 'exclude-' + opened.reason, file };
  const existing = opened.status === 'ok' ? opened.content : '';
  if (existing.split(/\r?\n/).some((line) => line.trim() === KEEP_FILENAME)) {
    return { action: 'present', file };
  }
  let fd = null;
  try {
    if (infoStat === null) fs.mkdirSync(infoDir, { recursive: true });
    fd = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_APPEND | fs.constants.O_CREAT | noFollowFlag() | nonBlockFlag(), 0o644);
    const landed = fs.fstatSync(fd);
    if (!landed.isFile()) return { action: ACTIONS.REFUSED, reason: 'exclude-changed-under-open', file };
    const prefix = existing.length > 0 && !existing.endsWith('\n') ? '\n' : '';
    fs.writeSync(fd, prefix + EXCLUDE_COMMENT + '\n' + KEEP_FILENAME + '\n');
    return { action: 'added', file };
  } catch (error) {
    return { action: ACTIONS.REFUSED, reason: error && error.code ? error.code : 'append-failed', file };
  } finally {
    if (fd !== null) {
      try { fs.closeSync(fd); } catch {}
    }
  }
}

function sweepSiblings(baseRepo, nowMs, idleMs, options) {
  const opts = options || {};
  const maxDirs = Number.isInteger(opts.maxDirs) && opts.maxDirs > 0 ? Math.min(opts.maxDirs, MAX_SWEEP_DIRS) : MAX_SWEEP_DIRS;
  const skip = typeof opts.skipRoot === 'string' ? opts.skipRoot : null;
  const summary = { scanned: 0, created: 0, removed: 0, kept: 0, refused: 0, reaped: 0, truncated: false, skipped: 0 };
  const container = path.join(baseRepo, ...WORKTREES_SEGMENTS);
  const containerStat = lstatOrNull(container);
  if (containerStat === null || containerStat.isSymbolicLink() || !containerStat.isDirectory()) {
    return { ...summary, reason: containerStat === null ? 'no-worktrees-dir' : 'worktrees-dir-not-a-directory' };
  }
  let entries;
  try {
    entries = fs.readdirSync(container, { withFileTypes: true });
  } catch (error) {
    return { ...summary, reason: error && error.code ? error.code : 'unreadable' };
  }
  const dirs = entries.filter((entry) => entry.isDirectory() && !entry.isSymbolicLink()).map((entry) => entry.name).sort();
  for (const name of dirs) {
    if (summary.scanned >= maxDirs) {
      summary.truncated = true;
      break;
    }
    const root = path.join(container, name);
    if (skip !== null && root === skip) {
      summary.skipped += 1;
      continue;
    }
    const gitEntry = lstatOrNull(path.join(root, '.git'));
    if (gitEntry === null || gitEntry.isSymbolicLink() || !gitEntry.isFile()) {
      summary.skipped += 1;
      continue;
    }
    summary.scanned += 1;
    const result = reconcileKeep(root, nowMs, idleMs);
    summary.reaped += result.reaped || 0;
    if (result.action === ACTIONS.CREATED) summary.created += 1;
    else if (result.action === ACTIONS.REMOVED) summary.removed += 1;
    else if (result.action === ACTIONS.KEPT) summary.kept += 1;
    else if (result.action === ACTIONS.REFUSED) summary.refused += 1;
  }
  return summary;
}

function unresolvedRecord(record) {
  return Boolean(record) && record.branch === null && record.head === null;
}

function detectDrift(record, current) {
  if (!record || !current || current.ok !== true) return null;
  if (unresolvedRecord(record)) return null;
  const recorded = record.branch;
  const now = current.branch;
  if (recorded === null) {
    if (now === null) return null;
    return { from: null, to: now, head: current.head || null };
  }
  if (now === recorded) return null;
  return { from: recorded, to: now, head: current.head || null };
}

function branchSlug(branch) {
  const cleaned = String(branch || '')
    .replace(/[^A-Za-z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60);
  return cleaned.length > 0 ? cleaned : 'continue';
}

function describeBranch(branch) {
  if (branch === null) return 'a detached HEAD';
  if (branch === UNRENDERABLE_BRANCH) return 'a branch whose name this plugin does not render';
  return 'branch ' + branch;
}

function remedyLines(input) {
  const raw = input && typeof input.from === 'string' && input.from.length > 0 ? input.from : null;
  const from = raw !== null && branchNameOk(raw) ? raw : null;
  const slug = branchSlug(from);
  const lines = [
    'Do not switch this directory back' + (from ? ' to ' + from : '') + ': another session is working here now, and switching would pull the directory out from under that session.',
    'Continue in a worktree NESTED inside this directory. The desktop write-guard and the Zensu gates both admit it, while a sibling or temp-dir worktree is refused as sibling_worktree.',
  ];
  if (from) {
    lines.push('Create it with: git worktree add .claude/worktrees/' + slug + ' ' + from);
    lines.push('If git answers that ' + from + ' is already checked out elsewhere, use: git worktree add .claude/worktrees/' + slug + ' -b ' + from + '-cont ' + from);
    lines.push('Work and commit in .claude/worktrees/' + slug + ', then push with: git push origin HEAD:' + from);
  } else if (raw !== null) {
    lines.push('The recorded branch name is not one this plugin renders into a command; create the nested worktree by hand with: git worktree add --detach .claude/worktrees/' + slug + ' <the commit this session was working on>');
  } else {
    lines.push('Create it with: git worktree add --detach .claude/worktrees/' + slug + ' <the commit this session was working on>');
    lines.push('Work and commit there, then push the branch you create.');
  }
  lines.push('If a Zensu review chain is armed in this session, its gates and audits still measure this directory rather than the nested worktree: close the chain here first, or expect the completion and edit-landing audits to judge the outer tree.');
  lines.push('/zensu:doctor reports this state under "worktree:".');
  return lines;
}

function driftSentence(worktreeRoot, drift) {
  const head = drift && drift.head ? String(drift.head).slice(0, 12) : 'unknown';
  return worktreeRoot + ' is now on ' + describeBranch(drift.to) + ' (HEAD ' + head + ') but this session\'s anchor recorded '
    + describeBranch(drift.from) + ' when it started';
}

function disclosureText(record, drift) {
  return 'zensu worktree-keep: this session\'s worktree ' + driftSentence(record.worktreeRoot, drift) + '. '
    + 'If this session did not switch branches itself, another Claude session took over the directory: '
    + 'Claude Desktop reuses worktrees across accounts and does not see other accounts\' live sessions. '
    + remedyLines({ worktreeRoot: record.worktreeRoot, from: drift.from }).join(' ')
    + ' Tell the user in one sentence what happened and which worktree you will use.';
}

function freshRecord(sessionKey, worktreeRoot, current, nowMs) {
  return {
    schemaVersion: ANCHOR_SCHEMA_VERSION,
    sessionKey,
    worktreeRoot,
    branch: current && current.ok ? current.branch : null,
    head: current && current.ok ? current.head : null,
    recordedAt: nowMs,
    lastSeenAt: nowMs,
    drift: null,
  };
}

function sessionStart(input) {
  const out = { verb: 'session-start', managed: false, faults: [] };
  const managed = managedWorktree(input.cwd);
  if (!managed) return out;
  out.managed = true;
  out.worktreeRoot = managed.worktreeRoot;
  out.baseRepo = managed.baseRepo;
  if (!isSessionKey(input.sessionKey)) {
    out.faults.push('session-key-shape');
    return out;
  }
  const current = currentBranch(managed.worktreeRoot);
  if (!current.ok) out.faults.push('branch-unresolved');
  else if (current.branch === UNRENDERABLE_BRANCH) out.faults.push('branch-unrenderable');
  const existing = readAnchor(managed.worktreeRoot, input.sessionKey);
  let record;
  if (existing.status === 'ok' && RESUME_SOURCES.includes(input.source)) {
    record = { ...existing.record, lastSeenAt: input.nowMs };
  } else {
    record = freshRecord(input.sessionKey, managed.worktreeRoot, current, input.nowMs);
  }
  out.anchor = writeAnchor(managed.worktreeRoot, input.sessionKey, record);
  if (!out.anchor.ok) out.faults.push('anchor-write:' + out.anchor.reason);
  out.branch = record.branch;
  out.head = record.head;
  out.exclude = ensureExclude(managed.baseRepo);
  if (out.exclude.action === ACTIONS.REFUSED) out.faults.push('exclude:' + out.exclude.reason);
  out.keep = reconcileKeep(managed.worktreeRoot, input.nowMs, input.idleMs);
  if (out.keep.action === ACTIONS.REFUSED) out.faults.push('keep:' + out.keep.reason);
  out.sweep = sweepSiblings(managed.baseRepo, input.nowMs, input.idleMs, { maxDirs: input.maxDirs, skipRoot: managed.worktreeRoot });
  return out;
}

function prompt(input) {
  const out = { verb: 'prompt', managed: false, faults: [], disclosure: null, drift: null };
  const managed = managedWorktree(input.cwd);
  if (!managed) return out;
  out.managed = true;
  out.worktreeRoot = managed.worktreeRoot;
  if (!isSessionKey(input.sessionKey)) {
    out.faults.push('session-key-shape');
    return out;
  }
  const current = currentBranch(managed.worktreeRoot);
  if (!current.ok) out.faults.push('branch-unresolved');
  else if (current.branch === UNRENDERABLE_BRANCH) out.faults.push('branch-unrenderable');
  const existing = readAnchor(managed.worktreeRoot, input.sessionKey);
  let record;
  let dirty = false;
  if (existing.status === 'ok' && existing.record.worktreeRoot === managed.worktreeRoot) {
    record = existing.record;
    if (input.nowMs - record.lastSeenAt >= REFRESH_INTERVAL_MS || input.nowMs < record.lastSeenAt) {
      record = { ...record, lastSeenAt: input.nowMs };
      dirty = true;
    }
    if (unresolvedRecord(record) && current.ok) {
      record = { ...record, branch: current.branch, head: current.head, drift: null };
      dirty = true;
    }
  } else {
    if (existing.status === VERDICTS.REJECTED) out.faults.push('anchor:' + existing.reason);
    if (existing.status === 'ok') out.faults.push('anchor:worktree-root-mismatch');
    record = freshRecord(input.sessionKey, managed.worktreeRoot, current, input.nowMs);
    dirty = true;
  }
  const drift = detectDrift(record, current);
  if (drift) {
    out.drift = drift;
    const already = record.drift && record.drift.to === drift.to && record.drift.from === drift.from;
    if (!already) {
      record = { ...record, drift: { from: drift.from, to: drift.to, head: drift.head, detectedAt: input.nowMs } };
      dirty = true;
      out.disclosure = disclosureText(record, drift);
    }
  } else if (current.ok && record.drift !== null) {
    record = { ...record, drift: null };
    dirty = true;
  }
  if (dirty) {
    out.anchor = writeAnchor(managed.worktreeRoot, input.sessionKey, record);
    if (!out.anchor.ok) out.faults.push('anchor-write:' + out.anchor.reason);
  } else {
    out.anchor = { ok: true, unchanged: true };
  }
  out.keep = reconcileKeep(managed.worktreeRoot, input.nowMs, input.idleMs);
  if (out.keep.action === ACTIONS.REFUSED) out.faults.push('keep:' + out.keep.reason);
  out.branch = current.ok ? current.branch : null;
  out.recordedBranch = record.branch;
  return out;
}

function sessionEnd(input) {
  const out = { verb: 'session-end', managed: false, faults: [] };
  const managed = managedWorktree(input.cwd);
  if (!managed) return out;
  out.managed = true;
  out.worktreeRoot = managed.worktreeRoot;
  if (!isSessionKey(input.sessionKey)) {
    out.faults.push('session-key-shape');
    return out;
  }
  out.anchor = removeAnchor(managed.worktreeRoot, input.sessionKey);
  if (out.anchor.action === ACTIONS.REFUSED) out.faults.push('anchor-remove:' + out.anchor.reason);
  out.keep = reconcileKeep(managed.worktreeRoot, input.nowMs, input.idleMs);
  if (out.keep.action === ACTIONS.REFUSED) out.faults.push('keep:' + out.keep.reason);
  return out;
}

function inputFromEnv(env) {
  const now = Number(env.WK_NOW);
  const maxDirs = Number(env.WK_MAX_DIRS);
  return {
    cwd: typeof env.WK_CWD === 'string' ? env.WK_CWD : '',
    sessionKey: typeof env.WK_SESSION_KEY === 'string' ? env.WK_SESSION_KEY : '',
    source: typeof env.WK_SOURCE === 'string' ? env.WK_SOURCE : '',
    idleMs: idleMsFromHours(env.WK_IDLE_HOURS),
    nowMs: Number.isFinite(now) && now > 0 ? now : Date.now(),
    maxDirs: Number.isInteger(maxDirs) && maxDirs > 0 ? maxDirs : undefined,
  };
}

function run(verb, input) {
  if (verb === 'session-start') return sessionStart(input);
  if (verb === 'prompt') return prompt(input);
  if (verb === 'session-end') return sessionEnd(input);
  return { verb: String(verb), managed: false, faults: ['unknown-verb'] };
}

function hookEnvelope(result) {
  const stderr = [];
  if (result.keep && result.keep.action === ACTIONS.CREATED) {
    stderr.push('zensu: worktree-keep marker set in ' + result.worktreeRoot);
  }
  if (Array.isArray(result.faults) && result.faults.length > 0) {
    stderr.push('zensu: worktree-keep ' + result.verb + ' fault(s): ' + result.faults.join(', '));
  }
  let stdout = '';
  if (result.verb === 'prompt' && typeof result.disclosure === 'string' && result.disclosure.length > 0) {
    stdout = JSON.stringify({
      hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: result.disclosure },
    }) + '\n';
  }
  return { stdout, stderr };
}

function main(argv, env) {
  const verb = argv[2];
  let result;
  try {
    result = run(verb, inputFromEnv(env));
  } catch (error) {
    result = { verb: String(verb), managed: false, faults: ['exception:' + (error && error.message ? error.message : String(error))] };
  }
  if (env.WK_EMIT === 'claude-hook') {
    const envelope = hookEnvelope(result);
    for (const line of envelope.stderr) process.stderr.write(line + '\n');
    if (envelope.stdout) process.stdout.write(envelope.stdout);
    return 0;
  }
  process.stdout.write(JSON.stringify(result) + '\n');
  return 0;
}

module.exports = {
  KEEP_FILENAME,
  KEEP_SOURCE_BUILD,
  KEEP_SIGNATURE,
  KEEP_BODY,
  ANCHOR_PREFIX,
  ANCHOR_NAME_RE,
  ANCHOR_SCHEMA_VERSION,
  BRANCH_NAME_RE,
  STATE_SEGMENTS,
  WORKTREES_SEGMENTS,
  DEFAULT_IDLE_HOURS,
  MAX_IDLE_HOURS,
  REAP_FACTOR,
  MAX_ANCHOR_BYTES,
  MAX_MARKER_BYTES,
  MAX_EXCLUDE_BYTES,
  MAX_SWEEP_DIRS,
  MAX_ANCHOR_FILES,
  MARKER_STATES,
  UNRENDERABLE_BRANCH,
  branchValueOk,
  REFRESH_INTERVAL_MS,
  EXCLUDE_COMMENT,
  GIT_ENV_SCRUB,
  VERDICTS,
  ACTIONS,
  VERBS,
  idleMsFromHours,
  isSessionKey,
  branchNameOk,
  managedWorktree,
  anchorPath,
  openPlainFile,
  readAnchor,
  writeAnchor,
  removeAnchor,
  listAnchors,
  classifyAnchor,
  reapable,
  anchorVerdict,
  markerState,
  reconcileKeep,
  gitEnvironment,
  ensureExclude,
  sweepSiblings,
  currentBranch,
  unresolvedRecord,
  detectDrift,
  branchSlug,
  describeBranch,
  remedyLines,
  driftSentence,
  disclosureText,
  freshRecord,
  run,
  hookEnvelope,
  main,
};

if (require.main === module) {
  process.exitCode = main(process.argv, process.env);
}
