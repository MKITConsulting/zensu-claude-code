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

ZC_MODULE="$PLUGIN_DIR/hooks/lib/zensu-cli-version-v1.js"
ZC_FLOOR="$(node -e 'process.stdout.write(require(process.argv[1]).MIN_VERSION)' "$ZC_MODULE" 2>/dev/null)"
PILOT_MD="$PLUGIN_DIR/skills/pilot/SKILL.md"
if [ -n "$ZC_FLOOR" ] && grep -qF 'node "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-cli-version-v1.js" --lookup' "$SKILL_MD" \
  && grep -qF '`state=old`' "$SKILL_MD" && grep -qF "zensu-cli $ZC_FLOOR or later" "$SKILL_MD" && grep -qF 'Warn only: continue either way.' "$SKILL_MD"; then
  check "P9a Phase 0 checks the version floor through the version module and only warns" PASS
else
  check "P9a Phase 0 checks the version floor through the version module and only warns" FAIL
fi
if grep -qF 'prints `Not logged in` (it exits 0' "$SKILL_MD"; then
  check "P9b Phase 1 treats Not logged in on exit 0 as not authenticated" PASS
else
  check "P9b Phase 1 treats Not logged in on exit 0 as not authenticated" FAIL
fi
if grep -qF 'or printing `Not logged in`' "$PILOT_MD"; then
  check "P9c /zensu:pilot treats Not logged in from zensu auth status as not authenticated" PASS
else
  check "P9c /zensu:pilot treats Not logged in from zensu auth status as not authenticated" FAIL
fi
if grep -qF 'On `cwd-relative`' "$SKILL_MD" && grep -qF 'skip Phase 1, because' "$SKILL_MD" && grep -qF '`absent` (the shell found' "$SKILL_MD"; then
  check "P9d Phase 0 skips Phase 1 when PATH reaches zensu through a relative entry, and names the absent state" PASS
else
  check "P9d Phase 0 skips Phase 1 when PATH reaches zensu through a relative entry, and names the absent state" FAIL
fi

ZC_FACTS="$(node -e 'const m = require(process.argv[1]); process.stdout.write([m.INSTALL.homebrew, m.INSTALL.homebrewUpgrade, m.INSTALL.script, m.INSTALL.powershell].join("\n"))' "$ZC_MODULE" 2>/dev/null)"
ZC_BREW="$(printf '%s\n' "$ZC_FACTS" | sed -n 1p)"
ZC_BREW_UP="$(printf '%s\n' "$ZC_FACTS" | sed -n 2p)"
ZC_SCRIPT="$(printf '%s\n' "$ZC_FACTS" | sed -n 3p)"
ZC_PS="$(printf '%s\n' "$ZC_FACTS" | sed -n 4p)"
zc_names_all() {
  [ -n "$ZC_BREW" ] && [ -n "$ZC_BREW_UP" ] && [ -n "$ZC_SCRIPT" ] && [ -n "$ZC_PS" ] || return 1
  local escaped_script escaped_ps
  escaped_script="$(printf '%s' "$ZC_SCRIPT" | sed 's/|/\\|/')"
  escaped_ps="$(printf '%s' "$ZC_PS" | sed 's/|/\\|/')"
  grep -qF "$ZC_BREW" "$1" && grep -qF "$ZC_BREW_UP" "$1" \
    && { grep -qF "$ZC_SCRIPT" "$1" || grep -qF "$escaped_script" "$1"; } \
    && { grep -qF "$ZC_PS" "$1" || grep -qF "$escaped_ps" "$1"; }
}
ZC_SITES_BAD=""
for zc_site in README.md docs/operations.md skills/setup/SKILL.md hooks/session-start-banner.sh; do
  zc_names_all "$PLUGIN_DIR/$zc_site" || ZC_SITES_BAD="$ZC_SITES_BAD $zc_site"
done
[ -z "$ZC_SITES_BAD" ] && check "P10a README, the operations troubleshooting row, /zensu:setup and the banner name the module's install and upgrade commands" PASS \
  || check "P10a an install or upgrade command of the module is missing from:$ZC_SITES_BAD" FAIL
if [ -n "$ZC_FLOOR" ] && [ "$(grep -cF "zensu-cli $ZC_FLOOR or later" "$README_MD")" -ge 2 ] \
  && grep -qF "older than $ZC_FLOOR" "$PLUGIN_DIR/docs/operations.md" && grep -qF "names zensu-cli $ZC_FLOOR" "$PLUGIN_DIR/docs/work-order-mode.md"; then
  check "P10b README Install and Requirements, the operations row and the work-order doc name the module's floor" PASS
else
  check "P10b README Install and Requirements, the operations row and the work-order doc name the module's floor" FAIL
fi
ZC_FULL="- Zensu CLI $ZC_FLOOR or later on \`PATH\`: \`$ZC_BREW\`, \`$ZC_SCRIPT\`, or on Windows \`$ZC_PS\`; upgrade with \`$ZC_BREW_UP\` or by running the installer again"
ZC_SKILLS_BAD=""
for zc_skill in bootstrap implement pulse security-review docs; do
  grep -qF -- "$ZC_FULL" "$PLUGIN_DIR/skills/$zc_skill/SKILL.md" || ZC_SKILLS_BAD="$ZC_SKILLS_BAD $zc_skill"
done
grep -qF -- "- Zensu CLI $ZC_FLOOR or later on \`PATH\`; see \`/zensu:doctor\` for install/upgrade hints" "$PLUGIN_DIR/skills/ghost-scan/SKILL.md" || ZC_SKILLS_BAD="$ZC_SKILLS_BAD ghost-scan"
[ -n "$ZC_FLOOR" ] && [ -z "$ZC_SKILLS_BAD" ] && check "P10c the six skill prerequisites name the module's floor; five name the install commands and ghost-scan, on the shrink-only body allowlist, names /zensu:doctor" PASS \
  || check "P10c a skill prerequisite does not match the module's floor or install commands:$ZC_SKILLS_BAD" FAIL
ZC_STALE="$(grep -lF 'Zensu CLI installed (`curl -fsSL https://zensu.dev/install.sh | sh`)' "$PLUGIN_DIR"/skills/*/SKILL.md 2>/dev/null | tr '\n' ' ')"
[ -z "$ZC_STALE" ] && check "P10d no skill keeps the curl-only install prerequisite" PASS || check "P10d a skill keeps the curl-only install prerequisite: $ZC_STALE" FAIL
ZC_REASON="$(node -e 'process.stdout.write(require(process.argv[1]).FLOOR_REASON)' "$ZC_MODULE" 2>/dev/null)"
if [ -n "$ZC_REASON" ] && grep -qF -- "$ZC_REASON" "$PLUGIN_DIR/hooks/session-start-banner.sh" && tr '\n' ' ' < "$README_MD" | grep -qF -- "$ZC_REASON"; then
  check "P10e the banner and the README Requirements state the module's reason for the floor" PASS
else
  check "P10e the banner and the README Requirements state the module's reason for the floor" FAIL
fi

echo "----"
echo "test-setup-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
