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
case "$INPUT" in
  *'<agent-message from='*|*'<task-notification>'*) ;;
  *) exit 0 ;;
esac
[ -n "${CLAUDE_PLUGIN_DATA:-}" ] || exit 0
BR_STORE="${CLAUDE_PLUGIN_DATA}/background-review/v1"
BR_PENDING=false
for BR_ENTRY in "$BR_STORE"/records/scv1_*.json "$BR_STORE"/fanout/scv1_*/*.json; do
  if [ -f "$BR_ENTRY" ] && [ ! -L "$BR_ENTRY" ]; then
    BR_PENDING=true
    break
  fi
done
[ "$BR_PENDING" = true ] || exit 0
export CLAUDE_PLUGIN_ROOT
trap '[ -z "${BR_DELEGATE:-}" ] || kill -TERM "$BR_DELEGATE" 2>/dev/null; exit 0' HUP INT TERM
printf '%s' "$INPUT" | bash "${CLAUDE_PLUGIN_ROOT}/hooks/post-review-tdd-delegate.sh" --background-arrival &
BR_DELEGATE=$!
wait "$BR_DELEGATE"
exit 0
