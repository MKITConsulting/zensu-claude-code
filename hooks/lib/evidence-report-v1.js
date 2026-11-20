'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { redact, rootSpellings } = require('./zensu-artifact-redact-v1.js');
const { scan, ALLOW_MARKER, PLACEHOLDER } = require('./secret-patterns.js');
const evidenceRun = require('./evidence-run-v1.js');
const acceptance = require('./acceptance-verify-v1.js');
const core = require('./session-control-core-v1.js');

const SCHEMA = 'zensu-evidence-report/v1';
const BINDING_SCHEMA = 'zensu-evidence-report-binding/v1';
const STORE_VERSION = 'v1';
const STORE_SEGMENTS = Object.freeze(['evidence-report', STORE_VERSION]);
const VERBS = Object.freeze(['begin', 'add', 'step', 'render', 'list', 'export']);
const ID_RE = /^vr1_[0-9]{13}_[0-9a-f]{12}$/;
const SESSION_KEY_RE = /^scv1_[0-9a-f]{64}$/;
const SHA_RE = /^[0-9a-f]{64}$/;
const COMMIT_RE = /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/;
const EVIDENCE_ID_RE = /^e[1-9][0-9]{0,5}$/;
const AC_RE = /^AC-([0-9]+)([a-z]?)$/;
const STEM_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$/;
const HOST_RE = /^[a-z0-9-]{2,32}$/;
const ISO_RE = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{3})?Z$/;
const REPO_KEY_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}-[0-9a-f]{10}$/;
const VERSION_RE = /^[0-9A-Za-z][0-9A-Za-z.+-]{0,63}$/;
const RECORD_RE = /^av1_[0-9]{13}_[0-9a-f]{12}$/;
const EVIDENCE_RUN_RE = /^er1_[0-9]{13}_[0-9a-f]{12}$/;
const REPOSITORY_RE = /^[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)+$/;
const ORIGIN_RE = /^https?:\/\/(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*|\[[0-9a-f:.]+\])(?::[0-9]{1,5})?$/;
const ROUTE_RE = /^\/[A-Za-z0-9\-._~!$&'()*+,;=:@%/]*$/;
const RECIPE_RE = /^[A-Za-z0-9._-][A-Za-z0-9._/-]{0,255}$/;
const BRANCH_RE = /^[^\u0000-\u0020\u007f~^:?*[\\]{1,255}$/;
const METHOD_RE = /^[A-Z]{3,10}$/;
const SIGNAL_CLASS_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$/;
const FEATURE_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const ZENSU_REF_RE = /^(?:AC|FR)-[0-9]+$/;
const VIEWPORT_ARG_RE = /^([1-9][0-9]{0,5})x([1-9][0-9]{0,5})(?:@([0-9]{1,2}(?:\.[0-9]{1,2})?))?$/;
const SCHEMA_NAME_RE = /^[A-Za-z0-9._/-]{1,80}$/;
const CHARACTER_RANGES = Object.freeze({
  layout: '\\u0009\\u000a\\u000d',
  c0: '\\u0000-\\u0008\\u000b\\u000c\\u000e-\\u001f',
  c1: '\\u007f-\\u009f',
  lineSeparators: '\\u2028\\u2029',
  bidi: '\\u200e\\u200f\\u202a-\\u202e\\u2066-\\u2069',
});
const SINGLE_LINE_FORBIDDEN = Object.freeze(['layout', 'c0', 'c1', 'lineSeparators', 'bidi']);
const TEXT_FILE_FORBIDDEN = Object.freeze(['c0', 'c1', 'bidi']);
const CONTROL_RE = characterClass(SINGLE_LINE_FORBIDDEN, 'g');
const SINGLE_LINE_FORBIDDEN_RE = characterClass(SINGLE_LINE_FORBIDDEN);
const TEXT_FILE_FORBIDDEN_RE = characterClass(TEXT_FILE_FORBIDDEN);
const REPORT_SECRET_RULES = Object.freeze([
  /\bauthorization["']?\s*[:=]\s*["']?(?:[A-Za-z0-9-]+\s+)?([^\s"']{12,})/gi,
  /\bbearer\s+((?=[A-Za-z0-9._~+/-]*[0-9])[A-Za-z0-9._~+/-]{16,}=*)/gi,
  /\b(eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,})/g,
  /\b[a-z][a-z0-9+.-]*:\/\/([^\s/?#@:]+:[^\s/?#@]+)@/gi,
  /\bx-api-key["']?\s*[:=]\s*["']?([^\s"']{12,})/gi,
]);
const COOKIE_HEADER_RE = /\b(?:set-)?cookie["']?\s*:\s*["']?([^\r\n"']*)/gi;
const COOKIE_PAIR_RE = /^\s*[^\s=;:"']+=([^\s;"']*)/;
const COOKIE_VALUE_MIN = 16;
const NAME_CHARACTER_RE = /[A-Za-z0-9_.-]/;
const OUTSIDE_GIT = 'not a git work tree';
const RUN_ROOT = '.zensu/verify-feature-runs/';
const TREE_FAILURE_RE = /^(?:work tree: )?(more than \d+ untracked files|untracked files exceed \d+ MiB|git timed out|not a git work tree)$/;
const TREE_CAUSE_RE = /^(?:more than \d+ untracked files|untracked files exceed \d+ MiB|git timed out|not a git work tree|git failed)$/;
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const PNG_IMAGE_CHUNKS = Object.freeze(['IHDR', 'PLTE', 'IDAT', 'IEND', 'tRNS', 'cHRM', 'gAMA', 'iCCP', 'sBIT', 'sRGB', 'cICP', 'mDCV', 'cLLI', 'bKGD', 'hIST', 'pHYs', 'sPLT']);
const PNG_ANIMATION_CHUNKS = Object.freeze(['acTL', 'fcTL', 'fdAT']);
const WEBP_IMAGE_CHUNKS = Object.freeze(['VP8X', 'VP8L', 'ICCP', 'VP8 ', 'ALPH', 'ANIM', 'ANMF']);
const WEBP_METADATA_FLAGS = 0x0c;

const VERDICTS = Object.freeze(['PASS', 'FAIL', 'PARTIAL']);
const MODES = Object.freeze(['local', 'remote']);
const CRITERION_STATES = Object.freeze(['pass', 'fail', 'partial', 'missing', 'stale', 'deprecated']);
const STEP_RESULTS = Object.freeze(['pass', 'fail', 'skip']);
const PRIORITIES = Object.freeze(['P0', 'P1', 'P2']);
const DRIVERS = Object.freeze(['browser', 'mobile', 'desktop', 'api', 'cli', 'async', 'iac', 'custom', 'library']);
const UI_DRIVERS = Object.freeze(['browser', 'mobile', 'desktop']);
const COVERAGE_SOURCES = Object.freeze(['acceptance-records', 'matrix']);
const EVIDENCE_KINDS = Object.freeze(['image', 'text', 'request', 'signal', 'run']);
const FILE_KINDS = Object.freeze(['image', 'text']);
const PLANES = Object.freeze(['visual', 'state', 'signal']);
const SIGNAL_SOURCES = Object.freeze(['console', 'network', 'runtime', 'log']);
const SECTION_STATES = Object.freeze(['clean', 'issues', 'not-checked']);
const CONSENT_DECISIONS = Object.freeze(['asked', 'remembered', 'policy-mode']);
const FILE_TYPES = Object.freeze({ 'image/png': 'png', 'image/webp': 'webp', 'text/plain': 'txt' });
const IMAGE_TYPES = Object.freeze(['image/png', 'image/webp']);
const DRIVER_SPELLINGS = new Map([['desktop-native', 'desktop']]);

const MANIFEST_KEYS = Object.freeze(['coverage', 'created_at', 'evidence', 'files', 'id', 'plugin_version', 'rendered_at', 'run', 'schema', 'sections', 'steps', 'target', 'verdict']);
const RUN_KEYS = Object.freeze(['attach', 'authenticated', 'chain', 'drivers', 'feature', 'host', 'mode', 'recipe']);
const CHAIN_KEYS = Object.freeze(['plan', 'stem']);
const TARGET_KEYS = Object.freeze(['begin_tree', 'branch', 'dirty', 'head', 'origin', 'repository', 'tree']);
const COVERAGE_KEYS = Object.freeze(['criteria', 'source']);
const CRITERION_KEYS = Object.freeze(['driver', 'evidence_run', 'id', 'note', 'record', 'state', 'steps', 'text', 'zensu']);
const ZENSU_KEYS = Object.freeze(['feature', 'ref']);
const STEP_KEYS = Object.freeze(['criteria', 'driver', 'evidence', 'expected', 'n', 'observed', 'priority', 'result', 'title']);
const EVIDENCE_KEYS = Object.freeze({
  image: Object.freeze(['caption', 'file', 'kind', 'plane']),
  text: Object.freeze(['caption', 'file', 'kind', 'plane']),
  request: Object.freeze(['kind', 'method', 'path', 'status']),
  signal: Object.freeze(['class', 'kind', 'message', 'source']),
  run: Object.freeze(['command', 'duration_ms', 'exit_code', 'kind', 'record']),
});
const FILE_KEYS = Object.freeze(['bytes', 'height', 'name', 'source_sha256', 'type', 'viewport', 'width']);
const VIEWPORT_KEYS = Object.freeze(['height', 'scale', 'width']);
const SECTIONS_KEYS = Object.freeze(['consent', 'console', 'limitations', 'network', 'resources']);
const CONSENT_KEYS = Object.freeze(['decided_by', 'origin', 'route']);
const BINDING_KEYS = Object.freeze(['begin_failure', 'created_at', 'criteria', 'evidence', 'files', 'id', 'plugin_version', 'project_root', 'rendered_at', 'run', 'run_dir', 'schema', 'session_key', 'steps', 'target']);
const DRAFT_CRITERION_KEYS = Object.freeze(['id', 'text', 'zensu']);

const VERB_ARGUMENTS = Object.freeze({
  begin: Object.freeze(['run-dir', 'mode', 'drivers', 'attach', 'recipe', 'origin', 'log']),
  add: Object.freeze(['report', 'kind', 'file', 'plane', 'viewport', 'method', 'path', 'status', 'source', 'class', 'evidence-run']),
  step: Object.freeze(['report', 'priority', 'driver', 'result', 'criteria', 'evidence', 'authenticated']),
  render: Object.freeze(['report', 'verdict', 'console', 'network', 'log']),
  list: Object.freeze(['limit']),
  export: Object.freeze(['report']),
});

const LIMITS = Object.freeze({
  maxFileBytes: 50 * 1024 * 1024,
  maxFiles: 2000,
  maxTextFileBytes: 64 * 1024,
  maxManifestBytes: 1024 * 1024,
  maxBindingBytes: 4 * 1024 * 1024,
  maxPixels: 100000000,
  maxStdinBytes: 64 * 1024,
  maxEvidence: 4000,
  maxSteps: 1000,
  maxCriteria: 500,
  maxConsent: 200,
  maxSectionLines: 100,
  maxExportBytes: 64 * 1024 * 1024,
  maxListed: 1000,
  defaultListed: 20,
  defaultKeep: 30,
  maxKeep: 100000,
  defaultMaxBytes: 2147483648,
  lockAttempts: 200,
  openReportMs: 14 * 24 * 60 * 60 * 1000,
  renderReserveBytes: 192 * 1024,
  chars: Object.freeze({
    feature: 2000,
    criterion: 400,
    note: 2000,
    title: 200,
    expected: 2000,
    observed: 2000,
    caption: 1000,
    message: 500,
    line: 500,
    command: 1000,
    path: 512,
  }),
});

const FAULT_CODES = Object.freeze([
  'schema.type', 'schema.unknown-key', 'schema.missing-key', 'schema.value', 'schema.limit', 'schema.duplicate', 'schema.version',
  'manifest.too-large', 'manifest.unreadable', 'manifest.unparseable',
  'criterion.absent', 'criterion.steps', 'criterion.no-image', 'step.unknown-criterion', 'step.unknown-evidence',
  'evidence.unknown-file', 'evidence.file-type',
  'file.unreferenced', 'file.missing', 'file.digest', 'file.size', 'file.type', 'file.metadata',
  'verdict.contradiction', 'verdict.empty', 'verdict.tree-changed',
]);

const SCHEMA_REMEDY = 'write the manifest as schema version 1 describes it, or render the report again with --report-render';
const STYLE = [
  ':root{color-scheme:light dark;--bg:#ffffff;--fg:#1f2328;--muted:#59636e;--line:#d1d9e0;--panel:#f6f8fa;--pass:#1a7f37;--fail:#d1242f;--partial:#9a6700;--neutral:#59636e}',
  '@media (prefers-color-scheme: dark){:root{--bg:#0d1117;--fg:#e6edf3;--muted:#9198a1;--line:#3d444d;--panel:#151b23;--pass:#3fb950;--fail:#f85149;--partial:#d29922;--neutral:#9198a1}}',
  '*{box-sizing:border-box}',
  'body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}',
  'main{max-width:1100px;margin:0 auto;padding:24px 16px 48px}',
  'h1{font-size:24px;margin:0 0 8px}',
  'h2{font-size:19px;margin:32px 0 8px;padding-bottom:4px;border-bottom:1px solid var(--line)}',
  'h3{font-size:16px;margin:16px 0 6px}',
  'table{border-collapse:collapse;width:100%;margin:8px 0}',
  'th,td{border-bottom:1px solid var(--line);padding:6px 8px;text-align:left;vertical-align:top}',
  'th{color:var(--muted);font-weight:600}',
  'code,pre{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:13px}',
  'code{background:var(--panel);padding:1px 4px;border-radius:4px;word-break:break-all}',
  'pre{background:var(--panel);padding:10px;border-radius:6px;overflow:auto;white-space:pre-wrap;word-break:break-word}',
  'figure{margin:12px 0}',
  'img{max-width:100%;height:auto;border:1px solid var(--line);border-radius:6px}',
  'figcaption,.muted{color:var(--muted);font-size:13px}',
  '.verdict{display:inline-block;font-weight:700;font-size:18px;padding:4px 12px;border-radius:6px;border:2px solid currentColor}',
  '.state-pass,.verdict-pass{color:var(--pass)}',
  '.state-fail,.verdict-fail{color:var(--fail)}',
  '.state-partial,.verdict-partial{color:var(--partial)}',
  '.state-missing,.state-stale,.state-deprecated,.state-skip{color:var(--neutral)}',
  'article{border:1px solid var(--line);border-radius:8px;padding:4px 16px 12px;margin:16px 0}',
  'footer{margin-top:40px;color:var(--muted);font-size:13px;border-top:1px solid var(--line);padding-top:12px}',
].join('');

class ReportError extends Error {
  constructor(message, code = 2) {
    super(message);
    this.name = 'ReportError';
    this.exitCode = code;
  }
}

function refuse(message) {
  throw new ReportError(message, 1);
}

function usage(message) {
  throw new ReportError(message, 2);
}

function unavailable(message) {
  throw new ReportError(message, 2);
}

function limitsWith(overrides) {
  if (!overrides) return LIMITS;
  return Object.freeze({ ...LIMITS, ...overrides, chars: Object.freeze({ ...LIMITS.chars, ...(overrides.chars || {}) }) });
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isString(value) {
  return typeof value === 'string';
}

function characterClass(names, flags) {
  return new RegExp(`[${names.map((name) => CHARACTER_RANGES[name]).join('')}]`, flags);
}

function schemaName(value) {
  return isString(value) && SCHEMA_NAME_RE.test(value) ? value : null;
}

function isoNow(now) {
  return new Date(now).toISOString().replace(/\.[0-9]{3}Z$/, 'Z');
}

function clockValue(options) {
  const value = typeof options.now === 'function' ? options.now() : Date.now();
  if (!Number.isInteger(value) || value < 0 || value > 9999999999999) unavailable('clock value out of range');
  return value;
}

function newReportId(now = Date.now()) {
  if (!Number.isInteger(now) || now < 0 || now > 9999999999999) unavailable('clock value out of range');
  return `vr1_${String(now).padStart(13, '0')}_${crypto.randomBytes(6).toString('hex')}`;
}

function sha256(data) {
  return crypto.createHash('sha256').update(data).digest('hex');
}

function isInside(parent, child) {
  const relative = path.relative(parent, child);
  return relative !== '' && relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function nativeSpelling(value, platform = process.platform) {
  return platform === 'win32' ? value.split('/').join(path.win32.sep) : value;
}

function samePath(left, right, platform = process.platform) {
  return platform === 'win32' ? left.toLowerCase() === right.toLowerCase() : left === right;
}

function linkFree(file, platform = process.platform) {
  return samePath(platform === 'win32' ? fs.realpathSync(file) : fs.realpathSync.native(file), file, platform);
}

function compareCriterionIds(left, right) {
  return acceptance.compareCriterionIds(left, right);
}

function evidenceNumber(id) {
  return Number(id.slice(1));
}

function sortedEvidenceIds(evidence) {
  return Object.keys(evidence).sort((left, right) => evidenceNumber(left) - evidenceNumber(right));
}

function syncDirectory(directory) {
  if (process.platform === 'win32') return;
  let descriptor;
  try {
    descriptor = fs.openSync(directory, 'r');
    fs.fsyncSync(descriptor);
  } catch { } finally {
    if (descriptor !== undefined) {
      try { fs.closeSync(descriptor); } catch { }
    }
  }
}

function assertRealDirectory(target, label) {
  let stat;
  try {
    stat = fs.lstatSync(target);
  } catch (error) {
    unavailable(`${label} ${target} is unavailable (${error.code || error.message})`);
  }
  if (stat.isSymbolicLink()) unavailable(`${label} ${target} is a symlink`);
  if (!stat.isDirectory()) unavailable(`${label} ${target} is not a directory`);
  if (process.platform !== 'win32' && typeof process.getuid === 'function' && stat.uid !== process.getuid()) {
    unavailable(`${label} ${target} belongs to another user`);
  }
  return stat;
}

function ensureDirectory(parent, name, label) {
  const target = path.join(parent, name);
  try {
    fs.mkdirSync(target, { mode: 0o700 });
  } catch (error) {
    if (error.code !== 'EEXIST') unavailable(`${label} ${target} cannot be created (${error.code || error.message})`);
  }
  assertRealDirectory(target, label);
  return target;
}

function writeAtomic(directory, name, data, mode = 0o600) {
  const target = path.join(directory, name);
  let existing = null;
  try {
    existing = fs.lstatSync(target);
  } catch (error) {
    if (error.code !== 'ENOENT') unavailable(`${target} is unreadable (${error.code || error.message})`);
  }
  if (existing && (existing.isSymbolicLink() || !existing.isFile())) unavailable(`${target} is not a regular file, so it is not replaced`);
  const temporary = path.join(directory, `.${name}.${crypto.randomBytes(6).toString('hex')}.tmp`);
  let descriptor;
  try {
    descriptor = fs.openSync(temporary, 'wx', mode);
  } catch (error) {
    unavailable(`${temporary} cannot be created (${error.code || error.message})`);
  }
  try {
    fs.writeFileSync(descriptor, data);
    fs.fsyncSync(descriptor);
  } catch (error) {
    try { fs.closeSync(descriptor); } catch { }
    try { fs.unlinkSync(temporary); } catch { }
    unavailable(`${target} could not be written (${error.code || error.message})`);
  }
  fs.closeSync(descriptor);
  try {
    fs.renameSync(temporary, target);
  } catch (error) {
    try { fs.unlinkSync(temporary); } catch { }
    unavailable(`${target} could not be written (${error.code || error.message})`);
  }
  syncDirectory(directory);
  return target;
}

function lockTarget(repository, id) {
  return { lockDirectory: repository, resourcePath: path.join(repository, `${id}.binding.json`) };
}

function acquireLock(target, attempts) {
  try {
    return core.acquireExternalProcessLock({ ...target, ownerPid: process.pid, attemptLimit: attempts }).token;
  } catch (error) {
    const reason = error && error.message ? error.message : String(error);
    if (reason.includes('timed out acquiring external process lock')) unavailable('another call holds this report\'s lock; run the verb again once it has finished');
    return unavailable(`the report lock cannot be taken (${reason})`);
  }
}

function releaseLock(target, token) {
  try {
    core.releaseExternalProcessLock({ ...target, ownerPid: process.pid, token });
  } catch { }
}

function lockHeld(target) {
  let lock;
  try {
    lock = core.inspectExternalProcessLock(target).lock;
  } catch {
    return true;
  }
  if (lock.state === 'absent') return false;
  if (lock.state === 'owned' || lock.state === 'ownerless') return !lock.stale;
  return true;
}

function withLock(target, limits, action) {
  const token = acquireLock(target, limits.lockAttempts);
  try {
    return action();
  } finally {
    releaseLock(target, token);
  }
}

function readBounded(filePath, maxBytes) {
  let descriptor;
  try {
    const before = fs.lstatSync(filePath);
    if (before.isSymbolicLink()) return { error: 'symlink' };
    if (!before.isFile()) return { error: 'not a regular file' };
    const noFollow = process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW) ? fs.constants.O_NOFOLLOW : 0;
    descriptor = fs.openSync(filePath, fs.constants.O_RDONLY | noFollow | (fs.constants.O_NONBLOCK || 0));
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile()) return { error: 'not a regular file' };
    if (stat.dev !== before.dev || stat.ino !== before.ino) return { error: 'replaced while it was opened' };
    if (stat.size > maxBytes) return { error: 'oversized', size: stat.size };
    const buffer = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < stat.size) {
      const read = fs.readSync(descriptor, buffer, offset, stat.size - offset, offset);
      if (read === 0) break;
      offset += read;
    }
    return { bytes: buffer.subarray(0, offset), stat: before };
  } catch (error) {
    return { error: error.code === 'ENOENT' ? 'missing' : `unreadable (${error.code || error.message})` };
  } finally {
    if (descriptor !== undefined) {
      try { fs.closeSync(descriptor); } catch { }
    }
  }
}

function readJson(filePath, maxBytes) {
  const loaded = readBounded(filePath, maxBytes);
  if (loaded.error) return { error: loaded.error };
  try {
    return { value: JSON.parse(loaded.bytes.toString('utf8')) };
  } catch {
    return { error: 'unparseable' };
  }
}

function normalizedText(text) {
  return String(text).replace(CONTROL_RE, ' ').replace(/\s+/g, ' ').trim();
}

function realValue(value) {
  return !PLACEHOLDER.test(value);
}

function cookieSecret(text) {
  for (const header of text.matchAll(COOKIE_HEADER_RE)) {
    for (const pair of header[1].split(';')) {
      const value = COOKIE_PAIR_RE.exec(pair);
      if (value && value[1].length >= COOKIE_VALUE_MIN && realValue(value[1])) return true;
    }
  }
  return false;
}

function secretMatch(text) {
  if (scan(text).matches.length > 0 || cookieSecret(text)) return true;
  return REPORT_SECRET_RULES.some((rule) => [...text.matchAll(rule)].some((match) => realValue(match[1])));
}

function ownRoots(context) {
  return [context.projectRoot, context.home].filter((root) => isString(root) && path.isAbsolute(root)
    && path.relative(path.parse(root).root, root).split(path.sep).filter(Boolean).length >= 2);
}

function ownPathMarks(context) {
  const options = { projectRoot: context.projectRoot, home: context.home };
  return ownRoots(context)
    .flatMap((root) => rootSpellings(root).map((spelling) => ({ spelling, mark: redact(root, options) })))
    .sort((a, b) => b.spelling.length - a.spelling.length);
}

function ownPathEnd(text, spelling, from) {
  for (let at = text.indexOf(spelling, from); at !== -1; at = text.indexOf(spelling, at + 1)) {
    let next = at + spelling.length;
    while (text.charAt(next) === '.') next += 1;
    if (!NAME_CHARACTER_RE.test(text.charAt(next))) return at;
  }
  return -1;
}

function namesOwnPath(text, context) {
  return ownPathMarks(context).some(({ spelling }) => ownPathEnd(text, spelling, 0) !== -1);
}

function scrubOwnPaths(text, context) {
  let out = text;
  for (const { spelling, mark } of ownPathMarks(context)) {
    for (let at = ownPathEnd(out, spelling, 0); at !== -1; at = ownPathEnd(out, spelling, at + mark.length)) {
      out = `${out.slice(0, at)}${mark}${out.slice(at + spelling.length)}`;
    }
  }
  return out;
}

function screenSecrets(text, context, label, options = {}) {
  const hint = options.hint || 'describe it without the value';
  if (text.includes(ALLOW_MARKER)) return { error: `${label} carries the ${ALLOW_MARKER} marker, which a report does not honor; remove it` };
  if (secretMatch(text)) return { error: `${label} matches a secret pattern; ${hint}` };
  if (options.paths === 'own' && namesOwnPath(text, context)) return { error: `${label} names a local path; ${hint}` };
  const redacted = redact(scrubOwnPaths(text, context), { projectRoot: context.projectRoot, home: context.home });
  if (secretMatch(redacted)) return { error: `${label} matches a secret pattern; ${hint}` };
  if (options.paths === 'any' && redacted !== text) return { error: `${label} names a local path; ${hint}` };
  return { value: options.paths === 'own' ? text : redacted };
}

function clipText(text, max) {
  let end = max - 1;
  if (/[\ud800-\udbff]/.test(text.charAt(end - 1))) end -= 1;
  return `${text.slice(0, end).trimEnd()}\u2026`;
}

function screenText(text, context, max, label, options = {}) {
  if (!isString(text) || text.trim() === '') return { error: `${label} is empty` };
  const screened = screenSecrets(text, context, label);
  if (screened.error) return screened;
  let cleaned = normalizedText(screened.value);
  if (cleaned === '') return { error: `${label} is empty` };
  if (cleaned.length > max) {
    if (!options.clip) return { error: `${label} exceeds ${max} characters` };
    cleaned = clipText(cleaned, max);
  }
  if (secretMatch(cleaned)) return { error: `${label} matches a secret pattern; describe it without the value` };
  return { value: cleaned };
}

function screenArgument(value, context, label, paths = 'any') {
  const screened = screenSecrets(value, context, label, { paths });
  if (screened.error) refuse(screened.error);
}

function parseFields(text, spec) {
  const entries = [];
  let current = null;
  const lines = String(text || '').replace(/\r\n?/g, '\n').split('\n');
  for (const line of lines) {
    const match = /^([a-z]+|AC-[0-9]+[a-z]?):(?:[ \t]+(.*)|)$/.exec(line);
    const key = match ? match[1] : null;
    const known = key !== null && (spec.single.includes(key) || spec.repeat.includes(key) || (spec.criteria && AC_RE.test(key)));
    if (known) {
      current = { key, value: match[2] || '' };
      entries.push(current);
      continue;
    }
    if (line.trim() === '') {
      if (current) current.value += '\n';
      continue;
    }
    if (!current) {
      return { error: `stdin must open with a field line such as '${spec.single[0] || spec.repeat[0]}: <text>'` };
    }
    current.value += `\n${line}`;
  }
  const single = new Map();
  const repeat = new Map(spec.repeat.map((key) => [key, []]));
  const criteria = [];
  for (const entry of entries) {
    if (spec.single.includes(entry.key)) {
      if (single.has(entry.key)) return { error: `stdin gives '${entry.key}:' more than once` };
      single.set(entry.key, entry.value);
    } else if (spec.repeat.includes(entry.key)) {
      repeat.get(entry.key).push(entry.value);
    } else {
      criteria.push({ id: entry.key, text: entry.value });
    }
  }
  return { single, repeat, criteria };
}

function withDropped(result, dropped, clean) {
  if (dropped.length === 0) return result;
  return { ...result, dropped: [...dropped].sort(), clean };
}

function sniffPng(bytes) {
  if (bytes.length < 33 || bytes.readUInt32BE(8) !== 13 || bytes.toString('latin1', 12, 16) !== 'IHDR') {
    return { error: 'the PNG has no IHDR header' };
  }
  const width = bytes.readUInt32BE(16);
  const height = bytes.readUInt32BE(20);
  if (width < 1 || height < 1) return { error: 'the PNG declares an empty image' };
  const kept = [bytes.subarray(0, 8)];
  const dropped = [];
  let offset = 8;
  for (;;) {
    if (offset + 12 > bytes.length) return { error: 'the PNG has no IEND chunk' };
    const size = bytes.readUInt32BE(offset);
    const type = bytes.toString('latin1', offset + 4, offset + 8);
    const end = offset + 12 + size;
    if (!/^[A-Za-z]{4}$/.test(type)) return { error: 'the PNG holds a malformed chunk' };
    if (size > 0x7fffffff || end > bytes.length) return { error: 'the PNG chunk list is truncated' };
    if (PNG_ANIMATION_CHUNKS.includes(type)) return { error: 'an animated PNG is not an image a report stores' };
    if (PNG_IMAGE_CHUNKS.includes(type)) kept.push(bytes.subarray(offset, end));
    else if (/^[A-Z]/.test(type)) return { error: `the PNG holds the unknown critical chunk ${type}` };
    else if (!dropped.includes(type)) dropped.push(type);
    offset = end;
    if (type === 'IEND') break;
  }
  if (offset !== bytes.length) return { error: 'the PNG carries bytes after its IEND chunk' };
  return withDropped({ type: 'image/png', width, height }, dropped, () => Buffer.concat(kept));
}

function sniffWebp(bytes) {
  if (bytes.readUInt32LE(4) + 8 !== bytes.length) return { error: 'the WebP container size does not match the file' };
  let offset = 12;
  let width = null;
  let height = null;
  let lossless = false;
  let lossy = false;
  let animated = false;
  const kept = [];
  const dropped = [];
  while (offset + 8 <= bytes.length) {
    const fourcc = bytes.toString('latin1', offset, offset + 4);
    const size = bytes.readUInt32LE(offset + 4);
    const data = offset + 8;
    if (data + size > bytes.length) return { error: 'the WebP chunk list is truncated' };
    if (fourcc === 'VP8X') {
      if (size < 10) return { error: 'the WebP extended header is truncated' };
      animated = animated || (bytes[data] & 0x02) !== 0;
      width = 1 + bytes.readUIntLE(data + 4, 3);
      height = 1 + bytes.readUIntLE(data + 7, 3);
    } else if (fourcc === 'VP8L') {
      if (size < 5 || bytes[data] !== 0x2f) return { error: 'the WebP lossless header is malformed' };
      lossless = true;
      if (width === null) {
        const bits = bytes.readUInt32LE(data + 1);
        width = (bits & 0x3fff) + 1;
        height = ((bits >>> 14) & 0x3fff) + 1;
      }
    } else if (fourcc === 'VP8 ') {
      lossy = true;
    } else if (fourcc === 'ANIM' || fourcc === 'ANMF') {
      animated = true;
    }
    const next = Math.min(bytes.length, data + size + (size % 2));
    if (WEBP_IMAGE_CHUNKS.includes(fourcc)) kept.push(bytes.subarray(offset, next));
    else if (!dropped.includes(fourcc)) dropped.push(fourcc);
    offset = data + size + (size % 2);
  }
  if (offset < bytes.length) return { error: 'the WebP chunk list is truncated' };
  if (animated) return { error: 'an animated WebP is not an image a report stores' };
  if (lossy) return { error: 'a lossy WebP is never stored as evidence; capture a PNG' };
  if (!lossless || width === null) return { error: 'the WebP holds no lossless image' };
  return withDropped({ type: 'image/webp', width, height }, dropped, () => {
    const body = Buffer.concat([bytes.subarray(8, 12), ...kept]);
    const head = Buffer.alloc(8);
    head.write('RIFF', 0, 'latin1');
    head.writeUInt32LE(body.length, 4);
    const clean = Buffer.concat([head, body]);
    if (clean.length >= 21 && clean.toString('latin1', 12, 16) === 'VP8X') clean[20] &= ~WEBP_METADATA_FLAGS;
    return clean;
  });
}

function sniffText(bytes) {
  if (bytes.length === 0) return { error: 'the file is empty' };
  let text;
  try {
    text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    return { error: 'the file is not a PNG, a lossless WebP or UTF-8 text' };
  }
  if (TEXT_FILE_FORBIDDEN_RE.test(text)) return { error: 'the text holds control characters other than tab and line breaks' };
  if (/^\s*</.test(text)) return { error: 'the text is markup (it opens with <), which a report never stores' };
  return { type: 'text/plain', text };
}

function sniff(bytes) {
  if (bytes.length >= 8 && bytes.subarray(0, 8).equals(PNG_SIGNATURE)) return sniffPng(bytes);
  if (bytes.length >= 16 && bytes.toString('latin1', 0, 4) === 'RIFF' && bytes.toString('latin1', 8, 12) === 'WEBP') {
    return sniffWebp(bytes);
  }
  return sniffText(bytes);
}

function parseViewport(value) {
  const match = VIEWPORT_ARG_RE.exec(value);
  if (!match) return null;
  const scale = match[3] === undefined ? 1 : Number(match[3]);
  if (!(scale > 0) || scale > 16) return null;
  return { width: Number(match[1]), height: Number(match[2]), scale };
}

function addFault(faults, code, at, message, remedy = SCHEMA_REMEDY) {
  faults.push({ code, at, message, remedy });
}

function exactKeys(value, keys, at, faults) {
  if (!isPlainObject(value)) {
    addFault(faults, 'schema.type', at, `${at || 'the manifest'} is not an object`);
    return false;
  }
  let exact = true;
  for (const key of Object.keys(value).sort()) {
    if (!keys.includes(key)) {
      addFault(faults, 'schema.unknown-key', at ? `${at}.${key}` : key, `${at ? `${at}.` : ''}${key} is not a key of schema version 1`);
      exact = false;
    }
  }
  for (const key of keys) {
    if (!Object.prototype.hasOwnProperty.call(value, key)) {
      addFault(faults, 'schema.missing-key', at ? `${at}.${key}` : key, `${at ? `${at}.` : ''}${key} is missing`);
      exact = false;
    }
  }
  return exact;
}

function textField(value, max, at, faults, options = {}) {
  if (options.nullable && value === null) return;
  if (!isString(value) || value.length === 0 || value.length > max || SINGLE_LINE_FORBIDDEN_RE.test(value) || value !== value.trim()) {
    addFault(faults, 'schema.value', at, `${at} must be a single-line text of 1 to ${max} characters${options.nullable ? ', or null' : ''}`);
  }
}

function patternField(value, pattern, at, faults, description, options = {}) {
  if (options.nullable && value === null) return;
  if (!isString(value) || !pattern.test(value)) {
    addFault(faults, 'schema.value', at, `${at} must be ${description}${options.nullable ? ', or null' : ''}`);
  }
}

function enumField(value, values, at, faults) {
  if (!values.includes(value)) addFault(faults, 'schema.value', at, `${at} must be one of ${values.join(', ')}`);
}

function integerField(value, min, max, at, faults, options = {}) {
  if (options.nullable && value === null) return;
  if (!Number.isInteger(value) || value < min || value > max) {
    addFault(faults, 'schema.value', at, `${at} must be an integer from ${min} to ${max}${options.nullable ? ', or null' : ''}`);
  }
}

function booleanField(value, at, faults, options = {}) {
  if (options.nullable && value === null) return;
  if (typeof value !== 'boolean') addFault(faults, 'schema.value', at, `${at} must be true or false${options.nullable ? ', or null' : ''}`);
}

function uniqueArray(value, at, faults, itemCheck, max) {
  if (!Array.isArray(value)) {
    addFault(faults, 'schema.type', at, `${at} is not an array`);
    return false;
  }
  if (value.length > max) {
    addFault(faults, 'schema.limit', at, `${at} holds more than ${max} entries`);
    return false;
  }
  const seen = new Set();
  let ok = true;
  value.forEach((item, index) => {
    if (!itemCheck(item, `${at}[${index}]`)) ok = false;
    const key = JSON.stringify(item);
    if (seen.has(key)) {
      addFault(faults, 'schema.duplicate', `${at}[${index}]`, `${at} names ${key} more than once`);
      ok = false;
    }
    seen.add(key);
  });
  return ok;
}

function zensuField(value, at, faults) {
  if (value === null || !exactKeys(value, ZENSU_KEYS, at, faults)) return;
  patternField(value.feature, FEATURE_ID_RE, `${at}.feature`, faults, 'a feature id');
  patternField(value.ref, ZENSU_REF_RE, `${at}.ref`, faults, 'a requirement ref such as AC-001');
}

function validateRun(run, faults, limits) {
  if (!exactKeys(run, RUN_KEYS, 'run', faults)) return;
  patternField(run.host, HOST_RE, 'run.host', faults, 'lowercase letters, digits and hyphens, 2 to 32 characters');
  enumField(run.mode, MODES, 'run.mode', faults);
  booleanField(run.attach, 'run.attach', faults);
  booleanField(run.authenticated, 'run.authenticated', faults);
  if (run.chain !== null && exactKeys(run.chain, CHAIN_KEYS, 'run.chain', faults)) {
    patternField(run.chain.stem, STEM_RE, 'run.chain.stem', faults, 'a plan stem');
    if (!isString(run.chain.stem) || run.chain.plan !== `.zensu/plans/${run.chain.stem}.md`) {
      addFault(faults, 'schema.value', 'run.chain.plan', 'run.chain.plan must be .zensu/plans/<stem>.md');
    }
  }
  textField(run.feature, limits.chars.feature, 'run.feature', faults);
  const driversOk = uniqueArray(run.drivers, 'run.drivers', faults, (item, at) => {
    if (!DRIVERS.includes(item)) {
      addFault(faults, 'schema.value', at, `${at} must be one of ${DRIVERS.join(', ')}`);
      return false;
    }
    return true;
  }, DRIVERS.length);
  if (driversOk && run.drivers.length === 0) addFault(faults, 'schema.value', 'run.drivers', 'run.drivers names no driver');
  if (run.recipe !== null && (!isString(run.recipe) || !RECIPE_RE.test(run.recipe) || run.recipe.split('/').includes('..'))) {
    addFault(faults, 'schema.value', 'run.recipe', 'run.recipe must be a relative path without .. segments, or null');
  }
}

function validateTarget(target, run, faults) {
  if (!exactKeys(target, TARGET_KEYS, 'target', faults)) return;
  patternField(target.repository, REPOSITORY_RE, 'target.repository', faults, 'an owner/name path', { nullable: true });
  patternField(target.branch, BRANCH_RE, 'target.branch', faults, 'a branch name', { nullable: true });
  patternField(target.head, COMMIT_RE, 'target.head', faults, 'a commit id', { nullable: true });
  patternField(target.tree, COMMIT_RE, 'target.tree', faults, 'a tree id', { nullable: true });
  patternField(target.begin_tree, COMMIT_RE, 'target.begin_tree', faults, 'a tree id', { nullable: true });
  booleanField(target.dirty, 'target.dirty', faults, { nullable: true });
  patternField(target.origin, ORIGIN_RE, 'target.origin', faults, 'scheme, host and port', { nullable: true });
  if (isPlainObject(run) && run.mode === 'remote' && target.origin === null) {
    addFault(faults, 'schema.value', 'target.origin', 'target.origin must name the origin in remote mode');
  }
  if (isPlainObject(run) && run.mode === 'local' && target.origin !== null) {
    addFault(faults, 'schema.value', 'target.origin', 'target.origin must be null in local mode');
  }
}

function validateFiles(files, faults, limits) {
  if (!isPlainObject(files)) {
    addFault(faults, 'schema.type', 'files', 'files is not an object');
    return false;
  }
  const keys = Object.keys(files).sort();
  if (keys.length > limits.maxFiles) {
    addFault(faults, 'schema.limit', 'files', `files holds more than ${limits.maxFiles} files`);
    return false;
  }
  let ok = true;
  for (const sha of keys) {
    const at = `files.${sha}`;
    if (!SHA_RE.test(sha)) {
      addFault(faults, 'schema.value', at, `${at} is not a SHA-256 digest`);
      ok = false;
      continue;
    }
    const entry = files[sha];
    if (!exactKeys(entry, FILE_KEYS, at, faults)) {
      ok = false;
      continue;
    }
    if (!Object.prototype.hasOwnProperty.call(FILE_TYPES, entry.type)) {
      addFault(faults, 'schema.value', `${at}.type`, `${at}.type must be one of ${Object.keys(FILE_TYPES).join(', ')}`);
      ok = false;
      continue;
    }
    if (entry.name !== `files/${sha}.${FILE_TYPES[entry.type]}`) {
      addFault(faults, 'schema.value', `${at}.name`, `${at}.name must be files/${sha}.${FILE_TYPES[entry.type]}`);
      ok = false;
    }
    const image = IMAGE_TYPES.includes(entry.type);
    integerField(entry.bytes, 1, image ? limits.maxFileBytes : limits.maxTextFileBytes, `${at}.bytes`, faults);
    if (image) {
      integerField(entry.width, 1, 1000000000, `${at}.width`, faults);
      integerField(entry.height, 1, 1000000000, `${at}.height`, faults);
      if (Number.isInteger(entry.width) && Number.isInteger(entry.height) && entry.width * entry.height > limits.maxPixels) {
        addFault(faults, 'schema.limit', at, `${at} holds more than ${limits.maxPixels} pixels`);
      }
      if (entry.viewport !== null && exactKeys(entry.viewport, VIEWPORT_KEYS, `${at}.viewport`, faults)) {
        integerField(entry.viewport.width, 1, 999999, `${at}.viewport.width`, faults);
        integerField(entry.viewport.height, 1, 999999, `${at}.viewport.height`, faults);
        if (typeof entry.viewport.scale !== 'number' || !(entry.viewport.scale > 0) || entry.viewport.scale > 16) {
          addFault(faults, 'schema.value', `${at}.viewport.scale`, `${at}.viewport.scale must be a number above 0 and at most 16`);
        }
      }
      patternField(entry.source_sha256, SHA_RE, `${at}.source_sha256`, faults, 'a SHA-256 digest', { nullable: true });
    } else {
      for (const key of ['width', 'height', 'viewport', 'source_sha256']) {
        if (entry[key] !== null) addFault(faults, 'schema.value', `${at}.${key}`, `${at}.${key} must be null for a text file`);
      }
    }
  }
  return ok;
}

function validateEvidence(evidence, faults, limits) {
  if (!isPlainObject(evidence)) {
    addFault(faults, 'schema.type', 'evidence', 'evidence is not an object');
    return false;
  }
  const ids = Object.keys(evidence);
  if (ids.length > limits.maxEvidence) {
    addFault(faults, 'schema.limit', 'evidence', `evidence holds more than ${limits.maxEvidence} items`);
    return false;
  }
  let ok = true;
  for (const id of sortedEvidenceIdsSafe(ids)) {
    const at = `evidence.${id}`;
    if (!EVIDENCE_ID_RE.test(id)) {
      addFault(faults, 'schema.value', at, `${at} is not an evidence id such as e1`);
      ok = false;
      continue;
    }
    const item = evidence[id];
    if (!isPlainObject(item)) {
      addFault(faults, 'schema.type', at, `${at} is not an object`);
      ok = false;
      continue;
    }
    if (!Object.prototype.hasOwnProperty.call(item, 'kind')) {
      addFault(faults, 'schema.missing-key', `${at}.kind`, `${at}.kind is missing`);
      ok = false;
      continue;
    }
    if (!EVIDENCE_KINDS.includes(item.kind)) {
      addFault(faults, 'schema.value', `${at}.kind`, `${at}.kind must be one of ${EVIDENCE_KINDS.join(', ')}`);
      ok = false;
      continue;
    }
    if (!exactKeys(item, EVIDENCE_KEYS[item.kind], at, faults)) {
      ok = false;
      continue;
    }
    if (FILE_KINDS.includes(item.kind)) {
      patternField(item.file, SHA_RE, `${at}.file`, faults, 'a SHA-256 digest');
      textField(item.caption, limits.chars.caption, `${at}.caption`, faults);
      enumField(item.plane, PLANES, `${at}.plane`, faults);
    } else if (item.kind === 'request') {
      patternField(item.method, METHOD_RE, `${at}.method`, faults, 'an upper-case HTTP method');
      if (!isString(item.path) || item.path.length > limits.chars.path || !ROUTE_RE.test(item.path)) {
        addFault(faults, 'schema.value', `${at}.path`, `${at}.path must be a path without query or fragment`);
      }
      integerField(item.status, 100, 599, `${at}.status`, faults);
    } else if (item.kind === 'signal') {
      enumField(item.source, SIGNAL_SOURCES, `${at}.source`, faults);
      patternField(item.class, SIGNAL_CLASS_RE, `${at}.class`, faults, 'a signal class such as error');
      textField(item.message, limits.chars.message, `${at}.message`, faults);
    } else {
      patternField(item.record, EVIDENCE_RUN_RE, `${at}.record`, faults, 'an er1_ evidence-run id');
      textField(item.command, limits.chars.command, `${at}.command`, faults);
      integerField(item.exit_code, 0, 999, `${at}.exit_code`, faults, { nullable: true });
      integerField(item.duration_ms, 0, Number.MAX_SAFE_INTEGER, `${at}.duration_ms`, faults, { nullable: true });
    }
  }
  return ok;
}

function sortedEvidenceIdsSafe(ids) {
  return [...ids].sort((left, right) => {
    const a = EVIDENCE_ID_RE.test(left) ? evidenceNumber(left) : Number.MAX_SAFE_INTEGER;
    const b = EVIDENCE_ID_RE.test(right) ? evidenceNumber(right) : Number.MAX_SAFE_INTEGER;
    return a - b || (left < right ? -1 : left > right ? 1 : 0);
  });
}

function validateSteps(steps, faults, limits) {
  if (!Array.isArray(steps)) {
    addFault(faults, 'schema.type', 'steps', 'steps is not an array');
    return false;
  }
  if (steps.length > limits.maxSteps) {
    addFault(faults, 'schema.limit', 'steps', `steps holds more than ${limits.maxSteps} rows`);
    return false;
  }
  let ok = true;
  steps.forEach((step, index) => {
    const at = `steps[${index}]`;
    if (!exactKeys(step, STEP_KEYS, at, faults)) {
      ok = false;
      return;
    }
    if (step.n !== index + 1) {
      addFault(faults, 'schema.value', `${at}.n`, `${at}.n must be ${index + 1}, because steps are numbered from 1 in order`);
      ok = false;
    }
    textField(step.title, limits.chars.title, `${at}.title`, faults);
    enumField(step.priority, PRIORITIES, `${at}.priority`, faults);
    enumField(step.driver, DRIVERS, `${at}.driver`, faults);
    enumField(step.result, STEP_RESULTS, `${at}.result`, faults);
    textField(step.expected, limits.chars.expected, `${at}.expected`, faults);
    textField(step.observed, limits.chars.observed, `${at}.observed`, faults);
    if (!uniqueArray(step.criteria, `${at}.criteria`, faults, (item, itemAt) => {
      if (!isString(item) || !AC_RE.test(item)) {
        addFault(faults, 'schema.value', itemAt, `${itemAt} must be a criterion id such as AC-001`);
        return false;
      }
      return true;
    }, limits.maxCriteria)) ok = false;
    if (!uniqueArray(step.evidence, `${at}.evidence`, faults, (item, itemAt) => {
      if (!isString(item) || !EVIDENCE_ID_RE.test(item)) {
        addFault(faults, 'schema.value', itemAt, `${itemAt} must be an evidence id such as e1`);
        return false;
      }
      return true;
    }, limits.maxEvidence)) ok = false;
  });
  return ok;
}

function validateCoverage(coverage, run, faults, limits) {
  if (!exactKeys(coverage, COVERAGE_KEYS, 'coverage', faults)) return;
  enumField(coverage.source, COVERAGE_SOURCES, 'coverage.source', faults);
  if (isPlainObject(run) && (run.chain === null) !== (coverage.source === 'matrix')) {
    addFault(faults, 'schema.value', 'coverage.source', 'coverage.source must be acceptance-records exactly when run.chain is set, and matrix otherwise');
  }
  if (!Array.isArray(coverage.criteria)) {
    addFault(faults, 'schema.type', 'coverage.criteria', 'coverage.criteria is not an array');
    return;
  }
  if (coverage.criteria.length > limits.maxCriteria) {
    addFault(faults, 'schema.limit', 'coverage.criteria', `coverage.criteria holds more than ${limits.maxCriteria} criteria`);
    return;
  }
  const seen = new Set();
  coverage.criteria.forEach((criterion, index) => {
    const at = `coverage.criteria[${index}]`;
    if (!exactKeys(criterion, CRITERION_KEYS, at, faults)) return;
    if (!isString(criterion.id) || !AC_RE.test(criterion.id)) {
      addFault(faults, 'schema.value', `${at}.id`, `${at}.id must be a criterion id such as AC-001`);
    } else if (seen.has(criterion.id)) {
      addFault(faults, 'schema.duplicate', `${at}.id`, `coverage.criteria lists ${criterion.id} more than once`);
    } else {
      seen.add(criterion.id);
    }
    textField(criterion.text, limits.chars.criterion, `${at}.text`, faults);
    enumField(criterion.state, CRITERION_STATES, `${at}.state`, faults);
    if (criterion.driver !== null) enumField(criterion.driver, DRIVERS, `${at}.driver`, faults);
    patternField(criterion.record, RECORD_RE, `${at}.record`, faults, 'an av1_ acceptance record id', { nullable: true });
    patternField(criterion.evidence_run, EVIDENCE_RUN_RE, `${at}.evidence_run`, faults, 'an er1_ evidence-run id', { nullable: true });
    if (coverage.source === 'matrix' && (criterion.record !== null || criterion.evidence_run !== null)) {
      addFault(faults, 'schema.value', `${at}.record`, `${at}.record and ${at}.evidence_run must be null in matrix mode`);
    }
    zensuField(criterion.zensu, `${at}.zensu`, faults);
    if (uniqueArray(criterion.steps, `${at}.steps`, faults, (item, itemAt) => {
      if (!Number.isInteger(item) || item < 1) {
        addFault(faults, 'schema.value', itemAt, `${itemAt} must be a step number`);
        return false;
      }
      return true;
    }, limits.maxSteps)) {
      for (let index2 = 1; index2 < criterion.steps.length; index2 += 1) {
        if (criterion.steps[index2] <= criterion.steps[index2 - 1]) {
          addFault(faults, 'schema.value', `${at}.steps`, `${at}.steps must ascend`);
          break;
        }
      }
    }
    textField(criterion.note, limits.chars.note, `${at}.note`, faults, { nullable: true });
  });
}

function validateSections(sections, faults, limits) {
  if (!exactKeys(sections, SECTIONS_KEYS, 'sections', faults)) return;
  enumField(sections.console, SECTION_STATES, 'sections.console', faults);
  enumField(sections.network, SECTION_STATES, 'sections.network', faults);
  if (!Array.isArray(sections.consent)) {
    addFault(faults, 'schema.type', 'sections.consent', 'sections.consent is not an array');
  } else if (sections.consent.length > limits.maxConsent) {
    addFault(faults, 'schema.limit', 'sections.consent', `sections.consent holds more than ${limits.maxConsent} entries`);
  } else {
    sections.consent.forEach((entry, index) => {
      const at = `sections.consent[${index}]`;
      if (!exactKeys(entry, CONSENT_KEYS, at, faults)) return;
      patternField(entry.origin, ORIGIN_RE, `${at}.origin`, faults, 'scheme, host and port');
      if (!isString(entry.route) || entry.route.length > limits.chars.path || !ROUTE_RE.test(entry.route)) {
        addFault(faults, 'schema.value', `${at}.route`, `${at}.route must be a path without query or fragment`);
      }
      enumField(entry.decided_by, CONSENT_DECISIONS, `${at}.decided_by`, faults);
    });
  }
  for (const key of ['limitations', 'resources']) {
    uniqueArray(sections[key], `sections.${key}`, faults, (item, at) => {
      const before = faults.length;
      textField(item, limits.chars.line, at, faults);
      return faults.length === before;
    }, limits.maxSectionLines);
  }
}

function validateManifest(manifest, limitsOverride) {
  const limits = limitsWith(limitsOverride);
  const faults = [];
  if (!isPlainObject(manifest)) {
    addFault(faults, 'schema.type', '', 'the manifest is not a JSON object');
    return faults;
  }
  if (manifest.schema !== SCHEMA) {
    const name = schemaName(manifest.schema);
    addFault(faults, 'schema.version', 'schema', name === null ? `the manifest names no schema this reader knows; schema must be ${SCHEMA}` : `the manifest names the schema ${name}, which this reader does not know`, `read it with a runtime that knows ${name === null ? 'its schema' : name}, or write it as ${SCHEMA}`);
    return faults;
  }
  if (!exactKeys(manifest, MANIFEST_KEYS, '', faults)) return faults;
  patternField(manifest.id, ID_RE, 'id', faults, 'a vr1_ report id');
  patternField(manifest.created_at, ISO_RE, 'created_at', faults, 'a UTC timestamp');
  patternField(manifest.rendered_at, ISO_RE, 'rendered_at', faults, 'a UTC timestamp', { nullable: true });
  patternField(manifest.plugin_version, VERSION_RE, 'plugin_version', faults, 'a version string', { nullable: true });
  enumField(manifest.verdict, VERDICTS, 'verdict', faults);
  validateRun(manifest.run, faults, limits);
  validateTarget(manifest.target, manifest.run, faults);
  validateFiles(manifest.files, faults, limits);
  validateEvidence(manifest.evidence, faults, limits);
  validateSteps(manifest.steps, faults, limits);
  validateCoverage(manifest.coverage, manifest.run, faults, limits);
  validateSections(manifest.sections, faults, limits);
  return faults;
}

function inspectStoredFile(bytes) {
  const sniffed = sniff(bytes);
  if (sniffed.error) return { type: null };
  return sniffed;
}

function targetOutsideGit(target) {
  return ['repository', 'branch', 'head', 'tree', 'begin_tree', 'dirty'].every((key) => target[key] === null);
}

function treeFailure(reason) {
  const known = TREE_FAILURE_RE.exec(isString(reason) ? reason : '');
  return known ? known[1] : 'git failed';
}

function treeCheck(target, context = {}) {
  const atBegin = isString(context.beginFailure) ? context.beginFailure : null;
  const atRender = isString(context.treeFailure) ? context.treeFailure : null;
  if (target.begin_tree !== null) {
    if (target.tree === null) return { state: 'render-unmeasured', atBegin: null, atRender };
    return { state: target.tree === target.begin_tree ? 'unchanged' : 'changed', atBegin: null, atRender: null };
  }
  const inGit = !targetOutsideGit(target) || context.beganOutsideGit === false;
  if (!inGit) return { state: 'outside', atBegin, atRender: null };
  return { state: target.tree === null ? 'unmeasured' : 'begin-unmeasured', atBegin, atRender };
}

function verdictFaults(manifest, context = {}) {
  const faults = [];
  const criteria = manifest.coverage.criteria;
  const failedCriteria = criteria.filter((criterion) => criterion.state === 'fail').map((criterion) => criterion.id);
  const failedP0 = manifest.steps.filter((step) => step.priority === 'P0' && step.result === 'fail').map((step) => `step ${step.n}`);
  const failed = [...failedCriteria, ...failedP0];
  if (failed.length > 0 && manifest.verdict !== 'FAIL') {
    addFault(faults, 'verdict.contradiction', 'verdict', `the stated verdict ${manifest.verdict} contradicts what failed: ${failed.join(', ')}`, 'state FAIL, because a failed criterion or a failed P0 row requires it');
  }
  if (manifest.verdict !== 'PASS' || failed.length > 0) return faults;
  const open = criteria.filter((criterion) => criterion.state !== 'pass' && criterion.state !== 'deprecated').map((criterion) => `${criterion.id} ${criterion.state}`);
  const openP0 = manifest.steps.filter((step) => step.priority === 'P0' && step.result !== 'pass').map((step) => `step ${step.n} ${step.result}`);
  const unmet = [...open, ...openP0];
  if (unmet.length > 0) {
    addFault(faults, 'verdict.contradiction', 'verdict', `the stated verdict PASS needs every in-scope criterion and every P0 row passed: ${unmet.join(', ')}`, 'state PARTIAL, or pass the open criteria and P0 rows first');
    return faults;
  }
  const passedCriterion = criteria.some((criterion) => criterion.state === 'pass');
  const passedP0 = manifest.steps.some((step) => step.priority === 'P0' && step.result === 'pass');
  if (!passedCriterion && !passedP0) {
    addFault(faults, 'verdict.empty', 'verdict', 'the stated verdict PASS rests on no passed criterion and no passed P0 row', 'state PARTIAL, or verify at least one criterion or P0 row first');
  }
  const { target } = manifest;
  if (manifest.coverage.source !== 'matrix' || manifest.run.mode !== 'local') return faults;
  const check = treeCheck(target, context);
  if (check.state === 'render-unmeasured') {
    addFault(faults, 'verdict.tree-changed', 'verdict', `the stated verdict PASS rests on rows recorded on a tree that could not be checked at --report-render (${target.begin_tree.slice(0, 12)} at --report-begin, not fingerprinted at --report-render${check.atRender ? `: ${check.atRender}` : ''})`, 'state PARTIAL, or render again once the working tree can be fingerprinted');
  } else if (check.state === 'changed') {
    addFault(faults, 'verdict.tree-changed', 'verdict', `the stated verdict PASS rests on rows recorded while the working tree changed (${target.begin_tree.slice(0, 12)} at --report-begin, ${target.tree.slice(0, 12)} at --report-render)`, 'state PARTIAL, or begin a new report and run the matrix again on the current tree');
  } else if (check.state === 'begin-unmeasured' || check.state === 'unmeasured') {
    const atBegin = check.atBegin ? ` (${check.atBegin})` : '';
    const atRender = check.state === 'unmeasured' ? `, and the tree at --report-render could not be fingerprinted either${check.atRender ? ` (${check.atRender})` : ''}` : `, so the tree ${target.tree.slice(0, 12)} at --report-render cannot be compared with it`;
    addFault(faults, 'verdict.tree-changed', 'verdict', `the stated verdict PASS rests on rows recorded on a tree that could not be fingerprinted at --report-begin${atBegin}${atRender}`, 'state PARTIAL, or begin a new report once the working tree can be fingerprinted');
  }
  return faults;
}

function integrityFaults(manifest, readFile, options = {}) {
  const faults = [];
  const criteria = manifest.coverage.criteria;
  const criterionIds = new Set(criteria.map((criterion) => criterion.id));
  const inScope = Array.isArray(options.inScope) ? options.inScope : [];
  for (const id of [...new Set(inScope)].sort(compareCriterionIds)) {
    if (!criterionIds.has(id)) {
      addFault(faults, 'criterion.absent', 'coverage.criteria', `the in-scope criterion ${id} is absent from the manifest`, `record a state for ${id}: in chain mode verify it, in matrix mode list it at --report-begin`);
    }
  }
  manifest.steps.forEach((step, index) => {
    for (const id of step.criteria) {
      if (!criterionIds.has(id)) {
        addFault(faults, 'step.unknown-criterion', `steps[${index}].criteria`, `step ${step.n} names the unknown criterion ${id}`, `name only criteria the coverage lists, or list ${id} at --report-begin`);
      }
    }
    for (const id of step.evidence) {
      if (!Object.prototype.hasOwnProperty.call(manifest.evidence, id)) {
        addFault(faults, 'step.unknown-evidence', `steps[${index}].evidence`, `step ${step.n} names the unknown evidence item ${id}`, 'name only evidence ids that --report-add returned for this report');
      }
    }
  });
  criteria.forEach((criterion, index) => {
    const expected = manifest.steps.filter((step) => step.criteria.includes(criterion.id)).map((step) => step.n);
    if (JSON.stringify(expected) !== JSON.stringify(criterion.steps)) {
      addFault(faults, 'criterion.steps', `coverage.criteria[${index}].steps`, `${criterion.id} lists steps ${criterion.steps.join(', ') || 'none'}, but the steps that name it are ${expected.join(', ') || 'none'}`, 'list exactly the steps whose criteria name the criterion');
    }
  });
  const referenced = new Set();
  for (const id of sortedEvidenceIds(manifest.evidence)) {
    const item = manifest.evidence[id];
    if (!FILE_KINDS.includes(item.kind)) continue;
    referenced.add(item.file);
    const entry = manifest.files[item.file];
    if (!entry) {
      addFault(faults, 'evidence.unknown-file', `evidence.${id}.file`, `evidence item ${id} names the file ${item.file}, which files does not list`, 'add the evidence file again with --report-add');
      continue;
    }
    const image = IMAGE_TYPES.includes(entry.type);
    if ((item.kind === 'image') !== image) {
      addFault(faults, 'evidence.file-type', `evidence.${id}.file`, `evidence item ${id} is ${item.kind === 'image' ? 'an image' : 'a text'} but its file is ${entry.type}`, `add the file with --kind ${image ? 'image' : 'text'}`);
    }
  }
  for (const sha of Object.keys(manifest.files).sort()) {
    if (!referenced.has(sha)) {
      addFault(faults, 'file.unreferenced', `files.${sha}`, `the file ${sha} is referenced by no evidence item`, 'drop the file from files, or add the evidence item that shows it');
    }
    const entry = manifest.files[sha];
    const loaded = readFile(sha, entry);
    if (!loaded || loaded.error) {
      addFault(faults, 'file.missing', `files.${sha}`, `the file ${entry.name} is missing from the bundle${loaded && loaded.error ? ` (${loaded.error})` : ''}`, `add the evidence file again with --report-add; the store copy of ${sha} is gone`);
      continue;
    }
    if (sha256(loaded.bytes) !== sha) {
      addFault(faults, 'file.digest', `files.${sha}`, `the file ${entry.name} does not match its SHA-256 digest`, `add the evidence file again with --report-add; the store copy of ${sha} was altered`);
      continue;
    }
    if (loaded.bytes.length !== entry.bytes) {
      addFault(faults, 'file.size', `files.${sha}.bytes`, `the file ${entry.name} holds ${loaded.bytes.length} bytes, not ${entry.bytes}`, 'state the size the file has');
    }
    const sniffed = inspectStoredFile(loaded.bytes);
    if (sniffed.type !== entry.type || (IMAGE_TYPES.includes(entry.type) && (sniffed.width !== entry.width || sniffed.height !== entry.height))) {
      addFault(faults, 'file.type', `files.${sha}.type`, `the file ${entry.name} is not the ${entry.type}${IMAGE_TYPES.includes(entry.type) ? ` of ${entry.width} x ${entry.height} pixels` : ''} the manifest declares`, 'state the type and size the content has, or add the evidence file again with --report-add');
    } else if (sniffed.dropped) {
      addFault(faults, 'file.metadata', `files.${sha}`, `the file ${entry.name} carries the metadata chunks ${sniffed.dropped.join(', ')}, which a report never stores`, 'add the evidence file again with --report-add, which drops metadata chunks');
    }
  }
  const stepByNumber = new Map(manifest.steps.map((step) => [step.n, step]));
  criteria.forEach((criterion, index) => {
    if (criterion.state !== 'pass' || !UI_DRIVERS.includes(criterion.driver)) return;
    const linked = criterion.steps.some((number) => {
      const step = stepByNumber.get(number);
      return step && step.evidence.some((id) => manifest.evidence[id] && manifest.evidence[id].kind === 'image');
    });
    if (!linked) {
      addFault(faults, 'criterion.no-image', `coverage.criteria[${index}]`, `${criterion.id} is recorded pass through ${criterion.driver}, but no step that names it links an image`, `link an image already in the report to a step that names ${criterion.id}, or record ${criterion.id} partial`);
    }
  });
  faults.push(...verdictFaults(manifest, options.verdictContext));
  return faults;
}

function checkManifest(manifest, readFile, options = {}) {
  const schemaFaults = validateManifest(manifest, options.limits);
  if (schemaFaults.length > 0) return schemaFaults;
  return integrityFaults(manifest, readFile, options);
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]);
}

function inlineText(value) {
  const parts = String(value).split('`');
  if (parts.length % 2 === 0) {
    const last = parts.pop();
    parts[parts.length - 1] += `\`${last}`;
  }
  return parts.map((part, index) => (index % 2 === 1 ? `<code>${escapeHtml(part)}</code>` : escapeHtml(part))).join('');
}

function formatCount(value) {
  return String(value).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

function formatDuration(milliseconds) {
  return Number.isInteger(milliseconds) ? `${(milliseconds / 1000).toFixed(1)} s` : 'no duration';
}

function formatScale(scale) {
  return Number.isInteger(scale) ? String(scale) : String(Number(scale.toFixed(2)));
}

function evidenceLines(id, item, manifest, readFile, exportMode) {
  if (item.kind === 'image') {
    const entry = manifest.files[item.file];
    const name = `files/${item.file}.${FILE_TYPES[entry.type]}`;
    const source = exportMode ? `data:${entry.type};base64,${readFile(item.file, entry).bytes.toString('base64')}` : name;
    const image = `<img src="${escapeHtml(source)}" alt="${escapeHtml(item.caption)}" width="${entry.width}" height="${entry.height}" loading="lazy" decoding="async">`;
    const viewport = entry.viewport ? ` | viewport ${entry.viewport.width} x ${entry.viewport.height} at scale ${formatScale(entry.viewport.scale)}` : ' | viewport not recorded';
    return [
      '<figure>',
      exportMode ? image : `<a href="${escapeHtml(name)}">${image}</a>`,
      `<figcaption>${escapeHtml(id)} | ${inlineText(item.caption)} | ${entry.width} x ${entry.height} px${viewport} | ${formatCount(entry.bytes)} bytes | ${escapeHtml(item.plane)} plane</figcaption>`,
      '</figure>',
    ];
  }
  if (item.kind === 'text') {
    const entry = manifest.files[item.file];
    const text = readFile(item.file, entry).bytes.toString('utf8');
    return [
      '<details>',
      `<summary>${escapeHtml(id)} | ${inlineText(item.caption)} | text, ${formatCount(entry.bytes)} bytes | ${escapeHtml(item.plane)} plane</summary>`,
      `<pre>${escapeHtml(text)}</pre>`,
      '</details>',
    ];
  }
  if (item.kind === 'request') {
    return [`<p>${escapeHtml(id)} | request | <code>${escapeHtml(item.method)} ${escapeHtml(item.path)}</code> answered ${item.status}</p>`];
  }
  if (item.kind === 'signal') {
    return [`<p>${escapeHtml(id)} | signal | ${escapeHtml(item.source)} ${escapeHtml(item.class)} | ${inlineText(item.message)}</p>`];
  }
  const exit = item.exit_code === null ? 'no exit code' : `exit ${item.exit_code}`;
  return [`<p>${escapeHtml(id)} | run <code>${escapeHtml(item.record)}</code> | ${exit} | ${formatDuration(item.duration_ms)} | <code>${escapeHtml(item.command)}</code></p>`];
}

function stateCounts(criteria) {
  const counts = CRITERION_STATES.map((state) => [state, criteria.filter((criterion) => criterion.state === state).length]).filter(([, count]) => count > 0);
  return counts.map(([state, count]) => `${state} ${count}`).join(', ');
}

function rowCounts(steps) {
  return PRIORITIES.map((priority) => {
    const rows = steps.filter((step) => step.priority === priority);
    if (rows.length === 0) return null;
    return `${priority} ${rows.filter((step) => step.result === 'pass').length} of ${rows.length} passed`;
  }).filter(Boolean).join(', ');
}

function targetRows(manifest) {
  const { run, target } = manifest;
  const rows = [
    ['Mode', `${escapeHtml(run.mode)}${run.attach ? ' (attached to a running target)' : ''}`],
    ['Host', escapeHtml(run.host)],
    ['Repository', target.repository === null ? 'none' : escapeHtml(target.repository)],
    ['Branch', target.branch === null ? 'none' : escapeHtml(target.branch)],
    ['Head', target.head === null ? 'none' : `<code>${escapeHtml(target.head)}</code>`],
    ['Tree', target.tree === null ? 'not fingerprinted' : `<code>${escapeHtml(target.tree)}</code>`],
    ...(target.begin_tree === target.tree ? [] : [['Tree at begin', target.begin_tree === null ? 'not fingerprinted' : `<code>${escapeHtml(target.begin_tree)}</code>`]]),
    ['Working tree', target.dirty === null ? 'unknown' : target.dirty ? 'has uncommitted changes' : 'clean'],
  ];
  if (target.origin !== null) rows.push(['Origin', `<code>${escapeHtml(target.origin)}</code>`]);
  rows.push(['Drivers', escapeHtml(run.drivers.join(', '))]);
  if (run.recipe !== null) rows.push(['Recipe', `<code>${escapeHtml(run.recipe)}</code>`]);
  if (run.chain !== null) rows.push(['Chain plan', `<code>${escapeHtml(run.chain.plan)}</code>`]);
  rows.push(['Manual login', run.authenticated ? 'yes' : 'no']);
  rows.push(['Created', escapeHtml(manifest.created_at)]);
  rows.push(['Rendered', manifest.rendered_at === null ? 'not rendered' : escapeHtml(manifest.rendered_at)]);
  return rows.map(([label, value]) => `<tr><th>${label}</th><td>${value}</td></tr>`);
}

function criterionDetail(criterion) {
  const details = [];
  if (criterion.record !== null) details.push(`record <code>${escapeHtml(criterion.record)}</code>`);
  if (criterion.evidence_run !== null) details.push(`run <code>${escapeHtml(criterion.evidence_run)}</code>`);
  if (criterion.zensu !== null) details.push(`Zensu ${escapeHtml(criterion.zensu.ref)} of feature <code>${escapeHtml(criterion.zensu.feature)}</code>`);
  const lines = [inlineText(criterion.text)];
  if (criterion.note !== null) lines.push(`<span class="muted">${inlineText(criterion.note)}</span>`);
  if (details.length > 0) lines.push(`<span class="muted">${details.join(' | ')}</span>`);
  return lines.join('<br>');
}

function renderHtml(manifest, readFile, options = {}) {
  const exportMode = options.mode === 'export';
  const out = [];
  const referenced = new Set(manifest.steps.flatMap((step) => step.evidence));
  out.push('<!doctype html>');
  out.push('<html lang="en">');
  out.push('<head>');
  out.push('<meta charset="utf-8">');
  out.push('<meta name="viewport" content="width=device-width, initial-scale=1">');
  out.push('<meta name="referrer" content="no-referrer">');
  out.push(`<title>Evidence report ${escapeHtml(manifest.id)} - ${escapeHtml(manifest.verdict)}</title>`);
  out.push(`<style>${STYLE}</style>`);
  out.push('</head>');
  out.push('<body>');
  out.push('<main>');
  out.push('<header>');
  out.push('<h1>Evidence report</h1>');
  out.push(`<p><span class="verdict verdict-${manifest.verdict.toLowerCase()}">Verdict: ${escapeHtml(manifest.verdict)}</span></p>`);
  out.push(`<p>${inlineText(manifest.run.feature)}</p>`);
  out.push('<table>');
  out.push(...targetRows(manifest));
  out.push('</table>');
  out.push('</header>');
  out.push('<section id="coverage">');
  out.push('<h2>Coverage</h2>');
  out.push(`<p>Source: ${manifest.coverage.source === 'matrix' ? 'the evidence matrix' : 'the acceptance records of the chain'}</p>`);
  const criteria = manifest.coverage.criteria;
  out.push(`<p>Criteria: ${criteria.length === 0 ? 'none' : `${criteria.length} (${stateCounts(criteria)})`}</p>`);
  out.push(`<p>Rows: ${manifest.steps.length === 0 ? 'none' : rowCounts(manifest.steps)}</p>`);
  if (criteria.length > 0) {
    out.push('<table>');
    out.push('<thead><tr><th>Criterion</th><th>State</th><th>Driver</th><th>Steps</th><th>Requirement</th></tr></thead>');
    out.push('<tbody>');
    for (const criterion of criteria) {
      out.push(`<tr><td><code>${escapeHtml(criterion.id)}</code></td><td class="state-${criterion.state}">${criterion.state}</td><td>${criterion.driver === null ? 'none' : escapeHtml(criterion.driver)}</td><td>${criterion.steps.length === 0 ? 'none' : criterion.steps.join(', ')}</td><td>${criterionDetail(criterion)}</td></tr>`);
    }
    out.push('</tbody>');
    out.push('</table>');
  }
  out.push('</section>');
  out.push('<section id="steps">');
  out.push('<h2>Steps</h2>');
  if (manifest.steps.length === 0) out.push('<p>No step was recorded.</p>');
  for (const step of manifest.steps) {
    out.push('<article>');
    out.push(`<h3>Step ${step.n}: ${inlineText(step.title)}</h3>`);
    out.push(`<p><span class="state-${step.result}">${step.result}</span> | ${step.priority} | ${escapeHtml(step.driver)} | criteria ${step.criteria.length === 0 ? 'none' : escapeHtml(step.criteria.join(', '))}</p>`);
    out.push(`<p><strong>Expected:</strong> ${inlineText(step.expected)}</p>`);
    out.push(`<p><strong>Observed:</strong> ${inlineText(step.observed)}</p>`);
    if (step.evidence.length === 0) out.push('<p class="muted">No evidence linked.</p>');
    for (const id of step.evidence) out.push(...evidenceLines(id, manifest.evidence[id], manifest, readFile, exportMode));
    out.push('</article>');
  }
  out.push('</section>');
  const unlinked = sortedEvidenceIds(manifest.evidence).filter((id) => !referenced.has(id) && manifest.evidence[id].kind !== 'signal');
  if (unlinked.length > 0) {
    out.push('<section id="unlinked">');
    out.push('<h2>Unlinked evidence</h2>');
    for (const id of unlinked) out.push(...evidenceLines(id, manifest.evidence[id], manifest, readFile, exportMode));
    out.push('</section>');
  }
  out.push('<section id="signals">');
  out.push('<h2>Signals</h2>');
  out.push(`<p>Console: ${manifest.sections.console === 'not-checked' ? 'not checked' : manifest.sections.console}</p>`);
  out.push(`<p>Network: ${manifest.sections.network === 'not-checked' ? 'not checked' : manifest.sections.network}</p>`);
  const signals = sortedEvidenceIds(manifest.evidence).filter((id) => manifest.evidence[id].kind === 'signal');
  if (signals.length === 0) out.push('<p>No signal was recorded.</p>');
  for (const id of signals) out.push(...evidenceLines(id, manifest.evidence[id], manifest, readFile, exportMode));
  out.push('</section>');
  out.push('<section id="consent">');
  out.push('<h2>Consent</h2>');
  if (manifest.sections.consent.length === 0) {
    out.push('<p>No consent record.</p>');
  } else {
    out.push('<table>');
    out.push('<thead><tr><th>Origin</th><th>Route</th><th>Decided by</th></tr></thead>');
    out.push('<tbody>');
    for (const entry of manifest.sections.consent) {
      out.push(`<tr><td><code>${escapeHtml(entry.origin)}</code></td><td><code>${escapeHtml(entry.route)}</code></td><td>${escapeHtml(entry.decided_by)}</td></tr>`);
    }
    out.push('</tbody>');
    out.push('</table>');
  }
  out.push('</section>');
  for (const [key, heading] of [['limitations', 'Limitations'], ['resources', 'Resources']]) {
    out.push(`<section id="${key}">`);
    out.push(`<h2>${heading}</h2>`);
    if (manifest.sections[key].length === 0) {
      out.push('<p>None.</p>');
    } else {
      out.push('<ul>');
      for (const line of manifest.sections[key]) out.push(`<li>${inlineText(line)}</li>`);
      out.push('</ul>');
    }
    out.push('</section>');
  }
  out.push(`<footer>Report <code>${escapeHtml(manifest.id)}</code> | Schema <code>${escapeHtml(manifest.schema)}</code> | Host <code>${escapeHtml(manifest.run.host)}</code> | Plugin <code>${manifest.plugin_version === null ? 'unknown' : escapeHtml(manifest.plugin_version)}</code></footer>`);
  out.push('</main>');
  out.push('</body>');
  out.push('</html>');
  return `${out.join('\n')}\n`;
}

function bundleReader(bundleDirectory, limits = LIMITS) {
  const cache = new Map();
  return (sha, entry) => {
    if (cache.has(sha)) return cache.get(sha);
    let result;
    if (!SHA_RE.test(sha) || !entry || !Object.prototype.hasOwnProperty.call(FILE_TYPES, entry.type)) {
      result = { error: 'not a file of schema version 1' };
    } else {
      const loaded = readBounded(path.join(bundleDirectory, 'files', `${sha}.${FILE_TYPES[entry.type]}`), limits.maxFileBytes);
      result = loaded.error ? { error: loaded.error } : { bytes: loaded.bytes };
    }
    cache.set(sha, result);
    return result;
  };
}

function renderBundle(manifest, bundleDirectory, options = {}) {
  const readFile = bundleReader(bundleDirectory, limitsWith(options.limits));
  const faults = checkManifest(manifest, readFile, options);
  if (faults.length > 0) return { faults };
  return { html: renderHtml(manifest, readFile, { mode: options.mode }) };
}

function loadManifest(bundleDirectory, limitsOverride) {
  const limits = limitsWith(limitsOverride);
  const loaded = readBounded(path.join(bundleDirectory, 'manifest.json'), limits.maxManifestBytes);
  if (loaded.error === 'oversized') {
    return { faults: [{ code: 'manifest.too-large', at: '', message: `the manifest holds more than ${limits.maxManifestBytes} bytes`, remedy: 'split the evidence across two reports' }] };
  }
  if (loaded.error) {
    return { faults: [{ code: 'manifest.unreadable', at: '', message: `the manifest cannot be read (${loaded.error})`, remedy: 'render the report again with --report-render' }] };
  }
  let manifest;
  try {
    manifest = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(loaded.bytes));
  } catch {
    return { faults: [{ code: 'manifest.unparseable', at: '', message: 'the manifest is not UTF-8 JSON', remedy: SCHEMA_REMEDY }] };
  }
  return { manifest };
}

function renderDirectory(bundleDirectory, options = {}) {
  const loaded = loadManifest(bundleDirectory, options.limits);
  if (loaded.faults) return loaded;
  return { manifest: loaded.manifest, ...renderBundle(loaded.manifest, bundleDirectory, options) };
}

function combineConfigLayers(raw) {
  const layers = isPlainObject(raw) ? raw : {};
  const user = isPlainObject(layers.user) ? layers.user : {};
  const project = isPlainObject(layers.project) ? layers.project : {};
  const has = (layer, key) => Object.prototype.hasOwnProperty.call(layer, key);
  const fromProject = (key) => has(project, key) && !(has(user, key) && JSON.stringify(user[key]) === JSON.stringify(project[key]));
  const value = {};
  if (user.enabled === false) {
    value.enabled = false;
    if (has(project, 'enabled') && project.enabled !== false) value.enabledFromProject = true;
  } else if (has(project, 'enabled')) {
    value.enabled = project.enabled;
  } else if (has(user, 'enabled')) {
    value.enabled = user.enabled;
  }
  if (has(user, 'dir')) value.dir = user.dir;
  if (has(project, 'keep')) value.keep = project.keep;
  else if (has(user, 'keep')) value.keep = user.keep;
  if (has(user, 'maxBytes')) value.maxBytes = user.maxBytes;
  if (fromProject('dir')) value.dirFromProject = true;
  if (fromProject('maxBytes')) value.maxBytesFromProject = true;
  return value;
}

function normalizeConfig(raw, limits = LIMITS) {
  const value = combineConfigLayers(raw);
  const disclosures = [];
  const enabled = value.enabled !== false;
  let dir = null;
  if (value.dir !== undefined && value.dir !== null && value.dir !== '') {
    if (isString(value.dir) && path.isAbsolute(value.dir) && !/[\u0000\r\n]/.test(value.dir)) {
      dir = path.resolve(value.dir);
    } else {
      disclosures.push('evidence.report.dir is not an absolute path, so the default store is used');
    }
  }
  let keep = limits.defaultKeep;
  if (value.keep !== undefined) {
    if (Number.isInteger(value.keep) && value.keep >= 1 && value.keep <= limits.maxKeep) keep = value.keep;
    else disclosures.push(`evidence.report.keep must be an integer from 1 to ${limits.maxKeep}, so the default of ${limits.defaultKeep} is used`);
  }
  let maxBytes = limits.defaultMaxBytes;
  if (value.maxBytes !== undefined) {
    if (Number.isInteger(value.maxBytes) && value.maxBytes >= 1) maxBytes = value.maxBytes;
    else disclosures.push(`evidence.report.maxBytes must be a positive integer, so the default of ${limits.defaultMaxBytes} is used`);
  }
  if (value.maxBytesFromProject === true) {
    disclosures.push('evidence.report.maxBytes caps the whole store, so it is read from the user configuration only and the project configuration\'s value is ignored');
  }
  if (value.dirFromProject === true) {
    disclosures.push('evidence.report.dir decides where every contributor\'s evidence is written, so it is read from the user configuration only and the project configuration\'s value is ignored');
  }
  if (value.enabledFromProject === true) {
    disclosures.push('the user configuration switched evidence reports off, and a project configuration can switch them off but never on');
  }
  return { enabled, dir, keep, maxBytes, disclosures: disclosures.map((line) => `zensu evidence report: ${line}`) };
}

function storeRoot(options, config, create) {
  if (config.dir) {
    if (create) {
      try {
        fs.mkdirSync(config.dir, { recursive: true, mode: 0o700 });
      } catch (error) {
        unavailable(`the configured store ${config.dir} cannot be created (${error.code || error.message})`);
      }
    } else if (!fs.existsSync(config.dir)) {
      return null;
    }
    assertRealDirectory(config.dir, 'the configured store');
    const base = fs.realpathSync.native(config.dir);
    if (create) return ensureDirectory(base, STORE_VERSION, 'the report store');
    const versioned = path.join(base, STORE_VERSION);
    if (!fs.existsSync(versioned)) return null;
    assertRealDirectory(versioned, 'the report store');
    return versioned;
  }
  if (!isString(options.pluginData) || !path.isAbsolute(options.pluginData)) unavailable('the plugin data directory is not an absolute path');
  assertRealDirectory(options.pluginData, 'the plugin data directory');
  let current = fs.realpathSync.native(options.pluginData);
  for (const segment of STORE_SEGMENTS) {
    if (create) {
      current = ensureDirectory(current, segment, 'the report store');
    } else {
      current = path.join(current, segment);
      if (!fs.existsSync(current)) return null;
      assertRealDirectory(current, 'the report store');
    }
  }
  return current;
}

function storePlacement(root) {
  const top = evidenceRun.workTreeTop(root);
  if (top.reason) return { ok: false, undetermined: true, reason: `whether the store ${root} lies in a git work tree could not be determined (${top.reason})` };
  if (top.top === null) return { ok: true, ignored: false };
  const topDirectory = top.top;
  const relative = path.relative(topDirectory, root).split(path.sep).join('/');
  if (relative === '') {
    return { ok: false, reason: `the store ${root} is the top level of a git work tree; move evidence.report.dir outside every git work tree` };
  }
  const probe = checkIgnore(topDirectory, `${relative}/`);
  if (probe.ignored === true) return { ok: true, ignored: true };
  if (probe.ignored === false) {
    return { ok: false, reason: `the store ${root} lies inside the git work tree ${topDirectory} and git does not report it ignored; move evidence.report.dir outside every git work tree, or have git ignore ${relative}/` };
  }
  return { ok: false, undetermined: true, reason: `whether git ignores the store could not be determined (${probe.reason})` };
}

function repositoryKey(projectRoot) {
  const result = evidenceRun.git(projectRoot, ['rev-parse', '--path-format=absolute', '--git-common-dir']);
  let anchor;
  let name;
  if (result.ok && result.stdout.trim() !== '') {
    try {
      anchor = fs.realpathSync.native(path.resolve(projectRoot, result.stdout.trim()));
    } catch (error) {
      unavailable(`the git directory of the project does not resolve (${error.code || error.message})`);
    }
    const clone = path.basename(anchor) === '.git' ? path.dirname(anchor) : anchor;
    name = path.basename(clone).replace(/\.git$/, '');
  } else if (!result.ok && evidenceRun.outsideWorkTree(result)) {
    anchor = fs.realpathSync.native(projectRoot);
    name = path.basename(anchor);
  } else {
    unavailable(`git could not name the repository of the project (${result.reason || 'no git directory'})`);
  }
  const safe = name.replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^[^A-Za-z0-9]+/, '').slice(0, 64) || 'repository';
  return `${safe}-${sha256(anchor).slice(0, 10)}`;
}

function repositoryFromRemote(url) {
  if (!isString(url)) return null;
  const value = url.trim();
  let pathPart = null;
  let match = /^[a-z][a-z0-9+.-]*:\/\/(?:[^@/\s]*@)?[^/\s]+\/(.+)$/i.exec(value);
  if (match) {
    pathPart = match[1];
  } else {
    match = /^(?:[^@/\s]+@)?[^:/\s]+:(?!\/)(.+)$/.exec(value);
    if (match) pathPart = match[1];
  }
  if (!pathPart) return null;
  pathPart = pathPart.replace(/\/+$/, '').replace(/\.git$/, '');
  if (pathPart.length > 200 || !REPOSITORY_RE.test(pathPart)) return null;
  return pathPart;
}

function measureTarget(options, scratch, mode, origin, chained) {
  const workTree = chained && options.chain && isString(options.chain.workTree) ? options.chain.workTree : '';
  const where = workTree || options.projectRoot;
  const target = { repository: null, branch: null, head: null, tree: null, begin_tree: null, dirty: null, origin: mode === 'remote' ? origin : null };
  const inside = evidenceRun.git(where, ['rev-parse', '--is-inside-work-tree']);
  if (!inside.ok) return { target, failure: evidenceRun.outsideWorkTree(inside) ? OUTSIDE_GIT : treeFailure(inside.reason) };
  if (inside.stdout.trim() !== 'true') return { target, failure: OUTSIDE_GIT };
  const head = evidenceRun.git(where, ['rev-parse', '--verify', '--quiet', 'HEAD']);
  if (head.ok && COMMIT_RE.test(head.stdout.trim())) target.head = head.stdout.trim();
  const branch = evidenceRun.git(where, ['symbolic-ref', '--quiet', '--short', 'HEAD']);
  if (branch.ok && BRANCH_RE.test(branch.stdout.trim())) target.branch = branch.stdout.trim();
  const remote = evidenceRun.git(where, ['config', '--get', 'remote.origin.url']);
  if (remote.ok) target.repository = repositoryFromRemote(remote.stdout);
  const tree = chained
    ? acceptance.chainTree({ projectRoot: options.projectRoot, workTree }, scratch).tree
    : evidenceRun.computeTree(options.projectRoot, scratch, evidenceRun.LIMITS);
  if (tree.tree && COMMIT_RE.test(tree.tree)) target.tree = tree.tree;
  const changes = acceptance.hasChanges(where);
  if (changes.known) target.dirty = changes.changed;
  const failure = target.tree === null ? treeFailure(tree.reason) : null;
  return { target, failure: failure === OUTSIDE_GIT ? 'git failed' : failure };
}

function readPluginVersion(manifestPath) {
  if (!isString(manifestPath) || manifestPath === '') return null;
  const loaded = readJson(manifestPath, 256 * 1024);
  if (loaded.error || !isPlainObject(loaded.value)) return null;
  return isString(loaded.value.version) && VERSION_RE.test(loaded.value.version) ? loaded.value.version : null;
}

function requireContext(options) {
  if (!isString(options.sessionKey) || !SESSION_KEY_RE.test(options.sessionKey)) unavailable('no valid session key is bound');
  if (!isString(options.projectRoot) || !path.isAbsolute(options.projectRoot)) unavailable('no project root is bound');
  assertRealDirectory(options.projectRoot, 'the project root');
  if (!isString(options.host) || !HOST_RE.test(options.host)) unavailable('the transport names no valid host');
}

function argumentMap(options, verb) {
  const allowed = VERB_ARGUMENTS[verb];
  const args = options.args instanceof Map ? options.args : new Map(Object.entries(options.args || {}));
  for (const key of args.keys()) {
    if (!allowed.includes(key)) usage(`--${key} is not an argument of --report-${verb}`);
  }
  return args;
}

function locations(options, config, reportId, create) {
  if (!isString(reportId) || !ID_RE.test(reportId)) usage('--report must name a report id such as vr1_1762250400000_0123456789ab');
  const root = storeRoot(options, config, create);
  if (root === null) refuse(`no report ${reportId} exists in this repository's store`);
  const key = repositoryKey(options.projectRoot);
  const repository = path.join(root, key);
  const bundle = path.join(repository, reportId);
  if (!create && !fs.existsSync(bundle)) refuse(`no report ${reportId} exists in this repository's store`);
  return {
    root,
    key,
    repository,
    bundle,
    files: path.join(bundle, 'files'),
    binding: path.join(repository, `${reportId}.binding.json`),
  };
}

function validateBinding(binding, expected, limits) {
  if (!isPlainObject(binding)) return 'the binding is not an object';
  if (binding.schema !== BINDING_SCHEMA) {
    const name = schemaName(binding.schema);
    return name === null ? `the binding names no schema this reader knows; it must be ${BINDING_SCHEMA}` : `the binding names the schema ${name}, which this reader does not know`;
  }
  const faults = [];
  if (!exactKeys(binding, BINDING_KEYS, 'binding', faults)) return faults[0].message;
  if (binding.id !== expected.id) return 'the binding names another report';
  if (!isString(binding.session_key) || !SESSION_KEY_RE.test(binding.session_key)) return 'malformed session key';
  if (!isString(binding.project_root) || !path.isAbsolute(binding.project_root)) return 'malformed project root';
  if (!isString(binding.run_dir) || !path.isAbsolute(binding.run_dir)) return 'malformed run directory';
  if (!isString(binding.created_at) || !ISO_RE.test(binding.created_at)) return 'malformed creation time';
  if (!(binding.rendered_at === null || (isString(binding.rendered_at) && ISO_RE.test(binding.rendered_at)))) return 'malformed render time';
  if (!(binding.plugin_version === null || (isString(binding.plugin_version) && VERSION_RE.test(binding.plugin_version)))) return 'malformed plugin version';
  if (!(binding.begin_failure === null || (isString(binding.begin_failure) && TREE_CAUSE_RE.test(binding.begin_failure)))) return 'malformed begin failure';
  validateRun(binding.run, faults, limits);
  validateTarget(binding.target, binding.run, faults);
  if (faults.length === 0 && (binding.begin_failure === null) !== (binding.target.begin_tree !== null)) return 'the begin failure contradicts the begin tree';
  validateFiles(binding.files, faults, limits);
  validateEvidence(binding.evidence, faults, limits);
  validateSteps(binding.steps, faults, limits);
  if (!Array.isArray(binding.criteria)) return 'malformed criteria';
  binding.criteria.forEach((criterion, index) => {
    if (!exactKeys(criterion, DRAFT_CRITERION_KEYS, `criteria[${index}]`, faults)) return;
    patternField(criterion.id, AC_RE, `criteria[${index}].id`, faults, 'a criterion id');
    textField(criterion.text, limits.chars.criterion, `criteria[${index}].text`, faults);
    zensuField(criterion.zensu, `criteria[${index}].zensu`, faults);
  });
  return faults.length > 0 ? `${faults[0].at}: ${faults[0].message}` : null;
}

function loadBinding(where, reportId, options, limits, requireOwner) {
  let stat;
  try {
    stat = fs.lstatSync(where.bundle);
  } catch {
    refuse(`no report ${reportId} exists in this repository's store`);
  }
  if (stat.isSymbolicLink() || !stat.isDirectory()) unavailable(`the report directory of ${reportId} is not a real directory`);
  const loaded = readJson(where.binding, limits.maxBindingBytes);
  if (loaded.error) unavailable(`the binding of ${reportId} cannot be read (${loaded.error})`);
  const problem = validateBinding(loaded.value, { id: reportId }, limits);
  if (problem) unavailable(`the binding of ${reportId} is invalid (${problem})`);
  if (requireOwner && loaded.value.session_key !== options.sessionKey) {
    refuse(`report ${reportId} belongs to another session; begin a report in this session`);
  }
  return loaded.value;
}

function writeBinding(where, binding) {
  writeAtomic(where.repository, path.basename(where.binding), `${JSON.stringify(binding, null, 2)}\n`);
}

function context(options) {
  return { projectRoot: options.projectRoot, home: isString(options.home) ? options.home : '' };
}

function stdinOf(options, limits) {
  const text = isString(options.stdinText) ? options.stdinText : '';
  if (Buffer.byteLength(text) > limits.maxStdinBytes) refuse(`stdin exceeds ${limits.maxStdinBytes} bytes`);
  return text;
}

function manifestOf(binding, parts) {
  return {
    schema: SCHEMA,
    id: binding.id,
    created_at: binding.created_at,
    rendered_at: parts.renderedAt,
    plugin_version: binding.plugin_version,
    run: binding.run,
    target: parts.target,
    verdict: parts.verdict,
    coverage: { source: binding.run.chain === null ? 'matrix' : 'acceptance-records', criteria: parts.criteria },
    steps: binding.steps,
    evidence: binding.evidence,
    files: binding.files,
    sections: parts.sections,
  };
}

function serializeManifest(manifest) {
  return `${JSON.stringify(manifest, null, 2)}\n`;
}

function criterionRow(id, text, fields = {}) {
  return { id, text, state: 'missing', driver: null, record: null, evidence_run: null, zensu: null, steps: [], note: null, ...fields };
}

function stepNumbers(binding, id) {
  return binding.steps.filter((entry) => entry.criteria.includes(id)).map((entry) => entry.n);
}

function chainNoteReserve(limits) {
  return 3 * limits.chars.note + 128;
}

function draftSize(binding, limits) {
  const rows = binding.run.chain === null
    ? matrixCoverage(binding).criteria
    : binding.criteria.map((criterion) => criterionRow(criterion.id, criterion.text, { zensu: criterion.zensu }));
  const criteria = rows.map((row) => ({ ...row, steps: stepNumbers(binding, row.id) }));
  const sections = { console: 'not-checked', network: 'not-checked', consent: [], limitations: [], resources: [] };
  const manifest = manifestOf(binding, { renderedAt: binding.created_at, target: binding.target, verdict: 'PARTIAL', criteria, sections });
  const notes = binding.run.chain === null ? 0 : binding.criteria.length * chainNoteReserve(limits);
  return Buffer.byteLength(serializeManifest(manifest)) + limits.renderReserveBytes + notes;
}

function planChanges(binding, criteria) {
  if (binding.run.chain === null) return [];
  const begun = new Map(binding.criteria.map((criterion) => [criterion.id, criterion.text]));
  return criteria.filter((criterion) => begun.get(criterion.id) !== criterion.text).map((criterion) => criterion.id);
}

function checkDraftSize(binding, limits) {
  if (draftSize(binding, limits) > limits.maxManifestBytes) {
    refuse(`the report would outgrow the manifest cap of ${limits.maxManifestBytes} bytes, which keeps room for what --report-render adds; begin a new report for further evidence`);
  }
}

function fittingCriteria(binding, limits) {
  let low = 0;
  let high = binding.criteria.length;
  while (low < high) {
    const middle = Math.ceil((low + high) / 2);
    if (draftSize({ ...binding, criteria: binding.criteria.slice(0, middle) }, limits) <= limits.maxManifestBytes) low = middle;
    else high = middle - 1;
  }
  return low;
}

function checkBeginSize(binding, limits) {
  if (draftSize(binding, limits) <= limits.maxManifestBytes) return;
  if (binding.run.chain !== null) {
    refuse(`a report of the chain's plan ${binding.run.chain.plan} would hold ${binding.criteria.length} criteria, but one report holds at most ${fittingCriteria(binding, limits)} of them, because each keeps ${chainNoteReserve(limits)} bytes of the ${limits.maxManifestBytes}-byte manifest free for the note --report-render adds; verify this chain without a report`);
  }
  refuse(`the report would outgrow the manifest cap of ${limits.maxManifestBytes} bytes before its first item; shorten the feature text or give fewer criteria`);
}

function chainOptions(options) {
  return {
    pluginData: options.pluginData,
    sessionKey: options.sessionKey,
    projectRoot: options.projectRoot,
    receiptPath: options.chain && options.chain.receiptPath ? options.chain.receiptPath : '',
    logPath: options.chain && options.chain.logPath ? options.chain.logPath : '',
    editLandingEscaped: Boolean(options.chain && options.chain.editLandingEscaped),
    workTree: options.chain && options.chain.workTree ? options.chain.workTree : '',
    workTreeFault: options.chain ? options.chain.workTreeFault : null,
    bashPath: options.chain && options.chain.bashPath ? options.chain.bashPath : 'bash',
  };
}

function checkRunDirectory(given, projectRoot, root, chainRoot = null) {
  if (!isString(given) || !path.isAbsolute(given)) usage('--run-dir must name the run directory by an absolute path');
  const runDirectory = nativeSpelling(given);
  if (path.resolve(runDirectory) !== runDirectory) usage('--run-dir must be a normalized path without . or .. segments');
  let stat;
  try {
    stat = fs.lstatSync(runDirectory);
  } catch {
    refuse(`the run directory ${runDirectory} does not exist${runRootHint(runDirectory, projectRoot)}`);
  }
  if (stat.isSymbolicLink()) refuse(`the run directory ${runDirectory} is a symlink; pass its physical path`);
  if (!stat.isDirectory()) refuse(`the run directory ${runDirectory} is not a directory`);
  if (!linkFree(runDirectory)) refuse(`the run directory ${runDirectory} runs through a symlink; pass its physical path${runRootHint(runDirectory, projectRoot)}`);
  const real = fs.realpathSync.native(runDirectory);
  const top = evidenceRun.workTreeTop(projectRoot);
  if (top.reason) unavailable(`whether the run directory lies in the project's work tree could not be determined (${top.reason})`);
  const base = top.top || fs.realpathSync.native(projectRoot);
  if (!isInside(base, real)) refuse(top.top === null ? `the run directory must lie inside the project root ${base}, which lies outside git` : `the run directory must lie inside the project's work tree ${base}`);
  if (real === root || isInside(root, real) || isInside(real, root)) {
    refuse('the run directory must not overlap the report store');
  }
  if (path.relative(base, real).split(path.sep).includes('.git')) {
    refuse(`the run directory ${real} lies inside .git; ${runRootRemedy(top.top, base)}`);
  }
  const own = evidenceRun.workTreeTop(real);
  if (own.reason) unavailable(`whether git ignores the run directory could not be determined (${own.reason})`);
  if (own.top !== null) {
    if (samePath(own.top, real)) refuse(`the run directory ${real} is the top of a git work tree, which that work tree cannot ignore; ${runRootRemedy(top.top, base)}`);
    const projectReal = fs.realpathSync.native(projectRoot);
    const trees = [{ root: projectReal, top: top.top }];
    const chainReal = realDirectory(chainRoot);
    if (chainReal !== null && !samePath(chainReal, projectReal)) trees.push({ root: chainReal, top: chainReal });
    requireIgnored(own.top, real, projectReal, trees.some((tree) => tree.top !== null && samePath(tree.top, own.top) && fingerprinted(tree.root, real)), top.top);
  }
  return real;
}

function realDirectory(directory) {
  if (!isString(directory) || directory === '') return null;
  try {
    return fs.realpathSync.native(directory);
  } catch {
    return null;
  }
}

function fingerprinted(treeRoot, real) {
  const excluded = path.join(treeRoot, '.zensu');
  return (samePath(real, treeRoot) || isInside(treeRoot, real)) && !samePath(real, excluded) && !isInside(excluded, real);
}

function checkIgnore(tree, spelled) {
  const answer = evidenceRun.git(tree, ['check-ignore', '-q', '--', `./${spelled}`]);
  if (answer.ok) return { ignored: true };
  if (answer.status === 1) return { ignored: false };
  return { ignored: null, reason: answer.reason };
}

function untracked(tree, spelled) {
  const tracked = evidenceRun.git(tree, ['--literal-pathspecs', 'ls-files', '-z', '--', spelled]);
  return tracked.ok && tracked.stdout === '';
}

function holdsOnly(tree, parent, spelled) {
  const others = evidenceRun.git(tree, ['--literal-pathspecs', 'ls-files', '-z', '--others', '--exclude-standard', '--', parent]);
  return others.ok && others.stdout.split('\0').every((entry) => entry === '' || entry.startsWith(spelled));
}

function holdsPath(directory, inner) {
  return samePath(directory, inner) || isInside(directory, inner);
}

function isRunRoot(directory, tree, projectRoot) {
  return [tree, projectRoot].some((root) => samePath(directory, path.resolve(root, RUN_ROOT)));
}

function isZensuRoot(directory, tree, projectRoot) {
  return [tree, projectRoot].some((root) => samePath(directory, path.join(root, '.zensu')));
}

function ignoreTarget(tree, real, projectRoot, relative) {
  if (SINGLE_LINE_FORBIDDEN_RE.test(relative.join('/'))) return null;
  const spelled = `${relative.join('/')}/`;
  const parent = `${relative.slice(0, -1).join('/')}/`;
  const above = path.dirname(real);
  if (relative.length >= 2 && !holdsPath(above, projectRoot) && !isZensuRoot(above, tree, projectRoot) && untracked(tree, parent) && (isRunRoot(above, tree, projectRoot) || holdsOnly(tree, parent, spelled))) return parent;
  return !holdsPath(real, projectRoot) && !isZensuRoot(real, tree, projectRoot) && untracked(tree, spelled) ? spelled : null;
}

function ignoreLine(spelled) {
  return `/${spelled.replace(/[\\*?[]/g, (character) => `\\${character}`)}`;
}

function runRootObstacle(root) {
  if (!isString(root)) return null;
  const segments = RUN_ROOT.split('/').filter((segment) => segment !== '');
  for (let count = 1; count <= segments.length; count += 1) {
    let stat;
    try {
      stat = fs.lstatSync(path.join(root, ...segments.slice(0, count)), { throwIfNoEntry: false });
    } catch {
      return null;
    }
    if (stat === undefined) return null;
    if (stat.isSymbolicLink() || !stat.isDirectory()) return { entry: segments.slice(0, count).join('/'), link: stat.isSymbolicLink() };
  }
  return null;
}

function runRootHint(runDirectory, projectRoot) {
  const top = evidenceRun.workTreeTop(projectRoot);
  if (top.reason) return '';
  const base = top.top || realDirectory(projectRoot);
  const obstacle = runRootObstacle(base);
  return obstacle !== null && holdsPath(path.join(base, ...obstacle.entry.split('/')), runDirectory) ? `; ${runRootRemedy(top.top, base)}` : '';
}

function runRootRemedy(tree, projectRoot) {
  const outside = !isString(tree);
  const obstacle = runRootObstacle(outside ? projectRoot : tree);
  if (obstacle !== null) {
    const blocked = `${RUN_ROOT} cannot hold it, because ${obstacle.entry} ${outside ? 'in the project root' : 'at the top of the work tree'} ${obstacle.link ? 'is a symbolic link; replace that link' : 'is not a directory; replace it'} with a directory`;
    return outside
      ? `${blocked}, or create the run directory in another directory of the project root that lies outside every git work tree`
      : `${blocked} and, unless git already ignores ${RUN_ROOT}, add the line /${RUN_ROOT} to the repository's .gitignore, or create the run directory in another directory of the work tree that git ignores`;
  }
  if (outside) return `create it under ${RUN_ROOT} in the project root, which lies outside git`;
  const probe = checkIgnore(tree, RUN_ROOT);
  if (probe.ignored === true) return `create it under ${RUN_ROOT} at the top of the work tree, which git ignores`;
  if (probe.ignored === false) return `create it under ${RUN_ROOT} at the top of the work tree and have git ignore that directory, for example with the line /${RUN_ROOT} in the repository's .gitignore`;
  return `create it under ${RUN_ROOT} at the top of the work tree; whether git ignores that directory could not be determined (${probe.reason})`;
}

function requireIgnored(tree, real, projectRoot, moves, runTree) {
  const relative = path.relative(tree, real).split(path.sep);
  const spelled = `${relative.join('/')}/`;
  const probe = checkIgnore(tree, spelled);
  if (probe.ignored === false) {
    const named = ignoreTarget(tree, real, projectRoot, relative);
    const moved = moves ? ' and every capture would move the tree fingerprint' : '';
    const remedy = named === null
      ? runRootRemedy(runTree, projectRoot)
      : `have git ignore ${named}, for example with the line ${ignoreLine(named)} in the repository's .gitignore`;
    refuse(`git does not ignore the run directory ${real}, so its captures could be committed${moved}; ${remedy}`);
  }
  if (probe.ignored === null) unavailable(`whether git ignores the run directory could not be determined (${probe.reason})`);
}

function begin(options) {
  const limits = limitsWith(options.limits);
  const config = normalizeConfig(options.config, limits);
  if (!config.enabled) {
    return { code: 3, lines: [...config.disclosures, 'zensu evidence report: not begun, because evidence.report.enabled is false'] };
  }
  requireContext(options);
  const args = argumentMap(options, 'begin');
  const mode = args.has('mode') ? args.get('mode') : 'local';
  if (!MODES.includes(mode)) usage(`--mode must be one of ${MODES.join(', ')}`);
  if (!args.has('drivers')) usage('--drivers must name the run\'s drivers, such as browser,api');
  const drivers = String(args.get('drivers')).split(',').map((entry) => entry.trim());
  for (const driver of drivers) {
    if (!DRIVERS.includes(driver)) usage(`--drivers names ${JSON.stringify(driver)}, which is not one of ${DRIVERS.join(', ')}`);
  }
  const orderedDrivers = DRIVERS.filter((driver) => drivers.includes(driver));
  let origin = null;
  if (mode === 'remote') {
    if (!args.has('origin') || !ORIGIN_RE.test(args.get('origin'))) usage('--origin must name the remote origin as scheme://host[:port] in remote mode');
    origin = args.get('origin');
  } else if (args.has('origin')) {
    usage('--origin belongs to remote mode');
  }
  const ctx = context(options);
  let recipe = null;
  if (args.has('recipe')) {
    recipe = args.get('recipe');
    if (!RECIPE_RE.test(recipe) || recipe.split('/').includes('..')) usage('--recipe must be a path relative to the project root, such as .zensu/runtime.yaml');
    screenArgument(recipe, ctx, '--recipe');
  }
  const fields = parseFields(stdinOf(options, limits), { single: ['feature'], repeat: [], criteria: true });
  if (fields.error) refuse(fields.error);
  if (!fields.single.has('feature')) refuse('stdin must give the request as a \'feature: <text>\' line');
  const feature = screenText(fields.single.get('feature'), ctx, limits.chars.feature, 'the feature text');
  if (feature.error) refuse(feature.error);
  const criteria = [];
  const seen = new Set();
  for (const entry of fields.criteria) {
    if (seen.has(entry.id)) refuse(`stdin lists ${entry.id} more than once`);
    seen.add(entry.id);
    const text = screenText(entry.text, ctx, limits.chars.criterion, `the text of ${entry.id}`);
    if (text.error) refuse(text.error);
    criteria.push({ id: entry.id, text: text.value, zensu: null });
  }
  if (criteria.length > limits.maxCriteria) refuse(`stdin lists more than ${limits.maxCriteria} criteria`);
  criteria.sort((left, right) => compareCriterionIds(left.id, right.id));
  let chain = null;
  const disclosures = [];
  if (args.has('log')) {
    if (criteria.length > 0) refuse('chain mode takes its criteria from the plan; give no AC lines on stdin');
    const fault = evidenceRun.workTreeFaultCause(options.chain ? options.chain.workTreeFault : null);
    if (fault !== null) unavailable(`the chain's work tree could not be determined, so the report cannot be bound to it: ${fault}`);
    const resolved = acceptance.resolveChain({ ...chainOptions(options), logPath: args.get('log') });
    if (resolved.error) refuse(resolved.error);
    chain = { stem: resolved.stem, plan: resolved.planRel };
    disclosures.push(...(resolved.disclosures || []));
    const listed = acceptance.readCriteria(resolved.planPath, chainOptions(options));
    if (listed.status === 'error') unavailable(`the criteria of ${resolved.planRel} cannot be read (${listed.reason})`);
    for (const entry of listed.status === 'ok' ? listed.criteria : []) {
      const text = screenText(entry.text, ctx, limits.chars.criterion, `the plan text of ${entry.id}`, { clip: true });
      if (text.error) refuse(text.error);
      criteria.push({ id: entry.id, text: text.value, zensu: null });
    }
    if (criteria.length > limits.maxCriteria) refuse(`the chain's plan lists more than ${limits.maxCriteria} criteria`);
    const assessed = acceptance.assess({ ...chainOptions(options), logPath: args.get('log'), chain: resolved });
    if (assessed.outcome !== 'evaluated' && assessed.outcome !== 'no-criteria') refuse(`the acceptance states could not be read (${assessed.outcome}: ${assessed.reason})`);
    const listedIds = new Set(criteria.map((criterion) => criterion.id));
    for (const row of assessed.outcome === 'evaluated' ? assessed.rows.filter((entry) => entry.state === 'dropped' && !listedIds.has(entry.criterion.id)) : []) {
      const text = screenText(row.criterion.text, ctx, limits.chars.criterion, `the plan text of ${row.criterion.id}`, { clip: true });
      if (text.error) refuse(text.error);
      criteria.push({ id: row.criterion.id, text: text.value, zensu: null });
    }
    if (criteria.length > limits.maxCriteria) refuse(`the chain's plan and the criteria dropped from it give more than ${limits.maxCriteria} criteria`);
  }
  const root = storeRoot(options, config, true);
  const placement = storePlacement(root);
  if (placement.undetermined) unavailable(placement.reason);
  if (!placement.ok) refuse(placement.reason);
  const chainRoot = chain !== null && options.chain && isString(options.chain.workTree) && options.chain.workTree !== ''
    ? evidenceRun.fingerprintRoot(options.chain.workTree, options.projectRoot, evidenceRun.LIMITS)
    : null;
  const runDirectory = checkRunDirectory(args.get('run-dir'), options.projectRoot, config.dir ? path.dirname(root) : root, chainRoot);
  const now = clockValue(options);
  const id = newReportId(now);
  const key = repositoryKey(options.projectRoot);
  const repository = ensureDirectory(root, key, 'the repository store');
  const scratch = ensureDirectory(root, 'scratch', 'the report scratch directory');
  const measured = measureTarget(options, scratch, mode, origin, chain !== null);
  const { target } = measured;
  target.begin_tree = target.tree;
  const binding = {
    schema: BINDING_SCHEMA,
    id,
    begin_failure: measured.failure,
    session_key: options.sessionKey,
    project_root: options.projectRoot,
    run_dir: runDirectory,
    created_at: isoNow(now),
    plugin_version: VERSION_RE.test(options.pluginVersion || '') ? options.pluginVersion : null,
    rendered_at: null,
    run: {
      host: options.host,
      mode,
      attach: args.has('attach'),
      chain,
      feature: feature.value,
      drivers: orderedDrivers,
      recipe,
      authenticated: false,
    },
    target,
    criteria,
    steps: [],
    evidence: {},
    files: {},
  };
  checkBeginSize(binding, limits);
  const where = { repository, bundle: path.join(repository, id), binding: path.join(repository, `${id}.binding.json`) };
  withLock(lockTarget(repository, id), limits, () => {
    ensureDirectory(repository, id, 'the report directory');
    ensureDirectory(where.bundle, 'files', 'the report file directory');
    writeBinding(where, binding);
  });
  const swept = sweep(root, { repositoryKey: key, keep: config.keep, maxBytes: config.maxBytes, protect: id, limits });
  const lines = [...config.disclosures, ...disclosures];
  lines.push(`zensu evidence report: begun ${id} | ${mode} | drivers ${orderedDrivers.join(', ')} | ${chain ? `chain ${chain.stem}` : `criteria ${criteria.length === 0 ? 'none' : criteria.map((criterion) => criterion.id).join(', ')}`}`);
  lines.push(`zensu evidence report: bundle ${where.bundle}`);
  if (chain === null && mode === 'local' && measured.failure !== null && measured.failure !== OUTSIDE_GIT) {
    lines.push(`zensu evidence report: the working tree could not be fingerprinted at --report-begin (${measured.failure}), so --report-render will refuse a PASS; make the tree fingerprintable and begin again`);
  }
  if (swept.removed.length > 0) {
    lines.push(`zensu evidence report: retention removed ${swept.removed.length} older report(s) (keep ${config.keep} per repository, at most ${config.maxBytes} bytes in total)`);
  }
  if (swept.kept !== null) {
    lines.push(`zensu evidence report: retention deleted nothing for the size cap, because the reports it must keep (this one, reports still being built and locked reports) hold ${swept.kept} bytes, above evidence.report.maxBytes of ${config.maxBytes}`);
  }
  if (swept.failed.length > 0) {
    lines.push(`zensu evidence report: retention could not delete ${swept.failed.length} report(s): ${swept.failed.join(', ')}; delete them by hand`);
  }
  return { code: 0, lines, id, bundle: where.bundle };
}

function readContainedFile(given, runDirectory, limits) {
  if (!isString(given) || !path.isAbsolute(given)) usage('--file must name the evidence file by an absolute path');
  const file = nativeSpelling(given);
  if (path.resolve(file) !== file) usage('--file must be a normalized path without . or .. segments');
  let stat;
  try {
    stat = fs.lstatSync(file);
  } catch {
    refuse(`the evidence file ${file} does not exist`);
  }
  if (stat.isSymbolicLink()) refuse(`the evidence file ${file} is a symlink; only a regular file inside the run directory is accepted`);
  if (!stat.isFile()) refuse(`the evidence file ${file} is not a regular file`);
  if (stat.nlink !== 1) refuse(`the evidence file ${file} has more than one link; only a file the run wrote itself is accepted`);
  let real;
  let linked;
  try {
    linked = !linkFree(file);
    real = fs.realpathSync.native(file);
  } catch (error) {
    refuse(`the evidence file ${file} does not resolve (${error.code || error.message})`);
  }
  if (linked) refuse(`the evidence file ${file} runs through a symlink; pass its physical path`);
  if (!isInside(runDirectory, real)) refuse(`the evidence file ${file} lies outside the run directory ${runDirectory}`);
  if (stat.size > limits.maxFileBytes) refuse(`the evidence file holds ${stat.size} bytes, above the cap of ${limits.maxFileBytes} bytes per file`);
  const loaded = readBounded(file, limits.maxFileBytes);
  if (loaded.error === 'oversized') refuse(`the evidence file is above the cap of ${limits.maxFileBytes} bytes per file`);
  if (loaded.error) refuse(`the evidence file ${file} cannot be read (${loaded.error})`);
  if (loaded.stat.dev !== stat.dev || loaded.stat.ino !== stat.ino) refuse(`the evidence file ${file} was replaced while it was read`);
  return loaded.bytes;
}

function storeFile(where, bytes, type) {
  const sha = sha256(bytes);
  const name = `${sha}.${FILE_TYPES[type]}`;
  const existing = readBounded(path.join(where.files, name), LIMITS.maxFileBytes);
  if (existing.bytes && sha256(existing.bytes) === sha) return sha;
  writeAtomic(where.files, name, bytes);
  return sha;
}

function addFileEvidence(options, args, binding, where, limits, kind, config) {
  if (!args.has('file')) usage(`--kind ${kind} needs --file <evidence file inside the run directory>`);
  for (const key of ['method', 'path', 'status', 'source', 'class', 'evidence-run']) {
    if (args.has(key)) usage(`--${key} does not belong to --kind ${kind}`);
  }
  const plane = args.has('plane') ? args.get('plane') : kind === 'image' ? 'visual' : 'state';
  if (!PLANES.includes(plane)) usage(`--plane must be one of ${PLANES.join(', ')}`);
  let viewport = null;
  if (args.has('viewport')) {
    if (kind !== 'image') usage('--viewport belongs to --kind image');
    viewport = parseViewport(args.get('viewport'));
    if (!viewport) usage('--viewport must read WIDTHxHEIGHT or WIDTHxHEIGHT@SCALE, such as 1440x900@1');
  }
  const ctx = context(options);
  const caption = screenText(stdinOf(options, limits), ctx, limits.chars.caption, 'the caption on stdin');
  if (caption.error) refuse(`${caption.error}; an image needs a caption that states what it shows`);
  const raw = readContainedFile(args.get('file'), binding.run_dir, limits);
  const sniffed = sniff(raw);
  if (sniffed.error) refuse(`the evidence file is refused: ${sniffed.error}`);
  let bytes = raw;
  let entry;
  if (kind === 'image') {
    if (!IMAGE_TYPES.includes(sniffed.type)) refuse('--kind image needs a PNG or a lossless WebP file');
    if (sniffed.width * sniffed.height > limits.maxPixels) refuse(`the image holds more than ${limits.maxPixels} pixels`);
    if (sniffed.dropped) bytes = sniffed.clean();
    entry = { name: '', type: sniffed.type, bytes: bytes.length, width: sniffed.width, height: sniffed.height, viewport, source_sha256: sniffed.dropped ? sha256(raw) : null };
  } else {
    if (sniffed.type !== 'text/plain') refuse('--kind text needs a UTF-8 text file');
    if (raw.length > limits.maxTextFileBytes) refuse(`a text file holds at most ${limits.maxTextFileBytes} bytes`);
    const screened = screenSecrets(sniffed.text, ctx, 'the text file', { hint: 'capture it without the value' });
    if (screened.error) refuse(screened.error);
    if (secretMatch(normalizedText(screened.value))) refuse('the text file matches a secret pattern; capture it without the value');
    bytes = Buffer.from(screened.value, 'utf8');
    if (bytes.length === 0 || bytes.length > limits.maxTextFileBytes) refuse(`a text file holds 1 to ${limits.maxTextFileBytes} bytes`);
    const stored = sniff(bytes);
    if (stored.type !== 'text/plain') {
      refuse(`after the path redaction the text file is refused: ${stored.error || 'it is no longer plain text'}; a capture that opens with a path the redaction replaces needs a first line that describes it`);
    }
    entry = { name: '', type: 'text/plain', bytes: bytes.length, width: null, height: null, viewport: null, source_sha256: null };
  }
  const sha = sha256(bytes);
  const known = binding.files[sha];
  if (known) {
    if (JSON.stringify(known.viewport) !== JSON.stringify(entry.viewport)) {
      refuse(`this file is already in the report with viewport ${known.viewport ? `${known.viewport.width}x${known.viewport.height}@${known.viewport.scale}` : 'none'}`);
    }
  } else if (Object.keys(binding.files).length >= limits.maxFiles) {
    refuse(`the report already holds ${limits.maxFiles} files, the cap per report; begin a new report for further evidence`);
  } else {
    const stored = Object.values(binding.files).reduce((sum, file) => sum + file.bytes, 0) + entry.bytes;
    if (stored > config.maxBytes) {
      refuse(`the report would hold ${stored} bytes of files, above evidence.report.maxBytes of ${config.maxBytes}; raise evidence.report.maxBytes in the user configuration, or begin a new report for further evidence`);
    }
  }
  entry.name = `files/${sha}.${FILE_TYPES[entry.type]}`;
  binding.files[sha] = known || entry;
  const stripped = sniffed.dropped ? ` | dropped the metadata chunks ${sniffed.dropped.join(', ')}` : '';
  return {
    item: { kind, file: sha, caption: caption.value, plane },
    detail: `${entry.type}${entry.width ? ` ${entry.width}x${entry.height}` : ''} | ${entry.bytes} bytes | ${entry.name}${stripped}`,
    store: () => storeFile(where, bytes, entry.type),
  };
}

function addRequestEvidence(options, args, limits) {
  for (const key of ['file', 'plane', 'viewport', 'source', 'class', 'evidence-run']) {
    if (args.has(key)) usage(`--${key} does not belong to --kind request`);
  }
  if (stdinOf(options, limits).trim() !== '') refuse('a request item carries no caption; pass nothing on stdin');
  const method = args.get('method');
  if (!isString(method) || !METHOD_RE.test(method)) usage('--method must be an upper-case HTTP method such as GET');
  const requestPath = args.get('path');
  if (!isString(requestPath) || requestPath.length > limits.chars.path || !ROUTE_RE.test(requestPath)) {
    usage('--path must be the request path without query or fragment, such as /api/settings');
  }
  screenArgument(requestPath, context(options), '--path', 'own');
  const status = Number(args.get('status'));
  if (!/^[1-5][0-9]{2}$/.test(String(args.get('status'))) || status < 100 || status > 599) usage('--status must be an HTTP status from 100 to 599');
  return { item: { kind: 'request', method, path: requestPath, status }, detail: `${method} ${requestPath} ${status}` };
}

function addSignalEvidence(options, args, limits) {
  for (const key of ['file', 'plane', 'viewport', 'method', 'path', 'status', 'evidence-run']) {
    if (args.has(key)) usage(`--${key} does not belong to --kind signal`);
  }
  const source = args.get('source');
  if (!SIGNAL_SOURCES.includes(source)) usage(`--source must be one of ${SIGNAL_SOURCES.join(', ')}`);
  const signalClass = args.get('class');
  if (!isString(signalClass) || !SIGNAL_CLASS_RE.test(signalClass)) usage('--class must name the signal class, such as error or warning');
  screenArgument(signalClass, context(options), '--class');
  const message = screenText(stdinOf(options, limits), context(options), limits.chars.message, 'the signal message on stdin');
  if (message.error) refuse(message.error);
  return { item: { kind: 'signal', source, class: signalClass, message: message.value }, detail: `${source} ${signalClass}` };
}

function addRunEvidence(options, args, limits) {
  for (const key of ['file', 'plane', 'viewport', 'method', 'path', 'status', 'source', 'class']) {
    if (args.has(key)) usage(`--${key} does not belong to --kind run`);
  }
  if (stdinOf(options, limits).trim() !== '') refuse('a run item carries no caption; pass nothing on stdin');
  const runId = args.get('evidence-run');
  if (!isString(runId) || !EVIDENCE_RUN_RE.test(runId)) usage('--evidence-run must name an er1_ evidence-run record');
  let store;
  try {
    store = evidenceRun.storeLocations(options.pluginData, options.sessionKey);
  } catch (error) {
    unavailable(error.message);
  }
  const loaded = evidenceRun.readRecordFile(path.join(store.records, `${runId}.json`), evidenceRun.LIMITS);
  if (loaded.invalid) {
    refuse(loaded.invalid === 'unreadable (ENOENT)' ? `no evidence run ${runId} exists for this session` : `evidence run ${runId} cannot be read (${loaded.invalid})`);
  }
  const problem = evidenceRun.validateRecord(loaded.record, { id: runId, sessionKey: options.sessionKey, projectRoot: options.projectRoot });
  if (problem) refuse(`evidence run ${runId} does not validate (${problem})`);
  const state = evidenceRun.effectiveState(loaded.record);
  if (state !== 'completed') refuse(`evidence run ${runId} is ${state}, not completed`);
  const command = screenText(loaded.record.command, context(options), limits.chars.command, `the command of evidence run ${runId}`, { clip: true });
  if (command.error) refuse(command.error);
  return {
    item: { kind: 'run', record: runId, command: command.value, exit_code: loaded.record.exit_code, duration_ms: loaded.record.duration_ms },
    detail: `${runId} exit ${loaded.record.exit_code === null ? 'none' : loaded.record.exit_code}`,
  };
}

const IMMUTABLE_REPORT = Object.freeze({
  add: 'is rendered and immutable; begin a new report for further evidence',
  step: 'is rendered and immutable; begin a new report for further rows',
  render: 'is already rendered; begin a new report to render another',
});

function withReport(options, verb, action) {
  const limits = limitsWith(options.limits);
  const config = normalizeConfig(options.config, limits);
  requireContext(options);
  const args = argumentMap(options, verb);
  const reportId = args.get('report');
  const where = locations(options, config, reportId, false);
  return withLock(lockTarget(where.repository, reportId), limits, () => {
    const binding = loadBinding(where, reportId, options, limits, verb !== 'export');
    if (verb === 'export' && binding.rendered_at === null) refuse(`report ${reportId} is not rendered; run --report-render first`);
    if (verb !== 'export' && binding.rendered_at !== null) refuse(`report ${reportId} ${IMMUTABLE_REPORT[verb]}`);
    if (verb !== 'export' && path.resolve(binding.project_root) !== path.resolve(options.projectRoot)) {
      refuse(`report ${reportId} was begun in the project root ${binding.project_root}, but this session's project root is ${options.projectRoot}; begin a new report there`);
    }
    return action({ limits, config, args, reportId, where, binding });
  });
}

function add(options) {
  return withReport(options, 'add', ({ limits, config, args, reportId, where, binding }) => {
    const kind = args.get('kind');
    if (!EVIDENCE_KINDS.includes(kind)) usage(`--kind must be one of ${EVIDENCE_KINDS.join(', ')}`);
    if (Object.keys(binding.evidence).length >= limits.maxEvidence) refuse(`the report already holds ${limits.maxEvidence} evidence items`);
    let added;
    if (FILE_KINDS.includes(kind)) added = addFileEvidence(options, args, binding, where, limits, kind, config);
    else if (kind === 'request') added = addRequestEvidence(options, args, limits);
    else if (kind === 'signal') added = addSignalEvidence(options, args, limits);
    else added = addRunEvidence(options, args, limits);
    const id = `e${Object.keys(binding.evidence).length + 1}`;
    binding.evidence[id] = added.item;
    checkDraftSize(binding, limits);
    if (added.store) added.store();
    writeBinding(where, binding);
    return { code: 0, lines: [`zensu evidence report: ${id} added to ${reportId} | ${kind} | ${added.detail}`], id };
  });
}

function listArgument(value, pattern, label, max) {
  if (value === undefined || value === '') return [];
  const entries = String(value).split(',').map((entry) => entry.trim());
  const seen = new Set();
  for (const entry of entries) {
    if (!pattern.test(entry)) usage(`${label} names ${JSON.stringify(entry)}, which is not a valid id`);
    if (seen.has(entry)) usage(`${label} names ${entry} more than once`);
    seen.add(entry);
  }
  if (entries.length > max) usage(`${label} names more than ${max} entries`);
  return entries;
}

function step(options) {
  return withReport(options, 'step', ({ limits, args, reportId, where, binding }) => {
    const priority = args.get('priority');
    if (!PRIORITIES.includes(priority)) usage(`--priority must be one of ${PRIORITIES.join(', ')}`);
    const driver = args.get('driver');
    if (!DRIVERS.includes(driver)) usage(`--driver must be one of ${DRIVERS.join(', ')}`);
    const result = args.get('result');
    if (!STEP_RESULTS.includes(result)) usage(`--result must be one of ${STEP_RESULTS.join(', ')}`);
    const criteria = listArgument(args.get('criteria'), AC_RE, '--criteria', limits.maxCriteria).sort(compareCriterionIds);
    const evidence = listArgument(args.get('evidence'), EVIDENCE_ID_RE, '--evidence', limits.maxEvidence);
    for (const id of evidence) {
      if (!Object.prototype.hasOwnProperty.call(binding.evidence, id)) refuse(`--evidence names ${id}, which this report does not hold`);
    }
    const known = new Set(binding.criteria.map((criterion) => criterion.id));
    const unlisted = binding.run.chain === null ? 'which --report-begin did not list' : `which the chain's plan ${binding.run.chain.plan} did not list at --report-begin`;
    for (const id of criteria) {
      if (!known.has(id)) refuse(`--criteria names ${id}, ${unlisted}; this report's criteria are ${[...known].join(', ') || 'none'}`);
    }
    const fields = parseFields(stdinOf(options, limits), { single: ['title', 'expected', 'observed'], repeat: [], criteria: false });
    if (fields.error) refuse(fields.error);
    const ctx = context(options);
    const values = {};
    for (const key of ['title', 'expected', 'observed']) {
      if (!fields.single.has(key)) refuse(`stdin must give '${key}: <text>'`);
      const cleaned = screenText(fields.single.get(key), ctx, limits.chars[key], `the ${key} text`);
      if (cleaned.error) refuse(cleaned.error);
      values[key] = cleaned.value;
    }
    if (binding.steps.length >= limits.maxSteps) refuse(`the report already holds ${limits.maxSteps} rows`);
    const n = binding.steps.length + 1;
    binding.steps.push({ n, title: values.title, priority, driver, criteria, result, expected: values.expected, observed: values.observed, evidence });
    if (args.has('authenticated')) binding.run.authenticated = true;
    checkDraftSize(binding, limits);
    writeBinding(where, binding);
    return { code: 0, lines: [`zensu evidence report: step ${n} written to ${reportId} | ${priority} ${driver} ${result} | criteria ${criteria.join(', ') || 'none'} | evidence ${evidence.join(', ') || 'none'}`], n };
  });
}

function mapDriver(driver) {
  if (DRIVERS.includes(driver)) return driver;
  return DRIVER_SPELLINGS.get(driver) || null;
}

function chainCoverage(options, binding, args, ctx, limits) {
  if (!args.has('log')) refuse(`report ${binding.id} is in chain mode; pass --log <this chain's run log>`);
  const fault = evidenceRun.workTreeFaultCause(options.chain ? options.chain.workTreeFault : null);
  if (fault !== null) unavailable(`the chain's work tree could not be determined, so the acceptance states cannot be read: ${fault}`);
  const chainOpts = { ...chainOptions(options), logPath: args.get('log') };
  const resolved = acceptance.resolveChain(chainOpts);
  if (resolved.error) refuse(resolved.error);
  if (resolved.stem !== binding.run.chain.stem) {
    refuse(`the chain's plan is now ${resolved.planRel}, but report ${binding.id} began on ${binding.run.chain.plan}; begin a new report`);
  }
  const assessed = acceptance.assess({ ...chainOpts, chain: resolved });
  let rows = [];
  if (assessed.outcome === 'evaluated') rows = assessed.rows;
  else if (assessed.outcome !== 'no-criteria') refuse(`the acceptance states could not be read (${assessed.outcome}: ${assessed.reason})`);
  const drafted = new Map(binding.criteria.map((criterion) => [criterion.id, criterion.zensu]));
  const criteria = [];
  for (const row of rows) {
    const text = screenText(row.criterion.text, ctx, limits.chars.criterion, `the plan text of ${row.criterion.id}`, { clip: true });
    if (text.error) refuse(text.error);
    let note = null;
    const source = [row.treeUnverified ? 'tree unverified' : null, row.cause, row.record ? row.record.evidence : null].filter((entry) => isString(entry) && entry.trim() !== '').join('; ');
    if (source !== '') {
      const cleaned = screenText(source, ctx, limits.chars.note, `the note of ${row.criterion.id}`, { clip: true });
      if (cleaned.error) refuse(cleaned.error);
      note = cleaned.value;
    }
    criteria.push(criterionRow(row.criterion.id, text.value, {
      state: row.state === 'dropped' ? (row.record && row.record.verdict === 'fail' ? 'fail' : 'partial') : row.state,
      driver: row.record ? mapDriver(row.record.driver) : null,
      record: row.record ? row.record.id : null,
      evidence_run: row.record ? row.record.evidence_run : null,
      zensu: drafted.get(row.criterion.id) || null,
      note,
    }));
  }
  const inScope = rows.filter((row) => row.criterion.state === 'active').map((row) => row.criterion.id);
  const disclosures = [...(resolved.disclosures || [])];
  if (assessed.outcome === 'evaluated' && assessed.currentTree && assessed.currentTree.tree === null) {
    disclosures.push(`The acceptance states could not be compared with the working tree at --report-render (${treeFailure(assessed.currentTree.reason)}), so each criterion shows its newest record, whatever tree that record was taken on.`);
  }
  return { criteria, inScope, disclosures };
}

function matrixCoverage(binding) {
  const criteria = binding.criteria.map((criterion) => {
    const rows = binding.steps.filter((entry) => entry.criteria.includes(criterion.id));
    let state = 'missing';
    if (rows.length > 0) {
      if (rows.some((entry) => entry.result === 'fail')) state = 'fail';
      else if (rows.every((entry) => entry.result === 'pass')) state = 'pass';
      else state = 'partial';
    }
    const ui = rows.find((entry) => UI_DRIVERS.includes(entry.driver));
    const driver = ui ? ui.driver : rows.length > 0 ? rows[0].driver : null;
    return criterionRow(criterion.id, criterion.text, { state, driver, zensu: criterion.zensu });
  });
  return { criteria, inScope: binding.criteria.map((criterion) => criterion.id), disclosures: [] };
}

function parseSections(options, args, limits) {
  const fields = parseFields(stdinOf(options, limits), { single: [], repeat: ['limitation', 'resource', 'consent'], criteria: false });
  if (fields.error) refuse(fields.error);
  const ctx = context(options);
  const sections = { console: args.has('console') ? args.get('console') : 'not-checked', network: args.has('network') ? args.get('network') : 'not-checked', consent: [], limitations: [], resources: [] };
  for (const key of ['console', 'network']) {
    if (!SECTION_STATES.includes(sections[key])) usage(`--${key} must be one of ${SECTION_STATES.join(', ')}`);
  }
  for (const [field, key] of [['limitation', 'limitations'], ['resource', 'resources']]) {
    for (const value of fields.repeat.get(field)) {
      const cleaned = screenText(value, ctx, limits.chars.line, `a ${field} line`);
      if (cleaned.error) refuse(cleaned.error);
      if (!sections[key].includes(cleaned.value)) sections[key].push(cleaned.value);
    }
    if (sections[key].length > limits.maxSectionLines) refuse(`stdin gives more than ${limits.maxSectionLines} ${field} lines`);
  }
  for (const value of fields.repeat.get('consent')) {
    const parts = normalizedText(value).split(' ');
    if (parts.length !== 3 || !ORIGIN_RE.test(parts[0]) || parts[1].length > limits.chars.path || !ROUTE_RE.test(parts[1]) || !CONSENT_DECISIONS.includes(parts[2])) {
      refuse(`a consent line must read '<origin> <route> <${CONSENT_DECISIONS.join('|')}>'`);
    }
    for (const [part, label] of [[parts[0], 'the origin of a consent line'], [parts[1], 'the route of a consent line']]) screenArgument(part, ctx, label, 'own');
    sections.consent.push({ origin: parts[0], route: parts[1], decided_by: parts[2] });
  }
  if (sections.consent.length > limits.maxConsent) refuse(`stdin gives more than ${limits.maxConsent} consent lines`);
  return sections;
}

function faultLines(faults) {
  return faults.map((entry) => `REPORT REFUSED — ${entry.code}${entry.at ? ` at ${entry.at}` : ''}: ${entry.message} | remedy: ${entry.remedy}`);
}

function render(options) {
  return withReport(options, 'render', ({ limits, args, reportId, where, binding }) => {
    const verdict = args.get('verdict');
    if (!VERDICTS.includes(verdict)) usage(`--verdict must be one of ${VERDICTS.join(', ')}`);
    if (binding.run.chain === null && args.has('log')) refuse(`report ${reportId} is in matrix mode; --log belongs to chain mode`);
    const sections = parseSections(options, args, limits);
    const ctx = context(options);
    const coverage = binding.run.chain === null ? matrixCoverage(binding) : chainCoverage(options, binding, args, ctx, limits);
    for (const criterion of coverage.criteria) criterion.steps = stepNumbers(binding, criterion.id);
    for (const disclosure of coverage.disclosures) {
      const cleaned = screenText(disclosure, ctx, limits.chars.line, 'an acceptance disclosure', { clip: true });
      if (cleaned.error) refuse(cleaned.error);
      if (!sections.limitations.includes(cleaned.value)) sections.limitations.push(cleaned.value);
    }
    const scratch = ensureDirectory(where.root, 'scratch', 'the report scratch directory');
    const measured = measureTarget(options, scratch, binding.run.mode, binding.target.origin, binding.run.chain !== null);
    const { target } = measured;
    target.begin_tree = binding.target.begin_tree;
    const verdictContext = { treeFailure: measured.failure, beginFailure: binding.begin_failure, beganOutsideGit: binding.begin_failure === OUTSIDE_GIT && targetOutsideGit(binding.target) };
    const check = treeCheck(target, verdictContext);
    const local = binding.run.mode === 'local';
    let treeNote = null;
    if (local && check.state === 'render-unmeasured') {
      treeNote = `The working tree could not be fingerprinted at --report-render (${check.atRender}), so a change since ${target.begin_tree.slice(0, 12)} at --report-begin cannot be ruled out.`;
    } else if (local && check.state === 'changed') {
      treeNote = `The working tree changed during the run: ${target.begin_tree.slice(0, 12)} at --report-begin, ${target.tree.slice(0, 12)} at --report-render.`;
    } else if (local && target.begin_tree === null) {
      const atBegin = check.atBegin ? ` (${check.atBegin})` : '';
      treeNote = check.state === 'unmeasured'
        ? `The working tree was not fingerprinted at --report-begin${atBegin}, and could not be fingerprinted at --report-render either (${check.atRender}), so a change during the run cannot be ruled out.`
        : `The working tree was not fingerprinted at --report-begin${atBegin}, so a change during the run cannot be ruled out.`;
    }
    if (treeNote !== null && !sections.limitations.includes(treeNote)) sections.limitations.push(treeNote);
    const now = clockValue(options);
    const manifest = manifestOf(binding, { renderedAt: isoNow(now), target, verdict, criteria: coverage.criteria, sections });
    const serialized = serializeManifest(manifest);
    if (Buffer.byteLength(serialized) > limits.maxManifestBytes) {
      const changed = planChanges(binding, coverage.criteria);
      const cause = changed.length > 0 ? `, because the chain's plan changed since --report-begin (${changed.join(', ')})` : '';
      return { code: 1, errors: faultLines([{ code: 'manifest.too-large', at: '', message: `the manifest holds ${Buffer.byteLength(serialized)} bytes, above the cap of ${limits.maxManifestBytes}${cause}`, remedy: changed.length > 0 ? 'begin a new report on the current plan' : 'split the evidence across two reports' }]) };
    }
    const readFile = bundleReader(where.bundle, limits);
    const faults = checkManifest(manifest, readFile, { inScope: coverage.inScope, limits: options.limits, verdictContext });
    if (faults.length > 0) return { code: 1, errors: faultLines(faults) };
    const html = renderHtml(manifest, readFile, { mode: 'bundle' });
    writeAtomic(where.bundle, 'manifest.json', serialized);
    writeAtomic(where.bundle, 'index.html', html);
    binding.rendered_at = manifest.rendered_at;
    binding.target = target;
    writeBinding(where, binding);
    const counts = coverage.criteria.length === 0 ? 'none' : `${coverage.criteria.length} (${stateCounts(coverage.criteria)})`;
    return {
      code: 0,
      lines: [
        ...coverage.disclosures,
        `zensu evidence report: ${reportId} rendered | verdict ${verdict} | criteria ${counts} | steps ${binding.steps.length} | files ${Object.keys(binding.files).length}`,
        `Evidence report: ${path.join(where.bundle, 'index.html')}`,
      ],
      manifest,
    };
  });
}

function list(options) {
  const limits = limitsWith(options.limits);
  const config = normalizeConfig(options.config, limits);
  requireContext(options);
  const args = argumentMap(options, 'list');
  let limit = limits.defaultListed;
  if (args.has('limit')) {
    if (!/^[1-9][0-9]{0,3}$/.test(String(args.get('limit'))) || Number(args.get('limit')) > limits.maxListed) usage(`--limit must be an integer from 1 to ${limits.maxListed}`);
    limit = Number(args.get('limit'));
  }
  const root = storeRoot(options, config, false);
  const key = repositoryKey(options.projectRoot);
  const repository = root === null ? null : path.join(root, key);
  let names = [];
  if (repository !== null) {
    try {
      if (!fs.lstatSync(repository).isSymbolicLink()) names = fs.readdirSync(repository);
    } catch { }
  }
  const ids = names.filter((name) => ID_RE.test(name)).sort().reverse();
  if (ids.length === 0) return { code: 0, lines: [`zensu evidence report: no report for this repository${root === null ? '' : ` in ${path.join(root, key)}`}`], reports: [] };
  const reports = [];
  for (const id of ids.slice(0, limit)) {
    const bundle = path.join(repository, id);
    let stat;
    try { stat = fs.lstatSync(bundle); } catch { continue; }
    if (stat.isSymbolicLink() || !stat.isDirectory()) continue;
    const binding = readJson(path.join(repository, `${id}.binding.json`), limits.maxBindingBytes);
    const valid = !binding.error && !validateBinding(binding.value, { id }, limits);
    let state = 'invalid';
    let verdict = '-';
    let location = bundle;
    if (valid && binding.value.rendered_at === null) state = 'unrendered';
    if (!binding.error && isPlainObject(binding.value) && binding.value.schema !== BINDING_SCHEMA && schemaName(binding.value.schema) !== null) {
      state = `schema ${binding.value.schema}`;
    }
    if (valid && binding.value.rendered_at !== null) {
      const manifest = readJson(path.join(bundle, 'manifest.json'), limits.maxManifestBytes);
      if (!manifest.error && validateManifest(manifest.value, options.limits).length === 0) {
        state = 'rendered';
        verdict = manifest.value.verdict;
        location = path.join(bundle, 'index.html');
      } else if (!manifest.error && isPlainObject(manifest.value) && manifest.value.schema !== SCHEMA && schemaName(manifest.value.schema) !== null) {
        state = `schema ${manifest.value.schema}`;
      }
    }
    const created = valid ? binding.value.created_at : '-';
    reports.push({ id, state, verdict, created, location });
  }
  const lines = reports.map((report) => `${report.id} | ${report.state} | ${report.verdict} | ${report.created} | ${report.location}`);
  if (ids.length > limit) lines.push(`zensu evidence report: ${ids.length - limit} older report(s) not listed; pass --limit to see more`);
  return { code: 0, lines, reports };
}

function exportReport(options) {
  return withReport(options, 'export', ({ limits, reportId, where }) => {
    const loaded = loadManifest(where.bundle, options.limits);
    if (loaded.faults) return { code: 1, errors: faultLines(loaded.faults) };
    const total = Object.values(isPlainObject(loaded.manifest) && isPlainObject(loaded.manifest.files) ? loaded.manifest.files : {}).reduce((sum, entry) => sum + (Number.isInteger(entry && entry.bytes) ? entry.bytes : 0), 0);
    if (total > limits.maxExportBytes) {
      refuse(`the report holds ${total} bytes of files, above the export cap of ${limits.maxExportBytes}; share it through the review summary or Zensu instead`);
    }
    const rendered = renderBundle(loaded.manifest, where.bundle, { mode: 'export', limits: options.limits });
    if (rendered.faults) return { code: 1, errors: faultLines(rendered.faults) };
    writeAtomic(where.bundle, 'export.html', rendered.html);
    const target = path.join(where.bundle, 'export.html');
    return { code: 0, lines: [`zensu evidence report: exported ${reportId} | ${Buffer.byteLength(rendered.html)} bytes | ${target}`], target };
  });
}

function directorySize(directory, budget) {
  let total = 0;
  const stack = [directory];
  while (stack.length > 0) {
    const current = stack.pop();
    let names;
    try { names = fs.readdirSync(current); } catch { continue; }
    for (const name of names) {
      if (budget.entries <= 0) return total;
      budget.entries -= 1;
      const target = path.join(current, name);
      let stat;
      try { stat = fs.lstatSync(target); } catch { continue; }
      if (stat.isSymbolicLink()) continue;
      if (stat.isDirectory()) stack.push(target);
      else if (stat.isFile()) total += stat.size;
    }
  }
  return total;
}

function openReport(repository, id, limits) {
  try {
    if (fs.lstatSync(path.join(repository, id, 'manifest.json')).isFile()) return false;
  } catch { }
  try {
    const stat = fs.lstatSync(path.join(repository, `${id}.binding.json`));
    return stat.isFile() && Date.now() - stat.mtimeMs <= limits.openReportMs;
  } catch {
    return false;
  }
}

function removeIdleReport(repository, id, limits) {
  const target = lockTarget(repository, id);
  let token;
  try {
    token = acquireLock(target, 1);
  } catch (error) {
    if (error instanceof ReportError) return { removed: false, fault: null };
    throw error;
  }
  try {
    if (openReport(repository, id, limits)) return { removed: false, fault: null };
    fs.rmSync(path.join(repository, id), { recursive: true, force: true });
    try { fs.unlinkSync(path.join(repository, `${id}.binding.json`)); } catch { }
    return { removed: true, fault: null };
  } catch (error) {
    return { removed: false, fault: error.code || error.message };
  } finally {
    releaseLock(target, token);
  }
}

function sweep(root, options) {
  const limits = limitsWith(options.limits);
  const keep = options.keep;
  const maxBytes = options.maxBytes;
  const protect = options.protect || null;
  const own = options.repositoryKey || null;
  const removed = [];
  const failed = new Map();
  const survivors = [];
  const remove = (key, repository, id) => {
    const outcome = removeIdleReport(repository, id, limits);
    if (outcome.fault) failed.set(`${key}/${id}`, `${key}/${id} (${outcome.fault})`);
    return outcome.removed;
  };
  let repositories;
  try { repositories = fs.readdirSync(root).filter((name) => REPO_KEY_RE.test(name)).sort(); } catch { return { removed, failed: [], kept: null }; }
  for (const key of repositories) {
    const repository = path.join(root, key);
    try {
      const stat = fs.lstatSync(repository);
      if (stat.isSymbolicLink() || !stat.isDirectory()) continue;
    } catch { continue; }
    let names;
    try { names = fs.readdirSync(repository); } catch { continue; }
    const ids = names.filter((name) => {
      if (!ID_RE.test(name)) return false;
      try {
        const stat = fs.lstatSync(path.join(repository, name));
        return !stat.isSymbolicLink() && stat.isDirectory();
      } catch {
        return false;
      }
    }).sort();
    const doomed = key === own ? new Set(ids.slice(0, Math.max(0, ids.length - keep))) : new Set();
    for (const id of ids) {
      if (doomed.has(id) && id !== protect && remove(key, repository, id)) {
        removed.push(`${key}/${id}`);
        continue;
      }
      let size = directorySize(path.join(repository, id), { entries: limits.maxFiles + 16 });
      try { size += fs.lstatSync(path.join(repository, `${id}.binding.json`)).size; } catch { }
      survivors.push({ key, id, repository, size });
    }
  }
  let total = survivors.reduce((sum, entry) => sum + entry.size, 0);
  if (total <= maxBytes) return { removed, failed: [...failed.values()], kept: null };
  const spared = new Set(survivors.filter((entry) => entry.id === protect || openReport(entry.repository, entry.id, limits) || lockHeld(lockTarget(entry.repository, entry.id))));
  const kept = [...spared].reduce((sum, entry) => sum + entry.size, 0);
  if (kept > maxBytes) return { removed, failed: [...failed.values()], kept };
  const oldestFirst = survivors.filter((entry) => !spared.has(entry)).sort((left, right) => (left.id < right.id ? -1 : left.id > right.id ? 1 : left.key < right.key ? -1 : 1));
  for (const entry of oldestFirst) {
    if (total <= maxBytes) break;
    if (!remove(entry.key, entry.repository, entry.id)) continue;
    removed.push(`${entry.key}/${entry.id}`);
    total -= entry.size;
  }
  return { removed, failed: [...failed.values()], kept: null };
}

function readTransportFile(directory, name, maxBytes) {
  if (!directory) return null;
  const loaded = readBounded(path.join(directory, name), maxBytes);
  if (loaded.error === 'missing') return null;
  if (loaded.error === 'oversized' && name === 'stdin') refuse(`stdin exceeds ${LIMITS.maxStdinBytes} bytes`);
  if (loaded.error) unavailable(`the transport file ${name} cannot be read (${loaded.error})`);
  return loaded.bytes.toString('utf8');
}

function readArguments(directory) {
  const args = new Map();
  const text = readTransportFile(directory, 'args', 256 * 1024);
  if (text === null) return args;
  const parts = text.split('\u0000');
  if (parts[parts.length - 1] === '') parts.pop();
  if (parts.length % 2 !== 0) usage('the argument transport is malformed');
  for (let index = 0; index < parts.length; index += 2) {
    const key = parts[index];
    if (!/^[a-z][a-z-]{0,31}$/.test(key)) usage('the argument transport is malformed');
    if (args.has(key)) usage(`--${key} is given more than once`);
    if (/[\r\n]/.test(parts[index + 1])) usage(`--${key} must not hold a line break`);
    args.set(key, parts[index + 1]);
  }
  return args;
}

function transportOptions(env) {
  const directory = env.ZENSU_ERP_DIR || '';
  let config = {};
  const configText = readTransportFile(directory, 'config.json', 64 * 1024);
  if (configText) {
    try { config = JSON.parse(configText); } catch { config = {}; }
  }
  return {
    pluginData: env.ZENSU_ERP_PLUGIN_DATA || '',
    sessionKey: env.ZENSU_ERP_SESSION_KEY || '',
    projectRoot: env.ZENSU_ERP_PROJECT_ROOT || '',
    host: env.ZENSU_ERP_HOST || '',
    home: env.ZENSU_ERP_HOME || '',
    pluginVersion: readPluginVersion(env.ZENSU_ERP_PLUGIN_MANIFEST || ''),
    args: readArguments(directory),
    stdinText: readTransportFile(directory, 'stdin', LIMITS.maxStdinBytes + 1) || '',
    config,
    chain: {
      receiptPath: env.ZENSU_ERP_RECEIPT || '',
      editLandingEscaped: env.ZENSU_ERP_EDIT_LANDING_ESCAPED === '1',
      workTree: env.ZENSU_ERP_WORK_TREE || '',
      workTreeFault: evidenceRun.readWorkTreeFault(directory),
      bashPath: env.ZENSU_ERP_BASH || 'bash',
    },
  };
}

const VERB_FUNCTIONS = Object.freeze({ begin, add, step, render, list, export: exportReport });

async function main(argv, env = process.env) {
  const verb = argv[0];
  const label = env.ZENSU_ERP_LABEL || 'evidence-report-v1';
  if (!VERBS.includes(verb)) {
    process.stderr.write(`usage: evidence-report-v1.js ${VERBS.join('|')}\n`);
    return 2;
  }
  let result;
  try {
    result = VERB_FUNCTIONS[verb](transportOptions(env));
  } catch (error) {
    if (!(error instanceof ReportError)) throw error;
    result = { code: error.exitCode, errors: [error.message] };
  }
  for (const line of result.lines || []) process.stdout.write(`${line}\n`);
  for (const line of result.errors || []) process.stderr.write(`${label}: ${line}\n`);
  return result.code;
}

module.exports = {
  SCHEMA,
  BINDING_SCHEMA,
  STORE_VERSION,
  STORE_SEGMENTS,
  FAULT_CODES,
  VERBS,
  VERB_ARGUMENTS,
  ID_RE,
  LIMITS,
  VERDICTS,
  MODES,
  CRITERION_STATES,
  STEP_RESULTS,
  PRIORITIES,
  DRIVERS,
  UI_DRIVERS,
  EVIDENCE_KINDS,
  PLANES,
  SIGNAL_SOURCES,
  SECTION_STATES,
  CONSENT_DECISIONS,
  FILE_TYPES,
  MANIFEST_KEYS,
  ReportError,
  newReportId,
  nativeSpelling,
  samePath,
  linkFree,
  sniff,
  parseFields,
  parseViewport,
  screenText,
  validateManifest,
  integrityFaults,
  checkManifest,
  renderHtml,
  renderBundle,
  loadManifest,
  renderDirectory,
  bundleReader,
  normalizeConfig,
  storePlacement,
  repositoryKey,
  repositoryFromRemote,
  sweep,
  begin,
  add,
  step,
  render,
  list,
  exportReport,
  transportOptions,
  main,
};

if (require.main === module) {
  main(process.argv.slice(2)).then((code) => {
    process.exitCode = code;
  }, (error) => {
    process.stderr.write(`evidence-report-v1: ${error && error.message ? error.message : String(error)}\n`);
    process.exitCode = 2;
  });
}
