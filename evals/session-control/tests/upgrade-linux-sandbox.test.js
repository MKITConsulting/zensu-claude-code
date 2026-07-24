#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  buildBubblewrapInvocation,
  requireBubblewrap,
} = require('../lib/upgrade-linux-sandbox.js');

const EVALUATOR_UID = 1000;
const ELF_HEADER = Buffer.from([0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01]);

function fakeFs({
  extraDirectories = [],
  extraFiles = {},
} = {}) {
  const directories = new Set([
    '/usr',
    '/bin',
    '/lib',
    '/tmp/eval',
    '/tmp/eval/project',
    ...extraDirectories,
  ]);
  const files = new Map(Object.entries({
    '/usr/bin/bwrap': ELF_HEADER,
    '/usr/bin/env': ELF_HEADER,
    '/usr/bin/node': ELF_HEADER,
    '/etc/resolv.conf': 'nameserver 127.0.0.53\n',
    '/etc/hosts': '127.0.0.1 localhost\n',
    '/etc/nsswitch.conf': 'hosts: files dns\n',
    ...extraFiles,
  }).map(([file, content]) => [
    file,
    Buffer.isBuffer(content) ? content : Buffer.from(content),
  ]));
  const descriptors = new Map();
  let nextDescriptor = 10;
  const inode = (file) => [...file].reduce(
    (value, character) => ((value * 33) + character.charCodeAt(0)) >>> 0,
    5381,
  );
  const fileStat = (file) => ({
    isFile: () => true,
    isDirectory: () => false,
    isSymbolicLink: () => false,
    mode: file.startsWith('/etc/') || file.startsWith('/run/systemd/resolve/')
      ? 0o100644
      : 0o100755,
    uid: file === '/usr/bin/bwrap'
      || file.startsWith('/etc/')
      || file.startsWith('/run/systemd/resolve/')
      ? 0
      : EVALUATOR_UID,
    dev: 1,
    ino: inode(file),
    size: files.get(file).length,
    mtimeMs: 1700000000000 + inode(file),
    ctimeMs: 1700000001000 + inode(file),
  });
  const directoryStat = (file) => ({
    isFile: () => false,
    isDirectory: () => true,
    isSymbolicLink: () => false,
    mode: file.startsWith('/tmp/eval') ? 0o40700 : 0o40755,
    uid: file.startsWith('/tmp/eval') ? EVALUATOR_UID : 0,
    dev: 1,
    ino: inode(file),
  });
  const runtime = {
    evaluatorUid: EVALUATOR_UID,
    constants: {
      O_RDONLY: 0,
      O_NOFOLLOW: 0x20000,
    },
    lstatSync(file) {
      if (files.has(file)) return fileStat(file);
      if (directories.has(file)) return directoryStat(file);
      if (!directories.has(file)) {
        const error = new Error('missing');
        error.code = 'ENOENT';
        throw error;
      }
    },
    realpathSync: {
      native(file) { return file; },
    },
    openSync(file) {
      if (!files.has(file)) {
        const error = new Error('missing');
        error.code = 'ENOENT';
        throw error;
      }
      const descriptor = nextDescriptor;
      nextDescriptor += 1;
      descriptors.set(descriptor, file);
      return descriptor;
    },
    fstatSync(descriptor) {
      const file = descriptors.get(descriptor);
      if (!file) throw new Error('bad descriptor');
      return fileStat(file);
    },
    readSync(descriptor, buffer, offset, length, position) {
      const file = descriptors.get(descriptor);
      if (!file) throw new Error('bad descriptor');
      const content = files.get(file);
      return content.copy(
        buffer,
        offset,
        position,
        Math.min(content.length, position + length),
      );
    },
    closeSync(descriptor) {
      if (!descriptors.delete(descriptor)) throw new Error('bad descriptor');
    },
  };
  return runtime;
}

function fakeFsWith(overrides = {}) {
  const base = fakeFs();
  return {
    ...base,
    ...overrides,
    realpathSync: overrides.realpathSync || base.realpathSync,
  };
}

test('fails closed before any non-Linux or unsafe bubblewrap invocation', () => {
  assert.throws(() => requireBubblewrap({
    platform: 'darwin',
    runtime: fakeFs(),
  }), /supported only on Linux; no child was started/);
  assert.throws(() => requireBubblewrap({
    platform: 'linux',
    runtime: fakeFs(),
    executable: '/tmp/bwrap',
  }), /path is not evaluator-owned/);
});

test('rejects every unsafe bubblewrap identity attribute', () => {
  const base = fakeFs();
  const original = base.lstatSync('/usr/bin/bwrap');
  const cases = [
    ['missing', () => { throw Object.assign(new Error('missing'), { code: 'ENOENT' }); },
      /bubblewrap is unavailable/],
    ['not a file', () => ({ ...original, isFile: () => false }),
      /bubblewrap identity is unsafe/],
    ['symlink', () => ({ ...original, isSymbolicLink: () => true }),
      /bubblewrap identity is unsafe/],
    ['not executable', () => ({ ...original, mode: 0o100644 }),
      /bubblewrap identity is unsafe/],
    ['not root owned', () => ({ ...original, uid: 501 }),
      /bubblewrap identity is unsafe/],
  ];
  for (const [, bwrapStat, expected] of cases) {
    const runtime = fakeFsWith({
      lstatSync(file) {
        if (file === '/usr/bin/bwrap') return bwrapStat();
        return base.lstatSync(file);
      },
    });
    assert.throws(
      () => requireBubblewrap({ platform: 'linux', runtime }),
      expected,
    );
  }

  const replaced = fakeFsWith({
    realpathSync: {
      native(file) {
        return file === '/usr/bin/bwrap' ? '/tmp/replaced-bwrap' : file;
      },
    },
  });
  assert.throws(
    () => requireBubblewrap({ platform: 'linux', runtime: replaced }),
    /bubblewrap identity is unsafe/,
  );
});

test('builds a credential-minimal PID and mount namespace', () => {
  const invocation = buildBubblewrapInvocation({
    command: '/usr/bin/node',
    args: ['fixture.js'],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: {
      PATH: '/usr/bin:/bin',
      HOME: '/tmp/eval/home',
      ANTHROPIC_API_KEY: 'dummy-local-key',
    },
    allowedCredential: 'ANTHROPIC_API_KEY',
    platform: 'linux',
    runtime: fakeFs(),
  });
  assert.equal(invocation.command, '/usr/bin/bwrap');
  assert.equal(invocation.containment, 'linux-bwrap-pid-mount-v1');
  assert.deepEqual(invocation.args.slice(0, 7), [
    '--unshare-user',
    '--unshare-pid',
    '--unshare-ipc',
    '--unshare-uts',
    '--unshare-cgroup',
    '--die-with-parent',
    '--new-session',
  ]);
  assert.equal(invocation.args.includes('--unshare-net'), false);
  for (const file of ['/etc/resolv.conf', '/etc/hosts', '/etc/nsswitch.conf']) {
    const mountAt = invocation.args.findIndex(
      (entry, index) => entry === '--ro-bind' && invocation.args[index + 2] === file,
    );
    assert.notEqual(mountAt, -1);
    assert.equal(invocation.args[mountAt + 1], file);
  }
  assert.deepEqual(invocation.args.slice(-3), ['--', '/usr/bin/node', 'fixture.js']);
  assert.equal(invocation.env.ANTHROPIC_API_KEY, undefined);
  assert.equal(invocation.env.CLAUDE_CODE_OAUTH_TOKEN, undefined);
  const keyAt = invocation.args.indexOf('ANTHROPIC_API_KEY');
  assert.equal(invocation.args[keyAt + 1], 'dummy-local-key');
});

test('supports a network-isolated child and rejects credential ambiguity', () => {
  const invocation = buildBubblewrapInvocation({
    command: '/usr/bin/node',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: { PATH: '/usr/bin', HOME: '/tmp/eval/home' },
    shareNetwork: false,
    platform: 'linux',
    runtime: fakeFs(),
  });
  assert.equal(invocation.args.includes('--unshare-net'), true);
  assert.equal(invocation.containment, 'linux-bwrap-pid-net-mount-v1');
  assert.equal(invocation.args.includes('/etc/resolv.conf'), false);
  assert.throws(() => buildBubblewrapInvocation({
    command: '/usr/bin/node',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: {
      ANTHROPIC_API_KEY: 'one',
      CLAUDE_CODE_OAUTH_TOKEN: 'two',
    },
    allowedCredential: 'ANTHROPIC_API_KEY',
    platform: 'linux',
    runtime: fakeFs(),
  }), /unexpected Claude credential/);
});

test('fails closed when shared-network resolver files are missing, mutable, or replaced', () => {
  const invocation = {
    command: '/usr/bin/node',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: { PATH: '/usr/bin' },
    platform: 'linux',
  };
  const missing = fakeFs();
  const missingLstat = missing.lstatSync;
  missing.lstatSync = (file) => {
    if (file === '/etc/resolv.conf') {
      throw Object.assign(new Error('missing'), { code: 'ENOENT' });
    }
    return missingLstat(file);
  };
  assert.throws(
    () => buildBubblewrapInvocation({ ...invocation, runtime: missing }),
    /network resolver configuration is unavailable/,
  );

  const mutable = fakeFs();
  const mutableLstat = mutable.lstatSync;
  mutable.lstatSync = (file) => {
    const stat = mutableLstat(file);
    return file === '/etc/hosts' ? { ...stat, mode: 0o100666 } : stat;
  };
  assert.throws(
    () => buildBubblewrapInvocation({ ...invocation, runtime: mutable }),
    /network resolver configuration is unsafe/,
  );

  const replaced = fakeFs();
  const replacedLstat = replaced.lstatSync;
  let resolverReads = 0;
  replaced.lstatSync = (file) => {
    const stat = replacedLstat(file);
    if (file !== '/etc/nsswitch.conf') return stat;
    resolverReads += 1;
    return resolverReads > 4 ? { ...stat, ino: stat.ino + 1 } : stat;
  };
  assert.throws(
    () => buildBubblewrapInvocation({ ...invocation, runtime: replaced }),
    /network resolver configuration (?:is unsafe|identity changed)/,
  );
});

test('canonicalizes a resolver symlink and rejects a retarget before spawn', () => {
  const targetOne = '/run/systemd/resolve/resolv.conf';
  const targetTwo = '/run/systemd/resolve/foreign.conf';
  const base = fakeFs({
    extraFiles: {
      [targetOne]: 'nameserver 127.0.0.53\n',
      [targetTwo]: 'nameserver 192.0.2.53\n',
    },
  });
  const linkSource = base.lstatSync('/etc/resolv.conf');
  const link = {
    ...linkSource,
    isFile: () => false,
    isSymbolicLink: () => true,
    mode: 0o120777,
    uid: 0,
  };
  const runtime = {
    ...base,
    lstatSync(file) {
      return file === '/etc/resolv.conf' ? link : base.lstatSync(file);
    },
    realpathSync: {
      native(file) {
        return file === '/etc/resolv.conf' ? targetOne : file;
      },
    },
  };
  const options = {
    command: '/usr/bin/node',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: { PATH: '/usr/bin' },
    platform: 'linux',
  };
  const invocation = buildBubblewrapInvocation({ ...options, runtime });
  const resolverAt = invocation.args.findIndex(
    (entry, index) => (
      entry === '--ro-bind'
      && invocation.args[index + 2] === '/etc/resolv.conf'
    ),
  );
  assert.notEqual(resolverAt, -1);
  assert.equal(invocation.args[resolverAt + 1], targetOne);

  let resolverRealpaths = 0;
  const retargeted = {
    ...runtime,
    realpathSync: {
      native(file) {
        if (file !== '/etc/resolv.conf') return file;
        resolverRealpaths += 1;
        return resolverRealpaths === 1 ? targetOne : targetTwo;
      },
    },
  };
  assert.throws(
    () => buildBubblewrapInvocation({ ...options, runtime: retargeted }),
    /network resolver configuration identity changed/,
  );
});

test('accepts a resolver target owned by a distinct system service, not the evaluator', () => {
  const target = '/run/systemd/resolve/resolv.conf';
  const base = fakeFs({
    extraFiles: {
      [target]: 'nameserver 127.0.0.53\n',
    },
  });
  const supplied = {
    ...base.lstatSync('/etc/resolv.conf'),
    isFile: () => false,
    isSymbolicLink: () => true,
    mode: 0o120777,
    uid: 0,
  };
  const targetInode = base.lstatSync(target).ino;
  const runtimeWithTargetUid = (targetUid) => ({
    ...base,
    lstatSync(file) {
      if (file === '/etc/resolv.conf') return supplied;
      const stat = base.lstatSync(file);
      return stat.ino === targetInode ? { ...stat, uid: targetUid } : stat;
    },
    fstatSync(descriptor) {
      const stat = base.fstatSync(descriptor);
      return stat.ino === targetInode ? { ...stat, uid: targetUid } : stat;
    },
    realpathSync: {
      native(file) {
        return file === '/etc/resolv.conf' ? target : file;
      },
    },
  });
  const options = {
    command: '/usr/bin/node',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: { PATH: '/usr/bin' },
    platform: 'linux',
  };

  const invocation = buildBubblewrapInvocation({
    ...options,
    runtime: runtimeWithTargetUid(998),
  });
  const resolverAt = invocation.args.findIndex(
    (entry, index) => (
      entry === '--ro-bind'
      && invocation.args[index + 2] === '/etc/resolv.conf'
    ),
  );
  assert.notEqual(resolverAt, -1);
  assert.equal(invocation.args[resolverAt + 1], target);

  assert.throws(() => buildBubblewrapInvocation({
    ...options,
    runtime: runtimeWithTargetUid(EVALUATOR_UID),
  }), /network resolver configuration is unsafe/);
});

test('requires exactly the declared credential and keeps host credentials out of bwrap env', () => {
  const invocation = buildBubblewrapInvocation({
    command: '/usr/bin/node',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: {
      PATH: '/usr/bin',
      ANTHROPIC_API_KEY: 'sandbox-only-key',
    },
    allowedCredential: 'ANTHROPIC_API_KEY',
    platform: 'linux',
    runtime: fakeFs(),
  });
  assert.equal(invocation.env.ANTHROPIC_API_KEY, undefined);
  assert.equal(invocation.env.CLAUDE_CODE_OAUTH_TOKEN, undefined);

  for (const [environment, allowedCredential] of [
    [{ PATH: '/usr/bin' }, 'ANTHROPIC_API_KEY'],
    [{ ANTHROPIC_API_KEY: '' }, 'ANTHROPIC_API_KEY'],
    [{ ANTHROPIC_API_KEY: 'one' }, 'NOT_A_CREDENTIAL'],
    [{ ANTHROPIC_API_KEY: 'one' }, null],
  ]) {
    assert.throws(() => buildBubblewrapInvocation({
      command: '/usr/bin/node',
      args: [],
      cwd: '/tmp/eval/project',
      disposableRoot: '/tmp/eval',
      writableRoots: ['/tmp/eval'],
      environment,
      allowedCredential,
      platform: 'linux',
      runtime: fakeFs(),
    }), /credential/);
  }
});

test('moves a credential-bearing environment through bounded Bubblewrap FD 3 arguments', () => {
  const secret = 'credential-must-not-enter-host-argv';
  const invocation = buildBubblewrapInvocation({
    command: '/usr/bin/node',
    args: ['fixture.js'],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: {
      PATH: '/usr/bin:/bin',
      HOME: '/tmp/eval/home',
      ANTHROPIC_API_KEY: secret,
    },
    allowedCredential: 'ANTHROPIC_API_KEY',
    environmentArgumentFd: 3,
    platform: 'linux',
    runtime: fakeFs(),
  });
  assert.equal(invocation.args.includes(secret), false);
  assert.equal(Object.values(invocation.env).includes(secret), false);
  const argsAt = invocation.args.indexOf('--args');
  assert.deepEqual(invocation.args.slice(argsAt, argsAt + 2), ['--args', '3']);
  assert.deepEqual(invocation.args.slice(-3), ['--', '/usr/bin/node', 'fixture.js']);
  assert.equal(invocation.argumentInput.fd, 3);
  const decoded = invocation.argumentInput.payload.toString('utf8')
    .split('\0').filter(Boolean);
  assert.deepEqual(decoded.slice(0, 4), [
    '--clearenv',
    '--setenv',
    'ANTHROPIC_API_KEY',
    secret,
  ]);
  assert.equal(decoded.includes('--args'), false);
});

test('rejects unsafe paths, environments, and working-directory escapes', () => {
  assert.throws(() => buildBubblewrapInvocation({
    command: 'node',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: {},
    platform: 'linux',
    runtime: fakeFs(),
  }), /invocation contract is invalid/);
  assert.throws(() => buildBubblewrapInvocation({
    command: '/usr/bin/node',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval-other'],
    environment: {},
    platform: 'linux',
    runtime: fakeFs({ extraDirectories: ['/tmp/eval-other'] }),
  }), /outside the evaluator-owned disposable root/);
  assert.throws(() => buildBubblewrapInvocation({
    command: '/usr/bin/node',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: { 'BAD-NAME': 'x' },
    platform: 'linux',
    runtime: fakeFs(),
  }), /environment entry is invalid/);
});

test('rejects tampered invocation values and canonical-directory identities', () => {
  const base = {
    command: '/usr/bin/node',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: {},
    platform: 'linux',
    runtime: fakeFs(),
  };
  for (const override of [
    { args: ['safe', 'bad\0arg'] },
    { writableRoots: [] },
    { shareNetwork: 'false' },
    { environmentArgumentFd: 0 },
    { environmentArgumentFd: 4 },
  ]) {
    assert.throws(
      () => buildBubblewrapInvocation({ ...base, ...override }),
      /invocation contract is invalid/,
    );
  }
  for (const environment of [
    [],
    { SAFE: 'bad\nvalue' },
    { '1INVALID': 'value' },
    { SAFE: 1 },
  ]) {
    assert.throws(
      () => buildBubblewrapInvocation({ ...base, environment }),
      /child environment|environment entry/,
    );
  }

  const symlinkedCwd = fakeFsWith({
    lstatSync(file) {
      const stat = fakeFs().lstatSync(file);
      if (file !== '/tmp/eval/project') return stat;
      return { ...stat, isSymbolicLink: () => true };
    },
  });
  assert.throws(
    () => buildBubblewrapInvocation({ ...base, runtime: symlinkedCwd }),
    /working directory must be a canonical real directory/,
  );

  const nestedRuntime = fakeFs({
    extraDirectories: ['/tmp/eval/work'],
  });
  const redirectedWritableRoot = {
    ...nestedRuntime,
    realpathSync: {
      native(file) {
        return file === '/tmp/eval/work' ? '/tmp/eval/replaced-work' : file;
      },
    },
  };
  assert.throws(
    () => buildBubblewrapInvocation({
      ...base,
      writableRoots: ['/tmp/eval/work'],
      runtime: redirectedWritableRoot,
    }),
    /writable root must be a canonical real directory/,
  );
});

test('deduplicates writable roots, sorts child env, and ignores unused opt', () => {
  const invocation = buildBubblewrapInvocation({
    command: '/usr/bin/node',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval', '/tmp/eval'],
    environment: { Z_LAST: 'last', A_FIRST: 'first' },
    platform: 'linux',
    runtime: fakeFs(),
  });
  const bindPairs = [];
  for (let index = 0; index < invocation.args.length - 2; index += 1) {
    if (invocation.args[index] === '--bind') {
      bindPairs.push(invocation.args.slice(index + 1, index + 3));
    }
  }
  assert.deepEqual(bindPairs, [['/tmp/eval', '/tmp/eval']]);
  assert.ok(
    invocation.args.indexOf('A_FIRST') < invocation.args.indexOf('Z_LAST'),
    'environment names must be emitted deterministically',
  );
  assert.equal(invocation.args.includes('/opt'), false);

  const inaccessibleSystemRoot = fakeFsWith({
    lstatSync(file) {
      if (file === '/etc/ssl') {
        throw Object.assign(new Error('denied'), { code: 'EACCES' });
      }
      return fakeFs().lstatSync(file);
    },
  });
  assert.throws(() => buildBubblewrapInvocation({
    command: '/usr/bin/node',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: {},
    platform: 'linux',
    runtime: inaccessibleSystemRoot,
  }), /system runtime root is unsafe/);
});

test('mounts opt only for a real command or resolved native runtime under opt', () => {
  const directRuntime = fakeFs({
    extraDirectories: ['/opt'],
    extraFiles: { '/opt/claude': ELF_HEADER },
  });
  const direct = buildBubblewrapInvocation({
    command: '/opt/claude',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: {},
    platform: 'linux',
    runtime: directRuntime,
  });
  const optAt = direct.args.indexOf('/opt');
  assert.ok(optAt > 0);
  assert.deepEqual(direct.args.slice(optAt - 1, optAt + 2), [
    '--ro-bind',
    '/opt',
    '/opt',
  ]);

  const shebangRuntime = fakeFs({
    extraDirectories: ['/opt'],
    extraFiles: {
      '/usr/local/lib/claude.js': '#!/usr/bin/env node\n',
      '/opt/node/bin/node': ELF_HEADER,
    },
  });
  const interpreted = buildBubblewrapInvocation({
    command: '/usr/local/lib/claude.js',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: { PATH: '/opt/node/bin:/usr/bin' },
    platform: 'linux',
    runtime: shebangRuntime,
  });
  assert.equal(interpreted.args.includes('/opt'), true);
});

test('fails closed for unresolved, indirect, or non-native command runtimes', () => {
  const unsupportedEnv = fakeFs({
    extraDirectories: ['/opt'],
    extraFiles: {
      '/usr/local/lib/claude.js': '#!/usr/bin/env -S node --no-warnings\n',
      '/opt/node/bin/node': ELF_HEADER,
    },
  });
  assert.throws(() => buildBubblewrapInvocation({
    command: '/usr/local/lib/claude.js',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: { PATH: '/opt/node/bin' },
    platform: 'linux',
    runtime: unsupportedEnv,
  }), /env shebang is unsupported/);

  const unresolved = fakeFs({
    extraFiles: {
      '/usr/local/lib/claude.js': '#!/usr/bin/env node\n',
    },
  });
  assert.throws(() => buildBubblewrapInvocation({
    command: '/usr/local/lib/claude.js',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: { PATH: '/usr/local/bin' },
    platform: 'linux',
    runtime: unresolved,
  }), /command runtime cannot be resolved/);

  const scriptedRuntime = fakeFs({
    extraFiles: {
      '/usr/local/lib/claude.js': '#!/usr/bin/env node\n',
      '/usr/local/bin/node': '#!/bin/sh\n',
      '/bin/sh': ELF_HEADER,
    },
  });
  assert.throws(() => buildBubblewrapInvocation({
    command: '/usr/local/lib/claude.js',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: { PATH: '/usr/local/bin' },
    platform: 'linux',
    runtime: scriptedRuntime,
  }), /command runtime must be a native executable/);

  const unsafePath = fakeFs({
    extraFiles: {
      '/usr/local/lib/claude.js': '#!/usr/bin/env node\n',
    },
  });
  assert.throws(() => buildBubblewrapInvocation({
    command: '/usr/local/lib/claude.js',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: { PATH: 'relative/bin:/usr/bin' },
    platform: 'linux',
    runtime: unsafePath,
  }), /command runtime PATH is unsafe/);

  const commandOutsideReadOnlyRoots = fakeFs({
    extraFiles: { '/tmp/eval/tool': ELF_HEADER },
  });
  assert.throws(() => buildBubblewrapInvocation({
    command: '/tmp/eval/tool',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: {},
    platform: 'linux',
    runtime: commandOutsideReadOnlyRoots,
  }), /command is outside the read-only executable roots/);

  const swappedCommand = fakeFs();
  const descriptorSwap = {
    ...swappedCommand,
    fstatSync(descriptor) {
      const stat = swappedCommand.fstatSync(descriptor);
      return { ...stat, ino: stat.ino + 1 };
    },
  };
  assert.throws(() => buildBubblewrapInvocation({
    command: '/usr/bin/node',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: {},
    platform: 'linux',
    runtime: descriptorSwap,
  }), /command identity changed while reading its header/);

  const metadataBase = fakeFs();
  let commandReads = 0;
  const metadataSwap = {
    ...metadataBase,
    lstatSync(file) {
      const stat = metadataBase.lstatSync(file);
      if (file !== '/usr/bin/node') return stat;
      commandReads += 1;
      return commandReads > 2 ? { ...stat, ctimeMs: stat.ctimeMs + 1 } : stat;
    },
  };
  assert.throws(() => buildBubblewrapInvocation({
    command: '/usr/bin/node',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: {},
    platform: 'linux',
    runtime: metadataSwap,
  }), /command identity changed/);
});

test('requires a private evaluator-owned disposable root for every writable mount', () => {
  const base = {
    command: '/usr/bin/node',
    args: [],
    cwd: '/tmp/eval/project',
    disposableRoot: '/tmp/eval',
    writableRoots: ['/tmp/eval'],
    environment: {},
    platform: 'linux',
  };
  assert.throws(
    () => buildBubblewrapInvocation({
      ...base,
      disposableRoot: undefined,
      runtime: fakeFs(),
    }),
    /invocation contract is invalid/,
  );

  for (const [label, change] of [
    ['owner', { uid: EVALUATOR_UID + 1 }],
    ['mode', { mode: 0o40750 }],
  ]) {
    const runtime = fakeFsWith({
      lstatSync(file) {
        const stat = fakeFs().lstatSync(file);
        return file === '/tmp/eval' ? { ...stat, ...change } : stat;
      },
    });
    assert.throws(
      () => buildBubblewrapInvocation({ ...base, runtime }),
      /disposable root is not evaluator-owned and private/,
      label,
    );
  }

  const driftBase = fakeFs();
  let disposableReads = 0;
  const identityDrift = {
    ...driftBase,
    lstatSync(file) {
      const stat = driftBase.lstatSync(file);
      if (file !== '/tmp/eval') return stat;
      disposableReads += 1;
      return disposableReads > 2 ? { ...stat, ino: stat.ino + 1 } : stat;
    },
  };
  assert.throws(
    () => buildBubblewrapInvocation({ ...base, runtime: identityDrift }),
    /disposable root identity changed/,
  );

  const nestedBase = fakeFs({
    extraDirectories: ['/tmp/eval/work', '/tmp/eval/work/project'],
  });
  const publicWritable = {
    ...nestedBase,
    lstatSync(file) {
      const stat = nestedBase.lstatSync(file);
      return file === '/tmp/eval/work'
        ? { ...stat, mode: 0o40750 }
        : stat;
    },
  };
  assert.throws(() => buildBubblewrapInvocation({
    ...base,
    cwd: '/tmp/eval/work/project',
    writableRoots: ['/tmp/eval/work'],
    runtime: publicWritable,
  }), /writable root is not evaluator-owned and private/);
});
