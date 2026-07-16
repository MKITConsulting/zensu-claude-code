#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SESSION="$ROOT/tests/structure/test-session-control-claude.sh"
REVIEWER="$ROOT/tests/structure/test-reviewer-capability-gate.sh"
CORRUPTION="$ROOT/tests/structure/test-tdd-state-corruption-fail-closed.sh"
MARKETPLACE="$ROOT/evals/session-control/tests/marketplace-fixture-selftest.sh"
RESET="$ROOT/evals/reset-review-limit/tests/sealed-evidence.test.js"
PASS=0; FAIL=0
check() {
  if [ "$2" = PASS ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1));
  else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

for file in "$SESSION" "$REVIEWER" "$CORRUPTION" "$MARKETPLACE"; do
  if grep -qF 'MINGW*|MSYS*|CYGWIN*' "$file"; then
    check "Windows guard exists: ${file#$ROOT/}" PASS
  else
    check "Windows guard exists: ${file#$ROOT/}" FAIL
  fi
done

if grep -qF 'process.platform === '\''win32'\''' "$RESET" \
  && grep -qF "runScenario('reset-cas-happy', reset)" "$RESET" \
  && grep -qF "runScenario('reset-invalid-state', null)" "$RESET" \
  && grep -qF "runScenario('reset-sidecar-isolation', reset)" "$RESET"; then
  check "reset selftest skips only the symlink sidecar row on Windows" PASS
else
  check "reset selftest skips only the symlink sidecar row on Windows" FAIL
fi

if grep -qF 'POSIX 0600 record-mode assertion skipped only on Windows' "$SESSION" \
  && grep -qF 'symlinked CLAUDE_PLUGIN_DATA fails closed' "$SESSION" \
  && ! grep -Eq 'MINGW\*\|MSYS\*\|CYGWIN\*\).*exit 0' "$SESSION"; then
  check "Session Control keeps non-mode/non-symlink semantics unconditional" PASS
else
  check "Session Control keeps non-mode/non-symlink semantics unconditional" FAIL
fi

if grep -qF 'dangling symlink leaf' "$REVIEWER" \
  && grep -qF 'neutral apply_patch Move to outside project is denied' "$REVIEWER" \
  && grep -qF 'workflow-state symlink rejection skipped only on Windows' "$CORRUPTION" \
  && grep -qF 'SKIP POSIX 0700 assertion on Windows' "$MARKETPLACE"; then
  check "security cases remain present behind only their narrow portability guards" PASS
else
  check "security cases remain present behind only their narrow portability guards" FAIL
fi

printf '%s\n' '----' "test-windows-portability-guards: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
