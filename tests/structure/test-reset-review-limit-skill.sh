#!/bin/bash
# Contract test for the Session-Control-v1 /zensu:reset-review-limit workflow.
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
  '## When to Use' \
  '## Do NOT Use For' \
  '## Strict Scope' \
  '## Prerequisites' \
  '## What This Skill Does' \
  '## Phase 1: Bind the current generation' \
  '## Phase 2: Rearm atomically' \
  '## Phase 3: Verify' \
  '## Response Style'; do
  grep -qF "$section" "$SKILL_MD" \
    && check "R3 section present: $section" PASS \
    || check "R3 section present: $section" FAIL
done

if grep -qF 'ROOT="${ZENSU_CLAUDE_PLUGIN_ROOT:?FATAL: plugin root unavailable; start a fresh Claude Code session}"' "$SKILL_MD" \
  && ! grep -qF '${CLAUDE_PLUGIN_ROOT}' "$SKILL_MD" \
  && ! grep -qF '.zensu/plugin-root' "$SKILL_MD"; then
  check "R4 helper resolution uses only the fail-closed session export" PASS
else
  check "R4 helper resolution uses only the fail-closed session export" FAIL
fi

if grep -qF 'SESSION_ID="$(zensu_resolve_session_id "${ZENSU_SESSION_KEY:?FATAL: Session Control key unavailable}")"' "$SKILL_MD" \
  && grep -qF 'REVIEW_TICKET="$(bash "$LOG" --current-review-ticket)"' "$SKILL_MD"; then
  check "R5 Phase 1 binds the current Session Control principal and consumed ticket" PASS
else
  check "R5 Phase 1 binds the current Session Control principal and consumed ticket" FAIL
fi

if grep -qF -- '--review-rearm --session "$SESSION_ID"' "$SKILL_MD" \
  && grep -qF -- '--claimed-review-ticket "$REVIEW_TICKET"' "$SKILL_MD"; then
  check "R6 standalone rearm is session- and ticket-bound" PASS
else
  check "R6 standalone rearm is session- and ticket-bound" FAIL
fi

if grep -qF -- '--autopilot-run "$RUN_ID"' "$SKILL_MD" \
  && grep -qF -- '--autopilot-attempt "$ATTEMPT" --chain-id "$CHAIN_ID"' "$SKILL_MD" \
  && grep -qF 'ownerSessionId' "$SKILL_MD" \
  && grep -qF 'tdd.sessionId' "$SKILL_MD"; then
  check "R7 durable rearm carries the exact run/attempt/chain/session binding" PASS
else
  check "R7 durable rearm carries the exact run/attempt/chain/session binding" FAIL
fi

if grep -qF 'reviewRound' "$SKILL_MD" \
  && grep -qF 'Session Control workflow document' "$SKILL_MD" \
  && grep -qF 'There are no derived' "$SKILL_MD" \
  && grep -qF 'round-counter or Stop-budget files' "$SKILL_MD"; then
  check "R8 review and Stop budgets remain integrated in one revisioned document" PASS
else
  check "R8 review and Stop budgets remain integrated in one revisioned document" FAIL
fi

CODE_BLOCKS="$(awk '/^```/{inside=!inside; next} inside{print}' "$SKILL_MD")"
if printf '%s\n' "$CODE_BLOCKS" | grep -Eq '(^|[[:space:]])(find|rm|mv|cp)[[:space:]]|CLAUDE_PLUGIN_DATA_OVERRIDE|rounds-|\.stopblocks|writeFileSync|JSON\.parse.*readFile'; then
  check "R9 executable recipes contain no search, deletion, sidecar, override, or raw-JSON mutation" FAIL
else
  check "R9 executable recipes contain no search, deletion, sidecar, override, or raw-JSON mutation" PASS
fi

if grep -qF 'NEVER** run `git worktree list`' "$SKILL_MD" \
  && grep -qF 'NEVER** use `find`, globs, or loops' "$SKILL_MD" \
  && grep -qF 'NEVER** edit a state JSON file directly' "$SKILL_MD"; then
  check "R10 strict scope forbids cross-session discovery and direct state edits" PASS
else
  check "R10 strict scope forbids cross-session discovery and direct state edits" FAIL
fi

if grep -qF 'Treat that as a safe stale-operation rejection' "$SKILL_MD" \
  && grep -qF 'do not reinterpret a historical' "$SKILL_MD" \
  && grep -qF 'pointer, retry with another ticket' "$SKILL_MD"; then
  check "R11 stale generations fail closed without scope reinterpretation" PASS
else
  check "R11 stale generations fail closed without scope reinterpretation" FAIL
fi

if grep -qF 'SHA-256 digest' "$SKILL_MD" \
  && grep -qF 'byte-identical binding and old ticket' "$SKILL_MD" \
  && grep -qF 'idempotent exit 0' "$SKILL_MD"; then
  check "R12 durable crash replay is limited to the exact digest receipt" PASS
else
  check "R12 durable crash replay is limited to the exact digest receipt" FAIL
fi

if grep -qF 'stage=TDD_RUNNING' "$SKILL_MD" \
  && grep -qF 'blocked.code=TDD_MAX_ROUNDS' "$SKILL_MD" \
  && grep -qF 'start `ATTEMPT + 1` through the bound `--tdd-begin` form' "$SKILL_MD"; then
  check "R13 durable recovery distinguishes same-chain rearm from a fresh bound attempt" PASS
else
  check "R13 durable recovery distinguishes same-chain rearm from a fresh bound attempt" FAIL
fi

if grep -qF 'MUST now exit non-zero' "$SKILL_MD" \
  && grep -qF 'round 1' "$SKILL_MD" \
  && grep -qF 'Do not pre-issue that ticket' "$SKILL_MD"; then
  check "R14 verification requires old-ticket invalidation and fresh round numbering" PASS
else
  check "R14 verification requires old-ticket invalidation and fresh round numbering" FAIL
fi

if grep -qF 'Never print the ticket value' "$SKILL_MD" \
  && grep -qF 'never name or touch another session' "$SKILL_MD"; then
  check "R15 response contract keeps the capability and sibling sessions private" PASS
else
  check "R15 response contract keeps the capability and sibling sessions private" FAIL
fi

jq -e '.skills | index("./skills/reset-review-limit")' "$PLUGIN_JSON" >/dev/null 2>&1 \
  && check "R16 plugin manifest registers the skill" PASS \
  || check "R16 plugin manifest registers the skill" FAIL

grep -qF '/zensu:reset-review-limit' "$README_MD" \
  && grep -qF '/zensu:reset-review-limit' "$HOOK_SH" \
  && check "R17 README and convergence directive expose the reset skill" PASS \
  || check "R17 README and convergence directive expose the reset skill" FAIL

echo "----"
echo "test-reset-review-limit-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
