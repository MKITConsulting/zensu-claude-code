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

# Severity-routing hook documented.
if grep -qiE 'post-review-tdd-delegate\.sh|severity[- ]rout(e|ing)|critical.*important.*tdd-manager' <<< "$UNREL"; then
  check "Unreleased mentions severity-routing hook (post-review-tdd-delegate)" PASS
else
  check "Unreleased mentions severity-routing hook (post-review-tdd-delegate)" FAIL
fi

# Suggestions explicitly called out as NOT auto-fixed.
if grep -qiE 'suggestions.*(not auto-fixed|buffered|deferred|presented)' <<< "$UNREL"; then
  check "Unreleased explains Suggestions are not auto-fixed" PASS
else
  check "Unreleased explains Suggestions are not auto-fixed" FAIL
fi

# SubagentStop:zensu:code-reviewer removal documented.
if grep -qiE '(remov|delet|drop).*SubagentStop.*(code-reviewer|zensu:code-reviewer)' <<< "$UNREL"; then
  check "Unreleased documents SubagentStop:code-reviewer removal" PASS
else
  check "Unreleased documents SubagentStop:code-reviewer removal" FAIL
fi

# T6/T7/T8 eval additions documented.
if grep -qE '\bT6\b.*\bT7\b.*\bT8\b' <<< "$UNREL"; then
  check "Unreleased mentions T6/T7/T8 eval additions" PASS
else
  check "Unreleased mentions T6/T7/T8 eval additions" FAIL
fi

echo "----"
echo "S8 assert-changelog: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
