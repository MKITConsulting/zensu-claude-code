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
  echo "test-log-style-long-delta: $PASS PASS / $FAIL FAIL"
  exit 1
fi

export ZENSU_CONFIG="$EVAL_DIR/fixtures/config-log-relative.json"

start=$(($(date +%s) - 90000))

STDERR_FILE="/tmp/zensu-log-long-delta-stderr-$$.txt"
rm -f "$STDERR_FILE"
out=$(bash "$WRAPPER" timestamp "$start" 2>"$STDERR_FILE")
rc=$?
err=$(cat "$STDERR_FILE")
rm -f "$STDERR_FILE"

if [ "$rc" -eq 0 ]; then
  check "long-delta (25h ago): exit code is 0" PASS
else
  check "long-delta (25h ago): exit code is 0 (got $rc; stderr='$err')" FAIL
fi

if [[ "$out" =~ ^\[\+1d\ [0-9]{2}:[0-9]{2}:[0-9]{2}\]\ $ ]]; then
  check "long-delta (25h ago): stdout matches '[+1d HH:MM:SS] '" PASS
else
  check "long-delta (25h ago): stdout matches '[+1d HH:MM:SS] ' (got '$out')" FAIL
fi

echo "----"
echo "test-log-style-long-delta: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
