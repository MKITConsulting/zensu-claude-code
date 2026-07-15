#!/bin/bash
# PostToolUse:ExitPlanMode routing. A durable Autopilot run owns its single
# planning gate and therefore delegates straight into its bound TDD attempt.
# Standalone plans retain the existing ask-first autoTdd behavior.
set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
INPUT="$(cat)"

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT_ROOT" ]; then
  PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || PROJECT_ROOT=""
fi
ACTIVE_POINTER_HINT="${PROJECT_ROOT:+$PROJECT_ROOT/.zensu/state/autopilot-active.json}"
AUTOPILOT_STATE_HINT=false
if [ -n "$ACTIVE_POINTER_HINT" ] && { [ -e "$ACTIVE_POINTER_HINT" ] || [ -L "$ACTIVE_POINTER_HINT" ]; }; then
  AUTOPILOT_STATE_HINT=true
fi
if [ -n "$PROJECT_ROOT" ]; then
  for _zensu_autopilot_hint in "$PROJECT_ROOT/.zensu/state"/autopilot-run-*.json; do
    if [ -e "$_zensu_autopilot_hint" ] || [ -L "$_zensu_autopilot_hint" ]; then
      AUTOPILOT_STATE_HINT=true
      break
    fi
  done
fi
unset _zensu_autopilot_hint

shell_spawned_agent() {
  [ "${ZENSU_FORCE_MAIN:-}" = "1" ] && return 1
  printf '%s' "$INPUT" | grep -Eq '"agent_id"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)+"' && return 0
  printf '%s' "$INPUT" | grep -Eq '"agent_type"[[:space:]]*:[[:space:]]*"zensu:(code-reviewer|review-aspect|zensu-plm)"'
}

emit_autopilot_runtime_blocked() {
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"ZENSU_AUTOPILOT PLAN_GATE_BLOCKED code=RUNTIME_UNAVAILABLE. A project-local durable Autopilot state artifact exists, but the state runtime is unavailable. Do not implement, start unbound TDD, replace the run, or infer approval; repair the plugin runtime first."}}'
}

NODE_AVAILABLE=true
command -v node >/dev/null 2>&1 || NODE_AVAILABLE=false

read_field() {
  printf '%s' "$INPUT" | FIELD="$1" node -e '
    try {
      const j=JSON.parse(require("fs").readFileSync(0,"utf8")||"{}");
      const v=j[process.env.FIELD];
      process.stdout.write(typeof v==="string"?v:"");
    } catch (_) { process.stdout.write(""); }
  ' 2>/dev/null
}

AGENT_CONTEXT_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-agent-context.sh"
if [ "$NODE_AVAILABLE" = "true" ] && [ -r "$AGENT_CONTEXT_LIB" ]; then
  # shellcheck disable=SC1090
  source "$AGENT_CONTEXT_LIB"
  if [ "$(zensu_is_spawned_agent "$(read_field agent_id)" "$(read_field agent_type)")" = "true" ]; then
    exit 0
  fi
elif shell_spawned_agent; then
  exit 0
fi

if [ "$NODE_AVAILABLE" != "true" ]; then
  [ "$AUTOPILOT_STATE_HINT" = true ] && emit_autopilot_runtime_blocked
  exit 0
fi

AUTOPILOT_STATE_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh"
if [ ! -r "$AUTOPILOT_STATE_LIB" ] && [ "$AUTOPILOT_STATE_HINT" = true ]; then
  emit_autopilot_runtime_blocked
  exit 0
fi

emit_autopilot_context() {
  local msys_env_exclusions="LOG_HELPER_Q"
  if [ -n "${MSYS2_ENV_CONV_EXCL:-}" ]; then
    msys_env_exclusions="${MSYS2_ENV_CONV_EXCL};${msys_env_exclusions}"
  fi
  MSYS2_ENV_CONV_EXCL="$msys_env_exclusions" RUN_ID="$1" SESSION_ID="$2" \
    LOG_HELPER_Q="$3" ATTEMPT="$4" RETURN_STAGE="$5" node -e '
    const run=process.env.RUN_ID;
    const sid=process.env.SESSION_ID;
    const log=process.env.LOG_HELPER_Q;
    const attempt=process.env.ATTEMPT;
    const returnStage=process.env.RETURN_STAGE;
    const msg = `ZENSU_AUTOPILOT PLAN_APPROVED runId=${run}. This is the one approved planning gate for the durable run. Do not ask another TDD/workflow question. Continue autonomously in this top-level session. Your VERY NEXT workflow action is the Skill tool with skill=\u0027zensu:tdd\u0027, passing the approved plan as the feature specification and the delegated context AUTOPILOT-RUN: ${run}. Before implementation, that delegated skill must create one safe chain id and run exactly: bash ${log} --tdd-begin --session ${sid} --autopilot-run ${run} --autopilot-attempt ${attempt} --autopilot-return-stage ${returnStage} --chain-id <chain-id>. Do not run a standalone unbound TDD generation, do not ask the user, and do not skip the review/self-review chain.`;
    process.stdout.write(JSON.stringify({hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:msg}}));
  '
}

emit_autopilot_blocked() {
  CODE="$1" node -e '
    const code=process.env.CODE;
    const msg=`ZENSU_AUTOPILOT PLAN_GATE_BLOCKED code=${code}. Do not implement, create a replacement run, or infer plan approval. Preserve the durable state and use its explicit repair/resume/cancel path.`;
    process.stdout.write(JSON.stringify({hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:msg}}));
  '
}

# Autopilot takes precedence over hooks.autoTdd: its contract already received
# the user's one interactive approval. Absence (rc 1) falls through to the
# standalone behavior; corruption (rc 2+) is a visible, fail-closed blocker.
if [ -n "$PROJECT_ROOT" ] && [ -r "$AUTOPILOT_STATE_LIB" ]; then
  source "$AUTOPILOT_STATE_LIB"
  ACTIVE_JSON=""
  if ACTIVE_JSON="$(autopilot_read_active "$PROJECT_ROOT" 2>/dev/null)"; then
    ACTIVE_RC=0
  else
    ACTIVE_RC=$?
  fi
  if [ "$ACTIVE_RC" -gt 1 ]; then
    emit_autopilot_blocked CORRUPT_ACTIVE_STATE
    exit 0
  fi
  if [ "$ACTIVE_RC" -eq 0 ]; then
    ACTIVE_STAGE="$(printf '%s' "$ACTIVE_JSON" | node -e '
      try {
        const state=JSON.parse(require("fs").readFileSync(0,"utf8")||"{}");
        if(typeof state.stage!=="string")process.exit(3);
        process.stdout.write(state.stage);
      } catch (_) { process.exit(3); }
    ' 2>/dev/null)" || {
      emit_autopilot_blocked CORRUPT_ACTIVE_STATE
      exit 0
    }
    case "$ACTIVE_STAGE" in
      DONE|CANCELLED)
        # Terminal pointers are historical durability records. They no longer
        # own ExitPlanMode, so ordinary plans use the standalone policy below.
        ;;
      PLANNING|AWAIT_TDD)
    SESSION_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
    if [ ! -r "$SESSION_LIB" ]; then
      emit_autopilot_runtime_blocked
      exit 0
    fi
    SESSION_ID="$(read_field session_id)"
    TRANSCRIPT_PATH=""
    [ -z "$SESSION_ID" ] && TRANSCRIPT_PATH="$(read_field transcript_path)"
    source "$SESSION_LIB"
    SESSION_ID="$(ZENSU_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" zensu_resolve_session_id "$SESSION_ID")"

    ACTIVE_META="$(printf '%s' "$ACTIVE_JSON" | node -e '
      let input="";
      process.stdin.on("data",c=>input+=c);
      process.stdin.on("end",()=>{ try {
        const state=JSON.parse(input||"{}");
        const stages=new Set(["GATES","CONVERGE","FIX_FINDINGS","VALIDATE","COVER"]);
        const attempt=state.stage==="PLANNING" ? 1 : state.tdd&&Number.isInteger(state.tdd.attempt) ? state.tdd.attempt+1 : null;
        const returnStage=state.stage==="PLANNING" ? "GATES" : state.tdd&&state.tdd.returnStage;
        if(!Number.isInteger(attempt)||attempt<1||attempt>999||!stages.has(returnStage))process.exit(3);
        process.stdout.write([state.runId,state.ownerSessionId,state.stage,attempt,returnStage].join("\t"));
      } catch (_) { process.exit(3); } });
    ' 2>/dev/null)" || {
      emit_autopilot_blocked CORRUPT_ACTIVE_STATE
      exit 0
    }
    IFS=$'\t' read -r ACTIVE_RUN ACTIVE_OWNER ACTIVE_STAGE ACTIVE_ATTEMPT ACTIVE_RETURN_STAGE <<<"$ACTIVE_META"
    PLAN_META="$(printf '%s' "$INPUT" | ACTIVE_RUN="$ACTIVE_RUN" ACTIVE_OWNER="$ACTIVE_OWNER" \
      ACTIVE_STAGE="$ACTIVE_STAGE" SESSION_ID="$SESSION_ID" node -e '
      const crypto=require("crypto");
      let raw="";
      process.stdin.on("data",c=>raw+=c);
      process.stdin.on("end",()=>{ try {
        const input=JSON.parse(raw||"{}");
        const plan=input && input.tool_input && input.tool_input.plan;
        if (typeof plan!=="string" || !plan) process.exit(3);
        const matches=[...plan.matchAll(/<!-- zensu-autopilot:([A-Za-z0-9][A-Za-z0-9_.:-]{2,127}) -->/g)];
        if (matches.length!==1) process.exit(4);
        if (process.env.ACTIVE_RUN!==matches[0][1]) process.exit(5);
        if (process.env.ACTIVE_OWNER!==process.env.SESSION_ID) process.exit(6);
        if (process.env.ACTIVE_STAGE!=="PLANNING" && process.env.ACTIVE_STAGE!=="AWAIT_TDD") process.exit(7);
        const sha=crypto.createHash("sha256").update(plan,"utf8").digest("hex");
        process.stdout.write([process.env.ACTIVE_RUN,sha].join("\t"));
      } catch (_) { process.exit(3); } });
    ' 2>/dev/null)"
    META_RC=$?
    if [ "$META_RC" -ne 0 ]; then
      case "$META_RC" in
        4) BLOCK_CODE=PLAN_MARKER_MISSING_OR_AMBIGUOUS ;;
        5) BLOCK_CODE=PLAN_MARKER_RUN_MISMATCH ;;
        6) BLOCK_CODE=OWNER_SESSION_MISMATCH ;;
        7) BLOCK_CODE=PLAN_STAGE_MISMATCH ;;
        *) BLOCK_CODE=INVALID_PLAN_PAYLOAD ;;
      esac
      emit_autopilot_blocked "$BLOCK_CODE"
      exit 0
    fi
    IFS=$'\t' read -r RUN_ID PLAN_SHA <<<"$PLAN_META"
    PLAN_PAYLOAD="$(PLAN_SHA="$PLAN_SHA" node -e 'process.stdout.write(JSON.stringify({approvedPlanSha256:process.env.PLAN_SHA}))')"
    if ! autopilot_apply_event "$RUN_ID" "plan-approved-${PLAN_SHA}" PLAN_APPROVED \
        "$PLAN_PAYLOAD" "$PROJECT_ROOT" "$SESSION_ID" >/dev/null 2>&1; then
      emit_autopilot_blocked PLAN_TRANSITION_REJECTED
      exit 0
    fi
    LOG_HELPER_Q="$(printf '%q' "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh")"
    emit_autopilot_context "$RUN_ID" "$SESSION_ID" "$LOG_HELPER_Q" \
      "$ACTIVE_ATTEMPT" "$ACTIVE_RETURN_STAGE"
    exit 0
        ;;
      *)
        emit_autopilot_blocked PLAN_STAGE_MISMATCH
        exit 0
        ;;
    esac
  fi
fi

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled autoTdd || exit 0

if zensu_tdd_strict_enabled; then
cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "STOP. The plan above was just approved by the user. Do NOT implement anything yet — first determine whether to run the strict TDD flow for this plan, and in most cases ASK the user. Fast-paths that need NO question: (A) the plan only modifies non-executable text — Markdown docs (README, CHANGELOG, *.md), code comments, plain prose, or static config files with no runtime logic — proceed directly without TDD and begin your next message with 'Skipping TDD: docs only'. README/CHANGELOG edits are ALWAYS in this category, even when adding markers, sections, or restructuring. (B) the user's approval message already states an EXPLICIT TDD preference — either a negation matching 'no tdd', 'skip tdd', 'no tdd-manager', \"don't use tdd\", 'direct edit', 'kein tdd', 'ohne tdd-manager' (then skip TDD, implement directly, begin with 'Skipping TDD: user opted out'), or an affirmation matching 'use tdd', 'with tdd', 'tdd please', 'mit tdd', 'tdd bitte' (then run TDD without asking). (C) you are running non-interactively with no human to answer (Auto Mode / headless) — default to running TDD and do NOT ask. In EVERY OTHER case — the plan adds or modifies executable code (functions, classes, methods, types, conditionals, loops, exports, imports, JSX/TSX components, React hooks, styles that affect rendered output, schema/config files that drive runtime behavior) and the user stated no preference — your VERY NEXT TOOL CALL must be the AskUserQuestion tool: ask a single question such as 'Run the strict TDD flow (RED→GREEN + review chain) for this plan?' with options 'Yes — TDD flow' and 'No — implement directly'. Do NOT call Read, Edit, Write, Bash, MultiEdit, NotebookEdit, Glob, or Grep before that AskUserQuestion call. Then act on the answer YOURSELF in THIS main thread (never a subagent): if the user chooses Yes (or fast-path B-affirmation, or fast-path C) → your next tool call is the Skill tool with skill='zensu:tdd', passing the approved plan content (the markdown that appeared in the ExitPlanMode tool_input) as the feature specification — you execute strict RED→IMPL→GREEN TDD under the PreToolUse phase-gate and the auto-review chain — and you begin that message with the status line 'Executing via /zensu:tdd'. If the user chooses No → implement the plan directly in this main thread; the TDD phase-gate stays inactive (never run --tdd-begin) so your edits flow freely; begin that message with 'Skipping TDD: user declined'. Generic action phrases ('go ahead', 'start now', 'implement', 'gleich arbeiten', 'los gehts', 'immediately', 'mach mal', 'jetzt umsetzen', 'go') are NOT a TDD preference — ask anyway. If uncertain whether the plan adds executable code, ask."
  }
}
JSON
else
cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "STOP. The plan above was just approved by the user. Vanilla implementation mode is configured (hooks.tddImplementation=false): the /zensu:tdd workflow implements WITHOUT the RED→GREEN ceremony (tests at your discretion) but keeps the full evidence discipline and review chain (Phase 5/6 audits, 5-aspect fan-out, code-reviewer, self-review, Stop-hook guarantee). Do NOT implement anything yet — first determine whether to run the Zensu workflow for this plan, and in most cases ASK the user. Fast-paths that need NO question: (A) the plan only modifies non-executable text — Markdown docs (README, CHANGELOG, *.md), code comments, plain prose, or static config files with no runtime logic — proceed directly without the workflow and begin your next message with 'Skipping TDD: docs only'. README/CHANGELOG edits are ALWAYS in this category, even when adding markers, sections, or restructuring. (B) the user's approval message already states an EXPLICIT preference — either a negation matching 'no tdd', 'skip tdd', 'no tdd-manager', \"don't use tdd\", 'direct edit', 'kein tdd', 'ohne tdd-manager' (then skip the workflow, implement directly, begin with 'Skipping TDD: user opted out'), or an affirmation matching 'use tdd', 'with tdd', 'tdd please', 'mit tdd', 'tdd bitte' (then run the workflow without asking). (C) you are running non-interactively with no human to answer (Auto Mode / headless) — default to running the workflow and do NOT ask. In EVERY OTHER case — the plan adds or modifies executable code (functions, classes, methods, types, conditionals, loops, exports, imports, JSX/TSX components, React hooks, styles that affect rendered output, schema/config files that drive runtime behavior) and the user stated no preference — your VERY NEXT TOOL CALL must be the AskUserQuestion tool: ask a single question such as 'Run the Zensu workflow (vanilla implementation + review chain) for this plan?' with options 'Yes — Zensu workflow' and 'No — implement directly'. Do NOT call Read, Edit, Write, Bash, MultiEdit, NotebookEdit, Glob, or Grep before that AskUserQuestion call. Then act on the answer YOURSELF in THIS main thread (never a subagent): if the user chooses Yes (or fast-path B-affirmation, or fast-path C) → your next tool call is the Skill tool with skill='zensu:tdd', passing the approved plan content (the markdown that appeared in the ExitPlanMode tool_input) as the feature specification — the skill detects vanilla mode itself at --tdd-begin and implements directly under the Phase 5/6 evidence discipline and the auto-review chain — and you begin that message with the status line 'Executing via /zensu:tdd (vanilla mode)'. If the user chooses No → implement the plan directly in this main thread; the phase-gate stays inactive (never run --tdd-begin) so your edits flow freely; begin that message with 'Skipping TDD: user declined'. Generic action phrases ('go ahead', 'start now', 'implement', 'gleich arbeiten', 'los gehts', 'immediately', 'mach mal', 'jetzt umsetzen', 'go') are NOT a workflow preference — ask anyway. If uncertain whether the plan adds executable code, ask."
  }
}
JSON
fi
