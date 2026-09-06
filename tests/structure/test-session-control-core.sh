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

# A registered-case FLOOR, not just the exit status. tests/session-control/run.sh is a
# bare `node --test`, and that exits 0 for a file which registers ZERO cases — so a
# suite emptied by a bad glob, a syntax error inside a skipped block, or a rename that
# silently stops matching reports exactly like a green run. Five sibling drivers in this
# tree call `unit_cases_registered_floor` directly and five more reach it through the
# `_text` wrapper — state the base, or the count means nothing. This one carried neither,
# while four new cases
# were being added to the file it runs.
#
# The floor is spelled here rather than derived from the suite's own output, for the
# reason this tree states about every hand-maintained count: a number derived from what
# it is checking agrees with whatever it finds. Raise it deliberately when cases land.
#
# What it is guarding is now two families rather than one, because two branches added
# cases to the same file: the orphaned-project-root cases, and the workflow-baseline
# cases (WB1-WB7 plus WB1a and WB5a), which are the only UNIT-level coverage of the
# classification truth table, the refusal vocabulary and the component the UNSAFE
# verdict names. Say unit-level: the REPAIR itself is additionally driven end to end by
# test-versioned-plugin-upgrade.sh Part D and by the SessionStart heal in
# test-session-control-claude.sh, so an unqualified "the only coverage anywhere" would
# overreach. The floor fires on REMOVAL only, so adding a case can never turn it red on
# its own — raise it in the same commit that adds one.
#
# ONE run of the suite, not two. The other branch put a second `bash "$SUITE"` plus an
# inline floor here while this file already runs it below; keeping both would have
# doubled the suite's wall clock. The block at the bottom is the one that survives
# because it fails CLOSED: it sources the summary helper unconditionally and exits 1
# when the helper is unavailable, where the inline form would have left the floor
# silently unchecked.
SC_FLOOR=153

OUT="$(mktemp "${TMPDIR:-/tmp}/zensu-session-control-core-XXXXXX")" \
  || { printf '%s\n' 'test-session-control-core: cannot create temp file' >&2; exit 1; }
trap 'rm -f "$OUT"' EXIT

bash "$SUITE" 2>&1 | tee "$OUT"
STATUS=${PIPESTATUS[0]}

# Sourced UNCONDITIONALLY and treated as REQUIRED. The first version guarded the source
# with `[ -f ]` and the call with `command -v`, leaving FLOOR_OK=1 when either was
# missing — so a renamed or deleted helper restored exactly the zero-case blindness the
# floor was added to remove, silently, with the driver still printing PASS. A check that
# fails open is not a check. Every sibling driver sources it at top level, where a
# missing helper makes the later call a command-not-found and the row goes red.
SUMMARY_LIB="$ROOT/tests/structure/lib-unit-summary.sh"
# shellcheck source=/dev/null
. "$SUMMARY_LIB" 2>/dev/null || true
if ! command -v unit_cases_registered_floor >/dev/null 2>&1; then
  printf '%s\n' '----' \
    'test-session-control-core: the shared summary parse is unavailable — the case floor did NOT run' >&2
  exit 1
fi
FLOOR_OK=1
unit_cases_registered_floor "$OUT" "$SC_FLOOR" || FLOOR_OK=0

if [ "$STATUS" -eq 0 ] && [ "$FLOOR_OK" = 1 ]; then
  printf '%s\n' '----' 'test-session-control-core: session-control core suite PASS'
elif [ "$STATUS" -eq 0 ]; then
  printf '%s\n' '----' \
    "test-session-control-core: session-control core suite FAIL (exited 0 but registered fewer than $SC_FLOOR cases)"
  STATUS=1
else
  printf '%s\n' '----' "test-session-control-core: session-control core suite FAIL (exit $STATUS)"
fi

exit "$STATUS"
