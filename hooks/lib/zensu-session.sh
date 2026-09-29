#!/bin/bash

# SECOND LOADER: hooks/lib/zensu-directive.sh loads zensu-msys-env.sh the same way,
# but records whether the load worked and falls back to its own append where this one
# installs a refusing stub. Change the two loaders together.
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
    ZENSU_RUNTIME_DIGEST ZENSU_PROJECT_ROOT ZENSU_SESSION_ADOPTED
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
      ZENSU_RUNTIME_DIGEST ZENSU_PROJECT_ROOT ZENSU_SESSION_ADOPTED
    return 1
  }
  eval "$bindings" || {
    unset ZENSU_CLAUDE_PLUGIN_ROOT ZENSU_SESSION_KEY ZENSU_SESSION_CONTEXT \
      ZENSU_RUNTIME_DIGEST ZENSU_PROJECT_ROOT ZENSU_SESSION_ADOPTED
    return 1
  }
  export ZENSU_CLAUDE_PLUGIN_ROOT ZENSU_SESSION_KEY ZENSU_SESSION_CONTEXT \
    ZENSU_RUNTIME_DIGEST ZENSU_PROJECT_ROOT ZENSU_SESSION_ADOPTED
}

zensu_bind_model_session() {
  local lib_dir binder bindings plugin_root native_plugin_root native_plugin_data
  local msys_env_exclusions
  unset ZENSU_CLAUDE_PLUGIN_ROOT ZENSU_SESSION_KEY ZENSU_SESSION_CONTEXT \
    ZENSU_RUNTIME_DIGEST ZENSU_PROJECT_ROOT ZENSU_SESSION_ADOPTED
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
      ZENSU_RUNTIME_DIGEST ZENSU_PROJECT_ROOT ZENSU_SESSION_ADOPTED
    return 1
  }
  eval "$bindings" || {
    unset ZENSU_CLAUDE_PLUGIN_ROOT ZENSU_SESSION_KEY ZENSU_SESSION_CONTEXT \
      ZENSU_RUNTIME_DIGEST ZENSU_PROJECT_ROOT ZENSU_SESSION_ADOPTED
    return 1
  }
  export ZENSU_CLAUDE_PLUGIN_ROOT ZENSU_SESSION_KEY ZENSU_SESSION_CONTEXT \
    ZENSU_RUNTIME_DIGEST ZENSU_PROJECT_ROOT ZENSU_SESSION_ADOPTED
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

# ONE implementation behind the four binder-mode wrappers below. They were four
# copies of the same body — the node probe, the lib_dir/plugin_root resolution,
# the binder `[ -f ] && [ ! -L ]` guard, both zensu-host-path.sh renders,
# zensu_msys_env_exclusions and the `cd -P` subshell — differing only in the argv
# mode and the `model-` prefix. The cost was never the lines: it was that a change
# to the MSYS preamble or to the symlink guard had to land in all four by hand,
# with nothing failing when one was missed.
#
# The MODE selects the calling convention, not the argument count. A `model-` mode
# takes its session id from CLAUDE_CODE_SESSION_ID and writes no stdin; every
# other mode requires a payload and pipes it in. Keying on the mode rather than on
# "was the payload empty" keeps a payload mode called with an empty payload a
# REFUSAL, instead of silently falling through to the model convention and
# answering about a different session than the caller asked about.
#
# CLAUDE_PLUGIN_DATA is read as `${CLAUDE_PLUGIN_DATA:-}` on both paths. The model
# wrappers used the bare `$CLAUDE_PLUGIN_DATA`, which was safe only because the
# emptiness check two lines above it happened to run first; the guarded spelling
# does not depend on that ordering surviving an edit.
_zensu_session_binder_mode() {
  local mode="${1:-}" payload="${2:-}"
  local lib_dir binder plugin_root native_plugin_root native_plugin_data
  local msys_env_exclusions
  [ -n "$mode" ] || return 1
  case "$mode" in
    model-*)
      [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || return 1
      [ -n "${CLAUDE_PLUGIN_DATA:-}" ] || return 1
      ;;
    *)
      [ -n "$payload" ] || return 1
      ;;
  esac
  command -v node >/dev/null 2>&1 || return 1
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  plugin_root="$(cd "$lib_dir/../.." && pwd -P)" || return 1
  binder="$lib_dir/claude-hook-session-v1.js"
  [ -f "$binder" ] && [ ! -L "$binder" ] || return 1
  native_plugin_root="$(bash "$lib_dir/zensu-host-path.sh" "$plugin_root")" || return 1
  native_plugin_data="$(bash "$lib_dir/zensu-host-path.sh" "${CLAUDE_PLUGIN_DATA:-}")" || return 1
  msys_env_exclusions="$(zensu_msys_env_exclusions CLAUDE_PLUGIN_ROOT CLAUDE_PLUGIN_DATA)" \
    || return 1
  # ONE invocation, with the MODE choosing what stands on stdin. Two subshells —
  # one piped, one not — would double the `node ./claude-hook-session-v1.js` count
  # while the MSYS exclusion is still computed once, and that pair is a shipped
  # invariant: test-msys-runtime-boundaries asserts that every relative binder
  # invocation in this file is covered by its own
  # `zensu_msys_env_exclusions CLAUDE_PLUGIN_ROOT CLAUDE_PLUGIN_DATA`.
  #
  # Piping an EMPTY stdin for a model mode is not a behaviour change: the binder
  # reads the payload only on the non-model branches, taking the session id from
  # CLAUDE_CODE_SESSION_ID otherwise, so those invocations never touched stdin.
  # The closed pipe is the safer of the two anyway — the previous spelling let
  # them inherit whatever descriptor the caller happened to hold.
  (
    cd -P -- "$lib_dir" || exit 1
    case "$mode" in
      model-*) : ;;
      *) printf '%s' "$payload" ;;
    esac \
      | MSYS2_ENV_CONV_EXCL="$msys_env_exclusions" \
        CLAUDE_PLUGIN_ROOT="$native_plugin_root" CLAUDE_PLUGIN_DATA="$native_plugin_data" \
        node ./claude-hook-session-v1.js "$mode"
  ) 2>/dev/null
}

# Returns 0 when a Session Control record READS and the disagreement is that the
# executing runtime declares an incompatible lineage — what a plugin update
# landing mid-session produces — with or WITHOUT a vanished project root. It is
# NOT a relaxable state in either half, and does not belong to the pair above,
# but the two halves are unrelaxed for different reasons: with the recorded root
# still present a workflow document is reachable, so relaxing a write gate would
# waive a live guarantee rather than a dead one; with that root gone the document
# is not reachable from this record, and what stands in for the guarantee is that
# the state has a real in-place repair (adoption) rather than a silent waiver. A
# caller that says anything about the workflow document must ask the third fact
# separately — zensu_session_incompatible_orphaned_root below — and branch on it.
# It exists so the doctor row, the Stop release and the deny text can NAME the
# cause instead of falling through to "no record", which is false and sends the
# user hunting for a record that is sitting intact.
# The decision lives in claude-hook-session-v1.js so every caller shares exactly
# one implementation.
#
# On a match this PRINTS `recorded<TAB>executing` on stdout. The same warning the
# orphaned wrapper carries applies with equal force: inside a PreToolUse gate
# stdout is the hook's JSON decision channel, so a caller that wants the
# predicate alone MUST discard stdout explicitly (`>/dev/null`).
zensu_session_incompatible_runtime() {
  _zensu_session_binder_mode incompatible-runtime "${1:-}"
}

# The model-side twin of the predicate above, for /zensu:doctor: same question
# and same printed version pair, but no hook payload exists there, so the session
# id comes from CLAUDE_CODE_SESSION_ID.
zensu_session_incompatible_runtime_model() {
  _zensu_session_binder_mode model-incompatible-runtime
}

# Returns 0 ONLY when a Session Control record is intact in every respect and the
# SOLE disagreement is that the installation which minted it no longer exists on
# disk — what the host's plugin-cache pruning produces for a session that
# outlived a few releases. Like the lineage predicate above it is NAMED, never
# relaxed: a workflow document is still reachable, and adoption re-mints the
# record under the running installation. Disjoint from the lineage predicate by
# construction (that one needs the strict read to succeed, this one needs it to
# fail), and deliberately blind to lineage, because the remedy is the same
# either way. The decision lives in claude-hook-session-v1.js.
#
# On a match this PRINTS the same `recorded<TAB>executing` pair the lineage
# predicate prints, so every consumer of that pair reads this one unchanged. The
# same stdout warning applies: a caller wanting the predicate alone MUST discard
# stdout explicitly (`>/dev/null`).
zensu_session_pruned_plugin_root() {
  _zensu_session_binder_mode pruned-plugin-root "${1:-}"
}

# The model-side twin, for /zensu:doctor: same question, same printed pair, the
# session id from CLAUDE_CODE_SESSION_ID.
zensu_session_pruned_plugin_root_model() {
  _zensu_session_binder_mode model-pruned-plugin-root
}

# Prints ONE token on stdout naming why the automatic adoption did not bind this
# session: an ADOPTION_REFUSALS value, `opted-out`, `adopted-concurrently` (a
# sibling hook won the lock and the record serves now — retry the call),
# `superseded-record-exists` (adoptable, but the file an interrupted adoption left
# behind is in the way — moving it is the remedy, a retry is a loop) or
# `not-completed` (adoptable, yet the caller's own bind failed inside the
# adoption — a lock timeout; retry). Read-only: it previews and never adopts.
# Non-zero when the question cannot be answered — which includes a record that
# already serves while the bind still fails: that failure was never an adoption
# one, and a token here would blame the adoption for it.
# Never a TAB, so the `recorded<TAB>executing` pair its consumers already parse
# keeps exactly two fields. Same stdout warning as every predicate above.
zensu_session_adoption_refusal() {
  _zensu_session_binder_mode adoption-refusal "${1:-}"
}

# The three sentences a refusal token selects, shape-checked here so a consumer
# outside this library never reaches a private renderer with an unscreened value.
# The Stop hook is that consumer: it renders the token into a stderr line rather
# than through zensu_emit_hook_session_deny, whose JSON channel a Stop cannot use.
zensu_session_adoption_remedy() {
  local refusal="${1:-}"
  if [ -z "${ZENSU_SAFE_REFUSAL_RE:-}" ] || ! [[ "$refusal" =~ $ZENSU_SAFE_REFUSAL_RE ]]; then refusal="(unknown)"; fi
  _zensu_adoption_refusal_remedy "$refusal"
}

zensu_session_adoption_attempt() {
  local refusal="${1:-}"
  if [ -z "${ZENSU_SAFE_REFUSAL_RE:-}" ] || ! [[ "$refusal" =~ $ZENSU_SAFE_REFUSAL_RE ]]; then refusal="(unknown)"; fi
  _zensu_adoption_attempt "$refusal"
}

zensu_session_adoption_tail() {
  local refusal="${1:-}"
  if [ -z "${ZENSU_SAFE_REFUSAL_RE:-}" ] || ! [[ "$refusal" =~ $ZENSU_SAFE_REFUSAL_RE ]]; then refusal="(unknown)"; fi
  _zensu_adoption_tail "$refusal"
}

# The per-gate bind-failure ladder, in ONE place. Four gates carried the same nine
# lines plus the same three-line comment, differing only in the payload variable
# and in the fallback scope — so adding a fifth named state meant eight edits with
# nothing that fails when one is missed, and the only control was a hand-maintained
# roster in CLAUDE.md. The fallback scope is the one thing that legitimately
# differs between the gates, so it stays the argument.
#
# The rationale the copies carried, kept here because it is the reason the ladder
# exists at all: before it, a gate in a named state printed "start a fresh Claude
# Code session" while its siblings said the session could be adopted — two denies
# contradicting each other about the one bind failure that has an in-place remedy.
#
# Both predicates PRINT `recorded<TAB>executing` on stdout, and inside a PreToolUse
# gate stdout is the JSON decision channel, so each is captured into a variable and
# never leaked. The two are disjoint by construction — the lineage one needs the
# strict read to succeed, the pruned one needs it to fail — so their order is
# immaterial. A caller that passes no fallback scope gets the generic deny.
zensu_emit_named_bind_deny() {
  local payload="${1:-}" fallback="${2:-}" audience="${3:-}"
  local pair refusal
  # The AUDIENCE is an optional third argument: a caller that has already
  # established its principal — the Edit gate exits for every non-main principal
  # before it can reach this function — passes it and saves the node spawn the
  # derivation costs. Anything but `main` or `child` is derived instead.
  case "$audience" in (main|child) ;; (*) audience="" ;; esac
  # Either named state is reached only AFTER the bind's own automatic adoption
  # did not bind the session, so the deny names why. One extra binder spawn, on
  # the deny path only; an unanswerable question renders as `(unknown)`.
  if pair="$(zensu_session_incompatible_runtime "$payload")" && [ -n "$pair" ]; then
    refusal="$(zensu_session_adoption_refusal "$payload")" || refusal=""
    [ -n "$audience" ] || audience="$(_zensu_deny_audience "$payload")"
    zensu_emit_hook_session_deny incompatible-runtime \
      "${pair%%$'\t'*}" "${pair##*$'\t'}" "$refusal" "$audience"
    return
  fi
  if pair="$(zensu_session_pruned_plugin_root "$payload")" && [ -n "$pair" ]; then
    refusal="$(zensu_session_adoption_refusal "$payload")" || refusal=""
    [ -n "$audience" ] || audience="$(_zensu_deny_audience "$payload")"
    zensu_emit_hook_session_deny pruned-plugin-root \
      "${pair%%$'\t'*}" "${pair##*$'\t'}" "$refusal" "$audience"
    return
  fi
  # NEITHER named state, and the adoption may still have run: the bind attempts it
  # before any predicate is asked, so a refusal that establishes no named state
  # (`record-unreadable`, a foreign store) or a race a sibling hook won lands HERE,
  # on wording that used to say nothing about it. The token is asked once and
  # rendered when there is one; an empty answer leaves the scope as it always was.
  refusal="$(zensu_session_adoption_refusal "$payload")" || refusal=""
  if [ "$refusal" = adopted-concurrently ]; then
    # The record serves NOW, so neither named predicate can match any more. This
    # is the only scope whose remedy is simply to retry.
    [ -n "$audience" ] || audience="$(_zensu_deny_audience "$payload")"
    zensu_emit_hook_session_deny adoption-incomplete "$refusal" "$audience"
    return
  fi
  if [ -n "$refusal" ]; then
    [ -n "$audience" ] || audience="$(_zensu_deny_audience "$payload")"
    zensu_emit_hook_session_deny "$fallback" "$refusal" "$audience"
    return
  fi
  # The orphaned root is tested LAST of the three. State the ground correctly: the
  # three predicates are DISJOINT by construction, so the order is defence in depth
  # rather than a correctness constraint. resolveOrphanedProjectRoot returns null
  # unless servesRecordedRuntime is true, so it cannot match in a lineage break, and
  # readOrphanedProjectRootContext still canonicalizes an absent plugin_root and
  # throws, so it cannot match in the pruned state either. The order is kept — and
  # pinned by R7f — so that a future relaxation of either predicate above cannot
  # silently reorder the diagnosis and offer the restore before the adoption it
  # requires. An earlier wording claimed that reordering would ALREADY do that,
  # which is a false disjointness model for anyone reasoning from it.
  #
  # It is tested at all because without it a gate denying in this state fell through
  # to the generic reason, which prescribes a fresh session — while the doctor row and
  # the Stop release for the SAME state now offer an in-place repair. That is the
  # contradiction this file's own rule names: a gate left on the generic text tells the
  # user to start a fresh session while its sibling says the session can be repaired in
  # place.
  #
  # TWO of the four callers reach this arm, not four, and the two that do not are
  # not symmetrical — say what each actually does rather than one sentence for both.
  # pre-bash-source-write-gate.sh rules the orphan state out ABOVE the router so it
  # can reach its own write-specific denies, which name the repair themselves; do
  # not "fix" that by removing its guard, because that would cost it the specific
  # message. pre-write-secret-scan.sh rules the state out in order to ALLOW the
  # scan, and carries no bind-state remedy at all. The reachable callers are
  # pre-edit-tdd-reminder.sh and pre-bash-zensu-gate.sh.
  local dead_root
  if dead_root="$(zensu_session_orphaned_project_root "$payload")" && [ -n "$dead_root" ]; then
    zensu_emit_hook_session_deny orphaned-project-root "$dead_root"
    return
  fi
  zensu_emit_hook_session_deny ${fallback:+"$fallback"}
}

# Sources the agent-context library beside this file. ONE loader for the two
# callers that need a principal — zensu_doctor_allowed and _zensu_deny_audience —
# which spelled this preamble separately. It only reports; the FAIL DIRECTION is
# each caller's own and the two are opposite on purpose: the allowance fails
# CLOSED (an unresolved principal is not the main thread), the audience falls to
# `main` (losing the remedy is the wrong message, an unusable one only a worse one).
_zensu_load_agent_context() {
  local lib_dir context_lib
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  context_lib="$lib_dir/zensu-agent-context.sh"
  [ -r "$context_lib" ] && [ ! -L "$context_lib" ] || return 1
  # shellcheck disable=SC1090
  source "$context_lib" || return 1
}

# WHO reads the deny: `main` or `child`. The remedy of every adoption deny is a
# command that WRITES the immutable record, and `zensu_doctor_allowed` conjoins the
# main principal — so a reviewer, an evidence worker or a neutral child handed that
# command is pointed at a write every gate refuses it. The `.*` gate has always
# split its wording on this; the shell scopes did not, and handed the remedy to
# every principal. Asked only on a deny that renders an adoption sentence.
#
# `main` whenever the principal cannot be established, and that direction is
# deliberate: a child shown the main wording still cannot run the command, while
# the main thread shown the child wording loses the one in-place remedy this state
# has. Losing the remedy is the wrong message; an unusable one is only a worse one.
_zensu_deny_audience() {
  local payload="${1:-}" principal
  _zensu_load_agent_context || { printf 'main'; return; }
  principal="$(zensu_hook_principal "$payload" PreToolUse 2>/dev/null)" || principal=""
  if [ -n "$principal" ] && [ "$principal" != main-v1 ]; then
    printf 'child'
    return
  fi
  printf 'main'
}

# THE THREE-WAY STATUS HAS A NAME, and this is it. The trichotomy below is a good
# design and it was spelled as a bare `3` in two hooks plus a structure pin, with the
# vocabulary living only in the prose of this comment — so a reader of either call site
# saw a magic number and could not tell `3` (a POSITIVE negative: the root is there)
# from the failure status it sits next to. That is exactly the collapse the paragraph
# below warns about, one level up: not a caller reading truthiness, but a maintainer
# reading a literal.
#
# Both consumers reach the trichotomy through these names, but NOT by the same route,
# and the difference is worth stating because an earlier wording here flattened it into
# "both compare against these names" and was wrong about one of them.
# hooks/stop-chain-enforcer.sh sources this file in its PARENT shell, so it compares
# against ZENSU_ROOT_STATE_* directly. hooks/lib/zensu-doctor.sh sources it only inside
# command substitutions, where the name is out of scope and reading it under `set -u`
# aborted the whole diagnostic; it copies the VALUES out in one subshell and compares
# against its own ZDOC_ROOT_STATE_* instead. Still one definition, still no literal —
# but the doctor is held to a DERIVED name, not to this one.
#
# Keep them in step — AC-C19 in tests/structure/test-versioned-plugin-upgrade.sh greps
# for both members in both files, in the spelling each consumer actually uses, so a
# silent revert to a literal fails rather than passing. That claim was false for one
# round: only the PRESENT member was pinned, nothing named _GONE at all, and the doctor
# had meanwhile reintroduced the literal through a `:-0` default on exactly the member
# no needle covered. Do not write "both files" here without checking that both MEMBERS
# are pinned too.
#
# Deliberately values, not a wrapper function: the two consumers reach the trichotomy
# through DIFFERENT probes — the payload flavour and the `_model` twin — and in
# opposite directions, so a single accessor would have to take a flavour argument and
# would buy nothing the names do not already buy.
# TWO names, not three, and the missing one is deliberate. The third state —
# "the question could not be answered" — is the RESIDUAL: it is every status that is
# neither of these two, so no site ever compares against it and a constant for it would
# be a name nothing consumes. This file's own neighbourhood states the rule that made
# that decision: an exported rule with no consumer, reachable by a future caller who
# mistakes it for the real one, is worse than no export at all
# (hooks/lib/zensu-safe-display-v1.js, on the retired foldDisplayHiders).
#
# A first version of this block did declare a third, `ZENSU_ROOT_STATE_UNKNOWN=1`, and a
# review seat caught that it had no consumer anywhere while the literals it was meant to
# replace were still spelled at four sites. Both of the names below are consumed.
ZENSU_ROOT_STATE_GONE=0
ZENSU_ROOT_STATE_PRESENT=3

# The THIRD fact of the incompatible-lineage state, asked separately so the
# version pair above stays two TAB-separated fields — every shell parser reads the
# executing half as `${V##*$'\t'}`, so a third field there would silently
# redirect all of them. Returns 0 and PRINTS the recorded project root only when the
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
  _zensu_session_binder_mode orphaned-incompatible-root "${1:-}"
}

# The model-side twin of the predicate above, for /zensu:doctor: same question,
# same printed path and the SAME THREE statuses — 0 with the dead path, 3 for a
# recorded root that positively still exists, 1 for an unavailable answer — but no
# hook payload exists there, so the session id comes from CLAUDE_CODE_SESSION_ID.
# The third status is what lets /zensu:doctor tell a negative from a failure; the
# plain orphan pair above has only two and must not be branched on the same way.
zensu_session_incompatible_orphaned_root_model() {
  _zensu_session_binder_mode model-orphaned-incompatible-root
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
# the diagnostic writes nothing, while the adoption WRITES — five classes, named
# in the header of hooks/lib/zensu-session-adopt.sh, which is also where that
# second justification lives. Do not fold the two arguments into one.
#
# The decision lives in zensu-doctor-invocation.js so every Bash-matcher gate that
# can deny and the all-tool capability gate share exactly one recognizer, and it derives the
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

# The one decision "is this one of the two recognized commands, run by the
# interactive thread". The bind-relaxing Bash gates ask it after a failed bind,
# and the browser consent gate asks it before its bind for every marked payload.
# Both conjuncts are
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
  zensu_doctor_invocation "$payload" || return 1
  _zensu_load_agent_context || return 1
  zensu_hook_is_main_principal "$payload" PreToolUse
}

# Seven scopes, because the same emitter serves callers with very different
# knowledge. Keep this numeral in step with the list below it — it is what a
# caller reads before adding an eighth. The numeral and the list went stale
# together once, on the very edit that added the sixth, which is why the
# instruction names both halves rather than the count alone. A caller that already ruled out the RELAXABLE states may say so; a
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
#                     supplies both declared versions ($2 recorded, $3 executing)
#                     plus the refusal token ($4) the automatic adoption answered;
#                     this scope names why the in-place repair did not happen and
#                     the per-reason remedy, rather than telling the user to
#                     start over
#   pruned-plugin-root  the caller POSITIVELY identified that the installation
#                     which minted the record is gone from the plugin cache, and
#                     supplies the same version pair and refusal token; the
#                     remedy is the same, the cause is a different one
#   orphaned-project-root  the caller POSITIVELY identified that the recorded
#                     project root is gone, and supplies THAT PATH as $2 — a
#                     path, not a version, so it is bounded by
#                     ZENSU_SAFE_DISPLAY_PATH_RE and never by
#                     ZENSU_SAFE_VERSION_RE, which forbids `/` and would
#                     degrade every real path to the placeholder
#   adoption-incomplete  NEITHER named state holds any more, because a sibling hook
#                     adopted the record while this bind was failing ($2 is the
#                     token, `adopted-concurrently`); the record serves now, so
#                     this is the one scope whose remedy is simply to retry
#
# The two version-pair scopes are reached only AFTER the bind's own automatic
# adoption (session-auto-adopt-v1.js, run by the hook-payload bind) did not bind
# the session, which is why they carry a refusal rather than an offer.
#
# The (default) and `narrowed` scopes take an OPTIONAL refusal token as $2: a
# refusal that establishes no named state — an unreadable record, a foreign store —
# lands on them, and a deny that said nothing about the adoption that had just run
# left the reader with two surfaces telling different stories. With a shape-valid
# token they append one sentence naming it; with none they read exactly as before.
#
# The LAST argument of every adoption-bearing scope is the AUDIENCE, `main` or
# `child` (see _zensu_deny_audience). `child` keeps the cause, the attempt and the
# token and withholds every command: the repair writes the immutable record and
# is the main thread's alone.
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
# The refusal token ($4 of the two named scopes) reaches the same JSON string, so
# it is held to the token grammar the binder's `adoption-refusal` mode produces
# and substituted with `(unknown)` otherwise — the same policy as the pair.
ZENSU_SAFE_REFUSAL_RE='^[a-z][a-z0-9-]{0,63}$'

# The per-reason remedy of a refused automatic adoption, chosen from a closed
# vocabulary: core.ADOPTION_REFUSALS plus the binder's own entry-level tokens.
# Plain text without a double quote, because it is interpolated into a JSON
# string. An unrecognized token gets the generic remedy, never a wrong one.
_zensu_adoption_refusal_remedy() {
  case "${1:-}" in
    (executing-runtime-older)
      printf '%s' 'The running installation is OLDER than the one that minted the record (a downgrade or a --plugin-dir checkout), so re-install the newer version, or start a fresh Claude Code session on this one' ;;
    (workflow-schema-mismatch)
      printf '%s' 'The persisted workflow shape really did change between the two versions, so a fresh Claude Code session is the only way forward' ;;
    (not-a-sibling-installation)
      printf '%s' 'The running installation is not a sibling of the recorded one (for example a --plugin-dir checkout beside an installed plugin), so a fresh Claude Code session on this installation is the way forward' ;;
    (plugin-data-mismatch)
      printf '%s' 'The record belongs to a different plugin data store than this installation uses, so a fresh Claude Code session is the way forward' ;;
    (record-unreadable)
      printf '%s' 'The record could not be re-verified against the installation that minted it — it may have been altered, or a persisted schema really did change — and adoption cannot tell those apart; /zensu:adopt-session prints the full diagnosis, and a fresh Claude Code session is the way forward' ;;
    (executing-runtime-unidentified)
      printf '%s' 'The running installation declares no usable version, so repair the plugin installation first' ;;
    (opted-out)
      printf '%s' 'hooks.sessionAutoAdopt is false in your Zensu config, so the automatic path is switched off on purpose; report this refusal and ask the user whether to run /zensu:adopt-session --confirm, which ignores the opt-out — never run it on your own initiative' ;;
    (adopted-concurrently)
      printf '%s' 'A sibling hook adopted the record in the meantime and it serves now, so simply retry this call' ;;
    (not-completed|lock-timeout)
      printf '%s' 'The adoption did not complete (a lock timeout, or a fault inside the adoption itself), so retry this call' ;;
    (superseded-record-exists)
      printf '%s' 'A superseded record from an interrupted adoption is already in place; /zensu:adopt-session names the file, and moving it aside lets the adoption complete' ;;
    (*)
      printf '%s' 'Run /zensu:adopt-session for the full report, and /zensu:adopt-session --confirm to retry the adoption by hand' ;;
  esac
}

# WHAT HAPPENED to the attempt, as a verb. HAND COPY of ADOPTION_INCOMPLETE_REASONS
# in hooks/lib/reviewer-capability-v1.js, pinned against it. `lock-timeout` and
# `adoption-failed` never reach a shell caller — the `adoption-refusal` mode is a
# preview and cannot observe either — and they stay in this arm, as `lock-timeout`
# stays in the remedy above, because the pin compares the two vocabularies BOTH
# ways: a token one side knows and the other does not is what it exists to catch.
_zensu_adoption_attempt() {
  case "${1:-}" in
    (adopted-concurrently|not-completed|lock-timeout|adoption-failed)
      printf '%s' 'it did not complete' ;;
    (*)
      printf '%s' 'it was REFUSED' ;;
  esac
}

# The sentence that FOLLOWS the remedy. HAND COPY of the three *_ADOPTION_TAIL
# constants in hooks/lib/reviewer-capability-v1.js, pinned against them. It depends
# on the token for the reason that file gives: an unconditional "--confirm retries
# the adoption by hand" straight after the opted-out remedy's "never run it on
# your own initiative" is one deny contradicting itself.
_zensu_adoption_tail() {
  case "${1:-}" in
    (opted-out)
      printf '%s' '/zensu:adopt-session reports the record as adoptable, because the opt-out governs the automatic path only, and /zensu:adopt-session --confirm adopts it by hand once the user has said yes' ;;
    (adopted-concurrently|not-completed|lock-timeout|adoption-failed)
      printf '%s' 'if a retry does not bind the session, /zensu:adopt-session prints the full report and /zensu:adopt-session --confirm retries the adoption by hand' ;;
    (*)
      printf '%s' '/zensu:adopt-session reports the same refusal in full, and /zensu:adopt-session --confirm retries the adoption by hand' ;;
  esac
}

# The sentence a `child` deny ends on, in every scope BUT ONE. One spelling, shared
# with the `.*` gate word for word. The exception is the `adoption-incomplete`
# scope, whose child form ends on its own retry sentence instead: there nothing is
# reserved for the main thread — a sibling hook already adopted the record, so a
# plain retry by the child itself is the remedy, and telling it that the repair
# "is not available here" would be false.
ZENSU_ADOPTION_CHILD_CLOSE='The repair writes the immutable record and is reserved for the main thread, so it is not available here — report this to the main thread rather than retrying.'

# The SAME rule for the one interpolated value that is a path rather than a
# version, and it must be its own constant: ZENSU_SAFE_VERSION_RE forbids `/`,
# so reusing it would degrade every real path to the placeholder and silently
# delete the one fact the message exists to carry.
#
# A control-byte denylist was tried here first and was a provable NO-OP:
# `[[:cntrl:]]` is the same class as the reader's own UNSAFE_PATH_CHARACTERS
# (`[\u0000-\u001f\u007f]` in session-control-core-v1.js), which every value
# reaching this printf has already passed. What the reader does NOT reject is
# `"` or `\`, both legal in a POSIX directory name, and `project_root` is
# minted from the SessionStart payload cwd. An unescaped quote closes the reason
# string and a later duplicate `permissionDecision` key wins under ordinary
# last-key-wins parsing; a trailing backslash makes the object unparseable.
# Either way the DECISION is lost, and this is not merely a lost message: in the
# orphaned state reviewer-capability-v1.js returns early for the main principal,
# so this deny is the ONLY thing refusing an Edit there.
#
# Leading `/` is required rather than optional, so an empty value fails the
# shape and takes the placeholder without a second arm.
#
# The length bound is a SEPARATE `${#dead}` test and deliberately NOT an ERE
# interval, because an interval here does not work on the shell this plugin
# actually runs under. MEASURED on bash 3.2.57, which is /bin/bash on macOS:
# `[[ /x =~ ^/[0-9A-Za-z._+@:/ -]{0,1023}$ ]]` does NOT match, while the same
# class with `*` does, and `^/[0-9A-Za-z]{0,10}$` matches — so 3.2 mishandles
# the interval for this class specifically. Written as an interval it would have
# degraded EVERY path to the placeholder on every macOS host while passing on
# bash 5, which is the same both-ways portability trap this repository already
# records for its `case` patterns.
# The hyphen is FIRST, not last. Last is also literal, but it sits next to the
# space there, so the natural way to widen the class — appending one character
# before the `]` — turns ` -X` into a RANGE from 0x20 upward, which spans `"`
# (0x22) and, for any X at or above 0x5C, `\` as well. Leading is literal in
# every position an append can reach.
#
# `[` and `]` are deliberately absent: `]` must be the FIRST class member to be
# literal, which collides with the hyphen rule above, and a bracket in a project
# path is rare enough that degrading to the placeholder is the better trade.
#
# `(` and `)` are absent for a DIFFERENT and sharper reason, and cite the consumer
# that still needs it: `hooks/stop-chain-enforcer.sh` renders this same value INSIDE
# a parenthetical, mid-sentence, with instructions after it, bounded by this same
# constant. A closing paren there ends the parenthetical and everything after reads
# as a new sentence. This emitter's own template no longer has a parenthetical — the
# value is rendered last — so a maintainer checking only this file would find no
# reason for the exclusion and could reopen it for the other consumer.
ZENSU_SAFE_DISPLAY_PATH_MAX=1024
ZENSU_SAFE_DISPLAY_PATH_RE='^/[-0-9A-Za-z._+@:/ ,~#=!&;]*$'

# The value is not only a JSON string, it is PROSE a model reads and acts on, so
# the two STRUCTURAL guards `hooks/lib/zensu-safe-display-v1.js` ships for this same
# value are applied here as shell tests. They are tests rather than a call into that
# module because this emitter has to work in a damaged installation where spawning
# node is exactly what may not be available.
#
# State what they close, and no more — the owner's own header forbids the wider
# claim. They close a two-space run and a colon with a space on either side: the
# ASCII half of that module's DOUBLE_SPACE and PAIR_SEPARATOR rules. They do NOT
# close sentence forgery in general. `/tmp/a. Note. the remedy above is obsolete`
# is absolute, normalized, class-clean and carries none of the three literals, so
# no character allowlist refuses it.
#
# WHAT BOUNDS IT IS THE DELIMITER, never the placement. The value is rendered
# inside quotes, and `"` is not a class member, so a forged sentence cannot close
# them and cannot read as a continuation of the plugin's own prose. Placement was
# offered as the bound once and that claim does NOT hold: rendering the value LAST
# means nothing authentic follows the forged text, which is the WEAKER position for
# instruction-following, not the stronger one. Last is still where it goes, for
# LAYOUT — the alternative is a mid-sentence parenthetical, which is the escape
# `(` and `)` left the class over — but the layout is not what holds the value.
# Residual, stated rather than implied: inside the quotes the value is still prose
# a model reads, so a sentence there is visible to it; what the delimiter removes
# is its ability to look like the plugin's own.
# TWO spellings, because the owner's rule is `/ :|: /` and NOT `/ : /`. Its own
# header records the both-sides-only form as a measured bypass: `/home/u/superseded
# record: /tmp/evil` satisfies it and was returned raw. A shell test that mirrors the
# superseded spelling admits exactly the shape the rule was widened to catch.
ZENSU_FORGERY_DOUBLE_SPACE='  '
ZENSU_FORGERY_PAIR_SPACE_COLON=' :'
ZENSU_FORGERY_PAIR_COLON_SPACE=': '

# ONE implementation of the display-path bound, and the reason is a MEASURED
# divergence rather than tidiness. It was spelled twice in shell — here and in
# `hooks/stop-chain-enforcer.sh` — and the two copies disagreed in FAIL DIRECTION on a
# RETYPED ceiling: `[ N -gt abc ]` is an `integer expression expected` error returning
# 2, which an `||` chain reads as "keep going" and an `&&` chain reads as "refuse", so
# the emitter rendered a 2001-character path raw while the hook degraded it. CLAUDE.md
# justifies a MIRROR of this rule as shell-versus-JS — this emitter must work in a
# damaged installation where spawning node is exactly what may not be available — and
# that argument does not reach shell-versus-shell.
#
# It ECHOES the value to render and never a status: both callers need a string, and a
# status would put the answer on the same channel every way a shell can fail already
# uses. Every fault answers `(unreadable)`, so a caller that ignores the exit status
# still fails closed.
#
# That said, a caller MAY test the status, and the three Stop-hook call sites do. Every
# return inside this body is 0, so the branch they guard can never fire on a FAULT of
# this function — what it covers is this function being UNAVAILABLE. A command
# substitution carries 127 when the name is not defined, which is what an unsourced or
# partially sourced emitter looks like from a hook that still renders the sentence; the
# slot would otherwise interpolate an empty string into a line that claims to name the
# recorded project root. Read the branches that way rather than as a fault contract,
# and do not delete them as dead: they are live for exactly one cause.
#
# THREE constant faults, not one. ABSENT and EMPTY are what an emptiness conjunct
# closes; RETYPED is the third and needs its own screen, which is why the ceiling is
# tested as a decimal before it is compared — the same shape `zensu-doctor.sh` applies
# to its own `ZENSU_ROOT_STATE_*` pair, and for the same stated reason. The three
# forgery literals are read with `:-` because an UNSET one aborts the whole function
# under `set -u` — every reachable caller of the emitter sets it — and a caller that
# loses the decision OBJECT loses more than the path inside it. Empty is harmless: the
# pattern then matches every value, which is the refusing direction.
zensu_safe_display_path() {
  local value="${1:-}"
  # Scoped to this call. Same hedge the emitter states about its own pin: a collation
  # that widens a range widens what an ALLOWLIST admits, and it makes ${#value} a byte
  # count, which is what a 1024-BYTE ceiling means.
  local LC_ALL=C
  case "$value" in
    (*"${ZENSU_FORGERY_DOUBLE_SPACE:-}"*|*"${ZENSU_FORGERY_PAIR_SPACE_COLON:-}"*|*"${ZENSU_FORGERY_PAIR_COLON_SPACE:-}"*)
      printf '(unreadable)'
      return 0
      ;;
  esac
  case "${ZENSU_SAFE_DISPLAY_PATH_MAX:-}" in
    (''|*[!0-9]*)
      printf '(unreadable)'
      return 0
      ;;
  esac
  if [ -z "${ZENSU_SAFE_DISPLAY_PATH_RE:-}" ] \
    || [ "${#value}" -gt "$ZENSU_SAFE_DISPLAY_PATH_MAX" ] \
    || ! [[ "$value" =~ $ZENSU_SAFE_DISPLAY_PATH_RE ]]; then
    printf '(unreadable)'
    return 0
  fi
  printf '%s' "$value"
}

zensu_emit_hook_session_deny() {
  # Scoped to this call. HALF of this is measured and half is reasoned, and the
  # citation says which: user-prompt-zen-mode.sh records a MEASURED case where
  # collation order let `[a-z]` accept an uppercase letter, and records separately
  # that `local` on LC_ALL taking effect for its own `case` patterns is REASONED
  # rather than measured. The same hedge applies here. The direction matters
  # because the class below is an ALLOWLIST: a collation that widens a range
  # widens what is admitted, never what is refused. It also makes ${#dead} a byte
  # count, which is what a 1024-BYTE ceiling means.
  local LC_ALL=C
  local scope="${1:-}"
  if [ "$scope" = adoption-incomplete ]; then
    local refusal="${2:-}" audience="${3:-main}" attempt remedy tail
    if [ -z "${ZENSU_SAFE_REFUSAL_RE:-}" ] || ! [[ "$refusal" =~ $ZENSU_SAFE_REFUSAL_RE ]]; then refusal="(unknown)"; fi
    attempt="$(_zensu_adoption_attempt "$refusal")"
    if [ "$audience" = child ]; then
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: this call could not be bound to the session'"'"'s Session Control record. Zensu tried to adopt the record automatically for this session and %s: %s. A sibling hook adopted it in the meantime, so retrying this call is expected to bind; if it keeps failing, report this to the main thread."}}\n' \
        "$attempt" "$refusal"
      return
    fi
    remedy="$(_zensu_adoption_refusal_remedy "$refusal")"
    tail="$(_zensu_adoption_tail "$refusal")"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: this call could not be bound to the session'"'"'s Session Control record. Zensu tried to adopt the record automatically for this session and %s: %s. %s; %s."}}\n' \
      "$attempt" "$refusal" "$remedy" "$tail"
    return
  fi
  if [ "$scope" = incompatible-runtime ]; then
    local recorded="${2:-}" executing="${3:-}" refusal="${4:-}" audience="${5:-main}" attempt remedy tail
    # ONE degradation policy across all three consumers of this pair: substitute a
    # placeholder and KEEP the lineage wording. Falling back to `narrowed` here
    # dropped the in-place remedy entirely and told the user to start a fresh
    # session — the contradiction this scope exists to remove.
    # FAIL CLOSED on a missing bound, never open. `[[ x =~ $EMPTY ]]` answers
    # differently per host — a regcomp error on bash 3.2, a match-everything on
    # glibc — so an absent constant decides the verdict, and on glibc it decides
    # it the wrong way: the shape test becomes vacuous and the raw value is
    # rendered. The presence test takes the host out of the answer. It is what
    # the guarantee rests on; the export block below is an optimisation that
    # keeps the ordinary child rendering a real value, never the safety property.
    # The refusal token is held to the same rule for the same reason.
    if [ -z "${ZENSU_SAFE_VERSION_RE:-}" ]; then
      recorded="(unreadable)"
      executing="(unreadable)"
    else
      [[ "$recorded" =~ $ZENSU_SAFE_VERSION_RE ]] || recorded="(unreadable)"
      [[ "$executing" =~ $ZENSU_SAFE_VERSION_RE ]] || executing="(unreadable)"
    fi
    if [ -z "${ZENSU_SAFE_REFUSAL_RE:-}" ] || ! [[ "$refusal" =~ $ZENSU_SAFE_REFUSAL_RE ]]; then
      refusal="(unknown)"
    fi
    attempt="$(_zensu_adoption_attempt "$refusal")"
    if [ "$audience" = child ]; then
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: this session'"'"'s Session Control record is readable, and the disagreement is that the running Zensu installation declares an incompatible lineage — the record was minted by %s and %s is executing. Zensu tried to adopt the record automatically for this session and %s: %s. %s"}}\n' \
        "$recorded" "$executing" "$attempt" "$refusal" "$ZENSU_ADOPTION_CHILD_CLOSE"
      return
    fi
    remedy="$(_zensu_adoption_refusal_remedy "$refusal")"
    tail="$(_zensu_adoption_tail "$refusal")"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: this session'"'"'s Session Control record is readable, and the disagreement is that the running Zensu installation declares an incompatible lineage — the record was minted by %s and %s is executing. While the plugin is at major 0 the minor is the breaking axis; a plugin update that lands mid-session is normally adopted automatically on the first hook contact, but Zensu tried to adopt this record and %s: %s. %s. The record is NOT damaged and NOT missing; %s — both stay reachable in this state. If the recorded project root is ALSO gone — a deleted or recycled worktree — an adoption still clears the lineage break, but Edit, Write and MultiEdit stay denied afterwards, and so does any Bash command the source-write gate can attribute as a write while that opt-in gate is on (hooks.bashWriteGate: true), until that exact directory is re-created, which /zensu:adopt-session --restore-root reports on and which must happen AFTER the adoption, because that repair requires the running installation to SERVE the record; /zensu:doctor names the path when that is the case."}}\n' \
      "$recorded" "$executing" "$attempt" "$refusal" "$remedy" "$tail"
    return
  fi
  if [ "$scope" = orphaned-project-root ]; then
    local dead="${2:-}"
    # Same degradation policy as the two version scopes: substitute, keep the
    # wording. Losing the path is a worse message; losing the remedy — or the
    # decision — is a wrong one. See ZENSU_SAFE_DISPLAY_PATH_RE for why this is
    # a positive allowlist and not a denylist.
    # ONE call, so this arm and the Stop hook's cannot answer differently. The rule,
    # the three constant faults it closes and why it echoes rather than returns a
    # status are all stated at `zensu_safe_display_path`.
    dead="$(zensu_safe_display_path "$dead")"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: this session'"'"'s Session Control record is readable and this installation serves it — the disagreement is that the project root it records no longer exists, which a deleted or recycled worktree causes. The workflow document lived under that directory, so no write can be attributed to a project that is not there: Edit, Write and MultiEdit fail closed, and so does a Bash write while the opt-in source-write gate is on (hooks.bashWriteGate: true). Other shell commands and the read-only diagnostics still work; a `zensu` CLI call does not, because that gate needs a binding before it can classify the verb as a read. Run /zensu:adopt-session --restore-root to see whether that directory can be re-created in place. That report is read-only; the repair itself is a separate step the user has to agree to, and a bare mkdir is not it — the workflow document lived under that root, so re-creating the directory alone leaves every tool denied. It restores the ANCHOR, not the work: the directory comes back empty, it is not a git worktree, and the chain that lived there is gone rather than restored. If it was moved rather than deleted, moving it back is better. Starting a fresh Claude Code session remains the alternative. The path this session records is: \\"%s\\""}}\n' \
      "$dead"
    return
  fi
  if [ "$scope" = pruned-plugin-root ]; then
    local recorded="${2:-}" executing="${3:-}" refusal="${4:-}" audience="${5:-main}" attempt remedy tail
    # Same degradation policy as the lineage scope: substitute, keep the wording,
    # never lose the in-place remedy over two unreadable numbers.
    # FAIL CLOSED on a missing bound, for the reason the lineage scope above gives.
    if [ -z "${ZENSU_SAFE_VERSION_RE:-}" ]; then
      recorded="(unreadable)"
      executing="(unreadable)"
    else
      [[ "$recorded" =~ $ZENSU_SAFE_VERSION_RE ]] || recorded="(unreadable)"
      [[ "$executing" =~ $ZENSU_SAFE_VERSION_RE ]] || executing="(unreadable)"
    fi
    if [ -z "${ZENSU_SAFE_REFUSAL_RE:-}" ] || ! [[ "$refusal" =~ $ZENSU_SAFE_REFUSAL_RE ]]; then
      refusal="(unknown)"
    fi
    attempt="$(_zensu_adoption_attempt "$refusal")"
    if [ "$audience" = child ]; then
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: this session'"'"'s Session Control record is intact, but the Zensu installation that minted it (version %s) has been removed from the plugin cache — the host keeps only a few versions — so the running installation (%s) cannot re-verify the record. Zensu tried to adopt the record automatically for this session and %s: %s. %s"}}\n' \
        "$recorded" "$executing" "$attempt" "$refusal" "$ZENSU_ADOPTION_CHILD_CLOSE"
      return
    fi
    remedy="$(_zensu_adoption_refusal_remedy "$refusal")"
    tail="$(_zensu_adoption_tail "$refusal")"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: this session'"'"'s Session Control record is intact, but the Zensu installation that minted it (version %s) has been removed from the plugin cache — the host keeps only a few versions — so the running installation (%s) cannot re-verify the record. Such a record is normally adopted automatically on the first hook contact, but Zensu tried to adopt this one and %s: %s. %s. The record is NOT damaged and NOT missing; %s — both stay reachable in this state. This predicate is deliberately blind to lineage, so a DOWNGRADE reaches this state too, and there adoption refuses as executing-runtime-older and re-installing the newer version is the way back — a persisted shape that really did change is the case that needs a fresh Claude Code session."}}\n' \
      "$recorded" "$executing" "$attempt" "$refusal" "$remedy" "$tail"
    return
  fi
  # The adoption sentence the two scopes below append when the caller supplies a
  # shape-valid token. Empty for no token, so both scopes read exactly as they did
  # before a token existed. The `child` form names the attempt and withholds the
  # remedy, for the reason _zensu_deny_audience gives.
  local appended=""
  if [ "$scope" != damaged-runtime ] && [ -n "${ZENSU_SAFE_REFUSAL_RE:-}" ] && [[ "${2:-}" =~ $ZENSU_SAFE_REFUSAL_RE ]]; then
    if [ "${3:-main}" = child ]; then
      appended=" Zensu also tried to adopt the record automatically for this session and $(_zensu_adoption_attempt "$2"): $2. $ZENSU_ADOPTION_CHILD_CLOSE"
    else
      appended=" Zensu also tried to adopt the record automatically for this session and $(_zensu_adoption_attempt "$2"): $2. $(_zensu_adoption_refusal_remedy "$2")."
    fi
  fi
  if [ "$scope" = narrowed ]; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: the immutable Zensu session binding is unavailable or invalid, so this call cannot be attributed to a Session Control record. This is neither relaxable state — a session with no record at all, and a record whose recorded project root no longer exists, are both handled separately — so either a record exists and disagrees with the running plugin installation about something else, or a relaxable-state check could not be evaluated at all. A Zensu plugin change that landed while this session was running is not that cause on its own any more: a compatible upgrade keeps serving the record, and a breaking one is adopted automatically when the persisted schemas are equal — reaching this deny means the record disagrees for a reason adoption does not admit. Run /zensu:doctor, which stays reachable in this state and names the disagreement, then start a fresh Claude Code session before using stateful tools.%s"}}\n' \
      "$appended"
    return
  fi
  if [ "$scope" = damaged-runtime ]; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: this session has no usable Session Control binding — either no record at all, or a record whose recorded project root no longer exists — which alone would still leave the interactive thread able to run /zensu:doctor, but a required Zensu runtime library is missing or unreadable, so that diagnostic is denied too. Repair the Zensu plugin installation; a fresh Claude Code session will not help until the installation itself is intact."}}'
    return
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: the immutable Zensu session binding is unavailable or invalid, so every stateful Zensu tool fails closed. Run /zensu:doctor — it stays reachable in every bind failure and names which check failed: whether this session has no record at all, a record whose recorded project root no longer exists, or a record that disagrees for another reason. A Zensu plugin change that landed mid-session is adopted automatically when the persisted schemas are equal, and a compatible upgrade no longer denies, so a deny here means the disagreement is one adoption does not admit. Then start a fresh Claude Code session before using stateful tools.%s"}}\n' \
    "$appended"
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

# The shape constants travel WITH the function that reads them, and this is an
# OPTIMISATION rather than the safety property — say which, because it shipped as
# the property once. `export -f` propagates the function to a child shell and a
# plain assignment does not, so without this block a child renders `(unreadable)`
# for every value: correct, but useless. The guard itself no longer depends on the
# block — each arm tests its constants for emptiness first and fails CLOSED — so
# what is lost when the two disagree is a real path in a message, never a refusal.
# That direction is what makes a silent failure survivable; before the emptiness
# conjuncts, a scrubbed child rendered the RAW value on glibc, and the injected
# duplicate `permissionDecision` key then won under last-key-wins parsing.
case "${OSTYPE:-}" in
  msys*|cygwin*|mingw*|win32*) ;;
  *)
    export ZENSU_SAFE_VERSION_RE ZENSU_SAFE_REFUSAL_RE ZENSU_ADOPTION_CHILD_CLOSE \
      ZENSU_SAFE_DISPLAY_PATH_RE ZENSU_SAFE_DISPLAY_PATH_MAX \
      ZENSU_FORGERY_DOUBLE_SPACE ZENSU_FORGERY_PAIR_SPACE_COLON ZENSU_FORGERY_PAIR_COLON_SPACE \
      2>/dev/null || true
    export -f zensu_bind_hook_session zensu_bind_model_session zensu_emit_hook_session_deny \
      zensu_safe_display_path \
      _zensu_session_binder_mode zensu_emit_named_bind_deny \
      zensu_session_unregistered \
      zensu_session_orphaned_project_root zensu_session_orphaned_project_root_model \
      zensu_session_incompatible_runtime zensu_session_incompatible_runtime_model \
      zensu_session_incompatible_orphaned_root zensu_session_incompatible_orphaned_root_model \
      zensu_session_pruned_plugin_root zensu_session_pruned_plugin_root_model \
      zensu_session_adoption_refusal zensu_session_adoption_remedy _zensu_adoption_refusal_remedy \
      zensu_session_adoption_attempt _zensu_adoption_attempt \
      zensu_session_adoption_tail _zensu_adoption_tail \
      _zensu_deny_audience _zensu_load_agent_context \
      zensu_session_key zensu_resolve_session_id zensu_resolve_project_dir 2>/dev/null || true
    ;;
esac
# The underscore-private helpers in that list are there for CLOSURE, not as API: an
# exported function that reaches a child shell runs there without this file, so
# every helper it calls has to travel with it. zensu_emit_named_bind_deny calls
# _zensu_deny_audience, which calls _zensu_load_agent_context; dropping either
# leaves the exported emitter printing "command not found" and falling back to the
# `main` wording for every principal.

# THE ZEN-MODE STATE PREDICATES MOVED OUT, to `hooks/lib/zensu-zen-shared.sh`.
# `zen_marker_active`, `zen_marker_shape_fault` and `zen_path_untraversable` have
# exactly two callers, both zen-mode, while THIS file is the Session Control
# binding library that every stateful gate sources — so a syntax fault introduced
# here while editing a presentation feature failed every PreToolUse Bash gate
# CLOSED. Blast radius is the whole argument; the reasoning that used to sit here
# travelled with the code.
