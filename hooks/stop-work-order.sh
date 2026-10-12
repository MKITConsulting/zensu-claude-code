#!/bin/bash
set -u

INPUT=""
IFS= read -r -d '' INPUT || true
[ -n "${ZENSU_SESSION_TOKEN:-}" ] || exit 0
[ -n "$INPUT" ] || exit 0

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd -P)" || exit 0
MODULE="$ROOT/hooks/lib/work-order-v1.js"
SESSION_LIB="$ROOT/hooks/lib/zensu-session.sh"
[ -f "$MODULE" ] && [ ! -L "$MODULE" ] || exit 0
[ -f "$SESSION_LIB" ] && [ ! -L "$SESSION_LIB" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0

CLAUDE_PLUGIN_ROOT="$ROOT"
source "$SESSION_LIB" 2>/dev/null || exit 0
zensu_bind_hook_session "$INPUT" 2>/dev/null || exit 0
WO_PD="$(zensu_resolve_project_dir 2>/dev/null)" || exit 0
WO_KEY="${ZENSU_SESSION_KEY:-}"
zensu_session_key_canonical "$WO_KEY" || exit 0
[ -n "$WO_PD" ] && [ -n "${ZENSU_PROJECT_ROOT:-}" ] || exit 0
[ -f "$WO_PD/.zensu/state/work-order/marker-${WO_KEY#scv1_}.json" ] || exit 0

WO_EXCL="$(zensu_msys_env_exclusions WO_PROJECT_ROOT 2>/dev/null)" || WO_EXCL=""
WO_OUT="$(
  cd -P -- "$ROOT/hooks/lib" 2>/dev/null || exit 1
  export WO_PROJECT_ROOT="$ZENSU_PROJECT_ROOT" WO_SESSION_KEY="$WO_KEY" WO_EMIT=hook
  if [ -n "$WO_EXCL" ]; then export MSYS2_ENV_CONV_EXCL="$WO_EXCL"; fi
  node ./work-order-v1.js stop 2>/dev/null
)" || exit 0

WO_CANCEL="$(printf '%s\n' "$WO_OUT" | sed -n '1p')"
WO_BLOCK="$(printf '%s\n' "$WO_OUT" | sed -n '2p')"
if [ -n "$WO_CANCEL" ]; then
  if source "$ROOT/hooks/lib/zensu-autopilot-state.sh" 2>/dev/null; then
    autopilot_apply_event "$WO_CANCEL" work-order-end CANCEL '{}' "$WO_PD" "$WO_KEY" >/dev/null 2>&1 || true
  fi
fi
if [ -n "$WO_BLOCK" ]; then
  printf '%s\n' "$WO_BLOCK"
fi
exit 0
