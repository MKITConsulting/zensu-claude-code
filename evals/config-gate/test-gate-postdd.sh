#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/post-tdd-review-delegate.sh"
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
  echo "test-gate-postdd: $PASS PASS / $FAIL FAIL"
  exit 1
fi

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"

TMP_CFG="/tmp/zensu-gate-postdd-disabled-$$.json"
cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoReview": false}}
EOF
export ZENSU_CONFIG="$TMP_CFG"

OUT_DISABLED="$("$SCRIPT" < "$EVAL_DIR/fixtures/stdin-tdd-manager.json" 2>/dev/null)"
EXIT_DISABLED=$?

if [ -z "$OUT_DISABLED" ]; then
  check "autoReview=false + tdd-manager subagent: empty stdout" PASS
else
  check "autoReview=false + tdd-manager subagent: empty stdout" FAIL
fi

if [ "$EXIT_DISABLED" = "0" ]; then
  check "autoReview=false: exit code 0" PASS
else
  check "autoReview=false: exit code 0" FAIL
fi

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoReview": true}}
EOF

OUT_ENABLED="$("$SCRIPT" < "$EVAL_DIR/fixtures/stdin-tdd-manager.json" 2>/dev/null)"

case "$OUT_ENABLED" in
  *"zensu:code-reviewer"*) check "autoReview=true + tdd-manager: stdout contains zensu:code-reviewer" PASS ;;
  *)                       check "autoReview=true + tdd-manager: stdout contains zensu:code-reviewer" FAIL ;;
esac

OUT_OTHER="$("$SCRIPT" < "$EVAL_DIR/fixtures/stdin-other-agent.json" 2>/dev/null)"
if [ -z "$OUT_OTHER" ]; then
  check "autoReview=true + non-tdd-manager subagent: empty stdout (isolation preserved)" PASS
else
  check "autoReview=true + non-tdd-manager subagent: empty stdout (isolation preserved)" FAIL
fi

unset ZENSU_CONFIG
NOTHING_CFG="/tmp/zensu-no-config-postdd-$$.json"
rm -f "$NOTHING_CFG"
export ZENSU_CONFIG="$NOTHING_CFG"
OUT_DEFAULT="$("$SCRIPT" < "$EVAL_DIR/fixtures/stdin-tdd-manager.json" 2>/dev/null)"
case "$OUT_DEFAULT" in
  *"zensu:code-reviewer"*) check "no config (default): stdout contains zensu:code-reviewer (enabled)" PASS ;;
  *)                       check "no config (default): stdout contains zensu:code-reviewer (enabled)" FAIL ;;
esac

rm -f "$TMP_CFG"

echo "----"
echo "test-gate-postdd: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
