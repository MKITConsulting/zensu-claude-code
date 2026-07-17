#!/bin/bash
set -uo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd -P)" || exit 1
POLICY="$ROOT/hooks/lib/review-evidence-hook-v1.js"
[ -f "$POLICY" ] && [ ! -L "$POLICY" ] || exit 1
NODE="$(command -v node 2>/dev/null)" || exit 1
[ -n "$NODE" ] || exit 1
export CLAUDE_PLUGIN_ROOT="$ROOT"
unset ROOT
exec "$NODE" "$POLICY" start
