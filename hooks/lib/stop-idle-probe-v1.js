'use strict';

const fs = require('node:fs');
const path = require('node:path');
const core = require('./session-control-core-v1.js');

const VERDICTS = Object.freeze({
  IDLE: 'idle',
  IDLE_WITH_BYPASSES: 'idle-bypasses',
  BUSY: 'busy',
});

const PENDING_WORK_ENTRY = /^(?:autopilot-(?:active|run)|pending-review|reviewer-spawn-denied-)/;

const STORAGE_LEAVES = Object.freeze([
  Object.freeze({ name: 'autopilot', kind: 'file' }),
  Object.freeze({ name: 'autopilot.lock', kind: 'file' }),
  Object.freeze({ name: 'autopilot.lockd', kind: 'directory' }),
]);

function realDirectory(target) {
  const stat = fs.lstatSync(target);
  return !stat.isSymbolicLink() && stat.isDirectory();
}

function leafSafe(target, kind) {
  let stat;
  try {
    stat = fs.lstatSync(target);
  } catch (error) {
    if (error && error.code === 'ENOENT') return true;
    throw error;
  }
  if (stat.isSymbolicLink()) return false;
  if (kind === 'directory') return stat.isDirectory();
  return stat.isFile() && stat.nlink === 1;
}

function stopIdleVerdict(projectRoot, sessionKey) {
  if (typeof projectRoot !== 'string' || !path.isAbsolute(projectRoot)) return VERDICTS.BUSY;
  if (typeof sessionKey !== 'string' || core.sessionKey(sessionKey) !== sessionKey) return VERDICTS.BUSY;
  let stateDirectory = projectRoot;
  for (const segment of core.WORKFLOW_STATE_SEGMENTS) {
    stateDirectory = path.join(stateDirectory, segment);
    if (!realDirectory(stateDirectory)) return VERDICTS.BUSY;
  }
  const entries = fs.readdirSync(stateDirectory);
  if (entries.some((name) => PENDING_WORK_ENTRY.test(name))) return VERDICTS.BUSY;
  if (!STORAGE_LEAVES.every((leaf) => leafSafe(path.join(stateDirectory, leaf.name), leaf.kind))) {
    return VERDICTS.BUSY;
  }
  if (!entries.includes(`${core.WORKFLOW_STATE_PREFIX}${sessionKey}.json`)) return VERDICTS.BUSY;
  const state = core.readWorkflowState({ projectRoot, sessionId: sessionKey });
  const snapshot = core.workflowChainSnapshot(state, sessionKey);
  if (!snapshot || snapshot.autopilot !== null) return VERDICTS.BUSY;
  if (snapshot.active && !(snapshot.implComplete && snapshot.chainDone)) return VERDICTS.BUSY;
  return state.bypasses.length === 0 ? VERDICTS.IDLE : VERDICTS.IDLE_WITH_BYPASSES;
}

function main() {
  let verdict = VERDICTS.BUSY;
  try {
    verdict = stopIdleVerdict(process.env.ZENSU_IDLE_PROJECT_ROOT, process.env.ZENSU_IDLE_SESSION_KEY);
  } catch (_) {
    verdict = VERDICTS.BUSY;
  }
  process.stdout.write(`${verdict}\n`);
}

if (require.main === module) main();

module.exports = {
  VERDICTS,
  PENDING_WORK_ENTRY,
  stopIdleVerdict,
};
