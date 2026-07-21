#!/bin/bash
# Pins hooks/lib/zensu-agent-context.sh: the trusted-payload principal and event
# discriminator shared by every hook that carries main-thread authority.
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

MAIN_PAYLOAD='{"hook_event_name":"PreToolUse","session_id":"main-session"}'
[ "$(zensu_hook_principal "$MAIN_PAYLOAD" PreToolUse)" = "main-v1" ] \
  && zensu_hook_is_main_principal "$MAIN_PAYLOAD" PreToolUse \
  && check "A1 trusted payload with both agent fields absent is main-v1" PASS \
  || check "A1 trusted main principal" FAIL

for NON_MAIN_PAYLOAD in \
  '{"agent_type":"zensu:code-reviewer"}' \
  '{"agent_type":"zensu:zensu-plm"}' \
  '{"agent_type":"custom-agent"}' \
  '{"agent_id":"child-only"}' \
  '{"agent_type":""}' \
  '{"agent_id":null}' \
  '{"agent_type":"custom-agent","agent_id":""}'; do
  NON_MAIN_EVENT_PAYLOAD="$(PAYLOAD="$NON_MAIN_PAYLOAD" node -e 'const p=JSON.parse(process.env.PAYLOAD);p.hook_event_name="PreToolUse";process.stdout.write(JSON.stringify(p))')"
  if zensu_hook_is_main_principal "$NON_MAIN_EVENT_PAYLOAD" PreToolUse; then
    check "A2 explicit/partial principal never classifies as main-v1 ($NON_MAIN_PAYLOAD)" FAIL
  else
    check "A2 explicit/partial principal never classifies as main-v1 ($NON_MAIN_PAYLOAD)" PASS
  fi
done

if ZENSU_FORCE_MAIN=1 zensu_hook_is_main_principal '{"hook_event_name":"PreToolUse","agent_type":"custom-agent"}' PreToolUse; then
  check "A3 ambient ZENSU_FORCE_MAIN cannot promote a trusted-payload principal" FAIL
else
  check "A3 ambient ZENSU_FORCE_MAIN cannot promote a trusted-payload principal" PASS
fi

if zensu_hook_is_main_principal 'not-json' PreToolUse; then
  check "A4 malformed payload is never main-v1" FAIL
else
  check "A4 malformed payload is never main-v1" PASS
fi

if zensu_hook_is_main_principal '{"hook_event_name":"PostToolUse"}' PreToolUse \
  || zensu_hook_is_main_principal '{}' PreToolUse; then
  check "A5 wrong or missing hook event is never main-v1" FAIL
else
  check "A5 wrong or missing hook event is never main-v1" PASS
fi

if grep -R -E -q 'zensu_is_spawned_agent|zensu_hook_agent_(id|type)|ZENSU_FORCE_MAIN' "$PLUGIN_DIR/hooks"; then
  check "A6 legacy ambient-force principal helpers are absent from production hooks" FAIL
else
  check "A6 legacy ambient-force principal helpers are absent from production hooks" PASS
fi

echo "----"
echo "test-agent-context: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
