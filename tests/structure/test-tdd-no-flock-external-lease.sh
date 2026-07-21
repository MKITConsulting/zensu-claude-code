#!/bin/bash
# Every Bash 3.2-compatible caller shares one Core external-process lease.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PHASE="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
AUTOPILOT="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"

PASS=0
FAIL=0
check() {
  if [ "$2" = PASS ]; then
    echo "  PASS  $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $1"
    FAIL=$((FAIL + 1))
  fi
}

ROOT="$(mktemp -d -t zensu-no-flock-XXXXXX)"
cleanup() {
  [ -n "${MUTEX_ONE_PID:-}" ] && kill "$MUTEX_ONE_PID" 2>/dev/null || true
  [ -n "${MUTEX_TWO_PID:-}" ] && kill "$MUTEX_TWO_PID" 2>/dev/null || true
  [ -n "${LIVE_PID:-}" ] && kill "$LIVE_PID" 2>/dev/null || true
  [ -n "${CONTENDER_PID:-}" ] && kill "$CONTENDER_PID" 2>/dev/null || true
  [ -n "${DEAD_PID:-}" ] && kill "$DEAD_PID" 2>/dev/null || true
  [ -n "${MIXED_PATH_PID:-}" ] && kill "$MIXED_PATH_PID" 2>/dev/null || true
  [ -n "${MIXED_ENV_PID:-}" ] && kill "$MIXED_ENV_PID" 2>/dev/null || true
  [ -n "${AUTO_PATH_PID:-}" ] && kill "$AUTO_PATH_PID" 2>/dev/null || true
  [ -n "${AUTO_ENV_PID:-}" ] && kill "$AUTO_ENV_PID" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT

STATE_FILE="$ROOT/tdd-phase-scv1_$(printf '%064d' 1).json"
printf '{}\n' > "$STATE_FILE"
export CLAUDE_PROJECT_DIR="$ROOT"
export TDD_DISABLE_FLOCK=1
unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
# shellcheck disable=SC1090
source "$PHASE"

LOCKED_RUN_BODY="$(sed -n '/^_tdd_locked_run() {$/,/^}$/p' "$PHASE")"
LOCK_KEEPER_BODY="$(sed -n '/^_tdd_core_lock_keeper() {$/,/^}$/p' "$PHASE")"
if printf '%s\n' "$LOCK_KEEPER_BODY" | grep -Fq 'ownerPid: process.pid' \
  && printf '%s\n' "$LOCK_KEEPER_BODY" | grep -Fq 'acquireExternalProcessLock' \
  && printf '%s\n' "$LOCK_KEEPER_BODY" | grep -Fq 'releaseExternalProcessLock' \
  && printf '%s\n' "$LOCKED_RUN_BODY" | grep -Fq 'coproc $coproc_name' \
  && ! printf '%s\n' "$LOCKED_RUN_BODY" | grep -Fq 'command -v flock' \
  && ! printf '%s\n' "$LOCKED_RUN_BODY" | grep -Fq 'flock -x' \
  && ! printf '%s\n' "$LOCKED_RUN_BODY" | grep -Fq 'TDD_DISABLE_FLOCK' \
  && ! printf '%s\n' "$LOCKED_RUN_BODY" | grep -Fq 'local lock_file='; then
  check "S0 _tdd_locked_run has one Core lease namespace and no native flock branch" PASS
else
  check "S0 _tdd_locked_run has one Core lease namespace and no native flock branch" FAIL
fi

wait_for_file() {
  local file="$1" attempts=0
  while [ ! -f "$file" ] && [ "$attempts" -lt 200 ]; do
    attempts=$((attempts + 1))
    sleep 0.01 2>/dev/null || sleep 1
  done
  [ -f "$file" ]
}

FAKE_BIN="$ROOT/fake-flock-bin"
mkdir -p "$FAKE_BIN"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/flock"
chmod 700 "$FAKE_BIN/flock"
BASE_PATH="$PATH"

mixed_callback() {
  local worker="$1" attempts=0
  if (set -C; : > "$MIXED_MARKER") 2>/dev/null; then
    : > "$MIXED_ENTERED_PREFIX-$worker"
    printf '%s-enter\n' "$worker" >> "$MIXED_EVENTS"
    if [ "$worker" = path ]; then
      while [ ! -f "$MIXED_RELEASE" ] && [ "$attempts" -lt 500 ]; do
        attempts=$((attempts + 1))
        sleep 0.01 2>/dev/null || sleep 1
      done
    fi
    rm -f "$MIXED_MARKER"
    [ "$worker" != path ] || [ -f "$MIXED_RELEASE" ]
    return $?
  fi
  printf 'overlap\n' > "$MIXED_VIOLATION"
  return 91
}

MIXED_MARKER="$ROOT/mixed-active"
MIXED_VIOLATION="$ROOT/mixed-overlap"
MIXED_EVENTS="$ROOT/mixed-events"
MIXED_RELEASE="$ROOT/mixed-release"
MIXED_ENTERED_PREFIX="$ROOT/mixed-entered"
(
  PATH="$FAKE_BIN:$BASE_PATH" TDD_DISABLE_FLOCK=0 \
    _tdd_locked_run "$STATE_FILE" mixed_callback path
) &
MIXED_PATH_PID=$!
if wait_for_file "$MIXED_ENTERED_PREFIX-path"; then
  (
    PATH="$BASE_PATH" TDD_DISABLE_FLOCK=1 \
      _tdd_locked_run "$STATE_FILE" mixed_callback env
  ) &
  MIXED_ENV_PID=$!
  sleep 0.2
else
  MIXED_ENV_PID=""
fi
if [ -n "$MIXED_ENV_PID" ] && kill -0 "$MIXED_ENV_PID" 2>/dev/null \
  && [ ! -e "$MIXED_ENTERED_PREFIX-env" ] \
  && [ ! -e "$MIXED_VIOLATION" ]; then
  MIXED_BLOCKED=yes
else
  MIXED_BLOCKED=no
fi
: > "$MIXED_RELEASE"
wait "$MIXED_PATH_PID"; MIXED_PATH_RC=$?
if [ -n "$MIXED_ENV_PID" ]; then
  wait "$MIXED_ENV_PID"; MIXED_ENV_RC=$?
else
  MIXED_ENV_RC=92
fi
MIXED_PATH_PID=""; MIXED_ENV_PID=""
if [ "$MIXED_BLOCKED" = yes ] \
  && [ "$MIXED_PATH_RC" -eq 0 ] && [ "$MIXED_ENV_RC" -eq 0 ] \
  && [ ! -e "$MIXED_VIOLATION" ] && [ ! -e "${STATE_FILE}.lock" ] \
  && [ "$(wc -l < "$MIXED_EVENTS" | tr -d '[:space:]')" = 2 ]; then
  check "P5 callers with different PATH and legacy env values share one generic resource lease" PASS
else
  check "P5 callers with different PATH and legacy env values share one generic resource lease" FAIL
fi

# shellcheck disable=SC1090
source "$AUTOPILOT"
AUTOPILOT_LOCKED_RUN_BODY="$(sed -n '/^_autopilot_locked_run() {$/,/^}$/p' "$AUTOPILOT")"
if printf '%s\n' "$AUTOPILOT_LOCKED_RUN_BODY" | grep -Fq '_tdd_locked_run' \
  && ! printf '%s\n' "$AUTOPILOT_LOCKED_RUN_BODY" | grep -Fq 'AUTOPILOT_DISABLE_FLOCK' \
  && ! printf '%s\n' "$AUTOPILOT_LOCKED_RUN_BODY" | grep -Fq 'TDD_DISABLE_FLOCK'; then
  check "S1 _autopilot_locked_run delegates directly to the shared Core lease" PASS
else
  check "S1 _autopilot_locked_run delegates directly to the shared Core lease" FAIL
fi
AUTO_ROOT="$ROOT/autopilot-mixed"
mkdir -p "$AUTO_ROOT/.zensu/state"
MIXED_MARKER="$ROOT/autopilot-mixed-active"
MIXED_VIOLATION="$ROOT/autopilot-mixed-overlap"
MIXED_EVENTS="$ROOT/autopilot-mixed-events"
MIXED_RELEASE="$ROOT/autopilot-mixed-release"
MIXED_ENTERED_PREFIX="$ROOT/autopilot-mixed-entered"
(
  PATH="$FAKE_BIN:$BASE_PATH" AUTOPILOT_DISABLE_FLOCK=0 TDD_DISABLE_FLOCK=0 \
    _autopilot_locked_run "$AUTO_ROOT" mixed-run mixed_callback path
) &
AUTO_PATH_PID=$!
if wait_for_file "$MIXED_ENTERED_PREFIX-path"; then
  (
    PATH="$BASE_PATH" AUTOPILOT_DISABLE_FLOCK=1 TDD_DISABLE_FLOCK=0 \
      _autopilot_locked_run "$AUTO_ROOT" mixed-run mixed_callback env
  ) &
  AUTO_ENV_PID=$!
  sleep 0.2
else
  AUTO_ENV_PID=""
fi
if [ -n "$AUTO_ENV_PID" ] && kill -0 "$AUTO_ENV_PID" 2>/dev/null \
  && [ ! -e "$MIXED_ENTERED_PREFIX-env" ] \
  && [ ! -e "$MIXED_VIOLATION" ]; then
  AUTO_BLOCKED=yes
else
  AUTO_BLOCKED=no
fi
: > "$MIXED_RELEASE"
wait "$AUTO_PATH_PID"; AUTO_PATH_RC=$?
if [ -n "$AUTO_ENV_PID" ]; then
  wait "$AUTO_ENV_PID"; AUTO_ENV_RC=$?
else
  AUTO_ENV_RC=92
fi
AUTO_PATH_PID=""; AUTO_ENV_PID=""
if [ "$AUTO_BLOCKED" = yes ] \
  && [ "$AUTO_PATH_RC" -eq 0 ] && [ "$AUTO_ENV_RC" -eq 0 ] \
  && [ ! -e "$MIXED_VIOLATION" ] \
  && [ ! -e "$AUTO_ROOT/.zensu/state/autopilot.lock" ] \
  && [ "$(wc -l < "$MIXED_EVENTS" | tr -d '[:space:]')" = 2 ]; then
  check "P6 callers with different PATH and legacy env values share one Autopilot sentinel lease" PASS
else
  check "P6 callers with different PATH and legacy env values share one Autopilot sentinel lease" FAIL
fi

ABSENT_PENDING="$ROOT/pending-review.json"
create_pending_callback() {
  printf '{}\n' > "$ABSENT_PENDING"
}
if [ ! -e "$ABSENT_PENDING" ] \
  && _tdd_locked_run "$ABSENT_PENDING" create_pending_callback \
  && [ -f "$ABSENT_PENDING" ]; then
  check "P0 an absent pending-review resource is safely locked and created" PASS
else
  check "P0 an absent pending-review resource is safely locked and created" FAIL
fi

MUTEX_MARKER="$ROOT/mutex-active"
MUTEX_VIOLATION="$ROOT/mutex-overlap"
MUTEX_EVENTS="$ROOT/mutex-events"
mutex_callback() {
  local worker="$1"
  if [ -d "${STATE_FILE}.lockd" ]; then
    printf 'legacy-lock-directory\n' > "$MUTEX_VIOLATION"
  fi
  if (set -C; : > "$MUTEX_MARKER") 2>/dev/null; then
    printf '%s-enter\n' "$worker" >> "$MUTEX_EVENTS"
    sleep 0.2
    rm -f "$MUTEX_MARKER"
    return 0
  fi
  printf 'overlap\n' > "$MUTEX_VIOLATION"
  return 91
}

_tdd_locked_run "$STATE_FILE" mutex_callback one &
MUTEX_ONE_PID=$!
sleep 0.03
_tdd_locked_run "$STATE_FILE" mutex_callback two &
MUTEX_TWO_PID=$!
wait "$MUTEX_ONE_PID"; MUTEX_ONE_RC=$?
wait "$MUTEX_TWO_PID"; MUTEX_TWO_RC=$?
MUTEX_ONE_PID=""; MUTEX_TWO_PID=""
if [ "$MUTEX_ONE_RC" -eq 0 ] && [ "$MUTEX_TWO_RC" -eq 0 ] \
  && [ ! -e "$MUTEX_VIOLATION" ] \
  && [ "$(wc -l < "$MUTEX_EVENTS" | tr -d '[:space:]')" = 2 ] \
  && [ ! -e "${STATE_FILE}.lockd" ]; then
  check "P1 two Core-lease callbacks are mutually exclusive without a lock directory" PASS
else
  check "P1 two Core-lease callbacks are mutually exclusive without a lock directory" FAIL
fi

LIVE_ENTERED="$ROOT/live-entered"
LIVE_RELEASE="$ROOT/live-release"
CONTENDER_ENTERED="$ROOT/contender-entered"
live_callback() {
  local attempts=0
  : > "$LIVE_ENTERED"
  while [ ! -f "$LIVE_RELEASE" ] && [ "$attempts" -lt 500 ]; do
    attempts=$((attempts + 1))
    sleep 0.01 2>/dev/null || sleep 1
  done
  [ -f "$LIVE_RELEASE" ]
}
contender_callback() {
  : > "$CONTENDER_ENTERED"
}

_tdd_locked_run "$STATE_FILE" live_callback &
LIVE_PID=$!
if wait_for_file "$LIVE_ENTERED"; then
  LEASE_FILE="$(CONTROL_CORE="$CORE" LOCK_DIR="$ROOT" RESOURCE="$STATE_FILE" node -e '
    const core = require(process.env.CONTROL_CORE);
    process.stdout.write(core.externalProcessLockPath({
      lockDirectory: process.env.LOCK_DIR,
      resourcePath: process.env.RESOURCE,
    }));
  ' 2>/dev/null)"
else
  LEASE_FILE=""
fi
if [ -n "$LEASE_FILE" ] && [ -f "$LEASE_FILE" ]; then
  touch -t 200001010000 "$LEASE_FILE"
fi
_tdd_locked_run "$STATE_FILE" contender_callback &
CONTENDER_PID=$!
sleep 0.3
if [ -n "$LEASE_FILE" ] && [ -f "$LEASE_FILE" ] \
  && [ ! -f "$CONTENDER_ENTERED" ] \
  && kill -0 "$LIVE_PID" 2>/dev/null; then
  check "P2 an old lease with a live owner is never stolen" PASS
else
  check "P2 an old lease with a live owner is never stolen" FAIL
fi
: > "$LIVE_RELEASE"
wait "$LIVE_PID"; LIVE_RC=$?
wait "$CONTENDER_PID"; CONTENDER_RC=$?
LIVE_PID=""; CONTENDER_PID=""
if [ "$LIVE_RC" -eq 0 ] && [ "$CONTENDER_RC" -eq 0 ] \
  && [ -f "$CONTENDER_ENTERED" ]; then
  check "P3 the contender enters after the live owner releases" PASS
else
  check "P3 the contender enters after the live owner releases" FAIL
fi

DEAD_ENTERED="$ROOT/dead-entered"
RECLAIMED="$ROOT/dead-reclaimed"
dead_callback() {
  : > "$DEAD_ENTERED"
  while :; do sleep 1; done
}
reclaimed_callback() {
  : > "$RECLAIMED"
}

_tdd_locked_run "$STATE_FILE" dead_callback &
DEAD_PID=$!
if wait_for_file "$DEAD_ENTERED"; then
  kill -9 "$DEAD_PID" 2>/dev/null || true
  wait "$DEAD_PID" 2>/dev/null || true
else
  kill "$DEAD_PID" 2>/dev/null || true
fi
DEAD_PID=""
if _tdd_locked_run "$STATE_FILE" reclaimed_callback \
  && [ -f "$RECLAIMED" ]; then
  check "P4 a lease left by a killed owner is reclaimed" PASS
else
  check "P4 a lease left by a killed owner is reclaimed" FAIL
fi

echo "----"
echo "test-tdd-no-flock-external-lease: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
