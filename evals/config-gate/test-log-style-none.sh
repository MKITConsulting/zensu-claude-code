#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN_DIR/hooks/lib/zensu-config.sh"
WRAPPER="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
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
  echo "test-log-style-none: $PASS PASS / $FAIL FAIL"
  exit 1
fi

export ZENSU_CONFIG="$EVAL_DIR/fixtures/config-log-none.json"

source "$HELPER"

style=$(_zensu_log_style)
if [ "$style" = "none" ]; then
  check "_zensu_log_style returns 'none' for config-log-none.json" PASS
else
  check "_zensu_log_style returns 'none' for config-log-none.json (got '$style')" FAIL
fi

if [ -f "$WRAPPER" ]; then
  prefix=$(bash "$WRAPPER" timestamp "$(date +%s)")
  if [ -z "$prefix" ]; then
    check "wrapper timestamp produces empty string in none mode" PASS
  else
    check "wrapper timestamp produces empty string in none mode (got '$prefix' length ${#prefix})" FAIL
  fi
else
  check "wrapper file exists at $WRAPPER" FAIL
fi

echo "----"
echo "test-log-style-none: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
