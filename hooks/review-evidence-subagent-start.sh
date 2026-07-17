#!/bin/bash
set -uo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd -P)" || exit 1
POLICY="$ROOT/hooks/lib/review-evidence-hook-v1.js"
[ -f "$POLICY" ] && [ ! -L "$POLICY" ] || exit 1
NODE="$(command -v node 2>/dev/null)" || exit 1
[ -n "$NODE" ] || exit 1
NATIVE_ROOT="$(bash "$ROOT/hooks/lib/zensu-host-path.sh" "$ROOT")" || exit 1
NATIVE_PLUGIN_DATA="$(bash "$ROOT/hooks/lib/zensu-host-path.sh" "${CLAUDE_PLUGIN_DATA:-}")" || exit 1
export CLAUDE_PLUGIN_ROOT="$NATIVE_ROOT" CLAUDE_PLUGIN_DATA="$NATIVE_PLUGIN_DATA"
cd -P -- "$ROOT/hooks/lib" || exit 1
unset ROOT
exec "$NODE" ./review-evidence-hook-v1.js start
