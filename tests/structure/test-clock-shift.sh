#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
UNIT="$PLUGIN_DIR/tests/structure/clock-shift-v1.test.js"
PRELOAD="$PLUGIN_DIR/tests/lib/clock-shift.cjs"
REPORTER="$PLUGIN_DIR/tests/lib/clock-shift-reporter.cjs"
RUNNER="$PLUGIN_DIR/tests/run-clock-shift.js"
ALLOWLIST="$PLUGIN_DIR/tests/profiles/clock-shift-allowlist.v1.json"
WORKFLOW="$PLUGIN_DIR/.github/workflows/scheduled.yml"
PROFILE="$PLUGIN_DIR/tests/profiles/promptfoo-local-only.v1.json"
source "$PLUGIN_DIR/tests/structure/lib-unit-registry.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

finish() {
  echo "----"
  echo "test-clock-shift: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

for f in "$UNIT" "$PRELOAD" "$REPORTER" "$RUNNER" "$ALLOWLIST" "$WORKFLOW" "$PROFILE"; do
  if [ ! -f "$f" ]; then
    check "C0 required file exists: $f" FAIL
    finish
    exit 1
  fi
done
if ! command -v node >/dev/null 2>&1; then
  check "C0 node is available" FAIL
  finish
  exit 1
fi
check "C0 required files and node are present" PASS

if node -e '
  const m = require(process.argv[1]);
  const name = "test-clock-shift.sh";
  process.exit(m.ciStructureTests.includes(name) && m.nodeDepsStructureTests.includes(name) ? 0 : 1);
' "$PROFILE"; then
  check "C0a the suite is classified as a CI structure test that needs the npm devDependencies" PASS
else
  check "C0a the suite is classified as a CI structure test that needs the npm devDependencies" FAIL
fi

unit_check "C1 the clock-shift unit file passes" "$UNIT"

unit_check_done "C1z every unit file the registry gives this suite was graded"
finish
