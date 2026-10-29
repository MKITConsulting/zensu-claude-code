#!/bin/bash
set -uo pipefail

fail_closed() {
  printf 'zensu: reviewer capability gate unavailable: %s\n' "$1" >&2
  exit 2
}

fail_closed_after_drain() {
  cat >/dev/null 2>&1 || true
  fail_closed "$1"
}

SCRIPT_DIR="$(case "$0" in (*/*) CDPATH= cd -- "${0%/*}/" ;; esac 2>/dev/null && pwd -P)" \
  || fail_closed "cannot resolve the directory of this hook"
PLUGIN_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)" \
  || fail_closed "cannot resolve the plugin root above this hook"
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  DECLARED_PLUGIN_ROOT="$(CDPATH= cd -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" \
    || fail_closed_after_drain "CLAUDE_PLUGIN_ROOT names no readable directory; start a fresh Claude Code session"
  [ "$DECLARED_PLUGIN_ROOT" = "$PLUGIN_ROOT" ] \
    || fail_closed_after_drain "CLAUDE_PLUGIN_ROOT names another plugin installation than the one running this hook; start a fresh Claude Code session"
fi
POLICY="$SCRIPT_DIR/lib/reviewer-capability-v1.js"
[ -f "$POLICY" ] || fail_closed "the policy module hooks/lib/reviewer-capability-v1.js is missing; reinstall the plugin"
NODE_MISSING="node was not found on the PATH that Claude Code was started with, and Zensu blocks every tool call until node is available. Install Node.js or put it on that PATH, then restart Claude Code (see Requirements in $PLUGIN_ROOT/README.md), or disable the Zensu plugin"
NODE="$(command -v node 2>/dev/null)" || fail_closed_after_drain "$NODE_MISSING"
[ -n "$NODE" ] || fail_closed_after_drain "$NODE_MISSING"
unset -f zensu_host_path _zensu_host_path_render _zensu_host_path_drive 2>/dev/null || true
source "$SCRIPT_DIR/lib/zensu-host-path.sh" 2>/dev/null && declare -F zensu_host_path >/dev/null 2>&1 \
  || fail_closed_after_drain "the path helper hooks/lib/zensu-host-path.sh cannot be loaded; reinstall the plugin"
NATIVE_PLUGIN_ROOT="$(zensu_host_path "$PLUGIN_ROOT")" \
  || fail_closed_after_drain "cannot convert the plugin root into a path node can open"
NATIVE_PLUGIN_DATA="$(zensu_host_path "${CLAUDE_PLUGIN_DATA:-}")" \
  || fail_closed_after_drain "cannot convert CLAUDE_PLUGIN_DATA into a path node can open"

OUTPUT="$(
  {
    cd -P -- "$SCRIPT_DIR/lib" \
      && CLAUDE_PLUGIN_ROOT="$NATIVE_PLUGIN_ROOT" CLAUDE_PLUGIN_DATA="$NATIVE_PLUGIN_DATA" \
        "$NODE" ./reviewer-capability-v1.js
  } 2>/dev/null
  printf ':%s' "$?"
)"
STATUS="${OUTPUT##*:}"
OUTPUT="${OUTPUT%:*}"
[ "$STATUS" -eq 0 ] || fail_closed "the policy check exited with status $STATUS"
printf '%s' "$OUTPUT" || fail_closed "cannot write the policy result"
exit 0
