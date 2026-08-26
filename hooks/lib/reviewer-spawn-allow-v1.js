#!/usr/bin/env node
// reviewer-spawn-allow-v1.js — decides whether a PreToolUse Agent/Task spawn is
// one of Zensu's own capability-confined reviewers, and therefore may be granted
// without consulting the host permission layer.
//
// WHY THIS EXISTS. The Claude Code auto-mode classifier refuses `zensu:code-reviewer`
// spawns intermittently. A refused spawn never executes, so no PreToolUse or
// PostToolUse hook observes it, and the Stop chain-enforcer repeats an impossible
// instruction until its cap releases the guard. `reviewer-spawn-denial-v1.js` is the
// reactive half — it DIAGNOSES a refusal after the fact. This module is the
// preventive half.
//
// HOW IT WORKS, and the provenance of that claim. A local PreToolUse hook returning
// `permissionDecision: "allow"` short-circuits the permission pipeline BEFORE the
// classifier is consulted. Measured against Claude Code build (2.1.245) with two
// headless `--permission-mode auto` runs of one prompt in an isolated directory,
// the build recorded below as ALLOW_BYPASS_SOURCE_BUILD and cross-checked against
// this header by the structure suite: without the hook the debug log records
// `classifier_request_started ... tool=Agent`; with the hook there is no classifier
// request for `tool=Agent` at all, only `Hook result has permissionBehavior=allow`
// followed by `Hook approved tool use for Agent, bypassing permission prompt`.
// Re-verify against the binary, never against memory — a host that reorders its
// pipeline silently turns this module back into a no-op, which is the fail-open
// direction but leaves the wedge it exists to remove.
//
// THREE HOST LIMITS, all read out of the same build. They are not defects here and
// must not be "fixed" by widening the grant:
//   1. A `permissions.deny` or `permissions.ask` rule still OVERRIDES a hook allow.
//      This is why the proactive deny/ask rows in zensu-doctor-report.js stay.
//   2. Any other hook on the same matcher returning deny/ask wins — the host ranks
//      deny > ask > allow across all hooks on a matcher.
//   3. An SDK session that supplies `canUseTool` (`requireCanUseTool`) forces the
//      full pipeline and the grant is ignored. Headless `-p` does NOT set it.
//
// WHY MEMBERSHIP IS THE BOUND, and not an armed chain. Every granted agent carries
// `tools: Read, Grep, Glob` in its frontmatter and is classified by
// claude-principal-v1.js as a confined principal — REVIEWER or EVIDENCE_WORKER,
// never HOST. Granting the SPAWN grants the child nothing: the child's own tool
// calls are permission-checked separately. An armed-chain condition was specified
// and then rejected on discovery — `plan-review-worker` and `pr-review-worker` are
// spawned by `/zensu:plan-review` and `/zensu:pr-team-review`, neither of which arms
// a TDD chain or calls `--workflow-begin`, so that condition would have shipped a
// grant missing two of the five. `zensu:zensu-plm` is EXCLUDED for the STRUCTURAL
// reason and that one only: `PLM_TYPES` is a separate classification returning
// `PRINCIPALS.HOST`, and it is never fed to `pluginScoped` below. Do NOT restate this
// as "it declares no `tools:` line" — `agents/zensu-plm.md` DOES declare
// `tools: Read, Grep, Glob`, so that reason is false, checkable, and its natural
// repair is to widen the set.
//
// THE SET IS DERIVED, NEVER SPELLED. It is claude-principal-v1.js's own
// REVIEWER_TYPES plus EVIDENCE_WORKER_TYPES — the same classifier the SubagentStart
// hook uses to inject `reviewer-readonly-v1` — so adding a confined agent there
// reaches this grant with no edit here, and CLAUDE.md's standing instruction to grep
// before renaming `zensu:code-reviewer` keeps holding.
//
// ONE NARROWING IS DELIBERATE: only the PLUGIN-SCOPED `zensu:` spellings are
// granted. REVIEWER_TYPES also carries the bare names (`code-reviewer`, …) so that
// `--agents` fixtures and same-named PROJECT agents still receive the read-only
// principal. Those are not our files: a project may define its own `code-reviewer`
// with `tools: Bash`, and the principal classification is prompt-level policy while
// `tools:` frontmatter is what the harness actually enforces. Granting a bare name
// would hand a project-authored agent a classifier-free spawn.
//
// THE PREMISE UNDER THAT NARROWING IS UNVERIFIED, and saying so is the point. It
// assumes the host reserves the `zensu:` scope to the plugin — that a project-authored
// agent can never present to this hook as `zensu:code-reviewer`. Unlike the bypass
// itself, which is measured against ALLOW_BYPASS_SOURCE_BUILD and pinned, nothing in
// this tree measures the scope reservation. If it does not hold, a project agent
// claiming the scoped name receives a classifier-free spawn with whatever `tools:` it
// declares — the one axis this design has no defense for. Measuring it the way the
// bypass was measured, and pinning the result here, is the standing fix.
//
// WHAT THE GRANT ACTUALLY COVERS is the whole tool CALL, not only the identity. Only
// `tool_name` and `tool_input.subagent_type` are examined; every other input field
// travels unexamined, including `prompt` and `isolation: "worktree"` — and that last
// one is a host-performed filesystem action caused by the spawn itself, so it sits
// OUTSIDE the `Read`/`Grep`/`Glob` confinement the frontmatter provides. Read the
// confinement claim as bounding what the CHILD may do, never as bounding the call.
//
// SPAWN_TOOL_NAMES is imported from the denial module and re-encoded a THIRD time as
// the `Agent|Task` matcher in hooks/hooks.json. A member added there without widening
// the matcher leaves the grant inert for that tool with every check green.
//
// This module NEVER denies. Every path that is not a grant returns a verdict whose
// rendering is the empty string, so the host sees a silent hook.

'use strict';

var denial = require('./reviewer-spawn-denial-v1.js');
var principal = require('./claude-principal-v1.js');

var ALLOW_BYPASS_SOURCE_BUILD = '2.1.245';

var PLUGIN_SCOPE = 'zensu:';

function pluginScoped(sets) {
  var out = [];
  sets.forEach(function (set) {
    Array.from(set).forEach(function (name) {
      if (typeof name !== 'string') return;
      if (name.indexOf(PLUGIN_SCOPE) !== 0) return;
      if (out.indexOf(name) === -1) out.push(name);
    });
  });
  return out.sort();
}

var CONFINED_REVIEWER_AGENTS = Object.freeze(pluginScoped([
  principal.REVIEWER_TYPES,
  principal.EVIDENCE_WORKER_TYPES,
]));

var SPAWN_TOOL_NAMES = denial.SPAWN_TOOL_NAMES;

var MAX_PAYLOAD_BYTES = 4 * 1024 * 1024;

var REFUSALS = Object.freeze({
  UNREADABLE: 'unreadable-payload',
  NOT_A_SPAWN: 'not-a-spawn-tool',
  NOT_CONFINED: 'not-a-confined-reviewer',
});

function isConfinedReviewer(subagentType) {
  return typeof subagentType === 'string'
    && CONFINED_REVIEWER_AGENTS.indexOf(subagentType) !== -1;
}

function allowVerdict(payload) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    return { allow: false, reason: REFUSALS.UNREADABLE, subagentType: '' };
  }
  if (SPAWN_TOOL_NAMES.indexOf(payload.tool_name) === -1) {
    return { allow: false, reason: REFUSALS.NOT_A_SPAWN, subagentType: '' };
  }
  var input = payload.tool_input;
  var subagentType = input && typeof input === 'object' && !Array.isArray(input)
    ? input.subagent_type
    : undefined;
  if (!isConfinedReviewer(subagentType)) {
    return {
      allow: false,
      reason: REFUSALS.NOT_CONFINED,
      subagentType: typeof subagentType === 'string' ? subagentType : '',
    };
  }
  return { allow: true, reason: '', subagentType: subagentType };
}

function decisionReason(subagentType) {
  return 'Zensu grants its own read-only reviewer spawn ' + subagentType
    + ' (Read/Grep/Glob only). Disable with hooks.reviewerSpawnAutoAllow=false'
    + ' in ~/.zensu/config.json.';
}

function renderDecision(verdict) {
  if (!verdict || verdict.allow !== true) return '';
  return JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'allow',
      permissionDecisionReason: decisionReason(verdict.subagentType),
    },
  }) + '\n';
}

function parsePayload(raw) {
  if (typeof raw !== 'string' || raw.length === 0) return null;
  if (Buffer.byteLength(raw, 'utf8') > MAX_PAYLOAD_BYTES) return null;
  try {
    return JSON.parse(raw);
  } catch (_) {
    return null;
  }
}

function decide(raw) {
  return renderDecision(allowVerdict(parsePayload(raw)));
}

function main() {
  var chunks = [];
  var size = 0;
  process.stdin.on('data', function (c) {
    size += c.length;
    if (size <= MAX_PAYLOAD_BYTES) chunks.push(c);
  });
  process.stdin.on('end', function () {
    if (size > MAX_PAYLOAD_BYTES) return;
    process.stdout.write(decide(Buffer.concat(chunks).toString('utf8')));
  });
  process.stdin.on('error', function () {});
}

module.exports = {
  ALLOW_BYPASS_SOURCE_BUILD: ALLOW_BYPASS_SOURCE_BUILD,
  PLUGIN_SCOPE: PLUGIN_SCOPE,
  CONFINED_REVIEWER_AGENTS: CONFINED_REVIEWER_AGENTS,
  SPAWN_TOOL_NAMES: SPAWN_TOOL_NAMES,
  MAX_PAYLOAD_BYTES: MAX_PAYLOAD_BYTES,
  REFUSALS: REFUSALS,
  isConfinedReviewer: isConfinedReviewer,
  allowVerdict: allowVerdict,
  renderDecision: renderDecision,
  decide: decide,
  main: main,
};

if (require.main === module) {
  main();
}
