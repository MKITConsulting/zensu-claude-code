#!/bin/bash
# Pins stop-chain-enforcer.sh ESCAPE HATCHES + anti-deadlock budget cap (0.4.0):
#   ZENSU_CHAIN=off              -> never block (allow stop)
#   hooks.chainEnforcer=false    -> never block (allow stop)
#   consecutive blocks > CAP     -> allow stop + stderr warning (anti-deadlock)
#   blocks within budget         -> still block (control)
# Complements test-stop-enforcer-self-review-routing.sh, which pins the positive
# block + two-stage routing. Here we prove the release paths so a stalled chain
# can never wedge a session forever.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
TDD_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
STATE_DIR="$(mktemp -d)"; export STATE_DIR
PROJ="$(mktemp -d)"; export CLAUDE_PROJECT_DIR="$PROJ"
export ZENSU_CONFIG="$STATE_DIR/no-such-config.json"   # defaults: chainEnforcer enabled
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN 2>/dev/null || true
cleanup() { rm -rf "$STATE_DIR" "$PROJ"; }
trap cleanup EXIT
# shellcheck disable=SC1090
source "$TDD_LIB"

decision() { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}try{console.log(JSON.parse(s).decision==="block"?"block":"allow")}catch(_){console.log("allow")}});'; }

# Arm a session so the enforcer WOULD block: active + implComplete, chainDone=false.
arm() {
  local sid="$1"
  export ZENSU_TEST_PLUGIN_DATA="$STATE_DIR/plugin-data"
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$sid"
  bash "$LOG" --tdd-begin --session "$sid" >/dev/null 2>&1
  bash "$LOG" --tdd-complete --session "$sid" >/dev/null 2>&1
}

# --- T0 control: armed session blocks by default ---
SID0="esc-control"
arm "$SID0"
OUT0="$(printf '{"session_id":"%s"}' "$SID0" | bash "$STOP" 2>/dev/null)"
[ "$(printf '%s' "$OUT0" | decision)" = "block" ] \
  && check "T0 armed session blocks by default (control)" PASS \
  || check "T0 control block (out=$OUT0)" FAIL

# --- E1 ZENSU_CHAIN=off -> allow stop ---
SID1="esc-chain-off"
arm "$SID1"
OUT1="$(printf '{"session_id":"%s"}' "$SID1" | ZENSU_CHAIN=off bash "$STOP" 2>/dev/null)"
if [ -z "$OUT1" ] || [ "$(printf '%s' "$OUT1" | decision)" = "allow" ]; then
  check "E1 ZENSU_CHAIN=off -> allow stop (env escape)" PASS
else
  check "E1 ZENSU_CHAIN=off (out=$OUT1)" FAIL
fi

# --- E2 hooks.chainEnforcer=false -> allow stop ---
SID2="esc-cfg-off"
arm "$SID2"
CFG_OFF="$STATE_DIR/enforcer-off.json"
printf '{"hooks":{"chainEnforcer":false}}' > "$CFG_OFF"
OUT2="$(printf '{"session_id":"%s"}' "$SID2" | ZENSU_CONFIG="$CFG_OFF" bash "$STOP" 2>/dev/null)"
if [ -z "$OUT2" ] || [ "$(printf '%s' "$OUT2" | decision)" = "allow" ]; then
  check "E2 hooks.chainEnforcer=false -> allow stop (config escape)" PASS
else
  check "E2 chainEnforcer=false (out=$OUT2)" FAIL
fi

# --- E3 anti-deadlock: blocks > CAP -> allow + stderr warning ---
# Default autoFixMaxRounds=5 -> CAP=MAX_ROUNDS+3=8. Pre-seed CAP 'x's so THIS run
# (which appends one) crosses the cap (9 > 8) and releases.
SID3="esc-budget-exhausted"
arm "$SID3"
for _ in 1 2 3 4 5 6 7 8; do
  tdd_increment_counter "$SID3" stopBlockCount >/dev/null
done
ERR3="$STATE_DIR/e3.err"
OUT3="$(printf '{"session_id":"%s"}' "$SID3" | bash "$STOP" 2>"$ERR3")"
DEC3="$(printf '%s' "$OUT3" | decision)"
if [ "$DEC3" = "allow" ] && grep -qi "did not converge" "$ERR3"; then
  check "E3 blocks>CAP -> allow + stderr warning (anti-deadlock release)" PASS
else
  check "E3 budget cap (dec=$DEC3 err='$(cat "$ERR3" 2>/dev/null)')" FAIL
fi

# --- E4 control: blocks within budget still block ---
SID4="esc-budget-ok"
arm "$SID4"
for _ in 1 2; do
  tdd_increment_counter "$SID4" stopBlockCount >/dev/null
done
OUT4="$(printf '{"session_id":"%s"}' "$SID4" | bash "$STOP" 2>/dev/null)"
[ "$(printf '%s' "$OUT4" | decision)" = "block" ] \
  && check "E4 blocks<=CAP still block (budget not exhausted)" PASS \
  || check "E4 within-budget block (out=$OUT4)" FAIL

echo "----"
echo "test-stop-enforcer-escapes: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
