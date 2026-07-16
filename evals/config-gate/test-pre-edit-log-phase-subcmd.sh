#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_SCRIPT="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
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
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

OUT_TIMESTAMP=$(bash "$LOG_SCRIPT" timestamp "$(date +%s)")
case "$OUT_TIMESTAMP" in
  "["*"] "|""|"[+"*"] ") check "backward compat: 'timestamp' subcommand still emits prefix" PASS ;;
  *)                     check "backward compat: 'timestamp' subcommand prefix (got: '$OUT_TIMESTAMP')" FAIL ;;
esac

OUT_STYLE=$(bash "$LOG_SCRIPT" style)
case "$OUT_STYLE" in
  wall|relative|none) check "backward compat: 'style' subcommand returns valid style" PASS ;;
  *)                  check "backward compat: 'style' subcommand returns valid style (got: '$OUT_STYLE')" FAIL ;;
esac

SID="s-log-phase-1"
# shellcheck disable=SC1090
source "$BASELINE" "$SID"
bash "$LOG_SCRIPT" --phase RED_WRITE --step S1 --session "$SID"
EXIT_RW=$?
if [ "$EXIT_RW" = "0" ]; then
  check "--phase RED_WRITE: exit 0" PASS
else
  check "--phase RED_WRITE: exit 0 (got: $EXIT_RW)" FAIL
fi

source "$LIB"
STATE_PATH=$(tdd_state_file "$SID")
if [ -f "$STATE_PATH" ]; then
  check "--phase creates state file at expected path" PASS
else
  check "--phase creates state file at expected path (missing: $STATE_PATH)" FAIL
fi

GOT_PHASE=$(tdd_phase "$STATE_PATH")
if [ "$GOT_PHASE" = "RED_WRITE" ]; then
  check "state file phase is RED_WRITE" PASS
else
  check "state file phase is RED_WRITE (got: $GOT_PHASE)" FAIL
fi

GOT_STEP=$(tdd_step "$STATE_PATH")
if [ "$GOT_STEP" = "S1" ]; then
  check "state file step is S1" PASS
else
  check "state file step is S1 (got: $GOT_STEP)" FAIL
fi

bash "$LOG_SCRIPT" --phase RED_FAIL --step S1 --session "$SID" --reason "assertion mismatch on foo"
HAS_FAIL=$(tdd_has_red_fail "$STATE_PATH" "S1")
if [ "$HAS_FAIL" = "true" ]; then
  check "--phase RED_FAIL with --reason records RED_FAIL in history" PASS
else
  check "--phase RED_FAIL with --reason records RED_FAIL (got: $HAS_FAIL)" FAIL
fi

REASON_OK=$(node -e '
  const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const e = (j.history || []).find(h => h.phase === "RED_FAIL");
  console.log(e && e.reason === "assertion mismatch on foo" ? "yes" : "no");
' "$STATE_PATH" 2>/dev/null)
if [ "$REASON_OK" = "yes" ]; then
  check "RED_FAIL reason text preserved in history" PASS
else
  check "RED_FAIL reason text preserved in history (got: $REASON_OK)" FAIL
fi

bash "$LOG_SCRIPT" --phase IMPL --step S1 --session "$SID"
bash "$LOG_SCRIPT" --phase GREEN_PASS --step S1 --session "$SID"
FINAL_PHASE=$(tdd_phase "$STATE_PATH")
if [ "$FINAL_PHASE" = "GREEN_PASS" ]; then
  check "multiple --phase calls update latest phase to GREEN_PASS" PASS
else
  check "multiple --phase calls update latest phase to GREEN_PASS (got: $FINAL_PHASE)" FAIL
fi

OUT_BAD=$(bash "$LOG_SCRIPT" bogus 2>&1)
EXIT_BAD=$?
if [ "$EXIT_BAD" != "0" ]; then
  check "unknown subcommand exits non-zero (backward compat)" PASS
else
  check "unknown subcommand exits non-zero (got exit: $EXIT_BAD, out: $OUT_BAD)" FAIL
fi

echo "----"
echo "test-pre-edit-log-phase-subcmd: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
