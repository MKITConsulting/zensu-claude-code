#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/lib/zensu-log.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$SCRIPT" ]; then
  check "hooks/lib/zensu-log.sh exists" FAIL
  echo "----"
  echo "test-autofix-rounds-reset-on-fresh-tdd: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PLUGIN_DATA_OVERRIDE="$TMP_DIR/state"
export TDD_STATE_DIR="$TMP_DIR/tdd"
mkdir -p "$CLAUDE_PLUGIN_DATA_OVERRIDE" "$TDD_STATE_DIR"

SID="sess-reset-001"
COUNTER_FILE="$CLAUDE_PLUGIN_DATA_OVERRIDE/rounds-${SID}.json"
PHASE_FILE="$TDD_STATE_DIR/tdd-phase-${SID}.json"

seed_counter() { printf '{"count":4,"ts":"2026-01-01T00:00:00Z"}\n' > "$COUNTER_FILE"; }
counter_count() {
  node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(Number.isInteger(j.count)?j.count:"");}catch(_){console.log("");}' "$1" 2>/dev/null
}
flag_true() {
  node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(j[process.argv[2]]===true?"true":"false");}catch(_){console.log("false");}' "$1" "$2" 2>/dev/null
}

# --- Case 1: --tdd-begin resets (deletes) the rounds counter ----------------
seed_counter
bash "$SCRIPT" --tdd-begin --session "$SID" >/dev/null 2>&1
begin_rc=$?
if [ ! -e "$COUNTER_FILE" ]; then
  check "--tdd-begin deletes pre-existing rounds counter (fresh task -> round 1)" PASS
else
  check "--tdd-begin deletes pre-existing rounds counter (fresh task -> round 1)" FAIL
fi
if [ "$begin_rc" -eq 0 ]; then
  check "--tdd-begin exits 0 on success" PASS
else
  check "--tdd-begin exits 0 on success (got $begin_rc)" FAIL
fi

# --- Case 2: --tdd-begin still sets the active chain-state flag --------------
if [ "$(flag_true "$PHASE_FILE" active)" = "true" ]; then
  check "--tdd-begin still sets active=true (primary behavior preserved)" PASS
else
  check "--tdd-begin still sets active=true (primary behavior preserved)" FAIL
fi

# --- Case 3: --tdd-complete preserves the rounds counter --------------------
seed_counter
bash "$SCRIPT" --tdd-complete --session "$SID" >/dev/null 2>&1
if [ -f "$COUNTER_FILE" ] && [ "$(counter_count "$COUNTER_FILE")" = "4" ]; then
  check "--tdd-complete preserves rounds counter (mid-task, guard intact)" PASS
else
  check "--tdd-complete preserves rounds counter (mid-task, guard intact)" FAIL
fi

# --- Case 4: --chain-done preserves the rounds counter ----------------------
seed_counter
bash "$SCRIPT" --chain-done --session "$SID" >/dev/null 2>&1
if [ -f "$COUNTER_FILE" ] && [ "$(counter_count "$COUNTER_FILE")" = "4" ]; then
  check "--chain-done preserves rounds counter (mid-task, guard intact)" PASS
else
  check "--chain-done preserves rounds counter (mid-task, guard intact)" FAIL
fi

# --- Case 5: --tdd-begin is idempotent when no counter exists ---------------
rm -f "$COUNTER_FILE"
bash "$SCRIPT" --tdd-begin --session "$SID" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$COUNTER_FILE" ]; then
  check "--tdd-begin idempotent when counter absent (exit 0, no file created)" PASS
else
  check "--tdd-begin idempotent when counter absent (exit 0, no file created)" FAIL
fi

# --- Case 6: symlink guard — refuse to delete through a symlink -------------
TARGET="$TMP_DIR/evil-target.json"
printf '{"count":99,"ts":"2026-01-01T00:00:00Z"}\n' > "$TARGET"
rm -f "$COUNTER_FILE"
ln -s "$TARGET" "$COUNTER_FILE"
err="$(bash "$SCRIPT" --tdd-begin --session "$SID" 2>&1 >/dev/null)"
if [ -L "$COUNTER_FILE" ] && [ -f "$TARGET" ]; then
  check "--tdd-begin refuses symlink — link and target both intact" PASS
else
  check "--tdd-begin refuses symlink — link and target both intact" FAIL
fi
case "$err" in
  *symlink*) check "--tdd-begin emits symlink-refusal warning to stderr" PASS ;;
  *)         check "--tdd-begin emits symlink-refusal warning to stderr (got: $err)" FAIL ;;
esac

echo "----"
echo "test-autofix-rounds-reset-on-fresh-tdd: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
