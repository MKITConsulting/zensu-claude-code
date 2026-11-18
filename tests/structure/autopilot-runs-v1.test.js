import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const mod = await import(new URL('../../skills/session-trail/scripts/autopilot-runs-v1.mjs', import.meta.url));
const STATE_LIB = new URL('../../hooks/lib/zensu-autopilot-state.sh', import.meta.url);

const ESC = String.fromCharCode(27);
const C1 = String.fromCharCode(0x9b);
const LS = String.fromCharCode(0x2028);
const KEY = `scv1_${'a'.repeat(64)}`;
const OTHER = `scv1_${'b'.repeat(64)}`;
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

test('runs of another owner and terminal runs are counted and never listed', () => {
  const folder = folderOf();
  writeRun(folder, 'run_foreign', { ownerSessionId: OTHER });
  writeRun(folder, 'run_done', { stage: 'DONE', nextActionCode: 'NONE' });
  writeRun(folder, 'run_cancel', { stage: 'CANCELLED', nextActionCode: 'NONE' });
  const state = mod.readAutopilotRuns([folder], KEY);
  assert.equal(state.runs.length, 0);
  assert.equal(state.others, 1);
  assert.equal(state.terminal, 2);
  assert.deepEqual(mod.autopilotRunLines(state, {}), []);
  assert.equal(mod.autopilotShowLine(state), null);
  assert.deepEqual(mod.autopilotReleaseBlockers(state), []);
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
  const linked = folderOf();
  fs.symlinkSync(path.join(folder, '.zensu'), path.join(linked, '.zensu'));
  const state = mod.readAutopilotRuns([folder, linked], KEY);
  const reasons = Object.fromEntries(state.unreadable.map((entry) => [path.basename(entry.file), entry.reason]));
  assert.equal(reasons['autopilot-run-run_link.json'], 'it is a symbolic link');
  assert.equal(reasons['autopilot-run-run_hard.json'], 'it is a hard link');
  assert.equal(reasons['autopilot-run-run_target.json'], 'it is a hard link');
  assert.deepEqual(state.directories, [dir]);
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

test('the listing stops at its bound and counts what it left out', () => {
  const folder = folderOf();
  for (let i = 0; i < mod.RUN_FILES_MAX + 3; i += 1) writeRun(folder, `run_${String(i).padStart(3, '0')}`, { ownerSessionId: OTHER });
  const state = mod.readAutopilotRuns([folder], KEY);
  assert.equal(state.others, mod.RUN_FILES_MAX);
  assert.equal(state.truncated, 3);
  const lines = mod.autopilotRunLines(state, {});
  assert.ok(lines.some((line) => line.includes(`3 further run record(s) were not read, past the bound of ${mod.RUN_FILES_MAX}`)));
  assert.equal(mod.autopilotReleaseBlockers(state)[0].code, 'autopilot-unreadable');
});

test('the section names the run, its stage, next action, pull request and record, and the move route with the guided adoption', () => {
  const folder = folderOf();
  const file = writeRun(folder, 'run_a1');
  const lines = mod.autopilotRunLines(mod.readAutopilotRuns([folder], KEY), { pathText: (p) => `<${p}>`, when: 'WHEN-CLAUSE' });
  const text = lines.join('\n');
  assert.equal(lines[0], '## Autopilot run');
  assert.match(text, /This session drives a durable Autopilot run that stays with it unless you carry it over\./);
  assert.match(text, /carry it over WHEN-CLAUSE\./);
  assert.ok(lines.includes('### Run `run_a1`'));
  assert.ok(lines.includes('- stage: `TEAM_REVIEW`, next action `RECONCILE_TEAM_REVIEW`'));
  assert.ok(lines.includes(`- pull request: #238 ${URL_238}`));
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
  assert.match(lines[1], /This session drives 2 durable Autopilot runs that stay with it unless you carry them over\./);
});

test('an unreadable record is named unreadable in the section, the show line and the release blockers', () => {
  const folder = folderOf();
  fs.writeFileSync(path.join(stateDir(folder), 'autopilot-run-run_bad.json'), '{');
  const state = mod.readAutopilotRuns([folder], KEY);
  const lines = mod.autopilotRunLines(state, { pathText: (p) => p });
  assert.ok(lines.some((line) => line.startsWith('**One Autopilot run record in this session\'s tree could not be read**')));
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
  assert.equal(mod.autopilotShowLine(mod.readAutopilotRuns([folder], KEY)), 'AUTOPILOT this session owns the durable Autopilot run run_a1 at TEAM_REVIEW (PR #238); takeover or handoff names the route that carries it over');
  writeRun(folder, 'run_a2', { stage: 'GATES', nextActionCode: 'RUN_GATES', evidence: { pr: null } });
  const two = mod.autopilotShowLine(mod.readAutopilotRuns([folder], KEY));
  assert.equal(two, 'AUTOPILOT this session owns 2 durable Autopilot runs: run_a1 at TEAM_REVIEW (PR #238), run_a2 at GATES; takeover or handoff names the route that carries each over');
  assert.ok(!two.includes('\n'));
});

test('release blocks on an owned run with a route per layout, and never on a terminal or foreign one', () => {
  const folder = folderOf();
  writeRun(folder, 'run_own');
  writeRun(folder, 'run_nest', { workspaceRoot: path.join(folder, 'wt') });
  writeRun(folder, 'run_tdd', { stage: 'TDD_RUNNING', nextActionCode: 'AWAIT_TDD_CHAIN' });
  writeRun(folder, 'run_done', { stage: 'DONE', nextActionCode: 'NONE' });
  writeRun(folder, 'run_foreign', { ownerSessionId: OTHER });
  const blockers = mod.autopilotReleaseBlockers(mod.readAutopilotRuns([folder], KEY), (p) => p);
  const byRun = Object.fromEntries(blockers.map((b) => [b.text.match(/Autopilot run (\S+) at stage/)[1], b]));
  assert.deepEqual(Object.keys(byRun).sort(), ['run_nest', 'run_own', 'run_tdd']);
  assert.ok(blockers.every((b) => b.code === 'autopilot-run'));
  assert.ok(byRun.run_own.text.includes(`Its record lives in the worktree ${folder}, so freeing that worktree would let Claude Desktop delete the run with it.`));
  assert.ok(byRun.run_own.text.includes('move that worktree into your project root and run /zensu:autopilot-adopt from inside it'));
  assert.ok(byRun.run_nest.text.includes(`Continue it with /zensu:autopilot-adopt from a session whose project root is ${folder}`));
  assert.ok(byRun.run_tdd.text.includes('Its inner build chain is still running, so adoption refuses it'));
});

test('no rendered line quotes a confirmation flag or the CLI helper, and no record value carries a control character into one', () => {
  const folder = folderOf();
  writeRun(folder, 'run_own', { nextActionCode: `RUN${ESC}X`, evidence: { pr: { number: 9, url: `https://example.test/${C1}` } } });
  writeRun(folder, 'run_nest', { workspaceRoot: path.join(folder, 'wt'), blocked: { from: 'GATES', code: `x${LS}y` }, stage: 'BLOCKED', nextActionCode: 'AWAIT_RESUME' });
  writeRun(folder, 'run_tdd', { stage: 'TDD_RUNNING', nextActionCode: 'AWAIT_TDD_CHAIN' });
  fs.writeFileSync(path.join(stateDir(folder), 'autopilot-run-run_bad.json'), '{');
  const state = mod.readAutopilotRuns([folder], KEY);
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
  assert.ok(lib.includes(`&& value.length >= 3 && value.length <= 128 && /${mod.RUN_ID_SHAPE.source}/.test(value);`));
  const stages = lib.match(/^const STAGES = new Set\(\[([^\]]*)\]\);$/m);
  assert.ok(stages, 'the state library no longer spells its STAGES set as one literal');
  for (const stage of JSON.parse(`[${stages[1].replace(/,\s*$/, '')}]`)) assert.match(stage, mod.STAGE_SHAPE);
  const actions = lib.match(/^const NEXT_ACTION = Object\.freeze\(\{([^}]*)\}\);$/m);
  assert.ok(actions, 'the state library no longer spells its NEXT_ACTION table as one literal');
  for (const code of actions[1].match(/"([A-Z_]+)"/g)) assert.match(code.slice(1, -1), mod.ACTION_SHAPE);
});
