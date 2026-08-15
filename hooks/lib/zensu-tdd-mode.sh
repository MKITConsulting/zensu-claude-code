#!/bin/bash
# zensu-tdd-mode.sh — session-scoped strict/vanilla switch for the /zensu:tdd
# implementation discipline. `--strict`, `--vanilla` and `--auto` WRITE the
# session marker in the project's ephemeral state directory
# (`{"mode":"strict"}` / `{"mode":"vanilla"}` / `{"mode":"auto"}`); `--status`
# reports the resolved mode and where it came from.
#
# The marker is read where a chain generation's mode is FROZEN, and there are two
# such points: `zensu-log.sh --tdd-begin` (every ordinary arm) and the Stop-hook
# adoption of a deferred review, which seeds the same `vanilla` flag through
# `tdd_seed_deferred_review` for a chain that has no prior state to freeze from.
# Switching therefore governs the NEXT chain and never the running one — the
# frozen flag is what the edit gate reads, so no mid-chain flip can un-gate a
# strict session or re-arm a vanilla one. The precedence both points apply is:
#   1. this session marker  2. `--tdd-begin --tdd-mode strict` (a skill's own
#   default, e.g. /zensu:pr-fix-findings; escalation only)
#   3. hooks.tddImplementation  4. vanilla
# so a user's explicit session choice is never overruled by a skill, and rank 2
# can only RAISE the discipline — the value travels through a model-read spec
# line, and a spec body is not always user-authored.
#
# `--auto` WRITES `{"mode":"auto"}` rather than deleting the marker. Absence and
# `auto` resolve identically (no override), but writing keeps `--status` able to
# tell a deliberate release from a choice that was never made, and the writer
# never has to distinguish the two. (No /zensu:doctor row reads the marker yet —
# a known gap, not a claim this file gets to make.)
#
# Choosing vanilla here is a MODE choice, not a gate escape: vanilla is the
# shipped default of hooks.tddImplementation, so this writes no bypass-ledger
# entry — the ledger records gate bypasses only, and everything it renders under
# "Gates bypassed" must stay true. Narrow reading on purpose: in a project that
# set hooks.tddImplementation:true, a vanilla marker DOES lower an explicit policy,
# and the only signal is this session's `--tdd-begin` echo plus `--status`. That
# is a deliberate trade (the alternative is a ledger entry for the shipped
# default), and the missing provenance surface is the known /zensu:doctor gap
# recorded in CLAUDE.md — not something this file may claim is covered.
#
# Session binding follows the model-invocation path zensu-log.sh uses: the helper
# must run from Claude Code's own Bash tool, which supplies CLAUDE_CODE_SESSION_ID
# and CLAUDE_PLUGIN_DATA. SessionStart deliberately exports no Zensu selectors, so
# there is no environment variable to read instead. The marker is keyed by the
# resolved Session Control key, so a fresh session always starts from the
# configured default and one session's choice can never leak into another.
set -u

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)" || exit 2
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

TDD_MODE_VERB="${1:-}"
case "$TDD_MODE_VERB" in
  --strict|--vanilla|--auto|--status) ;;
  *)
    echo "usage: zensu-tdd-mode.sh --strict | --vanilla | --auto | --status" >&2
    exit 2
    ;;
esac

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
if ! zensu_bind_model_session; then
  echo "zensu-tdd-mode.sh: rendered Session Control binding unavailable" >&2
  if [ -z "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    echo "zensu-tdd-mode.sh: CLAUDE_CODE_SESSION_ID is not set — this helper must run from Claude Code's own Bash tool, which supplies the host session id." >&2
  fi
  if [ -z "${CLAUDE_PLUGIN_DATA:-}" ]; then
    echo "zensu-tdd-mode.sh: CLAUDE_PLUGIN_DATA is not set — run this helper exactly as the tdd-mode skill renders it, including its leading 'CLAUDE_PLUGIN_DATA=...' assignment; never hand-build the command." >&2
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "zensu-tdd-mode.sh: node is not on PATH — Session Control cannot bind without it." >&2
  fi
  exit 2
fi
if ! _zensu_pd="$(zensu_resolve_project_dir)" || [ -z "$_zensu_pd" ]; then
  echo "zensu-tdd-mode.sh: Session Control project context unavailable" >&2
  exit 2
fi
if ! _zensu_sid="$(zensu_resolve_session_id)" || [ -z "$_zensu_sid" ]; then
  echo "zensu-tdd-mode.sh: Session Control session identity unavailable" >&2
  exit 2
fi

# The marker path template and the parse both live in zensu-config.sh, so the
# writer here and the reader in `--tdd-begin` can never drift apart.
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"

TDD_MODE_PROJECT_DIR="$_zensu_pd"
TDD_MODE_SESSION_KEY="$_zensu_sid"
if ! TDD_MODE_MARKER="$(zensu_tdd_mode_marker_path "$_zensu_pd" "$_zensu_sid")" || [ -z "$TDD_MODE_MARKER" ]; then
  echo "zensu-tdd-mode.sh: cannot resolve the session marker path" >&2
  exit 2
fi
# Derived from the marker, never re-spelled: the reader guards the same directory,
# and a second literal here would split the writer's state dir from the reader's.
TDD_MODE_STATE_DIR="$(dirname "$TDD_MODE_MARKER")"
unset _zensu_pd _zensu_sid

# The config getters below resolve the project overlay from CLAUDE_PROJECT_DIR.
# Pin it to the bound project — as zensu-log.sh does before its own config reads —
# so `--status` can never report a config file that `--tdd-begin` will not consult.
export CLAUDE_PROJECT_DIR="$TDD_MODE_PROJECT_DIR"

# The symlink refusal lives in the WRITER, not here: `--status` only reads, and the
# reader's own answer for a symlinked path is `auto` — so hard-failing a read would
# make this helper refuse a shape `--tdd-begin` handles fine, and tell the user to
# delete a file it was merely asked to report on.

# Written through a sibling temp file and renamed into place. A redirect onto the
# marker path would FOLLOW a symlink planted between the guard above and the
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
tdd_mode_write_marker() {
  local tmp
  # `.zensu` is checked alongside `state` and the marker: the project root itself is
  # canonicalized by Session Control, so `.zensu` is the one remaining component a
  # checked-out tree could carry as a link — and a link there relocates the whole
  # state directory while both leaf checks stay false.
  if [ -L "$TDD_MODE_PROJECT_DIR/.zensu" ] || [ -L "$TDD_MODE_STATE_DIR" ] || [ -L "$TDD_MODE_MARKER" ]; then
    echo "zensu-tdd-mode.sh: refusing to follow a symlinked state path — remove $TDD_MODE_MARKER and its directory link by hand" >&2
    exit 2
  fi
  mkdir -p -m 700 "$TDD_MODE_STATE_DIR" 2>/dev/null || {
    echo "zensu-tdd-mode.sh: cannot create state directory $TDD_MODE_STATE_DIR" >&2
    exit 2
  }
  tmp="$(mktemp "$TDD_MODE_MARKER.tmp.XXXXXX" 2>/dev/null)" || tmp=""
  [ -n "$tmp" ] || {
    echo "zensu-tdd-mode.sh: cannot create a temporary file beside $TDD_MODE_MARKER" >&2
    exit 2
  }
  trap 'rm -f "$tmp" 2>/dev/null' EXIT INT TERM HUP
  printf '{"mode":"%s"}\n' "$1" > "$tmp" || {
    echo "zensu-tdd-mode.sh: cannot write $tmp" >&2
    exit 2
  }
  # Re-assert every component the rename depends on, including the temp leaf.
  if [ -L "$TDD_MODE_PROJECT_DIR/.zensu" ] || [ -L "$TDD_MODE_STATE_DIR" ] \
    || [ -L "$TDD_MODE_MARKER" ] || [ -L "$tmp" ]; then
    echo "zensu-tdd-mode.sh: refusing to follow a symlinked state path — remove $TDD_MODE_MARKER and its directory link by hand" >&2
    exit 2
  fi
  # An existing non-regular marker (a directory above all) would swallow the
  # rename and report success, leaving the user told a choice landed that the
  # reader will never see.
  if [ -e "$TDD_MODE_MARKER" ] && [ ! -f "$TDD_MODE_MARKER" ]; then
    echo "zensu-tdd-mode.sh: $TDD_MODE_MARKER exists and is not a regular file — remove it by hand" >&2
    exit 2
  fi
  mv -f "$tmp" "$TDD_MODE_MARKER" || {
    echo "zensu-tdd-mode.sh: cannot write $TDD_MODE_MARKER" >&2
    exit 2
  }
  trap - EXIT INT TERM HUP
}

case "$TDD_MODE_VERB" in
  --strict)
    tdd_mode_write_marker strict
    echo "tdd-mode: strict"
    ;;
  --vanilla)
    tdd_mode_write_marker vanilla
    echo "tdd-mode: vanilla"
    ;;
  --auto)
    tdd_mode_write_marker auto
    echo "tdd-mode: auto"
    ;;
  --status)
    case "$(zensu_tdd_mode_override "$TDD_MODE_PROJECT_DIR" "$TDD_MODE_SESSION_KEY")" in
      strict)  echo "strict (session)" ;;
      vanilla) echo "vanilla (session)" ;;
      *)
        if zensu_tdd_strict_enabled; then echo "strict (config)"; else echo "vanilla (config)"; fi
        ;;
    esac
    ;;
esac
exit 0
