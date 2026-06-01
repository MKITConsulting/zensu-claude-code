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

# Thin consume-mode code-reviewer spawn carrying the marker, single hook event per round.
grep -qF 'PRE-MERGED FINDINGS (fan-out)' "$SKILL_MD" \
  && check "F6 skill passes the 'PRE-MERGED FINDINGS (fan-out)' marker" PASS || check "F6 fan-out marker in skill" FAIL
grep -qF "subagent_type='zensu:code-reviewer'" "$SKILL_MD" \
  && check "F7 skill still spawns zensu:code-reviewer (hook trigger preserved)" PASS || check "F7 code-reviewer spawn preserved" FAIL

# Explicit carve-out to the line-18 "NO parallel tool batches" rule.
grep -qiE 'sanctioned parallel batch|ONE (sanctioned|allowed) parallel|exception.{0,40}parallel|fan-out is the (one|only)' "$SKILL_MD" \
  && check "F8 skill carves out the review fan-out from the no-parallel rule" PASS || check "F8 parallel carve-out" FAIL

# --- agents/code-reviewer.md: fan-out consume mode ---

grep -qF 'PRE-MERGED FINDINGS (fan-out)' "$REVIEWER_MD" \
  && check "F9 code-reviewer carries the 'PRE-MERGED FINDINGS (fan-out)' marker" PASS || check "F9 fan-out marker in reviewer" FAIL
grep -qiE 'consume mode|fan-out consume' "$REVIEWER_MD" \
  && check "F10 code-reviewer documents fan-out consume mode" PASS || check "F10 consume mode" FAIL
# Consume mode short-circuits Phases 1-4 (no re-read, no build, no test).
grep -qiE 'skip phases 1-4|skip phases 1.{1,4}4|jump (straight )?to phase 5|skip.{0,30}(build|test)' "$REVIEWER_MD" \
  && check "F11 consume mode skips Phases 1-4 (no build/test re-run)" PASS || check "F11 consume skips 1-4" FAIL

echo "----"
echo "test-tdd-skill-review-fanout: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
