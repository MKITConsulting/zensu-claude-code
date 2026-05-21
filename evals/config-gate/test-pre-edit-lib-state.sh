#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$LIB" ]; then
  check "hooks/lib/zensu-tdd-phase.sh exists" FAIL
  echo "----"; echo "test-pre-edit-lib-state: $PASS PASS / $FAIL FAIL"
  exit 1
fi

source "$LIB"

for fn in tdd_write_phase tdd_phase tdd_step tdd_has_red_fail; do
  if declare -F "$fn" >/dev/null; then
    check "function defined: $fn" PASS
  else
    check "function defined: $fn" FAIL
  fi
done

TDD_STATE_DIR="$(mktemp -d)"
export TDD_STATE_DIR
cleanup() { rm -rf "$TDD_STATE_DIR"; }
trap cleanup EXIT

SID="testsession1"
STATE_PATH="$(tdd_state_file "$SID")"

tdd_write_phase "$SID" "S1" "RED_WRITE" "" >/dev/null
if [ -f "$STATE_PATH" ]; then
  check "tdd_write_phase creates state file" PASS
else
  check "tdd_write_phase creates state file (expected $STATE_PATH)" FAIL
fi

GOT_PHASE=$(tdd_phase "$STATE_PATH")
if [ "$GOT_PHASE" = "RED_WRITE" ]; then
  check "tdd_phase reads RED_WRITE" PASS
else
  check "tdd_phase reads RED_WRITE (got: $GOT_PHASE)" FAIL
fi

GOT_STEP=$(tdd_step "$STATE_PATH")
if [ "$GOT_STEP" = "S1" ]; then
  check "tdd_step reads S1" PASS
else
  check "tdd_step reads S1 (got: $GOT_STEP)" FAIL
fi

HAS_FAIL=$(tdd_has_red_fail "$STATE_PATH" "S1")
if [ "$HAS_FAIL" = "false" ]; then
  check "tdd_has_red_fail S1: false (no RED_FAIL yet)" PASS
else
  check "tdd_has_red_fail S1: false (got: $HAS_FAIL)" FAIL
fi

tdd_write_phase "$SID" "S1" "RED_RUN" ""        >/dev/null
tdd_write_phase "$SID" "S1" "RED_FAIL" "assertion mismatch" >/dev/null

HAS_FAIL2=$(tdd_has_red_fail "$STATE_PATH" "S1")
if [ "$HAS_FAIL2" = "true" ]; then
  check "tdd_has_red_fail S1: true after RED_FAIL recorded" PASS
else
  check "tdd_has_red_fail S1: true after RED_FAIL recorded (got: $HAS_FAIL2)" FAIL
fi

HAS_FAIL_OTHER=$(tdd_has_red_fail "$STATE_PATH" "S2")
if [ "$HAS_FAIL_OTHER" = "false" ]; then
  check "tdd_has_red_fail S2: false (RED_FAIL exists only for S1)" PASS
else
  check "tdd_has_red_fail S2: false (got: $HAS_FAIL_OTHER)" FAIL
fi

tdd_write_phase "$SID" "S1" "IMPL" ""       >/dev/null
tdd_write_phase "$SID" "S1" "GREEN_PASS" "" >/dev/null

LATEST_PHASE=$(tdd_phase "$STATE_PATH")
if [ "$LATEST_PHASE" = "GREEN_PASS" ]; then
  check "tdd_phase returns LATEST phase (GREEN_PASS)" PASS
else
  check "tdd_phase returns LATEST phase (got: $LATEST_PHASE)" FAIL
fi

LATEST_STEP=$(tdd_step "$STATE_PATH")
if [ "$LATEST_STEP" = "S1" ]; then
  check "tdd_step returns LATEST step (S1)" PASS
else
  check "tdd_step returns LATEST step (got: $LATEST_STEP)" FAIL
fi

if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$STATE_PATH" 2>/dev/null; then
  check "state file is valid JSON" PASS
else
  check "state file is valid JSON" FAIL
fi

HISTORY_LEN=$(node -e '
  const j = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  console.log(Array.isArray(j.history) ? j.history.length : -1);
' "$STATE_PATH" 2>/dev/null)
if [ "$HISTORY_LEN" = "5" ]; then
  check "history records all 5 transitions" PASS
else
  check "history records all 5 transitions (got: $HISTORY_LEN)" FAIL
fi

REASON_FOUND=$(node -e '
  const j = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const e = (j.history || []).find(h => h.phase === "RED_FAIL");
  console.log(e && e.reason === "assertion mismatch" ? "yes" : "no");
' "$STATE_PATH" 2>/dev/null)
if [ "$REASON_FOUND" = "yes" ]; then
  check "RED_FAIL entry preserves reason text" PASS
else
  check "RED_FAIL entry preserves reason text (got: $REASON_FOUND)" FAIL
fi

PHASE_EMPTY=$(tdd_phase "/nonexistent/path.json")
if [ "$PHASE_EMPTY" = "UNINITIALIZED" ]; then
  check "tdd_phase on missing state file returns UNINITIALIZED" PASS
else
  check "tdd_phase on missing state file returns UNINITIALIZED (got: $PHASE_EMPTY)" FAIL
fi

echo "----"
echo "test-pre-edit-lib-state: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
