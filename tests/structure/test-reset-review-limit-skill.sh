#!/bin/bash
# Contract test for the revision-secured /zensu:reset-review-limit workflow.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_MD="$PLUGIN_DIR/skills/reset-review-limit/SKILL.md"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
README_MD="$PLUGIN_DIR/README.md"
HOOK_SH="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = PASS ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ -f "$SKILL_MD" ]; then
  check "R1 reset-review-limit skill exists" PASS
else
  check "R1 reset-review-limit skill exists" FAIL
  exit 1
fi

grep -qE '^name: *reset-review-limit *$' "$SKILL_MD" \
  && grep -qxF '# /zensu:reset-review-limit' "$SKILL_MD" \
  && check "R2 frontmatter and namespaced heading are registered" PASS \
  || check "R2 frontmatter and namespaced heading are registered" FAIL

for section in \
  '## Strict Scope' \
  '## Phase 1: Validate the exact active workflow document' \
  '## Phase 2: Reset and re-arm through CAS only' \
  '## Phase 3: Verify the revisioned result' \
  '## Response Style'; do
  grep -qF "$section" "$SKILL_MD" \
    && check "R3 section present: $section" PASS \
    || check "R3 section present: $section" FAIL
done

if grep -qF 'tdd_reset_review_budget "$SESSION_KEY" "$BEFORE_REVISION"' "$SKILL_MD" \
  && ! grep -qF 'tdd_reset_review_counters' "$SKILL_MD" \
  && ! grep -qF 'tdd_set_flag "$SESSION_KEY"' "$SKILL_MD"; then
  check "R4 reset uses exactly one revision-pinned CAS helper" PASS
else
  check "R4 reset uses exactly one revision-pinned CAS helper" FAIL
fi

if grep -qF 'state.revision !== expected' "$SKILL_MD" \
  && grep -qF 'Number(process.env.BEFORE_REVISION) + 1' "$SKILL_MD" \
  && grep -qF 'state.reviewRound !== 0' "$SKILL_MD" \
  && grep -qF 'state.stopBlocks !== 0' "$SKILL_MD" \
  && grep -qF 'state.selfReviewFixed !== false' "$SKILL_MD"; then
  check "R5 trusted verification requires revision +1 and the complete reset invariant" PASS
else
  check "R5 trusted verification requires revision +1 and the complete reset invariant" FAIL
fi

if grep -qF 'tdd_state_status "$STATE_FILE"' "$SKILL_MD" \
  && grep -qF 'tdd_session_active "$STATE_FILE"' "$SKILL_MD" \
  && grep -qF 'ZENSU_SESSION_KEY' "$SKILL_MD" \
  && grep -qF 'ZENSU_CLAUDE_PLUGIN_ROOT' "$SKILL_MD"; then
  check "R6 preflight binds one validated active Session Control document" PASS
else
  check "R6 preflight binds one validated active Session Control document" FAIL
fi

# Inspect executable examples only. Prose deliberately names forbidden commands
# so the operator understands the boundary.
CODE_BLOCKS="$(awk '/^```/{inside=!inside; next} inside{print}' "$SKILL_MD")"
if printf '%s\n' "$CODE_BLOCKS" | grep -Eq '(^|[[:space:]])(find|rm|mv|cp)[[:space:]]|CLAUDE_PLUGIN_DATA_OVERRIDE|rounds-|\.stopblocks|writeFileSync|JSON\.parse.*readFile'; then
  check "R7 executable recipes contain no search, deletion, sidecar, override, or raw-JSON mutation" FAIL
else
  check "R7 executable recipes contain no search, deletion, sidecar, override, or raw-JSON mutation" PASS
fi

if grep -qF 'Never run `find`, `git worktree list`, or a filesystem scan.' "$SKILL_MD" \
  && grep -qF 'Explicitly say that no files were searched for or deleted.' "$SKILL_MD"; then
  check "R8 scope explicitly prohibits cross-session search and deletion" PASS
else
  check "R8 scope explicitly prohibits cross-session search and deletion" FAIL
fi

jq -e '.skills | index("./skills/reset-review-limit")' "$PLUGIN_JSON" >/dev/null 2>&1 \
  && check "R9 plugin manifest registers the skill" PASS \
  || check "R9 plugin manifest registers the skill" FAIL

grep -qF '/zensu:reset-review-limit' "$README_MD" \
  && grep -qF 'reviewRound' "$README_MD" \
  && check "R10 README documents the integrated reset" PASS \
  || check "R10 README documents the integrated reset" FAIL

grep -qF '/zensu:reset-review-limit' "$HOOK_SH" \
  && check "R11 convergence directive names the reset skill" PASS \
  || check "R11 convergence directive names the reset skill" FAIL

echo "----"
echo "test-reset-review-limit-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
