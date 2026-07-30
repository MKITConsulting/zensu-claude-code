#!/bin/bash
# Hierarchical Stop backstop. The inner TDD review chain gets first routing
# priority; after it permits a stop, a durable outer Autopilot run may still
# block until it reaches DONE, BLOCKED, or CANCELLED.
set -u
DEFERRED_OWNER_PID="${BASHPID:-$$}"
case "$DEFERRED_OWNER_PID" in ''|*[!0-9]*) exit 2 ;; esac
[ "$DEFERRED_OWNER_PID" -gt 0 ] || exit 2

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

# These responses deliberately have no dynamic fields. Once a trusted main
# Stop event has been authenticated, durable or inner state plus a missing
# workflow library must never be interpreted as successful completion.
emit_runtime_unavailable_block() {
  printf '%s\n' '{"decision":"block","reason":"Zensu Autopilot Stop denied: durable state exists but the durable state runtime is unavailable."}'
}

emit_inner_runtime_unavailable_block() {
  printf '%s\n' '{"decision":"block","reason":"Zensu review-chain Stop denied: project-local inner state exists but the required runtime is unavailable."}'
}

emit_session_binding_unavailable_block() {
  printf '%s\n' '{"decision":"block","reason":"Zensu Stop denied: the immutable main-session binding is unavailable, so review-chain and Autopilot completion cannot be proven."}'
}

AGENT_CONTEXT_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-agent-context.sh"
# Without Node or the principal classifier, this hook cannot authenticate a
# top-level Stop event. Stay silent rather than risk deadlocking a child.
command -v node >/dev/null 2>&1 || exit 0
[ -r "$AGENT_CONTEXT_LIB" ] || exit 0
# shellcheck disable=SC1090
source "$AGENT_CONTEXT_LIB"
zensu_hook_is_main_principal "$INPUT" Stop || exit 0


SESSION_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
if [ ! -r "$SESSION_LIB" ]; then
  emit_session_binding_unavailable_block
  exit 0
fi
# shellcheck disable=SC1090
source "$SESSION_LIB"
if ! zensu_bind_hook_session "$INPUT"; then
  emit_session_binding_unavailable_block
  exit 0
fi

PROJECT_ROOT="$(zensu_resolve_project_dir)" || {
  emit_session_binding_unavailable_block
  exit 0
}
ACTIVE_POINTER_HINT="$PROJECT_ROOT/.zensu/state/autopilot-active.json"
ACTIVE_POINTER_EXISTS=false
if [ -e "$ACTIVE_POINTER_HINT" ] || [ -L "$ACTIVE_POINTER_HINT" ]; then
  ACTIVE_POINTER_EXISTS=true
fi
AUTOPILOT_RUN_HINT_EXISTS=false
for _zensu_run_hint in "$PROJECT_ROOT/.zensu/state"/autopilot-run-*.json; do
  if [ -e "$_zensu_run_hint" ] || [ -L "$_zensu_run_hint" ]; then
    AUTOPILOT_RUN_HINT_EXISTS=true
    break
  fi
done
unset _zensu_run_hint
DURABLE_STATE_HINT_EXISTS=false
if [ "$ACTIVE_POINTER_EXISTS" = "true" ] || [ "$AUTOPILOT_RUN_HINT_EXISTS" = "true" ]; then
  DURABLE_STATE_HINT_EXISTS=true
fi
INNER_STATE_DIR_HINT="${TDD_STATE_DIR:-$PROJECT_ROOT/.zensu/state}"
INNER_STATE_EXISTS=false
for _zensu_inner_hint in "$INNER_STATE_DIR_HINT"/tdd-phase-*.json; do
  if [ -e "$_zensu_inner_hint" ] || [ -L "$_zensu_inner_hint" ]; then
    INNER_STATE_EXISTS=true
    break
  fi
done
unset _zensu_inner_hint

AUTOPILOT_STATE_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh"
CONFIG_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
TDD_PHASE_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
if [ ! -r "$SESSION_LIB" ] || [ ! -r "$CONFIG_LIB" ] || [ ! -r "$TDD_PHASE_LIB" ] \
    || [ ! -r "$AUTOPILOT_STATE_LIB" ]; then
  if [ "$DURABLE_STATE_HINT_EXISTS" = "true" ]; then emit_runtime_unavailable_block
  elif [ "$INNER_STATE_EXISTS" = "true" ]; then emit_inner_runtime_unavailable_block
  fi
  exit 0
fi

read_field() {
  printf '%s' "$INPUT" | FIELD="$1" node -e '
    try {
      const j=JSON.parse(require("fs").readFileSync(0,"utf8")||"{}");
      const v=j[process.env.FIELD];
      process.stdout.write(typeof v==="string"?v:(typeof v==="boolean"?String(v):""));
    } catch (_) { process.stdout.write(""); }
  ' 2>/dev/null
}

SESSION_ID="$(read_field session_id)"
source "$SESSION_LIB"
PROJECT_ROOT="$(zensu_resolve_project_dir)" || exit 0
SESSION_ID="$(zensu_resolve_session_id "$SESSION_ID")" || exit 0
source "$CONFIG_LIB"
source "$TDD_PHASE_LIB"
STATE_FILE="$(tdd_state_file "$SESSION_ID")"

INNER_SNAPSHOT=""
if INNER_SNAPSHOT="$(tdd_chain_snapshot "$STATE_FILE" "$SESSION_ID" 2>/dev/null)"; then
  INNER_STATUS=0
else
  INNER_STATUS=$?
fi
case "$INNER_STATUS" in
  0)
    INNER_FIELDS="$(printf '%s' "$INNER_SNAPSHOT" | node -e '
      try {
        const s=JSON.parse(require("fs").readFileSync(0,"utf8"));
        process.stdout.write([s.active,s.implComplete,s.chainDone,s.codeReviewDone,
          s.autopilot?s.autopilot.runId:"",s.autopilot?s.autopilot.attempt:"",
          s.autopilot?s.autopilot.returnStage:"",
          s.autopilot?s.autopilot.chainId:""].join("\t"));
      } catch (_) { process.exit(3); }
    ' 2>/dev/null)" || {
      printf '%s\n' '{"decision":"block","reason":"Zensu review-chain Stop denied: current-session inner state is corrupt or unsafe."}'
      exit 0
    }
    IFS=$'\t' read -r SESSION_ACTIVE SESSION_IMPL_COMPLETE SESSION_CHAIN_DONE \
      _SESSION_CODE_REVIEW_DONE INNER_BOUND_RUN INNER_BOUND_ATTEMPT \
      INNER_BOUND_RETURN_STAGE INNER_BOUND_CHAIN <<<"$INNER_FIELDS"
    ;;
  1)
    # SessionStart creates this baseline before any model action. Once the
    # immutable session context is bound, a missing baseline is deletion or an
    # incomplete initialization and must never be reinterpreted as inactivity.
    printf '%s\n' '{"decision":"block","reason":"Zensu review-chain Stop denied: the mandatory current-session workflow baseline is missing. Start a fresh Claude Code session or repair the Session Control state; do not infer completion."}'
    exit 0
    ;;
  *)
    printf '%s\n' '{"decision":"block","reason":"Zensu review-chain Stop denied: current-session inner state is corrupt or unsafe."}'
    exit 0
    ;;
esac

OUTER_STATUS=1
OUTER_JSON=""
if [ -r "$AUTOPILOT_STATE_LIB" ]; then
  # shellcheck disable=SC1090
  source "$AUTOPILOT_STATE_LIB"
  if OUTER_JSON="$(autopilot_read_active "$PROJECT_ROOT" 2>/dev/null)"; then
    OUTER_STATUS=0
  else
    OUTER_STATUS=$?
  fi
fi

emit_block() {
  printf '%s' "$1" | node -e '
    const reason = require("node:fs").readFileSync(0, "utf8");
    process.stdout.write(JSON.stringify({decision:"block",reason}));
  '
  echo
}

# A corrupt/orphaned outer inventory is authoritative and must fail closed
# before deferred-review adoption, inner counters, or any other mutation.
if [ "$OUTER_STATUS" -gt 1 ]; then
  emit_block "Zensu Autopilot Stop denied: project-local durable state is corrupt or unsafe. Repair or explicitly cancel it; do not infer completion."
  exit 0
fi

if [ "$OUTER_STATUS" -eq 1 ] && [ -n "$INNER_BOUND_RUN" ]; then
  emit_block "Zensu Autopilot Stop denied: the current inner generation is bound to run ${INNER_BOUND_RUN}, but its project-local active pointer is missing. Restore or explicitly repair the durable outer state; do not infer completion."
  exit 0
fi

outer_fields() {
  printf '%s' "$OUTER_JSON" | node -e '
    let input="";
    process.stdin.on("data",c=>input+=c);
    process.stdin.on("end",()=>{ try {
      const s=JSON.parse(input||"{}");
      if(!s.tdd || typeof s.tdd.headUpdateRequired!=="boolean")process.exit(3);
      process.stdout.write([s.runId,s.ownerSessionId,s.stage,s.nextActionCode,
        s.tdd.headUpdateRequired].join("\t"));
    } catch (_) { process.exit(3); } });
  ' 2>/dev/null
}

outer_reload() {
  if OUTER_JSON="$(autopilot_read_active "$PROJECT_ROOT" 2>/dev/null)"; then OUTER_STATUS=0; else OUTER_STATUS=$?; fi
}

outer_is_stop_terminal() {
  [ "$OUTER_STATUS" -eq 0 ] || return 1
  printf '%s' "$OUTER_JSON" | node -e '
    try {
      const s=JSON.parse(require("fs").readFileSync(0,"utf8")||"{}");
      // BLOCKED is stop-releasing but still resumable and project-owning.  It
      // must never be treated as historical for standalone/deferred adoption.
      process.exit(["DONE","CANCELLED"].includes(s.stage)?0:1);
    } catch (_) { process.exit(2); }
  ' 2>/dev/null
}

outer_apply_block() {
  local run_id="$1" code="$2" suffix="$3" payload state generation event_key event_id verified
  state="$(autopilot_read_run "$run_id" "$PROJECT_ROOT" 2>/dev/null)" || return 1
  generation="$(printf '%s' "$state" | node -e '
    let input="";process.stdin.on("data",c=>input+=c);process.stdin.on("end",()=>{try{
      const s=JSON.parse(input); if(!Array.isArray(s.events)||typeof s.stage!=="string")process.exit(3);
      process.stdout.write(`${s.stage}:${s.events.length}`);
    }catch(_){process.exit(3);}});
  ' 2>/dev/null)" || return 1
  event_key="$(RUN="$run_id" CODE="$code" SUFFIX="$suffix" GENERATION="$generation" node -e '
    const crypto=require("crypto");
    process.stdout.write(crypto.createHash("sha256").update(JSON.stringify([
      process.env.RUN,process.env.CODE,process.env.SUFFIX,process.env.GENERATION
    ])).digest("hex"));
  ')" || return 1
  event_id="outer-block-${event_key}"
  payload="$(CODE="$code" node -e 'process.stdout.write(JSON.stringify({code:process.env.CODE}))')"
  autopilot_apply_event "$run_id" "$event_id" BLOCK "$payload" \
    "$PROJECT_ROOT" "$SESSION_ID" >/dev/null 2>&1 || return 1
  verified="$(autopilot_read_run "$run_id" "$PROJECT_ROOT" 2>/dev/null)" || return 1
  printf '%s' "$verified" | CODE="$code" EVENT_ID="$event_id" node -e '
    let input="";process.stdin.on("data",c=>input+=c);process.stdin.on("end",()=>{try{
      const s=JSON.parse(input),last=Array.isArray(s.events)&&s.events[s.events.length-1];
      const ok=s.stage==="BLOCKED"&&s.blocked&&s.blocked.code===process.env.CODE
        &&last&&last.eventId===process.env.EVENT_ID&&last.eventType==="BLOCK"
        &&last.payload&&last.payload.code===process.env.CODE;
      process.exit(ok?0:3);
    }catch(_){process.exit(3);}});
  ' 2>/dev/null
}

# Explicit Autopilot escapes are audited state transitions. They never forge a
# successful terminus and they take precedence over inner-chain enforcement.
if [ "$OUTER_STATUS" -eq 0 ] && { [ "${ZENSU_AUTOPILOT:-}" = "off" ] || ! zensu_hook_enabled autopilotEnforcer; }; then
  # The escape decision is a current-pointer proof, not a cached-status check.
  # Reconcile/read under the project lock so a historical DONE/CANCELLED
  # snapshot cannot release a concurrently published active run.
  if OUTER_JSON="$(autopilot_reconcile_stop_active "$PROJECT_ROOT" "$SESSION_ID" 2>/dev/null)"; then
    OUTER_STATUS=0
  else
    OUTER_STATUS=$?
    if [ "$OUTER_STATUS" -eq 1 ]; then exit 0; fi
    emit_block "Zensu Autopilot escape denied: current durable state could not be proven safely."
    exit 0
  fi
  FIELDS="$(outer_fields)" || { emit_block "Zensu Autopilot state is corrupt; the requested escape could not be audited. Repair or cancel the project-local state explicitly."; exit 0; }
  IFS=$'\t' read -r OUTER_RUN OUTER_OWNER OUTER_STAGE _ <<<"$FIELDS"
  case "$OUTER_STAGE" in DONE|BLOCKED|CANCELLED) exit 0 ;; esac
  if [ "$OUTER_OWNER" != "$SESSION_ID" ]; then
    emit_block "Zensu Autopilot Stop denied: the active durable run belongs to another top-level session and cannot be escaped here. Only its original owner task/session may resume or cancel it; a fresh session cannot take ownership. Reopen the owner task or perform explicit manual state recovery."
    exit 0
  fi
  if [ "${ZENSU_AUTOPILOT:-}" = "off" ]; then ESCAPE_CODE=ZENSU_AUTOPILOT_OFF; else ESCAPE_CODE=AUTOPILOT_ENFORCER_DISABLED; fi
  case "$OUTER_STAGE" in DONE|BLOCKED|CANCELLED) ;;
    *) outer_apply_block "$OUTER_RUN" "$ESCAPE_CODE" "escape-${OUTER_STAGE}" || {
         emit_block "Zensu Autopilot escape failed to persist BLOCKED; Stop remains denied to avoid an unaudited bypass."
         exit 0
       } ;;
  esac
  exit 0
fi
outer_finish() {
  local fields run_id owner stage action head_update_required count cap
  local budget_json budget_fields budget_blocked reconcile_rc budget_rc
  local stale_retry="${1:-false}"

  # Re-read and, when necessary, reconcile the current Outer+Inner generation
  # under the canonical Outer -> Inner lock order. Never decide from the stale
  # snapshots captured when this Stop invocation began: a newer TDD attempt may
  # already own both files by the time inner-first routing reaches this point.
  if OUTER_JSON="$(autopilot_reconcile_stop_active "$PROJECT_ROOT" "$SESSION_ID" 2>/dev/null)"; then
    OUTER_STATUS=0
  else
    reconcile_rc=$?
    OUTER_STATUS=$reconcile_rc
    case "$reconcile_rc" in
      1) return 0 ;;
      *) emit_block "Zensu Autopilot Stop denied: project-local durable state could not be reconciled safely. Repair or explicitly cancel it; do not infer completion."; return 0 ;;
    esac
  fi

  fields="$(outer_fields)" || { emit_block "Zensu Autopilot Stop denied: validated state fields could not be read."; return 0; }
  IFS=$'\t' read -r run_id owner stage action head_update_required <<<"$fields"
  case "$stage" in
    DONE|BLOCKED|CANCELLED) return 0 ;;
  esac
  if [ "$owner" != "$SESSION_ID" ]; then
    emit_block "Zensu Autopilot Stop denied: active run ${run_id} is owned by another top-level session. Only the original owner task/session may continue, resume, or cancel it; a fresh session cannot take ownership. Reopen the owner task or perform explicit manual state recovery."
    return 0
  fi

  # Reconciliation can move the run to its return stage or to audited BLOCKED.
  case "$stage" in
    DONE|BLOCKED|CANCELLED) return 0 ;;
  esac

  cap=12
  if budget_json="$(autopilot_increment_stop_budget_capped "$run_id" "$stage" \
      "$PROJECT_ROOT" "$SESSION_ID" "$cap" STOP_BUDGET_EXHAUSTED 2>/dev/null)"; then
    :
  else
    budget_rc=$?
    if [ "$budget_rc" -eq 4 ] && [ "$stale_retry" != "true" ]; then
      # Stage/event generation changed after reconciliation but before the
      # capped mutation. Re-route exactly once from fresh state so the response
      # names the new action and the stale generation remains byte-stable.
      if OUTER_JSON="$(autopilot_read_active "$PROJECT_ROOT" 2>/dev/null)"; then
        OUTER_STATUS=0
        outer_finish true
      else
        OUTER_STATUS=$?
        if [ "$OUTER_STATUS" -ne 1 ]; then
          emit_block "Zensu Autopilot Stop denied: durable state changed and could not be re-read safely."
        fi
      fi
      return 0
    fi
    emit_block "Zensu Autopilot Stop denied: stage budget could not be persisted safely for run ${run_id}."
    return 0
  fi
  budget_fields="$(printf '%s' "$budget_json" | node -e '
    try {
      const b=JSON.parse(require("fs").readFileSync(0,"utf8"));
      if(!Number.isSafeInteger(b.count)||b.count<0||typeof b.blocked!=="boolean")process.exit(3);
      process.stdout.write(`${b.count}\t${b.blocked}`);
    } catch (_) { process.exit(3); }
  ' 2>/dev/null)" || {
    emit_block "Zensu Autopilot Stop denied: the persisted stage-budget result is invalid."
    return 0
  }
  IFS=$'\t' read -r count budget_blocked <<<"$budget_fields"
  if [ "$budget_blocked" = "true" ]; then
    echo "zensu autopilot: Stop budget exhausted in ${stage}; run moved to audited BLOCKED (never DONE)." >&2
    return 0
  fi

  if [ "$head_update_required" = "true" ]; then
    emit_block "STOP intercepted by durable Zensu Autopilot run ${run_id}. stage=${stage}; prerequisiteActionCode=UPDATE_PR_HEAD; nextActionCode=${action}; stopBlock=${count}/${cap}. FIRST execute prerequisite action UPDATE_PR_HEAD: re-run the configured gates, push the fixes, read the resulting PR head, and persist the exact PR_HEAD_UPDATED event. Only after that succeeds continue the static stage action ${action}. Inner TDD completion never releases the outer run; only DONE, BLOCKED, or CANCELLED may stop."
  else
    emit_block "STOP intercepted by durable Zensu Autopilot run ${run_id}. stage=${stage}; nextActionCode=${action}; stopBlock=${count}/${cap}. Continue exactly that closed next action. Inner TDD completion never releases the outer run; only DONE, BLOCKED, or CANCELLED may stop."
  fi
  return 0
}

# Corrupt outer state must be handled before project-wide deferred review
# adoption. A valid active outer run also never adopts an unrelated pending
# marker: its TDD attempt is explicitly run/attempt/chain bound.
OUTER_PRESENT=false
[ "$OUTER_STATUS" -ne 1 ] && OUTER_PRESENT=true

INNER_ENABLED=true
zensu_hook_enabled chainEnforcer || INNER_ENABLED=false

if [ "${ZENSU_CHAIN:-}" = "off" ]; then
  tdd_record_bypass "$SESSION_ID" ZENSU_CHAIN 2>/dev/null || true
  outer_finish
  exit 0
fi
if [ "$INNER_ENABLED" != "true" ]; then
  outer_finish
  exit 0
fi

# Evaluate a completed/cancelled historical pointer against the current inner generation before the
# usual inner-first routing. Matching run/attempt/chain means the outer audit
# already owns the terminus. A standalone or stale/mismatched inner generation
# continues through normal review enforcement.
OUTER_RELEASE_STAGE=""
if [ "$OUTER_STATUS" -eq 0 ]; then
  OUTER_RELEASE_STAGE="$(printf '%s' "$OUTER_JSON" | node -e '
    try { process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).stage || ""); }
    catch (_) { process.exit(3); }
  ' 2>/dev/null)" || OUTER_RELEASE_STAGE=""
fi
if [ "$OUTER_RELEASE_STAGE" = "BLOCKED" ]; then
  # BLOCKED releases Stop but remains resumable and keeps ownership. Prove the
  # current exact binding atomically, and never retire it or adopt queued work.
  if [ "$SESSION_ACTIVE" = "true" ] && [ "$SESSION_IMPL_COMPLETE" = "true" ] \
      && [ "$SESSION_CHAIN_DONE" != "true" ] && [ -n "$INNER_BOUND_RUN" ] \
      && autopilot_terminal_owns_inner_current "$INNER_BOUND_RUN" "$PROJECT_ROOT" \
        "$SESSION_ID" "$INNER_BOUND_ATTEMPT" "$INNER_BOUND_RETURN_STAGE" \
        "$INNER_BOUND_CHAIN"; then
    exit 0
  fi
  # BLOCKED does not own an unrelated standalone or mismatched Inner. Keep the
  # resumable Outer present, but let that unfinished Inner reach the ordinary
  # review routing (or the bound-generation fail-closed check) below.
fi
if outer_is_stop_terminal; then
  # A terminal pointer owns only its exact still-armed inner generation. It is
  # otherwise historical and must not suppress later standalone/deferred review
  # work merely because the pointer remains project-local for auditability.
  OUTER_PRESENT=false
  if [ "$SESSION_ACTIVE" = "true" ] && [ "$SESSION_IMPL_COMPLETE" = "true" ] \
      && [ "$SESSION_CHAIN_DONE" != "true" ] && [ -n "$INNER_BOUND_RUN" ]; then
    # Retire the exact historical Inner under the canonical Outer -> Inner lock
    # order. Besides closing the stale-terminal race, this prevents a queued
    # deferred review from starving forever behind a terminal run's old Inner.
    if autopilot_reset_inner "$INNER_BOUND_RUN" "$PROJECT_ROOT" "$SESSION_ID" \
        "$INNER_BOUND_ATTEMPT" "$INNER_BOUND_CHAIN"; then
      SESSION_ACTIVE=false; SESSION_IMPL_COMPLETE=false; SESSION_CHAIN_DONE=false
      _SESSION_CODE_REVIEW_DONE=false; INNER_BOUND_RUN=""; INNER_BOUND_ATTEMPT=""
      INNER_BOUND_RETURN_STAGE=""; INNER_BOUND_CHAIN=""
    else
      outer_reload
      if [ "$OUTER_STATUS" -eq 0 ] && ! outer_is_stop_terminal; then
        outer_finish
        exit 0
      elif [ "$OUTER_STATUS" -gt 1 ]; then
        emit_block "Zensu Autopilot Stop denied: terminal release raced with unsafe durable state."
        exit 0
      fi
      # The same terminal pointer does not own this Inner. Continue through
      # ordinary review enforcement instead of releasing it.
    fi
  fi
fi

ADOPT_ELIGIBLE=false
if [ "$OUTER_PRESENT" = false ]; then
  if [ "$SESSION_ACTIVE" != "true" ]; then
    ADOPT_ELIGIBLE=true
  elif [ "$SESSION_IMPL_COMPLETE" = "true" ] && [ "$SESSION_CHAIN_DONE" = "true" ]; then
    ADOPT_ELIGIBLE=true
  fi
fi

if [ "$ADOPT_ELIGIBLE" = "true" ]; then
  if zensu_tdd_strict_enabled; then VANILLA_SEED=false; else VANILLA_SEED=true; fi
  if ! declare -F autopilot_adopt_pending_review >/dev/null 2>&1; then
    emit_block "Zensu review-chain Stop denied: the durable Outer-lock adoption helper is unavailable. Repair the plugin runtime before claiming deferred review work."
    exit 0
  fi
  if autopilot_adopt_pending_review "$PROJECT_ROOT" "$SESSION_ID" \
      "$VANILLA_SEED" "$(zensu_pending_review_ttl_hours)" "$DEFERRED_OWNER_PID"; then
    :
  else
    ADOPT_RC=$?
    case "$ADOPT_RC" in
      6) ;; # no pending marker/claim; this is a normal no-work result
      4)
        # The locked read or its descriptor-backed contention fallback proved
        # that a durable run became active after the initial absent snapshot.
        # Do not take a second contended read here: its legacy rc=1 conflates
        # lock timeout with absence and could erase that stronger proof.
        emit_block "Zensu Autopilot Stop denied: a durable run became active while deferred review adoption was waiting for the Outer lock. Retry Stop so the current durable state can be routed safely."
        exit 0
        ;;
      *)
        emit_block "Zensu review-chain Stop denied: deferred-review adoption could not prove a safe absent/DONE/CANCELLED Outer generation (rc=${ADOPT_RC}). The pending review remains retryable."
        exit 0
        ;;
    esac
  fi
  if INNER_SNAPSHOT="$(tdd_chain_snapshot "$STATE_FILE" "$SESSION_ID" 2>/dev/null)"; then
    INNER_FIELDS="$(printf '%s' "$INNER_SNAPSHOT" | node -e '
      const s=JSON.parse(require("fs").readFileSync(0,"utf8"));
      process.stdout.write([s.active,s.implComplete,s.chainDone,s.codeReviewDone,
        s.autopilot?s.autopilot.runId:"",s.autopilot?s.autopilot.attempt:"",
        s.autopilot?s.autopilot.returnStage:"",
        s.autopilot?s.autopilot.chainId:""].join("\t"));
    ' 2>/dev/null)" || { emit_block "Zensu review-chain Stop denied: adopted inner state could not be validated."; exit 0; }
    IFS=$'\t' read -r SESSION_ACTIVE SESSION_IMPL_COMPLETE SESSION_CHAIN_DONE \
      _SESSION_CODE_REVIEW_DONE INNER_BOUND_RUN INNER_BOUND_ATTEMPT \
      INNER_BOUND_RETURN_STAGE INNER_BOUND_CHAIN <<<"$INNER_FIELDS"
  else
    SNAPSHOT_RC=$?
    if [ "$SNAPSHOT_RC" -eq 1 ]; then
      SESSION_ACTIVE=false; SESSION_IMPL_COMPLETE=false; SESSION_CHAIN_DONE=false
      _SESSION_CODE_REVIEW_DONE=false; INNER_BOUND_RUN=""; INNER_BOUND_ATTEMPT=""
      INNER_BOUND_RETURN_STAGE=""; INNER_BOUND_CHAIN=""
    else
    emit_block "Zensu review-chain Stop denied: deferred-review adoption left invalid inner state."
    exit 0
    fi
  fi
fi

if [ "$SESSION_ACTIVE" != "true" ]; then outer_finish; exit 0; fi
if [ "$SESSION_IMPL_COMPLETE" != "true" ]; then outer_finish; exit 0; fi
if [ "$SESSION_CHAIN_DONE" = "true" ]; then outer_finish; exit 0; fi

MAX_ROUNDS="$(zensu_autofix_max_rounds)"
case "$MAX_ROUNDS" in ''|*[!0-9]*) MAX_ROUNDS=5 ;; esac
CAP=$((MAX_ROUNDS + 3))
INNER_CAP_BLOCKED=false
if [ -n "$INNER_BOUND_RUN" ]; then
  # Every bound-Inner increment is one Outer -> Inner transaction. Besides the
  # exact run/attempt/chain binding, stage and event count are a generation CAS,
  # so an old Stop cannot cap a newly advanced outer stage.
  BOUND_OUTER_META="$(printf '%s' "$OUTER_JSON" | RUN_ID="$INNER_BOUND_RUN" SID="$SESSION_ID" \
    EXPECTED_ATTEMPT="$INNER_BOUND_ATTEMPT" EXPECTED_RETURN_STAGE="$INNER_BOUND_RETURN_STAGE" \
    EXPECTED_CHAIN="$INNER_BOUND_CHAIN" node -e '
    try {
      const s=JSON.parse(require("fs").readFileSync(0,"utf8"));
      const exact=s.runId===process.env.RUN_ID&&s.ownerSessionId===process.env.SID
        &&s.stage==="TDD_RUNNING"&&Array.isArray(s.events)&&s.tdd
        &&String(s.tdd.attempt)===process.env.EXPECTED_ATTEMPT
        &&s.tdd.returnStage===process.env.EXPECTED_RETURN_STAGE
        &&s.tdd.chainId===process.env.EXPECTED_CHAIN
        &&s.tdd.sessionId===process.env.SID;
      if(!exact)process.exit(3);
      process.stdout.write(`${s.stage}\t${s.events.length}`);
    } catch (_) { process.exit(3); }
  ' 2>/dev/null)" || BOUND_OUTER_META=""
  if [ -z "$BOUND_OUTER_META" ]; then
    outer_reload
    emit_block "Zensu review-chain Stop denied: the bound inner generation changed before its Stop budget could be claimed; retry Stop from current state."
    exit 0
  fi
  IFS=$'\t' read -r BOUND_OUTER_STAGE BOUND_OUTER_EVENTS <<<"$BOUND_OUTER_META"
  if INNER_CAP_RESULT="$(autopilot_increment_inner_stop_budget_capped \
      "$INNER_BOUND_RUN" "$BOUND_OUTER_STAGE" "$BOUND_OUTER_EVENTS" \
      "$INNER_BOUND_ATTEMPT" "$INNER_BOUND_RETURN_STAGE" "$INNER_BOUND_CHAIN" \
      "$PROJECT_ROOT" "$SESSION_ID" "$CAP" \
      INNER_REVIEW_STOP_BUDGET_EXHAUSTED 2>/dev/null)"; then
    :
  else
    # A stale CAS is expected under concurrency. Route from the new durable
    # outer generation; never emit a review prompt derived from the old inner
    # snapshot and never mutate that newer generation.
    outer_reload
    emit_block "Zensu review-chain Stop denied: the bound inner budget generation changed before it could be persisted safely; retry Stop from current state."
    exit 0
  fi
  INNER_CAP_FIELDS="$(printf '%s' "$INNER_CAP_RESULT" | node -e '
    try {
      const b=JSON.parse(require("fs").readFileSync(0,"utf8"));
      if(!Number.isSafeInteger(b.count)||b.count<0||typeof b.blocked!=="boolean")process.exit(3);
      process.stdout.write(`${b.count}\t${b.blocked}`);
    } catch (_) { process.exit(3); }
  ' 2>/dev/null)" || {
    emit_block "Zensu review-chain Stop denied: the persisted bound-inner budget result is invalid."
    exit 0
  }
  IFS=$'\t' read -r BLOCKS INNER_CAP_BLOCKED <<<"$INNER_CAP_FIELDS"
else
  if BLOCKS="$(tdd_increment_stop_budget "$SESSION_ID" 2>/dev/null)"; then
    case "$BLOCKS" in
      ''|*[!0-9]*) emit_block "Zensu review-chain Stop denied: the persisted standalone-inner budget result is invalid."; exit 0 ;;
    esac
  else
    # The locked increment rejected a stale snapshot (or could not persist).
    # Re-read before routing and fail closed if this is still the same live
    # review generation; never synthesize a counter and continue on old fields.
    if FRESH_INNER="$(tdd_chain_snapshot "$STATE_FILE" "$SESSION_ID" 2>/dev/null)"; then
      if printf '%s' "$FRESH_INNER" | node -e '
        try {
          const s=JSON.parse(require("fs").readFileSync(0,"utf8"));
          process.exit(s.active===true&&s.implComplete===true&&s.chainDone===false?0:1);
        } catch (_) { process.exit(2); }
      ' 2>/dev/null; then
        emit_block "Zensu review-chain Stop denied: the current standalone-inner budget could not be persisted safely."
      else
        outer_finish
      fi
    else
      FRESH_INNER_RC=$?
      if [ "$FRESH_INNER_RC" -eq 1 ]; then outer_finish
      else emit_block "Zensu review-chain Stop denied: current-session inner state became corrupt while updating its Stop budget."
      fi
    fi
    exit 0
  fi
fi

if [ "$BLOCKS" -gt "$CAP" ]; then
  if ! tdd_release_pending_review_claim "$SESSION_ID" 2>/dev/null; then
    emit_block "Zensu review-chain Stop denied: the deferred-review cancellation receipt could not be persisted safely at the Stop cap. Repair storage and retry; the guard remains active."
    exit 0
  fi
  if [ "$INNER_CAP_BLOCKED" = "true" ]; then
    echo "zensu chain-enforcer: inner review did not converge; active Autopilot run moved to audited BLOCKED." >&2
    exit 0
  elif [ -n "$INNER_BOUND_RUN" ]; then
    emit_block "Zensu inner review cap was reached, but the bound Autopilot generation did not persist its required audited BLOCKED transition."
    exit 0
  fi
  if [ "$(tdd_code_review_done "$STATE_FILE")" = "true" ]; then
    echo "zensu chain-enforcer: terminal self-review did not converge after ${BLOCKS} nudges (cap ${CAP}); releasing the standalone Inner guard. Run /zensu:reset-review-limit to re-arm this ticket-bound review generation, or set ZENSU_CHAIN=off explicitly. Any durable Outer run remains enforced." >&2
  else
    echo "zensu chain-enforcer: review chain did not converge after ${BLOCKS} nudges (cap ${CAP}); releasing the standalone Inner guard. This is a stalled pre-terminus chain, so /zensu:reset-review-limit is not applicable. Re-enter /zensu:tdd for the current task to start a fresh guarded chain, or set ZENSU_CHAIN=off explicitly. Any durable Outer run remains enforced." >&2
  fi
  outer_finish
  exit 0
fi

# Ensure the prompt below still describes the exact generation whose counter
# was incremented. A concurrent begin/complete is routed from fresh state.
if FRESH_PROMPT_INNER="$(tdd_chain_snapshot "$STATE_FILE" "$SESSION_ID" 2>/dev/null)"; then
  FRESH_PROMPT_RC=0
else
  FRESH_PROMPT_RC=$?
  if [ "$FRESH_PROMPT_RC" -eq 1 ]; then outer_finish
  else emit_block "Zensu review-chain Stop denied: current-session inner state became corrupt before routing."
  fi
  exit 0
fi
if FRESH_PROMPT_FIELDS="$(printf '%s' "$FRESH_PROMPT_INNER" | EXPECTED_RUN="$INNER_BOUND_RUN" \
    EXPECTED_ATTEMPT="$INNER_BOUND_ATTEMPT" EXPECTED_RETURN_STAGE="$INNER_BOUND_RETURN_STAGE" \
    EXPECTED_CHAIN="$INNER_BOUND_CHAIN" \
    EXPECTED_COUNT="$BLOCKS" node -e '
  try {
    const s=JSON.parse(require("fs").readFileSync(0,"utf8"));
    const linked=process.env.EXPECTED_RUN
      ? s.autopilot&&s.autopilot.runId===process.env.EXPECTED_RUN
        &&String(s.autopilot.attempt)===process.env.EXPECTED_ATTEMPT
        &&s.autopilot.returnStage===process.env.EXPECTED_RETURN_STAGE
        &&s.autopilot.chainId===process.env.EXPECTED_CHAIN
      : s.autopilot===null;
    const exact=s.active===true&&s.implComplete===true&&s.chainDone===false
      &&typeof s.codeReviewDone==="boolean"&&typeof s.vanilla==="boolean"
      &&s.stopBlockCount===Number(process.env.EXPECTED_COUNT)&&linked;
    if(!exact)process.exit(1);
    process.stdout.write([String(s.vanilla),String(s.implComplete),
      String(s.chainDone),String(s.codeReviewDone)].join("\t"));
  } catch (_) { process.exit(2); }
  ' 2>/dev/null)"; then
  :
else
  if printf '%s' "$FRESH_PROMPT_INNER" | node -e '
    try {
      const s=JSON.parse(require("fs").readFileSync(0,"utf8"));
      process.exit(s.active===true&&s.implComplete===true&&s.chainDone===false?0:1);
    } catch (_) { process.exit(2); }
  ' 2>/dev/null; then
    emit_block "Zensu review-chain Stop denied: the inner generation changed while Stop was being routed; retry Stop from current state."
  else
    outer_finish
  fi
  exit 0
fi

IFS=$'\t' read -r SESSION_VANILLA SESSION_IMPL SESSION_CHAIN CODE_REVIEW_DONE \
  <<<"$FRESH_PROMPT_FIELDS"
STATE_LEGEND="Session state: mode=strict, implComplete=${SESSION_IMPL}, chainDone=${SESSION_CHAIN}."
if [ "$SESSION_VANILLA" = "true" ]; then
  STATE_LEGEND="Session state: mode=vanilla, implComplete=${SESSION_IMPL}, chainDone=${SESSION_CHAIN}. In vanilla mode the RED/GREEN FSM is not driven, so the 'phase' and 'history' fields carry no signal here and are never by themselves evidence of a corrupt or never-started session."
fi
LEGEND_CLOSER="That observation does not change what must happen next: the instruction above still governs before this turn may end."
LEGEND_CLOSER_WITH_EXCEPTION="That observation does not change what must happen next: the instruction above — including the single exception it explicitly states — still governs before this turn may end."
LOG_HELPER_Q="$(printf '%q' "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh")"
PLUGIN_DATA_Q="$(printf '%q' "${CLAUDE_PLUGIN_DATA:-}")"
LOG_COMMAND="CLAUDE_PLUGIN_DATA=${PLUGIN_DATA_Q} bash ${LOG_HELPER_Q}"
INNER_BOUND_ARGS=""
INNER_ZERO_CHANGE_ARGS=""
INNER_ZERO_CHANGE_NOTE=" That terminus verifies the claim before it closes anything: it refuses while 'git diff --name-only HEAD' or an untracked non-ignored file still reports a changed file, so it can never stand in for a review of real changes."
INNER_SELF_REVIEW_ENVELOPE=" "
INNER_REVIEW_HEADERS="whose prompt starts with exactly two header lines — first 'PRE-MERGED FINDINGS (fan-out)', second 'REVIEW-TICKET: <ticket>'"
INNER_REVIEW_SUFFIX=", followed by"
if [ -n "$INNER_BOUND_RUN" ]; then
  INNER_BOUND_RUN_Q="$(printf '%q' "$INNER_BOUND_RUN")"
  INNER_BOUND_ATTEMPT_Q="$(printf '%q' "$INNER_BOUND_ATTEMPT")"
  INNER_BOUND_CHAIN_Q="$(printf '%q' "$INNER_BOUND_CHAIN")"
  INNER_BOUND_ARGS=" --autopilot-run ${INNER_BOUND_RUN_Q} --autopilot-attempt ${INNER_BOUND_ATTEMPT_Q} --chain-id ${INNER_BOUND_CHAIN_Q}"
  INNER_ZERO_CHANGE_ARGS="${INNER_BOUND_ARGS} --outcome no-changes"
  INNER_ZERO_CHANGE_NOTE=" That terminus records 'no-changes' as this attempt's audited Autopilot outcome, so the durable run keeps a receipt that distinguishes it from a reviewed close."
  INNER_SELF_REVIEW_ENVELOPE=$' Carry this exact official three-line Autopilot envelope into the skill unchanged and exactly once:\n'"ZENSU-DELEGATED-CALLER: autopilot"$'\n'"AUTOPILOT-BINDING: run=${INNER_BOUND_RUN} attempt=${INNER_BOUND_ATTEMPT} chain=${INNER_BOUND_CHAIN}"$'\n'"AUTOPILOT-STAGE: ${INNER_BOUND_RETURN_STAGE}"$'\n'
  INNER_REVIEW_HEADERS=$'whose prompt starts with exactly these five header lines:\nPRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: <ticket>\n'"ZENSU-DELEGATED-CALLER: autopilot"$'\n'"AUTOPILOT-BINDING: run=${INNER_BOUND_RUN} attempt=${INNER_BOUND_ATTEMPT} chain=${INNER_BOUND_CHAIN}"$'\n'"AUTOPILOT-STAGE: ${INNER_BOUND_RETURN_STAGE}"$'\n'
  INNER_REVIEW_SUFFIX="followed by"
fi
if [ "$CODE_REVIEW_DONE" = "true" ]; then
  SELF_REVIEW_TICKET="$(tdd_ensure_self_review_ticket "$SESSION_ID" 2>/dev/null)" || SELF_REVIEW_TICKET=""
  if _tdd_review_ticket_shape_ok "$SELF_REVIEW_TICKET"; then
    SELF_REVIEW_TICKET_Q="$(printf '%q' "$SELF_REVIEW_TICKET")"
    REASON="STOP intercepted by zensu chain-enforcer. The code-reviewer chain has converged (codeReviewDone) but the terminal self-review stage has not run. Carry this exact generation line into the skill: 'SELF-REVIEW-TICKET: ${SELF_REVIEW_TICKET}'.${INNER_SELF_REVIEW_ENVELOPE}Your VERY NEXT action MUST be the Skill tool with skill='zensu:self-review' — it performs a final critical self-reflection over this session's changes, takes at most one fix round under the still-active TDD phase-gate, and OWNS the generation-bound chain terminus (it runs: ${LOG_COMMAND} --chain-done${INNER_BOUND_ARGS} --claimed-review-ticket ${SELF_REVIEW_TICKET_Q}). Do NOT end your turn, do NOT re-run the reviewer agent, and do NOT run an unqualified --chain-done yourself — let /zensu:self-review finalize only this chain generation."
  else
    REASON="STOP intercepted by zensu chain-enforcer. The state says codeReviewDone=true, but no valid consumed review ticket can bind the terminal self-review generation. Do NOT run self-review or an unqualified terminus. /zensu:reset-review-limit cannot repair this state either — it rebinds a RETAINED consumed ticket, which is exactly what is missing here. Re-enter /zensu:tdd for the current task instead: its fresh --tdd-begin resets this session's review ticket, round counter, and chain flags in one transition, so the reviewer chain can run again and its terminus can bind."
  fi
  REASON="${REASON} ${STATE_LEGEND} ${LEGEND_CLOSER}"
else
  REASON="STOP intercepted by zensu chain-enforcer. A main-thread TDD session finished implementation (or a fix round) but the zensu:code-reviewer chain has not completed. Resume the /zensu:tdd Phase 6 review sequence where it left off: fan out the five zensu:review-aspect agents over the changed files ('git diff --name-only HEAD'), merge their findings in-thread, run the zensu:review-judge second pass when hooks.reviewJudge is enabled (the default), issue a fresh review ticket, then your NEXT action MUST be the Agent tool with subagent_type='zensu:code-reviewer' ${INNER_REVIEW_HEADERS}${INNER_REVIEW_SUFFIX} the merged findings + build/test status. Do NOT end your turn, and do NOT fix anything inline first — the post-review hook routes findings back to you and sets chain completion on PASS or max rounds. Only valid exception: if implementation produced ZERO file changes, run: ${LOG_COMMAND} --chain-done${INNER_ZERO_CHANGE_ARGS}; then stop.${INNER_ZERO_CHANGE_NOTE}"
  REASON="${REASON} ${STATE_LEGEND} ${LEGEND_CLOSER_WITH_EXCEPTION}"
fi

if ! tdd_mark_pending_review_handoff "$SESSION_ID" "$DEFERRED_OWNER_PID" 2>/dev/null; then
  emit_block "Zensu review-chain Stop denied: the review handoff lease could not be persisted safely. No actionable review instruction was emitted; repair storage and retry Stop."
  exit 0
fi
emit_block "$REASON"
exit 0
