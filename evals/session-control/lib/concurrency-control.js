#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const core = require('../../../hooks/lib/session-control-core-v1.js');

const CONTENTION_SESSION = 'zensu-session-control-contention-v1';
const LEDGER_SCHEMA = 'zensu.session-control-contention-participant';
const BARRIER_SCHEMA = 'zensu.session-control-contention-barrier';
const CAPACITY = 4;
const GENERATIONS = 3;
const DEFAULT_TIMEOUT_MS = 180000;

function fail(message) {
  throw new Error(`session-control concurrency evidence: ${message}`);
}

function directory(input, label, create = false) {
  if (typeof input !== 'string' || !input || /[\0\r\n]/.test(input)) fail(`${label} is unsafe`);
  if (create) fs.mkdirSync(input, { recursive: true, mode: 0o700 });
  const supplied = fs.lstatSync(input);
  if (!supplied.isDirectory() || supplied.isSymbolicLink()) fail(`${label} must be a real directory`);
  if (process.platform !== 'win32') fs.chmodSync(input, 0o700);
  return fs.realpathSync.native(input);
}

function layout(sharedInput) {
  const shared = directory(sharedInput, 'shared control directory', true);
  const project = directory(path.join(shared, 'contention-project'), 'shared contention project', true);
  const control = directory(path.join(shared, 'contention-control'), 'shared contention control', true);
  const records = directory(path.join(control, 'session-control', 'v1', 'records'), 'shared records directory', true);
  const participants = directory(path.join(shared, 'participants'), 'shared participant ledger', true);
  const barrier = directory(path.join(shared, 'barrier'), 'shared barrier directory', true);
  const barrierLocks = directory(path.join(barrier, 'locks'), 'shared barrier locks', true);
  const ready = directory(path.join(barrier, 'ready'), 'shared barrier ready directory', true);
  const releases = directory(path.join(barrier, 'releases'), 'shared barrier release directory', true);
  const state = path.join(barrier, 'state.json');
  return { shared, project, control, records, participants, barrier, barrierLocks, ready, releases, state };
}

function regularJson(file, label = 'ledger artifact') {
  let stat;
  try { stat = fs.lstatSync(file); }
  catch (_error) { fail(`${label} is missing`); }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size === 0 || stat.size > 1024 * 1024) {
    fail(`unsafe ${label}`);
  }
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (_error) { fail(`${label} is invalid JSON`); }
}

function iso(milliseconds) {
  return new Date(milliseconds).toISOString();
}

function sleep(milliseconds) {
  const shared = new SharedArrayBuffer(4);
  Atomics.wait(new Int32Array(shared), 0, 0, milliseconds);
}

function processAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; }
  catch (error) { return error.code === 'EPERM'; }
}

function participantFile(paths, sessionHash) {
  return path.join(paths.participants, `${sessionHash.slice('sha256:'.length)}.json`);
}

function readyFile(paths, generation, sessionHash) {
  return path.join(paths.ready, `g${generation}-${sessionHash.slice('sha256:'.length)}.ready`);
}

function releaseFile(paths, generation) {
  return path.join(paths.releases, `g${generation}.json`);
}

function initialState(context) {
  return {
    schema: BARRIER_SCHEMA,
    schema_version: 1,
    capacity: CAPACITY,
    generation_limit: GENERATIONS,
    contention_context_hash: context.session_id_hash,
    generations: [],
  };
}

function validateParticipant(value, generation) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || !/^sha256:[a-f0-9]{64}$/.test(value.host_session_hash || '')
      || value.generation !== generation
      || !Number.isSafeInteger(value.pid) || value.pid <= 0
      || !Number.isSafeInteger(value.joined_at_ms) || value.joined_at_ms <= 0
      || value.joined_at !== iso(value.joined_at_ms)
      || (value.passed_at_ms !== null
        && (!Number.isSafeInteger(value.passed_at_ms) || value.passed_at_ms < value.joined_at_ms
          || value.passed_at !== iso(value.passed_at_ms)))
      || (value.passed_at_ms === null && value.passed_at !== null)) {
    fail('barrier participant state is invalid');
  }
  return value;
}

function validateState(value, context) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || value.schema !== BARRIER_SCHEMA || value.schema_version !== 1
      || value.capacity !== CAPACITY || value.generation_limit !== GENERATIONS
      || value.contention_context_hash !== context.session_id_hash
      || !Array.isArray(value.generations) || value.generations.length > GENERATIONS) {
    fail('shared barrier state is invalid');
  }
  const allSessions = new Set();
  let openCount = 0;
  value.generations.forEach((generation, index) => {
    const number = index + 1;
    if (!generation || typeof generation !== 'object' || Array.isArray(generation)
        || generation.generation !== number
        || !['open', 'released', 'completed', 'failed'].includes(generation.status)
        || !Number.isSafeInteger(generation.opened_at_ms) || generation.opened_at_ms <= 0
        || generation.opened_at !== iso(generation.opened_at_ms)
        || !Array.isArray(generation.participants)
        || generation.participants.length > CAPACITY) {
      fail(`barrier generation ${number} is invalid`);
    }
    if (generation.status === 'open') {
      openCount += 1;
      if (generation.released_at_ms !== null || generation.released_at !== null
          || generation.completed_at_ms !== null || generation.completed_at !== null
          || generation.live_participants_at_release !== 0) {
        fail(`open barrier generation ${number} contains release evidence`);
      }
    } else if (generation.status !== 'failed') {
      if (generation.participants.length !== CAPACITY
          || !Number.isSafeInteger(generation.released_at_ms)
          || generation.released_at !== iso(generation.released_at_ms)
          || generation.live_participants_at_release !== CAPACITY) {
        fail(`released barrier generation ${number} lacks four-way overlap evidence`);
      }
      if (generation.status === 'completed') {
        if (!Number.isSafeInteger(generation.completed_at_ms)
            || generation.completed_at !== iso(generation.completed_at_ms)
            || generation.participants.some((participant) => participant.passed_at_ms === null)) {
          fail(`completed barrier generation ${number} lacks acknowledgements`);
        }
      } else if (generation.completed_at_ms !== null || generation.completed_at !== null) {
        fail(`released barrier generation ${number} has premature completion evidence`);
      }
    }
    for (const participant of generation.participants) {
      validateParticipant(participant, number);
      if (allSessions.has(participant.host_session_hash)) fail('host session joined more than one barrier generation');
      allSessions.add(participant.host_session_hash);
    }
  });
  if (openCount > 1) fail('multiple barrier generations are open');
  return value;
}

function readState(paths, context) {
  if (!fs.existsSync(paths.state)) return initialState(context);
  return validateState(regularJson(paths.state, 'barrier state'), context);
}

function createExclusiveJson(file, value) {
  fs.writeFileSync(file, `${JSON.stringify(value)}\n`, { encoding: 'utf8', flag: 'wx', mode: 0o600 });
}

function ledgerValue(context, sourceGitRevision, participant, generation) {
  return {
    schema: LEDGER_SCHEMA,
    schema_version: 3,
    host: 'claude',
    host_session_hash: participant.host_session_hash,
    contention_context_hash: context.session_id_hash,
    runtime_digest: context.runtime_digest,
    source_revision: context.source_revision,
    source_git_revision: sourceGitRevision,
    generation: generation.generation,
    joined_at: participant.joined_at,
    barrier_released_at: generation.released_at,
    passed_at: participant.passed_at,
    live_participants_at_release: generation.live_participants_at_release,
  };
}

function join(paths, context, sourceGitRevision, hostSessionHash) {
  return core.withFileLock(paths.barrierLocks, 'barrier-state', () => {
    const state = readState(paths, context);
    if (state.generations.some((generation) => generation.participants
      .some((participant) => participant.host_session_hash === hostSessionHash))) {
      fail('duplicate host session attempted to join the barrier');
    }
    let generation = state.generations.find((candidate) => candidate.status === 'open');
    if (!generation) {
      if (state.generations.length >= GENERATIONS) fail('barrier generation capacity is exhausted');
      const openedAt = Date.now();
      generation = {
        generation: state.generations.length + 1,
        status: 'open',
        opened_at_ms: openedAt,
        opened_at: iso(openedAt),
        released_at_ms: null,
        released_at: null,
        completed_at_ms: null,
        completed_at: null,
        live_participants_at_release: 0,
        participants: [],
      };
      state.generations.push(generation);
    }
    if (generation.participants.length >= CAPACITY) fail('fifth participant attempted to join one barrier generation');
    const joinedAt = Math.max(Date.now(), generation.opened_at_ms);
    const participant = {
      host_session_hash: hostSessionHash,
      generation: generation.generation,
      pid: process.pid,
      joined_at_ms: joinedAt,
      joined_at: iso(joinedAt),
      passed_at_ms: null,
      passed_at: null,
    };
    createExclusiveJson(readyFile(paths, generation.generation, hostSessionHash), participant);
    createExclusiveJson(participantFile(paths, hostSessionHash), ledgerValue(context, sourceGitRevision, participant, generation));
    generation.participants.push(participant);

    if (generation.participants.length === CAPACITY) {
      if (generation.participants.some((candidate) => !processAlive(candidate.pid))) {
        generation.status = 'failed';
        core.atomicWriteJson(paths.state, state);
        fail('a barrier participant crashed before four-way release');
      }
      const releasedAt = Math.max(Date.now(), ...generation.participants.map((candidate) => candidate.joined_at_ms));
      generation.status = 'released';
      generation.released_at_ms = releasedAt;
      generation.released_at = iso(releasedAt);
      generation.live_participants_at_release = CAPACITY;
      createExclusiveJson(releaseFile(paths, generation.generation), {
        schema: BARRIER_SCHEMA,
        schema_version: 1,
        generation: generation.generation,
        released_at: generation.released_at,
        participants: generation.participants.map((candidate) => candidate.host_session_hash),
      });
    }
    core.atomicWriteJson(paths.state, state);
    return generation.generation;
  });
}

function acknowledge(paths, context, sourceGitRevision, hostSessionHash, generationNumber) {
  return core.withFileLock(paths.barrierLocks, 'barrier-state', () => {
    const state = readState(paths, context);
    const generation = state.generations[generationNumber - 1];
    if (!generation || !['released', 'completed'].includes(generation.status)) return null;
    const participant = generation.participants
      .find((candidate) => candidate.host_session_hash === hostSessionHash);
    if (!participant) fail('barrier participant disappeared before release');
    if (participant.passed_at_ms === null) {
      const passedAt = Math.max(Date.now(), generation.released_at_ms);
      participant.passed_at_ms = passedAt;
      participant.passed_at = iso(passedAt);
      core.atomicWriteJson(participantFile(paths, hostSessionHash), ledgerValue(context, sourceGitRevision, participant, generation));
    }
    if (generation.participants.every((candidate) => candidate.passed_at_ms !== null)
        && generation.status !== 'completed') {
      for (const candidate of generation.participants) {
        const file = readyFile(paths, generation.generation, candidate.host_session_hash);
        const ready = regularJson(file, 'barrier ready artifact');
        if (ready.host_session_hash !== candidate.host_session_hash || ready.generation !== generation.generation) {
          fail('barrier ready artifact identity drifted');
        }
        fs.unlinkSync(file);
      }
      const release = releaseFile(paths, generation.generation);
      const releaseValue = regularJson(release, 'barrier release artifact');
      if (releaseValue.generation !== generation.generation
          || releaseValue.participants.length !== CAPACITY) {
        fail('barrier release artifact identity drifted');
      }
      fs.unlinkSync(release);
      generation.status = 'completed';
      const completedAt = Math.max(Date.now(), ...generation.participants.map((candidate) => candidate.passed_at_ms));
      generation.completed_at_ms = completedAt;
      generation.completed_at = iso(completedAt);
    }
    core.atomicWriteJson(paths.state, state);
    return ledgerValue(context, sourceGitRevision, participant, generation);
  });
}

function waitForRelease(paths, context, sourceGitRevision, hostSessionHash, generationNumber, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() <= deadline) {
    const result = acknowledge(paths, context, sourceGitRevision, hostSessionHash, generationNumber);
    if (result) return result;
    const status = core.withFileLock(paths.barrierLocks, 'barrier-state', () => {
      const state = readState(paths, context);
      const generation = state.generations[generationNumber - 1];
      if (!generation) fail('barrier generation disappeared while waiting');
      if (generation.status === 'failed') fail('barrier generation failed before release');
      if (generation.status === 'open') {
        const crashed = generation.participants.find((participant) => !processAlive(participant.pid));
        if (crashed) {
          generation.status = 'failed';
          core.atomicWriteJson(paths.state, state);
          fail('a ready barrier participant crashed before release');
        }
      }
      return generation.status;
    });
    if (status !== 'open') continue;
    sleep(25);
  }
  core.withFileLock(paths.barrierLocks, 'barrier-state', () => {
    const state = readState(paths, context);
    const generation = state.generations[generationNumber - 1];
    if (generation?.status === 'open') {
      generation.status = 'failed';
      core.atomicWriteJson(paths.state, state);
    }
  });
  fail('timed out waiting for exactly four ready participants');
}

function register(sharedInput, pluginRootInput, sourceGitRevision, hostSessionId, options = {}) {
  if (!/^[a-f0-9]{40,64}$/.test(sourceGitRevision || '')) fail('source Git revision must be an exact SHA');
  if (typeof hostSessionId !== 'string' || !hostSessionId || hostSessionId.length > 4096 || /[\0\r\n]/.test(hostSessionId)) {
    fail('host session id is unsafe');
  }
  const timeoutMs = options.timeoutMs === undefined ? DEFAULT_TIMEOUT_MS : options.timeoutMs;
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 50 || timeoutMs > DEFAULT_TIMEOUT_MS) fail('barrier timeout is invalid');
  const pluginRoot = directory(pluginRootInput, 'plugin root');
  const paths = layout(sharedInput);
  const context = core.registerContext({
    recordsDir: paths.records,
    host: 'claude',
    sessionId: CONTENTION_SESSION,
    projectRoot: paths.project,
    pluginRoot,
    pluginData: paths.control,
    createdAt: '2026-01-01T00:00:00.000Z',
  });
  const hostSessionHash = core.sessionIdHash(hostSessionId);
  const generation = join(paths, context, sourceGitRevision, hostSessionHash);
  return waitForRelease(paths, context, sourceGitRevision, hostSessionHash, generation, timeoutMs);
}

function emptyDirectory(root, label) {
  if (fs.readdirSync(root).length !== 0) fail(`${label} is not clean`);
}

function verify(sharedInput, pluginRootInput, sourceGitRevision, expectedSessionHashes) {
  if (!/^[a-f0-9]{40,64}$/.test(sourceGitRevision || '')) fail('source Git revision must be an exact SHA');
  const pluginRoot = directory(pluginRootInput, 'plugin root');
  const paths = layout(sharedInput);
  const context = core.readContext({ recordsDir: paths.records, sessionId: CONTENTION_SESSION, expectedHost: 'claude' });
  if (context.plugin_root !== pluginRoot || context.plugin_data !== paths.control
      || context.project_root !== paths.project || context.source_revision !== context.runtime_digest) {
    fail('shared contention context drifted');
  }
  const recordFiles = fs.readdirSync(paths.records).filter((name) => name.endsWith('.json'));
  if (recordFiles.length !== 1) fail(`expected exactly one shared context record, found ${recordFiles.length}`);
  emptyDirectory(path.join(paths.control, 'session-control', 'v1', 'locks'), 'shared contention lock directory');
  emptyDirectory(paths.barrierLocks, 'barrier lock directory');
  emptyDirectory(paths.ready, 'barrier ready directory');
  emptyDirectory(paths.releases, 'barrier release directory');

  const state = validateState(regularJson(paths.state, 'barrier state'), context);
  if (state.generations.length !== GENERATIONS
      || state.generations.some((generation) => generation.status !== 'completed'
        || generation.participants.length !== CAPACITY
        || generation.live_participants_at_release !== CAPACITY)) {
    fail('barrier did not complete three generations of exactly four participants');
  }

  const expected = new Set(expectedSessionHashes || []);
  if (expected.size !== CAPACITY * GENERATIONS) fail('verifier requires 12 distinct expected host sessions');
  const files = fs.readdirSync(paths.participants).filter((name) => /^[a-f0-9]{64}\.json$/.test(name)).sort();
  if (files.length !== expected.size || fs.readdirSync(paths.participants).length !== files.length) {
    fail(`expected ${expected.size} clean participant ledgers, found ${files.length}`);
  }
  const observed = new Set();
  for (const generation of state.generations) {
    const generationHashes = new Set();
    const latestJoin = Math.max(...generation.participants.map((participant) => participant.joined_at_ms));
    const latestPass = Math.max(...generation.participants.map((participant) => participant.passed_at_ms));
    if (latestJoin > generation.released_at_ms || latestPass > generation.completed_at_ms) {
      fail(`generation ${generation.generation} timestamps do not prove barrier ordering`);
    }
    for (const participant of generation.participants) {
      const name = `${participant.host_session_hash.slice('sha256:'.length)}.json`;
      const value = regularJson(path.join(paths.participants, name), 'participant ledger');
      if (value.schema !== LEDGER_SCHEMA || value.schema_version !== 3 || value.host !== 'claude'
          || value.host_session_hash !== participant.host_session_hash
          || value.contention_context_hash !== context.session_id_hash
          || value.runtime_digest !== context.runtime_digest || value.source_revision !== context.runtime_digest
          || value.source_git_revision !== sourceGitRevision
          || value.generation !== generation.generation || value.joined_at !== participant.joined_at
          || value.barrier_released_at !== generation.released_at || value.passed_at !== participant.passed_at
          || value.live_participants_at_release !== CAPACITY) {
        fail(`invalid participant ledger entry: ${name}`);
      }
      generationHashes.add(value.host_session_hash);
      observed.add(value.host_session_hash);
    }
    if (generationHashes.size !== CAPACITY) fail(`generation ${generation.generation} reused a host session`);
  }
  if (observed.size !== expected.size || [...observed].some((hash) => !expected.has(hash))) {
    fail('participant ledger does not match the 12 unique host sessions');
  }
  return {
    context,
    participant_count: observed.size,
    generation_count: state.generations.length,
    barrier_capacity: CAPACITY,
    overlap_verified: true,
  };
}

module.exports = { CONTENTION_SESSION, register, verify };

if (require.main === module) {
  try {
    const [command, ...args] = process.argv.slice(2);
    if (command === 'register' && args.length === 4) {
      process.stdout.write(`${JSON.stringify(register(...args))}\n`);
    } else if (command === 'verify' && args.length === 4) {
      const [shared, root, revision, value] = args;
      process.stdout.write(`${JSON.stringify(verify(shared, root, revision, JSON.parse(value)))}\n`);
    } else {
      fail('usage: concurrency-control.js register SHARED ROOT GIT_REVISION HOST_SESSION | verify SHARED ROOT GIT_REVISION SESSION_HASHES_JSON');
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
