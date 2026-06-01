#!/bin/bash
# Pins skills/self-review/SKILL.md (ported from /reflect, English-only) plus its
# registration + the 0.5.0 release bump (plugin.json, marketplace.json, README,
# CHANGELOG). self-review is the terminal review-chain stage and owns --chain-done.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_MD="$PLUGIN_DIR/skills/self-review/SKILL.md"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$PLUGIN_DIR/.claude-plugin/marketplace.json"
README_MD="$PLUGIN_DIR/README.md"
CHANGELOG_MD="$PLUGIN_DIR/CHANGELOG.md"
EXPECTED_VERSION="0.6.0"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$SKILL_MD" ]; then
  check "V1 skills/self-review/SKILL.md exists" FAIL
  echo "----"
  echo "test-self-review-skill: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "V1 skills/self-review/SKILL.md exists" PASS

FIRST_LINE="$(head -1 "$SKILL_MD")"
if [ "$FIRST_LINE" = "# /zensu:self-review" ]; then
  check "V2 SKILL.md first line is exactly '# /zensu:self-review'" PASS
else
  check "V2 SKILL.md first line is '# /zensu:self-review' — got: $FIRST_LINE" FAIL
fi

REQUIRED_SECTIONS=(
  "## When to Use"
  "## Do NOT Use For"
  "## What This Skill Does"
  "## Phase 1: List Changed Files"
  "## Phase 2: Analyze"
  "## Phase 3: Report"
  "## Phase 4: Fix Round or Finalize"
  "## Strict Scope"
  "## Response Style"
)
for section in "${REQUIRED_SECTIONS[@]}"; do
  if grep -qF "$section" "$SKILL_MD"; then
    check "V3 SKILL.md contains section heading '$section'" PASS
  else
    check "V3 SKILL.md contains section heading '$section'" FAIL
  fi
done

# English-only (repo convention): no German umlauts / eszett.
if node -e 'const t=require("fs").readFileSync(process.argv[1],"utf8");process.exit(/[äöüÄÖÜß]/.test(t)?1:0)' "$SKILL_MD"; then
  check "V4 SKILL.md is English-only (no umlauts/eszett)" PASS
else
  check "V4 SKILL.md is English-only (no umlauts/eszett)" FAIL
fi

# Seven self-reflection dimensions (ported from /reflect).
for dim in architecture consistency edge-cases "test coverage" security simplification conventions; do
  if grep -qiF "$dim" "$SKILL_MD"; then
    check "V5 SKILL.md scores dimension '$dim'" PASS
  else
    check "V5 SKILL.md scores dimension '$dim'" FAIL
  fi
done

# Three-bucket output, ported from /reflect.
for bucket in "Positive" "Improvements" "Risks"; do
  grep -qF "$bucket" "$SKILL_MD" && check "V6 SKILL.md output bucket '$bucket'" PASS || check "V6 output bucket '$bucket'" FAIL
done

# Terminal-stage mechanics.
grep -qF 'git diff --name-only' "$SKILL_MD" && check "V7 lists session changes via git diff --name-only" PASS || check "V7 git diff --name-only" FAIL
grep -qF 'selfReviewFixed' "$SKILL_MD" && check "V8 references selfReviewFixed latch" PASS || check "V8 selfReviewFixed latch" FAIL
grep -qF -- '--self-review-fixed' "$SKILL_MD" && check "V9 sets latch via --self-review-fixed marker" PASS || check "V9 --self-review-fixed marker" FAIL
grep -qF -- '--chain-done' "$SKILL_MD" && check "V10 finalizes via --chain-done (owns terminus)" PASS || check "V10 --chain-done finalize" FAIL
grep -qF '## Self-Review Summary' "$SKILL_MD" && check "V11 renders ## Self-Review Summary report section" PASS || check "V11 Self-Review Summary section" FAIL
grep -qiE 'exactly one|one fix round|a single fix round' "$SKILL_MD" && check "V12 documents the exactly-one fix round" PASS || check "V12 one fix round" FAIL
grep -qiF 'do not spawn' "$SKILL_MD" && check "V13 forbids spawning the code-reviewer (terminal)" PASS || check "V13 no reviewer respawn" FAIL

# Registration + 0.5.0 release bump.
jq -e '.skills | index("./skills/self-review")' "$PLUGIN_JSON" >/dev/null 2>&1 && check "V14 plugin.json skills[] contains './skills/self-review'" PASS || check "V14 plugin.json registration" FAIL

PLUGIN_VERSION="$(jq -r '.version' "$PLUGIN_JSON" 2>/dev/null)"
MARKETPLACE_VERSION="$(jq -r '.plugins[0].version' "$MARKETPLACE_JSON" 2>/dev/null)"
[ "$PLUGIN_VERSION" = "$EXPECTED_VERSION" ] && check "V15 plugin.json .version == $EXPECTED_VERSION (got: $PLUGIN_VERSION)" PASS || check "V15 plugin.json version (got: $PLUGIN_VERSION)" FAIL
[ "$MARKETPLACE_VERSION" = "$EXPECTED_VERSION" ] && check "V16 marketplace.json version == $EXPECTED_VERSION (got: $MARKETPLACE_VERSION)" PASS || check "V16 marketplace version (got: $MARKETPLACE_VERSION)" FAIL
{ [ "$PLUGIN_VERSION" = "$MARKETPLACE_VERSION" ] && [ -n "$PLUGIN_VERSION" ]; } && check "V17 plugin.json == marketplace.json version (cross-file invariant)" PASS || check "V17 version cross-file invariant" FAIL

{ [ -f "$README_MD" ] && grep -qF "version-${EXPECTED_VERSION}-green" "$README_MD"; } && check "V18 README.md version badge contains $EXPECTED_VERSION" PASS || check "V18 README badge $EXPECTED_VERSION" FAIL
{ [ -f "$README_MD" ] && grep -qF "### Skills (9)" "$README_MD"; } && check "V19 README.md Skills section heading reads '### Skills (9)'" PASS || check "V19 README Skills (9)" FAIL
{ [ -f "$README_MD" ] && grep -qF "/zensu:self-review" "$README_MD"; } && check "V20 README.md mentions /zensu:self-review in the skills table" PASS || check "V20 README mentions self-review" FAIL
{ [ -f "$CHANGELOG_MD" ] && grep -qF "## [${EXPECTED_VERSION}] - 2026-06-01" "$CHANGELOG_MD"; } && check "V21 CHANGELOG.md has '## [${EXPECTED_VERSION}] - 2026-06-01' section" PASS || check "V21 CHANGELOG $EXPECTED_VERSION section" FAIL

echo "----"
echo "test-self-review-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
