#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -x "$SCRIPT" ]; then
  check "hook script exists and is executable" FAIL
  echo "----"
  echo "test-autofix-suggestions-on: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PROJECT_DIR="$TMP_DIR/project"
export STATE_DIR="$TMP_DIR/state"
export ZENSU_CONFIG="$EVAL_DIR/fixtures/config-with-suggestions.json"
mkdir -p "$CLAUDE_PROJECT_DIR" "$STATE_DIR"
# shellcheck disable=SC1090
source "$BASELINE" sess-on-001
bash "$LOG" --tdd-begin --session "sess-on-001" >/dev/null 2>&1

STDIN='{"tool_name":"Task","tool_input":{"subagent_type":"zensu:code-reviewer","prompt":"x"},"session_id":"sess-on-001"}'
OUT="$(printf '%s' "$STDIN" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"Include EVERY finding the reviewer raised"*)
    check "stdout contains 'Include EVERY finding the reviewer raised' (all severities)" PASS ;;
  *)
    check "stdout contains 'Include EVERY finding the reviewer raised' (all severities)" FAIL ;;
esac

case "$OUT" in
  *"Critical, Important, Suggestion, Minor, Nit"*)
    check "stdout enumerates Critical, Important, Suggestion, Minor, Nit explicitly" PASS ;;
  *)
    check "stdout enumerates Critical, Important, Suggestion, Minor, Nit explicitly" FAIL ;;
esac

case "$OUT" in
  *"IN THIS MAIN THREAD"*)
    check "stdout routes the fixes to the MAIN THREAD (not a tdd-manager subagent)" PASS ;;
  *)
    check "stdout routes the fixes to the MAIN THREAD (not a tdd-manager subagent)" FAIL ;;
esac

case "$OUT" in
  *"Fixing all findings in-thread, then re-reviewing"*)
    check "stdout contains 'Fixing all findings in-thread, then re-reviewing' status line" PASS ;;
  *)
    check "stdout contains 'Fixing all findings in-thread, then re-reviewing' status line" FAIL ;;
esac

case "$OUT" in
  *"round 1/2"*)
    check "stdout contains 'round 1/2' indicator (first invocation)" PASS ;;
  *)
    check "stdout contains 'round 1/2' indicator (first invocation)" FAIL ;;
esac

echo "----"
echo "test-autofix-suggestions-on: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
