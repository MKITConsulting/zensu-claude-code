'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

const PLUGIN_DIR = path.resolve(__dirname, '..', '..');
const LIB = path.join(PLUGIN_DIR, 'hooks', 'lib');
const GATE = path.join(LIB, 'review-gate-v1.js');
const gate = require(GATE);
const packets = require(path.join(LIB, 'review-packet-v1.js'));
const core = require(path.join(LIB, 'session-control-core-v1.js'));

const FIELDS = {
  implementation_summary: 'Adds the invoice total.',
  requirements_baseline: 'AC-001',
  diff_summary: 'src/total.js: new sum()',
  test_evidence: 'evidence-run full: 12 passed, 0 failed',
  build_evidence: 'not run — no build step',
  coverage_evidence: 'not run — no coverage tool',
  edit_landing_evidence: 'EDIT LANDING AUDIT — claims=1 landed=1',
};
const JUDGE_OK = '## Aspect: judge\n- [IMPORTANT] JUDGE-1 src/total.js:3 — rounding drifts. Confidence: 90. Evidence: x. Fix: y.\n';
const JUDGE_NONE = '## Aspect: judge\n- (no findings)\n';
const HANDBACK_LEAD = '[Subagent hand-back] The text below is the final report of a subagent this session delegated to. The report follows:';

function frame(agent, report) {
  const body = report.replace(/\n$/, '').split('\n').map((line) => `  ${line}`);
  return [`<agent-message from="${agent}">`, HANDBACK_LEAD, ...body, '</agent-message>'].join('\n');
}

function notification(agent, status) {
  return ['<task-notification>', `<task-id>${agent}</task-id>`, '<tool-use-id>toolu_01WPhqY4dh2LFbaugtAn6Kg8</tool-use-id>',
    `<status>${status}</status>`, '<summary>Agent "review" finished</summary>', '</task-notification>'].join('\n');
}

function workspace(t) {
  const base = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'review-gate-')));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const env = { PATH: process.env.PATH, HOME: path.join(base, 'home'), GIT_CONFIG_NOSYSTEM: '1', LC_ALL: 'C' };
  fs.mkdirSync(env.HOME);
  const hooks = path.join(base, 'no-hooks');
  fs.mkdirSync(hooks);
  const root = path.join(base, 'repo');
  fs.mkdirSync(root);
  const git = (...args) => {
    const result = spawnSync('git', ['-C', root, '-c', 'user.email=t@example.invalid', '-c', 'user.name=zensu-test',
      '-c', 'commit.gpgsign=false', '-c', `core.hooksPath=${hooks}`, ...args], { env, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
  };
  git('init', '-q');
  fs.writeFileSync(path.join(root, '.gitignore'), '.zensu/\n');
  fs.writeFileSync(path.join(root, 'total.js'), 'v1\n');
  git('add', '-A');
  git('commit', '-qm', 'base');
  fs.writeFileSync(path.join(root, 'total.js'), 'v2\n');
  return { base, root };
}

function writeWorkflow(root, session, overrides = {}) {
  const document = core.stampWorkflowState({
    phase: 'IMPL',
    history: [],
    bypasses: [],
    active: true,
    vanilla: true,
    implComplete: true,
    chainDone: false,
    codeReviewDone: false,
    selfReviewFixed: false,
    reviewTicket: '',
    reviewTicketConsumed: false,
    reviewRound: 0,
    stopBlockCount: 0,
    ...overrides,
  }, session, 'active', 'tdd_begin');
  const file = core.adoptionWorkflowStatePath(root, session);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(document));
}

function chain(t, state = {}) {
  const w = workspace(t);
  const session = crypto.randomUUID();
  writeWorkflow(w.root, session, state);
  const receipt = packets.receiptPath(w.root, session);
  fs.writeFileSync(receipt, JSON.stringify({ schema: 'edit-landing-v2', clean: true, claims: 1, landed: 1, notLanded: 0, unverified: 0, pending: 0 }));
  const input = path.join(w.base, 'input.json');
  fs.writeFileSync(input, JSON.stringify(FIELDS));
  let clock = 1000;
  const tick = () => (clock += 10);
  const create = (env = {}) => packets.createPacket({ root: w.root, session, input, checkReceipt: () => {}, now: tick, env }).record;
  const payload = (type, prompt, response = { status: 'completed', content: [{ type: 'text', text: '## Aspect: correctness\n- (no findings)\n' }] }) => ({
    session_id: session, tool_name: 'Agent', tool_input: { subagent_type: type, prompt }, tool_response: response,
  });
  const record = (type, prompt, response) => gate.recordObservation({ root: w.root, session, payload: payload(type, prompt, response), now: tick });
  const check = (prompt, options = {}) => gate.checkConsume({
    root: w.root, session, payload: payload('zensu:code-reviewer', prompt, options.response || { status: 'completed', content: [{ type: 'text', text: '- Verdict: PASS\n' }] }),
    judge: options.judge || 'on', panel: options.panel || 'lean', ticket: options.ticket,
  });
  const consumePrompt = (packet) => `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: rt_x\n${packet}\n\nmerged findings: none\n`;
  const judged = (text) => ({ status: 'completed', content: [{ type: 'text', text }] });
  const launched = (agentId) => ({ status: 'async_launched', isAsync: true, agentId });
  const launch = (type, prompt, agentId) => gate.recordObservation({ root: w.root, session, payload: payload(type, prompt, launched(agentId)), now: tick });
  const prompted = (text) => ({ hook_event_name: 'UserPromptSubmit', session_id: session, prompt: text });
  const handbackPrompt = (text) => gate.recordHandback({ root: w.root, session, payload: prompted(text), now: tick });
  const handback = (agent, report) => handbackPrompt(frame(agent, report));
  const checkLaunch = (prompt, agentId, options = {}) => gate.checkConsume({
    root: w.root, session, payload: payload('zensu:code-reviewer', prompt, launched(agentId)),
    judge: options.judge || 'on', panel: options.panel || 'lean', ticket: options.ticket, now: tick,
  });
  const checkArrival = (text, agent, options = {}) => gate.checkConsume({
    root: w.root, session, payload: prompted(text), event: 'UserPromptSubmit', agent,
    judge: options.judge || 'on', panel: options.panel || 'lean', ticket: options.ticket, now: tick,
  });
  const checkHandback = (agent, report, options = {}) => checkArrival(frame(agent, report), agent, options);
  return { ...w, session, receipt, input, create, record, check, consumePrompt, judged, launch, handback, handbackPrompt, checkLaunch, checkArrival, checkHandback };
}

test('classify maps the plugin reviewers and repo personas and nothing else', () => {
  assert.equal(gate.classify('zensu:review-aspect'), 'aspect');
  assert.equal(gate.classify('zensu:review-judge'), 'judge');
  assert.equal(gate.classify('zensu-review-api'), 'persona');
  for (const other of ['zensu:code-reviewer', 'review-aspect', 'general-purpose', 'zensu-review-', 'zensu-review-a b', undefined]) {
    assert.equal(gate.classify(other), null, String(other));
  }
});

test('classify counts an aspect or judge only while the principal owner lists it as a reviewer', () => {
  const owner = require(path.join(LIB, 'claude-principal-v1.js'));
  for (const [type, role] of [['zensu:review-aspect', 'aspect'], ['zensu:review-judge', 'judge']]) {
    assert.equal(owner.REVIEWER_TYPES.has(type), true, type);
    owner.REVIEWER_TYPES.delete(type);
    try {
      assert.equal(gate.classify(type), null, type);
    } finally {
      owner.REVIEWER_TYPES.add(type);
    }
    assert.equal(gate.classify(type), role, type);
  }
  const others = ['zensu:__proto__', 'zensu:constructor', 'zensu:toString', '__proto__', 'zensu:',
    'zensu:review-aspect ', 'ZENSU:review-judge', 'review-judge', 42, null, {}, ['zensu:review-aspect']];
  for (const other of others) {
    assert.equal(gate.classify(other), null, String(other));
  }
});

test('reportText prefers the handback report and treats the delivery stub as no report', () => {
  const stub = [{ type: 'text', text: 'This agent\'s report was delivered to you as a message from "a1" (its SubagentHandback call). Read it there; it is not repeated here.\n' }];
  assert.deepEqual(gate.reportText({ status: 'completed', handback: 'send', handbackReport: { text: JUDGE_OK }, content: stub }), { text: JUDGE_OK, source: 'handback' });
  assert.deepEqual(gate.reportText({ status: 'completed', content: stub }), { text: '', source: 'none' });
  assert.deepEqual(gate.reportText({ status: 'completed', content: [{ type: 'text', text: 'a' }, { type: 'image' }, { type: 'text', text: 'b' }] }), { text: 'a\nb', source: 'content' });
  assert.deepEqual(gate.reportText({ content: 'plain' }), { text: 'plain', source: 'content' });
  for (const value of [null, [], 'x', {}]) assert.equal(gate.reportText(value).source, 'none');
});

test('judgeFailure accepts a substantive judge report and rejects every other shape', () => {
  const report = (text) => ({ text, source: 'content' });
  assert.equal(gate.judgeFailure(report(JUDGE_OK), 'completed'), null);
  assert.equal(gate.judgeFailure(report(JUDGE_NONE), 'completed'), null);
  assert.equal(gate.judgeFailure(report(`${JUDGE_OK}- [SUGGESTION] JUDGE-2 x — the fallback quotes "REVIEW PACKET INVALID" as data. Fix: none.\n`), 'completed'), null);
  assert.match(gate.judgeFailure(report(JUDGE_OK), 'async_launched'), /status async_launched/);
  assert.match(gate.judgeFailure({ text: '', source: 'none' }, 'completed'), /no judge report/);
  assert.match(gate.judgeFailure(report('REVIEW PACKET INVALID: changed_files\n'), 'completed'), /REVIEW PACKET INVALID/);
  assert.match(gate.judgeFailure(report('## Aspect: judge (second run)\n- (no findings)\n'), 'completed'), /no "## Aspect: judge" heading/);
  assert.match(gate.judgeFailure(report('## Aspect: judge\nNothing to add.\n'), 'completed'), /neither a JUDGE finding/);
});

test('record writes nothing outside an implementation-complete chain or for other agent types', (t) => {
  for (const state of [{ implComplete: false }, { chainDone: true }]) {
    const c = chain(t, state);
    assert.equal(c.record('zensu:review-aspect', 'x').recorded, false);
    assert.equal(fs.existsSync(packets.storeDirectory(c.root, c.session)), false);
  }
  const c = chain(t);
  assert.equal(c.record('general-purpose', 'x').recorded, false);
  assert.equal(c.record('zensu:code-reviewer', 'x').recorded, false);
  assert.equal(fs.existsSync(packets.storeDirectory(c.root, c.session)), false);
});

test('record keeps the role, identity, packet digest and validity of each reviewer run', (t) => {
  const c = chain(t);
  const packet = c.create();
  const aspect = c.record('zensu:review-aspect', `perspective: correctness\n${packet.text}\n`);
  assert.equal(aspect.record.role, 'aspect');
  assert.equal(aspect.record.identity, 'aspect:correctness');
  assert.equal(aspect.record.packetSha, packet.sha256);
  assert.equal(aspect.record.valid, null);
  assert.equal(gate.observationAdvice(aspect), '');
  const primary = c.record('zensu:review-judge', `${packet.text}\nmerged_panel_findings: none\n`, c.judged(JUDGE_OK));
  assert.equal(primary.record.role, 'judge-primary');
  assert.equal(primary.record.identity, 'judge-primary');
  assert.equal(primary.record.valid, true);
  const second = c.record('zensu:review-judge', `${packet.text}\nmerged_panel_findings: none\njudge_run: second\n`, c.judged('## Aspect: judge (second run)\n- (no findings)\n'));
  assert.equal(second.record.role, 'judge-second');
  assert.equal(second.record.valid, null);
  const persona = c.record('zensu-review-api', packet.text, c.judged('## Aspect: zensu-review-api\n- (no findings)\n'));
  assert.equal(persona.record.identity, 'persona:zensu-review-api');
  const handback = c.record('zensu:review-judge', packet.text, { status: 'completed', handback: 'send', handbackReport: { text: JUDGE_NONE }, content: [] });
  assert.equal(handback.record.reportSource, 'handback');
  assert.equal(handback.record.valid, true);
  assert.equal(gate.listStore(packets.storeDirectory(c.root, c.session)).records.length, 5);
});

test('record advises when the packet is missing, mismatched or not created yet', (t) => {
  const c = chain(t);
  assert.match(gate.observationAdvice(c.record('zensu:review-aspect', 'no packet')), /^REVIEW PACKET NOT CREATED — review round 0 has no canonical packet/);
  const packet = c.create();
  assert.match(gate.observationAdvice(c.record('zensu:review-aspect', 'no packet')), /^REVIEW PACKET MISSING — .* carried no REVIEW PACKET v1 block/);
  const edited = packet.text.replace('policy: reviewer-readonly-v1', 'policy: reviewer-readonly-v2');
  assert.match(gate.observationAdvice(c.record('zensu:review-aspect', edited)), /^REVIEW PACKET MISMATCH — .* at packet line 2\./);
  assert.match(gate.observationAdvice(c.record('zensu:review-aspect', `${packet.text}\n${packet.text}`)), /more than one REVIEW PACKET v1 block/);
});

test('a failed primary judge advises one retry and then a stop', (t) => {
  const c = chain(t);
  const packet = c.create();
  const first = gate.observationAdvice(c.record('zensu:review-judge', packet.text, c.judged('REVIEW PACKET INVALID: merged_panel_findings\n')));
  assert.match(first, /^PRIMARY JUDGE INCOMPLETE — the judge answered REVIEW PACKET INVALID\. Spawn the primary zensu:review-judge once more/);
  assert.match(first, /never substitutes/);
  const second = gate.observationAdvice(c.record('zensu:review-judge', packet.text, { status: 'completed', content: [] }));
  assert.match(second, /^REVIEW INCOMPLETE — the primary judge failed twice on review round 0's packet \(no judge report reached the hook\)\. Stop the review chain here/);
});

test('check passes a generation with no packet, no record and no packet in the consume prompt', (t) => {
  const c = chain(t);
  assert.deepEqual(c.check('PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: rt_x\nfindings\n'), { pass: true, reason: 'not-engaged' });
  const other = chain(t, { implComplete: false });
  assert.deepEqual(other.check('anything'), { pass: true, reason: 'not-reviewable' });
});

test('check holds the claim silently when the workflow document does not validate or is gone', (t) => {
  const c = chain(t);
  const file = core.adoptionWorkflowStatePath(c.root, c.session);
  const document = JSON.parse(fs.readFileSync(file, 'utf8'));
  delete document.vanilla;
  fs.writeFileSync(file, JSON.stringify(document));
  const invalid = { response: { status: 'completed', content: [{ type: 'text', text: 'REVIEW PACKET INVALID: policy\n' }] } };
  assert.deepEqual(c.check(c.consumePrompt('REVIEW PACKET v1\nEND REVIEW PACKET v1'), invalid), { pass: false, hold: true, reason: 'state-invalid' });
  const foreign = core.stampWorkflowState({ ...document, vanilla: true }, crypto.randomUUID(), 'active', 'tdd_begin');
  fs.writeFileSync(file, JSON.stringify(foreign));
  assert.deepEqual(c.check('anything'), { pass: false, hold: true, reason: 'state-invalid' });
  fs.rmSync(file);
  assert.deepEqual(c.check('anything'), { pass: false, hold: true, reason: 'state-absent' });
  const consume = JSON.stringify({ session_id: c.session, tool_input: { subagent_type: 'zensu:code-reviewer', prompt: 'x' }, tool_response: {} });
  const run = spawnSync(process.execPath, [GATE, 'check', '--root', c.root, '--session', c.session, '--judge', 'on', '--panel', 'lean'], { input: consume, encoding: 'utf8' });
  assert.equal(run.status, 3);
  assert.equal(run.stdout, 'hold state-absent\n');
  assert.equal(run.stderr, '');
});

test('check refuses an engaged round without a canonical packet', (t) => {
  const c = chain(t);
  c.record('zensu:review-aspect', 'a hand-written packet');
  const verdict = c.check(c.consumePrompt('REVIEW PACKET v1\npolicy: reviewer-readonly-v1\nEND REVIEW PACKET v1'));
  assert.equal(verdict.pass, false);
  assert.match(verdict.message, /^REVIEW INCOMPLETE — review round 0 has no canonical packet\. The review ticket was NOT consumed/);
  const fresh = chain(t);
  assert.equal(fresh.check(fresh.consumePrompt('REVIEW PACKET v1\nEND REVIEW PACKET v1')).pass, false);
});

test('check refuses a consume prompt whose packet is absent, duplicated or edited', (t) => {
  const c = chain(t);
  const packet = c.create();
  c.record('zensu:review-judge', packet.text, c.judged(JUDGE_OK));
  assert.match(c.check(c.consumePrompt('')).message, /the consume prompt carries no REVIEW PACKET v1 block/);
  assert.match(c.check(c.consumePrompt(`${packet.text}\n${packet.text}`)).message, /more than one REVIEW PACKET v1 block/);
  const edited = packet.text.replace('Adds the invoice total.', 'Adds the invoice total!');
  assert.match(c.check(c.consumePrompt(edited)).message, /differs from review round 0's canonical packet at packet line \d+/);
  assert.deepEqual(c.check(c.consumePrompt(packet.text)), { pass: true, reason: 'ok' });
});

test('check refuses when the tree or the receipt changed after the packet', (t) => {
  const c = chain(t);
  const packet = c.create();
  c.record('zensu:review-judge', packet.text, c.judged(JUDGE_OK));
  fs.writeFileSync(path.join(c.root, 'total.js'), 'v3\n');
  assert.match(c.check(c.consumePrompt(packet.text)).message, /^REVIEW INCOMPLETE — the working tree changed since review round 0's packet was created\./);
  fs.writeFileSync(path.join(c.root, 'total.js'), 'v2\n');
  assert.equal(c.check(c.consumePrompt(packet.text)).pass, true);
  fs.writeFileSync(path.join(c.root, 'extra.js'), 'x\n');
  assert.match(c.check(c.consumePrompt(packet.text)).message, /the change set changed/);
  fs.rmSync(path.join(c.root, 'extra.js'));
  fs.writeFileSync(c.receipt, JSON.stringify({ schema: 'edit-landing-v2', clean: false }));
  assert.match(c.check(c.consumePrompt(packet.text)).message, /the edit-landing receipt changed since review round 0's packet/);
});

test('a packet that recorded no receipt passes without one and refuses once an audit writes one', (t) => {
  const deferred = chain(t, { deferredReviewClaim: 'dc_claim1' });
  fs.rmSync(deferred.receipt);
  const none = deferred.create();
  deferred.record('zensu:review-judge', none.text, deferred.judged(JUDGE_OK));
  assert.deepEqual(deferred.check(deferred.consumePrompt(none.text)), { pass: true, reason: 'ok' });
  fs.writeFileSync(deferred.receipt, JSON.stringify({ schema: 'edit-landing-v2', clean: true, claims: 1, landed: 1, notLanded: 0, unverified: 0, pending: 0 }));
  assert.match(deferred.check(deferred.consumePrompt(none.text)).message,
    /^REVIEW INCOMPLETE — an edit-landing receipt was written after review round 0's packet recorded none\..*review-packet-v1\.js create --root .* again, spawn/);
  const escaped = chain(t);
  fs.rmSync(escaped.receipt);
  const open = escaped.create({ ZENSU_EDIT_LANDING_GATE: 'off' });
  escaped.record('zensu:review-judge', open.text, escaped.judged(JUDGE_OK));
  assert.deepEqual(escaped.check(escaped.consumePrompt(open.text)), { pass: true, reason: 'ok' });
});

test('check refuses while the latest run of a reviewer saw another packet and passes once it is re-run', (t) => {
  const c = chain(t);
  const packet = c.create();
  c.record('zensu:review-judge', packet.text, c.judged(JUDGE_OK));
  c.record('zensu:review-aspect', packet.text.replace('AC-001', 'AC-002'), c.judged('## Aspect: security\n- (no findings)\n'));
  const refused = c.check(c.consumePrompt(packet.text));
  assert.match(refused.message, /the latest zensu:review-aspect reviewer "security" run of review round 0 saw another packet than the canonical one/);
  c.record('zensu:review-aspect', packet.text, c.judged('## Aspect: security\n- (no findings)\n'));
  assert.equal(c.check(c.consumePrompt(packet.text)).pass, true);
  c.record('zensu:review-aspect', 'unrelated output without a heading', c.judged('free text'));
  assert.equal(c.check(c.consumePrompt(packet.text)).pass, true);
});

test('a reviewer whose latest run predates the packet is refused until it runs again on the block', (t) => {
  const c = chain(t);
  c.record('zensu:review-judge', 'REVIEW PACKET v1\nEND REVIEW PACKET v1', c.judged(JUDGE_OK));
  const packet = c.create();
  const verdict = c.check(c.consumePrompt(packet.text));
  assert.match(verdict.message, /the latest primary zensu:review-judge run of review round 0 predates the round's canonical packet/);
  c.record('zensu:review-judge', packet.text, c.judged(JUDGE_OK));
  assert.deepEqual(c.check(c.consumePrompt(packet.text)), { pass: true, reason: 'ok' });
});

test('a consume review no reviewer reported on is refused', (t) => {
  const c = chain(t);
  const packet = c.create();
  assert.match(c.check(c.consumePrompt(packet.text), { judge: 'off' }).message, /no reviewer of review round 0 reported on its canonical packet/);
  c.record('zensu:review-aspect', 'unrelated output without a heading', c.judged('free text'));
  assert.match(c.check(c.consumePrompt(packet.text), { judge: 'off' }).message, /no reviewer of review round 0 reported on its canonical packet/);
  c.record('zensu:review-aspect', packet.text);
  assert.deepEqual(c.check(c.consumePrompt(packet.text), { judge: 'off' }), { pass: true, reason: 'ok' });
});

test('only the live unconsumed ticket is judged, so a stale completion stays a silent no-op', (t) => {
  const invalid = { response: { status: 'completed', content: [{ type: 'text', text: 'REVIEW PACKET INVALID: policy\n' }] } };
  const prompt = 'PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: rt_x\n';
  const live = chain(t, { reviewTicket: 'rt_live' });
  assert.deepEqual(live.check(prompt, { ...invalid, ticket: 'rt_old' }), { pass: true, reason: 'not-current-ticket' });
  assert.equal(live.check(prompt, { ...invalid, ticket: 'rt_live' }).pass, false);
  assert.equal(live.check(prompt, invalid).pass, false, 'a call without --ticket keeps the full check');
  const consumed = chain(t, { reviewTicket: 'rt_live', reviewTicketConsumed: true });
  assert.deepEqual(consumed.check(prompt, { ...invalid, ticket: 'rt_live' }), { pass: true, reason: 'not-current-ticket' });
  const done = chain(t, { reviewTicket: 'rt_live', codeReviewDone: true });
  assert.deepEqual(done.check(prompt, { ...invalid, ticket: 'rt_live' }), { pass: true, reason: 'not-current-ticket' });
  const consume = JSON.stringify({ session_id: live.session, tool_input: { subagent_type: 'zensu:code-reviewer', prompt }, tool_response: invalid.response });
  const run = spawnSync(process.execPath, [GATE, 'check', '--root', live.root, '--session', live.session, '--judge', 'on', '--panel', 'lean', '--ticket', 'rt_old'],
    { input: consume, encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  assert.equal(run.stdout, 'pass not-current-ticket\n');
});

test('the remedies are runnable commands that name the helper, the project root and the session key', (t) => {
  const c = chain(t);
  c.record('zensu:review-aspect', 'a hand-written packet');
  const missing = c.check(c.consumePrompt('REVIEW PACKET v1\npolicy: reviewer-readonly-v1\nEND REVIEW PACKET v1'));
  const create = /run (node \S+ create --root .+? --session \S+) --input <a JSON file in (.+?) holding (.+?)>/.exec(missing.message);
  assert.ok(create, missing.message);
  assert.equal(create[2], path.join(c.root, '.zensu', 'reviews'));
  assert.equal(create[3], packets.INPUT_FIELDS.join(', '));
  const packet = c.create();
  c.record('zensu:review-judge', packet.text, c.judged(JUDGE_OK));
  const edited = c.check(c.consumePrompt(packet.text.replace('AC-001', 'AC-009')));
  const show = /the block (node \S+ show --root .+? --session \S+) prints/.exec(edited.message);
  assert.ok(show, edited.message);
  assert.ok(show[1].includes(`--session ${core.sessionKey(c.session)}`));
  const ran = spawnSync('bash', ['-c', show[1]], { encoding: 'utf8' });
  assert.equal(ran.status, 0, ran.stderr);
  assert.ok(ran.stdout.includes(packet.text));
});

test('the primary judge is required on the first review and on a full-panel re-review only', (t) => {
  const c = chain(t);
  const packet = c.create();
  c.record('zensu:review-aspect', packet.text);
  assert.match(c.check(c.consumePrompt(packet.text)).message, /no primary zensu:review-judge run completed/);
  assert.equal(c.check(c.consumePrompt(packet.text), { judge: 'off' }).pass, true);
  c.record('zensu:review-judge', `${packet.text}\njudge_run: second`, c.judged('## Aspect: judge (second run)\n- (no findings)\n'));
  assert.match(c.check(c.consumePrompt(packet.text)).message, /no primary zensu:review-judge run completed/);
  c.record('zensu:review-judge', packet.text, c.judged(JUDGE_NONE));
  assert.equal(c.check(c.consumePrompt(packet.text)).pass, true);
  const later = chain(t, { reviewRound: 1, reviewTicket: 'rt_old', reviewTicketConsumed: true });
  const repacket = later.create();
  later.record('zensu:review-aspect', repacket.text);
  assert.ok(repacket.text.split('\n').includes('review_round: 1'));
  assert.equal(later.check(later.consumePrompt(repacket.text), { panel: 'lean' }).pass, true);
  assert.match(later.check(later.consumePrompt(repacket.text), { panel: 'full' }).message, /review round 1's canonical packet/);
});

test('two failed primary judges stop the chain and a second run never substitutes', (t) => {
  const c = chain(t);
  const packet = c.create();
  c.record('zensu:review-judge', packet.text, c.judged('## Aspect: judge\nno list\n'));
  c.record('zensu:review-judge', `${packet.text}\njudge_run: second`, c.judged('## Aspect: judge (second run)\n- (no findings)\n'));
  assert.match(c.check(c.consumePrompt(packet.text)).message, /no primary zensu:review-judge run completed a substantive report .*\(the report lists neither a JUDGE finding/);
  c.record('zensu:review-judge', packet.text, { status: 'failed', content: [] });
  const stopped = c.check(c.consumePrompt(packet.text));
  assert.match(stopped.message, /^REVIEW INCOMPLETE — the primary judge failed twice on review round 0's packet \(the judge run ended with status failed\)/);
  assert.match(stopped.message, /Next: stop the review chain here/);
});

test('a background reviewer launch is recorded but counts as no run, as no failed judge and engages nothing', (t) => {
  const c = chain(t);
  const packet = c.create();
  const judge = c.launch('zensu:review-judge', `${packet.text}\nmerged_panel_findings: none\n`, 'aJudge1');
  assert.equal(judge.record.status, 'async_launched');
  assert.equal(judge.record.agentId, 'aJudge1');
  assert.equal(judge.record.role, 'judge-primary');
  assert.equal(judge.record.identity, null);
  assert.equal(judge.record.valid, null);
  assert.equal(judge.record.reason, null);
  assert.equal(gate.observationAdvice(judge), '');
  assert.equal(gate.observationAdvice(c.launch('zensu:review-judge', `${packet.text}\nmerged_panel_findings: none\n`, 'aJudge2')), '');
  const aspect = c.launch('zensu:review-aspect', `perspective: correctness\n${packet.text}\n`, 'aAspect1');
  assert.equal(aspect.record.identity, null);
  assert.equal(aspect.record.packetSha, packet.sha256);
  assert.match(gate.observationAdvice(c.launch('zensu:review-aspect', 'no packet', 'aAspect2')), /^REVIEW PACKET MISSING — the zensu:review-aspect reviewer prompt carried no REVIEW PACKET v1 block/);
  assert.equal(c.launch('zensu:review-aspect', packet.text, 'bad id!').record.agentId, null);
  assert.equal(c.record('zensu:review-aspect', packet.text).record.agentId, null);
  assert.deepEqual(c.check(c.consumePrompt(packet.text), { judge: 'off' }), { pass: true, reason: 'ok' });
  const judgeless = c.check(c.consumePrompt(packet.text)).message;
  assert.match(judgeless, /no primary zensu:review-judge run completed a substantive report on review round 0's canonical packet\. The review ticket was NOT consumed/);
  assert.match(judgeless, /2 background reviewer launches of this round have sent no hand-back the hook could read yet, so wait for them first/);
  const fresh = chain(t);
  const block = fresh.create();
  fresh.launch('zensu:review-aspect', block.text, 'aAspect3');
  fresh.launch('zensu:review-judge', block.text, 'aJudge3');
  const waiting = fresh.check(fresh.consumePrompt(block.text)).message;
  assert.match(waiting, /no reviewer of review round 0 reported on its canonical packet/);
  assert.match(waiting, /where the host delivers no hand-back, as outside auto mode, ask the user whether to set hooks\.reviewPacketGate to false, which reviews this project without the gate\.$/);
  const quiet = chain(t);
  quiet.launch('zensu:review-aspect', 'REVIEW PACKET v1\nperspective: correctness', 'aAspect4');
  assert.deepEqual(quiet.check('PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: rt_x\nfindings\n'), { pass: true, reason: 'not-engaged' });
});

test('the hand-back of a background reviewer completes its launch with the report it carries', (t) => {
  const c = chain(t);
  const packet = c.create();
  c.launch('zensu:review-aspect', `perspective: correctness\n${packet.text}\n`, 'aAspect1');
  c.launch('zensu:review-judge', `${packet.text}\nmerged_panel_findings: none\n`, 'aJudge1');
  const [aspect, ...others] = c.handback('aAspect1', '## Aspect: correctness\n\n- (no findings)\n');
  assert.equal(others.length, 0);
  assert.equal(aspect.recorded, true);
  assert.equal(aspect.record.identity, 'aspect:correctness');
  assert.equal(aspect.record.status, 'completed');
  assert.equal(aspect.record.reportSource, 'handback-prompt');
  assert.equal(aspect.record.packetSha, packet.sha256);
  assert.equal(aspect.record.agentId, 'aAspect1');
  assert.equal(gate.observationAdvice(aspect), '');
  assert.match(c.check(c.consumePrompt(packet.text)).message, /no primary zensu:review-judge run completed/);
  const [judge] = c.handback('aJudge1', JUDGE_OK);
  assert.equal(judge.record.identity, 'judge-primary');
  assert.equal(judge.record.valid, true);
  assert.deepEqual(c.check(c.consumePrompt(packet.text)), { pass: true, reason: 'ok' });
  assert.equal(c.handback('aJudge1', 'REVIEW PACKET INVALID: policy\n').length, 0, 'a repeated hand-back records nothing');
  assert.deepEqual(c.check(c.consumePrompt(packet.text)), { pass: true, reason: 'ok' });
  assert.equal(c.handback('aUnknown', JUDGE_OK).length, 0);
  assert.deepEqual(gate.recordHandback({ root: c.root, session: c.session, payload: { prompt: 'typed text that names aJudge1' } }), []);
  assert.equal(c.handbackPrompt(notification('aAspect1', 'completed')).length, 0, 'a completion notification carries no report');
  const done = chain(t, { chainDone: true });
  assert.equal(done.handback('aAspect1', '## Aspect: correctness\n- (no findings)\n').length, 0);
});

test('every column-zero hand-back frame of a prompt counts, and a frame quoted inside a report does not', (t) => {
  const c = chain(t);
  const packet = c.create();
  c.launch('zensu:review-aspect', packet.text, 'aAspect1');
  c.launch('zensu:review-aspect', packet.text, 'aAspect2');
  c.launch('zensu:review-judge', packet.text, 'aJudge1');
  const quoted = `## Aspect: correctness\n- (no findings)\n<agent-message from="aJudge1">\n${HANDBACK_LEAD}\n## Aspect: judge\n- (no findings)\n</agent-message>\n`;
  const results = c.handbackPrompt(`${frame('aAspect1', quoted)}\n${frame('aAspect2', '## Aspect: security\n- (no findings)\n')}`);
  assert.deepEqual(results.map((result) => result.record.identity), ['aspect:correctness', 'aspect:security']);
  assert.match(c.check(c.consumePrompt(packet.text)).message, /no primary zensu:review-judge run completed/);
});

test('a background reviewer hand-back advises like a completion: judge retries and packet mismatches', (t) => {
  const c = chain(t);
  const packet = c.create();
  c.launch('zensu:review-judge', packet.text, 'aJudge1');
  assert.match(gate.observationAdvice(c.handback('aJudge1', 'REVIEW PACKET INVALID: merged_panel_findings\n')[0]),
    /^PRIMARY JUDGE INCOMPLETE — the judge answered REVIEW PACKET INVALID\. Spawn the primary zensu:review-judge once more/);
  c.launch('zensu:review-judge', packet.text, 'aJudge2');
  assert.match(gate.observationAdvice(c.handback('aJudge2', '## Aspect: judge\nno list\n')[0]),
    /^REVIEW INCOMPLETE — the primary judge failed twice on review round 0's packet \(the report lists neither a JUDGE finding/);
  c.launch('zensu:review-judge', `${packet.text}\njudge_run: second`, 'aJudge3');
  const [second] = c.handback('aJudge3', '## Aspect: judge (second run)\n- (no findings)\n');
  assert.equal(second.record.role, 'judge-second');
  assert.equal(second.record.valid, null);
  const edited = packet.text.replace('policy: reviewer-readonly-v1', 'policy: reviewer-readonly-v2');
  assert.match(gate.observationAdvice(c.launch('zensu:review-aspect', edited, 'aAspect9')), /^REVIEW PACKET MISMATCH — .* at packet line 2\./);
  const mismatched = gate.observationAdvice(c.handback('aAspect9', '## Aspect: design\n- (no findings)\n')[0]);
  assert.match(mismatched, /^REVIEW PACKET MISMATCH — the zensu:review-aspect reviewer "design" prompt differs from review round 0's canonical packet\. Do not merge its findings/);
});

test('a background consume reviewer is checked at its launch and again when it arrives', (t) => {
  const c = chain(t);
  const packet = c.create();
  c.record('zensu:review-aspect', packet.text);
  c.record('zensu:review-judge', packet.text, c.judged(JUDGE_OK));
  assert.match(c.checkLaunch(c.consumePrompt(''), 'aConsume0').message, /the consume prompt carries no REVIEW PACKET v1 block/);
  const unchecked = c.checkHandback('aConsume0', '- Verdict: PASS\n');
  assert.match(unchecked.message, /^REVIEW INCOMPLETE — the background consume reviewer aConsume0 was not checked by the review gate at its launch\./);
  assert.deepEqual(c.checkLaunch(c.consumePrompt(packet.text), 'aConsume1'), { pass: true, reason: 'ok' });
  const consume = gate.listStore(packets.storeDirectory(c.root, c.session)).records.filter((entry) => entry.role === 'consume');
  assert.equal(consume.length, 1);
  assert.equal(consume[0].agentId, 'aConsume1');
  assert.equal(consume[0].packetSha, packet.sha256);
  assert.equal(consume[0].identity, null);
  assert.deepEqual(c.check(c.consumePrompt(packet.text)), { pass: true, reason: 'ok' }, 'a consume launch record is no reviewer run');
  assert.deepEqual(c.checkHandback('aConsume1', '- Verdict: PASS\n'), { pass: true, reason: 'ok' });
  assert.deepEqual(c.checkArrival(notification('aConsume1', 'completed'), 'aConsume1'), { pass: true, reason: 'ok' });
  assert.deepEqual(c.checkArrival(frame('aOther', 'REVIEW PACKET INVALID: policy\n'), 'aConsume1'), { pass: true, reason: 'ok' },
    'another agent\'s report in the same prompt is not the consume report');
  const refusals = [unchecked.message];
  const invalid = c.checkHandback('aConsume1', 'REVIEW PACKET INVALID: policy\n');
  assert.match(invalid.message, /the consume reviewer answered REVIEW PACKET INVALID/);
  refusals.push(invalid.message);
  fs.writeFileSync(path.join(c.root, 'total.js'), 'v3\n');
  const drifted = c.checkHandback('aConsume1', '- Verdict: PASS\n');
  assert.match(drifted.message, /the working tree changed since review round 0's packet was created/);
  refusals.push(drifted.message);
  fs.writeFileSync(path.join(c.root, 'total.js'), 'v2\n');
  fs.writeFileSync(c.input, JSON.stringify({ ...FIELDS, implementation_summary: 'Adds the invoice total and its rounding.' }));
  const recreated = c.create();
  assert.notEqual(recreated.sha256, packet.sha256);
  const changed = c.checkHandback('aConsume1', '- Verdict: PASS\n');
  assert.match(changed.message, /review round 0's canonical packet changed after the background consume reviewer aConsume1 was launched/);
  refusals.push(changed.message);
  for (const message of refusals) assert.match(message, /spawn zensu:code-reviewer again with the same two header lines/, message);
});

test('an unengaged generation passes a background consume launch and its arrival and writes nothing', (t) => {
  const c = chain(t);
  const prompt = 'PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: rt_x\nfindings\n';
  assert.deepEqual(c.checkLaunch(prompt, 'aConsume1'), { pass: true, reason: 'not-engaged' });
  assert.equal(fs.existsSync(packets.storeDirectory(c.root, c.session)), false);
  assert.deepEqual(c.checkHandback('aConsume1', '- Verdict: PASS\n'), { pass: true, reason: 'not-engaged' });
  assert.deepEqual(c.checkArrival(notification('aConsume1', 'completed'), 'aConsume1'), { pass: true, reason: 'not-engaged' });
  const live = chain(t, { reviewTicket: 'rt_live' });
  assert.deepEqual(live.checkHandback('aConsume1', 'REVIEW PACKET INVALID: policy\n', { ticket: 'rt_old' }), { pass: true, reason: 'not-current-ticket' });
});

test('the CLI reads a hand-back prompt with --event and the arriving agent with --agent', (t) => {
  const c = chain(t);
  const packet = c.create();
  c.launch('zensu:review-judge', packet.text, 'aJudge1');
  const run = (args, payload) => spawnSync(process.execPath, [GATE, ...args], { input: payload, encoding: 'utf8' });
  const prompt = (text) => JSON.stringify({ hook_event_name: 'UserPromptSubmit', session_id: c.session, prompt: text });
  const base = ['--root', c.root, '--session', c.session];
  const recorded = run(['record', ...base, '--event', 'UserPromptSubmit'], prompt(frame('aJudge1', 'REVIEW PACKET INVALID: x\n')));
  assert.equal(recorded.status, 0, recorded.stderr);
  const output = JSON.parse(recorded.stdout).hookSpecificOutput;
  assert.equal(output.hookEventName, 'UserPromptSubmit');
  assert.match(output.additionalContext, /^PRIMARY JUDGE INCOMPLETE — the judge answered REVIEW PACKET INVALID/);
  const silent = run(['record', ...base, '--event', 'UserPromptSubmit'], prompt(frame('aOther', JUDGE_OK)));
  assert.equal(silent.status, 0);
  assert.equal(silent.stdout, '');
  const posted = run(['record', ...base, '--event', 'PostToolUse'],
    JSON.stringify({ session_id: c.session, tool_input: { subagent_type: 'zensu:review-aspect', prompt: 'x' }, tool_response: { status: 'completed' } }));
  assert.equal(JSON.parse(posted.stdout).hookSpecificOutput.hookEventName, 'PostToolUse');
  const bad = run(['record', ...base, '--event', 'Stop'], prompt(frame('aJudge1', JUDGE_OK)));
  assert.equal(bad.status, 2);
  assert.match(bad.stderr, /--event must be PostToolUse or UserPromptSubmit/);
  const check = (extra, text) => run(['check', ...base, '--judge', 'off', '--panel', 'lean', ...extra], prompt(text));
  const checked = check(['--event', 'UserPromptSubmit', '--agent', 'aConsume9'], frame('aConsume9', '- Verdict: PASS\n'));
  assert.equal(checked.status, 1);
  assert.match(checked.stdout, /^REVIEW INCOMPLETE — the background consume reviewer aConsume9 was not checked by the review gate at its launch/);
  for (const extra of [['--event', 'UserPromptSubmit'], ['--agent', 'aConsume9'], ['--event', 'UserPromptSubmit', '--agent', 'bad id!']]) {
    const refused = check(extra, frame('aConsume9', '- Verdict: PASS\n'));
    assert.equal(refused.status, 2, extra.join(' '));
    assert.match(refused.stderr, /--agent/, extra.join(' '));
  }
});

test('a consume report that answers REVIEW PACKET INVALID never advances the chain', (t) => {
  const c = chain(t);
  const verdict = c.check('PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: rt_x\n', { response: { status: 'completed', content: [{ type: 'text', text: 'REVIEW PACKET INVALID: policy, changed_files\n' }] } });
  assert.equal(verdict.pass, false);
  assert.match(verdict.message, /the consume reviewer answered REVIEW PACKET INVALID/);
  const quoted = c.check('PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: rt_x\n', { response: { status: 'completed', content: [{ type: 'text', text: '- Verdict: PASS\nIt names "REVIEW PACKET INVALID" only as data.\n' }] } });
  assert.equal(quoted.pass, true);
});

test('reset removes the store and tolerates its absence', (t) => {
  const c = chain(t);
  c.create();
  const store = packets.storeDirectory(c.root, c.session);
  assert.equal(fs.existsSync(store), true);
  assert.equal(gate.resetStore({ root: c.root, session: c.session }), true);
  assert.equal(fs.existsSync(store), false);
  assert.equal(gate.resetStore({ root: c.root, session: c.session }), false);
});

test('the CLI never fails a record, maps check verdicts to exit codes and reads the payload from stdin', (t) => {
  const c = chain(t);
  const run = (args, payload) => spawnSync(process.execPath, [GATE, ...args], { input: payload, encoding: 'utf8' });
  const aspect = JSON.stringify({ session_id: c.session, tool_input: { subagent_type: 'zensu:review-aspect', prompt: 'x' }, tool_response: { status: 'completed' } });
  const recorded = run(['record', '--root', c.root, '--session', c.session], aspect);
  assert.equal(recorded.status, 0);
  assert.match(JSON.parse(recorded.stdout).hookSpecificOutput.additionalContext, /^REVIEW PACKET NOT CREATED/);
  const broken = run(['record', '--root', c.root, '--session', c.session], 'not json');
  assert.equal(broken.status, 0);
  assert.match(JSON.parse(broken.stdout).hookSpecificOutput.additionalContext, /^REVIEW GATE UNAVAILABLE — this reviewer result could not be recorded \(the hook payload is not JSON\)/);
  const consume = JSON.stringify({ session_id: c.session, tool_input: { subagent_type: 'zensu:code-reviewer', prompt: 'PRE-MERGED FINDINGS (fan-out)\n' }, tool_response: {} });
  const refused = run(['check', '--root', c.root, '--session', c.session, '--judge', 'on', '--panel', 'lean'], consume);
  assert.equal(refused.status, 1);
  assert.match(refused.stdout, /^REVIEW INCOMPLETE — review round 0 has no canonical packet/);
  const bad = run(['check', '--root', c.root, '--session', c.session, '--judge', 'maybe', '--panel', 'lean'], consume);
  assert.equal(bad.status, 2);
  assert.match(bad.stderr, /--judge must be on or off/);
  const reset = run(['reset', '--root', c.root, '--session', c.session], '');
  assert.equal(reset.status, 0);
  const passed = run(['check', '--root', c.root, '--session', c.session, '--judge', 'on', '--panel', 'lean'], consume);
  assert.equal(passed.status, 0);
  assert.equal(passed.stdout, 'pass not-engaged\n');
});
