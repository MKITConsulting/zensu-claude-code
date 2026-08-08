#!/bin/bash

_ZENSU_SESSION_MSYS_ENV_READY=false
_ZENSU_SESSION_LIB_DIR=''
_ZENSU_SESSION_MSYS_ENV=''
unset -f zensu_msys_env_exclusions 2>/dev/null || true
if _ZENSU_SESSION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; then
  _ZENSU_SESSION_MSYS_ENV="$_ZENSU_SESSION_LIB_DIR/zensu-msys-env.sh"
  if [ -f "$_ZENSU_SESSION_MSYS_ENV" ] && [ ! -L "$_ZENSU_SESSION_MSYS_ENV" ]; then
    # shellcheck disable=SC1090
    if source "$_ZENSU_SESSION_MSYS_ENV" \
        && declare -F zensu_msys_env_exclusions >/dev/null 2>&1; then
      _ZENSU_SESSION_MSYS_ENV_READY=true
    fi
  fi
fi
if [ "$_ZENSU_SESSION_MSYS_ENV_READY" != true ]; then
  # Keep every public session function available to its caller. Stateful hooks
  # can then render their normal fail-closed deny even when this dependency is
  # missing, symlinked, or otherwise unsafe to source.
  zensu_msys_env_exclusions() { return 1; }
fi
export -f zensu_msys_env_exclusions 2>/dev/null || true
unset _ZENSU_SESSION_LIB_DIR _ZENSU_SESSION_MSYS_ENV _ZENSU_SESSION_MSYS_ENV_READY

zensu_bind_hook_session() {
  local payload="${1:-}"
  local lib_dir binder bindings plugin_root native_plugin_root native_plugin_data
  local msys_env_exclusions
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
  msys_env_exclusions="$(zensu_msys_env_exclusions CLAUDE_PLUGIN_ROOT CLAUDE_PLUGIN_DATA)" \
    || return 1
  # Native Windows Node cannot reliably consume an MSYS module path when the
  # plugin root contains shell metacharacters. Resolve the already-validated
  # module from its own directory and let the binder normalize the declared
  # root before it compares identities.
  bindings="$(
    cd -P -- "$lib_dir" || exit 1
    printf '%s' "$payload" \
      | MSYS2_ENV_CONV_EXCL="$msys_env_exclusions" \
        CLAUDE_PLUGIN_ROOT="$native_plugin_root" CLAUDE_PLUGIN_DATA="$native_plugin_data" \
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
  local msys_env_exclusions
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
  msys_env_exclusions="$(zensu_msys_env_exclusions CLAUDE_PLUGIN_ROOT CLAUDE_PLUGIN_DATA)" \
    || return 1
  bindings="$(
    cd -P -- "$lib_dir" || exit 1
    MSYS2_ENV_CONV_EXCL="$msys_env_exclusions" \
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

# Returns 0 ONLY when Session Control has never registered this session — one of
# the two bind failures a gate may safely relax (see
# zensu_session_orphaned_project_root below for the other), because it is the
# 0.17.0 upgrade state (that release introduced the record; a resumed session
# never mints one) and not a capability or integrity violation. Every other
# failure, including a record that exists and disagrees about anything beyond a
# missing project root, returns non-zero and must stay fail-closed.
# The decision lives in claude-hook-session-v1.js so all three Bash gates and
# the all-tool capability gate share exactly one predicate.
zensu_session_unregistered() {
  local payload="${1:-}"
  local lib_dir binder plugin_root native_plugin_root native_plugin_data
  local msys_env_exclusions
  [ -n "$payload" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  plugin_root="$(cd "$lib_dir/../.." && pwd -P)" || return 1
  binder="$lib_dir/claude-hook-session-v1.js"
  [ -f "$binder" ] && [ ! -L "$binder" ] || return 1
  native_plugin_root="$(bash "$lib_dir/zensu-host-path.sh" "$plugin_root")" || return 1
  native_plugin_data="$(bash "$lib_dir/zensu-host-path.sh" "${CLAUDE_PLUGIN_DATA:-}")" || return 1
  msys_env_exclusions="$(zensu_msys_env_exclusions CLAUDE_PLUGIN_ROOT CLAUDE_PLUGIN_DATA)" \
    || return 1
  (
    cd -P -- "$lib_dir" || exit 1
    printf '%s' "$payload" \
      | MSYS2_ENV_CONV_EXCL="$msys_env_exclusions" \
        CLAUDE_PLUGIN_ROOT="$native_plugin_root" CLAUDE_PLUGIN_DATA="$native_plugin_data" \
        node ./claude-hook-session-v1.js unregistered
  ) 2>/dev/null
}

# Returns 0 ONLY when a Session Control record exists, validates in every other
# respect, and the project root it recorded no longer exists — the deleted or
# recycled worktree. The workflow document lived inside that directory, so no
# review chain and no Autopilot run survive it: the same "nothing left to
# enforce, nothing waived" argument that relaxes zensu_session_unregistered
# above, reached from the opposite direction. It is a SEPARATE predicate on
# purpose — that one answers "no record", this one answers "a record whose
# directory is gone", and collapsing them would relax a record that disagrees.
# The decision lives in claude-hook-session-v1.js so every gate shares exactly
# one implementation.
#
# On a match this PRINTS the dead recorded path on stdout, so a caller can name
# what to re-create. A caller that wants the predicate only MUST discard stdout
# explicitly (`>/dev/null`): inside a PreToolUse gate, stdout is the hook's JSON
# decision channel and a stray path there would corrupt it.
zensu_session_orphaned_project_root() {
  local payload="${1:-}"
  local lib_dir binder plugin_root native_plugin_root native_plugin_data
  local msys_env_exclusions
  [ -n "$payload" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  plugin_root="$(cd "$lib_dir/../.." && pwd -P)" || return 1
  binder="$lib_dir/claude-hook-session-v1.js"
  [ -f "$binder" ] && [ ! -L "$binder" ] || return 1
  native_plugin_root="$(bash "$lib_dir/zensu-host-path.sh" "$plugin_root")" || return 1
  native_plugin_data="$(bash "$lib_dir/zensu-host-path.sh" "${CLAUDE_PLUGIN_DATA:-}")" || return 1
  msys_env_exclusions="$(zensu_msys_env_exclusions CLAUDE_PLUGIN_ROOT CLAUDE_PLUGIN_DATA)" \
    || return 1
  (
    cd -P -- "$lib_dir" || exit 1
    printf '%s' "$payload" \
      | MSYS2_ENV_CONV_EXCL="$msys_env_exclusions" \
        CLAUDE_PLUGIN_ROOT="$native_plugin_root" CLAUDE_PLUGIN_DATA="$native_plugin_data" \
        node ./claude-hook-session-v1.js orphaned-project-root
  ) 2>/dev/null
}

# The model-side twin of the predicate above, for /zensu:doctor: same question
# and same printed path, but no hook payload exists there, so the session id
# comes from CLAUDE_CODE_SESSION_ID.
zensu_session_orphaned_project_root_model() {
  local lib_dir binder plugin_root native_plugin_root native_plugin_data
  local msys_env_exclusions
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || return 1
  [ -n "${CLAUDE_PLUGIN_DATA:-}" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  plugin_root="$(cd "$lib_dir/../.." && pwd -P)" || return 1
  binder="$lib_dir/claude-hook-session-v1.js"
  [ -f "$binder" ] && [ ! -L "$binder" ] || return 1
  native_plugin_root="$(bash "$lib_dir/zensu-host-path.sh" "$plugin_root")" || return 1
  native_plugin_data="$(bash "$lib_dir/zensu-host-path.sh" "$CLAUDE_PLUGIN_DATA")" || return 1
  msys_env_exclusions="$(zensu_msys_env_exclusions CLAUDE_PLUGIN_ROOT CLAUDE_PLUGIN_DATA)" \
    || return 1
  (
    cd -P -- "$lib_dir" || exit 1
    MSYS2_ENV_CONV_EXCL="$msys_env_exclusions" \
      CLAUDE_PLUGIN_ROOT="$native_plugin_root" CLAUDE_PLUGIN_DATA="$native_plugin_data" \
      node ./claude-hook-session-v1.js model-orphaned-project-root
  ) 2>/dev/null
}

# Three scopes, because the same emitter serves callers with very different
# knowledge. A caller that already ruled out the RELAXABLE states may say so; a
# caller that denies on any bind failure must NOT, or it tells a user in a
# relaxable state that /zensu:doctor is denied when it is exactly the command
# that still works for them.
#
# The reasons deliberately avoid asserting "no record" as the cause: two states
# are relaxable — no record at all, and a record whose recorded project root no
# longer exists — and naming the wrong one sends a user with an intact record
# hunting for a record that is right there. That is the same misdiagnosis the
# /zensu:doctor binding rows and the Stop-hook reasons were corrected for.
#   (default)         any bind failure, cause not narrowed
#   narrowed          BOTH relaxable states were ruled out by the caller
#   damaged-runtime   the session IS in a relaxable state, so the diagnostic
#                     would normally be reachable, but a runtime library the
#                     gate needs is missing — so the doctor is denied too
zensu_emit_hook_session_deny() {
  local scope="${1:-}"
  if [ "$scope" = narrowed ]; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: the immutable Zensu session binding is unavailable or invalid, so this call cannot be attributed to a Session Control record. This is neither relaxable state — a session with no record at all, and a record whose recorded project root no longer exists, are both handled separately — so either a record exists and disagrees with the running plugin installation about something else, or a relaxable-state check could not be evaluated at all. Start a fresh Claude Code session before using stateful tools."}}'
    return
  fi
  if [ "$scope" = damaged-runtime ]; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: this session has no usable Session Control binding — either no record at all, or a record whose recorded project root no longer exists — which alone would still leave the interactive thread able to run /zensu:doctor, but a required Zensu runtime library is missing or unreadable, so that diagnostic is denied too. Repair the Zensu plugin installation; a fresh Claude Code session will not help until the installation itself is intact."}}'
    return
  fi
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: the immutable Zensu session binding is unavailable or invalid, so every stateful Zensu tool fails closed. Run /zensu:doctor to see which check failed — it names whether this session has no record at all, a record whose recorded project root no longer exists, or a record that disagrees for another reason — or start a fresh Claude Code session before using stateful tools."}}'
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
  local lib_dir core msys_env_exclusions
  [ -n "$candidate" ] && [ -n "$context_file" ] && [ -n "$session_key" ] || return 1
  [ ! -L "$candidate" ] && [ -d "$candidate" ] || return 1
  [ ! -L "$context_file" ] && [ -f "$context_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  core="$lib_dir/session-control-core-v1.js"
  [ -f "$core" ] || return 1
  msys_env_exclusions="$(zensu_msys_env_exclusions PROJECT_CANDIDATE CONTEXT_FILE)" \
    || return 1
  (
    cd -P -- "$lib_dir" || exit 1
    MSYS2_ENV_CONV_EXCL="$msys_env_exclusions" \
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
  zensu_session_unregistered \
  zensu_session_orphaned_project_root zensu_session_orphaned_project_root_model \
  zensu_session_key zensu_resolve_session_id zensu_resolve_project_dir 2>/dev/null || true
