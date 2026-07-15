#!/bin/bash
# Pins the two new zensu-log.sh chain-terminus markers:
#   --code-review-done  -> sets codeReviewDone=true (intermediate; hands off to self-review)
#   --self-review-fixed -> sets selfReviewFixed=true (the one-fix-round latch)
# --code-review-done must NOT set chainDone: the final terminus stays self-review-owned.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
POST_REVIEW="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

TDD_STATE_DIR="$(mktemp -d)"; export TDD_STATE_DIR
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PROJECT_DIR="$TDD_STATE_DIR"
export CLAUDE_PLUGIN_DATA_OVERRIDE="$TDD_STATE_DIR"
cleanup() { rm -rf "$TDD_STATE_DIR"; }
trap cleanup EXIT

SID="markers-test"
SF="$TDD_STATE_DIR/tdd-phase-${SID}.json"
flag() { node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1]));console.log(j[process.argv[2]]===true?"true":"false")}catch(_){console.log("false")}' "$SF" "$1"; }

bash "$LOG" --tdd-begin --session "$SID" >/dev/null
bash "$LOG" --tdd-complete --session "$SID" >/dev/null
TICKET="$(bash "$LOG" --review-ticket --session "$SID")"
SID_VALUE="$SID" TICKET_VALUE="$TICKET" node -e '
  process.stdout.write(JSON.stringify({
    tool_name: "Agent",
    tool_input: {
      subagent_type: "zensu:code-reviewer",
      prompt: `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET_VALUE}\nfixture`
    },
    session_id: process.env.SID_VALUE
  }));
' | bash "$POST_REVIEW" >/dev/null 2>&1

bash "$LOG" --code-review-done --session "$SID" \
  --claimed-review-ticket "$TICKET" >/dev/null 2>&1
RC_CRD=$?
[ "$(flag codeReviewDone)" = "true" ] && check "M1 --code-review-done sets codeReviewDone=true" PASS || check "M1 --code-review-done sets codeReviewDone" FAIL
[ "$RC_CRD" = "0" ] && check "M2 --code-review-done exits 0" PASS || check "M2 --code-review-done exit 0 (got $RC_CRD)" FAIL
[ "$(flag chainDone)" = "false" ] && check "M3 --code-review-done leaves chainDone false (terminus is self-review)" PASS || check "M3 chainDone stays false" FAIL

bash "$LOG" --self-review-fixed --session "$SID" \
  --claimed-review-ticket "$TICKET" >/dev/null 2>&1
RC_SRF=$?
[ "$(flag selfReviewFixed)" = "true" ] && check "M4 --self-review-fixed sets selfReviewFixed=true" PASS || check "M4 --self-review-fixed sets selfReviewFixed" FAIL
[ "$RC_SRF" = "0" ] && check "M5 --self-review-fixed exits 0" PASS || check "M5 --self-review-fixed exit 0 (got $RC_SRF)" FAIL

echo "----"
echo "test-self-review-markers: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
