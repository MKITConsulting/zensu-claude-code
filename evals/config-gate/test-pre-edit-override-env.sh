#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/pre-edit-tdd-reminder.sh"
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
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# 0.4.0+: the gate activates on chain-state (active=true), not CLAUDE_AGENT_TYPE.
# Mark the session active (UNINITIALIZED phase) so the ZENSU_TDD_GATE override
# cases below exercise a genuinely-active gate — as /zensu:tdd --tdd-begin would.
source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
# shellcheck disable=SC1090
source "$BASELINE" s-override-1
tdd_set_flag "s-override-1" active true >/dev/null 2>&1

PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"s-override-1"}'

unset ZENSU_TDD_GATE
OUT_BASELINE=$(echo "$PAYLOAD" | "$SCRIPT" 2>/dev/null)
DECISION_BASELINE=$(node -e '
  try { const j = JSON.parse(process.argv[1]); console.log(j.hookSpecificOutput?.permissionDecision || ""); }
  catch (_) { console.log(""); }
' "$OUT_BASELINE" 2>/dev/null)
if [ "$DECISION_BASELINE" = "deny" ]; then
  check "ZENSU_TDD_GATE unset (baseline): UNINITIALIZED + production = denied" PASS
else
  check "ZENSU_TDD_GATE unset (baseline): UNINITIALIZED + production = denied (got: $DECISION_BASELINE)" FAIL
fi

export ZENSU_TDD_GATE=off
OUT_OFF=$(echo "$PAYLOAD" | "$SCRIPT" 2>/dev/null)
EXIT_OFF=$?
if [ -z "$OUT_OFF" ] && [ "$EXIT_OFF" = "0" ]; then
  check "ZENSU_TDD_GATE=off: same payload now passes through (empty stdout)" PASS
else
  check "ZENSU_TDD_GATE=off: passthrough (got: '$OUT_OFF' exit=$EXIT_OFF)" FAIL
fi

export ZENSU_TDD_GATE=true
OUT_TRUE=$(echo "$PAYLOAD" | "$SCRIPT" 2>/dev/null)
DECISION_TRUE=$(node -e '
  try { const j = JSON.parse(process.argv[1]); console.log(j.hookSpecificOutput?.permissionDecision || ""); }
  catch (_) { console.log(""); }
' "$OUT_TRUE" 2>/dev/null)
if [ "$DECISION_TRUE" = "deny" ]; then
  check "ZENSU_TDD_GATE=true: gate active (only literal 'off' bypasses)" PASS
else
  check "ZENSU_TDD_GATE=true: gate active (got decision: $DECISION_TRUE)" FAIL
fi

export ZENSU_TDD_GATE=""
OUT_EMPTY=$(echo "$PAYLOAD" | "$SCRIPT" 2>/dev/null)
DECISION_EMPTY=$(node -e '
  try { const j = JSON.parse(process.argv[1]); console.log(j.hookSpecificOutput?.permissionDecision || ""); }
  catch (_) { console.log(""); }
' "$OUT_EMPTY" 2>/dev/null)
if [ "$DECISION_EMPTY" = "deny" ]; then
  check "ZENSU_TDD_GATE='' (empty): gate still active" PASS
else
  check "ZENSU_TDD_GATE='' (empty): gate still active (got: $DECISION_EMPTY)" FAIL
fi

echo "----"
echo "test-pre-edit-override-env: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
