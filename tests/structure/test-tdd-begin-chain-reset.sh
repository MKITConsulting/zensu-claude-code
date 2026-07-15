#!/bin/bash
# --tdd-begin chain-flag lifecycle — hermetic walk (no live claude, no API).
#
# Proves the Stop-hook review-chain backstop re-arms for EVERY /zensu:tdd chain
# in a session, not just the first: a completed chain leaves chainDone=true in
# the per-session state, and before this fix a second --tdd-begin never cleared
# it, so stop-chain-enforcer released on the stale flag for every later chain
# (load-bearing since the /zensu:pilot conductor makes multiple same-session
# tdd delegations the designed path).
#   begin #1: chain walk implComplete -> stop BLOCKS -> chainDone -> stop allows
#   begin #2: implComplete/chainDone/codeReviewDone/selfReviewFixed all cleared
#             in the state file, and the enforcer BLOCKS again after the second
#             --tdd-complete until a fresh --chain-done lands
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
POSTREV="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

# --- hermetic environment (main-thread chain-state only) ---
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
TDD_STATE_DIR="$(mktemp -d)"; export TDD_STATE_DIR
PROJ="$(mktemp -d)"; export CLAUDE_PROJECT_DIR="$PROJ"
export CLAUDE_PLUGIN_DATA_OVERRIDE="$PROJ/state"
export ZENSU_CONFIG="$TDD_STATE_DIR/no-such-config.json"
unset CLAUDE_AGENT_TYPE ZENSU_TDD_GATE ZENSU_TEST_WITNESS ZENSU_CHAIN 2>/dev/null || true
cleanup() { rm -rf "$TDD_STATE_DIR" "$PROJ"; }
trap cleanup EXIT

SID="lifecycle-$$"
LOG_STDERR="$TDD_STATE_DIR/log-stderr.txt"

log() { CLAUDE_SESSION_ID="$SID" bash "$LOG" "$@" >/dev/null 2>>"$LOG_STDERR"; }

stop_dec() {
  printf '%s' '{"session_id":"'"$SID"'"}' | bash "$STOP" 2>/dev/null | node -e '
    let s="";process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}
      try{console.log(JSON.parse(s).decision==="block"?"block":"allow")}catch(_){console.log("allow")}});'
}

flag() {  # echoes the boolean value of a state-file flag (or "missing")
  STATE_FILE="$(CLAUDE_SESSION_ID="$SID" bash -c '
    source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh" 2>/dev/null
    source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
    tdd_state_file "$CLAUDE_SESSION_ID"')" FLAG="$1" node -e '
    const fs=require("fs");
    try{const j=JSON.parse(fs.readFileSync(process.env.STATE_FILE,"utf8"));
      console.log(String(j[process.env.FLAG]));}catch(_){console.log("missing")}'
}

# --- chain #1: normal walk, enforcer releases on chainDone ---
log --tdd-begin
log --tdd-complete
TICKET1="$(CLAUDE_SESSION_ID="$SID" bash "$LOG" --review-ticket 2>>"$LOG_STDERR")"
[ -n "$TICKET1" ] && check "C0 chain #1 receives a review ticket" PASS \
                   || check "C0 chain #1 receives a review ticket" FAIL
D1="$(stop_dec)"
[ "$D1" = "block" ] && check "C1 chain #1: stop BLOCKS while implComplete && !chainDone" PASS \
                    || check "C1 chain #1: stop decision (got '$D1')" FAIL

# Route the matching Agent completion through the production PostToolUse hook;
# this is the official transition that consumes the one-shot ticket and records
# reviewRound=1 before any ticket-bound terminal flag may be written.
SID_VALUE="$SID" TICKET="$TICKET1" node -e '
  process.stdout.write(JSON.stringify({
    session_id: process.env.SID_VALUE,
    tool_input: {
      subagent_type: "zensu:code-reviewer",
      prompt: `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nfixture`
    }
  }));
' | bash "$POSTREV" >/dev/null 2>>"$LOG_STDERR"
log --code-review-done --claimed-review-ticket "$TICKET1"
log --self-review-fixed --claimed-review-ticket "$TICKET1"
log --chain-done --claimed-review-ticket "$TICKET1"
D2="$(stop_dec)"
[ "$D2" = "allow" ] && check "C2 chain #1: stop allows after --chain-done" PASS \
                    || check "C2 chain #1: stop decision (got '$D2')" FAIL

# --- begin #2: the four chain flags must be cleared ---
log --tdd-begin
RESET_FAIL=0
for f in implComplete chainDone codeReviewDone selfReviewFixed; do
  V="$(flag "$f")"
  [ "$V" = "false" ] || { RESET_FAIL=$((RESET_FAIL+1)); echo "      flag $f not cleared (got '$V')"; }
done
[ "$RESET_FAIL" -eq 0 ] && check "C3 begin #2 clears implComplete/chainDone/codeReviewDone/selfReviewFixed" PASS \
                        || check "C3 begin #2 chain-flag reset ($RESET_FAIL stale)" FAIL
TICKET_RESET="$(flag reviewTicket)"
CONSUMED_RESET="$(flag reviewTicketConsumed)"
[ "$TICKET_RESET" = "" ] && [ "$CONSUMED_RESET" = "true" ] \
  && check "C3a begin #2 invalidates the prior review ticket atomically" PASS \
  || check "C3a begin #2 review-ticket reset (ticket='$TICKET_RESET' consumed='$CONSUMED_RESET')" FAIL

BEGIN_BRANCH="$(awk '
  /^[[:space:]]*--tdd-begin\)/ { inside=1 }
  inside { print }
  inside && /^[[:space:]]*;;[[:space:]]*$/ { exit }
' "$LOG")"
BEGIN_CALLS="$(printf '%s\n' "$BEGIN_BRANCH" | grep -cF 'tdd_begin_session "$session_val" "$begin_vanilla"')"
if [ "$BEGIN_CALLS" = "1" ] \
  && ! printf '%s\n' "$BEGIN_BRANCH" | grep -qE 'tdd_set_flag|tdd_reset_chain_flags'; then
  check "C3b --tdd-begin uses one atomic state transition" PASS
else
  check "C3b --tdd-begin uses one atomic state transition (calls=$BEGIN_CALLS)" FAIL
fi

D3="$(stop_dec)"
[ "$D3" = "allow" ] && check "C4 begin #2: stop allows while chain #2 has not completed impl" PASS \
                    || check "C4 begin #2: stop decision (got '$D3')" FAIL

# --- chain #2: the backstop must be LIVE again ---
log --tdd-complete
D4="$(stop_dec)"
[ "$D4" = "block" ] && check "C5 chain #2: stop BLOCKS again after second --tdd-complete (backstop re-armed)" PASS \
                    || check "C5 chain #2: stop decision (got '$D4')" FAIL

log --chain-done
D5="$(stop_dec)"
[ "$D5" = "allow" ] && check "C6 chain #2: stop allows after fresh --chain-done" PASS \
                    || check "C6 chain #2: stop decision (got '$D5')" FAIL

echo "----"
echo "test-tdd-begin-chain-reset: $PASS PASS / $FAIL FAIL"
if [ "$FAIL" -ne 0 ] && [ -s "$LOG_STDERR" ]; then
  echo "  captured zensu-log.sh stderr:"
  sed 's/^/    /' "$LOG_STDERR"
fi
[ "$FAIL" -eq 0 ]
