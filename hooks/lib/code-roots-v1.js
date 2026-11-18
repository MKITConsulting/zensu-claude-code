'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const childProcess = require('node:child_process');
const { READ_ONLY_GIT, gitEnvironment } = require('./git-read-only-v1.js');

const CODE_ROOTS_ENABLED = false;
const DISABLED_REASON = 'multi-repo chains are not enabled in this build';
const MAX_CODE_ROOTS = 8;
const ENTRY_KEYS = Object.freeze(['baseline', 'commonDir', 'label', 'path', 'top']);
const LABEL_RE = /^[a-z][a-z0-9-]{1,31}$/;
const FORBIDDEN_CHARACTER_RE = /["$`\\,=\u0000-\u001f\u007f-\u009f\u2028\u2029]/;
const UNPRINTABLE_PATH_RE = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/;
const BASELINE_RE = /^(?:unborn|[0-9a-f]{40}|[0-9a-f]{64})$/;
const COMMIT_RE = /^[0-9a-f]{4,64}$/;
const DRIVE_RE = /^[A-Za-z]:\//;
const GIT_TIMEOUT_MS = 20000;
const MAX_GIT_OUTPUT_BYTES = 64 * 1024 * 1024;
const MAX_DOCUMENT_BYTES = 4 * 1024 * 1024;
const PLUGIN_ROOT = path.resolve(__dirname, '..', '..');
const AUDIT_EXCLUDES = Object.freeze(['-c', 'core.excludesFile=/dev/null']);
const READ_STATUSES = Object.freeze({
  ABSENT: 'absent',
  OK: 'ok',
  DISABLED: 'disabled',
  ANCHOR_ONLY: 'anchor-only',
});
const RECIPES = Object.freeze({ AUDIT: 'audit', COUNT: 'count' });

function enabledFrom(options) {
  if (options && Object.prototype.hasOwnProperty.call(options, 'enabled')) return options.enabled === true;
  return CODE_ROOTS_ENABLED;
}

function storedSpelling(value, platform) {
  return platform === 'win32' ? String(value).replace(/\\/g, '/') : String(value);
}

function folds(platform) {
  return platform === 'darwin' || platform === 'win32';
}

function fold(value, platform) {
  return folds(platform) ? value.toLowerCase() : value;
}

function samePath(a, b, platform) {
  return typeof a === 'string' && typeof b === 'string' && fold(a, platform) === fold(b, platform);
}

function contains(root, candidate) {
  const base = root && root.length > 1 && root.endsWith('/') ? root.replace(/\/+$/, '') : root;
  const rel = path.relative(base, candidate);
  return rel === '' || (rel !== '..' && !rel.startsWith(`..${path.sep}`) && !path.isAbsolute(rel));
}

function declaresLiveRoots(document) {
  return Boolean(document) && typeof document === 'object' && document.active === true && document.chainDone !== true;
}

function strictlyInside(root, candidate, platform) {
  if (typeof root !== 'string' || typeof candidate !== 'string') return false;
  const folded = fold(root, platform);
  const inner = fold(candidate, platform);
  return folded !== inner && contains(folded, inner);
}

function overlaps(a, b, platform) {
  return samePath(a, b, platform) || strictlyInside(a, b, platform) || strictlyInside(b, a, platform);
}

function isFilesystemRoot(value, platform) {
  return platform === 'win32' ? /^[A-Za-z]:\/$/.test(value) : value === '/';
}

function canonicalForm(value, platform) {
  let rest;
  if (platform === 'win32') {
    if (!DRIVE_RE.test(value)) return false;
    rest = value.slice(3);
  } else {
    if (!value.startsWith('/')) return false;
    rest = value.slice(1);
  }
  if (rest === '') return true;
  return rest.split('/').every((segment) => segment !== '' && segment !== '.' && segment !== '..');
}

function canonicalString(value, platform) {
  if (typeof value !== 'string' || value === '' || /[\0\r\n]/.test(value)) return null;
  const spelled = storedSpelling(value, platform);
  if (platform === 'win32' && process.platform !== 'win32') {
    if (!DRIVE_RE.test(spelled)) return null;
    return spelled.length > 3 ? spelled.replace(/\/+$/, '') : spelled;
  }
  try {
    return storedSpelling(fs.realpathSync.native(value), platform);
  } catch {
    return storedSpelling(path.resolve(value), platform);
  }
}

function resolveContext(context) {
  const source = context || {};
  const platform = source.platform || process.platform;
  const home = canonicalString(source.home !== undefined ? source.home : os.homedir(), platform);
  const surfaces = [];
  const configured = typeof source.claudeConfigDir === 'string' ? source.claudeConfigDir.trim() : '';
  if (configured !== '') {
    const resolved = canonicalString(configured, platform);
    if (resolved) surfaces.push({ name: 'CLAUDE_CONFIG_DIR', path: resolved });
  }
  if (home) {
    const dotClaude = canonicalString(`${home}/.claude`, platform);
    if (dotClaude) surfaces.push({ name: '~/.claude', path: dotClaude });
  }
  const pluginRoot = canonicalString(source.pluginRoot || PLUGIN_ROOT, platform);
  if (pluginRoot) surfaces.push({ name: 'the plugin root', path: pluginRoot });
  if (typeof source.pluginData === 'string' && source.pluginData !== '') {
    const pluginData = canonicalString(source.pluginData, platform);
    if (pluginData) surfaces.push({ name: 'the plugin data directory', path: pluginData });
  }
  const anchor = canonicalString(source.anchor, platform);
  return { platform, home, surfaces, anchor };
}

function pathShapeProblem(value, platform) {
  if (value === '') return 'is empty';
  if (FORBIDDEN_CHARACTER_RE.test(value)) return 'holds a forbidden character';
  if (!canonicalForm(value, platform)) return 'is not a canonical absolute path';
  return '';
}

function positionProblem(value, ctx) {
  if (isFilesystemRoot(value, ctx.platform)) return 'it is a filesystem root';
  if (!ctx.anchor) return 'the anchor is unknown, so its position cannot be judged';
  if (samePath(value, ctx.anchor, ctx.platform)) return 'it is the anchor itself';
  if (strictlyInside(value, ctx.anchor, ctx.platform)) return 'it is an ancestor of the anchor';
  return '';
}

function locationProblem(value, ctx) {
  if (ctx.home) {
    if (samePath(value, ctx.home, ctx.platform)) return 'it is $HOME';
    if (strictlyInside(value, ctx.home, ctx.platform)) return 'it is an ancestor of $HOME';
  }
  for (const surface of ctx.surfaces) {
    if (samePath(value, surface.path, ctx.platform)) return `it is ${surface.name}`;
    if (strictlyInside(value, surface.path, ctx.platform)) return `it is an ancestor of ${surface.name}`;
    if (strictlyInside(surface.path, value, ctx.platform)) return `it lies inside ${surface.name}`;
  }
  return '';
}

function placementProblem(entries, ctx) {
  for (const entry of entries) {
    for (const key of ['path', 'top']) {
      const problem = positionProblem(entry[key], ctx) || locationProblem(entry[key], ctx);
      if (problem) return `code root ${entry.label}: ${problem}`;
    }
  }
  for (let i = 0; i < entries.length; i += 1) {
    for (let j = i + 1; j < entries.length; j += 1) {
      const a = entries[i];
      const b = entries[j];
      for (const left of [a.path, a.top]) {
        for (const right of [b.path, b.top]) {
          if (samePath(left, right, ctx.platform)) return `code roots ${a.label} and ${b.label} name the same directory`;
          if (strictlyInside(left, right, ctx.platform) || strictlyInside(right, left, ctx.platform)) {
            return `code roots ${a.label} and ${b.label} contain each other`;
          }
        }
      }
    }
  }
  return '';
}

function listProblem(list, ctx) {
  if (!Array.isArray(list)) return 'the code-root list is not an array';
  if (list.length === 0) return 'the code-root list is empty, and absence is the only single-root form';
  if (list.length > MAX_CODE_ROOTS) return `the code-root list holds more than ${MAX_CODE_ROOTS} entries`;
  const labels = new Map();
  for (let index = 0; index < list.length; index += 1) {
    const number = index + 1;
    const entry = list[index];
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) return `entry ${number} is not an object`;
    const keys = Object.keys(entry);
    if (keys.some((key) => !ENTRY_KEYS.includes(key))) return `entry ${number} carries a key the reader does not know`;
    const missing = ENTRY_KEYS.find((key) => !Object.prototype.hasOwnProperty.call(entry, key));
    if (missing) return `entry ${number} lacks its ${missing} key`;
    const nonString = ENTRY_KEYS.find((key) => typeof entry[key] !== 'string');
    if (nonString) return `entry ${number}: its ${nonString} is not a string`;
    if (!LABEL_RE.test(entry.label)) return `entry ${number}: its label does not match ${LABEL_RE.source}`;
    if (labels.has(entry.label)) return `entry ${number}: its label ${entry.label} repeats entry ${labels.get(entry.label)}`;
    labels.set(entry.label, number);
    for (const key of ['path', 'top', 'commonDir']) {
      const problem = pathShapeProblem(entry[key], ctx.platform);
      if (problem) return `code root ${entry.label}: its ${key} ${problem}`;
    }
    if (!BASELINE_RE.test(entry.baseline)) return `code root ${entry.label}: its baseline is neither unborn nor a full commit id`;
  }
  return placementProblem(list, ctx);
}

function copyEntry(entry) {
  return { label: entry.label, path: entry.path, top: entry.top, commonDir: entry.commonDir, baseline: entry.baseline };
}

function readCodeRoots(document, context, options) {
  if (!document || typeof document !== 'object' || Array.isArray(document)
      || !Object.prototype.hasOwnProperty.call(document, 'codeRoots')) {
    return { status: READ_STATUSES.ABSENT, roots: [], reason: '' };
  }
  if (!enabledFrom(options)) return { status: READ_STATUSES.DISABLED, roots: [], reason: DISABLED_REASON };
  const ctx = resolveContext(context);
  const problem = listProblem(document.codeRoots, ctx);
  if (problem) return { status: READ_STATUSES.ANCHOR_ONLY, roots: [], reason: problem };
  return { status: READ_STATUSES.OK, roots: document.codeRoots.map(copyEntry), reason: '' };
}

function firstLine(text) {
  return String(text || '').split(/\r?\n/).map((line) => line.replace(/^(fatal|error): /, '').trim()).find((line) => line !== '') || '';
}

function git(args, options) {
  const settings = options || {};
  const result = childProcess.spawnSync('git', [...READ_ONLY_GIT, ...args], {
    env: gitEnvironment(),
    encoding: 'utf8',
    maxBuffer: MAX_GIT_OUTPUT_BYTES,
    timeout: settings.timeoutMs || GIT_TIMEOUT_MS,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error) {
    const code = result.error.code || result.error.message;
    return {
      ok: false,
      status: null,
      stdout: '',
      message: code === 'ETIMEDOUT' ? 'git timed out' : `git could not run (${code})`,
    };
  }
  return { ok: result.status === 0, status: result.status, stdout: result.stdout || '', message: firstLine(result.stderr) };
}

function gitIn(top, args, recipe) {
  const prefix = recipe === RECIPES.AUDIT ? AUDIT_EXCLUDES : [];
  return git([...prefix, '-C', top, ...args]);
}

function commandText(args) {
  return `git ${args.join(' ')}`;
}

function fault(args, result) {
  return {
    ok: false,
    command: commandText(args),
    status: result.status === null ? 'none' : String(result.status),
    message: result.message || 'git printed no message',
  };
}

function nulFields(stdout) {
  return stdout.split('\0').filter((field) => field !== '');
}

function numstatPaths(stdout) {
  const fields = stdout.split('\0');
  const paths = [];
  for (let index = 0; index < fields.length; index += 1) {
    const field = fields[index];
    if (field === '') continue;
    const first = field.indexOf('\t');
    const second = first < 0 ? -1 : field.indexOf('\t', first + 1);
    if (second < 0) continue;
    const name = field.slice(second + 1);
    if (name === '') {
      const renamed = fields[index + 2];
      if (renamed !== undefined && renamed !== '') paths.push(renamed);
      index += 2;
      continue;
    }
    paths.push(name);
  }
  return paths;
}

function topOf(directory, platform) {
  const args = ['-C', directory, 'rev-parse', '--show-toplevel'];
  const result = git(args);
  if (!result.ok) return { ok: false, result, args };
  const printed = result.stdout.replace(/\r?\n$/, '');
  if (printed === '') return { ok: false, result: { status: result.status, message: 'git printed no top level' }, args };
  const canonical = canonicalString(printed, platform);
  if (!canonical) return { ok: false, result: { status: result.status, message: 'the top level git printed does not resolve' }, args };
  return { ok: true, top: canonical, args };
}

function changedPaths(root, recipe, platform) {
  const top = root.top;
  const located = topOf(top, platform);
  if (!located.ok) return fault(located.args, located.result);
  if (!samePath(located.top, canonicalString(top, platform), platform)) {
    return {
      ok: false,
      command: commandText(located.args),
      status: '0',
      message: `the directory is no longer the top of a git work tree (git answers ${located.top})`,
    };
  }
  const paths = new Set();
  const run = (args) => ({ args, result: gitIn(top, args, recipe) });
  const head = run(['rev-parse', '--verify', '--quiet', 'HEAD']);
  if (head.result.status !== 0 && head.result.status !== 1) return fault(['-C', top, ...head.args], head.result);
  if (head.result.status === 0) {
    const diff = run(['diff', '--numstat', '-z', 'HEAD', '--']);
    if (!diff.result.ok) return fault(['-C', top, ...diff.args], diff.result);
    for (const name of numstatPaths(diff.result.stdout)) paths.add(name);
    if (root.baseline === 'unborn') {
      const tree = run(['ls-tree', '-r', '--name-only', '-z', '--full-tree', 'HEAD']);
      if (!tree.result.ok) return fault(['-C', top, ...tree.args], tree.result);
      for (const name of nulFields(tree.result.stdout)) paths.add(name);
    } else {
      const verify = run(['rev-parse', '--verify', '--quiet', `${root.baseline}^{commit}`]);
      if (!verify.result.ok) {
        return {
          ok: false,
          command: commandText(['-C', top, ...verify.args]),
          status: verify.result.status === null ? 'none' : String(verify.result.status),
          message: verify.result.message || 'the recorded baseline no longer names a commit',
        };
      }
      const range = run(['diff', '--name-only', '-z', `${root.baseline}..HEAD`, '--']);
      if (!range.result.ok) return fault(['-C', top, ...range.args], range.result);
      for (const name of nulFields(range.result.stdout)) paths.add(name);
    }
  } else {
    if (root.baseline !== 'unborn') {
      return {
        ok: false,
        command: commandText(['-C', top, ...head.args]),
        status: '1',
        message: 'HEAD is unborn while the recorded baseline names a commit',
      };
    }
    const cached = run(['ls-files', '--cached', '--others', '--exclude-standard', '-z', '--']);
    if (!cached.result.ok) return fault(['-C', top, ...cached.args], cached.result);
    for (const name of nulFields(cached.result.stdout)) paths.add(name);
  }
  const others = run(['ls-files', '--others', '--exclude-standard', '-z', '--']);
  if (!others.result.ok) return fault(['-C', top, ...others.args], others.result);
  for (const name of nulFields(others.result.stdout)) paths.add(name);
  return { ok: true, paths: Array.from(paths).sort() };
}

function enumerateRoot(root, options) {
  const settings = options || {};
  return changedPaths(root, RECIPES.AUDIT, settings.platform || process.platform);
}

function countRoot(root, options) {
  const settings = options || {};
  const listed = changedPaths(root, RECIPES.COUNT, settings.platform || process.platform);
  if (!listed.ok) return { ok: false, count: 'unavailable', fault: listed };
  return { ok: true, count: listed.paths.length };
}

function relativeSpelling(root, candidate) {
  return path.relative(root, candidate).split(path.sep).join('/');
}

function anchorExclusions(anchor, roots, options) {
  const settings = options || {};
  const platform = settings.platform || process.platform;
  const exclusions = [];
  const anchorRoot = canonicalString(anchor, platform);
  if (!anchorRoot || roots.length === 0) return { ok: true, exclusions };
  const located = topOf(anchorRoot, platform);
  if (!located.ok) return { ok: true, exclusions };
  const anchorTop = located.top;
  const add = (name) => {
    if (name === '' || name === '..' || name.startsWith('../') || UNPRINTABLE_PATH_RE.test(name)) return;
    if (!exclusions.includes(name)) exclusions.push(name);
  };
  for (const root of roots) {
    for (const absolute of [root.top, root.path]) {
      if (strictlyInside(anchorTop, absolute, platform)) add(relativeSpelling(anchorTop, absolute));
    }
  }
  const args = ['-C', anchorTop, ...AUDIT_EXCLUDES, 'ls-files', '--others', '--exclude-standard', '-z', '--'];
  const listed = git(args);
  if (!listed.ok) return fault(args, listed);
  for (const entry of nulFields(listed.stdout)) {
    const name = entry.replace(/\/+$/, '');
    let stat;
    try {
      stat = fs.lstatSync(path.join(anchorTop, name));
    } catch {
      continue;
    }
    if (!stat.isSymbolicLink()) continue;
    const target = canonicalString(path.join(anchorTop, name), platform);
    if (target && roots.some((root) => samePath(root.top, target, platform) || strictlyInside(root.top, target, platform))) add(name);
  }
  return { ok: true, exclusions };
}

function isIgnored(top, relativePath) {
  const args = ['-C', top, ...AUDIT_EXCLUDES, 'check-ignore', '-q', '--', relativePath];
  const result = git(args);
  if (result.status === 0) return { ok: true, ignored: true };
  if (result.status === 1) return { ok: true, ignored: false };
  return fault(args, result);
}

function refusal(reason) {
  return { ok: false, reason };
}

function parseSpecs(values, kind) {
  const parsed = [];
  for (const value of values || []) {
    const text = String(value);
    const at = text.indexOf('=');
    if (at <= 0) return { ok: false, reason: `${kind} must be spelled <label>=<value>` };
    parsed.push({ label: text.slice(0, at), value: text.slice(at + 1) });
  }
  return { ok: true, parsed };
}

function absoluteSpelling(value, platform) {
  if (platform === 'win32') return DRIVE_RE.test(storedSpelling(value, platform));
  return value.startsWith('/');
}

function readJsonBounded(file) {
  const C = fs.constants;
  let flags = C.O_RDONLY;
  if (Number.isInteger(C.O_NOFOLLOW)) flags |= C.O_NOFOLLOW;
  if (Number.isInteger(C.O_NONBLOCK)) flags |= C.O_NONBLOCK;
  let fd = -1;
  try {
    fd = fs.openSync(file, flags);
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.size > MAX_DOCUMENT_BYTES) return { ok: false, missing: false };
    const buffer = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < stat.size) {
      const read = fs.readSync(fd, buffer, offset, stat.size - offset, offset);
      if (read <= 0) break;
      offset += read;
    }
    if (offset !== stat.size) return { ok: false, missing: false };
    const value = JSON.parse(buffer.toString('utf8'));
    if (!value || typeof value !== 'object' || Array.isArray(value)) return { ok: false, missing: false };
    return { ok: true, value };
  } catch (error) {
    return { ok: false, missing: Boolean(error && error.code === 'ENOENT') };
  } finally {
    if (fd >= 0) {
      try {
        fs.closeSync(fd);
      } catch {
      }
    }
  }
}

function declaredRootsOf(core, claim, ctx) {
  let file;
  try {
    file = core.adoptionWorkflowStatePath(claim.path, claim.session);
  } catch {
    return { ok: false };
  }
  const read = readJsonBounded(file);
  if (!read.ok) return read.missing ? { ok: true, roots: [] } : { ok: false };
  const document = read.value;
  if (!declaresLiveRoots(document)) return { ok: true, roots: [] };
  const declared = readCodeRoots(document, {
    platform: ctx.platform,
    anchor: claim.path,
    home: ctx.home,
    claudeConfigDir: ctx.claudeConfigDir,
    pluginRoot: ctx.pluginRoot,
    pluginData: ctx.pluginData,
  }, { enabled: true });
  return { ok: true, roots: declared.roots };
}

function exclusivityProblem(entries, request, deps) {
  const reanchor = deps.reanchor || require('./session-reanchor-v1.js');
  const core = deps.core || require('./session-control-core-v1.js');
  const worktreeKeep = deps.worktreeKeep || require('./worktree-keep-v1.js');
  const platform = request.platform || process.platform;
  if (typeof request.recordsDir !== 'string' || request.recordsDir === '') {
    return 'the private Session Control records could not be read, so the live sessions cannot be verified';
  }
  const options = {
    environment: request.environment || process.env,
    recordsDir: request.recordsDir,
    sessionId: request.sessionId,
  };
  let ownKey;
  try {
    ownKey = core.sessionKey(request.sessionId);
  } catch {
    return 'this session cannot be identified, so the live sessions cannot be verified';
  }
  if (request.sessionKey && ownKey !== request.sessionKey) {
    return 'CLAUDE_CODE_SESSION_ID names another session than the one this chain is bound to';
  }
  const registry = reanchor.registryClaims(options);
  if (registry.unverifiable.length > 0) {
    return `the live sessions could not be verified (${registry.unverifiable[0]})`;
  }
  const readSessions = new Set();
  for (const claim of registry.claims) {
    if (claim.source !== 'recorded project root' || readSessions.has(claim.session)) continue;
    readSessions.add(claim.session);
    const declared = declaredRootsOf(core, claim, { ...request, platform });
    if (!declared.ok) return `the workflow document of live session pid ${claim.pid} could not be read`;
    for (const root of declared.roots) {
      for (const entry of entries) {
        if (overlaps(root.top, entry.top, platform) || overlaps(root.path, entry.top, platform)) {
          return `code root ${entry.label}: live session pid ${claim.pid} declared the overlapping code root ${root.label}`;
        }
      }
    }
  }
  const nowMs = typeof request.nowMs === 'number' ? request.nowMs : Date.now();
  const idleMs = worktreeKeep.idleMsFromHours(request.worktreeKeepIdleHours);
  for (const entry of entries) {
    const worktrees = reanchor.registeredWorktrees(entry.top);
    if (worktrees === null) return `code root ${entry.label}: its registered worktrees could not be listed`;
    const live = reanchor.liveClaims({ ...options, worktrees, targetRoot: entry.top, nowMs, idleMs });
    if (live.conflicts.length > 0) return `code root ${entry.label}: another live session claims it (${live.conflicts.length} claim(s))`;
    if (live.unverifiable.length > 0) return `code root ${entry.label}: the live sessions could not be verified (${live.unverifiable[0]})`;
  }
  return '';
}

function shadowProblem(entries, anchorRoot, anchorTop) {
  for (const entry of entries) {
    for (const base of [anchorRoot, anchorTop]) {
      if (!base) continue;
      try {
        fs.lstatSync(path.join(base, `@${entry.label}`));
        return `code root ${entry.label}: the anchor holds a top-level entry named @${entry.label}, which the @${entry.label}/ spelling would shadow`;
      } catch (error) {
        if (!error || error.code !== 'ENOENT') return `code root ${entry.label}: the anchor's @${entry.label} entry could not be examined`;
      }
    }
  }
  return '';
}

function armCodeRoots(request, options, deps) {
  if (!enabledFrom(options)) return refusal(DISABLED_REASON);
  const injected = deps || {};
  const platform = request.platform || process.platform;
  const specs = parseSpecs(request.codeRoots, '--code-root');
  if (!specs.ok) return refusal(specs.reason);
  const baselineSpecs = parseSpecs(request.baselines, '--code-root-baseline');
  if (!baselineSpecs.ok) return refusal(baselineSpecs.reason);
  if (specs.parsed.length === 0) return refusal('no --code-root was given');
  if (specs.parsed.length > MAX_CODE_ROOTS) return refusal(`at most ${MAX_CODE_ROOTS} code roots may be declared`);
  const labels = new Set();
  for (const spec of specs.parsed) {
    if (!LABEL_RE.test(spec.label)) return refusal(`a code-root label must match ${LABEL_RE.source}`);
    if (labels.has(spec.label)) return refusal(`the code-root label ${spec.label} is declared twice`);
    labels.add(spec.label);
    if (spec.value === '') return refusal(`code root ${spec.label}: no path was given`);
  }
  const baselines = new Map();
  for (const spec of baselineSpecs.parsed) {
    if (!labels.has(spec.label)) return refusal(`--code-root-baseline names ${LABEL_RE.test(spec.label) ? spec.label : 'a label'} that no --code-root declares`);
    if (baselines.has(spec.label)) return refusal(`code root ${spec.label}: its baseline is given twice`);
    if (!COMMIT_RE.test(spec.value)) return refusal(`code root ${spec.label}: its baseline is not a hexadecimal commit id`);
    baselines.set(spec.label, spec.value);
  }
  const ctx = resolveContext({
    platform,
    anchor: request.anchor,
    home: request.home,
    claudeConfigDir: request.claudeConfigDir,
    pluginRoot: request.pluginRoot,
    pluginData: request.pluginData,
  });
  if (!ctx.anchor) return refusal('the anchor could not be resolved');
  const candidates = [];
  for (const spec of specs.parsed) {
    if (!absoluteSpelling(spec.value, platform)) return refusal(`code root ${spec.label}: its path must be absolute`);
    let canonical;
    try {
      canonical = storedSpelling(fs.realpathSync.native(spec.value), platform);
    } catch (error) {
      return refusal(`code root ${spec.label}: its path ${error && error.code === 'ENOENT' ? 'does not exist' : 'could not be resolved'}`);
    }
    let stat;
    try {
      stat = fs.statSync(canonical);
    } catch {
      return refusal(`code root ${spec.label}: its path could not be examined`);
    }
    if (!stat.isDirectory()) return refusal(`code root ${spec.label}: its path is not a directory`);
    const shape = pathShapeProblem(canonical, platform);
    if (shape) return refusal(`code root ${spec.label}: its canonical path ${shape}`);
    candidates.push({ label: spec.label, path: canonical });
  }
  const placed = placementProblem(candidates.map((entry) => ({ ...entry, top: entry.path })), ctx);
  if (placed) return refusal(placed);
  const entries = [];
  for (const candidate of candidates) {
    const insideArgs = ['-C', candidate.path, 'rev-parse', '--is-inside-work-tree'];
    const inside = git(insideArgs);
    if (!inside.ok || inside.stdout.trim() !== 'true') {
      return refusal(`code root ${candidate.label}: it is not a git work tree${inside.message ? ` (${inside.message})` : ''}`);
    }
    const located = topOf(candidate.path, platform);
    if (!located.ok) return refusal(`code root ${candidate.label}: its work-tree top could not be read (${located.result.message})`);
    if (!samePath(located.top, candidate.path, platform)) {
      return refusal(`code root ${candidate.label}: it lies inside the work tree ${located.top} but is not its top`);
    }
    const commonArgs = ['-C', candidate.path, 'rev-parse', '--path-format=absolute', '--git-common-dir'];
    const common = git(commonArgs);
    const commonDir = common.ok ? canonicalString(common.stdout.replace(/\r?\n$/, ''), platform) : null;
    if (!commonDir) return refusal(`code root ${candidate.label}: its git common directory could not be read`);
    const commonShape = pathShapeProblem(commonDir, platform);
    if (commonShape) return refusal(`code root ${candidate.label}: its git common directory ${commonShape}`);
    const head = git(['-C', candidate.path, 'rev-parse', '--verify', '--quiet', 'HEAD^{commit}']);
    if (head.status !== 0 && head.status !== 1) {
      return refusal(`code root ${candidate.label}: its HEAD could not be read (${head.message || 'git failed'})`);
    }
    const headSha = head.status === 0 ? head.stdout.trim() : '';
    let baseline = headSha === '' ? 'unborn' : headSha;
    if (baselines.has(candidate.label)) {
      if (headSha === '') return refusal(`code root ${candidate.label}: its HEAD is unborn, so no baseline commit can be an ancestor of it`);
      const named = git(['-C', candidate.path, 'rev-parse', '--verify', '--quiet', `${baselines.get(candidate.label)}^{commit}`]);
      if (named.status !== 0) return refusal(`code root ${candidate.label}: its baseline does not name a commit`);
      const full = named.stdout.trim();
      const ancestor = git(['-C', candidate.path, 'merge-base', '--is-ancestor', full, headSha]);
      if (ancestor.status === 1) return refusal(`code root ${candidate.label}: its baseline is not an ancestor of the root's HEAD`);
      if (ancestor.status !== 0) return refusal(`code root ${candidate.label}: its baseline could not be checked (${ancestor.message || 'git failed'})`);
      baseline = full;
    }
    if (!BASELINE_RE.test(baseline)) return refusal(`code root ${candidate.label}: its baseline is not a full commit id`);
    entries.push({ label: candidate.label, path: candidate.path, top: located.top, commonDir, baseline });
  }
  const listed = listProblem(entries, ctx);
  if (listed) return refusal(listed);
  const anchorTop = topOf(ctx.anchor, platform);
  const shadow = shadowProblem(entries, ctx.anchor, anchorTop.ok ? anchorTop.top : null);
  if (shadow) return refusal(shadow);
  const exclusive = exclusivityProblem(entries, request, injected);
  if (exclusive) return refusal(exclusive);
  return { ok: true, roots: entries };
}

function readDocumentFile(file) {
  if (!file) return { ok: true, document: null };
  const read = readJsonBounded(file);
  if (read.ok) return { ok: true, document: read.value };
  if (read.missing) return { ok: true, document: null };
  return { ok: false, reason: 'the workflow document could not be read' };
}

function readFromFile(file, context, options) {
  const opened = readDocumentFile(file);
  if (!opened.ok) return { status: READ_STATUSES.ANCHOR_ONLY, roots: [], reason: opened.reason };
  return readCodeRoots(opened.document, context, options);
}

function tab(...fields) {
  return `${fields.join('\t')}\n`;
}

function screen(value) {
  return String(value).replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, '?');
}

function statusLine(read) {
  return tab('status', read.status, screen(read.reason));
}

function rootLines(roots) {
  return roots.map((root) => tab('root', root.label, root.path, root.top, root.baseline)).join('');
}

function parseArgs(argv) {
  const parsed = { verb: argv[0] || '', codeRoots: [], baselines: [] };
  const single = new Set(['--anchor', '--workflow', '--plugin-data', '--session', '--top', '--path']);
  for (let index = 1; index < argv.length; index += 1) {
    const flag = argv[index];
    if (index + 1 >= argv.length) return { error: `${screen(flag)} requires a value` };
    const value = argv[index + 1];
    index += 1;
    if (flag === '--code-root') {
      parsed.codeRoots.push(value);
      continue;
    }
    if (flag === '--code-root-baseline') {
      parsed.baselines.push(value);
      continue;
    }
    if (!single.has(flag)) return { error: `unknown argument ${screen(flag)}` };
    const key = flag.slice(2);
    if (Object.prototype.hasOwnProperty.call(parsed, key)) return { error: `${flag} is given twice` };
    parsed[key] = value;
  }
  return parsed;
}

function usage(message) {
  return { out: '', err: `code-roots-v1: ${message}\n`, code: 2 };
}

function readerContext(args, environment) {
  return {
    anchor: args.anchor,
    pluginData: args['plugin-data'] || '',
    claudeConfigDir: environment.CLAUDE_CONFIG_DIR || '',
  };
}

function armVerb(args, env, options) {
  if (!args.anchor) return usage('--anchor is required');
  let recordsDir = '';
  if (args['plugin-data']) {
    try {
      recordsDir = require('./claude-hook-session-v1.js').privateRecordsDirectory(fs.realpathSync.native(path.resolve(args['plugin-data'])));
    } catch {
      recordsDir = '';
    }
  }
  const armed = armCodeRoots({
    anchor: args.anchor,
    codeRoots: args.codeRoots,
    baselines: args.baselines,
    pluginData: args['plugin-data'] || '',
    claudeConfigDir: env.CLAUDE_CONFIG_DIR || '',
    sessionId: env.CLAUDE_CODE_SESSION_ID || '',
    sessionKey: args.session || '',
    recordsDir,
    environment: env,
    worktreeKeepIdleHours: env.ZENSU_CR_WORKTREE_KEEP_IDLE_HOURS,
  }, options);
  if (!armed.ok) return { out: '', err: `${screen(armed.reason)}\n`, code: 2 };
  return { out: `${JSON.stringify(armed.roots)}\n`, err: '', code: 0 };
}

function rootReport(root, verb) {
  if (verb === 'count') {
    const counted = countRoot(root);
    if (counted.ok) return tab('count', root.label, String(counted.count));
    return tab('count', root.label, 'unavailable', screen(counted.fault.command), counted.fault.status, screen(counted.fault.message));
  }
  const listed = enumerateRoot(root);
  if (!listed.ok) return tab('fault', root.label, screen(listed.command), listed.status, screen(listed.message));
  let out = '';
  let unprintable = 0;
  for (const name of listed.paths) {
    if (UNPRINTABLE_PATH_RE.test(name)) {
      unprintable += 1;
      continue;
    }
    out += tab('file', root.label, name);
  }
  if (unprintable > 0) out += tab('unprintable', root.label, String(unprintable));
  return out;
}

function readVerb(args, env, options) {
  if (!args.anchor) return usage('--anchor is required');
  const read = readFromFile(args.workflow, readerContext(args, env), options);
  let out = statusLine(read) + rootLines(read.roots);
  if (args.verb === 'read' || read.roots.length === 0) return { out, err: '', code: 0 };
  const excluded = anchorExclusions(args.anchor, read.roots);
  if (excluded.ok) {
    out += excluded.exclusions.map((name) => tab('exclude', name)).join('');
  } else {
    out += tab('anchor-fault', screen(excluded.command), excluded.status, screen(excluded.message));
  }
  for (const root of read.roots) out += rootReport(root, args.verb);
  return { out, err: '', code: 0 };
}

function ignoredVerb(args) {
  if (!args.top || args.path === undefined) return usage('ignored needs --top and --path');
  const checked = isIgnored(args.top, args.path);
  if (!checked.ok) return { out: '', err: `${screen(checked.command)} exited ${checked.status}: ${screen(checked.message)}\n`, code: 2 };
  return { out: '', err: '', code: checked.ignored ? 0 : 1 };
}

function main(argv, environment, options) {
  const env = environment || process.env;
  const args = parseArgs(argv);
  if (args.error) return usage(args.error);
  if (args.verb === 'arm') return armVerb(args, env, options);
  if (args.verb === 'read' || args.verb === 'count' || args.verb === 'enumerate') return readVerb(args, env, options);
  if (args.verb === 'ignored') return ignoredVerb(args);
  if (args.verb === 'enabled') return { out: '', err: '', code: enabledFrom(options) ? 0 : 1 };
  return usage(`unknown verb ${screen(args.verb)}`);
}

if (require.main === module) {
  let result;
  try {
    result = main(process.argv.slice(2), process.env);
  } catch (error) {
    result = { out: '', err: `code-roots-v1: ${screen(error && error.message ? error.message : error)}\n`, code: 2 };
  }
  if (result.out) process.stdout.write(result.out);
  if (result.err) process.stderr.write(result.err);
  process.exitCode = result.code;
}

module.exports = {
  CODE_ROOTS_ENABLED,
  DISABLED_REASON,
  MAX_CODE_ROOTS,
  ENTRY_KEYS,
  LABEL_RE,
  FORBIDDEN_CHARACTER_RE,
  READ_STATUSES,
  RECIPES,
  contains,
  declaresLiveRoots,
  readCodeRoots,
  readFromFile,
  armCodeRoots,
  enumerateRoot,
  countRoot,
  anchorExclusions,
  isIgnored,
  numstatPaths,
  main,
};
