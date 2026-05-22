#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CFG="$PLUGIN_DIR/evals/tdd-manager-pretool/promptfooconfig-pretool.yaml"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$CFG" ]; then
  check "promptfooconfig-pretool.yaml exists" FAIL
  echo "----"
  echo "test-pretool-config-prompts: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "promptfooconfig-pretool.yaml exists" PASS

if grep -qE '^prompts:[[:space:]]*$' "$CFG"; then
  check "S1.a top-level prompts: block present" PASS
else
  check "S1.a top-level prompts: block present" FAIL
fi

if grep -qF '{{spec_block}}' "$CFG"; then
  check "S1.b prompt template references {{spec_block}} (for precondition scenarios)" PASS
else
  check "S1.b prompt template references {{spec_block}} (for precondition scenarios)" FAIL
fi

if grep -qF '{% include spec_path %}' "$CFG"; then
  check "S1.c prompt template falls back to {% include spec_path %} (for spec_path scenarios)" PASS
else
  check "S1.c prompt template falls back to {% include spec_path %} (for spec_path scenarios)" FAIL
fi

if awk '/^[[:space:]]*transform:[[:space:]]*\|[[:space:]]*$/,/^[^[:space:]]/' "$CFG" | grep -qE '^[[:space:]]*return[[:space:]]'; then
  check "S2.a transform block contains explicit 'return' statement" PASS
else
  check "S2.a transform block contains explicit 'return' statement" FAIL
fi

if awk '/^[[:space:]]*transform:[[:space:]]*\|[[:space:]]*$/,/^[^[:space:]]/' "$CFG" | grep -qE '^[[:space:]]*\(\{[[:space:]]*output'; then
  check "S2.b transform block no longer uses bare-arrow ({ output, context }) => (...) (no-return bug)" FAIL
else
  check "S2.b transform block no longer uses bare-arrow ({ output, context }) => (...) (no-return bug)" PASS
fi

SCEN_DIR="$PLUGIN_DIR/evals/tdd-manager-pretool/scenarios"
BAD=0
BAD_LIST=""
for f in \
  "$SCEN_DIR/01-happy-frontend.yaml" \
  "$SCEN_DIR/02-happy-backend.yaml" \
  "$SCEN_DIR/03-drift-impl-before-red.yaml" \
  "$SCEN_DIR/04-drift-skipped-test-run.yaml" \
  "$SCEN_DIR/06-drift-fake-green.yaml" \
  "$SCEN_DIR/08-refactor-after-green.yaml" \
  "$SCEN_DIR/precondition-missing-cli.yaml" \
  "$SCEN_DIR/precondition-missing-secret.yaml" \
  "$SCEN_DIR/precondition-drift-audit.yaml"; do
  [ -f "$f" ] || continue
  RETURN_COUNT=$(grep -cE 'return[[:space:]]*\{' "$f" 2>/dev/null)
  RETURN_COUNT=${RETURN_COUNT:-0}
  SCORE_COUNT=$(grep -cE 'score:[[:space:]]' "$f" 2>/dev/null)
  SCORE_COUNT=${SCORE_COUNT:-0}
  if [ "$RETURN_COUNT" -gt 0 ] && [ "$SCORE_COUNT" -lt "$RETURN_COUNT" ]; then
    BAD=$((BAD + 1))
    BAD_LIST="$BAD_LIST $(basename "$f")(returns=$RETURN_COUNT,score=$SCORE_COUNT)"
  fi
done
if [ "$BAD" -eq 0 ]; then
  check "S6 every JS-assertion 'return { ... }' block has a corresponding 'score:' field (required by promptfoo isGradingResult)" PASS
else
  check "S6 scenarios with return { ... } but missing score: ($BAD files:$BAD_LIST)" FAIL
fi

echo "----"
echo "test-pretool-config-prompts: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
