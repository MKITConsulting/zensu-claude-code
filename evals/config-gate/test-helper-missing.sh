#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN_DIR/hooks/lib/zensu-config.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HELPER" ]; then
  check "helper file exists" FAIL
  echo "----"
  echo "test-helper-missing: $PASS PASS / $FAIL FAIL"
  exit 1
fi

check "helper file exists" PASS

export ZENSU_CONFIG="/tmp/zensu-config-nonexistent-$$.json"
rm -f "$ZENSU_CONFIG"

source "$HELPER"

if zensu_hook_enabled autoTdd; then
  check "helper returns 0 (enabled) when config file missing" PASS
else
  check "helper returns 0 (enabled) when config file missing" FAIL
fi

echo "----"
echo "test-helper-missing: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
