#!/bin/bash

ZENSU_READ_TOOL_PREFIXES="list_ get_ search_ suggest_"
ZENSU_READ_TOOL_NAMES="analyze_journey_health validate_feature_security ghost_get_candidates pulse_start_session pulse_end_session pulse_session_summary"
ZENSU_MUTATION_TOOL_NAMES="add_feature_to_roadmap add_security_test add_subfeature analyze_feature_security apply_bootstrap bootstrap_from_vision bulk_link_source_files complete_security_review create_feature create_journey_step create_milestone create_product create_product_vision create_revision create_roadmap create_tier create_user_journey create_wiki_page delete_milestone delete_roadmap deprecate_feature generate_claude_md generate_threat_model ghost_apply ghost_approve_candidate ghost_batch_review ghost_reject_candidate ghost_scan import_repo link_docs link_source_files link_test merge_features promote_subfeature remove_feature_from_roadmap scaffold_agent set_feature_tiers set_security_classification split_feature update_bootstrap_step update_feature update_roadmap update_wiki_page"

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

export -f zensu_is_read_tool zensu_is_zensu_tool zensu_is_mutation_tool 2>/dev/null || true
