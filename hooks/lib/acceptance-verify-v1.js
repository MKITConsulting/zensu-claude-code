'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const childProcess = require('node:child_process');
const { ensurePrivateDirectory } = require('./review-evidence-lease-v1.js');
const { redact, defaultHome } = require('./zensu-artifact-redact-v1.js');
const { scan } = require('./secret-patterns.js');
const evidenceRun = require('./evidence-run-v1.js');
const receipts = require('./edit-landing-receipt-v1.js');

const { canonical, resolveRunLog } = receipts;
const SCHEMA = 'acceptance-verify-v1';
const STORE_SEGMENTS = Object.freeze(['acceptance-verify', 'v1']);
const VERDICTS = Object.freeze(['pass', 'fail', 'partial']);
const ATTESTED_DRIVERS = Object.freeze(['browser', 'mobile', 'desktop-native']);
const OBSERVED_DRIVERS = Object.freeze(['api', 'cli', 'async', 'iac', 'custom', 'library', 'artifact']);
const DRIVERS = Object.freeze([...ATTESTED_DRIVERS, ...OBSERVED_DRIVERS]);
const GATE_MODES = Object.freeze(['required', 'advisory']);
const VERDICT_STATES = Object.freeze([
  'pass',
  'pass-tree-unverified',
  'not-applicable',
  'not-checked',
  'escaped',
  'incomplete',
  'no-criteria',
  'unresolved',
  'invalid',
  'unavailable',
]);
const PASSING_STATES = Object.freeze(['pass', 'pass-tree-unverified', 'not-applicable', 'not-checked', 'escaped']);
const CRITERION_STATES = Object.freeze(['pass', 'fail', 'partial', 'stale', 'missing', 'deprecated', 'dropped']);
const VERIFY_AGAIN_STATES = Object.freeze(['missing', 'stale', 'partial']);
const ID_RE = /^av1_[0-9]{13}_[0-9a-f]{12}$/;
const RECORD_FILE_RE = /^av1_[0-9]{13}_[0-9a-f]{12}\.json$/;
const SESSION_KEY_RE = /^scv1_[0-9a-f]{64}$/;
const TREE_RE = /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/;
const DIGEST_RE = /^[0-9a-f]{64}$/;
const AC_RE = /^AC-([0-9]+)([a-z]?)$/;
const EVIDENCE_RUN_RE = /^er1_[0-9]{13}_[0-9a-f]{12}$/;
const STEM_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$/;
const RECORD_KEYS = Object.freeze([
  'ac',
  'criterion',
  'criterion_digest',
  'driver',
  'evidence',
  'evidence_run',
  'id',
  'plan',
  'plugin_version',
  'project_root',
  'recorded_at',
  'schema',
  'session_key',
  'stem',
  'tree',
  'tree_reason',
  'verdict',
]);
const LIMITS = Object.freeze({
  maxRecordBytes: 64 * 1024,
  maxEvidenceChars: 2000,
  maxCriterionChars: 400,
  maxRecordsPerCriterion: 20,
  maxRecordsPerSession: 400,
  idleSessionMs: 14 * 24 * 60 * 60 * 1000,
  maxReceiptBytes: receipts.MAX_RECEIPT_BYTES,
  displayMax: 200,
  listedCriteria: 12,
  listedPaths: 10,
  listTimeoutMs: 60000,
  gitTimeoutMs: 120000,
});
const REMEDY = '/zensu:verify-feature --chain';

class AcceptanceError extends Error {
  constructor(message) {
    super(message);
    this.name = 'AcceptanceError';
  }
}

function fail(message) {
  throw new AcceptanceError(message);
}

function limitsWith(overrides) {
  return Object.freeze({ ...LIMITS, ...(overrides || {}) });
}

function newRecordId(now = Date.now()) {
  if (!Number.isInteger(now) || now < 0 || now > 9999999999999) fail('clock value out of range');
  return `av1_${String(now).padStart(13, '0')}_${crypto.randomBytes(6).toString('hex')}`;
}

function storeLocations(pluginData, sessionKey) {
  if (typeof sessionKey !== 'string' || !SESSION_KEY_RE.test(sessionKey)) fail('invalid session key');
  let root;
  try {
    root = ensurePrivateDirectory(pluginData, STORE_SEGMENTS);
  } catch (error) {
    fail(`acceptance store unavailable: ${error.message}`);
  }
  return {
    root,
    records: ensurePrivateDirectory(root, ['records', sessionKey]),
    scratch: ensurePrivateDirectory(root, ['scratch']),
  };
}

function isIsoTimestamp(value) {
  return typeof value === 'string' && value.length <= 40 && !Number.isNaN(Date.parse(value));
}

function nullableString(value, max) {
  return value === null || (typeof value === 'string' && value.length <= max);
}

function validateRecord(record, expected = {}) {
  if (!record || typeof record !== 'object' || Array.isArray(record)) return 'not an object';
  const keys = Object.keys(record).sort();
  if (keys.length !== RECORD_KEYS.length || keys.some((key, index) => key !== RECORD_KEYS[index])) {
    return 'unexpected key set';
  }
  if (record.schema !== SCHEMA) return 'unknown schema';
  if (typeof record.id !== 'string' || !ID_RE.test(record.id)) return 'malformed id';
  if (expected.id !== undefined && record.id !== expected.id) return 'id does not match its file name';
  if (typeof record.session_key !== 'string' || !SESSION_KEY_RE.test(record.session_key)) return 'malformed session key';
  if (expected.sessionKey !== undefined && record.session_key !== expected.sessionKey) return 'bound to another session';
  if (typeof record.project_root !== 'string' || record.project_root === '') return 'malformed project root';
  if (expected.projectRoot !== undefined && record.project_root !== expected.projectRoot) return 'bound to another project root';
  if (typeof record.stem !== 'string' || !STEM_RE.test(record.stem)) return 'malformed stem';
  if (record.plan !== `.zensu/plans/${record.stem}.md`) return 'malformed plan';
  if (typeof record.ac !== 'string' || !AC_RE.test(record.ac)) return 'malformed criterion id';
  if (typeof record.criterion !== 'string' || record.criterion.length > LIMITS.maxCriterionChars) return 'malformed criterion';
  if (typeof record.criterion_digest !== 'string' || !DIGEST_RE.test(record.criterion_digest)) return 'malformed criterion digest';
  if (!VERDICTS.includes(record.verdict)) return 'unknown verdict';
  if (!DRIVERS.includes(record.driver)) return 'unknown driver';
  if (typeof record.evidence !== 'string' || record.evidence === '' || record.evidence.length > LIMITS.maxEvidenceChars) {
    return 'malformed evidence';
  }
  if (!(record.evidence_run === null || (typeof record.evidence_run === 'string' && EVIDENCE_RUN_RE.test(record.evidence_run)))) {
    return 'malformed evidence run';
  }
  if (!(record.tree === null || (typeof record.tree === 'string' && TREE_RE.test(record.tree)))) return 'malformed tree';
  if (!nullableString(record.tree_reason, 400)) return 'malformed tree reason';
  if (!isIsoTimestamp(record.recorded_at)) return 'malformed record time';
  if (!nullableString(record.plugin_version, 64)) return 'malformed plugin version';
  return null;
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

function writeRecordAtomic(directory, record) {
  const problem = validateRecord(record);
  if (problem) fail(`refusing to write an invalid record: ${problem}`);
  const target = path.join(directory, `${record.id}.json`);
  const temporary = path.join(directory, `.${record.id}.${crypto.randomBytes(6).toString('hex')}.tmp`);
  const descriptor = fs.openSync(temporary, 'wx', 0o600);
  try {
    fs.writeFileSync(descriptor, `${JSON.stringify(record)}\n`);
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
  syncDirectory(directory);
  return target;
}

function listRecords(locations, expected, limits = LIMITS) {
  let names;
  try {
    names = fs.readdirSync(locations.records);
  } catch (error) {
    fail(`acceptance records unreadable: ${error.code || error.message}`);
  }
  return names
    .filter((name) => RECORD_FILE_RE.test(name))
    .sort()
    .map((name) => {
      const id = name.slice(0, -5);
      const loaded = evidenceRun.readRecordFile(path.join(locations.records, name), limits);
      if (loaded.invalid) return { id, record: null, invalid: loaded.invalid };
      const problem = validateRecord(loaded.record, { ...expected, id });
      if (problem) return { id, record: null, invalid: problem };
      return { id, record: loaded.record, invalid: null };
    });
}

function prune(locations, limits = LIMITS) {
  let entries;
  try {
    entries = listRecords(locations, {}, limits);
  } catch {
    return 0;
  }
  const doomed = new Set();
  const groups = new Map();
  for (const entry of entries) {
    if (!entry.record) continue;
    const key = `${entry.record.stem}\t${entry.record.ac}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(entry.id);
  }
  for (const ids of groups.values()) {
    for (const id of ids.slice(0, Math.max(0, ids.length - limits.maxRecordsPerCriterion))) doomed.add(id);
  }
  const survivors = entries.filter((entry) => !doomed.has(entry.id));
  for (const entry of survivors.slice(0, Math.max(0, survivors.length - limits.maxRecordsPerSession))) doomed.add(entry.id);
  let removed = 0;
  for (const id of doomed) {
    try { fs.unlinkSync(path.join(locations.records, `${id}.json`)); removed += 1; } catch { }
  }
  return removed;
}

function newestMtime(directory) {
  let newest = 0;
  try {
    newest = fs.statSync(directory).mtimeMs;
    for (const name of fs.readdirSync(directory)) {
      try { newest = Math.max(newest, fs.lstatSync(path.join(directory, name)).mtimeMs); } catch { }
    }
  } catch { }
  return newest;
}

function sweepIdleSessions(locations, currentSessionKey, limits = LIMITS, now = Date.now()) {
  let swept = 0;
  const base = path.join(locations.root, 'records');
  let names;
  try { names = fs.readdirSync(base); } catch { return 0; }
  for (const name of names) {
    if (!SESSION_KEY_RE.test(name) || name === currentSessionKey) continue;
    const directory = path.join(base, name);
    try {
      if (fs.lstatSync(directory).isSymbolicLink()) continue;
    } catch { continue; }
    if (now - newestMtime(directory) <= limits.idleSessionMs) continue;
    try {
      fs.rmSync(directory, { recursive: true, force: true });
      swept += 1;
    } catch { }
  }
  return swept;
}

function readPluginVersion() {
  try {
    const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', '.claude-plugin', 'plugin.json'), 'utf8'));
    return typeof manifest.version === 'string' && manifest.version.length <= 64 ? manifest.version : null;
  } catch {
    return null;
  }
}

function normalizeText(text) {
  return String(text).replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, ' ').replace(/\s+/g, ' ').trim();
}

function criterionDigest(text) {
  return crypto.createHash('sha256').update(normalizeText(text), 'utf8').digest('hex');
}

function clip(text, max) {
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

function cleanEvidence(text, projectRoot, limits = LIMITS) {
  if (typeof text !== 'string' || text.trim() === '') {
    return { error: 'the evidence text on stdin is empty: name what was exercised and what was observed' };
  }
  const redacted = redact(text, { projectRoot, home: defaultHome() });
  if (scan(text).matches.length > 0 || scan(redacted).matches.length > 0) {
    return { error: 'the evidence text matches a secret pattern: describe the observation without the value' };
  }
  const cleaned = normalizeText(redacted).replace(/`/g, "'");
  if (cleaned === '') return { error: 'the evidence text on stdin is empty: name what was exercised and what was observed' };
  if (cleaned.length > limits.maxEvidenceChars) return { error: `the evidence text exceeds ${limits.maxEvidenceChars} characters` };
  return { value: cleaned };
}

function display(text, projectRoot, limits = LIMITS) {
  return evidenceRun.screen(text, projectRoot, { ...evidenceRun.LIMITS, displayMax: limits.displayMax });
}

function compareCriterionIds(left, right) {
  const a = AC_RE.exec(left);
  const b = AC_RE.exec(right);
  if (!a || !b) return left < right ? -1 : left > right ? 1 : 0;
  const numeric = Number(a[1]) - Number(b[1]);
  if (numeric !== 0) return numeric;
  return a[2] < b[2] ? -1 : a[2] > b[2] ? 1 : 0;
}

function receiptRunLog(options) {
  return receipts.receiptRunLog({ ...options, maxBytes: LIMITS.maxReceiptBytes });
}

function planFor(root, stem) {
  if (!STEM_RE.test(stem)) return { reason: `the run log name '${display(stem, root)}' is not a plain plan stem` };
  const plansDir = path.join(root, '.zensu', 'plans');
  try {
    if (fs.lstatSync(plansDir).isSymbolicLink()) return { reason: 'the project .zensu/plans directory is a symlink' };
  } catch {
    return { reason: 'the project has no .zensu/plans directory' };
  }
  const planRel = `.zensu/plans/${stem}.md`;
  const planPath = path.join(plansDir, `${stem}.md`);
  let stat;
  try {
    stat = fs.lstatSync(planPath);
  } catch {
    return { reason: `the plan ${planRel} does not exist` };
  }
  if (stat.isSymbolicLink() || !stat.isFile()) return { reason: `the plan ${planRel} is not a regular file` };
  return { planPath, planRel };
}

function readCriteria(planPath, options = {}) {
  const lister = path.join(options.libDir || __dirname, 'zensu-plan-requirements.sh');
  const result = childProcess.spawnSync(options.bashPath || 'bash', ['--noprofile', '--norc', lister, '--list', '--plan', planPath], {
    encoding: 'utf8',
    timeout: LIMITS.listTimeoutMs,
    maxBuffer: 16 * 1024 * 1024,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error) {
    return { status: 'error', reason: `the requirements lister could not run (${result.error.code || result.error.message})` };
  }
  const message = String(result.stderr || '').trim().split('\n').filter(Boolean).pop() || '';
  if (result.status === 3) return { status: 'no-section', reason: 'the plan has no ## Requirements section' };
  if (result.status !== 0 && result.status !== 4) {
    return { status: 'error', reason: message ? clip(normalizeText(message), 300) : `the requirements lister exited ${result.status}` };
  }
  const byId = new Map();
  for (const line of String(result.stdout || '').split('\n')) {
    if (line === '') continue;
    const parts = line.split('\t');
    if (parts.length < 3) continue;
    const id = parts[0];
    const state = parts[1];
    const text = parts.slice(2).join(' ');
    if (!AC_RE.test(id) || (state !== 'active' && state !== 'deprecated')) continue;
    const previous = byId.get(id);
    if (!previous || (previous.state === 'deprecated' && state === 'active')) byId.set(id, { id, state, text });
  }
  if (result.status === 4 && byId.size === 0) return { status: 'unusable', reason: 'the plan has no usable ## Requirements table' };
  return { status: 'ok', criteria: [...byId.values()].sort((left, right) => compareCriterionIds(left.id, right.id)) };
}

function gitEnvironment() {
  return evidenceRun.gitEnvironment();
}

function hasChanges(root, limits = LIMITS) {
  const result = childProcess.spawnSync('git', ['-C', root, 'status', '--porcelain=v1', '-z', '--untracked-files=all', '--', '.', ':(exclude).zensu'], {
    env: gitEnvironment(),
    encoding: 'utf8',
    timeout: limits.gitTimeoutMs,
    maxBuffer: 64 * 1024 * 1024,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error || result.status !== 0) return { known: false };
  return { known: true, changed: String(result.stdout || '').length > 0 };
}

function citedRun(options, runId, currentTree) {
  if (!EVIDENCE_RUN_RE.test(runId)) return { error: `--evidence-run ${JSON.stringify(runId)} is not an evidence-run record id` };
  let locations;
  try {
    locations = evidenceRun.storeLocations(options.pluginData, options.sessionKey);
  } catch (error) {
    return { error: error.message };
  }
  const loaded = evidenceRun.readRecordFile(path.join(locations.records, `${runId}.json`), evidenceRun.LIMITS);
  if (loaded.invalid) {
    return { error: loaded.invalid === 'unreadable (ENOENT)' ? `no evidence run ${runId} exists for this session` : `evidence run ${runId} cannot be read (${loaded.invalid})` };
  }
  const problem = evidenceRun.validateRecord(loaded.record, { id: runId, sessionKey: options.sessionKey, projectRoot: options.projectRoot });
  if (problem) return { error: `evidence run ${runId} does not validate (${problem})` };
  const run = loaded.record;
  if (run.scope !== 'acceptance') {
    return { error: `evidence run ${runId} has scope ${run.scope}; run the check with --evidence-run --scope acceptance` };
  }
  const state = evidenceRun.effectiveState(run);
  if (state !== 'completed') return { error: `evidence run ${runId} is ${state}, not completed` };
  if (run.tree_start && run.tree_end && run.tree_start !== run.tree_end) {
    return { error: `evidence run ${runId} changed the tree while it ran; make the check leave the working tree unchanged, tracked and untracked non-ignored files alike, by writing its output outside the project or to a gitignored path, then run it again` };
  }
  if (currentTree.tree && run.tree_end !== currentTree.tree) {
    return { error: `evidence run ${runId} measured another tree than the current one; run the check again on this tree` };
  }
  return { run };
}

function resolveChain(options) {
  const receipt = receiptRunLog({ receiptPath: options.receiptPath, projectRoot: options.projectRoot });
  const disclosures = [];
  let named = null;
  if (typeof options.logPath === 'string' && options.logPath !== '') {
    named = resolveRunLog(options.projectRoot, options.logPath);
    if (named.reason) return { error: `--log: ${named.reason}` };
  }
  let stem;
  let root;
  if (receipt.status === 'ok') {
    if (named && named.stem !== receipt.stem) {
      return {
        error: `--log names ${display(named.logRel, options.projectRoot)}, but this chain's edit-landing receipt records ${display(receipt.logRel, options.projectRoot)}; pass this chain's run log, or re-run the Phase 6 step 5b Edit Landing Audit when the receipt still describes an earlier generation`,
      };
    }
    stem = receipt.stem;
    root = receipt.root;
  } else if (receipt.status === 'absent') {
    if (!options.editLandingEscaped) {
      return {
        error: 'no edit-landing receipt exists for this chain; run the Phase 6 step 5b Edit Landing Audit first, because acceptance records bind to the plan its receipt names',
      };
    }
    if (!named) return { error: 'the edit-landing gate was escaped, so no receipt names this chain\'s plan; pass --log <this chain\'s run log>' };
    stem = named.stem;
    root = named.root;
    disclosures.push('ACCEPTANCE STEM UNCHECKED — ZENSU_EDIT_LANDING_GATE=off leaves no receipt, so the --log stem was not cross-checked against one');
  } else {
    return { error: receipt.reason };
  }
  const plan = planFor(root, stem);
  if (plan.reason) return { error: plan.reason };
  return { root, stem, planPath: plan.planPath, planRel: plan.planRel, disclosures };
}

function recordLine(record, projectRoot, limits = LIMITS) {
  const kind = record.evidence_run ? `observed ${record.evidence_run}` : 'attested';
  const tree = record.tree ? record.tree.slice(0, 12) : `unverified (${record.tree_reason || 'no tree id'})`;
  return `ACCEPTANCE — ${record.ac} ${record.verdict} | driver=${record.driver} ${kind} | tree=${tree} | record=${record.id} | plan: ${record.plan} | evidence: ${display(record.evidence, projectRoot, limits)}`;
}

function record(options) {
  const limits = limitsWith(options.limits);
  const ac = options.ac;
  if (typeof ac !== 'string' || !AC_RE.test(ac)) return { code: 2, error: '--ac must name an acceptance criterion id such as AC-001' };
  if (!VERDICTS.includes(options.verdict)) return { code: 2, error: `--verdict must be one of ${VERDICTS.join(', ')}` };
  if (!DRIVERS.includes(options.driver)) return { code: 2, error: `--driver must be one of ${DRIVERS.join(', ')}` };
  if (!options.logPath) return { code: 2, error: '--log <this chain\'s run log> is required' };
  const evidence = cleanEvidence(options.evidenceText, options.projectRoot, limits);
  if (evidence.error) return { code: 1, error: evidence.error };
  const chain = resolveChain(options);
  if (chain.error) return { code: 1, error: chain.error };
  const criteria = readCriteria(chain.planPath, options);
  if (criteria.status !== 'ok') return { code: 1, error: `${chain.planRel}: ${criteria.reason}` };
  const criterion = criteria.criteria.find((entry) => entry.id === ac);
  if (!criterion) {
    const known = criteria.criteria.filter((entry) => entry.state === 'active').map((entry) => entry.id);
    return { code: 1, error: `${ac} is not an acceptance criterion of ${chain.planRel} (active: ${known.length > 0 ? known.join(', ') : 'none'})` };
  }
  if (criterion.state === 'deprecated') return { code: 1, error: `${ac} is marked deprecated in ${chain.planRel}, so it is not verified` };
  let locations;
  try {
    locations = storeLocations(options.pluginData, options.sessionKey);
  } catch (error) {
    return { code: 2, error: error.message };
  }
  const currentTree = evidenceRun.computeTree(options.projectRoot, locations.scratch, evidenceRun.LIMITS);
  const runId = typeof options.evidenceRun === 'string' && options.evidenceRun !== '' ? options.evidenceRun : null;
  const observed = OBSERVED_DRIVERS.includes(options.driver);
  if (observed && !runId && options.verdict !== 'partial') {
    return {
      code: 1,
      error: `driver ${options.driver} decides by an exit code, so the plugin must observe it: run the check with zensu-log.sh --evidence-run --scope acceptance --cmd '<check>' and cite its record with --evidence-run`,
    };
  }
  if (runId) {
    const cited = citedRun(options, runId, currentTree);
    if (cited.error) return { code: 1, error: cited.error };
    if (options.verdict === 'pass' && cited.run.exit_code !== 0) {
      return { code: 1, error: `evidence run ${runId} exited ${cited.run.exit_code}, which contradicts --verdict pass` };
    }
    if (options.verdict === 'fail' && cited.run.exit_code === 0) {
      return { code: 1, error: `evidence run ${runId} exited 0, which contradicts --verdict fail` };
    }
  }
  const entry = {
    schema: SCHEMA,
    id: newRecordId(options.now ? options.now() : Date.now()),
    session_key: options.sessionKey,
    project_root: options.projectRoot,
    plan: chain.planRel,
    stem: chain.stem,
    ac,
    criterion: clip(normalizeText(criterion.text), limits.maxCriterionChars),
    criterion_digest: criterionDigest(criterion.text),
    verdict: options.verdict,
    driver: options.driver,
    evidence: evidence.value,
    evidence_run: runId,
    tree: currentTree.tree,
    tree_reason: currentTree.tree ? null : clip(String(currentTree.reason || 'no tree id'), 400),
    recorded_at: new Date(options.now ? options.now() : Date.now()).toISOString(),
    plugin_version: readPluginVersion(),
  };
  try {
    writeRecordAtomic(locations.records, entry);
  } catch (error) {
    return { code: 2, error: `the acceptance record could not be written (${error.code || error.message})` };
  }
  try {
    prune(locations, limits);
    sweepIdleSessions(locations, options.sessionKey, limits);
  } catch { }
  return { code: 0, record: entry, line: recordLine(entry, options.projectRoot, limits), disclosures: chain.disclosures };
}

function evaluate(criteria, entries, currentTree, projectRoot, limits = LIMITS) {
  const byCriterion = new Map();
  for (const entry of entries) {
    if (!byCriterion.has(entry.record.ac)) byCriterion.set(entry.record.ac, []);
    byCriterion.get(entry.record.ac).push(entry.record);
  }
  const rows = criteria.map((criterion) => {
    const records = byCriterion.get(criterion.id) || [];
    const latest = records[records.length - 1] || null;
    if (criterion.state === 'deprecated') {
      if (latest && latest.verdict !== 'pass') {
        return { criterion, state: 'dropped', record: latest, cause: `deprecated while its newest verdict is ${latest.verdict}` };
      }
      return { criterion, state: 'deprecated', record: latest };
    }
    if (records.length === 0) return { criterion, state: 'missing', record: null };
    const digest = criterionDigest(criterion.text);
    const matching = records.filter((entry) => entry.criterion_digest === digest);
    if (matching.length === 0) return { criterion, state: 'stale', record: latest, cause: 'the criterion text changed since it was verified' };
    if (currentTree.tree === null) {
      const last = matching[matching.length - 1];
      return { criterion, state: last.verdict, record: last, treeUnverified: true };
    }
    const onTree = matching.filter((entry) => entry.tree === currentTree.tree);
    if (onTree.length === 0) {
      const last = matching[matching.length - 1];
      const paths = last.tree ? evidenceRun.changedPaths(projectRoot, last.tree, currentTree.tree, { ...evidenceRun.LIMITS, listedPaths: limits.listedPaths }) : null;
      const listed = paths && paths.length > 0
        ? `: ${paths.slice(0, limits.listedPaths).map((entry) => display(entry, projectRoot, limits)).join(', ')}${paths.length > limits.listedPaths ? ', …' : ''}`
        : '';
      return { criterion, state: 'stale', record: last, cause: `files changed since it was verified${listed}` };
    }
    const last = onTree[onTree.length - 1];
    const earlier = last.verdict === 'pass' ? onTree.slice(0, -1).filter((entry) => entry.verdict !== 'pass').length : 0;
    return { criterion, state: last.verdict, record: last, earlierNonPass: earlier };
  });
  const planned = new Set(criteria.map((criterion) => criterion.id));
  const removed = [...byCriterion.keys()].filter((id) => !planned.has(id)).sort(compareCriterionIds);
  for (const id of removed) {
    const records = byCriterion.get(id);
    const latest = records[records.length - 1];
    if (latest.verdict === 'pass') continue;
    rows.push({
      criterion: { id, state: 'removed', text: latest.criterion },
      state: 'dropped',
      record: latest,
      cause: `removed from the plan while its newest verdict is ${latest.verdict}`,
    });
  }
  return rows;
}

function assess(options) {
  const limits = limitsWith(options.limits);
  let locations;
  try {
    locations = storeLocations(options.pluginData, options.sessionKey);
  } catch (error) {
    return { outcome: 'unavailable', reason: error.message };
  }
  const chain = options.chain;
  const criteria = readCriteria(chain.planPath, options);
  if (criteria.status === 'no-section' || criteria.status === 'unusable') return { outcome: 'no-criteria', reason: criteria.reason, chain };
  if (criteria.status !== 'ok') return { outcome: 'unresolved', reason: `${chain.planRel}: ${criteria.reason}`, chain };
  const active = criteria.criteria.filter((entry) => entry.state === 'active');
  if (active.length === 0) {
    return { outcome: 'no-criteria', reason: `${chain.planRel} declares no active acceptance criterion (AC-###)`, chain, criteria: criteria.criteria };
  }
  let entries;
  try {
    entries = listRecords(locations, { sessionKey: options.sessionKey, projectRoot: options.projectRoot }, limits);
  } catch (error) {
    return { outcome: 'unavailable', reason: error.message, chain };
  }
  const valid = entries.filter((entry) => entry.record && entry.record.stem === chain.stem);
  const newestValid = valid.length > 0 ? valid[valid.length - 1].id : '';
  const newestInvalid = entries.filter((entry) => !entry.record && entry.id > newestValid).pop();
  if (newestInvalid) {
    return { outcome: 'invalid', reason: `the newest acceptance record cannot be trusted (${newestInvalid.id}: ${newestInvalid.invalid}); verify again`, chain };
  }
  const currentTree = evidenceRun.computeTree(options.projectRoot, locations.scratch, evidenceRun.LIMITS);
  const rows = evaluate(criteria.criteria, valid, currentTree, options.projectRoot, limits);
  return { outcome: 'evaluated', rows, currentTree, chain };
}

function countKinds(rows) {
  let observed = 0;
  let attested = 0;
  for (const row of rows) {
    if (row.state !== 'pass' || !row.record) continue;
    if (row.record.evidence_run) observed += 1;
    else attested += 1;
  }
  return { observed, attested };
}

function describeRow(row, projectRoot, limits = LIMITS) {
  const id = row.criterion.id;
  const text = display(row.criterion.text, projectRoot, limits);
  if (row.state === 'missing' || row.state === 'deprecated') return `${id} ${row.state} | ${text}`;
  const cause = row.cause ? ` (${row.cause})` : '';
  const how = row.record
    ? ` | ${row.record.driver} ${row.record.evidence_run ? `observed ${row.record.evidence_run}` : 'attested'} | record ${row.record.id}`
    : '';
  const unverified = row.treeUnverified ? ' (tree unverified)' : '';
  return `${id} ${row.state}${cause}${unverified}${how} | ${text}`;
}

function status(options) {
  const limits = limitsWith(options.limits);
  const chain = resolveChain(options);
  if (chain.error) return { code: 2, lines: [`ACCEPTANCE STATUS — unresolved | ${chain.error}`] };
  const result = assess({ ...options, chain });
  if (result.outcome !== 'evaluated') {
    const suffix = remedies(result.outcome, [], chain, options.projectRoot).map((entry) => ` | ${entry}`).join('');
    return { code: result.outcome === 'unavailable' ? 2 : 1, lines: [...chain.disclosures, `ACCEPTANCE STATUS — ${result.outcome} | ${result.reason} | plan: ${chain.planRel}${suffix}`] };
  }
  const active = result.rows.filter((row) => row.criterion.state === 'active');
  const passing = active.filter((row) => row.state === 'pass').length;
  const blocking = result.rows.filter((row) => row.state === 'dropped').length;
  const complete = passing === active.length && blocking === 0;
  const tree = result.currentTree.tree ? result.currentTree.tree.slice(0, 12) : `unverified (${result.currentTree.reason || 'no tree id'})`;
  const suffix = complete ? '' : remedies('incomplete', result.rows, chain, options.projectRoot).map((entry) => ` | ${entry}`).join('');
  const lines = [...chain.disclosures, `ACCEPTANCE STATUS — plan: ${chain.planRel} | tree: ${tree} | ${passing}/${active.length} active criteria pass${blocking > 0 ? ` | ${blocking} dropped` : ''}${suffix}`];
  for (const row of result.rows) lines.push(describeRow(row, options.projectRoot, limits));
  return { code: complete ? 0 : 1, lines };
}

function normalizeGateMode(value, projectRoot) {
  if (value === undefined || value === null || value === '') return { mode: 'required', disclosure: null };
  if (GATE_MODES.includes(value)) return { mode: value, disclosure: null };
  return {
    mode: 'required',
    disclosure: `ACCEPTANCE — evidence.acceptanceGate value ${evidenceRun.shellQuote(display(String(value), projectRoot))} is not recognized (expected required or advisory); treated as required`,
  };
}

function verdictChain(options) {
  if (typeof options.projectRoot !== 'string' || options.projectRoot === '') return { outcome: 'unavailable', reason: 'no project root is bound' };
  const receipt = receiptRunLog({ receiptPath: options.receiptPath, projectRoot: options.projectRoot });
  if (receipt.status === 'invalid') return { outcome: 'unresolved', reason: receipt.reason };
  if (receipt.status === 'ok') {
    const plan = planFor(receipt.root, receipt.stem);
    if (plan.reason) return { outcome: 'unresolved', reason: plan.reason };
    return { chain: { root: receipt.root, stem: receipt.stem, planPath: plan.planPath, planRel: plan.planRel, disclosures: [] } };
  }
  const scope = evidenceRun.workTree(options.projectRoot, evidenceRun.LIMITS);
  if (options.editLandingEscaped) {
    let entries = [];
    try {
      entries = listRecords(storeLocations(options.pluginData, options.sessionKey), { sessionKey: options.sessionKey, projectRoot: options.projectRoot });
    } catch (error) {
      return { outcome: 'unavailable', reason: error.message };
    }
    const newest = entries.filter((entry) => entry.record).pop();
    if (!newest) {
      return { outcome: 'unresolved', reason: 'ZENSU_EDIT_LANDING_GATE=off left no receipt to name this chain\'s plan, and no acceptance record names one either' };
    }
    const root = canonical(path.resolve(options.projectRoot));
    const plan = planFor(root, newest.record.stem);
    if (plan.reason) return { outcome: 'unresolved', reason: plan.reason };
    return {
      chain: {
        root,
        stem: newest.record.stem,
        planPath: plan.planPath,
        planRel: plan.planRel,
        disclosures: ['ACCEPTANCE STEM UNCHECKED — ZENSU_EDIT_LANDING_GATE=off leaves no receipt, so the plan was taken from the newest acceptance record'],
      },
    };
  }
  if (scope.applicable === false) return { outcome: 'not-applicable', reason: `no edit-landing receipt, and ${scope.reason}, so no change can be established` };
  if (scope.applicable === null) return { outcome: 'unavailable', reason: scope.reason };
  const changes = hasChanges(canonical(path.resolve(options.projectRoot)));
  if (!changes.known) return { outcome: 'unavailable', reason: 'git status failed, so the change set is unknown' };
  if (changes.changed) {
    return { outcome: 'unresolved', reason: 'the working tree has changes but no edit-landing receipt names this chain\'s plan; run the Phase 6 step 5b Edit Landing Audit' };
  }
  return { outcome: 'not-applicable', reason: 'no edit-landing receipt and no changed file, so this chain implemented nothing to verify' };
}

function boundLine(validate) {
  if (validate === 'on') {
    return 'ACCEPTANCE — not-checked | Autopilot-bound chain: the /zensu:autopilot VALIDATE stage validates every acceptance criterion of the run';
  }
  if (validate === 'off') {
    return 'ACCEPTANCE — not-checked | Autopilot-bound chain started with --no-validate: live validation is switched off for this run, so no acceptance criterion was validated';
  }
  return 'ACCEPTANCE — not-checked | Autopilot-bound chain: the run\'s validate option could not be read, so whether its VALIDATE stage checks the acceptance criteria is unknown';
}

function verifyRemedy(chain, projectRoot) {
  const log = chain ? ` --log ${display(`.zensu/logs/${chain.stem}.log`, projectRoot)}` : '';
  return `run: ${REMEDY}${log}`;
}

function remedies(state, rows, chain, projectRoot) {
  if (state === 'no-criteria') {
    return ['add: give the plan\'s ## Requirements table an active AC-### criterion, or leave ZENSU_ACCEPTANCE_GATE to the user'];
  }
  if (state === 'invalid') return [verifyRemedy(chain, projectRoot)];
  if (state !== 'incomplete') return [];
  const found = new Set(rows.map((row) => row.state));
  const listed = [];
  if (VERIFY_AGAIN_STATES.some((entry) => found.has(entry))) listed.push(verifyRemedy(chain, projectRoot));
  if (found.has('fail')) {
    listed.push('fix: a criterion that fails on this tree needs a code change before it is verified again; without one, leave the refusal to the user');
  }
  if (found.has('dropped')) {
    listed.push('restore: a dropped criterion needs its row restored or un-deprecated and a pass, or ZENSU_ACCEPTANCE_GATE left to the user');
  }
  return listed;
}

function verdict(options) {
  const limits = limitsWith(options.limits);
  const gate = normalizeGateMode(options.gateMode, options.projectRoot);
  const lines = [];
  if (gate.disclosure) lines.push(gate.disclosure);
  const gateLabel = `gate: ${gate.mode}`;
  if (options.bound) {
    lines.push(boundLine(options.validate));
    return { state: 'not-checked', passes: true, mode: gate.mode, lines };
  }
  const resolved = verdictChain(options);
  if (resolved.outcome === 'not-applicable') {
    lines.push(`ACCEPTANCE — not-applicable | ${resolved.reason} | ${gateLabel}`);
    return { state: 'not-applicable', passes: true, mode: gate.mode, lines };
  }
  if (options.escape) {
    lines.push(`ACCEPTANCE — escaped | ZENSU_ACCEPTANCE_GATE=off switched this check off, so no acceptance record was read | ${gateLabel}`);
    return { state: 'escaped', passes: true, mode: gate.mode, lines };
  }
  let state;
  let cause;
  let planText = '';
  let flaky = [];
  let rows = [];
  if (resolved.chain) {
    lines.push(...resolved.chain.disclosures);
    planText = ` | plan: ${resolved.chain.planRel}`;
    const result = assess({ ...options, chain: resolved.chain });
    if (result.outcome === 'evaluated') {
      rows = result.rows;
      const active = result.rows.filter((row) => row.criterion.state === 'active');
      const deprecated = result.rows.filter((row) => row.state === 'deprecated').map((row) => row.criterion.id);
      const failing = result.rows.filter((row) => row.state !== 'pass' && row.state !== 'deprecated');
      const passing = active.filter((row) => row.state === 'pass').length;
      const tree = result.currentTree.tree ? `the current tree ${result.currentTree.tree.slice(0, 12)}` : `a tree that could not be fingerprinted (${result.currentTree.reason || 'no tree id'})`;
      const deprecatedText = deprecated.length > 0 ? `; deprecated: ${deprecated.join(', ')}` : '';
      if (failing.length === 0) {
        const kinds = countKinds(result.rows);
        state = result.currentTree.tree ? 'pass' : 'pass-tree-unverified';
        cause = `${passing}/${active.length} acceptance criteria pass on ${tree} (observed ${kinds.observed}, attested ${kinds.attested})${deprecatedText}`;
        flaky = result.rows.filter((row) => row.earlierNonPass > 0).map((row) => `${row.criterion.id} had ${row.earlierNonPass} earlier non-pass verdict(s) on this same tree`);
      } else {
        state = 'incomplete';
        const listed = failing.map((row, index) => `${row.criterion.id} ${row.state}${row.cause && index < limits.listedCriteria ? ` (${row.cause})` : ''}`);
        cause = `${passing}/${active.length} acceptance criteria pass on ${tree}; ${listed.join('; ')}${deprecatedText}`;
      }
    } else {
      state = result.outcome;
      cause = result.reason;
    }
  } else {
    state = resolved.outcome;
    cause = resolved.reason;
  }
  const passes = PASSING_STATES.includes(state);
  if (passes) {
    lines.push(`ACCEPTANCE — ${state} | ${cause}${planText} | ${gateLabel}`);
    for (const entry of flaky) lines.push(`ACCEPTANCE — flaky: ${entry}`);
  } else {
    const label = gate.mode === 'advisory' ? `${state} (advisory, not blocking)` : state;
    const suffix = remedies(state, rows, resolved.chain, options.projectRoot).map((entry) => ` | ${entry}`).join('');
    lines.push(`ACCEPTANCE — ${label} | ${cause}${planText} | ${gateLabel}${suffix}`);
  }
  return { state, passes: passes || gate.mode === 'advisory', mode: gate.mode, lines };
}

function readTransportFile(directory, name) {
  if (!directory) return null;
  try {
    return fs.readFileSync(path.join(directory, name), 'utf8');
  } catch {
    return null;
  }
}

function transportOptions(env) {
  const directory = env.ZENSU_AVR_DIR || '';
  return {
    pluginData: env.ZENSU_AVR_PLUGIN_DATA,
    sessionKey: env.ZENSU_AVR_SESSION_KEY,
    projectRoot: env.ZENSU_AVR_PROJECT_ROOT,
    receiptPath: env.ZENSU_AVR_RECEIPT || '',
    logPath: env.ZENSU_AVR_LOG || '',
    ac: env.ZENSU_AVR_AC,
    verdict: env.ZENSU_AVR_VERDICT,
    driver: env.ZENSU_AVR_DRIVER,
    evidenceRun: env.ZENSU_AVR_EVIDENCE_RUN || '',
    evidenceText: readTransportFile(directory, 'evidence'),
    gateMode: readTransportFile(directory, 'gate-mode'),
    escape: env.ZENSU_AVR_ESCAPE === '1',
    bound: env.ZENSU_AVR_BOUND === '1',
    validate: env.ZENSU_AVR_VALIDATE || '',
    editLandingEscaped: env.ZENSU_AVR_EDIT_LANDING_ESCAPED === '1',
    bashPath: env.ZENSU_AVR_BASH || 'bash',
    runLogLinePath: directory ? path.join(directory, 'run-log-line') : null,
    verdictStatePath: directory ? path.join(directory, 'verdict-state') : null,
  };
}

async function main(argv, env = process.env) {
  const mode = argv[0];
  const options = transportOptions(env);
  const label = env.ZENSU_AVR_LABEL || 'acceptance-verify-v1';
  if (mode === 'record') {
    const result = record(options);
    if (result.code !== 0) {
      process.stderr.write(`${label}: ${result.error}\n`);
      return result.code;
    }
    for (const line of result.disclosures) process.stderr.write(`${line}\n`);
    process.stdout.write(`zensu acceptance: ${result.line.replace(/^ACCEPTANCE — /, '')}\n`);
    if (options.runLogLinePath) {
      try {
        fs.writeFileSync(options.runLogLinePath, `${result.line}\n`, { mode: 0o600 });
      } catch { }
    }
    return 0;
  }
  if (mode === 'status') {
    const result = status(options);
    for (const line of result.lines) process.stdout.write(`${line}\n`);
    return result.code;
  }
  if (mode === 'verdict') {
    const result = verdict(options);
    for (const line of result.lines) process.stderr.write(`${line}\n`);
    if (options.verdictStatePath) {
      try { fs.writeFileSync(options.verdictStatePath, result.state); } catch { }
    }
    if (result.state === 'unavailable' && result.mode !== 'advisory') return 2;
    return result.passes ? 0 : 1;
  }
  process.stderr.write('usage: acceptance-verify-v1.js record|status|verdict\n');
  return 2;
}

module.exports = {
  SCHEMA,
  STORE_SEGMENTS,
  VERDICTS,
  ATTESTED_DRIVERS,
  OBSERVED_DRIVERS,
  DRIVERS,
  GATE_MODES,
  VERDICT_STATES,
  PASSING_STATES,
  CRITERION_STATES,
  VERIFY_AGAIN_STATES,
  RECORD_KEYS,
  LIMITS,
  REMEDY,
  AcceptanceError,
  newRecordId,
  storeLocations,
  validateRecord,
  writeRecordAtomic,
  listRecords,
  prune,
  sweepIdleSessions,
  criterionDigest,
  cleanEvidence,
  compareCriterionIds,
  resolveRunLog,
  receiptRunLog,
  planFor,
  readCriteria,
  hasChanges,
  citedRun,
  resolveChain,
  recordLine,
  record,
  evaluate,
  assess,
  status,
  normalizeGateMode,
  boundLine,
  remedies,
  verdict,
  main,
};

if (require.main === module) {
  main(process.argv.slice(2)).then((code) => {
    process.exitCode = code;
  }, (error) => {
    process.stderr.write(`acceptance-verify-v1: ${error && error.message ? error.message : String(error)}\n`);
    process.exitCode = 2;
  });
}
