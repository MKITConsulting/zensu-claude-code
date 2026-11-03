'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const LIB = path.resolve(__dirname, '..', '..', 'hooks', 'lib');
const backend = require(path.join(LIB, 'zensu-cli-backend-v1.js'));
const guard = require(path.join(LIB, 'subagent-shell-guard-v1.js'));
const ps = require(path.join(LIB, 'powershell-command-v1.js'));

const NAMED = /(?:^|[^A-Za-z0-9_.-])zensu(?![A-Za-z0-9_-])/iu;
const LOCAL = 'http://localhost:8090';
const REMOTE = 'https://api.zensu.dev';
const DYNAMIC = String.fromCharCode(1);
const OPAQUE = String.fromCharCode(0);

const plainOf = (command) => command.replace(/\$(?=["'])/g, '').replace(/[\\"']/g, '');
const exact = (rest, envp = {}) => ({ envp, rest, exact: true });
const token = (rest, envp = {}) => ({ envp, rest });
const derived = (rest, envp = {}) => ({ envp, rest, derived: true });

function walker(command) {
  return guard.commandInvocations(command, { platform: 'linux', foldNames: true })
    .filter((call) => call.name === 'zensu')
    .map((call) => exact(call.words, call.environment));
}

function tokenScanReading(command) {
  for (const segment of command.split(/&&|;/)) {
    const words = segment.trim().split(/\s+/).filter(Boolean);
    const envp = {};
    let i = 0;
    while (i < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i])) {
      const eq = words[i].indexOf('=');
      envp[words[i].slice(0, eq)] = backend.unquoted(words[i].slice(eq + 1));
      i += 1;
    }
    if (words[i] === 'zensu') return [token(words.slice(i + 1), envp)];
  }
  return [];
}

function reading(command, options = {}) {
  const plain = options.plain === undefined ? plainOf(command) : options.plain;
  return backend.backendReading({
    command,
    plain,
    tool: options.tool || 'Bash',
    invocations: options.invocations || [],
    apiUrl: options.apiUrl === undefined ? '' : options.apiUrl,
    modeled: options.modeled === undefined ? (plain.match(new RegExp(NAMED.source, 'giu')) || []).length : options.modeled,
    zensuName: NAMED,
    platform: options.platform || 'linux',
  });
}

function local(command, invocation, options = {}) {
  return reading(command, options)(invocation);
}

function bashVerdict(command, apiUrl) {
  const invocations = walker(command).concat(tokenScanReading(command));
  assert.ok(invocations.length > 0, `no reading of ${command}`);
  const judge = reading(command, { invocations, apiUrl, modeled: walker(command).length });
  return invocations.every(judge) ? 'ALLOW' : 'DENY';
}

function powershellVerdict(command, apiUrl) {
  const invocations = ps.zensuInvocations(command).invocations;
  assert.ok(invocations.length > 0, `no PowerShell reading of ${command}`);
  const judge = reading(command, { tool: 'PowerShell', invocations, apiUrl, modeled: -1 });
  return invocations.every(judge) ? 'ALLOW' : 'DENY';
}

test('isLocalUrl reads a value as local only when it spells a loopback host the URL parser confirms', () => {
  for (const value of [LOCAL, 'localhost:8090', 'https://localhost:8443', 'http://127.0.0.1:8090', 'http://0.0.0.0:8090', 'http://[::1]:8090', 'HTTP://LOCALHOST:8090', 'http://localhost']) {
    assert.equal(backend.isLocalUrl(value), true, value);
  }
  for (const value of [
    REMOTE, '', undefined, null, 'http://127.1:8090', 'http://2130706433', 'http://local%68ost:8090',
    'http://127.0.0.1.:8090', 'http://localhost.:8090', 'ftp://localhost:8090', 'http://localhost:8090@api.zensu.dev',
    'http://user@localhost:8090', 'http://:pw@localhost:8090', 'http://localhost:x@localhost:8090', 'http://localhost:@localhost:8090',
    'http://localhost:8090\\@api.zensu.dev', 'http://localhost:80\t90', 'http://localhost:8090/é', 'http://localhost:99999',
  ]) {
    assert.equal(backend.isLocalUrl(value), false, String(value));
  }
});

test('isLocalUrl keeps a run-time part only after the literal text already ended the host', () => {
  assert.equal(backend.isLocalUrl('http://localhost:8090/$PREFIX'), true);
  assert.equal(backend.isLocalUrl('http://localhost:8090/$P/é'), true);
  assert.equal(backend.isLocalUrl('http://localhost:8090/$P\\x'), true);
  assert.equal(backend.isLocalUrl('http://localhost:8090/$P x'), true);
  assert.equal(backend.isLocalUrl(`http://localhost:8090/x${OPAQUE}`), true);
  assert.equal(backend.isLocalUrl(`${LOCAL}?q=${DYNAMIC}`), true);
  assert.equal(backend.isLocalUrl(`${LOCAL}#${DYNAMIC}`), true);
  assert.equal(backend.isLocalUrl('http://localhost:$PORT'), false);
  assert.equal(backend.isLocalUrl(`http://localhost:${DYNAMIC}`), false);
  assert.equal(backend.isLocalUrl(`localhost:8090${DYNAMIC}@api.zensu.dev`), false);
  assert.equal(backend.isLocalUrl('http://localhost$X'), false);
});

test('unquoted, isDynamic and runTime read single words the way the gate does', () => {
  assert.equal(backend.unquoted('"\'http://x\'"'), 'http://x');
  assert.equal(backend.unquoted('a"b'), 'a"b');
  assert.equal(backend.unquoted('""'), '');
  assert.equal(backend.isDynamic('$X'), true);
  assert.equal(backend.isDynamic(`a${DYNAMIC}`), true);
  assert.equal(backend.isDynamic(`a${OPAQUE}`), false);
  assert.equal(backend.runTime(`a${OPAQUE}`), true);
  assert.equal(backend.runTime('$X'), true);
  assert.equal(backend.runTime('plain'), false);
});

test('shellWords joins the token-scan words the way the shell quotes them', () => {
  assert.deepEqual(backend.shellWords(['--title', '"Fix', '--api-url', 'parsing"', '--json']), ['--title', '"Fix --api-url parsing"', '--json']);
  assert.deepEqual(backend.shellWords(['a', '#', '--api-url', REMOTE]), ['a']);
  assert.deepEqual(backend.shellWords(['"x', '#y"', 'z']), ['"x #y"', 'z']);
  assert.deepEqual(backend.shellWords(["'a\\'", 'b']), ["'a\\'", 'b']);
  assert.deepEqual(backend.shellWords(['a\\"b', 'c']), ['a\\"b', 'c']);
  assert.deepEqual(backend.shellWords(['"a', 'b"', 'c']), ['"a b"', 'c']);
  assert.deepEqual(backend.shellWords(['--api-url', '"http://localhost:8090']), ['--api-url', '"http://localhost:8090']);
  const command = 'zensu security classify f1';
  const judge = (rest) => local(command, token(rest), { apiUrl: LOCAL });
  assert.equal(judge(['security', 'classify', 'f1', '--title', '"x', '#y"', '--api-url', REMOTE]), false);
  assert.equal(judge(['security', 'classify', 'f1', '--title', "'a\\'", '--api-url', REMOTE]), false);
  assert.equal(judge(['security', 'classify', 'f1', '--title', 'a\\"b', '--api-url', REMOTE]), false);
  assert.equal(judge(['security', 'classify', 'f1', '--title', '"a', 'b"', '--api-url', REMOTE]), false);
  assert.equal(local(command, token(['security', 'classify', 'f1', '--api-url', '"http://localhost:8090'])), true);
  assert.equal(local(command, token(['--api-url', LOCAL, 'security', 'classify', 'f1', '#', '--api-url', REMOTE])), true);
});

test('every --api-url occurrence must name a local backend, and a certain one decides alone', () => {
  const command = 'zensu security classify f1';
  assert.equal(local(command, exact(['--api-url', LOCAL, '--api-url', REMOTE, 'security', 'classify', 'f1'])), false);
  assert.equal(local(command, exact(['--api-url', LOCAL, '--api-url', 'http://127.0.0.1:8090', 'security', 'classify', 'f1'])), true);
  assert.equal(local(command, exact(['security', 'classify', 'f1', '--api-url', LOCAL])), true);
  assert.equal(local(command, exact(['security', 'classify', 'f1', '--api-url'])), false);
  assert.equal(local(command, exact(['security', 'classify', 'f1', '--', '--api-url', LOCAL])), false);
  assert.equal(local(command, exact(['security', 'classify', 'f1', '--json', '--api-url', LOCAL])), false);
  assert.equal(local(command, exact(['security', 'classify', 'f1', '-', '--api-url', LOCAL])), true);
  assert.equal(local(command, exact(['security', 'classify', 'f1', '--x=y', '--api-url', LOCAL])), true);
  assert.equal(local(command, exact(['security', 'classify', 'f1', '--json', '--api-url', LOCAL], { ZENSU_API_URL: LOCAL })), true);
});

test('a word built at run time before an occurrence takes its certainty away', () => {
  const command = 'zensu security classify f1 $X --api-url http://localhost:8090';
  assert.equal(local(command, exact(['security', 'classify', 'f1', DYNAMIC, '--api-url', LOCAL])), false);
  assert.equal(local(command, token(['security', 'classify', 'f1', '$X', '--api-url', LOCAL])), false);
  assert.equal(local(command, exact(['--api-url', LOCAL, 'security', 'classify', 'f1', DYNAMIC])), true);
  assert.equal(local(command, exact(['security', 'classify', 'f1', DYNAMIC, '--api-url', LOCAL]), { apiUrl: LOCAL }), true);
  const powershell = 'zensu @a --api-url http://localhost:8090 security classify f1';
  assert.equal(local(powershell, exact([OPAQUE, '--api-url', LOCAL, 'security', 'classify', 'f1']), { tool: 'PowerShell', modeled: -1 }), false);
});

test('the one-word spelling is local only in a call the gate reads in full', () => {
  const command = 'zensu --api-url=http://localhost:8090 security classify f1';
  const call = exact(['--api-url=http://localhost:8090', 'security', 'classify', 'f1']);
  assert.equal(local(command, call), true);
  assert.equal(local(command, derived(call.rest)), false);
  assert.equal(local(command, call, { modeled: 0 }), false);
  assert.equal(local(`echo ZENSU; ${command}`, call, { modeled: 1 }), false);
  assert.equal(local(command, token(['--api-url="http://localhost:8090"', 'security', 'classify', 'f1'])), true);
  assert.equal(local(command, exact(['--api-url="http://localhost:8090"', 'security', 'classify', 'f1'])), false);
  assert.equal(local(command, exact(['--api-url=http://localhost:8090', 'security', 'classify', 'f1', DYNAMIC])), false);
  assert.equal(local(command, exact(['--api-url=https://api.zensu.dev', 'security', 'classify', 'f1']), { apiUrl: LOCAL }), false);
  for (const mark of ['$', '`', '{', '*', '?', '[', '\r']) {
    assert.equal(local(`echo x${mark}; ${command}`, call, { modeled: 1 }), false, JSON.stringify(mark));
  }
  for (const word of ['xargs', 'watch', 'XARGS']) {
    assert.equal(local(`${word} echo; ${command}`, call, { modeled: 1 }), false, word);
  }
  for (const word of ['myxargs', 'xargsy', 'watcher', 'x.watch']) {
    assert.equal(local(`echo ${word}; ${command}`, call, { modeled: 1 }), true, word);
  }
  assert.equal(local(`echo a\\b; ${command}`, call, { modeled: 1, platform: 'win32' }), false);
  assert.equal(local(`echo a\\b; ${command}`, call, { modeled: 1, platform: 'linux' }), true);
  assert.equal(local(`echo a\\b; ${command}`, call, { modeled: 1, platform: 'darwin' }), true);
  const at = 'zensu --api-url=http://localhost:8090 features create @a';
  assert.equal(local(at, exact(['--api-url=http://localhost:8090', 'features', 'create', OPAQUE]), { tool: 'PowerShell', modeled: -1 }), false);
  assert.equal(local(command, exact(['--api-url=http://localhost:8090', 'security', 'classify', 'f1']), { tool: 'PowerShell', modeled: -1 }), true);
});

test('ZENSU_API_URL decides when no occurrence is certain: its inline value, else the hook value the command never names', () => {
  const command = 'zensu security classify f1';
  const call = (envp) => exact(['security', 'classify', 'f1'], envp);
  assert.equal(local(`ZENSU_API_URL=${LOCAL} ${command}`, call({ ZENSU_API_URL: LOCAL }), { apiUrl: REMOTE }), true);
  assert.equal(local(`ZENSU_API_URL= ${command}`, call({ ZENSU_API_URL: '' }), { apiUrl: LOCAL }), false);
  assert.equal(local(`ZENSU_API_URL+=localhost:8090 ${command}`, call({ ZENSU_API_URL: 'localhost:8090' }), { apiUrl: REMOTE }), false);
  assert.equal(local(command, call({}), { apiUrl: LOCAL }), true);
  assert.equal(local(command, call({}), { apiUrl: REMOTE }), false);
  assert.equal(local(command, call({})), false);
  assert.equal(local(`export ZENSU_API_URL=${REMOTE}; ${command}`, call({}), { apiUrl: LOCAL }), false);
  assert.equal(local(`export ZENSU_API""_URL=${REMOTE}; ${command}`, call({}), { apiUrl: LOCAL }), false);
  assert.equal(local(`echo ZENSU_API\`\`_URL; ${command}`, call({}), { apiUrl: LOCAL }), false);
  assert.equal(local(`${command} --title 'set zensu_api_url'`, call({}), { apiUrl: LOCAL }), false);
  assert.equal(powershellVerdict(`Set-Item -Path ('env:zensu_api' + '_url') -Value ${REMOTE}; ${command}`, LOCAL), 'DENY');
  assert.equal(powershellVerdict(`Set-Item -Path ('env:zensu_web' + '_url') -Value ${REMOTE}; ${command}`, LOCAL), 'ALLOW');
});

test('a PowerShell call is read as the analyzer spells it, in lowercase, and loses a flag the analyzer cannot read', () => {
  const read = (command, apiUrl) => powershellVerdict(command, apiUrl);
  assert.equal(read('zensu --API-URL http://localhost:8090 security classify f1', ''), 'ALLOW');
  assert.equal(read('zensu --api-url http://localhost:8090 security classify f1 --API-URL https://api.zensu.dev', ''), 'DENY');
  assert.equal(read('zensu --api-url http://localhost:8090 features get f1; echo --%', ''), 'ALLOW');
  assert.equal(read('zensu --api-url http://localhost:8090 features create --product p1 --title $t; echo --%', ''), 'DENY');
  assert.equal(read('zensu --api``-url=$u security classify f1', LOCAL), 'DENY');
  assert.equal(read('zensu --API-URL=$u security classify f1', LOCAL), 'DENY');
  assert.equal(read('zensu --api-url=http://localhost:8090 features create @a', ''), 'DENY');
  const quoted = 'zensu security classify f1';
  assert.equal(local(quoted, token(['security', 'classify', 'f1', '--title', "it's", '--api-url', REMOTE]), { tool: 'PowerShell', modeled: -1, apiUrl: LOCAL }), false);
  const bash = 'zensu --api-url http://localhost:8090 features create --product p1 --title "$T" # --%';
  assert.equal(local(bash, exact(['--api-url', LOCAL, 'features', 'create', '--product', 'p1', '--title', DYNAMIC])), true);
});

test('a hidden PowerShell flag is counted against the calls the analyzer read, never against the readings derived from them', () => {
  const command = "zensu --api-url http://localhost:8090 --api-url=$u features create --title '$5'";
  const base = ps.zensuInvocations(command).invocations;
  assert.equal(base.length, 1);
  const copies = base.flatMap((call) => [1, 2].map(() => derived(call.rest.filter((w) => w.indexOf('$') === -1), call.envp)));
  assert.equal(local(command, base[0], { tool: 'PowerShell', modeled: -1, invocations: base }), false);
  assert.equal(local(command, base[0], { tool: 'PowerShell', modeled: -1, invocations: base.concat(copies) }), false);
});

test('a module that cannot load its sibling analyzer reads a PowerShell command as naming ZENSU_API_URL', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-cli-backend-'));
  try {
    fs.copyFileSync(path.join(LIB, 'zensu-cli-backend-v1.js'), path.join(dir, 'zensu-cli-backend-v1.js'));
    const alone = require(path.join(dir, 'zensu-cli-backend-v1.js'));
    const command = 'zensu security classify f1';
    const call = exact(['security', 'classify', 'f1']);
    const options = { command, plain: command, tool: 'PowerShell', invocations: [call], apiUrl: LOCAL, modeled: -1, zensuName: NAMED, platform: 'linux' };
    assert.equal(backend.backendReading(options)(call), true);
    assert.equal(alone.backendReading(options)(call), false);
    assert.equal(alone.backendReading({ ...options, tool: 'Bash', modeled: 1 })(call), true);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('the shell-model reading is judged on its exact words and the token-scan reading after quote removal', () => {
  const command = "zensu features create --product p --title t \"'--api-url=http://localhost:8090'\"";
  assert.equal(local(command, exact(['features', 'create', '--product', 'p', '--title', 't', "'--api-url=http://localhost:8090'"]), { modeled: 1 }), false);
  assert.equal(local(command, token(['features', 'create', '--product', 'p', '--title', 't', "\"'--api-url=http://localhost:8090'\""]), { modeled: 1 }), true);
  assert.equal(local("zensu --api-url 'http://[::1]:8090' security classify f1", token(['--api-url', "'http://[::1]:8090'", 'security', 'classify', 'f1'])), true);
});

const BASH_PORTS = [
  ['B53a', `zensu --api-url ${LOCAL} --api-url ${REMOTE} security classify f1`, '', 'DENY'],
  ['B53b', `zensu --api-url ${LOCAL} security classify f1 --api-url=${REMOTE}`, '', 'DENY'],
  ['B53c', `zensu security classify f1 -- --api-url ${LOCAL}`, '', 'DENY'],
  ['B53c2', `zensu security classify f1 -- extra --api-url ${LOCAL}`, '', 'DENY'],
  ['B53d', `ZENSU_API_URL=${LOCAL} zensu security classify f1 -- --api-url ${LOCAL}`, '', 'ALLOW'],
  ['B53e', `zensu --api-url ${LOCAL} --api-url http://127.0.0.1:8090 security classify f1`, '', 'ALLOW'],
  ['B53f', `ZENSU_API_URL=${LOCAL} zensu --api-url=${REMOTE} security classify f1`, '', 'DENY'],
  ['B53g', `zensu --api-url=${REMOTE} security classify f1`, LOCAL, 'DENY'],
  ['B53h', `ZENSU_API_URL=${LOCAL} zensu security classify f1 --api-url=${LOCAL} $X`, '', 'DENY'],
  ['B53i', 'ZENSU_API_URL= zensu security classify f1', LOCAL, 'DENY'],
  ['B53j', `ZENSU_API_URL=${LOCAL} zensu security classify f1`, REMOTE, 'ALLOW'],
  ['B53k', `zensu features create --product p1 --title --api-url ${LOCAL}`, '', 'DENY'],
  ['B53l', `ZENSU_API_URL=${LOCAL} zensu features create --product p1 --title --api-url ${LOCAL}`, '', 'ALLOW'],
  ['B53m', `ZENSU_API_URL=${LOCAL} zensu security classify f1 --json --api-url ${REMOTE}`, '', 'DENY'],
  ['B53n', `ZENSU_API_URL=${LOCAL} zensu security classify f1 --json --api-url=${REMOTE}`, '', 'DENY'],
  ['B53o', `zensu security classify f1 --json --api-url ${LOCAL}`, '', 'DENY'],
  ['B53q', 'zensu --api-url http://localhost:8090@api.zensu.dev security classify f1', '', 'DENY'],
  ['B53q2', 'zensu --api-url http://localhost:x@localhost:8090 security classify f1', '', 'DENY'],
  ['B53r', 'ZENSU_API_URL=http://localhost:8090@api.zensu.dev zensu security classify f1', '', 'DENY'],
  ['B53s', 'zensu security classify f1', 'http://localhost:8090@api.zensu.dev', 'DENY'],
  ['B53t', "zensu --api-url 'http://[::1]:8090' security classify f1", '', 'ALLOW'],
  ['B53u', 'zensu --api-url http://127.1:8090 security classify f1', '', 'DENY'],
  ['B53v', "zensu --api-url 'http://localhost:8090\\@api.zensu.dev' security classify f1", '', 'DENY'],
  ['B53w', `ZENSU_API_URL=${LOCAL} zensu security classify f1 --api-url`, '', 'DENY'],
  ['B53x', 'zensu --api-url ftp://localhost:8090 security classify f1', '', 'DENY'],
  ['B53y', 'zensu security classify f1', 'http://[::1]:8090', 'ALLOW'],
  ['B53z', 'zensu --api-url HTTP://LOCALHOST:8090 security classify f1', '', 'ALLOW'],
  ['B54a', `zensu --api-url ${LOCAL} features create --product p1 --title "Fix --api-url parsing"`, '', 'ALLOW'],
  ['B54b', `zensu features create --product p1 --title "Phase 1 -- login" --api-url ${LOCAL}`, '', 'ALLOW'],
  ['B54c', `zensu features create --product p1 --title "use -v" --api-url ${LOCAL}`, '', 'ALLOW'],
  ['B54d', `zensu --api-url ${LOCAL} security classify f1 # --api-url ${REMOTE}`, '', 'ALLOW'],
  ['B54e', `ssh deploy@host "cd /srv && zensu features create --product p1 --title x' '--api-url ${LOCAL}"`, '', 'DENY'],
  ['B54f', `zensu security classify f1 $X y --api-url ${LOCAL}`, '', 'DENY'],
  ['B54g', 'zensu --api-url http://localhost:$PORT security classify f1', '', 'DENY'],
  ['B54h', 'ZENSU_API_URL=http://localhost:${PORT} zensu security classify f1', '', 'DENY'],
  ['B54i', 'zensu --api-url "http://localhost:8090/$PREFIX" features create --product p1 --title t', '', 'ALLOW'],
  ['B54j', 'zensu --api-url https://localhost:8443 security classify f1', '', 'ALLOW'],
  ['B54k', `ZENSU_API_URL=${REMOTE}; zensu security classify f1`, LOCAL, 'DENY'],
  ['B54l', `export ZENSU_API_URL=${REMOTE} && zensu security classify f1`, LOCAL, 'DENY'],
  ['B54m', 'ZENSU_API_URL+=localhost:8090 zensu security classify f1', 'https://api.zensu.dev/', 'DENY'],
  ['B54n', `export ZENSU_API""_URL=${REMOTE}; zensu security classify f1`, LOCAL, 'DENY'],
  ['B54o', "zensu features create --product p1 --title 'set ZENSU_API_URL'", LOCAL, 'DENY'],
  ['B54p', 'zensu features create --product p1 --title t', LOCAL, 'ALLOW'],
];

test('every B53 and B54 case of the gate suite holds at the module', () => {
  for (const [id, command, apiUrl, expected] of BASH_PORTS) {
    assert.equal(bashVerdict(command, apiUrl), expected, `${id}: ${command}`);
  }
});

const POWERSHELL_PORTS = [
  ['B40o11', 'zensu --api-url=$u security classify f1', LOCAL, 'DENY'],
  ['B40o12', `zensu security classify f1 --% --api-url ${REMOTE}`, LOCAL, 'DENY'],
  ['B40o13', `$env:ZENSU_API_URL = '${REMOTE}'; zensu security classify f1`, LOCAL, 'DENY'],
  ['B40o14', `zensu --api-url ${LOCAL} features create --product p1 --title $t`, '', 'ALLOW'],
  ['B40o15', `Set-Item -Path ('env:ZENSU_API' + '_URL') -Value ${REMOTE}; zensu security classify f1`, LOCAL, 'DENY'],
];

test('every B40o11 to B40o15 PowerShell case of the gate suite holds at the module', () => {
  for (const [id, command, apiUrl, expected] of POWERSHELL_PORTS) {
    assert.equal(powershellVerdict(command, apiUrl), expected, `${id}: ${command}`);
  }
  const joined = POWERSHELL_PORTS[4][1];
  assert.equal(/ZENSU_API_URL/i.test(plainOf(joined)), false);
  assert.equal(/ZENSU_API_URL/i.test(ps.spellings(joined)), true);
});

test('backendReading is pure: it changes none of its inputs and answers the same twice', () => {
  const command = `zensu --api-url ${LOCAL} security classify f1 $X`;
  const invocations = walker(command).concat(tokenScanReading(command), [derived(['--api-url', LOCAL, 'security', 'classify', 'f1'])]);
  const before = JSON.stringify(invocations);
  const first = invocations.map(reading(command, { invocations, apiUrl: LOCAL }));
  const second = invocations.map(reading(command, { invocations, apiUrl: LOCAL }));
  assert.deepEqual(first, second);
  assert.equal(JSON.stringify(invocations), before);
  const upper = exact(['--API-URL', LOCAL, 'security', 'classify', 'f1']);
  local('zensu --API-URL http://localhost:8090 security classify f1', upper, { tool: 'PowerShell', modeled: -1 });
  assert.deepEqual(upper.rest, ['--API-URL', LOCAL, 'security', 'classify', 'f1']);
});
