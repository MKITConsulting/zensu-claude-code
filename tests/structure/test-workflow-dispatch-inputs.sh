#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
UNIT="$ROOT/tests/structure/workflow-dispatch-inputs.test.js"
. "$(dirname "$0")/lib-unit-registry.sh"
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

unit_check "workflow dispatch-input unit file passes" "$UNIT"
unit_check_done "every unit file the registry gives this suite was graded"

printf '%s\n' '----' "test-workflow-dispatch-inputs: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
