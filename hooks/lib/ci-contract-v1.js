'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const childProcess = require('node:child_process');
const { ensurePrivateDirectory } = require('./review-evidence-lease-v1.js');
const evr = require('./evidence-run-v1.js');

const SCHEMA = 'ci-contract-v1';
const STORE_SEGMENTS = Object.freeze(['ci-contract', 'v1']);
const WORKFLOW_DIR = '.github/workflows';
const GITHUB_HOST = 'github.com';
const FILTER_KEYS = Object.freeze(['paths', 'paths-ignore', 'branches', 'branches-ignore', 'types']);
const PASSING_CONCLUSIONS = Object.freeze(['success', 'failure']);
const CACHE_KEYS = Object.freeze(['blob', 'job', 'repo', 'result', 'schema', 'verifiedAt', 'workflow']);
const LIMITS = Object.freeze({
  ghTimeoutMs: 20000,
  refreshDeadlineMs: 60000,
  gitTimeoutMs: 20000,
  maxWorkflowBytes: 256 * 1024,
  maxWorkflowFiles: 40,
  maxCandidates: 3,
  maxCacheBytes: 64 * 1024,
  runsPerPage: 20,
  maxJobRuns: 5,
  maxRunAgeMs: 30 * 24 * 60 * 60 * 1000,
  cacheTtlMs: 24 * 60 * 60 * 1000,
  cacheGraceMs: 7 * 24 * 60 * 60 * 1000,
  maxProofsPerWorkflow: 16,
  maxCommands: 2,
  maxListValues: 20,
  maxNameChars: 1024,
  maxMatchCells: 4 * 1024 * 1024,
});
const TEST_RE = /(?:\btests?\b|\bsuite\b|pytest|vitest|\bjest\b|\bmocha\b|rspec|phpunit|\bctest\b|\btox\b|\bnox\b|nextest|gradlew?\b|\bmvn\b|\bmaven\b|go test|cargo test|run-all|playwright test|cypress run|dotnet test|mix test|bun test)/i;
const KEY_RE = /^(?:"([^"]*)"|'([^']*)'|([^\s:'"#-][^:]*?))\s*:(?:\s+(.*))?$/;
const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const ACTION_REF_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_./-]+@\S+$/;
const SHA_RE = /^[0-9a-f]{64}$/;
const PROOF_NAME_RE = /^([0-9a-f]{40})\.([0-9a-f]{64})\.([0-9a-f]{16})\.json$/;
const BLOCK_SCALAR_RE = /^[>|](?:[1-9][+-]?|[+-][1-9]?)?$/;
const EXPRESSION_RE = /\$\{\{[\s\S]*?\}\}/;
const ANCHOR_RE = /^&\S+$/;
const MATRIX_SUFFIX = Object.freeze([' ', '(', null, ')']);
const CALLEE_SUFFIX = Object.freeze([' ', '/', ' ', null]);

function limitsWith(overrides) {
  return Object.freeze({ ...LIMITS, ...(overrides || {}) });
}

function unverified(reason, transient = false) {
  return { verified: false, reason, transient };
}

function jobUnverified(reason, job) {
  return { ...unverified(reason), disproves: 'job', job };
}

function truthy(value) {
  return typeof value === 'string' && value !== '' && value !== '0' && value.toLowerCase() !== 'false';
}

function insideCi(env) {
  const source = env || process.env;
  return truthy(source.CI) || source.GITHUB_ACTIONS === 'true' || truthy(source.GITLAB_CI) || truthy(source.TF_BUILD) || truthy(source.BUILDKITE);
}

function git(root, args, limits = LIMITS) {
  const result = childProcess.spawnSync('git', ['-C', root, ...args], {
    env: evr.gitEnvironment(),
    encoding: 'utf8',
    timeout: limits.gitTimeoutMs,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error || result.status !== 0) return null;
  return String(result.stdout).trim();
}

function workflowTree(options, limits = LIMITS) {
  const own = evr.workTreeTop(options.projectRoot, limits);
  if (own.reason !== null) return { error: `git could not place the project root in a work tree: ${own.reason}` };
  let real = options.projectRoot;
  try {
    real = fs.realpathSync.native(options.projectRoot);
  } catch { }
  const below = own.top ? path.relative(own.top, real) : '';
  const prefix = below === '' || below === '..' || below.startsWith(`..${path.sep}`) || path.isAbsolute(below) ? '' : below.split(path.sep).join('/');
  if (typeof options.workTree !== 'string' || options.workTree === '') return { tree: own.top || options.projectRoot, prefix };
  const placed = evr.workTreeTop(options.workTree, limits);
  if (placed.reason !== null) return { error: `git could not place the chain's work tree in a work tree: ${placed.reason}` };
  return { tree: placed.top || options.workTree, prefix };
}

const PATTERN_SYNTAX_RE = /[*?[\]{}+!]/;

function patternReaches(pattern, prefix) {
  const clean = pattern.replace(/^\.\//, '');
  const index = clean.search(PATTERN_SYNTAX_RE);
  const end = index === -1 ? clean.length : Math.max(0, clean[index] === '?' ? index - 1 : index);
  const head = clean.slice(0, end);
  const below = `${prefix}/`;
  return below.startsWith(head) || head.startsWith(below);
}

function patternCovers(pattern, prefix) {
  const match = pattern.replace(/^\.\//, '').match(/^(.*?)\*\*(\/\*)?$/);
  if (!match || PATTERN_SYNTAX_RE.test(match[1])) return false;
  return match[1] === '' || (match[1].endsWith('/') && `${prefix}/`.startsWith(match[1]));
}

function pathFilterRefusal(scanned, workflowPath, prefix, limits = LIMITS) {
  if (prefix === '') return null;
  const where = `the project root lies in ${prefix} below the repository top, so its pull requests may never run the suite`;
  if (scanned.flowTrigger) return `${workflowPath} writes its pull_request trigger in flow form, so its path filters were not read, and ${where}`;
  for (const filter of scanned.filters) {
    if (filter.key !== 'paths' && filter.key !== 'paths-ignore') continue;
    if (filter.values.length === 0 || filter.values.length >= limits.maxListValues) return `${workflowPath} lists pull_request ${filter.key} patterns this check cannot read in full, and ${where}`;
    if (filter.key === 'paths-ignore' && filter.values.some((value) => patternReaches(value, prefix))) {
      return `${workflowPath} has a pull_request paths-ignore pattern that can match files in ${prefix}, and ${where}`;
    }
    if (filter.key === 'paths') {
      const negated = filter.values.filter((value) => value.startsWith('!'));
      const covered = filter.values.some((value) => !value.startsWith('!') && patternCovers(value, prefix));
      if (!covered || negated.some((value) => patternReaches(value.slice(1), prefix))) {
        return `${workflowPath} has pull_request paths patterns that do not cover every file in ${prefix}, and ${where}`;
      }
    }
  }
  return null;
}

function remoteUrl(projectRoot, env, limits = LIMITS) {
  const source = env || process.env;
  if (typeof source.ZENSU_VCS_REMOTE === 'string' && source.ZENSU_VCS_REMOTE !== '') return source.ZENSU_VCS_REMOTE;
  const upstream = git(projectRoot, ['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'], limits);
  const remote = upstream && upstream.includes('/') ? upstream.split('/')[0] : 'origin';
  return git(projectRoot, ['remote', 'get-url', remote], limits) || '';
}

function repoIdentity(url) {
  const trimmed = String(url || '').trim().replace(/\.git$/, '');
  let host = '';
  let repoPath = '';
  let match = trimmed.match(/^[A-Za-z][A-Za-z0-9+.-]*:\/\/([^@/]*@)?([^/:@]+)(?::[0-9]+)?\/(.*)$/);
  if (match) {
    host = match[2];
    repoPath = match[3];
  } else {
    match = trimmed.match(/^([^@/]*@)?([^/:@]+):(.*)$/);
    if (match) {
      host = match[2];
      repoPath = match[3];
    }
  }
  host = host.toLowerCase();
  if (!host) return { provider: 'unknown', host: null, repo: null };
  if (host === GITHUB_HOST && REPO_RE.test(repoPath)) return { provider: 'github', host, repo: repoPath };
  return { provider: 'unsupported', host, repo: null };
}

function stripComment(line) {
  let quote = null;
  let previous = '';
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index];
    if (quote) {
      if (quote === '"' && character === '\\') index += 1;
      else if (character === quote && quote === "'" && line[index + 1] === "'") index += 1;
      else if (character === quote) {
        quote = null;
        previous = character;
      }
      continue;
    }
    if ((character === '"' || character === "'") && (previous === '' || ':-[{,?'.includes(previous))) quote = character;
    else if (character === '#' && (index === 0 || /\s/.test(line[index - 1]))) return line.slice(0, index);
    if (!/\s/.test(character)) previous = character;
  }
  return line;
}

function yamlEntries(text) {
  return text.split(/\r?\n/).map((raw) => {
    const expanded = raw.replace(/\t/g, '  ');
    const line = stripComment(expanded).replace(/\s+$/, '');
    const indent = /^ */.exec(line)[0].length;
    return { indent, text: line.slice(indent), raw: expanded.slice(indent).trim() };
  }).filter((entry) => entry.text !== '' && entry.text !== '---');
}

function keyOf(text) {
  const match = KEY_RE.exec(text);
  if (!match) return null;
  const key = match[1] !== undefined ? match[1] : (match[2] !== undefined ? match[2] : match[3]);
  return { key: key.trim(), value: match[4] === undefined ? '' : match[4].trim() };
}

function unquote(value) {
  return String(value || '').trim().replace(/^"(.*)"$/, '$1').replace(/^'(.*)'$/, '$1');
}

function childrenOf(entries, index) {
  const parent = entries[index].indent;
  const out = [];
  for (let cursor = index + 1; cursor < entries.length; cursor += 1) {
    if (entries[cursor].indent <= parent) break;
    out.push(cursor);
  }
  return out;
}

function directChildren(entries, index) {
  const all = childrenOf(entries, index);
  if (all.length === 0) return [];
  const level = entries[all[0]].indent;
  return all.filter((cursor) => entries[cursor].indent === level);
}

function scalarText(value) {
  const text = String(value).trim();
  if (text.length >= 2 && text.startsWith("'") && text.endsWith("'")) return text.slice(1, -1).replace(/''/g, "'");
  if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
    try {
      const decoded = JSON.parse(text);
      if (typeof decoded === 'string') return decoded;
    } catch { }
    return text.slice(1, -1).replace(/\\(.)/g, '$1');
  }
  return text;
}

function scalarOf(entries, index, value) {
  const block = BLOCK_SCALAR_RE.test(value);
  const lines = childrenOf(entries, index).map((cursor) => (block ? entries[cursor].raw : entries[cursor].text));
  if (block) return lines.length === 0 ? null : lines.join(' ');
  const text = [value, ...lines].filter((line) => line !== '').join(' ');
  return text === '' ? null : scalarText(text);
}

function flowItems(value) {
  const trimmed = value.trim();
  const inner = /^\[(.*)\]$/.exec(trimmed);
  const body = inner ? inner[1] : trimmed;
  return body.split(',').map((item) => unquote(item)).filter(Boolean);
}

function listItems(entries, index, limits) {
  const parent = entries[index].indent;
  const out = [];
  for (let cursor = index + 1; cursor < entries.length; cursor += 1) {
    const entry = entries[cursor];
    if (!entry.text.startsWith('- ')) {
      if (entry.indent <= parent) break;
      continue;
    }
    if (entry.indent < parent) break;
    out.push(unquote(entry.text.slice(2)));
    if (out.length >= limits.maxListValues) break;
  }
  return out;
}

function inlineBody(value) {
  return value !== '' && !ANCHOR_RE.test(value);
}

function topLevel(entries, name) {
  return entries.findIndex((entry) => entry.indent === 0 && (keyOf(entry.text) || {}).key === name);
}

function scanWorkflow(text, limits = LIMITS) {
  const result = { readable: false, reason: null, pullRequest: false, pullRequestTarget: false, flowTrigger: false, flowJobs: false, filters: [], jobs: [] };
  if (typeof text !== 'string') {
    result.reason = 'the workflow could not be read';
    return result;
  }
  const entries = yamlEntries(text);
  const onIndex = topLevel(entries, 'on');
  if (onIndex === -1) {
    result.reason = 'no top-level trigger block (on:) was found';
    return result;
  }
  result.readable = true;
  const onEntry = keyOf(entries[onIndex].text);
  const triggers = new Map();
  if (onEntry.value) {
    result.flowTrigger = /[{]/.test(onEntry.value);
    for (const token of onEntry.value.split(/[^A-Za-z0-9_]+/)) {
      if (token) triggers.set(token, null);
    }
  } else {
    for (const cursor of directChildren(entries, onIndex)) {
      const text = entries[cursor].text;
      if (text.startsWith('- ')) {
        triggers.set(unquote(text.slice(2)), null);
        continue;
      }
      const child = keyOf(text);
      if (!child) continue;
      triggers.set(child.key, child.value ? null : cursor);
      if (child.key === 'pull_request' && /[{]/.test(child.value)) result.flowTrigger = true;
    }
  }
  result.pullRequest = triggers.has('pull_request');
  result.pullRequestTarget = triggers.has('pull_request_target');
  const prIndex = triggers.get('pull_request');
  if (Number.isInteger(prIndex)) {
    for (const cursor of directChildren(entries, prIndex)) {
      const child = keyOf(entries[cursor].text);
      if (!child || !FILTER_KEYS.includes(child.key)) continue;
      const values = child.value ? flowItems(child.value) : listItems(entries, cursor, limits);
      result.filters.push({ key: child.key, values: values.slice(0, limits.maxListValues) });
    }
  }
  const jobsIndex = topLevel(entries, 'jobs');
  if (jobsIndex !== -1) {
    result.flowJobs = inlineBody((keyOf(entries[jobsIndex].text) || { value: '' }).value);
    for (const cursor of directChildren(entries, jobsIndex)) {
      const job = keyOf(entries[cursor].text);
      if (!job) continue;
      const record = { key: job.key, name: null, condition: null, reusable: false, inline: inlineBody(job.value) };
      for (const inner of directChildren(entries, cursor)) {
        const field = keyOf(entries[inner].text);
        if (!field) continue;
        if (field.key === 'name') record.name = scalarOf(entries, inner, field.value);
        if (field.key === 'if') record.condition = field.value;
        if (field.key === 'uses') record.reusable = true;
      }
      result.jobs.push(record);
    }
  }
  return result;
}

function patternTokens(pattern) {
  return Array.from(String(pattern), (character) => (character === '*' ? null : character));
}

function nameTokens(template, limits = LIMITS) {
  const text = String(template);
  if (text.length > limits.maxNameChars) return [null];
  const tokens = [];
  text.split(EXPRESSION_RE).forEach((part, index) => {
    if (index > 0) tokens.push(null);
    for (const character of part) tokens.push(character);
  });
  const solid = tokens.map((token) => token !== null && !/\s/.test(token));
  const first = solid.indexOf(true);
  const last = solid.lastIndexOf(true);
  return tokens.filter((token, index) => token === null || (index >= first && index <= last));
}

function overlaps(left, right) {
  const width = right.length + 1;
  const table = new Uint8Array((left.length + 1) * width);
  for (let i = left.length; i >= 0; i -= 1) {
    for (let j = right.length; j >= 0; j -= 1) {
      let value = 0;
      if (i === left.length && j === right.length) value = 1;
      else if (i < left.length && left[i] === null) value = table[(i + 1) * width + j] || (j < right.length ? table[i * width + j + 1] : 0);
      else if (j < right.length && right[j] === null) value = table[i * width + j + 1] || (i < left.length ? table[(i + 1) * width + j] : 0);
      else if (i < left.length && j < right.length && left[i] === right[j]) value = table[(i + 1) * width + j + 1];
      table[i * width + j] = value;
    }
  }
  return table[0] === 1;
}

function jobTemplate(job) {
  return String(typeof job.name === 'string' && job.name !== '' ? job.name : job.key);
}

function jobShapes(job, limits = LIMITS) {
  if (job.inline === true) return [[null]];
  const base = nameTokens(jobTemplate(job), limits);
  const shapes = [base, [...base, ...MATRIX_SUFFIX]];
  if (job.reusable === true) shapes.push([...base, ...CALLEE_SUFFIX], [...base, ...MATRIX_SUFFIX, ...CALLEE_SUFFIX]);
  return shapes;
}

function widthBound(job, limits) {
  if (job.inline === true) return 2;
  const length = jobTemplate(job).length;
  const base = length > limits.maxNameChars ? 1 : length;
  return 2 * base + 6 + (job.reusable === true ? 2 * base + 14 : 0);
}

function jobMatcher(scanResult, limits = LIMITS) {
  const jobs = scanResult && Array.isArray(scanResult.jobs) ? scanResult.jobs : [];
  const open = Boolean(scanResult && scanResult.flowJobs) || 2 * jobs.reduce((sum, job) => sum + widthBound(job, limits), 0) > limits.maxMatchCells;
  const shaped = open ? [] : jobs.map((job) => ({ job, shapes: jobShapes(job, limits) }));
  const width = shaped.reduce((sum, entry) => entry.shapes.reduce((inner, shape) => inner + shape.length + 1, sum), 0);
  const memo = new Map();
  return (pattern) => {
    if (typeof pattern !== 'string' || pattern === '') return [];
    if (!memo.has(pattern)) {
      let found = null;
      if (!open && (pattern.length + 1) * width <= limits.maxMatchCells) {
        const wanted = patternTokens(pattern);
        found = shaped.filter((entry) => entry.shapes.some((shape) => overlaps(wanted, shape))).map((entry) => entry.job);
      }
      memo.set(pattern, found);
    }
    return memo.get(pattern);
  };
}

function runsFound(found) {
  return found === null || found.length > 0;
}

function versionRuns(scanResult, pattern, limits) {
  return runsFound(jobMatcher(scanResult, limitsWith(limits))(pattern));
}

function notRunHere(workflowPath, pattern) {
  return `${workflowPath} in this working tree defines no job that runs as "${pattern}", so a pull request from this tree would not run it`;
}

function versionUnverified(workflowPath, pattern) {
  return { ...unverified(notRunHere(workflowPath, pattern)), disproves: 'version' };
}

function conditionsOf(scanResult, jobPattern = null, match = null) {
  const out = [];
  for (const filter of scanResult.filters) out.push(`on.pull_request.${filter.key}: ${filter.values.join(', ') || '(block)'}`);
  const found = typeof jobPattern === 'string' && jobPattern !== '' ? (match || jobMatcher(scanResult))(jobPattern) : null;
  const bound = Array.isArray(found) ? found : [];
  for (const job of bound.length > 0 ? bound : scanResult.jobs) {
    if (job.condition) out.push(`job ${job.key} if: ${job.condition}`);
  }
  if (scanResult.flowTrigger) out.push('the trigger block is written in flow form, so its filters were not read');
  if (scanResult.flowJobs) out.push('the jobs block is written in flow form, so its jobs were not read');
  return out;
}

function normalizeWorkflowPath(workflow) {
  if (typeof workflow !== 'string') return null;
  const trimmed = workflow.trim().replace(/\\/g, '/');
  if (trimmed === '' || trimmed.includes('\0')) return null;
  const candidate = trimmed.includes('/') ? trimmed : `${WORKFLOW_DIR}/${trimmed}`;
  const normalized = path.posix.normalize(candidate);
  if (path.posix.dirname(normalized) !== WORKFLOW_DIR) return null;
  if (!/\.ya?ml$/.test(normalized)) return null;
  return normalized;
}

function readWorkflowFile(projectRoot, workflowPath, limits = LIMITS) {
  const absolute = path.join(projectRoot, ...workflowPath.split('/'));
  let descriptor;
  try {
    const before = fs.lstatSync(absolute);
    if (before.isSymbolicLink()) return { error: `${workflowPath} could not be read (symlink)` };
    const noFollow = process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW) ? fs.constants.O_NOFOLLOW : 0;
    const flags = fs.constants.O_RDONLY | noFollow | (fs.constants.O_NONBLOCK || 0);
    descriptor = fs.openSync(absolute, flags);
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile()) return { error: `${workflowPath} is not a regular file` };
    if (stat.dev !== before.dev || stat.ino !== before.ino) return { error: `${workflowPath} could not be read (replaced)` };
    if (stat.size > limits.maxWorkflowBytes) return { error: `${workflowPath} is larger than ${limits.maxWorkflowBytes} bytes` };
    const buffer = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < stat.size) {
      const read = fs.readSync(descriptor, buffer, offset, stat.size - offset, offset);
      if (read === 0) break;
      offset += read;
    }
    const bytes = buffer.subarray(0, offset);
    return { text: bytes.toString('utf8'), blob: crypto.createHash('sha256').update(bytes).digest('hex') };
  } catch (error) {
    return { error: error && error.code === 'ENOENT' ? `${workflowPath} does not exist in the working tree` : `${workflowPath} could not be read (${(error && error.code) || 'error'})` };
  } finally {
    if (descriptor !== undefined) {
      try { fs.closeSync(descriptor); } catch { }
    }
  }
}

function listWorkflows(projectRoot, limits = LIMITS) {
  let names;
  try {
    names = fs.readdirSync(path.join(projectRoot, ...WORKFLOW_DIR.split('/')));
  } catch {
    return [];
  }
  return names.filter((name) => /^[^.].*\.ya?ml$/.test(name)).sort().slice(0, limits.maxWorkflowFiles).map((name) => `${WORKFLOW_DIR}/${name}`);
}

function ghEnvironment(env) {
  return { ...(env || process.env), GH_PROMPT_DISABLED: '1', GH_NO_UPDATE_NOTIFIER: '1', NO_COLOR: '1', CLICOLOR: '0' };
}

function refreshDeadline(options, limits) {
  return Number.isFinite(options.deadline) ? options.deadline : Date.now() + limits.refreshDeadlineMs;
}

function ghApi(endpoint, options = {}) {
  const limits = options.limits || LIMITS;
  const label = endpoint.split('?')[0];
  const left = Number.isFinite(options.deadline) ? options.deadline - Date.now() : Infinity;
  const late = `the refresh deadline of ${Math.round(limits.refreshDeadlineMs / 1000)} s passed before gh api ${label} answered`;
  if (left <= 0) return { ok: false, reason: late, transient: true };
  const timeout = Math.max(1, Math.min(limits.ghTimeoutMs, Math.ceil(left)));
  const result = childProcess.spawnSync(options.ghPath || 'gh', ['api', endpoint, '--hostname', GITHUB_HOST], {
    env: ghEnvironment(options.env),
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    timeout,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error) {
    if (result.error.code === 'ENOENT') return { ok: false, reason: 'the GitHub CLI (gh) is not installed', transient: true };
    if (result.error.code === 'ETIMEDOUT') return { ok: false, reason: timeout < limits.ghTimeoutMs ? late : `gh api ${label} timed out`, transient: true };
    return { ok: false, reason: `gh is unavailable (${result.error.code || result.error.message})`, transient: true };
  }
  if (result.status !== 0) {
    const first = String(result.stderr || '').trim().split('\n')[0] || `exit ${result.status}`;
    return { ok: false, reason: `gh api ${label} failed: ${first.slice(0, 160)}`, transient: true };
  }
  try {
    return { ok: true, json: JSON.parse(result.stdout) };
  } catch {
    return { ok: false, reason: `gh api ${label} returned output that is not JSON`, transient: true };
  }
}

function globToRegex(pattern) {
  const escaped = String(pattern).split('*').map((part) => part.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('.*');
  return new RegExp(`^${escaped}$`);
}

function matchesPattern(name, pattern) {
  if (typeof name !== 'string' || typeof pattern !== 'string' || pattern === '') return false;
  return globToRegex(pattern).test(name);
}

function jobPatternOf(name) {
  const match = /^(.*\S) \([^()]*\)$/.exec(name);
  return match ? `${match[1]} (*)` : name;
}

function stepCommands(job) {
  return (Array.isArray(job.steps) ? job.steps : [])
    .map((step) => (step && typeof step.name === 'string' ? step.name : ''))
    .filter((name) => name.startsWith('Run '))
    .map((name) => name.slice(4).trim())
    .filter((command) => command !== '' && !ACTION_REF_RE.test(command));
}

function commandsForDisplay(jobs, limits) {
  const commands = uniqueStrings(jobs.flatMap(stepCommands));
  const testLike = commands.filter((command) => TEST_RE.test(command));
  const rest = commands.filter((command) => !TEST_RE.test(command));
  return [...testLike, ...rest].slice(0, limits.maxCommands);
}

function groupJobs(jobs) {
  const groups = new Map();
  for (const job of jobs) {
    const pattern = jobPatternOf(job.name);
    if (!groups.has(pattern)) groups.set(pattern, []);
    groups.get(pattern).push(job);
  }
  return [...groups.entries()].map(([pattern, members]) => ({ pattern, jobs: members }));
}

function localTokens(command) {
  if (typeof command !== 'string' || command.trim() === '') return [];
  const tokens = [command.trim()];
  for (const word of command.split(/\s+/)) {
    const bare = word.replace(/^["']|["']$/g, '');
    if (bare.includes('/') || /\.(sh|py|js|mjs|cjs|ts|rb|pl)$/.test(bare)) tokens.push(path.posix.basename(bare));
  }
  return tokens.filter((token) => token.length >= 4);
}

function proposeJob(jobs, localCommand, certifiable = () => true) {
  const tokens = localTokens(localCommand);
  let best = null;
  for (const group of groupJobs(jobs)) {
    const commands = group.jobs.flatMap(stepCommands);
    let score = 0;
    if (tokens.length > 0 && commands.some((command) => tokens.some((token) => command.includes(token)))) score += 4;
    if (commands.some((command) => TEST_RE.test(command))) score += 2;
    if (TEST_RE.test(group.pattern)) score += 1;
    if (score > 0 && (!best || score > best.score) && certifiable(group.pattern)) best = { pattern: group.pattern, score };
  }
  return best ? best.pattern : null;
}

function uniqueStrings(values) {
  return [...new Set(values.filter((value) => typeof value === 'string' && value !== ''))];
}

function mergeBlocking(repo, base, jobNames, pattern, options) {
  const contexts = new Set();
  let answered = 0;
  const branch = ghApi(`repos/${repo}/branches/${encodeURIComponent(base)}`, options);
  if (branch.ok && branch.json && typeof branch.json === 'object') {
    answered += 1;
    const required = branch.json.protection && branch.json.protection.required_status_checks;
    if (required && required.enforcement_level !== 'off') {
      for (const context of Array.isArray(required.contexts) ? required.contexts : []) contexts.add(String(context));
      for (const check of Array.isArray(required.checks) ? required.checks : []) {
        if (check && typeof check.context === 'string') contexts.add(check.context);
      }
    }
  }
  const rules = ghApi(`repos/${repo}/rules/branches/${encodeURIComponent(base)}`, options);
  if (rules.ok && Array.isArray(rules.json)) {
    answered += 1;
    for (const rule of rules.json) {
      if (!rule || rule.type !== 'required_status_checks') continue;
      const checks = rule.parameters && Array.isArray(rule.parameters.required_status_checks) ? rule.parameters.required_status_checks : [];
      for (const check of checks) {
        if (check && typeof check.context === 'string') contexts.add(check.context);
      }
    }
  }
  if ([...contexts].some((context) => jobNames.includes(context) || matchesPattern(context, pattern))) return 'yes';
  return answered === 2 ? 'no' : 'unknown';
}

function verifyRemote(input) {
  const { repo, workflowPath, job, localCommand, limits } = input;
  const now = input.now;
  const certifiable = typeof input.certifiable === 'function' ? input.certifiable : () => true;
  let pattern = typeof job === 'string' && job !== '' ? job : null;
  const options ={ ghPath: input.ghPath, env: input.env, limits, deadline: input.deadline };
  const workflowFile = path.posix.basename(workflowPath);
  const info = ghApi(`repos/${repo}`, options);
  if (!info.ok) return unverified(info.reason, true);
  if (!info.json || typeof info.json !== 'object') return unverified('gh returned no repository object', true);
  if (info.json.fork === true) return unverified('the repository is a fork, so its pull requests run CI in the upstream repository');
  const base = typeof info.json.default_branch === 'string' && info.json.default_branch !== '' ? info.json.default_branch : null;
  if (!base) return unverified('the repository reports no default branch');
  const runsResponse = ghApi(`repos/${repo}/actions/workflows/${encodeURIComponent(workflowFile)}/runs?event=pull_request&status=completed&per_page=${limits.runsPerPage}`, options);
  if (!runsResponse.ok) return unverified(runsResponse.reason, true);
  const runs = (runsResponse.json && Array.isArray(runsResponse.json.workflow_runs) ? runsResponse.json.workflow_runs : [])
    .filter((run) => run && Number.isInteger(run.id) && PASSING_CONCLUSIONS.includes(run.conclusion) && !Number.isNaN(Date.parse(run.created_at)))
    .sort((left, right) => Date.parse(right.created_at) - Date.parse(left.created_at));
  if (runs.length === 0) return unverified(`${workflowPath} has no completed pull_request run that concluded success or failure`);
  let dropped = null;
  let evidence = null;
  let examined = 0;
  for (const run of runs.slice(0, limits.maxJobRuns)) {
    const jobsResponse = ghApi(`repos/${repo}/actions/runs/${run.id}/jobs?per_page=100`, options);
    if (!jobsResponse.ok) return unverified(jobsResponse.reason, true);
    examined += 1;
    const jobs = (jobsResponse.json && Array.isArray(jobsResponse.json.jobs) ? jobsResponse.json.jobs : [])
      .filter((entry) => entry && typeof entry.name === 'string');
    if (!pattern) {
      pattern = proposeJob(jobs, localCommand, certifiable);
      if (!pattern && !dropped) dropped = proposeJob(jobs, localCommand);
    }
    if (!pattern) continue;
    const matched = jobs.filter((entry) => matchesPattern(entry.name, pattern));
    if (matched.length > 0 && matched.every((entry) => PASSING_CONCLUSIONS.includes(entry.conclusion))) {
      evidence = { run, jobs: matched };
      break;
    }
  }
  if (!pattern && dropped) return versionUnverified(workflowPath, dropped);
  if (!pattern) return unverified(`no job in the recent pull_request runs of ${workflowPath} looks like a test run; name one with evidence.ci.job`);
  if (!evidence) return jobUnverified(`job "${pattern}" did not run to success or failure in the last ${examined} pull_request run(s) of ${workflowPath}`, pattern);
  if (now - Date.parse(evidence.run.created_at) > limits.maxRunAgeMs) {
    return jobUnverified(`the newest pull_request run in which job "${pattern}" ran is older than ${Math.round(limits.maxRunAgeMs / 86400000)} days`, pattern);
  }
  const jobNames = evidence.jobs.map((entry) => entry.name);
  return {
    verified: true,
    reason: null,
    transient: false,
    workflow: workflowPath,
    job: pattern,
    jobCount: evidence.jobs.length,
    ciCommands: commandsForDisplay(evidence.jobs, limits),
    base,
    lastRun: {
      id: evidence.run.id,
      createdAt: new Date(Date.parse(evidence.run.created_at)).toISOString(),
      conclusion: evidence.jobs.every((entry) => entry.conclusion === 'success') ? 'success' : 'failure',
    },
    skippedNewer: examined - 1,
    mergeBlocking: mergeBlocking(repo, base, jobNames, pattern, options),
  };
}

function cacheDirectory(pluginData) {
  const root = ensurePrivateDirectory(pluginData, STORE_SEGMENTS);
  return ensurePrivateDirectory(root, ['cache']);
}

function cacheKey(repo, workflowPath) {
  return crypto.createHash('sha256').update(`${repo}\n${workflowPath}`).digest('hex').slice(0, 40);
}

function cacheName(repo, workflowPath) {
  return `${cacheKey(repo, workflowPath)}.json`;
}

function jobKey(job) {
  return crypto.createHash('sha256').update(String(job)).digest('hex').slice(0, 16);
}

function proofName(repo, workflowPath, blob, job) {
  return `${cacheKey(repo, workflowPath)}.${blob}.${jobKey(job)}.json`;
}

function readJsonFile(filePath, maxBytes) {
  let descriptor;
  try {
    const before = fs.lstatSync(filePath);
    if (before.isSymbolicLink()) return null;
    const noFollow = process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW) ? fs.constants.O_NOFOLLOW : 0;
    const flags = fs.constants.O_RDONLY | noFollow | (fs.constants.O_NONBLOCK || 0);
    descriptor = fs.openSync(filePath, flags);
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile() || stat.size > maxBytes) return null;
    if (stat.dev !== before.dev || stat.ino !== before.ino) return null;
    const buffer = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < stat.size) {
      const read = fs.readSync(descriptor, buffer, offset, stat.size - offset, offset);
      if (read === 0) break;
      offset += read;
    }
    return JSON.parse(buffer.subarray(0, offset).toString('utf8'));
  } catch {
    return null;
  } finally {
    if (descriptor !== undefined) {
      try { fs.closeSync(descriptor); } catch { }
    }
  }
}

function writeJsonAtomic(directory, name, value) {
  const target = path.join(directory, name);
  const temporary = path.join(directory, `.${name}.${crypto.randomBytes(6).toString('hex')}.tmp`);
  const descriptor = fs.openSync(temporary, 'wx', 0o600);
  try {
    fs.writeFileSync(descriptor, `${JSON.stringify(value)}\n`);
    fs.fsyncSync(descriptor);
  } catch (error) {
    try { fs.closeSync(descriptor); } catch { }
    try { fs.unlinkSync(temporary); } catch { }
    throw error;
  }
  fs.closeSync(descriptor);
  try {
    fs.renameSync(temporary, target);
  } catch (error) {
    try { fs.unlinkSync(temporary); } catch { }
    throw error;
  }
  return target;
}

function validCacheEntry(entry, repo, workflowPath) {
  if (!entry || typeof entry !== 'object' || Array.isArray(entry)) return false;
  const keys = Object.keys(entry).sort();
  if (keys.length !== CACHE_KEYS.length || keys.some((key, index) => key !== CACHE_KEYS[index])) return false;
  if (entry.schema !== SCHEMA || entry.repo !== repo || entry.workflow !== workflowPath) return false;
  if (typeof entry.blob !== 'string' || !SHA_RE.test(entry.blob)) return false;
  if (typeof entry.job !== 'string' || entry.job === '') return false;
  if (typeof entry.verifiedAt !== 'string' || Number.isNaN(Date.parse(entry.verifiedAt))) return false;
  const result = entry.result;
  if (!result || typeof result !== 'object' || result.verified !== true || result.job !== entry.job) return false;
  if (!result.lastRun || Number.isNaN(Date.parse(result.lastRun.createdAt))) return false;
  return true;
}

function proofNames(directory, repo, workflowPath) {
  const key = cacheKey(repo, workflowPath);
  let names;
  try {
    names = fs.readdirSync(directory);
  } catch {
    return [];
  }
  return names
    .map((name) => PROOF_NAME_RE.exec(name))
    .filter((match) => match && match[1] === key)
    .map((match) => ({ name: match[0], blob: match[2], job: match[3] }));
}

function readProof(directory, name, repo, workflowPath, limits) {
  const entry = readJsonFile(path.join(directory, name), limits.maxCacheBytes);
  return validCacheEntry(entry, repo, workflowPath) ? entry : null;
}

function cachedProofs(directory, repo, workflowPath, blob, limits) {
  if (!directory) return [];
  const found = [];
  for (const entry of proofNames(directory, repo, workflowPath)) {
    if (entry.blob !== blob) continue;
    const proof = readProof(directory, entry.name, repo, workflowPath, limits);
    if (proof && proof.blob === blob && jobKey(proof.job) === entry.job) found.push({ proof, legacy: false });
  }
  const legacy = readProof(directory, cacheName(repo, workflowPath), repo, workflowPath, limits);
  if (legacy && legacy.blob === blob) found.push({ proof: legacy, legacy: true });
  return found.sort((left, right) => Date.parse(right.proof.verifiedAt) - Date.parse(left.proof.verifiedAt));
}

function otherVersionsCached(directory, repo, workflowPath, blob, limits) {
  if (!directory) return false;
  if (proofNames(directory, repo, workflowPath).some((entry) => entry.blob !== blob)) return true;
  const legacy = readProof(directory, cacheName(repo, workflowPath), repo, workflowPath, limits);
  return legacy !== null && legacy.blob !== blob;
}

function removeFile(target) {
  try {
    fs.rmSync(target, { force: true });
  } catch { }
}

function keepProof(directory, repo, workflowPath, found) {
  if (!found.legacy) return;
  try {
    writeJsonAtomic(directory, proofName(repo, workflowPath, found.proof.blob, found.proof.job), found.proof);
  } catch { }
}

function pruneProofs(directory, repo, workflowPath, keptName, now, limits) {
  const dated = [];
  for (const entry of proofNames(directory, repo, workflowPath)) {
    if (entry.name === keptName) continue;
    const proof = readProof(directory, entry.name, repo, workflowPath, limits);
    if (!proof || proof.blob !== entry.blob || jobKey(proof.job) !== entry.job) continue;
    dated.push({ name: entry.name, verifiedAt: Date.parse(proof.verifiedAt) });
  }
  dated.sort((left, right) => right.verifiedAt - left.verifiedAt);
  const others = Math.max(0, limits.maxProofsPerWorkflow - 1);
  dated.forEach((entry, index) => {
    if (index >= others || now - entry.verifiedAt > limits.cacheGraceMs) removeFile(path.join(directory, entry.name));
  });
}

function removeProofs(directory, repo, workflowPath, job, limits) {
  for (const entry of proofNames(directory, repo, workflowPath)) {
    if (job === null || entry.job === jobKey(job)) removeFile(path.join(directory, entry.name));
  }
  const legacyPath = path.join(directory, cacheName(repo, workflowPath));
  const legacy = job === null ? null : readJsonFile(legacyPath, limits.maxCacheBytes);
  if (job === null || (legacy && legacy.job === job)) removeFile(legacyPath);
}

function removeVersionProofs(directory, repo, workflowPath, blob, limits) {
  for (const entry of proofNames(directory, repo, workflowPath)) {
    if (entry.blob === blob) removeFile(path.join(directory, entry.name));
  }
  const legacyPath = path.join(directory, cacheName(repo, workflowPath));
  const legacy = readJsonFile(legacyPath, limits.maxCacheBytes);
  if (legacy && legacy.blob === blob) removeFile(legacyPath);
}

function removeDisproved(directory, repo, workflowPath, blob, wantedJob, remote, limits) {
  if (remote.disproves === 'version') {
    removeVersionProofs(directory, repo, workflowPath, blob, limits);
    return;
  }
  if (remote.disproves !== 'job') {
    removeProofs(directory, repo, workflowPath, null, limits);
    return;
  }
  removeProofs(directory, repo, workflowPath, remote.job, limits);
  if (!wantedJob) removeVersionProofs(directory, repo, workflowPath, blob, limits);
}

function decorate(result, extra) {
  return { ...result, ...extra };
}

function verify(options) {
  return verifyIn(options, null);
}

function verifyIn(options, placedTree) {
  const limits = limitsWith(options.limits);
  const deadline = refreshDeadline(options, limits);
  const now = Number.isInteger(options.now) ? options.now : Date.now();
  const env = options.env || process.env;
  const projectRoot = options.projectRoot;
  if (typeof projectRoot !== 'string' || projectRoot === '') return unverified('no project root is bound');
  if (insideCi(env)) return unverified('this process runs inside a CI pipeline, which is where the full suite runs');
  const workflowPath = normalizeWorkflowPath(options.workflow);
  if (!workflowPath) return unverified(`evidence.ci.workflow must name a .yml or .yaml file directly under ${WORKFLOW_DIR}`);
  const placed = placedTree || workflowTree(options, limits);
  if (placed.error) return unverified(placed.error);
  const tree = placed.tree;
  const identity = repoIdentity(remoteUrl(tree, env, limits));
  if (identity.provider === 'unknown') return unverified('the repository has no usable git remote');
  if (identity.provider !== 'github') return unverified(`the code forge ${identity.host} is not supported yet (GitHub.com only)`);
  const file = readWorkflowFile(tree, workflowPath, limits);
  if (file.error) return unverified(file.error);
  const scanned = scanWorkflow(file.text, limits);
  if (!scanned.readable) return unverified(`${workflowPath}: ${scanned.reason}`);
  if (!scanned.pullRequest) {
    return unverified(`${workflowPath} does not trigger on pull_request${scanned.pullRequestTarget ? ' (pull_request_target runs the base branch workflow and does not count)' : ''}`);
  }
  const filtered = pathFilterRefusal(scanned, workflowPath, placed.prefix, limits);
  if (filtered) return unverified(filtered);
  const wantedJob = typeof options.job === 'string' && options.job !== '' ? options.job : null;
  const match = jobMatcher(scanned, limits);
  const runsHere = (pattern) => runsFound(match(pattern));
  const extraFor = (job) => ({ workflow: workflowPath, repo: identity.repo, conditions: conditionsOf(scanned, job || wantedJob, match) });
  if (wantedJob && !runsHere(wantedJob)) return decorate(versionUnverified(workflowPath, wantedJob), extraFor(null));
  let directory = null;
  try {
    directory = cacheDirectory(options.pluginData);
  } catch {
    directory = null;
  }
  const proofs = cachedProofs(directory, identity.repo, workflowPath, file.blob, limits);
  const usable = proofs.filter((found) => runsHere(found.proof.job));
  const chosen = usable.find((found) => !wantedJob || found.proof.job === wantedJob) || null;
  const cached = chosen ? chosen.proof : null;
  const age = cached ? Math.max(0, now - Date.parse(cached.verifiedAt)) : Infinity;
  if (options.mode !== 'refresh') {
    if (cached && age <= limits.cacheGraceMs) {
      keepProof(directory, identity.repo, workflowPath, chosen);
      return decorate(cached.result, { ...extraFor(cached.result.job), ageMs: age, stale: age > limits.cacheTtlMs, refreshFailure: null });
    }
    if (cached) return decorate(unverified(`the verification is older than ${Math.round(limits.cacheGraceMs / 86400000)} days; run --full-suite-policy --refresh`), extraFor(cached.job));
    if (usable.length > 0) return decorate(unverified(`the verified job "${usable[0].proof.job}" is not the requested job "${wantedJob}"; run --full-suite-policy --refresh`), extraFor(null));
    if (proofs.length > 0) {
      const reason = wantedJob ? `no verification of job "${wantedJob}" is cached for this version of ${workflowPath}` : notRunHere(workflowPath, proofs[0].proof.job);
      return decorate(unverified(`${reason}; run --full-suite-policy --refresh`), extraFor(null));
    }
    if (otherVersionsCached(directory, identity.repo, workflowPath, file.blob, limits)) {
      return decorate(unverified(`${workflowPath} in this working tree differs from every verified version, so CI may no longer run what was verified; run --full-suite-policy --refresh`), extraFor(null));
    }
    return decorate(unverified('no verification of the CI pull-request pipeline is cached yet; run --full-suite-policy --refresh'), extraFor(null));
  }
  if (cached && age <= limits.cacheTtlMs) {
    keepProof(directory, identity.repo, workflowPath, chosen);
    return decorate(cached.result, { ...extraFor(cached.result.job), ageMs: age, stale: false, refreshFailure: null });
  }
  const remote = verifyRemote({ repo: identity.repo, workflowPath, job: wantedJob, localCommand: options.localCommand, ghPath: options.ghPath, env, limits, now, certifiable: runsHere, deadline });
  if (remote.verified) {
    if (directory) {
      try {
        const written = proofName(identity.repo, workflowPath, file.blob, remote.job);
        writeJsonAtomic(directory, written, { schema: SCHEMA, repo: identity.repo, workflow: workflowPath, job: remote.job, blob: file.blob, verifiedAt: new Date(now).toISOString(), result: remote });
        pruneProofs(directory, identity.repo, workflowPath, written, now, limits);
      } catch { }
    }
    return decorate(remote, { ...extraFor(remote.job), ageMs: 0, stale: false, refreshFailure: null });
  }
  if (cached && remote.transient && age <= limits.cacheGraceMs) {
    keepProof(directory, identity.repo, workflowPath, chosen);
    return decorate(cached.result, { ...extraFor(cached.result.job), ageMs: age, stale: true, refreshFailure: remote.reason });
  }
  if (!remote.transient && directory) removeDisproved(directory, identity.repo, workflowPath, file.blob, wantedJob, remote, limits);
  return decorate(remote, extraFor(remote.job));
}

function discover(options) {
  const limits = limitsWith(options.limits);
  const deadline = refreshDeadline(options, limits);
  const env = options.env || process.env;
  const projectRoot = options.projectRoot;
  if (typeof projectRoot !== 'string' || projectRoot === '') return unverified('no project root is bound');
  if (insideCi(env)) return unverified('this process runs inside a CI pipeline, which is where the full suite runs');
  const placed = workflowTree(options, limits);
  if (placed.error) return unverified(placed.error);
  const candidates = [];
  for (const workflowPath of listWorkflows(placed.tree, limits)) {
    const file = readWorkflowFile(placed.tree, workflowPath, limits);
    if (file.error) continue;
    if (scanWorkflow(file.text, limits).pullRequest) candidates.push(workflowPath);
  }
  if (candidates.length === 0) return unverified(`no workflow under ${WORKFLOW_DIR} triggers on pull_request`);
  let last = null;
  for (const workflowPath of candidates.slice(0, limits.maxCandidates)) {
    const result = verifyIn({ ...options, workflow: workflowPath, job: null, deadline }, placed);
    if (result.verified) return result;
    last = result;
  }
  return last;
}

module.exports = {
  SCHEMA,
  STORE_SEGMENTS,
  WORKFLOW_DIR,
  LIMITS,
  TEST_RE,
  insideCi,
  remoteUrl,
  repoIdentity,
  scanWorkflow,
  versionRuns,
  conditionsOf,
  normalizeWorkflowPath,
  readWorkflowFile,
  listWorkflows,
  ghApi,
  matchesPattern,
  jobPatternOf,
  stepCommands,
  commandsForDisplay,
  groupJobs,
  proposeJob,
  mergeBlocking,
  verifyRemote,
  cacheDirectory,
  cacheName,
  proofName,
  readJsonFile,
  writeJsonAtomic,
  validCacheEntry,
  verify,
  discover,
};
