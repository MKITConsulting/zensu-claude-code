#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -x "$SCRIPT" ]; then
  check "hook script exists and is executable" FAIL
  echo "----"
  echo "test-post-review-combined-summary: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
TMP_CFG="$TMP_DIR/config.json"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PLUGIN_DATA_OVERRIDE="$TMP_DIR/state"
mkdir -p "$CLAUDE_PLUGIN_DATA_OVERRIDE"
export ZENSU_CONFIG="$TMP_CFG"

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true}}
EOF

STDIN_A='{"tool_name":"Task","tool_input":{"subagent_type":"zensu:code-reviewer","prompt":"x"},"session_id":"sess-summary-a-001"}'
OUT="$(printf '%s' "$STDIN_A" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"CHAIN-END SUMMARY"*)
    check "case A/B legacy + flag on (default): output contains 'CHAIN-END SUMMARY'" PASS ;;
  *)
    check "case A/B legacy + flag on (default): output contains 'CHAIN-END SUMMARY'" FAIL ;;
esac

case "$OUT" in
  *"## Implementation Summary"*)
    check "case A/B legacy + flag on: output contains '## Implementation Summary' heading" PASS ;;
  *)
    check "case A/B legacy + flag on: output contains '## Implementation Summary' heading" FAIL ;;
esac

case "$OUT" in
  *"## Review Summary"*)
    check "case A/B legacy + flag on: output contains '## Review Summary' heading" PASS ;;
  *)
    check "case A/B legacy + flag on: output contains '## Review Summary' heading" FAIL ;;
esac

case "$OUT" in
  *"## Auto-fix History"*)
    check "case A/B legacy + flag on: output contains '## Auto-fix History' heading" PASS ;;
  *)
    check "case A/B legacy + flag on: output contains '## Auto-fix History' heading" FAIL ;;
esac

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "combinedSummary": false}}
EOF

STDIN_OFF='{"tool_name":"Task","tool_input":{"subagent_type":"zensu:code-reviewer","prompt":"x"},"session_id":"sess-summary-off-001"}'
OUT="$(printf '%s' "$STDIN_OFF" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"CHAIN-END SUMMARY"*)
    check "case A/B legacy + flag off: output must NOT contain 'CHAIN-END SUMMARY'" FAIL ;;
  *)
    check "case A/B legacy + flag off: output must NOT contain 'CHAIN-END SUMMARY'" PASS ;;
esac

case "$OUT" in
  *"EXCLUDE all Suggestions"*)
    check "case A/B legacy + flag off: existing 'EXCLUDE all Suggestions' directive preserved" PASS ;;
  *)
    check "case A/B legacy + flag off: existing 'EXCLUDE all Suggestions' directive preserved" FAIL ;;
esac

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "autoFixIncludeSuggestions": true}}
EOF

STDIN_SUGG_ON='{"tool_name":"Task","tool_input":{"subagent_type":"zensu:code-reviewer","prompt":"x"},"session_id":"sess-summary-sugg-001"}'
OUT="$(printf '%s' "$STDIN_SUGG_ON" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"ALL findings regardless of severity"*)
    check "case B suggestions-on + flag on: existing 'ALL findings' directive preserved" PASS ;;
  *)
    check "case B suggestions-on + flag on: existing 'ALL findings' directive preserved" FAIL ;;
esac

case "$OUT" in
  *"CHAIN-END SUMMARY"*)
    check "case B suggestions-on + flag on: output contains 'CHAIN-END SUMMARY'" PASS ;;
  *)
    check "case B suggestions-on + flag on: output contains 'CHAIN-END SUMMARY'" FAIL ;;
esac

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "autoFixIncludeSuggestions": true, "combinedSummary": false}}
EOF

STDIN_SUGG_OFF='{"tool_name":"Task","tool_input":{"subagent_type":"zensu:code-reviewer","prompt":"x"},"session_id":"sess-summary-sugg-off-001"}'
OUT="$(printf '%s' "$STDIN_SUGG_OFF" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"CHAIN-END SUMMARY"*)
    check "case B suggestions-on + flag off: output must NOT contain 'CHAIN-END SUMMARY'" FAIL ;;
  *)
    check "case B suggestions-on + flag off: output must NOT contain 'CHAIN-END SUMMARY'" PASS ;;
esac

case "$OUT" in
  *"ALL findings regardless of severity"*)
    check "case B suggestions-on + flag off: 'ALL findings' directive preserved" PASS ;;
  *)
    check "case B suggestions-on + flag off: 'ALL findings' directive preserved" FAIL ;;
esac

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "autoFixMaxRounds": 5}}
EOF
SID_MR_ON="sess-summary-mr-on-001"
printf '{"count":5,"ts":"2026-01-01T00:00:00Z"}\n' > "$CLAUDE_PLUGIN_DATA_OVERRIDE/rounds-${SID_MR_ON}.json"
STDIN_MR_ON="{\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"x\"},\"session_id\":\"${SID_MR_ON}\"}"
OUT="$(printf '%s' "$STDIN_MR_ON" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"Auto-fix convergence: max 5 rounds reached"*)
    check "max-rounds + flag on: existing convergence message preserved" PASS ;;
  *)
    check "max-rounds + flag on: existing convergence message preserved" FAIL ;;
esac

case "$OUT" in
  *"CHAIN-END SUMMARY"*)
    check "max-rounds + flag on: output contains 'CHAIN-END SUMMARY'" PASS ;;
  *)
    check "max-rounds + flag on: output contains 'CHAIN-END SUMMARY'" FAIL ;;
esac

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "autoFixMaxRounds": 5, "combinedSummary": false}}
EOF
SID_MR_OFF="sess-summary-mr-off-001"
printf '{"count":5,"ts":"2026-01-01T00:00:00Z"}\n' > "$CLAUDE_PLUGIN_DATA_OVERRIDE/rounds-${SID_MR_OFF}.json"
STDIN_MR_OFF="{\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"x\"},\"session_id\":\"${SID_MR_OFF}\"}"
OUT="$(printf '%s' "$STDIN_MR_OFF" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"Auto-fix convergence: max 5 rounds reached"*)
    check "max-rounds + flag off: existing convergence message preserved" PASS ;;
  *)
    check "max-rounds + flag off: existing convergence message preserved" FAIL ;;
esac

case "$OUT" in
  *"CHAIN-END SUMMARY"*)
    check "max-rounds + flag off: output must NOT contain 'CHAIN-END SUMMARY'" FAIL ;;
  *)
    check "max-rounds + flag off: output must NOT contain 'CHAIN-END SUMMARY'" PASS ;;
esac

echo "----"
echo "test-post-review-combined-summary: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
