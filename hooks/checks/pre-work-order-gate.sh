#!/bin/bash
set -u

INPUT=""
IFS= read -r -d '' INPUT || true
[ -n "${ZENSU_SESSION_TOKEN:-}" ] || exit 0
LIB="$(case "$0" in (*/*) CDPATH= cd -- "${0%/*}/../lib" ;; (*) CDPATH= cd -- ../lib ;; esac 2>/dev/null && pwd -P)" || exit 0
[ -f "$LIB/zensu-work-order-hook.sh" ] && [ ! -L "$LIB/zensu-work-order-hook.sh" ] || exit 0
source "$LIB/zensu-work-order-hook.sh" 2>/dev/null || exit 0
zensu_work_order_hook gate "$INPUT"
exit 0
