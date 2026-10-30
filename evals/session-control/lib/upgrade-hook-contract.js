#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const vm = require('node:vm');
const { readStableRegularFile } = require('./safe-file-read.js');

const CANONICAL_COMMAND = /^bash "\$\{CLAUDE_PLUGIN_ROOT\}\/hooks\/([A-Za-z0-9._-]+\.sh)"$/;
const DISPATCHER_ARGUMENT = '${CLAUDE_PLUGIN_ROOT}/hooks/lib/hook-dispatch-v1.js';
const DISPATCHER_TARGET = 'lib/hook-dispatch-v1.js';
const DISPATCHER_REGISTRY = 'lib/hook-registration-v1.js';
const DISPATCH_FLAGS = Object.freeze({ PreToolUse: 'pre', PostToolUse: 'post' });
const HOOK_TARGET = /^(?:[A-Za-z0-9._-]+\.sh|lib\/[A-Za-z0-9._-]+\.js|checks\/[A-Za-z0-9._-]+\.sh)$/;
const EVALUATOR_REQUIRED_HOOKS = deepFreeze({
  PreToolUse: {
    Read: [
      'pre-reviewer-capability-gate.sh',
    ],
    Bash: [
      'pre-reviewer-capability-gate.sh',
      'pre-bash-zensu-gate.sh',
      'pre-bash-source-write-gate.sh',
      'pre-write-secret-scan.sh',
    ],
  },
  SessionStart: [
    'session-start-session-control.sh',
  ],
  Stop: [
    'stop-chain-enforcer.sh',
  ],
});

function contractError(message) {
  const error = new Error(`upgrade hook contract: ${message}`);
  error.name = 'UpgradeHookContractError';
  return error;
}

function deepFreeze(value) {
  if (!value || typeof value !== 'object' || Object.isFrozen(value)) return value;
  for (const child of Object.values(value)) deepFreeze(child);
  return Object.freeze(value);
}

function inside(parent, child) {
  const relative = path.relative(parent, child);
  return relative === '' || (relative !== '..' && !relative.startsWith(`..${path.sep}`)
    && !path.isAbsolute(relative));
}

function canonicalPluginRoot(rootInput) {
  try {
    const root = fs.realpathSync.native(rootInput);
    const stat = fs.lstatSync(root);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('unsafe root');
    return root;
  } catch (_error) {
    throw contractError('plugin root is unsafe');
  }
}

function captureDirectoryIdentity(directory, includeTimestamps) {
  try {
    const before = fs.lstatSync(directory, { bigint: true });
    const canonicalPath = fs.realpathSync.native(directory);
    const after = fs.lstatSync(directory, { bigint: true });
    if (!before.isDirectory() || before.isSymbolicLink()
        || !after.isDirectory() || after.isSymbolicLink()
        || canonicalPath !== path.resolve(directory)
        || before.dev !== after.dev || before.ino !== after.ino
        || (includeTimestamps
          && (before.mtimeNs !== after.mtimeNs || before.ctimeNs !== after.ctimeNs))) {
      throw new Error('unsafe directory identity');
    }
    const identity = {
      canonicalPath,
      dev: String(after.dev),
      ino: String(after.ino),
    };
    if (includeTimestamps) {
      identity.mtimeNs = String(after.mtimeNs);
      identity.ctimeNs = String(after.ctimeNs);
    }
    return identity;
  } catch (_error) {
    throw contractError('directory identity is unsafe');
  }
}

function captureBoundDirectoryIntegrity(root) {
  const before = {
    cacheParent: captureDirectoryIdentity(path.dirname(root), true),
    pluginRoot: captureDirectoryIdentity(root, false),
    hooksDirectory: captureDirectoryIdentity(path.join(root, 'hooks'), true),
  };
  const hooksDirectoryAfter = captureDirectoryIdentity(path.join(root, 'hooks'), true);
  const pluginRootAfter = captureDirectoryIdentity(root, false);
  const cacheParentAfter = captureDirectoryIdentity(path.dirname(root), true);
  const after = {
    cacheParent: cacheParentAfter,
    pluginRoot: pluginRootAfter,
    hooksDirectory: hooksDirectoryAfter,
  };
  if (JSON.stringify(before) !== JSON.stringify(after)) {
    throw contractError('directory identity is unsafe');
  }
  return after;
}

function assertDirectoryIntegrity(root, expected) {
  let current;
  try {
    current = captureBoundDirectoryIntegrity(root);
  } catch (_error) {
    throw contractError('directory identity changed after capture');
  }
  if (JSON.stringify(current) !== JSON.stringify(expected)) {
    throw contractError('directory identity changed after capture');
  }
}

function canonicalHookBasename(command) {
  if (typeof command !== 'string') throw contractError('hook command is invalid');
  const match = command.match(CANONICAL_COMMAND);
  if (!match) throw contractError('hook command is not a canonical plugin hook command');
  return match[1];
}

function dispatcherFlag(event, hook) {
  if (hook.command !== 'node') return null;
  if (!Object.prototype.hasOwnProperty.call(DISPATCH_FLAGS, event)
      || !Array.isArray(hook.args) || hook.args.length !== 2
      || hook.args[0] !== DISPATCHER_ARGUMENT || hook.args[1] !== DISPATCH_FLAGS[event]) {
    throw contractError('hook command is not the canonical dispatcher');
  }
  return hook.args[1];
}

function hookProcessName(event, hook) {
  const flag = dispatcherFlag(event, hook);
  return flag === null ? canonicalHookBasename(hook.command) : `hook-dispatch-v1.js:${flag}`;
}

function loadDispatchedChecks(root) {
  let source;
  try {
    source = readStableRegularFile(path.join(root, 'hooks', DISPATCHER_REGISTRY), {
      minBytes: 1,
      maxBytes: 1024 * 1024,
    }).buffer.toString('utf8');
  } catch (_error) {
    throw contractError('dispatcher check registry is unsafe');
  }
  const module = { exports: {} };
  let checks;
  try {
    vm.runInNewContext(source, {
      module,
      exports: module.exports,
      require: () => { throw new Error('require refused'); },
    }, { timeout: 1000 });
    checks = JSON.parse(JSON.stringify(module.exports.DISPATCHED_CHECKS));
  } catch (_error) {
    throw contractError('dispatcher check registry is unsafe');
  }
  if (!Array.isArray(checks) || checks.length === 0) throw contractError('dispatcher check registry is invalid');
  const names = new Set();
  for (const check of checks) {
    const valid = Boolean(check) && typeof check === 'object' && !Array.isArray(check)
      && JSON.stringify(Object.keys(check)) === JSON.stringify(['event', 'name', 'matcher', 'script', 'body', 'failure'])
      && Object.prototype.hasOwnProperty.call(DISPATCH_FLAGS, check.event)
      && typeof check.name === 'string' && /^[a-z][a-z-]*$/.test(check.name)
      && !names.has(`${check.event}:${check.name}`)
      && typeof check.matcher === 'string' && check.matcher !== ''
      && typeof check.script === 'string' && /^[A-Za-z0-9._-]+\.sh$/.test(check.script)
      && (check.body === null || (typeof check.body === 'string' && /^checks\/[A-Za-z0-9._-]+\.sh$/.test(check.body)))
      && ['open', 'closed'].includes(check.failure);
    if (!valid) throw contractError('dispatcher check registry is invalid');
    try { new RegExp(check.matcher); }
    catch (_error) { throw contractError('dispatcher check registry is invalid'); }
    names.add(`${check.event}:${check.name}`);
  }
  return deepFreeze(checks);
}

function configDispatches(config) {
  return Object.entries(config?.hooks || {}).some(([event, groups]) => (groups || []).some(
    (group) => (group.hooks || []).some((hook) => dispatcherFlag(event, hook) !== null),
  ));
}

function loadCanonicalHookConfig(rootInput) {
  const root = canonicalPluginRoot(rootInput);
  let config;
  try {
    const file = path.join(root, 'hooks', 'hooks.json');
    const raw = readStableRegularFile(file, {
      minBytes: 2,
      maxBytes: 1024 * 1024,
    }).buffer.toString('utf8');
    config = JSON.parse(raw);
  } catch (_error) {
    throw contractError('hook configuration is unsafe');
  }
  if (!config || typeof config !== 'object' || Array.isArray(config)
      || !config.hooks || typeof config.hooks !== 'object' || Array.isArray(config.hooks)) {
    throw contractError('hook configuration shape is invalid');
  }

  const hookRoot = path.join(root, 'hooks');
  for (const [event, groups] of Object.entries(config.hooks)) {
    if (!/^[A-Za-z][A-Za-z0-9]*$/.test(event) || !Array.isArray(groups) || groups.length === 0) {
      throw contractError('hook event configuration is invalid');
    }
    for (const group of groups) {
      if (!group || typeof group !== 'object' || Array.isArray(group)
          || !Array.isArray(group.hooks) || group.hooks.length === 0
          || (group.matcher !== undefined && typeof group.matcher !== 'string')) {
        throw contractError('hook group configuration is invalid');
      }
      if (group.matcher !== undefined) {
        if (Buffer.byteLength(group.matcher) > 1024 || /[\0\r\n]/.test(group.matcher)) {
          throw contractError('hook matcher is invalid');
        }
        try { new RegExp(group.matcher); }
        catch (_error) { throw contractError('hook matcher is invalid'); }
      }
      for (const hook of group.hooks) {
        if (!hook || typeof hook !== 'object' || Array.isArray(hook)
            || hook.type !== 'command'
            || (hook.timeout !== undefined
              && (!Number.isFinite(hook.timeout) || hook.timeout <= 0))) {
          throw contractError('hook entry is invalid');
        }
        const dispatched = dispatcherFlag(event, hook) !== null;
        const allowed = dispatched ? ['args', 'command', 'onFailure', 'timeout', 'type'] : ['command', 'timeout', 'type'];
        if (Object.keys(hook).some((key) => !allowed.includes(key))
            || (dispatched && (group.matcher !== '.*'
              || hook.onFailure !== (event === 'PreToolUse' ? 'block' : undefined)))) {
          throw contractError('hook entry is invalid');
        }
        const basename = dispatched ? DISPATCHER_TARGET : canonicalHookBasename(hook.command);
        const target = path.join(hookRoot, basename);
        try {
          const stat = fs.lstatSync(target);
          const physical = fs.realpathSync.native(target);
          if (!stat.isFile() || stat.isSymbolicLink() || !inside(hookRoot, physical)) {
            throw new Error('unsafe hook target');
          }
        } catch (_error) {
          throw contractError('hook target is unsafe');
        }
      }
    }
  }
  return config;
}

function matchingHookBasenames(config, event, toolName, checks = []) {
  const basenames = [];
  for (const group of config?.hooks?.[event] || []) {
    let matches = true;
    if (toolName !== undefined) matches = new RegExp(group.matcher || '.*').test(toolName);
    if (!matches) continue;
    for (const hook of group.hooks || []) {
      if (dispatcherFlag(event, hook) === null) {
        basenames.push(canonicalHookBasename(hook.command));
        continue;
      }
      for (const check of checks) {
        if (check.event === event && (toolName === undefined || new RegExp(check.matcher).test(toolName))) {
          basenames.push(check.script);
        }
      }
    }
  }
  return basenames;
}

function matchingHookProcesses(config, event, toolName) {
  const names = [];
  for (const group of config?.hooks?.[event] || []) {
    if (toolName !== undefined && !new RegExp(group.matcher || '.*').test(toolName)) continue;
    for (const hook of group.hooks || []) names.push(hookProcessName(event, hook));
  }
  return names;
}

function configuredHookBasenames(config, checks = []) {
  const basenames = new Set(['hooks.json']);
  for (const [event, groups] of Object.entries(config?.hooks || {})) {
    for (const group of groups || []) {
      for (const hook of group.hooks || []) {
        if (dispatcherFlag(event, hook) === null) {
          basenames.add(canonicalHookBasename(hook.command));
          continue;
        }
        basenames.add(DISPATCHER_TARGET);
        basenames.add(DISPATCHER_REGISTRY);
        for (const check of checks) {
          basenames.add(check.script);
          if (check.body !== null) basenames.add(check.body);
        }
      }
    }
  }
  return [...basenames].sort();
}

function requireUniqueHooks(basenames, label) {
  const seen = new Set();
  for (const basename of basenames) {
    if (seen.has(basename)) throw contractError(`${label} contains a duplicate hook`);
    seen.add(basename);
  }
}

function requireOrderedHooks(basenames, required, label) {
  let previousIndex = -1;
  for (const basename of required) {
    const index = basenames.indexOf(basename);
    if (index === -1) throw contractError(`${label} is missing a required hook`);
    if (index <= previousIndex) throw contractError(`${label} required hook order is invalid`);
    previousIndex = index;
  }
}

function sameBigIntFileIdentity(left, right) {
  return left.dev === right.dev
    && left.ino === right.ino
    && left.size === right.size
    && left.mtimeNs === right.mtimeNs
    && left.ctimeNs === right.ctimeNs;
}

function captureHookIntegrity(root, basename) {
  if (basename !== 'hooks.json' && !HOOK_TARGET.test(basename)) {
    throw contractError('hook target integrity is unsafe');
  }
  const hookRoot = path.join(root, 'hooks');
  const target = path.join(hookRoot, basename);
  try {
    const before = fs.lstatSync(target, { bigint: true });
    const physical = fs.realpathSync.native(target);
    if (!before.isFile() || before.isSymbolicLink() || !inside(hookRoot, physical)) {
      throw new Error('unsafe hook target');
    }
    const stable = readStableRegularFile(target, {
      minBytes: 1,
      maxBytes: 8 * 1024 * 1024,
      bigint: true,
    });
    const after = fs.lstatSync(target, { bigint: true });
    const physicalAfter = fs.realpathSync.native(target);
    if (!after.isFile() || after.isSymbolicLink()
        || physicalAfter !== physical
        || !sameBigIntFileIdentity(before, after)
        || !sameBigIntFileIdentity(stable.stat, after)) {
      throw new Error('hook target changed');
    }
    return {
      basename,
      canonicalPath: physical,
      dev: String(after.dev),
      ino: String(after.ino),
      size: String(after.size),
      mtimeNs: String(after.mtimeNs),
      ctimeNs: String(after.ctimeNs),
      sha256: crypto.createHash('sha256').update(stable.buffer).digest('hex'),
    };
  } catch (_error) {
    throw contractError('hook target integrity is unsafe');
  }
}

function capturedContractIsValid(contract) {
  if (!contract || typeof contract !== 'object' || !Object.isFrozen(contract)
      || typeof contract.pluginRoot !== 'string'
      || !contract.config || typeof contract.config !== 'object'
      || !Object.isFrozen(contract.config)
      || !Array.isArray(contract.hookIntegrity) || !Object.isFrozen(contract.hookIntegrity)
      || !contract.directoryIntegrity || typeof contract.directoryIntegrity !== 'object'
      || !Object.isFrozen(contract.directoryIntegrity)
      || !Array.isArray(contract.dispatchedChecks) || !Object.isFrozen(contract.dispatchedChecks)
      || contract.requiredHooks !== EVALUATOR_REQUIRED_HOOKS) {
    return false;
  }
  const directoryKeys = Object.keys(contract.directoryIntegrity);
  if (JSON.stringify(directoryKeys) !== JSON.stringify([
    'cacheParent',
    'pluginRoot',
    'hooksDirectory',
  ])) return false;
  for (const [key, expectedKeys] of [
    ['cacheParent', ['canonicalPath', 'dev', 'ino', 'mtimeNs', 'ctimeNs']],
    ['pluginRoot', ['canonicalPath', 'dev', 'ino']],
    ['hooksDirectory', ['canonicalPath', 'dev', 'ino', 'mtimeNs', 'ctimeNs']],
  ]) {
    const identity = contract.directoryIntegrity[key];
    if (!identity || typeof identity !== 'object' || !Object.isFrozen(identity)
        || JSON.stringify(Object.keys(identity)) !== JSON.stringify(expectedKeys)
        || Object.values(identity).some((value) => typeof value !== 'string' || !value)) {
      return false;
    }
  }
  if (contract.directoryIntegrity.pluginRoot.canonicalPath !== contract.pluginRoot) return false;
  let expectedBasenames;
  try { expectedBasenames = configuredHookBasenames(contract.config, contract.dispatchedChecks); }
  catch (_error) { return false; }
  if (JSON.stringify(contract.hookIntegrity.map((entry) => entry?.basename))
      !== JSON.stringify(expectedBasenames)) return false;
  return contract.hookIntegrity.every((entry) => (
    entry && typeof entry === 'object' && Object.isFrozen(entry)
    && JSON.stringify(Object.keys(entry)) === JSON.stringify([
      'basename',
      'canonicalPath',
      'dev',
      'ino',
      'size',
      'mtimeNs',
      'ctimeNs',
      'sha256',
    ])
    && Object.values(entry).every((value) => typeof value === 'string' && value)
    && /^[a-f0-9]{64}$/.test(entry.sha256)
  ));
}

function verifyCapturedHookContract(rootInput, contract) {
  if (!capturedContractIsValid(contract)) {
    throw contractError('captured contract is invalid');
  }
  const root = canonicalPluginRoot(rootInput);
  if (root !== contract.pluginRoot) throw contractError('plugin root identity changed');

  assertDirectoryIntegrity(root, contract.directoryIntegrity);
  const currentConfig = loadCanonicalHookConfig(root);
  assertDirectoryIntegrity(root, contract.directoryIntegrity);
  if (JSON.stringify(currentConfig) !== JSON.stringify(contract.config)) {
    throw contractError('hook configuration changed after capture');
  }
  const currentChecks = configDispatches(currentConfig) ? loadDispatchedChecks(root) : [];
  if (JSON.stringify(currentChecks) !== JSON.stringify(contract.dispatchedChecks)) {
    throw contractError('dispatcher check registry changed after capture');
  }
  const currentIntegrity = [];
  for (const { basename } of contract.hookIntegrity) {
    assertDirectoryIntegrity(root, contract.directoryIntegrity);
    currentIntegrity.push(captureHookIntegrity(root, basename));
    assertDirectoryIntegrity(root, contract.directoryIntegrity);
  }
  if (JSON.stringify(currentIntegrity) !== JSON.stringify(contract.hookIntegrity)) {
    throw contractError('hook target changed after capture');
  }
  return true;
}

function captureEvaluatorOwnedHookContract(rootInput) {
  const root = canonicalPluginRoot(rootInput);
  const directoryIntegrity = captureBoundDirectoryIntegrity(root);
  assertDirectoryIntegrity(root, directoryIntegrity);
  const config = loadCanonicalHookConfig(root);
  assertDirectoryIntegrity(root, directoryIntegrity);
  const dispatchedChecks = configDispatches(config) ? loadDispatchedChecks(root) : deepFreeze([]);
  assertDirectoryIntegrity(root, directoryIntegrity);
  const observedExpectedHooks = {
    PreToolUse: {
      Read: matchingHookBasenames(config, 'PreToolUse', 'Read', dispatchedChecks),
      Bash: matchingHookBasenames(config, 'PreToolUse', 'Bash', dispatchedChecks),
    },
    SessionStart: matchingHookBasenames(config, 'SessionStart'),
    Stop: matchingHookBasenames(config, 'Stop'),
  };
  const observedHookProcesses = {
    PreToolUse: {
      Read: matchingHookProcesses(config, 'PreToolUse', 'Read'),
      Bash: matchingHookProcesses(config, 'PreToolUse', 'Bash'),
    },
    SessionStart: matchingHookProcesses(config, 'SessionStart'),
    Stop: matchingHookProcesses(config, 'Stop'),
  };

  for (const toolName of ['Read', 'Bash']) {
    const observed = observedExpectedHooks.PreToolUse[toolName];
    requireUniqueHooks(observed, `PreToolUse ${toolName}`);
    requireOrderedHooks(
      observed,
      EVALUATOR_REQUIRED_HOOKS.PreToolUse[toolName],
      `PreToolUse ${toolName}`,
    );
  }
  for (const event of ['SessionStart', 'Stop']) {
    const observed = observedExpectedHooks[event];
    requireUniqueHooks(observed, event);
    requireOrderedHooks(observed, EVALUATOR_REQUIRED_HOOKS[event], event);
  }

  const hookIntegrity = [];
  for (const basename of configuredHookBasenames(config, dispatchedChecks)) {
    assertDirectoryIntegrity(root, directoryIntegrity);
    hookIntegrity.push(captureHookIntegrity(root, basename));
    assertDirectoryIntegrity(root, directoryIntegrity);
  }

  return deepFreeze({
    config,
    directoryIntegrity,
    dispatchedChecks,
    hookIntegrity,
    pluginRoot: root,
    requiredHooks: EVALUATOR_REQUIRED_HOOKS,
    observedExpectedHooks,
    observedHookProcesses,
  });
}

function writeFaultedFile(file, serialized) {
  let descriptor;
  try {
    const before = fs.lstatSync(file, { bigint: true });
    const flags = fs.constants.O_WRONLY | (fs.constants.O_NOFOLLOW || 0);
    descriptor = fs.openSync(file, flags);
    const opened = fs.fstatSync(descriptor, { bigint: true });
    if (!before.isFile() || before.isSymbolicLink() || !opened.isFile()
        || before.dev !== opened.dev || before.ino !== opened.ino) {
      throw new Error('unsafe hook configuration target');
    }
    fs.ftruncateSync(descriptor, 0);
    let offset = 0;
    while (offset < serialized.length) {
      const written = fs.writeSync(
        descriptor,
        serialized,
        offset,
        serialized.length - offset,
        offset,
      );
      if (written <= 0) throw new Error('short hook configuration write');
      offset += written;
    }
    fs.fchmodSync(descriptor, 0o600);
    fs.fsyncSync(descriptor);
  } catch (_error) {
    throw contractError('test hook configuration fault could not be written safely');
  } finally {
    if (descriptor !== undefined) {
      try { fs.closeSync(descriptor); } catch (_error) { /* already closed */ }
    }
  }
}

function injectCandidateHookContractFaultForTest(rootInput, fault) {
  if (process.env.ZENSU_UPGRADE_TEST_MODE !== '1'
      || typeof fault !== 'string' || !fault.startsWith('hook-contract-')) {
    return false;
  }
  const root = canonicalPluginRoot(rootInput);
  const config = loadCanonicalHookConfig(root);
  const groups = config.hooks;
  const checks = configDispatches(config)
    ? JSON.parse(JSON.stringify(loadDispatchedChecks(root)))
    : null;
  const directBasename = (event, hook) => (
    dispatcherFlag(event, hook) === null ? canonicalHookBasename(hook.command) : null
  );
  const remove = (event, basename) => {
    let removed = 0;
    for (const group of groups[event] || []) {
      group.hooks = group.hooks.filter((hook) => {
        const matches = directBasename(event, hook) === basename;
        if (matches) removed += 1;
        return !matches;
      });
    }
    if (checks) {
      const kept = checks.filter((check) => check.event !== event || check.script !== basename);
      removed += checks.length - kept.length;
      checks.splice(0, checks.length, ...kept);
    }
    if (removed === 0) throw contractError('hook-contract selftest target is missing');
  };
  const bashEntries = () => {
    if (checks) {
      return {
        entries: checks,
        basename: (check) => (check.event === 'PreToolUse' ? check.script : null),
      };
    }
    const group = (groups.PreToolUse || []).find(({ matcher, hooks }) => (
      String(matcher || '').split('|').includes('Bash')
      && hooks.some((hook) => directBasename('PreToolUse', hook) === 'pre-bash-zensu-gate.sh')
    ));
    if (!group) throw contractError('hook-contract selftest target is missing');
    return { entries: group.hooks, basename: (hook) => directBasename('PreToolUse', hook) };
  };

  if (fault === 'hook-contract-remove-read') {
    remove('PreToolUse', 'pre-reviewer-capability-gate.sh');
  } else if (fault === 'hook-contract-remove-bash') {
    remove('PreToolUse', 'pre-bash-zensu-gate.sh');
  } else if (fault === 'hook-contract-reorder-bash') {
    const { entries, basename } = bashEntries();
    const first = entries.findIndex((entry) => basename(entry) === 'pre-bash-zensu-gate.sh');
    const second = entries.findIndex((entry) => basename(entry) === 'pre-bash-source-write-gate.sh');
    if (first === -1 || second === -1) {
      throw contractError('hook-contract selftest target is missing');
    }
    [entries[first], entries[second]] = [entries[second], entries[first]];
  } else if (fault === 'hook-contract-duplicate-bash') {
    const { entries, basename } = bashEntries();
    const source = entries.find((entry) => basename(entry) === 'pre-bash-zensu-gate.sh');
    if (!source) throw contractError('hook-contract selftest target is missing');
    entries.push(checks ? { ...source, name: `${source.name}-duplicate` } : { ...source });
  } else if (fault === 'hook-contract-remove-session-start') {
    remove('SessionStart', 'session-start-session-control.sh');
  } else if (fault === 'hook-contract-remove-stop') {
    remove('Stop', 'stop-chain-enforcer.sh');
  } else {
    throw contractError('unknown evaluator-owned hook-contract selftest fault');
  }
  writeFaultedFile(
    path.join(root, 'hooks', 'hooks.json'),
    Buffer.from(`${JSON.stringify(config)}\n`, 'utf8'),
  );
  if (checks) {
    writeFaultedFile(
      path.join(root, 'hooks', DISPATCHER_REGISTRY),
      Buffer.from(`'use strict';\n\nmodule.exports = { DISPATCHED_CHECKS: ${JSON.stringify(checks)} };\n`, 'utf8'),
    );
  }
  return true;
}

module.exports = {
  EVALUATOR_REQUIRED_HOOKS,
  canonicalHookBasename,
  captureEvaluatorOwnedHookContract,
  injectCandidateHookContractFaultForTest,
  loadCanonicalHookConfig,
  loadDispatchedChecks,
  matchingHookBasenames,
  matchingHookProcesses,
  verifyCapturedHookContract,
};
