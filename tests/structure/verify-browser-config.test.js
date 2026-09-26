'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const HELPER = path.resolve(__dirname, '../../scripts/verify-browser-config.js');
const helper = require(HELPER);
const { FLOOR_REASONS } = require('../../hooks/lib/verify-navigation-floor-v1.js');
const consent = require('../../hooks/lib/verify-consent-v1.js');

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

function target(origin, routes = ['/']) {
  return { origin, evidenceMode: 'declared-safe', routes };
}

function publicResolver(map) {
  return async (hostname) => {
    if (!Object.prototype.hasOwnProperty.call(map, hostname)) throw new Error('ENOTFOUND');
    return map[hostname].map((address) => ({ address, family: address.includes(':') ? 6 : 4 }));
  };
}

test('argument parsing refuses a missing, repeated or unknown argument', () => {
  const good = ['--run-dir', '/tmp/x', '--mode', 'local', '--origin', 'http://127.0.0.1:5173'];
  assert.deepEqual(helper.parseArgs(good), { runDir: '/tmp/x', mode: 'local', origins: ['http://127.0.0.1:5173'] });
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
    ['http://localhost:5173', FLOOR_REASONS.LOCAL_LITERAL_LOOPBACK],
    ['http://192.168.1.10:5173', FLOOR_REASONS.LOCAL_LITERAL_LOOPBACK],
    ['https://example.com', FLOOR_REASONS.LOCAL_LITERAL_LOOPBACK],
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

test('the run config follows the navigation policy: remote needs one, and a policy admits only its targets', async (t) => {
  const dir = runDir(t);
  const resolver = publicResolver({ 'preview.example.com': ['93.184.216.34'] });
  await assert.rejects(helper.run(['--run-dir', dir, '--mode', 'remote', '--origin', 'https://preview.example.com'], resolver, NO_POLICY, READY),
    (error) => error.message === consent.REASONS.REMOTE_NEEDS_POLICY);
  const local = policyEnv('local', [target('http://127.0.0.1:5173', ['/', '/login'])]);
  const admitted = await helper.run(['--run-dir', dir, '--mode', 'local', '--origin', 'http://127.0.0.1:5173'], undefined, local, READY);
  assert.equal(admitted.mode, 'policy');
  await assert.rejects(helper.run(['--run-dir', dir, '--mode', 'local', '--origin', 'http://127.0.0.1:5174'], undefined, local, READY),
    new RegExp(consent.REASONS.NOT_POLICY_TARGET));
  await assert.rejects(helper.run(['--run-dir', dir, '--mode', 'local', '--origin', 'http://127.0.0.1:5173'], undefined,
    { ZENSU_VERIFY_NAVIGATION_POLICY_V1: '{"version":1}' }, READY), new RegExp(consent.REASONS.POLICY_INVALID));
});

test('the policy check answers consent or policy and refuses what the gate would refuse', async () => {
  const resolver = publicResolver({ 'preview.example.com': ['93.184.216.34'], 'internal.example.com': ['10.0.0.5'] });
  assert.equal(await helper.checkPolicy(['local', 'http://127.0.0.1:5173', '/login', 'declared-safe'], NO_POLICY, resolver, READY), 'consent');
  await assert.rejects(helper.checkPolicy(['remote', 'https://preview.example.com', '/', 'declared-safe'], NO_POLICY, resolver, READY),
    (error) => error.message === consent.REASONS.REMOTE_NEEDS_POLICY);
  const local = policyEnv('local', [target('http://127.0.0.1:5173', ['/', '/login'])]);
  assert.equal(await helper.checkPolicy(['local', 'http://127.0.0.1:5173', '/login', 'declared-safe'], local, resolver, READY), 'policy');
  await assert.rejects(helper.checkPolicy(['local', 'http://127.0.0.1:5173', '/admin', 'declared-safe'], local, resolver, READY),
    new RegExp(consent.REASONS.NOT_POLICY_ROUTE));
  await assert.rejects(helper.checkPolicy(['remote', 'https://preview.example.com', '/', 'declared-safe'], local, resolver, READY), /mode does not match/);
  const remote = policyEnv('remote', [target('https://preview.example.com'), target('https://internal.example.com')]);
  assert.equal(await helper.checkPolicy(['remote', 'https://preview.example.com', '/', 'declared-safe'], remote, resolver, READY), 'policy');
  await assert.rejects(helper.checkPolicy(['remote', 'https://internal.example.com', '/', 'declared-safe'], remote, resolver, READY), /non-public/);
  const usage = [
    [],
    ['local', 'http://127.0.0.1:5173', '/'],
    ['local', 'http://127.0.0.1:5173', '/', 'redacted'],
    ['staging', 'http://127.0.0.1:5173', '/', 'declared-safe'],
    ['local', 'http://127.0.0.1:5173', '/', 'declared-safe', 'extra'],
  ];
  for (const argv of usage) await assert.rejects(helper.checkPolicy(argv, NO_POLICY, resolver, READY), /usage/, JSON.stringify(argv));
  for (const route of ['login', '/a?b=1', '/a#b', '/a/../b', '/a*']) {
    await assert.rejects(helper.checkPolicy(['local', 'http://127.0.0.1:5173', route, 'declared-safe'], NO_POLICY, resolver, READY),
      /absolute, normalized/, route);
  }
});

test('the policy check refuses before any verdict unless both consent hooks and the measured playwright-cli are ready', async (t) => {
  const resolver = publicResolver({ 'preview.example.com': ['93.184.216.34'] });
  const local = ['local', 'http://127.0.0.1:5173', '/', 'declared-safe'];
  await assert.rejects(helper.checkPolicy(local, NO_POLICY, resolver, { ...READY, installedVersion: installedAs({ source: 'manifest', version: '0.1.20', owner: '@playwright/cli' }) }),
    (error) => error.message.startsWith('playwright-cli 0.1.20 is installed') && error.message.includes(`\`${PINNED}\``));
  await assert.rejects(helper.checkPolicy(local, NO_POLICY, resolver, { ...READY, pluginRoot: pluginRoot(t, { hooks: {} }) }),
    (error) => error.message.startsWith('the browser consent gate is not ready') && error.message.includes('/zensu:doctor'));
  await assert.rejects(helper.checkPolicy(['remote', 'https://preview.example.com', '/', 'declared-safe'], NO_POLICY, resolver, { ...READY, installedVersion: installedAs({ source: 'absent' }) }),
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

test('the helper writes no run config unless both consent hooks are registered on the Bash matcher', async (t) => {
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
  const cases = [
    [{ source: 'manifest', version: '0.1.22', owner: '@playwright/cli' }, `playwright-cli 0.1.22 is installed, but the browser consent gate was measured against ${MEASURED}`],
    [{ source: 'manifest', version: `${MEASURED}-beta.1`, owner: '@playwright/cli' }, `playwright-cli ${MEASURED}-beta.1 is installed`],
    [{ source: 'absent' }, 'playwright-cli is not on PATH'],
    [{ source: 'foreign', owner: 'not-playwright' }, 'the playwright-cli on PATH belongs to the package not-playwright, not @playwright/cli'],
    [{ source: 'malformed' }, 'the package manifest beside the playwright-cli on PATH could not be judged'],
    [{ source: 'unread' }, 'the installed playwright-cli version could not be read from its @playwright/cli package manifest'],
  ];
  for (const [found, cause] of cases) {
    const dir = runDir(t);
    await assert.rejects(helper.run(['--run-dir', dir, ...origin], undefined, NO_POLICY, { ...READY, installedVersion: installedAs(found) }),
      (error) => error.message.includes(cause) && error.message.includes(`\`${PINNED}\``), JSON.stringify(found));
    assert.deepEqual(fs.readdirSync(dir), []);
  }
});

test('the helper names a PATH entry read against the working directory, and a playwright-cli outside its package, with the remedy each needs', async (t) => {
  const origin = ['--mode', 'local', '--origin', 'http://127.0.0.1:5173'];
  const moved = 'remove that entry from PATH, or move it behind the directory that holds playwright-cli';
  const cases = [
    [{ source: 'cwd-relative', entry: '' }, 'an empty PATH entry comes before or holds the playwright-cli on PATH, and the shell reads it against the working directory of each call', moved],
    [{ source: 'cwd-relative', entry: 'node_modules/.bin' }, 'the relative PATH entry "node_modules/.bin" comes before or holds the playwright-cli on PATH', moved],
    [{ source: 'unread' }, 'the playwright-cli on PATH resolves to no such manifest, as a wrapper script outside the package does', `install the measured version with \`${PINNED}\`, and put the directory npm installs it into first on PATH, ahead of any wrapper`],
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
  const bad = spawnSync(process.execPath, [HELPER, '--run-dir', dir, '--mode', 'local', '--origin', 'http://localhost:5173'], { encoding: 'utf8', env });
  assert.equal(bad.status, 1);
  assert.equal(bad.stdout, '');
  assert.equal(bad.stderr, `zensu verify browser config: ${FLOOR_REASONS.LOCAL_LITERAL_LOOPBACK}\n`);
  const check = spawnSync(process.execPath, [HELPER, '--check-policy', 'local', 'http://127.0.0.1:5173', '/', 'declared-safe'], { encoding: 'utf8', env });
  assert.equal(check.status, 0, check.stderr);
  assert.equal(check.stdout, 'consent\n');
  const refused = spawnSync(process.execPath, [HELPER, '--check-policy', 'remote', 'https://preview.example.com', '/', 'declared-safe'], { encoding: 'utf8', env });
  assert.equal(refused.status, 1);
  assert.equal(refused.stdout, '');
  assert.equal(refused.stderr, `zensu verify browser config: ${consent.REASONS.REMOTE_NEEDS_POLICY}\n`);
  const other = runDir(t, 'run-stale');
  const stale = spawnSync(process.execPath, [HELPER, '--run-dir', other, '--mode', 'local', '--origin', 'http://127.0.0.1:5173'],
    { encoding: 'utf8', env: { ...env, [pathKey]: `${cliOnPath(t, '0.1.20')}${path.delimiter}${basePath}` } });
  assert.equal(stale.status, 1);
  assert.equal(stale.stdout, '');
  assert.ok(stale.stderr.startsWith('zensu verify browser config: playwright-cli 0.1.20 is installed, but the browser consent gate was measured against '), stale.stderr);
  assert.ok(stale.stderr.includes(PINNED), stale.stderr);
  assert.deepEqual(fs.readdirSync(other), []);
});
