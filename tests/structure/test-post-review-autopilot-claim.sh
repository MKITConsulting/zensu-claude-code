#!/bin/bash
# The reviewer ticket claim returns the exact validated Autopilot binding from
# the same locked read that consumes the ticket. Partial linkage is corruption
# and must leave both authoritative and derived state byte-stable.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PHASE="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
POST="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"

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
PROJECT="$ROOT/project"
mkdir -p "$PROJECT"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PROJECT_DIR="$PROJECT"
export ZENSU_TEST_PLUGIN_DATA="$ROOT/plugin-data"
export ZENSU_CONFIG="$ROOT/no-config.json"

# shellcheck disable=SC1090
source "$PHASE"

state_file() { tdd_state_file "$1"; }
start_session() {
  # shellcheck disable=SC1090
  source "$BASELINE" "$1"
}
digest() { node -e 'const fs=require("fs"),crypto=require("crypto");process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$1"; }
inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1" 2>/dev/null; }

begin_bound() {
  tdd_begin_session "$1" false true false "" "$2" "$3" "$4" "$5" >/dev/null
}

run_hook() {
  local session="$1" ticket="$2"
  SID="$session" TICKET="$ticket" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: "PostToolUse",
      tool_name: "Agent",
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
S1_RAW=claim_context_bound
R1=claim_context_run
C1=claim-context-chain
start_session "$S1_RAW"
S1="$ZENSU_SESSION_KEY"
begin_bound "$S1" "$R1" 7 FIX_FINDINGS "$C1" || true
T1="$(tdd_issue_review_ticket "$S1")"
CLAIM1="$(tdd_consume_review_ticket_context "$S1" "$T1" 2>/dev/null)"
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
S2_RAW=claim_context_standalone
start_session "$S2_RAW"
S2="$ZENSU_SESSION_KEY"
tdd_begin_session "$S2" false true >/dev/null
T2="$(tdd_issue_review_ticket "$S2")"
CLAIM2="$(tdd_consume_review_ticket_context "$S2" "$T2" 2>/dev/null)"
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

# Every partial-link variant must fail before the authoritative ticket claim.
# The single Session Control document must remain byte-stable.
#
# Failing closed and DISCLOSING are separate properties, and this case carries
# both. The decline is decided by THIS session's own record, so it is not one of
# the two classes that stay silent — a silent no-op here is exactly what left a
# chain at `ticket-unclaimed` with no cause reported on any channel. The ticket
# value never travels in either direction. `P13d` in
# `test-post-review-self-review-handoff.sh` pins the same contract for the
# envelope-free prompt this fixture sends.
PARTIAL_OK=true
INDEX=0
for KEY in autopilotRunId autopilotAttempt autopilotReturnStage chainId chainOutcome; do
  INDEX=$((INDEX + 1))
  SID_RAW="claim_partial_${INDEX}"
  start_session "$SID_RAW"
  SID="$ZENSU_SESSION_KEY"
  RUN_ID="claim_partial_run_${INDEX}"
  CHAIN_ID="claim-partial-chain-${INDEX}"
  begin_bound "$SID" "$RUN_ID" "$INDEX" GATES "$CHAIN_ID" || PARTIAL_OK=false
  TICKET="$(tdd_issue_review_ticket "$SID")" || PARTIAL_OK=false
  SF="$(state_file "$SID")"
  FILE="$SF" DELETE_KEY="$KEY" node -e '
    const fs = require("fs");
    const value = JSON.parse(fs.readFileSync(process.env.FILE, "utf8"));
    delete value[process.env.DELETE_KEY];
    fs.writeFileSync(process.env.FILE, JSON.stringify(value, null, 2));
  '
  STATE_DIGEST="$(digest "$SF")"
  STATE_INODE="$(inode "$SF")"
  OUT="$(run_hook "$SID_RAW" "$TICKET")"
  printf '%s' "$OUT" \
    | grep -qF -- "was NOT recorded against this session's review chain" \
    || PARTIAL_OK=false
  ! printf '%s' "$OUT" | grep -qF -- "$TICKET" || PARTIAL_OK=false
  [ "$(digest "$SF")" = "$STATE_DIGEST" ] || PARTIAL_OK=false
  [ "$(inode "$SF")" = "$STATE_INODE" ] || PARTIAL_OK=false
done
if [ "$PARTIAL_OK" = true ]; then
  check "C3 every partial Autopilot linkage leaves CAS state byte-identical and discloses without echoing the ticket" PASS
else
  check "C3 every partial Autopilot linkage leaves CAS state byte-identical and discloses without echoing the ticket" FAIL
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
S5_RAW=claim_unsafe_round
start_session "$S5_RAW"
S5="$ZENSU_SESSION_KEY"
tdd_begin_session "$S5" false true >/dev/null
T5="$(tdd_issue_review_ticket "$S5")"
SF5="$(state_file "$S5")"
FILE="$SF5" node -e '
  const fs = require("fs");
  const value = JSON.parse(fs.readFileSync(process.env.FILE, "utf8"));
  value.reviewRound = Number.MAX_SAFE_INTEGER;
  fs.writeFileSync(process.env.FILE, JSON.stringify(value, null, 2));
'
STATE_DIGEST5="$(digest "$SF5")"; STATE_INODE5="$(inode "$SF5")"
CLAIM5="$(tdd_consume_review_ticket_context "$S5" "$T5" 2>/dev/null || true)"
if [ -z "$CLAIM5" ] \
  && [ "$(digest "$SF5")" = "$STATE_DIGEST5" ] \
  && [ "$(inode "$SF5")" = "$STATE_INODE5" ]; then
  check "C5 unsafe reviewRound cannot consume or strand the ticket" PASS
else
  check "C5 unsafe reviewRound leaves CAS state byte-identical" FAIL
fi

printf '%s\n' '----'
printf 'test-post-review-autopilot-claim: %s PASS / %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
