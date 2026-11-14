#!/usr/bin/env node
'use strict';
const childProcess = require('node:child_process');
const crypto = require('node:crypto');
const dns = require('node:dns');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const {
  FLOOR_REASONS,
  classifyOrigin,
  resolveRemoteHost,
} = require(path.join(__dirname, '..', 'hooks', 'lib', 'verify-navigation-floor-v1.js'));
const consent = require(path.join(__dirname, '..', 'hooks', 'lib', 'verify-consent-v1.js'));
const cliVersion = require(path.join(__dirname, '..', 'hooks', 'lib', 'playwright-cli-version-v1.js'));
const authState = require(path.join(__dirname, '..', 'hooks', 'lib', 'verify-auth-state-v1.js'));

const PLUGIN_ROOT = path.join(__dirname, '..');
const PINNED_INSTALL = `npm install -g @playwright/cli@${consent.PLAYWRIGHT_CLI_SOURCE_VERSION}`;
const CONFIG_NAME = consent.RUN_CONFIG_NAME;
const OUTPUT_DIR_NAME = consent.RUN_OUTPUT_DIR_NAME;
const SESSION_PREFIX = consent.SESSION_PREFIX;
const MAX_ORIGINS = consent.MAX_RUN_ORIGINS;
const MODES = Object.freeze(['local', 'remote']);
const USAGE = 'usage: verify-browser-config.js --run-dir <absolute-dir> --mode <local|remote> --origin <origin> [--origin <origin> ...] [--network-only-origin <origin> ...] [--login-recipe <absolute-recipe-path>]';
const CHECK_USAGE = 'usage: verify-browser-config.js --check-policy <local|remote> <origin> <declared-safe|network-only>';
const POLICY_CONSENT_NOTE = 'the navigation policy in the launch environment does not name every origin checked here as a target: the permission prompt asks for the others, and a session that cannot show it (permission mode bypassPermissions or dontAsk) is denied them at open';
const CHECK_ROLES = Object.freeze({ 'declared-safe': 'navigable', 'network-only': 'network-only' });
const AUTH_SESSION_PREFIX = authState.AUTH_SESSION_PREFIX;
const LOGIN_TIMEOUT_MS = 300000;
const MAX_LOGIN_STDOUT_BYTES = 65536;
const MAX_RECIPE_BYTES = 262144;
const AUTH_ENVIRONMENTS = Object.freeze(['test', 'production']);
const LOGIN_FAILURES = Object.freeze(['recipe', 'timeout', 'contract', 'artifact-path', 'artifact-shape', 'artifact-scope']);
const LOGIN_FAILURE_RE = new RegExp(`^(?:${LOGIN_FAILURES.join('|')}|exit [0-9]{1,3})$`);
const LOGIN_RESTORED = 'login=state-restored';
const ABORT_SIGNALS = Object.freeze(['SIGTERM', 'SIGINT', 'SIGHUP']);
const DISCARD_USAGE = 'usage: verify-browser-config.js --discard-state --run-dir <absolute-dir>';

function parseArgs(argv) {
  const options = { runDir: null, mode: null, origins: [], networkOnlyOrigins: [], loginRecipe: null };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const value = argv[index + 1];
    if (typeof value !== 'string') throw new Error(USAGE);
    if (arg === '--run-dir' && options.runDir === null) options.runDir = value;
    else if (arg === '--mode' && options.mode === null) options.mode = value;
    else if (arg === '--origin') options.origins.push(value);
    else if (arg === '--network-only-origin') options.networkOnlyOrigins.push(value);
    else if (arg === '--login-recipe' && options.loginRecipe === null) options.loginRecipe = value;
    else throw new Error(USAGE);
    index += 1;
  }
  if (!options.runDir || !MODES.includes(options.mode) || options.origins.length === 0) {
    throw new Error(USAGE);
  }
  if (options.origins.length + options.networkOnlyOrigins.length > MAX_ORIGINS) {
    throw new Error(`at most ${MAX_ORIGINS} origins are accepted`);
  }
  return options;
}

function checkRunDir(runDir) {
  if (!path.isAbsolute(runDir)) throw new Error('run directory must be an absolute path');
  let info;
  try { info = fs.lstatSync(runDir); }
  catch (_error) { throw new Error('run directory does not exist'); }
  if (info.isSymbolicLink() || !info.isDirectory()) throw new Error('run directory must be a real directory');
  return fs.realpathSync.native(runDir);
}

function checkOrigin(rawOrigin, mode, networkOnly = false) {
  let parsed;
  try { parsed = new URL(rawOrigin); }
  catch (_error) { throw new Error(FLOOR_REASONS.INVALID); }
  if (!['http:', 'https:'].includes(parsed.protocol)) throw new Error(FLOOR_REASONS.SCHEME);
  if (parsed.username || parsed.password) throw new Error(FLOOR_REASONS.CREDENTIALS);
  if (parsed.search || parsed.hash || rawOrigin.includes('?') || rawOrigin.includes('#')) {
    throw new Error(FLOOR_REASONS.QUERY_OR_FRAGMENT);
  }
  if (parsed.pathname !== '/') throw new Error('an origin must not carry a path');
  const classified = classifyOrigin(parsed.origin);
  const loopback = classified.ok && classified.mode === 'local';
  if (mode === 'local' && (!networkOnly || loopback)) {
    if (!loopback) throw new Error(FLOOR_REASONS.LOCAL_LOOPBACK_ONLY);
    return classified;
  }
  if (parsed.protocol !== 'https:') throw new Error(mode === 'local' ? FLOOR_REASONS.NETWORK_ONLY_HTTPS : FLOOR_REASONS.REMOTE_HTTPS);
  if (!classified.ok) throw new Error(classified.reason);
  if (classified.mode !== 'remote') throw new Error(FLOOR_REASONS.REMOTE_HTTPS);
  return classified;
}

async function resolverRule(classified, resolver) {
  const addresses = await resolveRemoteHost(classified.hostname, resolver);
  if (net.isIP(classified.hostname)) return null;
  const address = addresses.find((candidate) => net.isIP(candidate) === 4) || addresses[0];
  return `MAP ${classified.hostname} ${net.isIP(address) === 6 ? `[${address}]` : address}`;
}

function policyVerdict(url, policy, navigation, role) {
  const verdict = consent.judgeOrigin(url, { navigation, policy, role, answerable: true });
  if (verdict.deny) throw new Error(verdict.deny);
  return verdict;
}

async function checkPolicy(argv, env = process.env, resolver = dns.promises.lookup, readiness = defaultReadiness()) {
  if (argv.length !== 3 || !MODES.includes(argv[0]) || !Object.prototype.hasOwnProperty.call(CHECK_ROLES, argv[2])) {
    throw new Error(CHECK_USAGE);
  }
  checkReadiness(readiness, env, false);
  const [mode, rawOrigin, operand] = argv;
  const networkOnly = CHECK_ROLES[operand] === 'network-only';
  const classified = checkOrigin(rawOrigin, mode, networkOnly);
  const policy = consent.readPolicy(env);
  const verdict = policyVerdict(`${classified.origin}/`, policy, !networkOnly, CHECK_ROLES[operand]);
  if (classified.mode === 'remote') await resolveRemoteHost(classified.hostname, resolver);
  return verdict.decidedBy === 'policy-mode' ? 'policy' : 'consent';
}

function sessionName(runDir, options = {}) {
  const prefix = options.signedIn ? AUTH_SESSION_PREFIX : SESSION_PREFIX;
  const room = SESSION_PREFIX.length + 40 - prefix.length;
  let slug = path.basename(runDir).toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '');
  if (!options.signedIn && /^auth(-|$)/.test(slug)) slug = `run-${slug}`;
  slug = slug.slice(0, room);
  if (!slug) throw new Error('run directory name yields no session name');
  const name = `${prefix}${slug}`;
  if (!consent.SESSION_RE.test(name)) throw new Error('run directory name yields no valid session name');
  return name;
}

function buildConfig(runDir, origins, rules, statePath = null) {
  const args = ['--no-proxy-server'];
  if (rules.length > 0) args.push(`--host-resolver-rules=${rules.join(',')}`);
  const contextOptions = { serviceWorkers: 'block' };
  if (statePath) contextOptions.storageState = statePath;
  return {
    browser: {
      isolated: true,
      launchOptions: { args },
      contextOptions,
    },
    network: { allowedOrigins: origins },
    outputDir: path.join(runDir, OUTPUT_DIR_NAME),
  };
}

function loginFailure(kind) {
  const error = new Error(`login failed: ${kind}`);
  error.loginFailure = kind;
  return error;
}

function doubleQuoted(raw) {
  let value = '';
  let index = 1;
  const simple = { '\\': '\\', '"': '"', '/': '/', t: '\t', n: '\n', r: '\r', 0: '\0' };
  while (index < raw.length) {
    const char = raw[index];
    if (char === '"') return { value, rest: raw.slice(index + 1) };
    if (char !== '\\') {
      value += char;
      index += 1;
      continue;
    }
    const next = raw[index + 1];
    if (Object.prototype.hasOwnProperty.call(simple, next)) {
      value += simple[next];
      index += 2;
      continue;
    }
    const width = next === 'x' ? 2 : next === 'u' ? 4 : 0;
    const digits = width ? raw.slice(index + 2, index + 2 + width) : '';
    if (!width || !new RegExp(`^[0-9A-Fa-f]{${width}}$`).test(digits)) return null;
    value += String.fromCodePoint(parseInt(digits, 16));
    index += 2 + width;
  }
  return null;
}

function singleQuoted(raw) {
  let value = '';
  let index = 1;
  while (index < raw.length) {
    if (raw[index] === "'") {
      if (raw[index + 1] === "'") {
        value += "'";
        index += 2;
        continue;
      }
      return { value, rest: raw.slice(index + 1) };
    }
    value += raw[index];
    index += 1;
  }
  return null;
}

function scalarValue(raw) {
  if (raw.startsWith('"') || raw.startsWith("'")) {
    const quoted = raw.startsWith('"') ? doubleQuoted(raw) : singleQuoted(raw);
    if (!quoted || !/^\s*(#.*)?$/.test(quoted.rest)) return null;
    return quoted.value;
  }
  if (/^[[\]{}|>&*!%@`#]/.test(raw) || /^[-?:](\s|$)/.test(raw)) return null;
  const value = raw.replace(/\s+#.*$/, '').replace(/\s+$/, '');
  if (value === '' || /:(\s|$)/.test(value) || /^['"]/.test(value)) return null;
  return value;
}

function readAuthBlock(text) {
  const lines = String(text).split(/\r?\n/);
  let start = -1;
  for (let index = 0; index < lines.length; index += 1) {
    if (!/^auth\s*:/.test(lines[index])) continue;
    if (start !== -1 || !/^auth:\s*(#.*)?$/.test(lines[index])) return null;
    start = index;
  }
  if (start === -1) return null;
  const values = {};
  let indent = null;
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (/^\s*(#.*)?$/.test(line)) continue;
    if (/^[ ]*\t/.test(line)) return null;
    const lead = line.match(/^ */)[0].length;
    if (lead === 0) break;
    if (indent === null) indent = lead;
    if (lead !== indent) return null;
    const entry = line.slice(lead).match(/^([A-Za-z_][A-Za-z0-9_-]*):(?:[ ]+(.*))?$/);
    if (!entry || entry[2] === undefined || entry[2].trim() === '') return null;
    const value = scalarValue(entry[2]);
    if (value === null || Object.prototype.hasOwnProperty.call(values, entry[1])) return null;
    values[entry[1]] = value;
  }
  return values;
}

function originValue(value) {
  if (typeof value !== 'string' || value === '') return '';
  try {
    const parsed = new URL(value);
    if (parsed.username || parsed.password || parsed.search || parsed.hash || parsed.pathname !== '/') return '';
    if (value !== parsed.origin && value !== `${parsed.origin}/`) return '';
    return parsed.origin;
  } catch (_error) {
    return '';
  }
}

function readLoginRecipe(file, projectRoot) {
  if (typeof file !== 'string' || !path.isAbsolute(file)) throw loginFailure('recipe');
  let text;
  try {
    const info = fs.lstatSync(file);
    if (!info.isFile() || info.size > MAX_RECIPE_BYTES) throw loginFailure('recipe');
    const real = fs.realpathSync.native(file);
    if (!real.startsWith(`${projectRoot}${path.sep}`)) throw loginFailure('recipe');
    text = fs.readFileSync(real, 'utf8');
  } catch (_error) {
    throw loginFailure('recipe');
  }
  const block = readAuthBlock(text);
  if (!block || block.mode !== 'login-script' || block.artifact !== 'storageState' || !block.loginScript) throw loginFailure('recipe');
  return block;
}

function signalStatus(signal) {
  const number = os.constants.signals[signal];
  return typeof number === 'number' ? 128 + number : 128;
}

function runLoginScript(script, options) {
  return new Promise((resolve) => {
    const detached = process.platform !== 'win32';
    let child;
    try {
      child = childProcess.spawn(options.shell || 'bash', ['-c', script], {
        cwd: options.cwd,
        env: options.env,
        detached,
        stdio: ['ignore', 'pipe', 'ignore'],
        windowsHide: true,
      });
    } catch (_error) {
      resolve({ kind: 'exit 127' });
      return;
    }
    const chunks = [];
    let size = 0;
    let overflow = false;
    let settled = false;
    let timer = null;
    const killGroup = () => {
      const attempts = detached ? [() => process.kill(-child.pid, 'SIGKILL'), () => child.kill('SIGKILL')] : [() => child.kill('SIGKILL')];
      for (const attempt of attempts) {
        try {
          attempt();
          return;
        } catch (_error) {
          continue;
        }
      }
    };
    const abort = (signal) => {
      killGroup();
      if (typeof options.onAbort === 'function') options.onAbort();
      process.exit(signalStatus(signal));
    };
    const finish = (outcome) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      for (const signal of ABORT_SIGNALS) process.removeListener(signal, abort);
      resolve(outcome);
    };
    for (const signal of ABORT_SIGNALS) process.once(signal, abort);
    timer = setTimeout(() => {
      killGroup();
      child.stdout.destroy();
      finish({ kind: 'timeout' });
    }, options.timeoutMs || LOGIN_TIMEOUT_MS);
    child.stdout.on('data', (chunk) => {
      if (overflow) return;
      size += chunk.length;
      if (size > MAX_LOGIN_STDOUT_BYTES) {
        overflow = true;
        chunks.length = 0;
        killGroup();
        return;
      }
      chunks.push(chunk);
    });
    child.on('exit', () => killGroup());
    child.on('error', () => finish({ kind: 'exit 127' }));
    child.on('close', (code, signal) => {
      if (overflow) finish({ kind: 'contract' });
      else if (code !== 0) finish({ kind: `exit ${code === null ? signalStatus(signal) : code}` });
      else finish({ kind: 'ok', stdout: Buffer.concat(chunks).toString('utf8') });
    });
  });
}

async function signIn(options, runDir, origins, env, login = {}) {
  const layout = authState.runDirLayout(runDir);
  if (!layout.ok) throw new Error(`with --login-recipe the run directory must be <project>/${authState.ZENSU_DIR_NAME}/${authState.RUNS_DIR_NAME}/<leaf>`);
  const recipe = readLoginRecipe(options.loginRecipe, layout.projectRoot);
  const appOrigin = origins[0];
  let authOrigin = appOrigin;
  if (options.mode === 'remote') {
    if (originValue(recipe.appOrigin) !== appOrigin) throw loginFailure('recipe');
    authOrigin = recipe.baseUrl === undefined ? appOrigin : originValue(recipe.baseUrl);
    if (!origins.includes(authOrigin)) throw loginFailure('recipe');
    if (!AUTH_ENVIRONMENTS.includes(recipe.environment)) throw loginFailure('recipe');
  } else if (recipe.environment !== undefined
    || [recipe.appOrigin, recipe.baseUrl].some((value) => value !== undefined && originValue(value) !== appOrigin)) {
    throw loginFailure('recipe');
  }
  const prepared = authState.prepareAuthDir(runDir);
  try {
    const outcome = await runLoginScript(recipe.loginScript, {
      cwd: layout.projectRoot,
      env: Object.assign({}, env, {
        ZENSU_AUTH_ARTIFACT_DIR: prepared.artifactDir,
        ZENSU_AUTH_BASE_URL: authOrigin,
        ZENSU_APP_ORIGIN: appOrigin,
      }),
      timeoutMs: login.timeoutMs,
      shell: login.shell,
      onAbort: () => authState.removeArtifactDir(prepared.artifactDir),
    });
    if (outcome.kind !== 'ok') throw loginFailure(outcome.kind);
    const line = authState.artifactLine(outcome.stdout);
    if (!line.ok) throw loginFailure('contract');
    const artifact = authState.artifactFile(line.value, prepared.artifactDir);
    if (!artifact.ok) throw loginFailure('artifact-path');
    const read = authState.readBounded(artifact.file);
    if (!read.ok) throw loginFailure(read.fault === authState.FAULTS.TOO_LARGE ? 'artifact-shape' : 'artifact-path');
    const parsed = authState.parseState(read.text);
    if (!parsed.ok) throw loginFailure('artifact-shape');
    const scoped = authState.scopeState(parsed.state, origins.concat(options.scopeOrigins || []));
    if (authState.emptyState(scoped)) throw loginFailure('artifact-scope');
    const written = authState.writeStateFile(prepared.statePath, scoped);
    if (!written.ok) throw new Error('the signed-in state could not be written into the run directory');
    return prepared.statePath;
  } finally {
    authState.removeArtifactDir(prepared.artifactDir);
  }
}

function writeConfig(runDir, config) {
  const target = path.join(runDir, CONFIG_NAME);
  const temp = path.join(runDir, `.${CONFIG_NAME}.${crypto.randomBytes(6).toString('hex')}`);
  fs.writeFileSync(temp, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
  try { fs.renameSync(temp, target); }
  catch (error) {
    fs.rmSync(temp, { force: true });
    throw error;
  }
  return target;
}

function versionCause(installed, measured) {
  if (installed.source === 'absent') return 'playwright-cli is not on PATH';
  if (installed.source === 'cwd-relative') {
    const entry = installed.entry === '' ? 'an empty PATH entry' : `the relative PATH entry ${JSON.stringify(String(installed.entry))}`;
    return `${entry} comes before or holds the playwright-cli on PATH, and the shell reads it against the working directory of each call, so a gated call can run another playwright-cli than the one measured here`;
  }
  if (installed.source === 'manifest') {
    return `playwright-cli ${installed.version} is installed, but the browser consent gate was measured against ${measured}`;
  }
  if (installed.source === 'foreign') {
    return `the playwright-cli on PATH belongs to the package ${installed.owner}, not ${cliVersion.PACKAGE_NAME}`;
  }
  if (installed.source === 'malformed') return 'the package manifest beside the playwright-cli on PATH could not be judged';
  return `the installed playwright-cli version could not be read from its ${cliVersion.PACKAGE_NAME} package manifest: the playwright-cli on PATH resolves to no such manifest, as a wrapper script outside the package does`;
}

function versionRemedy(installed) {
  if (installed.source === 'cwd-relative') return 'remove that entry from PATH, or move it behind the directory that holds playwright-cli';
  const install = `install the measured version with \`${PINNED_INSTALL}\``;
  if (installed.source === 'unread') return `${install}, and put the directory npm installs it into first on PATH, ahead of any wrapper`;
  return install;
}

function checkReadiness(readiness, env, signedIn) {
  const hook = consent.consentHookRegistered(readiness.pluginRoot);
  const recorder = consent.consentRecorderRegistered(readiness.pluginRoot);
  if (hook !== consent.REGISTRATION.REGISTERED || recorder !== consent.REGISTRATION.REGISTERED) {
    throw new Error(`the browser consent gate is not ready (consent hook: ${hook}; consent recorder: ${recorder}), so no run config is written; run /zensu:doctor`);
  }
  const guard = signedIn ? consent.authGuardRegistered(readiness.pluginRoot) : consent.REGISTRATION.REGISTERED;
  if (guard !== consent.REGISTRATION.REGISTERED) {
    throw new Error(`the verify-auth read guard is not ready (auth guard: ${guard}), so no signed-in run config is written; run /zensu:doctor`);
  }
  const measured = consent.PLAYWRIGHT_CLI_SOURCE_VERSION;
  const installed = readiness.installedVersion(env);
  if (installed.source === 'manifest' && installed.version === measured) return;
  throw new Error(`${versionCause(installed, measured)}, so no run config is written; ${versionRemedy(installed)}`);
}

function defaultReadiness() {
  return { pluginRoot: PLUGIN_ROOT, installedVersion: (env) => cliVersion.installedVersion(env) };
}

async function run(argv, resolver = dns.promises.lookup, env = process.env, readiness = defaultReadiness(), login = {}) {
  const options = parseArgs(argv);
  checkReadiness(readiness, env, options.loginRecipe !== null);
  const runDir = checkRunDir(options.runDir);
  const policy = consent.readPolicy(env);
  const origins = [];
  const networkOnlyOrigins = [];
  const rules = [];
  const pinned = new Set();
  let consentNeeded = false;
  const admit = async (rawOrigin, networkOnly) => {
    const classified = checkOrigin(rawOrigin, options.mode, networkOnly);
    if (origins.includes(classified.origin) || networkOnlyOrigins.includes(classified.origin)) {
      throw new Error('origins must be unique');
    }
    const verdict = policyVerdict(`${classified.origin}/`, policy, false, networkOnly ? 'network-only' : 'navigable');
    if (verdict.decidedBy !== 'policy-mode') consentNeeded = true;
    if (classified.mode === 'remote' && !pinned.has(classified.hostname)) {
      const rule = await resolverRule(classified, resolver);
      if (rule) rules.push(rule);
      pinned.add(classified.hostname);
    }
    (networkOnly ? networkOnlyOrigins : origins).push(classified.origin);
  };
  for (const rawOrigin of options.origins) await admit(rawOrigin, false);
  for (const rawOrigin of options.networkOnlyOrigins) await admit(rawOrigin, true);
  const signedIn = options.loginRecipe !== null;
  const session = sessionName(runDir, { signedIn });
  const statePath = signedIn
    ? await signIn(Object.assign({}, options, { scopeOrigins: networkOnlyOrigins }), runDir, origins, env, login)
    : null;
  const config = buildConfig(runDir, [...origins, ...networkOnlyOrigins], rules, statePath);
  const shape = consent.runConfigShape(config, path.join(runDir, CONFIG_NAME));
  if (!shape.ok) throw new Error(shape.fault);
  const configPath = writeConfig(runDir, config);
  return { session, configPath, origins, networkOnlyOrigins, config, mode: consentNeeded ? 'consent' : 'policy', login: signedIn ? 'state-restored' : null };
}

function discardState(argv) {
  if (!Array.isArray(argv) || argv.length !== 2 || argv[0] !== '--run-dir') throw new Error(DISCARD_USAGE);
  const result = authState.discardAuthState(checkRunDir(argv[1]));
  if (!result.ok) throw new Error(result.reason);
  return result.removed ? 'discarded' : 'none';
}

module.exports = {
  ABORT_SIGNALS,
  AUTH_ENVIRONMENTS,
  AUTH_SESSION_PREFIX,
  CONFIG_NAME,
  LOGIN_FAILURES,
  LOGIN_FAILURE_RE,
  LOGIN_RESTORED,
  LOGIN_TIMEOUT_MS,
  MAX_LOGIN_STDOUT_BYTES,
  MAX_ORIGINS,
  OUTPUT_DIR_NAME,
  POLICY_CONSENT_NOTE,
  SESSION_PREFIX,
  buildConfig,
  checkOrigin,
  checkPolicy,
  checkRunDir,
  discardState,
  parseArgs,
  readAuthBlock,
  run,
  runLoginScript,
  sessionName,
};

if (require.main === module) {
  const argv = process.argv.slice(2);
  const policyPresent = consent.readPolicy(process.env) !== null;
  const work = argv[0] === '--check-policy'
    ? checkPolicy(argv.slice(1)).then((verdict) => ({ text: `${verdict}\n`, consentUnderPolicy: policyPresent && verdict === 'consent' }))
    : argv[0] === '--discard-state'
    ? Promise.resolve().then(() => ({ text: `state=${discardState(argv.slice(1))}\n`, consentUnderPolicy: false }))
    : run(argv).then((result) => {
      const lines = [`session=${result.session}`, `config=${result.configPath}`, `mode=${result.mode}`];
      for (const origin of result.origins) lines.push(`origin=${origin}`);
      for (const origin of result.networkOnlyOrigins) lines.push(`network-only-origin=${origin}`);
      if (result.login) lines.push(LOGIN_RESTORED);
      return { text: `${lines.join('\n')}\n`, consentUnderPolicy: policyPresent && result.mode === 'consent' };
    });
  work.then(({ text, consentUnderPolicy }) => {
    if (consentUnderPolicy) process.stderr.write(`zensu verify browser config: note: ${POLICY_CONSENT_NOTE}\n`);
    process.stdout.write(text);
  }).catch((error) => {
    process.stderr.write(`zensu verify browser config: ${error.message}\n`);
    process.exitCode = 1;
  });
}
