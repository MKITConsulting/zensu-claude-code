#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
MODE="${1:-all}"
[ "$#" -le 1 ] || {
  echo 'usage: test-windows-ci-contract.sh [all|metadata|lifecycle]' >&2
  exit 64
}

# The unit files stay spelled out INSIDE each case arm on purpose:
# windows-ci-contract.test.js reads this file and matches `metadata)[\s\S]*
# windows-ci-contract.test.js`, `lifecycle)[\s\S]*profile-runner.test.js` and
# `all)[\s\S]*profile-runner.test.js` — it pins which mode dispatches what. Hoisting
# the lists into arrays breaks that pin, which is how this comment came to exist.
case "$MODE" in
  metadata)
    set -- \
      "$ROOT/tests/structure/deferred-review-claim-cases.test.js" \
      "$ROOT/tests/structure/windows-observation.test.js" \
      "$ROOT/tests/structure/windows-profile-contract.test.js" \
      "$ROOT/tests/structure/windows-ci-contract.test.js" \
      "$ROOT/tests/structure/windows-safety-shard.test.js"
    ;;
  lifecycle)
    set -- "$ROOT/tests/structure/profile-runner.test.js"
    ;;
  all)
    set -- \
      "$ROOT/tests/structure/profile-runner.test.js" \
      "$ROOT/tests/structure/deferred-review-claim-cases.test.js" \
      "$ROOT/tests/structure/windows-observation.test.js" \
      "$ROOT/tests/structure/windows-profile-contract.test.js" \
      "$ROOT/tests/structure/windows-ci-contract.test.js" \
      "$ROOT/tests/structure/windows-safety-shard.test.js"
    ;;
  *)
    echo 'usage: test-windows-ci-contract.sh [all|metadata|lifecycle]' >&2
    exit 64
    ;;
esac

UNIT_MODE="$MODE"
UNIT_RUN_TEE=1
. "$(dirname "$0")/lib-unit-registry.sh"

RC=0
for UNIT in "$@"; do
  unit_run "$UNIT" || RC=1
  printf 'test-windows-ci-contract: %s\n' "$UNIT_RUN_VERDICT"
done
unit_registry_done || RC=1
printf 'test-windows-ci-contract: %s\n' "$UNIT_RUN_VERDICT"
exit "$RC"
