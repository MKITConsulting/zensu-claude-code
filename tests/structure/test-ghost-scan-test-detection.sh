#!/bin/bash
set -u

# Structure test for the /zensu:ghost-scan test-file detection guidance.
# Regression guard for the bug where agents called ghost_scan with
# detectedTestFiles:[] and silently dropped every test->feature link.
# Pins: the skill names the detectedTestFiles array, documents the co-location
# globbing mechanic, carries a test-completeness quality rule, shows the candidate
# JSON shape, has a pre-submit self-check, documents the enrich_existing backfill
# path, and flags an all-zero Tests column in review; the zensu-plm agent mirrors
# the field requirement and the first-class-scan-data rule; both files are
# English-only; and the version is in sync across plugin.json + marketplace.json +
# the README badge with ghost-scan registered in plugin.json.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_MD="$PLUGIN_DIR/skills/ghost-scan/SKILL.md"
AGENT_MD="$PLUGIN_DIR/agents/zensu-plm.md"
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

# P1 — SKILL.md exists with the namespaced title
if [ ! -f "$SKILL_MD" ]; then
  check "P1 skills/ghost-scan/SKILL.md exists" FAIL
  echo "----"
  echo "test-ghost-scan-test-detection: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "P1 skills/ghost-scan/SKILL.md exists" PASS

if [ "$(head -1 "$SKILL_MD")" = "# /zensu:ghost-scan" ]; then
  check "P2 SKILL.md first line is exactly '# /zensu:ghost-scan'" PASS
else
  check "P2 SKILL.md first line is '# /zensu:ghost-scan'" FAIL
fi

# P3 — the detectedTestFiles array is named (the core fix: patterns alone were not enough)
if grep -qF 'detectedTestFiles' "$SKILL_MD"; then
  check "P3 SKILL.md names the detectedTestFiles array" PASS
else
  check "P3 SKILL.md names the detectedTestFiles array" FAIL
fi

# P4 — co-location globbing mechanic with the sibling test dirs
if grep -qiE 'co-located' "$SKILL_MD" && grep -qF '__tests__' "$SKILL_MD"; then
  check "P4 SKILL.md documents the co-location glob (sibling test dirs incl. __tests__)" PASS
else
  check "P4 SKILL.md documents the co-location glob (sibling test dirs incl. __tests__)" FAIL
fi

# P5 — test-completeness quality rule (mirror of the source-file rule)
if grep -qF 'Test-file completeness' "$SKILL_MD"; then
  check "P5 SKILL.md carries a test-file completeness quality rule" PASS
else
  check "P5 SKILL.md carries a test-file completeness quality rule" FAIL
fi

# P6 — Phase 3 candidate shape includes detectedTestFiles as a JSON key
if grep -qF '"detectedTestFiles":' "$SKILL_MD"; then
  check "P6 SKILL.md shows the candidate JSON shape with a detectedTestFiles key" PASS
else
  check "P6 SKILL.md shows the candidate JSON shape with a detectedTestFiles key" FAIL
fi

# P7 — pre-submit self-check that catches a zero test sum
if grep -qF 'Pre-submit self-check' "$SKILL_MD"; then
  check "P7 SKILL.md has the pre-submit self-check (zero-tests guard)" PASS
else
  check "P7 SKILL.md has the pre-submit self-check (zero-tests guard)" FAIL
fi

# P8 — backfill path via enrich_existing for a scan that already created features
if grep -qiF 'Backfilling' "$SKILL_MD" && grep -qF 'enrich_existing=true' "$SKILL_MD"; then
  check "P8 SKILL.md documents the enrich_existing=true backfill path" PASS
else
  check "P8 SKILL.md documents the enrich_existing=true backfill path" FAIL
fi

# P9 — Phase 4 review flags an all-zero Tests column
if grep -qF 'Scan the Tests column' "$SKILL_MD"; then
  check "P9 SKILL.md tells review to flag an all-zero Tests column" PASS
else
  check "P9 SKILL.md tells review to flag an all-zero Tests column" FAIL
fi

# P10 — agent zensu-plm.md mirrors the requirement
if grep -qF 'detectedTestFiles' "$AGENT_MD"; then
  check "P10a zensu-plm.md requires populating detectedTestFiles" PASS
else
  check "P10a zensu-plm.md requires populating detectedTestFiles" FAIL
fi

if grep -qF 'first-class scan data' "$AGENT_MD"; then
  check "P10b zensu-plm.md has the 'tests are first-class scan data' rule" PASS
else
  check "P10b zensu-plm.md has the 'tests are first-class scan data' rule" FAIL
fi

# P11 — English-only guard: high-signal German tokens (the source material was German) must be ABSENT
GERMAN_RE='Dateien|Verzeichnis|verlinkt|behebbar|Versäumnis|durchziehen|prüf|änder'
for f in "$SKILL_MD" "$AGENT_MD"; do
  if grep -qiE "$GERMAN_RE" "$f"; then
    check "P11 $(basename "$f") is English-only (found German tokens matching: $GERMAN_RE)" FAIL
  else
    check "P11 $(basename "$f") is English-only (no German tokens)" PASS
  fi
done

# P12 — plugin.json registers the ghost-scan skill
if jq -e '.skills | index("./skills/ghost-scan")' "$PLUGIN_JSON" >/dev/null 2>&1; then
  check "P12 plugin.json skills[] contains './skills/ghost-scan'" PASS
else
  check "P12 plugin.json skills[] contains './skills/ghost-scan'" FAIL
fi

# P13 — version sync across plugin.json, marketplace.json, README badge
MARKET_VERSION="$(jq -r '.plugins[0].version' "$MARKETPLACE_JSON" 2>/dev/null)"
if [ "$MARKET_VERSION" = "$EXPECTED_VERSION" ]; then
  check "P13a marketplace.json version ($MARKET_VERSION) == plugin.json ($EXPECTED_VERSION)" PASS
else
  check "P13a marketplace.json version ($MARKET_VERSION) == plugin.json ($EXPECTED_VERSION)" FAIL
fi

EXPECTED_VERSION_RE="$(printf '%s' "$EXPECTED_VERSION" | sed 's/[.]/\\./g')"
if grep -qE "version-${EXPECTED_VERSION_RE}-green" "$README_MD"; then
  check "P13b README badge shows version-$EXPECTED_VERSION-green" PASS
else
  check "P13b README badge shows version-$EXPECTED_VERSION-green" FAIL
fi

echo "----"
echo "test-ghost-scan-test-detection: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
