#!/bin/bash
# Pins the self-review chain-state flags in hooks/lib/zensu-tdd-phase.sh:
#   codeReviewDone  — code-reviewer chain converged (intermediate terminus)
#   selfReviewFixed — the single self-review fix round has run (latch)
# Both MUST round-trip AND survive a subsequent phase write (a self-review fix
# round writes RED/IMPL/GREEN phase markers; if the phase-critical writer drops
# these flags the Stop-hook would mis-route back to the code-reviewer).
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PHASE_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

STATE_DIR="$(mktemp -d)"; export STATE_DIR
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PROJECT_DIR="$STATE_DIR"
export ZENSU_TEST_PLUGIN_DATA="$STATE_DIR/plugin-data"
cleanup() { rm -rf "$STATE_DIR"; }
trap cleanup EXIT

# Establish the same immutable context and revision-one workflow baseline that
# production receives from SessionStart.
# shellcheck disable=SC1091
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" flags-test

# shellcheck disable=SC1090
source "$PHASE_LIB"

SID="flags-test"
SF="$(tdd_state_file "$SID")"

if declare -f tdd_code_review_done >/dev/null 2>&1; then
  check "F1 tdd_code_review_done accessor defined" PASS
else
  check "F1 tdd_code_review_done accessor defined" FAIL
fi
if declare -f tdd_self_review_fixed >/dev/null 2>&1; then
  check "F2 tdd_self_review_fixed accessor defined" PASS
else
  check "F2 tdd_self_review_fixed accessor defined" FAIL
fi

[ "$(tdd_code_review_done "$SF")" = "false" ] && check "F3 codeReviewDone default false (no state file)" PASS || check "F3 codeReviewDone default false" FAIL
[ "$(tdd_self_review_fixed "$SF")" = "false" ] && check "F4 selfReviewFixed default false (no state file)" PASS || check "F4 selfReviewFixed default false" FAIL

tdd_set_flag "$SID" codeReviewDone true
tdd_set_flag "$SID" selfReviewFixed true
[ "$(tdd_code_review_done "$SF")" = "true" ] && check "F5 codeReviewDone set->true round-trip" PASS || check "F5 codeReviewDone set->true" FAIL
[ "$(tdd_self_review_fixed "$SF")" = "true" ] && check "F6 selfReviewFixed set->true round-trip" PASS || check "F6 selfReviewFixed set->true" FAIL

# The real regression: a phase write must PRESERVE the new flags.
tdd_write_phase "$SID" S1 RED_WRITE ""
[ "$(tdd_code_review_done "$SF")" = "true" ] && check "F7 codeReviewDone survives a phase write" PASS || check "F7 codeReviewDone survives phase write" FAIL
[ "$(tdd_self_review_fixed "$SF")" = "true" ] && check "F8 selfReviewFixed survives a phase write" PASS || check "F8 selfReviewFixed survives phase write" FAIL

# Existing flag still preserved across a phase write (no regression).
tdd_set_flag "$SID" chainDone true
tdd_write_phase "$SID" S1 IMPL ""
[ "$(tdd_chain_done "$SF")" = "true" ] && check "F9 chainDone still preserved across phase write" PASS || check "F9 chainDone preserved" FAIL

# A full session reset clears the new flags too.
tdd_clear_session "$SID"
[ "$(tdd_code_review_done "$SF")" = "false" ] && check "F10 reset clears codeReviewDone" PASS || check "F10 reset clears codeReviewDone" FAIL
[ "$(tdd_self_review_fixed "$SF")" = "false" ] && check "F11 reset clears selfReviewFixed" PASS || check "F11 reset clears selfReviewFixed" FAIL

echo "----"
echo "test-self-review-flags: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
