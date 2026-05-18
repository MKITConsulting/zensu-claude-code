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
  echo "test-log-style-relative: $PASS PASS / $FAIL FAIL"
  exit 1
fi

export ZENSU_CONFIG="$EVAL_DIR/fixtures/config-log-relative.json"

source "$HELPER"

style=$(_zensu_log_style)
if [ "$style" = "relative" ]; then
  check "_zensu_log_style returns 'relative' for config-log-relative.json" PASS
else
  check "_zensu_log_style returns 'relative' for config-log-relative.json (got '$style')" FAIL
fi

if [ -f "$WRAPPER" ]; then
  start=$(($(date +%s) - 90))
  prefix=$(bash "$WRAPPER" timestamp "$start")
  case "$prefix" in
    "[+00:01:29] "|"[+00:01:30] "|"[+00:01:31] ")
      check "wrapper timestamp produces '[+00:01:30] ' (+/-1s) in relative mode" PASS
      ;;
    *)
      check "wrapper timestamp produces '[+00:01:30] ' (+/-1s) in relative mode (got '$prefix')" FAIL
      ;;
  esac
else
  check "wrapper file exists at $WRAPPER" FAIL
fi

echo "----"
echo "test-log-style-relative: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
