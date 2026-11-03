#!/bin/bash
set -u

INPUT=""
IFS= read -r -d '' INPUT || true

ROOT="$(case "$0" in (*/*) CDPATH= cd -- "${0%/*}/.." ;; (*) CDPATH= cd -- .. ;; esac 2>/dev/null && pwd -P)" || exit 0
POLICY="$ROOT/hooks/lib/external-review-v1.js"
[ -f "$POLICY" ] && [ ! -L "$POLICY" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0
[ -n "$INPUT" ] || exit 0

CONFIG_LIB="$ROOT/hooks/lib/zensu-config.sh"
if [ -f "$CONFIG_LIB" ] && [ ! -L "$CONFIG_LIB" ]; then
  source "$CONFIG_LIB" 2>/dev/null || exit 0
  zensu_hook_enabled externalReviewImport || exit 0
fi

NATIVE_PLUGIN_DATA="$(bash "$ROOT/hooks/lib/zensu-host-path.sh" "${CLAUDE_PLUGIN_DATA:-}" 2>/dev/null)" || exit 0
[ -n "$NATIVE_PLUGIN_DATA" ] || exit 0
cd -P -- "$ROOT/hooks/lib" 2>/dev/null || exit 0
printf '%s' "$INPUT" | CLAUDE_PLUGIN_DATA="$NATIVE_PLUGIN_DATA" node ./external-review-v1.js record >/dev/null 2>&1
exit 0
