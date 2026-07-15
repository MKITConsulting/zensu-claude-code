#!/bin/bash
set -u

# Structure test for the /zensu:setup skill.
# Pins: the skill exists as a single self-contained SKILL.md with the namespaced
# title line + frontmatter name (so it is invocable + auto-triggerable), documents
# the curated config keys it configures, asks via AskUserQuestion, writes via a
# preserving deep-merge to either the global or project-local config.json, checks
# auth via the zensu CLI, is English-only, uses the namespaced command form, leaks
# no ~/.claude/skills home path, is registered in plugin.json, and keeps the version
# in sync across plugin.json + marketplace.json + the README badge.
# It intentionally does NOT assert the shared README "### Skills (N)" heading — that
# count is owned by the sibling skill tests (self-review / zensu-help /
# reset-review-limit); like autopilot / pr-fix-findings, this skill is not added to
# that table, so the count stays 12.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/setup"
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
  check "P1 skills/setup/SKILL.md exists" FAIL
  echo "----"
  echo "test-setup-skill: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "P1 skills/setup/SKILL.md exists" PASS

# P2 — namespaced H1 title + frontmatter name (drive invocation + auto-trigger)
if grep -qxF '# /zensu:setup' "$SKILL_MD"; then
  check "P2a SKILL.md has the namespaced H1 '# /zensu:setup'" PASS
else
  check "P2a SKILL.md has the namespaced H1 '# /zensu:setup'" FAIL
fi
if grep -qE '^name: *setup *$' "$SKILL_MD"; then
  check "P2b SKILL.md frontmatter declares 'name: setup'" PASS
else
  check "P2b SKILL.md frontmatter declares 'name: setup'" FAIL
fi

# P3 — configures the curated keys via the documented mechanisms.
# Indexed "label|needle" pairs (bash 3.2-safe — no declare -A).
ESSENTIALS=(
  "P3a curated key hooks.tddImplementation|tddImplementation"
  "P3b curated key hooks.chainEnforcer|chainEnforcer"
  "P3b2 curated key hooks.autopilotEnforcer|autopilotEnforcer"
  "P3c curated key hooks.autoFixMaxRounds|autoFixMaxRounds"
  "P3d curated key context.compactionNudge|compactionNudge"
  "P3e curated key context.nudgeThreshold|nudgeThreshold"
  "P3f curated key hooks.pulseSession|pulseSession"
  "P3g curated key logging.timestampStyle|timestampStyle"
  "P3h asks via AskUserQuestion|AskUserQuestion"
  "P3i preserving deep-merge|deep-merge"
  "P3j global target path|\$HOME/.zensu/config.json"
  "P3k project-local target path|CLAUDE_PROJECT_DIR"
  "P3l auth status check|zensu auth status"
)
for entry in "${ESSENTIALS[@]}"; do
  label="${entry%%|*}"; needle="${entry#*|}"
  if grep -qF "$needle" "$SKILL_MD"; then
    check "$label" PASS
  else
    check "$label" FAIL
  fi
done

# P4 — English-only guard: German tokens MUST be ABSENT.
GERMAN_RE='revalidier|köpfig|prüf|änder|überarbeit|konsens|konvergenz'
if grep -qiE "$GERMAN_RE" "$SKILL_MD"; then
  check "P4 SKILL.md is English-only (found German tokens matching: $GERMAN_RE)" FAIL
else
  check "P4 SKILL.md is English-only (no German tokens)" PASS
fi

# P5 — command refs are namespaced: a backtick-prefixed bare '/setup' must be ABSENT
if grep -qF '`/setup' "$SKILL_MD"; then
  check "P5 command refs are namespaced (found bare backticked '/setup')" FAIL
else
  check "P5 command refs are namespaced /zensu:setup (no bare command ref)" PASS
fi

# P6 — bundled-path: no hardcoded ~/.claude/skills home path
if grep -qF '~/.claude/skills' "$SKILL_MD"; then
  check "P6 no hardcoded ~/.claude/skills home path" FAIL
else
  check "P6 no hardcoded ~/.claude/skills home path (bundled-path safe)" PASS
fi

# P7 — plugin.json skills[] registration
if jq -e '.skills | index("./skills/setup")' "$PLUGIN_JSON" >/dev/null 2>&1; then
  check "P7 plugin.json skills[] contains './skills/setup'" PASS
else
  check "P7 plugin.json skills[] contains './skills/setup'" FAIL
fi

# P8 — version stays in sync across plugin.json + marketplace.json + README badge.
# Adding a skill does NOT bump the version; this guards against accidental drift.
MARKET_VERSION="$(jq -r '.plugins[0].version' "$MARKETPLACE_JSON" 2>/dev/null)"
if [ "$MARKET_VERSION" = "$EXPECTED_VERSION" ]; then
  check "P8a marketplace.json version ($MARKET_VERSION) == plugin.json ($EXPECTED_VERSION)" PASS
else
  check "P8a marketplace.json version ($MARKET_VERSION) == plugin.json ($EXPECTED_VERSION)" FAIL
fi
EXPECTED_VERSION_RE="$(printf '%s' "$EXPECTED_VERSION" | sed 's/[.]/\\./g')"
if grep -qE "version-${EXPECTED_VERSION_RE}-green" "$README_MD"; then
  check "P8b README badge shows version-$EXPECTED_VERSION-green" PASS
else
  check "P8b README badge shows version-$EXPECTED_VERSION-green" FAIL
fi

echo "----"
echo "test-setup-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
