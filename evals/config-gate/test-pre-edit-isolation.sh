#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/pre-edit-tdd-reminder.sh"
LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"

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
WORK_DIR="$(mktemp -d)"
export CLAUDE_PROJECT_DIR="$WORK_DIR/project"
export STATE_DIR="$WORK_DIR/retired-state"
mkdir -p "$CLAUDE_PROJECT_DIR" "$STATE_DIR"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

unset ZENSU_TDD_GATE

SID="s-iso-active"
# shellcheck disable=SC1090
source "$BASELINE" "$SID"
# shellcheck disable=SC1090
source "$LIB"
tdd_set_flag "$SID" active true >/dev/null 2>&1

# Spawned-agent identity is carried only by Claude's trusted top-level payload
# fields. The active main-thread state makes these checks meaningful: if either
# identity were accidentally promoted to main, the production edit would deny.
PAYLOAD_REVIEWER='{"hook_event_name":"PreToolUse","agent_type":"zensu:code-reviewer","agent_id":"agent-reviewer-1","tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"'$SID'"}'
OUT_REV=$(echo "$PAYLOAD_REVIEWER" | "$SCRIPT" 2>/dev/null)
EXIT_REV=$?
if [ -z "$OUT_REV" ] && [ "$EXIT_REV" = "0" ]; then
  check "active session + spawned code-reviewer identity: isolated with empty stdout + exit 0" PASS
else
  check "active session + spawned code-reviewer identity: isolated (got: '$OUT_REV' exit=$EXIT_REV)" FAIL
fi

PAYLOAD_PLM='{"hook_event_name":"PreToolUse","agent_type":"zensu:zensu-plm","agent_id":"agent-plm-1","tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"'$SID'"}'
OUT_PLM=$(echo "$PAYLOAD_PLM" | "$SCRIPT" 2>/dev/null)
EXIT_PLM=$?
if [ -z "$OUT_PLM" ] && [ "$EXIT_PLM" = "0" ]; then
  check "active session + spawned zensu-plm identity: isolated with empty stdout + exit 0" PASS
else
  check "active session + spawned zensu-plm identity: isolated (got: '$OUT_PLM' exit=$EXIT_PLM)" FAIL
fi

# Counter-proof: the exact same active session without spawned-agent metadata
# reaches the TDD phase gate and is denied in UNINITIALIZED.
PAYLOAD_MAIN='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"'$SID'"}'
OUT_MAIN=$(echo "$PAYLOAD_MAIN" | "$SCRIPT" 2>/dev/null)
DECISION_MAIN=$(node -e '
  try { const j=JSON.parse(process.argv[1]); process.stdout.write(j.hookSpecificOutput?.permissionDecision || ""); }
  catch (_) { process.stdout.write(""); }
' "$OUT_MAIN" 2>/dev/null)
if [ "$DECISION_MAIN" = "deny" ]; then
  check "active session + main principal counter-proof: production Edit is denied" PASS
else
  check "active session + main principal counter-proof: expected deny (got: '$OUT_MAIN')" FAIL
fi

# Tool filtering is independent of principal isolation: authenticated main
# payloads for non-edit tools remain silent even while the session is active.
PAYLOAD_BASH='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"'$SID'"}'
OUT_BASH=$(echo "$PAYLOAD_BASH" | "$SCRIPT" 2>/dev/null)
EXIT_BASH=$?
if [ -z "$OUT_BASH" ] && [ "$EXIT_BASH" = "0" ]; then
  check "active main session + Bash tool filter: empty stdout + exit 0" PASS
else
  check "active main session + Bash tool filter: expected empty stdout (got: '$OUT_BASH' exit=$EXIT_BASH)" FAIL
fi

PAYLOAD_READ='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"src/foo.ts"},"session_id":"'$SID'"}'
OUT_READ=$(echo "$PAYLOAD_READ" | "$SCRIPT" 2>/dev/null)
EXIT_READ=$?
if [ -z "$OUT_READ" ] && [ "$EXIT_READ" = "0" ]; then
  check "active main session + Read tool filter: empty stdout + exit 0" PASS
else
  check "active main session + Read tool filter: expected empty stdout (got: '$OUT_READ' exit=$EXIT_READ)" FAIL
fi

echo "----"
echo "test-pre-edit-isolation: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
