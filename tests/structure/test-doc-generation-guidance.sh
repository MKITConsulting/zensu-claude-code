#!/bin/bash
set -u

# Structure test for the code-grounded documentation guidance.
# Regression guard for the bug where doc generation condensed
# get_doc_generation_context METADATA straight into wiki pages (a generic
# "metadata dump") instead of reading the real source and writing
# code-grounded docs. Pins the shared guide + the zensu-plm rule/workflow +
# the implement Step 6 + the ghost-scan note + the zensu-help routing that
# reference it, plus the explicit Read imperative in implement + zensu-plm, and
# the guide's feature_scope -> doc_type table as the one copy: the docs skill and
# implement Step 6 point at its heading, and no other Markdown file keeps a row.

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

# --- Required doc types: the guide owns the feature_scope table ---------------
SCOPE_TITLE='Required doc types (the release gate)'
D21_BAD=""
grep -qxF -- "## $SCOPE_TITLE" "$GUIDE" || D21_BAD="$D21_BAD missing:heading"
for row in '| unset (`null`, the default) | `user_facing` | `end_user` |' \
  '| `api` | `api_reference` | `developer` |' \
  '| `internal_only` | `adr` | `internal` |' \
  '| `public_facing` | `user_facing` — **plus** `tutorial` when `estimated_effort` ∈ {L, XL} |'; do
  grep -qF -- "$row" "$GUIDE" || D21_BAD="$D21_BAD missing-row:[$row]"
done
for rule in 'So the scope picks the type, not the security classification' \
  'a gate that requires docs reports `documentation must be complete before release`' \
  'A response without a `feature_scope` field counts as unset: author `user_facing`' \
  'note that the `tutorial` was skipped for lack of an effort signal' \
  'a type the table does not require for the scope never completes the gate' \
  'with a required doc type from the table above'; do
  printf '%s' "$NORM_GUIDE" | grep -qF -- "$rule" || D21_BAD="$D21_BAD missing-rule:[$rule]"
done
printf '%s' "$NORM_GUIDE" | grep -qF -- 'usually warrants `internal`' && D21_BAD="$D21_BAD picks-by-classification"
[ -z "$D21_BAD" ] && check "D21 guide owns the feature_scope -> doc_type table with its unset-scope and unknown-effort rules, and picks no type by classification" PASS \
  || check "D21 guide lost part of the feature_scope -> doc_type table:$D21_BAD" FAIL

NORM_DOCS="$(tr -s '[:space:]' ' ' < "$DOCS")"
NORM_STEP6="$(awk 'index($0, "### Step 6:") == 1 {p = 1} p && index($0, "### Step 7:") == 1 {exit} p' "$IMPLEMENT" | tr -s '[:space:]' ' ')"
D22_BAD=""
printf '%s' "$NORM_DOCS" | grep -qF -- "Read the table under \"$SCOPE_TITLE\" in" || D22_BAD="$D22_BAD docs"
printf '%s' "$NORM_STEP6" | grep -qF -- "The table under \"$SCOPE_TITLE\" in that guide" || D22_BAD="$D22_BAD implement-step6"
[ -z "$D22_BAD" ] && check "D22 the docs skill and implement Step 6 take the doc type from the guide's table by its heading" PASS \
  || check "D22 a doc-authoring skill no longer points at the guide's '$SCOPE_TITLE' heading:$D22_BAD" FAIL

# scope_rows DIR... — every Markdown line under DIR that is a feature_scope ->
# doc_type table row, the guide excepted.
SCOPE_ROW_RE='^\| *(unset[^|]*|`(default|api|internal_only|public_facing)`) *\| *`(user_facing|api_reference|adr|tutorial)`'
scope_rows() {
  grep -rnE --include='*.md' -- "$SCOPE_ROW_RE" "$@" 2>/dev/null | grep -vF -- "$GUIDE:"
}
D23_ROWS="$(scope_rows "$PLUGIN_DIR/skills" "$PLUGIN_DIR/agents" "$PLUGIN_DIR/docs")"
[ -z "$D23_ROWS" ] && check "D23 no skill, agent or other doc keeps its own feature_scope -> doc_type table" PASS \
  || { printf '%s\n' "$D23_ROWS" | sed 's/^/      /'; check "D23 a copy of the feature_scope -> doc_type table outside the guide" FAIL; }

D24_FIX="$(mktemp -d)"
mkdir -p "$D24_FIX/copy" "$D24_FIX/other"
printf '%s\n' '| `api` | `api_reference` | `developer` |' > "$D24_FIX/copy/SKILL.md"
printf '%s\n' '| `default` | `user_facing` | `end_user` |' > "$D24_FIX/copy/rules.md"
printf '%s\n' '| `api` | REST endpoints | `curl` |' '| `api` | status code, response body |' > "$D24_FIX/other/SKILL.md"
D24_COPY="$(scope_rows "$D24_FIX/copy" | wc -l | tr -d ' ')"
D24_OTHER="$(scope_rows "$D24_FIX/other" | wc -l | tr -d ' ')"
rm -rf "$D24_FIX"
[ "$D24_COPY" = 2 ] && [ "$D24_OTHER" = 0 ] && check "D24 the D23 scan flags a planted scope table row and leaves other api tables alone" PASS \
  || check "D24 the D23 scan missed a planted row or flagged another table (copy=$D24_COPY other=$D24_OTHER)" FAIL

echo "----"
echo "test-doc-generation-guidance: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
