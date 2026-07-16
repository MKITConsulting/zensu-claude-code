#!/bin/bash
# Exact linkage and crash reconciliation between inner TDD and outer Autopilot.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
PHASE="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
PASS=0; FAIL=0
check() { if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }

[ -f "$LIB" ] || { check "C1 state library exists" FAIL; exit 1; }
source "$LIB"; source "$PHASE"
TMP="$(mktemp -d -t zensu-autopilot-chain-XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$TMP/missing-config.json"

approve() {
  local project="$1" run="$2" owner="$3" sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  autopilot_begin_run "$run" "$owner" "$project" >/dev/null \
    && autopilot_apply_event "$run" "plan-${run}" PLAN_APPROVED "{\"approvedPlanSha256\":\"$sha\"}" "$project" >/dev/null
}
field_ok() { FILE="$1" EXPR="$2" node -e 'const j=require(process.env.FILE);process.exit(Function("j",`return Boolean(${process.env.EXPR})`)(j)?0:1)' 2>/dev/null; }
digest() { node -e 'const fs=require("fs"),crypto=require("crypto");process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$1"; }

P1="$TMP/pass"; mkdir -p "$P1"; R1=chain_run_pass; S1=chain_session_pass; C1=chain-pass-001
approve "$P1" "$R1" "$S1" || exit 1
CLAUDE_PROJECT_DIR="$P1" bash "$LOG" --tdd-begin --session "$S1" --autopilot-run "$R1" --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id "$C1" >/dev/null
RF1="$(autopilot_run_file "$R1" "$P1")"; TF1="$P1/.zensu/state/tdd-phase-${S1}.json"
if field_ok "$RF1" 'j.stage==="TDD_RUNNING"&&j.tdd.attempt===1&&j.tdd.chainId==="chain-pass-001"' \
  && field_ok "$TF1" 'j.autopilotRunId==="chain_run_pass"&&j.autopilotAttempt===1&&j.autopilotReturnStage==="GATES"&&j.chainId==="chain-pass-001"'; then
  check "C1 TDD start binds the same run, attempt, session, chain, and return stage" PASS
else check "C1 TDD start binds exact inner/outer context" FAIL; fi

CLAUDE_PROJECT_DIR="$P1" bash "$LOG" --tdd-complete --session "$S1" \
  --autopilot-run "$R1" --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id "$C1" >/dev/null
CLAUDE_PROJECT_DIR="$P1" bash "$LOG" --chain-done --session "$S1" \
  --autopilot-run "$R1" --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id "$C1" --outcome pass >/dev/null
if field_ok "$RF1" 'j.stage==="GATES"&&j.tdd.outcome==="pass"' && field_ok "$TF1" 'j.chainDone===true'; then
  check "C2 guarded inner terminus returns to the exact outer stage" PASS
else check "C2 guarded inner terminus returns to the exact outer stage" FAIL; fi

BEFORE_DUP="$(digest "$RF1")"
if CLAUDE_PROJECT_DIR="$P1" bash "$LOG" --chain-done --session "$S1" \
    --autopilot-run "$R1" --autopilot-attempt 1 --autopilot-return-stage GATES \
    --chain-id "$C1" --outcome pass >/dev/null \
  && [ "$(digest "$RF1")" = "$BEFORE_DUP" ]; then
  check "C3 repeated guarded terminus reconciles idempotently" PASS
else
  check "C3 repeated guarded terminus reconciles idempotently" FAIL
fi

P2="$TMP/max"; mkdir -p "$P2"; R2=chain_run_max; S2=chain_session_max; C2=chain-max-001
approve "$P2" "$R2" "$S2" || exit 1
CLAUDE_PROJECT_DIR="$P2" bash "$LOG" --tdd-begin --session "$S2" --autopilot-run "$R2" --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id "$C2" >/dev/null
CLAUDE_PROJECT_DIR="$P2" bash "$LOG" --tdd-complete --session "$S2" \
  --autopilot-run "$R2" --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id "$C2" >/dev/null
CLAUDE_PROJECT_DIR="$P2" bash "$LOG" --chain-done --session "$S2" \
  --autopilot-run "$R2" --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id "$C2" --outcome max-rounds >/dev/null
RF2="$(autopilot_run_file "$R2" "$P2")"
field_ok "$RF2" 'j.stage==="BLOCKED"&&j.blocked.code==="TDD_MAX_ROUNDS"' \
  && check "C4 max-rounds outcome blocks the outer run instead of advancing" PASS \
  || check "C4 max-rounds outcome blocks the outer run instead of advancing" FAIL

P3="$TMP/crash"; mkdir -p "$P3"; R3=chain_run_crash; S3=chain_session_crash; C3=chain-crash-001
approve "$P3" "$R3" "$S3" || exit 1
CLAUDE_PROJECT_DIR="$P3" bash "$LOG" --tdd-begin --session "$S3" --autopilot-run "$R3" --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id "$C3" >/dev/null
CLAUDE_PROJECT_DIR="$P3" bash "$LOG" --tdd-complete --session "$S3" \
  --autopilot-run "$R3" --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id "$C3" >/dev/null
CLAUDE_PROJECT_DIR="$P3" bash -c 'source "$1"; tdd_finish_autopilot_chain "$2" "$3" 1 "$4" pass' \
  _ "$PHASE" "$S3" "$R3" "$C3"
RF3="$(autopilot_run_file "$R3" "$P3")"
OUT3="$(printf '{\"session_id\":\"%s\"}' "$S3" | CLAUDE_PROJECT_DIR="$P3" bash "$STOP" 2>/dev/null)"
if printf '%s' "$OUT3" | grep -q '"decision":"block"' && field_ok "$RF3" 'j.stage==="GATES"'; then
  check "C5 Stop heals inner-done/outer-running crash window then still blocks" PASS
else check "C5 Stop heals the two-file crash window" FAIL; fi

P4="$TMP/wrong-return"; mkdir -p "$P4"; R4=chain_run_wrong; S4=chain_session_wrong
approve "$P4" "$R4" "$S4" || exit 1
if ! CLAUDE_PROJECT_DIR="$P4" bash "$LOG" --tdd-begin --session "$S4" --autopilot-run "$R4" --autopilot-attempt 1 --autopilot-return-stage VALIDATE --chain-id chain-wrong-001 >/dev/null 2>&1 \
  && field_ok "$(autopilot_run_file "$R4" "$P4")" 'j.stage==="AWAIT_TDD"' \
  && [ ! -e "$P4/.zensu/state/tdd-phase-${S4}.json" ]; then
  check "C6 wrong return-stage binding is rejected before inner mutation" PASS
else check "C6 wrong return-stage binding is rejected before inner mutation" FAIL; fi

P5="$TMP/standalone"; mkdir -p "$P5"; S5=standalone_tdd
if CLAUDE_PROJECT_DIR="$P5" bash "$LOG" --tdd-begin --session "$S5" >/dev/null \
  && CLAUDE_PROJECT_DIR="$P5" bash "$LOG" --tdd-complete --session "$S5" >/dev/null \
  && CLAUDE_PROJECT_DIR="$P5" bash "$LOG" --chain-done --session "$S5" >/dev/null; then
  check "C7 standalone TDD remains backward compatible" PASS
else check "C7 standalone TDD remains backward compatible" FAIL; fi

P6="$TMP/concurrent-start"; mkdir -p "$P6"; R6=chain_run_parallel_start; S6=chain_session_parallel_start
approve "$P6" "$R6" "$S6" || exit 1
(
  CLAUDE_PROJECT_DIR="$P6" bash "$LOG" --tdd-begin --session "$S6" --autopilot-run "$R6" \
    --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id chain-parallel-a >/dev/null 2>&1
  printf '%s' "$?" >"$P6/a.rc"
) &
pid_a=$!
(
  CLAUDE_PROJECT_DIR="$P6" bash "$LOG" --tdd-begin --session "$S6" --autopilot-run "$R6" \
    --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id chain-parallel-b >/dev/null 2>&1
  printf '%s' "$?" >"$P6/b.rc"
) &
pid_b=$!
wait "$pid_a"; wait "$pid_b"
RF6="$(autopilot_run_file "$R6" "$P6")"; TF6="$P6/.zensu/state/tdd-phase-${S6}.json"
if [ "$(cat "$P6/a.rc")" != "$(cat "$P6/b.rc")" ] \
  && { [ "$(cat "$P6/a.rc")" = 0 ] || [ "$(cat "$P6/b.rc")" = 0 ]; } \
  && RF="$RF6" TF="$TF6" node -e '
    const o=require(process.env.RF), i=require(process.env.TF);
    process.exit(o.stage==="TDD_RUNNING" && o.tdd.chainId===i.chainId
      && o.tdd.attempt===i.autopilotAttempt && o.tdd.sessionId===i.session_id ? 0 : 1);
  ' 2>/dev/null; then
  check "C8 concurrent bound starts select one generation without inner/outer split-brain" PASS
else check "C8 concurrent bound starts select one generation without inner/outer split-brain" FAIL; fi

WIN_CHAIN="$(TF="$TF6" node -e 'process.stdout.write(require(process.env.TF).chainId)')"
CLAUDE_PROJECT_DIR="$P6" bash "$LOG" --tdd-complete --session "$S6" \
  --autopilot-run "$R6" --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id "$WIN_CHAIN" >/dev/null
(
  CLAUDE_PROJECT_DIR="$P6" bash "$LOG" --chain-done --session "$S6" \
    --autopilot-run "$R6" --autopilot-attempt 1 --autopilot-return-stage GATES \
    --chain-id "$WIN_CHAIN" --outcome pass >/dev/null 2>&1
  printf '%s' "$?" >"$P6/pass.rc"
) &
pid_pass=$!
(
  CLAUDE_PROJECT_DIR="$P6" bash "$LOG" --chain-done --session "$S6" \
    --autopilot-run "$R6" --autopilot-attempt 1 --autopilot-return-stage GATES \
    --chain-id "$WIN_CHAIN" --outcome max-rounds >/dev/null 2>&1
  printf '%s' "$?" >"$P6/max.rc"
) &
pid_max=$!
wait "$pid_pass"; wait "$pid_max"
if [ "$(cat "$P6/pass.rc")" != "$(cat "$P6/max.rc")" ] \
  && { [ "$(cat "$P6/pass.rc")" = 0 ] || [ "$(cat "$P6/max.rc")" = 0 ]; } \
  && RF="$RF6" TF="$TF6" node -e '
    const o=require(process.env.RF), i=require(process.env.TF);
    const outer=o.tdd.outcome;
    const stageOk=outer==="pass" ? o.stage==="GATES" : outer==="max-rounds" && o.stage==="BLOCKED";
    process.exit(i.chainDone===true && i.chainOutcome===outer && stageOk ? 0 : 1);
  ' 2>/dev/null; then
  check "C9 concurrent conflicting termini commit one immutable matching outcome" PASS
else check "C9 concurrent conflicting termini commit one immutable matching outcome" FAIL; fi

P7="$TMP/corrupt-link"; mkdir -p "$P7"; R7=chain_run_corrupt; S7=chain_session_corrupt; C7=chain-corrupt-001
approve "$P7" "$R7" "$S7" || exit 1
CLAUDE_PROJECT_DIR="$P7" bash "$LOG" --tdd-begin --session "$S7" --autopilot-run "$R7" \
  --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id "$C7" >/dev/null
CLAUDE_PROJECT_DIR="$P7" bash "$LOG" --tdd-complete --session "$S7" \
  --autopilot-run "$R7" --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id "$C7" >/dev/null
TF7="$P7/.zensu/state/tdd-phase-${S7}.json"
TF="$TF7" node -e 'const fs=require("fs"),s=require(process.env.TF);delete s.chainId;fs.writeFileSync(process.env.TF,JSON.stringify(s,null,2));'
if ! CLAUDE_PROJECT_DIR="$P7" bash "$LOG" --chain-done --session "$S7" \
    --autopilot-run "$R7" --autopilot-attempt 1 --autopilot-return-stage GATES \
    --chain-id "$C7" --outcome pass >/dev/null 2>&1 \
  && field_ok "$TF7" 'j.chainDone===false'; then
  check "C10 corrupt partial Autopilot linkage fails closed before chain mutation" PASS
else check "C10 corrupt partial Autopilot linkage fails closed before chain mutation" FAIL; fi

P8="$TMP/standalone-conflict"; mkdir -p "$P8"; R8=chain_run_active; S8=chain_session_active
approve "$P8" "$R8" "$S8" || exit 1
if ! CLAUDE_PROJECT_DIR="$P8" bash "$LOG" --tdd-begin --session "$S8" >/dev/null 2>&1 \
  && [ ! -e "$P8/.zensu/state/tdd-phase-${S8}.json" ]; then
  check "C11 standalone begin cannot erase linkage of an active owned outer run" PASS
else check "C11 standalone begin cannot erase linkage of an active owned outer run" FAIL; fi

P9="$TMP/foreign-owner"; mkdir -p "$P9"; R9=chain_run_owner; S9=chain_session_owner
approve "$P9" "$R9" "$S9" || exit 1
if ! CLAUDE_PROJECT_DIR="$P9" CLAUDE_SESSION_ID=chain_session_foreign bash "$LOG" \
    --autopilot-event --run "$R9" --event CANCEL --event-id foreign-cancel --payload '{}' >/dev/null 2>&1 \
  && field_ok "$(autopilot_run_file "$R9" "$P9")" 'j.stage==="AWAIT_TDD"'; then
  check "C12 public Autopilot mutations reject a foreign session owner" PASS
else check "C12 public Autopilot mutations reject a foreign session owner" FAIL; fi

P10="$TMP/internal-event"; mkdir -p "$P10"; R10=chain_run_internal; S10=chain_session_internal
approve "$P10" "$R10" "$S10" || exit 1
if ! CLAUDE_PROJECT_DIR="$P10" CLAUDE_SESSION_ID="$S10" bash "$LOG" \
    --autopilot-event --run "$R10" --event TDD_STARTED --event-id forged-start \
    --payload '{"attempt":1,"returnStage":"GATES","chainId":"forged-chain"}' >/dev/null 2>&1 \
  && ! CLAUDE_PROJECT_DIR="$P10" CLAUDE_SESSION_ID="$S10" bash "$LOG" \
    --autopilot-event --run "$R10" --event TDD_CHAIN_DONE --event-id forged-done \
    --payload '{"attempt":1,"chainId":"forged-chain","outcome":"pass"}' >/dev/null 2>&1 \
  && field_ok "$(autopilot_run_file "$R10" "$P10")" \
    'j.stage==="AWAIT_TDD"&&!j.events.some(e=>e.eventType==="TDD_STARTED"||e.eventType==="TDD_CHAIN_DONE")'; then
  check "C13 public event CLI cannot forge the guarded inner TDD lifecycle" PASS
else check "C13 internal TDD events remain private to composite commands" FAIL; fi

# A delayed attempt-1 caller must never arm or terminate attempt 2, even though
# both generations reuse the same durable session file.
P11="$TMP/stale-generation"; mkdir -p "$P11"
R11=chain_run_generation; S11=chain_session_generation
C11A=chain-generation-attempt-1; C11B=chain-generation-attempt-2
approve "$P11" "$R11" "$S11" || exit 1
CLAUDE_PROJECT_DIR="$P11" bash "$LOG" --tdd-begin --session "$S11" \
  --autopilot-run "$R11" --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id "$C11A" >/dev/null
CLAUDE_PROJECT_DIR="$P11" bash "$LOG" --tdd-complete --session "$S11" \
  --autopilot-run "$R11" --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id "$C11A" >/dev/null
CLAUDE_PROJECT_DIR="$P11" bash "$LOG" --chain-done --session "$S11" \
  --autopilot-run "$R11" --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id "$C11A" --outcome pass >/dev/null
RF11="$(autopilot_run_file "$R11" "$P11")"; TF11="$P11/.zensu/state/tdd-phase-${S11}.json"
autopilot_apply_event "$R11" generation-gates-failed GATES_FAILED \
  '{"headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","reason":"retry fixture"}' "$P11" >/dev/null
CLAUDE_PROJECT_DIR="$P11" bash "$LOG" --tdd-begin --session "$S11" \
  --autopilot-run "$R11" --autopilot-attempt 2 --autopilot-return-stage GATES \
  --chain-id "$C11B" >/dev/null

BEFORE_STALE_COMPLETE="$(digest "$TF11")"
if ! CLAUDE_PROJECT_DIR="$P11" bash "$LOG" --tdd-complete --session "$S11" \
    --autopilot-run "$R11" --autopilot-attempt 1 --autopilot-return-stage GATES \
    --chain-id "$C11A" >/dev/null 2>&1 \
  && [ "$(digest "$TF11")" = "$BEFORE_STALE_COMPLETE" ] \
  && field_ok "$TF11" 'j.autopilotAttempt===2&&j.chainId==="chain-generation-attempt-2"&&j.implComplete===false&&j.chainDone===false'; then
  check "C14 stale completion cannot arm a newer Autopilot attempt" PASS
else check "C14 stale completion leaves attempt 2 unchanged" FAIL; fi

CLAUDE_PROJECT_DIR="$P11" bash "$LOG" --tdd-complete --session "$S11" \
  --autopilot-run "$R11" --autopilot-attempt 2 --autopilot-return-stage GATES \
  --chain-id "$C11B" >/dev/null
BEFORE_STALE_DONE_INNER="$(digest "$TF11")"
BEFORE_STALE_DONE_OUTER="$(digest "$RF11")"
if ! CLAUDE_PROJECT_DIR="$P11" bash "$LOG" --chain-done --session "$S11" \
    --autopilot-run "$R11" --autopilot-attempt 1 --autopilot-return-stage GATES \
    --chain-id "$C11A" --outcome pass >/dev/null 2>&1 \
  && [ "$(digest "$TF11")" = "$BEFORE_STALE_DONE_INNER" ] \
  && [ "$(digest "$RF11")" = "$BEFORE_STALE_DONE_OUTER" ] \
  && field_ok "$TF11" 'j.autopilotAttempt===2&&j.implComplete===true&&j.chainDone===false&&j.chainOutcome===""' \
  && field_ok "$RF11" 'j.stage==="TDD_RUNNING"&&j.tdd.attempt===2&&j.tdd.chainId==="chain-generation-attempt-2"'; then
  check "C15 stale terminus cannot close a newer Autopilot attempt" PASS
else check "C15 stale terminus leaves attempt 2 unchanged" FAIL; fi

BEFORE_RESET_INNER="$(digest "$TF11")"
BEFORE_RESET_OUTER="$(digest "$RF11")"
if ! CLAUDE_PROJECT_DIR="$P11" bash "$LOG" --tdd-reset --session "$S11" >/dev/null 2>&1 \
  && [ "$(digest "$TF11")" = "$BEFORE_RESET_INNER" ] \
  && [ "$(digest "$RF11")" = "$BEFORE_RESET_OUTER" ]; then
  check "C16 reset cannot sever an active durable outer run" PASS
else check "C16 active outer ownership survives reset" FAIL; fi

P12="$TMP/resumable-reset"; mkdir -p "$P12"
R12=chain_run_resumable; S12=chain_session_resumable; C12=chain-resumable-attempt-1
approve "$P12" "$R12" "$S12" || exit 1
CLAUDE_PROJECT_DIR="$P12" bash "$LOG" --tdd-begin --session "$S12" \
  --autopilot-run "$R12" --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id "$C12" >/dev/null
CLAUDE_PROJECT_DIR="$P12" bash "$LOG" --tdd-complete --session "$S12" \
  --autopilot-run "$R12" --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id "$C12" >/dev/null
CLAUDE_PROJECT_DIR="$P12" bash "$LOG" --chain-done --session "$S12" \
  --autopilot-run "$R12" --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id "$C12" --outcome max-rounds >/dev/null
RF12="$(autopilot_run_file "$R12" "$P12")"; TF12="$P12/.zensu/state/tdd-phase-${S12}.json"
BEFORE_RESET_BLOCKED_INNER="$(digest "$TF12")"
BEFORE_RESET_BLOCKED_OUTER="$(digest "$RF12")"
if ! CLAUDE_PROJECT_DIR="$P12" bash "$LOG" --tdd-reset --session "$S12" >/dev/null 2>&1 \
  && [ "$(digest "$TF12")" = "$BEFORE_RESET_BLOCKED_INNER" ] \
  && [ "$(digest "$RF12")" = "$BEFORE_RESET_BLOCKED_OUTER" ] \
  && field_ok "$RF12" 'j.stage==="BLOCKED"&&j.blocked.code==="TDD_MAX_ROUNDS"'; then
  check "C17 reset cannot sever a resumable durable outer run" PASS
else check "C17 resumable outer ownership survives reset" FAIL; fi

# A standalone command may read `{}` immediately before a bound Autopilot
# generation replaces the same Inner file. Its eventual mutation must still
# prove that all linkage keys are absent while holding the Inner lock.
P13="$TMP/standalone-to-bound-race"; mkdir -p "$P13"
R13=chain_run_standalone_race; S13=chain_session_standalone_race
C13=chain-standalone-race-bound
CLAUDE_PROJECT_DIR="$P13" bash "$LOG" --tdd-begin --session "$S13" >/dev/null || exit 1
STANDALONE_CTX13="$(CLAUDE_PROJECT_DIR="$P13" tdd_autopilot_context \
  "$(CLAUDE_PROJECT_DIR="$P13" tdd_state_file "$S13")" "$S13")"
approve "$P13" "$R13" "$S13" || exit 1
CLAUDE_PROJECT_DIR="$P13" bash "$LOG" --tdd-begin --session "$S13" \
  --autopilot-run "$R13" --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id "$C13" >/dev/null || exit 1
TF13="$P13/.zensu/state/tdd-phase-${S13}.json"
BEFORE_STALE_STANDALONE_COMPLETE="$(digest "$TF13")"
if [ "$STANDALONE_CTX13" = '{}' ] \
  && declare -F tdd_mark_impl_complete_standalone >/dev/null \
  && grep -qF 'tdd_mark_impl_complete_standalone "$session_val"' "$LOG" \
  && ! CLAUDE_PROJECT_DIR="$P13" tdd_mark_impl_complete_standalone "$S13" >/dev/null 2>&1 \
  && [ "$(digest "$TF13")" = "$BEFORE_STALE_STANDALONE_COMPLETE" ] \
  && field_ok "$TF13" 'j.autopilotAttempt===1&&j.chainId==="chain-standalone-race-bound"&&j.implComplete===false'; then
  check "C18 stale standalone completion cannot arm a newly bound generation" PASS
else check "C18 standalone completion must use an atomic linkage-absent CAS" FAIL; fi

CLAUDE_PROJECT_DIR="$P13" tdd_mark_impl_complete_bound "$S13" "$R13" 1 "$C13" || exit 1
BEFORE_STALE_STANDALONE_DONE="$(digest "$TF13")"
if ! CLAUDE_PROJECT_DIR="$P13" tdd_mark_unclaimed_review "$S13" chainDone >/dev/null 2>&1 \
  && [ "$(digest "$TF13")" = "$BEFORE_STALE_STANDALONE_DONE" ] \
  && field_ok "$TF13" 'j.autopilotAttempt===1&&j.chainId==="chain-standalone-race-bound"&&j.implComplete===true&&j.chainDone===false'; then
  check "C19 stale standalone unclaimed terminus cannot close a bound generation" PASS
else check "C19 unclaimed terminus must prove linkage absence under lock" FAIL; fi

BEFORE_STALE_STANDALONE_RESET="$(digest "$TF13")"
if declare -F tdd_clear_standalone_session >/dev/null \
  && grep -qF 'tdd_clear_standalone_session "$session_val"' "$LOG" \
  && ! CLAUDE_PROJECT_DIR="$P13" tdd_clear_standalone_session "$S13" >/dev/null 2>&1 \
  && [ "$(digest "$TF13")" = "$BEFORE_STALE_STANDALONE_RESET" ] \
  && field_ok "$TF13" 'j.active===true&&j.autopilotAttempt===1&&j.chainId==="chain-standalone-race-bound"&&j.implComplete===true'; then
  check "C20 stale standalone reset cannot deactivate a newly bound generation" PASS
else check "C20 standalone reset must use an atomic linkage-absent clear CAS" FAIL; fi

echo "----"; echo "test-autopilot-chain-integration: $PASS PASS / $FAIL FAIL"; [ "$FAIL" -eq 0 ]
