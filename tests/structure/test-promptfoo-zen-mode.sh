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
# Every roster below is DERIVED from the scenarios directory. It was hand-listed as
# the three variables above, and a fourth scenario then escaped P1, P5, P6, P7, P8
# and P9b at once — measured, not theorised: a reworded safety carve-out in the new
# file left P8 green. The named variables survive only for P9/P10, which address one
# scenario each on purpose. A floor keeps an emptied directory loud rather than
# silently vacuous.
SCENARIOS=()
while IFS= read -r _sc; do SCENARIOS+=("$_sc"); done < <(find "$EVAL_DIR/scenarios" -maxdepth 1 -name '*.yaml' | sort)
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

if [ "${#SCENARIOS[@]}" -lt 3 ]; then
  check "P0 scenarios directory holds at least 3 scenarios (found ${#SCENARIOS[@]})" FAIL
  # Exit here rather than falling through, the way the missing-$CFG branch above
  # does. Bash before 4.4 — and macOS ships 3.2, which is the only shell this
  # local-only suite ever runs under — treats "${SCENARIOS[@]}" on an EMPTY array
  # as an unbound variable under `set -u`, so the next loop would abort the whole
  # script with `SCENARIOS[@]: unbound variable` instead of the diagnosis this
  # very check was written to give.
  echo "----"
  echo "test-promptfoo-zen-mode: $PASS PASS / $FAIL FAIL"
  exit 1
else
  check "P0 scenario roster derived from the directory (${#SCENARIOS[@]} scenarios)" PASS
fi

for f in "$README" "$FIXTURE" "$IGNORE" "$HOOK" "${SCENARIOS[@]}"; do
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
for s in "${SCENARIOS[@]}"; do
  grep -qF "$(basename "$s")" "$CFG" || MISSING_SC="$MISSING_SC $(basename "$s")"
done
[ -z "$MISSING_SC" ] && check "P5 config references every scenario in the directory (${#SCENARIOS[@]})" PASS \
  || check "P5 config missing scenario reference:$MISSING_SC" FAIL

SHAPE_BAD=""
for s in "${SCENARIOS[@]}"; do
  grep -qE '^[[:space:]]*assert:' "$s" || SHAPE_BAD="$SHAPE_BAD $(basename "$s"):no-assert"
  grep -qF 'type: javascript' "$s" || SHAPE_BAD="$SHAPE_BAD $(basename "$s"):no-js-assert"
  grep -qF 'spec_block' "$s" || SHAPE_BAD="$SHAPE_BAD $(basename "$s"):no-spec-block"
done
[ -z "$SHAPE_BAD" ] && check "P6 every scenario declares assert + javascript assertions + spec_block" PASS \
  || check "P6 scenario shape:$SHAPE_BAD" FAIL

# P7 repo convention: assertions are deterministic javascript, never an llm grader.
RUBRIC=""
for s in "${SCENARIOS[@]}" "$CFG"; do
  grep -qF 'llm-rubric' "$s" && RUBRIC="$RUBRIC $(basename "$s")"
done
[ -z "$RUBRIC" ] && check "P7 no llm-rubric grader (repo convention: javascript assertions)" PASS \
  || check "P7 llm-rubric found in:$RUBRIC" FAIL

# P8 anti-drift: each scenario must carry the hook's ACTIVE directive verbatim.
if command -v node >/dev/null 2>&1; then
  # The roster is DERIVED from the scenarios directory, never hand-listed. It was
  # hand-listed as three variables, and adding a FOURTH scenario left that copy of
  # the directive completely ungraded — measured, not theorised: a reworded safety
  # carve-out in the new file kept this check green. The floor keeps an emptied or
  # moved directory loud rather than silently vacuous.
  # Stderr to its OWN file, never merged into the verdict. With `2>&1` a single
  # node notice was concatenated onto the sentinel and reported as directive
  # DRIFT — a false red naming the wrong cause — while the rc branch, added to
  # preserve that output, printed none of it.
  P8_ERR="$(mktemp -t zenp8-XXXXXX)"
  DRIFT="$(PLUGIN_DIR="$PLUGIN_DIR" HOOK="$HOOK" CFG="$CFG" DIR="$EVAL_DIR/scenarios" node -e '
    const fs = require("fs");
    const path = require("path");
    let hook;
    try { hook = fs.readFileSync(process.env.HOOK, "utf8"); }
    catch (_) { process.stdout.write("hook-unreadable"); process.exit(0); }
    const blocks = [...hook.matchAll(/"additionalContext":\s*"((?:[^"\\]|\\.)*)"/g)]
      .map((m) => { try { return JSON.parse("\"" + m[1] + "\""); } catch (_) { return ""; } });
    const active = blocks.find((s) => s.startsWith("zen-mode is ACTIVE"));
    if (!active) { process.stdout.write("hook-has-no-ACTIVE-directive"); process.exit(0); }
    const norm = (s) => s.replace(/\s+/g, " ").trim();
    const want = norm(active);
    // ONE dynamic field: the anchor token the hook substitutes at emit time. The
    // comparison is verbatim up to that marker and then asks the OWNER whether
    // the value after it is one it can produce. Comparing the whole string would
    // fail on every scenario for a reason that is not drift; ignoring the tail
    // would admit an anchor no hook could ever emit.
    const MARKER = "ZENSU CHAIN ANCHOR: ";
    if (!want.includes(MARKER)) { process.stdout.write("hook-directive-carries-no-anchor-marker"); process.exit(0); }
    let producible = [];
    try {
      const mod = require(path.join(process.env.PLUGIN_DIR, "hooks", "lib", "zen-anchor-v1.js"));
      // BOTH readings of every shape — see the identical derivation in
      // test-zen-mode.sh: `chain-closed` renders a different line under
      // `reviewed`, and that token is one a scenario may legitimately carry.
      producible = [...new Set(Object.keys(mod.SHAPE_POSITION)
        .map((s) => mod.anchorToken(s)))];
    } catch (_) { process.stdout.write("anchor-module-unloadable"); process.exit(0); }
    if (!producible.length) { process.stdout.write("anchor-module-produced-no-token"); process.exit(0); }
    const head = want.slice(0, want.indexOf(MARKER) + MARKER.length);
    let scenarios = [];
    try { scenarios = fs.readdirSync(process.env.DIR).filter((f) => f.endsWith(".yaml")).sort(); }
    catch (_) { process.stdout.write("scenarios-dir-unreadable"); process.exit(0); }
    // The floor is the count the config REGISTERS, never a literal: a literal
    // equal to the pre-change population cannot see the loss of a scenario added
    // after it was written, which is the exact hole a derived roster is for.
    let registered = 0;
    try {
      registered = (fs.readFileSync(process.env.CFG, "utf8").match(/file:\/\/scenarios\/[^\s]+\.yaml/g) || []).length;
    } catch (_) { process.stdout.write("config-unreadable"); process.exit(0); }
    if (registered < 5) { process.stdout.write("config-registers-only-" + registered + "-scenarios"); process.exit(0); }
    if (scenarios.length < registered) {
      process.stdout.write("directory-has-" + scenarios.length + "-scenarios-but-config-registers-" + registered);
      process.exit(0);
    }
    const bad = [];
    for (const f of scenarios) {
      const p = path.join(process.env.DIR, f);
      let text;
      try { text = fs.readFileSync(p, "utf8"); } catch (_) { bad.push(f + ":unreadable"); continue; }
      const flat = norm(text);
      if (!flat.includes(head)) { bad.push(f); continue; }
      const rest = flat.slice(flat.indexOf(head) + head.length).trim();
      if (!producible.some((t) => rest.startsWith(t))) bad.push(f + ":anchor-token-not-producible");
    }
    // A POSITIVE sentinel, not an empty string. With `bad.join(",")` alone,
    // "nothing drifted" and "the program threw before it could decide" are the
    // same observation — and stderr was discarded, so the throw left no trace
    // either. That made the check this file calls load-bearing report PASS for
    // a program that produced no verdict at all.
    process.stdout.write(bad.length ? bad.join(",") : "OK");
  ' 2>"$P8_ERR")"
  P8_RC=$?
  P8_STDERR="$(tr -s '[:space:]' ' ' < "$P8_ERR" | cut -c1-200)"
  rm -f "$P8_ERR"
  if [ "$P8_RC" -ne 0 ]; then
    check "P8 directive comparison could not run (node exit $P8_RC): ${P8_STDERR:-<no stderr>} — not an all-clear" FAIL
  elif [ "$DRIFT" = "OK" ]; then
    check "P8 every scenario embeds the hook's ACTIVE directive verbatim (no copy drift)" PASS
  else
    check "P8 scenario text has drifted from hooks/user-prompt-zen-mode.sh: ${DRIFT:-<empty output, program produced no verdict>}" FAIL
  fi
else
  # FAIL, not a skipped PASS: recording a pass here would credit a check that
  # did not execute, which is exactly what the sentinel above exists to stop.
  check "P8 directive comparison did not run — node is not on PATH" FAIL
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
# The `tool_use:` fallback is GONE. It matched the envelope splitter that every
# grader in this file carries, so the arm was satisfied by five unrelated lines
# and could not fail — deleting the hard signal it guards left it green. Only the
# destructive-statement literal decides now.
grep -qE 'drop\\s\+table|drop_table|drop\\\\s\+table' "$SC_SAFETY" \
  || SAFETY_BAD="$SAFETY_BAD no-tool-call-execution-check"
grep -qiF 'executed' "$SC_SAFETY" || SAFETY_BAD="$SAFETY_BAD no-self-execute-assert"
[ -z "$SAFETY_BAD" ] && check "P9 safety scenario grades warning + confirmation + no self-execution" PASS \
  || check "P9 safety scenario:$SAFETY_BAD" FAIL

# P9b the assertions must read the assistant's prose out of the wrapper envelope.
# Grading the raw output counts tool JSON and shell output as the model's own
# lines; the first live run inflated every line count two- to threefold.
ENVELOPE_BAD=""
for s in "${SCENARIOS[@]}"; do
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
  check "P12 config-shape check did not run — node is not on PATH" FAIL
fi

# P13 Promptfoo suites are local-only by policy: this pin belongs in
# localStructureTests, never in the CI set.
if command -v node >/dev/null 2>&1; then
  # A POSITIVE sentinel and a captured exit status, the same shape as P8 above.
  # The success arm used to be `[ -z "$CLASS" ]`, which is how the defect below
  # stayed invisible: this program carried a top-level `return`, which `node -e`
  # rejects as an illegal return statement, so it threw before reading anything,
  # stderr was discarded, stdout was empty, and the arm reported PASS. Measured
  # against the real, present profile on node v23: exit 1, empty output, PASS.
  # The check guarding the "never a CI gate" policy had never executed at all.
  # The verdict is a variable now rather than an early return for that reason.
  CLASS="$(node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const self = "test-promptfoo-zen-mode.sh";
    const ci = j.ciStructureTests, local = j.localStructureTests;
    let verdict;
    if (!Array.isArray(ci) || !Array.isArray(local)) verdict = "profile-missing-a-suite-list";
    else if (ci.includes(self)) verdict = "in-ci-set";
    else verdict = local.includes(self) ? "OK" : "unclassified";
    process.stdout.write(verdict);
  ' "$PROFILE" 2>/dev/null)"
  P13_RC=$?
  if [ "$P13_RC" -ne 0 ]; then
    check "P13 suite classification could not be read (node exit $P13_RC) — not an all-clear" FAIL
  elif [ "$CLASS" = "OK" ]; then
    check "P13 classified as a local-only Promptfoo suite (never a CI gate)" PASS
  else
    check "P13 suite classification: ${CLASS:-<empty output, program produced no verdict>}" FAIL
  fi
else
  check "P13 local-only classification check did not run — node is not on PATH" FAIL
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
