#!/bin/bash
# Asserts hooks/hooks.json wires PostToolUse:Task to the
# post-tdd-review-delegate.sh script (which filters on subagent_type
# == "zensu:tdd-manager" and instructs the main agent to spawn the
# reviewer). Also asserts the script itself emits the expected
# additionalContext directive for the tdd-manager case.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS="$PLUGIN_DIR/hooks/hooks.json"
SCRIPT="$PLUGIN_DIR/hooks/post-tdd-review-delegate.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

# 1) hooks.json declares PostToolUse:Task pointing at the delegate script.
HOOK_CMD="$(node -e '
  const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const post = (j.hooks && j.hooks.PostToolUse) || [];
  const m = post.find(b => b.matcher === "Agent");
  if (!m) { console.log(""); process.exit(0); }
  const c = (m.hooks || []).find(h => h.type === "command");
  console.log(c ? c.command : "");
' "$HOOKS")"

case "$HOOK_CMD" in
  *post-tdd-review-delegate.sh) check "PostToolUse:Agent wired to post-tdd-review-delegate.sh" PASS ;;
  *)                             check "PostToolUse:Agent wired to post-tdd-review-delegate.sh" FAIL ;;
esac

# 2) The delegate script exists and is executable.
if [ -x "$SCRIPT" ]; then
  check "delegate script exists and is executable" PASS
else
  check "delegate script exists and is executable" FAIL
fi

# 3) The script emits additionalContext for the tdd-manager case.
OUT="$(echo '{"tool_name":"Task","tool_input":{"subagent_type":"zensu:tdd-manager","prompt":"x"}}' | "$SCRIPT" 2>/dev/null)"
case "$OUT" in
  *'"additionalContext"'*) check "script emits additionalContext for tdd-manager" PASS ;;
  *)                        check "script emits additionalContext for tdd-manager" FAIL ;;
esac

# 4) The script names @zensu:code-reviewer in its directive.
case "$OUT" in
  *'zensu:code-reviewer'*) check "directive names zensu:code-reviewer" PASS ;;
  *)                        check "directive names zensu:code-reviewer" FAIL ;;
esac

# 5) Script is silent for non-tdd-manager subagents (isolation).
OUT_OTHER="$(echo '{"tool_name":"Task","tool_input":{"subagent_type":"zensu:zensu-plm","prompt":"x"}}' | "$SCRIPT" 2>/dev/null)"
if [ -z "$OUT_OTHER" ]; then
  check "script silent for non-tdd-manager subagents" PASS
else
  check "script silent for non-tdd-manager subagents" FAIL
fi

# 6) /reflect no longer referenced anywhere in hooks.json (plugin concern).
if grep -q '/reflect' "$HOOKS"; then
  check "hooks.json no longer references /reflect" FAIL
else
  check "hooks.json no longer references /reflect" PASS
fi

echo "----"
echo "S1 assert-config: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
