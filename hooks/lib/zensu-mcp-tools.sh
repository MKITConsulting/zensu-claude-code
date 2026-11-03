#!/bin/bash

# get_context_pack (knowledge context-pack) is a read covered by get_.
ZENSU_READ_TOOL_PREFIXES="list_ get_ search_ suggest_"
ZENSU_READ_TOOL_NAMES="analyze_feature_security analyze_journey_health generate_claude_md generate_threat_model validate_feature_security ghost_get_candidates pulse_start_session pulse_end_session pulse_session_summary view_feature"
ZENSU_MUTATION_TOOL_NAMES="abandon_work_plan accept_work_plan_followup add_feature_to_roadmap add_product_repository add_security_test add_subfeature answer_work_question apply_bootstrap approve_work_order approve_work_plan ask_work_order_question bootstrap_from_vision bulk_link_source_files cancel_work_order claim_work_order complete_security_review confirm_work_order_claim confirm_work_order_merge confirm_work_plan_merge create_feature create_journey_step create_milestone create_mock create_product create_product_vision create_revision create_roadmap create_tier create_user_journey create_wiki_page create_work_order delete_journey_step delete_milestone delete_roadmap deprecate_feature dismiss_work_plan_followup finalize_work_plan ghost_apply ghost_approve_candidate ghost_batch_review ghost_reject_candidate ghost_scan import_repo link_docs link_source_files link_test merge_features overturn_work_answer promote_subfeature push_work_plan release_work_order remove_feature_from_roadmap remove_product_repository report_work_order_followup report_work_order_usage requeue_work_order scaffold_agent send_work_order_event send_work_order_heartbeat set_automation_policy set_feature_tiers set_security_classification split_feature update_bootstrap_step update_feature update_journey_step update_product_repository update_roadmap update_wiki_page"
ZENSU_HUMAN_DECISION_TOOL_NAMES="abandon_work_plan accept_work_plan_followup add_product_repository answer_work_question approve_work_order approve_work_plan cancel_work_order confirm_work_order_merge confirm_work_plan_merge create_work_order dismiss_work_plan_followup finalize_work_plan overturn_work_answer push_work_plan remove_product_repository requeue_work_order set_automation_policy update_product_repository"
ZENSU_MUTATION_TOOL_NAMES="$ZENSU_MUTATION_TOOL_NAMES bind_ai_work_product start_ai_work_capture submit_ai_work_result"
ZENSU_AI_WORK_CAPTURE_TOOL_NAMES="bind_ai_work_product start_ai_work_capture submit_ai_work_result"
ZENSU_WORK_ORDER_TOOL_NAMES="ask_work_order_question claim_work_order confirm_work_order_claim release_work_order report_work_order_followup report_work_order_usage send_work_order_event send_work_order_heartbeat"
ZENSU_WORK_ORDER_SESSION_TOOL_NAMES="ask_work_order_question report_work_order_followup"

zensu_is_read_tool() {
  local t="${1:-}" p
  [ -z "$t" ] && return 1
  for p in $ZENSU_READ_TOOL_PREFIXES; do
    case "$t" in ${p}*) return 0 ;; esac
  done
  for p in $ZENSU_READ_TOOL_NAMES; do
    [ "$t" = "$p" ] && return 0
  done
  return 1
}

zensu_is_mutation_tool() {
  local t="${1:-}" p
  [ -z "$t" ] && return 1
  for p in $ZENSU_MUTATION_TOOL_NAMES; do
    [ "$t" = "$p" ] && return 0
  done
  return 1
}

zensu_is_zensu_tool() {
  local t="${1:-}"
  zensu_is_read_tool "$t" && return 0
  zensu_is_mutation_tool "$t" && return 0
  return 1
}

zensu_tool_in_list() {
  local t="${1:-}" p
  [ -z "$t" ] && return 1
  for p in ${2:-}; do
    [ "$t" = "$p" ] && return 0
  done
  return 1
}

zensu_is_human_decision_tool() {
  zensu_tool_in_list "${1:-}" "$ZENSU_HUMAN_DECISION_TOOL_NAMES"
}

zensu_is_work_order_tool() {
  zensu_tool_in_list "${1:-}" "$ZENSU_WORK_ORDER_TOOL_NAMES"
}

zensu_is_work_order_session_tool() {
  zensu_tool_in_list "${1:-}" "$ZENSU_WORK_ORDER_SESSION_TOOL_NAMES"
}

export -f zensu_is_read_tool zensu_is_zensu_tool zensu_is_mutation_tool zensu_tool_in_list zensu_is_human_decision_tool zensu_is_work_order_tool zensu_is_work_order_session_tool 2>/dev/null || true
