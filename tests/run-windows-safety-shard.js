#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { runProfile } = require('./run-profile.js');

const ROOT = fs.realpathSync.native(path.resolve(__dirname, '..'));
const CANARY_FILE = path.join(ROOT, 'tests', 'profiles', 'windows-legacy-canary.v1.json');
const LOCAL_ONLY_FILE = path.join(ROOT, 'tests', 'profiles', 'promptfoo-local-only.v1.json');
const COMMAND_TIMEOUT_MS = 60 * 60 * 1000;
function localOnlyInventory() {
  const value = JSON.parse(fs.readFileSync(LOCAL_ONLY_FILE, 'utf8'));
  if (!value || value.schemaVersion !== 1
      || !Array.isArray(value.ciStructureTests)
      || !Array.isArray(value.localStructureTests)
      || !Array.isArray(value.ciOfflineSuites)
      || [...value.ciStructureTests, ...value.localStructureTests].some(
        (entry) => typeof entry !== 'string' || entry.length === 0,
      )) {
    throw new Error('Promptfoo local-only inventory is invalid');
  }
  const actualStructure = fs.readdirSync(path.join(ROOT, 'tests', 'structure'))
    .filter((name) => /^test-.*\.sh$/.test(name))
    .sort();
  const uniqueSorted = (entries) => [...new Set(entries)].sort();
  const classified = [...value.ciStructureTests, ...value.localStructureTests];
  if (JSON.stringify(uniqueSorted(classified)) !== JSON.stringify(actualStructure)
      || classified.length !== new Set(classified).size
      || value.ciOfflineSuites.some((suite) => !suite || typeof suite.label !== 'string'
        || typeof suite.path !== 'string' || !Array.isArray(suite.args)
        || !Array.isArray(suite.ciArgs)
        || typeof suite.needsNodeDeps !== 'boolean'
        || typeof suite.windowsSafety !== 'boolean'
        || !fs.existsSync(path.join(ROOT, suite.path)))) {
    throw new Error('suite classification inventory is incomplete');
  }
  return Object.freeze({
    ciStructureTests: Object.freeze([...value.ciStructureTests]),
    localStructureTests: Object.freeze([...value.localStructureTests]),
    ciOfflineSuites: Object.freeze(value.ciOfflineSuites.map((suite) => Object.freeze({
      ...suite,
      args: Object.freeze([...suite.args]),
      ciArgs: Object.freeze([...suite.ciArgs]),
    }))),
  });
}

const LOCAL_ONLY_INVENTORY = localOnlyInventory();
const CI_STRUCTURE_TESTS = new Set(LOCAL_ONLY_INVENTORY.ciStructureTests);
const LOCAL_ONLY_STRUCTURE_TESTS = new Set(LOCAL_ONLY_INVENTORY.localStructureTests);
const OFFLINE_COMMANDS = Object.freeze(
  LOCAL_ONLY_INVENTORY.ciOfflineSuites
    .filter((suite) => suite.windowsSafety)
    .map((suite) => Object.freeze({
      runner: 'bash',
      path: suite.path,
      args: Object.freeze([...suite.ciArgs]),
    })),
);

class SafetyShardError extends Error {}

function command(runner, relative, args = []) {
  if (runner !== 'bash'
      || typeof relative !== 'string'
      || !/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(relative)
      || path.posix.normalize(relative) !== relative
      || relative.startsWith('../')
      || !Array.isArray(args)
      || args.some((argument) => typeof argument !== 'string' || /[\u0000\r\n]/.test(argument))) {
    throw new SafetyShardError('safety command is invalid');
  }
  const boundary = path.relative(ROOT, fs.realpathSync.native(path.join(ROOT, relative)));
  if (boundary === '..' || boundary.startsWith(`..${path.sep}`) || path.isAbsolute(boundary)) {
    throw new SafetyShardError(`safety command escapes the repository: ${relative}`);
  }
  return Object.freeze({ runner, path: relative, args: Object.freeze([...args]) });
}

function canaryCommands() {
  const value = JSON.parse(fs.readFileSync(CANARY_FILE, 'utf8'));
  if (!value || value.schemaVersion !== 1 || !Array.isArray(value.commands)) {
    throw new SafetyShardError('legacy canary inventory is invalid');
  }
  return value.commands.map((entry) => {
    const match = /^(bash) ([A-Za-z0-9][A-Za-z0-9._/-]*)$/.exec(entry);
    if (!match) throw new SafetyShardError('legacy canary command is invalid');
    return command(match[1], match[2]);
  });
}

function structureCommands() {
  return [...CI_STRUCTURE_TESTS]
    .sort()
    .map((name) => command('bash', `tests/structure/${name}`));
}

function commandInventory(root, kind) {
  if (fs.realpathSync.native(path.resolve(root)) !== ROOT) {
    throw new SafetyShardError('safety root must be the repository root');
  }
  if (kind === 'canary') return canaryCommands();
  if (kind === 'structure') return structureCommands();
  if (kind === 'offline') return OFFLINE_COMMANDS;
  throw new SafetyShardError('safety kind must be canary, structure, or offline');
}

function shardCommands(inventory, shard, total) {
  if (!Number.isSafeInteger(total) || total < 1 || total > 64) {
    throw new SafetyShardError('safety total must be between 1 and 64');
  }
  if (!Number.isSafeInteger(shard) || shard < 1 || shard > total) {
    throw new SafetyShardError('safety shard must be between 1 and total');
  }
  const selected = inventory.filter((_entry, index) => index % total === shard - 1);
  if (selected.length === 0) throw new SafetyShardError('safety shard must not be empty');
  return selected;
}

async function run(kind, shard, total, {
  platform = process.platform,
  output = process.stdout,
  environment = process.env,
  reportDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-windows-safety-')),
  runProfileFn = runProfile,
} = {}) {
  const selected = shardCommands(commandInventory(ROOT, kind), shard, total);
  output.write(`Windows safety ${kind} ${shard}/${total}: ${selected.length} command(s)\n`);
  for (const [index, entry] of selected.entries()) {
    const ordinal = index + 1;
    const profileId = `safety-${kind}-${shard}-${ordinal}`;
    output.write(`\n>>> ${entry.runner} ${entry.path} ${entry.args.join(' ')}\n`);
    const result = await runProfileFn({
      manifest: {
        schemaVersion: 1,
        profiles: {
          [profileId]: {
            platform,
            profileTimeoutMs: COMMAND_TIMEOUT_MS,
            suites: [{
              id: `${profileId}-command`,
              runner: entry.runner,
              path: entry.path,
              args: [...entry.args],
              timeoutMs: COMMAND_TIMEOUT_MS,
            }],
          },
        },
      },
      profileId,
      root: ROOT,
      reportDirectory,
      environment,
      output,
      platform,
      installSignalHandlers: true,
    });
    if (result.exitCode !== 0) {
      throw new SafetyShardError(
        `${entry.path} failed under supervised cleanup with status ${result.report.status}`,
      );
    }
  }
}

async function main(argv = process.argv.slice(2)) {
  if (argv.length !== 3 || !/^[1-9][0-9]*$/.test(argv[1]) || !/^[1-9][0-9]*$/.test(argv[2])) {
    throw new SafetyShardError(
      'usage: run-windows-safety-shard.js <canary|structure|offline> <shard> <total>',
    );
  }
  await run(argv[0], Number(argv[1]), Number(argv[2]));
}

if (require.main === module) {
  main().catch((error) => {
    process.stderr.write(`Windows safety shard failed: ${error.message}\n`);
    process.exitCode = 1;
  });
}

module.exports = {
  CI_STRUCTURE_TESTS,
  LOCAL_ONLY_INVENTORY,
  LOCAL_ONLY_STRUCTURE_TESTS,
  OFFLINE_COMMANDS,
  SafetyShardError,
  commandInventory,
  main,
  run,
  shardCommands,
};
