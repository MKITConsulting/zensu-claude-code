#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
MODE="${1:-all}"
[ "$#" -le 1 ] || {
  echo 'usage: test-windows-ci-contract.sh [all|metadata|lifecycle]' >&2
  exit 64
}

case "$MODE" in
  metadata)
    node --test \
      "$ROOT/tests/structure/deferred-review-claim-cases.test.js" \
      "$ROOT/tests/structure/windows-observation.test.js" \
      "$ROOT/tests/structure/windows-profile-contract.test.js" \
      "$ROOT/tests/structure/windows-ci-contract.test.js" \
      "$ROOT/tests/structure/windows-safety-shard.test.js"
    ;;
  lifecycle)
    node --test "$ROOT/tests/structure/profile-runner.test.js"
    ;;
  all)
    node --test \
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
