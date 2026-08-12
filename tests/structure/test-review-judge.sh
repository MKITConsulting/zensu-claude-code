#!/bin/bash
set -u

# Structure test for the review-judge second-pass stage (P1-3).
# Pins: the agent file exists with read-only frontmatter tools and the judge
# contract (fresh-read mandate, four dimensions, Panel-FP: protocol, JUDGE-*
# IDs, confidence floor, no-build rule, review-aspect-shaped output); the tdd
# SKILL Phase 6 carries the judge stage between the aspect merge and the
# consume-mode reviewer, gated by hooks.reviewJudge with Panel-FP
# neutralization before fix routing; config.example.json ships
# hooks.reviewJudge:true; plugin.json agents[] registers the file; the README
# agents table (4) and config table carry the judge rows; the workflow doc
# names the stage. It intentionally does NOT assert version sync, hook counts,
# or README skill counts — those are owned by sibling tests.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT_MD="$PLUGIN_DIR/agents/review-judge.md"
TDD_MD="$PLUGIN_DIR/skills/tdd/SKILL.md"
CONFIG_EX="$PLUGIN_DIR/config.example.json"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
REVIEW_DOC="$PLUGIN_DIR/docs/review-chain.md"
CONFIG_DOC="$PLUGIN_DIR/docs/configuration.md"
WORKFLOW_DOC="$PLUGIN_DIR/docs/tdd-manager-workflow.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$AGENT_MD" "$TDD_MD" "$CONFIG_EX" "$PLUGIN_JSON" "$REVIEW_DOC" "$CONFIG_DOC" "$WORKFLOW_DOC"; do
  if [ ! -f "$f" ]; then
    check "P0 required file exists: $f" FAIL
    echo "----"
    echo "test-review-judge: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "P0 all six target files exist" PASS

# P1 — agent frontmatter: name + read-only tool set (mirrors review-aspect)
if grep -qE '^name: *review-judge *$' "$AGENT_MD"; then
  check "P1a frontmatter declares 'name: review-judge'" PASS
else
  check "P1a frontmatter declares 'name: review-judge'" FAIL
fi
if grep -qE '^tools: *Read, *Grep, *Glob *$' "$AGENT_MD"; then
  check "P1b frontmatter tools are dedicated reads only" PASS
else
  check "P1b frontmatter tools are dedicated reads only" FAIL
fi

# P2 — judge contract in the agent body
PINS_AGENT=(
  "P2a fresh-read mandate|Read every listed changed file fresh"
  "P2b cross-cutting dimension|cross-cutting integration"
  "P2c requirement-drift dimension|behavioral drift"
  "P2d missed-edge-cases dimension|edge cases missed by the panel"
  "P2e panel-quality dimension|panel false positives or false negatives"
  "P2f Panel-FP: protocol|Panel-FP:"
  "P2g JUDGE-* finding IDs|JUDGE-1"
  "P2h no-build rule|Never write/edit files, use Bash, run builds/tests"
  "P2i never repeats panel findings|Never repeat a panel finding"
  "P2j aspect-shaped output|## Aspect: judge"
)
for entry in "${PINS_AGENT[@]}"; do
  label="${entry%%|*}"; needle="${entry#*|}"
  if grep -qF "$needle" "$AGENT_MD"; then
    check "$label" PASS
  else
    check "$label" FAIL
  fi
done
if grep -qF "Report only confidence >= 80" "$AGENT_MD"; then
  check "P2k confidence floor 80 pinned" PASS
else
  check "P2k confidence floor 80 pinned" FAIL
fi
if grep -qiF 'read-only' "$AGENT_MD" && grep -qF 'tools: Read, Grep, Glob' "$AGENT_MD" && grep -qF 'use Bash' "$AGENT_MD"; then
  check "P2l read-only promise + dedicated reads + shell ban pinned" PASS
else
  check "P2l read-only promise + dedicated reads + shell ban pinned" FAIL
fi

# P3 — tdd SKILL Phase 6 judge stage
if grep -qF "Judge second pass" "$TDD_MD" && grep -qF "subagent_type='zensu:review-judge'" "$TDD_MD"; then
  check "P3a Phase 6 carries the judge stage spawning zensu:review-judge" PASS
else
  check "P3a Phase 6 carries the judge stage spawning zensu:review-judge" FAIL
fi
if grep -qF 'hooks.reviewJudge' "$TDD_MD"; then
  check "P3b judge stage gated by hooks.reviewJudge" PASS
else
  check "P3b judge stage gated by hooks.reviewJudge" FAIL
fi
if grep -qF "neutralizes the finding it references" "$TDD_MD" && grep -qF "BEFORE fix routing" "$TDD_MD"; then
  check "P3c Panel-FP neutralization happens before fix routing" PASS
else
  check "P3c Panel-FP neutralization happens before fix routing" FAIL
fi
if grep -qF "including the step-4b judge deltas" "$TDD_MD"; then
  check "P3d consume-mode reviewer receives merge + judge deltas" PASS
else
  check "P3d consume-mode reviewer receives merge + judge deltas" FAIL
fi
if grep -qF "Flag disabled → skip straight to step 5" "$TDD_MD"; then
  check "P3e flag-off fallback restores the pre-judge chain" PASS
else
  check "P3e flag-off fallback restores the pre-judge chain" FAIL
fi
if grep -qF "re-run the step-4b judge when \`hooks.reviewJudge\` is enabled" "$TDD_MD" && grep -qF "never carry a prior round's" "$TDD_MD"; then
  check "P3f fix rounds re-run the judge with fresh deltas" PASS
else
  check "P3f fix rounds re-run the judge with fresh deltas" FAIL
fi
if grep -qF "[Panel-FP-neutralized — do not fix]" "$TDD_MD" && grep -qF "never dropped outright" "$TDD_MD" && grep -qF "including \`autoFixIncludeSuggestions\`" "$TDD_MD"; then
  check "P3g visible neutralization tag, CRITICAL never dropped, all severity modes exempt" PASS
else
  check "P3g visible neutralization tag, CRITICAL never dropped, all severity modes exempt" FAIL
fi
if grep -qF "zensu_hook_enabled reviewJudge" "$TDD_MD"; then
  check "P3h flag resolved via the config-lib seam (real merge semantics)" PASS
else
  check "P3h flag resolved via the config-lib seam (real merge semantics)" FAIL
fi

# P4 — config example + registration
if node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.exit(c.hooks && c.hooks.reviewJudge===true?0:1)' "$CONFIG_EX" 2>/dev/null; then
  check "P4a config.example.json ships hooks.reviewJudge:true" PASS
else
  check "P4a config.example.json ships hooks.reviewJudge:true" FAIL
fi
if node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.exit(Array.isArray(p.agents)&&p.agents.indexOf("./agents/review-judge.md")!==-1?0:1)' "$PLUGIN_JSON" 2>/dev/null; then
  check "P4b plugin.json agents[] registers ./agents/review-judge.md" PASS
else
  check "P4b plugin.json agents[] registers ./agents/review-judge.md" FAIL
fi

# P5 — reference docs + workflow doc
if grep -qxF '### Agents (6)' "$REVIEW_DOC" \
   && grep -qF '| **review-judge** |' "$REVIEW_DOC" \
   && grep -qF '| **plan-review-worker** |' "$REVIEW_DOC" \
   && grep -qF '| **pr-review-worker** |' "$REVIEW_DOC"; then
  check "P5a docs/review-chain.md agents table is (6) with judge and dedicated review workers" PASS
else
  check "P5a docs/review-chain.md agents table is (6) with judge and dedicated review workers" FAIL
fi
if grep -qF '| `reviewJudge` |' "$CONFIG_DOC"; then
  check "P5b docs/configuration.md config table carries the reviewJudge row" PASS
else
  check "P5b docs/configuration.md config table carries the reviewJudge row" FAIL
fi
if grep -qF 'judge second pass' "$WORKFLOW_DOC" && grep -qF 'hooks.reviewJudge' "$WORKFLOW_DOC"; then
  check "P5c workflow doc names the judge stage + gate" PASS
else
  check "P5c workflow doc names the judge stage + gate" FAIL
fi

# P6 — recovery/re-round directives and the consume contract are judge-aware
ENFORCER="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
DELEGATE="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
CODE_REVIEWER_MD="$PLUGIN_DIR/agents/code-reviewer.md"
if grep -qF 'zensu:review-judge' "$ENFORCER" && grep -qF 'PRE-MERGED FINDINGS (fan-out)' "$ENFORCER"; then
  check "P6a stop-enforcer directive routes through the staged chain incl. judge" PASS
else
  check "P6a stop-enforcer directive routes through the staged chain incl. judge" FAIL
fi
if grep -qF 'zensu:review-judge' "$DELEGATE" && grep -qF 'Panel-FP-neutralized' "$DELEGATE"; then
  check "P6b delegate re-verify directive re-runs the judge + exempts neutralized items" PASS
else
  check "P6b delegate re-verify directive re-runs the judge + exempts neutralized items" FAIL
fi
if grep -qF 'JUDGE-*' "$CODE_REVIEWER_MD" && grep -qF 'Panel-FP-neutralized' "$CODE_REVIEWER_MD"; then
  check "P6c code-reviewer consume contract documents judge deltas + neutralization" PASS
else
  check "P6c code-reviewer consume contract documents judge deltas + neutralization" FAIL
fi

# P7 — e2e-skills scenario ships (prompt + agent type + expected pattern)
if [ -f "$PLUGIN_DIR/tests/e2e-skills/prompts/review-judge.txt" ] && [ -f "$PLUGIN_DIR/tests/e2e-skills/prompts/review-judge.agent" ] && [ -f "$PLUGIN_DIR/tests/e2e-skills/expected/review-judge.pattern" ]; then
  check "P7 e2e-skills review-judge scenario ships (prompt/.agent/pattern)" PASS
else
  check "P7 e2e-skills review-judge scenario ships (prompt/.agent/pattern)" FAIL
fi

echo "----"
echo "test-review-judge: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
