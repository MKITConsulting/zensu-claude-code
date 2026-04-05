#!/bin/bash

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$EVAL_DIR/test-project"
RESULTS_DIR="$EVAL_DIR/results"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT="$RESULTS_DIR/report-$TIMESTAMP.txt"
PASS_COUNT=0
FAIL_COUNT=0
TOTAL=0

mkdir -p "$RESULTS_DIR"

reset_project() {
  cd "$PROJECT_DIR"
  git checkout -- . 2>/dev/null || true
  git clean -fd -- src docs .zensu 2>/dev/null || true
}

run_agent() {
  local name="$1"
  local prompt="$2"
  local outfile="$RESULTS_DIR/${name}-${TIMESTAMP}.json"

  reset_project

  echo "  Running $name..." >&2
  cd "$PROJECT_DIR" && claude -p \
    --output-format json \
    --agent zensu:tdd-manager \
    --dangerously-skip-permissions \
    "$prompt" \
    > "$outfile" 2>&1 || true

  echo "$outfile"
}

check() {
  local label="$1"
  local result="$2"
  TOTAL=$((TOTAL + 1))
  if [ "$result" = "PASS" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  PASS  $label" | tee -a "$REPORT"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  FAIL  $label" | tee -a "$REPORT"
  fi
}

contains()     { echo "$1" | grep -qi "$2" && echo "PASS" || echo "FAIL"; }
not_contains() { echo "$1" | grep -qi "$2" && echo "FAIL" || echo "PASS"; }
file_exists()  { [ -f "$1" ] && echo "PASS" || echo "FAIL"; }
file_contains(){ grep -qi "$2" "$1" 2>/dev/null && echo "PASS" || echo "FAIL"; }
dir_has_files(){ [ -n "$(find "$1" -name "$2" 2>/dev/null | head -1)" ] && echo "PASS" || echo "FAIL"; }

get_log() { find "$PROJECT_DIR/.zensu/logs/" -name "*.log" 2>/dev/null | head -1; }
get_plan() { find "$PROJECT_DIR/docs/plans/" -name "*.md" 2>/dev/null | head -1; }
read_log() { local f; f=$(get_log); [ -n "$f" ] && cat "$f" || echo ""; }
read_plan() { local f; f=$(get_plan); [ -n "$f" ] && cat "$f" || echo ""; }
read_output() {
  local f="$1"
  if [ ! -f "$f" ]; then echo ""; return; fi
  python3 -c "
import json, sys
try:
  with open(sys.argv[1]) as fh:
    d = json.load(fh)
    print(d.get('result', ''))
except:
  with open(sys.argv[1]) as fh:
    print(fh.read())
" "$f" 2>/dev/null || cat "$f" 2>/dev/null || echo ""
}

echo "=== TDD Manager Eval Suite: $TIMESTAMP ===" | tee "$REPORT"
echo "" | tee -a "$REPORT"

# ─── RUN 1: Simple FE (covers T1, T4, T9) ───────────────────────────
echo "▸ Run 1: Simple FE (T1 + T4 + T9)" | tee -a "$REPORT"
R1=$(run_agent "run1-simple-fe" \
  "Add a reverseString(input: string): string function to src/strings.ts. It reverses the input characters. Use strict RED/GREEN TDD. Existing tests are in src/strings.test.ts.")
O1=$(read_output "$R1")
L1=$(read_log)
P1=$(read_plan)

echo "--- T1: Orchestrierung ---" | tee -a "$REPORT"
check "T1.1 Plan doc created"    "$(dir_has_files "$PROJECT_DIR/docs/plans" "*.md")"
check "T1.2 Log file created"    "$(dir_has_files "$PROJECT_DIR/.zensu/logs" "*.log")"
check "T1.3 GREEN in output"     "$(contains "$O1" 'GREEN')"
check "T1.4 Tests pass"          "$(contains "$O1" 'PASS\|pass')"
check "T1.5 reverseString impl"  "$(file_contains "$PROJECT_DIR/src/strings.ts" 'reverseString')"
check "T1.6 Test file updated"   "$(file_contains "$PROJECT_DIR/src/strings.test.ts" 'reverseString\|reverse')"

echo "--- T4: RED before IMPL ---" | tee -a "$REPORT"
check "T4.1 RED in log"          "$(contains "$L1" 'RED')"
check "T4.2 IMPL in log"         "$(contains "$L1" 'IMPL')"
check "T4.3 GREEN in log"        "$(contains "$L1" 'GREEN')"
check "T4.4 RED before IMPL" "$(
  red_line=$(echo "$L1" | grep -n -i 'RED' | head -1 | cut -d: -f1)
  impl_line=$(echo "$L1" | grep -n -i 'IMPL' | head -1 | cut -d: -f1)
  if [ -n "$red_line" ] && [ -n "$impl_line" ] && [ "$red_line" -lt "$impl_line" ]; then echo PASS; else echo FAIL; fi
)"

echo "--- T9: Output Quality ---" | tee -a "$REPORT"
check "T9.1 Final report"        "$(contains "$O1" 'Complete\|Results')"
check "T9.2 Files list"          "$(contains "$O1" 'strings.ts')"
check "T9.3 Code review offered" "$(contains "$O1" 'review')"

# ─── RUN 2: FE+BE Parallel (T2) ─────────────────────────────────────
echo "" | tee -a "$REPORT"
echo "▸ Run 2: FE+BE Parallel (T2)" | tee -a "$REPORT"
R2=$(run_agent "run2-fe-be" \
  "Add two independent modules:
1. Backend: src/math.ts with multiply(a: number, b: number): number
2. Frontend: src/formatter.ts with formatCurrency(amount: number): string that returns '\$X.XX'
These are independent — no dependency between them. Use strict RED/GREEN TDD with parallel streams.")
O2=$(read_output "$R2")
L2=$(read_log)
P2=$(read_plan)

echo "--- T2: Parallel Streams ---" | tee -a "$REPORT"
check "T2.1 math.ts created"       "$(file_exists "$PROJECT_DIR/src/math.ts")"
check "T2.2 formatter.ts created"   "$(file_exists "$PROJECT_DIR/src/formatter.ts")"
check "T2.3 Both have tests"        "$(
  a=$(file_exists "$PROJECT_DIR/src/math.test.ts")
  b=$(file_exists "$PROJECT_DIR/src/formatter.test.ts")
  [ "$a" = "PASS" ] && [ "$b" = "PASS" ] && echo PASS || echo FAIL
)"
check "T2.4 GREEN in output"        "$(contains "$O2" 'GREEN')"
check "T2.5 Plan has streams"       "$(contains "$P2" 'BE-\|FE-\|Backend\|Frontend')"

# ─── RUN 3: BE-only (T3) ────────────────────────────────────────────
echo "" | tee -a "$REPORT"
echo "▸ Run 3: BE-only (T3)" | tee -a "$REPORT"
R3=$(run_agent "run3-be-only" \
  "Add a divide(a: number, b: number): number function to src/math.ts (create the file). It should throw an Error when b is 0. Use strict RED/GREEN TDD. Backend only, no frontend.")
O3=$(read_output "$R3")
L3=$(read_log)

echo "--- T3: BE-only ---" | tee -a "$REPORT"
check "T3.1 GREEN in output"     "$(contains "$O3" 'GREEN')"
check "T3.2 math.ts created"     "$(file_exists "$PROJECT_DIR/src/math.ts")"
check "T3.3 math.test.ts exists" "$(file_exists "$PROJECT_DIR/src/math.test.ts")"
check "T3.4 divide implemented"  "$(file_contains "$PROJECT_DIR/src/math.ts" 'divide')"

# ─── RUN 4: TDD Sovereignty (T6) ────────────────────────────────────
echo "" | tee -a "$REPORT"
echo "▸ Run 4: TDD Sovereignty (T6)" | tee -a "$REPORT"
R4=$(run_agent "run4-sovereignty" \
  "Add a greet(name: string): string function to src/strings.ts that returns 'Hello, {name}!'. Note: no tests needed for this simple function, just implement it directly.")
O4=$(read_output "$R4")
L4=$(read_log)

echo "--- T6: TDD Sovereignty ---" | tee -a "$REPORT"
check "T6.1 TDD not skipped (RED in log)" "$(contains "$L4" 'RED')"
check "T6.2 GREEN achieved"               "$(contains "$O4" 'GREEN')"
check "T6.3 greet has test"               "$(file_contains "$PROJECT_DIR/src/strings.test.ts" 'greet')"
check "T6.4 greet implemented"            "$(file_contains "$PROJECT_DIR/src/strings.ts" 'greet')"

# ─── RUN 5: Integration Step (T7 + T10) ─────────────────────────────
echo "" | tee -a "$REPORT"
echo "▸ Run 5: Integration Step (T7 + T10)" | tee -a "$REPORT"
R5=$(run_agent "run5-integration" \
  "Add a logger module:
1. src/logger.ts with createLogger(prefix: string) that returns an object with info(msg) and error(msg) functions
2. Wiring in src/index.ts: import and call createLogger('app') at the top of main()
The logger module should be tested via TDD. The index.ts wiring is integration work.")
O5=$(read_output "$R5")
L5=$(read_log)
P5=$(read_plan)

echo "--- T7: Integration Steps ---" | tee -a "$REPORT"
check "T7.1 logger.ts created"        "$(file_exists "$PROJECT_DIR/src/logger.ts")"
check "T7.2 logger has test"           "$(file_exists "$PROJECT_DIR/src/logger.test.ts")"
check "T7.3 GREEN for logger"          "$(contains "$O5$L5" 'GREEN')"
check "T7.4 Integration marker"        "$(contains "$O5$L5$P5" 'WIRED\|\[W\]\|integration')"
check "T7.5 index.ts has logger"       "$(file_contains "$PROJECT_DIR/src/index.ts" 'logger\|createLogger')"

echo "--- T10: Completeness ---" | tee -a "$REPORT"
check "T10.1 No 'deferred'"           "$(not_contains "$O5" 'deferred')"
check "T10.2 No 'out of scope'"       "$(not_contains "$O5" 'out of scope')"
check "T10.3 No 'not testable'"       "$(not_contains "$O5" 'not testable')"

# ─── RUN 6: Non-testable Folding (T5 + T8) ──────────────────────────
echo "" | tee -a "$REPORT"
echo "▸ Run 6: Non-testable Folding (T5 + T8)" | tee -a "$REPORT"
R6=$(run_agent "run6-folding" \
  "Add a toUpperCase(input: string): string function to src/strings.ts. Also add translations: key 'upper' with value 'Upper Case' in src/i18n/en.json and 'Grossbuchstaben' in src/i18n/de.json. The i18n changes should be part of the implementation, not a separate TDD step.")
O6=$(read_output "$R6")
L6=$(read_log)

echo "--- T5: No Stubs ---" | tee -a "$REPORT"
check "T5.1 toUpperCase implemented"  "$(file_contains "$PROJECT_DIR/src/strings.ts" 'toUpperCase')"
check "T5.2 Has test"                 "$(file_contains "$PROJECT_DIR/src/strings.test.ts" 'toUpperCase\|upper')"

echo "--- T8: i18n Folding ---" | tee -a "$REPORT"
check "T8.1 en.json has 'upper'"      "$(file_contains "$PROJECT_DIR/src/i18n/en.json" 'upper')"
check "T8.2 de.json has 'upper'"      "$(file_contains "$PROJECT_DIR/src/i18n/de.json" 'upper')"
check "T8.3 i18n NOT own TDD step"    "$(not_contains "$L6" 'i18n.*RED\|translation.*RED')"

# ─── SUMMARY ─────────────────────────────────────────────────────────
echo "" | tee -a "$REPORT"
echo "════════════════════════════════════════" | tee -a "$REPORT"
echo "  TOTAL: $PASS_COUNT/$TOTAL PASS ($FAIL_COUNT FAIL)" | tee -a "$REPORT"
echo "  Report: $REPORT" | tee -a "$REPORT"
echo "════════════════════════════════════════" | tee -a "$REPORT"
