#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"

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
export CLAUDE_PLUGIN_DATA_OVERRIDE="$TMP_DIR/state"
export ZENSU_CONFIG="$EVAL_DIR/fixtures/config-with-suggestions.json"

STDIN='{"tool_name":"Task","tool_input":{"subagent_type":"zensu:code-reviewer","prompt":"x"},"session_id":"sess-on-001"}'
OUT="$(printf '%s' "$STDIN" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"ALL findings regardless of severity"*)
    check "stdout contains 'ALL findings regardless of severity'" PASS ;;
  *)
    check "stdout contains 'ALL findings regardless of severity'" FAIL ;;
esac

case "$OUT" in
  *"Critical, Important, Suggestion, Minor, Nit"*)
    check "stdout enumerates Critical, Important, Suggestion, Minor, Nit explicitly" PASS ;;
  *)
    check "stdout enumerates Critical, Important, Suggestion, Minor, Nit explicitly" FAIL ;;
esac

case "$OUT" in
  *"zensu:tdd-manager"*)
    check "stdout still references zensu:tdd-manager target subagent" PASS ;;
  *)
    check "stdout still references zensu:tdd-manager target subagent" FAIL ;;
esac

case "$OUT" in
  *"Delegating all findings to zensu:tdd-manager"*)
    check "stdout contains 'Delegating all findings to zensu:tdd-manager' status line" PASS ;;
  *)
    check "stdout contains 'Delegating all findings to zensu:tdd-manager' status line" FAIL ;;
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
