#!/bin/bash
# Shared payload extraction and root/session-key resolution for the worktree-keep hooks.
#
# It lives in one file and is CALLED twice rather than copied into the second hook,
# because the two halves write and remove the SAME anchor, so a one-sided edit to this
# ladder makes SessionStart write under one root while SessionEnd removes from another.
# The orphaned anchor then holds the keep marker — and with it the worktree out of the
# desktop pool — until the idle window, which is the accumulation sweepSiblings exists to
# bound, and both hooks exit 0 on every fault so nothing says so.
#
# What each hook keeps for itself is the house pattern the per-file scans expect: its own
# plugin-root guard, its own principal check with its own event name, its own config gate,
# its own payload pre-filter and its own module invocation.
#
# The UserPromptSubmit half deliberately does NOT source this: it has no payload fallback
# at all. An unbound session gets no drift disclosure, which docs/worktree-keep.md states
# under Limits and CLAUDE.md states as a known gap.

zensu_worktree_keep_payload_anchor() {
  local lib_dir
  lib_dir="$(case "${BASH_SOURCE[0]}" in (*/*) cd "${BASH_SOURCE[0]%/*}/" ;; esac && pwd -P)" || return 1
  (
    cd -P -- "$lib_dir" || exit 1
    printf '%s' "$1" | node -e '
      let cwd = "";
      let key = "";
      try {
        const j = JSON.parse(require("fs").readFileSync(0, "utf8") || "{}");
        if (typeof j.cwd === "string" && !/[\0\r\n]/.test(j.cwd)) cwd = j.cwd;
        require("./claude-hook-session-v1.js").validateSessionId(j.session_id);
        key = require("./session-control-core-v1.js").sessionKey(j.session_id);
      } catch (_) {}
      process.stdout.write(cwd + "\n" + key);
    ' 2>/dev/null
  )
}

# Resolves ZENSU_WK_ROOT and ZENSU_WK_SESSION_KEY from the bound record, falling back to
# the payload whenever the record yields no verified pair. Returns non-zero when neither
# channel yields a usable pair, which every caller answers with a silent exit 0.
zensu_worktree_keep_anchor() {
  _wk_input="$1"
  ZENSU_WK_ROOT=""
  ZENSU_WK_SESSION_KEY=""
  if zensu_bind_hook_session "$_wk_input" >/dev/null 2>&1; then
    _wk_project="$(zensu_resolve_project_dir 2>/dev/null)" || _wk_project=""
    if [ -n "$_wk_project" ]; then
      ZENSU_WK_ROOT="${ZENSU_PROJECT_ROOT:-$_wk_project}"
      ZENSU_WK_SESSION_KEY="${ZENSU_SESSION_KEY:-}"
    fi
  fi
  if [ -z "$ZENSU_WK_ROOT" ] || [ -z "$ZENSU_WK_SESSION_KEY" ]; then
    _wk_fields="$(zensu_worktree_keep_payload_anchor "$_wk_input")"
    case "$_wk_fields" in
      (*$'\n'*) ;;
      (*) return 1 ;;
    esac
    [ -n "$ZENSU_WK_ROOT" ] || ZENSU_WK_ROOT="${_wk_fields%%$'\n'*}"
    if [ -z "$ZENSU_WK_SESSION_KEY" ]; then
      ZENSU_WK_SESSION_KEY="${_wk_fields#*$'\n'}"
      [ -z "${ZENSU_SESSION_KEY:-}" ] || [ "$ZENSU_WK_SESSION_KEY" = "$ZENSU_SESSION_KEY" ] || return 1
    fi
  fi
  [ -n "$ZENSU_WK_ROOT" ] || return 1
  [ -n "$ZENSU_WK_SESSION_KEY" ] || return 1
  return 0
}
