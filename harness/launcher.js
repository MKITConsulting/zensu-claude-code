#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const readline = require('readline');
const { spawn, spawnSync } = require('child_process');

const PLUGIN_ROOT = path.resolve(__dirname, '..');
const runtime = require(path.join(PLUGIN_ROOT, 'hooks', 'lib', 'work-order-v1.js'));
const supervisor = require(path.join(PLUGIN_ROOT, 'scripts', 'process-supervisor.js'));

const STATE_LIBRARY = path.join(PLUGIN_ROOT, 'hooks', 'lib', 'zensu-autopilot-state.sh');
const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const VALUE_OPTIONS = new Set(['order', 'session-id', 'project', 'claude', 'permission-mode', 'settings', 'mcp-config', 'plugin-dir', 'log']);
const EXIT_CODES = Object.freeze({ success: 0, failure: 1, cancelled: 143 });
const USAGE = 'usage: launcher.js --order <order-id> --session-id <client-session-id> [--project <dir>] [--claude <executable>] '
  + '[--permission-mode <mode>] [--settings <file>] [--mcp-config <file>] [--plugin-dir <dir>] [--log <file>] [-- <claude arguments>]\n'
  + 'environment: ZENSU_SESSION_TOKEN, the session token of the claim, and ZENSU_API_URL, the Zensu host that issued it, '
  + 'unless the zensu CLI config the session reads stores that host; that config must hold the host only, never a login';

function boundedNumber(env, name, fallback, min, max) {
  const value = Number(env[name]);
  return Number.isFinite(value) && value >= min && value <= max ? value : fallback;
}

function parseLauncherArgs(argv) {
  const options = { extra: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--') {
      options.extra = argv.slice(index + 1);
      break;
    }
    const match = /^--([a-z-]+)$/.exec(arg);
    if (!match || !VALUE_OPTIONS.has(match[1]) || index + 1 >= argv.length) return { error: `unknown or incomplete argument: ${arg}` };
    if (options[match[1]] !== undefined) return { error: `repeated argument: ${arg}` };
    options[match[1]] = argv[index + 1];
    index += 1;
  }
  if (!UUID_RE.test(String(options.order || ''))) return { error: '--order must name a work order id' };
  if (!UUID_RE.test(String(options['session-id'] || ''))) return { error: '--session-id must be the client session id of the claim' };
  return { options };
}

function claudeArguments(options) {
  const args = ['-p', '--session-id', options['session-id'], '--output-format', 'stream-json', '--verbose',
    '--setting-sources', 'user', '--strict-mcp-config'];
  if (options['permission-mode']) args.push('--permission-mode', options['permission-mode']);
  if (options.settings) args.push('--settings', options.settings);
  if (options['mcp-config']) args.push('--mcp-config', options['mcp-config']);
  if (options['plugin-dir']) args.push('--plugin-dir', options['plugin-dir']);
  args.push(...options.extra, `/zensu:work ${options.order}`);
  return args;
}

function translate(message, now) {
  if (!message || typeof message !== 'object' || Array.isArray(message)) return null;
  if (message.type === 'system' && message.subtype === 'init') return { kind: 'init' };
  if (message.type === 'system' && message.subtype === 'api_retry'
    && (message.error === 'rate_limit' || message.error_status === 429)) {
    const delay = Number(message.retry_delay_ms);
    return { kind: 'rate_limited', resetAt: Number.isFinite(delay) && delay >= 0 ? new Date(now + delay).toISOString() : null };
  }
  if (message.type === 'result') return { kind: 'result', isError: message.is_error === true };
  return null;
}

function emit(line) {
  process.stdout.write(`${JSON.stringify(line)}\n`);
}

function currentContext(env, projectRoot, sessionKey, orderId) {
  let context;
  try {
    context = runtime.loadContext({ env, projectRoot, sessionKey });
  } catch (_) {
    return null;
  }
  if (!context || context.fault || !context.marker) return null;
  return String(context.marker.orderId).toLowerCase() === orderId.toLowerCase() ? context : null;
}

function watchdog(env, projectRoot, sessionKey, orderId) {
  const context = currentContext(env, projectRoot, sessionKey, orderId);
  if (!context) return null;
  let lease = null;
  try {
    lease = runtime.readState(context.files.lease);
  } catch (_) {
    lease = null;
  }
  const leaseSeconds = lease && Number.isFinite(lease.leaseSeconds) && lease.leaseSeconds > 0 ? lease.leaseSeconds : null;
  return runtime.renew(context, { env, thresholdMs: leaseSeconds ? Math.floor((leaseSeconds * 1000) / 3) : null }).verdict;
}

function releaseRuns(env, projectRoot, sessionKey, orderId) {
  const context = currentContext(env, projectRoot, sessionKey, orderId);
  if (!context) return;
  const below = context.marker.attempt + 1;
  for (const runId of runtime.releasePlan(projectRoot, context.marker.orderId, below)) {
    spawnSync('bash', ['-c', 'source "$1" && autopilot_release_work_order_run "$2" "$3" "$4" "$5"', 'zensu-launcher-release',
      STATE_LIBRARY, runId, context.marker.orderId, String(below), projectRoot], { env, stdio: 'ignore', timeout: 60000 });
  }
}

async function launch(argv, env = process.env) {
  const parsed = parseLauncherArgs(argv);
  if (parsed.error) {
    process.stderr.write(`zensu launcher: ${parsed.error}\n${USAGE}\n`);
    return 2;
  }
  const { options } = parsed;
  if (!runtime.tokenPresent(env)) {
    process.stderr.write('zensu launcher: ZENSU_SESSION_TOKEN is not set\n');
    return 2;
  }
  let projectRoot;
  try {
    projectRoot = fs.realpathSync(options.project || process.cwd());
    if (!fs.statSync(projectRoot).isDirectory()) throw new Error('not a directory');
  } catch (_) {
    process.stderr.write('zensu launcher: the project directory cannot be read\n');
    return 2;
  }
  let logFd = null;
  if (options.log) {
    try {
      logFd = fs.openSync(options.log, 'a', 0o600);
    } catch (_) {
      process.stderr.write('zensu launcher: the log file cannot be opened\n');
      return 2;
    }
  }
  const sessionKey = runtime.sessionKeyOf(options['session-id']);
  const tickMs = boundedNumber(env, 'ZENSU_LAUNCHER_TICK_MS', 5000, 50, 60000);
  const graceMs = boundedNumber(env, 'ZENSU_LAUNCHER_STOP_GRACE_MS', 10000, 0, 60000);
  const state = { started: false, cancelled: false, leaseLost: false, result: null, stopping: null, pid: null };
  const stop = () => {
    if (state.stopping) return state.stopping;
    if (state.pid === null) return Promise.resolve();
    state.stopping = (async () => {
      supervisor.signalGroup(state.pid, 'SIGTERM');
      const remaining = await supervisor.waitForGroupExit(state.pid, graceMs);
      if (remaining !== 'gone') {
        supervisor.signalGroup(state.pid, 'SIGKILL');
        await supervisor.waitForGroupExit(state.pid, 3000);
      }
    })();
    return state.stopping;
  };
  const cancel = () => {
    state.cancelled = true;
    stop();
  };
  for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(signal, cancel);
  const child = spawn(options.claude || 'claude', claudeArguments(options), {
    cwd: projectRoot,
    env,
    detached: true,
    stdio: ['ignore', 'pipe', logFd === null ? 'ignore' : logFd],
  });
  const spawned = await new Promise((resolve) => {
    child.once('spawn', () => resolve(true));
    child.once('error', () => resolve(false));
  });
  if (!spawned) {
    for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.removeListener(signal, cancel);
    if (logFd !== null) fs.closeSync(logFd);
    emit({ event: 'exited', status: state.cancelled ? 'cancelled' : 'failure', exit_code: null, reason: 'harness_unavailable' });
    return state.cancelled ? EXIT_CODES.cancelled : EXIT_CODES.failure;
  }
  state.pid = child.pid;
  if (state.cancelled) stop();
  const lines = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
  lines.on('line', (line) => {
    if (logFd !== null) {
      try {
        fs.writeSync(logFd, `${line}\n`);
      } catch (_) {}
    }
    let message;
    try {
      message = JSON.parse(line);
    } catch (_) {
      return;
    }
    const translated = translate(message, Date.now());
    if (!translated) return;
    if (translated.kind === 'init' && !state.started) {
      state.started = true;
      emit({ event: 'session_started', client_session_id: options['session-id'] });
    } else if (translated.kind === 'rate_limited') {
      emit({ event: 'rate_limited', reset_at: translated.resetAt });
    } else if (translated.kind === 'result') {
      state.result = translated;
    }
  });
  const closed = new Promise((resolve) => child.once('close', resolve));
  const exited = new Promise((resolve) => child.once('exit', (code, signal) => resolve({ code, signal })));
  const timer = setInterval(() => {
    if (state.stopping || state.leaseLost) return;
    if (watchdog(env, projectRoot, sessionKey, options.order) === runtime.VERDICTS.LOST) {
      state.leaseLost = true;
      stop();
    }
  }, tickMs);
  const exit = await exited;
  clearInterval(timer);
  await stop();
  await Promise.race([closed, new Promise((resolve) => setTimeout(resolve, 2000))]);
  for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.removeListener(signal, cancel);
  if (logFd !== null) fs.closeSync(logFd);
  releaseRuns(env, projectRoot, sessionKey, options.order);
  let status = 'failure';
  let reason = null;
  if (state.cancelled) status = 'cancelled';
  else if (state.leaseLost) reason = 'lease_lost';
  else if (exit.code === 0 && !(state.result && state.result.isError)) status = 'success';
  else reason = state.result && state.result.isError ? 'harness_error' : 'harness_failed';
  emit({ event: 'exited', status, exit_code: exit.code, ...(reason ? { reason } : {}) });
  return EXIT_CODES[status];
}

module.exports = { EXIT_CODES, claudeArguments, launch, parseLauncherArgs, translate };

if (require.main === module) {
  launch(process.argv.slice(2)).then((code) => {
    process.exitCode = code;
  }, (error) => {
    process.stderr.write(`zensu launcher: ${error && error.message ? error.message : 'internal fault'}\n`);
    process.exitCode = 2;
  });
}
