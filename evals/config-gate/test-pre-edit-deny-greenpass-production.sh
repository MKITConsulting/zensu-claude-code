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

SID_GP="s-greenpass-1"
# shellcheck disable=SC1090
source "$BASELINE" "$SID_GP"
tdd_write_phase "$SID_GP" "S1" "GREEN_PASS" "" >/dev/null

PAYLOAD_GP_PROD='{"tool_name":"Edit","tool_input":{"file_path":"src/strings.ts"},"session_id":"'$SID_GP'"}'
OUT_GP_PROD=$(echo "$PAYLOAD_GP_PROD" | "$SCRIPT" 2>/dev/null)
DEC_GP_PROD=$(node -e '
  try { const j = JSON.parse(process.argv[1]); console.log(j.hookSpecificOutput?.permissionDecision || ""); }
  catch (_) { console.log(""); }
' "$OUT_GP_PROD" 2>/dev/null)
if [ "$DEC_GP_PROD" = "deny" ]; then
  check "GREEN_PASS + production file (src/strings.ts): DENIED" PASS
else
  check "GREEN_PASS + production file (src/strings.ts): DENIED (got: '$DEC_GP_PROD')" FAIL
fi

PAYLOAD_GP_TEST='{"tool_name":"Edit","tool_input":{"file_path":"src/strings.test.ts"},"session_id":"'$SID_GP'"}'
OUT_GP_TEST=$(echo "$PAYLOAD_GP_TEST" | "$SCRIPT" 2>/dev/null)
if [ -z "$OUT_GP_TEST" ]; then
  check "GREEN_PASS + test file (src/strings.test.ts): allowed (counter-case to deny rule)" PASS
else
  check "GREEN_PASS + test file (src/strings.test.ts): allowed (got: $OUT_GP_TEST)" FAIL
fi

PAYLOAD_GP_GO='{"tool_name":"Edit","tool_input":{"file_path":"src/utils/refactor.go"},"session_id":"'$SID_GP'"}'
OUT_GP_GO=$(echo "$PAYLOAD_GP_GO" | "$SCRIPT" 2>/dev/null)
DEC_GP_GO=$(node -e '
  try { const j = JSON.parse(process.argv[1]); console.log(j.hookSpecificOutput?.permissionDecision || ""); }
  catch (_) { console.log(""); }
' "$OUT_GP_GO" 2>/dev/null)
if [ "$DEC_GP_GO" = "deny" ]; then
  check "GREEN_PASS + production .go file: DENIED" PASS
else
  check "GREEN_PASS + production .go file: DENIED (got: '$DEC_GP_GO')" FAIL
fi

SID_RUN="s-redrun-1"
# shellcheck disable=SC1090
source "$BASELINE" "$SID_RUN"
tdd_write_phase "$SID_RUN" "S1" "RED_RUN" "" >/dev/null
PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"'$SID_RUN'"}'
OUT_RUN=$(echo "$PAYLOAD" | "$SCRIPT" 2>/dev/null)
DECISION_RUN=$(node -e '
  try { const j = JSON.parse(process.argv[1]); console.log(j.hookSpecificOutput?.permissionDecision || ""); }
  catch (_) { console.log(""); }
' "$OUT_RUN" 2>/dev/null)
if [ "$DECISION_RUN" = "deny" ]; then
  check "RED_RUN: denied (no edits during test execution)" PASS
else
  check "RED_RUN: denied (got decision: '$DECISION_RUN')" FAIL
fi

SID_GR="s-greenrun-1"
# shellcheck disable=SC1090
source "$BASELINE" "$SID_GR"
tdd_write_phase "$SID_GR" "S1" "GREEN_RUN" "" >/dev/null
PAYLOAD2='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"'$SID_GR'"}'
OUT_GR=$(echo "$PAYLOAD2" | "$SCRIPT" 2>/dev/null)
DECISION_GR=$(node -e '
  try { const j = JSON.parse(process.argv[1]); console.log(j.hookSpecificOutput?.permissionDecision || ""); }
  catch (_) { console.log(""); }
' "$OUT_GR" 2>/dev/null)
if [ "$DECISION_GR" = "deny" ]; then
  check "GREEN_RUN: denied (no edits during test execution)" PASS
else
  check "GREEN_RUN: denied (got decision: '$DECISION_GR')" FAIL
fi

echo "----"
echo "test-pre-edit-deny-greenpass-production: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
