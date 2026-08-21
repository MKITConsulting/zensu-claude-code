#!/bin/bash
# Autopilot owns the one planning gate; standalone plans keep ask-first routing.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/plan-approved-delegate.sh"
LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"
HOST_PATH="$PLUGIN_DIR/hooks/lib/zensu-host-path.sh"
PASS=0; FAIL=0
check() { if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }

[ -f "$HOOK" ] && bash -n "$HOOK" 2>/dev/null && check "P1 plan hook exists and parses" PASS || check "P1 plan hook exists and parses" FAIL
[ -f "$LIB" ] && bash -n "$LIB" 2>/dev/null && check "P2 state library exists and parses" PASS || { check "P2 state library exists and parses" FAIL; exit 1; }
source "$LIB"

review_marker() {
  local operation_key="$1" head_sha="$2" payload_digest="$3"
  OPERATION_KEY="$operation_key" HEAD_SHA="$head_sha" PAYLOAD_DIGEST="$payload_digest" node -e '
    const crypto=require("crypto");
    const op=crypto.createHash("sha256").update(process.env.OPERATION_KEY).digest("hex");
    process.stdout.write(`<!-- zensu-review:v1:${op}:${process.env.PAYLOAD_DIGEST}:${process.env.HEAD_SHA.toLowerCase()}:1:part=1/1 -->`);
  '
}

RAW_TMP="$(mktemp -d -t zensu-autopilot-plan-XXXXXX)"
RAW_TMP="$(cd -P -- "$RAW_TMP" && pwd -P)"
TMP="$(bash "$HOST_PATH" "$RAW_TMP")" || exit 1
trap 'rm -rf "$RAW_TMP"' EXIT
PROJECT="$TMP/project"; mkdir -p "$PROJECT"
provision_session() {
  local project="$1" raw_session="$2" label="$3"
  export CLAUDE_PROJECT_DIR="$project"
  export ZENSU_TEST_PLUGIN_DATA="$TMP/plugin-data/$label"
  # shellcheck disable=SC1090
  source "$BASELINE" "$raw_session" || return 1
  PROVISIONED_KEY="$ZENSU_SESSION_KEY"
  PROVISIONED_DATA="$CLAUDE_PLUGIN_DATA"
}

RUN="plan_run_01"; SID_RAW="plan_session_01"
provision_session "$PROJECT" "$SID_RAW" main || exit 1
SID="$PROVISIONED_KEY"; MAIN_DATA="$PROVISIONED_DATA"
PLAN="# Approved feature\n\nImplement it.\n\n<!-- zensu-autopilot:${RUN} -->"
autopilot_begin_run "$RUN" "$SID" "$PROJECT" >/dev/null || exit 1
CFG_OFF="$TMP/off.json"; printf '%s\n' '{"hooks":{"autoTdd":false}}' > "$CFG_OFF"

# The delegation contract is asserted on the shape the CURRENT harness delivers:
# it strips the ExitPlanMode input fields its schema does not declare, so the
# approved plan travels in the tool response. `payload_input_dialect` keeps the
# legacy carrier covered for hosts that do declare those fields.
payload() {
  PLAN="$1" SID="$2" node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PostToolUse",session_id:process.env.SID,tool_name:"ExitPlanMode",tool_input:{_targetMode:"auto"},tool_response:{plan:process.env.PLAN,isAgent:false,hasTaskTool:true}}))'
}
payload_input_dialect() {
  PLAN="$1" SID="$2" node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PostToolUse",session_id:process.env.SID,tool_name:"ExitPlanMode",tool_input:{plan:process.env.PLAN}}))'
}
invoke() {
  local input="$1" project="$2" config="${3:-$CFG_OFF}" plugin_data="$4"
  (
    printf '%s' "$input" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY \
      -u ZENSU_SESSION_CONTEXT -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$plugin_data" \
      CLAUDE_PROJECT_DIR="$project" ZENSU_CONFIG="$config" bash "$HOOK" 2>/dev/null
  )
}
digest() { node -e 'const fs=require("fs"),crypto=require("crypto");process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$1"; }
RUN_FILE="$(autopilot_run_file "$RUN" "$PROJECT")"

OUT="$(invoke "$(payload "$PLAN" "$SID_RAW")" "$PROJECT" "$CFG_OFF" "$MAIN_DATA")"
if printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{const j=JSON.parse(s),t=j.hookSpecificOutput.additionalContext;process.exit(j.hookSpecificOutput.hookEventName==="PostToolUse"&&t.includes("PLAN_APPROVED")&&t.includes("skill=\u0027zensu:tdd\u0027")&&!t.includes("AskUserQuestion")?0:1)}catch(_){process.exit(1)}})'; then
  check "P3 approved Autopilot plan delegates directly without a routine question" PASS
else check "P3 approved Autopilot plan delegates directly without a routine question" FAIL; fi

EXPECTED_SHA="$(printf '%s' "$PLAN" | node -e 'const fs=require("fs"),crypto=require("crypto");process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(0)).digest("hex"));')"
if RUN_FILE="$RUN_FILE" SHA="$EXPECTED_SHA" node -e 'const j=require(process.env.RUN_FILE);process.exit(j.stage==="AWAIT_TDD"&&j.nextActionCode==="START_TDD"&&j.approvedPlanSha256===process.env.SHA?0:1)'; then
  check "P4 approval persists the exact plan digest and AWAIT_TDD stage" PASS
else check "P4 approval persists the exact plan digest and AWAIT_TDD stage" FAIL; fi

BEFORE="$(digest "$RUN_FILE")"; OUT_REPEAT="$(invoke "$(payload "$PLAN" "$SID_RAW")" "$PROJECT" "$CFG_OFF" "$MAIN_DATA")"; AFTER="$(digest "$RUN_FILE")"
[ "$OUT_REPEAT" = "$OUT" ] && [ "$BEFORE" = "$AFTER" ] \
  && check "P5 repeated ExitPlanMode delivery is byte-stable" PASS \
  || check "P5 repeated ExitPlanMode delivery is byte-stable" FAIL

PLAN_CONTEXT="$(printf '%s' "$OUT" | node -e '
  try{process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).hookSpecificOutput.additionalContext)}
  catch(_){process.exit(1)}
')"
PLAN_HELPER_Q="$(printf '%q' "$PLUGIN_DIR/hooks/lib/zensu-log.sh")"
PLAN_DATA_Q="$(printf '%q' "$MAIN_DATA")"
PLAN_EXPECTED_COMMAND="CLAUDE_PLUGIN_DATA=$PLAN_DATA_Q bash $PLAN_HELPER_Q --tdd-begin --session $SID --autopilot-run $RUN --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id <chain-id>"
PLAN_MSYS_EXCL="EXPECTED"
[ -z "${MSYS2_ENV_CONV_EXCL:-}" ] || PLAN_MSYS_EXCL="${MSYS2_ENV_CONV_EXCL};${PLAN_MSYS_EXCL}"
PLAN_EMITTED_COMMAND="$(printf '%s' "$PLAN_CONTEXT" | MSYS2_ENV_CONV_EXCL="$PLAN_MSYS_EXCL" EXPECTED="$PLAN_EXPECTED_COMMAND" node -e '
  const body=require("fs").readFileSync(0,"utf8"),expected=process.env.EXPECTED;
  const at=body.indexOf(expected);if(at<0)process.exit(1);
  process.stdout.write(body.slice(at,at+expected.length));
')"
PLAN_EXTRACT_RC=$?
PLAN_EXEC_COMMAND="${PLAN_EMITTED_COMMAND/<chain-id>/plan-retry-chain-01}"
CLAUDE_CODE_SESSION_ID="$SID_RAW" CLAUDE_PROJECT_DIR="$PROJECT" eval "$PLAN_EXEC_COMMAND" >/dev/null 2>&1
PLAN_EXEC_RC=$?
if [ "$PLAN_EXTRACT_RC" = 0 ] && [ "$PLAN_EXEC_RC" = 0 ]; then
  check "P5a exact emitted TDD-begin command executes through native per-call binding" PASS
else
  check "P5a emitted TDD-begin command executes (extract=$PLAN_EXTRACT_RC exec=$PLAN_EXEC_RC)" FAIL
fi

autopilot_apply_event "$RUN" plan-retry-tdd-done TDD_CHAIN_DONE \
  "{\"attempt\":1,\"chainId\":\"plan-retry-chain-01\",\"sessionId\":\"$SID\",\"outcome\":\"pass\"}" "$PROJECT" >/dev/null
autopilot_apply_event "$RUN" plan-retry-gates-failed GATES_FAILED \
  '{"headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","reason":"retry fixture"}' "$PROJECT" >/dev/null
BEFORE_STALE="$(digest "$RUN_FILE")"
OUT_STALE="$(invoke "$(payload "$PLAN" "$SID_RAW")" "$PROJECT" "$CFG_OFF" "$MAIN_DATA")"
if printf '%s' "$OUT_STALE" | grep -qF -- '--autopilot-attempt 2 --autopilot-return-stage GATES' \
  && [ "$(digest "$RUN_FILE")" = "$BEFORE_STALE" ]; then
  check "P5b delayed plan replay delegates the durable next attempt instead of stale attempt 1" PASS
else check "P5b delayed plan replay uses durable attempt and return stage" FAIL; fi

BEFORE_OWNER="$(digest "$RUN_FILE")"
provision_session "$PROJECT" other_session foreign || exit 1
FOREIGN_DATA="$PROVISIONED_DATA"
OUT_OWNER="$(invoke "$(payload "$PLAN" other_session)" "$PROJECT" "$CFG_OFF" "$FOREIGN_DATA")"
if ! printf '%s' "$OUT_OWNER" | grep -qF 'ZENSU_AUTOPILOT' \
  && [ "$(digest "$RUN_FILE")" = "$BEFORE_OWNER" ]; then
  check "P6 a foreign session neither drives nor mutates another session's run" PASS
else check "P6 a foreign session neither drives nor mutates another session's run" FAIL; fi

BAD_PROJECT="$TMP/bad-project"; mkdir -p "$BAD_PROJECT"
provision_session "$BAD_PROJECT" bad_plan_session bad || exit 1
BAD_OWNER="$PROVISIONED_KEY"; BAD_DATA="$PROVISIONED_DATA"
autopilot_begin_run bad_plan_run "$BAD_OWNER" "$BAD_PROJECT" >/dev/null || exit 1
BAD_OUT="$(invoke "$(payload '# no bound marker' bad_plan_session)" "$BAD_PROJECT" "$CFG_OFF" "$BAD_DATA")"
if printf '%s' "$BAD_OUT" | grep -qF 'PLAN_MARKER_MISSING_OR_AMBIGUOUS' \
  && RUN_FILE="$(autopilot_run_file bad_plan_run "$BAD_PROJECT")" node -e 'const j=require(process.env.RUN_FILE);process.exit(j.stage==="PLANNING"?0:1)'; then
  check "P7 missing marker fails closed without advancing" PASS
else check "P7 missing marker fails closed without advancing" FAIL; fi

DANGLING_PROJECT="$TMP/dangling-project"; mkdir -p "$DANGLING_PROJECT"
provision_session "$DANGLING_PROJECT" dangling_plan_session dangling || exit 1
DANGLING_OWNER="$PROVISIONED_KEY"; DANGLING_DATA="$PROVISIONED_DATA"
autopilot_begin_run dangling_plan_run "$DANGLING_OWNER" "$DANGLING_PROJECT" >/dev/null
rm -f "$(autopilot_run_file dangling_plan_run "$DANGLING_PROJECT")"
DANGLING_PLAN='# dangling

<!-- zensu-autopilot:dangling_plan_run -->'
DANGLING_OUT="$(invoke "$(payload "$DANGLING_PLAN" dangling_plan_session)" "$DANGLING_PROJECT" "$CFG_OFF" "$DANGLING_DATA")"
if printf '%s' "$DANGLING_OUT" | grep -qF 'CORRUPT_ACTIVE_STATE' \
  && ! printf '%s' "$DANGLING_OUT" | grep -qF 'AskUserQuestion'; then
  check "P7b dangling pointer blocks instead of falling through to standalone planning" PASS
else check "P7b dangling pointer is fail-closed" FAIL; fi

ORPHAN_PROJECT="$TMP/orphan-project"; mkdir -p "$ORPHAN_PROJECT"
provision_session "$ORPHAN_PROJECT" orphan_plan_owner orphan || exit 1
ORPHAN_OWNER="$PROVISIONED_KEY"; ORPHAN_DATA="$PROVISIONED_DATA"
autopilot_begin_run orphan_plan_run "$ORPHAN_OWNER" "$ORPHAN_PROJECT" >/dev/null
rm -f "$(autopilot_active_file "$ORPHAN_PROJECT" "$ORPHAN_OWNER")"
ORPHAN_OUT="$(invoke "$(payload 'ordinary plan during orphan crash' orphan_plan_owner)" "$ORPHAN_PROJECT" "$CFG_OFF" "$ORPHAN_DATA")"
if printf '%s' "$ORPHAN_OUT" | grep -qF 'CORRUPT_ACTIVE_STATE' \
  && ! printf '%s' "$ORPHAN_OUT" | grep -qF 'AskUserQuestion'; then
  check "P7c nonterminal run without a pointer blocks plan fallthrough" PASS
else check "P7c orphan nonterminal run cannot look standalone" FAIL; fi

HIDDEN_PROJECT="$TMP/hidden-orphan-project"; mkdir -p "$HIDDEN_PROJECT"
provision_session "$HIDDEN_PROJECT" hidden_plan_owner hidden-new || exit 1
HIDDEN_OWNER="$PROVISIONED_KEY"; HIDDEN_DATA="$PROVISIONED_DATA"
autopilot_begin_run old_plan_terminal "$HIDDEN_OWNER" "$HIDDEN_PROJECT" >/dev/null
autopilot_apply_event old_plan_terminal cancel-old-plan CANCEL '{}' "$HIDDEN_PROJECT" >/dev/null
OLD_PLAN_POINTER="$TMP/old-plan-pointer.json"
cp "$(autopilot_active_file "$HIDDEN_PROJECT" "$HIDDEN_OWNER")" "$OLD_PLAN_POINTER"
autopilot_begin_run hidden_plan_run "$HIDDEN_OWNER" "$HIDDEN_PROJECT" >/dev/null
cp "$OLD_PLAN_POINTER" "$(autopilot_active_file "$HIDDEN_PROJECT" "$HIDDEN_OWNER")"
HIDDEN_OUT="$(invoke "$(payload 'ordinary plan behind terminal pointer' hidden_plan_owner)" "$HIDDEN_PROJECT" "$CFG_OFF" "$HIDDEN_DATA")"
if printf '%s' "$HIDDEN_OUT" | grep -qF 'CORRUPT_ACTIVE_STATE' \
  && ! printf '%s' "$HIDDEN_OUT" | grep -qF 'AskUserQuestion'; then
  check "P7d terminal pointer cannot hide a newer nonterminal run from plan routing" PASS
else check "P7d hidden nonterminal run cannot inherit standalone plan policy" FAIL; fi

# --- P8a-P8c the empty-owner fail-closed arm --------------------------------
# What these pin is that the hook FAILS CLOSED — a PLAN_GATE_BLOCKED receipt
# rather than the standalone autoTdd policy — in a project that plainly holds
# durable Autopilot artifacts, including one whose only artifact is the
# owner-keyed pointer. Measured, not assumed: an unresolvable session id is
# refused by `zensu_bind_hook_session` before the owner arm is reached, so the
# code is RUNTIME_UNAVAILABLE and the SESSION_CONTEXT_UNAVAILABLE arm below it
# is defense in depth rather than the live path. The fail-closed DIRECTION is
# the property, and a fall-through is what would break it.
UNRESOLVED_PROJECT="$TMP/unresolved-owner"; mkdir -p "$UNRESOLVED_PROJECT"
provision_session "$UNRESOLVED_PROJECT" unresolved_plan_owner unresolved || exit 1
UNRESOLVED_OWNER="$PROVISIONED_KEY"; UNRESOLVED_DATA="$PROVISIONED_DATA"
autopilot_begin_run unresolved_plan_run "$UNRESOLVED_OWNER" "$UNRESOLVED_PROJECT" >/dev/null 2>&1 \
  || { echo "P8a fixture: run could not be started" >&2; exit 1; }
# An empty session id cannot resolve to a Session Control identity.
UNRESOLVED_OUT="$(invoke "$(payload 'ordinary plan with an unresolvable owner' '')" \
  "$UNRESOLVED_PROJECT" "$CFG_OFF" "$UNRESOLVED_DATA")"
if printf '%s' "$UNRESOLVED_OUT" | grep -qF 'PLAN_GATE_BLOCKED' \
  && ! printf '%s' "$UNRESOLVED_OUT" | grep -qF 'AskUserQuestion'; then
  check "P8a an unresolvable owner fails closed while durable run artifacts exist" PASS
else check "P8a unresolvable owner (out='$(printf '%s' "$UNRESOLVED_OUT" | head -c 120)')" FAIL; fi

# Only the owner-keyed pointer is present — no run file. The pre-scoping probe
# would miss it, so this is what bites the glob added for the new pointer name.
POINTER_ONLY_PROJECT="$TMP/pointer-only"; mkdir -p "$POINTER_ONLY_PROJECT/.zensu/state"
provision_session "$POINTER_ONLY_PROJECT" pointer_only_owner pointer-only || exit 1
POINTER_ONLY_DATA="$PROVISIONED_DATA"
printf '%s\n' '{"schemaVersion":1,"runId":"pointer_only_run"}' \
  > "$POINTER_ONLY_PROJECT/.zensu/state/autopilot-active-$(node -e 'const c=require("crypto");process.stdout.write(c.createHash("sha256").update("pointer_only_owner").digest("hex"))').json"
POINTER_ONLY_OUT="$(invoke "$(payload 'ordinary plan beside a lone pointer' '')" \
  "$POINTER_ONLY_PROJECT" "$CFG_OFF" "$POINTER_ONLY_DATA")"
if printf '%s' "$POINTER_ONLY_OUT" | grep -qF 'PLAN_GATE_BLOCKED' \
  && ! printf '%s' "$POINTER_ONLY_OUT" | grep -qF 'AskUserQuestion'; then
  check "P8b a lone owner-keyed pointer counts as durable state for the fail-closed arm" PASS
else check "P8b lone pointer (out='$(printf '%s' "$POINTER_ONLY_OUT" | head -c 120)')" FAIL; fi

# A state directory that exists but cannot be traversed is not "this project
# never ran Autopilot" either. Skipped where the mode cannot be established
# (running as root, or a filesystem that ignores the bit).
UNSEARCHABLE_PROJECT="$TMP/unsearchable"; mkdir -p "$UNSEARCHABLE_PROJECT/.zensu/state"
provision_session "$UNSEARCHABLE_PROJECT" unsearchable_owner unsearchable || exit 1
UNSEARCHABLE_DATA="$PROVISIONED_DATA"
chmod 600 "$UNSEARCHABLE_PROJECT/.zensu/state" 2>/dev/null || true
if [ -x "$UNSEARCHABLE_PROJECT/.zensu/state" ]; then
  chmod 700 "$UNSEARCHABLE_PROJECT/.zensu/state" 2>/dev/null || true
  check "P8c this host cannot make a directory unsearchable, so the arm was not exercised" PASS
else
  UNSEARCHABLE_OUT="$(invoke "$(payload 'ordinary plan behind an unsearchable state dir' '')" \
    "$UNSEARCHABLE_PROJECT" "$CFG_OFF" "$UNSEARCHABLE_DATA")"
  chmod 700 "$UNSEARCHABLE_PROJECT/.zensu/state" 2>/dev/null || true
  if printf '%s' "$UNSEARCHABLE_OUT" | grep -qF 'PLAN_GATE_BLOCKED' \
    && ! printf '%s' "$UNSEARCHABLE_OUT" | grep -qF 'AskUserQuestion'; then
    check "P8c an unsearchable state directory takes the fail-closed arm" PASS
  else check "P8c unsearchable state dir (out='$(printf '%s' "$UNSEARCHABLE_OUT" | head -c 120)')" FAIL; fi
fi

STANDALONE="$TMP/standalone"; mkdir -p "$STANDALONE"
provision_session "$STANDALONE" standalone_sid standalone || exit 1
STANDALONE_DATA="$PROVISIONED_DATA"
STANDALONE_OFF="$(invoke "$(payload 'ordinary plan' standalone_sid)" "$STANDALONE" "$CFG_OFF" "$STANDALONE_DATA")"
[ -z "$STANDALONE_OFF" ] && check "P8 standalone autoTdd=false remains silent" PASS || check "P8 standalone autoTdd=false remains silent" FAIL
DEFAULT_CFG="$TMP/missing.json"
STANDALONE_ON="$(invoke "$(payload 'ordinary plan' standalone_sid)" "$STANDALONE" "$DEFAULT_CFG" "$STANDALONE_DATA")"
printf '%s' "$STANDALONE_ON" | grep -qF 'AskUserQuestion' \
  && check "P9 standalone default remains ask-first" PASS \
  || check "P9 standalone default remains ask-first" FAIL

# DONE/CANCELLED pointers are retained as durable history, but they no longer
# own future ExitPlanMode events. Both must use the ordinary standalone policy.
CANCEL_PROJECT="$TMP/cancel-project"; mkdir -p "$CANCEL_PROJECT"
provision_session "$CANCEL_PROJECT" cancel_plan_owner cancel-owner || exit 1
CANCEL_OWNER="$PROVISIONED_KEY"
autopilot_begin_run cancel_plan_run "$CANCEL_OWNER" "$CANCEL_PROJECT" >/dev/null 2>&1
autopilot_apply_event cancel_plan_run cancel-plan-event CANCEL '{}' "$CANCEL_PROJECT" >/dev/null 2>&1
provision_session "$CANCEL_PROJECT" later_plan_session cancel-later || exit 1
CANCEL_LATER_DATA="$PROVISIONED_DATA"
CANCEL_OFF="$(invoke "$(payload 'ordinary plan after cancel' later_plan_session)" "$CANCEL_PROJECT" "$CFG_OFF" "$CANCEL_LATER_DATA")"
CANCEL_ON="$(invoke "$(payload 'ordinary plan after cancel' later_plan_session)" "$CANCEL_PROJECT" "$DEFAULT_CFG" "$CANCEL_LATER_DATA")"
if [ -z "$CANCEL_OFF" ] && printf '%s' "$CANCEL_ON" | grep -qF 'AskUserQuestion' \
  && ! printf '%s' "$CANCEL_ON" | grep -qF 'PLAN_GATE_BLOCKED'; then
  check "P10 CANCELLED pointer falls through to standalone plan policy" PASS
else check "P10 CANCELLED pointer does not own later plans" FAIL; fi
rm -f "$(autopilot_active_file "$CANCEL_PROJECT" "$CANCEL_OWNER")"
CANCEL_HISTORY_OFF="$(invoke "$(payload 'ordinary plan after detached terminal history' later_plan_session)" "$CANCEL_PROJECT" "$CFG_OFF" "$CANCEL_LATER_DATA")"
CANCEL_HISTORY_ON="$(invoke "$(payload 'ordinary plan after detached terminal history' later_plan_session)" "$CANCEL_PROJECT" "$DEFAULT_CFG" "$CANCEL_LATER_DATA")"
if [ -z "$CANCEL_HISTORY_OFF" ] && printf '%s' "$CANCEL_HISTORY_ON" | grep -qF 'AskUserQuestion' \
  && ! printf '%s' "$CANCEL_HISTORY_ON" | grep -qF 'PLAN_GATE_BLOCKED'; then
  check "P10b terminal history without a pointer remains standalone-compatible" PASS
else check "P10b terminal-only history is treated as absent" FAIL; fi

DONE_PROJECT="$TMP/done-project"; mkdir -p "$DONE_PROJECT"
DONE_RUN="done_plan_run_01"; DONE_OWNER_RAW="done_plan_owner_01"
provision_session "$DONE_PROJECT" "$DONE_OWNER_RAW" done-owner || exit 1
DONE_OWNER="$PROVISIONED_KEY"
DONE_HEAD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
DONE_READY=true
DONE_READY_STAGE=begin
autopilot_begin_run "$DONE_RUN" "$DONE_OWNER" "$DONE_PROJECT" >/dev/null 2>&1 \
  || { DONE_READY=false; DONE_READY_STAGE=begin-failed; }
done_plan_event() {
  if ! autopilot_apply_event "$DONE_RUN" "$1" "$2" "$3" "$DONE_PROJECT" >/dev/null 2>&1; then
    [ "$DONE_READY" = false ] || DONE_READY_STAGE="$1-failed"
    DONE_READY=false
  fi
}
done_plan_event done-plan PLAN_APPROVED '{"approvedPlanSha256":"2222222222222222222222222222222222222222222222222222222222222222"}'
done_plan_event done-tdd-start TDD_STARTED "{\"attempt\":1,\"chainId\":\"done-plan-chain-01\",\"sessionId\":\"$DONE_OWNER\"}"
done_plan_event done-tdd-finish TDD_CHAIN_DONE "{\"attempt\":1,\"chainId\":\"done-plan-chain-01\",\"sessionId\":\"$DONE_OWNER\",\"outcome\":\"pass\"}"
done_plan_event done-gates GATES_PASSED "{\"headSha\":\"$DONE_HEAD\"}"
done_plan_event done-converge CONVERGENCE_PASSED '{}'
done_plan_event done-pr-request PR_OPEN_REQUESTED '{"operationKey":"pr:done-plan"}'
done_plan_event done-pr-open PR_OPENED "{\"operationKey\":\"pr:done-plan\",\"pr\":{\"number\":713,\"url\":\"https://github.com/acme/repo/pull/713\",\"headSha\":\"$DONE_HEAD\"}}"
DONE_REVIEW_KEY="$(autopilot_team_review_operation_key "$DONE_RUN" "$DONE_HEAD")"
done_plan_event done-review-request TEAM_REVIEW_REQUESTED "{\"operationKey\":\"$DONE_REVIEW_KEY\",\"provider\":\"github\"}"
# P11 verifies terminal pointer routing, not the public payload-store boundary;
# that boundary has dedicated state-machine coverage below. Seed the exact
# private snapshot so this fixture cannot fail on unrelated Windows transport.
DONE_REVIEW_PAYLOAD="$RAW_TMP/done-review.json"
printf '%s\n' "{\"event\":\"COMMENT\",\"body\":\"Done fixture review\",\"commit_id\":\"$DONE_HEAD\",\"comments\":[]}" > "$DONE_REVIEW_PAYLOAD"
DONE_REVIEW_SNAPSHOT="$(_autopilot_team_review_payload_target \
  "$DONE_PROJECT" "$DONE_REVIEW_KEY" "$DONE_HEAD" 2>/dev/null || true)"
if [ -z "$DONE_REVIEW_SNAPSHOT" ] \
  || ! cp "$DONE_REVIEW_PAYLOAD" "$DONE_REVIEW_SNAPSHOT" \
  || ! chmod 600 "$DONE_REVIEW_SNAPSHOT" \
  || ! _autopilot_team_review_payload_inspect \
      "$DONE_REVIEW_SNAPSHOT" "$DONE_HEAD" true >/dev/null 2>&1; then
  [ "$DONE_READY" = false ] \
    || DONE_READY_STAGE="review-snapshot-seed-failed"
  DONE_READY=false
fi
DONE_REVIEW_DIGEST="$(_autopilot_team_review_payload_inspect \
  "$DONE_REVIEW_SNAPSHOT" "$DONE_HEAD" true canonical 2>/dev/null || true)"
DONE_REVIEW_MARKER="$(review_marker "$DONE_REVIEW_KEY" "$DONE_HEAD" "$DONE_REVIEW_DIGEST")"
done_plan_event done-review-published TEAM_REVIEW_PUBLISHED "{\"operationKey\":\"$DONE_REVIEW_KEY\",\"marker\":\"$DONE_REVIEW_MARKER\",\"headSha\":\"$DONE_HEAD\",\"provider\":\"github\"}"
done_plan_event done-findings FINDINGS_CLEARED "{\"headSha\":\"$DONE_HEAD\",\"unresolvedCount\":0}"
done_plan_event done-validation VALIDATION_PASSED "{\"headSha\":\"$DONE_HEAD\"}"
done_plan_event done-delivery DELIVERY_COMPLETE "{\"headSha\":\"$DONE_HEAD\"}"
DONE_FILE="$(autopilot_run_file "$DONE_RUN" "$DONE_PROJECT")"
DONE_BEFORE="$(digest "$DONE_FILE")"
provision_session "$DONE_PROJECT" later_done_session done-later || exit 1
DONE_LATER_DATA="$PROVISIONED_DATA"
DONE_ON="$(invoke "$(payload 'ordinary plan after delivery' later_done_session)" "$DONE_PROJECT" "$DEFAULT_CFG" "$DONE_LATER_DATA")"
if [ "$DONE_READY" = true ] && printf '%s' "$DONE_ON" | grep -qF 'AskUserQuestion' \
  && ! printf '%s' "$DONE_ON" | grep -qF 'PLAN_GATE_BLOCKED' \
  && [ "$(digest "$DONE_FILE")" = "$DONE_BEFORE" ]; then
  check "P11 DONE pointer falls through without mutating terminal history" PASS
else
  check "P11 DONE pointer does not own or mutate later plans (fixture=$DONE_READY_STAGE snapshot_length=${#DONE_REVIEW_SNAPSHOT})" FAIL
fi

# PATH is a POSIX colon-separated list under Bash, including Git Bash. Keep
# the one-shot shim in the shell path namespace: a native `D:/...` component
# would be split at the drive colon before command lookup ever reaches it.
NO_NODE_BIN="$RAW_TMP/no-node-bin"; mkdir -p "$NO_NODE_BIN"
ZENSU_TEST_REAL_NODE="$(command -v node)"
export ZENSU_TEST_REAL_NODE
NO_NODE_PATH="$NO_NODE_BIN"
_zensu_old_ifs="$IFS"; IFS=:
for _zensu_path_dir in $PATH; do
  if [ ! -x "$_zensu_path_dir/node" ] && [ ! -x "$_zensu_path_dir/node.exe" ]; then
    NO_NODE_PATH="$NO_NODE_PATH:$_zensu_path_dir"
  fi
done
IFS="$_zensu_old_ifs"
unset _zensu_old_ifs _zensu_path_dir
arm_one_shot_node() {
  # Let Session Control validate the sealed project binding, then model the
  # runtime disappearing before the Autopilot library can be loaded. A node
  # binary absent at hook entry cannot authenticate project context at all and
  # is covered by the silent/unavailable cases below.
  printf '%s\n' '#!/bin/bash' '/bin/rm -f "$0"' \
    'exec "$ZENSU_TEST_REAL_NODE" "$@"' > "$NO_NODE_BIN/node"
  chmod 700 "$NO_NODE_BIN/node"
}
invoke_without_node() {
  local input="$1" project="$2" plugin_data="$3"
  (
    printf '%s' "$input" | PATH="$NO_NODE_PATH" ZENSU_FORCE_MAIN='' \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$plugin_data" \
      CLAUDE_PROJECT_DIR="$project" /bin/bash "$HOOK" 2>/dev/null
  )
}
invoke_with_disappearing_node() {
  arm_one_shot_node
  invoke_without_node "$@"
}

arm_one_shot_node
ONE_SHOT_NODE="$(PATH="$NO_NODE_PATH" /bin/bash -c 'command -v node' 2>/dev/null || true)"
if [ "$ONE_SHOT_NODE" = "$NO_NODE_BIN/node" ]; then
  check "P11b one-shot Node shim is addressable through the POSIX PATH" PASS
else
  check "P11b one-shot Node shim path survives host-path normalization" FAIL
fi

MISSING_STATE_PLUGIN="$TMP/missing-state-plugin"; mkdir -p "$MISSING_STATE_PLUGIN/hooks/lib" "$MISSING_STATE_PLUGIN/.claude-plugin"
MISSING_STATE_PLUGIN="$(cd "$MISSING_STATE_PLUGIN" && pwd -P)"
printf '%s\n' '{"name":"zensu","version":"test-missing-state"}' \
  > "$MISSING_STATE_PLUGIN/.claude-plugin/plugin.json"
cp "$HOOK" "$MISSING_STATE_PLUGIN/hooks/plan-approved-delegate.sh"
cp "$PLUGIN_DIR/hooks/session-start-session-control.sh" "$MISSING_STATE_PLUGIN/hooks/session-start-session-control.sh"
cp "$PLUGIN_DIR/hooks/lib/zensu-session.sh" \
  "$PLUGIN_DIR/hooks/lib/zensu-msys-env.sh" \
  "$PLUGIN_DIR/hooks/lib/claude-hook-session-v1.js" \
  "$PLUGIN_DIR/hooks/lib/claude-session-control-v1.js" \
  "$PLUGIN_DIR/hooks/lib/claude-path-v1.js" \
  "$PLUGIN_DIR/hooks/lib/session-control-core-v1.js" \
  "$PLUGIN_DIR/hooks/lib/claude-principal-v1.js" \
  "$PLUGIN_DIR/hooks/lib/zensu-agent-context.sh" \
  "$PLUGIN_DIR/hooks/lib/zensu-config.sh" "$MISSING_STATE_PLUGIN/hooks/lib/"
MISSING_STATE_DATA="$TMP/missing-state-plugin-data"
mkdir -p "$MISSING_STATE_DATA"
bind_missing_state_session() {
  local raw_session="$1" project="$2"
  node -e 'process.stdout.write(JSON.stringify({
    hook_event_name:"SessionStart", source:"startup",
    session_id:process.argv[1], cwd:process.argv[2]
  }))' "$raw_session" "$project" \
    | CLAUDE_PLUGIN_ROOT="$MISSING_STATE_PLUGIN" CLAUDE_PLUGIN_DATA="$MISSING_STATE_DATA" \
      env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
      bash "$MISSING_STATE_PLUGIN/hooks/session-start-session-control.sh" >/dev/null
}
bind_missing_state_session "$SID_RAW" "$PROJECT" || exit 1
bind_missing_state_session orphan_plan_owner "$ORPHAN_PROJECT" || exit 1
OUT_NO_NODE="$(invoke_with_disappearing_node "$(payload "$PLAN" "$SID_RAW")" "$PROJECT" "$MAIN_DATA")"
OUT_NO_STATE="$(
  printf '%s' "$(payload "$PLAN" "$SID_RAW")" | ZENSU_FORCE_MAIN='' \
    CLAUDE_PLUGIN_ROOT="$MISSING_STATE_PLUGIN" CLAUDE_PLUGIN_DATA="$MISSING_STATE_DATA" CLAUDE_PROJECT_DIR="$PROJECT" \
    /bin/bash "$MISSING_STATE_PLUGIN/hooks/plan-approved-delegate.sh" 2>/dev/null
)"
if printf '%s' "$OUT_NO_NODE" | grep -qF 'PLAN_GATE_BLOCKED' \
  && printf '%s' "$OUT_NO_STATE" | grep -qF 'PLAN_GATE_BLOCKED' \
  && ! printf '%s' "$OUT_NO_NODE" | grep -qF 'AskUserQuestion'; then
  check "P12 active pointer plus missing Node or state library fails closed" PASS
else check "P12 missing durable runtime is not treated as standalone" FAIL; fi

ORPHAN_RUNTIME_PAYLOAD="$(payload 'ordinary plan while orphan runtime is missing' orphan_plan_owner)"
OUT_NO_NODE_ORPHAN="$(invoke_with_disappearing_node "$ORPHAN_RUNTIME_PAYLOAD" "$ORPHAN_PROJECT" "$ORPHAN_DATA")"
OUT_NO_STATE_ORPHAN="$(
  printf '%s' "$ORPHAN_RUNTIME_PAYLOAD" | ZENSU_FORCE_MAIN='' \
    CLAUDE_PLUGIN_ROOT="$MISSING_STATE_PLUGIN" CLAUDE_PLUGIN_DATA="$MISSING_STATE_DATA" CLAUDE_PROJECT_DIR="$ORPHAN_PROJECT" \
    /bin/bash "$MISSING_STATE_PLUGIN/hooks/plan-approved-delegate.sh" 2>/dev/null
)"
if printf '%s' "$OUT_NO_NODE_ORPHAN" | grep -qF 'PLAN_GATE_BLOCKED' \
  && printf '%s' "$OUT_NO_STATE_ORPHAN" | grep -qF 'PLAN_GATE_BLOCKED' \
  && ! printf '%s' "$OUT_NO_NODE_ORPHAN" | grep -qF 'AskUserQuestion'; then
  check "P12b orphan run plus missing Node or state library blocks plan routing" PASS
else check "P12b orphan durable state cannot fall through without its runtime" FAIL; fi

OUT_NO_NODE_ABSENT="$(invoke_without_node "$(payload 'ordinary plan' standalone_sid)" "$STANDALONE" "$STANDALONE_DATA")"
AGENT_PAYLOAD="$(PLAN='agent plan' SID='agent_sid' node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PostToolUse",session_id:process.env.SID,agent_id:"child-plan",tool_name:"ExitPlanMode",tool_input:{plan:process.env.PLAN}}))')"
OUT_NO_NODE_AGENT="$(invoke_without_node "$AGENT_PAYLOAD" "$PROJECT" "$MAIN_DATA")"
ORPHAN_AGENT_PAYLOAD="$(PLAN='orphan agent plan' SID='orphan_agent_sid' node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PostToolUse",session_id:process.env.SID,agent_id:"child-orphan-plan",tool_name:"ExitPlanMode",tool_input:{plan:process.env.PLAN}}))')"
OUT_NO_NODE_ORPHAN_AGENT="$(invoke_without_node "$ORPHAN_AGENT_PAYLOAD" "$ORPHAN_PROJECT" "$ORPHAN_DATA")"
if [ -z "$OUT_NO_NODE_ABSENT" ] \
  && [ -z "$OUT_NO_NODE_AGENT" ] \
  && [ -z "$OUT_NO_NODE_ORPHAN_AGENT" ]; then
  check "P13 missing Node cannot authenticate any principal and stays silent" PASS
else check "P13 unauthenticated missing-Node delivery must be a no-op" FAIL; fi

if grep -qF 'PAYLOAD="$INPUT"' "$HOOK" || grep -qF 'zensu_hook_agent_id "$INPUT"' "$HOOK"; then
  check "P14 plan hook copies the full payload into a process environment or argv" FAIL
else
  check "P14 plan hook streams JSON payloads over stdin" PASS
fi

if grep -qF 'MSYS2_ENV_CONV_EXCL=' "$HOOK" \
  && grep -qF 'LOG_HELPER_Q' "$HOOK"; then
  check "P15 MSYS preserves the already shell-quoted log-helper token" PASS
else
  check "P15 MSYS preserves the already shell-quoted log-helper token" FAIL
fi

# P16 the legacy carrier still delegates identically on a host that declares the
# ExitPlanMode fields, so keeping sources 1-2 ranked first costs no behavior.
# A project carries exactly one active run pointer, so the legacy carrier needs
# its own project rather than a second run beside the one above.
RUN_LEGACY="plan_run_legacy"; SID_LEGACY_RAW="plan_session_legacy"
PROJECT_LEGACY="$TMP/project-legacy"; mkdir -p "$PROJECT_LEGACY"
provision_session "$PROJECT_LEGACY" "$SID_LEGACY_RAW" legacy || exit 1
SID_LEGACY="$PROVISIONED_KEY"; LEGACY_DATA="$PROVISIONED_DATA"
PLAN_LEGACY="# Approved feature\n\nImplement it.\n\n<!-- zensu-autopilot:${RUN_LEGACY} -->"
if autopilot_begin_run "$RUN_LEGACY" "$SID_LEGACY" "$PROJECT_LEGACY" >/dev/null 2>&1; then
  OUT_LEGACY="$(invoke "$(payload_input_dialect "$PLAN_LEGACY" "$SID_LEGACY_RAW")" "$PROJECT_LEGACY" "$CFG_OFF" "$LEGACY_DATA")"
  LEGACY_RUN_FILE="$(autopilot_run_file "$RUN_LEGACY" "$PROJECT_LEGACY")"
  LEGACY_SHA="$(printf '%s' "$PLAN_LEGACY" | node -e 'const fs=require("fs"),crypto=require("crypto");process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(0)).digest("hex"));')"
  if printf '%s' "$OUT_LEGACY" | grep -qF 'PLAN_APPROVED' \
    && RUN_FILE="$LEGACY_RUN_FILE" SHA="$LEGACY_SHA" node -e 'const j=require(process.env.RUN_FILE);process.exit(j.stage==="AWAIT_TDD"&&j.approvedPlanSha256===process.env.SHA?0:1)'; then
    check "P16 a tool_input.plan payload still delegates and digests identically" PASS
  else
    check "P16 legacy carrier delegation (out='$(printf '%s' "$OUT_LEGACY" | head -c 140)')" FAIL
  fi
else
  check "P16 legacy carrier fixture could not be armed" FAIL
fi

echo "----"; echo "test-autopilot-plan-delegate: $PASS PASS / $FAIL FAIL"; [ "$FAIL" -eq 0 ]
