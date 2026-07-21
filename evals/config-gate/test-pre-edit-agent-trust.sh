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

# Post-0.4.0 trust model: the gate activates ONLY on chain-state (active=true,
# set by /zensu:tdd --tdd-begin). CLAUDE_AGENT_TYPE is IGNORED — it neither
# activates nor bypasses the gate, and a forged payload subagent_type is
# likewise irrelevant. This replaces the legacy env-trust model where
# CLAUDE_AGENT_TYPE=zensu:tdd-manager turned the gate on.

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
WORK_DIR="$(mktemp -d)"
export CLAUDE_PROJECT_DIR="$WORK_DIR/project"
mkdir -p "$CLAUDE_PROJECT_DIR"
unset ZENSU_TDD_GATE
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

source "$LIB"

decision() {
  node -e '
    try { const j = JSON.parse(process.argv[1]); console.log(j.hookSpecificOutput?.permissionDecision || "allow"); }
    catch (_) { console.log("allow"); }
  ' "$1" 2>/dev/null
}

# ── No active chain-state: gate is OFF regardless of env / payload tags ──

unset CLAUDE_AGENT_TYPE
# shellcheck disable=SC1090
source "$BASELINE" s-forge-1
OUT=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/foo.ts","subagent_type":"zensu:code-reviewer"},"session_id":"s-forge-1"}' | "$SCRIPT" 2>/dev/null)
[ -z "$OUT" ] && check "no chain-state + forged payload subagent_type: gate OFF (allow)" PASS \
              || check "no chain-state + forged payload subagent_type: gate OFF (got: $OUT)" FAIL

# shellcheck disable=SC1090
source "$BASELINE" s-forge-2
OUT=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"s-forge-2"}' | "$SCRIPT" 2>/dev/null)
[ -z "$OUT" ] && check "no chain-state + no tag: gate OFF (main-thread/untracked bypass)" PASS \
              || check "no chain-state + no tag: gate OFF (got: $OUT)" FAIL

export CLAUDE_AGENT_TYPE="zensu:code-reviewer"
# shellcheck disable=SC1090
source "$BASELINE" s-env-rev
OUT=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"s-env-rev"}' | "$SCRIPT" 2>/dev/null)
[ -z "$OUT" ] && check "no chain-state + CLAUDE_AGENT_TYPE=code-reviewer: gate OFF (env ignored)" PASS \
              || check "no chain-state + CLAUDE_AGENT_TYPE=code-reviewer: gate OFF (got: $OUT)" FAIL
unset CLAUDE_AGENT_TYPE

export CLAUDE_AGENT_TYPE="zensu:tdd-manager"
# shellcheck disable=SC1090
source "$BASELINE" s-env-tdd
OUT=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"s-env-tdd"}' | "$SCRIPT" 2>/dev/null)
[ -z "$OUT" ] && check "no chain-state + CLAUDE_AGENT_TYPE=tdd-manager: gate OFF (legacy env no longer activates)" PASS \
              || check "no chain-state + CLAUDE_AGENT_TYPE=tdd-manager: gate OFF (got: $OUT)" FAIL
unset CLAUDE_AGENT_TYPE

# ── Active chain-state: gate is ON regardless of env ──

SID_ACTIVE="s-active-uninit"
# shellcheck disable=SC1090
source "$BASELINE" "$SID_ACTIVE"
tdd_set_flag "$SID_ACTIVE" active true >/dev/null 2>&1
OUT=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"'"$SID_ACTIVE"'"}' | "$SCRIPT" 2>/dev/null)
[ "$(decision "$OUT")" = "deny" ] && check "active chain-state (UNINITIALIZED) + no env: gate ON (deny)" PASS \
                                  || check "active chain-state + no env: gate ON (got: $(decision "$OUT"))" FAIL

export CLAUDE_AGENT_TYPE="zensu:code-reviewer"
SID_ACTIVE2="s-active-envrev"
# shellcheck disable=SC1090
source "$BASELINE" "$SID_ACTIVE2"
tdd_set_flag "$SID_ACTIVE2" active true >/dev/null 2>&1
OUT=$(echo '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"'"$SID_ACTIVE2"'"}' | "$SCRIPT" 2>/dev/null)
[ "$(decision "$OUT")" = "deny" ] && check "active chain-state + CLAUDE_AGENT_TYPE=code-reviewer: gate ON (env does NOT bypass)" PASS \
                                  || check "active chain-state + env code-reviewer: gate ON (got: $(decision "$OUT"))" FAIL
unset CLAUDE_AGENT_TYPE

echo "----"
echo "test-pre-edit-agent-trust: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
