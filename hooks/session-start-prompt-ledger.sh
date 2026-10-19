#!/bin/bash
set -u

_ZENSU_EXECUTED_PLUGIN_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)" || exit 2
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _ZENSU_DECLARED_PLUGIN_ROOT="$(CDPATH= cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" || {
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
{ INPUT="$(cat)"; } 2>/dev/null
command -v node >/dev/null 2>&1 || exit 0

SESSION_ID="$(PAYLOAD="$INPUT" node -e '
  try {
    const j = JSON.parse(process.env.PAYLOAD || "{}");
    if (j && j.hook_event_name === "SessionStart" && typeof j.session_id === "string") {
      process.stdout.write(j.session_id);
    }
  } catch (_) {}
' 2>/dev/null)"
[ -n "$SESSION_ID" ] || exit 0

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-prompt-ledger.sh"
LEDGER_KEY="$(cd -P -- "${CLAUDE_PLUGIN_ROOT}/hooks/lib" 2>/dev/null \
  && node ./session-control-core-v1.js session-key "$SESSION_ID" 2>/dev/null)"
zensu_prompt_ledger_reset "$LEDGER_KEY"
zensu_prompt_ledger_sweep
exit 0
