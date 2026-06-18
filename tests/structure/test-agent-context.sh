#!/bin/bash
# Pins hooks/lib/zensu-agent-context.sh: the spawned-agent discriminator used by
# stop-chain-enforcer.sh to no-op inside Task/Agent reviewers and Claude Code
# Workflow workers. agent_id (present only in spawned subagents) is primary;
# a small zensu-subagent agent_type allowlist is the corroborating fallback;
# ZENSU_FORCE_MAIN=1 forces main-thread treatment.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN_DIR/hooks/lib/zensu-agent-context.sh"

PASS=0; FAIL=0
check() {
  if [ "$2" = "PASS" ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HELPER" ]; then
  check "A0 hooks/lib/zensu-agent-context.sh exists" FAIL
  echo "----"; echo "test-agent-context: $PASS PASS / $FAIL FAIL"; exit 1
fi
check "A0 hooks/lib/zensu-agent-context.sh exists" PASS
source "$HELPER"

[ "$(zensu_hook_agent_id '{"agent_id":"sub-xyz"}')" = "sub-xyz" ] \
  && check "A1 agent_id extracted from hook input" PASS || check "A1 agent_id extract" FAIL
[ -z "$(zensu_hook_agent_id '{"session_id":"s"}')" ] \
  && check "A2 missing agent_id -> empty" PASS || check "A2 missing agent_id" FAIL
[ -z "$(zensu_hook_agent_id 'not json at all')" ] \
  && check "A3 malformed json -> empty (no crash)" PASS || check "A3 malformed json" FAIL
[ "$(zensu_hook_agent_type '{"agent_type":"zensu:code-reviewer"}')" = "zensu:code-reviewer" ] \
  && check "A4 agent_type extracted" PASS || check "A4 agent_type extract" FAIL

[ "$(zensu_is_spawned_agent "" "")" = "false" ] \
  && check "A5 no agent_id + no agent_type -> false (main thread)" PASS || check "A5 main" FAIL
[ "$(zensu_is_spawned_agent "sub-abc" "")" = "true" ] \
  && check "A6 agent_id present -> true (spawned)" PASS || check "A6 agent_id spawned" FAIL
[ "$(zensu_is_spawned_agent "" "zensu:code-reviewer")" = "true" ] \
  && check "A7 known zensu subagent type -> true" PASS || check "A7 reviewer type" FAIL
[ "$(zensu_is_spawned_agent "" "zensu:review-aspect")" = "true" ] \
  && check "A8 review-aspect type -> true" PASS || check "A8 review-aspect" FAIL
[ "$(zensu_is_spawned_agent "" "some-custom-agent")" = "false" ] \
  && check "A9 unknown agent_type alone -> false (could be --agent main thread)" PASS || check "A9 unknown type" FAIL

[ "$(ZENSU_FORCE_MAIN=1 zensu_is_spawned_agent "sub-abc" "zensu:code-reviewer")" = "false" ] \
  && check "A10 ZENSU_FORCE_MAIN=1 forces main-thread treatment" PASS || check "A10 force-main" FAIL

echo "----"
echo "test-agent-context: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
