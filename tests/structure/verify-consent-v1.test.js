'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const consent = require('../../hooks/lib/verify-consent-v1.js');
const cliVersion = require('../../hooks/lib/playwright-cli-version-v1.js');
const floor = require('../../hooks/lib/verify-navigation-floor-v1.js');
const { buildConfig } = require('../../scripts/verify-browser-config.js');

const { REASONS } = consent;
const { FLOOR_REASONS } = floor;
const REPO_ROOT = path.resolve(__dirname, '../..');
const MODULE = path.join(REPO_ROOT, 'hooks', 'lib', 'verify-consent-v1.js');
const KEY = `scv1_${'a'.repeat(64)}`;
const SESSION = 'zensu-verify-run1';
const AT = '2026-09-22T12:00:00.000Z';
const MAIN = Object.freeze({});
const SUBAGENT = Object.freeze({ agent_id: 'agent-1', agent_type: 'general-purpose' });
const LOCAL_TARGET = Object.freeze({ origin: 'http://127.0.0.1:4300', routes: ['/', '/login'], evidenceMode: 'declared-safe' });
const DENIED = 'Zensu browser consent gate denied the playwright-cli call: ';

function tempDir(t, prefix = 'zensu-consent-') {
  const dir = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function project(t) {
  const root = tempDir(t);
  fs.mkdirSync(path.join(root, '.zensu', 'state'), { recursive: true });
  return { root, memory: path.join(root, '.zensu', 'state', `verify-consent-${KEY}.json`) };
}

function record(origin, route = '/', decidedBy = 'asked', at = AT) {
  return { origin, route, decidedBy, at };
}

function cli(rest) {
  return `playwright-cli -s=${SESSION} ${rest}`;
}

function decide(command, options = {}) {
  return consent.evaluate({
    command,
    payload: options.payload || MAIN,
    env: options.env || {},
    records: options.records || [],
    declaredRoutes: options.declaredRoutes || [],
    policy: options.policy || null,
    platform: options.platform,
  });
}

function denied(command, options) {
  const decision = decide(command, options);
  assert.equal(decision.verdict, 'deny', command);
  return decision.reason;
}

function policyOf(mode, targets) {
  return consent.readPolicy({ ZENSU_VERIFY_NAVIGATION_POLICY_V1: JSON.stringify({ version: 1, mode, targets }) });
}

function runConfig(t, origins, rules = []) {
  const runDir = tempDir(t, 'zensu-run-');
  const config = buildConfig(runDir, origins, rules);
  const file = path.join(runDir, consent.RUN_CONFIG_NAME);
  fs.writeFileSync(file, `${JSON.stringify(config, null, 2)}\n`);
  return { runDir, file, config };
}

function isolatedEnv(t) {
  return { PWTEST_CLI_GLOBAL_CONFIG: tempDir(t, 'zensu-home-') };
}

function writeGlobal(env, value) {
  const file = consent.globalConfigFile(env);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, typeof value === 'string' ? value : JSON.stringify(value));
  return file;
}

function openCommand(file, rest = '') {
  return cli(`open --config='${file}'${rest ? ` ${rest}` : ''}`);
}

function bash(command, extra = {}) {
  return { hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command }, session_id: 'unit', cwd: REPO_ROOT, ...extra };
}

function post(command, extra = {}) {
  return bash(command, { hook_event_name: 'PostToolUse', tool_response: { stdout: '', stderr: '', interrupted: false }, ...extra });
}

function sink() {
  const chunks = [];
  return {
    write: (chunk) => { chunks.push(String(chunk)); return true; },
    text: () => chunks.join(''),
  };
}

function runCli(mode, input, env = {}) {
  return spawnSync(process.execPath, mode ? [MODULE, mode] : [MODULE], {
    input,
    encoding: 'utf8',
    env: { PATH: process.env.PATH, ...env },
  });
}

function words(lexed) {
  return lexed.segments.map((segment) => segment.map((word) => word.value));
}

test('the gate rides the Bash matcher and names two hook files that exist', () => {
  assert.equal(consent.CONSENT_MATCHER, 'Bash');
  assert.equal(consent.CONSENT_HOOK_FILE, 'pre-browser-navigation-consent.sh');
  assert.equal(consent.CONSENT_RECORDER_FILE, 'post-browser-navigation-consent.sh');
  for (const file of [consent.CONSENT_HOOK_FILE, consent.CONSENT_RECORDER_FILE]) {
    assert.equal(fs.lstatSync(path.join(REPO_ROOT, 'hooks', file)).isFile(), true, file);
  }
  assert.equal(consent.SESSION_PREFIX, 'zensu-verify-');
  assert.equal(consent.SESSION_ENV, 'PLAYWRIGHT_CLI_SESSION');
  assert.equal(consent.CLI_PACKAGE, '@playwright/cli');
  assert.deepEqual([...consent.CLI_BASENAMES], ['playwright-cli', 'playwright-cli.cmd', 'playwright-cli.exe', 'playwright-cli.ps1']);
  assert.equal(consent.RUN_CONFIG_NAME, 'playwright-cli.json');
  assert.equal(consent.RUN_OUTPUT_DIR_NAME, 'browser');
  assert.equal(consent.PLAYWRIGHT_CLI_SOURCE_VERSION, '0.1.21');
});

test('SESSION_RE admits only a lower-case zensu-verify name of bounded length', () => {
  const { SESSION_RE } = consent;
  for (const good of ['zensu-verify-run1', 'zensu-verify-a', 'zensu-verify-0-x', `zensu-verify-${'a'.repeat(40)}`]) {
    assert.equal(SESSION_RE.test(good), true, good);
  }
  for (const bad of ['zensu-verify-', 'zensu-verify--x', 'zensu-verify-Run1', 'zensu-verify-run_1', 'zensu-verify-run 1',
    `zensu-verify-${'a'.repeat(41)}`, 'zensu-run1', 'x-zensu-verify-run1', 'zensu-verify-run1\n']) {
    assert.equal(SESSION_RE.test(bad), false, JSON.stringify(bad));
  }
});

test('the command allowlist carries the emulation commands and none of the page-state or process commands', () => {
  const { ALLOWED_COMMANDS } = consent;
  assert.equal(Object.isFrozen(ALLOWED_COMMANDS), true);
  for (const [command, flags] of Object.entries(ALLOWED_COMMANDS)) assert.equal(Object.isFrozen(flags), true, command);
  for (const command of ['set-color-scheme', 'set-reduced-motion', 'set-forced-colors', 'set-contrast', 'set-media',
    'clear-color-scheme', 'clear-reduced-motion', 'clear-forced-colors', 'clear-contrast', 'clear-media']) {
    assert.deepEqual([...ALLOWED_COMMANDS[command]], [], command);
  }
  for (const command of ['open', 'close', 'goto', 'reload', 'tab-new', 'snapshot', 'screenshot', 'click', 'fill', 'type',
    'press', 'console', 'requests', 'list']) {
    assert.equal(Object.hasOwn(ALLOWED_COMMANDS, command), true, command);
  }
  for (const command of ['eval', 'run-code', 'cookie-list', 'cookie-set', 'cookie-clear', 'localstorage-get', 'localstorage-set',
    'sessionstorage-list', 'sessionstorage-set', 'state-save', 'state-load', 'attach', 'install-browser', 'close-all',
    'kill-all', 'route', 'unroute', 'upload']) {
    assert.equal(Object.hasOwn(ALLOWED_COMMANDS, command), false, command);
  }
  assert.deepEqual([...ALLOWED_COMMANDS.open], ['config', 'headed', 'browser', 'device', 'mobile', 'idle-timeout']);
  assert.deepEqual([...ALLOWED_COMMANDS.goto], []);
});

test('only Chromium channels and three navigation commands are named', () => {
  assert.equal(Object.isFrozen(consent.CHROMIUM_BROWSERS), true);
  assert.deepEqual([...consent.CHROMIUM_BROWSERS], ['chrome', 'chrome-beta', 'chrome-canary', 'chrome-dev',
    'msedge', 'msedge-beta', 'msedge-canary', 'msedge-dev', 'chromium']);
  for (const browser of ['firefox', 'webkit', 'safari']) assert.equal(consent.CHROMIUM_BROWSERS.includes(browser), false, browser);
  assert.equal(Object.isFrozen(consent.NAVIGATION_COMMANDS), true);
  assert.deepEqual([...consent.NAVIGATION_COMMANDS], ['open', 'goto', 'tab-new']);
});

test('the remote refusal carries the floor sentence and the memory keeps its shape and bounds', () => {
  assert.equal(REASONS.REMOTE_NEEDS_POLICY, `remote-target-needs-parent-environment-policy: ${floor.CONSENT_REMOTE_REASON}`);
  assert.deepEqual([...consent.DECIDED_BY], ['asked', 'remembered', 'policy-mode']);
  assert.equal(consent.MEMORY_VERSION, 1);
  assert.deepEqual(consent.emptyMemory(), { version: 1, records: [] });
  assert.equal(consent.MAX_RECORDS, 512);
  assert.equal(consent.MAX_MEMORY_BYTES, 65536);
  assert.equal(consent.MAX_RUN_ORIGINS, 8);
  assert.equal(consent.stateDirFor('/p'), path.join('/p', '.zensu', 'state'));
  assert.equal(consent.MEMORY_NAME_RE.test(`verify-consent-${KEY}.json`), true);
  assert.equal(consent.MEMORY_NAME_RE.test('verify-consent-scv1_short.json'), false);
});

test('lexShell splits segments on control operators and keeps quoted words whole', () => {
  const lexed = consent.lexShell(`echo 'a b' "c d" | grep x && ls; pwd`);
  assert.deepEqual(words(lexed), [['echo', 'a b', 'c d'], ['grep', 'x'], ['ls'], ['pwd']]);
  assert.equal(lexed.segments[0][0].quoted, false);
  assert.equal(lexed.segments[0][1].quoted, true);
  assert.equal(lexed.fault, '');
  assert.deepEqual(lexed.nested, []);
  assert.deepEqual(lexed.heredocs, []);
});

test('lexShell marks every expansion unexpanded and collects substitution bodies', () => {
  const lexed = consent.lexShell('echo $HOME "${USER}" $(date) `id`');
  assert.deepEqual(lexed.segments[0].map((word) => word.unexpanded), [false, true, true, true, true]);
  assert.equal(lexed.segments[0][1].raw, '$HOME');
  assert.deepEqual(lexed.nested, ['USER', 'date', 'id']);
});

test('a locale string is read like a double-quoted string, so a substitution inside it is judged', () => {
  const lexed = consent.lexShell('echo $"a $(date) `id` b" next');
  assert.deepEqual(words(lexed), [['echo', 'a   b', 'next']]);
  assert.equal(lexed.segments[0][1].unexpanded, true);
  assert.deepEqual(lexed.nested, ['date', 'id']);
  assert.equal(lexed.fault, '');
  const hidden = 'PLAYWRIGHT_CLI_SESSION=$"$(playwright-cli -s=zensu-verify-b open https://attacker.example)" playwright-cli -s=zensu-verify-a snapshot';
  assert.equal(consent.analyzeCommand(hidden, {}).calls.length, 2);
  assert.equal(decide(hidden).verdict, 'deny');
});

test('inside double quotes a dollar before a quote is a literal dollar, never a quote opener', () => {
  const closing = consent.lexShell('echo "abc$" next');
  assert.deepEqual(words(closing), [['echo', 'abc$', 'next']]);
  assert.equal(closing.segments[0][1].unexpanded, false);
  const single = consent.lexShell(`echo "a$'b" next`);
  assert.deepEqual(words(single), [['echo', "a$'b", 'next']]);
  assert.equal(single.segments[0][1].unexpanded, true);
  for (const command of [
    'PLAYWRIGHT_CLI_SESSION="$" ; playwright-cli -s=zensu-verify-b open https://attacker.example ; PLAYWRIGHT_CLI_SESSION="x" playwright-cli -s=zensu-verify-a snapshot',
    `PLAYWRIGHT_CLI_SESSION="$'" ; playwright-cli -s=zensu-verify-b open https://attacker.example ; PLAYWRIGHT_CLI_SESSION="'" playwright-cli -s=zensu-verify-a snapshot`,
  ]) {
    assert.equal(consent.analyzeCommand(command, {}).calls.length, 2, command);
    assert.equal(decide(command).verdict, 'deny', command);
  }
  assert.deepEqual(decide(cli('fill e1 "abc$"')), { verdict: 'none', plan: [] });
  assert.deepEqual(decide(cli("fill e1 '$=X'")), { verdict: 'none', plan: [] });
  assert.equal(denied(cli('fill e1 "$=X"')), REASONS.ARGUMENT_UNEXPANDED);
});

test('a carriage return is part of a word, as in bash, so it never starts a comment', () => {
  assert.deepEqual(words(consent.lexShell('echo a\r#b; echo c')), [['echo', 'a\r#b'], ['echo', 'c']]);
  const hidden = 'playwright-cli -s=zensu-verify-a snapshot\r#; playwright-cli -s=zensu-verify-b open https://attacker.example';
  assert.equal(consent.analyzeCommand(hidden, {}).calls.length, 2);
  assert.equal(denied(hidden), `command 'snapshot\r#' ${REASONS.COMMAND_DENIED}`);
});

test('every marked command the gate admits runs exactly the call it judged in a real bash', {
  skip: process.platform === 'win32' || !fs.existsSync('/bin/bash'),
}, (t) => {
  const bin = tempDir(t, 'zensu-stub-');
  const log = path.join(bin, 'calls.log');
  fs.writeFileSync(path.join(bin, 'playwright-cli'), '#!/bin/sh\nfor a in "$@"; do printf \'%s\\0\' "$a"; done >> "$STUB_LOG"\nprintf \'\\001\' >> "$STUB_LOG"\n', { mode: 0o755 });
  const env = isolatedEnv(t);
  const config = runConfig(t, ['http://127.0.0.1:4200']);
  const corpus = [
    ['dollar-quoted substitution', 'PLAYWRIGHT_CLI_SESSION=$"$(playwright-cli -s=zensu-verify-b open https://attacker.example)" playwright-cli -s=zensu-verify-a snapshot', {}],
    ['lone dollar in an assignment', 'PLAYWRIGHT_CLI_SESSION="$" ; playwright-cli -s=zensu-verify-b open https://attacker.example ; PLAYWRIGHT_CLI_SESSION="x" playwright-cli -s=zensu-verify-a snapshot', {}],
    ['dollar-quote opener in an assignment', `PLAYWRIGHT_CLI_SESSION="$'" ; playwright-cli -s=zensu-verify-b open https://attacker.example ; PLAYWRIGHT_CLI_SESSION="'" playwright-cli -s=zensu-verify-a snapshot`, {}],
    ['carriage return before a hash', 'playwright-cli -s=zensu-verify-a snapshot\r#; playwright-cli -s=zensu-verify-b open https://attacker.example', {}],
    ['comment', 'playwright-cli -s=zensu-verify-a snapshot #; playwright-cli -s=zensu-verify-b snapshot', {}],
    ['session from the environment', 'playwright-cli snapshot', { PLAYWRIGHT_CLI_SESSION: SESSION }],
    ['plain call', cli('snapshot'), {}],
    ['trailing dollar in double quotes', cli('fill e1 "abc$"'), {}],
    ['dollar words', cli("fill e1 '$=X' \"5$ each\""), {}],
    ['navigation', cli('goto http://127.0.0.1:4200/login'), {}],
    ['session assignment', `PLAYWRIGHT_CLI_SESSION=${SESSION} playwright-cli tab-list`, {}],
    ['open with the run config', openCommand(config.file, 'http://127.0.0.1:4200/'), {}],
  ];
  const admitted = [];
  for (const [label, command, extra] of corpus) {
    assert.equal(consent.commandMarkers(command, extra).session, true, label);
    const decision = decide(command, { env: { ...env, ...extra } });
    if (decision.verdict === 'deny') continue;
    admitted.push(label);
    const judged = consent.analyzeCommand(command, extra).calls.map((call) => call.invocation.words.map((word) => word.value));
    fs.writeFileSync(log, '');
    const ran = spawnSync('/bin/bash', ['-c', command], {
      cwd: bin,
      encoding: 'utf8',
      timeout: 10000,
      env: { PATH: `${bin}:/usr/bin:/bin`, STUB_LOG: log, ...extra },
    });
    assert.equal(ran.error, undefined, label);
    const executed = fs.readFileSync(log, 'utf8').split('\u0001').slice(0, -1).map((record) => record.split('\0').slice(0, -1));
    assert.deepEqual(executed, judged, label);
  }
  assert.deepEqual(admitted, [
    'comment', 'session from the environment', 'plain call', 'trailing dollar in double quotes', 'dollar words',
    'navigation', 'session assignment', 'open with the run config',
  ]);
});

test('lexShell drops redirection targets and reads a heredoc body aside', () => {
  assert.deepEqual(words(consent.lexShell('echo hi > out.txt 2>&1')), [['echo', 'hi']]);
  const heredoc = consent.lexShell("cat <<'EOF'\nline one\nEOF\necho done");
  assert.deepEqual(heredoc.heredocs, ['line one\n']);
  assert.deepEqual(words(heredoc), [['cat'], ['echo', 'done']]);
  assert.equal(heredoc.fault, '');
});

test('lexShell reports an unterminated quote, substitution or heredoc as a fault', () => {
  assert.equal(consent.lexShell("echo 'open").fault, 'unterminated-quote');
  assert.equal(consent.lexShell('echo $(date').fault, 'unterminated-substitution');
  assert.equal(consent.lexShell('cat <<EOF\nno end').fault, 'unterminated-heredoc');
});

test('lexShell ignores comments and joins line continuations', () => {
  assert.deepEqual(words(consent.lexShell('echo a \\\n  b # trailing comment')), [['echo', 'a', 'b']]);
});

test('lexShell collects here-string words, counts control operators and marks shell pattern words unexpanded', () => {
  const here = consent.lexShell(`bash <<< 'playwright-cli -s=${SESSION} eval 1'`);
  assert.deepEqual(words(here), [['bash']]);
  assert.deepEqual(here.herestrings.map((word) => word.value), [`playwright-cli -s=${SESSION} eval 1`]);
  assert.equal(consent.lexShell('a; b && c || d | e & f').operators, 5);
  assert.equal(consent.lexShell('(a)').operators, 2);
  assert.equal(consent.lexShell('echo hi > out.txt 2>&1').operators, 0);
  assert.equal(consent.lexShell('playwright-cli snapshot\n').operators, 0);
  assert.deepEqual(consent.lexShell('echo hi').herestrings, []);
  const patterns = consent.lexShell("x {a,b} {1..3} a*b c?d [ab] ~/x =cmd '{a,b}' \"*\" \\* {a} a=b ~");
  assert.deepEqual(patterns.segments[0].map((word) => word.unexpanded),
    [false, true, true, true, true, true, true, true, false, false, false, false, false, true]);
});

test('parseCliArgs reads the session from -s and --session in every spelling', () => {
  assert.deepEqual(consent.parseCliArgs(['-s=zensu-verify-a', 'goto', 'http://127.0.0.1:1/']).args,
    { _: ['goto', 'http://127.0.0.1:1/'], session: 'zensu-verify-a' });
  assert.deepEqual(consent.parseCliArgs(['-s', 'zensu-verify-a', 'list']).args, { _: ['list'], session: 'zensu-verify-a' });
  assert.deepEqual(consent.parseCliArgs(['--session', 'zensu-verify-a', 'snapshot']).args, { _: ['snapshot'], session: 'zensu-verify-a' });
  assert.deepEqual(consent.parseCliArgs(['--session=zensu-verify-a']).args, { _: [], session: 'zensu-verify-a' });
});

test('parseCliArgs turns a repeated value flag into an array and keeps boolean flags scalar', () => {
  assert.deepEqual(consent.parseCliArgs(['open', '--config=/a.json', '--config=/b.json']).args.config, ['/a.json', '/b.json']);
  assert.deepEqual(consent.parseCliArgs(['--filter', 'x', '--filter', 'y', '--filter', 'z']).args.filter, ['x', 'y', 'z']);
  const flags = consent.parseCliArgs(['open', '--headed', '--headed', 'http://127.0.0.1:1/']).args;
  assert.equal(flags.headed, true);
  assert.deepEqual(flags._, ['open', 'http://127.0.0.1:1/']);
  assert.equal(consent.parseCliArgs(['--no-headed']).args.headed, false);
  assert.equal(consent.parseCliArgs(['--headed', 'false']).args.headed, false);
  assert.deepEqual(consent.parseCliArgs(['-g']).args, { _: [], global: true });
});

test('parseCliArgs and CLI_BOOLEAN_OPTIONS match a golden recording of the measured playwright-cli parser', () => {
  const golden = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'playwright-cli-argv.v1.json'), 'utf8'));
  assert.equal(golden.source.package, '@playwright/cli');
  assert.equal(golden.source.version, consent.PLAYWRIGHT_CLI_SOURCE_VERSION);
  assert.deepEqual([...new Set(consent.CLI_BOOLEAN_OPTIONS)].sort(), golden.booleanOptions);
  assert.equal(golden.cases.length, 53);
  assert.ok(golden.cases.some((entry) => entry.error));
  for (const entry of golden.cases) {
    const parsed = consent.parseCliArgs(entry.argv.slice());
    if (entry.error) assert.ok(parsed.fault, JSON.stringify(entry.argv));
    else assert.deepEqual(parsed.args, entry.args, JSON.stringify(entry.argv));
  }
});

test('the committed golden fixture was recorded from the committed case list', () => {
  const golden = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'playwright-cli-argv.v1.json'), 'utf8'));
  const recorder = require('./fixtures/record-playwright-cli-argv.js');
  assert.deepEqual(golden.cases.map((entry) => entry.argv), recorder.CASES);
  assert.deepEqual(golden.stringOptions, [...consent.CLI_STRING_OPTIONS]);
  const gatedSessions = (command, envSession) => consent.analyzeCommand(command, { PLAYWRIGHT_CLI_SESSION: envSession }).calls.map((call) => call.session.value);
  const argumentWins = gatedSessions('playwright-cli -s=mine goto http://127.0.0.1:4200/', SESSION).length === 0
    && gatedSessions(`playwright-cli -s=${SESSION} goto http://127.0.0.1:4200/`, 'mine').join() === SESSION;
  const environmentWins = gatedSessions('playwright-cli -s=mine goto http://127.0.0.1:4200/', SESSION).join() === SESSION
    && gatedSessions(`playwright-cli -s=${SESSION} goto http://127.0.0.1:4200/`, 'mine').length === 0;
  const observed = argumentWins && !environmentWins ? 'argument-over-environment'
    : environmentWins && !argumentWins ? 'environment-over-argument' : 'undetermined';
  assert.equal(observed, golden.sessionPrecedence);
  assert.deepEqual(golden.source.bin, [...new Set(consent.CLI_BASENAMES.map((name) => name.replace(/\.(cmd|exe|ps1)$/, '')))]);
  for (const argv of [['-szensu-verify-run1', 'eval', '1'], ['-szensu-verify-a', 'eval', '1'], ['-s/zensu-verify-a', 'snapshot'],
    ['-s.x', 'y'], ['-s-', 'snapshot'], ['-_s', 'zensu-verify-a', 'eval', '1'], ['-.s', 'zensu-verify-a', 'eval', '1'],
    ['-@s', 'zensu-verify-a', 'eval', '1'], ['-S', 'zensu-verify-a', 'eval', '1']]) {
    assert.ok(recorder.CASES.some((entry) => JSON.stringify(entry) === JSON.stringify(argv)), JSON.stringify(argv));
  }
});

test('a session value attached to -s is judged like the spelled-out forms', () => {
  assert.equal(denied(`playwright-cli -s${SESSION} eval 1`), `command 'eval' ${REASONS.COMMAND_DENIED}`);
  assert.equal(decide(`playwright-cli -s${SESSION} goto http://127.0.0.1:4200/`).verdict, 'ask');
  assert.equal(denied('playwright-cli -s/zensu-verify-a snapshot'), REASONS.SESSION_MALFORMED);
  assert.deepEqual(consent.parseCliArgs([`-s${SESSION}`, 'eval', '1']).args, { _: ['eval', '1'], session: SESSION });
});

test('parseCliArgs refuses a value on a boolean option and keeps words after -- positional', () => {
  assert.deepEqual(consent.parseCliArgs(['open', '--headed=yes']), { fault: 'boolean option --headed carries a value' });
  assert.deepEqual(consent.parseCliArgs(['fill', 'e1', '--', '--submit']).args, { _: ['fill', 'e1', '--submit'] });
});

test('analyzeCommand gates a plain call on a zensu-verify session', () => {
  const analysis = consent.analyzeCommand(cli('goto http://127.0.0.1:4200/login'), {});
  assert.equal(analysis.calls.length, 1);
  const [call] = analysis.calls;
  assert.equal(call.gated, true);
  assert.deepEqual(call.session, { value: SESSION, source: 'argument' });
  assert.deepEqual(call.args._, ['goto', 'http://127.0.0.1:4200/login']);
  assert.equal(call.invocation.launcher, false);
  assert.equal(analysis.indirect, false);
  assert.equal(analysis.unjudged, false);
  assert.equal(analysis.envBuiltin, false);
});

test('a session other than zensu-verify, or none at all, leaves the call ungated', () => {
  for (const command of ['playwright-cli -s=mine goto http://127.0.0.1:4200/', 'playwright-cli goto http://127.0.0.1:4200/',
    'playwright-cli --session=zensu-other snapshot']) {
    assert.deepEqual(consent.analyzeCommand(command, {}).calls, [], command);
  }
});

test('the session may come from an assignment or from the environment, and an argument outranks both', () => {
  const assigned = consent.analyzeCommand('PLAYWRIGHT_CLI_SESSION=zensu-verify-x playwright-cli goto http://127.0.0.1:4200/', {});
  assert.equal(assigned.calls.length, 1);
  assert.equal(assigned.calls[0].session.source, 'assignment');
  assert.equal(assigned.calls[0].session.value, 'zensu-verify-x');
  const inherited = consent.analyzeCommand('playwright-cli goto http://127.0.0.1:4200/', { PLAYWRIGHT_CLI_SESSION: 'zensu-verify-x' });
  assert.equal(inherited.calls.length, 1);
  assert.equal(inherited.calls[0].session.source, 'environment');
  assert.deepEqual(consent.analyzeCommand('playwright-cli -s=mine goto http://127.0.0.1:4200/', { PLAYWRIGHT_CLI_SESSION: 'zensu-verify-x' }).calls, []);
  assert.equal(decide('PLAYWRIGHT_CLI_SESSION=zensu-verify-x playwright-cli goto http://127.0.0.1:4200/').verdict, 'ask');
});

test('a package launcher is recognized and refused, and a path to the binary is refused as not bare', () => {
  for (const command of [`npx @playwright/cli -s=${SESSION} snapshot`, `npx -y @playwright/cli@0.1.21 -s=${SESSION} snapshot`,
    `pnpm dlx @playwright/cli -s=${SESSION} snapshot`, `/usr/local/bin/playwright-cli -s=${SESSION} snapshot`]) {
    const analysis = consent.analyzeCommand(command, {});
    assert.equal(analysis.calls.length, 1, command);
    assert.equal(analysis.calls[0].gated, true, command);
    assert.equal(analysis.indirect, false, command);
  }
  assert.equal(consent.analyzeCommand(`npx @playwright/cli -s=${SESSION} snapshot`, {}).calls[0].invocation.launcher, true);
  for (const command of [`npx @playwright/cli -s=${SESSION} snapshot`, `npx -y @playwright/cli@0.1.21 -s=${SESSION} snapshot`,
    `npx playwright-cli -s=${SESSION} snapshot`, `bunx @playwright/cli -s=${SESSION} snapshot`, `pnpx @playwright/cli -s=${SESSION} snapshot`,
    `pnpm dlx @playwright/cli -s=${SESSION} snapshot`, `npm exec @playwright/cli -s=${SESSION} snapshot`,
    `npm x -- @playwright/cli -s=${SESSION} snapshot`, `yarn dlx @playwright/cli -s=${SESSION} snapshot`,
    `npx @playwright/cli -s=${SESSION} eval 1`]) {
    assert.equal(denied(command), REASONS.LAUNCHER, command);
  }
  assert.equal(denied(`/usr/local/bin/playwright-cli -s=${SESSION} snapshot`), REASONS.CLI_NOT_BARE);
  assert.deepEqual(decide('npx @playwright/cli -s=mine eval 1'), { verdict: 'none' });
});

test('a gated call names the CLI by its bare name only, so PATH resolves the measured binary', () => {
  for (const command of [
    `./node_modules/.bin/playwright-cli -s=${SESSION} snapshot`,
    `/opt/homebrew/bin/playwright-cli -s=${SESSION} goto http://127.0.0.1:4200/`,
    `@playwright/cli -s=${SESSION} snapshot`,
    `@playwright/cli@0.1.21 -s=${SESSION} snapshot`,
    `Playwright-CLI -s=${SESSION} snapshot`,
    `PLAYWRIGHT-CLI.EXE -s=${SESSION} snapshot`,
  ]) {
    assert.equal(denied(command), REASONS.CLI_NOT_BARE, command);
  }
  assert.match(REASONS.CLI_NOT_BARE, /bare name/);
  assert.match(REASONS.CLI_NOT_BARE, /PATH/);
  for (const name of cliVersion.binaryNames(process.platform)) {
    assert.deepEqual(decide(`${name} -s=${SESSION} snapshot`), { verdict: 'none', plan: [] }, name);
  }
  assert.deepEqual(decide(`playwright-cl''i -s=${SESSION} snapshot`), { verdict: 'none', plan: [] });
  assert.deepEqual(decide('/opt/homebrew/bin/playwright-cli -s=mine snapshot'), { verdict: 'none' });
});

test('the version module owns the CLI names, and only the spellings the host resolves count as bare', () => {
  assert.equal(consent.CLI_PACKAGE, cliVersion.PACKAGE_NAME);
  assert.equal(consent.CLI_BASENAMES, cliVersion.BINARY_NAMES);
  assert.deepEqual([...cliVersion.binaryNames('linux')], ['playwright-cli']);
  assert.deepEqual([...cliVersion.binaryNames('darwin')], ['playwright-cli']);
  assert.deepEqual([...cliVersion.binaryNames('win32')].sort(), [...consent.CLI_BASENAMES].sort());
  for (const name of ['playwright-cli.cmd', 'playwright-cli.exe', 'playwright-cli.ps1']) {
    assert.equal(denied(`${name} -s=${SESSION} snapshot`, { platform: 'linux' }), REASONS.CLI_NOT_BARE, name);
    assert.equal(denied(`${name} -s=${SESSION} snapshot`, { platform: 'darwin' }), REASONS.CLI_NOT_BARE, name);
    assert.deepEqual(decide(`${name} -s=${SESSION} snapshot`, { platform: 'win32' }), { verdict: 'none', plan: [] }, name);
  }
  for (const platform of ['linux', 'darwin', 'win32']) {
    assert.deepEqual(decide(`playwright-cli -s=${SESSION} snapshot`, { platform }), { verdict: 'none', plan: [] }, platform);
  }
});

test('an unexpanded session beside a zensu-verify literal and an unexpanded argument are refused', () => {
  assert.equal(denied('S=zensu-verify-x; playwright-cli -s="$S" goto http://127.0.0.1:4200/'), REASONS.SESSION_UNEXPANDED);
  assert.equal(denied(cli('goto $URL')), REASONS.ARGUMENT_UNEXPANDED);
  assert.equal(denied(cli('snapshot --depth=$DEPTH')), REASONS.ARGUMENT_UNEXPANDED);
  assert.equal(denied(cli('goto "$(cat url.txt)"')), REASONS.ARGUMENT_UNEXPANDED);
  for (const form of ['$=X', '"$~X"', '$^X', '$+X']) {
    assert.equal(denied(cli(`snapshot ${form}`)), REASONS.ARGUMENT_UNEXPANDED, form);
  }
  assert.equal(denied(cli('snapshot > $=X')), REASONS.NOT_PLAIN);
  assert.deepEqual(decide(cli('fill e1 5$')), { verdict: 'none', plan: [] });
  assert.deepEqual(decide(cli('fill e1 "5$ each"')), { verdict: 'none', plan: [] });
});

test('an unexpanded session assignment is refused even where a literal -s outranks it', () => {
  for (const command of [
    `PLAYWRIGHT_CLI_SESSION=$X playwright-cli -s=${SESSION} snapshot`,
    `PLAYWRIGHT_CLI_SESSION="$(date)" playwright-cli -s=${SESSION} snapshot`,
    `PLAYWRIGHT_CLI_SESSION=$X; playwright-cli -s=${SESSION} snapshot`,
  ]) {
    assert.equal(denied(command), REASONS.SESSION_UNEXPANDED, command);
  }
  const env = { PLAYWRIGHT_CLI_SESSION: SESSION };
  assert.equal(denied('PLAYWRIGHT_CLI_SESSION=$X playwright-cli -s=mine snapshot', { env }), REASONS.SESSION_UNEXPANDED);
  assert.deepEqual(decide('PLAYWRIGHT_CLI_SESSION=$X playwright-cli -s=mine snapshot'), { verdict: 'none' });
  assert.deepEqual(decide(`PLAYWRIGHT_CLI_SESSION=${SESSION} playwright-cli -s=${SESSION} snapshot`), { verdict: 'none', plan: [] });
});

test('a call run through another program is refused as indirect', () => {
  assert.equal(denied(`echo http://127.0.0.1:4200/ | xargs playwright-cli -s=${SESSION} goto`), REASONS.INDIRECT);
  assert.equal(denied(`find . -name x -exec playwright-cli -s=${SESSION} snapshot \\;`), REASONS.INDIRECT);
});

test('a nested shell body is judged when literal and refused when it cannot be judged', () => {
  assert.equal(denied(`bash -c "playwright-cli -s=${SESSION} eval 1"`), `command 'eval' ${REASONS.COMMAND_DENIED}`);
  assert.equal(denied(`bash -c "playwright-cli -s=${SESSION} goto $URL"`), REASONS.UNJUDGED_BODY);
  assert.equal(denied(`sh -c 'playwright-cli -s=${SESSION} goto http://127.0.0.1:4200/'`), REASONS.NOT_PLAIN);
});

test('a heredoc body carrying a zensu-verify call is refused as unjudged', () => {
  assert.equal(denied(`bash <<'EOF'\nplaywright-cli -s=${SESSION} goto http://127.0.0.1:4200/\nEOF`), REASONS.UNJUDGED_BODY);
});

test('a here-string body, a -c or eval body beyond the nesting bound and an unexpanded body are refused as unjudged', () => {
  assert.equal(denied(`bash <<< 'playwright-cli -s=${SESSION} eval 1'`), REASONS.UNJUDGED_BODY);
  assert.equal(denied(`$($($(bash -c 'playwright-cli -s=${SESSION} eval 1')))`), `command 'eval' ${REASONS.COMMAND_DENIED}`);
  assert.equal(denied(`$($($($(bash -c 'playwright-cli -s=${SESSION} eval 1'))))`), REASONS.UNJUDGED_BODY);
  assert.equal(denied(`$($($($(eval 'playwright-cli -s=${SESSION} eval 1'))))`), REASONS.UNJUDGED_BODY);
  assert.equal(denied(`S=${SESSION}; bash -c "playwright-cli -s=$S eval 1"`), REASONS.UNJUDGED_BODY);
});

test('the eval builtin, a process substitution and an assignment-only segment are all seen', () => {
  assert.equal(denied(`eval 'playwright-cli -s=${SESSION} eval 1'`), `command 'eval' ${REASONS.COMMAND_DENIED}`);
  assert.equal(denied(`eval "playwright-cli -s=${SESSION} $X"`), REASONS.UNJUDGED_BODY);
  assert.equal(denied(`cat <(playwright-cli -s=${SESSION} eval 1)`), `command 'eval' ${REASONS.COMMAND_DENIED}`);
  assert.equal(denied(`PLAYWRIGHT_CLI_SESSION=${SESSION}; playwright-cli eval 1`), `command 'eval' ${REASONS.COMMAND_DENIED}`);
  assert.equal(denied(`declare PLAYWRIGHT_CLI_SESSION=${SESSION}; playwright-cli eval 1`), REASONS.ENV_BUILTIN);
  assert.deepEqual(decide('PLAYWRIGHT_CLI_SESSION=mine; playwright-cli eval 1'), { verdict: 'none' });
});

test('a nested shell body inherits the assignments and wrappers of the segment that runs it', () => {
  const open = 'open --config=/abs/run/playwright-cli.json http://127.0.0.1:3000/';
  assert.equal(denied(`HOME=/tmp/x bash -c 'playwright-cli -s zensu-verify-a ${open}'`), REASONS.ENV_ASSIGNMENT);
  assert.equal(denied(`sudo sh -c 'playwright-cli -s zensu-verify-a ${open}'`), REASONS.ENV_ASSIGNMENT);
  assert.equal(denied(`env -i sh -c 'playwright-cli -s zensu-verify-a ${open}'`), REASONS.ENV_ASSIGNMENT);
  const analysis = consent.analyzeCommand(`HOME=/tmp/x bash -c 'playwright-cli -s zensu-verify-a snapshot'`, {});
  assert.deepEqual(analysis.calls[0].invocation.assignments.map((item) => item.name), ['HOME']);
});

test('a command string handed to another program or shell is refused as indirect', () => {
  for (const command of [
    `echo 'playwright-cli -s=${SESSION} eval 1' | bash`,
    `echo 1 | xargs sh -c 'playwright-cli -s zensu-verify-a eval 1'`,
    `npx -c 'playwright-cli -s zensu-verify-a eval 1'`,
    `env -S 'playwright-cli -s zensu-verify-a eval 1'`,
    `bash < <(printf 'playwright-cli -s=${SESSION} eval 1')`,
    `echo zensu-verify-x | xargs -I{} playwright-cli -s={} open --config=/tmp/x.json`,
  ]) {
    assert.equal(denied(command), REASONS.INDIRECT, command);
  }
  assert.deepEqual(decide("echo 'playwright-cli -s=mine eval 1' | bash"), { verdict: 'none' });
});

test('a session that arrives through expansion, an append, a second value, a letter case or a path is refused', () => {
  assert.equal(denied(`S='-s zensu-verify-a'; playwright-cli $S eval 1`), REASONS.ARGUMENT_UNEXPANDED);
  assert.equal(denied('playwright-cli {-s,zensu-verify-a} eval 1'), REASONS.ARGUMENT_UNEXPANDED);
  assert.equal(denied('PLAYWRIGHT_CLI_SESSION=zensu-verify-a; playwright-cli eval 1; PLAYWRIGHT_CLI_SESSION=x'), REASONS.SESSION_MALFORMED);
  assert.equal(denied('export PLAYWRIGHT_CLI_SESSION=zensu-verify-a; playwright-cli eval 1; export PLAYWRIGHT_CLI_SESSION=x'),
    REASONS.ENV_BUILTIN);
  assert.equal(denied('PLAYWRIGHT_CLI_SESSION=zensu-verify-; PLAYWRIGHT_CLI_SESSION+=a playwright-cli eval 1'), REASONS.SESSION_MALFORMED);
  assert.equal(denied('PLAYWRIGHT_CLI_SESSION+=zensu-verify-a playwright-cli eval 1'), REASONS.SESSION_UNEXPANDED);
  assert.equal(denied('playwright-cli -s=ZENSU-VERIFY-RUN1 eval 1'), REASONS.SESSION_MALFORMED);
  assert.equal(denied('playwright-cli -s=x/../zensu-verify-run1 eval 1'), REASONS.SESSION_MALFORMED);
  assert.equal(denied('playwright-cli eval 1', { env: { PLAYWRIGHT_CLI_SESSION: 'ZENSU-VERIFY-X' } }), REASONS.SESSION_MALFORMED);
  assert.deepEqual(decide('playwright-cli -s=mine $ARGS eval 1'), { verdict: 'none' });
});

test('calls inside a subshell or a command substitution are still judged', () => {
  assert.equal(denied(`(cd /tmp && playwright-cli -s=${SESSION} eval 1)`), `command 'eval' ${REASONS.COMMAND_DENIED}`);
  assert.equal(denied(`echo $(playwright-cli -s=${SESSION} cookie-list)`), `command 'cookie-list' ${REASONS.COMMAND_DENIED}`);
  assert.equal(denied(`(playwright-cli -s=${SESSION} goto http://127.0.0.1:4200/)`), REASONS.NOT_PLAIN);
});

test('redefining playwright-cli, changing the shell environment or naming ambient variables is refused', () => {
  assert.equal(denied(`playwright-cli() { :; }; playwright-cli -s=${SESSION} snapshot`), REASONS.REDEFINED);
  assert.equal(denied(`function playwright-cli { :; }; playwright-cli -s=${SESSION} snapshot`), REASONS.REDEFINED);
  assert.equal(denied(`export FOO=1; playwright-cli -s=${SESSION} snapshot`), REASONS.ENV_BUILTIN);
  assert.equal(denied(`unset PLAYWRIGHT_CLI_SESSION; playwright-cli -s=${SESSION} snapshot`), REASONS.ENV_BUILTIN);
  assert.equal(denied(`echo $PLAYWRIGHT_MCP_CONFIG; playwright-cli -s=${SESSION} snapshot`), REASONS.AMBIENT_TEXT);
  assert.equal(denied(`PWTEST_CLI_GLOBAL_CONFIG=/tmp playwright-cli -s=${SESSION} snapshot`), REASONS.AMBIENT_TEXT);
});

test('assignments and environment-changing wrappers are refused as such, and every other wrapper is refused as a wrapper', () => {
  for (const command of [`FOO=1 playwright-cli -s=${SESSION} snapshot`, `env playwright-cli -s=${SESSION} snapshot`,
    `sudo playwright-cli -s=${SESSION} snapshot`, `doas playwright-cli -s=${SESSION} snapshot`,
    `timeout 30 env playwright-cli -s=${SESSION} snapshot`]) {
    assert.equal(denied(command), REASONS.ENV_ASSIGNMENT, command);
  }
  for (const command of [`timeout 30 playwright-cli -s=${SESSION} snapshot`, `gtimeout -k 5 30 playwright-cli -s=${SESSION} snapshot`,
    `nohup playwright-cli -s=${SESSION} snapshot`, `time playwright-cli -s=${SESSION} snapshot`, `nice -n 5 playwright-cli -s=${SESSION} snapshot`,
    `exec playwright-cli -s=${SESSION} snapshot`, `command playwright-cli -s=${SESSION} snapshot`, `builtin playwright-cli -s=${SESSION} snapshot`,
    `timeout 30 npx @playwright/cli -s=${SESSION} snapshot`]) {
    assert.equal(denied(command), REASONS.WRAPPER, command);
  }
  assert.deepEqual(decide('timeout 30 playwright-cli -s=mine eval 1'), { verdict: 'none' });
});

test('a wrapper the ladder does not know is refused too, so the ladder decides only the reason', () => {
  for (const wrapper of ['stdbuf -o0', 'setsid', 'ionice -c3', 'caffeinate -i', 'flock /tmp/lock', 'script -q /dev/null']) {
    assert.equal(denied(`${wrapper} ${cli('snapshot')}`), REASONS.INDIRECT, wrapper);
  }
  for (const wrapper of ['timeout 5', 'gtimeout 5', 'nohup', 'nice -n 5', 'exec', 'command', 'builtin', 'time']) {
    assert.equal(denied(`${wrapper} ${cli('snapshot')}`), REASONS.WRAPPER, wrapper);
  }
  for (const wrapper of ['env', 'sudo', 'doas']) {
    assert.equal(denied(`${wrapper} ${cli('snapshot')}`), REASONS.ENV_ASSIGNMENT, wrapper);
  }
});

test('a command lookup beside the call is not an indirect call, but the command is not one plain call', () => {
  assert.equal(consent.analyzeCommand(`command -v playwright-cli && playwright-cli -s=${SESSION} snapshot`, {}).indirect, false);
  assert.equal(denied(`command -v playwright-cli && playwright-cli -s=${SESSION} snapshot`), REASONS.NOT_PLAIN);
});

test('a marked command is admitted only as one plain top-level playwright-cli call', () => {
  for (const command of [
    `${cli('goto http://127.0.0.1:4200/')} && curl -s http://127.0.0.1:9/`,
    `${cli('snapshot')}; ${cli('snapshot')}`,
    `${cli('snapshot')}\n${cli('snapshot')}`,
    `${cli('snapshot')} | cat`,
    `${cli('snapshot')} &`,
    `echo "$(${cli('snapshot')})"`,
    `${cli('snapshot')} <<< 'x'`,
    `$'playwright-cli' -s=${SESSION} eval 1`,
    `=playwright-cli -s=${SESSION} eval 1`,
    `./playwright-cli-wrapper -s=${SESSION} eval 1`,
  ]) {
    assert.equal(denied(command), REASONS.NOT_PLAIN, command);
  }
  for (const command of [`P=playwright-cli; $P -s=${SESSION} eval 1`, `$(echo playwright-cli) -s=${SESSION} eval 1`,
    `node ./node_modules/@playwright/cli/cli.js -s=${SESSION} eval 1`]) {
    assert.equal(denied(command), REASONS.INDIRECT, command);
  }
  assert.equal(decide(cli('goto http://127.0.0.1:4200/')).verdict, 'ask');
  assert.deepEqual(decide(cli('snapshot 2>&1')), { verdict: 'none', plan: [] });
  assert.deepEqual(decide(`${cli('snapshot')} # note`), { verdict: 'none', plan: [] });
  assert.deepEqual(decide(`${cli('snapshot')}\n`), { verdict: 'none', plan: [] });
  assert.deepEqual(decide('playwright-cli snapshot', { env: { PLAYWRIGHT_CLI_SESSION: SESSION } }), { verdict: 'none', plan: [] });
  assert.deepEqual(decide('playwright-cli -s=mine snapshot && playwright-cli -s=mine eval 1'), { verdict: 'none' });
});

test('a line holding only a redirection is its own command, so the marked call beside it is not plain', () => {
  for (const command of [
    `${cli('snapshot')}\n> /tmp/zv-redirect`,
    `> /tmp/zv-redirect\n${cli('snapshot')}`,
    `${cli('snapshot')}\n2>> /tmp/zv-redirect`,
  ]) {
    assert.equal(denied(command), REASONS.NOT_PLAIN, command);
  }
  assert.deepEqual(decide(`${cli('snapshot')} > /tmp/zv-out.txt`), { verdict: 'none', plan: [] });
  assert.deepEqual(decide(`> /tmp/zv-out.txt ${cli('snapshot')}`), { verdict: 'none', plan: [] });
  assert.deepEqual(decide(`${cli('snapshot')} > /tmp/zv-out.txt\n`), { verdict: 'none', plan: [] });
});

test('a command hidden in a parameter or arithmetic expansion is scanned, and an unexpanded CLI word or redirect target is not plain', () => {
  const hidden = `playwright-cli\${x:-$(playwright-cli -s=${SESSION} eval 'document.cookie' >&2)} -s=${SESSION} snapshot`;
  assert.equal(denied(hidden), `command 'eval' ${REASONS.COMMAND_DENIED}`, hidden);
  assert.deepEqual(consent.lexShell('echo $(( $(id) ))').nested, ['( $(id) )']);
  assert.equal(denied(`echo $(( $(playwright-cli -s=${SESSION} eval 1) ))`), `command 'eval' ${REASONS.COMMAND_DENIED}`);
  for (const command of [
    `playwright-cli\${x} -s=${SESSION} snapshot`,
    `playwright-cli$x -s=${SESSION} snapshot`,
    `~/bin/playwright-cli -s=${SESSION} snapshot`,
    `${cli('snapshot')} > "\${x:-$(touch /tmp/zv-p)}"`,
    `${cli('snapshot')} > $(( $(touch /tmp/zv-p) ))`,
    `${cli('snapshot')} > $TMPDIR/zv-out.txt`,
    `${cli('snapshot')} 2> /tmp/zv-*`,
  ]) {
    assert.equal(denied(command), REASONS.NOT_PLAIN, command);
  }
  assert.match(REASONS.NOT_PLAIN, /redirect[^;]*literal/);
  assert.match(REASONS.NOT_PLAIN, /^a command that names playwright-cli and a zensu-verify session, or names playwright-cli while PLAYWRIGHT_CLI_SESSION names one, must be/);
  assert.deepEqual(decide(`${cli('snapshot')} > /tmp/zv-out.txt 2>&1`), { verdict: 'none', plan: [] });
});

test('a command that only mentions playwright-cli and a zensu-verify session is refused with the remedy named', () => {
  for (const command of [
    `grep -rn "playwright-cli -s=${SESSION}" docs`,
    `git commit -m "fix playwright-cli ${SESSION} gate"`,
    `echo playwright-cli ${SESSION}`,
    `rg ${SESSION} | grep playwright-cli`,
    `cat notes.txt # playwright-cli -s=${SESSION}`,
  ]) {
    const reason = denied(command);
    assert.ok([REASONS.INDIRECT, REASONS.NOT_PLAIN].includes(reason), `${command} -> ${reason}`);
    assert.match(reason, /Grep tool/, command);
    assert.match(reason, /message file/, command);
  }
  assert.match(REASONS.INDIRECT, /^a zensu-verify playwright-cli call must run as a plain command, not through another program/);
  assert.equal(denied(`echo http://127.0.0.1:4200/ | xargs playwright-cli -s=${SESSION} goto`), REASONS.INDIRECT);
});

test('a plain call whose text names a zensu-verify session it does not resolve to is refused', () => {
  for (const command of [
    'playwright-cli -_s zensu-verify-a eval 1',
    'playwright-cli -.s zensu-verify-a eval 1',
    'playwright-cli -@s zensu-verify-a eval 1',
    'playwright-cli -S zensu-verify-a eval 1',
    'playwright-cli --sesion=zensu-verify-a eval 1',
    'playwright-cli -szensu-verify-a eval 1',
    'playwright-cli -s=mine snapshot --filename=zensu-verify-notes.md',
  ]) {
    assert.equal(denied(command), REASONS.SESSION_UNRESOLVED, command);
  }
  assert.match(REASONS.SESSION_UNRESOLVED, /-s=<name>/);
  assert.deepEqual(decide('playwright-cli -s=other snapshot', { env: { PLAYWRIGHT_CLI_SESSION: SESSION } }), { verdict: 'none' });
  assert.deepEqual(decide('playwright-cli -S other eval 1'), { verdict: 'none' });
  assert.equal(denied(`playwright-cli -s=mine snapshot && echo ${SESSION}`), REASONS.NOT_PLAIN);
});

test('an ambient variable spelled through quotes and a redefinition in another letter case are refused', () => {
  assert.equal(denied(`env PLAYWRIGHT_MCP''_CONFIG=/tmp/x ${cli('snapshot')}`), REASONS.AMBIENT_TEXT);
  assert.equal(denied(`Playwright-cli() { :; }; Playwright-cli -s=${SESSION} snapshot`), REASONS.REDEFINED);
  assert.equal(denied(`function PLAYWRIGHT-CLI { :; }; ${cli('snapshot')}`), REASONS.REDEFINED);
});

test('a malformed, oversized or repeated session name is refused', () => {
  assert.equal(denied('playwright-cli -s=zensu-verify-Bad snapshot'), REASONS.SESSION_MALFORMED);
  assert.equal(denied(`playwright-cli -s=zensu-verify-${'a'.repeat(41)} snapshot`), REASONS.SESSION_MALFORMED);
  assert.equal(denied(`playwright-cli -s=${SESSION} -s=zensu-verify-other snapshot`), REASONS.SESSION_MALFORMED);
});

test('an unrelated or ungated command gets no decision', () => {
  for (const command of ['', 'ls -la', 'git commit -m "mention playwright-cli here"', 'playwright-cli -s=mine eval "document.cookie"',
    'playwright-cli eval "document.cookie"', 'playwright-cli --version']) {
    assert.deepEqual(decide(command), { verdict: 'none' }, command);
  }
  assert.deepEqual(consent.evaluate({ command: undefined }), { verdict: 'none' });
});

test('commandMarkers reads both markers from quote-stripped text in any letter case, and the environment session', () => {
  const pick = (marks) => ({ cli: marks.cli, session: marks.session });
  assert.deepEqual(pick(consent.commandMarkers(`playwright-cl''i -s=${SESSION} eval 1`, {})), { cli: true, session: true });
  assert.deepEqual(pick(consent.commandMarkers('PLAYWRIGHT-CLI -s=ZENSU-VERIFY-RUN1 eval 1', {})), { cli: true, session: true });
  assert.deepEqual(pick(consent.commandMarkers('npx @playwright\\/cli snapshot', {})), { cli: true, session: false });
  assert.deepEqual(pick(consent.commandMarkers('zensu-ver"ify-x', {})), { cli: false, session: true });
  assert.deepEqual(pick(consent.commandMarkers('playwright-cli snapshot', { PLAYWRIGHT_CLI_SESSION: 'Zensu-Verify-x' })), { cli: true, session: true });
  assert.deepEqual(pick(consent.commandMarkers('playwright-cli -s=mine snapshot', {})), { cli: true, session: false });
  assert.deepEqual(pick(consent.commandMarkers('ls -la', {})), { cli: false, session: false });
});

test('the CLI markers are derived from the binary names and the package, and each one marks a command', () => {
  const derived = [...new Set(consent.CLI_BASENAMES.map((name) => name.replace(/\.(cmd|exe|ps1)$/i, '').toLowerCase()))];
  assert.deepEqual([...consent.CLI_MARKERS], [...derived, consent.CLI_PACKAGE.toLowerCase()]);
  for (const name of [...consent.CLI_BASENAMES, consent.CLI_PACKAGE]) {
    assert.equal(consent.commandMarkers(`${name} -s=${SESSION} snapshot`, {}).cli, true, name);
    assert.equal(consent.commandMarkers(`${name.toUpperCase()} snapshot`, {}).cli, true, name);
  }
});

test('the environment session marker alone changes a verdict', () => {
  const env = { PLAYWRIGHT_CLI_SESSION: SESSION };
  const piped = 'echo http://127.0.0.1:4200/ | xargs playwright-cli goto';
  const heredoc = 'bash <<EOF\nplaywright-cli goto http://127.0.0.1:4200/\nEOF';
  assert.equal(denied(piped, { env }), REASONS.INDIRECT);
  assert.equal(denied(heredoc, { env }), REASONS.UNJUDGED_BODY);
  assert.deepEqual(decide(piped), { verdict: 'none' });
  assert.deepEqual(decide(heredoc), { verdict: 'none' });
  for (const command of ['playwright-cli -s=a -s=b snapshot', 'playwright-cli -s=a --session=b snapshot']) {
    assert.equal(denied(command, { env }), REASONS.SESSION_MALFORMED, command);
    assert.deepEqual(decide(command), { verdict: 'none' }, command);
  }
  for (const command of ["$'playwright-cli' goto http://127.0.0.1:4200/", 'playwright-cli -s=other snapshot && ls']) {
    assert.equal(denied(command, { env }), REASONS.NOT_PLAIN, command);
    assert.deepEqual(decide(command), { verdict: 'none' }, command);
  }
});

test('the environment session marker alone arms the size bound, the unexpanded arms, the unjudged bodies and the redefinition check', () => {
  const env = { PLAYWRIGHT_CLI_SESSION: SESSION };
  const pairs = [
    [`playwright-cli eval 1 #${'x'.repeat(262145)}`, REASONS.COMMAND_TOO_LARGE],
    ['playwright-cli -s=$S goto http://127.0.0.1:4200/', REASONS.SESSION_UNEXPANDED],
    ['playwright-cli -s=mine $ARGS eval 1', REASONS.ARGUMENT_UNEXPANDED],
    ["bash <<< 'playwright-cli goto http://127.0.0.1:4200/'", REASONS.UNJUDGED_BODY],
    ["$($($($(bash -c 'playwright-cli goto http://127.0.0.1:4200/'))))", REASONS.UNJUDGED_BODY],
    ['playwright-cli() { :; }; playwright-cli goto http://127.0.0.1:4200/', REASONS.REDEFINED],
  ];
  for (const [command, reason] of pairs) {
    assert.equal(consent.commandMarkers(command, {}).named, false, command.slice(0, 60));
    assert.equal(denied(command, { env }), reason, command.slice(0, 60));
    assert.deepEqual(decide(command), { verdict: 'none' }, command.slice(0, 60));
  }
});

test('a backslash-newline continuation inside either marker is joined before the markers are read', () => {
  const pick = (marks) => ({ cli: marks.cli, session: marks.session });
  assert.deepEqual(pick(consent.commandMarkers('playwright-\\\ncli -s=zensu-verify-a eval 1', {})), { cli: true, session: true });
  assert.deepEqual(pick(consent.commandMarkers('playwright-cli -s zensu-verify\\\n-a eval 1', {})), { cli: true, session: true });
  assert.deepEqual(pick(consent.commandMarkers('playwright-\\\r\ncli -s zensu-verify\\\r\n-a eval 1', {})), { cli: true, session: true });
  assert.equal(denied('playwright-\\\ncli -s=zensu-verify-a eval 1'), `command 'eval' ${REASONS.COMMAND_DENIED}`);
  assert.equal(denied('playwright-cli -s zensu-verify\\\n-a eval 1'), `command 'eval' ${REASONS.COMMAND_DENIED}`);
  assert.equal(decide('playwright-\\\ncli -s=zensu-verify-a goto http://127.0.0.1:4200/').verdict, 'ask');
  assert.deepEqual(decide('playwright-\\\ncli -s=mine eval 1'), { verdict: 'none' });
});

test('a case variant of the CLI is refused as not bare, and a quote-split spelling is judged like the literal name', () => {
  assert.equal(denied(`Playwright-cli -s=${SESSION} eval 1`), REASONS.CLI_NOT_BARE);
  assert.equal(denied(`playwright-cl''i -s=${SESSION} eval 1`), `command 'eval' ${REASONS.COMMAND_DENIED}`);
  assert.equal(denied(`/usr/local/bin/PLAYWRIGHT-CLI.EXE -s=${SESSION} eval 1`), REASONS.CLI_NOT_BARE);
  assert.equal(denied(`Playwright-cli -s=${SESSION} goto http://127.0.0.1:4200/`), REASONS.CLI_NOT_BARE);
  assert.deepEqual(decide('Playwright-cli -s=mine eval 1'), { verdict: 'none' });
});

test('page-state, scripting and process commands are refused on a zensu-verify session', () => {
  const cases = [
    ['eval', 'eval "document.title"'],
    ['run-code', 'run-code "async page => page.title()"'],
    ['cookie-list', 'cookie-list'],
    ['cookie-set', 'cookie-set name value'],
    ['localstorage-get', 'localstorage-get key'],
    ['sessionstorage-list', 'sessionstorage-list'],
    ['state-save', 'state-save state.json'],
    ['state-load', 'state-load state.json'],
    ['attach', 'attach'],
    ['install-browser', 'install-browser'],
    ['close-all', 'close-all'],
    ['kill-all', 'kill-all'],
    ['route', 'route "**/*"'],
    ['upload', 'upload ./file.txt'],
  ];
  for (const [command, rest] of cases) assert.equal(denied(cli(rest)), `command '${command}' ${REASONS.COMMAND_DENIED}`, rest);
});

test('the command and flag refusals name /zensu:verify-feature and forbid a retry under another session or program', () => {
  for (const reason of [REASONS.COMMAND_DENIED, REASONS.FLAG_DENIED]) {
    assert.match(reason, /\/zensu:verify-feature/);
    assert.match(reason, /do not retry it under another session name or through another program/);
  }
  assert.equal(denied(cli('eval 1')),
    "command 'eval' is not available in a /zensu:verify-feature browser session; do not retry it under another session name or through another program");
});

test('an unknown, denied or repeated flag is refused and the harmless flags pass everywhere', () => {
  assert.equal(denied(cli('goto --foo http://127.0.0.1:4200/')), `flag '--foo' ${REASONS.FLAG_DENIED}`);
  assert.equal(denied(cli('screenshot --filename=shot.png')), `flag '--filename' ${REASONS.FLAG_DENIED}`);
  assert.equal(denied(cli('open --save-video=run.webm --config=/tmp/playwright-cli.json')), `flag '--save-video' ${REASONS.FLAG_DENIED}`);
  assert.equal(denied(cli('snapshot --depth=3 --depth=4')), "flag '--depth' is given more than once");
  assert.equal(denied(cli('open --config=/a.json --config=/b.json')), "flag '--config' is given more than once");
  assert.deepEqual(decide(cli('snapshot --json')), { verdict: 'none', plan: [] });
  assert.deepEqual(decide(cli('close --help')), { verdict: 'none', plan: [] });
  assert.deepEqual(decide(cli('list --all --version')), { verdict: 'none', plan: [] });
  assert.equal(decide(cli('goto --raw http://127.0.0.1:4200/')).verdict, 'ask');
});

test('open needs an absolute --config naming an existing run config', (t) => {
  const missing = path.join(tempDir(t), consent.RUN_CONFIG_NAME);
  assert.equal(denied(cli('open http://127.0.0.1:4200/')), REASONS.CONFIG_REQUIRED);
  assert.equal(denied(cli('open --config=relative/playwright-cli.json http://127.0.0.1:4200/')), REASONS.CONFIG_REQUIRED);
  assert.equal(denied(openCommand(missing, 'http://127.0.0.1:4200/')), 'the --config file does not exist');
});

test('open admits a Chromium channel and refuses any other browser', (t) => {
  const { file } = runConfig(t, ['http://127.0.0.1:4200']);
  const env = isolatedEnv(t);
  for (const browser of ['firefox', 'webkit']) {
    assert.equal(denied(openCommand(file, `--browser=${browser} http://127.0.0.1:4200/`), { env }), REASONS.BROWSER_NOT_CHROMIUM, browser);
  }
  for (const rest of ['--browser=msedge http://127.0.0.1:4200/', '--browser=chrome http://127.0.0.1:4200/', 'http://127.0.0.1:4200/']) {
    assert.equal(decide(openCommand(file, rest), { env }).verdict, 'ask', rest);
  }
});

test('open asks for every origin its run config allows and refuses a target outside it', (t) => {
  const { file } = runConfig(t, ['http://127.0.0.1:4200', 'http://[::1]:4201']);
  const env = isolatedEnv(t);
  const bare = decide(openCommand(file), { env });
  assert.equal(bare.verdict, 'ask');
  assert.deepEqual(bare.origins, ['http://127.0.0.1:4200', 'http://[::1]:4201']);
  assert.deepEqual(bare.plan, [
    { origin: 'http://127.0.0.1:4200', route: '/', decidedBy: 'asked' },
    { origin: 'http://[::1]:4201', route: '/', decidedBy: 'asked' },
  ]);
  assert.match(bare.prompt, /approves these origins/);
  const routed = decide(openCommand(file, 'http://127.0.0.1:4200/login'), { env });
  assert.deepEqual(routed.plan[0], { origin: 'http://127.0.0.1:4200', route: '/login', decidedBy: 'asked' });
  assert.equal(denied(openCommand(file, 'http://127.0.0.1:4299/'), { env }), REASONS.OPEN_OUTSIDE_CONFIG);
});

test('open refuses an ambient PLAYWRIGHT_MCP_ override and a global config that selects another browser', (t) => {
  const { file } = runConfig(t, ['http://127.0.0.1:4200']);
  const env = isolatedEnv(t);
  for (const name of ['PLAYWRIGHT_MCP_CONFIG', 'PLAYWRIGHT_MCP_PROXY_SERVER', 'PLAYWRIGHT_MCP_ALLOWED_ORIGINS']) {
    assert.equal(denied(openCommand(file, 'http://127.0.0.1:4200/'), { env: { ...env, [name]: 'x' } }),
      `the launch environment sets ${name}, which overrides the run config`, name);
  }
  assert.equal(decide(openCommand(file, 'http://127.0.0.1:4200/'), { env: { ...env, PLAYWRIGHT_MCP_CONFIG: '' } }).verdict, 'ask');
  writeGlobal(env, { browser: { browserName: 'firefox' } });
  assert.equal(denied(openCommand(file, 'http://127.0.0.1:4200/'), { env }), REASONS.GLOBAL_BROWSER_NOT_CHROMIUM);
});

test('a first loopback navigation asks with a prompt naming the session, the origin and the declared routes', () => {
  const decision = decide(cli('goto http://127.0.0.1:4200/login'), { declaredRoutes: ['/', '/login'] });
  assert.equal(decision.verdict, 'ask');
  assert.equal(decision.reason, REASONS.NEW_ORIGIN);
  assert.deepEqual(decision.origins, ['http://127.0.0.1:4200']);
  assert.deepEqual(decision.plan, [{ origin: 'http://127.0.0.1:4200', route: '/login', decidedBy: 'asked' }]);
  assert.equal(decision.prompt, consent.promptText({ origins: ['http://127.0.0.1:4200'], session: SESSION, declaredRoutes: ['/', '/login'] }));
  assert.match(decision.prompt, /zensu-verify-run1 is about to reach http:\/\/127\.0\.0\.1:4200 \(local loopback\)/);
  assert.match(decision.prompt, /synthetic-safe: \/, \/login\./);
});

test('a remembered origin passes without a prompt on any route while another origin still asks', () => {
  const records = [record('http://127.0.0.1:4200', '/login')];
  assert.deepEqual(decide(cli('goto http://127.0.0.1:4200/admin'), { records }),
    { verdict: 'none', plan: [{ origin: 'http://127.0.0.1:4200', route: '/admin', decidedBy: 'remembered' }] });
  assert.deepEqual(decide(cli('tab-new http://127.0.0.1:4200/'), { records }),
    { verdict: 'none', plan: [{ origin: 'http://127.0.0.1:4200', route: '/', decidedBy: 'remembered' }] });
  assert.equal(decide(cli('goto http://127.0.0.1:4201/admin'), { records }).verdict, 'ask');
});

test('two navigations in one command are refused as not one plain call, and one navigation asks once', () => {
  assert.equal(denied(`${cli('goto http://127.0.0.1:4200/a')} && ${cli('tab-new http://127.0.0.1:4200/b')}`), REASONS.NOT_PLAIN);
  const decision = decide(cli('tab-new http://127.0.0.1:4200/b'));
  assert.equal(decision.verdict, 'ask');
  assert.deepEqual(decision.origins, ['http://127.0.0.1:4200']);
  assert.deepEqual(decision.plan.map((entry) => entry.route), ['/b']);
  assert.match(decision.prompt, /approves this origin/);
});

test('consent mode refuses a remote target and every navigation the floor refuses', () => {
  assert.equal(denied(cli('goto https://app.example.com/')), REASONS.REMOTE_NEEDS_POLICY);
  assert.equal(denied(cli('tab-new https://93.184.216.34/')), REASONS.REMOTE_NEEDS_POLICY);
  const floorCases = [
    ['http://localhost:4200/', FLOOR_REASONS.LOCAL_LITERAL_LOOPBACK],
    ['http://10.0.0.5/', FLOOR_REASONS.REMOTE_HTTPS],
    ['https://10.0.0.5/', FLOOR_REASONS.REMOTE_NOT_PUBLIC],
    ['http://user:pw@127.0.0.1:4200/', FLOOR_REASONS.CREDENTIALS],
    ['http://127.0.0.1:4200/?token=1', FLOOR_REASONS.QUERY_OR_FRAGMENT],
    ['file:///etc/passwd', FLOOR_REASONS.SCHEME],
    ['not-a-url', FLOOR_REASONS.INVALID],
  ];
  for (const [url, reason] of floorCases) assert.equal(denied(cli(`goto '${url}'`)), reason, url);
  assert.equal(denied(cli('goto http://127.0.0.1:4200/?token=1')), REASONS.ARGUMENT_UNEXPANDED);
});

test('consent mode refuses an open whose run config names a remote origin, even toward a loopback target', (t) => {
  const env = isolatedEnv(t);
  const pin = ['MAP app.example.com 93.184.216.34'];
  const mixed = runConfig(t, ['http://127.0.0.1:4200', 'https://app.example.com'], pin);
  assert.equal(denied(openCommand(mixed.file, 'http://127.0.0.1:4200/'), { env }), REASONS.REMOTE_NEEDS_POLICY);
  const remote = runConfig(t, ['https://app.example.com'], pin);
  assert.equal(denied(openCommand(remote.file), { env }), REASONS.REMOTE_NEEDS_POLICY);
  const local = runConfig(t, ['http://127.0.0.1:4200']);
  assert.equal(decide(openCommand(local.file, 'http://127.0.0.1:4200/'), { env }).verdict, 'ask');
});

test('a subagent is refused on a zensu-verify session and ignored on any other call', () => {
  for (const payload of [SUBAGENT, { agent_id: 'r1', agent_type: 'zensu:code-reviewer' }, { agent_type: 'general-purpose' }]) {
    assert.equal(denied(cli('goto http://127.0.0.1:4200/'), { payload }), REASONS.NOT_MAIN_THREAD, JSON.stringify(payload));
  }
  assert.deepEqual(decide('playwright-cli -s=mine snapshot', { payload: SUBAGENT }), { verdict: 'none' });
});

test('policy mode admits a declared route of a policy target without a prompt and refuses the rest', () => {
  const policy = policyOf('local', [LOCAL_TARGET]);
  assert.deepEqual(decide(cli('goto http://127.0.0.1:4300/login'), { policy }),
    { verdict: 'none', plan: [{ origin: 'http://127.0.0.1:4300', route: '/login', decidedBy: 'policy-mode' }] });
  assert.equal(denied(cli('goto http://127.0.0.1:4301/'), { policy }), `http://127.0.0.1:4301: ${REASONS.NOT_POLICY_TARGET}`);
  assert.equal(denied(cli('goto http://127.0.0.1:4300/admin'), { policy }), `http://127.0.0.1:4300/admin: ${REASONS.NOT_POLICY_ROUTE}`);
  assert.equal(denied(cli('goto http://localhost:4300/'), { policy }), FLOOR_REASONS.LOCAL_LITERAL_LOOPBACK);
  assert.deepEqual(decide(cli('snapshot'), { policy }), { verdict: 'none', plan: [] });
  const invalid = consent.readPolicy({ ZENSU_VERIFY_NAVIGATION_POLICY_V1: '{"version":1}' });
  assert.equal(denied(cli('goto http://127.0.0.1:4300/'), { policy: invalid }), `${REASONS.POLICY_INVALID}: policy contains unknown or missing keys`);
});

test('policy mode judges the run config against the policy and needs a resolver pin for a remote host', (t) => {
  const env = isolatedEnv(t);
  const local = policyOf('local', [LOCAL_TARGET]);
  const inside = runConfig(t, ['http://127.0.0.1:4300']);
  assert.deepEqual(decide(openCommand(inside.file), { env, policy: local }),
    { verdict: 'none', plan: [{ origin: 'http://127.0.0.1:4300', route: '/', decidedBy: 'policy-mode' }] });
  const outside = runConfig(t, ['http://127.0.0.1:4301']);
  assert.equal(denied(openCommand(outside.file), { env, policy: local }), `http://127.0.0.1:4301: ${REASONS.NOT_POLICY_TARGET}`);
  const remote = policyOf('remote', [{ origin: 'https://app.example.com', routes: ['/'], evidenceMode: 'declared-safe' }]);
  const unpinned = runConfig(t, ['https://app.example.com']);
  assert.equal(denied(openCommand(unpinned.file), { env, policy: remote }),
    'https://app.example.com: the run config carries no resolver pin for this remote host');
  const pinned = runConfig(t, ['https://app.example.com'], ['MAP app.example.com 93.184.216.34']);
  assert.deepEqual(decide(openCommand(pinned.file, 'https://app.example.com/'), { env, policy: remote }),
    { verdict: 'none', plan: [{ origin: 'https://app.example.com', route: '/', decidedBy: 'policy-mode' }] });
});

test('a command beyond the size bound is refused only when it names a zensu-verify session', () => {
  const padding = 'x'.repeat(262145);
  assert.equal(denied(`${cli('snapshot')} # ${padding}`), REASONS.COMMAND_TOO_LARGE);
  assert.deepEqual(decide(`playwright-cli snapshot # ${padding}`), { verdict: 'none' });
});

test('a gated command the lexer cannot close is refused as unjudged', () => {
  assert.equal(denied(cli("goto 'http://127.0.0.1:4200/")), REASONS.UNJUDGED_BODY);
});

test('a run config written from buildConfig passes and reports its origins and pins', (t) => {
  const { file, config } = runConfig(t, ['http://127.0.0.1:4200', 'http://[::1]:4201']);
  const shape = consent.runConfigShape(config, file);
  assert.equal(shape.ok, true);
  assert.deepEqual(shape.origins, ['http://127.0.0.1:4200', 'http://[::1]:4201']);
  assert.equal(shape.pins.size, 0);
  const read = consent.readRunConfig(file);
  assert.equal(read.ok, true);
  assert.equal(read.configPath, file);
  assert.deepEqual(read.origins, shape.origins);
});

test('the run config refuses extra keys, a proxy and a loosened browser or context block', (t) => {
  const { file, config } = runConfig(t, ['http://127.0.0.1:4200']);
  const variant = (mutate) => {
    const copy = structuredClone(config);
    mutate(copy);
    return consent.runConfigShape(copy, file).fault;
  };
  assert.equal(variant((c) => { c.extensions = []; }), 'the run config carries keys beyond browser, network and outputDir');
  assert.equal(variant((c) => { c.browser.userDataDir = '/tmp/profile'; }), 'the run config browser block carries unexpected keys');
  assert.equal(variant((c) => { c.browser.isolated = false; }), 'the run config must keep the browser isolated');
  assert.equal(variant((c) => { c.browser.launchOptions.proxy = { server: 'http://proxy.example.com:8080' }; }),
    'the run config launchOptions carry unexpected keys');
  assert.equal(variant((c) => { c.browser.launchOptions.args = ['--proxy-server=http://proxy.example.com:8080']; }),
    'the run config launch arguments must be --no-proxy-server and at most one resolver pin list');
  assert.equal(variant((c) => { c.browser.launchOptions.args.push('--proxy-server=http://proxy.example.com:8080'); }),
    'the run config carries a launch argument other than a resolver pin list');
  assert.equal(variant((c) => { c.browser.contextOptions.serviceWorkers = 'allow'; }),
    'the run config must block service workers and set nothing else on the context');
  assert.equal(variant((c) => { c.browser.contextOptions.viewport = { width: 1, height: 1 }; }),
    'the run config must block service workers and set nothing else on the context');
  assert.equal(variant((c) => { c.network.blockedOrigins = []; }), 'the run config network block carries unexpected keys');
});

test('the run config refuses an empty, oversized, invalid, non-canonical or repeated origin list', (t) => {
  const { file, config } = runConfig(t, ['http://127.0.0.1:4200']);
  const withOrigins = (origins) => consent.runConfigShape({ ...config, network: { allowedOrigins: origins } }, file).fault;
  const bounds = `the run config must allow between 1 and ${consent.MAX_RUN_ORIGINS} origins`;
  assert.equal(withOrigins([]), bounds);
  assert.equal(withOrigins(Array.from({ length: consent.MAX_RUN_ORIGINS + 1 }, (_unused, index) => `http://127.0.0.1:${4200 + index}`)), bounds);
  assert.equal(withOrigins('http://127.0.0.1:4200'), bounds);
  assert.equal(withOrigins([4200]), 'the run config names a non-string origin');
  assert.equal(withOrigins(['not a url']), 'the run config names an invalid origin');
  assert.equal(withOrigins(['http://127.0.0.1:4200/']), 'the run config names an origin that is not in canonical form');
  assert.equal(withOrigins(['HTTP://127.0.0.1:4200']), 'the run config names an origin that is not in canonical form');
  assert.equal(withOrigins(['http://127.0.0.1:4200', 'http://127.0.0.1:4200']), 'the run config names an origin twice');
});

test('the run config pins only public addresses, only for hosts it allows, once each', (t) => {
  const { file, config } = runConfig(t, ['https://app.example.com']);
  const withRules = (rules) => {
    const copy = structuredClone(config);
    copy.browser.launchOptions.args = ['--no-proxy-server', `--host-resolver-rules=${rules}`];
    return consent.runConfigShape(copy, file);
  };
  const v4 = withRules('MAP app.example.com 93.184.216.34');
  assert.equal(v4.ok, true);
  assert.deepEqual([...v4.pins], [['app.example.com', '93.184.216.34']]);
  assert.deepEqual([...withRules('MAP app.example.com [2606:2800:220:1:248:1893:25c8:1946]').pins],
    [['app.example.com', '2606:2800:220:1:248:1893:25c8:1946']]);
  assert.equal(withRules('MAP app.example.com 10.0.0.5').fault, 'the run config pins a host to an address that is not globally routable');
  assert.equal(withRules('MAP app.example.com 127.0.0.1').fault, 'the run config pins a host to an address that is not globally routable');
  assert.equal(withRules('MAP other.example.com 93.184.216.34').fault, 'the run config pins a host that is not among its allowed origins');
  assert.equal(withRules('MAP 93.184.216.34 93.184.216.34').fault, 'the run config pins an address literal or pins a host twice');
  assert.equal(withRules('MAP app.example.com 93.184.216.34,MAP app.example.com 93.184.216.35').fault,
    'the run config pins an address literal or pins a host twice');
  assert.equal(withRules('EXCLUDE app.example.com').fault, 'the run config carries a resolver rule other than MAP <host> <address>');
});

test('the run config outputDir must be the absolute browser directory beside the file', (t) => {
  const { runDir, file, config } = runConfig(t, ['http://127.0.0.1:4200']);
  assert.equal(config.outputDir, path.join(runDir, consent.RUN_OUTPUT_DIR_NAME));
  assert.equal(consent.runConfigShape({ ...config, outputDir: 'browser' }, file).fault, 'the run config outputDir must be absolute');
  assert.equal(consent.runConfigShape({ ...config, outputDir: path.join(tempDir(t), 'browser') }, file).fault,
    'the run config outputDir must be the browser directory beside the config file');
  assert.equal(consent.runConfigShape(config, path.join(runDir, 'missing', consent.RUN_CONFIG_NAME)).fault,
    'the run config directory cannot be resolved');
});

test('readRunConfig refuses a relative, missing, non-regular, oversized or unparseable file', (t) => {
  const { runDir, file, config } = runConfig(t, ['http://127.0.0.1:4200']);
  const plain = 'the --config file is not a plain file within the size bound';
  assert.deepEqual(consent.readRunConfig(''), { ok: false, fault: REASONS.CONFIG_REQUIRED });
  assert.deepEqual(consent.readRunConfig('relative/playwright-cli.json'), { ok: false, fault: REASONS.CONFIG_REQUIRED });
  assert.deepEqual(consent.readRunConfig(path.join(runDir, 'absent.json')), { ok: false, fault: 'the --config file does not exist' });
  assert.deepEqual(consent.readRunConfig(runDir), { ok: false, fault: plain });
  const oversized = path.join(runDir, 'oversized.json');
  fs.writeFileSync(oversized, `${JSON.stringify(config)}${' '.repeat(16384)}`);
  assert.deepEqual(consent.readRunConfig(oversized), { ok: false, fault: plain });
  const broken = path.join(runDir, 'broken.json');
  fs.writeFileSync(broken, '{');
  assert.deepEqual(consent.readRunConfig(broken), { ok: false, fault: 'the --config file is not valid JSON' });
  const extra = path.join(runDir, 'extra.json');
  fs.writeFileSync(extra, JSON.stringify({ ...config, extensions: [] }));
  assert.deepEqual(consent.readRunConfig(extra), { ok: false, fault: 'the run config carries keys beyond browser, network and outputDir' });
  if (process.platform !== 'win32') {
    const link = path.join(runDir, 'link.json');
    fs.symlinkSync(file, link);
    assert.deepEqual(consent.readRunConfig(link), { ok: false, fault: plain });
  }
});

test('the global config file sits under PWTEST_CLI_GLOBAL_CONFIG, else under the home directory', () => {
  assert.equal(consent.globalConfigFile({ PWTEST_CLI_GLOBAL_CONFIG: '/base' }), path.join('/base', '.playwright', 'cli.config.json'));
  assert.equal(consent.globalConfigFile({}), path.join(os.homedir(), '.playwright', 'cli.config.json'));
  assert.equal(consent.globalConfigFile({ PWTEST_CLI_GLOBAL_CONFIG: '' }), path.join(os.homedir(), '.playwright', 'cli.config.json'));
});

test('an absent or harmless global config is no fault', (t) => {
  const env = isolatedEnv(t);
  assert.equal(consent.globalConfigFault(env), '');
  writeGlobal(env, {
    browser: { browserName: 'chromium', launchOptions: { channel: 'chrome', headless: true } },
    timeouts: { action: 5000, navigation: 30000 },
    testIdAttribute: 'data-qa',
    console: { level: 'info' },
    snapshot: { mode: 'incremental' },
    outputMode: 'file',
    imageResponses: 'omit',
    codegen: 'none',
    network: { blockedOrigins: ['https://ads.example.com'] },
  });
  assert.equal(consent.globalConfigFault(env), '');
  writeGlobal(env, `${String.fromCharCode(0xfeff)}${JSON.stringify({ outputMode: 'file' })}`);
  assert.equal(consent.globalConfigFault(env), '');
});

test('a global config that selects another browser, sets any other key or cannot be judged is a fault', (t) => {
  const env = isolatedEnv(t);
  const merge = (keyPath) => `the global playwright-cli config sets ${keyPath}, which would merge under the run config`;
  const cases = [
    [{ browser: { browserName: 'firefox' } }, REASONS.GLOBAL_BROWSER_NOT_CHROMIUM],
    [{ browser: { isolated: false } }, merge('browser.isolated')],
    [{ browser: { launchOptions: { args: ['--proxy-server=http://proxy.example.com'] } } }, merge('browser.launchOptions.args')],
    [{ network: { allowedOrigins: ['*'] } }, merge('network.allowedOrigins')],
    [{ outputDir: '/tmp/elsewhere' }, merge('outputDir')],
    [[], merge('(root)')],
    ['{', 'the global playwright-cli config is not JSON the gate can judge'],
    [`${JSON.stringify({ outputMode: 'file' })}${' '.repeat(65536)}`, 'the global playwright-cli config is not a plain file within the size bound'],
  ];
  for (const [value, fault] of cases) {
    writeGlobal(env, value);
    assert.equal(consent.globalConfigFault(env), fault, JSON.stringify(value).slice(0, 60));
  }
  if (process.platform !== 'win32') {
    const file = consent.globalConfigFile(env);
    const target = path.join(path.dirname(file), 'target.json');
    fs.writeFileSync(target, JSON.stringify({ outputMode: 'file' }));
    fs.rmSync(file);
    fs.symlinkSync(target, file);
    assert.equal(consent.globalConfigFault(env), 'the global playwright-cli config is not a plain file within the size bound');
  }
});

test('validRecord and isIsoInstant accept exactly the recorded shape', () => {
  for (const decidedBy of consent.DECIDED_BY) {
    assert.equal(consent.validRecord(record('http://127.0.0.1:4200', '/', decidedBy)), true, decidedBy);
  }
  const base = record('http://127.0.0.1:4200');
  for (const bad of [null, {}, { ...base, origin: '' }, { ...base, route: 'login' }, { ...base, decidedBy: 'granted' },
    { ...base, at: '2026-09-22' }, { origin: base.origin, route: base.route, decidedBy: base.decidedBy }]) {
    assert.equal(Boolean(consent.validRecord(bad)), false, JSON.stringify(bad));
  }
  assert.equal(consent.isIsoInstant(AT), true);
  for (const bad of ['2026-09-22T12:00:00Z', '2026-02-31T00:00:00.000Z', '2026-09-22T12:00:00.000+00:00', 20260922, '']) {
    assert.equal(consent.isIsoInstant(bad), false, String(bad));
  }
});

test('the memory path must be the session file inside the real state directory', (t) => {
  const { root, memory } = project(t);
  const refused = { ok: false, reason: REASONS.MEMORY_PATH_REFUSED };
  assert.deepEqual(consent.memoryPathAllowed(memory, root), { ok: true, stateDir: path.join(root, '.zensu', 'state') });
  assert.deepEqual(consent.memoryPathAllowed(`verify-consent-${KEY}.json`, root), refused);
  assert.deepEqual(consent.memoryPathAllowed(memory, 'relative'), refused);
  assert.deepEqual(consent.memoryPathAllowed(path.join(root, '.zensu', 'state', 'verify-consent-other.json'), root), refused);
  assert.deepEqual(consent.memoryPathAllowed(path.join(root, `verify-consent-${KEY}.json`), root), refused);
  assert.deepEqual(consent.memoryPathAllowed(memory, path.join(root, 'missing')), refused);
});

test('a symlinked state component, a symlinked memory and a hard-linked memory are refused', { skip: process.platform === 'win32' }, (t) => {
  const refused = { ok: false, reason: REASONS.MEMORY_PATH_REFUSED };
  const name = `verify-consent-${KEY}.json`;
  const elsewhere = tempDir(t, 'zensu-elsewhere-');
  fs.mkdirSync(path.join(elsewhere, 'state'));
  const linkedState = tempDir(t);
  fs.mkdirSync(path.join(linkedState, '.zensu'));
  fs.symlinkSync(elsewhere, path.join(linkedState, '.zensu', 'state'));
  assert.deepEqual(consent.memoryPathAllowed(path.join(linkedState, '.zensu', 'state', name), linkedState), refused);
  const linkedZensu = tempDir(t);
  fs.symlinkSync(elsewhere, path.join(linkedZensu, '.zensu'));
  assert.deepEqual(consent.memoryPathAllowed(path.join(linkedZensu, '.zensu', 'state', name), linkedZensu), refused);
  const { root, memory } = project(t);
  const target = path.join(elsewhere, 'target.json');
  fs.writeFileSync(target, JSON.stringify({ version: 1, records: [] }));
  fs.symlinkSync(target, memory);
  assert.deepEqual(consent.memoryPathAllowed(memory, root), refused);
  assert.deepEqual(consent.readConsentMemory(memory, root), { ...refused, records: [] });
  fs.unlinkSync(memory);
  fs.writeFileSync(memory, JSON.stringify({ version: 1, records: [] }));
  fs.linkSync(memory, path.join(elsewhere, 'second-name.json'));
  assert.deepEqual(consent.memoryPathAllowed(memory, root), refused);
  assert.deepEqual(consent.appendRecord(memory, record('http://127.0.0.1:4200'), { projectRoot: root }), refused);
});

test('the session memory round trips appended records and skips a duplicate', (t) => {
  const { root, memory } = project(t);
  assert.deepEqual(consent.readConsentMemory('', root), { ok: true, records: [], absent: true });
  assert.deepEqual(consent.readConsentMemory(memory, root), { ok: true, records: [], absent: true });
  const first = consent.appendRecord(memory, record('http://127.0.0.1:4200', '/login'), { projectRoot: root });
  assert.equal(first.ok, true);
  assert.equal(first.duplicate, false);
  const again = consent.appendRecord(memory, record('http://127.0.0.1:4200', '/login', 'remembered'), { projectRoot: root });
  assert.equal(again.ok, true);
  assert.equal(again.duplicate, true);
  assert.equal(consent.appendRecord(memory, record('http://127.0.0.1:4200', '/admin', 'remembered'), { projectRoot: root }).ok, true);
  const read = consent.readConsentMemory(memory, root);
  assert.equal(read.ok, true);
  assert.equal(read.absent, false);
  assert.deepEqual(read.records, [record('http://127.0.0.1:4200', '/login'), record('http://127.0.0.1:4200', '/admin', 'remembered')]);
  assert.equal(JSON.parse(fs.readFileSync(memory, 'utf8')).version, consent.MEMORY_VERSION);
  assert.deepEqual(fs.readdirSync(path.dirname(memory)), [path.basename(memory)]);
  if (process.platform !== 'win32') assert.equal(fs.statSync(memory).mode & 0o777, 0o600);
});

test('appendRecord refuses an invalid record and a memory already at its record cap', (t) => {
  const { root, memory } = project(t);
  assert.deepEqual(consent.appendRecord(memory, { origin: 'http://127.0.0.1:4200' }, { projectRoot: root }), { ok: false, reason: 'record-invalid' });
  assert.equal(fs.existsSync(memory), false);
  const full = Array.from({ length: consent.MAX_RECORDS }, (_unused, index) => record('http://127.0.0.1:4200', `/r/${index}`));
  fs.writeFileSync(memory, JSON.stringify({ version: consent.MEMORY_VERSION, records: full }));
  assert.equal(consent.readConsentMemory(memory, root).ok, true);
  assert.deepEqual(consent.appendRecord(memory, record('http://127.0.0.1:4200', '/one-more'), { projectRoot: root }),
    { ok: false, reason: 'memory-full' });
});

test('appendRecord refuses a write that would push the memory past its own read cap', (t) => {
  const { root, memory } = project(t);
  const long = `/${'a'.repeat(300)}`;
  const records = [];
  for (let index = 0; ; index += 1) {
    const next = record('http://127.0.0.1:4200', `${long}/${index}`);
    const size = Buffer.byteLength(`${JSON.stringify({ version: consent.MEMORY_VERSION, records: [...records, next] })}\n`);
    if (size > consent.MAX_MEMORY_BYTES - 200) break;
    records.push(next);
  }
  assert.equal(records.length > 0 && records.length < consent.MAX_RECORDS, true);
  fs.writeFileSync(memory, `${JSON.stringify({ version: consent.MEMORY_VERSION, records })}\n`);
  assert.equal(consent.readConsentMemory(memory, root).ok, true);
  assert.deepEqual(consent.appendRecord(memory, record('http://127.0.0.1:4200', `/${'b'.repeat(600)}`), { projectRoot: root }),
    { ok: false, reason: 'memory-would-exceed-read-cap' });
});

test('a memory over its size or record cap, or carrying a malformed record, reads as unreadable and is never rewritten', (t) => {
  const { root, memory } = project(t);
  const unreadable = { ok: false, reason: REASONS.MEMORY_UNREADABLE, records: [] };
  fs.writeFileSync(memory, `${JSON.stringify({ version: 1, records: [] })}${' '.repeat(consent.MAX_MEMORY_BYTES)}`);
  assert.deepEqual(consent.readConsentMemory(memory, root), unreadable);
  const tooMany = Array.from({ length: consent.MAX_RECORDS + 1 }, (_unused, index) => record('http://127.0.0.1:4200', `/r/${index}`));
  fs.writeFileSync(memory, JSON.stringify({ version: 1, records: tooMany }));
  assert.deepEqual(consent.readConsentMemory(memory, root), unreadable);
  const bodies = ['{', '[]', JSON.stringify({ version: 2, records: [] }), JSON.stringify({ version: 1, records: {} }),
    JSON.stringify({ version: 1, records: [{ ...record('http://127.0.0.1:4200'), decidedBy: 'granted' }] })];
  for (const body of bodies) {
    fs.writeFileSync(memory, body);
    assert.deepEqual(consent.readConsentMemory(memory, root), unreadable, body);
  }
  assert.deepEqual(consent.appendRecord(memory, record('http://127.0.0.1:4201'), { projectRoot: root }),
    { ok: false, reason: REASONS.MEMORY_UNREADABLE });
  assert.equal(fs.readFileSync(memory, 'utf8'), bodies[bodies.length - 1]);
});

test('runPre writes nothing for a non-Bash or unrelated call and denies an unreadable payload', () => {
  const out = sink();
  const err = sink();
  assert.equal(consent.runPre({ tool_name: 'Read', tool_input: { file_path: '/x/playwright-cli' } }, {}, out, err), false);
  assert.equal(consent.runPre(bash('ls -la'), {}, out, err), false);
  assert.equal(out.text(), '');
  assert.equal(consent.runPre(null, {}, out, err), true);
  assert.deepEqual(JSON.parse(out.text()), consent.preEnvelope({ verdict: 'deny', reason: REASONS.PAYLOAD_UNREADABLE }));
  const nameless = sink();
  assert.equal(consent.runPre({ tool_input: {} }, {}, nameless, err), true);
  assert.equal(JSON.parse(nameless.text()).hookSpecificOutput.permissionDecision, 'deny');
  assert.equal(err.text(), '');
});

test('runPre emits the ask and deny envelopes in the PreToolUse shape', () => {
  const err = sink();
  const asked = sink();
  assert.equal(consent.runPre(bash(cli('goto http://127.0.0.1:4200/login')), {}, asked, err), true);
  assert.deepEqual(JSON.parse(asked.text()), {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'ask',
      permissionDecisionReason: consent.promptText({ origins: ['http://127.0.0.1:4200'], session: SESSION, declaredRoutes: [] }),
    },
  });
  const refused = sink();
  assert.equal(consent.runPre(bash(cli('eval 1')), {}, refused, err), true);
  assert.deepEqual(JSON.parse(refused.text()), {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: `${DENIED}command 'eval' ${REASONS.COMMAND_DENIED}`,
    },
  });
  assert.equal(err.text(), '');
});

test('runPre reads the session memory and the recipe routes its environment names', (t) => {
  const { root, memory } = project(t);
  fs.writeFileSync(path.join(root, '.zensu', 'runtime.yaml'), ['version: 1', 'validate:', '  evidenceSafety:', '    routes: ["/", "/login"]', ''].join('\n'));
  const env = { ZENSU_VERIFY_PROJECT_ROOT: root, ZENSU_VERIFY_CONSENT_MEMORY: memory };
  const asked = sink();
  assert.equal(consent.runPre(bash(cli('goto http://127.0.0.1:4200/login')), env, asked, sink()), true);
  assert.match(JSON.parse(asked.text()).hookSpecificOutput.permissionDecisionReason, /synthetic-safe: \/, \/login\./);
  assert.equal(consent.appendRecord(memory, record('http://127.0.0.1:4200', '/login'), { projectRoot: root }).ok, true);
  const quiet = sink();
  assert.equal(consent.runPre(bash(cli('goto http://127.0.0.1:4200/other')), env, quiet, sink()), false);
  assert.equal(quiet.text(), '');
});

test('runPre discloses an unreadable memory on stderr and asks again', (t) => {
  const { root, memory } = project(t);
  fs.writeFileSync(memory, '{');
  const env = { ZENSU_VERIFY_PROJECT_ROOT: root, ZENSU_VERIFY_CONSENT_MEMORY: memory };
  const out = sink();
  const err = sink();
  assert.equal(consent.runPre(bash(cli('goto http://127.0.0.1:4200/')), env, out, err), true);
  assert.equal(JSON.parse(out.text()).hookSpecificOutput.permissionDecision, 'ask');
  assert.equal(err.text(), `zensu: verify consent memory ignored (${REASONS.MEMORY_UNREADABLE}); the call asks again\n`);
});

test('runPre answers policy mode from the launch environment without a prompt', () => {
  const env = { ZENSU_VERIFY_NAVIGATION_POLICY_V1: JSON.stringify({ version: 1, mode: 'local', targets: [LOCAL_TARGET] }) };
  const quiet = sink();
  assert.equal(consent.runPre(bash(cli('goto http://127.0.0.1:4300/login')), env, quiet, sink()), false);
  assert.equal(quiet.text(), '');
  const refused = sink();
  assert.equal(consent.runPre(bash(cli('goto http://127.0.0.1:4300/admin')), env, refused, sink()), true);
  assert.equal(JSON.parse(refused.text()).hookSpecificOutput.permissionDecisionReason,
    `${DENIED}http://127.0.0.1:4300/admin: ${REASONS.NOT_POLICY_ROUTE}`);
});

test('runPre denies a subagent on a zensu-verify session', () => {
  const out = sink();
  assert.equal(consent.runPre(bash(cli('snapshot'), SUBAGENT), {}, out, sink()), true);
  assert.equal(JSON.parse(out.text()).hookSpecificOutput.permissionDecisionReason, `${DENIED}${REASONS.NOT_MAIN_THREAD}`);
});

test('runPost records the asked, remembered and policy-mode decisions it sees', (t) => {
  const { root, memory } = project(t);
  const env = { ZENSU_VERIFY_PROJECT_ROOT: root, ZENSU_VERIFY_CONSENT_MEMORY: memory };
  const err = sink();
  const first = consent.runPost(post(cli('goto http://127.0.0.1:4200/login')), env, err);
  assert.equal(first.ok, true);
  assert.equal(first.duplicate, false);
  assert.equal(consent.runPost(post(cli('goto http://127.0.0.1:4200/admin')), env, err).ok, true);
  const policyEnv = { ...env, ZENSU_VERIFY_NAVIGATION_POLICY_V1: JSON.stringify({ version: 1, mode: 'local', targets: [LOCAL_TARGET] }) };
  assert.equal(consent.runPost(post(cli('goto http://127.0.0.1:4300/')), policyEnv, err).ok, true);
  const read = consent.readConsentMemory(memory, root);
  assert.equal(read.ok, true);
  assert.deepEqual(read.records.map(({ origin, route, decidedBy }) => ({ origin, route, decidedBy })), [
    { origin: 'http://127.0.0.1:4200', route: '/login', decidedBy: 'asked' },
    { origin: 'http://127.0.0.1:4200', route: '/admin', decidedBy: 'remembered' },
    { origin: 'http://127.0.0.1:4300', route: '/', decidedBy: 'policy-mode' },
  ]);
  for (const entry of read.records) assert.equal(consent.isIsoInstant(entry.at), true);
  assert.equal(err.text(), '');
});

test('runPost records nothing for a denied, interrupted, non-Bash, target-free or unbound call', (t) => {
  const { root, memory } = project(t);
  const env = { ZENSU_VERIFY_PROJECT_ROOT: root, ZENSU_VERIFY_CONSENT_MEMORY: memory };
  const err = sink();
  assert.deepEqual(consent.runPost(post(cli('eval 1')), env, err), { ok: true, skipped: `command 'eval' ${REASONS.COMMAND_DENIED}` });
  assert.deepEqual(consent.runPost(post(cli('goto https://app.example.com/')), env, err), { ok: true, skipped: REASONS.REMOTE_NEEDS_POLICY });
  assert.deepEqual(consent.runPost(post(cli('goto http://127.0.0.1:4200/'), { tool_response: { interrupted: true } }), env, err),
    { ok: true, skipped: 'interrupted' });
  assert.deepEqual(consent.runPost({ tool_name: 'Read', tool_input: {} }, env, err), { ok: true, skipped: 'not-a-bash-call' });
  assert.deepEqual(consent.runPost(post('ls -la'), env, err), { ok: true, skipped: 'nothing-to-record' });
  assert.deepEqual(consent.runPost(post(cli('snapshot')), env, err), { ok: true, skipped: 'nothing-to-record' });
  assert.equal(err.text(), '');
  assert.equal(fs.existsSync(memory), false);
  const unbound = sink();
  assert.deepEqual(consent.runPost(post(cli('goto http://127.0.0.1:4200/')), {}, unbound), { ok: false, reason: 'no-bound-session' });
  assert.equal(unbound.text(), 'zensu: verify consent memory not written (no bound session)\n');
  const unreadable = sink();
  assert.deepEqual(consent.runPost(null, env, unreadable), { ok: false, reason: REASONS.PAYLOAD_UNREADABLE });
  assert.equal(unreadable.text(), `zensu: verify consent memory not written (${REASONS.PAYLOAD_UNREADABLE})\n`);
});

test('runPost reports a refused memory path and writes nothing there', (t) => {
  const { root } = project(t);
  const outside = path.join(root, `verify-consent-${KEY}.json`);
  const err = sink();
  assert.deepEqual(consent.runPost(post(cli('goto http://127.0.0.1:4200/')), { ZENSU_VERIFY_PROJECT_ROOT: root, ZENSU_VERIFY_CONSENT_MEMORY: outside }, err),
    { ok: false, reason: REASONS.MEMORY_PATH_REFUSED });
  assert.equal(err.text(), `zensu: verify consent memory not written (${REASONS.MEMORY_PATH_REFUSED})\n`);
  assert.equal(fs.existsSync(outside), false);
});

const registrationEntry = (file) => ({ type: 'command', command: `bash "\${CLAUDE_PLUGIN_ROOT}/hooks/${file}"` });
const registrationRoot = (t, manifest, files = [consent.CONSENT_HOOK_FILE, consent.CONSENT_RECORDER_FILE]) => {
  const root = tempDir(t, 'zensu-plugin-');
  fs.mkdirSync(path.join(root, 'hooks'));
  for (const file of files) fs.writeFileSync(path.join(root, 'hooks', file), '#!/bin/bash\n');
  if (manifest !== undefined) {
    fs.writeFileSync(path.join(root, 'hooks', 'hooks.json'), typeof manifest === 'string' ? manifest : JSON.stringify(manifest));
  }
  return root;
};
const registrationManifest = (hookMatcher, recorderMatcher) => ({
  hooks: {
    PreToolUse: [{ matcher: hookMatcher, hooks: [registrationEntry(consent.CONSENT_HOOK_FILE)] }],
    PostToolUse: [{ matcher: recorderMatcher, hooks: [registrationEntry(consent.CONSENT_RECORDER_FILE)] }],
  },
});

test('the registration probes find both hooks on the Bash matcher of this plugin', () => {
  assert.deepEqual(consent.REGISTRATION, { REGISTERED: 'registered', UNREGISTERED: 'unregistered', UNKNOWN: 'unknown' });
  assert.equal(Object.isFrozen(consent.REGISTRATION), true);
  assert.equal(consent.consentHookRegistered(REPO_ROOT), consent.REGISTRATION.REGISTERED);
  assert.equal(consent.consentRecorderRegistered(REPO_ROOT), consent.REGISTRATION.REGISTERED);
});

test('the registration probes follow the host matcher rule and refuse another matcher, a swapped event, a missing hook file and a missing root', (t) => {
  const { REGISTERED, UNREGISTERED } = consent.REGISTRATION;
  const control = registrationRoot(t, registrationManifest('Bash', 'Bash'));
  assert.equal(consent.consentHookRegistered(control), REGISTERED);
  assert.equal(consent.consentRecorderRegistered(control), REGISTERED);
  const widened = registrationRoot(t, registrationManifest('Bash|Read', ''));
  assert.equal(consent.consentHookRegistered(widened), REGISTERED);
  assert.equal(consent.consentRecorderRegistered(widened), REGISTERED);
  const everyTool = registrationRoot(t, registrationManifest('*', undefined));
  assert.equal(consent.consentHookRegistered(everyTool), REGISTERED, 'a * matcher covers every tool');
  assert.equal(consent.consentRecorderRegistered(everyTool), REGISTERED, 'an absent matcher covers every tool');
  const pattern = registrationRoot(t, registrationManifest('Ba.h', '.*'));
  assert.equal(consent.consentHookRegistered(pattern), REGISTERED);
  assert.equal(consent.consentRecorderRegistered(pattern), REGISTERED);
  const otherMatcher = registrationRoot(t, registrationManifest('Read', 'Edit|Write'));
  assert.equal(consent.consentHookRegistered(otherMatcher), UNREGISTERED);
  assert.equal(consent.consentRecorderRegistered(otherMatcher), UNREGISTERED);
  const substring = registrationRoot(t, registrationManifest('Bas', 'ash|Read'));
  assert.equal(consent.consentHookRegistered(substring), UNREGISTERED, 'a plain name matches the whole tool name only');
  assert.equal(consent.consentRecorderRegistered(substring), UNREGISTERED, 'a plain name list matches whole tool names only');
  if (process.platform !== 'win32') {
    const linked = registrationRoot(t, registrationManifest('Bash', 'Bash'), []);
    fs.writeFileSync(path.join(linked, 'hooks', 'gate-target.sh'), '#!/bin/bash\n');
    fs.symlinkSync('gate-target.sh', path.join(linked, 'hooks', consent.CONSENT_HOOK_FILE));
    fs.symlinkSync('absent-target.sh', path.join(linked, 'hooks', consent.CONSENT_RECORDER_FILE));
    assert.equal(consent.consentHookRegistered(linked), REGISTERED, 'a symlinked hook file is followed');
    assert.equal(consent.consentRecorderRegistered(linked), UNREGISTERED, 'a dangling symlinked hook file is missing');
  }
  const swapped = registrationRoot(t, {
    hooks: {
      PreToolUse: [{ matcher: 'Bash', hooks: [registrationEntry(consent.CONSENT_RECORDER_FILE)] }],
      PostToolUse: [{ matcher: 'Bash', hooks: [registrationEntry(consent.CONSENT_HOOK_FILE)] }],
    },
  });
  assert.equal(consent.consentHookRegistered(swapped), UNREGISTERED);
  assert.equal(consent.consentRecorderRegistered(swapped), UNREGISTERED);
  const noHooksKey = registrationRoot(t, {});
  assert.equal(consent.consentHookRegistered(noHooksKey), UNREGISTERED);
  assert.equal(consent.consentRecorderRegistered(noHooksKey), UNREGISTERED);
  const noFiles = registrationRoot(t, registrationManifest('Bash', 'Bash'), []);
  assert.equal(consent.consentHookRegistered(noFiles), UNREGISTERED);
  assert.equal(consent.consentRecorderRegistered(noFiles), UNREGISTERED);
  assert.equal(consent.consentHookRegistered(path.join(control, 'missing')), UNREGISTERED);
});

test('the registration probes answer unknown when hooks.json cannot be read, parsed or matched', (t) => {
  const { REGISTERED, UNKNOWN } = consent.REGISTRATION;
  const cases = {
    'no hooks.json': registrationRoot(t, undefined),
    'unparseable hooks.json': registrationRoot(t, '{'),
    'a hooks.json that is not an object': registrationRoot(t, '[]'),
    'a hooks value that is not an object': registrationRoot(t, { hooks: 'Bash' }),
    'an event value that is not a list': registrationRoot(t, { hooks: { PreToolUse: {}, PostToolUse: 'Bash' } }),
    'a matcher that does not compile': registrationRoot(t, registrationManifest('[', '(')),
    'a pattern whose anchored and unanchored readings disagree': registrationRoot(t, registrationManifest('Ba.', 'as.')),
    'a matcher the host may read as a name list or as a pattern': registrationRoot(t, registrationManifest('Bash, Read', 'Read, Bash')),
    'a matcher that is not a string': registrationRoot(t, registrationManifest(5, null)),
  };
  for (const [label, root] of Object.entries(cases)) {
    assert.equal(consent.consentHookRegistered(root), UNKNOWN, label);
    assert.equal(consent.consentRecorderRegistered(root), UNKNOWN, label);
  }
  const hooksDir = registrationRoot(t, undefined);
  fs.mkdirSync(path.join(hooksDir, 'hooks', 'hooks.json'));
  assert.equal(consent.consentHookRegistered(hooksDir), UNKNOWN, 'a hooks.json that is a directory');
  if (process.platform !== 'win32') {
    const fileAsHooks = tempDir(t, 'zensu-plugin-');
    fs.writeFileSync(path.join(fileAsHooks, 'hooks'), 'not a directory\n');
    assert.equal(consent.consentHookRegistered(fileAsHooks), UNKNOWN, 'a hooks path that is a file');
    assert.equal(consent.consentRecorderRegistered(fileAsHooks), UNKNOWN, 'a hooks path that is a file');
  }
  const settled = registrationRoot(t, {
    hooks: {
      PreToolUse: [
        { matcher: '(', hooks: [registrationEntry(consent.CONSENT_HOOK_FILE)] },
        { matcher: 'Bash', hooks: [registrationEntry(consent.CONSENT_HOOK_FILE)] },
      ],
      PostToolUse: [{ matcher: 'Bash', hooks: [registrationEntry(consent.CONSENT_RECORDER_FILE)] }],
    },
  });
  assert.equal(consent.consentHookRegistered(settled), REGISTERED, 'a registration on Bash settles an uncompilable sibling');
});

test('one registration reader serves the consent probes and the grant row, each through its own reading', () => {
  const registration = require('../../hooks/lib/hook-registration-v1.js');
  const R = registration.REGISTRATION;
  assert.equal(consent.REGISTRATION, R);
  const names = (command) => command.includes('/hooks/x.sh');
  const group = (matcher, command = 'bash /p/hooks/x.sh') => ({ ...(matcher === undefined ? {} : { matcher }), hooks: [{ type: 'command', command }] });
  const doc = (matcher) => ({ hooks: { PreToolUse: [group(matcher)] } });
  const host = (manifest, tools = ['Bash']) => registration.registration(manifest, { event: 'PreToolUse', tools, names, reading: registration.READINGS.HOST });
  const regex = (manifest, tools = ['Agent', 'Task']) => registration.registration(manifest, { event: 'PreToolUse', tools, names, reading: registration.READINGS.REGEX });
  const cases = [
    ['a plain name list naming the tool', doc('Bash'), R.REGISTERED, doc('Agent|Task'), R.REGISTERED],
    ['a plain name list without the tool', doc('Edit|Write'), R.UNREGISTERED, doc('Agent'), R.UNREGISTERED],
    ['an absent matcher', doc(undefined), R.REGISTERED, doc(undefined), R.REGISTERED],
    ['an empty matcher', doc(''), R.REGISTERED, doc(''), R.REGISTERED],
    ['the star', doc('*'), R.REGISTERED, doc('*'), R.UNREGISTERED],
    ['a matcher that is not a string', doc(42), R.UNKNOWN, doc(42), R.REGISTERED],
    ['a matcher that does not compile', doc('('), R.UNKNOWN, doc('('), R.UNREGISTERED],
    ['a matcher whose readings disagree', doc('as.'), R.UNKNOWN, doc('gen.'), R.UNREGISTERED],
    ['an array document', [], R.UNKNOWN, [], R.UNREGISTERED],
    ['a hooks value of the wrong type', { hooks: 'x' }, R.UNKNOWN, { hooks: 'x' }, R.UNREGISTERED],
    ['a present but falsy event value', { hooks: { PreToolUse: null } }, R.UNKNOWN, { hooks: { PreToolUse: null } }, R.UNREGISTERED],
    ['a truthy event value that is not an array', { hooks: { PreToolUse: {} } }, R.UNKNOWN, { hooks: { PreToolUse: {} } }, R.UNKNOWN],
    ['a document that is not an object', 'x', R.UNKNOWN, 'x', R.UNKNOWN],
    ['no hooks at all', {}, R.UNREGISTERED, {}, R.UNREGISTERED],
    ['a group that names another hook', { hooks: { PreToolUse: [group('Bash', 'bash /p/hooks/y.sh')] } }, R.UNREGISTERED,
      { hooks: { PreToolUse: [group('Agent|Task', 'bash /p/hooks/y.sh')] } }, R.UNREGISTERED],
  ];
  for (const [label, hostDoc, hostWant, regexDoc, regexWant] of cases) {
    assert.equal(host(hostDoc), hostWant, `host reading: ${label}`);
    assert.equal(regex(regexDoc), regexWant, `regex reading: ${label}`);
  }
  const report = fs.readFileSync(path.join(REPO_ROOT, 'hooks', 'lib', 'zensu-doctor-report.js'), 'utf8');
  assert.match(report, /require\('\.\/hook-registration-v1\.js'\)/);
});

test('promptText states the session, the origin, the per-origin grant and the declared routes', () => {
  const single = consent.promptText({ origins: ['http://127.0.0.1:4200'], session: SESSION, declaredRoutes: ['/', '/login', '/a/../b'] });
  assert.equal(single, [
    `The playwright-cli browser session ${SESSION} is about to reach http://127.0.0.1:4200 (local loopback).`,
    'Answering Yes approves this origin for the rest of this Claude Code session: the model may then open, read and interact with (click, type, submit forms on) any page on it, screenshots included, without asking again. Consent is per origin, never per route.',
    'The run declares these routes as synthetic-safe: /, /login.',
    'Answer No to keep the browser away from it; the run then reports PARTIAL.',
  ].join(' '));
  const plural = consent.promptText({ origins: ['http://127.0.0.1:4200', 'http://[::1]:4201'], session: SESSION, declaredRoutes: [] });
  assert.match(plural, /reach http:\/\/127\.0\.0\.1:4200, http:\/\/\[::1\]:4201 \(local loopback\)/);
  assert.match(plural, /approves these origins/);
  assert.match(plural, /any page on them/);
  assert.match(plural, /keep the browser away from them/);
  assert.doesNotMatch(plural, /synthetic-safe/);
});

test('the prompt route list is bounded in characters, count and width', () => {
  assert.equal(consent.promptRoute(`/a${String.fromCharCode(1)}b${String.fromCharCode(0x7f)}`), '/ab');
  assert.equal(consent.promptRoute(`/${'x'.repeat(200)}`), `/${'x'.repeat(consent.MAX_PROMPT_ROUTE - 1)}…`);
  assert.equal(consent.promptRoute(42), '');
  const many = Array.from({ length: consent.MAX_PROMPT_ROUTES + 3 }, (_unused, index) => `/r${index}`);
  assert.equal(consent.promptRoutes(many), `${many.slice(0, consent.MAX_PROMPT_ROUTES).join(', ')} (and 3 more)`);
  const wide = Array.from({ length: 5 }, (_unused, index) => `/${String(index).repeat(100)}`);
  const rendered = consent.promptRoutes(wide);
  assert.equal(rendered.startsWith(`${wide[0]}, ${wide[1]}, ${wide[2]}`), true);
  assert.match(rendered, / \(and 2 more\)$/);
});

test('every refusal belongs to exactly one class, and only a shape denial carries the re-issue note', () => {
  const keys = Object.keys(REASONS);
  const shape = [...consent.SHAPE_REASONS];
  const final = [...consent.FINAL_REASONS];
  assert.equal(new Set([...shape, ...final]).size, shape.length + final.length);
  assert.deepEqual([...shape, ...final].sort(), [...keys].sort());
  assert.deepEqual([...shape].sort(), ['ARGUMENT_UNEXPANDED', 'CLI_NOT_BARE', 'ENV_ASSIGNMENT', 'LAUNCHER', 'NOT_PLAIN', 'SESSION_UNEXPANDED', 'SESSION_UNRESOLVED', 'WRAPPER']);
  assert.match(consent.SHAPE_MARKER, /^\(shape denial: re-issue this call once /);
  assert.match(consent.SHAPE_MARKER, /single-quoted literal arguments; a second denial is final\)$/);
  const reasonOf = (reason) => consent.preEnvelope({ verdict: 'deny', reason }).hookSpecificOutput.permissionDecisionReason;
  for (const key of shape) assert.equal(reasonOf(REASONS[key]), `${DENIED}${REASONS[key]} ${consent.SHAPE_MARKER}`, key);
  for (const key of final) assert.ok(!reasonOf(REASONS[key]).includes('shape denial'), key);
  const bare = consent.preEnvelope(decide(`/usr/local/bin/playwright-cli -s=${SESSION} snapshot`));
  assert.equal(bare.hookSpecificOutput.permissionDecisionReason, `${DENIED}${REASONS.CLI_NOT_BARE} ${consent.SHAPE_MARKER}`);
  const plain = consent.preEnvelope(decide(`${cli('snapshot')} && ${cli('snapshot')}`));
  assert.equal(plain.hookSpecificOutput.permissionDecisionReason, `${DENIED}${REASONS.NOT_PLAIN} ${consent.SHAPE_MARKER}`);
  const refused = consent.preEnvelope(decide(cli('eval 1')));
  assert.equal(refused.hookSpecificOutput.permissionDecisionReason, `${DENIED}command 'eval' ${REASONS.COMMAND_DENIED}`);
});

test('preEnvelope carries ask and deny only', () => {
  assert.equal(consent.preEnvelope({ verdict: 'none' }), null);
  assert.deepEqual(consent.preEnvelope({ verdict: 'ask', prompt: 'P' }),
    { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'ask', permissionDecisionReason: 'P' } });
  assert.deepEqual(consent.preEnvelope({ verdict: 'deny', reason: 'R' }),
    { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: `${DENIED}R` } });
});

test('payloadFromRaw refuses an empty, unparseable or failed read', () => {
  assert.equal(consent.payloadFromRaw('', false), null);
  assert.equal(consent.payloadFromRaw('   ', false), null);
  assert.equal(consent.payloadFromRaw('{', false), null);
  assert.equal(consent.payloadFromRaw('{"tool_name":"Bash"}', true), null);
  assert.deepEqual(consent.payloadFromRaw('{"tool_name":"Bash"}', false), { tool_name: 'Bash' });
});

test('readPolicy is absent without the variable and names the fault of an invalid one', () => {
  assert.equal(consent.readPolicy({}), null);
  assert.equal(consent.readPolicy({ ZENSU_VERIFY_NAVIGATION_POLICY_V1: '' }), null);
  const valid = policyOf('local', [LOCAL_TARGET]);
  assert.equal(valid.ok, true);
  assert.equal(valid.mode, 'local');
  assert.deepEqual([...valid.targets.keys()], ['http://127.0.0.1:4300']);
  assert.deepEqual(consent.readPolicy({ ZENSU_VERIFY_NAVIGATION_POLICY_V1: '{"version":1}' }),
    { ok: false, fault: 'policy contains unknown or missing keys' });
});

test('the recipe routes come from runtime.yaml before autopilot.yaml, in flow or block form', (t) => {
  const root = tempDir(t);
  const zensu = path.join(root, '.zensu');
  fs.mkdirSync(zensu);
  assert.equal(consent.resolveRecipeFile(root), '');
  assert.equal(consent.resolveRecipeFile(''), '');
  fs.writeFileSync(path.join(zensu, 'autopilot.yaml'), ['validate:', '  evidenceSafety:', '    routes:', '      - /', '      - "/inventory"', ''].join('\n'));
  assert.equal(consent.resolveRecipeFile(root), path.join(zensu, 'autopilot.yaml'));
  assert.deepEqual(consent.readRecipeRoutes(consent.resolveRecipeFile(root)), ['/', '/inventory']);
  fs.writeFileSync(path.join(zensu, 'runtime.yaml'), ['validate:', '  evidenceSafety:', "    routes: ['/settings', '/a/../b']", ''].join('\n'));
  assert.equal(consent.resolveRecipeFile(root), path.join(zensu, 'runtime.yaml'));
  assert.deepEqual(consent.readRecipeRoutes(consent.resolveRecipeFile(root)), ['/settings']);
  assert.deepEqual(consent.declaredRoutesFromRecipe('validate:\n  driver: browser\n'), []);
  if (process.platform !== 'win32') {
    fs.rmSync(path.join(zensu, 'runtime.yaml'));
    fs.symlinkSync(path.join(zensu, 'autopilot.yaml'), path.join(zensu, 'runtime.yaml'));
    assert.equal(consent.resolveRecipeFile(root), path.join(zensu, 'autopilot.yaml'));
  }
});

test('recordingStream reports whether anything was written', () => {
  const target = sink();
  const recorder = consent.recordingStream(target);
  assert.equal(recorder.emitted(), false);
  recorder.write('x');
  assert.equal(recorder.emitted(), true);
  assert.equal(target.text(), 'x');
});

test('the CLI entry answers pre and post and refuses any other mode', () => {
  const usage = runCli('', '');
  assert.equal(usage.status, 2);
  assert.match(usage.stderr, /usage: verify-consent-v1\.js pre\|post/);
  const asked = runCli('pre', JSON.stringify(bash(cli('goto http://127.0.0.1:4200/'))));
  assert.equal(asked.status, 0, asked.stderr);
  assert.equal(JSON.parse(asked.stdout).hookSpecificOutput.permissionDecision, 'ask');
  const garbled = runCli('pre', '{"tool_name":"Bash","tool_input":{"command":"playwright-cli');
  assert.equal(garbled.status, 0, garbled.stderr);
  assert.equal(JSON.parse(garbled.stdout).hookSpecificOutput.permissionDecisionReason, `${DENIED}${REASONS.PAYLOAD_UNREADABLE}`);
  const quiet = runCli('pre', JSON.stringify(bash('ls -la')));
  assert.equal(quiet.status, 0, quiet.stderr);
  assert.equal(quiet.stdout, '');
  const recorded = runCli('post', JSON.stringify(post(cli('goto http://127.0.0.1:4200/'))));
  assert.equal(recorded.status, 0, recorded.stderr);
  assert.equal(recorded.stdout, '');
  assert.equal(recorded.stderr.includes('zensu: verify consent memory not written (no bound session)\n'), true);
});
