#!/bin/bash
case "$0" in (*/*) _zensu_hooks="${0%/*}" ;; (*) _zensu_hooks=. ;; esac
_zensu_lead='zensu: reviewer capability gate unavailable: '
if command -v node >/dev/null 2>&1; then
  if source "$_zensu_hooks/lib/zensu-hook-dispatch.sh" 2>/dev/null && declare -F zensu_hook_dispatch_guarded >/dev/null 2>&1; then
    zensu_hook_dispatch_guarded pre reviewer-capability "$_zensu_hooks" "$_zensu_lead"
    exit
  fi
  _zensu_reason="the dispatcher hooks/lib/hook-dispatch-v1.js cannot be started; reinstall the plugin"
else
  _zensu_root="$(CDPATH= cd -- "$_zensu_hooks/.." 2>/dev/null && pwd -P)"
  _zensu_reason="node was not found on the PATH that Claude Code was started with, and Zensu blocks every tool call until node is available. Install Node.js or put it on that PATH, then restart Claude Code (see Requirements in $_zensu_root/README.md), or disable the Zensu plugin"
fi
cat >/dev/null 2>&1 || true
printf '%s%s\n' "$_zensu_lead" "$_zensu_reason" >&2
exit 2
