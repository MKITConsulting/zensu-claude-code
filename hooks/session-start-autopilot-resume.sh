#!/bin/bash
# SessionStart hook -- restore model context for an already-active durable
# Autopilot run. This hook is deliberately read-only: it never claims a run,
# changes ownership, advances a stage, or records an event.
set -u

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 2
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _ZENSU_DECLARED_PLUGIN_ROOT="$(cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" || {
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  }
  if [ "$_ZENSU_DECLARED_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  fi
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT _ZENSU_DECLARED_PLUGIN_ROOT

INPUT=""
IFS= read -r -d '' INPUT || true

emit_runtime_unavailable() {
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"ZENSU_AUTOPILOT_RESUME RUNTIME_UNAVAILABLE. A project-local durable Autopilot state artifact exists, but the state runtime is unavailable. Do not infer progress, resume effects, or create a replacement run; repair the plugin runtime first."}}'
}

emit_corrupt_active_state() {
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"ZENSU_AUTOPILOT_RESUME CORRUPT_ACTIVE_STATE. The project-local Autopilot pointer and run inventory did not validate as one unambiguous active state. Do not infer progress, resume effects, or create a replacement run. Inspect and repair or explicitly cancel the durable state first."}}'
}

NODE_AVAILABLE=true
command -v node >/dev/null 2>&1 || NODE_AVAILABLE=false
AGENT_CONTEXT_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-agent-context.sh"

json_field() {
  printf '%s' "$INPUT" | FIELD="$1" node -e '
    try {
      const value = JSON.parse(require("fs").readFileSync(0, "utf8") || "{}")[process.env.FIELD];
      process.stdout.write(typeof value === "string" ? value : "");
    } catch (_) { process.stdout.write(""); }
  ' 2>/dev/null
}

# Only a trusted top-level SessionStart principal may inherit outer-run context.
# Keep this no-op ahead of runtime enforcement so a missing Node binary cannot
# deadlock a child.
[ "$NODE_AVAILABLE" = "true" ] && [ -r "$AGENT_CONTEXT_LIB" ] || exit 0
# shellcheck disable=SC1090
source "$AGENT_CONTEXT_LIB"
zensu_hook_is_main_principal "$INPUT" SessionStart || exit 0

# Without Node this sibling cannot authenticate the lifecycle source or a
# private session record. Stay silent before inspecting any project path.
[ "$NODE_AVAILABLE" = "true" ] || exit 0

# A malformed payload cannot prove that this is a top-level SessionStart event.
if ! printf '%s' "$INPUT" | node -e '
  try {
    const value = JSON.parse(require("fs").readFileSync(0, "utf8") || "{}");
    process.exit(value && typeof value === "object" && !Array.isArray(value)
      && value.hook_event_name === "SessionStart" ? 0 : 1);
  } catch (_) { process.exit(1); }
' 2>/dev/null; then
  exit 0
fi

read_field() {
  json_field "$1"
}

# SessionStart supplies exactly one of these four lifecycle sources. Ambiguous
# or future values stay silent until their security semantics are explicit.
SOURCE="$(read_field source)"
case "$SOURCE" in
  startup|resume|compact|clear) ;;
  *) exit 0 ;;
esac

SESSION_ID="$(read_field session_id)"
SESSION_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
AUTOPILOT_STATE_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh"
[ -r "$AGENT_CONTEXT_LIB" ] && [ -r "$SESSION_LIB" ] || exit 0
unset ZENSU_CLAUDE_PLUGIN_ROOT ZENSU_SESSION_KEY ZENSU_SESSION_CONTEXT \
  ZENSU_RUNTIME_DIGEST ZENSU_PROJECT_ROOT
source "$SESSION_LIB"

case "$SOURCE" in
  resume|compact)
    # Continuations already have a record created by their original fresh
    # SessionStart. CwdChanged may point anywhere; only the private record may
    # select the durable project. Missing or invalid records remain silent and
    # never trigger a payload-cwd probe.
    zensu_bind_hook_session "$INPUT" >/dev/null 2>&1 || exit 0
    PROJECT_ROOT="$(zensu_resolve_project_dir 2>/dev/null)" || exit 0
    ;;
  startup|clear)
    # Equal-match SessionStart hooks run concurrently. Prefer a valid existing
    # record on retries; while the first record is not yet present, use Claude's
    # stable project variable. The mutable payload cwd is never authoritative.
    BINDER="${CLAUDE_PLUGIN_ROOT}/hooks/lib/claude-hook-session-v1.js"
    PROJECT_ROOT="$(printf '%s' "$INPUT" | BINDER="$BINDER" node -e '
      const fs = require("node:fs");
      const binder = require(process.env.BINDER);
      const payload = JSON.parse(fs.readFileSync(0, "utf8"));
      process.stdout.write(binder.resolveFreshHookProject(payload));
    ' 2>/dev/null)" || exit 0
    ;;
esac
[ -n "$PROJECT_ROOT" ] || exit 0

ACTIVE_POINTER_HINT="$PROJECT_ROOT/.zensu/state/autopilot-active.json"
AUTOPILOT_STATE_HINT=false
if [ -e "$ACTIVE_POINTER_HINT" ] || [ -L "$ACTIVE_POINTER_HINT" ]; then
  AUTOPILOT_STATE_HINT=true
fi
for _zensu_autopilot_hint in "$PROJECT_ROOT/.zensu/state"/autopilot-run-*.json; do
  if [ -e "$_zensu_autopilot_hint" ] || [ -L "$_zensu_autopilot_hint" ]; then
    AUTOPILOT_STATE_HINT=true
    break
  fi
done
unset _zensu_autopilot_hint

if [ ! -r "$AUTOPILOT_STATE_LIB" ]; then
  [ "$AUTOPILOT_STATE_HINT" = "true" ] && emit_runtime_unavailable
  exit 0
fi

SESSION_ID="$(zensu_resolve_session_id "$SESSION_ID" 2>/dev/null)" || exit 0

# The state library owns path validation and the active-pointer/run-file
# consistency check. Keep this project-local even when the hook's cwd differs.
source "$AUTOPILOT_STATE_LIB"
ACTIVE_STATE=""
if ACTIVE_STATE="$(autopilot_read_active "$PROJECT_ROOT" 2>/dev/null)"; then
  READ_RC=0
else
  READ_RC=$?
fi

case "$READ_RC" in
  0) ;;
  1)
    # No nonterminal active run is normal and intentionally produces no output;
    # validated DONE/CANCELLED history without a pointer is compatible here.
    exit 0
    ;;
  *)
    # Durable pointer/run inventory is corrupt, unsafe, or ambiguous.
    # Emit only a closed, constant message; never reflect unvalidated bytes.
    emit_corrupt_active_state
    exit 0
    ;;
esac

# Defense in depth: autopilot_read_active already validates this schema. The
# emitter nevertheless admits only closed stage/action pairs and token-safe
# identifiers before reflecting any value into model-facing context.
# Keep the (up to 1 MiB) validated state on stdin rather than in the process
# environment, whose platform ARG_MAX can be much smaller. Only the fixed
# emitter program is passed as an argument.
AUTOPILOT_RESUME_EMITTER="$(cat <<'NODE'
'use strict';

const fs = require('fs');

const stageActions = Object.freeze({
  PLANNING: 'AWAIT_PLAN_APPROVAL',
  AWAIT_TDD: 'START_TDD',
  TDD_RUNNING: 'AWAIT_TDD_CHAIN',
  GATES: 'RUN_GATES',
  CONVERGE: 'RUN_CONVERGENCE',
  OPEN_PR: 'RECONCILE_PR',
  TEAM_REVIEW: 'RECONCILE_TEAM_REVIEW',
  FIX_FINDINGS: 'FIX_REVIEW_FINDINGS',
  VALIDATE: 'VALIDATE_FEATURE',
  COVER: 'RUN_COVERAGE',
  DELIVER: 'DELIVER_PR',
  BLOCKED: 'AWAIT_RESUME',
  DONE: 'NONE',
  CANCELLED: 'NONE',
});

const actionText = Object.freeze({
  AWAIT_PLAN_APPROVAL: 'Wait for explicit approval of the bound plan.',
  START_TDD: 'Start the delegated TDD or implementation chain for the current attempt.',
  AWAIT_TDD_CHAIN: 'Resume the bound TDD chain and wait for its ticket-bound terminal outcome.',
  RUN_GATES: 'Run the configured quality gates and persist their evidence.',
  RUN_CONVERGENCE: 'Run the convergence checks before any pull-request effect.',
  RECONCILE_PR: 'Reconcile the pull-request operation key before creating or updating a PR.',
  RECONCILE_TEAM_REVIEW: 'Reconcile the team-review operation key before publishing review output.',
  FIX_REVIEW_FINDINGS: 'Inspect unresolved review threads and route required fixes through the bound TDD chain.',
  VALIDATE_FEATURE: 'Validate the running feature against every acceptance criterion.',
  RUN_COVERAGE: 'Run the configured coverage phase and persist its evidence.',
  DELIVER_PR: 'Verify delivery invariants and report the ready pull request without merging or deploying.',
  AWAIT_RESUME: 'Remain blocked until an explicit, audited resume or cancel event is applied.',
  NONE: 'The durable run is terminal; perform no further Autopilot effects.',
});

function emit(additionalContext) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'SessionStart',
      additionalContext,
    },
  }));
}

let state;
try {
  state = JSON.parse(fs.readFileSync(0, 'utf8'));
} catch (_) {
  emit('ZENSU_AUTOPILOT_RESUME CORRUPT_ACTIVE_STATE. The project-local Autopilot pointer and run inventory did not validate as one unambiguous active state. Do not infer progress, resume effects, or create a replacement run. Inspect and repair or explicitly cancel the durable state first.');
  process.exit(0);
}

const token = /^[A-Za-z0-9][A-Za-z0-9_.:-]{2,127}$/;
const sessionId = /^[A-Za-z0-9_-]{1,128}$/;
const exact = (value, keys) => value && typeof value === 'object' && !Array.isArray(value)
  && Object.keys(value).length === keys.length
  && keys.every(key => Object.prototype.hasOwnProperty.call(value, key));
const nonEmpty = (value, max) => typeof value === 'string' && value.length > 0
  && value.length <= max && !/[\u0000-\u001f]/.test(value);
const sha = value => typeof value === 'string' && /^[a-fA-F0-9]{7,64}$/.test(value);
const sha256 = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const positive = value => Number.isSafeInteger(value) && value > 0;
const reviewMarker = value => {
  if (typeof value !== 'string') return null;
  const match = /^<!-- zensu-review:v1:([a-f0-9]{64}):([a-f0-9]{64}):([a-f0-9]{7,64}):([1-9][0-9]{0,5}):part=1\/([1-9][0-9]{0,5}) -->$/.exec(value);
  return match && match[4] === match[5]
    ? { payloadDigest: match[2], headSha: match[3], partCount: Number(match[4]) }
    : null;
};
const runId = state && state.runId;
const ownerSessionId = state && state.ownerSessionId;
const stage = state && state.stage;
const nextActionCode = state && state.nextActionCode;
const currentSessionId = process.env.CURRENT_SESSION_ID || '';
const tdd = state && state.tdd;
const effects = state && state.effects;
const evidence = state && state.evidence;
const returnStages = new Set([null, 'GATES', 'CONVERGE', 'FIX_FINDINGS', 'VALIDATE', 'COVER']);
const effectStatuses = new Set(['none', 'requested', 'completed']);
const attempt = tdd && Number.isSafeInteger(tdd.attempt) && tdd.attempt >= 0 ? tdd.attempt : null;
const returnStage = tdd && returnStages.has(tdd.returnStage) ? tdd.returnStage : undefined;
const chainId = tdd && (tdd.chainId === null || token.test(tdd.chainId)) ? tdd.chainId : undefined;
const tddSessionId = tdd && (tdd.sessionId === null || token.test(tdd.sessionId)) ? tdd.sessionId : undefined;
const headUpdateRequired = tdd && typeof tdd.headUpdateRequired === 'boolean'
  ? tdd.headUpdateRequired : undefined;
const prStatus = effects && effects.prOpen && effectStatuses.has(effects.prOpen.status)
  ? effects.prOpen.status : undefined;
const reviewStatus = effects && effects.teamReview && effectStatuses.has(effects.teamReview.status)
  ? effects.teamReview.status : undefined;
const evidenceShapeValid = exact(evidence,
  ['pr', 'gates', 'review', 'findings', 'validation', 'coverage', 'delivery']);
const prEvidenceValid = evidenceShapeValid && (evidence.pr === null
  || (exact(evidence.pr, ['number', 'url', 'headSha'])
    && positive(evidence.pr.number) && nonEmpty(evidence.pr.url, 2048)
    && /^https:\/\//.test(evidence.pr.url) && sha(evidence.pr.headSha)));
const reviewEvidenceValid = evidenceShapeValid && (evidence.review === null
  || (exact(evidence.review, ['published', 'marker', 'headSha', 'payloadDigest', 'partCount', 'provider'])
    && evidence.review.published === true && nonEmpty(evidence.review.marker, 512)
    && sha(evidence.review.headSha) && sha256(evidence.review.payloadDigest)
    && positive(evidence.review.partCount) && evidence.review.partCount <= 999999
    && (evidence.review.provider === null
      || evidence.review.provider === 'github' || evidence.review.provider === 'gitlab')
    && (() => {
      const marker = reviewMarker(evidence.review.marker);
      return marker !== null && marker.payloadDigest === evidence.review.payloadDigest
        && marker.headSha === evidence.review.headSha.toLowerCase()
        && marker.partCount === evidence.review.partCount;
    })()));
const valid = token.test(runId || '')
  && token.test(ownerSessionId || '')
  && sessionId.test(currentSessionId)
  && Object.prototype.hasOwnProperty.call(stageActions, stage)
  && stageActions[stage] === nextActionCode
  && Object.prototype.hasOwnProperty.call(actionText, nextActionCode)
  && attempt !== null
  && returnStage !== undefined
  && chainId !== undefined
  && tddSessionId !== undefined
  && headUpdateRequired !== undefined
  && (stage !== 'TDD_RUNNING' || (attempt > 0 && chainId !== null
    && tddSessionId === ownerSessionId && returnStage !== null && headUpdateRequired === false))
  && prStatus !== undefined
  && reviewStatus !== undefined
  && prEvidenceValid
  && reviewEvidenceValid
  && (prStatus === 'completed' ? evidence.pr !== null : evidence.pr === null)
  && (reviewStatus === 'completed' ? evidence.review !== null : evidence.review === null)
  && (reviewStatus !== 'completed' || prStatus === 'completed');

if (!valid) {
  emit('ZENSU_AUTOPILOT_RESUME CORRUPT_ACTIVE_STATE. The project-local Autopilot pointer and run inventory did not validate as one unambiguous active state. Do not infer progress, resume effects, or create a replacement run. Inspect and repair or explicitly cancel the durable state first.');
  process.exit(0);
}

const exactEvidence = JSON.stringify({ pr: evidence.pr, review: evidence.review });
if (stage === 'DONE' || stage === 'CANCELLED') {
  emit(`ZENSU_AUTOPILOT_RESUME TERMINAL_RUN runId=${runId} stage=${stage} nextActionCode=NONE prStatus=${prStatus} teamReviewStatus=${reviewStatus} evidence=${exactEvidence}. This durable run is terminal and does not block a new Autopilot run or standalone plan. Do not resume it or repeat its historical effects.`);
  process.exit(0);
}

if (ownerSessionId !== currentSessionId) {
  emit(`ZENSU_AUTOPILOT_RESUME OWNER_MISMATCH runId=${runId} stage=${stage}. This nonterminal durable run belongs to another top-level session. Do not resume, mutate, replace, or repeat its effects here. Continue, resume, or cancel it only from its owner session; if that session cannot be recovered, stop and request explicit manual state repair.`);
  process.exit(0);
}

const returnLabel = returnStage === null ? 'NONE' : returnStage;
const chainLabel = chainId === null ? 'NONE' : chainId;
const tddSessionLabel = tddSessionId === null ? 'NONE' : tddSessionId;
const actionFields = headUpdateRequired
  ? `stage=${stage} prerequisiteActionCode=UPDATE_PR_HEAD nextActionCode=${nextActionCode}`
  : `stage=${stage} nextActionCode=${nextActionCode}`;
const actionDirective = headUpdateRequired
  ? `FIRST execute prerequisite action UPDATE_PR_HEAD: re-run the configured gates, push the fixes, read the resulting PR head, and persist the exact PR_HEAD_UPDATED event. Only after that succeeds continue stage action ${nextActionCode}: ${actionText[nextActionCode]}`
  : actionText[nextActionCode];
emit(`ZENSU_AUTOPILOT_RESUME ACTIVE_RUN runId=${runId} ${actionFields} tddAttempt=${attempt} returnStage=${returnLabel} prStatus=${prStatus} teamReviewStatus=${reviewStatus} tddChainId=${chainLabel} tddSessionId=${tddSessionLabel} headUpdateRequired=${headUpdateRequired} evidence=${exactEvidence}. ${actionDirective} Continue this exact durable run only; do not restart completed stages, repeat remote effects, or mark DONE outside guarded state transitions.`);
NODE
)"
printf '%s' "$ACTIVE_STATE" | CURRENT_SESSION_ID="$SESSION_ID" node -e "$AUTOPILOT_RESUME_EMITTER"

exit 0
