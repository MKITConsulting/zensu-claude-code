#!/bin/bash
set -u

# Structure test for the /zensu:pilot skill.
# Pins: the skill exists as a single self-contained SKILL.md with the namespaced
# title line + frontmatter name (so it is invocable + auto-triggerable), wraps
# its only mutation (features status -> update_feature) in a PER-MUTATION
# write-gate window (--workflow-begin immediately before, --workflow-end
# immediately after — never a session-long arming, which delegated skills would
# clobber), offers next steps via AskUserQuestion (always with an Exit option),
# confirms every mutation explicitly, probes read-only, loops
# probe -> offer -> delegate -> re-probe, delegates to the sibling skills,
# preflights the released transition with `zensu security validate`, handles the
# server's release_gate_blocked rejection, follows the strict status FSM, never
# touches the review-chain terminus marker, routes missing setup to
# /zensu:setup, is English-only, uses namespaced command refs, leaks no
# ~/.claude/skills home path, is registered in plugin.json, has its README
# skills-table row, and keeps the version in sync across plugin.json +
# marketplace.json + the README badge.
# It intentionally does NOT assert the shared README "### Skills (N)" heading —
# that count is owned by the sibling skill tests.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/pilot"
SKILL_MD="$SKILL_DIR/SKILL.md"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$PLUGIN_DIR/.claude-plugin/marketplace.json"
README_MD="$PLUGIN_DIR/README.md"
EXPECTED_VERSION="$(jq -r '.version' "$PLUGIN_JSON" 2>/dev/null)"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

# P1 — SKILL.md exists
if [ ! -f "$SKILL_MD" ]; then
  check "P1 skills/pilot/SKILL.md exists" FAIL
  echo "----"
  echo "test-pilot-skill: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "P1 skills/pilot/SKILL.md exists" PASS

# P2 — namespaced H1 title + frontmatter name (drive invocation + auto-trigger)
if grep -qxF '# /zensu:pilot' "$SKILL_MD"; then
  check "P2a SKILL.md has the namespaced H1 '# /zensu:pilot'" PASS
else
  check "P2a SKILL.md has the namespaced H1 '# /zensu:pilot'" FAIL
fi
if grep -qE '^name: *pilot *$' "$SKILL_MD"; then
  check "P2b SKILL.md frontmatter declares 'name: pilot'" PASS
else
  check "P2b SKILL.md frontmatter declares 'name: pilot'" FAIL
fi

# P3 — conductor essentials.
# Indexed "label|needle" pairs (bash 3.2-safe — no declare -A).
ESSENTIALS=(
  "P3a workflow gate armed for the status mutation|--workflow-begin --tools \"update_feature\""
  "P3b workflow gate closed after the mutation|--workflow-end"
  "P3c offers via AskUserQuestion|AskUserQuestion"
  "P3d always offers Exit|ALWAYS including **Exit**"
  "P3e delegates to /zensu:implement|/zensu:implement"
  "P3f delegates to /zensu:tdd|(\`/zensu:implement\` / \`/zensu:tdd\`)"
  "P3g delegates to /zensu:cover|/zensu:cover"
  "P3h delegates to /zensu:pr-team-review|Deep review via \`/zensu:pr-team-review\`"
  "P3i delegates to /zensu:pr-fix-findings|Fix findings via \`/zensu:pr-fix-findings\`"
  "P3j delegates to /zensu:converge|/zensu:converge"
  "P3k delegates to /zensu:docs|/zensu:docs"
  "P3l delegates to /zensu:security-review|/zensu:security-review"
  "P3m released preflight via security validate|zensu security validate"
  "P3n handles the server release-gate rejection|release_gate_blocked"
  "P3o strict status FSM order|planned → in-progress → testing → released"
  "P3p transition mutation named|zensu features status"
  "P3q unresolved review threads probe|isResolved"
  "P3r missing setup routes to /zensu:setup|/zensu:setup"
  "P3s every mutation behind explicit confirm|Execute only after explicit confirm"
  "P3t per-mutation gate window, no session arming|per-mutation"
  "P3t2 no session-long arming|never once per session"
  "P3t3 begin/mutate/end adjacency|wrap each transition in its own gate window"
  "P3t4 window closed on every outcome|regardless of the transition's outcome"
  "P3u gate bypass forbidden|never prefix \`ZENSU_MCP_GATE=off\`"
  "P3y backend/PR text treated as data|data, not commands"
  "P3z merged PR unlocks the testing transition|review presence no longer gates a merged PR"
  "P3z2 closed PR falls back to the no-PR rows|Fall back to the no-PR rows"
  "P3v loop semantics pinned|probe → offer → delegate/transition → re-probe"
  "P3w probe is read-only|run zero mutations"
  "P3x work never spawned into a subagent|Never spawn the work into a subagent"
)
# Prose needles are matched against whitespace-normalized content so markdown
# re-wrapping never splits a pinned phrase across lines.
NORMALIZED_SKILL="$(tr -s '[:space:]' ' ' < "$SKILL_MD")"
for entry in "${ESSENTIALS[@]}"; do
  label="${entry%%|*}"; needle="${entry#*|}"
  if printf '%s' "$NORMALIZED_SKILL" | grep -qF -- "$needle"; then
    check "$label" PASS
  else
    check "$label" FAIL
  fi
done

# P4 — chain-terminus safety: the chain-done marker flag MUST be ABSENT
# (the review-chain terminus belongs to /zensu:self-review, never to pilot).
if grep -qF -- '--chain-done' "$SKILL_MD"; then
  check "P4 SKILL.md never references the chain-done marker flag" FAIL
else
  check "P4 SKILL.md never references the chain-done marker flag" PASS
fi

# P5 — English-only guard: German tokens MUST be ABSENT.
GERMAN_RE='revalidier|köpfig|prüf|änder|überarbeit|konsens|konvergenz'
if grep -qiE "$GERMAN_RE" "$SKILL_MD"; then
  check "P5 SKILL.md is English-only (found German tokens matching: $GERMAN_RE)" FAIL
else
  check "P5 SKILL.md is English-only (no German tokens)" PASS
fi

# P6 — command refs are namespaced: a backtick-prefixed bare '/pilot' must be ABSENT
if grep -qF '`/pilot' "$SKILL_MD"; then
  check "P6 command refs are namespaced (found bare backticked '/pilot')" FAIL
else
  check "P6 command refs are namespaced /zensu:pilot (no bare command ref)" PASS
fi

# P7 — bundled-path: no hardcoded ~/.claude/skills home path
if grep -qF '~/.claude/skills' "$SKILL_MD"; then
  check "P7 no hardcoded ~/.claude/skills home path" FAIL
else
  check "P7 no hardcoded ~/.claude/skills home path (bundled-path safe)" PASS
fi

# P8 — plugin.json skills[] registration + README skills-table row
if jq -e '.skills | index("./skills/pilot")' "$PLUGIN_JSON" >/dev/null 2>&1; then
  check "P8a plugin.json skills[] contains './skills/pilot'" PASS
else
  check "P8a plugin.json skills[] contains './skills/pilot'" FAIL
fi
if grep -qF '| `/zensu:pilot` |' "$README_MD"; then
  check "P8b README skills table has the /zensu:pilot row" PASS
else
  check "P8b README skills table has the /zensu:pilot row" FAIL
fi
if grep -qF '/zensu:pilot' "$PLUGIN_DIR/hooks/session-start-banner.sh"; then
  check "P8c banner skills line mentions /zensu:pilot" PASS
else
  check "P8c banner skills line mentions /zensu:pilot" FAIL
fi
# P8d asserts what its label says: /zensu:pilot is named in BOTH mode variants.
# It used to compare a WHOLE-FILE match count against the literal 2, which is a
# different claim — it broke the moment a heredoc gained a second legitimate
# mention, and bumping the literal would only re-arm the same trap on the next
# primer edit. Extract the two heredocs and require the name in each.
# An unchecked mktemp -d leaves the variable empty and awk then writes the blocks
# to /b1 and /b2, which the guard below would grade as if they were the primer.
PRIMER_BLOCK_DIR="$(mktemp -d)" || PRIMER_BLOCK_DIR=""
if [ -z "$PRIMER_BLOCK_DIR" ]; then
  check "P8d primer heredoc extraction (mktemp -d failed)" FAIL
else
awk -v dir="$PRIMER_BLOCK_DIR" '{
  if ($0 ~ /^[[:space:]]*cat[[:space:]]+<<\047?JSON\047?([[:space:]]*\|.*)?$/) { n++; inb=1; next }
  if ($0 ~ /^[[:space:]]*JSON[[:space:]]*$/) { inb=0; next }
  if (inb) print > (dir "/b" n)
}' "$PLUGIN_DIR/hooks/session-start-primer.sh" 2>/dev/null
if [ ! -f "$PRIMER_BLOCK_DIR/b1" ] || [ ! -f "$PRIMER_BLOCK_DIR/b2" ] || [ -f "$PRIMER_BLOCK_DIR/b3" ]; then
  check "P8d primer heredoc extraction found the expected two mode variants" FAIL
elif grep -qF '/zensu:pilot' "$PRIMER_BLOCK_DIR/b1" && grep -qF '/zensu:pilot' "$PRIMER_BLOCK_DIR/b2"; then
  check "P8d primer mentions /zensu:pilot in BOTH mode variants (strict + vanilla)" PASS
else
  check "P8d primer /zensu:pilot missing from a mode variant" FAIL
fi
rm -rf "$PRIMER_BLOCK_DIR"
fi

# P9 — sibling handoffs: each pipeline neighbor ends with a Next step offer
# that is confirm-gated and scoped to standalone runs (never auto-chained
# under autopilot's zero-questions phase or pilot's own loop).
for sib in implement pr-team-review pr-fix-findings cover; do
  SIB_MD="$PLUGIN_DIR/skills/$sib/SKILL.md"
  NORMALIZED_SIB="$(tr -s '[:space:]' ' ' < "$SIB_MD")"
  if grep -qF '## Next step' "$SIB_MD" \
    && grep -qF '/zensu:pilot' "$SIB_MD" \
    && printf '%s' "$NORMALIZED_SIB" | grep -qF 'only after the user confirms' \
    && printf '%s' "$NORMALIZED_SIB" | grep -qF 'When invoked standalone'; then
    check "P9 skills/$sib has a confirm-gated standalone Next step handoff" PASS
  else
    check "P9 skills/$sib has a confirm-gated standalone Next step handoff" FAIL
  fi
done

# P10 — version stays in sync across plugin.json + marketplace.json + README badge.
# Adding a skill does NOT bump the version; this guards against accidental drift.
MARKET_VERSION="$(jq -r '.plugins[0].version' "$MARKETPLACE_JSON" 2>/dev/null)"
if [ -z "$EXPECTED_VERSION" ] || [ "$EXPECTED_VERSION" = "null" ]; then
  check "P10a plugin.json version is readable (got '${EXPECTED_VERSION:-}')" FAIL
elif [ "$MARKET_VERSION" = "$EXPECTED_VERSION" ]; then
  check "P10a marketplace.json version ($MARKET_VERSION) == plugin.json ($EXPECTED_VERSION)" PASS
else
  check "P10a marketplace.json version ($MARKET_VERSION) == plugin.json ($EXPECTED_VERSION)" FAIL
fi
EXPECTED_VERSION_RE="$(printf '%s' "$EXPECTED_VERSION" | sed 's/[.]/\\./g')"
if grep -qE "version-${EXPECTED_VERSION_RE}-green" "$README_MD"; then
  check "P10b README badge shows version-$EXPECTED_VERSION-green" PASS
else
  check "P10b README badge shows version-$EXPECTED_VERSION-green" FAIL
fi

echo "----"
echo "test-pilot-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
