#!/bin/bash
set -u
export ZENSU_BASH_START="${ZENSU_BASH_START:-}"
: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/../.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"

# Recover CLAUDE_PROJECT_DIR for non-hook Bash invocations (Claude Code sets it
# only for hooks). Without it the state files anchor to ${CLAUDE_PROJECT_DIR:-.}
# = cwd and the session id falls through resolve-session-id.js to gitToplevel()/
# cwd() — both diverge from the Stop hook (which HAS CLAUDE_PROJECT_DIR) inside a
# git worktree, so a marker like --chain-done lands in a state file the enforcer
# never reads and the review chain deadlocks. Recovering the launch/project dir
# from the active transcript's cwd (cwd-independent) realigns every verb below
# with the (project-dir, session-id) the hook uses. Gated to the state verbs
# (--*) so the hot `timestamp`/`style` path never spawns node; skipped entirely
# when CLAUDE_PROJECT_DIR is already set (all hooks, all hermetic tests) —
# behavior then is byte-for-byte unchanged. ZENSU_OWN_CMD is hoisted default-if-
# unset so this recovery and the per-verb session resolution tail-match the same
# command in the transcript.
case "${1:-}" in
  --*)
    if [ -z "${CLAUDE_PROJECT_DIR:-}" ]; then
      # Build a quote-safe, reason-free tail-match needle. Claude Code stores a
      # --reason value QUOTED in the transcript, so an unquoted "$*" would not
      # substring-match; the per-verb session needles below are likewise reason-
      # free. Assemble it from the verb/step tokens only (dropping any --reason
      # <val> pair), without consuming $@, so this recovery and the per-verb
      # resolution tail-match the same command in the active transcript.
      _zensu_needle="bash $0"; _zensu_skip=0
      for _zensu_a in "$@"; do
        if [ "$_zensu_skip" = "1" ]; then _zensu_skip=0; continue; fi
        if [ "$_zensu_a" = "--reason" ]; then _zensu_skip=1; continue; fi
        _zensu_needle="$_zensu_needle $_zensu_a"
      done
      export ZENSU_OWN_CMD="${ZENSU_OWN_CMD:-$_zensu_needle}"
      unset _zensu_needle _zensu_skip _zensu_a
      source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
      _zensu_pd="$(zensu_resolve_project_dir)" && [ -n "$_zensu_pd" ] && export CLAUDE_PROJECT_DIR="$_zensu_pd"
      unset _zensu_pd
    fi
    ;;
esac

case "${1:-}" in
  --phase)
    phase_val=""
    step_val=""
    session_val=""
    reason_val=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --phase)   phase_val="${2:-}";   shift 2 || break ;;
        --step)    step_val="${2:-}";    shift 2 || break ;;
        --session) session_val="${2:-}"; shift 2 || break ;;
        --reason)  reason_val="${2:-}";  shift 2 || break ;;
        *) shift ;;
      esac
    done
    if [ -z "$phase_val" ]; then
      echo "zensu-log.sh --phase requires a phase value" >&2
      exit 2
    fi
    if [ -z "$session_val" ]; then
      export ZENSU_OWN_CMD="${ZENSU_OWN_CMD:-bash $0 --phase $phase_val --step $step_val}"
      source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
      session_val="$(zensu_resolve_session_id "${CLAUDE_SESSION_ID:-}")"
    fi
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
    tdd_write_phase "$session_val" "$step_val" "$phase_val" "$reason_val"
    exit $?
    ;;
  --mode)
    session_val=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --session) session_val="${2:-}"; shift 2 || break ;;
        *) shift ;;
      esac
    done
    if [ -z "$session_val" ]; then
      export ZENSU_OWN_CMD="${ZENSU_OWN_CMD:-bash $0 --mode}"
      source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
      session_val="$(zensu_resolve_session_id "${CLAUDE_SESSION_ID:-}")"
    fi
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
    if [ "$(tdd_vanilla_mode "$(tdd_state_file "$session_val")")" = "true" ]; then
      echo "vanilla"
    else
      echo "strict"
    fi
    exit 0
    ;;
  --bypass-note)
    gate_val=""
    session_val=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --bypass-note) gate_val="${2:-}";    shift 2 || break ;;
        --session)     session_val="${2:-}"; shift 2 || break ;;
        *) shift ;;
      esac
    done
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
    if ! _tdd_bypass_shape_ok "$gate_val"; then
      echo "zensu-log.sh --bypass-note requires a known gate name (one of: $ZENSU_BYPASS_GATE_ALLOWLIST)" >&2
      exit 2
    fi
    if [ -z "$session_val" ]; then
      export ZENSU_OWN_CMD="${ZENSU_OWN_CMD:-bash $0 --bypass-note $gate_val}"
      source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
      session_val="$(zensu_resolve_session_id "${CLAUDE_SESSION_ID:-}")"
    fi
    tdd_record_bypass "$session_val" "$gate_val"
    exit $?
    ;;
  --bypass-list)
    session_val=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --session) session_val="${2:-}"; shift 2 || break ;;
        *) shift ;;
      esac
    done
    if [ -z "$session_val" ]; then
      export ZENSU_OWN_CMD="${ZENSU_OWN_CMD:-bash $0 --bypass-list}"
      source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
      session_val="$(zensu_resolve_session_id "${CLAUDE_SESSION_ID:-}")"
    fi
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
    bypass_list="$(tdd_bypasses "$(tdd_state_file "$session_val")")"
    if [ -n "$bypass_list" ]; then
      echo "$bypass_list"
    else
      echo "none"
    fi
    exit 0
    ;;
  --pending-review|--pending-review-done)
    verb="$1"
    files_val=""
    summary_val=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --files)   files_val="${2:-}";   shift 2 || break ;;
        --summary) summary_val="${2:-}"; shift 2 || break ;;
        *) shift ;;
      esac
    done
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
    case "$verb" in
      --pending-review)      tdd_write_pending_review "$files_val" "$summary_val" ;;
      --pending-review-done) tdd_clear_pending_review ;;
    esac
    exit $?
    ;;
  --tdd-begin|--tdd-complete|--chain-done|--code-review-done|--self-review-fixed|--tdd-reset|--workflow-begin|--workflow-end)
    verb="$1"
    session_val=""
    tools_val=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --session) session_val="${2:-}"; shift 2 || break ;;
        --tools)   tools_val="${2:-}";   shift 2 || break ;;
        *) shift ;;
      esac
    done
    if [ -z "$session_val" ]; then
      export ZENSU_OWN_CMD="${ZENSU_OWN_CMD:-bash $0 $verb}"
      source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
      session_val="$(zensu_resolve_session_id "${CLAUDE_SESSION_ID:-}")"
    fi
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
    case "$verb" in
      --tdd-begin)
        tdd_set_flag "$session_val" active true
        tdd_begin_rc=$?
        if [ "$tdd_begin_rc" -eq 0 ]; then
          if zensu_tdd_strict_enabled; then
            if ! tdd_set_flag "$session_val" vanilla false; then
              echo "zensu-log --tdd-begin: strict flag write failed — a stale vanilla flag may remain" >&2
              tdd_begin_rc=1
            fi
          elif ! tdd_set_flag "$session_val" vanilla true; then
            echo "zensu-log --tdd-begin: vanilla flag write failed — session runs strict" >&2
            tdd_begin_rc=1
          fi
          if [ "$(tdd_vanilla_mode "$(tdd_state_file "$session_val")")" = "true" ]; then
            echo "mode: vanilla"
          else
            echo "mode: strict"
          fi
        else
          echo "zensu-log --tdd-begin: active flag write failed — session NOT activated" >&2
        fi
        outgoing_bypasses="$(tdd_bypasses "$(tdd_state_file "$session_val")" 2>/dev/null)"
        [ -n "$outgoing_bypasses" ] && echo "previous-run bypasses (cleared now): $outgoing_bypasses"
        tdd_clear_bypasses "$session_val" 2>/dev/null || \
          echo "zensu-log --tdd-begin: bypass-ledger reset failed — prior entries may persist" >&2
        tdd_clear_review_pass "$session_val" 2>/dev/null || true
        rounds_state_dir="${CLAUDE_PLUGIN_DATA_OVERRIDE:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}"
        rounds_counter_file="${rounds_state_dir}/rounds-${session_val}.json"
        if [ -L "$rounds_counter_file" ]; then
          echo "zensu-log --tdd-begin: refusing to delete through symlink at $rounds_counter_file — rounds counter NOT reset" >&2
        elif [ -L "$rounds_state_dir" ]; then
          echo "zensu-log --tdd-begin: refusing to reset under symlinked state dir $rounds_state_dir — rounds counter NOT reset" >&2
        else
          rm -f -- "$rounds_counter_file"
        fi
        stopblocks_file="$(tdd_state_file "$session_val").stopblocks"
        if [ -L "$stopblocks_file" ]; then
          echo "zensu-log --tdd-begin: refusing to delete through symlink at $stopblocks_file — stop-block budget NOT reset" >&2
        else
          rm -f -- "$stopblocks_file"
        fi
        exit "$tdd_begin_rc"
        ;;
      --tdd-complete) tdd_set_flag "$session_val" implComplete true ;;
      --chain-done)
        tdd_set_flag "$session_val" chainDone true
        chain_done_rc=$?
        tdd_write_review_pass "$session_val" 2>&1 >/dev/null | head -2 >&2 || true
        exit "$chain_done_rc"
        ;;
      --code-review-done)  tdd_set_flag "$session_val" codeReviewDone true ;;
      --self-review-fixed) tdd_set_flag "$session_val" selfReviewFixed true ;;
      --workflow-begin)
        tdd_workflow_begin "$session_val" "$tools_val"
        ;;
      --workflow-end)   tdd_set_flag "$session_val" workflowActive false ;;
      --tdd-reset)
        tdd_clear_review_pass "$session_val" 2>/dev/null || true
        tdd_clear_session "$session_val"
        ;;
    esac
    exit $?
    ;;
esac

cmd="${1:-timestamp}"
case "$cmd" in
  timestamp)
    start="${2:-$(date +%s)}"
    case "$start" in
      ''|*[!0-9]*) start=$(date +%s) ;;
    esac
    style=$(_zensu_log_style)
    case "$style" in
      none)
        printf ""
        ;;
      relative)
        now=$(date +%s)
        diff=$((now - 10#$start))
        [ "$diff" -lt 0 ] && diff=0
        if [ "$diff" -lt 86400 ]; then
          printf "[+%02d:%02d:%02d] " $((diff/3600)) $(((diff%3600)/60)) $((diff%60))
        else
          days=$((diff/86400))
          rem=$((diff%86400))
          printf "[+%dd %02d:%02d:%02d] " "$days" $((rem/3600)) $(((rem%3600)/60)) $((rem%60))
        fi
        ;;
      *)
        printf "[%s] " "$(date +%H:%M:%S)"
        ;;
    esac
    ;;
  style)
    _zensu_log_style
    ;;
  *)
    echo "usage: zensu-log.sh {timestamp <epoch> | style}" >&2
    exit 2
    ;;
esac
