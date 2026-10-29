#!/bin/bash
set -u

BR_HOOK_TIMEOUT=180
BR_CLAIM_MARGIN=45
_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 0
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _ZENSU_DECLARED_PLUGIN_ROOT="$(cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" || exit 0
  [ "$_ZENSU_DECLARED_PLUGIN_ROOT" = "$_ZENSU_EXECUTED_PLUGIN_ROOT" ] || exit 0
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT _ZENSU_DECLARED_PLUGIN_ROOT
{ INPUT="$(cat)"; } 2>/dev/null
[ -n "${CLAUDE_PLUGIN_DATA:-}" ] || exit 0
BR_STORE="${CLAUDE_PLUGIN_DATA}/background-review/v1"
BR_PENDING=false
case "$INPUT" in
  *'<agent-message from='*|*'<task-notification>'*)
    for BR_ENTRY in "$BR_STORE"/records/scv1_*.json "$BR_STORE"/fanout/scv1_*/*.json; do
      if [ -f "$BR_ENTRY" ] && [ ! -L "$BR_ENTRY" ]; then
        BR_PENDING=true
        break
      fi
    done
    ;;
esac
if [ "$BR_PENDING" = false ]; then
  for BR_ENTRY in "$BR_STORE"/arrivals/scv1_*.json; do
    if [ -f "$BR_ENTRY" ] && [ ! -L "$BR_ENTRY" ]; then
      BR_PENDING=true
      break
    fi
  done
fi
[ "$BR_PENDING" = true ] || exit 0
export CLAUDE_PLUGIN_ROOT
trap '[ -z "${BR_DELEGATE:-}" ] || kill -TERM "$BR_DELEGATE" 2>/dev/null; exit 0' HUP INT TERM
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-msys-env.sh"
BR_DATA="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-host-path.sh" "$CLAUDE_PLUGIN_DATA" 2>/dev/null)" || exit 0
BR_EXCLUSIONS="$(zensu_msys_env_exclusions ZENSU_BR_PLUGIN_DATA 2>/dev/null)" || BR_EXCLUSIONS="${MSYS2_ENV_CONV_EXCL:-}"
BR_ARRIVAL="$(printf '%s' "$INPUT" | MSYS2_ENV_CONV_EXCL="$BR_EXCLUSIONS" ZENSU_BR_PLUGIN_DATA="$BR_DATA" \
  node "${CLAUDE_PLUGIN_ROOT}/hooks/lib/background-review-v1.js" arrive 2>/dev/null)" || exit 0
case "$BR_ARRIVAL" in
  "pending agent="*) ;;
  *) exit 0 ;;
esac
ZENSU_BR_CLAIM_BY="$(( $(date +%s) - SECONDS + BR_HOOK_TIMEOUT - BR_CLAIM_MARGIN ))"
export ZENSU_BR_CLAIM_BY
printf '%s' "$INPUT" | bash "${CLAUDE_PLUGIN_ROOT}/hooks/post-review-tdd-delegate.sh" --background-arrival &
BR_DELEGATE=$!
wait "$BR_DELEGATE"
exit 0
