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
# and same printed path — TWO statuses, 0 with the path and 1 for everything
# else, exactly as its hook-payload sibling — but no hook payload exists there,
# so the session id comes from CLAUDE_CODE_SESSION_ID. Do not give this pair a
# third status by copying the incompatible-orphaned pair's contract onto it: they
# back different argv modes, and a consumer that branched on `-ne 3` here would
# read every unavailable answer as a live recorded root.
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

# Returns 0 when a Session Control record READS and the disagreement is that the
# executing runtime declares an incompatible lineage — what a plugin update
# landing mid-session produces — with or WITHOUT a vanished project root. It is
# NOT a relaxable state in either half, and does not belong to the pair above,
# but the two halves are unrelaxed for different reasons: with the recorded root
# still present a workflow document is reachable, so relaxing a write gate would
# waive a live guarantee rather than a dead one; with that root gone the document
# is not reachable from this record, and what stands in for the guarantee is that the state has a real
# in-place repair (adoption) rather than a silent waiver. A caller that says
# anything about the workflow document must ask the third fact separately —
# zensu_session_incompatible_orphaned_root below — and branch on it. It exists so
# the doctor row, the Stop release and the deny text can NAME the cause instead
# of falling through to "no record", which is false and sends the user hunting
# for a record that is sitting intact.
# The decision lives in claude-hook-session-v1.js so every caller shares exactly
# one implementation.
#
# On a match this PRINTS `recorded<TAB>executing` on stdout. The same warning the
# orphaned wrapper carries applies with equal force: inside a PreToolUse gate
# stdout is the hook's JSON decision channel, so a caller that wants the
# predicate alone MUST discard stdout explicitly (`>/dev/null`).
zensu_session_incompatible_runtime() {
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
        node ./claude-hook-session-v1.js incompatible-runtime
  ) 2>/dev/null
}

# The model-side twin of the predicate above, for /zensu:doctor: same question
# and same printed version pair, but no hook payload exists there, so the session
# id comes from CLAUDE_CODE_SESSION_ID.
zensu_session_incompatible_runtime_model() {
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
      node ./claude-hook-session-v1.js model-incompatible-runtime
  ) 2>/dev/null
}

# The THIRD fact of the incompatible-lineage state, asked separately so the
# version pair above stays two TAB-separated fields — five callers read the
# executing half as `${V##*$'\t'}`, so a third field there would silently
# redirect all five. Returns 0 and PRINTS the recorded project root only when the
# lineage is incompatible AND that root is gone; **3** for a plain incompatible
# lineage whose recorded root still exists; and 1 only when the question could not
# be answered at all. THREE statuses, never two — a caller that reads only
# truthiness collapses the last two, and that collapse is what makes a consumer
# assert a workflow document that is gone.
#
# The same stdout warning the two wrappers above carry applies here: inside a
# PreToolUse gate stdout is the hook's JSON decision channel, so a caller that
# wants the predicate alone MUST discard stdout explicitly.
zensu_session_incompatible_orphaned_root() {
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
        node ./claude-hook-session-v1.js orphaned-incompatible-root
  ) 2>/dev/null
}

# The model-side twin of the predicate above, for /zensu:doctor: same question,
# same printed path and the SAME THREE statuses — 0 with the dead path, 3 for a
# recorded root that positively still exists, 1 for an unavailable answer — but no
# hook payload exists there, so the session id comes from CLAUDE_CODE_SESSION_ID.
# The third status is what lets /zensu:doctor tell a negative from a failure; the
# plain orphan pair above has only two and must not be branched on the same way.
zensu_session_incompatible_orphaned_root_model() {
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
      node ./claude-hook-session-v1.js model-orphaned-incompatible-root
  ) 2>/dev/null
}

# Returns 0 ONLY when this PreToolUse payload is one of the two recognized Bash
# calls: the read-only /zensu:doctor diagnostic, or /zensu:adopt-session. This is
# NOT a relaxable-state predicate and does not belong beside the two above: those
# answer "is there anything left to enforce", this one answers "is this one of
# the commands that must stay reachable while unbound". It applies in EVERY bind
# failure, including a record that exists and disagrees — the state where the
# diagnostic was previously denied by the very defect it reports, and the state
# the adoption repairs.
#
# The two are admitted on DIFFERENT grounds and the distinction is load-bearing:
# the diagnostic writes nothing, while the adoption WRITES — three classes, named
# in the header of hooks/lib/zensu-session-adopt.sh, which is also where that
# second justification lives. Do not fold the two arguments into one.
#
# The decision lives in zensu-doctor-invocation.js so all three Bash gates and
# the all-tool capability gate share exactly one recognizer, and it derives the
# executing plugin root itself rather than trusting a caller. Every caller must
# still conjoin its own main-principal check: a reviewer or neutral child has
# neither command to run.
#
# Prints nothing on purpose. Inside a PreToolUse gate stdout is the JSON decision
# channel, so a stray byte here would corrupt the verdict.
#
# Deliberately carries NONE of the CLAUDE_PLUGIN_ROOT / CLAUDE_PLUGIN_DATA
# rendering the predicates above need. The recognizer reads only stdin and its
# own __dirname, so passing them would add nothing — while making the diagnostic
# unreachable in exactly the degraded sessions it exists for: zensu-host-path.sh
# exits non-zero on an empty argument, so an unset CLAUDE_PLUGIN_DATA would
# silently refuse the doctor. Every precondition here must be one the recognizer
# actually depends on.
zensu_doctor_invocation() {
  local payload="${1:-}"
  local lib_dir recognizer
  [ -n "$payload" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  recognizer="$lib_dir/zensu-doctor-invocation.js"
  [ -f "$recognizer" ] && [ ! -L "$recognizer" ] || return 1
  (
    cd -P -- "$lib_dir" || exit 1
    printf '%s' "$payload" | node ./zensu-doctor-invocation.js
  ) >/dev/null 2>&1
}

# The one decision "may this call run despite a failed bind". Both conjuncts are
# required at every gate: the command must BE one of the two recognized ones —
# the read-only diagnostic, or the adoption, which WRITES its own session's
# record under the justification in its own header — and the caller must be the
# interactive thread. A reviewer, evidence worker or
# neutral child has neither to run, and the all-tool capability gate's own
# principal check is not a substitute here — a deny from ANY hook on the Bash
# matcher wins, so each gate has to reach this verdict itself or the allowance
# silently collapses back into a deny.
#
# Fails closed on a missing or unsafe agent-context lib: an unresolved principal
# is not the main thread.
zensu_doctor_allowed() {
  local payload="${1:-}"
  local lib_dir context_lib
  zensu_doctor_invocation "$payload" || return 1
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  context_lib="$lib_dir/zensu-agent-context.sh"
  [ -r "$context_lib" ] && [ ! -L "$context_lib" ] || return 1
  # shellcheck disable=SC1090
  source "$context_lib" || return 1
  zensu_hook_is_main_principal "$payload" PreToolUse
}

# Four scopes, because the same emitter serves callers with very different
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
#   incompatible-runtime  the caller POSITIVELY identified the lineage state and
#                     supplies both declared versions ($2 recorded, $3 executing);
#                     this is the one scope that can name a remedy which fixes
#                     the session in place rather than telling the user to start
#                     over
#
# The version pair is interpolated into a JSON string, so it is held to a strict
# shape first. A manifest version is ordinary text as far as the record schema is
# concerned (validateContext only requireText's it), and an unchecked value here
# would let a crafted manifest inject a quote and rewrite the decision object.
# A value that fails the check is SUBSTITUTED with `(unreadable)` and the lineage
# wording is kept. Falling back to the narrowed scope instead would drop the
# in-place remedy and tell the user to start a fresh session — the contradiction
# this scope exists to remove. Losing two numbers is a worse message; losing the
# remedy is a wrong one.
ZENSU_SAFE_VERSION_RE='^[0-9A-Za-z][0-9A-Za-z.+-]{0,63}$'

zensu_emit_hook_session_deny() {
  local scope="${1:-}"
  if [ "$scope" = incompatible-runtime ]; then
    local recorded="${2:-}" executing="${3:-}"
    # ONE degradation policy across all three consumers of this pair: substitute a
    # placeholder and KEEP the lineage wording. Falling back to `narrowed` here
    # dropped the in-place remedy entirely and told the user to start a fresh
    # session — the contradiction this scope exists to remove.
    [[ "$recorded" =~ $ZENSU_SAFE_VERSION_RE ]] || recorded="(unreadable)"
    [[ "$executing" =~ $ZENSU_SAFE_VERSION_RE ]] || executing="(unreadable)"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: this session'"'"'s Session Control record is readable, and the disagreement is that the running Zensu installation declares an incompatible lineage — the record was minted by %s and %s is executing. While the plugin is at major 0 the minor is the breaking axis, so a plugin update that landed mid-session stops serving the record and every stateful tool fails closed. The record is NOT damaged and NOT missing. Run /zensu:adopt-session to check whether this session can be adopted by the running installation in place, and /zensu:adopt-session --confirm to do it; both stay reachable in this state. If the recorded project root is ALSO gone — a deleted or recycled worktree — the adoption still clears the lineage break, but Edit, Write and MultiEdit stay denied, and so does any Bash command the source-write gate can attribute as a write, afterwards until that exact directory is re-created; /zensu:doctor names the path when that is the case. If it refuses, the persisted shapes really did change and a fresh Claude Code session is the only way forward."}}\n' \
      "$recorded" "$executing"
    return
  fi
  if [ "$scope" = narrowed ]; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: the immutable Zensu session binding is unavailable or invalid, so this call cannot be attributed to a Session Control record. This is neither relaxable state — a session with no record at all, and a record whose recorded project root no longer exists, are both handled separately — so either a record exists and disagrees with the running plugin installation about something else, or a relaxable-state check could not be evaluated at all. The most common cause is a Zensu plugin change across a breaking version boundary that landed while this session was running: a compatible upgrade keeps serving the record, but a breaking one or a downgrade cannot, because the record stays bound to the installation the session started on and no session can be re-bound in place. Run /zensu:doctor, which stays reachable in this state and names the disagreement, then start a fresh Claude Code session before using stateful tools."}}'
    return
  fi
  if [ "$scope" = damaged-runtime ]; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: this session has no usable Session Control binding — either no record at all, or a record whose recorded project root no longer exists — which alone would still leave the interactive thread able to run /zensu:doctor, but a required Zensu runtime library is missing or unreadable, so that diagnostic is denied too. Repair the Zensu plugin installation; a fresh Claude Code session will not help until the installation itself is intact."}}'
    return
  fi
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: the immutable Zensu session binding is unavailable or invalid, so every stateful Zensu tool fails closed. Run /zensu:doctor — it stays reachable in every bind failure and names which check failed: whether this session has no record at all, a record whose recorded project root no longer exists, or a record that disagrees for another reason, most often a Zensu plugin change across a breaking version boundary that landed mid-session; a compatible upgrade no longer denies. Then start a fresh Claude Code session before using stateful tools."}}'
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
  zensu_session_incompatible_runtime zensu_session_incompatible_runtime_model \
  zensu_session_incompatible_orphaned_root zensu_session_incompatible_orphaned_root_model \
  zensu_session_key zensu_resolve_session_id zensu_resolve_project_dir 2>/dev/null || true
