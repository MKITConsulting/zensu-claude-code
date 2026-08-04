#!/bin/bash
# Pins that a failed zensu-log.sh state verb names its cause instead of exiting
# with a bare code, and separates the one recoverable case from the rest:
#   S0 armed session, verb succeeds        -> no hint at all (silence pin)
#   S1 state file removed, --review-ticket -> names the loss and --tdd-begin
#   S2 state file removed, --tdd-complete  -> keeps its pinned line, adds the hint
#   S3 state file removed, --chain-done    -> same hint on the terminus
#   S4 state file removed, --code-review-done -> same hint (no verb left silent)
#   S5 unreadable state file               -> the unreadable/foreign branch instead
#   S6 armed session, foreign review ticket  -> the readable-state branch
# The removal case is the common one: '.zensu/' is gitignored, so a git clean, a
# worktree removal, or a branch cleanup wipes a live chain, after which every
# state verb failed silently or with a lumped cause.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
PHASE="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"

PASS=0
FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS + 1));
  else echo "  FAIL  $label"; FAIL=$((FAIL + 1)); fi
}

ROOT="$(mktemp -d -t zensu-state-hint-XXXXXX)"
ROOT="$(cd "$ROOT" && pwd -P)"
trap 'rm -rf "$ROOT"' EXIT

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export ZENSU_CONFIG="$ROOT/no-config.json"
unset CLAUDE_PLUGIN_DATA ZENSU_PROJECT_ROOT ZENSU_SESSION_CONTEXT ZENSU_SESSION_KEY \
  ZENSU_TEST_PLUGIN_DATA 2>/dev/null || true

# shellcheck disable=SC1090
source "$PHASE"

MISSING_HINT='no chain state exists for this session'
INVALID_HINT='unreadable or belongs to another session'
READABLE_HINT='the chain state is readable, so this verb'

ARMED_KEY=""
ARMED_STATE=""
arm() {
  local label="$1"
  local project="$ROOT/$label"
  mkdir -p "$project"
  project="$(cd "$project" && pwd -P)"
  export CLAUDE_PROJECT_DIR="$project"
  export ZENSU_TEST_PLUGIN_DATA="$ROOT/plugin-data-$label"
  # shellcheck disable=SC1090
  source "$BASELINE" "$label" || return 1
  bash "$LOG" --tdd-begin --session "$ZENSU_SESSION_KEY" >/dev/null 2>&1 || return 1
  bash "$LOG" --tdd-complete --session "$ZENSU_SESSION_KEY" >/dev/null 2>&1 || return 1
  ARMED_KEY="$ZENSU_SESSION_KEY"
  ARMED_STATE="$(tdd_state_file "$ARMED_KEY")"
}

verb() {
  local errfile="$1"
  shift
  bash "$LOG" "$@" --session "$ARMED_KEY" >/dev/null 2>"$errfile"
}

# --- S0 a succeeding verb stays silent ---
arm hint-ok || { echo "S0 fixture failed" >&2; exit 1; }
ERR0="$ROOT/s0.err"
verb "$ERR0" --review-ticket
RC0=$?
if [ "$RC0" -eq 0 ] && [ ! -s "$ERR0" ]; then
  check "S0 a succeeding state verb emits no hint" PASS
else
  check "S0 succeeding verb (rc=$RC0 err='$(cat "$ERR0" 2>/dev/null)')" FAIL
fi

# --- S6 a readable state with an unmet precondition gets its own branch ---
ERR6="$ROOT/s6.err"
verb "$ERR6" --code-review-done --claimed-review-ticket rt_notthisgeneration
RC6=$?
if [ "$RC6" -ne 0 ] && grep -qF "$READABLE_HINT" "$ERR6" \
  && ! grep -qF "$MISSING_HINT" "$ERR6"; then
  check "S6 a foreign ticket on readable state reports an unmet precondition" PASS
else
  check "S6 readable-state branch (rc=$RC6 err='$(cat "$ERR6" 2>/dev/null)')" FAIL
fi

# --- S1..S4 the chain state file is gone ---
arm hint-removed || { echo "S1 fixture failed" >&2; exit 1; }
rm -f "$ARMED_STATE"
[ ! -e "$ARMED_STATE" ] || { echo "S1 fixture: state file still present" >&2; exit 1; }

ERR1="$ROOT/s1.err"
verb "$ERR1" --review-ticket
RC1=$?
if [ "$RC1" -ne 0 ] && grep -qF "$MISSING_HINT" "$ERR1" \
  && grep -qF -- "--tdd-begin" "$ERR1" && grep -qF "gitignored" "$ERR1"; then
  check "S1 --review-ticket names the lost state, the cause and the recovery" PASS
else
  check "S1 --review-ticket (rc=$RC1 err='$(cat "$ERR1" 2>/dev/null)')" FAIL
fi

ERR2="$ROOT/s2.err"
verb "$ERR2" --tdd-complete
RC2=$?
if [ "$RC2" -ne 0 ] \
  && grep -qF 'corrupt, inactive, or foreign session state' "$ERR2" \
  && grep -qF "$MISSING_HINT" "$ERR2"; then
  check "S2 --tdd-complete keeps its pinned line and adds the cause" PASS
else
  check "S2 --tdd-complete (rc=$RC2 err='$(cat "$ERR2" 2>/dev/null)')" FAIL
fi

ERR3="$ROOT/s3.err"
verb "$ERR3" --chain-done
RC3=$?
if [ "$RC3" -ne 0 ] && grep -qF "$MISSING_HINT" "$ERR3"; then
  check "S3 --chain-done names the lost state instead of exiting silently" PASS
else
  check "S3 --chain-done (rc=$RC3 err='$(cat "$ERR3" 2>/dev/null)')" FAIL
fi

ERR4="$ROOT/s4.err"
verb "$ERR4" --code-review-done
RC4=$?
if [ "$RC4" -ne 0 ] && grep -qF "$MISSING_HINT" "$ERR4"; then
  check "S4 --code-review-done names the lost state too" PASS
else
  check "S4 --code-review-done (rc=$RC4 err='$(cat "$ERR4" 2>/dev/null)')" FAIL
fi

# --- S5 an unreadable state file is a different diagnosis ---
arm hint-corrupt || { echo "S5 fixture failed" >&2; exit 1; }
printf 'not json at all' > "$ARMED_STATE"
ERR5="$ROOT/s5.err"
verb "$ERR5" --review-ticket
RC5=$?
if [ "$RC5" -ne 0 ] && grep -qF "$INVALID_HINT" "$ERR5" \
  && ! grep -qF "$MISSING_HINT" "$ERR5"; then
  check "S5 an unreadable state file reports the unreadable branch, not the lost one" PASS
else
  check "S5 unreadable state (rc=$RC5 err='$(cat "$ERR5" 2>/dev/null)')" FAIL
fi

echo "----"
echo "test-state-verb-diagnostics: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
