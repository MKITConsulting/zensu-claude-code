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

export CLAUDE_PLUGIN_DATA_OVERRIDE="$(mktemp -d)"
export TDD_STATE_DIR="$CLAUDE_PLUGIN_DATA_OVERRIDE"
export CLAUDE_PROJECT_DIR="$CLAUDE_PLUGIN_DATA_OVERRIDE"
cleanup() { rm -rf "$CLAUDE_PLUGIN_DATA_OVERRIDE"; }
trap cleanup EXIT

bash "$PLUGIN_DIR/hooks/lib/zensu-log.sh" --tdd-begin --session no-root-review >/dev/null
bash "$PLUGIN_DIR/hooks/lib/zensu-log.sh" --tdd-complete --session no-root-review >/dev/null
TICKET="$(bash "$PLUGIN_DIR/hooks/lib/zensu-log.sh" --review-ticket --session no-root-review)"

# (post-tdd-review-delegate.sh was removed in the 0.4.0 main-thread migration;
#  only post-review-tdd-delegate.sh remains.)
STDIN_POSTREVIEW="{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"PRE-MERGED FINDINGS (fan-out)\\nREVIEW-TICKET: ${TICKET}\\nfixture\"},\"session_id\":\"no-root-review\"}"
OUT_POSTREVIEW="$(printf '%s' "$STDIN_POSTREVIEW" | "$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh" 2>/dev/null)"
case "$OUT_POSTREVIEW" in
  *"zensu:code-reviewer"*) check "post-review-tdd-delegate.sh works WITHOUT CLAUDE_PLUGIN_ROOT" PASS ;;
  *)                       check "post-review-tdd-delegate.sh works WITHOUT CLAUDE_PLUGIN_ROOT" FAIL ;;
esac

OUT_PLAN="$(echo '{"tool_name":"ExitPlanMode","tool_input":{"plan":"x"}}' | "$PLUGIN_DIR/hooks/plan-approved-delegate.sh" 2>/dev/null)"
case "$OUT_PLAN" in
  *"skill='zensu:tdd'"*) check "plan-approved-delegate.sh works WITHOUT CLAUDE_PLUGIN_ROOT" PASS ;;
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
