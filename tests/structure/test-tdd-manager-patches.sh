#!/bin/bash
set -u

# NOTE (0.4.0): the TDD discipline patches migrated from the deleted
# agents/tdd-manager.md subagent into the main-thread skill skills/tdd/SKILL.md.
# This test now pins that content in its new home.
PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT="$PLUGIN_DIR/skills/tdd/SKILL.md"
AUTOPILOT_SKILL="$PLUGIN_DIR/skills/autopilot/SKILL.md"
PR_TEAM_REVIEW_SKILL="$PLUGIN_DIR/skills/pr-team-review/SKILL.md"
PR_FIX_FINDINGS_SKILL="$PLUGIN_DIR/skills/pr-fix-findings/SKILL.md"
TPL_PLAN="$PLUGIN_DIR/templates/tdd-plan.md"
WORKFLOW_DOC="$PLUGIN_DIR/docs/tdd-manager-workflow.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$AGENT" ]; then
  check "skills/tdd/SKILL.md exists" FAIL
  echo "----"
  echo "test-tdd-manager-patches: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "skills/tdd/SKILL.md exists" PASS

LINES=$(wc -l <"$AGENT")
if [ "$LINES" -le 433 ]; then
  check "skill line count <= 433 (actual: $LINES)" PASS
else
  check "skill line count <= 433 (actual: $LINES)" FAIL
fi

# Patch 1 — 3 new Rationalization Counters
if grep -qF 'Tool X is missing, I' "$AGENT"; then
  check "P1.a Rationalization Counter: missing tool -> hand-rolled replacement" PASS
else
  check "P1.a Rationalization Counter: missing tool -> hand-rolled replacement" FAIL
fi
if grep -qF 'Secret / env var missing' "$AGENT"; then
  check "P1.b Rationalization Counter: missing secret -> placeholder fixture" PASS
else
  check "P1.b Rationalization Counter: missing secret -> placeholder fixture" FAIL
fi
if grep -qF "The user said 'no questions'" "$AGENT"; then
  check "P1.c Rationalization Counter: 'no questions' override" PASS
else
  check "P1.c Rationalization Counter: 'no questions' override" FAIL
fi

# Patch 2 — Hard Ban for self-substitution
if grep -qF 'NEVER substitute a missing required dependency' "$AGENT"; then
  check "P2 Hard Ban: never substitute missing required dependency" PASS
else
  check "P2 Hard Ban: never substitute missing required dependency" FAIL
fi

# Patch 3 — New Phase 1.5
if grep -qF '## Phase 1.5: Spec Precondition Discovery' "$AGENT"; then
  check "P3 Phase 1.5 header present" PASS
else
  check "P3 Phase 1.5 header present" FAIL
fi
if grep -qF 'AskUserQuestion override' "$AGENT"; then
  check "P3 Phase 1.5 AskUserQuestion override section" PASS
else
  check "P3 Phase 1.5 AskUserQuestion override section" FAIL
fi
if grep -qF 'substitution MUST be named by the user' "$AGENT"; then
  check "P3 Phase 1.5 user-named substitution rule" PASS
else
  check "P3 Phase 1.5 user-named substitution rule" FAIL
fi

# Patch 4 — Preconditions table in plan template
if grep -qxF '## Preconditions' "$TPL_PLAN" 2>/dev/null; then
  check "P4 Preconditions table heading in plan template" PASS
else
  check "P4 Preconditions table heading in plan template" FAIL
fi
if grep -qF '| Name | Type | Verification | Status | Decision |' "$TPL_PLAN" 2>/dev/null; then
  check "P4 Preconditions table columns (plan template)" PASS
else
  check "P4 Preconditions table columns (plan template)" FAIL
fi

# Patch 5 — Phase 4 per-step precondition gate
if grep -qF 'Precondition check' "$AGENT"; then
  check "P5 Phase 4 self-check expanded with Precondition check" PASS
else
  check "P5 Phase 4 self-check expanded with Precondition check" FAIL
fi
if grep -qF 'BLOCKED — precondition' "$AGENT"; then
  check "P5 Phase 4 BLOCKED log format" PASS
else
  check "P5 Phase 4 BLOCKED log format" FAIL
fi

# Patch 6 — Phase 6 Precondition Drift Audit
if grep -qF 'Precondition Drift Audit' "$AGENT"; then
  check "P6 Phase 6 Precondition Drift Audit step" PASS
else
  check "P6 Phase 6 Precondition Drift Audit step" FAIL
fi
if grep -qF 'PRECONDITION DRIFT' "$AGENT"; then
  check "P6 Phase 6 PRECONDITION DRIFT log marker" PASS
else
  check "P6 Phase 6 PRECONDITION DRIFT log marker" FAIL
fi

# Phase 6 renumbering integrity: still has "Output summary" step
if grep -qF 'Output summary' "$AGENT"; then
  check "Phase 6 'Output summary' step preserved after renumbering" PASS
else
  check "Phase 6 'Output summary' step preserved after renumbering" FAIL
fi

# Fix-round 1: finding 3 — Phase 6 step 6.b uses fixed-string grep, not interpolated regex
if grep -qF 'grep -F -w' "$AGENT"; then
  check "F3 Phase 6 step 6.b uses grep -F -w (fixed-string word match)" PASS
else
  check "F3 Phase 6 step 6.b uses grep -F -w (fixed-string word match)" FAIL
fi
if grep -qF 'regex metacharacters' "$AGENT"; then
  check "F3 Phase 6 step 6.b warns about regex metacharacters in CLI names" PASS
else
  check "F3 Phase 6 step 6.b warns about regex metacharacters in CLI names" FAIL
fi
if grep -qF "grep -E '\\b(X|substitute)\\b'" "$AGENT"; then
  check "F3 Phase 6 step 6.b no longer contains the brittle grep -E interpolation" FAIL
else
  check "F3 Phase 6 step 6.b no longer contains the brittle grep -E interpolation" PASS
fi

# Fix-round 1: finding 4 — Phase 1.5 option (a) install follow-up step present
if grep -qF 'picks (a) install' "$AGENT"; then
  check "F4 Phase 1.5 step describes option-(a) install follow-up" PASS
else
  check "F4 Phase 1.5 step describes option-(a) install follow-up" FAIL
fi
if grep -qF 'does NOT proactively run install commands' "$AGENT"; then
  check "F4 Phase 1.5 option-(a) step forbids proactive install" PASS
else
  check "F4 Phase 1.5 option-(a) step forbids proactive install" FAIL
fi

# Round 14 — Test-Run Evidence Anti-Hallucination Patches

if grep -qF -- '`{step_or_phase} CHECKPOINT — {verdict} | cmd: {command} | scope: {N} suites over {files}`' "$AGENT"; then
  check "R14-P1 Phase 5 logs a plain scoped CHECKPOINT line" PASS
else
  check "R14-P1 Phase 5 logs a plain scoped CHECKPOINT line" FAIL
fi

if grep -qF -- "--evidence-run --scope full --cmd '{full_test_cmd}' --log {log_file}" "$AGENT" \
  && grep -qF -- 'You write no claim line for these runs.' "$AGENT" \
  && grep -qF -- 'never a claim in the run log' "$AGENT"; then
  check "R14-P2 Phase 6 step 1 runs the full suite through the evidence runner, and the terminus reads its record" PASS
else
  check "R14-P2 Phase 6 step 1 runs the full suite through the evidence runner, and the terminus reads its record" FAIL
fi

if grep -qF 'Test Evidence' "$AGENT" && grep -qF -- 'TEST VIA {tool}' "$AGENT"; then
  check "R14-P3 Phase 6 report carries a Test Evidence section and the non-Bash runner line" PASS
else
  check "R14-P3 Phase 6 report carries a Test Evidence section and the non-Bash runner line" FAIL
fi

# Round 17 — Phase 5 checkpoint is SCOPED; the full suite runs in the Phase 6 audit.
# Placed beside Round 14 rather than in round order, deliberately: these rows close
# R14-P1's blind spot and the comment below back-references it, so adjacency is what
# makes that read. Do not "correct" the ordering.
# R14-P1 above greps only the CHECKPOINT schema literals, which survive a revert of the
# scoping, so without these rows the whole rule could be undone with every suite green.
# Both doc carriers and the plan template are pinned beside the skill: the mermaid node,
# the phase table and the template's Checkpoint line are what an operator and every
# generated plan actually read, and they drift silently otherwise.

if [ -f "$WORKFLOW_DOC" ]; then
  check "R17-P0 docs/tdd-manager-workflow.md exists (carrier for R17-P3/P4)" PASS
else
  check "R17-P0 docs/tdd-manager-workflow.md exists (carrier for R17-P3/P4)" FAIL
fi

if grep -qF -- '**The FULL suite is NOT run here**' "$AGENT" && grep -qF -- 'SCOPED to that phase' "$AGENT"; then
  check "R17-P1 Phase 5 checkpoint is scoped and states the full suite is not run there" PASS
else
  check "R17-P1 Phase 5 checkpoint is scoped and states the full suite is not run there" FAIL
fi

if grep -qF -- "**This is the implementation pass's mandatory full-suite run**" "$AGENT" \
  && grep -qF -- 'never scoped down, and it must measure the FINISHED tree' "$AGENT" \
  && grep -qF -- 'reports COVERAGE only and never carries the verdict' "$AGENT"; then
  check "R17-P2 Phase 6 step 1 states the mandatory full-suite run over the finished tree" PASS
else
  check "R17-P2 Phase 6 step 1 states the mandatory full-suite run over the finished tree" FAIL
fi

# R17-P2b — the operator account of the status-marker legend. The two renderers are
# pinned against each other by evals/config-gate/test-post-review-combined-summary.sh;
# this is the third carrier, which nothing else reads, and its three load-bearing
# claims are the prefix rule, the provenance bound on the neutral marker, and the
# `## Open` exemption. A `\|` inside a code span is asserted ABSENT because that escape
# is only meaningful inside a GFM table row — in a paragraph the backslash renders.
if grep -qF -- 'The marker **prefixes** the cell value and never replaces it' "$WORKFLOW_DOC" 2>/dev/null \
  && grep -qF -- '⚪ is bound to provenance, never to judgement' "$WORKFLOW_DOC" 2>/dev/null \
  && grep -qF -- 'carries no marker column at all' "$WORKFLOW_DOC" 2>/dev/null \
  && grep -qF -- 'subject only to the pipe-escaping rule' "$WORKFLOW_DOC" 2>/dev/null \
  && ! grep -qF -- 'survives byte-for-byte' "$WORKFLOW_DOC" 2>/dev/null \
  && ! grep -qF -- '`Check \| Verdict` cell' "$WORKFLOW_DOC" 2>/dev/null; then
  check "R17-P2b workflow doc states the marker prefix rule, the provenance bound and the Open exemption" PASS
else
  check "R17-P2b workflow doc states the marker prefix rule, the provenance bound and the Open exemption" FAIL
fi

# Both needles carry their CONTAINING structure. A bare phrase would stay green if the
# mermaid node or the table row were deleted and the words survived in prose, under a
# label still claiming the node and the row are there.
if grep -qF -- 'P5[Phase 5: Checkpoint<br/>scoped suites + linter]' "$WORKFLOW_DOC" 2>/dev/null \
  && grep -qF -- 'P6[Phase 6: Audit and Final Report<br/>full suite · build · coverage' "$WORKFLOW_DOC" 2>/dev/null; then
  check "R17-P3 workflow doc mermaid nodes carry the scoped checkpoint and the audit full suite" PASS
else
  check "R17-P3 workflow doc mermaid nodes carry the scoped checkpoint and the audit full suite" FAIL
fi

if grep -qF -- '| 5. Checkpoint | Run the suites scoped to that phase' "$WORKFLOW_DOC" 2>/dev/null \
  && grep -qF -- '| 6. Audit & Final Report | The mandatory full-suite run for the test verdict' "$WORKFLOW_DOC" 2>/dev/null; then
  check "R17-P4 workflow doc phase table matches the scoped checkpoint rule" PASS
else
  check "R17-P4 workflow doc phase table matches the scoped checkpoint rule" FAIL
fi

# Phase 6 step 1 is now the chain's ONLY full-suite run, so the per-round re-run rule is
# what keeps a review round's test_evidence from describing a pre-fix tree. Unpinned, it
# could be deleted with every other row green.
if grep -qF -- "re-run this round's OWN scoped suites" "$AGENT" \
  && grep -qF -- 'describes a tree that no longer exists' "$AGENT"; then
  check "R17-P5 review-fix rounds re-run their own scoped suites and say why" PASS
else
  check "R17-P5 review-fix rounds re-run their own scoped suites and say why" FAIL
fi

if grep -qF -- '`{scoped_test_cmd}` over this phase' "$TPL_PLAN" 2>/dev/null \
  && grep -qF -- '+ `{lint_cmd}` pass' "$TPL_PLAN" 2>/dev/null \
  && grep -qF -- 'the full suite runs in the Phase 6 audit, not here — unless the Phase 5 fallback fires' "$TPL_PLAN" 2>/dev/null \
  && grep -qF -- '`{scoped_test_cmd}` (the runner' "$AGENT"; then
  check "R17-P6 plan template Checkpoint line teaches the scoped rule" PASS
else
  check "R17-P6 plan template Checkpoint line teaches the scoped rule" FAIL
fi

# AC-005: both stale cross-references corrected. Site-ANCHORED, not counted: a population
# count (>= 2 occurrences) goes green again as soon as any third sentence carries the same
# tagline, which would let either real site be reverted unnoticed — and it goes red for
# nothing if the two notes are ever merged onto one line.
if grep -qF -- '(Phase 5 checkpoints run the scoped suites, not per step; the Phase 6 audit runs the full suite either way, and the Phase 5 fallback is the only case that also runs it at a checkpoint.)' "$AGENT" \
  && grep -qF -- 'Scoped suites run at Phase 5 checkpoints (not per step, and except through the Phase 5 fallback); the full suite runs in the Phase 6 audit' "$AGENT"; then
  check "R17-P7 both Phase-5 cross-references point the full suite at Phase 6" PASS
else
  check "R17-P7 both Phase-5 cross-references point the full suite at Phase 6" FAIL
fi

# The chain's closing full-suite run is anchored on the ONE decidable moment. An earlier
# revision anchored it on "the last round before the terminus", which a model cannot
# identify prospectively — the loop's exit is decided by a reviewer that runs afterwards.
# The IMPERATIVE is the first conjunct, not the justification. Pinning only the two
# rationale clauses left the rule itself revertible: rewriting the imperative to "re-run
# this round's scoped suites" — exactly the regression this block exists to catch — kept
# both rationale literals byte-identical and this row green.
if grep -qF -- 'run the Phase 6 step 1 full-suite command again with `--if-stale`' "$AGENT" \
  && grep -qF -- 'this branch is the one decidable moment at which the chain knows it is converging' "$AGENT" \
  && grep -qF -- 'CONVERGENCE branch of step 10' "$AGENT"; then
  check "R17-P10 the closing full-suite run is anchored on the convergence branch" PASS
else
  check "R17-P10 the closing full-suite run is anchored on the convergence branch" FAIL
fi

SELF_REVIEW_MD="$PLUGIN_DIR/skills/self-review/SKILL.md"
if grep -qF -- "--evidence-run --scope full --cmd '<full test command>' --log <run-log>" "$SELF_REVIEW_MD" \
  && grep -qF -- 'the `cmd:` of the newest `EVIDENCE RUN — scope=full` line in the run log' "$SELF_REVIEW_MD" \
  && grep -qF -- 'Copy every `FULL SUITE — …` line the terminus' "$SELF_REVIEW_MD"; then
  check "R17-P11 the self-review fix round runs the full suite through the runner and the report carries the terminus verdict" PASS
else
  check "R17-P11 the self-review fix round runs the full suite through the runner and the report carries the terminus verdict" FAIL
fi

if grep -qF -- 'may run with `run_in_background`: its record lands when it finishes, and until then the terminus refuses the chain as `running`' "$AGENT" \
  && grep -qF -- '**Run each checkpoint command in the foreground, one tool call at a time**' "$AGENT" \
  && [ "$(grep -oF 'run_in_background' "$AGENT" | wc -l | tr -d ' ')" -eq 1 ]; then
  check "R17-P12 only the recorded full-suite run may go to the background, and the terminus waits for its record" PASS
else
  check "R17-P12 only the recorded full-suite run may go to the background, and the terminus waits for its record" FAIL
fi

if grep -qF -- '| scope: fallback-full' "$AGENT" \
  && grep -qF -- 'scope: fallback-full' "$WORKFLOW_DOC" \
  && ! grep -qE -- '\| scope: full[A-Za-z-]' "$AGENT"; then
  check "R17-P13 the fallback token is spelled fallback-full and no token prefix-extends full" PASS
else
  check "R17-P13 the fallback token is spelled fallback-full and no token prefix-extends full" FAIL
fi

# Round 15 — Native component root/data binding to eliminate cross-session races

if grep -qF '${CLAUDE_PLUGIN_ROOT}' "$AGENT" \
  && grep -qF 'CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}"' "$AGENT" \
  && ! grep -qF 'ZENSU_CLAUDE_PLUGIN_ROOT' "$AGENT" \
  && ! grep -qF '.zensu/plugin-root' "$AGENT"; then
  check "R15-P1 Phase 0 uses native root/data placeholders without legacy exports or pointer" PASS
else
  check "R15-P1 Phase 0 native root/data binding drifted or legacy authority returned" FAIL
fi

CANONICAL_ROOT_FAILURE='FATAL: active plugin root is unavailable — start a fresh Claude Code session'
ROOT_FAILURE_DRIFT=""
for skill in "$AGENT" "$AUTOPILOT_SKILL" "$PR_TEAM_REVIEW_SKILL" "$PR_FIX_FINDINGS_SKILL"; do
  if ! grep -qF "$CANONICAL_ROOT_FAILURE" "$skill"; then
    ROOT_FAILURE_DRIFT="${skill#$PLUGIN_DIR/}"
    break
  fi
done
if [ -z "$ROOT_FAILURE_DRIFT" ]; then
  check "R15-P2 native-root workflows share one byte-identical fail-closed diagnostic" PASS
else
  check "R15-P2 native-root failure diagnostic drifted in $ROOT_FAILURE_DRIFT" FAIL
fi

if grep -qF 'NEVER search the filesystem to "discover" the zensu-log.sh helper' "$AGENT"; then
  check "R15-P3 Hard Bans section forbids filesystem search for zensu-log.sh" PASS
else
  check "R15-P3 Hard Bans section forbids filesystem search for zensu-log.sh" FAIL
fi

if grep -qF 'bash ${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh' "$AGENT"; then
  CNT=$(grep -cF 'bash ${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh' "$AGENT")
  check "R15-P4 expected 0 unquoted native-root helper calls; found $CNT" FAIL
else
  check "R15-P4 zero unquoted native-root helper calls remain in agent" PASS
fi

SAFE_HELPER_COUNT=$(grep -cF 'CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh"' "$AGENT")
if [ "$SAFE_HELPER_COUNT" -ge 10 ]; then
  check "R15-P5 at least 10 native per-call helper bindings present (got $SAFE_HELPER_COUNT)" PASS
else
  check "R15-P5 expected >=10 native per-call helper bindings; got $SAFE_HELPER_COUNT" FAIL
fi

# Fix-round 2: Phase 0 validates the native component root rather than discovering one

if grep -qF 'ROOT="${CLAUDE_PLUGIN_ROOT}"' "$AGENT" \
  && grep -qF 'require `[ -f "$ROOT/hooks/lib/zensu-log.sh" ]`' "$AGENT" \
  && grep -qF 'pass the natively rendered `CLAUDE_PLUGIN_DATA` on every stateful helper invocation' "$AGENT"; then
  check "F1.a Phase 0 validates native CLAUDE_PLUGIN_ROOT and requires per-call plugin data" PASS
else
  check "F1.a Phase 0 native root/data validation contract" FAIL
fi

if grep -qF 'Never source the internal Session Control binder, discover or persist a replacement root, or cache plugin-private selectors yourself.' "$AGENT"; then
  check "F1.b Phase 0 forbids binder use, root discovery, persistence, and selector caching" PASS
else
  check "F1.b Phase 0 forbids binder use, root discovery, persistence, and selector caching" FAIL
fi

if grep -qF 'require `[ -f "$ROOT/hooks/lib/zensu-log.sh" ]`' "$AGENT" \
  && grep -qF 'on failure abort with:' "$AGENT" \
  && grep -qF 'start a fresh Claude Code session' "$AGENT"; then
  check "F1.c Phase 0 validates the helper and aborts to a fresh session" PASS
else
  check "F1.c Phase 0 validates the helper and aborts to a fresh session" FAIL
fi

if grep -qF '.zensu/plugin-root' "$AGENT" || grep -qF '{PLUGIN_ROOT}' "$AGENT"; then
  check "F1.d Phase 0 Step 1 contains no legacy root-pointer contract" FAIL
else
  check "F1.d Phase 0 Step 1 contains no legacy root-pointer contract" PASS
fi

# 0.4.0 — main-thread deferred-tool loading + correct TaskCreate signature
if grep -qF 'select:TaskCreate,TaskUpdate' "$AGENT"; then
  check "MT1 skill instructs ToolSearch load of deferred task tools (main-thread)" PASS
else
  check "MT1 skill instructs ToolSearch load of deferred task tools (main-thread)" FAIL
fi
if grep -qF 'requires BOTH `subject` and `description`' "$AGENT" && grep -qF 'description:' "$AGENT"; then
  check "MT2 skill TaskCreate includes required description + states the contract" PASS
else
  check "MT2 skill TaskCreate includes required description + states the contract" FAIL
fi
if grep -qF 'one tool call at a time' "$AGENT" && grep -qF 'not a parallel batch' "$AGENT"; then
  check "MT3 skill mandates serial tool calls; a backgrounded runner call is not a parallel batch" PASS
else
  check "MT3 skill mandates serial tool calls; a backgrounded runner call is not a parallel batch" FAIL
fi
if grep -qF 'in the same turn or batch as' "$AGENT"; then
  check "MT4 skill guards --chain-done against early/parallel firing" PASS
else
  check "MT4 skill guards --chain-done against early/parallel firing" FAIL
fi
if grep -qF 'plan file with the **Write tool**' "$AGENT" && ! grep -qF 'cat > .zensu/plans' "$AGENT"; then
  check "MT5 Phase 2 writes the plan via the Write tool (.zensu/ paths bypass the gate)" PASS
else
  check "MT5 Phase 2 writes the plan via the Write tool (.zensu/ paths bypass the gate)" FAIL
fi

# 0.5.1 — task usage hardened from soft prose to a mandatory contract + rationalization counter
if grep -qF 'Task Contract (MANDATORY)' "$AGENT"; then
  check "MT6 skill pins a mandatory per-step Task Contract (tasks = live dashboard)" PASS
else
  check "MT6 skill pins a mandatory per-step Task Contract (tasks = live dashboard)" FAIL
fi
if grep -qF 'Tasks are just UI noise' "$AGENT"; then
  check "MT7 Rationalization Counter: skipping tasks because the log tracks progress" PASS
else
  check "MT7 Rationalization Counter: skipping tasks because the log tracks progress" FAIL
fi

# Cross-Layer Value Flow Pairing rule (Principle 2)
if grep -qF 'Cross-Layer Value Flow Pairing' "$AGENT"; then
  check "X1 Principle 2 Cross-Layer Value Flow Pairing rule present" PASS
else
  check "X1 Principle 2 Cross-Layer Value Flow Pairing rule present" FAIL
fi

if grep -qF "Backend code didn't change, no test needed" "$AGENT"; then
  check "X2 Rationalization Counter: backend unchanged -> no test" PASS
else
  check "X2 Rationalization Counter: backend unchanged -> no test" FAIL
fi

if grep -qF 'Cross-layer detection (Principle 2):' "$AGENT"; then
  check "X3 Phase 1 step 6 Cross-layer detection instruction" PASS
else
  check "X3 Phase 1 step 6 Cross-layer detection instruction" FAIL
fi

if grep -qxF '## Cross-Layer Value Flow Pairings' "$TPL_PLAN" 2>/dev/null; then
  check "X4 Phase 2 plan template Cross-Layer Value Flow Pairings table" PASS
else
  check "X4 Phase 2 plan template Cross-Layer Value Flow Pairings table" FAIL
fi

if grep -qF '6b. **Cross-Layer Value Flow Audit**' "$AGENT"; then
  check "X5 Phase 6 step 6b Cross-Layer Value Flow Audit" PASS
else
  check "X5 Phase 6 step 6b Cross-Layer Value Flow Audit" FAIL
fi

if grep -qF 'CROSS-LAYER PAIRING MISSING' "$AGENT"; then
  check "X6 Phase 6 step 6b emits CROSS-LAYER PAIRING MISSING marker" PASS
else
  check "X6 Phase 6 step 6b emits CROSS-LAYER PAIRING MISSING marker" FAIL
fi

if grep -qF 'CROSS-LAYER PAIRING TEST-AFTER' "$AGENT"; then
  check "X7 Phase 6 step 6b emits CROSS-LAYER PAIRING TEST-AFTER marker" PASS
else
  check "X7 Phase 6 step 6b emits CROSS-LAYER PAIRING TEST-AFTER marker" FAIL
fi

if grep -qF 'CROSS-LAYER PAIRING MOCK-ONLY' "$AGENT"; then
  check "X8 Phase 6 step 6b emits CROSS-LAYER PAIRING MOCK-ONLY marker" PASS
else
  check "X8 Phase 6 step 6b emits CROSS-LAYER PAIRING MOCK-ONLY marker" FAIL
fi

# Plan-doc single-source-of-truth — the Steps-table Status column tracks completion.
# The plan template must carry ZERO GFM task-list checkboxes: nothing ever flipped them
# to [x], so generated plans always rendered "open items" no matter how the run finished.
CHECKBOX_COUNT=$(cat "$AGENT" "$TPL_PLAN" 2>/dev/null | grep -cE '^- \[[ xX]\]')
if [ "$CHECKBOX_COUNT" -eq 0 ]; then
  check "PB1 skill + plan template have zero GFM checkboxes (Status column is the only completion tracker)" PASS
else
  check "PB1 expected 0 GFM checkboxes in plan template; found $CHECKBOX_COUNT" FAIL
fi

echo "----"
echo "test-tdd-manager-patches: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
