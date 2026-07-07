#!/bin/bash
set -u

# Structure test for the /zensu:docs skill.
# Pins: the skill exists with its SKILL.md, follows the namespaced title-line +
# frontmatter convention, is workflow-wrapped (the write-gate marker) and declares
# exactly the doc mutations it runs, carries the docs_complete contract (the three
# hard rules), the feature_scope -> doc_type mapping, the read-source-first
# code-grounding discipline (references the shared guide + the forbidden metadata
# dump), the batch read-only Explore fan-out, docs_complete verification, no silent
# truncation, is English-only, uses the namespaced command form, leaks no
# ~/.claude/skills home path, and is registered in plugin.json.
# Deliberately bash-3.2 compatible: no associative arrays (macOS /bin/bash is 3.2).

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/docs"
SKILL_MD="$SKILL_DIR/SKILL.md"
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

# D1 — SKILL.md exists
if [ ! -f "$SKILL_MD" ]; then
  check "D1 skills/docs/SKILL.md exists" FAIL
  echo "----"
  echo "test-docs-skill: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "D1 skills/docs/SKILL.md exists" PASS

# D2 — namespaced H1 title + frontmatter name (drives invocation + auto-trigger)
if grep -qxF '# /zensu:docs' "$SKILL_MD"; then
  check "D2a SKILL.md has the namespaced H1 '# /zensu:docs'" PASS
else
  check "D2a SKILL.md has the namespaced H1 '# /zensu:docs'" FAIL
fi
if grep -qE '^name: *docs *$' "$SKILL_MD"; then
  check "D2b SKILL.md frontmatter declares 'name: docs'" PASS
else
  check "D2b SKILL.md frontmatter declares 'name: docs'" FAIL
fi

# D3 — workflow-wrapped: BOTH markers present (the write-gate recognition the
# skill-workflow-markers guard requires for a mutating skill).
if grep -qF -- '--workflow-begin' "$SKILL_MD" && grep -qF -- '--workflow-end' "$SKILL_MD"; then
  check "D3 SKILL.md is workflow-wrapped (--workflow-begin + --workflow-end)" PASS
else
  check "D3 SKILL.md is workflow-wrapped (--workflow-begin + --workflow-end)" FAIL
fi

# D4 — the --tools declaration names exactly the one doc mutation the skill runs.
pin "D4 workflow --tools declares the doc mutation" "$SKILL_MD" '--tools "link_docs"'

# D5 — the docs_complete contract: the three hard rules.
pin "D5a contract: fresh (require_fresh / is_outdated)" "$SKILL_MD" "is_outdated"
pin "D5b contract: not over-shared (shared_doc_max / <= 3 features)" "$SKILL_MD" "shared_doc_max"
pin "D5c contract: one doc PER feature" "$SKILL_MD" "one doc PER feature"

# D6 — feature_scope -> doc_type mapping (all four scopes + the tutorial rule).
pin "D6a maps feature_scope" "$SKILL_MD" "feature_scope"
pin "D6b default -> user_facing" "$SKILL_MD" "user_facing"
pin "D6c api -> api_reference row" "$SKILL_MD" '`api` | `api_reference`'
pin "D6d internal_only -> adr row" "$SKILL_MD" '`internal_only` | `adr`'
pin "D6e public_facing tutorial rule keys on estimated_effort" "$SKILL_MD" "estimated_effort"

# D7 — the CLI mechanics: gen-context (context map) + link docs (publish + recompute).
pin "D7a reads the gen-context map" "$SKILL_MD" "zensu doc gen-context"
pin "D7b links + recomputes via zensu link docs" "$SKILL_MD" "zensu link docs"
pin "D7c verifies the gate via features get docs_complete" "$SKILL_MD" "zensu features get"

# D8 — code-grounding discipline: references the shared guide with the explicit
# Read imperative, and names the forbidden metadata-dump anti-pattern.
pin "D8a references docs/documentation-guide.md" "$SKILL_MD" "docs/documentation-guide.md"
pin "D8b has explicit Read imperative" "$SKILL_MD" 'Read `docs/documentation-guide.md`'
pin "D8c forbids the metadata-dump anti-pattern" "$SKILL_MD" "metadata dump"

# D9 — batch fan-out is a READ-ONLY Explore pass (mutations stay on the main thread).
pin "D9a batch authoring fans out to Explore agents" "$SKILL_MD" "subagent_type: Explore"
pin "D9b batch authoring agents perform no Zensu writes" "$SKILL_MD" "performs NO Zensu writes"

# D10 — idempotency + no silent truncation.
pin "D10a idempotent: skips features already complete" "$SKILL_MD" "Skip every feature already"
pin "D10b no silent truncation of the batch" "$SKILL_MD" "silent truncation"

# D11 — English-only guard: German tokens MUST be ABSENT.
GERMAN_RE='revalidier|köpfig|prüf|änder|überarbeit|dokument|erstell|funktion'
if grep -rqiE "$GERMAN_RE" "$SKILL_DIR"; then
  check "D11 skill is English-only (found German tokens matching: $GERMAN_RE)" FAIL
else
  check "D11 skill is English-only (no German tokens)" PASS
fi

# D12 — command refs are namespaced: a backtick-prefixed bare '/docs' must be ABSENT.
if grep -rqF '`/docs' "$SKILL_DIR"; then
  check "D12 command refs are namespaced (found bare backticked '/docs')" FAIL
else
  check "D12 command refs are namespaced /zensu:docs (no bare command ref)" PASS
fi

# D13 — bundled-path: no hardcoded ~/.claude/skills home path.
if grep -rqF '~/.claude/skills' "$SKILL_DIR"; then
  check "D13 no hardcoded ~/.claude/skills home path" FAIL
else
  check "D13 no hardcoded ~/.claude/skills home path (bundled-path safe)" PASS
fi

# D14 — plugin.json skills[] registration.
if jq -e '.skills | index("./skills/docs")' "$PLUGIN_JSON" >/dev/null 2>&1; then
  check "D14 plugin.json skills[] contains './skills/docs'" PASS
else
  check "D14 plugin.json skills[] contains './skills/docs'" FAIL
fi

# D15/D16 — high-value invariants: the repo-file per-feature path rule (the
# antidote to the shared-README false-green) and the Phase 5 verify step.
pin "D15 repo-file mode uses a unique per-feature path" "$SKILL_MD" "docs/features/<KEY-N>-<slug>.md"
pin "D16 Phase 5 verifies the gate flipped" "$SKILL_MD" "Verify the gate flipped"

echo "----"
echo "test-docs-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
