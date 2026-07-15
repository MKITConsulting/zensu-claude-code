#!/bin/bash
# Pins the parallel review fan-out wiring in the /zensu:tdd review chain:
#   skills/tdd/SKILL.md Phase 6.10 spawns 5 zensu:review-aspect agents in ONE parallel
#   batch, merges their findings in-thread, then spawns ONE thin zensu:code-reviewer in
#   "fan-out consume mode" (marker: PRE-MERGED FINDINGS (fan-out)) so the existing
#   post-review hook fires exactly once per round and the downstream chain is unchanged.
#   agents/code-reviewer.md carries the consume-mode branch that short-circuits Phases 1-4.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_MD="$PLUGIN_DIR/skills/tdd/SKILL.md"
REVIEWER_MD="$PLUGIN_DIR/agents/code-reviewer.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$SKILL_MD" "$REVIEWER_MD"; do
  if [ ! -f "$f" ]; then
    check "F0 required file exists: $f" FAIL
    echo "----"
    echo "test-tdd-skill-review-fanout: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "F0 skill + code-reviewer files exist" PASS

# --- skills/tdd/SKILL.md Phase 6.10: fan-out -> merge -> thin spawn ---

grep -qF 'zensu:review-aspect' "$SKILL_MD" \
  && check "F1 skill spawns zensu:review-aspect aspects" PASS || check "F1 review-aspect spawn" FAIL

# Five aspects, in a single parallel batch.
grep -qiE 'five|5).{0,40}(review-aspect|aspect)|(review-aspect|aspect).{0,40}(five|5)' "$SKILL_MD" \
  && check "F2 skill fans out the five perspectives" PASS || check "F2 five perspectives" FAIL
grep -qiE 'parallel batch|in parallel|one parallel' "$SKILL_MD" \
  && check "F3 skill spawns the aspects in parallel" PASS || check "F3 parallel batch" FAIL

# In-thread merge (dedupe + sort by severity).
grep -qiE 'merge' "$SKILL_MD" \
  && check "F4 skill merges aspect findings in-thread" PASS || check "F4 merge step" FAIL
grep -qiE 'dedup|sort.{0,20}severity|by severity' "$SKILL_MD" \
  && check "F5 skill dedupes / sorts merged findings by severity" PASS || check "F5 dedupe/sort" FAIL

# Thin consume-mode code-reviewer spawn carrying the exact two-line header and a
# fresh one-shot ticket, single hook event per round.
grep -qF 'PRE-MERGED FINDINGS (fan-out)' "$SKILL_MD" \
  && check "F6 skill passes the 'PRE-MERGED FINDINGS (fan-out)' marker" PASS || check "F6 fan-out marker in skill" FAIL
if grep -qF -- '--review-ticket' "$SKILL_MD" \
  && grep -qF 'second `REVIEW-TICKET: ${REVIEW_TICKET}`' "$SKILL_MD" \
  && grep -qF 'Issue a fresh ticket before EVERY verification spawn' "$SKILL_MD"; then
  check "F6a skill requires an exact second-line fresh review ticket" PASS
else
  check "F6a skill requires an exact second-line fresh review ticket" FAIL
fi
if grep -qF 'ZENSU-DELEGATED-CALLER: autopilot' "$SKILL_MD" \
  && grep -qF 'AUTOPILOT-BINDING: run=${RUN_ID} attempt=${ATTEMPT} chain=${CHAIN_ID}' "$SKILL_MD" \
  && grep -qF 'AUTOPILOT-STAGE: ${RETURN_STAGE}' "$SKILL_MD" \
  && grep -qiE 'each (official )?(envelope )?line exactly once|three.{0,30}lines exactly once' "$SKILL_MD"; then
  check "F6b bound reviewer prompt carries the official three-line envelope exactly once" PASS
else
  check "F6b official exact-once bound reviewer envelope" FAIL
fi
if grep -qiE 'partial.{0,40}duplicate.{0,40}(conflict|mismatch)|duplicate.{0,40}partial.{0,40}(conflict|mismatch)' "$SKILL_MD" \
  && grep -qiE 'standalone.{0,50}(omit|no|without).{0,30}(envelope|ZENSU-DELEGATED-CALLER)' "$SKILL_MD"; then
  check "F6c delegated envelope fails closed while standalone stays envelope-free" PASS
else
  check "F6c strict delegated/standalone envelope boundary" FAIL
fi
grep -qF "subagent_type='zensu:code-reviewer'" "$SKILL_MD" \
  && check "F7 skill still spawns zensu:code-reviewer (hook trigger preserved)" PASS || check "F7 code-reviewer spawn preserved" FAIL

# Once Autopilot has crossed its single planning gate, the delegated TDD chain
# may report a durable BLOCK but may not open a second interactive decision.
UNQUALIFIED_ASKS="$(SKILL_MD="$SKILL_MD" node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.env.SKILL_MD, "utf8").split(/\r?\n/);
  const interactive = /AskUserQuestion|ask (?:the )?user|ask again|ask anyway|always asks|pause and wait|escalate to (?:the )?user/i;
  const qualified = /standalone/i;
  const planGate = /plan-approval hook/i;
  const prohibition = /(?:do not|never|without)\b.*\bask/i;
  lines.forEach((line, index) => {
    if (interactive.test(line) && !qualified.test(line) && !planGate.test(line) && !prohibition.test(line)) {
      process.stdout.write(`${index + 1}:${line}\n`);
    }
  });
')"
TDD_BLOCK_CODES=(
  'coverage-tool-decision-required'
  'precondition-decision-required'
  'tdd-retry-limit'
  'coverage-threshold-decision-required'
)
TDD_NO_ASK=true
for code in "${TDD_BLOCK_CODES[@]}"; do
  grep -qF -- "$code" "$SKILL_MD" || TDD_NO_ASK=false
done
if [ -z "$UNQUALIFIED_ASKS" ] \
   && [ "$TDD_NO_ASK" = true ] \
   && grep -qF -- 'persist `BLOCK`' "$SKILL_MD" \
   && grep -qF -- 'Autopilot has exactly one interactive gate' "$SKILL_MD"; then
  check "F7a delegated TDD reports durable blockers without opening another question" PASS
else
  [ -z "$UNQUALIFIED_ASKS" ] || printf '%s\n' "$UNQUALIFIED_ASKS" >&2
  check "F7a delegated TDD reports durable blockers without opening another question" FAIL
fi

# Explicit carve-out to the line-18 "NO parallel tool batches" rule.
grep -qiE 'sanctioned parallel batch|ONE (sanctioned|allowed) parallel|exception.{0,40}parallel|fan-out is the (one|only)' "$SKILL_MD" \
  && check "F8 skill carves out the review fan-out from the no-parallel rule" PASS || check "F8 parallel carve-out" FAIL

# --- agents/code-reviewer.md: fan-out consume mode ---

grep -qF 'PRE-MERGED FINDINGS (fan-out)' "$REVIEWER_MD" \
  && check "F9 code-reviewer carries the 'PRE-MERGED FINDINGS (fan-out)' marker" PASS || check "F9 fan-out marker in reviewer" FAIL
grep -qiE 'consume mode|fan-out consume' "$REVIEWER_MD" \
  && check "F10 code-reviewer documents fan-out consume mode" PASS || check "F10 consume mode" FAIL
if grep -qF 'first line is exactly `PRE-MERGED FINDINGS (fan-out)`' "$REVIEWER_MD" \
  && grep -qF 'second line is `REVIEW-TICKET: <ticket>`' "$REVIEWER_MD" \
  && grep -qF 'Merely containing or quoting the marker elsewhere is not consume mode' "$REVIEWER_MD"; then
  check "F10a reviewer enters consume mode only for the exact two-line contract" PASS
else
  check "F10a reviewer enters consume mode only for the exact two-line contract" FAIL
fi
# Consume mode short-circuits Phases 1-4 (no re-read, no build, no test).
grep -qiE 'skip phases 1-4|skip phases 1.{1,4}4|jump (straight )?to phase 5|skip.{0,30}(build|test)' "$REVIEWER_MD" \
  && check "F11 consume mode skips Phases 1-4 (no build/test re-run)" PASS || check "F11 consume skips 1-4" FAIL

echo "----"
echo "test-tdd-skill-review-fanout: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
