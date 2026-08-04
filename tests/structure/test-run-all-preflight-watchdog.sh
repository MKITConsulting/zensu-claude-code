#!/bin/bash
# tests/run-all.sh must bound every suite and must never hang on one.
#
# Two defects motivated this. (1) `out="$("$@" 2>&1)"` blocks until every writer
# closes the pipe, so a suite that leaves a background child alive stalls the
# whole runner with no indication which suite did it — observed with
# evals/config-gate, whose own runner uses the same construct. (2) GNU `timeout`
# does not exist on macOS, so there was no bound at all: a hang was
# indistinguishable from a slow suite, forever.
#
# The watchdog and the dependency preflight are EXTRACTED from run-all.sh and
# driven against hermetic fixtures, so this suite tests the real code rather
# than pinning its prose.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_ALL="$PLUGIN_DIR/tests/run-all.sh"

# The extracted harness defines its own PASS/FAIL/HANG/BLOCKED counters, so this
# suite keeps its tally under distinct names — sourcing must not reset it.
T_PASS=0; T_FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; T_PASS=$((T_PASS+1));
  else echo "  FAIL  $label"; T_FAIL=$((T_FAIL+1)); fi
}
verdict() { if [ "$1" -eq 0 ]; then echo PASS; else echo FAIL; fi; }

WORK=""
cleanup() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT INT TERM
WORK="$(mktemp -d)" || exit 1
[ -n "$WORK" ] && [ -d "$WORK" ] || exit 1

echo "== Source pins =="
[ -f "$RUN_ALL" ]
check "P1 tests/run-all.sh exists" "$(verdict $?)"
# The construct that caused the stall must be gone from run_suite.
awk '/^run_suite\(\) \{/,/^\}/' "$RUN_ALL" | grep -q 'out="\$("\$@"'
[ $? -ne 0 ]
check "P2 run_suite no longer captures suite output via command substitution" "$(verdict $?)"
grep -q 'SUITE_TIMEOUT="\${ZENSU_SUITE_TIMEOUT:-' "$RUN_ALL"
check "P3 a per-suite timeout exists and is overridable via ZENSU_SUITE_TIMEOUT" "$(verdict $?)"
grep -q 'HANG  \$label' "$RUN_ALL"
check "P4 a hang is reported as HANG, distinct from FAIL" "$(verdict $?)"
grep -q 'npm ci' "$RUN_ALL"
check "P5 the dependency preflight names the command that fixes it" "$(verdict $?)"
grep -q '\[ "\$FAIL" -eq 0 \] && \[ "\$HANG" -eq 0 \] && \[ "\$BLOCKED" -eq 0 \]' "$RUN_ALL"
check "P6 hung or blocked suites keep the run from exiting green" "$(verdict $?)"
# A suite must not inherit the runner's stdin, or it can block on a read.
awk '/^run_suite\(\) \{/,/^\}/' "$RUN_ALL" | grep -q '</dev/null'
check "P7 suites run with stdin closed so none can block on a read" "$(verdict $?)"

echo "== Behaviour: the extracted watchdog against real fixtures =="
# Extract the real function plus the preflight helpers, then drive them with
# stub counters. Testing the shipped code, not a re-implementation.
HARNESS="$WORK/harness.sh"
{
  echo 'PASS=0; FAIL=0; HANG=0; BLOCKED=0'
  echo 'REPORT="$WORK/report.txt"'
  echo 'log() { printf "%s\n" "$1" >> "$REPORT"; }'
  awk '/^SUITE_TIMEOUT=/{print}' "$RUN_ALL"
  awk '/^run_suite\(\) \{/,/^\}/' "$RUN_ALL"
  awk '/^deps_ready\(\)/{print}' "$RUN_ALL"
  awk '/^block_suite\(\) \{/,/^\}/' "$RUN_ALL"
} > "$HARNESS"

grep -q 'run_suite()' "$HARNESS" && grep -q 'block_suite()' "$HARNESS"
check "B0 watchdog + preflight helpers extracted from the shipped runner" "$(verdict $?)"

# Fixture suites.
printf '#!/bin/bash\necho hello\nexit 0\n'                       > "$WORK/ok.sh"
printf '#!/bin/bash\necho nope\nexit 3\n'                        > "$WORK/bad.sh"
printf '#!/bin/bash\necho starting\nsleep 900\n'                 > "$WORK/hang.sh"
# Exits immediately but leaves a child holding the inherited stdout for a long
# time — the exact shape that stalls a command substitution.
printf '#!/bin/bash\necho quick\n( sleep 900 ) &\nexit 0\n'      > "$WORK/lingering.sh"
chmod +x "$WORK"/*.sh

# shellcheck disable=SC1090
WORK="$WORK" SUITE_TIMEOUT=3 . "$HARNESS"
SUITE_TIMEOUT=3

run_suite "ok" bash "$WORK/ok.sh"
{ [ "$PASS" -eq 1 ] && [ "$FAIL" -eq 0 ] && [ "$HANG" -eq 0 ]; }
check "B1 a passing suite still counts as PASS" "$(verdict $?)"

run_suite "bad" bash "$WORK/bad.sh"
{ [ "$FAIL" -eq 1 ] && [ "$HANG" -eq 0 ]; }
check "B2 a failing suite still counts as FAIL, not HANG" "$(verdict $?)"

START="$(date +%s)"
run_suite "lingering" bash "$WORK/lingering.sh"
ELAPSED=$(( $(date +%s) - START ))
{ [ "$PASS" -eq 2 ] && [ "$ELAPSED" -lt 3 ]; }
check "B3 a suite leaving a background child returns immediately (elapsed ${ELAPSED}s) — the stall is gone" "$(verdict $?)"

START="$(date +%s)"
run_suite "hang" bash "$WORK/hang.sh"
ELAPSED=$(( $(date +%s) - START ))
{ [ "$HANG" -eq 1 ] && [ "$ELAPSED" -lt 20 ]; }
check "B4 a hanging suite is killed at the bound and counted as HANG (elapsed ${ELAPSED}s)" "$(verdict $?)"
grep -q "HANG  hang" "$WORK/report.txt"
check "B5 the hang is named in the report with its label" "$(verdict $?)"
# The suite's partial output must survive, or a hang gives no diagnostic at all.
grep -q "starting" "$WORK/report.txt"
check "B6 output produced before the kill is preserved for diagnosis" "$(verdict $?)"

echo "== Behaviour: dependency preflight =="
NODE_DEPS_OK=1
deps_ready
check "D1 deps_ready is true when node_modules is present" "$(verdict $?)"
NODE_DEPS_OK=0
deps_ready
[ $? -ne 0 ]
check "D2 deps_ready is false when node_modules is absent" "$(verdict $?)"
BEFORE="$BLOCKED"
block_suite "some/suite"
{ [ "$BLOCKED" -eq $((BEFORE + 1)) ] && grep -q "BLOCK some/suite" "$WORK/report.txt"; }
check "D3 a blocked suite is counted and reported as BLOCK, never as PASS" "$(verdict $?)"
grep -q "npm ci" "$WORK/report.txt"
check "D4 the BLOCK line carries the actionable command" "$(verdict $?)"

echo "----"
echo "test-run-all-preflight-watchdog: $T_PASS PASS / $T_FAIL FAIL"
[ "$T_FAIL" -eq 0 ]
