'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const PLUGIN = path.resolve(__dirname, '..', '..');
const DISPATCHER = path.join(PLUGIN, 'hooks', 'lib', 'hook-dispatch-v1.js');
const dispatch = require(DISPATCHER);
const registration = require(path.join(PLUGIN, 'hooks', 'lib', 'hook-registration-v1.js'));

const SHELL_PRE = ['reviewer-capability', 'zensu-cli-gate', 'source-write-gate', 'secret-scan', 'browser-consent', 'work-order-gate'];
const SHELL_POST = ['artifact-redact', 'browser-consent-recorder', 'work-order-post'];

const names = (event, tool) => dispatch.selectChecks(event, tool).map((check) => check.name);
const escaped = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const pre = (decision, reason) => ({
  hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: decision, permissionDecisionReason: reason },
});
const bashPayload = (command) => JSON.stringify({ hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command } });

test('a Read call runs only the capability and work-order checks, never a check registered for the shell tools', () => {
  assert.deepEqual(names('PreToolUse', 'Read'), ['reviewer-capability', 'work-order-gate']);
  assert.deepEqual(names('PostToolUse', 'Read'), ['work-order-post']);
  assert.deepEqual(names('PreToolUse', 'Edit'), ['reviewer-capability', 'work-order-gate']);
});

test('a Bash or PowerShell call runs every shell check in registry order, the capability check first', () => {
  for (const tool of ['Bash', 'PowerShell']) {
    assert.deepEqual(names('PreToolUse', tool), SHELL_PRE);
    assert.deepEqual(names('PostToolUse', tool), SHELL_POST);
  }
});

test('every check names a wrapper that dispatches exactly that check and falls back to the body the registry names', () => {
  const seen = new Set();
  for (const check of dispatch.REGISTRY) {
    const key = `${check.event}:${check.name}`;
    assert.equal(seen.has(key), false, key);
    seen.add(key);
    const wrapper = fs.readFileSync(path.join(PLUGIN, 'hooks', check.script), 'utf8');
    const event = check.event === 'PreToolUse' ? 'pre' : 'post';
    assert.match(wrapper, new RegExp(`zensu_hook_dispatch(?:_guarded)? ${event} ${escaped(check.name)} `), check.script);
    if (check.body === null) continue;
    assert.equal(fs.lstatSync(path.join(PLUGIN, 'hooks', check.body)).isFile(), true, check.body);
    assert.match(wrapper, new RegExp(`"\\$_zensu_hooks/${escaped(check.body)}"`), check.script);
  }
  assert.equal(dispatch.REGISTRY, registration.DISPATCHED_CHECKS);
});

test('every check matcher has one host reading, and only the capability, source-write and consent checks fail closed', () => {
  for (const check of dispatch.REGISTRY) {
    for (const tool of ['Bash', 'PowerShell', 'Read', 'Edit', 'Agent']) {
      assert.notEqual(registration.hostMatcherCovers(check.matcher, tool), registration.REGISTRATION.UNKNOWN, check.name);
    }
  }
  assert.deepEqual(
    dispatch.REGISTRY.filter((check) => check.failure === 'closed').map((check) => check.name),
    ['reviewer-capability', 'source-write-gate', 'browser-consent'],
  );
  assert.deepEqual(dispatch.REGISTRY.filter((check) => check.failure !== 'closed').map((check) => check.failure),
    Array(6).fill('open'));
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

test('the CLI-gate pre-check reads the zensu name in every spelling the gate body reads and leaves other calls to pass unread', () => {
  for (const command of [
    'zensu security classify f1',
    'ZENSU security classify f1',
    'Zensu.exe security classify f1',
    '/opt/homebrew/bin/ZENSU security classify f1',
    'zen\u017fu security classify f1',
    'z\\ensu security classify f1',
    'zen""su security classify f1',
    "zen$''su security classify f1",
    'zen\\\nsu security classify f1',
    '"C:\\Program Files\\Zensu\\zensu.exe" security classify f1',
    'ls # x\\\nZEN\\\nSU security classify f1',
    'echo "a #b" && zen\\\nsu features create --product p --title t',
    '(true)# c\\\nzen""su security classify f1',
  ]) {
    assert.equal(dispatch.zensuNamed(command), true, command);
  }
  for (const command of ['git status --short', 'ls .zensu/plans', 'bash hooks/lib/zensu-log.sh --project-root', 'cat dev.zensu/README.md']) {
    assert.equal(dispatch.zensuNamed(command), false, command);
  }
});

test('the CLI-gate pre-check answers exactly as the gate body early exit on every command of a generated corpus', () => {
  const body = fs.readFileSync(path.join(PLUGIN, 'hooks', 'checks', 'pre-bash-zensu-gate.sh'), 'utf8').split('\n');
  const start = body.findIndex((line) => line.startsWith('  const joinLines = '));
  const end = body.findIndex((line) => line.startsWith('  const candidates = '));
  assert.ok(start !== -1 && end > start, 'the early exit of hooks/checks/pre-bash-zensu-gate.sh was not found');
  const bodyNamed = new Function('cmd', `${body.slice(start, end + 1).join('\n')}\nreturn candidates.some((text) => NAMED.test(text));`);
  const parts = [
    'zensu', 'ZEN', 'SU', 'zen', 'su', 'z', 'e', 'n', 's', 'u', '\u017f', '\\', '\n', '\\\n', '"', "'", '""', "$''", '$',
    '#', ' #', '# c', ' ', ';', '&&', '(', ')', '(true)', 'echo "a #b"', 'x', '.', '-', '/',
  ];
  let seed = 7;
  const next = () => {
    seed = (seed * 48271) % 2147483647;
    return seed;
  };
  const corpus = [];
  const prefixes = ['', ' ', 'x', '.', '/opt/', 'echo "a #b" && ', 'echo "a #b"; ', '(true)# c\\\n', 'ls # x\\\n', 'x\\\n', 'echo \\\\\n', "echo 'a\\\n'; "];
  const names = ['zensu', 'ZENSU', 'zenſu', 'ZEN""SU', "zen$''su", 'z\\ensu', 'zen\\\nsu', 'ZEN\\\nSU', 'zen""\\\nsu', '\\ZENSU'];
  const suffixes = ['', ' security classify f1', '.exe x', '-log.sh', '_x', '/x', '\n'];
  for (const prefix of prefixes) {
    for (const name of names) {
      for (const suffix of suffixes) corpus.push(prefix + name + suffix);
    }
  }
  for (let i = 0; i < 20000; i += 1) {
    let command = '';
    const length = 1 + (next() % 12);
    for (let k = 0; k < length; k += 1) command += parts[next() % parts.length];
    corpus.push(command);
  }
  let named = 0;
  for (const command of corpus) {
    const expected = bodyNamed(command);
    assert.equal(dispatch.zensuNamed(command), expected, JSON.stringify(command));
    if (expected) named += 1;
  }
  assert.ok(named > 0 && named < corpus.length, `the corpus names zensu in ${named} of ${corpus.length} commands`);
});
