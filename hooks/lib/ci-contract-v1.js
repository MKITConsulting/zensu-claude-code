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
const FILTER_KEYS = Object.freeze(['paths', 'paths-ignore', 'branches', 'branches-ignore', 'types']);
const PASSING_CONCLUSIONS = Object.freeze(['success', 'failure']);
const CACHE_KEYS = Object.freeze(['blob', 'job', 'repo', 'result', 'schema', 'verifiedAt', 'workflow']);
const LIMITS = Object.freeze({
  ghTimeoutMs: 20000,
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
  maxCommands: 2,
  maxListValues: 20,
});
const TEST_RE = /(?:\btests?\b|\bsuite\b|pytest|vitest|\bjest\b|\bmocha\b|rspec|phpunit|\bctest\b|\btox\b|\bnox\b|nextest|gradlew?\b|\bmvn\b|\bmaven\b|go test|cargo test|run-all|playwright test|cypress run|dotnet test|mix test|bun test)/i;
const KEY_RE = /^(?:"([^"]*)"|'([^']*)'|([^\s:'"#-][^:]*?))\s*:(?:\s+(.*))?$/;
const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const ACTION_REF_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_./-]+@\S+$/;
const SHA_RE = /^[0-9a-f]{64}$/;

function limitsWith(overrides) {
  return Object.freeze({ ...LIMITS, ...(overrides || {}) });
}

function unverified(reason, transient = false) {
  return { verified: false, reason, transient };
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
  if (host === 'github.com' && REPO_RE.test(repoPath)) return { provider: 'github', host, repo: repoPath };
  return { provider: 'unsupported', host, repo: null };
}

function stripComment(line) {
  let quote = null;
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index];
    if (quote) {
      if (character === quote) quote = null;
      continue;
    }
    if (character === '"' || character === "'") quote = character;
    else if (character === '#' && (index === 0 || /\s/.test(line[index - 1]))) return line.slice(0, index);
  }
  return line;
}

function yamlEntries(text) {
  return text.split(/\r?\n/).map((raw) => {
    const line = stripComment(raw.replace(/\t/g, '  ')).replace(/\s+$/, '');
    const indent = /^ */.exec(line)[0].length;
    return { indent, text: line.slice(indent) };
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

function topLevel(entries, name) {
  return entries.findIndex((entry) => entry.indent === 0 && (keyOf(entry.text) || {}).key === name);
}

function scanWorkflow(text, limits = LIMITS) {
  const result = { readable: false, reason: null, pullRequest: false, pullRequestTarget: false, flowTrigger: false, filters: [], jobs: [] };
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
    for (const cursor of directChildren(entries, jobsIndex)) {
      const job = keyOf(entries[cursor].text);
      if (!job) continue;
      const record = { key: job.key, name: null, condition: null };
      for (const inner of directChildren(entries, cursor)) {
        const field = keyOf(entries[inner].text);
        if (!field) continue;
        if (field.key === 'name') record.name = unquote(field.value);
        if (field.key === 'if') record.condition = field.value;
      }
      result.jobs.push(record);
    }
  }
  return result;
}

function jobMatches(job, pattern) {
  return [job.name, job.key].some((text) => typeof text === 'string' && text !== ''
    && (matchesPattern(text, pattern) || jobPatternOf(text) === pattern || `${text} (*)` === pattern));
}

function conditionsOf(scanResult, jobPattern = null) {
  const out = [];
  for (const filter of scanResult.filters) out.push(`on.pull_request.${filter.key}: ${filter.values.join(', ') || '(block)'}`);
  const bound = typeof jobPattern === 'string' && jobPattern !== '' ? scanResult.jobs.filter((job) => jobMatches(job, jobPattern)) : [];
  for (const job of bound.length > 0 ? bound : scanResult.jobs) {
    if (job.condition) out.push(`job ${job.key} if: ${job.condition}`);
  }
  if (scanResult.flowTrigger) out.push('the trigger block is written in flow form, so its filters were not read');
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
    const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0) | (fs.constants.O_NONBLOCK || 0);
    descriptor = fs.openSync(absolute, flags);
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile()) return { error: `${workflowPath} is not a regular file` };
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

function ghApi(endpoint, options = {}) {
  const limits = options.limits || LIMITS;
  const result = childProcess.spawnSync(options.ghPath || 'gh', ['api', endpoint], {
    env: ghEnvironment(options.env),
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    timeout: limits.ghTimeoutMs,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const label = endpoint.split('?')[0];
  if (result.error) {
    if (result.error.code === 'ENOENT') return { ok: false, reason: 'the GitHub CLI (gh) is not installed', transient: true };
    if (result.error.code === 'ETIMEDOUT') return { ok: false, reason: `gh api ${label} timed out`, transient: true };
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

function proposeJob(jobs, localCommand) {
  const tokens = localTokens(localCommand);
  let best = null;
  for (const group of groupJobs(jobs)) {
    const commands = group.jobs.flatMap(stepCommands);
    let score = 0;
    if (tokens.length > 0 && commands.some((command) => tokens.some((token) => command.includes(token)))) score += 4;
    if (commands.some((command) => TEST_RE.test(command))) score += 2;
    if (TEST_RE.test(group.pattern)) score += 1;
    if (score > 0 && (!best || score > best.score)) best = { pattern: group.pattern, score };
  }
  return best ? best.pattern : null;
}

function uniqueStrings(values) {
  return [...new Set(values.filter((value) => typeof value === 'string' && value !== ''))];
}

function mergeBlocking(repo, base, jobNames, pattern, options) {
  const contexts = new Set();
  let known = false;
  const branch = ghApi(`repos/${repo}/branches/${encodeURIComponent(base)}`, options);
  if (branch.ok && branch.json && typeof branch.json === 'object') {
    known = true;
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
    known = true;
    for (const rule of rules.json) {
      if (!rule || rule.type !== 'required_status_checks') continue;
      const checks = rule.parameters && Array.isArray(rule.parameters.required_status_checks) ? rule.parameters.required_status_checks : [];
      for (const check of checks) {
        if (check && typeof check.context === 'string') contexts.add(check.context);
      }
    }
  }
  if (!known) return 'unknown';
  return [...contexts].some((context) => jobNames.includes(context) || matchesPattern(context, pattern)) ? 'yes' : 'no';
}

function verifyRemote(input) {
  const { repo, workflowPath, job, localCommand, limits } = input;
  const now = input.now;
  const options = { ghPath: input.ghPath, env: input.env, limits };
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
  let pattern = typeof job === 'string' && job !== '' ? job : null;
  let evidence = null;
  let examined = 0;
  for (const run of runs.slice(0, limits.maxJobRuns)) {
    const jobsResponse = ghApi(`repos/${repo}/actions/runs/${run.id}/jobs?per_page=100`, options);
    if (!jobsResponse.ok) return unverified(jobsResponse.reason, true);
    examined += 1;
    const jobs = (jobsResponse.json && Array.isArray(jobsResponse.json.jobs) ? jobsResponse.json.jobs : [])
      .filter((entry) => entry && typeof entry.name === 'string');
    if (!pattern) pattern = proposeJob(jobs, localCommand);
    if (!pattern) continue;
    const matched = jobs.filter((entry) => matchesPattern(entry.name, pattern));
    if (matched.length > 0 && matched.every((entry) => PASSING_CONCLUSIONS.includes(entry.conclusion))) {
      evidence = { run, jobs: matched };
      break;
    }
  }
  if (!pattern) return unverified(`no job in the recent pull_request runs of ${workflowPath} looks like a test run; name one with evidence.ci.job`);
  if (!evidence) return unverified(`job "${pattern}" did not run to success or failure in the last ${examined} pull_request run(s) of ${workflowPath}`);
  if (now - Date.parse(evidence.run.created_at) > limits.maxRunAgeMs) {
    return unverified(`the newest pull_request run in which job "${pattern}" ran is older than ${Math.round(limits.maxRunAgeMs / 86400000)} days`);
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

function cacheName(repo, workflowPath) {
  return `${crypto.createHash('sha256').update(`${repo}\n${workflowPath}`).digest('hex').slice(0, 40)}.json`;
}

function readJsonFile(filePath, maxBytes) {
  let descriptor;
  try {
    const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0) | (fs.constants.O_NONBLOCK || 0);
    descriptor = fs.openSync(filePath, flags);
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile() || stat.size > maxBytes) return null;
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

function decorate(result, extra) {
  return { ...result, ...extra };
}

function verify(options) {
  const limits = limitsWith(options.limits);
  const now = Number.isInteger(options.now) ? options.now : Date.now();
  const env = options.env || process.env;
  const projectRoot = options.projectRoot;
  if (typeof projectRoot !== 'string' || projectRoot === '') return unverified('no project root is bound');
  if (insideCi(env)) return unverified('this process runs inside a CI pipeline, which is where the full suite runs');
  const workflowPath = normalizeWorkflowPath(options.workflow);
  if (!workflowPath) return unverified(`evidence.ci.workflow must name a .yml or .yaml file directly under ${WORKFLOW_DIR}`);
  const identity = repoIdentity(remoteUrl(projectRoot, env, limits));
  if (identity.provider === 'unknown') return unverified('the repository has no usable git remote');
  if (identity.provider !== 'github') return unverified(`the code forge ${identity.host} is not supported yet (GitHub.com only)`);
  const file = readWorkflowFile(projectRoot, workflowPath, limits);
  if (file.error) return unverified(file.error);
  const scanned = scanWorkflow(file.text, limits);
  if (!scanned.readable) return unverified(`${workflowPath}: ${scanned.reason}`);
  if (!scanned.pullRequest) {
    return unverified(`${workflowPath} does not trigger on pull_request${scanned.pullRequestTarget ? ' (pull_request_target runs the base branch workflow and does not count)' : ''}`);
  }
  let directory = null;
  try {
    directory = cacheDirectory(options.pluginData);
  } catch {
    directory = null;
  }
  const name = cacheName(identity.repo, workflowPath);
  const cached = directory ? readJsonFile(path.join(directory, name), limits.maxCacheBytes) : null;
  const valid = validCacheEntry(cached, identity.repo, workflowPath);
  const wantedJob = typeof options.job === 'string' && options.job !== '' ? options.job : null;
  const usable = valid && cached.blob === file.blob && (!wantedJob || cached.job === wantedJob);
  const age = usable ? Math.max(0, now - Date.parse(cached.verifiedAt)) : Infinity;
  const extraFor = (job) => ({ workflow: workflowPath, repo: identity.repo, conditions: conditionsOf(scanned, job || wantedJob) });
  if (options.mode !== 'refresh') {
    if (usable && age <= limits.cacheGraceMs) return decorate(cached.result, { ...extraFor(cached.result.job), ageMs: age, stale: age > limits.cacheTtlMs, refreshFailure: null });
    if (valid && cached.blob !== file.blob) return decorate(unverified(`${workflowPath} changed since it was verified, so CI may no longer run what was verified`), extraFor(null));
    if (valid && wantedJob && cached.job !== wantedJob) return decorate(unverified(`the verified job "${cached.job}" is not the requested job "${wantedJob}"; run --full-suite-policy --refresh`), extraFor(null));
    if (usable) return decorate(unverified(`the verification is older than ${Math.round(limits.cacheGraceMs / 86400000)} days; run --full-suite-policy --refresh`), extraFor(cached.job));
    return decorate(unverified('no verification of the CI pull-request pipeline is cached yet; run --full-suite-policy --refresh'), extraFor(null));
  }
  if (usable && age <= limits.cacheTtlMs) return decorate(cached.result, { ...extraFor(cached.result.job), ageMs: age, stale: false, refreshFailure: null });
  const remote = verifyRemote({ repo: identity.repo, workflowPath, job: wantedJob, localCommand: options.localCommand, ghPath: options.ghPath, env, limits, now });
  if (remote.verified) {
    if (directory) {
      try {
        writeJsonAtomic(directory, name, { schema: SCHEMA, repo: identity.repo, workflow: workflowPath, job: remote.job, blob: file.blob, verifiedAt: new Date(now).toISOString(), result: remote });
      } catch { }
    }
    return decorate(remote, { ...extraFor(remote.job), ageMs: 0, stale: false, refreshFailure: null });
  }
  if (usable && remote.transient && age <= limits.cacheGraceMs) {
    return decorate(cached.result, { ...extraFor(cached.result.job), ageMs: age, stale: true, refreshFailure: remote.reason });
  }
  if (!remote.transient && directory && valid) {
    try {
      fs.rmSync(path.join(directory, name), { force: true });
    } catch { }
  }
  return decorate(remote, extraFor(remote.job));
}

function discover(options) {
  const limits = limitsWith(options.limits);
  const env = options.env || process.env;
  const projectRoot = options.projectRoot;
  if (typeof projectRoot !== 'string' || projectRoot === '') return unverified('no project root is bound');
  if (insideCi(env)) return unverified('this process runs inside a CI pipeline, which is where the full suite runs');
  const candidates = [];
  for (const workflowPath of listWorkflows(projectRoot, limits)) {
    const file = readWorkflowFile(projectRoot, workflowPath, limits);
    if (file.error) continue;
    if (scanWorkflow(file.text, limits).pullRequest) candidates.push(workflowPath);
  }
  if (candidates.length === 0) return unverified(`no workflow under ${WORKFLOW_DIR} triggers on pull_request`);
  let last = null;
  for (const workflowPath of candidates.slice(0, limits.maxCandidates)) {
    const result = verify({ ...options, workflow: workflowPath, job: null });
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
  readJsonFile,
  writeJsonAtomic,
  validCacheEntry,
  verify,
  discover,
};
