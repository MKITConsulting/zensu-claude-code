#!/bin/bash
# The reviewer ticket claim returns the exact validated Autopilot binding from
# the same locked read that consumes the ticket. Partial linkage is corruption
# and must leave both authoritative and derived state byte-stable.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PHASE="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
POST="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"

PASS=0
FAIL=0
check() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

ROOT="$(mktemp -d -t zensu-postreview-claim-XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
STATE="$ROOT/state"
PROJECT="$ROOT/project"
mkdir -p "$STATE" "$PROJECT"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PROJECT_DIR="$PROJECT"
export CLAUDE_PLUGIN_DATA_OVERRIDE="$STATE"
export TDD_STATE_DIR="$STATE"
export ZENSU_CONFIG="$ROOT/no-config.json"

# shellcheck disable=SC1090
source "$PHASE"

state_file() { tdd_state_file "$1"; }
counter_file() { printf '%s/rounds-%s.json\n' "$STATE" "$1"; }
digest() { shasum -a 256 "$1" | awk '{print $1}'; }
inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1" 2>/dev/null; }

begin_bound() {
  tdd_begin_session "$1" false true false "" "$2" "$3" "$4" "$5" >/dev/null
}

run_hook() {
  local session="$1" ticket="$2"
  SID="$session" TICKET="$ticket" node -e '
    process.stdout.write(JSON.stringify({
      session_id: process.env.SID,
      tool_input: {
        subagent_type: "zensu:code-reviewer",
        prompt: `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nfixture`
      }
    }));
  ' | bash "$POST" 2>/dev/null
}

# The bound claim result is a closed JSON contract. It carries the round and
# all five linkage fields from the same pre-mutation snapshot.
S1=claim_context_bound
R1=claim_context_run
C1=claim-context-chain
begin_bound "$S1" "$R1" 7 FIX_FINDINGS "$C1" || true
T1="$(tdd_issue_review_ticket "$S1")"
CLAIM1="$(tdd_consume_review_ticket_context "$S1" "$T1" "$(counter_file "$S1")" 2>/dev/null)"
if CLAIM="$CLAIM1" RUN_ID="$R1" CHAIN_ID="$C1" node -e '
    try {
      const value = JSON.parse(process.env.CLAIM);
      const keys = Object.keys(value).sort().join(",");
      const bindingKeys = Object.keys(value.autopilot || {}).sort().join(",");
      const ok = keys === "autopilot,next" && value.next === 1
        && bindingKeys === "attempt,chainId,outcome,returnStage,runId"
        && value.autopilot.runId === process.env.RUN_ID
        && value.autopilot.attempt === 7
        && value.autopilot.returnStage === "FIX_FINDINGS"
        && value.autopilot.chainId === process.env.CHAIN_ID
        && value.autopilot.outcome === "";
      process.exit(ok ? 0 : 1);
    } catch (_) { process.exit(1); }
  ' 2>/dev/null; then
  check "C1 bound claim atomically returns NEXT plus the exact validated binding" PASS
else
  check "C1 bound claim atomically returns NEXT plus the exact validated binding" FAIL
fi

# Fully absent linkage remains a supported standalone claim and is represented
# explicitly as null, never as a guessed or partially empty binding.
S2=claim_context_standalone
tdd_begin_session "$S2" false true >/dev/null
T2="$(tdd_issue_review_ticket "$S2")"
CLAIM2="$(tdd_consume_review_ticket_context "$S2" "$T2" "$(counter_file "$S2")" 2>/dev/null)"
if CLAIM="$CLAIM2" node -e '
    try {
      const value = JSON.parse(process.env.CLAIM);
      process.exit(value.next === 1 && value.autopilot === null ? 0 : 1);
    } catch (_) { process.exit(1); }
  ' 2>/dev/null; then
  check "C2 fully absent linkage is returned as an explicit standalone claim" PASS
else
  check "C2 fully absent linkage is returned as an explicit standalone claim" FAIL
fi

# Every partial-link variant must fail before the authoritative ticket claim or
# the compatibility counter changes. Seed alternating present/absent counters
# so both byte-stability forms are covered.
PARTIAL_OK=true
INDEX=0
for KEY in autopilotRunId autopilotAttempt autopilotReturnStage chainId chainOutcome; do
  INDEX=$((INDEX + 1))
  SID="claim_partial_${INDEX}"
  RUN_ID="claim_partial_run_${INDEX}"
  CHAIN_ID="claim-partial-chain-${INDEX}"
  begin_bound "$SID" "$RUN_ID" "$INDEX" GATES "$CHAIN_ID" || PARTIAL_OK=false
  TICKET="$(tdd_issue_review_ticket "$SID")" || PARTIAL_OK=false
  SF="$(state_file "$SID")"
  CF="$(counter_file "$SID")"
  FILE="$SF" DELETE_KEY="$KEY" node -e '
    const fs = require("fs");
    const value = JSON.parse(fs.readFileSync(process.env.FILE, "utf8"));
    delete value[process.env.DELETE_KEY];
    fs.writeFileSync(process.env.FILE, JSON.stringify(value, null, 2));
  '
  if [ $((INDEX % 2)) -eq 1 ]; then
    printf '%s\n' '{"count":41,"sentinel":"unchanged"}' > "$CF"
    COUNTER_DIGEST="$(digest "$CF")"
    COUNTER_INODE="$(inode "$CF")"
  else
    COUNTER_DIGEST=absent
    COUNTER_INODE=absent
  fi
  STATE_DIGEST="$(digest "$SF")"
  STATE_INODE="$(inode "$SF")"
  OUT="$(run_hook "$SID" "$TICKET")"
  [ -z "$OUT" ] || PARTIAL_OK=false
  [ "$(digest "$SF")" = "$STATE_DIGEST" ] || PARTIAL_OK=false
  [ "$(inode "$SF")" = "$STATE_INODE" ] || PARTIAL_OK=false
  if [ "$COUNTER_DIGEST" = absent ]; then
    [ ! -e "$CF" ] || PARTIAL_OK=false
  else
    [ "$(digest "$CF")" = "$COUNTER_DIGEST" ] || PARTIAL_OK=false
    [ "$(inode "$CF")" = "$COUNTER_INODE" ] || PARTIAL_OK=false
  fi
done
if [ "$PARTIAL_OK" = true ]; then
  check "C3 every partial Autopilot linkage leaves state and counter byte-identical" PASS
else
  check "C3 every partial Autopilot linkage leaves state and counter byte-identical" FAIL
fi

# The hook must consume the structured claim result directly. A second
# tdd_autopilot_context read would re-introduce a generation TOCTOU window.
if grep -q 'tdd_consume_review_ticket_context' "$POST" \
  && ! grep -q 'tdd_autopilot_context' "$POST"; then
  check "C4 post-review routing uses no post-claim Autopilot context reread" PASS
else
  check "C4 post-review routing uses no post-claim Autopilot context reread" FAIL
fi

# JavaScript integers beyond MAX_SAFE_INTEGER can round during `next = round +
# 1`. Such a claim would consume the ticket before the hook rejects `next`, so
# the authoritative state and compatibility counter must remain untouched.
S5=claim_unsafe_round
tdd_begin_session "$S5" false true >/dev/null
T5="$(tdd_issue_review_ticket "$S5")"
SF5="$(state_file "$S5")"
CF5="$(counter_file "$S5")"
FILE="$SF5" node -e '
  const fs = require("fs");
  const value = JSON.parse(fs.readFileSync(process.env.FILE, "utf8"));
  value.reviewRound = Number.MAX_SAFE_INTEGER;
  fs.writeFileSync(process.env.FILE, JSON.stringify(value, null, 2));
'
printf '%s\n' '{"count":23,"sentinel":"unchanged"}' > "$CF5"
STATE_DIGEST5="$(digest "$SF5")"; STATE_INODE5="$(inode "$SF5")"
COUNTER_DIGEST5="$(digest "$CF5")"; COUNTER_INODE5="$(inode "$CF5")"
CLAIM5="$(tdd_consume_review_ticket_context "$S5" "$T5" "$CF5" 2>/dev/null || true)"
if [ -z "$CLAIM5" ] \
  && [ "$(digest "$SF5")" = "$STATE_DIGEST5" ] \
  && [ "$(inode "$SF5")" = "$STATE_INODE5" ] \
  && [ "$(digest "$CF5")" = "$COUNTER_DIGEST5" ] \
  && [ "$(inode "$CF5")" = "$COUNTER_INODE5" ]; then
  check "C5 unsafe reviewRound cannot consume or strand the ticket" PASS
else
  check "C5 unsafe reviewRound leaves state and counter byte-identical" FAIL
fi

printf '%s\n' '----'
printf 'test-post-review-autopilot-claim: %s PASS / %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
