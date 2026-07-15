#!/bin/bash
# Autopilot owns the one planning gate; standalone plans keep ask-first routing.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/plan-approved-delegate.sh"
LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
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

TMP="$(mktemp -d -t zensu-autopilot-plan-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"; mkdir -p "$PROJECT"
RUN="plan_run_01"; SID="plan_session_01"
PLAN="# Approved feature\n\nImplement it.\n\n<!-- zensu-autopilot:${RUN} -->"
autopilot_begin_run "$RUN" "$SID" "$PROJECT" >/dev/null || exit 1
CFG_OFF="$TMP/off.json"; printf '%s\n' '{"hooks":{"autoTdd":false}}' > "$CFG_OFF"

payload() {
  PLAN="$1" SID="$2" node -e 'process.stdout.write(JSON.stringify({session_id:process.env.SID,tool_name:"ExitPlanMode",tool_input:{plan:process.env.PLAN}}))'
}
invoke() {
  printf '%s' "$1" | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$2" ZENSU_CONFIG="${3:-$CFG_OFF}" bash "$HOOK" 2>/dev/null
}
digest() { node -e 'const fs=require("fs"),crypto=require("crypto");process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$1"; }
RUN_FILE="$(autopilot_run_file "$RUN" "$PROJECT")"

OUT="$(invoke "$(payload "$PLAN" "$SID")" "$PROJECT")"
if printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{const j=JSON.parse(s),t=j.hookSpecificOutput.additionalContext;process.exit(j.hookSpecificOutput.hookEventName==="PostToolUse"&&t.includes("PLAN_APPROVED")&&t.includes("skill=\u0027zensu:tdd\u0027")&&!t.includes("AskUserQuestion")?0:1)}catch(_){process.exit(1)}})'; then
  check "P3 approved Autopilot plan delegates directly without a routine question" PASS
else check "P3 approved Autopilot plan delegates directly without a routine question" FAIL; fi

EXPECTED_SHA="$(printf '%s' "$PLAN" | node -e 'const fs=require("fs"),crypto=require("crypto");process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(0)).digest("hex"));')"
if RUN_FILE="$RUN_FILE" SHA="$EXPECTED_SHA" node -e 'const j=require(process.env.RUN_FILE);process.exit(j.stage==="AWAIT_TDD"&&j.nextActionCode==="START_TDD"&&j.approvedPlanSha256===process.env.SHA?0:1)'; then
  check "P4 approval persists the exact plan digest and AWAIT_TDD stage" PASS
else check "P4 approval persists the exact plan digest and AWAIT_TDD stage" FAIL; fi

BEFORE="$(digest "$RUN_FILE")"; OUT_REPEAT="$(invoke "$(payload "$PLAN" "$SID")" "$PROJECT")"; AFTER="$(digest "$RUN_FILE")"
[ "$OUT_REPEAT" = "$OUT" ] && [ "$BEFORE" = "$AFTER" ] \
  && check "P5 repeated ExitPlanMode delivery is byte-stable" PASS \
  || check "P5 repeated ExitPlanMode delivery is byte-stable" FAIL

autopilot_apply_event "$RUN" plan-retry-tdd-start TDD_STARTED \
  '{"attempt":1,"chainId":"plan-retry-chain-01","sessionId":"plan_session_01"}' "$PROJECT" >/dev/null
autopilot_apply_event "$RUN" plan-retry-tdd-done TDD_CHAIN_DONE \
  '{"attempt":1,"chainId":"plan-retry-chain-01","sessionId":"plan_session_01","outcome":"pass"}' "$PROJECT" >/dev/null
autopilot_apply_event "$RUN" plan-retry-gates-failed GATES_FAILED \
  '{"headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","reason":"retry fixture"}' "$PROJECT" >/dev/null
BEFORE_STALE="$(digest "$RUN_FILE")"
OUT_STALE="$(invoke "$(payload "$PLAN" "$SID")" "$PROJECT")"
if printf '%s' "$OUT_STALE" | grep -qF -- '--autopilot-attempt 2 --autopilot-return-stage GATES' \
  && [ "$(digest "$RUN_FILE")" = "$BEFORE_STALE" ]; then
  check "P5b delayed plan replay delegates the durable next attempt instead of stale attempt 1" PASS
else check "P5b delayed plan replay uses durable attempt and return stage" FAIL; fi

BEFORE_OWNER="$(digest "$RUN_FILE")"
OUT_OWNER="$(invoke "$(payload "$PLAN" other_session)" "$PROJECT")"
if printf '%s' "$OUT_OWNER" | grep -qF 'OWNER_SESSION_MISMATCH' && [ "$(digest "$RUN_FILE")" = "$BEFORE_OWNER" ]; then
  check "P6 foreign session cannot approve or mutate the run" PASS
else check "P6 foreign session cannot approve or mutate the run" FAIL; fi

BAD_PROJECT="$TMP/bad-project"; mkdir -p "$BAD_PROJECT"
autopilot_begin_run bad_plan_run bad_plan_session "$BAD_PROJECT" >/dev/null || exit 1
BAD_OUT="$(invoke "$(payload '# no bound marker' bad_plan_session)" "$BAD_PROJECT")"
if printf '%s' "$BAD_OUT" | grep -qF 'PLAN_MARKER_MISSING_OR_AMBIGUOUS' \
  && RUN_FILE="$(autopilot_run_file bad_plan_run "$BAD_PROJECT")" node -e 'const j=require(process.env.RUN_FILE);process.exit(j.stage==="PLANNING"?0:1)'; then
  check "P7 missing marker fails closed without advancing" PASS
else check "P7 missing marker fails closed without advancing" FAIL; fi

DANGLING_PROJECT="$TMP/dangling-project"; mkdir -p "$DANGLING_PROJECT"
autopilot_begin_run dangling_plan_run dangling_plan_session "$DANGLING_PROJECT" >/dev/null
rm -f "$(autopilot_run_file dangling_plan_run "$DANGLING_PROJECT")"
DANGLING_PLAN='# dangling

<!-- zensu-autopilot:dangling_plan_run -->'
DANGLING_OUT="$(invoke "$(payload "$DANGLING_PLAN" dangling_plan_session)" "$DANGLING_PROJECT")"
if printf '%s' "$DANGLING_OUT" | grep -qF 'CORRUPT_ACTIVE_STATE' \
  && ! printf '%s' "$DANGLING_OUT" | grep -qF 'AskUserQuestion'; then
  check "P7b dangling pointer blocks instead of falling through to standalone planning" PASS
else check "P7b dangling pointer is fail-closed" FAIL; fi

ORPHAN_PROJECT="$TMP/orphan-project"; mkdir -p "$ORPHAN_PROJECT"
autopilot_begin_run orphan_plan_run orphan_plan_owner "$ORPHAN_PROJECT" >/dev/null
rm -f "$(autopilot_active_file "$ORPHAN_PROJECT")"
ORPHAN_OUT="$(invoke "$(payload 'ordinary plan during orphan crash' orphan_plan_owner)" "$ORPHAN_PROJECT" "$CFG_OFF")"
if printf '%s' "$ORPHAN_OUT" | grep -qF 'CORRUPT_ACTIVE_STATE' \
  && ! printf '%s' "$ORPHAN_OUT" | grep -qF 'AskUserQuestion'; then
  check "P7c nonterminal run without a pointer blocks plan fallthrough" PASS
else check "P7c orphan nonterminal run cannot look standalone" FAIL; fi

HIDDEN_PROJECT="$TMP/hidden-orphan-project"; mkdir -p "$HIDDEN_PROJECT"
autopilot_begin_run old_plan_terminal old_plan_owner "$HIDDEN_PROJECT" >/dev/null
autopilot_apply_event old_plan_terminal cancel-old-plan CANCEL '{}' "$HIDDEN_PROJECT" >/dev/null
OLD_PLAN_POINTER="$TMP/old-plan-pointer.json"
cp "$(autopilot_active_file "$HIDDEN_PROJECT")" "$OLD_PLAN_POINTER"
autopilot_begin_run hidden_plan_run hidden_plan_owner "$HIDDEN_PROJECT" >/dev/null
cp "$OLD_PLAN_POINTER" "$(autopilot_active_file "$HIDDEN_PROJECT")"
HIDDEN_OUT="$(invoke "$(payload 'ordinary plan behind terminal pointer' hidden_plan_owner)" "$HIDDEN_PROJECT" "$CFG_OFF")"
if printf '%s' "$HIDDEN_OUT" | grep -qF 'CORRUPT_ACTIVE_STATE' \
  && ! printf '%s' "$HIDDEN_OUT" | grep -qF 'AskUserQuestion'; then
  check "P7d terminal pointer cannot hide a newer nonterminal run from plan routing" PASS
else check "P7d hidden nonterminal run cannot inherit standalone plan policy" FAIL; fi

STANDALONE="$TMP/standalone"; mkdir -p "$STANDALONE"
STANDALONE_OFF="$(invoke "$(payload 'ordinary plan' standalone_sid)" "$STANDALONE" "$CFG_OFF")"
[ -z "$STANDALONE_OFF" ] && check "P8 standalone autoTdd=false remains silent" PASS || check "P8 standalone autoTdd=false remains silent" FAIL
DEFAULT_CFG="$TMP/missing.json"
STANDALONE_ON="$(invoke "$(payload 'ordinary plan' standalone_sid)" "$STANDALONE" "$DEFAULT_CFG")"
printf '%s' "$STANDALONE_ON" | grep -qF 'AskUserQuestion' \
  && check "P9 standalone default remains ask-first" PASS \
  || check "P9 standalone default remains ask-first" FAIL

# DONE/CANCELLED pointers are retained as durable history, but they no longer
# own future ExitPlanMode events. Both must use the ordinary standalone policy.
CANCEL_PROJECT="$TMP/cancel-project"; mkdir -p "$CANCEL_PROJECT"
autopilot_begin_run cancel_plan_run cancel_plan_owner "$CANCEL_PROJECT" >/dev/null 2>&1
autopilot_apply_event cancel_plan_run cancel-plan-event CANCEL '{}' "$CANCEL_PROJECT" >/dev/null 2>&1
CANCEL_OFF="$(invoke "$(payload 'ordinary plan after cancel' later_plan_session)" "$CANCEL_PROJECT" "$CFG_OFF")"
CANCEL_ON="$(invoke "$(payload 'ordinary plan after cancel' later_plan_session)" "$CANCEL_PROJECT" "$DEFAULT_CFG")"
if [ -z "$CANCEL_OFF" ] && printf '%s' "$CANCEL_ON" | grep -qF 'AskUserQuestion' \
  && ! printf '%s' "$CANCEL_ON" | grep -qF 'PLAN_GATE_BLOCKED'; then
  check "P10 CANCELLED pointer falls through to standalone plan policy" PASS
else check "P10 CANCELLED pointer does not own later plans" FAIL; fi
rm -f "$(autopilot_active_file "$CANCEL_PROJECT")"
CANCEL_HISTORY_OFF="$(invoke "$(payload 'ordinary plan after detached terminal history' later_plan_session)" "$CANCEL_PROJECT" "$CFG_OFF")"
CANCEL_HISTORY_ON="$(invoke "$(payload 'ordinary plan after detached terminal history' later_plan_session)" "$CANCEL_PROJECT" "$DEFAULT_CFG")"
if [ -z "$CANCEL_HISTORY_OFF" ] && printf '%s' "$CANCEL_HISTORY_ON" | grep -qF 'AskUserQuestion' \
  && ! printf '%s' "$CANCEL_HISTORY_ON" | grep -qF 'PLAN_GATE_BLOCKED'; then
  check "P10b terminal history without a pointer remains standalone-compatible" PASS
else check "P10b terminal-only history is treated as absent" FAIL; fi

DONE_PROJECT="$TMP/done-project"; mkdir -p "$DONE_PROJECT"
DONE_RUN="done_plan_run_01"; DONE_OWNER="done_plan_owner_01"
DONE_HEAD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
DONE_READY=true
autopilot_begin_run "$DONE_RUN" "$DONE_OWNER" "$DONE_PROJECT" >/dev/null 2>&1 || DONE_READY=false
done_plan_event() {
  autopilot_apply_event "$DONE_RUN" "$1" "$2" "$3" "$DONE_PROJECT" >/dev/null 2>&1 || DONE_READY=false
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
DONE_REVIEW_PAYLOAD="$TMP/done-review-payload.json"
printf '%s\n' "{\"event\":\"COMMENT\",\"body\":\"Done fixture review\",\"commit_id\":\"$DONE_HEAD\",\"comments\":[]}" > "$DONE_REVIEW_PAYLOAD"
DONE_REVIEW_SNAPSHOT="$(autopilot_store_team_review_payload "$DONE_RUN" "$DONE_REVIEW_KEY" \
  "$DONE_HEAD" "$DONE_REVIEW_PAYLOAD" github "$DONE_PROJECT" 2>/dev/null || true)"
[ -n "$DONE_REVIEW_SNAPSHOT" ] || DONE_READY=false
DONE_REVIEW_DIGEST="$(_autopilot_team_review_payload_inspect \
  "$DONE_REVIEW_SNAPSHOT" "$DONE_HEAD" true canonical 2>/dev/null || true)"
DONE_REVIEW_MARKER="$(review_marker "$DONE_REVIEW_KEY" "$DONE_HEAD" "$DONE_REVIEW_DIGEST")"
done_plan_event done-review-published TEAM_REVIEW_PUBLISHED "{\"operationKey\":\"$DONE_REVIEW_KEY\",\"marker\":\"$DONE_REVIEW_MARKER\",\"headSha\":\"$DONE_HEAD\",\"provider\":\"github\"}"
done_plan_event done-findings FINDINGS_CLEARED "{\"headSha\":\"$DONE_HEAD\",\"unresolvedCount\":0}"
done_plan_event done-validation VALIDATION_PASSED "{\"headSha\":\"$DONE_HEAD\"}"
done_plan_event done-delivery DELIVERY_COMPLETE "{\"headSha\":\"$DONE_HEAD\"}"
DONE_FILE="$(autopilot_run_file "$DONE_RUN" "$DONE_PROJECT")"
DONE_BEFORE="$(digest "$DONE_FILE")"
DONE_ON="$(invoke "$(payload 'ordinary plan after delivery' later_done_session)" "$DONE_PROJECT" "$DEFAULT_CFG")"
if [ "$DONE_READY" = true ] && printf '%s' "$DONE_ON" | grep -qF 'AskUserQuestion' \
  && ! printf '%s' "$DONE_ON" | grep -qF 'PLAN_GATE_BLOCKED' \
  && [ "$(digest "$DONE_FILE")" = "$DONE_BEFORE" ]; then
  check "P11 DONE pointer falls through without mutating terminal history" PASS
else check "P11 DONE pointer does not own or mutate later plans" FAIL; fi

NO_NODE_BIN="$TMP/no-node-bin"; mkdir -p "$NO_NODE_BIN"
invoke_without_node() {
  printf '%s' "$1" | PATH="$NO_NODE_BIN" ZENSU_FORCE_MAIN='' \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$2" /bin/bash "$HOOK" 2>/dev/null
}

MISSING_STATE_PLUGIN="$TMP/missing-state-plugin"; mkdir -p "$MISSING_STATE_PLUGIN/hooks/lib"
OUT_NO_NODE="$(invoke_without_node "$(payload "$PLAN" "$SID")" "$PROJECT")"
OUT_NO_STATE="$(printf '%s' "$(payload "$PLAN" "$SID")" | ZENSU_FORCE_MAIN='' \
  CLAUDE_PLUGIN_ROOT="$MISSING_STATE_PLUGIN" CLAUDE_PROJECT_DIR="$PROJECT" /bin/bash "$HOOK" 2>/dev/null)"
if printf '%s' "$OUT_NO_NODE" | grep -qF 'RUNTIME_UNAVAILABLE' \
  && printf '%s' "$OUT_NO_STATE" | grep -qF 'RUNTIME_UNAVAILABLE' \
  && ! printf '%s' "$OUT_NO_NODE" | grep -qF 'AskUserQuestion'; then
  check "P12 active pointer plus missing Node or state library fails closed" PASS
else check "P12 missing durable runtime is not treated as standalone" FAIL; fi

ORPHAN_RUNTIME_PAYLOAD="$(payload 'ordinary plan while orphan runtime is missing' orphan_plan_owner)"
OUT_NO_NODE_ORPHAN="$(invoke_without_node "$ORPHAN_RUNTIME_PAYLOAD" "$ORPHAN_PROJECT")"
OUT_NO_STATE_ORPHAN="$(printf '%s' "$ORPHAN_RUNTIME_PAYLOAD" | ZENSU_FORCE_MAIN='' \
  CLAUDE_PLUGIN_ROOT="$MISSING_STATE_PLUGIN" CLAUDE_PROJECT_DIR="$ORPHAN_PROJECT" /bin/bash "$HOOK" 2>/dev/null)"
if printf '%s' "$OUT_NO_NODE_ORPHAN" | grep -qF 'RUNTIME_UNAVAILABLE' \
  && printf '%s' "$OUT_NO_STATE_ORPHAN" | grep -qF 'RUNTIME_UNAVAILABLE' \
  && ! printf '%s' "$OUT_NO_NODE_ORPHAN" | grep -qF 'AskUserQuestion'; then
  check "P12b orphan run plus missing Node or state library blocks plan routing" PASS
else check "P12b orphan durable state cannot fall through without its runtime" FAIL; fi

OUT_NO_NODE_ABSENT="$(invoke_without_node "$(payload 'ordinary plan' standalone_sid)" "$STANDALONE")"
AGENT_PAYLOAD="$(PLAN='agent plan' SID='agent_sid' node -e 'process.stdout.write(JSON.stringify({session_id:process.env.SID,agent_id:"child-plan",tool_name:"ExitPlanMode",tool_input:{plan:process.env.PLAN}}))')"
OUT_NO_NODE_AGENT="$(invoke_without_node "$AGENT_PAYLOAD" "$PROJECT")"
ORPHAN_AGENT_PAYLOAD="$(PLAN='orphan agent plan' SID='orphan_agent_sid' node -e 'process.stdout.write(JSON.stringify({session_id:process.env.SID,agent_id:"child-orphan-plan",tool_name:"ExitPlanMode",tool_input:{plan:process.env.PLAN}}))')"
OUT_NO_NODE_ORPHAN_AGENT="$(invoke_without_node "$ORPHAN_AGENT_PAYLOAD" "$ORPHAN_PROJECT")"
if [ -z "$OUT_NO_NODE_ABSENT" ] && [ -z "$OUT_NO_NODE_AGENT" ] \
  && [ -z "$OUT_NO_NODE_ORPHAN_AGENT" ]; then
  check "P13 unavailable runtime stays silent without a pointer and for spawned agents" PASS
else check "P13 unavailable runtime distinguishes absence and spawned-agent no-op" FAIL; fi

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

echo "----"; echo "test-autopilot-plan-delegate: $PASS PASS / $FAIL FAIL"; [ "$FAIL" -eq 0 ]
