#!/bin/bash
# Written through a sibling temp file and renamed into place. A redirect onto the
# marker path would FOLLOW a symlink planted between the first guard and the
# write; rename replaces the link itself, so the marker leaf cannot be used to
# redirect the write out of the state directory, and the guard is re-asserted
# immediately before the rename.
#
# The TEMP leaf needs the same care, and a predictable `.tmp.$$` name does not
# give it: a co-writer of the state directory can pre-plant a symlink at that
# name and a `>` redirect follows it, which merely moves the window rather than
# closing it. `mktemp` creates with O_EXCL under an unguessable name — the same
# primitive `zensu-autopilot-state.sh` uses for the documents in this very
# directory — and the link check is applied to it too.
zensu_write_session_marker() {
  local name="$1" project_dir="$2" marker="$3" line="$4" state_dir tmp
  state_dir="$(dirname "$marker")"
  # The component list lives ONCE, in zensu_tdd_mode_state_linked beside the path
  # template, and both the reader and this writer call it — `.zensu` is checked
  # alongside `state` and the marker because the project root itself is canonicalized
  # by Session Control, so `.zensu` is the one remaining component a checked-out tree
  # could carry as a link, and a link there relocates the whole state directory while
  # both leaf checks stay false.
  if zensu_tdd_mode_state_linked "$project_dir" "$marker"; then
    echo "$name: refusing to follow a symlinked state path — remove $marker and its directory link by hand" >&2
    exit 2
  fi
  mkdir -p -m 700 "$state_dir" 2>/dev/null || {
    echo "$name: cannot create state directory $state_dir" >&2
    exit 2
  }
  tmp="$(mktemp "$marker.tmp.XXXXXX" 2>/dev/null)" || tmp=""
  [ -n "$tmp" ] || {
    echo "$name: cannot create a temporary file beside $marker" >&2
    exit 2
  }
  # EXIT alone cleans up; a signal only EXITS, and the exit runs that cleanup. A
  # cleanup handler on the signals themselves returned into this function, which then
  # resumed the write and could re-create the temp leaf through a plain redirect,
  # without O_EXCL.
  trap 'rm -f "$tmp" 2>/dev/null' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  # The mktemp name is unguessable but observable by readdir, so a same-UID co-tenant
  # can swap a link in between mktemp and the redirect below. This `-L` test narrows
  # that window; it does not close it. The closing form, an O_NOFOLLOW|O_EXCL open,
  # costs a node spawn on every write and is deliberately not taken.
  if [ -L "$tmp" ]; then
    echo "$name: refusing to write through a symlinked temp leaf $tmp — remove it by hand" >&2
    exit 2
  fi
  printf '%s\n' "$line" > "$tmp" || {
    echo "$name: cannot write $tmp" >&2
    exit 2
  }
  # Re-assert every component the RENAME depends on, including the temp leaf. This
  # is deliberately a SECOND call of the shared predicate rather than a shared
  # result — the duplication is the TOCTOU defense, and only the component list is
  # shared. Note what it does and does not cover: the write on the line above has
  # already happened, so what this prevents is a misdirected rename, not a
  # misdirected write. `mktemp` creates the temp leaf with O_EXCL, which is what
  # keeps that window narrow; it does not close it.
  if zensu_tdd_mode_state_linked "$project_dir" "$marker" "$tmp"; then
    echo "$name: refusing to follow a symlinked state path — remove $marker and its directory link by hand" >&2
    exit 2
  fi
  # An existing non-regular marker (a directory above all) would swallow the
  # rename and report success, leaving the user told a choice landed that the
  # reader will never see.
  if [ -e "$marker" ] && [ ! -f "$marker" ]; then
    echo "$name: $marker exists and is not a regular file — remove it by hand" >&2
    exit 2
  fi
  mv -f "$tmp" "$marker" || {
    echo "$name: cannot write $marker" >&2
    exit 2
  }
  # Post-condition, because the non-regular check above is a check-then-use: a
  # DIRECTORY swapped in after it makes `mv -f` move the temp INTO that directory and
  # return 0, which would print the success line with nothing recorded at the marker
  # path. Refuse rather than claim.
  if [ ! -f "$marker" ] || [ -L "$marker" ]; then
    echo "$name: $marker did not land as a regular file — something was swapped in at that path during the write; remove it by hand" >&2
    exit 2
  fi
  trap - EXIT INT TERM HUP
}
