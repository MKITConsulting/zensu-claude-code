#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
for variable in CLAUDE_PLUGIN_ROOT PLUGIN_ROOT ZENSU_PLUGIN_ROOT; do
  case "$variable" in
    CLAUDE_PLUGIN_ROOT) value="${CLAUDE_PLUGIN_ROOT:-}" ;;
    PLUGIN_ROOT) value="${PLUGIN_ROOT:-}" ;;
    ZENSU_PLUGIN_ROOT) value="${ZENSU_PLUGIN_ROOT:-}" ;;
  esac
  [ -z "$value" ] && continue
  candidate="$(cd -P -- "$value" 2>/dev/null && pwd -P)" \
    || { echo "zensu: $variable does not identify the executing plugin" >&2; exit 2; }
  [ "$candidate" = "$ROOT" ] \
    || { echo "zensu: $variable does not match the executing plugin" >&2; exit 2; }
done
unset CLAUDE_PLUGIN_ROOT PLUGIN_ROOT ZENSU_PLUGIN_ROOT value candidate variable
cd -P -- "$ROOT"
exec node ./hooks/lib/claude-session-control-v1.js
