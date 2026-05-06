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

# Plugin root = parent of evals/. expect scripts pass it as --plugin-dir
# so claude loads our LOCAL hooks/hooks.json instead of the marketplace cache.
PLUGIN_DIR="$(cd "$EVAL_DIR/../.." && pwd)"
echo "Plugin dir: $PLUGIN_DIR" | tee -a "$REPORT"
cd "$PLUGIN_DIR"

# ─── Test 1: Doc-only plan → escape-hatch (NO tdd-manager) ──────
echo "" | tee -a "$REPORT"
echo "▸ Test 1: Doc-only plan (escape-hatch path)" | tee -a "$REPORT"
DOC_OUT="$RESULTS_DIR/doc-${TIMESTAMP}.out"
DOC_LOG="$RESULTS_DIR/doc-${TIMESTAMP}.debug.log"
timeout 180 "$EVAL_DIR/test-doc-plan.exp" "$DOC_LOG" "$PLUGIN_DIR" > "$DOC_OUT" 2>&1 || true

# Deterministic assertions read from the debug log (TUI output is brittle).
# The debug log records "Hooks: Processing prompt hook with prompt: <text>"
# verbatim when a prompt-type hook fires.
check "T1.1 Plugin loaded hooks.json"        "$(contains "$DOC_LOG" "Loaded hooks.*plugin zensu")"
check "T1.2 Hook fired on approval"           "$(contains "$DOC_LOG" "Processing prompt hook.*Plan was just approved")"
check "T1.3 ExitPlanMode tool succeeded"      "$(contains "$DOC_LOG" "tool=ExitPlanMode.*outcome=ok")"
check "T1.4 Escape-hatch path indicated"      "$(contains "$DOC_OUT" "doc-only|pure ?documentation|trivial ?documentation|TDD ?does ?not ?apply|does ?not ?apply|zero ?code ?changes|Exception ?\\(1\\)|without ?delegating|proceed ?normally")"
check "T1.5 No tdd-manager Agent dispatch"    "$(not_contains "$DOC_LOG" "tool=Agent.*tdd-manager|subagent_type.*tdd-manager")"

# ─── Test 2: Code-change plan → tdd-manager delegation ──────────
echo "" | tee -a "$REPORT"
echo "▸ Test 2: Code-change plan (delegation path)" | tee -a "$REPORT"
CODE_OUT="$RESULTS_DIR/code-${TIMESTAMP}.out"
CODE_LOG="$RESULTS_DIR/code-${TIMESTAMP}.debug.log"
mkdir -p "$EVAL_DIR/fixtures"
[ -f "$EVAL_DIR/fixtures/sample.ts" ] || echo "export const noop = () => {};" > "$EVAL_DIR/fixtures/sample.ts"
timeout 360 "$EVAL_DIR/test-code-plan.exp" "$CODE_LOG" "$PLUGIN_DIR" > "$CODE_OUT" 2>&1 || true

check "T2.1 Plugin loaded hooks.json"        "$(contains "$CODE_LOG" "Loaded hooks.*plugin zensu")"
check "T2.2 Hook fired on approval"           "$(contains "$CODE_LOG" "Processing prompt hook.*Plan was just approved")"
check "T2.3 ExitPlanMode tool succeeded"      "$(contains "$CODE_LOG" "tool=ExitPlanMode.*outcome=ok")"
check "T2.4 Delegation path indicated"        "$(contains "$CODE_OUT" "tdd-manager|MANDATORY|delegating")"
check "T2.5 No doc-only escape-hatch"         "$(not_contains "$CODE_OUT" "doc-only|trivial documentation update")"

# Reset fixture so repeat runs are deterministic.
echo "export const noop = () => {};" > "$EVAL_DIR/fixtures/sample.ts"

echo "" | tee -a "$REPORT"
echo "════════════════════════════════════════" | tee -a "$REPORT"
echo "  TOTAL: $PASS_COUNT/$TOTAL PASS ($FAIL_COUNT FAIL)" | tee -a "$REPORT"
echo "  Report: $REPORT" | tee -a "$REPORT"
echo "════════════════════════════════════════" | tee -a "$REPORT"

[ "$FAIL_COUNT" -eq 0 ]
