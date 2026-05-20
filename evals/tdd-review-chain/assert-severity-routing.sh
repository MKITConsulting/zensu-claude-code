#!/bin/bash
# Asserts hooks/post-review-tdd-delegate.sh classifies zensu:code-reviewer
# findings by severity and routes ONLY Critical + Important to tdd-manager.
# Suggestions / Minor / Nits are NOT auto-fixed.
#
# Test runner for TDD: bash exit 0 = PASS, non-zero = FAIL.
set -u

export CLAUDE_PLUGIN_DATA="$(mktemp -d)"
cleanup() { rm -rf "$CLAUDE_PLUGIN_DATA"; }
trap cleanup EXIT

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS="$PLUGIN_DIR/hooks/hooks.json"
SCRIPT="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
EXISTING_SCRIPT="$PLUGIN_DIR/hooks/post-tdd-review-delegate.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

# 1) New delegate script exists and is executable.
if [ -x "$SCRIPT" ]; then
  check "post-review-tdd-delegate.sh exists and is executable" PASS
else
  check "post-review-tdd-delegate.sh exists and is executable" FAIL
fi

# 2) Script emits additionalContext when subagent_type == zensu:code-reviewer.
OUT_REVIEWER="$(echo '{"tool_name":"Task","tool_input":{"subagent_type":"zensu:code-reviewer","prompt":"x"}}' | "$SCRIPT" 2>/dev/null || echo '')"
case "$OUT_REVIEWER" in
  *'"additionalContext"'*) check "emits additionalContext for code-reviewer subagent" PASS ;;
  *)                        check "emits additionalContext for code-reviewer subagent" FAIL ;;
esac

# 3) Script is silent (no output) for zensu:tdd-manager subagent (isolation
#    from the existing post-tdd-review-delegate.sh which handles that case).
OUT_TDDM="$(echo '{"tool_name":"Task","tool_input":{"subagent_type":"zensu:tdd-manager","prompt":"x"}}' | "$SCRIPT" 2>/dev/null || echo '')"
if [ -z "$OUT_TDDM" ]; then
  check "silent for tdd-manager subagent (no cross-contamination)" PASS
else
  check "silent for tdd-manager subagent (no cross-contamination)" FAIL
fi

# 4) Script is silent for unrelated subagents.
OUT_OTHER="$(echo '{"tool_name":"Task","tool_input":{"subagent_type":"zensu:zensu-plm","prompt":"x"}}' | "$SCRIPT" 2>/dev/null || echo '')"
if [ -z "$OUT_OTHER" ]; then
  check "silent for unrelated subagents" PASS
else
  check "silent for unrelated subagents" FAIL
fi

# 5) Directive names zensu:tdd-manager as the next dispatch target.
case "$OUT_REVIEWER" in
  *'zensu:tdd-manager'*) check "directive names zensu:tdd-manager" PASS ;;
  *)                      check "directive names zensu:tdd-manager" FAIL ;;
esac

# 6) Directive is imperative (STOP. / VERY NEXT TOOL CALL).
case "$OUT_REVIEWER" in
  *"VERY NEXT TOOL CALL"*|*"STOP."*) check "directive is imperative" PASS ;;
  *)                                  check "directive is imperative" FAIL ;;
esac

# 7) Directive contains severity-classification keywords.
SEV_KEYS=("Critical" "Important" "Suggestions")
for KEY in "${SEV_KEYS[@]}"; do
  case "$OUT_REVIEWER" in
    *"$KEY"*) check "directive mentions severity keyword '$KEY'" PASS ;;
    *)         check "directive mentions severity keyword '$KEY'" FAIL ;;
  esac
done

# 8) Directive says Suggestions / Minor / Nits are NOT auto-fixed.
case "$OUT_REVIEWER" in
  *"not auto-fixed"*|*"NOT auto-fixed"*|*"not auto-fix"*) check "directive marks Suggestions as not auto-fixed" PASS ;;
  *)                                                       check "directive marks Suggestions as not auto-fixed" FAIL ;;
esac

# 9) Directive contains the three status-line phrases for cases A/B/C.
STATUS_LINES=(
  "No fixes needed"
  "No critical/important findings"
  "Delegating critical+important findings"
)
for LINE in "${STATUS_LINES[@]}"; do
  case "$OUT_REVIEWER" in
    *"$LINE"*) check "directive defines status line: '$LINE'" PASS ;;
    *)          check "directive defines status line: '$LINE'" FAIL ;;
  esac
done

# 10) hooks.json wires the new script under PostToolUse:Agent.
WIRED="$(node -e '
  const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const post = (j.hooks && j.hooks.PostToolUse) || [];
  const m = post.find(b => b.matcher === "Agent");
  if (!m) { console.log("no-matcher"); process.exit(0); }
  const hits = (m.hooks || []).filter(h => h.type === "command" && /post-review-tdd-delegate\.sh/.test(h.command || ""));
  console.log(hits.length ? "wired" : "missing");
' "$HOOKS" 2>/dev/null || echo error)"

if [ "$WIRED" = "wired" ]; then
  check "hooks.json wires post-review-tdd-delegate.sh under PostToolUse:Agent" PASS
else
  check "hooks.json wires post-review-tdd-delegate.sh under PostToolUse:Agent" FAIL
fi

# 11) Both delegate scripts coexist (the existing tdd-manager → reviewer chain
#     must still be wired alongside the new reviewer → tdd-manager chain).
BOTH_WIRED="$(node -e '
  const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const post = (j.hooks && j.hooks.PostToolUse) || [];
  const m = post.find(b => b.matcher === "Agent");
  if (!m) { console.log("no"); process.exit(0); }
  const cmds = (m.hooks || []).map(h => h.command || "");
  const hasOld = cmds.some(c => /post-tdd-review-delegate\.sh/.test(c));
  const hasNew = cmds.some(c => /post-review-tdd-delegate\.sh/.test(c));
  console.log(hasOld && hasNew ? "yes" : "no");
' "$HOOKS" 2>/dev/null || echo no)"

if [ "$BOTH_WIRED" = "yes" ]; then
  check "both PostToolUse:Agent delegate scripts coexist" PASS
else
  check "both PostToolUse:Agent delegate scripts coexist" FAIL
fi

# 12) Existing post-tdd-review-delegate.sh still emits its directive (sanity:
#     we did not accidentally break the upstream chain).
if [ -x "$EXISTING_SCRIPT" ]; then
  OUT_EXISTING="$(echo '{"tool_name":"Task","tool_input":{"subagent_type":"zensu:tdd-manager","prompt":"x"}}' | "$EXISTING_SCRIPT" 2>/dev/null || echo '')"
  case "$OUT_EXISTING" in
    *'zensu:code-reviewer'*) check "existing tdd-manager→reviewer chain still emits" PASS ;;
    *)                        check "existing tdd-manager→reviewer chain still emits" FAIL ;;
  esac
else
  check "existing tdd-manager→reviewer chain still emits" FAIL
fi

# 13) SubagentStop:zensu:code-reviewer matcher must be REMOVED (the new
#     PostToolUse:Agent severity-routing hook supersedes it).
REMOVED="$(node -e '
  const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const ss = (j.hooks && j.hooks.SubagentStop) || [];
  const hits = ss.filter(b => b.matcher === "zensu:code-reviewer");
  console.log(hits.length === 0 ? "removed" : "present");
' "$HOOKS" 2>/dev/null || echo error)"

if [ "$REMOVED" = "removed" ]; then
  check "SubagentStop:zensu:code-reviewer matcher removed" PASS
else
  check "SubagentStop:zensu:code-reviewer matcher removed" FAIL
fi

echo "----"
echo "S-SR assert-severity-routing: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
