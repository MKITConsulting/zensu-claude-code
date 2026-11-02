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
const VERDICTS = ['skill:zensu:build', 'ask', 'edit', 'edit-outside', 'other:Bash', 'none', 'delegate', 'plan'];

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
    blocks: [{ text }, { use: 'Skill', id: 's1', input: { skill: 'zensu:build' } }, { result: 'Skill', id: 's1', error: true }, { text: 'I would run the Zensu workflow next.' }],
    probe: [{ id: 's1', tool: 'Skill', decision: 'END', skill: 'zensu:build' }],
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
  assert.equal(envelope.covers('Three questions first: 1. Is there working code in this repo yet? 2. Do you have a plan or spec document? 3. Does it list features that remain to be built?', 'router'), true);
  assert.equal(envelope.covers('Has it been built? Is there a spec? What still needs to be implemented?', 'router'), true);
  assert.equal(envelope.offersRoute('Run this through /zensu:build, or go with a direct implementation?'), true);
  assert.equal(envelope.offersRoute('Use TDD, or should I edit the file directly?'), true);
  assert.equal(envelope.offersRoute('Use TDD, or should I edit the file?'), false);
  assert.equal(envelope.proseAsk(TRIAGE, 'router'), true);
  assert.equal(envelope.proseAsk("I'll treat the cart app as existing code with no separate plan or spec, so nothing is unbuilt. Shall I start with the ghost scan?", 'router'), false);
  assert.deepEqual(envelope.LOOK_TOOLS, ['Read', 'Glob', 'Grep', 'LS', 'LSP', 'Bash', 'WebSearch', 'WebFetch']);
  const asked = [
    'Before I set up the roadmap, please answer these three:\n1. Code status — already built, or starting from scratch\n2. Plan or spec — whether a document exists\n3. Unbuilt items — which planned features are not yet built',
    'Is the code already built (i.e. is there a working app here)? Is there a plan or spec? Which of its items are not built yet?',
    'Quick check — is the code already built, is there a plan or spec, and does it hold unbuilt items?',
    '1) Is the code already built — or not yet?\n2) Is there a plan or spec?\n3) Which items are not built yet?',
    '1. Is the code already built — or are you starting fresh?\n2. Is there a plan or spec?\n3. Which items are not built yet?',
  ];
  for (const text of asked) assert.equal(envelope.proseAsk(text, 'router'), true, text);
  const guessed = [
    "I'll assume the following:\n- The code is already built\n- There is no separate plan\n- Nothing is unbuilt",
    'Since this is existing code with no plan or spec, nothing is unbuilt — shall I draft the roadmap from the code?',
    'Here is my read:\n1. The code is already built\n2. There is no plan or spec\n3. Nothing is unbuilt\nShall I continue?',
  ];
  for (const text of guessed) assert.equal(envelope.proseAsk(text, 'router'), false, text);
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
  assert.equal(envelope.classifyQuestion('Use the Zensu workflow (/zensu:build) instead, or implement directly as configured? | Zensu workflow | Implement directly'), 'route');
  assert.equal(envelope.classifyQuestion('Should I skip TDD for this one?'), 'route');
  assert.equal(envelope.offersRoute('Add tests for the discount?'), false);
  assert.equal(envelope.proseAsk('Should I run this through the Zensu workflow, or implement it directly?', 'reminder'), true);
  assert.equal(envelope.proseAsk('Skipping /zensu:build: route direct (hooks.defaultDeliveryRoute).\nShould I also add tests?', 'reminder'), false);
  assert.equal(envelope.proseAsk('I will implement it directly without the Zensu workflow.', 'reminder'), false);
});

test('the decisive action skips allowed calls, setup calls and clarifying questions', () => {
  const base = [
    { id: 'a', tool: 'Read', decision: 'ALLOW' },
    { id: 'b', tool: 'Bash', decision: 'SETUP', command: 'git worktree add x' },
    { id: 'c', tool: 'AskUserQuestion', decision: 'CONTINUE', question: 'Which currency?' },
  ];
  const cases = [
    [{ tool: 'Skill', decision: 'END', skill: 'zensu:build' }, 'skill:zensu:build'],
    [{ tool: 'AskUserQuestion', decision: 'CONTINUE', question: ROUTE_QUESTION }, 'ask'],
    [{ tool: 'AskUserQuestion', decision: 'CONTINUE', question: TRIAGE }, 'ask'],
    [{ tool: 'Edit', decision: 'END' }, 'edit'],
    [{ tool: 'Write', decision: 'END' }, 'edit'],
    [{ tool: 'Task', decision: 'END' }, 'delegate'],
    [{ tool: 'Agent', decision: 'END' }, 'delegate'],
    [{ tool: 'EnterPlanMode', decision: 'END' }, 'plan'],
    [{ tool: 'Bash', decision: 'END', command: 'npm test' }, 'other:Bash'],
    [{ tool: 'Bash', decision: 'RETRY', command: 'sort x' }, 'none'],
  ];
  for (const [last, want] of cases) assert.equal(envelope.decisive([...base, { id: 'd', ...last }]), want, want);
  assert.equal(envelope.decisive(base), 'none');
  const at = envelope.decisiveAt([{ tool: 'AskUserQuestion', decision: 'CONTINUE', question: ROUTE_QUESTION }, { tool: 'Edit', decision: 'END' }], 1);
  assert.deepEqual([at.value, at.index], ['edit', 1]);
  const retried = [{ tool: 'Bash', decision: 'RETRY', command: 'sort x' }, { tool: 'Read', decision: 'ALLOW' }, { tool: 'Bash', decision: 'RETRY', command: 'jq . y' }, { tool: 'Edit', decision: 'END' }];
  assert.deepEqual([envelope.decisiveAt(retried, 0).value, envelope.decisiveAt(retried, 0).index], ['edit', 3]);
  assert.deepEqual(envelope.retriedBefore(retried, 3).map((r) => r.command), ['sort x', 'jq . y']);
  assert.deepEqual(envelope.retriedBefore(retried.slice(0, 3), -1).map((r) => r.command), ['sort x', 'jq . y']);
});

test('an edit counts as edit only inside the attested fixture', () => {
  const root = '/private/tmp/claude-eval-AB12';
  const inside = ['/private/tmp/claude-eval-AB12/src/cart.js', '/tmp/claude-eval-AB12/src/cart.js', 'src/cart.js', './src/cart.js'];
  const outside = ['/private/tmp/zensu-rt.x/scratchpad/check.js', '/private/tmp/claude-eval-AB12x/a.js', '../a.js', '~/a.js', '/private/tmp/claude-eval-AB12/../other/a.js'];
  for (const file of inside) assert.equal(envelope.decisive([{ tool: 'Write', decision: 'END', path: file }], root), 'edit', file);
  for (const file of outside) assert.equal(envelope.decisive([{ tool: 'Write', decision: 'END', path: file }], root), 'edit-outside', file);
  assert.equal(envelope.decisive([{ tool: 'Edit', decision: 'END', path: '/anywhere/a.js' }]), 'edit');
  assert.equal(envelope.decisive([{ tool: 'Edit', decision: 'END' }], root), 'edit');
});


test('firstEnd keeps only what came before the result of the first denied call', () => {
  const e = envelope.parse(output({
    blocks: [{ text: 'Before.' }, { use: 'Skill', id: 's1' }, { result: 'Skill', id: 's1', error: true }, { text: 'After the deny.' }, { use: 'Edit', id: 'e1' }],
    probe: [{ id: 's1', tool: 'Skill', decision: 'END', skill: 'zensu:build' }, { id: 'e1', tool: 'Edit', decision: 'END' }],
  }));
  const cut = envelope.firstEnd(e);
  assert.equal(cut.prose, 'Before.');
  assert.deepEqual(cut.probe.map((r) => r.id), ['s1']);
  assert.equal(envelope.firstEnd({ ...e, probe: [{ id: '', tool: 'Edit', decision: 'END' }] }).prose, 'Before.\nAfter the deny.');
  const positional = envelope.firstEnd({ ...e, probe: [{ id: '', tool: 'Skill', decision: 'END', skill: 'zensu:build' }] });
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
    blocks: [...setup, { text: 'Executing via /zensu:build (vanilla mode, route: x)' }, { use: 'Skill', id: 's1' }],
    probe: [{ id: 'b1', tool: 'Bash', decision: 'SETUP', command: 'git worktree add x' }, { id: 's1', tool: 'Skill', decision: 'END' }],
  }));
  assert.deepEqual(envelope.openingLines(e), ['Creating a worktree first.', 'Executing via /zensu:build (vanilla mode, route: x)']);
  const read = envelope.parse(output({
    blocks: [{ text: 'Let me look first.' }, { use: 'Read', id: 'r1' }, { result: 'Read', id: 'r1' }, { text: 'Executing.' }],
    probe: [{ id: 'r1', tool: 'Read', decision: 'ALLOW' }],
  }));
  assert.deepEqual(envelope.openingLines(read), ['Let me look first.']);
  assert.deepEqual(envelope.openingLines(envelope.parse(output({}))), []);
});

test('firstLine reads the first line without markdown emphasis or quoting', () => {
  assert.equal(envelope.firstLine('**Executing via /zensu:build (vanilla mode, route: hooks.defaultDeliveryRoute)**\nThen more.'), 'Executing via /zensu:build (vanilla mode, route: hooks.defaultDeliveryRoute)');
  assert.equal(envelope.firstLine('\n> `Skipping /zensu:build: route direct (hooks.defaultDeliveryRoute)`'), 'Skipping /zensu:build: route direct (hooks.defaultDeliveryRoute)');
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
    ['Bash', { command: 'cat $(echo src/cart.js)' }, 'RETRY'],
    ['Bash', { command: 'lsof -i' }, 'RETRY'],
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
    ['Bash', { command: 'npm test -- --watch' }, 'RETRY'],
    ['Bash', { command: 'rg -n x --pre cat' }, 'END'],
    ['Bash', { command: 'echo hi' }, 'ALLOW'],
    ['Bash', { command: 'touch src/new.js' }, 'END'],
    ['Bash', { command: 'echo hi > out.txt' }, 'END'],
    ['Bash', { command: 'git ls-files && echo "---" && cat -n src/cart.js && echo "---" && cat package.json 2>/dev/null' }, 'ALLOW'],
    ['Bash', { command: 'git status --short && (cat package.json 2>/dev/null || echo "(no package.json)")' }, 'ALLOW'],
    ['Bash', { command: 'grep -nE "cartTotal|shipping" src/cart.js' }, 'ALLOW'],
    ['Bash', { command: "grep -n 'a;b' src/cart.js" }, 'ALLOW'],
    ['Bash', { command: 'grep -n "cartTotal\\|shipping" src/cart.js' }, 'ALLOW'],
    ['Bash', { command: "printf '%s\\n' done" }, 'ALLOW'],
    ['Bash', { command: 'nl -ba src/cart.js' }, 'ALLOW'],
    ['Bash', { command: "sed -n '1,40p' src/cart.js" }, 'ALLOW'],
    ['Bash', { command: 'sed -i -n 1p src/cart.js' }, 'END'],
    ['Bash', { command: 'sed -n 1p -i src/cart.js' }, 'END'],
    ['Bash', { command: "sed -n '1w copy.js' src/cart.js" }, 'END'],
    ['Bash', { command: "echo '$(rm -rf src)'" }, 'ALLOW'],
    ['Bash', { command: 'echo "$(rm -rf src)"' }, 'END'],
    ['Bash', { command: 'echo "\\$(rm -rf src)"' }, 'ALLOW'],
    ['Bash', { command: 'echo "a \\"quoted\\" word" && ls' }, 'ALLOW'],
    ['Bash', { command: 'echo "`rm -rf src`"' }, 'END'],
    ['Bash', { command: "echo $'\\x41'" }, 'END'],
    ['Bash', { command: 'cat "src/cart.js' }, 'RETRY'],
    ['Bash', { command: "find . -ex''ec rm {} +" }, 'END'],
    ['Bash', { command: 'git diff --out"put"=patch.txt' }, 'END'],
    ['Bash', { command: '(rm -rf src)' }, 'END'],
    ['Bash', { command: 'ls & rm -rf src' }, 'END'],
    ['Bash', { command: 'cat src/cart.js |& tee copy.js' }, 'END'],
    ['Bash', { command: '' }, 'END'],
    ['Bash', { command: '()' }, 'END'],
    ['Bash', { command: 'git worktree list && git branch -a && ls -la' }, 'SETUP'],
    ['Bash', { command: 'git branch --show-current' }, 'SETUP'],
    ['Bash', { command: 'git -C . worktree list --porcelain' }, 'SETUP'],
    ['Bash', { command: 'git --no-pager branch -av' }, 'SETUP'],
    ['Bash', { command: 'git branch -av' }, 'SETUP'],
    ['Bash', { command: 'ls -la .claude/worktrees 2>/dev/null || true' }, 'ALLOW'],
    ['Bash', { command: 'cat package.json 2>/dev/null || true' }, 'ALLOW'],
    ['Bash', { command: '[ -f package.json ] && cat package.json' }, 'ALLOW'],
    ['Bash', { command: 'test -d test && ls test' }, 'ALLOW'],
    ['Bash', { command: 'git worktree add x -b y 2>/dev/null || true' }, 'SETUP'],
    ['Bash', { command: 'true && rm -rf src' }, 'END'],
    ['Bash', { command: "test -v 'a[$(rm -rf src)]'" }, 'END'],
    ['Bash', { command: '[ -v x ]' }, 'END'],
    ['Bash', { command: "printf -v 'a[$(rm -rf src)]' x" }, 'END'],
    ['Bash', { command: 'test -R x' }, 'END'],
    ['Bash', { command: 'git status --short && git remote -v' }, 'ALLOW'],
    ['Bash', { command: 'git remote' }, 'ALLOW'],
    ['Bash', { command: 'git remote add o x' }, 'END'],
    ['Bash', { command: 'git remote -v update' }, 'END'],
    ['Bash', { command: 'git remote show origin' }, 'END'],
    ['Bash', { command: 'find . \\( -name a -o -name b \\)' }, 'ALLOW'],
    ['Bash', { command: 'find . -exec rm {} \\;' }, 'END'],
    ['Bash', { command: 'find . \\-exec rm {} +' }, 'END'],
    ['Bash', { command: 'ls \\' }, 'RETRY'],
    ['Bash', { command: 'ec\\ho hi' }, 'ALLOW'],
    ['Bash', { command: "grep -n 'cartTotal\nshipping' src/cart.js" }, 'RETRY'],
    ['Bash', { command: 'echo "a\nb"' }, 'RETRY'],
    ['Bash', { command: 'echo "a\\\nb"' }, 'RETRY'],
    ['Bash', { command: "cat src/cart.js # let's read it\nrm -rf src" }, 'END'],
    ['Bash', { command: 'git branch feature' }, 'SETUP'],
    ['Bash', { command: 'git branch -D main' }, 'SETUP'],
    ['Bash', { command: 'git worktree list && git worktree add x -b y' }, 'SETUP'],
    ['Bash', { command: 'git worktree add x -b y && cd x' }, 'SETUP'],
    ['Bash', { command: 'git -C . worktree add x' }, 'SETUP'],
    ['Bash', { command: 'git -C . status' }, 'ALLOW'],
    ['Bash', { command: 'git status\ngit checkout -b feat' }, 'END'],
    ['Bash', { command: 'pwd\nnode --test src/' }, 'RETRY'],
    ['Bash', { command: 'cat\nrm -rf ~/x' }, 'END'],
    ['Bash', { command: 'ls src 2>/dev/null' }, 'ALLOW'],
    ['Bash', { command: 'node --test src/ 2>&1 | tail -5' }, 'ALLOW'],
    ['Bash', { command: 'cat src/cart.js | head -40' }, 'ALLOW'],
    ['Bash', { command: 'ls 2>/dev/nullx' }, 'END'],
    ['Bash', { command: 'tail -f log' }, 'RETRY'],
    ['Bash', { command: 'tail --follow=name log' }, 'RETRY'],
    ['Bash', { command: 'git check-ignore -v .zensu .verify-runtime 2>/dev/null' }, 'ALLOW'],
    ['Bash', { command: 'git check-ignore --stdin' }, 'RETRY'],
    ['Bash', { command: 'cat package.json && node --version' }, 'ALLOW'],
    ['Bash', { command: 'node -v' }, 'ALLOW'],
    ['Bash', { command: 'npm --version' }, 'RETRY'],
    ['Bash', { command: 'npm version patch' }, 'END'],
    ['Bash', { command: 'node -e "console.log(1)"' }, 'END'],
    ['Bash', { command: 'node scripts/check.js' }, 'END'],
    ['Bash', { command: 'cat package.json | sort' }, 'RETRY'],
    ['Bash', { command: 'sort -o out.txt package.json' }, 'END'],
    ['Bash', { command: 'jq .scripts package.json' }, 'RETRY'],
    ['Bash', { command: 'which node && command -v npm' }, 'RETRY'],
    ['Bash', { command: 'command rm -rf src' }, 'END'],
    ['Bash', { command: 'env' }, 'RETRY'],
    ['Bash', { command: 'env X=1 ls' }, 'END'],
    ['Bash', { command: 'LC_ALL=C grep -n cartTotal src/cart.js' }, 'END'],
    ['Bash', { command: 'for f in src/*.js; do wc -l "$f"; done' }, 'RETRY'],
    ['Bash', { command: 'for f in $(rm -rf src); do cat "$f"; done' }, 'END'],
    ['Bash', { command: 'cat <<EOF\nx\nEOF' }, 'END'],
    ['Bash', { command: 'echo x | python3' }, 'END'],
    ['Bash', { command: './scripts/setup.sh' }, 'END'],
    ['Bash', { command: '/bin/cat src/cart.js' }, 'RETRY'],
    ['Bash', { command: 'zensu feature list' }, 'RETRY'],
    ['Bash', { command: 'zensu feature create --title Cart' }, 'END'],
    ['Bash', { command: 'git stash' }, 'END'],
    ['Bash', { command: 'git blame src/cart.js' }, 'RETRY'],
    ['Bash', { command: 'git worktree list\ngit status' }, 'END'],
    ['Bash', { command: 'sleep 5' }, 'RETRY'],
    ['Bash', { command: 'cat src/cart.js &' }, 'END'],
    ['Bash', { command: 'cat src/cart.js > /dev/null' }, 'ALLOW'],
    ['Bash', { command: 'printf "%s" "$HOME"' }, 'RETRY'],
    ['Bash', { command: 'echo "a -> b" | cat' }, 'ALLOW'],
    ['Bash', { command: 'grep -n x src/cart.js | awk "{print $1}"' }, 'END'],
    ['Bash', { command: 'diff <(cat a) <(cat b)' }, 'RETRY'],
    ['Bash', { command: 'tee >(cat) < src/cart.js' }, 'END'],
    ['Bash', { command: 'cat src/cart.js 2>&1 | head' }, 'ALLOW'],
    ['Bash', { command: 'ls &>out.txt' }, 'END'],
    ['Bash', { command: 'bash /p/hooks/lib/zensu-delivery-route.sh --build' }, 'END'],
    ['Bash', { command: 'echo --tdd-begin | head' }, 'ALLOW'],
    ['Bash', { command: 'jq . x --tdd-begin' }, 'END'],
    ['Bash', { command: '# just a note' }, 'END'],
    ['WebSearch', {}, 'ALLOW'],
    ['LSP', {}, 'ALLOW'],
    ['mcp__server__tool', {}, 'END'],
    ['Bash', {}, 'END'],
    ['EnterWorktree', {}, 'SETUP'],
    ['AskUserQuestion', {}, 'CONTINUE'],
    ['Skill', { skill: 'zensu:build' }, 'END'],
    ['Edit', {}, 'END'],
    ['Write', {}, 'END'],
    ['Task', {}, 'END'],
    ['EnterPlanMode', {}, 'END'],
    ['', {}, 'END'],
  ];
  for (const [tool, input, want] of cases) assert.equal(probe.decide(tool, input), want, `${tool} ${JSON.stringify(input)}`);
  assert.deepEqual(['ALLOW', 'CONTINUE', 'SETUP', 'RETRY', 'END'].map(probe.reasonFor), [probe.END_REASON, probe.CONTINUE_REASON, probe.SETUP_REASON, probe.RETRY_REASON, probe.END_REASON]);
  assert.doesNotMatch(probe.CONTINUE_REASON, /continue/i);
  assert.doesNotMatch(probe.RETRY_REASON, /end your turn/i);
  assert.deepEqual(probe.record('Skill', { skill: 'zensu:build', args: 'Add discountPercent' }, 's1', 'END'), { id: 's1', tool: 'Skill', decision: 'END', skill: 'zensu:build', args: 'Add discountPercent' });
  assert.deepEqual(probe.record('Skill', { skill: 'zensu:build' }, 's1', 'END'), { id: 's1', tool: 'Skill', decision: 'END', skill: 'zensu:build' });
  assert.equal(probe.record('Skill', { skill: 'x', args: 'a'.repeat(500) }, 's1', 'END').args.length, 500);
  assert.equal(probe.record('Skill', { skill: 'x', args: 'a'.repeat(5000) }, 's1', 'END').args.length, 4001);
  assert.equal(probe.record('Bash', { command: 'ls', args: 'x' }, 'b1', 'ALLOW').args, undefined);
});

test('the probe reads a Bash command it cannot prove for signals, and names the code and the part that decided it', () => {
  const observed = [
    ['for f in package.json src/cart.js src/cart.test.js; do echo "===== $f ====="; cat -n "$f"; done; echo "===== .zensu tree ====="; find .zensu -maxdepth 3 | head -50', 'RETRY', 'expansion'],
    ['cat package.json && echo "---" && cat src/cart.test.js && echo "---" && find .zensu .verify-feature-runtime .verify-runtime -maxdepth 3 2>/dev/null | head -50 && echo "---" && cat .gitignore 2>/dev/null; git check-ignore -v .zensu .verify-runtime .verify-feature-runtime 2>/dev/null; git status --short --ignored', 'ALLOW', 'read'],
    ['echo "--- package.json:" && cat -n package.json && echo "--- .zensu tree:" && find .zensu -maxdepth 3 -not -name \'hook-events.log\' | head -50 && echo "--- node/npm:" && node --version && npm --version && ls node_modules 2>/dev/null | head', 'RETRY', 'unlisted'],
    ["mkdir -p /tmp/run/scratchpad && cat > /tmp/run/scratchpad/formula-check.js <<'EOF'\n'use strict';\nconst A = (s, p) => s * (1 - p / 100);\nEOF\nnode /tmp/run/scratchpad/formula-check.js", 'END', 'program:mkdir'],
    ['cat package.json && echo "---" && cat src/cart.test.js && echo "---" && node --version', 'ALLOW', 'read'],
  ];
  for (const [command, decision, code] of observed) {
    const verdict = probe.bashVerdict(command);
    assert.deepEqual([verdict.decision, verdict.code], [decision, code], command);
  }
  assert.equal(probe.bashVerdict('npm --version').part, 'npm --version');
  assert.deepEqual(probe.bashVerdict('cat src/cart.js > copy.js'), { decision: 'END', code: 'redirect', part: '> copy.js' });
  assert.deepEqual(probe.bashVerdict('ls && rm -rf src'), { decision: 'END', code: 'program:rm', part: 'rm -rf src' });
  assert.deepEqual(probe.bashVerdict('echo "$(git commit -am x)"'), { decision: 'END', code: 'git:commit', part: 'git commit -am x' });
  assert.equal(probe.bashVerdict('ls `touch x`').code, 'program:touch');
  assert.equal(probe.bashVerdict('git diff --out"put"=patch.txt').code, 'flag:--output');
  assert.equal(probe.bashVerdict("echo $'\\x72\\x6d'").code, 'ansi-c');
  assert.equal(probe.bashVerdict('pwd\nls').code, 'multi-line');
  assert.equal(probe.bashVerdict('cat "src/cart.js').code, 'unparsed');
  assert.deepEqual(probe.bashVerdict('git status && git worktree list'), { decision: 'SETUP', code: 'setup', part: '' });
  assert.deepEqual(probe.bashVerdict(''), { decision: 'END', code: 'empty', part: '' });
  assert.deepEqual(probe.verdictFor('Read', {}), { decision: 'ALLOW' });
  assert.deepEqual(probe.record('Bash', { command: 'sort x' }, 'b1', 'RETRY', probe.bashVerdict('sort x')), { id: 'b1', tool: 'Bash', decision: 'RETRY', command: 'sort x', code: 'unlisted', part: 'sort x' });
  assert.equal(probe.record('Bash', { command: 'x' }, 'b1', 'END', { code: 'unlisted', part: 'p'.repeat(500) }).part.length, 201);
  assert.equal(probe.record('Bash', { command: 'x' }, 'b1', 'END', { code: 'unlisted', part: 'p', cap: true }).cap, true);
  assert.equal(require(path.join(EVAL, 'assertions', 'no-delegation.js')).MUTATION, probe.MUTATION);
});

test('the probe answers the fourth RETRY of a run with a capped END', () => {
  const dir = tempDir('route-eval-retry-');
  try {
    const call = (id, command, env) => spawnSync(process.execPath, [path.join(EVAL, 'lib', 'decision-probe.js')], {
      input: JSON.stringify({ tool_name: 'Bash', tool_use_id: id, tool_input: { command } }), env: { ...process.env, ZENSU_ROUTE_EVAL_DIR: dir, ...env }, encoding: 'utf8',
    });
    const reasons = [['b1', 'sort a'], ['b2', 'cat src/cart.js'], ['b3', 'sort b'], ['b4', 'jq . c'], ['b5', 'sort d']].map(([id, command]) => {
      const r = call(id, command);
      assert.equal(r.status, 0);
      return r.stdout ? JSON.parse(r.stdout).hookSpecificOutput.permissionDecisionReason : 'allowed';
    });
    assert.equal(probe.RETRY_CAP, 3);
    assert.deepEqual(reasons, [probe.RETRY_REASON, 'allowed', probe.RETRY_REASON, probe.RETRY_REASON, probe.END_REASON]);
    const log = fs.readFileSync(path.join(dir, 'hook.log'), 'utf8').trim().split('\n').map((line) => JSON.parse(line.slice('probe '.length)));
    assert.deepEqual(log.map((r) => [r.seq, r.decision, r.code, r.cap === true]), [[1, 'RETRY', 'unlisted', false], [2, 'ALLOW', 'read', false], [3, 'RETRY', 'unlisted', false], [4, 'RETRY', 'unlisted', false], [5, 'END', 'unlisted', true]]);
    const loose = call('b6', 'sort e', { ZENSU_ROUTE_EVAL_DIR: '' });
    assert.equal(JSON.parse(loose.stdout).hookSpecificOutput.permissionDecisionReason, probe.RETRY_REASON);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('the second reading ends every write, run and route command the review tried, and no plain read', () => {
  const writes = [
    "for f in a; do rm -rf \"$f\"; done",
    "zensu feature \"create\" --title X",
    "rg -n x . > out.txt",
    "git -c alias.x=\"!rm -rf src\" x",
    "git log --output=x",
    "git diff --output x",
    "find . -fprint x",
    "npm pkg set name=x",
    "node --eval \"require('fs').writeFileSync('a','b')\"",
    "node -p 1",
    "node --require ./x.js --test",
    "node --test --test-reporter-destination=out.txt",
    "node --test --test-update-snapshots",
    "cat src/cart.js | tee x",
    "echo x >| file",
    "exec 3>file",
    "{ echo x; } > file",
    "f() { rm -rf src; }; f",
    "python3 -c \"open('a','w')\"",
    "perl -pi -e s/a/b/ src/cart.js",
    "ruby -i -pe 1 src/cart.js",
    "cp src/cart.js /tmp/x",
    "install -m 644 a b",
    "dd if=a of=b",
    "truncate -s 0 x",
    "git apply p.diff",
    "git am p.mbox",
    "git restore src/cart.js",
    "git reset --hard",
    "git clean -fd",
    "git rm src/cart.js",
    "git add .",
    "git update-index --assume-unchanged x",
    "git notes add -m x",
    "git tag v1",
    "sed -i.bak s/a/b/ src/cart.js",
    "awk -i inplace 1 src/cart.js",
    "ed -s src/cart.js <<< $'w'",
    "vim -c wq src/cart.js",
    "cat > src/cart.js",
    "tee -a src/cart.js",
    "echo hi | sponge src/cart.js",
    ">src/cart.js",
    ": > src/cart.js",
    "true > src/cart.js",
    "cat x 1>> y",
    "cat x {fd}>y",
    "cat x 2>y",
    "npx prettier --write src/cart.js",
    "npm exec -- prettier --write src",
    "pnpm dlx prettier",
    "yarn add lodash",
    "bun run x",
    "deno run x.ts",
    "make",
    "curl -o x https://example.com",
    "wget https://example.com",
    "tar xzf a.tgz",
    "ln -s a b",
    "chmod +x a",
    "mkdir x",
    "touch x",
    "git commit -m x",
    "git push",
    "git stash push",
    "bash /p/hooks/lib/zensu-log.sh --chain-done",
    "CLAUDE_PLUGIN_DATA=x bash y.sh --build",
    "source ./x.sh",
    ". ./x.sh",
    "eval \"rm -rf src\"",
    "find . -name x | xargs rm",
    "find . -name x | xargs -I{} cp {} /tmp",
    "timeout 5 node x.js",
    "nohup node x.js",
    "sudo ls",
    "osascript -e x",
    "open .",
    "pbcopy < src/cart.js",
    "uniq a b",
    "sort -o a b",
    "split a",
    "git -C /tmp/other commit -m x",
    "git -c core.fsmonitor=x status",
    "corepack enable",
    "alias x=rm; x -rf src",
    "trap 'rm -rf src' EXIT; ls",
    "r\\\nm -rf src",
    "$'\\x72\\x6d' -rf src",
    "rm${IFS}-rf${IFS}src",
    "$(which rm) -rf src",
    "`which rm` -rf src",
    "{rm,-rf,src}",
    "/bin/r? -rf src",
    "~/bin/x",
    "cat src/cart.js | node",
    "npm run build",
    "npm ci",
    "npm i",
    "pnpm install",
    "git config user.name x",
    "git remote set-url origin x",
    "cd /tmp && rm -rf x",
    "bash -c \"ls\"",
    "exec ls",
    "command rm x",
    "builtin cd /tmp",
    "kill 1",
    "node --version > v.txt",
    "docker run x",
    "zensu feature create --title X",
    "echo x | zensu roadmap add tier",
    "printf \"x\" > out",
    "cat <<EOF > src/cart.js\nx\nEOF",
    "grep x src/cart.js && sed -i s/a/b/ src/cart.js",
    "git checkout -b feat && touch x",
    "ls; git commit -am x",
    "diff a b > patch.diff",
    "cat src/cart.js >> out.txt",
    "node -e 1 && ls",
    "jq .x package.json > out.json",
    "wc -l src/*.js > counts.txt",
    "git log --format=%H -1 | xargs git show",
    "env X=1 node x.js",
    "LC_ALL=C sort a",
    "X=1",
    "ls && X=1 git commit -m y",
    "awk '{print > \"f\"}' a",
    "gawk 1 a",
    "perl -ne print a",
    "ruby -e 1",
    "npm config set x y",
    "cat <<< \"$(rm -rf src)\"",
    "[[ -v x ]]",
  ];
  const reads = [
    "git remote -v | sort",
    "ls -la",
    "cat package.json",
    "cat -n src/cart.js",
    "head -40 src/cart.js",
    "sed -n 1,40p src/cart.js",
    "grep -rn cartTotal .",
    "rg cartTotal",
    "find . -name \"*.js\" -not -path \"./node_modules/*\"",
    "git status --short",
    "git log --oneline -5",
    "git diff",
    "git ls-files",
    "git check-ignore -v .zensu",
    "node --version",
    "node -v",
    "npm --version",
    "npm test",
    "node --test",
    "cat package.json | jq .scripts",
    "cat src/cart.js | sort | uniq -c",
    "wc -l src/*.js",
    "tree -L 2",
    "stat src/cart.js",
    "file src/cart.js",
    "ls src | sort",
    "for f in src/*.js; do echo \"== $f\"; cat \"$f\"; done",
    "while read l; do echo \"$l\"; done < src/cart.js",
    "grep -c x src/cart.js || true",
    "[ -f package.json ] && cat package.json",
    "[[ -f package.json ]] && cat package.json",
    "test -d src && ls src",
    "git blame -L 1,10 src/cart.js",
    "git show HEAD:src/cart.js",
    "git log -p -1 -- src/cart.js | head -50",
    "cat src/cart.js src/cart.test.js | wc -l",
    "diff src/cart.js src/cart.test.js",
    "cmp a b",
    "basename src/cart.js",
    "dirname src/cart.js",
    "realpath src/cart.js",
    "which node",
    "command -v node",
    "type node",
    "uname -a",
    "date",
    "pwd && ls",
    "echo \"$PWD\"",
    "printf \"%s\\n\" \"$(pwd)\"",
    "cat package.json | head -20 | tail -5",
    "ls -la .zensu 2>/dev/null || echo none",
    "cat src/cart.js | grep -n \"SHIPPING\"",
    "grep -n \"a > b\" src/cart.js",
    "echo \"--- a -> b ---\"",
    "sort package.json",
    "cut -d: -f1 /etc/passwd | head",
    "tr a-z A-Z < src/cart.js",
    "node --test src/ 2>&1 | tail -20",
    "git rev-parse --show-toplevel",
    "npm ls --depth=0",
    "cat .gitignore; git status --ignored --short",
    "ls -1 src | while read f; do wc -l \"src/$f\"; done",
    "git --no-pager diff --stat",
    "git log --oneline | head",
    "du -sh .",
    "ps aux | head -3",
    "env",
    "hostname",
    "whoami",
    "npm config get registry",
    "pnpm why lodash",
    "uniq -c a",
    "cat <<< \"plain text\"",
  ];
  for (const command of writes) assert.equal(probe.bashDecision(command), 'END', command);
  for (const command of reads) assert.notEqual(probe.bashDecision(command), 'END', command);
  assert.deepEqual(probe.bashVerdict('$(which rm) -rf src'), { decision: 'END', code: 'program:expanded', part: '$(…) -rf src' });
  assert.equal(probe.bashVerdict('cat <<< "$(rm -rf src)"').code, 'program:rm');
  assert.equal(probe.bashVerdict('git -c core.fsmonitor=x status').code, 'git:-c');
  assert.equal(probe.bashVerdict('[[ -f package.json ]] && cat package.json').decision, 'RETRY');
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
      [{ tool_name: 'Skill', tool_use_id: 't2', tool_input: { skill: 'zensu:build' } }, probe.END_REASON],
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
    assert.deepEqual([log[0].path, log[1].skill, log[2].question, log[3].command], ['src/cart.js', 'zensu:build', 'Run it?', 'git worktree add x']);
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
  const planning = { route_source: 'none', router_fires: 'yes' };
  assert.equal(passes('harness-attested', output({ capture: { ...CONTROL, live: { ...LIVE, router_control_chars: 900 } } }), planning), true);
  assert.equal(passes('harness-attested', output({ capture: { ...CONTROL, live: { ...LIVE, router_control_chars: 0 } } }), planning), false);
  assert.equal(passes('harness-attested', output({ capture: CONTROL }), planning), false);
  assert.equal(passes('harness-attested', output({ capture: CONTROL }), { route_source: 'none' }), true);
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
  assert.equal(passes('harness-injection', output({ capture: { ...capture, field: 'build (hooks.defaultDeliveryRoute)' }, inject }), vars), false);
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

test('harness-isolation fails a run in which another hook or the tool itself answered a probed call', () => {
  const gate = 'PreToolUse:Read hook error: [bash "/plugin/hooks/pre-reviewer-capability-gate.sh"]: zensu: reviewer capability gate unavailable';
  const run = (decision, tool, result) => output({
    blocks: [{ use: tool, id: 'c1' }, { result: tool, id: 'c1', ...result }],
    probe: [{ id: 'c1', tool, decision }],
  });
  const own = (decision) => `PreToolUse:Bash hook error: ${probe.reasonFor(decision)}`;
  assert.equal(passes('harness-isolation', run('ALLOW', 'Read', { summary: 'export function cartTotal() {}' })), true);
  assert.equal(passes('harness-isolation', run('ALLOW', 'Read', { error: true, summary: 'File does not exist.' })), true);
  assert.equal(passes('harness-isolation', run('ALLOW', 'Read', { error: true, summary: gate })), false);
  assert.equal(passes('harness-isolation', run('ALLOW', 'Read', { summary: gate })), true);
  for (const decision of ['SETUP', 'CONTINUE', 'RETRY', 'END']) {
    assert.equal(passes('harness-isolation', run(decision, 'Bash', { error: true, summary: own(decision) })), true, decision);
    assert.equal(passes('harness-isolation', run(decision, 'Bash', { error: true, summary: gate })), false, decision);
    assert.equal(passes('harness-isolation', run(decision, 'Bash', { summary: own(decision) })), false, decision);
  }
  assert.equal(passes('harness-isolation', run('SETUP', 'Bash', { error: true, summary: own('END') })), false);
  assert.equal(passes('harness-isolation', run('RETRY', 'Bash', { error: true, summary: own('END') })), false);
  const capped = output({
    blocks: [{ use: 'Bash', id: 'c1' }, { result: 'Bash', id: 'c1', error: true, summary: own('END') }],
    probe: [{ id: 'c1', tool: 'Bash', decision: 'END', command: 'sort z', code: 'unlisted', cap: true }],
  });
  assert.equal(grade('harness-isolation', capped).reason, "the probe answered RETRY 3 times and then ended the run at call #1 (sort z), so the run measures the probe's read list, not the model");
  const reason = grade('harness-isolation', run('ALLOW', 'Read', { error: true, summary: gate })).reason;
  assert.match(reason, /^1 call\(s\) did not get the probe's answer/);
  assert.match(reason, /Read #1 \(ALLOW\): PreToolUse:Read hook error: \[bash/);
  const unpaired = output({ blocks: [{ use: 'Read', id: '' }, { result: 'Read', id: '', error: true, summary: gate }], probe: [{ id: '', tool: 'Read', decision: 'ALLOW' }] });
  assert.equal(passes('harness-isolation', unpaired), true);
});

test('allowed-read requires an allowed Bash read that ran and returned the fixture marker', () => {
  const vars = { read_marker: 'const SHIPPING_FEE = 5;' };
  const run = (decision, result, tool) => output({
    blocks: [{ use: tool || 'Bash', id: 'b1' }, { result: tool || 'Bash', id: 'b1', ...result }],
    probe: [{ id: 'b1', tool: tool || 'Bash', decision, command: 'cat src/cart.js' }],
  });
  const source = "'use strict';\n\nconst SHIPPING_FEE = 5;\nfunction cartTotal(items) {}";
  assert.equal(passes('allowed-read', run('ALLOW', { summary: source }), vars), true);
  assert.equal(passes('allowed-read', run('ALLOW', { error: true, summary: `${source}\nbash: /tmp/claude-1a2b-cwd: Operation not permitted` }), vars), false);
  assert.equal(passes('allowed-read', run('ALLOW', { error: true, summary: 'PreToolUse:Bash hook error: [bash "/plugin/hooks/pre-reviewer-capability-gate.sh"]: zensu: reviewer capability gate unavailable' }), vars), false);
  assert.equal(passes('allowed-read', run('ALLOW', { summary: 'module.exports = {};' }), vars), false);
  assert.equal(passes('allowed-read', run('END', { error: true, summary: source }), vars), false);
  assert.equal(passes('allowed-read', run('SETUP', { summary: source }), vars), false);
  assert.equal(passes('allowed-read', run('ALLOW', { summary: source }, 'Read'), vars), false);
  assert.equal(passes('allowed-read', run('ALLOW', { summary: source }), {}), false);
  assert.equal(passes('allowed-read', output({}), vars), false);
  const two = output({
    blocks: [{ use: 'Bash', id: 'b1' }, { result: 'Bash', id: 'b1', error: true, summary: 'cat: nope: No such file' }, { use: 'Bash', id: 'b2' }, { result: 'Bash', id: 'b2', summary: source }],
    probe: [{ id: 'b1', tool: 'Bash', decision: 'ALLOW' }, { id: 'b2', tool: 'Bash', decision: 'ALLOW' }],
  });
  assert.equal(passes('allowed-read', two, vars), true);
  assert.match(grade('allowed-read', run('ALLOW', { error: true, summary: 'denied here' }), vars).reason, /the first one returned an error: denied here$/);
  assert.equal(grade('allowed-read', output({}), vars).reason, 'the probe allowed no Bash call, so the allowed path never ran');
});

test('first-decisive grades the first decisive action against the scenario allowlist', () => {
  const ask = { allowed_first: 'skill:zensu:build,ask', expected_hook: 'reminder' };
  assert.equal(passes('first-decisive', skillRun('Executing.'), ask), true);
  assert.equal(passes('first-decisive', output({ probe: [{ id: 'e1', tool: 'Edit', decision: 'END' }] }), ask), false);
  assert.equal(passes('first-decisive', output({ blocks: [{ text: ROUTE_QUESTION }] }), ask), true);
  assert.equal(passes('first-decisive', output({ blocks: [{ text: 'Done thinking.' }] }), ask), false);
  const control = { allowed_first: 'edit,none', expected_hook: '' };
  assert.equal(passes('first-decisive', output({ blocks: [{ text: ROUTE_QUESTION }] }), control), true);
  assert.equal(passes('first-decisive', skillRun('Executing.'), control), false);
  assert.equal(passes('first-decisive', skillRun('Executing.'), {}), false);
  const routeAsk = { id: 'q1', tool: 'AskUserQuestion', decision: 'CONTINUE', question: ROUTE_QUESTION };
  const triageAsk = { id: 'q1', tool: 'AskUserQuestion', decision: 'CONTINUE', question: TRIAGE };
  assert.equal(passes('first-decisive', output({ probe: [routeAsk] }), ask), true);
  assert.equal(grade('first-decisive', output({ probe: [triageAsk] }), ask).reason, 'first decisive action ask:triage; allowed skill:zensu:build | ask');
  const router = { allowed_first: 'ask', expected_hook: 'router' };
  assert.equal(passes('first-decisive', output({ probe: [triageAsk] }), router), true);
  assert.equal(passes('first-decisive', output({ probe: [routeAsk] }), router), false);
  assert.equal(grade('first-decisive', output({ probe: [triageAsk] }), control).reason, 'first decisive action ask:triage; allowed edit | none');
  const long = probe.record('Skill', { skill: 'zensu:build', args: `${'Context about cartTotal and SHIPPING_FEE. '.repeat(10)}Add an optional discountPercent parameter` }, 's1', 'END');
  const direct = { allowed_first: 'edit', expected_hook: 'reminder', expected_status: 'Skipping /zensu:build: route direct (hooks.defaultDeliveryRoute)' };
  const capped = output({ blocks: [{ text: 'Skipping /zensu:build: route direct (hooks.defaultDeliveryRoute) — should the discount be capped at 100?' }] });
  assert.equal(grade('first-decisive', capped, direct).reason, 'first decisive action none; allowed edit');
  assert.equal(grade('first-decisive', capped, { ...direct, expected_status: '' }).reason, 'first decisive action ask; allowed edit');
  const tdd = { allowed_first: 'skill:zensu:build', expected_hook: 'reminder', first_args_contains: 'discountPercent' };
  const skill = (args) => output({ probe: [{ id: 's1', tool: 'Skill', decision: 'END', skill: 'zensu:build', ...(args === undefined ? {} : { args }) }] });
  assert.equal(passes('first-decisive', skill('Add an optional discountPercent parameter'), tdd), true);
  assert.equal(grade('first-decisive', skill('Add a parameter'), tdd).reason, 'first decisive action skill:zensu:build without "discountPercent" in its args; allowed skill:zensu:build');
  assert.equal(passes('first-decisive', skill(undefined), tdd), false);
  assert.equal(passes('first-decisive', skill(undefined), { ...tdd, first_args_contains: '' }), true);
  assert.equal(passes('first-decisive', output({ probe: [long] }), tdd), true);
  const touched = output({ probe: [{ id: 'b1', tool: 'Bash', decision: 'END', command: 'touch src/new.js' }] });
  assert.equal(grade('first-decisive', touched, control).reason, 'first decisive action other:Bash (touch src/new.js); allowed edit | none');
  const edited = output({ probe: [{ id: 'e1', tool: 'Edit', decision: 'END', path: 'src/cart.js' }] });
  assert.equal(grade('first-decisive', edited, control).reason, 'first decisive action edit; allowed edit | none');
  const attestation = { ...ATTESTED, root: '/private/tmp/claude-eval-AB12' };
  const scratch = output({ attestation, probe: [{ id: 'w1', tool: 'Write', decision: 'END', path: '/private/tmp/zensu-rt.x/scratchpad/check.js' }] });
  assert.equal(grade('first-decisive', scratch, direct).reason, 'first decisive action edit-outside (/private/tmp/zensu-rt.x/scratchpad/check.js); allowed edit');
  assert.equal(passes('first-decisive', output({ attestation, probe: [{ id: 'e1', tool: 'Edit', decision: 'END', path: '/tmp/claude-eval-AB12/src/cart.js' }] }), direct), true);
  const named = output({ probe: [
    { id: 'b1', tool: 'Bash', decision: 'RETRY', command: 'cat package.json | sort', code: 'unlisted', part: 'sort' },
    { id: 'b2', tool: 'Bash', decision: 'END', command: 'cat package.json && mkdir -p tmp', code: 'program:mkdir', part: 'mkdir -p tmp' },
  ] });
  assert.equal(grade('first-decisive', named, control).reason, 'first decisive action other:Bash (mkdir -p tmp) [program:mkdir]; allowed edit | none; answered RETRY before it: cat package.json | sort');
  const cappedEnd = output({ probe: [{ id: 'b1', tool: 'Bash', decision: 'END', command: 'sort z', code: 'unlisted', part: 'sort z', cap: true }] });
  assert.equal(grade('first-decisive', cappedEnd, control).reason, 'first decisive action other:Bash (sort z) [unlisted, RETRY cap]; allowed edit | none');
  const implementing = { ...direct, allowed_first: 'edit,edit-outside,other:Bash' };
  const check = output({ probe: [{ id: 'b1', tool: 'Bash', decision: 'END', command: 'node -e 1', code: 'program:node', part: 'node -e 1' }] });
  assert.deepEqual([passes('first-decisive', check, implementing), passes('first-decisive', scratch, implementing)], [true, true]);
  assert.deepEqual([passes('first-decisive', skillRun('Executing.'), implementing), passes('first-decisive', output({}), implementing), passes('first-decisive', output({ probe: [{ id: 't1', tool: 'Task', decision: 'END' }] }), implementing)], [false, false, false]);
  const retriedOnly = output({ probe: [{ id: 'b1', tool: 'Bash', decision: 'RETRY', command: 'sort y' }] });
  assert.equal(grade('first-decisive', retriedOnly, control).reason, 'first decisive action none; allowed edit | none; answered RETRY before it: sort y');
});

test('route-neutral fails a route action with nothing injected and reports the edit-first baseline otherwise', () => {
  const run = (records, attestation) => output({ probe: records, ...(attestation ? { attestation } : {}) });
  const routed = [
    [[{ id: 's1', tool: 'Skill', decision: 'END', skill: 'zensu:build' }], 'skill:zensu:build'],
    [[{ id: 's1', tool: 'Skill', decision: 'END', skill: 'zensu:bootstrap' }], 'skill:zensu:bootstrap'],
    [[{ id: 'q1', tool: 'AskUserQuestion', decision: 'CONTINUE', question: ROUTE_QUESTION }], 'ask:route'],
    [[{ id: 'q1', tool: 'AskUserQuestion', decision: 'CONTINUE', question: TRIAGE }], 'ask:triage'],
    [[{ id: 't1', tool: 'Task', decision: 'END' }], 'delegate'],
    [[{ id: 'b1', tool: 'Bash', decision: 'END', command: 'zensu feature create --title Cart' }], 'zensu-mutation'],
  ];
  for (const [records, got] of routed) {
    const verdict = grade('route-neutral', run(records));
    assert.deepEqual([verdict.pass, verdict.reason], [false, `with nothing injected the first decisive action is a route action: ${got}`]);
  }
  const attestation = { ...ATTESTED, root: '/private/tmp/claude-eval-AB12' };
  const neutral = [
    [[{ id: 'e1', tool: 'Edit', decision: 'END', path: '/private/tmp/claude-eval-AB12/src/cart.js' }], 'route-neutral; edit-first baseline yes: first decisive action edit'],
    [[{ id: 'w1', tool: 'Write', decision: 'END', path: '/private/tmp/zensu-rt.x/scratchpad/check.js' }], 'route-neutral; edit-first baseline no: first decisive action edit-outside (/private/tmp/zensu-rt.x/scratchpad/check.js)'],
    [[{ id: 'b1', tool: 'Bash', decision: 'END', command: 'mkdir -p x && cat > x/a.js', part: 'mkdir -p x' }], 'route-neutral; edit-first baseline no: first decisive action other:Bash (mkdir -p x)'],
    [[{ id: 'b1', tool: 'Bash', decision: 'RETRY', command: 'sort x' }], 'route-neutral; edit-first baseline no: first decisive action none'],
    [[{ id: 'q1', tool: 'AskUserQuestion', decision: 'CONTINUE', question: 'Which currency?' }], 'route-neutral; edit-first baseline no: first decisive action none'],
    [[{ id: 's1', tool: 'Skill', decision: 'END', skill: 'frontend-design:frontend-design' }], 'route-neutral; edit-first baseline no: first decisive action skill:frontend-design:frontend-design'],
    [[{ id: 'p1', tool: 'EnterPlanMode', decision: 'END' }], 'route-neutral; edit-first baseline no: first decisive action plan'],
  ];
  for (const [records, reason] of neutral) {
    const verdict = grade('route-neutral', run(records, attestation));
    assert.deepEqual([verdict.pass, verdict.reason], [true, reason]);
  }
});


test('after-ask lets an unanswered route question end the run or start the workflow, never an edit', () => {
  const asked = { id: 'q', tool: 'AskUserQuestion', decision: 'CONTINUE', question: COMPLETE_ROUTE_QUESTION };
  assert.equal(passes('after-ask', output({ probe: [asked] })), true);
  assert.equal(passes('after-ask', output({ probe: [asked, { id: 's', tool: 'Skill', decision: 'END', skill: 'zensu:build' }] })), true);
  assert.equal(passes('after-ask', output({ probe: [asked, { id: 'e', tool: 'Edit', decision: 'END' }] })), false);
  assert.equal(passes('after-ask', output({ probe: [asked, { id: 'b', tool: 'Bash', decision: 'END', command: 'bash zensu-delivery-route.sh --build' }] })), false);
  assert.equal(passes('after-ask', output({ probe: [{ id: 'e', tool: 'Edit', decision: 'END' }] })), true);
  const triage = { id: 'q', tool: 'AskUserQuestion', decision: 'CONTINUE', question: TRIAGE };
  assert.equal(grade('after-ask', output({ probe: [triage, { id: 'e', tool: 'Edit', decision: 'END' }] })).reason, 'no route question was asked through the tool, so nothing follows it to grade');
});

test('no-record-command flags a route record and --tdd-begin, and nothing else', () => {
  const bash = (command) => output({ probe: [{ id: 'b', tool: 'Bash', decision: 'END', command }] });
  assert.equal(passes('no-record-command', bash('CLAUDE_PLUGIN_DATA=/d bash /p/hooks/lib/zensu-delivery-route.sh --build')), false);
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
  const loose = viaTool('Use the Zensu workflow (/zensu:build), or implement directly? | Zensu workflow | Implement directly');
  assert.equal(passes('route-question-complete', loose), false);
  const afterEnd = output({
    blocks: [{ use: 'Skill', id: 's1' }, { result: 'Skill', id: 's1', error: true, summary: `PreToolUse:Skill hook error: ${probe.END_REASON}` }, { text: 'Next I would run /zensu:build here, or should I implement it directly instead?' }],
    probe: [{ id: 's1', tool: 'Skill', decision: 'END', skill: 'zensu:build' }],
  });
  assert.equal(grade('route-question-complete', afterEnd).reason, 'no route question was asked; nothing to check');
  const toolAfterEnd = output({ probe: [{ id: 's1', tool: 'Skill', decision: 'END', skill: 'zensu:build' }, { id: 'q', tool: 'AskUserQuestion', decision: 'CONTINUE', question: ROUTE_QUESTION }] });
  assert.equal(passes('route-question-complete', toolAfterEnd), true);
});

test('status-line-exact requires the expected status as the opening line, setup narration aside', () => {
  const vars = { expected_status: 'Executing via /zensu:build (vanilla mode, route: hooks.defaultDeliveryRoute)' };
  assert.equal(passes('status-line-exact', skillRun('**Executing via /zensu:build (vanilla mode, route: hooks.defaultDeliveryRoute)**\nStarting.'), vars), true);
  const detour = (first, decision) => output({
    blocks: [{ text: first }, { use: 'Bash', id: 'b1' }, { result: 'Bash', id: 'b1', error: decision === 'SETUP' }, { text: 'Executing via /zensu:build (vanilla mode, route: hooks.defaultDeliveryRoute)' }, { use: 'Skill', id: 's1' }],
    probe: [{ id: 'b1', tool: 'Bash', decision, command: 'git worktree add x' }, { id: 's1', tool: 'Skill', decision: 'END' }],
  });
  assert.equal(passes('status-line-exact', detour('Creating a worktree first.', 'SETUP'), vars), true);
  assert.equal(passes('status-line-exact', detour('Checking the tree first.', 'ALLOW'), vars), false);
  assert.equal(passes('status-line-exact', skillRun('Executing via /zensu:build (vanilla mode, route: <the source the field names>)'), vars), false);
  assert.equal(passes('status-line-exact', skillRun('Let me look first.\nExecuting via /zensu:build (vanilla mode, route: hooks.defaultDeliveryRoute)'), vars), false);
  assert.equal(passes('status-line-exact', skillRun('Anything.'), { expected_status: '' }), false);
  const status = 'Executing via /zensu:build (vanilla mode, route: hooks.defaultDeliveryRoute)';
  const late = output({
    blocks: [{ text: 'Creating a worktree first.' }, { use: 'Bash', id: 'b1' }, { result: 'Bash', id: 'b1', error: true }, { use: 'Skill', id: 's1' }, { result: 'Skill', id: 's1', error: true }, { text: `${status}; next I would run it.` }],
    probe: [{ id: 'b1', tool: 'Bash', decision: 'SETUP', command: 'git worktree add x' }, { id: 's1', tool: 'Skill', decision: 'END' }],
  });
  assert.equal(passes('status-line-exact', late, vars), false);
  const toolFirst = output({
    blocks: [{ use: 'Skill', id: 's1' }, { result: 'Skill', id: 's1', error: true }, { text: status }],
    probe: [{ id: 's1', tool: 'Skill', decision: 'END' }],
  });
  assert.equal(passes('status-line-exact', toolFirst, vars), false);
  const setupFirst = output({
    blocks: [{ use: 'Bash', id: 'b1' }, { result: 'Bash', id: 'b1', error: true }, { text: status }, { use: 'Skill', id: 's1' }],
    probe: [{ id: 'b1', tool: 'Bash', decision: 'SETUP', command: 'git worktree add x' }, { id: 's1', tool: 'Skill', decision: 'END' }],
  });
  assert.equal(passes('status-line-exact', setupFirst, vars), true);
  assert.deepEqual(envelope.openingLines(envelope.parse(toolFirst)), [status]);
  assert.equal(grade('status-line-exact', toolFirst, vars).reason, `Skill ran before any text, so the reply did not begin with "${status}"`);
  const acknowledged = (text) => output({
    blocks: [{ use: 'Bash', id: 'b1' }, { result: 'Bash', id: 'b1', error: true }, { text }, { use: 'Skill', id: 's1' }],
    probe: [{ id: 'b1', tool: 'Bash', decision: 'SETUP', command: 'git worktree add x' }, { id: 's1', tool: 'Skill', decision: 'END' }],
  });
  assert.equal(passes('status-line-exact', acknowledged(`Worktrees are not available here, so I will work in the current directory.\n\n${status}`), vars), true);
  assert.equal(passes('status-line-exact', acknowledged(`Worktrees are not available here.\nSo I will work in place.\n${status}`), vars), false);
  assert.deepEqual(envelope.openingLines(envelope.parse(acknowledged(`Noted.\n${status}`))), ['Noted.', status]);
  const readFirst = output({
    blocks: [{ use: 'Read', id: 'r1' }, { result: 'Read', id: 'r1' }, { text: status }, { use: 'Skill', id: 's1' }],
    probe: [{ id: 'r1', tool: 'Read', decision: 'ALLOW' }, { id: 's1', tool: 'Skill', decision: 'END' }],
  });
  assert.equal(grade('status-line-exact', readFirst, vars).reason, `Read ran before any text, so the reply did not begin with "${status}"`);
  assert.equal(grade('status-line-exact', skillRun('Let me look first.'), vars).reason, `the opening line "Let me look first." is not "${status}"`);
});

test('no-route-status flags a route status line anywhere in the prose', () => {
  const route = require(path.join(EVAL, 'assertions', 'no-route-status.js'));
  assert.equal(passes('no-route-status', output({ blocks: [{ text: 'I will add the parameter.' }] })), true);
  for (const prefix of route.PREFIXES) assert.equal(passes('no-route-status', output({ blocks: [{ text: `${prefix} (vanilla mode)` }] })), false);
  assert.equal(passes('no-route-status', output({
    blocks: [{ text: 'Creating a worktree first.' }, { use: 'Bash', id: 'b1' }, { result: 'Bash', id: 'b1', error: true }, { text: 'Executing via /zensu:build (vanilla mode, route: hooks.defaultDeliveryRoute)' }],
    probe: [{ id: 'b1', tool: 'Bash', decision: 'SETUP', command: 'git worktree add x' }],
  })), false);
  assert.equal(passes('no-route-status', output({ blocks: [{ text: 'I will add the parameter.\n**Skipping /zensu:build: route direct**' }] })), false);
  assert.equal(passes('no-route-status', output({ blocks: [{ text: 'I am not Skipping /zensu:build here.' }] })), true);
});

test('no-route-question flags a route or triage question before the first denied call', () => {
  const reminder = { expected_hook: 'reminder' };
  const question = (q) => ({ id: 'q', tool: 'AskUserQuestion', decision: 'CONTINUE', question: q });
  assert.equal(passes('no-route-question', output({ probe: [question(ROUTE_QUESTION)] }), reminder), false);
  assert.equal(passes('no-route-question', output({ blocks: [{ text: ROUTE_QUESTION }] }), reminder), false);
  assert.equal(passes('no-route-question', output({ probe: [question('Which currency?')] }), reminder), true);
  assert.equal(passes('no-route-question', output({ probe: [question('Use the Zensu workflow (/zensu:build) instead, or implement directly as configured? | Zensu workflow | Implement directly')] }), reminder), false);
  assert.equal(passes('no-route-question', output({ probe: [{ id: 'e1', tool: 'Edit', decision: 'END' }, question(ROUTE_QUESTION)] }), reminder), true);
  assert.equal(passes('no-route-question', output({
    blocks: [{ use: 'Edit', id: 'e1' }, { result: 'Edit', id: 'e1', error: true }, { text: ROUTE_QUESTION }],
    probe: [{ id: 'e1', tool: 'Edit', decision: 'END' }],
  }), reminder), true);
  assert.equal(passes('no-route-question', output({ blocks: [{ text: TRIAGE }] }), { expected_hook: '' }), false);
  assert.equal(passes('no-route-question', output({ blocks: [{ text: TRIAGE }] }), reminder), true);
  const capped = output({ blocks: [{ text: 'Skipping /zensu:build: route direct (hooks.defaultDeliveryRoute) — should the discount be capped at 100?' }] });
  assert.equal(passes('no-route-question', capped, { ...reminder, expected_status: 'Skipping /zensu:build: route direct (hooks.defaultDeliveryRoute)' }), true);
  assert.equal(passes('no-route-question', capped, reminder), false);
});

test('no-placeholder-copy flags every hook placeholder in the prose', () => {
  const placeholders = require(path.join(EVAL, 'assertions', 'no-placeholder-copy.js')).PLACEHOLDERS;
  const hook = fs.readFileSync(path.join(ROOT, 'hooks', 'user-prompt-tdd-reminder.sh'), 'utf8');
  for (const p of placeholders) {
    assert.ok(hook.includes(p), p);
    assert.equal(passes('no-placeholder-copy', output({ blocks: [{ text: `Executing via /zensu:build (route: ${p})` }] })), false);
  }
  assert.equal(passes('no-placeholder-copy', output({ blocks: [{ text: 'Skipping /zensu:build: route direct (hooks.defaultDeliveryRoute)' }] })), true);
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
  assert.equal(grade('router-triage-first', output({
    blocks: [{ use: 'WebSearch', id: 'w1' }, { result: 'WebSearch', id: 'w1' }, { text: TRIAGE }],
    probe: [{ id: 'w1', tool: 'WebSearch', decision: 'ALLOW' }],
  })).reason, 'WebSearch ran before the triage question');
  assert.equal(grade('router-triage-first', output({
    blocks: [{ use: 'AskUserQuestion', id: 'q0' }, { result: 'AskUserQuestion', id: 'q0', error: true }, { text: TRIAGE }],
    probe: [{ id: 'q0', tool: 'AskUserQuestion', decision: 'CONTINUE', question: 'Which tiers do you want?' }],
  })).reason, 'AskUserQuestion ran before the triage question');
  assert.equal(grade('router-triage-first', output({
    blocks: [{ text: TRIAGE }, { use: 'Read', id: 'r1' }, { result: 'Read', id: 'r1' }],
    probe: [{ id: 'r1', tool: 'Read', decision: 'ALLOW' }],
  })).reason, 'Read ran after the triage question, so the model looked for the answers instead of leaving them to the user');
  assert.equal(passes('router-triage-first', output({
    blocks: [{ text: TRIAGE }, { use: 'Bash', id: 'b1' }, { result: 'Bash', id: 'b1', error: true }],
    probe: [{ id: 'b1', tool: 'Bash', decision: 'SETUP', command: 'git worktree add x' }],
  })), true);
  assert.equal(passes('router-triage-first', output({
    blocks: [{ use: 'AskUserQuestion', id: 'q1' }, { result: 'AskUserQuestion', id: 'q1', error: true }, { use: 'Read', id: 'r1' }, { result: 'Read', id: 'r1' }],
    probe: [asked, { id: 'r1', tool: 'Read', decision: 'ALLOW' }],
  })), true);
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
  assert.equal(mutation.test('zensu --json feature create --title Checkout'), true);
  assert.equal(mutation.test('./node_modules/.bin/zensu feature create'), true);
  assert.equal(mutation.test('zensu create'), true);
  assert.equal(mutation.test('zensu feature list --sort created'), false);
  assert.equal(mutation.test('zensu feature list | grep add'), false);
  assert.equal(mutation.test('zensu help feature create'), false);
  assert.equal(mutation.test('zensu feature list --tag add-ons'), false);
  assert.equal(mutation.test('zensu --api-url=http://localhost:8090 feature create'), true);
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
  assert.deepEqual(preflight, ['scenarios/preflight/channel-check.yaml', 'scenarios/preflight/read-check.yaml']);
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
    if (text.includes('file://assertions/allowed-read.js')) assert.ok(vars.read_marker && fs.readFileSync(path.join(EVAL, 'test-projects', 'cart-app', 'src', 'cart.js'), 'utf8').includes(vars.read_marker), `${f} read_marker`);
    if (vars.route_source !== 'none' && vars.route_source !== 'nonce') assert.ok(vars.anchor_clause, `${f} anchor_clause`);
    if (vars.router_fires !== undefined) assert.equal(vars.router_fires, 'yes', `${f} router_fires`);
    if (vars.first_args_contains !== undefined) assert.ok(vars.allowed_first.startsWith('skill:') && vars.user_message.includes(vars.first_args_contains), `${f} first_args_contains`);
  }
  const router = scenarioVars(fs.readFileSync(path.join(EVAL, 'scenarios', 'router-genuine-planning.yaml'), 'utf8'));
  const planningControl = scenarioVars(fs.readFileSync(path.join(EVAL, 'scenarios', 'control-planning-no-injection.yaml'), 'utf8'));
  assert.equal(planningControl.user_message, router.user_message);
  assert.deepEqual([router.router_fires, planningControl.router_fires, planningControl.route_source], ['yes', 'yes', 'none']);
});
