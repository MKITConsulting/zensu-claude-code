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

# A chain terminus is a disclosure point: a gate escape needs no file change to
# be recorded, so the zero-change spelling is exactly where one would otherwise
# go unreported. The line goes to stderr, the operator channel every other
# release message in the Stop enforcer already uses, so a caller parsing this
# verb's stdout is unaffected.
zensu_render_terminus_bypasses() {
  local session="${1:-}" rendered
  [ -n "$session" ] || return 0
  command -v zensu_bypass_display >/dev/null 2>&1 || return 0
  rendered="$(zensu_bypass_display "$(tdd_state_file "$session" 2>/dev/null)")"
  [ -n "$rendered" ] && echo "Gates bypassed during this session: $rendered" >&2
  return 0
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
    if [ "$phase_val" = RUNTIME_ADOPTED ]; then
      echo "zensu-log.sh --phase: RUNTIME_ADOPTED is written only by the session adoption; it is the provenance record of a runtime takeover and cannot be minted by a caller" >&2
      exit 2
    fi
    case "$reason_val" in
      "chain-recovered: "*)
        echo "zensu-log.sh --phase: a 'chain-recovered: ' reason is reserved for --chain-recover" >&2
        exit 2
        ;;
      "runtime-adopted: "*)
        echo "zensu-log.sh --phase: a 'runtime-adopted: ' reason is reserved for the session adoption" >&2
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
    bypass_rc=0
    bypass_list="$(zensu_bypass_display "$(tdd_state_file "$session_val")" text)" || bypass_rc=$?
    if [ "$bypass_rc" -ne 0 ]; then
      echo "$bypass_list"
      zensu_state_failure_hint --bypass-list "$session_val" >&2
      exit 3
    fi
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
    tdd_mode_val=""
    plan_val=""
    seen_session=false
    seen_tools=false
    seen_claimed_ticket=false
    seen_autopilot_run=false
    seen_autopilot_attempt=false
    seen_autopilot_return=false
    seen_chain_id=false
    seen_outcome=false
    seen_tdd_mode=false
    seen_plan=false
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
        --tdd-mode)
          [ "$seen_tdd_mode" = false ] && [ $# -ge 2 ] || { echo "zensu-log.sh $verb: duplicate/missing --tdd-mode" >&2; exit 2; }
          seen_tdd_mode=true; tdd_mode_val="$2"; shift 2 ;;
        --plan)
          [ "$seen_plan" = false ] && [ $# -ge 2 ] || { echo "zensu-log.sh $verb: duplicate/missing --plan" >&2; exit 2; }
          seen_plan=true; plan_val="$2"; shift 2 ;;
        *) echo "zensu-log.sh $verb: unknown argument '$1'" >&2; exit 2 ;;
      esac
    done
    if [ "$seen_session" = true ] && [ -z "$session_val" ]; then
      echo "zensu-log.sh $verb: --session must not be empty" >&2
      exit 2
    fi
    if [ "$seen_plan" = true ] && [ -z "$plan_val" ]; then
      echo "zensu-log.sh $verb: --plan must not be empty" >&2
      exit 2
    fi
    # --tdd-mode carries the caller's OWN default into the one verb that freezes
    # the mode, and it is ESCALATION-ONLY: `strict` is the only accepted value.
    # The value reaches this flag from a `TDD-MODE:` line in a model-read
    # specification, and a spec body is not always user-authored — /zensu:pr-fix-findings
    # builds one from PR review-comment bodies. An accepted `vanilla` there would
    # let text a commenter controls relax a project that set
    # hooks.tddImplementation:true, with no bypass-ledger entry. Lowering the
    # discipline stays the user's own `/zensu:tdd-mode --vanilla` session choice,
    # which outranks this flag anyway.
    if [ "$seen_tdd_mode" = true ]; then
      case "$tdd_mode_val" in
        strict) ;;
        *)
          echo "zensu-log.sh $verb: --tdd-mode accepts only 'strict' — a caller may raise the discipline, never lower it; run /zensu:tdd-mode --vanilla to opt this session out" >&2
          exit 2
          ;;
      esac
    fi
    invalid_known_flag=false
    # --tdd-mode belongs to exactly ONE verb, and the rule is written once rather
    # than as a `seen_tdd_mode=false` conjunct in every other branch: a verb added
    # later inherits the refusal instead of silently accepting a flag that only
    # `--tdd-begin` can act on.
    #
    # One real coupling, named rather than alluded to: T18 in
    # tests/structure/test-tdd-mode-toggle.sh derives the gated-verb list by
    # extracting the OUTER verb-dispatch line of this file (the
    # `--tdd-begin|--tdd-complete|...)` case label far above) and comparing it
    # against a hardcoded count. Reformatting THAT line breaks T18; the per-verb
    # matrix below is not what it reads, and this line's placement is a readability
    # choice, not a constraint.
    [ "$seen_tdd_mode" = false ] || [ "$verb" = "--tdd-begin" ] || invalid_known_flag=true
    # --plan names the session's TDD plan for the requirements-table gate below,
    # and belongs to exactly ONE verb for the same reason --tdd-mode does: a verb
    # added later inherits the refusal rather than silently accepting a flag only
    # --tdd-complete can act on.
    [ "$seen_plan" = false ] || [ "$verb" = "--tdd-complete" ] || invalid_known_flag=true
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
        outgoing_bypasses="$(zensu_bypass_display "$begin_state_file")"
        # Mode precedence, resolved ONCE here and then frozen into this chain
        # generation's `vanilla` flag:
        #   1. the session override /zensu:tdd-mode recorded for this session
        #   2. --tdd-mode strict, the CALLER's own default (e.g. the strict
        #      default /zensu:pr-fix-findings asks for) — escalation only
        #   3. hooks.tddImplementation
        #   4. vanilla
        # The user's explicit session choice therefore outranks a skill's default,
        # and a skill's default outranks the config — otherwise the shipped
        # `false` would make every such default unreachable. Only rank 1 can lower
        # the discipline. An unresolvable project dir yields `auto` and falls
        # through, never a forced mode.
        begin_project_dir="$(zensu_resolve_project_dir 2>/dev/null)" || begin_project_dir=""
        begin_mode="$(zensu_tdd_mode_override "$begin_project_dir" "$session_val")"
        # `auto` (and anything unreadable, which the reader also reports as auto)
        # hands the decision down to the caller's flag, then to the config.
        [ "$begin_mode" = "strict" ] || [ "$begin_mode" = "vanilla" ] || begin_mode="$tdd_mode_val"
        case "$begin_mode" in
          strict)  begin_vanilla=false ;;
          vanilla) begin_vanilla=true ;;
          *) if zensu_tdd_strict_enabled; then begin_vanilla=false; else begin_vanilla=true; fi ;;
        esac
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
        # The change set scopes BOTH gates in this verb, so it is computed when
        # either one is armed — the requirements gate below must not inherit the
        # edit-landing switch. The `_tc_` prefix is verb-scoped rather than
        # gate-scoped on purpose: these values belong to --tdd-complete and are
        # read by two different gates, and an `_el_` (edit-landing) name would
        # keep suggesting the second one is borrowing the first one's state.
        # ONE spelling of the receipt path for both gates below. The library and
        # this verb must agree on that filename — a second hand-copy inside the
        # same verb is exactly how such an agreement drifts. Resolved BEFORE the
        # change set, because the root it yields is what that count is measured on.
        _tc_state="$(tdd_state_file "$session_val")" || _tc_state=""
        if [ -z "$_tc_state" ]; then
          echo "zensu-log.sh --tdd-complete: current-session workflow path unavailable" >&2
          exit 1
        fi
        _tc_key="$(basename "$_tc_state")"; _tc_key="${_tc_key#tdd-phase-}"; _tc_key="${_tc_key%.json}"
        _tc_receipt="$(dirname "$_tc_state")/edit-landing-${_tc_key}.json"
        # The root comes from the accessor that OWNS it, not from path surgery over
        # `tdd_state_file`'s layout: that layout belongs to another function, and a
        # change to it would leave this silently mis-rooted with no error. This
        # file already normalizes `CLAUDE_PROJECT_DIR` to the same value for every
        # `--*` verb before any verb body runs, so the two cannot diverge — the
        # accessor is used here for ownership, not to defend against a divergence.
        _tc_root="$(zensu_resolve_project_dir)" || _tc_root=""
        if [ -z "$_tc_root" ]; then
          echo "zensu-log.sh --tdd-complete: Session Control project context unavailable" >&2
          exit 1
        fi
        _tc_changes=0
        # Armed when either gate is ON — and ALSO when either is OFF, because the
        # bypass-ledger records below conjoin on this count too: with both switches
        # off the old condition left the count at 0 and silently recorded NEITHER
        # escape, while both docs promise the recording unconditionally.
        # The git environment is SCRUBBED. Several variables override `-C` discovery
        # or empty the untracked listing, so a one-token prefix on the model's own
        # command would otherwise leave the count at 0 — disarming BOTH gates and,
        # because the two ledger records conjoin on the same count, suppressing both
        # bypass entries with nothing recorded anywhere.
        #
        # State the strength honestly: this raises the cost of a CARELESS or
        # inherited prefix, it is not a defence against a determined session. The
        # same session can write `ZENSU_REQUIREMENTS_GATE=off`, which is documented,
        # named in the refusal text it just read, and costs it only a ledger line.
        # The list is also a DENYLIST over an open-ended namespace: every variable
        # git grows needs an entry here and nothing would notice a gap. It covers
        # discovery (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR`, `GIT_INDEX_FILE`,
        # `GIT_CEILING_DIRECTORIES`, `GIT_DISCOVERY_ACROSS_FILESYSTEM`), the object
        # database (`GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`,
        # `GIT_NAMESPACE`) — `rev-parse --verify HEAD` needs the object FOUND, not
        # just the ref resolved — and config injection (`GIT_CONFIG`,
        # `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`, and `GIT_CONFIG_COUNT`, which is
        # the single lever for the numbered `GIT_CONFIG_KEY_n`/`VALUE_n` pairs, so
        # unsetting it neutralises them without enumerating any). `core.excludesFile`
        # alone empties `ls-files --others --exclude-standard`.
        #
        # The identical unscrubbed shape still ships for the `--chain-done`
        # zero-change terminus below; that one is knowingly left alone rather than
        # changed in passing, and it is the higher-consequence half — that terminus
        # consumes no review ticket.
        # Builtins in a subshell, not `env`: `env` is an external binary, and if it
        # cannot be resolved the `if` below is false, the count stays 0, and every
        # consumer conjoins on it — disarming both gates AND suppressing both ledger
        # records, which is precisely the outcome this wrapper exists to prevent.
        _tc_git() { (
          unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
                GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
                GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM \
                GIT_NAMESPACE GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM \
                GIT_CONFIG_COUNT
          git "$@"
        ); }
        if _tc_git -C "$_tc_root" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
          # `grep -c .` already prints 0 on no match and then exits 1, so an `|| echo 0`
          # fallback would append a SECOND line and turn the count into "0\n0" — which
          # makes the -gt comparison below abort with "integer expression expected" and
          # silently skips the gate on exactly the empty change set it is scoping for.
          _tc_changes="$( { _tc_git -C "$_tc_root" diff --name-only HEAD 2>/dev/null
                            _tc_git -C "$_tc_root" ls-files --others --exclude-standard 2>/dev/null; } \
                          | sort -u | grep -c . 2>/dev/null || true)"
        fi
        # The ledger records an escape that short-circuited a DECISION POINT. Out of
        # scope there is no decision to short-circuit, so the scope conjunct belongs
        # here too — otherwise a zero-change chain reports a bypass of a gate that
        # never ran.
        if [ "${ZENSU_EDIT_LANDING_GATE:-on}" = "off" ] && [ "${_tc_changes:-0}" -gt 0 ]; then
          tdd_record_bypass "$session_val" ZENSU_EDIT_LANDING_GATE >/dev/null 2>&1 || true
        fi
        if [ "${ZENSU_EDIT_LANDING_GATE:-on}" != "off" ] && [ "${_tc_changes:-0}" -gt 0 ]; then
          # `! -L` as well as `-f`: `-f` FOLLOWS a symlink, and the derived-channel
          # reader below refuses one outright (`lstatSync`). Without this the two
          # halves disagree about what a receipt is — a symlink satisfies the
          # precondition here and then derives nothing, which routes an explicit
          # `--plan` into a refusal whose named cause is the audit rather than the
          # receipt. This is a shape check, not an authenticity check: the receipt
          # is a file the session can write, so it bounds accidents, not intent.
          if [ ! -f "$_tc_receipt" ] || [ -L "$_tc_receipt" ]; then
            echo "zensu-log.sh --tdd-complete: refusing to mark implementation complete — no edit-landing receipt for this session (a symlink at that path is refused rather than followed, so it does not count as one). A claimed edit that never landed leaves no diff, so no reviewer would ever see it. Run the Phase 6 step 5b audit first:" >&2
            echo "  bash \"\${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-edit-landing.sh\" --log <run-log> --project \"\${CLAUDE_PROJECT_DIR:-.}\" --session \"<session id>\"" >&2
            echo "Set ZENSU_EDIT_LANDING_GATE=off only for a session the user has explicitly exempted." >&2
            exit 1
          fi
        fi
        # Whether a receipt is EXPECTED at all is decided once, here, and named.
        # The requirements gate below needs the answer — with no receipt there is no
        # run-log stem to cross-check an explicit --plan against — and reading the
        # sibling gate's switch from inside that branch made the gate look as though
        # it inherits the other's configuration. It does not: the scope of each gate
        # is its own, and this is the single, named consequence of the sibling being
        # switched off. One question ("is there a receipt to anchor against?"),
        # asked in one place.
        _tc_receipt_expected=1
        [ "${ZENSU_EDIT_LANDING_GATE:-on}" = "off" ] && _tc_receipt_expected=0
        # Requirements-table gate. /zensu:converge anchors its flow-back audit on
        # the plan's `## Requirements` table. Without a usable one it takes its
        # legacy stop and reports nothing — and /zensu:autopilot's CONVERGE stage,
        # the ONLY edge into OPEN_PR, then passes on an audit that examined
        # nothing. Prose asked for the table (skills/tdd/SKILL.md Phase 2 step 1b)
        # and the only check was the warning-level step 6c, which skips silently
        # when the table is absent; measured across real projects a third of plans
        # carried none. Same move as the receipt gate above: make the obligation a
        # precondition of completion.
        if [ "${ZENSU_REQUIREMENTS_GATE:-on}" = "off" ] && [ "${_tc_changes:-0}" -gt 0 ]; then
          # An env escape is free but never silent: the ledger is what keeps
          # everything a chain renders under "Gates bypassed" true. Fail-open, as
          # every other recording site is — failing to record must not change the
          # completion decision. Scoped like the gate itself: out of scope there is
          # no decision point to short-circuit, so there is no escape to record.
          tdd_record_bypass "$session_val" ZENSU_REQUIREMENTS_GATE >/dev/null 2>&1 || true
        fi
        if [ "${ZENSU_REQUIREMENTS_GATE:-on}" != "off" ] && [ "${_tc_changes:-0}" -gt 0 ]; then
          _rq_plan="$plan_val"
          _rq_explicit="$seen_plan"
          _rq_reason=""
          _rq_derived=""
          if [ "$_rq_explicit" = true ]; then
            # A relative --plan is anchored on the project, exactly like the
            # derived path below. The skill hands this flag a project-relative
            # spelling and the explicit channel is fail-closed, so resolving it
            # against the process cwd would turn a correct plan into a refusal
            # whenever the shell's cwd is not the project root.
            case "$_rq_plan" in
              /*) ;;
              *) [ -n "$_rq_plan" ] && _rq_plan="${_tc_root}/$_rq_plan" ;;
            esac
          fi
          if [ -f "$_tc_receipt" ] && command -v node >/dev/null 2>&1; then
            # Derive from the receipt's own record of the run log it audited. The
            # plan and the log are created from one {SESSION_TS}_tdd-{slug} stem,
            # so .zensu/logs/<stem>.log names .zensu/plans/<stem>.md. Deriving
            # through the receipt — rather than taking the newest plan by mtime,
            # as /zensu:converge does — is what anchors this gate to THIS session,
            # AS STRONGLY AS THE RECEIPT CAN BE TRUSTED. A stale plan cannot satisfy
            # the gate without also rewriting the receipt, and the receipt is an
            # ordinary file in the project tree that the session can rewrite through
            # a Bash redirect. So this is anchoring, not enforcement — the same
            # wording docs/gates.md uses, and the honest one: it buys nothing an
            # attacker wants anyway, because a model that wanted to defeat this gate
            # would simply fill the table.
            # The receipt is a file inside the project, so the session can write
            # it: the reader binds the writer's `schema` discriminator rather than
            # accepting any object with a `log` string, and the value is judged
            # against the project's own logs directory before anything is derived
            # from it. `case` globbing would not do that — `*` matches `/`, so
            # `*/.zensu/logs/*.log` accepts a path anywhere on the host.
            # Both values are translated into the NATIVE namespace before they
            # cross into node, and what comes BACK is a project-relative suffix,
            # never a native absolute path: the shell applies basename/dirname to
            # the result, and on a host whose shell and node namespaces differ
            # (MSYS) a `C:\...` string has no `/` separators, so the derived stem
            # would be malformed and every skill-supplied --plan refused.
            _rq_native_root="$(_tdd_native_path "$_tc_root" 2>/dev/null || printf '%s' "$_tc_root")"
            _rq_native_receipt="$(_tdd_native_path "$_tc_receipt" 2>/dev/null || printf '%s' "$_tc_receipt")"
            _rq_rel="$(ZENSU_RQ_RECEIPT="$_rq_native_receipt" ZENSU_RQ_ROOT="$_rq_native_root" node -e '
              try {
                const fs = require("fs"), path = require("path");
                const st = fs.lstatSync(process.env.ZENSU_RQ_RECEIPT);
                if (st.isSymbolicLink() || !st.isFile() || st.size > 4 * 1024 * 1024) process.exit(0);
                const j = JSON.parse(fs.readFileSync(process.env.ZENSU_RQ_RECEIPT, "utf8"));
                // TWO schema versions are accepted, and the discriminator is what
                // tells them apart rather than the value shape. `edit-landing-v1`
                // persisted `log` as the caller spelled `--log`; `edit-landing-v2`
                // persists it project-relative. Holding one schema name over two
                // value domains would leave this reader guessing from a leading
                // slash — and a plugin upgrade landing between the step 5b audit and
                // `--tdd-complete` is explicitly SERVED by the runtime-lineage rule,
                // so a v1 receipt read by this code is a supported state, not a
                // corruption. Both are resolved the same way below and judged by
                // CONTAINMENT, never by spelling.
                const rqSchemaVersion = !j ? 0
                  : j.schema === "edit-landing-v2" ? 2
                  : j.schema === "edit-landing-v1" ? 1 : 0;
                if (!rqSchemaVersion || typeof j.log !== "string" || j.log === "") process.exit(0);
                // The receipt is a gate input the session can write, so it gets the
                // same treatment the plan reader gets: no symlink, regular file
                // only, and a bounded read.
                // Both sides are canonicalized before they are compared. On macOS
                // a temp root is spelled /var/... by the caller and /private/var/...
                // by realpath, and an uncanonicalized comparison rejects the very
                // path it was handed — a containment check that fails open into
                // "no derived plan" instead of doing its job.
                const canon = (p) => { try { return fs.realpathSync(p); } catch (e) { return path.resolve(p); } };
                const root = canon(path.resolve(process.env.ZENSU_RQ_ROOT));
                const logsDirRaw = path.join(root, ".zensu", "logs");
                // Canonicalizing a SYMLINKED logs directory would compare the link
                // target against itself and admit anything the link points at, so
                // the directory itself is refused rather than resolved through.
                try { if (fs.lstatSync(logsDirRaw).isSymbolicLink()) process.exit(0); } catch (e) {}
                const logsDir = canon(logsDirRaw);
                const relLogs = path.relative(root, logsDir);
                // Same anchored test the plan check uses seven lines down, including
                // the isAbsolute arm: on win32 path.relative returns an ABSOLUTE
                // path when the two sides are on different drives, so the `..`
                // prefix test alone would pass a logs dir on another drive.
                if (relLogs === ".." || relLogs.startsWith(".." + path.sep) || path.isAbsolute(relLogs)) process.exit(0);
                // A project-relative `log` (what a v2 writer persists) needs no
                // namespace translation at all. An ABSOLUTE value is a v1 receipt or
                // an out-of-project log, and it is judged by where it RESOLVES, not
                // by how it is spelled. The previous rule rejected any leading-slash
                // value on win32 outright; that turned a perfectly readable legacy
                // receipt into no-derivation, which — because the shipped skill
                // always passes --plan — became a hard `exit 1` rather than a
                // warning. A foreign-namespace value still fails, but it fails at the
                // containment test below, which is the check that can actually tell:
                // win32 path.resolve splices a POSIX `/d/a/...` under the current
                // drive, and the spliced result is not inside logsDir.
                const raw = path.resolve(root, j.log);
                const resolved = path.join(canon(path.dirname(raw)), path.basename(raw));
                const rel = path.relative(logsDir, resolved);
                // Anchored, not a bare `startsWith("..")`: a real file named
                // `..bak.log` inside the directory is INSIDE it, and the unanchored
                // form rejects it. CLAUDE.md names this exact defect elsewhere.
                if (rel === "" || rel === ".." || rel.startsWith(".." + path.sep) || path.isAbsolute(rel)) process.exit(0);
                if (!resolved.endsWith(".log")) process.exit(0);
                // Project-RELATIVE, so the shell never applies basename/dirname to a
                // foreign-namespace absolute path.
                process.stdout.write(path.relative(root, resolved).split(path.sep).join("/"));
              } catch (e) {}
            ' 2>/dev/null || true)"
            if [ -n "$_rq_rel" ]; then
              # `_rq_rel` is project-relative with `/` separators by construction,
              # so basename/dirname are safe here on every host.
              _rq_stem="$(basename "$_rq_rel" .log)"
              _rq_derived="${_tc_root}/.zensu/plans/${_rq_stem}.md"
              # The DERIVED channel gets the same plans-directory bound the explicit
              # one gets. Without it the two entry paths enforce different rules for
              # one gate, and the derived path is the one an unwedged chain takes,
              # because the recovery renderer emits `--tdd-complete` flag-free.
              if [ -L "${_tc_root}/.zensu/plans" ]; then
                _rq_derived=""
              fi
              [ "$_rq_explicit" = true ] || _rq_plan="$_rq_derived"
            fi
          fi
          # An explicit --plan is caller-supplied, so it is bounded the same way
          # the derived one is: inside the project's own plans directory, and —
          # when a receipt exists to compare against — naming the same stem the
          # derivation would have. Without this the flag silently defeats the
          # session anchoring the derivation exists to provide, because any older
          # plan with one filled row would satisfy the gate.
          if [ "$_rq_explicit" = true ] && [ -n "$_rq_plan" ]; then
            # Both sides canonicalized before comparison, for the same reason the
            # derivation canonicalizes: the caller's spelling of the project root
            # and the kernel's can differ (macOS /var vs /private/var), and a raw
            # string compare would reject the session's own plan.
            _rq_plans_dir="$(cd "$_tc_root" 2>/dev/null && pwd -P)/.zensu/plans"
            # A SYMLINKED plans directory is refused rather than resolved through:
            # canonicalizing both sides and comparing them for equality would then
            # compare the link target with itself and accept a plan anywhere on the
            # host. Same rule the derived channel applies to .zensu/logs.
            if [ -L "$_rq_plans_dir" ]; then
              _rq_reason="${_rq_plans_dir} is a symlink; refusing to resolve a plan through it"
            else
              _rq_plans_dir="$(cd "$_rq_plans_dir" 2>/dev/null && pwd -P || printf '%s' "$_rq_plans_dir")"
              _rq_root_canon="$(cd "$_tc_root" 2>/dev/null && pwd -P || printf '%s' "$_tc_root")"
              # The canonicalized plans dir must still be UNDER the canonicalized
              # root: the leaf lstat above does not see a relocated `.zensu`
              # component, and the derived channel carries the same assertion.
              case "$_rq_plans_dir" in
                "$_rq_root_canon"/*) ;;
                *) _rq_reason="${_rq_plans_dir} resolves outside the session root ${_rq_root_canon}" ;;
              esac
              _rq_plan_dir="$(cd "$(dirname "$_rq_plan")" 2>/dev/null && pwd -P || printf '%s' "$(dirname "$_rq_plan")")"
              if [ -z "$_rq_reason" ] && [ "$_rq_plan_dir" != "$_rq_plans_dir" ]; then
                _rq_reason="the --plan path is outside ${_rq_plans_dir}: ${_rq_plan}"
              fi
            fi
            # Compared by STEM, not by full path: the derived value is canonical
            # (realpath) while the explicit one is anchored on CLAUDE_PROJECT_DIR
            # as given, and on a host where those two spellings differ a path
            # comparison would reject every correct plan.
            if [ -z "$_rq_reason" ] && [ -n "$_rq_derived" ] \
               && [ "$(basename "$_rq_plan")" != "$(basename "$_rq_derived")" ]; then
              _rq_reason="the --plan path does not name this session's run log sibling ($(basename "$_rq_derived")): ${_rq_plan}. If this generation has not run the Phase 6 step 5b audit yet, the receipt still records the PREVIOUS generation's log — re-run the audit rather than changing the path."
            fi
            # The stem bound is UNCONDITIONAL. Without a derived stem there is
            # nothing to cross-check the caller's assertion against, and falling
            # through to the directory bound alone would let any older plan in
            # .zensu/plans/ satisfy the gate — precisely the stale-plan hole the
            # derivation exists to close, reachable simply by switching the sibling
            # gate off. Refusing here keeps the documented bound true as written.
            # ...EXCEPT when the receipt gate was deliberately switched off. That
            # switch is documented as exempting a session from the receipt
            # precondition, and no receipt means no derivable stem — refusing here
            # would make the documented exemption unusable for the shipped
            # invocation, which always passes --plan. The bound is dropped, not
            # faked: the weaker state is disclosed on stderr instead.
            if [ -z "$_rq_reason" ] && [ -z "$_rq_derived" ] \
               && [ "$_tc_receipt_expected" -eq 0 ]; then
              echo "zensu-log.sh --tdd-complete: REQUIREMENTS GATE STEM UNCHECKED — ZENSU_EDIT_LANDING_GATE=off leaves no receipt, so the --plan path could not be cross-checked against this session's run log. Only the plans-directory bound applies." >&2
            elif [ -z "$_rq_reason" ] && [ -z "$_rq_derived" ]; then
              # Two causes reach here and they need different remedies, so the
              # message is split on whether a receipt is actually on disk. It also
              # must NOT end with "or omit --plan": in exactly this state dropping
              # the flag does not refuse at all — `_rq_plan` stays empty, the judge
              # branch below is skipped, and the run exits through
              # REQUIREMENTS GATE UNRESOLVED, which does not block. The one branch
              # that fails closed would have been naming the spelling that fails
              # open, to the model that is reading it.
              # Both branches keep the same leading clause on purpose — it is the
              # state, and it is what downstream readers match on — and differ only
              # in the REMEDY, which is the part that was wrong before: telling an
              # author to run an audit that has already run sends them nowhere.
              if [ -f "$_tc_receipt" ]; then
                _rq_reason="no run-log stem could be derived for this session: the edit-landing receipt is present, but the run log it records does not resolve inside ${_tc_root}/.zensu/logs/, so an explicit --plan cannot be cross-checked against it. Re-run the Phase 6 step 5b edit-landing audit for THIS generation so the receipt names this generation's log"
              else
                _rq_reason="no run-log stem could be derived for this session, so an explicit --plan cannot be cross-checked against it. Run the Phase 6 step 5b edit-landing audit first — it writes the receipt this check reads"
              fi
            fi
          fi
          # An explicit --plan is judged even when it names nothing: the caller
          # asserted where the plan is, and silently skipping a typo would leave
          # the gate looking armed while it never ran. A DERIVED path that is not
          # there is different — nothing was asserted, so there is nothing to hold
          # against the chain.
          if [ -n "$_rq_reason" ]; then
            # The generic tail deliberately does NOT offer "omit --plan". For the
            # no-derivable-stem reason above, omitting the flag is the spelling that
            # reaches the non-blocking UNRESOLVED arm, so advertising it here turns
            # this refusal into a documented way around itself. Pointing at the plan
            # is the remedy that keeps the gate doing its job.
            echo "zensu-log.sh --tdd-complete: refusing to mark implementation complete — ${_rq_reason}. The requirements-table gate judges this session's own plan; pass the plan this chain wrote under ${_tc_root}/.zensu/plans/." >&2
            echo "Set ZENSU_REQUIREMENTS_GATE=off only for a session the user has explicitly exempted." >&2
            exit 1
          fi
          if [ "$_rq_explicit" = true ] || { [ -n "$_rq_plan" ] && [ -f "$_rq_plan" ]; }; then
            _rq_lib="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-plan-requirements.sh"
            if [ ! -f "$_rq_lib" ] || [ -L "$_rq_lib" ] || [ ! -r "$_rq_lib" ]; then
              # A load fault is NOT a verdict about the plan. Reporting it as one
              # would send the user editing a table that was never read.
              #
              # This branch deliberately does NOT name the escape hatch, unlike the
              # three refusal sites around it. A missing, unreadable or symlinked
              # gate library is a plugin-INTEGRITY fault: something happened to the
              # installation that nobody has explained, and the honest instruction is
              # stop and repair, not skip. The other sites can at least argue the
              # user might legitimately exempt a session whose plan is genuinely
              # unjudgeable; this one cannot, and it is the model that reads the
              # line. An operator who truly must proceed can still set the variable —
              # they just should not learn it from the integrity failure itself.
              echo "zensu-log.sh --tdd-complete: the requirements-table check could not run — its library is missing, unreadable, or a symlink: ${_rq_lib}. The plan was NOT judged." >&2
              echo "Reinstall the plugin and run /zensu:doctor; the executing installation is not intact." >&2
              exit 1
            fi
            _rq_verdict="$(bash "$_rq_lib" --plan "$_rq_plan" 2>&1)"
            _rq_rc=$?
            case "$_rq_rc" in
              0) ;;
              3|4)
                echo "zensu-log.sh --tdd-complete: refusing to mark implementation complete — this session's TDD plan carries no usable \`## Requirements\` table, so /zensu:converge would audit nothing and still close clean:" >&2
                echo "  ${_rq_verdict}" >&2
                echo "Fill the table with AC-###/FR-### rows per Phase 2 step 1b, then re-run. Pass --plan <path> when the plan is not the run log's sibling under .zensu/plans/." >&2
                echo "Set ZENSU_REQUIREMENTS_GATE=off only for a session the user has explicitly exempted." >&2
                exit 1
                ;;
              *)
                # Exit 2 (unreadable/usage) and anything else mean the table was
                # never judged. Same refusal direction, deliberately different
                # wording: the remedy is the path or the file, not the contents.
                echo "zensu-log.sh --tdd-complete: the requirements-table check could not judge the plan (exit ${_rq_rc}). The table was NOT read, so this is not a verdict about its contents:" >&2
                echo "  ${_rq_verdict}" >&2
                echo "Point --plan at a readable plan under .zensu/plans/, or set ZENSU_REQUIREMENTS_GATE=off for a session the user has explicitly exempted." >&2
                exit 1
                ;;
            esac
          else
            # Armed, in scope, and nothing was judged. Staying silent here would
            # reproduce the exact indistinguishability this gate exists to remove:
            # "the table passed" and "no table was ever looked at" would read the
            # same to everyone downstream.
            # Two distinct states reach here, and naming the wrong one sends the
            # reader to the wrong remedy: nothing was derived at all, or a plan WAS
            # derived and the file is simply not there.
            if [ -n "$_rq_plan" ]; then
              echo "zensu-log.sh --tdd-complete: REQUIREMENTS GATE UNRESOLVED — the plan derived for this session does not exist: ${_rq_plan}. The \`## Requirements\` table was NOT checked. Completion is not blocked on it." >&2
            else
              echo "zensu-log.sh --tdd-complete: REQUIREMENTS GATE UNRESOLVED — no --plan was passed and no plan could be derived from this session's edit-landing receipt, so the \`## Requirements\` table was NOT checked. Completion is not blocked on it." >&2
            fi
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
          zensu_render_terminus_bypasses "$session_val"
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
        chain_done_rc=$?
        [ "$chain_done_rc" -eq 0 ] && zensu_render_terminus_bypasses "$session_val"
        exit "$chain_done_rc"
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
        reset_bypasses="$(zensu_bypass_display "$reset_state")"
        reset_rc=0
        reset_ctx='{}'
        if [ -e "$reset_state" ] || [ -L "$reset_state" ]; then
          reset_ctx="$(tdd_autopilot_context "$reset_state" "$session_val" 2>/dev/null)" || {
            echo "zensu-log.sh --tdd-reset: corrupt or incomplete Autopilot linkage" >&2
            [ -n "$reset_bypasses" ] && echo "previous-run bypasses preserved: $reset_bypasses" >&2
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
          ' 2>/dev/null)" || {
            [ -n "$reset_bypasses" ] && echo "previous-run bypasses preserved: $reset_bypasses" >&2
            exit 1
          }
          IFS=$'\t' read -r reset_run reset_attempt reset_chain <<<"$reset_fields"
          source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh"
          if ! autopilot_reset_inner "$reset_run" "${CLAUDE_PROJECT_DIR:-.}" "$session_val" \
              "$reset_attempt" "$reset_chain"; then
            echo "zensu-log.sh --tdd-reset: an active or resumable durable outer run owns this chain" >&2
            [ -n "$reset_bypasses" ] && echo "previous-run bypasses preserved: $reset_bypasses" >&2
            exit 1
          fi
          reset_rc=0
        else
          tdd_reset_pending_review_claim "$session_val"
          reset_rc=$?
        fi
        if [ "$reset_rc" -eq 0 ]; then
          [ -n "$reset_bypasses" ] && echo "previous-run bypasses (cleared now): $reset_bypasses"
        else
          [ -n "$reset_bypasses" ] && echo "previous-run bypasses preserved: $reset_bypasses" >&2
        fi
        exit "$reset_rc"
        ;;
    esac
    state_verb_rc=$?
    [ "$state_verb_rc" -eq 0 ] || zensu_state_failure_hint "$verb" "$session_val"
    exit "$state_verb_rc"
    ;;
esac

# The inline timestamp prefix, resolved from logging.timestampStyle. Both the
# legacy `timestamp` verb and the `append` writer below call it, so the two can
# never drift into printing different prefixes for the same configuration.
_zensu_log_timestamp_prefix() {
  local start="${1:-}" style now diff days rem
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
}

cmd="${1:-timestamp}"
case "$cmd" in
  timestamp)
    _zensu_log_timestamp_prefix "${2:-}"
    ;;
  append)
    # The narrative-log WRITER. It exists because the old recipe
    # (`printf "$(zensu-log.sh timestamp …)" "<msg>" >> {log}`) never routed the
    # MESSAGE through this helper at all — only the prefix — so nothing could
    # rewrite the absolute developer paths that a quoted `cmd="cd \"/Users/…\""`
    # drags into an artifact consuming repos commit.
    #
    # Deliberately NOT a `--append` verb: a leading `--` selects the Session
    # Control binding case at the top of this file, and a log append must keep
    # working in a shell where CLAUDE_CODE_SESSION_ID or CLAUDE_PLUGIN_DATA is
    # absent. The project root comes from the log path instead, which is
    # self-anchoring and needs no environment at all.
    shift
    log_val=""
    msg_val=""
    msg_seen=0
    start_val=""
    truncate_val=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --log)      log_val="${2:-}";   shift 2 || break ;;
        --message)
          # `msg_seen` is set only when a VALUE was actually consumed. Setting it
          # on the flag alone leaves the malformed `--message` as the last token
          # indistinguishable from a supplied empty string, which is exactly the
          # timestamp-only line this guard exists to refuse.
          if [ "$#" -lt 2 ]; then
            echo "zensu-log.sh append: --message needs a value" >&2
            exit 2
          fi
          msg_val="$2"; msg_seen=1; shift 2
          ;;
        --start)    start_val="${2:-}"; shift 2 || break ;;
        --truncate) truncate_val=1;     shift ;;
        *)
          echo "zensu-log.sh append: unknown option '$1'" >&2
          exit 2
          ;;
      esac
    done

    if [ -z "$log_val" ]; then
      echo "zensu-log.sh append: --log <file> is required" >&2
      exit 2
    fi
    # A flag consumed as the last token leaves ${2:-} empty and `shift 2` fails
    # into the loop break, so an absent VALUE is indistinguishable from an
    # absent flag unless it is tracked. Writing a timestamp-only line into a
    # committed audit log is not a reasonable answer to a malformed call.
    if [ "$msg_seen" -ne 1 ]; then
      echo "zensu-log.sh append: --message <text> is required" >&2
      exit 2
    fi
    if [ -L "$log_val" ]; then
      echo "zensu-log.sh append: refusing to write through a symlinked log path" >&2
      exit 2
    fi
    # NOT gated on CLAUDE_PROJECT_DIR, and the reason is worth writing down: an
    # earlier revision made `--truncate` refuse without it, which broke the
    # shipped Phase 2 recipe outright — that variable is absent from the model's
    # Bash environment on this host, and `{log_file}` is rendered from
    # `${CLAUDE_PROJECT_DIR:-.}` precisely because it may be. The binding would
    # also have bought little: an env var the caller sets is not an authority.
    # What actually constrains the destructive mode is the module — the `logs`
    # bucket only, never a `witness-` name, a canonicalized artifact directory,
    # and a descriptor judged for isFile, nlink and dev+ino. When the variable IS set
    # it is still passed through as `expectedRoot`, so a bound session gets the
    # stricter check for free.

    # Module transport, mechanism 2 of the two this repo accepts (see
    # tests/structure/test-msys-special-plugin-module-boundaries.sh): the lib
    # DIRECTORY is rendered natively by zensu-host-path.sh, the file name is
    # appended, and the guarded result travels in an ENVIRONMENT variable — never
    # as an argv token carrying the plugin root.
    redact_lib_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-host-path.sh" \
      "${CLAUDE_PLUGIN_ROOT}/hooks/lib")" || redact_lib_dir=""
    redact_lib="$redact_lib_dir/zensu-artifact-redact-v1.js"
    secret_lib="$redact_lib_dir/secret-patterns.js"
    # Fail LOUD rather than write an unredacted line. A host without node cannot
    # arm a chain at all (--tdd-begin needs Session Control, which needs node),
    # so this refusal is unreachable in any session that has a log to write to.
    if ! command -v node >/dev/null 2>&1; then
      # The wording here deliberately avoids the bind-failure hint phrase used
      # further up this file: test-session-control-claude greps the WHOLE file
      # for those three literals and pins their order against the guards in
      # zensu_bind_model_session, so a second occurrence anywhere — comments
      # included — breaks the mirror.
      echo "zensu-log.sh append: node is required to redact the message — refusing to write an unredacted log line" >&2
      exit 2
    fi
    # The guard ACTS: it drops the path, so the node side takes its own
    # fail-open branch and reports the scan as unavailable. It used to warn and
    # then do nothing — a symlinked-but-valid scanner was still required, still
    # ran, and refused the line, so the warning claimed an outcome that did not
    # happen and the refusal arrived after a message saying it would not. A
    # branch that warns about an outcome it does not produce trains the reader
    # to ignore it.
    #
    # A symlink is refused rather than followed for the same reason the redactor
    # refuses one: this is a path the session itself can write, and a scanner
    # that can be repointed is not a control. It fails OPEN here rather than
    # exiting, because the scan is an improvement and the redaction is the
    # guarantee — losing the scan must not cost the log line.
    if [ ! -f "$secret_lib" ] || [ -L "$secret_lib" ]; then
      echo "zensu-log.sh append: the credential scanner is missing or is a symlink; the line will be written unscanned" >&2
      secret_lib=""
    fi
    if [ -z "$redact_lib_dir" ] || [ ! -f "$redact_lib" ] || [ -L "$redact_lib" ]; then
      echo "zensu-log.sh append: the artifact redactor is missing — refusing to write an unredacted log line" >&2
      exit 2
    fi
    # Every sibling gate records its own `ZENSU_*=off` escape, and the chain-end
    # report renders that ledger under "Gates bypassed" — a list the reader takes
    # as complete. This chokepoint honoured the opt-out and recorded nothing, so
    # a session that turned the credential scan off read as one that never did.
    #
    # Best-effort BY DESIGN, and in a subshell so the phase library never enters
    # the append path: a ledger write must not be able to cost a log line. The
    # bound is real and worth stating — `zensu_resolve_session_id` with no
    # argument reads `ZENSU_SESSION_KEY`, which SessionStart injects, so an
    # `append` run outside a Zensu-started session records nothing. That is the
    # same identity every other ledger writer needs; there is no second source
    # for it here, because this verb deliberately carries no session bind.
    if [ "${ZENSU_SECRET_SCAN:-}" = "off" ]; then
      (
        # BOTH libraries, and the second is not optional: `append` skips the
        # binding `case` this file runs for every `--verb`, so nothing has
        # sourced `zensu-session.sh` by here and `zensu_resolve_session_id` is
        # simply undefined. The failure is silent — an empty id, a no-op write,
        # exit 0 — which is exactly the under-reporting this branch exists to fix.
        source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
        source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
        bypass_sid="$(zensu_resolve_session_id "" 2>/dev/null)" || bypass_sid=""
        [ -n "$bypass_sid" ] && tdd_record_bypass "$bypass_sid" ZENSU_SECRET_SCAN
      ) >/dev/null 2>&1 || true
    fi
    # CONTAINMENT, and it is not optional. Without it this verb is a write /
    # truncate primitive with a caller-supplied destination that no Bash gate
    # can see: it carries none of the redirect, tee, sed -i, dd or heredoc
    # tokens `bash-source-write-parse.js` recognizes as a channel, so rules
    # (A)/(B) of the source-write gate never judge it. The module refuses any
    # `--log` that does not resolve to a real `<root>/.zensu/logs/<file>`
    # — canonicalizing the artifact directory, so a symlinked `.zensu/logs`
    # cannot carry the write out of the project — and a refusal is a non-zero
    # exit, which this branch turns into a loud failure rather than a write.
    #
    # The same check closes the quieter half: an unrecognized shape used to make
    # the derived project root empty, which SKIPPED rule 1 and wrote a partially
    # redacted line under exit 0.
    #
    # `--project` is passed when CLAUDE_PROJECT_DIR is set so that this writer
    # and hooks/post-bash-witness.sh — which resolves the root from the Session
    # Control record — substitute identically. They must, or the equality match
    # in zensu-evidence-crosscheck.js reports an EVIDENCE GAP; supplying both
    # candidate roots makes the result the same whenever EITHER is right.
    # The WRITE happens inside the module, not through a shell redirect. A `>>`
    # names a path and follows whatever it finds, so the validation above and the
    # write would name different objects — and `[ -L ]` is blind to a hard link
    # planted in the artifact directory, which would turn this verb into an
    # append/truncate primitive on any file on the same filesystem. The module
    # opens with O_NOFOLLOW and judges the DESCRIPTOR, so the object checked is
    # the object written.
    if ! printf '%s' "$msg_val" \
      | ZENSU_REDACT_LIB="$redact_lib" \
        ZENSU_APPEND_LOG="$log_val" \
        ZENSU_APPEND_PREFIX="$(_zensu_log_timestamp_prefix "$start_val")" \
        ZENSU_APPEND_TRUNCATE="$truncate_val" \
        ZENSU_APPEND_PROJECT="${CLAUDE_PROJECT_DIR:-}" \
        ZENSU_SECRET_PATTERNS="$secret_lib" \
        node -e '
        // Wrapped in a function because `node -e` evaluates at true top level,
        // where `return` is a syntax error.
        (function main() {
          const fs = require("node:fs");
          const path = require("node:path");
          const mod = require(process.env.ZENSU_REDACT_LIB);
          const refuse = (reason) => {
            // process.exit() does not flush an async pipe write, so the specific
            // reason would be lost and the operator would see only the shells
            // catch-all. Set the code and return instead.
            process.stderr.write("zensu-log.sh append: refused (" + reason + ")\n");
            process.exitCode = 2;
          };
          const log = process.env.ZENSU_APPEND_LOG;
          const expected = process.env.ZENSU_APPEND_PROJECT || undefined;
          const target = mod.resolveArtifactTarget(log, expected);
          if (!target.ok) { refuse(target.reason); return; }
          // CONTAINMENT for the DESTRUCTIVE mode when the caller supplied no
          // authority, which is the DEFAULT path and not an edge case:
          // CLAUDE_PROJECT_DIR is absent from the Bash environment the model runs
          // on this host, which is exactly why the shipped recipe renders
          // {log_file} from ${CLAUDE_PROJECT_DIR:-.}.
          // (No apostrophes anywhere in this block: it lives inside a
          // single-quoted node -e program, where one terminates the shell string
          // and turns the next brace into a bash syntax error.)
          //
          // Without this, `resolveArtifactTarget` skips its binding block and
          // containment reduces to artifact SHAPE: any absolute --log resolving
          // to a real <anyroot>/.zensu/logs/<name>.log is an accepted
          // destination. The verb this replaced carried a redirect, so the
          // source-write gate judged its destination against the session root;
          // leaving this unbound made the change a NARROWING of an existing
          // control, and the reachable targets are the committed audit logs of
          // sibling checkouts.
          //
          // SCOPED TO `replace`, and the scope was MEASURED rather than assumed.
          // Applying cwd-or-ancestor to every mode denies a working and ordinary
          // call shape: an absolute --log issued from an unrelated cwd, which is
          // how five checks in the suite, and the log commands of the TDD chains
          // in this repo, invoke the verb. An unbound append adds a line to a
          // foreign audit log; an unbound --truncate DESTROYS one, and only the
          // second is worth denying that shape over.
          //
          // ACCEPTED RESIDUAL, stated rather than implied: the additive mode is
          // still bound by artifact SHAPE only, so an absolute --log naming any
          // project .zensu/logs artifact on the host is appendable. R44b pins
          // that judgement so closing it later is deliberate.
          //
          // ANCESTOR rather than equality, because running the verb from a
          // subdirectory of the project is ordinary. It lives HERE rather than in
          // `resolveArtifactTarget` because `redactFile` and the sweep resolve
          // with no expectedRoot and a caller root that need not be an ancestor
          // of the cwd, so the same check in the shared resolver denies them.
          //
          // WHAT THIS ANCHOR IS WORTH, stated because the paragraph above rejects
          // `CLAUDE_PROJECT_DIR` as "an env var the caller sets" and then anchors
          // on something the caller sets more freely still. The anchor is the
          // PROCESS CWD, and `cd` selects it in the same command with no write
          // channel for `bash-source-write-parse.js` to recognize — so
          // `cd <sibling> && … append --truncate --log <sibling>/.zensu/logs/x.log`
          // satisfies this check and is judged by no gate at any point.
          //
          // So this bounds an ACCIDENTAL cross-project truncate — the drifted-cwd
          // shape, which is the one that actually happens — and not a deliberate
          // one. It does NOT restore what the pre-change redirect form had: that
          // was judged against the session root, an authority outside the command,
          // while this is state the command sets in its own first token. Anchoring
          // on the `project_root` of the Session Control record — the authority
          // `hooks/post-bash-witness.sh` uses — is the stronger spelling and is
          // deliberately NOT taken here, because this verb carries no session bind
          // and adding one would make every log line depend on a bind that the
          // append path exists to work without. R44c pins the passing shape as a
          // residual so that narrowing it later is a decision, not a discovery.
          const replaceMode = process.env.ZENSU_APPEND_TRUNCATE === "1";
          if (expected === undefined && replaceMode) {
            // BOTH sides are canonicalized. `resolveArtifactTarget` returns
            // `projectRoot` un-realpathed, so on macOS it reads /var/folders/...
            // while process.cwd() resolves to /private/var/folders/... — the
            // same alias pair the redaction rules handle by hand. Comparing the
            // two spellings directly refuses every legitimate call under a temp
            // directory, which is how this was caught.
            let here;
            let rootReal;
            try {
              here = fs.realpathSync(process.cwd());
              rootReal = fs.realpathSync(target.projectRoot);
            } catch (_) {
              refuse("project-root-unusable");
              return;
            }
            if (here !== rootReal && !here.startsWith(rootReal + path.sep)) {
              refuse("foreign-project");
              return;
            }
          }
          let message;
          try {
            message = fs.readFileSync(0, "utf8");
          } catch (_) {
            // A read fault must NOT degrade to an empty message: that writes the
            // timestamp-only line the --message guard exists to refuse, under a
            // success exit.
            refuse("message-unreadable");
            return;
          }
          // The message is scanned for credential VALUES before it is written.
          // This restores, at the new chokepoint, the control the move off the
          // command line removed: the old `printf … >> {log}` form carried a
          // write channel, so pre-write-secret-scan.sh saw the message; `append`
          // carries none, and the narrative log is an artifact consuming repos
          // commit. It REFUSES rather than redacting — a credential value is not
          // a location, and silently rewriting one would hide it from the person
          // who has to rotate it. `ZENSU_SECRET_SCAN=off` is honoured, the same
          // escape the gate itself teaches, so a false positive is not a wedge.
          if (process.env.ZENSU_SECRET_SCAN !== "off") {
            try {
              const patterns = require(process.env.ZENSU_SECRET_PATTERNS);
              const hit = patterns.scan(message);
              if (hit && hit.matches && hit.matches.length) {
                const rules = [...new Set(hit.matches.map((m) => m.rule))].join(", ");
                // The surgical escape first, matching the sibling gate: the
                // marker is visible in the committed artifact, the env opt-out
                // is not.
                refuse("secret-value-detected: " + rules
                  + " — remove it, or append the zensu-secret-allow marker to that line,"
                  + " or set ZENSU_SECRET_SCAN=off for this call if it is a false positive");
                return;
              }
            } catch (_) {
              // Fail OPEN — the scan is an improvement, never a precondition —
              // but never SILENTLY: a control that quietly became a no-op is
              // indistinguishable from one that passed.
              process.stderr.write(
                "zensu-log.sh append: credential scan unavailable; the line was written unscanned\n");
            }
          }
          const roots = expected ? [expected, target.projectRoot] : target.projectRoot;
          const line = (process.env.ZENSU_APPEND_PREFIX || "")
            + mod.redact(message, { projectRoot: roots, home: mod.defaultHome() }) + "\n";
          const result = mod.writeArtifactLine(log, line, {
            mode: process.env.ZENSU_APPEND_TRUNCATE === "1" ? "replace" : "append",
            expectedRoot: expected,
          });
          if (!result.written) { refuse(result.reason); }
        }());
        '; then
      echo "zensu-log.sh append: refusing to write — the log path is not a .zensu artifact of this project, is not a plain unlinked file, or redaction failed" >&2
      exit 2
    fi
    ;;
  style)
    _zensu_log_style
    ;;
  *)
    echo "usage: zensu-log.sh {append --log <file> --message <text> [--start <epoch>] [--truncate] | timestamp <epoch> | style}" >&2
    exit 2
    ;;
esac
