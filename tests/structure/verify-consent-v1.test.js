'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const consent = require('../../hooks/lib/verify-consent-v1.js');
const { FLOOR_REASONS } = require('../../hooks/lib/verify-navigation-floor-v1.js');
const {
  CONSENT_MATCHER,
  MEMORY_VERSION,
  NAVIGATION_TOOL_RE,
  REASONS,
  appendRecord,
  decide,
  memoryPathAllowed,
  readMemory,
  targetOf,
} = consent;

const MODULE = path.resolve(__dirname, '../../hooks/lib/verify-consent-v1.js');
const KEY = 'scv1_' + 'a'.repeat(64);
const NAV = 'mcp__plugin_zensu_playwright__browser_navigate';
const TABS = 'mcp__playwright__browser_tabs';

function project() {
  const root = fs.mkdtempSync(path.join(fs.realpathSync.native(os.tmpdir()), 'zensu-consent-'));
  fs.mkdirSync(path.join(root, '.zensu', 'state'), { recursive: true });
  return { root, memory: path.join(root, '.zensu', 'state', `verify-consent-${KEY}.json`) };
}

function record(origin, route, decidedBy = 'prompt') {
  return { origin, route, decidedBy, at: '2026-09-02T20:00:00.000Z' };
}

function runCli(mode, payload, env) {
  const result = spawnSync(process.execPath, [MODULE, mode], {
    input: typeof payload === 'string' ? payload : JSON.stringify(payload),
    env: { PATH: process.env.PATH, ...env },
    encoding: 'utf8',
  });
  return { ...result, envelope: result.stdout ? JSON.parse(result.stdout) : null };
}

test('the matcher and the navigation tool test cover both plugin spellings and only the navigating tools', () => {
  const matcher = new RegExp(`^${CONSENT_MATCHER}$`);
  for (const name of [NAV, 'mcp__playwright__browser_navigate', TABS, 'mcp__plugin_zensu_playwright__browser_tabs']) {
    assert.equal(matcher.test(name), true, name);
    assert.equal(NAVIGATION_TOOL_RE.test(name), true, name);
  }
  for (const name of ['mcp__plugin_zensu_playwright__browser_snapshot', 'mcp__playwright__browser_click', 'Bash', 'mcp__other__browser_navigate']) {
    assert.equal(matcher.test(name), false, name);
    assert.equal(NAVIGATION_TOOL_RE.test(name), false, name);
  }
});

test('targetOf reads the navigate url and only a tabs call that opens a new url', () => {
  assert.equal(targetOf(NAV, { url: 'http://127.0.0.1:1/' }), 'http://127.0.0.1:1/');
  assert.equal(targetOf(NAV, {}), null);
  assert.equal(targetOf(TABS, { action: 'new', url: 'http://127.0.0.1:1/x' }), 'http://127.0.0.1:1/x');
  assert.equal(targetOf(TABS, { action: 'new' }), null);
  assert.equal(targetOf(TABS, { action: 'close', url: 'http://127.0.0.1:1/' }), null);
  assert.equal(targetOf('mcp__plugin_zensu_playwright__browser_snapshot', { url: 'http://127.0.0.1:1/' }), null);
});

test('a navigation to a new origin asks, names the origin, the route and the consequence', () => {
  const decision = decide({ toolName: NAV, toolInput: { url: 'http://127.0.0.1:4200/login' }, records: [], declaredRoutes: ['/', '/login'] });
  assert.equal(decision.verdict, 'ask');
  assert.equal(decision.reason, REASONS.NEW_ORIGIN);
  assert.equal(decision.origin, 'http://127.0.0.1:4200');
  assert.equal(decision.route, '/login');
  assert.equal(decision.mode, 'local');
  assert.match(decision.prompt, /http:\/\/127\.0\.0\.1:4200/);
  assert.match(decision.prompt, /\/login/);
  assert.match(decision.prompt, /lets the model read this page's content/);
  assert.match(decision.prompt, /Declared synthetic-safe routes for this run: \/, \/login\./);
});

test('memory and declared routes decide silently; an undeclared route on a known origin asks again', () => {
  const records = [record('http://127.0.0.1:4200', '/')];
  const hit = decide({ toolName: NAV, toolInput: { url: 'http://127.0.0.1:4200/' }, records, declaredRoutes: [] });
  assert.equal(hit.verdict, 'allow');
  assert.equal(hit.reason, REASONS.MEMORY_HIT);
  const declared = decide({ toolName: NAV, toolInput: { url: 'http://127.0.0.1:4200/login' }, records, declaredRoutes: ['/login'] });
  assert.equal(declared.verdict, 'allow');
  assert.equal(declared.reason, REASONS.DECLARED_ROUTE);
  const undeclared = decide({ toolName: NAV, toolInput: { url: 'http://127.0.0.1:4200/admin' }, records, declaredRoutes: ['/login'] });
  assert.equal(undeclared.verdict, 'ask');
  assert.equal(undeclared.reason, REASONS.UNDECLARED_ROUTE);
  assert.match(undeclared.prompt, /does not declare as synthetic-safe/);
  const otherOrigin = decide({ toolName: NAV, toolInput: { url: 'http://127.0.0.1:4201/login' }, records, declaredRoutes: ['/login'] });
  assert.equal(otherOrigin.verdict, 'ask');
  assert.equal(otherOrigin.reason, REASONS.NEW_ORIGIN);
});

test('the floor denies before any memory is consulted', () => {
  const records = [record('http://localhost:4200', '/')];
  const cases = [
    ['http://localhost:4200/', FLOOR_REASONS.LOCAL_LITERAL_LOOPBACK],
    ['http://example.com/', FLOOR_REASONS.LOCAL_LITERAL_LOOPBACK],
    ['http://10.0.0.5/', FLOOR_REASONS.REMOTE_HTTPS],
    ['https://192.168.1.10/', FLOOR_REASONS.REMOTE_NOT_PUBLIC],
    ['https://169.254.169.254/', FLOOR_REASONS.REMOTE_NOT_PUBLIC],
    ['http://user:pw@127.0.0.1:4200/', FLOOR_REASONS.CREDENTIALS],
    ['http://127.0.0.1:4200/?token=1', FLOOR_REASONS.QUERY_OR_FRAGMENT],
    ['http://127.0.0.1:4200/#frag', FLOOR_REASONS.QUERY_OR_FRAGMENT],
    ['file:///etc/passwd', FLOOR_REASONS.SCHEME],
  ];
  for (const [url, reason] of cases) {
    const decision = decide({ toolName: NAV, toolInput: { url }, records, declaredRoutes: ['/'] });
    assert.equal(decision.verdict, 'deny', url);
    assert.equal(decision.reason, reason, url);
  }
});

test('consent mode admits loopback origins only; a remote target is refused with the policy reason', () => {
  for (const url of ['https://app.example.com/', 'https://93.184.216.34/dashboard', 'wss://app.example.com/events']) {
    const remote = decide({ toolName: NAV, toolInput: { url }, records: [record('https://app.example.com', '/')], declaredRoutes: ['/'] });
    assert.equal(remote.verdict, 'deny', url);
    assert.equal(remote.reason, REASONS.REMOTE_NEEDS_POLICY, url);
    assert.match(remote.reason, /parent-environment navigation policy/);
  }
  const local = decide({ toolName: NAV, toolInput: { url: 'http://127.0.0.1:1/' }, records: [record('https://app.example.com', '/')], declaredRoutes: [] });
  assert.equal(local.verdict, 'ask');
  assert.equal(consent.lockFromRecords, undefined);
});

test('policy mode and non-navigation calls allow silently', () => {
  const policy = decide({ toolName: NAV, toolInput: { url: 'http://localhost:1/' }, records: [], declaredRoutes: [], policyPresent: true });
  assert.equal(policy.verdict, 'allow');
  assert.equal(policy.reason, REASONS.POLICY_MODE);
  const snapshot = decide({ toolName: 'mcp__plugin_zensu_playwright__browser_snapshot', toolInput: {}, records: [], declaredRoutes: [] });
  assert.equal(snapshot.verdict, 'allow');
  assert.equal(snapshot.reason, REASONS.NOT_A_NAVIGATION);
});

test('memory reads refuse a symlink, a non-file, an oversized file and a malformed document', () => {
  const { root, memory } = project();
  assert.deepEqual(readMemory(memory), { ok: true, records: [], absent: true });
  fs.writeFileSync(memory, JSON.stringify({ version: MEMORY_VERSION, records: [record('http://127.0.0.1:1', '/')] }));
  assert.equal(readMemory(memory).records.length, 1);
  fs.writeFileSync(memory, '{bad');
  assert.equal(readMemory(memory).ok, false);
  fs.writeFileSync(memory, JSON.stringify({ version: 2, records: [] }));
  assert.equal(readMemory(memory).reason, REASONS.MEMORY_UNREADABLE);
  fs.writeFileSync(memory, JSON.stringify({ version: 1, records: [{ origin: 'x', route: 'nope', decidedBy: 'prompt', at: 'now' }] }));
  assert.equal(readMemory(memory).ok, false);
  fs.writeFileSync(memory, JSON.stringify({ version: 1, records: [] }).padEnd(70000, ' '));
  assert.equal(readMemory(memory).ok, false);
  fs.unlinkSync(memory);
  fs.mkdirSync(memory);
  assert.equal(readMemory(memory).ok, false);
  fs.rmdirSync(memory);
  const real = path.join(root, 'elsewhere.json');
  fs.writeFileSync(real, JSON.stringify({ version: 1, records: [] }));
  try {
    fs.symlinkSync(real, memory);
    assert.equal(readMemory(memory).ok, false);
  } catch (error) {
    if (!error || error.code !== 'EPERM') throw error;
  }
});

test('memory writes are contained to the session state directory and land by O_EXCL temp plus rename', () => {
  const { root, memory } = project();
  const first = appendRecord(memory, record('http://127.0.0.1:4200', '/'), { projectRoot: root });
  assert.equal(first.ok, true);
  assert.equal(first.duplicate, false);
  const again = appendRecord(memory, record('http://127.0.0.1:4200', '/', 'memory'), { projectRoot: root });
  assert.equal(again.duplicate, true);
  const second = appendRecord(memory, record('http://127.0.0.1:4200', '/login'), { projectRoot: root });
  assert.equal(second.records.length, 2);
  const stored = JSON.parse(fs.readFileSync(memory, 'utf8'));
  assert.equal(stored.version, MEMORY_VERSION);
  assert.deepEqual(stored.records.map((entry) => entry.route), ['/', '/login']);
  assert.equal(fs.readdirSync(path.dirname(memory)).filter((name) => name.endsWith('.tmp')).length, 0);
  assert.equal((fs.statSync(memory).mode & 0o777), 0o600);

  assert.equal(appendRecord(path.join(root, `verify-consent-${KEY}.json`), record('http://127.0.0.1:1', '/'), { projectRoot: root }).reason, REASONS.MEMORY_PATH_REFUSED);
  assert.equal(appendRecord(path.join(root, '.zensu', 'state', 'other.json'), record('http://127.0.0.1:1', '/'), { projectRoot: root }).reason, REASONS.MEMORY_PATH_REFUSED);
  assert.equal(appendRecord(memory, record('http://127.0.0.1:1', '/'), { projectRoot: '' }).reason, REASONS.MEMORY_PATH_REFUSED);
  assert.equal(appendRecord(memory, { origin: 'http://127.0.0.1:1', route: 'x', decidedBy: 'prompt', at: 'now' }, { projectRoot: root }).reason, 'record-invalid');

  const foreign = fs.mkdtempSync(path.join(fs.realpathSync.native(os.tmpdir()), 'zensu-consent-foreign-'));
  fs.mkdirSync(path.join(foreign, 'state'));
  const linked = project();
  fs.rmSync(path.join(linked.root, '.zensu', 'state'), { recursive: true });
  try {
    fs.symlinkSync(path.join(foreign, 'state'), path.join(linked.root, '.zensu', 'state'));
    assert.equal(memoryPathAllowed(linked.memory, linked.root).reason, REASONS.MEMORY_PATH_REFUSED);
    assert.equal(appendRecord(linked.memory, record('http://127.0.0.1:1', '/'), { projectRoot: linked.root }).ok, false);
    assert.equal(fs.readdirSync(path.join(foreign, 'state')).length, 0);
  } catch (error) {
    if (!error || error.code !== 'EPERM') throw error;
  }
});

test('the pre CLI emits ask or deny envelopes and denies an unreadable payload', () => {
  const { root, memory } = project();
  const env = { ZENSU_VERIFY_CONSENT_MEMORY: memory, ZENSU_VERIFY_PROJECT_ROOT: root, ZENSU_VERIFY_DECLARED_ROUTES: '["/"]' };
  const ask = runCli('pre', { tool_name: NAV, tool_input: { url: 'http://127.0.0.1:4200/' } }, env);
  assert.equal(ask.status, 0);
  assert.equal(ask.envelope.hookSpecificOutput.permissionDecision, 'ask');
  const deny = runCli('pre', { tool_name: NAV, tool_input: { url: 'http://localhost:4200/' } }, env);
  assert.equal(deny.envelope.hookSpecificOutput.permissionDecision, 'deny');
  assert.match(deny.envelope.hookSpecificOutput.permissionDecisionReason, /literal loopback-IP/);
  const quiet = runCli('pre', { tool_name: 'mcp__plugin_zensu_playwright__browser_snapshot', tool_input: {} }, env);
  assert.equal(quiet.stdout, '');
  const unreadable = runCli('pre', '{not json', env);
  assert.equal(unreadable.envelope.hookSpecificOutput.permissionDecision, 'deny');
  assert.match(unreadable.envelope.hookSpecificOutput.permissionDecisionReason, /hook-payload-unreadable/);
  const policy = runCli('pre', { tool_name: NAV, tool_input: { url: 'http://localhost:4200/' } }, { ...env, ZENSU_VERIFY_NAVIGATION_POLICY_V1: '{"version":1}' });
  assert.equal(policy.stdout, '');
  const memoryAllows = runCli('pre', { tool_name: NAV, tool_input: { url: 'http://127.0.0.1:4200/' } }, env);
  assert.equal(memoryAllows.envelope.hookSpecificOutput.permissionDecision, 'ask');
  fs.writeFileSync(memory, JSON.stringify({ version: 1, records: [record('http://127.0.0.1:4200', '/')] }));
  const afterMemory = runCli('pre', { tool_name: NAV, tool_input: { url: 'http://127.0.0.1:4200/' } }, env);
  assert.equal(afterMemory.stdout, '');
  fs.writeFileSync(memory, '{corrupt');
  const corrupt = runCli('pre', { tool_name: NAV, tool_input: { url: 'http://127.0.0.1:4200/' } }, env);
  assert.equal(corrupt.envelope.hookSpecificOutput.permissionDecision, 'ask');
  assert.match(corrupt.stderr, /consent memory ignored/);
  const usage = runCli('bogus', {}, env);
  assert.equal(usage.status, 2);
});

test('declared routes are read from the recipe evidenceSafety block in flow and block form, bounded and unfollowed', () => {
  const { declaredRoutesFromRecipe, readRecipeRoutes, responseFailed, MAX_RECIPE_BYTES } = consent;
  const flow = ['version: 1', 'validate:', '  driver: browser', '  evidenceSafety:', '    contractVersion: 1', '    routes: ["/", "/login", "/login", "/bad?x", "nope"]', '    mode: declared-safe', 'other:', '  routes: ["/ignored"]'].join('\n');
  assert.deepEqual(declaredRoutesFromRecipe(flow), ['/', '/login']);
  const block = ['validate:', '  evidenceSafety:', '    routes:', "      - '/'", '      - "/inventory"', '      - /a/../b', '    mode: declared-safe'].join('\n');
  assert.deepEqual(declaredRoutesFromRecipe(block), ['/', '/inventory']);
  assert.deepEqual(declaredRoutesFromRecipe('validate:\n  evidenceSafety:\n    mode: declared-safe\n'), []);
  assert.deepEqual(declaredRoutesFromRecipe('routes: ["/"]'), []);
  assert.deepEqual(declaredRoutesFromRecipe(''), []);

  const { root } = project();
  const recipe = path.join(root, '.zensu', 'runtime.yaml');
  fs.writeFileSync(recipe, flow);
  assert.deepEqual(readRecipeRoutes(recipe), ['/', '/login']);
  assert.deepEqual(readRecipeRoutes(path.join(root, 'missing.yaml')), []);
  assert.deepEqual(readRecipeRoutes(''), []);
  fs.writeFileSync(path.join(root, 'huge.yaml'), 'x'.repeat(MAX_RECIPE_BYTES + 1));
  assert.deepEqual(readRecipeRoutes(path.join(root, 'huge.yaml')), []);
  try {
    fs.symlinkSync(recipe, path.join(root, 'link.yaml'));
    assert.deepEqual(readRecipeRoutes(path.join(root, 'link.yaml')), []);
  } catch (error) {
    if (!error || error.code !== 'EPERM') throw error;
  }
  const env = { ZENSU_VERIFY_RECIPE_FILE: recipe };
  assert.deepEqual(consent.readInputs(env).declaredRoutes, ['/', '/login']);
  assert.deepEqual(consent.readInputs({ ...env, ZENSU_VERIFY_DECLARED_ROUTES: '["/x"]' }).declaredRoutes, ['/x']);

  assert.equal(responseFailed({ isError: true }), true);
  assert.equal(responseFailed({ content: [{ type: 'text', text: 'Zensu browser broker rejected the operation: nope' }] }), true);
  assert.equal(responseFailed({ content: [{ type: 'text', text: 'Navigated to http://127.0.0.1:1/' }] }), false);
  assert.equal(responseFailed(undefined), false);
  assert.equal(responseFailed('string'), false);
});

test('the post CLI records an executed navigation, tags its decision source and skips what the floor refuses', () => {
  const { root, memory } = project();
  const env = { ZENSU_VERIFY_CONSENT_MEMORY: memory, ZENSU_VERIFY_PROJECT_ROOT: root, ZENSU_VERIFY_DECLARED_ROUTES: '["/login"]' };
  runCli('post', { tool_name: NAV, tool_input: { url: 'http://127.0.0.1:4200/' } }, env);
  let stored = JSON.parse(fs.readFileSync(memory, 'utf8'));
  assert.deepEqual(stored.records.map((entry) => [entry.route, entry.decidedBy]), [['/', 'prompt']]);
  runCli('post', { tool_name: NAV, tool_input: { url: 'http://127.0.0.1:4200/login' } }, env);
  stored = JSON.parse(fs.readFileSync(memory, 'utf8'));
  assert.deepEqual(stored.records.map((entry) => [entry.route, entry.decidedBy]), [['/', 'prompt'], ['/login', 'memory']]);
  runCli('post', { tool_name: NAV, tool_input: { url: 'http://localhost:4200/' } }, env);
  runCli('post', { tool_name: 'mcp__plugin_zensu_playwright__browser_snapshot', tool_input: {} }, env);
  runCli('post', { tool_name: NAV, tool_input: { url: 'http://127.0.0.1:4200/rejected' }, tool_response: { isError: true, content: [{ type: 'text', text: 'Zensu browser broker rejected the operation: x' }] } }, env);
  stored = JSON.parse(fs.readFileSync(memory, 'utf8'));
  assert.equal(stored.records.length, 2);
  runCli('post', { tool_name: NAV, tool_input: { url: 'https://app.example.com/dashboard' } }, { ...env, ZENSU_VERIFY_NAVIGATION_POLICY_V1: '{"version":1}' });
  stored = JSON.parse(fs.readFileSync(memory, 'utf8'));
  assert.deepEqual(stored.records[2], { ...stored.records[2], origin: 'https://app.example.com', route: '/dashboard', decidedBy: 'policy' });
  const refused = runCli('post', { tool_name: NAV, tool_input: { url: 'http://127.0.0.1:4200/x' } }, { ...env, ZENSU_VERIFY_PROJECT_ROOT: '' });
  assert.match(refused.stderr, /consent memory not written/);
  assert.equal(refused.status, 0);
});
