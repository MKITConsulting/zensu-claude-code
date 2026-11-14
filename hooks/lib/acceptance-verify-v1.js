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
const planPayload = require('./plan-payload-v1.js');

const { canonical, resolveRunLog } = receipts;
const SCHEMA = 'acceptance-verify-v1';
const STORE_SEGMENTS = Object.freeze(['acceptance-verify', 'v1']);
const VERDICTS = Object.freeze(['pass', 'fail', 'partial']);
const ATTESTED_DRIVERS = Object.freeze(['browser', 'mobile', 'desktop']);
const OBSERVED_DRIVERS = Object.freeze(['api', 'cli', 'async', 'iac', 'custom', 'library']);
const DRIVERS = Object.freeze([...ATTESTED_DRIVERS, ...OBSERVED_DRIVERS]);
const EARLIER_ATTESTED_DRIVERS = Object.freeze(['desktop-native']);
const EARLIER_OBSERVED_DRIVERS = Object.freeze(['artifact']);
const ACCEPTED_DRIVERS = Object.freeze([...DRIVERS, ...EARLIER_ATTESTED_DRIVERS, ...EARLIER_OBSERVED_DRIVERS]);
const RECORDED_DRIVER_SPELLINGS = new Map([['desktop', 'desktop-native']]);
const GATE_MODES = Object.freeze(['required', 'advisory']);
const VERDICT_STATES = Object.freeze([
  'pass',
  'pass-tree-unverified',
  'not-applicable',
  'not-checked',
  'escaped',
  'partial-accepted',
  'incomplete',
  'no-criteria',
  'unresolved',
  'invalid',
  'unavailable',
]);
const PASSING_STATES = Object.freeze(['pass', 'pass-tree-unverified', 'not-applicable', 'not-checked', 'escaped', 'partial-accepted']);
const CRITERION_STATES = Object.freeze(['pass', 'fail', 'partial', 'stale', 'missing', 'deprecated', 'dropped']);
const VERIFY_AGAIN_STATES = Object.freeze(['missing', 'stale', 'partial']);
const STANDALONE_VERIFY_AGAIN_STATES = Object.freeze(['missing', 'stale']);
const HANDOFF_SCHEMA = 'acceptance-handoff-v1';
const HANDOFF_SEGMENTS = Object.freeze(['acceptance-handoff', 'v1']);
const HANDOFF_KEYS = Object.freeze(['open', 'plan', 'plan_sha256', 'records_sha256', 'remedies', 'schema', 'session_key', 'state', 'ticket', 'tree', 'written_at']);
const HANDOFF_STATES = Object.freeze(['incomplete', 'no-criteria']);
const USER_REMEDIES = Object.freeze(['accept', 'add', 'restore']);
const HANDOFF_PLAN_RE = /^\.zensu\/plans\/([A-Za-z0-9][A-Za-z0-9._-]{0,199})\.md$/;
const TICKET_RE = /^[A-Za-z0-9_-]{1,96}$/;
const ID_RE = /^av1_[0-9]{13}_[0-9a-f]{12}$/;
const RECORD_FILE_RE = /^av1_[0-9]{13}_[0-9a-f]{12}\.json$/;
const SESSION_KEY_RE = /^scv1_[0-9a-f]{64}$/;
const TREE_RE = /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/;
const DIGEST_RE = /^[0-9a-f]{64}$/;
const AC_RE = /^AC-([0-9]+)([a-z]?)$/;
const EVIDENCE_RUN_RE = /^er1_[0-9]{13}_[0-9a-f]{12}$/;
const STEM_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$/;
const RUN_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_.:-]{2,127}$/;
const ORDER_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const COMMIT_RE = /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/;
const RECORDED_HEAD_RE = /^[0-9a-fA-F]{7,64}$/;
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
  maxPlanBytes: 4 * 1024 * 1024,
  maxRemedyChars: 1000,
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

function isRunCopyStem(stem) {
  return typeof stem === 'string' && stem.startsWith(planPayload.APPROVED_PLAN_PREFIX);
}

function expectedPlanRel(stem) {
  if (isRunCopyStem(stem)) return planPayload.approvedPlanRelPath(stem.slice(planPayload.APPROVED_PLAN_PREFIX.length));
  return `.zensu/plans/${stem}.md`;
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
  if (record.plan !== expectedPlanRel(record.stem)) return 'malformed plan';
  if (typeof record.ac !== 'string' || !AC_RE.test(record.ac)) return 'malformed criterion id';
  if (typeof record.criterion !== 'string' || record.criterion.length > LIMITS.maxCriterionChars) return 'malformed criterion';
  if (typeof record.criterion_digest !== 'string' || !DIGEST_RE.test(record.criterion_digest)) return 'malformed criterion digest';
  if (!VERDICTS.includes(record.verdict)) return 'unknown verdict';
  if (!ACCEPTED_DRIVERS.includes(record.driver)) return 'unknown driver';
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

function hasChanges(root, limits = LIMITS, excluded = []) {
  const result = childProcess.spawnSync('git', ['-C', root, 'status', '--porcelain=v1', '-z', '--untracked-files=all', '--', '.', ':(exclude).zensu',
    ...excluded.map((entry) => `:(exclude,literal)${entry}`)], {
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

function chainTree(options, scratchDirectory) {
  if (typeof options.workTree !== 'string' || options.workTree === '') {
    if (options.runId) {
      const repository = evidenceRun.repositoryTree(options.projectRoot, scratchDirectory, evidenceRun.LIMITS);
      return { root: repository.root, tree: { tree: repository.tree, reason: repository.reason } };
    }
    return { root: options.projectRoot, tree: evidenceRun.computeTree(options.projectRoot, scratchDirectory, evidenceRun.LIMITS) };
  }
  const root = evidenceRun.fingerprintRoot(options.workTree, options.projectRoot, evidenceRun.LIMITS);
  return { root, tree: evidenceRun.computeFingerprint(options.projectRoot, root, scratchDirectory, evidenceRun.LIMITS) };
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

function runFacts(options) {
  const runId = options.runId;
  if (typeof runId !== 'string' || !RUN_ID_RE.test(runId)) return { error: '--run must name an Autopilot run id' };
  const label = `autopilot run ${runId}`;
  const run = options.run;
  if (!run || typeof run !== 'object' || Array.isArray(run)) {
    return { error: `the record of ${label} did not reach the acceptance check; run the verb again` };
  }
  if (run.runId !== runId) {
    return { error: `the run record handed to the acceptance check names run ${display(String(run.runId), options.projectRoot)}, not ${runId}` };
  }
  const validate = run.options && typeof run.options === 'object' ? run.options.validate : undefined;
  if (validate === false) return { error: `${label} was begun with --no-validate, so it has no acceptance criteria to verify` };
  if (validate !== true) return { error: `the record of ${label} carries no readable validate option` };
  const approved = run.approvedPlanSha256;
  if (approved === null || approved === undefined) return { error: `${label} records no approved plan, so it has no acceptance criteria to verify yet` };
  if (typeof approved !== 'string' || !DIGEST_RE.test(approved)) return { error: `the record of ${label} carries a malformed approved-plan digest` };
  let workOrder = null;
  if (run.workOrder !== undefined && run.workOrder !== null) {
    const order = run.workOrder;
    if (typeof order !== 'object' || Array.isArray(order) || typeof order.orderId !== 'string' || !ORDER_ID_RE.test(order.orderId)
      || typeof order.specHash !== 'string' || !DIGEST_RE.test(order.specHash)) {
      return { error: `the record of ${label} carries a malformed work-order binding` };
    }
    workOrder = { orderId: order.orderId, specHash: order.specHash };
  }
  const pr = run.evidence && typeof run.evidence === 'object' ? run.evidence.pr : null;
  const prHead = pr && typeof pr === 'object' && typeof pr.headSha === 'string' ? pr.headSha : null;
  return { runId, label, approved, workOrder, prHead };
}

function approvedPlanRefusal(facts, reason) {
  const copy = planPayload.approvedPlanRelPath(facts.approved);
  const failures = planPayload.APPROVED_PLAN_FAILURES;
  if (reason === failures.MISSING) {
    return `${facts.label} has no stored copy of the plan it approved (${copy}): the plan was approved before this release kept one, or the copy was removed, so its acceptance criteria cannot be read; report this refusal and leave the decision to the user`;
  }
  if (reason === failures.MISMATCH) {
    return `the stored copy ${copy} no longer matches the digest the run approved, so its acceptance criteria cannot be trusted; report this refusal and leave the decision to the user`;
  }
  if (reason === failures.STATE_DIRECTORY) {
    return `the project .zensu/state directory is a symlink or not a directory, so the approved plan of ${facts.label} cannot be read`;
  }
  return `the stored copy ${copy} of the plan ${facts.label} approved cannot be read (${reason})`;
}

function runChain(options) {
  const facts = runFacts(options);
  if (facts.error) return { error: facts.error };
  if (typeof options.projectRoot !== 'string' || options.projectRoot === '') return { error: 'no project root is bound' };
  const root = canonical(path.resolve(options.projectRoot));
  if (!facts.workOrder) {
    const copy = planPayload.readApprovedPlan(root, facts.approved);
    if (!copy.ok) return { error: approvedPlanRefusal(facts, copy.reason) };
    return { root, stem: copy.stem, planPath: copy.path, planRel: copy.rel, disclosures: [], runId: facts.runId, facts };
  }
  const stem = facts.workOrder.orderId;
  const plan = planFor(root, stem);
  if (plan.reason) return { error: plan.reason };
  const disclosures = [];
  if (facts.approved !== facts.workOrder.specHash) {
    const read = planPayload.readPlanFile(plan.planPath);
    if (read.failure) return { error: `the plan ${plan.planRel} of ${facts.label} cannot be read (${read.failure})` };
    if (crypto.createHash('sha256').update(read.bytes).digest('hex') !== facts.approved) {
      return {
        error: `the plan ${plan.planRel} no longer matches the plan a person approved for ${facts.label}, so its acceptance criteria cannot be trusted; restore the approved plan, or report this refusal and leave the decision to the user`,
      };
    }
  } else {
    disclosures.push(`ACCEPTANCE PLAN UNAPPROVED — work order ${stem} asks for no plan approval, so the criteria of ${facts.label} come from the session's own plan ${plan.planRel}, which no person approved`);
  }
  return { root, stem, planPath: plan.planPath, planRel: plan.planRel, disclosures, runId: facts.runId, facts };
}

function commitOf(root, revision, limits) {
  const result = childProcess.spawnSync('git', ['-C', root, 'rev-parse', '--verify', '--quiet', revision], {
    env: gitEnvironment(),
    encoding: 'utf8',
    timeout: limits.gitTimeoutMs,
    maxBuffer: 1024 * 1024,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error || result.status !== 0) return null;
  const value = String(result.stdout || '').trim().toLowerCase();
  return COMMIT_RE.test(value) ? value : null;
}

function runHead(root, prHead, limits = LIMITS, excluded = []) {
  if (typeof prHead !== 'string' || !RECORDED_HEAD_RE.test(prHead)) {
    return { reason: 'the run records no pull-request head, so there is no commit to validate' };
  }
  const head = commitOf(root, 'HEAD', limits);
  if (!head) return { reason: 'the HEAD commit of the work tree could not be read, so it cannot be compared with the pull-request head' };
  const pr = commitOf(root, `${prHead.toLowerCase()}^{commit}`, limits);
  if (!pr) return { reason: `the pull-request head ${prHead.slice(0, 12).toLowerCase()} is not a commit in the work tree; fetch it, then validate again` };
  if (pr !== head) {
    return {
      reason: `HEAD of the work tree is ${head.slice(0, 12)}, not the pull-request head ${pr.slice(0, 12)}; check out ${pr.slice(0, 12)}, or send the newer commit through the fix loop with VALIDATION_FAILED: once its fix attempt is back, push it and record PR_HEAD_UPDATED, then FINDINGS_CLEARED on the new head returns the run to VALIDATE`,
    };
  }
  const changes = hasChanges(root, limits, excluded);
  if (!changes.known) return { reason: 'git status failed in the work tree, so whether it is clean is unknown' };
  if (changes.changed) {
    return {
      reason: `the work tree has uncommitted changes, so it is not the pull-request head ${pr.slice(0, 12)}; discard them, or send them through the fix loop with VALIDATION_FAILED: once its fix attempt is back, push them and record PR_HEAD_UPDATED, then FINDINGS_CLEARED on the new head returns the run to VALIDATE`,
    };
  }
  return { head };
}

function workTreeRefusal(options, limits = LIMITS) {
  const fault = evidenceRun.workTreeFaultCause(options.workTreeFault);
  if (fault === null) return null;
  return `the chain's work tree could not be determined, so no acceptance record can be bound to it: ${display(fault, options.projectRoot, limits)}`;
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
  if (!ACCEPTED_DRIVERS.includes(options.driver)) return { code: 2, error: `--driver must be one of ${DRIVERS.join(', ')}` };
  if (options.runId && options.logPath) {
    return { code: 2, error: '--log and --run name two different anchors; pass --run for an Autopilot run and --log for a standalone chain' };
  }
  if (!options.logPath && !options.runId) return { code: 2, error: '--log <this chain\'s run log> is required' };
  const refusal = workTreeRefusal(options, limits);
  if (refusal) return { code: 2, error: refusal };
  const evidence = cleanEvidence(options.evidenceText, options.projectRoot, limits);
  if (evidence.error) return { code: 1, error: evidence.error };
  const chain = options.runId ? runChain(options) : resolveChain(options);
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
  const currentTree = chainTree(options, locations.scratch).tree;
  const runId = typeof options.evidenceRun === 'string' && options.evidenceRun !== '' ? options.evidenceRun : null;
  const observed = OBSERVED_DRIVERS.includes(options.driver) || EARLIER_OBSERVED_DRIVERS.includes(options.driver);
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
    driver: RECORDED_DRIVER_SPELLINGS.get(options.driver) || options.driver,
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

function evaluate(criteria, entries, currentTree, projectRoot, limits = LIMITS, treeRoot = projectRoot) {
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
      const paths = last.tree ? evidenceRun.fingerprintChanges(projectRoot, treeRoot, last.tree, currentTree.tree, { ...evidenceRun.LIMITS, listedPaths: limits.listedPaths }) : null;
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
  const current = chainTree(options, locations.scratch);
  const rows = evaluate(criteria.criteria, valid, current.tree, options.projectRoot, limits, current.root);
  return { outcome: 'evaluated', rows, currentTree: current.tree, chain };
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

function describeRow(row, projectRoot, limits = LIMITS, withEvidence = false) {
  const id = row.criterion.id;
  const text = display(row.criterion.text, projectRoot, limits);
  if (row.state === 'missing' || row.state === 'deprecated') return `${id} ${row.state} | ${text}`;
  const cause = row.cause ? ` (${row.cause})` : '';
  const how = row.record
    ? ` | ${row.record.driver} ${row.record.evidence_run ? `observed ${row.record.evidence_run}` : 'attested'} | record ${row.record.id}`
    : '';
  const evidence = withEvidence && row.record ? ` | evidence: ${display(row.record.evidence, projectRoot, limits)}` : '';
  const unverified = row.treeUnverified ? ' (tree unverified)' : '';
  return `${id} ${row.state}${cause}${unverified}${how}${evidence} | ${text}`;
}

function status(options) {
  const limits = limitsWith(options.limits);
  const refusal = workTreeRefusal(options, limits);
  if (refusal) return { code: 2, lines: [`ACCEPTANCE STATUS — unavailable | ${refusal}`] };
  const chain = options.runId ? runChain(options) : resolveChain(options);
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
  const suffix = complete ? '' : remedies('incomplete', result.rows, chain, options.projectRoot, { currentTree: result.currentTree, zeroChangeTicket: options.zeroChangeTicket === true }).map((entry) => ` | ${entry}`).join('');
  const anchor = chain.runId ? `autopilot run ${chain.runId} | ` : '';
  const lines = [...chain.disclosures, `ACCEPTANCE STATUS — ${anchor}plan: ${chain.planRel} | tree: ${tree} | ${passing}/${active.length} active criteria pass${blocking > 0 ? ` | ${blocking} dropped` : ''}${suffix}`];
  for (const row of result.rows) lines.push(describeRow(row, options.projectRoot, limits, Boolean(chain.runId)));
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
    const newest = entries.filter((entry) => entry.record && !isRunCopyStem(entry.record.stem)).pop();
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

function runRemedies(state, rows, runId) {
  if (state === 'no-criteria') {
    return ['add: the approved plan carries no active AC-### criterion, so this run cannot validate; report this refusal and leave the decision to the user'];
  }
  const verify = `run: drive each criterion that does not pass again on this tree and record it with zensu-log.sh --acceptance-record --run ${runId}`;
  if (state === 'invalid') return [verify];
  if (state !== 'incomplete') return [];
  const found = new Set(rows.map((row) => row.state));
  const listed = [];
  if (VERIFY_AGAIN_STATES.some((entry) => found.has(entry))) listed.push(verify);
  if (found.has('fail')) {
    listed.push(`fix: a criterion that fails on this tree needs a code change; send VALIDATION_FAILED for autopilot run ${runId} so the run returns to its fix loop`);
  }
  if (found.has('dropped')) listed.push('restore: a dropped criterion needs a pass, or report this refusal and leave the decision to the user');
  const open = rows.filter((row) => row.state !== 'pass' && row.state !== 'deprecated');
  if (open.length > 0 && open.every((row) => row.state === 'partial')) {
    listed.push(`accept: every criterion that does not pass is partial, so zensu-log.sh --autopilot-validate --run ${runId} --accept-partial records the gap in the run's ledger and validates the run`);
  }
  return listed;
}

function openRows(rows) {
  return rows.filter((row) => row.state !== 'pass' && row.state !== 'deprecated');
}

const REVIEWED_CHAIN_ONLY = 'closes only a chain whose review ticket a reviewer consumed';
const ACCEPT_CONTEXT_REFUSALS = new Map([
  ['standalone', ''],
  ['bound', 'refusing --accept-partial — it belongs to the ticket-bound standalone terminus and takes no Autopilot binding and no --outcome; an Autopilot run checks its criteria in its VALIDATE stage. The chain stays open.'],
  ['unticketed', `refusing --accept-partial on the zero-change terminus — consent to a partial criterion ${REVIEWED_CHAIN_ONLY}, so pass it with --claimed-review-ticket <the consumed review ticket>. The chain stays open.`],
  ['zero-change', `refusing --accept-partial on the zero-change terminus — consent to a partial criterion ${REVIEWED_CHAIN_ONLY}, and no reviewer consumed this zero-change self-review ticket; report the refusal and leave the decision to the user. The chain stays open.`],
]);
const UNJUDGED_NEXT_STEP = 'Check the plan path and run /zensu:doctor; if the plan still cannot be read, report this refusal and leave the decision to the user.';

function partialRemedy(ids, projectRoot, context) {
  const named = ids.join(', ');
  if (context.zeroChangeTicket === true) {
    return `review: ${named} could not be observed in this environment, and consent to a partial criterion ${REVIEWED_CHAIN_ONLY}, which this zero-change self-review ticket is not; report the refusal and leave the decision to the user`;
  }
  if (context.currentTree && !context.currentTree.tree) {
    return `tree: ${named} could not be observed in this environment, and consent binds to a tree the gate can fingerprint, which this one is not (${display(context.currentTree.reason || 'no tree id', projectRoot)}); report the refusal and leave the decision to the user`;
  }
  return `accept: ${named} could not be observed in this environment; they close only with the user's consent for exactly these criteria, from one of the two sources the plugin's skills/verify-feature/rules/acceptance-consent.md names, so once each has its ## Manual Acceptance row in the plan, add --accept-partial ${ids.join(',')} to the same --chain-done call`;
}

function remedies(state, rows, chain, projectRoot, context = {}) {
  if (chain && chain.runId) return runRemedies(state, rows, chain.runId);
  if (state === 'no-criteria') {
    return ['add: give the plan\'s ## Requirements table an active AC-### criterion this environment can observe, or leave the refusal to the user'];
  }
  if (state === 'invalid') return [verifyRemedy(chain, projectRoot)];
  if (state !== 'incomplete') return [];
  const found = new Set(rows.map((row) => row.state));
  const listed = [];
  if (STANDALONE_VERIFY_AGAIN_STATES.some((entry) => found.has(entry))) listed.push(verifyRemedy(chain, projectRoot));
  if (found.has('fail')) {
    listed.push('fix: a criterion that fails on this tree needs a code change before it is verified again; without one, leave the refusal to the user');
  }
  if (found.has('dropped')) {
    listed.push('restore: a dropped criterion needs its row restored or un-deprecated and a pass, or leave the refusal to the user');
  }
  const open = openRows(rows);
  if (open.length > 0 && open.every((row) => row.state === 'partial')) {
    listed.push(partialRemedy(open.map((row) => row.criterion.id), projectRoot, context || {}));
  }
  return listed;
}

function remedyKind(segment) {
  const colon = typeof segment === 'string' ? segment.indexOf(':') : -1;
  return colon > 0 ? segment.slice(0, colon) : '';
}

function isHandoff(state, segments, fixRoundSpent) {
  if (!HANDOFF_STATES.includes(state) || segments.length === 0) return false;
  return segments.every((segment) => {
    const kind = remedyKind(segment);
    return USER_REMEDIES.includes(kind) || (kind === 'fix' && fixRoundSpent === true);
  });
}

function parseAcceptIds(text) {
  if (typeof text !== 'string' || text === '') return { ids: [] };
  const ids = [];
  for (const part of text.split(',')) {
    const id = part.trim();
    if (!AC_RE.test(id)) {
      return { error: `--accept-partial takes a comma-separated list of acceptance criterion ids such as AC-004,AC-005, and ${JSON.stringify(clip(part, 40))} is not one` };
    }
    if (!ids.includes(id)) ids.push(id);
  }
  return { ids: ids.sort(compareCriterionIds) };
}

function acceptOpenRows(ids, open) {
  const openIds = open.map((row) => row.criterion.id);
  const problems = [];
  const notPartial = open.filter((row) => row.state !== 'partial').map((row) => `${row.criterion.id} ${row.state}`);
  if (notPartial.length > 0) problems.push(`--accept-partial covers only partial criteria, not ${notPartial.join(', ')}`);
  const notOpen = ids.filter((id) => !openIds.includes(id));
  if (notOpen.length > 0) problems.push(`--accept-partial names ${notOpen.join(', ')}, which ${notOpen.length === 1 ? 'is' : 'are'} not open`);
  const unlisted = openIds.filter((id) => !ids.includes(id));
  if (unlisted.length > 0) problems.push(`--accept-partial leaves ${unlisted.join(', ')} open`);
  return problems.length === 0 ? { accepted: true } : { accepted: false, refusal: problems.join('; ') };
}

function handoffDirectory(pluginData) {
  try {
    return ensurePrivateDirectory(pluginData, HANDOFF_SEGMENTS);
  } catch (error) {
    return fail(`acceptance hand-off store unavailable: ${error.message}`);
  }
}

function handoffFile(pluginData, sessionKey) {
  if (typeof sessionKey !== 'string' || !SESSION_KEY_RE.test(sessionKey)) fail('invalid session key');
  return path.join(handoffDirectory(pluginData), `${sessionKey}.json`);
}

function validateHandoff(record, sessionKey) {
  if (!record || typeof record !== 'object' || Array.isArray(record)) return 'not an object';
  const keys = Object.keys(record).sort();
  if (keys.length !== HANDOFF_KEYS.length || keys.some((key, index) => key !== HANDOFF_KEYS[index])) return 'unexpected key set';
  if (record.schema !== HANDOFF_SCHEMA) return 'unknown schema';
  if (record.session_key !== sessionKey) return 'bound to another session';
  if (typeof record.ticket !== 'string' || !TICKET_RE.test(record.ticket)) return 'malformed review ticket';
  if (typeof record.tree !== 'string' || !TREE_RE.test(record.tree)) return 'malformed tree';
  if (!HANDOFF_STATES.includes(record.state)) return 'unknown verdict state';
  if (typeof record.plan !== 'string' || !HANDOFF_PLAN_RE.test(record.plan)) return 'malformed plan';
  if (typeof record.plan_sha256 !== 'string' || !DIGEST_RE.test(record.plan_sha256)) return 'malformed plan digest';
  if (typeof record.records_sha256 !== 'string' || !DIGEST_RE.test(record.records_sha256)) return 'malformed record-set digest';
  if (!Array.isArray(record.open) || record.open.length > LIMITS.maxRecordsPerSession
    || record.open.some((id) => typeof id !== 'string' || !AC_RE.test(id))) {
    return 'malformed open criteria';
  }
  if (!Array.isArray(record.remedies) || record.remedies.length === 0 || record.remedies.length > 8
    || record.remedies.some((segment) => typeof segment !== 'string' || segment.length > LIMITS.maxRemedyChars || /[\u0000-\u001f\u007f]/.test(segment)
      || !(USER_REMEDIES.includes(remedyKind(segment)) || remedyKind(segment) === 'fix'))) {
    return 'malformed remedies';
  }
  if (!isIsoTimestamp(record.written_at)) return 'malformed record time';
  return null;
}

function fileDigest(filePath, maxBytes) {
  let descriptor;
  try {
    const before = fs.lstatSync(filePath);
    if (before.isSymbolicLink() || !before.isFile()) return null;
    const noFollow = process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW) ? fs.constants.O_NOFOLLOW : 0;
    descriptor = fs.openSync(filePath, fs.constants.O_RDONLY | noFollow | (fs.constants.O_NONBLOCK || 0));
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile() || stat.dev !== before.dev || stat.ino !== before.ino || stat.size > maxBytes) return null;
    const buffer = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < stat.size) {
      const read = fs.readSync(descriptor, buffer, offset, stat.size - offset, offset);
      if (read === 0) break;
      offset += read;
    }
    return crypto.createHash('sha256').update(buffer.subarray(0, offset)).digest('hex');
  } catch {
    return null;
  } finally {
    if (descriptor !== undefined) {
      try { fs.closeSync(descriptor); } catch { }
    }
  }
}

function recordSetDigest(options, stem) {
  const entries = listRecords(storeLocations(options.pluginData, options.sessionKey), { sessionKey: options.sessionKey, projectRoot: options.projectRoot });
  const hash = crypto.createHash('sha256');
  for (const entry of entries) {
    if (entry.record && entry.record.stem !== stem) continue;
    hash.update(`${entry.id}\n${entry.record ? JSON.stringify(entry.record) : `invalid ${entry.invalid}`}\n`);
  }
  return hash.digest('hex');
}

function handoffEvidence(options, stem) {
  const plan = planFor(canonical(path.resolve(options.projectRoot)), stem);
  if (plan.reason) return { reason: plan.reason };
  const planDigest = fileDigest(plan.planPath, LIMITS.maxPlanBytes);
  if (!planDigest) return { reason: `the plan ${plan.planRel} could not be read` };
  return { plan: plan.planRel, plan_sha256: planDigest, records_sha256: recordSetDigest(options, stem) };
}

function writeHandoff(options, record) {
  const target = handoffFile(options.pluginData, options.sessionKey);
  const problem = validateHandoff(record, options.sessionKey);
  if (problem) fail(`refusing to write an invalid hand-off record: ${problem}`);
  const directory = path.dirname(target);
  const temporary = path.join(directory, `.${options.sessionKey}.${crypto.randomBytes(6).toString('hex')}.tmp`);
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

function removeHandoff(options) {
  try {
    fs.rmSync(handoffFile(options.pluginData, options.sessionKey), { force: true });
  } catch { }
}

function handoffLine(record, projectRoot) {
  const open = record.open.length > 0 ? record.open.join(', ') : 'none';
  const shown = record.remedies.map((segment) => display(segment, projectRoot, { ...LIMITS, displayMax: LIMITS.maxRemedyChars }));
  return `ACCEPTANCE HAND-OFF — the chain stays open, waiting on the user's acceptance decision | ${record.state} | open: ${open} | ${shown.join(' | ')} | review ticket ${record.ticket} | tree ${record.tree.slice(0, 12)}`;
}

function recordHandoff(options, result) {
  if (typeof options.handoffTicket !== 'string' || options.handoffTicket === '') return;
  const tree = result.currentTree && result.currentTree.tree;
  if (!result.handoff || options.gatesPassed !== true || options.reviewDone !== true || !tree || !result.chain || !TICKET_RE.test(options.handoffTicket)) {
    removeHandoff(options);
    return;
  }
  try {
    const evidence = handoffEvidence(options, result.chain.stem);
    if (evidence.reason) {
      removeHandoff(options);
      return;
    }
    writeHandoff(options, {
      schema: HANDOFF_SCHEMA,
      session_key: options.sessionKey,
      ticket: options.handoffTicket,
      tree,
      plan: evidence.plan,
      plan_sha256: evidence.plan_sha256,
      records_sha256: evidence.records_sha256,
      state: result.state,
      open: openRows(result.rows || []).map((row) => row.criterion.id),
      remedies: result.segments,
      written_at: new Date().toISOString(),
    });
  } catch {
    removeHandoff(options);
  }
}

function handoffStatus(options) {
  if (typeof options.sessionKey !== 'string' || !SESSION_KEY_RE.test(options.sessionKey)) return { code: 2, reason: 'invalid session key' };
  if (typeof options.handoffTicket !== 'string' || !TICKET_RE.test(options.handoffTicket)) {
    return { code: 1, reason: 'the chain holds no consumed review ticket' };
  }
  if (typeof options.projectRoot !== 'string' || options.projectRoot === '') return { code: 2, reason: 'no project root is bound' };
  let file;
  let locations;
  try {
    file = handoffFile(options.pluginData, options.sessionKey);
    locations = storeLocations(options.pluginData, options.sessionKey);
  } catch (error) {
    return { code: 2, reason: error.message };
  }
  const loaded = evidenceRun.readRecordFile(file, LIMITS);
  if (loaded.invalid) return { code: 1, reason: loaded.invalid };
  const problem = validateHandoff(loaded.record, options.sessionKey);
  if (problem) return { code: 1, reason: problem };
  if (loaded.record.ticket !== options.handoffTicket) return { code: 1, reason: 'the hand-off names another review ticket' };
  const current = chainTree({ ...options, runId: '', workTree: '' }, locations.scratch);
  if (!current.tree.tree || current.tree.tree !== loaded.record.tree) return { code: 1, reason: 'the tree changed since the terminus refused' };
  let evidence;
  try {
    evidence = handoffEvidence(options, HANDOFF_PLAN_RE.exec(loaded.record.plan)[1]);
  } catch (error) {
    return { code: 1, reason: error.message };
  }
  if (evidence.reason) return { code: 1, reason: evidence.reason };
  if (evidence.plan !== loaded.record.plan || evidence.plan_sha256 !== loaded.record.plan_sha256) {
    return { code: 1, reason: 'the plan changed since the terminus refused' };
  }
  if (evidence.records_sha256 !== loaded.record.records_sha256) return { code: 1, reason: 'the acceptance records changed since the terminus refused' };
  return { code: 0, line: handoffLine(loaded.record, options.projectRoot) };
}

function unjudgedCriteria(options, cause) {
  if (options.criteriaAdvisory === true) {
    return { code: 0, lines: [`ACCEPTANCE CRITERIA — advisory, not blocking | ${cause}, so the plan was NOT judged`] };
  }
  return { code: 2, lines: [cause] };
}

function planCriteria(options) {
  const planPath = typeof options.planPath === 'string' ? options.planPath : '';
  if (planPath === '') return unjudgedCriteria(options, 'the plan path did not reach the acceptance check');
  const relative = options.projectRoot ? path.relative(options.projectRoot, planPath) : '';
  const shown = display(relative && !relative.startsWith('..') && !path.isAbsolute(relative) ? relative : planPath, options.projectRoot);
  const read = readCriteria(planPath, options);
  if (read.status === 'error') return unjudgedCriteria(options, `the acceptance criteria of ${shown} could not be read: ${read.reason}`);
  if (read.status === 'ok' && read.criteria.some((criterion) => criterion.state === 'active')) return { code: 0, lines: [] };
  const cause = read.status !== 'ok'
    ? read.reason
    : (read.criteria.length === 0 ? 'its ## Requirements table has no AC-### row' : 'every AC-### row is deprecated');
  if (options.criteriaAdvisory === true) {
    return {
      code: 0,
      lines: [`ACCEPTANCE CRITERIA — advisory, not blocking | the plan ${shown} carries no active AC-### acceptance criterion (${cause}), so the chain terminus will report no-criteria after the review without blocking it`],
    };
  }
  return {
    code: 1,
    lines: [
      `the plan ${shown} carries no active AC-### acceptance criterion (${cause}), so the chain terminus would refuse it as no-criteria after the review`,
      'Add one AC-### row to the plan\'s ## Requirements table for each acceptance criterion, then run --tdd-complete again. Prefer criteria this environment can observe (a test, a command or a page a verification driver reaches); a criterion only a person can check is an active AC-### row too, and with the user\'s consent it also gets a row in the plan\'s ## Manual Acceptance table.',
    ],
  };
}

function runOutcome(options, chain, limits) {
  const bound = typeof options.workTree === 'string' && options.workTree !== '';
  const repository = bound ? { root: options.workTree, excluded: [], reason: null } : evidenceRun.repositoryRoot(options.projectRoot, evidenceRun.LIMITS);
  if (repository.root === null) {
    return {
      state: 'unresolved',
      cause: `${chain.facts.label}: the repository of the project root could not be determined (${display(repository.reason || 'no reason', options.projectRoot, limits)}), so the pull-request head cannot be checked`,
      rows: [],
    };
  }
  const head = runHead(repository.root, chain.facts.prHead, limits, repository.excluded);
  if (head.reason) return { state: 'unresolved', cause: `${chain.facts.label}: ${head.reason}`, rows: [] };
  const result = assess({ ...options, chain });
  if (result.outcome !== 'evaluated') return { state: result.outcome, cause: result.reason, rows: [] };
  if (!result.currentTree.tree) {
    return {
      state: 'unresolved',
      cause: `${chain.facts.label}: the work tree could not be fingerprinted (${result.currentTree.reason || 'no tree id'}), so no record can be matched to the pull-request head`,
      rows: [],
    };
  }
  const rows = result.rows;
  const active = rows.filter((row) => row.criterion.state === 'active');
  const passing = active.filter((row) => row.state === 'pass').length;
  const open = rows.filter((row) => row.state !== 'pass' && row.state !== 'deprecated');
  const deprecated = rows.filter((row) => row.state === 'deprecated').map((row) => row.criterion.id);
  const deprecatedText = deprecated.length > 0 ? `; deprecated: ${deprecated.join(', ')}` : '';
  const where = `${chain.facts.label}: ${passing}/${active.length} acceptance criteria pass on the pull-request head ${head.head.slice(0, 12)}`;
  if (open.length === 0) {
    const kinds = countKinds(rows);
    const flaky = rows.filter((row) => row.earlierNonPass > 0).map((row) => `${row.criterion.id} had ${row.earlierNonPass} earlier non-pass verdict(s) on this same tree`);
    return { state: 'pass', cause: `${where} (observed ${kinds.observed}, attested ${kinds.attested})${deprecatedText}`, rows, flaky };
  }
  if (options.acceptPartial && open.every((row) => row.state === 'partial')) {
    return { state: 'partial-accepted', cause: `${where}; accepted as partial: ${open.map((row) => row.criterion.id).join(', ')}${deprecatedText}`, rows };
  }
  const listed = open.map((row, index) => `${row.criterion.id} ${row.state}${row.cause && index < limits.listedCriteria ? ` (${row.cause})` : ''}`);
  const refusedAccept = options.acceptPartial ? '; --accept-partial covers only partial criteria' : '';
  return { state: 'incomplete', cause: `${where}; ${listed.join('; ')}${deprecatedText}${refusedAccept}`, rows };
}

function runVerdict(options, gate, lines, limits) {
  const gateLabel = `gate: ${gate.mode}`;
  if (options.escape) {
    lines.push(`ACCEPTANCE — escaped | ZENSU_ACCEPTANCE_GATE=off switched this check off, so no acceptance record of autopilot run ${options.runId} was read | ${gateLabel}`);
    return { state: 'escaped', passes: true, mode: gate.mode, lines };
  }
  let outcome;
  let chain = null;
  let planText = '';
  const refusal = workTreeRefusal(options, limits);
  if (refusal) {
    outcome = { state: 'unavailable', cause: refusal, rows: [] };
  } else {
    const resolved = runChain(options);
    if (resolved.error) {
      outcome = { state: 'unresolved', cause: resolved.error, rows: [] };
    } else {
      chain = resolved;
      lines.push(...chain.disclosures);
      planText = ` | plan: ${chain.planRel}`;
      outcome = runOutcome(options, chain, limits);
    }
  }
  const passes = PASSING_STATES.includes(outcome.state);
  if (passes) {
    lines.push(`ACCEPTANCE — ${outcome.state} | ${outcome.cause}${planText} | ${gateLabel}`);
    for (const entry of outcome.flaky || []) lines.push(`ACCEPTANCE — flaky: ${entry}`);
  } else {
    const label = gate.mode === 'advisory' ? `${outcome.state} (advisory, not blocking)` : outcome.state;
    const suffix = runRemedies(outcome.state, outcome.rows, options.runId).map((entry) => ` | ${entry}`).join('');
    lines.push(`ACCEPTANCE — ${label} | ${outcome.cause}${planText} | ${gateLabel}${suffix}`);
  }
  return { state: outcome.state, passes: passes || gate.mode === 'advisory', mode: gate.mode, lines };
}

function verdict(options) {
  const limits = limitsWith(options.limits);
  const gate = normalizeGateMode(options.gateMode, options.projectRoot);
  const lines = [];
  if (gate.disclosure) lines.push(gate.disclosure);
  if (options.runId) return runVerdict(options, gate, lines, limits);
  if (options.bound) {
    lines.push(boundLine(options.validate));
    return { state: 'not-checked', passes: true, mode: gate.mode, lines };
  }
  const result = standaloneVerdict(options, gate, lines, limits);
  recordHandoff(options, result);
  return result;
}

function standaloneVerdict(options, gate, lines, limits) {
  const gateLabel = `gate: ${gate.mode}`;
  const resolved = verdictChain(options);
  if (resolved.outcome === 'not-applicable') {
    lines.push(`ACCEPTANCE — not-applicable | ${resolved.reason} | ${gateLabel}`);
    return { state: 'not-applicable', passes: true, mode: gate.mode, lines };
  }
  if (options.escape) {
    lines.push(`ACCEPTANCE — escaped | ZENSU_ACCEPTANCE_GATE=off switched this check off, so no acceptance record was read | ${gateLabel}`);
    return { state: 'escaped', passes: true, mode: gate.mode, lines };
  }
  const accept = parseAcceptIds(options.acceptPartialIds);
  let state;
  let cause;
  let planText = '';
  let flaky = [];
  let rows = [];
  let accepted = [];
  let currentTree = null;
  if (resolved.chain) {
    lines.push(...resolved.chain.disclosures);
    planText = ` | plan: ${resolved.chain.planRel}`;
    const result = assess({ ...options, chain: resolved.chain });
    if (result.outcome === 'evaluated') {
      rows = result.rows;
      currentTree = result.currentTree;
      const active = result.rows.filter((row) => row.criterion.state === 'active');
      const deprecated = result.rows.filter((row) => row.state === 'deprecated').map((row) => row.criterion.id);
      const failing = openRows(result.rows);
      const passing = active.filter((row) => row.state === 'pass').length;
      const tree = result.currentTree.tree ? `the current tree ${result.currentTree.tree.slice(0, 12)}` : `a tree that could not be fingerprinted (${result.currentTree.reason || 'no tree id'})`;
      const deprecatedText = deprecated.length > 0 ? `; deprecated: ${deprecated.join(', ')}` : '';
      if (failing.length === 0 && (accept.error || accept.ids.length > 0)) {
        state = 'incomplete';
        const refusal = accept.error || `${acceptOpenRows(accept.ids, []).refusal}: every criterion passes, so run --chain-done again without --accept-partial`;
        cause = `${passing}/${active.length} acceptance criteria pass on ${tree}${deprecatedText}; ${refusal}`;
      } else if (failing.length === 0) {
        const kinds = countKinds(result.rows);
        state = result.currentTree.tree ? 'pass' : 'pass-tree-unverified';
        cause = `${passing}/${active.length} acceptance criteria pass on ${tree} (observed ${kinds.observed}, attested ${kinds.attested})${deprecatedText}`;
        flaky = result.rows.filter((row) => row.earlierNonPass > 0).map((row) => `${row.criterion.id} had ${row.earlierNonPass} earlier non-pass verdict(s) on this same tree`);
      } else {
        let decision = null;
        if (accept.error) {
          decision = { accepted: false, refusal: accept.error };
        } else if (accept.ids.length > 0 && options.zeroChangeTicket === true) {
          decision = { accepted: false, refusal: `--accept-partial ${REVIEWED_CHAIN_ONLY}, which this zero-change self-review ticket is not` };
        } else if (accept.ids.length > 0) {
          decision = result.currentTree.tree
            ? acceptOpenRows(accept.ids, failing)
            : { accepted: false, refusal: '--accept-partial needs a tree the gate can fingerprint, and this one could not be fingerprinted' };
        }
        if (decision && decision.accepted) {
          state = 'partial-accepted';
          accepted = failing;
          cause = `${passing}/${active.length} acceptance criteria pass on ${tree}; accepted as partial: ${failing.map((row) => row.criterion.id).join(', ')}${deprecatedText}`;
        } else {
          state = 'incomplete';
          const listed = failing.map((row, index) => `${row.criterion.id} ${row.state}${row.cause && index < limits.listedCriteria ? ` (${row.cause})` : ''}`);
          cause = `${passing}/${active.length} acceptance criteria pass on ${tree}; ${listed.join('; ')}${deprecatedText}${decision ? `; ${decision.refusal}` : ''}`;
        }
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
  const zeroChangeTicket = options.zeroChangeTicket === true;
  let segments = [];
  if (passes) {
    lines.push(`ACCEPTANCE — ${state} | ${cause}${planText} | ${gateLabel}`);
    for (const entry of flaky) lines.push(`ACCEPTANCE — flaky: ${entry}`);
    for (const row of accepted) lines.push(`ACCEPTANCE — accepted as partial: ${describeRow(row, options.projectRoot, limits, true)}`);
  } else {
    const label = gate.mode === 'advisory' ? `${state} (advisory, not blocking)` : state;
    segments = remedies(state, rows, resolved.chain, options.projectRoot, { currentTree, zeroChangeTicket });
    const suffix = segments.map((entry) => ` | ${entry}`).join('');
    lines.push(`ACCEPTANCE — ${label} | ${cause}${planText} | ${gateLabel}${suffix}`);
  }
  const handoff = !passes && gate.mode !== 'advisory' && !zeroChangeTicket && isHandoff(state, segments, options.fixRoundSpent === true);
  if (handoff && !currentTree && options.handoffTicket) {
    try {
      currentTree = chainTree({ ...options, runId: '', workTree: '' }, storeLocations(options.pluginData, options.sessionKey).scratch).tree;
    } catch {
      currentTree = null;
    }
  }
  return { state, passes: passes || gate.mode === 'advisory', mode: gate.mode, lines, rows, segments, currentTree, handoff, chain: resolved.chain || null };
}

function readTransportFile(directory, name) {
  if (!directory) return null;
  try {
    return fs.readFileSync(path.join(directory, name), 'utf8');
  } catch {
    return null;
  }
}

function readRunTransport(directory) {
  const text = readTransportFile(directory, 'run.json');
  if (text === null) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function transportOptions(env) {
  const directory = env.ZENSU_AVR_DIR || '';
  return {
    runId: env.ZENSU_AVR_RUN || '',
    run: readRunTransport(directory),
    acceptPartial: env.ZENSU_AVR_ACCEPT_PARTIAL === '1',
    acceptPartialIds: env.ZENSU_AVR_ACCEPT_PARTIAL_IDS || '',
    acceptContext: env.ZENSU_AVR_ACCEPT_CONTEXT || 'standalone',
    handoffTicket: env.ZENSU_AVR_HANDOFF_TICKET || '',
    gatesPassed: env.ZENSU_AVR_GATES_PASSED === '1',
    fixRoundSpent: env.ZENSU_AVR_FIX_ROUND_SPENT === '1',
    reviewDone: env.ZENSU_AVR_REVIEW_DONE === '1',
    zeroChangeTicket: env.ZENSU_AVR_ZERO_CHANGE_TICKET === '1',
    criteriaAdvisory: env.ZENSU_AVR_CRITERIA_ADVISORY === '1',
    planPath: env.ZENSU_AVR_PLAN || '',
    pluginData: env.ZENSU_AVR_PLUGIN_DATA,
    sessionKey: env.ZENSU_AVR_SESSION_KEY,
    projectRoot: env.ZENSU_AVR_PROJECT_ROOT,
    workTree: env.ZENSU_AVR_WORK_TREE || '',
    workTreeFault: evidenceRun.readWorkTreeFault(directory),
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
  if (mode === 'accept-ids') {
    if (!ACCEPT_CONTEXT_REFUSALS.has(options.acceptContext)) {
      process.stderr.write(`${label}: --accept-partial reached the acceptance module with the unknown context ${JSON.stringify(options.acceptContext)}\n`);
      return 2;
    }
    const refusal = ACCEPT_CONTEXT_REFUSALS.get(options.acceptContext);
    if (refusal) {
      process.stderr.write(`${label}: ${refusal}\n`);
      return 1;
    }
    const parsed = parseAcceptIds(options.acceptPartialIds);
    if (!parsed.error && parsed.ids.length === 0) parsed.error = '--accept-partial needs the ids of the criteria the user accepted as partial, such as AC-004,AC-005';
    if (parsed.error) {
      process.stderr.write(`${label}: ${parsed.error}\n`);
      return 2;
    }
    process.stdout.write(`${parsed.ids.join(',')}\n`);
    return 0;
  }
  if (mode === 'handoff') {
    const result = handoffStatus(options);
    if (result.code === 0) process.stdout.write(`${result.line}\n`);
    if (result.code === 2) process.stderr.write(`${label}: ${result.reason}\n`);
    return result.code;
  }
  if (mode === 'plan-criteria') {
    const result = planCriteria(options);
    if (result.code === 0) {
      for (const line of result.lines) process.stderr.write(`${line}\n`);
    } else if (result.code === 1) {
      process.stderr.write(`${label}: refusing to mark implementation complete — ${result.lines[0]}.\n${result.lines.slice(1).join('\n')}\n`);
    } else if (result.code === 2) {
      process.stderr.write(`${label}: ${result.lines[0]}, so the plan was NOT judged.\n${UNJUDGED_NEXT_STEP}\n`);
    }
    return result.code;
  }
  process.stderr.write('usage: acceptance-verify-v1.js record|status|verdict|accept-ids|handoff|plan-criteria\n');
  return 2;
}

module.exports = {
  SCHEMA,
  STORE_SEGMENTS,
  VERDICTS,
  ATTESTED_DRIVERS,
  OBSERVED_DRIVERS,
  DRIVERS,
  EARLIER_ATTESTED_DRIVERS,
  EARLIER_OBSERVED_DRIVERS,
  ACCEPTED_DRIVERS,
  RECORDED_DRIVER_SPELLINGS,
  GATE_MODES,
  VERDICT_STATES,
  PASSING_STATES,
  CRITERION_STATES,
  VERIFY_AGAIN_STATES,
  STANDALONE_VERIFY_AGAIN_STATES,
  HANDOFF_SCHEMA,
  HANDOFF_SEGMENTS,
  HANDOFF_KEYS,
  HANDOFF_STATES,
  USER_REMEDIES,
  ACCEPT_CONTEXT_REFUSALS,
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
  runChain,
  runHead,
  recordLine,
  record,
  evaluate,
  assess,
  status,
  normalizeGateMode,
  boundLine,
  remedies,
  remedyKind,
  isHandoff,
  parseAcceptIds,
  acceptOpenRows,
  handoffFile,
  validateHandoff,
  writeHandoff,
  removeHandoff,
  handoffLine,
  handoffStatus,
  planCriteria,
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
