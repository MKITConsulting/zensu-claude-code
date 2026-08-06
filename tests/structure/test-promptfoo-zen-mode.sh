#!/bin/bash
set -u

# Deterministic shape pin for the LIVE zen-mode reaction eval
# (evals/zen-mode-reaction). Runs offline: it never invokes promptfoo, never
# spends API credits, and asserts nothing about model behaviour.
#
# The load-bearing check is P8. Each scenario embeds the hook's injected
# `additionalContext` as a copy, because a fresh `claude --print` session carries
# no zen-mode marker and the real UserPromptSubmit hook therefore never fires. A
# copy silently drifts from its source, and a drifted copy grades wording that no
# user ever receives — which would be worse than having no eval, since it reports
# green. P8 re-derives the directive from hooks/user-prompt-zen-mode.sh and
# requires every scenario to carry it verbatim.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
EVAL_DIR="$PLUGIN_DIR/evals/zen-mode-reaction"
CFG="$EVAL_DIR/promptfooconfig.yaml"
README="$EVAL_DIR/README.md"
FIXTURE="$EVAL_DIR/test-projects/empty-host/CLAUDE.md"
IGNORE="$EVAL_DIR/.gitignore"
SC_CONTRACT="$EVAL_DIR/scenarios/contract-compliance.yaml"
SC_PRECEDENCE="$EVAL_DIR/scenarios/precedence-over-compression.yaml"
SC_SAFETY="$EVAL_DIR/scenarios/safety-carve-out.yaml"
HOOK="$PLUGIN_DIR/hooks/user-prompt-zen-mode.sh"
WRAPPER="$PLUGIN_DIR/scripts/claude-promptfoo-wrapper.sh"
PROFILE="$PLUGIN_DIR/tests/profiles/promptfoo-local-only.v1.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$CFG" ]; then
  check "P1 promptfooconfig.yaml exists" FAIL
  echo "----"
  echo "test-promptfoo-zen-mode: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "P1 promptfooconfig.yaml exists" PASS

for f in "$README" "$FIXTURE" "$IGNORE" "$SC_CONTRACT" "$SC_PRECEDENCE" "$SC_SAFETY"; do
  if [ -f "$f" ]; then
    check "P1 file exists: ${f#$PLUGIN_DIR/}" PASS
  else
    check "P1 file exists: ${f#$PLUGIN_DIR/}" FAIL
  fi
done

grep -qF 'claude-promptfoo-wrapper.sh' "$CFG" \
  && check "P2 promptfooconfig references claude-promptfoo-wrapper.sh provider" PASS \
  || check "P2 promptfooconfig references claude-promptfoo-wrapper.sh provider" FAIL

grep -qF './test-projects/empty-host' "$CFG" \
  && check "P3 promptfooconfig points at test-projects/empty-host fixture" PASS \
  || check "P3 promptfooconfig points at test-projects/empty-host fixture" FAIL

if grep -qE '^[[:space:]]*agent:' "$CFG"; then
  check "P4 promptfooconfig does NOT force an agent (main-thread reaction)" FAIL
else
  check "P4 promptfooconfig does NOT force an agent (main-thread reaction)" PASS
fi

MISSING_SC=""
for s in contract-compliance.yaml precedence-over-compression.yaml safety-carve-out.yaml; do
  grep -qF "$s" "$CFG" || MISSING_SC="$MISSING_SC $s"
done
[ -z "$MISSING_SC" ] && check "P5 config references all three scenarios" PASS \
  || check "P5 config missing scenario reference:$MISSING_SC" FAIL

SHAPE_BAD=""
for s in "$SC_CONTRACT" "$SC_PRECEDENCE" "$SC_SAFETY"; do
  grep -qE '^[[:space:]]*assert:' "$s" || SHAPE_BAD="$SHAPE_BAD $(basename "$s"):no-assert"
  grep -qF 'type: javascript' "$s" || SHAPE_BAD="$SHAPE_BAD $(basename "$s"):no-js-assert"
  grep -qF 'spec_block' "$s" || SHAPE_BAD="$SHAPE_BAD $(basename "$s"):no-spec-block"
done
[ -z "$SHAPE_BAD" ] && check "P6 every scenario declares assert + javascript assertions + spec_block" PASS \
  || check "P6 scenario shape:$SHAPE_BAD" FAIL

# P7 repo convention: assertions are deterministic javascript, never an llm grader.
RUBRIC=""
for s in "$SC_CONTRACT" "$SC_PRECEDENCE" "$SC_SAFETY" "$CFG"; do
  grep -qF 'llm-rubric' "$s" && RUBRIC="$RUBRIC $(basename "$s")"
done
[ -z "$RUBRIC" ] && check "P7 no llm-rubric grader (repo convention: javascript assertions)" PASS \
  || check "P7 llm-rubric found in:$RUBRIC" FAIL

# P8 anti-drift: each scenario must carry the hook's ACTIVE directive verbatim.
if command -v node >/dev/null 2>&1; then
  DRIFT="$(HOOK="$HOOK" A="$SC_CONTRACT" B="$SC_PRECEDENCE" C="$SC_SAFETY" node -e '
    const fs = require("fs");
    const hook = fs.readFileSync(process.env.HOOK, "utf8");
    const blocks = [...hook.matchAll(/"additionalContext":\s*"((?:[^"\\]|\\.)*)"/g)]
      .map((m) => { try { return JSON.parse("\"" + m[1] + "\""); } catch (_) { return ""; } });
    const active = blocks.find((s) => s.startsWith("zen-mode is ACTIVE"));
    if (!active) { process.stdout.write("hook-has-no-ACTIVE-directive"); process.exit(0); }
    const norm = (s) => s.replace(/\s+/g, " ").trim();
    const want = norm(active);
    const bad = [];
    for (const key of ["A", "B", "C"]) {
      const path = process.env[key];
      if (!norm(fs.readFileSync(path, "utf8")).includes(want)) bad.push(path.split("/").pop());
    }
    process.stdout.write(bad.join(","));
  ' 2>/dev/null)"
  if [ -z "$DRIFT" ]; then
    check "P8 every scenario embeds the hook's ACTIVE directive verbatim (no copy drift)" PASS
  else
    check "P8 scenario text has drifted from hooks/user-prompt-zen-mode.sh: $DRIFT" FAIL
  fi
else
  check "P8 (skipped — node not on PATH)" PASS
fi

# P9 the safety scenario is the reason this eval exists: it must grade the
# irreversibility warning, the surviving confirmation question, and the refusal
# to self-execute.
SAFETY_BAD=""
grep -qF 'irreversible' "$SC_SAFETY" || SAFETY_BAD="$SAFETY_BAD no-irreversibility-assert"
grep -qF 'confirm' "$SC_SAFETY" || SAFETY_BAD="$SAFETY_BAD no-confirmation-assert"
grep -qF 'one-question cap' "$SC_SAFETY" || SAFETY_BAD="$SAFETY_BAD no-question-cap-assert"
# The self-execution check must grade the hard signal (a tool call that really
# ran the statement), not only a prose confession — a live run showed prose
# sniffing alone produces false positives on refusals.
grep -qE 'drop\\s\+table|drop_table|drop\\\\s\+table' "$SC_SAFETY" \
  || grep -qF 'tool_use:' "$SC_SAFETY" \
  || SAFETY_BAD="$SAFETY_BAD no-tool-call-execution-check"
grep -qiF 'executed' "$SC_SAFETY" || SAFETY_BAD="$SAFETY_BAD no-self-execute-assert"
[ -z "$SAFETY_BAD" ] && check "P9 safety scenario grades warning + confirmation + no self-execution" PASS \
  || check "P9 safety scenario:$SAFETY_BAD" FAIL

# P9b the assertions must read the assistant's prose out of the wrapper envelope.
# Grading the raw output counts tool JSON and shell output as the model's own
# lines; the first live run inflated every line count two- to threefold.
ENVELOPE_BAD=""
for s in "$SC_CONTRACT" "$SC_PRECEDENCE" "$SC_SAFETY"; do
  grep -qF 'assistant_text' "$s" || ENVELOPE_BAD="$ENVELOPE_BAD $(basename "$s")"
done
[ -z "$ENVELOPE_BAD" ] && check "P9b every scenario extracts assistant prose from the wrapper envelope" PASS \
  || check "P9b scenario grades the raw envelope:$ENVELOPE_BAD" FAIL

# P10 the precedence scenario must actually pit a compression mode against
# zen-mode and grade the outcome, not merely mention it.
PREC_BAD=""
grep -qiF 'caveman' "$SC_PRECEDENCE" || PREC_BAD="$PREC_BAD no-competing-mode"
grep -qF 'articles' "$SC_PRECEDENCE" || PREC_BAD="$PREC_BAD no-article-density-assert"
grep -qF 'OVERRIDES' "$SC_PRECEDENCE" || PREC_BAD="$PREC_BAD no-precedence-clause"
[ -z "$PREC_BAD" ] && check "P10 precedence scenario pits a compression mode against zen-mode and grades it" PASS \
  || check "P10 precedence scenario:$PREC_BAD" FAIL

[ -x "$WRAPPER" ] && check "P11 referenced provider script exists and is executable" PASS \
  || check "P11 referenced provider script exists and is executable" FAIL

if command -v node >/dev/null 2>&1; then
  CFG_N="$(command -v cygpath >/dev/null 2>&1 && cygpath -m "$CFG" || printf '%s' "$CFG")"
  if node -e "
    const fs = require('fs');
    const txt = fs.readFileSync('$CFG_N', 'utf8');
    if (!/^description:\s*['\"]/m.test(txt)) process.exit(11);
    if (!/^providers:/m.test(txt)) process.exit(12);
    if (!/^tests:/m.test(txt)) process.exit(13);
    if (!/^prompts:/m.test(txt)) process.exit(14);
    process.exit(0);
  "; then
    check "P12 promptfooconfig has top-level description/providers/prompts/tests keys" PASS
  else
    check "P12 promptfooconfig missing one of description/providers/prompts/tests" FAIL
  fi
else
  check "P12 (skipped — node not on PATH)" PASS
fi

# P13 Promptfoo suites are local-only by policy: this pin belongs in
# localStructureTests, never in the CI set.
if command -v node >/dev/null 2>&1; then
  CLASS="$(node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const self = "test-promptfoo-zen-mode.sh";
    if (j.ciStructureTests.includes(self)) { process.stdout.write("in-ci-set"); return; }
    process.stdout.write(j.localStructureTests.includes(self) ? "" : "unclassified");
  ' "$PROFILE" 2>/dev/null)"
  [ -z "$CLASS" ] && check "P13 classified as a local-only Promptfoo suite (never a CI gate)" PASS \
    || check "P13 suite classification: $CLASS" FAIL
else
  check "P13 (skipped — node not on PATH)" PASS
fi

# P14 the README must state that this is advisory and costs API credits, so a
# reader never mistakes a red run for a merge blocker.
README_BAD=""
grep -qiF 'costs API credits' "$README" || README_BAD="$README_BAD no-cost-warning"
grep -qiF 'NOT a CI gate' "$README" || README_BAD="$README_BAD no-advisory-note"
grep -qF 'promptfoo eval -c promptfooconfig.yaml' "$README" || README_BAD="$README_BAD no-run-command"
[ -z "$README_BAD" ] && check "P14 README documents the run command, the cost, and the advisory status" PASS \
  || check "P14 README:$README_BAD" FAIL

echo "----"
echo "test-promptfoo-zen-mode: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
