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

const {
  CONSENT_REMOTE_REASON,
  FLOOR_REASONS,
  checkNavigationTarget,
  classifyOrigin,
  isLoopbackHost,
  isPublicAddress,
  normalizeHostname,
  normalizeRoute,
  resolveRemoteHost,
} = require(path.join(__dirname, '..', 'hooks', 'lib', 'verify-navigation-floor-v1.js'));

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
      const normalizedRoute = normalizeRoute(route);
      if (normalizedRoute === null) {
        throw new Error('evidence route must be an absolute query-free pathname');
      }
      if (routes.has(normalizedRoute)) {
        throw new Error('evidence routes must be normalized and unique');
      }
      routes.add(normalizedRoute);
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
        throw new Error(FLOOR_REASONS.LOCAL_LITERAL_LOOPBACK);
      }
    } else {
      if (parsed.protocol !== 'https:' || isLoopbackHost(hostname)) {
        throw new Error(FLOOR_REASONS.REMOTE_HTTPS);
      }
      pins.set(hostname, await resolveRemoteHost(hostname, resolver));
    }
    targets.set(parsed.origin, { origin: parsed.origin, routes, evidenceMode: rawTarget.evidenceMode });
  }
  return { version: 1, mode: value.mode, targets, pins };
}

const CONSENT_HOOK_FILE = 'pre-browser-navigation-consent.sh';

function consentHookRegistered(pluginRoot) {
  try {
    const hookPath = path.join(pluginRoot, 'hooks', CONSENT_HOOK_FILE);
    const hookInfo = fs.lstatSync(hookPath);
    if (!hookInfo.isFile() || hookInfo.isSymbolicLink()) return false;
    const modulePath = path.join(pluginRoot, 'hooks', 'lib', 'verify-consent-v1.js');
    const moduleInfo = fs.lstatSync(modulePath);
    if (!moduleInfo.isFile() || moduleInfo.isSymbolicLink()) return false;
    const { CONSENT_MATCHER } = require(modulePath);
    const registry = JSON.parse(fs.readFileSync(path.join(pluginRoot, 'hooks', 'hooks.json'), 'utf8'));
    const groups = (registry.hooks && registry.hooks.PreToolUse) || [];
    return groups.some((group) => group && group.matcher === CONSENT_MATCHER
      && Array.isArray(group.hooks)
      && group.hooks.some((hook) => typeof hook.command === 'string' && hook.command.includes(`/hooks/${CONSENT_HOOK_FILE}`)));
  } catch (_error) {
    return false;
  }
}

function consentPolicy() {
  return { version: 1, mode: 'consent', targets: new Map(), pins: new Map(), approved: new Map() };
}

async function resolveStartupPolicy(raw, options = {}) {
  if (raw) return parsePolicy(raw, options.resolver);
  const pluginRoot = options.pluginRoot || path.join(__dirname, '..');
  if (consentHookRegistered(pluginRoot)) return consentPolicy();
  return parsePolicy('', options.resolver);
}

function approveConsentOrigin(policy, rawUrl) {
  if (policy.mode !== 'consent') throw new Error('consent approval requires consent mode');
  const classified = classifyOrigin(rawUrl, true);
  if (!classified.ok) throw new Error(classified.reason);
  if (classified.mode !== 'local') throw new Error(CONSENT_REMOTE_REASON);
  if (!policy.approved.has(classified.origin)) {
    policy.approved.set(classified.origin, { origin: classified.origin, approvedAt: new Date().toISOString() });
  }
  return classified;
}

function assertAllowedUrl(policy, rawUrl, navigation = true) {
  if (policy.mode === 'deny') throw new Error('navigation policy is not configured');
  const target = checkNavigationTarget(rawUrl, navigation);
  if (!target.ok) throw new Error(target.reason);
  if (policy.mode === 'consent') {
    if (!policy.approved.has(target.origin)) throw new Error('navigation target origin is not approved');
    return target.parsed;
  }
  const known = policy.targets.get(target.origin);
  if (!known) throw new Error('navigation target origin is not approved');
  if (navigation && !known.routes.has(target.parsed.pathname)) {
    throw new Error('navigation target route is not approved for evidence');
  }
  return target.parsed;
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
      const opensUrl = name === 'browser_navigate'
        || (name === 'browser_tabs' && request.params.arguments?.action === 'new' && request.params.arguments?.url);
      if (opensUrl) {
        const url = request.params.arguments?.url;
        if (policy.mode === 'consent') approveConsentOrigin(policy, url);
        assertAllowedUrl(policy, url, true);
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
  const policy = await resolveStartupPolicy(process.env[POLICY_ENV], { pluginRoot: dependencies.pluginRoot });
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
    const policy = await resolveStartupPolicy(process.env[POLICY_ENV]);
    const [mode, origin, route, evidenceMode] = args.slice(checkIndex + 1, checkIndex + 5);
    if (!mode || !origin || !route || !evidenceMode || args.length !== checkIndex + 5) {
      throw new Error('usage: --check-policy <local|remote> <origin> <route> declared-safe');
    }
    if (policy.mode === 'consent') {
      if (mode !== 'local') throw new Error(CONSENT_REMOTE_REASON);
      if (evidenceMode !== 'declared-safe') throw new Error('navigation target contract is invalid; v1 supports declared-safe evidence only');
      const classified = classifyOrigin(new URL(route, `${origin}/`).href, true);
      if (!classified.ok) throw new Error(classified.reason);
      if (classified.mode !== 'local') throw new Error(CONSENT_REMOTE_REASON);
      if (classified.origin !== origin) {
        throw new Error('navigation origin does not match the route it was checked with');
      }
      process.stdout.write('consent\n');
      return;
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
  CONSENT_REMOTE_REASON,
  approveConsentOrigin,
  assertActiveUrls,
  assertAllowedUrl,
  chromiumResolverRules,
  configureContext,
  consentHookRegistered,
  installCapabilityBoundary,
  isPublicAddress,
  JsonLineTransport,
  openOwnedContext,
  parsePolicy,
  resolveStartupPolicy,
  run,
};

if (require.main === module) {
  main().catch((error) => {
    process.stderr.write(`zensu Playwright broker: ${error.message}\n`);
    process.exitCode = 1;
  });
}
