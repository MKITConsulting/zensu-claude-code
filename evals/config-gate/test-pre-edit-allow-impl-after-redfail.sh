#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/pre-edit-tdd-reminder.sh"
LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
TDD_STATE_DIR="$(mktemp -d)"
export TDD_STATE_DIR
export CLAUDE_AGENT_TYPE="zensu:tdd-manager"
unset ZENSU_TDD_GATE

cleanup() { rm -rf "$TDD_STATE_DIR"; }
trap cleanup EXIT

source "$LIB"

SID_A="s-impl-a"
tdd_write_phase "$SID_A" "S3" "RED_WRITE" ""                  >/dev/null
tdd_write_phase "$SID_A" "S3" "RED_FAIL"  "assertion mismatch" >/dev/null
tdd_write_phase "$SID_A" "S3" "IMPL"      ""                  >/dev/null

PAYLOAD_A='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"'$SID_A'"}'
OUT_A=$(echo "$PAYLOAD_A" | "$SCRIPT" 2>/dev/null)
if [ -z "$OUT_A" ]; then
  check "IMPL after RED_FAIL for current step: allowed on production file" PASS
else
  check "IMPL after RED_FAIL for current step: allowed (got: $OUT_A)" FAIL
fi

SID_B="s-impl-b"
tdd_write_phase "$SID_B" "S3" "RED_WRITE" ""                  >/dev/null
tdd_write_phase "$SID_B" "S3" "RED_FAIL"  "..."                >/dev/null
tdd_write_phase "$SID_B" "S3" "IMPL"      ""                  >/dev/null
tdd_write_phase "$SID_B" "S3" "GREEN_PASS" ""                 >/dev/null
tdd_write_phase "$SID_B" "S4" "IMPL"      ""                  >/dev/null

PAYLOAD_B='{"tool_name":"Edit","tool_input":{"file_path":"src/bar.ts"},"session_id":"'$SID_B'"}'
OUT_B=$(echo "$PAYLOAD_B" | "$SCRIPT" 2>/dev/null)
DECISION_B=$(node -e '
  try { const j = JSON.parse(process.argv[1]); console.log(j.hookSpecificOutput?.permissionDecision || ""); }
  catch (_) { console.log(""); }
' "$OUT_B" 2>/dev/null)
if [ "$DECISION_B" = "deny" ]; then
  check "IMPL phase but RED_FAIL belongs to OTHER step: denied" PASS
else
  check "IMPL phase but RED_FAIL belongs to OTHER step: denied (got decision: '$DECISION_B', out: $OUT_B)" FAIL
fi

SID_C="s-impl-c"
tdd_write_phase "$SID_C" "S3" "RED_WRITE" "" >/dev/null
tdd_write_phase "$SID_C" "S3" "IMPL"      "" >/dev/null

PAYLOAD_C='{"tool_name":"Edit","tool_input":{"file_path":"src/baz.ts"},"session_id":"'$SID_C'"}'
OUT_C=$(echo "$PAYLOAD_C" | "$SCRIPT" 2>/dev/null)
DECISION_C=$(node -e '
  try { const j = JSON.parse(process.argv[1]); console.log(j.hookSpecificOutput?.permissionDecision || ""); }
  catch (_) { console.log(""); }
' "$OUT_C" 2>/dev/null)
if [ "$DECISION_C" = "deny" ]; then
  check "IMPL phase but never went through RED_FAIL for current step: denied" PASS
else
  check "IMPL phase but never RED_FAIL for current step: denied (got decision: '$DECISION_C', out: $OUT_C)" FAIL
fi

REASON_C=$(node -e '
  try { const j = JSON.parse(process.argv[1]); console.log(j.hookSpecificOutput?.permissionDecisionReason || ""); }
  catch (_) { console.log(""); }
' "$OUT_C" 2>/dev/null)
case "$REASON_C" in
  *RED_FAIL*) check "IMPL-without-RED_FAIL deny reason mentions RED_FAIL prerequisite" PASS ;;
  *)          check "IMPL-without-RED_FAIL deny reason mentions RED_FAIL prerequisite (got: $REASON_C)" FAIL ;;
esac

echo "----"
echo "test-pre-edit-allow-impl-after-redfail: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
