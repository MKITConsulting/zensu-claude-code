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
EXPECTED_VERSION="0.4.0"

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

FIRST_LINE="$(head -1 "$SKILL_MD")"
if [ "$FIRST_LINE" = "# /zensu:reset-review-limit" ]; then
  check "R2 SKILL.md first line is exactly '# /zensu:reset-review-limit'" PASS
else
  check "R2 SKILL.md first line is '# /zensu:reset-review-limit' — got: $FIRST_LINE" FAIL
fi

REQUIRED_SECTIONS=(
  "## When to Use"
  "## Do NOT Use For"
  "## Prerequisites"
  "## What This Skill Does"
  "## Phase 1: Locate"
  "## Phase 2: Delete"
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

if grep -qF 'CLAUDE_PLUGIN_DATA_OVERRIDE' "$SKILL_MD"; then
  check "R4 SKILL.md references CLAUDE_PLUGIN_DATA_OVERRIDE (matches hook precedence)" PASS
else
  check "R4 SKILL.md references CLAUDE_PLUGIN_DATA_OVERRIDE" FAIL
fi

if grep -qF 'rounds-*.json' "$SKILL_MD" || grep -qF 'rounds-' "$SKILL_MD"; then
  check "R5 SKILL.md targets rounds-*.json files (matches hook output)" PASS
else
  check "R5 SKILL.md targets rounds-*.json files" FAIL
fi

if grep -qF 'symlink' "$SKILL_MD"; then
  check "R6 SKILL.md documents symlink-traversal guard" PASS
else
  check "R6 SKILL.md documents symlink-traversal guard" FAIL
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

if [ -f "$README_MD" ] && grep -qF "### Skills (8)" "$README_MD"; then
  check "R13 README.md Skills section heading reads '### Skills (8)'" PASS
else
  check "R13 README.md Skills section heading reads '### Skills (8)'" FAIL
fi

if [ -f "$README_MD" ] && grep -qF "/zensu:reset-review-limit" "$README_MD"; then
  check "R14 README.md mentions /zensu:reset-review-limit in the skills table" PASS
else
  check "R14 README.md mentions /zensu:reset-review-limit in the skills table" FAIL
fi

if [ -f "$CHANGELOG_MD" ] && grep -qF "## [${EXPECTED_VERSION}] - 2026-05-30" "$CHANGELOG_MD"; then
  check "R15 CHANGELOG.md has '## [${EXPECTED_VERSION}] - 2026-05-26' section" PASS
else
  check "R15 CHANGELOG.md has '## [${EXPECTED_VERSION}] - 2026-05-26' section" FAIL
fi

if [ -f "$HOOK_SH" ] && grep -qF "/zensu:reset-review-limit" "$HOOK_SH"; then
  check "R16 hooks/post-review-tdd-delegate.sh mentions /zensu:reset-review-limit in convergence directive" PASS
else
  check "R16 hooks/post-review-tdd-delegate.sh mentions /zensu:reset-review-limit in convergence directive" FAIL
fi

if grep -qF 'shopt -s nullglob' "$SKILL_MD"; then
  check "R17 SKILL.md does NOT contain 'shopt -s nullglob' (bash-only builtin broken under zsh)" FAIL
else
  check "R17 SKILL.md does NOT contain 'shopt -s nullglob' (bash-only builtin broken under zsh)" PASS
fi

if grep -qF "find \"\$STATE_DIR\" -maxdepth 1 -name 'rounds-*.json'" "$SKILL_MD"; then
  check "R18 SKILL.md contains POSIX-portable find invocation for rounds-*.json" PASS
else
  check "R18 SKILL.md contains POSIX-portable find invocation for rounds-*.json" FAIL
fi

if grep -qE 'POSIX|bash, zsh|bash/zsh/dash' "$SKILL_MD"; then
  check "R19 SKILL.md Phase 2 preamble declares POSIX/bash-zsh-dash portability" PASS
else
  check "R19 SKILL.md Phase 2 preamble declares POSIX/bash-zsh-dash portability" FAIL
fi

PHASE3_REGION="$(sed -n '/^## Phase 3: Verify/,/^## Response Style/p' "$SKILL_MD")"
if printf '%s\n' "$PHASE3_REGION" | grep -qF "find \"\$STATE_DIR\" -maxdepth 1 -name 'rounds-*.json'"; then
  check "R20 SKILL.md Phase 3 verify recipe uses POSIX-portable find (mirrors R18 for Phase 2)" PASS
else
  check "R20 SKILL.md Phase 3 verify recipe uses POSIX-portable find (mirrors R18 for Phase 2)" FAIL
fi

R21_IF=0; R21_PRINTF=0; R21_ELSE=0
if printf '%s\n' "$PHASE3_REGION" | grep -qF 'if [ -n "$out" ]'; then R21_IF=1; fi
if printf '%s\n' "$PHASE3_REGION" | grep -qF "printf '%s\\n' \"\$out\""; then R21_PRINTF=1; fi
if printf '%s\n' "$PHASE3_REGION" | grep -qF 'else echo "(empty, expected)"'; then R21_ELSE=1; fi
if [ "$R21_IF" = 1 ] && [ "$R21_PRINTF" = 1 ] && [ "$R21_ELSE" = 1 ]; then
  check "R21 SKILL.md Phase 3 recipe uses if/else form (exit 0 in both branches; no && short-circuit)" PASS
else
  check "R21 SKILL.md Phase 3 recipe uses if/else form (if=$R21_IF printf=$R21_PRINTF else=$R21_ELSE)" FAIL
fi

PHASE2_REGION="$(sed -n '/^## Phase 2: Delete/,/^## Phase 3: Verify/p' "$SKILL_MD")"
if printf '%s\n' "$PHASE2_REGION" | grep -qF 'Fresh git worktree detected — counter effectively at 0'; then
  check "R22 SKILL.md Phase 2 contains fresh-worktree hint substring" PASS
else
  check "R22 SKILL.md Phase 2 contains fresh-worktree hint substring" FAIL
fi

R23_DETECT=0; R23_GATE=0
if printf '%s\n' "$PHASE2_REGION" | grep -qF '[ -f "$WORKTREE_ROOT/.git" ]'; then R23_DETECT=1; fi
if printf '%s\n' "$PHASE2_REGION" | grep -qF 'if [ -z "${CLAUDE_PLUGIN_DATA_OVERRIDE:-}" ]'; then R23_GATE=1; fi
if [ "$R23_DETECT" = 1 ] && [ "$R23_GATE" = 1 ]; then
  check "R23 SKILL.md Phase 2 contains .git-is-file detection idiom AND CLAUDE_PLUGIN_DATA_OVERRIDE override-gate" PASS
else
  check "R23 SKILL.md Phase 2 contains .git-is-file detection + override-gate (detect=$R23_DETECT gate=$R23_GATE)" FAIL
fi

if grep -qF "## Strict Scope" "$SKILL_MD"; then
  check "R24 SKILL.md contains '## Strict Scope' section heading" PASS
else
  check "R24 SKILL.md contains '## Strict Scope' section heading" FAIL
fi

if grep -qF 'NEVER** run `git worktree list`' "$SKILL_MD"; then
  check "R25 SKILL.md Strict Scope section prohibits 'git worktree list' (primary cross-worktree traversal vector)" PASS
else
  check "R25 SKILL.md Strict Scope section prohibits 'git worktree list' (primary cross-worktree traversal vector)" FAIL
fi

echo "----"
echo "test-reset-review-limit-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
