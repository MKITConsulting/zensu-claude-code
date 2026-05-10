#!/bin/bash
# Asserts CHANGELOG.md [Unreleased] section documents the review-chain change.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CL="$PLUGIN_DIR/CHANGELOG.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

# Extract Unreleased section (between [Unreleased] header and next ## heading)
UNREL="$(awk '/^## \[Unreleased\]/{flag=1; next} /^## \[/{flag=0} flag' "$CL")"

if grep -qE '(SubagentStop|PostToolUse).*zensu:tdd-manager.*auto-invokes.*@zensu:code-reviewer' <<< "$UNREL"; then
  check "Unreleased mentions tdd-manager auto-invoke change" PASS
else
  check "Unreleased mentions tdd-manager auto-invoke change" FAIL
fi

if grep -qE 'tdd-manager.*step 7.*no longer asks' <<< "$UNREL"; then
  check "Unreleased mentions step 7 no longer asks user" PASS
else
  check "Unreleased mentions step 7 no longer asks user" FAIL
fi

if grep -qE 'evals/tdd-review-chain' <<< "$UNREL"; then
  check "Unreleased mentions tdd-review-chain eval suite" PASS
else
  check "Unreleased mentions tdd-review-chain eval suite" FAIL
fi

echo "----"
echo "S8 assert-changelog: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
