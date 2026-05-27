#!/bin/bash
# Asserts CHANGELOG.md documents the review-chain change history.
# Scope intentionally covers the entire CHANGELOG (not just [Unreleased]),
# because these entries shipped in 0.3.11 and now live in the historical
# section — pinning to [Unreleased] would rot the moment the release lands.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CL="$PLUGIN_DIR/CHANGELOG.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if grep -qE '(SubagentStop|PostToolUse).*zensu:tdd-manager.*auto-invokes.*@zensu:code-reviewer' "$CL"; then
  check "CHANGELOG documents tdd-manager auto-invoke change" PASS
else
  check "CHANGELOG documents tdd-manager auto-invoke change" FAIL
fi

if grep -qE 'tdd-manager.*step 7.*no longer asks' "$CL"; then
  check "CHANGELOG documents step 7 no longer asks user" PASS
else
  check "CHANGELOG documents step 7 no longer asks user" FAIL
fi

if grep -qE 'evals/tdd-review-chain' "$CL"; then
  check "CHANGELOG documents tdd-review-chain eval suite" PASS
else
  check "CHANGELOG documents tdd-review-chain eval suite" FAIL
fi

if grep -qiE 'post-review-tdd-delegate\.sh|severity[- ]rout(e|ing)|critical.*important.*tdd-manager' "$CL"; then
  check "CHANGELOG documents severity-routing hook (post-review-tdd-delegate)" PASS
else
  check "CHANGELOG documents severity-routing hook (post-review-tdd-delegate)" FAIL
fi

if grep -qiE 'suggestions.*(not auto-fixed|buffered|deferred|presented)' "$CL"; then
  check "CHANGELOG explains Suggestions are not auto-fixed" PASS
else
  check "CHANGELOG explains Suggestions are not auto-fixed" FAIL
fi

if grep -qiE '(remov|delet|drop).*SubagentStop.*(code-reviewer|zensu:code-reviewer)' "$CL"; then
  check "CHANGELOG documents SubagentStop:code-reviewer removal" PASS
else
  check "CHANGELOG documents SubagentStop:code-reviewer removal" FAIL
fi

if grep -qE '\bT6\b.*\bT7\b.*\bT8\b' "$CL"; then
  check "CHANGELOG mentions T6/T7/T8 eval additions" PASS
else
  check "CHANGELOG mentions T6/T7/T8 eval additions" FAIL
fi

echo "----"
echo "S8 assert-changelog: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
