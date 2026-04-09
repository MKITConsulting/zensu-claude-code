#!/bin/bash

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$EVAL_DIR/test-project"
RESULTS_DIR="$EVAL_DIR/results/${RESULTS_SUBDIR:-}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT="$RESULTS_DIR/report-$TIMESTAMP.txt"
PASS_COUNT=0
FAIL_COUNT=0
TOTAL=0

mkdir -p "$RESULTS_DIR"
export RESULTS_DIR

reset_project() {
  cd "$PROJECT_DIR"
  rm -rf .zensu/logs/ docs/plans/
  git checkout -- . 2>/dev/null || true
  git clean -fd -- src >/dev/null 2>&1 || true
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
    > "$outfile" 2>"${outfile%.json}.stderr" || true
  echo "$outfile"
}

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

file_exists()       { [ -f "$1" ] && echo "PASS" || echo "FAIL"; }
file_contains()     { grep -qi "$2" "$1" 2>/dev/null && echo "PASS" || echo "FAIL"; }
file_not_contains() { grep -qi "$2" "$1" 2>/dev/null && echo "FAIL" || echo "PASS"; }
dir_has_files()     { [ -n "$(find "$1" -name "$2" 2>/dev/null | head -1)" ] && echo "PASS" || echo "FAIL"; }
get_log()           { find "$PROJECT_DIR/.zensu/logs/" -name "*.log" 2>/dev/null | head -1; }
get_plan()          { find "$PROJECT_DIR/docs/plans/" -name "*.md" 2>/dev/null | head -1; }

save_log() {
  local run_name="$1" logfile
  logfile=$(get_log)
  if [ -n "$logfile" ]; then
    cp "$logfile" "$RESULTS_DIR/${run_name}-log-${TIMESTAMP}.txt"
    echo "$RESULTS_DIR/${run_name}-log-${TIMESTAMP}.txt"
  else
    echo ""
  fi
}

ai_eval() {
  local run_name="$1" spec="$2"
  local outfile="$RESULTS_DIR/${run_name}-ai-eval-${TIMESTAMP}.json"
  local logfile testfiles implfiles planfile
  logfile=$(get_log)
  planfile=$(get_plan)
  testfiles=$(find "$PROJECT_DIR/src" -name "*.test.ts" 2>/dev/null | tr '\n' ' ')
  implfiles=$(find "$PROJECT_DIR/src" \( -name "*.ts" ! -name "*.test.ts" -o -name "*.json" \) 2>/dev/null | tr '\n' ' ')

  local file_list=""
  for f in $testfiles $implfiles; do
    file_list="$file_list
--- $(basename "$f") ---
$(cat "$f" 2>/dev/null)"
  done

  local log_content=""
  [ -n "$logfile" ] && log_content=$(cat "$logfile" 2>/dev/null)

  local prompt="You are a TDD quality auditor. Answer EXACTLY in this format — one line per field, nothing else:

test_is_genuine_red: true/false
implementation_is_real: true/false
test_assertions_specific: true/false
tdd_order_correct: true/false
all_spec_items_implemented: true/false
verdict: PASS/FAIL
issues: comma-separated list or 'none'

SPEC: $spec

SOURCE FILES:
$file_list

PROGRESS LOG:
$log_content

Evaluate:
- test_is_genuine_red: Tests assert ACTUAL behavior needing real implementation? (not just 'function exists')
- implementation_is_real: Code is real and functional? (not stubs like 'return true')
- test_assertions_specific: Tests use toBe/toEqual/toThrow with CONCRETE values?
- tdd_order_correct: Log shows RED before IMPL? Test not modified after implementation?
- all_spec_items_implemented: Everything from spec present in code?"

  echo "$prompt" > "${outfile%.json}.prompt.txt"

  cd "$PROJECT_DIR" && claude -p \
    --output-format json \
    --model sonnet \
    --dangerously-skip-permissions \
    "$prompt" \
    > "$outfile" 2>"${outfile%.json}.stderr" || true

  local result
  result=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('result', ''))
except:
    print(open(sys.argv[1]).read())
" "$outfile" 2>/dev/null || echo "")

  echo "--- AI Eval: $run_name ---" | tee -a "$REPORT"
  for field in test_is_genuine_red implementation_is_real test_assertions_specific tdd_order_correct all_spec_items_implemented; do
    val=$(echo "$result" | grep -i "$field" | grep -qi "true" && echo "PASS" || echo "FAIL")
    check "AI:$field" "$val"
  done
  local verdict
  verdict=$(echo "$result" | grep -i "^verdict" | grep -qi "PASS" && echo "PASS" || echo "FAIL")
  check "AI:verdict" "$verdict"
  local issues
  issues=$(echo "$result" | grep -i "^issues" | sed 's/^issues: *//' || echo "parse error")
  echo "  Issues: ${issues:-none}" | tee -a "$REPORT"
}

tests_pass() {
  cd "$PROJECT_DIR" && npm test 2>&1 | grep -qi "Tests.*passed\|passed" && echo "PASS" || echo "FAIL"
}

tests_have_assertions() {
  local testfile="$1"
  [ ! -f "$testfile" ] && echo "FAIL" && return
  grep -qE 'expect\(|assert\(|toBe\(|toEqual\(|toThrow\(|toContain\(' "$testfile" 2>/dev/null && echo "PASS" || echo "FAIL"
}

test_not_modified_after_impl() {
  local logfile="$1"
  [ -z "$logfile" ] && echo "FAIL" && return
  # FAIL if a RED entry appears AFTER a GREEN entry for the same step (= test rewritten post-verification)
  local green_line red_after
  green_line=$(grep -n -i 'GREEN' "$logfile" 2>/dev/null | head -1 | cut -d: -f1)
  [ -z "$green_line" ] && echo "PASS" && return
  if tail -n +"$green_line" "$logfile" 2>/dev/null | grep -qiE '\bRED\b'; then
    echo "FAIL"
  else
    echo "PASS"
  fi
}

echo "=== TDD Manager Eval Suite: $TIMESTAMP ===" | tee "$REPORT"
echo "" | tee -a "$REPORT"

# ─── RUN 1: Simple FE (T1 + T4 + T9) ───────────────────────────
echo "▸ Run 1: Simple FE (T1 + T4 + T9)" | tee -a "$REPORT"
R1=$(run_agent "run1-simple-fe" \
  "Add a reverseString(input: string): string function to src/strings.ts. It reverses the input characters. Use strict RED/GREEN TDD. Existing tests are in src/strings.test.ts.")
LOG1=$(save_log "run1")

echo "--- T1: Orchestrierung ---" | tee -a "$REPORT"
check "T1.1 Plan doc created"    "$(dir_has_files "$PROJECT_DIR/docs/plans" "*.md")"
check "T1.2 Log file created"    "$(dir_has_files "$PROJECT_DIR/.zensu/logs" "*.log")"
check "T1.3 GREEN in output"     "$(file_contains "$R1" 'GREEN')"
check "T1.4 Tests pass"          "$(file_contains "$R1" 'pass')"
check "T1.5 reverseString impl"  "$(file_contains "$PROJECT_DIR/src/strings.ts" 'reverseString')"
check "T1.6 Test file updated"   "$(file_contains "$PROJECT_DIR/src/strings.test.ts" 'reverse')"

echo "--- T4: RED before IMPL ---" | tee -a "$REPORT"
check "T4.1 RED in log"          "$([ -n "$LOG1" ] && file_contains "$LOG1" 'RED' || echo FAIL)"
check "T4.2 IMPL in log"         "$([ -n "$LOG1" ] && file_contains "$LOG1" 'IMPL' || echo FAIL)"
check "T4.3 GREEN in log"        "$([ -n "$LOG1" ] && file_contains "$LOG1" 'GREEN' || echo FAIL)"
check "T4.4 RED before IMPL"     "$(
  [ -z "$LOG1" ] && echo FAIL && exit
  red_line=$(grep -n -i 'RED' "$LOG1" | head -1 | cut -d: -f1)
  impl_line=$(grep -n -i 'IMPL' "$LOG1" | head -1 | cut -d: -f1)
  [ -n "$red_line" ] && [ -n "$impl_line" ] && [ "$red_line" -lt "$impl_line" ] && echo PASS || echo FAIL
)"

echo "--- T9: Output Quality ---" | tee -a "$REPORT"
check "T9.1 Final report"        "$(file_contains "$R1" 'Complete')"
check "T9.2 Files list"          "$(file_contains "$R1" 'strings.ts')"
check "T9.3 Code review offered" "$(file_contains "$R1" 'review')"

echo "--- T11: Test Quality (Run 1) ---" | tee -a "$REPORT"
check "T11.1 npm test passes"              "$(tests_pass)"
check "T11.2 Tests have real assertions"   "$(tests_have_assertions "$PROJECT_DIR/src/strings.test.ts")"
check "T11.3 No RED after GREEN (test not rewritten)" "$(test_not_modified_after_impl "$LOG1")"

ai_eval "run1" "Add reverseString(input: string): string to src/strings.ts that reverses characters"

# ─── RUN 2: FE+BE Parallel (T2) ─────────────────────────────────
echo "" | tee -a "$REPORT"
echo "▸ Run 2: FE+BE Parallel (T2)" | tee -a "$REPORT"
R2=$(run_agent "run2-fe-be" \
  "Add two independent modules:
1. Backend: src/math.ts with multiply(a: number, b: number): number
2. Frontend: src/formatter.ts with formatCurrency(amount: number): string that returns '\$X.XX'
These are independent — no dependency between them. Use strict RED/GREEN TDD with parallel streams.")
PLAN2=$(get_plan); [ -n "$PLAN2" ] && cp "$PLAN2" "$RESULTS_DIR/run2-plan-${TIMESTAMP}.md"
PLAN2="$RESULTS_DIR/run2-plan-${TIMESTAMP}.md"

echo "--- T2: Parallel Streams ---" | tee -a "$REPORT"
check "T2.1 math.ts created"     "$(file_exists "$PROJECT_DIR/src/math.ts")"
check "T2.2 formatter.ts created" "$(file_exists "$PROJECT_DIR/src/formatter.ts")"
check "T2.3 Both have tests"     "$(
  a=$(file_exists "$PROJECT_DIR/src/math.test.ts")
  b=$(file_exists "$PROJECT_DIR/src/formatter.test.ts")
  [ "$a" = "PASS" ] && [ "$b" = "PASS" ] && echo PASS || echo FAIL
)"
check "T2.4 GREEN in output"     "$(file_contains "$R2" 'GREEN')"
check "T2.5 Plan has streams"    "$([ -n "$PLAN2" ] && file_contains "$PLAN2" 'Backend\|Frontend\|BE-\|FE-' || echo FAIL)"

echo "--- TQ: Test Quality (Run 2) ---" | tee -a "$REPORT"
check "TQ2.1 npm test passes"             "$(tests_pass)"
check "TQ2.2 math tests have assertions"  "$(tests_have_assertions "$PROJECT_DIR/src/math.test.ts")"
check "TQ2.3 formatter tests have assertions" "$(tests_have_assertions "$PROJECT_DIR/src/formatter.test.ts")"

ai_eval "run2" "Add multiply(a,b) in math.ts and formatCurrency(amount) in formatter.ts, independent modules"

# ─── RUN 3: BE-only (T3) ────────────────────────────────────────
echo "" | tee -a "$REPORT"
echo "▸ Run 3: BE-only (T3)" | tee -a "$REPORT"
R3=$(run_agent "run3-be-only" \
  "Add a divide(a: number, b: number): number function to src/math.ts (create the file). It should throw an Error when b is 0. Use strict RED/GREEN TDD. Backend only, no frontend.")

echo "--- T3: BE-only ---" | tee -a "$REPORT"
check "T3.1 GREEN in output"     "$(file_contains "$R3" 'GREEN')"
check "T3.2 math.ts created"     "$(file_exists "$PROJECT_DIR/src/math.ts")"
check "T3.3 math.test.ts exists" "$(file_exists "$PROJECT_DIR/src/math.test.ts")"
check "T3.4 divide implemented"  "$(file_contains "$PROJECT_DIR/src/math.ts" 'divide')"

echo "--- TQ: Test Quality (Run 3) ---" | tee -a "$REPORT"
check "TQ3.1 npm test passes"             "$(tests_pass)"
check "TQ3.2 divide test has assertions"  "$(tests_have_assertions "$PROJECT_DIR/src/math.test.ts")"

ai_eval "run3" "Add divide(a,b) to math.ts that throws Error when b is 0"

# ─── RUN 4: TDD Sovereignty (T6) ────────────────────────────────
echo "" | tee -a "$REPORT"
echo "▸ Run 4: TDD Sovereignty (T6)" | tee -a "$REPORT"
R4=$(run_agent "run4-sovereignty" \
  "Add a greet(name: string): string function to src/strings.ts that returns 'Hello, {name}!'. Note: no tests needed for this simple function, just implement it directly.")
LOG4=$(save_log "run4")

echo "--- T6: TDD Sovereignty ---" | tee -a "$REPORT"
check "T6.1 TDD not skipped"     "$([ -n "$LOG4" ] && file_contains "$LOG4" 'RED' || echo FAIL)"
check "T6.2 GREEN achieved"      "$(file_contains "$R4" 'GREEN')"
check "T6.3 greet has test"      "$(file_contains "$PROJECT_DIR/src/strings.test.ts" 'greet')"
check "T6.4 greet implemented"   "$(file_contains "$PROJECT_DIR/src/strings.ts" 'greet')"

echo "--- TQ: Test Quality (Run 4) ---" | tee -a "$REPORT"
check "TQ4.1 npm test passes"             "$(tests_pass)"
check "TQ4.2 greet test has assertions"   "$(tests_have_assertions "$PROJECT_DIR/src/strings.test.ts")"

ai_eval "run4" "Add greet(name) returning 'Hello, {name}!' — spec said 'no tests needed' but TDD should be enforced"

# ─── RUN 5: Integration Step (T7 + T10) ─────────────────────────
echo "" | tee -a "$REPORT"
echo "▸ Run 5: Integration Step (T7 + T10)" | tee -a "$REPORT"
R5=$(run_agent "run5-integration" \
  "Add a logger module:
1. src/logger.ts with createLogger(prefix: string) that returns an object with info(msg) and error(msg) functions
2. Wiring in src/index.ts: import and call createLogger('app') at the top of main()
The logger module should be tested via TDD. The index.ts wiring is integration work.")
LOG5=$(save_log "run5")
PLAN5=$(get_plan); [ -n "$PLAN5" ] && cp "$PLAN5" "$RESULTS_DIR/run5-plan-${TIMESTAMP}.md"
PLAN5="$RESULTS_DIR/run5-plan-${TIMESTAMP}.md"

echo "--- T7: Integration Steps ---" | tee -a "$REPORT"
check "T7.1 logger.ts created"   "$(file_exists "$PROJECT_DIR/src/logger.ts")"
check "T7.2 logger has test"     "$(file_exists "$PROJECT_DIR/src/logger.test.ts")"
check "T7.3 GREEN for logger"    "$(file_contains "$R5" 'GREEN')"
check "T7.4 Integration marker"  "$(
  a=$(file_contains "$R5" 'WIRED\|integration\|\[W\]')
  b=$([ -n "$LOG5" ] && file_contains "$LOG5" 'WIRED\|integration' || echo FAIL)
  c=$([ -n "$PLAN5" ] && file_contains "$PLAN5" 'WIRED\|integration\|\[W\]' || echo FAIL)
  [ "$a" = "PASS" ] || [ "$b" = "PASS" ] || [ "$c" = "PASS" ] && echo PASS || echo FAIL
)"
check "T7.5 index.ts has logger" "$(file_contains "$PROJECT_DIR/src/index.ts" 'logger')"

echo "--- T10: Completeness ---" | tee -a "$REPORT"
check "T10.1 No 'deferred'"      "$(file_not_contains "$R5" 'deferred')"
check "T10.2 No 'out of scope'"  "$(file_not_contains "$R5" 'out of scope')"
check "T10.3 No 'not testable'"  "$(file_not_contains "$R5" 'not testable')"

echo "--- TQ: Test Quality (Run 5) ---" | tee -a "$REPORT"
check "TQ5.1 npm test passes"             "$(tests_pass)"
check "TQ5.2 logger test has assertions"  "$(tests_have_assertions "$PROJECT_DIR/src/logger.test.ts")"

ai_eval "run5" "Add createLogger(prefix) module with info/error methods + wiring in index.ts main()"

# ─── RUN 6: Non-testable Folding (T5 + T8) ──────────────────────
echo "" | tee -a "$REPORT"
echo "▸ Run 6: Non-testable Folding (T5 + T8)" | tee -a "$REPORT"
R6=$(run_agent "run6-folding" \
  "Add a toUpperCase(input: string): string function to src/strings.ts. Also add translations: key 'upper' with value 'Upper Case' in src/i18n/en.json and 'Grossbuchstaben' in src/i18n/de.json. The i18n changes should be part of the implementation, not a separate TDD step.")
LOG6=$(save_log "run6")

echo "--- T5: No Stubs ---" | tee -a "$REPORT"
check "T5.1 toUpperCase implemented" "$(file_contains "$PROJECT_DIR/src/strings.ts" 'toUpperCase')"
check "T5.2 Has test"                "$(file_contains "$PROJECT_DIR/src/strings.test.ts" 'toUpperCase')"

echo "--- T8: i18n Folding ---" | tee -a "$REPORT"
check "T8.1 en.json has 'upper'"     "$(file_contains "$PROJECT_DIR/src/i18n/en.json" 'upper')"
check "T8.2 de.json has 'upper'"     "$(file_contains "$PROJECT_DIR/src/i18n/de.json" 'upper')"
check "T8.3 i18n NOT own TDD step"   "$([ -n "$LOG6" ] && grep -qiE 'i18n.*RED|translation.*RED' "$LOG6" 2>/dev/null && echo FAIL || echo PASS)"

echo "--- TQ: Test Quality (Run 6) ---" | tee -a "$REPORT"
check "TQ6.1 npm test passes"             "$(tests_pass)"
check "TQ6.2 toUpperCase test has assertions" "$(tests_have_assertions "$PROJECT_DIR/src/strings.test.ts")"

ai_eval "run6" "Add toUpperCase(input) to strings.ts + i18n key 'upper' in en.json and de.json"

# ─── TOKEN USAGE & COST SUMMARY ──────────────────────────────────
echo "" | tee -a "$REPORT"
echo "── Token Usage & Cost ──" | tee -a "$REPORT"
python3 -c "
import json, glob, os
results_dir = os.environ.get('RESULTS_DIR', '.')
runs = sorted(glob.glob(os.path.join(results_dir, 'run[1-6]-*-*.json')))
runs = [r for r in runs if 'ai-eval' not in r]
total_cost = 0; total_turns = 0; total_duration = 0; total_output = 0; total_cache_read = 0
print(f'  {\"Run\":<28} {\"Turns\":>5} {\"Duration\":>8} {\"Cost\":>7} {\"Output\":>8} {\"Cache Read\":>11}')
print(f'  {\"─\"*28} {\"─\"*5} {\"─\"*8} {\"─\"*7} {\"─\"*8} {\"─\"*11}')
for f in runs:
    d = json.load(open(f))
    name = os.path.basename(f).rsplit('-2026', 1)[0]
    mu = d.get('modelUsage', {})
    out_tok = sum(s.get('outputTokens', 0) for s in mu.values())
    cache_r = sum(s.get('cacheReadInputTokens', 0) for s in mu.values())
    cost = d.get('total_cost_usd', 0)
    turns = d.get('num_turns', 0)
    dur = d.get('duration_ms', 0) / 1000
    total_cost += cost; total_turns += turns; total_duration += dur
    total_output += out_tok; total_cache_read += cache_r
    print(f'  {name:<28} {turns:>5} {dur:>7.0f}s {\"$\"+f\"{cost:.2f}\":>7} {out_tok:>8,} {cache_r:>11,}')
print(f'  {\"─\"*28} {\"─\"*5} {\"─\"*8} {\"─\"*7} {\"─\"*8} {\"─\"*11}')
print(f'  {\"TOTAL\":<28} {total_turns:>5} {total_duration:>7.0f}s {\"$\"+f\"{total_cost:.2f}\":>7} {total_output:>8,} {total_cache_read:>11,}')

# AI judge costs
ai_runs = sorted(glob.glob(os.path.join(results_dir, '*-ai-eval-*.json')))
ai_cost = sum(json.load(open(f)).get('total_cost_usd', 0) for f in ai_runs)
print(f'  AI Judge (6 runs): \${ai_cost:.2f}')
print(f'  Grand Total: \${total_cost + ai_cost:.2f}')
" 2>/dev/null | tee -a "$REPORT"

# ─── SUMMARY ─────────────────────────────────────────────────────
echo "" | tee -a "$REPORT"
echo "════════════════════════════════════════" | tee -a "$REPORT"
echo "  TOTAL: $PASS_COUNT/$TOTAL PASS ($FAIL_COUNT FAIL)" | tee -a "$REPORT"
echo "  Report: $REPORT" | tee -a "$REPORT"
echo "════════════════════════════════════════" | tee -a "$REPORT"
