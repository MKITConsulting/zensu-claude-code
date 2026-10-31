#!/bin/bash
# zensu-zen-shared.sh — the state predicates and the resolution ladder every
# zen-mode reader needs.
#
# WHY THIS FILE EXISTS, stated because the alternative looked cheaper and was
# worse. These three predicates lived in `hooks/lib/zensu-session.sh`, which is
# the Session Control binding library: it is sourced by every stateful gate in
# the tree, including `pre-bash-zensu-gate.sh`, `pre-bash-source-write-gate.sh`,
# `pre-write-secret-scan.sh`, `pre-edit-tdd-reminder.sh` and
# `stop-chain-enforcer.sh`. A syntax fault introduced there while editing a
# PRESENTATION feature fails every PreToolUse Bash gate CLOSED — a blast radius
# with no relationship to what was being changed. They have three callers,
# `hooks/user-prompt-zen-mode.sh`, `hooks/lib/zensu-zen-mode.sh` and the zen-mode
# probe in `hooks/lib/zensu-doctor.sh`, and each already sources other libraries,
# so this costs one line each.
#
# Do NOT collapse this into `hooks/lib/zensu-zen-mode.sh`: that file DISPATCHES
# and `exit`s at file scope, so sourcing it to reach a predicate runs a verb.
#
# The argument for the move is BLAST RADIUS ALONE. An earlier draft also claimed
# these were the only functions the binding library omits from its `export -f`
# list; that is false — the list names eleven and the file defines fifteen — and
# the claim is recorded here as retired so it is not restored as support.

# --- The marker's ACTIVE question. ONE owner, three consumers. ---------------
#
# The pattern was hand-spelled three times: the hook's resolution ladder, the
# hook's off-write verification, and the helper's own `--status` verb. Nothing
# compared them, so a one-sided widening — accepting `"active" : true`, say —
# would make the verification report COULD NOT BE DEACTIVATED for a marker the
# resolution honours, or make `--status` answer differently from the hook that
# actually injects. Two readers of one state disagreeing is the failure this
# repository already refuses elsewhere; the verification is the RESOLUTION's own
# question negated, and that is only true while there is one question.
#
# Callers own the CONSEQUENCE, never the pattern: the hook exits, the
# verification reports, `--status` prints, the doctor renders. Only the question
# lives here.
zen_marker_active() { # $1 marker path
  grep -q '"active"[[:space:]]*:[[:space:]]*true' "$1" 2>/dev/null
}

# --- Marker SHAPE, with the reason on stdout. --------------------------------
#
# Returns 0 and prints the cause when the marker or its directories are a shape
# neither carrier may honour; returns 1 when the shape is acceptable. The reason
# travels on STDOUT because a caller inside a PreToolUse hook must capture it
# into a variable before emitting anything — that hook's stdout is its JSON
# decision channel, so this value can never simply be let through.
#
# The CONSEQUENCE stays per caller: the hook resolves the mode OFF, because
# unreadable state must never impose it, while the writer refuses.
zen_marker_shape_fault() {  # $1 .zensu dir, $2 state dir, $3 marker
  if [ -L "$1" ] || [ -L "$2" ] || [ -L "$3" ]; then
    printf '%s' "refusing to follow a symlinked state path — remove $3 and its directory link by hand"
    return 0
  fi
  if [ -e "$3" ] && [ ! -f "$3" ]; then
    printf '%s' "$3 is not a regular file — remove it by hand"
    return 0
  fi
  return 1
}

# --- Is any component between the ceiling and the leaf unsearchable? ---------
#
# EVERY component is walked, not just the leaf. `test -L`, `-e` and `-f` all fail
# with EACCES on a path under an unsearchable directory, so a leaf-only check
# could not fire in the very case that reaches it from one component up: control
# then fell through to the configured default, which ships TRUE, and a marker
# recording `{"active":false}` was ignored on every prompt.
zen_path_untraversable() {
  _zpu_leaf="$1"
  _zpu_ceiling="$2"
  case "$_zpu_leaf" in
    "$_zpu_ceiling"/*) _zpu_rest="${_zpu_leaf#"$_zpu_ceiling"/}" ;;
    *) return 1 ;;
  esac
  _zpu_at="$_zpu_ceiling"
  if [ -d "$_zpu_at" ] && [ ! -x "$_zpu_at" ]; then return 0; fi
  while [ -n "$_zpu_rest" ]; do
    case "$_zpu_rest" in
      */*) _zpu_seg="${_zpu_rest%%/*}"; _zpu_rest="${_zpu_rest#*/}" ;;
      *)   _zpu_seg="$_zpu_rest";      _zpu_rest="" ;;
    esac
    [ -n "$_zpu_seg" ] || continue
    _zpu_at="$_zpu_at/$_zpu_seg"
    [ -n "$_zpu_rest" ] || break
    if [ -d "$_zpu_at" ] && [ ! -x "$_zpu_at" ]; then return 0; fi
  done
  return 1
}

zen_marker_path() {
  ZEN_MARKER_PATH="$1/.zensu/state/zen-mode-$2.json"
}

zen_marker_inactive() {
  grep -q '"active"[[:space:]]*:[[:space:]]*false' "$1" 2>/dev/null
}

# Two readers of one state must not disagree, and `--status` is the surface a user
# consults exactly when the mode misbehaves: without the permission arm `[ -f ]`
# failed with EACCES on an unsearchable ancestor and `--status` reported the
# configured default - `on` by default - for a session the hook resolves OFF and
# injects nothing into.
zen_mode_resolve() {
  zen_marker_path "$1" "$2"
  ZEN_MODE_WHY=""
  # A PRESENT-BUT-NOT-REGULAR marker resolves to OFF, and that arm is not tidiness.
  # Without it a FIFO planted at the marker is neither a symlink nor a regular file,
  # so both type tests are false and control falls through to the CONFIGURED
  # DEFAULT, which ships TRUE — so unreadable state IMPOSED the mode, which is the
  # exact opposite of what the hook's header promises. Worse, it then reached the
  # hook's off-phrase write, and a shell redirect opens a FIFO with no reader
  # BLOCKING: the one in-band way out of the mode wedged the session on a path the
  # user cannot see. `-e` is what distinguishes a present non-regular file from an
  # absent one; the `-L` arm already took every symlink, including a dangling one.
  # The shape arm sits ABOVE the `[ -f ]` arm on purpose: `-f` follows a symlink, so
  # a link to a non-regular target would otherwise fall through to the configured
  # default and be reported `on`.
  if ZEN_MODE_WHY="$(zen_marker_shape_fault "$1/.zensu" "$1/.zensu/state" "$ZEN_MARKER_PATH")"; then
    ZEN_MODE_SOURCE=shape
    return 1
  fi
  ZEN_MODE_WHY=""
  if [ -f "$ZEN_MARKER_PATH" ]; then
    # ACCEPTED RESIDUAL, stated here rather than left to be rediscovered: this read
    # runs on every prompt while the mode is on, where the hook's off-write
    # read-back runs only on an off phrase. `zen_marker_active` RE-RESOLVES the path
    # after the type tests above, follows a symlink, and opens a FIFO BLOCKING. The
    # persistent plant is closed by the arms above; the RACED one is not - anything
    # with write access to `.zensu/state/`, which is in-session by construction, can
    # rename a FIFO or a symlink into place between the tests and this read. What
    # bounds it in the hook is the `"timeout": 20` on its registration, and losing
    # that turn loses the whole directive. DELIBERATELY NOT wrapped in
    # `zensu_run_bounded` either: this is the hottest path in the plugin, and the
    # shared watchdog ladder's own deadline plus the child would approach the
    # registration timeout rather than stay under it. The strongest fix is a single
    # bounded child that opens with `O_NOFOLLOW|O_NONBLOCK` and reads from that
    # descriptor, which is what `readRegularFileSnapshot` already does one directory
    # over - deliberately NOT taken, because it puts a `node` spawn on that same
    # hottest path, on every prompt of every zen-mode session. The symlink variant
    # leaks a read rather than a write: the off-phrase writer re-`lstat`s and
    # refuses a non-regular target.
    # A marker that is unreadable or does not spell out an active mode counts as
    # off: an unparsable state file must never impose the mode on a user who may
    # have just left it.
    ZEN_MODE_SOURCE=marker
    zen_marker_active "$ZEN_MARKER_PATH"
    return
  fi
  # A NON-TRAVERSABLE state directory is not an absent marker. Every test above
  # uses lstat or stat, all of them fail with EACCES, and the fall-through then
  # took the configured default, which ships TRUE - so a marker recording
  # `{"active":false}` was ignored and the mode was re-imposed on every prompt.
  #
  # BOTH COMPONENTS are tested, exactly as the symlink arm above tests both. The
  # first spelling covered the leaf only, so an unsearchable `.zensu` made every
  # test in the ladder - including this arm`s own `[ -d ]` - fail for EACCES, and
  # control reached the default again. The leaf-only arm could not fire in the
  # very case that reaches it from one component up. `zen_path_untraversable`
  # walks EVERY component from the ceiling down and owns the `[ -d ]` test; this
  # arm supplies the ceiling and reads the verdict.
  # The ladder already knows the right answer one arm up: an unreadable MARKER
  # resolves OFF. Only the unreadable DIRECTORY fell the wrong way, against the
  # invariant the hook's header states.
  #
  # IT SITS AFTER THE MARKER ARMS. Testing it first diverged for a process that CAN
  # traverse a mode-000 directory (root, CAP_DAC_OVERRIDE): the hook read and
  # honoured the marker while `--status` answered "not searchable" - the
  # disagreement the arm exists to prevent.
  if zen_path_untraversable "$ZEN_MARKER_PATH" "$1"; then
    ZEN_MODE_SOURCE=untraversable
    return 1
  fi
  ZEN_MODE_SOURCE=default
  zensu_zen_mode_default_on
}
