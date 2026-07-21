#!/bin/bash
set -uo pipefail

fail_closed() {
  printf '%s\n' 'zensu: reviewer capability gate unavailable' >&2
  exit 2
}

fail_closed_after_drain() {
  cat >/dev/null 2>&1 || true
  fail_closed
}

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)" || fail_closed
PLUGIN_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)" || fail_closed
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  DECLARED_PLUGIN_ROOT="$(CDPATH= cd -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" \
    || fail_closed_after_drain
  [ "$DECLARED_PLUGIN_ROOT" = "$PLUGIN_ROOT" ] || fail_closed_after_drain
fi
POLICY="$SCRIPT_DIR/lib/reviewer-capability-v1.js"
[ -f "$POLICY" ] || fail_closed
NODE="$(command -v node 2>/dev/null)" || fail_closed
[ -n "$NODE" ] || fail_closed
NATIVE_PLUGIN_ROOT="$(bash "$SCRIPT_DIR/lib/zensu-host-path.sh" "$PLUGIN_ROOT")" \
  || fail_closed_after_drain
NATIVE_PLUGIN_DATA="$(bash "$SCRIPT_DIR/lib/zensu-host-path.sh" "${CLAUDE_PLUGIN_DATA:-}")" \
  || fail_closed_after_drain
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

(cd -P -- "$SCRIPT_DIR/lib" \
  && CLAUDE_PLUGIN_ROOT="$NATIVE_PLUGIN_ROOT" CLAUDE_PLUGIN_DATA="$NATIVE_PLUGIN_DATA" \
    "$NODE" ./reviewer-capability-v1.js) >"$OUTPUT" 2>"$ERROR_OUTPUT"
STATUS=$?
[ "$STATUS" -eq 0 ] || fail_closed
cat "$OUTPUT" || fail_closed
exit 0
