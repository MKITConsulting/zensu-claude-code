#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { loadProfileContract } = require('./windows-profile-contract.js');

const EXPECTED_PROFILES = Object.freeze([
  'windows-reset-session',
  'windows-leases-routing',
  'windows-native-state',
  'windows-installed-core',
]);
const SHA = /^[a-f0-9]{40}$/;
const HASH = /^[a-f0-9]{64}$/;
const ID = /^[0-9]{1,32}$/;
const EVENT = /^(?:pull_request|push)$/;
const MAX_JSON_BYTES = 4 * 1024 * 1024;
const SUMMARY_KEYS = new Set([
  'schemaVersion',
  'kind',
  'sourceGitRevision',
  'runId',
  'runAttempt',
  'eventName',
  'observedAt',
  'manifestSha256',
  'commandCatalogSha256',
  'profileContractSha256',
  'legacyOutcome',
  'shardOutcome',
  'parity',
  'complete',
  'profiles',
]);
const SUMMARY_PROFILE_KEYS = new Set(['profile', 'status', 'durationMs', 'suiteCount']);
const LEDGER_KEYS = new Set(['schemaVersion', 'observations']);

class ObservationError extends Error {}

function isObject(value) {
  return value !== null
    && typeof value === 'object'
    && !Array.isArray(value)
    && Object.getPrototypeOf(value) === Object.prototype;
}

function readBoundedRegularFile(file, label) {
  const info = fs.lstatSync(file, { bigint: true });
  if (info.isSymbolicLink() || !info.isFile() || info.nlink !== 1n
      || info.size > BigInt(MAX_JSON_BYTES)) {
    throw new ObservationError(`${label} must be a bounded singly linked regular JSON file`);
  }
  const source = fs.readFileSync(file);
  const after = fs.lstatSync(file, { bigint: true });
  if (after.dev !== info.dev || after.ino !== info.ino || after.size !== info.size
      || after.mtimeMs !== info.mtimeMs) {
    throw new ObservationError(`${label} changed while it was being read`);
  }
  return source;
}

function readJson(file, label) {
  const source = readBoundedRegularFile(file, label);
  let value;
  try {
    value = JSON.parse(source.toString('utf8'));
  } catch (error) {
    throw new ObservationError(`${label} is invalid JSON: ${error.message}`);
  }
  return value;
}

function hasExactKeys(value, expected) {
  const keys = Object.keys(value);
  return keys.length === expected.size && keys.every((key) => expected.has(key));
}

function currentContract() {
  try {
    return loadProfileContract(path.resolve(__dirname, '..'));
  } catch (error) {
    throw new ObservationError(`current Windows profile contract is invalid: ${error.message}`);
  }
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, {
    encoding: 'utf8',
    flag: 'wx',
    mode: 0o600,
  });
  fs.renameSync(temporary, file);
}

function requireString(value, pattern, label) {
  if (typeof value !== 'string' || !pattern.test(value)) {
    throw new ObservationError(`${label} is invalid`);
  }
  return value;
}

function validateContext(value, expected, label) {
  if (value !== expected) throw new ObservationError(`${label} does not match this workflow run`);
}

function validateLegacy(record, expected) {
  if (!isObject(record) || record.schemaVersion !== 1 || record.kind !== 'windows-legacy-outcome') {
    throw new ObservationError('legacy outcome schema is invalid');
  }
  requireString(record.sourceGitRevision, SHA, 'legacy sourceGitRevision');
  requireString(record.runId, ID, 'legacy runId');
  requireString(record.runAttempt, ID, 'legacy runAttempt');
  requireString(record.eventName, EVENT, 'legacy eventName');
  if (!['success', 'failure', 'cancelled', 'timed_out'].includes(record.outcome)) {
    throw new ObservationError('legacy outcome is invalid');
  }
  validateContext(record.sourceGitRevision, expected.sourceGitRevision, 'legacy sourceGitRevision');
  validateContext(record.runId, expected.runId, 'legacy runId');
  validateContext(record.runAttempt, expected.runAttempt, 'legacy runAttempt');
  validateContext(record.eventName, expected.eventName, 'legacy eventName');
  return record;
}

function validateProfile(report, profile, expected, contract) {
  const expectedProfile = contract.profiles[profile];
  if (!isObject(report) || report.schemaVersion !== 3 || report.profile !== profile
      || !expectedProfile) {
    throw new ObservationError(`${profile} report schema is invalid`);
  }
  requireString(report.manifestSha256, HASH, `${profile} manifestSha256`);
  requireString(report.commandCatalogSha256, HASH, `${profile} commandCatalogSha256`);
  requireString(report.profileContractSha256, HASH, `${profile} profileContractSha256`);
  requireString(report.sourceGitRevision, SHA, `${profile} sourceGitRevision`);
  requireString(report.runId, ID, `${profile} runId`);
  requireString(report.runAttempt, ID, `${profile} runAttempt`);
  requireString(report.eventName, EVENT, `${profile} eventName`);
  validateContext(report.sourceGitRevision, expected.sourceGitRevision, `${profile} sourceGitRevision`);
  validateContext(report.runId, expected.runId, `${profile} runId`);
  validateContext(report.runAttempt, expected.runAttempt, `${profile} runAttempt`);
  validateContext(report.eventName, expected.eventName, `${profile} eventName`);
  validateContext(
    report.manifestSha256,
    contract.manifestSha256,
    `${profile} manifestSha256`,
  );
  validateContext(
    report.commandCatalogSha256,
    contract.commandCatalogSha256,
    `${profile} commandCatalogSha256`,
  );
  validateContext(
    report.profileContractSha256,
    contract.profileContractSha256,
    `${profile} profileContractSha256`,
  );
  if (!['passed', 'failed', 'cancelled'].includes(report.status)
      || report.profileTimeoutMs !== expectedProfile.profileTimeoutMs
      || report.platform !== 'win32'
      || !Array.isArray(report.suites)
      || report.suites.length !== expectedProfile.suites.length
      || !report.endedAt || !Number.isFinite(report.durationMs)) {
    throw new ObservationError(`${profile} report is incomplete`);
  }
  const suiteIds = new Set();
  for (const [index, suite] of report.suites.entries()) {
    const expectedSuite = expectedProfile.suites[index];
    if (!isObject(suite) || typeof suite.id !== 'string' || suiteIds.has(suite.id)
        || !HASH.test(suite.executedSha256 || '')
        || suite.id !== expectedSuite.id
        || suite.path !== expectedSuite.path
        || JSON.stringify(suite.args) !== JSON.stringify(expectedSuite.args)
        || suite.executedSha256 !== expectedSuite.executedSha256
        || !['passed', 'failed', 'timed_out', 'spawn_error'].includes(suite.status)
        || !isObject(suite.cleanup)
        || !['terminated', 'failed', 'failed_recovered'].includes(suite.cleanup.status)) {
      throw new ObservationError(`${profile} contains invalid suite evidence`);
    }
    suiteIds.add(suite.id);
  }
  const allSuitesPassed = report.suites.every((suite) => (
    suite.status === 'passed' && suite.cleanup.status === 'terminated'
  ));
  if ((report.status === 'passed') !== allSuitesPassed) {
    throw new ObservationError(`${profile} status contradicts its suite evidence`);
  }
  return report;
}

function summarize({ reportsDirectory, legacyFile, expected }) {
  const contract = currentContract();
  const directory = fs.realpathSync.native(reportsDirectory);
  const names = fs.readdirSync(directory).filter((name) => name.endsWith('.json')).sort();
  const expectedNames = EXPECTED_PROFILES.map((profile) => `${profile}.json`).sort();
  if (JSON.stringify(names) !== JSON.stringify(expectedNames)) {
    throw new ObservationError('profile report inventory must contain exactly four expected files');
  }
  const profiles = EXPECTED_PROFILES.map((profile) => validateProfile(
    readJson(path.join(directory, `${profile}.json`), `${profile} report`),
    profile,
    expected,
    contract,
  ));
  const legacy = validateLegacy(readJson(legacyFile, 'legacy outcome'), expected);
  const manifestHashes = new Set(profiles.map((report) => report.manifestSha256));
  const catalogHashes = new Set(profiles.map((report) => report.commandCatalogSha256));
  const contractHashes = new Set(profiles.map((report) => report.profileContractSha256));
  if (manifestHashes.size !== 1 || catalogHashes.size !== 1 || contractHashes.size !== 1) {
    throw new ObservationError('profile reports do not share one complete execution contract');
  }
  const shardOutcome = profiles.every((report) => report.status === 'passed')
    ? 'success'
    : 'failure';
  const complete = profiles.every((report) => (
    report.status !== 'cancelled'
    && !report.profileDeadlineExceeded
    && report.suites.every((suite) => (
      suite.status !== 'timed_out'
      && suite.status !== 'spawn_error'
      && suite.cleanup.status === 'terminated'
    ))
  ));
  return {
    schemaVersion: 2,
    kind: 'windows-observation-summary',
    sourceGitRevision: expected.sourceGitRevision,
    runId: expected.runId,
    runAttempt: expected.runAttempt,
    eventName: expected.eventName,
    observedAt: new Date().toISOString(),
    manifestSha256: profiles[0].manifestSha256,
    commandCatalogSha256: profiles[0].commandCatalogSha256,
    profileContractSha256: profiles[0].profileContractSha256,
    legacyOutcome: legacy.outcome,
    shardOutcome,
    parity: shardOutcome === 'success' && legacy.outcome === 'success',
    complete,
    profiles: profiles.map((report) => ({
      profile: report.profile,
      status: report.status,
      durationMs: report.durationMs,
      suiteCount: report.suites.length,
    })),
  };
}

function auditLedger(ledger, expectedContract = null) {
  if (!isObject(ledger) || !hasExactKeys(ledger, LEDGER_KEYS)
      || ledger.schemaVersion !== 2 || !Array.isArray(ledger.observations)) {
    throw new ObservationError('observation ledger schema is invalid');
  }
  if (!expectedContract || !isObject(expectedContract.profiles)) {
    throw new ObservationError('current Windows profile contract is required');
  }
  if (ledger.observations.length < 10) {
    throw new ObservationError('observation ledger needs at least 10 runs');
  }
  const runKeys = new Set();
  const revisions = new Set();
  const events = new Set();
  const manifestHashes = new Set();
  const catalogHashes = new Set();
  const profileContractHashes = new Set();
  const timestamps = [];
  for (const observation of ledger.observations) {
    if (!isObject(observation)
        || !hasExactKeys(observation, SUMMARY_KEYS)
        || observation.schemaVersion !== 2
        || observation.kind !== 'windows-observation-summary'
        || observation.parity !== true
        || observation.complete !== true
        || observation.legacyOutcome !== 'success'
        || observation.shardOutcome !== 'success'
        || !Array.isArray(observation.profiles)
        || observation.profiles.length !== EXPECTED_PROFILES.length) {
      throw new ObservationError('observation ledger contains an ineligible run');
    }
    const profileNames = [];
    for (const profile of observation.profiles) {
      if (!isObject(profile)
          || !hasExactKeys(profile, SUMMARY_PROFILE_KEYS)
          || typeof profile.profile !== 'string'
          || profile.status !== 'passed'
          || !Number.isFinite(profile.durationMs)
          || !Number.isInteger(profile.suiteCount)
          || profile.suiteCount < 1) {
        throw new ObservationError('observation ledger contains invalid profile evidence');
      }
      profileNames.push(profile.profile);
    }
    if (JSON.stringify(profileNames) !== JSON.stringify(EXPECTED_PROFILES)) {
      throw new ObservationError('observation ledger profile inventory is invalid');
    }
    for (const profile of observation.profiles) {
      const expectedProfile = expectedContract.profiles[profile.profile];
      if (!expectedProfile || profile.suiteCount !== expectedProfile.suites.length) {
        throw new ObservationError('observation ledger suite inventory is invalid');
      }
    }
    const derivedShardOutcome = observation.profiles.every(
      (profile) => profile.status === 'passed',
    ) ? 'success' : 'failure';
    if (derivedShardOutcome !== observation.shardOutcome) {
      throw new ObservationError('observation ledger profile outcomes are inconsistent');
    }
    requireString(observation.sourceGitRevision, SHA, 'ledger sourceGitRevision');
    requireString(observation.runId, ID, 'ledger runId');
    requireString(observation.runAttempt, ID, 'ledger runAttempt');
    requireString(observation.eventName, EVENT, 'ledger eventName');
    manifestHashes.add(requireString(
      observation.manifestSha256,
      HASH,
      'ledger manifestSha256',
    ));
    catalogHashes.add(requireString(
      observation.commandCatalogSha256,
      HASH,
      'ledger commandCatalogSha256',
    ));
    profileContractHashes.add(requireString(
      observation.profileContractSha256,
      HASH,
      'ledger profileContractSha256',
    ));
    const key = `${observation.runId}:${observation.runAttempt}`;
    if (runKeys.has(key)) throw new ObservationError('observation ledger contains a duplicate run');
    runKeys.add(key);
    revisions.add(observation.sourceGitRevision);
    events.add(observation.eventName);
    const timestamp = Date.parse(observation.observedAt);
    if (!Number.isFinite(timestamp)) throw new ObservationError('ledger observedAt is invalid');
    timestamps.push(timestamp);
  }
  if (revisions.size < 10) throw new ObservationError('observation ledger needs 10 distinct revisions');
  if (!events.has('pull_request') || !events.has('push')) {
    throw new ObservationError('observation ledger must represent pull_request and main push runs');
  }
  if (manifestHashes.size !== 1
      || catalogHashes.size !== 1
      || profileContractHashes.size !== 1) {
    throw new ObservationError('observation ledger must use one unchanged execution contract');
  }
  const [manifestSha256] = manifestHashes;
  const [commandCatalogSha256] = catalogHashes;
  const [profileContractSha256] = profileContractHashes;
  requireString(expectedContract.manifestSha256, HASH, 'current manifestSha256');
  requireString(expectedContract.commandCatalogSha256, HASH, 'current commandCatalogSha256');
  requireString(expectedContract.profileContractSha256, HASH, 'current profileContractSha256');
  if (manifestSha256 !== expectedContract.manifestSha256) {
    throw new ObservationError('observation ledger does not match the current manifest');
  }
  if (commandCatalogSha256 !== expectedContract.commandCatalogSha256) {
    throw new ObservationError('observation ledger does not match the current command catalog');
  }
  if (profileContractSha256 !== expectedContract.profileContractSha256) {
    throw new ObservationError('observation ledger does not match the current execution contract');
  }
  const span = Math.max(...timestamps) - Math.min(...timestamps);
  if (span < 14 * 24 * 60 * 60 * 1000) {
    throw new ObservationError('observation ledger must span at least 14 days');
  }
  return {
    eligible: true,
    runCount: runKeys.size,
    revisionCount: revisions.size,
    spanDays: span / 86400000,
    manifestSha256,
    commandCatalogSha256,
    profileContractSha256,
  };
}

function environmentContext(environment) {
  return {
    sourceGitRevision: requireString(environment.GITHUB_SHA, SHA, 'GITHUB_SHA'),
    runId: requireString(environment.GITHUB_RUN_ID, ID, 'GITHUB_RUN_ID'),
    runAttempt: requireString(environment.GITHUB_RUN_ATTEMPT, ID, 'GITHUB_RUN_ATTEMPT'),
    eventName: requireString(environment.GITHUB_EVENT_NAME, EVENT, 'GITHUB_EVENT_NAME'),
  };
}

function recordLegacy(environment) {
  const expected = environmentContext(environment);
  const outcome = environment.ZENSU_LEGACY_OUTCOME;
  if (!['success', 'failure', 'cancelled', 'timed_out'].includes(outcome)) {
    throw new ObservationError('ZENSU_LEGACY_OUTCOME is invalid');
  }
  return {
    schemaVersion: 1,
    kind: 'windows-legacy-outcome',
    ...expected,
    outcome,
  };
}

function main({
  argv = process.argv.slice(2),
  environment = process.env,
  stdout = process.stdout,
  stderr = process.stderr,
} = {}) {
  try {
    const [mode, ...args] = argv;
    if (mode === 'record-legacy' && args.length === 1) {
      writeJson(args[0], recordLegacy(environment));
      return 0;
    }
    if (mode === 'summarize' && args.length === 3) {
      const value = summarize({
        reportsDirectory: args[0],
        legacyFile: args[1],
        expected: environmentContext(environment),
      });
      writeJson(args[2], value);
      stdout.write(`windows observation: ${value.parity && value.complete ? 'ELIGIBLE-RUN' : 'NOT-ELIGIBLE'}\n`);
      return value.parity && value.complete ? 0 : 1;
    }
    if (mode === 'audit-ledger' && args.length === 1) {
      const result = auditLedger(
        readJson(args[0], 'observation ledger'),
        currentContract(),
      );
      stdout.write(`windows observation ledger: PASS (${result.runCount} runs, ${result.spanDays.toFixed(1)} days)\n`);
      return 0;
    }
    throw new ObservationError(
      'usage: summarize-windows-observation.js record-legacy <output> | summarize <reports-dir> <legacy.json> <output> | audit-ledger <ledger.json>',
    );
  } catch (error) {
    if (!(error instanceof ObservationError)) throw error;
    stderr.write(`windows observation error: ${error.message}\n`);
    return 2;
  }
}

if (require.main === module) process.exitCode = main();

module.exports = {
  EXPECTED_PROFILES,
  ObservationError,
  auditLedger,
  main,
  recordLegacy,
  summarize,
};
