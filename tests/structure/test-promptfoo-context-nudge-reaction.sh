#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
EVAL_DIR="$PLUGIN_DIR/evals/context-nudge-reaction"
CFG="$EVAL_DIR/promptfooconfig.yaml"
CONF="$EVAL_DIR/scenarios/reaction-configured.yaml"
FIXTURE="$EVAL_DIR/test-projects/empty-host/CLAUDE.md"
README="$EVAL_DIR/README.md"
WRAPPER="$PLUGIN_DIR/scripts/claude-promptfoo-wrapper.sh"
REMOVED_AUTO="$EVAL_DIR/scenarios/reaction-auto-detected.yaml"
REMOVED_NEG="$EVAL_DIR/scenarios/reaction-negative-control.yaml"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$CFG" ]; then
  check "P1 promptfooconfig.yaml exists" FAIL
  echo "----"
  echo "test-promptfoo-context-nudge-reaction: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "P1 promptfooconfig.yaml exists" PASS

for f in "$CONF" "$FIXTURE" "$README"; do
  if [ -f "$f" ]; then
    check "P1 file exists: ${f#$PLUGIN_DIR/}" PASS
  else
    check "P1 file exists: ${f#$PLUGIN_DIR/}" FAIL
  fi
done

for r in "$REMOVED_AUTO" "$REMOVED_NEG"; do
  if [ ! -f "$r" ]; then
    check "P1b removed (confident-only): ${r#$PLUGIN_DIR/}" PASS
  else
    check "P1b still present, should be removed: ${r#$PLUGIN_DIR/}" FAIL
  fi
done

if grep -qF 'claude-promptfoo-wrapper.sh' "$CFG"; then
  check "P2 promptfooconfig references claude-promptfoo-wrapper.sh provider" PASS
else
  check "P2 promptfooconfig references claude-promptfoo-wrapper.sh provider" FAIL
fi

if grep -qF './test-projects/empty-host' "$CFG"; then
  check "P3 promptfooconfig points at test-projects/empty-host fixture" PASS
else
  check "P3 promptfooconfig points at test-projects/empty-host fixture" FAIL
fi

if grep -qE '^[[:space:]]*agent:' "$CFG"; then
  check "P4 promptfooconfig does NOT force an agent (main-thread reaction)" FAIL
else
  check "P4 promptfooconfig does NOT force an agent (main-thread reaction)" PASS
fi

if grep -qF 'reaction-configured.yaml' "$CFG"; then
  check "P5 config references the confident scenario (reaction-configured.yaml)" PASS
else
  check "P5 config references the confident scenario (reaction-configured.yaml)" FAIL
fi

if grep -qF 'reaction-auto-detected.yaml' "$CFG" || grep -qF 'reaction-negative-control.yaml' "$CFG"; then
  check "P5b config tests: no longer references the removed hedged-premise scenarios" FAIL
else
  check "P5b config tests: no longer references the removed hedged-premise scenarios" PASS
fi

if grep -qE '^[[:space:]]*assert:' "$CONF" 2>/dev/null; then
  check "P6 configured scenario declares assert block" PASS
else
  check "P6 configured scenario declares assert block" FAIL
fi

if grep -qF 'type: javascript' "$CONF" 2>/dev/null; then
  check "P6 configured scenario uses javascript-style assertions" PASS
else
  check "P6 configured scenario uses javascript-style assertions" FAIL
fi

if grep -qF 'RELAY-TO-USER' "$CONF" 2>/dev/null; then
  check "P7 configured scenario grades the RELAY-TO-USER decision token" PASS
else
  check "P7 configured scenario grades the RELAY-TO-USER decision token" FAIL
fi

if grep -qF '/compact' "$CONF" 2>/dev/null; then
  check "P8 configured scenario asserts /compact surfaced as a user action" PASS
else
  check "P8 configured scenario asserts /compact surfaced as a user action" FAIL
fi

if grep -qF '1M' "$CONF" 2>/dev/null; then
  check "P9 configured scenario references the 1M window" PASS
else
  check "P9 configured scenario references the 1M window" FAIL
fi

if [ -x "$WRAPPER" ]; then
  check "P10 referenced provider script exists and is executable" PASS
else
  check "P10 referenced provider script exists and is executable" FAIL
fi

if command -v node >/dev/null 2>&1; then
  if node -e "
    const fs = require('fs');
    const txt = fs.readFileSync('$CFG', 'utf8');
    if (!/^description:\s*['\"]/m.test(txt)) process.exit(11);
    if (!/^providers:/m.test(txt)) process.exit(12);
    if (!/^tests:/m.test(txt)) process.exit(13);
    if (!/^prompts:/m.test(txt)) process.exit(14);
    process.exit(0);
  "; then
    check "P11 promptfooconfig has top-level description/providers/prompts/tests keys" PASS
  else
    check "P11 promptfooconfig missing one of description/providers/prompts/tests" FAIL
  fi
else
  check "P11 (skipped — node not on PATH)" PASS
fi

echo "----"
echo "test-promptfoo-context-nudge-reaction: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
