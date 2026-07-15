#!/bin/bash
# Deferred review markers are claimed once, survive seed/output crashes, and do
# not shadow a later queued marker after completion/reset/cap release.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
ROOT="$(mktemp -d -t zensu-deferred-claim-XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0; FAIL=0
check() {
  if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}
decision() {
  node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{console.log(JSON.parse(s).decision==="block"?"block":"allow")}catch(_){console.log("allow")}});'
}

setup_case() {
  local config_json="${2:-}"
  CASE_ROOT="$ROOT/$1"
  CASE_STATE="$CASE_ROOT/state"
  CASE_PROJECT="$CASE_ROOT/project"
  CASE_CONFIG="$CASE_ROOT/config.json"
  mkdir -p "$CASE_STATE" "$CASE_PROJECT"
  [ -n "$config_json" ] || config_json='{}'
  printf '%s\n' "$config_json" > "$CASE_CONFIG"
}
zlog() {
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$CASE_PROJECT" \
    TDD_STATE_DIR="$CASE_STATE" CLAUDE_PLUGIN_DATA_OVERRIDE="$CASE_STATE" \
    ZENSU_CONFIG="$CASE_CONFIG" bash "$LOG" "$@"
}
stop() {
  local sid="$1"
  printf '{"session_id":"%s"}' "$sid" | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    CLAUDE_PROJECT_DIR="$CASE_PROJECT" TDD_STATE_DIR="$CASE_STATE" \
    CLAUDE_PLUGIN_DATA_OVERRIDE="$CASE_STATE" ZENSU_CONFIG="$CASE_CONFIG" \
    bash "$STOP" 2>/dev/null
}
state_flag() {
  node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1]));process.stdout.write(String(j[process.argv[2]]))}catch(_){process.stdout.write("missing")}' \
    "$CASE_STATE/tdd-phase-$1.json" "$2"
}

# Twenty simultaneous sessions race on one project marker. Only the winner
# seeds/blocks; the others observe the live/emitted ownership record and no-op.
setup_case parallel
zlog --pending-review --files x.ts >/dev/null
i=1
while [ "$i" -le 20 ]; do
  stop "parallel-$i" > "$CASE_ROOT/out-$i" &
  i=$((i + 1))
done
wait
WINNERS="$(grep -l '"decision":"block"' "$CASE_ROOT"/out-* 2>/dev/null | wc -l | tr -d '[:space:]')"
STATES="$(find "$CASE_STATE" -maxdepth 1 -name 'tdd-phase-parallel-*.json' -type f | wc -l | tr -d '[:space:]')"
if [ "$WINNERS" = 1 ] && [ "$STATES" = 1 ] && [ -f "$CASE_STATE/pending-review.json.claim" ]; then
  check "C1 parallel Stops adopt and block exactly once" PASS
else
  check "C1 parallel Stops adopt and block exactly once (blocks=$WINNERS states=$STATES)" FAIL
fi

# Simulate process death after seed but before block output: direct adoption
# leaves handoffEmitted=false and its owner PID dies with the subshell. Session B
# must transfer the claim, retire A, and block itself.
setup_case seed_crash
zlog --pending-review --files crash.ts >/dev/null
CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$CASE_PROJECT" \
  TDD_STATE_DIR="$CASE_STATE" CLAUDE_PLUGIN_DATA_OVERRIDE="$CASE_STATE" \
  ZENSU_CONFIG="$CASE_CONFIG" bash -c '
    source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
    tdd_adopt_pending_review owner-a true 0
  ' >/dev/null
OUT="$(stop owner-b)"
if [ "$(printf '%s' "$OUT" | decision)" = block ] \
  && [ "$(state_flag owner-a active)" = false ] \
  && [ "$(state_flag owner-b active)" = true ]; then
  check "C2 seed-before-output crash transfers one durable claim" PASS
else
  check "C2 seed-before-output crash transfers one durable claim" FAIL
fi

# If the SAME interactive session retries after that crash, its Stop handoff
# re-acknowledges the retained claim and renews the lease. A later unrelated
# session must not steal or duplicate the review that was just handed off.
setup_case seed_reack
zlog --pending-review --files reack.ts >/dev/null
CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$CASE_PROJECT" \
  TDD_STATE_DIR="$CASE_STATE" CLAUDE_PLUGIN_DATA_OVERRIDE="$CASE_STATE" \
  ZENSU_CONFIG="$CASE_CONFIG" bash -c '
    source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
    tdd_adopt_pending_review recovered-owner true 0
  ' >/dev/null
RECOVERED="$(stop recovered-owner)"
REACK_META="$(CLAIM_FILE="$CASE_STATE/pending-review.json.claim" node -e '
  const j = JSON.parse(require("fs").readFileSync(process.env.CLAIM_FILE, "utf8"));
  process.stdout.write(`${j.ownerSessionId}\t${j.handoffEmitted === true}`);
')"
CONTENDER="$(stop contender)"
if [ "$(printf '%s' "$RECOVERED" | decision)" = block ] \
  && [ "$REACK_META" = $'recovered-owner\ttrue' ] \
  && [ "$(printf '%s' "$CONTENDER" | decision)" = allow ] \
  && [ "$(state_flag recovered-owner active)" = true ] \
  && [ "$(state_flag contender active)" = missing ]; then
  check "C2b same-session Stop re-acknowledges crash claim before another session can steal it" PASS
else
  check "C2b same-session Stop re-acknowledges crash claim before another session can steal it" FAIL
fi

# The orchestrator's queue cleanup must not be able to delete an already
# adopted live claim. Ownership release is session-bound instead.
setup_case queue_cleanup
zlog --pending-review --files owned.ts >/dev/null
OWNED="$(stop cleanup-owner)"
zlog --pending-review-done >/dev/null
AFTER_CLEANUP="$(stop cleanup-owner)"
if [ "$(printf '%s' "$OWNED" | decision)" = block ] \
  && [ "$(printf '%s' "$AFTER_CLEANUP" | decision)" = block ] \
  && [ -f "$CASE_STATE/pending-review.json.claim" ]; then
  check "C3 queue cleanup cannot cancel a live ownership claim" PASS
else
  check "C3 queue cleanup cannot cancel a live ownership claim" FAIL
fi

# Explicit reset cancels the retained claim; it must not resurrect the adopted
# review on the next Stop.
setup_case reset_cancel
zlog --pending-review --files reset.ts >/dev/null
OUT="$(stop reset-owner)"
zlog --tdd-reset --session reset-owner >/dev/null
AFTER_RESET="$(stop reset-owner)"
if [ "$(printf '%s' "$OUT" | decision)" = block ] \
  && [ "$(printf '%s' "$AFTER_RESET" | decision)" = allow ] \
  && [ ! -e "$CASE_STATE/pending-review.json.claim" ] \
  && [ "$(state_flag reset-owner active)" = false ]; then
  check "C4 tdd-reset cancels rather than resurrects a retained claim" PASS
else
  check "C4 tdd-reset cancels rather than resurrects a retained claim" FAIL
fi

# A marker queued behind a completed ownership claim is adopted during the
# same terminal Stop, so no only-chance Stop releases with pending work.
setup_case queued
zlog --pending-review --files first.ts >/dev/null
FIRST="$(stop queued-owner)"
zlog --pending-review --files second.ts >/dev/null
zlog --chain-done --session queued-owner >/dev/null
SECOND="$(stop queued-owner)"
if [ "$(printf '%s' "$FIRST" | decision)" = block ] \
  && [ "$(printf '%s' "$SECOND" | decision)" = block ] \
  && [ ! -e "$CASE_STATE/pending-review.json" ] \
  && [ "$(state_flag queued-owner chainDone)" = false ]; then
  check "C5 terminal Stop immediately adopts a marker queued behind its claim" PASS
else
  check "C5 terminal Stop immediately adopts a marker queued behind its claim" FAIL
fi

# The anti-deadlock escape releases ownership so it cannot shadow future
# project reviews forever.
setup_case cap '{"hooks":{"autoFixMaxRounds":1}}'
zlog --pending-review --files capped.ts >/dev/null
CAP_SID=cap-owner
stop "$CAP_SID" >/dev/null
stop "$CAP_SID" >/dev/null
stop "$CAP_SID" >/dev/null
stop "$CAP_SID" >/dev/null
CAP_OUT="$(stop "$CAP_SID")"
if [ "$(printf '%s' "$CAP_OUT" | decision)" = allow ] \
  && [ ! -e "$CASE_STATE/pending-review.json.claim" ]; then
  check "C6 Stop-cap escape releases the deferred ownership claim" PASS
else
  check "C6 Stop-cap escape releases the deferred ownership claim" FAIL
fi

# Transferring an expired emitted claim renews its lease. The freshly informed
# owner must retain it until that renewed lease itself expires; otherwise every
# unrelated Stop can immediately retire the recovery session before it reviews.
setup_case lease_refresh '{"hooks":{"pendingReviewTtlHours":1}}'
zlog --pending-review --files leased.ts >/dev/null
LEASE_A="$(stop lease-a)"
LEASE_CLAIM="$CASE_STATE/pending-review.json.claim"
CLAIM_FILE="$LEASE_CLAIM" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.env.CLAIM_FILE, "utf8"));
  j.ts = "2020-01-01T00:00:00Z";
  fs.writeFileSync(process.env.CLAIM_FILE, JSON.stringify(j, null, 2));
'
LEASE_B="$(stop lease-b)"
LEASE_B_TS="$(CLAIM_FILE="$LEASE_CLAIM" node -e '
  const j = JSON.parse(require("fs").readFileSync(process.env.CLAIM_FILE, "utf8"));
  process.stdout.write(typeof j.ts === "string" ? j.ts : "");
')"
LEASE_C_FRESH="$(stop lease-c)"
CLAIM_FILE="$LEASE_CLAIM" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.env.CLAIM_FILE, "utf8"));
  j.ts = "2020-01-01T00:00:00Z";
  fs.writeFileSync(process.env.CLAIM_FILE, JSON.stringify(j, null, 2));
'
LEASE_C_EXPIRED="$(stop lease-c)"
if [ "$(printf '%s' "$LEASE_A" | decision)" = block ] \
  && [ "$(printf '%s' "$LEASE_B" | decision)" = block ] \
  && [ -n "$LEASE_B_TS" ] && [ "$LEASE_B_TS" != "2020-01-01T00:00:00Z" ] \
  && [ "$(printf '%s' "$LEASE_C_FRESH" | decision)" = allow ] \
  && [ "$(printf '%s' "$LEASE_C_EXPIRED" | decision)" = block ] \
  && [ "$(state_flag lease-b active)" = false ] \
  && [ "$(state_flag lease-c active)" = true ]; then
  check "C7 transferred claim renews timestamp lease before another session may adopt" PASS
else
  check "C7 transferred claim renews timestamp lease before another session may adopt" FAIL
fi

# timestampStyle:none deliberately persists no wall-clock timestamp. Assignment
# must therefore remove any inherited ts and renew the lease through the atomic
# replacement's mtime, with the same fresh-then-expired transfer behavior.
setup_case lease_refresh_none '{"hooks":{"pendingReviewTtlHours":1},"logging":{"timestampStyle":"none"}}'
zlog --pending-review --files leased-none.ts >/dev/null
LEASE_NONE_A="$(stop lease-none-a)"
LEASE_NONE_CLAIM="$CASE_STATE/pending-review.json.claim"
CLAIM_FILE="$LEASE_NONE_CLAIM" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.env.CLAIM_FILE, "utf8"));
  j.ts = "2020-01-01T00:00:00Z";
  fs.writeFileSync(process.env.CLAIM_FILE, JSON.stringify(j, null, 2));
'
LEASE_NONE_B="$(stop lease-none-b)"
LEASE_NONE_HAS_TS="$(CLAIM_FILE="$LEASE_NONE_CLAIM" node -e '
  const j = JSON.parse(require("fs").readFileSync(process.env.CLAIM_FILE, "utf8"));
  process.stdout.write(Object.prototype.hasOwnProperty.call(j, "ts") ? "yes" : "no");
')"
LEASE_NONE_C_FRESH="$(stop lease-none-c)"
touch -t 202001010000 "$LEASE_NONE_CLAIM" 2>/dev/null
LEASE_NONE_C_EXPIRED="$(stop lease-none-c)"
if [ "$(printf '%s' "$LEASE_NONE_A" | decision)" = block ] \
  && [ "$(printf '%s' "$LEASE_NONE_B" | decision)" = block ] \
  && [ "$LEASE_NONE_HAS_TS" = no ] \
  && [ "$(printf '%s' "$LEASE_NONE_C_FRESH" | decision)" = allow ] \
  && [ "$(printf '%s' "$LEASE_NONE_C_EXPIRED" | decision)" = block ] \
  && [ "$(state_flag lease-none-b active)" = false ] \
  && [ "$(state_flag lease-none-c active)" = true ]; then
  check "C8 timestampStyle none renews claim lease through mtime" PASS
else
  check "C8 timestampStyle none renews claim lease through mtime" FAIL
fi

echo "----"
echo "test-deferred-review-claim: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
