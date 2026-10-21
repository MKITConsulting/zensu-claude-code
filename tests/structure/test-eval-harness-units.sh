#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/lib-unit-registry.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

unit_check "owned process groups clean normal-exit and late-fork descendants" "$PLUGIN_DIR/tests/structure/owned-process.test.js"
unit_check "fixture watch events are classified once for both backends" "$PLUGIN_DIR/tests/structure/fixture-mutation-watch.test.js"
unit_check "P7-S12b stream renderer behavior enforces framing and resource limits" "$PLUGIN_DIR/tests/structure/claude-stream-render.test.js"
unit_check "deterministic transcript contract regressions pass" "$PLUGIN_DIR/tests/structure/verify-feature-transcript-check.test.js"
unit_check_done "every unit file the registry gives this suite was graded"

echo "----"
echo "test-eval-harness-units: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
