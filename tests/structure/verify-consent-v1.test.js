'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const consent = require('../../hooks/lib/verify-consent-v1.js');
const floorModule = require('../../hooks/lib/verify-navigation-floor-v1.js');
const { FLOOR_REASONS } = floorModule;
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
const VALID_POLICY = JSON.stringify({
  version: 1,
  mode: 'local',
  targets: [{ origin: 'http://127.0.0.1:4200', routes: ['/'], evidenceMode: 'declared-safe' }],
});
const TABS = 'mcp__playwright__browser_tabs';

function project() {
  const root = fs.mkdtempSync(path.join(fs.realpathSync.native(os.tmpdir()), 'zensu-consent-'));
  fs.mkdirSync(path.join(root, '.zensu', 'state'), { recursive: true });
  return { root, memory: path.join(root, '.zensu', 'state', `verify-consent-${KEY}.json`) };
}

function record(origin, route, decidedBy = 'asked', declaredRoutes) {
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
  assert.match(decision.prompt, /may then open, read and interact with \(click, type, submit forms on\) any page on http:\/\/127\.0\.0\.1:4200/);
  assert.match(decision.prompt, /without asking again/);
  assert.match(decision.prompt, /The run declares these routes as synthetic-safe: \/, \/login\./);
  assert.match(decision.prompt, /reports PARTIAL/);
});

test('consent is per origin: an approved origin admits every route and a new origin still asks', () => {
  const records = [record('http://127.0.0.1:4200', '/login')];
  const sameRoute = decide({ toolName: NAV, toolInput: { url: 'http://127.0.0.1:4200/login' }, records, declaredRoutes: [] });
  assert.equal(sameRoute.verdict, 'allow');
  assert.equal(sameRoute.reason, REASONS.MEMORY_HIT);
  assert.equal(sameRoute.decidedBy, 'remembered');
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
  assert.equal(validRecord({ origin: 'http://127.0.0.1:1', route: '/', decidedBy: 'asked', at: 'now' }), false);
  assert.equal(validRecord({ origin: 'http://127.0.0.1:1', route: '/', decidedBy: 'asked', at: '2026-02-31T00:00:00.000Z' }), false);
  assert.equal(validRecord({ origin: 'http://127.0.0.1:1', route: '/', decidedBy: 'asked', at: '2026-09-02T20:00:00.000Z' }), true);
  assert.equal(validRecord({ origin: '', route: '/', decidedBy: 'asked', at: '2026-09-02T20:00:00.000Z' }), false);
  assert.equal(validRecord({ origin: 'http://127.0.0.1:1', route: 'nope', decidedBy: 'asked', at: '2026-09-02T20:00:00.000Z' }), false);
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
  // A literal loopback address, not "localhost": the floor now runs ahead of the policy-mode
  // allow, and a hostname is exactly what its local rule refuses. AC-005 owns that discrimination.
  const policy = decide({ toolName: NAV, toolInput: { url: 'http://127.0.0.1:1/' }, records: [], declaredRoutes: [], policyPresent: true });
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
  fs.writeFileSync(memory, JSON.stringify({ version: 1, records: [{ origin: 'http://127.0.0.1:1', route: '/', decidedBy: 'asked', at: 'now' }] }));
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
  const again = appendRecord(memory, record('http://127.0.0.1:4200', '/', 'remembered'), { projectRoot: root });
  assert.equal(again.duplicate, true);
  const second = appendRecord(memory, record('http://127.0.0.1:4200', '/login'), { projectRoot: root });
  assert.equal(second.records.length, 2);
  const stored = JSON.parse(fs.readFileSync(memory, 'utf8'));
  assert.equal(stored.version, MEMORY_VERSION);
  assert.deepEqual(stored.records.map((entry) => entry.route), ['/', '/login']);
  assert.equal(fs.readdirSync(path.dirname(memory)).filter((name) => name.endsWith('.tmp')).length, 0);
  // POSIX only: on win32 Node maps a file's mode to the read-only flag alone, so a writable
  // file reports 0o666 and this would fail deterministically there — a platform mapping being
  // reported as a defect in the consent feature.
  if (process.platform !== 'win32') {
    assert.equal((fs.statSync(memory).mode & 0o777), 0o600);
  }

  assert.equal(appendRecord(path.join(root, `verify-consent-${KEY}.json`), record('http://127.0.0.1:1', '/'), { projectRoot: root }).reason, REASONS.MEMORY_PATH_REFUSED);
  assert.equal(appendRecord(path.join(root, '.zensu', 'state', 'other.json'), record('http://127.0.0.1:1', '/'), { projectRoot: root }).reason, REASONS.MEMORY_PATH_REFUSED);
  assert.equal(appendRecord(memory, record('http://127.0.0.1:1', '/'), { projectRoot: '' }).reason, REASONS.MEMORY_PATH_REFUSED);
  assert.equal(appendRecord(memory, { origin: 'http://127.0.0.1:1', route: '/', decidedBy: 'asked', at: 'not-an-instant' }, { projectRoot: root }).reason, 'record-invalid');

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
  // Same platform bound as the mode assertion above: NTFS link counting was not established
  // for this shape, so the claim is made only where it is known to hold.
  if (process.platform !== 'win32') {
    assert.equal(fs.lstatSync(memory).nlink, 2);
  }
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
  // The envelope KEY SET, not just the verdict. hookEventName is the field the host keys on;
  // without this, dropping it leaves the shell suite and every unit verdict assertion green
  // while the gate silently stops being applied.
  for (const [label, produced] of [['ask', ask], ['deny', deny], ['unreadable', unreadable]]) {
    assert.deepEqual(
      Object.keys(produced.envelope.hookSpecificOutput).sort(),
      ['hookEventName', 'permissionDecision', 'permissionDecisionReason'],
      `${label} envelope key set`);
    assert.equal(produced.envelope.hookSpecificOutput.hookEventName, 'PreToolUse', `${label} hookEventName`);
  }
  const policy = runCli('pre', { tool_name: NAV, tool_input: { url: 'http://127.0.0.1:4200/' } }, { ...env, ZENSU_VERIFY_NAVIGATION_POLICY_V1: VALID_POLICY });
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
  assert.deepEqual(stored.records.map((entry) => [entry.route, entry.decidedBy]), [['/', 'asked']]);
  runCli('post', { tool_name: NAV, tool_input: { url: 'http://127.0.0.1:4200/login' } }, env);
  stored = JSON.parse(fs.readFileSync(memory, 'utf8'));
  assert.deepEqual(stored.records.map((entry) => [entry.route, entry.decidedBy]), [['/', 'asked'], ['/login', 'remembered']]);
  runCli('post', { tool_name: NAV, tool_input: { url: 'http://localhost:4200/' } }, env);
  runCli('post', { tool_name: 'mcp__plugin_zensu_playwright__browser_snapshot', tool_input: {} }, env);
  runCli('post', { tool_name: NAV, tool_input: { url: 'http://127.0.0.1:4200/rejected' }, tool_response: { isError: true, content: [{ type: 'text', text: 'Zensu browser broker rejected the operation: x' }] } }, env);
  stored = JSON.parse(fs.readFileSync(memory, 'utf8'));
  assert.equal(stored.records.length, 2);
  runCli('post', { tool_name: NAV, tool_input: { url: 'https://app.example.com/dashboard' } }, { ...env, ZENSU_VERIFY_NAVIGATION_POLICY_V1: VALID_POLICY });
  stored = JSON.parse(fs.readFileSync(memory, 'utf8'));
  assert.deepEqual(stored.records[2], { ...stored.records[2], origin: 'https://app.example.com', route: '/dashboard', decidedBy: 'policy-mode' });
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

// The likeliest payload fault is an empty read, not an empty object: the hook wrapper's
// "$(cat 2>/dev/null || true)" turns a stdin failure into "". Parsing that as {} produced a
// payload with no tool_name that the decider allowed silently, so the module's own
// PAYLOAD_UNREADABLE branch never fired for the one fault it exists to catch.
test('an empty read is unreadable, not an empty payload', () => {
  for (const raw of ['', '   ', '\n\t ', undefined, null]) {
    assert.equal(consent.payloadFromRaw(raw, false), null);
  }
  assert.deepEqual(consent.payloadFromRaw('{"tool_name":"x"}', false), { tool_name: 'x' });
  assert.equal(consent.payloadFromRaw('{"tool_name":"x"}', true), null);

  const seen = [];
  const out = { write: (s) => seen.push(s) };
  const err = { write: () => {} };
  consent.runPre({}, {}, out, err);
  assert.equal(JSON.parse(seen[0]).hookSpecificOutput.permissionDecisionReason.includes(REASONS.PAYLOAD_UNREADABLE), true);
  assert.equal(consent.runPost({ tool_name: 7 }, {}, err).reason, REASONS.PAYLOAD_UNREADABLE);
});

// Rebuilding from empty renamed over the file and discarded every approved origin with no
// signal: the result was ok, so runPost's stderr disclosure never fired. An absent file is the
// ordinary first write and stays the only case that starts from zero.
test('an empty stdin read reaches the CLI as a refusal on both entry points', () => {
  const { root, memory } = project();
  const env = { ZENSU_VERIFY_PROJECT_ROOT: root, ZENSU_VERIFY_CONSENT_MEMORY: memory };
  const pre = runCli('pre', '', env);
  assert.equal(pre.envelope.hookSpecificOutput.permissionDecision, 'deny');
  assert.equal(pre.envelope.hookSpecificOutput.permissionDecisionReason.includes(REASONS.PAYLOAD_UNREADABLE), true);
  const post = runCli('post', '', env);
  assert.equal(post.stderr.includes(REASONS.PAYLOAD_UNREADABLE), true);
  assert.equal(fs.existsSync(memory), false);
});

test('an unreadable memory is refused, never silently rebuilt from empty', () => {
  const { root, memory } = project();
  fs.writeFileSync(memory, 'this is not json\n');
  const before = fs.readFileSync(memory, 'utf8');
  const result = appendRecord(memory, record('http://127.0.0.1:5173', '/a'), { projectRoot: root });
  assert.equal(result.ok, false);
  assert.equal(result.reason, REASONS.MEMORY_UNREADABLE);
  assert.equal(fs.readFileSync(memory, 'utf8'), before);
  assert.equal(fs.readdirSync(path.dirname(memory)).filter((n) => n.endsWith('.tmp')).length, 0);

  fs.rmSync(memory);
  assert.equal(appendRecord(memory, record('http://127.0.0.1:5173', '/a'), { projectRoot: root }).ok, true);
});

// The writer must never produce a file its own reader refuses: validRecord bounds no route
// length, so one long route would exceed MAX_MEMORY_BYTES and make every later read fail,
// leaving an approved origin asking on every navigation with nothing to repair it.
test('a write that would exceed the read cap is refused, so the reader can always read it back', () => {
  const { root, memory } = project();
  const huge = '/' + 'a'.repeat(consent.MAX_MEMORY_BYTES);
  const result = appendRecord(memory, record('http://127.0.0.1:5173', huge), { projectRoot: root });
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'memory-would-exceed-read-cap');
  assert.equal(fs.existsSync(memory), false);

  assert.equal(appendRecord(memory, record('http://127.0.0.1:5173', '/ok'), { projectRoot: root }).ok, true);
  assert.equal(readMemory(memory).ok, true);
});

// The guard is on the .zensu component itself, which the leaf checks cannot see: a symlinked
// .zensu resolves a recipe out of a directory the session does not own.
test('the recipe resolver refuses a symlinked .zensu component, not only a symlinked leaf', () => {
  const root = fs.mkdtempSync(path.join(fs.realpathSync.native(os.tmpdir()), 'zensu-recipe-'));
  const elsewhere = path.join(root, 'elsewhere');
  fs.mkdirSync(elsewhere, { recursive: true });
  fs.writeFileSync(path.join(elsewhere, 'runtime.yaml'), 'evidenceSafety:\n  routes: []\n');

  const real = path.join(root, '.zensu');
  fs.mkdirSync(real, { recursive: true });
  fs.writeFileSync(path.join(real, 'runtime.yaml'), 'evidenceSafety:\n  routes: []\n');
  assert.equal(consent.resolveRecipeFile(root), path.join(real, 'runtime.yaml'));

  fs.rmSync(real, { recursive: true });
  let linked = true;
  try { fs.symlinkSync(elsewhere, real, 'dir'); }
  catch (error) {
    if (!error || error.code !== 'EPERM') throw error;
    linked = false;
  }
  if (linked) assert.equal(consent.resolveRecipeFile(root), '');
});

// The prompt is the human's only control. The route comes from a URL a caller supplied, so a
// long or control-byte-carrying route reaching it unbounded is the defect this bounds.
test('the prompt route is bounded and stripped of control bytes', () => {
  const long = '/' + 'a'.repeat(consent.MAX_PROMPT_ROUTE + 200);
  const bounded = consent.promptRoute(long);
  assert.equal(bounded.length, consent.MAX_PROMPT_ROUTE + 1);
  assert.equal(bounded.endsWith('…'), true);
  assert.equal(consent.promptRoute('/a\u0000b\u001fc\u007fd'), '/abcd');
  assert.equal(consent.promptRoute('/plain'), '/plain');
  assert.equal(consent.promptRoute(undefined), '');

  const longRoute = '/' + 'a'.repeat(consent.MAX_PROMPT_ROUTE + 50);
  const rendered = decide({
    toolName: NAV,
    toolInput: { url: 'http://127.0.0.1:4200' + longRoute },
    records: [],
    declaredRoutes: [],
  });
  assert.equal(rendered.verdict, 'ask');
  assert.equal(rendered.prompt.includes(longRoute), false);
  assert.equal(rendered.prompt.includes('…'), true);

  const declared = decide({
    toolName: NAV,
    toolInput: { url: 'http://127.0.0.1:4200/' },
    records: [],
    declaredRoutes: ['/short', longRoute],
  });
  assert.equal(declared.verdict, 'ask');
  assert.equal(declared.prompt.includes(longRoute), false);
  assert.equal(declared.prompt.includes('/short'), true);

  const many = [];
  for (let i = 0; i < consent.MAX_PROMPT_ROUTES; i += 1) many.push('/r' + i);
  many.splice(1, 0, longRoute);
  const overflow = decide({
    toolName: NAV,
    toolInput: { url: 'http://127.0.0.1:4200/' },
    records: [],
    declaredRoutes: many,
  });
  assert.equal(overflow.verdict, 'ask');
  assert.equal(overflow.prompt.includes(longRoute), false);
  assert.equal(overflow.prompt.includes('…'), true);
  assert.equal(overflow.prompt.includes('(and 1 more)'), true);
});

// A tool name the matcher accepts is a navigation the host guaranteed would carry a target.
// When no target can be read, that is a fault, not a non-navigation: decide() answers
// not-a-navigation for both, so without a separate reason the gate stays silent and the host
// reads silence as allow. The discrimination that matters is the control below — an ordinary
// tab operation genuinely is not a navigation and must keep passing.
test('AC-001 runPre denies a matcher-accepted navigation whose target cannot be read', () => {
  const call = (payload) => {
    let stdout = '';
    consent.runPre(payload, {}, { write: (chunk) => { stdout += chunk; } }, { write: () => {} });
    return stdout;
  };
  const denied = (payload) => {
    const raw = call(payload);
    assert.notEqual(raw, '', 'expected a decision envelope, got silence');
    const envelope = JSON.parse(raw).hookSpecificOutput;
    assert.equal(envelope.permissionDecision, 'deny');
    return envelope.permissionDecisionReason;
  };

  assert.equal(REASONS.TARGET_UNREADABLE, 'navigation-target-unreadable');

  assert.match(denied({ tool_name: NAV, tool_input: {} }), /navigation-target-unreadable/);
  assert.match(denied({ tool_name: NAV, tool_input: { url: ['http://127.0.0.1:9999'] } }), /navigation-target-unreadable/);
  assert.match(denied({ tool_name: NAV, tool_input: { url: 42 } }), /navigation-target-unreadable/);
  assert.match(denied({ tool_name: NAV }), /navigation-target-unreadable/);
  assert.match(denied({ tool_name: TABS, tool_input: { action: 'new' } }), /navigation-target-unreadable/);
  assert.match(denied({ tool_name: TABS, tool_input: { action: 'new', url: '' } }), /navigation-target-unreadable/);

  assert.equal(call({ tool_name: TABS, tool_input: { action: 'list' } }), '');
  assert.equal(call({ tool_name: TABS, tool_input: { action: 'close', index: 1 } }), '');
  assert.equal(call({ tool_name: TABS, tool_input: { action: 'select', index: 0 } }), '');
  assert.equal(call({ tool_name: 'Read', tool_input: { file_path: '/etc/hosts' } }), '');
});

// The scope sentence is the one line that tells the human what a Yes actually grants, so it
// must not be displaceable by content the recipe controls. MAX_PROMPT_ROUTES bounds the route
// COUNT and each route is bounded individually, but twelve routes at the per-route cap still
// render a kilobyte of text ahead of the sentence in any surface that truncates.
test('AC-002 the consent-scope sentence precedes the route list, and the route list is bounded by total length', () => {
  const routes = [];
  for (let i = 0; i < consent.MAX_PROMPT_ROUTES; i += 1) routes.push('/' + String(i) + 'x'.repeat(consent.MAX_PROMPT_ROUTE));

  const decision = decide({
    toolName: NAV,
    toolInput: { url: 'http://127.0.0.1:4200/' },
    records: [],
    declaredRoutes: routes,
  });
  assert.equal(decision.verdict, 'ask');

  const scopeAt = decision.prompt.indexOf('Answering Yes approves this origin');
  const routesAt = decision.prompt.indexOf('The run declares these routes');
  assert.notEqual(scopeAt, -1);
  assert.notEqual(routesAt, -1);
  assert.ok(scopeAt < routesAt, `the scope sentence must precede the route list (scope=${scopeAt} routes=${routesAt})`);

  assert.equal(typeof consent.MAX_PROMPT_ROUTES_TEXT, 'number');
  const rendered = consent.promptRoutes(routes);
  assert.ok(
    rendered.length <= consent.MAX_PROMPT_ROUTES_TEXT + 32,
    `the joined route list must be bounded by total length, got ${rendered.length}`,
  );
  assert.ok(rendered.includes('more)'), 'a truncated route list must say how many it dropped');

  // Control: a short list is rendered whole, so the bound never costs an ordinary prompt.
  assert.equal(consent.promptRoutes(['/a', '/b']), '/a, /b');
});

// The human answers one question about two things: what the grant covers, and who is asking.
// The prompt got both wrong. It described a read grant while the broker's approved set gates
// every interaction on the origin — click, type and form submission included — and it opened
// by naming /zensu:verify-feature as the requester, which the gate cannot know: the matcher
// accepts the bare mcp__playwright__ spelling belonging to any MCP server keyed "playwright".
test('AC-003/AC-004 the prompt states an interactive grant and asserts no requester', () => {
  const decision = decide({
    toolName: NAV,
    toolInput: { url: 'http://127.0.0.1:4200/login' },
    records: [],
    declaredRoutes: [],
  });
  assert.equal(decision.verdict, 'ask');

  assert.match(decision.prompt, /interact with/);
  assert.match(decision.prompt, /click/);
  assert.match(decision.prompt, /submit/);

  assert.equal(decision.prompt.includes('Zensu verify-feature wants to'), false,
    'the opening must not assert which run requested the navigation');
  assert.match(decision.prompt, /^A browser navigation was requested to http:\/\/127\.0\.0\.1:4200 /);

  // The foreign-server note belongs to the ask envelope too: the same doubt that forbids
  // naming a requester is what the note explains, and only a deny carried it before.
  const envelope = preEnvelope(decision).hookSpecificOutput;
  assert.equal(envelope.permissionDecision, 'ask');
  assert.ok(
    envelope.permissionDecisionReason.includes(consent.FOREIGN_SERVER_NOTE),
    'an ask must carry the foreign-server note',
  );
});

// policyPresent was Boolean(env), so ANY non-empty value disarmed the gate — including one the
// broker refuses at startup. The two components then disagreed about the same string: the hook
// stood down while the broker denied every navigation, and the user got neither a prompt nor a
// working browser. Presence must mean "a policy the broker would accept", decided without DNS.
test('AC-005 an unacceptable policy counts as absent, and the floor stays armed in policy mode', () => {
  assert.equal(typeof floorModule.policyContractFault, 'function');
  assert.equal(floorModule.policyContractFault(JSON.stringify({
    version: 1,
    mode: 'local',
    targets: [{ origin: 'http://127.0.0.1:4200', routes: ['/'], evidenceMode: 'declared-safe' }],
  })), '');
  assert.notEqual(floorModule.policyContractFault('{oops'), '');
  assert.notEqual(floorModule.policyContractFault('{}'), '');
  assert.notEqual(floorModule.policyContractFault(JSON.stringify({ version: 2, mode: 'local', targets: [1] })), '');
  assert.notEqual(floorModule.policyContractFault(JSON.stringify({ version: 1, mode: 'sideways', targets: [1] })), '');
  assert.notEqual(floorModule.policyContractFault(JSON.stringify({ version: 1, mode: 'local', targets: [] })), '');

  const valid = JSON.stringify({
    version: 1,
    mode: 'local',
    targets: [{ origin: 'http://127.0.0.1:4200', routes: ['/'], evidenceMode: 'declared-safe' }],
  });
  assert.equal(consent.readInputs({ ZENSU_VERIFY_NAVIGATION_POLICY_V1: valid }).policyPresent, true);
  assert.equal(consent.readInputs({ ZENSU_VERIFY_NAVIGATION_POLICY_V1: '{oops' }).policyPresent, false);
  assert.equal(consent.readInputs({ ZENSU_VERIFY_NAVIGATION_POLICY_V1: 'yes' }).policyPresent, false);
  assert.equal(consent.readInputs({}).policyPresent, false);

  // Policy mode no longer skips the address floor. A valid policy names its own targets, so a
  // target the floor refuses was never in it — applying the floor costs a legitimate policy
  // nothing and removes a total bypass reachable from one environment variable.
  const refused = decide({
    toolName: NAV,
    toolInput: { url: 'http://169.254.169.254/latest/meta-data/' },
    records: [],
    policyPresent: true,
  });
  assert.equal(refused.verdict, 'deny');

  // Control: with the floor satisfied, policy mode still allows without prompting.
  const allowed = decide({
    toolName: NAV,
    toolInput: { url: 'http://127.0.0.1:4200/' },
    records: [],
    policyPresent: true,
  });
  assert.equal(allowed.verdict, 'allow');
  assert.equal(allowed.reason, REASONS.POLICY_MODE);
});

test('AC-006 the recorded label names what was observed, and runPost builds no prompt', () => {
  // PostToolUse carries no evidence that a human answered. The old vocabulary said `prompt`,
  // which a reader of the report Consent block takes as "a person approved this origin";
  // what the recorder can actually establish is that the pre hook WOULD have asked.
  assert.deepEqual(consent.DECIDED_BY, ['asked', 'remembered', 'policy-mode']);

  // recordLabel is the post path's own ladder: one classifyOrigin plus an explicit label.
  // It must never construct a prompt — this path shows none, and building one invites the
  // same inference the vocabulary rename removes.
  assert.equal(typeof consent.recordLabel, 'function');
  const fresh = consent.recordLabel({
    toolName: NAV,
    toolInput: { url: 'http://127.0.0.1:4200/dashboard' },
    records: [],
    policyPresent: false,
  });
  assert.equal(fresh.label, 'asked');
  assert.equal(fresh.origin, 'http://127.0.0.1:4200');
  assert.equal(fresh.route, '/dashboard');
  assert.equal('prompt' in fresh, false);

  const seen = consent.recordLabel({
    toolName: NAV,
    toolInput: { url: 'http://127.0.0.1:4200/other' },
    records: [record('http://127.0.0.1:4200', '/', 'asked')],
    policyPresent: false,
  });
  assert.equal(seen.label, 'remembered');

  // Policy mode still runs the floor first, so a refused address records nothing at all.
  assert.equal(consent.recordLabel({
    toolName: NAV,
    toolInput: { url: 'http://127.0.0.1:4200/' },
    records: [],
    policyPresent: true,
  }).label, 'policy-mode');
  assert.equal(consent.recordLabel({
    toolName: NAV,
    toolInput: { url: 'http://169.254.169.254/latest/meta-data/' },
    records: [],
    policyPresent: true,
  }).label, null);

  // End to end: the value that lands in the memory file is the new vocabulary, and
  // validRecord accepts it.
  const { root, memory } = project();
  const err = { write() {} };
  const result = consent.runPost(
    { tool_name: NAV, tool_input: { url: 'http://127.0.0.1:4200/dashboard' } },
    { ZENSU_VERIFY_PROJECT_ROOT: root, ZENSU_VERIFY_CONSENT_MEMORY: memory },
    err,
  );
  assert.equal(result.ok, true);
  const written = readMemory(memory, root).records;
  assert.equal(written.length, 1);
  assert.equal(written[0].decidedBy, 'asked');
  assert.equal(validRecord(written[0]), true);
});

test('AC-103 the gate records per-session EXECUTION evidence, bounded and contained', (t) => {
  // Consent mode is entered from a file read: the broker lstats two files in its OWN tree and
  // parses hooks.json there. That is a claim a file makes, never a fact about this session, so
  // a host with hooks disabled — or a broker launched from a different tree than the one whose
  // registry the host loaded — self-approves every loopback origin with nothing having asked.
  // This marker is what the broker can require instead: the gate wrote it, in this session,
  // for this origin.
  const { root } = project();
  const dir = consent.evidenceDirFor(root);
  const evidence = consent.evidencePathFor(path.join(dir, `verify-consent-${KEY}.json`), 'http://127.0.0.1:4200');

  assert.equal(typeof consent.writeExecutionEvidence, 'function');
  assert.equal(typeof consent.executionEvidencePresent, 'function');

  // Absent evidence is the state a disabled hook leaves behind, and it must not read as a pass.
  assert.equal(consent.executionEvidencePresent(dir, 'http://127.0.0.1:4200', { projectRoot: root }), false);

  const written = consent.writeExecutionEvidence(evidence, 'http://127.0.0.1:4200', { projectRoot: root });
  assert.equal(written.ok, true);
  assert.equal(consent.executionEvidencePresent(dir, 'http://127.0.0.1:4200', { projectRoot: root }), true);

  // The evidence is bound to the ORIGIN the gate decided, so a marker for one origin never
  // licenses self-approval of another.
  assert.equal(consent.executionEvidencePresent(dir, 'http://127.0.0.1:4201', { projectRoot: root }), false);

  // And it is bounded in TIME, so a marker left by an earlier navigation cannot stand in for a
  // gate that did not run for this one.
  assert.equal(typeof consent.MAX_EVIDENCE_AGE_MS, 'number');
  assert.equal(consent.executionEvidencePresent(dir, 'http://127.0.0.1:4200', { projectRoot: root, now: Date.now() + consent.MAX_EVIDENCE_AGE_MS + 60000 }), false);

  // The name is per (session, ORIGIN), so a second decided origin coexists with the first
  // instead of renaming over it — two navigations in flight together used to clobber one
  // another and the earlier origin was then refused.
  const second = consent.evidencePathFor(path.join(dir, `verify-consent-${KEY}.json`), 'http://127.0.0.1:4201');
  assert.notEqual(second, evidence);
  assert.equal(consent.writeExecutionEvidence(second, 'http://127.0.0.1:4201', { projectRoot: root }).ok, true);
  assert.equal(consent.executionEvidencePresent(dir, 'http://127.0.0.1:4200', { projectRoot: root }), true);
  assert.equal(consent.executionEvidencePresent(dir, 'http://127.0.0.1:4201', { projectRoot: root }), true);

  // The writer applies the containment the consent memory already applies: the name shape, the
  // state directory, and a leaf that is a plain file. An evidence-path fault names the EVIDENCE
  // artifact rather than the memory, so the operator is not sent to inspect the wrong file.
  assert.equal(consent.writeExecutionEvidence(path.join(dir, 'not-evidence.json'), 'http://127.0.0.1:4200', { projectRoot: root }).reason, consent.REASONS.EVIDENCE_PATH_REFUSED);
  assert.equal(consent.writeExecutionEvidence(path.join(root, path.basename(evidence)), 'http://127.0.0.1:4200', { projectRoot: root }).ok, false);
  assert.equal(consent.writeExecutionEvidence(evidence, 'http://169.254.169.254', { projectRoot: root }).ok, false);

  // A HARD LINK does not wedge the marker: the writer publishes by rename, which repoints the
  // name and never truncates the linked inode, so refusing here would defend nothing while one
  // `ln` in this session-writable directory disabled every loopback navigation for good.
  const linked = consent.evidencePathFor(path.join(dir, `verify-consent-${KEY}.json`), 'http://127.0.0.1:4202');
  fs.writeFileSync(path.join(dir, 'evidence-link-source'), '{}\n');
  fs.linkSync(path.join(dir, 'evidence-link-source'), linked);
  assert.equal(consent.writeExecutionEvidence(linked, 'http://127.0.0.1:4202', { projectRoot: root }).ok, true);

  assert.equal(consent.executionEvidencePresent(dir, 'http://127.0.0.1:4202', { projectRoot: root }), true, 'a hard-linked marker is still honoured, which is what makes the allowance safe');
  // That assertion grades a file that is NO LONGER hard-linked: the write above publishes by
  // rename, which repoints the name onto a fresh single-link inode. So it proves the writer's
  // allowance and says nothing about what the READER does with a live hard link. The reader
  // refuses one (`nlink !== 1`), and the REAPER has to agree, or such an entry is unreadable and
  // unreapable at once and holds a walk-budget slot the reaper exists to free.
  assert.equal(fs.lstatSync(linked).nlink, 1, 'the rename left a single-link inode, which is why the case above proves only the writer');
  const stuck = consent.evidencePathFor(path.join(dir, `verify-consent-${KEY}.json`), 'http://127.0.0.1:4204');
  fs.writeFileSync(
    path.join(dir, 'evidence-live-link-source'),
    `${JSON.stringify({ version: consent.EVIDENCE_VERSION, origin: 'http://127.0.0.1:4204', verdict: 'allowed', at: new Date().toISOString() })}\n`,
  );
  fs.linkSync(path.join(dir, 'evidence-live-link-source'), stuck);
  assert.equal(consent.executionEvidencePresent(dir, 'http://127.0.0.1:4204', { projectRoot: root }), false, 'the reader refuses a live hard-linked marker');
  const sweep = consent.evidencePathFor(path.join(dir, `verify-consent-${KEY}.json`), 'http://127.0.0.1:4205');
  assert.equal(consent.writeExecutionEvidence(sweep, 'http://127.0.0.1:4205', { projectRoot: root }).ok, true);
  assert.equal(fs.existsSync(stuck), false, 'and the reaper removes it, because no reader can ever honour it');

  // An OVERSIZE marker is skipped by the SIZE guard, so the body has to stay valid JSON —
  // padding with non-JSON would be discarded by the parse whether or not the guard exists.
  const fat = consent.evidencePathFor(path.join(dir, `verify-consent-${KEY}.json`), 'http://127.0.0.1:4203');
  fs.writeFileSync(fat, JSON.stringify({ version: 1, origin: 'http://127.0.0.1:4203', verdict: 'allowed', at: new Date().toISOString() }).padEnd(consent.MAX_EVIDENCE_BYTES + 1, ' '));
  assert.equal(consent.executionEvidencePresent(dir, 'http://127.0.0.1:4203', { projectRoot: root }), false);

  // Each per-entry guard gets a body differing from a good one in exactly ONE field, so none of
  // them can be deleted while the suite stays green.
  const plant = (origin, body) => {
    const at = consent.evidencePathFor(path.join(dir, `verify-consent-${KEY}.json`), origin);
    fs.writeFileSync(at, `${JSON.stringify(body)}\n`);
    return origin;
  };
  const good = (origin) => ({ version: consent.EVIDENCE_VERSION, origin, verdict: 'allowed', at: new Date().toISOString() });
  assert.equal(consent.executionEvidencePresent(dir, plant('http://127.0.0.1:4220', good('http://127.0.0.1:4220')), { projectRoot: root }), true, 'positive control for the four guards below');
  assert.equal(consent.executionEvidencePresent(dir, plant('http://127.0.0.1:4221', Object.assign(good('http://127.0.0.1:4221'), { version: consent.EVIDENCE_VERSION + 1 })), { projectRoot: root }), false, 'schema discriminator');
  assert.equal(consent.executionEvidencePresent(dir, plant('http://127.0.0.1:4222', Object.assign(good('http://127.0.0.1:4222'), { at: 'July 4, 2026' })), { projectRoot: root }), false, 'stamp shape');
  // The re-classification arm is asserted with the body origin EQUAL to the requested one. A
  // marker whose body names a DIFFERENT origin is already refused by the lookup itself — the walk
  // pushes `parsed.origin` and the caller asks for its own string — so such a case passes with
  // the whole re-classification block deleted and proves nothing about it. Each of the three
  // sub-rules gets its own body, because they refuse for different reasons.
  assert.equal(consent.executionEvidencePresent(dir, plant('https://app.example.com', good('https://app.example.com')), { projectRoot: root }), false, 're-classification on read: a remote origin is refused even when the body names it exactly');
  assert.equal(consent.executionEvidencePresent(dir, plant('http://localhost:4225', good('http://localhost:4225')), { projectRoot: root }), false, 're-classification on read: an origin the floor no longer accepts at all');
  assert.equal(consent.executionEvidencePresent(dir, plant('http://127.0.0.1:4226/', good('http://127.0.0.1:4226/')), { projectRoot: root }), false, 're-classification on read: a spelling that does not survive normalization');
  assert.equal(consent.executionEvidencePresent(dir, plant('http://127.0.0.1:4224', Object.assign(good('http://127.0.0.1:4224'), { verdict: 'whatever' })), { projectRoot: root }), false, 'verdict vocabulary');

  // The walk's budget is spent on THIS session's markers, so foreign accumulation cannot push a
  // live one outside the examined set — and exhausting it is reported rather than read as empty.
  const crowd = project();
  const crowdDir = consent.evidenceDirFor(crowd.root);
  for (let i = 0; i <= consent.MAX_EVIDENCE_FILES; i += 1) {
    const foreignKey = 'scv1_' + String(i).padStart(4, '0') + 'f'.repeat(60);
    const origin = `http://127.0.0.1:${5000 + i}`;
    fs.writeFileSync(
      path.join(crowdDir, `verify-consent-exec-${foreignKey}-${consent.evidenceOriginTag(origin)}.json`),
      `${JSON.stringify(good(origin))}\n`,
    );
  }
  const mineOrigin = 'http://127.0.0.1:4999';
  fs.writeFileSync(
    path.join(crowdDir, `verify-consent-exec-${KEY}-${consent.evidenceOriginTag(mineOrigin)}.json`),
    `${JSON.stringify(good(mineOrigin))}\n`,
  );
  assert.equal(consent.executionEvidencePresent(crowdDir, mineOrigin, { projectRoot: crowd.root, sessionKey: KEY }), true, 'a session-scoped walk is immune to foreign accumulation');
  // That assertion alone does NOT discriminate: with the session filter moved BELOW the budget the
  // walk still examines 512 of the 514 entries, so `readdirSync` order decides whether this
  // session's single marker lands inside the examined set and the check passes about 99.6% of the
  // time with the defect present. TRUNCATION is the order-independent witness — a scoped walk over
  // one matching name can never exhaust the budget, while a budget spent on foreign names always
  // does.
  const scoped = consent.executionEvidenceSeen(crowdDir, { projectRoot: crowd.root, sessionKey: KEY });
  assert.equal(scoped.truncated, false, 'the session filter runs before the budget, so foreign accumulation cannot spend it');
  assert.equal(scoped.present, true, 'and the one matching marker is still found');
  assert.equal(consent.executionEvidenceSeen(crowdDir, { projectRoot: crowd.root }).truncated, true, 'an unscoped walk past the budget reports truncation rather than an empty read');

  // A marker that is not a regular file is refused rather than read, and the reader reports
  // that it COULD read the directory — an unreadable directory is a different verdict from an
  // empty one, which is what keeps the doctor from rendering a fault as a clean row.
  const foreign = project();
  const foreignDir = consent.evidenceDirFor(foreign.root);
  fs.mkdirSync(consent.evidencePathFor(path.join(foreignDir, `verify-consent-${KEY}.json`), 'http://127.0.0.1:4200'), { recursive: true });
  assert.equal(consent.executionEvidencePresent(foreignDir, 'http://127.0.0.1:4200', { projectRoot: foreign.root }), false);
  assert.equal(consent.executionEvidenceSeen(foreignDir, { projectRoot: foreign.root }).read, true);
  // Named for the guard it actually reaches: this stateDir does not match the root's own join, so
  // it returns before any directory is opened. The `readdirSync` catch is a DIFFERENT arm and had
  // no executed case anywhere — every other case here returns at the realpath, the equality or the
  // component guard — so it is driven below on a directory that satisfies all three and still
  // cannot be read.
  assert.equal(consent.executionEvidenceSeen(path.join(foreign.root, 'no-such-dir'), { projectRoot: foreign.root }).read, false, 'a stateDir that is not the root\'s own join is refused before it is opened');
  // TWO conditions, split and NAMED, because the combined `process.getuid && getuid() !== 0`
  // guard skipped in silence and for the wrong stated reason. On win32 `getuid` is undefined, so
  // that guard is what suppressed the assertions there — while the real obstacle is that
  // `chmodSync(dir, 0o000)` does not restrict directory reads on win32 at all, so the fixture
  // cannot produce the state. As root the chmod is simply not enforced. Either way the
  // readdirSync catch goes unexercised, and a run that cannot reach it says so rather than
  // reporting a green case that tested nothing.
  const rootUser = typeof process.getuid === 'function' && process.getuid() === 0;
  const chmodBindsDirReads = process.platform !== 'win32' && typeof process.getuid === 'function';
  if (chmodBindsDirReads && !rootUser) {
    const sealed = project();
    const sealedDir = consent.evidenceDirFor(sealed.root);
    try {
      fs.chmodSync(sealedDir, 0o000);
      const blind = consent.executionEvidenceSeen(sealedDir, { projectRoot: sealed.root });
      assert.equal(blind.read, false, 'a directory that passes every containment guard and still cannot be read answers read:false');
      assert.equal(blind.present, false);
    } finally {
      try { fs.chmodSync(sealedDir, 0o700); } catch (_ignore) { /* best effort */ }
    }
  } else {
    t.diagnostic('SKIPPED: the liveEvidenceOrigins readdirSync catch is unexercised here — '
      + (process.platform === 'win32'
        ? 'chmod 0o000 does not restrict directory reads on win32'
        : (rootUser ? 'running as root, where the mode is not enforced' : 'this host exposes no getuid'))
      + '; that arm has no other executed case, so it is UNVERIFIED on this run');
  }

  // The walk binds to ONE session when a key is supplied, so a row claiming "executed in this
  // session" is never satisfied by a sibling session's marker.
  const otherKey = 'scv1_' + 'd'.repeat(64);
  const sibling = path.join(dir, `verify-consent-exec-${otherKey}-${consent.evidenceOriginTag('http://127.0.0.1:4210')}.json`);
  assert.equal(consent.writeExecutionEvidence(sibling, 'http://127.0.0.1:4210', { projectRoot: root }).ok, true);
  assert.equal(consent.executionEvidencePresent(dir, 'http://127.0.0.1:4210', { projectRoot: root }), true);
  assert.equal(consent.executionEvidencePresent(dir, 'http://127.0.0.1:4210', { projectRoot: root, sessionKey: KEY }), false);

  // A symlinked `.zensu` is refused by the READER as well as by the writer when the caller
  // supplies the root, so the two halves cannot disagree about which tree they looked at.
  assert.equal(consent.executionEvidenceSeen(dir, { projectRoot: root }).present, true);
  // A root that does not exist reaches the realpath throw, not the component walk — asserted
  // separately so the two arms cannot pass for each other's reason.
  assert.equal(consent.executionEvidenceSeen(dir, { projectRoot: path.join(root, 'nope') }).read, false);
  // The component walk itself: a real `.zensu` SYMLINK is refused by the reader exactly as the
  // writer refuses it, which is what keeps the granting read from resolving through a link the
  // writer would not follow.
  const linkedRoot = project().root;
  const realState = path.join(linkedRoot, 'elsewhere', 'state');
  fs.mkdirSync(realState, { recursive: true });
  fs.rmSync(path.join(linkedRoot, '.zensu'), { recursive: true, force: true });
  try {
    fs.symlinkSync(path.join(linkedRoot, 'elsewhere'), path.join(linkedRoot, '.zensu'));
    assert.equal(consent.executionEvidenceSeen(consent.evidenceDirFor(linkedRoot), { projectRoot: linkedRoot }).read, false);
  } catch (error) {
    if (!error || error.code !== 'EPERM') throw error;
  }
  // And a stateDir that does not match the root's own join is refused rather than read.
  assert.equal(consent.executionEvidenceSeen(path.join(root, 'somewhere-else'), { projectRoot: root }).read, false);
});

test('the stamp predicate is TOTAL, so a planted marker cannot wedge every loopback origin', () => {
  // ISO_INSTANT_RE admits two digits per field, so `9999-99-99T99:99:99.999Z` matches the shape
  // and yields an invalid Date — and `toISOString()` raises RangeError on one. The predicate is
  // called from `liveEvidenceOrigins` OUTSIDE every enclosing try, so a throw there escaped the
  // reader entirely: the broker caught it, answered `unjudged`, and refused EVERY loopback
  // origin in the project naming a plugin-tree fault that had not occurred. `.zensu/state/` is
  // session-writable, and the reaper reached the same predicate inside its own try and skipped
  // past, so the wedge was permanent until the file was removed by hand.
  assert.equal(consent.isIsoInstant('9999-99-99T99:99:99.999Z'), false);
  assert.equal(consent.isIsoInstant('2026-02-31T00:00:00.000Z'), false, 'shape alone is still not validity');
  assert.equal(consent.isIsoInstant('2026-09-10T12:00:00.000Z'), true, 'positive control');

  const { root } = project();
  const dir = consent.evidenceDirFor(root);
  const poisoned = 'http://127.0.0.1:4230';
  fs.writeFileSync(
    path.join(dir, `verify-consent-exec-${KEY}-${consent.evidenceOriginTag(poisoned)}.json`),
    `${JSON.stringify({ version: consent.EVIDENCE_VERSION, origin: poisoned, verdict: 'allowed', at: '9999-99-99T99:99:99.999Z' })}\n`,
  );
  assert.equal(consent.executionEvidencePresent(dir, poisoned, { projectRoot: root }), false);
  const live = 'http://127.0.0.1:4231';
  const livePath = consent.evidencePathFor(path.join(dir, `verify-consent-${KEY}.json`), live);
  assert.equal(consent.writeExecutionEvidence(livePath, live, { projectRoot: root, verdict: 'allowed' }).ok, true);
  assert.equal(consent.executionEvidencePresent(dir, live, { projectRoot: root }), true, 'one poisoned marker does not deny the whole project');
});

test('the reaper removes what the reader can never honour, and only that', () => {
  const { root } = project();
  const dir = consent.evidenceDirFor(root);
  const memory = path.join(dir, `verify-consent-${KEY}.json`);
  const stale = 'http://127.0.0.1:4240';
  const stalePath = consent.evidencePathFor(memory, stale);
  // Past the SWEEP's own grace bound, not merely past the reader's window: a marker that has only
  // just expired is held for one further window so the broker's `expired` refusal keeps its input.
  const old = new Date(Date.now() - consent.MAX_EVIDENCE_REAP_AGE_MS - 60000).toISOString();
  // Planted DIRECTLY rather than written through the writer. The sweep is clocked on the wall
  // clock, so a marker the writer stamps already-expired is unhonourable from birth and is swept
  // by its own write — correct, but it would leave this case with nothing to reap. Writing it by
  // hand is what keeps the NEXT write the thing under test.
  fs.writeFileSync(stalePath, `${JSON.stringify({ version: consent.EVIDENCE_VERSION, origin: stale, verdict: 'allowed', at: old })}\n`);
  assert.equal(fs.existsSync(stalePath), true, 'the fixture is in place before the write under test');

  // A correctly-named file the reader can never honour still costs walk budget, and the walk the
  // BROKER takes is unscoped — so an accumulation of these refused every loopback origin with a
  // message naming a gate that had run. Reaping only well-formed EXPIRED markers left them.
  const junk = path.join(dir, `verify-consent-exec-${KEY}-${consent.evidenceOriginTag('http://127.0.0.1:4241')}.json`);
  fs.writeFileSync(junk, '{}\n');
  const futureOrigin = 'http://127.0.0.1:4242';
  const future = path.join(dir, `verify-consent-exec-${KEY}-${consent.evidenceOriginTag(futureOrigin)}.json`);
  fs.writeFileSync(future, `${JSON.stringify({ version: consent.EVIDENCE_VERSION, origin: futureOrigin, verdict: 'allowed', at: new Date(Date.now() + 86400000).toISOString() })}\n`);

  const fresh = 'http://127.0.0.1:4243';
  const freshPath = consent.evidencePathFor(memory, fresh);
  assert.equal(consent.writeExecutionEvidence(freshPath, fresh, { projectRoot: root, verdict: 'allowed' }).ok, true);

  assert.equal(fs.existsSync(stalePath), false, 'an expired marker is reaped by the next write');
  assert.equal(fs.existsSync(junk), false, 'so is a correctly-named body the reader refuses');
  assert.equal(fs.existsSync(future), false, 'and so is a stamp outside the window in the other direction');
  assert.equal(fs.existsSync(freshPath), true, 'the marker just published is left alone');

  // The memory is not a marker and is never a reap candidate.
  fs.writeFileSync(memory, '{}\n');
  const second = consent.evidencePathFor(memory, 'http://127.0.0.1:4244');
  assert.equal(consent.writeExecutionEvidence(second, 'http://127.0.0.1:4244', { projectRoot: root }).ok, true);
  assert.equal(fs.existsSync(memory), true);
});

test('the doctor verdict does not depend on readdir order, and the broker can see a truncated walk', () => {
  const { root } = project();
  const dir = consent.evidenceDirFor(root);
  const memory = path.join(dir, `verify-consent-${KEY}.json`);
  const allowed = 'http://127.0.0.1:4250';
  const asked = 'http://127.0.0.1:4251';
  assert.equal(consent.writeExecutionEvidence(consent.evidencePathFor(memory, allowed), allowed, { projectRoot: root, verdict: 'allowed' }).ok, true);
  assert.equal(consent.writeExecutionEvidence(consent.evidencePathFor(memory, asked), asked, { projectRoot: root, verdict: 'asked' }).ok, true);
  // Two origins decided inside the window is ordinary in a multi-origin verify run. Reporting
  // `origins[0]` made the doctor's `ran` / `ran-asked` row flip between runs for identical state
  // and could drop the declined-prompt disclosure, so the weaker verdict wins.
  assert.equal(consent.executionEvidenceSeen(dir, { projectRoot: root, sessionKey: KEY }).verdict, 'asked');

  // The broker asks about ONE origin, and it must be able to tell "no marker" from "the walk did
  // not finish" — collapsing both to false made a budget-exhausted read refuse with a sentence
  // naming a gate that had run.
  const seen = consent.executionEvidenceSeen(dir, { projectRoot: root, wantOrigin: allowed });
  assert.equal(seen.present, true);
  assert.equal(seen.origin, allowed, 'wantOrigin selects the origin asked about, not the first on disk');
  assert.equal(seen.truncated, false);

  // That positive is NOT the discriminator, and saying so is the point: the walk breaks as soon
  // as it parses the wanted origin, so whenever that marker is read first the fallback selector
  // returns the same value and the assertion cannot fail. `readdirSync` is unordered, so which
  // happens is filesystem-dependent. The order-INDEPENDENT claim is the negative one: a named
  // origin that is NOT live must answer `present: false`, whatever else the directory holds.
  // Without it `present` reported on the directory rather than on the question, and the broker's
  // authorization path was correct only because its caller conjoined `seen.origin === origin`.
  const missing = consent.executionEvidenceSeen(dir, { projectRoot: root, wantOrigin: 'http://127.0.0.1:4252' });
  assert.equal(missing.present, false, 'a named origin with no live marker is absent, whatever else is live');
  assert.equal(missing.origin, '', 'and no other origin is reported in its place');
  assert.equal(missing.read, true, 'the directory was still read, which is a different fact from the answer');
});

test('the execution verdict is classified by the module, not a second time by the doctor', () => {
  // The doctor probe hand-wrote its own classifier over `executionEvidenceSeen`'s record inside a
  // `node -e` string, re-deciding rules the broker's own classifier already owns — "a walk that
  // did not finish is not a walk that found nothing", "an unreadable directory is not an empty
  // one" — with nothing comparing the two, and unreachable from a unit layer. The record's shape
  // belongs to this module, so the classification does too.
  assert.equal(typeof consent.classifyExecution, 'function');
  assert.deepEqual([...consent.EXECUTION_VERDICTS].sort(), ['none', 'ran', 'ran-asked', 'unjudged']);
  assert.equal(Object.isFrozen(consent.EXECUTION_VERDICTS), true);

  const seen = (over) => Object.assign({ present: false, read: true, truncated: false, origin: '', verdict: '' }, over);
  assert.equal(consent.classifyExecution(seen({ present: true, origin: 'http://127.0.0.1:1', verdict: consent.EVIDENCE_VERDICT_ALLOWED })), 'ran');
  assert.equal(consent.classifyExecution(seen({ present: true, origin: 'http://127.0.0.1:1', verdict: consent.EVIDENCE_VERDICT_WEAKEST })), 'ran-asked');
  assert.equal(consent.classifyExecution(seen({})), 'none', 'read, and held nothing');
  assert.equal(consent.classifyExecution(seen({ read: false })), 'unjudged', 'an unreadable directory is not an empty one');
  assert.equal(consent.classifyExecution(seen({ truncated: true })), 'unjudged', 'and a walk that did not finish is not one that found nothing');
  assert.equal(consent.classifyExecution(seen({ truncated: true, present: true, origin: 'http://127.0.0.1:1', verdict: consent.EVIDENCE_VERDICT_ALLOWED })), 'ran', 'a truncated walk that still found this session answers on what it found');
  assert.equal(consent.classifyExecution(null), 'unjudged', 'every fault is a missing check rather than an all-clear');
  assert.equal(consent.classifyExecution({}), 'unjudged');
});

test('the sweep keeps the expiry diagnosis its input, and the body rule has one owner', () => {
  const { root, memory } = project();
  const dir = consent.evidenceDirFor(root);

  // The reaper and the readers share the BODY rule, not only the stat rule. Both spelled the same
  // ladder — version, origin, stamp shape, the re-classification, the verdict set, the age bound —
  // so tightening one side would restore exactly the class the shared stat rule removed.
  assert.equal(typeof consent.evidenceBodyLive, 'function');
  const good = (origin, at) => ({ version: consent.EVIDENCE_VERSION, origin, verdict: consent.EVIDENCE_VERDICT_ALLOWED, at });
  const now = Date.now();
  assert.equal(consent.evidenceBodyLive(good('http://127.0.0.1:4300', new Date(now).toISOString()), now, consent.MAX_EVIDENCE_AGE_MS), true);
  assert.equal(consent.evidenceBodyLive(good('https://app.example.com', new Date(now).toISOString()), now, consent.MAX_EVIDENCE_AGE_MS), false, 're-classification');
  assert.equal(consent.evidenceBodyLive(good('http://127.0.0.1:4300', 'July 4, 2026'), now, consent.MAX_EVIDENCE_AGE_MS), false, 'stamp shape');
  assert.equal(consent.evidenceBodyLive({ version: consent.EVIDENCE_VERSION + 1 }, now, consent.MAX_EVIDENCE_AGE_MS), false, 'schema discriminator');

  // The SWEEP's age bound is a GRACE window strictly larger than the reader's, and that is what
  // keeps the broker's `expired` refusal reachable. The only thing that can produce `expired` is a
  // read with a widened window; a sweep clocked on the reader's own bound would delete exactly the
  // marker that diagnosis needs, and the broker would then say the gate never ran — the wrong
  // cause the `expired` arm exists to prevent.
  assert.equal(consent.MAX_EVIDENCE_REAP_AGE_MS > consent.MAX_EVIDENCE_AGE_MS, true);
  const aged = 'http://127.0.0.1:4301';
  const agedPath = consent.evidencePathFor(memory, aged);
  fs.writeFileSync(agedPath, `${JSON.stringify(good(aged, new Date(now - consent.MAX_EVIDENCE_AGE_MS - 60000).toISOString()))}\n`);
  const trigger = 'http://127.0.0.1:4302';
  assert.equal(consent.writeExecutionEvidence(consent.evidencePathFor(memory, trigger), trigger, { projectRoot: root }).ok, true);
  assert.equal(fs.existsSync(agedPath), true, 'a just-expired marker survives the sweep so its expiry can still be reported');
  assert.equal(consent.executionEvidencePresent(dir, aged, { projectRoot: root }), false, 'while every ordinary read still refuses it');
  assert.equal(consent.executionEvidencePresent(dir, aged, { projectRoot: root, maxAgeMs: Number.MAX_SAFE_INTEGER }), true, 'which is what the expiry probe reads');

  // Past the grace bound it goes.
  const ancient = 'http://127.0.0.1:4303';
  const ancientPath = consent.evidencePathFor(memory, ancient);
  fs.writeFileSync(ancientPath, `${JSON.stringify(good(ancient, new Date(now - consent.MAX_EVIDENCE_REAP_AGE_MS - 60000).toISOString()))}\n`);
  const second = 'http://127.0.0.1:4304';
  assert.equal(consent.writeExecutionEvidence(consent.evidencePathFor(memory, second), second, { projectRoot: root }).ok, true);
  assert.equal(fs.existsSync(ancientPath), false, 'and a marker past the grace bound is swept');

  // The marker's NAME is bound to the origin its body names. `evidencePathAllowed` only shape-
  // tests the name, so a caller handing the tag for origin A with a body naming origin B would
  // rename over A's marker and destroy evidence for an origin that was never approved. The
  // writer is exported, so a second caller is reachable.
  const wrong = consent.evidencePathFor(memory, 'http://127.0.0.1:4305');
  const refused = consent.writeExecutionEvidence(wrong, 'http://127.0.0.1:4306', { projectRoot: root });
  assert.equal(refused.ok, false, 'a name that does not carry this origin is refused');
  assert.match(String(refused.reason), /origin/, 'and the refusal names the cause');
  assert.equal(consent.writeExecutionEvidence(wrong, 'http://127.0.0.1:4305', { projectRoot: root }).ok, true, 'control: the matching name is accepted');
});

test('exactly one decision envelope leaves the hook, and the ordering claim is bounded to what it buys', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', '..', 'hooks', 'lib', 'verify-consent-v1.js'), 'utf8');

  // `runPre` REPORTS whether it emitted. The CLI catch used to write a deny envelope
  // unconditionally, so a throw after the envelope write appended a SECOND object to a stdout that
  // already carried one — not valid JSON — while node still exited 0, so the wrapper's `|| deny`
  // did not fire and a malformed decision was forwarded to the host.
  const { root, memory } = project();
  let stdout = '';
  const emitted = consent.runPre(
    { tool_name: 'mcp__plugin_zensu_playwright__browser_navigate', tool_input: { url: 'http://127.0.0.1:4290/x' } },
    { ZENSU_VERIFY_PROJECT_ROOT: root, ZENSU_VERIFY_CONSENT_MEMORY: memory },
    { write: (chunk) => { stdout += chunk; } },
    { write: () => {} },
  );
  assert.equal(emitted, true, 'runPre reports the emission its caller has to know about');
  assert.equal(JSON.parse(stdout).hookSpecificOutput.permissionDecision, 'ask', 'control: one well-formed envelope');

  const cli = src.split('const finalize = () => {')[1].split('process.stdin.on(')[0];
  assert.notEqual(cli.trim(), '', 'control: the CLI finalize body was extracted');
  assert.match(cli, /if\s*\(!\s*recorder\.emitted\(\)\s*\)/, 'the catch consults the STREAM recorder, which is the only record of an emission a throw cannot abandon');
  assert.doesNotMatch(cli, /emitted\s*=\s*runPre\s*\(/, 'and never a flag assigned from the very call that can throw');
  assert.match(cli, /process\.exitCode = 2/, 'and sets a non-zero status so the wrapper denies rather than forwarding');

  // The reap runs BEFORE the publish. The wrapper captures node's stdout in a command
  // substitution, which reads to EOF, so nothing this module writes reaches the host until the
  // process exits — the envelope-first ordering therefore buys only what happens INSIDE the
  // process, and every instruction between the rename and exit widens the window in which a
  // killed hook leaves a live marker behind. Sweeping first removes up to MAX_EVIDENCE_FILES
  // read-and-parse rounds from that window.
  const writer = src.split('function writeExecutionEvidence(')[1].split('\nfunction ')[0];
  assert.notEqual(writer.trim(), '', 'control: the writer body was extracted');
  const reapAt = writer.indexOf('reapExpiredEvidence(');
  const renameAt = writer.indexOf('renameSync(');
  assert.notEqual(reapAt, -1, 'control: the writer sweeps');
  assert.notEqual(renameAt, -1, 'control: the writer publishes by rename');
  assert.equal(reapAt < renameAt, true, 'the sweep precedes the publish, so it is not inside the post-rename window');
});

test('both marker disclosures are emitted, and they say different things', () => {
  // Neither line had an executed case anywhere, and the hook header names the FIRST of them as
  // the mitigation for an absent state directory — a disclosure nothing exercises is a
  // disclosure nobody notices has stopped being emitted.
  const call = (env) => {
    let err = '';
    consent.runPre(
      { tool_name: 'mcp__plugin_zensu_playwright__browser_navigate', tool_input: { url: 'http://127.0.0.1:4280/x' } },
      env,
      { write: () => {} },
      { write: (chunk) => { err += chunk; } },
    );
    return err;
  };

  // No bound session: there is no key to bind a marker to, so the broker will refuse the
  // navigation the human is about to be asked about, and the operator hears that rather than a
  // path fault.
  const { root } = project();
  const unbound = call({ ZENSU_VERIFY_PROJECT_ROOT: root });
  assert.match(unbound, /execution evidence not written \(no bound session\)/);
  assert.match(unbound, /cannot complete a consent-mode navigation/);

  // A WRITE that was attempted and refused is a different fact, and names the refusal's reason.
  const second = project();
  fs.rmSync(path.join(second.root, '.zensu'), { recursive: true, force: true });
  const refused = call({ ZENSU_VERIFY_PROJECT_ROOT: second.root, ZENSU_VERIFY_CONSENT_MEMORY: second.memory });
  assert.match(refused, /execution evidence not written \(/);
  assert.match(refused, /the broker will not self-approve this origin/);
  assert.equal(/no bound session/.test(refused), false, 'the two disclosures are not interchangeable');

  // Control: with a usable state directory neither line is written at all.
  const third = project();
  assert.equal(call({ ZENSU_VERIFY_PROJECT_ROOT: third.root, ZENSU_VERIFY_CONSENT_MEMORY: third.memory }), '');
});

test('the readers refuse an anchorless call rather than reading a directory they cannot contain', () => {
  // The directory-component containment walk used to run ONLY when a caller supplied
  // `projectRoot`, so the module's default was open: `executionEvidencePresent(dir, origin)` read
  // whatever directory it was handed, through a symlinked `.zensu` or `state`, with no check. One
  // caller was hardened against that — the broker refuses an anchorless policy — but the module a
  // port copies kept the permissive default, which is how this class returns. The anchor is what
  // the walk is checked AGAINST, so without one there is nothing to verify and the only
  // fail-closed answer is to refuse.
  const { root } = project();
  const dir = consent.evidenceDirFor(root);
  const origin = 'http://127.0.0.1:4270';
  const memory = path.join(dir, `verify-consent-${KEY}.json`);
  assert.equal(consent.writeExecutionEvidence(consent.evidencePathFor(memory, origin), origin, { projectRoot: root }).ok, true);

  assert.equal(consent.executionEvidencePresent(dir, origin, { projectRoot: root }), true, 'positive control: the anchored read finds it');
  assert.equal(consent.executionEvidencePresent(dir, origin), false, 'an anchorless read refuses rather than answering');
  const seen = consent.executionEvidenceSeen(dir);
  assert.equal(seen.read, false, 'and reports that it did not read, never that the directory was empty');
  assert.equal(seen.present, false);
  assert.equal(consent.executionEvidenceSeen(dir, { projectRoot: '' }).read, false, 'an empty anchor is not an anchor');
});

test('the marker verdict vocabulary has one owner, the way decidedBy does', () => {
  // `decidedBy` is governed by the frozen exported DECIDED_BY and validated through it. The
  // marker's own `verdict` was hand-spelled at the writer's coercion, at both validators, at the
  // weakest-verdict selector, at the caller's ternary and again across a process boundary in the
  // doctor probe — seven spellings of a two-value set, with no owner to change.
  assert.equal(Array.isArray(consent.EVIDENCE_VERDICTS), true);
  assert.equal(Object.isFrozen(consent.EVIDENCE_VERDICTS), true);
  assert.deepEqual([...consent.EVIDENCE_VERDICTS].sort(), ['allowed', 'asked']);
  // The WEAKER member is named rather than positional: the doctor's row prefers it so a declined
  // prompt is disclosed, and reading it off an index would break silently on a reorder.
  assert.equal(consent.EVIDENCE_VERDICT_WEAKEST, 'asked');
  assert.equal(consent.EVIDENCE_VERDICTS.includes(consent.EVIDENCE_VERDICT_WEAKEST), true);

  // No MARKER-VERDICT line in the module carries a bare spelling. The scan is scoped to lines
  // that name the `verdict` field rather than to the two literals alone, because `DECIDED_BY`
  // legitimately holds `'asked'` too — the two vocabularies overlap on one word and belong to
  // different artifacts, so an unscoped scan would report the memory's owner as a drift.
  const body = fs.readFileSync(path.join(__dirname, '..', '..', 'hooks', 'lib', 'verify-consent-v1.js'), 'utf8')
    .split('\n')
    .filter((line) => !line.trim().startsWith('//')
      && !/EVIDENCE_VERDICT_ALLOWED = |EVIDENCE_VERDICT_WEAKEST = /.test(line));
  assert.notEqual(body.length, 0, 'control: the module body was read');
  const verdictLines = body.filter((line) => /verdict/i.test(line));
  assert.notEqual(verdictLines.length, 0, 'control: the scan found verdict-bearing lines to judge');
  const bare = verdictLines.filter((line) => /'allowed'|'asked'/.test(line));
  assert.deepEqual(bare, [], `the verdict set has one owner; bare spellings remain: ${bare.join(' | ')}`);
});

test('the decision envelope is emitted before the marker is published, and the reap is off the decision path', () => {
  const { root, memory } = project();
  const origin = 'http://127.0.0.1:4260';
  const evidencePath = consent.evidencePathFor(memory, origin);
  // The ordering is the whole safety property. For a NEW origin the envelope is the `ask`, and
  // the marker the gate writes for it carries verdict `asked`, which the broker treats as a
  // clearance. So while the marker landed FIRST, a hook process tree that died before the write
  // left a live self-approving marker behind with no prompt ever raised. Emitting first is
  // fail-closed in the other direction: a lost marker refuses, a lost envelope must not approve.
  let markerAtEnvelope = null;
  const out = { write: () => { markerAtEnvelope = fs.existsSync(evidencePath); } };
  consent.runPre(
    { tool_name: 'mcp__plugin_zensu_playwright__browser_navigate', tool_input: { url: `${origin}/first` } },
    { ZENSU_VERIFY_PROJECT_ROOT: root, ZENSU_VERIFY_CONSENT_MEMORY: memory },
    out,
    { write: () => {} },
  );
  assert.equal(markerAtEnvelope, false, 'the envelope must be written before the marker exists on disk');
  assert.equal(fs.existsSync(evidencePath), true, 'and the marker must still be written afterwards');

  // The reap is budgeted like the reader it protects: `.zensu/state` is session-writable, so an
  // unbounded walk put one read-and-parse per entry inside the hook that gates the navigation.
  const dir = consent.evidenceDirFor(root);
  const good = (o) => ({ version: consent.EVIDENCE_VERSION, origin: o, verdict: 'allowed', at: new Date().toISOString() });
  for (let i = 0; i <= consent.MAX_EVIDENCE_FILES; i += 1) {
    const key = 'scv1_' + String(i).padStart(4, '0') + 'b'.repeat(60);
    const o = `http://127.0.0.1:${6000 + i}`;
    fs.writeFileSync(path.join(dir, `verify-consent-exec-${key}-${consent.evidenceOriginTag(o)}.json`), `${JSON.stringify(good(o))}\n`);
  }
  const later = 'http://127.0.0.1:4261';
  assert.equal(consent.reapBudgetSpent(dir, new Date().toISOString()) <= consent.MAX_EVIDENCE_FILES, true, 'the reap examines at most the reader budget');
  assert.equal(consent.writeExecutionEvidence(consent.evidencePathFor(memory, later), later, { projectRoot: root, verdict: 'allowed' }).ok, true);

  // And the reap is clocked on the real clock, never on the caller's stamp: a back-dated `at`
  // made every live marker in the directory fail the `age >= 0` arm and be reaped. This arm runs
  // in its OWN project, because the crowd above holds more entries than the sweep's budget — with
  // the defect present the survivor would then escape only if `readdirSync` happened to put it
  // past the budget, which is the order dependence this file forbids elsewhere.
  const clockRoot = project();
  const clockDir = consent.evidenceDirFor(clockRoot.root);
  const live = 'http://127.0.0.1:4265';
  const survivor = consent.evidencePathFor(clockRoot.memory, live);
  assert.equal(consent.writeExecutionEvidence(survivor, live, { projectRoot: clockRoot.root, verdict: 'allowed' }).ok, true);
  assert.equal(fs.readdirSync(clockDir).filter((n) => n.startsWith('verify-consent-exec-')).length, 1, 'control: the sweep cannot be budget-bound here');
  const backdated = 'http://127.0.0.1:4266';
  assert.equal(consent.writeExecutionEvidence(consent.evidencePathFor(clockRoot.memory, backdated), backdated, {
    projectRoot: clockRoot.root,
    verdict: 'allowed',
    at: new Date(Date.now() - consent.MAX_EVIDENCE_REAP_AGE_MS - 60000).toISOString(),
  }).ok, true);
  assert.equal(fs.existsSync(survivor), true, 'a back-dated write must not reap a live marker');
});

test('AC-104 emission is observable from the throwing path, so the deny envelope can never double it', () => {
  // A throw ABANDONS an assignment, so `emitted = runPre(...)` is still false inside the caller's
  // catch — on every path, including the one where the envelope had already been written. The
  // guard that reads it therefore always passed and the comment above it named a protection the
  // code could not give. What survives a throw is what the STREAM saw, so the recorder is the
  // flag. Severity was bounded rather than absent: `process.exitCode = 2` is what makes the
  // wrapper's `|| deny` fire, so the malformed two-object stdout never reached the host.
  let written = '';
  const rec = consent.recordingStream({ write: (chunk) => { written += chunk; } });
  assert.equal(rec.emitted(), false, 'nothing observed before the first write');
  rec.write('{"one":1}');
  assert.equal(rec.emitted(), true, 'a write stays observable after the call that made it throws');
  assert.equal(written, '{"one":1}', 'control: the chunk still reaches the underlying stream');

  // Driven through the real emitter: what `runPre` writes is what the recorder reports.
  const { root, memory } = project();
  let out = '';
  const live = consent.recordingStream({ write: (chunk) => { out += chunk; } });
  consent.runPre(
    { tool_name: 'mcp__plugin_zensu_playwright__browser_navigate', tool_input: { url: 'http://127.0.0.1:4291/x' } },
    { ZENSU_VERIFY_PROJECT_ROOT: root, ZENSU_VERIFY_CONSENT_MEMORY: memory },
    live,
    { write: () => {} },
  );
  assert.equal(live.emitted(), true, 'the recorder reports the envelope runPre wrote');
  assert.equal(JSON.parse(out).hookSpecificOutput.permissionDecision, 'ask', 'control: one well-formed envelope');

  // The target-unreadable arm emits and must report it on runPre's own contract too, so a future
  // caller reading the return value is not told nothing was written.
  let unreadable = '';
  const reported = consent.runPre(
    { tool_name: 'mcp__plugin_zensu_playwright__browser_navigate', tool_input: {} },
    { ZENSU_VERIFY_PROJECT_ROOT: root, ZENSU_VERIFY_CONSENT_MEMORY: memory },
    { write: (chunk) => { unreadable += chunk; } },
    { write: () => {} },
  );
  assert.equal(JSON.parse(unreadable).hookSpecificOutput.permissionDecision, 'deny', 'control: the arm denied');
  assert.equal(reported, true, 'and runPre reports the emission rather than returning undefined');
});
