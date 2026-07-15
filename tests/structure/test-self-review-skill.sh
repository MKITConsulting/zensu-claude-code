#!/bin/bash
# Pins skills/self-review/SKILL.md (ported from /reflect, English-only) plus its
# registration + cross-file version consistency (plugin.json, marketplace.json, README,
# CHANGELOG). self-review is the terminal review-chain stage and owns --chain-done.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_MD="$PLUGIN_DIR/skills/self-review/SKILL.md"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$PLUGIN_DIR/.claude-plugin/marketplace.json"
README_MD="$PLUGIN_DIR/README.md"
CHANGELOG_MD="$PLUGIN_DIR/CHANGELOG.md"
EXPECTED_VERSION="$(jq -r '.version' "$PLUGIN_JSON")"

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

if grep -qxF '# /zensu:self-review' "$SKILL_MD"; then
  check "V2 SKILL.md has the namespaced H1 '# /zensu:self-review'" PASS
else
  check "V2 SKILL.md has the namespaced H1 '# /zensu:self-review'" FAIL
fi
if grep -qE '^name: *self-review *$' "$SKILL_MD"; then
  check "V2b SKILL.md frontmatter declares 'name: self-review'" PASS
else
  check "V2b SKILL.md frontmatter declares 'name: self-review'" FAIL
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
if grep -qF 'AUTOPILOT-BINDING: run=<runId> attempt=<attempt> chain=<chainId>' "$SKILL_MD" \
  && grep -qF -- '--autopilot-status' "$SKILL_MD" \
  && grep -qF 'never from conversation memory' "$SKILL_MD"; then
  check "V10a self-review reads and verifies official current Autopilot binding evidence" PASS
else
  check "V10a official current Autopilot binding evidence" FAIL
fi
if grep -qF -- '--chain-done --autopilot-run "$RUN_ID" --autopilot-attempt "$ATTEMPT" --chain-id "$CHAIN_ID"' "$SKILL_MD" \
  && grep -qF 'Standalone handoffs keep the unqualified terminus' "$SKILL_MD"; then
  check "V10b self-review uses the exact bound terminus without changing standalone" PASS
else
  check "V10b exact bound self-review terminus" FAIL
fi
PHASE4_REGION="$(sed -n '/^## Phase 4: Fix Round or Finalize/,/^### Final report/p' "$SKILL_MD")"
if printf '%s\n' "$PHASE4_REGION" | grep -qF 'The pass-2 invocation MUST carry the' \
  && printf '%s\n' "$PHASE4_REGION" | grep -qF 'SELF-REVIEW-TICKET: <review-ticket>' \
  && printf '%s\n' "$PHASE4_REGION" | grep -qF 'AUTOPILOT-BINDING: run=<runId> attempt=<attempt> chain=<chainId>' \
  && printf '%s\n' "$PHASE4_REGION" | grep -qF 'Do not re-read, re-derive, or omit either generation token'; then
  check "V10c self-review pass 2 explicitly preserves ticket and Autopilot binding" PASS
else
  check "V10c pass-2 generation evidence" FAIL
fi
grep -qF '## Self-Review Summary' "$SKILL_MD" && check "V11 renders ## Self-Review Summary report section" PASS || check "V11 Self-Review Summary section" FAIL

for h in "## Problem" "## What I built" "## How I built it" "## Open" "## TL;DR"; do
  grep -qF "$h" "$SKILL_MD" && check "V11b final report contains '$h'" PASS || check "V11b final report contains '$h'" FAIL
done

REPORT_BLOCK="$(awk '/^### Final report/{f=1} f&&/^```/{c++; if(c>=2) exit} f&&c>=1{print}' "$SKILL_MD")"
LAST_HEADING="$(printf '%s\n' "$REPORT_BLOCK" | grep -E '^## ' | tail -1)"
[ "$LAST_HEADING" = "## TL;DR" ] && check "V11c '## TL;DR' is the last heading in the Final report block" PASS || check "V11c '## TL;DR' last in Final report block (got: $LAST_HEADING)" FAIL

REPORT_SEQ="$(printf '%s\n' "$REPORT_BLOCK" | grep -E '^## ' | sed 's/[[:space:]]*$//' | paste -sd'|' -)"
EXPECTED_REPORT_SEQ="## Problem|## What I built|## How I built it|## Self-Review Summary|## Open|## TL;DR"
[ "$REPORT_SEQ" = "$EXPECTED_REPORT_SEQ" ] && check "V11d Final report emits exact ordered heading sequence" PASS || check "V11d Final report ordered sequence (got: $REPORT_SEQ)" FAIL

grep -qiE 'exactly one|one fix round|a single fix round' "$SKILL_MD" && check "V12 documents the exactly-one fix round" PASS || check "V12 one fix round" FAIL
grep -qiF 'do not spawn' "$SKILL_MD" && check "V13 forbids spawning the code-reviewer (terminal)" PASS || check "V13 no reviewer respawn" FAIL

# Registration + cross-file version consistency (expected version derived from plugin.json).
jq -e '.skills | index("./skills/self-review")' "$PLUGIN_JSON" >/dev/null 2>&1 && check "V14 plugin.json skills[] contains './skills/self-review'" PASS || check "V14 plugin.json registration" FAIL

PLUGIN_VERSION="$(jq -r '.version' "$PLUGIN_JSON" 2>/dev/null)"
MARKETPLACE_VERSION="$(jq -r '.plugins[0].version' "$MARKETPLACE_JSON" 2>/dev/null)"
[ "$PLUGIN_VERSION" = "$EXPECTED_VERSION" ] && check "V15 plugin.json .version == $EXPECTED_VERSION (got: $PLUGIN_VERSION)" PASS || check "V15 plugin.json version (got: $PLUGIN_VERSION)" FAIL
[ "$MARKETPLACE_VERSION" = "$EXPECTED_VERSION" ] && check "V16 marketplace.json version == $EXPECTED_VERSION (got: $MARKETPLACE_VERSION)" PASS || check "V16 marketplace version (got: $MARKETPLACE_VERSION)" FAIL
{ [ "$PLUGIN_VERSION" = "$MARKETPLACE_VERSION" ] && [ -n "$PLUGIN_VERSION" ]; } && check "V17 plugin.json == marketplace.json version (cross-file invariant)" PASS || check "V17 version cross-file invariant" FAIL

{ [ -f "$README_MD" ] && grep -qF "version-${EXPECTED_VERSION}-green" "$README_MD"; } && check "V18 README.md version badge contains $EXPECTED_VERSION" PASS || check "V18 README badge $EXPECTED_VERSION" FAIL
{ [ -f "$README_MD" ] && grep -qE '^### Skills \([0-9]+\)$' "$README_MD"; } && check "V19 README.md has a '### Skills (N)' heading (count owned by test-converge-skill P4c)" PASS || check "V19 README Skills heading missing" FAIL
{ [ -f "$README_MD" ] && grep -qF "/zensu:self-review" "$README_MD"; } && check "V20 README.md mentions /zensu:self-review in the skills table" PASS || check "V20 README mentions self-review" FAIL
{ [ -f "$CHANGELOG_MD" ] && grep -qE "^## \[${EXPECTED_VERSION}\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$CHANGELOG_MD"; } && check "V21 CHANGELOG.md has '## [${EXPECTED_VERSION}] - <date>' section" PASS || check "V21 CHANGELOG $EXPECTED_VERSION dated section" FAIL

echo "----"
echo "test-self-review-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
