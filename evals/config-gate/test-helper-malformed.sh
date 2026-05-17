#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN_DIR/hooks/lib/zensu-config.sh"
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HELPER" ]; then
  check "helper file exists" FAIL
  echo "----"
  echo "test-helper-malformed: $PASS PASS / $FAIL FAIL"
  exit 1
fi

export ZENSU_CONFIG="$EVAL_DIR/fixtures/config-malformed.json"

source "$HELPER"

if zensu_hook_enabled autoTdd; then
  check "helper returns 0 (enabled) when config is malformed JSON" PASS
else
  check "helper returns 0 (enabled) when config is malformed JSON" FAIL
fi

if zensu_hook_enabled pulseSession; then
  check "helper returns 0 (enabled) for any key when malformed" PASS
else
  check "helper returns 0 (enabled) for any key when malformed" FAIL
fi

echo "----"
echo "test-helper-malformed: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
