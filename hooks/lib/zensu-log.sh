#!/bin/bash
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
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"

# State verbs bind from the skill-rendered plugin-data path and Claude's host
# session id inside this helper process only. SessionStart deliberately exports
# no Zensu selectors because CLAUDE_ENV_FILE reaches subsequent subagent Bash
# calls too. Missing context is a hard failure; transcript and PPID discovery
# remain absent.
case "${1:-}" in
  --*)
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
    if ! zensu_bind_model_session; then
      echo "zensu-log.sh: rendered Session Control binding unavailable" >&2
      if [ -z "${CLAUDE_CODE_SESSION_ID:-}" ]; then
        echo "zensu-log.sh: CLAUDE_CODE_SESSION_ID is not set — this helper must run from Claude Code's own Bash tool, which supplies the host session id." >&2
      fi
      if [ -z "${CLAUDE_PLUGIN_DATA:-}" ]; then
        echo "zensu-log.sh: CLAUDE_PLUGIN_DATA is not set — run this helper exactly as the Zensu hook or skill renders it, including its leading 'CLAUDE_PLUGIN_DATA=...' assignment; never hand-build the command." >&2
      fi
      if ! command -v node >/dev/null 2>&1; then
        echo "zensu-log.sh: node is not on PATH — Session Control cannot bind without it." >&2
      fi
      exit 2
    fi
    if ! _zensu_pd="$(zensu_resolve_project_dir)" || [ -z "$_zensu_pd" ]; then
      echo "zensu-log.sh: Session Control project context unavailable" >&2
      exit 2
    fi
    export CLAUDE_PROJECT_DIR="$_zensu_pd"
    unset _zensu_pd
    ;;
esac

zensu_state_failure_hint() {
  local verb="${1:-}" session="${2:-}" state_file status
  [ -n "$verb" ] && [ -n "$session" ] || return 0
  command -v tdd_state_file >/dev/null 2>&1 || return 0
  state_file="$(tdd_state_file "$session" 2>/dev/null)" || return 0
  status="$(tdd_state_status "$state_file" 2>/dev/null)"
  case "$status" in
    missing)
      echo "zensu-log.sh $verb: no chain state exists for this session — it was never armed in this project, or the state file was removed. '.zensu/' is gitignored, so a git clean, a worktree removal, or a branch cleanup deletes it. Re-run --tdd-begin to arm a fresh chain; the previous chain cannot be recovered." >&2
      ;;
    invalid)
      echo "zensu-log.sh $verb: the chain state for this session is unreadable or belongs to another session. Run /zensu:doctor for the exact diagnosis; --tdd-begin arms a fresh chain when the current one is beyond repair." >&2
      ;;
    *)
      echo "zensu-log.sh $verb: the chain state is readable, so this verb's own precondition was not met — an inactive session, the wrong chain phase, or a stale generation." >&2
      ;;
  esac
}

case "${1:-}" in
  --session-key)
    session_val="$(zensu_resolve_session_id)" || {
      echo "zensu-log.sh: Session Control session identity unavailable" >&2
      exit 2
    }
    printf '%s\n' "$session_val"
    exit 0
    ;;
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
    if [ "$phase_val" = CHAIN_RECOVERED ]; then
      echo "zensu-log.sh --phase: CHAIN_RECOVERED is written only by --chain-recover; it is the provenance record of a repair and cannot be minted by a caller" >&2
      exit 2
    fi
    case "$reason_val" in
      "chain-recovered: "*)
        echo "zensu-log.sh --phase: a 'chain-recovered: ' reason is reserved for --chain-recover" >&2
        exit 2
        ;;
    esac
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
  --autopilot-begin)
    run_val=""
    session_val=""
    cover_val=false
    validate_val=true
    seen_run=false
    seen_session=false
    seen_cover=false
    seen_validate=false
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --run)
          [ "$seen_run" = false ] && [ $# -ge 2 ] || { echo "zensu-log.sh --autopilot-begin: duplicate/missing --run" >&2; exit 2; }
          seen_run=true; run_val="$2"; shift 2
          ;;
        --session)
          [ "$seen_session" = false ] && [ $# -ge 2 ] || { echo "zensu-log.sh --autopilot-begin: duplicate/missing --session" >&2; exit 2; }
          seen_session=true; session_val="$2"; shift 2
          ;;
        --cover)
          [ "$seen_cover" = false ] && [ $# -ge 2 ] || { echo "zensu-log.sh --autopilot-begin: duplicate/missing --cover" >&2; exit 2; }
          seen_cover=true; cover_val="$2"; shift 2
          ;;
        --validate)
          [ "$seen_validate" = false ] && [ $# -ge 2 ] || { echo "zensu-log.sh --autopilot-begin: duplicate/missing --validate" >&2; exit 2; }
          seen_validate=true; validate_val="$2"; shift 2
          ;;
        *) echo "zensu-log.sh --autopilot-begin: unknown argument '$1'" >&2; exit 2 ;;
      esac
    done
    [ "$seen_run" = true ] || { echo "zensu-log.sh --autopilot-begin requires --run <id>" >&2; exit 2; }
    if [ "$seen_session" = true ] && [ -z "$session_val" ]; then
      echo "zensu-log.sh --autopilot-begin: --session must not be empty" >&2
      exit 2
    fi
    case "$cover_val" in true|false) ;; *) echo "zensu-log.sh --autopilot-begin: --cover must be true or false" >&2; exit 2 ;; esac
    case "$validate_val" in true|false) ;; *) echo "zensu-log.sh --autopilot-begin: --validate must be true or false" >&2; exit 2 ;; esac
    if [ -z "$session_val" ]; then
      export ZENSU_OWN_CMD="${ZENSU_OWN_CMD:-bash $0 --autopilot-begin --run $run_val}"
    fi
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
    session_val="$(zensu_resolve_session_id "$session_val")" || {
      echo "zensu-log.sh: Session Control session identity unavailable" >&2
      exit 2
    }
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh"
    autopilot_begin_run "$run_val" "$session_val" "${CLAUDE_PROJECT_DIR:-.}" "$cover_val" "$validate_val"
    exit $?
    ;;
  --autopilot-event)
    run_val=""
    event_val=""
    event_id_val=""
    payload_val='{}'
    seen_run=false
    seen_event=false
    seen_event_id=false
    seen_payload=false
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --run)
          [ "$seen_run" = false ] && [ $# -ge 2 ] || { echo "zensu-log.sh --autopilot-event: duplicate/missing --run" >&2; exit 2; }
          seen_run=true; run_val="$2"; shift 2
          ;;
        --event)
          [ "$seen_event" = false ] && [ $# -ge 2 ] || { echo "zensu-log.sh --autopilot-event: duplicate/missing --event" >&2; exit 2; }
          seen_event=true; event_val="$2"; shift 2
          ;;
        --event-id)
          [ "$seen_event_id" = false ] && [ $# -ge 2 ] || { echo "zensu-log.sh --autopilot-event: duplicate/missing --event-id" >&2; exit 2; }
          seen_event_id=true; event_id_val="$2"; shift 2
          ;;
        --payload)
          [ "$seen_payload" = false ] && [ $# -ge 2 ] || { echo "zensu-log.sh --autopilot-event: duplicate/missing --payload" >&2; exit 2; }
          seen_payload=true; payload_val="$2"; shift 2
          ;;
        *) echo "zensu-log.sh --autopilot-event: unknown argument '$1'" >&2; exit 2 ;;
      esac
    done
    [ "$seen_run" = true ] && [ "$seen_event" = true ] && [ "$seen_event_id" = true ] || {
      echo "zensu-log.sh --autopilot-event requires --run, --event, and --event-id" >&2
      exit 2
    }
    case "$event_val" in
      TDD_STARTED|TDD_CHAIN_DONE)
        echo "zensu-log.sh --autopilot-event: $event_val is internal; use the generation-bound TDD commands" >&2
        exit 2
        ;;
    esac
    export ZENSU_OWN_CMD="${ZENSU_OWN_CMD:-bash $0 --autopilot-event --run $run_val --event $event_val --event-id $event_id_val}"
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
    caller_session_val="$(zensu_resolve_session_id)" || {
      echo "zensu-log.sh: Session Control session identity unavailable" >&2
      exit 2
    }
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh"
    autopilot_apply_event "$run_val" "$event_id_val" "$event_val" "$payload_val" \
      "${CLAUDE_PROJECT_DIR:-.}" "$caller_session_val"
    exit $?
    ;;
  --autopilot-status)
    [ $# -eq 1 ] || { echo "zensu-log.sh --autopilot-status accepts no arguments" >&2; exit 2; }
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh"
    autopilot_read_active "${CLAUDE_PROJECT_DIR:-.}"
    exit $?
    ;;
  --tdd-begin|--tdd-complete|--review-ticket|--current-review-ticket|--review-rearm|--chain-done|--code-review-done|--self-review-fixed|--tdd-reset|--chain-status|--chain-recover|--workflow-begin|--workflow-end)
    verb="$1"
    session_val=""
    tools_val=""
    claimed_ticket_val=""
    claimed_ticket_seen=false
    autopilot_run_val=""
    autopilot_attempt_val=""
    autopilot_return_stage_val=""
    chain_id_val=""
    chain_outcome_val=""
    seen_session=false
    seen_tools=false
    seen_claimed_ticket=false
    seen_autopilot_run=false
    seen_autopilot_attempt=false
    seen_autopilot_return=false
    seen_chain_id=false
    seen_outcome=false
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --session)
          [ "$seen_session" = false ] && [ $# -ge 2 ] || { echo "zensu-log.sh $verb: duplicate/missing --session" >&2; exit 2; }
          seen_session=true; session_val="$2"; shift 2 ;;
        --tools)
          [ "$seen_tools" = false ] && [ $# -ge 2 ] || { echo "zensu-log.sh $verb: duplicate/missing --tools" >&2; exit 2; }
          seen_tools=true; tools_val="$2"; shift 2 ;;
        --autopilot-run)
          [ "$seen_autopilot_run" = false ] && [ $# -ge 2 ] || { echo "zensu-log.sh $verb: duplicate/missing --autopilot-run" >&2; exit 2; }
          seen_autopilot_run=true; autopilot_run_val="$2"; shift 2 ;;
        --autopilot-attempt)
          [ "$seen_autopilot_attempt" = false ] && [ $# -ge 2 ] || { echo "zensu-log.sh $verb: duplicate/missing --autopilot-attempt" >&2; exit 2; }
          seen_autopilot_attempt=true; autopilot_attempt_val="$2"; shift 2 ;;
        --autopilot-return-stage)
          [ "$seen_autopilot_return" = false ] && [ $# -ge 2 ] || { echo "zensu-log.sh $verb: duplicate/missing --autopilot-return-stage" >&2; exit 2; }
          seen_autopilot_return=true; autopilot_return_stage_val="$2"; shift 2 ;;
        --chain-id)
          [ "$seen_chain_id" = false ] && [ $# -ge 2 ] || { echo "zensu-log.sh $verb: duplicate/missing --chain-id" >&2; exit 2; }
          seen_chain_id=true; chain_id_val="$2"; shift 2 ;;
        --outcome)
          [ "$seen_outcome" = false ] && [ $# -ge 2 ] || { echo "zensu-log.sh $verb: duplicate/missing --outcome" >&2; exit 2; }
          seen_outcome=true; chain_outcome_val="$2"; shift 2 ;;
        --claimed-review-ticket)
          [ "$seen_claimed_ticket" = false ] && [ $# -ge 2 ] || { echo "zensu-log.sh $verb: duplicate/missing --claimed-review-ticket" >&2; exit 2; }
          seen_claimed_ticket=true
          claimed_ticket_seen=true
          claimed_ticket_val="$2"
          shift 2
          ;;
        *) echo "zensu-log.sh $verb: unknown argument '$1'" >&2; exit 2 ;;
      esac
    done
    if [ "$seen_session" = true ] && [ -z "$session_val" ]; then
      echo "zensu-log.sh $verb: --session must not be empty" >&2
      exit 2
    fi
    invalid_known_flag=false
    case "$verb" in
      --tdd-begin|--tdd-complete)
        [ "$seen_tools" = false ] && [ "$seen_claimed_ticket" = false ] \
          && [ "$seen_outcome" = false ] || invalid_known_flag=true
        ;;
      --review-ticket|--current-review-ticket|--tdd-reset|--chain-status|--chain-recover)
        [ "$seen_tools" = false ] && [ "$seen_claimed_ticket" = false ] \
          && [ "$seen_autopilot_run" = false ] && [ "$seen_autopilot_attempt" = false ] \
          && [ "$seen_autopilot_return" = false ] && [ "$seen_chain_id" = false ] \
          && [ "$seen_outcome" = false ] || invalid_known_flag=true
        ;;
      --review-rearm)
        [ "$seen_tools" = false ] && [ "$seen_outcome" = false ] || invalid_known_flag=true
        ;;
      --chain-done)
        [ "$seen_tools" = false ] || invalid_known_flag=true
        ;;
      --code-review-done|--self-review-fixed)
        [ "$seen_tools" = false ] && [ "$seen_autopilot_run" = false ] \
          && [ "$seen_autopilot_attempt" = false ] && [ "$seen_autopilot_return" = false ] \
          && [ "$seen_chain_id" = false ] && [ "$seen_outcome" = false ] \
          || invalid_known_flag=true
        ;;
      --workflow-begin)
        [ "$seen_claimed_ticket" = false ] && [ "$seen_autopilot_run" = false ] \
          && [ "$seen_autopilot_attempt" = false ] && [ "$seen_autopilot_return" = false ] \
          && [ "$seen_chain_id" = false ] && [ "$seen_outcome" = false ] \
          || invalid_known_flag=true
        ;;
      --workflow-end)
        [ "$seen_tools" = false ] && [ "$seen_claimed_ticket" = false ] \
          && [ "$seen_autopilot_run" = false ] && [ "$seen_autopilot_attempt" = false ] \
          && [ "$seen_autopilot_return" = false ] && [ "$seen_chain_id" = false ] \
          && [ "$seen_outcome" = false ] || invalid_known_flag=true
        ;;
    esac
    if [ "$invalid_known_flag" = true ]; then
      echo "zensu-log.sh $verb: option is not valid for this verb" >&2
      exit 2
    fi
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
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
        begin_state_file="$(tdd_state_file "$session_val")" || {
          echo "zensu-log.sh --tdd-begin: current-session workflow path unavailable" >&2
          exit 1
        }
        # Inspect the canonical leaf before reading prior-generation metadata.
        # A FIFO/device/directory must fail immediately rather than letting any
        # convenience read block before the transactional begin guard runs.
        _tdd_state_storage_safe "$begin_state_file" || {
          echo "zensu-log.sh --tdd-begin: current-session workflow storage is unsafe" >&2
          exit 1
        }
        outgoing_bypasses="$(tdd_bypasses "$begin_state_file" 2>/dev/null)"
        if zensu_tdd_strict_enabled; then
          begin_vanilla=false
        else
          begin_vanilla=true
        fi
        if [ -n "$autopilot_run_val$autopilot_attempt_val$autopilot_return_stage_val$chain_id_val" ]; then
          [ -n "$autopilot_run_val" ] && [ -n "$autopilot_attempt_val" ] \
            && [ -n "$autopilot_return_stage_val" ] && [ -n "$chain_id_val" ] || {
              echo "zensu-log.sh --tdd-begin: Autopilot linkage requires --autopilot-run, --autopilot-attempt, --autopilot-return-stage, and --chain-id" >&2
              exit 2
            }
        fi
        if [ -n "$autopilot_run_val" ]; then
          source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh"
          start_event_id="$(autopilot_chain_event_id start "$chain_id_val")" || {
            echo "zensu-log.sh --tdd-begin: invalid Autopilot chain identifier" >&2
            exit 2
          }
          autopilot_begin_tdd_attempt "$autopilot_run_val" "$start_event_id" \
            "${CLAUDE_PROJECT_DIR:-.}" "$session_val" "$begin_vanilla" \
            "$autopilot_attempt_val" "$autopilot_return_stage_val" "$chain_id_val"
          tdd_begin_rc=$?
        else
          # The absent/terminal decision and the unbound Inner write are one
          # Outer -> Inner composite. A resumable BLOCKED run is not terminal,
          # and a concurrent bound start cannot be overwritten after a stale
          # preflight read.
          source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh"
          autopilot_begin_standalone_tdd "${CLAUDE_PROJECT_DIR:-.}" \
            "$session_val" "$begin_vanilla"
          tdd_begin_rc=$?
        fi
        if [ "$tdd_begin_rc" -eq 0 ]; then
          if [ "$begin_vanilla" = "true" ]; then
            echo "mode: vanilla"
          else
            echo "mode: strict"
          fi
          [ -n "$outgoing_bypasses" ] && echo "previous-run bypasses (cleared now): $outgoing_bypasses"
        else
          echo "zensu-log --tdd-begin: atomic chain activation failed — session NOT activated" >&2
          [ -n "$outgoing_bypasses" ] && echo "previous-run bypasses preserved: $outgoing_bypasses" >&2
        fi
        exit "$tdd_begin_rc"
        ;;
      --tdd-complete)
        if ! complete_ctx="$(tdd_autopilot_context "$(tdd_state_file "$session_val")" "$session_val" 2>/dev/null)"; then
          echo "zensu-log.sh --tdd-complete: corrupt, inactive, or foreign session state" >&2
          zensu_state_failure_hint --tdd-complete "$session_val"
          exit 1
        fi
        # Edit-landing receipt gate. The Phase 6 step 5b audit is an obligation
        # the model could simply forget; this makes it a precondition, the same
        # way --chain-done refuses a terminus it can see is untrue. The receipt
        # is written by hooks/lib/zensu-edit-landing.sh and lives beside the
        # session state, keyed the same way.
        # Scope it exactly like the --chain-done dirty-tree refusal below: the
        # obligation exists because files changed. A chain that changed nothing
        # has no claim to verify, and hermetic chain-mechanics tests must not be
        # forced to fabricate a receipt to exercise the terminus.
        # Not evaluable means not gated, exactly as the --chain-done zero-change
        # gate treats a non-git root and a repo with no HEAD commit: without a
        # baseline there is no honest claim to check against.
        _el_changes=0
        if [ "${ZENSU_EDIT_LANDING_GATE:-on}" != "off" ] \
           && git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
          # `grep -c .` already prints 0 on no match and then exits 1, so an `|| echo 0`
          # fallback would append a SECOND line and turn the count into "0\n0" — which
          # makes the -gt comparison below abort with "integer expression expected" and
          # silently skips the gate on exactly the empty change set it is scoping for.
          _el_changes="$( { git -C "${CLAUDE_PROJECT_DIR:-.}" diff --name-only HEAD 2>/dev/null
                            git -C "${CLAUDE_PROJECT_DIR:-.}" ls-files --others --exclude-standard 2>/dev/null; } \
                          | sort -u | grep -c . 2>/dev/null || true)"
        fi
        if [ "${ZENSU_EDIT_LANDING_GATE:-on}" != "off" ] && [ "${_el_changes:-0}" -gt 0 ]; then
          _el_state="$(tdd_state_file "$session_val")"
          _el_key="$(basename "$_el_state")"; _el_key="${_el_key#tdd-phase-}"; _el_key="${_el_key%.json}"
          _el_receipt="$(dirname "$_el_state")/edit-landing-${_el_key}.json"
          if [ ! -f "$_el_receipt" ]; then
            echo "zensu-log.sh --tdd-complete: refusing to mark implementation complete — no edit-landing receipt for this session. A claimed edit that never landed leaves no diff, so no reviewer would ever see it. Run the Phase 6 step 5b audit first:" >&2
            echo "  bash \"\${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-edit-landing.sh\" --log <run-log> --project \"\${CLAUDE_PROJECT_DIR:-.}\" --session \"<session id>\"" >&2
            echo "Set ZENSU_EDIT_LANDING_GATE=off only for a session the user has explicitly exempted." >&2
            exit 1
          fi
        fi
        if [ "$complete_ctx" = '{}' ]; then
          if [ -n "$autopilot_run_val$autopilot_attempt_val$autopilot_return_stage_val$chain_id_val" ]; then
            echo "zensu-log.sh --tdd-complete: Autopilot binding was supplied for a standalone chain" >&2
            exit 2
          fi
          tdd_mark_impl_complete_standalone "$session_val"
          exit $?
        fi
        [ -n "$autopilot_run_val" ] && [ -n "$autopilot_attempt_val" ] && [ -n "$chain_id_val" ] || {
          echo "zensu-log.sh --tdd-complete: bound chain requires --autopilot-run, --autopilot-attempt, and --chain-id" >&2
          exit 2
        }
        complete_link="$(AUTOPILOT_CTX="$complete_ctx" RUN="$autopilot_run_val" \
          ATTEMPT="$autopilot_attempt_val" CHAIN="$chain_id_val" RETURN_STAGE="$autopilot_return_stage_val" node -e '
          try {
            const c=JSON.parse(process.env.AUTOPILOT_CTX);
            const exact=c.sessionId && c.active===true && c.chainDone===false
              && c.runId===process.env.RUN && String(c.attempt)===process.env.ATTEMPT
              && c.chainId===process.env.CHAIN
              && (!process.env.RETURN_STAGE || c.returnStage===process.env.RETURN_STAGE);
            if(!exact)process.exit(3);
            process.stdout.write([c.runId,c.attempt,c.chainId].join("\t"));
          } catch (_) { process.exit(3); }
        ' 2>/dev/null)" || {
          echo "zensu-log.sh --tdd-complete: stale or mismatched Autopilot generation" >&2
          exit 1
        }
        IFS=$'\t' read -r complete_run complete_attempt complete_chain <<<"$complete_link"
        tdd_mark_impl_complete_bound "$session_val" "$complete_run" "$complete_attempt" "$complete_chain"
        exit $?
        ;;
      --review-ticket) tdd_issue_review_ticket "$session_val" ;;
      --current-review-ticket) tdd_claimed_review_ticket "$(tdd_state_file "$session_val")" ;;
      --chain-status)
        chain_status_out="$(tdd_chain_diagnostics "$session_val")"
        chain_status_rc=$?
        case "$chain_status_rc" in
          0) printf '%s\n' "$chain_status_out"; exit 0 ;;
          1)
            echo "zensu-log.sh --chain-status: this session has no chain state" >&2
            exit 1
            ;;
          *)
            echo "zensu-log.sh --chain-status: chain state is unreadable, foreign, or unsafe" >&2
            exit 2
            ;;
        esac
        ;;
      --chain-recover)
        chain_recover_out="$(tdd_recover_chain "$session_val")"
        chain_recover_rc=$?
        case "$chain_recover_rc" in
          0)
            printf '%s\n' "${chain_recover_out/recovered:/recovered: }"
            exit 0
            ;;
          1)
            echo "zensu-log.sh --chain-recover: this session has no chain state" >&2
            exit 1
            ;;
          3)
            chain_recover_reason="${chain_recover_out#refused:}"
            case "$chain_recover_reason" in
              stale-generation)
                echo "zensu-log.sh --chain-recover: refused — the generation changed between the diagnosis and the transaction. Nothing was written; re-run --chain-status." >&2
                exit 3
                ;;
              unclassifiable-generation)
                echo "zensu-log.sh --chain-recover: refused — under the lock the document no longer classified (a field changed shape between the diagnosis and the transaction). Nothing was written; re-run --chain-status." >&2
                exit 3
                ;;
            esac
            chain_recover_report="$(tdd_chain_diagnostics "$session_val" 2>/dev/null)" \
              || chain_recover_report=""
            chain_recover_hint="$(CHAIN_REASON="$chain_recover_reason" \
              CHAIN_REPORT="$chain_recover_report" \
              CHAIN_RECOVERY="$_ZENSU_TDD_CHAIN_RECOVERY" node -e '
              try {
                const chain = require(process.env.CHAIN_RECOVERY);
                const blocked = chain.BLOCKED_RECOVERY_COMMAND[process.env.CHAIN_REASON];
                let report = {};
                try { report = JSON.parse(process.env.CHAIN_REPORT); } catch (_) {}
                let lead;
                if (report.deadEnd) lead = "This chain is at a dead end";
                else if (report.wedged && !report.recoverable) lead = "This chain is wedged but not recoverable in place";
                else if (report.wedged) lead = "The chain changed under the refusal and now reads as recoverable — re-run --chain-status first";
                else if (report.shape) lead = "This chain is not wedged";
                else lead = "The current chain shape could not be re-read";
                const command = blocked || report.nextCommand;
                if (command) process.stdout.write(lead + " — supported next step: " + command);
              } catch (_) {}
            ' 2>/dev/null)"
            if [ -n "$chain_recover_hint" ]; then
              echo "zensu-log.sh --chain-recover: refused (${chain_recover_reason}). ${chain_recover_hint}" >&2
            else
              echo "zensu-log.sh --chain-recover: refused (${chain_recover_reason}). The supported next step could not be derived — run --chain-status." >&2
            fi
            exit 3
            ;;
          *)
            case "${chain_recover_out#op:}" in
              write-failed)
                echo "zensu-log.sh --chain-recover: the recovery transaction was rejected before it could be committed (lock or filesystem failure). The chain was left untouched — retry once the cause is resolved." >&2
                ;;
              write-landed-unconfirmed)
                echo "zensu-log.sh --chain-recover: the repair landed but the transaction could not confirm it. Re-run --chain-status to see the current shape; do NOT arm a new chain." >&2
                ;;
              lock-failed)
                echo "zensu-log.sh --chain-recover: the locked transaction did not report a verdict — the session lease could not be taken, the lock keeper failed, or the storage re-check refused. The chain was NOT recovered. Re-run --chain-status; do NOT arm a new chain to work around it." >&2
                ;;
              module-unreadable)
                echo "zensu-log.sh --chain-recover: the chain-recovery module is missing or could not be loaded — repair the plugin installation" >&2
                ;;
              *)
                echo "zensu-log.sh --chain-recover: chain state is unreadable, foreign, or unsafe" >&2
                ;;
            esac
            exit 2
            ;;
        esac
        ;;
      --review-rearm)
        [ "$claimed_ticket_seen" = "true" ] || {
          echo "zensu-log.sh --review-rearm requires --claimed-review-ticket <ticket>" >&2
          exit 2
        }
        if ! rearm_ctx="$(tdd_autopilot_context "$(tdd_state_file "$session_val")" "$session_val" 2>/dev/null)"; then
          echo "zensu-log.sh --review-rearm: corrupt or incomplete Autopilot linkage" >&2
          exit 1
        fi
        if [ "$rearm_ctx" = '{}' ]; then
          if [ -n "$autopilot_run_val$autopilot_attempt_val$autopilot_return_stage_val$chain_id_val" ]; then
            echo "zensu-log.sh --review-rearm: Autopilot binding was supplied for a standalone chain" >&2
            exit 2
          fi
          tdd_rearm_review "$session_val" "$claimed_ticket_val"
          exit $?
        fi
        [ -n "$autopilot_run_val" ] && [ -n "$autopilot_attempt_val" ] && [ -n "$chain_id_val" ] || {
          echo "zensu-log.sh --review-rearm: bound chain requires --autopilot-run, --autopilot-attempt, and --chain-id" >&2
          exit 2
        }
        rearm_link="$(AUTOPILOT_CTX="$rearm_ctx" RUN="$autopilot_run_val" \
          ATTEMPT="$autopilot_attempt_val" CHAIN="$chain_id_val" node -e '
          try {
            const c=JSON.parse(process.env.AUTOPILOT_CTX);
            const exact=c.runId===process.env.RUN && String(c.attempt)===process.env.ATTEMPT
              && c.chainId===process.env.CHAIN;
            if(!exact)process.exit(3);
            process.stdout.write([c.runId,c.attempt,c.chainId].join("\t"));
          } catch (_) { process.exit(3); }
        ' 2>/dev/null)" || {
          echo "zensu-log.sh --review-rearm: stale or mismatched Autopilot generation" >&2
          exit 1
        }
        IFS=$'\t' read -r rearm_run rearm_attempt rearm_chain <<<"$rearm_link"
        source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh"
        autopilot_rearm_review "$rearm_run" "${CLAUDE_PROJECT_DIR:-.}" "$session_val" \
          "$rearm_attempt" "$rearm_chain" "$claimed_ticket_val" || {
          echo "zensu-log.sh --review-rearm: composite outer/inner rearm rejected stale or corrupt state" >&2
          exit 1
        }
        exit 0
        ;;
      --chain-done)
        if ! autopilot_ctx="$(tdd_autopilot_context "$(tdd_state_file "$session_val")" "$session_val" 2>/dev/null)"; then
          echo "zensu-log.sh --chain-done: corrupt or incomplete Autopilot linkage" >&2
          zensu_state_failure_hint --chain-done "$session_val"
          exit 1
        fi
        if [ "$autopilot_ctx" = '{}' ]; then
          if [ -n "$autopilot_run_val$autopilot_attempt_val$autopilot_return_stage_val$chain_id_val" ]; then
            echo "zensu-log.sh --chain-done: Autopilot binding was supplied for a standalone chain" >&2
            exit 2
          fi
          if [ -n "$chain_outcome_val" ]; then
            echo "zensu-log.sh --chain-done: --outcome requires an Autopilot-bound chain" >&2
            exit 1
          fi
          if [ "$(tdd_chain_done "$(tdd_state_file "$session_val")")" != "true" ]; then
            if [ "$claimed_ticket_seen" = "true" ]; then
              tdd_mark_review_converged "$session_val" "$claimed_ticket_val" chainDone || {
                chain_done_rc=$?
                zensu_state_failure_hint --chain-done "$session_val"
                exit "$chain_done_rc"
              }
            else
              chain_change_count="unknown"
              if command -v git >/dev/null 2>&1 \
                && [ "$(git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] \
                && git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
                chain_change_count="$( { git -C "${CLAUDE_PROJECT_DIR:-.}" diff --name-only HEAD 2>/dev/null
                  git -C "${CLAUDE_PROJECT_DIR:-.}" ls-files --others --exclude-standard 2>/dev/null
                } | awk 'NF{n++} END{print n+0}')"
                case "$chain_change_count" in ''|*[!0-9]*) chain_change_count="unknown" ;; esac
              fi
              if [ "$chain_change_count" != "unknown" ] && [ "$chain_change_count" != "0" ]; then
                echo "zensu-log.sh --chain-done: refusing the unqualified standalone terminus. No review ticket was ever consumed in this chain, so this form is reserved for the ZERO-file-change exception — but the worktree reports ${chain_change_count} changed file(s). Review those changes through the zensu:code-reviewer chain and close with --claimed-review-ticket, or re-enter /zensu:tdd for a fresh guarded chain." >&2
                exit 1
              fi
              tdd_mark_unclaimed_review "$session_val" chainDone || {
                chain_done_rc=$?
                zensu_state_failure_hint --chain-done "$session_val"
                exit "$chain_done_rc"
              }
            fi
          fi
          exit 0
        fi
        [ -n "$autopilot_run_val" ] && [ -n "$autopilot_attempt_val" ] && [ -n "$chain_id_val" ] || {
          echo "zensu-log.sh --chain-done: bound chain requires --autopilot-run, --autopilot-attempt, and --chain-id" >&2
          exit 2
        }
        done_fields="$(AUTOPILOT_CTX="$autopilot_ctx" REQUESTED_OUTCOME="$chain_outcome_val" \
          RUN="$autopilot_run_val" ATTEMPT="$autopilot_attempt_val" CHAIN="$chain_id_val" \
          RETURN_STAGE="$autopilot_return_stage_val" node -e '
          try {
            const c=JSON.parse(process.env.AUTOPILOT_CTX);
            const exact=c.active===true && c.implComplete===true
              && c.runId===process.env.RUN && String(c.attempt)===process.env.ATTEMPT
              && c.chainId===process.env.CHAIN
              && (!process.env.RETURN_STAGE || c.returnStage===process.env.RETURN_STAGE);
            if(!exact)process.exit(3);
            const outcome=process.env.REQUESTED_OUTCOME||c.outcome||"pass";
            process.stdout.write([c.runId,c.attempt,c.chainId,outcome].join("\t"));
          } catch (_) { process.exit(3); }
        ' 2>/dev/null)" || {
          echo "zensu-log.sh --chain-done: stale or mismatched Autopilot generation" >&2
          exit 1
        }
        IFS=$'\t' read -r done_run done_attempt done_chain done_outcome <<<"$done_fields"
        source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh"
        done_event_id="$(autopilot_chain_event_id "done" "$done_chain")" || {
          echo "zensu-log.sh --chain-done: invalid Autopilot chain identifier" >&2
          exit 2
        }
        autopilot_finish_tdd_attempt "$done_run" "$done_event_id" \
          "${CLAUDE_PROJECT_DIR:-.}" "$session_val" "$done_attempt" "$done_chain" \
          "$done_outcome" "$claimed_ticket_seen" "$claimed_ticket_val"
        exit $?
        ;;
      --code-review-done)
        if [ "$claimed_ticket_seen" = "true" ]; then
          tdd_mark_review_converged "$session_val" "$claimed_ticket_val" codeReviewDone
        else
          tdd_mark_unclaimed_review "$session_val" codeReviewDone
        fi
        ;;
      --self-review-fixed)
        if [ "$claimed_ticket_seen" = "true" ]; then
          tdd_mark_review_converged "$session_val" "$claimed_ticket_val" selfReviewFixed
        else
          tdd_mark_unclaimed_review "$session_val" selfReviewFixed
        fi
        ;;
      --workflow-begin)
        tdd_workflow_begin "$session_val" "$tools_val"
        ;;
      --workflow-end)   tdd_set_flag "$session_val" workflowActive false ;;
      --tdd-reset)
        reset_state="$(tdd_state_file "$session_val")"
        reset_ctx='{}'
        if [ -e "$reset_state" ] || [ -L "$reset_state" ]; then
          reset_ctx="$(tdd_autopilot_context "$reset_state" "$session_val" 2>/dev/null)" || {
            echo "zensu-log.sh --tdd-reset: corrupt or incomplete Autopilot linkage" >&2
            exit 1
          }
        fi
        if [ "$reset_ctx" != '{}' ]; then
          reset_fields="$(AUTOPILOT_CTX="$reset_ctx" node -e '
            try {
              const c=JSON.parse(process.env.AUTOPILOT_CTX);
              process.stdout.write([c.runId,c.attempt,c.chainId].join("\t"));
            }
            catch (_) { process.exit(3); }
          ' 2>/dev/null)" || exit 1
          IFS=$'\t' read -r reset_run reset_attempt reset_chain <<<"$reset_fields"
          source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh"
          if ! autopilot_reset_inner "$reset_run" "${CLAUDE_PROJECT_DIR:-.}" "$session_val" \
              "$reset_attempt" "$reset_chain"; then
            echo "zensu-log.sh --tdd-reset: an active or resumable durable outer run owns this chain" >&2
            exit 1
          fi
          reset_rc=0
        else
          tdd_reset_pending_review_claim "$session_val"
          reset_rc=$?
        fi
        exit "$reset_rc"
        ;;
    esac
    state_verb_rc=$?
    [ "$state_verb_rc" -eq 0 ] || zensu_state_failure_hint "$verb" "$session_val"
    exit "$state_verb_rc"
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
