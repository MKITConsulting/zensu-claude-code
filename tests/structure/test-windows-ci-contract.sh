#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
node --test \
  "$ROOT/tests/structure/profile-runner.test.js" \
  "$ROOT/tests/structure/deferred-review-claim-cases.test.js" \
  "$ROOT/tests/structure/windows-observation.test.js" \
  "$ROOT/tests/structure/windows-profile-contract.test.js" \
  "$ROOT/tests/structure/windows-ci-contract.test.js"
