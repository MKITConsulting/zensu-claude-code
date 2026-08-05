#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
RUN_ALL="$ROOT/tests/run-all.sh"
MANIFEST="$ROOT/tests/profiles/promptfoo-local-only.v1.json"
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

if grep -qF 'OFFLINE_LINES="$(offline_inventory)" || exit 2' "$RUN_ALL" \
  && grep -qF 'done <<< "$OFFLINE_LINES"' "$RUN_ALL" \
  && grep -qF 'run_required_suite "$label" "$runner" bash "$runner" "${suite_args[@]}"' "$RUN_ALL"; then
  check "master runner consumes every classified offline suite fail-closed" PASS
else
  check "manifest-driven required offline suite wiring" FAIL
fi

if node - "$MANIFEST" <<'NODE'
const value = require(process.argv[2]);
const expected = [
  ['evals/config-gate/run-eval.sh', ['--self-check'], ['--self-check'], false],
  ['evals/session-control/run-self-check.sh', [], ['--ci'], true],
  ['evals/tdd-review-chain/run-self-check.sh', [], [], false],
  ['evals/reset-review-limit/run-self-check.sh', [], ['--ci'], true],
  ['evals/tdd-manager-pretool/run-eval.sh', ['--self-check'], ['--self-check'], false],
];
const actual = value.ciOfflineSuites.map(
  ({ path, args, ciArgs, needsNodeDeps }) => [path, args, ciArgs, needsNodeDeps],
);
process.exit(JSON.stringify(actual) === JSON.stringify(expected) ? 0 : 1);
NODE
then
  check "offline suite manifest preserves local and CI arguments" PASS
else
  check "offline suite manifest local/CI argument contract" FAIL
fi

if grep -Eq '^\[ -f "\$(CG|SC|TRC|RRL)" \] && run_suite' "$RUN_ALL"; then
  check "no offline suite is silently skipped when its runner is missing" FAIL
else
  check "no offline suite is silently skipped when its runner is missing" PASS
fi

printf '%s\n' '----'
printf 'test-run-all-required-offline-suites: %s PASS / %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
