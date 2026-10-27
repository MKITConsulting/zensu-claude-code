'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { ensurePrivateDirectory } = require('./review-evidence-lease-v1.js');

const SCHEMA = 'stop-background-wait-v1';
const STORE_SEGMENTS = Object.freeze(['stop-background-wait', 'v1']);
const MEASURED_HOST_BUILD = '2.1.299';
const WAKING_TASK_TYPES = Object.freeze(['shell', 'monitor', 'subagent', 'workflow']);
const IN_FLIGHT_STATUSES = Object.freeze(['running', 'pending']);
const MARKER = 'ZENSU-AWAIT:';
const VERDICTS = Object.freeze(['wait', 'hint', 'nowait']);
const NOWAIT_REASONS = Object.freeze(['none', 'hinted', 'limit', 'hint-limit', 'fault']);
const SESSION_KEY_RE = /^scv1_[0-9a-f]{64}$/;
const STATE_FILE_RE = /^scv1_[0-9a-f]{64}\.json$/;
const TASK_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const AWAIT_LINE_RE = /^[ \t]*`?ZENSU-AWAIT:[ \t]*([A-Za-z0-9][A-Za-z0-9_-]{0,63})`?[ \t]*\r?$/gm;
const LIMITS = Object.freeze({
  releasesPerTask: 5,
  hintsPerGeneration: 3,
  maxTasks: 32,
  maxMessageChars: 64 * 1024,
  maxDescriptionChars: 80,
  maxPayloadBytes: 4 * 1024 * 1024,
  maxStateBytes: 64 * 1024,
  maxSweptEntries: 256,
  sweepAfterMs: 14 * 24 * 60 * 60 * 1000,
});

function limitsWith(overrides = {}) {
  return Object.freeze({ ...LIMITS, ...overrides });
}

function screenDescription(value, limits = LIMITS) {
  if (typeof value !== 'string') return '';
  const flat = value
    .replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Default_Ignorable_Code_Point}`"()]/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (flat.length <= limits.maxDescriptionChars) return flat;
  return `${flat.slice(0, limits.maxDescriptionChars - 1).trimEnd()}…`;
}

function inFlightTasks(payload, limits = LIMITS) {
  const entries = payload && Array.isArray(payload.background_tasks) ? payload.background_tasks : [];
  const seen = new Set();
  const tasks = [];
  for (const entry of entries) {
    if (tasks.length >= limits.maxTasks) break;
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) continue;
    if (typeof entry.id !== 'string' || !TASK_ID_RE.test(entry.id) || seen.has(entry.id)) continue;
    if (typeof entry.type !== 'string' || !WAKING_TASK_TYPES.includes(entry.type)) continue;
    if (typeof entry.status !== 'string' || !IN_FLIGHT_STATUSES.includes(entry.status)) continue;
    seen.add(entry.id);
    tasks.push({
      id: entry.id,
      type: entry.type,
      status: entry.status,
      description: screenDescription(entry.description, limits),
    });
  }
  return tasks;
}

function awaitedIds(payload, limits = LIMITS) {
  const ids = new Set();
  const message = payload ? payload.last_assistant_message : undefined;
  if (typeof message !== 'string' || message === '') return ids;
  const window = message.length > limits.maxMessageChars ? message.slice(-limits.maxMessageChars) : message;
  for (const match of window.matchAll(AWAIT_LINE_RE)) ids.add(match[1]);
  return ids;
}

function emptyState() {
  return { releases: {}, hinted: [], hints: 0 };
}

function statePath(pluginData, sessionKey) {
  if (typeof sessionKey !== 'string' || !SESSION_KEY_RE.test(sessionKey)) throw new Error('invalid session key');
  if (typeof pluginData !== 'string' || pluginData === '') throw new Error('plugin data unavailable');
  return path.join(pluginData, ...STORE_SEGMENTS, `${sessionKey}.json`);
}

function readBoundedFile(filePath, maxBytes) {
  let descriptor;
  try {
    const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0) | (fs.constants.O_NONBLOCK || 0);
    descriptor = fs.openSync(filePath, flags);
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile() || stat.size > maxBytes) return null;
    const buffer = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < stat.size) {
      const read = fs.readSync(descriptor, buffer, offset, stat.size - offset, offset);
      if (read === 0) break;
      offset += read;
    }
    return buffer.subarray(0, offset).toString('utf8');
  } catch {
    return null;
  } finally {
    if (descriptor !== undefined) {
      try { fs.closeSync(descriptor); } catch { }
    }
  }
}

function readState(file, limits = LIMITS) {
  const text = readBoundedFile(file, limits.maxStateBytes);
  if (text === null) return emptyState();
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    return emptyState();
  }
  if (!parsed || typeof parsed !== 'object' || parsed.schema !== SCHEMA) return emptyState();
  const state = emptyState();
  if (Number.isSafeInteger(parsed.hints) && parsed.hints > 0) state.hints = parsed.hints;
  if (parsed.releases && typeof parsed.releases === 'object' && !Array.isArray(parsed.releases)) {
    for (const [id, count] of Object.entries(parsed.releases)) {
      if (TASK_ID_RE.test(id) && Number.isSafeInteger(count) && count > 0) state.releases[id] = count;
    }
  }
  if (Array.isArray(parsed.hinted)) {
    state.hinted = [...new Set(parsed.hinted.filter((id) => typeof id === 'string' && TASK_ID_RE.test(id)))];
  }
  return state;
}

function pruneState(state, ids) {
  const keep = new Set(ids);
  const releases = {};
  for (const [id, count] of Object.entries(state.releases)) {
    if (keep.has(id)) releases[id] = count;
  }
  return { releases, hinted: state.hinted.filter((id) => keep.has(id)), hints: state.hints };
}

function sameState(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function sweepStale(directory, keep, limits = LIMITS, now = Date.now()) {
  let names;
  try { names = fs.readdirSync(directory); } catch { return 0; }
  let swept = 0;
  for (const name of names.slice(0, limits.maxSweptEntries)) {
    if (!STATE_FILE_RE.test(name) || name === keep) continue;
    const file = path.join(directory, name);
    try {
      const stat = fs.lstatSync(file);
      if (!stat.isFile() || now - stat.mtimeMs <= limits.sweepAfterMs) continue;
      fs.rmSync(file, { force: true });
      swept += 1;
    } catch { }
  }
  return swept;
}

function writeState(pluginData, sessionKey, state, limits = LIMITS, now = Date.now()) {
  statePath(pluginData, sessionKey);
  const directory = ensurePrivateDirectory(pluginData, STORE_SEGMENTS);
  const name = `${sessionKey}.json`;
  const text = `${JSON.stringify({ schema: SCHEMA, updated_at: new Date(now).toISOString(), releases: state.releases, hinted: state.hinted, hints: state.hints })}\n`;
  const temporary = path.join(directory, `.${name}.${crypto.randomBytes(6).toString('hex')}.tmp`);
  const descriptor = fs.openSync(temporary, 'wx', 0o600);
  try {
    fs.writeFileSync(descriptor, text);
    fs.fsyncSync(descriptor);
  } catch (error) {
    try { fs.closeSync(descriptor); } catch { }
    try { fs.unlinkSync(temporary); } catch { }
    throw error;
  }
  fs.closeSync(descriptor);
  try {
    fs.renameSync(temporary, path.join(directory, name));
  } catch (error) {
    try { fs.unlinkSync(temporary); } catch { }
    throw error;
  }
  sweepStale(directory, name, limits, now);
  return path.join(directory, name);
}

function clearState(options) {
  let file;
  try {
    file = statePath(options.pluginData, options.sessionKey);
  } catch {
    return false;
  }
  try {
    fs.rmSync(file, { force: true });
    return true;
  } catch {
    return false;
  }
}

function taskLabel(task) {
  return task.description ? `${task.id} (${task.type}: "${task.description}")` : `${task.id} (${task.type})`;
}

function renderHint(tasks, limits = LIMITS) {
  return [
    'STOP intercepted by zensu chain-enforcer.',
    `This session's review chain is still armed, and background work of this session is still running: ${tasks.map(taskLabel).join(', ')}.`,
    `If this turn is only waiting for one of these tasks, end the turn again with a final message that carries the line '${MARKER} <task id>' on a line of its own, naming that task: this guard then releases that Stop while the task runs, at most ${limits.releasesPerTask} times for each task, and the harness wakes this session when the task reports.`,
    'Never name a task this turn is not waiting for, such as a dev server: nothing wakes the session while such a task runs, so the review chain would stall until the next prompt.',
    'If this turn is not waiting for any of them, continue the review chain now; the next Stop repeats its full instruction.',
  ].join(' ');
}

function renderReleaseNote(tasks, release, limits = LIMITS) {
  const ids = tasks.map((task) => task.id).join(', ');
  return `zensu chain-enforcer: releasing this Stop while the background task(s) this turn waits for still run (${ids}); release ${release} of ${limits.releasesPerTask} for each. The review chain stays armed: when the task reports back, continue the current round.`;
}

function nowait(reason, tasks) {
  return {
    verdict: 'nowait',
    reason,
    tasks,
    lines: [`nowait reason=${reason} tasks=${tasks.length}`],
  };
}

function stopWait(payload, options = {}, limits = LIMITS) {
  const tasks = inFlightTasks(payload, limits);
  if (tasks.length === 0) return nowait('none', tasks);
  const now = options.now === undefined ? Date.now() : options.now;
  let file;
  let state;
  try {
    file = statePath(options.pluginData, options.sessionKey);
    state = readState(file, limits);
  } catch {
    return nowait('fault', tasks);
  }
  const ids = tasks.map((task) => task.id);
  const pruned = pruneState(state, ids);
  const persist = (next) => {
    if (sameState(next, state)) return true;
    try {
      writeState(options.pluginData, options.sessionKey, next, limits, now);
      return true;
    } catch {
      return false;
    }
  };
  const awaited = awaitedIds(payload, limits);
  const named = tasks.filter((task) => awaited.has(task.id));
  if (named.length > 0) {
    const eligible = named.filter((task) => (pruned.releases[task.id] || 0) < limits.releasesPerTask);
    if (eligible.length === 0) {
      persist(pruned);
      return nowait('limit', named);
    }
    const releases = { ...pruned.releases };
    for (const task of eligible) releases[task.id] = (releases[task.id] || 0) + 1;
    if (!persist({ releases, hinted: pruned.hinted, hints: pruned.hints })) return nowait('fault', tasks);
    const release = Math.max(...eligible.map((task) => releases[task.id]));
    return {
      verdict: 'wait',
      reason: 'named',
      tasks: eligible,
      release,
      lines: [
        `wait release=${release} max=${limits.releasesPerTask} tasks=${eligible.length} ids=${eligible.map((task) => task.id).join(',')}`,
        renderReleaseNote(eligible, release, limits),
      ],
    };
  }
  const fresh = tasks.filter((task) => !pruned.hinted.includes(task.id));
  if (fresh.length > 0) {
    if (pruned.hints >= limits.hintsPerGeneration) {
      persist(pruned);
      return nowait('hint-limit', tasks);
    }
    const hinted = [...pruned.hinted, ...fresh.map((task) => task.id)];
    if (!persist({ releases: pruned.releases, hinted, hints: pruned.hints + 1 })) {
      return nowait('fault', tasks);
    }
    return {
      verdict: 'hint',
      reason: 'unnamed',
      tasks,
      lines: [
        `hint tasks=${tasks.length} ids=${ids.join(',')}`,
        renderHint(tasks, limits),
      ],
    };
  }
  persist(pruned);
  return nowait('hinted', tasks);
}

function readStdin(maxBytes) {
  const raw = fs.readFileSync(0);
  if (raw.length > maxBytes) return null;
  return raw.toString('utf8');
}

function parsePayload(text) {
  if (typeof text !== 'string' || text === '') return null;
  try {
    const payload = JSON.parse(text);
    return payload && typeof payload === 'object' && !Array.isArray(payload) ? payload : null;
  } catch {
    return null;
  }
}

function main(argv, env = process.env, io = {}) {
  const mode = argv[0];
  const write = io.write || ((text) => process.stdout.write(text));
  const options = { pluginData: env.ZENSU_SBW_PLUGIN_DATA, sessionKey: env.ZENSU_SBW_SESSION_KEY };
  if (mode === 'stop-wait') {
    let result;
    try {
      const text = io.stdin !== undefined ? io.stdin : readStdin(LIMITS.maxPayloadBytes);
      result = stopWait(parsePayload(text) || {}, options);
    } catch {
      result = nowait('fault', []);
    }
    write(`${result.lines.join('\n')}\n`);
    return 0;
  }
  if (mode === 'clear') {
    write(`${clearState(options) ? 'cleared' : 'unavailable'}\n`);
    return 0;
  }
  process.stderr.write('usage: stop-background-wait-v1.js stop-wait|clear\n');
  return 2;
}

module.exports = {
  SCHEMA,
  STORE_SEGMENTS,
  MEASURED_HOST_BUILD,
  WAKING_TASK_TYPES,
  IN_FLIGHT_STATUSES,
  MARKER,
  VERDICTS,
  NOWAIT_REASONS,
  LIMITS,
  limitsWith,
  screenDescription,
  inFlightTasks,
  awaitedIds,
  statePath,
  readState,
  writeState,
  clearState,
  renderHint,
  renderReleaseNote,
  stopWait,
  main,
};

if (require.main === module) {
  let code = 0;
  try {
    code = main(process.argv.slice(2));
  } catch {
    code = 2;
  }
  process.exitCode = code;
}
