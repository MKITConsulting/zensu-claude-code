import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import childProcess from 'node:child_process';

const mod = await import(new URL('../../plugins/session-hub/hooks/lib/session-hub-courier-v1.mjs', import.meta.url));
const contract = JSON.parse(fs.readFileSync(new URL('../../plugins/session-hub/hooks/interaction-contract.json', import.meta.url), 'utf8'));
const manifest = JSON.parse(fs.readFileSync(new URL('../../plugins/session-hub/.claude-plugin/plugin.json', import.meta.url), 'utf8'));

const tmp = () => fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-courier-unit-')));
const REQUIREMENT = 'anchor apple generic and certificate leaf[subject.OU] = "3P6C5C4S5B" and identifier "dev.zensu.session-hub.courier"';
const SESSION = '0f8fad5b-d9cb-469f-a165-70867728950e';

function writePointer(root, value) {
  const dir = path.join(root, 'zensu', 'session-hub', 'v1');
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const file = path.join(dir, 'hub.json');
  fs.writeFileSync(file, typeof value === 'string' ? value : `${JSON.stringify(value)}\n`, { mode: 0o600 });
  return file;
}

function pointer(socket, courier) {
  return { schemaVersion: 1, protocol: 1, socket, courier };
}

const FAKE = `
import path from 'node:path';
const args = process.argv.slice(3);
const mode = path.basename(args[1], '.sock');
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => { input += chunk; });
process.stdin.on('end', () => {
  if (mode === 'welcome') process.stdout.write('{"v":1,"kind":"welcome"}\\n');
  else if (mode === 'echo') process.stdout.write(JSON.stringify({ v: 1, kind: 'echo', input, args }) + '\\n');
  else if (mode.startsWith('exit-')) process.exitCode = Number(mode.slice(5));
  else if (mode === 'garbage') process.stdout.write('not json\\n');
  else if (mode === 'other-version') process.stdout.write('{"v":2,"kind":"welcome"}\\n');
  else if (mode === 'two-lines') process.stdout.write('{"v":1}\\n{"v":1}\\n');
  else if (mode === 'unterminated') process.stdout.write('{"v":1,"kind":"welcome"}');
  else if (mode === 'too-long') process.stdout.write('x'.repeat(300 * 1024));
  else if (mode === 'silent') setInterval(() => {}, 1000);
});
`;

function fakeCourier() {
  const dir = tmp();
  const script = path.join(dir, 'fake-courier.mjs');
  fs.writeFileSync(script, FAKE);
  const calls = [];
  const spawn = (command, args, options) => {
    calls.push({ command, args, options });
    return childProcess.spawn(process.execPath, [script, command, ...args], options);
  };
  return { spawn, calls };
}

function hubRoot(mode, courierName = 'zensu-session-hub-courier') {
  const root = tmp();
  const socket = path.join(root, `${mode}.sock`);
  const courier = path.join(root, courierName);
  writePointer(root, pointer(socket, courier));
  return { root, socket, courier };
}

const signed = async () => true;
const unsigned = async () => false;

test('the module speaks exactly the channel its contract file declares', () => {
  const channel = contract.interaction;
  assert.equal(contract.schemaVersion, 1);
  assert.equal(mod.CONTRACT, channel.contract);
  assert.equal(mod.PROTOCOL, channel.protocol);
  assert.equal(mod.POINTER, channel.pointer);
  assert.equal(mod.MAX_LINE_BYTES, channel.maxLineBytes);
  assert.equal(mod.COURIER_IDENTIFIER, channel.courier.identifier);
  assert.equal(mod.TEAM, channel.courier.team);
  assert.equal(mod.COURIER_REQUIREMENT, REQUIREMENT);
});

test('the unsigned option is the one option the manifest declares, and its environment name follows it', () => {
  assert.deepEqual(Object.keys(manifest.userConfig), [mod.OPTION]);
  assert.equal(manifest.userConfig[mod.OPTION].type, 'boolean');
  assert.equal(manifest.userConfig[mod.OPTION].default, false);
  assert.equal(mod.OPTION_ENV, 'CLAUDE_PLUGIN_OPTION_ALLOW_UNSIGNED_COURIER');
});

test('the config root is an absolute CLAUDE_CONFIG_DIR, else the home folder, and never a relative path', () => {
  assert.equal(mod.configRoot({ CLAUDE_CONFIG_DIR: '  /custom/claude  ' }, '/Users/a'), '/custom/claude');
  assert.equal(mod.configRoot({ CLAUDE_CONFIG_DIR: 'relative/claude' }, '/Users/a'), null);
  assert.equal(mod.configRoot({}, '/Users/a'), path.join('/Users/a', '.claude'));
  assert.equal(mod.configRoot({ CLAUDE_CONFIG_DIR: '   ' }, '/Users/a'), path.join('/Users/a', '.claude'));
  assert.equal(mod.configRoot({}, 'relative'), null);
  assert.equal(mod.configRoot({}, ''), null);
});

test('the pointer lies under the contract path of the config root', () => {
  assert.equal(mod.pointerPath('/Users/a/.claude'), path.join('/Users/a/.claude', 'zensu', 'session-hub', 'v1', 'hub.json'));
  assert.equal(mod.pointerPath('relative'), null);
  assert.equal(mod.pointerPath(null), null);
});

test('only a literal true admits an unsigned courier', () => {
  assert.equal(mod.unsignedAllowed(true), true);
  assert.equal(mod.unsignedAllowed('true'), true);
  for (const value of [false, 'false', 'TRUE', ' true', '1', 1, 'yes', undefined, null, {}]) {
    assert.equal(mod.unsignedAllowed(value), false, String(value));
  }
});

test('a pointer is read with its socket and courier and keeps nothing else', () => {
  const root = tmp();
  const file = writePointer(root, { ...pointer('/tmp/zensu-session-hub/hub.sock', '/Applications/Hub.app/Contents/MacOS/zensu-session-hub-courier'), extra: 'ignored' });
  assert.deepEqual(mod.readPointer(file), { socket: '/tmp/zensu-session-hub/hub.sock', courier: '/Applications/Hub.app/Contents/MacOS/zensu-session-hub-courier' });
});

test('a pointer of another schema or protocol, or with a relative or overlong path, is refused', () => {
  const courier = '/Applications/Hub.app/Contents/MacOS/zensu-session-hub-courier';
  const exact = `/${'s'.repeat(102)}`;
  assert.equal(Buffer.byteLength(exact), 103);
  assert.deepEqual(mod.pointerOf(pointer(exact, courier)), { socket: exact, courier });
  for (const value of [
    { ...pointer('/tmp/hub.sock', courier), schemaVersion: 2 },
    { ...pointer('/tmp/hub.sock', courier), protocol: 2 },
    { ...pointer('/tmp/hub.sock', courier), protocol: '1' },
    pointer(`${exact}x`, courier),
    pointer(`/${'é'.repeat(52)}`, courier),
    pointer('tmp/hub.sock', courier),
    pointer('/tmp/hub.sock', 'zensu-session-hub-courier'),
    pointer('/tmp/hub.sock', '/tmp/a\0b'),
    pointer('', courier),
    pointer('/tmp/hub.sock', 7),
    [pointer('/tmp/hub.sock', courier)],
    null,
    'text',
  ]) {
    assert.equal(mod.pointerOf(value), null, JSON.stringify(value));
  }
});

test('a pointer file that is missing, a link, too large, not JSON or owned by another user reads as none', () => {
  const root = tmp();
  const valid = pointer('/tmp/hub.sock', '/tmp/zensu-session-hub-courier');
  assert.equal(mod.readPointer(path.join(root, 'missing.json')), null);
  const file = writePointer(root, valid);
  assert.notEqual(mod.readPointer(file), null);
  const link = path.join(root, 'link.json');
  fs.symlinkSync(file, link);
  assert.equal(mod.readPointer(link), null);
  const large = path.join(root, 'large.json');
  fs.writeFileSync(large, JSON.stringify({ ...valid, pad: 'x'.repeat(mod.MAX_POINTER_BYTES) }));
  assert.equal(mod.readPointer(large), null);
  const text = path.join(root, 'text.json');
  fs.writeFileSync(text, 'not json');
  assert.equal(mod.readPointer(text), null);
  assert.equal(mod.readPointer(path.join(root, 'zensu')), null);
  assert.equal(mod.readPointer(file, fs.statSync(file).uid + 1), null);
  assert.equal(mod.readPointer('relative.json'), null);
});

test('a request line carries protocol 1, ends in one newline and fits the line bound', () => {
  assert.equal(mod.requestLine({ kind: 'hello', session: SESSION }), `{"v":1,"kind":"hello","session":"${SESSION}"}\n`);
  assert.equal(mod.requestLine({ v: 1, kind: 'hello' }), '{"v":1,"kind":"hello"}\n');
  const fill = mod.MAX_LINE_BYTES - Buffer.byteLength('{"v":1,"pad":""}\n');
  assert.equal(Buffer.byteLength(mod.requestLine({ pad: 'x'.repeat(fill) })), mod.MAX_LINE_BYTES);
  assert.equal(mod.requestLine({ pad: 'x'.repeat(fill + 1) }), null);
});

test('a request of another version or that is no plain object is refused', () => {
  for (const value of [{ v: 2, kind: 'hello' }, { v: '1' }, [], null, 'hello', 7, { big: 1n }]) {
    assert.equal(mod.requestLine(value), null, String(value));
  }
});

test('a reply is one protocol-1 object on one line', () => {
  assert.deepEqual(mod.replyOf('{"v":1,"kind":"welcome"}\n'), { v: 1, kind: 'welcome' });
  assert.deepEqual(mod.replyOf('{"v":1,"kind":"refused","code":"error.interactionPaused","later":true}\n'), { v: 1, kind: 'refused', code: 'error.interactionPaused', later: true });
  for (const output of ['{"v":1}', '{"v":2}\n', '{"kind":"welcome"}\n', '[1]\n', 'not json\n', '{"v":1}\n{"v":1}\n', '', `{"v":1,"pad":"${'x'.repeat(mod.MAX_LINE_BYTES)}"}\n`, 7]) {
    assert.equal(mod.replyOf(output), null, String(output).slice(0, 40));
  }
});

test('the courier is checked with codesign against the release requirement, with no environment and a bound', async () => {
  const calls = [];
  const execFile = (file, args, options, done) => {
    calls.push({ file, args, options });
    done(null, '', '');
  };
  assert.equal(await mod.verifyCourier('/Applications/Hub.app/Contents/MacOS/zensu-session-hub-courier', execFile), true);
  assert.deepEqual(calls, [{
    file: '/usr/bin/codesign',
    args: ['--verify', '--strict', `-R=${REQUIREMENT}`, '/Applications/Hub.app/Contents/MacOS/zensu-session-hub-courier'],
    options: { timeout: 10_000, env: {}, windowsHide: true },
  }]);
});

test('a failed, throwing or skipped codesign check leaves the courier unverified', async () => {
  assert.equal(await mod.verifyCourier('/tmp/zensu-session-hub-courier', (file, args, options, done) => done(Object.assign(new Error('exit 3'), { code: 3 }))), false);
  assert.equal(await mod.verifyCourier('/tmp/zensu-session-hub-courier', () => { throw new Error('spawn failed'); }), false);
  let called = false;
  assert.equal(await mod.verifyCourier('relative/zensu-session-hub-courier', () => { called = true; }), false);
  assert.equal(called, false);
});

test('a binary that is not the signed courier fails the real check', async () => {
  assert.equal(await mod.verifyCourier('/bin/ls'), false);
});

test('a signed courier is trusted, and an unsigned one only under the option and under its own file name', async () => {
  const courier = '/tmp/build/zensu-session-hub-courier';
  assert.equal(await mod.courierTrust(courier, { verify: signed }), 'signed');
  assert.equal(await mod.courierTrust(courier, { verify: signed, allowUnsigned: true }), 'signed');
  assert.equal(await mod.courierTrust(courier, { verify: unsigned }), null);
  assert.equal(await mod.courierTrust(courier, { verify: unsigned, allowUnsigned: 'false' }), null);
  assert.equal(await mod.courierTrust(courier, { verify: unsigned, allowUnsigned: true }), 'unsigned');
  assert.equal(await mod.courierTrust(courier, { verify: unsigned, allowUnsigned: 'true' }), 'unsigned');
  assert.equal(await mod.courierTrust('/tmp/build/other-tool', { verify: unsigned, allowUnsigned: true }), null);
  assert.equal(await mod.courierTrust(courier, { verify: async () => { throw new Error('boom'); } }), null);
  assert.equal(await mod.courierTrust('relative/zensu-session-hub-courier', { verify: signed }), null);
});

test('the relay starts the courier with the pointer socket, the wait and no environment, and hands it exactly the request line', async () => {
  const { root, socket, courier } = hubRoot('echo');
  const fake = fakeCourier();
  const outcome = await mod.relay({ kind: 'hello', session: SESSION }, { root, verify: signed, spawn: fake.spawn });
  assert.equal(outcome.ok, true);
  assert.equal(outcome.trust, 'signed');
  assert.equal(outcome.reply.input, `{"v":1,"kind":"hello","session":"${SESSION}"}\n`);
  assert.deepEqual(outcome.reply.args, ['--socket', socket, '--wait', '10']);
  assert.equal(fake.calls.length, 1);
  assert.equal(fake.calls[0].command, courier);
  assert.deepEqual(fake.calls[0].args, ['--socket', socket, '--wait', '10']);
  assert.deepEqual(fake.calls[0].options.env, {});
  assert.deepEqual(fake.calls[0].options.stdio, ['pipe', 'pipe', 'ignore']);
});

test('the relay hands back the reply the courier printed, under the trust that admitted it', async () => {
  const { root } = hubRoot('welcome');
  const fake = fakeCourier();
  assert.deepEqual(await mod.relay({ kind: 'hello', session: SESSION }, { root, verify: unsigned, allowUnsigned: true, wait: 3, spawn: fake.spawn }), { ok: true, reply: { v: 1, kind: 'welcome' }, trust: 'unsigned' });
  assert.deepEqual(fake.calls[0].args.slice(2), ['--wait', '3']);
});

test('each courier exit names its cause', async () => {
  for (const [mode, reason] of [['exit-64', 'usage'], ['exit-69', 'no-hub'], ['exit-74', 'transport'], ['exit-77', 'unverified'], ['exit-3', 'exit']]) {
    const { root } = hubRoot(mode);
    const fake = fakeCourier();
    assert.deepEqual(await mod.relay({ kind: 'hello', session: SESSION }, { root, verify: signed, spawn: fake.spawn }), { ok: false, reason }, mode);
  }
});

test('a reply that is not one protocol-1 line within the bound is refused', async () => {
  for (const mode of ['garbage', 'other-version', 'two-lines', 'unterminated', 'too-long']) {
    const { root } = hubRoot(mode);
    const fake = fakeCourier();
    assert.deepEqual(await mod.relay({ kind: 'hello', session: SESSION }, { root, verify: signed, spawn: fake.spawn }), { ok: false, reason: 'reply' }, mode);
  }
});

test('a courier that does not answer within its wait is stopped', async () => {
  const { root } = hubRoot('silent');
  const fake = fakeCourier();
  const started = Date.now();
  assert.deepEqual(await mod.relay({ kind: 'hello', session: SESSION }, { root, verify: signed, wait: 1, grace: 0, spawn: fake.spawn }), { ok: false, reason: 'timeout' });
  assert.ok(Date.now() - started < 5_000);
});

test('a courier that cannot be started is reported as such', async () => {
  const { root } = hubRoot('welcome');
  assert.deepEqual(await mod.relay({ kind: 'hello', session: SESSION }, { root, verify: signed }), { ok: false, reason: 'spawn' });
  assert.deepEqual(await mod.relay({ kind: 'hello', session: SESSION }, { root, verify: signed, spawn: () => { throw new Error('refused'); } }), { ok: false, reason: 'spawn' });
});

test('nothing starts for a bad request, a bad wait, a missing pointer or an untrusted courier', async () => {
  const fake = fakeCourier();
  const { root } = hubRoot('welcome');
  assert.deepEqual(await mod.relay({ v: 2 }, { root, verify: signed, spawn: fake.spawn }), { ok: false, reason: 'request' });
  for (const wait of [0, 3601, 1.5, '10']) {
    assert.deepEqual(await mod.relay({ kind: 'hello' }, { root, wait, verify: signed, spawn: fake.spawn }), { ok: false, reason: 'request' }, String(wait));
  }
  assert.deepEqual(await mod.relay({ kind: 'hello' }, { root: tmp(), verify: signed, spawn: fake.spawn }), { ok: false, reason: 'no-pointer' });
  assert.deepEqual(await mod.relay({ kind: 'hello' }, { root: null, verify: signed, spawn: fake.spawn }), { ok: false, reason: 'no-pointer' });
  assert.deepEqual(await mod.relay({ kind: 'hello' }, { root, verify: unsigned, spawn: fake.spawn }), { ok: false, reason: 'untrusted' });
  const other = hubRoot('welcome', 'other-tool');
  assert.deepEqual(await mod.relay({ kind: 'hello' }, { root: other.root, verify: unsigned, allowUnsigned: true, spawn: fake.spawn }), { ok: false, reason: 'untrusted' });
  assert.equal(fake.calls.length, 0);
});
