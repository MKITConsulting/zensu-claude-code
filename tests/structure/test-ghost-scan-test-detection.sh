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

# P14 — SKILL.md documents the multi-perspective fan-out (parallel read-only Explore lenses)
if grep -qiE 'fan-out' "$SKILL_MD" && grep -qF 'Explore' "$SKILL_MD"; then
  check "P14 SKILL.md documents the multi-perspective fan-out (Explore agents)" PASS
else
  check "P14 SKILL.md documents the multi-perspective fan-out (Explore agents)" FAIL
fi

# P15 — adaptive lens count (explicit cap 12 + size thresholds) + no-silent-caps logging
if grep -qiE 'adaptive' "$SKILL_MD" && grep -qiE 'cap[ -]?12' "$SKILL_MD" && grep -qF '> 500' "$SKILL_MD" && grep -qiF 'No silent caps' "$SKILL_MD"; then
  check "P15 SKILL.md documents adaptive lens count (cap 12 + thresholds) + no-silent-caps log" PASS
else
  check "P15 SKILL.md documents adaptive lens count (cap 12 + thresholds) + no-silent-caps log" FAIL
fi

# P16 — journey discovery phase creates journeys after apply
if grep -qF 'create_user_journey' "$SKILL_MD" && grep -qF 'create_journey_step' "$SKILL_MD"; then
  check "P16 SKILL.md journey phase calls create_user_journey + create_journey_step" PASS
else
  check "P16 SKILL.md journey phase calls create_user_journey + create_journey_step" FAIL
fi

# P17 — journey health analysis on the created journeys
if grep -qF 'analyze_journey_health' "$SKILL_MD"; then
  check "P17 SKILL.md runs analyze_journey_health on created journeys" PASS
else
  check "P17 SKILL.md runs analyze_journey_health on created journeys" FAIL
fi

# P18 — doc-file completeness quality rule (mirror of the test-file rule)
if grep -qF 'Doc-file completeness' "$SKILL_MD"; then
  check "P18 SKILL.md carries a doc-file completeness quality rule" PASS
else
  check "P18 SKILL.md carries a doc-file completeness quality rule" FAIL
fi

# P19 — pre-submit self-check sums detectedDocFiles too (not only tests)
if grep -qiE 'sum .*detectedTestFiles.*and.*detectedDocFiles' "$SKILL_MD"; then
  check "P19 SKILL.md pre-submit self-check sums detectedDocFiles too" PASS
else
  check "P19 SKILL.md pre-submit self-check sums detectedDocFiles too" FAIL
fi

# P20 — Phase 4 review flags an all-zero Docs column
if grep -qF 'Scan the Docs column' "$SKILL_MD"; then
  check "P20 SKILL.md tells review to flag an all-zero Docs column" PASS
else
  check "P20 SKILL.md tells review to flag an all-zero Docs column" FAIL
fi

# P21 — Phase 6 doc-gap report names the report and routes zero-doc features to /zensu:implement
if grep -qiF 'Doc-gap report' "$SKILL_MD" && grep -qiF 'zero docs' "$SKILL_MD" && grep -qF '/zensu:implement' "$SKILL_MD"; then
  check "P21 SKILL.md Phase 6 doc-gap report flags zero-doc features -> /zensu:implement" PASS
else
  check "P21 SKILL.md Phase 6 doc-gap report flags zero-doc features -> /zensu:implement" FAIL
fi

# P22a — zensu-plm.md mirrors the ghost-scan multi-perspective fan-out
if grep -qiE 'fan-out|multi-perspective' "$AGENT_MD"; then
  check "P22a zensu-plm.md mirrors the ghost-scan fan-out" PASS
else
  check "P22a zensu-plm.md mirrors the ghost-scan fan-out" FAIL
fi

# P22b — zensu-plm.md ghost-scan workflow discovers user journeys
if grep -qF 'discover user journeys' "$AGENT_MD"; then
  check "P22b zensu-plm.md ghost-scan workflow discovers user journeys" PASS
else
  check "P22b zensu-plm.md ghost-scan workflow discovers user journeys" FAIL
fi

# P22c — zensu-plm.md mirrors first-class docs (detectedDocFiles) in ghost-scan
if grep -qF 'detectedDocFiles' "$AGENT_MD"; then
  check "P22c zensu-plm.md requires populating detectedDocFiles" PASS
else
  check "P22c zensu-plm.md requires populating detectedDocFiles" FAIL
fi

# P23-P26 — e2e behavioral-contract pattern + prompt assert journeys, docs, fan-out
PATTERN_FILE="$PLUGIN_DIR/tests/e2e-plm/expected/ghost-scan.pattern"
PROMPT_TXT="$PLUGIN_DIR/tests/e2e-plm/prompts/ghost-scan.txt"

if grep -qF 'create_user_journey' "$PATTERN_FILE"; then
  check "P23 ghost-scan.pattern asserts journey creation" PASS
else
  check "P23 ghost-scan.pattern asserts journey creation" FAIL
fi

if grep -qiE 'detectedDocFiles|link_docs' "$PATTERN_FILE"; then
  check "P24 ghost-scan.pattern asserts first-class docs" PASS
else
  check "P24 ghost-scan.pattern asserts first-class docs" FAIL
fi

if grep -qiE 'fan-out|parallel|Explore' "$PATTERN_FILE"; then
  check "P25 ghost-scan.pattern asserts multi-perspective fan-out" PASS
else
  check "P25 ghost-scan.pattern asserts multi-perspective fan-out" FAIL
fi

if grep -qiF 'journey' "$PROMPT_TXT"; then
  check "P26 ghost-scan.txt prompt invites journey discovery" PASS
else
  check "P26 ghost-scan.txt prompt invites journey discovery" FAIL
fi

# P27 — journeys are created AFTER ghost_apply (feature IDs exist only post-apply)
if grep -qiE 'after .{0,4}ghost_apply|after apply' "$SKILL_MD"; then
  check "P27 SKILL.md pins journey creation after ghost_apply" PASS
else
  check "P27 SKILL.md pins journey creation after ghost_apply" FAIL
fi

# P28 — Phase 5b removed: the ghost-scan SKILL no longer drives a client-side create_revision baseline (now minted server-side by ghost_apply, zensu-monorepo #266)
if grep -qF 'create_revision' "$SKILL_MD"; then
  check "P28 SKILL.md has no client create_revision (baseline is server-side)" FAIL
else
  check "P28 SKILL.md has no client create_revision (baseline is server-side)" PASS
fi

# P29 — agent mirrors the removal: no ghost-scan client-baseline step or rule
if grep -qiE 'Seat each discovered feature|Discovered features get a build-out baseline' "$AGENT_MD"; then
  check "P29 zensu-plm.md has no ghost-scan client-baseline step/rule" FAIL
else
  check "P29 zensu-plm.md has no ghost-scan client-baseline step/rule" PASS
fi

echo "----"
echo "test-ghost-scan-test-detection: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
