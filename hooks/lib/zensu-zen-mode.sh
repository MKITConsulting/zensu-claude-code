#!/bin/bash
# zensu-zen-mode.sh — session-scoped on/off switch for the zen-mode response
# style. `--on` writes a marker into the project's ephemeral state directory,
# `--off` removes it, `--status` reports it. The UserPromptSubmit hook
# (user-prompt-zen-mode.sh) reads that marker on every prompt and re-injects the
# mode contract, so the style survives context drift instead of fading after a
# handful of turns.
#
# Session binding follows the model-invocation path zensu-log.sh uses: the helper
# must run from Claude Code's own Bash tool, which supplies CLAUDE_CODE_SESSION_ID
# and CLAUDE_PLUGIN_DATA. SessionStart deliberately exports no Zensu selectors, so
# there is no environment variable to read instead. The marker is keyed by the
# resolved Session Control key, so a fresh session always starts with zen-mode off
# and a leftover marker can never leak into another session.
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

ZEN_STATE_DIR="$_zensu_pd/.zensu/state"
ZEN_MARKER="$ZEN_STATE_DIR/zen-mode-$_zensu_sid.json"
unset _zensu_pd _zensu_sid

if [ -L "$ZEN_STATE_DIR" ] || [ -L "$ZEN_MARKER" ]; then
  echo "zensu-zen-mode.sh: refusing to follow a symlinked state path — remove $ZEN_MARKER and its directory link by hand" >&2
  exit 2
fi

case "$ZEN_VERB" in
  --on)
    mkdir -p -m 700 "$ZEN_STATE_DIR" 2>/dev/null || {
      echo "zensu-zen-mode.sh: cannot create state directory $ZEN_STATE_DIR" >&2
      exit 2
    }
    printf '{"active":true}\n' > "$ZEN_MARKER" || {
      echo "zensu-zen-mode.sh: cannot write $ZEN_MARKER" >&2
      exit 2
    }
    echo "zen-mode: on"
    ;;
  --off)
    rm -f "$ZEN_MARKER" 2>/dev/null || true
    if [ -e "$ZEN_MARKER" ]; then
      echo "zensu-zen-mode.sh: cannot remove $ZEN_MARKER — zen-mode is still active" >&2
      exit 2
    fi
    echo "zen-mode: off"
    ;;
  --status)
    if [ -f "$ZEN_MARKER" ]; then echo "on"; else echo "off"; fi
    ;;
esac
exit 0
