#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/zensu-help"
SKILL_MD="$SKILL_DIR/SKILL.md"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$PLUGIN_DIR/.claude-plugin/marketplace.json"
README_MD="$PLUGIN_DIR/README.md"
CHANGELOG_MD="$PLUGIN_DIR/CHANGELOG.md"
EXPECTED_VERSION="$(jq -r '.version' "$PLUGIN_JSON")"
EXPECTED_VERSION_RE="$(printf '%s' "$EXPECTED_VERSION" | sed 's/[.]/\\./g')"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$SKILL_MD" ]; then
  check "S1 skills/zensu-help/SKILL.md exists" FAIL
  echo "----"
  echo "test-zensu-help-skill: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "S1 skills/zensu-help/SKILL.md exists" PASS

if grep -qxF '# /zensu:zensu-help' "$SKILL_MD"; then
  check "S2 SKILL.md has the namespaced H1 '# /zensu:zensu-help'" PASS
else
  check "S2 SKILL.md has the namespaced H1 '# /zensu:zensu-help'" FAIL
fi
if grep -qE '^name: *zensu-help *$' "$SKILL_MD"; then
  check "S2b SKILL.md frontmatter declares 'name: zensu-help'" PASS
else
  check "S2b SKILL.md frontmatter declares 'name: zensu-help'" FAIL
fi

REQUIRED_SECTIONS=(
  "## When to Use"
  "## Do NOT Use For"
  "## Core Glossary"
  "## Three Layers"
  "## Topic Routing"
  "## Response Style"
)
for section in "${REQUIRED_SECTIONS[@]}"; do
  if grep -qF "$section" "$SKILL_MD"; then
    check "S3 SKILL.md contains section heading '$section'" PASS
  else
    check "S3 SKILL.md contains section heading '$section'" FAIL
  fi
done

if [ ! -f "$PLUGIN_JSON" ]; then
  check "S4 .claude-plugin/plugin.json exists" FAIL
  echo "----"
  echo "test-zensu-help-skill: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "S4 .claude-plugin/plugin.json exists" PASS

if jq -e '.skills | index("./skills/zensu-help")' "$PLUGIN_JSON" >/dev/null 2>&1; then
  check "S5 plugin.json skills[] contains './skills/zensu-help'" PASS
else
  check "S5 plugin.json skills[] contains './skills/zensu-help'" FAIL
fi

PLUGIN_VERSION="$(jq -r '.version' "$PLUGIN_JSON" 2>/dev/null)"
MARKETPLACE_VERSION="$(jq -r '.plugins[0].version' "$MARKETPLACE_JSON" 2>/dev/null)"

if [ "$PLUGIN_VERSION" = "$EXPECTED_VERSION" ]; then
  check "S6 plugin.json .version == $EXPECTED_VERSION (got: $PLUGIN_VERSION)" PASS
else
  check "S6 plugin.json .version == $EXPECTED_VERSION (got: $PLUGIN_VERSION)" FAIL
fi

if [ "$MARKETPLACE_VERSION" = "$EXPECTED_VERSION" ]; then
  check "S7 marketplace.json .plugins[0].version == $EXPECTED_VERSION (got: $MARKETPLACE_VERSION)" PASS
else
  check "S7 marketplace.json .plugins[0].version == $EXPECTED_VERSION (got: $MARKETPLACE_VERSION)" FAIL
fi

if [ "$PLUGIN_VERSION" = "$MARKETPLACE_VERSION" ] && [ -n "$PLUGIN_VERSION" ]; then
  check "S8 plugin.json .version == marketplace.json .plugins[0].version (cross-file invariant)" PASS
else
  check "S8 plugin.json .version ($PLUGIN_VERSION) == marketplace.json .plugins[0].version ($MARKETPLACE_VERSION)" FAIL
fi

if [ -f "$README_MD" ] && grep -qF "version-${EXPECTED_VERSION}-green" "$README_MD"; then
  check "S9 README.md version badge contains $EXPECTED_VERSION" PASS
else
  check "S9 README.md version badge contains $EXPECTED_VERSION" FAIL
fi

if [ -f "$README_MD" ] && grep -qE '^### Skills \([0-9]+\)$' "$README_MD"; then
  check "S10 README.md has a '### Skills (N)' heading (count owned by test-converge-skill P4c)" PASS
else
  check "S10 README.md has a '### Skills (N)' heading (count owned by test-converge-skill P4c)" FAIL
fi

if [ -f "$README_MD" ] && grep -qF "/zensu:zensu-help" "$README_MD"; then
  check "S11 README.md mentions /zensu:zensu-help in the skills table" PASS
else
  check "S11 README.md mentions /zensu:zensu-help in the skills table" FAIL
fi

if [ -f "$CHANGELOG_MD" ] && grep -qE "^## \[${EXPECTED_VERSION_RE}\] - [0-9]{4}-[0-9]{2}-[0-9]{2}" "$CHANGELOG_MD"; then
  check "S12 CHANGELOG.md has '## [${EXPECTED_VERSION}] - <date>' section" PASS
else
  check "S12 CHANGELOG.md has '## [${EXPECTED_VERSION}] - <date>' section" FAIL
fi

echo "----"
echo "test-zensu-help-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
