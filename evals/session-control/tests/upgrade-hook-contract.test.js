#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const {
  EVALUATOR_REQUIRED_HOOKS,
  canonicalHookBasename,
  captureEvaluatorOwnedHookContract,
  injectCandidateHookContractFaultForTest,
  loadCanonicalHookConfig,
  loadDispatchedChecks,
  matchingHookBasenames,
  matchingHookProcesses,
  verifyCapturedHookContract,
} = require('../lib/upgrade-hook-contract.js');

const PLUGIN_ROOT = path.resolve(__dirname, '..', '..', '..');
const DISPATCHER_ARGUMENT = '${CLAUDE_PLUGIN_ROOT}/hooks/lib/hook-dispatch-v1.js';
const DISPATCHED_CHECKS = [
  ['PreToolUse', 'reviewer-capability', '.*', 'pre-reviewer-capability-gate.sh', null, 'closed'],
  ['PreToolUse', 'zensu-cli-gate', 'Bash|PowerShell', 'pre-bash-zensu-gate.sh', 'checks/pre-bash-zensu-gate.sh', 'open'],
  ['PreToolUse', 'source-write-gate', 'Bash|PowerShell', 'pre-bash-source-write-gate.sh', 'checks/pre-bash-source-write-gate.sh', 'closed'],
  ['PreToolUse', 'secret-scan', 'Bash|PowerShell', 'pre-write-secret-scan.sh', 'checks/pre-write-secret-scan.sh', 'open'],
  ['PostToolUse', 'tool-audit', 'Write|Edit', 'post-tool-audit.sh', 'checks/post-tool-audit.sh', 'open'],
].map(([event, name, matcher, script, body, failure]) => ({ event, name, matcher, script, body, failure }));

const HOOK_NAMES = [
  'pre-bash-source-write-gate.sh',
  'pre-bash-zensu-gate.sh',
  'pre-reviewer-capability-gate.sh',
  'pre-write-secret-scan.sh',
  'post-tool-audit.sh',
  'session-start-banner.sh',
  'session-start-session-control.sh',
  'stop-chain-enforcer.sh',
  'user-prompt-policy.sh',
];

function command(name) {
  return `bash "\${CLAUDE_PLUGIN_ROOT}/hooks/${name}"`;
}

function hook(name) {
  return { type: 'command', command: command(name) };
}

function withInode(stat, exactInode) {
  const inode = typeof stat.ino === 'bigint' ? exactInode : Number(exactInode);
  return new Proxy(stat, {
    get(target, property) {
      if (property === 'ino') return inode;
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
}

function fixture(preToolCommand = command('pre-reviewer-capability-gate.sh'), bashMatcher = 'Bash') {
  const cacheParent = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-hook-contract-'));
  const root = path.join(cacheParent, '0.17.0');
  fs.mkdirSync(path.join(root, 'hooks'), { recursive: true, mode: 0o700 });
  for (const name of HOOK_NAMES) {
    fs.writeFileSync(path.join(root, 'hooks', name), '#!/bin/bash\nexit 0\n', { mode: 0o700 });
  }
  fs.writeFileSync(path.join(root, 'hooks', 'hooks.json'), JSON.stringify({
    hooks: {
      SessionStart: [{
        hooks: [
          hook('session-start-session-control.sh'),
          hook('session-start-banner.sh'),
        ],
      }],
      PreToolUse: [
        {
          matcher: '.*',
          hooks: [{
            type: 'command',
            command: preToolCommand,
          }],
        },
        {
          matcher: bashMatcher,
          hooks: [
            hook('pre-bash-zensu-gate.sh'),
            hook('pre-bash-source-write-gate.sh'),
            hook('pre-write-secret-scan.sh'),
          ],
        },
      ],
      UserPromptSubmit: [{
        matcher: '.*',
        hooks: [hook('user-prompt-policy.sh')],
      }],
      PostToolUse: [{
        matcher: 'Write|Edit',
        hooks: [hook('post-tool-audit.sh')],
      }],
      Stop: [{ hooks: [hook('stop-chain-enforcer.sh')] }],
    },
  }));
  return root;
}

function dispatcherHook(flag) {
  const entry = { type: 'command', command: 'node', args: [DISPATCHER_ARGUMENT, flag], timeout: 60 };
  if (flag === 'pre') entry.onFailure = 'block';
  return entry;
}

function registrySource(checks) {
  return `'use strict';\n\nmodule.exports = { DISPATCHED_CHECKS: ${JSON.stringify(checks)} };\n`;
}

function writeRegistry(root, source) {
  fs.writeFileSync(path.join(root, 'hooks', 'lib', 'hook-registration-v1.js'), source, { mode: 0o600 });
}

function dispatchedFixture(checks = DISPATCHED_CHECKS) {
  const root = fixture();
  fs.mkdirSync(path.join(root, 'hooks', 'lib'), { mode: 0o700 });
  fs.mkdirSync(path.join(root, 'hooks', 'checks'), { mode: 0o700 });
  fs.writeFileSync(path.join(root, 'hooks', 'lib', 'hook-dispatch-v1.js'), "'use strict';\n", { mode: 0o600 });
  for (const check of checks) {
    if (check.body !== null) {
      fs.writeFileSync(path.join(root, 'hooks', check.body), '#!/bin/bash\nexit 0\n', { mode: 0o700 });
    }
  }
  writeRegistry(root, registrySource(checks));
  rewriteConfig(root, (config) => {
    config.hooks.PreToolUse = [{ matcher: '.*', hooks: [dispatcherHook('pre')] }];
    config.hooks.PostToolUse = [{ matcher: '.*', hooks: [dispatcherHook('post')] }];
  });
  return root;
}

function replaceAndRestore(file) {
  const original = fs.readFileSync(file);
  fs.writeFileSync(file, '#!/bin/bash\nexit 61\n');
  fs.writeFileSync(file, original);
}

function removeFixture(root) {
  fs.rmSync(path.dirname(root), { recursive: true, force: true });
}

function rewriteConfig(root, mutate) {
  const file = path.join(root, 'hooks', 'hooks.json');
  const config = JSON.parse(fs.readFileSync(file, 'utf8'));
  mutate(config);
  fs.writeFileSync(file, JSON.stringify(config));
}

test('accepts only complete canonical lifecycle hook commands', () => {
  const root = fixture();
  try {
    const config = loadCanonicalHookConfig(root);
    assert.deepEqual(matchingHookBasenames(config, 'PreToolUse', 'Read'), [
      'pre-reviewer-capability-gate.sh',
    ]);
    assert.deepEqual(matchingHookBasenames(config, 'SessionStart'), [
      'session-start-session-control.sh',
      'session-start-banner.sh',
    ]);
    assert.deepEqual(matchingHookBasenames(config, 'Stop'), ['stop-chain-enforcer.sh']);
  } finally {
    removeFixture(root);
  }
});

test('rejects unsafe roots, unreadable configuration, and invalid shapes', () => {
  assert.throws(() => loadCanonicalHookConfig('/definitely/missing/zensu-plugin-root'), /plugin root is unsafe/);

  const malformed = fixture();
  const invalidShape = fixture();
  try {
    fs.writeFileSync(path.join(malformed, 'hooks', 'hooks.json'), '{');
    assert.throws(() => loadCanonicalHookConfig(malformed), /hook configuration is unsafe/);

    fs.writeFileSync(path.join(invalidShape, 'hooks', 'hooks.json'), '[]');
    assert.throws(() => loadCanonicalHookConfig(invalidShape), /hook configuration shape is invalid/);
  } finally {
    removeFixture(malformed);
    removeFixture(invalidShape);
  }
});

test('rejects invalid event, group, matcher, and hook entry contracts', () => {
  const cases = [
    ['event', (config) => { config.hooks['bad event'] = config.hooks.Stop; }, /hook event configuration is invalid/],
    ['group', (config) => { config.hooks.Stop = [{}]; }, /hook group configuration is invalid/],
    ['matcher control byte', (config) => { config.hooks.PreToolUse[0].matcher = 'Read\nBash'; }, /hook matcher is invalid/],
    ['matcher byte bound', (config) => { config.hooks.PreToolUse[0].matcher = 'R'.repeat(1025); }, /hook matcher is invalid/],
    ['matcher expression', (config) => { config.hooks.PreToolUse[0].matcher = '['; }, /hook matcher is invalid/],
    ['hook entry', (config) => { config.hooks.Stop[0].hooks[0].timeout = 0; }, /hook entry is invalid/],
    ['hook timeout type', (config) => { config.hooks.Stop[0].hooks[0].timeout = '1000'; }, /hook entry is invalid/],
    ['hook extension key', (config) => { config.hooks.Stop[0].hooks[0].env = {}; }, /hook entry is invalid/],
    ['undocumented hook args', (config) => {
      Reflect.set(config.hooks.Stop[0].hooks[0], 'args', ['forged']);
    }, /hook entry is invalid/],
  ];

  for (const [, mutate, expected] of cases) {
    const root = fixture();
    try {
      rewriteConfig(root, mutate);
      assert.throws(() => loadCanonicalHookConfig(root), expected);
    } finally {
      removeFixture(root);
    }
  }
});

test('rejects invalid direct commands and unsafe existing hook targets', () => {
  assert.throws(() => canonicalHookBasename(null), /hook command is invalid/);

  const root = fixture();
  try {
    const target = path.join(root, 'hooks', 'pre-reviewer-capability-gate.sh');
    fs.rmSync(target);
    fs.mkdirSync(target);
    assert.throws(() => loadCanonicalHookConfig(root), /hook target is unsafe/);
  } finally {
    removeFixture(root);
  }
});

test('matching ignores non-matching and absent hook groups', () => {
  const root = fixture();
  try {
    const config = loadCanonicalHookConfig(root);
    assert.deepEqual(matchingHookBasenames(config, 'PreToolUse', 'Bash'), [
      'pre-reviewer-capability-gate.sh',
      'pre-bash-zensu-gate.sh',
      'pre-bash-source-write-gate.sh',
      'pre-write-secret-scan.sh',
    ]);
    assert.deepEqual(matchingHookBasenames(config, 'Notification'), []);
  } finally {
    removeFixture(root);
  }
});

for (const [name, command] of [
  [
    'shell suffix',
    'bash "${CLAUDE_PLUGIN_ROOT}/hooks/pre-reviewer-capability-gate.sh"; printf unsafe',
  ],
  [
    'non-Bash side command',
    'node "${CLAUDE_PLUGIN_ROOT}/hooks/pre-reviewer-capability-gate.sh"',
  ],
]) {
  test(`rejects a lifecycle hook with ${name}`, () => {
    const root = fixture(command);
    try {
      assert.throws(() => loadCanonicalHookConfig(root), /canonical plugin hook command/);
    } finally {
      removeFixture(root);
    }
  });
}

test('rejects a canonical-looking command whose hook file is missing', () => {
  const root = fixture('bash "${CLAUDE_PLUGIN_ROOT}/hooks/missing.sh"');
  try {
    assert.throws(() => loadCanonicalHookConfig(root), /hook target is unsafe/);
  } finally {
    removeFixture(root);
  }
});

test('rejects a canonical hook target replaced by a symlink', (context) => {
  const root = fixture();
  const external = path.join(root, 'external-hook.sh');
  const target = path.join(root, 'hooks', 'pre-reviewer-capability-gate.sh');
  try {
    fs.writeFileSync(external, '#!/bin/bash\nexit 0\n', { mode: 0o700 });
    fs.rmSync(target);
    try {
      fs.symlinkSync(external, target);
    } catch (error) {
      if (error?.code === 'EPERM' || error?.code === 'EACCES') {
        context.skip('host does not permit symlink fixtures');
        return;
      }
      throw error;
    }
    assert.throws(() => loadCanonicalHookConfig(root), /hook target is unsafe/);
  } finally {
    removeFixture(root);
  }
});

test('captures evaluator-owned minima and all observed expectations exactly once', () => {
  const root = fixture();
  try {
    const contract = captureEvaluatorOwnedHookContract(root);
    assert.deepEqual(contract.requiredHooks, EVALUATOR_REQUIRED_HOOKS);
    assert.deepEqual(contract.observedExpectedHooks, {
      PreToolUse: {
        Read: ['pre-reviewer-capability-gate.sh'],
        Bash: [
          'pre-reviewer-capability-gate.sh',
          'pre-bash-zensu-gate.sh',
          'pre-bash-source-write-gate.sh',
          'pre-write-secret-scan.sh',
        ],
      },
      SessionStart: [
        'session-start-session-control.sh',
        'session-start-banner.sh',
      ],
      Stop: ['stop-chain-enforcer.sh'],
    });
  } finally {
    removeFixture(root);
  }
});

test('returns a deeply immutable configuration and expectation snapshot', () => {
  const root = fixture();
  try {
    const contract = captureEvaluatorOwnedHookContract(root);
    assert.equal(Object.isFrozen(contract), true);
    assert.equal(Object.isFrozen(contract.config.hooks.PreToolUse), true);
    assert.equal(Object.isFrozen(contract.hookIntegrity), true);
    assert.equal(Object.isFrozen(contract.hookIntegrity[0]), true);
    assert.equal(Object.isFrozen(contract.observedExpectedHooks.PreToolUse.Bash), true);
    assert.equal(Object.isFrozen(EVALUATOR_REQUIRED_HOOKS.PreToolUse.Bash), true);
    assert.throws(
      () => contract.observedExpectedHooks.PreToolUse.Bash.push('forged.sh'),
      TypeError,
    );
    assert.throws(
      () => { contract.config.hooks.Stop[0].hooks[0].command = command('session-start-banner.sh'); },
      TypeError,
    );
  } finally {
    removeFixture(root);
  }
});

test('attests every observed hook identity and rejects replace-and-restore tampering', () => {
  const root = fixture();
  try {
    const contract = captureEvaluatorOwnedHookContract(root);
    assert.equal(verifyCapturedHookContract(root, contract), true);
    assert.deepEqual(
      contract.hookIntegrity.map(({ basename }) => basename),
      [...new Set([...HOOK_NAMES, 'hooks.json'])].sort(),
    );

    const target = path.join(root, 'hooks', 'pre-reviewer-capability-gate.sh');
    const original = fs.readFileSync(target);
    fs.writeFileSync(target, '#!/bin/bash\nexit 23\n');
    fs.writeFileSync(target, original);
    assert.throws(
      () => verifyCapturedHookContract(root, contract),
      /hook target changed after capture/,
    );
  } finally {
    removeFixture(root);
  }
});

test('attests exact hook identities beyond Number inode precision', (context) => {
  const root = fixture();
  const hooksRoot = `${path.join(fs.realpathSync.native(root), 'hooks')}${path.sep}`;
  const exactInode = 9007199254740993n;
  const originalLstatSync = fs.lstatSync.bind(fs);
  const originalFstatSync = fs.fstatSync.bind(fs);
  context.mock.method(fs, 'lstatSync', (target, options) => {
    const stat = originalLstatSync(target, options);
    return stat.isFile() && String(target).startsWith(hooksRoot)
      ? withInode(stat, exactInode)
      : stat;
  });
  context.mock.method(fs, 'fstatSync', (descriptor, options) => {
    const stat = originalFstatSync(descriptor, options);
    return stat.isFile() ? withInode(stat, exactInode) : stat;
  });
  try {
    const contract = captureEvaluatorOwnedHookContract(root);
    assert.equal(verifyCapturedHookContract(root, contract), true);
    assert.equal(
      contract.hookIntegrity.every(({ ino }) => ino === String(exactInode)),
      true,
    );
  } finally {
    removeFixture(root);
  }
});

test('attests hook files referenced only by UserPromptSubmit and PostToolUse', () => {
  for (const basename of ['user-prompt-policy.sh', 'post-tool-audit.sh']) {
    const root = fixture();
    try {
      const contract = captureEvaluatorOwnedHookContract(root);
      const target = path.join(root, 'hooks', basename);
      const original = fs.readFileSync(target);
      fs.writeFileSync(target, '#!/bin/bash\nexit 41\n');
      fs.writeFileSync(target, original);
      assert.throws(
        () => verifyCapturedHookContract(root, contract),
        /hook target changed after capture/,
      );
    } finally {
      removeFixture(root);
    }
  }
});

test('binds cache parent, plugin root, and hooks directory identities immutably', () => {
  const root = fixture();
  try {
    const contract = captureEvaluatorOwnedHookContract(root);
    assert.deepEqual(
      Object.keys(contract.directoryIntegrity),
      ['cacheParent', 'pluginRoot', 'hooksDirectory'],
    );
    for (const key of ['cacheParent', 'hooksDirectory']) {
      assert.equal(Object.isFrozen(contract.directoryIntegrity[key]), true);
      for (const field of ['canonicalPath', 'dev', 'ino', 'mtimeNs', 'ctimeNs']) {
        assert.equal(typeof contract.directoryIntegrity[key][field], 'string');
        assert.notEqual(contract.directoryIntegrity[key][field], '');
      }
    }
    assert.deepEqual(
      Object.keys(contract.directoryIntegrity.pluginRoot),
      ['canonicalPath', 'dev', 'ino'],
    );
    assert.equal(Object.isFrozen(contract.directoryIntegrity.pluginRoot), true);
  } finally {
    removeFixture(root);
  }
});

test('permits legitimate plugin-root .in_use churn without weakening directory bindings', () => {
  const root = fixture();
  try {
    const contract = captureEvaluatorOwnedHookContract(root);
    const inUse = path.join(root, '.in_use');
    fs.writeFileSync(inUse, 'candidate\n');
    fs.rmSync(inUse);
    assert.equal(verifyCapturedHookContract(root, contract), true);
  } finally {
    removeFixture(root);
  }
});

test('rejects plugin-root rename, replacement, and restore through the cache-parent binding', () => {
  const root = fixture();
  const displaced = `${root}.original`;
  try {
    const contract = captureEvaluatorOwnedHookContract(root);
    fs.renameSync(root, displaced);
    fs.mkdirSync(root, { mode: 0o700 });
    fs.rmSync(root, { recursive: true, force: true });
    fs.renameSync(displaced, root);
    assert.throws(
      () => verifyCapturedHookContract(root, contract),
      /directory identity changed after capture/,
    );
  } finally {
    if (fs.existsSync(displaced) && !fs.existsSync(root)) fs.renameSync(displaced, root);
    removeFixture(root);
  }
});

test('rejects hooks-directory rename, replacement, and restore', () => {
  const root = fixture();
  const hooksDirectory = path.join(root, 'hooks');
  const displaced = path.join(root, 'hooks.original');
  try {
    const contract = captureEvaluatorOwnedHookContract(root);
    fs.renameSync(hooksDirectory, displaced);
    fs.mkdirSync(hooksDirectory, { mode: 0o700 });
    fs.rmSync(hooksDirectory, { recursive: true, force: true });
    fs.renameSync(displaced, hooksDirectory);
    assert.throws(
      () => verifyCapturedHookContract(root, contract),
      /directory identity changed after capture/,
    );
  } finally {
    if (fs.existsSync(displaced) && !fs.existsSync(hooksDirectory)) {
      fs.renameSync(displaced, hooksDirectory);
    }
    removeFixture(root);
  }
});

test('rejects replace-and-restore hook configuration tampering and an untrusted contract', () => {
  const root = fixture();
  try {
    const contract = captureEvaluatorOwnedHookContract(root);
    const configFile = path.join(root, 'hooks', 'hooks.json');
    const original = fs.readFileSync(configFile);
    rewriteConfig(root, (config) => {
      config.hooks.SessionStart[0].hooks.push(hook('session-start-banner.sh'));
    });
    fs.writeFileSync(configFile, original);
    assert.throws(
      () => verifyCapturedHookContract(root, contract),
      /hook target changed after capture/,
    );
    assert.throws(
      () => verifyCapturedHookContract(root, { ...contract }),
      /captured contract is invalid/,
    );
  } finally {
    removeFixture(root);
  }
});

test('rejects removal of every evaluator-owned required hook', () => {
  const cases = [
    ['Read', (config) => { config.hooks.PreToolUse.shift(); }],
    ['Bash', (config) => { config.hooks.PreToolUse[1].hooks.shift(); }],
    ['SessionStart', (config) => { config.hooks.SessionStart[0].hooks.shift(); }],
    ['Stop', (config) => { config.hooks.Stop[0].hooks = [hook('session-start-banner.sh')]; }],
  ];
  for (const [label, mutate] of cases) {
    const root = fixture();
    try {
      rewriteConfig(root, mutate);
      assert.throws(
        () => captureEvaluatorOwnedHookContract(root),
        new RegExp(`${label} is missing a required hook`),
      );
    } finally {
      removeFixture(root);
    }
  }
});

test('rejects matcher tampering that removes the reviewer gate from Read', () => {
  const root = fixture();
  try {
    rewriteConfig(root, (config) => {
      config.hooks.PreToolUse[0].matcher = '^Bash$';
    });
    assert.throws(
      () => captureEvaluatorOwnedHookContract(root),
      /PreToolUse Read is missing a required hook/,
    );
  } finally {
    removeFixture(root);
  }
});

test('rejects duplicate required and extra hooks in every observed expectation set', () => {
  const cases = [
    ['PreToolUse Read', (config) => {
      config.hooks.PreToolUse.unshift({
        matcher: 'Read',
        hooks: [hook('pre-reviewer-capability-gate.sh')],
      });
    }],
    ['PreToolUse Bash', (config) => {
      config.hooks.PreToolUse[1].hooks.push(hook('pre-bash-zensu-gate.sh'));
    }],
    ['SessionStart', (config) => {
      config.hooks.SessionStart[0].hooks.push(hook('session-start-banner.sh'));
    }],
    ['Stop', (config) => {
      config.hooks.Stop[0].hooks.push(hook('stop-chain-enforcer.sh'));
    }],
  ];
  for (const [label, mutate] of cases) {
    const root = fixture();
    try {
      rewriteConfig(root, mutate);
      assert.throws(
        () => captureEvaluatorOwnedHookContract(root),
        new RegExp(`${label} contains a duplicate hook`),
      );
    } finally {
      removeFixture(root);
    }
  }
});

test('rejects reordered Bash requirements', () => {
  const root = fixture();
  try {
    rewriteConfig(root, (config) => {
      const bashHooks = config.hooks.PreToolUse[1].hooks;
      [bashHooks[0], bashHooks[1]] = [bashHooks[1], bashHooks[0]];
    });
    assert.throws(
      () => captureEvaluatorOwnedHookContract(root),
      /PreToolUse Bash required hook order is invalid/,
    );
  } finally {
    removeFixture(root);
  }
});

test('allows unique extras while preserving the evaluator-owned required order', () => {
  const root = fixture();
  try {
    rewriteConfig(root, (config) => {
      config.hooks.PreToolUse.splice(1, 0, {
        matcher: 'Read|Bash',
        hooks: [hook('session-start-banner.sh')],
      });
      config.hooks.Stop[0].hooks.unshift(hook('session-start-banner.sh'));
    });
    const contract = captureEvaluatorOwnedHookContract(root);
    assert.deepEqual(contract.observedExpectedHooks.PreToolUse.Read, [
      'pre-reviewer-capability-gate.sh',
      'session-start-banner.sh',
    ]);
    assert.deepEqual(contract.observedExpectedHooks.PreToolUse.Bash, [
      'pre-reviewer-capability-gate.sh',
      'session-start-banner.sh',
      'pre-bash-zensu-gate.sh',
      'pre-bash-source-write-gate.sh',
      'pre-write-secret-scan.sh',
    ]);
    assert.deepEqual(contract.observedExpectedHooks.Stop, [
      'session-start-banner.sh',
      'stop-chain-enforcer.sh',
    ]);
  } finally {
    removeFixture(root);
  }
});

test('applies every evaluator-owned hook-contract selftest fault only in test mode', () => {
  const previous = process.env.ZENSU_UPGRADE_TEST_MODE;
  const cases = [
    ['hook-contract-remove-read', /hook group configuration is invalid/],
    ['hook-contract-remove-bash', /PreToolUse Bash is missing a required hook/],
    ['hook-contract-reorder-bash', /PreToolUse Bash required hook order is invalid/],
    ['hook-contract-duplicate-bash', /PreToolUse Bash contains a duplicate hook/],
    ['hook-contract-remove-session-start', /SessionStart is missing a required hook/],
    ['hook-contract-remove-stop', /hook group configuration is invalid/],
  ];
  try {
    process.env.ZENSU_UPGRADE_TEST_MODE = '1';
    for (const bashMatcher of ['Bash', 'Bash|PowerShell']) {
      for (const [fault, expected] of cases) {
        const root = fixture(undefined, bashMatcher);
        try {
          assert.equal(injectCandidateHookContractFaultForTest(root, fault), true, `${fault} on ${bashMatcher}`);
          assert.throws(() => captureEvaluatorOwnedHookContract(root), expected, `${fault} on ${bashMatcher}`);
        } finally {
          removeFixture(root);
        }
      }
    }

    const dispatchedCases = [
      ['hook-contract-remove-read', /PreToolUse Read is missing a required hook/],
      ['hook-contract-remove-bash', /PreToolUse Bash is missing a required hook/],
      ['hook-contract-reorder-bash', /PreToolUse Bash required hook order is invalid/],
      ['hook-contract-duplicate-bash', /PreToolUse Bash contains a duplicate hook/],
      ['hook-contract-remove-session-start', /SessionStart is missing a required hook/],
      ['hook-contract-remove-stop', /hook group configuration is invalid/],
    ];
    for (const [fault, expected] of dispatchedCases) {
      const root = dispatchedFixture();
      try {
        assert.equal(injectCandidateHookContractFaultForTest(root, fault), true, `${fault} on the dispatcher`);
        assert.throws(() => captureEvaluatorOwnedHookContract(root), expected, `${fault} on the dispatcher`);
      } finally {
        removeFixture(root);
      }
    }

    const withoutGate = DISPATCHED_CHECKS.filter((check) => check.name !== 'zensu-cli-gate');
    for (const fault of ['hook-contract-remove-bash', 'hook-contract-reorder-bash', 'hook-contract-duplicate-bash']) {
      const dispatched = dispatchedFixture(withoutGate);
      const direct = fixture();
      try {
        rewriteConfig(direct, (config) => { config.hooks.PreToolUse.splice(1, 1); });
        for (const root of [dispatched, direct]) {
          assert.throws(
            () => injectCandidateHookContractFaultForTest(root, fault),
            /hook-contract selftest target is missing/,
            fault,
          );
        }
      } finally {
        removeFixture(dispatched);
        removeFixture(direct);
      }
    }

    const root = fixture();
    try {
      assert.throws(
        () => injectCandidateHookContractFaultForTest(root, 'hook-contract-unknown'),
        /unknown evaluator-owned hook-contract selftest fault/,
      );
    } finally {
      removeFixture(root);
    }
  } finally {
    if (previous === undefined) delete process.env.ZENSU_UPGRADE_TEST_MODE;
    else process.env.ZENSU_UPGRADE_TEST_MODE = previous;
  }
});

test('does not mutate hook configuration when hook-contract test mode is disabled', () => {
  const root = fixture();
  const previous = process.env.ZENSU_UPGRADE_TEST_MODE;
  try {
    delete process.env.ZENSU_UPGRADE_TEST_MODE;
    const before = fs.readFileSync(path.join(root, 'hooks', 'hooks.json'));
    assert.equal(
      injectCandidateHookContractFaultForTest(root, 'hook-contract-remove-read'),
      false,
    );
    assert.deepEqual(fs.readFileSync(path.join(root, 'hooks', 'hooks.json')), before);
  } finally {
    if (previous === undefined) delete process.env.ZENSU_UPGRADE_TEST_MODE;
    else process.env.ZENSU_UPGRADE_TEST_MODE = previous;
    removeFixture(root);
  }
});

test('captures a dispatched configuration through the check registry the evaluator reads itself', () => {
  const root = dispatchedFixture();
  try {
    const contract = captureEvaluatorOwnedHookContract(root);
    assert.deepEqual(contract.dispatchedChecks, DISPATCHED_CHECKS);
    assert.equal(Object.isFrozen(contract.dispatchedChecks[0]), true);
    assert.deepEqual(contract.observedExpectedHooks.PreToolUse, {
      Read: ['pre-reviewer-capability-gate.sh'],
      Bash: [
        'pre-reviewer-capability-gate.sh',
        'pre-bash-zensu-gate.sh',
        'pre-bash-source-write-gate.sh',
        'pre-write-secret-scan.sh',
      ],
    });
    assert.deepEqual(contract.observedHookProcesses, {
      PreToolUse: { Read: ['hook-dispatch-v1.js:pre'], Bash: ['hook-dispatch-v1.js:pre'] },
      SessionStart: ['session-start-session-control.sh', 'session-start-banner.sh'],
      Stop: ['stop-chain-enforcer.sh'],
    });
    assert.deepEqual(matchingHookProcesses(contract.config, 'PostToolUse', 'Read'), ['hook-dispatch-v1.js:post']);
    assert.deepEqual(matchingHookBasenames(contract.config, 'PostToolUse', 'Edit', contract.dispatchedChecks), [
      'post-tool-audit.sh',
    ]);
    assert.deepEqual(matchingHookBasenames(contract.config, 'PostToolUse', 'Read', contract.dispatchedChecks), []);
    assert.deepEqual(contract.hookIntegrity.map(({ basename }) => basename), [
      ...HOOK_NAMES,
      'checks/post-tool-audit.sh',
      'checks/pre-bash-source-write-gate.sh',
      'checks/pre-bash-zensu-gate.sh',
      'checks/pre-write-secret-scan.sh',
      'hooks.json',
      'lib/hook-dispatch-v1.js',
      'lib/hook-registration-v1.js',
    ].sort());
    assert.equal(verifyCapturedHookContract(root, contract), true);
    assert.throws(
      () => verifyCapturedHookContract(root, Object.freeze({
        ...contract,
        dispatchedChecks: [...contract.dispatchedChecks],
      })),
      /captured contract is invalid/,
    );
  } finally {
    removeFixture(root);
  }
});

test('rejects a changed check registry and a replaced dispatcher, registry or check body after capture', () => {
  const cases = [
    ['registry content', (root) => {
      writeRegistry(root, registrySource(DISPATCHED_CHECKS.map(
        (check) => (check.name === 'zensu-cli-gate' ? { ...check, matcher: 'Read' } : check),
      )));
    }, /dispatcher check registry changed after capture/],
    ['registry file', (root) => {
      replaceAndRestore(path.join(root, 'hooks', 'lib', 'hook-registration-v1.js'));
    }, /hook target changed after capture/],
    ['dispatcher file', (root) => {
      replaceAndRestore(path.join(root, 'hooks', 'lib', 'hook-dispatch-v1.js'));
    }, /hook target changed after capture/],
    ['check body', (root) => {
      replaceAndRestore(path.join(root, 'hooks', 'checks', 'pre-bash-zensu-gate.sh'));
    }, /hook target changed after capture/],
  ];
  for (const [label, tamper, expected] of cases) {
    const root = dispatchedFixture();
    try {
      const contract = captureEvaluatorOwnedHookContract(root);
      tamper(root);
      assert.throws(() => verifyCapturedHookContract(root, contract), expected, label);
    } finally {
      removeFixture(root);
    }
  }
});

test('refuses a check registry it cannot read without running candidate code, or whose entries are malformed', () => {
  const valid = DISPATCHED_CHECKS[1];
  const { failure: _failure, ...withoutFailure } = valid;
  const unsafe = [
    ['missing', (root) => { fs.rmSync(path.join(root, 'hooks', 'lib', 'hook-registration-v1.js')); }],
    ['require', (root) => { writeRegistry(root, "'use strict';\nrequire('node:fs');\n"); }],
    ['syntax', (root) => { writeRegistry(root, 'module.exports = {'); }],
    ['absent export', (root) => { writeRegistry(root, 'module.exports = {};\n'); }],
  ];
  for (const [label, mutate] of unsafe) {
    const root = dispatchedFixture();
    try {
      mutate(root);
      assert.throws(() => loadDispatchedChecks(root), /dispatcher check registry is unsafe/, label);
    } finally {
      removeFixture(root);
    }
  }
  const invalid = [
    ['not an array', {}],
    ['empty', []],
    ['null entry', [null]],
    ['array entry', [[]]],
    ['extra key', [{ ...valid, extra: true }]],
    ['missing key', [withoutFailure]],
    ['key order', [{ name: valid.name, ...valid }]],
    ['event', [{ ...valid, event: 'Stop' }]],
    ['name', [{ ...valid, name: 'Zensu Gate' }]],
    ['duplicate', [valid, { ...valid }]],
    ['empty matcher', [{ ...valid, matcher: '' }]],
    ['matcher type', [{ ...valid, matcher: 1 }]],
    ['matcher expression', [{ ...valid, matcher: '[' }]],
    ['script', [{ ...valid, script: '../escape.sh' }]],
    ['body', [{ ...valid, body: 'lib/escape.sh' }]],
    ['failure', [{ ...valid, failure: 'maybe' }]],
  ];
  for (const [label, checks] of invalid) {
    const root = dispatchedFixture();
    try {
      writeRegistry(root, registrySource(checks));
      assert.throws(() => loadDispatchedChecks(root), /dispatcher check registry is invalid/, label);
    } finally {
      removeFixture(root);
    }
  }
});

test('accepts the dispatcher only in its canonical exec form on the tool events', () => {
  const pre = (config) => config.hooks.PreToolUse[0].hooks[0];
  const cases = [
    ['argument count', (config) => { pre(config).args.push('extra'); }, /hook command is not the canonical dispatcher/],
    ['module path', (config) => {
      pre(config).args[0] = '${CLAUDE_PLUGIN_ROOT}/hooks/lib/other.js';
    }, /hook command is not the canonical dispatcher/],
    ['event flag', (config) => { pre(config).args[1] = 'post'; }, /hook command is not the canonical dispatcher/],
    ['argument type', (config) => { pre(config).args = 'pre'; }, /hook command is not the canonical dispatcher/],
    ['lifecycle event', (config) => {
      config.hooks.Stop[0].hooks.push(dispatcherHook('pre'));
    }, /hook command is not the canonical dispatcher/],
    ['group matcher', (config) => { config.hooks.PreToolUse[0].matcher = 'Bash'; }, /hook entry is invalid/],
    ['missing block', (config) => { delete pre(config).onFailure; }, /hook entry is invalid/],
    ['post block', (config) => { config.hooks.PostToolUse[0].hooks[0].onFailure = 'block'; }, /hook entry is invalid/],
    ['extension key', (config) => { pre(config).env = {}; }, /hook entry is invalid/],
  ];
  for (const [label, mutate, expected] of cases) {
    const root = dispatchedFixture();
    try {
      rewriteConfig(root, mutate);
      assert.throws(() => loadCanonicalHookConfig(root), expected, label);
    } finally {
      removeFixture(root);
    }
  }
  const root = dispatchedFixture();
  try {
    fs.rmSync(path.join(root, 'hooks', 'lib', 'hook-dispatch-v1.js'));
    assert.throws(() => loadCanonicalHookConfig(root), /hook target is unsafe/);
  } finally {
    removeFixture(root);
  }
});

test('captures the hooks directory this repository ships, its registry read as data', () => {
  const root = fixture();
  try {
    fs.rmSync(path.join(root, 'hooks'), { recursive: true, force: true });
    fs.cpSync(path.join(PLUGIN_ROOT, 'hooks'), path.join(root, 'hooks'), { recursive: true });
    const shipped = require(path.join(PLUGIN_ROOT, 'hooks', 'lib', 'hook-registration-v1.js')).DISPATCHED_CHECKS;
    assert.deepEqual(loadDispatchedChecks(root), JSON.parse(JSON.stringify(shipped)));
    const contract = captureEvaluatorOwnedHookContract(root);
    assert.deepEqual(contract.observedHookProcesses.PreToolUse, {
      Read: ['hook-dispatch-v1.js:pre'],
      Bash: ['hook-dispatch-v1.js:pre'],
    });
    assert.deepEqual(
      contract.observedExpectedHooks.PreToolUse.Bash.slice(0, 4),
      EVALUATOR_REQUIRED_HOOKS.PreToolUse.Bash,
    );
    const shippedHooks = (event, tool) => matchingHookBasenames(contract.config, event, tool, contract.dispatchedChecks);
    assert.deepEqual(shippedHooks('PreToolUse', 'Edit'), [
      'pre-reviewer-capability-gate.sh',
      'pre-work-order-gate.sh',
      'pre-write-plugin-data-guard.sh',
      'pre-edit-tdd-reminder.sh',
      'pre-write-secret-scan.sh',
    ]);
    assert.deepEqual(shippedHooks('PreToolUse', 'NotebookEdit'), [
      'pre-reviewer-capability-gate.sh',
      'pre-work-order-gate.sh',
      'pre-write-plugin-data-guard.sh',
      'pre-write-secret-scan.sh',
    ]);
    assert.deepEqual(shippedHooks('PreToolUse', 'Agent'), [
      'pre-reviewer-capability-gate.sh',
      'pre-work-order-gate.sh',
      'pre-agent-reviewer-allow.sh',
    ]);
    assert.deepEqual(matchingHookProcesses(contract.config, 'PreToolUse', 'Edit'), ['hook-dispatch-v1.js:pre']);
    assert.deepEqual(matchingHookProcesses(contract.config, 'PostToolUse', 'Edit'), ['hook-dispatch-v1.js:post']);
    assert.equal(verifyCapturedHookContract(root, contract), true);
  } finally {
    removeFixture(root);
  }
});
