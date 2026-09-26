#!/usr/bin/env node
'use strict';
const crypto = require('node:crypto');
const dns = require('node:dns');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const {
  FLOOR_REASONS,
  classifyOrigin,
  normalizeRoute,
  resolveRemoteHost,
} = require(path.join(__dirname, '..', 'hooks', 'lib', 'verify-navigation-floor-v1.js'));
const consent = require(path.join(__dirname, '..', 'hooks', 'lib', 'verify-consent-v1.js'));
const cliVersion = require(path.join(__dirname, '..', 'hooks', 'lib', 'playwright-cli-version-v1.js'));

const PLUGIN_ROOT = path.join(__dirname, '..');
const PINNED_INSTALL = `npm install -g @playwright/cli@${consent.PLAYWRIGHT_CLI_SOURCE_VERSION}`;
const CONFIG_NAME = consent.RUN_CONFIG_NAME;
const OUTPUT_DIR_NAME = consent.RUN_OUTPUT_DIR_NAME;
const SESSION_PREFIX = consent.SESSION_PREFIX;
const MAX_ORIGINS = consent.MAX_RUN_ORIGINS;
const MODES = Object.freeze(['local', 'remote']);
const USAGE = 'usage: verify-browser-config.js --run-dir <absolute-dir> --mode <local|remote> --origin <origin> [--origin <origin> ...]';
const CHECK_USAGE = 'usage: verify-browser-config.js --check-policy <local|remote> <origin> <route> declared-safe';

function parseArgs(argv) {
  const options = { runDir: null, mode: null, origins: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const value = argv[index + 1];
    if (typeof value !== 'string') throw new Error(USAGE);
    if (arg === '--run-dir' && options.runDir === null) options.runDir = value;
    else if (arg === '--mode' && options.mode === null) options.mode = value;
    else if (arg === '--origin') options.origins.push(value);
    else throw new Error(USAGE);
    index += 1;
  }
  if (!options.runDir || !MODES.includes(options.mode) || options.origins.length === 0) {
    throw new Error(USAGE);
  }
  if (options.origins.length > MAX_ORIGINS) throw new Error(`at most ${MAX_ORIGINS} origins are accepted`);
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

function checkOrigin(rawOrigin, mode) {
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
  if (mode === 'local') {
    if (!classified.ok || classified.mode !== 'local') throw new Error(FLOOR_REASONS.LOCAL_LITERAL_LOOPBACK);
    return classified;
  }
  if (parsed.protocol !== 'https:') throw new Error(FLOOR_REASONS.REMOTE_HTTPS);
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

function policyVerdict(url, policy, navigation) {
  const verdict = consent.judgeOrigin(url, { navigation, policy });
  if (verdict.deny) throw new Error(verdict.deny);
  return verdict;
}

async function checkPolicy(argv, env = process.env, resolver = dns.promises.lookup, readiness = defaultReadiness()) {
  if (argv.length !== 4 || !MODES.includes(argv[0]) || argv[3] !== 'declared-safe') throw new Error(CHECK_USAGE);
  checkReadiness(readiness, env);
  const [mode, rawOrigin, route] = argv;
  const classified = checkOrigin(rawOrigin, mode);
  if (normalizeRoute(route) === null) throw new Error('route must be an absolute, normalized, query-free pathname');
  const policy = consent.readPolicy(env);
  if (policy && policy.ok && policy.mode !== mode) throw new Error('navigation policy mode does not match');
  const verdict = policyVerdict(new URL(route, `${classified.origin}/`).href, policy, true);
  if (verdict.origin !== classified.origin) throw new Error('navigation origin does not match the route it was checked with');
  if (mode === 'remote') await resolveRemoteHost(classified.hostname, resolver);
  return policy ? 'policy' : 'consent';
}

function sessionName(runDir) {
  const slug = path.basename(runDir).toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);
  if (!slug) throw new Error('run directory name yields no session name');
  const name = `${SESSION_PREFIX}${slug}`;
  if (!consent.SESSION_RE.test(name)) throw new Error('run directory name yields no valid session name');
  return name;
}

function buildConfig(runDir, origins, rules) {
  const args = ['--no-proxy-server'];
  if (rules.length > 0) args.push(`--host-resolver-rules=${rules.join(',')}`);
  return {
    browser: {
      isolated: true,
      launchOptions: { args },
      contextOptions: { serviceWorkers: 'block' },
    },
    network: { allowedOrigins: origins },
    outputDir: path.join(runDir, OUTPUT_DIR_NAME),
  };
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

function checkReadiness(readiness, env) {
  const hook = consent.consentHookRegistered(readiness.pluginRoot);
  const recorder = consent.consentRecorderRegistered(readiness.pluginRoot);
  if (hook !== consent.REGISTRATION.REGISTERED || recorder !== consent.REGISTRATION.REGISTERED) {
    throw new Error(`the browser consent gate is not ready (consent hook: ${hook}; consent recorder: ${recorder}), so no run config is written; run /zensu:doctor`);
  }
  const measured = consent.PLAYWRIGHT_CLI_SOURCE_VERSION;
  const installed = readiness.installedVersion(env);
  if (installed.source === 'manifest' && installed.version === measured) return;
  throw new Error(`${versionCause(installed, measured)}, so no run config is written; ${versionRemedy(installed)}`);
}

function defaultReadiness() {
  return { pluginRoot: PLUGIN_ROOT, installedVersion: (env) => cliVersion.installedVersion(env) };
}

async function run(argv, resolver = dns.promises.lookup, env = process.env, readiness = defaultReadiness()) {
  const options = parseArgs(argv);
  checkReadiness(readiness, env);
  const runDir = checkRunDir(options.runDir);
  const policy = consent.readPolicy(env);
  const origins = [];
  const rules = [];
  const pinned = new Set();
  for (const rawOrigin of options.origins) {
    const classified = checkOrigin(rawOrigin, options.mode);
    if (origins.includes(classified.origin)) throw new Error('origins must be unique');
    policyVerdict(`${classified.origin}/`, policy, false);
    if (options.mode === 'remote' && !pinned.has(classified.hostname)) {
      const rule = await resolverRule(classified, resolver);
      if (rule) rules.push(rule);
      pinned.add(classified.hostname);
    }
    origins.push(classified.origin);
  }
  const session = sessionName(runDir);
  const config = buildConfig(runDir, origins, rules);
  const shape = consent.runConfigShape(config, path.join(runDir, CONFIG_NAME));
  if (!shape.ok) throw new Error(shape.fault);
  const configPath = writeConfig(runDir, config);
  return { session, configPath, origins, config, mode: policy ? 'policy' : 'consent' };
}

module.exports = {
  CONFIG_NAME,
  MAX_ORIGINS,
  OUTPUT_DIR_NAME,
  SESSION_PREFIX,
  buildConfig,
  checkOrigin,
  checkPolicy,
  checkRunDir,
  parseArgs,
  run,
  sessionName,
};

if (require.main === module) {
  const argv = process.argv.slice(2);
  const work = argv[0] === '--check-policy'
    ? checkPolicy(argv.slice(1)).then((verdict) => `${verdict}\n`)
    : run(argv).then((result) => {
      const lines = [`session=${result.session}`, `config=${result.configPath}`, `mode=${result.mode}`];
      for (const origin of result.origins) lines.push(`origin=${origin}`);
      return `${lines.join('\n')}\n`;
    });
  work.then((text) => {
    process.stdout.write(text);
  }).catch((error) => {
    process.stderr.write(`zensu verify browser config: ${error.message}\n`);
    process.exitCode = 1;
  });
}
