#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  EXECUTION_MODES,
  OLD_RELEASE_REVISION,
  line,
  REQUIRED_SEQUENCE,
} = require('./upgrade-attestation.js');
const { readStableRegularFile } = require('./safe-file-read.js');
const {
  captureEvaluatorOwnedHookContract,
  injectCandidateHookContractFaultForTest,
  loadCanonicalHookConfig,
  verifyCapturedHookContract,
} = require('./upgrade-hook-contract.js');
const { startUpgradeAnthropicMock } = require('./upgrade-anthropic-mock.js');
const { buildBubblewrapInvocation } = require('./upgrade-linux-sandbox.js');
const { selectExplicitCredential } = require('./upgrade-credentials.js');
const {
  credentialFreeEnvironment,
  withoutClaudeCredentials,
} = require('./upgrade-environment.js');
const {
  computeClaudeRuntimeDigest,
  readAndValidateContext,
  readAndValidateInitialWorkflow,
  sessionIdHash: independentSessionIdHash,
  sessionKey: independentSessionKey,
} = require('./upgrade-independent-verifier.js');
const {
  runProcessTreeBounded,
  runSyncBounded,
  signalProcessTree,
  spawnProcessTree,
  terminateProcessTree,
} = require('./upgrade-process.js');
const {
  captureOwnedDirectory,
  quarantineAndRemoveOwnedDirectory,
} = require('./upgrade-owned-directory.js');

const OLD_REF = 'v0.16.1';
const OLD_VERSION = '0.16.1';
const MAX_STREAM_BYTES = 32 * 1024 * 1024;
const PROCESS_TIMEOUT_MS = 180000;
const GIT_TIMEOUT_MS = 60000;
const INSTALL_TIMEOUT_MS = 120000;
const PROBE_TIMEOUT_MS = 30000;
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

function boundedSync(command, args, options, label, timeoutMs, maxBuffer) {
  try {
    return runSyncBounded(command, args, options, {
      label,
      timeoutMs,
      maxBuffer,
      trustedEvaluatorCommand: true,
    });
  } catch (error) {
    fail(error.message.replace(/^upgrade process: /, ''));
  }
}

function testBoundedTimeout(name, fallback) {
  const value = process.env[name] || '';
  if (process.env.ZENSU_UPGRADE_TEST_MODE !== '1' || !/^[1-9][0-9]*$/.test(value)) {
    return fallback;
  }
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed >= 50 && parsed <= fallback
    ? parsed : fallback;
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
  try { return fs.realpathSync.native(input); }
  catch (_error) { fail(`${label} is unavailable`); }
}

function inside(parent, child) {
  const relative = path.relative(parent, child);
  return relative === '' || (relative !== '..' && !relative.startsWith(`..${path.sep}`)
    && !path.isAbsolute(relative));
}

function sameDirectoryIdentity(left, right) {
  return left.dev === right.dev
    && left.ino === right.ino
    && left.mode === right.mode
    && left.mtimeMs === right.mtimeMs
    && left.ctimeMs === right.ctimeMs;
}

function directoryIdentity(directory, label) {
  let stat;
  let canonical;
  try {
    stat = fs.lstatSync(directory);
    canonical = fs.realpathSync.native(directory);
  } catch (_error) {
    fail(`${label} is unavailable`);
  }
  if (stat.isSymbolicLink() || !stat.isDirectory() || canonical !== directory) {
    fail(`${label} must be a real directory`);
  }
  return { canonical, stat };
}

function requireUnchangedDirectory(directory, before, label) {
  let after;
  try { after = directoryIdentity(directory, label); }
  catch (_error) { fail(`${label} changed while being inspected`); }
  if (before.canonical !== after.canonical
      || !sameDirectoryIdentity(before.stat, after.stat)) {
    fail(`${label} changed while being inspected`);
  }
}

function optionalDescendantDirectory(root, input, label) {
  const resolved = path.resolve(input);
  if (!inside(root, resolved)) fail(`${label} escaped its expected root`);
  let current = root;
  const relative = path.relative(root, resolved);
  if (!relative) return root;
  for (const name of relative.split(path.sep)) {
    const candidate = path.join(current, name);
    let stat;
    try { stat = fs.lstatSync(candidate); }
    catch (error) {
      if (error.code === 'ENOENT') return null;
      fail(`${label} is unavailable`);
    }
    if (stat.isSymbolicLink()) fail('candidate plugin data contains a symlink');
    if (!stat.isDirectory()) fail(`${label} must be a real directory`);
    let canonical;
    try { canonical = fs.realpathSync.native(candidate); }
    catch (_error) { fail(`${label} is unavailable`); }
    if (path.dirname(canonical) !== current) fail(`${label} escaped its direct parent`);
    current = canonical;
  }
  return current;
}

function boundedDirectoryEntries(directory, label, limit) {
  const before = directoryIdentity(directory, label);
  const entries = [];
  let handle;
  try {
    handle = fs.opendirSync(directory);
    while (entries.length <= limit) {
      const entry = handle.readSync();
      if (entry === null) break;
      entries.push(entry);
    }
  } catch (_error) {
    fail(`${label} cannot be inspected`);
  } finally {
    if (handle) {
      try { handle.closeSync(); }
      catch (_error) { fail(`${label} cannot be inspected`); }
    }
  }
  requireUnchangedDirectory(directory, before, label);
  return {
    entries,
    overflow: entries.length > limit,
  };
}

function gitHelperEnvironment() {
  return credentialFreeEnvironment(process.env, {
    LANG: 'C',
    LC_ALL: 'C',
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_CONFIG_GLOBAL: process.platform === 'win32' ? 'NUL' : '/dev/null',
    GIT_TERMINAL_PROMPT: '0',
    GIT_NO_REPLACE_OBJECTS: '1',
  });
}

function gitProcess(root, gitArguments) {
  return boundedSync('git', ['--no-replace-objects', '-C', root, ...gitArguments], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    env: gitHelperEnvironment(),
  }, `git ${gitArguments[0]} probe`, GIT_TIMEOUT_MS, 16 * 1024 * 1024);
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
  let content;
  try {
    content = readStableRegularFile(file, {
      minBytes: 2,
      maxBytes: 1024 * 1024,
    }).buffer.toString('utf8');
  } catch (_error) {
    fail(`${label} plugin manifest is unsafe`);
  }
  const manifest = safeJson(content, `${label} plugin manifest`);
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
        let stable;
        try {
          stable = readStableRegularFile(file, {
            maxBytes: 8 * 1024 * 1024,
          });
        } catch (_error) {
          fail(`runtime snapshot entry changed or became unsafe; entry_sha256=${hash(Buffer.from(rel, 'utf8'))}`);
        }
        bytes += stable.stat.size;
        if (files > 12000 || bytes > 96 * 1024 * 1024) {
          fail('runtime snapshot exceeds its bounded surface');
        }
        digest.update(`f\0${rel}\0${stable.stat.size}\0`, 'utf8');
        digest.update(stable.buffer);
        digest.update('\0', 'utf8');
        if (inventory) {
          inventory.set(rel, `file:${stable.stat.size}:${hash(stable.buffer)}`);
        }
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
  try { fs.lstatSync(file); }
  catch (error) {
    if (error.code === 'ENOENT') return null;
    fail(`${label} .orphaned_at marker cannot be inspected`);
  }
  let stable;
  try {
    stable = readStableRegularFile(file, { minBytes: 13, maxBytes: 13 });
  } catch (_error) {
    fail(`${label} .orphaned_at marker is unsafe`);
  }
  const stat = stable.stat;
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size !== 13
      || (process.platform !== 'win32' && (stat.mode & 0o022) !== 0)) {
    fail(`${label} .orphaned_at marker is unsafe`);
  }
  const content = stable.buffer.toString('utf8');
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
  if (pid !== null && !/^[1-9][0-9]*$/.test(expected)) fail(`${label} process id is invalid`);
  const actual = inUseMarkerPids(root, label);
  if (present && (
    actual.length !== 1
      || (pid !== null && actual[0] !== expected)
  )) {
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

function runtimeDigest(root) {
  let independent;
  try { independent = computeClaudeRuntimeDigest(root); }
  catch (_error) { fail('runtime digest failed independent verification'); }
  return independent;
}

function verifiedSessionIdHash(sessionId) {
  let independent;
  try { independent = independentSessionIdHash(sessionId); }
  catch (_error) { fail('session hash failed independent verification'); }
  return independent;
}

function install(source, cacheParent, version, revision) {
  const canonicalParent = realDirectory(cacheParent, 'runtime cache parent');
  const result = boundedSync(process.execPath, [
    INSTALLER, source, canonicalParent, version, revision,
  ], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
    env: credentialFreeEnvironment(),
  }, 'runtime fixture installer', INSTALL_TIMEOUT_MS, 16 * 1024 * 1024);
  if (result.status !== 0) fail('runtime installation failed');
  const lines = String(result.stdout || '').split(/\r?\n/).filter(Boolean);
  if (lines.length !== 1) fail('runtime installer returned an ambiguous root');
  const installed = realDirectory(lines[0], 'installed runtime root');
  if (path.dirname(installed) !== canonicalParent
      || !path.basename(installed).startsWith(`.zensu-runtime-v${version}-`)) {
    fail('runtime installer returned a root outside its direct cache parent');
  }
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
  const result = boundedSync(
    'git',
    ['--no-replace-objects', 'init', '-q'],
    { cwd: root, encoding: 'utf8', env: gitHelperEnvironment() },
    'isolated project git init',
    GIT_TIMEOUT_MS,
  );
  if (result.status !== 0) fail('cannot initialize isolated upgrade project');
  for (const args of [
    ['config', 'user.name', 'Zensu Upgrade Eval'],
    ['config', 'user.email', 'upgrade-eval@zensu.invalid'],
    ['config', 'core.hooksPath', process.platform === 'win32' ? 'NUL' : '/dev/null'],
    ['add', '.'],
    ['-c', 'commit.gpgsign=false', 'commit', '-qm', 'test: seed upgrade fixture'],
  ]) {
    const command = boundedSync(
      'git',
      ['--no-replace-objects', ...args],
      { cwd: root, encoding: 'utf8', env: gitHelperEnvironment() },
      `isolated project git ${args[0]}`,
      GIT_TIMEOUT_MS,
    );
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

function commandLineSettings(guard, forbiddenRoots) {
  const sandbox = {
    enabled: true,
    failIfUnavailable: true,
    autoAllowBashIfSandboxed: false,
    allowUnsandboxedCommands: false,
  };
  if (!Array.isArray(forbiddenRoots) || forbiddenRoots.some(
    (entry) => typeof entry !== 'string' || !path.isAbsolute(entry),
  )) {
    fail('Claude sandbox forbidden-root policy is invalid');
  }
  if (forbiddenRoots.length > 0) {
    sandbox.filesystem = {
      denyRead: [...forbiddenRoots],
      denyWrite: [...forbiddenRoots],
    };
  }
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

function createTraceBoundary(
  control,
  cacheBase,
  home,
  projectRoot,
  pluginData,
  config,
) {
  const trace = path.join(control, 'hook-trace.jsonl');
  const testMode = process.env.ZENSU_UPGRADE_TEST_MODE === '1';
  const realBashProbe = boundedSync(
    'bash',
    ['--noprofile', '--norc', '-c', 'command -v bash'],
    { encoding: 'utf8', env: credentialFreeEnvironment() },
    'Bash runtime probe',
    PROBE_TIMEOUT_MS,
  );
  if (realBashProbe.status !== 0) fail('cannot resolve the real Bash runtime');
  const realBash = fs.realpathSync.native(realBashProbe.stdout.trim());
  const bin = path.join(control, 'trace-bin');
  const logger = path.join(control, 'trace-append.js');
  fs.mkdirSync(bin, { mode: 0o700 });
  fs.writeFileSync(logger, [
    "'use strict';",
    "const crypto=require('node:crypto');",
    "const fs=require('node:fs');",
    'const [mode,file,invocation,hook,status]=process.argv.slice(2);',
    "if(!['start','end'].includes(mode)||!file||!hook||/[\\0\\r\\n]/.test(hook))process.exit(2);",
    "const id=mode==='start'?crypto.randomUUID():invocation;",
    "if(!/^[a-f0-9-]{36}$/.test(id||'')||(mode==='end'&&!/^[0-9]+$/.test(status||'')))process.exit(2);",
    "const flags=fs.constants.O_WRONLY|fs.constants.O_APPEND|fs.constants.O_CREAT|(fs.constants.O_NOFOLLOW||0);",
    "let descriptor;try{",
    "  descriptor=fs.openSync(file,flags,0o600);",
    "  const stat=fs.fstatSync(descriptor);",
    "  if(!stat.isFile()||(process.platform!=='win32'&&(stat.mode&0o077)!==0))process.exit(2);",
    "  const record=mode==='start'?{type:'START',id,hook}:{type:'END',id,hook,status:Number(status)};",
    "  fs.writeSync(descriptor,`${JSON.stringify(record)}\\n`);fs.fsyncSync(descriptor);",
    "}finally{if(descriptor!==undefined)fs.closeSync(descriptor);}",
    "if(mode==='start')process.stdout.write(id);",
  ].join('\n'), { mode: 0o500 });
  const wrapper = path.join(bin, 'bash');
  const safePath = (process.env.PATH || '').split(path.delimiter)
    .filter((entry) => entry && path.resolve(entry) !== path.resolve(bin))
    .join(path.delimiter);
  const directCommand = '/usr/bin/true';
  const containedCommand = [
    '/usr/bin/bwrap',
    '--unshare-user --unshare-pid --unshare-net --unshare-ipc --unshare-uts --unshare-cgroup',
    '--die-with-parent --new-session',
    '--ro-bind / /',
    '--tmpfs /tmp',
    `--bind ${shellQuote(home)} ${shellQuote(home)}`,
    `--bind ${shellQuote(projectRoot)} ${shellQuote(projectRoot)}`,
    '--ro-bind "$plugin_root" "$plugin_root"',
    `--tmpfs ${shellQuote(control)}`,
    '--proc /proc --dev /dev',
    `--chdir ${shellQuote(projectRoot)}`,
    '--clearenv',
    `--setenv PATH ${shellQuote(safePath)}`,
    `--setenv HOME ${shellQuote(home)}`,
    '--setenv TMPDIR /tmp',
    '--setenv TEMP /tmp',
    '--setenv TMP /tmp',
    `--setenv ZENSU_CONFIG ${shellQuote(config)}`,
    '--setenv CLAUDE_PLUGIN_ROOT "$plugin_root"',
    `--setenv CLAUDE_PLUGIN_DATA ${shellQuote(pluginData)}`,
    `--setenv CLAUDE_PROJECT_DIR ${shellQuote(projectRoot)}`,
    `-- ${shellQuote(realBash)} "$@"`,
  ].join(' ');
  fs.writeFileSync(wrapper, `#!/bin/bash
set +e
target="\${1:-}"
plugin_root="\${CLAUDE_PLUGIN_ROOT:-}"
is_hook=0
case "$plugin_root" in
  ${shellQuote(cacheBase)}/*) ;;
  *) exit 125 ;;
esac
case "$target" in
  "$plugin_root"/hooks/*.sh) is_hook=1 ;;
esac
invocation=""
if [ "$is_hook" -eq 1 ]; then
  invocation="$(${shellQuote(process.execPath)} ${shellQuote(logger)} start ${shellQuote(trace)} unused "$target")" || exit 125
fi
${testMode ? directCommand : containedCommand}
status=$?
${testMode ? `if [ "\${ZENSU_UPGRADE_SELFTEST_FAULT:-}" = nonzero-hook ] && [ "$is_hook" -eq 1 ]; then
  status=7
fi` : ''}
if [ "$is_hook" -eq 1 ]; then
  ${shellQuote(process.execPath)} ${shellQuote(logger)} end ${shellQuote(trace)} "$invocation" "$target" "$status" || exit 125
fi
exit "$status"
`, { mode: 0o700 });
  return { bin, trace };
}

function traceEntries(file) {
  if (!fs.existsSync(file)) return [];
  let stable;
  try {
    stable = readStableRegularFile(file, { maxBytes: 4 * 1024 * 1024 });
  } catch (_error) {
    fail('hook trace is unsafe');
  }
  const records = stable.buffer.toString('utf8').split(/\r?\n/).filter(Boolean).map((raw) => {
    const entry = safeJson(raw, 'hook trace entry');
    if (!entry || !['START', 'END'].includes(entry.type)
        || !/^[a-f0-9-]{36}$/.test(entry.id || '')
        || typeof entry.hook !== 'string'
        || (entry.type === 'END' && !Number.isInteger(entry.status))) {
      fail('hook trace entry shape is invalid');
    }
    return entry;
  });
  const pending = new Map();
  const completed = [];
  for (const record of records) {
    if (record.type === 'START') {
      if (Object.keys(record).length !== 3 || pending.has(record.id)) {
        fail('hook trace START record is duplicated or malformed');
      }
      pending.set(record.id, record);
    } else {
      const start = pending.get(record.id);
      if (Object.keys(record).length !== 4 || !start || start.hook !== record.hook) {
        fail('hook trace END record is unmatched or malformed');
      }
      pending.delete(record.id);
      completed.push({ hook: record.hook, status: record.status });
    }
  }
  if (pending.size !== 0) fail('hook trace contains an incomplete invocation');
  return completed;
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

function requireTraceScope(entries, expectedRoot, label) {
  if (entries.length === 0) fail(`${label} produced no hook trace`);
  for (const entry of entries) {
    const hook = path.resolve(entry.hook);
    if (!inside(expectedRoot, hook)) {
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
  const result = boundedSync(
    'bash',
    ['--noprofile', '--norc', '-c', 'command -v claude'],
    { encoding: 'utf8', env: credentialFreeEnvironment() },
    'Claude CLI path probe',
    PROBE_TIMEOUT_MS,
  );
  if (result.status !== 0) fail('Claude CLI is unavailable');
  const raw = String(result.stdout || '').trim();
  if (!path.isAbsolute(raw) || /[\0\r\n]/.test(raw)) fail('Claude CLI path is invalid');
  let command;
  let stat;
  try {
    command = fs.realpathSync.native(raw);
    stat = fs.lstatSync(command);
  } catch (_error) {
    fail('Claude CLI path is unavailable');
  }
  if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o111) === 0) {
    fail('Claude CLI path is unsafe');
  }
  return { command, prefix: [] };
}

function childEnvironment(home, temporary, config, traceBoundary, modelBackend) {
  const existingLogin = process.env.ZENSU_UPGRADE_EXISTING_LOGIN === '1';
  const configRoot = path.join(home, '.claude');
  const pluginRoot = path.join(configRoot, 'plugins');
  const isolatedTemp = path.join(temporary, 'tmp');
  if (!modelBackend || typeof modelBackend.apiKey !== 'string' || !modelBackend.apiKey
      || typeof modelBackend.baseUrl !== 'string' || !modelBackend.baseUrl
      || /[\0\r\n]/.test(modelBackend.apiKey)
      || /[\0\r\n]/.test(modelBackend.baseUrl)) {
    fail('candidate model backend is invalid');
  }
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
    ANTHROPIC_API_KEY: modelBackend.apiKey,
    ANTHROPIC_BASE_URL: modelBackend.baseUrl,
  };
  if (!existingLogin) env.CLAUDE_CONFIG_DIR = configRoot;
  const forwarded = [
    'SHELL', 'TERM', 'LANG', 'LC_ALL', 'CI', 'USER', 'LOGNAME',
    'SYSTEMROOT', 'WINDIR', 'COMSPEC', 'PATHEXT',
  ];
  for (const name of forwarded) {
    if (process.env[name]) env[name] = process.env[name];
  }
  if (process.env.ZENSU_UPGRADE_TEST_MODE === '1') {
    env.ZENSU_UPGRADE_SELFTEST_TRACE_FILE = traceBoundary.trace;
    env.ZENSU_UPGRADE_SELFTEST_CONTROL_DIR = path.dirname(traceBoundary.trace);
    env.ZENSU_UPGRADE_SELFTEST_PLUGIN_DATA = pluginDataPath(pluginRoot);
    env.ZENSU_UPGRADE_SELFTEST_REGISTRY_FILE = path.join(
      home,
      '.claude',
      'plugins',
      'installed_plugins.json',
    );
    env.ZENSU_UPGRADE_SELFTEST_FAULT = process.env.ZENSU_UPGRADE_SELFTEST_FAULT || '';
    if (existingLogin) {
      env.ZENSU_UPGRADE_SELFTEST_EXISTING_LOGIN_HOME =
        process.env.ZENSU_UPGRADE_TEST_EXISTING_LOGIN_HOME || '';
    }
  }
  fs.mkdirSync(env.XDG_CONFIG_HOME, { recursive: true, mode: 0o700 });
  fs.mkdirSync(env.XDG_CACHE_HOME, { recursive: true, mode: 0o700 });
  fs.mkdirSync(env.XDG_DATA_HOME, { recursive: true, mode: 0o700 });
  fs.mkdirSync(env.TMPDIR, { recursive: true, mode: 0o700 });
  return env;
}

function lifecycleInvocation(cli, args, env, temporary, projectRoot, testMode) {
  if (testMode) {
    return {
      command: cli.command,
      args: [...cli.prefix, ...args],
      env,
      containment: 'deterministic-fake-process-tree',
    };
  }
  try {
    return buildBubblewrapInvocation({
      command: cli.command,
      args: [...cli.prefix, ...args],
      cwd: projectRoot,
      disposableRoot: temporary,
      writableRoots: [temporary],
      environment: env,
      allowedCredential: 'ANTHROPIC_API_KEY',
      shareNetwork: true,
    });
  } catch (_error) {
    fail('Linux bubblewrap candidate containment is unavailable or unsafe');
  }
}

class StreamSession {
  constructor(command, args, options) {
    this.events = [];
    this.results = [];
    this.stderr = '';
    this.stdoutBytes = 0;
    this.buffer = '';
    this.closed = false;
    this.closing = false;
    this.error = null;
    this.waiters = [];
    this.tree = spawnProcessTree(command, args, {
      cwd: options.cwd,
      env: options.env,
      stdio: ['pipe', 'pipe', 'pipe'],
    }, { label: options.label || 'Claude lifecycle process' });
    this.child = this.tree.child;
    this.child.stdout.setEncoding('utf8');
    this.child.stderr.setEncoding('utf8');
    this.child.stdout.on('data', (chunk) => this.onStdout(chunk));
    this.child.stderr.on('data', (chunk) => {
      this.stderr += chunk;
      if (Buffer.byteLength(this.stderr) > MAX_STREAM_BYTES) this.abort('stderr exceeded its bound');
    });
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
    this.child.stdin.on('error', (error) => {
      if (!this.closing && !this.closed) this.recordStdinFailure(error);
    });
    this.exit = this.tree.exit.then(({ status, signal }) => {
      this.closed = true;
      this.status = status;
      this.signal = signal;
      this.flushWaiters();
      return { status, signal };
    });
  }

  recordStdinFailure(error) {
    if (!this.error) {
      const diagnostic = redactedTextDiagnostic(error?.message);
      this.error = providerError([
        'Claude stdin closed before prompt could be sent',
        `error_category=${diagnostic.category}`,
        `error_bytes=${diagnostic.bytes}`,
        `error_sha256=${diagnostic.sha256}`,
      ].join('; '));
    }
    this.flushWaiters();
  }

  abort(message) {
    if (!this.error) this.error = providerError(message);
    try { signalProcessTree(this.tree, 'SIGKILL'); }
    catch (_error) {
      this.error.message += '; process_tree_signal_failed=true';
    }
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
    if (this.error) throw this.error;
    if (this.closed) fail('cannot write to a closed Claude stream');
    const envelope = {
      type: 'user',
      message: { role: 'user', content: prompt },
      parent_tool_use_id: null,
    };
    const payload = `${JSON.stringify(envelope)}\n`;
    return new Promise((resolve, reject) => {
      let settled = false;
      const finish = (error) => {
        if (settled) return;
        settled = true;
        this.child.stdin.removeListener('error', onError);
        if (error) this.recordStdinFailure(error);
        if (this.error) reject(this.error);
        else resolve();
      };
      const onError = (error) => finish(error);
      this.child.stdin.once('error', onError);
      try { this.child.stdin.write(payload, finish); }
      catch (error) { finish(error); }
    });
  }

  waitForResult(count) {
    if (this.results.length >= count) return Promise.resolve(this.results[count - 1]);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.abort(`Claude timed out before result ${count}`);
        reject(this.error);
      }, testBoundedTimeout('ZENSU_UPGRADE_TEST_PROCESS_TIMEOUT_MS', PROCESS_TIMEOUT_MS));
      this.waiters.push({
        count,
        resolve: (value) => { clearTimeout(timer); resolve(value); },
        reject: (error) => { clearTimeout(timer); reject(error); },
      });
      this.flushWaiters();
    });
  }

  async close() {
    this.closing = true;
    try { this.child.stdin.end(); } catch (_error) { /* already closed */ }
    const closeTimeoutMs = testBoundedTimeout(
      'ZENSU_UPGRADE_TEST_CLOSE_TIMEOUT_MS',
      60000,
    );
    let timer;
    const deadline = new Promise((resolve) => {
      timer = setTimeout(() => resolve(null), closeTimeoutMs);
    });
    const result = await Promise.race([this.exit, deadline]);
    clearTimeout(timer);
    if (result === null) {
      if (!this.error) this.error = providerError('Claude did not exit after stream EOF');
      try {
        await terminateProcessTree(this.tree, { graceMs: 1000, forceMs: 5000 });
      } catch (_error) {
        this.error.message += '; process_tree_termination_failed=true';
      }
      this.flushWaiters();
      throw this.error;
    }
    try {
      await terminateProcessTree(this.tree, { graceMs: 1000, forceMs: 5000 });
    } catch (_error) {
      fail('Claude process tree did not terminate after stream EOF');
    }
    if (this.buffer.trim()) fail('Claude stream ended with an unterminated JSON record');
    if (this.error) throw this.error;
    if (result.status !== 0 || result.signal) {
      fail(`Claude exited nonzero after stream EOF: status=${result.status}; signal=${result.signal || 'none'}`);
    }
  }

  async terminate() {
    this.closing = true;
    try { this.child.stdin.destroy(); } catch (_error) { /* already closed */ }
    try {
      await terminateProcessTree(this.tree, { graceMs: 5000, forceMs: 5000 });
    } catch (_error) {
      fail('Claude process tree did not terminate during cleanup');
    }
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

function canonicalHooks(root, label) {
  try { return loadCanonicalHookConfig(root); }
  catch (_error) { fail(`${label} hook configuration is not canonical`); }
}

function candidateHookContract(root) {
  try { return captureEvaluatorOwnedHookContract(root); }
  catch (_error) { fail('candidate hook configuration violates the evaluator-owned contract'); }
}

function verifyCandidateHookContract(root, contract) {
  try { verifyCapturedHookContract(root, contract); }
  catch (_error) { fail('candidate hook integrity changed after evaluator capture'); }
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
  expectedRuntimeDigest,
) {
  let key;
  try { key = independentSessionKey(sessionId); }
  catch (_error) { fail('session key failed independent verification'); }
  const temporaryRoot = realDirectory(temporary, 'isolated filesystem root');
  let expectedPluginData;
  if (expectedPluginDataInput !== null) {
    expectedPluginData = optionalDescendantDirectory(
      temporaryRoot,
      expectedPluginDataInput,
      'expected candidate plugin data',
    );
    if (expectedPluginData === null) {
      fail('fresh candidate created 0 total context records or used the wrong plugin-data path');
    }
    if (!inside(temporaryRoot, expectedPluginData)) {
      fail('candidate plugin data escaped the isolated filesystem root');
    }
  } else {
    const parent = optionalDescendantDirectory(
      temporaryRoot,
      diagnosticPluginDataParentInput,
      'diagnostic plugin data parent',
    );
    if (parent === null || !inside(temporaryRoot, parent)) {
      fail('fresh diagnostic candidate plugin data escaped its isolated direct parent');
    }
    const children = boundedDirectoryEntries(
      parent,
      'diagnostic plugin data parent',
      1,
    );
    if (children.overflow || children.entries.length !== 1) {
      fail('fresh diagnostic candidate plugin data did not create exactly one direct child');
    }
    const child = children.entries[0];
    if (child.isSymbolicLink()) fail('candidate plugin data contains a symlink');
    if (!child.isDirectory()) {
      fail('diagnostic candidate plugin data must be a real directory');
    }
    expectedPluginData = optionalDescendantDirectory(
      parent,
      path.join(parent, child.name),
      'diagnostic candidate plugin data',
    );
    if (expectedPluginData === null || path.dirname(expectedPluginData) !== parent) {
      fail('fresh diagnostic candidate plugin data escaped its isolated direct parent');
    }
  }
  const expectedRecordsDir = optionalDescendantDirectory(
    expectedPluginData,
    path.join(expectedPluginData, 'session-control', 'v1', 'records'),
    'candidate records directory',
  );
  if (expectedRecordsDir === null) {
    fail('fresh candidate created 0 total context records or used the wrong plugin-data path');
  }
  const recordListing = boundedDirectoryEntries(
    expectedRecordsDir,
    'candidate records directory',
    2,
  );
  if (recordListing.overflow) {
    fail('candidate records directory exceeds its bounded entry count');
  }
  if (recordListing.entries.length !== 1
      || recordListing.entries[0].name !== `${key}.json`) {
    fail(`fresh candidate created ${recordListing.entries.length} total context records or used the wrong plugin-data path`);
  }
  const recordEntry = recordListing.entries[0];
  if (recordEntry.isSymbolicLink() || !recordEntry.isFile()) {
    fail('fresh candidate context record is unsafe');
  }
  const guardedDirectories = [
    expectedPluginData,
    path.join(expectedPluginData, 'session-control'),
    path.join(expectedPluginData, 'session-control', 'v1'),
    expectedRecordsDir,
  ].map((directory) => ({
    directory,
    identity: directoryIdentity(directory, 'candidate plugin data directory'),
  }));
  const recordFile = path.join(expectedRecordsDir, `${key}.json`);
  const candidateManifestVersion = safeManifest(candidateRoot, 'candidate').version;
  let independentContext;
  try {
    independentContext = readAndValidateContext(recordFile, {
      sessionId,
      projectRoot,
      pluginRoot: candidateRoot,
      pluginData: expectedPluginData,
      pluginVersion: candidateManifestVersion,
      runtimeDigest: expectedRuntimeDigest,
    });
  } catch (_error) {
    fail('fresh candidate context failed independent verification');
  }
  for (const guarded of guardedDirectories) {
    requireUnchangedDirectory(
      guarded.directory,
      guarded.identity,
      'candidate plugin data directory',
    );
  }
  const stateDirectory = optionalDescendantDirectory(
    temporaryRoot,
    path.join(projectRoot, '.zensu', 'state'),
    'candidate workflow state directory',
  );
  if (stateDirectory === null) {
    fail('fresh candidate did not create exactly one matching workflow baseline');
  }
  const stateListing = boundedDirectoryEntries(
    stateDirectory,
    'candidate workflow state directory',
    2,
  );
  if (stateListing.overflow || stateListing.entries.length !== 1
      || stateListing.entries[0].name !== `tdd-phase-${key}.json`
      || stateListing.entries[0].isSymbolicLink()
      || !stateListing.entries[0].isFile()) {
    fail('fresh candidate did not create exactly one matching workflow baseline');
  }
  const stateDirectoryBefore = directoryIdentity(
    stateDirectory,
    'candidate workflow state directory',
  );
  const stateFile = path.join(stateDirectory, `tdd-phase-${key}.json`);
  let independentState;
  try {
    independentState = readAndValidateInitialWorkflow(stateFile, { sessionId });
  } catch (_error) {
    fail('fresh candidate workflow baseline failed independent verification');
  }
  requireUnchangedDirectory(
    stateDirectory,
    stateDirectoryBefore,
    'candidate workflow state directory',
  );
  return { context: independentContext, state: independentState };
}

function probeCli(command, prefix, env, expectedVersion) {
  const result = boundedSync(
    command,
    [...prefix, '--version'],
    { encoding: 'utf8', env: withoutClaudeCredentials(env) },
    'Claude CLI version probe',
    testBoundedTimeout('ZENSU_UPGRADE_TEST_CLI_TIMEOUT_MS', PROBE_TIMEOUT_MS),
  );
  if (result.status !== 0) fail('Claude CLI version probe failed');
  const match = String(result.stdout || '').match(/^([0-9]+\.[0-9]+\.[0-9]+)/);
  if (!match || match[1] !== expectedVersion) {
    fail(`Claude CLI must be exactly ${expectedVersion}`);
  }
}

function probeExistingLogin(command, prefix, env, cwd) {
  const result = boundedSync(command, [...prefix, 'auth', 'status', '--json'], {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    env: withoutClaudeCredentials(env),
  }, 'existing-login Claude auth preflight', PROBE_TIMEOUT_MS);
  if (result.status !== 0) fail('existing-login Claude auth preflight failed');
  const status = safeJson(result.stdout || '', 'existing-login Claude auth status');
  if (status?.loggedIn !== true || typeof status?.authMethod !== 'string' || !status.authMethod) {
    fail('existing-login credentials are unavailable to the isolated diagnostic process');
  }
}

async function runAuthenticatedCliCanary(
  command,
  prefix,
  credential,
  temporary,
) {
  if (!credential || !['ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN'].includes(credential.name)
      || typeof credential.value !== 'string' || !credential.value) {
    fail('authenticated Claude canary credential is invalid');
  }
  const root = path.join(temporary, 'authenticated-canary');
  const home = path.join(root, 'home');
  const project = path.join(root, 'project');
  const temp = path.join(root, 'tmp');
  for (const directory of [home, project, temp]) {
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  }
  const env = credentialFreeEnvironment(process.env, {
    HOME: home,
    CLAUDE_CONFIG_DIR: path.join(home, '.claude'),
    XDG_CONFIG_HOME: path.join(home, '.config'),
    XDG_CACHE_HOME: path.join(home, '.cache'),
    XDG_DATA_HOME: path.join(home, '.local', 'share'),
    TMPDIR: temp,
    TEMP: temp,
    TMP: temp,
    CLAUDE_CODE_TMPDIR: temp,
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
    CLAUDE_CODE_SKIP_PROMPT_HISTORY: '1',
  });
  env[credential.name] = credential.value;
  if (process.env.ZENSU_UPGRADE_TEST_MODE === '1') {
    env.ZENSU_UPGRADE_SELFTEST_FAULT = process.env.ZENSU_UPGRADE_SELFTEST_FAULT || '';
    env.ZENSU_UPGRADE_SELFTEST_LAUNCH_SENTINEL =
      process.env.ZENSU_UPGRADE_SELFTEST_LAUNCH_SENTINEL || '';
  }
  const canaryArgs = [
    ...prefix,
    '--print',
    '--output-format', 'text',
    '--safe-mode',
    '--setting-sources', '',
    '--strict-mcp-config',
    '--mcp-config', '{"mcpServers":{}}',
    '--tools', '',
    '--no-session-persistence',
    'Reply with exactly ZENSU_AUTH_CANARY_OK and no other text.',
  ];
  let invocation = {
    command,
    args: canaryArgs,
    env,
    argumentInput: null,
  };
  if (process.env.ZENSU_UPGRADE_TEST_MODE !== '1') {
    try {
      invocation = buildBubblewrapInvocation({
        command,
        args: canaryArgs,
        cwd: project,
        disposableRoot: temporary,
        writableRoots: [temporary],
        environment: env,
        allowedCredential: credential.name,
        environmentArgumentFd: 3,
        shareNetwork: true,
      });
    } catch (_error) {
      fail('plugin-free authenticated Claude canary containment is unavailable or unsafe');
    }
  }
  const result = await runProcessTreeBounded(invocation.command, invocation.args, {
    cwd: project,
    encoding: 'utf8',
    env: invocation.env,
  }, {
    label: 'plugin-free authenticated Claude canary',
    timeoutMs: PROCESS_TIMEOUT_MS,
    maxBuffer: 4 * 1024 * 1024,
    trustedEvaluatorCommand: true,
    argumentInput: invocation.argumentInput,
  });
  if (result.status !== 0 || result.signal
      || String(result.stdout || '').trim() !== 'ZENSU_AUTH_CANARY_OK') {
    fail('plugin-free authenticated Claude canary failed');
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
  if (process.platform === 'win32') {
    fail('Windows candidate containment is unsupported; no helper or Claude process was started');
  }
  if (!testMode && process.platform !== 'linux') {
    fail('real Claude candidate upgrade validation requires Linux bubblewrap containment');
  }
  if (!testMode && existingLogin) {
    fail('existing-login candidate execution is forbidden; use the plugin-free authenticated canary with an explicit credential');
  }
  const testExistingLoginHome = process.env.ZENSU_UPGRADE_TEST_EXISTING_LOGIN_HOME || '';
  if (testMode && existingLogin) {
    if (!path.isAbsolute(testExistingLoginHome)
        || realDirectory(testExistingLoginHome, 'test existing-login HOME')
          !== realDirectory(process.env.HOME || '', 'existing-login host HOME')) {
      fail('deterministic existing-login mode requires its exact hermetic test HOME');
    }
  } else if (testExistingLoginHome) {
    fail('test existing-login HOME is forbidden outside deterministic existing-login mode');
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
  let explicitCredential = null;
  if (!existingLogin) {
    try { explicitCredential = selectExplicitCredential(process.env); }
    catch (_error) { fail('explicit Claude credential is invalid'); }
  }
  if (!testMode && !existingLogin && !explicitCredential) {
    fail('explicit Claude credentials are unavailable');
  }
  if (existingLogin && (!process.env.HOME || !path.isAbsolute(process.env.HOME))) {
    fail('existing-login mode requires an absolute host HOME');
  }
  const executionMode = existingLogin
    ? EXECUTION_MODES.diagnostic
    : testMode ? EXECUTION_MODES.fake : EXECUTION_MODES.authoritative;
  const hostHome = existingLogin ? realDirectory(process.env.HOME, 'existing-login host HOME') : null;
  const hostCanaryBefore = existingLogin ? existingLoginCanary(hostHome) : null;
  const temporaryBase = testMode ? os.tmpdir() : '/tmp';
  const temporary = fs.realpathSync.native(
    fs.mkdtempSync(path.join(temporaryBase, 'zensu-claude-upgrade-')),
  );
  const temporaryIdentity = captureOwnedDirectory(temporary, 'isolated upgrade temporary root');
  const temporaryParentIdentity = captureOwnedDirectory(
    path.dirname(temporary),
    'isolated upgrade temporary parent',
  );
  const activeProcesses = new Set();
  let primaryError = null;
  let pendingAttestationLine = null;
  let mockBackend = null;
  try {
    const home = path.join(temporary, 'home');
    const projectRoot = path.join(temporary, 'project');
    const control = path.join(temporary, 'control');
    const oldCheckout = path.join(temporary, 'old-v0.16.1-source');
    const pluginStore = path.join(home, '.claude', 'plugins');
    const pluginData = pluginDataPath(pluginStore);
    const cacheBase = path.join(home, '.claude', 'plugins', 'cache', 'zensu', 'zensu');
    for (const directory of [home, control, cacheBase, pluginData]) {
      fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    }
    createProject(projectRoot);
    const bashGuard = createBashGuard(control);
    const cliSettings = commandLineSettings(
      bashGuard,
      [control, ...(hostHome ? [hostHome] : [])],
    );
    const config = path.join(home, '.zensu-upgrade-config.json');
    fs.writeFileSync(config, '{"context":{"compactionNudge":false},"hooks":{"intentRouter":false,"tddReminder":false,"pulseSession":false,"sessionBanner":false}}\n', { mode: 0o400 });

    const clone = boundedSync('git', [
      '--no-replace-objects',
      '-c', 'protocol.file.allow=always', '-c', 'core.hooksPath=/dev/null',
      'clone', '--no-local', '--no-hardlinks', '--no-checkout', '--', sourceRoot, oldCheckout,
    ], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      env: gitHelperEnvironment(),
    }, 'local source clone', GIT_TIMEOUT_MS, 16 * 1024 * 1024);
    if (clone.status !== 0) fail('cannot clone local upgrade source');
    git(oldCheckout, ['checkout', '--detach', '--force', oldRevision]);
    if (git(oldCheckout, ['status', '--porcelain=v1', '--untracked-files=all'])) fail('v0.16.1 checkout is dirty');
    if (safeManifest(oldCheckout, 'v0.16.1').version !== OLD_VERSION) fail('v0.16.1 tag manifest drifted');

    const candidateSourceVersion = safeManifest(sourceRoot, 'candidate source').version;
    const candidateVersion = installedVersion(candidateSourceVersion);
    const oldRoot = install(oldCheckout, cacheBase, OLD_VERSION, oldRevision);
    canonicalHooks(oldRoot, 'v0.16.1');
    const oldRuntimeDigest = runtimeDigest(oldRoot);
    if (oldRuntimeDigest !== runtimeDigest(oldCheckout)) fail('installed v0.16.1 runtime is not byte-identical to its tag');
    const oldInventoryBefore = new Map();
    const oldBytesBefore = snapshotTree(oldRoot, oldInventoryBefore);
    requireOrphanMarker(oldRoot, false, null, 'old runtime before process activation');

    const traceBoundary = createTraceBoundary(
      control,
      cacheBase,
      home,
      projectRoot,
      pluginData,
      config,
    );
    const cli = cliCommand();
    const probeHome = path.join(temporary, 'version-probe');
    const probeTemp = path.join(probeHome, 'tmp');
    for (const directory of [
      probeHome,
      probeTemp,
      path.join(probeHome, '.claude'),
      path.join(probeHome, '.config'),
      path.join(probeHome, '.cache'),
      path.join(probeHome, '.local', 'share'),
    ]) {
      fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    }
    const probeEnvironment = credentialFreeEnvironment(process.env, {
      HOME: probeHome,
      CLAUDE_CONFIG_DIR: path.join(probeHome, '.claude'),
      XDG_CONFIG_HOME: path.join(probeHome, '.config'),
      XDG_CACHE_HOME: path.join(probeHome, '.cache'),
      XDG_DATA_HOME: path.join(probeHome, '.local', 'share'),
      TMPDIR: probeTemp,
      TEMP: probeTemp,
      TMP: probeTemp,
      CLAUDE_CODE_TMPDIR: probeTemp,
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
      CLAUDE_CODE_SKIP_PROMPT_HISTORY: '1',
    });
    if (testMode) {
      probeEnvironment.ZENSU_UPGRADE_SELFTEST_FAULT =
        process.env.ZENSU_UPGRADE_SELFTEST_FAULT || '';
    }
    probeCli(
      cli.command,
      cli.prefix,
      probeEnvironment,
      expectedCliVersion,
    );
    if (existingLogin) {
      const preflightEnv = childEnvironment(
        home,
        temporary,
        config,
        traceBoundary,
        { apiKey: 'zensu-upgrade-test-dummy-key', baseUrl: 'http://127.0.0.1:9' },
      );
      probeExistingLogin(cli.command, cli.prefix, preflightEnv, projectRoot);
      if (existingLoginCanary(hostHome) !== hostCanaryBefore) {
        fail('existing-login auth preflight changed the host config/cache canary');
      }
    } else {
      await runAuthenticatedCliCanary(
        cli.command,
        cli.prefix,
        explicitCredential || {
          name: 'ANTHROPIC_API_KEY',
          value: 'zensu-upgrade-selftest-auth-canary',
        },
        temporary,
      );
    }
    if (!testMode) mockBackend = await startUpgradeAnthropicMock();
    const candidateBackend = mockBackend
      ? { apiKey: mockBackend.apiKey, baseUrl: mockBackend.url }
      : {
        apiKey: 'zensu-upgrade-test-dummy-key',
        baseUrl: 'http://127.0.0.1:9',
      };
    const env = childEnvironment(
      home,
      temporary,
      config,
      traceBoundary,
      candidateBackend,
    );
    writeRegistry(home, oldRoot, OLD_VERSION, oldRevision);

    const allowedReadFiles = [
      path.join(projectRoot, 'old-turn-1.txt'),
      path.join(projectRoot, 'old-turn-2.txt'),
      path.join(projectRoot, 'old-turn-3.txt'),
      path.join(projectRoot, 'candidate-turn.txt'),
    ].map((file) => fs.realpathSync.native(file));

    const oldSessionId = crypto.randomUUID();
    const oldInvocation = lifecycleInvocation(
      cli,
      claudeArgs(
        oldSessionId,
        allowedReadFiles,
        cliSettings,
        existingLogin ? oldRoot : null,
      ),
      env,
      temporary,
      projectRoot,
      testMode,
    );
    const oldProcess = new StreamSession(oldInvocation.command, oldInvocation.args, {
      cwd: projectRoot,
      env: oldInvocation.env,
      label: 'contained old Claude lifecycle',
    });
    activeProcesses.add(oldProcess);
    let eventStart = 0;
    let traceStart = 0;
    const oldTurn1Token = OLD_TURN_TOKENS[0];
    const oldTurn1File = fs.realpathSync.native(path.join(projectRoot, 'old-turn-1.txt'));
    await oldProcess.send(promptFor(oldTurn1File));
    await oldProcess.waitForResult(1);
    let resultIndex = oldProcess.events.findIndex((event) => event === oldProcess.results[0]);
    validateTurn(oldProcess.events, eventStart, resultIndex, oldTurn1File, oldTurn1Token, 'old turn one');
    requireTurnInitEvents(oldProcess.events, oldSessionId, 1, 'old process');
    let trace = traceEntries(traceBoundary.trace);
    let delta = trace.slice(traceStart);
    requireTraceScope(delta, oldRoot, 'old turn one');
    requireTrace(delta, oldRoot, 'stop-chain-enforcer.sh', 1, 'old turn one');
    for (const hook of [
      'session-start-pulse.sh', 'session-start-banner.sh',
      'session-start-primer.sh', 'session-start-autopilot-resume.sh',
    ]) requireTrace(delta, oldRoot, hook, 1, 'old turn one');
    requireInUseMarker(
      oldRoot,
      testMode ? oldProcess.child.pid : null,
      true,
      'old process',
    );
    requireOrphanMarker(
      oldRoot, false, null, 'old runtime after old-process activation',
    );
    traceStart = trace.length;
    eventStart = resultIndex + 1;

    const candidateRoot = install(
      sourceRoot,
      cacheBase,
      candidateVersion.version,
      sourceRevision,
    );
    if (candidateRoot === oldRoot) fail('old and candidate runtime roots alias');
    injectCandidateHookContractFaultForTest(
      candidateRoot,
      process.env.ZENSU_UPGRADE_SELFTEST_FAULT || '',
    );
    const capturedCandidateHooks = candidateHookContract(candidateRoot);
    verifyCandidateHookContract(candidateRoot, capturedCandidateHooks);
    const candidateRuntimeDigest = runtimeDigest(candidateRoot);
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
    await oldProcess.send(promptFor(oldTurn2File));
    await oldProcess.waitForResult(2);
    resultIndex = oldProcess.events.findIndex((event) => event === oldProcess.results[1]);
    validateTurn(oldProcess.events, eventStart, resultIndex, oldTurn2File, oldTurn2Token, 'old turn two');
    requireTurnInitEvents(oldProcess.events, oldSessionId, 2, 'old process');
    if (oldProcess.results.length !== 2) {
      fail(`old process did not remain one process with exactly two completed turns; init_count=${initEvents(oldProcess.events).length}; result_count=${oldProcess.results.length}; closed=${oldProcess.closed ? 'true' : 'false'}; status=${String(oldProcess.status ?? 'none')}`);
    }
    trace = traceEntries(traceBoundary.trace);
    delta = trace.slice(traceStart);
    requireTraceScope(delta, oldRoot, 'old turn two');
    requireTrace(delta, oldRoot, 'stop-chain-enforcer.sh', 1, 'old turn two');
    traceStart = trace.length;
    eventStart = resultIndex + 1;
    if (oldProcess.closed) fail('old process closed before the fresh candidate session started');

    const candidateSessionId = crypto.randomUUID();
    verifyCandidateHookContract(candidateRoot, capturedCandidateHooks);
    const candidateInvocation = lifecycleInvocation(
      cli,
      claudeArgs(
        candidateSessionId,
        allowedReadFiles,
        cliSettings,
        existingLogin ? candidateRoot : null,
      ),
      env,
      temporary,
      projectRoot,
      testMode,
    );
    const candidateProcess = new StreamSession(
      candidateInvocation.command,
      candidateInvocation.args,
      {
        cwd: projectRoot,
        env: candidateInvocation.env,
        label: 'contained candidate Claude lifecycle',
      },
    );
    activeProcesses.add(candidateProcess);
    const candidateToken = CANDIDATE_TOKEN;
    const candidateFile = fs.realpathSync.native(path.join(projectRoot, 'candidate-turn.txt'));
    await candidateProcess.send(candidatePromptFor(candidateFile));
    await candidateProcess.waitForResult(1);
    verifyCandidateHookContract(candidateRoot, capturedCandidateHooks);
    candidateActivationWindow.endedAtMs = Date.now();
    const candidateResultIndex = candidateProcess.events.findIndex((event) => event === candidateProcess.results[0]);
    validateCandidateTurn(candidateProcess.events, candidateResultIndex, candidateFile, candidateToken);
    requireInUseMarker(
      candidateRoot,
      testMode ? candidateProcess.child.pid : null,
      true,
      'fresh candidate process',
    );
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
      oldRoot, testMode ? oldProcess.child.pid : null, true,
      'old process during candidate activation',
    );
    trace = traceEntries(traceBoundary.trace);
    delta = trace.slice(traceStart);
    requireTraceScope(delta, candidateRoot, 'fresh candidate');
    const expectedHookCounts = new Map();
    for (const name of [
      ...capturedCandidateHooks.observedExpectedHooks.SessionStart,
      ...capturedCandidateHooks.observedExpectedHooks.Stop,
      ...capturedCandidateHooks.observedExpectedHooks.PreToolUse.Read,
      ...capturedCandidateHooks.observedExpectedHooks.PreToolUse.Bash,
    ]) expectedHookCounts.set(name, (expectedHookCounts.get(name) || 0) + 1);
    for (const [name, count] of expectedHookCounts) {
      requireTrace(delta, candidateRoot, name, count, 'fresh candidate Read/Bash PreToolUse');
    }
    requireBashGuardTrace(bashGuard.trace);
    await candidateProcess.close();
    activeProcesses.delete(candidateProcess);
    verifyCandidateHookContract(candidateRoot, capturedCandidateHooks);
    requireInUseMarker(candidateRoot, null, false, 'fresh candidate process');
    validateFreshState(
      candidateRoot,
      projectRoot,
      candidateSessionId,
      temporary,
      existingLogin ? null : pluginDataPath(env.CLAUDE_CODE_PLUGIN_CACHE_DIR),
      existingLogin ? path.join(env.CLAUDE_CODE_PLUGIN_CACHE_DIR, 'data') : null,
      candidateRuntimeDigest,
    );
    traceStart = trace.length;
    if (oldProcess.closed) fail('old process did not remain open through the fresh candidate session');

    const oldTurn3Token = OLD_TURN_TOKENS[2];
    const oldTurn3File = fs.realpathSync.native(path.join(projectRoot, 'old-turn-3.txt'));
    await oldProcess.send(promptFor(oldTurn3File));
    await oldProcess.waitForResult(3);
    resultIndex = oldProcess.events.findIndex((event) => event === oldProcess.results[2]);
    validateTurn(oldProcess.events, eventStart, resultIndex, oldTurn3File, oldTurn3Token, 'old turn three after candidate');
    requireTurnInitEvents(oldProcess.events, oldSessionId, 3, 'old process');
    if (oldProcess.results.length !== 3) {
      fail(`old process did not remain one process with exactly three completed turns; init_count=${initEvents(oldProcess.events).length}; result_count=${oldProcess.results.length}; closed=${oldProcess.closed ? 'true' : 'false'}; status=${String(oldProcess.status ?? 'none')}`);
    }
    trace = traceEntries(traceBoundary.trace);
    delta = trace.slice(traceStart);
    requireTraceScope(delta, oldRoot, 'old turn three after candidate');
    requireTrace(delta, oldRoot, 'stop-chain-enforcer.sh', 1, 'old turn three after candidate');
    await oldProcess.close();
    activeProcesses.delete(oldProcess);
    requireInUseMarker(oldRoot, null, false, 'old process');

    const oldOrphanMarkerFinal = requireOrphanMarker(
      oldRoot, true, null, 'old runtime final',
    );
    if (oldOrphanMarkerFinal.fingerprint !== oldOrphanMarkerAfterCandidate.fingerprint) {
      fail('old runtime .orphaned_at marker changed after candidate activation');
    }
    requireOrphanMarker(candidateRoot, false, null, 'candidate runtime final');
    verifyCandidateHookContract(candidateRoot, capturedCandidateHooks);

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
    if (mockBackend) mockBackend.assertHealthy();
    const evidence = {
      schema: 'zensu.session-control-upgrade-evidence',
      schema_version: 2,
      host: 'claude',
      gate: 'passed',
      execution_mode: executionMode,
      authenticated_canary_status: existingLogin
        ? 'not-applicable-hermetic-existing-login-test'
        : testMode ? 'passed-deterministic-fake' : 'passed-plugin-free-live',
      candidate_model_backend: testMode
        ? 'deterministic-fake-cli'
        : 'deterministic-loopback-anthropic-mock',
      candidate_containment: testMode
        ? 'deterministic-fake-process-tree'
        : 'linux-bwrap-pid-mount-with-nested-hook-net-v1',
      host_config_cache_canary_status: existingLogin
        ? 'unchanged-local-diagnostic'
        : testMode ? 'not-applicable-test-mode' : 'not-applicable-isolated-home',
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
      old_session_id_hash: verifiedSessionIdHash(oldSessionId),
      candidate_session_id_hash: verifiedSessionIdHash(candidateSessionId),
      old_process_result_count: 3,
      fresh_process_result_count: 1,
      hook_sequence: [...REQUIRED_SEQUENCE],
    };
    pendingAttestationLine = line(evidence);
  } catch (error) {
    primaryError = error;
    throw error;
  } finally {
    const cleanupResults = await Promise.allSettled(
      [...activeProcesses].map((session) => session.terminate()),
    );
    const cleanupFailureCount = cleanupResults.filter(
      (result) => result.status === 'rejected',
    ).length;
    let mockCleanupError = null;
    if (mockBackend) {
      try { await mockBackend.close(); }
      catch (error) { mockCleanupError = error; }
    }
    let canaryChanged = false;
    let canaryInspectionError = null;
    try {
      canaryChanged = existingLogin && existingLoginCanary(hostHome) !== hostCanaryBefore;
    } catch (error) {
      canaryInspectionError = error;
    }
    let removalFailed = false;
    try {
      quarantineAndRemoveOwnedDirectory(
        temporaryIdentity,
        temporaryParentIdentity,
        'isolated upgrade temporary root',
      );
    } catch (_error) {
      removalFailed = true;
    }
    if (testMode
        && process.env.ZENSU_UPGRADE_SELFTEST_FAULT === 'post-cleanup-attestation-failure') {
      removalFailed = true;
    }
    if (primaryError) {
      if (cleanupFailureCount > 0) {
        primaryError.message += `; process_cleanup_failures=${cleanupFailureCount}`;
      }
      if (canaryChanged) {
        primaryError.message += '; existing-login host config/cache canary also changed';
      }
      if (canaryInspectionError) {
        primaryError.message += '; existing-login canary inspection also failed';
      }
      if (mockCleanupError) primaryError.message += '; deterministic model backend cleanup also failed';
      if (removalFailed) primaryError.message += '; temporary cleanup also failed';
    } else if (cleanupFailureCount > 0) {
      fail(`Claude process cleanup failed; failure_count=${cleanupFailureCount}`);
    } else if (mockCleanupError) {
      fail('deterministic model backend cleanup failed');
    } else if (canaryInspectionError) {
      throw canaryInspectionError;
    } else if (canaryChanged) {
      fail('existing-login host config/cache canary changed during the local diagnostic');
    } else if (removalFailed) {
      fail('isolated upgrade temporary directory cleanup failed');
    }
  }
  if (typeof pendingAttestationLine !== 'string' || !pendingAttestationLine) {
    fail('upgrade attestation commit point was not reached');
  }
  process.stdout.write(`${pendingAttestationLine}\n`);
}

if (require.main === module) {
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
}

module.exports = {
  createTraceBoundary,
};
