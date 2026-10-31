#!/bin/bash
case "$0" in (*/*) _zensu_hooks="${0%/*}" ;; (*) _zensu_hooks=. ;; esac
if command -v node >/dev/null 2>&1; then
  source "$_zensu_hooks/lib/zensu-hook-dispatch.sh" 2>/dev/null && zensu_hook_dispatch post artifact-redact "$_zensu_hooks"
  printf '%s\n' "zensu: artifact redactor unavailable (module path unresolvable)" >&2
else
  printf '%s\n' "zensu: artifact redactor unavailable (node is not on PATH)" >&2
fi
cat >/dev/null 2>&1 || true
exit 0
