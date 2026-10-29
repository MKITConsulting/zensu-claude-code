#!/bin/bash
case "$0" in (*/*) _zensu_hooks="${0%/*}" ;; (*) _zensu_hooks=. ;; esac
command -v node >/dev/null 2>&1 || exec "${BASH:-bash}" "$_zensu_hooks/checks/pre-browser-navigation-consent.sh"
source "$_zensu_hooks/lib/zensu-hook-dispatch.sh" 2>/dev/null && zensu_hook_dispatch pre browser-consent "$_zensu_hooks"
exec "${BASH:-bash}" "$_zensu_hooks/checks/pre-browser-navigation-consent.sh"
