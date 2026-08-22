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
# D2a the marker is bound to the plan CONTENT, not to a tool argument. The gate
# matches it in the bytes the harness hands back, so a marker written anywhere
# else — a side file, an ExitPlanMode argument the schema strips — never reaches
# it and every run dies at its single planning gate. This is the operator-facing
# half of the source table in CLAUDE.md; it must move with it.
# Every literal below is line-local on purpose: the surrounding sentence wraps,
# and a phrase that crosses the break can never match a line-oriented grep.
has "$AUTO" 'plan CONTENT you pass to `ExitPlanMode`' \
  && has "$AUTO" 'file it was not given' \
  && has "$AUTO" 'the marker has to travel inside the plan itself' \
  && has "$AUTO" 'the plan content you pass to `ExitPlanMode`' \
  && check "D2a the marker is bound to the plan content, not to a tool argument" PASS \
  || check "D2a marker placement guidance" FAIL
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
has "$TDD" '--tdd-complete --plan {plan_file} --autopilot-run "$RUN_ID" --autopilot-attempt "$ATTEMPT" --chain-id "$CHAIN_ID"' \
  && has "$TDD" '--chain-done --autopilot-run "$RUN_ID" --autopilot-attempt "$ATTEMPT" --chain-id "$CHAIN_ID"' \
  && check "D9 bound TDD completion and terminus preserve exact generation" PASS \
  || check "D9 exact bound completion/terminus" FAIL
has "$TDD" 'zensu-log.sh" --tdd-complete --plan {plan_file}`' \
  && check "D9b the standalone completion spelling carries --plan too" PASS \
  || check "D9b standalone --plan spelling" FAIL
# D9/D9b are whole-file `grep -qF` presence pins, and `--tdd-complete` is spelled on
# several lines of this skill — the mandatory command protocol AND Phase 6 step 10.1
# both carry both variants. So EITHER site could lose `--plan` while both checks stay
# green, and step 10.1 is the one the model actually executes at completion time; a
# regression there routes every chain through the weaker derived channel silently.
# Assert the PROPERTY instead of a count: no invocation anywhere may omit the flag.
# A count would be its own trap — the literal legitimately appears more than twice.
if grep -oE 'zensu-log\.sh" --tdd-complete[^`]*' "$TDD" | grep -qv -- '--plan {plan_file}'; then
  check "D9c every --tdd-complete invocation in the skill carries --plan" FAIL
else
  # An empty haystack would satisfy the absence above for the wrong reason, so the
  # anchor's own presence is established first — the vacuity this repo has hit before.
  if [ "$(grep -cE 'zensu-log\.sh" --tdd-complete' "$TDD")" -ge 2 ]; then
    check "D9c every --tdd-complete invocation in the skill carries --plan" PASS
  else
    check "D9c the --tdd-complete anchor this check greps still exists" FAIL
  fi
fi
has "$TDD" 'Standalone chains keep the unqualified commands' \
  && check "D10 standalone TDD completion protocol remains unchanged" PASS \
  || check "D10 standalone completion unchanged" FAIL
has "$TDD" '--chain-id "$CHAIN_ID" --outcome no-changes' \
  && has "$TDD" "never let the helper's normal \`pass\` default mislabel that receipt" \
  && check "D11 bound zero-change path records no-changes explicitly" PASS \
  || check "D11 exact bound zero-change outcome" FAIL

echo "----"; echo "test-autopilot-durable-skill: $PASS PASS / $FAIL FAIL"; [ "$FAIL" -eq 0 ]
