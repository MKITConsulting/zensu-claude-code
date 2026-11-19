import fs from 'node:fs';
import path from 'node:path';

export const RUN_RECORD_MAX_BYTES = 1024 * 1024;
export const RUN_READ_BUDGET_BYTES = 256 * RUN_RECORD_MAX_BYTES;
export const RUN_SCHEMA_VERSION = 1;
export const TERMINAL_STAGES = Object.freeze(['DONE', 'CANCELLED']);
export const RUN_ENVELOPE = /^autopilot-run-(.*)\.json$/;
export const RUN_ID_SHAPE = /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/;
export const RUN_ID_MIN = 3;
export const RUN_ID_MAX = 128;
export const PR_URL_SHAPE = /^https:\/\/[A-Za-z0-9._-]+\/[A-Za-z0-9._\-/]+\/(?:pull|merge_requests|-\/merge_requests)\/\d{1,9}$/;
export const PR_NUMBER_MAX = 999999999;

export const STAGE_SHAPE = /^[A-Z][A-Z_]{1,31}$/;
export const ACTION_SHAPE = /^[A-Z][A-Z_]{1,63}$/;
const UNSAFE = /[\u0000-\u001f\u007f-\u009f\u2028\u2029\p{Cf}]/u;

const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

export function runIdOk(value) {
  return typeof value === 'string' && value.length >= RUN_ID_MIN && value.length <= RUN_ID_MAX && RUN_ID_SHAPE.test(value);
}

function layoutOf(projectRoot, workspaceRoot) {
  if (workspaceRoot === null || workspaceRoot === projectRoot) return 'own-tree';
  const inside = path.relative(workspaceRoot, projectRoot);
  return inside !== '' && inside !== '..' && !inside.startsWith(`..${path.sep}`) && !path.isAbsolute(inside)
    ? 'project-root-in-worktree'
    : 'nested-workspace';
}

function rootOf(value) {
  return typeof value === 'string' && value.length > 0 && value.length <= 4096 && !UNSAFE.test(value) && path.isAbsolute(value) ? value : null;
}

function prOf(evidence) {
  const pr = isObject(evidence) && isObject(evidence.pr) ? evidence.pr : null;
  if (!pr || !Number.isSafeInteger(pr.number) || pr.number <= 0 || pr.number > PR_NUMBER_MAX) return null;
  const url = pr.url;
  if (typeof url !== 'string' || url.length > 2048 || !PR_URL_SHAPE.test(url) || !url.endsWith(`/${pr.number}`)) return null;
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

function readBounded(file, remaining) {
  let before;
  try { before = fs.lstatSync(file); } catch { return { error: 'it vanished or could not be inspected' }; }
  if (before.isSymbolicLink()) return { error: 'it is a symbolic link' };
  if (!before.isFile()) return { error: 'it is not a regular file' };
  if (before.nlink !== 1) return { error: 'it is a hard link' };
  if (before.size > RUN_RECORD_MAX_BYTES) return { error: `it is larger than ${RUN_RECORD_MAX_BYTES} bytes` };
  if (before.size > remaining) return { overBudget: true };
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
    return { text: bytes.subarray(0, offset).toString('utf8'), size: stat.size };
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
  const layout = layoutOf(projectRoot, workspaceRoot);
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
      layout,
      tree: layout === 'project-root-in-worktree' ? path.resolve(folder, path.relative(projectRoot, workspaceRoot)) : null,
      innerChain: pendingStage === 'TDD_RUNNING',
    },
  };
}

export function readAutopilotRuns(folders, ownerKey, selfKey = null, budgetBytes = RUN_READ_BUDGET_BYTES) {
  const found = stateDirectories(folders);
  const state = {
    measured: true,
    reason: null,
    directories: found.directories,
    runs: [],
    foreign: [],
    unreadable: [...found.unreadable],
    others: 0,
    terminal: 0,
    truncated: 0,
  };
  const lazyKey = (source) => {
    let key;
    let resolved = false;
    return () => {
      if (!resolved) {
        resolved = true;
        try { key = typeof source === 'function' ? source() : source; } catch { key = null; }
        if (typeof key !== 'string' || key === '') key = null;
      }
      return key;
    };
  };
  const owner = lazyKey(ownerKey);
  const self = lazyKey(selfKey);
  let budget = budgetBytes;
  for (const directory of found.directories) {
    let names;
    try { names = fs.readdirSync(directory, { encoding: 'utf8' }); } catch {
      state.unreadable.push({ file: directory, reason: 'its listing could not be read' });
      continue;
    }
    const files = names.filter((name) => RUN_ENVELOPE.test(name)).sort();
    for (const name of files) {
      const file = path.join(directory, name);
      const id = RUN_ENVELOPE.exec(name)[1];
      if (!runIdOk(id)) {
        state.unreadable.push({ file, reason: 'its name carries no run id' });
        continue;
      }
      const read = readBounded(file, budget);
      if (read.overBudget) {
        state.truncated += 1;
        continue;
      }
      if (read.error) {
        state.unreadable.push({ file, reason: read.error });
        continue;
      }
      budget -= read.size;
      let parsed;
      try { parsed = JSON.parse(read.text); } catch {
        state.unreadable.push({ file, reason: 'it does not parse as JSON' });
        continue;
      }
      if (!isObject(parsed)) {
        state.unreadable.push({ file, reason: 'it is not a run record' });
        continue;
      }
      if (parsed.schemaVersion !== RUN_SCHEMA_VERSION) {
        state.unreadable.push({ file, reason: `its schema version is not ${RUN_SCHEMA_VERSION}, the one this reader knows` });
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
      const folder = path.dirname(path.dirname(directory));
      if (parsed.ownerSessionId !== sessionKey) {
        state.others += 1;
        if (parsed.ownerSessionId === self()) continue;
        const other = classify(file, parsed, folder);
        if (!other.error && !other.terminal) state.foreign.push(other.run);
        continue;
      }
      const verdict = classify(file, parsed, folder);
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

function cancelText(run, pathText) {
  const moving = run.layout === 'nested-workspace'
    ? ''
    : ', and only before that worktree moves, because `/zensu:autopilot-release` no longer reaches the run once it has';
  return `\`/zensu:autopilot-release\` from a session whose project root is \`${pathText(run.folder)}\`, other than the old session${moving}`;
}

function routeText(run, pathText) {
  if (run.innerChain) {
    return `its inner build chain is still running under the old session (pending stage \`TDD_RUNNING\`), so \`/zensu:autopilot-adopt\` refuses this run, and moving its worktree does not carry it over. Two exits exist: the old session finishes that chain, after which the run can be carried over as its layout allows, or the user cancels the run with ${cancelText(run, pathText)}. Put that choice in the plan confirmation and move nothing before it is made.`;
  }
  if (run.layout === 'nested-workspace') {
    return `its record lives in the project root \`${pathText(run.folder)}\` and drives the worktree \`${pathText(run.workspaceRoot)}\` below it. Do not move that worktree: the record stays in that project root, and a run whose worktree moved away no longer finds the tree it drives. Continue the run from a session whose project root is \`${pathText(run.folder)}\` by running \`/zensu:autopilot-adopt\` there; a session rooted anywhere else cannot take it over. To cancel it instead, run ${cancelText(run, pathText)}.`;
  }
  if (run.layout === 'project-root-in-worktree') {
    return `its record lives in \`${pathText(run.folder)}\`, a directory inside the worktree \`${pathText(run.tree)}\` it drives, and moves with that tree, but \`/zensu:autopilot-adopt\` does not carry a run whose project root lies inside its worktree into another project. Do not move that worktree. Continue the run from a session whose project root is \`${pathText(run.folder)}\` by running \`/zensu:autopilot-adopt\` there; a session rooted anywhere else cannot take it over. To cancel it instead, run ${cancelText(run, pathText)}.`;
  }
  return `its record lives in the worktree \`${pathText(run.folder)}\` and moves with that tree. To continue the run here, take the move route of the worktree advice: move that worktree into this session's project root with \`git worktree move\`, then run \`/zensu:autopilot-adopt\` with the moved worktree as its working directory. Its report says the run moves into this project; once the user agrees, the run continues under this session from its stage. After the move the old session no longer reaches the run, so while its last turn lies inside the owner-activity window of that skill, one hour by default, the report refuses and names the window, and the adoption waits until it has passed. The create route leaves the run with the old session: say so in the plan confirmation, and expect \`release\` to refuse to free that worktree while the run is still in it. To cancel the run instead, run ${cancelText(run, pathText)}.`;
}

export function autopilotRunLines(state, options = {}) {
  const pathText = typeof options.pathText === 'function' ? options.pathText : (value) => String(value);
  const when = typeof options.when === 'string' && options.when ? options.when : 'after the user has confirmed the plan';
  if (state.measured && !state.runs.length && !state.unreadable.length && !state.truncated && !state.foreign.length) return [];
  const L = ['## Autopilot run'];
  if (!state.measured) {
    L.push(`_Not attributed: ${state.reason}. The old session's tree holds Autopilot run records, so ask the user whether one of them belongs to the old session before that tree is moved or released._`);
    return L;
  }
  const n = state.runs.length;
  if (n) {
    const runs = n === 1 ? 'a durable Autopilot run that stays' : `${n} durable Autopilot runs that stay`;
    L.push(`**The old session drives ${runs} with it unless you carry ${n === 1 ? 'it' : 'them'} over.** An Autopilot run is a project-local state machine that carries a feature from its approved plan to a ready pull request. Its record names the old session as its owner, so the pipeline stands still while the old session is gone, and a takeover alone does not move it. Name every run below in the plan confirmation with the route its block gives, and carry it over ${when}. Whether a run continues or ends is the user's decision: \`/zensu:autopilot-adopt\` continues a run and \`/zensu:autopilot-release\` cancels one, each first reports what it would do and changes nothing until the user agrees, and adoption comes first because a cancel cannot be undone.`);
  }
  for (const run of state.runs) {
    L.push('');
    L.push(`### Run \`${run.runId}\``);
    L.push(`- stage: ${stageText(run)}`);
    if (run.pr) L.push(`- pull request: [#${run.pr.number}](${run.pr.url})`);
    L.push(`- record: \`${pathText(run.record)}\``);
    L.push(`- route: ${routeText(run, pathText)}`);
  }
  const unread = state.unreadable.length + state.truncated;
  if (unread) {
    L.push('');
    L.push(`**${unread === 1 ? 'One Autopilot run record' : `${unread} Autopilot run records`} in the old session's tree could not be read**, so a run it still owns may be among them. Name ${unread === 1 ? 'it' : 'them'} in the plan confirmation, and move or release that tree only after the user has looked at ${unread === 1 ? 'it' : 'them'}.`);
    for (const entry of state.unreadable) L.push(`- \`${pathText(entry.file)}\` is **unreadable**: ${entry.reason}`);
    if (state.truncated) L.push(`- ${state.truncated} further run record(s) were not read, past the read budget of ${RUN_READ_BUDGET_BYTES / RUN_RECORD_MAX_BYTES} MiB of run records; once the records of finished runs that are no longer needed are removed from that state directory, the rest are read`);
  }
  const foreign = state.foreign.length;
  if (foreign) {
    L.push('');
    L.push(`**${foreign === 1 ? 'One further unfinished Autopilot run' : `${foreign} further unfinished Autopilot runs`} in the old session's tree ${foreign === 1 ? 'names' : 'name'} another session than the old one as ${foreign === 1 ? 'its' : 'their'} owner**, for example an earlier id of the old session after a fork or a resume. This takeover does not carry ${foreign === 1 ? 'it' : 'them'}, and \`release\` refuses to free that tree while ${foreign === 1 ? 'it is' : 'they are'} there and names ${foreign === 1 ? 'it' : 'each'}. Say so in the plan confirmation, and move or release that tree only after the user has said which session drives ${foreign === 1 ? 'it' : 'them'}.`);
  }
  return L;
}

export function autopilotShowLine(state) {
  if (!state.measured) return `AUTOPILOT not attributed: ${state.reason}; run takeover or handoff before moving or releasing its tree`;
  const runs = state.runs.map((run) => `${run.runId} at ${run.stage}${run.pr ? ` (PR #${run.pr.number})` : ''}`);
  const unread = state.unreadable.length + state.truncated;
  const foreign = state.foreign.length;
  if (!runs.length && !unread && !foreign) return null;
  const parts = [];
  if (runs.length === 1) parts.push(`the session shown owns the durable Autopilot run ${runs[0]}`);
  else if (runs.length) parts.push(`the session shown owns ${runs.length} durable Autopilot runs: ${runs.join(', ')}`);
  if (unread) parts.push(`${unread} Autopilot run record(s) in its tree could not be read`);
  if (foreign) parts.push(`${foreign} unfinished Autopilot run(s) of another session sit in its tree, which release refuses to leave behind`);
  const route = runs.length || unread ? `; takeover or handoff names the route that carries ${runs.length === 1 && !unread ? 'it' : 'each'} over` : '';
  return `AUTOPILOT ${parts.join('; ')}${route}`;
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
    const moving = run.layout === 'nested-workspace' ? '' : ', before that worktree moves';
    const cancel = `cancel it with /zensu:autopilot-release from a session whose project root is ${pathText(run.folder)}, other than the old session${moving}`;
    if (run.layout === 'nested-workspace') {
      where = `Its record lives in the project root ${pathText(run.folder)}, and the run stays tied to the old session until it is adopted or cancelled.`;
      route = `Continue it with /zensu:autopilot-adopt from a session whose project root is ${pathText(run.folder)}, or ${cancel}, then run release again.`;
    } else if (run.layout === 'project-root-in-worktree') {
      where = `Its record lives in ${pathText(run.folder)}, inside the worktree ${pathText(run.tree)}, so freeing that worktree would let Claude Desktop delete the run with it.`;
      route = `Moving that worktree does not carry the run over: continue it with /zensu:autopilot-adopt from a session whose project root is ${pathText(run.folder)}, or ${cancel}, then run release again.`;
    } else {
      where = `Its record lives in the worktree ${pathText(run.folder)}, so freeing that worktree would let Claude Desktop delete the run with it.`;
      route = `Carry it over first: move that worktree into your project root and run /zensu:autopilot-adopt from inside it, or ${cancel}, then run release again.`;
    }
    if (run.innerChain) route = `Its inner build chain is still running, so adoption refuses it: let the old session finish that chain, or ${cancel}, then run release again.`;
    blockers.push({ code: 'autopilot-run', text: `The old session still owns the durable Autopilot run ${run.runId} at stage ${run.stage}. ${where} ${route}` });
  }
  const unread = state.unreadable.length + state.truncated;
  if (unread) {
    const first = state.unreadable[0];
    const named = first ? ` (${pathText(first.file)}: ${first.reason})` : '';
    const budget = state.truncated
      ? ` ${state.truncated} of them lie past the read budget of ${RUN_READ_BUDGET_BYTES / RUN_RECORD_MAX_BYTES} MiB of run records; once the records of finished runs that are no longer needed are removed from that state directory, release reads the rest.`
      : '';
    blockers.push({ code: 'autopilot-unreadable', text: `${unread} Autopilot run record(s) in the old session's tree could not be read${named}, so release cannot rule out a run it still owns.${budget} Look at ${unread === 1 ? 'it' : 'them'}, then run release again.` });
  }
  for (const run of state.foreign) {
    const route = run.innerChain
      ? `Its inner build chain is still running, so adoption refuses it: let the session that drives that chain finish it, or cancel the run with /zensu:autopilot-release from a session whose project root is ${pathText(run.folder)}, then run release again.`
      : `Ask the user which session drives it, then continue it with /zensu:autopilot-adopt from a session whose project root is ${pathText(run.folder)}, or cancel it with /zensu:autopilot-release from such a session, then run release again.`;
    blockers.push({ code: 'autopilot-foreign-run', text: `The old session's tree holds the durable Autopilot run ${run.runId} at stage ${run.stage}, whose record names another session than the old one as its owner, so freeing that tree would let Claude Desktop delete the run with it. ${route}` });
  }
  return blockers;
}
