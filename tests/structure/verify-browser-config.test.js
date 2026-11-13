'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const HELPER = path.resolve(__dirname, '../../scripts/verify-browser-config.js');
const helper = require(HELPER);
const { FLOOR_REASONS } = require('../../hooks/lib/verify-navigation-floor-v1.js');
const consent = require('../../hooks/lib/verify-consent-v1.js');
const authState = require('../../hooks/lib/verify-auth-state-v1.js');

function runDir(t, name = 'run-abc123') {
  const base = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-browser-config-')));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const dir = path.join(base, name);
  fs.mkdirSync(dir);
  return dir;
}

const NO_POLICY = Object.freeze({});
const REPO_ROOT = path.resolve(__dirname, '../..');
const MEASURED = consent.PLAYWRIGHT_CLI_SOURCE_VERSION;
const UNMEASURED = MEASURED.replace(/\d+$/, (patch) => String(Number(patch) + 1));
const PINNED = `npm install -g @playwright/cli@${MEASURED}`;
const installedAs = (found) => () => ({ version: '', owner: '', ...found });
const READY = Object.freeze({ pluginRoot: REPO_ROOT, installedVersion: installedAs({ source: 'manifest', version: MEASURED, owner: '@playwright/cli' }) });

function pluginRoot(t, manifest) {
  const root = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-plugin-root-')));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, 'hooks'));
  for (const file of [consent.CONSENT_HOOK_FILE, consent.CONSENT_RECORDER_FILE]) fs.writeFileSync(path.join(root, 'hooks', file), '#!/bin/bash\n');
  fs.writeFileSync(path.join(root, 'hooks', 'hooks.json'), typeof manifest === 'string' ? manifest : JSON.stringify(manifest));
  return root;
}

function registration(event, file) {
  return { [event]: [{ matcher: consent.CONSENT_MATCHER, hooks: [{ type: 'command', command: `bash "\${CLAUDE_PLUGIN_ROOT}/hooks/${file}"` }] }] };
}

function cliOnPath(t, version) {
  const bin = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-cli-bin-')));
  t.after(() => fs.rmSync(bin, { recursive: true, force: true }));
  for (const name of ['playwright-cli', 'playwright-cli.cmd']) fs.writeFileSync(path.join(bin, name), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  const pkg = path.join(bin, 'node_modules', '@playwright', 'cli');
  fs.mkdirSync(pkg, { recursive: true });
  fs.writeFileSync(path.join(pkg, 'package.json'), JSON.stringify({ name: '@playwright/cli', version }));
  return bin;
}

function policyEnv(mode, targets) {
  return { ZENSU_VERIFY_NAVIGATION_POLICY_V1: JSON.stringify({ version: 1, mode, targets }) };
}

function networkOnlyEnv(mode, targets, networkOnlyOrigins) {
  return { ZENSU_VERIFY_NAVIGATION_POLICY_V1: JSON.stringify({ version: 1, mode, targets, networkOnlyOrigins }) };
}

function target(origin, routes) {
  return routes === undefined ? { origin, evidenceMode: 'declared-safe' } : { origin, evidenceMode: 'declared-safe', routes };
}

function publicResolver(map) {
  return async (hostname) => {
    if (!Object.prototype.hasOwnProperty.call(map, hostname)) throw new Error('ENOTFOUND');
    return map[hostname].map((address) => ({ address, family: address.includes(':') ? 6 : 4 }));
  };
}

test('argument parsing refuses a missing, repeated or unknown argument', () => {
  const good = ['--run-dir', '/tmp/x', '--mode', 'local', '--origin', 'http://127.0.0.1:5173'];
  assert.deepEqual(helper.parseArgs(good), { runDir: '/tmp/x', mode: 'local', origins: ['http://127.0.0.1:5173'], networkOnlyOrigins: [], loginRecipe: null, authOrigin: null });
  const bad = [
    [],
    ['--run-dir', '/tmp/x', '--mode', 'local'],
    ['--run-dir', '/tmp/x', '--origin', 'http://127.0.0.1:1'],
    ['--run-dir', '/tmp/x', '--mode', 'staging', '--origin', 'http://127.0.0.1:1'],
    ['--run-dir', '/tmp/x', '--run-dir', '/tmp/y', '--mode', 'local', '--origin', 'http://127.0.0.1:1'],
    ['--run-dir', '/tmp/x', '--mode', 'local', '--origin'],
    ['--run-dir', '/tmp/x', '--mode', 'local', '--origin', 'http://127.0.0.1:1', '--headed', 'yes'],
  ];
  for (const argv of bad) assert.throws(() => helper.parseArgs(argv), /usage/, JSON.stringify(argv));
  const many = ['--run-dir', '/tmp/x', '--mode', 'local'];
  for (let port = 1; port <= helper.MAX_ORIGINS + 1; port += 1) many.push('--origin', `http://127.0.0.1:${port}`);
  assert.throws(() => helper.parseArgs(many), /at most/);
});

test('argument parsing keeps network-only origins apart and counts them toward the same origin bound', () => {
  const base = ['--run-dir', '/tmp/x', '--mode', 'remote', '--origin', 'https://app.example.com'];
  assert.deepEqual(helper.parseArgs([...base, '--network-only-origin', 'https://api.example.org', '--network-only-origin', 'https://id.example.org']),
    { runDir: '/tmp/x', mode: 'remote', origins: ['https://app.example.com'], networkOnlyOrigins: ['https://api.example.org', 'https://id.example.org'], loginRecipe: null, authOrigin: null });
  assert.throws(() => helper.parseArgs(['--run-dir', '/tmp/x', '--mode', 'remote', '--network-only-origin', 'https://api.example.org']), /usage/);
  assert.throws(() => helper.parseArgs([...base, '--network-only-origin']), /usage/);
  const full = [...base];
  for (let index = 1; index < helper.MAX_ORIGINS; index += 1) full.push('--network-only-origin', `https://api${index}.example.org`);
  assert.equal(helper.parseArgs(full).networkOnlyOrigins.length, helper.MAX_ORIGINS - 1);
  assert.throws(() => helper.parseArgs([...full, '--network-only-origin', 'https://one-more.example.org']), /at most/);
});

test('a local run writes an isolated, origin-restricted config inside the run directory', async (t) => {
  const dir = runDir(t);
  const result = await helper.run(['--run-dir', dir, '--mode', 'local', '--origin', 'http://127.0.0.1:5173', '--origin', 'http://[::1]:8080'], undefined, NO_POLICY, READY);
  assert.equal(result.session, 'zensu-verify-run-abc123');
  assert.equal(result.mode, 'consent');
  assert.equal(result.configPath, path.join(dir, helper.CONFIG_NAME));
  assert.deepEqual(result.origins, ['http://127.0.0.1:5173', 'http://[::1]:8080']);
  const written = JSON.parse(fs.readFileSync(result.configPath, 'utf8'));
  assert.deepEqual(written, result.config);
  assert.equal(written.browser.isolated, true);
  assert.deepEqual(written.browser.launchOptions.args, ['--no-proxy-server']);
  assert.equal(written.browser.contextOptions.serviceWorkers, 'block');
  assert.deepEqual(written.network.allowedOrigins, result.origins);
  assert.equal(written.outputDir, path.join(dir, helper.OUTPUT_DIR_NAME));
  if (process.platform !== 'win32') assert.equal(fs.statSync(result.configPath).mode & 0o777, 0o600);
  assert.deepEqual(fs.readdirSync(dir), [helper.CONFIG_NAME]);
});

test('a local run refuses every origin the navigation floor refuses', async (t) => {
  const dir = runDir(t);
  const refused = [
    ['http://app.localhost:5173', FLOOR_REASONS.LOCAL_LOOPBACK_ONLY],
    ['http://localhost.:5173', FLOOR_REASONS.LOCAL_LOOPBACK_ONLY],
    ['http://192.168.1.10:5173', FLOOR_REASONS.LOCAL_LOOPBACK_ONLY],
    ['https://example.com', FLOOR_REASONS.LOCAL_LOOPBACK_ONLY],
    ['http://user:pw@127.0.0.1:5173', FLOOR_REASONS.CREDENTIALS],
    ['http://127.0.0.1:5173/?token=x', FLOOR_REASONS.QUERY_OR_FRAGMENT],
    ['http://127.0.0.1:5173/#x', FLOOR_REASONS.QUERY_OR_FRAGMENT],
    ['http://127.0.0.1:5173/?', FLOOR_REASONS.QUERY_OR_FRAGMENT],
    ['http://127.0.0.1:5173/app', /must not carry a path/],
    ['ws://127.0.0.1:5173', FLOOR_REASONS.SCHEME],
    ['file:///etc/passwd', FLOOR_REASONS.SCHEME],
    ['not a url', FLOOR_REASONS.INVALID],
  ];
  for (const [origin, reason] of refused) {
    await assert.rejects(helper.run(['--run-dir', dir, '--mode', 'local', '--origin', origin], undefined, NO_POLICY, READY),
      (error) => (reason instanceof RegExp ? reason.test(error.message) : error.message === reason), origin);
  }
  await assert.rejects(helper.run(['--run-dir', dir, '--mode', 'local', '--origin', 'http://127.0.0.1:1', '--origin', 'http://127.0.0.1:1/'], undefined, NO_POLICY, READY),
    /unique/);
  assert.deepEqual(fs.readdirSync(dir), []);
});

test('a local run admits localhost and pins no address for it', async (t) => {
  const dir = runDir(t);
  const neverResolves = async (host) => { throw new Error(`resolved ${host}`); };
  const result = await helper.run(['--run-dir', dir, '--mode', 'local', '--origin', 'http://localhost:4200', '--origin', 'http://localhost:9090'],
    neverResolves, NO_POLICY, READY);
  assert.deepEqual(result.origins, ['http://localhost:4200', 'http://localhost:9090']);
  assert.deepEqual(result.config.browser.launchOptions.args, ['--no-proxy-server']);
  assert.deepEqual(result.config.network.allowedOrigins, ['http://localhost:4200', 'http://localhost:9090']);
  assert.equal(consent.runConfigShape(result.config, result.configPath).ok, true);
});

test('a remote run pins every hostname to a public address and refuses the rest', async (t) => {
  const dir = runDir(t);
  const resolver = publicResolver({
    'preview.example.com': ['93.184.216.34', '2606:2800:220:1:248:1893:25c8:1946'],
    'v6.example.com': ['2606:2800:220:1:248:1893:25c8:1946'],
    'mixed.example.com': ['93.184.216.34', '10.0.0.5'],
    'internal.example.com': ['127.0.0.1'],
  });
  const env = policyEnv('remote', [
    target('https://preview.example.com'), target('https://v6.example.com'), target('https://93.184.216.34'),
    target('https://mixed.example.com'), target('https://internal.example.com'), target('https://unknown.example.com'),
  ]);
  const result = await helper.run(['--run-dir', dir, '--mode', 'remote',
    '--origin', 'https://preview.example.com', '--origin', 'https://v6.example.com', '--origin', 'https://93.184.216.34'], resolver, env, READY);
  assert.equal(result.mode, 'policy');
  assert.deepEqual(result.config.browser.launchOptions.args, [
    '--no-proxy-server',
    '--host-resolver-rules=MAP preview.example.com 93.184.216.34,MAP v6.example.com [2606:2800:220:1:248:1893:25c8:1946]',
  ]);
  assert.deepEqual(result.config.network.allowedOrigins, ['https://preview.example.com', 'https://v6.example.com', 'https://93.184.216.34']);
  const refused = [
    ['https://mixed.example.com', /non-public/],
    ['https://internal.example.com', /non-public/],
    ['https://unknown.example.com', /ENOTFOUND/],
    ['http://preview.example.com', FLOOR_REASONS.REMOTE_HTTPS],
    ['http://93.184.216.34', FLOOR_REASONS.REMOTE_HTTPS],
    ['https://127.0.0.1:8443', FLOOR_REASONS.REMOTE_HTTPS],
    ['https://localhost:8443', FLOOR_REASONS.REMOTE_HTTPS],
    ['https://10.0.0.5', FLOOR_REASONS.REMOTE_NOT_PUBLIC],
  ];
  for (const [origin, reason] of refused) {
    await assert.rejects(helper.run(['--run-dir', dir, '--mode', 'remote', '--origin', origin], resolver, env, READY),
      (error) => (reason instanceof RegExp ? reason.test(error.message) : error.message === reason), origin);
  }
});

test('two remote origins that share a hostname are pinned once', async (t) => {
  const dir = runDir(t);
  const resolver = publicResolver({ 'app.example.com': ['93.184.216.34'] });
  const env = policyEnv('remote', [target('https://app.example.com'), target('https://app.example.com:8443')]);
  const result = await helper.run(['--run-dir', dir, '--mode', 'remote',
    '--origin', 'https://app.example.com', '--origin', 'https://app.example.com:8443'], resolver, env, READY);
  assert.deepEqual(result.config.browser.launchOptions.args, ['--no-proxy-server', '--host-resolver-rules=MAP app.example.com 93.184.216.34']);
  assert.deepEqual(result.origins, ['https://app.example.com', 'https://app.example.com:8443']);
  assert.equal(consent.readRunConfig(result.configPath).ok, true);
});

test('the run config pins a remote origin for consent, and a policy pre-approves only its targets', async (t) => {
  const dir = runDir(t);
  const resolver = publicResolver({ 'preview.example.com': ['93.184.216.34'] });
  const remote = await helper.run(['--run-dir', dir, '--mode', 'remote', '--origin', 'https://preview.example.com'], resolver, NO_POLICY, READY);
  assert.equal(remote.mode, 'consent');
  assert.deepEqual(remote.config.browser.launchOptions.args, ['--no-proxy-server', '--host-resolver-rules=MAP preview.example.com 93.184.216.34']);
  assert.equal(consent.readRunConfig(remote.configPath).ok, true);
  const local = policyEnv('local', [target('http://127.0.0.1:5173', ['/', '/login'])]);
  const admitted = await helper.run(['--run-dir', dir, '--mode', 'local', '--origin', 'http://127.0.0.1:5173'], undefined, local, READY);
  assert.equal(admitted.mode, 'policy');
  const outside = await helper.run(['--run-dir', dir, '--mode', 'local', '--origin', 'http://127.0.0.1:5174'], undefined, local, READY);
  assert.equal(outside.mode, 'consent');
  const mixed = await helper.run(['--run-dir', dir, '--mode', 'local', '--origin', 'http://127.0.0.1:5173', '--origin', 'http://127.0.0.1:5174'],
    undefined, local, READY);
  assert.equal(mixed.mode, 'consent');
  const crossMode = await helper.run(['--run-dir', dir, '--mode', 'remote', '--origin', 'https://preview.example.com'], resolver, local, READY);
  assert.equal(crossMode.mode, 'consent');
  await assert.rejects(helper.run(['--run-dir', dir, '--mode', 'local', '--origin', 'http://127.0.0.1:5173'], undefined,
    { ZENSU_VERIFY_NAVIGATION_POLICY_V1: '{"version":1}' }, READY), new RegExp(consent.REASONS.POLICY_INVALID));
});

test('a remote run allows its network-only origins after its targets and pins every hostname', async (t) => {
  const dir = runDir(t);
  const resolver = publicResolver({
    'app.example.com': ['93.184.216.34'],
    'api.example.org': ['93.184.216.35'],
    'id.example.org': ['2606:2800:220:1:248:1893:25c8:1946'],
  });
  const env = networkOnlyEnv('remote', [target('https://app.example.com')], ['https://api.example.org', 'https://id.example.org', 'https://93.184.216.36']);
  const result = await helper.run(['--run-dir', dir, '--mode', 'remote', '--origin', 'https://app.example.com',
    '--network-only-origin', 'https://api.example.org', '--network-only-origin', 'https://id.example.org',
    '--network-only-origin', 'https://93.184.216.36'], resolver, env, READY);
  assert.equal(result.mode, 'policy');
  assert.deepEqual(result.origins, ['https://app.example.com']);
  assert.deepEqual(result.networkOnlyOrigins, ['https://api.example.org', 'https://id.example.org', 'https://93.184.216.36']);
  assert.deepEqual(result.config.network.allowedOrigins,
    ['https://app.example.com', 'https://api.example.org', 'https://id.example.org', 'https://93.184.216.36']);
  assert.deepEqual(result.config.browser.launchOptions.args, [
    '--no-proxy-server',
    '--host-resolver-rules=MAP app.example.com 93.184.216.34,MAP api.example.org 93.184.216.35,MAP id.example.org [2606:2800:220:1:248:1893:25c8:1946]',
  ]);
  assert.equal(consent.readRunConfig(result.configPath).ok, true);
});

test('a local policy may allow a loopback API without a pin and a public HTTPS identity provider with one', async (t) => {
  const dir = runDir(t);
  const resolver = publicResolver({ 'auth.example.com': ['93.184.216.34'] });
  const env = networkOnlyEnv('local', [target('http://127.0.0.1:4200')], ['http://127.0.0.1:9090', 'https://auth.example.com']);
  const result = await helper.run(['--run-dir', dir, '--mode', 'local', '--origin', 'http://127.0.0.1:4200',
    '--network-only-origin', 'http://127.0.0.1:9090', '--network-only-origin', 'https://auth.example.com'], resolver, env, READY);
  assert.equal(result.mode, 'policy');
  assert.deepEqual(result.config.network.allowedOrigins, ['http://127.0.0.1:4200', 'http://127.0.0.1:9090', 'https://auth.example.com']);
  assert.deepEqual(result.config.browser.launchOptions.args, ['--no-proxy-server', '--host-resolver-rules=MAP auth.example.com 93.184.216.34']);
  assert.equal(consent.readRunConfig(result.configPath).ok, true);
});

test('the helper refuses a network-only origin without a policy, one the policy does not declare, a swapped role and a failed floor', async (t) => {
  const dir = runDir(t);
  const resolver = publicResolver({
    'app.example.com': ['93.184.216.34'],
    'app2.example.com': ['93.184.216.34'],
    'api.example.org': ['93.184.216.35'],
    'internal.example.org': ['10.0.0.5'],
  });
  const remote = networkOnlyEnv('remote', [target('https://app.example.com'), target('https://app2.example.com')],
    ['https://api.example.org', 'https://internal.example.org']);
  const local = networkOnlyEnv('local', [target('http://127.0.0.1:4200')], ['http://127.0.0.1:9090']);
  const app = ['--run-dir', dir, '--mode', 'remote', '--origin', 'https://app.example.com'];
  const loopbackApp = ['--run-dir', dir, '--mode', 'local', '--origin', 'http://127.0.0.1:4200'];
  const refused = [
    [[...loopbackApp, '--network-only-origin', 'http://127.0.0.1:9090'], NO_POLICY, consent.REASONS.NETWORK_ONLY_NEEDS_POLICY],
    [[...loopbackApp, '--network-only-origin', 'https://api.example.org'], NO_POLICY, consent.REASONS.NETWORK_ONLY_NEEDS_POLICY],
    [[...app, '--network-only-origin', 'https://other.example.org'], remote, `https://other.example.org: ${consent.REASONS.NOT_POLICY_NETWORK_ONLY}`],
    [[...app, '--network-only-origin', 'https://app2.example.com'], remote, `https://app2.example.com: ${consent.REASONS.NOT_POLICY_NETWORK_ONLY}`],
    [[...app, '--origin', 'https://api.example.org'], remote, `https://api.example.org: ${consent.REASONS.NETWORK_ONLY_NAVIGATION}`],
    [[...app, '--network-only-origin', 'https://app.example.com'], remote, 'origins must be unique'],
    [[...app, '--network-only-origin', 'https://internal.example.org'], remote, /non-public/],
    [[...app, '--network-only-origin', 'https://10.0.0.5'], remote, FLOOR_REASONS.REMOTE_NOT_PUBLIC],
    [[...app, '--network-only-origin', 'http://api.example.org'], remote, FLOOR_REASONS.REMOTE_HTTPS],
    [[...loopbackApp, '--network-only-origin', 'http://api.example.org'], local, FLOOR_REASONS.NETWORK_ONLY_HTTPS],
    [[...loopbackApp, '--network-only-origin', 'http://127.0.0.1:9091'], local, `http://127.0.0.1:9091: ${consent.REASONS.NOT_POLICY_NETWORK_ONLY}`],
    [[...loopbackApp, '--origin', 'http://127.0.0.1:9090'], local, `http://127.0.0.1:9090: ${consent.REASONS.NETWORK_ONLY_NAVIGATION}`],
  ];
  for (const [argv, env, reason] of refused) {
    await assert.rejects(helper.run(argv, resolver, env, READY),
      (error) => (reason instanceof RegExp ? reason.test(error.message) : error.message === reason), JSON.stringify(argv.slice(4)));
  }
  assert.deepEqual(fs.readdirSync(dir), []);
});

test('the policy check judges a network-only origin by its own operand', async () => {
  const resolver = publicResolver({ 'api.example.org': ['93.184.216.35'], 'internal.example.org': ['10.0.0.5'] });
  const remote = networkOnlyEnv('remote', [target('https://app.example.com')], ['https://api.example.org', 'https://internal.example.org']);
  assert.equal(await helper.checkPolicy(['remote', 'https://api.example.org', 'network-only'], remote, resolver, READY), 'policy');
  await assert.rejects(helper.checkPolicy(['remote', 'https://internal.example.org', 'network-only'], remote, resolver, READY), /non-public/);
  await assert.rejects(helper.checkPolicy(['remote', 'https://app.example.com', 'network-only'], remote, resolver, READY),
    (error) => error.message === `https://app.example.com: ${consent.REASONS.NOT_POLICY_NETWORK_ONLY}`);
  await assert.rejects(helper.checkPolicy(['remote', 'https://api.example.org', 'declared-safe'], remote, resolver, READY),
    (error) => error.message === `https://api.example.org: ${consent.REASONS.NETWORK_ONLY_NAVIGATION}`);
  await assert.rejects(helper.checkPolicy(['local', 'http://127.0.0.1:9090', 'network-only'], NO_POLICY, resolver, READY),
    (error) => error.message === consent.REASONS.NETWORK_ONLY_NEEDS_POLICY);
  const local = networkOnlyEnv('local', [target('http://127.0.0.1:4200')], ['http://127.0.0.1:9090', 'https://api.example.org']);
  assert.equal(await helper.checkPolicy(['local', 'http://127.0.0.1:9090', 'network-only'], local, resolver, READY), 'policy');
  assert.equal(await helper.checkPolicy(['local', 'https://api.example.org', 'network-only'], local, resolver, READY), 'policy');
  await assert.rejects(helper.checkPolicy(['local', 'https://api.example.org', 'declared-safe'], local, resolver, READY),
    (error) => error.message === FLOOR_REASONS.LOCAL_LOOPBACK_ONLY);
  assert.equal(await helper.checkPolicy(['remote', 'https://api.example.org', 'network-only'], local, resolver, READY), 'policy');
});

test('the policy check answers consent or policy per origin and refuses what the gate would refuse', async () => {
  const resolver = publicResolver({ 'preview.example.com': ['93.184.216.34'], 'internal.example.com': ['10.0.0.5'] });
  assert.equal(await helper.checkPolicy(['local', 'http://127.0.0.1:5173', 'declared-safe'], NO_POLICY, resolver, READY), 'consent');
  assert.equal(await helper.checkPolicy(['local', 'http://localhost:5173', 'declared-safe'], NO_POLICY, resolver, READY), 'consent');
  assert.equal(await helper.checkPolicy(['local', 'http://localhost:5173', 'declared-safe'],
    policyEnv('local', [target('http://localhost:5173')]), resolver, READY), 'policy');
  assert.equal(await helper.checkPolicy(['remote', 'https://preview.example.com', 'declared-safe'], NO_POLICY, resolver, READY), 'consent');
  await assert.rejects(helper.checkPolicy(['remote', 'https://internal.example.com', 'declared-safe'], NO_POLICY, resolver, READY), /non-public/);
  const noLookup = () => { throw new Error('the floor must refuse before any DNS lookup'); };
  for (const host of ['https://*.example.com', 'https://{a,b}.example.com']) {
    await assert.rejects(helper.checkPolicy(['remote', host, 'declared-safe'], NO_POLICY, noLookup, READY),
      (error) => error.message === FLOOR_REASONS.HOSTNAME_PATTERN, host);
  }
  for (const local of [policyEnv('local', [target('http://127.0.0.1:5173')]), policyEnv('local', [target('http://127.0.0.1:5173', ['/login'])])]) {
    assert.equal(await helper.checkPolicy(['local', 'http://127.0.0.1:5173', 'declared-safe'], local, resolver, READY), 'policy');
    assert.equal(await helper.checkPolicy(['local', 'http://127.0.0.1:5174', 'declared-safe'], local, resolver, READY), 'consent');
    assert.equal(await helper.checkPolicy(['remote', 'https://preview.example.com', 'declared-safe'], local, resolver, READY), 'consent');
  }
  const remote = policyEnv('remote', [target('https://preview.example.com'), target('https://internal.example.com')]);
  assert.equal(await helper.checkPolicy(['remote', 'https://preview.example.com', 'declared-safe'], remote, resolver, READY), 'policy');
  await assert.rejects(helper.checkPolicy(['remote', 'https://internal.example.com', 'declared-safe'], remote, resolver, READY), /non-public/);
  const usage = [
    [],
    ['local', 'http://127.0.0.1:5173'],
    ['local', 'http://127.0.0.1:5173', 'redacted'],
    ['staging', 'http://127.0.0.1:5173', 'declared-safe'],
    ['local', 'http://127.0.0.1:5173', '/', 'declared-safe'],
    ['local', 'http://127.0.0.1:5173', 'declared-safe', 'extra'],
  ];
  for (const argv of usage) await assert.rejects(helper.checkPolicy(argv, NO_POLICY, resolver, READY), /usage/, JSON.stringify(argv));
  for (const origin of ['http://127.0.0.1:5173/login', 'http://127.0.0.1:5173/?a=1', 'http://127.0.0.1:5173/#b']) {
    await assert.rejects(helper.checkPolicy(['local', origin, 'declared-safe'], NO_POLICY, resolver, READY),
      /must not carry a path|query or fragment/, origin);
  }
});

test('the policy check refuses before any verdict unless both consent hooks and the measured playwright-cli are ready', async (t) => {
  const resolver = publicResolver({ 'preview.example.com': ['93.184.216.34'] });
  const local = ['local', 'http://127.0.0.1:5173', 'declared-safe'];
  await assert.rejects(helper.checkPolicy(local, NO_POLICY, resolver, { ...READY, installedVersion: installedAs({ source: 'manifest', version: '0.1.20', owner: '@playwright/cli' }) }),
    (error) => error.message.startsWith('playwright-cli 0.1.20 is installed') && error.message.includes(`\`${PINNED}\``));
  await assert.rejects(helper.checkPolicy(local, NO_POLICY, resolver, { ...READY, pluginRoot: pluginRoot(t, { hooks: {} }) }),
    (error) => error.message.startsWith('the browser consent gate is not ready') && error.message.includes('/zensu:doctor'));
  await assert.rejects(helper.checkPolicy(['remote', 'https://preview.example.com', 'declared-safe'], NO_POLICY, resolver, { ...READY, installedVersion: installedAs({ source: 'absent' }) }),
    (error) => error.message.startsWith('playwright-cli is not on PATH'));
  assert.equal(await helper.checkPolicy(local, NO_POLICY, resolver, READY), 'consent');
  const empty = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-no-cli-')));
  t.after(() => fs.rmSync(empty, { recursive: true, force: true }));
  const env = { ...process.env };
  delete env.ZENSU_VERIFY_NAVIGATION_POLICY_V1;
  for (const key of Object.keys(env)) if (key.toUpperCase() === 'PATH') delete env[key];
  env.PATH = empty;
  const cli = spawnSync(process.execPath, [HELPER, '--check-policy', ...local], { encoding: 'utf8', env });
  assert.equal(cli.status, 1);
  assert.equal(cli.stdout, '');
  assert.ok(cli.stderr.startsWith('zensu verify browser config: playwright-cli is not on PATH'), cli.stderr);
});

test('the run directory must be an absolute, existing, real directory', async (t) => {
  const dir = runDir(t);
  const origin = ['--mode', 'local', '--origin', 'http://127.0.0.1:5173'];
  await assert.rejects(helper.run(['--run-dir', 'relative/dir', ...origin], undefined, NO_POLICY, READY), /absolute/);
  await assert.rejects(helper.run(['--run-dir', path.join(dir, 'missing'), ...origin], undefined, NO_POLICY, READY), /does not exist/);
  const file = path.join(dir, 'file');
  fs.writeFileSync(file, '');
  await assert.rejects(helper.run(['--run-dir', file, ...origin], undefined, NO_POLICY, READY), /real directory/);
  if (process.platform !== 'win32') {
    const link = path.join(dir, 'link');
    fs.symlinkSync(dir, link);
    await assert.rejects(helper.run(['--run-dir', link, ...origin], undefined, NO_POLICY, READY), /real directory/);
  }
  const weird = runDir(t, '___');
  await assert.rejects(helper.run(['--run-dir', weird, ...origin], undefined, NO_POLICY, READY), /no session name/);
});

test('the helper writes no run config unless both consent hooks are registered on both shell tools', async (t) => {
  const origin = ['--mode', 'local', '--origin', 'http://127.0.0.1:5173'];
  const cases = [
    [{ hooks: registration('PreToolUse', consent.CONSENT_HOOK_FILE) }, /consent hook: registered; consent recorder: unregistered/],
    [{ hooks: registration('PostToolUse', consent.CONSENT_RECORDER_FILE) }, /consent hook: unregistered; consent recorder: registered/],
    ['{not json', /consent hook: unknown; consent recorder: unknown/],
  ];
  for (const [manifest, reason] of cases) {
    const dir = runDir(t);
    await assert.rejects(helper.run(['--run-dir', dir, ...origin], undefined, NO_POLICY, { ...READY, pluginRoot: pluginRoot(t, manifest) }),
      (error) => reason.test(error.message) && error.message.includes('/zensu:doctor'), JSON.stringify(manifest));
    assert.deepEqual(fs.readdirSync(dir), []);
  }
  const both = { hooks: { ...registration('PreToolUse', consent.CONSENT_HOOK_FILE), ...registration('PostToolUse', consent.CONSENT_RECORDER_FILE) } };
  const written = await helper.run(['--run-dir', runDir(t), ...origin], undefined, NO_POLICY, { ...READY, pluginRoot: pluginRoot(t, both) });
  assert.equal(written.mode, 'consent');
});

test('the helper writes no run config for a playwright-cli version other than the measured one, or one it cannot read', async (t) => {
  const origin = ['--mode', 'local', '--origin', 'http://127.0.0.1:5173'];
  assert.notEqual(UNMEASURED, MEASURED);
  const cases = [
    [{ source: 'manifest', version: UNMEASURED, owner: '@playwright/cli' }, `playwright-cli ${UNMEASURED} is installed, but the browser consent gate was measured against ${MEASURED}`],
    [{ source: 'manifest', version: `${MEASURED}-beta.1`, owner: '@playwright/cli' }, `playwright-cli ${MEASURED}-beta.1 is installed`],
    [{ source: 'absent' }, 'playwright-cli is not on PATH'],
    [{ source: 'foreign', owner: 'not-playwright' }, 'the playwright-cli on PATH belongs to the package not-playwright, not @playwright/cli'],
    [{ source: 'malformed' }, 'the package manifest beside the playwright-cli on PATH could not be judged'],
    [{ source: 'unread' }, 'the installed playwright-cli version could not be read from its @playwright/cli package manifest'],
    [{ source: 'self-reported', version: MEASURED }, 'the installed playwright-cli version could not be read from its @playwright/cli package manifest'],
  ];
  for (const [found, cause] of cases) {
    const dir = runDir(t);
    await assert.rejects(helper.run(['--run-dir', dir, ...origin], undefined, NO_POLICY, { ...READY, installedVersion: installedAs(found) }),
      (error) => error.message.includes(cause) && error.message.includes(`\`${PINNED}\``), JSON.stringify(found));
    assert.deepEqual(fs.readdirSync(dir), []);
  }
});

test('the helper names the remedy each version answer needs, and adds the PATH advice only for a PATH entry read against the working directory or a playwright-cli outside its package', async (t) => {
  const origin = ['--mode', 'local', '--origin', 'http://127.0.0.1:5173'];
  const moved = 'remove that entry from PATH, or move it behind the directory that holds playwright-cli';
  const cases = [
    [{ source: 'cwd-relative', entry: '' }, 'an empty PATH entry comes before or holds the playwright-cli on PATH, and the shell reads it against the working directory of each call', moved],
    [{ source: 'cwd-relative', entry: 'node_modules/.bin' }, 'the relative PATH entry "node_modules/.bin" comes before or holds the playwright-cli on PATH', moved],
    [{ source: 'unread' }, 'the playwright-cli on PATH resolves to no such manifest, as a wrapper script outside the package does', `install the measured version with \`${PINNED}\`, and put the directory npm installs it into first on PATH, ahead of any wrapper`],
    [{ source: 'foreign', owner: 'not-playwright' }, 'the playwright-cli on PATH belongs to the package not-playwright, not @playwright/cli', `install the measured version with \`${PINNED}\``],
    [{ source: 'malformed' }, 'the package manifest beside the playwright-cli on PATH could not be judged', `install the measured version with \`${PINNED}\``],
    [{ source: 'absent' }, 'playwright-cli is not on PATH', `install the measured version with \`${PINNED}\``],
    [{ source: 'manifest', version: UNMEASURED, owner: '@playwright/cli' }, `playwright-cli ${UNMEASURED} is installed, but the browser consent gate was measured against`, `install the measured version with \`${PINNED}\``],
    [{ source: 'self-reported', version: MEASURED }, 'the playwright-cli on PATH resolves to no such manifest, as a wrapper script outside the package does', `install the measured version with \`${PINNED}\``],
  ];
  for (const [found, cause, remedy] of cases) {
    const dir = runDir(t);
    await assert.rejects(helper.run(['--run-dir', dir, ...origin], undefined, NO_POLICY, { ...READY, installedVersion: installedAs(found) }),
      (error) => error.message.includes(cause) && error.message.endsWith(`, so no run config is written; ${remedy}`), JSON.stringify(found));
    assert.deepEqual(fs.readdirSync(dir), []);
  }
  if (process.platform === 'win32') return;
  const env = { ...process.env, PATH: `${path.delimiter}${cliOnPath(t, MEASURED)}` };
  delete env.ZENSU_VERIFY_NAVIGATION_POLICY_V1;
  const other = runDir(t, 'run-cwd');
  const refused = spawnSync(process.execPath, [HELPER, '--run-dir', other, ...origin], { encoding: 'utf8', env, cwd: path.dirname(other) });
  assert.equal(refused.status, 1);
  assert.ok(refused.stderr.startsWith('zensu verify browser config: an empty PATH entry comes before or holds the playwright-cli on PATH'), refused.stderr);
  assert.deepEqual(fs.readdirSync(other), []);
});

test('the CLI prints the session, the config path and each origin, and exits 1 with a named reason', (t) => {
  const dir = runDir(t);
  const env = { ...process.env };
  delete env.ZENSU_VERIFY_NAVIGATION_POLICY_V1;
  const pathKey = Object.keys(env).find((key) => key.toUpperCase() === 'PATH') || 'PATH';
  const basePath = env[pathKey] || '';
  env[pathKey] = `${cliOnPath(t, MEASURED)}${path.delimiter}${basePath}`;
  const ok = spawnSync(process.execPath, [HELPER, '--run-dir', dir, '--mode', 'local', '--origin', 'http://127.0.0.1:5173'], { encoding: 'utf8', env });
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(ok.stdout, `session=zensu-verify-run-abc123\nconfig=${path.join(dir, helper.CONFIG_NAME)}\nmode=consent\norigin=http://127.0.0.1:5173\n`);
  const bad = spawnSync(process.execPath, [HELPER, '--run-dir', dir, '--mode', 'local', '--origin', 'http://app.localhost:5173'], { encoding: 'utf8', env });
  assert.equal(bad.status, 1);
  assert.equal(bad.stdout, '');
  assert.equal(bad.stderr, `zensu verify browser config: ${FLOOR_REASONS.LOCAL_LOOPBACK_ONLY}\n`);
  assert.equal(ok.stderr, '');
  const check = spawnSync(process.execPath, [HELPER, '--check-policy', 'local', 'http://127.0.0.1:5173', 'declared-safe'], { encoding: 'utf8', env });
  assert.equal(check.status, 0, check.stderr);
  assert.equal(check.stdout, 'consent\n');
  assert.equal(check.stderr, '');
  const remoteCheck = spawnSync(process.execPath, [HELPER, '--check-policy', 'remote', 'https://93.184.216.34', 'declared-safe'], { encoding: 'utf8', env });
  assert.equal(remoteCheck.status, 0, remoteCheck.stderr);
  assert.equal(remoteCheck.stdout, 'consent\n');
  assert.equal(remoteCheck.stderr, '');
  const refused = spawnSync(process.execPath, [HELPER, '--check-policy', 'remote', 'https://*.example.com', 'declared-safe'], { encoding: 'utf8', env });
  assert.equal(refused.status, 1);
  assert.equal(refused.stdout, '');
  assert.equal(refused.stderr, `zensu verify browser config: ${FLOOR_REASONS.HOSTNAME_PATTERN}\n`);
  const other = runDir(t, 'run-stale');
  const stale = spawnSync(process.execPath, [HELPER, '--run-dir', other, '--mode', 'local', '--origin', 'http://127.0.0.1:5173'],
    { encoding: 'utf8', env: { ...env, [pathKey]: `${cliOnPath(t, '0.1.20')}${path.delimiter}${basePath}` } });
  assert.equal(stale.status, 1);
  assert.equal(stale.stdout, '');
  assert.ok(stale.stderr.startsWith('zensu verify browser config: playwright-cli 0.1.20 is installed, but the browser consent gate was measured against '), stale.stderr);
  assert.ok(stale.stderr.includes(PINNED), stale.stderr);
  assert.deepEqual(fs.readdirSync(other), []);
});

test('the CLI prints one network-only-origin line per network-only origin and checks one through its operand', (t) => {
  const dir = runDir(t);
  const pathKey = Object.keys(process.env).find((key) => key.toUpperCase() === 'PATH') || 'PATH';
  const env = {
    ...process.env,
    ...networkOnlyEnv('local', [target('http://127.0.0.1:4200')], ['http://127.0.0.1:9090']),
    [pathKey]: `${cliOnPath(t, MEASURED)}${path.delimiter}${process.env[pathKey] || ''}`,
  };
  const ok = spawnSync(process.execPath, [HELPER, '--run-dir', dir, '--mode', 'local', '--origin', 'http://127.0.0.1:4200',
    '--network-only-origin', 'http://127.0.0.1:9090'], { encoding: 'utf8', env });
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(ok.stdout, `session=zensu-verify-run-abc123\nconfig=${path.join(dir, helper.CONFIG_NAME)}\nmode=policy\n`
    + 'origin=http://127.0.0.1:4200\nnetwork-only-origin=http://127.0.0.1:9090\n');
  const check = spawnSync(process.execPath, [HELPER, '--check-policy', 'local', 'http://127.0.0.1:9090', 'network-only'], { encoding: 'utf8', env });
  assert.equal(check.status, 0, check.stderr);
  assert.equal(check.stdout, 'policy\n');
  const usage = spawnSync(process.execPath, [HELPER, '--check-policy', 'local', 'http://127.0.0.1:9090', 'api'], { encoding: 'utf8', env });
  assert.equal(usage.status, 1);
  assert.equal(usage.stderr, 'zensu verify browser config: usage: verify-browser-config.js --check-policy <local|remote> <origin> <declared-safe|network-only>\n');
});

test('the CLI notes on stderr when a present policy leaves an origin to the permission prompt, and only then', (t) => {
  const pathKey = Object.keys(process.env).find((key) => key.toUpperCase() === 'PATH') || 'PATH';
  const env = {
    ...process.env,
    ZENSU_VERIFY_NAVIGATION_POLICY_V1: JSON.stringify({ version: 1, mode: 'local', targets: [target('http://127.0.0.1:4200')] }),
    [pathKey]: `${cliOnPath(t, MEASURED)}${path.delimiter}${process.env[pathKey] || ''}`,
  };
  const note = `zensu verify browser config: note: ${helper.POLICY_CONSENT_NOTE}\n`;
  assert.match(helper.POLICY_CONSENT_NOTE, /permission mode bypassPermissions or dontAsk\) is denied them at open$/);
  const named = spawnSync(process.execPath, [HELPER, '--check-policy', 'local', 'http://127.0.0.1:4200', 'declared-safe'], { encoding: 'utf8', env });
  assert.equal(named.status, 0, named.stderr);
  assert.equal(named.stdout, 'policy\n');
  assert.equal(named.stderr, '');
  for (const args of [['local', 'http://127.0.0.1:4201'], ['remote', 'https://93.184.216.34']]) {
    const other = spawnSync(process.execPath, [HELPER, '--check-policy', ...args, 'declared-safe'], { encoding: 'utf8', env });
    assert.equal(other.status, 0, other.stderr);
    assert.equal(other.stdout, 'consent\n', args.join(' '));
    assert.equal(other.stderr, note, args.join(' '));
  }
  const allNamed = spawnSync(process.execPath, [HELPER, '--run-dir', runDir(t), '--mode', 'local', '--origin', 'http://127.0.0.1:4200'],
    { encoding: 'utf8', env });
  assert.equal(allNamed.status, 0, allNamed.stderr);
  assert.match(allNamed.stdout, /^mode=policy$/m);
  assert.equal(allNamed.stderr, '');
  const partly = spawnSync(process.execPath, [HELPER, '--run-dir', runDir(t, 'run-partly'), '--mode', 'local',
    '--origin', 'http://127.0.0.1:4200', '--origin', 'http://127.0.0.1:4201'], { encoding: 'utf8', env });
  assert.equal(partly.status, 0, partly.stderr);
  assert.match(partly.stdout, /^mode=consent$/m);
  assert.equal(partly.stderr, note);
});

const LOGIN_SECRET = 'eyJhbGciOiJIUzI1NiJ9.test-account-session';
const APP = 'http://127.0.0.1:4300';

function loginProject(t, options = {}) {
  const root = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-login-project-')));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const dir = path.join(root, '.zensu', 'verify-feature-runs', options.leaf || 'run-login1');
  fs.mkdirSync(dir, { recursive: true });
  const origin = options.origin || APP;
  const host = new URL(origin).hostname;
  const state = options.state || {
    cookies: [
      { name: 'sid', value: LOGIN_SECRET, domain: host, path: '/', expires: -1, httpOnly: true, secure: false, sameSite: 'Lax' },
      { name: 'tracker', value: 'x', domain: 'tracker.example.net', path: '/', expires: -1, httpOnly: false, secure: true, sameSite: 'None' },
    ],
    origins: [
      { origin, localStorage: [{ name: 'token', value: LOGIN_SECRET }] },
      { origin: 'https://tracker.example.net', localStorage: [{ name: 'id', value: 'x' }] },
    ],
  };
  fs.writeFileSync(path.join(root, 'state.json'), typeof state === 'string' ? state : JSON.stringify(state));
  const script = options.script || [
    'printf "%s\\n%s\\n%s\\n" "$ZENSU_AUTH_ARTIFACT_DIR" "$ZENSU_AUTH_BASE_URL" "$ZENSU_APP_ORIGIN" > seen-env.txt',
    `echo "password ${LOGIN_SECRET}" >&2`,
    'mkdir -p "$ZENSU_AUTH_ARTIFACT_DIR/nested"',
    'cp state.json "$ZENSU_AUTH_ARTIFACT_DIR/nested/state.json"',
    'echo "STORAGE_STATE=$ZENSU_AUTH_ARTIFACT_DIR/nested/state.json"',
  ].join('\n');
  fs.writeFileSync(path.join(root, 'login.sh'), `${script}\n`, { mode: 0o755 });
  const auth = options.auth || ['auth:', '  mode: login-script', '  loginScript: "bash ./login.sh" # runs in the project root', '  artifact: storageState', '  PASSWORD_ENV: VERIFY_TEST_PASSWORD'];
  fs.writeFileSync(path.join(root, '.zensu', 'runtime.yaml'), ['version: 1', ...auth, 'validate:', '  driver: browser', ''].join('\n'));
  return { root, dir: fs.realpathSync.native(dir), recipe: path.join(root, '.zensu', 'runtime.yaml'), origin };
}

function loginArgs(project, extra = []) {
  return ['--run-dir', project.dir, '--mode', 'local', '--origin', project.origin, '--login-recipe', project.recipe, ...extra];
}

async function loginFails(project, kind, argv = loginArgs(project), resolver, login = {}) {
  await assert.rejects(helper.run(argv, resolver, NO_POLICY, READY, login), (error) => error.message === `login failed: ${kind}` && error.loginFailure === kind, kind);
  assert.equal(fs.existsSync(path.join(project.dir, helper.CONFIG_NAME)), false, `${kind} writes no run config`);
  assert.equal(fs.existsSync(path.join(project.dir, 'auth', 'storage-state.json')), false, `${kind} leaves no state`);
  assert.equal(fs.existsSync(path.join(project.dir, 'auth', 'artifact')), false, `${kind} removes the artifact directory`);
}

test('argument parsing takes one login recipe and one auth origin, and an auth origin only beside a recipe', () => {
  const base = ['--run-dir', '/tmp/x', '--mode', 'local', '--origin', APP];
  assert.deepEqual(helper.parseArgs([...base, '--login-recipe', '/p/.zensu/runtime.yaml', '--auth-origin', 'http://127.0.0.1:4301']),
    { runDir: '/tmp/x', mode: 'local', origins: [APP], networkOnlyOrigins: [], loginRecipe: '/p/.zensu/runtime.yaml', authOrigin: 'http://127.0.0.1:4301' });
  for (const argv of [
    [...base, '--auth-origin', 'http://127.0.0.1:4301'],
    [...base, '--login-recipe', '/a', '--login-recipe', '/b'],
    [...base, '--login-recipe', '/a', '--auth-origin', APP, '--auth-origin', APP],
    [...base, '--login-recipe'],
  ]) {
    assert.throws(() => helper.parseArgs(argv), /usage/, JSON.stringify(argv));
  }
});

test('the auth block reader takes key: scalar lines only and refuses the whole block for any other YAML construct', () => {
  const read = (lines) => helper.readAuthBlock(['version: 1', ...lines, 'validate:', '  driver: browser'].join('\n'));
  assert.deepEqual(read(['auth:', '  mode: login-script', "  loginScript: 'make e2e-session' # quoted", '  artifact: storageState', '  baseUrl: "http://127.0.0.1:5173"', '  environment: test']), {
    mode: 'login-script', loginScript: 'make e2e-session', artifact: 'storageState', baseUrl: 'http://127.0.0.1:5173', environment: 'test',
  });
  assert.deepEqual(read(['auth: # comment', '', '  # note', '  loginScript: "a \\"b\\" \\\\ \\u0041"', "  other: 'it''s'", '  plain: make a#b # trailing']), {
    loginScript: 'a "b" \\ A', other: "it's", plain: 'make a#b',
  });
  for (const lines of [
    [],
    ['auth: { mode: login-script }'],
    ['auth: none'],
    ['auth :', '  mode: login-script'],
    ['auth:', '  mode: [login-script]'],
    ['auth:', '  mode: {a: b}'],
    ['auth:', '  loginScript: |', '    make e2e'],
    ['auth:', '  loginScript: >', '    make e2e'],
    ['auth:', '  loginScript: &a make'],
    ['auth:', '  loginScript: *a'],
    ['auth:', '  loginScript: !!str make'],
    ['auth:', '  loginScript: "make', '    e2e"'],
    ['auth:', '  loginScript: make', '    e2e'],
    ['auth:', '  nested:', '    key: value'],
    ['auth:', '  mode: a', '  mode: b'],
    ['auth:', '  mode: login-script', 'auth:', '  mode: none'],
    ['auth:', '\tmode: login-script'],
    ['auth:', '  mode: a: b'],
    ['auth:', '  "mode": login-script'],
    ['auth:', '  - mode'],
    ['auth:', '  mode: "\\q"'],
    ['auth:', '  mode:'],
    ['auth:', '  mode: login-script', '   artifact: storageState'],
  ]) {
    assert.equal(read(lines), null, JSON.stringify(lines));
  }
});

test('a signed-in run is named zensu-verify-auth-<slug>, and a plain run never takes that prefix', () => {
  assert.equal(helper.sessionName('/x/run-abc', { signedIn: true }), 'zensu-verify-auth-run-abc');
  assert.equal(helper.sessionName(`/x/${'a'.repeat(60)}`, { signedIn: true }), `zensu-verify-auth-${'a'.repeat(35)}`);
  assert.equal(helper.sessionName('/x/run-abc'), 'zensu-verify-run-abc');
  assert.equal(helper.sessionName('/x/auth-abc'), 'zensu-verify-run-auth-abc');
  assert.equal(helper.sessionName('/x/Auth'), 'zensu-verify-run-auth');
  assert.equal(helper.sessionName('/x/authority'), 'zensu-verify-authority');
  for (const name of [helper.sessionName(`/x/${'b'.repeat(60)}`, { signedIn: true }), helper.sessionName(`/x/auth-${'c'.repeat(60)}`)]) {
    assert.match(name, consent.SESSION_RE);
  }
});

test('a login run writes a signed-in run config whose private state keeps only the run origins and leaves no artifact behind', async (t) => {
  const project = loginProject(t);
  const result = await helper.run(loginArgs(project), undefined, NO_POLICY, READY);
  assert.equal(result.login, 'state-restored');
  assert.equal(result.session, 'zensu-verify-auth-run-login1');
  const statePath = path.join(project.dir, 'auth', 'storage-state.json');
  assert.equal(result.config.browser.contextOptions.storageState, statePath);
  assert.deepEqual(Object.keys(result.config.browser.contextOptions).sort(), ['serviceWorkers', 'storageState']);
  assert.equal(consent.runConfigShape(result.config, result.configPath).statePath, statePath);
  const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
  assert.deepEqual(state.cookies.map((cookie) => cookie.name), ['sid']);
  assert.deepEqual(state.origins.map((entry) => entry.origin), [APP]);
  if (process.platform !== 'win32') {
    assert.equal(fs.statSync(statePath).mode & 0o777, 0o600);
    assert.equal(fs.statSync(path.join(project.dir, 'auth')).mode & 0o777, 0o700);
  }
  assert.equal(fs.readFileSync(path.join(project.dir, 'auth', '.gitignore'), 'utf8'), '*\n');
  assert.deepEqual(fs.readdirSync(path.join(project.dir, 'auth')).sort(), ['.gitignore', 'storage-state.json']);
  const seen = fs.readFileSync(path.join(project.root, 'seen-env.txt'), 'utf8').trim().split('\n');
  assert.deepEqual(seen, [path.join(project.dir, 'auth', 'artifact'), APP, APP]);
  const config = JSON.parse(fs.readFileSync(result.configPath, 'utf8'));
  assert.equal(JSON.stringify(config).includes(LOGIN_SECRET), false);
  const again = await helper.run(loginArgs(project, ['--origin', 'http://127.0.0.1:4301', '--auth-origin', 'http://127.0.0.1:4301']), undefined, NO_POLICY, READY);
  assert.equal(again.login, 'state-restored');
  assert.deepEqual(fs.readFileSync(path.join(project.root, 'seen-env.txt'), 'utf8').trim().split('\n')[1], 'http://127.0.0.1:4301');
  fs.rmSync(path.join(project.root, 'seen-env.txt'));
  await assert.rejects(helper.run(loginArgs(project, ['--auth-origin', 'http://127.0.0.1:4302']), undefined, NO_POLICY, READY),
    /--auth-origin must be one of the --origin values/);
  assert.equal(fs.existsSync(path.join(project.root, 'seen-env.txt')), false);
});

test('a login run fails with one fixed class, writes no run config and keeps no state or artifact', async (t) => {
  await loginFails(loginProject(t, { script: 'exit 3' }), 'exit 3');
  await loginFails(loginProject(t, { script: `echo "${LOGIN_SECRET}"\necho second` }), 'contract');
  await loginFails(loginProject(t, { script: `echo "STORAGE_STATE=$PWD/state.json"` }), 'artifact-path');
  await loginFails(loginProject(t, { script: 'echo "STORAGE_STATE=relative/state.json"' }), 'artifact-path');
  await loginFails(loginProject(t, { state: `${LOGIN_SECRET} not json` }), 'artifact-shape');
  await loginFails(loginProject(t, { state: { cookies: [{ name: 'x', value: 'y', domain: 'tracker.example.net' }], origins: [] } }), 'artifact-scope');
  await loginFails(loginProject(t, { script: 'head -c 70000 /dev/zero | tr "\\0" a' }), 'contract');
  const slow = loginProject(t, { script: 'sleep 30 &\necho $! > sleeper.pid\nwait' });
  await loginFails(slow, 'timeout', loginArgs(slow), undefined, { timeoutMs: 1500 });
  const pid = Number(fs.readFileSync(path.join(slow.root, 'sleeper.pid'), 'utf8').trim());
  if (process.platform !== 'win32' && pid > 0) {
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.throws(() => process.kill(pid, 0), /ESRCH/, 'the timed-out login script loses its whole process group');
  }
  for (const auth of [
    ['auth:', '  mode: none'],
    ['auth:', '  mode: login-script', '  loginScript: "bash ./login.sh"', '  artifact: bearer-token-file'],
    ['auth:', '  mode: login-script', '  artifact: storageState'],
    ['auth:', '  mode: login-script', '  loginScript: |', '    bash ./login.sh', '  artifact: storageState'],
  ]) {
    await loginFails(loginProject(t, { auth }), 'recipe');
  }
  const outside = loginProject(t);
  const foreign = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-foreign-recipe-')));
  t.after(() => fs.rmSync(foreign, { recursive: true, force: true }));
  fs.copyFileSync(outside.recipe, path.join(foreign, 'runtime.yaml'));
  await loginFails(outside, 'recipe', loginArgs({ ...outside, recipe: path.join(foreign, 'runtime.yaml') }));
  if (process.platform !== 'win32') {
    const linked = loginProject(t);
    const target = path.join(linked.root, 'real.yaml');
    fs.renameSync(linked.recipe, target);
    fs.symlinkSync(target, linked.recipe);
    await loginFails(linked, 'recipe');
  }
});

test('a login run needs a run directory inside .zensu/verify-feature-runs and refuses foreign entries in its auth folder', async (t) => {
  const project = loginProject(t);
  await assert.rejects(helper.run(['--run-dir', runDir(t), '--mode', 'local', '--origin', APP, '--login-recipe', project.recipe], undefined, NO_POLICY, READY),
    /with --login-recipe the run directory must be <project>\/\.zensu\/verify-feature-runs\/<leaf>/);
  fs.mkdirSync(path.join(project.dir, 'auth'));
  fs.writeFileSync(path.join(project.dir, 'auth', 'notes.txt'), 'x');
  await assert.rejects(helper.run(loginArgs(project), undefined, NO_POLICY, READY), /entries this helper did not write/);
  assert.equal(fs.existsSync(path.join(project.root, 'seen-env.txt')), false, 'the login script never ran');
});

test('a remote login run needs the recipe to bind the application origin and declare a test or production environment', async (t) => {
  const resolver = publicResolver({ 'app.example.com': ['93.184.216.34'] });
  const remote = 'https://app.example.com';
  const auth = (extra) => ['auth:', '  mode: login-script', '  loginScript: "bash ./login.sh"', '  artifact: storageState', ...extra];
  const args = (project) => ['--run-dir', project.dir, '--mode', 'remote', '--origin', remote, '--login-recipe', project.recipe];
  for (const extra of [
    [],
    ['  appOrigin: "https://other.example.com"'],
    ['  appOrigin: "https://app.example.com"'],
    ['  appOrigin: "https://app.example.com"', '  environment: staging'],
    ['  appOrigin: "https://app.example.com/path"', '  environment: test'],
    ['  appOrigin: "https://app.example.com"', '  environment: test', '  baseUrl: "https://login.example.com"'],
  ]) {
    const project = loginProject(t, { origin: remote, auth: auth(extra) });
    await loginFails(project, 'recipe', args(project), resolver);
  }
  for (const environment of ['test', 'production']) {
    const project = loginProject(t, { origin: remote, auth: auth(['  appOrigin: "https://app.example.com"', `  environment: ${environment}`, '  baseUrl: "https://app.example.com/"']) });
    const result = await helper.run(args(project), resolver, NO_POLICY, READY);
    assert.equal(result.login, 'state-restored', environment);
    assert.deepEqual(result.config.browser.launchOptions.args, ['--no-proxy-server', '--host-resolver-rules=MAP app.example.com 93.184.216.34']);
  }
  const local = loginProject(t, { auth: auth(['  appOrigin: "http://127.0.0.1:9"', '  baseUrl: "http://127.0.0.1:9"']) });
  assert.equal((await helper.run(loginArgs(local), undefined, NO_POLICY, READY)).login, 'state-restored');
  const wide = publicResolver({ 'app.example.com': ['93.184.216.34'], 'collector.example.net': ['93.184.216.35'] });
  const collector = loginProject(t, { origin: remote, auth: auth(['  appOrigin: "https://app.example.com"', '  environment: test']) });
  await loginFails(collector, 'recipe', [...args(collector), '--origin', 'https://collector.example.net', '--auth-origin', 'https://collector.example.net'], wide);
  assert.equal(fs.existsSync(path.join(collector.root, 'seen-env.txt')), false);
});

test('the CLI prints login=state-restored for a signed-in run and only the failure class when the login fails', (t) => {
  const pathKey = Object.keys(process.env).find((key) => key.toUpperCase() === 'PATH') || 'PATH';
  const env = { ...process.env, [pathKey]: `${cliOnPath(t, MEASURED)}${path.delimiter}${process.env[pathKey] || ''}` };
  delete env.ZENSU_VERIFY_NAVIGATION_POLICY_V1;
  const project = loginProject(t);
  const signed = spawnSync(process.execPath, [HELPER, ...loginArgs(project)], { encoding: 'utf8', env });
  assert.equal(signed.status, 0, signed.stderr);
  const lines = signed.stdout.trim().split('\n');
  assert.equal(lines[0], 'session=zensu-verify-auth-run-login1');
  assert.equal(lines[lines.length - 1], helper.LOGIN_RESTORED);
  assert.equal(signed.stdout.includes(LOGIN_SECRET), false);
  assert.equal(signed.stderr.includes(LOGIN_SECRET), false);
  const failing = loginProject(t, { script: `echo "${LOGIN_SECRET}"\nexit 9` });
  const failed = spawnSync(process.execPath, [HELPER, ...loginArgs(failing)], { encoding: 'utf8', env });
  assert.equal(failed.status, 1);
  assert.equal(failed.stdout, '');
  assert.equal(failed.stderr, 'zensu verify browser config: login failed: exit 9\n');
  assert.deepEqual([...helper.LOGIN_FAILURES], ['recipe', 'timeout', 'contract', 'artifact-path', 'artifact-shape', 'artifact-scope']);
  for (const kind of [...helper.LOGIN_FAILURES, 'exit 9', 'exit 127']) assert.match(kind, helper.LOGIN_FAILURE_RE);
  for (const kind of ['exit', 'exit 1000', 'password', 'recipe ']) assert.doesNotMatch(kind, helper.LOGIN_FAILURE_RE);
  assert.deepEqual([...helper.ABORT_SIGNALS], ['SIGTERM', 'SIGINT', 'SIGHUP']);
  assert.deepEqual([...helper.AUTH_ENVIRONMENTS], ['test', 'production']);
  assert.equal(helper.LOGIN_TIMEOUT_MS, 300000);
  assert.equal(helper.MAX_LOGIN_STDOUT_BYTES, 65536);
});

test('the discard verb removes a run\'s signed-in material and refuses any other argument shape or layout', async (t) => {
  const project = loginProject(t);
  assert.equal(helper.discardState(['--run-dir', project.dir]), 'none');
  await helper.run(loginArgs(project), undefined, NO_POLICY, READY);
  assert.equal(fs.existsSync(path.join(project.dir, 'auth', 'storage-state.json')), true);
  const cli = spawnSync(process.execPath, [HELPER, '--discard-state', '--run-dir', project.dir], { encoding: 'utf8' });
  assert.equal(cli.status, 0, cli.stderr);
  assert.equal(cli.stdout, 'state=discarded\n');
  assert.equal(fs.existsSync(path.join(project.dir, 'auth')), false);
  assert.equal(fs.existsSync(path.join(project.dir, helper.CONFIG_NAME)), true);
  for (const argv of [[], ['--run-dir'], ['--run-dir', project.dir, '--mode', 'local'], ['--mode', project.dir]]) {
    assert.throws(() => helper.discardState(argv), /usage: verify-browser-config\.js --discard-state/);
  }
  assert.throws(() => helper.discardState(['--run-dir', 'relative/dir']), /absolute path/);
  const outside = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-discard-outside-')));
  t.after(() => fs.rmSync(outside, { recursive: true, force: true }));
  fs.mkdirSync(path.join(outside, 'auth'));
  const refused = spawnSync(process.execPath, [HELPER, '--discard-state', '--run-dir', outside], { encoding: 'utf8' });
  assert.equal(refused.status, 1);
  assert.match(refused.stderr, /the run directory must be <project>\/\.zensu\/verify-feature-runs\/<leaf>/);
  assert.equal(fs.existsSync(path.join(outside, 'auth')), true);
});

test('a helper stopped by a signal during the login kills the login and removes the artifact directory', { skip: process.platform === 'win32' ? 'POSIX signals and process groups' : false }, async (t) => {
  const pathKey = Object.keys(process.env).find((key) => key.toUpperCase() === 'PATH') || 'PATH';
  const env = { ...process.env, [pathKey]: `${cliOnPath(t, MEASURED)}${path.delimiter}${process.env[pathKey] || ''}` };
  delete env.ZENSU_VERIFY_NAVIGATION_POLICY_V1;
  const project = loginProject(t, { script: ['echo $$ > login.pid', 'touch "$ZENSU_AUTH_ARTIFACT_DIR/started"', 'exec sleep 30'].join('\n') });
  const child = spawn(process.execPath, [HELPER, ...loginArgs(project)], { env, stdio: ['ignore', 'ignore', 'ignore'] });
  const exited = new Promise((resolve) => child.on('exit', (code) => resolve(code)));
  const started = path.join(project.dir, 'auth', 'artifact', 'started');
  const deadline = Date.now() + 20000;
  while (!fs.existsSync(started) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(fs.existsSync(started), true, 'the login started');
  child.kill('SIGTERM');
  assert.equal(await exited, 128 + os.constants.signals.SIGTERM);
  assert.equal(fs.existsSync(path.join(project.dir, 'auth', 'artifact')), false);
  assert.equal(fs.existsSync(path.join(project.dir, helper.CONFIG_NAME)), false);
  const pid = Number(fs.readFileSync(path.join(project.root, 'login.pid'), 'utf8').trim());
  let alive = true;
  for (let attempt = 0; attempt < 40 && alive; attempt += 1) {
    try {
      process.kill(pid, 0);
      await new Promise((resolve) => setTimeout(resolve, 50));
    } catch (_error) {
      alive = false;
    }
  }
  assert.equal(alive, false, 'the login process group was killed');
});

test('a signed-in run needs the verify-auth read guard registered, and a plain run does not', async (t) => {
  const command = (file) => ({ type: 'command', command: `bash "\${CLAUDE_PLUGIN_ROOT}/hooks/${file}"` });
  const consentOnly = {
    PreToolUse: [{ matcher: consent.CONSENT_MATCHER, hooks: [command(consent.CONSENT_HOOK_FILE)] }],
    PostToolUse: [{ matcher: consent.CONSENT_MATCHER, hooks: [command(consent.CONSENT_RECORDER_FILE)] }],
  };
  const withGuard = {
    PreToolUse: [...consentOnly.PreToolUse, { matcher: authState.AUTH_GUARD_TOOLS.join('|'), hooks: [command(authState.AUTH_GUARD_HOOK_FILE)] }],
    PostToolUse: consentOnly.PostToolUse,
  };
  const narrowGuard = {
    PreToolUse: [...consentOnly.PreToolUse, { matcher: 'Bash|PowerShell', hooks: [command(authState.AUTH_GUARD_HOOK_FILE)] }],
    PostToolUse: consentOnly.PostToolUse,
  };
  const rootWith = (hooks) => {
    const root = pluginRoot(t, { hooks });
    fs.writeFileSync(path.join(root, 'hooks', authState.AUTH_GUARD_HOOK_FILE), '#!/bin/bash\n');
    return root;
  };
  for (const [hooks, state] of [[consentOnly, 'unregistered'], [narrowGuard, 'unregistered']]) {
    const project = loginProject(t);
    await assert.rejects(helper.run(loginArgs(project), undefined, NO_POLICY, { ...READY, pluginRoot: rootWith(hooks) }),
      (error) => error.message.includes(`auth guard: ${state}`) && error.message.includes('/zensu:doctor') && !error.message.includes(LOGIN_SECRET));
    assert.deepEqual(fs.readdirSync(project.dir), []);
    assert.equal(fs.existsSync(path.join(project.root, 'seen-env.txt')), false);
  }
  const plain = await helper.run(['--run-dir', runDir(t), '--mode', 'local', '--origin', APP], undefined, NO_POLICY, { ...READY, pluginRoot: rootWith(consentOnly) });
  assert.equal(plain.login, null);
  const project = loginProject(t);
  const signed = await helper.run(loginArgs(project), undefined, NO_POLICY, { ...READY, pluginRoot: rootWith(withGuard) });
  assert.equal(signed.login, 'state-restored');
  assert.equal(signed.session.startsWith(authState.AUTH_SESSION_PREFIX), true);
});
