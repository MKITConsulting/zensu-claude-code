#!/bin/bash
# LIVE full /zensu:tdd cycle E2E — drives real `claude --print` through an entire
# feature implementation under the active TDD hooks, then asserts the cycle really
# happened via deterministic post-run state (not just stdout text):
#   - chain-state chainDone=true        (the Stop-hook drove the chain to completion)
#   - FSM history contains RED_FAIL      (test-first actually happened)
#   - FSM history contains GREEN_PASS/IMPL (implementation happened)
#   - `node --test` passes in the fixture (the GREEN is real, not claimed)
#   - witness log recorded a test run    (anti-hallucination trail)
#   - stdout mentions the review stage
#
# This is the HEAVIEST suite: one long agent run (RED->GREEN->review->self-review).
# COSTS API CREDITS and can take several minutes. Build the fixture first with
# ./setup-fixtures.sh. Timeout via ZENSU_TDD_E2E_TIMEOUT (default 600s).
#
# Modes: (full) live run | --offline (re-assert last run's fixture state + capture)
#        | --self-check (skeleton only, no claude, no API).
set -u

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$EVAL_DIR/../.." && pwd)"

FIXTURES_DIR="${FIXTURES_DIR:-$EVAL_DIR/fixtures}"
RESULTS_DIR="${RESULTS_DIR:-$EVAL_DIR/results}"
mkdir -p "$RESULTS_DIR"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$RESULTS_DIR/report-$TIMESTAMP.txt"
TIMEOUT="${ZENSU_TDD_E2E_TIMEOUT:-600}"
FIXTURE="$FIXTURES_DIR/add-feature"

MODE="${1:-full}"
case "$MODE" in
  --self-check|--offline|""|full) ;;
  *) printf "  FAIL  unknown mode '%s'\n" "$MODE" >&2; exit 2 ;;
esac

PASS=0; FAIL=0; TOTAL=0
log() { printf "%s\n" "$1" | tee -a "$REPORT"; }
check() {
  local label="$1" result="$2"
  TOTAL=$((TOTAL+1))
  if [ "$result" = "PASS" ]; then PASS=$((PASS+1)); log "  PASS  $label";
  else FAIL=$((FAIL+1)); log "  FAIL  $label"; fi
}

PROMPT='/zensu:tdd Implement add(a, b) in src/math.js as a CommonJS module (module.exports = { add }) returning a + b. Write the test FIRST in test/math.test.js using node:test and node:assert, run it with "node --test", and follow strict RED -> GREEN. Keep the scope to this one function.'

log "=== Live full /zensu:tdd cycle E2E: $TIMESTAMP ($MODE) ==="
log "Plugin dir: $PLUGIN_DIR"
log "Fixture:    $FIXTURE"

if [ "$MODE" = "--self-check" ]; then
  log ""
  log "  (skeleton only — no claude spawned)"
  log "════════════════════════════════════════"
  log "  TOTAL: 0/0 PASS (0 FAIL)"
  log "════════════════════════════════════════"
  exit 0
fi

if [ ! -d "$FIXTURE/.git" ]; then
  check "fixture present (run ./setup-fixtures.sh first)" FAIL
  log "  TOTAL: $PASS/$TOTAL PASS ($FAIL FAIL)"
  exit 1
fi

CAPTURED="$RESULTS_DIR/add-feature-${TIMESTAMP}.captured.txt"
if [ "$MODE" = "--offline" ]; then
  CAPTURED="$(ls -t "$RESULTS_DIR"/add-feature-*.captured.txt 2>/dev/null | head -1)"
  [ -z "$CAPTURED" ] && { check "prior capture exists (--offline)" FAIL; log "  TOTAL: $PASS/$TOTAL PASS ($FAIL FAIL)"; exit 1; }
  log "Offline: re-asserting against $CAPTURED + current fixture state"
else
  log "Running (timeout ${TIMEOUT}s) — this can take several minutes..."
  ( cd "$FIXTURE" && timeout "$TIMEOUT" claude --print --plugin-dir "$PLUGIN_DIR" --permission-mode bypassPermissions "$PROMPT" ) > "$CAPTURED" 2>&1
  log "Run finished (claude exit via timeout wrapper). Capture: $CAPTURED"
fi

log ""
log "▸ Post-run assertions"

# 1. non-empty capture
[ -s "$CAPTURED" ] && check "1 claude produced output" PASS || check "1 claude produced output (zero-byte capture)" FAIL

# 2. FSM state file exists
STATE="$(ls -t "$FIXTURE"/.zensu/state/tdd-phase-*.json 2>/dev/null | head -1)"
if [ -n "$STATE" ] && [ -f "$STATE" ]; then
  check "2 TDD FSM state file created" PASS
else
  check "2 TDD FSM state file created (none under $FIXTURE/.zensu/state)" FAIL
fi

jq_state() { [ -n "$STATE" ] && node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1]));let v=j;for(const k of process.argv[2].split(".")){v=v&&v[k]}process.stdout.write(String(v))}catch(_){process.stdout.write("")}' "$STATE" "$1" 2>/dev/null; }
hist_has() { [ -n "$STATE" ] && node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1]));const ph=process.argv[2].split("|");process.exit((Array.isArray(j.history)&&j.history.some(h=>h&&ph.includes(h.phase)))?0:1)}catch(_){process.exit(1)}' "$STATE" "$1" 2>/dev/null; }

# 3. chain completed (Stop-hook drove it to the terminus)
[ "$(jq_state chainDone)" = "true" ] && check "3 chain-state chainDone=true (full chain ran to completion)" PASS || check "3 chainDone=true (got: $(jq_state chainDone))" FAIL

# 4. test-first really happened
hist_has "RED_FAIL" && check "4 FSM history contains RED_FAIL (test-first: a failing test preceded impl)" PASS || check "4 FSM history contains RED_FAIL" FAIL

# 5. implementation phase reached
hist_has "GREEN_PASS|IMPL" && check "5 FSM history reached IMPL/GREEN_PASS (implementation happened)" PASS || check "5 FSM history reached IMPL/GREEN_PASS" FAIL

# 6. the GREEN is REAL — run the agent's test against the agent's impl.
# Require exit 0 AND at least one passing test (an empty suite also exits 0).
NT_OUT="$( cd "$FIXTURE" && timeout 60 node --test 2>&1 )"; NT_RC=$?
if [ "$NT_RC" -eq 0 ] && printf '%s' "$NT_OUT" | grep -Eq 'pass[[:space:]]+[1-9]'; then
  check "6 'node --test' passes with >=1 test in the fixture (GREEN is real, not claimed)" PASS
else
  check "6 'node --test' passes with >=1 test (rc=$NT_RC)" FAIL
fi

# 7. witness recorded a test run, with the stdout tail captured. Real Claude Code Bash
#    tool_response has no exit_code (so exit=?), but stdout IS present -> tail= must be non-empty.
WLOG="$(ls -t "$FIXTURE"/.zensu/logs/witness-*.log 2>/dev/null | head -1)"
WT_LINE="$( [ -n "$WLOG" ] && grep -E 'node --test|npm test|node:test' "$WLOG" | head -1 )"
if [ -n "$WT_LINE" ] && printf '%s' "$WT_LINE" | grep -Eq 'tail="[^"]'; then
  check "7 witness log recorded a test run with non-empty tail= (stdout captured under exit=?)" PASS
else
  check "7 witness log recorded a test run with non-empty tail= (anti-hallucination trail) line='${WT_LINE}'" FAIL
fi

# 8. review stage is visible in the transcript
if grep -Eqi 'code.?review|self.?review|reviewer' "$CAPTURED"; then
  check "8 transcript shows the review stage ran" PASS
else
  check "8 transcript shows the review stage ran" FAIL
fi

log ""
log "════════════════════════════════════════"
log "  TOTAL: $PASS/$TOTAL PASS ($FAIL FAIL)"
log "  Report: $REPORT"
log "════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
