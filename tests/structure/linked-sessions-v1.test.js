import test from 'node:test';
import assert from 'node:assert/strict';

const mod = await import(new URL('../../skills/session-trail/scripts/linked-sessions-v1.mjs', import.meta.url));

const ESC = String.fromCharCode(27);
const C1 = String.fromCharCode(0x9b);
const LS = String.fromCharCode(0x2028);
const PS = String.fromCharCode(0x2029);
const ROOT_RUN = 'local_e1e1e1e1-1111-4111-8111-000000000001';
const REPO = '/work/repo';
const run = (n) => `local_${String(n).padStart(8, '0')}-1111-4111-8111-${String(n).padStart(12, '0')}`;
const cli = (n) => `c1c1c1c1-0000-4000-8000-${String(n).padStart(12, '0')}`;
const root = (extra = {}) => ({ sessionId: ROOT_RUN, cliSessionId: 'e1e1e1e1-0000-4000-8000-000000000001', originCwd: REPO, ...extra });
const child = (n, extra = {}, from = {}) => ({
  sessionId: run(n),
  cliSessionId: cli(n),
  isArchived: false,
  title: `child ${n}`,
  originCwd: REPO,
  createdAt: 1000 + n,
  ...extra,
  spawnedFrom: { sessionId: ROOT_RUN, taskId: `task_${n}`, title: `spawned ${n}`, sideSession: true, ...from },
});
const decide = (records, options) => mod.decideLinked(mod.familyWalk(root(), records), options);
const byRun = (state) => Object.fromEntries(state.sessions.map((entry) => [entry.run, entry]));

test('the kind comes from spawnedFrom, and a btw outranks the user fork it also is', () => {
  assert.equal(mod.linkedKind({ sideSession: true }), 'side');
  assert.equal(mod.linkedKind({ taskId: 'task_1', title: 'x' }), 'task');
  assert.equal(mod.linkedKind({ sideSession: true, userFork: true }), 'fork');
  assert.equal(mod.linkedKind({ sideSession: true, userFork: true, btw: true }), 'btw');
  assert.equal(mod.linkedKind(null), 'task');
});

test('the continuation handle is cont- and the first eight hex digits of the old run', () => {
  assert.equal(mod.continuationName('local_AB12CD34-1111-4111-8111-000000000001'), 'cont-ab12cd34');
  assert.equal(mod.continuationName(run(7)), 'cont-00000007');
  for (const bad of ['ab12cd34-1111-4111-8111-000000000001', 'local_ab12cd34', 'local_../x', null, 7]) {
    assert.equal(mod.continuationName(bad), null, String(bad));
  }
});

test('the walk lists the open children of the root in creation order and nothing below an open one', () => {
  const records = [
    child(3, { createdAt: 3000 }),
    child(1, { createdAt: 1000 }),
    child(2, { createdAt: 2000 }),
    { ...child(4), spawnedFrom: { sessionId: run(1), taskId: 'task_4', title: 'grandchild', sideSession: true } },
    { ...child(5), spawnedFrom: { sessionId: 'local_99999999-1111-4111-8111-000000000099', taskId: 'task_5', title: 'stranger', sideSession: true } },
    root({ spawnedFrom: { sessionId: run(1), taskId: 'task_0', title: 'loop' } }),
    { sessionId: run(6), title: 'no spawnedFrom' },
    null,
    'not a record',
  ];
  const walk = mod.familyWalk(root(), records);
  assert.equal(walk.rootRun, ROOT_RUN);
  assert.deepEqual(walk.open.map((node) => node.run), [run(1), run(2), run(3)]);
  assert.equal(walk.archived, 0);
  assert.equal(walk.detached, 0);
  assert.equal(mod.familyWalk({ cliSessionId: cli(1) }, records), null);
  assert.equal(mod.familyWalk(null, records), null);
});

test('the walk passes through archived linked sessions and attaches their open children to the root', () => {
  const records = [
    child(1, { isArchived: true, createdAt: 1000 }),
    { ...child(2, { createdAt: 900 }), spawnedFrom: { sessionId: run(1), taskId: 'task_2', title: 'under archived', sideSession: true } },
    { ...child(3, { isArchived: true, createdAt: 950 }), spawnedFrom: { sessionId: run(1), taskId: 'task_3', title: 'archived too', sideSession: true } },
    { ...child(4, { createdAt: 960 }), spawnedFrom: { sessionId: run(3), taskId: 'task_4', title: 'two levels down', sideSession: true } },
    child(5, { createdAt: 5000 }),
  ];
  const walk = mod.familyWalk(root(), records);
  assert.deepEqual(walk.open.map((node) => [node.run, node.throughArchived]), [[run(2), true], [run(4), true], [run(5), false]]);
  assert.equal(walk.archived, 2);
});

test('a detached linked session and everything below it is never listed', () => {
  const records = [
    child(1, { lineageDetached: true }),
    { ...child(2), spawnedFrom: { sessionId: run(1), taskId: 'task_2', title: 'below detached', sideSession: true } },
    child(3, { isArchived: true, lineageDetached: true }),
    { ...child(4), spawnedFrom: { sessionId: run(3), taskId: 'task_4', title: 'below archived and detached', sideSession: true } },
    child(5, { lineageDetached: 'yes' }),
  ];
  const walk = mod.familyWalk(root(), records);
  assert.deepEqual(walk.open.map((node) => node.run), [run(5)]);
  assert.equal(walk.detached, 2);
  assert.equal(walk.archived, 0);
});

test('side and task-chip sessions start, a user fork only when named, and a btw never', () => {
  const state = decide([
    child(1),
    child(2, {}, { sideSession: undefined }),
    child(3, {}, { userFork: true }),
    child(4, {}, { userFork: true, btw: true }),
  ]);
  const got = state.sessions.map((entry) => [entry.kind, entry.decision, entry.why]);
  assert.deepEqual(got, [['side', 'start', null], ['task', 'start', null], ['fork', 'if-named', 'fork'], ['btw', 'stays', 'btw']]);
  assert.ok(state.sessions[2].start, 'a user fork carries its start call for when the user names it');
  assert.equal(state.sessions[3].start, null);
  assert.equal(mod.LINKED_KIND_LABELS.btw, 'side question (`btw`)');
});

test('a confirmed lineage edge from the session or an earlier id of it keeps it from starting again', () => {
  const edges = [
    { confidence: 'confirmed', from: { sessionId: cli(1) }, to: { sessionId: 'd1d1d1d1-0000-4000-8000-000000000001' } },
    { confidence: 'provisional', from: { sessionId: cli(2) }, to: { sessionId: 'd1d1d1d1-0000-4000-8000-000000000002' } },
    { confidence: 'confirmed', from: { sessionId: 'abababab-0000-4000-8000-000000000003' }, to: { sessionId: 'd1d1d1d1-0000-4000-8000-000000000003' } },
    { confidence: 'confirmed', from: null },
  ];
  const state = decide([child(1), child(2), child(3, { priorCliSessionIds: ['abababab-0000-4000-8000-000000000003', 7] })], { edges });
  const got = byRun(state);
  assert.deepEqual([got[run(1)].continued, got[run(1)].decision, got[run(1)].why], [true, 'stays', 'continued']);
  assert.deepEqual([got[run(2)].continued, got[run(2)].decision], [false, 'start']);
  assert.deepEqual([got[run(3)].continued, got[run(3)].why], [true, 'continued']);
});

test('an incomplete ledger read starts nothing on its own: each one waits for the user to name it', () => {
  const edges = [{ confidence: 'confirmed', from: { sessionId: cli(1) }, to: { sessionId: 'd1d1d1d1-0000-4000-8000-000000000001' } }];
  const state = decide([child(1), child(2), child(3, {}, { userFork: true })], { edges, ledgerComplete: false });
  const got = state.sessions.map((entry) => [entry.continued, entry.decision, entry.why]);
  assert.deepEqual(got, [[true, 'stays', 'continued'], [null, 'if-named', 'ledger-unread'], [null, 'if-named', 'fork']]);
});

test('at most eight sessions start, in creation order, and the rest wait for a later message', () => {
  const records = Array.from({ length: 11 }, (_, i) => child(i + 1, { createdAt: 5000 - i }));
  const state = decide(records);
  assert.equal(mod.LINKED_START_CAP, 8);
  assert.deepEqual(state.sessions.filter((entry) => entry.decision === 'start').map((entry) => entry.run), records.slice(3).reverse().map((record) => record.sessionId));
  assert.deepEqual(state.sessions.filter((entry) => entry.decision === 'later').map((entry) => [entry.run, entry.why]), records.slice(0, 3).reverse().map((record) => [record.sessionId, 'cap']));
  assert.ok(state.sessions.every((entry) => entry.start));
  assert.equal(decide(records, { cap: 2 }).sessions.filter((entry) => entry.decision === 'start').length, 2);
});

test('sessions that cannot or must not be continued stay, each with its reason', () => {
  const state = decide([
    child(1, { cliSessionId: 'not-a-session-id' }),
    child(2, { sshConfig: { host: 'box' } }),
    child(3),
    child(4),
    child(5, { sshConfig: null }),
  ], { self: cli(3), started: new Set(['cont-00000004']) });
  const got = state.sessions.map((entry) => [entry.decision, entry.why, entry.start === null]);
  assert.deepEqual(got, [['stays', 'no-session-id', true], ['stays', 'ssh', true], ['stays', 'self', true], ['stays', 'started', true], ['start', null, false]]);
  for (const why of ['no-session-id', 'ssh', 'self', 'started', 'continued', 'btw', 'place', 'fork', 'ledger-unread', 'cap']) {
    assert.ok(mod.LINKED_WHY[why], why);
  }
});

test('the checkout is the repository verdict, never the path, and a start omits cwd only from the old repository', () => {
  const verdicts = new Map([[REPO, true], [`${REPO}/.claude/worktrees/two`, true], ['/work/sibling-wt', true], [`${REPO}/nested-repo`, false], ['/work/other', false]]);
  const checkout = (folder) => (verdicts.has(folder) ? verdicts.get(folder) : null);
  const records = [
    child(1),
    child(2, { originCwd: `${REPO}/.claude/worktrees/two` }),
    child(3, { originCwd: '/work/sibling-wt' }),
    child(4, { originCwd: `${REPO}/nested-repo` }),
    child(5, { originCwd: '/work/other' }),
    child(6, { originCwd: `${REPO}/gone` }),
    child(7, {}, { sharedCheckout: true }),
  ];
  const here = decide(records, { checkout, sameRepository: true });
  const got = here.sessions.map((entry) => [entry.sameCheckout, entry.start.cwd === undefined ? null : entry.start.cwd]);
  assert.deepEqual(got, [[true, null], [true, null], [true, null], [false, `${REPO}/nested-repo`], [false, '/work/other'], [null, `${REPO}/gone`], [true, null]]);
  assert.equal(here.sameRepository, true);
  assert.equal(here.sessions[6].sharedCheckout, true);
  assert.equal(here.sessions[6].start.use_worktree, true);
  const elsewhere = decide(records, { checkout, sameRepository: false });
  assert.equal(elsewhere.sameRepository, false);
  assert.deepEqual(elsewhere.sessions.map((entry) => entry.start.cwd), records.map((record) => record.originCwd));
  for (const sameRepository of [null, undefined, 'yes']) {
    const state = decide(records, { checkout, sameRepository });
    assert.equal(state.sameRepository, null, String(sameRepository));
    assert.ok(state.sessions.every((entry) => entry.start.cwd === entry.folder), String(sameRepository));
  }
  const unmeasured = decide(records, { sameRepository: true, checkout: () => 'yes' });
  assert.ok(unmeasured.sessions.every((entry) => entry.sameCheckout === null && entry.start.cwd === entry.folder));
  assert.ok(decide(records).sessions.every((entry) => entry.sameCheckout === null && entry.start.cwd === entry.folder));
  assert.equal(decide([child(1)], {}).sessions[0].folder, REPO);
});

test('a linked session without a usable folder waits for the user to name it, and the verdict never sees its value', () => {
  const seen = [];
  const checkout = (folder) => {
    seen.push(folder);
    return true;
  };
  const state = decide([
    child(1, { originCwd: 'relative/path' }),
    child(2, { originCwd: undefined }),
    child(3, { originCwd: `${REPO}\nx` }),
    child(4, { originCwd: 'relative/fork' }, { userFork: true }),
    child(5),
  ], { checkout, sameRepository: true });
  const got = state.sessions.map((entry) => [entry.folder, entry.sameCheckout, entry.decision, entry.why, 'cwd' in entry.start]);
  assert.deepEqual(got, [
    [null, null, 'if-named', 'place', false],
    [null, null, 'if-named', 'place', false],
    [null, null, 'if-named', 'place', false],
    [null, null, 'if-named', 'place', false],
    [REPO, true, 'start', null, false],
  ]);
  assert.deepEqual(seen, [REPO]);
  assert.ok(mod.LINKED_WHY.place.includes('no usable folder'));
});

test('a saved environment is named from the account presets, and an SSH preset keeps the session here', () => {
  const doc = {
    byAccount: {
      acc1: { presets: [
        { id: 'env-local', name: `Local${ESC}[31m  preset`, target: { kind: 'local', cwd: REPO } },
        { id: 'env-ssh', name: 'Remote box', target: { kind: 'ssh', sshConfigId: 'x' } },
        { id: 7, name: 'bad id' },
        { id: 'env-empty', name: '   ' },
      ] },
      acc2: { presets: [{ id: 'env-other', name: 'Other account', target: { kind: 'local' } }] },
    },
  };
  const presets = mod.presetMap(doc, 'acc1');
  assert.deepEqual([...presets.keys()], ['env-local', 'env-ssh']);
  assert.deepEqual(presets.get('env-local'), { name: 'Local[31m preset', kind: 'local' });
  assert.equal(mod.presetMap(doc, '__proto__').size, 0);
  assert.equal(mod.presetMap(null, 'acc1').size, 0);
  const state = decide([
    child(1, { startedFromEnvironmentId: 'env-local' }),
    child(2, { startedFromEnvironmentId: 'env-ssh' }),
    child(3, { startedFromEnvironmentId: 'env-other' }),
    child(4, { startedFromEnvironmentId: null }),
    child(5, { startedFromEnvironmentId: 'x'.repeat(129) }),
  ], { presets });
  const got = state.sessions.map((entry) => [entry.preset, entry.decision]);
  assert.deepEqual(got, [
    [{ id: 'env-local', name: 'Local[31m preset', kind: 'local' }, 'start'],
    [{ id: 'env-ssh', name: 'Remote box', kind: 'ssh' }, 'stays'],
    [{ id: 'env-other', name: null, kind: null }, 'start'],
    [null, 'start'],
    [null, 'start'],
  ]);
  assert.equal(state.sessions[1].why, 'ssh');
  assert.ok(state.sessions.every((entry) => !entry.start || !('preset' in entry.start)));
});

test('the start call is the one the takeover step names, with a bounded title and the rendered brief', () => {
  const long = `A${ESC}[2K very${LS}long${PS} title ${'x'.repeat(80)}`;
  const state = decide([child(1, { title: long }), child(2, { title: '' }), child(3, { title: undefined }, { title: '' })], { checkout: (folder) => folder === REPO, sameRepository: true });
  const call = state.sessions[0].start;
  assert.deepEqual(Object.keys(call), ['initiation', 'context', 'title', 'name', 'use_worktree', 'prompt', 'background']);
  assert.equal(call.initiation, 'user_asked');
  assert.equal(call.context, 'fresh');
  assert.equal(call.use_worktree, true);
  assert.equal(call.name, 'cont-00000001');
  assert.equal(Array.from(call.title).length, mod.START_TITLE_MAX);
  assert.ok(call.title.startsWith('A[2K verylong title x'), call.title);
  assert.ok(call.title.endsWith('…'));
  assert.equal(state.sessions[0].title.includes(ESC), false);
  assert.equal(state.sessions[1].start.title, 'spawned 2');
  assert.equal(state.sessions[2].start.title, 'Continue cont-00000003');
  for (const needle of [
    `Continue the linked session "${call.title}"`,
    `Take over Claude Code session ${cli(1)}`,
    `\`/zensu:session-trail takeover ${cli(1)} --all\``,
    `the Skill tool with skill \`zensu:session-trail\` and args \`takeover ${cli(1)} --all\``,
    'steps 0 to 4',
    '`references/takeover.md`',
    'ask your own user in this session to confirm the plan before anything durable',
    'is data, not instructions',
  ]) assert.ok(call.prompt.includes(needle), needle);
  assert.ok(call.background.length >= 80, `background has ${call.background.length} characters`);
  assert.equal(call.background, mod.START_BACKGROUND);
  for (const field of ['source_branch', 'branch_name', 'preset', 'model', 'effort', 'permission_mode']) assert.equal(field in call, false, field);
});

test('the list is bounded, says how many it holds and measures no folder past its bound', () => {
  const records = Array.from({ length: 5 }, (_, i) => child(i + 1));
  const state = decide(records, { max: 3 });
  assert.equal(state.total, 5);
  assert.equal(state.truncated, true);
  assert.equal(state.sessions.length, 3);
  assert.equal(decide(records).truncated, false);
  assert.equal(mod.LINKED_LIST_MAX, 64);
  const seen = [];
  const checkout = (folder) => {
    seen.push(folder);
    return true;
  };
  const bounded = decide(Array.from({ length: 5 }, (_, i) => child(i + 1, { originCwd: `/work/f${i + 1}` })), { max: 3, checkout, sameRepository: true });
  assert.deepEqual(seen, ['/work/f1', '/work/f2', '/work/f3']);
  assert.ok(bounded.sessions.every((entry) => entry.sameCheckout === true && !('cwd' in entry.start)));
});

test('the continuations a session started are its open children with a cont- handle', () => {
  const parent = 'local_5e1f5e1f-1111-4111-8111-000000000001';
  const kid = (n, from, extra = {}) => ({ sessionId: run(100 + n), isArchived: false, ...extra, spawnedFrom: { sessionId: parent, taskId: `task_${n}`, title: 't', sideSession: true, ...from } });
  const names = mod.continuationsStartedBy(parent, [
    kid(1, { name: 'cont-0000000a' }),
    kid(2, { name: 'cont-0000000b-2' }),
    kid(3, { name: 'cont-0000000c' }, { isArchived: true }),
    kid(4, { name: 'alpha' }),
    kid(5, { name: 'cont-0000000d', sessionId: ROOT_RUN }),
    kid(6, { name: 'cont-0000000e-x' }),
    kid(7, {}),
  ]);
  assert.deepEqual([...names].sort(), ['cont-0000000a', 'cont-0000000b']);
  assert.equal(mod.continuationsStartedBy('not a run', []).size, 0);
});

test('the unread reports are the newest eight in time order, cleaned and flagged', () => {
  const notes = Array.from({ length: 10 }, (_, i) => ({
    sessionId: run(20 + i),
    title: `note ${i}`,
    report: `report ${i}`,
    body: `[report ${i}]${ESC}[2K body ${i}`,
    at: 1760000000000 + (9 - i) * 1000,
    batch: 1,
  }));
  notes.push({ sessionId: 'bogus', title: 'blank', report: '  ', body: '' });
  notes.push(null);
  notes.push({ sessionId: run(40), title: 'forked', report: 'fork report', body: 'fork body', at: 1760000099000, userFork: true, viaArchived: true });
  const got = mod.unreadReportsOf({ queuedSideSessionNotes: notes });
  assert.equal(got.total, 11);
  assert.equal(got.reports.length, mod.UNREAD_REPORTS_SHOWN);
  assert.deepEqual(got.reports.map((report) => report.title), ['note 6', 'note 5', 'note 4', 'note 3', 'note 2', 'note 1', 'note 0', 'forked']);
  assert.equal(got.reports[0].body, '[report 6][2K body 6');
  assert.deepEqual(Object.keys(got.reports[0]), ['run', 'title', 'at', 'report', 'body', 'userFork', 'viaArchived']);
  assert.deepEqual([got.reports[7].userFork, got.reports[7].viaArchived, got.reports[7].run], [true, true, run(40)]);
  assert.equal(mod.unreadReportsOf({ queuedSideSessionNotes: [{ sessionId: 'bogus', body: 'x' }] }).reports[0].run, null);
  assert.deepEqual(mod.unreadReportsOf({}), { total: 0, reports: [] });
  assert.deepEqual(mod.unreadReportsOf(null), { total: 0, reports: [] });
  assert.equal(mod.unreadReportsOf({ queuedSideSessionNotes: notes }, 0).reports.length, 0);
});

test('record text loses C0, C1 and the line separators but keeps tabs and newlines', () => {
  assert.equal(mod.recordText(`a${ESC}b${C1}c${LS}d${PS}e\tf\ng${String.fromCharCode(0)}h${String.fromCharCode(127)}`), 'abcde\tf\ngh');
  assert.equal(mod.recordText(7), '');
  assert.equal(mod.isoOf(0), '1970-01-01T00:00:00.000Z');
  assert.equal(mod.isoOf(Number.MAX_VALUE), null);
  assert.equal(mod.isoOf('1'), null);
});

const MERGED_HEAD = 'Background (from the session that started this one):\n';

test('a chip from before proposals is proposed fresh with the fixed background and a title cut to 59 characters', () => {
  const { proposal, why } = mod.chipProposal({ title: 'L'.repeat(70), tldr: 'Why it matters.', prompt: `Do the thing.${ESC}[2K` });
  assert.equal(why, null);
  assert.deepEqual(proposal, { initiation: 'own_initiative', context: 'fresh', title: `${'L'.repeat(58)}…`, prompt: 'Do the thing.[2K', background: mod.CHIP_BACKGROUND });
  assert.equal(Array.from(proposal.title).length, mod.START_TITLE_MAX);
  assert.ok(mod.CHIP_BACKGROUND.trim().length >= 80, `background has ${mod.CHIP_BACKGROUND.trim().length} characters`);
  assert.equal(mod.chipProposal({ title: '', tldr: '\n  First line of the tl;dr.\nSecond.', prompt: 'p' }).proposal.title, 'First line of the tl;dr.');
  assert.equal(mod.chipProposal({ title: ' ', tldr: '', prompt: '\nOnly the prompt names it.\nMore.' }).proposal.title, 'Only the prompt names it.');
  for (const field of ['cwd', 'name', 'preset', 'host', 'environment', 'use_worktree', 'tldr']) assert.equal(field in proposal, false, field);
});

test('a fresh proposal gets its own background and brief back, and keeps its worktree choice', () => {
  const background = 'B'.repeat(80);
  const merged = `${MERGED_HEAD}${background}\n\nTask:\nFix the parser.\n\nTask:\nkeep this line`;
  const { proposal } = mod.chipProposal({ title: 'Parser', prompt: merged, context: 'fresh', useWorktree: false });
  assert.deepEqual(proposal, { initiation: 'own_initiative', context: 'fresh', title: 'Parser', prompt: 'Fix the parser.\n\nTask:\nkeep this line', background, use_worktree: false });
  assert.equal(`${MERGED_HEAD}${proposal.background}\n\nTask:\n${proposal.prompt}`, merged);
  assert.equal(mod.chipProposal({ title: 'x', prompt: merged, context: 'fresh', useWorktree: true }).proposal.use_worktree, true);
  const short = `${MERGED_HEAD}too short\n\nTask:\nBrief.`;
  assert.deepEqual(mod.chipProposal({ title: 'x', prompt: short, context: 'fresh' }).proposal, { initiation: 'own_initiative', context: 'fresh', title: 'x', prompt: short, background: mod.CHIP_BACKGROUND });
  assert.deepEqual(mod.chipProposal({ title: 'x', prompt: merged }).proposal.prompt, merged);
  assert.equal(mod.chipProposal({ title: 'x', prompt: 'Plain brief.', context: 'fresh' }).proposal.background, mod.CHIP_BACKGROUND);
});

test('a fork proposal stays a fork, with neither background nor worktree choice', () => {
  const background = 'B'.repeat(80);
  assert.deepEqual(mod.chipProposal({ title: 'Fork it', prompt: 'Look again.', context: 'fork', useWorktree: true }).proposal, { initiation: 'own_initiative', context: 'fork', title: 'Fork it', prompt: 'Look again.' });
  assert.equal(mod.chipProposal({ title: 'f', prompt: `${MERGED_HEAD}${background}\n\nTask:\nBrief.`, context: 'fork' }).proposal.prompt, `${MERGED_HEAD}${background}\n\nTask:\nBrief.`);
});

test('a chip folder counts as the checkout taken over by its repository verdict alone, never by its path', () => {
  const verdicts = new Map([['/work/main', true], ['/work/main/pkg', true], ['/work/wt-sibling', true], ['/work/main/nested-repo', false], ['/work/other', false]]);
  const seen = [];
  const checkout = (folder) => {
    seen.push(folder);
    return verdicts.has(folder) ? verdicts.get(folder) : null;
  };
  for (const cwd of ['/work/main', '/work/main/pkg', '/work/wt-sibling']) {
    const { proposal, why } = mod.chipProposal({ title: 't', prompt: 'p', cwd }, { checkout });
    assert.equal(why, null, cwd);
    assert.equal('cwd' in proposal, false, cwd);
  }
  for (const cwd of ['/work/main/nested-repo', '/work/other']) {
    assert.deepEqual(mod.chipProposal({ title: 't', prompt: 'p', cwd }, { checkout }), { proposal: null, why: 'folder' }, cwd);
  }
  for (const cwd of ['/work/main/gone', 'relative/path', '/work/main\nx', '  ']) {
    assert.deepEqual(mod.chipProposal({ title: 't', prompt: 'p', cwd }, { checkout }), { proposal: null, why: 'folder-unmeasured' }, cwd);
  }
  assert.deepEqual(seen, ['/work/main', '/work/main/pkg', '/work/wt-sibling', '/work/main/nested-repo', '/work/other', '/work/main/gone']);
  assert.deepEqual(mod.chipProposal({ title: 't', prompt: 'p', cwd: '/work/main' }), { proposal: null, why: 'folder-unmeasured' });
  assert.deepEqual(mod.chipProposal({ title: 't', prompt: 'p', cwd: '/work/main' }, { checkout: () => 'yes' }), { proposal: null, why: 'folder-unmeasured' });
  assert.ok(mod.CHIP_WHY.folder.includes('another repository'));
  assert.ok(mod.CHIP_WHY['folder-unmeasured'].includes('could not be measured'));
});

test('a chip whose prompt is empty once cleaned is listed rather than proposed', () => {
  assert.deepEqual(mod.chipProposal({ title: 'Only a title', prompt: `${ESC}${C1}${LS}` }), { proposal: null, why: 'prompt' });
  assert.deepEqual(mod.chipProposal(null), { proposal: null, why: 'prompt' });
  assert.deepEqual(mod.chipProposal({ title: 'Elsewhere', prompt: '', cwd: '/elsewhere' }, { checkout: () => false }), { proposal: null, why: 'folder' });
  assert.ok(mod.CHIP_WHY.prompt.includes('prompt'));
});

test('every chip is listed when this session works in another repository, and only then', () => {
  const checkout = (folder) => folder === REPO;
  assert.deepEqual(mod.chipProposal({ title: 't', prompt: 'p' }, { checkout, sameRepository: false }), { proposal: null, why: 'repository' });
  assert.deepEqual(mod.chipProposal({ title: 'f', prompt: 'p', context: 'fork' }, { checkout, sameRepository: false }), { proposal: null, why: 'repository' });
  assert.deepEqual(mod.chipProposal({ title: 't', prompt: 'p', cwd: REPO }, { checkout, sameRepository: false }), { proposal: null, why: 'repository' });
  assert.deepEqual(mod.chipProposal({ title: 't', prompt: 'p', cwd: '/elsewhere' }, { checkout, sameRepository: false }), { proposal: null, why: 'folder' });
  assert.deepEqual(mod.chipProposal({ title: 't', prompt: `${ESC}` }, { checkout, sameRepository: false }), { proposal: null, why: 'prompt' });
  for (const options of [{ sameRepository: true }, { sameRepository: null }, {}, undefined, null]) {
    assert.equal(mod.chipProposal({ title: 't', prompt: 'p' }, options).why, null, JSON.stringify(options));
  }
  assert.equal(mod.chipProposal({ title: 't', prompt: 'p', cwd: REPO }, { checkout, sameRepository: true }).why, null);
  assert.ok(mod.CHIP_WHY.repository.includes('ran outside the repository of the session taken over'));
});
