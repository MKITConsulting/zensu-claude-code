#!/bin/bash
set -u

# Structure test for the /zensu:converge flow-back audit skill (P1-2).
# Pins: the skill exists with the namespaced H1 + frontmatter name; the
# read-only default, user-confirmation-before-edit, and never-auto-apply
# contracts; the gap taxonomy (missing/partial/contradicts/unrequested); the
# business-rule vs implementation-detail flow-back split; next-free-stable-ID
# allocation; the legacy-plan clean stop; plugin.json registration; README
# skills-table row + header count consistency (header N == table rows); the
# tdd chain-end offer; the autopilot pre-PR report-only bullet; the zensu-help
# routing row; and the e2e-skills scenario files. It intentionally does NOT
# assert version sync or hook counts — those are owned by sibling tests.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_MD="$PLUGIN_DIR/skills/converge/SKILL.md"
TDD_MD="$PLUGIN_DIR/skills/tdd/SKILL.md"
AUTOPILOT_MD="$PLUGIN_DIR/skills/autopilot/SKILL.md"
HELP_MD="$PLUGIN_DIR/skills/zensu-help/SKILL.md"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
README="$PLUGIN_DIR/README.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$SKILL_MD" "$TDD_MD" "$AUTOPILOT_MD" "$HELP_MD" "$PLUGIN_JSON" "$README"; do
  if [ ! -f "$f" ]; then
    check "P0 required file exists: $f" FAIL
    echo "----"
    echo "test-converge-skill: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "P0 all six target files exist" PASS

# P1 — identity: namespaced H1 + frontmatter name
if grep -qxF '# /zensu:converge' "$SKILL_MD"; then
  check "P1a namespaced H1 '# /zensu:converge'" PASS
else
  check "P1a namespaced H1 '# /zensu:converge'" FAIL
fi
if grep -qE '^name: *converge *$' "$SKILL_MD"; then
  check "P1b frontmatter declares 'name: converge'" PASS
else
  check "P1b frontmatter declares 'name: converge'" FAIL
fi

# P2 — contract pins
PINS=(
  "P2a read-only default|READ-ONLY by default"
  "P2b never touches production source|never modifies production source"
  "P2c user confirmation before edits|explicit user confirmation via AskUserQuestion"
  "P2d never auto-apply|Never auto-apply"
  "P2e non-interactive is report-only|REPORT-ONLY"
  "P2f legacy-plan clean stop|nothing to converge against"
  "P2g gap taxonomy missing|**missing**"
  "P2h gap taxonomy partial|**partial**"
  "P2i gap taxonomy contradicts|**contradicts**"
  "P2j gap taxonomy unrequested|**unrequested**"
  "P2k business-rule split|BUSINESS RULE"
  "P2l implementation-detail split|IMPLEMENTATION DETAIL"
  "P2m next-free stable ID allocation|free stable ID of that family"
  "P2n never recycle|never recycle"
  "P2o CV finding ids|CV-1"
  "P2p deprecated rows excluded|rows marked deprecated are EXCLUDED"
  "P2q converged verdict|**converged**"
)
for entry in "${PINS[@]}"; do
  label="${entry%%|*}"; needle="${entry#*|}"
  if grep -qF "$needle" "$SKILL_MD"; then
    check "$label" PASS
  else
    check "$label" FAIL
  fi
done

# P3 — integration points
if grep -qF '/zensu:converge' "$TDD_MD" && grep -qF 'offer only — never run it unasked' "$TDD_MD"; then
  check "P3a tdd chain-end offers converge (offer only)" PASS
else
  check "P3a tdd chain-end offers converge (offer only)" FAIL
fi
if grep -qF 'Converge (report-only)' "$AUTOPILOT_MD" && grep -qF 'blocks the PR open' "$AUTOPILOT_MD"; then
  check "P3b autopilot runs converge report-only pre-PR; contradicts blocks" PASS
else
  check "P3b autopilot runs converge report-only pre-PR; contradicts blocks" FAIL
fi
if grep -qF 'skills/converge/SKILL.md' "$HELP_MD"; then
  check "P3c zensu-help routes flow-back questions to converge" PASS
else
  check "P3c zensu-help routes flow-back questions to converge" FAIL
fi

# P4 — registration + README count consistency
if node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.exit(Array.isArray(p.skills)&&p.skills.indexOf("./skills/converge")!==-1?0:1)' "$PLUGIN_JSON" 2>/dev/null; then
  check "P4a plugin.json skills[] registers ./skills/converge" PASS
else
  check "P4a plugin.json skills[] registers ./skills/converge" FAIL
fi
if grep -qF '| `/zensu:converge` |' "$README"; then
  check "P4b README skills table carries the converge row" PASS
else
  check "P4b README skills table carries the converge row" FAIL
fi
HDR_N="$(grep -oE '^### Skills \([0-9]+\)' "$README" | grep -oE '[0-9]+' | head -1)"
ROW_N="$(awk '/^### Skills \(/{f=1;next} /^### /{f=0} f' "$README" | grep -cE '^\| `/zensu:[a-z-]+` \|')"
if [ -n "$HDR_N" ] && [ "$HDR_N" = "$ROW_N" ]; then
  check "P4c README skills header ($HDR_N) == table rows ($ROW_N)" PASS
else
  check "P4c README skills header ($HDR_N) == table rows ($ROW_N)" FAIL
fi

# P5 — e2e-skills scenario ships
if [ -f "$PLUGIN_DIR/tests/e2e-skills/prompts/converge.txt" ] && [ -f "$PLUGIN_DIR/tests/e2e-skills/expected/converge.pattern" ] && grep -qE '^make_converge[[:space:]]*$' "$PLUGIN_DIR/tests/e2e-skills/setup-fixtures.sh"; then
  check "P5 e2e-skills converge scenario ships (prompt/pattern/fixture)" PASS
else
  check "P5 e2e-skills converge scenario ships (prompt/pattern/fixture)" FAIL
fi

echo "----"
echo "test-converge-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
