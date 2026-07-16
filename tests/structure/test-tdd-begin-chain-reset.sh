#!/bin/bash
# --tdd-begin chain-flag lifecycle — hermetic walk (no live claude, no API).
#
# Proves the Stop-hook review-chain backstop re-arms for EVERY /zensu:tdd chain
# in a session, not just the first: a completed chain leaves chainDone=true in
# the per-session state, and before this fix a second --tdd-begin never cleared
# it, so stop-chain-enforcer released on the stale flag for every later chain
# (load-bearing since the /zensu:pilot conductor makes multiple same-session
# tdd delegations the designed path).
#   begin #1: chain walk implComplete -> stop BLOCKS -> chainDone -> stop allows
#   begin #2: implComplete/chainDone/codeReviewDone/selfReviewFixed all cleared,
#             integrated reviewRound/stopBlocks reset to zero, and the enforcer
#             BLOCKS again after the second --tdd-complete until a fresh
#             --chain-done lands
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
SESSION_CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
TDD_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

# --- hermetic environment (main-thread chain-state only) ---
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
PROJ="$(mktemp -d)"; export CLAUDE_PROJECT_DIR="$PROJ"
STATE_DIR="$CLAUDE_PROJECT_DIR/.zensu/state"
mkdir -p "$STATE_DIR"
export ZENSU_CONFIG="$STATE_DIR/no-such-config.json"
unset CLAUDE_AGENT_TYPE ZENSU_TDD_GATE ZENSU_TEST_WITNESS ZENSU_CHAIN 2>/dev/null || true
cleanup() { rm -rf "$PROJ"; }
trap cleanup EXIT

SID="lifecycle-$$"
SID_KEY="$(node "$SESSION_CORE" session-key "$SID")"
export ZENSU_SESSION_KEY="$SID_KEY"
LOG_STDERR="$STATE_DIR/log-stderr.txt"
# shellcheck disable=SC1090
source "$TDD_LIB"

# shellcheck disable=SC1090
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$SID"

log() { bash "$LOG" "$@" >/dev/null 2>>"$LOG_STDERR"; }

stop_dec() {
  printf '%s' '{"session_id":"'"$SID"'"}' | bash "$STOP" 2>/dev/null | node -e '
    let s="";process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}
      try{console.log(JSON.parse(s).decision==="block"?"block":"allow")}catch(_){console.log("allow")}});'
}

field() {  # echoes a validated state field (or "missing")
  STATE_FILE="$(bash -c '
    source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh" 2>/dev/null
    source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
    tdd_state_file "$ZENSU_SESSION_KEY"')" FLAG="$1" node -e '
    const fs=require("fs");
    try{const j=JSON.parse(fs.readFileSync(process.env.STATE_FILE,"utf8"));
      console.log(String(j[process.env.FLAG]));}catch(_){console.log("missing")}'
}

# --- chain #1: normal walk, enforcer releases on chainDone ---
log --tdd-begin
log --tdd-complete
D1="$(stop_dec)"
[ "$D1" = "block" ] && check "C1 chain #1: stop BLOCKS while implComplete && !chainDone" PASS \
                    || check "C1 chain #1: stop decision (got '$D1')" FAIL

log --code-review-done
log --self-review-fixed
log --chain-done
D2="$(stop_dec)"
[ "$D2" = "allow" ] && check "C2 chain #1: stop allows after --chain-done" PASS \
                    || check "C2 chain #1: stop decision (got '$D2')" FAIL

# Simulate budgets consumed during the first chain; a fresh begin owns their
# lifecycle and resets both in the same CAS document.
tdd_increment_counter "$SID" reviewRound >/dev/null
tdd_increment_counter "$SID" reviewRound >/dev/null
tdd_increment_counter "$SID" stopBlocks >/dev/null
log --workflow-begin --tools "link_test,create_revision"
log --phase IMPL --step stale-step
tdd_add_bypass "$SID" ZENSU_TDD_GATE >/dev/null

# --- begin #2: the four chain flags and both counters must be reset ---
BEFORE_SECOND_REVISION="$(field revision)"
printf '%s\n' '{"hooks":{"tddImplementation":true}}' >"$ZENSU_CONFIG"
log --tdd-begin
RESET_FAIL=0
for f in implComplete chainDone codeReviewDone selfReviewFixed; do
  V="$(field "$f")"
  [ "$V" = "false" ] || { RESET_FAIL=$((RESET_FAIL+1)); echo "      flag $f not cleared (got '$V')"; }
done
[ "$RESET_FAIL" -eq 0 ] && check "C3 begin #2 clears implComplete/chainDone/codeReviewDone/selfReviewFixed" PASS \
                        || check "C3 begin #2 chain-flag reset ($RESET_FAIL stale)" FAIL

COUNTER_FAIL=0
for f in reviewRound stopBlocks; do
  V="$(field "$f")"
  [ "$V" = "0" ] || { COUNTER_FAIL=$((COUNTER_FAIL+1)); echo "      counter $f not reset (got '$V')"; }
done
[ "$COUNTER_FAIL" -eq 0 ] && check "C3b begin #2 resets integrated reviewRound/stopBlocks" PASS \
                          || check "C3b begin #2 counter reset ($COUNTER_FAIL stale)" FAIL

ATOMIC_FAIL=0
for expected in 'phase=UNINITIALIZED' 'step_id=' 'workflowActive=false' 'workflowTools=' 'bypasses=' 'history=' 'vanilla=false'; do
  key="${expected%%=*}"; value="${expected#*=}"
  actual="$(field "$key")"
  [ "$actual" = "$value" ] || { ATOMIC_FAIL=$((ATOMIC_FAIL+1)); echo "      field $key not reset (got '$actual')"; }
done
[ "$ATOMIC_FAIL" -eq 0 ] && check "C3c begin #2 atomically resets FSM and workflow-window fields" PASS \
                         || check "C3c begin #2 atomic field reset ($ATOMIC_FAIL stale)" FAIL
AFTER_SECOND_REVISION="$(field revision)"
[ "$AFTER_SECOND_REVISION" = "$((BEFORE_SECOND_REVISION + 1))" ] \
  && check "C3d begin #2 performs exactly one CAS revision advance" PASS \
  || check "C3d begin #2 revision (before=$BEFORE_SECOND_REVISION after=$AFTER_SECOND_REVISION)" FAIL

D3="$(stop_dec)"
[ "$D3" = "allow" ] && check "C4 begin #2: stop allows while chain #2 has not completed impl" PASS \
                    || check "C4 begin #2: stop decision (got '$D3')" FAIL

# --- chain #2: the backstop must be LIVE again ---
log --tdd-complete
D4="$(stop_dec)"
[ "$D4" = "block" ] && check "C5 chain #2: stop BLOCKS again after second --tdd-complete (backstop re-armed)" PASS \
                    || check "C5 chain #2: stop decision (got '$D4')" FAIL

log --chain-done
D5="$(stop_dec)"
[ "$D5" = "allow" ] && check "C6 chain #2: stop allows after fresh --chain-done" PASS \
                    || check "C6 chain #2: stop decision (got '$D5')" FAIL

echo "----"
echo "test-tdd-begin-chain-reset: $PASS PASS / $FAIL FAIL"
if [ "$FAIL" -ne 0 ] && [ -s "$LOG_STDERR" ]; then
  echo "  captured zensu-log.sh stderr:"
  sed 's/^/    /' "$LOG_STDERR"
fi
[ "$FAIL" -eq 0 ]
