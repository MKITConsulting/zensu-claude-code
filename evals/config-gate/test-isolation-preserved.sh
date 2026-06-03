#!/bin/bash
set -u

# post-review-tdd-delegate.sh subagent isolation: it acts ONLY when a completed
# zensu:code-reviewer Agent fires; every other subagent_type is a silent
# pass-through. (The pre-0.4.0 sibling post-tdd-review-delegate.sh was removed in
# the main-thread TDD migration, so there is no longer a second hook to isolate.)

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_POSTREVIEW="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -x "$SCRIPT_POSTREVIEW" ]; then
  check "post-review-tdd-delegate.sh exists and is executable" FAIL
  echo "----"
  echo "test-isolation-preserved: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "post-review-tdd-delegate.sh exists and is executable" PASS

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PLUGIN_DATA_OVERRIDE="$(mktemp -d)"
cleanup() { rm -rf "$CLAUDE_PLUGIN_DATA_OVERRIDE"; }
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

OUT_OTHER="$("$SCRIPT_POSTREVIEW" < "$EVAL_DIR/fixtures/stdin-other-agent.json" 2>/dev/null)"
if [ -z "$OUT_OTHER" ]; then
  check "post-review + general-purpose subagent: empty stdout (filtered)" PASS
else
  check "post-review + general-purpose subagent: empty stdout (got: $OUT_OTHER)" FAIL
fi

OUT_TDDM="$("$SCRIPT_POSTREVIEW" < "$EVAL_DIR/fixtures/stdin-tdd-manager.json" 2>/dev/null)"
if [ -z "$OUT_TDDM" ]; then
  check "post-review + (legacy) tdd-manager subagent: empty stdout (only code-reviewer acts)" PASS
else
  check "post-review + tdd-manager subagent: empty stdout (got: $OUT_TDDM)" FAIL
fi

OUT_OK="$("$SCRIPT_POSTREVIEW" < "$EVAL_DIR/fixtures/stdin-code-reviewer.json" 2>/dev/null)"
case "$OUT_OK" in
  *"zensu:code-reviewer"*) check "post-review + code-reviewer subagent: routing directive present (re-verify via zensu:code-reviewer)" PASS ;;
  *)                       check "post-review + code-reviewer subagent: routing directive present (got: $OUT_OK)" FAIL ;;
esac

rm -f "$TMP_CFG"

echo "----"
echo "test-isolation-preserved: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
