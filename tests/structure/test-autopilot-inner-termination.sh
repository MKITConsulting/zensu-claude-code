#!/bin/bash
# Atomic, generation- and ticket-bound inner Autopilot chain termination.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PHASE="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"
PASS=0
FAIL=0
check() {
  if [ "$2" = PASS ]; then
    echo "  PASS  $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $1"
    FAIL=$((FAIL + 1))
  fi
}

if [ -f "$PHASE" ] && bash -n "$PHASE" 2>/dev/null; then
  check "A1 TDD phase library exists and parses" PASS
else
  check "A1 TDD phase library exists and parses" FAIL
  exit 1
fi

TMP="$(mktemp -d -t zensu-inner-terminus-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
mkdir -p "$PROJECT"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PROJECT_DIR="$PROJECT"
export ZENSU_CONFIG="$TMP/no-config.json"
export ZENSU_TEST_PLUGIN_DATA="$TMP/plugin-data"

source "$PHASE"

state_file() { tdd_state_file "$1"; }
start_session() {
  # shellcheck disable=SC1090
  source "$BASELINE" "$1"
}
digest() { node -e 'const fs=require("fs"),crypto=require("crypto");process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$1"; }
inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1" 2>/dev/null; }
field_ok() {
  FILE="$1" EXPR="$2" node -e '
    try {
      const j = JSON.parse(require("fs").readFileSync(process.env.FILE, "utf8"));
      process.exit(Function("j", `return Boolean(${process.env.EXPR})`)(j) ? 0 : 1);
    } catch (_) { process.exit(1); }
  ' 2>/dev/null
}
begin_bound() {
  tdd_begin_session "$1" false true false "" "$2" "$3" "$4" "$5" >/dev/null
}
claim_ticket() {
  local session="$1" ticket
  ticket="$(tdd_issue_review_ticket "$session")" || return 1
  [ "$(tdd_consume_review_ticket "$session" "$ticket")" = "1" ] || return 1
  printf '%s' "$ticket"
}

# Unclaimed zero-diff style termination: outcome and done land together, and
# an identical retry performs no replacement write.
S1_RAW=inner_unclaimed_01
R1=run_unclaimed_01
C1=chain-unclaimed-01
start_session "$S1_RAW"
S1="$ZENSU_SESSION_KEY"
if begin_bound "$S1" "$R1" 1 GATES "$C1" \
  && tdd_finish_autopilot_chain "$S1" "$R1" 1 "$C1" no-changes \
  && field_ok "$(state_file "$S1")" 'j.chainOutcome==="no-changes"&&j.chainDone===true&&j.reviewTicket===""&&j.reviewTicketConsumed===true&&j.reviewRound===0'; then
  check "A2 unclaimed exact generation seals outcome and chainDone atomically" PASS
else
  check "A2 unclaimed exact generation seals outcome and chainDone atomically" FAIL
fi

SF1="$(state_file "$S1")"
D1="$(digest "$SF1")"
I1="$(inode "$SF1")"
if tdd_finish_autopilot_chain "$S1" "$R1" 1 "$C1" no-changes \
  && [ "$(digest "$SF1")" = "$D1" ] && [ "$(inode "$SF1")" = "$I1" ]; then
  check "A3 identical finish retry is an rc0 true no-op" PASS
else
  check "A3 identical finish retry is an rc0 true no-op" FAIL
fi

if ! tdd_finish_autopilot_chain "$S1" "$R1" 1 "$C1" pass >/dev/null 2>&1 \
  && ! tdd_finish_autopilot_chain "$S1" wrong_run 1 "$C1" no-changes >/dev/null 2>&1 \
  && ! tdd_finish_autopilot_chain "$S1" "$R1" 2 "$C1" no-changes >/dev/null 2>&1 \
  && ! tdd_finish_autopilot_chain "$S1" "$R1" 1 wrong-chain no-changes >/dev/null 2>&1 \
  && [ "$(digest "$SF1")" = "$D1" ]; then
  check "A4 different outcome or generation conflicts without mutation" PASS
else
  check "A4 different outcome or generation conflicts without mutation" FAIL
fi

# Claimed reviewer completion requires the exact consumed ticket. Omitting it,
# inventing another one, or presenting an unconsumed ticket cannot terminate.
S2_RAW=inner_claimed_02
R2=run_claimed_02
C2=chain-claimed-02
start_session "$S2_RAW"
S2="$ZENSU_SESSION_KEY"
begin_bound "$S2" "$R2" 2 FIX_FINDINGS "$C2" || true
T2="$(claim_ticket "$S2")"
SF2="$(state_file "$S2")"
D2="$(digest "$SF2")"
if [ -n "$T2" ] \
  && ! tdd_finish_autopilot_chain "$S2" "$R2" 2 "$C2" pass >/dev/null 2>&1 \
  && ! tdd_finish_autopilot_chain "$S2" "$R2" 2 "$C2" pass rt_wrong_ticket >/dev/null 2>&1 \
  && [ "$(digest "$SF2")" = "$D2" ] \
  && tdd_finish_autopilot_chain "$S2" "$R2" 2 "$C2" pass "$T2" \
  && field_ok "$SF2" 'j.chainOutcome==="pass"&&j.chainDone===true&&j.reviewTicketConsumed===true&&j.reviewRound===1'; then
  check "A5 claimed completion accepts only its exact consumed ticket" PASS
else
  check "A5 claimed completion accepts only its exact consumed ticket" FAIL
fi

D2_DONE="$(digest "$SF2")"
I2_DONE="$(inode "$SF2")"
if tdd_finish_autopilot_chain "$S2" "$R2" 2 "$C2" pass "$T2" \
  && ! tdd_finish_autopilot_chain "$S2" "$R2" 2 "$C2" max-rounds "$T2" >/dev/null 2>&1 \
  && ! tdd_finish_autopilot_chain "$S2" "$R2" 2 "$C2" pass rt_other >/dev/null 2>&1 \
  && [ "$(digest "$SF2")" = "$D2_DONE" ] && [ "$(inode "$SF2")" = "$I2_DONE" ]; then
  check "A6 claimed retry is idempotent; changed ticket or outcome conflicts" PASS
else
  check "A6 claimed retry is idempotent; changed ticket or outcome conflicts" FAIL
fi

# max-rounds can be persisted before the self-review terminus, but only by the
# exact generation/ticket. Once present it is immutable and the final seal must
# carry the same value.
S3_RAW=inner_max_03
R3=run_max_03
C3=chain-max-03
start_session "$S3_RAW"
S3="$ZENSU_SESSION_KEY"
begin_bound "$S3" "$R3" 3 VALIDATE "$C3" || true
T3="$(claim_ticket "$S3")"
SF3="$(state_file "$S3")"
if [ -n "$T3" ] \
  && ! tdd_set_chain_outcome "$S3" max-rounds >/dev/null 2>&1 \
  && ! tdd_set_chain_outcome "$S3" max-rounds "$R3" 3 "$C3" rt_wrong >/dev/null 2>&1 \
  && ! tdd_set_chain_outcome "$S3" max-rounds wrong_run 3 "$C3" "$T3" >/dev/null 2>&1 \
  && ! tdd_set_chain_outcome "$S3" max-rounds "$R3" 4 "$C3" "$T3" >/dev/null 2>&1 \
  && ! tdd_set_chain_outcome "$S3" max-rounds "$R3" 3 wrong_chain "$T3" >/dev/null 2>&1 \
  && tdd_set_chain_outcome "$S3" max-rounds "$R3" 3 "$C3" "$T3" \
  && field_ok "$SF3" 'j.chainOutcome==="max-rounds"&&j.chainDone===false'; then
  check "A7 max-rounds persistence is generation- and ticket-bound" PASS
else
  check "A7 max-rounds persistence is generation- and ticket-bound" FAIL
fi

D3="$(digest "$SF3")"
I3="$(inode "$SF3")"
if tdd_set_chain_outcome "$S3" max-rounds "$R3" 3 "$C3" "$T3" \
  && ! tdd_set_chain_outcome "$S3" pass "$R3" 3 "$C3" "$T3" >/dev/null 2>&1 \
  && [ "$(digest "$SF3")" = "$D3" ] && [ "$(inode "$SF3")" = "$I3" ] \
  && tdd_finish_autopilot_chain "$S3" "$R3" 3 "$C3" max-rounds "$T3" \
  && field_ok "$SF3" 'j.chainOutcome==="max-rounds"&&j.chainDone===true'; then
  check "A8 max-rounds is immutable and seals only with the same outcome" PASS
else
  check "A8 max-rounds is immutable and seals only with the same outcome" FAIL
fi

# Partial linkage is corruption, not standalone state. Both the pre-persist and
# final CAS must fail closed and preserve the corrupt bytes for diagnosis.
S4_RAW=inner_partial_04
R4=run_partial_04
C4=chain-partial-04
start_session "$S4_RAW"
S4="$ZENSU_SESSION_KEY"
begin_bound "$S4" "$R4" 4 COVER "$C4" || true
SF4="$(state_file "$S4")"
FILE="$SF4" node -e '
  const fs=require("fs"), p=process.env.FILE, j=JSON.parse(fs.readFileSync(p,"utf8"));
  delete j.autopilotAttempt;
  fs.writeFileSync(p,JSON.stringify(j,null,2));
' 2>/dev/null
D4="$(digest "$SF4")"
if ! tdd_set_chain_outcome "$S4" pass "$R4" 4 "$C4" >/dev/null 2>&1 \
  && ! tdd_finish_autopilot_chain "$S4" "$R4" 4 "$C4" pass >/dev/null 2>&1 \
  && [ "$(digest "$SF4")" = "$D4" ]; then
  check "A9 partial Autopilot linkage fails closed without repair-by-guessing" PASS
else
  check "A9 partial Autopilot linkage fails closed without repair-by-guessing" FAIL
fi

# Malformed claimed state is neither a valid claimed completion nor the exact
# unclaimed zero-review shape.
S5_RAW=inner_ticket_corrupt_05
R5=run_ticket_corrupt_05
C5=chain-ticket-corrupt-05
start_session "$S5_RAW"
S5="$ZENSU_SESSION_KEY"
begin_bound "$S5" "$R5" 5 GATES "$C5" || true
SF5="$(state_file "$S5")"
FILE="$SF5" node -e '
  const fs=require("fs"), p=process.env.FILE, j=JSON.parse(fs.readFileSync(p,"utf8"));
  j.reviewTicket="rt_malformed_round"; j.reviewTicketConsumed=true; j.reviewRound=0;
  fs.writeFileSync(p,JSON.stringify(j,null,2));
' 2>/dev/null
D5="$(digest "$SF5")"
if ! tdd_finish_autopilot_chain "$S5" "$R5" 5 "$C5" pass >/dev/null 2>&1 \
  && ! tdd_finish_autopilot_chain "$S5" "$R5" 5 "$C5" pass rt_malformed_round >/dev/null 2>&1 \
  && [ "$(digest "$SF5")" = "$D5" ]; then
  check "A10 malformed ticket/round combinations fail closed" PASS
else
  check "A10 malformed ticket/round combinations fail closed" FAIL
fi

# Two different outcomes racing under the same inner lock cannot produce a
# hybrid. Exactly one wins; the loser observes the immutable outcome conflict.
S6_RAW=inner_race_06
R6=run_race_06
C6=chain-race-06
start_session "$S6_RAW"
S6="$ZENSU_SESSION_KEY"
begin_bound "$S6" "$R6" 6 CONVERGE "$C6" || true
(
  tdd_finish_autopilot_chain "$S6" "$R6" 6 "$C6" pass >/dev/null 2>&1
  printf '%s' "$?" > "$TMP/race-pass.rc"
) &
P_PASS=$!
(
  tdd_finish_autopilot_chain "$S6" "$R6" 6 "$C6" max-rounds >/dev/null 2>&1
  printf '%s' "$?" > "$TMP/race-max.rc"
) &
P_MAX=$!
wait "$P_PASS" 2>/dev/null || true
wait "$P_MAX" 2>/dev/null || true
RC_PASS="$(cat "$TMP/race-pass.rc" 2>/dev/null)"
RC_MAX="$(cat "$TMP/race-max.rc" 2>/dev/null)"
SF6="$(state_file "$S6")"
if { [ "$RC_PASS" = 0 ] && [ "$RC_MAX" != 0 ]; } \
  || { [ "$RC_PASS" != 0 ] && [ "$RC_MAX" = 0 ]; }; then
  if field_ok "$SF6" 'j.chainDone===true&&(j.chainOutcome==="pass"||j.chainOutcome==="max-rounds")'; then
    check "A11 concurrent different outcomes linearize to exactly one winner" PASS
  else
    check "A11 concurrent different outcomes linearize to exactly one winner" FAIL
  fi
else
  check "A11 concurrent different outcomes linearize to exactly one winner" FAIL
fi

echo "----"
echo "test-autopilot-inner-termination: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
