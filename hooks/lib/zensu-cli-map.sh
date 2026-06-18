#!/bin/bash
# zensu-cli-map.sh — maps a typed `zensu <noun> <verb>` CLI invocation to the
# canonical Zensu MCP tool name. The Bash write-gate (pre-bash-zensu-gate.sh)
# feeds the result to the classification SoT in zensu-mcp-tools.sh
# (zensu_is_read_tool / zensu_is_mutation_tool) so the CLI gate reproduces the
# exact semantics the MCP gate had — reads pass, mutations gate to the active
# workflow. One entry per CLI verb across the 17 noun groups; the mutation
# entries stay a subset of ZENSU_MUTATION_TOOL_NAMES (the build-time guard pins
# this). Unknown noun/verb (auth, version, help, completion, typos) → empty,
# which the gate treats as ungated.

zensu_cli_to_tool() {
  case "${1:-} ${2:-}" in
    # products
    "products list")            echo "list_products" ;;
    "products get")             echo "get_product" ;;
    "products create")          echo "create_product" ;;
    "products vision-create")   echo "create_product_vision" ;;
    "products vision-get")      echo "get_vision" ;;
    "products bootstrap-apply") echo "apply_bootstrap" ;;
    "products bootstrap-step")  echo "update_bootstrap_step" ;;
    "products import")          echo "import_repo" ;;
    # features
    "features list")            echo "list_features" ;;
    "features get")             echo "get_feature" ;;
    "features create")          echo "create_feature" ;;
    "features update")          echo "update_feature" ;;
    "features status")          echo "update_feature" ;;
    "features history")         echo "get_feature_history" ;;
    "features deprecate")       echo "deprecate_feature" ;;
    "features split")           echo "split_feature" ;;
    "features merge")           echo "merge_features" ;;
    "features revision")        echo "create_revision" ;;
    # subfeatures
    "subfeatures add")          echo "add_subfeature" ;;
    "subfeatures list")         echo "list_subfeatures" ;;
    "subfeatures promote")      echo "promote_subfeature" ;;
    # roadmap
    "roadmap list")             echo "list_roadmaps" ;;
    "roadmap get")              echo "get_roadmap" ;;
    "roadmap create")           echo "create_roadmap" ;;
    "roadmap update")           echo "update_roadmap" ;;
    "roadmap delete")           echo "delete_roadmap" ;;
    "roadmap add-feature")      echo "add_feature_to_roadmap" ;;
    "roadmap remove-feature")   echo "remove_feature_from_roadmap" ;;
    "roadmap milestone-create") echo "create_milestone" ;;
    "roadmap milestone-list")   echo "list_milestones" ;;
    "roadmap milestone-delete") echo "delete_milestone" ;;
    # tiers
    "tiers create")             echo "create_tier" ;;
    "tiers list")               echo "list_tiers" ;;
    "tiers matrix")             echo "get_tier_matrix" ;;
    "tiers set-feature")        echo "set_feature_tiers" ;;
    # security
    "security classify")        echo "set_security_classification" ;;
    "security posture")         echo "get_security_posture" ;;
    "security score")           echo "get_security_score" ;;
    "security add-test")        echo "add_security_test" ;;
    "security review")          echo "complete_security_review" ;;
    "security analyze")         echo "analyze_feature_security" ;;
    "security validate")        echo "validate_feature_security" ;;
    "security suggest-tests")   echo "suggest_security_tests" ;;
    "security threat-model")    echo "generate_threat_model" ;;
    # journeys
    "journeys list")            echo "list_journeys" ;;
    "journeys get")             echo "get_journey" ;;
    "journeys create")          echo "create_user_journey" ;;
    "journeys step")            echo "create_journey_step" ;;
    "journeys steps")           echo "list_journey_steps" ;;
    "journeys health")          echo "analyze_journey_health" ;;
    "journeys suggest")         echo "suggest_journeys" ;;
    # link
    "link test")                echo "link_test" ;;
    "link docs")                echo "link_docs" ;;
    # `link source` covers both link_source_files and bulk_link_source_files (the CLI
    # folds bulk into repeated --file); bulk_link_source_files stays in the SoT
    # ZENSU_MUTATION_TOOL_NAMES as a harmless superset entry with no separate verb.
    "link source")              echo "link_source_files" ;;
    # ghost
    "ghost scan")               echo "ghost_scan" ;;
    "ghost candidates")         echo "ghost_get_candidates" ;;
    "ghost approve")            echo "ghost_approve_candidate" ;;
    "ghost reject")             echo "ghost_reject_candidate" ;;
    "ghost batch")              echo "ghost_batch_review" ;;
    "ghost apply")              echo "ghost_apply" ;;
    # wiki
    "wiki create")              echo "create_wiki_page" ;;
    "wiki update")              echo "update_wiki_page" ;;
    "wiki list")                echo "list_wiki_pages" ;;
    # doc
    "doc claude-md")            echo "generate_claude_md" ;;
    "doc claude-md-context")    echo "get_claude_md" ;;
    "doc gen-context")          echo "get_doc_generation_context" ;;
    # knowledge
    "knowledge search")         echo "search_knowledge" ;;
    "knowledge get")            echo "get_knowledge_item" ;;
    "knowledge sources")        echo "list_knowledge_sources" ;;
    # pulse
    "pulse start")              echo "pulse_start_session" ;;
    "pulse end")                echo "pulse_end_session" ;;
    "pulse summary")            echo "pulse_session_summary" ;;
    # meta (CLI stubs — server-side compute, gated by classification only)
    "meta scaffold-agent")      echo "scaffold_agent" ;;
    "meta workflow-guide")      echo "get_workflow_guide" ;;
    "meta suggest-workflow")    echo "suggest_workflow" ;;
    # org
    "org users")                echo "search_org_users" ;;
    *)                          echo "" ;;
  esac
}

export -f zensu_cli_to_tool 2>/dev/null || true
