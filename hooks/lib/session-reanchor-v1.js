'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');
const core = require('./session-control-core-v1.js');
const worktreeKeep = require('./worktree-keep-v1.js');
const sweep = require('./review-evidence-sweep-v1.js');
const safeDisplay = require('./zensu-safe-display-v1.js');
const { within } = require('./bash-source-write-parse.js');
const { msysDrivePrefix } = require('./claude-path-v1.js');

const REANCHOR_REFUSALS = Object.freeze({
  SESSION_ID_UNUSABLE: 'session-id-unusable',
  STORE_UNSAFE: 'private-record-store-unsafe',
  RECORD_UNREADABLE: 'record-unreadable',
  RECORDED_ROOT_MISSING: 'recorded-root-missing',
  NOT_SERVED: 'not-served-by-executing-runtime',
  PLUGIN_DATA: 'plugin-data-mismatch',
  WORKFLOW_UNUSABLE: 'workflow-document-unusable',
  WORKFLOW_IN_PROGRESS: 'workflow-in-progress',
  AUTOPILOT_UNVERIFIABLE: 'autopilot-state-unverifiable',
  RECORDED_ROOT_NOT_IN_WORKTREE: 'recorded-root-not-in-a-worktree',
  TARGET_NOT_IN_WORKTREE: 'target-not-in-a-worktree',
  DIFFERENT_REPOSITORY: 'different-repository',
  TARGET_NOT_REGISTERED: 'target-not-a-registered-worktree',
  ALREADY_ANCHORED: 'already-anchored',
  TARGET_CONTAINS_RECORDED_ROOT: 'target-contains-recorded-root',
  TARGET_CONTAINS_WORKTREES: 'target-contains-other-worktrees',
  TARGET_WORKFLOW_UNUSABLE: 'target-workflow-document-unusable',
  CLAIMED: 'claimed-by-live-session',
  LIVE_SESSIONS_UNVERIFIABLE: 'live-sessions-unverifiable',
  VERDICT_UNAVAILABLE: 'verdict-unavailable',
});

const REANCHOR_HISTORY_PHASE = 'PROJECT_ROOT_REANCHORED';
const REANCHOR_HISTORY_REASON_PREFIX = 'project-root-reanchored: ';
const REANCHOR_WORKFLOW_STATE = 'project_root_reanchored';
const REANCHOR_WORKFLOW_EVENT = 'project-root-reanchored';
const GIT_TIMEOUT_MS = 20000;
const AUTOPILOT_TIMEOUT_MS = 60000;
const AUTOPILOT_TERMINAL_STAGES = new Set(['DONE', 'CANCELLED']);
const AUTOPILOT_READER_FAULTS = Object.freeze({
  2: 'an orphaned, hidden or inconsistent run',
  3: 'the reader refused the call',
  5: 'the Autopilot lock or state storage could not be read',
  97: 'the Autopilot state library did not load',
});
const PLUGIN_ROOT = path.resolve(__dirname, '..', '..');
const SESSION_MARKERS = Object.freeze(['tdd-mode', 'delivery-route', 'zen-mode']);
const MAX_REGISTRY_ENTRIES = 1024;
const MAX_REGISTRY_BYTES = 65536;
const MAX_RECORD_BYTES = 1024 * 1024;
const REGISTRY_NAME_RE = /^([1-9][0-9]{0,9})\.json$/;
const LABEL_WIDTH = 17;
const MAX_LISTED_PATHS = 10;
const UNPASTABLE_ROOT_RE = /["$`\\]/;

const REANCHOR_REMEDY = Object.freeze({
  [REANCHOR_REFUSALS.SESSION_ID_UNUSABLE]: 'The session identity this command was given is empty, malformed, or a derived Session Control identifier rather than the raw host session id. Nothing was read.',
  [REANCHOR_REFUSALS.STORE_UNSAFE]: 'The private Session Control record store is missing, aliased, or has unsafe permissions or ownership, so no record in it is re-minted. Run /zensu:doctor.',
  [REANCHOR_REFUSALS.RECORD_UNREADABLE]: 'The Session Control record did not re-verify. Run /zensu:doctor for the exact cause.',
  [REANCHOR_REFUSALS.RECORDED_ROOT_MISSING]: 'The recorded project root no longer exists, so the repository it belonged to cannot be proven and the anchor cannot move away from it. /zensu:adopt-session --restore-root reports whether that directory can be re-created; otherwise start a fresh Claude Code session in the worktree you want to work in.',
  [REANCHOR_REFUSALS.NOT_SERVED]: 'The running Zensu installation does not serve this session\'s record — a lineage break or a pruned installation. Run /zensu:adopt-session first, then run this command again.',
  [REANCHOR_REFUSALS.PLUGIN_DATA]: 'The record belongs to a different plugin-data store and is never re-anchored from this one.',
  [REANCHOR_REFUSALS.WORKFLOW_UNUSABLE]: 'This session\'s workflow document under the recorded root is missing or cannot be read. /zensu:adopt-session --confirm rebuilds a missing one; /zensu:doctor names any other cause.',
  [REANCHOR_REFUSALS.WORKFLOW_IN_PROGRESS]: 'This session still holds open work under the recorded root, and its evidence is bound to that root. Finish that work first — a review chain ends at its terminus, zensu-log.sh --tdd-reset discards an armed one, and an Autopilot run this session owns ends at DONE or is cancelled through zensu-log.sh --autopilot-event --run <run id> --event CANCEL, since /zensu:autopilot-release refuses the caller\'s own run — then run this command again.',
  [REANCHOR_REFUSALS.AUTOPILOT_UNVERIFIABLE]: 'Whether this session owns an open Autopilot run under the recorded root could not be established, so the move is refused rather than guessed. The autopilot row of /zensu:doctor and zensu-log.sh --autopilot-status name the cause.',
  [REANCHOR_REFUSALS.RECORDED_ROOT_NOT_IN_WORKTREE]: 'git does not place the recorded project root inside a worktree, so the repository it belongs to cannot be proven.',
  [REANCHOR_REFUSALS.TARGET_NOT_IN_WORKTREE]: 'The directory this command ran in is not inside a git worktree. Run it from inside the worktree this session should be anchored to.',
  [REANCHOR_REFUSALS.DIFFERENT_REPOSITORY]: 'That worktree belongs to a different repository than the recorded root. A re-anchor never crosses repositories; start a fresh Claude Code session there instead.',
  [REANCHOR_REFUSALS.TARGET_NOT_REGISTERED]: 'That directory is not a registered worktree of the recorded root\'s repository, or git marks it prunable.',
  [REANCHOR_REFUSALS.ALREADY_ANCHORED]: 'This session is already anchored at that worktree.',
  [REANCHOR_REFUSALS.TARGET_CONTAINS_RECORDED_ROOT]: 'That worktree contains the recorded project root, so anchoring there would widen this session\'s tree rather than move it. A re-anchor only moves a session to a worktree that lies outside its current anchor.',
  [REANCHOR_REFUSALS.TARGET_CONTAINS_WORKTREES]: 'Other registered worktrees of this repository lie inside that worktree, and anchoring there would admit writes into all of them. Run this command from inside the worktree this session should be anchored to, not from the checkout that contains it.',
  [REANCHOR_REFUSALS.TARGET_WORKFLOW_UNUSABLE]: 'A workflow document for this session already sits under that worktree and is unsafe or unreadable. Inspect it before running this command again; it is never overwritten.',
  [REANCHOR_REFUSALS.CLAIMED]: 'Another live session works in that worktree, or in a worktree nested inside it. Anchoring this session there would let it write into that session\'s tree — the contamination the source-write gate exists to prevent. Use a worktree of your own, or wait until that session ends.',
  [REANCHOR_REFUSALS.LIVE_SESSIONS_UNVERIFIABLE]: 'Whether another live session works in that worktree could not be established, so the move is refused rather than guessed.',
  [REANCHOR_REFUSALS.VERDICT_UNAVAILABLE]: 'The verdict could not be computed. Run /zensu:doctor.',
});

const safe = (value, followedBy) => safeDisplay.safeDisplayValue(String(value), followedBy);
const quoted = (value) => {
  const shown = safe(value);
  return shown.startsWith('"') ? shown : `"${shown}"`;
};
const row = (label, value) => `  ${label.padEnd(LABEL_WIDTH)}: ${value}\n`;
const messageOf = (error) => (error && error.message ? String(error.message) : 'unknown');

function refusal(reason, detail) {
  return { ok: false, reason, detail: Array.isArray(detail) ? detail : [] };
}

function unpastableRoot(root, platform = process.platform) {
  const spelled = String(root);
  return UNPASTABLE_ROOT_RE.test(platform === 'win32' ? spelled.replace(/\\/g, '/') : spelled);
}

function canonicalOrNull(value) {
  if (typeof value !== 'string' || value === '' || /[\0\r\n]/.test(value)) return null;
  try {
    return fs.realpathSync.native(value);
  } catch {
    return null;
  }
}

function runGit(cwd, args) {
  try {
    const output = execFileSync('git', args, {
      cwd,
      encoding: 'utf8',
      timeout: GIT_TIMEOUT_MS,
      maxBuffer: 8 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'ignore'],
      env: { ...worktreeKeep.gitEnvironment(process.env), LC_ALL: 'C' },
    });
    return { ok: true, output };
  } catch {
    return { ok: false, output: '' };
  }
}

function firstLine(output) {
  return String(output).split(/\r?\n/)[0];
}

function worktreeIdentity(directory) {
  const dir = canonicalOrNull(directory);
  if (dir === null) return null;
  const top = runGit(dir, ['rev-parse', '--path-format=absolute', '--show-toplevel']);
  const common = runGit(dir, ['rev-parse', '--path-format=absolute', '--git-common-dir']);
  if (!top.ok || !common.ok) return null;
  const topPath = canonicalOrNull(path.resolve(dir, firstLine(top.output)));
  const commonPath = canonicalOrNull(path.resolve(dir, firstLine(common.output)));
  if (topPath === null || commonPath === null) return null;
  return { top: topPath, commonDir: commonPath };
}

function uncommittedPaths(directory) {
  const listed = runGit(directory, ['--no-optional-locks', 'status', '--porcelain=v1', '-z', '--untracked-files=normal']);
  if (!listed.ok) return null;
  const paths = [];
  const fields = listed.output.split('\0');
  for (let index = 0; index < fields.length; index += 1) {
    const field = fields[index];
    if (field.length < 4) continue;
    paths.push(field.slice(3));
    if ('RC'.includes(field[0]) || 'RC'.includes(field[1])) index += 1;
  }
  return paths;
}

function registeredWorktrees(directory) {
  const dir = canonicalOrNull(directory);
  if (dir === null) return null;
  const listed = runGit(dir, ['worktree', 'list', '--porcelain', '-z']);
  if (!listed.ok) return null;
  const entries = [];
  let current = null;
  for (const field of listed.output.split('\0')) {
    if (field.startsWith('worktree ')) {
      if (current !== null) entries.push(current);
      current = { path: field.slice('worktree '.length), bare: false, prunable: false };
    } else if (field === '') {
      if (current !== null) entries.push(current);
      current = null;
    } else if (current !== null && field === 'bare') {
      current.bare = true;
    } else if (current !== null && (field === 'prunable' || field.startsWith('prunable '))) {
      current.prunable = true;
    }
  }
  if (current !== null) entries.push(current);
  return entries.map((entry) => ({ ...entry, canonical: canonicalOrNull(entry.path) }));
}

function owningWorktree(worktrees, candidate) {
  let best = null;
  for (const worktree of worktrees) {
    if (worktree.canonical === null || worktree.prunable || worktree.bare) continue;
    if (!within(worktree.canonical, candidate)) continue;
    if (best === null || worktree.canonical.length > best.length) best = worktree.canonical;
  }
  return best;
}

function processAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return Boolean(error && error.code === 'EPERM');
  }
}

function liveRegistryDirectory(environment) {
  const configured = environment && typeof environment.CLAUDE_CONFIG_DIR === 'string'
    ? environment.CLAUDE_CONFIG_DIR.trim()
    : '';
  const base = configured !== '' ? path.resolve(msysDrivePrefix(configured)) : path.join(os.homedir(), '.claude');
  return path.join(base, 'sessions');
}

function foreignRecordRoot(recordsDir, sessionId) {
  let key;
  try {
    key = core.sessionKey(sessionId);
  } catch {
    return { status: 'unreadable' };
  }
  const opened = worktreeKeep.openPlainFile(path.join(recordsDir, `${key}.json`), MAX_RECORD_BYTES);
  if (opened.status === 'missing') return { status: 'missing' };
  if (opened.status !== 'ok') return { status: 'unreadable' };
  try {
    const record = JSON.parse(opened.content);
    if (record && typeof record.project_root === 'string' && path.isAbsolute(record.project_root)) {
      return { status: 'ok', projectRoot: record.project_root };
    }
  } catch {
    return { status: 'unreadable' };
  }
  return { status: 'unreadable' };
}

function registryPid(entry) {
  if (!entry || (typeof entry.pid !== 'number' && typeof entry.pid !== 'string')) return NaN;
  const pid = Number(entry.pid);
  return Number.isInteger(pid) && pid > 0 ? pid : NaN;
}

function registryClaims(options) {
  const directory = liveRegistryDirectory(options.environment || process.env);
  const claims = [];
  const unverifiable = [];
  let names;
  try {
    names = fs.readdirSync(directory);
  } catch (error) {
    return {
      claims,
      unverifiable: [`the live-session registry ${directory} cannot be read (${error && error.code ? error.code : 'error'})`],
    };
  }
  const candidates = names.filter((name) => name.endsWith('.json')).sort();
  if (candidates.length > MAX_REGISTRY_ENTRIES) {
    return { claims, unverifiable: [`the live-session registry ${directory} holds more than ${MAX_REGISTRY_ENTRIES} entries`] };
  }
  let ownSeen = false;
  for (const name of candidates) {
    const opened = worktreeKeep.openPlainFile(path.join(directory, name), MAX_REGISTRY_BYTES);
    if (opened.status === 'missing') continue;
    let entry = null;
    if (opened.status === 'ok') {
      try {
        entry = JSON.parse(opened.content);
      } catch {
        entry = null;
      }
    }
    const pid = registryPid(entry);
    const usable = entry !== null && typeof entry === 'object' && !Number.isNaN(pid)
      && typeof entry.sessionId === 'string' && entry.sessionId !== '';
    if (!usable) {
      const named = REGISTRY_NAME_RE.exec(name);
      const probe = !Number.isNaN(pid) ? pid : (named ? Number(named[1]) : NaN);
      if (!Number.isNaN(probe) && !processAlive(probe)) continue;
      unverifiable.push(`the live-session registry entry ${name} cannot be read`);
      continue;
    }
    if (!processAlive(pid)) continue;
    if (entry.sessionId === options.sessionId) {
      ownSeen = true;
      continue;
    }
    const owner = { pid, session: entry.sessionId };
    if (typeof entry.cwd === 'string' && path.isAbsolute(msysDrivePrefix(entry.cwd))) {
      claims.push({ ...owner, source: 'working directory', path: msysDrivePrefix(entry.cwd) });
    } else {
      unverifiable.push(`live session pid ${pid} names no working directory`);
    }
    const record = foreignRecordRoot(options.recordsDir, entry.sessionId);
    if (record.status === 'ok') {
      claims.push({ ...owner, source: 'recorded project root', path: record.projectRoot });
    } else if (record.status === 'unreadable') {
      unverifiable.push(`the Session Control record of live session pid ${pid} cannot be read`);
    }
  }
  if (!ownSeen) unverifiable.push(`this session is not in the live-session registry ${directory}`);
  return { claims, unverifiable };
}

function anchorClaims(options) {
  const claims = [];
  const unverifiable = [];
  const ownKey = core.sessionKey(options.sessionId);
  for (const worktree of options.worktrees) {
    if (worktree.canonical === null || worktree.prunable || worktree.bare) continue;
    if (!within(options.targetRoot, worktree.canonical)) continue;
    let listed;
    try {
      listed = worktreeKeep.listAnchors(worktree.canonical, options.nowMs, options.idleMs);
    } catch (error) {
      listed = { ok: false, reason: error && error.code ? error.code : 'error' };
    }
    if (!listed.ok) {
      unverifiable.push(`the worktree-keep anchors of ${worktree.canonical} cannot be listed (${listed.reason})`);
      continue;
    }
    for (const entry of listed.live) {
      if (entry.key !== ownKey) claims.push({ source: 'live worktree-keep anchor', worktree: worktree.canonical, key: entry.key });
    }
    for (const entry of listed.rejected) {
      if (entry.key !== ownKey) claims.push({ source: 'worktree-keep anchor this build cannot validate', worktree: worktree.canonical, key: entry.key });
    }
  }
  return { claims, unverifiable };
}

function liveClaims(options) {
  const registry = registryClaims(options);
  const anchors = anchorClaims(options);
  const conflicts = [];
  for (const claim of registry.claims) {
    const resolved = canonicalOrNull(claim.path) || path.resolve(claim.path);
    const owner = owningWorktree(options.worktrees, resolved);
    if (owner !== null && within(options.targetRoot, owner)) conflicts.push({ ...claim, worktree: owner });
  }
  conflicts.push(...anchors.claims);
  return { conflicts, unverifiable: [...registry.unverifiable, ...anchors.unverifiable] };
}

function describeClaim(claim) {
  if (claim.pid !== undefined) {
    return `live session pid ${claim.pid} (session ${String(claim.session).slice(0, 8)}) — ${claim.source} ${claim.path}, in worktree ${claim.worktree}`;
  }
  return `${claim.source} ${String(claim.key).slice(0, 13)}… in worktree ${claim.worktree}`;
}

function workflowInProgress(state) {
  if (state.workflowActive === true) return 'an open Zensu skill workflow';
  if (typeof state.autopilotRunId === 'string' && state.autopilotRunId !== '') return 'a linked Autopilot run';
  if (typeof state.deferredReviewClaim === 'string' && state.deferredReviewClaim !== '') return 'a claimed deferred review';
  if (state.reviewRearm !== undefined) return 'a pending review rearm';
  if (state.active === true && state.chainDone !== true) return 'an armed review chain that has not reached its terminus';
  return '';
}

function ownedAutopilotRun(projectRoot, sessionId, bashPath) {
  let owner;
  try {
    owner = core.sessionKey(sessionId);
  } catch (error) {
    return { state: 'unverifiable', detail: messageOf(error) };
  }
  const environment = { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT, CLAUDE_PROJECT_DIR: projectRoot };
  for (const name of ['ZENSU_PROJECT_ROOT', 'ZENSU_SESSION_KEY', 'ZENSU_SESSION_CONTEXT', 'CLAUDE_ENV_FILE', 'BASH_ENV', 'ENV']) delete environment[name];
  const result = spawnSync(
    typeof bashPath === 'string' && bashPath !== '' ? bashPath : 'bash',
    ['-c', 'source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-autopilot-state.sh" || exit 97; autopilot_read_active_strict "$1" "$2"', 'zensu-reanchor', projectRoot, owner],
    { cwd: projectRoot, encoding: 'utf8', timeout: AUTOPILOT_TIMEOUT_MS, maxBuffer: 8 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'], env: environment },
  );
  if (result.error || typeof result.status !== 'number') {
    return { state: 'unverifiable', detail: 'the Autopilot state reader did not finish' };
  }
  if (result.status === 1) return { state: 'none' };
  if (result.status !== 0) {
    const meaning = AUTOPILOT_READER_FAULTS[result.status];
    return { state: 'unverifiable', detail: `the Autopilot state reader answered ${result.status}${meaning ? ` (${meaning})` : ''}` };
  }
  let run = null;
  try {
    run = JSON.parse(result.stdout);
  } catch {
    run = null;
  }
  if (!run || typeof run !== 'object' || typeof run.stage !== 'string' || typeof run.runId !== 'string') {
    return { state: 'unverifiable', detail: 'the Autopilot state reader printed no run' };
  }
  if (AUTOPILOT_TERMINAL_STAGES.has(run.stage)) return { state: 'none' };
  return { state: 'open', detail: `an Autopilot run this session owns (${run.runId}, stage ${run.stage})` };
}

function readRecord(request) {
  const readerOptions = { recordsDir: request.recordsDir, sessionId: request.sessionId, expectedHost: request.host };
  try {
    return { context: core.readContext(readerOptions) };
  } catch {
    try {
      core.readOrphanedProjectRootContext(readerOptions);
      return { reason: REANCHOR_REFUSALS.RECORDED_ROOT_MISSING };
    } catch {
      try {
        core.readPrunedPluginRootContext(readerOptions);
        return { reason: REANCHOR_REFUSALS.NOT_SERVED };
      } catch {
        return { reason: REANCHOR_REFUSALS.RECORD_UNREADABLE };
      }
    }
  }
}

function verdictUnguarded(request) {
  const read = readRecord(request);
  if (!read.context) return refusal(read.reason);
  const context = read.context;
  const pluginData = canonicalOrNull(request.pluginData);
  if (pluginData === null || context.plugin_data !== pluginData) return refusal(REANCHOR_REFUSALS.PLUGIN_DATA);
  const executingPluginRoot = canonicalOrNull(request.executingPluginRoot);
  if (executingPluginRoot === null || !core.servesRecordedRuntime(context, executingPluginRoot, context.host)) {
    return refusal(REANCHOR_REFUSALS.NOT_SERVED);
  }
  const recordedRoot = context.project_root;
  const ownFile = core.adoptionWorkflowStatePath(recordedRoot, request.sessionId);
  const ownState = core.classifyWorkflowBaseline(ownFile, recordedRoot, request.sessionId);
  if (ownState !== core.BASELINE_STATES.PRESENT) {
    return refusal(REANCHOR_REFUSALS.WORKFLOW_UNUSABLE, [`${ownState}: ${ownFile}`]);
  }
  const open = workflowInProgress(core.readWorkflowState({ projectRoot: recordedRoot, sessionId: request.sessionId }));
  if (open !== '') return refusal(REANCHOR_REFUSALS.WORKFLOW_IN_PROGRESS, [open]);
  const recorded = worktreeIdentity(recordedRoot);
  if (recorded === null) return refusal(REANCHOR_REFUSALS.RECORDED_ROOT_NOT_IN_WORKTREE, [recordedRoot]);
  const target = worktreeIdentity(request.targetDirectory);
  if (target === null) {
    return refusal(REANCHOR_REFUSALS.TARGET_NOT_IN_WORKTREE, [String(request.targetDirectory || '(none)')]);
  }
  if (target.commonDir !== recorded.commonDir) return refusal(REANCHOR_REFUSALS.DIFFERENT_REPOSITORY, [target.top]);
  const worktrees = registeredWorktrees(recorded.top);
  if (worktrees === null) return refusal(REANCHOR_REFUSALS.TARGET_NOT_REGISTERED, ['git worktree list failed']);
  const entry = worktrees.find((worktree) => worktree.canonical === target.top);
  if (!entry || entry.prunable || entry.bare) return refusal(REANCHOR_REFUSALS.TARGET_NOT_REGISTERED, [target.top]);
  if (target.top === recordedRoot) return refusal(REANCHOR_REFUSALS.ALREADY_ANCHORED, [target.top]);
  if (within(target.top, recordedRoot)) return refusal(REANCHOR_REFUSALS.TARGET_CONTAINS_RECORDED_ROOT, [target.top]);
  const nested = worktrees
    .filter((worktree) => worktree.canonical !== null && worktree.canonical !== target.top && within(target.top, worktree.canonical))
    .map((worktree) => worktree.canonical);
  if (nested.length > 0) return refusal(REANCHOR_REFUSALS.TARGET_CONTAINS_WORKTREES, nested);
  const targetFile = core.adoptionWorkflowStatePath(target.top, request.sessionId);
  const targetState = core.classifyWorkflowBaseline(targetFile, target.top, request.sessionId);
  if (targetState !== core.BASELINE_STATES.PRESENT && targetState !== core.BASELINE_STATES.MISSING) {
    return refusal(REANCHOR_REFUSALS.TARGET_WORKFLOW_UNUSABLE, [`${targetState}: ${targetFile}`]);
  }
  const run = ownedAutopilotRun(recordedRoot, request.sessionId, request.bashPath);
  if (run.state === 'open') return refusal(REANCHOR_REFUSALS.WORKFLOW_IN_PROGRESS, [run.detail]);
  if (run.state !== 'none') return refusal(REANCHOR_REFUSALS.AUTOPILOT_UNVERIFIABLE, [run.detail]);
  const claims = liveClaims({
    environment: request.environment,
    recordsDir: request.recordsDir,
    sessionId: request.sessionId,
    worktrees,
    targetRoot: target.top,
    nowMs: typeof request.nowMs === 'number' ? request.nowMs : Date.now(),
    idleMs: worktreeKeep.idleMsFromHours(request.worktreeKeepIdleHours),
  });
  if (claims.conflicts.length > 0) return refusal(REANCHOR_REFUSALS.CLAIMED, claims.conflicts.map(describeClaim));
  if (claims.unverifiable.length > 0) return refusal(REANCHOR_REFUSALS.LIVE_SESSIONS_UNVERIFIABLE, claims.unverifiable);
  return {
    ok: true,
    context,
    recordedRoot,
    targetRoot: target.top,
    commonDir: target.commonDir,
    requestedDirectory: canonicalOrNull(request.targetDirectory),
    targetDocument: targetState === core.BASELINE_STATES.PRESENT ? 'present' : 'missing',
  };
}

function reanchorVerdict(request) {
  try {
    return verdictUnguarded(request);
  } catch (error) {
    return refusal(REANCHOR_REFUSALS.VERDICT_UNAVAILABLE, [messageOf(error)]);
  }
}

function reanchorReport(request) {
  const verdict = reanchorVerdict(request);
  if (verdict.ok !== true) return verdict;
  return { ...verdict, uncommitted: uncommittedPaths(verdict.targetRoot) };
}

function repositoryLockKey(commonDir) {
  const digest = crypto.createHash('sha256').update(commonDir === null ? '' : commonDir).digest('hex');
  return `reanchor-${commonDir === null ? 'unresolved' : digest}`;
}

function stamp(ms) {
  return new Date(ms).toISOString().replace(/[^0-9TZ]/g, '');
}

function recordHistory(projectRoot, sessionId, reason, ts) {
  try {
    core.mutateWorkflowState({
      projectRoot,
      sessionId,
      actor: 'main-v1',
      workflowState: REANCHOR_WORKFLOW_STATE,
      event: REANCHOR_WORKFLOW_EVENT,
    }, (state) => {
      const history = Array.isArray(state.history) ? state.history : [];
      history.push({ step: '', phase: REANCHOR_HISTORY_PHASE, ts, reason });
      state.history = history;
      return state;
    });
    return { provenance: 'recorded', cause: null };
  } catch (error) {
    return { provenance: 'unavailable', cause: messageOf(error) };
  }
}

function moveKeepAnchor(request, from, to, key, nowMs) {
  if (request.worktreeKeep !== true) return { state: 'disabled', faults: [] };
  const idleHours = Number(request.worktreeKeepIdleHours);
  const input = (cwd, extra) => ({
    cwd,
    sessionKey: key,
    nowMs,
    idleMs: worktreeKeep.idleMsFromHours(idleHours),
    idleHours,
    ...extra,
  });
  const faults = [];
  let started = null;
  try {
    faults.push(...(worktreeKeep.run('session-end', input(from)).faults || []));
  } catch (error) {
    faults.push(`session-end: ${messageOf(error)}`);
  }
  try {
    started = worktreeKeep.run('session-start', input(to, { source: 'startup' }));
    faults.push(...(started.faults || []));
  } catch (error) {
    faults.push(`session-start: ${messageOf(error)}`);
  }
  if (started === null) return { state: 'fault', faults };
  if (!started.managed) return { state: 'not a managed worktree', faults };
  return { state: faults.length > 0 ? 'moved with faults' : 'moved', faults };
}

function realDirectory(file) {
  try {
    const stat = fs.lstatSync(file);
    return stat.isDirectory() && !stat.isSymbolicLink();
  } catch {
    return false;
  }
}

function regularOrAbsent(file) {
  try {
    const stat = fs.lstatSync(file);
    return stat.isFile() ? 'file' : 'other';
  } catch (error) {
    return error && error.code === 'ENOENT' ? 'absent' : 'other';
  }
}

function moveSessionMarkers(from, to, key) {
  const moved = [];
  const faults = [];
  const stateDirectories = [from, to].every((root) => realDirectory(path.join(root, '.zensu'))
    && realDirectory(path.join(root, '.zensu', 'state')));
  for (const kind of SESSION_MARKERS) {
    const name = `${kind}-${key}.json`;
    const source = path.join(from, '.zensu', 'state', name);
    const destination = path.join(to, '.zensu', 'state', name);
    const sourceShape = regularOrAbsent(source);
    if (sourceShape === 'absent') continue;
    if (!stateDirectories) {
      faults.push(`${kind}: a state directory is not a plain directory`);
      continue;
    }
    if (sourceShape !== 'file' || regularOrAbsent(destination) === 'other') {
      faults.push(`${kind}: the marker is not a regular file`);
      continue;
    }
    try {
      fs.renameSync(source, destination);
      moved.push(kind);
    } catch (error) {
      faults.push(`${kind}: ${error && error.code ? error.code : 'not moved'}`);
    }
  }
  return { moved, faults };
}

function performReanchor(request, deps) {
  const now = deps && typeof deps.now === 'function' ? deps.now : () => Date.now();
  let swapped;
  try {
    const location = core.contextRecordLocation(request);
    const probed = worktreeIdentity(request.targetDirectory);
    const repositoryKey = repositoryLockKey(probed === null ? null : probed.commonDir);
    swapped = core.withFileLock(location.locksDir, repositoryKey, () => core.withFileLock(location.locksDir, location.key, () => {
      const verdict = reanchorVerdict(request);
      if (!verdict.ok) return { refused: verdict };
      if (repositoryLockKey(verdict.commonDir) !== repositoryKey) {
        throw new Error('session-reanchor-v1: the target\'s repository changed while the move was being prepared');
      }
      if (canonicalOrNull(verdict.targetRoot) !== verdict.targetRoot) {
        throw new Error('session-reanchor-v1: the verified worktree no longer resolves to itself');
      }
      const baseline = verdict.targetDocument === 'missing'
        ? core.initializeWorkflowStateDetailed({ projectRoot: verdict.targetRoot, sessionId: request.sessionId })
        : { created: false };
      const next = core.buildContext({
        host: verdict.context.host,
        sessionId: request.sessionId,
        projectRoot: verdict.targetRoot,
        pluginRoot: verdict.context.plugin_root,
        pluginData: location.pluginData,
        createdAt: verdict.context.created_at,
      });
      if (next.project_root !== verdict.targetRoot) {
        throw new Error('session-reanchor-v1: the re-minted record would name a different directory than the verified worktree');
      }
      for (const field of ['plugin_root', 'plugin_data', 'plugin_version', 'runtime_digest', 'source_revision', 'session_id_hash', 'created_at']) {
        if (next[field] !== verdict.context[field]) {
          throw new Error(`session-reanchor-v1: the re-minted record would change ${field}`);
        }
      }
      const supersededFile = path.join(location.recordsDir, `${location.key}.superseded-reanchor-${stamp(now())}.json`);
      core.supersedeContextRecord(location.file, supersededFile, next);
      return { verdict, location, supersededFile, documentCreated: baseline.created === true };
    }));
  } catch (error) {
    return { ok: false, failed: true, cause: messageOf(error) };
  }
  if (swapped.refused) return { ok: false, verdict: swapped.refused };
  const from = swapped.verdict.recordedRoot;
  const to = swapped.verdict.targetRoot;
  const nowMs = now();
  const ts = new Date(nowMs).toISOString();
  const reason = `${REANCHOR_HISTORY_REASON_PREFIX}${from} -> ${to}`;
  const provenance = recordHistory(to, request.sessionId, reason, ts);
  const previous = recordHistory(from, request.sessionId, reason, ts);
  const leases = sweep.discardSupersededLeases(
    swapped.location.pluginData,
    swapped.location.key,
    canonicalOrNull(request.executingPluginRoot) || request.executingPluginRoot,
    to,
  );
  const keep = moveKeepAnchor(request, from, to, swapped.location.key, nowMs);
  const markers = moveSessionMarkers(from, to, swapped.location.key);
  return {
    ok: true,
    previousRoot: from,
    projectRoot: to,
    supersededFile: swapped.supersededFile,
    documentCreated: swapped.documentCreated,
    provenance: provenance.provenance,
    provenanceCause: provenance.cause,
    previousProvenance: previous.provenance,
    previousProvenanceCause: previous.cause,
    leases,
    keep,
    markers,
  };
}

function renderRefusal(verdict) {
  let text = `Zensu session re-anchor — NOT MOVABLE (${safe(verdict.reason)})\n\n`;
  text += `${REANCHOR_REMEDY[verdict.reason] || REANCHOR_REMEDY[REANCHOR_REFUSALS.VERDICT_UNAVAILABLE]}\n`;
  for (const line of verdict.detail || []) text += `  - ${safe(line)}\n`;
  text += 'Nothing was changed.\n';
  return text;
}

function renderReanchorVerdict(verdict, confirmed) {
  if (!verdict || verdict.ok !== true) {
    return { text: renderRefusal(verdict || refusal(REANCHOR_REFUSALS.VERDICT_UNAVAILABLE)), code: 1, proceed: false };
  }
  if (confirmed) return { text: '', code: 0, proceed: true };
  let text = 'Zensu session re-anchor — MOVABLE\n\n';
  text += row('recorded root', safe(verdict.recordedRoot));
  text += row('new anchor', safe(verdict.targetRoot));
  text += row('workflow document', verdict.targetDocument === 'present'
    ? 'already present under the new anchor'
    : 'created under the new anchor by --confirm');
  if (Array.isArray(verdict.uncommitted)) {
    const count = verdict.uncommitted.length;
    text += row('uncommitted', `${count} path${count === 1 ? '' : 's'}${count > 0 ? ', file names as git status reports them, each in quotes' : ''}`);
    for (const entry of verdict.uncommitted.slice(0, MAX_LISTED_PATHS)) text += `    ${quoted(entry)}\n`;
    if (count > MAX_LISTED_PATHS) text += `    … ${count - MAX_LISTED_PATHS} more\n`;
  } else {
    text += row('uncommitted', 'unknown (git status failed)');
  }
  text += '\nThe new anchor is a registered worktree of the same repository as the recorded root,\n';
  text += 'and no other registered worktree lies inside it. No other live session was found that\n';
  text += 'started in it, is anchored in it, or keeps a worktree-keep anchor in it. Live sessions\n';
  text += 'are found through this Claude Code configuration\'s live-session registry, their Session\n';
  text += 'Control records and worktree-keep anchors. A session that only edits files there by\n';
  text += 'absolute path, or that none of these sources shows, is not detected: read the uncommitted\n';
  text += 'paths above before you confirm.\n';
  text += '\n--confirm re-mints this session\'s Session Control record with the new project root and\n';
  text += 'nothing else changed, and sets the previous record aside unchanged. From the next tool\n';
  text += 'call the source-write gate, the reviewer confinement and the zensu-log.sh workflow verbs\n';
  text += 'anchor on the new worktree, and the recorded root is outside this session from then on.\n';
  text += 'The host does not move: it keeps this session\'s start directory, and the Bash tool\n';
  text += 'returns there after a command that leaves it, so give your own commands a leading cd into\n';
  if (unpastableRoot(verdict.targetRoot)) {
    text += 'the new worktree, with its path in single quotes. That path holds a double quote, a dollar\n';
    text += 'sign, a backtick or a backslash, which zensu-log.sh --project-root refuses, so /zensu:tdd,\n';
    text += '/zensu:self-review, /zensu:converge and /zensu:verify-feature --chain cannot run there:\n';
    text += 'move the worktree to a path without these characters before you start a chain there.\n';
  } else {
    text += 'the new worktree. /zensu:tdd, /zensu:self-review, /zensu:converge and /zensu:verify-feature\n';
    text += '--chain read the anchor from zensu-log.sh --project-root and run their commands inside it,\n';
    text += 'and --evidence-run runs there too, so a new /zensu:tdd chain can start in this session.\n';
  }
  text += '/zensu:plan-review, /zensu:setup, /zensu:cover, /zensu:autopilot and /zensu:pilot still\n';
  text += 'read plans, config, overlays and templates from the start directory. The workflow\n';
  text += 'document under the recorded root stays where it is; review-evidence leases bound to it\n';
  text += 'are set aside, and this session\'s tdd-mode, delivery-route and zen-mode markers move\n';
  text += 'with the anchor.\n';
  text += '\nNothing has been changed. Run the same command with --confirm to move the anchor.\n';
  return { text, code: 0, proceed: false };
}

function renderReanchorOutcome(outcome) {
  if (!outcome || outcome.ok !== true) {
    if (outcome && outcome.verdict) return { text: renderRefusal(outcome.verdict), code: 1 };
    let text = 'Zensu session re-anchor — FAILED\n\n';
    text += row('cause', safe(outcome && outcome.cause ? outcome.cause : 'unknown'));
    text += '\nThe move did not complete. Run /zensu:doctor before resuming: it reports which project\n';
    text += 'root this session is bound to now.\n';
    return { text, code: 1 };
  }
  const leases = outcome.leases || { discarded: 0, failed: [] };
  const stuck = Array.isArray(leases.failed) ? leases.failed : [];
  const leaseScope = typeof leases.unsafe === 'string' ? leases.unsafe : '';
  const leaseFault = stuck.length > 0 || leaseScope !== '';
  let text = `Zensu session re-anchor — MOVED${leaseFault ? ' (lease sweep incomplete)' : ''}\n\n`;
  text += row('previous root', safe(outcome.previousRoot));
  text += row('project', safe(outcome.projectRoot));
  text += row('superseded record', safe(outcome.supersededFile));
  text += row('workflow document', outcome.documentCreated ? 'created' : 'present');
  text += row('provenance', safe(outcome.provenance));
  if (outcome.provenanceCause) text += row('provenance cause', safe(outcome.provenanceCause));
  text += row('previous document', safe(outcome.previousProvenance));
  if (outcome.previousProvenanceCause) text += row('previous cause', safe(outcome.previousProvenanceCause));
  text += row('leases set aside', String(Number(leases.discarded) || 0));
  text += row('leases stuck', String(stuck.length));
  for (const name of stuck) text += row('stuck lease', safe(name));
  if (leaseScope !== '') text += row('lease store', `not swept (${safe(leaseScope)})`);
  if (leaseScope !== '' && leases.unsafeAt) text += row('lease store at', safe(leases.unsafeAt));
  text += row('worktree keep', safe(outcome.keep ? outcome.keep.state : 'unknown'));
  for (const fault of (outcome.keep && outcome.keep.faults) || []) text += row('keep fault', safe(fault));
  const markers = outcome.markers || { moved: [], faults: [] };
  text += row('session markers', markers.moved.length > 0 ? `moved (${markers.moved.join(', ')})` : 'none to move');
  for (const fault of markers.faults) text += row('marker fault', safe(fault));
  text += '\nThis session is anchored at the project above from the next tool call onward. The host\n';
  text += 'still returns the Bash tool to this session\'s start directory, so give your own commands a\n';
  if (unpastableRoot(outcome.projectRoot)) {
    text += 'leading cd into the project above, with its path in single quotes. That path holds a double\n';
    text += 'quote, a dollar sign, a backtick or a backslash, which zensu-log.sh --project-root refuses,\n';
    text += 'so /zensu:tdd, /zensu:self-review, /zensu:converge and /zensu:verify-feature --chain cannot\n';
    text += 'run there: move the worktree to a path without these characters before you start a chain\n';
    text += 'there. /zensu:plan-review, /zensu:setup, /zensu:cover, /zensu:autopilot and /zensu:pilot\n';
    text += 'still read plans, config, overlays and templates from the start directory.\n';
  } else {
    text += 'leading cd into the project above. /zensu:tdd, /zensu:self-review, /zensu:converge,\n';
    text += '/zensu:verify-feature --chain and --evidence-run work in the project above, so a new\n';
    text += '/zensu:tdd chain can start in this session. /zensu:plan-review, /zensu:setup,\n';
    text += '/zensu:cover, /zensu:autopilot and /zensu:pilot still read plans, config, overlays and\n';
    text += 'templates from the start directory.\n';
  }
  if (markers.faults.length > 0) {
    text += '\nA session marker that did not move stays under the previous root, where this session no\n';
    text += 'longer reads it. Set that preference again from here.\n';
  }
  if (leaseFault) {
    text += '\nWARNING: the review-evidence lease store of this session was not fully swept. A lease\n';
    text += 'still bound to the previous root fails every review-evidence operation of this session\n';
    text += 'until it is moved out of <plugin_data>/review-evidence/v1/records/<session key>/ by hand.\n';
    text += 'Nothing was deleted. The move itself is complete; do not run it again.\n';
  }
  if (outcome.provenance !== 'recorded' || outcome.previousProvenance !== 'recorded') {
    text += '\nWARNING: the move succeeded but a provenance entry could not be written. The move is real\n';
    text += 'and is not recorded in that workflow history; report this rather than repeating it.\n';
  }
  return { text, code: leaseFault ? 1 : 0 };
}

function main(source) {
  const hookSession = require('./claude-hook-session-v1.js');
  try {
    hookSession.validateSessionId(source.CLAUDE_CODE_SESSION_ID);
  } catch (error) {
    return renderReanchorVerdict(refusal(REANCHOR_REFUSALS.SESSION_ID_UNUSABLE, [messageOf(error)]), false);
  }
  let recordsDir;
  try {
    recordsDir = hookSession.privateRecordsDirectory(source.ZREANCHOR_PLUGIN_DATA);
  } catch (error) {
    return renderReanchorVerdict(refusal(REANCHOR_REFUSALS.STORE_UNSAFE, [messageOf(error)]), false);
  }
  const request = {
    recordsDir,
    sessionId: source.CLAUDE_CODE_SESSION_ID,
    host: 'claude',
    pluginData: source.ZREANCHOR_PLUGIN_DATA,
    executingPluginRoot: source.ZREANCHOR_PLUGIN_ROOT,
    targetDirectory: source.ZREANCHOR_TARGET,
    environment: source,
    worktreeKeep: source.ZREANCHOR_WORKTREE_KEEP === '1',
    worktreeKeepIdleHours: Number(source.ZREANCHOR_WORKTREE_KEEP_IDLE_HOURS),
    bashPath: source.ZREANCHOR_BASH,
  };
  const confirmed = source.ZREANCHOR_CONFIRM === '1';
  const pre = renderReanchorVerdict(confirmed ? reanchorVerdict(request) : reanchorReport(request), confirmed);
  if (!pre.proceed) return pre;
  return renderReanchorOutcome(performReanchor(request));
}

module.exports = {
  REANCHOR_REFUSALS,
  REANCHOR_REMEDY,
  REANCHOR_HISTORY_PHASE,
  REANCHOR_HISTORY_REASON_PREFIX,
  worktreeIdentity,
  registeredWorktrees,
  owningWorktree,
  unpastableRoot,
  liveRegistryDirectory,
  registryClaims,
  anchorClaims,
  liveClaims,
  workflowInProgress,
  ownedAutopilotRun,
  reanchorVerdict,
  reanchorReport,
  performReanchor,
  renderReanchorVerdict,
  renderReanchorOutcome,
  main,
};

if (require.main === module) {
  let result;
  try {
    result = main(process.env);
  } catch (error) {
    result = { text: `zensu:adopt-session --reanchor: ${safe(messageOf(error))}\n`, code: 1 };
  }
  process.stdout.write(result.text);
  process.exitCode = result.code;
}
