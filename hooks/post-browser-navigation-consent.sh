#!/bin/bash
set -u

skip() {
  echo "zensu: browser consent memory not written ($1)" >&2
  exit 0
}

INPUT="$(cat 2>/dev/null || true)"
_ZENSU_SCAN="$(printf '%s' "$INPUT" | LC_ALL=C sed -e 's/\\\\\\r\\n//g' -e 's/\\\\\\n//g' 2>/dev/null | LC_ALL=C tr -d "\"'\\\\" 2>/dev/null)" || _ZENSU_SCAN="$INPUT"
[ -n "$_ZENSU_SCAN" ] || _ZENSU_SCAN="$INPUT"
shopt -s nocasematch
case "$_ZENSU_SCAN" in
  *playwright-cli*|*@playwright/cli*|*@playwright\\/cli*) ;;
  *) exit 0 ;;
esac
case "$_ZENSU_SCAN" in
  *zensu-verify-*) ;;
  *)
    case "${PLAYWRIGHT_CLI_SESSION:-}" in
      *zensu-verify-*) ;;
      *) exit 0 ;;
    esac
    ;;
esac
shopt -u nocasematch
unset _ZENSU_SCAN

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" \
  || skip "plugin root unresolved"
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _ZENSU_DECLARED_PLUGIN_ROOT="$(cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" \
    || skip "inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin"
  if [ "$_ZENSU_DECLARED_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
    skip "inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin"
  fi
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT _ZENSU_DECLARED_PLUGIN_ROOT

command -v node >/dev/null 2>&1 || skip "node unavailable"
MODULE="$CLAUDE_PLUGIN_ROOT/hooks/lib/verify-consent-v1.js"
[ -f "$MODULE" ] && [ ! -L "$MODULE" ] || skip "decision module absent or symlinked"
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh" 2>/dev/null || skip "session library unavailable"
zensu_bind_hook_session "$INPUT" >/dev/null 2>&1 || skip "no bound session"
ZENSU_VERIFY_PROJECT_ROOT="$(zensu_resolve_project_dir 2>/dev/null || true)"
[ -n "$ZENSU_VERIFY_PROJECT_ROOT" ] && [ -n "${ZENSU_SESSION_KEY:-}" ] || skip "no project root"
[ ! -L "$ZENSU_VERIFY_PROJECT_ROOT/.zensu" ] || skip "symlinked .zensu"
[ ! -L "$ZENSU_VERIFY_PROJECT_ROOT/.zensu/state" ] || skip "symlinked state directory"
mkdir -p "$ZENSU_VERIFY_PROJECT_ROOT/.zensu/state" 2>/dev/null || skip "state directory unavailable"
ZENSU_VERIFY_CONSENT_MEMORY="$ZENSU_VERIFY_PROJECT_ROOT/.zensu/state/verify-consent-${ZENSU_SESSION_KEY}.json"
export ZENSU_VERIFY_CONSENT_MEMORY ZENSU_VERIFY_PROJECT_ROOT

printf '%s' "$INPUT" | (
  cd -P -- "$CLAUDE_PLUGIN_ROOT/hooks/lib" && node ./verify-consent-v1.js post
) || skip "decision module failed"
exit 0
