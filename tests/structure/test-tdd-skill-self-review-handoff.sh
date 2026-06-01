#!/bin/bash
# Pins skills/tdd/SKILL.md Phase 6 step 10: on PASS / suggestions-only the chain
# no longer closes directly with --chain-done; it routes to --code-review-done +
# /zensu:self-review, and the self-review stage owns the --chain-done terminus.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_MD="$PLUGIN_DIR/skills/tdd/SKILL.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$SKILL_MD" ]; then
  check "skills/tdd/SKILL.md exists" FAIL
  echo "test-tdd-skill-self-review-handoff: $PASS PASS / $FAIL FAIL"
  exit 1
fi

# Phase 6 step 10 region: from the "Close implementation and trigger the review chain" step to EOF.
REGION="$(sed -n '/Close implementation and trigger the review chain/,$p' "$SKILL_MD")"

printf '%s\n' "$REGION" | grep -qF "zensu:self-review" \
  && check "H1 Phase 6.10 hands off to /zensu:self-review" PASS || check "H1 self-review handoff" FAIL
printf '%s\n' "$REGION" | grep -qF -- "--code-review-done" \
  && check "H2 Phase 6.10 routes PASS/suggestions via --code-review-done" PASS || check "H2 --code-review-done" FAIL
printf '%s\n' "$REGION" | grep -qiE "self-review (stage )?owns|self-review finalizes" \
  && check "H3 Phase 6.10 states self-review owns/finalizes the terminus" PASS || check "H3 self-review owns terminus" FAIL
printf '%s\n' "$REGION" | grep -qF "zensu:code-reviewer" \
  && check "H4 Phase 6.10 still spawns zensu:code-reviewer first (regression)" PASS || check "H4 reviewer still first" FAIL

echo "----"
echo "test-tdd-skill-self-review-handoff: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
