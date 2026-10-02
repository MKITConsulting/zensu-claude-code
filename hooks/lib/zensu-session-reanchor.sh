#!/bin/bash
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || {
  printf '%s\n' 'zensu:adopt-session --reanchor: cannot resolve the plugin library directory' >&2
  exit 1
}
PLUGIN_ROOT="$(cd "$DIR/../.." && pwd -P)" || {
  printf '%s\n' 'zensu:adopt-session --reanchor: cannot resolve the executing plugin root' >&2
  exit 1
}
TARGET="$(pwd -P)" || {
  printf '%s\n' 'zensu:adopt-session --reanchor: the current directory cannot be resolved' >&2
  exit 1
}

_zsr_seen=0
while IFS='|' read -r _zsr_file _zsr_noun; do
  [ -n "$_zsr_file" ] || continue
  _zsr_seen=$((_zsr_seen + 1))
  [ -f "$DIR/$_zsr_file" ] && [ ! -L "$DIR/$_zsr_file" ] || {
    printf '%s\n' "zensu:adopt-session --reanchor: the $_zsr_noun is missing or symlinked; repair the Zensu plugin installation" >&2
    exit 1
  }
done <<'ZSR_REQUIRED_MODULES'
session-reanchor-v1.js|re-anchor module
session-control-core-v1.js|Session Control runtime
claude-hook-session-v1.js|Session Control binder
review-evidence-sweep-v1.js|review-evidence sweep module
review-evidence-lease-v1.js|review-evidence lease module
worktree-keep-v1.js|worktree-keep module
bash-source-write-parse.js|source-write parser
zensu-safe-display-v1.js|display-safety module
claude-path-v1.js|host-path module
ZSR_REQUIRED_MODULES
[ "$_zsr_seen" -eq 9 ] || {
  printf '%s\n' 'zensu:adopt-session --reanchor: the required-module table could not be read in full; repair the Zensu plugin installation' >&2
  exit 1
}

CONFIRM=0
for _zsr_arg in "$@"; do
  case "$_zsr_arg" in
    --confirm)
      [ "$CONFIRM" -eq 0 ] || {
        printf '%s\n' 'zensu:adopt-session --reanchor: --confirm may be given only once' >&2
        exit 2
      }
      CONFIRM=1
      ;;
    *)
      printf '%s\n' 'zensu:adopt-session --reanchor: the only supported argument is --confirm' >&2
      exit 2
      ;;
  esac
done

command -v node >/dev/null 2>&1 || {
  printf '%s\n' 'zensu:adopt-session --reanchor: node is not available, so Session Control cannot be read' >&2
  exit 1
}
[ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || {
  printf '%s\n' 'zensu:adopt-session --reanchor: CLAUDE_CODE_SESSION_ID is unset, so this session cannot be identified' >&2
  exit 1
}
[ -n "${CLAUDE_PLUGIN_DATA:-}" ] || {
  printf '%s\n' 'zensu:adopt-session --reanchor: CLAUDE_PLUGIN_DATA is unset, so the record store cannot be located' >&2
  exit 1
}

for _zsr_lib in "$DIR/zensu-session.sh" "$DIR/zensu-host-path.sh" "$DIR/zensu-config.sh" \
  "$DIR/zensu-autopilot-state.sh" "$DIR/zensu-tdd-phase.sh"; do
  [ -f "$_zsr_lib" ] && [ ! -L "$_zsr_lib" ] || {
    printf '%s\n' "zensu:adopt-session --reanchor: ${_zsr_lib##*/} is missing or symlinked; repair the Zensu plugin installation" >&2
    exit 1
  }
done

source "$DIR/zensu-session.sh" >/dev/null 2>&1 || {
  printf '%s\n' 'zensu:adopt-session --reanchor: the Session Control shell library is unavailable' >&2
  exit 1
}
source "$DIR/zensu-config.sh" >/dev/null 2>&1 || {
  printf '%s\n' 'zensu:adopt-session --reanchor: the configuration library is unavailable' >&2
  exit 1
}
KEEP=0
zensu_hook_enabled worktreeKeep && KEEP=1
IDLE_HOURS="$(zensu_worktree_keep_idle_hours 2>/dev/null)" || IDLE_HOURS=72
NATIVE_BASH="$(_zensu_config_native_path "${BASH:-bash}")" || NATIVE_BASH=bash

NATIVE_PLUGIN_ROOT="$(bash "$DIR/zensu-host-path.sh" "$PLUGIN_ROOT")" || {
  printf '%s\n' 'zensu:adopt-session --reanchor: the executing plugin root is not a readable directory; repair the Zensu plugin installation' >&2
  exit 1
}
NATIVE_PLUGIN_DATA="$(bash "$DIR/zensu-host-path.sh" "$CLAUDE_PLUGIN_DATA")" || {
  printf '%s\n' 'zensu:adopt-session --reanchor: CLAUDE_PLUGIN_DATA does not name a readable directory, so the record store cannot be located. It is missing, a file, or a symlink.' >&2
  exit 1
}
NATIVE_TARGET="$(bash "$DIR/zensu-host-path.sh" "$TARGET")" || {
  printf '%s\n' 'zensu:adopt-session --reanchor: the current directory is not a readable directory' >&2
  exit 1
}
MSYS_EXCL="$(zensu_msys_env_exclusions ZREANCHOR_PLUGIN_ROOT ZREANCHOR_PLUGIN_DATA ZREANCHOR_TARGET ZREANCHOR_BASH)" || {
  printf '%s\n' 'zensu:adopt-session --reanchor: the host-path environment library is unavailable; repair the Zensu plugin installation' >&2
  exit 1
}

cd -P -- "$DIR" || exit 1
MSYS2_ENV_CONV_EXCL="$MSYS_EXCL" \
ZREANCHOR_PLUGIN_ROOT="$NATIVE_PLUGIN_ROOT" \
ZREANCHOR_PLUGIN_DATA="$NATIVE_PLUGIN_DATA" \
ZREANCHOR_TARGET="$NATIVE_TARGET" \
ZREANCHOR_CONFIRM="$CONFIRM" \
ZREANCHOR_WORKTREE_KEEP="$KEEP" \
ZREANCHOR_WORKTREE_KEEP_IDLE_HOURS="$IDLE_HOURS" \
ZREANCHOR_BASH="$NATIVE_BASH" \
node ./session-reanchor-v1.js
