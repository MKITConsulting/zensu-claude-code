#!/bin/bash
set -u

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 2
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
{ INPUT="$(cat)"; } 2>/dev/null
case "$INPUT" in *'.claude/worktrees'*|*'.claude\\worktrees'*) ;; *) exit 0 ;; esac
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-agent-context.sh"
zensu_hook_is_main_principal "$INPUT" SessionStart || exit 0
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled worktreeKeep || exit 0
command -v node >/dev/null 2>&1 || exit 0
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-msys-env.sh"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-bounded-run.sh"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-worktree-keep.sh"

zensu_worktree_keep_anchor "$INPUT" || exit 0
ROOT="$ZENSU_WK_ROOT"
SESSION_KEY="$ZENSU_WK_SESSION_KEY"
SOURCE="$(zensu_worktree_keep_read_field "$INPUT" source)"
IDLE_HOURS="$(zensu_worktree_keep_idle_hours 2>/dev/null)" || IDLE_HOURS=72
MSYS_EXCL="$(zensu_msys_env_exclusions WK_CWD 2>/dev/null)" || MSYS_EXCL=""

(
  cd -P -- "${CLAUDE_PLUGIN_ROOT}/hooks/lib" 2>/dev/null || exit 0
  unset WK_NOW WK_MAX_DIRS
  export WK_CWD="$ROOT" WK_SESSION_KEY="$SESSION_KEY" WK_SOURCE="$SOURCE" WK_IDLE_HOURS="$IDLE_HOURS" WK_EMIT="claude-hook"
  if [ -n "$MSYS_EXCL" ]; then export MSYS2_ENV_CONV_EXCL="$MSYS_EXCL"; fi
  zensu_run_bounded node ./worktree-keep-v1.js session-start </dev/null
) || true
exit 0
