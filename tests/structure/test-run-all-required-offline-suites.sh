#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
RUN_ALL="$ROOT/tests/run-all.sh"
PASS=0
FAIL=0

check() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

grep -qF 'run_required_suite()' "$RUN_ALL" \
  && check "master runner defines a fail-closed required-suite helper" PASS \
  || check "master runner required-suite helper" FAIL

grep -qF 'FAIL=$((FAIL+1)); log "  FAIL  $label — runner missing at $runner"' "$RUN_ALL" \
  && check "missing required runner increments the master failure count" PASS \
  || check "missing required runner must increment the master failure count" FAIL

for call in \
  'run_required_suite "evals/config-gate (--self-check)" "$CG" bash "$CG" --self-check' \
  'run_required_suite "evals/session-control (self-check)" "$SC" bash "$SC"' \
  'run_required_suite "evals/tdd-review-chain (self-check)" "$TRC" bash "$TRC"' \
  'run_required_suite "evals/reset-review-limit (self-check)" "$RRL" bash "$RRL"'; do
  grep -qF "$call" "$RUN_ALL" \
    && check "required offline suite is fail-closed: ${call#*\"}" PASS \
    || check "required offline suite wiring missing: $call" FAIL
done

if grep -Eq '^\[ -f "\$(CG|SC|TRC|RRL)" \] && run_suite' "$RUN_ALL"; then
  check "no offline suite is silently skipped when its runner is missing" FAIL
else
  check "no offline suite is silently skipped when its runner is missing" PASS
fi

printf '%s\n' '----'
printf 'test-run-all-required-offline-suites: %s PASS / %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
