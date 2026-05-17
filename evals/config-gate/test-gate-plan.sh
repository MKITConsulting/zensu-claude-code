#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/plan-approved-delegate.sh"
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
  echo "test-gate-plan: $PASS PASS / $FAIL FAIL"
  exit 1
fi

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"

export ZENSU_CONFIG="$EVAL_DIR/fixtures/config-only-tdd.json"
OUT_DISABLED="$("$SCRIPT" < "$EVAL_DIR/fixtures/stdin-exitplanmode.json" 2>/dev/null)"
EXIT_DISABLED=$?

if [ -z "$OUT_DISABLED" ]; then
  check "autoTdd=false: empty stdout" PASS
else
  check "autoTdd=false: empty stdout" FAIL
fi

if [ "$EXIT_DISABLED" = "0" ]; then
  check "autoTdd=false: exit code 0" PASS
else
  check "autoTdd=false: exit code 0" FAIL
fi

TMP_CFG="/tmp/zensu-gate-plan-enabled-$$.json"
cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoTdd": true}}
EOF
export ZENSU_CONFIG="$TMP_CFG"

OUT_ENABLED="$("$SCRIPT" < "$EVAL_DIR/fixtures/stdin-exitplanmode.json" 2>/dev/null)"

case "$OUT_ENABLED" in
  *"zensu:tdd-manager"*) check "autoTdd=true: stdout contains zensu:tdd-manager" PASS ;;
  *)                     check "autoTdd=true: stdout contains zensu:tdd-manager" FAIL ;;
esac

case "$OUT_ENABLED" in
  *"additionalContext"*) check "autoTdd=true: stdout contains additionalContext" PASS ;;
  *)                     check "autoTdd=true: stdout contains additionalContext" FAIL ;;
esac

unset ZENSU_CONFIG
NOTHING_CFG="/tmp/zensu-no-config-$$.json"
rm -f "$NOTHING_CFG"
export ZENSU_CONFIG="$NOTHING_CFG"
OUT_DEFAULT="$("$SCRIPT" < "$EVAL_DIR/fixtures/stdin-exitplanmode.json" 2>/dev/null)"

case "$OUT_DEFAULT" in
  *"zensu:tdd-manager"*) check "no config (default): stdout contains zensu:tdd-manager (enabled)" PASS ;;
  *)                     check "no config (default): stdout contains zensu:tdd-manager (enabled)" FAIL ;;
esac

rm -f "$TMP_CFG"

echo "----"
echo "test-gate-plan: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
