#!/bin/bash

zensu_bind_hook_session() {
  local payload="${1:-}"
  local lib_dir binder bindings plugin_root native_plugin_root native_plugin_data
  unset ZENSU_CLAUDE_PLUGIN_ROOT ZENSU_SESSION_KEY ZENSU_SESSION_CONTEXT \
    ZENSU_RUNTIME_DIGEST ZENSU_PROJECT_ROOT
  [ -n "$payload" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  plugin_root="$(cd "$lib_dir/../.." && pwd -P)" || return 1
  binder="$lib_dir/claude-hook-session-v1.js"
  [ -f "$binder" ] && [ ! -L "$binder" ] || return 1
  native_plugin_root="$(bash "$lib_dir/zensu-host-path.sh" "$plugin_root")" || return 1
  native_plugin_data="$(bash "$lib_dir/zensu-host-path.sh" "${CLAUDE_PLUGIN_DATA:-}")" || return 1
  # Native Windows Node cannot reliably consume an MSYS module path when the
  # plugin root contains shell metacharacters. Resolve the already-validated
  # module from its own directory and let the binder normalize the declared
  # root before it compares identities.
  bindings="$(
    cd -P -- "$lib_dir" || exit 1
    printf '%s' "$payload" \
      | CLAUDE_PLUGIN_ROOT="$native_plugin_root" CLAUDE_PLUGIN_DATA="$native_plugin_data" \
        node ./claude-hook-session-v1.js
  )" || {
    unset ZENSU_CLAUDE_PLUGIN_ROOT ZENSU_SESSION_KEY ZENSU_SESSION_CONTEXT \
      ZENSU_RUNTIME_DIGEST ZENSU_PROJECT_ROOT
    return 1
  }
  eval "$bindings" || {
    unset ZENSU_CLAUDE_PLUGIN_ROOT ZENSU_SESSION_KEY ZENSU_SESSION_CONTEXT \
      ZENSU_RUNTIME_DIGEST ZENSU_PROJECT_ROOT
    return 1
  }
  export ZENSU_CLAUDE_PLUGIN_ROOT ZENSU_SESSION_KEY ZENSU_SESSION_CONTEXT \
    ZENSU_RUNTIME_DIGEST ZENSU_PROJECT_ROOT
}

zensu_bind_model_session() {
  local lib_dir binder bindings plugin_root native_plugin_root native_plugin_data
  unset ZENSU_CLAUDE_PLUGIN_ROOT ZENSU_SESSION_KEY ZENSU_SESSION_CONTEXT \
    ZENSU_RUNTIME_DIGEST ZENSU_PROJECT_ROOT
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || return 1
  [ -n "${CLAUDE_PLUGIN_DATA:-}" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  plugin_root="$(cd "$lib_dir/../.." && pwd -P)" || return 1
  binder="$lib_dir/claude-hook-session-v1.js"
  [ -f "$binder" ] && [ ! -L "$binder" ] || return 1
  native_plugin_root="$(bash "$lib_dir/zensu-host-path.sh" "$plugin_root")" || return 1
  native_plugin_data="$(bash "$lib_dir/zensu-host-path.sh" "$CLAUDE_PLUGIN_DATA")" || return 1
  bindings="$(
    cd -P -- "$lib_dir" || exit 1
    CLAUDE_PLUGIN_ROOT="$native_plugin_root" CLAUDE_PLUGIN_DATA="$native_plugin_data" \
      node ./claude-hook-session-v1.js model-bind
  )" || {
    unset ZENSU_CLAUDE_PLUGIN_ROOT ZENSU_SESSION_KEY ZENSU_SESSION_CONTEXT \
      ZENSU_RUNTIME_DIGEST ZENSU_PROJECT_ROOT
    return 1
  }
  eval "$bindings" || {
    unset ZENSU_CLAUDE_PLUGIN_ROOT ZENSU_SESSION_KEY ZENSU_SESSION_CONTEXT \
      ZENSU_RUNTIME_DIGEST ZENSU_PROJECT_ROOT
    return 1
  }
  export ZENSU_CLAUDE_PLUGIN_ROOT ZENSU_SESSION_KEY ZENSU_SESSION_CONTEXT \
    ZENSU_RUNTIME_DIGEST ZENSU_PROJECT_ROOT
}

zensu_emit_hook_session_deny() {
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: the immutable Zensu session binding is unavailable or invalid. Start a fresh Claude Code session before using stateful tools."}}'
}

zensu_resolve_session_id() {
  local raw="${1:-}"
  local lib_dir core resolved injected_key
  injected_key="${ZENSU_SESSION_KEY:-}"
  if [ -z "$raw" ]; then
    raw="$injected_key"
  fi
  [ -n "$raw" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  core="$lib_dir/session-control-core-v1.js"
  [ -f "$core" ] || return 1
  resolved="$(cd -P -- "$lib_dir" && node ./session-control-core-v1.js session-key "$raw")" \
    || return 1
  if [ -n "$injected_key" ]; then
    # SessionStart injects a canonical key. Once present, it is an immutable
    # binding: explicit raw ids and explicit keys are accepted only when their
    # normalized key is exactly this session's key. This prevents model-side
    # helpers from reading or mutating another session's CAS state.
    [ "$(cd -P -- "$lib_dir" && node ./session-control-core-v1.js session-key "$injected_key")" \
      = "$injected_key" ] || return 1
    [ "$resolved" = "$injected_key" ] || return 1
  fi
  printf '%s\n' "$resolved"
}

zensu_session_key() {
  zensu_resolve_session_id "${1:-}"
}

zensu_resolve_project_dir() {
  local candidate="${ZENSU_PROJECT_ROOT:-}"
  local context_file="${ZENSU_SESSION_CONTEXT:-}"
  local session_key="${ZENSU_SESSION_KEY:-}"
  local lib_dir core
  [ -n "$candidate" ] && [ -n "$context_file" ] && [ -n "$session_key" ] || return 1
  [ ! -L "$candidate" ] && [ -d "$candidate" ] || return 1
  [ ! -L "$context_file" ] && [ -f "$context_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  core="$lib_dir/session-control-core-v1.js"
  [ -f "$core" ] || return 1
  (
    cd -P -- "$lib_dir" || exit 1
    PROJECT_CANDIDATE="$candidate" CONTEXT_FILE="$context_file" SESSION_KEY="$session_key" node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const core = require("./session-control-core-v1.js");
    const key = core.sessionKey(process.env.SESSION_KEY);
    if (key !== process.env.SESSION_KEY) process.exit(1);
    const contextFile = path.resolve(process.env.CONTEXT_FILE);
    if (path.basename(contextFile) !== `${key}.json`) process.exit(1);
    const stat = fs.lstatSync(contextFile);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1) process.exit(1);
    if (fs.realpathSync.native(contextFile) !== contextFile) process.exit(1);
    const recordsDir = path.dirname(contextFile);
    const context = core.readContext({ recordsDir, sessionId: key });
    const requested = path.resolve(process.env.PROJECT_CANDIDATE);
    const canonical = fs.realpathSync.native(requested);
    if (requested !== canonical || context.project_root !== canonical) process.exit(1);
    ' 2>/dev/null
  ) || return 1

  # Session Control records the host-native canonical path. On Git Bash that
  # is a Windows path (for example C:\\work\\repo), while subsequent shell
  # helpers need the MSYS spelling (/c/work/repo) for path concatenation and
  # Bash builtins. Validate the immutable native value above, then render the
  # same directory in the executing shell's canonical namespace.
  (cd -P -- "$candidate" && pwd -P)
}

export -f zensu_bind_hook_session zensu_bind_model_session zensu_emit_hook_session_deny \
  zensu_session_key zensu_resolve_session_id zensu_resolve_project_dir 2>/dev/null || true
