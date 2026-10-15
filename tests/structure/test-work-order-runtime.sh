#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MODULE="$PLUGIN_DIR/hooks/lib/work-order-v1.js"
WRAPPER="$PLUGIN_DIR/hooks/lib/zensu-work-order.sh"
UNIT="$PLUGIN_DIR/tests/structure/work-order-v1.test.js"
FAKE_LIB="$PLUGIN_DIR/tests/structure/lib-work-order.sh"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
finish() {
  echo "----"
  echo "test-work-order-runtime: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

. "$PLUGIN_DIR/tests/structure/lib-unit-registry.sh"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    check "native Windows work-order run skipped (macOS/Linux/WSL required)" PASS
    unit_check_done "R2a every unit file the registry gives this suite was graded"
    finish; exit
    ;;
esac

for f in "$MODULE" "$WRAPPER" "$UNIT" "$FAKE_LIB" "$BASELINE"; do
  if [ ! -f "$f" ]; then
    check "R0 required file exists: $f" FAIL
    finish; exit 1
  fi
done
check "R0 module, wrapper, unit suite, fake and session baseline exist" PASS

[ -x "$WRAPPER" ] && bash -n "$WRAPPER" 2>/dev/null \
  && check "R1 wrapper is executable and parses" PASS || check "R1 wrapper is executable and parses" FAIL
node --check "$MODULE" 2>/dev/null && check "R1 module parses" PASS || check "R1 module parses" FAIL

unit_check "R2 the work-order runtime unit file passes with its registered count and no skipped case" "$UNIT"
unit_check_done "R2a every unit file the registry gives this suite was graded"

source "$FAKE_LIB"

SBOX="$(mktemp -d -t wo-runtime-XXXXXX)"
SBOX="$(cd "$SBOX" && pwd -P)"
trap 'rm -rf "$SBOX"' EXIT
PROJECT="$SBOX/project"
mkdir -p "$PROJECT"
export HOME="$SBOX/home"
mkdir -p "$HOME"
export CLAUDE_PROJECT_DIR="$PROJECT"
export ZENSU_CONFIG="$SBOX/config.json"
printf '%s\n' '{}' > "$ZENSU_CONFIG"
SESSION="wo-runtime-session-0001"
ORDER="33333333-3333-4333-8333-333333333333"
source "$BASELINE" "$SESSION" || { check "R3 test session binds" FAIL; finish; exit 1; }
check "R3 test session binds" PASS

wo_fake_install "$SBOX/bin" || { check "R4 fake zensu installs" FAIL; finish; exit 1; }
export PATH="$SBOX/bin:$PATH"
export FAKE_ZENSU_STATE="$SBOX/fake.json"
export FAKE_ZENSU_CALLS="$SBOX/calls.jsonl"
wo_fake_seed "$FAKE_ZENSU_STATE" "$ORDER" "$SESSION" auto implement
check "R4 fake zensu installs and seeds" PASS

OUT="$(env -u ZENSU_SESSION_TOKEN bash "$WRAPPER" --start --order "$ORDER" 2>&1)"; RC=$?
if [ "$RC" -eq 5 ] && printf '%s' "$OUT" | grep -q 'ZENSU_SESSION_TOKEN is not set' \
  && [ "$(wo_calls_matching "$FAKE_ZENSU_CALLS" '^work ')" = "0" ]; then
  check "R5 start without the session token refuses before any zensu work call" PASS
else
  check "R5 start without the session token refuses before any zensu work call (rc=$RC out=$OUT)" FAIL
fi

STATUS="$(env -u ZENSU_SESSION_TOKEN bash "$WRAPPER" --status 2>/dev/null)"
if [ "$(printf '%s' "$STATUS" | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>process.stdout.write(JSON.parse(s).mode))')" = "inert" ] \
  && [ ! -e "$PROJECT/.zensu/state/work-order" ]; then
  check "R6 status outside work-order mode is inert and writes nothing" PASS
else
  check "R6 status outside work-order mode is inert and writes nothing ($STATUS)" FAIL
fi

export ZENSU_SESSION_TOKEN="zst_fake_session_token"
export ZENSU_WORK_ORDER_RETRY_MS=1
export ZENSU_WORK_ORDER_RETRY_BUDGET_MS=50
OUT="$(bash "$WRAPPER" --start --order "$ORDER" 2>"$SBOX/start.err")"; RC=$?
ACTION="$(printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{try{process.stdout.write(JSON.parse(s).action)}catch(_){}})')"
if [ "$RC" -eq 0 ] && [ "$ACTION" = "implement" ] && ls "$PROJECT/.zensu/state/work-order/" | grep -q '^marker-'; then
  check "R7 start reads the order, writes the marker and dispatches the implement kind" PASS
else
  check "R7 start reads the order, writes the marker and dispatches the implement kind (rc=$RC out=$OUT err=$(cat "$SBOX/start.err"))" FAIL
fi

if [ "$(wo_calls_matching "$FAKE_ZENSU_CALLS" "^pulse start --work-order $ORDER --client-name zensu-claude-code --client-version ")" = "1" ] \
  && [ "$(wo_calls_matching "$FAKE_ZENSU_CALLS" "^work heartbeat $ORDER --json$")" = "1" ]; then
  check "R8 start renews the lease once and links Pulse with the harness client name" PASS
else
  check "R8 start renews the lease once and links Pulse with the harness client name" FAIL
fi

STATUS="$(bash "$WRAPPER" --status 2>/dev/null)"
if printf '%s' "$STATUS" | grep -q '"mode": "active"' && printf '%s' "$STATUS" | grep -q '"forgeWrites": "allowed"'; then
  check "R9 status reports an active order with forge writes allowed" PASS
else
  check "R9 status reports an active order with forge writes allowed ($STATUS)" FAIL
fi

wo_fake_set "$FAKE_ZENSU_STATE" 'state.staleAttempt = true'
bash "$WRAPPER" --renew --force >/dev/null 2>"$SBOX/renew.err"; RC=$?
STATUS="$(bash "$WRAPPER" --status 2>/dev/null)"
if [ "$RC" -eq 4 ] && printf '%s' "$STATUS" | grep -q '"lost": true' && printf '%s' "$STATUS" | grep -q '"forgeWrites": "denied"'; then
  check "R10 a 409 stale_attempt on renewal writes the lease-lost marker and denies forge writes" PASS
else
  check "R10 a 409 stale_attempt on renewal writes the lease-lost marker and denies forge writes (rc=$RC $STATUS)" FAIL
fi

PROJECT2="$SBOX/project2"
mkdir -p "$PROJECT2"
SESSION2="wo-runtime-session-0002"
ORDER2="44444444-4444-4444-8444-444444444444"
(
  export CLAUDE_PROJECT_DIR="$PROJECT2"
  export ZENSU_TEST_PLUGIN_DATA="$SBOX/plugin-data-2"
  source "$BASELINE" "$SESSION2" || exit 90
  wo_fake_seed "$FAKE_ZENSU_STATE" "$ORDER2" "$SESSION2" auto verify
  bash "$WRAPPER" --start --order "$ORDER2" >"$SBOX/start2.out" 2>"$SBOX/start2.err"
); RC=$?
if [ "$RC" -eq 6 ] && [ "$(wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.blocked_kind')" = "worker_error" ] \
  && wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.blocked_reason' | grep -q 'kind verify'; then
  check "R11 an order of an unsupported kind ends with blocked(worker_error) naming the kind" PASS
else
  check "R11 an order of an unsupported kind ends with blocked(worker_error) naming the kind (rc=$RC $(cat "$SBOX/start2.err" 2>/dev/null))" FAIL
fi

bash "$WRAPPER" --no-such-verb >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && check "R12 an unknown verb is a usage error" PASS || check "R12 an unknown verb is a usage error (rc=$RC)" FAIL

finish
