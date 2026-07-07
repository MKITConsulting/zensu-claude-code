#!/bin/bash
set -u

# Structure test for the /zensu:plan-review skill.
# Pins: the skill exists as a single self-contained SKILL.md, follows the title-line
# convention, carries the orchestration essentials (TeamCreate, read-only mandate,
# default team size 6, the four core personas, the verdict enum), is English-only and
# stack-agnostic (no leaked stack names from any specific product), is registered in
# plugin.json, and that the version is in sync across plugin.json + marketplace.json +
# the README badge.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/plan-review"
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
  check "P1 skills/plan-review/SKILL.md exists" FAIL
  echo "----"
  echo "test-plan-review-skill: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "P1 skills/plan-review/SKILL.md exists" PASS

# P2 — namespaced H1 title + frontmatter name (drives invocation + auto-trigger)
if grep -qxF '# /zensu:plan-review' "$SKILL_MD"; then
  check "P2 SKILL.md has the namespaced H1 '# /zensu:plan-review'" PASS
else
  check "P2 SKILL.md has the namespaced H1 '# /zensu:plan-review'" FAIL
fi
if grep -qE '^name: *plan-review *$' "$SKILL_MD"; then
  check "P2b SKILL.md frontmatter declares 'name: plan-review'" PASS
else
  check "P2b SKILL.md frontmatter declares 'name: plan-review'" FAIL
fi

# P3 — orchestration essentials
if grep -qF 'TeamCreate' "$SKILL_MD"; then
  check "P3a SKILL.md references TeamCreate (team-spawn mechanism)" PASS
else
  check "P3a SKILL.md references TeamCreate" FAIL
fi

if grep -qiE 'read-only' "$SKILL_MD"; then
  check "P3b SKILL.md states the READ-ONLY validator mandate" PASS
else
  check "P3b SKILL.md states the READ-ONLY validator mandate" FAIL
fi

if grep -qiE 'default[^0-9]{0,15}6' "$SKILL_MD"; then
  check "P3c SKILL.md documents the default team size of 6" PASS
else
  check "P3c SKILL.md documents the default team size of 6" FAIL
fi

CORE_PERSONAS=(requirements-completeness feasibility-soundness testing-tdd devils-advocate)
for p in "${CORE_PERSONAS[@]}"; do
  if grep -qF "$p" "$SKILL_MD"; then
    check "P3d SKILL.md defines core persona '$p'" PASS
  else
    check "P3d SKILL.md defines core persona '$p'" FAIL
  fi
done

for v in 'go-with-changes' 'no-go'; do
  if grep -qF "$v" "$SKILL_MD"; then
    check "P3e SKILL.md output schema includes verdict '$v'" PASS
  else
    check "P3e SKILL.md output schema includes verdict '$v'" FAIL
  fi
done

# P4 — English-only + generic guard: these patterns MUST be ABSENT from SKILL.md
GERMAN_RE='revalidier|köpfig|prüf|änder|überarbeit|konsens|konvergenz'
if grep -qiE "$GERMAN_RE" "$SKILL_MD"; then
  check "P4a SKILL.md is English-only (found German tokens matching: $GERMAN_RE)" FAIL
else
  check "P4a SKILL.md is English-only (no German tokens)" PASS
fi

STACK_RE='pro-cloud|hermes|ppsharedlibrary|spring modulith|flyway|@require(tenant|global)|PPS-[0-9]'
if grep -qiE "$STACK_RE" "$SKILL_MD"; then
  check "P4b SKILL.md is stack-agnostic (found leaked stack names matching: $STACK_RE)" FAIL
else
  check "P4b SKILL.md is stack-agnostic (no leaked stack names)" PASS
fi

# P5 — plugin.json skills[] registration
if jq -e '.skills | index("./skills/plan-review")' "$PLUGIN_JSON" >/dev/null 2>&1; then
  check "P5 plugin.json skills[] contains './skills/plan-review'" PASS
else
  check "P5 plugin.json skills[] contains './skills/plan-review'" FAIL
fi

# P6 — version sync across plugin.json, marketplace.json, README badge
MARKET_VERSION="$(jq -r '.plugins[0].version' "$MARKETPLACE_JSON" 2>/dev/null)"
if [ "$MARKET_VERSION" = "$EXPECTED_VERSION" ]; then
  check "P6a marketplace.json version ($MARKET_VERSION) == plugin.json ($EXPECTED_VERSION)" PASS
else
  check "P6a marketplace.json version ($MARKET_VERSION) == plugin.json ($EXPECTED_VERSION)" FAIL
fi

EXPECTED_VERSION_RE="$(printf '%s' "$EXPECTED_VERSION" | sed 's/[.]/\\./g')"
if grep -qE "version-${EXPECTED_VERSION_RE}-green" "$README_MD"; then
  check "P6b README badge shows version-$EXPECTED_VERSION-green" PASS
else
  check "P6b README badge shows version-$EXPECTED_VERSION-green" FAIL
fi

# P8 — in-body command references use the namespaced form (no bare backticked `/plan-review`).
# A backtick immediately followed by /plan-review is the inline command reference; the /tmp
# / mktemp working-dir paths are inside a fenced code block and are NOT backtick-prefixed,
# so this uniquely catches a bare (non-namespaced) command ref.
if grep -qF '`/plan-review' "$SKILL_MD"; then
  check "P8 SKILL.md command refs are namespaced (found bare backticked '/plan-review')" FAIL
else
  check "P8 SKILL.md command refs are namespaced /zensu:plan-review (no bare command ref)" PASS
fi

# P9 — the per-run working dir is created unpredictably with mktemp -d (not a predictable /tmp path)
if grep -qF 'mktemp -d' "$SKILL_MD"; then
  check "P9 SKILL.md materializes the working dir with mktemp -d (no predictable /tmp path)" PASS
else
  check "P9 SKILL.md materializes the working dir with mktemp -d (no predictable /tmp path)" FAIL
fi

echo "----"
echo "test-plan-review-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
