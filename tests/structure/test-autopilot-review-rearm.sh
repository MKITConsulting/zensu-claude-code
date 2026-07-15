#!/bin/bash
# Generation-bound review-budget rearm and retirement contracts.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PHASE="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"

PASS=0; FAIL=0
check() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

if [ ! -f "$PHASE" ]; then
  check "A1 TDD phase library exists" FAIL
  exit 1
fi
# shellcheck disable=SC1090
source "$PHASE"

ROOT="$(mktemp -d -t zensu-autopilot-rearm-XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PROJECT_DIR="$ROOT/project"
export TDD_STATE_DIR="$ROOT/state"
export CLAUDE_PLUGIN_DATA_OVERRIDE="$ROOT/state"
mkdir -p "$CLAUDE_PROJECT_DIR" "$TDD_STATE_DIR"

state_file() { tdd_state_file "$1"; }
counter_file() { printf '%s/rounds-%s.json\n' "$TDD_STATE_DIR" "$1"; }
stop_file() { printf '%s.stopblocks\n' "$(state_file "$1")"; }
digest() { shasum -a 256 "$1" | awk '{print $1}'; }
field_ok() {
  FILE="$1" EXPR="$2" node -e '
    const value = require(process.env.FILE);
    process.exit(Function("value", `return Boolean(${process.env.EXPR})`)(value) ? 0 : 1);
  ' 2>/dev/null
}

seed_max_rounds() {
  local sid="$1" run="$2" attempt="$3" chain="$4" terminal="$5" ticket
  tdd_begin_session "$sid" true false false "" "$run" "$attempt" GATES "$chain" >/dev/null || return 1
  tdd_set_flag "$sid" implComplete true >/dev/null || return 1
  ticket="$(tdd_issue_review_ticket "$sid")" || return 1
  tdd_consume_review_ticket "$sid" "$ticket" "$(counter_file "$sid")" >/dev/null || return 1
  tdd_set_chain_outcome "$sid" max-rounds "$run" "$attempt" "$chain" "$ticket" >/dev/null || return 1
  if [ "$terminal" = true ]; then
    tdd_finish_autopilot_chain "$sid" "$run" "$attempt" "$chain" max-rounds "$ticket" >/dev/null || return 1
  else
    tdd_mark_review_converged "$sid" "$ticket" codeReviewDone >/dev/null || return 1
  fi
  printf '%s\n' "$ticket"
}

seed_standalone_rearm() {
  local sid="$1" ticket
  tdd_begin_session "$sid" true >/dev/null || return 1
  tdd_set_flag "$sid" implComplete true >/dev/null || return 1
  ticket="$(tdd_issue_review_ticket "$sid")" || return 1
  tdd_consume_review_ticket "$sid" "$ticket" "$(counter_file "$sid")" >/dev/null || return 1
  tdd_mark_review_converged "$sid" "$ticket" codeReviewDone >/dev/null || return 1
  printf '%s\n' "$ticket"
}

check "A1 TDD phase library exists" PASS

# The legacy current-session transition is strictly standalone and remains
# single-use. It must not create a lone chainOutcome field while re-arming.
S1=normal-rearm-session
T1="$(seed_standalone_rearm "$S1")"
if tdd_rearm_review "$S1" "$T1" \
  && field_ok "$(state_file "$S1")" 'value.chainOutcome === undefined && value.chainDone === false && value.codeReviewDone === false' \
  && ! tdd_rearm_review "$S1" "$T1" >/dev/null 2>&1; then
  check "A2 normal rearm clears max-rounds and remains single-use" PASS
else
  check "A2 normal rearm clears max-rounds and remains single-use" FAIL
fi

# Wrong tickets and every wrong binding dimension are byte-stable CAS rejects.
S2=bound-rearm-session; R2=bound_rearm_run; C2=bound-rearm-chain
T2="$(seed_max_rounds "$S2" "$R2" 2 "$C2" false)"
SF2="$(state_file "$S2")"
printf '%s\n' '{"count":99}' > "$(counter_file "$S2")"
printf '%s\n' 99 > "$(stop_file "$S2")"
BEFORE_WRONG="$(digest "$SF2")"
WRONG_OK=true
tdd_rearm_autopilot_review wrong-session "$R2" 2 "$C2" "$T2" false >/dev/null 2>&1 && WRONG_OK=false
tdd_rearm_autopilot_review ../wrong-session "$R2" 2 "$C2" "$T2" false >/dev/null 2>&1 && WRONG_OK=false
tdd_rearm_autopilot_review "$S2" "$R2" 2 "$C2" rt_00000000000000000000000000000000 false >/dev/null 2>&1 && WRONG_OK=false
tdd_rearm_autopilot_review "$S2" wrong_run 2 "$C2" "$T2" false >/dev/null 2>&1 && WRONG_OK=false
tdd_rearm_autopilot_review "$S2" "$R2" 3 "$C2" "$T2" false >/dev/null 2>&1 && WRONG_OK=false
tdd_rearm_autopilot_review "$S2" "$R2" 2 wrong_chain "$T2" false >/dev/null 2>&1 && WRONG_OK=false
if [ "$WRONG_OK" = true ] && [ "$(digest "$SF2")" = "$BEFORE_WRONG" ] \
  && [ -e "$(counter_file "$S2")" ] && [ -e "$(stop_file "$S2")" ]; then
  check "A3 bound rearm rejects wrong ticket or binding without mutation" PASS
else
  check "A3 bound rearm rejects wrong ticket or binding without mutation" FAIL
fi

if tdd_rearm_autopilot_review "$S2" "$R2" 2 "$C2" "$T2" \
  && field_ok "$SF2" 'value.active === true && value.implComplete === true && value.chainOutcome === "" && value.chainDone === false && value.codeReviewDone === false && value.selfReviewFixed === false && value.reviewTicket === "" && value.reviewTicketConsumed === true && value.reviewRound === 0 && value.stopBlockCount === 0 && value.reviewRearm && Object.keys(value.reviewRearm).sort().join(",") === "attempt,chainId,consumedTicketSha256,retire,runId,schemaVersion,status" && value.reviewRearm.schemaVersion === 1 && value.reviewRearm.status === "pending" && value.reviewRearm.runId === "bound_rearm_run" && value.reviewRearm.attempt === 2 && value.reviewRearm.chainId === "bound-rearm-chain" && /^[a-f0-9]{64}$/.test(value.reviewRearm.consumedTicketSha256) && value.reviewRearm.retire === false' \
  && [ ! -e "$(counter_file "$S2")" ] && [ ! -e "$(stop_file "$S2")" ]; then
  check "A4 exact bound rearm clears outcome, flags, and derived budgets" PASS
else
  check "A4 exact bound rearm clears outcome, flags, and derived budgets" FAIL
fi

BEFORE_RETRY="$(digest "$SF2")"
printf '%s\n' '{"count":7}' > "$(counter_file "$S2")"
printf '%s\n' 7 > "$(stop_file "$S2")"
if tdd_rearm_autopilot_review "$S2" "$R2" 2 "$C2" "$T2" \
  && [ "$(digest "$SF2")" = "$BEFORE_RETRY" ] \
  && [ ! -e "$(counter_file "$S2")" ] && [ ! -e "$(stop_file "$S2")" ] \
  && ! tdd_rearm_autopilot_review "$S2" "$R2" 2 "$C2" "$T2" true >/dev/null 2>&1 \
  && [ "$(digest "$SF2")" = "$BEFORE_RETRY" ]; then
  check "A5 only the exact receipt-bound crash retry is an idempotent no-op" PASS
else
  check "A5 only the exact receipt-bound crash retry is an idempotent no-op" FAIL
fi

if tdd_issue_review_ticket "$S2" >/dev/null \
  && field_ok "$SF2" 'value.reviewRearm === undefined && value.reviewTicketConsumed === false'; then
  check "A5a forward review progress consumes the crash-retry receipt" PASS
else
  check "A5a forward review progress consumes the crash-retry receipt" FAIL
fi

# Strict receipt validation fails closed: an extra key cannot be interpreted as
# a compatible receipt even when every visible binding field still matches.
S2B=strict-marker-session; R2B=strict_marker_run; C2B=strict-marker-chain
T2B="$(seed_max_rounds "$S2B" "$R2B" 6 "$C2B" false)"
SF2B="$(state_file "$S2B")"
tdd_rearm_autopilot_review "$S2B" "$R2B" 6 "$C2B" "$T2B" false >/dev/null || true
STATE_FILE="$SF2B" node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8"));
  s.reviewRearm.unexpected = true;
  fs.writeFileSync(process.env.STATE_FILE, JSON.stringify(s, null, 2));
'
STRICT_BEFORE="$(digest "$SF2B")"
if ! tdd_rearm_autopilot_review "$S2B" "$R2B" 6 "$C2B" "$T2B" false >/dev/null 2>&1 \
  && ! tdd_issue_review_ticket "$S2B" >/dev/null 2>&1 \
  && [ "$(digest "$SF2B")" = "$STRICT_BEFORE" ]; then
  check "A5b malformed receipt blocks retry and forward progress byte-stably" PASS
else
  check "A5b malformed receipt blocks retry and forward progress byte-stably" FAIL
fi

# Once the Outer state is already TDD_MAX_ROUNDS BLOCKED, retirement makes the
# old Inner generation inactive. RESUME must therefore create a new bound TDD
# attempt instead of silently continuing the exhausted chain.
S3=retire-session; R3=retire_run; C3=retire-chain
T3="$(seed_max_rounds "$S3" "$R3" 3 "$C3" true)"
SF3="$(state_file "$S3")"
printf '%s\n' '{"count":5}' > "$(counter_file "$S3")"
printf '%s\n' 5 > "$(stop_file "$S3")"
if tdd_rearm_autopilot_review "$S3" "$R3" 3 "$C3" "$T3" true \
  && field_ok "$SF3" 'value.active === false && value.implComplete === false && value.chainDone === false && value.chainOutcome === "" && value.reviewRearm.status === "pending" && value.reviewRearm.retire === true' \
  && [ ! -e "$(counter_file "$S3")" ] && [ ! -e "$(stop_file "$S3")" ]; then
  check "A6 retire=true retires the exhausted Inner generation" PASS
else
  check "A6 retire=true retires the exhausted Inner generation" FAIL
fi

RETIRED_DIGEST="$(digest "$SF3")"
if tdd_rearm_autopilot_review "$S3" "$R3" 3 "$C3" "$T3" true \
  && [ "$(digest "$SF3")" = "$RETIRED_DIGEST" ] \
  && tdd_begin_session "$S3" true false false "" "$R3" 4 GATES retire-chain-next \
  && field_ok "$SF3" 'value.active === true && value.autopilotAttempt === 4 && value.chainId === "retire-chain-next" && value.reviewRearm === undefined'; then
  check "A7 retired exact retry is stable and next begin clears its receipt" PASS
else
  check "A7 retired exact retry is stable and next begin clears its receipt" FAIL
fi

# Both generic reset paths must remove a receipt rather than carrying a prior
# capability proof into another chain generation.
S4=marker-clear-session; R4=marker_clear_run; C4=marker-clear-chain
T4="$(seed_max_rounds "$S4" "$R4" 4 "$C4" false)"
SF4="$(state_file "$S4")"
RESET_CLEARED=false
if tdd_rearm_autopilot_review "$S4" "$R4" 4 "$C4" "$T4" false >/dev/null \
  && field_ok "$SF4" 'value.reviewRearm !== undefined' \
  && tdd_reset_chain_flags "$S4" >/dev/null \
  && field_ok "$SF4" 'value.reviewRearm === undefined'; then
  RESET_CLEARED=true
fi

S5=marker-full-clear; R5=marker_full_clear_run; C5=marker-full-clear-chain
T5="$(seed_max_rounds "$S5" "$R5" 5 "$C5" false)"
SF5="$(state_file "$S5")"
if [ "$RESET_CLEARED" = true ] \
  && tdd_rearm_autopilot_review "$S5" "$R5" 5 "$C5" "$T5" false >/dev/null \
  && field_ok "$SF5" 'value.reviewRearm !== undefined' \
  && tdd_clear_session "$S5" >/dev/null \
  && field_ok "$SF5" 'value.reviewRearm === undefined'; then
  check "A8 chain reset and full clear remove the rearm receipt" PASS
else
  check "A8 chain reset and full clear remove the rearm receipt" FAIL
fi

printf '%s\n' "----" "test-autopilot-review-rearm: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
