#!/bin/bash

zensu_work_order_hook() {
  local verb="${1:-}" input="${2:-}" root module session_lib pd key excl out cancel decision
  [ -n "${ZENSU_SESSION_TOKEN:-}" ] || return 0
  [ -n "$input" ] || return 0
  case "$verb" in
    gate|post|stop) ;;
    *) return 0 ;;
  esac
  root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P)" || return 0
  module="$root/hooks/lib/work-order-v1.js"
  session_lib="$root/hooks/lib/zensu-session.sh"
  [ -f "$module" ] && [ ! -L "$module" ] || return 0
  [ -f "$session_lib" ] && [ ! -L "$session_lib" ] || return 0
  command -v node >/dev/null 2>&1 || return 0
  CLAUDE_PLUGIN_ROOT="$root"
  source "$session_lib" 2>/dev/null || return 0
  zensu_bind_hook_session "$input" 2>/dev/null || return 0
  pd="$(zensu_resolve_project_dir 2>/dev/null)" || return 0
  key="${ZENSU_SESSION_KEY:-}"
  zensu_session_key_canonical "$key" || return 0
  [ -n "$pd" ] && [ -n "${ZENSU_PROJECT_ROOT:-}" ] || return 0
  [ -f "$pd/.zensu/state/work-order/marker-${key#scv1_}.json" ] || return 0
  excl="$(zensu_msys_env_exclusions WO_PROJECT_ROOT 2>/dev/null)" || excl=""
  out="$(
    cd -P -- "$root/hooks/lib" 2>/dev/null || exit 1
    export WO_PROJECT_ROOT="$ZENSU_PROJECT_ROOT" WO_SESSION_KEY="$key" WO_EMIT=hook
    if [ -n "$excl" ]; then export MSYS2_ENV_CONV_EXCL="$excl"; fi
    printf '%s' "$input" | node ./work-order-v1.js "$verb" 2>/dev/null
  )" || return 0
  cancel="$(printf '%s\n' "$out" | sed -n '1p')"
  decision="$(printf '%s\n' "$out" | sed -n '2p')"
  if [ -n "$cancel" ]; then
    if source "$root/hooks/lib/zensu-autopilot-state.sh" 2>/dev/null; then
      autopilot_apply_event "$cancel" work-order-end CANCEL '{}' "$pd" "$key" >/dev/null 2>&1 || true
    fi
  fi
  if [ -n "$decision" ]; then
    printf '%s\n' "$decision"
  fi
  return 0
}
