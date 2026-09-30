'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const childProcess = require('node:child_process');
const { ensurePrivateDirectory } = require('./review-evidence-lease-v1.js');
const evr = require('./evidence-run-v1.js');
const contract = require('./ci-contract-v1.js');

const CLONE_SCHEMA = 'full-suite-clone-v1';
const SNAPSHOT_SCHEMA = 'full-suite-snapshot-v1';
const RUNNERS = Object.freeze(['ci', 'local']);
const SNAPSHOT_RUNNERS = Object.freeze(['ci', 'local', 'ask']);
const MARKER_STATES = Object.freeze(['ci', 'local', 'released', 'none']);
const RANKS = Object.freeze(['session marker', 'this clone', 'config']);
const RANK_SUBJECTS = Object.freeze({ 'session marker': 'the session marker', 'this clone': 'the record for this clone', config: 'evidence.fullSuiteRunner in the config' });
const SESSION_KEY_RE = /^scv1_[0-9a-f]{64}$/;
const CLONE_KEYS = Object.freeze(['commonDir', 'decidedAt', 'job', 'runner', 'schema', 'workflow']);
const SNAPSHOT_KEYS = Object.freeze(['decidedBy', 'projectRoot', 'runner', 'schema', 'sessionKey', 'takenAt']);
const MAX_RECORD_BYTES = 16 * 1024;
const MAX_TRANSPORT_BYTES = 64 * 1024;
const DISPLAY = Object.freeze({ displayMax: 200 });
const HELPER = path.join(__dirname, 'zensu-full-suite.sh');
const DEACTIVATE = '/zensu:full-suite --local --repo (this clone, every worktree) or /zensu:full-suite --local --session (this session only)';

function stores(pluginData) {
  const root = ensurePrivateDirectory(pluginData, contract.STORE_SEGMENTS);
  return {
    root,
    clones: ensurePrivateDirectory(root, ['clones']),
    snapshots: ensurePrivateDirectory(root, ['snapshots']),
  };
}

function commonDir(projectRoot) {
  const result = childProcess.spawnSync('git', ['-C', projectRoot, 'rev-parse', '--path-format=absolute', '--git-common-dir'], {
    env: evr.gitEnvironment(),
    encoding: 'utf8',
    timeout: contract.LIMITS.gitTimeoutMs,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error || result.status !== 0) return null;
  const value = String(result.stdout).trim();
  if (value === '') return null;
  try {
    return fs.realpathSync(value);
  } catch {
    return value;
  }
}

function cloneName(common) {
  return `${crypto.createHash('sha256').update(common).digest('hex').slice(0, 40)}.json`;
}

function isIso(value) {
  return typeof value === 'string' && value.length <= 40 && !Number.isNaN(Date.parse(value));
}

function nullableText(value) {
  return value === null || (typeof value === 'string' && value !== '' && value.length <= 512);
}

function exactKeys(value, keys) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const actual = Object.keys(value).sort();
  return actual.length === keys.length && actual.every((key, index) => key === keys[index]);
}

function validClone(entry, common) {
  if (!exactKeys(entry, CLONE_KEYS)) return false;
  if (entry.schema !== CLONE_SCHEMA || entry.commonDir !== common) return false;
  if (!RUNNERS.includes(entry.runner)) return false;
  return nullableText(entry.workflow) && nullableText(entry.job) && isIso(entry.decidedAt);
}

function validSnapshot(entry, sessionKey) {
  if (!exactKeys(entry, SNAPSHOT_KEYS)) return false;
  if (entry.schema !== SNAPSHOT_SCHEMA || entry.sessionKey !== sessionKey) return false;
  if (!SNAPSHOT_RUNNERS.includes(entry.runner)) return false;
  return typeof entry.projectRoot === 'string' && entry.projectRoot !== '' && typeof entry.decidedBy === 'string' && isIso(entry.takenAt);
}

function readClone(storeSet, projectRoot) {
  const common = commonDir(projectRoot);
  if (!common) return null;
  const entry = contract.readJsonFile(path.join(storeSet.clones, cloneName(common)), MAX_RECORD_BYTES);
  return validClone(entry, common) ? entry : null;
}

function writeClone(storeSet, projectRoot, runner, workflow, job, now = Date.now()) {
  if (!RUNNERS.includes(runner)) throw new Error(`unknown runner ${runner}`);
  const common = commonDir(projectRoot);
  if (!common) throw new Error('the project is not inside a git repository, so there is no clone to record a choice for');
  const entry = {
    schema: CLONE_SCHEMA,
    commonDir: common,
    runner,
    workflow: typeof workflow === 'string' && workflow !== '' ? workflow : null,
    job: typeof job === 'string' && job !== '' ? job : null,
    decidedAt: new Date(now).toISOString(),
  };
  contract.writeJsonAtomic(storeSet.clones, cloneName(common), entry);
  return entry;
}

function clearClone(storeSet, projectRoot) {
  const common = commonDir(projectRoot);
  if (!common) return false;
  const target = path.join(storeSet.clones, cloneName(common));
  try {
    if (!fs.lstatSync(target).isFile()) return false;
    fs.unlinkSync(target);
    return true;
  } catch {
    return false;
  }
}

function readSnapshot(storeSet, sessionKey) {
  if (!SESSION_KEY_RE.test(String(sessionKey || ''))) return null;
  const entry = contract.readJsonFile(path.join(storeSet.snapshots, `${sessionKey}.json`), MAX_RECORD_BYTES);
  return validSnapshot(entry, sessionKey) ? entry : null;
}

function writeSnapshot(storeSet, sessionKey, projectRoot, policy, now = Date.now()) {
  if (!SESSION_KEY_RE.test(String(sessionKey || ''))) throw new Error('invalid session key');
  if (typeof projectRoot !== 'string' || projectRoot === '') throw new Error('no project root is bound');
  const entry = {
    schema: SNAPSHOT_SCHEMA,
    sessionKey,
    projectRoot,
    runner: SNAPSHOT_RUNNERS.includes(policy.runner) ? policy.runner : 'local',
    decidedBy: String(policy.decidedBy || 'default').slice(0, 64),
    takenAt: new Date(now).toISOString(),
  };
  contract.writeJsonAtomic(storeSet.snapshots, `${sessionKey}.json`, entry);
  return entry;
}

function textOrNull(value) {
  return typeof value === 'string' && value.trim() !== '' && !value.includes('\0') && value.length <= 512 ? value.trim() : null;
}

function normalizeConfig(config) {
  const source = config && typeof config === 'object' && !Array.isArray(config) ? config : {};
  return {
    runner: RUNNERS.includes(source.runner) ? source.runner : null,
    workflow: textOrNull(source.workflow),
    job: textOrNull(source.job),
    fullSuiteCommand: typeof source.fullSuiteCommand === 'string' && source.fullSuiteCommand.trim() !== '' ? source.fullSuiteCommand : null,
  };
}

function resolve(options) {
  const env = options.env || process.env;
  const projectRoot = options.projectRoot;
  const config = normalizeConfig(options.config);
  const marker = MARKER_STATES.includes(options.markerState) ? options.markerState : 'none';
  const base = { runner: 'local', decidedBy: 'default', reason: null, contract: null, localCommand: config.fullSuiteCommand, clone: null, marker, configRunner: config.runner };
  if (typeof projectRoot !== 'string' || projectRoot === '') return { ...base, reason: 'no project root is bound' };
  if (contract.insideCi(env)) return { ...base, reason: 'this process runs inside a CI pipeline, which is where the full suite runs' };
  let storeSet = null;
  let storeFault = null;
  try {
    storeSet = stores(options.pluginData);
  } catch (error) {
    storeFault = error.message;
  }
  const clone = storeSet ? readClone(storeSet, projectRoot) : null;
  const shared = { ...base, clone };
  const values = [marker === 'ci' || marker === 'local' ? marker : null, clone ? clone.runner : null, config.runner];
  const localIndex = values.indexOf('local');
  if (localIndex !== -1) return { ...shared, decidedBy: RANKS[localIndex], reason: `${RANK_SUBJECTS[RANKS[localIndex]]} chose local full-suite runs` };
  const ciIndex = values.indexOf('ci');
  if (ciIndex === -1 && !options.needCandidate) return { ...shared, reason: 'nothing selects CI full-suite runs for this clone or session' };
  const workflow = config.workflow || (clone && clone.workflow) || null;
  const job = config.job || (clone && clone.job) || null;
  const verifyOptions = {
    projectRoot,
    pluginData: options.pluginData,
    workflow,
    job,
    localCommand: config.fullSuiteCommand,
    env,
    mode: options.mode === 'refresh' ? 'refresh' : 'cache',
    now: options.now,
    ghPath: options.ghPath,
    limits: options.limits,
  };
  const result = workflow ? contract.verify(verifyOptions) : contract.discover(verifyOptions);
  if (ciIndex !== -1) {
    const rank = RANKS[ciIndex];
    if (!result.verified) {
      return { ...shared, decidedBy: rank, contract: result, ciRequested: true, reason: `${RANK_SUBJECTS[rank]} chose CI full-suite runs, but the CI pull-request pipeline is not verified: ${result.reason}` };
    }
    if (options.requireSnapshot) {
      const snapshot = storeSet ? readSnapshot(storeSet, options.sessionKey) : null;
      if (!snapshot || snapshot.projectRoot !== projectRoot) {
        return { ...shared, decidedBy: rank, contract: result, ciRequested: true, reason: 'this chain recorded no full-suite snapshot when it began, so it closes as a local chain' };
      }
      if (snapshot.runner !== 'ci') {
        return { ...shared, decidedBy: 'chain begin', contract: result, ciRequested: true, reason: `this chain began with the ${snapshot.runner} runner; a switch to CI takes effect with the next chain` };
      }
    }
    return { ...shared, runner: 'ci', decidedBy: rank, contract: result, reason: null };
  }
  if (result.verified) return { ...shared, runner: 'ask', contract: result, reason: 'nothing is recorded for this clone or session yet' };
  return { ...shared, contract: result, reason: `no verified CI pull-request pipeline runs the full suite: ${result.reason}${storeFault ? ` (plugin store: ${storeFault})` : ''}` };
}

function shown(text, projectRoot) {
  return evr.screen(String(text), projectRoot, DISPLAY);
}

function formatAge(milliseconds) {
  if (!Number.isFinite(milliseconds) || milliseconds < 0) return 'an unknown time';
  const minutes = Math.round(milliseconds / 60000);
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `${hours} h`;
  return `${Math.round(hours / 24)} days`;
}

function contractSummary(result, projectRoot, now = Date.now()) {
  const commands = (result.ciCommands || []).map((command) => `'${shown(command, projectRoot)}'`).join(', ') || 'steps without a run: command';
  const conditions = Array.isArray(result.conditions) && result.conditions.length > 0
    ? result.conditions.map((condition) => shown(condition, projectRoot)).join('; ')
    : 'none found';
  return [
    `CI: ${shown(result.workflow, projectRoot)}, job "${shown(result.job, projectRoot)}"${result.jobCount > 1 ? ` (${result.jobCount} jobs)` : ''} runs ${commands}`,
    `last pull-request run ${formatAge(now - Date.parse(result.lastRun.createdAt))} ago (${result.lastRun.conclusion})${result.skippedNewer > 0 ? `, the job did not run in ${result.skippedNewer} newer run(s)` : ''}`,
    `merge-blocking: ${result.mergeBlocking || 'unknown'}`,
    `conditions: ${conditions}`,
    `verified ${formatAge(result.ageMs)} ago${result.stale ? ' (stale)' : ''}${result.refreshFailure ? `, refresh failed: ${shown(result.refreshFailure, projectRoot)}` : ''}`,
  ].join(' | ');
}

function localCommandText(policy, projectRoot) {
  return policy.localCommand
    ? `local full suite: '${shown(policy.localCommand, projectRoot)}'`
    : 'local full suite: not configured (evidence.fullSuiteCommand)';
}

function renderHelper(pluginData, args) {
  return `CLAUDE_PLUGIN_DATA=${evr.shellQuote(pluginData || '')} bash ${evr.shellQuote(HELPER)} ${args}`;
}

function policyLines(policy, options) {
  const projectRoot = options.projectRoot;
  const now = options.now || Date.now();
  if (policy.runner === 'ci') {
    return [
      `full suite: ci | ${contractSummary(policy.contract, projectRoot, now)} | ${localCommandText(policy, projectRoot)} | decided by: ${policy.decidedBy}`,
      `full suite: no local full-suite run in this chain; CI runs the suite when a pull request against ${shown(policy.contract.base, projectRoot)} is opened or updated | deactivate: ${DEACTIVATE}`,
    ];
  }
  if (policy.runner === 'ask') {
    return [
      `full suite: ask | candidate ${contractSummary(policy.contract, projectRoot, now)} | ${localCommandText(policy, projectRoot)}`,
      `full suite: nothing is recorded yet. Ask the user once, then record the answer. Repository (this clone, every worktree): ${renderHelper(options.pluginData, '--ci --repo')} | this session only: ${renderHelper(options.pluginData, '--ci --session')} | stay local: ${renderHelper(options.pluginData, '--local --session')}`,
    ];
  }
  return [`full suite: local | ${shown(policy.reason || 'local full-suite runs', projectRoot)} | decided by: ${policy.decidedBy}`];
}

function sourceLine(policy, projectRoot) {
  const clone = policy.clone
    ? `${policy.clone.runner}${policy.clone.workflow ? ` (${shown(policy.clone.workflow, projectRoot)}, job "${shown(policy.clone.job || '', projectRoot)}")` : ''}`
    : 'none';
  return `full suite sources: session marker ${policy.marker} | this clone ${clone} | config evidence.fullSuiteRunner ${policy.configRunner || 'unset'}`;
}

function verdictInput(policy, projectRoot, now = Date.now()) {
  if (policy.runner !== 'ci') return { runner: 'local', decidedBy: policy.decidedBy, reason: policy.reason, ciRequested: policy.ciRequested === true };
  return {
    runner: 'ci',
    decidedBy: policy.decidedBy,
    summary: contractSummary(policy.contract, projectRoot, now),
    base: shown(policy.contract.base, projectRoot),
  };
}

function readTransport(directory, name) {
  if (!directory) return null;
  try {
    const text = fs.readFileSync(path.join(directory, name), 'utf8');
    return text.length > MAX_TRANSPORT_BYTES ? null : text;
  } catch {
    return null;
  }
}

function transportConfig(raw) {
  if (raw === null) return {};
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function inputsFromTransport(directory, env, names) {
  return {
    pluginData: env[names.pluginData],
    sessionKey: env[names.sessionKey],
    projectRoot: env[names.projectRoot],
    markerState: String(readTransport(directory, names.marker) || 'none').trim(),
    config: { ...transportConfig(readTransport(directory, 'ci-config.json')), fullSuiteCommand: readTransport(directory, 'full-suite-command') },
    env,
  };
}

function policyInputs(env) {
  return inputsFromTransport(env.ZENSU_FSP_DIR || '', env, {
    pluginData: 'ZENSU_FSP_PLUGIN_DATA',
    sessionKey: 'ZENSU_FSP_SESSION_KEY',
    projectRoot: 'ZENSU_FSP_PROJECT_ROOT',
    marker: 'marker-state',
  });
}

function write(stream, lines) {
  for (const line of lines) stream.write(`${line}\n`);
}

function setClone(inputs, env, now) {
  const runner = env.ZENSU_FSP_RUNNER;
  const storeSet = stores(inputs.pluginData);
  if (runner === 'clear') {
    const removed = clearClone(storeSet, inputs.projectRoot);
    write(process.stdout, [`full-suite: ${removed ? 'the choice recorded for this clone was removed' : 'this clone had no recorded choice'}`]);
    return 0;
  }
  if (runner === 'local') {
    writeClone(storeSet, inputs.projectRoot, 'local', null, null, now);
    write(process.stdout, ['full-suite: local for this clone (every worktree); switch back with /zensu:full-suite --ci --repo']);
    return 0;
  }
  if (runner !== 'ci') {
    process.stderr.write('full-suite-policy: ZENSU_FSP_RUNNER must be ci, local or clear\n');
    return 2;
  }
  const config = normalizeConfig(inputs.config);
  const workflow = textOrNull(env.ZENSU_FSP_WORKFLOW) || config.workflow;
  const job = textOrNull(env.ZENSU_FSP_JOB) || config.job;
  const verifyOptions = { projectRoot: inputs.projectRoot, pluginData: inputs.pluginData, workflow, job, localCommand: config.fullSuiteCommand, env, mode: 'cache', now };
  const result = workflow ? contract.verify(verifyOptions) : contract.discover(verifyOptions);
  if (!result.verified) {
    process.stderr.write(`full-suite: refusing to record CI full-suite runs for this clone — ${shown(result.reason, inputs.projectRoot)}\n`);
    return 2;
  }
  writeClone(storeSet, inputs.projectRoot, 'ci', result.workflow, result.job, now);
  write(process.stdout, [
    `full-suite: ci for this clone (every worktree) — ${shown(result.workflow, inputs.projectRoot)}, job "${shown(result.job, inputs.projectRoot)}"; later chains do not ask again`,
    `full-suite: deactivate with ${DEACTIVATE}`,
  ]);
  return 0;
}

async function main(argv, env = process.env) {
  const mode = argv[0];
  const inputs = policyInputs(env);
  const now = Date.now();
  try {
    if (mode === 'policy' || mode === 'status') {
      const policy = resolve({ ...inputs, mode: env.ZENSU_FSP_REFRESH === '1' ? 'refresh' : 'cache', needCandidate: true, now });
      write(process.stdout, policyLines(policy, { ...inputs, now }));
      if (mode === 'status') write(process.stdout, [sourceLine(policy, inputs.projectRoot)]);
      return 0;
    }
    if (mode === 'snapshot') {
      const policy = resolve({ ...inputs, mode: 'cache', needCandidate: false, now });
      writeSnapshot(stores(inputs.pluginData), inputs.sessionKey, inputs.projectRoot, policy, now);
      return 0;
    }
    if (mode === 'effective') {
      const policy = resolve({ ...inputs, mode: 'cache', needCandidate: false, requireSnapshot: true, now });
      write(process.stdout, [policy.runner === 'ci' ? 'ci' : 'local']);
      return 0;
    }
    if (mode === 'set-clone') return setClone(inputs, env, now);
  } catch (error) {
    process.stderr.write(`full-suite-policy: ${error && error.message ? error.message : String(error)}\n`);
    return 2;
  }
  process.stderr.write('usage: full-suite-policy-v1.js policy|status|snapshot|effective|set-clone\n');
  return 2;
}

module.exports = {
  CLONE_SCHEMA,
  SNAPSHOT_SCHEMA,
  RUNNERS,
  MARKER_STATES,
  RANKS,
  DEACTIVATE,
  stores,
  commonDir,
  readClone,
  writeClone,
  clearClone,
  readSnapshot,
  writeSnapshot,
  normalizeConfig,
  resolve,
  formatAge,
  contractSummary,
  policyLines,
  sourceLine,
  verdictInput,
  inputsFromTransport,
  policyInputs,
  main,
};

if (require.main === module) {
  main(process.argv.slice(2)).then((code) => {
    process.exitCode = code;
  }, (error) => {
    process.stderr.write(`full-suite-policy-v1: ${error && error.message ? error.message : String(error)}\n`);
    process.exitCode = 2;
  });
}
