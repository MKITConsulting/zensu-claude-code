'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const childProcess = require('node:child_process');

const GIT_TIMEOUT_MS = 10000;
const MAX_LISTING_BYTES = 64 * 1024 * 1024;
const SHA_RE = /^[0-9a-f]{40,64}$/i;
const PACKET_START = 'REVIEW PACKET v1';
const PACKET_END = 'END REVIEW PACKET v1';
const PACKET_SCHEMA = 'zensu-review-packet-record-v1';
const INPUT_FIELDS = Object.freeze([
  'implementation_summary',
  'requirements_baseline',
  'diff_summary',
  'test_evidence',
  'build_evidence',
  'coverage_evidence',
  'edit_landing_evidence',
]);
const LIMITS = {
  fieldBytes: 192 * 1024,
  changedListBytes: 1024 * 1024,
};
const PACKET_OVERHEAD_BYTES = 64 * 1024;
const inputBytesLimit = () => LIMITS.fieldBytes + LIMITS.changedListBytes;
const packetBytesLimit = () => LIMITS.fieldBytes + LIMITS.changedListBytes + PACKET_OVERHEAD_BYTES;
const recordBytesLimit = () => 2 * packetBytesLimit() + 1024 * 1024;
const MAX_RECEIPT_BYTES = 4 * 1024 * 1024;
const MAX_SNAPSHOT_FILES = 20000;
const MAX_SNAPSHOT_BYTES = 64 * 1024 * 1024;
const RECEIPT_CHECK_TIMEOUT_MS = 120000;
const STORE_PREFIX = 'review-gate-';
const EDIT_LANDING_ESCAPE = 'ZENSU_EDIT_LANDING_GATE';
const RECEIPT_MODES = Object.freeze(['receipt', 'escaped', 'none']);
const BASELINE_SOURCES = Object.freeze(['receipt', 'argument', 'none']);
const REVIEW_INPUT_SEGMENTS = Object.freeze(['.zensu', 'reviews']);
const CONTROL_RE = /[\x00-\x1f\x7f]/;
const FIELD_CONTROL_RE = /[\x00-\x08\x0b-\x1f\x7f]/;

class ReviewPacketError extends Error {}

function fail(message) {
  throw new ReviewPacketError(message);
}

function core() {
  return require('./session-control-core-v1.js');
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function gitEnvironment() {
  return require('./evidence-run-v1.js').gitEnvironment();
}

function git(root, args, options = {}) {
  const result = childProcess.spawnSync('git', ['-C', root, ...args], {
    env: gitEnvironment(),
    encoding: 'utf8',
    maxBuffer: MAX_LISTING_BYTES,
    timeout: GIT_TIMEOUT_MS,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error) {
    if (result.error.code === 'ENOENT' && options.absentGit) return { absent: true };
    fail(`git ${args[0]} could not run (${result.error.code || result.error.message})`);
  }
  if (options.absentRepository && result.status !== 0 && /not a git repository/i.test(result.stderr || '')) {
    return { absent: true };
  }
  if (result.status === 0) return { stdout: result.stdout };
  if (options.allowStatusOne && result.status === 1) return { stdout: null };
  const first = String(result.stderr || '').trim().split('\n')[0] || `exit ${result.status}`;
  fail(`git ${args[0]} failed: ${first.slice(0, 200)}`);
}

function untrackedListing(repository) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-no-global-excludes-'));
  try {
    const empty = path.join(directory, 'excludes');
    fs.writeFileSync(empty, '', { flag: 'wx', mode: 0o600 });
    return git(repository, ['-c', `core.excludesFile=${empty}`, 'ls-files', '--others', '--exclude-standard', '-z', '--']).stdout;
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

function excluded(file) {
  const artifacts = require('./evidence-run-v1.js').WORKFLOW_ARTIFACTS;
  const parts = file.split('/');
  return parts.some((part, index) => part === '.git' || (part === '.zensu' && artifacts.includes(parts[index + 1])));
}

function canonicalRoot(root) {
  if (typeof root !== 'string' || root === '') fail('--root is required');
  let requested;
  try {
    requested = fs.realpathSync(root);
  } catch (error) {
    fail(`the project root cannot be resolved (${error.code || error.message})`);
  }
  if (!fs.statSync(requested).isDirectory()) fail('the project root is not a directory');
  return requested;
}

function collectChanges(options = {}) {
  const requested = canonicalRoot(options.root);
  const baseline = typeof options.baseline === 'string' ? options.baseline : '';
  const top = git(requested, ['rev-parse', '--show-toplevel'], { absentRepository: true, absentGit: true });
  if (top.absent) {
    if (baseline) fail('a project outside git cannot carry a commit baseline');
    return { schema: 'zensu-change-set-v1', kind: 'explicit-no-git', root: requested, baseline: null, head: null, changed_files: null };
  }
  const repository = fs.realpathSync(top.stdout.trim());
  const head = git(repository, ['rev-parse', '--verify', '--quiet', 'HEAD'], { allowStatusOne: true }).stdout;
  const paths = new Set();
  const add = (listing) => {
    for (const file of String(listing || '').split('\0')) {
      if (!file) continue;
      if (/[\r\n]/.test(file)) fail('a changed path contains a line break, which the review packet cannot carry');
      if (!excluded(file)) paths.add(file);
    }
  };
  if (head !== null) {
    add(git(repository, ['diff', '--no-ext-diff', '--no-renames', '--name-only', '-z', 'HEAD', '--']).stdout);
    if (baseline) {
      if (!SHA_RE.test(baseline)) fail('--baseline must be the exact commit SHA captured at Phase 0');
      git(repository, ['rev-parse', '--verify', '--quiet', `${baseline}^{commit}`]);
      add(git(repository, ['diff', '--no-ext-diff', '--no-renames', '--name-only', '-z', `${baseline}..HEAD`, '--']).stdout);
    }
  } else {
    if (baseline) fail('--baseline cannot apply to a repository whose HEAD is unborn');
    add(git(repository, ['ls-files', '--cached', '-z', '--']).stdout);
  }
  add(untrackedListing(repository));
  return {
    schema: 'zensu-change-set-v1',
    kind: 'git',
    root: repository,
    baseline: baseline || null,
    head: head === null ? null : head.trim(),
    changed_files: [...paths].sort(),
  };
}

function readBounded(file, limit) {
  let stat;
  try {
    stat = fs.lstatSync(file);
  } catch (error) {
    if (error.code === 'ENOENT') return { absent: true };
    return { invalid: `unreadable (${error.code || 'error'})` };
  }
  if (stat.isSymbolicLink() || !stat.isFile()) return { invalid: 'not a regular file' };
  if (stat.size > limit) return { invalid: `larger than ${limit} bytes` };
  try {
    return { bytes: fs.readFileSync(file) };
  } catch (error) {
    return { invalid: `unreadable (${error.code || 'error'})` };
  }
}

function requireSession(session) {
  if (typeof session !== 'string' || session === '' || CONTROL_RE.test(session)) fail('--session is required');
  try {
    return core().sessionKey(session);
  } catch (error) {
    fail(`--session is not a usable session id (${error.message})`);
  }
}

function chainState(root, session) {
  const state = require('./edit-landing-receipt-v1.js').workflowState(root, session);
  if (state.status === 'none') return { status: 'absent' };
  if (state.status !== 'ok') return state;
  const value = state.value;
  return {
    status: 'ok',
    reviewable: value.active === true && value.implComplete === true && value.chainDone !== true,
    round: value.reviewRound,
    deferred: typeof value.deferredReviewClaim === 'string' && value.deferredReviewClaim !== '',
    escaped: Array.isArray(value.bypasses) && value.bypasses.includes(EDIT_LANDING_ESCAPE),
    ticket: value.reviewTicket,
    ticketConsumed: value.reviewTicketConsumed === true,
    codeReviewDone: value.codeReviewDone === true,
  };
}

function storeDirectory(root, session) {
  const engine = core();
  return path.join(root, ...engine.WORKFLOW_STATE_SEGMENTS, `${STORE_PREFIX}${engine.sessionKey(session)}`);
}

function packetFile(store, round) {
  return path.join(store, `packet-r${round}.json`);
}

function ensureStore(root, session) {
  const engine = core();
  let current = root;
  for (const segment of engine.WORKFLOW_STATE_SEGMENTS) {
    current = path.join(current, segment);
    let stat;
    try {
      stat = fs.lstatSync(current);
    } catch (error) {
      fail(`the ${segment} directory of the project cannot be read (${error.code || 'error'})`);
    }
    if (stat.isSymbolicLink() || !stat.isDirectory()) fail(`the ${segment} directory of the project is not a real directory`);
  }
  const store = storeDirectory(root, session);
  try {
    fs.mkdirSync(store, { mode: 0o700 });
  } catch (error) {
    if (error.code !== 'EEXIST') fail(`the review gate store cannot be created (${error.code || 'error'})`);
  }
  const stat = fs.lstatSync(store);
  if (stat.isSymbolicLink() || !stat.isDirectory()) fail('the review gate store is not a real directory');
  return store;
}

function writeAtomic(file, text) {
  const temporary = `${file}.${process.pid}.${crypto.randomBytes(6).toString('hex')}.tmp`;
  fs.writeFileSync(temporary, text, { mode: 0o600, flag: 'wx' });
  try {
    fs.renameSync(temporary, file);
  } catch (error) {
    fs.rmSync(temporary, { force: true });
    throw error;
  }
}

function validPacketRecord(record, round) {
  return Boolean(record) && typeof record === 'object' && record.schema === PACKET_SCHEMA && record.round === round
    && typeof record.text === 'string' && typeof record.sha256 === 'string' && sha256(record.text) === record.sha256
    && Number.isSafeInteger(record.createdAt) && record.scope && typeof record.scope === 'object'
    && RECEIPT_MODES.includes(record.receiptMode)
    && (record.receiptMode === 'receipt'
      ? typeof record.receiptSha256 === 'string' && /^[0-9a-f]{64}$/.test(record.receiptSha256)
      : record.receiptSha256 === null);
}

function readPacketRecord(store, round) {
  const loaded = readBounded(packetFile(store, round), recordBytesLimit());
  if (loaded.absent) return null;
  if (loaded.invalid) fail(`the canonical packet of review round ${round} is ${loaded.invalid}`);
  let record;
  try {
    record = JSON.parse(loaded.bytes.toString('utf8'));
  } catch {
    fail(`the canonical packet of review round ${round} is not JSON`);
  }
  if (!validPacketRecord(record, round)) fail(`the canonical packet of review round ${round} does not validate`);
  return record;
}

function snapshotFiles(root, files) {
  if (!Array.isArray(files) || files.length === 0 || files.length > MAX_SNAPSHOT_FILES) {
    fail('a project outside git needs changed_files in the --input file: a non-empty list of project-relative paths');
  }
  const entries = [];
  let total = 0;
  for (const file of [...new Set(files)].sort()) {
    if (typeof file !== 'string' || file === '' || /[\x00-\x1f\x7f\\]/.test(file) || path.isAbsolute(file)
        || path.posix.normalize(file) !== file || file.split('/').some((part) => ['', '.', '..'].includes(part)) || excluded(file)) {
      fail(`the changed_files entry ${JSON.stringify(String(file)).slice(0, 120)} is not a normalized path inside the project`);
    }
    const parts = file.split('/');
    let current = root;
    let stat = null;
    let missing = false;
    for (let index = 0; index < parts.length; index += 1) {
      current = path.join(current, parts[index]);
      try {
        stat = fs.lstatSync(current);
      } catch (error) {
        if (error.code === 'ENOENT') {
          missing = true;
          break;
        }
        fail(`the changed file ${file} cannot be read (${error.code || 'error'})`);
      }
      if (stat.isSymbolicLink()) fail(`the changed file ${file} passes through a symbolic link`);
      if (index < parts.length - 1 && !stat.isDirectory()) fail(`the changed file ${file} has a parent that is not a directory`);
    }
    if (missing) {
      entries.push({ path: file, exists: false });
      continue;
    }
    if (!stat.isFile()) fail(`the changed file ${file} is not a regular file`);
    total += stat.size;
    if (total > MAX_SNAPSHOT_BYTES) fail('the changed files of a project outside git exceed the snapshot limit');
    entries.push({ path: file, exists: true, sha256: sha256(fs.readFileSync(current)) });
  }
  return entries;
}

function currentScope(root, baseline, explicitFiles) {
  const changes = collectChanges({ root, baseline });
  if (changes.kind === 'git') {
    if (explicitFiles !== undefined) fail('a project inside git takes its changed files from git; remove changed_files from the --input file');
    const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-review-tree-'));
    let result;
    try {
      result = require('./evidence-run-v1.js').computeTree(changes.root, scratch, undefined, { workflowStateAtEveryDepth: true });
    } finally {
      fs.rmSync(scratch, { recursive: true, force: true });
    }
    if (!result || (!result.tree && result.limited !== true)) {
      fail(`the working tree has no fingerprint (${(result && result.reason) || 'unknown reason'})`);
    }
    const scope = {
      kind: 'git',
      root: changes.root,
      head: changes.head,
      baseline: changes.baseline,
      changedFiles: changes.changed_files,
      tree: result.tree || null,
    };
    if (!result.tree) scope.treeReason = String(result.reason || 'the tree could not be fingerprinted');
    return scope;
  }
  const snapshot = snapshotFiles(changes.root, explicitFiles);
  return {
    kind: 'explicit-no-git',
    root: changes.root,
    head: null,
    baseline: null,
    changedFiles: snapshot.map((entry) => entry.path),
    snapshot: sha256(JSON.stringify(snapshot)),
  };
}

function scopeDifference(stored, now) {
  if (!stored || stored.kind !== now.kind) return 'the project is no longer the same kind of change set';
  if (stored.root !== now.root) return 'the repository root changed';
  if (stored.head !== now.head) return 'HEAD moved';
  if (stored.baseline !== now.baseline) return 'the baseline changed';
  if (JSON.stringify(stored.changedFiles) !== JSON.stringify(now.changedFiles)) return 'the change set changed';
  if (now.kind === 'git' && (stored.tree !== now.tree || (now.tree === null && stored.treeReason !== now.treeReason))) {
    return 'the working tree changed';
  }
  if (now.kind !== 'git' && stored.snapshot !== now.snapshot) return 'a changed file changed';
  return null;
}

function receiptPath(root, session) {
  return require('./edit-landing-receipt-v1.js').receiptFile(root, core().sessionKey(session));
}

function readReceipt(root, session) {
  const loaded = readBounded(receiptPath(root, session), MAX_RECEIPT_BYTES);
  if (loaded.absent) fail('this session has no edit-landing receipt; run the Phase 6 step 5b audit first');
  if (loaded.invalid) fail(`the edit-landing receipt is ${loaded.invalid}`);
  let value;
  try {
    value = JSON.parse(loaded.bytes.toString('utf8'));
  } catch {
    fail('the edit-landing receipt is not JSON');
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail('the edit-landing receipt is not an object');
  return { sha256: sha256(loaded.bytes), value };
}

function receiptAbsent(root, session) {
  return readBounded(receiptPath(root, session), MAX_RECEIPT_BYTES).absent === true;
}

function receiptMode(root, session, state, env = process.env) {
  if (env[EDIT_LANDING_ESCAPE] === 'off' || state.escaped) return 'escaped';
  if (state.deferred && receiptAbsent(root, session)) return 'none';
  return 'receipt';
}

function receiptLine(mode, receipt) {
  if (mode === 'escaped') return `escaped (${EDIT_LANDING_ESCAPE}=off; no edit-landing receipt binds this review)`;
  if (mode === 'none') return 'none (not run — this chain is a deferred review the Stop hook adopted, and no edit-landing audit ran in it)';
  const value = receipt.value;
  const count = (field) => (Number.isSafeInteger(value[field]) && value[field] >= 0 ? value[field] : '?');
  const schema = typeof value.schema === 'string' && /^[A-Za-z0-9._-]{1,40}$/.test(value.schema) ? value.schema : '?';
  return `schema=${schema} clean=${value.clean === true} claims=${count('claims')} landed=${count('landed')}`
    + ` not_landed=${count('notLanded')} unverified=${count('unverified')} pending=${count('pending')} sha256=${receipt.sha256}`
    + (value.auditFailure ? ' audit=incomplete' : '');
}

function packetBaseline(mode, receipt, supplied) {
  const scope = mode === 'receipt' && receipt && receipt.value ? receipt.value.auditScope : null;
  const recorded = scope && typeof scope === 'object' && typeof scope.baseline === 'string' ? scope.baseline : '';
  const argument = typeof supplied === 'string' ? supplied : '';
  if (recorded !== '') {
    if (!SHA_RE.test(recorded)) fail('the edit-landing receipt records a baseline that is not a commit SHA; re-run the step 5b audit with the exact Phase 0 baseline');
    if (argument !== '' && argument !== recorded) {
      fail(`--baseline differs from the baseline the edit-landing audit recorded (${recorded}); omit --baseline, and the packet takes the audit's baseline`);
    }
    return { baseline: recorded, source: 'receipt' };
  }
  if (argument !== '') return { baseline: argument, source: 'argument' };
  return { baseline: '', source: 'none' };
}

function checkReceipt(root, session) {
  const result = childProcess.spawnSync('bash', [path.join(__dirname, 'zensu-edit-landing.sh'), '--check-receipt',
    '--allow-unclean', '--project', root, '--session', session], {
    env: process.env,
    encoding: 'utf8',
    maxBuffer: 1024 * 1024,
    timeout: RECEIPT_CHECK_TIMEOUT_MS,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error) fail(`the edit-landing receipt could not be checked (${result.error.code || result.error.message})`);
  if (result.status !== 0) {
    const text = String(result.stderr || '').trim().split('\n').filter(Boolean).slice(0, 4).join(' ');
    fail(text || `the edit-landing receipt check exited ${result.status}`);
  }
}

function readInput(file) {
  if (typeof file !== 'string' || file === '') fail('--input is required');
  const loaded = readBounded(file, inputBytesLimit());
  if (loaded.absent) fail('the --input file does not exist');
  if (loaded.invalid) fail(`the --input file is ${loaded.invalid}`);
  let value;
  try {
    value = JSON.parse(loaded.bytes.toString('utf8'));
  } catch (error) {
    fail(`the --input file is not JSON (${error.message})`);
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail('the --input file must hold one JSON object');
  const allowed = new Set([...INPUT_FIELDS, 'changed_files']);
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) fail(`the --input file carries the unknown field ${JSON.stringify(key).slice(0, 80)}`);
  }
  for (const field of INPUT_FIELDS) {
    if (typeof value[field] !== 'string' || value[field].trim() === '') {
      fail(`the --input file needs a non-empty string ${field}; write "not run — <reason>" for evidence this review did not produce`);
    }
    if (FIELD_CONTROL_RE.test(value[field].replace(/\r\n?/g, '\n'))) fail(`${field} carries a control character`);
  }
  if (value.changed_files !== undefined && !Array.isArray(value.changed_files)) fail('changed_files must be a list of paths');
  return value;
}

function blockLines(value) {
  const lines = String(value).replace(/\r\n?/g, '\n').split('\n').map((line) => line.replace(/[ \t]+$/u, ''));
  while (lines.length && lines[0] === '') lines.shift();
  while (lines.length && lines[lines.length - 1] === '') lines.pop();
  return lines.map((line) => (line === '' ? '' : `  ${line}`));
}

function pathLine(file) {
  const plain = file === file.trim() && !CONTROL_RE.test(file) && !file.startsWith('"');
  return `- ${plain ? file : JSON.stringify(file)}`;
}

function renderPacket({ round, projectRoot, scope, fields, receipt, receiptMode: mode = 'receipt' }) {
  const lines = [
    PACKET_START,
    'policy: reviewer-readonly-v1',
    `review_round: ${round}`,
    `project_root: ${projectRoot}`,
    `repository_root: ${scope.root}`,
    scope.kind === 'git'
      ? `change_set: kind=git head=${scope.head || 'unborn'} baseline=${scope.baseline || 'none'}`
        + ` baseline_source=${BASELINE_SOURCES.includes(scope.baselineSource) ? scope.baselineSource : 'none'}`
        + ` tree=${scope.tree === null ? `unverified (${scope.treeReason})` : scope.tree}`
      : `change_set: kind=explicit-no-git snapshot=sha256:${scope.snapshot}`,
  ];
  if (scope.changedFiles.length === 0) lines.push('changed_files: none');
  else lines.push('changed_files:', ...scope.changedFiles.map(pathLine));
  for (const field of INPUT_FIELDS) lines.push(`${field}: |`, ...blockLines(fields[field]));
  lines.push(`edit_landing_receipt: ${receiptLine(mode, receipt)}`, PACKET_END);
  return lines.join('\n');
}

function extractPacket(prompt) {
  if (typeof prompt !== 'string') return { status: 'absent' };
  const lines = prompt.replace(/\r\n?/g, '\n').split('\n').map((line) => line.replace(/[ \t]+$/u, ''));
  const starts = [];
  const ends = [];
  lines.forEach((line, index) => {
    if (line === PACKET_START) starts.push(index);
    else if (line === PACKET_END) ends.push(index);
  });
  if (starts.length === 0) return { status: 'absent' };
  if (starts.length > 1 || ends.length > 1) return { status: 'duplicate' };
  if (ends.length === 0 || ends[0] < starts[0]) return { status: 'unterminated' };
  const text = lines.slice(starts[0], ends[0] + 1).join('\n');
  return { status: 'ok', text, sha256: sha256(text) };
}

function firstDifference(expected, actual) {
  const left = String(expected).split('\n');
  const right = String(actual).split('\n');
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    if (left[index] !== right[index]) return index + 1;
  }
  return 0;
}

function reviewableChain(projectRoot, session) {
  const state = chainState(projectRoot, session);
  if (state.status === 'absent') fail('this session has no workflow state at this project root; arm the chain first');
  if (state.status !== 'ok') fail(`the workflow state of this session cannot be trusted (${state.reason})`);
  if (!state.reviewable) fail('the chain is not waiting for a review: it needs an active chain whose implementation is complete and whose terminus has not run');
  return state;
}

function createPacket(options = {}) {
  const projectRoot = canonicalRoot(options.root);
  if (CONTROL_RE.test(projectRoot)) fail('the project root contains a control character, which the packet cannot carry');
  requireSession(options.session);
  const state = reviewableChain(projectRoot, options.session);
  const input = readInput(options.input);
  const mode = receiptMode(projectRoot, options.session, state, options.env || process.env);
  let receipt = null;
  if (mode === 'receipt') {
    (options.checkReceipt || checkReceipt)(projectRoot, options.session);
    receipt = readReceipt(projectRoot, options.session);
  }
  const baseline = packetBaseline(mode, receipt, options.baseline);
  const scope = currentScope(projectRoot, baseline.baseline, input.changed_files);
  if (CONTROL_RE.test(scope.root)) fail('the repository root contains a control character, which the packet cannot carry');
  if (scope.kind === 'git') scope.baselineSource = baseline.source;
  const listBytes = Buffer.byteLength(scope.changedFiles.map(pathLine).join('\n'));
  if (listBytes > LIMITS.changedListBytes) {
    fail(`the change set lists ${scope.changedFiles.length} paths in ${listBytes} bytes, more than ${LIMITS.changedListBytes}; review a change this large in smaller chains`);
  }
  const fieldBytes = INPUT_FIELDS.reduce((total, field) => total + Buffer.byteLength([`${field}: |`, ...blockLines(input[field])].join('\n')), 0);
  if (fieldBytes > LIMITS.fieldBytes) fail(`the packet's summary fields take ${fieldBytes} bytes, more than ${LIMITS.fieldBytes}; shorten its summaries`);
  const text = renderPacket({ round: state.round, projectRoot, scope, fields: input, receipt, receiptMode: mode });
  const bytes = Buffer.byteLength(text);
  if (bytes > packetBytesLimit()) fail(`the packet is ${bytes} bytes, more than ${packetBytesLimit()}`);
  const digest = sha256(text);
  const store = ensureStore(projectRoot, options.session);
  let previous = null;
  try {
    previous = readPacketRecord(store, state.round);
  } catch (error) {
    if (!(error instanceof ReviewPacketError)) throw error;
  }
  if (previous && previous.sha256 === digest) return { record: previous, unchanged: true };
  const record = {
    schema: PACKET_SCHEMA,
    round: state.round,
    createdAt: (options.now || Date.now)(),
    sha256: digest,
    scope,
    receiptMode: mode,
    receiptSha256: receipt ? receipt.sha256 : null,
    text,
  };
  writeAtomic(packetFile(store, state.round), JSON.stringify(record));
  return { record, unchanged: false };
}

function removeConsumedInput(file, root) {
  try {
    if (typeof file !== 'string' || file === '' || typeof root !== 'string' || root === '') return false;
    if (file.split(/[\\/]/).includes('..')) return false;
    const projectRoot = fs.realpathSync(root);
    const directory = fs.realpathSync(path.dirname(file));
    if (path.basename(directory) !== REVIEW_INPUT_SEGMENTS[1] || path.basename(path.dirname(directory)) !== REVIEW_INPUT_SEGMENTS[0]) return false;
    const relative = path.relative(projectRoot, path.dirname(path.dirname(directory)));
    if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) return false;
    const target = path.join(directory, path.basename(file));
    const stat = fs.lstatSync(target);
    if (stat.isSymbolicLink() || !stat.isFile() || stat.nlink !== 1) return false;
    fs.unlinkSync(target);
    return true;
  } catch {
    return false;
  }
}

function showPacket(options = {}) {
  const projectRoot = canonicalRoot(options.root);
  requireSession(options.session);
  const state = reviewableChain(projectRoot, options.session);
  const record = readPacketRecord(storeDirectory(projectRoot, options.session), state.round);
  if (!record) fail(`review round ${state.round} has no canonical packet yet; run review-packet-v1.js create first`);
  return { record };
}

function packetReport(lead, record) {
  const files = record.scope && Array.isArray(record.scope.changedFiles) ? record.scope.changedFiles.length : 0;
  return `${lead} — round=${record.round} sha256=${record.sha256} files=${files} bytes=${Buffer.byteLength(record.text)}\n`
    + 'Copy every line from "REVIEW PACKET v1" to "END REVIEW PACKET v1" below, unchanged and unindented, into every reviewer prompt of this round.\n\n'
    + `${record.text}\n`;
}

function parseFlags(args, allowed) {
  const flags = Object.create(null);
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index];
    if (!allowed.includes(name)) fail(`unknown argument '${name}'`);
    if (index + 1 >= args.length) fail(`${name} requires a value`);
    if (Object.prototype.hasOwnProperty.call(flags, name)) fail(`${name} was given twice`);
    flags[name] = String(args[index + 1]);
  }
  return flags;
}

function main(argv, stdout = process.stdout, stderr = process.stderr) {
  const [verb, ...args] = argv;
  try {
    if (verb === 'changes') {
      const flags = parseFlags(args, ['--root', '--baseline']);
      stdout.write(`${JSON.stringify(collectChanges({ root: flags['--root'], baseline: flags['--baseline'] }), null, 2)}\n`);
      return 0;
    }
    if (verb === 'create') {
      const flags = parseFlags(args, ['--root', '--session', '--input', '--baseline']);
      const result = createPacket({ root: flags['--root'], session: flags['--session'], input: flags['--input'], baseline: flags['--baseline'] });
      removeConsumedInput(flags['--input'], flags['--root']);
      stdout.write(packetReport(result.unchanged ? 'REVIEW PACKET UNCHANGED' : 'REVIEW PACKET CREATED', result.record));
      return 0;
    }
    if (verb === 'show') {
      const flags = parseFlags(args, ['--root', '--session']);
      stdout.write(packetReport('REVIEW PACKET', showPacket({ root: flags['--root'], session: flags['--session'] }).record));
      return 0;
    }
    fail('usage: review-packet-v1.js changes --root <dir> [--baseline <sha>] | create --root <dir> --session <id> --input <json> [--baseline <sha>] | show --root <dir> --session <id>');
  } catch (error) {
    stderr.write(`review-packet-v1: ${error instanceof ReviewPacketError ? error.message : `unexpected failure (${error.message})`}\n`);
    return 2;
  }
}

module.exports = {
  ReviewPacketError,
  PACKET_START,
  PACKET_END,
  PACKET_SCHEMA,
  INPUT_FIELDS,
  LIMITS,
  BASELINE_SOURCES,
  REVIEW_INPUT_SEGMENTS,
  sha256,
  canonicalRoot,
  collectChanges,
  chainState,
  storeDirectory,
  packetFile,
  ensureStore,
  writeAtomic,
  readBounded,
  readPacketRecord,
  currentScope,
  scopeDifference,
  receiptPath,
  receiptAbsent,
  receiptMode,
  readReceipt,
  receiptLine,
  packetBaseline,
  checkReceipt,
  readInput,
  renderPacket,
  extractPacket,
  firstDifference,
  createPacket,
  removeConsumedInput,
  showPacket,
  parseFlags,
  main,
};

if (require.main === module) {
  process.exitCode = main(process.argv.slice(2));
}
