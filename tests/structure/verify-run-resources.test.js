'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const test = require('node:test');

const HELPER = path.resolve(__dirname, '../../skills/verify-feature/scripts/verify-run-resources.js');
const { ownedName, parseArgs, resolveRunDir, runKeyFor } = require(HELPER);

const POSIX = process.platform === 'win32'
  ? { skip: 'the tool stubs are POSIX shell scripts and the supervisor needs POSIX process groups' }
  : {};
const LOOPBACK = process.platform !== 'win32' && spawnSync(process.execPath, ['-e', [
  "const server = require('node:net').createServer();",
  "server.on('error', () => process.exit(1));",
  "server.listen(0, '127.0.0.1', () => server.close(() => process.exit(0)));",
].join(' ')], { stdio: 'ignore', timeout: 10000 }).status === 0;
const SUPERVISED = process.platform === 'win32'
  ? POSIX
  : (LOOPBACK ? {} : { skip: 'the managed host forbids loopback listeners' });
const RUN_NAME = 'Run.Ab_1';
const RUN_KEY = 'run-ab-1--c6da27ce74';
const PREFIX = `zensu-verify-${RUN_KEY}`;
const UDID = 'A1B2C3D4-0000-4000-8000-00000000ABCD';
const OTHER_UDID = 'FFFFFFFF-1111-4111-8111-111111111111';
const RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-26-5';

const XCRUN = [
  'if [ "$1" = simctl ] && [ "$2" = create ]; then',
  '  if [ -n "$STUB_LEDGER" ]; then cat "$STUB_LEDGER" > "$STUB_LEDGER_SEEN"; fi',
  '  if [ -n "$STUB_CREATE_FAIL" ]; then printf \'%s\\n\' "$STUB_CREATE_FAIL" >&2; exit 1; fi',
  '  printf \'No runtime specified, using a stub runtime\\n\' >&2',
  '  printf \'%s\\n\' "$STUB_UDID"',
  '  exit 0',
  'fi',
  'if [ "$1" = simctl ] && [ "$2" = list ]; then',
  '  if [ -n "$STUB_LIST_FAIL" ]; then exit 1; fi',
  '  printf \'%s\' "$STUB_DEVICES"',
  '  exit 0',
  'fi',
  'if [ "$1" = simctl ] && [ "$2" = shutdown ]; then exit 0; fi',
  'if [ "$1" = simctl ] && [ "$2" = delete ]; then exit 0; fi',
  'exit 3',
].join('\n');

const ADB = [
  'if [ "$1" = devices ]; then',
  '  printf \'List of devices attached\\n\'',
  '  for serial in $STUB_ADB_DEVICES; do printf \'%s\\tdevice\\n\' "$serial"; done',
  '  exit 0',
  'fi',
  'exit 3',
].join('\n');

function fixture() {
  const base = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'zensu-vrr-'));
  const runDir = path.join(base, RUN_NAME);
  const bin = path.join(base, 'bin');
  const empty = path.join(base, 'empty');
  const log = path.join(base, 'stub.log');
  fs.mkdirSync(runDir);
  fs.mkdirSync(bin);
  fs.mkdirSync(empty);
  fs.writeFileSync(log, '');
  return { base, runDir, bin, empty, log, ledger: path.join(runDir, 'resources.json') };
}

function stub(fx, name, body) {
  const script = `#!/bin/sh\nprintf '${name} %s\\n' "$*" >> "$STUB_LOG"\n${body}\n`;
  fs.writeFileSync(path.join(fx.bin, name), script, { mode: 0o755 });
}

function helper(fx, args, env = {}, pathValue = `${fx.bin}${path.delimiter}/bin${path.delimiter}/usr/bin`) {
  return spawnSync(process.execPath, [HELPER, ...args], {
    encoding: 'utf8',
    env: { ...process.env, PATH: pathValue, STUB_LOG: fx.log, ...env },
  });
}

function calls(fx) {
  return fs.readFileSync(fx.log, 'utf8').split('\n').filter((line) => line.length > 0);
}

function ledgerOf(fx) {
  return JSON.parse(fs.readFileSync(fx.ledger, 'utf8'));
}

function seedLedger(fx, resources) {
  fs.writeFileSync(fx.ledger, JSON.stringify({ version: 1, runKey: RUN_KEY, resources }));
}

function devices(list) {
  return JSON.stringify({ devices: { 'com.apple.CoreSimulator.SimRuntime.iOS-26-5': list } });
}

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

function deadPid() {
  return spawnSync(process.execPath, ['-e', ''], { stdio: 'ignore' }).pid;
}

async function waitDead(pid) {
  const deadline = Date.now() + 5000;
  while (alive(pid) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 50));
  return !alive(pid);
}

async function readPid(file) {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    const value = fs.existsSync(file) ? Number(fs.readFileSync(file, 'utf8').trim()) : Number.NaN;
    if (Number.isInteger(value) && value > 1) return value;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  return null;
}

function reap(fx, pids) {
  helper(fx, ['teardown', '--run-dir', fx.runDir], {}, process.env.PATH);
  for (const pid of pids) {
    if (!Number.isInteger(pid) || pid <= 1) continue;
    for (const target of [-pid, pid]) {
      try { process.kill(target, 'SIGKILL'); } catch (_error) {}
    }
  }
}

function cleanup(fx) {
  fs.rmSync(fx.base, { recursive: true, force: true });
}

test('argument parsing names every verb and refuses unknown, repeated, missing and misplaced arguments', () => {
  assert.deepEqual(parseArgs(['list', '--run-dir', '/r']), { verb: 'list', flags: { 'run-dir': '/r' }, command: [] });
  assert.deepEqual(
    parseArgs(['create-simulator', '--run-dir', '/r', '--device-type', 'iPhone 17', '--runtime', 'iOS 26.5']).flags,
    { 'run-dir': '/r', 'device-type': 'iPhone 17', runtime: 'iOS 26.5' },
  );
  assert.deepEqual(
    parseArgs(['start', '--run-dir', '/r', '--name', 'app', '--cwd', '/w', '--', 'node', '-e', '1']).command,
    ['node', '-e', '1'],
  );
  assert.throws(() => parseArgs([]), /usage: verify-run-resources\.js create-simulator/);
  assert.throws(() => parseArgs(['destroy', '--run-dir', '/r']), /usage/);
  assert.throws(() => parseArgs(['list']), /list needs --run-dir/);
  assert.throws(() => parseArgs(['list', '--run-dir', '/r', '--run-dir', '/s']), /--run-dir was given twice/);
  assert.throws(() => parseArgs(['list', '--run-dir', '/r', '--name', 'app']), /unknown flag --name for list/);
  assert.throws(() => parseArgs(['list', '--run-dir']), /--run-dir needs a value/);
  assert.throws(() => parseArgs(['list', 'stray']), /unexpected argument for list: stray/);
  assert.throws(() => parseArgs(['teardown', '--run-dir', '/r', '--', 'rm', '-rf']), /teardown takes no command/);
  assert.throws(() => parseArgs(['start', '--run-dir', '/r', '--name', 'app', '--cwd', '/w']), /start needs a command after --/);
  assert.throws(() => parseArgs(['record', '--run-dir', '/r', '--kind', 'container']), /record needs --id/);
});

test('owned names carry this run\'s prefix and nothing a sibling run or the user could own', () => {
  const run = { dir: '/r/run-1', key: 'run-1' };
  assert.equal(ownedName('zensu-verify-run-1', run), true);
  assert.equal(ownedName('zensu-verify-run-1-db', run), true);
  assert.equal(ownedName('zensu-verify-run-1-DB', run), false);
  assert.equal(ownedName('zensu-verify-run-12', run), false);
  assert.equal(ownedName('zensu-verify-run-1-', run), false);
  assert.equal(ownedName('postgres', run), false);
  assert.equal(ownedName(`zensu-verify-run-1-${'x'.repeat(60)}`, run), false);
  assert.equal(ownedName(undefined, run), false);
  assert.equal(runKeyFor(RUN_NAME), RUN_KEY);
  assert.equal(runKeyFor('run-1'), 'run-1');
  assert.equal(runKeyFor('a'.repeat(24)), 'a'.repeat(24));
  assert.match(runKeyFor('a'.repeat(25)), /^a{14}--[0-9a-f]{10}$/);
  assert.match(runKeyFor('run--1'), /^run-1--[0-9a-f]{10}$/);
  assert.match(runKeyFor('autopilot-run:7f3a'), /^autopilot-run--[0-9a-f]{10}$/);
  const keys = ['run-1', 'Run-1', 'run_1', 'run.1', 'run--1', 'run-1--00000000'].map(runKeyFor);
  assert.equal(new Set(keys).size, keys.length);
  for (const key of keys) assert.equal(key.includes('--'), key !== 'run-1');
});

test('the run directory must be absolute, physical and plainly named', POSIX, () => {
  const fx = fixture();
  try {
    assert.deepEqual(resolveRunDir(fx.runDir), { dir: fx.runDir, key: RUN_KEY });
    assert.throws(() => resolveRunDir('relative/run'), /--run-dir must be an absolute path/);
    assert.throws(() => resolveRunDir(path.join(fx.base, 'missing')), /--run-dir does not exist/);
    const link = path.join(fx.base, 'link');
    fs.symlinkSync(fx.runDir, link);
    assert.throws(() => resolveRunDir(link), /must be a directory, not a symlink/);
    fs.mkdirSync(path.join(fx.runDir, 'inner'));
    assert.throws(() => resolveRunDir(path.join(link, 'inner')), /must be a physical path/);
    const spaced = path.join(fx.base, 'bad name');
    fs.mkdirSync(spaced);
    assert.throws(() => resolveRunDir(spaced), /the run directory name must be/);
    const colon = path.join(fx.base, 'autopilot-run:1');
    fs.mkdirSync(colon);
    assert.deepEqual(resolveRunDir(colon), { dir: colon, key: 'autopilot-run--fc22686144' });
  } finally {
    cleanup(fx);
  }
});

test('create-simulator records the device before creating it, reads the UDID from stdout only, and teardown deletes exactly that device', POSIX, () => {
  const fx = fixture();
  try {
    stub(fx, 'xcrun', XCRUN);
    const seen = path.join(fx.base, 'ledger-at-create.json');
    const created = helper(fx, ['create-simulator', '--run-dir', fx.runDir, '--device-type', 'iPhone 17', '--runtime', RUNTIME], {
      STUB_UDID: UDID,
      STUB_LEDGER: fx.ledger,
      STUB_LEDGER_SEEN: seen,
    });
    assert.equal(created.status, 0, created.stderr);
    assert.equal(created.stdout, `udid=${UDID}\nname=${PREFIX}\n`);
    assert.deepEqual(JSON.parse(fs.readFileSync(seen, 'utf8')).resources, [{ kind: 'ios-simulator', id: null, name: PREFIX }]);
    assert.deepEqual(ledgerOf(fx).resources, [{ kind: 'ios-simulator', id: UDID, name: PREFIX }]);
    const listing = devices([
      { udid: OTHER_UDID, name: 'iPhone 17 Pro', state: 'Booted' },
      { udid: UDID, name: PREFIX, state: 'Booted' },
    ]);
    const down = helper(fx, ['teardown', '--run-dir', fx.runDir], { STUB_DEVICES: listing });
    assert.equal(down.status, 0, down.stdout + down.stderr);
    assert.equal(down.stdout, `removed ios-simulator ${UDID}\nteardown=complete\n`);
    assert.deepEqual(calls(fx), [
      `xcrun simctl create ${PREFIX} iPhone 17 ${RUNTIME}`,
      'xcrun simctl list devices --json',
      `xcrun simctl shutdown ${UDID}`,
      `xcrun simctl delete ${UDID}`,
    ]);
    assert.deepEqual(ledgerOf(fx).resources, []);
  } finally {
    cleanup(fx);
  }
});

test('teardown keeps a simulator whose name no longer belongs to the run and touches nothing', POSIX, () => {
  const fx = fixture();
  try {
    stub(fx, 'xcrun', XCRUN);
    assert.equal(helper(fx, ['create-simulator', '--run-dir', fx.runDir, '--device-type', 'iPhone 17'], { STUB_UDID: UDID }).status, 0);
    const second = helper(fx, ['create-simulator', '--run-dir', fx.runDir, '--device-type', 'iPad Air'], { STUB_UDID: OTHER_UDID });
    assert.equal(second.stdout, `udid=${OTHER_UDID}\nname=${PREFIX}-2\n`);
    const listing = devices([
      { udid: UDID, name: 'My iPhone', state: 'Shutdown' },
      { udid: OTHER_UDID, name: `${PREFIX}-2`, state: 'Shutdown' },
    ]);
    const down = helper(fx, ['teardown', '--run-dir', fx.runDir], { STUB_DEVICES: listing });
    assert.equal(down.status, 1);
    assert.equal(down.stdout, [
      `removed ios-simulator ${OTHER_UDID}`,
      `kept ios-simulator ${UDID}: the simulator is named My iPhone, not ${PREFIX}`,
      'teardown=incomplete kept=1',
      '',
    ].join('\n'));
    assert.equal(calls(fx).some((line) => line.includes(`shutdown ${UDID}`) || line.includes(`delete ${UDID}`)), false);
    assert.deepEqual(ledgerOf(fx).resources, [{ kind: 'ios-simulator', id: UDID, name: PREFIX }]);
    const third = helper(fx, ['create-simulator', '--run-dir', fx.runDir, '--device-type', 'iPad Air'], { STUB_UDID: OTHER_UDID });
    assert.equal(third.stdout, `udid=${OTHER_UDID}\nname=${PREFIX}-2\n`);
    assert.deepEqual(ledgerOf(fx).resources, [
      { kind: 'ios-simulator', id: UDID, name: PREFIX },
      { kind: 'ios-simulator', id: OTHER_UDID, name: `${PREFIX}-2` },
    ]);
  } finally {
    cleanup(fx);
  }
});

test('a failed create names the reason and drops its entry only when no device can exist', POSIX, () => {
  const fx = fixture();
  try {
    stub(fx, 'xcrun', XCRUN);
    const failed = helper(fx, ['create-simulator', '--run-dir', fx.runDir, '--device-type', 'iPhone 99'], {
      STUB_CREATE_FAIL: 'Invalid device type: iPhone 99',
      STUB_DEVICES: devices([]),
    });
    assert.equal(failed.status, 1);
    assert.equal(failed.stderr, 'zensu verify run resources: xcrun simctl create failed: Invalid device type: iPhone 99\n');
    assert.deepEqual(ledgerOf(fx).resources, []);
    const timedOut = helper(fx, ['create-simulator', '--run-dir', fx.runDir, '--device-type', 'iPhone 17'], {
      STUB_CREATE_FAIL: 'the create call timed out',
      STUB_DEVICES: devices([{ udid: UDID, name: PREFIX, state: 'Creating' }]),
    });
    assert.equal(timedOut.status, 1);
    assert.deepEqual(ledgerOf(fx).resources, [{ kind: 'ios-simulator', id: UDID, name: PREFIX }]);
    const unlisted = helper(fx, ['create-simulator', '--run-dir', fx.runDir, '--device-type', 'iPhone 17'], {
      STUB_CREATE_FAIL: 'the create call timed out',
      STUB_LIST_FAIL: '1',
    });
    assert.equal(unlisted.status, 1);
    assert.deepEqual(ledgerOf(fx).resources, [
      { kind: 'ios-simulator', id: UDID, name: PREFIX },
      { kind: 'ios-simulator', id: null, name: `${PREFIX}-2` },
    ]);
    const noTool = helper(fx, ['create-simulator', '--run-dir', fx.runDir, '--device-type', 'iPhone 17'], {}, fx.empty);
    assert.equal(noTool.stderr, 'zensu verify run resources: xcrun simctl create failed: xcrun was not found on PATH\n');
    assert.equal(ledgerOf(fx).resources.length, 2);
    const down = helper(fx, ['teardown', '--run-dir', fx.runDir], {}, fx.empty);
    assert.equal(down.status, 1);
    assert.equal(down.stdout, [
      `kept ios-simulator ${PREFIX}-2: xcrun simctl list failed; iOS simulators need macOS with Xcode`,
      `kept ios-simulator ${UDID}: xcrun simctl list failed; iOS simulators need macOS with Xcode`,
      'teardown=incomplete kept=2',
      '',
    ].join('\n'));
    const refused = helper(fx, ['create-simulator', '--run-dir', fx.runDir, '--device-type', '-set']);
    assert.equal(refused.status, 1);
    assert.match(refused.stderr, /--device-type must be a plain value that does not start with a dash/);
    const runtime = helper(fx, ['create-simulator', '--run-dir', fx.runDir, '--device-type', 'iPhone 17', '--runtime', '-set']);
    assert.match(runtime.stderr, /--runtime must be a plain value that does not start with a dash/);
  } finally {
    cleanup(fx);
  }
});

test('a run directory name at the length limit keeps every owned name valid, and a longer one is refused before any tool runs', POSIX, () => {
  const fx = fixture();
  try {
    stub(fx, 'xcrun', XCRUN);
    const longName = `L${'o'.repeat(199)}`;
    const runDir = path.join(fx.base, longName);
    fs.mkdirSync(runDir);
    const prefix = 'zensu-verify-looooooooooooo--b289b9362f';
    const first = helper(fx, ['create-simulator', '--run-dir', runDir, '--device-type', 'iPhone 17'], { STUB_UDID: UDID });
    assert.equal(first.stdout, `udid=${UDID}\nname=${prefix}\n`, first.stderr);
    const second = helper(fx, ['create-simulator', '--run-dir', runDir, '--device-type', 'iPad Air'], { STUB_UDID: OTHER_UDID });
    assert.equal(second.stdout, `udid=${OTHER_UDID}\nname=${prefix}-2\n`, second.stderr);
    assert.equal(helper(fx, ['list', '--run-dir', runDir]).stdout, `prefix=${prefix}\nresource=ios-simulator ${UDID}\nresource=ios-simulator ${OTHER_UDID}\n`);
    const down = helper(fx, ['teardown', '--run-dir', runDir], {
      STUB_DEVICES: devices([
        { udid: UDID, name: prefix, state: 'Shutdown' },
        { udid: OTHER_UDID, name: `${prefix}-2`, state: 'Shutdown' },
      ]),
    });
    assert.equal(down.stdout, `removed ios-simulator ${OTHER_UDID}\nremoved ios-simulator ${UDID}\nteardown=complete\n`);
    const tooLong = path.join(fx.base, `${longName}x`);
    fs.mkdirSync(tooLong);
    fs.writeFileSync(fx.log, '');
    const refused = helper(fx, ['create-simulator', '--run-dir', tooLong, '--device-type', 'iPhone 17'], { STUB_UDID: UDID });
    assert.equal(refused.stderr, 'zensu verify run resources: the run directory name must be 1 to 200 letters, digits, dots, colons, dashes or underscores\n');
    assert.deepEqual(calls(fx), []);
  } finally {
    cleanup(fx);
  }
});

test('teardown resolves a simulator recorded before its UDID was known by its name alone', POSIX, () => {
  const fx = fixture();
  try {
    stub(fx, 'xcrun', XCRUN);
    const pending = [{ kind: 'ios-simulator', id: null, name: PREFIX }];
    seedLedger(fx, pending);
    const one = helper(fx, ['teardown', '--run-dir', fx.runDir], {
      STUB_DEVICES: devices([
        { udid: OTHER_UDID, name: 'My iPhone', state: 'Booted' },
        { udid: UDID, name: PREFIX, state: 'Shutdown' },
      ]),
    });
    assert.equal(one.stdout, `removed ios-simulator ${PREFIX}\nteardown=complete\n`);
    assert.deepEqual(calls(fx), ['xcrun simctl list devices --json', `xcrun simctl delete ${UDID}`]);
    seedLedger(fx, pending);
    fs.writeFileSync(fx.log, '');
    const two = helper(fx, ['teardown', '--run-dir', fx.runDir], {
      STUB_DEVICES: devices([
        { udid: UDID, name: PREFIX, state: 'Shutdown' },
        { udid: OTHER_UDID, name: PREFIX, state: 'Shutdown' },
      ]),
    });
    assert.equal(two.status, 1);
    assert.equal(two.stdout, `kept ios-simulator ${PREFIX}: more than one simulator carries this run's name\nteardown=incomplete kept=1\n`);
    assert.deepEqual(calls(fx), ['xcrun simctl list devices --json']);
    const none = helper(fx, ['teardown', '--run-dir', fx.runDir], { STUB_DEVICES: devices([]) });
    assert.equal(none.stdout, `gone ios-simulator ${PREFIX}\nteardown=complete\n`);
  } finally {
    cleanup(fx);
  }
});

test('record accepts this run\'s names and a free emulator serial and refuses everything else', POSIX, () => {
  const fx = fixture();
  try {
    stub(fx, 'adb', ADB);
    const container = helper(fx, ['record', '--run-dir', fx.runDir, '--kind', 'container', '--id', `${PREFIX}-db`]);
    assert.equal(container.status, 0, container.stderr);
    assert.equal(container.stdout, `recorded=container ${PREFIX}-db\n`);
    const cluster = helper(fx, ['record', '--run-dir', fx.runDir, '--kind', 'kind-cluster', '--id', PREFIX]);
    assert.equal(cluster.stdout, `recorded=kind-cluster ${PREFIX}\nkubeconfig=${path.join(fx.runDir, 'kubeconfig')}\n`);
    assert.equal(helper(fx, ['record', '--run-dir', fx.runDir, '--kind', 'android-emulator', '--id', 'emulator-5580']).status, 0);
    assert.equal(helper(fx, ['record', '--run-dir', fx.runDir, '--kind', 'tmux-socket', '--id', `${PREFIX}-tui`]).status, 0);
    const foreign = helper(fx, ['record', '--run-dir', fx.runDir, '--kind', 'container', '--id', 'postgres']);
    assert.equal(foreign.status, 1);
    assert.match(foreign.stderr, new RegExp(`a container name must be ${PREFIX} or start with ${PREFIX}-`));
    assert.match(helper(fx, ['record', '--run-dir', fx.runDir, '--kind', 'android-emulator', '--id', 'R58M1234']).stderr, /emulator serial must read emulator-<port>/);
    const busy = helper(fx, ['record', '--run-dir', fx.runDir, '--kind', 'android-emulator', '--id', 'emulator-5554'], { STUB_ADB_DEVICES: 'emulator-5554' });
    assert.equal(busy.status, 1);
    assert.match(busy.stderr, /emulator-5554 is already running; choose a console port that no emulator uses/);
    const blind = helper(fx, ['record', '--run-dir', fx.runDir, '--kind', 'android-emulator', '--id', 'emulator-5556'], {}, fx.empty);
    assert.equal(blind.status, 1);
    assert.match(blind.stderr, /adb was not found on PATH; an emulator serial is recorded only when adb shows that no emulator uses its port/);
    assert.match(helper(fx, ['record', '--run-dir', fx.runDir, '--kind', 'vm', '--id', PREFIX]).stderr, /--kind must be one of android-emulator, tmux-socket, kind-cluster, container/);
    assert.match(helper(fx, ['record', '--run-dir', fx.runDir, '--kind', 'container', '--id', `${PREFIX}-db`]).stderr, /already recorded/);
    const listed = helper(fx, ['list', '--run-dir', fx.runDir]);
    assert.equal(listed.stdout, [
      `prefix=${PREFIX}`,
      `resource=container ${PREFIX}-db`,
      `resource=kind-cluster ${PREFIX}`,
      'resource=android-emulator emulator-5580',
      `resource=tmux-socket ${PREFIX}-tui`,
      '',
    ].join('\n'));
  } finally {
    cleanup(fx);
  }
});

test('teardown runs each recorded kind\'s own command in reverse order and reports resources already gone', POSIX, () => {
  const fx = fixture();
  try {
    stub(fx, 'docker', 'exit 0');
    stub(fx, 'kind', 'exit 0');
    stub(fx, 'adb', ADB);
    stub(fx, 'tmux', 'printf \'no server running on /tmp/stub\\n\' >&2; exit 1');
    for (const [kind, id] of [['container', `${PREFIX}-db`], ['kind-cluster', PREFIX], ['android-emulator', 'emulator-5580'], ['tmux-socket', `${PREFIX}-tui`]]) {
      assert.equal(helper(fx, ['record', '--run-dir', fx.runDir, '--kind', kind, '--id', id]).status, 0);
    }
    fs.writeFileSync(fx.log, '');
    const down = helper(fx, ['teardown', '--run-dir', fx.runDir]);
    assert.equal(down.status, 0, down.stdout + down.stderr);
    assert.equal(down.stdout, [
      `gone tmux-socket ${PREFIX}-tui`,
      'gone android-emulator emulator-5580',
      `removed kind-cluster ${PREFIX}`,
      `removed container ${PREFIX}-db`,
      'teardown=complete',
      '',
    ].join('\n'));
    assert.deepEqual(calls(fx), [
      `tmux -L ${PREFIX}-tui kill-server`,
      'adb devices',
      `kind delete cluster --name ${PREFIX} --kubeconfig ${path.join(fx.runDir, 'kubeconfig')}`,
      `docker rm -f ${PREFIX}-db`,
    ]);
    assert.deepEqual(ledgerOf(fx).resources, []);
  } finally {
    cleanup(fx);
  }
});

test('teardown never stops an emulator itself and keeps a serial that stays listed', POSIX, () => {
  const fx = fixture();
  try {
    stub(fx, 'adb', ADB);
    assert.equal(helper(fx, ['record', '--run-dir', fx.runDir, '--kind', 'android-emulator', '--id', 'emulator-5580']).status, 0);
    const held = helper(fx, ['teardown', '--run-dir', fx.runDir], { STUB_ADB_DEVICES: 'emulator-5580' });
    assert.equal(held.status, 1);
    assert.equal(held.stdout, 'kept android-emulator emulator-5580: emulator-5580 is still listed after the run\'s processes stopped, so an emulator this run did not start may hold that port\nteardown=incomplete kept=1\n');
    assert.equal(calls(fx).every((line) => line === 'adb devices'), true);
    const later = helper(fx, ['teardown', '--run-dir', fx.runDir]);
    assert.equal(later.stdout, 'gone android-emulator emulator-5580\nteardown=complete\n');
  } finally {
    cleanup(fx);
  }
});

test('teardown keeps what it could not remove, says why, and removes it on a later call', POSIX, () => {
  const fx = fixture();
  try {
    assert.equal(helper(fx, ['record', '--run-dir', fx.runDir, '--kind', 'container', '--id', `${PREFIX}-db`]).status, 0);
    const noTool = helper(fx, ['teardown', '--run-dir', fx.runDir], {}, fx.bin);
    assert.equal(noTool.status, 1);
    assert.equal(noTool.stdout, `kept container ${PREFIX}-db: docker was not found on PATH\nteardown=incomplete kept=1\n`);
    stub(fx, 'docker', 'if [ -n "$STUB_DOCKER_FAIL" ]; then printf \'%s\\n\' "$STUB_DOCKER_FAIL" >&2; exit 1; fi; exit 0');
    const denied = helper(fx, ['teardown', '--run-dir', fx.runDir], { STUB_DOCKER_FAIL: 'permission denied' });
    assert.equal(denied.status, 1);
    assert.equal(denied.stdout, `kept container ${PREFIX}-db: docker rm failed: permission denied\nteardown=incomplete kept=1\n`);
    assert.equal(ledgerOf(fx).resources.length, 1);
    const later = helper(fx, ['teardown', '--run-dir', fx.runDir]);
    assert.equal(later.status, 0);
    assert.equal(later.stdout, `removed container ${PREFIX}-db\nteardown=complete\n`);
  } finally {
    cleanup(fx);
  }
});

test('a ledger this run could not have written is refused before any tool runs', POSIX, () => {
  const fx = fixture();
  try {
    stub(fx, 'docker', 'exit 0');
    seedLedger(fx, [{ kind: 'container', id: 'postgres' }]);
    const foreign = helper(fx, ['teardown', '--run-dir', fx.runDir]);
    assert.equal(foreign.status, 1);
    assert.match(foreign.stderr, /the resource ledger holds an entry this run could not have recorded/);
    fs.writeFileSync(fx.ledger, JSON.stringify({ version: 1, runKey: 'another-run', resources: [] }));
    assert.match(helper(fx, ['teardown', '--run-dir', fx.runDir]).stderr, /does not belong to this run directory/);
    fs.rmSync(fx.ledger);
    const elsewhere = path.join(fx.base, 'elsewhere.json');
    fs.writeFileSync(elsewhere, JSON.stringify({ version: 1, runKey: RUN_KEY, resources: [] }));
    fs.symlinkSync(elsewhere, fx.ledger);
    assert.match(helper(fx, ['list', '--run-dir', fx.runDir]).stderr, /the resource ledger is not a regular file/);
    assert.deepEqual(calls(fx), []);
  } finally {
    cleanup(fx);
  }
});

test('a lock left by a helper that no longer runs is named in the refusal', POSIX, () => {
  const fx = fixture();
  try {
    const holder = deadPid();
    const lock = path.join(fx.runDir, 'resources.lock');
    fs.writeFileSync(lock, `${holder}\n`);
    const blocked = helper(fx, ['teardown', '--run-dir', fx.runDir]);
    assert.equal(blocked.status, 1);
    assert.equal(blocked.stderr, `zensu verify run resources: the resource ledger is locked by pid ${holder}, which no longer runs; remove resources.lock from the run directory and retry\n`);
    fs.rmSync(lock);
    assert.equal(helper(fx, ['teardown', '--run-dir', fx.runDir]).stdout, 'teardown=complete\n');
  } finally {
    cleanup(fx);
  }
});

test('teardown signals a supervisor only after its command line proves it is this run\'s, treats an ended group as gone, and keeps a group it cannot prove ended', POSIX, () => {
  const fx = fixture();
  const sleeper = spawn('sleep', ['30'], { detached: true, stdio: 'ignore' });
  sleeper.unref();
  try {
    const entry = (id, fields) => ({
      kind: 'process',
      id,
      ready: path.join(fx.runDir, `${id}.supervisor.json`),
      log: path.join(fx.runDir, `${id}.log`),
      ...fields,
    });
    for (const id of ['gone', 'held', 'lost']) fs.writeFileSync(path.join(fx.runDir, `${id}.supervisor.json`), '{}\n');
    const heldPid = deadPid();
    const lostPid = deadPid();
    seedLedger(fx, [
      entry('app', { supervisorPid: sleeper.pid }),
      entry('old', { supervisorPid: deadPid() }),
      entry('gone', { supervisorPid: deadPid(), childPid: deadPid() }),
      entry('held', { supervisorPid: heldPid, childPid: sleeper.pid }),
      entry('lost', { supervisorPid: lostPid }),
    ]);
    const down = helper(fx, ['teardown', '--run-dir', fx.runDir], {}, process.env.PATH);
    assert.equal(down.status, 1);
    assert.equal(down.stdout, [
      `kept process lost: the supervisor pid ${lostPid} ended without stopping its process group`,
      `kept process held: the supervisor pid ${heldPid} ended without stopping its process group; process group ${sleeper.pid} still runs`,
      'gone process gone',
      'gone process old',
      `kept process app: the recorded supervisor pid ${sleeper.pid} no longer runs this run's supervisor`,
      'teardown=incomplete kept=3',
      '',
    ].join('\n'));
    assert.equal(alive(sleeper.pid), true);
    assert.equal(fs.existsSync(path.join(fx.runDir, 'gone.supervisor.json')), false);
    assert.equal(fs.existsSync(path.join(fx.runDir, 'held.supervisor.json')), true);
    assert.equal(fs.existsSync(path.join(fx.runDir, 'lost.supervisor.json')), true);
    assert.deepEqual(ledgerOf(fx).resources.map((resource) => resource.id), ['app', 'held', 'lost']);
  } finally {
    try { process.kill(sleeper.pid, 'SIGKILL'); } catch (_error) {}
    cleanup(fx);
  }
});

test('start supervises a command in its own process group and teardown stops the whole group', SUPERVISED, async () => {
  const fx = fixture();
  let pid = null;
  let grandchild = null;
  try {
    const grandchildFile = path.join(fx.base, 'grandchild.pid');
    const script = path.join(fx.base, 'child.js');
    fs.writeFileSync(script, [
      "const { spawn } = require('node:child_process');",
      "const grandchild = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: 'ignore' });",
      `require('node:fs').writeFileSync(${JSON.stringify(grandchildFile)}, String(grandchild.pid));`,
      'setInterval(() => {}, 1000);',
    ].join('\n'));
    const started = helper(fx, ['start', '--run-dir', fx.runDir, '--name', 'app', '--cwd', fx.base, '--', process.execPath, script], {}, process.env.PATH);
    assert.equal(started.status, 0, started.stderr);
    pid = Number((/^pid=([0-9]+)$/m.exec(started.stdout) || [])[1]);
    assert.equal(Number.isInteger(pid) && alive(pid), true, started.stdout);
    assert.match(started.stdout, /^name=app$/m);
    assert.equal(started.stdout.includes(`log=${path.join(fx.runDir, 'app.log')}\n`), true);
    grandchild = await readPid(grandchildFile);
    assert.equal(Number.isInteger(grandchild) && alive(grandchild), true);
    const again = helper(fx, ['start', '--run-dir', fx.runDir, '--name', 'app', '--cwd', fx.base, '--', process.execPath, script], {}, process.env.PATH);
    assert.equal(again.status, 1);
    assert.match(again.stderr, /a process named app is already recorded for this run/);
    assert.match(helper(fx, ['start', '--run-dir', fx.runDir, '--name', 'web', '--cwd', 'relative', '--', 'true'], {}, process.env.PATH).stderr, /--cwd must be an absolute path/);
    assert.match(helper(fx, ['start', '--run-dir', fx.runDir, '--name', 'Web', '--cwd', fx.base, '--', 'true'], {}, process.env.PATH).stderr, /--name must be 1 to 32 lowercase letters/);
    assert.equal(helper(fx, ['list', '--run-dir', fx.runDir]).stdout, `prefix=${PREFIX}\nresource=process app\n`);
    const down = helper(fx, ['teardown', '--run-dir', fx.runDir], {}, process.env.PATH);
    assert.equal(down.status, 0, down.stdout + down.stderr);
    assert.match(down.stdout, /^(removed|gone) process app\nteardown=complete\n$/);
    assert.equal(await waitDead(pid), true);
    assert.equal(await waitDead(grandchild), true);
    assert.equal(fs.existsSync(path.join(fx.runDir, 'app.supervisor.json')), false);
  } finally {
    reap(fx, [pid, grandchild]);
    cleanup(fx);
  }
});

test('start runs a command that takes no arguments, and teardown still stops it when its endpoint file is gone', SUPERVISED, async () => {
  const fx = fixture();
  let pid = null;
  try {
    const tool = path.join(fx.base, 'tool');
    fs.writeFileSync(tool, '#!/bin/sh\nexec sleep 30\n', { mode: 0o755 });
    const started = helper(fx, ['start', '--run-dir', fx.runDir, '--name', 'tool', '--cwd', fx.base, '--', tool], {}, process.env.PATH);
    assert.equal(started.status, 0, started.stderr);
    pid = Number((/^pid=([0-9]+)$/m.exec(started.stdout) || [])[1]);
    assert.equal(Number.isInteger(pid) && alive(pid), true, started.stdout);
    fs.rmSync(path.join(fx.runDir, 'tool.supervisor.json'));
    const down = helper(fx, ['teardown', '--run-dir', fx.runDir], {}, process.env.PATH);
    assert.equal(down.stdout, 'removed process tool\nteardown=complete\n', down.stderr);
    assert.equal(await waitDead(pid), true);
  } finally {
    reap(fx, [pid]);
    cleanup(fx);
  }
});

test('the CLI reports every refusal on stderr with its prefix and exit 1', () => {
  const usage = spawnSync(process.execPath, [HELPER, 'bogus'], { encoding: 'utf8' });
  assert.equal(usage.status, 1);
  assert.equal(usage.stdout, '');
  assert.match(usage.stderr, /^zensu verify run resources: usage: verify-run-resources\.js create-simulator/);
  const relative = spawnSync(process.execPath, [HELPER, 'list', '--run-dir', 'relative'], { encoding: 'utf8' });
  assert.equal(relative.status, 1);
  assert.equal(relative.stderr, 'zensu verify run resources: --run-dir must be an absolute path\n');
});
