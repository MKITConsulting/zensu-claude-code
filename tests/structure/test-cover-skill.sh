#!/bin/bash
set -u

# Structure test for the /zensu:cover skill.
# Pins: the skill exists with its SKILL.md + four rules files, follows the namespaced
# title-line + frontmatter convention, carries the decision brain (the level matrix + the
# five heuristics), states the green-first + report-only coverage semantics, reuses the
# Zensu review chain (review-aspect fan-out + code-reviewer), documents the --from-acs
# autopilot seam, is English-only, uses the namespaced command form, leaks no
# ~/.claude/skills home path, and is registered in plugin.json.
# It intentionally does NOT assert the shared README "### Skills (N)" heading — that count
# is owned by the older sibling skill tests; coupling this test to it would break this test
# on every future skill addition (see the note in test-autopilot-skill.sh).
# Deliberately bash-3.2 compatible: no associative arrays (macOS /bin/bash is 3.2).

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/cover"
SKILL_MD="$SKILL_DIR/SKILL.md"
LEVELS_MD="$SKILL_DIR/rules/levels.md"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

# pin LABEL FILE NEEDLE — PASS iff NEEDLE (fixed string) is present in FILE.
pin() {
  if grep -qF -- "$3" "$2"; then check "$1" PASS; else check "$1" FAIL; fi
}

# pin_tree LABEL NEEDLE — PASS iff NEEDLE (fixed string, case-insensitive) is present
# anywhere in the skill tree.
pin_tree() {
  if grep -rqiF -- "$2" "$SKILL_DIR"; then check "$1" PASS; else check "$1" FAIL; fi
}

# P1 — SKILL.md exists
if [ ! -f "$SKILL_MD" ]; then
  check "P1 skills/cover/SKILL.md exists" FAIL
  echo "----"
  echo "test-cover-skill: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "P1 skills/cover/SKILL.md exists" PASS

# P2 — the four rules files ship alongside the skill
for r in levels probe drivers quality; do
  if [ -f "$SKILL_DIR/rules/$r.md" ]; then
    check "P2 skills/cover/rules/$r.md exists" PASS
  else
    check "P2 skills/cover/rules/$r.md exists" FAIL
  fi
done

# P3 — namespaced H1 title + frontmatter name (drives invocation + auto-trigger)
if grep -qxF '# /zensu:cover' "$SKILL_MD"; then
  check "P3a SKILL.md has the namespaced H1 '# /zensu:cover'" PASS
else
  check "P3a SKILL.md has the namespaced H1 '# /zensu:cover'" FAIL
fi
if grep -qE '^name: *cover *$' "$SKILL_MD"; then
  check "P3b SKILL.md frontmatter declares 'name: cover'" PASS
else
  check "P3b SKILL.md frontmatter declares 'name: cover'" FAIL
fi

# P4 — the decision brain: the level matrix + the five heuristics live in levels.md
pin "P4a levels.md carries the decision matrix" "$LEVELS_MD" "## The decision matrix"
pin "P4b lowest-faithful-level heuristic" "$LEVELS_MD" "Lowest-faithful-level"
pin "P4c pyramid-budget heuristic" "$LEVELS_MD" "Pyramid budget"
pin "P4d no-duplication heuristic" "$LEVELS_MD" "No-duplication"
pin "P4e faithfulness/mutation heuristic" "$LEVELS_MD" "Faithfulness / mutation"
pin "P4f coverage-mode inversion heuristic" "$LEVELS_MD" "Coverage-mode inversion"

# P5 — coverage semantics: green-first + report-only, stated in the skill tree
pin_tree "P5a skill states green-first coverage semantics" "green-first"
pin_tree "P5b skill states report-only bug handling" "report-only"

# P6 — reuses the Zensu review chain (fan-out aspects + consolidating reviewer)
pin "P6a SKILL.md reuses the zensu:review-aspect fan-out" "$SKILL_MD" "zensu:review-aspect"
pin "P6b SKILL.md consolidates via zensu:code-reviewer" "$SKILL_MD" "zensu:code-reviewer"
pin "P6c SKILL.md drives review in-thread without arming the phase-gate" "$SKILL_MD" "does not arm the phase-gate"

# P7 — the --from-acs autopilot seam is documented
pin_tree "P7 skill documents the --from-acs autopilot seam" "--from-acs"

# P8 — the five workflow phase sections are present (anchored to the headings)
P8OK=1
for p in "Phase 0" "Phase 1" "Phase 2" "Phase 3" "Phase 4"; do
  grep -qF "### $p —" "$SKILL_MD" || P8OK=0
done
if [ "$P8OK" -eq 1 ]; then
  check "P8 SKILL.md documents Phases 0-4" PASS
else
  check "P8 SKILL.md documents Phases 0-4" FAIL
fi

# P9 — English-only guard: German tokens MUST be ABSENT across the skill tree.
GERMAN_RE='revalidier|köpfig|prüf|änder|überarbeit|konsens|konvergenz'
if grep -rqiE "$GERMAN_RE" "$SKILL_DIR"; then
  check "P9 skill is English-only (found German tokens matching: $GERMAN_RE)" FAIL
else
  check "P9 skill is English-only (no German tokens)" PASS
fi

# P10 — command refs are namespaced: a backtick-prefixed bare '/cover' must be ABSENT
if grep -rqF '`/cover' "$SKILL_DIR"; then
  check "P10 command refs are namespaced (found bare backticked '/cover')" FAIL
else
  check "P10 command refs are namespaced /zensu:cover (no bare command ref)" PASS
fi

# P11 — bundled-path: no hardcoded ~/.claude/skills home path
if grep -rqF '~/.claude/skills' "$SKILL_DIR"; then
  check "P11 no hardcoded ~/.claude/skills home path" FAIL
else
  check "P11 no hardcoded ~/.claude/skills home path (bundled-path safe)" PASS
fi

# P12 — plugin.json skills[] registration
if jq -e '.skills | index("./skills/cover")' "$PLUGIN_JSON" >/dev/null 2>&1; then
  check "P12 plugin.json skills[] contains './skills/cover'" PASS
else
  check "P12 plugin.json skills[] contains './skills/cover'" FAIL
fi

echo "----"
echo "test-cover-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
