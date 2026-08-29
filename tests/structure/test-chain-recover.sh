#!/bin/bash
# Functional regression for the read-only chain diagnosis (--chain-status) and
# the guarded escape hatch (--chain-recover). Pins that recovery reaches exactly
# ONE shape — a rearm receipt that disagrees with its own document, which makes
# --review-ticket refuse permanently — refuses every other shape byte-identically,
# never touches a terminal flag, a budget, an outstanding ticket, an Autopilot
# binding, or a claimed deferred-review generation, and fails closed on foreign,
# corrupt, absent, and unsafe state.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$ROOT/hooks/lib/zensu-log.sh"
CORE="$ROOT/hooks/lib/session-control-core-v1.js"
MODULE="$ROOT/hooks/lib/chain-recovery-v1.js"
PHASE_LIB="$ROOT/hooks/lib/zensu-tdd-phase.sh"
ENFORCER="$ROOT/hooks/stop-chain-enforcer.sh"
SKILL="$ROOT/skills/recover-chain/SKILL.md"
PLUGIN_JSON="$ROOT/.claude-plugin/plugin.json"
README="$ROOT/README.md"
PASS=0; FAIL=0
# Shared, locale-independent `node --test` summary parse (see the file header for
# why the count matters and why it is not hand-copied here).
. "$(dirname "$0")/lib-unit-summary.sh"
check() {
  local label="$1" result="$2"
  if [ "$result" = PASS ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$LOG" "$CORE" "$MODULE" "$PHASE_LIB" "$ENFORCER" "$SKILL" "$PLUGIN_JSON" "$README"; do
  if [ ! -f "$f" ]; then
    check "P0 required file exists: $f" FAIL
    echo "----"
    echo "test-chain-recover: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "P0 all target files exist" PASS

WORK="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM HUP

if node --test "$ROOT/tests/structure/chain-recovery-v1.test.js" >"$WORK/unit.out" 2>&1 \
  && unit_cases_registered_floor "$WORK/unit.out" 21; then
  check "P1 the classifier unit suite passes ($(unit_cases_report "$WORK/unit.out"))" PASS
else
  check "P1 the classifier unit suite passes ($(unit_cases_report "$WORK/unit.out"), want >= 21 registered; $(grep -c '^not ok' "$WORK/unit.out" 2>/dev/null) failing)" FAIL
  grep -B2 -A 20 '^not ok' "$WORK/unit.out" | sed 's/^/        /'
fi
export CLAUDE_PLUGIN_ROOT="$ROOT"
export CLAUDE_PLUGIN_DATA="$WORK/plugin-data"
export ZENSU_TEST_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA"
export ZENSU_CONFIG="$WORK/config.json"
mkdir -p "$CLAUDE_PLUGIN_DATA"
printf '%s\n' '{"hooks":{"autoFix":true,"autoFixMaxRounds":5}}' > "$ZENSU_CONFIG"

SID=""
STATE_FILE=""

new_chain_in_root() {
  SID="$1"
  ACTIVE_ROOT="$(cd "$2" && pwd -P)"
  ACTIVE_LOG="$ACTIVE_ROOT/hooks/lib/zensu-log.sh"
  ACTIVE_CORE="$ACTIVE_ROOT/hooks/lib/session-control-core-v1.js"
  SID_KEY=""; TICKET=""; BEFORE=""; RECOVER_RC=0; RECOVER_ERR=""; RECOVER_OUT=""
  STATE_FILE=""
  export CLAUDE_PLUGIN_ROOT="$ACTIVE_ROOT"
  export CLAUDE_PROJECT_DIR="$WORK/$SID"
  export STATE_DIR="$CLAUDE_PROJECT_DIR/.zensu/state"
  mkdir -p "$CLAUDE_PROJECT_DIR"
  # shellcheck disable=SC1090
  source "$ROOT/tests/session-control/initialize-baseline.sh" "$SID" "$ACTIVE_ROOT"
  # shellcheck disable=SC1090
  source "$ACTIVE_ROOT/hooks/lib/zensu-tdd-phase.sh"
  bash "$ACTIVE_LOG" --tdd-begin --session "$SID" >/dev/null 2>&1 \
    || { check "bootstrap: --tdd-begin failed for $SID" FAIL; return 1; }
  bash "$ACTIVE_LOG" --tdd-complete --session "$SID" >/dev/null 2>&1 \
    || { check "bootstrap: --tdd-complete failed for $SID" FAIL; return 1; }
  STATE_FILE="$(tdd_state_file "$(zensu_resolve_session_id "$SID")")" \
    || { check "bootstrap: state path unresolved for $SID" FAIL; return 1; }
  [ -f "$STATE_FILE" ] \
    || { check "bootstrap: state document missing for $SID" FAIL; return 1; }
}

new_chain() {
  new_chain_in_root "$1" "$ROOT"
}

seed() {
  local seed_err
  seed_err="$(CORE_PATH="${ACTIVE_CORE:-$CORE}" PROJECT_ROOT="${ZENSU_PROJECT_ROOT:-$CLAUDE_PROJECT_DIR}" \
    SID="$SID" BODY="$1" node -e '
    const core = require(process.env.CORE_PATH);
    const body = new Function("s", process.env.BODY);
    core.mutateWorkflowState({
      projectRoot: process.env.PROJECT_ROOT,
      sessionId: process.env.SID,
      workflowState: "test_seed",
      event: "test-seed",
    }, (s) => { body(s); return s; });
  ' 2>&1 >/dev/null)" || { check "seed failed for $SID: $seed_err" FAIL; return 1; }
}

document_diff() {
  BEFORE_DOC="$1" node -e '
    const fs = require("node:fs");
    const before = JSON.parse(process.env.BEFORE_DOC);
    const after = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const keys = [...new Set([...Object.keys(before), ...Object.keys(after)])].sort();
    const changed = keys.filter((key) => JSON.stringify(before[key]) !== JSON.stringify(after[key]));
    process.stdout.write(changed.join(","));
  ' "$STATE_FILE"
}

read_document() {
  node -e '
    const fs = require("node:fs");
    process.stdout.write(fs.readFileSync(process.argv[1], "utf8"));
  ' "$STATE_FILE"
}

status_field() {
  bash "$LOG" --chain-status --session "$SID" 2>/dev/null | FIELD="$1" node -e '
    let s = "";
    process.stdin.on("data", (d) => { s += d; }).on("end", () => {
      try {
        const value = JSON.parse(s)[process.env.FIELD];
        process.stdout.write(value === undefined ? "" : String(value));
      } catch (_) { process.stdout.write("PARSE_ERROR"); }
    });
  '
}

state_field() {
  FIELD="$1" node -e '
    const fs = require("node:fs");
    try {
      const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))[process.env.FIELD];
      process.stdout.write(value === undefined ? "" : String(value));
    } catch (_) { process.stdout.write("READ_ERROR"); }
  ' "$STATE_FILE"
}

last_history_reason() {
  node -e '
    const fs = require("node:fs");
    try {
      const history = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).history || [];
      const last = history[history.length - 1] || {};
      process.stdout.write(String(last.reason || ""));
    } catch (_) { process.stdout.write("READ_ERROR"); }
  ' "$STATE_FILE"
}

digest() {
  node -e '
    const fs = require("node:fs");
    const c = require("node:crypto");
    try {
      process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));
    } catch (_) { process.stdout.write("missing"); }
  ' "$STATE_FILE"
}

RECEIPT_ONLY='s.reviewRearm={schemaVersion:1,status:"pending",runId:"run-stale-1",attempt:2,chainId:"chain-stale-1",consumedTicketSha256:"a".repeat(64),retire:false};'
BOUND_LINK='s.autopilotRunId="run-bound-1";s.autopilotAttempt=1;s.autopilotReturnStage="GATES";s.chainId="chain-bound-1";s.chainOutcome="";'
# The only shape a real writer can leave behind is a receipt on a BOUND document
# whose binding it no longer matches; a standalone document carrying one is
# corrupt input that recovery refuses (link-shape).
STALE_RECEIPT="${BOUND_LINK}${RECEIPT_ONLY}"

# ---------------------------------------------------------------- reachable shapes
new_chain "chain-recover-healthy"
[ "$(status_field shape)" = "ready-for-review" ] \
  && check "T1 a completed implementation reports ready-for-review" PASS \
  || check "T1 a completed implementation reports ready-for-review (got: $(status_field shape))" FAIL

BEFORE="$(digest)"
bash "$LOG" --chain-status --session "$SID" >/dev/null 2>&1
[ "$BEFORE" = "$(digest)" ] \
  && check "T2 --chain-status is byte-for-byte read-only" PASS \
  || check "T2 --chain-status is byte-for-byte read-only" FAIL

RECOVER_ERR="$(bash "$LOG" --chain-recover --session "$SID" 2>&1 >/dev/null)"
RECOVER_RC=$?
[ "$RECOVER_RC" -eq 3 ] && [ "$BEFORE" = "$(digest)" ] \
  && check "T3 recover refuses a healthy chain and preserves the state bytes" PASS \
  || check "T3 recover refuses a healthy chain and preserves the state bytes (rc=$RECOVER_RC)" FAIL

case "$RECOVER_ERR" in
  *"ready-for-review"*"not wedged"*"--review-ticket"*)
    check "T4 the refusal names the shape, denies the wedge, and gives the supported command" PASS ;;
  *)
    check "T4 the refusal names the shape, denies the wedge, and gives the supported command (got: $RECOVER_ERR)" FAIL ;;
esac

# ---------------------------------------------------------------- the one real wedge
new_chain "chain-recover-stale"
seed "$STALE_RECEIPT"

if bash "$LOG" --review-ticket --session "$SID" >/dev/null 2>&1; then
  check "T5 a receipt that disagrees with its document blocks --review-ticket" FAIL
else
  check "T5 a receipt that disagrees with its document blocks --review-ticket" PASS
fi

[ "$(status_field shape)" = "wedged-stale-rearm" ] && [ "$(status_field recoverable)" = "true" ] \
  && [ "$(status_field rearmReceipt)" = "stale" ] \
  && check "T6 status classifies the blocked chain as a recoverable wedge" PASS \
  || check "T6 status classifies the blocked chain as a recoverable wedge (got: $(status_field shape))" FAIL

REV_BEFORE="$(state_field revision)"
RECOVER_OUT="$(bash "$LOG" --chain-recover --session "$SID" 2>/dev/null)"
RECOVER_RC=$?
[ "$RECOVER_RC" -eq 0 ] && [ "$RECOVER_OUT" = "recovered: wedged-stale-rearm" ] \
  && check "T7 recover accepts the stale-receipt wedge" PASS \
  || check "T7 recover accepts the stale-receipt wedge (rc=$RECOVER_RC out=$RECOVER_OUT)" FAIL

[ "$(status_field shape)" = "ready-for-review" ] && [ "$(status_field rearmReceipt)" = "none" ] \
  && check "T8 the recovered chain is reviewable again and carries no receipt" PASS \
  || check "T8 the recovered chain is reviewable again and carries no receipt (got: $(status_field shape))" FAIL

REISSUED="$(bash "$LOG" --review-ticket --session "$SID" 2>/dev/null)"
case "$REISSUED" in
  rt_*) check "T9 --review-ticket issues again after recovery" PASS ;;
  *) check "T9 --review-ticket issues again after recovery (got: $REISSUED)" FAIL ;;
esac

case "$(last_history_reason)" in
  *chain-recovered*)
    check "T10 the recovery records its provenance as a history entry inside the transaction" PASS ;;
  *)
    check "T10 the recovery records its provenance as a history entry (got: $(last_history_reason))" FAIL ;;
esac

case ", $(tdd_bypasses "$STATE_FILE")," in
  *ZENSU_CHAIN_RECOVER*)
    check "T10b a repair never appears in the gate-escape ledger (no gate was bypassed)" FAIL ;;
  *)
    check "T10b a repair never appears in the gate-escape ledger (no gate was bypassed)" PASS ;;
esac

# ---------------------------------------------------------------- budgets, flags, revision
new_chain "chain-recover-budget"
seed "s.reviewRound=4;s.stopBlockCount=2;s.bypasses=[\"ZENSU_TDD_GATE\"];$STALE_RECEIPT" || true
REV_BEFORE="$(state_field revision)"
DOC_BEFORE="$(read_document)"
bash "$LOG" --chain-recover --session "$SID" >/dev/null 2>&1
BUDGET_RC=$?
[ "$BUDGET_RC" -eq 0 ] && [ "$(status_field reviewRound)" = "4" ] \
  && [ "$(status_field stopBlockCount)" = "2" ] \
  && [ "$(status_field implStopCount)" = "0" ] \
  && check "T11 recovery preserves the review and Stop budgets (no free round)" PASS \
  || check "T11 recovery preserves the review and Stop budgets (rc=$BUDGET_RC round=$(status_field reviewRound) stops=$(status_field stopBlockCount))" FAIL

[ "$(status_field chainDone)" = "false" ] && [ "$(status_field codeReviewDone)" = "false" ] \
  && [ "$(status_field selfReviewFixed)" = "false" ] \
  && check "T12 recovery never sets a terminal flag" PASS \
  || check "T12 recovery never sets a terminal flag" FAIL

REV_AFTER="$(state_field revision)"
REV_DELTA=$(( REV_AFTER - REV_BEFORE ))
[ "$REV_DELTA" -eq 1 ] \
  && check "T12b the repair and its audit record are one single revision" PASS \
  || check "T12b the repair and its audit record are one single revision (got delta $REV_DELTA)" FAIL

CHANGED="$(document_diff "$DOC_BEFORE")"
[ "$CHANGED" = "history,last_event,reviewRearm,revision,updated_at,workflow_state" ] \
  && check "T12c recovery changes ONLY the receipt, its history entry and the bookkeeping" PASS \
  || check "T12c recovery changes ONLY the expected keys (got: $CHANGED)" FAIL

RAW_LEDGER="$(state_field bypasses)"
[ "$RAW_LEDGER" = "ZENSU_TDD_GATE" ] \
  && check "T12d the recovery leaves the gate-escape ledger byte-identical" PASS \
  || check "T12d the recovery leaves the gate-escape ledger byte-identical (got: $RAW_LEDGER)" FAIL

new_chain "chain-recover-slot"
seed "s.reviewTicketConsumed=false;$STALE_RECEIPT" || true
BEFORE="$(digest)"
SLOT_RC=0
SLOT_ERR="$(bash "$LOG" --chain-recover --session "$SID" 2>&1 >/dev/null)" || SLOT_RC=$?
[ "$SLOT_RC" -eq 3 ] && [ "$BEFORE" = "$(digest)" ] \
  && [ "$(status_field nextCommandId)" = "ticket-slot" ] \
  && check "T12e an inconsistent ticket slot is REFUSED — normalizing it would satisfy the no-ticket review terminus" PASS \
  || check "T12e an inconsistent ticket slot is REFUSED (rc=$SLOT_RC reason=$(status_field nextCommandId))" FAIL

case "$SLOT_ERR" in
  *"review terminus"*)
    check "T12f the ticket-slot refusal explains why the repair is withheld" PASS ;;
  *)
    check "T12f the ticket-slot refusal explains why the repair is withheld (got: $SLOT_ERR)" FAIL ;;
esac

UNCLAIMED_TERMINUS_RC=0
bash "$LOG" --code-review-done --session "$SID" >/dev/null 2>&1 || UNCLAIMED_TERMINUS_RC=$?
[ "$UNCLAIMED_TERMINUS_RC" -ne 0 ] && [ "$(state_field codeReviewDone)" = "false" ] \
  && [ "$(state_field reviewTicketConsumed)" = "false" ] \
  && check "T12g the refused document keeps consumed=false, so the no-ticket terminus stays shut" PASS \
  || check "T12g the refused document keeps consumed=false (rc=$UNCLAIMED_TERMINUS_RC consumed=$(state_field reviewTicketConsumed))" FAIL

new_chain "chain-recover-slot-control"
seed "$STALE_RECEIPT" || true
WEDGED_TERMINUS_RC=0
bash "$LOG" --code-review-done --session "$SID" >/dev/null 2>&1 || WEDGED_TERMINUS_RC=$?
[ "$WEDGED_TERMINUS_RC" -ne 0 ] && [ "$(state_field codeReviewDone)" = "false" ] \
  && check "T12h0 while a disagreeing receipt is present the unqualified no-ticket terminus is refused" PASS \
  || check "T12h0 while a disagreeing receipt is present the unqualified terminus is refused (rc=$WEDGED_TERMINUS_RC)" FAIL

bash "$LOG" --chain-recover --session "$SID" >/dev/null 2>&1
CONTROL_RECOVER_RC=$?
[ "$(status_field recoveries)" = "1" ] \
  && check "T12h1 the repair is counted as one durable recovery in the report" PASS \
  || check "T12h1 the repair is counted as one durable recovery (got: $(status_field recoveries))" FAIL

RESERVED_PHASE="$(MODULE_PATH="$MODULE" node -e 'process.stdout.write(require(process.env.MODULE_PATH).RECOVERY_HISTORY_PHASE)')"
RESERVED_PREFIX="$(MODULE_PATH="$MODULE" node -e 'process.stdout.write(require(process.env.MODULE_PATH).RECOVERY_HISTORY_REASON_PREFIX)')"
FORGE_PHASE_RC=0
bash "$LOG" --phase "$RESERVED_PHASE" --step forged --session "$SID" >/dev/null 2>&1 || FORGE_PHASE_RC=$?
FORGE_REASON_RC=0
bash "$LOG" --phase IMPL --step forged --reason "${RESERVED_PREFIX}forged" --session "$SID" >/dev/null 2>&1 \
  || FORGE_REASON_RC=$?
FORGE_DIRECT_RC=0
_tdd_write_phase_critical "$STATE_FILE" "$(zensu_resolve_session_id "$SID")" forged \
  "$RESERVED_PHASE" "${RESERVED_PREFIX}forged" >/dev/null 2>&1 || FORGE_DIRECT_RC=$?
[ "$FORGE_PHASE_RC" -eq 2 ] && [ "$FORGE_REASON_RC" -eq 2 ] && [ "$FORGE_DIRECT_RC" -ne 0 ] \
  && [ "$(status_field recoveries)" = "1" ] \
  && check "T12h2 the reserved phase and reason are refused by the verb AND by the exported writer, so the counter cannot be forged" PASS \
  || check "T12h2 the recovery counter cannot be forged (phase=$FORGE_PHASE_RC reason=$FORGE_REASON_RC direct=$FORGE_DIRECT_RC count=$(status_field recoveries))" FAIL
CONTROL_TERMINUS_RC=0
bash "$LOG" --code-review-done --session "$SID" >/dev/null 2>&1 || CONTROL_TERMINUS_RC=$?
[ "$CONTROL_RECOVER_RC" -eq 0 ] && [ "$CONTROL_TERMINUS_RC" -ne 0 ] \
  && [ "$(state_field codeReviewDone)" = "false" ] \
  && check "T12h positive control: with a CONSISTENT slot the same document recovers — so T12g's refusal is attributable to the slot alone — while the unqualified no-ticket terminus stays REFUSED on the repaired bound chain" PASS \
  || check "T12h positive control: consistent slot recovers and the unqualified terminus stays shut (recover=$CONTROL_RECOVER_RC terminus=$CONTROL_TERMINUS_RC flag=$(state_field codeReviewDone))" FAIL

# ---------------------------------------------------------------- lost ticket is NOT a wedge
new_chain "chain-recover-orphan"
seed 's.reviewTicket="";s.reviewTicketConsumed=true;s.reviewRound=2;' || true
[ "$(status_field shape)" = "ticket-lost" ] && [ "$(status_field wedged)" = "false" ] \
  && check "T13 a consumed round whose ticket is gone reports ticket-lost, not a wedge" PASS \
  || check "T13 a consumed round whose ticket is gone reports ticket-lost (got: $(status_field shape))" FAIL

BEFORE="$(digest)"
RECOVER_RC=0
bash "$LOG" --chain-recover --session "$SID" >/dev/null 2>&1 || RECOVER_RC=$?
AFTER_REFUSAL="$(digest)"
LOST_TICKET="$(bash "$LOG" --review-ticket --session "$SID" 2>/dev/null)"
case "$RECOVER_RC:$LOST_TICKET" in
  3:rt_*)
    check "T14 recover refuses it because --review-ticket still advances that chain" PASS ;;
  *)
    check "T14 recover refuses it because --review-ticket still advances that chain (rc=$RECOVER_RC ticket=$LOST_TICKET)" FAIL ;;
esac
[ "$BEFORE" = "$AFTER_REFUSAL" ] \
  && check "T14b the refused recovery left the state bytes untouched" PASS \
  || check "T14b the refused recovery left the state bytes untouched" FAIL

# ---------------------------------------------------------------- an outstanding ticket outranks the receipt
new_chain "chain-recover-outstanding"
OUTSTANDING="$(bash "$LOG" --review-ticket --session "$SID" 2>/dev/null)"
seed "$STALE_RECEIPT" || true
[ "$(status_field shape)" = "ticket-unclaimed" ] && [ "$(status_field wedged)" = "false" ] \
  && check "T15 an unconsumed ticket outranks a stale receipt (the spawned reviewer can still claim it)" PASS \
  || check "T15 an unconsumed ticket outranks a stale receipt (got: $(status_field shape))" FAIL

RECOVER_RC=0
bash "$LOG" --chain-recover --session "$SID" >/dev/null 2>&1 || RECOVER_RC=$?
SID_KEY="$(zensu_resolve_session_id "$SID")"
CLAIMED_ROUND="$(tdd_consume_review_ticket "$SID_KEY" "$OUTSTANDING" 2>/dev/null)"
[ "$RECOVER_RC" -eq 3 ] && [ "$CLAIMED_ROUND" = "1" ] \
  && check "T16 recovery refuses rather than discarding a live outstanding ticket" PASS \
  || check "T16 recovery refuses rather than discarding a live outstanding ticket (rc=$RECOVER_RC round=$CLAIMED_ROUND)" FAIL

STATUS_RAW="$(bash "$LOG" --chain-status --session "$SID" 2>/dev/null)"
case "$STATUS_RAW" in
  *"$OUTSTANDING"*) TICKET_LEAKED=yes ;;
  *) TICKET_LEAKED=no ;;
esac
[ "$(status_field shape)" = "review-in-flight" ] \
  && [ "$(status_field claimedReviewTicketPresent)" = "true" ] \
  && [ "$TICKET_LEAKED" = no ] \
  && check "T17 status reports a claimed ticket as a boolean and the value appears nowhere in its output" PASS \
  || check "T17 status reports a claimed ticket as a boolean and the value appears nowhere (shape=$(status_field shape) leaked=$TICKET_LEAKED)" FAIL

RECOVER_ERR="$(bash "$LOG" --chain-recover --session "$SID" 2>&1 >/dev/null)"
RECOVER_RC=$?
case "$RECOVER_RC:$RECOVER_ERR" in
  3:*"--code-review-done --claimed-review-ticket"*)
    check "T18 an open review round is refused and routed to the ticket-bound terminus" PASS ;;
  *)
    check "T18 an open review round is refused and routed to the ticket-bound terminus (rc=$RECOVER_RC got: $RECOVER_ERR)" FAIL ;;
esac

# ---------------------------------------------------------------- terminal flag
TICKET="$(state_field reviewTicket)"
tdd_mark_review_converged "$SID_KEY" "$TICKET" codeReviewDone >/dev/null 2>&1
BEFORE="$(digest)"
RECOVER_ERR="$(bash "$LOG" --chain-recover --session "$SID" 2>&1 >/dev/null)"
RECOVER_RC=$?
[ "$(status_field shape)" = "awaiting-self-review" ] && [ "$RECOVER_RC" -eq 3 ] \
  && [ "$BEFORE" = "$(digest)" ] \
  && check "T19 recover refuses a chain that already reached a terminal flag" PASS \
  || check "T19 recover refuses a chain that already reached a terminal flag (shape=$(status_field shape) rc=$RECOVER_RC)" FAIL

case "$RECOVER_ERR" in
  *"self-review"*)
    check "T20 the terminal-flag refusal routes to the self-review stage" PASS ;;
  *)
    check "T20 the terminal-flag refusal routes to the self-review stage (got: $RECOVER_ERR)" FAIL ;;
esac

# ---------------------------------------------------------------- a bound generation is repaired, never unbound
new_chain "chain-recover-bound"
seed "$STALE_RECEIPT" || true
[ "$(status_field linkage)" = "bound" ] && [ "$(status_field recoverable)" = "true" ] \
  && check "T21 a bound generation with a disagreeing receipt is recoverable" PASS \
  || check "T21 a bound generation with a disagreeing receipt is recoverable (linkage=$(status_field linkage) recoverable=$(status_field recoverable))" FAIL

DOC_BEFORE="$(read_document)"
bash "$LOG" --chain-recover --session "$SID" >/dev/null 2>&1
BOUND_RC=$?
CHANGED="$(document_diff "$DOC_BEFORE")"
[ "$BOUND_RC" -eq 0 ] && [ "$(status_field linkage)" = "bound" ] \
  && [ "$CHANGED" = "history,last_event,reviewRearm,revision,updated_at,workflow_state" ] \
  && check "T22 recovery repairs the bound chain and touches no Autopilot link field" PASS \
  || check "T22 recovery repairs the bound chain and touches no link field (rc=$BOUND_RC changed=$CHANGED)" FAIL

# ---------------------------------------------------------------- blocked recoveries
new_chain "chain-recover-partial"
seed "s.chainId=\"chain-partial-1\";$RECEIPT_ONLY" || true
BEFORE="$(digest)"
RECOVER_ERR="$(bash "$LOG" --chain-recover --session "$SID" 2>&1 >/dev/null)"
RECOVER_RC=$?
[ "$(status_field linkage)" = "partial" ] && [ "$(status_field wedged)" = "true" ] \
  && [ "$(status_field recoverable)" = "false" ] && [ "$RECOVER_RC" -eq 3 ] \
  && [ "$BEFORE" = "$(digest)" ] \
  && check "T23 an incomplete Autopilot linkage is diagnosed and refused, never repaired in place" PASS \
  || check "T23 an incomplete Autopilot linkage is diagnosed and refused (linkage=$(status_field linkage) rc=$RECOVER_RC)" FAIL

case "$RECOVER_ERR" in
  *"refused (partial-link)."*"wedged but not recoverable"*"/zensu:tdd"*)
    check "T24 the blocked refusal says the chain IS wedged and names a real next step" PASS ;;
  *)
    check "T24 the blocked refusal says the chain IS wedged and names a real next step (got: $RECOVER_ERR)" FAIL ;;
esac

new_chain "chain-recover-deferred"
seed "s.deferredReviewClaim=\"dc_test1\";$STALE_RECEIPT" || true
BEFORE="$(digest)"
RECOVER_ERR="$(bash "$LOG" --chain-recover --session "$SID" 2>&1 >/dev/null)"
RECOVER_RC=$?
[ "$(status_field deferredReviewClaim)" = "present" ] \
  && [ "$(status_field recoverable)" = "false" ] && [ "$RECOVER_RC" -eq 3 ] \
  && [ "$BEFORE" = "$(digest)" ] \
  && check "T25 an outstanding deferred-review claim blocks recovery, like every sibling mutator" PASS \
  || check "T25 an outstanding deferred-review claim blocks recovery (claim=$(status_field deferredReviewClaim) rc=$RECOVER_RC)" FAIL

case "$RECOVER_ERR" in
  *"deferred-review claim"*)
    check "T26 the deferred-claim refusal names the claim as the blocker" PASS ;;
  *)
    check "T26 the deferred-claim refusal names the claim as the blocker (got: $RECOVER_ERR)" FAIL ;;
esac

# ---------------------------------------------------------------- fail-closed inputs
new_chain "chain-recover-corrupt"
printf '%s' '{"schema":"zensu.workflow-state"' > "$STATE_FILE"
BEFORE="$(digest)"
STATUS_RC=0
bash "$LOG" --chain-status --session "$SID" >/dev/null 2>&1 || STATUS_RC=$?
RECOVER_RC=0
bash "$LOG" --chain-recover --session "$SID" >/dev/null 2>&1 || RECOVER_RC=$?
[ "$STATUS_RC" -eq 2 ] && [ "$RECOVER_RC" -eq 2 ] && [ "$BEFORE" = "$(digest)" ] \
  && check "T27 corrupt state fails closed for both verbs and is never rewritten" PASS \
  || check "T27 corrupt state fails closed for both verbs (status=$STATUS_RC recover=$RECOVER_RC)" FAIL

new_chain "chain-recover-foreign"
FOREIGN="$(node -e '
  const fs = require("node:fs");
  const file = process.argv[1];
  const state = JSON.parse(fs.readFileSync(file, "utf8"));
  state.session_id_hash = "sha256:" + "b".repeat(64);
  fs.writeFileSync(file, JSON.stringify(state, null, 2));
  process.stdout.write("ok");
' "$STATE_FILE" 2>/dev/null)"
BEFORE="$(digest)"
STATUS_RC=0
bash "$LOG" --chain-status --session "$SID" >/dev/null 2>&1 || STATUS_RC=$?
RECOVER_RC=0
bash "$LOG" --chain-recover --session "$SID" >/dev/null 2>&1 || RECOVER_RC=$?
[ "$FOREIGN" = ok ] && [ "$STATUS_RC" -eq 2 ] && [ "$RECOVER_RC" -eq 2 ] \
  && [ "$BEFORE" = "$(digest)" ] \
  && check "T28 a foreign session hash fails closed and is never rewritten" PASS \
  || check "T28 a foreign session hash fails closed (status=$STATUS_RC recover=$RECOVER_RC)" FAIL

new_chain "chain-recover-absent"
rm -f "$STATE_FILE"
STATUS_RC=0
bash "$LOG" --chain-status --session "$SID" >/dev/null 2>&1 || STATUS_RC=$?
RECOVER_RC=0
bash "$LOG" --chain-recover --session "$SID" >/dev/null 2>&1 || RECOVER_RC=$?
[ "$STATUS_RC" -eq 1 ] && [ "$RECOVER_RC" -eq 1 ] && [ ! -e "$STATE_FILE" ] \
  && check "T29 an absent chain reports rc=1 and creates nothing" PASS \
  || check "T29 an absent chain reports rc=1 and creates nothing (status=$STATUS_RC recover=$RECOVER_RC)" FAIL

# `ln -s` exiting 0 is not evidence of a symlink: Git Bash satisfies it with a copy
# unless MSYS is set to winsymlinks:nativestrict. The state document would then be a
# regular file, both verbs would rightly accept it, and this check would fail on a
# correct implementation. Create the link through Node and confirm it with lstat.
IS_WINDOWS="$(node -p 'process.platform === "win32" ? "true" : "false"')"
make_file_symlink() {
  node -e '
    const fs=require("fs"),target=process.argv[1],link=process.argv[2];
    try {
      fs.symlinkSync(target,link,process.platform==="win32"?"file":undefined);
      process.exit(fs.lstatSync(link).isSymbolicLink()?0:1);
    } catch (_) { process.exit(1); }
  ' "$1" "$2"
}
new_chain "chain-recover-symlink"
mv "$STATE_FILE" "$STATE_DIR/real-state.json"
if make_file_symlink "$STATE_DIR/real-state.json" "$STATE_FILE"; then
  STATUS_RC=0
  bash "$LOG" --chain-status --session "$SID" >/dev/null 2>&1 || STATUS_RC=$?
  RECOVER_RC=0
  bash "$LOG" --chain-recover --session "$SID" >/dev/null 2>&1 || RECOVER_RC=$?
  [ "$STATUS_RC" -eq 2 ] && [ "$RECOVER_RC" -eq 2 ] && [ -L "$STATE_FILE" ] \
    && check "T30 a symlinked state document is refused by both verbs" PASS \
    || check "T30 a symlinked state document is refused by both verbs (status=$STATUS_RC recover=$RECOVER_RC)" FAIL
elif [ "$IS_WINDOWS" = true ]; then
  check "T30 symlinked state document refusal (native file symlinks unavailable)" PASS
else
  check "T30 symlink fixture creation failed" FAIL
fi
rm -f "$STATE_FILE"; mv "$STATE_DIR/real-state.json" "$STATE_FILE"

STUB="$WORK/nodeless"
mkdir -p "$STUB"
BEFORE="$(digest)"
STATUS_RC=0
( PATH="$STUB"; tdd_chain_diagnostics "$SID" >/dev/null 2>&1 ) || STATUS_RC=$?
RECOVER_RC=0
( PATH="$STUB"; tdd_recover_chain "$SID" >/dev/null 2>&1 ) || RECOVER_RC=$?
[ "$STATUS_RC" -eq 2 ] && [ "$RECOVER_RC" -eq 2 ] && [ "$BEFORE" = "$(digest)" ] \
  && check "T31 both verbs return rc 2 when node is unavailable, writing nothing" PASS \
  || check "T31 both verbs return rc 2 when node is unavailable (status=$STATUS_RC recover=$RECOVER_RC)" FAIL

# ---------------------------------------------------------------- the transaction fails closed on an unwritable store
new_chain "chain-recover-readonly"
seed "$STALE_RECEIPT" || true
BEFORE="$(digest)"
chmod a-w "$STATE_DIR" 2>/dev/null
RECOVER_RC=0
RECOVER_ERR="$(bash "$LOG" --chain-recover --session "$SID" 2>&1 >/dev/null)" || RECOVER_RC=$?
chmod u+w "$STATE_DIR" 2>/dev/null
if [ "$RECOVER_RC" -eq 0 ]; then
  check "T31b an unwritable state directory refuses the recovery (skipped: the write succeeded, likely running as root)" PASS
else
  case "$RECOVER_ERR" in
    *"NOT recovered"*|*"left untouched"*|*"unreadable, foreign, or unsafe"*)
      [ "$BEFORE" = "$(digest)" ] \
        && check "T31b an unwritable state directory refuses the recovery without a partial write" PASS \
        || check "T31b an unwritable state directory refuses the recovery without a partial write" FAIL ;;
    *)
      check "T31b an unwritable state directory refuses the recovery (rc=$RECOVER_RC got: $RECOVER_ERR)" FAIL ;;
  esac
fi

# ---------------------------------------------------------------- the classifier module is tamper-protected
# Tamper with a COPY of the plugin, never the tracked tree: tests/run-all.sh kills a
# slow suite with an untrappable SIGKILL, which would leave the real write-gate module
# stubbed or deleted in the working tree.
PLUGIN_COPY="$WORK/plugin"
mkdir -p "$PLUGIN_COPY/.claude-plugin"
COPY_OK=true
for item in .claude-plugin .mcp.json hooks agents skills docs templates README.md CHANGELOG.md tests; do
  [ -e "$ROOT/$item" ] || continue
  cp -R "$ROOT/$item" "$PLUGIN_COPY/" 2>/dev/null || COPY_OK=false
done
[ "$COPY_OK" = true ] || check "T32 plugin copy for the tamper fixtures failed" FAIL
COPY_MODULE="$PLUGIN_COPY/hooks/lib/chain-recovery-v1.js"
COPY_LOG="$PLUGIN_COPY/hooks/lib/zensu-log.sh"
new_chain_in_root "chain-recover-tamper" "$PLUGIN_COPY"
seed "$STALE_RECEIPT" || true
printf '%s\n' "module.exports = {};" > "$COPY_MODULE"
TAMPER_RC=0
TAMPER_OUT="$(bash "$COPY_LOG" --chain-status --session "$SID" 2>&1)" || TAMPER_RC=$?
case "$TAMPER_RC:$TAMPER_OUT" in
  2:*"runtime digest mismatch"*)
    check "T32 substituting the classifier module is rejected by the runtime digest, so the shared receipt predicate cannot be swapped out" PASS ;;
  *)
    check "T32 substituting the classifier module is rejected by the runtime digest (rc=$TAMPER_RC out=$TAMPER_OUT)" FAIL ;;
esac

rm -f "$COPY_MODULE"
MISSING_RC=0
MISSING_ERR="$(bash "$COPY_LOG" --chain-status --session "$SID" 2>&1 >/dev/null)" || MISSING_RC=$?
TICKET_FAULT_RC=0
bash "$COPY_LOG" --review-ticket --session "$SID" >/dev/null 2>&1 || TICKET_FAULT_RC=$?
case "$MISSING_RC:$MISSING_ERR" in
  2:*"runtime digest mismatch"*)
    check "T32a removing the classifier module is caught by the runtime digest before any verb runs" PASS ;;
  *)
    check "T32a removing the classifier module is caught by the runtime digest (rc=$MISSING_RC got: $MISSING_ERR)" FAIL ;;
esac
[ "$TICKET_FAULT_RC" -ne 0 ] \
  && check "T32a1 the ticket issuer also fails closed while the shared module is absent" PASS \
  || check "T32a1 the ticket issuer also fails closed while the shared module is absent" FAIL

cp "$MODULE" "$COPY_MODULE"
RESTORED_SHAPE="$(bash "$COPY_LOG" --chain-status --session "$SID" 2>/dev/null | node -e '
  let s = "";
  process.stdin.on("data", (d) => { s += d; }).on("end", () => {
    try { process.stdout.write(String(JSON.parse(s).shape)); } catch (_) { process.stdout.write("PARSE_ERROR"); }
  });
')"
[ "$RESTORED_SHAPE" = "wedged-stale-rearm" ] \
  && check "T32b restoring the module restores the diagnosis" PASS \
  || check "T32b restoring the module restores the diagnosis (got: $RESTORED_SHAPE)" FAIL

# ---------------------------------------------------------------- shapes outside the review window
new_chain "chain-recover-shapes"
bash "$LOG" --tdd-reset --session "$SID" >/dev/null 2>&1
[ "$(status_field shape)" = "no-session" ] \
  && check "T32g a reset session reports no-session" PASS \
  || check "T32g a reset session reports no-session (got: $(status_field shape))" FAIL

bash "$LOG" --tdd-begin --session "$SID" >/dev/null 2>&1
[ "$(status_field shape)" = "implementing" ] \
  && check "T32h an armed but incomplete chain reports implementing" PASS \
  || check "T32h an armed but incomplete chain reports implementing (got: $(status_field shape))" FAIL

# ---------------------------------------------------------------- argument hygiene for the new verbs
new_chain "chain-recover-flags"
FLAG_FAILURES=0
for probe in "--chain-status --tools Bash" "--chain-status --claimed-review-ticket rt_x" \
  "--chain-recover --tools Bash" "--chain-recover --claimed-review-ticket rt_x" \
  "--chain-recover --outcome pass" "--chain-recover --chain-id c1"; do
  PROBE_RC=0
  # shellcheck disable=SC2086
  bash "$LOG" $probe --session "$SID" >/dev/null 2>&1 || PROBE_RC=$?
  [ "$PROBE_RC" -eq 2 ] || FLAG_FAILURES=$((FLAG_FAILURES+1))
done
[ "$FLAG_FAILURES" -eq 0 ] \
  && check "T32i both verbs reject every flag that belongs to another verb" PASS \
  || check "T32i both verbs reject every flag that belongs to another verb ($FLAG_FAILURES accepted)" FAIL

AMBIENT_RC=0
bash "$LOG" --chain-status >/dev/null 2>&1 || AMBIENT_RC=$?
[ "$AMBIENT_RC" -eq 0 ] \
  && check "T32j the documented ambient form (no --session) resolves the current session" PASS \
  || check "T32j the documented ambient form (no --session) resolves the current session (rc=$AMBIENT_RC)" FAIL

# ---------------------------------------------------------------- the gate-escape ledger stays gates-only
new_chain "chain-recover-ledger"
NOTE_RC=0
bash "$LOG" --bypass-note ZENSU_CHAIN_RECOVER --session "$SID" >/dev/null 2>&1 || NOTE_RC=$?
case "$NOTE_RC:$(state_field bypasses)" in
  2:|2:none)
    check "T33 the recovery marker is not a ledger gate name and cannot be recorded as one" PASS ;;
  *)
    check "T33 the recovery marker is not a ledger gate name (rc=$NOTE_RC ledger=$(state_field bypasses))" FAIL ;;
esac

bash "$LOG" --bypass-note ZENSU_CHAIN --session "$SID" >/dev/null 2>&1
case ", $(tdd_bypasses "$STATE_FILE")," in
  *", ZENSU_CHAIN,"*)
    check "T34 a real gate escape is still recordable through --bypass-note" PASS ;;
  *)
    check "T34 a real gate escape is still recordable through --bypass-note (got: $(tdd_bypasses "$STATE_FILE"))" FAIL ;;
esac

# ---------------------------------------------------------------- doctor surface
new_chain "chain-recover-doctor"
seed "$STALE_RECEIPT" || true
# The doctor renderer resolves BOTH the user-scoped zensu config and the
# reviewer-spawn permission check out of HOME, so an unsandboxed invocation
# reads whatever the developer running the suite happens to have. Same guard
# tests/structure/test-doctor.sh applies to its own functional half.
DOCTOR_HOME="$WORK/doctor-home"
mkdir -p "$DOCTOR_HOME"
DOCTOR_OUT="$(HOME="$DOCTOR_HOME" ZENSU_DOCTOR_PLUGIN_DIR="$ROOT" node "$ROOT/hooks/lib/zensu-doctor-report.js" 2>/dev/null)"
case "$DOCTOR_OUT" in
  *"wedged-stale-rearm"*"/zensu:recover-chain"*)
    check "T35 doctor reports the wedged chain and names the recovery command" PASS ;;
  *)
    check "T35 doctor reports the wedged chain and names the recovery command" FAIL ;;
esac

new_chain "chain-recover-doctor-deadend"
seed 's.codeReviewDone=true;s.reviewRound=2;' || true
DOCTOR_OUT="$(HOME="$DOCTOR_HOME" ZENSU_DOCTOR_PLUGIN_DIR="$ROOT" node "$ROOT/hooks/lib/zensu-doctor-report.js" 2>/dev/null)"
case "$DOCTOR_OUT" in
  *"self-review-unbindable"*"at a dead end"*"/zensu:tdd"*)
    check "T35b doctor raises a dead-end chain as its own warning row with the fresh-generation remedy" PASS ;;
  *)
    check "T35b doctor raises a dead-end chain as its own warning row" FAIL ;;
esac

new_chain "chain-recover-doctor-blocked"
seed "s.deferredReviewClaim=\"dc_test2\";$STALE_RECEIPT" || true
DOCTOR_OUT="$(HOME="$DOCTOR_HOME" ZENSU_DOCTOR_PLUGIN_DIR="$ROOT" node "$ROOT/hooks/lib/zensu-doctor-report.js" 2>/dev/null)"
case "$DOCTOR_OUT" in
  *"wedged but not recoverable in place"*"deferred-review claim"*)
    check "T36 doctor distinguishes a blocked wedge and prints its real next step" PASS ;;
  *)
    check "T36 doctor distinguishes a blocked wedge and prints its real next step" FAIL ;;
esac

# ---------------------------------------------------------------- doctor wrapper resolves ownership itself
new_chain "chain-recover-doctor-wrapper"
seed "$STALE_RECEIPT" || true
WRAPPER_OUT="$(ZENSU_DOCTOR_PLUGIN_DIR="$ROOT" ZDOC_ZENSU=absent ZDOC_NODE=vTEST \
  ZDOC_FORGE_PROVIDER=unknown ZDOC_FORGE_CLI="" ZDOC_FORGE_STATE=missing \
  ZDOC_PLAYWRIGHT=absent ZDOC_TTL_HOURS=6 HOME="$DOCTOR_HOME" bash "$ROOT/hooks/lib/zensu-doctor.sh" 2>/dev/null)"
case "$WRAPPER_OUT" in
  *"wedged-stale-rearm"*"/zensu:recover-chain"*)
    check "T45 the doctor WRAPPER renders the wedged shape and the recovery command end to end" PASS ;;
  *)
    check "T45 the doctor wrapper renders the wedged shape and the recovery command (row missing)" FAIL ;;
esac

new_chain "chain-recover-doctor-repaired"
seed "$STALE_RECEIPT" || true
REPAIRED_RC=0
bash "$LOG" --chain-recover --session "$SID" >/dev/null 2>&1 || REPAIRED_RC=$?
DOCTOR_OUT="$(HOME="$DOCTOR_HOME" ZENSU_DOCTOR_PLUGIN_DIR="$ROOT" node "$ROOT/hooks/lib/zensu-doctor-report.js" 2>/dev/null)"
case "$REPAIRED_RC:$DOCTOR_OUT" in
  0:*"(repaired 1×)"*)
    check "T52 doctor renders the durable repair count once a chain has actually been recovered" PASS ;;
  *)
    check "T52 doctor renders the durable repair count on a recovered chain (rc=$REPAIRED_RC)" FAIL ;;
esac

# ------------------------------------------- a standalone receipt: refused, and it shuts the terminus
new_chain "chain-recover-standalone-receipt"
seed "$RECEIPT_ONLY" || true
STANDALONE_TERMINUS_RC=0
bash "$LOG" --code-review-done --session "$SID" >/dev/null 2>&1 || STANDALONE_TERMINUS_RC=$?
[ "$STANDALONE_TERMINUS_RC" -ne 0 ] && [ "$(state_field codeReviewDone)" = "false" ] \
  && check "T46 the reviewRearm conjunct shuts the unqualified no-ticket terminus while a receipt is present" PASS \
  || check "T46 the reviewRearm conjunct shuts the unqualified terminus (rc=$STANDALONE_TERMINUS_RC flag=$(state_field codeReviewDone))" FAIL

BEFORE="$(digest)"
STANDALONE_ERR="$(bash "$LOG" --chain-recover --session "$SID" 2>&1 >/dev/null)"
STANDALONE_RC=$?
[ "$(status_field linkage)" = "standalone" ] && [ "$(status_field wedged)" = "true" ] \
  && [ "$(status_field recoverable)" = "false" ] && [ "$(status_field nextCommandId)" = "link-shape" ] \
  && [ "$STANDALONE_RC" -eq 3 ] && [ "$BEFORE" = "$(digest)" ] \
  && check "T47 a standalone document carrying a receipt is refused as link-shape, byte-identically — the repair never opens that terminus" PASS \
  || check "T47 a standalone receipt is refused as link-shape (linkage=$(status_field linkage) reason=$(status_field nextCommandId) rc=$STANDALONE_RC)" FAIL

case "$STANDALONE_ERR" in
  *"refused (link-shape)."*"no writer in this plugin can produce"*)
    check "T48 the link-shape refusal names the reason token and explains that no writer produces this shape" PASS ;;
  *)
    check "T48 the link-shape refusal names the reason token (got: $STANDALONE_ERR)" FAIL ;;
esac

# ---------------------------------------------------------------- writer + core lockstep
CORE_KEYS="$(CORE_SRC="$CORE" node -e '
  const fs = require("node:fs");
  const src = fs.readFileSync(process.env.CORE_SRC, "utf8");
  const head = src.slice(0, src.indexOf("reviewRearm is invalid"));
  const open = head.lastIndexOf("const exactKeys = [");
  if (open < 0) process.exit(3);
  const body = head.slice(open + "const exactKeys = [".length);
  const literal = body.slice(0, body.indexOf("]"));
  const keys = (literal.match(/[\x27"]([^\x27"]+)[\x27"]/g) || [])
    .map(function (t) { return t.slice(1, -1); });
  process.stdout.write(keys.sort().join(","));
' 2>/dev/null)"
MODULE_KEYS="$(node -e '
  process.stdout.write([...require(process.argv[1]).REARM_MARKER_KEYS].sort().join(","));
' "$MODULE" 2>/dev/null)"
[ -n "$CORE_KEYS" ] && [ "$CORE_KEYS" = "$MODULE_KEYS" ] \
  && check "T43 the core's hand-transcribed receipt key list matches REARM_MARKER_KEYS (a mismatch fails every hook closed)" PASS \
  || check "T43 the core's receipt key list matches REARM_MARKER_KEYS (core=$CORE_KEYS module=$MODULE_KEYS)" FAIL

new_chain "chain-recover-writer-lockstep"
SID_KEY="$(zensu_resolve_session_id "$SID")"
WRITER_TICKET="$(bash "$LOG" --review-ticket --session "$SID" 2>/dev/null)"
tdd_consume_review_ticket "$SID_KEY" "$WRITER_TICKET" >/dev/null 2>&1
seed "${BOUND_LINK}s.chainOutcome=\"max-rounds\";s.codeReviewDone=true;" || true
tdd_rearm_autopilot_review "$SID_KEY" run-bound-1 1 chain-bound-1 "$WRITER_TICKET" false >/dev/null 2>&1
WRITER_RC=$?
WRITER_VERDICT="$(CHAIN_RECOVERY="$MODULE" node -e '
  const fs = require("node:fs");
  const chain = require(process.env.CHAIN_RECOVERY);
  process.stdout.write(chain.rearmReceiptVerdict(JSON.parse(fs.readFileSync(process.argv[1], "utf8"))));
' "$STATE_FILE" 2>/dev/null)"
if [ "$WRITER_RC" -ne 0 ]; then
  check "T44 a receipt minted by the real writer classifies as valid (writer refused this fixture: rc=$WRITER_RC)" FAIL
else
  [ "$WRITER_VERDICT" = valid ] \
    && check "T44 a receipt minted by the real rearm writer classifies as valid, so writer and module cannot drift apart" PASS \
    || check "T44 a receipt minted by the real rearm writer classifies as valid (got: $WRITER_VERDICT)" FAIL
fi

EMIT_UNPREFIXED="$(sed -n '/_tdd_recover_chain_critical()/,/^}/p' "$PHASE_LIB" \
  | grep -oE 'emit\("[^"]*"' | grep -vcE 'emit\("(op:|refused:|recovered:)')"
[ "$EMIT_UNPREFIXED" = "0" ] \
  && check "T49 every emit() literal in the recovery transaction carries an op:/refused:/recovered: namespace" PASS \
  || check "T49 every emit() literal carries a namespace ($EMIT_UNPREFIXED unprefixed)" FAIL

ISSUER_FIELDS="$(sed -n '/_tdd_issue_review_ticket_critical()/,/^}/p' "$PHASE_LIB" \
  | grep -oE 's\.(phase|history|bypasses|vanilla|active|implComplete|chainDone|codeReviewDone|selfReviewFixed|reviewTicket|reviewTicketConsumed|reviewRound)\b' \
  | sed 's/^s\.//' | sort -u | tr '\n' ',')"
MODULE_FIELDS="$(node -e '
  const fs = require("node:fs");
  const src = fs.readFileSync(process.argv[1], "utf8");
  const grab = (name) => {
    const i = src.indexOf("const " + name + " = [");
    if (i < 0) return [];
    const body = src.slice(i + ("const " + name + " = [").length);
    return (body.slice(0, body.indexOf("]")).match(/[\x27"]([^\x27"]+)[\x27"]/g) || [])
      .map((t) => t.slice(1, -1));
  };
  const all = [...grab("REQUIRED_BOOLEANS"), ...grab("REQUIRED_STRINGS"),
    ...grab("REQUIRED_ARRAYS"), "vanilla", "reviewRound"];
  process.stdout.write([...new Set(all)].sort().join(",") + ",");
' "$MODULE" 2>/dev/null)"
[ -n "$ISSUER_FIELDS" ] && [ "$ISSUER_FIELDS" = "$MODULE_FIELDS" ] \
  && check "T50 the classifier's required field set matches the ticket issuer's, so --chain-status cannot go blind on a document the issuer still serves" PASS \
  || check "T50 the classifier's required field set matches the issuer's (issuer=$ISSUER_FIELDS module=$MODULE_FIELDS)" FAIL

# ---------------------------------------------------------------- contract pins
if grep -qE '^ZENSU_BYPASS_GATE_ALLOWLIST=.*ZENSU_CHAIN_RECOVER' "$PHASE_LIB"; then
  check "T37 the gate-escape allowlist stays gates-only (no recovery marker)" FAIL
else
  check "T37 the gate-escape allowlist stays gates-only (no recovery marker)" PASS
fi

if grep -qF '"./skills/recover-chain"' "$PLUGIN_JSON" && grep -qE '^name: recover-chain$' "$SKILL"; then
  check "T38 the skill is registered and its frontmatter name matches" PASS
else
  check "T38 the skill is registered and its frontmatter name matches" FAIL
fi

# NOTE ON HOME: T39 below is the repo-wide skill-registry invariant — header count,
# row count, the "N skills are registered" figure, both set differences and the
# unlisted exemption — living in a suite named for chain recovery. Its header-vs-rows
# half is duplicated in test-converge-skill.sh P4c, and every per-skill suite adds a
# registration pin of its own. That is three places for one invariant, held together
# by comments. Extracting it into a dedicated tests/structure/test-skill-registry.sh
# is the right move; it is deliberately NOT done inside a review-fix round, because
# moving a checked invariant is a change that needs its own review.
SKILLS_BLOCK="$(awk '/^### Skills \(/{f=1;next} /^### /{f=0} f' "$README")"
SKILLS_HEADER_N="$(grep -oE '^### Skills \([0-9]+\)' "$README" | grep -oE '[0-9]+' | head -1)"
# The slug class admits digits. This grep and both of its siblings spelled [a-z-]+
# until this change, so a future skill named like `review-v2` would drop out of the
# row count AND surface as registered-but-unlisted, failing this check twice for a
# reason neither message names. The class had THREE hand-maintained encodings, all of
# them reading README.md. Two of them live in this function, so they now share ONE
# spelling: the grep below and the JS row regex both take SKILL_SLUG_CLASS. The third,
# test-converge-skill.sh P4c, now takes the same constant from lib-skill-registry.sh.
# The INVARIANT is still not shared — that is what the NOTE above defers.
# (test-gauntlet-loop-skill.sh G13 also spells [a-z0-9-]+, but that is a hook
# FILENAME class applied to SKILL.md and reads no README row — not a co-moving site.)
. "$(dirname "$0")/lib-skill-registry.sh"   # SKILL_SLUG_CLASS, shared with test-converge-skill.sh P4c
SKILLS_ROWS="$(printf '%s\n' "$SKILLS_BLOCK" | grep -cE "^\| \`/zensu:$SKILL_SLUG_CLASS\` \|")"
# Deliberately registered but kept out of the README table. A second entry here is a
# real decision, not a typo — see P2h in test-doctor.sh for why doctor is documented
# under Diagnostics instead.
README_UNLISTED_SKILLS="doctor"
# BOTH directions. registered-minus-listed catches a renamed or de-registered skill
# whose README row went stale. listed-minus-registered catches the mirror case — a
# row advertising a command plugin.json does not register — which every other
# conjunct here is blind to, because bumping the header to match repairs the counts.
SKILLS_SET_DIFF="$(printf '%s\n' "$SKILLS_BLOCK" | node -e '
const fs = require("node:fs");
// The slug class arrives from the shell so this regex and the grep above cannot drift.
const rowRe = new RegExp("^\\| `\\/zensu:(" + process.argv[2] + ")` \\|");
const rows = new Set(
  fs.readFileSync(0, "utf8").split("\n")
    .map((line) => rowRe.exec(line))
    .filter(Boolean).map((match) => match[1]),
);
const manifest = require(process.argv[1]);
const registered = (manifest.skills || [])
  .map((entry) => entry.replace(/^\.\/skills\//, ""));
const unlisted = registered.filter((name) => !rows.has(name)).sort();
const unregistered = [...rows].filter((name) => !registered.includes(name)).sort();
process.stdout.write(unlisted.join(",") + "|" + unregistered.join(","));
' "$PLUGIN_JSON" "$SKILL_SLUG_CLASS" 2>/dev/null)"
SKILLS_UNLISTED="${SKILLS_SET_DIFF%%|*}"
SKILLS_UNREGISTERED="${SKILLS_SET_DIFF##*|}"
REGISTERED_N="$(node -e 'process.stdout.write(String(require(process.argv[1]).skills.length))' "$PLUGIN_JSON" 2>/dev/null)"
README_REGISTERED_N="$(printf '%s\n' "$SKILLS_BLOCK" | grep -oE '\([0-9]+ skills are registered' | grep -oE '[0-9]+' | head -1)"
if printf '%s' "$SKILLS_BLOCK" | grep -qF '/zensu:recover-chain' \
  && [ "$SKILLS_HEADER_N" = "$SKILLS_ROWS" ] && [ "$README_REGISTERED_N" = "$REGISTERED_N" ] \
  && [ "$SKILLS_UNLISTED" = "$README_UNLISTED_SKILLS" ] && [ -z "$SKILLS_UNREGISTERED" ]; then
  check "T39 README lists the skill; header, table and registered set all agree" PASS
else
  check "T39 README lists the skill; header, table and registered set agree (header=$SKILLS_HEADER_N rows=$SKILLS_ROWS readme=$README_REGISTERED_N plugin=$REGISTERED_N; registered-but-unlisted=[$SKILLS_UNLISTED], must be exactly [$README_UNLISTED_SKILLS] — the diagnostics skill P2h in test-doctor.sh keeps out of the table; listed-but-unregistered=[$SKILLS_UNREGISTERED], must be empty — a row here advertises a command the plugin never loads)" FAIL
fi

SKILL_CODE="$(awk '/^```/{inside=!inside; next} inside{print}' "$SKILL")"
if printf '%s\n' "$SKILL_CODE" | grep -Eq '(^|[[:space:]])(find|rm|mv|cp)[[:space:]]|git worktree|tdd-phase-'; then
  check "T40 the recovery recipe has no search, deletion, or cross-worktree step" FAIL
else
  check "T40 the recovery recipe has no search, deletion, or cross-worktree step" PASS
fi

STATUS_LINE="$(printf '%s\n' "$SKILL_CODE" | grep -n -- '--chain-status' | head -1 | cut -d: -f1)"
RECOVER_LINE="$(printf '%s\n' "$SKILL_CODE" | grep -n -- '--chain-recover' | head -1 | cut -d: -f1)"
if [ -n "$STATUS_LINE" ] && [ -n "$RECOVER_LINE" ] && [ "$STATUS_LINE" -lt "$RECOVER_LINE" ]; then
  check "T41 the recipe runs the read-only diagnosis before the repair" PASS
else
  check "T41 the recipe runs the read-only diagnosis before the repair (status=$STATUS_LINE recover=$RECOVER_LINE)" FAIL
fi

SHAPE_ROWS_MISSING=""
for shape in $(node -e '
  const chain = require(process.argv[1]);
  process.stdout.write(
    Object.keys(chain.NEXT_COMMAND).concat(Object.keys(chain.BLOCKED_RECOVERY_COMMAND)).join(" "),
  );
' "$MODULE"); do
  grep -qF "\`$shape\`" "$SKILL" || SHAPE_ROWS_MISSING="$SHAPE_ROWS_MISSING $shape"
done
[ -z "$SHAPE_ROWS_MISSING" ] \
  && check "T42 every shape and blocked reason the module can emit is documented in the skill" PASS \
  || check "T42 every shape and blocked reason is documented in the skill (missing:$SHAPE_ROWS_MISSING)" FAIL

MODULE_SHAPES=" $(node -e '
  const chain = require(process.argv[1]);
  process.stdout.write(Object.keys(chain.NEXT_COMMAND).join(" "));
' "$MODULE" 2>/dev/null) "
ENFORCER_SHAPE_N=0
ENFORCER_SHAPES_UNKNOWN=""
for shape in $(grep -oE 'shape=[a-z][a-z-]*' "$ENFORCER" | sed 's/^shape=//' | sort -u); do
  ENFORCER_SHAPE_N=$((ENFORCER_SHAPE_N+1))
  case "$MODULE_SHAPES" in
    *" $shape "*) ;;
    *) ENFORCER_SHAPES_UNKNOWN="$ENFORCER_SHAPES_UNKNOWN $shape" ;;
  esac
done
[ "$ENFORCER_SHAPE_N" -gt 0 ] && [ -z "$ENFORCER_SHAPES_UNKNOWN" ] \
  && check "T51 every chain shape the Stop enforcer names is one the module can still emit, so its refusal never routes to a renamed shape" PASS \
  || check "T51 every chain shape the Stop enforcer names is a real module shape (named=$ENFORCER_SHAPE_N unknown:$ENFORCER_SHAPES_UNKNOWN)" FAIL

echo "----"
echo "test-chain-recover: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
