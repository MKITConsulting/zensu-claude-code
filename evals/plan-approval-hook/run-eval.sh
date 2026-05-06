#!/bin/bash
# E2E eval for the plan-approval PostToolUse hook on ExitPlanMode.
# Drives an interactive Claude Code session via expect, approves the
# presented plan, then asserts the hook's behavior in the resulting output.

set -u

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$EVAL_DIR/results"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT="$RESULTS_DIR/report-$TIMESTAMP.txt"
mkdir -p "$RESULTS_DIR"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL=0

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }
}
require expect
require claude

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

strip_ansi()   { sed -E "s/\x1b\[[0-9;]*[A-Za-z]//g; s/\[[0-9]+[A-Z]//g; s/\[[?][0-9;]+[hl]//g" "$1"; }
contains()     { strip_ansi "$1" | grep -qiE "$2" && echo PASS || echo FAIL; }
not_contains() { strip_ansi "$1" | grep -qiE "$2" && echo FAIL || echo PASS; }

echo "=== Plan-Approval Hook Eval: $TIMESTAMP ===" | tee "$REPORT"

# Run from plugin root so hooks/hooks.json auto-loads.
cd "$EVAL_DIR/../.."

# ─── Test 1: Doc-only plan → escape-hatch (NO tdd-manager) ──────
echo "" | tee -a "$REPORT"
echo "▸ Test 1: Doc-only plan (escape-hatch path)" | tee -a "$REPORT"
DOC_OUT="$RESULTS_DIR/doc-${TIMESTAMP}.out"
DOC_LOG="$RESULTS_DIR/doc-${TIMESTAMP}.debug.log"
timeout 180 "$EVAL_DIR/test-doc-plan.exp" "$DOC_LOG" > "$DOC_OUT" 2>&1 || true

check "T1.1 Plugin auto-loaded hooks.json"  "$(contains "$DOC_LOG" "Loaded hooks from standard location for plugin zensu")"
check "T1.2 Hook fired on approval"          "$(contains "$DOC_OUT" "PostToolUse:ExitPlanMode|hook ?stopped ?continuation")"
check "T1.3 Escape-hatch invoked"            "$(contains "$DOC_OUT" "doc-only|proceed normally|trivial documentation|without delegating")"
check "T1.4 No tdd-manager spawn"            "$(not_contains "$DOC_LOG" "subagent.*tdd-manager|spawn.*tdd-manager")"

# ─── Test 2: Code-change plan → tdd-manager delegation ──────────
echo "" | tee -a "$REPORT"
echo "▸ Test 2: Code-change plan (delegation path)" | tee -a "$REPORT"
CODE_OUT="$RESULTS_DIR/code-${TIMESTAMP}.out"
CODE_LOG="$RESULTS_DIR/code-${TIMESTAMP}.debug.log"
mkdir -p "$EVAL_DIR/fixtures"
[ -f "$EVAL_DIR/fixtures/sample.ts" ] || echo "export const noop = () => {};" > "$EVAL_DIR/fixtures/sample.ts"
timeout 360 "$EVAL_DIR/test-code-plan.exp" "$CODE_LOG" > "$CODE_OUT" 2>&1 || true

check "T2.1 Plugin auto-loaded hooks.json"   "$(contains "$CODE_LOG" "Loaded hooks from standard location for plugin zensu")"
check "T2.2 Hook fired on approval"           "$(contains "$CODE_OUT" "PostToolUse:ExitPlanMode|hook ?stopped ?continuation|Plan ?was ?just ?approved")"
check "T2.3 Delegation path indicated"        "$(contains "$CODE_OUT" "tdd-manager|RED.*GREEN|delegating")"
check "T2.4 No escape-hatch (code change)"    "$(not_contains "$CODE_OUT" "doc-only|trivial documentation update")"

# Reset fixture so repeat runs are deterministic.
echo "export const noop = () => {};" > "$EVAL_DIR/fixtures/sample.ts"

echo "" | tee -a "$REPORT"
echo "════════════════════════════════════════" | tee -a "$REPORT"
echo "  TOTAL: $PASS_COUNT/$TOTAL PASS ($FAIL_COUNT FAIL)" | tee -a "$REPORT"
echo "  Report: $REPORT" | tee -a "$REPORT"
echo "════════════════════════════════════════" | tee -a "$REPORT"

[ "$FAIL_COUNT" -eq 0 ]
