#!/bin/bash
set -euo pipefail

fail() {
  printf '%s\n' "zensu-review-evidence.sh: $1" >&2
  exit 2
}

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." 2>/dev/null && pwd -P)" \
  || fail 'executing plugin root is unavailable'
[ -n "${CLAUDE_PLUGIN_DATA:-}" ] || fail 'CLAUDE_PLUGIN_DATA is required'
[ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || fail 'CLAUDE_CODE_SESSION_ID is required'

if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  DECLARED="$(CDPATH= cd -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" \
    || fail 'CLAUDE_PLUGIN_ROOT does not exist'
  [ "$DECLARED" = "$ROOT" ] || fail 'CLAUDE_PLUGIN_ROOT does not match the executing plugin'
fi

POLICY="$ROOT/hooks/lib/review-evidence-lease-v1.js"
[ -f "$POLICY" ] && [ ! -L "$POLICY" ] || fail 'lease policy is unavailable'
NODE="$(command -v node 2>/dev/null)" || fail 'node is required'
[ -n "$NODE" ] || fail 'node is required'
NATIVE_ROOT="$(bash "$ROOT/hooks/lib/zensu-host-path.sh" "$ROOT")" \
  || fail 'executing plugin root is unavailable to native Node'
NATIVE_PLUGIN_DATA="$(bash "$ROOT/hooks/lib/zensu-host-path.sh" "$CLAUDE_PLUGIN_DATA")" \
  || fail 'CLAUDE_PLUGIN_DATA is unavailable to native Node'

export CLAUDE_PLUGIN_ROOT="$NATIVE_ROOT" CLAUDE_PLUGIN_DATA="$NATIVE_PLUGIN_DATA"
unset PLUGIN_ROOT ZENSU_PLUGIN_ROOT DECLARED NATIVE_ROOT NATIVE_PLUGIN_DATA POLICY
cd -P -- "$ROOT/hooks/lib" || fail 'lease policy directory is unavailable'
unset ROOT
exec "$NODE" ./review-evidence-lease-v1.js "$@"
