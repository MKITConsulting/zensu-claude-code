#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -d "$ROOT/plugins/zensu" ]; then
  CORE="$ROOT/plugins/zensu/hooks/lib/session-control-core-v1.js"
else
  CORE="$ROOT/hooks/lib/session-control-core-v1.js"
fi

# A REGISTRATION FLOOR, because exit 0 alone proves nothing here. MEASURED:
# `node --test` over a file that registers zero tests exits 0, so a runner that
# reads only the status reports a clean pass for a suite that ran nothing - a
# renamed export, a throw at module load swallowed by a top-level guard, or a
# file that stopped being collected all look identical to green. The floor is
# the count the suite registers today; raise it when cases are added. It fires
# on REMOVAL, which is the direction that hides work rather than adding it.
#
# THE FLOOR LIVES HERE rather than in the tests/structure driver on purpose: the
# Windows profiles invoke this script directly, so a floor in the driver alone
# would leave exactly those runs unfloored.
SESSION_CONTROL_FLOOR="${SESSION_CONTROL_FLOOR:-153}"

set +e
OUT="$(SESSION_CONTROL_CORE="$CORE" node --test "$ROOT/tests/session-control/session-control-core-v1.test.js" 2>&1)"
STATUS=$?
set -e
printf '%s\n' "$OUT"

# The reporter prefixes its summary with a non-ASCII marker, so the leading run
# is matched loosely rather than spelled - the digits are what is being read.
PASSED="$(printf '%s\n' "$OUT" | sed -n 's/^[^0-9]*pass \([0-9][0-9]*\)$/\1/p' | tail -1)"
FAILED="$(printf '%s\n' "$OUT" | sed -n 's/^[^0-9]*fail \([0-9][0-9]*\)$/\1/p' | tail -1)"

if [ "$STATUS" -ne 0 ]; then
  printf '%s\n' "session-control: node --test exited $STATUS" >&2
  exit "$STATUS"
fi
if [ -z "$PASSED" ] || [ -z "$FAILED" ]; then
  printf '%s\n' "session-control: could not read the pass/fail summary — the run is NOT an all-clear" >&2
  exit 1
fi
if [ "$FAILED" -ne 0 ]; then
  printf '%s\n' "session-control: $FAILED failing case(s)" >&2
  exit 1
fi
if [ "$PASSED" -lt "$SESSION_CONTROL_FLOOR" ]; then
  printf '%s\n' "session-control: only $PASSED case(s) ran, want at least $SESSION_CONTROL_FLOOR — the suite is not measuring what it claims" >&2
  exit 1
fi
printf '%s\n' "session-control: $PASSED case(s) passed (floor $SESSION_CONTROL_FLOOR)"
