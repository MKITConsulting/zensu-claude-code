#!/bin/bash
# Pins the stop-chain-enforcer.sh two-stage routing:
#   implComplete && !codeReviewDone           -> block, force Agent zensu:code-reviewer (unchanged)
#   implComplete && codeReviewDone && !chainDone -> block, force Skill zensu:self-review (NEW)
#   chainDone                                 -> allow (self-review owns the terminus)
#   selfReview disabled + codeReviewDone      -> block, legacy force code-reviewer
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
STATE_DIR="$(mktemp -d)"; export STATE_DIR
PROJ="$(mktemp -d)"; export CLAUDE_PROJECT_DIR="$PROJ"
export ZENSU_CONFIG="$STATE_DIR/no-such-config.json"   # force defaults -> selfReview enabled
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN 2>/dev/null || true
cleanup() { rm -rf "$STATE_DIR" "$PROJ"; }
trap cleanup EXIT

stop_run() {
  local payload="$1" cfg="${2:-}"
  if [ -n "$cfg" ]; then
    printf '%s' "$payload" | ZENSU_CONFIG="$cfg" bash "$STOP" 2>/dev/null
  else
    printf '%s' "$payload" | bash "$STOP" 2>/dev/null
  fi
}
decision() { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}try{console.log(JSON.parse(s).decision==="block"?"block":"allow")}catch(_){console.log("allow")}});'; }
reason()   { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{console.log(JSON.parse(s).reason||"")}catch(_){console.log("")}});'; }

start_session() {
  export ZENSU_TEST_PLUGIN_DATA="$STATE_DIR/plugin-data"
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$1"
}

# --- Scenario 1: codeReviewDone=false -> force code-reviewer (unchanged) ---
SID1="stop-cr-pending"
start_session "$SID1"
bash "$LOG" --tdd-begin --session "$SID1" >/dev/null
bash "$LOG" --tdd-complete --session "$SID1" >/dev/null
OUT1="$(stop_run '{"session_id":"'"$SID1"'"}')"
[ "$(printf '%s' "$OUT1" | decision)" = "block" ] && check "T1 implComplete + !codeReviewDone -> block" PASS || check "T1 block" FAIL
printf '%s' "$OUT1" | reason | grep -q "zensu:code-reviewer" && check "T2 !codeReviewDone reason forces zensu:code-reviewer" PASS || check "T2 reason code-reviewer" FAIL

# --- Scenario 2: codeReviewDone=true -> force self-review (NEW) ---
SID2="stop-cr-done"
start_session "$SID2"
bash "$LOG" --tdd-begin --session "$SID2" >/dev/null
bash "$LOG" --tdd-complete --session "$SID2" >/dev/null
bash "$LOG" --code-review-done --session "$SID2" >/dev/null
OUT2="$(stop_run '{"session_id":"'"$SID2"'"}')"
[ "$(printf '%s' "$OUT2" | decision)" = "block" ] && check "T3 codeReviewDone + !chainDone -> block" PASS || check "T3 block" FAIL
printf '%s' "$OUT2" | reason | grep -q "skill='zensu:self-review'" && check "T4 codeReviewDone reason forces skill='zensu:self-review'" PASS || check "T4 reason self-review" FAIL
if printf '%s' "$OUT2" | reason | grep -q "zensu:code-reviewer"; then
  check "T5 self-review reason must NOT name zensu:code-reviewer" FAIL
else
  check "T5 self-review reason must NOT name zensu:code-reviewer" PASS
fi

# --- Scenario 3: chainDone -> allow (terminus) ---
SID3="stop-chain-done"
start_session "$SID3"
bash "$LOG" --tdd-begin --session "$SID3" >/dev/null
bash "$LOG" --tdd-complete --session "$SID3" >/dev/null
bash "$LOG" --code-review-done --session "$SID3" >/dev/null
bash "$LOG" --chain-done --session "$SID3" >/dev/null
OUT3="$(stop_run '{"session_id":"'"$SID3"'"}')"
[ "$(printf '%s' "$OUT3" | decision)" = "allow" ] && check "T6 chainDone -> allow stop (self-review owns terminus)" PASS || check "T6 allow" FAIL

# --- Scenario 4: selfReview disabled + codeReviewDone=true -> legacy code-reviewer ---
SID4="stop-selfreview-off"
start_session "$SID4"
OFFCFG="$STATE_DIR/selfreview-off.json"
printf '{"hooks":{"selfReview":false}}' > "$OFFCFG"
bash "$LOG" --tdd-begin --session "$SID4" >/dev/null
bash "$LOG" --tdd-complete --session "$SID4" >/dev/null
bash "$LOG" --code-review-done --session "$SID4" >/dev/null
OUT4="$(stop_run '{"session_id":"'"$SID4"'"}' "$OFFCFG")"
[ "$(printf '%s' "$OUT4" | decision)" = "block" ] && check "T7 selfReview off + codeReviewDone -> block" PASS || check "T7 block" FAIL
printf '%s' "$OUT4" | reason | grep -q "zensu:code-reviewer" && check "T8 selfReview off -> legacy force code-reviewer" PASS || check "T8 legacy code-reviewer" FAIL

echo "----"
echo "test-stop-enforcer-self-review-routing: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
