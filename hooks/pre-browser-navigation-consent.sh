#!/bin/bash
set -u

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Zensu browser consent gate denied the playwright-cli call: %s"}}' "$1"
  echo "zensu: browser consent gate denied the playwright-cli call ($1)" >&2
  exit 0
}

{ INPUT="$(cat 2>/dev/null || true)"; } 2>/dev/null
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

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || {
  echo "zensu: browser consent gate cannot resolve its own plugin root" >&2
  exit 2
}
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

if source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh" 2>/dev/null && zensu_doctor_allowed "$INPUT"; then
  exit 0
fi

command -v node >/dev/null 2>&1 || deny "node unavailable"
MODULE="$CLAUDE_PLUGIN_ROOT/hooks/lib/verify-consent-v1.js"
[ -f "$MODULE" ] && [ ! -L "$MODULE" ] || deny "decision module absent or symlinked"

ZENSU_VERIFY_CONSENT_MEMORY=""
ZENSU_VERIFY_PROJECT_ROOT=""
if source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh" 2>/dev/null \
  && zensu_bind_hook_session "$INPUT" >/dev/null 2>&1; then
  _ZENSU_CONSENT_ROOT="$(zensu_resolve_project_dir 2>/dev/null || true)"
  if [ -n "$_ZENSU_CONSENT_ROOT" ] && [ -n "${ZENSU_SESSION_KEY:-}" ]; then
    ZENSU_VERIFY_PROJECT_ROOT="$_ZENSU_CONSENT_ROOT"
    ZENSU_VERIFY_CONSENT_MEMORY="$_ZENSU_CONSENT_ROOT/.zensu/state/verify-consent-${ZENSU_SESSION_KEY}.json"
  fi
fi
export ZENSU_VERIFY_CONSENT_MEMORY ZENSU_VERIFY_PROJECT_ROOT

DECISION="$(printf '%s' "$INPUT" | (
  cd -P -- "$CLAUDE_PLUGIN_ROOT/hooks/lib" && node ./verify-consent-v1.js pre
))" || deny "decision module failed"
[ -z "$DECISION" ] || printf '%s\n' "$DECISION"
exit 0
