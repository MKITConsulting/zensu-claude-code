#!/bin/bash
set -u

# Structure test for the /zensu:pr-team-review skill.
# Pins: the skill exists with its SKILL.md + three rules files, follows the namespaced
# title-line convention, carries the orchestration essentials (worktree isolation,
# single-message parallel spawn, run_in_background reviewers, one consolidated gh api
# review, the 14-persona pool), is English-only, uses the namespaced command form and
# the ${CLAUDE_PLUGIN_ROOT} path (no leaked ~/.claude/skills home path), is registered
# in plugin.json, and that the version is in sync across plugin.json + marketplace.json
# + the README badge with the skills-count heading bumped to 12.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/pr-team-review"
SKILL_MD="$SKILL_DIR/SKILL.md"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$PLUGIN_DIR/.claude-plugin/marketplace.json"
README_MD="$PLUGIN_DIR/README.md"
EXPECTED_VERSION="$(jq -r '.version' "$PLUGIN_JSON")"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

# P1 — SKILL.md exists
if [ ! -f "$SKILL_MD" ]; then
  check "P1 skills/pr-team-review/SKILL.md exists" FAIL
  echo "----"
  echo "test-pr-team-review-skill: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "P1 skills/pr-team-review/SKILL.md exists" PASS

# P2 — the three rules files ship alongside the skill
for r in reviewer-personas workflow github-publish; do
  if [ -f "$SKILL_DIR/rules/$r.md" ]; then
    check "P2 skills/pr-team-review/rules/$r.md exists" PASS
  else
    check "P2 skills/pr-team-review/rules/$r.md exists" FAIL
  fi
done

# P3 — namespaced H1 title present, plus the frontmatter that drives invocation + auto-trigger.
# Unlike its slash-only siblings, this skill keeps YAML frontmatter so the description's
# trigger phrases ("team review", "multi-agent PR review", ...) can auto-select it.
if grep -qxF '# /zensu:pr-team-review' "$SKILL_MD"; then
  check "P3a SKILL.md has the namespaced H1 '# /zensu:pr-team-review'" PASS
else
  check "P3a SKILL.md has the namespaced H1 '# /zensu:pr-team-review'" FAIL
fi
if grep -qE '^name: *pr-team-review *$' "$SKILL_MD"; then
  check "P3b SKILL.md frontmatter declares 'name: pr-team-review'" PASS
else
  check "P3b SKILL.md frontmatter declares 'name: pr-team-review'" FAIL
fi

# P4 — orchestration essentials
declare -A ESSENTIALS=(
  ["P4a worktree isolation (git worktree add)"]="worktree add"
  ["P4b single-message parallel spawn"]="single message"
  ["P4c reviewers run in background"]="run_in_background"
  ["P4d one consolidated review (Submit ONE review)"]="Submit ONE review"
  ["P4e publishes via the gh api reviews endpoint"]="pulls/<n>/reviews"
  ["P4f casts from the 14-persona pool"]="14-persona"
)
for label in "${!ESSENTIALS[@]}"; do
  if grep -qF "${ESSENTIALS[$label]}" "$SKILL_MD"; then
    check "$label" PASS
  else
    check "$label" FAIL
  fi
done

# P5 — English-only guard: German tokens MUST be ABSENT across the skill tree.
# Word stems carry their own umlauts; a bare [äöüßÄÖÜ] class is intentionally omitted
# because, under a byte-wise locale, it false-matches multibyte punctuation (em-dash, arrows).
GERMAN_RE='revalidier|köpfig|prüf|änder|überarbeit|konsens|konvergenz'
if grep -rqiE "$GERMAN_RE" "$SKILL_DIR"; then
  check "P5 skill is English-only (found German tokens matching: $GERMAN_RE)" FAIL
else
  check "P5 skill is English-only (no German tokens)" PASS
fi

# P6 — command refs are namespaced: a backtick-prefixed bare '/pr-team-review' must be ABSENT
if grep -rqF '`/pr-team-review' "$SKILL_DIR"; then
  check "P6 command refs are namespaced (found bare backticked '/pr-team-review')" FAIL
else
  check "P6 command refs are namespaced /zensu:pr-team-review (no bare command ref)" PASS
fi

# P7 — bundled-path: no hardcoded ~/.claude/skills home path; sibling files via ${CLAUDE_PLUGIN_ROOT}
if grep -rqF '~/.claude/skills' "$SKILL_DIR"; then
  check "P7 no hardcoded ~/.claude/skills home path (use \${CLAUDE_PLUGIN_ROOT})" FAIL
else
  check "P7 no hardcoded ~/.claude/skills home path (bundled-path safe)" PASS
fi

# P8 — plugin.json skills[] registration
if jq -e '.skills | index("./skills/pr-team-review")' "$PLUGIN_JSON" >/dev/null 2>&1; then
  check "P8 plugin.json skills[] contains './skills/pr-team-review'" PASS
else
  check "P8 plugin.json skills[] contains './skills/pr-team-review'" FAIL
fi

# P9 — version sync across plugin.json, marketplace.json, README badge
MARKET_VERSION="$(jq -r '.plugins[0].version' "$MARKETPLACE_JSON" 2>/dev/null)"
if [ "$MARKET_VERSION" = "$EXPECTED_VERSION" ]; then
  check "P9a marketplace.json version ($MARKET_VERSION) == plugin.json ($EXPECTED_VERSION)" PASS
else
  check "P9a marketplace.json version ($MARKET_VERSION) == plugin.json ($EXPECTED_VERSION)" FAIL
fi

EXPECTED_VERSION_RE="$(printf '%s' "$EXPECTED_VERSION" | sed 's/[.]/\\./g')"
if grep -qE "version-${EXPECTED_VERSION_RE}-green" "$README_MD"; then
  check "P9b README badge shows version-$EXPECTED_VERSION-green" PASS
else
  check "P9b README badge shows version-$EXPECTED_VERSION-green" FAIL
fi

# P10 — README skills section: count bumped to 12 and the skill is listed
if grep -qF "### Skills (12)" "$README_MD"; then
  check "P10a README.md Skills section heading reads '### Skills (12)'" PASS
else
  check "P10a README.md Skills section heading reads '### Skills (12)'" FAIL
fi

if grep -qF "/zensu:pr-team-review" "$README_MD"; then
  check "P10b README.md mentions /zensu:pr-team-review in the skills table" PASS
else
  check "P10b README.md mentions /zensu:pr-team-review in the skills table" FAIL
fi

# P11 — per-run workspace must be race-safe (mirrors plan-review's P9 mktemp mandate).
# A predictable world-writable /tmp name invites a symlink / pre-creation race on
# shared hosts, so the working dir is materialized with `mktemp -d` and no fixed
# /tmp/pr* path may survive anywhere in the skill tree.
if grep -qF 'mktemp -d' "$SKILL_MD"; then
  check "P11a SKILL.md materializes the working dir with mktemp -d" PASS
else
  check "P11a SKILL.md materializes the working dir with mktemp -d" FAIL
fi

if grep -rqF '/tmp/pr' "$SKILL_DIR"; then
  check "P11b no predictable '/tmp/pr*' path remains (race-safe)" FAIL
else
  check "P11b no predictable '/tmp/pr*' path remains (race-safe)" PASS
fi

if grep -qF -- '--detach' "$SKILL_MD"; then
  check "P11c worktree is created detached (re-run never collides on the branch ref)" PASS
else
  check "P11c worktree is created detached (re-run never collides on the branch ref)" FAIL
fi

echo "----"
echo "test-pr-team-review-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
