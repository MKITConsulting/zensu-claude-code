#!/bin/bash
# Deferred review markers are claimed once, survive seed/output crashes, and do
# not shadow a later queued marker after completion/reset/cap release.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"
ROOT="$(mktemp -d -t zensu-deferred-claim-XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0; FAIL=0
check() {
  if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}
decision() {
  node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}try{const j=JSON.parse(s);if(j&&j.decision==="block"&&typeof j.reason==="string"){console.log("block");return}}catch(_){}console.log("invalid");process.exitCode=2});'
}
reason() {
  node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{process.stdout.write(JSON.parse(s).reason||"")}catch(_){}});'
}

setup_case() {
  local config_json="${2:-}"
  CASE_ROOT="$ROOT/$1"
  CASE_PROJECT="$CASE_ROOT/project"
  CASE_STATE="$CASE_PROJECT/.zensu/state"
  CASE_CONFIG="$CASE_ROOT/config.json"
  CASE_PLUGIN_DATA="$CASE_ROOT/plugin-data"
  mkdir -p "$CASE_PROJECT" "$CASE_PLUGIN_DATA"
  [ -n "$config_json" ] || config_json='{}'
  printf '%s\n' "$config_json" > "$CASE_CONFIG"
  activate_session "case-control-$1"
}
activate_session() {
  local sid="$1"
  export CLAUDE_PROJECT_DIR="$CASE_PROJECT"
  export ZENSU_TEST_PLUGIN_DATA="$CASE_PLUGIN_DATA"
  # shellcheck disable=SC1090
  source "$BASELINE" "$sid"
}
zlog() {
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CASE_CONFIG" bash "$LOG" "$@"
}
zlog_for() (
  local sid="$1"
  shift
  activate_session "$sid" || exit 1
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CASE_CONFIG" bash "$LOG" "$@"
)
adopt() (
  local sid="$1"
  activate_session "$sid" || exit 1
  SID="$sid" PLUGIN_DIR="$PLUGIN_DIR" bash -c '
    # shellcheck disable=SC1090
    source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
    adopting_pid="${BASHPID:-$$}"
    tdd_adopt_pending_review "$SID" true 0 "$adopting_pid"
  '
)
fail_seed_after_assignment() (
  local sid="$1"
  activate_session "$sid" || exit 1
  SID="$sid" PLUGIN_DIR="$PLUGIN_DIR" bash -c '
    # shellcheck disable=SC1090
    source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
    tdd_seed_deferred_review() { return 1; }
    adopting_pid="${BASHPID:-$$}"
    tdd_adopt_pending_review "$SID" true 0 "$adopting_pid"
  '
)
advance_transfer_core() {
  local stage="$1"
  CONTROL_CORE="$CORE" CURRENT_CONTEXT="$ZENSU_SESSION_CONTEXT" \
    CURRENT_SESSION="$ZENSU_SESSION_KEY" PROJECT_ROOT="$ZENSU_PROJECT_ROOT" \
    PLUGIN_ROOT="$PLUGIN_DIR" RUNTIME_DIGEST="$ZENSU_RUNTIME_DIGEST" \
    CLAIM_FILE="$ZENSU_PROJECT_ROOT/.zensu/state/pending-review.json.claim" STAGE="$stage" node -e '
      const core = require(process.env.CONTROL_CORE);
      const options = {
        currentContextFile: process.env.CURRENT_CONTEXT,
        currentSessionId: process.env.CURRENT_SESSION,
        projectRoot: process.env.PROJECT_ROOT,
        pluginRoot: process.env.PLUGIN_ROOT,
        runtimeDigest: process.env.RUNTIME_DIGEST,
        claimFile: process.env.CLAIM_FILE,
        claimStale: false,
      };
      const prepared = core.prepareDeferredReviewTransfer(options);
      const expectedRevision = prepared.transfer.fromOwnerRevision;
      core.retireDeferredReviewOwner({ ...options, expectedRevision });
      if (process.env.STAGE === "retired-before-ack") process.exit(0);
      core.markDeferredReviewOwnerRetired({ ...options, expectedRevision });
      const claim = core.assignDeferredReviewClaim({
        ...options,
        ownerPid: process.pid,
        logStyle: "wall",
      });
      process.stdout.write(claim.claimId);
    '
}
retire_without_receipt_ack() (
  activate_session "$1" || exit 1
  advance_transfer_core retired-before-ack >/dev/null
)
seed_without_transfer_finalize() (
  local sid="$1" claim_id
  activate_session "$sid" || exit 1
  claim_id="$(advance_transfer_core assigned-before-seed)" || exit 1
  # shellcheck disable=SC1090
  source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
  tdd_seed_deferred_review "$sid" true "$claim_id"
)
begin_bound_inner() (
  local sid="$1" run_id="$2" attempt="$3" chain_id="$4"
  activate_session "$sid" || exit 1
  # shellcheck disable=SC1090
  source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
  tdd_begin_session "$sid" false false false "" \
    "$run_id" "$attempt" GATES "$chain_id"
)
reset_bound_inner() (
  local sid="$1" run_id="$2" attempt="$3" chain_id="$4"
  activate_session "$sid" || exit 1
  # shellcheck disable=SC1090
  source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
  tdd_reset_pending_review_claim "$sid" "$run_id" "$attempt" "$chain_id"
)
write_state_cleared_reset_receipt() {
  local sid="$1" binding_json="$2" cancellation_id="$3" owner_key
  owner_key="$(canonical_session "$sid")" || return 1
  CONTROL_CORE="$CORE" PROJECT_ROOT="$CASE_PROJECT" OWNER_SESSION="$owner_key" \
    CLAIM_FILE="$CASE_STATE/pending-review.json.claim" BINDING_JSON="$binding_json" \
    CANCELLATION_ID="$cancellation_id" node -e '
      const fs=require("fs");
      const core=require(process.env.CONTROL_CORE);
      const binding=JSON.parse(process.env.BINDING_JSON);
      const claim=JSON.parse(fs.readFileSync(process.env.CLAIM_FILE,"utf8"));
      let state=core.readWorkflowState({projectRoot:process.env.PROJECT_ROOT,sessionId:process.env.OWNER_SESSION});
      if(binding!==null){
        state=core.mutateWorkflowState({
          projectRoot:process.env.PROJECT_ROOT,
          sessionId:process.env.OWNER_SESSION,
          workflowState:state.workflow_state,
          event:"tdd-begin",
          expectedRevision:state.revision,
        },draft=>({...draft,
          autopilotRunId:binding.runId,
          autopilotAttempt:binding.attempt,
          autopilotReturnStage:"GATES",
          chainId:binding.chainId,
          chainOutcome:"",
        }));
      }
      const marker={
        schemaVersion:1,
        cancellationId:process.env.CANCELLATION_ID,
        claimId:claim.claimId,
        ownerSessionId:claim.ownerSessionId,
        mode:"reset",
        origin:"linked",
        sourceRevision:state.revision,
        resultRevision:state.revision+1,
        resetBinding:binding,
      };
      const cleared=core.mutateWorkflowState({
        projectRoot:process.env.PROJECT_ROOT,
        sessionId:process.env.OWNER_SESSION,
        workflowState:"idle",
        event:"deferred-review-reset",
        expectedRevision:state.revision,
      },draft=>{
        draft.active=false;draft.implComplete=false;draft.chainDone=false;
        draft.codeReviewDone=false;draft.selfReviewFixed=false;
        draft.workflowActive=false;draft.workflowTools=[];draft.vanilla=false;
        draft.bypasses=[];draft.reviewTicket="";draft.reviewTicketConsumed=true;
        draft.reviewRound=0;draft.stopBlockCount=0;draft.deferredReviewClaim="";
        draft.phase="UNINITIALIZED";draft.step_id="";draft.history=[];
        delete draft.reviewRearm;delete draft.autopilotRunId;
        delete draft.autopilotAttempt;delete draft.autopilotReturnStage;
        delete draft.chainId;delete draft.chainOutcome;
        draft.deferredReviewCancellation=marker;
        return draft;
      });
      delete claim.transfer;
      claim.cancellation={
        schemaVersion:1,
        stage:"state-cleared",
        cancellationId:process.env.CANCELLATION_ID,
        claimId:claim.claimId,
        ownerSessionId:claim.ownerSessionId,
        mode:"reset",
        origin:"linked",
        ownerRevision:state.revision,
        clearedOwnerRevision:cleared.revision,
        resetBinding:binding,
      };
      fs.writeFileSync(process.env.CLAIM_FILE,`${JSON.stringify(claim,null,2)}\n`);
    '
}
write_prepared_unseeded_reset_receipt() {
  local sid="$1" binding_json="$2" cancellation_id="$3" owner_key
  owner_key="$(canonical_session "$sid")" || return 1
  CONTROL_CORE="$CORE" PROJECT_ROOT="$CASE_PROJECT" OWNER_SESSION="$owner_key" \
    CLAIM_FILE="$CASE_STATE/pending-review.json.claim" BINDING_JSON="$binding_json" \
    CANCELLATION_ID="$cancellation_id" node -e '
      const fs=require("fs");
      const core=require(process.env.CONTROL_CORE);
      const binding=JSON.parse(process.env.BINDING_JSON);
      const claim=JSON.parse(fs.readFileSync(process.env.CLAIM_FILE,"utf8"));
      const state=core.readWorkflowState({projectRoot:process.env.PROJECT_ROOT,sessionId:process.env.OWNER_SESSION});
      const bound=core.mutateWorkflowState({
        projectRoot:process.env.PROJECT_ROOT,
        sessionId:process.env.OWNER_SESSION,
        workflowState:"done",
        event:"chain-done",
        expectedRevision:state.revision,
      },draft=>({...draft,
        active:true,
        implComplete:true,
        chainDone:true,
        deferredReviewClaim:"",
        autopilotRunId:binding.runId,
        autopilotAttempt:binding.attempt,
        autopilotReturnStage:"GATES",
        chainId:binding.chainId,
        chainOutcome:"pass",
      }));
      delete claim.transfer;
      claim.cancellation={
        schemaVersion:1,
        stage:"prepared",
        cancellationId:process.env.CANCELLATION_ID,
        claimId:claim.claimId,
        ownerSessionId:claim.ownerSessionId,
        mode:"reset",
        origin:"unseeded",
        ownerRevision:bound.revision,
        clearedOwnerRevision:null,
        resetBinding:binding,
      };
      fs.writeFileSync(process.env.CLAIM_FILE,`${JSON.stringify(claim,null,2)}\n`);
    '
}
canonical_session() {
  node "$CORE" session-key "$1"
}
stop() (
  local sid="$1"
  activate_session "$sid" || exit 1
  printf '{"hook_event_name":"Stop","session_id":"%s"}' "$sid" | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    ZENSU_CONFIG="$CASE_CONFIG" \
    bash "$STOP" 2>/dev/null
)
state_flag() {
  local key
  key="$(canonical_session "$1")" || { printf 'missing'; return; }
  node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1]));process.stdout.write(String(j[process.argv[2]]))}catch(_){process.stdout.write("missing")}' \
    "$CASE_STATE/tdd-phase-$key.json" "$2"
}
wait_for_file() {
  local file="$1" attempts=0
  while [ ! -e "$file" ] && [ "$attempts" -lt 500 ]; do
    sleep 0.01 2>/dev/null || sleep 1
    attempts=$((attempts + 1))
  done
  [ -e "$file" ]
}
claim_summary() {
  node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(typeof j.summary==="string"?j.summary:"invalid")}catch(_){process.stdout.write("invalid")}' "$1"
}

PID_WIRING_OK="$(STOP_FILE="$STOP" TDD_FILE="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh" \
  AUTOPILOT_FILE="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh" node -e '
  const fs = require("fs");
  const stop = fs.readFileSync(process.env.STOP_FILE, "utf8");
  const tdd = fs.readFileSync(process.env.TDD_FILE, "utf8");
  const autopilot = fs.readFileSync(process.env.AUTOPILOT_FILE, "utf8");
  const capture = stop.indexOf("DEFERRED_OWNER_PID=\"${BASHPID:-$$}\"");
  const firstSubstitution = stop.indexOf("_ZENSU_EXECUTED_PLUGIN_ROOT=\"$(");
  const adopt = stop.includes("$VANILLA_SEED\" \"$(zensu_pending_review_ttl_hours)\" \"$DEFERRED_OWNER_PID\"");
  const handoff = stop.includes("tdd_mark_pending_review_handoff \"$SESSION_ID\" \"$DEFERRED_OWNER_PID\"");
  const noInnerCapture = !tdd.includes("${BASHPID:-$$}");
  const threaded = autopilot.includes("tdd_adopt_pending_review \"$session_id\" \"$vanilla\" \"$ttl_hours\" \"$owner_pid\"");
  process.stdout.write(capture >= 0 && capture < firstSubstitution && adopt && handoff
    && noInnerCapture && threaded ? "yes" : "no");
')"
if [ "$PID_WIRING_OK" = yes ]; then
  check "P0 deferred owner PID is captured before subshells and threaded explicitly" PASS
else
  check "P0 deferred owner PID is captured before subshells and threaded explicitly" FAIL
fi

# The PID stored by assignment and handoff is the long-lived top-level hook
# shell, not either short-lived pending/Claim lock subshell.
setup_case owner_pid_liveness
zlog --pending-review --files owner-pid.ts >/dev/null
PID_SID=owner-pid-session
activate_session "$PID_SID"
(
  SID="$PID_SID" PLUGIN_DIR="$PLUGIN_DIR" PID_FILE="$CASE_ROOT/top.pid" \
    READY_FILE="$CASE_ROOT/handoff-ready" RELEASE_FILE="$CASE_ROOT/release-owner" bash -c '
      # shellcheck disable=SC1090
      source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
      top_pid="${BASHPID:-$$}"
      printf "%s\n" "$top_pid" > "$PID_FILE"
      tdd_adopt_pending_review "$SID" true 0 "$top_pid" || exit 1
      tdd_mark_pending_review_handoff "$SID" "$top_pid" || exit 1
      : > "$READY_FILE"
      while [ ! -e "$RELEASE_FILE" ]; do sleep 0.01 2>/dev/null || sleep 1; done
    '
) & PID_WORKER=$!
wait_for_file "$CASE_ROOT/handoff-ready"
TOP_OWNER_PID="$(cat "$CASE_ROOT/top.pid" 2>/dev/null)"
EXPECTED_OWNER_PID="$(
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
  # shellcheck disable=SC1090
  source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
  _tdd_native_process_pid "$TOP_OWNER_PID"
)"
PID_META="$(CLAIM_FILE="$CASE_STATE/pending-review.json.claim" node -e '
  const j=JSON.parse(require("fs").readFileSync(process.env.CLAIM_FILE,"utf8"));
  process.stdout.write(`${j.ownerPid}\t${j.handoffEmitted}`);
')"
PID_ALIVE=false
kill -0 "$TOP_OWNER_PID" 2>/dev/null && PID_ALIVE=true
: > "$CASE_ROOT/release-owner"
wait "$PID_WORKER"
if [ "$PID_META" = "$EXPECTED_OWNER_PID"$'\ttrue' ] && [ "$PID_ALIVE" = true ]; then
  check "P1 deferred owner PID remains live through durable handoff" PASS
else
  check "P1 deferred owner PID remains live through durable handoff (shell=$TOP_OWNER_PID native=$EXPECTED_OWNER_PID meta=$PID_META alive=$PID_ALIVE)" FAIL
fi

# Reset remains an idempotent no-op when neither a state nor a claim artifact
# exists for the current canonical session.
setup_case reset_without_artifacts
NO_STATE_SID=reset-without-artifacts
activate_session "$NO_STATE_SID"
NO_STATE_FILE="$CASE_STATE/tdd-phase-$(canonical_session "$NO_STATE_SID").json"
rm -f "$NO_STATE_FILE"
if CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CASE_CONFIG" \
      bash "$LOG" --tdd-reset --session "$NO_STATE_SID" >/dev/null 2>&1 \
    && [ ! -e "$NO_STATE_FILE" ]; then
  check "P2 reset is absent/idempotent with no state and no claim" PASS
else
  check "P2 reset is absent/idempotent with no state and no claim" FAIL
fi

# A project-global claim owned by another session is absent for a current
# session with no state. Reset must neither create state nor mutate that claim.
setup_case foreign_claim_without_current_state
zlog --pending-review --files foreign-no-state.ts >/dev/null
adopt foreign-live-owner >/dev/null
FOREIGN_CLAIM="$CASE_STATE/pending-review.json.claim"
cp "$FOREIGN_CLAIM" "$CASE_ROOT/foreign-claim.before"
FOREIGN_CURRENT=foreign-reset-no-state
activate_session "$FOREIGN_CURRENT"
FOREIGN_STATE="$CASE_STATE/tdd-phase-$(canonical_session "$FOREIGN_CURRENT").json"
rm -f "$FOREIGN_STATE"
if CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CASE_CONFIG" \
      bash "$LOG" --tdd-reset --session "$FOREIGN_CURRENT" >/dev/null 2>&1 \
    && [ ! -e "$FOREIGN_STATE" ] \
    && cmp -s "$CASE_ROOT/foreign-claim.before" "$FOREIGN_CLAIM"; then
  check "P3 foreign claim is absent for a current session without state" PASS
else
  check "P3 foreign claim is absent for a current session without state" FAIL
fi

# A pending marker writer must queue behind adoption on the exact same
# pending-review.json mutex. The adopter claims the old generation; only after
# it releases the mutex may the writer publish the next queued generation.
setup_case lock_writer_adopt
zlog --pending-review --files old.ts --summary "old generation" >/dev/null
LOCK_ADOPT_SID=lock-adopt-owner
activate_session "$LOCK_ADOPT_SID"
(
  SIGNAL_FILE="$CASE_ROOT/adopt-entered" RELEASE_FILE="$CASE_ROOT/release-adopt" \
    RESULT_FILE="$CASE_ROOT/adopt.rc" SID="$LOCK_ADOPT_SID" PLUGIN_DIR="$PLUGIN_DIR" bash -c '
      # shellcheck disable=SC1090
      source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
      eval "$(declare -f _tdd_adopt_pending_review_critical | sed "1s/_tdd_adopt_pending_review_critical/_lock_original_adopt_pending_review_critical/")"
      _tdd_adopt_pending_review_critical() {
        : > "$SIGNAL_FILE"
        while [ ! -e "$RELEASE_FILE" ]; do sleep 0.01 2>/dev/null || sleep 1; done
        _lock_original_adopt_pending_review_critical "$@"
      }
      if tdd_adopt_pending_review "$SID" true 0; then rc=0; else rc=$?; fi
      printf "%s\n" "$rc" > "$RESULT_FILE"
    '
) & LOCK_ADOPT_PID=$!
wait_for_file "$CASE_ROOT/adopt-entered"
(
  : > "$CASE_ROOT/writer-adopt-started"
  if zlog --pending-review --files new.ts --summary "new generation" >/dev/null; then rc=0; else rc=$?; fi
  printf '%s\n' "$rc" > "$CASE_ROOT/writer-adopt.rc"
) & LOCK_ADOPT_WRITER_PID=$!
wait_for_file "$CASE_ROOT/writer-adopt-started"
sleep 0.2
LOCK_ADOPT_WAITED=true
[ -e "$CASE_ROOT/writer-adopt.rc" ] && LOCK_ADOPT_WAITED=false
: > "$CASE_ROOT/release-adopt"
wait "$LOCK_ADOPT_PID"; wait "$LOCK_ADOPT_WRITER_PID"
if [ "$LOCK_ADOPT_WAITED" = true ] \
  && [ "$(cat "$CASE_ROOT/adopt.rc" 2>/dev/null)" = 0 ] \
  && [ "$(cat "$CASE_ROOT/writer-adopt.rc" 2>/dev/null)" = 0 ] \
  && [ "$(claim_summary "$CASE_STATE/pending-review.json.claim")" = "old generation" ] \
  && [ "$(claim_summary "$CASE_STATE/pending-review.json")" = "new generation" ] \
  && [ "$(state_flag "$LOCK_ADOPT_SID" active)" = true ]; then
  check "L1 writer queues behind adoption on the canonical pending-review lock" PASS
else
  check "L1 writer/adoption lock serialization (waited=$LOCK_ADOPT_WAITED adopt=$(cat "$CASE_ROOT/adopt.rc" 2>/dev/null) writer=$(cat "$CASE_ROOT/writer-adopt.rc" 2>/dev/null) claim=$(claim_summary "$CASE_STATE/pending-review.json.claim") queue=$(claim_summary "$CASE_STATE/pending-review.json"))" FAIL
fi

# Queue cleanup holds the same mutex. A writer that starts while cleanup is in
# its critical section must publish afterwards, so cleanup cannot delete the
# newer generation.
setup_case lock_writer_clear
zlog --pending-review --files old-clear.ts --summary "clear old generation" >/dev/null
(
  SIGNAL_FILE="$CASE_ROOT/clear-entered" RELEASE_FILE="$CASE_ROOT/release-clear" \
    RESULT_FILE="$CASE_ROOT/clear.rc" PLUGIN_DIR="$PLUGIN_DIR" bash -c '
      # shellcheck disable=SC1090
      source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
      eval "$(declare -f _tdd_clear_pending_review_critical | sed "1s/_tdd_clear_pending_review_critical/_lock_original_clear_pending_review_critical/")"
      _tdd_clear_pending_review_critical() {
        : > "$SIGNAL_FILE"
        while [ ! -e "$RELEASE_FILE" ]; do sleep 0.01 2>/dev/null || sleep 1; done
        _lock_original_clear_pending_review_critical "$@"
      }
      if tdd_clear_pending_review; then rc=0; else rc=$?; fi
      printf "%s\n" "$rc" > "$RESULT_FILE"
    '
) & LOCK_CLEAR_PID=$!
wait_for_file "$CASE_ROOT/clear-entered"
(
  : > "$CASE_ROOT/writer-clear-started"
  if zlog --pending-review --files new-clear.ts --summary "clear new generation" >/dev/null; then rc=0; else rc=$?; fi
  printf '%s\n' "$rc" > "$CASE_ROOT/writer-clear.rc"
) & LOCK_CLEAR_WRITER_PID=$!
wait_for_file "$CASE_ROOT/writer-clear-started"
sleep 0.2
LOCK_CLEAR_WAITED=true
[ -e "$CASE_ROOT/writer-clear.rc" ] && LOCK_CLEAR_WAITED=false
: > "$CASE_ROOT/release-clear"
wait "$LOCK_CLEAR_PID"; wait "$LOCK_CLEAR_WRITER_PID"
if [ "$LOCK_CLEAR_WAITED" = true ] \
  && [ "$(cat "$CASE_ROOT/clear.rc" 2>/dev/null)" = 0 ] \
  && [ "$(cat "$CASE_ROOT/writer-clear.rc" 2>/dev/null)" = 0 ] \
  && [ "$(claim_summary "$CASE_STATE/pending-review.json")" = "clear new generation" ] \
  && [ ! -e "$CASE_STATE/pending-review.json.claim" ]; then
  check "L2 writer queues behind cleanup and its newer marker survives" PASS
else
  check "L2 writer/cleanup lock serialization (waited=$LOCK_CLEAR_WAITED clear=$(cat "$CASE_ROOT/clear.rc" 2>/dev/null) writer=$(cat "$CASE_ROOT/writer-clear.rc" 2>/dev/null) queue=$(claim_summary "$CASE_STATE/pending-review.json"))" FAIL
fi

# Twenty simultaneous sessions race on one project marker. Only the winner
# seeds/blocks; the others observe the live/emitted ownership record and no-op.
setup_case parallel
zlog --pending-review --files x.ts >/dev/null
i=1
while [ "$i" -le 20 ]; do
  (
    if stop "parallel-$i" > "$CASE_ROOT/out-$i"; then stop_rc=0; else stop_rc=$?; fi
    printf '%s\n' "$stop_rc" > "$CASE_ROOT/rc-$i"
  ) &
  i=$((i + 1))
done
wait
DECISIONS="$(OUT_DIR="$CASE_ROOT" node -e '
  const fs = require("fs");
  let block = 0;
  let allow = 0;
  let invalid = 0;
  for (let index = 1; index <= 20; index += 1) {
    const outputFile = `${process.env.OUT_DIR}/out-${index}`;
    const rcFile = `${process.env.OUT_DIR}/rc-${index}`;
    try {
      const rc = fs.readFileSync(rcFile, "utf8").trim();
      const raw = fs.readFileSync(outputFile, "utf8").trim();
      if (rc !== "0") { invalid += 1; continue; }
      if (!raw) { allow += 1; continue; }
      const value = JSON.parse(raw);
      if (value && value.decision === "block" && typeof value.reason === "string") block += 1;
      else invalid += 1;
    } catch (_) { invalid += 1; }
  }
  process.stdout.write(`${block}\t${allow}\t${invalid}`);
')"
STATE_META="$(STATE_DIR="$CASE_STATE" node -e '
  const fs = require("fs");
  const path = require("path");
  const names = fs.readdirSync(process.env.STATE_DIR).filter((name) => /^tdd-phase-scv1_[a-f0-9]{64}\.json$/.test(name));
  const states = names.map((name) => ({ name, value: JSON.parse(fs.readFileSync(path.join(process.env.STATE_DIR, name), "utf8")) }));
  const active = states.filter(({ value }) => value.active === true);
  const claim = JSON.parse(fs.readFileSync(path.join(process.env.STATE_DIR, "pending-review.json.claim"), "utf8"));
  const ownerFile = `tdd-phase-${claim.ownerSessionId}.json`;
  const exactOwner = active.length === 1
    && active[0].name === ownerFile
    && active[0].value.deferredReviewClaim === claim.claimId;
  process.stdout.write(`${states.length}\t${active.length}\t${states.length - active.length}\t${exactOwner}`);
')"
IFS=$'\t' read -r WINNERS ALLOWS INVALID_STOPS <<<"$DECISIONS"
IFS=$'\t' read -r STATES ACTIVE_STATES INACTIVE_STATES EXACT_OWNER <<<"$STATE_META"
if [ "$WINNERS" = 1 ] && [ "$ALLOWS" = 19 ] && [ "$INVALID_STOPS" = 0 ] \
  && [ "$STATES" = 21 ] && [ "$ACTIVE_STATES" = 1 ] \
  && [ "$INACTIVE_STATES" = 20 ] && [ "$EXACT_OWNER" = true ]; then
  check "C1 parallel Stops adopt and block exactly once" PASS
else
  check "C1 parallel Stops adopt and block exactly once (blocks=$WINNERS allows=$ALLOWS invalid=$INVALID_STOPS states=$STATES active=$ACTIVE_STATES inactive=$INACTIVE_STATES exact_owner=$EXACT_OWNER)" FAIL
fi

# Simulate process death after seed but before block output: direct adoption
# leaves handoffEmitted=false and its owner PID dies with the subshell. Session B
# must transfer the claim, retire A, and block itself.
setup_case seed_crash
zlog --pending-review --files crash.ts >/dev/null
adopt owner-a >/dev/null
OUT="$(stop owner-b)"
if [ "$(printf '%s' "$OUT" | decision)" = block ] \
  && [ "$(state_flag owner-a active)" = false ] \
  && [ "$(state_flag owner-b active)" = true ]; then
  check "C2 seed-before-output crash transfers one durable claim" PASS
else
  check "C2 seed-before-output crash transfers one durable claim" FAIL
fi

# Force the failure after assignment has already published canonical ownership.
# That record must remain at .claim (never be demoted to the queue, where
# --pending-review-done/Doctor cleanup is allowed), and a later Stop must recover
# it exactly once.
setup_case post_assignment_seed_failure
zlog --pending-review --files post-assignment.ts --summary "post-assignment recovery" >/dev/null
if fail_seed_after_assignment seed-failure-owner >/dev/null 2>&1; then
  POST_ASSIGN_RC=0
else
  POST_ASSIGN_RC=$?
fi
POST_ASSIGN_CLAIM="$CASE_STATE/pending-review.json.claim"
POST_ASSIGN_OWNER="$(canonical_session seed-failure-owner)"
POST_ASSIGN_META="$(CLAIM_FILE="$POST_ASSIGN_CLAIM" EXPECTED_OWNER="$POST_ASSIGN_OWNER" node -e '
  try {
    const j=JSON.parse(require("fs").readFileSync(process.env.CLAIM_FILE,"utf8"));
    const valid=j.ownerSessionId===process.env.EXPECTED_OWNER
      &&typeof j.claimId==="string"&&j.claimId.startsWith("dc_")
      &&Number.isInteger(j.ownerPid)&&j.ownerPid>0
      &&j.handoffEmitted===false;
    process.stdout.write(valid?"assigned":"invalid");
  } catch (_) { process.stdout.write("missing"); }
')"
[ -f "$POST_ASSIGN_CLAIM" ] && cp "$POST_ASSIGN_CLAIM" "$CASE_ROOT/post-assignment-before-cleanup.json"
zlog --pending-review-done >/dev/null 2>&1
POST_ASSIGN_CLEANUP_PRESERVED=false
if [ -f "$CASE_ROOT/post-assignment-before-cleanup.json" ] \
    && cmp -s "$CASE_ROOT/post-assignment-before-cleanup.json" "$POST_ASSIGN_CLAIM"; then
  POST_ASSIGN_CLEANUP_PRESERVED=true
fi
POST_ASSIGN_RECOVERED="$(stop seed-failure-recovery)"; POST_ASSIGN_RECOVERED_RC=$?
POST_ASSIGN_RECOVERY_OWNER="$(CLAIM_FILE="$POST_ASSIGN_CLAIM" node -e '
  try{const j=JSON.parse(require("fs").readFileSync(process.env.CLAIM_FILE,"utf8"));process.stdout.write(j.ownerSessionId||"missing")}catch(_){process.stdout.write("missing")}
')"
if [ "$POST_ASSIGN_RC" -eq 1 ] \
  && [ "$POST_ASSIGN_META" = assigned ] \
  && [ ! -e "$CASE_STATE/pending-review.json" ] \
  && [ "$(state_flag seed-failure-owner active)" = false ] \
  && [ "$POST_ASSIGN_CLEANUP_PRESERVED" = true ] \
  && [ "$POST_ASSIGN_RECOVERED_RC" -eq 0 ] \
  && [ "$(printf '%s' "$POST_ASSIGN_RECOVERED" | decision)" = block ] \
  && [ "$(state_flag seed-failure-recovery active)" = true ] \
  && [ "$POST_ASSIGN_RECOVERY_OWNER" = "$(canonical_session seed-failure-recovery)" ]; then
  check "C2f post-assignment seed failure retains and recovers its durable claim" PASS
else
  check "C2f post-assignment recovery (first_rc=$POST_ASSIGN_RC assigned=$POST_ASSIGN_META cleanup=$POST_ASSIGN_CLEANUP_PRESERVED retry_rc=$POST_ASSIGN_RECOVERED_RC decision=$(printf '%s' "$POST_ASSIGN_RECOVERED" | decision) owner=$POST_ASSIGN_RECOVERY_OWNER)" FAIL
fi

# Crash after the foreign-owner CAS but before its receipt acknowledgement.
# The same target principal must advance the prepared receipt, assign, seed,
# and finalize exactly once on its next Stop.
setup_case retire_before_ack
zlog --pending-review --files retire-before-ack.ts >/dev/null
adopt retire-source >/dev/null
RETIRE_STAGE_OK=false
retire_without_receipt_ack retire-target && RETIRE_STAGE_OK=true
cp "$CASE_STATE/pending-review.json.claim" "$CASE_ROOT/claim-before-delayed-release.json"
DELAYED_RELEASE_REJECTED=false
if ! zlog_for retire-source --tdd-reset --session retire-source >/dev/null 2>&1; then
  DELAYED_RELEASE_REJECTED=true
fi
RETIRE_RECEIPT_PRESERVED=false
if cmp -s "$CASE_ROOT/claim-before-delayed-release.json" \
    "$CASE_STATE/pending-review.json.claim"; then
  RETIRE_RECEIPT_PRESERVED=true
fi
RETIRE_RECOVERED="$(stop retire-target)"
RETIRE_TRANSFER_LEFT="$(CLAIM_FILE="$CASE_STATE/pending-review.json.claim" node -e '
  const j=JSON.parse(require("fs").readFileSync(process.env.CLAIM_FILE,"utf8"));
  process.stdout.write(Object.prototype.hasOwnProperty.call(j,"transfer")?"yes":"no");
')"
if [ "$RETIRE_STAGE_OK" = true ] \
  && [ "$DELAYED_RELEASE_REJECTED" = true ] \
  && [ "$RETIRE_RECEIPT_PRESERVED" = true ] \
  && [ "$(printf '%s' "$RETIRE_RECOVERED" | decision)" = block ] \
  && [ "$(state_flag retire-source active)" = false ] \
  && [ "$(state_flag retire-target active)" = true ] \
  && [ "$RETIRE_TRANSFER_LEFT" = no ]; then
  check "C2c delayed source release preserves receipt; target resumes transfer" PASS
else
  check "C2c delayed source release preserves receipt; target resumes transfer" FAIL
fi

# Crash after the target state was seeded but before the cross-file receipt was
# removed. A same-principal Stop must finalize the receipt before handoff.
setup_case seed_before_finalize
zlog --pending-review --files seed-before-finalize.ts >/dev/null
adopt finalize-source >/dev/null
FINALIZE_STAGE_OK=false
seed_without_transfer_finalize finalize-target && FINALIZE_STAGE_OK=true
FINALIZE_BEFORE="$(CLAIM_FILE="$CASE_STATE/pending-review.json.claim" node -e '
  const j=JSON.parse(require("fs").readFileSync(process.env.CLAIM_FILE,"utf8"));
  process.stdout.write(j.transfer&&j.transfer.stage==="owner-retired"?"pending":"missing");
')"
FINALIZE_RECOVERED="$(stop finalize-target)"
FINALIZE_AFTER="$(CLAIM_FILE="$CASE_STATE/pending-review.json.claim" node -e '
  const j=JSON.parse(require("fs").readFileSync(process.env.CLAIM_FILE,"utf8"));
  process.stdout.write(Object.prototype.hasOwnProperty.call(j,"transfer")?"yes":"no");
')"
if [ "$FINALIZE_STAGE_OK" = true ] \
  && [ "$FINALIZE_BEFORE" = pending ] \
  && [ "$(printf '%s' "$FINALIZE_RECOVERED" | decision)" = block ] \
  && [ "$(state_flag finalize-source active)" = false ] \
  && [ "$(state_flag finalize-target active)" = true ] \
  && [ "$FINALIZE_AFTER" = no ]; then
  check "C2d seeded-target crash finalizes receipt before same-session handoff" PASS
else
  check "C2d seeded-target crash finalizes receipt before same-session handoff" FAIL
fi

# The actionable review prompt must never become visible before its durable
# handoff lease. Force the final acknowledgement to fail after routing has
# already chosen a review action: Stop must emit only a storage-failure block.
setup_case handoff_ack_failure
zlog --pending-review --files handoff-ack-failure.ts >/dev/null
adopt ack-owner >/dev/null
printf '%s\n' '{malformed-claim' > "$CASE_STATE/pending-review.json.claim"
ACK_FAILURE_OUT="$(stop ack-owner)"
ACK_FAILURE_REASON="$(printf '%s' "$ACK_FAILURE_OUT" | reason)"
ACK_ORDER_OK="$(STOP_FILE="$STOP" node -e '
  const source = require("fs").readFileSync(process.env.STOP_FILE, "utf8");
  const ack = source.lastIndexOf("if ! tdd_mark_pending_review_handoff");
  const emit = source.lastIndexOf("emit_block \"$REASON\"");
  process.stdout.write(ack >= 0 && emit > ack ? "yes" : "no");
')"
if [ "$(printf '%s' "$ACK_FAILURE_OUT" | decision)" = block ] \
  && printf '%s' "$ACK_FAILURE_REASON" | grep -q "handoff lease could not be persisted" \
  && ! printf '%s' "$ACK_FAILURE_REASON" | grep -q "zensu:code-reviewer" \
  && [ "$ACK_ORDER_OK" = yes ]; then
  check "C2e failed lease persistence cannot expose an actionable handoff" PASS
else
  check "C2e failed lease persistence cannot expose an actionable handoff" FAIL
fi

# If the SAME interactive session retries after that crash, its Stop handoff
# re-acknowledges the retained claim and renews the lease. A later unrelated
# session must not steal or duplicate the review that was just handed off.
setup_case seed_reack
zlog --pending-review --files reack.ts >/dev/null
adopt recovered-owner >/dev/null
RECOVERED="$(stop recovered-owner)"
REACK_META="$(CLAIM_FILE="$CASE_STATE/pending-review.json.claim" node -e '
  const j = JSON.parse(require("fs").readFileSync(process.env.CLAIM_FILE, "utf8"));
  process.stdout.write(`${j.ownerSessionId}\t${j.handoffEmitted === true}`);
')"
CONTENDER="$(stop contender)"; CONTENDER_RC=$?
if [ "$(printf '%s' "$RECOVERED" | decision)" = block ] \
  && [ "$REACK_META" = "$(canonical_session recovered-owner)"$'\ttrue' ] \
  && [ "$CONTENDER_RC" -eq 0 ] \
  && [ "$(printf '%s' "$CONTENDER" | decision)" = allow ] \
  && [ "$(state_flag recovered-owner active)" = true ] \
  && [ "$(state_flag contender active)" = false ]; then
  check "C2b same-session Stop re-acknowledges crash claim before another session can steal it" PASS
else
  check "C2b same-session Stop re-acknowledges crash claim before another session can steal it" FAIL
fi

# The orchestrator's queue cleanup must not be able to delete an already
# adopted live claim. Ownership release is session-bound instead.
setup_case queue_cleanup
zlog --pending-review --files owned.ts >/dev/null
OWNED="$(stop cleanup-owner)"
zlog --pending-review-done >/dev/null
AFTER_CLEANUP="$(stop cleanup-owner)"
if [ "$(printf '%s' "$OWNED" | decision)" = block ] \
  && [ "$(printf '%s' "$AFTER_CLEANUP" | decision)" = block ] \
  && [ -f "$CASE_STATE/pending-review.json.claim" ]; then
  check "C3 queue cleanup cannot cancel a live ownership claim" PASS
else
  check "C3 queue cleanup cannot cancel a live ownership claim" FAIL
fi

# Explicit reset cancels the retained claim; it must not resurrect the adopted
# review on the next Stop.
setup_case reset_unacknowledged_cancel
zlog --pending-review --files reset-unacknowledged.ts >/dev/null
adopt reset-unack-owner >/dev/null
UNACK_BEFORE="$(CLAIM_FILE="$CASE_STATE/pending-review.json.claim" node -e '
  const j=JSON.parse(require("fs").readFileSync(process.env.CLAIM_FILE,"utf8"));
  process.stdout.write(String(j.handoffEmitted));
')"
zlog_for reset-unack-owner --tdd-reset --session reset-unack-owner >/dev/null
UNACK_AFTER="$(stop reset-unack-owner)"; UNACK_AFTER_RC=$?
if [ "$UNACK_BEFORE" = false ] \
  && [ "$UNACK_AFTER_RC" -eq 0 ] \
  && [ "$(printf '%s' "$UNACK_AFTER" | decision)" = allow ] \
  && [ ! -e "$CASE_STATE/pending-review.json.claim" ] \
  && [ "$(state_flag reset-unack-owner active)" = false ]; then
  check "C4u tdd-reset cancels an unacknowledged claim without resurrection" PASS
else
  check "C4u tdd-reset cancels an unacknowledged claim without resurrection" FAIL
fi

# Reset by the exact transfer target must recover the crash window after target
# seeding but before receipt finalization. It finalizes the owner-retired receipt
# first, then cancels the now-current claim without resurrecting the review.
setup_case reset_transfer_target
zlog --pending-review --files reset-transfer-target.ts >/dev/null
adopt reset-transfer-source >/dev/null
seed_without_transfer_finalize reset-transfer-target >/dev/null
RESET_TRANSFER_BEFORE="$(CLAIM_FILE="$CASE_STATE/pending-review.json.claim" \
  TARGET="$(canonical_session reset-transfer-target)" node -e '
    const j=JSON.parse(require("fs").readFileSync(process.env.CLAIM_FILE,"utf8"));
    process.stdout.write(j.ownerSessionId===process.env.TARGET
      &&j.transfer&&j.transfer.stage==="owner-retired"
      &&j.transfer.toOwnerSessionId===process.env.TARGET?"pending":"invalid");
  ')"
if zlog_for reset-transfer-target --tdd-reset --session reset-transfer-target >/dev/null 2>&1; then
  RESET_TRANSFER_RC=0
else
  RESET_TRANSFER_RC=$?
fi
RESET_TRANSFER_CLAIM_GONE=false
[ ! -e "$CASE_STATE/pending-review.json.claim" ] && RESET_TRANSFER_CLAIM_GONE=true
RESET_TRANSFER_AFTER="$(stop reset-transfer-target)"; RESET_TRANSFER_AFTER_RC=$?
if [ "$RESET_TRANSFER_BEFORE" = pending ] \
  && [ "$RESET_TRANSFER_RC" -eq 0 ] \
  && [ "$RESET_TRANSFER_CLAIM_GONE" = true ] \
  && [ "$(state_flag reset-transfer-source active)" = false ] \
  && [ "$(state_flag reset-transfer-target active)" = false ] \
  && [ "$RESET_TRANSFER_AFTER_RC" -eq 0 ] \
  && [ "$(printf '%s' "$RESET_TRANSFER_AFTER" | decision)" = allow ]; then
  check "C4t tdd-reset finalizes and cancels an owner-retired target receipt" PASS
else
  check "C4t transfer-target reset recovery (before=$RESET_TRANSFER_BEFORE rc=$RESET_TRANSFER_RC claim_gone=$RESET_TRANSFER_CLAIM_GONE source=$(state_flag reset-transfer-source active) target=$(state_flag reset-transfer-target active) after=$RESET_TRANSFER_AFTER_RC/$(printf '%s' "$RESET_TRANSFER_AFTER" | decision))" FAIL
fi

# Explicit reset is allowed to cancel an exact current claim that reached done
# before its handoff acknowledgement. Stop-side terminal cleanup remains strict.
setup_case reset_done_unacknowledged
zlog --pending-review --files reset-done-unacknowledged.ts >/dev/null
adopt reset-done-unack-owner >/dev/null
zlog_for reset-done-unack-owner --chain-done --session reset-done-unack-owner >/dev/null
RESET_DONE_BEFORE="$(CLAIM_FILE="$CASE_STATE/pending-review.json.claim" node -e '
  const j=JSON.parse(require("fs").readFileSync(process.env.CLAIM_FILE,"utf8"));
  process.stdout.write(j.handoffEmitted===false?"unacknowledged":"invalid");
')"
if zlog_for reset-done-unack-owner --tdd-reset --session reset-done-unack-owner >/dev/null 2>&1; then
  RESET_DONE_RC=0
else
  RESET_DONE_RC=$?
fi
RESET_DONE_CLAIM_GONE=false
[ ! -e "$CASE_STATE/pending-review.json.claim" ] && RESET_DONE_CLAIM_GONE=true
RESET_DONE_AFTER="$(stop reset-done-unack-owner)"; RESET_DONE_AFTER_RC=$?
if [ "$RESET_DONE_BEFORE" = unacknowledged ] \
  && [ "$RESET_DONE_RC" -eq 0 ] \
  && [ "$RESET_DONE_CLAIM_GONE" = true ] \
  && [ "$(state_flag reset-done-unack-owner active)" = false ] \
  && [ "$RESET_DONE_AFTER_RC" -eq 0 ] \
  && [ "$(printf '%s' "$RESET_DONE_AFTER" | decision)" = allow ]; then
  check "C4d tdd-reset cancels an unacknowledged done claim" PASS
else
  check "C4d unacknowledged-done reset (before=$RESET_DONE_BEFORE rc=$RESET_DONE_RC claim_gone=$RESET_DONE_CLAIM_GONE active=$(state_flag reset-done-unack-owner active) after=$RESET_DONE_AFTER_RC/$(printf '%s' "$RESET_DONE_AFTER" | decision))" FAIL
fi

# Assignment can outlive a seed failure while the exact owner state remains
# idle and unlinked. Owner-only reset must durably cancel that generation.
setup_case reset_assigned_unseeded
zlog --pending-review --files reset-assigned-unseeded.ts >/dev/null
if fail_seed_after_assignment reset-assigned-unseeded-owner >/dev/null 2>&1; then
  RESET_UNSEEDED_ASSIGN_RC=0
else
  RESET_UNSEEDED_ASSIGN_RC=$?
fi
RESET_UNSEEDED_BEFORE="$(CLAIM_FILE="$CASE_STATE/pending-review.json.claim" \
  OWNER="$(canonical_session reset-assigned-unseeded-owner)" node -e '
    const j=JSON.parse(require("fs").readFileSync(process.env.CLAIM_FILE,"utf8"));
    process.stdout.write(j.ownerSessionId===process.env.OWNER
      &&j.handoffEmitted===false&&!j.transfer&&!j.cancellation?"unseeded":"invalid");
  ')"
if zlog_for reset-assigned-unseeded-owner --tdd-reset \
    --session reset-assigned-unseeded-owner >/dev/null 2>&1; then
  RESET_UNSEEDED_RC=0
else
  RESET_UNSEEDED_RC=$?
fi
RESET_UNSEEDED_CLAIM_GONE=false
[ ! -e "$CASE_STATE/pending-review.json.claim" ] && RESET_UNSEEDED_CLAIM_GONE=true
RESET_UNSEEDED_AFTER="$(stop reset-assigned-unseeded-owner)"; RESET_UNSEEDED_AFTER_RC=$?
if [ "$RESET_UNSEEDED_ASSIGN_RC" -ne 0 ] \
  && [ "$RESET_UNSEEDED_BEFORE" = unseeded ] \
  && [ "$RESET_UNSEEDED_RC" -eq 0 ] \
  && [ "$RESET_UNSEEDED_CLAIM_GONE" = true ] \
  && [ "$(state_flag reset-assigned-unseeded-owner active)" = false ] \
  && [ "$RESET_UNSEEDED_AFTER_RC" -eq 0 ] \
  && [ "$(printf '%s' "$RESET_UNSEEDED_AFTER" | decision)" = allow ]; then
  check "C4s tdd-reset cancels an owner-assigned unseeded claim" PASS
else
  check "C4s assigned-unseeded reset (assign_rc=$RESET_UNSEEDED_ASSIGN_RC before=$RESET_UNSEEDED_BEFORE rc=$RESET_UNSEEDED_RC claim_gone=$RESET_UNSEEDED_CLAIM_GONE active=$(state_flag reset-assigned-unseeded-owner active) after=$RESET_UNSEEDED_AFTER_RC/$(printf '%s' "$RESET_UNSEEDED_AFTER" | decision))" FAIL
fi

# A claim may also be assigned while its target is a completed, seedable state.
# If seeding then fails, exact-owner reset must clear that unlinked generation.
setup_case reset_assigned_unseeded_done
RESET_UNSEEDED_DONE_SID=reset-assigned-unseeded-done-owner
zlog_for "$RESET_UNSEEDED_DONE_SID" --tdd-begin \
  --session "$RESET_UNSEEDED_DONE_SID" >/dev/null
zlog_for "$RESET_UNSEEDED_DONE_SID" --tdd-complete \
  --session "$RESET_UNSEEDED_DONE_SID" >/dev/null
zlog_for "$RESET_UNSEEDED_DONE_SID" --chain-done \
  --session "$RESET_UNSEEDED_DONE_SID" >/dev/null
zlog --pending-review --files reset-assigned-unseeded-done.ts >/dev/null
if fail_seed_after_assignment "$RESET_UNSEEDED_DONE_SID" >/dev/null 2>&1; then
  RESET_UNSEEDED_DONE_ASSIGN_RC=0
else
  RESET_UNSEEDED_DONE_ASSIGN_RC=$?
fi
RESET_UNSEEDED_DONE_BEFORE="$(CLAIM_FILE="$CASE_STATE/pending-review.json.claim" \
  OWNER="$(canonical_session "$RESET_UNSEEDED_DONE_SID")" node -e '
    const j=JSON.parse(require("fs").readFileSync(process.env.CLAIM_FILE,"utf8"));
    process.stdout.write(j.ownerSessionId===process.env.OWNER
      &&j.handoffEmitted===false&&!j.transfer&&!j.cancellation?"unseeded":"invalid");
  ')"
if zlog_for "$RESET_UNSEEDED_DONE_SID" --tdd-reset \
    --session "$RESET_UNSEEDED_DONE_SID" >/dev/null 2>&1; then
  RESET_UNSEEDED_DONE_RC=0
else
  RESET_UNSEEDED_DONE_RC=$?
fi
RESET_UNSEEDED_DONE_CLAIM_GONE=false
[ ! -e "$CASE_STATE/pending-review.json.claim" ] && RESET_UNSEEDED_DONE_CLAIM_GONE=true
RESET_UNSEEDED_DONE_AFTER="$(stop "$RESET_UNSEEDED_DONE_SID")"
RESET_UNSEEDED_DONE_AFTER_RC=$?
if [ "$RESET_UNSEEDED_DONE_ASSIGN_RC" -ne 0 ] \
  && [ "$RESET_UNSEEDED_DONE_BEFORE" = unseeded ] \
  && [ "$RESET_UNSEEDED_DONE_RC" -eq 0 ] \
  && [ "$RESET_UNSEEDED_DONE_CLAIM_GONE" = true ] \
  && [ "$(state_flag "$RESET_UNSEEDED_DONE_SID" active)" = false ] \
  && [ "$(state_flag "$RESET_UNSEEDED_DONE_SID" chainDone)" = false ] \
  && [ "$RESET_UNSEEDED_DONE_AFTER_RC" -eq 0 ] \
  && [ "$(printf '%s' "$RESET_UNSEEDED_DONE_AFTER" | decision)" = allow ]; then
  check "C4s-done tdd-reset cancels an unseeded claim assigned from done" PASS
else
  check "C4s-done reset recovery (assign_rc=$RESET_UNSEEDED_DONE_ASSIGN_RC before=$RESET_UNSEEDED_DONE_BEFORE rc=$RESET_UNSEEDED_DONE_RC claim_gone=$RESET_UNSEEDED_DONE_CLAIM_GONE active=$(state_flag "$RESET_UNSEEDED_DONE_SID" active) chain=$(state_flag "$RESET_UNSEEDED_DONE_SID" chainDone) after=$RESET_UNSEEDED_DONE_AFTER_RC/$(printf '%s' "$RESET_UNSEEDED_DONE_AFTER" | decision))" FAIL
fi

# The transfer target may also be assigned before its seed fails. Since an idle
# target cannot finalize the transfer, reset atomically converts that exact
# owner-retired target receipt into a cancellation receipt under Claim -> State.
setup_case reset_transfer_assigned_unseeded
zlog --pending-review --files reset-transfer-assigned-unseeded.ts >/dev/null
adopt reset-transfer-unseeded-source >/dev/null
( activate_session reset-transfer-unseeded-target \
    && advance_transfer_core assigned-before-seed >/dev/null )
RESET_TRANSFER_UNSEEDED_BEFORE="$(CLAIM_FILE="$CASE_STATE/pending-review.json.claim" \
  TARGET="$(canonical_session reset-transfer-unseeded-target)" node -e '
    const j=JSON.parse(require("fs").readFileSync(process.env.CLAIM_FILE,"utf8"));
    process.stdout.write(j.ownerSessionId===process.env.TARGET
      &&j.handoffEmitted===false&&j.transfer
      &&j.transfer.stage==="owner-retired"
      &&j.transfer.toOwnerSessionId===process.env.TARGET?"unseeded-transfer":"invalid");
  ')"
if zlog_for reset-transfer-unseeded-target --tdd-reset \
    --session reset-transfer-unseeded-target >/dev/null 2>&1; then
  RESET_TRANSFER_UNSEEDED_RC=0
else
  RESET_TRANSFER_UNSEEDED_RC=$?
fi
RESET_TRANSFER_UNSEEDED_CLAIM_GONE=false
[ ! -e "$CASE_STATE/pending-review.json.claim" ] && RESET_TRANSFER_UNSEEDED_CLAIM_GONE=true
RESET_TRANSFER_UNSEEDED_AFTER="$(stop reset-transfer-unseeded-target)"
RESET_TRANSFER_UNSEEDED_AFTER_RC=$?
if [ "$RESET_TRANSFER_UNSEEDED_BEFORE" = unseeded-transfer ] \
  && [ "$RESET_TRANSFER_UNSEEDED_RC" -eq 0 ] \
  && [ "$RESET_TRANSFER_UNSEEDED_CLAIM_GONE" = true ] \
  && [ "$(state_flag reset-transfer-unseeded-source active)" = false ] \
  && [ "$(state_flag reset-transfer-unseeded-target active)" = false ] \
  && [ "$RESET_TRANSFER_UNSEEDED_AFTER_RC" -eq 0 ] \
  && [ "$(printf '%s' "$RESET_TRANSFER_UNSEEDED_AFTER" | decision)" = allow ]; then
  check "C4s-transfer tdd-reset cancels an assigned unseeded transfer target" PASS
else
  check "C4s-transfer reset recovery (before=$RESET_TRANSFER_UNSEEDED_BEFORE rc=$RESET_TRANSFER_UNSEEDED_RC claim_gone=$RESET_TRANSFER_UNSEEDED_CLAIM_GONE source=$(state_flag reset-transfer-unseeded-source active) target=$(state_flag reset-transfer-unseeded-target active) after=$RESET_TRANSFER_UNSEEDED_AFTER_RC/$(printf '%s' "$RESET_TRANSFER_UNSEEDED_AFTER" | decision))" FAIL
fi

# A foreign superseded unseeded receipt removes only that old claim. Explicit
# reset then applies its initial current-state revision to the current session.
setup_case reset_foreign_superseded
RESET_FOREIGN_CURRENT=reset-foreign-superseded-current
RESET_FOREIGN_OWNER=reset-foreign-superseded-owner
zlog_for "$RESET_FOREIGN_CURRENT" --tdd-begin \
  --session "$RESET_FOREIGN_CURRENT" >/dev/null
zlog --pending-review --files reset-foreign-superseded.ts >/dev/null
fail_seed_after_assignment "$RESET_FOREIGN_OWNER" >/dev/null 2>&1 || true
RESET_FOREIGN_OWNER_KEY="$(canonical_session "$RESET_FOREIGN_OWNER")"
RESET_FOREIGN_OWNER_STATE="$CASE_STATE/tdd-phase-$RESET_FOREIGN_OWNER_KEY.json"
CLAIM_FILE="$CASE_STATE/pending-review.json.claim" \
  STATE_FILE="$RESET_FOREIGN_OWNER_STATE" node -e '
    const fs=require("fs");
    const claim=JSON.parse(fs.readFileSync(process.env.CLAIM_FILE,"utf8"));
    const state=JSON.parse(fs.readFileSync(process.env.STATE_FILE,"utf8"));
    claim.cancellation={
      schemaVersion:1,
      stage:"prepared",
      cancellationId:"drc_reset_foreign_superseded",
      claimId:claim.claimId,
      ownerSessionId:claim.ownerSessionId,
      mode:"reset",
      origin:"unseeded",
      ownerRevision:state.revision,
      clearedOwnerRevision:null,
      resetBinding:null,
    };
    fs.writeFileSync(process.env.CLAIM_FILE,`${JSON.stringify(claim,null,2)}\n`);
  '
CONTROL_CORE="$CORE" PROJECT_ROOT="$CASE_PROJECT" \
  OWNER_SESSION="$RESET_FOREIGN_OWNER_KEY" node -e '
    const core=require(process.env.CONTROL_CORE);
    const state=core.readWorkflowState({
      projectRoot:process.env.PROJECT_ROOT,
      sessionId:process.env.OWNER_SESSION,
    });
    core.mutateWorkflowState({
      projectRoot:process.env.PROJECT_ROOT,
      sessionId:process.env.OWNER_SESSION,
      workflowState:"red",
      event:"tdd-begin",
      expectedRevision:state.revision,
    },(draft)=>({...draft,active:true,implComplete:false}));
  '
if zlog_for "$RESET_FOREIGN_CURRENT" --tdd-reset \
    --session "$RESET_FOREIGN_CURRENT" >/dev/null 2>&1; then
  RESET_FOREIGN_RC=0
else
  RESET_FOREIGN_RC=$?
fi
if [ "$RESET_FOREIGN_RC" -eq 0 ] \
  && [ ! -e "$CASE_STATE/pending-review.json.claim" ] \
  && [ "$(state_flag "$RESET_FOREIGN_CURRENT" active)" = false ] \
  && [ "$(state_flag "$RESET_FOREIGN_OWNER" active)" = true ]; then
  check "C4sf foreign superseded receipt preserves foreign winner and resets current" PASS
else
  check "C4sf foreign superseded reset (rc=$RESET_FOREIGN_RC current=$(state_flag "$RESET_FOREIGN_CURRENT" active) foreign=$(state_flag "$RESET_FOREIGN_OWNER" active) claim=$([ -e "$CASE_STATE/pending-review.json.claim" ] && printf present || printf absent))" FAIL
fi

# Release reconciliation also treats a superseded old claim as complete, but
# never applies a generic reset to the fresh current generation that won.
setup_case release_current_superseded
zlog --pending-review --files release-current-superseded.ts >/dev/null
fail_seed_after_assignment release-current-superseded-owner >/dev/null 2>&1 || true
activate_session release-current-superseded-owner
RELEASE_SUPERSEDED_STATE="$CASE_STATE/tdd-phase-$ZENSU_SESSION_KEY.json"
CLAIM_FILE="$CASE_STATE/pending-review.json.claim" \
  STATE_FILE="$RELEASE_SUPERSEDED_STATE" node -e '
    const fs=require("fs");
    const claim=JSON.parse(fs.readFileSync(process.env.CLAIM_FILE,"utf8"));
    const state=JSON.parse(fs.readFileSync(process.env.STATE_FILE,"utf8"));
    claim.cancellation={
      schemaVersion:1,
      stage:"prepared",
      cancellationId:"drc_release_current_superseded",
      claimId:claim.claimId,
      ownerSessionId:claim.ownerSessionId,
      mode:"reset",
      origin:"unseeded",
      ownerRevision:state.revision,
      clearedOwnerRevision:null,
      resetBinding:null,
    };
    fs.writeFileSync(process.env.CLAIM_FILE,`${JSON.stringify(claim,null,2)}\n`);
  '
CONTROL_CORE="$CORE" PROJECT_ROOT="$CASE_PROJECT" \
  OWNER_SESSION="$ZENSU_SESSION_KEY" node -e '
    const core=require(process.env.CONTROL_CORE);
    const state=core.readWorkflowState({projectRoot:process.env.PROJECT_ROOT,sessionId:process.env.OWNER_SESSION});
    core.mutateWorkflowState({
      projectRoot:process.env.PROJECT_ROOT,
      sessionId:process.env.OWNER_SESSION,
      workflowState:"red",
      event:"tdd-begin",
      expectedRevision:state.revision,
    },(draft)=>({...draft,active:true,implComplete:false}));
  '
if (
  # shellcheck disable=SC1090
  source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
  tdd_release_pending_review_claim "$ZENSU_SESSION_KEY"
); then
  RELEASE_SUPERSEDED_RC=0
else
  RELEASE_SUPERSEDED_RC=$?
fi
if [ "$RELEASE_SUPERSEDED_RC" -eq 0 ] \
  && [ ! -e "$CASE_STATE/pending-review.json.claim" ] \
  && [ "$(state_flag release-current-superseded-owner active)" = true ]; then
  check "C4sr release accepts superseded claim without resetting its winner" PASS
else
  check "C4sr superseded release (rc=$RELEASE_SUPERSEDED_RC active=$(state_flag release-current-superseded-owner active) claim=$([ -e "$CASE_STATE/pending-review.json.claim" ] && printf present || printf absent))" FAIL
fi

# If reset resumes an older release-only receipt, a concurrent fresh begin
# between receipt recovery and the follow-up idle reset must win by revision
# CAS. Reset fails closed and never erases that new generation.
setup_case reset_release_receipt_race
zlog --pending-review --files reset-release-race.ts >/dev/null
adopt reset-release-race-owner >/dev/null
activate_session reset-release-race-owner
CLAIM_FILE="$CASE_STATE/pending-review.json.claim" \
  STATE_FILE="$CASE_STATE/tdd-phase-$(canonical_session reset-release-race-owner).json" node -e '
    const fs=require("fs");
    const claim=JSON.parse(fs.readFileSync(process.env.CLAIM_FILE,"utf8"));
    const state=JSON.parse(fs.readFileSync(process.env.STATE_FILE,"utf8"));
    claim.cancellation={
      schemaVersion:1,
      stage:"prepared",
      cancellationId:"drc_reset_release_race",
      claimId:claim.claimId,
      ownerSessionId:claim.ownerSessionId,
      mode:"release-only",
      origin:"linked",
      ownerRevision:state.revision,
      clearedOwnerRevision:null,
      resetBinding:null,
    };
    fs.writeFileSync(process.env.CLAIM_FILE,`${JSON.stringify(claim,null,2)}\n`);
  '
RESET_RACE_MARKER="$CASE_ROOT/inner-window-race-injected"
if (
  export NODE_OPTIONS="--require=$PLUGIN_DIR/tests/structure/fixtures/deferred-reset-inner-race-preload.js"
  export ZENSU_TEST_RESET_INNER_RACE=1
  export ZENSU_TEST_RESET_INNER_RACE_MARKER="$RESET_RACE_MARKER"
  zlog_for reset-release-race-owner --tdd-reset \
    --session reset-release-race-owner >/dev/null 2>&1
); then
  RESET_RACE_RC=0
else
  RESET_RACE_RC=$?
fi
RESET_RACE_STATE="$(STATE_FILE="$CASE_STATE/tdd-phase-$(canonical_session reset-release-race-owner).json" node -e '
  const s=JSON.parse(require("fs").readFileSync(process.env.STATE_FILE,"utf8"));
  process.stdout.write(`${s.active}\t${s.last_event}`);
')"
RESET_RACE_TRACE="$(tr '\n' ' ' < "$RESET_RACE_MARKER" 2>/dev/null || true)"
if [ "$RESET_RACE_RC" -ne 0 ] \
  && [ "$RESET_RACE_TRACE" = "injected " ] \
  && [ "$RESET_RACE_STATE" = true$'\t'tdd-begin ] \
  && [ ! -e "$CASE_STATE/pending-review.json.claim" ]; then
  check "C4r stale reset CAS cannot erase a concurrent fresh generation" PASS
else
  check "C4r inner-window reset CAS preserves new generation (rc=$RESET_RACE_RC trace=$RESET_RACE_TRACE state=$RESET_RACE_STATE)" FAIL
fi

# A state-cleared cancellation receipt is already terminal. If a fresh begin
# wins after the helper's initial snapshot but before terminal claim removal,
# reset must retain that initial revision rather than adopting clear's refresh.
setup_case reset_terminal_cancellation_race
zlog --pending-review --files reset-terminal-cancellation-race.ts >/dev/null
adopt reset-terminal-cancellation-owner >/dev/null
activate_session reset-terminal-cancellation-owner
CONTROL_CORE="$CORE" PROJECT_ROOT="$CASE_PROJECT" \
  OWNER_SESSION="$ZENSU_SESSION_KEY" \
  CLAIM_FILE="$CASE_STATE/pending-review.json.claim" node -e '
    const fs=require("fs");
    const core=require(process.env.CONTROL_CORE);
    const claim=JSON.parse(fs.readFileSync(process.env.CLAIM_FILE,"utf8"));
    const state=core.readWorkflowState({projectRoot:process.env.PROJECT_ROOT,sessionId:process.env.OWNER_SESSION});
    const cancellationId="drc_terminal_cancellation_race";
    const marker={
      schemaVersion:1,
      cancellationId,
      claimId:claim.claimId,
      ownerSessionId:claim.ownerSessionId,
      mode:"release-only",
      origin:"linked",
      sourceRevision:state.revision,
      resultRevision:state.revision+1,
      resetBinding:null,
    };
    const cleared=core.mutateWorkflowState({
      projectRoot:process.env.PROJECT_ROOT,
      sessionId:process.env.OWNER_SESSION,
      workflowState:state.workflow_state,
      event:"deferred-review-release",
      expectedRevision:state.revision,
    },(draft)=>({...draft,deferredReviewClaim:"",deferredReviewCancellation:marker}));
    claim.cancellation={
      schemaVersion:1,
      stage:"state-cleared",
      cancellationId,
      claimId:claim.claimId,
      ownerSessionId:claim.ownerSessionId,
      mode:"release-only",
      origin:"linked",
      ownerRevision:state.revision,
      clearedOwnerRevision:cleared.revision,
      resetBinding:null,
    };
    fs.writeFileSync(process.env.CLAIM_FILE,`${JSON.stringify(claim,null,2)}\n`);
  '
TERMINAL_CANCEL_RACE_MARKER="$CASE_ROOT/terminal-cancellation-race-injected"
if (
  export NODE_OPTIONS="--require=$PLUGIN_DIR/tests/structure/fixtures/deferred-reset-inner-race-preload.js"
  export ZENSU_TEST_RESET_INNER_RACE=1
  export ZENSU_TEST_RESET_INNER_RACE_OPERATION=clear
  export ZENSU_TEST_RESET_INNER_RACE_MARKER="$TERMINAL_CANCEL_RACE_MARKER"
  zlog_for reset-terminal-cancellation-owner --tdd-reset \
    --session reset-terminal-cancellation-owner >/dev/null 2>&1
); then
  TERMINAL_CANCEL_RACE_RC=0
else
  TERMINAL_CANCEL_RACE_RC=$?
fi
TERMINAL_CANCEL_RACE_TRACE="$(tr '\n' ' ' < "$TERMINAL_CANCEL_RACE_MARKER" 2>/dev/null || true)"
TERMINAL_CANCEL_RACE_STATE="$(STATE_FILE="$CASE_STATE/tdd-phase-$(canonical_session reset-terminal-cancellation-owner).json" node -e '
  const s=JSON.parse(require("fs").readFileSync(process.env.STATE_FILE,"utf8"));
  process.stdout.write(`${s.active}\t${s.last_event}`);
')"
if [ "$TERMINAL_CANCEL_RACE_RC" -ne 0 ] \
  && [ "$TERMINAL_CANCEL_RACE_TRACE" = "injected " ] \
  && [ "$TERMINAL_CANCEL_RACE_STATE" = true$'\t'tdd-begin ] \
  && [ ! -e "$CASE_STATE/pending-review.json.claim" ]; then
  check "C4rc terminal cancellation clear cannot lend fresh revision to reset" PASS
else
  check "C4rc terminal cancellation race (rc=$TERMINAL_CANCEL_RACE_RC trace=$TERMINAL_CANCEL_RACE_TRACE state=$TERMINAL_CANCEL_RACE_STATE claim=$([ -e "$CASE_STATE/pending-review.json.claim" ] && printf present || printf absent))" FAIL
fi

# The same revision rule applies to an ordinary cancelled claim left after the
# done-state CAS. A fresh begin before artifact removal must survive reset.
setup_case reset_ordinary_cancelled_race
zlog --pending-review --files reset-ordinary-cancelled-race.ts >/dev/null
stop reset-ordinary-cancelled-owner >/dev/null
zlog_for reset-ordinary-cancelled-owner --chain-done \
  --session reset-ordinary-cancelled-owner >/dev/null
activate_session reset-ordinary-cancelled-owner
CONTROL_CORE="$CORE" PROJECT_ROOT="$CASE_PROJECT" \
  OWNER_SESSION="$ZENSU_SESSION_KEY" node -e '
    const core=require(process.env.CONTROL_CORE);
    const state=core.readWorkflowState({projectRoot:process.env.PROJECT_ROOT,sessionId:process.env.OWNER_SESSION});
    core.mutateWorkflowState({
      projectRoot:process.env.PROJECT_ROOT,
      sessionId:process.env.OWNER_SESSION,
      workflowState:state.workflow_state,
      event:"deferred-review-complete",
      expectedRevision:state.revision,
    },(draft)=>({...draft,deferredReviewClaim:""}));
  '
ORDINARY_CANCEL_RACE_MARKER="$CASE_ROOT/ordinary-cancelled-race-injected"
if (
  export NODE_OPTIONS="--require=$PLUGIN_DIR/tests/structure/fixtures/deferred-reset-inner-race-preload.js"
  export ZENSU_TEST_RESET_INNER_RACE=1
  export ZENSU_TEST_RESET_INNER_RACE_OPERATION=clear
  export ZENSU_TEST_RESET_INNER_RACE_MARKER="$ORDINARY_CANCEL_RACE_MARKER"
  zlog_for reset-ordinary-cancelled-owner --tdd-reset \
    --session reset-ordinary-cancelled-owner >/dev/null 2>&1
); then
  ORDINARY_CANCEL_RACE_RC=0
else
  ORDINARY_CANCEL_RACE_RC=$?
fi
ORDINARY_CANCEL_RACE_TRACE="$(tr '\n' ' ' < "$ORDINARY_CANCEL_RACE_MARKER" 2>/dev/null || true)"
ORDINARY_CANCEL_RACE_STATE="$(STATE_FILE="$CASE_STATE/tdd-phase-$(canonical_session reset-ordinary-cancelled-owner).json" node -e '
  const s=JSON.parse(require("fs").readFileSync(process.env.STATE_FILE,"utf8"));
  process.stdout.write(`${s.active}\t${s.last_event}`);
')"
if [ "$ORDINARY_CANCEL_RACE_RC" -ne 0 ] \
  && [ "$ORDINARY_CANCEL_RACE_TRACE" = "injected " ] \
  && [ "$ORDINARY_CANCEL_RACE_STATE" = true$'\t'tdd-begin ] \
  && [ ! -e "$CASE_STATE/pending-review.json.claim" ]; then
  check "C4ro ordinary cancelled clear cannot lend fresh revision to reset" PASS
else
  check "C4ro ordinary cancelled race (rc=$ORDINARY_CANCEL_RACE_RC trace=$ORDINARY_CANCEL_RACE_TRACE state=$ORDINARY_CANCEL_RACE_STATE claim=$([ -e "$CASE_STATE/pending-review.json.claim" ] && printf present || printf absent))" FAIL
fi

# A terminal reset receipt with the same standalone binding is an idempotency
# receipt. A later same-binding begin wins, so recovery removes only the old
# claim artifact and deliberately does not issue a second reset.
setup_case reset_receipt_same_binding
zlog --pending-review --files reset-receipt-same-binding.ts >/dev/null
adopt reset-receipt-same-binding-owner >/dev/null
write_state_cleared_reset_receipt reset-receipt-same-binding-owner null \
  drc_reset_receipt_same_binding
zlog_for reset-receipt-same-binding-owner --tdd-begin \
  --session reset-receipt-same-binding-owner >/dev/null
if zlog_for reset-receipt-same-binding-owner --tdd-reset \
    --session reset-receipt-same-binding-owner >/dev/null 2>&1; then
  RESET_RECEIPT_SAME_RC=0
else
  RESET_RECEIPT_SAME_RC=$?
fi
RESET_RECEIPT_SAME_STATE="$(STATE_FILE="$CASE_STATE/tdd-phase-$(canonical_session reset-receipt-same-binding-owner).json" node -e '
  const s=JSON.parse(require("fs").readFileSync(process.env.STATE_FILE,"utf8"));
  process.stdout.write(`${s.active}\t${s.last_event}`);
')"
if [ "$RESET_RECEIPT_SAME_RC" -eq 0 ] \
  && [ "$RESET_RECEIPT_SAME_STATE" = true$'\t'tdd-begin ] \
  && [ ! -e "$CASE_STATE/pending-review.json.claim" ]; then
  check "C4ri same-binding terminal reset receipt is idempotent" PASS
else
  check "C4ri same-binding terminal receipt (rc=$RESET_RECEIPT_SAME_RC state=$RESET_RECEIPT_SAME_STATE claim=$([ -e "$CASE_STATE/pending-review.json.claim" ] && printf present || printf absent))" FAIL
fi

# A reset receipt for bound generation A cannot satisfy an explicit reset of a
# fresh generation B. Recover A, then apply the generic reset to the initial B
# revision that was observed before terminal claim removal.
setup_case reset_receipt_binding_mismatch
RESET_RECEIPT_MISMATCH_SID=reset-receipt-binding-mismatch-owner
zlog --pending-review --files reset-receipt-binding-mismatch.ts >/dev/null
adopt "$RESET_RECEIPT_MISMATCH_SID" >/dev/null
write_state_cleared_reset_receipt "$RESET_RECEIPT_MISMATCH_SID" \
  '{"chainId":"chain-receipt-old-001","attempt":1,"runId":"run_receipt_old"}' \
  drc_reset_receipt_binding_mismatch
begin_bound_inner "$RESET_RECEIPT_MISMATCH_SID" \
  run_receipt_new 2 chain-receipt-new-002 >/dev/null
if reset_bound_inner "$RESET_RECEIPT_MISMATCH_SID" \
    run_receipt_new 2 chain-receipt-new-002 >/dev/null 2>&1; then
  RESET_RECEIPT_MISMATCH_RC=0
else
  RESET_RECEIPT_MISMATCH_RC=$?
fi
RESET_RECEIPT_MISMATCH_STATE="$(STATE_FILE="$CASE_STATE/tdd-phase-$(canonical_session "$RESET_RECEIPT_MISMATCH_SID").json" node -e '
  const s=JSON.parse(require("fs").readFileSync(process.env.STATE_FILE,"utf8"));
  process.stdout.write(`${s.active}\t${s.last_event}\t${s.autopilotRunId||"none"}`);
')"
if [ "$RESET_RECEIPT_MISMATCH_RC" -eq 0 ] \
  && [ "$RESET_RECEIPT_MISMATCH_STATE" = false$'\t'autopilot-reset$'\t'none ] \
  && [ ! -e "$CASE_STATE/pending-review.json.claim" ]; then
  check "C4rib terminal reset receipt cannot mask a newer bound generation" PASS
else
  check "C4rib terminal binding mismatch (rc=$RESET_RECEIPT_MISMATCH_RC state=$RESET_RECEIPT_MISMATCH_STATE claim=$([ -e "$CASE_STATE/pending-review.json.claim" ] && printf present || printf absent))" FAIL
fi

# The prepared-unseeded superseded path follows the same idempotency rule. A
# field-wise equal binding (even with a different JSON key order) preserves the
# newer same-bound revision after removing the obsolete claim.
setup_case reset_superseded_same_binding
RESET_SUPERSEDED_SAME_SID=reset-superseded-same-binding-owner
zlog --pending-review --files reset-superseded-same-binding.ts >/dev/null
fail_seed_after_assignment "$RESET_SUPERSEDED_SAME_SID" >/dev/null 2>&1 || true
write_prepared_unseeded_reset_receipt "$RESET_SUPERSEDED_SAME_SID" \
  '{"chainId":"chain-superseded-same-001","attempt":1,"runId":"run_superseded_same"}' \
  drc_reset_superseded_same_binding
begin_bound_inner "$RESET_SUPERSEDED_SAME_SID" \
  run_superseded_same 1 chain-superseded-same-001 >/dev/null
if reset_bound_inner "$RESET_SUPERSEDED_SAME_SID" \
    run_superseded_same 1 chain-superseded-same-001 >/dev/null 2>&1; then
  RESET_SUPERSEDED_SAME_RC=0
else
  RESET_SUPERSEDED_SAME_RC=$?
fi
RESET_SUPERSEDED_SAME_STATE="$(STATE_FILE="$CASE_STATE/tdd-phase-$(canonical_session "$RESET_SUPERSEDED_SAME_SID").json" node -e '
  const s=JSON.parse(require("fs").readFileSync(process.env.STATE_FILE,"utf8"));
  process.stdout.write(`${s.active}\t${s.last_event}\t${s.autopilotRunId||"none"}`);
')"
if [ "$RESET_SUPERSEDED_SAME_RC" -eq 0 ] \
  && [ "$RESET_SUPERSEDED_SAME_STATE" = true$'\t'tdd-begin$'\t'run_superseded_same ] \
  && [ ! -e "$CASE_STATE/pending-review.json.claim" ]; then
  check "C4ris same-binding superseded reset receipt is idempotent" PASS
else
  check "C4ris same-binding superseded receipt (rc=$RESET_SUPERSEDED_SAME_RC state=$RESET_SUPERSEDED_SAME_STATE claim=$([ -e "$CASE_STATE/pending-review.json.claim" ] && printf present || printf absent))" FAIL
fi

# A superseded prepared receipt for A is not an idempotency receipt for B. Its
# old claim is removed first, then the generic expected-revision CAS resets B.
setup_case reset_superseded_binding_mismatch
RESET_SUPERSEDED_MISMATCH_SID=reset-superseded-binding-mismatch-owner
zlog --pending-review --files reset-superseded-binding-mismatch.ts >/dev/null
fail_seed_after_assignment "$RESET_SUPERSEDED_MISMATCH_SID" >/dev/null 2>&1 || true
write_prepared_unseeded_reset_receipt "$RESET_SUPERSEDED_MISMATCH_SID" \
  '{"chainId":"chain-superseded-old-001","attempt":1,"runId":"run_superseded_old"}' \
  drc_reset_superseded_binding_mismatch
begin_bound_inner "$RESET_SUPERSEDED_MISMATCH_SID" \
  run_superseded_new 2 chain-superseded-new-002 >/dev/null
if reset_bound_inner "$RESET_SUPERSEDED_MISMATCH_SID" \
    run_superseded_new 2 chain-superseded-new-002 >/dev/null 2>&1; then
  RESET_SUPERSEDED_MISMATCH_RC=0
else
  RESET_SUPERSEDED_MISMATCH_RC=$?
fi
RESET_SUPERSEDED_MISMATCH_STATE="$(STATE_FILE="$CASE_STATE/tdd-phase-$(canonical_session "$RESET_SUPERSEDED_MISMATCH_SID").json" node -e '
  const s=JSON.parse(require("fs").readFileSync(process.env.STATE_FILE,"utf8"));
  process.stdout.write(`${s.active}\t${s.last_event}\t${s.autopilotRunId||"none"}`);
')"
if [ "$RESET_SUPERSEDED_MISMATCH_RC" -eq 0 ] \
  && [ "$RESET_SUPERSEDED_MISMATCH_STATE" = false$'\t'autopilot-reset$'\t'none ] \
  && [ ! -e "$CASE_STATE/pending-review.json.claim" ]; then
  check "C4risb superseded reset receipt cannot mask a newer bound generation" PASS
else
  check "C4risb superseded binding mismatch (rc=$RESET_SUPERSEDED_MISMATCH_RC state=$RESET_SUPERSEDED_MISMATCH_STATE claim=$([ -e "$CASE_STATE/pending-review.json.claim" ] && printf present || printf absent))" FAIL
fi

setup_case reset_cancel
zlog --pending-review --files reset.ts >/dev/null
OUT="$(stop reset-owner)"
zlog_for reset-owner --tdd-reset --session reset-owner >/dev/null
AFTER_RESET="$(stop reset-owner)"; AFTER_RESET_RC=$?
if [ "$(printf '%s' "$OUT" | decision)" = block ] \
  && [ "$AFTER_RESET_RC" -eq 0 ] \
  && [ "$(printf '%s' "$AFTER_RESET" | decision)" = allow ] \
  && [ ! -e "$CASE_STATE/pending-review.json.claim" ] \
  && [ "$(state_flag reset-owner active)" = false ]; then
  check "C4 tdd-reset cancels rather than resurrects a retained claim" PASS
else
  check "C4 tdd-reset cancels rather than resurrects a retained claim" FAIL
fi

# A marker queued behind a completed ownership claim is adopted during the
# same terminal Stop, so no only-chance Stop releases with pending work.
setup_case queued
zlog --pending-review --files first.ts >/dev/null
FIRST="$(stop queued-owner)"
zlog --pending-review --files second.ts >/dev/null
zlog_for queued-owner --chain-done --session queued-owner >/dev/null
SECOND="$(stop queued-owner)"
if [ "$(printf '%s' "$FIRST" | decision)" = block ] \
  && [ "$(printf '%s' "$SECOND" | decision)" = block ] \
  && [ ! -e "$CASE_STATE/pending-review.json" ] \
  && [ "$(state_flag queued-owner chainDone)" = false ]; then
  check "C5 terminal Stop immediately adopts a marker queued behind its claim" PASS
else
  check "C5 terminal Stop immediately adopts a marker queued behind its claim" FAIL
fi

# The anti-deadlock escape releases ownership so it cannot shadow future
# project reviews forever.
setup_case cap '{"hooks":{"autoFixMaxRounds":1}}'
zlog --pending-review --files capped.ts >/dev/null
CAP_SID=cap-owner
stop "$CAP_SID" >/dev/null
stop "$CAP_SID" >/dev/null
stop "$CAP_SID" >/dev/null
stop "$CAP_SID" >/dev/null
CAP_OUT="$(stop "$CAP_SID")"; CAP_OUT_RC=$?
if [ "$CAP_OUT_RC" -eq 0 ] \
  && [ "$(printf '%s' "$CAP_OUT" | decision)" = allow ] \
  && [ ! -e "$CASE_STATE/pending-review.json.claim" ] \
  && [ "$(state_flag "$CAP_SID" active)" = true ] \
  && [ "$(state_flag "$CAP_SID" implComplete)" = true ]; then
  check "C6 Stop-cap release-only preserves the active deferred generation" PASS
else
  check "C6 Stop-cap release-only preserves the active deferred generation" FAIL
fi

# A terminal ticket remains rearmable after release-only cap cancellation.
setup_case cap_rearm '{"hooks":{"autoFixMaxRounds":1}}'
REARM_SID=cap-rearm-owner
zlog --pending-review --files capped-rearm.ts >/dev/null
stop "$REARM_SID" >/dev/null
REARM_TICKET="$(zlog_for "$REARM_SID" --review-ticket --session "$REARM_SID")"
if (
  activate_session "$REARM_SID" || exit 1
  # shellcheck disable=SC1090
  source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
  tdd_consume_review_ticket "$ZENSU_SESSION_KEY" "$REARM_TICKET" >/dev/null
); then REARM_CONSUME_RC=0; else REARM_CONSUME_RC=$?; fi
if zlog_for "$REARM_SID" --code-review-done --session "$REARM_SID" \
    --claimed-review-ticket "$REARM_TICKET" >/dev/null; then
  REARM_CODE_DONE_RC=0
else
  REARM_CODE_DONE_RC=$?
fi
stop "$REARM_SID" >/dev/null
stop "$REARM_SID" >/dev/null
stop "$REARM_SID" >/dev/null
REARM_CAP_OUT="$(stop "$REARM_SID")"; REARM_CAP_RC=$?
REARM_PRESERVED="$(STATE_FILE="$CASE_STATE/tdd-phase-$(canonical_session "$REARM_SID").json" \
  TICKET="$REARM_TICKET" node -e '
    const s=JSON.parse(require("fs").readFileSync(process.env.STATE_FILE,"utf8"));
    process.stdout.write(String(s.active===true&&s.implComplete===true&&s.codeReviewDone===true
      &&s.reviewTicket===process.env.TICKET&&s.reviewTicketConsumed===true));
')"
if zlog_for "$REARM_SID" --review-rearm --session "$REARM_SID" \
    --claimed-review-ticket "$REARM_TICKET" >/dev/null 2>&1; then
  REARM_RC=0
else
  REARM_RC=$?
fi
if [ "$REARM_CAP_RC" -eq 0 ] \
  && [ "$(printf '%s' "$REARM_CAP_OUT" | decision)" = allow ] \
  && [ "$REARM_CONSUME_RC" -eq 0 ] \
  && [ "$REARM_CODE_DONE_RC" -eq 0 ] \
  && [ "$REARM_PRESERVED" = true ] \
  && [ "$REARM_RC" -eq 0 ] \
  && [ "$(state_flag "$REARM_SID" active)" = true ] \
  && [ "$(state_flag "$REARM_SID" stopBlockCount)" = 0 ] \
  && [ "$(state_flag "$REARM_SID" codeReviewDone)" = false ]; then
  check "C6a cap preserves the consumed ticket and reset-review-limit re-arms it" PASS
else
  check "C6a cap ticket rearm (cap_rc=$REARM_CAP_RC consume=$REARM_CONSUME_RC code_done=$REARM_CODE_DONE_RC preserved=$REARM_PRESERVED rearm_rc=$REARM_RC)" FAIL
fi

# A malformed/replaced claim at the cap is never treated as successful
# cancellation. Stop remains blocked and exact bytes remain for repair.
setup_case cap_cancel_failure '{"hooks":{"autoFixMaxRounds":1}}'
CAP_FAIL_SID=cap-failure-owner
zlog --pending-review --files cap-failure.ts >/dev/null
stop "$CAP_FAIL_SID" >/dev/null
stop "$CAP_FAIL_SID" >/dev/null
stop "$CAP_FAIL_SID" >/dev/null
stop "$CAP_FAIL_SID" >/dev/null
printf '%s\n' '{malformed-cap-claim' > "$CASE_STATE/pending-review.json.claim"
cp "$CASE_STATE/pending-review.json.claim" "$CASE_ROOT/cap-failure.before"
CAP_FAIL_OUT="$(stop "$CAP_FAIL_SID")"; CAP_FAIL_RC=$?
if [ "$CAP_FAIL_RC" -eq 0 ] \
  && [ "$(printf '%s' "$CAP_FAIL_OUT" | decision)" = block ] \
  && printf '%s' "$(printf '%s' "$CAP_FAIL_OUT" | reason)" | grep -q "cancellation receipt" \
  && cmp -s "$CASE_ROOT/cap-failure.before" "$CASE_STATE/pending-review.json.claim" \
  && [ "$(state_flag "$CAP_FAIL_SID" active)" = true ]; then
  check "C6b cap cancellation failure blocks and preserves the claim" PASS
else
  check "C6b cap cancellation failure remains fail-closed" FAIL
fi

# Transferring an expired emitted claim renews its lease. The freshly informed
# owner must retain it until that renewed lease itself expires; otherwise every
# unrelated Stop can immediately retire the recovery session before it reviews.
setup_case lease_refresh '{"hooks":{"pendingReviewTtlHours":1}}'
zlog --pending-review --files leased.ts >/dev/null
LEASE_A="$(stop lease-a)"
LEASE_CLAIM="$CASE_STATE/pending-review.json.claim"
CLAIM_FILE="$LEASE_CLAIM" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.env.CLAIM_FILE, "utf8"));
  j.ts = "2020-01-01T00:00:00Z";
  fs.writeFileSync(process.env.CLAIM_FILE, JSON.stringify(j, null, 2));
'
LEASE_B="$(stop lease-b)"
LEASE_B_TS="$(CLAIM_FILE="$LEASE_CLAIM" node -e '
  const j = JSON.parse(require("fs").readFileSync(process.env.CLAIM_FILE, "utf8"));
  process.stdout.write(typeof j.ts === "string" ? j.ts : "");
')"
LEASE_C_FRESH="$(stop lease-c)"; LEASE_C_FRESH_RC=$?
CLAIM_FILE="$LEASE_CLAIM" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.env.CLAIM_FILE, "utf8"));
  j.ts = "2020-01-01T00:00:00Z";
  fs.writeFileSync(process.env.CLAIM_FILE, JSON.stringify(j, null, 2));
'
LEASE_C_EXPIRED="$(stop lease-c)"
if [ "$(printf '%s' "$LEASE_A" | decision)" = block ] \
  && [ "$(printf '%s' "$LEASE_B" | decision)" = block ] \
  && [ -n "$LEASE_B_TS" ] && [ "$LEASE_B_TS" != "2020-01-01T00:00:00Z" ] \
  && [ "$LEASE_C_FRESH_RC" -eq 0 ] \
  && [ "$(printf '%s' "$LEASE_C_FRESH" | decision)" = allow ] \
  && [ "$(printf '%s' "$LEASE_C_EXPIRED" | decision)" = block ] \
  && [ "$(state_flag lease-b active)" = false ] \
  && [ "$(state_flag lease-c active)" = true ]; then
  check "C7 transferred claim renews timestamp lease before another session may adopt" PASS
else
  check "C7 transferred claim renews timestamp lease before another session may adopt" FAIL
fi

# timestampStyle:none deliberately persists no wall-clock timestamp. Assignment
# must therefore remove any inherited ts and renew the lease through the atomic
# replacement's mtime, with the same fresh-then-expired transfer behavior.
setup_case lease_refresh_none '{"hooks":{"pendingReviewTtlHours":1},"logging":{"timestampStyle":"none"}}'
zlog --pending-review --files leased-none.ts >/dev/null
LEASE_NONE_A="$(stop lease-none-a)"
LEASE_NONE_CLAIM="$CASE_STATE/pending-review.json.claim"
CLAIM_FILE="$LEASE_NONE_CLAIM" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.env.CLAIM_FILE, "utf8"));
  j.ts = "2020-01-01T00:00:00Z";
  fs.writeFileSync(process.env.CLAIM_FILE, JSON.stringify(j, null, 2));
'
LEASE_NONE_B="$(stop lease-none-b)"
LEASE_NONE_HAS_TS="$(CLAIM_FILE="$LEASE_NONE_CLAIM" node -e '
  const j = JSON.parse(require("fs").readFileSync(process.env.CLAIM_FILE, "utf8"));
  process.stdout.write(Object.prototype.hasOwnProperty.call(j, "ts") ? "yes" : "no");
')"
LEASE_NONE_C_FRESH="$(stop lease-none-c)"; LEASE_NONE_C_FRESH_RC=$?
touch -t 202001010000 "$LEASE_NONE_CLAIM" 2>/dev/null
LEASE_NONE_C_EXPIRED="$(stop lease-none-c)"
if [ "$(printf '%s' "$LEASE_NONE_A" | decision)" = block ] \
  && [ "$(printf '%s' "$LEASE_NONE_B" | decision)" = block ] \
  && [ "$LEASE_NONE_HAS_TS" = no ] \
  && [ "$LEASE_NONE_C_FRESH_RC" -eq 0 ] \
  && [ "$(printf '%s' "$LEASE_NONE_C_FRESH" | decision)" = allow ] \
  && [ "$(printf '%s' "$LEASE_NONE_C_EXPIRED" | decision)" = block ] \
  && [ "$(state_flag lease-none-b active)" = false ] \
  && [ "$(state_flag lease-none-c active)" = true ]; then
  check "C8 timestampStyle none renews claim lease through mtime" PASS
else
  check "C8 timestampStyle none renews claim lease through mtime" FAIL
fi

echo "----"
echo "test-deferred-review-claim: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
