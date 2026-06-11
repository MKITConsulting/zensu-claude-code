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
echo "▸ Log-style offline tests" | tee -a "$REPORT"

run_test "$EVAL_DIR/test-log-style-wall.sh"     "test-log-style-wall.sh"
run_test "$EVAL_DIR/test-log-style-relative.sh" "test-log-style-relative.sh"
run_test "$EVAL_DIR/test-log-style-none.sh"     "test-log-style-none.sh"
run_test "$EVAL_DIR/test-log-style-fallback.sh" "test-log-style-fallback.sh"
run_test "$EVAL_DIR/test-log-style-no-node.sh"  "test-log-style-no-node.sh"
run_test "$EVAL_DIR/test-log-style-negative-delta.sh" "test-log-style-negative-delta.sh"
run_test "$EVAL_DIR/test-log-style-bad-epoch.sh"      "test-log-style-bad-epoch.sh"
run_test "$EVAL_DIR/test-log-style-long-delta.sh"     "test-log-style-long-delta.sh"
run_test "$EVAL_DIR/test-log-style-artifacts.sh"      "test-log-style-artifacts.sh"

echo "" | tee -a "$REPORT"
echo "▸ Hook gate offline tests" | tee -a "$REPORT"

run_test "$EVAL_DIR/test-gate-plan.sh"        "test-gate-plan.sh"
run_test "$EVAL_DIR/test-gate-postreview.sh"  "test-gate-postreview.sh"
run_test "$EVAL_DIR/test-gate-session.sh"     "test-gate-session.sh"
run_test "$EVAL_DIR/test-isolation-preserved.sh" "test-isolation-preserved.sh"
run_test "$EVAL_DIR/test-no-pluginroot-env.sh"   "test-no-pluginroot-env.sh"
run_test "$EVAL_DIR/test-pluginroot-default-setu.sh" "test-pluginroot-default-setu.sh"

echo "" | tee -a "$REPORT"
echo "▸ Config deep-merge offline tests" | tee -a "$REPORT"

run_test "$EVAL_DIR/test-config-merge.sh" "test-config-merge.sh"

echo "" | tee -a "$REPORT"
echo "▸ Auto-fix flag offline tests (Suggestions routing + loop guard)" | tee -a "$REPORT"

run_test "$EVAL_DIR/test-helper-autofix-flags.sh"             "test-helper-autofix-flags.sh"
run_test "$EVAL_DIR/test-autofix-suggestions-on.sh"           "test-autofix-suggestions-on.sh"
run_test "$EVAL_DIR/test-autofix-suggestions-off.sh"          "test-autofix-suggestions-off.sh"
run_test "$EVAL_DIR/test-autofix-rounds-increment.sh"         "test-autofix-rounds-increment.sh"
run_test "$EVAL_DIR/test-autofix-rounds-convergence.sh"       "test-autofix-rounds-convergence.sh"
run_test "$EVAL_DIR/test-autofix-rounds-session-isolation.sh" "test-autofix-rounds-session-isolation.sh"
run_test "$EVAL_DIR/test-autofix-rounds-sanitize.sh"          "test-autofix-rounds-sanitize.sh"
run_test "$EVAL_DIR/test-autofix-rounds-reset-on-fresh-tdd.sh" "test-autofix-rounds-reset-on-fresh-tdd.sh"
run_test "$EVAL_DIR/test-rounds-default-location.sh"          "test-rounds-default-location.sh"
run_test "$EVAL_DIR/test-post-review-combined-summary.sh"     "test-post-review-combined-summary.sh"

echo "" | tee -a "$REPORT"
echo "▸ Pre-Edit TDD-Gate offline tests" | tee -a "$REPORT"

run_test "$EVAL_DIR/test-pre-edit-lib-paths.sh"                "test-pre-edit-lib-paths.sh"
run_test "$EVAL_DIR/test-pre-edit-lib-state.sh"                "test-pre-edit-lib-state.sh"
run_test "$EVAL_DIR/test-pre-edit-isolation.sh"                "test-pre-edit-isolation.sh"
run_test "$EVAL_DIR/test-pre-edit-deny-uninitialized.sh"       "test-pre-edit-deny-uninitialized.sh"
run_test "$EVAL_DIR/test-pre-edit-allow-red-write.sh"          "test-pre-edit-allow-red-write.sh"
run_test "$EVAL_DIR/test-pre-edit-allow-redfail-test-only.sh"  "test-pre-edit-allow-redfail-test-only.sh"
run_test "$EVAL_DIR/test-pre-edit-allow-impl-after-redfail.sh" "test-pre-edit-allow-impl-after-redfail.sh"
run_test "$EVAL_DIR/test-pre-edit-allow-refactor.sh"           "test-pre-edit-allow-refactor.sh"
run_test "$EVAL_DIR/test-pre-edit-deny-greenpass-production.sh" "test-pre-edit-deny-greenpass-production.sh"
run_test "$EVAL_DIR/test-pre-edit-override-env.sh"             "test-pre-edit-override-env.sh"
run_test "$EVAL_DIR/test-pre-edit-log-phase-subcmd.sh"         "test-pre-edit-log-phase-subcmd.sh"
run_test "$EVAL_DIR/test-pre-edit-toplevel-paths.sh"           "test-pre-edit-toplevel-paths.sh"
run_test "$EVAL_DIR/test-pre-edit-basename-boundary.sh"        "test-pre-edit-basename-boundary.sh"
run_test "$EVAL_DIR/test-pre-edit-symlink-reject.sh"           "test-pre-edit-symlink-reject.sh"
run_test "$EVAL_DIR/test-pre-edit-inline-header.sh"            "test-pre-edit-inline-header.sh"
run_test "$EVAL_DIR/test-pre-edit-concurrent-write.sh"         "test-pre-edit-concurrent-write.sh"
run_test "$EVAL_DIR/test-pre-edit-agent-trust.sh"              "test-pre-edit-agent-trust.sh"
run_test "$EVAL_DIR/test-pre-edit-greenpass-tight.sh"          "test-pre-edit-greenpass-tight.sh"
run_test "$EVAL_DIR/test-pre-edit-bash-bypass.sh"              "test-pre-edit-bash-bypass.sh"

echo "" | tee -a "$REPORT"
echo "▸ Documentation coverage tests" | tee -a "$REPORT"

run_test "$EVAL_DIR/test-readme-coverage.sh"             "test-readme-coverage.sh"
run_test "$EVAL_DIR/test-changelog-coverage.sh"          "test-changelog-coverage.sh"
run_test "$EVAL_DIR/test-changelog-round3-accuracy.sh"   "test-changelog-round3-accuracy.sh"

echo "" | tee -a "$REPORT"
echo "▸ Main-thread TDD chain smoke test (0.4.0 migration)" | tee -a "$REPORT"

run_test "$PLUGIN_DIR/tests/structure/test-smoke-main-thread-chain.sh" "test-smoke-main-thread-chain.sh"

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
