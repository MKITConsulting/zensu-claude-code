#!/bin/bash
case "$0" in (*/*) _zensu_hooks="${0%/*}" ;; (*) _zensu_hooks=. ;; esac
ZENSU_GUARD_CALLER_CWD="$(pwd -P 2>/dev/null || true)"
export ZENSU_GUARD_CALLER_CWD
if command -v node >/dev/null 2>&1; then
  source "$_zensu_hooks/lib/zensu-hook-dispatch.sh" 2>/dev/null && zensu_hook_dispatch pre plugin-data-guard "$_zensu_hooks"
  printf '%s\n' "zensu: plugin-data guard did not run (hooks/lib unreachable) — writes into the plugin data store are unguarded" >&2
else
  printf '%s\n' "zensu: plugin-data guard did not run (node unavailable) — writes into the plugin data store are unguarded" >&2
fi
cat >/dev/null 2>&1 || true
exit 0
