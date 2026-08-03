#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const {
  buildBubblewrapInvocation,
} = require('../lib/upgrade-linux-sandbox.js');
const {
  runProcessTreeBounded,
} = require('../lib/upgrade-process.js');

async function main() {
  if (process.platform !== 'linux') {
    throw new Error('Linux sandbox runtime smoke requires Linux');
  }
  const root = fs.realpathSync.native(fs.mkdtempSync('/tmp/zensu-sandbox-smoke-'));
  try {
    fs.chmodSync(root, 0o700);
    const project = path.join(root, 'project');
    fs.mkdirSync(project, { mode: 0o700 });
    const invocation = buildBubblewrapInvocation({
      command: fs.realpathSync.native('/usr/bin/getent'),
      args: ['hosts', 'localhost'],
      cwd: project,
      disposableRoot: root,
      writableRoots: [root],
      environment: {
        PATH: '/usr/bin:/bin',
        HOME: root,
        TMPDIR: '/tmp',
        TEMP: '/tmp',
        TMP: '/tmp',
      },
      shareNetwork: true,
    });
    const result = await runProcessTreeBounded(
      invocation.command,
      invocation.args,
      {
        cwd: project,
        encoding: 'utf8',
        env: invocation.env,
      },
      {
        label: 'Linux sandbox resolver runtime smoke',
        timeoutMs: 30000,
        maxBuffer: 1024 * 1024,
        trustedEvaluatorCommand: true,
        argumentInput: invocation.argumentInput,
      },
    );
    if (result.status !== 0 || result.signal
        || !/(^|\s)localhost(\s|$)/m.test(String(result.stdout || ''))) {
      throw new Error('production Linux sandbox cannot resolve localhost');
    }
    process.stdout.write(
      'linux-sandbox-runtime-smoke.js: PASS (production builder + resolver runtime)\n',
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
