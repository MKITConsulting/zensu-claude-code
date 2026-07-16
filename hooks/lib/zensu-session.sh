#!/bin/bash

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
  resolved="$(node "$core" session-key "$raw")" || return 1
  if [ -n "$injected_key" ]; then
    # SessionStart injects a canonical key. Once present, it is an immutable
    # binding: explicit raw ids and explicit keys are accepted only when their
    # normalized key is exactly this session's key. This prevents model-side
    # helpers from reading or mutating another session's CAS state.
    [ "$(node "$core" session-key "$injected_key")" = "$injected_key" ] || return 1
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
  PROJECT_CANDIDATE="$candidate" CONTEXT_FILE="$context_file" SESSION_KEY="$session_key" CORE="$core" node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const core = require(process.env.CORE);
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
    process.stdout.write(canonical);
  ' 2>/dev/null
}

export -f zensu_session_key zensu_resolve_session_id zensu_resolve_project_dir 2>/dev/null || true
