#!/bin/bash
set -u

INPUT=""
IFS= read -r -d '' INPUT || true

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd -P)" || exit 0
POLICY="$ROOT/hooks/lib/review-consume-v1.js"
[ -f "$POLICY" ] && [ ! -L "$POLICY" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0
[ -n "$INPUT" ] || exit 0
case "$INPUT" in
  *'"zensu:code-reviewer"'*) ;;
  *) exit 0 ;;
esac

NATIVE_ROOT="$(bash "$ROOT/hooks/lib/zensu-host-path.sh" "$ROOT" 2>/dev/null)" || exit 0
NATIVE_PLUGIN_DATA="$(bash "$ROOT/hooks/lib/zensu-host-path.sh" "${CLAUDE_PLUGIN_DATA:-}" 2>/dev/null)" || exit 0
[ -n "$NATIVE_PLUGIN_DATA" ] || exit 0
cd -P -- "$ROOT/hooks/lib" 2>/dev/null || exit 0
printf '%s' "$INPUT" | CLAUDE_PLUGIN_ROOT="$NATIVE_ROOT" CLAUDE_PLUGIN_DATA="$NATIVE_PLUGIN_DATA" \
  node ./review-consume-v1.js stop >/dev/null
exit 0
