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

export CLAUDE_PLUGIN_ROOT="$ROOT"
unset PLUGIN_ROOT ZENSU_PLUGIN_ROOT DECLARED ROOT
exec "$NODE" "$POLICY" "$@"
