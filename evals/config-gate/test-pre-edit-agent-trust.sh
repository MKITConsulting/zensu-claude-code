#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/pre-edit-tdd-reminder.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
TDD_STATE_DIR="$(mktemp -d)"
export TDD_STATE_DIR
unset ZENSU_TDD_GATE
cleanup() { rm -rf "$TDD_STATE_DIR"; }
trap cleanup EXIT

unset CLAUDE_AGENT_TYPE

PAYLOAD_FORGE='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.ts","subagent_type":"zensu:code-reviewer"},"session_id":"s-forge-1"}'
OUT_FORGE=$(echo "$PAYLOAD_FORGE" | "$SCRIPT" 2>/dev/null)
EXIT_FORGE=$?
if [ -z "$OUT_FORGE" ] && [ "$EXIT_FORGE" = "0" ]; then
  check "forged subagent_type in payload, no CLAUDE_AGENT_TYPE env: gate OFF (allow, env-only trust)" PASS
else
  check "forged subagent_type in payload, no CLAUDE_AGENT_TYPE env: gate OFF (got out='$OUT_FORGE' exit=$EXIT_FORGE)" FAIL
fi

unset CLAUDE_AGENT_TYPE
PAYLOAD_NOTAG='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"s-forge-2"}'
OUT_NOTAG=$(echo "$PAYLOAD_NOTAG" | "$SCRIPT" 2>/dev/null)
EXIT_NOTAG=$?
if [ -z "$OUT_NOTAG" ] && [ "$EXIT_NOTAG" = "0" ]; then
  check "no CLAUDE_AGENT_TYPE env, no payload tag: gate OFF (main-thread bypass, default for unidentified actor)" PASS
else
  check "no CLAUDE_AGENT_TYPE env, no payload tag: gate OFF (got out='$OUT_NOTAG' exit=$EXIT_NOTAG)" FAIL
fi

export CLAUDE_AGENT_TYPE=""
PAYLOAD_EMPTY='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"s-empty"}'
OUT_EMPTY=$(echo "$PAYLOAD_EMPTY" | "$SCRIPT" 2>/dev/null)
EXIT_EMPTY=$?
if [ -z "$OUT_EMPTY" ] && [ "$EXIT_EMPTY" = "0" ]; then
  check "CLAUDE_AGENT_TYPE='' (explicit empty): gate OFF" PASS
else
  check "CLAUDE_AGENT_TYPE='' (explicit empty): gate OFF (got out='$OUT_EMPTY' exit=$EXIT_EMPTY)" FAIL
fi
unset CLAUDE_AGENT_TYPE

export CLAUDE_AGENT_TYPE="zensu:code-reviewer"
PAYLOAD_ENVREV='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"s-env-rev"}'
OUT_ENVREV=$(echo "$PAYLOAD_ENVREV" | "$SCRIPT" 2>/dev/null)
EXIT_ENVREV=$?
if [ -z "$OUT_ENVREV" ] && [ "$EXIT_ENVREV" = "0" ]; then
  check "env CLAUDE_AGENT_TYPE=zensu:code-reviewer: bypass (correct, env is trusted)" PASS
else
  check "env CLAUDE_AGENT_TYPE=zensu:code-reviewer: bypass (got: '$OUT_ENVREV' exit=$EXIT_ENVREV)" FAIL
fi
unset CLAUDE_AGENT_TYPE

export CLAUDE_AGENT_TYPE="zensu:tdd-manager"
PAYLOAD_ENVTDD='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.ts","subagent_type":"zensu:code-reviewer"},"session_id":"s-env-tdd"}'
OUT_ENVTDD=$(echo "$PAYLOAD_ENVTDD" | "$SCRIPT" 2>/dev/null)
DECISION_ENVTDD=$(node -e '
  try { const j = JSON.parse(process.argv[1]); console.log(j.hookSpecificOutput?.permissionDecision || ""); }
  catch (_) { console.log(""); }
' "$OUT_ENVTDD" 2>/dev/null)
if [ "$DECISION_ENVTDD" = "deny" ]; then
  check "env tdd-manager + forged payload subagent_type=code-reviewer: env wins, gate denies" PASS
else
  check "env tdd-manager + forged payload subagent_type=code-reviewer: env wins (got: '$DECISION_ENVTDD')" FAIL
fi
unset CLAUDE_AGENT_TYPE

echo "----"
echo "test-pre-edit-agent-trust: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
