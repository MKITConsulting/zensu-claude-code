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

OUT="$(mktemp "${TMPDIR:-/tmp}/zensu-session-control-core-XXXXXX")" || {
  printf '%s\n' 'test-session-control-core: cannot create a temp file for the suite output' >&2
  exit 1
}
trap 'rm -f "$OUT"' EXIT INT TERM HUP

bash "$SUITE" 2>&1 | tee "$OUT"
STATUS=${PIPESTATUS[0]}

MISSING=""
tr -d '\r' < "$OUT" | grep -qE '^session-control: tests/session-control/session-control-core-v1\.test\.js: [0-9]+/[0-9]+ passed' \
  || MISSING="$MISSING the graded run of tests/session-control/session-control-core-v1.test.js;"
tr -d '\r' < "$OUT" | grep -qxF 'session-control: tests/session-control/run.sh: every unit file it is registered for was graded' \
  || MISSING="$MISSING the done check of tests/session-control/run.sh;"
if [ "$STATUS" -eq 0 ] && [ -n "$MISSING" ]; then
  printf '%s\n' "test-session-control-core: tests/session-control/run.sh exited 0 without reporting$MISSING" >&2
  STATUS=1
fi

if [ "$STATUS" -eq 0 ]; then
  printf '%s\n' '----' 'test-session-control-core: session-control core suite PASS'
else
  printf '%s\n' '----' "test-session-control-core: session-control core suite FAIL (exit $STATUS)"
fi

exit "$STATUS"
