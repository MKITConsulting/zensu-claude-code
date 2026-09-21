#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const hookSession = require('./claude-hook-session-v1.js');
const leases = require('./review-evidence-lease-v1.js');

const MAX_PAYLOAD_BYTES = 1024 * 1024;

function fail(message) {
  throw new Error(`review-evidence-hook-v1: ${message}`);
}

function readPayload(expectedEvent) {
  const raw = fs.readFileSync(0);
  if (raw.length === 0 || raw.length > MAX_PAYLOAD_BYTES) fail('hook payload is empty or too large');
  let payload;
  try { payload = JSON.parse(raw.toString('utf8')); } catch { fail('hook payload is invalid JSON'); }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) fail('hook payload must be an object');
  if (payload.hook_event_name !== expectedEvent) fail(`expected ${expectedEvent}`);
  return payload;
}

// Binds with the automatic adoption opted in, and DISCLOSES an adoption this
// process performed. This hook binds IN PROCESS, never through the CLI binder, so
// the binder's one operator line was never written for it: an adoption landing
// here re-minted the record, kept a superseded copy and swept the lease store
// without a line anywhere — and on SubagentStop no sibling adapter exists to speak
// for it. Both halves are covered: a bind that returns carries the verdict on
// `binding.adoption`, and a bind whose strict re-read then throws carries it on the
// error, exactly as the CLI mode reads it.
function bindAndDisclose(payload) {
  let binding;
  try {
    binding = hookSession.resolveHookSession(payload, process.env, { autoAdopt: true });
  } catch (error) {
    const performed = hookSession.performedAdoption(error);
    if (performed) hookSession.writeAdoptionOperatorLine(performed);
    throw error;
  }
  if (binding.adoption) hookSession.writeAdoptionOperatorLine(binding.adoption);
  return binding;
}

function start() {
  const payload = readPayload('SubagentStart');
  const kind = leases.kindForAgentType(payload.agent_type);
  if (!kind) return;
  // Opts into the automatic adoption: this hook runs on the same SubagentStart
  // matcher as the session-control adapter and in parallel with it, so without
  // adopting here it could bind-fail in the adoption window, mint no lease, and
  // leave the reviewer denied for the whole review. The records lock serializes
  // the two; the loser sees already-served and re-reads.
  const binding = bindAndDisclose(payload);
  leases.bindWorker(payload, binding);
  process.stdout.write(`${JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'SubagentStart',
      additionalContext: `evidence-worker-v1 bound: kind=${kind}. Read only exact leased files; Grep/Glob only exact leased traversal roots; return one raw schema-valid JSON object. No private lease or session selector is exposed.`,
    },
  })}\n`);
}

function stop() {
  const payload = readPayload('SubagentStop');
  if (!leases.kindForAgentType(payload.agent_type)) return;
  // Opts into the automatic adoption: this hook runs on the same SubagentStart
  // matcher as the session-control adapter and in parallel with it, so without
  // adopting here it could bind-fail in the adoption window, mint no lease, and
  // leave the reviewer denied for the whole review. The records lock serializes
  // the two; the loser sees already-served and re-reads.
  const binding = bindAndDisclose(payload);
  const outcome = leases.storeWorkerResult(payload, binding);
  if (outcome.action === 'block') {
    process.stdout.write(`${JSON.stringify({
      decision: 'block',
      reason: `Your evidence-worker result was rejected: ${outcome.reason}. Reply once more with exactly one raw schema-valid JSON object for the assigned kind and role; no Markdown fence, preface, or suffix.`,
    })}\n`);
  }
}

function main() {
  const mode = process.argv[2];
  if (process.argv.length !== 3 || !['start', 'stop'].includes(mode)) fail('expected start or stop');
  if (mode === 'start') start();
  else stop();
}

try { main(); } catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
}
