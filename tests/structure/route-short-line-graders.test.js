'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const EVAL = path.join(ROOT, 'evals', 'route-short-line-reaction');
const envelope = require(path.join(EVAL, 'lib', 'envelope.js'));
const probe = require(path.join(EVAL, 'lib', 'decision-probe.js'));

const ROUTE_QUESTION = 'Run the Zensu workflow for this change? Yes — Zensu workflow | No — implement directly';
const COMPLETE_ROUTE_QUESTION = `${ROUTE_QUESTION} | A Yes is remembered for the rest of this session, later approved plans included, through one Bash call you may be asked to allow. A No decides this request only and is not remembered. /zensu:delivery-route changes the session route.`;
const TRIAGE = 'Is the code already built? Is there a plan or spec document? Does the plan hold unbuilt items?';
const ATTESTED = { init_git: true, tracked_clean: true };
const LIVE = { root: '/plugin', version: '0.25.0', silent_hooks: 6, leaks: 0, control_chars: 5690 };
const CONTROL = { route_source: 'none', hook: '', shape: 'none', field: 'n/a', blocks: [], live: LIVE };
const VERDICTS = ['skill:zensu:tdd', 'ask', 'edit', 'none', 'delegate', 'plan'];

function output(spec) {
  const s = spec || {};
  const lines = [];
  for (const b of s.blocks || []) {
    if (b.text !== undefined) lines.push('[assistant_text]', b.text);
    else if (b.use) lines.push(`[tool_use: ${b.use}] id=${b.id} input=${JSON.stringify(b.input || {})}`);
    else lines.push(`[tool_result: ${b.result}] id=${b.id} is_error=${b.error === true}`, b.summary || 'done');
  }
  const headers = s.headers === undefined ? 1 : s.headers;
  for (let i = 0; i < headers; i += 1) lines.push('', envelope.HEADER);
  if (s.attestation !== null) lines.push(`${envelope.ATTESTATION_PREFIX}${JSON.stringify(s.attestation || ATTESTED)}`);
  for (const r of s.inject || []) lines.push(`${envelope.HOOK_PREFIX}inject ${JSON.stringify(r)}`);
  (s.probe || []).forEach((r, i) => lines.push(`${envelope.HOOK_PREFIX}probe ${JSON.stringify({ seq: i + 1, ...r })}`));
  if (s.capture !== null) lines.push(`${envelope.CAPTURE_PREFIX}${JSON.stringify(s.capture || CONTROL)}`);
  return lines.join('\n');
}

function grade(name, out, vars) {
  return require(path.join(EVAL, 'assertions', `${name}.js`))(out, { vars: vars || {} });
}

function passes(name, out, vars) {
  return grade(name, out, vars).pass;
}

function scenarioVars(text) {
  const lines = text.split('\n');
  const start = lines.indexOf('vars:');
  const vars = {};
  if (start < 0) return vars;
  for (const line of lines.slice(start + 1)) {
    const m = /^ {2}([a-z_]+): (.*)$/.exec(line);
    if (!m) break;
    vars[m[1]] = m[2].startsWith('"') ? JSON.parse(m[2]) : m[2];
  }
  return vars;
}

function scenarioFiles(config) {
  return [...fs.readFileSync(path.join(EVAL, config), 'utf8').matchAll(/file:\/\/(scenarios\/\S+\.yaml)/g)].map((m) => m[1]);
}

function skillRun(text) {
  return output({
    blocks: [{ text }, { use: 'Skill', id: 's1', input: { skill: 'zensu:tdd' } }, { result: 'Skill', id: 's1', error: true }, { text: 'I would run the Zensu workflow next.' }],
    probe: [{ id: 's1', tool: 'Skill', decision: 'END', skill: 'zensu:tdd' }],
  });
}

function tempDir(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

test('the envelope constants are the ones the wrapper, the renderer and the provider print', () => {
  const wrapper = fs.readFileSync(path.join(ROOT, 'scripts', 'claude-promptfoo-wrapper.sh'), 'utf8');
  const renderer = fs.readFileSync(path.join(ROOT, 'scripts', 'claude-stream-render.js'), 'utf8');
  const provider = fs.readFileSync(path.join(EVAL, 'provider.sh'), 'utf8');
  assert.ok(wrapper.includes(`printf '\\n${envelope.HEADER}\\n'`));
  assert.ok(wrapper.includes('`' + envelope.ATTESTATION_PREFIX + '${JSON.stringify(value)}'));
  assert.ok(provider.includes(`printf '${envelope.HOOK_PREFIX}%s\\n' "$line"`));
  assert.ok(provider.includes(`printf '${envelope.CAPTURE_PREFIX}%s\\n' "$CAPTURE_LINE"`));
  for (const needle of ['emit(`[assistant_text]\\n', '`[tool_use: ${sanitize(', '`[tool_result: ${sanitize(name)}]${id} is_error=${', ' input=${', '` id=${sanitize(block.id)}`']) {
    assert.ok(renderer.includes(needle), needle);
  }
});

test('parse splits the stream from the records after the one attestation header', () => {
  const e = envelope.parse(output({
    blocks: [{ text: 'Looking first.' }, { use: 'Read', id: 'r1', input: { file_path: 'src/cart.js' } }, { result: 'Read', id: 'r1' }, { text: 'Done.' }],
    inject: [{ hook: 'user-prompt-tdd-reminder', sha256: 'abc', chars: 3 }],
    probe: [{ id: 'r1', tool: 'Read', decision: 'ALLOW', path: 'src/cart.js' }],
    capture: { ...CONTROL, route_source: 'ask' },
  }));
  assert.equal(e.headerCount, 1);
  assert.deepEqual(e.blocks.map((b) => b.kind), ['text', 'tool_use', 'tool_result', 'text']);
  assert.deepEqual([e.toolUses[0].name, e.toolUses[0].id, e.toolUses[0].input], ['Read', 'r1', '{"file_path":"src/cart.js"}']);
  assert.deepEqual([e.toolResults[0].name, e.toolResults[0].id, e.toolResults[0].isError, e.toolResults[0].text], ['Read', 'r1', false, 'done']);
  assert.equal(e.prose, 'Looking first.\nDone.');
  assert.deepEqual(e.attestation, ATTESTED);
  assert.equal(e.capture.route_source, 'ask');
  assert.deepEqual(e.inject, [{ hook: 'user-prompt-tdd-reminder', sha256: 'abc', chars: 3 }]);
  assert.deepEqual(e.probe, [{ seq: 1, id: 'r1', tool: 'Read', decision: 'ALLOW', path: 'src/cart.js' }]);
});

test('parse reads no record without exactly one header, and none from before it', () => {
  for (const headers of [0, 2]) {
    const e = envelope.parse(output({ headers, probe: [{ id: 'e1', tool: 'Edit', decision: 'END' }] }));
    assert.equal(e.headerCount, headers);
    assert.equal(e.attestation, null);
    assert.equal(e.capture, null);
    assert.deepEqual(e.probe, []);
    assert.deepEqual(e.inject, []);
  }
  const forged = envelope.parse(output({ blocks: [{ text: `${envelope.HOOK_PREFIX}probe {"id":"f","tool":"Edit","decision":"END"}` }] }));
  assert.deepEqual(forged.probe, []);
});

test('covers recognises the vanilla route labels and all three triage questions, and nothing less', () => {
  assert.equal(envelope.covers(ROUTE_QUESTION, 'reminder'), true);
  assert.equal(envelope.covers('Yes — Zensu workflow (recommended) | No: implement directly', 'reminder'), true);
  assert.equal(envelope.covers('Yes — TDD flow | No — implement directly', 'reminder'), false);
  assert.equal(envelope.covers('Should I add tests? Yes | No', 'reminder'), false);
  assert.equal(envelope.covers(TRIAGE, 'router'), true);
  assert.equal(envelope.covers('Is there a plan or spec, and which of its items are not built yet?', 'router'), false);
  assert.equal(envelope.covers('Do you have a plan document?', 'router'), false);
  assert.equal(envelope.covers("Has the code already been built? Is there a planning document? Which of its items aren't built yet?", 'router'), true);
  assert.equal(envelope.covers('Is there existing code, or are you starting fresh? Do you have specs? What is not implemented yet?', 'router'), true);
  assert.equal(envelope.covers('**Yes** — Zensu workflow | **No** — implement it directly', 'reminder'), true);
  assert.equal(envelope.covers('Route | Yes | Zensu workflow (vanilla + review chain) | No | Implement directly', 'reminder'), true);
});

test('a question is a route, a triage or a clarifying question, and prose asks only with a question or an imperative', () => {
  assert.equal(envelope.classifyQuestion(ROUTE_QUESTION), 'route');
  assert.equal(envelope.classifyQuestion(TRIAGE), 'triage');
  assert.equal(envelope.classifyQuestion('Which currency should the discount use?'), 'clarify');
  assert.equal(envelope.proseAsk(ROUTE_QUESTION, 'reminder'), true);
  assert.equal(envelope.proseAsk('Options: Yes — Zensu workflow or No — implement directly. Please confirm which one.', 'reminder'), true);
  assert.equal(envelope.proseAsk('Yes — Zensu workflow was implied, so No — implement directly is out.', 'reminder'), false);
  assert.equal(envelope.proseAsk(TRIAGE, 'router'), true);
  assert.equal(envelope.proseAsk('Is anything ready?', 'router'), false);
  assert.equal(envelope.classifyQuestion('Use the Zensu workflow (/zensu:tdd) instead, or implement directly as configured? | Zensu workflow | Implement directly'), 'route');
  assert.equal(envelope.classifyQuestion('Should I skip TDD for this one?'), 'route');
  assert.equal(envelope.offersRoute('Add tests for the discount?'), false);
  assert.equal(envelope.proseAsk('Should I run this through the Zensu workflow, or implement it directly?', 'reminder'), true);
  assert.equal(envelope.proseAsk('Skipping TDD: route direct (hooks.defaultDeliveryRoute).\nShould I also add tests?', 'reminder'), false);
  assert.equal(envelope.proseAsk('I will implement it directly without the Zensu workflow.', 'reminder'), false);
});

test('the decisive action skips allowed calls, setup calls and clarifying questions', () => {
  const base = [
    { id: 'a', tool: 'Read', decision: 'ALLOW' },
    { id: 'b', tool: 'Bash', decision: 'SETUP', command: 'git worktree add x' },
    { id: 'c', tool: 'AskUserQuestion', decision: 'CONTINUE', question: 'Which currency?' },
  ];
  const cases = [
    [{ tool: 'Skill', decision: 'END', skill: 'zensu:tdd' }, 'skill:zensu:tdd'],
    [{ tool: 'AskUserQuestion', decision: 'CONTINUE', question: ROUTE_QUESTION }, 'ask'],
    [{ tool: 'AskUserQuestion', decision: 'CONTINUE', question: TRIAGE }, 'ask'],
    [{ tool: 'Edit', decision: 'END' }, 'edit'],
    [{ tool: 'Write', decision: 'END' }, 'edit'],
    [{ tool: 'Task', decision: 'END' }, 'delegate'],
    [{ tool: 'Agent', decision: 'END' }, 'delegate'],
    [{ tool: 'EnterPlanMode', decision: 'END' }, 'plan'],
    [{ tool: 'Bash', decision: 'END', command: 'npm test' }, 'other:Bash'],
  ];
  for (const [last, want] of cases) assert.equal(envelope.decisive([...base, { id: 'd', ...last }]), want, want);
  assert.equal(envelope.decisive(base), 'none');
  const at = envelope.decisiveAt([{ tool: 'AskUserQuestion', decision: 'CONTINUE', question: ROUTE_QUESTION }, { tool: 'Edit', decision: 'END' }], 1);
  assert.deepEqual([at.value, at.index], ['edit', 1]);
});

test('firstEnd keeps only what came before the result of the first denied call', () => {
  const e = envelope.parse(output({
    blocks: [{ text: 'Before.' }, { use: 'Skill', id: 's1' }, { result: 'Skill', id: 's1', error: true }, { text: 'After the deny.' }, { use: 'Edit', id: 'e1' }],
    probe: [{ id: 's1', tool: 'Skill', decision: 'END', skill: 'zensu:tdd' }, { id: 'e1', tool: 'Edit', decision: 'END' }],
  }));
  const cut = envelope.firstEnd(e);
  assert.equal(cut.prose, 'Before.');
  assert.deepEqual(cut.probe.map((r) => r.id), ['s1']);
  assert.equal(envelope.firstEnd({ ...e, probe: [{ id: '', tool: 'Edit', decision: 'END' }] }).prose, 'Before.\nAfter the deny.');
  const positional = envelope.firstEnd({ ...e, probe: [{ id: '', tool: 'Skill', decision: 'END', skill: 'zensu:tdd' }] });
  assert.equal(positional.prose, 'Before.');
  const allowed = [{ id: 'r', tool: 'Read', decision: 'ALLOW' }];
  assert.deepEqual(envelope.firstEnd({ ...e, probe: allowed }), { probe: allowed, prose: 'Before.\nAfter the deny.' });
});

test('pairs match tool calls to probe records by id, or by position and name when the probe has no ids', () => {
  const blocks = [{ use: 'Read', id: 'r1' }, { result: 'Read', id: 'r1' }, { use: 'Skill', id: 's1' }, { result: 'Skill', id: 's1', error: true }];
  const byId = envelope.parse(output({ blocks, probe: [{ id: 's1', tool: 'Skill', decision: 'END' }, { id: 'r1', tool: 'Read', decision: 'ALLOW' }] }));
  assert.deepEqual([...envelope.pairs(byId)].map(([u, r]) => [u.id, r.tool]), [['r1', 'Read'], ['s1', 'Skill']]);
  const byPosition = envelope.parse(output({ blocks, probe: [{ id: '', tool: 'Read', decision: 'ALLOW' }, { id: '', tool: 'Skill', decision: 'END' }] }));
  assert.deepEqual([...envelope.pairs(byPosition)].map(([u, r]) => [u.id, r.tool]), [['r1', 'Read'], ['s1', 'Skill']]);
  const misaligned = envelope.parse(output({ blocks, probe: [{ id: '', tool: 'Skill', decision: 'END' }, { id: '', tool: 'Read', decision: 'ALLOW' }] }));
  assert.equal(envelope.pairs(misaligned).size, 0);
  assert.equal(envelope.resultOf(byId, byId.toolUses[1]).isError, true);
});

test('openingLines skips the narration of a setup call and stops at the first other text', () => {
  const setup = [{ text: 'Creating a worktree first.' }, { use: 'Bash', id: 'b1' }, { result: 'Bash', id: 'b1', error: true }];
  const e = envelope.parse(output({
    blocks: [...setup, { text: 'Executing via /zensu:tdd (vanilla mode, route: x)' }, { use: 'Skill', id: 's1' }],
    probe: [{ id: 'b1', tool: 'Bash', decision: 'SETUP', command: 'git worktree add x' }, { id: 's1', tool: 'Skill', decision: 'END' }],
  }));
  assert.deepEqual(envelope.openingLines(e), ['Creating a worktree first.', 'Executing via /zensu:tdd (vanilla mode, route: x)']);
  const read = envelope.parse(output({
    blocks: [{ text: 'Let me look first.' }, { use: 'Read', id: 'r1' }, { result: 'Read', id: 'r1' }, { text: 'Executing.' }],
    probe: [{ id: 'r1', tool: 'Read', decision: 'ALLOW' }],
  }));
  assert.deepEqual(envelope.openingLines(read), ['Let me look first.']);
  assert.deepEqual(envelope.openingLines(envelope.parse(output({}))), []);
});

test('firstLine reads the first line without markdown emphasis or quoting', () => {
  assert.equal(envelope.firstLine('**Executing via /zensu:tdd (vanilla mode, route: hooks.defaultDeliveryRoute)**\nThen more.'), 'Executing via /zensu:tdd (vanilla mode, route: hooks.defaultDeliveryRoute)');
  assert.equal(envelope.firstLine('\n> `Skipping TDD: route direct (hooks.defaultDeliveryRoute)`'), 'Skipping TDD: route direct (hooks.defaultDeliveryRoute)');
  assert.equal(envelope.firstLine('# Plan\nbody'), 'Plan');
  assert.equal(envelope.firstLine(''), '');
});

test('the probe decides by tool and, for Bash, by command', () => {
  const cases = [
    ['Read', {}, 'ALLOW'],
    ['ToolSearch', {}, 'ALLOW'],
    ['TodoWrite', {}, 'ALLOW'],
    ['Bash', { command: 'ls -la src' }, 'ALLOW'],
    ['Bash', { command: 'cat src/cart.js' }, 'ALLOW'],
    ['Bash', { command: 'git status --short' }, 'ALLOW'],
    ['Bash', { command: 'git --no-pager log --oneline -5' }, 'ALLOW'],
    ['Bash', { command: 'git diff --output=patch.txt' }, 'END'],
    ['Bash', { command: 'git diff --ext-diff' }, 'END'],
    ['Bash', { command: 'ls; rm -rf src' }, 'END'],
    ['Bash', { command: 'cat src/cart.js > copy.js' }, 'END'],
    ['Bash', { command: 'cat $(echo src/cart.js)' }, 'END'],
    ['Bash', { command: 'lsof -i' }, 'END'],
    ['Bash', { command: 'git status && git commit -am x' }, 'END'],
    ['Bash', { command: 'git worktree add .claude/worktrees/x -b claude/x' }, 'SETUP'],
    ['Bash', { command: 'git checkout -b feature' }, 'SETUP'],
    ['Bash', { command: 'git switch -c feature' }, 'SETUP'],
    ['Bash', { command: 'git commit -am x' }, 'END'],
    ['Bash', { command: 'npm test' }, 'ALLOW'],
    ['Bash', { command: 'node --test src/' }, 'ALLOW'],
    ['Bash', { command: 'grep -n cartTotal src/cart.js' }, 'ALLOW'],
    ['Bash', { command: 'find src -name "*.js"' }, 'ALLOW'],
    ['Bash', { command: 'cd src' }, 'ALLOW'],
    ['Bash', { command: 'git status && git log --oneline -3' }, 'ALLOW'],
    ['Bash', { command: 'find . -delete' }, 'END'],
    ['Bash', { command: 'npm test -- --watch' }, 'END'],
    ['Bash', { command: 'rg -n x --pre cat' }, 'END'],
    ['Bash', { command: 'echo hi' }, 'END'],
    ['Bash', { command: 'git worktree add x -b y && cd x' }, 'SETUP'],
    ['Bash', { command: 'git -C . worktree add x' }, 'SETUP'],
    ['Bash', { command: 'git -C . status' }, 'ALLOW'],
    ['Bash', { command: 'git status\ngit checkout -b feat' }, 'END'],
    ['Bash', { command: 'pwd\nnode --test src/' }, 'END'],
    ['Bash', { command: 'cat\nrm -rf ~/x' }, 'END'],
    ['Bash', { command: 'ls src 2>/dev/null' }, 'ALLOW'],
    ['Bash', { command: 'node --test src/ 2>&1 | tail -5' }, 'ALLOW'],
    ['Bash', { command: 'cat src/cart.js | head -40' }, 'ALLOW'],
    ['Bash', { command: 'ls 2>/dev/nullx' }, 'END'],
    ['Bash', { command: 'tail -f log' }, 'END'],
    ['Bash', { command: 'tail --follow=name log' }, 'END'],
    ['WebSearch', {}, 'ALLOW'],
    ['LSP', {}, 'ALLOW'],
    ['mcp__server__tool', {}, 'END'],
    ['Bash', {}, 'END'],
    ['EnterWorktree', {}, 'SETUP'],
    ['AskUserQuestion', {}, 'CONTINUE'],
    ['Skill', { skill: 'zensu:tdd' }, 'END'],
    ['Edit', {}, 'END'],
    ['Write', {}, 'END'],
    ['Task', {}, 'END'],
    ['EnterPlanMode', {}, 'END'],
    ['', {}, 'END'],
  ];
  for (const [tool, input, want] of cases) assert.equal(probe.decide(tool, input), want, `${tool} ${JSON.stringify(input)}`);
  assert.deepEqual(['ALLOW', 'CONTINUE', 'SETUP', 'END'].map(probe.reasonFor), [probe.END_REASON, probe.CONTINUE_REASON, probe.SETUP_REASON, probe.END_REASON]);
});

test('the probe flattens a question into one bounded line', () => {
  const question = { questions: [{ header: 'Route', question: 'Run it?', options: [{ label: 'Yes', description: 'Workflow' }, { label: 'No' }] }] };
  assert.equal(probe.flattenQuestion(question), 'Route | Run it? | Yes | Workflow | No');
  assert.equal(probe.flattenQuestion({ question: 'Legacy?' }), 'Legacy?');
  assert.equal(probe.flattenQuestion({}), '');
  const long = probe.flattenQuestion({ question: 'x'.repeat(5000) });
  assert.equal(long.length, 4001);
  assert.ok(long.endsWith('…'));
});

test('the probe hook logs every call in order and denies with the reason of its decision', () => {
  const dir = tempDir('route-eval-probe-');
  try {
    const call = (input) => spawnSync(process.execPath, [path.join(EVAL, 'lib', 'decision-probe.js')], {
      input, env: { ...process.env, ZENSU_ROUTE_EVAL_DIR: dir }, encoding: 'utf8',
    });
    const allow = call(JSON.stringify({ tool_name: 'Read', tool_use_id: 't1', tool_input: { file_path: 'src/cart.js' } }));
    assert.deepEqual([allow.status, allow.stdout], [0, '']);
    const denied = [
      [{ tool_name: 'Skill', tool_use_id: 't2', tool_input: { skill: 'zensu:tdd' } }, probe.END_REASON],
      [{ tool_name: 'AskUserQuestion', tool_use_id: 't3', tool_input: { questions: [{ question: 'Run it?' }] } }, probe.CONTINUE_REASON],
      [{ tool_name: 'Bash', tool_use_id: 't4', tool_input: { command: 'git worktree add x' } }, probe.SETUP_REASON],
    ];
    for (const [payload, reason] of denied) {
      const r = call(JSON.stringify(payload));
      assert.equal(r.status, 0);
      assert.deepEqual(JSON.parse(r.stdout), { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason } });
    }
    const malformed = call('not json');
    assert.equal(JSON.parse(malformed.stdout).hookSpecificOutput.permissionDecisionReason, probe.END_REASON);
    const file = path.join(dir, 'hook.log');
    const log = fs.readFileSync(file, 'utf8').trim().split('\n').map((line) => {
      assert.ok(line.startsWith('probe '));
      return JSON.parse(line.slice('probe '.length));
    });
    assert.deepEqual(log.map((r) => [r.seq, r.id, r.tool, r.decision]), [
      [1, 't1', 'Read', 'ALLOW'], [2, 't2', 'Skill', 'END'], [3, 't3', 'AskUserQuestion', 'CONTINUE'], [4, 't4', 'Bash', 'SETUP'], [5, '', '', 'END'],
    ]);
    assert.deepEqual([log[0].path, log[1].skill, log[2].question, log[3].command], ['src/cart.js', 'zensu:tdd', 'Run it?', 'git worktree add x']);
    if (process.platform !== 'win32') assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('the inject hook delivers the captured block and records its digest', () => {
  const dir = tempDir('route-eval-inject-');
  try {
    const text = 'Zensu planning notice (the full notice given earlier in this context still applies): ask first.';
    fs.writeFileSync(path.join(dir, 'inject.txt'), text);
    const run = (env) => spawnSync(process.execPath, [path.join(EVAL, 'lib', 'inject-context.js')], {
      input: '{}', env: { ...process.env, ZENSU_ROUTE_EVAL_DIR: '', ZENSU_ROUTE_EVAL_HOOK: '', ...env }, encoding: 'utf8',
    });
    const r = run({ ZENSU_ROUTE_EVAL_DIR: dir, ZENSU_ROUTE_EVAL_HOOK: 'user-prompt-intent-router' });
    assert.equal(r.status, 0);
    assert.deepEqual(JSON.parse(r.stdout), { hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: text } });
    const sha256 = crypto.createHash('sha256').update(text, 'utf8').digest('hex');
    assert.equal(fs.readFileSync(path.join(dir, 'hook.log'), 'utf8'), `inject ${JSON.stringify({ hook: 'user-prompt-intent-router', sha256, chars: text.length })}\n`);
    assert.equal(run({}).stdout, '');
    fs.rmSync(path.join(dir, 'inject.txt'));
    assert.equal(run({ ZENSU_ROUTE_EVAL_DIR: dir }).stdout, '');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('harness-attested requires one attestation, the immutable fixture, the scenario source and the silence proof', () => {
  const vars = { route_source: 'ask' };
  const capture = { ...CONTROL, route_source: 'ask' };
  assert.equal(passes('harness-attested', output({ capture }), vars), true);
  const failing = [
    output({ headers: 2, capture }),
    output({ attestation: null, capture }),
    output({ attestation: { init_git: false, tracked_clean: true }, capture }),
    output({ capture: null }),
    output({ capture: { ...capture, route_source: 'router' } }),
    output({ capture: { ...capture, live: { ...LIVE, leaks: 1 } } }),
    output({ capture: { ...capture, live: { ...LIVE, control_chars: 0 } } }),
    output({ capture: { ...capture, live: { ...LIVE, silent_hooks: 0 } } }),
    output({ capture: { ...capture, live: undefined } }),
  ];
  for (const out of failing) assert.equal(passes('harness-attested', out, vars), false);
});

test('harness-injection requires exactly the captured block with the scenario shape and field', () => {
  const capture = { ...CONTROL, route_source: 'ask', hook: 'user-prompt-tdd-reminder', shape: 'ask-short', field: 'ask', blocks: [{ sha256: 'abc', chars: 3 }] };
  const inject = [{ hook: 'user-prompt-tdd-reminder', sha256: 'abc', chars: 3 }];
  const vars = { route_source: 'ask', expected_shape: 'ask-short', expected_field: 'ask' };
  assert.equal(passes('harness-injection', output({ capture, inject }), vars), true);
  assert.equal(passes('harness-injection', output({ capture, inject: [] }), vars), false);
  assert.equal(passes('harness-injection', output({ capture, inject: [...inject, ...inject] }), vars), false);
  assert.equal(passes('harness-injection', output({ capture, inject: [{ ...inject[0], sha256: 'zzz' }] }), vars), false);
  assert.equal(passes('harness-injection', output({ capture, inject: [{ ...inject[0], hook: 'other' }] }), vars), false);
  assert.equal(passes('harness-injection', output({ capture: { ...capture, field: 'tdd (hooks.defaultDeliveryRoute)' }, inject }), vars), false);
  const controlVars = { route_source: 'none', expected_shape: 'none', expected_field: 'n/a' };
  assert.equal(passes('harness-injection', output({ capture: CONTROL }), controlVars), true);
  assert.equal(passes('harness-injection', output({ capture: CONTROL, inject }), controlVars), false);
});

test('harness-isolation requires an unchanged fixture and a probe record for every call that ran', () => {
  const read = [{ use: 'Read', id: 'r1' }, { result: 'Read', id: 'r1' }];
  assert.equal(passes('harness-isolation', output({ blocks: read, probe: [{ id: 'r1', tool: 'Read', decision: 'ALLOW' }] })), true);
  assert.equal(passes('harness-isolation', output({ blocks: read, probe: [{ id: '', tool: 'Read', decision: 'ALLOW' }] })), true);
  assert.equal(passes('harness-isolation', output({ blocks: [...read, { use: 'Edit', id: 'e1' }, { result: 'Edit', id: 'e1', error: true }], probe: [{ id: 'r1', tool: 'Read', decision: 'ALLOW' }] })), true);
  assert.equal(passes('harness-isolation', output({ blocks: [...read, { use: 'Edit', id: 'e1' }, { result: 'Edit', id: 'e1' }], probe: [{ id: 'r1', tool: 'Read', decision: 'ALLOW' }] })), false);
  assert.equal(passes('harness-isolation', output({ blocks: read, probe: [{ id: 'r9', tool: 'Read', decision: 'ALLOW' }] })), false);
  assert.equal(passes('harness-isolation', output({ attestation: { init_git: true, tracked_clean: false } })), false);
  assert.equal(passes('harness-isolation', output({ attestation: null })), false);
  assert.equal(passes('harness-isolation', output({ blocks: [{ use: 'Edit', id: 'e1' }, { result: 'Edit', id: 'e1', error: true }, { use: 'Skill', id: 's1' }, { result: 'Skill', id: 's1', error: true }] })), false);
});

test('first-decisive grades the first decisive action against the scenario allowlist', () => {
  const ask = { allowed_first: 'skill:zensu:tdd,ask', expected_hook: 'reminder' };
  assert.equal(passes('first-decisive', skillRun('Executing.'), ask), true);
  assert.equal(passes('first-decisive', output({ probe: [{ id: 'e1', tool: 'Edit', decision: 'END' }] }), ask), false);
  assert.equal(passes('first-decisive', output({ blocks: [{ text: ROUTE_QUESTION }] }), ask), true);
  assert.equal(passes('first-decisive', output({ blocks: [{ text: 'Done thinking.' }] }), ask), false);
  const control = { allowed_first: 'edit,none', expected_hook: '' };
  assert.equal(passes('first-decisive', output({ blocks: [{ text: ROUTE_QUESTION }] }), control), true);
  assert.equal(passes('first-decisive', skillRun('Executing.'), control), false);
  assert.equal(passes('first-decisive', skillRun('Executing.'), {}), false);
});

test('after-ask lets an unanswered route question end the run or start the workflow, never an edit', () => {
  const asked = { id: 'q', tool: 'AskUserQuestion', decision: 'CONTINUE', question: COMPLETE_ROUTE_QUESTION };
  assert.equal(passes('after-ask', output({ probe: [asked] })), true);
  assert.equal(passes('after-ask', output({ probe: [asked, { id: 's', tool: 'Skill', decision: 'END', skill: 'zensu:tdd' }] })), true);
  assert.equal(passes('after-ask', output({ probe: [asked, { id: 'e', tool: 'Edit', decision: 'END' }] })), false);
  assert.equal(passes('after-ask', output({ probe: [asked, { id: 'b', tool: 'Bash', decision: 'END', command: 'bash zensu-delivery-route.sh --tdd' }] })), false);
  assert.equal(passes('after-ask', output({ probe: [{ id: 'e', tool: 'Edit', decision: 'END' }] })), true);
});

test('no-record-command flags a route record and --tdd-begin, and nothing else', () => {
  const bash = (command) => output({ probe: [{ id: 'b', tool: 'Bash', decision: 'END', command }] });
  assert.equal(passes('no-record-command', bash('CLAUDE_PLUGIN_DATA=/d bash /p/hooks/lib/zensu-delivery-route.sh --tdd')), false);
  assert.equal(passes('no-record-command', bash('bash /p/hooks/lib/zensu-delivery-route.sh --direct')), false);
  assert.equal(passes('no-record-command', bash('bash /p/hooks/lib/zensu-log.sh --tdd-begin')), false);
  assert.equal(passes('no-record-command', bash('npm test -- --tdd-mode')), true);
  assert.equal(passes('no-record-command', bash('git status')), true);
});

test('route-question-complete scores a route question by its labels and disclosures', () => {
  const route = require(path.join(EVAL, 'assertions', 'route-question-complete.js'));
  assert.deepEqual(route.missing(COMPLETE_ROUTE_QUESTION), []);
  assert.equal(route.missing(ROUTE_QUESTION).length, 5);
  const viaTool = (question) => output({ probe: [{ id: 'q', tool: 'AskUserQuestion', decision: 'CONTINUE', question }] });
  assert.deepEqual([grade('route-question-complete', viaTool(COMPLETE_ROUTE_QUESTION)).pass, grade('route-question-complete', viaTool(COMPLETE_ROUTE_QUESTION)).score], [true, 1]);
  const partial = grade('route-question-complete', viaTool(ROUTE_QUESTION));
  assert.deepEqual([partial.pass, partial.score], [false, 2 / 7]);
  assert.equal(passes('route-question-complete', output({ blocks: [{ text: COMPLETE_ROUTE_QUESTION }] })), true);
  assert.equal(passes('route-question-complete', output({ blocks: [{ text: ROUTE_QUESTION }] })), false);
  assert.equal(passes('route-question-complete', skillRun('Executing.')), true);
  const reworded = "Run the Zensu workflow? **Yes** — Zensu workflow | **No** — implement it directly | A Yes is saved for the rest of the session, later approved plans included, through one Bash call. A No only affects this request and won't be remembered. /zensu:delivery-route changes it.";
  assert.deepEqual(route.missing(reworded), []);
  const requestOnly = route.NEEDLES.find(([name]) => name === 'a No decides this request only')[1];
  assert.deepEqual(["A No won't be remembered.", 'A No is not saved.', 'A No is final.'].map((t) => requestOnly.test(t)), [true, true, false]);
  const loose = viaTool('Use the Zensu workflow (/zensu:tdd), or implement directly? | Zensu workflow | Implement directly');
  assert.equal(passes('route-question-complete', loose), false);
});

test('status-line-exact requires the expected status as the opening line, setup narration aside', () => {
  const vars = { expected_status: 'Executing via /zensu:tdd (vanilla mode, route: hooks.defaultDeliveryRoute)' };
  assert.equal(passes('status-line-exact', skillRun('**Executing via /zensu:tdd (vanilla mode, route: hooks.defaultDeliveryRoute)**\nStarting.'), vars), true);
  const detour = (first, decision) => output({
    blocks: [{ text: first }, { use: 'Bash', id: 'b1' }, { result: 'Bash', id: 'b1', error: decision === 'SETUP' }, { text: 'Executing via /zensu:tdd (vanilla mode, route: hooks.defaultDeliveryRoute)' }, { use: 'Skill', id: 's1' }],
    probe: [{ id: 'b1', tool: 'Bash', decision, command: 'git worktree add x' }, { id: 's1', tool: 'Skill', decision: 'END' }],
  });
  assert.equal(passes('status-line-exact', detour('Creating a worktree first.', 'SETUP'), vars), true);
  assert.equal(passes('status-line-exact', detour('Checking the tree first.', 'ALLOW'), vars), false);
  assert.equal(passes('status-line-exact', skillRun('Executing via /zensu:tdd (vanilla mode, route: <the source the field names>)'), vars), false);
  assert.equal(passes('status-line-exact', skillRun('Let me look first.\nExecuting via /zensu:tdd (vanilla mode, route: hooks.defaultDeliveryRoute)'), vars), false);
  assert.equal(passes('status-line-exact', skillRun('Anything.'), { expected_status: '' }), false);
});

test('no-route-status flags a route status line on the first line', () => {
  const route = require(path.join(EVAL, 'assertions', 'no-route-status.js'));
  assert.equal(passes('no-route-status', output({ blocks: [{ text: 'I will add the parameter.' }] })), true);
  for (const prefix of route.PREFIXES) assert.equal(passes('no-route-status', output({ blocks: [{ text: `${prefix} (vanilla mode)` }] })), false);
});

test('no-route-question flags a route or triage question before the first denied call', () => {
  const reminder = { expected_hook: 'reminder' };
  const question = (q) => ({ id: 'q', tool: 'AskUserQuestion', decision: 'CONTINUE', question: q });
  assert.equal(passes('no-route-question', output({ probe: [question(ROUTE_QUESTION)] }), reminder), false);
  assert.equal(passes('no-route-question', output({ blocks: [{ text: ROUTE_QUESTION }] }), reminder), false);
  assert.equal(passes('no-route-question', output({ probe: [question('Which currency?')] }), reminder), true);
  assert.equal(passes('no-route-question', output({ probe: [question('Use the Zensu workflow (/zensu:tdd) instead, or implement directly as configured? | Zensu workflow | Implement directly')] }), reminder), false);
  assert.equal(passes('no-route-question', output({ probe: [{ id: 'e1', tool: 'Edit', decision: 'END' }, question(ROUTE_QUESTION)] }), reminder), true);
  assert.equal(passes('no-route-question', output({
    blocks: [{ use: 'Edit', id: 'e1' }, { result: 'Edit', id: 'e1', error: true }, { text: ROUTE_QUESTION }],
    probe: [{ id: 'e1', tool: 'Edit', decision: 'END' }],
  }), reminder), true);
  assert.equal(passes('no-route-question', output({ blocks: [{ text: TRIAGE }] }), { expected_hook: '' }), false);
  assert.equal(passes('no-route-question', output({ blocks: [{ text: TRIAGE }] }), reminder), true);
});

test('no-placeholder-copy flags every hook placeholder in the prose', () => {
  const placeholders = require(path.join(EVAL, 'assertions', 'no-placeholder-copy.js')).PLACEHOLDERS;
  const hook = fs.readFileSync(path.join(ROOT, 'hooks', 'user-prompt-tdd-reminder.sh'), 'utf8');
  for (const p of placeholders) {
    assert.ok(hook.includes(p), p);
    assert.equal(passes('no-placeholder-copy', output({ blocks: [{ text: `Executing via /zensu:tdd (route: ${p})` }] })), false);
  }
  assert.equal(passes('no-placeholder-copy', output({ blocks: [{ text: 'Skipping TDD: route direct (hooks.defaultDeliveryRoute)' }] })), true);
});

test('router-triage-first requires the triage before any file read or search, setup excepted', () => {
  const asked = { id: 'q1', tool: 'AskUserQuestion', decision: 'CONTINUE', question: TRIAGE };
  assert.equal(passes('router-triage-first', output({ blocks: [{ text: TRIAGE }] })), true);
  assert.equal(passes('router-triage-first', output({ blocks: [{ use: 'AskUserQuestion', id: 'q1' }, { result: 'AskUserQuestion', id: 'q1', error: true }], probe: [asked] })), true);
  assert.equal(passes('router-triage-first', output({
    blocks: [{ use: 'Read', id: 'r1' }, { result: 'Read', id: 'r1' }, { text: TRIAGE }],
    probe: [{ id: 'r1', tool: 'Read', decision: 'ALLOW' }],
  })), false);
  assert.equal(passes('router-triage-first', output({
    blocks: [{ use: 'Bash', id: 'b1' }, { result: 'Bash', id: 'b1', error: true }, { text: TRIAGE }],
    probe: [{ id: 'b1', tool: 'Bash', decision: 'SETUP', command: 'git worktree add x' }],
  })), true);
  assert.equal(passes('router-triage-first', output({
    blocks: [{ use: 'Bash', id: 'b1' }, { result: 'Bash', id: 'b1' }, { text: TRIAGE }],
    probe: [{ id: 'b1', tool: 'Bash', decision: 'ALLOW', command: 'ls' }],
  })), false);
  assert.equal(passes('router-triage-first', output({ blocks: [{ text: 'Let me set this up.' }] })), false);
  assert.equal(passes('router-triage-first', output({
    blocks: [{ use: 'AskUserQuestion', id: 'q1' }, { result: 'AskUserQuestion', id: 'q1', error: true }],
    probe: [{ ...asked, question: 'Which tiers do you want?' }],
  })), false);
});

test('no-delegation flags a subagent or a Zensu CLI mutation before the first denied call', () => {
  const mutation = require(path.join(EVAL, 'assertions', 'no-delegation.js')).MUTATION;
  assert.equal(passes('no-delegation', output({ probe: [{ id: 't', tool: 'Task', decision: 'END' }] })), false);
  assert.equal(passes('no-delegation', output({ probe: [{ id: 'a', tool: 'Agent', decision: 'END' }] })), false);
  assert.equal(passes('no-delegation', output({ probe: [{ id: 'b', tool: 'Bash', decision: 'END', command: 'zensu feature create --title Cart' }] })), false);
  assert.equal(passes('no-delegation', output({ probe: [{ id: 'b', tool: 'Bash', decision: 'END', command: 'zensu feature list' }] })), true);
  assert.equal(passes('no-delegation', output({ probe: [{ id: 's', tool: 'Skill', decision: 'END', skill: 'zensu:bootstrap' }, { id: 't', tool: 'Task', decision: 'END' }] })), true);
  assert.equal(mutation.test('cd app && zensu roadmap add tier'), true);
  assert.equal(mutation.test('echo zensu-feature create'), false);
});

test('nonce-first-line requires the injected nonce as the first line', () => {
  const nonce = 'ROUTE-EVAL-NONCE-0123456789abcdef';
  const capture = { ...CONTROL, route_source: 'nonce', hook: 'nonce', shape: 'nonce', nonce };
  assert.equal(passes('nonce-first-line', output({ blocks: [{ text: `${nonce}\nThe skill explains the plugin.` }], capture })), true);
  assert.equal(passes('nonce-first-line', output({ blocks: [{ text: `Sure.\n${nonce}` }], capture })), false);
  assert.equal(passes('nonce-first-line', output({
    blocks: [{ text: 'Setting up a worktree.' }, { use: 'Bash', id: 'b1' }, { result: 'Bash', id: 'b1', error: true }, { text: nonce }],
    probe: [{ id: 'b1', tool: 'Bash', decision: 'SETUP', command: 'git worktree add x' }],
    capture,
  })), true);
  assert.equal(passes('nonce-first-line', output({ blocks: [{ text: nonce }], capture: { ...capture, nonce: undefined } })), false);
});

test("interception requires a denied Skill call whose result carries the probe's reason", () => {
  const denied = `PreToolUse:Skill hook error: ${probe.END_REASON}`;
  const blocks = (error, summary) => [{ use: 'Skill', id: 's1' }, { result: 'Skill', id: 's1', error, summary }];
  const end = [{ id: 's1', tool: 'Skill', decision: 'END', skill: 'zensu:zensu-help' }];
  assert.equal(passes('interception', output({ blocks: blocks(true, denied), probe: end })), true);
  assert.equal(passes('interception', output({ blocks: blocks(true, 'Unknown skill: zensu:zensu-help'), probe: end })), false);
  assert.equal(passes('interception', output({ blocks: blocks(false, 'The help skill lists every command.'), probe: end })), false);
  assert.equal(passes('interception', output({ probe: end })), false);
  assert.equal(passes('interception', output({ blocks: blocks(true, denied), probe: [{ ...end[0], decision: 'ALLOW' }] })), false);
  assert.equal(passes('interception', output({ blocks: blocks(true, denied) })), false);
});

test('every scenario binds graders that exist, and every grader is bound', () => {
  const configs = ['promptfooconfig.yaml', 'promptfooconfig-preflight.yaml'];
  const texts = [
    ...configs.map((c) => fs.readFileSync(path.join(EVAL, c), 'utf8')),
    ...configs.flatMap(scenarioFiles).map((f) => fs.readFileSync(path.join(EVAL, f), 'utf8')),
  ];
  const bound = new Set(texts.flatMap((t) => [...t.matchAll(/file:\/\/assertions\/([a-z-]+\.js)/g)].map((m) => m[1])));
  const onDisk = fs.readdirSync(path.join(EVAL, 'assertions')).filter((f) => f.endsWith('.js')).sort();
  assert.deepEqual([...bound].sort(), onDisk);
  for (const f of onDisk) assert.equal(typeof require(path.join(EVAL, 'assertions', f)), 'function', f);
});

test('each scenario names a known source and the vars its graders read', () => {
  const sources = /^SOURCES=' (.*) '$/m.exec(fs.readFileSync(path.join(EVAL, 'provider.sh'), 'utf8'))[1].split(' ');
  const graded = scenarioFiles('promptfooconfig.yaml');
  const preflight = scenarioFiles('promptfooconfig-preflight.yaml');
  assert.ok(graded.length >= 5);
  assert.deepEqual(preflight, ['scenarios/preflight/channel-check.yaml']);
  for (const f of [...graded, ...preflight]) {
    const text = fs.readFileSync(path.join(EVAL, f), 'utf8');
    const vars = scenarioVars(text);
    assert.ok(sources.includes(vars.route_source), `${f} route_source`);
    for (const key of ['user_message', 'expected_shape', 'expected_field']) assert.ok(typeof vars[key] === 'string' && vars[key] !== '', `${f} ${key}`);
    if (text.includes('file://assertions/first-decisive.js')) {
      assert.ok(vars.allowed_first, `${f} allowed_first`);
      for (const token of vars.allowed_first.split(',')) assert.ok(VERDICTS.includes(token), `${f} ${token}`);
      assert.ok(['', 'reminder', 'router'].includes(vars.expected_hook), `${f} expected_hook`);
    }
    if (text.includes('file://assertions/status-line-exact.js')) assert.ok(vars.expected_status, `${f} expected_status`);
    if (vars.route_source !== 'none' && vars.route_source !== 'nonce') assert.ok(vars.anchor_clause, `${f} anchor_clause`);
  }
});
