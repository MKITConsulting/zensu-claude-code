'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const {
  EXPECTED_PROFILES,
  auditLedger,
  main,
  recordLegacy,
  summarize,
  summarizeShards,
} = require('../summarize-windows-observation.js');
const { loadProfileContract } = require('../windows-profile-contract.js');
const CURRENT_PROFILE_CONTRACT = loadProfileContract(path.resolve(__dirname, '..', '..'));

const context = {
  sourceGitRevision: 'a'.repeat(40),
  runId: '123',
  runAttempt: '2',
  eventName: 'pull_request',
};

function profile(name, overrides = {}) {
  const contract = currentContractHashes();
  const expectedProfile = contract.profiles[name];
  return {
    schemaVersion: 3,
    manifestSha256: contract.manifestSha256,
    commandCatalogSha256: contract.commandCatalogSha256,
    profileContractSha256: contract.profileContractSha256,
    ...context,
    runnerImage: 'windows-2025',
    profile: name,
    profileTimeoutMs: 1800000,
    platform: 'win32',
    nodeVersion: 'v20.19.0',
    status: 'passed',
    startedAt: '2026-07-01T00:00:00.000Z',
    endedAt: '2026-07-01T00:01:00.000Z',
    durationMs: 60000,
    suites: expectedProfile.suites.map((suite) => ({
      id: suite.id,
      path: suite.path,
      args: [...suite.args],
      executedSha256: suite.executedSha256,
      timeoutMs: 1000,
      effectiveTimeoutMs: 1000,
      timeoutScope: null,
      status: 'passed',
      exitCode: 0,
      signal: null,
      startedAt: '2026-07-01T00:00:00.000Z',
      endedAt: '2026-07-01T00:01:00.000Z',
      durationMs: 60000,
      cleanup: { status: 'terminated', mechanism: 'windows-job-object-taskkill-tree' },
    })),
    ...overrides,
  };
}

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-windows-observation-'));
  const reports = path.join(root, 'reports');
  fs.mkdirSync(reports);
  for (const name of EXPECTED_PROFILES) {
    fs.writeFileSync(path.join(reports, `${name}.json`), JSON.stringify(profile(name)));
  }
  const legacy = path.join(root, 'legacy.json');
  fs.writeFileSync(legacy, JSON.stringify({
    schemaVersion: 1,
    kind: 'windows-legacy-outcome',
    ...context,
    outcome: 'success',
  }));
  return { root, reports, legacy };
}

function artifactName(name, attempt) {
  return `windows-profile-${name}-${context.sourceGitRevision}-${attempt}`;
}

function reportFile(artifacts, name = EXPECTED_PROFILES[0], attempt = context.runAttempt) {
  return path.join(artifacts, artifactName(name, attempt), `${name}.json`);
}

function writeArtifact(artifacts, name, attempt, report = profile(name, { runAttempt: attempt })) {
  const file = reportFile(artifacts, name, attempt);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(report));
  return file;
}

function artifactFixture(attempt = context.runAttempt) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-windows-shard-artifacts-'));
  const artifacts = path.join(root, 'artifacts');
  fs.mkdirSync(artifacts);
  for (const name of EXPECTED_PROFILES) writeArtifact(artifacts, name, attempt);
  return { root, artifacts };
}

function currentContractHashes() {
  return CURRENT_PROFILE_CONTRACT;
}

function currentContractEvidence() {
  const contract = currentContractHashes();
  return {
    manifestSha256: contract.manifestSha256,
    commandCatalogSha256: contract.commandCatalogSha256,
    profileContractSha256: contract.profileContractSha256,
  };
}

function ledgerObservations(overrides = {}) {
  return Array.from({ length: 10 }, (_unused, index) => ({
    schemaVersion: 2,
    kind: 'windows-observation-summary',
    ...currentContractEvidence(),
    sourceGitRevision: index.toString(16).padStart(40, '0'),
    runId: String(100 + index),
    runAttempt: '1',
    eventName: index === 9 ? 'push' : 'pull_request',
    observedAt: new Date(Date.UTC(2026, 6, 1 + index * 2)).toISOString(),
    legacyOutcome: 'success',
    shardOutcome: 'success',
    parity: true,
    complete: true,
    profiles: EXPECTED_PROFILES.map((profileName) => ({
      profile: profileName,
      status: 'passed',
      durationMs: 60000,
      suiteCount: currentContractHashes().profiles[profileName].suites.length,
    })),
    ...overrides,
  }));
}

test('summarizes every provenance-bound profile report against the legacy result', () => {
  const value = fixture();
  try {
    const result = summarize({ reportsDirectory: value.reports, legacyFile: value.legacy, expected: context });
    assert.equal(result.parity, true);
    assert.equal(result.complete, true);
    assert.equal(result.profiles.length, EXPECTED_PROFILES.length);
    assert.equal(result.shardOutcome, 'success');
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('cutover summary passes only the complete same-run Windows shard inventory', () => {
  const value = artifactFixture();
  try {
    const result = summarizeShards({
      artifactsDirectory: value.artifacts,
      expected: context,
    });
    assert.deepEqual(
      {
        schemaVersion: result.schemaVersion,
        kind: result.kind,
        status: result.status,
        complete: result.complete,
        profileNames: result.profiles.map((entry) => entry.profile),
        profileAttempts: result.profiles.map((entry) => entry.runAttempt),
      },
      {
        schemaVersion: 2,
        kind: 'windows-shard-summary',
        status: 'passed',
        complete: true,
        profileNames: EXPECTED_PROFILES,
        profileAttempts: EXPECTED_PROFILES.map(() => context.runAttempt),
      },
    );
    assert.deepEqual(
      {
        sourceGitRevision: result.sourceGitRevision,
        runId: result.runId,
        runAttempt: result.runAttempt,
        eventName: result.eventName,
      },
      context,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('cutover summary fails closed on malformed, drifted, or red shard evidence', () => {
  const mutations = [
    {
      throws: /has no report for/,
      mutate: ({ artifacts }) => fs.rmSync(path.dirname(reportFile(artifacts)), { recursive: true }),
    },
    {
      throws: /must hold exactly/,
      mutate: ({ artifacts }) => fs.unlinkSync(reportFile(artifacts)),
    },
    {
      throws: /must hold exactly/,
      mutate: ({ artifacts }) => fs.writeFileSync(
        path.join(path.dirname(reportFile(artifacts)), 'unexpected.json'),
        JSON.stringify(profile(EXPECTED_PROFILES[0])),
      ),
    },
    {
      throws: /not a profile report artifact/,
      mutate: ({ artifacts }) => fs.mkdirSync(path.join(artifacts, 'unexpected')),
    },
    {
      throws: /not a profile report artifact/,
      mutate: ({ artifacts }) => fs.mkdirSync(path.join(artifacts, artifactName('windows-shard-0', '1'))),
    },
    {
      throws: /not a profile report artifact/,
      mutate: ({ artifacts }) => fs.mkdirSync(path.join(
        artifacts,
        `windows-profile-${EXPECTED_PROFILES[0]}-${'b'.repeat(40)}-1`,
      )),
    },
    {
      throws: /not a profile report artifact/,
      mutate: ({ artifacts }) => fs.mkdirSync(
        path.join(artifacts, artifactName(EXPECTED_PROFILES[0], '01')),
      ),
    },
    {
      throws: /not a profile report artifact/,
      mutate: ({ artifacts }) => fs.writeFileSync(
        path.join(artifacts, artifactName(EXPECTED_PROFILES[0], '1')),
        JSON.stringify(profile(EXPECTED_PROFILES[0], { runAttempt: '1' })),
      ),
    },
    {
      throws: /later run attempt/,
      mutate: ({ artifacts }) => writeArtifact(artifacts, EXPECTED_PROFILES[0], '3'),
    },
    { mutate: ({ artifacts }) => {
      const file = reportFile(artifacts);
      const failed = profile(EXPECTED_PROFILES[0], { status: 'failed' });
      failed.suites[0] = { ...failed.suites[0], status: 'failed', exitCode: 1 };
      fs.writeFileSync(file, JSON.stringify(failed));
    } },
    { mutate: ({ artifacts }) => {
      const file = reportFile(artifacts);
      const timedOut = profile(EXPECTED_PROFILES[0], { status: 'failed' });
      timedOut.suites[0] = {
        ...timedOut.suites[0],
        status: 'timed_out',
        timeoutScope: 'suite',
      };
      fs.writeFileSync(file, JSON.stringify(timedOut));
    } },
    { mutate: ({ artifacts }) => {
      const file = reportFile(artifacts);
      const cleanupFailed = profile(EXPECTED_PROFILES[0], { status: 'failed' });
      cleanupFailed.suites[0] = {
        ...cleanupFailed.suites[0],
        cleanup: { status: 'failed', mechanism: null },
      };
      fs.writeFileSync(file, JSON.stringify(cleanupFailed));
    } },
    { throws: /runAttempt/, mutate: ({ artifacts }) => {
      const file = reportFile(artifacts);
      fs.writeFileSync(file, JSON.stringify(profile(EXPECTED_PROFILES[0], { runAttempt: '1' })));
    } },
    { throws: /profileContractSha256/, mutate: ({ artifacts }) => {
      const file = reportFile(artifacts);
      fs.writeFileSync(file, JSON.stringify(profile(EXPECTED_PROFILES[0], {
        profileContractSha256: 'e'.repeat(64),
      })));
    } },
    { throws: /report is incomplete/, mutate: ({ artifacts }) => {
      const file = reportFile(artifacts);
      fs.writeFileSync(file, JSON.stringify(profile(EXPECTED_PROFILES[0], { suites: [] })));
    } },
    { throws: /status contradicts its suite evidence/, mutate: ({ artifacts }) => {
      const file = reportFile(artifacts);
      const contradictory = profile(EXPECTED_PROFILES[0]);
      contradictory.suites[0] = {
        ...contradictory.suites[0],
        status: 'failed',
        exitCode: 1,
      };
      fs.writeFileSync(file, JSON.stringify(contradictory));
    } },
  ];
  for (const mutation of mutations) {
    const value = artifactFixture();
    try {
      mutation.mutate(value);
      if (mutation.throws) {
        assert.throws(
          () => summarizeShards({ artifactsDirectory: value.artifacts, expected: context }),
          mutation.throws,
        );
      } else {
        const result = summarizeShards({
          artifactsDirectory: value.artifacts,
          expected: context,
        });
        assert.equal(result.status, 'failed');
        assert.equal(result.complete, false);
      }
    } finally {
      fs.rmSync(value.root, { recursive: true, force: true });
    }
  }
});

test('shard summary judges every profile by its newest run attempt', () => {
  const value = artifactFixture('1');
  try {
    const [rerunProfile, laterProfile] = EXPECTED_PROFILES;
    const timedOut = profile(rerunProfile, { runAttempt: '1', status: 'failed' });
    timedOut.suites[0] = { ...timedOut.suites[0], status: 'timed_out', timeoutScope: 'suite' };
    fs.writeFileSync(reportFile(value.artifacts, rerunProfile, '1'), JSON.stringify(timedOut));
    writeArtifact(value.artifacts, rerunProfile, '2');
    const repaired = summarizeShards({ artifactsDirectory: value.artifacts, expected: context });
    assert.equal(repaired.status, 'passed');
    assert.equal(repaired.runAttempt, '2');
    assert.deepEqual(
      repaired.profiles.map((entry) => entry.runAttempt),
      EXPECTED_PROFILES.map((name) => (name === rerunProfile ? '2' : '1')),
    );

    const summaryOnly = { ...context, runAttempt: '3' };
    const rerunSummary = summarizeShards({ artifactsDirectory: value.artifacts, expected: summaryOnly });
    assert.equal(rerunSummary.status, 'passed');
    assert.equal(rerunSummary.runAttempt, '3');
    assert.deepEqual(
      rerunSummary.profiles.map((entry) => entry.runAttempt),
      repaired.profiles.map((entry) => entry.runAttempt),
    );

    const regressed = profile(laterProfile, { runAttempt: '3', status: 'failed' });
    regressed.suites[0] = { ...regressed.suites[0], status: 'failed', exitCode: 1 };
    writeArtifact(value.artifacts, laterProfile, '3', regressed);
    const masked = summarizeShards({ artifactsDirectory: value.artifacts, expected: summaryOnly });
    assert.equal(masked.status, 'failed');
    assert.equal(masked.complete, false);
    assert.deepEqual(
      masked.profiles.filter((entry) => entry.profile === laterProfile),
      [{ profile: laterProfile, status: 'failed', durationMs: 60000,
        suiteCount: regressed.suites.length, runAttempt: '3' }],
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('summary fails closed on inventory, provenance, hash, suite, and legacy drift', () => {
  const mutations = [
    ({ reports }) => fs.unlinkSync(path.join(reports, `${EXPECTED_PROFILES[0]}.json`)),
    ({ reports }) => fs.writeFileSync(path.join(reports, 'extra.json'), '{}'),
    ({ reports }) => {
      const file = path.join(reports, `${EXPECTED_PROFILES[0]}.json`);
      fs.writeFileSync(file, JSON.stringify(profile(EXPECTED_PROFILES[0], { runAttempt: '9' })));
    },
    ({ reports }) => {
      const file = path.join(reports, `${EXPECTED_PROFILES[0]}.json`);
      fs.writeFileSync(file, JSON.stringify(profile(EXPECTED_PROFILES[0], { manifestSha256: 'e'.repeat(64) })));
    },
    ({ reports }) => {
      const file = path.join(reports, `${EXPECTED_PROFILES[0]}.json`);
      fs.writeFileSync(file, JSON.stringify(profile(EXPECTED_PROFILES[0], { suites: [] })));
    },
    ({ reports }) => {
      const file = path.join(reports, `${EXPECTED_PROFILES[0]}.json`);
      const incomplete = profile(EXPECTED_PROFILES[0]);
      incomplete.suites.pop();
      fs.writeFileSync(file, JSON.stringify(incomplete));
    },
    ({ reports }) => {
      const file = path.join(reports, `${EXPECTED_PROFILES[0]}.json`);
      const drifted = profile(EXPECTED_PROFILES[0]);
      drifted.suites[0].args = ['unexpected'];
      fs.writeFileSync(file, JSON.stringify(drifted));
    },
    ({ reports }) => {
      const file = path.join(reports, `${EXPECTED_PROFILES[0]}.json`);
      const contradictory = profile(EXPECTED_PROFILES[0]);
      contradictory.suites[0].status = 'failed';
      contradictory.suites[0].exitCode = 1;
      fs.writeFileSync(file, JSON.stringify(contradictory));
    },
    ({ reports }) => {
      const file = path.join(reports, `${EXPECTED_PROFILES[0]}.json`);
      fs.writeFileSync(file, JSON.stringify(profile(EXPECTED_PROFILES[0], {
        status: 'failed',
      })));
    },
    ({ legacy }) => fs.writeFileSync(legacy, JSON.stringify({ schemaVersion: 1 })),
  ];
  for (const mutate of mutations) {
    const value = fixture();
    try {
      mutate(value);
      assert.throws(
        () => summarize({ reportsDirectory: value.reports, legacyFile: value.legacy, expected: context }),
      );
    } finally {
      fs.rmSync(value.root, { recursive: true, force: true });
    }
  }
});

test('timeouts, cleanup failures, and shard/legacy mismatches are not eligible', () => {
  const value = fixture();
  try {
    const file = path.join(value.reports, `${EXPECTED_PROFILES[0]}.json`);
    const failed = profile(EXPECTED_PROFILES[0], { status: 'failed' });
    failed.suites[0] = {
      ...failed.suites[0],
      status: 'timed_out',
      timeoutScope: 'profile',
      cleanup: { status: 'failed', mechanism: null },
    };
    fs.writeFileSync(file, JSON.stringify(failed));
    const result = summarize({ reportsDirectory: value.reports, legacyFile: value.legacy, expected: context });
    assert.equal(result.complete, false);
    assert.equal(result.parity, false);
    assert.equal(result.shardOutcome, 'failure');
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('matching shard and legacy failures are never eligible parity evidence', () => {
  const value = fixture();
  try {
    for (const name of EXPECTED_PROFILES) {
      const failed = profile(name, { status: 'failed' });
      failed.suites[0] = {
        ...failed.suites[0],
        status: 'failed',
        exitCode: 1,
      };
      fs.writeFileSync(path.join(value.reports, `${name}.json`), JSON.stringify(failed));
    }
    const legacyRecord = JSON.parse(fs.readFileSync(value.legacy, 'utf8'));
    fs.writeFileSync(value.legacy, JSON.stringify({ ...legacyRecord, outcome: 'failure' }));
    const result = summarize({
      reportsDirectory: value.reports,
      legacyFile: value.legacy,
      expected: context,
    });
    assert.equal(result.complete, true);
    assert.equal(result.shardOutcome, 'failure');
    assert.equal(result.legacyOutcome, 'failure');
    assert.equal(result.parity, false);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('legacy recorder and CLI use exact workflow provenance', () => {
  const environment = {
    GITHUB_SHA: context.sourceGitRevision,
    GITHUB_RUN_ID: context.runId,
    GITHUB_RUN_ATTEMPT: context.runAttempt,
    GITHUB_EVENT_NAME: context.eventName,
    ZENSU_LEGACY_OUTCOME: 'failure',
  };
  assert.deepEqual(recordLegacy(environment), {
    schemaVersion: 1,
    kind: 'windows-legacy-outcome',
    ...context,
    outcome: 'failure',
  });
  const stderr = [];
  assert.equal(main({
    argv: [],
    environment,
    stderr: { write(value) { stderr.push(String(value)); } },
  }), 2);
  assert.match(stderr.join(''), /usage:/);
});

test('public CLI records, summarizes, and audits persisted observation evidence', () => {
  const value = fixture();
  const environment = {
    GITHUB_SHA: context.sourceGitRevision,
    GITHUB_RUN_ID: context.runId,
    GITHUB_RUN_ATTEMPT: context.runAttempt,
    GITHUB_EVENT_NAME: context.eventName,
    ZENSU_LEGACY_OUTCOME: 'success',
  };
  const recordedLegacy = path.join(value.root, 'generated', 'legacy.json');
  const summary = path.join(value.root, 'generated', 'summary.json');
  const ledger = path.join(value.root, 'ledger.json');
  const stdout = [];
  try {
    assert.equal(main({
      argv: ['record-legacy', recordedLegacy],
      environment,
    }), 0);
    assert.equal(main({
      argv: ['summarize', value.reports, recordedLegacy, summary],
      environment,
      stdout: { write(message) { stdout.push(String(message)); } },
    }), 0);
    assert.equal(JSON.parse(fs.readFileSync(summary, 'utf8')).complete, true);

    fs.writeFileSync(ledger, JSON.stringify({
      schemaVersion: 2,
      observations: ledgerObservations(),
    }));
    assert.equal(main({
      argv: ['audit-ledger', ledger],
      stdout: { write(message) { stdout.push(String(message)); } },
    }), 0);
    assert.match(stdout.join(''), /ELIGIBLE-RUN/);
    assert.match(stdout.join(''), /PASS \(10 runs, 18\.0 days\)/);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('public CLI writes a shard-only aggregate and returns non-zero for red evidence', () => {
  const value = artifactFixture();
  const flat = fixture();
  const output = path.join(value.root, 'generated', 'shards.json');
  const stdout = [];
  const stderr = [];
  const environment = {
    GITHUB_SHA: context.sourceGitRevision,
    GITHUB_RUN_ID: context.runId,
    GITHUB_RUN_ATTEMPT: context.runAttempt,
    GITHUB_EVENT_NAME: context.eventName,
  };
  try {
    assert.equal(main({
      argv: ['summarize-shards', value.artifacts, output],
      environment,
      stdout: { write(message) { stdout.push(String(message)); } },
    }), 0);
    assert.equal(JSON.parse(fs.readFileSync(output, 'utf8')).status, 'passed');

    const file = reportFile(value.artifacts);
    const failed = profile(EXPECTED_PROFILES[0], { status: 'failed' });
    failed.suites[0] = { ...failed.suites[0], status: 'failed', exitCode: 1 };
    fs.writeFileSync(file, JSON.stringify(failed));
    assert.equal(main({
      argv: ['summarize-shards', value.artifacts, output],
      environment,
      stdout: { write(message) { stdout.push(String(message)); } },
    }), 1);
    assert.equal(JSON.parse(fs.readFileSync(output, 'utf8')).status, 'failed');
    assert.match(stdout.join(''), /windows shards: PASS/);
    assert.match(stdout.join(''), /windows shards: FAIL/);
    assert.equal(main({
      argv: ['summarize-shards', flat.reports, output],
      environment,
      stderr: { write(message) { stderr.push(String(message)); } },
    }), 2);
    assert.match(stderr.join(''), /is not a profile report artifact of this commit/);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
    fs.rmSync(flat.root, { recursive: true, force: true });
  }
});

test('public CLI fails closed for invalid persisted evidence and outcomes', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-windows-observation-invalid-'));
  const invalidJson = path.join(root, 'invalid.json');
  fs.writeFileSync(invalidJson, '{');
  const stderr = [];
  const environment = {
    GITHUB_SHA: context.sourceGitRevision,
    GITHUB_RUN_ID: context.runId,
    GITHUB_RUN_ATTEMPT: context.runAttempt,
    GITHUB_EVENT_NAME: context.eventName,
    ZENSU_LEGACY_OUTCOME: 'unknown',
  };
  try {
    assert.equal(main({
      argv: ['record-legacy', path.join(root, 'legacy.json')],
      environment,
      stderr: { write(message) { stderr.push(String(message)); } },
    }), 2);
    assert.equal(main({
      argv: ['audit-ledger', invalidJson],
      stderr: { write(message) { stderr.push(String(message)); } },
    }), 2);
    assert.match(stderr.join(''), /ZENSU_LEGACY_OUTCOME is invalid/);
    assert.match(stderr.join(''), /invalid JSON/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('ledger audit requires ten distinct revisions across 14 days and both event types', () => {
  const observations = ledgerObservations();
  const expectedHashes = currentContractHashes();
  const result = auditLedger({ schemaVersion: 2, observations }, expectedHashes);
  assert.equal(result.eligible, true);
  assert.equal(result.runCount, 10);
  for (const invalid of [
    observations.slice(0, 9),
    observations.map((entry) => ({ ...entry, observedAt: '2026-07-01T00:00:00.000Z' })),
    observations.map((entry) => ({ ...entry, eventName: 'pull_request' })),
    observations.map((entry, index) => (index === 0 ? { ...entry, parity: false } : entry)),
    observations.map((entry, index) => (index === 1 ? { ...entry, runId: '100' } : entry)),
    observations.map((entry, index) => (
      index === 2 ? { ...entry, schemaVersion: 1 } : entry
    )),
    observations.map((entry, index) => (
      index === 3 ? { ...entry, manifestSha256: 'f'.repeat(64) } : entry
    )),
    observations.map((entry, index) => (
      index === 4 ? { ...entry, commandCatalogSha256: 'e'.repeat(64) } : entry
    )),
    observations.map((entry, index) => (
      index === 5 ? { ...entry, profileContractSha256: 'd'.repeat(64) } : entry
    )),
    observations.map((entry, index) => (
      index === 6 ? {
        ...entry,
        profiles: entry.profiles.map((profileEntry, profileIndex) => (
          profileIndex === 0 ? { ...profileEntry, suiteCount: 1 } : profileEntry
        )),
      } : entry
    )),
    observations.map((entry, index) => (
      index === 7 ? { ...entry, unexpected: true } : entry
    )),
    observations.map((entry, index) => (
      index === 8 ? {
        ...entry,
        profiles: entry.profiles.map((profileEntry, profileIndex) => (
          profileIndex === 0 ? { ...profileEntry, status: 'failed' } : profileEntry
        )),
      } : entry
    )),
    observations.map((entry, index) => (
      index === 9 ? {
        ...entry,
        legacyOutcome: 'failure',
        shardOutcome: 'failure',
        parity: true,
        profiles: entry.profiles.map((profileEntry) => ({
          ...profileEntry,
          status: 'failed',
        })),
      } : entry
    )),
  ]) {
    assert.throws(() => auditLedger({ schemaVersion: 2, observations: invalid }, expectedHashes));
  }
  assert.throws(
    () => auditLedger(
      { schemaVersion: 2, observations },
      { ...expectedHashes, manifestSha256: '0'.repeat(64) },
    ),
    /current manifest/,
  );
  assert.throws(
    () => auditLedger(
      { schemaVersion: 2, observations },
      { ...expectedHashes, profileContractSha256: '0'.repeat(64) },
    ),
    /current execution contract/,
  );
});
