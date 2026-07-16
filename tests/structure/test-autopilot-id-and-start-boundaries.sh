#!/bin/bash
# Durable identifier boundaries and standalone/bound start serialization.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"
PASS=0; FAIL=0
check() {
  if [ "$2" = PASS ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
ROOT="$(mktemp -d -t zensu-autopilot-boundaries-XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
# shellcheck disable=SC1090
source "$STATE_LIB"

digest() { node -e 'const fs=require("fs"),crypto=require("crypto");process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$1"; }
session_key() { node "$CORE" session-key "$1"; }
activate_session() {
  export CLAUDE_PROJECT_DIR="$1"
  # shellcheck disable=SC1090
  source "$BASELINE" "$2"
}
field_ok() {
  FILE="$1" EXPR="$2" node -e '
    const value=require(process.env.FILE);
    process.exit(Function("value",`return Boolean(${process.env.EXPR})`)(value)?0:1);
  ' 2>/dev/null
}
approve() {
  local project="$1" run="$2" sid="$3" owner_key
  mkdir -p "$project"
  owner_key="$(session_key "$sid")" || return 1
  [ "${ZENSU_SESSION_KEY:-}" = "$owner_key" ] || return 1
  autopilot_begin_run "$run" "$owner_key" "$project" >/dev/null \
    && autopilot_apply_event "$run" boundary-plan PLAN_APPROVED \
      '{"approvedPlanSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' \
      "$project" "$owner_key" >/dev/null
}

ID128="$(printf 'r%.0s' {1..128})"
ID129="${ID128}r"

P1="$ROOT/run-128"; mkdir -p "$P1"
activate_session "$P1" boundary_run_session || exit 1
if CLAUDE_PROJECT_DIR="$P1" bash "$LOG" --autopilot-begin \
    --run "$ID128" --session boundary_run_session >/dev/null \
  && field_ok "$(autopilot_run_file "$ID128" "$P1")" \
    'value.runId.length===128&&value.stage==="PLANNING"'; then
  check "B1 a 128-character durable run id is accepted" PASS
else check "B1 a 128-character durable run id is accepted" FAIL; fi

P2="$ROOT/run-129"; mkdir -p "$P2"
activate_session "$P2" boundary_run_reject || exit 1
set +e
CLAUDE_PROJECT_DIR="$P2" bash "$LOG" --autopilot-begin \
  --run "$ID129" --session boundary_run_reject >/dev/null 2>&1
RC2=$?
set -e
if [ "$RC2" -ne 0 ] && [ ! -e "$P2/.zensu/state/autopilot-active.json" ] \
    && [ ! -e "$P2/.zensu/state/autopilot-run-${ID129}.json" ]; then
  check "B2 a 129-character durable run id is rejected without mutation" PASS
else check "B2 a 129-character durable run id is rejected without mutation" FAIL; fi

P3="$ROOT/empty-session"; mkdir -p "$P3"
activate_session "$P3" boundary_empty_host || exit 1
set +e
CLAUDE_PROJECT_DIR="$P3" bash "$LOG" --autopilot-begin \
  --run boundary_empty_session --session '' >/dev/null 2>&1
RC3=$?
set -e
if [ "$RC3" -eq 2 ] && [ ! -e "$P3/.zensu/state/autopilot-active.json" ]; then
  check "B3 explicit empty Autopilot session is rc=2 with no pointer" PASS
else check "B3 empty Autopilot session fails before mutation" FAIL; fi

CHAIN128="$(printf 'c%.0s' {1..128})"
CHAIN129="${CHAIN128}c"
P4="$ROOT/chain-128"; R4=boundary_chain_run; S4=boundary_chain_session
activate_session "$P4" "$S4" || exit 1
approve "$P4" "$R4" "$S4" || exit 1
if CLAUDE_PROJECT_DIR="$P4" bash "$LOG" --tdd-begin --session "$S4" \
    --autopilot-run "$R4" --autopilot-attempt 1 --autopilot-return-stage GATES \
    --chain-id "$CHAIN128" >/dev/null \
  && CLAUDE_PROJECT_DIR="$P4" bash "$LOG" --tdd-complete --session "$S4" \
    --autopilot-run "$R4" --autopilot-attempt 1 --autopilot-return-stage GATES \
    --chain-id "$CHAIN128" >/dev/null \
  && CLAUDE_PROJECT_DIR="$P4" bash "$LOG" --chain-done --session "$S4" \
    --autopilot-run "$R4" --autopilot-attempt 1 --autopilot-return-stage GATES \
    --chain-id "$CHAIN128" --outcome no-changes >/dev/null \
  && field_ok "$(autopilot_run_file "$R4" "$P4")" \
    'value.stage==="GATES"&&value.events.filter(e=>e.eventType==="TDD_STARTED"||e.eventType==="TDD_CHAIN_DONE").every(e=>e.eventId.length<=128)&&value.events.filter(e=>e.eventType==="TDD_STARTED"||e.eventType==="TDD_CHAIN_DONE").length===2'; then
  check "B4 a 128-character chain uses bounded deterministic event ids" PASS
else check "B4 a 128-character chain completes with bounded event ids" FAIL; fi

P5="$ROOT/chain-129"; R5=boundary_chain_reject_run; S5=boundary_chain_reject_session
activate_session "$P5" "$S5" || exit 1
approve "$P5" "$R5" "$S5" || exit 1
RF5="$(autopilot_run_file "$R5" "$P5")"; BEFORE5="$(digest "$RF5")"
TF5="$(tdd_state_file "$S5")"; BEFORE5_INNER="$(digest "$TF5")"
set +e
CLAUDE_PROJECT_DIR="$P5" bash "$LOG" --tdd-begin --session "$S5" \
  --autopilot-run "$R5" --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id "$CHAIN129" >/dev/null 2>&1
RC5=$?
set -e
if [ "$RC5" -eq 2 ] && [ "$(digest "$RF5")" = "$BEFORE5" ] \
    && [ "$(digest "$TF5")" = "$BEFORE5_INNER" ]; then
  check "B5 a 129-character chain is rejected byte-stably" PASS
else check "B5 a 129-character chain cannot partially start" FAIL; fi

P6="$ROOT/blocked-standalone"; R6=boundary_blocked_run; S6=boundary_blocked_owner
CALLER6=boundary_blocked_standalone
activate_session "$P6" "$S6" || exit 1
S6_KEY="$ZENSU_SESSION_KEY"
activate_session "$P6" "$CALLER6" || exit 1
mkdir -p "$P6"; autopilot_begin_run "$R6" "$S6_KEY" "$P6" >/dev/null
autopilot_apply_event "$R6" boundary-block BLOCK '{"code":"BOUNDARY_BLOCK"}' \
  "$P6" "$S6_KEY" >/dev/null
RF6="$(autopilot_run_file "$R6" "$P6")"; BEFORE6="$(digest "$RF6")"
TF6="$(tdd_state_file "$CALLER6")"; BEFORE6_INNER="$(digest "$TF6")"
set +e
CLAUDE_PROJECT_DIR="$P6" bash "$LOG" --tdd-begin \
  --session "$CALLER6" >/dev/null 2>&1
RC6=$?
set -e
if [ "$RC6" -ne 0 ] && [ "$(digest "$RF6")" = "$BEFORE6" ] \
    && [ "$(digest "$TF6")" = "$BEFORE6_INNER" ]; then
  check "B6 resumable BLOCKED outer state rejects standalone TDD byte-stably" PASS
else check "B6 BLOCKED is not treated as a completed outer run" FAIL; fi

P7="$ROOT/start-race"; R7=boundary_race_run; S7=boundary_race_session
activate_session "$P7" "$S7" || exit 1
approve "$P7" "$R7" "$S7" || exit 1
(
  set +e
  CLAUDE_PROJECT_DIR="$P7" bash "$LOG" --tdd-begin --session "$S7" >/dev/null 2>&1
  printf '%s\n' "$?" > "$ROOT/race-standalone.rc"
) & PID_STANDALONE=$!
(
  set +e
  CLAUDE_PROJECT_DIR="$P7" bash "$LOG" --tdd-begin --session "$S7" \
    --autopilot-run "$R7" --autopilot-attempt 1 --autopilot-return-stage GATES \
    --chain-id boundary-race-chain >/dev/null 2>&1
  printf '%s\n' "$?" > "$ROOT/race-bound.rc"
) & PID_BOUND=$!
wait "$PID_STANDALONE"; wait "$PID_BOUND"
TF7="$(tdd_state_file "$S7")"
if [ "$(cat "$ROOT/race-standalone.rc")" -ne 0 ] \
  && [ "$(cat "$ROOT/race-bound.rc")" -eq 0 ] \
  && field_ok "$TF7" \
    'value.autopilotRunId==="boundary_race_run"&&value.autopilotAttempt===1&&value.chainId==="boundary-race-chain"' \
  && field_ok "$(autopilot_run_file "$R7" "$P7")" \
    'value.stage==="TDD_RUNNING"&&value.tdd.attempt===1&&value.tdd.chainId==="boundary-race-chain"'; then
  check "B7 concurrent standalone and bound starts cannot split Inner from Outer" PASS
else check "B7 start race leaves one exact bound generation" FAIL; fi

printf '%s\n' "----" "test-autopilot-id-and-start-boundaries: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
