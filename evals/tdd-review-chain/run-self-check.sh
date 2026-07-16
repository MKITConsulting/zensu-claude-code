#!/bin/bash
# Deterministic current-contract self-check; no Claude spawn and no API spend.
set -u

DIR="$(cd "$(dirname "$0")" && pwd -P)"
PASS=0; FAIL=0
run() {
  if bash "$1" >/dev/null 2>&1; then
    echo "  PASS  $(basename "$1")"; PASS=$((PASS+1))
  else
    echo "  FAIL  $(basename "$1")"; FAIL=$((FAIL+1))
  fi
}

run "$DIR/assert-config.sh"
run "$DIR/assert-agent.sh"
run "$DIR/assert-version.sh"
run "$DIR/assert-changelog.sh"
run "$DIR/assert-severity-routing.sh"

COMPLIANCE="$DIR/assert-tdd-log-compliance.sh"
if bash "$COMPLIANCE" --log "$DIR/fixtures/tdd-log-good.log" >/dev/null 2>&1 \
  && ! bash "$COMPLIANCE" --log "$DIR/fixtures/tdd-log-missing-red.log" >/dev/null 2>&1 \
  && ! bash "$COMPLIANCE" --log "$DIR/fixtures/tdd-log-bulk-shortcut.log" >/dev/null 2>&1 \
  && ! bash "$COMPLIANCE" --log "$DIR/fixtures/tdd-log-ordering.log" >/dev/null 2>&1; then
  echo "  PASS  assert-tdd-log-compliance fixtures"; PASS=$((PASS+1))
else
  echo "  FAIL  assert-tdd-log-compliance fixtures"; FAIL=$((FAIL+1))
fi

echo "----"
echo "tdd-review-chain self-check: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
