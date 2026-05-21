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

if [ ! -x "$SCRIPT" ]; then
  check "hook script exists and is executable" FAIL
  echo "----"; echo "test-pre-edit-isolation: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "hook script exists and is executable" PASS

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
TDD_STATE_DIR="$(mktemp -d)"
export TDD_STATE_DIR
cleanup() { rm -rf "$TDD_STATE_DIR"; }
trap cleanup EXIT

unset CLAUDE_AGENT_TYPE
unset ZENSU_TDD_GATE

PAYLOAD_REVIEWER='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"s-iso-1"}'
OUT_REV=$(echo "$PAYLOAD_REVIEWER" | CLAUDE_AGENT_TYPE="zensu:code-reviewer" "$SCRIPT" 2>/dev/null)
EXIT_REV=$?
if [ -z "$OUT_REV" ] && [ "$EXIT_REV" = "0" ]; then
  check "non-tdd-manager subagent (code-reviewer via env): empty stdout + exit 0" PASS
else
  check "non-tdd-manager subagent (code-reviewer via env): empty stdout + exit 0 (got: '$OUT_REV' exit=$EXIT_REV)" FAIL
fi

PAYLOAD_PLM='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"s-iso-2"}'
OUT_PLM=$(echo "$PAYLOAD_PLM" | CLAUDE_AGENT_TYPE="zensu:zensu-plm" "$SCRIPT" 2>/dev/null)
EXIT_PLM=$?
if [ -z "$OUT_PLM" ] && [ "$EXIT_PLM" = "0" ]; then
  check "non-tdd-manager subagent (zensu-plm via env): empty stdout + exit 0" PASS
else
  check "non-tdd-manager subagent (zensu-plm via env): empty stdout + exit 0 (got: '$OUT_PLM' exit=$EXIT_PLM)" FAIL
fi

PAYLOAD_BASH='{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"s-iso-3"}'
OUT_BASH=$(echo "$PAYLOAD_BASH" | CLAUDE_AGENT_TYPE="zensu:tdd-manager" "$SCRIPT" 2>/dev/null)
EXIT_BASH=$?
if [ -z "$OUT_BASH" ] && [ "$EXIT_BASH" = "0" ]; then
  check "Bash + benign read-only command (ls): empty stdout + exit 0" PASS
else
  check "Bash + benign read-only command (ls): empty stdout + exit 0 (got: '$OUT_BASH' exit=$EXIT_BASH)" FAIL
fi

PAYLOAD_READ='{"tool_name":"Read","tool_input":{"file_path":"src/foo.ts"},"session_id":"s-iso-4"}'
OUT_READ=$(echo "$PAYLOAD_READ" | CLAUDE_AGENT_TYPE="zensu:tdd-manager" "$SCRIPT" 2>/dev/null)
EXIT_READ=$?
if [ -z "$OUT_READ" ] && [ "$EXIT_READ" = "0" ]; then
  check "non-Edit tool (Read): empty stdout + exit 0" PASS
else
  check "non-Edit tool (Read): empty stdout + exit 0 (got: '$OUT_READ' exit=$EXIT_READ)" FAIL
fi

echo "----"
echo "test-pre-edit-isolation: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
