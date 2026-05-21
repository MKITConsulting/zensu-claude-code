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
  echo "test-changelog-round3-accuracy: $PASS PASS / $FAIL FAIL"
  exit 1
fi

if grep -F -q -- "57 to 61" "$CHANGELOG"; then
  check "CHANGELOG.md does NOT contain the inaccurate '57 to 61' suite-size claim" FAIL
else
  check "CHANGELOG.md does NOT contain the inaccurate '57 to 61' suite-size claim" PASS
fi

if grep -F -q -- "stays at 57/57 file-level PASS" "$CHANGELOG"; then
  check "CHANGELOG.md contains the corrected wording 'stays at 57/57 file-level PASS'" PASS
else
  check "CHANGELOG.md contains the corrected wording 'stays at 57/57 file-level PASS'" FAIL
fi

echo "----"
echo "test-changelog-round3-accuracy: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
