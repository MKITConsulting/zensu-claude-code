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

# D12 the marker-strip rule has exactly ONE authoritative statement. It used to be
# a hand-copied pair — the durable-begin site restated the action while pointing at
# Phase 0.D only for the CONSEQUENCE, so a model reaching the earlier site had been
# told what to do and had no reason to read on. The earlier copy dropped the
# load-bearing half ("Strip the comment, never the whole line"), which is what keeps
# an unanchored matcher from eating real requirement text out of the plan the user
# is then asked to approve.
D12_RESTATE="$(grep -c 'Strip any pre-existing' "$AUTO" || true)"
D12_RULE="$(grep -c 'Strip the comment, never the whole line' "$AUTO" || true)"
if [ "$D12_RESTATE" -eq 0 ] && [ "$D12_RULE" -eq 1 ]; then
  check "D12 the strip rule is stated once, with its never-the-whole-line bound" PASS
else
  check "D12 strip rule copies (restatements=$D12_RESTATE authoritative=$D12_RULE, want 0/1)" FAIL
fi

# D13 the strip targets the bytes the GATE reads. hooks/plan-approved-delegate.sh
# counts markers in `resolved.plan` — the ExitPlanMode plan CONTENT — while the
# rule used to name the incoming feature description. Those are different
# documents: Phase 0.C turns the description into the spec and the acceptance
# criteria, so a marker carried across while writing them survives a strip of the
# description and the gate still counts two.
if has "$AUTO" 'COMMENT from the plan CONTENT you are about to pass to' \
  && has "$AUTO" 'stripping the incoming feature description is not enough' \
  && ! has "$AUTO" 'COMMENT from the incoming'; then
  check "D13 the strip targets the plan content the gate actually reads" PASS
else
  check "D13 strip target document" FAIL
fi

# D14 the single-marker check is ordered BEFORE the durable begin. --autopilot-begin
# mints the run and takes the working tree; when the strip misses, the gate refuses
# an already-minted run and the recovery is a separate guided command. Presence is
# not enough here — the precondition has to be readable before the command it
# guards, so the line numbers are compared.
D14_PRE="$(grep -n 'Verify FIRST that the plan content you are about to present carries exactly one' "$AUTO" | head -1 | cut -d: -f1)"
D14_BEGIN="$(grep -n -- '--autopilot-begin --run "\$RUN_ID"' "$AUTO" | head -1 | cut -d: -f1)"
if [ -n "$D14_PRE" ] && [ -n "$D14_BEGIN" ] && [ "$D14_PRE" -lt "$D14_BEGIN" ]; then
  check "D14 the single-marker precondition precedes --autopilot-begin" PASS
else
  check "D14 marker precondition ordering (precondition=${D14_PRE:-absent} begin=${D14_BEGIN:-absent})" FAIL
fi

# D15 the wedge the ordering exists to prevent is named with its recovery, so a run
# that mints before the refusal is not left without an exit.
# Both needles occur at more than one site in this file (the release path names the
# command three times), so a whole-file pair would be satisfied by a sibling and
# could not see the deletion it exists to catch. Each site is sliced and graded on
# its own: the durable-begin block, where the precondition is stated, and Phase 0.D,
# where the rule it guards lives.
d15_slice() { # $1 start regex, $2 end regex (exclusive)
  awk -v s="$1" -v e="$2" 'BEGIN{on=0} $0 ~ s {on=1} on && $0 ~ e && !($0 ~ s) {exit} on {print}' "$AUTO"
}
D15_BEGIN="$(d15_slice '^Before presenting the Phase-0 plan' '^A refusal naming a nonterminal run')"
D15_CONFIRM="$(d15_slice '^\*\*0\.D — Confirm\.\*\*' '^## ')"
d15_pair() { printf '%s' "$1" | grep -qF '/zensu:autopilot-release' && printf '%s' "$1" | grep -qF 'already holds the working tree'; }
if [ -z "$D15_BEGIN" ] || [ -z "$D15_CONFIRM" ]; then
  check "D15 slices not extracted (begin=${#D15_BEGIN} confirm=${#D15_CONFIRM} chars)" FAIL
elif d15_pair "$D15_BEGIN" && d15_pair "$D15_CONFIRM"; then
  check "D15 both the durable-begin block and Phase 0.D name the minted-then-refused recovery" PASS
else
  check "D15 minted-then-refused recovery missing from a site" FAIL
fi

echo "----"; echo "test-autopilot-durable-skill: $PASS PASS / $FAIL FAIL"; [ "$FAIL" -eq 0 ]
