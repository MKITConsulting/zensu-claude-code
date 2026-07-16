#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
POST_REVIEW="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"

PASS=0; FAIL=0
check() {
  if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PROJECT_DIR="$TMP_DIR/project"
export ZENSU_CONFIG="$TMP_DIR/config.json"
mkdir -p "$CLAUDE_PROJECT_DIR"
export ZENSU_TEST_PLUGIN_DATA="$TMP_DIR/host-plugin-data"
printf '%s\n' '{"hooks":{"autoFix":true,"autoFixMaxRounds":10}}' > "$ZENSU_CONFIG"

run_review() {
  local sid="$1"
  # shellcheck disable=SC1090
  source "$BASELINE" "$sid" || return 1
  bash "$LOG" --tdd-begin --session "$sid" >/dev/null 2>&1 || return 1
  printf '{"tool_name":"Agent","tool_input":{"subagent_type":"zensu:code-reviewer"},"session_id":"%s"}' "$sid" \
    | "$POST_REVIEW" >/dev/null 2>&1
}

# Mutable state is project-local and shares one document with the FSM.
unset STATE_DIR CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_DATA_OVERRIDE
SID_A="review-location-default"
KEY_A="$(node "$CORE" session-key "$SID_A")"
run_review "$SID_A"
DEFAULT_FILE="$CLAUDE_PROJECT_DIR/.zensu/state/tdd-phase-${KEY_A}.json"
[ -f "$DEFAULT_FILE" ] && check "default review counter lives in the project CAS workflow document" PASS \
  || check "default review counter lives in the project CAS workflow document" FAIL
CONTROL_CORE="$CORE" PROJECT_ROOT="$CLAUDE_PROJECT_DIR" SID="$SID_A" node -e '
  const core=require(process.env.CONTROL_CORE);
  const s=core.readWorkflowState({projectRoot:process.env.PROJECT_ROOT,sessionId:process.env.SID});
  process.exit(s.reviewRound===1 ? 0 : 1);
' && check "project document contains reviewRound=1" PASS \
  || check "project document contains reviewRound=1" FAIL

# Retired counter-location variables are inert; they cannot split the budget
# away from the validated workflow document.
export CLAUDE_PLUGIN_DATA_OVERRIDE="$TMP_DIR/retired-override"
mkdir -p "$CLAUDE_PLUGIN_DATA_OVERRIDE"
SID_B="review-location-retired-env"
KEY_B="$(node "$CORE" session-key "$SID_B")"
run_review "$SID_B"
PROJECT_FILE_B="$CLAUDE_PROJECT_DIR/.zensu/state/tdd-phase-${KEY_B}.json"
[ -f "$PROJECT_FILE_B" ] && check "retired location env cannot redirect integrated counters" PASS \
  || check "retired location env cannot redirect integrated counters" FAIL
if find "$CLAUDE_PLUGIN_DATA_OVERRIDE" -type f | grep -q .; then
  check "retired location override receives no counter artifacts" FAIL
else
  check "retired location override receives no counter artifacts" PASS
fi

# A similarly named ambient variable is inert; callers cannot redirect the
# project-bound CAS workflow document.
export STATE_DIR="$TMP_DIR/explicit-state"
mkdir -p "$STATE_DIR"
SID_C="review-location-explicit-state"
KEY_C="$(node "$CORE" session-key "$SID_C")"
run_review "$SID_C"
EXPLICIT_FILE="$STATE_DIR/tdd-phase-${KEY_C}.json"
[ ! -e "$EXPLICIT_FILE" ] && check "ambient STATE_DIR cannot redirect the CAS workflow document" PASS \
  || check "ambient STATE_DIR cannot redirect the CAS workflow document" FAIL
CONTROL_CORE="$CORE" PROJECT_ROOT="$CLAUDE_PROJECT_DIR" SID="$SID_C" node -e '
  const core=require(process.env.CONTROL_CORE);
  const s=core.readWorkflowState({projectRoot:process.env.PROJECT_ROOT,sessionId:process.env.SID});
  process.exit(s.reviewRound===1 && s.active===true ? 0 : 1);
' && check "project document retains FSM and review counter together" PASS \
  || check "project document retains FSM and review counter together" FAIL

echo "----"
echo "test-review-counters-state-location: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
