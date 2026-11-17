'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const test = require('node:test');

const PLUGIN = path.resolve(__dirname, '..', '..');
const LIB = path.join(PLUGIN, 'hooks', 'lib');
const HELPER = path.join(PLUGIN, 'scripts', 'verify-browser-config.js');
const consent = require(path.join(LIB, 'verify-consent-v1.js'));
const authState = require(path.join(LIB, 'verify-auth-state-v1.js'));
const guard = require(path.join(LIB, 'verify-auth-guard-v1.js'));
const cliVersion = require(path.join(LIB, 'playwright-cli-version-v1.js'));

const ACCOUNT = 'tester@example.test';
const LOGIN_WORD = `fixture-login-${crypto.randomBytes(6).toString('hex')}`;
const CALL_TIMEOUT_MS = 180000;
const MEMORY_LEAF = `${consent.MEMORY_NAME_PREFIX}scv1_${'e'.repeat(64)}.json`;

const SERVER_SOURCE = `'use strict';
const http = require('node:http');
const crypto = require('node:crypto');
const sessions = new Set();
const page = (res, title, heading) => {
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
  res.end('<!doctype html><title>' + title + '</title><h1>' + heading + '</h1>');
};
const server = http.createServer((req, res) => {
  const cookies = Object.fromEntries(String(req.headers.cookie || '').split(';').map((part) => part.trim().split('=')).filter((pair) => pair.length === 2));
  if (req.method === 'POST' && req.url === '/api/login') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      let parsed = {};
      try { parsed = JSON.parse(body); } catch (_error) { parsed = {}; }
      if (parsed.user !== '${ACCOUNT}' || parsed.word !== process.env.FIXTURE_LOGIN_WORD) {
        res.writeHead(401);
        res.end();
        return;
      }
      const sid = crypto.randomBytes(16).toString('hex');
      sessions.add(sid);
      res.writeHead(204, { 'set-cookie': 'sid=' + sid + '; HttpOnly; Path=/; SameSite=Lax' });
      res.end();
    });
    return;
  }
  if (req.url === '/' && sessions.has(cookies.sid)) return page(res, 'Account', 'Signed in as ${ACCOUNT}');
  if (req.url === '/') {
    res.writeHead(302, { location: '/login' });
    res.end();
    return;
  }
  if (req.url === '/login') return page(res, 'Sign in', 'Please sign in');
  res.writeHead(404);
  res.end();
});
server.listen(0, '127.0.0.1', () => process.stdout.write(server.address().port + '\\n'));
`;

const LOGIN_SOURCE = `'use strict';
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const origin = process.env.ZENSU_APP_ORIGIN;
const request = http.request(origin + '/api/login', { method: 'POST', headers: { 'content-type': 'application/json' } }, (response) => {
  response.resume();
  const header = (response.headers['set-cookie'] || [])[0] || '';
  const [name, value] = header.split(';')[0].split('=');
  if (response.statusCode !== 204 || !name || !value) {
    process.stderr.write('login refused with ' + response.statusCode + '\\n');
    process.exit(1);
  }
  const file = path.join(process.env.ZENSU_AUTH_ARTIFACT_DIR, 'state.json');
  const cookie = { name, value, domain: new URL(origin).hostname, path: '/', expires: -1, httpOnly: true, secure: false, sameSite: 'Lax' };
  fs.writeFileSync(file, JSON.stringify({ cookies: [cookie], origins: [] }));
  process.stdout.write('STORAGE_STATE=' + file + '\\n');
});
request.end(JSON.stringify({ user: '${ACCOUNT}', word: process.env.FIXTURE_LOGIN_WORD }));
`;

function cleanEnv(extra = {}) {
  const env = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (/^(PLAYWRIGHT_MCP_|PWTEST_)/.test(key)) continue;
    if (['PLAYWRIGHT_CLI_SESSION', 'ZENSU_VERIFY_NAVIGATION_POLICY_V1', 'CLAUDE_AGENT_TYPE', 'ZENSU_VERIFY_CONSENT_MEMORY', 'ZENSU_VERIFY_PROJECT_ROOT'].includes(key)) continue;
    env[key] = value;
  }
  return { ...env, ...extra };
}

function unavailable() {
  if (process.platform === 'win32') return 'the signed-in browser run is exercised on POSIX hosts only';
  if (!fs.existsSync('/bin/bash')) return 'no /bin/bash to run the judged command text';
  const installed = cliVersion.installedVersion(cleanEnv());
  if (installed.source !== 'manifest' || installed.version !== consent.PLAYWRIGHT_CLI_SOURCE_VERSION) {
    return `playwright-cli ${consent.PLAYWRIGHT_CLI_SOURCE_VERSION} is not installed here (${installed.source}${installed.version ? ` ${installed.version}` : ''})`;
  }
  return false;
}

function startServer(t, root) {
  fs.writeFileSync(path.join(root, 'server.js'), SERVER_SOURCE);
  const child = spawn(process.execPath, [path.join(root, 'server.js')], {
    cwd: root, env: cleanEnv({ FIXTURE_LOGIN_WORD: LOGIN_WORD }), stdio: ['ignore', 'pipe', 'ignore'],
  });
  t.after(() => { if (child.exitCode === null) child.kill('SIGTERM'); });
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('the fixture app did not report its port')), 30000);
    child.stdout.once('data', (chunk) => {
      clearTimeout(timer);
      resolve(`http://127.0.0.1:${String(chunk).trim()}`);
    });
    child.once('exit', (code) => reject(new Error(`the fixture app exited with ${code}`)));
  });
}

function signedOutStatus(origin) {
  const probe = spawnSync(process.execPath, ['-e', `require('node:http').get(${JSON.stringify(`${origin}/`)}, (res) => { process.stdout.write(String(res.statusCode)); res.resume(); })`], {
    encoding: 'utf8', timeout: 30000,
  });
  return probe.stdout;
}

function gate(command, root, mode = 'pre', response = null) {
  const payload = { hook_event_name: mode === 'pre' ? 'PreToolUse' : 'PostToolUse', tool_name: 'Bash', tool_input: { command }, permission_mode: 'default', cwd: root };
  const env = cleanEnv({ ZENSU_VERIFY_CONSENT_MEMORY: path.join(root, '.zensu', 'state', MEMORY_LEAF), ZENSU_VERIFY_PROJECT_ROOT: root });
  const notes = [];
  const err = { write: (chunk) => { notes.push(String(chunk)); return true; } };
  if (mode === 'post') return consent.runPost({ ...payload, tool_response: response }, env, err);
  const written = [];
  const out = { write: (chunk) => { written.push(String(chunk)); return true; } };
  const decided = consent.runPre(payload, env, out, err);
  if (!decided) return { decision: 'allow', reason: '' };
  const output = JSON.parse(written.join('')).hookSpecificOutput;
  return { decision: output.permissionDecision, reason: output.permissionDecisionReason };
}

function execute(command, root) {
  return spawnSync('/bin/bash', ['-c', command], { cwd: root, env: cleanEnv(), encoding: 'utf8', timeout: CALL_TIMEOUT_MS });
}

test('a recipe login script signs a real playwright-cli browser in through the gate, and the model never sees the state', { skip: unavailable(), timeout: 900000 }, async (t) => {
  const root = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-auth-e2e-')));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const leaf = `run-e2e-${crypto.randomBytes(4).toString('hex')}`;
  const runDir = path.join(root, '.zensu', 'verify-feature-runs', leaf);
  fs.mkdirSync(runDir, { recursive: true });
  fs.mkdirSync(path.join(root, '.zensu', 'state'), { mode: 0o700 });
  fs.writeFileSync(path.join(root, 'login.js'), LOGIN_SOURCE);
  const recipe = path.join(root, '.zensu', 'runtime.yaml');
  fs.writeFileSync(recipe, ['version: 1', 'auth:', '  mode: login-script', '  loginScript: "node ./login.js"', '  artifact: storageState', 'validate:', '  driver: browser', ''].join('\n'));
  const origin = await startServer(t, root);
  assert.equal(signedOutStatus(origin), '302', 'the fixture app sends a visitor without the session cookie to its login page');

  const helper = spawnSync(process.execPath, [HELPER, '--run-dir', runDir, '--mode', 'local', '--origin', origin, '--login-recipe', recipe], {
    cwd: root, env: cleanEnv({ FIXTURE_LOGIN_WORD: LOGIN_WORD }), encoding: 'utf8', timeout: CALL_TIMEOUT_MS,
  });
  assert.equal(helper.status, 0, helper.stderr);
  const printed = Object.fromEntries(helper.stdout.trim().split('\n').map((line) => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]));
  assert.equal(printed.login, 'state-restored');
  assert.equal(printed.mode, 'consent');
  assert.equal(printed.origin, origin);
  assert.ok(printed.session.startsWith(authState.AUTH_SESSION_PREFIX), printed.session);
  const statePath = authState.statePathFor(path.dirname(printed.config));
  const sid = JSON.parse(fs.readFileSync(statePath, 'utf8')).cookies[0].value;
  for (const text of [helper.stdout, helper.stderr]) {
    assert.equal(text.includes(LOGIN_WORD), false, 'the helper never prints the login secret');
    assert.equal(text.includes(sid), false, 'the helper never prints the session cookie');
  }
  assert.equal(fs.statSync(statePath).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.dirname(statePath)).mode & 0o777, 0o700);
  assert.equal(fs.readFileSync(path.join(path.dirname(statePath), authState.IGNORE_FILE_NAME), 'utf8'), authState.IGNORE_BODY);
  assert.equal(fs.existsSync(path.join(path.dirname(statePath), authState.ARTIFACT_DIR_NAME)), false);
  assert.equal(guard.decide({ payload: { tool_name: 'Read', tool_input: { file_path: statePath }, cwd: root } }).deny, true);
  assert.equal(guard.decide({ payload: { tool_name: 'Bash', tool_input: { command: `cat ${statePath}` }, cwd: root } }).deny, true);

  const session = printed.session;
  let open = true;
  t.after(() => { if (open) execute(`playwright-cli -s=${session} close`, root); });
  const openCommand = `playwright-cli -s=${session} open --config=${printed.config} ${origin}/`;
  assert.equal(guard.decide({ payload: { tool_name: 'Bash', tool_input: { command: openCommand }, cwd: root } }).deny, false);
  const asked = gate(openCommand, root);
  assert.equal(asked.decision, 'ask', asked.reason);
  assert.ok(asked.reason.includes('The browser opens signed in'), asked.reason);
  const opened = execute(openCommand, root);
  if (opened.status !== 0 && /executable doesn't exist|is not found|chrome|chromium|browser/i.test(`${opened.stdout}\n${opened.stderr}`) && !opened.stdout.includes('- Page URL:')) {
    open = false;
    t.skip(`playwright-cli could not launch its browser here: ${`${opened.stdout} ${opened.stderr}`.trim().slice(0, 200)}`);
    return;
  }
  assert.equal(opened.status, 0, `${opened.stdout}\n${opened.stderr}`);
  assert.ok(opened.stdout.includes(`- Page URL: ${origin}/`), opened.stdout);
  assert.ok(opened.stdout.includes('- Page Title: Account'), opened.stdout);
  for (const text of [opened.stdout, opened.stderr]) {
    assert.equal(text.includes(sid), false, 'the open output carries no cookie value');
    assert.equal(text.includes(LOGIN_WORD), false, 'the open output carries no login secret');
  }
  const recorded = gate(openCommand, root, 'post', { stdout: opened.stdout, stderr: opened.stderr, interrupted: false });
  assert.deepEqual(recorded.consumed, [statePath]);
  assert.equal(fs.existsSync(statePath), false, 'the recorder consumed the state once the browser opened');
  const memory = JSON.parse(fs.readFileSync(path.join(root, '.zensu', 'state', MEMORY_LEAF), 'utf8'));
  assert.ok(memory.records.some((record) => record.origin === origin && record.restoredState === true), JSON.stringify(memory.records));

  const snapshotCommand = `playwright-cli -s=${session} snapshot`;
  assert.deepEqual(gate(snapshotCommand, root), { decision: 'allow', reason: '' });
  const snapshot = execute(snapshotCommand, root);
  assert.equal(snapshot.status, 0, snapshot.stderr);
  assert.ok(snapshot.stdout.includes(`heading "Signed in as ${ACCOUNT}"`), snapshot.stdout);
  assert.equal(snapshot.stdout.includes(sid), false);

  for (const [command, reason] of [
    ['cookie-list', consent.REASONS.COMMAND_DENIED],
    ['cookie-get sid', consent.REASONS.COMMAND_DENIED],
    ['localstorage-list', consent.REASONS.COMMAND_DENIED],
    ['state-save', consent.REASONS.COMMAND_DENIED],
    ['console', consent.REASONS.AUTH_SIGNAL_DENIED],
    ['requests', consent.REASONS.AUTH_SIGNAL_DENIED],
  ]) {
    const denied = gate(`playwright-cli -s=${session} ${command}`, root);
    assert.equal(denied.decision, 'deny', command);
    assert.ok(denied.reason.includes(reason), `${command}: ${denied.reason}`);
  }
  const reopened = gate(openCommand, root);
  assert.equal(reopened.decision, 'deny');
  assert.ok(reopened.reason.includes(consent.REASONS.STATE_CONSUMED), reopened.reason);

  const closeCommand = `playwright-cli -s=${session} close`;
  assert.deepEqual(gate(closeCommand, root), { decision: 'allow', reason: '' });
  const closed = execute(closeCommand, root);
  assert.equal(closed.status, 0, closed.stderr);
  open = false;
  assert.ok(closed.stdout.includes(`'${session}' closed`), closed.stdout);
});
