#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const {
  EXECUTION_MODES,
  OLD_RELEASE_REVISION,
  line,
  REQUIRED_SEQUENCE,
} = require('./upgrade-attestation.js');

const OLD_REF = 'v0.16.1';
const OLD_VERSION = '0.16.1';
const MAX_STREAM_BYTES = 32 * 1024 * 1024;
const PROCESS_TIMEOUT_MS = 180000;
const BASH_PROBE_COMMAND = "printf '%s\\n' ZENSU_UPGRADE_BASH_OK";
const BASH_PROBE_OUTPUT = 'ZENSU_UPGRADE_BASH_OK';
const OLD_TURN_TOKENS = [
  'OLD_ROOT_TURN_ONE_OK',
  'OLD_ROOT_TURN_TWO_OK',
  'OLD_ROOT_TURN_THREE_OK',
];
const CANDIDATE_TOKEN = 'FRESH_CANDIDATE_OK';
const SAFE_DIAGNOSTIC_ERRORS = new WeakSet();
const safeErrorAdd = Function.call.bind(WeakSet.prototype.add);
const safeErrorHas = Function.call.bind(WeakSet.prototype.has);
const INSTALLER = path.resolve(
  __dirname,
  '..', '..', '..', 'tests', 'structure', 'fixtures', 'install-claude-runtime-fixture.js',
);

function providerError(message) {
  const error = new Error(`session-control upgrade provider: ${message}`);
  safeErrorAdd(SAFE_DIAGNOSTIC_ERRORS, error);
  return error;
}

function fail(message) {
  throw providerError(message);
}

function safeJson(text, label) {
  try { return JSON.parse(text); }
  catch (_error) { fail(`${label} is invalid JSON`); }
}

function realDirectory(input, label) {
  if (typeof input !== 'string' || !input || /[\0\r\n]/.test(input)) fail(`${label} is invalid`);
  let stat;
  try { stat = fs.lstatSync(input); }
  catch (_error) { fail(`${label} is unavailable`); }
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail(`${label} must be a real directory`);
  return fs.realpathSync.native(input);
}

function inside(parent, child) {
  const relative = path.relative(parent, child);
  return relative === '' || (relative !== '..' && !relative.startsWith(`..${path.sep}`)
    && !path.isAbsolute(relative));
}

function gitProcess(root, gitArguments) {
  return spawnSync('git', ['-C', root, ...gitArguments], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    env: {
      PATH: process.env.PATH || '',
      HOME: process.env.HOME || os.homedir(),
      TMPDIR: process.env.TMPDIR || os.tmpdir(),
      LANG: 'C',
      LC_ALL: 'C',
      GIT_CONFIG_NOSYSTEM: '1',
      GIT_CONFIG_GLOBAL: process.platform === 'win32' ? 'NUL' : '/dev/null',
      GIT_TERMINAL_PROMPT: '0',
    },
  });
}

function git(root, gitArguments) {
  const result = gitProcess(root, gitArguments);
  if (result.status !== 0) {
    fail(`git ${gitArguments[0]} failed`);
  }
  return result.stdout.trim();
}

function gitIsAncestor(root, ancestor, descendant) {
  const result = gitProcess(root, ['merge-base', '--is-ancestor', ancestor, descendant]);
  if (result.status === 0) return true;
  if (result.status === 1) return false;
  fail('git merge-base failed');
}

function safeManifest(root, label) {
  const file = path.join(root, '.claude-plugin', 'plugin.json');
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 1024 * 1024) {
    fail(`${label} plugin manifest is unsafe`);
  }
  const manifest = safeJson(fs.readFileSync(file, 'utf8'), `${label} plugin manifest`);
  if (manifest?.name !== 'zensu' || !/^\d+\.\d+\.\d+$/.test(manifest.version || '')) {
    fail(`${label} plugin manifest identity is invalid`);
  }
  return manifest;
}

function compareVersion(left, right) {
  const a = left.split('.').map(Number);
  const b = right.split('.').map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] - b[index];
  }
  return 0;
}

function installedVersion(sourceVersion) {
  const comparison = compareVersion(sourceVersion, OLD_VERSION);
  if (comparison < 0) fail('candidate source version predates v0.16.1');
  if (comparison > 0) return { synthetic: false, version: sourceVersion };
  const [major, minor, patch] = OLD_VERSION.split('.').map(Number);
  return { synthetic: true, version: `${major}.${minor}.${patch + 1}` };
}

function hash(value) {
  return `sha256:${crypto.createHash('sha256').update(value).digest('hex')}`;
}

function snapshotTree(rootInput, inventory = null) {
  const root = realDirectory(rootInput, 'runtime root');
  const digest = crypto.createHash('sha256');
  let files = 0;
  let bytes = 0;
  const visit = (directory, relative) => {
    for (const name of fs.readdirSync(directory).sort()) {
      const file = path.join(directory, name);
      const rel = relative ? `${relative}/${name}` : name;
      if (!relative && (name === '.in_use' || name === '.orphaned_at')) continue;
      const stat = fs.lstatSync(file);
      if (stat.isSymbolicLink()) {
        fail(`runtime snapshot contains a symlink; entry_sha256=${hash(Buffer.from(rel, 'utf8'))}`);
      }
      if (stat.isDirectory()) {
        digest.update(`d\0${rel}\0`, 'utf8');
        if (inventory) inventory.set(rel, 'directory');
        visit(file, rel);
      } else if (stat.isFile()) {
        files += 1;
        bytes += stat.size;
        if (files > 12000 || stat.size > 8 * 1024 * 1024 || bytes > 96 * 1024 * 1024) {
          fail('runtime snapshot exceeds its bounded surface');
        }
        const content = fs.readFileSync(file);
        digest.update(`f\0${rel}\0${stat.size}\0`, 'utf8');
        digest.update(content);
        digest.update('\0', 'utf8');
        if (inventory) inventory.set(rel, `file:${stat.size}:${hash(content)}`);
      } else {
        fail(`runtime snapshot contains an unsupported entry; entry_sha256=${hash(Buffer.from(rel, 'utf8'))}`);
      }
    }
  };
  visit(root, '');
  return `sha256:${digest.digest('hex')}`;
}

function changedTreeEntries(before, after) {
  const paths = [...new Set([...before.keys(), ...after.keys()])].sort();
  const changed = paths.filter((entry) => before.get(entry) !== after.get(entry));
  return `count=${changed.length},sha256=${hash(Buffer.from(JSON.stringify(changed), 'utf8'))}`;
}

function orphanMarker(rootInput, label) {
  const root = realDirectory(rootInput, `${label} runtime root`);
  const file = path.join(root, '.orphaned_at');
  let stat;
  try { stat = fs.lstatSync(file); }
  catch (error) {
    if (error.code === 'ENOENT') return null;
    fail(`${label} .orphaned_at marker cannot be inspected`);
  }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size !== 13
      || (process.platform !== 'win32' && (stat.mode & 0o022) !== 0)) {
    fail(`${label} .orphaned_at marker is unsafe`);
  }
  const content = fs.readFileSync(file, 'utf8');
  if (!/^[1-9][0-9]{12}$/.test(content)) fail(`${label} .orphaned_at marker is unsafe`);
  const timestampMs = Number(content);
  if (!Number.isSafeInteger(timestampMs) || Math.abs(stat.mtimeMs - timestampMs) > 2000) {
    fail(`${label} .orphaned_at marker timestamp and mtime disagree`);
  }
  return {
    timestampMs,
    fingerprint: hash(Buffer.from(`${content}\0${stat.mtimeMs}\0${stat.mode & 0o777}`, 'utf8')),
  };
}

function requireOrphanMarker(root, present, activationWindow, label) {
  const marker = orphanMarker(root, label);
  if (!present) {
    if (marker) fail(`${label} unexpectedly has .orphaned_at`);
    return null;
  }
  if (!marker) fail(`${label} is missing .orphaned_at`);
  if (activationWindow) {
    const start = Number(activationWindow.startedAtMs);
    const end = Number(activationWindow.endedAtMs);
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || end < start
        || marker.timestampMs < start - 2000 || marker.timestampMs > end + 2000) {
      fail(`${label} .orphaned_at timestamp is outside the candidate activation window`);
    }
  }
  return marker;
}

function inUseMarkerPids(rootInput, label) {
  const root = realDirectory(rootInput, `${label} runtime root`);
  const directory = path.join(root, '.in_use');
  let stat;
  try { stat = fs.lstatSync(directory); }
  catch (error) {
    if (error.code === 'ENOENT') return [];
    fail(`${label} .in_use marker cannot be inspected`);
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail(`${label} .in_use marker is unsafe`);
  const names = fs.readdirSync(directory).sort();
  if (names.length > 8) fail(`${label} has too many .in_use markers`);
  for (const name of names) {
    if (!/^[1-9][0-9]*$/.test(name)) fail(`${label} .in_use marker name is invalid`);
    const marker = fs.lstatSync(path.join(directory, name));
    if (!marker.isFile() || marker.isSymbolicLink() || marker.size > 128) {
      fail(`${label} .in_use marker file is unsafe`);
    }
  }
  return names;
}

function requireInUseMarker(root, pid, present, label) {
  const expected = String(pid || '');
  if (!/^[1-9][0-9]*$/.test(expected)) fail(`${label} process id is invalid`);
  const actual = inUseMarkerPids(root, label);
  if (present && (actual.length !== 1 || actual[0] !== expected)) {
    fail(`${label} does not have exactly its own active .in_use marker`);
  }
  if (!present && actual.length !== 0) fail(`${label} retained an .in_use marker after process exit`);
}

function snapshotMetadata(paths) {
  const digest = crypto.createHash('sha256');
  let entries = 0;
  const visit = (target, label) => {
    let stat;
    try { stat = fs.lstatSync(target); }
    catch (error) {
      if (error.code === 'ENOENT') {
        digest.update(`missing\0${label}\0`, 'utf8');
        return;
      }
      fail(`cannot inspect existing-login host canary; entry_sha256=${hash(Buffer.from(label, 'utf8'))}`);
    }
    entries += 1;
    if (entries > 30000) fail('existing-login host canaries exceed their bounded surface');
    const type = stat.isDirectory() ? 'd' : stat.isFile() ? 'f' : stat.isSymbolicLink() ? 'l' : 'o';
    digest.update(`${type}\0${label}\0${stat.mode}\0${stat.size}\0${stat.mtimeMs}\0`, 'utf8');
    if (stat.isSymbolicLink()) {
      digest.update(`${fs.readlinkSync(target)}\0`, 'utf8');
      return;
    }
    if (!stat.isDirectory()) return;
    for (const name of fs.readdirSync(target).sort()) visit(path.join(target, name), `${label}/${name}`);
  };
  paths.forEach((target, index) => visit(target, `canary-${index}`));
  return `sha256:${digest.digest('hex')}`;
}

function existingLoginCanary(hostHome) {
  const hostConfig = path.join(hostHome, '.claude');
  return snapshotMetadata([
    path.join(hostConfig, 'settings.json'),
    path.join(hostConfig, 'plugins', 'installed_plugins.json'),
    path.join(hostConfig, 'plugins', 'cache'),
  ]);
}

function runtimeDigest(core, root) {
  const value = core.computeRuntimeDigest(root, 'claude');
  if (!/^sha256:[a-f0-9]{64}$/.test(value)) fail('runtime digest is malformed');
  return value;
}

function install(source, destination, version) {
  if (fs.existsSync(destination)) fail('immutable version destination already exists');
  const result = spawnSync(process.execPath, [INSTALLER, source, destination, version], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.status !== 0) fail('runtime installation failed');
  const installed = realDirectory(result.stdout.trim(), 'installed runtime root');
  if (installed !== fs.realpathSync.native(destination)) fail('runtime installer returned the wrong root');
  if (safeManifest(installed, 'installed').version !== version) fail('installed runtime version drifted');
  return installed;
}

function atomicJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(value)}\n`, { encoding: 'utf8', mode: 0o600, flag: 'wx' });
  fs.renameSync(temporary, file);
}

function writeRegistry(home, root, version, revision) {
  if (!inside(home, root)) fail('installed runtime escaped the isolated HOME');
  atomicJson(path.join(home, '.claude', 'settings.json'), {
    enabledPlugins: { 'zensu@zensu': true },
  });
  atomicJson(path.join(home, '.claude', 'plugins', 'installed_plugins.json'), {
    version: 2,
    plugins: {
      'zensu@zensu': [{
        scope: 'user', installPath: root, version, gitCommitSha: revision,
      }],
    },
  });
}

function pluginDataPath(pluginRoot) {
  const pluginId = 'zensu@zensu';
  const directory = pluginId.replace(/[^A-Za-z0-9._-]+/g, '-');
  if (directory !== 'zensu-zensu') fail('Claude plugin-data identifier mapping drifted');
  return path.join(pluginRoot, 'data', directory);
}

function createProject(root) {
  fs.mkdirSync(root, { recursive: true, mode: 0o700 });
  fs.writeFileSync(path.join(root, 'old-turn-1.txt'), `${OLD_TURN_TOKENS[0]}\n`, { mode: 0o600 });
  fs.writeFileSync(path.join(root, 'old-turn-2.txt'), `${OLD_TURN_TOKENS[1]}\n`, { mode: 0o600 });
  fs.writeFileSync(path.join(root, 'old-turn-3.txt'), `${OLD_TURN_TOKENS[2]}\n`, { mode: 0o600 });
  fs.writeFileSync(path.join(root, 'candidate-turn.txt'), `${CANDIDATE_TOKEN}\n`, { mode: 0o600 });
  const result = spawnSync('git', ['init', '-q'], { cwd: root, encoding: 'utf8' });
  if (result.status !== 0) fail('cannot initialize isolated upgrade project');
  for (const args of [
    ['config', 'user.name', 'Zensu Upgrade Eval'],
    ['config', 'user.email', 'upgrade-eval@zensu.invalid'],
    ['config', 'core.hooksPath', process.platform === 'win32' ? 'NUL' : '/dev/null'],
    ['add', '.'],
    ['-c', 'commit.gpgsign=false', 'commit', '-qm', 'test: seed upgrade fixture'],
  ]) {
    const command = spawnSync('git', args, { cwd: root, encoding: 'utf8' });
    if (command.status !== 0) fail(`cannot prepare isolated upgrade project: git ${args[0]}`);
  }
}

function shellQuote(value) {
  if (/['\0\r\n]/.test(value)) fail('cannot quote unsafe shell path');
  return `'${value}'`;
}

function createBashGuard(control) {
  const script = path.join(control, 'exact-bash-guard.js');
  const trace = path.join(control, 'exact-bash-guard.jsonl');
  fs.writeFileSync(script, [
    "'use strict';",
    "const fs=require('node:fs');",
    `const expected=${JSON.stringify(BASH_PROBE_COMMAND)};`,
    `const trace=${JSON.stringify(trace)};`,
    "let input='';",
    "process.stdin.setEncoding('utf8');",
    "process.stdin.on('data',(chunk)=>{input+=chunk;if(Buffer.byteLength(input)>65536)process.exit(2);});",
    "process.stdin.on('end',()=>{",
    "  let event;try{event=JSON.parse(input);}catch(_error){process.exit(2);}",
    "  const toolInput=event&&event.tool_input;",
    "  const keys=toolInput&&typeof toolInput==='object'&&!Array.isArray(toolInput)?Object.keys(toolInput):[];",
    "  const sorted=[...keys].sort();",
    "  const canonicalKeys=JSON.stringify(sorted)==='[\\\"command\\\"]'||JSON.stringify(sorted)==='[\\\"command\\\",\\\"description\\\"]';",
    "  const description=toolInput&&toolInput.description;",
    "  const validDescription=description===undefined||(typeof description==='string'&&Buffer.byteLength(description)<=512&&!/[\\0\\r\\n]/.test(description));",
    "  if(event?.hook_event_name!=='PreToolUse'||event?.tool_name!=='Bash'||!canonicalKeys||!validDescription||toolInput.command!==expected){",
    "    process.stderr.write('upgrade harness rejected non-canonical Bash input\\n');process.exit(2);",
    "  }",
    "  fs.appendFileSync(trace,JSON.stringify({status:0,command_sha256:require('node:crypto').createHash('sha256').update(expected).digest('hex')})+'\\n',{encoding:'utf8',mode:0o600});",
    "});",
  ].join('\n'), { mode: 0o500 });
  return { script, trace };
}

function commandLineSettings(guard, hostHome) {
  const sandbox = {
    enabled: true,
    failIfUnavailable: true,
    autoAllowBashIfSandboxed: false,
    allowUnsandboxedCommands: false,
  };
  if (hostHome) sandbox.filesystem = { denyRead: [hostHome] };
  return JSON.stringify({
    sandbox,
    hooks: {
      PreToolUse: [{
        matcher: 'Bash',
        hooks: [{ type: 'command', command: `${shellQuote(process.execPath)} ${shellQuote(guard.script)}` }],
      }],
    },
  });
}

function createTraceBoundary(control, oldRoot, candidateRoot) {
  const trace = path.join(control, 'hook-trace.jsonl');
  const testMode = process.env.ZENSU_UPGRADE_TEST_MODE === '1';
  if (testMode) return { bin: null, trace };
  const realBashProbe = spawnSync('bash', ['--noprofile', '--norc', '-c', 'command -v bash'], { encoding: 'utf8' });
  if (realBashProbe.status !== 0) fail('cannot resolve the real Bash runtime');
  const realBash = fs.realpathSync.native(realBashProbe.stdout.trim());
  const bin = path.join(control, 'trace-bin');
  const logger = path.join(control, 'trace-append.js');
  fs.mkdirSync(bin, { mode: 0o700 });
  fs.writeFileSync(logger, [
    "'use strict';",
    "const fs=require('node:fs');",
    'const [file,hook,status]=process.argv.slice(2);',
    "if(!/^[0-9]+$/.test(status||''))process.exit(2);",
    "fs.appendFileSync(file,`${JSON.stringify({hook,status:Number(status)})}\\n`,'utf8');",
  ].join('\n'), { mode: 0o500 });
  const wrapper = path.join(bin, 'bash');
  fs.writeFileSync(wrapper, `#!/bin/bash\nset +e\ntarget="\${1:-}"\n${shellQuote(realBash)} "$@"\nstatus=$?\ncase "$target" in\n  ${shellQuote(oldRoot)}/hooks/*|${shellQuote(candidateRoot)}/hooks/*)\n    ${shellQuote(process.execPath)} ${shellQuote(logger)} ${shellQuote(trace)} "$target" "$status"\n    ;;\nesac\nexit "$status"\n`, { mode: 0o700 });
  return { bin, trace };
}

function traceEntries(file) {
  if (!fs.existsSync(file)) return [];
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 4 * 1024 * 1024) {
    fail('hook trace is unsafe');
  }
  return fs.readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean).map((raw) => {
    const entry = safeJson(raw, 'hook trace entry');
    if (!entry || typeof entry.hook !== 'string' || !Number.isInteger(entry.status)) {
      fail('hook trace entry shape is invalid');
    }
    return entry;
  });
}

function requireBashGuardTrace(file) {
  if (!fs.existsSync(file)) fail('fresh candidate exact Bash guard trace is missing');
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 64 * 1024) {
    fail('fresh candidate exact Bash guard trace is unsafe');
  }
  const entries = fs.readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean)
    .map((raw) => safeJson(raw, 'exact Bash guard trace entry'));
  const expectedHash = crypto.createHash('sha256').update(BASH_PROBE_COMMAND).digest('hex');
  if (entries.length !== 1 || entries[0]?.status !== 0
      || entries[0]?.command_sha256 !== expectedHash || Object.keys(entries[0]).length !== 2) {
    fail('fresh candidate exact Bash guard did not run successfully exactly once');
  }
}

function requireTrace(entries, root, basename, count, label) {
  const matching = entries.filter((entry) => (
    path.basename(entry.hook) === basename
      && inside(root, path.resolve(entry.hook))
  ));
  const hookHash = hash(Buffer.from(basename, 'utf8'));
  if (matching.length !== count) {
    fail(`${label} expected hook count=${count}; observed=${matching.length}; hook_sha256=${hookHash}`);
  }
  if (matching.some((entry) => entry.status !== 0)) {
    fail(`${label} observed a nonzero hook result; hook_sha256=${hookHash}`);
  }
}

function requireTraceScope(entries, expectedRoot, forbiddenRoot, label) {
  if (entries.length === 0) fail(`${label} produced no hook trace`);
  for (const entry of entries) {
    const hook = path.resolve(entry.hook);
    if (!inside(expectedRoot, hook) || inside(forbiddenRoot, hook)) {
      fail(`${label} executed a hook from the wrong plugin root`);
    }
    if (entry.status !== 0) fail(`${label} observed a nonzero hook response`);
  }
}

function cliCommand() {
  if (process.env.ZENSU_UPGRADE_TEST_MODE === '1') {
    const file = process.env.ZENSU_UPGRADE_TEST_CLAUDE_SCRIPT || '';
    const stat = file ? fs.lstatSync(file) : null;
    if (!stat || !stat.isFile() || stat.isSymbolicLink()) fail('fake Claude script is unavailable');
    return { command: process.execPath, prefix: [fs.realpathSync.native(file)] };
  }
  return { command: 'claude', prefix: [] };
}

function childEnvironment(home, temporary, config, traceBoundary) {
  const existingLogin = process.env.ZENSU_UPGRADE_EXISTING_LOGIN === '1';
  const configRoot = path.join(home, '.claude');
  const pluginRoot = path.join(configRoot, 'plugins');
  const isolatedTemp = path.join(temporary, 'tmp');
  const env = {
    PATH: traceBoundary.bin ? `${traceBoundary.bin}${path.delimiter}${process.env.PATH || ''}` : (process.env.PATH || ''),
    HOME: existingLogin ? process.env.HOME : home,
    CLAUDE_CODE_PLUGIN_CACHE_DIR: pluginRoot,
    XDG_CONFIG_HOME: path.join(home, '.config'),
    XDG_CACHE_HOME: path.join(home, '.cache'),
    XDG_DATA_HOME: path.join(home, '.local', 'share'),
    TMPDIR: isolatedTemp,
    TEMP: isolatedTemp,
    TMP: isolatedTemp,
    CLAUDE_CODE_TMPDIR: isolatedTemp,
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
    CLAUDE_CODE_SKIP_PROMPT_HISTORY: '1',
    ZENSU_CONFIG: config,
  };
  if (!existingLogin) env.CLAUDE_CONFIG_DIR = configRoot;
  const forwarded = [
    'ANTHROPIC_BASE_URL',
    'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY',
    'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy',
    'SSL_CERT_FILE', 'SSL_CERT_DIR', 'NODE_EXTRA_CA_CERTS',
    'SHELL', 'TERM', 'LANG', 'LC_ALL', 'CI', 'USER', 'LOGNAME',
    'SYSTEMROOT', 'WINDIR', 'COMSPEC', 'PATHEXT',
  ];
  if (!existingLogin) forwarded.unshift('ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN');
  for (const name of forwarded) {
    if (process.env[name]) env[name] = process.env[name];
  }
  if (process.env.ZENSU_UPGRADE_TEST_MODE === '1') {
    env.ZENSU_UPGRADE_SELFTEST_TRACE_FILE = traceBoundary.trace;
    env.ZENSU_UPGRADE_SELFTEST_CONTROL_DIR = path.dirname(traceBoundary.trace);
    env.ZENSU_UPGRADE_SELFTEST_PLUGIN_DATA = pluginDataPath(pluginRoot);
    env.ZENSU_UPGRADE_SELFTEST_FAULT = process.env.ZENSU_UPGRADE_SELFTEST_FAULT || '';
  }
  fs.mkdirSync(env.XDG_CONFIG_HOME, { recursive: true, mode: 0o700 });
  fs.mkdirSync(env.XDG_CACHE_HOME, { recursive: true, mode: 0o700 });
  fs.mkdirSync(env.XDG_DATA_HOME, { recursive: true, mode: 0o700 });
  fs.mkdirSync(env.TMPDIR, { recursive: true, mode: 0o700 });
  return env;
}

class StreamSession {
  constructor(command, args, options) {
    this.events = [];
    this.results = [];
    this.stderr = '';
    this.stdoutBytes = 0;
    this.buffer = '';
    this.closed = false;
    this.error = null;
    this.waiters = [];
    this.child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.child.stdout.setEncoding('utf8');
    this.child.stderr.setEncoding('utf8');
    this.child.stdout.on('data', (chunk) => this.onStdout(chunk));
    this.child.stderr.on('data', (chunk) => {
      this.stderr += chunk;
      if (Buffer.byteLength(this.stderr) > MAX_STREAM_BYTES) this.abort('stderr exceeded its bound');
    });
    this.exit = new Promise((resolve) => {
      this.child.on('error', (error) => {
        const diagnostic = redactedTextDiagnostic(error?.message);
        this.error = providerError([
          'Claude process could not start',
          `error_category=${diagnostic.category}`,
          `error_bytes=${diagnostic.bytes}`,
          `error_sha256=${diagnostic.sha256}`,
        ].join('; '));
        this.flushWaiters();
      });
      this.child.on('close', (status, signal) => {
        this.closed = true;
        this.status = status;
        this.signal = signal;
        this.flushWaiters();
        resolve({ status, signal });
      });
    });
  }

  abort(message) {
    if (!this.error) this.error = providerError(message);
    this.child.kill('SIGKILL');
    this.flushWaiters();
  }

  onStdout(chunk) {
    this.stdoutBytes += Buffer.byteLength(chunk);
    if (this.stdoutBytes > MAX_STREAM_BYTES) return this.abort('stdout exceeded its bound');
    this.buffer += chunk;
    while (this.buffer.includes('\n')) {
      const newline = this.buffer.indexOf('\n');
      const raw = this.buffer.slice(0, newline).replace(/\r$/, '');
      this.buffer = this.buffer.slice(newline + 1);
      if (!raw) continue;
      try {
        const event = JSON.parse(raw);
        this.events.push(event);
        if (event?.type === 'result') this.results.push(event);
      } catch (_error) {
        return this.abort('Claude stream contains malformed JSON');
      }
      this.flushWaiters();
    }
  }

  flushWaiters() {
    const remaining = [];
    for (const waiter of this.waiters) {
      if (this.error) waiter.reject(this.error);
      else if (this.results.length >= waiter.count) waiter.resolve(this.results[waiter.count - 1]);
      else if (this.closed) {
        const stderr = redactedTextDiagnostic(this.stderr);
        waiter.reject(providerError([
          `Claude exited before result ${waiter.count}`,
          `status=${String(this.status ?? 'none')}`,
          `signal=${String(this.signal || 'none')}`,
          `stderr_category=${stderr.category}`,
          `stderr_bytes=${stderr.bytes}`,
          `stderr_sha256=${stderr.sha256}`,
        ].join('; ')));
      }
      else remaining.push(waiter);
    }
    this.waiters = remaining;
  }

  send(prompt) {
    if (this.closed || this.error) fail('cannot write to a closed Claude stream');
    const envelope = {
      type: 'user',
      message: { role: 'user', content: prompt },
      parent_tool_use_id: null,
    };
    this.child.stdin.write(`${JSON.stringify(envelope)}\n`);
  }

  waitForResult(count) {
    if (this.results.length >= count) return Promise.resolve(this.results[count - 1]);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.abort(`Claude timed out before result ${count}`);
        reject(this.error);
      }, PROCESS_TIMEOUT_MS);
      this.waiters.push({
        count,
        resolve: (value) => { clearTimeout(timer); resolve(value); },
        reject: (error) => { clearTimeout(timer); reject(error); },
      });
      this.flushWaiters();
    });
  }

  async close() {
    this.child.stdin.end();
    const timer = setTimeout(() => this.abort('Claude did not exit after stream EOF'), 60000);
    const result = await this.exit;
    clearTimeout(timer);
    if (this.buffer.trim()) fail('Claude stream ended with an unterminated JSON record');
    if (this.error) throw this.error;
    if (result.status !== 0 || result.signal) {
      fail(`Claude exited nonzero after stream EOF: status=${result.status}; signal=${result.signal || 'none'}`);
    }
  }

  async terminate() {
    const waitForClose = async (timeoutMs) => {
      let timer;
      const closed = await Promise.race([
        this.exit.then(() => true),
        new Promise((resolve) => { timer = setTimeout(() => resolve(false), timeoutMs); }),
      ]);
      if (timer) clearTimeout(timer);
      return closed;
    };
    if (this.closed) {
      await this.exit;
      return;
    }
    try { this.child.stdin.destroy(); } catch (_error) { /* already closed */ }
    this.child.kill('SIGTERM');
    if (!await waitForClose(5000)) {
      this.child.kill('SIGKILL');
      if (!await waitForClose(5000)) fail('Claude process did not close after SIGKILL');
    }
    await this.exit;
  }
}

function claudeReadRule(file) {
  if (!path.isAbsolute(file) || /[\0\r\n*?\[\]!#]/.test(file)) {
    fail('Read fixture cannot be represented as an exact Claude permission rule');
  }
  let normalized = file.split(path.sep).join('/');
  if (/^[A-Za-z]:\//.test(normalized)) {
    normalized = `/${normalized[0].toLowerCase()}${normalized.slice(2)}`;
  }
  if (!normalized.startsWith('/')) fail('Read fixture did not normalize to an absolute path');
  return `Read(/${normalized})`;
}

function claudeArgs(sessionId, allowedReadFiles, settings, diagnosticPluginRoot = null) {
  if (!Array.isArray(allowedReadFiles) || allowedReadFiles.length !== 4
      || new Set(allowedReadFiles).size !== 4) {
    fail('Claude permission boundary requires exactly four distinct Read fixtures');
  }
  const readRules = allowedReadFiles.map(claudeReadRule);
  if (typeof settings !== 'string' || !settings.startsWith('{') || /[\0\r\n]/.test(settings)) {
    fail('Claude command-line settings are invalid');
  }
  const diagnosticRoot = diagnosticPluginRoot === null
    ? null
    : realDirectory(diagnosticPluginRoot, 'diagnostic plugin root');
  if (diagnosticRoot !== null && /[\0\r\n]/.test(diagnosticRoot)) {
    fail('diagnostic plugin root is invalid');
  }
  const args = [
    '--print',
    '--input-format', 'stream-json',
    '--output-format', 'stream-json',
    '--verbose',
    '--permission-mode', 'dontAsk',
    '--no-session-persistence',
    '--disable-slash-commands',
    '--strict-mcp-config',
    '--mcp-config', '{"mcpServers":{}}',
    '--setting-sources', diagnosticRoot === null ? 'user' : '',
    '--settings', settings,
    '--tools', 'Read,Bash',
    '--allowedTools', ...readRules, `Bash(${BASH_PROBE_COMMAND})`,
    '--max-turns', '12',
    '--session-id', sessionId,
  ];
  if (diagnosticRoot !== null) args.push('--plugin-dir', diagnosticRoot);
  return args;
}

function promptFor(file) {
  return `Use the Read tool exactly once with file_path ${JSON.stringify(file)}. The file contains one opaque token that is not present in this prompt. Use no other tool. After the successful Read result, reply with exactly the opaque token from the file and no other text.`;
}

function candidatePromptFor(file) {
  return `Use the Read tool exactly once with file_path ${JSON.stringify(file)}. The file contains one opaque token that is not present in this prompt. Then use the Bash tool exactly once with command ${JSON.stringify(BASH_PROBE_COMMAND)}. The command is a harmless shell builtin and must not be changed. Use no other tool. After both successful tool results, reply with exactly the opaque token from the file and no other text.`;
}

function observedToolShape(uses) {
  const shape = uses.slice(0, 64).map((use) => {
    const name = typeof use?.name === 'string' ? use.name : '';
    const keys = use?.input && typeof use.input === 'object' && !Array.isArray(use.input)
      ? Object.keys(use.input).sort() : [];
    return {
      tool_category: name === 'Read' || name === 'Bash' ? name : 'other',
      tool_name_bytes: Buffer.byteLength(name),
      tool_name_sha256: hash(Buffer.from(name, 'utf8')),
      input_kind: use?.input && typeof use.input === 'object' && !Array.isArray(use.input)
        ? 'object' : 'other',
      input_key_count: keys.length,
      input_key_sha256: hash(Buffer.from(JSON.stringify(keys), 'utf8')),
    };
  });
  return [
    `tool_count=${uses.length}`,
    `tool_shape_sha256=${hash(Buffer.from(JSON.stringify(shape), 'utf8'))}`,
  ].join('; ');
}

function redactedTextDiagnostic(value) {
  const text = typeof value === 'string' ? value : '';
  let category = 'other';
  if (!text.trim()) category = 'empty';
  else if (/permission|not allowed|denied|approval/i.test(text)) category = 'permission-denied';
  else if (/tool.{0,40}(?:unavailable|not available|not found|disabled)/i.test(text)) category = 'tool-unavailable';
  else if (/auth|login|sign[ -]?in|credential/i.test(text)) category = 'authentication';
  else if (/sandbox|bubblewrap|bwrap|socat|apparmor/i.test(text)) category = 'sandbox';
  else if (/max(?:imum)? turns|turn limit/i.test(text)) category = 'turn-limit';
  else if (/session control|zensu/i.test(text)) category = 'session-control';
  else if (/\bread\b/i.test(text)) category = 'mentions-read';
  else if (/opaque|token/i.test(text)) category = 'mentions-task';
  else if (/cannot|can't|unable|won't|will not/i.test(text)) category = 'unable';
  return {
    category,
    bytes: Buffer.byteLength(text),
    sha256: crypto.createHash('sha256').update(text).digest('hex'),
  };
}

function terminalDiagnostic(events, resultIndex) {
  const slice = events.slice(0, resultIndex + 1);
  const terminal = events[resultIndex];
  const result = redactedTextDiagnostic(terminal?.result);
  const assistantText = slice.flatMap((event) => (
    Array.isArray(event?.message?.content)
      ? event.message.content.filter((block) => block?.type === 'text').map((block) => String(block.text || ''))
      : []
  )).join('\n');
  const assistant = redactedTextDiagnostic(assistantText);
  const allowlisted = (value, allowed, absent = 'none') => {
    if (value === undefined || value === null || value === '') return absent;
    return typeof value === 'string' && allowed.includes(value) ? value : 'other';
  };
  const eventShape = slice.slice(0, 64).map((event) => {
    const blocks = Array.isArray(event?.message?.content)
      ? event.message.content.slice(0, 64).map((block) => (
        allowlisted(block?.type, ['text', 'tool_use', 'tool_result'])
      )).join('+')
      : 'none';
    return `${allowlisted(event?.type, ['system', 'assistant', 'user', 'result'])}/${allowlisted(event?.subtype, ['init', 'success', 'error'], '-')}[${blocks}]`;
  }).join(',');
  const initTools = slice.filter((event) => event?.type === 'system' && event?.subtype === 'init')
    .flatMap((event) => Array.isArray(event.tools) ? event.tools.map(String) : [])
    .slice(0, 64);
  const initToolCounts = { Read: 0, Bash: 0, other: 0 };
  for (const tool of initTools) {
    if (tool === 'Read' || tool === 'Bash') initToolCounts[tool] += 1;
    else initToolCounts.other += 1;
  }
  const denials = Array.isArray(terminal?.permission_denials) ? terminal.permission_denials.length : 0;
  return [
    `terminal_subtype=${allowlisted(terminal?.subtype, ['success', 'error'])}`,
    `terminal_error=${terminal?.is_error === true ? 'true' : 'false'}`,
    `terminal_category=${result.category}`,
    `terminal_bytes=${result.bytes}`,
    `terminal_sha256=${result.sha256}`,
    `assistant_category=${assistant.category}`,
    `assistant_bytes=${assistant.bytes}`,
    `assistant_sha256=${assistant.sha256}`,
    `permission_denials=${denials}`,
    `init_tools_read=${initToolCounts.Read}`,
    `init_tools_bash=${initToolCounts.Bash}`,
    `init_tools_other=${initToolCounts.other}`,
    `event_count=${slice.length}`,
    `event_shape=${eventShape || 'none'}`,
  ].join('; ');
}

function validateTurn(events, startIndex, resultIndex, expectedFile, token, label) {
  const slice = events.slice(startIndex, resultIndex + 1);
  const uses = [];
  const results = new Map();
  for (const event of slice) {
    if (!Array.isArray(event?.message?.content)) continue;
    for (const block of event.message.content) {
      if (block?.type === 'tool_use') uses.push(block);
      if (block?.type === 'tool_result' && typeof block.tool_use_id === 'string') {
        if (results.has(block.tool_use_id)) fail(`${label} duplicated a tool result`);
        results.set(block.tool_use_id, block);
      }
    }
  }
  if (uses.length !== 1 || uses[0].name !== 'Read'
      || path.resolve(uses[0].input?.file_path || '') !== expectedFile) {
    fail(`${label} did not issue exactly the requested Read; observed ${observedToolShape(uses)}; ${terminalDiagnostic(slice, slice.length - 1)}`);
  }
  const result = results.get(uses[0].id);
  if (!result || result.is_error === true
      || !JSON.stringify(result.content ?? '').includes(token)) {
    fail(`${label} Read did not return the expected opaque token in a successful structured result`);
  }
  const terminal = events[resultIndex];
  if (terminal?.type !== 'result' || terminal.is_error === true
      || terminal.subtype === 'error' || String(terminal.result || '').trim() !== token) {
    fail(`${label} terminal result is missing, errored, or drifted`);
  }
}

function validateCandidateTurn(events, resultIndex, expectedFile, token) {
  const slice = events.slice(0, resultIndex + 1);
  const uses = [];
  const results = new Map();
  for (const event of slice) {
    if (!Array.isArray(event?.message?.content)) continue;
    for (const block of event.message.content) {
      if (block?.type === 'tool_use') uses.push(block);
      if (block?.type === 'tool_result' && typeof block.tool_use_id === 'string') {
        if (results.has(block.tool_use_id)) fail('fresh candidate duplicated a tool result');
        results.set(block.tool_use_id, block);
      }
    }
  }
  const bashKeys = uses[1]?.input && typeof uses[1].input === 'object' && !Array.isArray(uses[1].input)
    ? Object.keys(uses[1].input).sort() : [];
  const bashDescription = uses[1]?.input?.description;
  const validBashInput = (
    JSON.stringify(bashKeys) === '["command"]'
      || JSON.stringify(bashKeys) === '["command","description"]'
  ) && (bashDescription === undefined || (
    typeof bashDescription === 'string'
      && Buffer.byteLength(bashDescription) <= 512
      && !/[\0\r\n]/.test(bashDescription)
  ));
  if (uses.length !== 2 || uses[0].name !== 'Read' || uses[1].name !== 'Bash'
      || path.resolve(uses[0].input?.file_path || '') !== expectedFile
      || uses[1].input?.command !== BASH_PROBE_COMMAND || !validBashInput) {
    fail(`fresh candidate did not issue exactly the requested Read then harmless Bash probe; observed ${observedToolShape(uses)}; ${terminalDiagnostic(slice, slice.length - 1)}`);
  }
  const readResult = results.get(uses[0].id);
  const bashResult = results.get(uses[1].id);
  if (!readResult || readResult.is_error === true
      || !JSON.stringify(readResult.content ?? '').includes(token)
      || !bashResult || bashResult.is_error === true
      || !JSON.stringify(bashResult.content ?? '').includes(BASH_PROBE_OUTPUT)) {
    fail('fresh candidate Read or Bash probe did not return a successful structured result');
  }
  const terminal = events[resultIndex];
  if (terminal?.type !== 'result' || terminal.is_error === true
      || terminal.subtype === 'error' || String(terminal.result || '').trim() !== token) {
    fail('fresh candidate terminal result is missing, errored, or drifted');
  }
}

function expectedPreToolHooks(root, toolName) {
  const config = safeJson(fs.readFileSync(path.join(root, 'hooks', 'hooks.json'), 'utf8'), 'candidate hooks');
  const basenames = [];
  for (const group of config?.hooks?.PreToolUse || []) {
    let matches = false;
    try { matches = new RegExp(group.matcher || '.*').test(toolName); }
    catch (_error) { fail('candidate PreToolUse matcher is invalid'); }
    if (!matches) continue;
    for (const hook of group.hooks || []) {
      if (hook?.type !== 'command' || typeof hook.command !== 'string') fail('candidate PreToolUse hook is invalid');
      const match = hook.command.match(/\/hooks\/([A-Za-z0-9._-]+\.sh)/);
      if (!match) fail('candidate PreToolUse hook command is not an exact plugin hook');
      basenames.push(match[1]);
    }
  }
  if (basenames.length === 0 || new Set(basenames).size !== basenames.length) {
    fail(`candidate ${toolName} PreToolUse hook set is empty or duplicated`);
  }
  return basenames;
}

function initEvents(events) {
  return events.filter((event) => event?.type === 'system' && event?.subtype === 'init');
}

function requireTurnInitEvents(events, sessionId, expectedCount, label) {
  const init = initEvents(events);
  if (init.length !== expectedCount || init.some((event) => event.session_id !== sessionId)) {
    fail(`${label} did not expose exactly one matching init per completed turn`);
  }
}

function validateFreshState(
  candidateRoot,
  projectRoot,
  sessionId,
  temporary,
  expectedPluginDataInput,
  diagnosticPluginDataParentInput,
) {
  const core = require(path.join(candidateRoot, 'hooks', 'lib', 'session-control-core-v1.js'));
  const key = core.sessionKey(sessionId);
  const records = [];
  const visit = (directory) => {
    if (!fs.existsSync(directory)) return;
    const stat = fs.lstatSync(directory);
    if (stat.isSymbolicLink() || !stat.isDirectory()) fail('candidate plugin data contains an unsafe directory');
    for (const name of fs.readdirSync(directory)) {
      const file = path.join(directory, name);
      const item = fs.lstatSync(file);
      if (item.isSymbolicLink()) fail('candidate plugin data contains a symlink');
      if (item.isDirectory()) visit(file);
      else if (item.isFile() && path.basename(path.dirname(file)) === 'records' && name.endsWith('.json')) records.push(file);
    }
  };
  visit(temporary);
  if (records.length !== 1 || path.basename(records[0]) !== `${key}.json`) {
    fail(`fresh candidate created ${records.length} total context records or used the wrong plugin-data path`);
  }
  const expectedRecordsDir = realDirectory(path.dirname(records[0]), 'candidate records directory');
  const expectedPluginData = realDirectory(
    path.resolve(expectedRecordsDir, '..', '..', '..'),
    'candidate plugin data',
  );
  if (!inside(temporary, expectedPluginData)) fail('candidate plugin data escaped the isolated filesystem root');
  if (expectedPluginDataInput !== null) {
    if (expectedPluginData !== realDirectory(expectedPluginDataInput, 'expected candidate plugin data')) {
      fail('fresh candidate used the wrong installed-plugin data directory');
    }
  } else {
    const parent = realDirectory(diagnosticPluginDataParentInput, 'diagnostic plugin data parent');
    if (!inside(temporary, parent) || path.dirname(expectedPluginData) !== parent) {
      fail('fresh diagnostic candidate plugin data escaped its isolated direct parent');
    }
  }
  const context = core.readContext({ recordsDir: expectedRecordsDir, sessionId, expectedHost: 'claude' });
  if (context.plugin_root !== candidateRoot || context.project_root !== projectRoot
      || context.principal_profiles?.main !== 'main-v1' || context.plugin_version !== safeManifest(candidateRoot, 'candidate').version
      || context.plugin_data !== expectedPluginData) {
    fail('fresh candidate context did not bind main-v1 to the exact isolated roots');
  }
  const baselines = fs.existsSync(path.join(projectRoot, '.zensu', 'state'))
    ? fs.readdirSync(path.join(projectRoot, '.zensu', 'state')).filter((name) => name.startsWith('tdd-phase-') && name.endsWith('.json'))
    : [];
  if (baselines.length !== 1 || baselines[0] !== `tdd-phase-${key}.json`) {
    fail('fresh candidate did not create exactly one matching workflow baseline');
  }
  const state = core.readWorkflowState({ projectRoot, sessionId });
  if (state.revision !== 1 || state.workflow_state !== 'idle' || state.phase !== 'UNINITIALIZED'
      || state.active !== false || state.actor !== 'main-v1' || state.history?.length !== 0) {
    fail('fresh candidate workflow baseline is invalid');
  }
  return core;
}

function probeCli(command, prefix, env, expectedVersion) {
  const result = spawnSync(command, [...prefix, '--version'], { encoding: 'utf8', env });
  if (result.status !== 0) fail('Claude CLI version probe failed');
  const match = String(result.stdout || '').match(/^([0-9]+\.[0-9]+\.[0-9]+)/);
  if (!match || match[1] !== expectedVersion) {
    fail(`Claude CLI must be exactly ${expectedVersion}`);
  }
}

function probeExistingLogin(command, prefix, env, cwd) {
  const result = spawnSync(command, [...prefix, 'auth', 'status', '--json'], {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    env,
  });
  if (result.status !== 0) fail('existing-login Claude auth preflight failed');
  const status = safeJson(result.stdout || '', 'existing-login Claude auth status');
  if (status?.loggedIn !== true || typeof status?.authMethod !== 'string' || !status.authMethod) {
    fail('existing-login credentials are unavailable to the isolated diagnostic process');
  }
}

async function main() {
  const prompt = process.argv[2] || '';
  const options = safeJson(process.argv[3] || '{}', 'provider options');
  const context = safeJson(process.argv[4] || '{}', 'provider context');
  const testMode = process.env.ZENSU_UPGRADE_TEST_MODE === '1';
  const existingLogin = process.env.ZENSU_UPGRADE_EXISTING_LOGIN === '1';
  const scenarioId = context?.vars?.scenario_id || options?.vars?.scenario_id || '';
  if (!prompt.includes('side-by-side') || scenarioId !== 'upgrade-v0161-side-by-side') {
    fail('Promptfoo scenario identity is missing');
  }
  if (!testMode && process.platform !== 'darwin' && process.platform !== 'linux') {
    fail('real Claude upgrade validation is currently supported only on macOS and Linux');
  }
  if (testMode && existingLogin) fail('deterministic test mode cannot use existing-login mode');
  if (!testMode && existingLogin && process.platform !== 'darwin') {
    fail('existing-login upgrade diagnostics are supported only on macOS');
  }
  const sourceInput = options?.config?.source_dir;
  if (typeof sourceInput !== 'string' || !sourceInput) fail('config.source_dir is mandatory');
  const sourceRoot = realDirectory(path.resolve(process.cwd(), sourceInput), 'candidate source root');
  const expectedRoot = realDirectory(process.env.ZENSU_EXPECTED_SOURCE_ROOT || '', 'expected source root');
  if (sourceRoot !== expectedRoot) fail('candidate source root does not match ZENSU_EXPECTED_SOURCE_ROOT');
  const sourceRevision = git(sourceRoot, ['rev-parse', 'HEAD']);
  if (!/^[a-f0-9]{40,64}$/.test(sourceRevision)
      || sourceRevision !== process.env.ZENSU_EXPECTED_SOURCE_REVISION) {
    fail('candidate source revision does not match the exact requested SHA');
  }
  const sourceStatusBefore = git(sourceRoot, ['status', '--porcelain=v1', '--untracked-files=all']);
  if (sourceStatusBefore) fail('candidate source checkout must be clean');
  const oldRevision = git(sourceRoot, ['rev-parse', `${OLD_REF}^{commit}`]);
  if (oldRevision !== OLD_RELEASE_REVISION) {
    fail(`v0.16.1 must resolve to pinned commit ${OLD_RELEASE_REVISION}`);
  }
  if (oldRevision === sourceRevision) fail('candidate source does not advance beyond v0.16.1');
  if (!gitIsAncestor(sourceRoot, oldRevision, sourceRevision)) {
    fail('v0.16.1 must be an ancestor of the candidate source revision');
  }

  const expectedCliVersion = process.env.ZENSU_EXPECTED_CLAUDE_VERSION || '';
  if (!/^\d+\.\d+\.\d+$/.test(expectedCliVersion)) {
    fail('ZENSU_EXPECTED_CLAUDE_VERSION must be an explicit semantic version');
  }
  if (!testMode && !existingLogin
      && !process.env.ANTHROPIC_API_KEY && !process.env.CLAUDE_CODE_OAUTH_TOKEN) {
    fail('explicit Claude credentials are unavailable');
  }
  if (existingLogin && (!process.env.HOME || !path.isAbsolute(process.env.HOME))) {
    fail('existing-login mode requires an absolute host HOME');
  }
  const executionMode = testMode
    ? EXECUTION_MODES.fake
    : existingLogin ? EXECUTION_MODES.diagnostic : EXECUTION_MODES.authoritative;
  const hostHome = existingLogin ? realDirectory(process.env.HOME, 'existing-login host HOME') : null;
  const hostCanaryBefore = existingLogin ? existingLoginCanary(hostHome) : null;
  const temporary = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-claude-upgrade-')));
  const activeProcesses = new Set();
  let primaryError = null;
  try {
    const home = path.join(temporary, 'home');
    const projectRoot = path.join(temporary, 'project');
    const control = path.join(temporary, 'control');
    const oldCheckout = path.join(temporary, 'old-v0.16.1-source');
    const cacheBase = path.join(home, '.claude', 'plugins', 'cache', 'zensu', 'zensu');
    for (const directory of [home, control, cacheBase]) fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    createProject(projectRoot);
    const bashGuard = createBashGuard(control);
    const cliSettings = commandLineSettings(bashGuard, hostHome);
    const config = path.join(control, 'zensu-config.json');
    fs.writeFileSync(config, '{"context":{"compactionNudge":false},"hooks":{"intentRouter":false,"tddReminder":false,"pulseSession":false,"sessionBanner":false}}\n', { mode: 0o400 });

    const clone = spawnSync('git', [
      '-c', 'protocol.file.allow=always', '-c', 'core.hooksPath=/dev/null',
      'clone', '--no-local', '--no-hardlinks', '--no-checkout', '--', sourceRoot, oldCheckout,
    ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    if (clone.status !== 0) fail('cannot clone local upgrade source');
    git(oldCheckout, ['checkout', '--detach', '--force', oldRevision]);
    if (git(oldCheckout, ['status', '--porcelain=v1', '--untracked-files=all'])) fail('v0.16.1 checkout is dirty');
    if (safeManifest(oldCheckout, 'v0.16.1').version !== OLD_VERSION) fail('v0.16.1 tag manifest drifted');

    const candidateSourceVersion = safeManifest(sourceRoot, 'candidate source').version;
    const candidateVersion = installedVersion(candidateSourceVersion);
    const oldDestination = path.join(cacheBase, OLD_VERSION);
    const candidateDestination = path.join(cacheBase, candidateVersion.version);
    if (oldDestination === candidateDestination) fail('old and candidate version roots alias');
    const oldRoot = install(oldCheckout, oldDestination, OLD_VERSION);
    const core = require(path.join(sourceRoot, 'hooks', 'lib', 'session-control-core-v1.js'));
    const oldRuntimeDigest = runtimeDigest(core, oldRoot);
    if (oldRuntimeDigest !== runtimeDigest(core, oldCheckout)) fail('installed v0.16.1 runtime is not byte-identical to its tag');
    const oldInventoryBefore = new Map();
    const oldBytesBefore = snapshotTree(oldRoot, oldInventoryBefore);
    requireOrphanMarker(oldRoot, false, null, 'old runtime before process activation');

    const traceBoundary = createTraceBoundary(control, oldRoot, candidateDestination);
    const env = childEnvironment(home, temporary, config, traceBoundary);
    const cli = cliCommand();
    probeCli(cli.command, cli.prefix, env, expectedCliVersion);
    if (existingLogin) {
      probeExistingLogin(cli.command, cli.prefix, env, projectRoot);
      if (existingLoginCanary(hostHome) !== hostCanaryBefore) {
        fail('existing-login auth preflight changed the host config/cache canary');
      }
    }
    writeRegistry(home, oldRoot, OLD_VERSION, oldRevision);

    const allowedReadFiles = [
      path.join(projectRoot, 'old-turn-1.txt'),
      path.join(projectRoot, 'old-turn-2.txt'),
      path.join(projectRoot, 'old-turn-3.txt'),
      path.join(projectRoot, 'candidate-turn.txt'),
    ].map((file) => fs.realpathSync.native(file));

    const oldSessionId = crypto.randomUUID();
    const oldProcess = new StreamSession(cli.command, [
      ...cli.prefix, ...claudeArgs(
        oldSessionId,
        allowedReadFiles,
        cliSettings,
        existingLogin ? oldRoot : null,
      ),
    ], {
      cwd: projectRoot, env,
    });
    activeProcesses.add(oldProcess);
    let eventStart = 0;
    let traceStart = 0;
    const oldTurn1Token = OLD_TURN_TOKENS[0];
    const oldTurn1File = fs.realpathSync.native(path.join(projectRoot, 'old-turn-1.txt'));
    oldProcess.send(promptFor(oldTurn1File));
    await oldProcess.waitForResult(1);
    let resultIndex = oldProcess.events.findIndex((event) => event === oldProcess.results[0]);
    validateTurn(oldProcess.events, eventStart, resultIndex, oldTurn1File, oldTurn1Token, 'old turn one');
    requireTurnInitEvents(oldProcess.events, oldSessionId, 1, 'old process');
    let trace = traceEntries(traceBoundary.trace);
    let delta = trace.slice(traceStart);
    requireTraceScope(delta, oldRoot, candidateDestination, 'old turn one');
    requireTrace(delta, oldRoot, 'stop-chain-enforcer.sh', 1, 'old turn one');
    for (const hook of [
      'session-start-pulse.sh', 'session-start-banner.sh',
      'session-start-primer.sh', 'session-start-autopilot-resume.sh',
    ]) requireTrace(delta, oldRoot, hook, 1, 'old turn one');
    requireInUseMarker(oldRoot, oldProcess.child.pid, true, 'old process');
    requireOrphanMarker(
      oldRoot, false, null, 'old runtime after old-process activation',
    );
    traceStart = trace.length;
    eventStart = resultIndex + 1;

    const candidateRoot = install(sourceRoot, candidateDestination, candidateVersion.version);
    const candidateRuntimeDigest = runtimeDigest(core, candidateRoot);
    if (candidateRuntimeDigest === oldRuntimeDigest) fail('candidate runtime digest does not differ from v0.16.1');
    const candidateInventoryBefore = new Map();
    const candidateBytesBefore = snapshotTree(candidateRoot, candidateInventoryBefore);
    requireOrphanMarker(candidateRoot, false, null, 'candidate runtime before activation');
    const oldInventoryAfterCandidate = new Map();
    if (snapshotTree(oldRoot, oldInventoryAfterCandidate) !== oldBytesBefore) {
      fail(`candidate installation modified the old version root; changedEntries=${changedTreeEntries(oldInventoryBefore, oldInventoryAfterCandidate)}`);
    }
    const candidateActivationWindow = { startedAtMs: Date.now(), endedAtMs: null };
    writeRegistry(home, candidateRoot, candidateVersion.version, sourceRevision);

    const oldTurn2Token = OLD_TURN_TOKENS[1];
    const oldTurn2File = fs.realpathSync.native(path.join(projectRoot, 'old-turn-2.txt'));
    oldProcess.send(promptFor(oldTurn2File));
    await oldProcess.waitForResult(2);
    resultIndex = oldProcess.events.findIndex((event) => event === oldProcess.results[1]);
    validateTurn(oldProcess.events, eventStart, resultIndex, oldTurn2File, oldTurn2Token, 'old turn two');
    requireTurnInitEvents(oldProcess.events, oldSessionId, 2, 'old process');
    if (oldProcess.results.length !== 2) {
      fail(`old process did not remain one process with exactly two completed turns; init_count=${initEvents(oldProcess.events).length}; result_count=${oldProcess.results.length}; closed=${oldProcess.closed ? 'true' : 'false'}; status=${String(oldProcess.status ?? 'none')}`);
    }
    trace = traceEntries(traceBoundary.trace);
    delta = trace.slice(traceStart);
    requireTraceScope(delta, oldRoot, candidateRoot, 'old turn two');
    requireTrace(delta, oldRoot, 'stop-chain-enforcer.sh', 1, 'old turn two');
    traceStart = trace.length;
    eventStart = resultIndex + 1;
    if (oldProcess.closed) fail('old process closed before the fresh candidate session started');

    const candidateSessionId = crypto.randomUUID();
    const candidateProcess = new StreamSession(cli.command, [
      ...cli.prefix, ...claudeArgs(
        candidateSessionId,
        allowedReadFiles,
        cliSettings,
        existingLogin ? candidateRoot : null,
      ),
    ], {
      cwd: projectRoot, env,
    });
    activeProcesses.add(candidateProcess);
    const candidateToken = CANDIDATE_TOKEN;
    const candidateFile = fs.realpathSync.native(path.join(projectRoot, 'candidate-turn.txt'));
    candidateProcess.send(candidatePromptFor(candidateFile));
    await candidateProcess.waitForResult(1);
    candidateActivationWindow.endedAtMs = Date.now();
    const candidateResultIndex = candidateProcess.events.findIndex((event) => event === candidateProcess.results[0]);
    validateCandidateTurn(candidateProcess.events, candidateResultIndex, candidateFile, candidateToken);
    requireInUseMarker(candidateRoot, candidateProcess.child.pid, true, 'fresh candidate process');
    const candidateInit = initEvents(candidateProcess.events);
    if (candidateInit.length !== 1 || candidateInit[0].session_id !== candidateSessionId) {
      fail('fresh candidate process did not expose exactly one matching init event');
    }
    const oldOrphanMarkerAfterCandidate = requireOrphanMarker(
      oldRoot, true, candidateActivationWindow,
      'old runtime after candidate activation',
    );
    requireOrphanMarker(
      candidateRoot, false, null,
      'candidate runtime after candidate activation',
    );
    requireInUseMarker(
      oldRoot, oldProcess.child.pid, true,
      'old process during candidate activation',
    );
    trace = traceEntries(traceBoundary.trace);
    delta = trace.slice(traceStart);
    requireTraceScope(delta, candidateRoot, oldRoot, 'fresh candidate');
    requireTrace(delta, candidateRoot, 'session-start-session-control.sh', 1, 'fresh candidate');
    requireTrace(delta, candidateRoot, 'stop-chain-enforcer.sh', 1, 'fresh candidate');
    const expectedHookCounts = new Map();
    for (const name of [
      ...expectedPreToolHooks(candidateRoot, 'Read'),
      ...expectedPreToolHooks(candidateRoot, 'Bash'),
    ]) expectedHookCounts.set(name, (expectedHookCounts.get(name) || 0) + 1);
    for (const [name, count] of expectedHookCounts) {
      requireTrace(delta, candidateRoot, name, count, 'fresh candidate Read/Bash PreToolUse');
    }
    requireBashGuardTrace(bashGuard.trace);
    await candidateProcess.close();
    activeProcesses.delete(candidateProcess);
    requireInUseMarker(candidateRoot, candidateProcess.child.pid, false, 'fresh candidate process');
    validateFreshState(
      candidateRoot,
      projectRoot,
      candidateSessionId,
      temporary,
      existingLogin ? null : pluginDataPath(env.CLAUDE_CODE_PLUGIN_CACHE_DIR),
      existingLogin ? path.join(env.CLAUDE_CODE_PLUGIN_CACHE_DIR, 'data') : null,
    );
    traceStart = trace.length;
    if (oldProcess.closed) fail('old process did not remain open through the fresh candidate session');

    const oldTurn3Token = OLD_TURN_TOKENS[2];
    const oldTurn3File = fs.realpathSync.native(path.join(projectRoot, 'old-turn-3.txt'));
    oldProcess.send(promptFor(oldTurn3File));
    await oldProcess.waitForResult(3);
    resultIndex = oldProcess.events.findIndex((event) => event === oldProcess.results[2]);
    validateTurn(oldProcess.events, eventStart, resultIndex, oldTurn3File, oldTurn3Token, 'old turn three after candidate');
    requireTurnInitEvents(oldProcess.events, oldSessionId, 3, 'old process');
    if (oldProcess.results.length !== 3) {
      fail(`old process did not remain one process with exactly three completed turns; init_count=${initEvents(oldProcess.events).length}; result_count=${oldProcess.results.length}; closed=${oldProcess.closed ? 'true' : 'false'}; status=${String(oldProcess.status ?? 'none')}`);
    }
    trace = traceEntries(traceBoundary.trace);
    delta = trace.slice(traceStart);
    requireTraceScope(delta, oldRoot, candidateRoot, 'old turn three after candidate');
    requireTrace(delta, oldRoot, 'stop-chain-enforcer.sh', 1, 'old turn three after candidate');
    await oldProcess.close();
    activeProcesses.delete(oldProcess);
    requireInUseMarker(oldRoot, oldProcess.child.pid, false, 'old process');

    const oldOrphanMarkerFinal = requireOrphanMarker(
      oldRoot, true, null, 'old runtime final',
    );
    if (oldOrphanMarkerFinal.fingerprint !== oldOrphanMarkerAfterCandidate.fingerprint) {
      fail('old runtime .orphaned_at marker changed after candidate activation');
    }
    requireOrphanMarker(candidateRoot, false, null, 'candidate runtime final');

    const oldInventoryFinal = new Map();
    if (snapshotTree(oldRoot, oldInventoryFinal) !== oldBytesBefore) {
      fail(`fresh candidate process modified the old runtime root; changedEntries=${changedTreeEntries(oldInventoryBefore, oldInventoryFinal)}`);
    }
    const candidateInventoryFinal = new Map();
    if (snapshotTree(candidateRoot, candidateInventoryFinal) !== candidateBytesBefore) {
      fail(`fresh candidate process modified candidate runtime bytes; changedEntries=${changedTreeEntries(candidateInventoryBefore, candidateInventoryFinal)}`);
    }
    if (git(sourceRoot, ['rev-parse', 'HEAD']) !== sourceRevision
        || git(sourceRoot, ['status', '--porcelain=v1', '--untracked-files=all']) !== sourceStatusBefore) {
      fail('upgrade evaluation changed the candidate source checkout');
    }
    if (![home, projectRoot, control, oldCheckout, oldRoot, candidateRoot]
      .every((entry) => inside(temporary, fs.realpathSync.native(entry)))) {
      fail('upgrade evaluation escaped its isolated filesystem root');
    }
    const evidence = {
      schema: 'zensu.session-control-upgrade-evidence',
      schema_version: 1,
      host: 'claude',
      gate: 'passed',
      execution_mode: executionMode,
      host_config_cache_canary_status: testMode
        ? 'not-applicable-test-mode'
        : existingLogin ? 'unchanged-local-diagnostic' : 'not-applicable-isolated-home',
      claude_code_version: expectedCliVersion,
      source_git_revision: sourceRevision,
      old_release_ref: OLD_REF,
      old_release_revision: oldRevision,
      old_version: OLD_VERSION,
      candidate_source_version: candidateSourceVersion,
      candidate_installed_version: candidateVersion.version,
      candidate_version_synthetic: candidateVersion.synthetic,
      old_runtime_digest: oldRuntimeDigest,
      candidate_runtime_digest: candidateRuntimeDigest,
      old_session_id_hash: core.sessionIdHash(oldSessionId),
      candidate_session_id_hash: core.sessionIdHash(candidateSessionId),
      old_process_result_count: 3,
      fresh_process_result_count: 1,
      hook_sequence: [...REQUIRED_SEQUENCE],
    };
    process.stdout.write(`${line(evidence)}\n`);
  } catch (error) {
    primaryError = error;
    throw error;
  } finally {
    try {
      await Promise.all([...activeProcesses].map((session) => session.terminate()));
    } finally {
      try {
        if (existingLogin && existingLoginCanary(hostHome) !== hostCanaryBefore) {
          if (primaryError) {
            primaryError.message += '; existing-login host config/cache canary also changed';
          } else {
            fail('existing-login host config/cache canary changed during the local diagnostic');
          }
        }
      } finally {
        fs.rmSync(temporary, { recursive: true, force: true });
      }
    }
  }
}

main().catch((error) => {
  const message = typeof error?.message === 'string' ? error.message : '';
  if (safeErrorHas(SAFE_DIAGNOSTIC_ERRORS, error) && !/[\0\r\n]/.test(message)) {
    process.stderr.write(`${message}\n`);
  } else {
    const diagnostic = redactedTextDiagnostic(message);
    process.stderr.write(`${[
      'session-control upgrade provider: unexpected failure',
      `error_category=${diagnostic.category}`,
      `error_bytes=${diagnostic.bytes}`,
      `error_sha256=${diagnostic.sha256}`,
    ].join('; ')}\n`);
  }
  process.exit(1);
});
