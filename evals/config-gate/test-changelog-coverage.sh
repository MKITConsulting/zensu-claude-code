#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CHANGELOG="$PLUGIN_DIR/CHANGELOG.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$CHANGELOG" ]; then
  check "CHANGELOG.md exists" FAIL
  echo "----"
  echo "test-changelog-coverage: $PASS PASS / $FAIL FAIL"
  exit 1
fi

contains() {
  if grep -F -q -- "$1" "$CHANGELOG"; then return 0; fi
  return 1
}

if contains "autoFixIncludeSuggestions"; then
  check "CHANGELOG mentions autoFixIncludeSuggestions" PASS
else
  check "CHANGELOG mentions autoFixIncludeSuggestions" FAIL
fi

if contains "autoFixMaxRounds"; then
  check "CHANGELOG mentions autoFixMaxRounds" PASS
else
  check "CHANGELOG mentions autoFixMaxRounds" FAIL
fi

if contains "_zensu_resolve_config" || contains "Config Resolution Order" || contains "project-local"; then
  check "CHANGELOG describes the config resolution order change" PASS
else
  check "CHANGELOG describes the config resolution order change" FAIL
fi

if contains "CLAUDE_PROJECT_DIR"; then
  check "CHANGELOG references CLAUDE_PROJECT_DIR" PASS
else
  check "CHANGELOG references CLAUDE_PROJECT_DIR" FAIL
fi

if contains "test-resolution-order-"; then
  check "CHANGELOG references new test-resolution-order- tests" PASS
else
  check "CHANGELOG references new test-resolution-order- tests" FAIL
fi

if contains "test-autofix-suggestions-"; then
  check "CHANGELOG references new test-autofix-suggestions- tests" PASS
else
  check "CHANGELOG references new test-autofix-suggestions- tests" FAIL
fi

if contains "test-autofix-rounds-"; then
  check "CHANGELOG references new test-autofix-rounds- tests" PASS
else
  check "CHANGELOG references new test-autofix-rounds- tests" FAIL
fi

if contains "Edit/Write/MultiEdit only" || contains "Edit/Write/MultiEdit"; then
  check "CHANGELOG states gate scope: Edit/Write/MultiEdit only (scope reduction)" PASS
else
  check "CHANGELOG states gate scope: Edit/Write/MultiEdit only" FAIL
fi

if contains "assert-no-shell-redirect-bypass"; then
  check "CHANGELOG references renamed assert-no-shell-redirect-bypass" PASS
else
  check "CHANGELOG references renamed assert-no-shell-redirect-bypass" FAIL
fi

if contains "stale-lock" || contains "stale lock"; then
  check "CHANGELOG documents stale-lock recovery" PASS
else
  check "CHANGELOG documents stale-lock recovery" FAIL
fi

if contains "hard-link" || contains "hard link"; then
  check "CHANGELOG documents hard-link rejection (F7)" PASS
else
  check "CHANGELOG documents hard-link rejection" FAIL
fi

if contains "BOM"; then
  check "CHANGELOG documents BOM-stripping in inline-header (F8)" PASS
else
  check "CHANGELOG documents BOM-stripping in inline-header" FAIL
fi

echo "----"
echo "test-changelog-coverage: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
