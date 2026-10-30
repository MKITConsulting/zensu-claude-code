#!/bin/bash
case "$0" in (*/*) _zensu_hooks="${0%/*}" ;; (*) _zensu_hooks=. ;; esac
if command -v node >/dev/null 2>&1 && source "$_zensu_hooks/lib/zensu-hook-dispatch.sh" 2>/dev/null; then
  (zensu_hook_dispatch pre reviewer-spawn-allow "$_zensu_hooks")
fi
cat >/dev/null 2>&1 || true
exit 0
