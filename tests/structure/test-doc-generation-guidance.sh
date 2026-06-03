#!/bin/bash
set -u

# Structure test for the code-grounded documentation guidance.
# Regression guard for the bug where doc generation condensed
# get_doc_generation_context METADATA straight into wiki pages (a generic
# "metadata dump") instead of reading the real source and writing
# code-grounded docs. Pins the shared guide + the zensu-plm rule/workflow +
# the implement Step 6 + the ghost-scan note that reference it.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUIDE="$PLUGIN_DIR/docs/documentation-guide.md"
PLM="$PLUGIN_DIR/agents/zensu-plm.md"
IMPLEMENT="$PLUGIN_DIR/skills/implement/SKILL.md"
GHOST="$PLUGIN_DIR/skills/ghost-scan/SKILL.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
has() { [ -f "$1" ] && grep -qF "$2" "$1" && echo PASS || echo FAIL; }

# --- The shared guide ---------------------------------------------------------
if [ ! -f "$GUIDE" ]; then
  check "D1 docs/documentation-guide.md exists" FAIL
  echo "----"; echo "test-doc-generation-guidance: $PASS PASS / $FAIL FAIL"; exit 1
fi
check "D1 docs/documentation-guide.md exists" PASS

if [ "$(head -1 "$GUIDE")" = "# Documentation Guide" ]; then
  check "D2 guide first line is '# Documentation Guide'" PASS
else
  check "D2 guide first line is '# Documentation Guide'" FAIL
fi

# All 8 canonical doc types named in the guide
DOC_TYPES=(user_facing api_reference tutorial adr release_notes internal migration_guide overview)
missing_types=0
for t in "${DOC_TYPES[@]}"; do
  grep -qF "\`$t\`" "$GUIDE" || missing_types=$((missing_types+1))
done
if [ "$missing_types" -eq 0 ]; then
  check "D3 guide names all 8 canonical doc types" PASS
else
  check "D3 guide names all 8 canonical doc types ($missing_types missing)" FAIL
fi

check "D4 guide names the forbidden metadata-dump anti-pattern" "$(has "$GUIDE" "metadata dump")"
check "D5 guide states map-not-territory (read real source)" "$(has "$GUIDE" "map, not the territory")"
check "D6 guide has a read-source-first procedure" "$(has "$GUIDE" "read-source-first")"
check "D7 guide has a quality checklist" "$(has "$GUIDE" "Quality checklist")"
check "D8 guide notes /docs/generate is frontend-only (not MCP)" "$(has "$GUIDE" "frontend-only")"

# --- zensu-plm agent ----------------------------------------------------------
check "D9 zensu-plm Important Rule: code-grounded, never a metadata dump" \
  "$(has "$PLM" "Documentation is code-grounded, never a metadata dump")"
check "D10 zensu-plm has 'When the user wants documentation' workflow" \
  "$(has "$PLM" "### When the user wants documentation")"
check "D11 zensu-plm references the shared guide" \
  "$(has "$PLM" "docs/documentation-guide.md")"

# --- implement skill ----------------------------------------------------------
check "D12 implement Step 6 is code-grounded Documentation" \
  "$(has "$IMPLEMENT" "### Step 6: Documentation")"
check "D13 implement Step 6 references the shared guide" \
  "$(has "$IMPLEMENT" "docs/documentation-guide.md")"

# --- ghost-scan skill ---------------------------------------------------------
check "D14 ghost-scan references the shared guide for authoring docs" \
  "$(has "$GHOST" "docs/documentation-guide.md")"

echo "----"
echo "test-doc-generation-guidance: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
