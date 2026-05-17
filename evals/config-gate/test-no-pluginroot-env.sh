#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

unset CLAUDE_PLUGIN_ROOT
unset ZENSU_CONFIG

OUT_POSTDD="$(echo '{"tool_name":"Task","tool_input":{"subagent_type":"zensu:tdd-manager","prompt":"x"}}' | "$PLUGIN_DIR/hooks/post-tdd-review-delegate.sh" 2>/dev/null)"
case "$OUT_POSTDD" in
  *"zensu:code-reviewer"*) check "post-tdd-review-delegate.sh works WITHOUT CLAUDE_PLUGIN_ROOT" PASS ;;
  *)                       check "post-tdd-review-delegate.sh works WITHOUT CLAUDE_PLUGIN_ROOT" FAIL ;;
esac

OUT_POSTREVIEW="$(echo '{"tool_name":"Task","tool_input":{"subagent_type":"zensu:code-reviewer","prompt":"x"}}' | "$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh" 2>/dev/null)"
case "$OUT_POSTREVIEW" in
  *"zensu:tdd-manager"*) check "post-review-tdd-delegate.sh works WITHOUT CLAUDE_PLUGIN_ROOT" PASS ;;
  *)                     check "post-review-tdd-delegate.sh works WITHOUT CLAUDE_PLUGIN_ROOT" FAIL ;;
esac

OUT_PLAN="$(echo '{"tool_name":"ExitPlanMode","tool_input":{"plan":"x"}}' | "$PLUGIN_DIR/hooks/plan-approved-delegate.sh" 2>/dev/null)"
case "$OUT_PLAN" in
  *"zensu:tdd-manager"*) check "plan-approved-delegate.sh works WITHOUT CLAUDE_PLUGIN_ROOT" PASS ;;
  *)                     check "plan-approved-delegate.sh works WITHOUT CLAUDE_PLUGIN_ROOT" FAIL ;;
esac

OUT_SESSION="$("$PLUGIN_DIR/hooks/session-start-pulse.sh" 2>/dev/null)"
case "$OUT_SESSION" in
  *"pulse session ready"*|*"not a git repository"*) check "session-start-pulse.sh works WITHOUT CLAUDE_PLUGIN_ROOT" PASS ;;
  *)                                                  check "session-start-pulse.sh works WITHOUT CLAUDE_PLUGIN_ROOT" FAIL ;;
esac

echo "----"
echo "test-no-pluginroot-env: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
