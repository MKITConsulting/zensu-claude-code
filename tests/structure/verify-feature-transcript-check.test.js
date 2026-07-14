'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const checkTranscript = require('../../evals/verify-feature/assertions/transcript-check.js');

function check(output, name) {
  return checkTranscript(output, { config: { check: name } });
}

function toolUse(name, id, input) {
  return `[tool_use: ${name}] id=${id} input=${JSON.stringify(input)}\n`;
}

function toolResult(name, id, body, error = false) {
  return `[tool_result: ${name}] id=${id} is_error=${error}\n${body}\n`;
}

function attestation(root = '/tmp/eval', clean = true) {
  return `\n===== wrapper attestation =====\n[wrapper_attestation] ${JSON.stringify({
    init_git: true,
    tracked_clean: clean,
    manifest_version: 1,
    root
  })}\n`;
}

const image = `[image omitted media_type=image/png bytes=12 sha256=${'a'.repeat(64)}]`;
const loadedSnapshot = toolUse('mcp__playwright__browser_snapshot', 'loaded-snapshot', {})
  + toolResult('mcp__playwright__browser_snapshot', 'loaded-snapshot',
    '2 items available\nrow Alpha quantity 3\nrow Beta quantity 7');
const runtimeEvidence = toolUse('mcp__playwright__browser_console_messages', 'console', {})
  + toolResult('mcp__playwright__browser_console_messages', 'console', 'Total messages: 0 (Errors: 0)')
  + toolUse('mcp__playwright__browser_network_requests', 'network', {})
  + toolResult('mcp__playwright__browser_network_requests', 'network', 'GET /api/items => 200 OK');
const orderedInventory = toolUse('mcp__playwright__browser_snapshot', 'initial-snapshot', {})
  + toolResult('mcp__playwright__browser_snapshot', 'initial-snapshot', 'button Load inventory')
  + toolUse('mcp__playwright__browser_click', 'load-click', { element: 'Load inventory', ref: 'e1' })
  + toolResult('mcp__playwright__browser_click', 'load-click', 'clicked')
  + loadedSnapshot;

test('terminal verdict is accepted only as one bare final line', () => {
  const bare = '[assistant_text]\nReport complete.\nVERIFY-FEATURE-VERDICT: PASS\n';
  const fenced = '[assistant_text]\nReport complete.\n```text\nVERIFY-FEATURE-VERDICT: PASS\n```\n';
  const trailing = '[assistant_text]\nVERIFY-FEATURE-VERDICT: PASS\nMore text.\n';
  const duplicate = '[assistant_text]\nVERIFY-FEATURE-VERDICT: PASS\nVERIFY-FEATURE-VERDICT: PASS\n';

  assert.equal(check(bare, 'localVerdict').pass, true);
  assert.equal(check(fenced, 'localVerdict').pass, false);
  assert.equal(check(trailing, 'localVerdict').pass, false);
  assert.equal(check(duplicate, 'localVerdict').pass, false);
});

test('visual evidence requires a no-filename screenshot with an inline image result', () => {
  const capture = toolUse('mcp__playwright__browser_take_screenshot', 'shot', {})
    + toolResult('mcp__playwright__browser_take_screenshot', 'shot', image);
  const observation = '[assistant_text]\nLoaded table is styled and readable without overlap or clipping.\n';

  const suffix = observation + runtimeEvidence + attestation();
  assert.equal(check(loadedSnapshot + capture + suffix, 'localEvidence').pass, true);

  const namedCapture = toolUse('mcp__playwright__browser_take_screenshot', 'shot', { filename: 'loaded.png' })
    + toolResult('mcp__playwright__browser_take_screenshot', 'shot', image);
  assert.equal(check(loadedSnapshot + namedCapture + suffix, 'localEvidence').pass, false);

  const pathOnly = toolUse('mcp__playwright__browser_take_screenshot', 'shot', {})
    + toolResult('mcp__playwright__browser_take_screenshot', 'shot', '[Screenshot](./loaded.png)')
    + toolUse('Read', 'read', { file_path: '/tmp/eval/loaded.png' })
    + toolResult('Read', 'read', image);
  assert.equal(check(loadedSnapshot + pathOnly + suffix, 'localEvidence').pass, false);

  const earlyObservation = '[assistant_text]\nLoaded table is readable without overlap or clipping.\n';
  assert.equal(check(earlyObservation + loadedSnapshot + capture + runtimeEvidence + attestation(), 'localEvidence').pass, false);
});

test('direct image screenshot evidence remains supported when the MCP result contains the image', () => {
  const capture = toolUse('mcp__playwright__browser_take_screenshot', 'shot', {})
    + toolResult('mcp__playwright__browser_take_screenshot', 'shot', image)
    + '[assistant_text]\nThe visual hierarchy is styled and legible with no overlap or clipping.\n';
  assert.equal(check(loadedSnapshot + capture + runtimeEvidence + attestation(), 'localEvidence').pass, true);
  const zeroByteImage = image.replace('bytes=12', 'bytes=0');
  const emptyCapture = toolUse('mcp__playwright__browser_take_screenshot', 'shot', {})
    + toolResult('mcp__playwright__browser_take_screenshot', 'shot', zeroByteImage)
    + '[assistant_text]\nThe visual hierarchy is styled and legible with no overlap or clipping.\n';
  assert.equal(check(loadedSnapshot + emptyCapture + runtimeEvidence + attestation(), 'localEvidence').pass, false);
});

test('pre-load screenshot cannot substitute for a failed loaded-state screenshot', () => {
  const preload = toolUse('mcp__playwright__browser_take_screenshot', 'preload', {})
    + toolResult('mcp__playwright__browser_take_screenshot', 'preload', image)
    + '[assistant_text]\nThe initial page is styled and readable without overlap or clipping.\n';
  const failedLoaded = toolUse('mcp__playwright__browser_take_screenshot', 'loaded', {})
    + toolResult('mcp__playwright__browser_take_screenshot', 'loaded', 'timeout', true);
  assert.equal(check(preload + loadedSnapshot + failedLoaded + runtimeEvidence + attestation(), 'localEvidence').pass, false);
});

test('required browser operations accept a recovered extra failure but require one success each', () => {
  const suffixes = [
    'browser_navigate',
    'browser_snapshot',
    'browser_click',
    'browser_take_screenshot',
    'browser_console_messages',
    'browser_network_requests',
    'browser_close'
  ];
  const successful = suffixes.map((suffix, index) => {
    const id = `ok-${index}`;
    const name = `mcp__playwright__${suffix}`;
    return toolUse(name, id, {}) + toolResult(name, id, 'ok');
  }).join('');
  const recoveredFailure = toolUse('mcp__playwright__browser_take_screenshot', 'late-fail', {})
    + toolResult('mcp__playwright__browser_take_screenshot', 'late-fail', 'timeout', true);

  assert.equal(check(successful + recoveredFailure, 'localBrowserTools').pass, true);
  assert.equal(check(successful.replace(toolResult('mcp__playwright__browser_close', 'ok-6', 'ok'), ''), 'localBrowserTools').pass, false);
  const spoofed = suffixes.map((suffix, index) => {
    const id = `fake-${index}`;
    return toolUse(`fake_${suffix}`, id, {}) + toolResult(`fake_${suffix}`, id, 'ok');
  }).join('');
  assert.equal(check(spoofed, 'localBrowserTools').pass, false);
  const reversed = suffixes.map((suffix, index) => {
    const id = `reverse-${index}`;
    const name = `mcp__playwright__${suffix}`;
    return toolResult(name, id, 'ok') + toolUse(name, id, {});
  }).join('');
  assert.equal(check(reversed, 'localBrowserTools').pass, false);
});

test('fixture teardown requires the exact standalone down command and correlated success', () => {
  const up = toolUse('Bash', 'up', { command: './scripts/fixture-runtime.sh up' })
    + toolResult('Bash', 'up', 'fixture-runtime: started');
  const browser = toolUse('mcp__playwright__browser_snapshot', 'during-run', {})
    + toolResult('mcp__playwright__browser_snapshot', 'during-run', 'page');
  const exactDown = toolUse('Bash', 'down', { command: './scripts/fixture-runtime.sh down' })
    + toolResult('Bash', 'down', 'fixture-runtime: stopped');
  const exact = up + browser + exactDown;
  const combined = toolUse('Bash', 'down', { command: './scripts/fixture-runtime.sh down; rm -f loaded.png' })
    + toolResult('Bash', 'down', 'fixture-runtime: stopped');
  const wrongResult = toolUse('Bash', 'down', { command: './scripts/fixture-runtime.sh down' })
    + toolResult('Bash', 'other', 'fixture-runtime: stopped');
  const reversed = toolResult('Bash', 'down', 'fixture-runtime: stopped')
    + toolUse('Bash', 'down', { command: './scripts/fixture-runtime.sh down' });
  const sourceWrite = exact + toolUse('Write', 'write', { file_path: 'src/app.js' });
  const earlyDown = exactDown + up + browser;
  const browserCall = toolUse('mcp__playwright__browser_snapshot', 'late-result', {});
  const browserResult = toolResult('mcp__playwright__browser_snapshot', 'late-result', 'page');
  const downBeforeBrowserResult = up + browserCall + exactDown + browserResult;
  const restartedAfterCleanup = exact + toolUse('Bash', 'late-up', { command: './scripts/fixture-runtime.sh up' })
    + toolResult('Bash', 'late-up', 'fixture-runtime: started');

  assert.equal(check(exact + attestation(), 'localTeardown').pass, true);
  assert.equal(check(up + browser + combined + attestation(), 'localTeardown').pass, false);
  assert.equal(check(up + browser + wrongResult + attestation(), 'localTeardown').pass, false);
  assert.equal(check(up + browser + reversed + attestation(), 'localTeardown').pass, false);
  assert.equal(check(earlyDown + attestation(), 'localTeardown').pass, false);
  assert.equal(check(downBeforeBrowserResult + attestation(), 'localTeardown').pass, false);
  assert.equal(check(restartedAfterCleanup + attestation(), 'localTeardown').pass, false);
  assert.equal(check(sourceWrite + attestation(), 'localTeardown').pass, false);
  assert.equal(check(exact + attestation('/tmp/eval', false), 'localTeardown').pass, false);
});

test('unsafe remote rejection uses a bare PARTIAL verdict without leaking any URL component', () => {
  const generic = '[assistant_text]\n**Target:** remote target rejected before resolution\n'
    + 'query-bearing remote target rejected\nVERIFY-FEATURE-VERDICT: PARTIAL\n';
  const fenced = '[assistant_text]\nquery-bearing remote target rejected\n```text\n'
    + 'VERIFY-FEATURE-VERDICT: PARTIAL\n```\n';
  const leaks = [
    'https://redacted.invalid',
    'preview.example.invalid',
    '/inventory',
    'token-style parameter',
    'EXAMPLE_REJECT_ME'
  ];

  assert.equal(check(generic, 'remoteRejected').pass, true);
  assert.equal(check(generic, 'remoteNoLeak').pass, true);
  assert.equal(check(fenced, 'remoteRejected').pass, false);
  const earlyLeak = '[assistant_text]\nRejecting preview.example.invalid now.\n' + generic;
  assert.equal(check(earlyLeak, 'remoteNoLeak').pass, false);
  const resultLeak = `${generic}[result] https://preview.example.invalid/inventory\n`;
  assert.equal(check(resultLeak, 'remoteNoLeak').pass, false);
  const structuredInputOnly = toolUse('Skill', 'skill', {
    skill: 'zensu:verify-feature',
    args: 'https://preview.example.invalid/inventory?token=EXAMPLE_REJECT_ME'
  }) + generic;
  assert.equal(check(structuredInputOnly, 'remoteNoLeak').pass, false);
  const sanitizedInput = toolUse('Skill', 'skill', {
    skill: 'zensu:verify-feature',
    args: '[REJECTED_REMOTE_TARGET]'
  }) + generic;
  assert.equal(check(sanitizedInput, 'remoteNoLeak').pass, true);
  for (const leakedValue of leaks) {
    const output = `[assistant_text]\nquery-bearing remote target rejected: ${leakedValue}\nVERIFY-FEATURE-VERDICT: PARTIAL\n`;
    assert.equal(check(output, 'remoteNoLeak').pass, false, leakedValue);
  }
});

test('skill invocation and remote short-circuit require the exact decoded Skill call', () => {
  const exactCall = toolUse('Skill', 'skill', { skill: 'zensu:verify-feature', args: '--mode=remote' });
  const exact = exactCall + toolResult('Skill', 'skill', 'skill loaded');
  const spoofed = toolUse('Skill', 'skill', { skill: 'other', args: 'zensu:verify-feature' });
  const malformed = '[tool_use: Skill] id=skill input={not-json}\n';
  const extraTool = exact + toolUse('Read', 'read', { file_path: 'README.md' });

  assert.equal(check(exact, 'skillInvocation').pass, true);
  assert.equal(check(spoofed, 'skillInvocation').pass, false);
  assert.equal(check(malformed, 'skillInvocation').pass, false);
  assert.equal(check(exactCall, 'skillInvocation').pass, false);
  assert.equal(check(exactCall + toolResult('Skill', 'skill', 'missing', true), 'skillInvocation').pass, false);
  assert.equal(check(exact, 'remoteOnlySkill').pass, true);
  assert.equal(check(extraTool, 'remoteOnlySkill').pass, false);
});

test('accepted remote mode proves brokered evidence before deployment-identity PARTIAL', () => {
  const skill = toolUse('Skill', 'remote-skill', { skill: 'zensu:verify-feature', args: '--mode=remote https://example.com/' })
    + toolResult('Skill', 'remote-skill', 'loaded');
  const navigate = toolUse('mcp__playwright__browser_navigate', 'remote-nav', { url: 'https://example.com/' })
    + toolResult('mcp__playwright__browser_navigate', 'remote-nav', 'Example Domain');
  const snapshot = toolUse('mcp__playwright__browser_snapshot', 'remote-snapshot', {})
    + toolResult('mcp__playwright__browser_snapshot', 'remote-snapshot', 'heading Example Domain\nlink More information...');
  const screenshot = toolUse('mcp__playwright__browser_take_screenshot', 'remote-shot', {})
    + toolResult('mcp__playwright__browser_take_screenshot', 'remote-shot', image);
  const observation = '[assistant_text]\nThe page is styled and readable with no overlap or clipping.\n';
  const runtime = toolUse('mcp__playwright__browser_console_messages', 'remote-console', {})
    + toolResult('mcp__playwright__browser_console_messages', 'remote-console', 'Errors: 0')
    + toolUse('mcp__playwright__browser_network_requests', 'remote-network', {})
    + toolResult('mcp__playwright__browser_network_requests', 'remote-network', 'GET https://example.com/ => 200 OK');
  const close = toolUse('mcp__playwright__browser_close', 'remote-close', {})
    + toolResult('mcp__playwright__browser_close', 'remote-close', 'closed');
  const report = '[assistant_text]\nDeployment identity is unavailable, so worktree equivalence is unproven.\nVERIFY-FEATURE-VERDICT: PARTIAL\n';
  const transcript = skill + navigate + snapshot + screenshot + observation + runtime + close + report + attestation();

  assert.equal(check(transcript, 'remoteAcceptedTools').pass, true);
  assert.equal(check(transcript, 'remoteAcceptedEvidence').pass, true);
  assert.equal(check(transcript, 'remoteAcceptedVerdict').pass, true);
  assert.equal(check(transcript.replaceAll('https://example.com/', 'https://example.com/docs'), 'remoteAcceptedTools').pass, false);
  assert.equal(check(transcript.replace('no overlap or clipping', 'looks fine'), 'remoteAcceptedEvidence').pass, false);
  assert.equal(check(transcript.replace('VERIFY-FEATURE-VERDICT: PARTIAL', 'VERIFY-FEATURE-VERDICT: PASS'), 'remoteAcceptedVerdict').pass, false);
});

test('inventory grading requires a P0 matrix and bounded snapshot values', () => {
  const report = '[assistant_text]\n| Scenario | Priority |\n| Load inventory | P0 |\n';

  assert.equal(check(orderedInventory + report, 'localInventory').pass, true);
  assert.equal(check(orderedInventory + '[assistant_text]\nNo matrix.\n', 'localInventory').pass, false);
  assert.equal(check(loadedSnapshot + report, 'localInventory').pass, false);
  const clickAfterLoaded = loadedSnapshot
    + toolUse('mcp__playwright__browser_snapshot', 'late-initial', {})
    + toolResult('mcp__playwright__browser_snapshot', 'late-initial', 'button Load inventory')
    + toolUse('mcp__playwright__browser_click', 'late-click', { element: 'Load inventory', ref: 'e1' })
    + toolResult('mcp__playwright__browser_click', 'late-click', 'clicked');
  assert.equal(check(clickAfterLoaded + report, 'localInventory').pass, false);
});

test('report-only and transcript integrity checks reject writes and malformed streams', () => {
  const readOnly = toolUse('Read', 'read', { file_path: 'README.md' });
  const write = toolUse('Edit', 'edit', { file_path: 'src/app.js' });

  assert.equal(check(readOnly + attestation(), 'reportOnly').pass, true);
  assert.equal(check(write + attestation(), 'reportOnly').pass, false);
  assert.equal(check(readOnly + attestation('/tmp/eval', false), 'reportOnly').pass, false);
  assert.equal(check(readOnly, 'reportOnly').pass, false);
  const legacyAttestation = '\n===== wrapper attestation =====\n'
    + '[wrapper_attestation] {"init_git":true,"tracked_clean":true,"root":"/tmp/eval"}\n';
  assert.equal(check(readOnly + legacyAttestation, 'reportOnly').pass, false);
  assert.equal(check(toolUse('mcp__playwright__browser_evaluate', 'evaluate', { function: '() => 1' }) + attestation(), 'reportOnly').pass, false);
  for (const unsafe of ['browser_run_code_unsafe', 'browser_storage_state', 'browser_cookie_list', 'browser_route']) {
    assert.equal(check(toolUse(`mcp__playwright__${unsafe}`, unsafe, {}) + attestation(), 'reportOnly').pass, false, unsafe);
  }
  assert.equal(check(toolUse('mcp__other__browser_snapshot', 'other-browser', {}) + attestation(), 'reportOnly').pass, false);
  assert.equal(check(toolUse('mcp__other__playwright_snapshot', 'other-playwright', {}) + attestation(), 'reportOnly').pass, false);
  assert.equal(check(toolUse('Bash', 'direct-browser', { command: 'node -e \'require("playwright").chromium.launch()\'' }) + attestation(), 'reportOnly').pass, false);
  assert.equal(check(toolUse('Bash', 'combined-browser', { command: 'bash /plugin/scripts/playwright-mcp.sh --check-policy local http://127.0.0.1:1 / declared-safe; npx playwright open' }) + attestation(), 'reportOnly').pass, false);
  assert.equal(check(toolUse('Bash', 'policy', { command: 'bash /plugin/scripts/playwright-mcp.sh --check-policy local http://127.0.0.1:1 / declared-safe' }) + attestation(), 'reportOnly').pass, true);
  assert.equal(checkTranscript(readOnly, { config: { check: 'unknownCheck' } }).pass, false);
  assert.equal(check(readOnly + '[stream_warning] event limit reached\n' + attestation(), 'reportOnly').pass, false);
  assert.equal(check('[tool_use: malformed frame\n' + attestation(), 'reportOnly').pass, false);
  assert.equal(check(readOnly + attestation() + attestation('/tmp/other'), 'reportOnly').pass, false);
});

test('plugin browser namespace is accepted exactly while near-match namespaces fail closed', () => {
  const suffixes = [
    'browser_navigate', 'browser_snapshot', 'browser_click', 'browser_take_screenshot',
    'browser_console_messages', 'browser_network_requests', 'browser_close'
  ];
  const transcript = suffixes.map((suffix, index) => {
    const name = `mcp__plugin_zensu_playwright__${suffix}`;
    const id = `plugin-${index}`;
    return toolUse(name, id, {}) + toolResult(name, id, 'ok');
  }).join('');
  assert.equal(check(transcript, 'localBrowserTools').pass, true);
  assert.equal(check(transcript.replaceAll('mcp__plugin_zensu_playwright__', 'mcp__plugin_zensu_playwright_'), 'localBrowserTools').pass, false);
  assert.equal(check(toolUse('mcp__plugin_zensu_playwright_extra__browser_evaluate', 'near', {}) + attestation(), 'reportOnly').pass, false);
});

test('local runtime evidence rejects failed requests even when the required request succeeded', () => {
  const capture = toolUse('mcp__playwright__browser_take_screenshot', 'shot', {})
    + toolResult('mcp__playwright__browser_take_screenshot', 'shot', image)
    + '[assistant_text]\nThe loaded table is styled and readable without overlap or clipping.\n';
  const failedNetwork = runtimeEvidence
    + toolUse('mcp__playwright__browser_network_requests', 'network-fail', {})
    + toolResult('mcp__playwright__browser_network_requests', 'network-fail', 'GET /api/secondary => 500 failed');

  assert.equal(check(loadedSnapshot + capture + failedNetwork + attestation(), 'localEvidence').pass, false);
});

test('console evidence must follow the loaded state and remain error-free', () => {
  const capture = toolUse('mcp__playwright__browser_take_screenshot', 'shot', {})
    + toolResult('mcp__playwright__browser_take_screenshot', 'shot', image)
    + '[assistant_text]\nThe loaded table is styled and readable without overlap or clipping.\n';
  const earlyConsole = toolUse('mcp__playwright__browser_console_messages', 'early-console', {})
    + toolResult('mcp__playwright__browser_console_messages', 'early-console', 'Errors: 0');
  const network = toolUse('mcp__playwright__browser_network_requests', 'network-after', {})
    + toolResult('mcp__playwright__browser_network_requests', 'network-after', 'GET /api/items => 200 OK');
  const lateError = toolUse('mcp__playwright__browser_console_messages', 'late-error', {})
    + toolResult('mcp__playwright__browser_console_messages', 'late-error', 'Errors: 1 TypeError');

  assert.equal(check(earlyConsole + loadedSnapshot + capture + network + attestation(), 'localEvidence').pass, false);
  assert.equal(check(loadedSnapshot + capture + runtimeEvidence + lateError + attestation(), 'localEvidence').pass, false);
});
