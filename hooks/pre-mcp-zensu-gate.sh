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
[ -z "$TOOL" ] && exit 0
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-mcp-tools.sh"
zensu_is_read_tool "$TOOL" && exit 0

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
[ "$(zensu_workflow_allows "$(tdd_state_file "$SID_PRIMARY")" "$TOOL")" = "true" ] && exit 0
[ -n "$SID_FALLBACK" ] && [ "$SID_FALLBACK" != "$SID_PRIMARY" ] \
  && [ "$(zensu_workflow_allows "$(tdd_state_file "$SID_FALLBACK")" "$TOOL")" = "true" ] && exit 0

REASON="Zensu state-mutating operation '${TOOL}' was blocked. A direct main-thread mutation bypasses the Zensu workflow conventions (dedup, user journeys, baseline revisions, security classification, release-readiness gates) that the skills and the zensu-plm agent enforce. Run the matching skill — /zensu:bootstrap or /zensu:ghost-scan (onboarding), /zensu:implement (feature work), /zensu:security-review (classification/review) — or delegate the whole task to the zensu-plm agent, instead of calling this MCP tool directly. For a deliberate one-off, set ZENSU_MCP_GATE=off."

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
