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

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
WORK_DIR="$(mktemp -d)"
export CLAUDE_PROJECT_DIR="$WORK_DIR/project"
mkdir -p "$CLAUDE_PROJECT_DIR"
unset ZENSU_TDD_GATE
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

source "$LIB"

# 0.4.0+: the gate activates on chain-state (active=true), set by /zensu:tdd
# --tdd-begin. Shim phase setup to also mark each session active (the legacy
# CLAUDE_AGENT_TYPE=zensu:tdd-manager activation was removed).
eval "$(declare -f tdd_write_phase | sed '1s/^tdd_write_phase/_zensu_orig_write_phase/')"
tdd_write_phase() { tdd_set_flag "$1" active true >/dev/null 2>&1; _zensu_orig_write_phase "$@"; }

decide() {
  local payload="$1"
  local out
  out=$(echo "$payload" | "$SCRIPT" 2>/dev/null)
  node -e '
    try { const j = JSON.parse(process.argv[1]); console.log(j.hookSpecificOutput?.permissionDecision || "allow"); }
    catch (_) { console.log("allow"); }
  ' "$out" 2>/dev/null
}

SID_GP="s-gp-tight-1"
# shellcheck disable=SC1090
source "$BASELINE" "$SID_GP"
tdd_write_phase "$SID_GP" "S1" "RED_WRITE" "" >/dev/null
tdd_write_phase "$SID_GP" "S1" "RED_FAIL" "x" >/dev/null
tdd_write_phase "$SID_GP" "S1" "IMPL" "" >/dev/null
tdd_write_phase "$SID_GP" "S1" "GREEN_PASS" "" >/dev/null

DEC1=$(decide '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/another.ts"},"session_id":"'$SID_GP'"}')
if [ "$DEC1" = "deny" ]; then
  check "GREEN_PASS + production file: DENIED (cannot drift to next step without RED)" PASS
else
  check "GREEN_PASS + production file: DENIED (got: $DEC1)" FAIL
fi

DEC2=$(decide '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/another.test.ts"},"session_id":"'$SID_GP'"}')
if [ "$DEC2" = "allow" ]; then
  check "GREEN_PASS + test file: allowed (write next RED test)" PASS
else
  check "GREEN_PASS + test file: allowed (got: $DEC2)" FAIL
fi

SID_RF="s-rf-tight-1"
# shellcheck disable=SC1090
source "$BASELINE" "$SID_RF"
tdd_write_phase "$SID_RF" "S1" "RED_WRITE" "" >/dev/null
tdd_write_phase "$SID_RF" "S1" "RED_FAIL" "x" >/dev/null
tdd_write_phase "$SID_RF" "S1" "IMPL" "" >/dev/null
tdd_write_phase "$SID_RF" "S1" "GREEN_PASS" "" >/dev/null
tdd_write_phase "$SID_RF" "S1" "REFACTOR" "" >/dev/null

DEC3=$(decide '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/anywhere.ts"},"session_id":"'$SID_RF'"}')
if [ "$DEC3" = "allow" ]; then
  check "REFACTOR (explicit transition): production file allowed" PASS
else
  check "REFACTOR (explicit transition): production file allowed (got: $DEC3)" FAIL
fi

DEC4=$(decide '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/anywhere.test.ts"},"session_id":"'$SID_RF'"}')
if [ "$DEC4" = "allow" ]; then
  check "REFACTOR: test file allowed" PASS
else
  check "REFACTOR: test file allowed (got: $DEC4)" FAIL
fi

SID_NEXT="s-next-step-1"
# shellcheck disable=SC1090
source "$BASELINE" "$SID_NEXT"
tdd_write_phase "$SID_NEXT" "S1" "RED_WRITE" "" >/dev/null
tdd_write_phase "$SID_NEXT" "S1" "RED_FAIL" "x" >/dev/null
tdd_write_phase "$SID_NEXT" "S1" "IMPL" "" >/dev/null
tdd_write_phase "$SID_NEXT" "S1" "GREEN_PASS" "" >/dev/null
tdd_write_phase "$SID_NEXT" "S2" "RED_WRITE" "" >/dev/null

DEC5=$(decide '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/s2-test.test.ts"},"session_id":"'$SID_NEXT'"}')
if [ "$DEC5" = "allow" ]; then
  check "After S1 GREEN_PASS, S2 RED_WRITE + test file: allowed" PASS
else
  check "After S1 GREEN_PASS, S2 RED_WRITE + test file: allowed (got: $DEC5)" FAIL
fi

DEC6=$(decide '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/s2-prod.ts"},"session_id":"'$SID_NEXT'"}')
if [ "$DEC6" = "allow" ]; then
  check "After S1 GREEN_PASS, S2 RED_WRITE + production file: allowed (legitimate test setup)" PASS
else
  check "After S1 GREEN_PASS, S2 RED_WRITE + production file: allowed (got: $DEC6)" FAIL
fi

echo "[INFO] Documenting REFACTOR known-gap: agent trust boundary, not enforced by FSM"

SID_RF_UNINIT="s-rf-uninit-trust-gap"
# shellcheck disable=SC1090
source "$BASELINE" "$SID_RF_UNINIT"
tdd_write_phase "$SID_RF_UNINIT" "S1" "REFACTOR" "" >/dev/null

DEC7=$(decide '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/anyfile.ts"},"session_id":"'$SID_RF_UNINIT'"}')
if [ "$DEC7" = "allow" ]; then
  check "REFACTOR from UNINITIALIZED (no prior history): production edit ALLOWED (known agent-trust gap, FSM does not enforce GREEN_PASS predecessor)" PASS
else
  check "REFACTOR from UNINITIALIZED (no prior history): production edit ALLOWED (got: $DEC7 — if deny, FSM was tightened and gap is no longer accurate; update this assert)" FAIL
fi

SID_RF_REDFAIL="s-rf-redfail-trust-gap"
# shellcheck disable=SC1090
source "$BASELINE" "$SID_RF_REDFAIL"
tdd_write_phase "$SID_RF_REDFAIL" "S1" "RED_WRITE" "" >/dev/null
tdd_write_phase "$SID_RF_REDFAIL" "S1" "RED_FAIL" "x" >/dev/null
tdd_write_phase "$SID_RF_REDFAIL" "S1" "REFACTOR" "" >/dev/null

DEC8=$(decide '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/anyfile.ts"},"session_id":"'$SID_RF_REDFAIL'"}')
if [ "$DEC8" = "allow" ]; then
  check "REFACTOR from RED_FAIL (no GREEN_PASS): production edit ALLOWED (known agent-trust gap, FSM does not enforce GREEN_PASS predecessor)" PASS
else
  check "REFACTOR from RED_FAIL (no GREEN_PASS): production edit ALLOWED (got: $DEC8 — if deny, FSM was tightened and gap is no longer accurate; update this assert)" FAIL
fi

echo "----"
echo "test-pre-edit-greenpass-tight: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
