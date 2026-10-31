'use strict';

const fs = require('node:fs');
const path = require('node:path');
const childProcess = require('node:child_process');
const { DISPATCHED_CHECKS, REGISTRATION, hostMatcherCovers } = require('./hook-registration-v1.js');
const { msysDrivePrefix } = require('./claude-path-v1.js');

const LIB_DIR = __dirname;
const HOOKS_DIR = path.dirname(LIB_DIR);
const EVENTS = Object.freeze({ pre: 'PreToolUse', post: 'PostToolUse' });
const DECISION_RANK = Object.freeze({ allow: 1, ask: 2, defer: 3, deny: 4 });
const CONTEXT_LIMIT = 10000;
const BUDGET_MS = 55000;
const MIN_DELEGATE_MS = 1000;
const MAX_PAYLOAD_BYTES = 1024 * 1024;
const BINDER_EVENTS = new Set(['SessionStart', 'PreToolUse', 'PostToolUse', 'Stop', 'UserPromptSubmit']);
const ZENSU_WORD = /(?:^|[^A-Za-z0-9_.-])zensu(?![A-Za-z0-9_-])/;
const PAIR = '\u0001';
const ROOT_MISMATCH = 'zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin';
const CAPABILITY_LEAD = 'zensu: reviewer capability gate unavailable: ';
const EDIT_GATE_TOOLS = new Set(['Edit', 'Write', 'MultiEdit']);
const EDIT_GATE_LIBRARIES = Object.freeze([
  'zensu-agent-context.sh',
  'zensu-session.sh',
  'zensu-msys-env.sh',
  'zensu-host-path.sh',
  'zensu-config.sh',
  'zensu-tdd-phase.sh',
  'claude-principal-v1.js',
  'session-control-core-v1.js',
  'state-path-safety-v1.js',
  'edit-path-class-v1.js',
]);
const SPAWN_GRANT_SOURCED = Object.freeze([
  'zensu-agent-context.sh',
  'zensu-session.sh',
  'zensu-host-path.sh',
  'zensu-config.sh',
]);
const SPAWN_GRANT_GUARDED = Object.freeze([
  'zensu-msys-env.sh',
  'claude-principal-v1.js',
  'reviewer-spawn-allow-v1.js',
]);

const REGISTRY = DISPATCHED_CHECKS;

function silent() {
  return { kind: 'output', output: null };
}

function emitted(output) {
  return { kind: 'output', output };
}

function blocked(message) {
  return { kind: 'block', message };
}

function denyOutput(reason) {
  return {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  };
}

function shellInput(text) {
  return text.replace(/\0/g, '').replace(/\n+$/, '');
}

function parseObject(text) {
  try {
    return JSON.parse(text || '{}');
  } catch (_error) {
    return undefined;
  }
}

function hostDirectory(value, base) {
  if (typeof value !== 'string' || value === '' || /[\r\n]/.test(value)) return null;
  const spelled = path.resolve(base, msysDrivePrefix(value));
  try {
    const stat = fs.lstatSync(spelled);
    if (stat.isSymbolicLink() || !stat.isDirectory()) return null;
    return fs.realpathSync.native(spelled);
  } catch (_error) {
    return null;
  }
}

function enteredDirectory(value, base) {
  if (typeof value !== 'string' || value === '' || /[\r\n]/.test(value)) return null;
  try {
    const resolved = fs.realpathSync.native(path.resolve(base, msysDrivePrefix(value)));
    return fs.statSync(resolved).isDirectory() ? resolved : null;
  } catch (_error) {
    return null;
  }
}

function rootVerdict(environment, hookCwd) {
  let executing = null;
  try {
    executing = fs.realpathSync.native(path.resolve(LIB_DIR, '..', '..'));
  } catch (_error) {
    return { executing: null, declared: 'unset' };
  }
  const declared = environment.CLAUDE_PLUGIN_ROOT;
  if (typeof declared !== 'string' || declared === '') return { executing, declared: 'unset' };
  const resolved = enteredDirectory(declared, hookCwd);
  if (resolved === null) return { executing, declared: 'unreadable' };
  return { executing, declared: resolved === executing ? 'match' : 'mismatch' };
}

function rootFailure(context) {
  const root = context.root;
  if (root.executing === null) return blocked('');
  if (root.declared === 'unreadable' || root.declared === 'mismatch') return blocked(ROOT_MISMATCH);
  return null;
}

function readConfigFile(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_error) {
    return {};
  }
}

function mergeConfig(base, overlay) {
  if (overlay === null || typeof overlay !== 'object' || Array.isArray(overlay)) return overlay;
  const merged = base && typeof base === 'object' && !Array.isArray(base) ? Object.assign({}, base) : {};
  for (const key of Object.keys(overlay)) {
    if (key === '__proto__' || key === 'constructor' || key === 'prototype') continue;
    merged[key] = Object.prototype.hasOwnProperty.call(merged, key) ? mergeConfig(merged[key], overlay[key]) : overlay[key];
  }
  return merged;
}

function effectiveConfig(environment, base) {
  const at = (value) => path.resolve(base, msysDrivePrefix(value));
  if (environment.ZENSU_CONFIG) return readConfigFile(at(environment.ZENSU_CONFIG));
  const global = readConfigFile(at(`${environment.HOME || ''}/.zensu/config.json`));
  const projectDir = environment.CLAUDE_PROJECT_DIR;
  const project = projectDir ? readConfigFile(at(`${projectDir}/.zensu/config.json`)) : {};
  return mergeConfig(global, project);
}

function configHookEnabled(key, environment, base) {
  try {
    const config = effectiveConfig(environment, base);
    return !(config.hooks && config.hooks[key] === false);
  } catch (_error) {
    return true;
  }
}

function configHookOptedIn(key, environment, base) {
  try {
    const config = effectiveConfig(environment, base);
    return Boolean(config.hooks && config.hooks[key] === true);
  } catch (_error) {
    return false;
  }
}

function configHookEnabledStrict(key, environment, base) {
  const inputs = [environment.ZENSU_CONFIG, environment.HOME, environment.CLAUDE_PROJECT_DIR];
  if (inputs.some((value) => /[\r\n]/.test(value || ''))) return false;
  const at = (value) => path.resolve(base, msysDrivePrefix(value));
  const candidates = environment.ZENSU_CONFIG
    ? [environment.ZENSU_CONFIG]
    : [
      environment.HOME ? `${environment.HOME}/.zensu/config.json` : '',
      environment.CLAUDE_PROJECT_DIR ? `${environment.CLAUDE_PROJECT_DIR}/.zensu/config.json` : '',
    ].filter(Boolean);
  if (candidates.length === 0) return false;
  for (const candidate of candidates) {
    const file = at(candidate);
    try {
      fs.statSync(file);
    } catch (error) {
      if (error && error.code === 'ENOENT') continue;
      return false;
    }
    let value;
    try {
      value = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (_error) {
      return false;
    }
    if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
    const hooks = value.hooks;
    if (hooks === undefined) continue;
    if (!hooks || typeof hooks !== 'object' || Array.isArray(hooks)) return false;
    if (hooks[key] === false) return false;
  }
  return true;
}

function libraryScan(text) {
  const scan = text
    .replace(/\\\\/g, PAIR)
    .replace(/\u0001\\r\\n/g, '')
    .replace(/\u0001\\n/g, '')
    .replace(/["'\\`\u0001]/g, '');
  return scan === '' ? text : scan;
}

function fallbackScan(text) {
  return text.replace(/\\[nrt]/g, '').replace(/["'\\`]/g, '');
}

function foldings(text) {
  return [text.replace(/[A-Z]+/g, (letters) => letters.toLowerCase()), text.toLowerCase()];
}

function consentMarked(input) {
  const texts = [input, libraryScan(input), fallbackScan(input)].flatMap(foldings);
  if (texts.some((text) => text.includes('playwright') || text.includes('zensu-verify'))) return true;
  const powershell = foldings(input).some((text) => text.includes('"tool_name":"powershell"') || text.includes('"tool_name": "powershell"'));
  return powershell && texts.some((text) => text.includes('wright') || text.includes('verify') || text.includes('u{'));
}

function binderPayloadValid(input) {
  if (input.length === 0 || Buffer.byteLength(input, 'utf8') > MAX_PAYLOAD_BYTES) return false;
  let payload;
  try {
    payload = JSON.parse(input);
  } catch (_error) {
    return false;
  }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return false;
  if (payload.hook_event_name !== undefined && !BINDER_EVENTS.has(payload.hook_event_name)) return false;
  const sessionId = payload.session_id;
  if (typeof sessionId !== 'string' || sessionId.trim() === '' || sessionId.length > 4096 || /[\0\r\n]/.test(sessionId)) return false;
  return !/^(?:scv1_[a-f0-9]{64}|sha256:[a-f0-9]{64})$/.test(sessionId);
}

function regularFile(file) {
  try {
    const stat = fs.lstatSync(file);
    return stat.isFile() && !stat.isSymbolicLink();
  } catch (_error) {
    return false;
  }
}

function regularTarget(file) {
  try {
    return fs.statSync(file).isFile();
  } catch (_error) {
    return false;
  }
}

function sessionBinding(context) {
  if (context.binding !== undefined) return context.binding;
  if (!context.data.ok || context.root.executing === null || context.parsed === undefined) {
    context.binding = { error: new Error('the hook session cannot be bound') };
    return context.binding;
  }
  try {
    const hookSession = require('./claude-hook-session-v1.js');
    context.binding = { value: hookSession.resolveHookSession(context.parsed, process.env, { autoAdopt: true }) };
  } catch (error) {
    context.binding = { error };
  }
  return context.binding;
}

function shellBinding(context, options = {}) {
  if (/[\r\n]/.test(context.environment.MSYS2_ENV_CONV_EXCL || '')) return null;
  if (!binderPayloadValid(context.input)) return null;
  if (!regularFile(path.join(LIB_DIR, 'claude-hook-session-v1.js'))) return null;
  const outcome = sessionBinding(context);
  const hookSession = require('./claude-hook-session-v1.js');
  if (!context.disclosed && !options.quiet) {
    context.disclosed = true;
    const source = outcome.error || outcome.value;
    const performed = outcome.error ? hookSession.performedAdoption(outcome.error) : (outcome.value.adoption || null);
    if (performed) hookSession.writeAdoptionOperatorLine(performed);
    hookSession.writeServedSweepLine(source && source.servedSweep);
  }
  if (outcome.error) return null;
  const binding = outcome.value;
  const values = [binding.pluginRoot, binding.sessionKey, binding.contextFile, binding.context.runtime_digest, binding.projectRoot];
  if (values.some((value) => typeof value !== 'string' || /[\0\r\n]/.test(value))) return null;
  return binding;
}

function boundProjectDir(binding) {
  const core = require('./session-control-core-v1.js');
  const { projectRoot, contextFile, sessionKey } = binding;
  if (!projectRoot || !contextFile || !sessionKey) return null;
  try {
    const rootStat = fs.lstatSync(projectRoot);
    if (rootStat.isSymbolicLink() || !rootStat.isDirectory()) return null;
    if (core.sessionKey(sessionKey) !== sessionKey) return null;
    const recordFile = path.resolve(contextFile);
    if (path.basename(recordFile) !== `${sessionKey}.json`) return null;
    const recordStat = fs.lstatSync(recordFile);
    if (!recordStat.isFile() || recordStat.isSymbolicLink() || recordStat.nlink !== 1) return null;
    if (fs.realpathSync.native(recordFile) !== recordFile) return null;
    const requested = path.resolve(projectRoot);
    const canonical = fs.realpathSync.native(requested);
    if (requested !== canonical || binding.context.project_root !== canonical) return null;
    return canonical;
  } catch (_error) {
    return null;
  }
}

function bashForDelegates(environment) {
  if (process.platform !== 'win32') return 'bash';
  const usable = (candidate) => {
    if (typeof candidate !== 'string' || !path.win32.isAbsolute(candidate)) return false;
    if (!['bash.exe', 'sh.exe', 'bash', 'sh'].includes(path.win32.basename(candidate).toLowerCase())) return false;
    try {
      return fs.statSync(candidate).isFile();
    } catch (_error) {
      return false;
    }
  };
  const candidates = [
    environment.SHELL,
    environment.CLAUDE_CODE_GIT_BASH_PATH,
    'C:\\Program Files\\Git\\bin\\bash.exe',
    'C:\\Program Files (x86)\\Git\\bin\\bash.exe',
  ];
  for (const directory of String(environment.PATH || environment.Path || '').split(path.win32.delimiter)) {
    if (directory && fs.existsSync(path.win32.join(directory, 'git.exe'))) {
      candidates.push(path.win32.join(directory, '..', 'bin', 'bash.exe'));
    }
  }
  return candidates.find(usable) || null;
}

function delegate(context, check) {
  const shell = bashForDelegates(context.environment);
  if (shell === null) return { kind: 'error', message: 'Git Bash was not found' };
  if (check.body === null) return { kind: 'error', message: 'the check has no shell body' };
  const script = path.join(HOOKS_DIR, ...check.body.split('/'));
  const result = childProcess.spawnSync(shell, [process.platform === 'win32' ? script.split(path.sep).join('/') : script], {
    input: context.raw,
    env: context.environment,
    cwd: context.hookCwd,
    maxBuffer: 64 * 1024 * 1024,
    timeout: Math.max(MIN_DELEGATE_MS, context.deadline - Date.now()),
    windowsHide: true,
  });
  if (result.error) return { kind: 'error', message: result.error.message, stdout: result.stdout, stderr: result.stderr };
  if (result.status === null) return { kind: 'error', message: `stopped by ${result.signal}`, stdout: result.stdout, stderr: result.stderr };
  return { kind: 'delegate', status: result.status, stdout: result.stdout, stderr: result.stderr };
}

function runCapability(context) {
  const root = context.root;
  if (root.executing === null) return blocked(`${CAPABILITY_LEAD}cannot resolve the plugin root above this hook`);
  if (root.declared === 'unreadable') return blocked(`${CAPABILITY_LEAD}CLAUDE_PLUGIN_ROOT names no readable directory; start a fresh Claude Code session`);
  if (root.declared === 'mismatch') return blocked(`${CAPABILITY_LEAD}CLAUDE_PLUGIN_ROOT names another plugin installation than the one running this hook; start a fresh Claude Code session`);
  const policyFile = path.join(LIB_DIR, 'reviewer-capability-v1.js');
  if (!regularTarget(policyFile)) return blocked(`${CAPABILITY_LEAD}the policy module hooks/lib/reviewer-capability-v1.js is missing; reinstall the plugin`);
  if (/[\r\n]/.test(root.executing)) return blocked(`${CAPABILITY_LEAD}cannot convert the plugin root into a path node can open`);
  if (!context.data.ok) return blocked(`${CAPABILITY_LEAD}cannot convert CLAUDE_PLUGIN_DATA into a path node can open`);
  const policy = require('./reviewer-capability-v1.js');
  return emitted(policy.evaluate(context.raw, () => {
    const outcome = sessionBinding(context);
    if (outcome.error) throw outcome.error;
    return outcome.value;
  }));
}

function runCliGate(context, check) {
  const failure = rootFailure(context);
  if (failure) return failure;
  const payload = parseObject(context.input);
  let command = '';
  let powershell = false;
  try {
    if (payload.tool_input && typeof payload.tool_input.command === 'string') command = payload.tool_input.command;
    powershell = payload.tool_name === 'PowerShell';
  } catch (_error) {
    return silent();
  }
  if (!command || (!powershell && !ZENSU_WORD.test(command))) return silent();
  return delegate(context, check);
}

function runSourceWrite(context, check) {
  const failure = rootFailure(context);
  if (failure) return failure;
  let reason;
  try {
    reason = require('./bash-source-write-parse.js').controlVerdict(`${context.input}\n`);
  } catch (_error) {
    return emitted(denyOutput('Zensu could not validate protected Session Control bindings; retry in a fresh session.'));
  }
  if (reason) return emitted(denyOutput(reason));
  if (!configHookOptedIn('bashWriteGate', context.environment, context.hookCwd)) return silent();
  return delegate(context, check);
}

function secretScanDeny(rules, input) {
  const payload = parseObject(input);
  let tool = '';
  try {
    tool = String(payload.tool_name || '');
  } catch (_error) {
    tool = '';
  }
  const whole = tool === 'PowerShell'
    ? 'A PowerShell command is scanned as a whole, because this check does not trace where PowerShell writes; ' +
      'a value that only passes through a command and is never written to a file can go through the Bash tool, ' +
      'which scans only commands that write. '
    : '';
  return denyOutput(
    'Blocked: the payload matches secret pattern(s): ' + rules + '. ' + whole +
    'Real-looking credentials must not land in files. Legitimate fixture options: ' +
    'for the Write/Edit tools, place it under a test(s)/, __tests__/, spec(s)/, testdata/, ' +
    'evals/ or fixtures/ path or an *.example.* file; on any channel, append the ' +
    'zensu-secret-allow marker to that line or use an obvious placeholder (EXAMPLE, ' +
    'YOUR_...). Prefer the surgical, auditable escape (the allow marker, visible in ' +
    'the diff) over disabling the gate. A blanket opt-out exists but is documented in ' +
    'docs/gates.md (§ Secret Scan) rather than inlined here, so turning the whole gate ' +
    'off stays a deliberate, human choice.',
  );
}

function secretScanSkipsBash(input) {
  if (!input.includes('"tool_name":"Bash"')) return false;
  const first = input.indexOf('"tool_name"');
  const repeated = first !== -1 && input.indexOf('"tool_name"', first + '"tool_name"'.length) !== -1;
  const sed = input.indexOf('sed');
  const sedInPlace = sed !== -1 && input.indexOf('-i', sed + 3) !== -1;
  return !(input.includes('>') || input.includes('<<') || input.includes('tee') || input.includes('of=')
    || input.includes('\\u') || sedInPlace || repeated);
}

function runSecretScan(context, check) {
  const failure = rootFailure(context);
  if (failure) return failure;
  if (shellBinding(context) === null) return delegate(context, check);
  if (!configHookEnabled('secretScan', context.environment, context.hookCwd)) return silent();
  if (context.environment.ZENSU_SECRET_SCAN === 'off') return delegate(context, check);
  if (context.input === '') return silent();
  if (secretScanSkipsBash(context.input)) return silent();
  let verdict;
  try {
    verdict = require('./secret-scan-decide.js').decide(context.input);
  } catch (_error) {
    process.stderr.write('zensu secret-scan: scanner error (rc=1), failing open\n');
    return silent();
  }
  if (verdict === '__bypass__:ZENSU_SECRET_SCAN') return delegate(context, check);
  if (!verdict) return silent();
  return emitted(secretScanDeny(verdict, context.input));
}

function runConsent(context, check) {
  if (!consentMarked(context.input)) return silent();
  return delegate(context, check);
}

function runWorkOrder(context, check) {
  if (!context.environment.ZENSU_SESSION_TOKEN) return silent();
  return delegate(context, check);
}

function mainPrincipal(input, eventName) {
  try {
    const payload = JSON.parse(input || '{}');
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return false;
    if (payload.hook_event_name !== eventName) return false;
    return require('./claude-principal-v1.js').classifyPreToolPayload(payload) === 'main-v1';
  } catch (_error) {
    return false;
  }
}

function runDataGuard(context) {
  const root = context.root;
  if (root.executing === null) return blocked('zensu: plugin-data guard cannot resolve its own plugin root');
  const failure = rootFailure(context);
  if (failure) return failure;
  if (!regularFile(path.join(LIB_DIR, 'plugin-data-guard-v1.js'))) {
    process.stderr.write('zensu: plugin-data guard did not run (decision module absent or symlinked) — writes into the plugin data store are unguarded\n');
    return silent();
  }
  const guard = require('./plugin-data-guard-v1.js');
  const environment = context.environment;
  const outcome = guard.hostOutcome(guard.decide({
    payload: guard.payloadFromRaw(`${context.input}\n`, false),
    pluginData: environment.CLAUDE_PLUGIN_DATA || '',
    cwd: context.only ? environment.ZENSU_GUARD_CALLER_CWD || '' : context.hookCwd,
    projectRoot: environment.CLAUDE_PROJECT_DIR || '',
  }));
  for (const note of outcome.notes) process.stderr.write(note);
  return emitted(outcome.output);
}

function editGateAllows(context) {
  if (!EDIT_GATE_LIBRARIES.every((name) => regularFile(path.join(LIB_DIR, name)))) return false;
  if (!mainPrincipal(context.input, 'PreToolUse')) return true;
  const binding = shellBinding(context);
  if (binding === null) return false;
  const payload = JSON.parse(context.input);
  if (!EDIT_GATE_TOOLS.has(payload.tool_name)) return true;
  if (context.environment.ZENSU_TDD_GATE === 'off') return false;
  const project = boundProjectDir(binding);
  if (project === null) return false;
  const stateDirectory = path.join(project, '.zensu', 'state');
  if (!regularFile(path.join(stateDirectory, `tdd-phase-${binding.sessionKey}.json`))) return false;
  const core = require('./session-control-core-v1.js');
  const state = core.readWorkflowState({ projectRoot: project, sessionId: binding.sessionKey });
  if (state.active !== true) return true;
  if (state.vanilla !== true) return false;
  const input = payload.tool_input;
  const spelled = input && typeof input === 'object' && typeof input.file_path === 'string' ? input.file_path : '';
  if (/[\0\r\n]/.test(spelled)) return false;
  if (process.platform === 'win32' && /^[\\/]/.test(spelled)) return false;
  const absolute = /^(?:\/|[A-Za-z]:[\\/]|\\\\)/.test(spelled) ? spelled : `${project}/${spelled}`;
  return require('./edit-path-class-v1.js').editPathClass(absolute, stateDirectory) !== 'state';
}

function runEditGate(context, check) {
  const failure = rootFailure(context);
  if (failure) return failure;
  let allowed = false;
  try {
    allowed = editGateAllows(context);
  } catch (_error) {
    allowed = false;
  }
  return allowed ? silent() : delegate(context, check);
}

function spawnGrantLibrariesPresent(directory) {
  return SPAWN_GRANT_SOURCED.every((name) => regularTarget(path.join(directory, name)))
    && SPAWN_GRANT_GUARDED.every((name) => regularFile(path.join(directory, name)));
}

function spawnPayload(context) {
  const { MAX_PAYLOAD_BYTES: limit } = require('./reviewer-spawn-allow-v1.js');
  return context.raw.subarray(0, limit + 1).toString('utf8').replace(/\0/g, '');
}

function runSpawnGrant(context) {
  const root = context.root;
  if (root.declared === 'unreadable' || root.declared === 'mismatch') {
    process.stderr.write(`${ROOT_MISMATCH}\n`);
    return silent();
  }
  if (root.executing === null) return silent();
  try {
    if (!spawnGrantLibrariesPresent(LIB_DIR)) return silent();
    const decision = require('./reviewer-spawn-allow-v1.js').decide(spawnPayload(context));
    if (decision === '') return silent();
    if (!mainPrincipal(context.input, 'PreToolUse')) return silent();
    if (shellBinding(context, { quiet: true }) === null) return silent();
    if (!configHookEnabledStrict('reviewerSpawnAutoAllow', context.environment, context.hookCwd)) return silent();
    return emitted(JSON.parse(decision));
  } catch (_error) {
    return silent();
  }
}

function sweepArtifacts(mod, project, input) {
  let job;
  try {
    job = JSON.parse(input);
  } catch (_error) {
    return;
  }
  const tool = typeof job.tool_name === 'string' ? job.tool_name : '';
  const writeTool = tool === 'Edit' || tool === 'Write' || tool === 'MultiEdit';
  if (tool !== 'Bash' && tool !== 'PowerShell' && !writeTool) return;
  const named = writeTool && job.tool_input && typeof job.tool_input.file_path === 'string'
    ? job.tool_input.file_path : '';
  const sweep = mod.sweepTargets(project);
  if (sweep.fallback) {
    process.stderr.write('zensu: artifact sweep not scoped by git (' + sweep.fallback
      + ') — artifacts git reports unchanged are swept too\n');
  }
  const seen = new Set();
  const targets = [];
  const entries = named
    ? [{ p: named, named: true }, ...sweep.targets.map((p) => ({ p, named: false }))]
    : sweep.targets.map((p) => ({ p, named: false }));
  for (const entry of entries) {
    const key = path.resolve(project, entry.p);
    if (seen.has(key)) continue;
    seen.add(key);
    targets.push(entry);
  }
  for (const entry of targets) {
    let result;
    try {
      result = mod.redactFile(entry.p, {
        projectRoot: [project, process.env.CLAUDE_PROJECT_DIR || ''].filter(Boolean),
        expectedRoot: project,
        base: project,
      });
    } catch (err) {
      process.stderr.write('zensu: artifact redaction threw for ' + entry.p + ' (' + (err && err.code) + ')\n');
      continue;
    }
    if (mod.CLEAN_REASONS.has(result.reason)) continue;
    if (mod.TRANSIENT_REASONS.has(result.reason)) continue;
    if (entry.named && mod.NON_ARTIFACT_REASONS.has(result.reason)) continue;
    process.stderr.write('zensu: artifact left UNREDACTED'
      + (entry.named ? '' : ' (sweep)') + ' — ' + entry.p + ' (' + result.reason + ')\n');
  }
}

function runRedact(context) {
  const failure = rootFailure(context);
  if (failure) return failure;
  if (!mainPrincipal(context.input, 'PostToolUse')) return silent();
  const binding = shellBinding(context);
  if (binding === null) {
    process.stderr.write('zensu: artifact redactor unavailable (session bind refused) — .zensu artifacts are not redacted for this call\n');
    return silent();
  }
  const moduleFile = path.join(LIB_DIR, 'zensu-artifact-redact-v1.js');
  if (!regularFile(moduleFile)) {
    process.stderr.write('zensu: artifact redactor unavailable (module path unresolvable)\n');
    return silent();
  }
  const project = boundProjectDir(binding);
  if (project === null) {
    process.stderr.write('zensu: artifact redactor unavailable (no bound project)\n');
    return silent();
  }
  let mod;
  try {
    mod = require(moduleFile);
  } catch (err) {
    process.stderr.write('zensu: artifact redactor unavailable (' + (err && err.code) + ')\n');
    return silent();
  }
  sweepArtifacts(mod, project, context.input);
  return silent();
}

const RUNNERS = Object.freeze({
  'reviewer-capability': runCapability,
  'zensu-cli-gate': runCliGate,
  'source-write-gate': runSourceWrite,
  'secret-scan': runSecretScan,
  'browser-consent': runConsent,
  'work-order-gate': runWorkOrder,
  'reviewer-spawn-allow': runSpawnGrant,
  'plugin-data-guard': runDataGuard,
  'tdd-edit-gate': runEditGate,
  'secret-scan-write': runSecretScan,
  'plugin-data-guard-notebook': runDataGuard,
  'secret-scan-notebook': runSecretScan,
  'artifact-redact': runRedact,
  'browser-consent-recorder': runConsent,
  'work-order-post': runWorkOrder,
  'artifact-redact-write': runRedact,
});

function selectChecks(eventName, tool) {
  return REGISTRY.filter((check) => check.event === eventName
    && hostMatcherCovers(check.matcher, typeof tool === 'string' ? tool : '') === REGISTRATION.REGISTERED);
}

function joined(values, separator) {
  return values.filter((value) => typeof value === 'string' && value !== '').join(separator);
}

function aggregate(outputs, eventName) {
  const present = outputs.filter((output) => output && typeof output === 'object' && !Array.isArray(output));
  if (present.length === 0) return null;
  if (present.length === 1) return present[0];
  let decision = null;
  let reasons = [];
  const contexts = [];
  const messages = [];
  const blockReasons = [];
  const stopReasons = [];
  let block = false;
  let halt = false;
  let suppress = false;
  for (const output of present) {
    const specific = output.hookSpecificOutput && typeof output.hookSpecificOutput === 'object' ? output.hookSpecificOutput : {};
    const candidate = specific.permissionDecision;
    if (Object.prototype.hasOwnProperty.call(DECISION_RANK, candidate)) {
      if (decision === null || DECISION_RANK[candidate] > DECISION_RANK[decision]) {
        decision = candidate;
        reasons = [];
      }
      if (candidate === decision) reasons.push(specific.permissionDecisionReason);
    }
    contexts.push(specific.additionalContext);
    messages.push(output.systemMessage);
    if (output.decision === 'block') {
      block = true;
      blockReasons.push(output.reason);
    }
    if (output.continue === false) {
      halt = true;
      stopReasons.push(output.stopReason);
    }
    if (output.suppressOutput === true) suppress = true;
  }
  const specific = { hookEventName: eventName };
  if (decision !== null) {
    specific.permissionDecision = decision;
    const reason = joined(reasons, '\n\n');
    if (reason) specific.permissionDecisionReason = reason;
  }
  const context = joined(contexts, '\n\n');
  if (context) specific.additionalContext = context.slice(0, CONTEXT_LIMIT);
  const result = {};
  if (Object.keys(specific).length > 1) result.hookSpecificOutput = specific;
  const message = joined(messages, '\n');
  if (message) result.systemMessage = message;
  if (block) {
    result.decision = 'block';
    const reason = joined(blockReasons, '\n\n');
    if (reason) result.reason = reason;
  }
  if (halt) {
    result.continue = false;
    const reason = joined(stopReasons, '\n\n');
    if (reason) result.stopReason = reason;
  }
  if (suppress) result.suppressOutput = true;
  return Object.keys(result).length ? result : null;
}

function buildContext(raw, eventName, environment, hookCwd, only) {
  const text = raw.toString('utf8');
  const input = shellInput(text);
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (_error) {
    parsed = undefined;
  }
  const root = rootVerdict(environment, hookCwd);
  const dataValue = hostDirectory(environment.CLAUDE_PLUGIN_DATA, hookCwd);
  return {
    raw,
    text,
    input,
    parsed: parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : undefined,
    eventName,
    environment,
    hookCwd,
    only,
    root,
    data: { ok: dataValue !== null, value: dataValue },
    deadline: Date.now() + BUDGET_MS,
    binding: undefined,
    disclosed: false,
  };
}

function prepareProcessEnvironment(context) {
  if (context.root.executing !== null) process.env.CLAUDE_PLUGIN_ROOT = context.root.executing;
  if (context.data.ok) process.env.CLAUDE_PLUGIN_DATA = context.data.value;
  try {
    process.chdir(LIB_DIR);
  } catch (_error) {
    return;
  }
}

function runCheck(context, check) {
  try {
    return RUNNERS[check.name](context, check);
  } catch (error) {
    return { kind: 'error', message: error && error.message ? error.message : String(error) };
  }
}

function failureMessage(check, result) {
  if (check.name === 'reviewer-capability') return `${CAPABILITY_LEAD}the policy check exited with status 1`;
  return `zensu: ${check.name} check failed (${result.message || `exit ${result.status}`})`;
}

function writeBuffer(stream, value) {
  if (value && value.length) stream.write(value);
}

function runOnly(context, check) {
  const result = runCheck(context, check);
  if (result.kind === 'output') {
    if (result.output) process.stdout.write(`${JSON.stringify(result.output)}\n`);
    return 0;
  }
  if (result.kind === 'block') {
    if (result.message) process.stderr.write(`${result.message}\n`);
    return 2;
  }
  if (result.kind === 'delegate') {
    writeBuffer(process.stdout, result.stdout);
    writeBuffer(process.stderr, result.stderr);
    return result.status;
  }
  writeBuffer(process.stdout, result.stdout);
  writeBuffer(process.stderr, result.stderr);
  if (check.failure === 'closed') {
    process.stderr.write(`${failureMessage(check, result)}\n`);
    return 2;
  }
  process.stderr.write(`${failureMessage(check, result)}; failing open\n`);
  return 0;
}

function delegatedOutput(result) {
  const text = result.stdout ? result.stdout.toString('utf8').trim() : '';
  if (text === '') return { ok: true, output: null };
  try {
    const output = JSON.parse(text);
    if (output && typeof output === 'object' && !Array.isArray(output)) return { ok: true, output };
  } catch (_error) {
    return { ok: false };
  }
  return { ok: false };
}

function runAll(context) {
  const tool = context.parsed && typeof context.parsed.tool_name === 'string' ? context.parsed.tool_name : '';
  const outputs = [];
  for (const check of selectChecks(context.eventName, tool)) {
    const result = runCheck(context, check);
    if (result.kind === 'output') {
      outputs.push(result.output);
      continue;
    }
    if (result.kind === 'block') {
      if (result.message) process.stderr.write(`${result.message}\n`);
      return { status: 2, outputs };
    }
    writeBuffer(process.stderr, result.stderr);
    if (result.kind === 'delegate' && result.status === 2) return { status: 2, outputs };
    if (result.kind === 'delegate' && result.status === 0) {
      const parsed = delegatedOutput(result);
      if (parsed.ok) {
        outputs.push(parsed.output);
        continue;
      }
    }
    if (check.failure === 'closed') {
      process.stderr.write(`${failureMessage(check, result)}\n`);
      return { status: 2, outputs };
    }
    process.stderr.write(`${failureMessage(check, result)}; failing open\n`);
  }
  return { status: 0, outputs };
}

function usage() {
  process.stderr.write('usage: hook-dispatch-v1.js pre|post [--only <check>]\n');
  return 2;
}

function main(argv) {
  const eventName = EVENTS[argv[0]];
  if (!eventName) return usage();
  let only = null;
  if (argv.length > 1) {
    if (argv.length !== 3 || argv[1] !== '--only') return usage();
    only = REGISTRY.find((check) => check.event === eventName && check.name === argv[2]);
    if (!only) return usage();
  }
  const hookCwd = process.cwd();
  let raw;
  try {
    raw = fs.readFileSync(0);
  } catch (_error) {
    raw = Buffer.alloc(0);
  }
  const environment = Object.assign({}, process.env);
  const context = buildContext(raw, eventName, environment, hookCwd, only !== null);
  prepareProcessEnvironment(context);
  if (only) return runOnly(context, only);
  const outcome = runAll(context);
  if (outcome.status !== 0) return outcome.status;
  const output = aggregate(outcome.outputs, eventName);
  if (output) process.stdout.write(`${JSON.stringify(output)}\n`);
  return 0;
}

module.exports = {
  REGISTRY,
  aggregate,
  configHookEnabled,
  configHookEnabledStrict,
  configHookOptedIn,
  consentMarked,
  secretScanSkipsBash,
  selectChecks,
  spawnGrantLibrariesPresent,
};

if (require.main === module) process.exitCode = main(process.argv.slice(2));
