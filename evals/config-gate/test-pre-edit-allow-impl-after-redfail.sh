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

SID_A="s-impl-a"
# shellcheck disable=SC1090
source "$BASELINE" "$SID_A"
tdd_write_phase "$SID_A" "S3" "RED_WRITE" ""                  >/dev/null
tdd_write_phase "$SID_A" "S3" "RED_FAIL"  "assertion mismatch" >/dev/null
tdd_write_phase "$SID_A" "S3" "IMPL"      ""                  >/dev/null

PAYLOAD_A='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"'$SID_A'"}'
OUT_A=$(echo "$PAYLOAD_A" | "$SCRIPT" 2>/dev/null)
if [ -z "$OUT_A" ]; then
  check "IMPL after RED_FAIL for current step: allowed on production file" PASS
else
  check "IMPL after RED_FAIL for current step: allowed (got: $OUT_A)" FAIL
fi

SID_B="s-impl-b"
# shellcheck disable=SC1090
source "$BASELINE" "$SID_B"
tdd_write_phase "$SID_B" "S3" "RED_WRITE" ""                  >/dev/null
tdd_write_phase "$SID_B" "S3" "RED_FAIL"  "..."                >/dev/null
tdd_write_phase "$SID_B" "S3" "IMPL"      ""                  >/dev/null
tdd_write_phase "$SID_B" "S3" "GREEN_PASS" ""                 >/dev/null
tdd_write_phase "$SID_B" "S4" "IMPL"      ""                  >/dev/null

PAYLOAD_B='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/bar.ts"},"session_id":"'$SID_B'"}'
OUT_B=$(echo "$PAYLOAD_B" | "$SCRIPT" 2>/dev/null)
DECISION_B=$(node -e '
  try { const j = JSON.parse(process.argv[1]); console.log(j.hookSpecificOutput?.permissionDecision || ""); }
  catch (_) { console.log(""); }
' "$OUT_B" 2>/dev/null)
if [ "$DECISION_B" = "deny" ]; then
  check "IMPL phase but RED_FAIL belongs to OTHER step: denied" PASS
else
  check "IMPL phase but RED_FAIL belongs to OTHER step: denied (got decision: '$DECISION_B', out: $OUT_B)" FAIL
fi

SID_C="s-impl-c"
# shellcheck disable=SC1090
source "$BASELINE" "$SID_C"
tdd_write_phase "$SID_C" "S3" "RED_WRITE" "" >/dev/null
tdd_write_phase "$SID_C" "S3" "IMPL"      "" >/dev/null

PAYLOAD_C='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/baz.ts"},"session_id":"'$SID_C'"}'
OUT_C=$(echo "$PAYLOAD_C" | "$SCRIPT" 2>/dev/null)
DECISION_C=$(node -e '
  try { const j = JSON.parse(process.argv[1]); console.log(j.hookSpecificOutput?.permissionDecision || ""); }
  catch (_) { console.log(""); }
' "$OUT_C" 2>/dev/null)
if [ "$DECISION_C" = "deny" ]; then
  check "IMPL phase but never went through RED_FAIL for current step: denied" PASS
else
  check "IMPL phase but never RED_FAIL for current step: denied (got decision: '$DECISION_C', out: $OUT_C)" FAIL
fi

REASON_C=$(node -e '
  try { const j = JSON.parse(process.argv[1]); console.log(j.hookSpecificOutput?.permissionDecisionReason || ""); }
  catch (_) { console.log(""); }
' "$OUT_C" 2>/dev/null)
case "$REASON_C" in
  *RED_FAIL*) check "IMPL-without-RED_FAIL deny reason mentions RED_FAIL prerequisite" PASS ;;
  *)          check "IMPL-without-RED_FAIL deny reason mentions RED_FAIL prerequisite (got: $REASON_C)" FAIL ;;
esac

echo "----"
echo "test-pre-edit-allow-impl-after-redfail: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
