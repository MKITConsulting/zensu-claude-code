#!/bin/bash
set -u

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

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Zensu browser consent gate denied the navigation: %s"}}' "$1"
  echo "zensu: browser consent gate denied the navigation ($1)" >&2
  exit 0
}

# deny() is defined ABOVE the read on purpose: a read that fails has no other channel to report
# on. `cat 2>/dev/null || true` discarded the status, so an EIO, an EPIPE or a host that closed
# stdin early produced an empty payload — and every layer below then judged something it never
# received. The module refuses a blank payload on its own, but only once node has run and only
# while the module is loadable, so this gate must not depend on either to refuse its own input.
if ! INPUT="$(cat 2>/dev/null)"; then deny "hook payload unreadable"; fi
[ -n "$INPUT" ] || deny "hook payload unreadable"

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
else
  echo "zensu: browser consent gate has no bound session — every navigation asks and nothing is remembered" >&2
fi
# Which recipe governs is resolved INSIDE the decision module from the project root, so
# this hook, its PostToolUse sibling and the /zensu:doctor row cannot disagree about it.
export ZENSU_VERIFY_CONSENT_MEMORY ZENSU_VERIFY_PROJECT_ROOT

DECISION="$(printf '%s' "$INPUT" | (
  cd -P -- "$CLAUDE_PLUGIN_ROOT/hooks/lib" && node ./verify-consent-v1.js pre
))" || deny "decision module failed"
[ -z "$DECISION" ] || printf '%s\n' "$DECISION"
exit 0
