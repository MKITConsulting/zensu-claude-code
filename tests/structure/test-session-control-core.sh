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

# A REGISTRATION FLOOR, matching the three sibling unit drivers in
# test-versioned-plugin-upgrade.sh. Without one, exit 0 also accepts a file that
# registers fewer cases than it used to — so an accidentally deleted block of
# tests is indistinguishable from a green run. That is not hypothetical here: the
# workflow-baseline cases (WB1-WB7 plus WB1a and WB5a) are the only UNIT-level
# coverage of the classification truth table, the refusal vocabulary and the
# component the UNSAFE verdict names, and this driver is the one place that could
# catch their removal. Say unit-level: the REPAIR itself is additionally driven end
# to end by test-versioned-plugin-upgrade.sh Part D and by the SessionStart heal in
# test-session-control-claude.sh, so an unqualified "the only coverage anywhere"
# was an overreaching claim in the justification of a real control. Raise the number in the same commit that adds a case — the floor
# fires on REMOVAL only, so adding one can never turn it red on its own.
# shellcheck source=tests/structure/lib-unit-summary.sh
. "$ROOT/tests/structure/lib-unit-summary.sh"

CORE_UNIT_OUT="$(mktemp "${TMPDIR:-/tmp}/zensu-core-unit-XXXXXX")"
bash "$SUITE" >"$CORE_UNIT_OUT" 2>&1
STATUS=$?
cat "$CORE_UNIT_OUT"

if [ "$STATUS" -eq 0 ] && ! unit_cases_registered_floor "$CORE_UNIT_OUT" 146; then
  printf '%s\n' "test-session-control-core: registered ${UNIT_CASES_TESTS:-?} cases, want >= 146" >&2
  STATUS=1
fi
rm -f "$CORE_UNIT_OUT"

if [ "$STATUS" -eq 0 ]; then
  printf '%s\n' '----' 'test-session-control-core: session-control core suite PASS'
else
  printf '%s\n' '----' "test-session-control-core: session-control core suite FAIL (exit $STATUS)"
fi

exit "$STATUS"
