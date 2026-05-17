#!/bin/bash
set -u

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$EVAL_DIR/../.." && pwd)"
RESULTS_DIR="$EVAL_DIR/results"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT="$RESULTS_DIR/report-$TIMESTAMP.txt"
mkdir -p "$RESULTS_DIR"

MODE="${1:-full}"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL=0

check() {
  local label="$1" result="$2"
  TOTAL=$((TOTAL + 1))
  if [ "$result" = "PASS" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  PASS  $label" | tee -a "$REPORT"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  FAIL  $label" | tee -a "$REPORT"
  fi
}

run_test() {
  local script="$1"
  local label="$2"
  if [ -x "$script" ]; then
    if "$script" >/dev/null 2>&1; then
      check "$label" PASS
    else
      check "$label" FAIL
    fi
  else
    check "$label (not executable)" FAIL
  fi
}

echo "=== Config-Gate Eval: $TIMESTAMP ($MODE) ===" | tee "$REPORT"
echo "Plugin dir: $PLUGIN_DIR" | tee -a "$REPORT"
cd "$PLUGIN_DIR"

echo "" | tee -a "$REPORT"
echo "▸ Structural checks" | tee -a "$REPORT"

if node -e 'JSON.parse(require("fs").readFileSync("hooks/hooks.json","utf8"))' 2>/dev/null; then
  check "hooks.json is valid JSON" PASS
else
  check "hooks.json is valid JSON" FAIL
fi

if node -e 'JSON.parse(require("fs").readFileSync("config.example.json","utf8"))' 2>/dev/null; then
  check "config.example.json is valid JSON" PASS
else
  check "config.example.json is valid JSON" FAIL
fi

if [ -f "$PLUGIN_DIR/hooks/lib/zensu-config.sh" ]; then
  check "hooks/lib/zensu-config.sh exists" PASS
else
  check "hooks/lib/zensu-config.sh exists" FAIL
fi

if [ -x "$PLUGIN_DIR/hooks/session-start-pulse.sh" ]; then
  check "hooks/session-start-pulse.sh is executable" PASS
else
  check "hooks/session-start-pulse.sh is executable" FAIL
fi

SS_CMD=$(node -e "const j=JSON.parse(require('fs').readFileSync('hooks/hooks.json','utf8'));console.log((j.hooks.SessionStart[0].hooks[0].command)||'')" 2>/dev/null)
case "$SS_CMD" in
  *session-start-pulse.sh*) check "SessionStart hook wired to session-start-pulse.sh" PASS ;;
  *)                         check "SessionStart hook wired to session-start-pulse.sh" FAIL ;;
esac

echo "" | tee -a "$REPORT"
echo "▸ Helper offline tests" | tee -a "$REPORT"

run_test "$EVAL_DIR/test-helper-missing.sh"     "test-helper-missing.sh"
run_test "$EVAL_DIR/test-helper-malformed.sh"   "test-helper-malformed.sh"
run_test "$EVAL_DIR/test-helper-keymissing.sh"  "test-helper-keymissing.sh"
run_test "$EVAL_DIR/test-helper-disabled.sh"    "test-helper-disabled.sh"
run_test "$EVAL_DIR/test-helper-envoverride.sh" "test-helper-envoverride.sh"
run_test "$EVAL_DIR/test-helper-no-node.sh"     "test-helper-no-node.sh"

echo "" | tee -a "$REPORT"
echo "▸ Hook gate offline tests" | tee -a "$REPORT"

run_test "$EVAL_DIR/test-gate-plan.sh"        "test-gate-plan.sh"
run_test "$EVAL_DIR/test-gate-postdd.sh"      "test-gate-postdd.sh"
run_test "$EVAL_DIR/test-gate-postreview.sh"  "test-gate-postreview.sh"
run_test "$EVAL_DIR/test-gate-session.sh"     "test-gate-session.sh"
run_test "$EVAL_DIR/test-isolation-preserved.sh" "test-isolation-preserved.sh"
run_test "$EVAL_DIR/test-no-pluginroot-env.sh"   "test-no-pluginroot-env.sh"
run_test "$EVAL_DIR/test-pluginroot-default-setu.sh" "test-pluginroot-default-setu.sh"

if [ "$MODE" = "--self-check" ]; then
  echo "" | tee -a "$REPORT"
  echo "════════════════════════════════════════" | tee -a "$REPORT"
  echo "  SELF-CHECK: $PASS_COUNT/$TOTAL PASS ($FAIL_COUNT FAIL)" | tee -a "$REPORT"
  echo "  E2E (test-e2e-*.exp) skipped — run without --self-check for full suite" | tee -a "$REPORT"
  echo "  Report: $REPORT" | tee -a "$REPORT"
  echo "════════════════════════════════════════" | tee -a "$REPORT"
  [ "$FAIL_COUNT" -eq 0 ]
  exit $?
fi

echo "" | tee -a "$REPORT"
echo "▸ E2E expect scripts (not executed by default — see SPEC out-of-scope)" | tee -a "$REPORT"
echo "  Available: test-e2e-disabled-tdd.exp, test-e2e-default.exp" | tee -a "$REPORT"
echo "  Run manually: expect ./test-e2e-disabled-tdd.exp <log> <plugin_dir>" | tee -a "$REPORT"

echo "" | tee -a "$REPORT"
echo "════════════════════════════════════════" | tee -a "$REPORT"
echo "  TOTAL: $PASS_COUNT/$TOTAL PASS ($FAIL_COUNT FAIL)" | tee -a "$REPORT"
echo "  Report: $REPORT" | tee -a "$REPORT"
echo "════════════════════════════════════════" | tee -a "$REPORT"

[ "$FAIL_COUNT" -eq 0 ]
