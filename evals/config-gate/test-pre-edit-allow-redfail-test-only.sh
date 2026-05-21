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

SID="s-redfail-1"
tdd_write_phase "$SID" "S1" "RED_FAIL" "assertion mismatch" >/dev/null

PAYLOAD_TEST='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.test.ts"},"session_id":"'$SID'"}'
OUT_TEST=$(echo "$PAYLOAD_TEST" | "$SCRIPT" 2>/dev/null)
if [ -z "$OUT_TEST" ]; then
  check "RED_FAIL + test file: allowed (empty stdout)" PASS
else
  check "RED_FAIL + test file: allowed (got: $OUT_TEST)" FAIL
fi

PAYLOAD_PROD='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"'$SID'"}'
OUT_PROD=$(echo "$PAYLOAD_PROD" | "$SCRIPT" 2>/dev/null)
DECISION=$(node -e '
  try { const j = JSON.parse(process.argv[1]); console.log(j.hookSpecificOutput?.permissionDecision || ""); }
  catch (_) { console.log(""); }
' "$OUT_PROD" 2>/dev/null)
if [ "$DECISION" = "deny" ]; then
  check "RED_FAIL + production file: denied" PASS
else
  check "RED_FAIL + production file: denied (got decision: '$DECISION')" FAIL
fi

REASON=$(node -e '
  try { const j = JSON.parse(process.argv[1]); console.log(j.hookSpecificOutput?.permissionDecisionReason || ""); }
  catch (_) { console.log(""); }
' "$OUT_PROD" 2>/dev/null)
case "$REASON" in
  *RED_FAIL*) check "deny reason mentions RED_FAIL phase" PASS ;;
  *)          check "deny reason mentions RED_FAIL phase (got: $REASON)" FAIL ;;
esac

PAYLOAD_TESTDIR='{"tool_name":"Edit","tool_input":{"file_path":"src/__tests__/Foo.tsx"},"session_id":"'$SID'"}'
OUT_TD=$(echo "$PAYLOAD_TESTDIR" | "$SCRIPT" 2>/dev/null)
if [ -z "$OUT_TD" ]; then
  check "RED_FAIL + __tests__ dir file: allowed" PASS
else
  check "RED_FAIL + __tests__ dir file: allowed (got: $OUT_TD)" FAIL
fi

echo "----"
echo "test-pre-edit-allow-redfail-test-only: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
