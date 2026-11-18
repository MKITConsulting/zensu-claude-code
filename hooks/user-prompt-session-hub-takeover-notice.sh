#!/bin/bash
set -u

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 0
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _ZENSU_DECLARED_PLUGIN_ROOT="$(cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" || exit 0
  [ "$_ZENSU_DECLARED_PLUGIN_ROOT" = "$_ZENSU_EXECUTED_PLUGIN_ROOT" ] || exit 0
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT _ZENSU_DECLARED_PLUGIN_ROOT
{ INPUT="$(cat)"; } 2>/dev/null
case "$INPUT" in *'/session-hub:session-trail'*) ;; *) exit 0 ;; esac
case "$INPUT" in *takeover*) ;; *) exit 0 ;; esac
[ "${ZENSU_BASH_WRITE_GATE:-}" = "off" ] && exit 0
[ "${ZENSU_MCP_GATE:-}" = "off" ] && exit 0
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-agent-context.sh" 2>/dev/null || exit 0
zensu_hook_is_main_principal "$INPUT" UserPromptSubmit || exit 0
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh" 2>/dev/null || exit 0
zensu_hook_opted_in bashWriteGate || exit 0
command -v node >/dev/null 2>&1 || exit 0
NOTICE_ROOT=""
NOTICE_BOUND=0
if source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh" 2>/dev/null \
  && zensu_bind_hook_session "$INPUT" >/dev/null 2>&1; then
  NOTICE_BOUND=1
  NOTICE_ROOT="$(zensu_safe_display_path "${ZENSU_PROJECT_ROOT:-}" 2>/dev/null)" || NOTICE_ROOT=""
  [ "$NOTICE_ROOT" = "(unreadable)" ] && NOTICE_ROOT=""
fi
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-bounded-run.sh" 2>/dev/null || exit 0

(
  cd -P -- "${CLAUDE_PLUGIN_ROOT}/hooks/lib" 2>/dev/null || exit 0
  export ZENSU_NOTICE_ROOT="$NOTICE_ROOT"
  export ZENSU_NOTICE_BOUND="$NOTICE_BOUND"
  printf '%s' "$INPUT" | zensu_run_bounded node ./session-hub-takeover-notice-v1.js
) 2>/dev/null || true
exit 0
