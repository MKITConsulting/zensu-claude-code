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
# THE SAME WATCHDOG THE IN-BAND TWIN USES. This script is what the hook NAMES
# when the in-band escape is unavailable, and the conditions that make that path
# fail - an lstat, an O_EXCL open, an fsync and a rename on stalled storage -
# stall here too. RESIDUAL: on a host with neither `timeout` nor `gtimeout`, which
# is base macOS, the shared ladder falls through to an unbounded arm, so this buys
# a bound only where the host supplies one.
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-bounded-run.sh"
# THE ZEN-ONLY STATE PREDICATES, shared with the in-band twin: the marker`s
# ACTIVE question, its SHAPE rule, and the component walk. One owner each.
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-zen-shared.sh"
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
# THE DETECTION IS ONE FUNCTION; THE CONSEQUENCE IS PER VERB. Both arms used to
# sit at FILE SCOPE, above the dispatch, so they gated `--status` too - and in
# exactly these two states the hook resolves the mode OFF and injects nothing,
# while this verb answered neither `on` nor `off` but exited 2 with an empty
# stdout. `--status` is the surface a user consults when the mode misbehaves, and
# `skills/zen-mode/SKILL.md` states it reports `on` or `off`; the file`s other two
# degraded arms already print bare `off` with the cause on stderr for the same
# reason. A WRITE is a different question - there the shape is tamper evidence and
# still a refusal - so `--on` and `--off` keep exit 2.
# THE PREDICATE LIVES IN `hooks/lib/zensu-session.sh`, beside the untraversable
# arm of the same ladder, and this file sources it. It was spelled here AND
# inline in the hook, with nothing comparing the two copies.
zen_shape_fault() {  # this file`s paths, the shared rule
  zen_marker_shape_fault "$ZEN_ZENSU_DIR" "$ZEN_STATE_DIR" "$ZEN_MARKER"
}

zen_refuse_bad_shape() {  # the WRITE consequence: name the cause and refuse
  ZEN_SHAPE_WHY="$(zen_shape_fault)" || return 0
  echo "zensu-zen-mode.sh: $ZEN_SHAPE_WHY" >&2
  exit 2
}

zen_write_marker() {
  mkdir -p -m 700 "$ZEN_STATE_DIR" 2>/dev/null || {
    echo "zensu-zen-mode.sh: cannot create state directory $ZEN_STATE_DIR" >&2
    exit 2
  }
  # Stale temps from a killed write. The suffix is random rather than the pid -
  # a collision would turn one crash into a permanent refusal - and the price of
  # randomness is that every killed write leaks a distinct file.
  find "$ZEN_STATE_DIR" -maxdepth 1 -type f -name "$(basename "$ZEN_MARKER").tmp-*" -mmin +5 \
    -exec rm -f {} + 2>/dev/null || true
  ZEN_WRITE_RC=0
  (
    export ZEN_MARKER="$ZEN_MARKER" ZEN_VALUE="$1"
    zensu_run_bounded node -e '
    const fs = require("fs");
    const crypto = require("crypto");
    const target = process.env.ZEN_MARKER;
    let st = null;
    try { st = fs.lstatSync(target); } catch (e) { if (e.code !== "ENOENT") process.exit(2); }
    // THE nlink CONJUNCT IS GONE, matching the in-band twin. The landing never
    // opens `target`: it creates a fresh inode with O_EXCL and publishes with
    // `renameSync`, and `rename(2)` repoints the NAME - it leaves any other hard
    // link pointing at the old inode with its old content untouched. So the
    // hard-link destroy is closed by the rename alone, while refusing on nlink
    // cost the remedy: one `ln` in a session-writable directory made every later
    // off-attempt fail here AND in the hook, which is an availability regression
    // against the truncating write this replaced.
    if (st && !st.isFile()) process.exit(2);
    const tmp = target + ".tmp-" + crypto.randomBytes(6).toString("hex");
    let fd;
    try {
      fd = fs.openSync(tmp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
      // THE WHOLE BUFFER, or a failure. An ignored return value is harmless for
      // --off (the reader greps for an active mode, misses, resolves OFF) and is
      // NOT harmless for --on: the same truncation fails that grep, so the mode
      // reads OFF while this script has already printed `zen-mode: on` and exited
      // 0 - the user is told the mode is on and it is not, on no channel at all.
      const buf = Buffer.from("{\"active\":" + process.env.ZEN_VALUE + "}\n");
      let written = 0;
      while (written < buf.length) {
        const n = fs.writeSync(fd, buf, written, buf.length - written);
        if (!(n > 0)) throw new Error("short write");
        written += n;
      }
      fs.fsyncSync(fd);
    } catch (e) { try { if (fd !== undefined) fs.closeSync(fd); } catch (_) {} try { fs.unlinkSync(tmp); } catch (_) {} process.exit(3); }
    try { fs.closeSync(fd); } catch (_) {}
    try { fs.renameSync(tmp, target); } catch (e) { try { fs.unlinkSync(tmp); } catch (_) {} process.exit(4); }
  '
  ) || ZEN_WRITE_RC=$?
  # FOUR REFUSALS, FOUR MESSAGES. They all arrived as `cannot write $ZEN_MARKER`,
  # and the shape arm is the one that hurt: an operator reading a generic write
  # failure checks permissions and disk and never looks for the marker`s type. The
  # two arms above this function already name their cause and what to remove by
  # hand; the new writer was the one path that had lost that property.
  case "$ZEN_WRITE_RC" in
    0) ;;
    2)
      echo "zensu-zen-mode.sh: $ZEN_MARKER is not a regular file, or its type could not be read - remove it by hand" >&2
      exit 2
      ;;
    3)
      echo "zensu-zen-mode.sh: could not create or write a temporary marker beside $ZEN_MARKER in $ZEN_STATE_DIR - check permissions and free space" >&2
      exit 2
      ;;
    4)
      echo "zensu-zen-mode.sh: could not publish the new marker over $ZEN_MARKER - the rename failed, so the old content still stands" >&2
      exit 2
      ;;
    *)
      echo "zensu-zen-mode.sh: cannot write $ZEN_MARKER (writer exited $ZEN_WRITE_RC; state directory $ZEN_STATE_DIR)" >&2
      exit 2
      ;;
  esac
}
case "$ZEN_VERB" in
  --on)
    zen_refuse_bad_shape
    zen_write_marker true
    echo "zen-mode: on"
    ;;
  --off)
    zen_refuse_bad_shape
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
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
    # THE HOOK`S OWN FLAG IS CONSULTED FIRST. `zensu_zen_mode_default_on` reads
    # only `zenModeDefault` and never `hooks.zenMode`, while the hook exits on
    # `zenMode` before any marker is read - so with the hook disabled and no
    # marker this verb printed `on` for a session that receives no zen-mode
    # behaviour at all, which is exactly the state that sends someone here. The
    # two-word stdout contract is kept and the reason goes to stderr, matching the
    # untraversable arm below.
    if ! zensu_hook_enabled zenMode; then
      echo "zensu-zen-mode.sh: the re-injection hook is disabled by hooks.zenMode, so no prompt receives the mode" >&2
      echo "off"
    elif ZEN_SHAPE_WHY="$(zen_shape_fault)"; then
      # A CORRUPT MARKER SHAPE IS `off` HERE, not a refusal. The hook resolves a
      # symlinked state path and a present-but-non-regular marker to OFF, so
      # exiting 2 with nothing on stdout made the two readers disagree about one
      # state - and it did so on the surface a user reaches BECAUSE the mode is
      # misbehaving. It sits ABOVE the `[ -f ]` arm on purpose: `-f` follows a
      # symlink, so a link to a non-regular target would otherwise fall through
      # to the configured default and be reported `on`.
      echo "zensu-zen-mode.sh: $ZEN_SHAPE_WHY" >&2
      echo "off"
    elif [ -f "$ZEN_MARKER" ]; then
      # A marker that is unreadable or does not spell out an active mode counts
      # as off: an unparsable state file must never impose the mode on a user who
      # may have just left it.
      if zen_marker_active "$ZEN_MARKER"; then
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
      if zensu_zen_mode_default_on; then echo "on"; else echo "off"; fi
    fi
    ;;
esac
exit 0
