#!/bin/bash
case "$0" in (*/*) _zensu_hooks="${0%/*}" ;; (*) _zensu_hooks=. ;; esac
ZENSU_GUARD_CALLER_CWD="$(pwd -P 2>/dev/null || true)"
export ZENSU_GUARD_CALLER_CWD
if command -v node >/dev/null 2>&1; then
  source "$_zensu_hooks/lib/zensu-hook-dispatch.sh" 2>/dev/null && zensu_hook_dispatch pre verify-auth-guard "$_zensu_hooks"
fi
_zensu_input="$(cat 2>/dev/null || true)"
case "$(printf '%s' "$_zensu_input" | LC_ALL=C tr -d '`'"'"'"\\' | LC_ALL=C tr 'A-Z' 'a-z')" in
  (*verify-feature-runs*)
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Zensu verify-auth guard: refused a call that names a verify-feature run directory because the guard could not reach node or its dispatcher; reinstall the plugin or run /zensu:doctor"}}'
    ;;
esac
exit 0
