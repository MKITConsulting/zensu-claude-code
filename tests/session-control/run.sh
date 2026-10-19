#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -d "$ROOT/plugins/zensu" ]; then
  CORE="$ROOT/plugins/zensu/hooks/lib/session-control-core-v1.js"
else
  CORE="$ROOT/hooks/lib/session-control-core-v1.js"
fi

SESSION_CONTROL_TIMEOUT_MS="${SESSION_CONTROL_TIMEOUT_MS:-180000}"
UNIT="$ROOT/tests/session-control/session-control-core-v1.test.js"
. "$ROOT/tests/structure/lib-unit-registry.sh"

LOG="$(mktemp "${TMPDIR:-/tmp}/zensu-session-control-log-XXXXXX")"
PROGRESS="$(mktemp "${TMPDIR:-/tmp}/zensu-session-control-progress-XXXXXX")"
trap 'rm -f "$LOG" "$PROGRESS"' EXIT

set +e
SESSION_CONTROL_CORE="$CORE" SESSION_CONTROL_PROGRESS="$PROGRESS" \
  node --test --test-reporter=tap --test-timeout="$SESSION_CONTROL_TIMEOUT_MS" \
  "$UNIT" 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e
IN_FLIGHT="$(tr -d '\r' < "$PROGRESS" | sed -n '$s/^start //p')"

if [ "$STATUS" -ne 0 ] && [ -n "$IN_FLIGHT" ]; then
  printf '%s\n' "session-control: the last test started never finished: $IN_FLIGHT" >&2
fi
GRADED=0
UNIT_RUN_TEE=1 unit_grade "$UNIT" "$LOG" "$STATUS" || GRADED=$?
printf '%s\n' "session-control: $UNIT_RUN_VERDICT"
DONE=0
unit_registry_done || DONE=$?
printf '%s\n' "session-control: $UNIT_RUN_VERDICT"
if [ "$GRADED" -ne 0 ] || [ "$DONE" -ne 0 ]; then
  [ "$STATUS" -eq 0 ] || exit "$STATUS"
  exit 1
fi
