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
# routing row; each of the three chain-end carriers of that offer, region-scoped
# where the region matters — the self-review `## Open` section (the carrier a
# Stop-hook-forced terminal stage still sees), the tdd step-10 bullet, and the
# selfReview-off combined-summary directive in post-review-tdd-delegate.sh; and
# the e2e-skills scenario files. Pins are stated per carrier, not as a
# cross-carrier equality. The self-review report contracts the offer sits beside
# (pipe escaping, the unrunnable-cross-check verdict) are owned by
# test-self-review-skill.sh V22-V24, not here. It intentionally does NOT assert version sync or hook
# counts — those are owned by sibling tests.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_MD="$PLUGIN_DIR/skills/converge/SKILL.md"
TDD_MD="$PLUGIN_DIR/skills/tdd/SKILL.md"
SELF_REVIEW_MD="$PLUGIN_DIR/skills/self-review/SKILL.md"
POST_REVIEW_HOOK="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
WORKFLOW_DOC="$PLUGIN_DIR/docs/tdd-manager-workflow.md"
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

TARGET_FILES=("$SKILL_MD" "$TDD_MD" "$SELF_REVIEW_MD" "$POST_REVIEW_HOOK" "$AUTOPILOT_MD" "$HELP_MD" "$PLUGIN_JSON" "$README")
for f in "${TARGET_FILES[@]}"; do
  if [ ! -f "$f" ]; then
    check "P0 required file exists: $f" FAIL
    echo "----"
    echo "test-converge-skill: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
if [ "${#TARGET_FILES[@]}" = 8 ]; then
  check "P0 all 8 target files exist" PASS
else
  check "P0 target file list changed (${#TARGET_FILES[@]} entries, expected 8) — update this count deliberately" FAIL
fi

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
if [ "$(grep -cF 'Optional next step: /zensu:converge' "$TDD_MD")" = 1 ]; then
  check "P3a tdd carries the offer line exactly once (no stray duplicate outside step 10)" PASS
else
  check "P3a tdd carries the offer line exactly once (no stray duplicate outside step 10)" FAIL
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
if [ "$(grep -cxF '## Open' "$SELF_REVIEW_MD")" = 1 ] && [ "$(grep -cxF '## TL;DR' "$SELF_REVIEW_MD")" = 1 ]; then
  check "P3danchor self-review report block has exactly one ## Open and one ## TL;DR anchor" PASS
else
  check "P3danchor self-review report block has exactly one ## Open and one ## TL;DR anchor" FAIL
fi
region_has() {
  if [ "$#" -ne 3 ] || [ -z "$3" ]; then check "$1 (empty or missing needle)" FAIL; return; fi
  case "$2" in *"$3"*) check "$1" PASS ;; *) check "$1" FAIL ;; esac
}
nonempty_region() {
  if [ -n "$2" ]; then check "$1" PASS; else check "$1" FAIL; fi
}

OFFER_LINE='Optional next step: /zensu:converge — flow-back audit of the code against the plan'"'"'s Requirements table.'

OPEN_FLAT="$(awk '/^## Open$/{f=1} /^## TL;DR$/{if(f) exit} f' "$SELF_REVIEW_MD" | tr '\n' ' ' | tr -s ' ')"
nonempty_region "P3d.0 self-review ## Open region resolves non-empty" "$OPEN_FLAT"
region_has "P3d.1 ## Open carries the exact offer line" "$OPEN_FLAT" "$OFFER_LINE"
region_has "P3d.2 ## Open states the offer-only contract" "$OPEN_FLAT" 'offer only — never run it unasked'
region_has "P3d.3 ## Open scopes the offer to a standalone handoff" "$OPEN_FLAT" 'for a STANDALONE handoff only'
region_has "P3d.4 ## Open states the offer never gates the terminus" "$OPEN_FLAT" 'never gates, delays, or precedes the `--chain-done` terminus'
region_has "P3d.5 ## Open omits the offer for an Autopilot-bound handoff" "$OPEN_FLAT" 'Omit the line entirely for an Autopilot-bound handoff'
region_has "P3d.6 ## Open omits the offer without a Requirements table" "$OPEN_FLAT" 'when the session plan carries no `## Requirements`'
region_has "P3d.7 ## Open carries the bypass-ledger disclosure" "$OPEN_FLAT" 'Gates bypassed during this session:'
region_has "P3d.8 ## Open renders the ledger unconditionally" "$OPEN_FLAT" 'in both cases — whether or not the table has rows'
region_has "P3d.9 ## Open gives every evidence line its own row" "$OPEN_FLAT" 'one row per `EVIDENCE GAP` / `EVIDENCE CONTRADICTION` line'
OPEN_HEAD="${OPEN_FLAT%%Optional next step:*}"
if [ "$OPEN_HEAD" = "$OPEN_FLAT" ]; then
  check "P3d.10 ## Open orders the ledger before the offer (offer line absent)" FAIL
else
  region_has "P3d.10 ## Open orders the ledger before the offer" "$OPEN_HEAD" 'Gates bypassed during this session:'
fi

TDD_STEP10_FLAT="$(awk '/\*\*Close implementation and trigger the review chain\.\*\*/{f=1;next} f&&/^(#+ |[0-9]+\. \*\*)/{exit} f' "$TDD_MD" | tr '\n' ' ' | tr -s ' ')"
nonempty_region "P3e.0 tdd step-10 region resolves non-empty" "$TDD_STEP10_FLAT"
region_has "P3e.1 tdd step-10 states the offer-only contract" "$TDD_STEP10_FLAT" 'offer only — never run it unasked'
region_has "P3e.2 tdd step-10 carries the exact offer line" "$TDD_STEP10_FLAT" "$OFFER_LINE"
region_has "P3e.3 tdd step-10 suppresses the offer for a bound chain in EVERY selfReview setting" "$TDD_STEP10_FLAT" 'Never render it for an Autopilot-bound chain in any `hooks.selfReview` setting'
region_has "P3e.4 tdd step-10 defers rendering to self-review" "$TDD_STEP10_FLAT" 'renders that offer in its `## Open` section'
region_has "P3e.5 tdd step-10 ties suppression to the combined-summary directive" "$TDD_STEP10_FLAT" 'The offer travels only inside the combined-summary directive'
region_has "P3e.5a tdd step-10 names the zero-change branch as the one non-flag exception" "$TDD_STEP10_FLAT" 'the zero-change branch, which closes the chain without a report'
region_has "P3e.8 tdd step-10 places the offer after the chain closes" "$TDD_STEP10_FLAT" 'After the chain closes'
region_has "P3e.6 tdd step-10 states the Requirements-table condition" "$TDD_STEP10_FLAT" 'when the session plan carries a `## Requirements` table'
region_has "P3e.7 tdd step-10 forbids rendering the offer in a non-terminal fix round" "$TDD_STEP10_FLAT" 'never render it in a non-terminal fix round'


HOOK_OFFER="$(grep -F 'CONVERGE_OFFER_DIRECTIVE=$' "$POST_REVIEW_HOOK")"
HOOK_SUMMARY="$(grep -F 'COMBINED_SUMMARY_DIRECTIVE=$' "$POST_REVIEW_HOOK")"
nonempty_region "P3f.0 hook converge-offer directive line resolves non-empty" "$HOOK_OFFER"
OFFER_HEAD="${OFFER_LINE%%\'*}"
OFFER_TAIL="${OFFER_LINE#*\'}"
HOOK_OFFER_NEEDLE="${OFFER_HEAD}\\'${OFFER_TAIL}"
region_has "P3f.1 hook offer directive carries the exact offer line, derived from OFFER_LINE" "$HOOK_OFFER" "$HOOK_OFFER_NEEDLE"
region_has "P3f.2 hook offer directive scopes to a standalone chain" "$HOOK_OFFER" 'for a STANDALONE chain only and never for an Autopilot-bound one'
region_has "P3f.3 hook offer directive states the offer-only contract" "$HOOK_OFFER" 'It is an offer only — never run it unasked'
region_has "P3f.4 hook offer directive states the offer never gates the terminus" "$HOOK_OFFER" 'never gates, delays, or precedes the chain terminus'
region_has "P3f.4a hook offer directive states the Requirements-table condition" "$HOOK_OFFER" 'when the session plan carries a ## Requirements table'
region_has "P3f.4b hook offer directive restricts the offer to the chain-closing turn" "$HOOK_OFFER" 'never in a fix round that will be re-reviewed'
region_has "P3f.5 hook combined-summary directive names the ## Open budget exception" "$HOOK_SUMMARY" 'the sole exception is ## Open'
region_has "P3f.5a hook combined-summary directive actually interpolates the offer" "$HOOK_SUMMARY" '${CONVERGE_OFFER_DIRECTIVE}'
if grep -qE 'AUTOPILOT_BOUND"?\}? *(!=|=) *"?(true|false)"?' "$POST_REVIEW_HOOK"; then
  check "P3f.6 hook builds the offer only for a non-bound chain, rather than delegating the condition to prose" PASS
else
  check "P3f.6 hook builds the offer only for a non-bound chain, rather than delegating the condition to prose" FAIL
fi

PREAMBLE_FLAT="$(awk '/^### Final report$/{f=1} f&&/^```$/{exit} f' "$SELF_REVIEW_MD" | tr '\n' ' ' | tr -s ' ')"
nonempty_region "P3g.0 self-review report preamble resolves non-empty" "$PREAMBLE_FLAT"
region_has "P3g.1 report budget names the ## Open exception" "$PREAMBLE_FLAT" 'the sole exception is `## Open`'
region_has "P3g.2 report budget makes the evidence lines a duty" "$PREAMBLE_FLAT" 'carries the verbatim `EVIDENCE GAP` / `EVIDENCE CONTRADICTION` lines'
region_has "P3g.3 report budget fixes the ledger-then-offer order" "$PREAMBLE_FLAT" 'ends with the bypass-ledger line followed, when it applies, by the converge offer'
if [ "$(grep -cF 'Optional next step: /zensu:converge' "$SELF_REVIEW_MD")" = 1 ] \
  && [ "$(grep -cF 'Optional next step: /zensu:converge' "$POST_REVIEW_HOOK")" = 1 ]; then
  check "P3g.6 the offer line occurs exactly once in the self-review skill and once in the hook" PASS
else
  check "P3g.6 the offer line occurs exactly once in the self-review skill and once in the hook" FAIL
fi
DOC_OPEN_ROW="$(grep -F '| `## Open` |' "$WORKFLOW_DOC")"
nonempty_region "P3h.0 workflow doc ## Open row resolves non-empty ($WORKFLOW_DOC)" "$DOC_OPEN_ROW"
region_has "P3h.1 workflow doc names the bypass-ledger disclosure" "$DOC_OPEN_ROW" 'Gates bypassed during this session:'
region_has "P3h.2 workflow doc names the standalone-only converge offer" "$DOC_OPEN_ROW" 'never an Autopilot-bound one'
region_has "P3h.3 workflow doc names the Requirements-table condition" "$DOC_OPEN_ROW" 'carries a `## Requirements` table'

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
