#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/lib-unit-summary.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

drive() {
  local unit="$PLUGIN_DIR/tests/structure/$1" passing="$2" failing="$3" floor out rc overview
  floor="$(unit_overview_declared "${unit##*/}")"
  out="$(node --test "$unit" 2>&1)"
  rc=$?
  if [ "$rc" = 0 ] && unit_cases_registered_floor_text "$out" "$floor"; then
    check "$passing ($(unit_cases_report_text "$out"))" PASS
  else
    check "$failing (rc=$rc, $(unit_cases_report_text "$out"), want >= ${floor:-<no overview row>} registered)" FAIL
    printf '%s\n' "$out" | tail -60
  fi
  if overview="$(unit_overview_check "$unit")"; then
    check "the SUITE-OVERVIEW Blocks cell matches what ${unit##*/} registers ($floor)" PASS
  else
    check "$overview" FAIL
  fi
}

drive owned-process.test.js \
  "owned process groups clean normal-exit and late-fork descendants" \
  "owned process group regressions pass"
drive fixture-mutation-watch.test.js \
  "fixture watch events are classified once for both backends" \
  "fixture watch event classification pins hold"
drive claude-stream-render.test.js \
  "P7-S12b stream renderer behavior enforces framing and resource limits" \
  "P7-S12b stream renderer behavior enforces framing and resource limits"
drive verify-feature-transcript-check.test.js \
  "deterministic transcript contract regressions pass" \
  "deterministic transcript contract regressions pass"

echo "----"
echo "test-eval-harness-units: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
