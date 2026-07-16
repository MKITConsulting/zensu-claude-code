'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const STATE_FILE_RE = /^tdd-phase-(scv1_[a-f0-9]{64})\.json$/;
const MAX_BYTES = 1024 * 1024;
const MANIFEST_EXCLUDES = Object.freeze([
  '.git',
  '.zensu/hook-events.log',
  '.zensu/logs',
]);

function sha256(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`;
}

function safeRead(file) {
  const before = fs.lstatSync(file);
  if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1 || before.size > MAX_BYTES) {
    throw new Error('unsafe regular file');
  }
  const noFollow = Number.isInteger(fs.constants.O_NOFOLLOW) ? fs.constants.O_NOFOLLOW : 0;
  const descriptor = fs.openSync(file, fs.constants.O_RDONLY | noFollow);
  try {
    const opened = fs.fstatSync(descriptor);
    if (!opened.isFile() || opened.nlink !== 1 || opened.size !== before.size) {
      throw new Error('file identity changed');
    }
    return fs.readFileSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
}

function projectState(state) {
  if (!state || typeof state !== 'object' || Array.isArray(state)) return null;
  return {
    revision: state.revision,
    reviewRound: state.reviewRound,
    stopBlockCount: state.stopBlockCount,
    chainDone: state.chainDone,
    codeReviewDone: state.codeReviewDone,
    selfReviewFixed: state.selfReviewFixed,
    active: state.active,
    implComplete: state.implComplete,
  };
}

function snapshotSidecars(stateDirectory, stateFile) {
  const stopblocksPath = `${stateFile}.stopblocks`;
  const roundsPath = path.join(stateDirectory, 'rounds-retired.json');
  const stopblocks = { present: false };
  const rounds = { present: false };

  if (fs.existsSync(stopblocksPath) || (() => {
    try { fs.lstatSync(stopblocksPath); return true; } catch (error) {
      if (error.code === 'ENOENT') return false;
      throw error;
    }
  })()) {
    const info = fs.lstatSync(stopblocksPath);
    stopblocks.present = true;
    stopblocks.kind = info.isSymbolicLink() ? 'symlink' : info.isFile() ? 'file' : 'other';
    if (info.isSymbolicLink()) {
      const linkTarget = fs.readlinkSync(stopblocksPath);
      const resolved = path.resolve(path.dirname(stopblocksPath), linkTarget);
      const relative = path.relative(stateDirectory, resolved);
      stopblocks.link_target = linkTarget;
      stopblocks.target_inside_state = relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
      if (stopblocks.target_inside_state) {
        const bytes = safeRead(resolved);
        stopblocks.target_basename = path.basename(resolved);
        stopblocks.target_sha256 = sha256(bytes);
        stopblocks.target_text = bytes.toString('utf8');
      }
    }
  }

  if (fs.existsSync(roundsPath)) {
    const bytes = safeRead(roundsPath);
    rounds.present = true;
    rounds.kind = 'file';
    rounds.sha256 = sha256(bytes);
  }
  return { stopblocks, rounds };
}

function snapshot(projectRootInput, coreFile) {
  const projectRoot = fs.realpathSync.native(projectRootInput);
  const stateDirectory = path.join(projectRoot, '.zensu', 'state');
  const directory = fs.lstatSync(stateDirectory);
  if (!directory.isDirectory() || directory.isSymbolicLink()) {
    return { status: 'unsafe-state-directory' };
  }
  const names = fs.readdirSync(stateDirectory).filter((name) => STATE_FILE_RE.test(name)).sort();
  if (names.length !== 1) return { status: 'ambiguous-state-files', state_file_count: names.length };
  const fileName = names[0];
  const sessionKey = STATE_FILE_RE.exec(fileName)[1];
  const stateFile = path.join(stateDirectory, fileName);
  const bytes = safeRead(stateFile);
  let parsed = null;
  let parseError = null;
  try { parsed = JSON.parse(bytes.toString('utf8')); }
  catch (_error) { parseError = 'invalid JSON'; }

  let validated = null;
  let validationError = null;
  if (!parseError) {
    try {
      const core = require(coreFile);
      validated = core.readWorkflowState({ projectRoot, sessionId: sessionKey });
    } catch (error) {
      validationError = String(error.message || error).replace(projectRoot, '<project>');
    }
  }
  return {
    status: validated ? 'valid' : 'invalid',
    file: fileName,
    raw_sha256: sha256(bytes),
    state: projectState(validated || parsed),
    validation_error: parseError || validationError,
    sidecars: snapshotSidecars(stateDirectory, stateFile),
  };
}

function fixtureManifest(projectRootInput, mutableStateFile) {
  const root = fs.realpathSync.native(projectRootInput);
  const mutablePath = `.zensu/state/${mutableStateFile}`;
  const records = [];
  const excluded = (relative) => MANIFEST_EXCLUDES.some(
    (entry) => relative === entry || relative.startsWith(`${entry}/`),
  );
  const visit = (relativeDirectory) => {
    const absoluteDirectory = relativeDirectory ? path.join(root, relativeDirectory) : root;
    for (const name of fs.readdirSync(absoluteDirectory).sort()) {
      const relative = relativeDirectory ? `${relativeDirectory}/${name}` : name;
      if (excluded(relative)) continue;
      const absolute = path.join(root, relative);
      const info = fs.lstatSync(absolute);
      const mode = info.mode & 0o777;
      if (relative === mutablePath) {
        if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1) {
          throw new Error('canonical mutable workflow state is unsafe');
        }
        records.push({ path: relative, type: 'mutable-workflow-state', mode });
      } else if (info.isSymbolicLink()) {
        records.push({ path: relative, type: 'symlink', mode, target: fs.readlinkSync(absolute) });
      } else if (info.isFile()) {
        const bytes = safeRead(absolute);
        records.push({ path: relative, type: 'file', mode, size: bytes.length, sha256: sha256(bytes) });
      } else if (info.isDirectory()) {
        records.push({ path: relative, type: 'directory', mode });
        visit(relative);
      } else {
        throw new Error(`unsupported fixture entry: ${relative}`);
      }
    }
  };
  visit('');
  return records;
}

module.exports = { fixtureManifest, snapshot };
