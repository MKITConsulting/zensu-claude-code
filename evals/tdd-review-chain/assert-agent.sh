#!/bin/bash
# Asserts agents/tdd-manager.md Phase 6 step 7 no longer asks the user about
# code review and instead points to the SubagentStop hook.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT="$PLUGIN_DIR/agents/tdd-manager.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

# Step 7 line should NOT be the suggestive "ask user (in their language) if they want to run"
if grep -qE 'ask user .in their language. if they want to run.*zensu:code-reviewer' "$AGENT"; then
  check "step 7 no longer suggestively asks user" FAIL
else
  check "step 7 no longer suggestively asks user" PASS
fi

# Step 7 line MUST mention a hook auto-invoking the code reviewer.
# Hook type is intentionally not pinned — implementation has moved between
# SubagentStop, PostToolUse:Agent, and PostToolUse:Task as architectural
# constraints evolved; the invariant we care about is the auto-invocation,
# not the specific hook event.
if grep -qE 'hook auto-invokes .@zensu:code-reviewer.' "$AGENT"; then
  check "step 7 references hook auto-invocation of code-reviewer" PASS
else
  check "step 7 references hook auto-invocation of code-reviewer" FAIL
fi

# Step 7 must explicitly tell the agent NOT to ask the user
if grep -qiE 'do not ask the user about review' "$AGENT"; then
  check "step 7 explicitly forbids user prompt" PASS
else
  check "step 7 explicitly forbids user prompt" FAIL
fi

echo "----"
echo "S2 assert-agent: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
