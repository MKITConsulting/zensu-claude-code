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

function start() {
  const payload = readPayload('SubagentStart');
  const kind = leases.kindForAgentType(payload.agent_type);
  if (!kind) return;
  const binding = hookSession.resolveHookSession(payload);
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
  const binding = hookSession.resolveHookSession(payload);
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
