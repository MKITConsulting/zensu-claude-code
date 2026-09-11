'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const { PassThrough } = require('node:stream');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const test = require('node:test');

const installedMcpDir = path.resolve(__dirname, '../../mcp-runtime/node_modules/@playwright/mcp');
const installedMcpAvailable = fs.existsSync(path.join(installedMcpDir, 'package.json'));
const posixLauncher = process.platform === 'win32'
  ? { skip: 'the live launcher requires macOS, Linux, or WSL' }
  : {};

function shellQuote(value) {
  return `'${String(value).replaceAll("'", `'"'"'`)}'`;
}

const {
  ALLOWED_TOOLS,
  JsonLineTransport,
  assertActiveUrls,
  assertAllowedUrl,
  chromiumResolverRules,
  configureContext,
  installCapabilityBoundary,
  isPublicAddress,
  openOwnedContext,
  parsePolicy,
  run,
} = require('../../scripts/playwright-mcp-proxy.js');

// Consent mode no longer self-approves on registration alone: it requires evidence that the
// gate RAN in this session for the origin. These fixtures exercise the approval path, so each
// needs a project whose state directory carries that evidence — writing it is what a real
// PreToolUse gate does immediately before the broker sees the call.
function consentProject(origins) {
  const consent = require('../../hooks/lib/verify-consent-v1.js');
  const projectRoot = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-consent-proj-')));
  const stateDir = path.join(projectRoot, '.zensu', 'state');
  fs.mkdirSync(stateDir, { recursive: true });
  const key = 'scv1_' + 'c'.repeat(64);
  origins.forEach((origin) => {
    const evidencePath = consent.evidencePathFor(path.join(stateDir, `verify-consent-${key}.json`), origin);
    const written = consent.writeExecutionEvidence(evidencePath, origin, { projectRoot, verdict: 'allowed' });
    assert.equal(written.ok, true, `evidence for ${origin}`);
  });
  return projectRoot;
}

function rawPolicy(mode, origin, evidenceMode = 'declared-safe', routes = ['/inventory']) {
  return JSON.stringify({
    version: 1,
    mode,
    targets: [{ origin, evidenceMode, routes }],
  });
}

test('the exposed inventory is an exact safe allowlist', () => {
  assert.deepEqual(ALLOWED_TOOLS, [...ALLOWED_TOOLS].sort());
  for (const denied of [
    'browser_evaluate',
    'browser_run_code_unsafe',
    'browser_storage_state',
    'browser_cookie_list',
    'browser_file_upload',
    'browser_network_request',
    'browser_navigate_back',
    'browser_reload',
    'browser_route',
  ]) assert.equal(ALLOWED_TOOLS.includes(denied), false, denied);
  for (const required of [
    'browser_navigate',
    'browser_snapshot',
    'browser_click',
    'browser_take_screenshot',
    'browser_console_messages',
    'browser_network_requests',
    'browser_close',
  ]) assert.equal(ALLOWED_TOOLS.includes(required), true, required);
});

test('local policies accept exact loopback origins and reject broader targets', async () => {
  const policy = await parsePolicy(rawPolicy('local', 'http://127.0.0.1:5173'));
  assert.equal(assertAllowedUrl(policy, 'http://127.0.0.1:5173/inventory').pathname, '/inventory');
  assert.equal(assertAllowedUrl(policy, 'ws://127.0.0.1:5173/events', false).pathname, '/events');
  assert.throws(() => assertAllowedUrl(policy, 'http://127.0.0.1:5173/inventory?token=x'), /query/);
  assert.throws(() => assertAllowedUrl(policy, 'http://127.0.0.1:8090/api/health'), /not approved/);
  await assert.rejects(parsePolicy(JSON.stringify({
    version: 1,
    mode: 'local',
    targets: [{ origin: 'http://192.168.1.2:5173', evidenceMode: 'declared-safe', routes: ['/inventory'] }],
  })), /loopback/);
  await assert.rejects(parsePolicy(rawPolicy('local', 'http://localhost:5173')), /literal loopback-IP/);
  assert.throws(() => assertAllowedUrl(policy, 'http://127.0.0.1:5173/admin'), /route/);
});

test('remote policies pin public DNS and reject non-public address classes', async () => {
  const policy = await parsePolicy(rawPolicy('remote', 'https://app.example.com', 'declared-safe', ['/dashboard']),
    async () => [{ address: '93.184.216.34', family: 4 }]);
  assert.match(chromiumResolverRules(policy), /MAP app\.example\.com 93\.184\.216\.34/);
  assert.equal(assertAllowedUrl(policy, 'https://app.example.com/dashboard').hostname, 'app.example.com');

  for (const address of ['10.0.0.1', '127.0.0.1', '169.254.169.254', '192.168.1.1', '::1', 'fc00::1', 'fe80::1', '::ffff:127.0.0.1', '2001:2::1', '2001:20::1', '3fff::1']) {
    assert.equal(isPublicAddress(address), false, address);
  }
  for (const address of ['93.184.216.34', '2606:2800:220:1:248:1893:25c8:1946']) {
    assert.equal(isPublicAddress(address), true, address);
  }
  const ipv6Policy = await parsePolicy(rawPolicy('remote', 'https://[2606:2800:220:1:248:1893:25c8:1946]', 'declared-safe', ['/dashboard']));
  assert.equal(assertAllowedUrl(ipv6Policy, 'https://[2606:2800:220:1:248:1893:25c8:1946]/dashboard').pathname, '/dashboard');
  await assert.rejects(parsePolicy(JSON.stringify({
    version: 1,
    mode: 'remote',
    targets: [{ origin: 'https://app.example.com', evidenceMode: 'declared-safe', routes: ['/dashboard'] }],
  }), async () => [
    { address: '93.184.216.34', family: 4 },
    { address: '169.254.169.254', family: 4 },
  ]), /non-public/);
  await assert.rejects(parsePolicy(JSON.stringify({
    version: 1,
    mode: 'remote',
    targets: [{ origin: 'https://127.0.0.1', evidenceMode: 'declared-safe', routes: ['/dashboard'] }],
  })), /non-loopback/);
});

test('missing, malformed, wildcard, and unknown policy contracts fail closed', async () => {
  const missing = await parsePolicy('');
  assert.throws(() => assertAllowedUrl(missing, 'https://example.com'), /not configured/);
  await assert.rejects(parsePolicy('{bad json'), /valid JSON/);
  await assert.rejects(parsePolicy(JSON.stringify({ version: 2, mode: 'local', targets: [{ origin: 'http://127.0.0.1:1', evidenceMode: 'declared-safe', routes: ['/'] }] })), /invalid/);
  await assert.rejects(parsePolicy(JSON.stringify({ version: 1, mode: 'local', targets: [{ origin: 'http://127.0.0.1:1', evidenceMode: 'declared-safe', routes: ['/'] }], extra: true })), /unknown/);
  await assert.rejects(parsePolicy(JSON.stringify({ version: 1, mode: 'local', targets: [{ origin: 'http://*.localhost:1', evidenceMode: 'declared-safe', routes: ['/'] }] })), /loopback|invalid/);
  await assert.rejects(parsePolicy(JSON.stringify({ version: 1, mode: 'local', targets: [{ origin: 'http://127.0.0.1:1', evidenceMode: 'declared-safe', routes: ['/*'] }] })), /normalized|pathname/);
  await assert.rejects(parsePolicy(rawPolicy('local', 'http://127.0.0.1:1', 'pre-model-redaction', ['/'])), /declared-safe/);
});

test('routes are bound to one exact target origin instead of a global cross-product', async () => {
  const policy = await parsePolicy(JSON.stringify({
    version: 1,
    mode: 'local',
    targets: [
      { origin: 'http://127.0.0.1:5173', evidenceMode: 'declared-safe', routes: ['/inventory'] },
      { origin: 'http://127.0.0.1:5174', evidenceMode: 'declared-safe', routes: ['/admin'] },
    ],
  }));
  assert.equal(assertAllowedUrl(policy, 'http://127.0.0.1:5173/inventory').pathname, '/inventory');
  assert.equal(assertAllowedUrl(policy, 'http://127.0.0.1:5174/admin').pathname, '/admin');
  assert.throws(() => assertAllowedUrl(policy, 'http://127.0.0.1:5173/admin'), /route/);
  assert.throws(() => assertAllowedUrl(policy, 'http://127.0.0.1:5174/inventory'), /route/);
});

test('MCP list and call handlers enforce the boundary independently of upstream inventory', async () => {
  let upstreamCalls = 0;
  let activeUrls = ['about:blank'];
  const server = {
    _requestHandlers: new Map([
      ['tools/list', async () => ({ tools: [
        { name: 'browser_navigate' },
        { name: 'browser_evaluate' },
        { name: 'browser_run_code_unsafe' },
      ] })],
      ['tools/call', async (request) => {
        upstreamCalls += 1;
        if (request.params.name === 'browser_navigate') activeUrls = [request.params.arguments.url];
        return { content: [{ type: 'text', text: request.params.name }] };
      }],
    ]),
  };
  const policy = await parsePolicy(rawPolicy('local', 'http://127.0.0.1:5173'));
  let ownedCloses = 0;
  installCapabilityBoundary(server, policy, async () => { ownedCloses += 1; }, () => activeUrls);

  const listed = await server._requestHandlers.get('tools/list')({});
  assert.deepEqual(listed.tools.map((tool) => tool.name), ['browser_navigate']);
  const unsafe = await server._requestHandlers.get('tools/call')({ params: { name: 'browser_run_code_unsafe', arguments: {} } });
  assert.equal(unsafe.isError, true);
  const wrongOrigin = await server._requestHandlers.get('tools/call')({
    params: { name: 'browser_navigate', arguments: { url: 'http://127.0.0.1:8090' } },
  });
  assert.equal(wrongOrigin.isError, true);
  const safe = await server._requestHandlers.get('tools/call')({
    params: { name: 'browser_navigate', arguments: { url: 'http://127.0.0.1:5173/inventory' } },
  });
  assert.equal(safe.isError, undefined);
  assert.equal(upstreamCalls, 1);
  activeUrls = ['http://127.0.0.1:5173/inventory'];
  const close = await server._requestHandlers.get('tools/call')({ params: { name: 'browser_close', arguments: {} } });
  assert.equal(close.isError, undefined);
  assert.equal(ownedCloses, 1);
  assert.equal(upstreamCalls, 2);
});

test('about:blank is limited to the single pre-navigation page and cannot expose popup DOM', async () => {
  const policy = await parsePolicy(rawPolicy('local', 'http://127.0.0.1:5173'));
  assert.doesNotThrow(() => assertActiveUrls(policy, ['about:blank'], true));
  assert.throws(() => assertActiveUrls(policy, ['about:blank']), /single initial page/);
  assert.throws(() => assertActiveUrls(policy, [
    'http://127.0.0.1:5173/inventory',
    'about:blank',
  ], true), /single initial page/);

  let upstreamCalls = 0;
  const server = {
    _requestHandlers: new Map([
      ['tools/list', async () => ({ tools: ALLOWED_TOOLS.map((name) => ({ name })) })],
      ['tools/call', async () => { upstreamCalls += 1; return { content: [] }; }],
    ]),
  };
  installCapabilityBoundary(server, policy, async () => {}, () => [
    'http://127.0.0.1:5173/inventory',
    'about:blank',
  ]);
  const result = await server._requestHandlers.get('tools/call')({
    params: { name: 'browser_snapshot', arguments: {} },
  });
  assert.equal(result.isError, true);
  assert.equal(upstreamCalls, 0);
});

test('screenshot filenames are rejected before upstream can write outside broker-owned output', async () => {
  const policy = await parsePolicy(rawPolicy('local', 'http://127.0.0.1:5173'));
  let upstreamCalls = 0;
  const server = {
    _requestHandlers: new Map([
      ['tools/list', async () => ({ tools: ALLOWED_TOOLS.map((name) => ({ name })) })],
      ['tools/call', async () => {
        upstreamCalls += 1;
        return { content: [{ type: 'image', data: 'aW1hZ2U=', mimeType: 'image/png' }] };
      }],
    ]),
  };
  installCapabilityBoundary(server, policy, async () => {}, () => ['http://127.0.0.1:5173/inventory']);
  const result = await server._requestHandlers.get('tools/call')({
    params: { name: 'browser_take_screenshot', arguments: { filename: '../../source.png' } },
  });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /broker-owned/);
  assert.equal(upstreamCalls, 0);
  const inline = await server._requestHandlers.get('tools/call')({
    params: { name: 'browser_take_screenshot', arguments: {} },
  });
  assert.equal(inline.isError, undefined);
  assert.equal(inline.content[0].type, 'image');
  assert.equal(upstreamCalls, 1);
});

test('run gives upstream an external temporary output directory and cleans it on close or init failure', async () => {
  const originalPolicy = process.env.ZENSU_VERIFY_NAVIGATION_POLICY_V1;
  process.env.ZENSU_VERIFY_NAVIGATION_POLICY_V1 = rawPolicy('local', 'http://127.0.0.1:5173');
  const makeServer = () => ({
    _requestHandlers: new Map([
      ['tools/list', async () => ({ tools: [] })],
      ['tools/call', async () => ({ content: [] })],
    ]),
    connect: async function connect() { await this.onclose?.(); },
  });
  let closeOutputDir;
  try {
    await run('/unused', {
      chromium: {},
      input: new PassThrough(),
      output: new PassThrough(),
      createConnection: async (config) => {
        closeOutputDir = config.outputDir;
        assert.equal(path.isAbsolute(closeOutputDir), true);
        assert.equal(fs.existsSync(closeOutputDir), true);
        return makeServer();
      },
    });
    assert.equal(fs.existsSync(closeOutputDir), false);

    let failedOutputDir;
    await assert.rejects(run('/unused', {
      chromium: {},
      input: new PassThrough(),
      output: new PassThrough(),
      createConnection: async (config) => {
        failedOutputDir = config.outputDir;
        throw new Error('synthetic connection failure');
      },
    }), /synthetic connection failure/);
    assert.equal(fs.existsSync(failedOutputDir), false);

    let transportOutputDir;
    await assert.rejects(run('/unused', {
      chromium: {},
      input: new PassThrough(),
      output: new PassThrough(),
      createConnection: async (config) => {
        transportOutputDir = config.outputDir;
        return {
          ...makeServer(),
          connect: async () => { throw new Error('synthetic transport failure'); },
        };
      },
    }), /synthetic transport failure/);
    assert.equal(fs.existsSync(transportOutputDir), false);
  } finally {
    if (originalPolicy === undefined) delete process.env.ZENSU_VERIFY_NAVIGATION_POLICY_V1;
    else process.env.ZENSU_VERIFY_NAVIGATION_POLICY_V1 = originalPolicy;
  }
});

test('client-side route changes are checked before and after every model-visible operation', async () => {
  let activeUrls = ['http://127.0.0.1:5173/inventory'];
  const server = {
    _requestHandlers: new Map([
      ['tools/list', async () => ({ tools: ALLOWED_TOOLS.map((name) => ({ name })) })],
      ['tools/call', async () => {
        activeUrls = ['http://127.0.0.1:5173/admin'];
        return { content: [{ type: 'text', text: 'raw sensitive page' }] };
      }],
    ]),
  };
  const policy = await parsePolicy(rawPolicy('local', 'http://127.0.0.1:5173'));
  installCapabilityBoundary(server, policy, async () => {}, () => activeUrls);
  const result = await server._requestHandlers.get('tools/call')({ params: { name: 'browser_click', arguments: {} } });
  assert.equal(result.isError, true);
  assert.doesNotMatch(result.content[0].text, /raw sensitive page/);
  const second = await server._requestHandlers.get('tools/call')({ params: { name: 'browser_snapshot', arguments: {} } });
  assert.equal(second.isError, true);
});

test('owned contexts block service workers and gate HTTP redirects and WebSockets before continuation', async () => {
  const policy = await parsePolicy(rawPolicy('local', 'http://127.0.0.1:5173'));
  let routeHandler;
  let webSocketHandler;
  let contextOptions;
  let launchOptions;
  let browserClosed = 0;
  const context = {
    route: async (_pattern, handler) => { routeHandler = handler; },
    routeWebSocket: async (_pattern, handler) => { webSocketHandler = handler; },
  };
  const chromium = { launch: async (options) => {
    launchOptions = options;
    return ({
    newContext: async (options) => { contextOptions = options; return context; },
    close: async () => { browserClosed += 1; },
    });
  } };
  const owned = await openOwnedContext(chromium, policy);
  assert.equal(owned.context, context);
  assert.deepEqual(contextOptions, { serviceWorkers: 'block' });
  assert.equal(launchOptions.headless, false);
  assert.equal(launchOptions.args.includes('--no-proxy-server'), true);

  const http = async (url, navigation) => {
    const events = [];
    await routeHandler({
      request: () => ({ url: () => url, isNavigationRequest: () => navigation }),
      continue: async () => events.push('continue'),
      abort: async (reason) => events.push(`abort:${reason}`),
    });
    return events;
  };
  assert.deepEqual(await http('http://127.0.0.1:5173/inventory', true), ['continue']);
  assert.deepEqual(await http('http://127.0.0.1:5173/inventory?filter=a', false), ['continue']);
  assert.deepEqual(await http('http://127.0.0.1:5173/admin', true), ['abort:blockedbyclient']);
  assert.deepEqual(await http('https://example.com/inventory', true), ['abort:blockedbyclient']);

  const socket = async (url) => {
    const events = [];
    await webSocketHandler({
      url: () => url,
      connectToServer: () => events.push('connect'),
      close: async ({ code }) => events.push(`close:${code}`),
    });
    return events;
  };
  assert.deepEqual(await socket('ws://127.0.0.1:5173/events'), ['connect']);
  assert.deepEqual(await socket('wss://example.com/events'), ['close:1008']);
  await owned.browser.close();
  assert.equal(browserClosed, 1);
});

test('JSON line transport terminates and releases its buffer after one oversized message', async () => {
  const input = new PassThrough();
  const output = new PassThrough();
  const transport = new JsonLineTransport(input, output);
  let errors = 0;
  let closes = 0;
  transport.onerror = () => { errors += 1; };
  transport.onclose = () => { closes += 1; };
  await transport.start();
  input.write('x'.repeat((16 * 1024 * 1024) + 1));
  input.write('more');
  assert.equal(errors, 1);
  assert.equal(closes, 1);
  assert.equal(transport.closed, true);
  assert.equal(transport.buffer, '');
});

const PLUGIN_ROOT = path.resolve(__dirname, '../..');
const {
  CONSENT_REMOTE_REASON,
  approveConsentOrigin,
  consentHookRegistered,
  consentRecorderRegistered,
  resolveStartupPolicy,
} = require('../../scripts/playwright-mcp-proxy.js');

function syntheticRoot(withHook, withRecorder = false) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-consent-root-'));
  fs.mkdirSync(path.join(root, 'hooks', 'lib'), { recursive: true });
  fs.copyFileSync(path.join(PLUGIN_ROOT, 'hooks', 'lib', 'verify-consent-v1.js'), path.join(root, 'hooks', 'lib', 'verify-consent-v1.js'));
  fs.copyFileSync(path.join(PLUGIN_ROOT, 'hooks', 'lib', 'verify-navigation-floor-v1.js'), path.join(root, 'hooks', 'lib', 'verify-navigation-floor-v1.js'));
  const { CONSENT_MATCHER } = require(path.join(PLUGIN_ROOT, 'hooks', 'lib', 'verify-consent-v1.js'));
  const registry = { hooks: { PreToolUse: [], PostToolUse: [] } };
  if (withHook) {
    fs.writeFileSync(path.join(root, 'hooks', 'pre-browser-navigation-consent.sh'), '#!/bin/bash\nexit 0\n');
    registry.hooks.PreToolUse.push({ matcher: CONSENT_MATCHER, hooks: [{ type: 'command', command: 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/pre-browser-navigation-consent.sh"' }] });
  }
  if (withRecorder) {
    fs.writeFileSync(path.join(root, 'hooks', 'post-browser-navigation-consent.sh'), '#!/bin/bash\nexit 0\n');
    registry.hooks.PostToolUse.push({ matcher: CONSENT_MATCHER, hooks: [{ type: 'command', command: 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/post-browser-navigation-consent.sh"' }] });
  }
  fs.writeFileSync(path.join(root, 'hooks', 'hooks.json'), JSON.stringify(registry));
  return root;
}

test('without a policy the broker starts in consent mode only when the consent hook is registered', async () => {
  assert.equal(consentHookRegistered(PLUGIN_ROOT), true);
  assert.equal(consentHookRegistered(os.tmpdir()), false);
  const registered = syntheticRoot(true);
  const unregistered = syntheticRoot(false);
  assert.equal(consentHookRegistered(registered), true);
  assert.equal(consentHookRegistered(unregistered), false);
  assert.equal((await resolveStartupPolicy('', { pluginRoot: registered })).mode, 'consent');
  assert.equal((await resolveStartupPolicy('', { pluginRoot: unregistered })).mode, 'deny');
  assert.equal((await resolveStartupPolicy(rawPolicy('local', 'http://127.0.0.1:5173'), { pluginRoot: registered })).mode, 'local');
  fs.unlinkSync(path.join(registered, 'hooks', 'pre-browser-navigation-consent.sh'));
  assert.equal(consentHookRegistered(registered), false);
  const wrongMatcher = syntheticRoot(true);
  const registry = JSON.parse(fs.readFileSync(path.join(wrongMatcher, 'hooks', 'hooks.json'), 'utf8'));
  registry.hooks.PreToolUse[0].matcher = 'Bash';
  fs.writeFileSync(path.join(wrongMatcher, 'hooks', 'hooks.json'), JSON.stringify(registry));
  assert.equal(consentHookRegistered(wrongMatcher), false);
});

test('the consent recorder predicate is graded across the same truth table as its sibling', () => {
  // consentRecorderRegistered is exported and was referenced by no test: it executed only
  // incidentally, through the doctor wrapper's true branch, while consentHookRegistered was
  // driven across registered / unregistered / file-deleted / wrong-matcher. The asymmetry
  // matters because the broker starts in consent mode on the GATE alone — a missing recorder
  // prompts on every navigation and remembers nothing, which is silent without this check.
  assert.equal(consentRecorderRegistered(PLUGIN_ROOT), true);
  assert.equal(consentRecorderRegistered(os.tmpdir()), false);
  const gateOnly = syntheticRoot(true, false);
  const recorderOnly = syntheticRoot(false, true);
  const both = syntheticRoot(true, true);
  assert.equal(consentRecorderRegistered(gateOnly), false);
  assert.equal(consentHookRegistered(gateOnly), true);
  assert.equal(consentRecorderRegistered(recorderOnly), true);
  assert.equal(consentHookRegistered(recorderOnly), false);
  assert.equal(consentRecorderRegistered(both), true);
  fs.unlinkSync(path.join(both, 'hooks', 'post-browser-navigation-consent.sh'));
  assert.equal(consentRecorderRegistered(both), false);
  const wrongMatcher = syntheticRoot(false, true);
  const registry = JSON.parse(fs.readFileSync(path.join(wrongMatcher, 'hooks', 'hooks.json'), 'utf8'));
  registry.hooks.PostToolUse[0].matcher = 'Bash';
  fs.writeFileSync(path.join(wrongMatcher, 'hooks', 'hooks.json'), JSON.stringify(registry));
  assert.equal(consentRecorderRegistered(wrongMatcher), false);
});

test('consent mode approves loopback navigations, keeps the floor, and refuses remote and unapproved origins', async () => {
  const projectRoot = consentProject(['http://127.0.0.1:5173']);
  const policy = await resolveStartupPolicy('', { pluginRoot: PLUGIN_ROOT, projectRoot });
  assert.equal(policy.mode, 'consent');
  assert.throws(() => assertAllowedUrl(policy, 'http://127.0.0.1:5173/inventory'), /origin is not approved/);
  const approved = approveConsentOrigin(policy, 'http://127.0.0.1:5173/inventory');
  assert.equal(approved.mode, 'local');
  assert.equal(assertAllowedUrl(policy, 'http://127.0.0.1:5173/inventory').pathname, '/inventory');
  assert.equal(assertAllowedUrl(policy, 'http://127.0.0.1:5173/other').pathname, '/other');
  assert.equal(assertAllowedUrl(policy, 'http://127.0.0.1:5173/api/items?page=2', false).pathname, '/api/items');
  assert.equal(assertAllowedUrl(policy, 'ws://127.0.0.1:5173/events', false).pathname, '/events');
  assert.throws(() => assertAllowedUrl(policy, 'http://127.0.0.1:8090/', false), /origin is not approved/);
  assert.throws(() => assertAllowedUrl(policy, 'https://app.example.com/', false), /origin is not approved/);
  assert.throws(() => assertAllowedUrl(policy, 'http://127.0.0.1:5173/inventory?token=1'), /query or fragment/);
  assert.throws(() => approveConsentOrigin(policy, 'https://app.example.com/'), new RegExp(CONSENT_REMOTE_REASON.slice(0, 30)));
  assert.throws(() => approveConsentOrigin(policy, 'http://localhost:5173/'), /literal loopback-IP/);
  assert.throws(() => approveConsentOrigin(policy, 'http://10.0.0.5/'), /non-loopback HTTPS/);
  assert.throws(() => approveConsentOrigin(policy, 'http://user:pw@127.0.0.1:5173/'), /credentials/);
  // A non-string target must never enter the approved map. The hook's own targetOf requires a
  // string, so it answers "not a navigation" and asks nothing; coercing here classified
  // ["http://127.0.0.1:9999/"] as loopback and approved an origin no human was shown.
  for (const value of [['http://127.0.0.1:9999/'], undefined, null, 42, { toString: () => 'http://127.0.0.1:9999/' }]) {
    assert.throws(() => approveConsentOrigin(policy, value), /navigation target is invalid/);
  }
  assert.equal(policy.approved.has('http://127.0.0.1:9999'), false);
  assert.equal(policy.approved.size, 1);
  assert.equal(chromiumResolverRules(policy), null);
  const local = await parsePolicy(rawPolicy('local', 'http://127.0.0.1:5173'));
  assert.throws(() => approveConsentOrigin(local, 'http://127.0.0.1:5173/'), /requires consent mode/);
});

test('consent-mode call boundary approves on navigate and tabs-new and blocks everything else', async () => {
  const projectRoot = consentProject(['http://127.0.0.1:5173', 'http://127.0.0.1:7777', 'http://127.0.0.1:9000']);
  const policy = await resolveStartupPolicy('', { pluginRoot: PLUGIN_ROOT, projectRoot });
  let upstreamCalls = 0;
  let activeUrls = ['about:blank'];
  const server = {
    _requestHandlers: new Map([
      ['tools/list', async () => ({ tools: ALLOWED_TOOLS.map((name) => ({ name })) })],
      ['tools/call', async (request) => {
        upstreamCalls += 1;
        if (request.params.name === 'browser_navigate') activeUrls = [request.params.arguments.url];
        return { content: [{ type: 'text', text: request.params.name }] };
      }],
    ]),
  };
  installCapabilityBoundary(server, policy, async () => {}, () => activeUrls);
  const call = (name, args) => server._requestHandlers.get('tools/call')({ params: { name, arguments: args } });
  const remote = await call('browser_navigate', { url: 'https://app.example.com/' });
  assert.equal(remote.isError, true);
  assert.match(remote.content[0].text, /consent mode admits literal loopback origins only/);
  const hostname = await call('browser_navigate', { url: 'http://localhost:5173/' });
  assert.equal(hostname.isError, true);
  assert.equal(upstreamCalls, 0);
  const first = await call('browser_navigate', { url: 'http://127.0.0.1:5173/inventory' });
  assert.equal(first.isError, undefined);
  assert.equal(upstreamCalls, 1);
  assert.equal(policy.approved.has('http://127.0.0.1:5173'), true);
  const second = await call('browser_tabs', { action: 'new', url: 'http://127.0.0.1:9000/' });
  assert.equal(second.isError, undefined);
  assert.equal(policy.approved.has('http://127.0.0.1:9000'), true);
  activeUrls = ['http://127.0.0.1:5173/inventory'];
  const snapshot = await call('browser_snapshot', {});
  assert.equal(snapshot.isError, undefined);
  activeUrls = ['http://127.0.0.1:5173/inventory', 'http://127.0.0.1:7777/popup'];
  const leaked = await call('browser_snapshot', {});
  assert.equal(leaked.isError, true);
});

test('check-policy reports consent mode for a loopback route and refuses remote without a policy', () => {
  const env = { ...process.env };
  delete env.ZENSU_VERIFY_NAVIGATION_POLICY_V1;
  const proxy = path.join(PLUGIN_ROOT, 'scripts', 'playwright-mcp-proxy.js');
  const ok = spawnSync(process.execPath, [proxy, '--check-policy', 'local', 'http://127.0.0.1:5173', '/inventory', 'declared-safe'], { env, encoding: 'utf8' });
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(ok.stdout, 'consent\n');
  const remote = spawnSync(process.execPath, [proxy, '--check-policy', 'remote', 'https://app.example.com', '/', 'declared-safe'], { env, encoding: 'utf8' });
  assert.equal(remote.status, 1);
  assert.match(remote.stderr, /consent mode admits literal loopback origins only/);
  const hostname = spawnSync(process.execPath, [proxy, '--check-policy', 'local', 'http://localhost:5173', '/', 'declared-safe'], { env, encoding: 'utf8' });
  assert.equal(hostname.status, 1);
  assert.match(hostname.stderr, /literal loopback-IP/);
  const withPolicy = spawnSync(process.execPath, [proxy, '--check-policy', 'local', 'http://127.0.0.1:5173', '/inventory', 'declared-safe'], {
    env: { ...env, ZENSU_VERIFY_NAVIGATION_POLICY_V1: rawPolicy('local', 'http://127.0.0.1:5173') }, encoding: 'utf8',
  });
  assert.equal(withPolicy.status, 0, withPolicy.stderr);
  assert.equal(withPolicy.stdout, '');
});

test('launcher check-policy subprocess pins parent mode, origin, route, and evidence mode', () => {
  const launcher = path.resolve(__dirname, '../../scripts/playwright-mcp.sh');
  const run = (raw, mode, origin, route = '/inventory', evidenceMode = 'declared-safe') => spawnSync('bash', [launcher, '--check-policy', mode, origin, route, evidenceMode], {
    env: {
      ...process.env,
      ZENSU_VERIFY_NAVIGATION_POLICY_V1: raw,
    },
    encoding: 'utf8',
  });
  assert.equal(run(rawPolicy('local', 'http://127.0.0.1:5173'), 'local', 'http://127.0.0.1:5173').status, 0);
  const consent = run('', 'local', 'http://127.0.0.1:5173');
  assert.equal(consent.status, 0, consent.stderr);
  assert.equal(consent.stdout, 'consent\n');
  assert.notEqual(run('', 'remote', 'https://app.example.com', '/').status, 0);
  assert.notEqual(run('', 'local', 'http://localhost:5173').status, 0);
  assert.notEqual(run(rawPolicy('local', 'http://127.0.0.1:5173'), 'remote', 'http://127.0.0.1:5173').status, 0);
  assert.notEqual(run('{"version":1,"mode":"local","targets":[{"origin":"http://127.0.0.1:5173","evidenceMode":"declared-safe","routes":["/*"]}]}', 'local', 'http://127.0.0.1:5173').status, 0);
  assert.notEqual(run(rawPolicy('local', 'http://127.0.0.1:5173'), 'local', 'http://127.0.0.1:9999').status, 0);
  assert.notEqual(run(rawPolicy('local', 'http://127.0.0.1:5173'), 'local', 'http://127.0.0.1:5173', '/admin').status, 0);
  assert.notEqual(run(rawPolicy('local', 'http://127.0.0.1:5173'), 'local', 'http://127.0.0.1:5173', '/inventory', 'pre-model-redaction').status, 0);
});

test('launcher install-browser rematerializes and delegates to the lockfile-installed runtime', posixLauncher, () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-mcp-runtime-'));
  const tools = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-mcp-tools-'));
  const fixture = path.join(root, 'plugin');
  const fixtureScripts = path.join(fixture, 'scripts');
  const fixtureRuntime = path.join(fixture, 'mcp-runtime');
  const binDir = path.join(fixtureRuntime, 'node_modules', '.bin');
  fs.mkdirSync(fixtureScripts, { recursive: true });
  fs.mkdirSync(binDir, { recursive: true });
  fs.copyFileSync(
    path.resolve(__dirname, '../../scripts/playwright-mcp.sh'),
    path.join(fixtureScripts, 'playwright-mcp.sh'),
  );
  const lock = '{"lockfileVersion":3}\n';
  fs.writeFileSync(path.join(fixtureRuntime, 'package.json'), '{"private":true}\n');
  fs.writeFileSync(path.join(fixtureRuntime, 'package-lock.json'), lock);
  const executable = path.join(binDir, 'playwright-mcp');
  fs.writeFileSync(executable, '#!/bin/sh\nprintf "tampered:%s\\n" "$1"\n', { mode: 0o755 });
  fs.mkdirSync(path.join(fixtureRuntime, 'node_modules', '@playwright', 'mcp'), { recursive: true });
  fs.writeFileSync(path.join(fixtureRuntime, 'node_modules', '@playwright', 'mcp', 'tampered.txt'), 'tampered\n');
  const npmCalls = path.join(root, 'npm-calls');
  fs.writeFileSync(path.join(tools, 'npm'), `#!/bin/sh
set -eu
[ -z "\${ANTHROPIC_API_KEY:-}" ] || exit 82
[ "\${1:-}" = ci ] || exit 81
prefix=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = --prefix ]; then prefix="$2"; shift 2; else shift; fi
done
printf '%s\\n' "$prefix" >>${JSON.stringify(npmCalls)}
rm -rf "$prefix/node_modules"
mkdir -p "$prefix/node_modules/.bin"
cat >"$prefix/node_modules/.bin/playwright-mcp" <<'MCP_STUB'
#!/bin/sh
[ -z "\${ANTHROPIC_API_KEY:-}" ] || exit 83
printf "trusted:%s\\n" "$1"
MCP_STUB
chmod +x "$prefix/node_modules/.bin/playwright-mcp"
`, { mode: 0o755 });
  // Reproduce the old cross-runtime representation bug even on POSIX: the
  // former launcher printed Node's realpath and compared it with a shell path.
  // A Windows-shaped result made that valid contained executable look external.
  fs.writeFileSync(path.join(tools, 'node'), `#!/bin/sh
case "\${2:-}" in
  *process.stdout.write*)
    printf '%s' 'C:\\synthetic\\node_modules\\.bin\\playwright-mcp'
    exit 0
    ;;
esac
exec ${shellQuote(process.execPath)} "$@"
`, { mode: 0o755 });
  try {
    const launcher = path.join(fixtureScripts, 'playwright-mcp.sh');
    const result = spawnSync('bash', [launcher, 'install-browser'], {
      env: {
        ...process.env,
        PATH: `${tools}:${process.env.PATH}`,
        ANTHROPIC_API_KEY: 'must-not-reach-child',
      },
      encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'trusted:install-browser\n');
    const generation = fs.readFileSync(npmCalls, 'utf8').trim();
    assert.notEqual(generation, fixtureRuntime);
    assert.equal(generation.startsWith(`${fixture}${path.sep}`), false);
    assert.equal(fs.existsSync(generation), false);
    assert.equal(fs.existsSync(path.join(fixtureRuntime, 'node_modules', '@playwright', 'mcp', 'tampered.txt')), true);
    assert.match(fs.readFileSync(executable, 'utf8'), /tampered:/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
    fs.rmSync(tools, { recursive: true, force: true });
  }
});

test('production launcher rejects former test bypass controls', posixLauncher, () => {
  const launcher = path.resolve(__dirname, '../../scripts/playwright-mcp.sh');
  for (const name of ['ZENSU_MCP_TEST_MODE', 'ZENSU_MCP_TEST_PASSTHROUGH', 'ZENSU_MCP_RUNTIME_DIR_OVERRIDE']) {
    const result = spawnSync('bash', [launcher, '--check-policy'], {
      env: { ...process.env, [name]: '1' },
      encoding: 'utf8',
    });
    assert.equal(result.status, 2);
    assert.match(result.stderr, /test-only launcher controls are not supported/);
  }
});

test('the locked upstream runtime exposes exactly the broker allowlist after filtering', {
  skip: installedMcpAvailable ? false : 'locked MCP runtime is installed only for live use',
}, async () => {
  const { createConnection } = require(installedMcpDir);
  const server = await createConnection({ browser: { isolated: false } }, async () => {
    throw new Error('tools/list must not launch a browser');
  });
  const policy = await parsePolicy(rawPolicy('local', 'http://127.0.0.1:5173'));
  installCapabilityBoundary(server, policy);
  const result = await server._requestHandlers.get('tools/list')({ method: 'tools/list', params: {} }, {});
  assert.deepEqual(result.tools.map((tool) => tool.name).sort(), ALLOWED_TOOLS);
});

test('AC-101/AC-102 consent self-approval requires live in-session gate evidence, re-read on every first approval of an origin', async () => {
  // resolveStartupPolicy enters consent mode from a FILE READ in the broker's own tree, so
  // registration is a claim rather than a fact about the running session. Without this check a
  // host with hooks disabled — or a broker launched from a different tree than the one whose
  // registry the host loaded — self-approves every loopback origin unprompted, which is MORE
  // than the deny-everything state consent mode replaced.
  const consent = require('../../hooks/lib/verify-consent-v1.js');
  const pluginRoot = path.resolve(__dirname, '../..');
  const projectRoot = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-broker-')));
  const stateDir = path.join(projectRoot, '.zensu', 'state');
  fs.mkdirSync(stateDir, { recursive: true });
  const key = 'scv1_' + 'b'.repeat(64);
  const memory = path.join(stateDir, `verify-consent-${key}.json`);
  const evidence = consent.evidencePathFor(memory, 'http://127.0.0.1:5173');
  const evidence74 = consent.evidencePathFor(memory, 'http://127.0.0.1:5174');

  const policy = await resolveStartupPolicy('', { pluginRoot, projectRoot });
  assert.equal(policy.mode, 'consent', 'this repository registers the consent hook, so consent mode is the shape under test');

  // No gate ran: the broker must not approve its own way in.
  assert.throws(() => approveConsentOrigin(policy, 'http://127.0.0.1:5173/inventory'), /no in-session evidence/);
  assert.equal(policy.approved.has('http://127.0.0.1:5173'), false);

  // The gate ran for both origins: approval proceeds exactly as before.
  assert.equal(consent.writeExecutionEvidence(evidence, 'http://127.0.0.1:5173', { projectRoot }).ok, true);
  assert.equal(consent.writeExecutionEvidence(evidence74, 'http://127.0.0.1:5174', { projectRoot }).ok, true);
  assert.equal(approveConsentOrigin(policy, 'http://127.0.0.1:5173/inventory').origin, 'http://127.0.0.1:5173');

  // AC-102: the evidence is consulted on every FIRST approval of an origin, never cached for the
  // process lifetime. A long-lived MCP process that resolved its mode once at start is precisely
  // the third route the finding names, so removing a marker after a successful read elsewhere
  // must take effect on the next call. The removal is what this asserts: :5174 was approvable a
  // line ago, and is not once its own marker is gone.
  assert.equal(approveConsentOrigin(policy, 'http://127.0.0.1:5174/inventory').origin, 'http://127.0.0.1:5174');
  policy.approved.delete('http://127.0.0.1:5174');
  fs.unlinkSync(evidence74);
  assert.throws(() => approveConsentOrigin(policy, 'http://127.0.0.1:5174/inventory'), /no in-session evidence/);

  // An EXPIRED marker is refused too, and names its own cause rather than claiming the gate
  // never ran — the window covers the human's deliberation, so a slow answer lands here.
  const stale = consent.evidencePathFor(memory, 'http://127.0.0.1:5199');
  // Planted DIRECTLY. Writing it through `writeExecutionEvidence` with a back-dated `at` used to
  // work only because the sweep was clocked on that same stamp; the sweep reads the wall clock
  // now, so a marker the writer stamps already-expired is unhonourable from birth and its own
  // write removes it. That is the correct sweep behaviour, and it leaves this case nothing to
  // grade unless the fixture bypasses the writer.
  fs.writeFileSync(stale, `${JSON.stringify({
    version: consent.EVIDENCE_VERSION,
    origin: 'http://127.0.0.1:5199',
    verdict: 'allowed',
    at: new Date(Date.now() - consent.MAX_EVIDENCE_AGE_MS - 60000).toISOString(),
  })}\n`);
  assert.throws(() => approveConsentOrigin(policy, 'http://127.0.0.1:5199/inventory'), /older than the accepted window/);

  // An origin already in the approved set stays approved — the evidence gates the WRITE into
  // that set, and assertAllowedUrl keeps policing every later navigation against it.
  assert.equal(policy.approved.has('http://127.0.0.1:5173'), true);
});

test('the production consent anchor comes from the environment, not only from an injected option', async () => {
  // Every other consent case supplies `projectRoot` explicitly, so the ladder `run()` actually
  // travels — option, then ZENSU_VERIFY_PROJECT_ROOT, then cwd — had no executed case. That
  // matters because the launcher execs the broker through `env -i`: if the variable is not
  // carried, the anchor silently becomes the broker's own cwd while the gate writes under the
  // Session Control record's root, and the broker then refuses every loopback origin while the
  // doctor reports the gate as executing.
  const projectRoot = consentProject(['http://127.0.0.1:5188']);
  const previous = process.env.ZENSU_VERIFY_PROJECT_ROOT;
  process.env.ZENSU_VERIFY_PROJECT_ROOT = projectRoot;
  try {
    const policy = await resolveStartupPolicy('', { pluginRoot: PLUGIN_ROOT });
    assert.equal(policy.mode, 'consent');
    assert.equal(approveConsentOrigin(policy, 'http://127.0.0.1:5188/inventory').origin, 'http://127.0.0.1:5188');
  } finally {
    if (previous === undefined) delete process.env.ZENSU_VERIFY_PROJECT_ROOT;
    else process.env.ZENSU_VERIFY_PROJECT_ROOT = previous;
  }

  // And the launcher must actually carry it IN THE ALLOWLIST: the `env -i` sweep is what makes
  // the env term reachable in production at all. A whole-file match cannot see that — the
  // launcher names the variable in its own prose too, so deleting it from the `for name in`
  // operand list left this check green while the broker's production anchor was stripped. The
  // slice is the operand list itself, and the control fails if that list ever stops matching.
  const launcher = fs.readFileSync(path.resolve(__dirname, '../../scripts/playwright-mcp.sh'), 'utf8');
  const allowlist = (launcher.split(/^\s*for name in \\?$/m)[1] || '').split(/;\s*do$/m)[0] || '';
  assert.notEqual(allowlist.trim(), '', 'control: the env -i allowlist operand list was extracted');
  assert.match(allowlist, /ZENSU_VERIFY_PROJECT_ROOT/, 'the anchor survives the env -i sweep');
  assert.match(allowlist, /ZENSU_VERIFY_NAVIGATION_POLICY_V1/, 'control: its sibling is in the same list');
  assert.match(launcher, /ZENSU_VERIFY_PROJECT_ROOT/);
});

test('the consent policy carries its anchor, and a module fault is refused as unjudged rather than as a gate that never ran', async () => {
  const { consentEvidenceState } = require('../../scripts/playwright-mcp-proxy.js');
  const projectRoot = consentProject(['http://127.0.0.1:5177']);
  const policy = await resolveStartupPolicy('', { pluginRoot: PLUGIN_ROOT, projectRoot });

  // The anchor has to reach the RECORD on the policy, or the reader's directory-component walk
  // is skipped on the one read that writes into the approved set. A previous revision passed it
  // at the call site while the constructor took two parameters, so it was dropped in silence.
  assert.equal(policy.projectRoot, projectRoot);
  assert.equal(consentEvidenceState(policy, 'http://127.0.0.1:5177'), 'present');

  // The anchor is CANONICALIZED before the evidence directory is derived from it. The reader
  // compares its own `realpathSync.native` of the root against the directory it is handed, so a
  // non-canonical spelling makes those two operands differ and the granting read refuses every
  // loopback origin in the project. A symlink to the same tree is the reachable shape: the caller
  // supplies the link, the writer's markers live under the real path.
  const aliasHome = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-consent-alias-')));
  const alias = path.join(aliasHome, 'link');
  let aliased = true;
  try {
    fs.symlinkSync(projectRoot, alias);
  } catch (error) {
    if (!error || error.code !== 'EPERM') throw error;
    aliased = false;
  }
  if (aliased) {
    const aliasPolicy = await resolveStartupPolicy('', { pluginRoot: PLUGIN_ROOT, projectRoot: alias });
    assert.equal(aliasPolicy.projectRoot, projectRoot, 'the policy carries the canonical root, not the caller spelling');
    assert.equal(consentEvidenceState(aliasPolicy, 'http://127.0.0.1:5177'), 'present', 'and the granting read still matches the directory the writer used');
  }

  // A module that cannot be read is a fault in the plugin tree, not a gate that never ran, and
  // the refusal has to say so — otherwise it sends the reader after a gate that is working. The
  // fixture is a plugin root with NO module rather than a policy with an empty `evidenceDir`:
  // that field is re-derived per call now, so an empty one is recoverable and no longer stands
  // in for a module fault. Using it here would have graded the recovery instead.
  const broken = {
    mode: 'consent',
    approved: new Map(),
    pluginRoot: fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-consent-nomod-'))),
    evidenceDir: '',
    projectRoot,
  };
  assert.equal(consentEvidenceState(broken, 'http://127.0.0.1:5177'), 'unjudged');
  assert.throws(() => approveConsentOrigin(broken, 'http://127.0.0.1:5177/x'), /could be judged/);

  // A symlinked `.zensu` is refused by the granting read exactly as the writer refuses it.
  const linked = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-consent-link-')));
  const real = path.join(linked, 'elsewhere', 'state');
  fs.mkdirSync(real, { recursive: true });
  const consent = require('../../hooks/lib/verify-consent-v1.js');
  fs.writeFileSync(
    path.join(real, `verify-consent-exec-scv1_${'a'.repeat(64)}-${consent.evidenceOriginTag('http://127.0.0.1:5178')}.json`),
    `${JSON.stringify({ version: consent.EVIDENCE_VERSION, origin: 'http://127.0.0.1:5178', verdict: 'allowed', at: new Date().toISOString() })}\n`,
  );
  try {
    fs.symlinkSync(path.join(linked, 'elsewhere'), path.join(linked, '.zensu'));
  } catch (error) {
    if (!error || error.code !== 'EPERM') throw error;
    return;
  }
  const linkedPolicy = await resolveStartupPolicy('', { pluginRoot: PLUGIN_ROOT, projectRoot: linked });
  // The reader REFUSES that tree rather than resolving through the link, and the refusal says so:
  // "no in-session evidence" would name a gate that never ran for a directory this read declined
  // to open at all, which is the conflation the state split removed.
  assert.throws(() => approveConsentOrigin(linkedPolicy, 'http://127.0.0.1:5178/x'), /could not be read/);
});

// A plugin root carrying exactly one file: the consent module, with a body this test chooses.
// The `unjudged` fixture above sets `evidenceDir: ''` and returns at the FIRST guard, so the
// module-load throw, the missing-reader arm and the outer catch had no executed case at all.
function stubPluginRoot(body) {
  const root = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-consent-stub-')));
  fs.mkdirSync(path.join(root, 'hooks', 'lib'), { recursive: true });
  fs.writeFileSync(path.join(root, 'hooks', 'lib', 'verify-consent-v1.js'), body);
  return root;
}

test('the granting read names every cause it can distinguish, and refuses rather than reading unguarded', async () => {
  const { consentEvidenceState } = require('../../scripts/playwright-mcp-proxy.js');
  const projectRoot = consentProject(['http://127.0.0.1:5180']);
  const evidenceDir = path.join(projectRoot, '.zensu', 'state');

  // An ANCHORLESS policy must refuse, not read. `liveEvidenceOrigins` runs its realpath equality
  // and component walk only when a root is supplied, so an empty anchor silently DROPPED the
  // containment guard on the one read that grants access — the fail-open direction, and exactly
  // the inertness that hid the round-3 arity defect.
  const anchorless = { mode: 'consent', approved: new Map(), pluginRoot: PLUGIN_ROOT, evidenceDir, projectRoot: '' };
  assert.equal(consentEvidenceState(anchorless, 'http://127.0.0.1:5180'), 'unjudged');

  // A module that THROWS at load is a plugin-tree fault. Reached through a real stub root, so
  // the require and the outer catch are executed rather than argued about.
  const thrower = { mode: 'consent', approved: new Map(), pluginRoot: stubPluginRoot('throw new Error("boom");\n'), evidenceDir, projectRoot };
  assert.equal(consentEvidenceState(thrower, 'http://127.0.0.1:5180'), 'unjudged');
  assert.throws(() => approveConsentOrigin(thrower, 'http://127.0.0.1:5180/x'), /could be judged/);

  // A module missing the READER is the same class.
  const gutted = { mode: 'consent', approved: new Map(), pluginRoot: stubPluginRoot('module.exports = {};\n'), evidenceDir, projectRoot };
  assert.equal(consentEvidenceState(gutted, 'http://127.0.0.1:5180'), 'unjudged');

  // A module missing only MAX_EVIDENCE_AGE_MS still reports `expired`: the expired probe passes
  // its own maxAgeMs and never reads that export, so gating on it degraded a real expiry to
  // `absent` and emitted the wrong cause.
  const REAL = JSON.stringify(path.join(PLUGIN_ROOT, 'hooks', 'lib', 'verify-consent-v1.js'));
  const noConst = stubPluginRoot(`const real = require(${REAL});\nconst copy = Object.assign({}, real);\ndelete copy.MAX_EVIDENCE_AGE_MS;\nmodule.exports = copy;\n`);
  const consent = require('../../hooks/lib/verify-consent-v1.js');
  const staleOrigin = 'http://127.0.0.1:5181';
  fs.writeFileSync(
    path.join(evidenceDir, `verify-consent-exec-scv1_${'a'.repeat(64)}-${consent.evidenceOriginTag(staleOrigin)}.json`),
    `${JSON.stringify({ version: consent.EVIDENCE_VERSION, origin: staleOrigin, verdict: 'allowed', at: new Date(Date.now() - consent.MAX_EVIDENCE_AGE_MS - 60000).toISOString() })}\n`,
  );
  const staleState = { mode: 'consent', approved: new Map(), pluginRoot: PLUGIN_ROOT, evidenceDir, projectRoot };
  assert.equal(consentEvidenceState(staleState, staleOrigin), 'expired');
  assert.equal(consentEvidenceState({ mode: 'consent', approved: new Map(), pluginRoot: noConst, evidenceDir, projectRoot }, staleOrigin), 'expired');

  // The expired refusal names BOTH causes and points at a diagnostic. A gate that has STOPPED
  // running leaves a permanently expired marker — nothing writes, so nothing reaps — and the
  // retry the old text prescribed re-entered this arm forever while blaming the clock.
  assert.throws(() => approveConsentOrigin(staleState, `${staleOrigin}/x`), /older than the accepted window/);
  assert.throws(() => approveConsentOrigin(staleState, `${staleOrigin}/x`), /stopped running/);
  assert.throws(() => approveConsentOrigin(staleState, `${staleOrigin}/x`), /zensu:doctor/);

  // A walk that did not FINISH is not a walk that found nothing, and an unreadable state
  // directory is neither. Collapsing all three into `absent` made the refusal name a gate that
  // had run — so each answers under its own name.
  const seenStub = (record) => stubPluginRoot(`module.exports = { executionEvidencePresent: () => false, executionEvidenceSeen: () => (${JSON.stringify(record)}) };\n`);
  const truncated = { mode: 'consent', approved: new Map(), pluginRoot: seenStub({ present: false, read: true, truncated: true, origin: '', verdict: '' }), evidenceDir, projectRoot };
  assert.equal(consentEvidenceState(truncated, 'http://127.0.0.1:5180'), 'truncated');
  assert.throws(() => approveConsentOrigin(truncated, 'http://127.0.0.1:5180/x'), /too many execution markers/);
  const unread = { mode: 'consent', approved: new Map(), pluginRoot: seenStub({ present: false, read: false, truncated: false, origin: '', verdict: '' }), evidenceDir, projectRoot };
  assert.equal(consentEvidenceState(unread, 'http://127.0.0.1:5180'), 'unread');
  assert.throws(() => approveConsentOrigin(unread, 'http://127.0.0.1:5180/x'), /could not be read/);

  // The LEGACY fallback: a module that exports the boolean reader and not the richer one. The
  // comment above that arm states the degradation as a contract, and no stub had that shape —
  // every one either exported both readers or neither, so the arm had no executed case at all.
  const legacy = {
    mode: 'consent',
    approved: new Map(),
    pluginRoot: stubPluginRoot('module.exports = { executionEvidencePresent: () => true };\n'),
    evidenceDir,
    projectRoot,
  };
  assert.equal(consentEvidenceState(legacy, 'http://127.0.0.1:5181'), 'present', 'a module predating the split degrades to the boolean rather than refusing');
  const legacyAbsent = {
    mode: 'consent',
    approved: new Map(),
    pluginRoot: stubPluginRoot('module.exports = { executionEvidencePresent: () => false };\n'),
    evidenceDir,
    projectRoot,
  };
  assert.equal(consentEvidenceState(legacyAbsent, 'http://127.0.0.1:5181'), 'absent', 'control: the same shape still refuses when the boolean says no');
});

test('AC-009 a url-less new tab is refused before the tab exists', async () => {
  // opensUrl required a truthy url, so `browser_tabs {action:"new"}` skipped both the consent
  // approval and the floor and reached upstream. The tab then opened at about:blank, and every
  // later pre-call assertActiveUrls saw two pages — the allowInitialBlank escape needs exactly
  // one — so the session was wedged for every tool but browser_close.
  const policy = await parsePolicy(rawPolicy('local', 'http://127.0.0.1:5173'));
  let upstreamCalls = 0;
  const server = {
    _requestHandlers: new Map([
      ['tools/list', async () => ({ tools: ALLOWED_TOOLS.map((name) => ({ name })) })],
      ['tools/call', async () => { upstreamCalls += 1; return { content: [] }; }],
    ]),
  };
  installCapabilityBoundary(server, policy, async () => {}, () => ['http://127.0.0.1:5173/inventory']);
  const refused = await server._requestHandlers.get('tools/call')({
    params: { name: 'browser_tabs', arguments: { action: 'new' } },
  });
  assert.equal(refused.isError, true);
  assert.equal(upstreamCalls, 0);

  // Control: the same call WITH an allowed url still reaches upstream, so the refusal is about
  // the missing url and not about browser_tabs.
  const allowed = await server._requestHandlers.get('tools/call')({
    params: { name: 'browser_tabs', arguments: { action: 'new', url: 'http://127.0.0.1:5173/inventory' } },
  });
  assert.equal(allowed.isError, undefined);
  assert.equal(upstreamCalls, 1);

  // A non-'new' action carries no url and must stay unaffected.
  const listTabs = await server._requestHandlers.get('tools/call')({
    params: { name: 'browser_tabs', arguments: { action: 'list' } },
  });
  assert.equal(listTabs.isError, undefined);
  assert.equal(upstreamCalls, 2);
});

test('the evidence directory is re-derived per call, so a transient startup fault is recoverable', async () => {
  const { consentEvidenceState } = require('../../scripts/playwright-mcp-proxy.js');
  // `consentModule` is deliberately re-read on every call, because this process outlives any
  // number of navigations and can outlive the plugin tree it resolved its mode from. The
  // DIRECTORY derived from that module was resolved once at startup and cached, so a module
  // fault in that one window disabled consent approval for the life of the MCP server and then
  // told the user to reinstall a plugin that was fine. The anchor is on the policy; the layout
  // belongs to the module; so the join belongs to the call, not to startup.
  const projectRoot = consentProject(['http://127.0.0.1:5190']);
  const startupFault = { mode: 'consent', approved: new Map(), pluginRoot: PLUGIN_ROOT, evidenceDir: '', projectRoot };
  assert.equal(consentEvidenceState(startupFault, 'http://127.0.0.1:5190'), 'present', 'a recovered module recovers the broker');

  // An ANCHORLESS policy still refuses: the directory cannot be derived without a root, and the
  // containment walk the reader runs is checked against that same root.
  const anchorless = { mode: 'consent', approved: new Map(), pluginRoot: PLUGIN_ROOT, evidenceDir: '', projectRoot: '' };
  assert.equal(consentEvidenceState(anchorless, 'http://127.0.0.1:5190'), 'unjudged');
});

test('every evidence state has its own refusal, and an unrecognized one is never given a cause', () => {
  const proxy = require('../../scripts/playwright-mcp-proxy.js');
  const { CONSENT_EVIDENCE_STATES, consentRefusalFor } = proxy;

  // The state set has ONE owner. `approveConsentOrigin` used to re-spell it as four `if` arms
  // plus a catch-all that ASSERTED a cause — "no in-session evidence that the Zensu consent gate
  // ran for this origin" — so a state added to the producer would have named a fact the probe
  // never established. That is the exact conflation the unread/truncated split removed one layer
  // down, and the sibling doctor renderer already carries an explicit unrecognized-state row.
  assert.equal(Array.isArray(CONSENT_EVIDENCE_STATES), true);
  assert.equal(Object.isFrozen(CONSENT_EVIDENCE_STATES), true);
  assert.deepEqual(
    [...CONSENT_EVIDENCE_STATES].sort(),
    ['absent', 'expired', 'present', 'truncated', 'unjudged', 'unread'],
  );

  // Derived, not hand-listed: every value the producer can return must be a member, so a seventh
  // state cannot reach the refusal ladder without joining the set first.
  const produced = fs.readFileSync(path.join(PLUGIN_ROOT, 'scripts', 'playwright-mcp-proxy.js'), 'utf8')
    .split('function consentEvidenceState(')[1]
    .split('\nfunction ')[0]
    .match(/return '([a-z-]+)'/g)
    .map((m) => m.slice(8, -1));
  assert.notEqual(produced.length, 0, 'control: the producer body was extracted');
  for (const state of produced) {
    assert.equal(CONSENT_EVIDENCE_STATES.includes(state), true, `${state} is produced but not declared`);
  }

  // `present` is not a refusal; every other member names its own cause.
  for (const state of CONSENT_EVIDENCE_STATES) {
    if (state === 'present') { assert.equal(consentRefusalFor(state), '', 'present is not a refusal'); continue; }
    assert.notEqual(consentRefusalFor(state), '', `${state} has no refusal`);
  }
  assert.match(consentRefusalFor('expired'), /older than the accepted window/);
  assert.match(consentRefusalFor('truncated'), /too many execution markers/);
  assert.match(consentRefusalFor('unread'), /could not be read/);
  assert.match(consentRefusalFor('unjudged'), /decision module could not be read/);
  assert.match(consentRefusalFor('absent'), /no in-session evidence/);

  // The residual arm states WHAT it could not interpret and claims nothing about the gate.
  const residual = consentRefusalFor('something-new');
  assert.match(residual, /something-new/, 'the unrecognized state is named');
  assert.equal(/no in-session evidence/.test(residual), false, 'and no cause is asserted for it');

  // Every remedy that prescribes a DELETION is scoped to the marker glob. `.zensu/state/` also
  // holds the CAS workflow documents `skills/doctor/SKILL.md` forbids deleting, and this refusal
  // is read by the MODEL, which holds Bash and reaches that directory ungated — so an unscoped
  // "clear stale files from .zensu/state" is an instruction to wedge the session. Both sibling
  // carriers already scope it.
  const truncated = consentRefusalFor('truncated');
  assert.match(truncated, /verify-consent-exec-\*/, 'the deletion remedy names the marker glob');
  assert.equal(/clear stale files from/.test(truncated), false, 'and never prescribes an unscoped clear');

  // The `unread` refusal names the ANCHOR it read under rather than instructing a comparison
  // neither surface can supply: it printed no path of its own, and the doctor's gate rows print
  // none either, so "compare the two" named nothing the reader could see.
  const unreadWithAnchor = proxy.consentRefusalFor('unread', '/tmp/some-anchor');
  assert.match(unreadWithAnchor, /\/tmp\/some-anchor/, 'the anchor the broker read under is named');
  assert.equal(/compare the two/.test(unreadWithAnchor), false, 'and no uncomparable comparison is instructed');

  // `present` is the one member that decides pass versus refuse, and the approval path compares
  // against the exported member rather than a bare literal — while KEEPING the inequality. Routing
  // the decision through this renderer's empty string would make any future state that renders ''
  // approve silently, which turns a fail-closed test into a fail-open one.
  assert.equal(proxy.CONSENT_EVIDENCE_PRESENT, 'present');
  assert.equal(CONSENT_EVIDENCE_STATES.includes(proxy.CONSENT_EVIDENCE_PRESENT), true);
  const approveBody = fs.readFileSync(path.join(PLUGIN_ROOT, 'scripts', 'playwright-mcp-proxy.js'), 'utf8')
    .split('function approveConsentOrigin(')[1]
    .split('\nfunction ')[0];
  assert.notEqual(approveBody.trim(), '', 'control: the approval body was extracted');
  assert.match(approveBody, /state !== CONSENT_EVIDENCE_PRESENT/, 'the pass test stays an inequality against the owner');
  assert.equal(/state !== 'present'/.test(approveBody), false, 'and no bare literal survives beside the owner');
});
