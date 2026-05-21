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

SID="s-red-write-1"
tdd_write_phase "$SID" "S1" "RED_WRITE" "" >/dev/null

PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"src/strings.test.ts"},"session_id":"'$SID'"}'
OUT=$(echo "$PAYLOAD" | "$SCRIPT" 2>/dev/null)
EXIT=$?

if [ -z "$OUT" ] && [ "$EXIT" = "0" ]; then
  check "RED_WRITE + test file: empty stdout + exit 0 (allowed)" PASS
else
  check "RED_WRITE + test file: empty stdout + exit 0 (got: '$OUT' exit=$EXIT)" FAIL
fi

PAYLOAD2='{"tool_name":"Edit","tool_input":{"file_path":"src/strings.ts"},"session_id":"'$SID'"}'
OUT2=$(echo "$PAYLOAD2" | "$SCRIPT" 2>/dev/null)
EXIT2=$?

if [ -z "$OUT2" ] && [ "$EXIT2" = "0" ]; then
  check "RED_WRITE + production file: empty stdout + exit 0 (also allowed in RED_WRITE)" PASS
else
  check "RED_WRITE + production file: empty stdout (got: '$OUT2' exit=$EXIT2)" FAIL
fi

PAYLOAD_WRITE='{"tool_name":"Write","tool_input":{"file_path":"src/foo.test.ts"},"session_id":"'$SID'"}'
OUT_W=$(echo "$PAYLOAD_WRITE" | "$SCRIPT" 2>/dev/null)
if [ -z "$OUT_W" ]; then
  check "RED_WRITE + Write tool on test file: allowed" PASS
else
  check "RED_WRITE + Write tool on test file: allowed (got: '$OUT_W')" FAIL
fi

PAYLOAD_MULTI='{"tool_name":"MultiEdit","tool_input":{"file_path":"src/bar.spec.ts"},"session_id":"'$SID'"}'
OUT_M=$(echo "$PAYLOAD_MULTI" | "$SCRIPT" 2>/dev/null)
if [ -z "$OUT_M" ]; then
  check "RED_WRITE + MultiEdit tool on test file: allowed" PASS
else
  check "RED_WRITE + MultiEdit tool on test file: allowed (got: '$OUT_M')" FAIL
fi

echo "----"
echo "test-pre-edit-allow-red-write: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
