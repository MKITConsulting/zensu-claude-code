#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG="$PLUGIN_DIR/evals/tdd-manager-pretool/promptfooconfig-pretool.yaml"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$CONFIG" ]; then
  check "promptfooconfig-pretool.yaml exists" FAIL
  echo "----"
  echo "test-promptfoo-concurrency: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "promptfooconfig-pretool.yaml exists" PASS

VALUE=$(grep -E '^[[:space:]]*maxConcurrency:[[:space:]]*[0-9]+' "$CONFIG" | head -1 | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}')

if [ "$VALUE" = "5" ]; then
  check "maxConcurrency is 5 (got: '$VALUE')" PASS
else
  check "maxConcurrency is 5 (got: '$VALUE')" FAIL
fi

OCCURRENCES=$(grep -cE '^[[:space:]]*maxConcurrency:' "$CONFIG")
if [ "$OCCURRENCES" = "1" ]; then
  check "exactly one maxConcurrency line in config (got $OCCURRENCES)" PASS
else
  check "exactly one maxConcurrency line in config (got $OCCURRENCES)" FAIL
fi

echo "----"
echo "test-promptfoo-concurrency: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
