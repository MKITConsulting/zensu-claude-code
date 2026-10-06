#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
UNIT="$ROOT/tests/structure/workflow-dispatch-inputs.test.js"
. "$(dirname "$0")/lib-unit-summary.sh"
PASS=0
FAIL=0

check() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

if [ -f "$UNIT" ]; then
  OUT="$(node --test "$UNIT" 2>&1)"
  RC=$?
  if [ "$RC" -eq 0 ] && unit_cases_registered_floor_text "$OUT" 24; then
    check "workflow dispatch-input suite passes ($(unit_cases_report_text "$OUT"))" PASS
  else
    check "workflow dispatch-input suite passes (rc=$RC, $(unit_cases_report_text "$OUT"))" FAIL
    printf '%s\n' "$OUT" | tail -60
  fi
else
  check "workflow dispatch-input suite exists" FAIL
fi

printf '%s\n' '----' "test-workflow-dispatch-inputs: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
