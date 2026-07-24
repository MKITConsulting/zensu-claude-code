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
  matchingHookBasenames,
  verifyCapturedHookContract,
} = require('../lib/upgrade-hook-contract.js');

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

function fixture(preToolCommand = command('pre-reviewer-capability-gate.sh')) {
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
          matcher: 'Bash',
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
    for (const [fault, expected] of cases) {
      const root = fixture();
      try {
        assert.equal(injectCandidateHookContractFaultForTest(root, fault), true);
        assert.throws(() => captureEvaluatorOwnedHookContract(root), expected);
      } finally {
        removeFixture(root);
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
