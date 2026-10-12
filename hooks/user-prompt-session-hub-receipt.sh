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
case "$INPUT" in *'--receipt '*) ;; *) exit 0 ;; esac
case "$INPUT" in *'/zensu:session-trail'*) ;; *) exit 0 ;; esac
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-agent-context.sh" 2>/dev/null || exit 0
zensu_hook_is_main_principal "$INPUT" UserPromptSubmit || exit 0
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh" 2>/dev/null || exit 0
zensu_hook_enabled sessionHubReceipt || exit 0
command -v node >/dev/null 2>&1 || exit 0
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-bounded-run.sh" 2>/dev/null || exit 0

(
  cd -P -- "${CLAUDE_PLUGIN_ROOT}/hooks/lib" 2>/dev/null || exit 0
  printf '%s' "$INPUT" | zensu_run_bounded node ./session-hub-receipt-v1.mjs
) >/dev/null 2>&1 || true
exit 0
