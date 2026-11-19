import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const mod = await import(new URL('../../plugins/session-hub/skills/session-trail/scripts/autopilot-runs-v1.mjs', import.meta.url));
const STATE_LIB = new URL('../../hooks/lib/zensu-autopilot-state.sh', import.meta.url);

const ESC = String.fromCharCode(27);
const C1 = String.fromCharCode(0x9b);
const LS = String.fromCharCode(0x2028);
const KEY = `scv1_${'a'.repeat(64)}`;
const OTHER = `scv1_${'b'.repeat(64)}`;
const SELF = `scv1_${'c'.repeat(64)}`;
const URL_238 = 'https://github.com/acme/city/pull/238';

const folderOf = () => fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-ar-')));
const stateDir = (folder) => {
  const dir = path.join(folder, '.zensu', 'state');
  fs.mkdirSync(dir, { recursive: true });
  return dir;
};
const runFile = (folder, runId) => path.join(stateDir(folder), `autopilot-run-${runId}.json`);
const writeRun = (folder, runId, extra = {}) => {
  const record = {
    schemaVersion: 1,
    runId,
    projectRoot: folder,
    workspaceRoot: folder,
    ownerSessionId: KEY,
    stage: 'TEAM_REVIEW',
    nextActionCode: 'RECONCILE_TEAM_REVIEW',
    evidence: { pr: { number: 238, url: URL_238, headSha: 'abc1234' } },
    ...extra,
  };
  const file = runFile(folder, runId);
  fs.writeFileSync(file, typeof extra === 'string' ? extra : JSON.stringify(record));
  return file;
};
const allText = (state) => [
  ...mod.autopilotRunLines(state, { pathText: (p) => `<${p}>` }),
  mod.autopilotShowLine(state) || '',
  ...mod.autopilotReleaseBlockers(state).map((b) => b.text),
];

test('a nonterminal run this session owns is read and classified as moving with its worktree', () => {
  const folder = folderOf();
  const file = writeRun(folder, 'run_a1');
  const state = mod.readAutopilotRuns([folder], KEY);
  assert.equal(state.measured, true);
  assert.equal(state.runs.length, 1);
  const run = state.runs[0];
  assert.equal(run.runId, 'run_a1');
  assert.equal(run.stage, 'TEAM_REVIEW');
  assert.equal(run.pendingStage, 'TEAM_REVIEW');
  assert.equal(run.nextActionCode, 'RECONCILE_TEAM_REVIEW');
  assert.deepEqual(run.pr, { number: 238, url: URL_238 });
  assert.equal(run.record, file);
  assert.equal(run.folder, folder);
  assert.equal(run.layout, 'own-tree');
  assert.equal(run.innerChain, false);
  assert.deepEqual(state.unreadable, []);
});

test('terminal runs and runs the running session owns are counted and never listed', () => {
  const folder = folderOf();
  writeRun(folder, 'run_self', { ownerSessionId: SELF });
  writeRun(folder, 'run_done', { stage: 'DONE', nextActionCode: 'NONE' });
  writeRun(folder, 'run_cancel', { stage: 'CANCELLED', nextActionCode: 'NONE' });
  writeRun(folder, 'run_old', { ownerSessionId: OTHER, stage: 'DONE', nextActionCode: 'NONE' });
  const state = mod.readAutopilotRuns([folder], KEY, SELF);
  assert.equal(state.runs.length, 0);
  assert.deepEqual(state.foreign, []);
  assert.equal(state.others, 2);
  assert.equal(state.terminal, 2);
  assert.deepEqual(mod.autopilotRunLines(state, {}), []);
  assert.equal(mod.autopilotShowLine(state), null);
  assert.deepEqual(mod.autopilotReleaseBlockers(state), []);
});

test('an unfinished run of a third session is counted, named on the show line and by release, and only counted in the section', () => {
  const folder = folderOf();
  writeRun(folder, 'run_third', { ownerSessionId: OTHER });
  writeRun(folder, 'run_third_tdd', { ownerSessionId: OTHER, stage: 'TDD_RUNNING', nextActionCode: 'AWAIT_TDD_CHAIN' });
  for (const selfKey of [SELF, null, () => { throw new Error('no core'); }]) {
    const state = mod.readAutopilotRuns([folder], KEY, selfKey);
    assert.deepEqual(state.foreign.map((run) => run.runId), ['run_third', 'run_third_tdd']);
    assert.equal(state.others, 2);
    assert.deepEqual(state.runs, []);
    const text = mod.autopilotRunLines(state, { pathText: (p) => p }).join('\n');
    assert.ok(text.startsWith("## Autopilot run\n\n**2 further unfinished Autopilot runs in the old session's tree name another session than the old one as their owner**"), text);
    assert.ok(!text.includes('run_third'), text);
    assert.equal(mod.autopilotShowLine(state), 'AUTOPILOT 2 unfinished Autopilot run(s) of another session sit in its tree, which release refuses to leave behind');
    const blockers = mod.autopilotReleaseBlockers(state, (p) => p);
    assert.deepEqual(blockers.map((b) => b.code), ['autopilot-foreign-run', 'autopilot-foreign-run']);
    assert.ok(blockers[0].text.includes('durable Autopilot run run_third at stage TEAM_REVIEW, whose record names another session than the old one as its owner'), blockers[0].text);
    assert.ok(blockers[0].text.includes(`continue it with /zensu:autopilot-adopt from a session whose project root is ${folder}`), blockers[0].text);
    assert.ok(blockers[1].text.includes('Its inner build chain is still running, so adoption refuses it'), blockers[1].text);
  }
  const mine = mod.readAutopilotRuns([folder], KEY, OTHER);
  assert.deepEqual(mine.foreign, []);
  assert.deepEqual(mod.autopilotReleaseBlockers(mine), []);
});

test('a run whose record drives a worktree below its project root is the nested layout, and a record without a working tree is not', () => {
  const folder = folderOf();
  writeRun(folder, 'run_nested', { workspaceRoot: path.join(folder, '.claude', 'worktrees', 'feature') });
  writeRun(folder, 'run_legacy', { workspaceRoot: undefined });
  const state = mod.readAutopilotRuns([folder], KEY);
  const byId = Object.fromEntries(state.runs.map((run) => [run.runId, run]));
  assert.equal(byId.run_nested.layout, 'nested-workspace');
  assert.equal(byId.run_nested.workspaceRoot, path.join(folder, '.claude', 'worktrees', 'feature'));
  assert.equal(byId.run_legacy.layout, 'own-tree');
  assert.equal(byId.run_legacy.workspaceRoot, null);
});

test('a run whose pending stage is TDD_RUNNING is an inner chain, directly and when blocked out of it', () => {
  const folder = folderOf();
  writeRun(folder, 'run_tdd', { stage: 'TDD_RUNNING', nextActionCode: 'AWAIT_TDD_CHAIN' });
  writeRun(folder, 'run_blk', { stage: 'BLOCKED', nextActionCode: 'AWAIT_RESUME', blocked: { from: 'TDD_RUNNING', code: 'tdd-retry-limit' } });
  writeRun(folder, 'run_gate', { stage: 'BLOCKED', nextActionCode: 'AWAIT_RESUME', blocked: { from: 'GATES', code: null } });
  const state = mod.readAutopilotRuns([folder], KEY);
  const byId = Object.fromEntries(state.runs.map((run) => [run.runId, run]));
  assert.equal(byId.run_tdd.innerChain, true);
  assert.equal(byId.run_blk.innerChain, true);
  assert.equal(byId.run_blk.pendingStage, 'TDD_RUNNING');
  assert.equal(byId.run_blk.blockedCode, 'tdd-retry-limit');
  assert.equal(byId.run_gate.innerChain, false);
  assert.equal(byId.run_gate.pendingStage, 'GATES');
  assert.equal(byId.run_gate.blockedCode, null);
});

test('every record that cannot be read is named with its reason', () => {
  const folder = folderOf();
  const dir = stateDir(folder);
  fs.mkdirSync(path.join(dir, 'autopilot-run-run_dir.json'));
  fs.writeFileSync(path.join(dir, 'autopilot-run-run_big.json'), 'x'.repeat(mod.RUN_RECORD_MAX_BYTES + 1));
  fs.writeFileSync(path.join(dir, 'autopilot-run-run_json.json'), '{not json');
  fs.writeFileSync(path.join(dir, 'autopilot-run-run_array.json'), '[]');
  writeRun(folder, 'run_name', { runId: 'run_other' });
  fs.writeFileSync(path.join(dir, 'autopilot-run-x.json'), '{}');
  writeRun(folder, 'run_owner', { ownerSessionId: 7 });
  writeRun(folder, 'run_stage', { stage: 'team_review' });
  writeRun(folder, 'run_from', { stage: 'BLOCKED', blocked: { from: 7 } });
  writeRun(folder, 'run_root', { projectRoot: 'relative/root' });
  writeRun(folder, 'run_ws', { workspaceRoot: `${folder}${ESC}x` });
  const state = mod.readAutopilotRuns([folder], KEY);
  const reasons = Object.fromEntries(state.unreadable.map((entry) => [path.basename(entry.file), entry.reason]));
  assert.equal(reasons['autopilot-run-run_dir.json'], 'it is not a regular file');
  assert.equal(reasons['autopilot-run-run_big.json'], `it is larger than ${mod.RUN_RECORD_MAX_BYTES} bytes`);
  assert.equal(reasons['autopilot-run-run_json.json'], 'it does not parse as JSON');
  assert.equal(reasons['autopilot-run-run_array.json'], 'it is not a run record');
  assert.equal(reasons['autopilot-run-run_name.json'], 'it names another run id than its file name');
  assert.equal(reasons['autopilot-run-x.json'], 'its name carries no run id');
  assert.equal(reasons['autopilot-run-run_owner.json'], 'it names no owner');
  assert.equal(reasons['autopilot-run-run_stage.json'], 'its stage is not readable');
  assert.equal(reasons['autopilot-run-run_from.json'], 'it is blocked without a readable pending stage');
  assert.equal(reasons['autopilot-run-run_root.json'], 'it names no usable project root');
  assert.equal(reasons['autopilot-run-run_ws.json'], 'it names no usable working tree');
  assert.equal(state.unreadable.length, 11);
  assert.equal(state.runs.length, 0);
});

test('a linked record, a hard-linked record and a linked state folder hold no readable run', (t) => {
  const folder = folderOf();
  const target = writeRun(folder, 'run_target', { ownerSessionId: OTHER });
  const dir = path.dirname(target);
  try {
    fs.symlinkSync(target, path.join(dir, 'autopilot-run-run_link.json'));
  } catch {
    t.skip('this host cannot create a symbolic link');
    return;
  }
  fs.linkSync(target, path.join(dir, 'autopilot-run-run_hard.json'));
  const behind = folderOf();
  writeRun(behind, 'run_behind_link');
  const linked = folderOf();
  fs.symlinkSync(path.join(behind, '.zensu'), path.join(linked, '.zensu'));
  const stateLinked = folderOf();
  fs.mkdirSync(path.join(stateLinked, '.zensu'));
  fs.symlinkSync(path.join(behind, '.zensu', 'state'), path.join(stateLinked, '.zensu', 'state'));
  const state = mod.readAutopilotRuns([folder, linked, stateLinked], KEY);
  const reasons = Object.fromEntries(state.unreadable.map((entry) => [path.basename(entry.file), entry.reason]));
  assert.equal(reasons['autopilot-run-run_link.json'], 'it is a symbolic link');
  assert.equal(reasons['autopilot-run-run_hard.json'], 'it is a hard link');
  assert.equal(reasons['autopilot-run-run_target.json'], 'it is a hard link');
  assert.deepEqual(state.directories, [dir]);
  assert.ok(!state.runs.some((run) => run.runId === 'run_behind_link'));
});

test('a folder, a .zensu or a state directory that cannot be inspected or listed is named unreadable and blocks release', (t) => {
  if (process.platform === 'win32' || (typeof process.getuid === 'function' && process.getuid() === 0)) {
    t.skip('permission bits do not deny this process on this host');
    return;
  }
  const listing = folderOf();
  writeRun(listing, 'run_unlisted');
  const listingState = stateDir(listing);
  const stateless = folderOf();
  writeRun(stateless, 'run_uninspected');
  const statelessZensu = path.join(stateless, '.zensu');
  const zensuless = folderOf();
  writeRun(zensuless, 'run_unreached');
  fs.chmodSync(listingState, 0o300);
  fs.chmodSync(statelessZensu, 0o600);
  fs.chmodSync(zensuless, 0o600);
  t.after(() => {
    fs.chmodSync(listingState, 0o700);
    fs.chmodSync(statelessZensu, 0o700);
    fs.chmodSync(zensuless, 0o700);
  });
  const state = mod.readAutopilotRuns([listing, stateless, zensuless], KEY);
  assert.deepEqual(state.unreadable.map((entry) => [entry.file, entry.reason]), [
    [path.join(statelessZensu, 'state'), 'it could not be inspected'],
    [path.join(zensuless, '.zensu'), 'it could not be inspected'],
    [listingState, 'its listing could not be read'],
  ]);
  assert.deepEqual(state.directories, [listingState]);
  assert.equal(state.runs.length, 0);
  const blockers = mod.autopilotReleaseBlockers(state, (p) => p);
  assert.equal(blockers[0].code, 'autopilot-unreadable');
  assert.ok(blockers[0].text.startsWith('3 Autopilot run record(s) in the old session\'s tree could not be read'));
});

test('the owner key is asked for only when a run record exists, and a key that cannot be computed leaves the tree unattributed', () => {
  const empty = folderOf();
  let asked = 0;
  const none = mod.readAutopilotRuns([empty, path.join(empty, 'gone')], () => { asked += 1; return KEY; });
  assert.equal(asked, 0);
  assert.equal(none.measured, true);
  assert.deepEqual(none.directories, []);
  const folder = folderOf();
  writeRun(folder, 'run_a1');
  writeRun(folder, 'run_a2');
  const once = mod.readAutopilotRuns([folder], () => { asked += 1; return KEY; });
  assert.equal(asked, 1);
  assert.equal(once.runs.length, 2);
  for (const ownerKey of [() => null, () => { throw new Error('no core'); }, '']) {
    const state = mod.readAutopilotRuns([folder], ownerKey);
    assert.equal(state.measured, false);
    assert.match(state.reason, /could not be computed/);
    assert.deepEqual(state.runs, []);
    const lines = mod.autopilotRunLines(state, {});
    assert.equal(lines[0], '## Autopilot run');
    assert.match(lines[1], /^_Not attributed: /);
    assert.equal(mod.autopilotReleaseBlockers(state)[0].code, 'autopilot-unattributed');
    assert.match(mod.autopilotShowLine(state), /^AUTOPILOT not attributed: /);
  }
});

test('a state directory named by two folders is read once, and a folder that is not absolute is never read', () => {
  const folder = folderOf();
  writeRun(folder, 'run_a1');
  const state = mod.readAutopilotRuns(new Set([folder, folder, path.join(folder, '.'), 'relative']), KEY);
  assert.equal(state.directories.length, 1);
  assert.equal(state.runs.length, 1);
});

test('the reads stop at their byte budget, count what they left out and name the remedy that clears the block', () => {
  const folder = folderOf();
  for (let i = 0; i < 5; i += 1) writeRun(folder, `run_${String(i).padStart(3, '0')}`, { ownerSessionId: OTHER, stage: 'DONE', nextActionCode: 'NONE' });
  const size = fs.statSync(runFile(folder, 'run_000')).size;
  const state = mod.readAutopilotRuns([folder], KEY, null, size * 3);
  assert.equal(state.others, 3);
  assert.equal(state.truncated, 2);
  const lines = mod.autopilotRunLines(state, {});
  assert.ok(lines.some((line) => line.includes(`2 further run record(s) were not read, past the read budget of ${mod.RUN_READ_BUDGET_BYTES / mod.RUN_RECORD_MAX_BYTES} MiB of run records; once the records of finished runs that are no longer needed are removed from that state directory, the rest are read`)), lines.join('\n'));
  const [blocker] = mod.autopilotReleaseBlockers(state);
  assert.equal(blocker.code, 'autopilot-unreadable');
  assert.ok(blocker.text.includes('2 of them lie past the read budget'), blocker.text);
  assert.equal(mod.readAutopilotRuns([folder], KEY).truncated, 0);
  assert.equal(mod.RUN_READ_BUDGET_BYTES, 256 * mod.RUN_RECORD_MAX_BYTES);
});

test('a pull request is kept only when its URL has the pull-request shape and ends in its number, and renders as a link', () => {
  const folder = folderOf();
  const cases = {
    run_gh: [{ number: 238, url: URL_238 }, true],
    run_gl: [{ number: 12, url: 'https://gitlab.com/acme/city/-/merge_requests/12' }, true],
    run_issue: [{ number: 238, url: 'https://github.com/acme/city/issues/238' }, false],
    run_other: [{ number: 239, url: URL_238 }, false],
    run_http: [{ number: 238, url: 'http://github.com/acme/city/pull/238' }, false],
    run_query: [{ number: 238, url: `${URL_238}?x=1` }, false],
    run_big: [{ number: mod.PR_NUMBER_MAX + 1, url: `https://github.com/acme/city/pull/${mod.PR_NUMBER_MAX + 1}` }, false],
  };
  for (const [id, [pr]] of Object.entries(cases)) writeRun(folder, id, { evidence: { pr } });
  const state = mod.readAutopilotRuns([folder], KEY);
  const byId = Object.fromEntries(state.runs.map((run) => [run.runId, run]));
  for (const [id, [pr, kept]] of Object.entries(cases)) assert.deepEqual(byId[id].pr, kept ? pr : null, id);
  const lines = mod.autopilotRunLines(state, { pathText: (p) => p });
  assert.ok(lines.includes(`- pull request: [#238](${URL_238})`));
  assert.ok(lines.includes('- pull request: [#12](https://gitlab.com/acme/city/-/merge_requests/12)'));
  assert.equal(lines.filter((line) => line.startsWith('- pull request: ')).length, 2);
});

test('the pull-request shape is the one both trail.mjs copies use', () => {
  for (const copy of ['../../skills/session-trail/scripts/trail.mjs', '../../plugins/session-hub/skills/session-trail/scripts/trail.mjs']) {
    const src = fs.readFileSync(new URL(copy, import.meta.url), 'utf8');
    const line = src.match(/^const PR_URL_SHAPE = \/(.*)\/;$/m);
    assert.ok(line, `${copy} no longer spells PR_URL_SHAPE on one line`);
    assert.equal(line[1], mod.PR_URL_SHAPE.source, copy);
  }
});

test('a record of another schema version is named unreadable, and the version is the one the state library validates', () => {
  const folder = folderOf();
  writeRun(folder, 'run_v2', { schemaVersion: 2 });
  writeRun(folder, 'run_v0', { schemaVersion: undefined });
  const state = mod.readAutopilotRuns([folder], KEY);
  const reasons = Object.fromEntries(state.unreadable.map((entry) => [path.basename(entry.file), entry.reason]));
  assert.equal(reasons['autopilot-run-run_v2.json'], 'its schema version is not 1, the one this reader knows');
  assert.equal(reasons['autopilot-run-run_v0.json'], 'its schema version is not 1, the one this reader knows');
  assert.deepEqual(state.runs, []);
  const lib = fs.readFileSync(STATE_LIB, 'utf8');
  assert.ok(lib.includes(`if (state.schemaVersion !== ${mod.RUN_SCHEMA_VERSION} || !identifier(state.runId)`));
});

test('the section names the run, its stage, next action, pull request and record, and the move route with the guided adoption', () => {
  const folder = folderOf();
  const file = writeRun(folder, 'run_a1');
  const lines = mod.autopilotRunLines(mod.readAutopilotRuns([folder], KEY), { pathText: (p) => `<${p}>`, when: 'WHEN-CLAUSE' });
  const text = lines.join('\n');
  assert.equal(lines[0], '## Autopilot run');
  assert.match(text, /The old session drives a durable Autopilot run that stays with it unless you carry it over\./);
  assert.match(text, /carry it over WHEN-CLAUSE\./);
  assert.ok(lines.includes('### Run `run_a1`'));
  assert.ok(lines.includes('- stage: `TEAM_REVIEW`, next action `RECONCILE_TEAM_REVIEW`'));
  assert.ok(lines.includes(`- pull request: [#238](${URL_238})`));
  assert.ok(lines.includes(`- record: \`<${file}>\``));
  const route = lines.find((line) => line.startsWith('- route: '));
  assert.ok(route.includes(`its record lives in the worktree \`<${folder}>\` and moves with that tree`));
  assert.ok(route.includes('git worktree move'));
  assert.ok(route.includes('`/zensu:autopilot-adopt` with the moved worktree as its working directory'));
  assert.ok(route.includes('The create route leaves the run with the old session'));
  assert.ok(text.includes('`/zensu:autopilot-release` cancels one'));
});

test('an inner chain gets the finish-or-release text and a nested layout the stay-in-place text', () => {
  const folder = folderOf();
  writeRun(folder, 'run_tdd', { stage: 'BLOCKED', nextActionCode: 'AWAIT_RESUME', blocked: { from: 'TDD_RUNNING', code: 'tdd-retry-limit' } });
  writeRun(folder, 'run_nested', { workspaceRoot: path.join(folder, 'wt') });
  const state = mod.readAutopilotRuns([folder], KEY);
  const lines = mod.autopilotRunLines(state, { pathText: (p) => p });
  const block = (id) => {
    const at = lines.indexOf(`### Run \`${id}\``);
    return lines.slice(at, at + 5).join('\n');
  };
  const tdd = block('run_tdd');
  assert.ok(tdd.includes('- stage: `BLOCKED` (blocked from `TDD_RUNNING` with code `tdd-retry-limit`), next action `AWAIT_RESUME`'));
  assert.ok(tdd.includes('its inner build chain is still running under the old session'));
  assert.ok(tdd.includes('`/zensu:autopilot-adopt` refuses this run'));
  assert.ok(tdd.includes('cancels the run with `/zensu:autopilot-release`'));
  assert.ok(!tdd.includes('git worktree move'));
  const nested = block('run_nested');
  assert.ok(nested.includes(`its record lives in the project root \`${folder}\` and drives the worktree \`${path.join(folder, 'wt')}\` below it`));
  assert.ok(nested.includes('Do not move that worktree'));
  assert.ok(nested.includes(`Continue the run from a session whose project root is \`${folder}\` by running \`/zensu:autopilot-adopt\` there`));
  assert.ok(!nested.includes('git worktree move'));
  assert.match(lines[1], /The old session drives 2 durable Autopilot runs that stay with it unless you carry them over\./);
});

test('a run whose project root lies inside the worktree it drives is its own layout, told to stay in place and continue from its project root', () => {
  const tree = folderOf();
  const folder = path.join(tree, 'service');
  fs.mkdirSync(folder);
  const oldTree = path.join(os.tmpdir(), 'zensu-ar-gone', 'feature');
  writeRun(folder, 'run_sub', { projectRoot: path.join(oldTree, 'service'), workspaceRoot: oldTree });
  const state = mod.readAutopilotRuns([folder], KEY);
  assert.equal(state.runs.length, 1);
  const run = state.runs[0];
  assert.equal(run.layout, 'project-root-in-worktree');
  assert.equal(run.tree, tree);
  const lines = mod.autopilotRunLines(state, { pathText: (p) => p });
  const route = lines.find((line) => line.startsWith('- route: '));
  assert.ok(route.includes(`its record lives in \`${folder}\`, a directory inside the worktree \`${tree}\` it drives, and moves with that tree`), route);
  assert.ok(route.includes('Do not move that worktree.'), route);
  assert.ok(route.includes(`Continue the run from a session whose project root is \`${folder}\` by running \`/zensu:autopilot-adopt\` there`), route);
  assert.ok(!route.includes('git worktree move'), route);
  const [blocker] = mod.autopilotReleaseBlockers(state, (p) => p);
  assert.equal(blocker.code, 'autopilot-run');
  assert.ok(blocker.text.includes(`Its record lives in ${folder}, inside the worktree ${tree}`), blocker.text);
  assert.ok(blocker.text.includes('Moving that worktree does not carry the run over'), blocker.text);
  const sibling = folderOf();
  writeRun(sibling, 'run_side', { workspaceRoot: path.join(path.dirname(sibling), 'elsewhere') });
  assert.equal(mod.readAutopilotRuns([sibling], KEY).runs[0].layout, 'nested-workspace');
});

test('every cancel names the project root it runs from and excludes the old session, and a layout whose record moves says the cancel ends with the move', () => {
  const folder = folderOf();
  writeRun(folder, 'run_own');
  writeRun(folder, 'run_nest', { workspaceRoot: path.join(folder, 'wt') });
  writeRun(folder, 'run_tdd', { stage: 'TDD_RUNNING', nextActionCode: 'AWAIT_TDD_CHAIN' });
  const state = mod.readAutopilotRuns([folder], KEY);
  const lines = mod.autopilotRunLines(state, { pathText: (p) => p });
  const routeOf = (id) => lines[lines.indexOf(`### Run \`${id}\``) + 4];
  const cancelFrom = `\`/zensu:autopilot-release\` from a session whose project root is \`${folder}\`, other than the old session`;
  const endsWithMove = 'only before that worktree moves, because `/zensu:autopilot-release` no longer reaches the run once it has';
  for (const id of ['run_own', 'run_nest', 'run_tdd']) assert.ok(routeOf(id).includes(cancelFrom), routeOf(id));
  assert.ok(routeOf('run_own').includes(endsWithMove), routeOf('run_own'));
  assert.ok(routeOf('run_tdd').includes(endsWithMove), routeOf('run_tdd'));
  assert.ok(!routeOf('run_nest').includes(endsWithMove), routeOf('run_nest'));
  const blockers = mod.autopilotReleaseBlockers(state, (p) => p);
  const byRun = Object.fromEntries(blockers.map((b) => [b.text.match(/Autopilot run (\S+) at stage/)[1], b.text]));
  for (const id of ['run_own', 'run_nest', 'run_tdd']) {
    assert.ok(byRun[id].includes(`cancel it with /zensu:autopilot-release from a session whose project root is ${folder}, other than the old session`), byRun[id]);
  }
  assert.ok(byRun.run_own.includes('other than the old session, before that worktree moves'), byRun.run_own);
  assert.ok(byRun.run_tdd.includes('other than the old session, before that worktree moves'), byRun.run_tdd);
  assert.ok(!byRun.run_nest.includes('before that worktree moves'), byRun.run_nest);
});

test('an unreadable record is named unreadable in the section, the show line and the release blockers', () => {
  const folder = folderOf();
  fs.writeFileSync(path.join(stateDir(folder), 'autopilot-run-run_bad.json'), '{');
  const state = mod.readAutopilotRuns([folder], KEY);
  const lines = mod.autopilotRunLines(state, { pathText: (p) => p });
  assert.ok(lines.some((line) => line.startsWith('**One Autopilot run record in the old session\'s tree could not be read**')));
  assert.ok(lines.includes(`- \`${path.join(folder, '.zensu', 'state', 'autopilot-run-run_bad.json')}\` is **unreadable**: it does not parse as JSON`));
  assert.equal(mod.autopilotShowLine(state), 'AUTOPILOT 1 Autopilot run record(s) in its tree could not be read; takeover or handoff names the route that carries each over');
  const blockers = mod.autopilotReleaseBlockers(state, (p) => p);
  assert.equal(blockers.length, 1);
  assert.equal(blockers[0].code, 'autopilot-unreadable');
  assert.ok(blockers[0].text.includes('it does not parse as JSON'));
});

test('the show line is one line that names each run', () => {
  const folder = folderOf();
  writeRun(folder, 'run_a1');
  assert.equal(mod.autopilotShowLine(mod.readAutopilotRuns([folder], KEY)), 'AUTOPILOT the session shown owns the durable Autopilot run run_a1 at TEAM_REVIEW (PR #238); takeover or handoff names the route that carries it over');
  writeRun(folder, 'run_a2', { stage: 'GATES', nextActionCode: 'RUN_GATES', evidence: { pr: null } });
  const two = mod.autopilotShowLine(mod.readAutopilotRuns([folder], KEY));
  assert.equal(two, 'AUTOPILOT the session shown owns 2 durable Autopilot runs: run_a1 at TEAM_REVIEW (PR #238), run_a2 at GATES; takeover or handoff names the route that carries each over');
  assert.ok(!two.includes('\n'));
});

test('release blocks on an owned run with a route per layout, and never on a terminal one or one the running session owns', () => {
  const folder = folderOf();
  writeRun(folder, 'run_own');
  writeRun(folder, 'run_nest', { workspaceRoot: path.join(folder, 'wt') });
  writeRun(folder, 'run_tdd', { stage: 'TDD_RUNNING', nextActionCode: 'AWAIT_TDD_CHAIN' });
  writeRun(folder, 'run_done', { stage: 'DONE', nextActionCode: 'NONE' });
  writeRun(folder, 'run_mine', { ownerSessionId: SELF });
  const blockers = mod.autopilotReleaseBlockers(mod.readAutopilotRuns([folder], KEY, SELF), (p) => p);
  const byRun = Object.fromEntries(blockers.map((b) => [b.text.match(/Autopilot run (\S+) at stage/)[1], b]));
  assert.deepEqual(Object.keys(byRun).sort(), ['run_nest', 'run_own', 'run_tdd']);
  assert.ok(blockers.every((b) => b.code === 'autopilot-run'));
  assert.ok(byRun.run_own.text.includes(`Its record lives in the worktree ${folder}, so freeing that worktree would let Claude Desktop delete the run with it.`));
  assert.ok(byRun.run_own.text.includes('move that worktree into your project root and run /zensu:autopilot-adopt from inside it'));
  assert.ok(byRun.run_nest.text.includes(`Continue it with /zensu:autopilot-adopt from a session whose project root is ${folder}`));
  assert.ok(byRun.run_tdd.text.includes('Its inner build chain is still running, so adoption refuses it'));
});

test('a relocation claim is read as an interrupted move whoever owns it, and release refuses while it is there', () => {
  const folder = folderOf();
  const claimOf = (file, runId) => {
    const claim = path.join(path.dirname(file), `autopilot-relocating-${runId}.json`);
    fs.renameSync(file, claim);
    return claim;
  };
  const own = claimOf(writeRun(folder, 'run_cl'), 'run_cl');
  const foreign = claimOf(writeRun(folder, 'run_cf', { ownerSessionId: OTHER }), 'run_cf');
  claimOf(writeRun(folder, 'run_cd', { stage: 'DONE', nextActionCode: 'NONE' }), 'run_cd');
  fs.writeFileSync(path.join(stateDir(folder), 'autopilot-relocating-bad name.json'), '{}');
  const state = mod.readAutopilotRuns([folder], KEY);
  assert.equal(state.runs.length, 0);
  assert.equal(state.foreign.length, 0);
  assert.deepEqual(state.claims.map((run) => [run.runId, run.owned, run.record]), [['run_cf', false, foreign], ['run_cl', true, own]]);
  assert.deepEqual(state.unreadable.map((entry) => [path.basename(entry.file), entry.reason]), [['autopilot-relocating-bad name.json', 'its name carries no run id']]);
  const lines = mod.autopilotRunLines(state, { pathText: (p) => p });
  assert.ok(lines.includes('## Autopilot run'));
  assert.ok(lines.some((line) => line.includes("Moves of 2 durable Autopilot runs were interrupted in the old session's tree")));
  assert.ok(lines.includes(`- \`run_cl\` at \`TEAM_REVIEW\`, next action \`RECONCILE_TEAM_REVIEW\`: the claim \`${own}\` waits for \`/zensu:autopilot-adopt\` from a session whose project root contains \`${folder}\`, standing inside \`${folder}\``));
  assert.match(mod.autopilotShowLine(state), /the relocation claim of 2 Autopilot runs: run_cf at TEAM_REVIEW, run_cl at TEAM_REVIEW in its tree as what may be the only copy/);
  const blockers = mod.autopilotReleaseBlockers(state, (p) => p).filter((b) => b.code === 'autopilot-claim');
  assert.deepEqual(blockers.map((b) => b.text.match(/Autopilot run (\S+) at stage/)[1]), ['run_cf', 'run_cl']);
  assert.ok(blockers[1].text.includes(`Finish the move with /zensu:autopilot-adopt from a session whose project root contains ${folder}, standing inside ${folder}, then run release again.`));
  const none = mod.readAutopilotRuns([folderOf()], KEY);
  assert.deepEqual(none.claims, []);
  assert.deepEqual(mod.autopilotRunLines(none), []);
});

test('an own-tree work-order run keeps its worktree in the brief and in the release blocker', () => {
  const folder = folderOf();
  writeRun(folder, 'run_wo', { workOrder: { id: 'wo_1' } });
  writeRun(folder, 'run_plain');
  const state = mod.readAutopilotRuns([folder], KEY);
  const byId = Object.fromEntries(state.runs.map((run) => [run.runId, run]));
  assert.equal(byId.run_wo.workOrder, true);
  assert.equal(byId.run_plain.workOrder, false);
  const lines = mod.autopilotRunLines(state, { pathText: (p) => p });
  const route = (runId) => lines.slice(lines.indexOf(`### Run \`${runId}\``)).find((line) => line.startsWith('- route: '));
  assert.ok(route('run_wo').includes('it is a work-order run, whose plan lives in the `.zensu/plans` of that worktree'));
  assert.ok(route('run_wo').includes(`Do not move that worktree. Continue the run from a session whose project root is \`${folder}\``));
  assert.ok(!route('run_wo').includes('git worktree move'));
  assert.ok(route('run_plain').includes('git worktree move'));
  const blockers = mod.autopilotReleaseBlockers(state, (p) => p);
  const byRun = Object.fromEntries(blockers.map((b) => [b.text.match(/Autopilot run (\S+) at stage/)[1], b.text]));
  assert.ok(byRun.run_wo.includes(`It is a work-order run, so moving that worktree does not carry it over: continue it with /zensu:autopilot-adopt from a session whose project root is ${folder}`));
  assert.ok(!byRun.run_wo.includes('move that worktree into your project root'));
  assert.ok(byRun.run_plain.includes('move that worktree into your project root'));
});

test('no rendered line quotes a confirmation flag or the CLI helper, and no record value carries a control character into one', () => {
  const folder = folderOf();
  writeRun(folder, 'run_own', { nextActionCode: `RUN${ESC}X`, evidence: { pr: { number: 9, url: `https://example.test/${C1}` } } });
  writeRun(folder, 'run_nest', { workspaceRoot: path.join(folder, 'wt'), blocked: { from: 'GATES', code: `x${LS}y` }, stage: 'BLOCKED', nextActionCode: 'AWAIT_RESUME' });
  writeRun(folder, 'run_tdd', { stage: 'TDD_RUNNING', nextActionCode: 'AWAIT_TDD_CHAIN' });
  writeRun(folder, 'run_third', { ownerSessionId: OTHER, stage: 'BLOCKED', nextActionCode: 'AWAIT_RESUME', blocked: { from: 'GATES', code: `x${ESC}y` } });
  fs.writeFileSync(path.join(stateDir(folder), 'autopilot-run-run_bad.json'), '{');
  const state = mod.readAutopilotRuns([folder], KEY);
  assert.equal(state.foreign.length, 1);
  const byId = Object.fromEntries(state.runs.map((run) => [run.runId, run]));
  assert.equal(byId.run_own.nextActionCode, null);
  assert.equal(byId.run_own.pr, null);
  assert.equal(byId.run_nest.blockedCode, null);
  const unattributed = mod.readAutopilotRuns([folder], () => null);
  for (const line of [...allText(state), ...allText(unattributed)]) {
    assert.ok(!line.includes('--confirm'), line);
    assert.ok(!line.includes('zensu-log.sh'), line);
    assert.ok(![ESC, C1, LS].some((c) => line.includes(c)), JSON.stringify(line));
  }
});

test('the run vocabulary matches the state library it mirrors', () => {
  const lib = fs.readFileSync(STATE_LIB, 'utf8');
  const terminal = lib.match(/^const TERMINAL = new Set\(\[([^\]]*)\]\);$/m);
  assert.ok(terminal, 'the state library no longer spells its TERMINAL set on one line');
  assert.deepEqual(JSON.parse(`[${terminal[1]}]`), [...mod.TERMINAL_STAGES]);
  assert.match(lib, /^const MAX_BYTES = 1024 \* 1024;$/m);
  assert.equal(mod.RUN_RECORD_MAX_BYTES, 1024 * 1024);
  assert.ok(lib.includes('const envelope = /^autopilot-run-(.*)\\.json$/;'));
  assert.equal(mod.RUN_ENVELOPE.source, '^autopilot-run-(.*)\\.json$');
  assert.ok(lib.includes('const claimNameOf = id => `autopilot-relocating-${id}.json`;'));
  assert.equal(mod.CLAIM_ENVELOPE.source, '^autopilot-relocating-(.*)\\.json$');
  assert.ok(lib.includes('if (relocation === "worktree" && Object.prototype.hasOwnProperty.call(state, "workOrder")) {'));
  assert.ok(lib.includes(`&& value.length >= ${mod.RUN_ID_MIN} && value.length <= ${mod.RUN_ID_MAX} && /${mod.RUN_ID_SHAPE.source}/.test(value);`));
  assert.equal(mod.runIdOk('a'.repeat(mod.RUN_ID_MIN)), true);
  assert.equal(mod.runIdOk('a'.repeat(mod.RUN_ID_MIN - 1)), false);
  assert.equal(mod.runIdOk('a'.repeat(mod.RUN_ID_MAX)), true);
  assert.equal(mod.runIdOk('a'.repeat(mod.RUN_ID_MAX + 1)), false);
  const stages = lib.match(/^const STAGES = new Set\(\[([^\]]*)\]\);$/m);
  assert.ok(stages, 'the state library no longer spells its STAGES set as one literal');
  for (const stage of JSON.parse(`[${stages[1].replace(/,\s*$/, '')}]`)) assert.match(stage, mod.STAGE_SHAPE);
  const actions = lib.match(/^const NEXT_ACTION = Object\.freeze\(\{([^}]*)\}\);$/m);
  assert.ok(actions, 'the state library no longer spells its NEXT_ACTION table as one literal');
  for (const code of actions[1].match(/"([A-Z_]+)"/g)) assert.match(code.slice(1, -1), mod.ACTION_SHAPE);
});
