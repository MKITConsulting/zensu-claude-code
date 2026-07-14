#!/bin/bash
# Persist this exact Claude Code plugin installation for later model-issued
# Bash commands. SessionStart hooks run concurrently, so peer hooks must keep
# resolving themselves from CLAUDE_PLUGIN_ROOT instead of depending on this
# export having completed.
set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"

[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 1
ENV_FILE="$CLAUDE_ENV_FILE"

# Invalidate first. If validation, canonicalization, or the final append fails,
# the EXIT trap appends another unset after any concurrent successful writer,
# so the last completed SessionStart attempt always wins fail closed.
printf '%s\n' 'unset ZENSU_CLAUDE_PLUGIN_ROOT' >> "$ENV_FILE" 2>/dev/null || exit 1
PUBLISHED=0
cleanup_failed_export() {
  [ "$PUBLISHED" -eq 1 ] && return
  printf '%s\n' 'unset ZENSU_CLAUDE_PLUGIN_ROOT' >> "$ENV_FILE" 2>/dev/null || true
}
trap cleanup_failed_export EXIT

ROOT="$(cd "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" || exit 1
[ -f "$ROOT/hooks/lib/zensu-log.sh" ] || exit 1

# Bash's %q produces one shell word and safely preserves spaces, quotes,
# dollar signs, backticks, and newlines when Claude sources CLAUDE_ENV_FILE.
# Append so exports written by other concurrent SessionStart hooks survive.
printf 'export ZENSU_CLAUDE_PLUGIN_ROOT=%q\n' "$ROOT" >> "$ENV_FILE" 2>/dev/null || exit 1
PUBLISHED=1
trap - EXIT
exit 0
