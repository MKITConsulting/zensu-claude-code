#!/bin/bash
# Bound max-rounds handoff must preserve one immutable outcome and drive the
# outer run to audited BLOCKED, both with and without the self-review stage.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
POST="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
PHASE="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
STATE_LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
PASS=0; FAIL=0
check() { if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }

TMP="$(mktemp -d -t zensu-autopilot-post-max-XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export TDD_STATE_DIR="$TMP/tdd-state"
mkdir -p "$TDD_STATE_DIR"
source "$STATE_LIB"
# shellcheck disable=SC1090
source "$PHASE"

approve() {
  local project="$1" run="$2" owner="$3"
  local sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  autopilot_begin_run "$run" "$owner" "$project" >/dev/null \
    && autopilot_apply_event "$run" "plan-${run}" PLAN_APPROVED \
      "{\"approvedPlanSha256\":\"$sha\"}" "$project" "$owner" >/dev/null
}
field_ok() {
  FILE="$1" EXPR="$2" node -e '
    try { const j=JSON.parse(require("fs").readFileSync(process.env.FILE,"utf8"));
      process.exit(Function("j",`return Boolean(${process.env.EXPR})`)(j)?0:1); }
    catch (_) { process.exit(1); }
  ' 2>/dev/null
}
digest() { node -e 'const fs=require("fs"),crypto=require("crypto");process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$1"; }
inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1" 2>/dev/null; }
run_max_hook() {
  local project="$1" session="$2" cfg="$3" state ticket payload context
  state="$TDD_STATE_DIR/tdd-phase-${session}.json"
  FILE="$state" node -e '
    const fs=require("fs"),j=JSON.parse(fs.readFileSync(process.env.FILE,"utf8"));
    j.reviewRound=1; fs.writeFileSync(process.env.FILE,JSON.stringify(j,null,2));
  '
  ticket="$(CLAUDE_PROJECT_DIR="$project" ZENSU_CONFIG="$cfg" bash "$LOG" --review-ticket --session "$session")" || return 1
  context="$(tdd_autopilot_context "$state" "$session")" || return 1
  payload="$(SID="$session" TICKET="$ticket" CONTEXT="$context" node -e '
    const c=JSON.parse(process.env.CONTEXT);
    process.stdout.write(JSON.stringify({session_id:process.env.SID,tool_input:{
      subagent_type:"zensu:code-reviewer",
      prompt:`PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nZENSU-DELEGATED-CALLER: autopilot\nAUTOPILOT-BINDING: run=${c.runId} attempt=${c.attempt} chain=${c.chainId}\nAUTOPILOT-STAGE: ${c.returnStage}\nfixture`
    }}));
  ')"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$project" ZENSU_CONFIG="$cfg" bash "$POST" >/dev/null
}

CFG_ON="$TMP/self-review-on.json"
printf '%s\n' '{"hooks":{"autoFixMaxRounds":1,"selfReview":true}}' >"$CFG_ON"
P1="$TMP/on"; mkdir -p "$P1"; R1=post_max_review_on; S1=post_max_session_on; C1=post-max-chain-on
approve "$P1" "$R1" "$S1" || exit 1
CLAUDE_PROJECT_DIR="$P1" ZENSU_CONFIG="$CFG_ON" bash "$LOG" --tdd-begin --session "$S1" \
  --autopilot-run "$R1" --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id "$C1" >/dev/null
CLAUDE_PROJECT_DIR="$P1" ZENSU_CONFIG="$CFG_ON" bash "$LOG" --tdd-complete --session "$S1" \
  --autopilot-run "$R1" --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id "$C1" >/dev/null
run_max_hook "$P1" "$S1" "$CFG_ON"
TF1="$TDD_STATE_DIR/tdd-phase-${S1}.json"; RF1="$(autopilot_run_file "$R1" "$P1")"
if field_ok "$TF1" 'j.chainOutcome==="max-rounds"&&j.codeReviewDone===true&&j.chainDone===false' \
  && field_ok "$RF1" 'j.stage==="TDD_RUNNING"'; then
  check "M1 self-review handoff persists bound max-rounds without closing early" PASS
else check "M1 self-review handoff persists bound max-rounds without closing early" FAIL; fi
OUT1_STOP="$(printf '%s' "{\"session_id\":\"$S1\"}" \
  | CLAUDE_PROJECT_DIR="$P1" ZENSU_CONFIG="$CFG_ON" bash "$STOP" 2>/dev/null)"
if printf '%s' "$OUT1_STOP" | grep -qF "skill='zensu:self-review'" \
  && ! printf '%s' "$OUT1_STOP" | grep -qF 'nextActionCode=AWAIT_TDD_CHAIN' \
  && field_ok "$TF1" 'j.stopBlockCount===1&&j.chainOutcome==="max-rounds"&&j.codeReviewDone===true' \
  && field_ok "$RF1" 'j.stage==="TDD_RUNNING"&&j.stopBudget.count===0'; then
  check "M1b Stop accepts the exact max-round handoff and routes self-review" PASS
else check "M1b max-round handoff cannot fall back to AWAIT_TDD_CHAIN" FAIL; fi
T1="$(FILE="$TF1" node -e 'process.stdout.write(require(process.env.FILE).reviewTicket)')"
D1="$(digest "$TF1")"; I1="$(inode "$TF1")"
if tdd_mark_autopilot_max_round_handoff "$S1" "$R1" 1 GATES "$C1" "$T1" \
  && ! tdd_mark_autopilot_max_round_handoff "$S1" wrong_run 1 GATES "$C1" "$T1" >/dev/null 2>&1 \
  && ! tdd_mark_autopilot_max_round_handoff "$S1" "$R1" 2 GATES "$C1" "$T1" >/dev/null 2>&1 \
  && ! tdd_mark_autopilot_max_round_handoff "$S1" "$R1" 1 VALIDATE "$C1" "$T1" >/dev/null 2>&1 \
  && ! tdd_mark_autopilot_max_round_handoff "$S1" "$R1" 1 GATES wrong_chain "$T1" >/dev/null 2>&1 \
  && ! tdd_mark_autopilot_max_round_handoff "$S1" "$R1" 1 GATES "$C1" rt_wrong >/dev/null 2>&1 \
  && [ "$(digest "$TF1")" = "$D1" ] && [ "$(inode "$TF1")" = "$I1" ]; then
  check "M1a only the exact ticket and generation retry is an rc0 byte-stable no-op" PASS
else check "M1a max-round handoff exact retry contract" FAIL; fi

# A self-review may apply its one allowed fix before it owns the final
# --chain-done terminus. If that turn stops in between, the max-round handoff is
# still live and Stop must resume self-review rather than falling back to the
# Outer AWAIT_TDD_CHAIN action.
if tdd_mark_review_converged "$S1" "$T1" selfReviewFixed; then
  OUT1_FIXED_STOP="$(printf '%s' "{\"session_id\":\"$S1\"}" \
    | CLAUDE_PROJECT_DIR="$P1" ZENSU_CONFIG="$CFG_ON" bash "$STOP" 2>/dev/null)"
else
  OUT1_FIXED_STOP=""
fi
if printf '%s' "$OUT1_FIXED_STOP" | grep -qF "skill='zensu:self-review'" \
  && ! printf '%s' "$OUT1_FIXED_STOP" | grep -qF 'nextActionCode=AWAIT_TDD_CHAIN' \
  && field_ok "$TF1" \
    'j.chainOutcome==="max-rounds"&&j.codeReviewDone===true&&j.selfReviewFixed===true&&j.chainDone===false&&j.stopBlockCount===2' \
  && field_ok "$RF1" 'j.stage==="TDD_RUNNING"&&j.stopBudget.count===0'; then
  check "M1c Stop resumes terminal self-review after its one fix and before chainDone" PASS
else check "M1c max-round selfReviewFixed crash window cannot fall back to AWAIT_TDD_CHAIN" FAIL; fi

if CLAUDE_PROJECT_DIR="$P1" ZENSU_CONFIG="$CFG_ON" bash "$LOG" --chain-done --session "$S1" \
    --autopilot-run "$R1" --autopilot-attempt 1 --autopilot-return-stage GATES \
    --chain-id "$C1" --claimed-review-ticket "$T1" >/dev/null \
  && field_ok "$TF1" 'j.chainOutcome==="max-rounds"&&j.chainDone===true' \
  && field_ok "$RF1" 'j.stage==="BLOCKED"&&j.blocked.code==="TDD_MAX_ROUNDS"'; then
  check "M2 terminal self-review carries the immutable max outcome into outer BLOCKED" PASS
else check "M2 terminal self-review carries the immutable max outcome into outer BLOCKED" FAIL; fi

CFG_OFF="$TMP/self-review-off.json"
printf '%s\n' '{"hooks":{"autoFixMaxRounds":1,"selfReview":false}}' >"$CFG_OFF"
P2="$TMP/off"; mkdir -p "$P2"; R2=post_max_review_off; S2=post_max_session_off; C2=post-max-chain-off
approve "$P2" "$R2" "$S2" || exit 1
CLAUDE_PROJECT_DIR="$P2" ZENSU_CONFIG="$CFG_OFF" bash "$LOG" --tdd-begin --session "$S2" \
  --autopilot-run "$R2" --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id "$C2" >/dev/null
CLAUDE_PROJECT_DIR="$P2" ZENSU_CONFIG="$CFG_OFF" bash "$LOG" --tdd-complete --session "$S2" \
  --autopilot-run "$R2" --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id "$C2" >/dev/null
run_max_hook "$P2" "$S2" "$CFG_OFF"
TF2="$TDD_STATE_DIR/tdd-phase-${S2}.json"; RF2="$(autopilot_run_file "$R2" "$P2")"
if field_ok "$TF2" 'j.chainOutcome==="max-rounds"&&j.chainDone===true' \
  && field_ok "$RF2" 'j.stage==="BLOCKED"&&j.blocked.code==="TDD_MAX_ROUNDS"'; then
  check "M3 no-self-review path closes inner and outer max-rounds atomically" PASS
else check "M3 no-self-review path closes inner and outer max-rounds atomically" FAIL; fi

# Simulate a process crash immediately after the ticket claim. Recovery has
# only the atomically returned binding and must be able to land outcome plus
# codeReviewDone in one exact, retry-safe inner CAS.
P3="$TMP/crash"; mkdir -p "$P3"
export CLAUDE_PROJECT_DIR="$P3"
S3=post_max_crash_session; R3=post_max_crash_run; C3=post-max-crash-chain
tdd_begin_session "$S3" false true false "" "$R3" 3 VALIDATE "$C3" >/dev/null
T3="$(tdd_issue_review_ticket "$S3")"
CF3="$P3/.zensu/state/rounds-${S3}.json"
CLAIM3="$(tdd_consume_review_ticket_context "$S3" "$T3" "$CF3" 2>/dev/null)"
TF3="$(tdd_state_file "$S3")"
if [ -n "$CLAIM3" ] \
  && CLAIM="$CLAIM3" node -e '
    const value=JSON.parse(process.env.CLAIM);
    process.exit(value.next===1 && value.autopilot
      && value.autopilot.runId==="post_max_crash_run"
      && value.autopilot.attempt===3
      && value.autopilot.returnStage==="VALIDATE"
      && value.autopilot.chainId==="post-max-crash-chain"
      && value.autopilot.outcome==="" ? 0 : 1);
  ' \
  && field_ok "$TF3" 'j.reviewTicketConsumed===true&&j.chainOutcome===""&&j.codeReviewDone===false' \
  && tdd_mark_autopilot_max_round_handoff "$S3" "$R3" 3 VALIDATE "$C3" "$T3" \
  && field_ok "$TF3" 'j.chainOutcome==="max-rounds"&&j.codeReviewDone===true&&j.chainDone===false&&j.selfReviewFixed===false'; then
  D3="$(digest "$TF3")"; I3="$(inode "$TF3")"
  if tdd_mark_autopilot_max_round_handoff "$S3" "$R3" 3 VALIDATE "$C3" "$T3" \
    && [ "$(digest "$TF3")" = "$D3" ] && [ "$(inode "$TF3")" = "$I3" ]; then
    check "M4 crash-after-claim recovery atomically hands off and exact retry is stable" PASS
  else check "M4 crash recovery retry stability" FAIL; fi
else check "M4 crash-after-claim recovery atomic handoff" FAIL; fi

if grep -q 'tdd_mark_autopilot_max_round_handoff' "$POST" \
  && ! grep -q 'tdd_set_chain_outcome' "$POST" \
  && grep -q -- '--outcome max-rounds' "$POST"; then
  check "M5 hook uses atomic handoff for self-review and direct bound finish without it" PASS
else check "M5 max-round hook wiring is free of split outcome writes" FAIL; fi

echo "----"; echo "test-autopilot-post-review-max-rounds: $PASS PASS / $FAIL FAIL"; [ "$FAIL" -eq 0 ]
