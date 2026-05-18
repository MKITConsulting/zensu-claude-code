#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$WRAPPER" ]; then
  check "wrapper file exists" FAIL
  echo "----"
  echo "test-log-style-negative-delta: $PASS PASS / $FAIL FAIL"
  exit 1
fi

export ZENSU_CONFIG="$EVAL_DIR/fixtures/config-log-relative.json"

future_start=$(($(date +%s) + 60))
prefix=$(bash "$WRAPPER" timestamp "$future_start")

if [ "$prefix" = "[+00:00:00] " ]; then
  check "future-dated start clamps to '[+00:00:00] ' in relative mode" PASS
else
  check "future-dated start clamps to '[+00:00:00] ' in relative mode (got '$prefix')" FAIL
fi

echo "----"
echo "test-log-style-negative-delta: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
