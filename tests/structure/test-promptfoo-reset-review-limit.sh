#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
EVAL_DIR="$PLUGIN_DIR/evals/reset-review-limit"
CFG="$EVAL_DIR/promptfooconfig.yaml"
HAPPY="$EVAL_DIR/scenarios/reset-counter-happy.yaml"
EMPTY="$EVAL_DIR/scenarios/reset-counter-empty.yaml"
FIXTURE="$EVAL_DIR/test-projects/empty-host/CLAUDE.md"
README="$EVAL_DIR/README.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$CFG" ]; then
  check "P1 promptfooconfig.yaml exists" FAIL
  echo "----"
  echo "test-promptfoo-reset-review-limit: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "P1 promptfooconfig.yaml exists" PASS

for f in "$HAPPY" "$EMPTY" "$FIXTURE" "$README"; do
  if [ -f "$f" ]; then
    check "P1 file exists: ${f#$PLUGIN_DIR/}" PASS
  else
    check "P1 file exists: ${f#$PLUGIN_DIR/}" FAIL
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

if grep -E '^\s*-\s+id:\s+' "$CFG" | grep -qF 'agent:'; then
  check "P4 promptfooconfig does NOT force an agent (skill is invoked directly)" FAIL
else
  if grep -qE '^\s+agent:' "$CFG"; then
    check "P4 promptfooconfig does NOT force an agent (skill is invoked directly) — found agent: line" FAIL
  else
    check "P4 promptfooconfig does NOT force an agent (skill is invoked directly)" PASS
  fi
fi

for scenario_file in "$HAPPY" "$EMPTY"; do
  base="${scenario_file##*/}"
  if grep -qF '/zensu:reset-review-limit' "$scenario_file"; then
    check "P5 ${base} spec_block references /zensu:reset-review-limit" PASS
  else
    check "P5 ${base} spec_block references /zensu:reset-review-limit" FAIL
  fi

  if grep -qE '^\s*assert:' "$scenario_file"; then
    check "P5 ${base} declares assert block" PASS
  else
    check "P5 ${base} declares assert block" FAIL
  fi

  if grep -qF 'type: javascript' "$scenario_file"; then
    check "P5 ${base} uses javascript-style assertions" PASS
  else
    check "P5 ${base} uses javascript-style assertions" FAIL
  fi
done

if grep -qF 'rounds-eval-sess-A.json' "$HAPPY" && grep -qF 'rounds-eval-sess-B.json' "$HAPPY"; then
  check "P6 happy scenario pre-seeds two distinct counter files (A + B)" PASS
else
  check "P6 happy scenario pre-seeds two distinct counter files (A + B)" FAIL
fi

if grep -qF 'Removed:' "$HAPPY" && grep -qF 'Reset complete:' "$HAPPY"; then
  check "P7 happy scenario asserts both 'Removed:' AND 'Reset complete:' literals" PASS
else
  check "P7 happy scenario asserts both 'Removed:' AND 'Reset complete:' literals" FAIL
fi

if grep -qF 'No round counter files in' "$EMPTY" || grep -qF 'does not exist' "$EMPTY"; then
  check "P8 empty scenario asserts no-op message ('No round counter files in' or 'does not exist')" PASS
else
  check "P8 empty scenario asserts no-op message" FAIL
fi

if grep -qE 'pass:\s*!.*Removed' "$EMPTY" || grep -qE 'claimedRemoval' "$EMPTY"; then
  check "P9 empty scenario has a must-not-match assert against 'Removed:'" PASS
else
  check "P9 empty scenario has a must-not-match assert against 'Removed:'" FAIL
fi

if [ -x "$PLUGIN_DIR/scripts/claude-promptfoo-wrapper.sh" ]; then
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
echo "test-promptfoo-reset-review-limit: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
