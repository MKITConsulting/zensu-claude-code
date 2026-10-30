'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const PLUGIN = path.resolve(__dirname, '..', '..');
const DISPATCHER = path.join(PLUGIN, 'hooks', 'lib', 'hook-dispatch-v1.js');
const dispatch = require(DISPATCHER);
const registration = require(path.join(PLUGIN, 'hooks', 'lib', 'hook-registration-v1.js'));

const SHELL_PRE = ['reviewer-capability', 'zensu-cli-gate', 'source-write-gate', 'secret-scan', 'browser-consent', 'work-order-gate'];
const SHELL_POST = ['artifact-redact', 'browser-consent-recorder', 'work-order-post'];
const EDIT_PRE = ['reviewer-capability', 'work-order-gate', 'plugin-data-guard', 'tdd-edit-gate', 'secret-scan-write'];
const NOTEBOOK_PRE = ['reviewer-capability', 'work-order-gate', 'plugin-data-guard-notebook', 'secret-scan-notebook'];
const SPAWN_PRE = ['reviewer-capability', 'work-order-gate', 'reviewer-spawn-allow'];

const names = (event, tool) => dispatch.selectChecks(event, tool).map((check) => check.name);
const escaped = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const pre = (decision, reason) => ({
  hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: decision, permissionDecisionReason: reason },
});
const bashPayload = (command) => JSON.stringify({ hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command } });

test('a Read call runs only the capability and work-order checks, never a check registered for the shell tools', () => {
  assert.deepEqual(names('PreToolUse', 'Read'), ['reviewer-capability', 'work-order-gate']);
  assert.deepEqual(names('PostToolUse', 'Read'), ['work-order-post']);
});

test('a file-tool call runs its original group in registration order, and NotebookEdit keeps its own group', () => {
  for (const tool of ['Edit', 'Write', 'MultiEdit']) {
    assert.deepEqual(names('PreToolUse', tool), EDIT_PRE);
    assert.deepEqual(names('PostToolUse', tool), ['work-order-post', 'artifact-redact-write']);
  }
  assert.deepEqual(names('PreToolUse', 'NotebookEdit'), NOTEBOOK_PRE);
  assert.deepEqual(names('PostToolUse', 'NotebookEdit'), ['work-order-post']);
});

test('a spawn call reaches the grant behind every check that can deny or ask, and no other tool reaches it', () => {
  for (const tool of ['Agent', 'Task']) assert.deepEqual(names('PreToolUse', tool), SPAWN_PRE);
  for (const tool of ['Bash', 'PowerShell', 'Read', 'Edit', 'NotebookEdit']) {
    assert.equal(names('PreToolUse', tool).includes('reviewer-spawn-allow'), false, tool);
  }
  const grant = JSON.parse(require(path.join(PLUGIN, 'hooks', 'lib', 'reviewer-spawn-allow-v1.js')).decide(JSON.stringify({
    tool_name: 'Agent', tool_input: { subagent_type: 'zensu:code-reviewer' },
  })));
  assert.equal(grant.hookSpecificOutput.permissionDecision, 'allow');
  for (const rival of ['deny', 'ask', 'defer']) {
    for (const outputs of [[pre(rival, 'rival'), grant], [grant, pre(rival, 'rival')]]) {
      assert.deepEqual(dispatch.aggregate(outputs, 'PreToolUse'), pre(rival, 'rival'));
    }
  }
});

test('the spawn grant needs every library the old hook sourced, and a symlink only where that hook refused one', () => {
  const lib = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-grant-libs-')));
  const sourced = ['zensu-agent-context.sh', 'zensu-session.sh', 'zensu-host-path.sh', 'zensu-config.sh'];
  const guarded = ['zensu-msys-env.sh', 'claude-principal-v1.js', 'reviewer-spawn-allow-v1.js'];
  try {
    for (const name of [...sourced, ...guarded]) fs.writeFileSync(path.join(lib, name), 'x');
    assert.equal(dispatch.spawnGrantLibrariesPresent(lib), true);
    for (const name of [...sourced, ...guarded]) {
      fs.rmSync(path.join(lib, name));
      assert.equal(dispatch.spawnGrantLibrariesPresent(lib), false, name);
      fs.writeFileSync(path.join(lib, name), 'x');
    }
    if (process.platform !== 'win32') {
      fs.writeFileSync(path.join(lib, 'target'), 'x');
      for (const [name, expected] of [[sourced[0], true], [guarded[0], false]]) {
        fs.rmSync(path.join(lib, name));
        fs.symlinkSync(path.join(lib, 'target'), path.join(lib, name));
        assert.equal(dispatch.spawnGrantLibrariesPresent(lib), expected, name);
        fs.rmSync(path.join(lib, name));
        fs.writeFileSync(path.join(lib, name), 'x');
      }
    }
  } finally {
    fs.rmSync(lib, { recursive: true, force: true });
  }
  assert.equal(dispatch.spawnGrantLibrariesPresent(path.join(PLUGIN, 'hooks', 'lib')), true);
});

test('the registry readers still answer one virtual entry per original group, with the dispatcher timeout', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(PLUGIN, 'hooks', 'hooks.json'), 'utf8'));
  const entries = (event, script) => registration.registeredHooks(manifest, event)
    .filter((entry) => entry.command.endsWith(`/hooks/${script}"`))
    .map((entry) => `${entry.matcher}=${entry.timeout}`);
  assert.deepEqual(entries('PreToolUse', 'pre-write-plugin-data-guard.sh'), ['Edit|Write|MultiEdit=60', 'NotebookEdit=60']);
  assert.deepEqual(entries('PreToolUse', 'pre-edit-tdd-reminder.sh'), ['Edit|Write|MultiEdit=60']);
  assert.deepEqual(entries('PreToolUse', 'pre-write-secret-scan.sh'), ['Bash|PowerShell=60', 'Edit|Write|MultiEdit=60', 'NotebookEdit=60']);
  assert.deepEqual(entries('PreToolUse', 'pre-agent-reviewer-allow.sh'), ['Agent|Task=60']);
  assert.deepEqual(entries('PostToolUse', 'post-artifact-redact.sh'), ['Bash|PowerShell=60', 'Edit|Write|MultiEdit=60']);
});

test('the edit path class names the state directory, any .zensu path and everything else, through a symlink too', () => {
  const { editPathClass } = require(path.join(PLUGIN, 'hooks', 'lib', 'edit-path-class-v1.js'));
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-edit-class-')));
  try {
    const state = path.join(root, '.zensu', 'state');
    fs.mkdirSync(state, { recursive: true });
    fs.mkdirSync(path.join(root, 'src'));
    assert.equal(editPathClass(path.join(state, 'tdd-phase-x.json'), state), 'state');
    assert.equal(editPathClass(path.join(root, 'src', '..', '.zensu', 'state', 'new.json'), state), 'state');
    assert.equal(editPathClass(path.join(root, '.zensu', 'plans', 'p.md'), state), 'zensu');
    assert.equal(editPathClass(path.join(root, '.zensu'), state), 'zensu');
    assert.equal(editPathClass(path.join(root, 'src', 'app.js'), state), 'other');
    const codeRoot = path.join(root, 'sibling');
    fs.mkdirSync(path.join(codeRoot, '.zensu', 'state'), { recursive: true });
    const document = { codeRoots: [{ label: 'app', path: codeRoot, top: codeRoot }] };
    assert.equal(editPathClass(path.join(codeRoot, '.zensu', 'state', 'x.json'), state), 'zensu');
    assert.equal(editPathClass(path.join(codeRoot, '.zensu', 'state', 'x.json'), state, document), 'state');
    assert.equal(editPathClass(path.join(codeRoot, 'src', 'app.js'), state, document), 'other');
    assert.equal(editPathClass(path.join(codeRoot, '.zensu', 'state', 'x.json'), state, { codeRoots: 'broken' }), 'zensu');
    if (process.platform !== 'win32') {
      fs.symlinkSync(state, path.join(root, 'src', 'link'));
      assert.equal(editPathClass(path.join(root, 'src', 'link', 'tdd-phase-x.json'), state), 'state');
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('a Bash or PowerShell call runs every shell check in registry order, the capability check first', () => {
  for (const tool of ['Bash', 'PowerShell']) {
    assert.deepEqual(names('PreToolUse', tool), SHELL_PRE);
    assert.deepEqual(names('PostToolUse', tool), SHELL_POST);
  }
});

test('every entry point dispatches the first check that names it and falls back to the body the registry names', () => {
  const seen = new Set();
  for (const check of dispatch.REGISTRY) {
    const key = `${check.event}:${check.name}`;
    assert.equal(seen.has(key), false, key);
    seen.add(key);
    const wrapper = fs.readFileSync(path.join(PLUGIN, 'hooks', check.script), 'utf8');
    const event = check.event === 'PreToolUse' ? 'pre' : 'post';
    const first = dispatch.REGISTRY.find((other) => other.event === check.event && other.script === check.script);
    assert.equal(check.body, first.body, check.name);
    assert.equal(check.failure, first.failure, check.name);
    assert.match(wrapper, new RegExp(`zensu_hook_dispatch(?:_guarded)? ${event} ${escaped(first.name)} `), check.script);
    if (check.body === null) continue;
    assert.equal(fs.lstatSync(path.join(PLUGIN, 'hooks', check.body)).isFile(), true, check.body);
    assert.match(wrapper, new RegExp(`"\\$_zensu_hooks/${escaped(check.body)}"`), check.script);
  }
  assert.equal(dispatch.REGISTRY, registration.DISPATCHED_CHECKS);
});

test('every check matcher has one host reading, and only the capability, source-write and consent checks fail closed', () => {
  for (const check of dispatch.REGISTRY) {
    for (const tool of ['Bash', 'PowerShell', 'Read', 'Edit', 'Write', 'MultiEdit', 'NotebookEdit', 'Agent', 'Task']) {
      assert.notEqual(registration.hostMatcherCovers(check.matcher, tool), registration.REGISTRATION.UNKNOWN, check.name);
    }
  }
  assert.deepEqual(
    dispatch.REGISTRY.filter((check) => check.failure === 'closed').map((check) => check.name),
    ['reviewer-capability', 'source-write-gate', 'browser-consent'],
  );
  assert.deepEqual(dispatch.REGISTRY.filter((check) => check.failure !== 'closed').map((check) => check.failure),
    Array(13).fill('open'));
});

test('hooks.json starts one dispatcher per tool event in exec form on every tool, blocking on failure before a tool runs', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(PLUGIN, 'hooks', 'hooks.json'), 'utf8'));
  for (const event of ['PreToolUse', 'PostToolUse']) {
    const found = [];
    for (const group of manifest.hooks[event] || []) {
      for (const hook of group.hooks || []) {
        if (registration.dispatcherEvent(hook) === event) found.push({ group, hook });
      }
    }
    assert.equal(found.length, 1, event);
    assert.equal(found[0].group.matcher, '.*');
    assert.equal(found[0].hook.timeout, 60);
    assert.equal(found[0].hook.onFailure, event === 'PreToolUse' ? 'block' : undefined);
  }
  assert.deepEqual(manifest.hooks.PreToolUse.map((group) => group.matcher), ['.*']);
  assert.deepEqual(manifest.hooks.PostToolUse.map((group) => group.matcher), ['ExitPlanMode', 'Agent|Task', 'Workflow', '.*']);
});

test('the dispatcher refuses an unknown event, a check of another event and a stray argument before it reads stdin', () => {
  for (const argv of [[], ['sideways'], ['pre', '--only', 'artifact-redact'], ['post', '--only'], ['pre', 'extra']]) {
    const run = spawnSync(process.execPath, [DISPATCHER, ...argv], { encoding: 'utf8', timeout: 15000 });
    assert.equal(run.status, 2, argv.join(' '));
    assert.equal(run.stdout, '');
    assert.match(run.stderr, /^usage: hook-dispatch-v1\.js pre\|post \[--only <check>\]\n$/);
  }
});

test('a single check output passes through unchanged and no output aggregates to none', () => {
  const only = pre('ask', 'confirm the navigation');
  assert.equal(dispatch.aggregate([null, only, undefined], 'PreToolUse'), only);
  assert.equal(dispatch.aggregate([null, undefined], 'PreToolUse'), null);
});

test('deny outranks defer, ask and allow, and the reasons of the winning decision join in registry order', () => {
  assert.deepEqual(dispatch.aggregate([
    pre('allow', 'granted'),
    pre('deny', 'first'),
    pre('ask', 'asked'),
    pre('defer', 'deferred'),
    pre('deny', 'second'),
  ], 'PreToolUse'), pre('deny', 'first\n\nsecond'));
  assert.deepEqual(dispatch.aggregate([pre('allow', 'a'), pre('defer', 'b'), pre('ask', 'c')], 'PreToolUse'), pre('defer', 'b'));
  assert.deepEqual(dispatch.aggregate([pre('allow', 'a'), pre('ask', 'c'), pre('allow', 'd')], 'PreToolUse'), pre('ask', 'c'));
});

test('additional context joins in registry order and stays under the 10,000-character cap', () => {
  const capability = 'c'.repeat(6000);
  const other = 'o'.repeat(6000);
  const out = dispatch.aggregate([
    { hookSpecificOutput: { hookEventName: 'PreToolUse', additionalContext: capability } },
    { hookSpecificOutput: { hookEventName: 'PreToolUse', additionalContext: other } },
  ], 'PreToolUse');
  assert.equal(out.hookSpecificOutput.additionalContext.length, 10000);
  assert.equal(out.hookSpecificOutput.additionalContext.startsWith(`${capability}\n\n`), true);
  assert.equal(out.hookSpecificOutput.permissionDecision, undefined);
});

test('system messages, a block decision and a stop from several checks are all kept', () => {
  assert.deepEqual(dispatch.aggregate([
    { systemMessage: 'one', decision: 'block', reason: 'redacted' },
    { systemMessage: 'two', continue: false, stopReason: 'stop', suppressOutput: true },
  ], 'PostToolUse'), {
    systemMessage: 'one\ntwo',
    decision: 'block',
    reason: 'redacted',
    continue: false,
    stopReason: 'stop',
    suppressOutput: true,
  });
});

test('the secret-scan pre-check skips only a Bash payload that holds no write-channel token', () => {
  assert.equal(dispatch.secretScanSkipsBash(bashPayload('git status --short')), true);
  for (const command of ['printf x > a', 'cat <<EOF\nx\nEOF', 'printf x | tee a', 'dd if=a of=b', 'sed -e s/a/b/ -i f']) {
    assert.equal(dispatch.secretScanSkipsBash(bashPayload(command)), false, command);
  }
  assert.equal(dispatch.secretScanSkipsBash('{"tool_name":"Bash","tool_input":{"command":"printf x \\u003e a"}}'), false);
  assert.equal(dispatch.secretScanSkipsBash('{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_name":"PowerShell"}'), false);
  assert.equal(dispatch.secretScanSkipsBash(JSON.stringify({ tool_name: 'PowerShell', tool_input: { command: 'ls' } })), false);
});

test('the consent pre-check marks the playwright spellings the prefilter marks and leaves an unrelated call unmarked', () => {
  for (const command of [
    'playwright-cli -s=zensu-verify-x snapshot',
    'pla""ywright-cli -s=zensu-verify-x snapshot',
    'playw\\\nright-cli -s=zensu-ver\\\nify-x snapshot',
    'PLAYWRIGHT-CLI snapshot',
    'ls zensu-verify-notes',
  ]) {
    assert.equal(dispatch.consentMarked(bashPayload(command)), true, command);
  }
  const powershell = (command) => JSON.stringify({ tool_name: 'PowerShell', tool_input: { command } });
  assert.equal(dispatch.consentMarked(powershell("& ('pla' + 'ywright-cli') -s=('zensu-' + 'verify-x') snapshot")), true);
  assert.equal(dispatch.consentMarked(powershell('Write-Output "`u{41}"')), true);
  assert.equal(dispatch.consentMarked(powershell('Get-ChildItem -Recurse')), false);
  assert.equal(dispatch.consentMarked(bashPayload('git status --short')), false);
});
