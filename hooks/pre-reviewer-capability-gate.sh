#!/bin/bash
set -uo pipefail

fail_closed() {
  printf '%s\n' 'zensu: reviewer capability gate unavailable' >&2
  exit 2
}

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)" || fail_closed
POLICY="$SCRIPT_DIR/lib/reviewer-capability-v1.js"
[ -f "$POLICY" ] || fail_closed
NODE="$(command -v node 2>/dev/null)" || fail_closed
[ -n "$NODE" ] || fail_closed
OUTPUT="$(mktemp "${TMPDIR:-/tmp}/zensu-reviewer-gate.XXXXXX" 2>/dev/null)" || fail_closed
ERROR_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/zensu-reviewer-gate-error.XXXXXX" 2>/dev/null)" || {
  rm -f "$OUTPUT"
  fail_closed
}
chmod 600 "$OUTPUT" "$ERROR_OUTPUT" 2>/dev/null || {
  rm -f "$OUTPUT" "$ERROR_OUTPUT"
  fail_closed
}
trap 'rm -f "$OUTPUT" "$ERROR_OUTPUT"' EXIT HUP INT TERM

"$NODE" "$POLICY" >"$OUTPUT" 2>"$ERROR_OUTPUT"
STATUS=$?
[ "$STATUS" -eq 0 ] || fail_closed
cat "$OUTPUT" || fail_closed
exit 0
