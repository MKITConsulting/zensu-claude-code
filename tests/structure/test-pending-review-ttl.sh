#!/bin/bash
# Pins the pending-review marker freshness/TTL guard (0.8.x): a stale marker (its
# ISO-8601 ts older than hooks.pendingReviewTtlHours, default 6) is NOT adopted by
# the deferred-review branch — it is cleared and the Stop proceeds normally, so an
# abandoned marker from a crashed Workflow orchestrator cannot hijack a later
# unrelated interactive session. A fresh marker still adopts. TTL=0 disables the
# guard. Complements test-deferred-review-fallback.sh.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"

PASS=0; FAIL=0
check() {
  if [ "$2" = "PASS" ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
TDD_STATE_DIR="$(mktemp -d)"; export TDD_STATE_DIR
PROJ="$(mktemp -d)"; export CLAUDE_PROJECT_DIR="$PROJ"
export ZENSU_CONFIG="$TDD_STATE_DIR/no-such-config.json"
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN CLAUDE_SESSION_ID 2>/dev/null || true
cleanup() { rm -rf "$TDD_STATE_DIR" "$PROJ"; }
trap cleanup EXIT

decision() { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}try{console.log(JSON.parse(s).decision==="block"?"block":"allow")}catch(_){console.log("allow")}});'; }

MARKER="$TDD_STATE_DIR/pending-review.json"
OLD_TS='2020-01-01T00:00:00Z'

# --- Unit: tdd_pending_review_stale truth table ---
stale() { ( source "$PLUGIN_DIR/hooks/lib/zensu-config.sh"; source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"; tdd_pending_review_stale "$1" ); }

bash "$LOG" --pending-review --files "x.ts" --summary "fresh" >/dev/null 2>&1
[ "$(stale 6)" = "false" ] \
  && check "U1 fresh marker (just written) -> not stale @ ttl=6" PASS \
  || check "U1 fresh not stale" FAIL

printf '%s\n' '{"files":["x.ts"],"summary":"old","ts":"'"$OLD_TS"'"}' > "$MARKER"
[ "$(stale 6)" = "true" ] \
  && check "U2 marker with 2020 ts -> stale @ ttl=6" PASS \
  || check "U2 old stale" FAIL
[ "$(stale 0)" = "false" ] \
  && check "U3 ttl=0 disables staleness (old marker not stale)" PASS \
  || check "U3 ttl=0 disable" FAIL

printf '%s\n' '{"files":["x.ts"],"summary":"nots"}' > "$MARKER"
[ "$(stale 6)" = "false" ] \
  && check "U4 marker without ts -> not stale (cannot expire, fail-safe adopt)" PASS \
  || check "U4 no-ts not stale" FAIL
rm -f "$MARKER"

# --- Integration via stop-chain-enforcer ---
SID="ttl-main"

# Fresh marker -> adopt -> block + cleared (sanity, matches deferred fallback)
bash "$LOG" --pending-review --files "x.ts" --summary "fresh" >/dev/null 2>&1
OUT="$(printf '{"session_id":"%s"}' "$SID" | bash "$STOP" 2>/dev/null)"
{ [ "$(printf '%s' "$OUT" | decision)" = "block" ] && [ ! -f "$MARKER" ]; } \
  && check "I1 fresh marker -> adopt -> block + marker cleared" PASS \
  || check "I1 fresh adopt (dec=$(printf '%s' "$OUT" | decision) marker_exists=$([ -f "$MARKER" ] && echo y || echo n))" FAIL

# Stale marker -> NOT adopted -> allow (clean exit 0) + cleared
SID2="ttl-stale"
printf '%s\n' '{"files":["x.ts"],"summary":"old","ts":"'"$OLD_TS"'"}' > "$MARKER"
OUT="$(printf '{"session_id":"%s"}' "$SID2" | bash "$STOP" 2>/dev/null)"; RC=$?
{ [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | decision)" = "allow" ] && [ ! -f "$MARKER" ]; } \
  && check "I2 stale marker -> NOT adopted (allow, clean exit) + marker cleared" PASS \
  || check "I2 stale not adopted (rc=$RC dec=$(printf '%s' "$OUT" | decision) marker_exists=$([ -f "$MARKER" ] && echo y || echo n))" FAIL

# Stale marker but TTL disabled (=0) -> adopt -> block
SID3="ttl-disabled"
CFG_OFF="$TDD_STATE_DIR/ttl-off.json"
printf '%s\n' '{"hooks":{"pendingReviewTtlHours":0}}' > "$CFG_OFF"
printf '%s\n' '{"files":["x.ts"],"summary":"old","ts":"'"$OLD_TS"'"}' > "$MARKER"
OUT="$(printf '{"session_id":"%s"}' "$SID3" | ZENSU_CONFIG="$CFG_OFF" bash "$STOP" 2>/dev/null)"
[ "$(printf '%s' "$OUT" | decision)" = "block" ] \
  && check "I3 ttl=0 disables guard -> stale marker still adopts (block)" PASS \
  || check "I3 ttl=0 still adopts (dec=$(printf '%s' "$OUT" | decision))" FAIL
rm -f "$MARKER"

echo "----"
echo "test-pending-review-ttl: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
