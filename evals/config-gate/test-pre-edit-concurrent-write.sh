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

source "$LIB"

TDD_STATE_DIR="$(mktemp -d)"
export TDD_STATE_DIR
cleanup() { rm -rf "$TDD_STATE_DIR"; }
trap cleanup EXIT

SID="concurrent-1"
STATE_PATH="$(tdd_state_file "$SID")"

N=10
PIDS=()
for i in $(seq 1 $N); do
  ( tdd_write_phase "$SID" "S$i" "RED_WRITE" "" >/dev/null ) &
  PIDS+=($!)
done
for pid in "${PIDS[@]}"; do wait "$pid"; done

if [ -f "$STATE_PATH" ]; then
  check "state file exists after concurrent writes" PASS
else
  check "state file exists after concurrent writes (missing!)" FAIL
fi

if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$STATE_PATH" 2>/dev/null; then
  check "state file is valid JSON after concurrent writes" PASS
else
  check "state file is valid JSON after concurrent writes" FAIL
fi

HISTORY_LEN=$(node -e '
  const j = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  console.log(Array.isArray(j.history) ? j.history.length : -1);
' "$STATE_PATH" 2>/dev/null)
if [ "$HISTORY_LEN" = "$N" ]; then
  check "history records ALL $N concurrent writes (got: $HISTORY_LEN)" PASS
else
  check "history records ALL $N concurrent writes (got: $HISTORY_LEN — last-writer-wins)" FAIL
fi

DISTINCT_STEPS=$(node -e '
  const j = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const steps = new Set((j.history || []).map(h => h.step));
  console.log(steps.size);
' "$STATE_PATH" 2>/dev/null)
if [ "$DISTINCT_STEPS" = "$N" ]; then
  check "history contains $N DISTINCT step IDs (no duplicates lost)" PASS
else
  check "history contains $N DISTINCT step IDs (got: $DISTINCT_STEPS)" FAIL
fi

if command -v flock >/dev/null 2>&1; then
  TDD_DISABLE_FLOCK=1
  export TDD_DISABLE_FLOCK
fi

SID_STALE="stale-lock-1"
STATE_PATH_STALE="$(tdd_state_file "$SID_STALE")"
mkdir -p "$(dirname "$STATE_PATH_STALE")"
LOCK_DIR="${STATE_PATH_STALE}.lockd"
mkdir "$LOCK_DIR"
echo "99999" > "$LOCK_DIR/owner"
touch -t 200001010000 "$LOCK_DIR" 2>/dev/null || true

START_NS=$(node -e 'process.stdout.write(String(Date.now()))')
tdd_write_phase "$SID_STALE" "S1" "RED_WRITE" "" >/dev/null
END_NS=$(node -e 'process.stdout.write(String(Date.now()))')
ELAPSED_MS=$((END_NS - START_NS))

if [ -f "$STATE_PATH_STALE" ]; then
  check "stale-lock recovery: write succeeded after recovering dead lock" PASS
else
  check "stale-lock recovery: write succeeded after recovering dead lock (state file missing)" FAIL
fi

GOT_STALE_PHASE=$(tdd_phase "$STATE_PATH_STALE")
if [ "$GOT_STALE_PHASE" = "RED_WRITE" ]; then
  check "stale-lock recovery: phase RED_WRITE recorded" PASS
else
  check "stale-lock recovery: phase RED_WRITE recorded (got: $GOT_STALE_PHASE)" FAIL
fi

if [ "$ELAPSED_MS" -lt 5000 ]; then
  check "stale-lock recovery: completed in <5s (got ${ELAPSED_MS}ms)" PASS
else
  check "stale-lock recovery: completed in <5s (got ${ELAPSED_MS}ms — likely blocked on stale lock)" FAIL
fi

unset TDD_DISABLE_FLOCK

SID_ENV="env-var-honored-1"
STATE_PATH_ENV="$(tdd_state_file "$SID_ENV")"
mkdir -p "$(dirname "$STATE_PATH_ENV")"
LOCK_DIR_ENV="${STATE_PATH_ENV}.lockd"
mkdir "$LOCK_DIR_ENV"
echo "99998" > "$LOCK_DIR_ENV/owner"
echo "sentinel" > "$LOCK_DIR_ENV/sentinel.txt"
touch -t 200001010000 "$LOCK_DIR_ENV" 2>/dev/null || true

TDD_DISABLE_FLOCK=1 tdd_write_phase "$SID_ENV" "S1" "RED_WRITE" "" >/dev/null

if [ -f "$STATE_PATH_ENV" ]; then
  check "TDD_DISABLE_FLOCK=1: state file exists after write" PASS
else
  check "TDD_DISABLE_FLOCK=1: state file exists after write (missing!)" FAIL
fi

if [ ! -f "$LOCK_DIR_ENV/sentinel.txt" ]; then
  check "TDD_DISABLE_FLOCK=1: mkdir-fallback executed (sentinel removed during stale-lock recovery)" PASS
else
  check "TDD_DISABLE_FLOCK=1: mkdir-fallback executed (sentinel survived — env var not honored, flock branch taken)" FAIL
fi

echo "----"
echo "test-pre-edit-concurrent-write: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
