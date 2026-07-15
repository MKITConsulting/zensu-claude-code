#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
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
  echo "test-autofix-suggestions-off: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
TMP_CFG="$TMP_DIR/config.json"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true}}
EOF

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PLUGIN_DATA_OVERRIDE="$TMP_DIR/state"
export TDD_STATE_DIR="$CLAUDE_PLUGIN_DATA_OVERRIDE"
export CLAUDE_PROJECT_DIR="$TMP_DIR"
export ZENSU_CONFIG="$TMP_CFG"

bash "$LOG" --tdd-begin --session sess-off-001 >/dev/null
bash "$LOG" --tdd-complete --session sess-off-001 >/dev/null
TICKET_FLAG_ABSENT="$(bash "$LOG" --review-ticket --session sess-off-001)"
STDIN_FLAG_ABSENT="{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"PRE-MERGED FINDINGS (fan-out)\\nREVIEW-TICKET: ${TICKET_FLAG_ABSENT}\\nfixture\"},\"session_id\":\"sess-off-001\"}"
OUT="$(printf '%s' "$STDIN_FLAG_ABSENT" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"EXCLUDE all Suggestions"*)
    check "flag absent: legacy 'EXCLUDE all Suggestions' directive preserved" PASS ;;
  *)
    check "flag absent: legacy 'EXCLUDE all Suggestions' directive preserved" FAIL ;;
esac

case "$OUT" in
  *"Fixing critical+important findings in-thread, then re-reviewing"*)
    check "flag absent: 'Fixing critical+important findings in-thread' status line (main thread)" PASS ;;
  *)
    check "flag absent: 'Fixing critical+important findings in-thread' status line (main thread)" FAIL ;;
esac

case "$OUT" in
  *"ALL findings regardless of severity"*)
    check "flag absent: new 'ALL findings' directive must NOT appear" FAIL ;;
  *)
    check "flag absent: new 'ALL findings' directive must NOT appear" PASS ;;
esac

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "autoFixIncludeSuggestions": false}}
EOF
bash "$LOG" --tdd-begin --session sess-off-002 >/dev/null
bash "$LOG" --tdd-complete --session sess-off-002 >/dev/null
TICKET_FLAG_FALSE="$(bash "$LOG" --review-ticket --session sess-off-002)"
STDIN_FLAG_FALSE="{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"PRE-MERGED FINDINGS (fan-out)\\nREVIEW-TICKET: ${TICKET_FLAG_FALSE}\\nfixture\"},\"session_id\":\"sess-off-002\"}"
OUT="$(printf '%s' "$STDIN_FLAG_FALSE" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"EXCLUDE all Suggestions"*)
    check "flag=false: legacy directive preserved" PASS ;;
  *)
    check "flag=false: legacy directive preserved" FAIL ;;
esac

case "$OUT" in
  *"ALL findings regardless of severity"*)
    check "flag=false: new directive must NOT appear" FAIL ;;
  *)
    check "flag=false: new directive must NOT appear" PASS ;;
esac

echo "----"
echo "test-autofix-suggestions-off: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
