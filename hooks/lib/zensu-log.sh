#!/bin/bash
set -u
_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)" || exit 2
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ "$CLAUDE_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
  echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
  exit 2
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"

# State verbs consume only the immutable Session Control v1 exports. Missing
# session or project context is a hard failure; transcript and PPID discovery
# are intentionally absent from the fresh-session contract.
case "${1:-}" in
  --*)
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
    if ! _zensu_pd="$(zensu_resolve_project_dir)" || [ -z "$_zensu_pd" ]; then
      echo "zensu-log.sh: Session Control project context unavailable" >&2
      exit 2
    fi
    export CLAUDE_PROJECT_DIR="$_zensu_pd"
    unset _zensu_pd
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
    fi
    if ! session_val="$(zensu_resolve_session_id "$session_val")" || [ -z "$session_val" ]; then
      echo "zensu-log.sh: Session Control session identity unavailable" >&2
      exit 2
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
    fi
    if ! session_val="$(zensu_resolve_session_id "$session_val")" || [ -z "$session_val" ]; then
      echo "zensu-log.sh: Session Control session identity unavailable" >&2
      exit 2
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
    fi
    if ! session_val="$(zensu_resolve_session_id "$session_val")" || [ -z "$session_val" ]; then
      echo "zensu-log.sh: Session Control session identity unavailable" >&2
      exit 2
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
    fi
    if ! session_val="$(zensu_resolve_session_id "$session_val")" || [ -z "$session_val" ]; then
      echo "zensu-log.sh: Session Control session identity unavailable" >&2
      exit 2
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
    fi
    if ! session_val="$(zensu_resolve_session_id "$session_val")" || [ -z "$session_val" ]; then
      echo "zensu-log.sh: Session Control session identity unavailable" >&2
      exit 2
    fi
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
    case "$verb" in
      --tdd-begin)
        outgoing_bypasses="$(tdd_bypasses "$(tdd_state_file "$session_val")" 2>/dev/null)"
        if zensu_tdd_strict_enabled; then mode_flag_val="false"; else mode_flag_val="true"; fi
        if tdd_begin_session "$session_val" "$mode_flag_val"; then
          tdd_begin_rc=0
          [ "$mode_flag_val" = "true" ] && echo "mode: vanilla" || echo "mode: strict"
          [ -n "$outgoing_bypasses" ] && echo "previous-run bypasses (cleared now): $outgoing_bypasses"
        else
          tdd_begin_rc=1
          echo "zensu-log --tdd-begin: atomic workflow initialization failed — session NOT activated" >&2
        fi
        exit "$tdd_begin_rc"
        ;;
      --tdd-complete) tdd_set_flag "$session_val" implComplete true ;;
      --chain-done)
        tdd_set_flag "$session_val" chainDone true
        exit $?
        ;;
      --code-review-done)  tdd_set_flag "$session_val" codeReviewDone true ;;
      --self-review-fixed) tdd_set_flag "$session_val" selfReviewFixed true ;;
      --workflow-begin)
        tdd_workflow_begin "$session_val" "$tools_val"
        ;;
      --workflow-end)   tdd_set_flag "$session_val" workflowActive false ;;
      --tdd-reset)
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
