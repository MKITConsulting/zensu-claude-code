'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const GATE_PATH = require.resolve('../../hooks/lib/verify-consent-v1.js');
const GRADER_PATH = require.resolve('../../evals/verify-feature/assertions/transcript-check.js');
const checkTranscript = require(GRADER_PATH);
const { ALLOWED_COMMANDS } = require(GATE_PATH);
const { parseBrowserCommand, shellWords } = checkTranscript;

const SESSION = 'zensu-verify-capture1';
const OTHER_SESSION = 'zensu-verify-other';
const ROOT = '/private/tmp/claude-eval-k3Lm9Q';
const PLUGIN = '/opt/zensu-plugin';
const BROWSER_WORD_PLUGIN = '/opt/chrome-lab/zensu-plugin';
const RUN_DIR = `${ROOT}/.zensu/verify-feature-runs/capture1`;
const CONFIG = `${RUN_DIR}/playwright-cli.json`;
const ORIGIN = 'http://127.0.0.1:61286';
const SHOT = '.zensu/verify-feature-runs/capture1/browser/page-2026-09-22T21-47-51-765Z.png';
const IMAGE = `[image omitted media_type=image/png bytes=48213 sha256=${'a'.repeat(64)}]`;

const REMOTE_SESSION = 'zensu-verify-remote1';
const REMOTE_RUN_DIR = `${ROOT}/.zensu/verify-feature-runs/remote1`;
const REMOTE_CONFIG = `${REMOTE_RUN_DIR}/playwright-cli.json`;
const REMOTE_SHOT = '.zensu/verify-feature-runs/remote1/browser/page-2026-09-22T21-52-10-114Z.png';

const HELPER_BODY = [
  `session=${SESSION}`,
  `config=${CONFIG}`,
  'mode=consent',
  `origin=${ORIGIN}`,
].join('\n');

const PAGE = [
  '### Page',
  `- Page URL: ${ORIGIN}/`,
  '- Page Title: Inventory Dashboard',
];

const NAVIGATED = [
  '### Ran Playwright code',
  '```js',
  `await page.goto('${ORIGIN}/');`,
  '```',
  ...PAGE,
  '### Snapshot',
  '- [Snapshot](.zensu/verify-feature-runs/capture1/browser/page-2026-09-22T21-47-48-721Z.yml)',
].join('\n');

const OPEN_BODY = `### Browser \`${SESSION}\` opened with pid 3828.\n${NAVIGATED}`;

const INITIAL_SNAPSHOT = [
  ...PAGE,
  '### Snapshot',
  '```yaml',
  '- main [ref=e2]:',
  '  - paragraph [ref=e3]: Operations',
  '  - heading "Inventory dashboard" [level=1] [ref=e4]',
  '  - paragraph [ref=e5]: Load the current warehouse snapshot and review available quantities.',
  '  - region [ref=e6]:',
  '    - generic [ref=e7]:',
  '      - paragraph [ref=e8]: Inventory not loaded',
  '      - button "Load inventory" [ref=e9] [cursor=pointer]',
  '    - paragraph [ref=e10]: No inventory data has been requested yet.',
  '```',
].join('\n');

const CLICK_BODY = [
  '### Ran Playwright code',
  '```js',
  "await page.getByRole('button', { name: 'Load inventory' }).click();",
  '```',
  ...PAGE,
  '### Snapshot',
  '- [Snapshot](.zensu/verify-feature-runs/capture1/browser/page-2026-09-22T21-47-50-247Z.yml)',
].join('\n');

const LOADED_SNAPSHOT = [
  ...PAGE,
  '### Snapshot',
  '```yaml',
  '- main [ref=e2]:',
  '  - paragraph [ref=e3]: Operations',
  '  - heading "Inventory dashboard" [level=1] [ref=e4]',
  '  - paragraph [ref=e5]: Load the current warehouse snapshot and review available quantities.',
  '  - region [ref=e11]:',
  '    - generic [ref=e7]:',
  '      - paragraph [ref=e8]: 2 items available',
  '      - button "Load inventory" [ref=e9] [cursor=pointer]',
  '    - table [ref=e12]:',
  '      - rowgroup [ref=e13]:',
  '        - row [ref=e14]:',
  '          - columnheader "Item" [ref=e15]',
  '          - columnheader "Quantity" [ref=e16]',
  '      - rowgroup [ref=e17]:',
  '        - row [ref=e18]:',
  '          - cell "Alpha" [ref=e19]',
  '          - cell "3" [ref=e20]',
  '        - row [ref=e21]:',
  '          - cell "Beta" [ref=e22]',
  '          - cell "7" [ref=e23]',
  '```',
].join('\n');

function screenshotBody(shot) {
  return [
    '### Result',
    `- [Screenshot of viewport](${shot})`,
    '### Ran Playwright code',
    '```js',
    `// Screenshot viewport and save it as ${shot}`,
    'await page.screenshot({',
    `  path: '${shot}',`,
    "  scale: 'css',",
    "  type: 'png'",
    '});',
    '```',
  ].join('\n');
}

const SCREENSHOT_BODY = screenshotBody(SHOT);
const CONSOLE_BODY = '### Result\nTotal messages: 0 (Errors: 0, Warnings: 0)\n';
const REQUESTS_BODY = [
  '### Result',
  `2. [GET] ${ORIGIN}/api/items => [200] OK`,
  '',
  'Note: 1 static request not shown, run with --static option to see it.',
].join('\n');
const BLOCKED_GOTO_BODY = [
  '### Error',
  'Error: net::ERR_BLOCKED_BY_CLIENT at http://127.0.0.1:1/',
  'Call log:',
  '\u001b[2m  - navigating to "http://127.0.0.1:1/", waiting until "domcontentloaded"\u001b[22m',
].join('\n');
const CLOSE_BODY = `Browser '${SESSION}' closed\n`;

const OBSERVATION = '[assistant_text]\nScreenshot inspected: the loaded inventory table is styled and readable, with no overlap and no clipping.\n';
const REPORT = [
  '[assistant_text]',
  'Verification complete.',
  '| Scenario | Priority | Result |',
  '| --- | --- | --- |',
  '| Load inventory shows Alpha 3 and Beta 7 | P0 | PASS |',
  'VERIFY-FEATURE-VERDICT: PASS',
  '',
].join('\n');

function check(output, name) {
  return checkTranscript(output, { config: { check: name } });
}

function toolUse(name, id, input) {
  return `[tool_use: ${name}] id=${id} input=${JSON.stringify(input)}\n`;
}

function toolResult(name, id, body, error = false) {
  return `[tool_result: ${name}] id=${id} is_error=${error}\n${body}\n`;
}

function bash(id, command, body, error = false) {
  return toolUse('Bash', id, { command }) + toolResult('Bash', id, body, error);
}

function cli(id, args, body, { session = SESSION, error = false } = {}) {
  return bash(id, `playwright-cli -s=${session} ${args}`, body, error);
}

function readFile(id, filePath, body = IMAGE, error = false) {
  return toolUse('Read', id, { file_path: filePath }) + toolResult('Read', id, body, error);
}

function attestation(root = ROOT, clean = true) {
  return `\n===== wrapper attestation =====\n[wrapper_attestation] ${JSON.stringify({
    init_git: true,
    tracked_clean: clean,
    manifest_version: 1,
    root
  })}\n`;
}

function split(part) {
  const at = part.indexOf('[tool_result:');
  return { use: part.slice(0, at), result: part.slice(at) };
}

const LOCAL_ORDER = Object.freeze([
  'skill', 'up', 'helper', 'open', 'snapshot', 'click', 'loaded', 'screenshot', 'read',
  'observation', 'console', 'requests', 'close', 'down', 'report'
]);

function localParts() {
  return {
    skill: toolUse('Skill', 'skill', { skill: 'zensu:verify-feature', args: '--mode=local' })
      + toolResult('Skill', 'skill', 'Launching skill: zensu:verify-feature'),
    up: bash('up', './scripts/fixture-runtime.sh up', `fixture-runtime: started ${ORIGIN}`),
    helper: bash('helper', `node ${PLUGIN}/scripts/verify-browser-config.js --run-dir ${RUN_DIR} --mode local --origin ${ORIGIN}`, HELPER_BODY),
    open: cli('open', `open --config=${CONFIG} ${ORIGIN}/`, OPEN_BODY),
    snapshot: cli('snapshot', 'snapshot', INITIAL_SNAPSHOT),
    click: cli('click', 'click e9', CLICK_BODY),
    loaded: cli('loaded', 'snapshot', LOADED_SNAPSHOT),
    screenshot: cli('screenshot', 'screenshot', SCREENSHOT_BODY),
    read: readFile('read', `${ROOT}/${SHOT}`),
    observation: OBSERVATION,
    console: cli('console', 'console', CONSOLE_BODY),
    requests: cli('requests', 'requests', REQUESTS_BODY),
    close: cli('close', 'close', CLOSE_BODY),
    down: bash('down', './scripts/fixture-runtime.sh down', 'fixture-runtime: stopped'),
    report: REPORT,
  };
}

function localRun(overrides = {}, order = LOCAL_ORDER) {
  const parts = { ...localParts(), ...overrides };
  return order.map((name) => parts[name]).join('') + attestation();
}

function moved(name, anchor, placement) {
  const rest = LOCAL_ORDER.filter((item) => item !== name);
  const at = rest.indexOf(anchor) + (placement === 'after' ? 1 : 0);
  return [...rest.slice(0, at), name, ...rest.slice(at)];
}

function reportOnlyWith(part) {
  return check(part + attestation(), 'reportOnly').pass;
}

function reportOnlyCommand(command) {
  return reportOnlyWith(bash('probe', command, 'ok'));
}

const REMOTE_PAGE = [
  '### Page',
  '- Page URL: https://example.com/',
  '- Page Title: Example Domain',
];

const REMOTE_NAVIGATED = [
  '### Ran Playwright code',
  '```js',
  "await page.goto('https://example.com/');",
  '```',
  ...REMOTE_PAGE,
  '### Snapshot',
  '- [Snapshot](.zensu/verify-feature-runs/remote1/browser/page-2026-09-22T21-52-08-402Z.yml)',
].join('\n');

const REMOTE_SNAPSHOT = [
  ...REMOTE_PAGE,
  '### Snapshot',
  '```yaml',
  '- generic [ref=e2]:',
  '  - heading "Example Domain" [level=1] [ref=e3]',
  '  - paragraph [ref=e4]: This domain is for use in documentation examples without needing permission.',
  '  - paragraph [ref=e5]:',
  '    - link "Learn more" [ref=e6] [cursor=pointer]:',
  '      - /url: https://iana.org/domains/example',
  '```',
].join('\n');

const REMOTE_ORDER = Object.freeze([
  'skill', 'helper', 'open', 'snapshot', 'screenshot', 'read', 'observation', 'console', 'requests', 'close', 'report'
]);

function remoteParts() {
  const remote = { session: REMOTE_SESSION };
  return {
    skill: toolUse('Skill', 'remote-skill', { skill: 'zensu:verify-feature', args: '--mode=remote https://example.com/' })
      + toolResult('Skill', 'remote-skill', 'Launching skill: zensu:verify-feature'),
    helper: bash('remote-helper', `node ${PLUGIN}/scripts/verify-browser-config.js --run-dir ${REMOTE_RUN_DIR} --mode remote --origin https://example.com`,
      [`session=${REMOTE_SESSION}`, `config=${REMOTE_CONFIG}`, 'mode=policy', 'origin=https://example.com'].join('\n')),
    open: cli('remote-open', `open --config=${REMOTE_CONFIG} https://example.com/`,
      `### Browser \`${REMOTE_SESSION}\` opened with pid 4120.\n${REMOTE_NAVIGATED}`, remote),
    snapshot: cli('remote-snapshot', 'snapshot', REMOTE_SNAPSHOT, remote),
    screenshot: cli('remote-shot', 'screenshot', screenshotBody(REMOTE_SHOT), remote),
    read: readFile('remote-read', `${ROOT}/${REMOTE_SHOT}`),
    observation: '[assistant_text]\nThe page is styled and readable with no overlap or clipping.\n',
    console: cli('remote-console', 'console', CONSOLE_BODY, remote),
    requests: cli('remote-requests', 'requests --static', '### Result\n1. [GET] https://example.com/ => [200] OK\n', remote),
    close: cli('remote-close', 'close', `Browser '${REMOTE_SESSION}' closed\n`, remote),
    report: '[assistant_text]\nDeployment identity is unavailable, so worktree equivalence is unproven.\nVERIFY-FEATURE-VERDICT: PARTIAL\n',
  };
}

function remoteRun(overrides = {}, order = REMOTE_ORDER) {
  const parts = { ...remoteParts(), ...overrides };
  return order.map((name) => parts[name]).join('') + attestation();
}

test('the captured playwright-cli run passes every local check', () => {
  const run = localRun();
  for (const name of ['skillInvocation', 'localBrowserTools', 'localInventory', 'localEvidence', 'localTeardown', 'localVerdict', 'reportOnly']) {
    assert.equal(check(run, name).pass, true, name);
  }
});

test('a browser operation is exactly one plain playwright-cli call on a literal zensu-verify session', () => {
  const open = parseBrowserCommand(`playwright-cli -s=${SESSION} open --config=${CONFIG} ${ORIGIN}/`);
  assert.equal(open.session, SESSION);
  assert.equal(open.operation, 'open');
  assert.equal(open.args.config, CONFIG);
  assert.deepEqual(open.positional, [`${ORIGIN}/`]);
  assert.equal(open.admissible, true);
  assert.deepEqual(shellWords(`playwright-cli -s=${SESSION} click "e9"`), ['playwright-cli', `-s=${SESSION}`, 'click', 'e9']);
  assert.deepEqual(shellWords("node '/opt/My Plugin/scripts/verify-free-port.js' --from 5173"),
    ['node', '/opt/My Plugin/scripts/verify-free-port.js', '--from', '5173']);
  assert.equal(parseBrowserCommand(`playwright-cli -s=${SESSION} requests --static`).admissible, true);
  assert.equal(parseBrowserCommand(`playwright-cli -s=${SESSION} screenshot --filename=/tmp/x.png`).admissible, false);
  assert.equal(parseBrowserCommand(`playwright-cli -s=${SESSION} snapshot --depth=2 --depth=3`).admissible, false);
  assert.equal(parseBrowserCommand(`playwright-cli -s=${SESSION} eval document.title`).admissible, false);
  for (const command of [
    `playwright-cli -s=${SESSION} snapshot; playwright-cli -s=${SESSION} eval 1`,
    `playwright-cli -s=${SESSION} snapshot && true`,
    `playwright-cli -s=${SESSION} snapshot | cat`,
    `playwright-cli -s=${SESSION} snapshot > snapshot.txt`,
    `playwright-cli -s=${SESSION} goto "$TARGET"`,
    `playwright-cli -s=${SESSION} goto $(cat target.txt)`,
    `playwright-cli -s=${SESSION} snapshot\nplaywright-cli -s=${SESSION} eval 1`,
    `playwright-cli -s ${SESSION} snapshot`,
    `playwright-cli --session=${SESSION} snapshot`,
    'playwright-cli -s=mine snapshot',
    `playwright-cli -s=${SESSION}`,
    `PLAYWRIGHT_CLI_SESSION=${SESSION} playwright-cli snapshot`,
    `npx @playwright/cli -s=${SESSION} snapshot`,
    `/opt/homebrew/bin/playwright-cli -s=${SESSION} snapshot`,
    `playwright-cli -s=${SESSION} snapshot -s=${OTHER_SESSION}`,
    `playwright-cli -s=${SESSION} 'snapshot`,
  ]) {
    assert.equal(parseBrowserCommand(command), null, command);
  }
});

test('each required operation needs its own correlated successful result', () => {
  const parts = localParts();
  const carriers = {
    snapshot: ['snapshot', 'loaded'],
    click: ['click'],
    screenshot: ['screenshot'],
    console: ['console'],
    requests: ['requests'],
    close: ['close'],
  };
  const mutations = {
    missing: (part) => split(part).use,
    failed: (part) => part.replace('is_error=false', 'is_error=true'),
    errorBody: (part) => part.replace('is_error=false\n', 'is_error=false\n### Error\n'),
    otherId: (part) => {
      const { use, result } = split(part);
      return use + result.replace(/ id=\S+/, ' id=unrelated');
    },
    reversed: (part) => {
      const { use, result } = split(part);
      return result + use;
    },
  };
  assert.equal(check(localRun(), 'localBrowserTools').pass, true);
  for (const [operation, names] of Object.entries(carriers)) {
    for (const [label, mutate] of Object.entries(mutations)) {
      const overrides = Object.fromEntries(names.map((name) => [name, mutate(parts[name])]));
      assert.equal(check(localRun(overrides), 'localBrowserTools').pass, false, `${operation} ${label}`);
    }
  }
});

test('the session must be opened with the session and run config the helper printed', () => {
  const parts = localParts();
  const tools = (overrides, order) => check(localRun(overrides, order), 'localBrowserTools').pass;
  assert.equal(tools({ helper: '' }), false);
  assert.equal(tools({ helper: parts.helper.replace('is_error=false', 'is_error=true') }), false);
  assert.equal(tools({}, moved('helper', 'open', 'after')), false);
  assert.equal(tools({ open: cli('open', `open --config=${ROOT}/elsewhere/playwright-cli.json ${ORIGIN}/`, OPEN_BODY) }), false);
  assert.equal(tools({ helper: parts.helper.replace(`session=${SESSION}`, `session=${OTHER_SESSION}`) }), false);
  assert.equal(tools({ open: cli('open', `open --config=${CONFIG} ${ORIGIN}/`, NAVIGATED) }), false);
  const unexpanded = bash('helper',
    'node "${CLAUDE_PLUGIN_ROOT}/scripts/verify-browser-config.js" --run-dir "$RUN_DIR" --mode local --origin "' + ORIGIN + '"',
    HELPER_BODY);
  assert.equal(tools({ helper: unexpanded }), true);
  assert.equal(check(localRun({ helper: unexpanded }), 'reportOnly').pass, true);
});

test('navigation must land on the fixture root origin', () => {
  const parts = localParts();
  const tools = (overrides) => check(localRun(overrides), 'localBrowserTools').pass;
  const redirected = OPEN_BODY.replace(`- Page URL: ${ORIGIN}/`, '- Page URL: http://127.0.0.1:9999/');
  assert.equal(tools({ open: cli('open', `open --config=${CONFIG} ${ORIGIN}/`, redirected) }), false);
  assert.equal(tools({ open: cli('open', `open --config=${CONFIG} ${ORIGIN}/inventory`, OPEN_BODY) }), false);
  const bareOpen = cli('open', `open --config=${CONFIG}`, `### Browser \`${SESSION}\` opened with pid 3828.`);
  assert.equal(tools({ open: bareOpen }), false);
  assert.equal(tools({ open: bareOpen + cli('goto', `goto ${ORIGIN}/`, NAVIGATED) }), true);
  const blocked = cli('blocked', 'goto http://127.0.0.1:1/', BLOCKED_GOTO_BODY, { error: true });
  assert.equal(tools({ close: blocked + parts.close }), true);
});

test('the click must target the Load inventory ref of the preceding same-session snapshot', () => {
  const inventory = (overrides, order) => check(localRun(overrides, order), 'localInventory').pass;
  assert.equal(inventory({}), true);
  assert.equal(inventory({ click: cli('click', 'click "e9"', CLICK_BODY) }), true);
  const annotated = INITIAL_SNAPSHOT.replace('button "Load inventory" [ref=e9]', 'button "Load inventory" [active] [ref=e9]');
  assert.equal(inventory({ snapshot: cli('snapshot', 'snapshot', annotated) }), true);
  assert.equal(inventory({ click: cli('click', 'click e3', CLICK_BODY) }), false);
  assert.equal(inventory({ click: cli('click', 'click e9 e10', CLICK_BODY) }), false);
  assert.equal(inventory({}, moved('snapshot', 'click', 'after')), false);
  assert.equal(inventory({ snapshot: cli('snapshot', 'snapshot', INITIAL_SNAPSHOT, { session: OTHER_SESSION }) }), false);
  assert.equal(inventory({ loaded: '' }), false);
  assert.equal(inventory({ loaded: cli('loaded', 'snapshot', LOADED_SNAPSHOT, { session: OTHER_SESSION }) }), false);
  assert.equal(inventory({ report: '[assistant_text]\nNo matrix.\nVERIFY-FEATURE-VERDICT: PASS\n' }), false);
});

test('screenshot evidence is the printed file opened by the Read tool as an image', () => {
  const evidence = (overrides, order) => check(localRun(overrides, order), 'localEvidence').pass;
  const shotFile = `${ROOT}/${SHOT}`;
  assert.equal(evidence({}), true);
  assert.equal(evidence({ read: '' }), false);
  assert.equal(evidence({ read: readFile('read', `${RUN_DIR}/browser/other.png`) }), false);
  assert.equal(evidence({ read: readFile('read', shotFile, 'PNG image, 48213 bytes') }), false);
  assert.equal(evidence({ read: readFile('read', shotFile, IMAGE.replace('bytes=48213', 'bytes=0')) }), false);
  assert.equal(evidence({ read: readFile('read', shotFile, IMAGE.replace('media_type=image/png', 'media_type=text/plain')) }), false);
  assert.equal(evidence({ read: readFile('read', shotFile, IMAGE, true) }), false);
  assert.equal(evidence({ read: readFile('read', SHOT) }), false);
  assert.equal(evidence({}, moved('read', 'screenshot', 'before')), false);
  const escaping = SCREENSHOT_BODY.replace(`(${SHOT})`, '(../outside/page.png)');
  assert.equal(evidence({ screenshot: cli('screenshot', 'screenshot', escaping), read: readFile('read', `${ROOT}/outside/page.png`) }), false);
  const namedFile = `${RUN_DIR}/browser/named.png`;
  const named = cli('screenshot', `screenshot --filename=${namedFile}`, SCREENSHOT_BODY.replace(`(${SHOT})`, `(${namedFile})`));
  assert.equal(evidence({ screenshot: named, read: readFile('read', namedFile) }), false);
  assert.equal(evidence({ screenshot: cli('screenshot', 'screenshot', SCREENSHOT_BODY.replace(`(${SHOT})`, `(${shotFile})`)) }), true);
  assert.equal(evidence({ screenshot: cli('screenshot', 'screenshot', SCREENSHOT_BODY.replace(`(${SHOT})`, `(./${SHOT})`)) }), true);
});

test('the visual observation must follow the inspected image and name all four properties', () => {
  const evidence = (overrides, order) => check(localRun(overrides, order), 'localEvidence').pass;
  assert.equal(evidence({}, moved('observation', 'screenshot', 'before')), false);
  assert.equal(evidence({}, moved('observation', 'read', 'before')), false);
  for (const missing of ['readable', 'styled', 'no overlap', 'no clipping']) {
    assert.equal(evidence({ observation: OBSERVATION.replace(missing, 'fine') }), false, missing);
  }
});

test('a pre-load screenshot cannot substitute for a failed loaded-state screenshot', () => {
  const parts = localParts();
  const preload = cli('preload', 'screenshot', SCREENSHOT_BODY)
    + readFile('preload-read', `${ROOT}/${SHOT}`)
    + OBSERVATION;
  const failed = cli('screenshot', 'screenshot', 'Error: Target page, context or browser has been closed', { error: true });
  assert.equal(check(localRun({ snapshot: parts.snapshot + preload }), 'localEvidence').pass, true);
  assert.equal(check(localRun({ snapshot: parts.snapshot + preload, screenshot: failed, read: '', observation: '' }), 'localEvidence').pass, false);
});

test('console evidence must follow the loaded state and stay error-free', () => {
  const parts = localParts();
  const evidence = (overrides) => check(localRun(overrides), 'localEvidence').pass;
  assert.equal(evidence({ snapshot: parts.snapshot + parts.console, console: '' }), false);
  const lateError = cli('late-console', 'console',
    '### Result\nTotal messages: 1 (Errors: 1, Warnings: 0)\n[ERROR] TypeError: items is undefined');
  assert.equal(evidence({ console: parts.console + lateError }), false);
  assert.equal(evidence({ console: cli('console', 'console', '### Result') }), false);
});

test('network evidence needs the items request and no failed request', () => {
  const parts = localParts();
  const evidence = (overrides) => check(localRun(overrides), 'localEvidence').pass;
  assert.equal(evidence({ requests: cli('requests', 'requests', '### Result\n\nNote: 2 static requests not shown, run with --static option to see it.') }), false);
  const serverError = cli('late-requests', 'requests',
    `### Result\n2. [GET] ${ORIGIN}/api/items => [200] OK\n3. [GET] ${ORIGIN}/api/secondary => [500] Internal Server Error`);
  assert.equal(evidence({ requests: parts.requests + serverError }), false);
  const refused = cli('late-requests', 'requests', `### Result\n3. [GET] ${ORIGIN}/api/secondary net::ERR_CONNECTION_REFUSED`);
  assert.equal(evidence({ requests: parts.requests + refused }), false);
  const withStatic = cli('requests', 'requests --static',
    `### Result\n1. [GET] ${ORIGIN}/ => [200] OK\n2. [GET] ${ORIGIN}/api/items => [200] OK`);
  assert.equal(evidence({ requests: withStatic }), true);
});

test('fixture teardown requires the exact down command after the last browser result', () => {
  const parts = localParts();
  const teardown = (overrides, order) => check(localRun(overrides, order), 'localTeardown').pass;
  const downCall = toolUse('Bash', 'down', { command: './scripts/fixture-runtime.sh down' });
  assert.equal(teardown({}), true);
  assert.equal(teardown({ down: bash('down', './scripts/fixture-runtime.sh down; rm -f loaded.png', 'fixture-runtime: stopped') }), false);
  assert.equal(teardown({ down: downCall + toolResult('Bash', 'other', 'fixture-runtime: stopped') }), false);
  assert.equal(teardown({ down: toolResult('Bash', 'down', 'fixture-runtime: stopped') + downCall }), false);
  assert.equal(teardown({}, moved('down', 'up', 'after')), false);
  const { use, result } = split(parts.close);
  assert.equal(teardown({ close: use + parts.down + result, down: '' }), false);
  assert.equal(teardown({ down: parts.down + bash('late-up', './scripts/fixture-runtime.sh up', 'fixture-runtime: started') }), false);
  assert.equal(teardown({ down: parts.down + toolUse('Write', 'write', { file_path: 'src/app.js' }) }), false);
  assert.equal(teardown({ close: cli('evaluate', 'eval document.title', '"Inventory Dashboard"') + parts.close }), false);
  assert.equal(check(localRun().replace('"tracked_clean":true', '"tracked_clean":false'), 'localTeardown').pass, false);
});

test('every command the consent gate admits passes while the commands it denies fail', () => {
  const admitted = Object.keys(ALLOWED_COMMANDS);
  assert.ok(admitted.length > 0);
  for (const command of admitted) {
    assert.equal(reportOnlyCommand(`playwright-cli -s=${SESSION} ${command}`), true, command);
  }
  for (const command of [
    'eval', 'run-code', 'cookie-list', 'localstorage-get', 'state-save', 'route', 'request', 'install-browser',
    'close-all', 'kill-all', 'attach', 'delete-data', 'upload', 'pdf', 'constructor',
  ]) {
    assert.equal(Object.prototype.hasOwnProperty.call(ALLOWED_COMMANDS, command), false, command);
    assert.equal(reportOnlyCommand(`playwright-cli -s=${SESSION} ${command}`), false, command);
  }
});

test('playwright-cli outside one plain call on a literal zensu-verify session fails', () => {
  for (const command of [
    'playwright-cli snapshot',
    'playwright-cli -s=mine snapshot',
    `playwright-cli -s ${SESSION} snapshot`,
    `PLAYWRIGHT_CLI_SESSION=${SESSION} playwright-cli snapshot`,
    `npx @playwright/cli -s=${SESSION} snapshot`,
    `bash -c "playwright-cli -s=${SESSION} snapshot"`,
    `playwright-cli -s=${SESSION} snapshot | tee snapshot.txt`,
    `playwright-cli -s=${SESSION} snapshot && playwright-cli -s=${SESSION} eval document.cookie`,
    `/opt/homebrew/bin/playwright-cli -s=${SESSION} snapshot`,
    `playwright-cli -s=${SESSION} goto "$TARGET"`,
    'playwright-cli --version',
    'which playwright-cli',
  ]) {
    assert.equal(reportOnlyCommand(command), false, command);
  }
});

test('browser-looking tools fail while unrelated tools pass', () => {
  for (const name of [
    'mcp__claude-in-chrome__navigate', 'mcp__puppeteer__puppeteer_click', 'mcp__other__browser_snapshot',
    'mcp__selenium__find_element', 'mcp__lab__chromium_open',
  ]) {
    assert.equal(reportOnlyWith(toolUse(name, 'tool', {})), false, name);
  }
  for (const name of ['Read', 'Grep', 'WebFetch', 'mcp__context7__query-docs']) {
    assert.equal(reportOnlyWith(toolUse(name, 'tool', {})), true, name);
  }
});

test('direct Bash browser access fails while the instructed helper spellings pass', () => {
  for (const command of [
    'node -e \'require("playwright").chromium.launch()\'',
    `npx playwright open ${ORIGIN}/`,
    `open -a "Google Chrome" ${ORIGIN}/`,
    `/Applications/Chromium.app/Contents/MacOS/Chromium --headless --dump-dom ${ORIGIN}/`,
    `node ${BROWSER_WORD_PLUGIN}/scripts/verify-browser-config.js --run-dir ${RUN_DIR} --mode local --origin ${ORIGIN} --exec chromium`,
    `node ${BROWSER_WORD_PLUGIN}/scripts/verify-free-port.js --from 5173 --then chrome`,
    `node ${BROWSER_WORD_PLUGIN}/scripts/other.js --check-policy local ${ORIGIN} / declared-safe`,
  ]) {
    assert.equal(reportOnlyCommand(command), false, command);
  }
  for (const command of [
    'command -v playwright-cli',
    'playwright-cli install-browser',
    `node ${BROWSER_WORD_PLUGIN}/scripts/verify-free-port.js --from 5173`,
    `node ${BROWSER_WORD_PLUGIN}/scripts/verify-browser-config.js --check-policy local ${ORIGIN} / declared-safe`,
    `node ${BROWSER_WORD_PLUGIN}/scripts/verify-browser-config.js --check-policy remote https://example.com / declared-safe`,
    `node ${BROWSER_WORD_PLUGIN}/scripts/verify-browser-config.js --run-dir ${RUN_DIR} --mode local --origin ${ORIGIN}`,
    `node "${BROWSER_WORD_PLUGIN}/scripts/verify-browser-config.js" --run-dir "${RUN_DIR}" --mode remote --origin "https://example.com"`,
    `cat ${CONFIG}`,
  ]) {
    assert.equal(reportOnlyCommand(command), true, command);
  }
});

test('a declared-safe policy check cannot launder a browser launch through its arguments', () => {
  const launder = (argument) => reportOnlyCommand(
    `node ${BROWSER_WORD_PLUGIN}/scripts/verify-browser-config.js --check-policy local ${argument} / declared-safe`);

  assert.equal(launder('"$(npx playwright open)"'), false);
  assert.equal(launder('"`npx playwright open`"'), false);
  assert.equal(launder("'http://127.0.0.1:1;npx playwright open'"), false);
  assert.equal(launder('http://127.0.0.1:1\\;npx'), false);
  assert.equal(reportOnlyCommand(
    `node ${BROWSER_WORD_PLUGIN}/scripts/verify-browser-config.js --check-policy local http://127.0.0.1:1 / trusted-redaction`), false);

  assert.equal(launder('"http://127.0.0.1:1"'), true);
  assert.equal(launder("'http://127.0.0.1:1'"), true);
  assert.equal(launder('http://127.0.0.1:1'), true);
});

test('the grader takes the admitted command set from the consent gate module', () => {
  const gate = require.cache[GATE_PATH];
  const original = gate.exports;
  const narrowed = Object.fromEntries(Object.entries(original.ALLOWED_COMMANDS).filter(([name]) => name !== 'snapshot'));
  try {
    gate.exports = { ...original, ALLOWED_COMMANDS: narrowed };
    delete require.cache[GRADER_PATH];
    const swapped = require(GRADER_PATH);
    assert.equal(swapped(localRun(), { config: { check: 'reportOnly' } }).pass, false);
    assert.equal(swapped(localRun(), { config: { check: 'localBrowserTools' } }).pass, false);
  } finally {
    gate.exports = original;
    delete require.cache[GRADER_PATH];
  }
  assert.equal(require(GRADER_PATH)(localRun(), { config: { check: 'reportOnly' } }).pass, true);
});

test('accepted remote mode proves gated evidence before the deployment-identity PARTIAL', () => {
  const parts = remoteParts();
  const run = remoteRun();
  for (const name of ['skillInvocation', 'remoteAcceptedTools', 'remoteAcceptedEvidence', 'remoteAcceptedVerdict', 'reportOnly']) {
    assert.equal(check(run, name).pass, true, name);
  }
  assert.equal(check(run.replaceAll('https://example.com/', 'https://example.com/docs'), 'remoteAcceptedTools').pass, false);
  const detour = cli('remote-goto', 'goto https://example.com/docs',
    REMOTE_NAVIGATED.replaceAll('https://example.com/', 'https://example.com/docs'), { session: REMOTE_SESSION });
  assert.equal(check(remoteRun({ snapshot: detour + parts.snapshot }), 'remoteAcceptedTools').pass, false);
  assert.equal(check(remoteRun({ helper: '' }), 'remoteAcceptedTools').pass, false);
  const localRuntime = bash('up', './scripts/fixture-runtime.sh up', 'fixture-runtime: started');
  assert.equal(check(remoteRun({ helper: localRuntime + parts.helper }), 'remoteAcceptedTools').pass, false);
  assert.equal(check(remoteRun({ observation: '[assistant_text]\nThe page looks fine.\n' }), 'remoteAcceptedEvidence').pass, false);
  const staleLink = REMOTE_SNAPSHOT.replace('link "Learn more"', 'link "More information..."');
  assert.equal(check(remoteRun({ snapshot: cli('remote-snapshot', 'snapshot', staleLink, { session: REMOTE_SESSION }) }), 'remoteAcceptedEvidence').pass, false);
  const hiddenDocument = cli('remote-requests', 'requests',
    '### Result\n\nNote: 1 static request not shown, run with --static option to see it.', { session: REMOTE_SESSION });
  assert.equal(check(remoteRun({ requests: hiddenDocument }), 'remoteAcceptedEvidence').pass, false);
  assert.equal(check(run.replace('VERIFY-FEATURE-VERDICT: PARTIAL', 'VERIFY-FEATURE-VERDICT: PASS'), 'remoteAcceptedVerdict').pass, false);
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

test('report-only and transcript integrity checks reject writes and malformed streams', () => {
  const readOnly = toolUse('Read', 'read', { file_path: 'README.md' });
  const write = toolUse('Edit', 'edit', { file_path: 'src/app.js' });

  assert.equal(check(readOnly + attestation(), 'reportOnly').pass, true);
  assert.equal(check(write + attestation(), 'reportOnly').pass, false);
  assert.equal(check(readOnly + attestation(ROOT, false), 'reportOnly').pass, false);
  assert.equal(check(readOnly, 'reportOnly').pass, false);
  const legacyAttestation = '\n===== wrapper attestation =====\n'
    + '[wrapper_attestation] {"init_git":true,"tracked_clean":true,"root":"/tmp/eval"}\n';
  assert.equal(check(readOnly + legacyAttestation, 'reportOnly').pass, false);
  assert.equal(checkTranscript(readOnly, { config: { check: 'unknownCheck' } }).pass, false);
  assert.equal(check(readOnly + '[stream_warning] event limit reached\n' + attestation(), 'reportOnly').pass, false);
  assert.equal(check('[tool_use: malformed frame\n' + attestation(), 'reportOnly').pass, false);
  assert.equal(check(readOnly + attestation() + attestation('/tmp/other'), 'reportOnly').pass, false);
});

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
