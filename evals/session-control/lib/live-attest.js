#!/usr/bin/env node
'use strict';

const core = require('../../../hooks/lib/session-control-core-v1.js');

function fail(message) {
  throw new Error(`session-control live attestation: ${message}`);
}

function parse(args) {
  const values = {};
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index];
    const value = args[index + 1];
    if (!key?.startsWith('--') || value === undefined) fail('invalid arguments');
    values[key.slice(2)] = value;
  }
  return values;
}

function json(value, label) {
  try { return JSON.parse(value); }
  catch (_error) { fail(`${label} is invalid JSON`); }
}

function main() {
  const options = parse(process.argv.slice(2));
  const context = core.readContext({
    recordsDir: options['records-dir'],
    sessionId: options['session-id'],
    expectedHost: 'claude',
  });
  const state = core.readWorkflowState({
    projectRoot: options['project-root'],
    sessionId: options['session-id'],
  });
  const value = core.createAttestation({
    context,
    state,
    hookSequence: json(options['hook-sequence-json'], 'hook sequence'),
    reviewerCapabilities: options['reviewer-capabilities'],
    changedFileHashes: json(options['changed-file-hashes-json'], 'changed-file hashes'),
    cliVersion: options['cli-version'],
    pluginVersion: options['plugin-version'],
    exitCode: Number(options['exit-code']),
  });
  process.stdout.write(JSON.stringify(value));
}

try { main(); }
catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
}
