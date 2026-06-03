#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/pre-edit-tdd-reminder.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -x "$SCRIPT" ]; then
  check "hook script exists and is executable" FAIL
  echo "----"; echo "test-pre-edit-deny-uninitialized: $PASS PASS / $FAIL FAIL"
  exit 1
fi

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
TDD_STATE_DIR="$(mktemp -d)"
export TDD_STATE_DIR
unset ZENSU_TDD_GATE

cleanup() { rm -rf "$TDD_STATE_DIR"; }
trap cleanup EXIT

# 0.4.0+: the gate activates on chain-state (active=true), not CLAUDE_AGENT_TYPE.
# Mark the session active with no phase written (UNINITIALIZED), as /zensu:tdd
# --tdd-begin would before any RED test exists.
source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
tdd_set_flag "s-uninit-1" active true >/dev/null 2>&1

PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"s-uninit-1"}'
OUT=$(echo "$PAYLOAD" | "$SCRIPT" 2>/dev/null)
EXIT=$?

if [ "$EXIT" = "0" ]; then
  check "hook exits 0 even when emitting deny" PASS
else
  check "hook exits 0 even when emitting deny (got exit=$EXIT)" FAIL
fi

if [ -z "$OUT" ]; then
  check "hook produces output for UNINITIALIZED + production file" FAIL
else
  check "hook produces output for UNINITIALIZED + production file" PASS
fi

if node -e 'JSON.parse(process.argv[1])' "$OUT" 2>/dev/null; then
  check "output is valid JSON" PASS
else
  check "output is valid JSON" FAIL
fi

DECISION=$(node -e '
  try {
    const j = JSON.parse(process.argv[1]);
    console.log(j.hookSpecificOutput && j.hookSpecificOutput.permissionDecision || "");
  } catch (_) { console.log(""); }
' "$OUT" 2>/dev/null)
if [ "$DECISION" = "deny" ]; then
  check "permissionDecision = deny" PASS
else
  check "permissionDecision = deny (got: $DECISION)" FAIL
fi

REASON=$(node -e '
  try {
    const j = JSON.parse(process.argv[1]);
    console.log(j.hookSpecificOutput && j.hookSpecificOutput.permissionDecisionReason || "");
  } catch (_) { console.log(""); }
' "$OUT" 2>/dev/null)
case "$REASON" in
  *UNINITIALIZED*) check "reason mentions UNINITIALIZED" PASS ;;
  *)               check "reason mentions UNINITIALIZED (got: $REASON)" FAIL ;;
esac
case "$REASON" in
  *RED_WRITE*) check "reason mentions RED_WRITE remediation" PASS ;;
  *)           check "reason mentions RED_WRITE remediation (got: $REASON)" FAIL ;;
esac
case "$REASON" in
  *src/foo.ts*) check "reason includes the offending file path" PASS ;;
  *)            check "reason includes the offending file path (got: $REASON)" FAIL ;;
esac

EVENT_NAME=$(node -e '
  try {
    const j = JSON.parse(process.argv[1]);
    console.log(j.hookSpecificOutput && j.hookSpecificOutput.hookEventName || "");
  } catch (_) { console.log(""); }
' "$OUT" 2>/dev/null)
if [ "$EVENT_NAME" = "PreToolUse" ]; then
  check "hookEventName = PreToolUse" PASS
else
  check "hookEventName = PreToolUse (got: $EVENT_NAME)" FAIL
fi

echo "----"
echo "test-pre-edit-deny-uninitialized: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
