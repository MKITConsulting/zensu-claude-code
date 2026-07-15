#!/bin/bash
# Pin the prompt-level half of the durable outer/inner orchestration contract.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AUTO="$ROOT/skills/autopilot/SKILL.md"; TDD="$ROOT/skills/tdd/SKILL.md"
PASS=0; FAIL=0
check() { if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }
has() { grep -qF -- "$2" "$1"; }

has "$AUTO" '--autopilot-begin --run "$RUN_ID"' && check "D1 Autopilot begins durable state before approval" PASS || check "D1 durable begin" FAIL
has "$AUTO" '<!-- zensu-autopilot:<RUN_ID> -->' && check "D2 approved plan carries an exact run marker" PASS || check "D2 plan marker" FAIL
has "$AUTO" 'AUTOPILOT-RUN: <RUN_ID>' && check "D3 delegated TDD carries explicit run context" PASS || check "D3 delegated context" FAIL
has "$AUTO" '--autopilot-event --run "$RUN_ID"' && has "$AUTO" '--autopilot-status' \
  && check "D4 lifecycle uses the closed state API" PASS || check "D4 closed state API" FAIL
has "$AUTO" 'PR_OPEN_REQUESTED' && has "$AUTO" 'TEAM_REVIEW_REQUESTED' \
  && check "D5 remote effects have write-ahead request events" PASS || check "D5 write-ahead events" FAIL
grep -qiF -- 'Only `DONE`, `BLOCKED`, and' "$AUTO" && grep -qF -- '`CANCELLED` permit the top-level task to stop' "$AUTO" \
  && check "D6 only outer terminals permit Stop" PASS || check "D6 terminal rule" FAIL
has "$TDD" 'AUTOPILOT-RUN: <runId>' && has "$TDD" '--autopilot-return-stage <returnStage>' \
  && has "$TDD" 'Never follow a delegated begin with the standalone form' \
  && check "D7 TDD preserves exact outer linkage" PASS || check "D7 bound TDD begin" FAIL
if grep -qF 'auto-merge' "$AUTO" && grep -qF 'auto-deploy' "$AUTO"; then check "D8 durable protocol retains no-merge/deploy boundary" PASS; else check "D8 no merge/deploy" FAIL; fi
has "$TDD" '--tdd-complete --autopilot-run "$RUN_ID" --autopilot-attempt "$ATTEMPT" --chain-id "$CHAIN_ID"' \
  && has "$TDD" '--chain-done --autopilot-run "$RUN_ID" --autopilot-attempt "$ATTEMPT" --chain-id "$CHAIN_ID"' \
  && check "D9 bound TDD completion and terminus preserve exact generation" PASS \
  || check "D9 exact bound completion/terminus" FAIL
has "$TDD" 'Standalone chains keep the unqualified commands' \
  && check "D10 standalone TDD completion protocol remains unchanged" PASS \
  || check "D10 standalone completion unchanged" FAIL
has "$TDD" '--chain-id "$CHAIN_ID" --outcome no-changes' \
  && has "$TDD" "never let the helper's normal \`pass\` default mislabel that receipt" \
  && check "D11 bound zero-change path records no-changes explicitly" PASS \
  || check "D11 exact bound zero-change outcome" FAIL

echo "----"; echo "test-autopilot-durable-skill: $PASS PASS / $FAIL FAIL"; [ "$FAIL" -eq 0 ]
