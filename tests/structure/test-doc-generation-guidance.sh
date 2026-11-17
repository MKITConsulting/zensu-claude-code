#!/bin/bash
set -u

# Structure test for the code-grounded documentation guidance.
# Regression guard for the bug where doc generation condensed
# get_doc_generation_context METADATA straight into wiki pages (a generic
# "metadata dump") instead of reading the real source and writing
# code-grounded docs. Pins the shared guide + the zensu-plm rule/workflow +
# the implement Step 6 + the ghost-scan note + the zensu-help routing that
# reference it, plus the explicit Read imperative in implement + zensu-plm.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUIDE="$PLUGIN_DIR/docs/documentation-guide.md"
PLM="$PLUGIN_DIR/agents/zensu-plm.md"
IMPLEMENT="$PLUGIN_DIR/skills/implement/SKILL.md"
GHOST="$PLUGIN_DIR/skills/ghost-scan/SKILL.md"
DOCS="$PLUGIN_DIR/skills/docs/SKILL.md"
ZENSUHELP="$PLUGIN_DIR/skills/zensu-help/SKILL.md"
READ_REF='Read `docs/documentation-guide.md`'
READ_REF_ABS='Read `${CLAUDE_PLUGIN_ROOT}/docs/documentation-guide.md`'

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

# --- explicit Read imperative + zensu-help routing ----------------------------
check "D15 implement Step 6 has explicit Read imperative" \
  "$(has "$IMPLEMENT" "$READ_REF_ABS")"
check "D16 zensu-plm has explicit Read imperative" \
  "$(has "$PLM" "$READ_REF")"
check "D17 zensu-help routes documentation questions to the guide" \
  "$(has "$ZENSUHELP" "docs/documentation-guide.md")"

# --- docs skill (the primary doc-authoring surface) ---------------------------
check "D18 docs skill references the shared guide" \
  "$(has "$DOCS" "docs/documentation-guide.md")"
check "D19 docs skill has explicit Read imperative" \
  "$(has "$DOCS" "$READ_REF_ABS")"

NORM_GUIDE="$(tr -s '[:space:]' ' ' < "$GUIDE")"
D20_BAD=""
for cli in 'zensu doc gen-context <feature-id> --doc-type <type>' 'zensu wiki list --product <id> --json' \
  'zensu wiki create --product <id> --title <title> --content-file <path>' 'zensu wiki update <page-id> --content-file <path>' \
  'zensu link docs <feature-id> --doc-type <type>'; do
  printf '%s' "$NORM_GUIDE" | grep -qF -- "$cli" || D20_BAD="$D20_BAD missing:[$cli]"
done
for tool in get_doc_generation_context list_wiki_pages create_wiki_page update_wiki_page link_docs MCP; do
  grep -qF -- "$tool" "$GUIDE" && D20_BAD="$D20_BAD names:$tool"
done
printf '%s' "$NORM_GUIDE" | grep -qF -- 'Create never changes an existing page' || D20_BAD="$D20_BAD missing:create-only-rule"
printf '%s' "$NORM_GUIDE" | grep -qF -- 'zensu-cli sends this create-only request (`createOnly`) from 0.12.0 on, so every zensu-cli the plugin supports sends it.' || D20_BAD="$D20_BAD missing:createOnly-release"
VERSION_MODULE="$PLUGIN_DIR/hooks/lib/zensu-cli-version-v1.js"
node -e 'const [major, minor] = require(process.argv[1]).MIN_VERSION.split(".").map(Number); process.exit(major > 0 || minor >= 12 ? 0 : 1)' "$VERSION_MODULE" || D20_BAD="$D20_BAD floor-below:0.12.0"
FLOOR="$(node -p 'require(process.argv[1]).MIN_VERSION' "$VERSION_MODULE")"
[ -n "$FLOOR" ] && ! grep -qF -- "$FLOOR" "$GUIDE" || D20_BAD="$D20_BAD copies-floor:${FLOOR:-unread}"
[ -z "$D20_BAD" ] && check "D20 guide names its procedure and commands in zensu CLI terms, keeps the create-only rule with the first zensu-cli release that sends it, holds that release below the floor without copying the floor, and names no MCP tool" PASS \
  || check "D20 guide drifts from the zensu CLI terms or the create-only rule:$D20_BAD" FAIL

echo "----"
echo "test-doc-generation-guidance: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
