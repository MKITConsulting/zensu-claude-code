#!/bin/bash
# Shared payload extraction and root/session-key resolution for the worktree-keep hooks.
#
# It lives in one file and is CALLED twice rather than copied into the second hook, for
# the reason hooks/lib/zensu-witness.sh states about its own pair: the two halves write
# and remove the SAME anchor, so a one-sided edit to this ladder makes SessionStart write
# under one root while SessionEnd removes from another. The orphaned anchor then holds the
# keep marker — and with it the worktree out of the desktop pool — until the idle window,
# which is the accumulation sweepSiblings exists to bound, and both hooks exit 0 on every
# fault so nothing says so.
#
# What each hook keeps for itself is the house pattern the per-file scans expect: its own
# plugin-root guard, its own principal check with its own event name, its own config gate,
# its own payload pre-filter and its own module invocation.
#
# The UserPromptSubmit half deliberately does NOT source this: it has no payload fallback
# at all. An unbound session gets no drift disclosure, which docs/worktree-keep.md states
# under Limits and CLAUDE.md states as a known gap.

zensu_worktree_keep_read_field() {
  PAYLOAD="$1" FIELD="$2" node -e '
    try {
      const j = JSON.parse(process.env.PAYLOAD || "{}");
      const v = j[process.env.FIELD];
      process.stdout.write(typeof v === "string" ? v : "");
    } catch (_) { process.stdout.write(""); }
  ' 2>/dev/null
}

# Resolves ZENSU_WK_ROOT and ZENSU_WK_SESSION_KEY from the bound record, falling back to
# the payload only while the record is not readable yet. Returns non-zero when neither
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
  [ -n "$ZENSU_WK_ROOT" ] || ZENSU_WK_ROOT="$(zensu_worktree_keep_read_field "$_wk_input" cwd)"
  [ -n "$ZENSU_WK_ROOT" ] || return 1
  if [ -z "$ZENSU_WK_SESSION_KEY" ]; then
    _wk_id="$(zensu_worktree_keep_read_field "$_wk_input" session_id)"
    [ -n "$_wk_id" ] || return 1
    ZENSU_WK_SESSION_KEY="$(zensu_resolve_session_id "$_wk_id" 2>/dev/null)" || return 1
  fi
  [ -n "$ZENSU_WK_SESSION_KEY" ] || return 1
  return 0
}
