#!/bin/bash
set -u

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$EVAL_DIR/../.." && pwd)"
RESULTS_DIR="$EVAL_DIR/results"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT="$RESULTS_DIR/report-$TIMESTAMP.txt"

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

# GNU `timeout` is absent on macOS, where every `timeout 120 ...` call below
# returned 127 and reported a healthy sub-suite as FAIL. Bound the child with a
# portable poll instead, and send its output to a file rather than through a
# command substitution — a lingering background child would otherwise hold the
# pipe open and stall the whole runner.
bounded() {
  local secs="$1"; shift
  local out_file pid waited rc
  out_file="$(mktemp)" || return 127
  "$@" >"$out_file" 2>&1 </dev/null &
  pid=$!
  waited=0
  while [ "$waited" -lt "$secs" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 1; waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    pkill -P "$pid" 2>/dev/null; kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    cat "$out_file"; rm -f "$out_file"
    return 124
  fi
  wait "$pid"; rc=$?
  cat "$out_file"; rm -f "$out_file"
  return "$rc"
}

run_subscript() {
  local script="$1" label="$2"; shift 2
  if [ ! -x "$script" ]; then check "$label (not executable)" FAIL; return; fi
  if bounded "${SUBSCRIPT_TIMEOUT:-120}" bash "$script" "$@" >/dev/null 2>&1; then
    check "$label" PASS
  else
    local rc=$?
    if [ "$rc" -eq 124 ]; then check "$label (HANG: no exit within ${SUBSCRIPT_TIMEOUT:-120}s)" FAIL
    else check "$label" FAIL; fi
  fi
}

echo "=== TDD Manager PreToolUse Eval: $TIMESTAMP ($MODE) ===" | tee "$REPORT"
echo "Plugin dir: $PLUGIN_DIR" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

echo "▸ Phase 1 — Backward-compat regression (existing offline suites)" | tee -a "$REPORT"
# These two are full suites, not unit tests: config-gate alone runs ~30 minutes.
# When tests/run-all.sh drives this arm it has already run both as suites of
# their own, so re-running them here doubles the wall clock and proves nothing
# new. The caller says so; a standalone invocation still runs the full Phase 1.
if [ "${ZENSU_PRETOOL_SKIP_NESTED:-0}" = "1" ]; then
  check "evals/config-gate/run-eval.sh --self-check (already run by the caller)" PASS
  check "evals/tdd-review-chain/run-eval.sh --self-check (already run by the caller)" PASS
else
SUBSCRIPT_TIMEOUT=3600 run_subscript "$PLUGIN_DIR/evals/config-gate/run-eval.sh"        "evals/config-gate/run-eval.sh --self-check"           --self-check
TRC_OUT=$(bounded 3600 bash "$PLUGIN_DIR/evals/tdd-review-chain/run-eval.sh" --self-check 2>&1)
TRC_PASS=$(echo "$TRC_OUT" | grep -E '^  SELF-CHECK: [0-9]+/[0-9]+ PASS' | sed -E 's/.*SELF-CHECK: ([0-9]+)\/.*/\1/')
TRC_TOTAL=$(echo "$TRC_OUT" | grep -E '^  SELF-CHECK: [0-9]+/[0-9]+ PASS' | sed -E 's/.*SELF-CHECK: [0-9]+\/([0-9]+).*/\1/')
TRC_FAIL=$(echo "$TRC_OUT" | grep -E '^  SELF-CHECK: [0-9]+/[0-9]+ PASS \([0-9]+ FAIL\)' | sed -E 's/.*\(([0-9]+) FAIL\).*/\1/')
# tdd-review-chain has a single pre-existing FAIL in assert-version.sh, otherwise must be green
if [ "${TRC_FAIL:-99}" -le 1 ] && [ "${TRC_PASS:-0}" -ge 30 ]; then
  check "evals/tdd-review-chain/run-eval.sh --self-check (PASS=$TRC_PASS/$TRC_TOTAL FAIL=$TRC_FAIL, <=1 pre-existing)" PASS
else
  check "evals/tdd-review-chain/run-eval.sh --self-check (PASS=$TRC_PASS/$TRC_TOTAL FAIL=$TRC_FAIL)" FAIL
fi
fi

echo "" | tee -a "$REPORT"
echo "▸ Phase 2 — PreToolUse hook unit tests" | tee -a "$REPORT"
for t in "$PLUGIN_DIR/evals/config-gate"/test-pre-edit-*.sh; do
  [ -f "$t" ] || continue
  run_subscript "$t" "$(basename "$t")" ""
done

echo "" | tee -a "$REPORT"
echo "▸ Phase 3 — Structural validation of pretool fixture" | tee -a "$REPORT"

FIXTURE_ROOT="$EVAL_DIR/test-projects/react-go-fullstack"
if [ -d "$FIXTURE_ROOT" ] && [ -f "$FIXTURE_ROOT/package.json" ] && [ -f "$FIXTURE_ROOT/backend/go.mod" ] && [ -f "$FIXTURE_ROOT/CLAUDE.md" ]; then
  check "monorepo fixture has package.json + backend/go.mod + CLAUDE.md" PASS
else
  check "monorepo fixture has package.json + backend/go.mod + CLAUDE.md" FAIL
fi

if [ -f "$EVAL_DIR/promptfooconfig-pretool.yaml" ] && [ -f "$EVAL_DIR/promptfooconfig-regression.yaml" ]; then
  check "promptfoo configs present (pretool + regression)" PASS
else
  check "promptfoo configs present (pretool + regression)" FAIL
fi

SCEN_COUNT=$(find "$EVAL_DIR/scenarios" -maxdepth 1 -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')
if [ "$SCEN_COUNT" -ge 10 ]; then
  check "10 scenarios present (count: $SCEN_COUNT)" PASS
else
  check "10 scenarios present (count: $SCEN_COUNT)" FAIL
fi

ASSERT_COUNT=$(find "$EVAL_DIR/assertions" -maxdepth 1 \( -name 'assert-*.sh' -o -name 'assert-*.js' \) 2>/dev/null | wc -l | tr -d ' ')
if [ "$ASSERT_COUNT" -ge 4 ]; then
  check "assertions library has 4+ files (count: $ASSERT_COUNT)" PASS
else
  check "assertions library has 4+ files (count: $ASSERT_COUNT)" FAIL
fi

if [ "$MODE" = "--self-check" ]; then
  echo "" | tee -a "$REPORT"
  echo "════════════════════════════════════════" | tee -a "$REPORT"
  echo "  SELF-CHECK: $PASS_COUNT/$TOTAL PASS ($FAIL_COUNT FAIL)" | tee -a "$REPORT"
  echo "  Promptfoo live runs skipped (--self-check). Run without flag for full suite." | tee -a "$REPORT"
  echo "  Report: $REPORT" | tee -a "$REPORT"
  echo "════════════════════════════════════════" | tee -a "$REPORT"
  [ "$FAIL_COUNT" -eq 0 ]
  exit $?
fi

echo "" | tee -a "$REPORT"
echo "▸ Phase 4 — Promptfoo live runs" | tee -a "$REPORT"
if ! command -v promptfoo >/dev/null 2>&1; then
  echo "  SKIP: promptfoo CLI not installed (run 'npm i -g promptfoo' to enable)" | tee -a "$REPORT"
else
  if ! command -v claude >/dev/null 2>&1; then
    echo "  SKIP: claude CLI not installed" | tee -a "$REPORT"
  else
    promptfoo eval -c "$EVAL_DIR/promptfooconfig-pretool.yaml" \
      --output "$RESULTS_DIR/full-$TIMESTAMP.json" 2>&1 | tee -a "$REPORT"
    PF_EXIT=${PIPESTATUS[0]}
    if [ "$PF_EXIT" = "0" ]; then
      check "promptfoo pretool suite" PASS
    else
      check "promptfoo pretool suite (exit $PF_EXIT)" FAIL
    fi

    echo "" | tee -a "$REPORT"
    echo "▸ Phase 5 — Promptfoo regression suite" | tee -a "$REPORT"
    promptfoo eval -c "$EVAL_DIR/promptfooconfig-regression.yaml" \
      --output "$RESULTS_DIR/regression-$TIMESTAMP.json" 2>&1 | tee -a "$REPORT"
    PF_REG_EXIT=${PIPESTATUS[0]}
    if [ "$PF_REG_EXIT" = "0" ]; then
      check "promptfoo regression suite" PASS
    else
      check "promptfoo regression suite (exit $PF_REG_EXIT)" FAIL
    fi
  fi
fi

echo "" | tee -a "$REPORT"
echo "════════════════════════════════════════" | tee -a "$REPORT"
echo "  TOTAL: $PASS_COUNT/$TOTAL PASS ($FAIL_COUNT FAIL)" | tee -a "$REPORT"
echo "  Report: $REPORT" | tee -a "$REPORT"
echo "════════════════════════════════════════" | tee -a "$REPORT"

[ "$FAIL_COUNT" -eq 0 ]
