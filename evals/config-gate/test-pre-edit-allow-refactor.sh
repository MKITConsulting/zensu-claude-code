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

SID_RF="s-refactor-1"
tdd_write_phase "$SID_RF" "S1" "REFACTOR" "" >/dev/null

for fp in "src/strings.ts" "src/strings.test.ts" "backend/handlers.go"; do
  PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"'"$fp"'"},"session_id":"'$SID_RF'"}'
  OUT=$(echo "$PAYLOAD" | "$SCRIPT" 2>/dev/null)
  if [ -z "$OUT" ]; then
    check "REFACTOR + $fp: allowed" PASS
  else
    check "REFACTOR + $fp: allowed (got: $OUT)" FAIL
  fi
done

echo "----"
echo "test-pre-edit-allow-refactor: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
