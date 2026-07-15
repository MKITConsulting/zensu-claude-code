#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/reset-review-limit"
SKILL_MD="$SKILL_DIR/SKILL.md"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$PLUGIN_DIR/.claude-plugin/marketplace.json"
README_MD="$PLUGIN_DIR/README.md"
CHANGELOG_MD="$PLUGIN_DIR/CHANGELOG.md"
HOOK_SH="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
EXPECTED_VERSION="$(jq -r '.version' "$PLUGIN_JSON")"
EXPECTED_VERSION_RE="$(printf '%s' "$EXPECTED_VERSION" | sed 's/[.]/\\./g')"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$SKILL_MD" ]; then
  check "R1 skills/reset-review-limit/SKILL.md exists" FAIL
  echo "----"
  echo "test-reset-review-limit-skill: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "R1 skills/reset-review-limit/SKILL.md exists" PASS

if grep -qxF '# /zensu:reset-review-limit' "$SKILL_MD"; then
  check "R2 SKILL.md has the namespaced H1 '# /zensu:reset-review-limit'" PASS
else
  check "R2 SKILL.md has the namespaced H1 '# /zensu:reset-review-limit'" FAIL
fi
if grep -qE '^name: *reset-review-limit *$' "$SKILL_MD"; then
  check "R2b SKILL.md frontmatter declares 'name: reset-review-limit'" PASS
else
  check "R2b SKILL.md frontmatter declares 'name: reset-review-limit'" FAIL
fi

REQUIRED_SECTIONS=(
  "## When to Use"
  "## Do NOT Use For"
  "## Strict Scope"
  "## Prerequisites"
  "## What This Skill Does"
  "## Phase 1: Bind the current generation"
  "## Phase 2: Rearm atomically"
  "## Phase 3: Verify"
  "## Response Style"
)
for section in "${REQUIRED_SECTIONS[@]}"; do
  if grep -qF "$section" "$SKILL_MD"; then
    check "R3 SKILL.md contains section heading '$section'" PASS
  else
    check "R3 SKILL.md contains section heading '$section'" FAIL
  fi
done

if grep -qF '"${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh"' "$SKILL_MD"; then
  check "R4 SKILL.md invokes the installed plugin helper through CLAUDE_PLUGIN_ROOT" PASS
else
  check "R4 SKILL.md invokes the installed plugin helper through CLAUDE_PLUGIN_ROOT" FAIL
fi

if grep -qF -- '--current-review-ticket' "$SKILL_MD" \
  && grep -qF -- '--review-rearm --claimed-review-ticket "$REVIEW_TICKET"' "$SKILL_MD"; then
  check "R5 SKILL.md binds and rearms through the ticket-bound helper API" PASS
else
  check "R5 SKILL.md binds and rearms through the ticket-bound helper API" FAIL
fi

if grep -qF 'Do not inspect state files yourself' "$SKILL_MD" \
  && grep -qF 'Never fall back to searching for a' "$SKILL_MD" \
  && grep -qF 'different session' "$SKILL_MD"; then
  check "R6 SKILL.md keeps state/path safety inside the official current-session helper" PASS
else
  check "R6 SKILL.md keeps state/path safety inside the official current-session helper" FAIL
fi

if [ ! -f "$PLUGIN_JSON" ]; then
  check "R7 .claude-plugin/plugin.json exists" FAIL
  echo "----"
  echo "test-reset-review-limit-skill: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "R7 .claude-plugin/plugin.json exists" PASS

if jq -e '.skills | index("./skills/reset-review-limit")' "$PLUGIN_JSON" >/dev/null 2>&1; then
  check "R8 plugin.json skills[] contains './skills/reset-review-limit'" PASS
else
  check "R8 plugin.json skills[] contains './skills/reset-review-limit'" FAIL
fi

PLUGIN_VERSION="$(jq -r '.version' "$PLUGIN_JSON" 2>/dev/null)"
MARKETPLACE_VERSION="$(jq -r '.plugins[0].version' "$MARKETPLACE_JSON" 2>/dev/null)"

if [ "$PLUGIN_VERSION" = "$EXPECTED_VERSION" ]; then
  check "R9 plugin.json .version == $EXPECTED_VERSION (got: $PLUGIN_VERSION)" PASS
else
  check "R9 plugin.json .version == $EXPECTED_VERSION (got: $PLUGIN_VERSION)" FAIL
fi

if [ "$MARKETPLACE_VERSION" = "$EXPECTED_VERSION" ]; then
  check "R10 marketplace.json .plugins[0].version == $EXPECTED_VERSION (got: $MARKETPLACE_VERSION)" PASS
else
  check "R10 marketplace.json .plugins[0].version == $EXPECTED_VERSION (got: $MARKETPLACE_VERSION)" FAIL
fi

if [ "$PLUGIN_VERSION" = "$MARKETPLACE_VERSION" ] && [ -n "$PLUGIN_VERSION" ]; then
  check "R11 plugin.json .version == marketplace.json .plugins[0].version (cross-file invariant)" PASS
else
  check "R11 plugin.json .version ($PLUGIN_VERSION) == marketplace.json .plugins[0].version ($MARKETPLACE_VERSION)" FAIL
fi

if [ -f "$README_MD" ] && grep -qF "version-${EXPECTED_VERSION}-green" "$README_MD"; then
  check "R12 README.md version badge contains $EXPECTED_VERSION" PASS
else
  check "R12 README.md version badge contains $EXPECTED_VERSION" FAIL
fi

if [ -f "$README_MD" ] && grep -qE '^### Skills \([0-9]+\)$' "$README_MD"; then
  check "R13 README.md has a '### Skills (N)' heading (count owned by test-converge-skill P4c)" PASS
else
  check "R13 README.md has a '### Skills (N)' heading (count owned by test-converge-skill P4c)" FAIL
fi

if [ -f "$README_MD" ] && grep -qF "/zensu:reset-review-limit" "$README_MD"; then
  check "R14 README.md mentions /zensu:reset-review-limit in the skills table" PASS
else
  check "R14 README.md mentions /zensu:reset-review-limit in the skills table" FAIL
fi

if [ -f "$CHANGELOG_MD" ] && grep -qE "^## \[${EXPECTED_VERSION_RE}\] - [0-9]{4}-[0-9]{2}-[0-9]{2}" "$CHANGELOG_MD"; then
  check "R15 CHANGELOG.md has '## [${EXPECTED_VERSION}] - <date>' section" PASS
else
  check "R15 CHANGELOG.md has '## [${EXPECTED_VERSION}] - <date>' section" FAIL
fi

if [ -f "$HOOK_SH" ] && grep -qF "/zensu:reset-review-limit" "$HOOK_SH"; then
  check "R16 hooks/post-review-tdd-delegate.sh mentions /zensu:reset-review-limit in convergence directive" PASS
else
  check "R16 hooks/post-review-tdd-delegate.sh mentions /zensu:reset-review-limit in convergence directive" FAIL
fi

if grep -qE '(^|[[:space:]])(find|rm)[[:space:]]+-' "$SKILL_MD" \
  || grep -qE 'for .*(rounds-|tdd-phase-|stopblocks)' "$SKILL_MD"; then
  check "R17 SKILL.md contains no direct filesystem scan/delete recipe" FAIL
else
  check "R17 SKILL.md contains no direct filesystem scan/delete recipe" PASS
fi

if grep -qF 'NEVER** use `find`, globs, or loops' "$SKILL_MD" \
  && grep -qF 'NEVER** edit a state JSON file directly' "$SKILL_MD"; then
  check "R18 Strict Scope explicitly forbids cross-session scans and direct JSON edits" PASS
else
  check "R18 Strict Scope explicitly forbids cross-session scans and direct JSON edits" FAIL
fi

PHASE1_REGION="$(sed -n '/^## Phase 1: Bind the current generation/,/^## Phase 2: Rearm atomically/p' "$SKILL_MD")"
if printf '%s\n' "$PHASE1_REGION" | grep -qF 'REVIEW_TICKET="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --current-review-ticket)"' \
  && printf '%s\n' "$PHASE1_REGION" | grep -qF 'If this command fails or prints an empty value, stop'; then
  check "R19 Phase 1 resolves exactly the current consumed generation and fails closed" PASS
else
  check "R19 Phase 1 resolves exactly the current consumed generation and fails closed" FAIL
fi

PHASE2_REGION="$(sed -n '/^## Phase 2: Rearm atomically/,/^## Phase 3: Verify/p' "$SKILL_MD")"
if printf '%s\n' "$PHASE2_REGION" | grep -qF -- '--review-rearm --claimed-review-ticket "$REVIEW_TICKET"' \
  && printf '%s\n' "$PHASE2_REGION" | grep -qF 'Treat that as a safe stale-operation rejection'; then
  check "R20 Phase 2 uses one stale-rejecting generation-bound CAS" PASS
else
  check "R20 Phase 2 uses one stale-rejecting generation-bound CAS" FAIL
fi

if printf '%s\n' "$PHASE2_REGION" | grep -qF 'retry with another ticket' \
  && printf '%s\n' "$PHASE2_REGION" | grep -qF 'do not edit any state manually'; then
  check "R21 Phase 2 forbids stale-CAS retry and manual repair" PASS
else
  check "R21 Phase 2 forbids stale-CAS retry and manual repair" FAIL
fi

PHASE3_REGION="$(sed -n '/^## Phase 3: Verify/,/^## Response Style/p' "$SKILL_MD")"
if printf '%s\n' "$PHASE3_REGION" | grep -qF -- '--current-review-ticket' \
  && printf '%s\n' "$PHASE3_REGION" | grep -qF 'MUST now exit non-zero' \
  && printf '%s\n' "$PHASE3_REGION" | grep -qF 'round 1'; then
  check "R22 Phase 3 verifies ticket invalidation and fresh round numbering" PASS
else
  check "R22 Phase 3 verifies ticket invalidation and fresh round numbering" FAIL
fi

if grep -qF 'next ticket can therefore be issued' "$SKILL_MD" \
  && grep -qF 'Do not pre-issue that ticket from this reset skill' "$SKILL_MD"; then
  check "R23 skill rearms without issuing or consuming the next review ticket" PASS
else
  check "R23 skill rearms without issuing or consuming the next review ticket" FAIL
fi

if grep -qF 'NEVER** run `git worktree list`' "$SKILL_MD" \
  && grep -qF 'current resolved session and current' "$SKILL_MD"; then
  check "R24 Strict Scope binds the operation to the current session/worktree" PASS
else
  check "R24 Strict Scope binds the operation to the current session/worktree" FAIL
fi

if grep -qF 'Never print the ticket value' "$SKILL_MD" \
  && grep -qF 'never name or touch another session' "$SKILL_MD"; then
  check "R25 response contract keeps the capability ticket out of output" PASS
else
  check "R25 response contract keeps the capability ticket out of output" FAIL
fi

# Runtime contract: the helper performs one generation-bound CAS, rejects a
# wrong/replayed ticket without mutation, leaves sibling state untouched, and
# makes the next real reviewer completion round 1.
RUNTIME_ROOT="$(mktemp -d -t zensu-reset-runtime-XXXXXX)"
RUNTIME_STATE="$RUNTIME_ROOT/state"
RUNTIME_PROJECT="$RUNTIME_ROOT/project"
RUNTIME_CONFIG="$RUNTIME_ROOT/config.json"
mkdir -p "$RUNTIME_STATE" "$RUNTIME_PROJECT"
printf '%s\n' '{}' > "$RUNTIME_CONFIG"
trap 'rm -rf "$RUNTIME_ROOT"' EXIT

runtime_log() {
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$RUNTIME_PROJECT" \
    TDD_STATE_DIR="$RUNTIME_STATE" CLAUDE_PLUGIN_DATA_OVERRIDE="$RUNTIME_STATE" \
    ZENSU_CONFIG="$RUNTIME_CONFIG" bash "$PLUGIN_DIR/hooks/lib/zensu-log.sh" "$@"
}
runtime_review() {
  local sid="$1" ticket="$2"
  SID="$sid" TICKET="$ticket" node -e '
    process.stdout.write(JSON.stringify({
      tool_name: "Agent",
      tool_input: {
        subagent_type: "zensu:code-reviewer",
        prompt: `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nfixture`
      },
      session_id: process.env.SID
    }));
  ' | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$RUNTIME_PROJECT" \
    TDD_STATE_DIR="$RUNTIME_STATE" CLAUDE_PLUGIN_DATA_OVERRIDE="$RUNTIME_STATE" \
    ZENSU_CONFIG="$RUNTIME_CONFIG" bash "$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
}

RUNTIME_SID=reset-runtime
RUNTIME_OTHER=reset-sibling
runtime_log --tdd-begin --session "$RUNTIME_SID" >/dev/null
runtime_log --tdd-complete --session "$RUNTIME_SID" >/dev/null
RUNTIME_TICKET="$(runtime_log --review-ticket --session "$RUNTIME_SID")"
runtime_review "$RUNTIME_SID" "$RUNTIME_TICKET" >/dev/null
runtime_log --code-review-done --session "$RUNTIME_SID" \
  --claimed-review-ticket "$RUNTIME_TICKET" >/dev/null

RUNTIME_FILE="$RUNTIME_STATE/tdd-phase-${RUNTIME_SID}.json"
RUNTIME_COUNTER="$RUNTIME_STATE/rounds-${RUNTIME_SID}.json"
RUNTIME_STOPBLOCKS="${RUNTIME_FILE}.stopblocks"
printf '%s' xxx > "$RUNTIME_STOPBLOCKS"
printf '%s\n' sibling > "$RUNTIME_STATE/rounds-${RUNTIME_OTHER}.json"
SIBLING_BEFORE="$(cksum < "$RUNTIME_STATE/rounds-${RUNTIME_OTHER}.json")"
STATE_BEFORE_WRONG="$(cksum < "$RUNTIME_FILE")"
WRONG_TICKET=rt_00000000000000000000000000000000
if runtime_log --review-rearm --session "$RUNTIME_SID" \
    --claimed-review-ticket "$WRONG_TICKET" >/dev/null 2>&1; then
  WRONG_RC=0
else
  WRONG_RC=$?
fi
STATE_AFTER_WRONG="$(cksum < "$RUNTIME_FILE")"
if [ "$WRONG_RC" -ne 0 ] && [ "$STATE_BEFORE_WRONG" = "$STATE_AFTER_WRONG" ]; then
  check "R26 wrong generation ticket is a byte-stable CAS rejection" PASS
else
  check "R26 wrong generation ticket is a byte-stable CAS rejection" FAIL
fi

if runtime_log --review-rearm --session "$RUNTIME_SID" \
    --claimed-review-ticket "$RUNTIME_TICKET" >/dev/null; then
  check "R27 matching consumed terminal generation rearms successfully" PASS
else
  check "R27 matching consumed terminal generation rearms successfully" FAIL
fi

if node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const valid = s.reviewRound === 0 && s.reviewTicket === ""
    && s.reviewTicketConsumed === true && s.codeReviewDone === false
    && s.chainDone === false && s.selfReviewFixed === false && s.stopBlockCount === 0;
  process.exit(valid ? 0 : 1);
' "$RUNTIME_FILE" \
  && [ ! -e "$RUNTIME_COUNTER" ] && [ ! -e "$RUNTIME_STOPBLOCKS" ]; then
  check "R28 rearm resets authoritative and derived budgets together" PASS
else
  check "R28 rearm resets authoritative and derived budgets together" FAIL
fi

SIBLING_AFTER="$(cksum < "$RUNTIME_STATE/rounds-${RUNTIME_OTHER}.json")"
if [ "$SIBLING_BEFORE" = "$SIBLING_AFTER" ] \
  && ! runtime_log --current-review-ticket --session "$RUNTIME_SID" >/dev/null 2>&1 \
  && ! runtime_log --review-rearm --session "$RUNTIME_SID" \
       --claimed-review-ticket "$RUNTIME_TICKET" >/dev/null 2>&1; then
  check "R29 rearm invalidates replay/getter and never scans sibling counters" PASS
else
  check "R29 rearm invalidates replay/getter and never scans sibling counters" FAIL
fi

RUNTIME_NEXT_TICKET="$(runtime_log --review-ticket --session "$RUNTIME_SID")"
runtime_review "$RUNTIME_SID" "$RUNTIME_NEXT_TICKET" >/dev/null
RUNTIME_NEXT_ROUND="$(node -e '
  try { process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1])).count)); }
  catch (_) { process.stdout.write(""); }
' "$RUNTIME_COUNTER")"
if [ "$RUNTIME_NEXT_ROUND" = 1 ]; then
  check "R30 first completion after rearm is round 1" PASS
else
  check "R30 first completion after rearm is round 1" FAIL
fi

echo "----"
echo "test-reset-review-limit-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
