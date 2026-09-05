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
  foreignServerNoteApplies,
  isIsoInstant,
  preEnvelope,
  memoryPathAllowed,
  readMemory,
  targetOf,
  validRecord,
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

function record(origin, route, decidedBy = 'prompt', declaredRoutes) {
  const entry = { origin, route, decidedBy, at: '2026-09-02T20:00:00.000Z' };
  if (declaredRoutes !== undefined) entry.declaredRoutes = declaredRoutes;
  return entry;
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
  assert.match(decision.prompt, /may then open and read any page on http:\/\/127\.0\.0\.1:4200/);
  assert.match(decision.prompt, /without asking again/);
  assert.match(decision.prompt, /The run declares these routes as synthetic-safe: \/, \/login\./);
  assert.match(decision.prompt, /reports PARTIAL/);
});

test('consent is per origin: an approved origin admits every route and a new origin still asks', () => {
  const records = [record('http://127.0.0.1:4200', '/login')];
  const sameRoute = decide({ toolName: NAV, toolInput: { url: 'http://127.0.0.1:4200/login' }, records, declaredRoutes: [] });
  assert.equal(sameRoute.verdict, 'allow');
  assert.equal(sameRoute.reason, REASONS.MEMORY_HIT);
  assert.equal(sameRoute.decidedBy, 'memory');
  const otherRoute = decide({ toolName: NAV, toolInput: { url: 'http://127.0.0.1:4200/admin' }, records, declaredRoutes: [] });
  assert.equal(otherRoute.verdict, 'allow');
  assert.equal(otherRoute.reason, REASONS.MEMORY_HIT);
  const otherOrigin = decide({ toolName: NAV, toolInput: { url: 'http://127.0.0.1:4201/login' }, records, declaredRoutes: ['/login'] });
  assert.equal(otherOrigin.verdict, 'ask');
  assert.equal(otherOrigin.reason, REASONS.NEW_ORIGIN);
  // The route set the recipe declares steers no decision at all: it is prompt context only.
  // While it did, a session could widen the recipe and launder a route into the silent-allow
  // set, because every record was stamped with a fresh read of the live file.
  const widened = decide({ toolName: NAV, toolInput: { url: 'http://127.0.0.1:4202/admin' }, records, declaredRoutes: ['/admin'] });
  assert.equal(widened.verdict, 'ask');
  assert.equal(widened.reason, REASONS.NEW_ORIGIN);
  const fresh = decide({ toolName: NAV, toolInput: { url: 'http://127.0.0.1:4200/' }, records: [], declaredRoutes: ['/', '/login'] });
  assert.match(fresh.prompt, /Consent is per origin, never per route\./);
  assert.match(fresh.prompt, /any page on http:\/\/127\.0\.0\.1:4200/);
  assert.doesNotMatch(fresh.prompt, /does not declare as synthetic-safe/);
});

test('the foreign-server note rides only on denies a foreign server can cause, and names one remedy', () => {
  for (const reason of Object.values(FLOOR_REASONS)) assert.equal(foreignServerNoteApplies(reason), true);
  assert.equal(foreignServerNoteApplies(REASONS.REMOTE_NEEDS_POLICY), true);
  assert.equal(foreignServerNoteApplies(REASONS.PAYLOAD_UNREADABLE), false);
  assert.equal(foreignServerNoteApplies('hook-failed:EACCES'), false);
  assert.equal(foreignServerNoteApplies(''), false);
  assert.equal(foreignServerNoteApplies(undefined), false);
  const floorDeny = preEnvelope({ verdict: 'deny', reason: FLOOR_REASONS.LOCAL_LITERAL_LOOPBACK });
  assert.ok(floorDeny.hookSpecificOutput.permissionDecisionReason.includes(consent.FOREIGN_SERVER_NOTE));
  const faultDeny = preEnvelope({ verdict: 'deny', reason: REASONS.PAYLOAD_UNREADABLE });
  assert.ok(!faultDeny.hookSpecificOutput.permissionDecisionReason.includes(consent.FOREIGN_SERVER_NOTE));
  // A navigation policy would disarm the gate for every target, so it is not offered here.
  assert.ok(!consent.FOREIGN_SERVER_NOTE.includes('ZENSU_VERIFY_NAVIGATION_POLICY_V1'));
  assert.match(consent.FOREIGN_SERVER_NOTE, /rename that server key/);
  assert.match(consent.FOREIGN_SERVER_NOTE, /never edit an MCP server configuration on their behalf/);
});

test('a record is judged on its stamp independently of its route', () => {
  assert.equal(isIsoInstant('2026-09-02T20:00:00.000Z'), true);
  assert.equal(isIsoInstant('July 4, 2026'), false);
  assert.equal(isIsoInstant('9999'), false);
  assert.equal(isIsoInstant('2026-02-31T00:00:00.000Z'), false);
  assert.equal(isIsoInstant('2026-09-02T20:00:00Z'), false);
  // The route is deliberately valid on every arm below, so the stamp is what decides.
  assert.equal(validRecord({ origin: 'http://127.0.0.1:1', route: '/', decidedBy: 'prompt', at: 'now' }), false);
  assert.equal(validRecord({ origin: 'http://127.0.0.1:1', route: '/', decidedBy: 'prompt', at: '2026-02-31T00:00:00.000Z' }), false);
  assert.equal(validRecord({ origin: 'http://127.0.0.1:1', route: '/', decidedBy: 'prompt', at: '2026-09-02T20:00:00.000Z' }), true);
  assert.equal(validRecord({ origin: '', route: '/', decidedBy: 'prompt', at: '2026-09-02T20:00:00.000Z' }), false);
  assert.equal(validRecord({ origin: 'http://127.0.0.1:1', route: 'nope', decidedBy: 'prompt', at: '2026-09-02T20:00:00.000Z' }), false);
  assert.equal(validRecord({ origin: 'http://127.0.0.1:1', route: '/', decidedBy: 'nobody', at: '2026-09-02T20:00:00.000Z' }), false);
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
  fs.writeFileSync(memory, JSON.stringify({ version: 1, records: [{ origin: 'http://127.0.0.1:1', route: '/', decidedBy: 'prompt', at: 'now' }] }));
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
  assert.equal(appendRecord(memory, { origin: 'http://127.0.0.1:1', route: '/', decidedBy: 'prompt', at: 'not-an-instant' }, { projectRoot: root }).reason, 'record-invalid');

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

test('the write side refuses a leaf that is a symlink, a directory or a hard link', () => {
  const { root, memory } = project();
  const good = record('http://127.0.0.1:4200', '/');
  const real = path.join(root, '.zensu', 'state', 'real-target.json');
  fs.writeFileSync(real, '{}');

  fs.mkdirSync(memory);
  assert.equal(appendRecord(memory, good, { projectRoot: root }).reason, REASONS.MEMORY_PATH_REFUSED);
  fs.rmdirSync(memory);

  try {
    fs.symlinkSync(real, memory);
    assert.equal(appendRecord(memory, good, { projectRoot: root }).reason, REASONS.MEMORY_PATH_REFUSED);
    fs.unlinkSync(memory);
  } catch (error) {
    if (!error || error.code !== 'EPERM') throw error;
  }

  fs.linkSync(real, memory);
  assert.equal(fs.lstatSync(memory).nlink, 2);
  assert.equal(appendRecord(memory, good, { projectRoot: root }).reason, REASONS.MEMORY_PATH_REFUSED);
  fs.unlinkSync(memory);

  assert.equal(appendRecord(memory, good, { projectRoot: root }).ok, true);
});

test('the pre CLI emits ask or deny envelopes and denies an unreadable payload', () => {
  const { root, memory } = project();
  const recipe = path.join(root, '.zensu', 'runtime.yaml');
  fs.writeFileSync(recipe, 'validate:\n  evidenceSafety:\n    routes: ["/"]\n');
  const env = { ZENSU_VERIFY_CONSENT_MEMORY: memory, ZENSU_VERIFY_PROJECT_ROOT: root };
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
  const inputRoot = path.dirname(path.dirname(recipe));
  const env = { ZENSU_VERIFY_PROJECT_ROOT: inputRoot };
  assert.deepEqual(consent.readInputs(env).declaredRoutes, ['/', '/login']);
  assert.deepEqual(consent.readInputs({ ...env, ZENSU_VERIFY_DECLARED_ROUTES: '["/x"]' }).declaredRoutes, ['/', '/login']);
  assert.deepEqual(consent.readInputs({ ...env, ZENSU_VERIFY_RECIPE_FILE: '/nowhere.yaml' }).declaredRoutes, ['/', '/login']);
  assert.deepEqual(consent.readInputs({}).declaredRoutes, []);
  assert.equal(consent.resolveRecipeFile(inputRoot), recipe);
  assert.equal(consent.resolveRecipeFile(''), '');
  assert.deepEqual([...consent.RECIPE_NAMES], ['runtime.yaml', 'autopilot.yaml']);

  assert.equal(responseFailed({ isError: true }), true);
  assert.equal(responseFailed({ content: [{ type: 'text', text: 'Zensu browser broker rejected the operation: nope' }] }), true);
  assert.equal(responseFailed({ content: [{ type: 'text', text: 'Navigated to http://127.0.0.1:1/' }] }), false);
  assert.equal(responseFailed(undefined), false);
  assert.equal(responseFailed('string'), false);
});

test('the post CLI records an executed navigation, tags its decision source and skips what the floor refuses', () => {
  const { root, memory } = project();
  const recipe = path.join(root, '.zensu', 'runtime.yaml');
  fs.writeFileSync(recipe, 'validate:\n  evidenceSafety:\n    routes: ["/login"]\n');
  const env = { ZENSU_VERIFY_CONSENT_MEMORY: memory, ZENSU_VERIFY_PROJECT_ROOT: root };
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

test('the shared memory read applies the writer containment rule and keeps not-configured out of it', () => {
  const { root, memory } = project();
  // An UNSET path is not a refusal. The pre hook exports an empty value when no session is
  // bound and prints its own accurate line there; reporting a refused path would name a path
  // nobody supplied and would print two lines per navigation for an ordinary case.
  const unset = consent.readConsentMemory('', root);
  assert.equal(unset.ok, true);
  assert.equal(unset.absent, true);
  assert.equal(unset.reason, undefined);

  // Containment is what makes a removed guard visible: without it these read as an ordinary
  // absent memory rather than as a refusal, and a read and a write would disagree about which
  // file is this session's memory.
  assert.equal(consent.readConsentMemory(path.join(root, 'elsewhere.json'), root).reason, REASONS.MEMORY_PATH_REFUSED);
  assert.equal(consent.readConsentMemory(path.join(root, '.zensu', 'state', 'other.json'), root).reason, REASONS.MEMORY_PATH_REFUSED);
  assert.equal(consent.readConsentMemory(memory, '').reason, REASONS.MEMORY_PATH_REFUSED);
  assert.equal(consent.readConsentMemory(path.basename(memory), root).reason, REASONS.MEMORY_PATH_REFUSED);

  // A contained path that is simply not there yet is absent, never refused.
  const fresh = consent.readConsentMemory(memory, root);
  assert.equal(fresh.ok, true);
  assert.equal(fresh.absent, true);

  assert.equal(appendRecord(memory, record('http://127.0.0.1:4200', '/'), { projectRoot: root }).ok, true);
  const filled = consent.readConsentMemory(memory, root);
  assert.equal(filled.ok, true);
  assert.equal(filled.records.length, 1);
});
