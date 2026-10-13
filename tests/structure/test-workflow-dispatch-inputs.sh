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
  FLOOR="$(unit_overview_declared "${UNIT##*/}")"
  OUT="$(node --test "$UNIT" 2>&1)"
  RC=$?
  if [ "$RC" -eq 0 ] && unit_cases_registered_floor_text "$OUT" "$FLOOR"; then
    check "workflow dispatch-input suite passes ($(unit_cases_report_text "$OUT"))" PASS
  else
    check "workflow dispatch-input suite passes (rc=$RC, $(unit_cases_report_text "$OUT"), want >= ${FLOOR:-<no overview row>} registered)" FAIL
    printf '%s\n' "$OUT" | tail -60
  fi
  if OVERVIEW="$(unit_overview_check "$UNIT")"; then
    check "the SUITE-OVERVIEW Blocks cell matches what ${UNIT##*/} registers ($FLOOR)" PASS
  else
    check "$OVERVIEW" FAIL
  fi
else
  check "workflow dispatch-input suite exists" FAIL
fi

printf '%s\n' '----' "test-workflow-dispatch-inputs: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
