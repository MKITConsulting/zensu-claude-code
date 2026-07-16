#!/bin/bash
# Pins the two new zensu-log.sh chain-terminus markers:
#   --code-review-done  -> sets codeReviewDone=true (intermediate; hands off to self-review)
#   --self-review-fixed -> sets selfReviewFixed=true (the one-fix-round latch)
# --code-review-done must NOT set chainDone: the final terminus stays self-review-owned.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
SESSION_CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

STATE_DIR="$(mktemp -d)"; export STATE_DIR
CLAUDE_PROJECT_DIR="$(mktemp -d)"; export CLAUDE_PROJECT_DIR
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export ZENSU_TEST_PLUGIN_DATA="$STATE_DIR/plugin-data"
cleanup() { rm -rf "$STATE_DIR" "$CLAUDE_PROJECT_DIR"; }
trap cleanup EXIT

SID="markers-test"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$SID"
SID_KEY="$(node "$SESSION_CORE" session-key "$SID")"
SF="$ZENSU_PROJECT_ROOT/.zensu/state/tdd-phase-${SID_KEY}.json"
flag() { node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1]));console.log(j[process.argv[2]]===true?"true":"false")}catch(_){console.log("false")}' "$SF" "$1"; }

bash "$LOG" --code-review-done --session "$SID" >/dev/null 2>&1
RC_CRD=$?
[ "$(flag codeReviewDone)" = "true" ] && check "M1 --code-review-done sets codeReviewDone=true" PASS || check "M1 --code-review-done sets codeReviewDone" FAIL
[ "$RC_CRD" = "0" ] && check "M2 --code-review-done exits 0" PASS || check "M2 --code-review-done exit 0 (got $RC_CRD)" FAIL
[ "$(flag chainDone)" = "false" ] && check "M3 --code-review-done leaves chainDone false (terminus is self-review)" PASS || check "M3 chainDone stays false" FAIL

bash "$LOG" --self-review-fixed --session "$SID" >/dev/null 2>&1
RC_SRF=$?
[ "$(flag selfReviewFixed)" = "true" ] && check "M4 --self-review-fixed sets selfReviewFixed=true" PASS || check "M4 --self-review-fixed sets selfReviewFixed" FAIL
[ "$RC_SRF" = "0" ] && check "M5 --self-review-fixed exits 0" PASS || check "M5 --self-review-fixed exit 0 (got $RC_SRF)" FAIL

echo "----"
echo "test-self-review-markers: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
