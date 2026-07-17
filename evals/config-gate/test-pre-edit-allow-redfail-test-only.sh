#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/pre-edit-tdd-reminder.sh"
LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
WORK_DIR="$(mktemp -d)"
export CLAUDE_PROJECT_DIR="$WORK_DIR/project"
mkdir -p "$CLAUDE_PROJECT_DIR"
unset ZENSU_TDD_GATE

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

source "$LIB"

# 0.4.0+: the gate activates on chain-state (active=true), set by /zensu:tdd
# --tdd-begin. Shim phase setup to also mark each session active (the legacy
# CLAUDE_AGENT_TYPE=zensu:tdd-manager activation was removed).
eval "$(declare -f tdd_write_phase | sed '1s/^tdd_write_phase/_zensu_orig_write_phase/')"
tdd_write_phase() { tdd_set_flag "$1" active true >/dev/null 2>&1; _zensu_orig_write_phase "$@"; }

SID="s-redfail-1"
# shellcheck disable=SC1090
source "$BASELINE" "$SID"
tdd_write_phase "$SID" "S1" "RED_FAIL" "assertion mismatch" >/dev/null

PAYLOAD_TEST='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/foo.test.ts"},"session_id":"'$SID'"}'
OUT_TEST=$(echo "$PAYLOAD_TEST" | "$SCRIPT" 2>/dev/null)
if [ -z "$OUT_TEST" ]; then
  check "RED_FAIL + test file: allowed (empty stdout)" PASS
else
  check "RED_FAIL + test file: allowed (got: $OUT_TEST)" FAIL
fi

PAYLOAD_PROD='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"'$SID'"}'
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

PAYLOAD_TESTDIR='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/__tests__/Foo.tsx"},"session_id":"'$SID'"}'
OUT_TD=$(echo "$PAYLOAD_TESTDIR" | "$SCRIPT" 2>/dev/null)
if [ -z "$OUT_TD" ]; then
  check "RED_FAIL + __tests__ dir file: allowed" PASS
else
  check "RED_FAIL + __tests__ dir file: allowed (got: $OUT_TD)" FAIL
fi

echo "----"
echo "test-pre-edit-allow-redfail-test-only: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
