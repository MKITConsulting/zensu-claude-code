import fs from 'node:fs';
import path from 'node:path';

export const RUN_RECORD_MAX_BYTES = 1024 * 1024;
export const RUN_FILES_MAX = 64;
export const TERMINAL_STAGES = Object.freeze(['DONE', 'CANCELLED']);
export const RUN_ENVELOPE = /^autopilot-run-(.*)\.json$/;
export const RUN_ID_SHAPE = /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/;

export const STAGE_SHAPE = /^[A-Z][A-Z_]{1,31}$/;
export const ACTION_SHAPE = /^[A-Z][A-Z_]{1,63}$/;
const UNSAFE = /[\u0000-\u001f\u007f-\u009f\u2028\u2029\p{Cf}]/u;
const URL_UNSAFE = /[\s`<>\u0000-\u001f\u007f-\u009f\u2028\u2029\p{Cf}]/u;

const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

export function runIdOk(value) {
  return typeof value === 'string' && value.length >= 3 && value.length <= 128 && RUN_ID_SHAPE.test(value);
}

function rootOf(value) {
  return typeof value === 'string' && value.length > 0 && value.length <= 4096 && !UNSAFE.test(value) && path.isAbsolute(value) ? value : null;
}

function prOf(evidence) {
  const pr = isObject(evidence) && isObject(evidence.pr) ? evidence.pr : null;
  if (!pr || !Number.isSafeInteger(pr.number) || pr.number <= 0) return null;
  const url = pr.url;
  if (typeof url !== 'string' || url.length > 2048 || !url.startsWith('https://') || URL_UNSAFE.test(url)) return null;
  return { number: pr.number, url };
}

function directoryVerdict(target) {
  let stat;
  try { stat = fs.lstatSync(target); } catch (error) {
    return error && (error.code === 'ENOENT' || error.code === 'ENOTDIR') ? 'absent' : 'unreadable';
  }
  if (stat.isSymbolicLink() || !stat.isDirectory()) return 'absent';
  return 'directory';
}

function readBounded(file) {
  let before;
  try { before = fs.lstatSync(file); } catch { return { error: 'it vanished or could not be inspected' }; }
  if (before.isSymbolicLink()) return { error: 'it is a symbolic link' };
  if (!before.isFile()) return { error: 'it is not a regular file' };
  if (before.nlink !== 1) return { error: 'it is a hard link' };
  if (before.size > RUN_RECORD_MAX_BYTES) return { error: `it is larger than ${RUN_RECORD_MAX_BYTES} bytes` };
  const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0) | (fs.constants.O_NONBLOCK || 0);
  let fd = null;
  try {
    fd = fs.openSync(file, flags);
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.nlink !== 1 || stat.size > RUN_RECORD_MAX_BYTES || stat.ino !== before.ino || stat.dev !== before.dev) {
      return { error: 'it changed while it was read' };
    }
    const bytes = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < bytes.length) {
      const read = fs.readSync(fd, bytes, offset, bytes.length - offset, offset);
      if (read === 0) break;
      offset += read;
    }
    return { text: bytes.subarray(0, offset).toString('utf8') };
  } catch {
    return { error: 'it could not be read' };
  } finally {
    if (fd !== null) {
      try { fs.closeSync(fd); } catch { }
    }
  }
}

export function stateDirectories(folders) {
  const directories = [];
  const unreadable = [];
  const seen = new Set();
  for (const folder of folders || []) {
    if (typeof folder !== 'string' || !path.isAbsolute(folder)) continue;
    const zensu = path.join(folder, '.zensu');
    const zensuVerdict = directoryVerdict(zensu);
    if (zensuVerdict === 'unreadable') unreadable.push({ file: zensu, reason: 'it could not be inspected' });
    if (zensuVerdict !== 'directory') continue;
    const state = path.join(zensu, 'state');
    const stateVerdict = directoryVerdict(state);
    if (stateVerdict === 'unreadable') unreadable.push({ file: state, reason: 'it could not be inspected' });
    if (stateVerdict !== 'directory') continue;
    let key = state;
    try { key = fs.realpathSync.native(state); } catch { key = state; }
    if (seen.has(key)) continue;
    seen.add(key);
    directories.push(state);
  }
  return { directories, unreadable };
}

function classify(file, parsed, folder) {
  const stage = parsed.stage;
  if (typeof stage !== 'string' || !STAGE_SHAPE.test(stage)) return { error: 'its stage is not readable' };
  if (TERMINAL_STAGES.includes(stage)) return { terminal: true };
  let pendingStage = stage;
  let blockedCode = null;
  if (stage === 'BLOCKED') {
    const blocked = isObject(parsed.blocked) ? parsed.blocked : null;
    if (!blocked || typeof blocked.from !== 'string' || !STAGE_SHAPE.test(blocked.from)) return { error: 'it is blocked without a readable pending stage' };
    pendingStage = blocked.from;
    blockedCode = runIdOk(blocked.code) ? blocked.code : null;
  }
  const projectRoot = rootOf(parsed.projectRoot);
  if (!projectRoot) return { error: 'it names no usable project root' };
  let workspaceRoot = null;
  if (parsed.workspaceRoot !== undefined && parsed.workspaceRoot !== null) {
    workspaceRoot = rootOf(parsed.workspaceRoot);
    if (!workspaceRoot) return { error: 'it names no usable working tree' };
  }
  const nextActionCode = typeof parsed.nextActionCode === 'string' && ACTION_SHAPE.test(parsed.nextActionCode) ? parsed.nextActionCode : null;
  return {
    run: {
      runId: parsed.runId,
      stage,
      pendingStage,
      blockedCode,
      nextActionCode,
      pr: prOf(parsed.evidence),
      projectRoot,
      workspaceRoot,
      record: file,
      folder,
      layout: workspaceRoot !== null && workspaceRoot !== projectRoot ? 'nested-workspace' : 'own-tree',
      innerChain: pendingStage === 'TDD_RUNNING',
    },
  };
}

export function readAutopilotRuns(folders, ownerKey) {
  const found = stateDirectories(folders);
  const state = {
    measured: true,
    reason: null,
    directories: found.directories,
    runs: [],
    unreadable: [...found.unreadable],
    others: 0,
    terminal: 0,
    truncated: 0,
  };
  let key;
  let keyResolved = false;
  const owner = () => {
    if (!keyResolved) {
      keyResolved = true;
      try { key = typeof ownerKey === 'function' ? ownerKey() : ownerKey; } catch { key = null; }
      if (typeof key !== 'string' || key === '') key = null;
    }
    return key;
  };
  for (const directory of found.directories) {
    let names;
    try { names = fs.readdirSync(directory, { encoding: 'utf8' }); } catch {
      state.unreadable.push({ file: directory, reason: 'its listing could not be read' });
      continue;
    }
    const files = names.filter((name) => RUN_ENVELOPE.test(name)).sort();
    if (files.length > RUN_FILES_MAX) state.truncated += files.length - RUN_FILES_MAX;
    for (const name of files.slice(0, RUN_FILES_MAX)) {
      const file = path.join(directory, name);
      const id = RUN_ENVELOPE.exec(name)[1];
      if (!runIdOk(id)) {
        state.unreadable.push({ file, reason: 'its name carries no run id' });
        continue;
      }
      const read = readBounded(file);
      if (read.error) {
        state.unreadable.push({ file, reason: read.error });
        continue;
      }
      let parsed;
      try { parsed = JSON.parse(read.text); } catch {
        state.unreadable.push({ file, reason: 'it does not parse as JSON' });
        continue;
      }
      if (!isObject(parsed)) {
        state.unreadable.push({ file, reason: 'it is not a run record' });
        continue;
      }
      if (parsed.runId !== id) {
        state.unreadable.push({ file, reason: 'it names another run id than its file name' });
        continue;
      }
      if (typeof parsed.ownerSessionId !== 'string' || parsed.ownerSessionId === '') {
        state.unreadable.push({ file, reason: 'it names no owner' });
        continue;
      }
      const sessionKey = owner();
      if (sessionKey === null) {
        return {
          ...state,
          measured: false,
          reason: 'the Session Control key of the session could not be computed, so no run record could be attributed to it',
          runs: [],
        };
      }
      if (parsed.ownerSessionId !== sessionKey) {
        state.others += 1;
        continue;
      }
      const verdict = classify(file, parsed, path.dirname(path.dirname(directory)));
      if (verdict.error) state.unreadable.push({ file, reason: verdict.error });
      else if (verdict.terminal) state.terminal += 1;
      else state.runs.push(verdict.run);
    }
  }
  return state;
}

function stageText(run) {
  const blocked = run.stage === 'BLOCKED'
    ? ` (blocked from \`${run.pendingStage}\`${run.blockedCode ? ` with code \`${run.blockedCode}\`` : ''})`
    : '';
  const next = run.nextActionCode ? `, next action \`${run.nextActionCode}\`` : '';
  return `\`${run.stage}\`${blocked}${next}`;
}

function routeText(run, pathText) {
  if (run.innerChain) {
    return 'its inner build chain is still running under the old session (pending stage `TDD_RUNNING`), so `/zensu:autopilot-adopt` refuses this run, and moving its worktree does not carry it over. Two exits exist: the old session finishes that chain, after which the run can be carried over as its layout allows, or the user cancels the run with `/zensu:autopilot-release`. Put that choice in the plan confirmation and move nothing before it is made.';
  }
  if (run.layout === 'nested-workspace') {
    return `its record lives in the project root \`${pathText(run.folder)}\` and drives the worktree \`${pathText(run.workspaceRoot)}\` below it. Do not move that worktree: the record stays in that project root, and a run whose worktree moved away no longer finds the tree it drives. Continue the run from a session whose project root is \`${pathText(run.folder)}\` by running \`/zensu:autopilot-adopt\` there; a session rooted anywhere else cannot take it over.`;
  }
  return `its record lives in the worktree \`${pathText(run.folder)}\` and moves with that tree. To continue the run here, take the move route of the worktree advice: move that worktree into this session's project root with \`git worktree move\`, then run \`/zensu:autopilot-adopt\` with the moved worktree as its working directory. Its report says the run moves into this project; once the user agrees, the run continues under this session from its stage. The create route leaves the run with the old session: say so in the plan confirmation, and expect \`release\` to refuse to free that worktree while the run is still in it.`;
}

export function autopilotRunLines(state, options = {}) {
  const pathText = typeof options.pathText === 'function' ? options.pathText : (value) => String(value);
  const when = typeof options.when === 'string' && options.when ? options.when : 'after the user has confirmed the plan';
  if (state.measured && !state.runs.length && !state.unreadable.length && !state.truncated) return [];
  const L = ['## Autopilot run'];
  if (!state.measured) {
    L.push(`_Not attributed: ${state.reason}. This session's tree holds Autopilot run records, so ask the user whether one of them belongs to this session before that tree is moved or released._`);
    return L;
  }
  const n = state.runs.length;
  if (n) {
    const runs = n === 1 ? 'a durable Autopilot run that stays' : `${n} durable Autopilot runs that stay`;
    L.push(`**This session drives ${runs} with it unless you carry ${n === 1 ? 'it' : 'them'} over.** An Autopilot run is a project-local state machine that carries a feature from its approved plan to a ready pull request. Its record names this session as its owner, so the pipeline stands still while this session is gone, and a takeover alone does not move it. Name every run below in the plan confirmation with the route its block gives, and carry it over ${when}. Whether a run continues or ends is the user's decision: \`/zensu:autopilot-adopt\` continues a run and \`/zensu:autopilot-release\` cancels one, each first reports what it would do and changes nothing until the user agrees, and adoption comes first because a cancel cannot be undone.`);
  }
  for (const run of state.runs) {
    L.push('');
    L.push(`### Run \`${run.runId}\``);
    L.push(`- stage: ${stageText(run)}`);
    if (run.pr) L.push(`- pull request: #${run.pr.number} ${run.pr.url}`);
    L.push(`- record: \`${pathText(run.record)}\``);
    L.push(`- route: ${routeText(run, pathText)}`);
  }
  const unread = state.unreadable.length + state.truncated;
  if (unread) {
    L.push('');
    L.push(`**${unread === 1 ? 'One Autopilot run record' : `${unread} Autopilot run records`} in this session's tree could not be read**, so a run it still owns may be among them. Name ${unread === 1 ? 'it' : 'them'} in the plan confirmation, and move or release that tree only after the user has looked at ${unread === 1 ? 'it' : 'them'}.`);
    for (const entry of state.unreadable) L.push(`- \`${pathText(entry.file)}\` is **unreadable**: ${entry.reason}`);
    if (state.truncated) L.push(`- ${state.truncated} further run record(s) were not read, past the bound of ${RUN_FILES_MAX} per state directory`);
  }
  return L;
}

export function autopilotShowLine(state) {
  if (!state.measured) return `AUTOPILOT not attributed: ${state.reason}; run takeover or handoff before moving or releasing its tree`;
  const runs = state.runs.map((run) => `${run.runId} at ${run.stage}${run.pr ? ` (PR #${run.pr.number})` : ''}`);
  const unread = state.unreadable.length + state.truncated;
  if (!runs.length && !unread) return null;
  const parts = [];
  if (runs.length === 1) parts.push(`this session owns the durable Autopilot run ${runs[0]}`);
  else if (runs.length) parts.push(`this session owns ${runs.length} durable Autopilot runs: ${runs.join(', ')}`);
  if (unread) parts.push(`${unread} Autopilot run record(s) in its tree could not be read`);
  return `AUTOPILOT ${parts.join('; ')}; takeover or handoff names the route that carries ${runs.length === 1 && !unread ? 'it' : 'each'} over`;
}

export function autopilotReleaseBlockers(state, pathText = (value) => String(value)) {
  const blockers = [];
  if (!state.measured) {
    blockers.push({ code: 'autopilot-unattributed', text: `The old session's tree holds Autopilot run records that could not be attributed (${state.reason}), so release cannot rule out a run it still owns.` });
    return blockers;
  }
  for (const run of state.runs) {
    let where;
    let route;
    if (run.layout === 'nested-workspace') {
      where = `Its record lives in the project root ${pathText(run.folder)}, and the run stays tied to the old session until it is adopted or cancelled.`;
      route = `Continue it with /zensu:autopilot-adopt from a session whose project root is ${pathText(run.folder)}, or cancel it with /zensu:autopilot-release, then run release again.`;
    } else {
      where = `Its record lives in the worktree ${pathText(run.folder)}, so freeing that worktree would let Claude Desktop delete the run with it.`;
      route = 'Carry it over first: move that worktree into your project root and run /zensu:autopilot-adopt from inside it, or cancel the run with /zensu:autopilot-release, then run release again.';
    }
    if (run.innerChain) route = 'Its inner build chain is still running, so adoption refuses it: let the old session finish that chain, or cancel the run with /zensu:autopilot-release, then run release again.';
    blockers.push({ code: 'autopilot-run', text: `The old session still owns the durable Autopilot run ${run.runId} at stage ${run.stage}. ${where} ${route}` });
  }
  const unread = state.unreadable.length + state.truncated;
  if (unread) {
    const first = state.unreadable[0];
    const named = first ? ` (${pathText(first.file)}: ${first.reason})` : '';
    blockers.push({ code: 'autopilot-unreadable', text: `${unread} Autopilot run record(s) in the old session's tree could not be read${named}, so release cannot rule out a run it still owns. Look at ${unread === 1 ? 'it' : 'them'}, then run release again.` });
  }
  return blockers;
}
