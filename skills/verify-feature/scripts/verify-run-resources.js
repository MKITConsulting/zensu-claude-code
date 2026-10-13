#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const LEDGER_NAME = 'resources.json';
const LOCK_NAME = 'resources.lock';
const LEASE_NAME = 'supervisor.lease';
const KUBECONFIG_NAME = 'kubeconfig';
const NAME_PREFIX = 'zensu-verify-';
const MAX_NAME_LENGTH = 63;
const MAX_LEDGER_BYTES = 256 * 1024;
const MAX_RESOURCES = 64;
const LOCK_WAIT_MS = 10000;
const READY_WAIT_MS = 30000;
const EMULATOR_GONE_WAIT_MS = 6000;
const SUPERVISOR = path.resolve(__dirname, '..', '..', '..', 'scripts', 'process-supervisor.js');
const RECORD_KINDS = Object.freeze(['android-emulator', 'tmux-socket', 'kind-cluster', 'container']);
const LEDGER_KINDS = Object.freeze(['ios-simulator', 'process', ...RECORD_KINDS]);
const UDID_RE = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i;
const EMULATOR_RE = /^emulator-[0-9]{4,5}$/;
const PROCESS_NAME_RE = /^[a-z0-9][a-z0-9-]{0,31}$/;
const RUN_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$/;
const PLAIN_KEY_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const MAX_PLAIN_KEY = 24;
const SLUG_LENGTH = 14;
const DIGEST_LENGTH = 10;
const SUFFIX_RE = /^[a-z0-9][a-z0-9-]*$/;
const TOOL_ARG_RE = /^[^\0\r\n-][^\0\r\n]{0,254}$/;
const LEASE_RE = /^[a-f0-9]{64}$/;
const USAGE = [
  'usage: verify-run-resources.js create-simulator --run-dir <dir> --device-type <id> [--runtime <id>]',
  '       verify-run-resources.js start --run-dir <dir> --name <name> --cwd <dir> -- <command> [args...]',
  `       verify-run-resources.js record --run-dir <dir> --kind <${RECORD_KINDS.join('|')}> --id <id>`,
  '       verify-run-resources.js teardown --run-dir <dir>',
  '       verify-run-resources.js list --run-dir <dir>',
].join('\n');
const VERBS = Object.freeze({
  'create-simulator': { required: ['run-dir', 'device-type'], optional: ['runtime'], command: false },
  start: { required: ['run-dir', 'name', 'cwd'], optional: [], command: true },
  record: { required: ['run-dir', 'kind', 'id'], optional: [], command: false },
  teardown: { required: ['run-dir'], optional: [], command: false },
  list: { required: ['run-dir'], optional: [], command: false },
});

class Refusal extends Error {}

function refuse(message) {
  throw new Refusal(message);
}

function safe(text) {
  return String(text === undefined || text === null ? '' : text)
    .replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, ' ')
    .trim()
    .slice(0, 200);
}

function firstLine(text) {
  const line = String(text || '').split(/\r?\n/).map((part) => part.trim()).find((part) => part.length > 0);
  return safe(line || '');
}

function parseArgs(argv) {
  const list = Array.isArray(argv) ? argv : [];
  const verb = list[0];
  const spec = Object.prototype.hasOwnProperty.call(VERBS, verb) ? VERBS[verb] : null;
  if (!spec) refuse(USAGE);
  const flags = {};
  let command = [];
  for (let index = 1; index < list.length; index += 1) {
    const arg = list[index];
    if (arg === '--') {
      if (!spec.command) refuse(`${verb} takes no command`);
      command = list.slice(index + 1);
      break;
    }
    if (typeof arg !== 'string' || !arg.startsWith('--')) refuse(`unexpected argument for ${verb}: ${safe(arg)}`);
    const key = arg.slice(2);
    if (!spec.required.includes(key) && !spec.optional.includes(key)) refuse(`unknown flag --${safe(key)} for ${verb}`);
    if (Object.prototype.hasOwnProperty.call(flags, key)) refuse(`--${key} was given twice`);
    const value = list[index + 1];
    if (typeof value !== 'string' || value === '--' || value.length === 0) refuse(`--${key} needs a value`);
    flags[key] = value;
    index += 1;
  }
  for (const key of spec.required) {
    if (!Object.prototype.hasOwnProperty.call(flags, key)) refuse(`${verb} needs --${key}`);
  }
  if (spec.command && command.length === 0) refuse(`${verb} needs a command after --`);
  return { verb, flags, command };
}

function runKeyFor(runId) {
  const name = String(runId);
  if (name.length <= MAX_PLAIN_KEY && PLAIN_KEY_RE.test(name)) return name;
  const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, '-').slice(0, SLUG_LENGTH).replace(/-+$/, '');
  return `${slug}--${crypto.createHash('sha256').update(name).digest('hex').slice(0, DIGEST_LENGTH)}`;
}

function resolveRunDir(value) {
  if (typeof value !== 'string' || !path.isAbsolute(value)) refuse('--run-dir must be an absolute path');
  const dir = path.resolve(value);
  let info;
  try {
    info = fs.lstatSync(dir);
  } catch (_error) {
    refuse('--run-dir does not exist');
  }
  if (info.isSymbolicLink() || !info.isDirectory()) refuse('--run-dir must be a directory, not a symlink');
  let real;
  try {
    real = fs.realpathSync(dir);
  } catch (_error) {
    refuse('--run-dir cannot be resolved');
  }
  if (real !== dir) refuse('--run-dir must be a physical path: a component of it is a symlink');
  const runId = path.basename(dir);
  if (!RUN_ID_RE.test(runId)) refuse('the run directory name must be 1 to 200 letters, digits, dots, colons, dashes or underscores');
  return { dir, key: runKeyFor(runId) };
}

function prefixOf(run) {
  return `${NAME_PREFIX}${run.key}`;
}

function ownedName(id, run) {
  if (typeof id !== 'string' || id.length > MAX_NAME_LENGTH) return false;
  const prefix = prefixOf(run);
  if (id === prefix) return true;
  return id.startsWith(`${prefix}-`) && SUFFIX_RE.test(id.slice(prefix.length + 1));
}

function readyPathFor(run, name) {
  return path.join(run.dir, `${name}.supervisor.json`);
}

function logPathFor(run, name) {
  return path.join(run.dir, `${name}.log`);
}

function validEntry(entry, run) {
  if (!entry || typeof entry !== 'object' || Array.isArray(entry)) return false;
  if (!LEDGER_KINDS.includes(entry.kind)) return false;
  if (entry.kind === 'ios-simulator') {
    return ownedName(entry.name, run) && (entry.id === null || (typeof entry.id === 'string' && UDID_RE.test(entry.id)));
  }
  if (entry.kind === 'process') {
    return typeof entry.id === 'string' && PROCESS_NAME_RE.test(entry.id)
      && entry.ready === readyPathFor(run, entry.id)
      && entry.log === logPathFor(run, entry.id)
      && Number.isInteger(entry.supervisorPid) && entry.supervisorPid > 1
      && (entry.childPid === undefined || (Number.isInteger(entry.childPid) && entry.childPid > 1));
  }
  if (entry.kind === 'android-emulator') return typeof entry.id === 'string' && EMULATOR_RE.test(entry.id);
  if (entry.kind === 'kind-cluster') return ownedName(entry.id, run) && entry.kubeconfig === path.join(run.dir, KUBECONFIG_NAME);
  return ownedName(entry.id, run);
}

function ledgerPath(run) {
  return path.join(run.dir, LEDGER_NAME);
}

function readLedger(run) {
  const file = ledgerPath(run);
  let info;
  try {
    info = fs.lstatSync(file);
  } catch (error) {
    if (error.code === 'ENOENT') return { version: 1, runKey: run.key, resources: [] };
    throw error;
  }
  if (info.isSymbolicLink() || !info.isFile()) refuse('the resource ledger is not a regular file');
  if (info.size > MAX_LEDGER_BYTES) refuse('the resource ledger is too large');
  let ledger;
  try {
    ledger = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_error) {
    refuse('the resource ledger is not valid JSON');
  }
  if (!ledger || ledger.version !== 1 || ledger.runKey !== run.key || !Array.isArray(ledger.resources)) {
    refuse('the resource ledger does not belong to this run directory');
  }
  if (ledger.resources.length > MAX_RESOURCES) refuse('the resource ledger holds too many resources');
  for (const entry of ledger.resources) {
    if (!validEntry(entry, run)) refuse('the resource ledger holds an entry this run could not have recorded');
  }
  return ledger;
}

function writeLedger(run, ledger) {
  for (const entry of ledger.resources) {
    if (!validEntry(entry, run)) refuse('refusing to write a ledger entry this run could not read back');
  }
  const temp = path.join(run.dir, `.${LEDGER_NAME}.${process.pid}.${crypto.randomBytes(6).toString('hex')}.tmp`);
  fs.writeFileSync(temp, `${JSON.stringify(ledger, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
  fs.renameSync(temp, ledgerPath(run));
}

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function lockHolder(lock) {
  try {
    const value = Number(fs.readFileSync(lock, 'utf8').trim());
    return Number.isInteger(value) && value > 1 ? value : null;
  } catch (_error) {
    return null;
  }
}

function withLock(run, action) {
  const lock = path.join(run.dir, LOCK_NAME);
  const deadline = Date.now() + LOCK_WAIT_MS;
  let fd = null;
  while (fd === null) {
    try {
      fd = fs.openSync(lock, 'wx', 0o600);
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      if (Date.now() > deadline) {
        const holder = lockHolder(lock);
        refuse(holder !== null && !pidAlive(holder)
          ? `the resource ledger is locked by pid ${holder}, which no longer runs; remove ${LOCK_NAME} from the run directory and retry`
          : `the resource ledger is locked; remove ${LOCK_NAME} from the run directory only when no other call is running`);
      }
      sleepSync(50);
    }
  }
  try {
    fs.writeSync(fd, `${process.pid}\n`);
    return action();
  } finally {
    fs.closeSync(fd);
    fs.rmSync(lock, { force: true });
  }
}

function run(tool, args, timeout) {
  return spawnSync(tool, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout });
}

function missing(result) {
  return Boolean(result.error && result.error.code === 'ENOENT');
}

function checkToolArg(flag, value) {
  if (!TOOL_ARG_RE.test(value)) refuse(`${flag} must be a plain value that does not start with a dash`);
}

function listSimulators() {
  const result = run('xcrun', ['simctl', 'list', 'devices', '--json'], 60000);
  if (result.status !== 0) return null;
  try {
    const parsed = JSON.parse(result.stdout);
    const devices = [];
    for (const list of Object.values(parsed.devices || {})) {
      if (!Array.isArray(list)) continue;
      for (const device of list) {
        if (device && typeof device.udid === 'string' && typeof device.name === 'string') devices.push(device);
      }
    }
    return devices;
  } catch (_error) {
    return null;
  }
}

function createSimulator(target, flags) {
  checkToolArg('--device-type', flags['device-type']);
  if (flags.runtime !== undefined) checkToolArg('--runtime', flags.runtime);
  const name = withLock(target, () => {
    const ledger = readLedger(target);
    if (ledger.resources.length >= MAX_RESOURCES) refuse('the resource ledger is full');
    const taken = new Set(ledger.resources.filter((entry) => entry.kind === 'ios-simulator').map((entry) => entry.name));
    let chosen = prefixOf(target);
    for (let index = 2; taken.has(chosen); index += 1) chosen = `${prefixOf(target)}-${index}`;
    ledger.resources.push({ kind: 'ios-simulator', id: null, name: chosen });
    writeLedger(target, ledger);
    return chosen;
  });
  const args = ['simctl', 'create', name, flags['device-type']];
  if (flags.runtime !== undefined) args.push(flags.runtime);
  const result = run('xcrun', args, 120000);
  const udid = String(result.stdout || '').trim();
  const pending = (ledger) => ledger.resources.find((item) => item.kind === 'ios-simulator' && item.name === name);
  if (result.status === 0 && UDID_RE.test(udid)) {
    withLock(target, () => {
      const ledger = readLedger(target);
      const entry = pending(ledger);
      if (entry) entry.id = udid;
      else ledger.resources.push({ kind: 'ios-simulator', id: udid, name });
      writeLedger(target, ledger);
    });
    return { lines: [`udid=${udid}`, `name=${name}`], code: 0 };
  }
  const reason = missing(result) ? 'xcrun was not found on PATH' : (firstLine(result.stderr) || 'no UDID on stdout');
  const listed = missing(result) ? [] : listSimulators();
  const named = listed === null ? null : listed.filter((device) => device.name === name);
  withLock(target, () => {
    const ledger = readLedger(target);
    const entry = pending(ledger);
    if (!entry || named === null) return;
    if (named.length === 1) entry.id = named[0].udid;
    else if (named.length === 0) ledger.resources = ledger.resources.filter((item) => item !== entry);
    writeLedger(target, ledger);
  });
  refuse(`xcrun simctl create failed: ${reason}`);
}

function ensureLease(target) {
  const file = path.join(target.dir, LEASE_NAME);
  let info = null;
  try {
    info = fs.lstatSync(file);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  if (info === null) {
    const value = crypto.randomBytes(32).toString('hex');
    fs.writeFileSync(file, `${value}\n`, { mode: 0o600, flag: 'wx' });
    return value;
  }
  if (info.isSymbolicLink() || !info.isFile()) refuse('the supervisor lease is not a regular file');
  const value = fs.readFileSync(file, 'utf8').trim();
  if (!LEASE_RE.test(value)) refuse('the supervisor lease is malformed');
  return value;
}

function supervisorAvailable() {
  try {
    const info = fs.lstatSync(SUPERVISOR);
    return info.isFile() && !info.isSymbolicLink();
  } catch (_error) {
    return false;
  }
}

function supervisorRequest(target, ready, action, timeout) {
  return spawnSync(process.execPath, [SUPERVISOR, action, ready], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout,
    env: { ...process.env, ZENSU_VERIFY_RUNTIME_LEASE: ensureLease(target) },
  });
}

function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

function commandOf(pid) {
  const result = run('ps', ['-o', 'command=', '-p', String(pid)], 10000);
  return result.status === 0 ? String(result.stdout || '').trim() : null;
}

function start(target, flags, command) {
  if (process.platform === 'win32') refuse('a supervised start needs POSIX process groups, which native Windows does not have');
  const name = flags.name;
  if (!PROCESS_NAME_RE.test(name)) refuse('--name must be 1 to 32 lowercase letters, digits or dashes');
  const cwd = flags.cwd;
  if (!path.isAbsolute(cwd)) refuse('--cwd must be an absolute path');
  let cwdInfo;
  try {
    cwdInfo = fs.statSync(cwd);
  } catch (_error) {
    refuse('--cwd does not exist');
  }
  if (!cwdInfo.isDirectory()) refuse('--cwd must be a directory');
  if (!supervisorAvailable()) refuse('the process supervisor is unavailable or a symlink');
  const ready = readyPathFor(target, name);
  const log = logPathFor(target, name);
  const lease = ensureLease(target);
  const supervisorPid = withLock(target, () => {
    const ledger = readLedger(target);
    if (ledger.resources.some((entry) => entry.kind === 'process' && entry.id === name)) refuse(`a process named ${name} is already recorded for this run`);
    if (ledger.resources.length >= MAX_RESOURCES) refuse('the resource ledger is full');
    if (fs.existsSync(ready)) refuse(`${path.basename(ready)} already exists in the run directory`);
    const child = spawn(process.execPath, [SUPERVISOR, 'start', ready, log, cwd, command[0], ...command.slice(1)], {
      detached: true,
      stdio: 'ignore',
      env: { ...process.env, ZENSU_VERIFY_RUNTIME_LEASE: lease },
    });
    child.on('error', () => {});
    child.unref();
    if (!Number.isInteger(child.pid)) refuse(`the process supervisor for ${name} could not be started`);
    ledger.resources.push({ kind: 'process', id: name, ready, log, supervisorPid: child.pid });
    writeLedger(target, ledger);
    return child.pid;
  });
  const deadline = Date.now() + READY_WAIT_MS;
  let lastProblem = null;
  while (Date.now() < deadline) {
    if (fs.existsSync(ready)) {
      const status = supervisorRequest(target, ready, 'status', 5000);
      if (status.status === 0) {
        let childPid = null;
        try {
          childPid = JSON.parse(String(status.stdout).trim()).childPid;
        } catch (_error) {
          childPid = null;
        }
        if (Number.isInteger(childPid) && childPid > 1) {
          withLock(target, () => {
            const ledger = readLedger(target);
            const entry = ledger.resources.find((item) => item.kind === 'process' && item.id === name);
            if (entry) entry.childPid = childPid;
            writeLedger(target, ledger);
          });
        }
        return { lines: [`name=${name}`, `pid=${Number.isInteger(childPid) ? childPid : 'unknown'}`, `log=${log}`], code: 0 };
      }
      lastProblem = firstLine(status.stderr) || 'the supervisor status request failed';
    } else if (!pidAlive(supervisorPid)) {
      refuse(`the supervisor for ${name} exited before it became ready; read ${log} and run teardown`);
    }
    sleepSync(100);
  }
  refuse(lastProblem === null
    ? `the supervisor for ${name} did not become ready; read ${log} and run teardown`
    : `${name} is not running (${lastProblem}); read ${log} and run teardown`);
}

function record(target, flags) {
  const kind = flags.kind;
  if (!RECORD_KINDS.includes(kind)) refuse(`--kind must be one of ${RECORD_KINDS.join(', ')}`);
  const id = flags.id;
  if (kind === 'android-emulator') {
    if (!EMULATOR_RE.test(id)) refuse('an emulator serial must read emulator-<port>');
    const probe = adbListsSerial(id);
    if (probe.error) refuse(`${probe.error}; an emulator serial is recorded only when adb shows that no emulator uses its port`);
    if (probe.listed) refuse(`${id} is already running; choose a console port that no emulator uses`);
  } else if (!ownedName(id, target)) {
    refuse(`a ${kind} name must be ${prefixOf(target)} or start with ${prefixOf(target)}- followed by lowercase letters, digits or dashes`);
  }
  withLock(target, () => {
    const ledger = readLedger(target);
    if (ledger.resources.some((entry) => entry.kind === kind && entry.id === id)) refuse(`${kind} ${id} is already recorded`);
    if (ledger.resources.length >= MAX_RESOURCES) refuse('the resource ledger is full');
    const entry = { kind, id };
    if (kind === 'kind-cluster') entry.kubeconfig = path.join(target.dir, KUBECONFIG_NAME);
    ledger.resources.push(entry);
    writeLedger(target, ledger);
  });
  const lines = [`recorded=${kind} ${id}`];
  if (kind === 'kind-cluster') lines.push(`kubeconfig=${path.join(target.dir, KUBECONFIG_NAME)}`);
  return { lines, code: 0 };
}

const REMOVED = Object.freeze({ state: 'removed' });
const GONE = Object.freeze({ state: 'gone' });

function kept(reason) {
  return { state: 'kept', reason: safe(reason) };
}

function destroySimulator(entry) {
  const devices = listSimulators();
  if (devices === null) return kept('xcrun simctl list failed; iOS simulators need macOS with Xcode');
  let device;
  if (entry.id === null) {
    const named = devices.filter((item) => item.name === entry.name);
    if (named.length === 0) return GONE;
    if (named.length > 1) return kept('more than one simulator carries this run\'s name');
    device = named[0];
  } else {
    device = devices.find((item) => item.udid === entry.id);
    if (!device) return GONE;
  }
  if (device.name !== entry.name) return kept(`the simulator is named ${device.name}, not ${entry.name}`);
  if (device.state !== 'Shutdown') run('xcrun', ['simctl', 'shutdown', device.udid], 120000);
  const result = run('xcrun', ['simctl', 'delete', device.udid], 120000);
  if (result.status !== 0) return kept(`xcrun simctl delete failed: ${firstLine(result.stderr)}`);
  return REMOVED;
}

function groupAlive(pgid) {
  try {
    process.kill(-pgid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

function destroyProcess(target, entry) {
  const supervisor = `supervisor pid ${entry.supervisorPid}`;
  if (fs.existsSync(entry.ready)) {
    const result = supervisorRequest(target, entry.ready, 'stop', 20000);
    if (result.status === 0) return REMOVED;
    if (!pidAlive(entry.supervisorPid)) {
      if (!Number.isInteger(entry.childPid)) return kept(`the ${supervisor} ended without stopping its process group`);
      if (groupAlive(entry.childPid)) return kept(`the ${supervisor} ended without stopping its process group; process group ${entry.childPid} still runs`);
      fs.rmSync(entry.ready, { force: true });
      return GONE;
    }
  }
  if (!pidAlive(entry.supervisorPid)) return GONE;
  const commandLine = commandOf(entry.supervisorPid);
  if (commandLine === null || !commandLine.includes(SUPERVISOR) || !commandLine.includes(entry.ready)) {
    return kept(`the recorded ${supervisor} no longer runs this run's supervisor`);
  }
  try {
    process.kill(entry.supervisorPid, 'SIGTERM');
  } catch (error) {
    if (error.code === 'ESRCH') return GONE;
    return kept(`the ${supervisor} could not be signalled: ${error.code || error.message}`);
  }
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    if (!pidAlive(entry.supervisorPid)) return REMOVED;
    sleepSync(100);
  }
  return kept(`the ${supervisor} did not exit after SIGTERM`);
}

function adbListsSerial(serial) {
  const devices = run('adb', ['devices'], 30000);
  if (missing(devices)) return { error: 'adb was not found on PATH' };
  if (devices.status !== 0) return { error: `adb devices failed: ${firstLine(devices.stderr)}` };
  return { listed: String(devices.stdout || '').split(/\r?\n/).some((line) => line.split(/\s+/)[0] === serial) };
}

function destroyEmulator(entry) {
  const deadline = Date.now() + EMULATOR_GONE_WAIT_MS;
  for (;;) {
    const probe = adbListsSerial(entry.id);
    if (probe.error) return kept(probe.error);
    if (!probe.listed) return GONE;
    if (Date.now() > deadline) {
      return kept(`${entry.id} is still listed after the run's processes stopped, so an emulator this run did not start may hold that port`);
    }
    sleepSync(500);
  }
}

function destroyTmux(entry) {
  const result = run('tmux', ['-L', entry.id, 'kill-server'], 10000);
  if (missing(result)) return kept('tmux was not found on PATH');
  if (result.status === 0) return REMOVED;
  if (/no server running|error connecting|no such file/i.test(String(result.stderr || ''))) return GONE;
  return kept(`tmux kill-server failed: ${firstLine(result.stderr)}`);
}

function destroyKindCluster(entry) {
  const result = run('kind', ['delete', 'cluster', '--name', entry.id, '--kubeconfig', entry.kubeconfig], 300000);
  if (missing(result)) return kept('kind was not found on PATH');
  if (result.status === 0) return REMOVED;
  return kept(`kind delete cluster failed: ${firstLine(result.stderr)}`);
}

function destroyContainer(entry) {
  const result = run('docker', ['rm', '-f', entry.id], 60000);
  if (missing(result)) return kept('docker was not found on PATH');
  if (result.status === 0) return REMOVED;
  if (/no such container/i.test(String(result.stderr || ''))) return GONE;
  return kept(`docker rm failed: ${firstLine(result.stderr)}`);
}

function destroy(target, entry) {
  if (entry.kind === 'ios-simulator') return destroySimulator(entry);
  if (entry.kind === 'process') return destroyProcess(target, entry);
  if (entry.kind === 'android-emulator') return destroyEmulator(entry);
  if (entry.kind === 'tmux-socket') return destroyTmux(entry);
  if (entry.kind === 'kind-cluster') return destroyKindCluster(entry);
  return destroyContainer(entry);
}

function teardown(target) {
  return withLock(target, () => {
    const ledger = readLedger(target);
    const survivors = [];
    const lines = [];
    for (const entry of ledger.resources.slice().reverse()) {
      let outcome;
      try {
        outcome = destroy(target, entry);
      } catch (error) {
        outcome = kept(error.message);
      }
      const label = entry.id === null ? entry.name : entry.id;
      lines.push(`${outcome.state} ${entry.kind} ${label}${outcome.reason ? `: ${outcome.reason}` : ''}`);
      if (outcome.state === 'kept') survivors.unshift(entry);
    }
    ledger.resources = survivors;
    writeLedger(target, ledger);
    lines.push(survivors.length === 0 ? 'teardown=complete' : `teardown=incomplete kept=${survivors.length}`);
    return { lines, code: survivors.length === 0 ? 0 : 1 };
  });
}

function list(target) {
  const ledger = readLedger(target);
  const lines = [`prefix=${prefixOf(target)}`];
  for (const entry of ledger.resources) lines.push(`resource=${entry.kind} ${entry.id === null ? entry.name : entry.id}`);
  return { lines, code: 0 };
}

function main(argv) {
  const options = parseArgs(argv);
  const target = resolveRunDir(options.flags['run-dir']);
  if (options.verb === 'create-simulator') return createSimulator(target, options.flags);
  if (options.verb === 'start') return start(target, options.flags, options.command);
  if (options.verb === 'record') return record(target, options.flags);
  if (options.verb === 'teardown') return teardown(target);
  return list(target);
}

module.exports = {
  EMULATOR_RE,
  LEDGER_NAME,
  NAME_PREFIX,
  RECORD_KINDS,
  UDID_RE,
  VERB_NAMES: Object.freeze(Object.keys(VERBS)),
  Refusal,
  main,
  ownedName,
  parseArgs,
  resolveRunDir,
  runKeyFor,
};

if (require.main === module) {
  try {
    const result = main(process.argv.slice(2));
    process.stdout.write(`${result.lines.join('\n')}\n`);
    process.exitCode = result.code;
  } catch (error) {
    process.stderr.write(`zensu verify run resources: ${error instanceof Refusal ? error.message : safe(error.message)}\n`);
    process.exitCode = 1;
  }
}
