#!/bin/bash
# zensu-zen-mode.sh — session-scoped on/off switch for the zen-mode response
# style. `--on` and `--off` both WRITE the session marker in the project's
# ephemeral state directory (`{"active":true}` / `{"active":false}`); `--status`
# reports the resolved mode. The UserPromptSubmit hook (user-prompt-zen-mode.sh)
# reads that marker on every prompt and re-injects the mode contract, so the
# style survives context drift instead of fading after a handful of turns.
#
# The marker is a RECORDED CHOICE, not an on-switch: absent it, the mode falls
# back to hooks.zenModeDefault, which defaults to TRUE. That is why `--off` writes
# `{"active":false}` instead of removing the file — under a true default, deleting
# the marker would re-enable the mode the user just left. Deletion is therefore
# never a valid deactivation; only an explicit false marker is.
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

ZEN_VERB="${1:-}"
case "$ZEN_VERB" in
  --on|--off|--status) ;;
  *)
    echo "usage: zensu-zen-mode.sh --on | --off | --status" >&2
    exit 2
    ;;
esac

# TWIN PROLOGUE — the block from here to the end of the two resolver guards is
# duplicated, near-verbatim, in hooks/lib/zensu-tdd-mode.sh (only the script name in
# the messages and the skill named in the CLAUDE_PLUGIN_DATA hint differ). It is NOT
# extracted into zensu-session.sh: the plugin-root self-validation above has to
# precede this `source` to mean anything, so the two halves cannot move together
# without restructuring both helpers. Change the Session Control binding contract and
# you change it TWICE — the twin carries the same reference back to this file.
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
if ! zensu_bind_model_session; then
  echo "zensu-zen-mode.sh: rendered Session Control binding unavailable" >&2
  if [ -z "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    echo "zensu-zen-mode.sh: CLAUDE_CODE_SESSION_ID is not set — this helper must run from Claude Code's own Bash tool, which supplies the host session id." >&2
  fi
  if [ -z "${CLAUDE_PLUGIN_DATA:-}" ]; then
    echo "zensu-zen-mode.sh: CLAUDE_PLUGIN_DATA is not set — run this helper exactly as the zen-mode skill renders it, including its leading 'CLAUDE_PLUGIN_DATA=...' assignment; never hand-build the command." >&2
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "zensu-zen-mode.sh: node is not on PATH — Session Control cannot bind without it." >&2
  fi
  exit 2
fi
if ! _zensu_pd="$(zensu_resolve_project_dir)" || [ -z "$_zensu_pd" ]; then
  echo "zensu-zen-mode.sh: Session Control project context unavailable" >&2
  exit 2
fi
if ! _zensu_sid="$(zensu_resolve_session_id)" || [ -z "$_zensu_sid" ]; then
  echo "zensu-zen-mode.sh: Session Control session identity unavailable" >&2
  exit 2
fi

_zensu_status_root="$_zensu_pd"
ZEN_STATE_DIR="$_zensu_pd/.zensu/state"
ZEN_ZENSU_DIR="$_zensu_pd/.zensu"
ZEN_MARKER="$ZEN_STATE_DIR/zen-mode-$_zensu_sid.json"
unset _zensu_pd _zensu_sid

# THIS WRITER IS THE OUT-OF-BAND REMEDY, so it must be at least as hard as the
# in-band one. `user-prompt-zen-mode.sh` names this script in the sentence it
# prints when the in-band `zen off` escape is unavailable, so a hostile or
# corrupt marker path that makes the hook decline must not then wedge or destroy
# HERE. All three guards the hook carries are mirrored: the `.zensu` component
# (testing `state` alone resolves THROUGH a symlinked parent), a present-but-not
# regular marker (a FIFO is neither a symlink nor a regular file, and a shell
# redirect opens one BLOCKING with no reader), and a landing that publishes by
# rename rather than truncating a name a hard link may point elsewhere.
if [ -L "$ZEN_ZENSU_DIR" ] || [ -L "$ZEN_STATE_DIR" ] || [ -L "$ZEN_MARKER" ]; then
  echo "zensu-zen-mode.sh: refusing to follow a symlinked state path — remove $ZEN_MARKER and its directory link by hand" >&2
  exit 2
fi
if [ -e "$ZEN_MARKER" ] && [ ! -f "$ZEN_MARKER" ]; then
  echo "zensu-zen-mode.sh: $ZEN_MARKER is not a regular file — remove it by hand" >&2
  exit 2
fi

zen_write_marker() {
  mkdir -p -m 700 "$ZEN_STATE_DIR" 2>/dev/null || {
    echo "zensu-zen-mode.sh: cannot create state directory $ZEN_STATE_DIR" >&2
    exit 2
  }
  ZEN_MARKER="$ZEN_MARKER" ZEN_VALUE="$1" node -e '
    const fs = require("fs");
    const crypto = require("crypto");
    const target = process.env.ZEN_MARKER;
    let st = null;
    try { st = fs.lstatSync(target); } catch (e) { if (e.code !== "ENOENT") process.exit(1); }
    if (st && (!st.isFile() || st.nlink !== 1)) process.exit(1);
    const tmp = target + ".tmp-" + crypto.randomBytes(6).toString("hex");
    let fd;
    try {
      fd = fs.openSync(tmp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
      fs.writeSync(fd, "{\"active\":" + process.env.ZEN_VALUE + "}\n");
      fs.fsyncSync(fd);
    } catch (e) { try { if (fd !== undefined) fs.closeSync(fd); } catch (_) {} try { fs.unlinkSync(tmp); } catch (_) {} process.exit(1); }
    try { fs.closeSync(fd); } catch (_) {}
    try { fs.renameSync(tmp, target); } catch (e) { try { fs.unlinkSync(tmp); } catch (_) {} process.exit(1); }
  ' || {
    echo "zensu-zen-mode.sh: cannot write $ZEN_MARKER" >&2
    exit 2
  }
}

case "$ZEN_VERB" in
  --on)
    zen_write_marker true
    echo "zen-mode: on"
    ;;
  --off)
    zen_write_marker false
    echo "zen-mode: off"
    ;;
  --status)
    # THE SAME PERMISSION ARM THE HOOK CARRIES, through ONE shared predicate in
    # `zensu-session.sh`. Without it `[ -f ]` fails with EACCES on an unsearchable
    # ancestor and this verb reported the configured default - `on` by default -
    # for a session the hook resolves OFF and injects nothing into. Two readers of
    # one state must not disagree, and this is the surface a user consults exactly
    # when the mode misbehaves.
    #
    # IT SITS AFTER THE MARKER ARMS, matching the hook`s own order. Testing it
    # first diverged for a process that CAN traverse a mode-000 directory (root,
    # CAP_DAC_OVERRIDE): the hook read and honoured the marker while this verb
    # answered "not searchable" - the disagreement the arm exists to prevent.
    if [ -f "$ZEN_MARKER" ]; then
      # A marker that is unreadable or does not spell out an active mode counts
      # as off: an unparsable state file must never impose the mode on a user who
      # may have just left it.
      if grep -q '"active"[[:space:]]*:[[:space:]]*true' "$ZEN_MARKER" 2>/dev/null; then
        echo "on"
      else
        echo "off"
      fi
    elif zen_path_untraversable "$ZEN_MARKER" "$_zensu_status_root"; then
      # BARE `off` on stdout, reason on stderr. The verb`s contract is two words
      # and a consumer may compare for equality, so a third stdout spelling would
      # break it - and `skills/zen-mode/SKILL.md` states that contract.
      echo "zensu-zen-mode.sh: the state directory is not searchable" >&2
      echo "off"
    else
      source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
      if zensu_zen_mode_default_on; then echo "on"; else echo "off"; fi
    fi
    ;;
esac
exit 0
