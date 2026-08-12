'use strict';

const assert = require('node:assert/strict');
const { spawn, spawnSync } = require('node:child_process');
const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  EXIT_MANIFEST,
  EXIT_SUITE,
  atomicWriteJson,
  loadAndValidateManifest,
  main,
  runProfile,
  spawnAndWait,
  terminateOwnedTree,
  validateManifest,
} = require('../run-profile.js');
const { RUNTIME_PATHS } = require('../windows-profile-contract.js');

const WINDOWS_TEST_WAIT_MS = 30000;
const TEST_WAIT_MS = process.platform === 'win32' ? WINDOWS_TEST_WAIT_MS : 3000;
// A cold Windows PowerShell Add-Type compilation can exceed 30 seconds while
// the Windows contract shards share one hosted runner pool. Keep the fixture
// bounded, but leave enough room to observe the child process's real exit code.
const TEST_SUITE_TIMEOUT_MS = process.platform === 'win32' ? 60000 : 5000;
const TEST_PROFILE_TIMEOUT_MS = process.platform === 'win32' ? 180000 : 30000;
const TEST_PROFILE_DEADLINE_MS = process.platform === 'win32' ? 60000 : 120;
const TEST_PROFILE_DEADLINE_SUITE_TIMEOUT_MS =
  process.platform === 'win32' ? 90000 : 5000;
const TEST_PROFILE_DEADLINE_ASSERT_MS =
  process.platform === 'win32' ? 120000 : 3000;

function temporaryRoot() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-profile-runner-'));
  fs.mkdirSync(path.join(root, 'suites'), { recursive: true });
  const repositoryRoot = path.resolve(__dirname, '..', '..');
  for (const relative of RUNTIME_PATHS) {
    if (relative === 'tests/profiles/windows-ci.v1.json'
        || relative === 'tests/profiles/windows-ci-command-catalog.v1.json') continue;
    const destination = path.join(root, relative);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(path.join(repositoryRoot, relative), destination);
  }
  return root;
}

function removeTemporaryRoot(root) {
  fs.rmSync(root, {
    recursive: true,
    force: true,
    maxRetries: process.platform === 'win32' ? 20 : 0,
    retryDelay: process.platform === 'win32' ? 100 : 0,
  });
}

async function removeTemporaryRootAfterProcessExit(root) {
  // Yield between Windows retries so pending process/stream close work can
  // release the fixture tree instead of being blocked by synchronous cleanup.
  await fs.promises.rm(root, {
    recursive: true,
    force: true,
    maxRetries: process.platform === 'win32' ? 20 : 0,
    retryDelay: process.platform === 'win32' ? 100 : 0,
  });
}

function writeSuite(root, name, source) {
  const relative = `suites/${name}.js`;
  fs.writeFileSync(path.join(root, relative), source, { mode: 0o700 });
  return relative;
}

function writeBashSuite(root, name, source) {
  const relative = `suites/${name}.sh`;
  fs.writeFileSync(path.join(root, relative), source, { mode: 0o700 });
  return relative;
}

function manifestFor(platform, suites) {
  return {
    schemaVersion: 1,
    profiles: {
      'test-profile': {
        platform,
        profileTimeoutMs: TEST_PROFILE_TIMEOUT_MS,
        suites,
      },
    },
  };
}

function suite(id, relative, overrides = {}) {
  return {
    id,
    runner: 'node',
    path: relative,
    args: [],
    timeoutMs: TEST_SUITE_TIMEOUT_MS,
    ...overrides,
  };
}

function writeCatalog(root, suites) {
  const file = path.join(root, 'tests', 'profiles', 'windows-ci-command-catalog.v1.json');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify({
    schemaVersion: 1,
    commands: suites.map(({ runner, path: relative, args }) => ({
      runner,
      path: relative,
      args,
    })),
  })}\n`);
}

async function waitFor(predicate, timeoutMs = TEST_WAIT_MS) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error('timed out waiting for test condition');
}

function processAlive(pid) {
  // Number('') is 0, and process.kill(0, sig) signals the CALLER'S OWN process
  // group — always alive — so an empty pid file would turn every wait here into
  // a silent timeout against this very process. Both readers below take the pid
  // only after the profile has completed, so that window is not reachable today;
  // this refuses the shape outright rather than depending on it staying so.
  if (!Number.isSafeInteger(pid) || pid <= 0) {
    throw new Error(`refusing to probe a non-process pid: ${JSON.stringify(pid)}`);
  }
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error.code === 'ESRCH') return false;
    throw error;
  }
}

test('validates the complete manifest before selecting a profile through the public CLI', async () => {
  const root = temporaryRoot();
  try {
    const good = writeSuite(root, 'good', 'process.exit(0);\n');
    const marker = path.join(root, 'spawned');
    const wouldSpawn = writeSuite(
      root,
      'would-spawn',
      `require('node:fs').writeFileSync(${JSON.stringify(marker)}, 'bad');\n`,
    );
    const manifest = {
      schemaVersion: 1,
      profiles: {
        selected: {
          platform: 'win32',
          profileTimeoutMs: 30000,
          suites: [suite('selected-good', good)],
        },
        invalid: {
          platform: 'win32',
          profileTimeoutMs: 30000,
          suites: [suite('invalid-path', wouldSpawn, { path: '../escape.js' })],
        },
      },
    };
    const manifestPath = path.join(root, 'tests', 'profiles', 'windows-ci.v1.json');
    fs.mkdirSync(path.dirname(manifestPath), { recursive: true });
    fs.writeFileSync(manifestPath, `${JSON.stringify(manifest)}\n`);
    writeCatalog(root, [suite('catalog-good', good), suite('catalog-invalid', wouldSpawn)]);
    const stderr = [];
    assert.equal(await main({
      root,
      argv: ['selected'],
      platform: 'win32',
      sourceGitRevision: 'a'.repeat(40),
      installSignalHandlers: false,
      stderr: { write(value) { stderr.push(String(value)); } },
      stdout: { write() {} },
    }), EXIT_MANIFEST);
    assert.match(stderr.join(''), /path traversal|repo-relative/);
    assert.equal(fs.existsSync(marker), false);
  } finally {
    removeTemporaryRoot(root);
  }
});

test('rejects unknown keys, duplicate commands, symlinks, hardlinks, and unbounded suites', () => {
  const root = temporaryRoot();
  try {
    const good = writeSuite(root, 'good', 'process.exit(0);\n');
    const link = path.join(root, 'suites', 'link.js');
    fs.symlinkSync(path.join(root, good), link);
    const linkedSource = writeSuite(root, 'linked-source', 'process.exit(0);\n');
    const hardlink = path.join(root, 'suites', 'hardlink.js');
    fs.linkSync(path.join(root, linkedSource), hardlink);

    assert.throws(
      () => validateManifest({ ...manifestFor(process.platform, [suite('one', good)]), extra: true }, root),
      /unknown key/,
    );
    assert.throws(
      () => validateManifest(
        manifestFor(process.platform, [suite('one', good), suite('two', good)]),
        root,
      ),
      /duplicate suite command/,
    );
    assert.throws(
      () => validateManifest(manifestFor(process.platform, [suite('link', 'suites/link.js')]), root),
      /symlink/,
    );
    assert.throws(
      () => validateManifest(manifestFor(process.platform, [suite('hardlink', 'suites/hardlink.js')]), root),
      /multiply linked/,
    );
    assert.throws(
      () => validateManifest(
        manifestFor(process.platform, [suite('timeout', good, { timeoutMs: 0 })]),
        root,
      ),
      /timeoutMs/,
    );
    const invalidProfileTimeout = manifestFor(process.platform, [suite('one', good)]);
    invalidProfileTimeout.profiles['test-profile'].profileTimeoutMs = 3600001;
    assert.throws(() => validateManifest(invalidProfileTimeout, root), /profileTimeoutMs/);
  } finally {
    removeTemporaryRoot(root);
  }
});

test('allows one script to expose distinct bounded case selections', () => {
  const root = temporaryRoot();
  try {
    const good = writeSuite(root, 'good', 'process.exit(0);\n');
    const validated = validateManifest(
      manifestFor(process.platform, [
        suite('case-a', good, { args: ['--cases', 'A'] }),
        suite('case-b', good, { args: ['--cases', 'B'] }),
      ]),
      root,
    );
    assert.equal(validated.profiles.get('test-profile').suites.length, 2);
  } finally {
    removeTemporaryRoot(root);
  }
});

test('streams before exit, isolates credentials/home, and publishes a running report atomically', async () => {
  let root = temporaryRoot();
  try {
    const output = [];
    let backpressureApplied = false;
    const outputSink = new EventEmitter();
    outputSink.write = (chunk) => {
      const value = String(chunk);
      output.push(value);
      if (backpressureApplied || !value.includes('early-output')) return true;
      backpressureApplied = true;
      setImmediate(() => outputSink.emit('drain'));
      return false;
    };
    const release = path.join(root, 'release');
    const child = writeSuite(root, 'stream', `
      const fs = require('node:fs');
      const path = require('node:path');
      const forbidden = Object.entries(process.env).some(([key, value]) =>
        /^(?:anthropic_api_key|claude_code_oauth_token|gh_token|node_options|bash_env)$/i.test(key)
          && value);
      process.stdout.write('early-output\\n');
      const timer = setInterval(() => {
        if (!fs.existsSync(${JSON.stringify(release)})) return;
        clearInterval(timer);
        const isolated = process.env.HOME && process.env.HOME !== ${JSON.stringify(process.env.HOME)};
        process.stderr.write(forbidden || !isolated ? 'credential-leaked\\n' : 'credential-free\\n');
        process.stderr.write('sandbox-prefix:' + path.basename(path.dirname(process.env.TEMP)) + '\\n');
      }, 10);
    `);
    const reportDirectory = path.join(root, 'reports');
    const pending = runProfile({
      manifest: manifestFor(process.platform, [suite('stream', child)]),
      profileId: 'test-profile',
      root,
      reportDirectory,
      environment: {
        ...process.env,
        ANTHROPIC_API_KEY: 'api-secret',
        anthropic_api_key: 'mixed-case-secret',
        CLAUDE_CODE_OAUTH_TOKEN: 'oauth-secret',
        GH_TOKEN: 'github-secret',
        NODE_OPTIONS: '--require=/tmp/hostile.js',
        BASH_ENV: '/tmp/hostile.sh',
      },
      output: outputSink,
      sourceGitRevision: 'a'.repeat(40),
      runId: '123',
      runAttempt: '2',
      eventName: 'pull_request',
      runnerImage: 'test-runner',
    });
    await waitFor(() => output.join('').includes('early-output'));
    const running = JSON.parse(
      fs.readFileSync(path.join(reportDirectory, 'test-profile.json'), 'utf8'),
    );
    assert.equal(running.status, 'running');
    assert.deepEqual(running.suites, []);
    fs.writeFileSync(release, 'go\n');
    const result = await pending;
    assert.equal(result.exitCode, 0);
    assert.equal(backpressureApplied, true);
    assert.match(output.join(''), /early-output[\s\S]*credential-free/);
    assert.match(output.join(''), /sandbox-prefix:zp-[A-Za-z0-9_-]+/);
    assert.doesNotMatch(output.join(''), /credential-leaked/);
    const report = JSON.parse(fs.readFileSync(result.reportPath, 'utf8'));
    assert.equal(report.status, 'passed');
    assert.equal(report.suites[0].status, 'passed');
    assert.equal(report.suites[0].exitCode, 0);
    assert.equal(report.suites[0].cleanup.status, 'terminated');
    assert.match(report.suites[0].executedSha256, /^[a-f0-9]{64}$/);
    assert.equal(Object.hasOwn(report, 'environment'), false);
    assert.match(report.manifestSha256, /^[a-f0-9]{64}$/);
    assert.equal(report.sourceGitRevision, 'a'.repeat(40));
    assert.equal(report.runAttempt, '2');
    assert.equal(report.runnerImage, 'test-runner');
    await removeTemporaryRootAfterProcessExit(root);
    root = null;
  } finally {
    if (root) await removeTemporaryRootAfterProcessExit(root);
  }
});

test('times out a nested process tree and records deterministic failure evidence', async () => {
  const root = temporaryRoot();
  try {
    const pidFile = path.join(root, 'grandchild.pid');
    const child = writeSuite(root, 'timeout', `
      const fs = require('node:fs');
      const { spawn } = require('node:child_process');
      const nested = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {
        stdio: 'ignore',
      });
      nested.unref();
      fs.writeFileSync(${JSON.stringify(pidFile)}, String(nested.pid));
      setInterval(() => {}, 1000);
    `);
    const result = await runProfile({
      manifest: manifestFor(process.platform, [
        suite('timeout', child, {
          timeoutMs: process.platform === 'win32' ? WINDOWS_TEST_WAIT_MS : 250,
        }),
      ]),
      profileId: 'test-profile',
      root,
      reportDirectory: path.join(root, 'reports'),
      output: { write() {} },
    });
    assert.equal(result.exitCode, EXIT_SUITE);
    const report = JSON.parse(fs.readFileSync(result.reportPath, 'utf8'));
    assert.equal(report.status, 'failed');
    assert.equal(report.suites[0].status, 'timed_out');
    assert.equal(report.suites[0].cleanup.status, 'terminated');
    const nestedPid = Number(fs.readFileSync(pidFile, 'utf8'));
    await waitFor(() => !processAlive(nestedPid));
  } finally {
    removeTemporaryRoot(root);
  }
});

test('the internal profile deadline terminates the active tree before the CI envelope', async () => {
  const root = temporaryRoot();
  try {
    const readyFile = path.join(root, 'profile-timeout.ready');
    const child = writeSuite(root, 'profile-timeout', `
      const fs = require('node:fs');
      fs.writeFileSync(${JSON.stringify(readyFile)}, 'ready');
      setInterval(() => {}, 1000);
    `);
    const manifest = manifestFor(process.platform, [
      suite('profile-timeout', child, { timeoutMs: TEST_PROFILE_DEADLINE_SUITE_TIMEOUT_MS }),
    ]);
    manifest.profiles['test-profile'].profileTimeoutMs = TEST_PROFILE_DEADLINE_MS;
    const result = await runProfile({
      manifest,
      profileId: 'test-profile',
      root,
      reportDirectory: path.join(root, 'reports'),
      output: { write() { return true; } },
    });
    assert.equal(result.exitCode, EXIT_SUITE);
    assert.equal(result.report.profileDeadlineExceeded, true);
    assert.equal(result.report.suites[0].timeoutScope, 'profile');
    assert.equal(result.report.suites[0].cleanup.status, 'terminated');
    assert.equal(fs.existsSync(readyFile), true);
    assert.ok(result.report.durationMs < TEST_PROFILE_DEADLINE_ASSERT_MS);
  } finally {
    removeTemporaryRoot(root);
  }
});

test('normal suite completion still terminates background descendants before reporting', async () => {
  const root = temporaryRoot();
  try {
    const pidFile = path.join(root, 'background.pid');
    const child = writeSuite(root, 'background', `
      const fs = require('node:fs');
      const { spawn } = require('node:child_process');
      const nested = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {
        stdio: 'ignore',
      });
      nested.unref();
      fs.writeFileSync(${JSON.stringify(pidFile)}, String(nested.pid));
    `);
    const result = await runProfile({
      manifest: manifestFor(process.platform, [suite('background', child)]),
      profileId: 'test-profile',
      root,
      reportDirectory: path.join(root, 'reports'),
      output: { write() { return true; } },
    });
    assert.equal(result.exitCode, 0);
    assert.equal(result.report.suites[0].cleanup.status, 'terminated');
    const nestedPid = Number(fs.readFileSync(pidFile, 'utf8'));
    await waitFor(() => !processAlive(nestedPid));
  } finally {
    removeTemporaryRoot(root);
  }
});

test('continues after an ordinary suite failure and reports every result', async () => {
  const root = temporaryRoot();
  try {
    const fail = writeSuite(root, 'fail', 'process.exit(7);\n');
    const pass = writeSuite(root, 'pass', 'process.exit(0);\n');
    const result = await runProfile({
      manifest: manifestFor(process.platform, [
        suite('fail', fail),
        suite('pass', pass),
      ]),
      profileId: 'test-profile',
      root,
      reportDirectory: path.join(root, 'reports'),
      output: { write() {} },
    });
    assert.equal(result.exitCode, EXIT_SUITE);
    const report = JSON.parse(fs.readFileSync(result.reportPath, 'utf8'));
    assert.deepEqual(
      report.suites.map(({ id, status, exitCode }) => ({ id, status, exitCode })),
      [
        { id: 'fail', status: 'failed', exitCode: 7 },
        { id: 'pass', status: 'passed', exitCode: 0 },
      ],
    );
  } finally {
    removeTemporaryRoot(root);
  }
});

test('loads only the repository-owned manifest path', () => {
  const root = temporaryRoot();
  try {
    const good = writeSuite(root, 'good', 'process.exit(0);\n');
    const manifestPath = path.join(root, 'tests', 'profiles', 'windows-ci.v1.json');
    fs.mkdirSync(path.dirname(manifestPath), { recursive: true });
    const command = suite('one', good);
    fs.writeFileSync(manifestPath, `${JSON.stringify(manifestFor('win32', [command]))}\n`);
    writeCatalog(root, [command]);
    const loaded = loadAndValidateManifest(root);
    assert.equal(loaded.profiles.has('test-profile'), true);
    assert.equal(EXIT_MANIFEST, 2);
  } finally {
    removeTemporaryRoot(root);
  }
});

test('manifest validation rejects malformed roots, shapes, paths, arguments, and profiles', () => {
  const root = temporaryRoot();
  try {
    const good = writeSuite(root, 'good', 'process.exit(0);\n');
    const rootFile = path.join(root, 'not-a-directory');
    fs.writeFileSync(rootFile, 'x');
    assert.throws(
      () => validateManifest(manifestFor(process.platform, [suite('one', good)]), rootFile),
      /root must be a directory/,
    );
    assert.throws(() => validateManifest(null, root), /manifest must be an object/);
    assert.throws(
      () => validateManifest({ schemaVersion: 2, profiles: {} }, root),
      /schemaVersion/,
    );
    assert.throws(
      () => validateManifest({ schemaVersion: 1, profiles: {} }, root),
      /must not be empty/,
    );
    assert.throws(
      () => validateManifest({
        schemaVersion: 1,
        profiles: {
          BAD_PROFILE: { platform: process.platform, suites: [suite('one', good)] },
        },
      }, root),
      /invalid profile id/,
    );
    assert.throws(
      () => validateManifest(manifestFor('plan9', [suite('one', good)]), root),
      /platform is unsupported/,
    );
    assert.throws(
      () => validateManifest(
        manifestFor(process.platform, [suite('one', good)]),
        root,
        { requiredPlatform: process.platform === 'win32' ? 'linux' : 'win32' },
      ),
      /platform must be/,
    );
    assert.throws(
      () => validateManifest(manifestFor(process.platform, []), root),
      /non-empty array/,
    );
    assert.throws(
      () => validateManifest(
        manifestFor(process.platform, [suite('bad-runner', good, { runner: 'python' })]),
        root,
      ),
      /runner must be bash or node/,
    );
    assert.throws(
      () => validateManifest(
        manifestFor(process.platform, [suite('bad-args', good, { args: null })]),
        root,
      ),
      /args must be an array/,
    );
    for (const invalidArgument of [
      null,
      'x'.repeat(4097),
      'line\nbreak',
      '--live',
      '--live=true',
      '--require=/tmp/hostile.js',
      '--import',
      '--eval=code',
      '-r',
    ]) {
      assert.throws(
        () => validateManifest(
          manifestFor(process.platform, [
            suite('bad-argument', good, { args: [invalidArgument] }),
          ]),
          root,
        ),
        /bounded single-line string|live\/API|interpreter preload/,
      );
    }
    for (const invalidPath of ['', 'suites\\good.js', '/absolute.js', 'suites//good.js']) {
      assert.throws(
        () => validateManifest(
          manifestFor(process.platform, [suite('bad-path', invalidPath)]),
          root,
        ),
        /path must|path traversal/,
      );
    }
    assert.throws(
      () => validateManifest(
        manifestFor(process.platform, [suite('missing', 'suites/missing.js')]),
        root,
      ),
      /path does not exist/,
    );
    assert.throws(
      () => validateManifest(
        manifestFor(process.platform, [suite('directory', 'suites')]),
        root,
      ),
      /regular file/,
    );
    assert.throws(
      () => validateManifest(
        manifestFor(process.platform, [suite('duplicate', good), suite('duplicate', good, {
          args: ['distinct'],
        })]),
        root,
      ),
      /duplicate suite id/,
    );
  } finally {
    removeTemporaryRoot(root);
  }
});

test('manifest loader reports missing and malformed repository-owned JSON', () => {
  const root = temporaryRoot();
  try {
    assert.throws(() => loadAndValidateManifest(root), /path does not exist|failed to read/);
    const good = writeSuite(root, 'good', 'process.exit(0);\n');
    writeCatalog(root, [suite('one', good)]);
    const manifestPath = path.join(root, 'tests', 'profiles', 'windows-ci.v1.json');
    fs.mkdirSync(path.dirname(manifestPath), { recursive: true });
    fs.writeFileSync(manifestPath, '{not-json');
    assert.throws(() => loadAndValidateManifest(root), /invalid JSON/);
  } finally {
    removeTemporaryRoot(root);
  }
});

test('repository loader requires an exact audited command catalog', () => {
  const root = temporaryRoot();
  try {
    const good = writeSuite(root, 'good', 'process.exit(0);\n');
    const extra = writeSuite(root, 'extra', 'process.exit(0);\n');
    const manifestPath = path.join(root, 'tests', 'profiles', 'windows-ci.v1.json');
    fs.mkdirSync(path.dirname(manifestPath), { recursive: true });
    const command = suite('one', good);
    fs.writeFileSync(manifestPath, `${JSON.stringify(manifestFor('win32', [command]))}\n`);
    writeCatalog(root, [command, suite('extra', extra)]);
    assert.throws(() => loadAndValidateManifest(root), /unassigned commands/);

    writeCatalog(root, [suite('extra', extra)]);
    assert.throws(() => loadAndValidateManifest(root), /absent from the audited catalog/);
  } finally {
    removeTemporaryRoot(root);
  }
});

test('suite content and component identity are revalidated immediately before spawn', async () => {
  const root = temporaryRoot();
  try {
    const marker = path.join(root, 'marker');
    const relative = writeSuite(
      root,
      'drift',
      `require('node:fs').writeFileSync(${JSON.stringify(marker)}, 'old');\n`,
    );
    const validated = validateManifest(
      manifestFor(process.platform, [suite('drift', relative)]),
      root,
    );
    fs.writeFileSync(
      path.join(root, relative),
      `require('node:fs').writeFileSync(${JSON.stringify(marker)}, 'new');\n`,
    );
    await assert.rejects(
      runProfile({
        manifest: validated,
        profileId: 'test-profile',
        root,
        reportDirectory: path.join(root, 'reports'),
        output: { write() { return true; } },
      }),
      /identity or content drifted/,
    );
    assert.equal(fs.existsSync(marker), false);
  } finally {
    removeTemporaryRoot(root);
  }
});

test('atomic reports clean their private temporary file when publication fails', () => {
  const root = temporaryRoot();
  try {
    const destination = path.join(root, 'reports', 'blocked.json');
    fs.mkdirSync(destination, { recursive: true });
    assert.throws(() => atomicWriteJson(destination, { status: 'blocked' }));
    assert.deepEqual(
      fs.readdirSync(path.dirname(destination)).filter((name) => name.endsWith('.tmp')),
      [],
    );
  } finally {
    removeTemporaryRoot(root);
  }
});

test('bounded cleanup command reports success, spawn failure, and timeout', async () => {
  const success = await spawnAndWait(
    process.execPath,
    ['-e', 'process.exit(0)'],
    { stdio: 'ignore' },
    5000,
  );
  assert.equal(success.status, 0);
  assert.equal(success.error, null);

  const missing = await spawnAndWait(
    path.join(os.tmpdir(), `missing-command-${process.pid}`),
    [],
    { stdio: 'ignore' },
    5000,
  );
  assert.equal(missing.status, null);
  assert.equal(missing.error?.code, 'ENOENT');

  const timedOut = await spawnAndWait(
    process.execPath,
    ['-e', 'setInterval(() => {}, 1000)'],
    { stdio: 'ignore' },
    30,
  );
  assert.equal(timedOut.status, null);
  assert.match(timedOut.error?.message, /timed out/);
});

test('a won timeout race clears its long losing timer so the process exits promptly', () => {
  const result = spawnSync(process.execPath, ['-e', `
    const { raceWithTimeout } = require(${JSON.stringify(path.join(__dirname, '..', 'run-profile.js'))});
    raceWithTimeout(Promise.resolve('done'), 20000).then((value) => {
      if (value !== 'done') process.exitCode = 1;
    });
  `], {
    encoding: 'utf8',
    timeout: 2000,
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.error, undefined);
});

test('Windows tree cleanup validates SystemRoot and taskkill outcomes', {
  skip: process.platform === 'win32',
}, async () => {
  const root = temporaryRoot();
  try {
    await assert.rejects(
      terminateOwnedTree({ pid: null }, 'win32', {}),
      /has no pid/,
    );
    await assert.rejects(
      terminateOwnedTree({ pid: 123 }, 'win32', {
        SystemRoot: '',
        SYSTEMROOT: '',
      }),
      /SystemRoot is unavailable/,
    );
    const system32 = path.join(root, 'System32');
    const taskkill = path.join(system32, 'taskkill.exe');
    fs.mkdirSync(system32);
    fs.writeFileSync(taskkill, '#!/bin/bash\nexit 0\n', { mode: 0o700 });
    assert.deepEqual(
      await terminateOwnedTree({ pid: 123 }, 'win32', { SystemRoot: root }),
      { status: 'terminated', mechanism: 'windows-job-object-taskkill-tree' },
    );
    fs.writeFileSync(taskkill, '#!/bin/bash\nexit 7\n', { mode: 0o700 });
    await assert.rejects(
      terminateOwnedTree({ pid: 123 }, 'win32', { SystemRoot: root }),
      /taskkill failed with exit 7/,
    );
  } finally {
    removeTemporaryRoot(root);
  }
});

test('POSIX cleanup handles already-exited and TERM-resistant process groups', {
  skip: process.platform === 'win32',
}, async () => {
  assert.deepEqual(
    await terminateOwnedTree({ pid: 99999999 }, process.platform, process.env),
    { status: 'terminated', mechanism: 'already-exited' },
  );

  const child = spawn(
    process.execPath,
    ['-e', 'process.on("SIGTERM", () => {}); process.stdout.write("ready\\n"); setInterval(() => {}, 1000)'],
    { detached: true, stdio: ['ignore', 'pipe', 'ignore'] },
  );
  try {
    await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.stdout.once('data', resolve);
    });
    assert.deepEqual(
      await terminateOwnedTree(child, process.platform, process.env),
      { status: 'terminated', mechanism: 'process-group-kill' },
    );
  } finally {
    try { process.kill(-child.pid, 'SIGKILL'); } catch (_error) {}
  }
});

test('profile runner covers bash heartbeats, spawn errors, and selection errors', async () => {
  const root = temporaryRoot();
  try {
    const bash = writeBashSuite(root, 'heartbeat', '#!/bin/bash\nsleep 0.08\nexit 0\n');
    const output = [];
    const success = await runProfile({
      manifest: manifestFor(process.platform, [
        suite('bash-heartbeat', bash, { runner: 'bash' }),
      ]),
      profileId: 'test-profile',
      root,
      reportDirectory: path.join(root, 'heartbeat-reports'),
      output: { write(value) { output.push(String(value)); } },
      heartbeatMs: 10,
    });
    assert.equal(success.exitCode, 0);
    assert.match(output.join(''), /HEARTBEAT bash-heartbeat/);

    await assert.rejects(
      runProfile({
        manifest: manifestFor(process.platform, [
          suite('missing-bash', bash, { runner: 'bash' }),
        ]),
        profileId: 'test-profile',
        root,
        reportDirectory: path.join(root, 'spawn-reports'),
        environment: { ...process.env, PATH: '' },
        output: { write() { return true; } },
      }),
      /PATH is unavailable|trusted bash executable was not found/,
    );

    await assert.rejects(
      runProfile({
        manifest: manifestFor(process.platform, [suite('one', bash, { runner: 'bash' })]),
        profileId: 'missing-profile',
        root,
      }),
      /unknown profile/,
    );
    const otherPlatform = process.platform === 'win32' ? 'linux' : 'win32';
    await assert.rejects(
      runProfile({
        manifest: manifestFor(otherPlatform, [suite('one', bash, { runner: 'bash' })]),
        profileId: 'test-profile',
        root,
        platform: process.platform,
      }),
      /requires .* current platform/,
    );
  } finally {
    removeTemporaryRoot(root);
  }
});

test('cleanup failures abort the remaining profile and persist diagnostics', async () => {
  const root = temporaryRoot();
  try {
    const hangs = writeSuite(root, 'hangs', 'setInterval(() => {}, 1000);\n');
    const marker = path.join(root, 'should-not-run');
    const next = writeSuite(
      root,
      'next',
      `require('node:fs').writeFileSync(${JSON.stringify(marker)}, 'ran');\n`,
    );
    const result = await runProfile({
      manifest: manifestFor(process.platform, [
        suite('hangs', hangs, { timeoutMs: 40 }),
        suite('next', next),
      ]),
      profileId: 'test-profile',
      root,
      reportDirectory: path.join(root, 'reports'),
      output: { write() {} },
      async terminateProcessTree() {
        // Leave the tree intact so this case deterministically exercises the
        // runner-owned fallback. Partial/late cleanup has a separate contract.
        throw new Error('synthetic cleanup failure');
      },
    });
    assert.equal(result.exitCode, EXIT_SUITE);
    assert.equal(result.report.suites.length, 1);
    assert.equal(result.report.suites[0].cleanup.status, 'failed_recovered');
    assert.match(result.report.suites[0].cleanup.error, /synthetic cleanup failure/);
    assert.equal(fs.existsSync(marker), false);
  } finally {
    removeTemporaryRoot(root);
  }
});

test('a cleanup that does not close the suite is reported fail-closed', async () => {
  const root = temporaryRoot();
  try {
    const hangs = writeSuite(root, 'late-close', 'setInterval(() => {}, 1000);\n');
    const result = await runProfile({
      manifest: manifestFor(process.platform, [
        suite('late-close', hangs, { timeoutMs: 40 }),
      ]),
      profileId: 'test-profile',
      root,
      reportDirectory: path.join(root, 'reports'),
      output: { write() {} },
      cleanupCloseTimeoutMs: 5,
      async terminateProcessTree(child) {
        setTimeout(() => child.kill('SIGKILL'), 50);
        return { status: 'terminated', mechanism: 'synthetic' };
      },
    });
    assert.equal(result.exitCode, EXIT_SUITE);
    assert.equal(result.report.suites[0].cleanup.status, 'failed_recovered');
    assert.match(result.report.suites[0].cleanup.error, /required cleanup recovery/);
    await new Promise((resolve) => setTimeout(resolve, 80));
  } finally {
    removeTemporaryRoot(root);
  }
});

test('signal cancellation writes a report and removes installed handlers', async () => {
  const root = temporaryRoot();
  try {
    const hangs = writeSuite(root, 'cancel', 'setInterval(() => {}, 1000);\n');
    const signals = new EventEmitter();
    const pending = runProfile({
      manifest: manifestFor(process.platform, [
        suite('cancel', hangs),
      ]),
      profileId: 'test-profile',
      root,
      reportDirectory: path.join(root, 'reports'),
      output: { write() {} },
      installSignalHandlers: true,
      signalEmitter: signals,
      async terminateProcessTree(child) {
        child.kill('SIGKILL');
        throw new Error('synthetic signal cleanup failure');
      },
    });
    setTimeout(() => {
      signals.emit('SIGINT');
      signals.emit('SIGINT');
    }, 50);
    const result = await pending;
    assert.equal(result.exitCode, 130);
    assert.equal(result.report.status, 'cancelled');
    assert.match(result.report.cleanupError, /synthetic signal cleanup failure/);
    assert.equal(signals.listenerCount('SIGINT'), 0);
    assert.equal(signals.listenerCount('SIGTERM'), 0);
  } finally {
    removeTemporaryRoot(root);
  }
});

test('injectable CLI validates usage and executes an exact Windows profile', async () => {
  const root = temporaryRoot();
  try {
    const good = writeSuite(root, 'good', 'process.exit(0);\n');
    const manifestPath = path.join(root, 'tests', 'profiles', 'windows-ci.v1.json');
    fs.mkdirSync(path.dirname(manifestPath), { recursive: true });
    const command = suite('one', good);
    fs.writeFileSync(
      manifestPath,
      `${JSON.stringify(manifestFor('win32', [command]))}\n`,
    );
    writeCatalog(root, [command]);
    const stdout = [];
    const stderr = [];
    const streams = {
      stdout: { write(value) { stdout.push(String(value)); } },
      stderr: { write(value) { stderr.push(String(value)); } },
    };
    assert.equal(await main({
      root,
      argv: ['--validate'],
      ...streams,
      installSignalHandlers: false,
    }), 0);
    assert.match(stdout.join(''), /manifest: PASS/);

    assert.equal(await main({
      root,
      argv: [],
      ...streams,
      installSignalHandlers: false,
    }), EXIT_MANIFEST);
    assert.match(stderr.join(''), /usage:/);

    assert.equal(await main({
      root,
      argv: ['test-profile'],
      ...streams,
      platform: 'win32',
      sourceGitRevision: 'a'.repeat(40),
      installSignalHandlers: false,
      async terminateProcessTree(child) {
        child.kill('SIGKILL');
        return { status: 'terminated', mechanism: 'synthetic-windows-tree' };
      },
    }), 0);
    assert.equal(await main({
      root,
      argv: ['missing-profile'],
      ...streams,
      platform: 'win32',
      sourceGitRevision: 'a'.repeat(40),
      installSignalHandlers: false,
    }), EXIT_MANIFEST);
    assert.match(stderr.join(''), /unknown profile/);
  } finally {
    removeTemporaryRoot(root);
  }
});
