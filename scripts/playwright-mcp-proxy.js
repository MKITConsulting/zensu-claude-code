#!/usr/bin/env node
'use strict';

const dns = require('node:dns');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');

const POLICY_ENV = 'ZENSU_VERIFY_NAVIGATION_POLICY_V1';
const MAX_MESSAGE_BYTES = 16 * 1024 * 1024;
const ALLOWED_TOOLS = Object.freeze([
  'browser_click',
  'browser_close',
  'browser_console_messages',
  'browser_drag',
  'browser_fill_form',
  'browser_handle_dialog',
  'browser_hover',
  'browser_navigate',
  'browser_network_requests',
  'browser_press_key',
  'browser_resize',
  'browser_select_option',
  'browser_snapshot',
  'browser_tabs',
  'browser_take_screenshot',
  'browser_type',
  'browser_wait_for',
]);
const ALLOWED_TOOL_SET = new Set(ALLOWED_TOOLS);

function normalizeHostname(hostname) {
  return String(hostname).toLowerCase().replace(/^\[|\]$/g, '');
}

function ipv4Number(address) {
  const parts = address.split('.').map(Number);
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) return null;
  return parts.reduce((value, part) => ((value << 8) | part) >>> 0, 0);
}

function inIpv4Range(value, base, bits) {
  const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
  return (value & mask) === (ipv4Number(base) & mask);
}

function isPublicIpv4(address) {
  const value = ipv4Number(address);
  if (value === null) return false;
  const denied = [
    ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8],
    ['169.254.0.0', 16], ['172.16.0.0', 12], ['192.0.0.0', 24], ['192.0.2.0', 24],
    ['192.88.99.0', 24], ['192.168.0.0', 16], ['198.18.0.0', 15], ['198.51.100.0', 24],
    ['203.0.113.0', 24], ['224.0.0.0', 4], ['240.0.0.0', 4],
  ];
  return !denied.some(([base, bits]) => inIpv4Range(value, base, bits));
}

function expandIpv6(address) {
  const zoneFree = address.toLowerCase().split('%')[0];
  if (zoneFree.includes('.')) return null;
  const halves = zoneFree.split('::');
  if (halves.length > 2) return null;
  const left = halves[0] ? halves[0].split(':') : [];
  const right = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const missing = 8 - left.length - right.length;
  if (missing < 0 || (halves.length === 1 && missing !== 0)) return null;
  const groups = [...left, ...Array(missing).fill('0'), ...right];
  if (groups.length !== 8 || groups.some((group) => !/^[0-9a-f]{1,4}$/.test(group))) return null;
  return groups.map((group) => Number.parseInt(group, 16));
}

function isPublicIpv6(address) {
  const groups = expandIpv6(address);
  if (!groups) return false;
  const value = groups.reduce((result, group) => (result << 16n) | BigInt(group), 0n);
  const inRange = (base, bits) => {
    const baseGroups = expandIpv6(base);
    const baseValue = baseGroups.reduce((result, group) => (result << 16n) | BigInt(group), 0n);
    const shift = 128n - BigInt(bits);
    return (value >> shift) === (baseValue >> shift);
  };
  if (!inRange('2000::', 3)) return false;
  const specialPurpose = [
    ['2001::', 32],       // Teredo and IETF protocol assignments
    ['2001:1::', 32],    // protocol anycast assignments
    ['2001:2::', 48],    // benchmarking
    ['2001:10::', 28],   // ORCHID
    ['2001:20::', 28],   // ORCHIDv2 and adjacent special assignments
    ['2001:db8::', 32],  // documentation
    ['2002::', 16],      // deprecated 6to4
    ['3fff::', 20],      // documentation
  ];
  return !specialPurpose.some(([base, bits]) => inRange(base, bits));
}

function isPublicAddress(address) {
  const family = net.isIP(address);
  return family === 4 ? isPublicIpv4(address) : family === 6 ? isPublicIpv6(address) : false;
}

function isLoopbackHost(hostname) {
  const normalized = normalizeHostname(hostname);
  if (normalized === '::1') return true;
  const value = ipv4Number(normalized);
  return value !== null && inIpv4Range(value, '127.0.0.0', 8);
}

async function resolveRemoteHost(hostname, resolver) {
  const normalized = normalizeHostname(hostname);
  if (net.isIP(normalized)) {
    if (!isPublicAddress(normalized)) throw new Error('remote address is not globally routable');
    return [normalized];
  }
  const records = await resolver(normalized, { all: true, verbatim: true });
  const addresses = [...new Set(records.map((record) => record.address))];
  if (addresses.length === 0 || addresses.some((address) => !isPublicAddress(address))) {
    throw new Error('remote DNS includes a non-public or unresolved address');
  }
  return addresses;
}

async function parsePolicy(raw, resolver = dns.promises.lookup) {
  if (!raw) return {
    version: 1, mode: 'deny', targets: new Map(), pins: new Map(),
  };
  let value;
  try { value = JSON.parse(raw); }
  catch (_error) { throw new Error('navigation policy is not valid JSON'); }
  const keys = Object.keys(value || {}).sort();
  if (JSON.stringify(keys) !== JSON.stringify(['mode', 'targets', 'version'])) {
    throw new Error('navigation policy contains unknown or missing keys');
  }
  if (value.version !== 1 || !['local', 'remote'].includes(value.mode)
      || !Array.isArray(value.targets) || value.targets.length < 1 || value.targets.length > 8) {
    throw new Error('navigation policy contract is invalid');
  }
  const targets = new Map();
  const pins = new Map();
  for (const rawTarget of value.targets) {
    const targetKeys = Object.keys(rawTarget || {}).sort();
    if (JSON.stringify(targetKeys) !== JSON.stringify(['evidenceMode', 'origin', 'routes'])
        || rawTarget.evidenceMode !== 'declared-safe'
        || !Array.isArray(rawTarget.routes) || rawTarget.routes.length < 1
        || rawTarget.routes.length > 64) {
      throw new Error('navigation target contract is invalid; v1 supports declared-safe evidence only');
    }
    const routes = new Set();
    for (const route of rawTarget.routes) {
      if (typeof route !== 'string' || !route.startsWith('/') || route.includes('?')
          || route.includes('#') || route.includes('*')) {
        throw new Error('evidence route must be an absolute query-free pathname');
      }
      const normalizedRoute = new URL(route, 'https://zensu.invalid').pathname;
      if (normalizedRoute !== route || routes.has(route)) {
        throw new Error('evidence routes must be normalized and unique');
      }
      routes.add(route);
    }
    const rawOrigin = rawTarget.origin;
    if (typeof rawOrigin !== 'string') throw new Error('navigation origin must be a string');
    let parsed;
    try { parsed = new URL(rawOrigin); }
    catch (_error) { throw new Error('navigation origin is invalid'); }
    if (parsed.username || parsed.password || parsed.search || parsed.hash || parsed.pathname !== '/') {
      throw new Error('navigation origin must not contain credentials, path, query, or fragment');
    }
    if (targets.has(parsed.origin)) throw new Error('navigation origins must be unique');
    const hostname = normalizeHostname(parsed.hostname);
    if (value.mode === 'local') {
      if (!['http:', 'https:'].includes(parsed.protocol) || !net.isIP(hostname)
          || !isLoopbackHost(hostname)) {
        throw new Error('local navigation policy accepts literal loopback-IP origins only');
      }
    } else {
      if (parsed.protocol !== 'https:' || isLoopbackHost(hostname)) {
        throw new Error('remote navigation policy requires non-loopback HTTPS origins');
      }
      pins.set(hostname, await resolveRemoteHost(hostname, resolver));
    }
    targets.set(parsed.origin, { origin: parsed.origin, routes, evidenceMode: rawTarget.evidenceMode });
  }
  return { version: 1, mode: value.mode, targets, pins };
}

function assertAllowedUrl(policy, rawUrl, navigation = true) {
  if (policy.mode === 'deny') throw new Error('navigation policy is not configured');
  let parsed;
  try { parsed = new URL(rawUrl); }
  catch (_error) { throw new Error('navigation target is invalid'); }
  if (parsed.username || parsed.password) throw new Error('navigation target contains credentials');
  if (navigation && (parsed.search || parsed.hash)) throw new Error('navigation target contains query or fragment');
  const comparisonOrigin = parsed.protocol === 'ws:'
    ? `http://${parsed.host}`
    : parsed.protocol === 'wss:' ? `https://${parsed.host}` : parsed.origin;
  const target = policy.targets.get(comparisonOrigin);
  if (!target) throw new Error('navigation target origin is not approved');
  if (navigation && !target.routes.has(parsed.pathname)) {
    throw new Error('navigation target route is not approved for evidence');
  }
  return parsed;
}

function chromiumResolverRules(policy) {
  const rules = [];
  for (const [hostname, addresses] of policy.pins) {
    const address = addresses.find((candidate) => net.isIP(candidate) === 4) || addresses[0];
    const target = net.isIP(address) === 6 ? `[${address}]` : address;
    rules.push(`MAP ${hostname} ${target}`);
  }
  return rules.length > 0 ? `--host-resolver-rules=${rules.join(',')}` : null;
}

function deniedToolResult(reason) {
  return {
    content: [{ type: 'text', text: `Zensu browser broker rejected the operation: ${reason}` }],
    isError: true,
  };
}

function assertActiveUrls(policy, urls, allowInitialBlank = false) {
  for (const url of urls) {
    if (url === 'about:blank') {
      if (allowInitialBlank && urls.length === 1) continue;
      throw new Error('about:blank is allowed only as the single initial page before navigation');
    }
    assertAllowedUrl(policy, url, true);
  }
}

function installCapabilityBoundary(server, policy, closeOwned = async () => {}, currentUrls = () => []) {
  const listHandler = server._requestHandlers.get('tools/list');
  const callHandler = server._requestHandlers.get('tools/call');
  if (typeof listHandler !== 'function' || typeof callHandler !== 'function') {
    throw new Error('locked Playwright MCP request handlers are unavailable');
  }
  server._requestHandlers.set('tools/list', async (...args) => {
    const response = await listHandler(...args);
    return { ...response, tools: response.tools.filter((tool) => ALLOWED_TOOL_SET.has(tool.name)) };
  });
  server._requestHandlers.set('tools/call', async (request, ...args) => {
    const name = request?.params?.name;
    if (!ALLOWED_TOOL_SET.has(name)) {
      return deniedToolResult('tool capability is not allowlisted');
    }
    try {
      if (name !== 'browser_close') {
        assertActiveUrls(policy, await currentUrls(), name === 'browser_navigate');
      }
      if (name === 'browser_navigate') assertAllowedUrl(policy, request.params.arguments?.url, true);
      if (name === 'browser_tabs' && request.params.arguments?.action === 'new' && request.params.arguments?.url) {
        assertAllowedUrl(policy, request.params.arguments.url, true);
      }
      if (name === 'browser_take_screenshot'
          && Object.prototype.hasOwnProperty.call(request.params.arguments || {}, 'filename')) {
        throw new Error('screenshot filenames are broker-owned; omit filename and inspect the returned image');
      }
    } catch (error) {
      return deniedToolResult(error.message);
    }
    if (name === 'browser_close') {
      try { return await callHandler(request, ...args); }
      finally { await closeOwned(); }
    }
    const result = await callHandler(request, ...args);
    try {
      assertActiveUrls(policy, await currentUrls());
    } catch (error) {
      return deniedToolResult(error.message);
    }
    return result;
  });
}

async function configureContext(context, policy) {
  await context.route('**/*', async (route) => {
    const request = route.request();
    try {
      assertAllowedUrl(policy, request.url(), request.isNavigationRequest());
      await route.continue();
    } catch (_error) {
      await route.abort('blockedbyclient');
    }
  });
  await context.routeWebSocket('**/*', async (webSocket) => {
    try {
      assertAllowedUrl(policy, webSocket.url(), false);
      webSocket.connectToServer();
    } catch (_error) {
      await webSocket.close({ code: 1008, reason: 'origin rejected by Zensu browser broker' });
    }
  });
}

async function openOwnedContext(chromium, policy) {
  const resolverRule = chromiumResolverRules(policy);
  const args = ['--no-proxy-server'];
  if (resolverRule) args.push(resolverRule);
  const browser = await chromium.launch({ headless: false, args });
  try {
    const context = await browser.newContext({ serviceWorkers: 'block' });
    await configureContext(context, policy);
    return { browser, context };
  } catch (error) {
    await browser.close().catch(() => {});
    throw error;
  }
}

class JsonLineTransport {
  constructor(input = process.stdin, output = process.stdout) {
    this.input = input;
    this.output = output;
    this.buffer = '';
    this.closed = false;
  }

  async start() {
    this.input.setEncoding('utf8');
    this.input.on('data', (chunk) => {
      if (this.closed) return;
      this.buffer += chunk;
      if (Buffer.byteLength(this.buffer) > MAX_MESSAGE_BYTES) {
        this.buffer = '';
        this.onerror?.(new Error('MCP message limit exceeded'));
        this.close();
        this.input.destroy?.();
        return;
      }
      let newline;
      while ((newline = this.buffer.indexOf('\n')) !== -1) {
        const line = this.buffer.slice(0, newline).replace(/\r$/, '');
        this.buffer = this.buffer.slice(newline + 1);
        if (!line) continue;
        try { this.onmessage?.(JSON.parse(line)); }
        catch (error) { this.onerror?.(error); }
      }
    });
    this.input.on('error', (error) => this.onerror?.(error));
    this.input.on('end', () => this.close());
  }

  async send(message) {
    if (!this.closed) this.output.write(`${JSON.stringify(message)}\n`);
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    this.onclose?.();
  }
}

async function run(runtimeDir, dependencies = {}) {
  const policy = await parsePolicy(process.env[POLICY_ENV]);
  const chromium = dependencies.chromium
    || require(path.join(runtimeDir, 'node_modules/playwright')).chromium;
  const createConnection = dependencies.createConnection
    || require(path.join(runtimeDir, 'node_modules/@playwright/mcp')).createConnection;
  let browser;
  let context;
  const outputDir = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-playwright-output-'));
  process.once('exit', () => fs.rmSync(outputDir, { recursive: true, force: true }));
  const closeOwned = async () => {
    const ownedContext = context;
    const ownedBrowser = browser;
    context = undefined;
    browser = undefined;
    await ownedContext?.close().catch(() => {});
    await ownedBrowser?.close().catch(() => {});
  };
  let server;
  try {
    server = await createConnection({ browser: { isolated: false }, outputDir }, async () => {
      await closeOwned();
      ({ browser, context } = await openOwnedContext(chromium, policy));
      return context;
    });
  } catch (error) {
    fs.rmSync(outputDir, { recursive: true, force: true });
    throw error;
  }
  installCapabilityBoundary(server, policy, closeOwned, () => context?.pages().map((page) => page.url()) || []);
  const previousClose = server.onclose;
  server.onclose = async () => {
    previousClose?.();
    await closeOwned();
    fs.rmSync(outputDir, { recursive: true, force: true });
  };
  try {
    await server.connect(new JsonLineTransport(dependencies.input, dependencies.output));
  } catch (error) {
    await closeOwned();
    fs.rmSync(outputDir, { recursive: true, force: true });
    throw error;
  }
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes('--print-allowlist')) {
    process.stdout.write(`${ALLOWED_TOOLS.join('\n')}\n`);
    return;
  }
  const checkIndex = args.indexOf('--check-policy');
  if (checkIndex !== -1) {
    const policy = await parsePolicy(process.env[POLICY_ENV]);
    const [mode, origin, route, evidenceMode] = args.slice(checkIndex + 1, checkIndex + 5);
    if (!mode || !origin || !route || !evidenceMode || args.length !== checkIndex + 5) {
      throw new Error('usage: --check-policy <local|remote> <origin> <route> declared-safe');
    }
    if (policy.mode !== mode) throw new Error('navigation policy mode does not match');
    const target = policy.targets.get(new URL(origin).origin);
    if (!target || target.origin !== origin || target.evidenceMode !== evidenceMode) {
      throw new Error('navigation policy target does not match');
    }
    assertAllowedUrl(policy, new URL(route, `${origin}/`).href, true);
    return;
  }
  const runtimeIndex = args.indexOf('--runtime-dir');
  if (runtimeIndex === -1 || !args[runtimeIndex + 1]) throw new Error('missing locked runtime directory');
  await run(path.resolve(args[runtimeIndex + 1]));
}

module.exports = {
  ALLOWED_TOOLS,
  assertActiveUrls,
  assertAllowedUrl,
  chromiumResolverRules,
  configureContext,
  installCapabilityBoundary,
  isPublicAddress,
  JsonLineTransport,
  openOwnedContext,
  parsePolicy,
  run,
};

if (require.main === module) {
  main().catch((error) => {
    process.stderr.write(`zensu Playwright broker: ${error.message}\n`);
    process.exitCode = 1;
  });
}
