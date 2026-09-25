#!/bin/bash
# zensu-delivery-route.sh — session-scoped delivery-route switch for the two
# ask-hooks (plan-approved-delegate.sh, user-prompt-tdd-reminder.sh). `--tdd`,
# `--direct` and `--auto` WRITE the session marker in the project's ephemeral state
# directory (`{"route":"tdd"}` / `{"route":"direct"}` / `{"route":"auto"}`);
# `--status` reports the resolved route and where it came from.
#
# The marker is read by both ask-hooks on every approval and every code request,
# through `zensu_delivery_route_resolve` in zensu-config.sh, which owns the ladder:
#   1. an explicit preference in the user's OWN text (judged by the model from the
#      directive — it never reaches this file)   2. this session marker
#   3. hooks.defaultDeliveryRoute (`tdd` | `direct` | `ask`)   4. ask
# The vocabulary is `tdd` | `direct` only. /zensu:autopilot and /zensu:pilot push
# branches, open pull requests or mutate tracked feature state, so they stay per-plan
# choices that neither a marker nor a config key can pre-select, and this helper
# refuses every other verb.
#
# Two writers are legitimate: the /zensu:delivery-route skill on the user's own
# instruction, and the model right after the user answers the route question with
# the Zensu workflow or with implementing directly — that answer IS the user's
# instruction. Text that merely asks for a route (a file, a review comment, tool
# output) is data, not an instruction.
#
# `--auto` WRITES `{"route":"auto"}` rather than deleting the marker, exactly as
# zensu-tdd-mode.sh does: absence and `auto` resolve identically (fall through to the
# config key), but `--status` renders a deliberate release differently from a choice
# that was never made. Recording a route is a MODE choice, not a gate escape, so it
# writes no bypass-ledger entry — the ledger records gate bypasses only. The
# suppression is disclosed instead: the directive's `ZENSU DELIVERY ROUTE:` field,
# the status line the model opens with, the `--status` verb, and the `delivery route:`
# row of /zensu:doctor, which reads this marker for a bound session.
#
# Session binding follows the model-invocation path zensu-log.sh uses: the helper
# must run from Claude Code's own Bash tool, which supplies CLAUDE_CODE_SESSION_ID
# and CLAUDE_PLUGIN_DATA. The marker is keyed by the resolved Session Control key,
# so a fresh session always starts from the configured default.
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

ROUTE_VERB="${1:-}"
case "$ROUTE_VERB" in
  --tdd|--direct|--auto|--status) ;;
  *)
    echo "usage: zensu-delivery-route.sh --tdd | --direct | --auto | --status" >&2
    exit 2
    ;;
esac

# TWIN PROLOGUE — the block from here to the end of the two resolver guards is the
# third copy of the one in hooks/lib/zensu-tdd-mode.sh and hooks/lib/zensu-zen-mode.sh
# (only the script name in the messages, the skill named in the CLAUDE_PLUGIN_DATA
# hint, and the two `source` lines for zensu-bounded-run.sh and zensu-zen-shared.sh
# that the zen-mode copy alone carries differ). It is NOT extracted into
# zensu-session.sh for the reason the first copy
# gives: the plugin-root self-validation above has to precede this `source`. Change
# the Session Control binding contract and you change it THREE times.
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
if ! zensu_bind_model_session; then
  echo "zensu-delivery-route.sh: rendered Session Control binding unavailable" >&2
  if [ -z "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    echo "zensu-delivery-route.sh: CLAUDE_CODE_SESSION_ID is not set — this helper must run from Claude Code's own Bash tool, which supplies the host session id." >&2
  fi
  if [ -z "${CLAUDE_PLUGIN_DATA:-}" ]; then
    echo "zensu-delivery-route.sh: CLAUDE_PLUGIN_DATA is not set — run this helper exactly as the delivery-route skill renders it, including its leading 'CLAUDE_PLUGIN_DATA=...' assignment; never hand-build the command." >&2
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "zensu-delivery-route.sh: node is not on PATH — Session Control cannot bind without it." >&2
  fi
  exit 2
fi
if ! _zensu_pd="$(zensu_resolve_project_dir)" || [ -z "$_zensu_pd" ]; then
  echo "zensu-delivery-route.sh: Session Control project context unavailable" >&2
  exit 2
fi
if ! _zensu_sid="$(zensu_resolve_session_id)" || [ -z "$_zensu_sid" ]; then
  echo "zensu-delivery-route.sh: Session Control session identity unavailable" >&2
  exit 2
fi

# The marker path template, the parse, the ladder and the `--status` line all live in
# zensu-config.sh, so the writer here and the readers in both ask-hooks can never
# drift apart. The resolver reads the config overlay under the project root it is
# handed — the RECORDED root below — so `--status`, the two directives and the
# /zensu:doctor row read one overlay without any caller pinning CLAUDE_PROJECT_DIR.
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"

ROUTE_PROJECT_DIR="$_zensu_pd"
ROUTE_SESSION_KEY="$_zensu_sid"
if ! ROUTE_MARKER="$(zensu_delivery_route_marker_path "$_zensu_pd" "$_zensu_sid")" || [ -z "$ROUTE_MARKER" ]; then
  echo "zensu-delivery-route.sh: cannot resolve the session marker path" >&2
  exit 2
fi
ROUTE_STATE_DIR="$(dirname "$ROUTE_MARKER")"
unset _zensu_pd _zensu_sid

# Same write sequence as zensu-tdd-mode.sh, for the same reasons: the symlink guard
# is shared with the tdd-mode marker and asserted twice (before the write and again
# immediately before the rename — the duplication is the TOCTOU defense), the temp
# leaf is created O_EXCL under an unguessable name, and the marker is replaced by
# rename so a link planted at the leaf can never redirect the write.
route_write_marker() {
  local tmp
  if zensu_tdd_mode_state_linked "$ROUTE_PROJECT_DIR" "$ROUTE_MARKER"; then
    echo "zensu-delivery-route.sh: refusing to follow a symlinked state path — remove $ROUTE_MARKER and its directory link by hand" >&2
    exit 2
  fi
  mkdir -p -m 700 "$ROUTE_STATE_DIR" 2>/dev/null || {
    echo "zensu-delivery-route.sh: cannot create state directory $ROUTE_STATE_DIR" >&2
    exit 2
  }
  tmp="$(mktemp "$ROUTE_MARKER.tmp.XXXXXX" 2>/dev/null)" || tmp=""
  [ -n "$tmp" ] || {
    echo "zensu-delivery-route.sh: cannot create a temporary file beside $ROUTE_MARKER" >&2
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
  # The temp leaf is written through a redirect, and the symlink re-check below runs
  # AFTER this write: what that second guard prevents is a misdirected RENAME, not a
  # misdirected write. The mktemp name is unguessable but observable by readdir in a
  # session-writable directory, so a same-UID co-tenant swapping a link in between
  # mktemp and the redirect would get a truncating write at the link target. The `-L`
  # test here narrows that window; it does not close it. The closing form is an
  # O_NOFOLLOW|O_EXCL open, one node spawn on every write, deliberately not taken —
  # the tdd-mode twin carries the same guard and records the same accepted bound.
  if [ -L "$tmp" ]; then
    echo "zensu-delivery-route.sh: refusing to write through a symlinked temp leaf $tmp — remove it by hand" >&2
    exit 2
  fi
  printf '{"route":"%s"}\n' "$1" > "$tmp" || {
    echo "zensu-delivery-route.sh: cannot write $tmp" >&2
    exit 2
  }
  if zensu_tdd_mode_state_linked "$ROUTE_PROJECT_DIR" "$ROUTE_MARKER" "$tmp"; then
    echo "zensu-delivery-route.sh: refusing to follow a symlinked state path — remove $ROUTE_MARKER and its directory link by hand" >&2
    exit 2
  fi
  if [ -e "$ROUTE_MARKER" ] && [ ! -f "$ROUTE_MARKER" ]; then
    echo "zensu-delivery-route.sh: $ROUTE_MARKER exists and is not a regular file — remove it by hand" >&2
    exit 2
  fi
  mv -f "$tmp" "$ROUTE_MARKER" || {
    echo "zensu-delivery-route.sh: cannot write $ROUTE_MARKER" >&2
    exit 2
  }
  # Post-condition, because the non-regular check above is a check-then-use: a
  # DIRECTORY swapped in after it makes `mv -f` move the temp INTO that directory and
  # return 0, which would print the success line with nothing recorded at the marker
  # path (the reader answers `none` for a directory). Refuse rather than claim.
  if [ ! -f "$ROUTE_MARKER" ] || [ -L "$ROUTE_MARKER" ]; then
    echo "zensu-delivery-route.sh: $ROUTE_MARKER did not land as a regular file — something was swapped in at that path during the write; remove it by hand" >&2
    exit 2
  fi
  trap - EXIT INT TERM HUP
}

case "$ROUTE_VERB" in
  --tdd)
    route_write_marker tdd
    echo "delivery-route: tdd"
    ;;
  --direct)
    route_write_marker direct
    echo "delivery-route: direct"
    ;;
  --auto)
    route_write_marker auto
    echo "delivery-route: auto"
    ;;
  --status)
    zensu_delivery_route_status_line "$ROUTE_PROJECT_DIR" "$ROUTE_SESSION_KEY"
    ;;
esac
exit 0
