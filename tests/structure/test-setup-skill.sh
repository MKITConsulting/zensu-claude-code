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
MARKET_VERSION="$(jq -r '[.plugins[] | select(.name == "zensu")] | select(length == 1) | .[0].version' "$MARKETPLACE_JSON" 2>/dev/null)"
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
zc_names_install() {
  [ -n "$ZC_BREW" ] && [ -n "$ZC_SCRIPT" ] && [ -n "$ZC_PS" ] || return 1
  local escaped_script escaped_ps
  escaped_script="$(printf '%s' "$ZC_SCRIPT" | sed 's/|/\\|/')"
  escaped_ps="$(printf '%s' "$ZC_PS" | sed 's/|/\\|/')"
  grep -qF "$ZC_BREW" "$1" \
    && { grep -qF "$ZC_SCRIPT" "$1" || grep -qF "$escaped_script" "$1"; } \
    && { grep -qF "$ZC_PS" "$1" || grep -qF "$escaped_ps" "$1"; }
}
zc_names_all() {
  [ -n "$ZC_BREW_UP" ] && grep -qF "$ZC_BREW_UP" "$1" && zc_names_install "$1"
}
ZC_BANNER="$PLUGIN_DIR/hooks/session-start-banner.sh"
ZC_SITES_BAD=""
for zc_site in README.md docs/operations.md docs/cli-install-update.md skills/setup/SKILL.md; do
  zc_names_all "$PLUGIN_DIR/$zc_site" || ZC_SITES_BAD="$ZC_SITES_BAD $zc_site"
done
zc_names_install "$ZC_BANNER" && [ -n "$ZC_BREW_UP" ] && ! grep -qF -- "$ZC_BREW_UP" "$ZC_BANNER" && grep -qF 'INSTALL.homebrewUpgrade' "$ZC_BANNER" \
  || ZC_SITES_BAD="$ZC_SITES_BAD hooks/session-start-banner.sh"
[ -z "$ZC_SITES_BAD" ] && check "P10a README, the operations troubleshooting row, the CLI install guide and /zensu:setup name the module's install and upgrade commands; the banner names the install commands on its missing-CLI line and reads the upgrade command from the module" PASS \
  || check "P10a a site misses an install or upgrade command of the module, or the banner copies the upgrade command instead of reading it:$ZC_SITES_BAD" FAIL
if [ -n "$ZC_FLOOR" ] && [ "$(grep -cF "zensu-cli $ZC_FLOOR or later" "$README_MD")" -ge 2 ] \
  && grep -qF "older than $ZC_FLOOR" "$PLUGIN_DIR/docs/operations.md" && grep -qF "names zensu-cli $ZC_FLOOR" "$PLUGIN_DIR/docs/work-order-mode.md"; then
  check "P10b README Install and Requirements, the operations row and the work-order doc name the module's floor" PASS
else
  check "P10b README Install and Requirements, the operations row and the work-order doc name the module's floor" FAIL
fi
ZC_FULL="- Zensu CLI $ZC_FLOOR or later on \`PATH\`: \`$ZC_BREW\`, \`$ZC_SCRIPT\`, or on Windows \`$ZC_PS\`; upgrade with \`$ZC_BREW_UP\` or by running the installer again"
ZC_SKILLS_BAD=""
for zc_skill in bootstrap implement pulse security-review docs change; do
  grep -qF -- "$ZC_FULL" "$PLUGIN_DIR/skills/$zc_skill/SKILL.md" || ZC_SKILLS_BAD="$ZC_SKILLS_BAD $zc_skill"
done
grep -qF -- "- Zensu CLI $ZC_FLOOR or later on \`PATH\`; see \`/zensu:doctor\` for install/upgrade hints" "$PLUGIN_DIR/skills/ghost-scan/SKILL.md" || ZC_SKILLS_BAD="$ZC_SKILLS_BAD ghost-scan"
[ -n "$ZC_FLOOR" ] && [ -z "$ZC_SKILLS_BAD" ] && check "P10c the seven skill prerequisites name the module's floor; six name the install commands and ghost-scan, on the shrink-only body allowlist, names /zensu:doctor" PASS \
  || check "P10c a skill prerequisite does not match the module's floor or install commands:$ZC_SKILLS_BAD" FAIL
ZC_STALE="$(grep -lF 'Zensu CLI installed (`curl -fsSL https://zensu.dev/install.sh | sh`)' "$PLUGIN_DIR"/skills/*/SKILL.md 2>/dev/null | tr '\n' ' ')"
[ -z "$ZC_STALE" ] && check "P10d no skill keeps the curl-only install prerequisite" PASS || check "P10d a skill keeps the curl-only install prerequisite: $ZC_STALE" FAIL
ZC_REASON="$(node -e 'process.stdout.write(require(process.argv[1]).FLOOR_REASON)' "$ZC_MODULE" 2>/dev/null)"
if [ -n "$ZC_REASON" ] && ! grep -qF -- "$ZC_REASON" "$ZC_BANNER" && grep -qF 'FLOOR_REASON' "$ZC_BANNER" \
  && tr '\n' ' ' < "$README_MD" | grep -qF -- "$ZC_REASON" \
  && tr -s '[:space:]' ' ' < "$SKILL_MD" | grep -qF -- "$ZC_REASON"; then
  check "P10e the README Requirements and /zensu:setup Phase 0 state the module's reason for the floor, and the banner reads it from the module instead of copying it" PASS
else
  check "P10e the README Requirements and /zensu:setup Phase 0 state the module's reason for the floor, and the banner reads it from the module instead of copying it" FAIL
fi
ZC_OLD_BREW_UP='brew upgrade --cask zensu'
ZC_OLD_SITES="$(cd "$PLUGIN_DIR" || exit 2; grep -rlF -- "$ZC_OLD_BREW_UP" README.md docs skills hooks)"
ZC_OLD_RC=$?
if [ "$ZC_OLD_RC" -eq 1 ]; then
  check "P10f README, docs, skills and hooks hold no copy of the old Homebrew upgrade spelling '$ZC_OLD_BREW_UP'" PASS
else
  check "P10f the old Homebrew upgrade spelling '$ZC_OLD_BREW_UP' is back, or the scan failed (grep exit $ZC_OLD_RC): $(printf '%s' "$ZC_OLD_SITES" | tr '\n' ' ')" FAIL
fi
readme_section() {
  awk -v heading="$1" '
    $0 == heading { on = 1; next }
    on && /^##/ { exit }
    on
  ' "$README_MD" | tr -s '[:space:]' ' '
}
SELF_HOSTING="$(readme_section '### Self-hosting')"
TRUSTED_ROW="$(grep -F -- '| `ZENSU_TRUSTED_AUTH_HOSTS` | — | Comma-separated host names' "$PLUGIN_DIR/docs/configuration.md")"
if printf '%s' "$SELF_HOSTING" | grep -qF -- 'on a host named in `ZENSU_TRUSTED_AUTH_HOSTS`, a comma-separated list of host names, and never a plain `http://` endpoint under an `https://` API, not even on a listed host.' \
  && printf '%s' "$SELF_HOSTING" | grep -qF -- 'only when both sit on the API'"'"'s own origin' \
  && printf '%s' "$SELF_HOSTING" | grep -qF -- '`<api-url>/oauth/authorize` and `<api-url>/oauth/token`' \
  && printf '%s' "$SELF_HOSTING" | grep -qF -- 'export ZENSU_TRUSTED_AUTH_HOSTS=' \
  && [ "$(printf '%s\n' "$TRUSTED_ROW" | grep -c .)" -eq 1 ] \
  && printf '%s' "$TRUSTED_ROW" | grep -qF -- 'only on the API'"'"'s own origin (same host and port) or on a listed host' \
  && printf '%s' "$TRUSTED_ROW" | grep -qF -- 'never as a plain `http://` endpoint under an `https://` API' \
  && printf '%s' "$TRUSTED_ROW" | grep -qF -- '`<api-url>/oauth/authorize` and `<api-url>/oauth/token`'; then
  check "P11a README Self-hosting and the docs/configuration.md environment row document ZENSU_TRUSTED_AUTH_HOSTS with its origin rule, its https rule and the fallback endpoints" PASS
else
  check "P11a README Self-hosting or the docs/configuration.md environment row misses ZENSU_TRUSTED_AUTH_HOSTS, its origin rule, its https rule or the fallback endpoints" FAIL
fi
DATA_PRIVACY="$(readme_section '## Data & privacy')"
if printf '%s' "$DATA_PRIVACY" | grep -qF -- 'Commands you run yourself send what you hand them: `zensu plan push` sends the work plan it parses from your Markdown file' \
  && printf '%s' "$DATA_PRIVACY" | grep -qF -- '`zensu mocks create`, which `/zensu:change` also runs, uploads the mock file.'; then
  check "P11b README Data & privacy names what zensu plan push and zensu mocks create send" PASS
else
  check "P11b README Data & privacy does not name what zensu plan push and zensu mocks create send" FAIL
fi

echo "----"
echo "test-setup-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
