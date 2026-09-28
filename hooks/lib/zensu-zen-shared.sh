#!/bin/bash
# zensu-zen-shared.sh — the state predicates BOTH zen-mode carriers need.
#
# WHY THIS FILE EXISTS, stated because the alternative looked cheaper and was
# worse. These three predicates lived in `hooks/lib/zensu-session.sh`, which is
# the Session Control binding library: it is sourced by every stateful gate in
# the tree, including `pre-bash-zensu-gate.sh`, `pre-bash-source-write-gate.sh`,
# `pre-write-secret-scan.sh`, `pre-edit-tdd-reminder.sh` and
# `stop-chain-enforcer.sh`. A syntax fault introduced there while editing a
# PRESENTATION feature fails every PreToolUse Bash gate CLOSED — a blast radius
# with no relationship to what was being changed. They have exactly two callers,
# `hooks/user-prompt-zen-mode.sh` and `hooks/lib/zensu-zen-mode.sh`, and both
# already source two libraries, so this costs one line each.
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
# hook's off-write verification, and this library's own `--status` verb. Nothing
# compared them, so a one-sided widening — accepting `"active" : true`, say —
# would make the verification report COULD NOT BE DEACTIVATED for a marker the
# resolution honours, or make `--status` answer differently from the hook that
# actually injects. Two readers of one state disagreeing is the failure this
# repository already refuses elsewhere; the verification is the RESOLUTION's own
# question negated, and that is only true while there is one question.
#
# Callers own the CONSEQUENCE, never the pattern: the resolver exits, the
# verification reports, `--status` prints. Only the question lives here.
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
