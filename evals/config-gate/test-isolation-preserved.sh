#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_POSTDD="$PLUGIN_DIR/hooks/post-tdd-review-delegate.sh"
SCRIPT_POSTREVIEW="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -x "$SCRIPT_POSTDD" ] || [ ! -x "$SCRIPT_POSTREVIEW" ]; then
  check "both hook scripts exist and are executable" FAIL
  echo "----"
  echo "test-isolation-preserved: $PASS PASS / $FAIL FAIL"
  exit 1
fi

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PLUGIN_DATA="$(mktemp -d)"
cleanup() { rm -rf "$CLAUDE_PLUGIN_DATA"; }
trap cleanup EXIT

TMP_CFG="/tmp/zensu-isolation-allenabled-$$.json"
cat > "$TMP_CFG" <<'EOF'
{
  "hooks": {
    "autoTdd": true,
    "autoReview": true,
    "autoFix": true,
    "pulseSession": true
  }
}
EOF
export ZENSU_CONFIG="$TMP_CFG"

OUT_POSTDD_OTHER="$("$SCRIPT_POSTDD" < "$EVAL_DIR/fixtures/stdin-other-agent.json" 2>/dev/null)"
if [ -z "$OUT_POSTDD_OTHER" ]; then
  check "post-tdd-review with all-enabled + general-purpose subagent: empty stdout" PASS
else
  check "post-tdd-review with all-enabled + general-purpose subagent: empty stdout" FAIL
fi

OUT_POSTDD_REVIEWER="$("$SCRIPT_POSTDD" < "$EVAL_DIR/fixtures/stdin-code-reviewer.json" 2>/dev/null)"
if [ -z "$OUT_POSTDD_REVIEWER" ]; then
  check "post-tdd-review with all-enabled + code-reviewer subagent: empty stdout (subagent filter)" PASS
else
  check "post-tdd-review with all-enabled + code-reviewer subagent: empty stdout (subagent filter)" FAIL
fi

OUT_POSTREVIEW_OTHER="$("$SCRIPT_POSTREVIEW" < "$EVAL_DIR/fixtures/stdin-other-agent.json" 2>/dev/null)"
if [ -z "$OUT_POSTREVIEW_OTHER" ]; then
  check "post-review-tdd with all-enabled + general-purpose subagent: empty stdout" PASS
else
  check "post-review-tdd with all-enabled + general-purpose subagent: empty stdout" FAIL
fi

OUT_POSTREVIEW_TDDM="$("$SCRIPT_POSTREVIEW" < "$EVAL_DIR/fixtures/stdin-tdd-manager.json" 2>/dev/null)"
if [ -z "$OUT_POSTREVIEW_TDDM" ]; then
  check "post-review-tdd with all-enabled + tdd-manager subagent: empty stdout (subagent filter)" PASS
else
  check "post-review-tdd with all-enabled + tdd-manager subagent: empty stdout (subagent filter)" FAIL
fi

OUT_POSTDD_OK="$("$SCRIPT_POSTDD" < "$EVAL_DIR/fixtures/stdin-tdd-manager.json" 2>/dev/null)"
case "$OUT_POSTDD_OK" in
  *"zensu:code-reviewer"*) check "post-tdd-review with all-enabled + tdd-manager subagent: directive present" PASS ;;
  *)                       check "post-tdd-review with all-enabled + tdd-manager subagent: directive present" FAIL ;;
esac

OUT_POSTREVIEW_OK="$("$SCRIPT_POSTREVIEW" < "$EVAL_DIR/fixtures/stdin-code-reviewer.json" 2>/dev/null)"
case "$OUT_POSTREVIEW_OK" in
  *"zensu:tdd-manager"*) check "post-review-tdd with all-enabled + code-reviewer subagent: directive present" PASS ;;
  *)                     check "post-review-tdd with all-enabled + code-reviewer subagent: directive present" FAIL ;;
esac

rm -f "$TMP_CFG"

echo "----"
echo "test-isolation-preserved: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
