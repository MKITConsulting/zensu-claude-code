#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { spawn, spawnSync } = require('node:child_process');

const INSTALLER = path.resolve(
  __dirname,
  '..', '..', '..',
  'tests', 'structure', 'fixtures', 'install-claude-runtime-fixture.js',
);
const { InstallerFailure, install } = require(INSTALLER);
const REVISION = 'a'.repeat(40);
const CHILD_TIMEOUT_MS = 30000;
const BARRIER_TIMEOUT_MS = 15000;

function installerChildMain() {
  'use strict';

  const fs = require('node:fs');
  const path = require('node:path');
  const config = JSON.parse(process.env.ZENSU_INSTALLER_CHILD_CONFIG);
  const { InstallerFailure, install } = require(config.installer);
  const originalWriteFileSync = fs.writeFileSync.bind(fs);
  const waitBuffer = new Int32Array(new SharedArrayBuffer(4));
  let runtimePath = null;
  let materializationPaused = false;

  function writeMarker(file, value) {
    originalWriteFileSync(file, `${JSON.stringify(value)}\n`, {
      encoding: 'utf8',
      flag: 'wx',
      mode: 0o600,
    });
  }

  function waitForMarker(file, label) {
    const deadline = Date.now() + config.barrierTimeoutMs;
    while (!fs.existsSync(file)) {
      if (Date.now() >= deadline) {
        throw new InstallerFailure(`timed out waiting for ${label}`);
      }
      Atomics.wait(waitBuffer, 0, 0, 10);
    }
  }

  function isRuntimeFile(file) {
    if (runtimePath === null || typeof file !== 'string') return false;
    const relative = path.relative(runtimePath, path.resolve(file));
    return relative !== ''
      && relative !== '..'
      && !relative.startsWith(`..${path.sep}`)
      && !path.isAbsolute(relative);
  }

  if (config.pauseDuringMaterialization) {
    fs.writeFileSync = function observedRuntimeWrite(file, ...args) {
      const result = originalWriteFileSync(file, ...args);
      if (!materializationPaused && isRuntimeFile(file)) {
        materializationPaused = true;
        writeMarker(config.materializingFile, {
          child: config.id,
          runtime: runtimePath,
        });
        waitForMarker(config.resumeMaterializationFile, 'materialization resume');
      }
      return result;
    };
  }

  const hooks = {
    afterFinalRootCreated({ runtime }) {
      runtimePath = runtime.path;
      writeMarker(config.readyFile, {
        child: config.id,
        runtime: runtime.path,
      });
      waitForMarker(config.releaseFile, 'initial release');
    },
  };
  if (config.failAfterReady) {
    hooks.afterFinalRootReady = function failAfterConcurrentMaterialization() {
      waitForMarker(config.requiredPeerMarker, 'peer materialization');
      throw new InstallerFailure('injected concurrent post-ready failure');
    };
  }

  try {
    const runtime = install([
      config.source,
      config.cacheParent,
      config.version,
      config.revision,
    ], hooks);
    process.stdout.write(`${JSON.stringify({ ok: true, runtime })}\n`);
  } catch (error) {
    process.stdout.write(`${JSON.stringify({
      message: error?.message || String(error),
      name: error?.name || 'Error',
      ok: false,
    })}\n`);
    process.exitCode = config.failAfterReady ? 23 : 1;
  } finally {
    fs.writeFileSync = originalWriteFileSync;
  }
}

const INSTALLER_CHILD_PROGRAM = `(${installerChildMain.toString()})()`;

function command(commandName, args, options = {}) {
  const result = spawnSync(commandName, args, {
    encoding: 'utf8',
    env: {
      ...process.env,
      GIT_CONFIG_GLOBAL: process.platform === 'win32' ? 'NUL' : '/dev/null',
      GIT_CONFIG_NOSYSTEM: '1',
      GIT_TERMINAL_PROMPT: '0',
      LANG: 'C',
      LC_ALL: 'C',
    },
    timeout: 60000,
    ...options,
  });
  assert.equal(result.error, undefined, `${commandName} failed to start`);
  assert.equal(result.signal, null, `${commandName} exceeded its bound`);
  return result;
}

function invokeInstaller(args) {
  return command(process.execPath, [INSTALLER, ...args]);
}

function git(repository, args) {
  const result = command('git', ['-C', repository, ...args]);
  assert.equal(result.status, 0, `git ${args[0]} failed: ${result.stderr}`);
  return result.stdout.trim();
}

function createRepository(root, marketplacePluginName = 'zensu') {
  const source = path.join(root, 'source');
  fs.mkdirSync(path.join(source, '.claude-plugin'), { recursive: true });
  fs.mkdirSync(path.join(source, 'hooks'));
  fs.writeFileSync(
    path.join(source, '.claude-plugin', 'plugin.json'),
    `${JSON.stringify({ name: 'zensu', version: '0.16.1' })}\n`,
  );
  fs.writeFileSync(
    path.join(source, '.claude-plugin', 'marketplace.json'),
    `${JSON.stringify({
      name: 'zensu',
      plugins: [{
        name: marketplacePluginName,
        source: {
          source: 'github',
          repo: 'MKITConsulting/zensu-claude-code',
          ref: 'v0.16.1',
        },
        version: '0.16.1',
      }],
    })}\n`,
  );
  fs.writeFileSync(path.join(source, 'hooks', 'example.sh'), '#!/bin/bash\nexit 0\n');
  git(source, ['init', '-q']);
  git(source, ['config', 'user.name', 'Runtime Fixture Test']);
  git(source, ['config', 'user.email', 'runtime-fixture@zensu.invalid']);
  git(source, [
    'config',
    'core.hooksPath',
    process.platform === 'win32' ? 'NUL' : '/dev/null',
  ]);
  git(source, ['add', '.']);
  git(source, ['-c', 'commit.gpgsign=false', 'commit', '-qm', 'test: seed runtime fixture']);
  return {
    revision: git(source, ['rev-parse', 'HEAD']),
    source,
  };
}

function withTemporaryDirectory(prefix, callback) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  try {
    callback(temporary);
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}

async function withTemporaryDirectoryAsync(prefix, callback) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  try {
    return await callback(temporary);
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}

function spawnInstallerChild(config) {
  const child = spawn(process.execPath, ['-e', INSTALLER_CHILD_PROGRAM], {
    env: {
      ...process.env,
      GIT_CONFIG_GLOBAL: process.platform === 'win32' ? 'NUL' : '/dev/null',
      GIT_CONFIG_NOSYSTEM: '1',
      GIT_TERMINAL_PROMPT: '0',
      LANG: 'C',
      LC_ALL: 'C',
      ZENSU_INSTALLER_CHILD_CONFIG: JSON.stringify({
        ...config,
        barrierTimeoutMs: BARRIER_TIMEOUT_MS,
        installer: INSTALLER,
      }),
    },
    stdio: ['ignore', 'pipe', 'pipe'],
    windowsHide: true,
  });
  let stderr = '';
  let stdout = '';
  let settled = false;
  let timedOut = false;
  child.stderr.setEncoding('utf8');
  child.stdout.setEncoding('utf8');
  child.stderr.on('data', (chunk) => {
    stderr += chunk;
  });
  child.stdout.on('data', (chunk) => {
    stdout += chunk;
  });

  const timeout = setTimeout(() => {
    timedOut = true;
    child.kill('SIGKILL');
  }, CHILD_TIMEOUT_MS);
  const completed = new Promise((resolve) => {
    child.once('error', (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      resolve({
        code: null,
        error,
        signal: null,
        stderr,
        stdout,
        timedOut,
      });
    });
    child.once('close', (code, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      resolve({
        code,
        error: null,
        signal,
        stderr,
        stdout,
        timedOut,
      });
    });
  });
  return {
    child,
    completed,
    id: config.id,
  };
}

function terminateInstallerChild(state) {
  if (state.child.exitCode === null && state.child.signalCode === null) {
    state.child.kill('SIGKILL');
  }
}

function writeBarrierRelease(file) {
  fs.writeFileSync(file, 'release\n', {
    encoding: 'utf8',
    flag: 'wx',
    mode: 0o600,
  });
}

async function waitForBarrierFiles(files, children) {
  const pending = () => files.filter((file) => !fs.existsSync(file));
  if (pending().length === 0) return;

  await new Promise((resolve, reject) => {
    let settled = false;
    const interval = setInterval(check, 25);
    const timeout = setTimeout(() => {
      finish(new Error(
        `timed out waiting for barrier files: ${pending().join(', ')}`,
      ));
    }, BARRIER_TIMEOUT_MS);

    function finish(error = null) {
      if (settled) return;
      settled = true;
      clearInterval(interval);
      clearTimeout(timeout);
      for (const state of children) {
        state.child.removeListener('close', check);
        state.child.removeListener('error', check);
      }
      if (error === null) resolve();
      else reject(error);
    }

    function check() {
      if (pending().length === 0) {
        finish();
        return;
      }
      const stopped = children.find(
        (state) => state.child.exitCode !== null || state.child.signalCode !== null,
      );
      if (stopped) {
        finish(new Error(
          `installer child ${stopped.id} exited before reaching the filesystem barrier`,
        ));
      }
    }

    for (const state of children) {
      state.child.once('close', check);
      state.child.once('error', check);
    }
    check();
  });
}

function readBarrierRuntime(file) {
  const value = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert.equal(typeof value.runtime, 'string');
  return value.runtime;
}

async function assertInstallerChildResult(state, expectedCode, expectedOk) {
  const result = await state.completed;
  assert.equal(result.error, null, `${state.id} failed to start: ${result.error}`);
  assert.equal(result.timedOut, false, `${state.id} exceeded its bound`);
  assert.equal(result.signal, null, `${state.id} terminated via ${result.signal}`);
  assert.equal(result.code, expectedCode, `${state.id} stderr: ${result.stderr}`);
  assert.equal(result.stderr, '');
  const lines = result.stdout.trim().split(/\r?\n/).filter(Boolean);
  assert.equal(lines.length, 1, `${state.id} emitted unexpected stdout: ${result.stdout}`);
  const payload = JSON.parse(lines[0]);
  assert.equal(payload.ok, expectedOk);
  return payload;
}

function runtimeChildren(parent) {
  if (!fs.existsSync(parent)) return [];
  return fs.readdirSync(parent)
    .filter((entry) => entry.startsWith('.zensu-runtime-v'))
    .sort();
}

function assertNoCoordinationResidue(cacheParent) {
  const residue = fs.readdirSync(cacheParent).filter(
    (entry) => entry.includes('lock')
      || entry.startsWith('.zensu-runtime-quarantine-'),
  );
  assert.deepEqual(residue, []);
}

test('rejects an incomplete immutable-runtime invocation', () => {
  const result = invokeInstaller([]);
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '');
  assert.match(result.stderr, /SOURCE CACHE_PARENT VERSION REVISION/);
});

test('rejects a cache parent inside the source checkout', () => {
  withTemporaryDirectory('zensu-installer-policy-', (temporary) => {
    const source = path.join(temporary, 'source');
    fs.mkdirSync(source);
    const result = invokeInstaller([
      source,
      path.join(source, 'runtime-cache'),
      '0.17.0',
      REVISION,
    ]);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /cache parent must be outside the source checkout/);
  });
});

test('rejects a cache parent beneath a non-directory ancestor', () => {
  withTemporaryDirectory('zensu-installer-parent-ancestor-', (temporary) => {
    const fixture = createRepository(temporary);
    const blockingAncestor = path.join(temporary, 'not-a-directory');
    fs.writeFileSync(blockingAncestor, 'file\n');

    const result = invokeInstaller([
      fixture.source,
      path.join(blockingAncestor, 'cache'),
      '0.17.0',
      fixture.revision,
    ]);

    assert.equal(result.status, 1);
    assert.equal(result.stdout, '');
    assert.match(result.stderr, /cache parent ancestor must be a real directory/);
  });
});

test('removes only its unpredictable final root after manifest validation fails', () => {
  withTemporaryDirectory('zensu-installer-cleanup-', (temporary) => {
    const fixture = createRepository(temporary, 'wrong-plugin');
    const cacheParent = path.join(temporary, 'cache', 'zensu');
    const result = invokeInstaller([
      fixture.source,
      cacheParent,
      '0.17.0',
      fixture.revision,
    ]);

    assert.equal(result.status, 1);
    assert.equal(result.stdout, '');
    assert.equal(
      result.stderr,
      'install-claude-runtime-fixture: marketplace fixture does not contain the exact plugin entry\n',
    );
    assert.deepEqual(runtimeChildren(cacheParent), []);
    assert.equal(fs.existsSync(fixture.source), true);
  });
});

test('removes its verified final root after a post-ready failure', () => {
  withTemporaryDirectory('zensu-installer-post-ready-', (temporary) => {
    const fixture = createRepository(temporary);
    const cacheParent = path.join(temporary, 'cache', 'zensu');

    assert.throws(
      () => install([
        fixture.source,
        cacheParent,
        '0.17.0',
        fixture.revision,
      ], {
        afterFinalRootReady() {
          throw new InstallerFailure('injected post-ready failure');
        },
      }),
      /injected post-ready failure/,
    );

    assert.deepEqual(runtimeChildren(cacheParent), []);
    assert.equal(fs.existsSync(fixture.source), true);
  });
});

test('captures final-root identity before exposing it to hooks', () => {
  withTemporaryDirectory('zensu-installer-identity-', (temporary) => {
    const fixture = createRepository(temporary);
    const cacheParent = path.join(temporary, 'cache', 'zensu');
    let observed = null;

    assert.throws(
      () => install([
        fixture.source,
        cacheParent,
        '0.17.0',
        fixture.revision,
      ], {
        afterFinalRootCreated({ runtime }) {
          observed = runtime;
          const stat = fs.lstatSync(runtime.path, { bigint: true });
          assert.equal(stat.dev, runtime.dev);
          assert.equal(stat.ino, runtime.ino);
          throw new InstallerFailure('injected after identity capture');
        },
      }),
      /injected after identity capture/,
    );

    assert.notEqual(observed, null);
    assert.deepEqual(runtimeChildren(cacheParent), []);
  });
});

test('never path-cleans a foreign root swapped after identity capture', () => {
  withTemporaryDirectory('zensu-installer-root-swap-', (temporary) => {
    const fixture = createRepository(temporary);
    const cacheParent = path.join(temporary, 'cache', 'zensu');
    let displacedRuntime = null;
    let foreignRuntime = null;

    assert.throws(
      () => install([
        fixture.source,
        cacheParent,
        '0.17.0',
        fixture.revision,
      ], {
        afterFinalRootCreated({ runtime }) {
          displacedRuntime = `${runtime.path}-displaced`;
          foreignRuntime = runtime.path;
          fs.renameSync(runtime.path, displacedRuntime);
          fs.mkdirSync(runtime.path);
          fs.writeFileSync(path.join(runtime.path, 'foreign-marker'), 'do not delete\n');
        },
      }),
      /installer cleanup could not prove ownership/,
    );

    assert.equal(fs.existsSync(displacedRuntime), true);
    assert.equal(
      fs.readFileSync(path.join(foreignRuntime, 'foreign-marker'), 'utf8'),
      'do not delete\n',
    );
  });
});

test('fails closed when the canonical cache parent is swapped after root creation', () => {
  withTemporaryDirectory('zensu-installer-parent-swap-', (temporary) => {
    const fixture = createRepository(temporary);
    const cacheParent = path.join(temporary, 'cache', 'zensu');
    const displacedParent = path.join(temporary, 'cache', 'zensu-displaced');
    let createdName = null;

    assert.throws(
      () => install([
        fixture.source,
        cacheParent,
        '0.17.0',
        fixture.revision,
      ], {
        afterFinalRootCreated({ runtime }) {
          createdName = path.basename(runtime.path);
          fs.renameSync(cacheParent, displacedParent);
          fs.mkdirSync(cacheParent);
        },
      }),
      /installer cleanup could not prove ownership/,
    );

    assert.equal(fs.existsSync(path.join(cacheParent, createdName)), false);
    assert.equal(fs.existsSync(path.join(displacedParent, createdName)), true);
  });
});

test('quarantines but never removes a swapped final root during cleanup', () => {
  withTemporaryDirectory('zensu-installer-quarantine-swap-', (temporary) => {
    const fixture = createRepository(temporary);
    const cacheParent = path.join(temporary, 'cache', 'zensu');
    let displacedRuntime = null;
    let swapped = false;

    assert.throws(
      () => install([
        fixture.source,
        cacheParent,
        '0.17.0',
        fixture.revision,
      ], {
        afterFinalRootReady() {
          throw new InstallerFailure('injected post-ready failure');
        },
        beforeQuarantineRename({ identity, label }) {
          if (label !== 'runtime directory' || swapped) return;
          swapped = true;
          displacedRuntime = `${identity.path}-owned`;
          fs.renameSync(identity.path, displacedRuntime);
          fs.mkdirSync(identity.path);
          fs.writeFileSync(path.join(identity.path, 'foreign-marker'), 'do not delete\n');
        },
      }),
      /installer cleanup could not prove ownership/,
    );

    assert.equal(fs.existsSync(displacedRuntime), true);
    const quarantines = fs.readdirSync(cacheParent)
      .filter((entry) => entry.startsWith('.zensu-runtime-quarantine-'));
    assert.equal(quarantines.length, 1);
    assert.equal(
      fs.readFileSync(path.join(cacheParent, quarantines[0], 'foreign-marker'), 'utf8'),
      'do not delete\n',
    );
  });
});

test('parallel successful installers materialize independent unpredictable roots', async () => {
  await withTemporaryDirectoryAsync('zensu-installer-concurrent-success-', async (temporary) => {
    const fixture = createRepository(temporary);
    const cacheParent = path.join(temporary, 'cache', 'zensu');
    const barriers = path.join(temporary, 'barriers');
    fs.mkdirSync(barriers);
    const children = ['first', 'second'].map((id) => spawnInstallerChild({
      cacheParent,
      id,
      readyFile: path.join(barriers, `${id}.ready.json`),
      releaseFile: path.join(barriers, `${id}.release`),
      revision: fixture.revision,
      source: fixture.source,
      version: '0.17.0',
    }));

    try {
      await waitForBarrierFiles(
        children.map((state) => path.join(barriers, `${state.id}.ready.json`)),
        children,
      );
      const observedRoots = children.map(
        (state) => readBarrierRuntime(path.join(barriers, `${state.id}.ready.json`)),
      );
      assert.equal(new Set(observedRoots).size, 2);
      for (const runtime of observedRoots) {
        assert.equal(path.dirname(runtime), fs.realpathSync.native(cacheParent));
        assert.match(
          path.basename(runtime),
          /^\.zensu-runtime-v0\.17\.0-[a-f0-9]{48}$/,
        );
        assert.deepEqual(fs.readdirSync(runtime), []);
      }

      for (const state of children) {
        writeBarrierRelease(path.join(barriers, `${state.id}.release`));
      }
      const results = await Promise.all(
        children.map((state) => assertInstallerChildResult(state, 0, true)),
      );
      assert.deepEqual(
        new Set(results.map((result) => result.runtime)),
        new Set(observedRoots),
      );
      for (const runtime of observedRoots) {
        assert.equal(fs.existsSync(
          path.join(runtime, '.claude-plugin', 'plugin.json'),
        ), true);
        assert.equal(fs.existsSync(path.join(runtime, 'hooks', 'example.sh')), true);
      }
      assert.deepEqual(
        new Set(runtimeChildren(cacheParent)),
        new Set(observedRoots.map((runtime) => path.basename(runtime))),
      );
      assertNoCoordinationResidue(cacheParent);
    } finally {
      for (const state of children) terminateInstallerChild(state);
      await Promise.all(children.map((state) => state.completed));
    }
  });
});

test('a parallel failing installer cleans only its root during peer materialization', async () => {
  await withTemporaryDirectoryAsync('zensu-installer-concurrent-failure-', async (temporary) => {
    const fixture = createRepository(temporary);
    const cacheParent = path.join(temporary, 'cache', 'zensu');
    const barriers = path.join(temporary, 'barriers');
    fs.mkdirSync(cacheParent, { recursive: true });
    fs.mkdirSync(barriers);

    const foreignRoot = path.join(
      cacheParent,
      `.zensu-runtime-v0.17.0-${'f'.repeat(48)}`,
    );
    fs.mkdirSync(foreignRoot, { mode: 0o700 });
    fs.writeFileSync(path.join(foreignRoot, 'foreign-marker'), 'do not delete\n');

    const materializingFile = path.join(barriers, 'success.materializing.json');
    const resumeMaterializationFile = path.join(barriers, 'success.resume');
    const success = spawnInstallerChild({
      cacheParent,
      id: 'success',
      materializingFile,
      pauseDuringMaterialization: true,
      readyFile: path.join(barriers, 'success.ready.json'),
      releaseFile: path.join(barriers, 'success.release'),
      resumeMaterializationFile,
      revision: fixture.revision,
      source: fixture.source,
      version: '0.17.0',
    });
    const failure = spawnInstallerChild({
      cacheParent,
      failAfterReady: true,
      id: 'failure',
      readyFile: path.join(barriers, 'failure.ready.json'),
      releaseFile: path.join(barriers, 'failure.release'),
      requiredPeerMarker: materializingFile,
      revision: fixture.revision,
      source: fixture.source,
      version: '0.17.0',
    });
    const children = [success, failure];

    try {
      await waitForBarrierFiles([
        path.join(barriers, 'success.ready.json'),
        path.join(barriers, 'failure.ready.json'),
      ], children);
      const successRoot = readBarrierRuntime(path.join(barriers, 'success.ready.json'));
      const failureRoot = readBarrierRuntime(path.join(barriers, 'failure.ready.json'));
      assert.equal(new Set([successRoot, failureRoot, foreignRoot]).size, 3);
      for (const runtime of [successRoot, failureRoot]) {
        assert.equal(path.dirname(runtime), fs.realpathSync.native(cacheParent));
        assert.match(
          path.basename(runtime),
          /^\.zensu-runtime-v0\.17\.0-[a-f0-9]{48}$/,
        );
      }
      assert.deepEqual(fs.readdirSync(successRoot), []);
      assert.deepEqual(fs.readdirSync(failureRoot), []);

      writeBarrierRelease(path.join(barriers, 'success.release'));
      writeBarrierRelease(path.join(barriers, 'failure.release'));
      await waitForBarrierFiles([materializingFile], children);
      assert.equal(readBarrierRuntime(materializingFile), successRoot);

      const failureResult = await assertInstallerChildResult(failure, 23, false);
      assert.equal(failureResult.name, 'InstallerFailure');
      assert.equal(
        failureResult.message,
        'injected concurrent post-ready failure',
      );
      assert.equal(
        success.child.exitCode === null && success.child.signalCode === null,
        true,
        'successful peer must remain paused inside materialization during cleanup',
      );
      assert.equal(fs.existsSync(failureRoot), false);
      assert.equal(fs.existsSync(successRoot), true);
      assert.equal(
        fs.readFileSync(path.join(foreignRoot, 'foreign-marker'), 'utf8'),
        'do not delete\n',
      );
      assertNoCoordinationResidue(cacheParent);

      writeBarrierRelease(resumeMaterializationFile);
      const successResult = await assertInstallerChildResult(success, 0, true);
      assert.equal(successResult.runtime, successRoot);
      assert.equal(fs.existsSync(
        path.join(successRoot, '.claude-plugin', 'plugin.json'),
      ), true);
      assert.equal(fs.existsSync(path.join(successRoot, 'hooks', 'example.sh')), true);
      assert.equal(
        fs.readFileSync(path.join(foreignRoot, 'foreign-marker'), 'utf8'),
        'do not delete\n',
      );
      assert.deepEqual(
        new Set(runtimeChildren(cacheParent)),
        new Set([path.basename(foreignRoot), path.basename(successRoot)]),
      );
      assertNoCoordinationResidue(cacheParent);
    } finally {
      for (const state of children) terminateInstallerChild(state);
      await Promise.all(children.map((state) => state.completed));
    }
  });
});

test('materializes directly in the final root without a root publication rename', () => {
  withTemporaryDirectory('zensu-installer-direct-final-', (temporary) => {
    const fixture = createRepository(temporary);
    const cacheParent = path.join(temporary, 'cache', 'zensu');
    const originalRename = fs.renameSync;
    const renames = [];
    let createdRuntime = null;

    fs.renameSync = function observedRename(source, destination) {
      renames.push({
        destination: path.resolve(destination),
        source: path.resolve(source),
      });
      return originalRename.call(fs, source, destination);
    };
    let installed;
    try {
      installed = install([
        fixture.source,
        cacheParent,
        '0.17.0',
        fixture.revision,
      ], {
        afterFinalRootCreated({ runtime }) {
          createdRuntime = runtime.path;
        },
      });
    } finally {
      fs.renameSync = originalRename;
    }

    assert.equal(installed, createdRuntime);
    assert.ok(renames.length > 0, 'manifest replacement should remain atomic');
    for (const operation of renames) {
      assert.equal(
        operation.source.startsWith(`${installed}${path.sep}`),
        true,
        `rename source escaped final root: ${operation.source}`,
      );
      assert.equal(
        operation.destination.startsWith(`${installed}${path.sep}`),
        true,
        `rename destination escaped final root: ${operation.destination}`,
      );
    }
  });
});

test('returns an unpredictable immutable child root and leaves registry publication external', () => {
  withTemporaryDirectory('zensu-installer-success-', (temporary) => {
    const fixture = createRepository(temporary);
    const cacheParent = path.join(temporary, 'cache', 'zensu');
    const result = invokeInstaller([
      fixture.source,
      cacheParent,
      '0.17.0',
      fixture.revision,
    ]);

    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stderr, '');
    const runtime = result.stdout.trim();
    assert.equal(path.dirname(runtime), fs.realpathSync.native(cacheParent));
    assert.match(
      path.basename(runtime),
      /^\.zensu-runtime-v0\.17\.0-[a-f0-9]{48}$/,
    );
    assert.notEqual(runtime, path.join(cacheParent, '0.17.0'));
    const manifest = JSON.parse(
      fs.readFileSync(path.join(runtime, '.claude-plugin', 'plugin.json'), 'utf8'),
    );
    const marketplace = JSON.parse(
      fs.readFileSync(path.join(runtime, '.claude-plugin', 'marketplace.json'), 'utf8'),
    );
    assert.equal(manifest.version, '0.17.0');
    assert.equal(marketplace.plugins[0].version, '0.17.0');
    assert.equal(marketplace.plugins[0].source.ref, 'v0.17.0');
    assert.deepEqual(
      fs.readdirSync(cacheParent).filter((entry) => !entry.startsWith('.zensu-runtime-v')),
      [],
    );
    assert.equal(fs.existsSync(fixture.source), true);
  });
});
