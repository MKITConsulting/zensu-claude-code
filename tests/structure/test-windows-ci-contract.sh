#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
MODE="${1:-all}"
[ "$#" -le 1 ] || {
  echo 'usage: test-windows-ci-contract.sh [all|metadata|lifecycle]' >&2
  exit 64
}

# Shared, locale-independent `node --test` summary parse. This file is a thin
# dispatcher with no check() of its own — node's exit status IS its verdict — and
# that status is 0 whether a unit file registered its cases or not, so an emptied,
# renamed or never-collected one would pass silently (an emptied file reports
# `tests 1`, node counting the file itself, and still exits 0). The count is asserted at the exit
# instead, and node's own output is passed through unchanged so the Windows profile
# runner still sees exactly what it saw before.
#
# The unit files stay spelled out INSIDE each case arm on purpose:
# windows-ci-contract.test.js reads this file and matches `metadata)[\s\S]*
# windows-ci-contract.test.js`, `lifecycle)[\s\S]*profile-runner.test.js` and
# `all)[\s\S]*profile-runner.test.js` — it pins which mode dispatches what. Hoisting
# the lists into arrays breaks that pin, which is how this comment came to exist.
. "$(dirname "$0")/lib-unit-summary.sh"

# node's output is TEE'd, not captured: the Windows profile runner reads this log
# while the run is in flight, and swallowing it into a variable until the end would
# have changed what that runner sees. The copy on disk is only what the count is
# read from, and it is removed on exit.
OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/zensu-windows-ci-contract-XXXXXX")"
trap 'rm -f "$OUT_FILE"' EXIT INT TERM HUP

# Floors are the counts each mode registers today, measured rather than guessed:
# lifecycle 23, metadata 42, all 65. They are TOTALS — a case that starts skipping
# itself must lower the floor deliberately, in the commit that introduces the skip.
case "$MODE" in
  metadata)
    FLOOR=42
    node --test \
      "$ROOT/tests/structure/deferred-review-claim-cases.test.js" \
      "$ROOT/tests/structure/windows-observation.test.js" \
      "$ROOT/tests/structure/windows-profile-contract.test.js" \
      "$ROOT/tests/structure/windows-ci-contract.test.js" \
      "$ROOT/tests/structure/windows-safety-shard.test.js" 2>&1 | tee "$OUT_FILE"
    RC=${PIPESTATUS[0]}
    ;;
  lifecycle)
    FLOOR=23
    node --test "$ROOT/tests/structure/profile-runner.test.js" 2>&1 | tee "$OUT_FILE"
    RC=${PIPESTATUS[0]}
    ;;
  all)
    FLOOR=65
    node --test \
      "$ROOT/tests/structure/profile-runner.test.js" \
      "$ROOT/tests/structure/deferred-review-claim-cases.test.js" \
      "$ROOT/tests/structure/windows-observation.test.js" \
      "$ROOT/tests/structure/windows-profile-contract.test.js" \
      "$ROOT/tests/structure/windows-ci-contract.test.js" \
      "$ROOT/tests/structure/windows-safety-shard.test.js" 2>&1 | tee "$OUT_FILE"
    RC=${PIPESTATUS[0]}
    ;;
  *)
    echo 'usage: test-windows-ci-contract.sh [all|metadata|lifecycle]' >&2
    exit 64
    ;;
esac

[ "$RC" -eq 0 ] || exit "$RC"

if ! unit_cases_registered_floor "$OUT_FILE" "$FLOOR"; then
  # Two different faults, distinguished so a triage is not guesswork: a parsed
  # count below the floor means a unit file lost cases; a count of 0 means the
  # summary was never parsed at all, which on a loaded host is usually a truncated
  # or interrupted run rather than a real regression. Both fail — a count assertion
  # that shrugs at an unreadable count is the vacuous pass this exists to remove.
  if [ "${UNIT_CASES_TESTS:-0}" -eq 0 ]; then
    printf 'test-windows-ci-contract: %s mode produced no parsable node --test summary — the run was truncated or the reporter changed\n' "$MODE" >&2
  else
    printf 'test-windows-ci-contract: %s mode registered %s of an expected %s cases (%s) — a unit file was emptied, renamed, or never collected\n' \
      "$MODE" "$UNIT_CASES_TESTS" "$FLOOR" "$(unit_cases_report "$OUT_FILE")" >&2
  fi
  exit 1
fi
