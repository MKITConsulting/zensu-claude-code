#!/bin/bash
set -u

# Driver for tests/session-control/run.sh.
#
# The suite it runs pins the Session Control core: the runtime-lineage predicate,
# the attestation field pair, and every workflow-state transition. Before this
# driver existed it was reachable only through the Windows profiles
# (tests/profiles/windows-ci.v1.json and the two Windows catalogs), because
# tests/run-all.sh collects structure/test-*.sh plus a fixed e2e list and
# tests/session-control/run.sh is in neither. On Linux and macOS the whole suite
# was therefore green by omission — which is how a defect in
# currentClaudeSessionContext reached main with its own test suite never run.
#
# This file exists only to make the tree runner find it. Keep it a driver: the
# assertions belong in session-control-core-v1.test.js, not here.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SUITE="$ROOT/tests/session-control/run.sh"

if [ ! -f "$SUITE" ]; then
  printf '%s\n' 'test-session-control-core: tests/session-control/run.sh is missing' >&2
  exit 1
fi

bash "$SUITE"
STATUS=$?

if [ "$STATUS" -eq 0 ]; then
  printf '%s\n' '----' 'test-session-control-core: session-control core suite PASS'
else
  printf '%s\n' '----' "test-session-control-core: session-control core suite FAIL (exit $STATUS)"
fi

exit "$STATUS"
