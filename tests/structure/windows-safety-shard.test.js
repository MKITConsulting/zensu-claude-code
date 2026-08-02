'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const {
  OFFLINE_COMMANDS,
  SafetyShardError,
  commandInventory,
  run,
  shardCommands,
} = require('../run-windows-safety-shard.js');

const root = path.resolve(__dirname, '..', '..');
const canary = JSON.parse(fs.readFileSync(
  path.join(root, 'tests', 'profiles', 'windows-legacy-canary.v1.json'),
  'utf8',
));
const runAllSource = fs.readFileSync(path.join(root, 'tests', 'run-all.sh'), 'utf8');

function key(command) {
  return JSON.stringify([command.runner, command.path, command.args]);
}

test('safety inventories exactly the former canary, full structure suite, and offline evals', () => {
  assert.deepEqual(
    commandInventory(root, 'canary').map(({ runner, path: relative, args }) => (
      [runner, relative, ...args].join(' ')
    )),
    canary.commands,
  );
  assert.deepEqual(
    commandInventory(root, 'structure').map((command) => command.path),
    fs.readdirSync(path.join(root, 'tests', 'structure'))
      .filter((name) => /^test-.*\.sh$/.test(name))
      .sort()
      .map((name) => `tests/structure/${name}`),
  );
  const variables = new Map(
    [...runAllSource.matchAll(/^([A-Z][A-Z0-9_]*)="\$ROOT\/([^"]+)"$/gm)]
      .map((match) => [match[1], match[2]]),
  );
  const canonicalOffline = [
    ...runAllSource.matchAll(
      /^run_required_suite[ \t]+"[^"]+"[ \t]+"\$([A-Z][A-Z0-9_]*)"[ \t]+(bash)[ \t]+"\$\1"(?:[ \t]+([^\r\n]+))?$/gm,
    ),
  ].map((match) => ({
    runner: match[2],
    path: variables.get(match[1]),
    args: match[3] ? match[3].trim().split(/\s+/) : [],
  }));
  assert.equal(canonicalOffline.length, 4);
  assert.deepEqual(commandInventory(root, 'offline'), canonicalOffline);
  assert.deepEqual(OFFLINE_COMMANDS, canonicalOffline);
});

test('each safety command delegates to one bounded supervised profile execution', async () => {
  const calls = [];
  await run('offline', 1, 4, {
    platform: 'win32',
    reportDirectory: path.join(root, 'tests', 'results'),
    output: { write() {} },
    async runProfileFn(options) {
      calls.push(options);
      return { exitCode: 0, report: { status: 'passed' } };
    },
  });
  assert.equal(calls.length, 1);
  const [call] = calls;
  assert.equal(call.platform, 'win32');
  assert.equal(call.installSignalHandlers, true);
  assert.equal(call.profileId, 'safety-offline-1-1');
  assert.deepEqual(call.manifest, {
    schemaVersion: 1,
    profiles: {
      'safety-offline-1-1': {
        platform: 'win32',
        profileTimeoutMs: 1800000,
        suites: [{
          id: 'safety-offline-1-1-command',
          runner: 'bash',
          path: 'evals/config-gate/run-eval.sh',
          args: ['--self-check'],
          timeoutMs: 1800000,
        }],
      },
    },
  });
});

test('a red supervised command fails closed before the next safety command starts', async () => {
  const calls = [];
  await assert.rejects(
    () => run('canary', 1, 4, {
      platform: 'win32',
      reportDirectory: path.join(root, 'tests', 'results'),
      output: { write() {} },
      async runProfileFn(options) {
        calls.push(options);
        return { exitCode: 1, report: { status: 'failed' } };
      },
    }),
    (error) => error instanceof SafetyShardError
      && /failed under supervised cleanup with status failed/.test(error.message),
  );
  assert.equal(calls.length, 1);
});

test('configured safety partitions cover every command exactly once', () => {
  for (const [kind, total] of [['canary', 4], ['structure', 8], ['offline', 4]]) {
    const inventory = commandInventory(root, kind);
    const partitioned = [];
    for (let shard = 1; shard <= total; shard += 1) {
      const commands = shardCommands(inventory, shard, total);
      assert.ok(commands.length > 0, `${kind} ${shard}/${total}`);
      partitioned.push(...commands);
    }
    assert.deepEqual(partitioned.map(key).sort(), inventory.map(key).sort(), kind);
    assert.equal(new Set(partitioned.map(key)).size, inventory.length, kind);
  }
});

test('safety shard selection rejects invalid or empty partitions', () => {
  const inventory = commandInventory(root, 'offline');
  assert.throws(() => shardCommands(inventory, 0, 4), /shard/);
  assert.throws(() => shardCommands(inventory, 1, 0), /total/);
  assert.throws(() => shardCommands(inventory, 5, 4), /shard/);
  assert.throws(() => shardCommands(inventory, 5, 8), /empty/);
  assert.throws(() => commandInventory(root, 'unknown'), /kind/);
});
