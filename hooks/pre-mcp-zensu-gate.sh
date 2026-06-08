#!/bin/bash
set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"

command -v node >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null || true)"

field() {
  PAYLOAD="$INPUT" F="$1" node -e '
    try {
      const j = JSON.parse(process.env.PAYLOAD || "{}");
      const v = j[process.env.F];
      process.stdout.write(typeof v === "string" ? v : "");
    } catch (_) { process.stdout.write(""); }
  ' 2>/dev/null
}

TOOL_NAME="$(field tool_name)"
TOOL="${TOOL_NAME#mcp__plugin_zensu_zensu__}"
case "$TOOL" in
  create_product|create_product_vision|apply_bootstrap|ghost_apply|create_feature) ;;
  *) exit 0 ;;
esac

[ "${ZENSU_MCP_GATE:-}" = "off" ] && exit 0

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled mcpGate || exit 0

AGENT_TYPE="$(field agent_type)"
case "$AGENT_TYPE" in
  *zensu-plm*) exit 0 ;;
esac

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
SID_PRIMARY="$(zensu_resolve_session_id "$(field session_id)")"
SID_FALLBACK="$(zensu_resolve_session_id "${CLAUDE_SESSION_ID:-}")"
[ "$(zensu_workflow_active "$(tdd_state_file "$SID_PRIMARY")")" = "true" ] && exit 0
[ -n "$SID_FALLBACK" ] && [ "$SID_FALLBACK" != "$SID_PRIMARY" ] \
  && [ "$(zensu_workflow_active "$(tdd_state_file "$SID_FALLBACK")")" = "true" ] && exit 0

REASON="Zensu structural write '${TOOL}' was blocked. A direct main-thread create/onboard bypasses the Zensu workflow conventions (dedup, user journeys, v1 baseline revisions, security classification) that the skills and the zensu-plm agent enforce. Run the /zensu:bootstrap (greenfield) or /zensu:ghost-scan (brownfield) skill, or delegate the task to the zensu-plm agent, instead of calling this MCP tool directly. For a deliberate one-off, set ZENSU_MCP_GATE=off."

REASON="$REASON" node -e '
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: process.env.REASON
    }
  }));
'
echo
exit 0
