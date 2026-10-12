#!/bin/bash
set -u
_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)" || exit 2
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _ZENSU_DECLARED_PLUGIN_ROOT="$(cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" || {
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  }
  if [ "$_ZENSU_DECLARED_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  fi
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT _ZENSU_DECLARED_PLUGIN_ROOT

case "${1:-}" in
  --?*) _ZENSU_WO_VERB="${1#--}"; shift ;;
  *)
    echo "zensu-work-order.sh: usage: zensu-work-order.sh --<verb> [options]" >&2
    exit 2
    ;;
esac

command -v node >/dev/null 2>&1 || {
  echo "zensu-work-order.sh: node is not on PATH" >&2
  exit 2
}

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
if ! zensu_bind_model_session; then
  echo "zensu-work-order.sh: rendered Session Control binding unavailable" >&2
  if [ -z "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    echo "zensu-work-order.sh: CLAUDE_CODE_SESSION_ID is not set — this helper must run from Claude Code's own Bash tool." >&2
  fi
  if [ -z "${CLAUDE_PLUGIN_DATA:-}" ]; then
    echo "zensu-work-order.sh: CLAUDE_PLUGIN_DATA is not set — run this helper exactly as the Zensu skill renders it, including its leading plugin-data assignment." >&2
  fi
  exit 2
fi
if ! _ZENSU_WO_PD="$(zensu_resolve_project_dir)" || [ -z "$_ZENSU_WO_PD" ]; then
  echo "zensu-work-order.sh: Session Control project context unavailable" >&2
  exit 2
fi
if ! _ZENSU_WO_KEY="$(zensu_resolve_session_id "")" || [ -z "$_ZENSU_WO_KEY" ]; then
  echo "zensu-work-order.sh: Session Control session identity unavailable" >&2
  exit 2
fi
_ZENSU_WO_EXCL="$(zensu_msys_env_exclusions WO_PROJECT_ROOT WO_PLUGIN_DATA 2>/dev/null)" || _ZENSU_WO_EXCL=""

(
  cd -P -- "${CLAUDE_PLUGIN_ROOT}/hooks/lib" 2>/dev/null || exit 2
  export WO_PROJECT_ROOT="$ZENSU_PROJECT_ROOT" WO_SESSION_KEY="$_ZENSU_WO_KEY"
  export WO_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA:-}" WO_MODEL_PROJECT_DIR="$_ZENSU_WO_PD"
  if [ -n "$_ZENSU_WO_EXCL" ]; then export MSYS2_ENV_CONV_EXCL="$_ZENSU_WO_EXCL"; fi
  exec node ./work-order-v1.js "$_ZENSU_WO_VERB" "$@"
)
exit $?
