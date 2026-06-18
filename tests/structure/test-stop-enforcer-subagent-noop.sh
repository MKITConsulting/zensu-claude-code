#!/bin/bash
# Pins the spawned-agent no-op in stop-chain-enforcer.sh (0.8.x): only the
# genuine top-level interactive thread enforces the review chain. A spawned
# agent (agent_id present, or a known zensu subagent agent_type) MUST allow its
# Stop even when the resolved session looks armed — blocking a subagent would
# deadlock the review cycle. Complements test-stop-enforcer-escapes.sh.
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

arm() {
  bash "$LOG" --tdd-begin --session "$1" >/dev/null 2>&1
  bash "$LOG" --tdd-complete --session "$1" >/dev/null 2>&1
}

SID="noop-armed"
arm "$SID"

OUT="$(printf '{"session_id":"%s"}' "$SID" | bash "$STOP" 2>/dev/null)"
[ "$(printf '%s' "$OUT" | decision)" = "block" ] \
  && check "N0 main-thread armed session blocks (control)" PASS \
  || check "N0 control block (out=$OUT)" FAIL

OUT="$(printf '{"session_id":"%s","agent_id":"sub-abc"}' "$SID" | bash "$STOP" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && { [ -z "$OUT" ] || [ "$(printf '%s' "$OUT" | decision)" = "allow" ]; }; then
  check "N1 agent_id present -> allow stop (Workflow worker / Task subagent, clean exit 0, no deadlock)" PASS
else
  check "N1 spawned agent_id allow (rc=$RC out=$OUT)" FAIL
fi

OUT="$(printf '{"session_id":"%s","agent_type":"zensu:code-reviewer"}' "$SID" | bash "$STOP" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && { [ -z "$OUT" ] || [ "$(printf '%s' "$OUT" | decision)" = "allow" ]; }; then
  check "N2 zensu:code-reviewer agent_type -> allow stop (clean exit 0)" PASS
else
  check "N2 reviewer subagent allow (rc=$RC out=$OUT)" FAIL
fi

OUT="$(printf '{"session_id":"%s","agent_type":"zensu:review-aspect"}' "$SID" | bash "$STOP" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && { [ -z "$OUT" ] || [ "$(printf '%s' "$OUT" | decision)" = "allow" ]; }; then
  check "N3 zensu:review-aspect agent_type -> allow stop (clean exit 0)" PASS
else
  check "N3 review-aspect allow (rc=$RC out=$OUT)" FAIL
fi

OUT="$(printf '{"session_id":"%s","agent_type":"Explore"}' "$SID" | bash "$STOP" 2>/dev/null)"
[ "$(printf '%s' "$OUT" | decision)" = "block" ] \
  && check "N4 unknown agent_type with no agent_id still blocks (could be --agent main thread)" PASS \
  || check "N4 unknown-type still blocks (out=$OUT)" FAIL

OUT="$(printf '{"session_id":"%s","agent_id":"sub-abc"}' "$SID" | ZENSU_FORCE_MAIN=1 bash "$STOP" 2>/dev/null)"
[ "$(printf '%s' "$OUT" | decision)" = "block" ] \
  && check "N5 ZENSU_FORCE_MAIN=1 re-enables enforcement despite agent_id" PASS \
  || check "N5 force-main block (out=$OUT)" FAIL

MARKER="$TDD_STATE_DIR/pending-review.json"
SID_NF="noop-nomutate"
bash "$LOG" --pending-review --files "x.ts" >/dev/null 2>&1
OUT="$(printf '{"session_id":"%s","agent_id":"sub-zzz"}' "$SID_NF" | bash "$STOP" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | decision)" = "allow" ] && [ -f "$MARKER" ]; then
  check "N6 spawned no-op short-circuits before deferred-adopt (marker NOT consumed -> precedes state mutation)" PASS
else
  check "N6 no-op precedes mutation (rc=$RC dec=$(printf '%s' "$OUT" | decision) marker=$([ -f "$MARKER" ] && echo y || echo n))" FAIL
fi
rm -f "$MARKER"

echo "----"
echo "test-stop-enforcer-subagent-noop: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
