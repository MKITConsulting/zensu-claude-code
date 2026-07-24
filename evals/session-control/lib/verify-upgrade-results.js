#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { EXECUTION_MODES, parse } = require('./upgrade-attestation.js');

function fail(message) {
  process.stderr.write(`session-control upgrade result verification: ${message}\n`);
  process.exit(1);
}

function publish(fileInput, value) {
  const requested = path.resolve(fileInput);
  const parentInput = path.dirname(requested);
  const parentStat = fs.lstatSync(parentInput);
  if (!parentStat.isDirectory() || parentStat.isSymbolicLink()) {
    fail('evidence parent must be a real directory');
  }
  const parent = fs.realpathSync.native(parentInput);
  const file = path.join(parent, path.basename(requested));
  if (fs.existsSync(file)) fail('evidence output already exists');
  const temporary = path.join(parent, `.${path.basename(file)}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.tmp`);
  let descriptor;
  let publicationError;
  try {
    descriptor = fs.openSync(temporary, 'wx', 0o600);
    fs.writeFileSync(descriptor, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    fs.linkSync(temporary, file);
    fs.unlinkSync(temporary);
    if (process.platform !== 'win32') fs.chmodSync(file, 0o400);
  } catch (error) {
    publicationError = error;
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    try { fs.unlinkSync(temporary); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  if (publicationError) fail('cannot publish sanitized upgrade evidence');
}

const [resultFile, revision, evidenceFile] = process.argv.slice(2);
if (!resultFile || !/^[a-f0-9]{40,64}$/.test(revision || '')) {
  fail('usage: verify-upgrade-results.js RESULT.json REVISION [EVIDENCE.json]');
}
let payload;
try { payload = JSON.parse(fs.readFileSync(resultFile, 'utf8')); }
catch (_error) { fail('Promptfoo result payload is invalid JSON'); }
const rows = payload?.results?.results;
if (!Array.isArray(rows) || rows.length !== 1) fail('upgrade profile must contain exactly one result row');
const row = rows[0];
if (row?.success !== true || row?.vars?.scenario_id !== 'upgrade-v0161-side-by-side') {
  fail('Promptfoo upgrade row failed or has the wrong scenario identity');
}
let attestation;
try { attestation = parse(row?.response?.output); }
catch (error) { fail(error.message); }
if (attestation.source_git_revision !== revision) fail('upgrade evidence is bound to the wrong source revision');

if (evidenceFile) {
  if (attestation.execution_mode !== EXECUTION_MODES.authoritative) {
    fail('only split authenticated-canary and contained-candidate runs may publish upgrade evidence');
  }
  const receipt = {
    schema: 'zensu.session-control-upgrade-suite-evidence',
    schema_version: 2,
    host: 'claude',
    mode: 'upgrade',
    gate: 'passed',
    execution_mode: attestation.execution_mode,
    authenticated_canary_status: attestation.authenticated_canary_status,
    candidate_model_backend: attestation.candidate_model_backend,
    candidate_containment: attestation.candidate_containment,
    source_git_revision: revision,
    old_release_ref: attestation.old_release_ref,
    old_release_revision: attestation.old_release_revision,
    old_version: attestation.old_version,
    candidate_installed_version: attestation.candidate_installed_version,
    candidate_version_synthetic: attestation.candidate_version_synthetic,
    old_runtime_digest: attestation.old_runtime_digest,
    candidate_runtime_digest: attestation.candidate_runtime_digest,
    lifecycle_evidence_count: attestation.hook_sequence.length,
    promptfoo_version: '0.121.18',
    claude_code_version: attestation.claude_code_version,
  };
  const canonical = JSON.stringify(receipt);
  publish(evidenceFile, {
    ...receipt,
    evidence_digest: `sha256:${crypto.createHash('sha256').update(canonical).digest('hex')}`,
  });
}
const suffix = attestation.execution_mode === EXECUTION_MODES.authoritative
  ? 'authoritative'
  : `NON-AUTHORITATIVE ${attestation.execution_mode}`;
process.stdout.write(`session-control upgrade result verification: PASS (1 row; ${suffix})\n`);
