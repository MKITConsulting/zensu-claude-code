#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { fixtureManifest, snapshot } = require('./state-snapshot.js');

const [command, projectRoot, scenarioId, sessionId, extra, coreFileInput] = process.argv.slice(2);
const coreFile = command === 'snapshot' ? coreFileInput : extra;
if (!['seed', 'barrier', 'snapshot'].includes(command)
    || !projectRoot || !scenarioId || !sessionId || !coreFile) process.exit(2);
const core = require(coreFile);

function publish(beforeFile, value) {
  const temporary = `${beforeFile}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.tmp`;
  const descriptor = fs.openSync(temporary, 'wx', 0o600);
  try {
    fs.writeFileSync(descriptor, `${JSON.stringify(value)}\n`, 'utf8');
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  fs.linkSync(temporary, beforeFile);
  fs.unlinkSync(temporary);
}

const stateDirectory = path.join(projectRoot, '.zensu', 'state');
const stateFile = path.join(stateDirectory, `tdd-phase-${core.sessionKey(sessionId)}.json`);
if (command === 'seed') {
  core.initializeWorkflowState({ projectRoot, sessionId });
  const round = scenarioId === 'reset-cas-happy' ? 3 : scenarioId === 'reset-sidecar-isolation' ? 2 : 0;
  core.mutateWorkflowState({
    projectRoot,
    sessionId,
    workflowState: 'reset_eval_seeded',
    event: 'provider-seed',
    expectedRevision: 1,
  }, (state) => ({
    ...state,
    active: true,
    implComplete: true,
    reviewRound: round,
    stopBlockCount: 2,
    chainDone: true,
    codeReviewDone: true,
    selfReviewFixed: true,
  }));
}

if (command === 'barrier' && scenarioId === 'reset-invalid-state') {
  const valid = core.readWorkflowState({ projectRoot, sessionId });
  if (valid.revision !== 2 || valid.reviewRound !== 0) throw new Error('invalid-state barrier requires the valid provider seed');
  const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  state.reviewRound = '3';
  fs.writeFileSync(stateFile, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
} else if (command === 'seed' && scenarioId === 'reset-sidecar-isolation') {
  fs.writeFileSync(path.join(stateDirectory, 'retired-target.txt'), 'do-not-touch\n', { mode: 0o600 });
  fs.symlinkSync('retired-target.txt', `${stateFile}.stopblocks`);
  fs.writeFileSync(path.join(stateDirectory, 'rounds-retired.json'), '{"retired":true}\n', { mode: 0o600 });
}

if (command === 'snapshot') {
  const beforeFile = extra;
  const stateSnapshot = snapshot(projectRoot, coreFile);
  publish(beforeFile, {
    schema: 'zensu.reset-review-limit.provider-before',
    schema_version: 1,
    scenario_id: scenarioId,
    session_id_hash: core.sessionIdHash(sessionId),
    snapshot: stateSnapshot,
    fixture_manifest: fixtureManifest(projectRoot, stateSnapshot.file),
  });
}
