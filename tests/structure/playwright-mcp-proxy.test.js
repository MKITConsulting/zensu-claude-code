'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
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

test('launcher check-policy subprocess pins parent mode, origin, route, and evidence mode', posixLauncher, () => {
  const launcher = path.resolve(__dirname, '../../scripts/playwright-mcp.sh');
  const runtime = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-mcp-policy-runtime-'));
  const lock = '{"lockfileVersion":3}\n';
  const binDir = path.join(runtime, 'node_modules', '.bin');
  fs.mkdirSync(binDir, { recursive: true });
  fs.writeFileSync(path.join(runtime, 'package.json'), '{"private":true}\n');
  fs.writeFileSync(path.join(runtime, 'package-lock.json'), lock);
  fs.writeFileSync(path.join(runtime, 'node_modules', '.zensu-lock-sha256'),
    `${crypto.createHash('sha256').update(lock).digest('hex')}\n`);
  fs.writeFileSync(path.join(binDir, 'playwright-mcp'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  const run = (raw, mode, origin, route = '/inventory', evidenceMode = 'declared-safe') => spawnSync('bash', [launcher, '--check-policy', mode, origin, route, evidenceMode], {
    env: {
      ...process.env,
      ZENSU_MCP_TEST_MODE: '1',
      ZENSU_MCP_RUNTIME_DIR_OVERRIDE: runtime,
      ZENSU_VERIFY_NAVIGATION_POLICY_V1: raw,
    },
    encoding: 'utf8',
  });
  try {
    assert.equal(run(rawPolicy('local', 'http://127.0.0.1:5173'), 'local', 'http://127.0.0.1:5173').status, 0);
    assert.notEqual(run('', 'local', 'http://127.0.0.1:5173').status, 0);
    assert.notEqual(run(rawPolicy('local', 'http://127.0.0.1:5173'), 'remote', 'http://127.0.0.1:5173').status, 0);
    assert.notEqual(run('{"version":1,"mode":"local","targets":[{"origin":"http://127.0.0.1:5173","evidenceMode":"declared-safe","routes":["/*"]}]}', 'local', 'http://127.0.0.1:5173').status, 0);
    assert.notEqual(run(rawPolicy('local', 'http://127.0.0.1:5173'), 'local', 'http://127.0.0.1:9999').status, 0);
    assert.notEqual(run(rawPolicy('local', 'http://127.0.0.1:5173'), 'local', 'http://127.0.0.1:5173', '/admin').status, 0);
    assert.notEqual(run(rawPolicy('local', 'http://127.0.0.1:5173'), 'local', 'http://127.0.0.1:5173', '/inventory', 'pre-model-redaction').status, 0);
  } finally {
    fs.rmSync(runtime, { recursive: true, force: true });
  }
});

test('launcher install-browser delegates to the integrity-matched pinned runtime', posixLauncher, () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-mcp-runtime-'));
  const binDir = path.join(root, 'node_modules', '.bin');
  fs.mkdirSync(binDir, { recursive: true });
  const lock = '{"lockfileVersion":3}\n';
  fs.writeFileSync(path.join(root, 'package.json'), '{"private":true}\n');
  fs.writeFileSync(path.join(root, 'package-lock.json'), lock);
  fs.writeFileSync(path.join(root, 'node_modules', '.zensu-lock-sha256'), `${crypto.createHash('sha256').update(lock).digest('hex')}\n`);
  const executable = path.join(binDir, 'playwright-mcp');
  fs.writeFileSync(executable, '#!/bin/sh\nprintf "stub:%s\\n" "$1"\n', { mode: 0o755 });
  try {
    const launcher = path.resolve(__dirname, '../../scripts/playwright-mcp.sh');
    const result = spawnSync('bash', [launcher, 'install-browser'], {
      env: { ...process.env, ZENSU_MCP_TEST_MODE: '1', ZENSU_MCP_RUNTIME_DIR_OVERRIDE: root },
      encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'stub:install-browser\n');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
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
