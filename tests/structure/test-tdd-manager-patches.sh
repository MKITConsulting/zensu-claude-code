#!/bin/bash
set -u

# NOTE (0.4.0): the TDD discipline patches migrated from the deleted
# agents/tdd-manager.md subagent into the main-thread skill skills/tdd/SKILL.md.
# This test now pins that content in its new home.
PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT="$PLUGIN_DIR/skills/tdd/SKILL.md"

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
if [ "$LINES" -le 360 ]; then
  check "skill line count <= 360 (actual: $LINES)" PASS
else
  check "skill line count <= 360 (actual: $LINES)" FAIL
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
if grep -qF '## Preconditions' "$AGENT"; then
  check "P4 Preconditions table heading in plan template" PASS
else
  check "P4 Preconditions table heading in plan template" FAIL
fi
if grep -qF '| Name | Type | Verification | Status | Decision |' "$AGENT"; then
  check "P4 Preconditions table columns" PASS
else
  check "P4 Preconditions table columns" FAIL
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

if grep -qF 'MANDATORY' "$AGENT" && grep -qF 'CHECKPOINT — cmd="' "$AGENT" && grep -qF 'exit=' "$AGENT"; then
  check "R14-P1 Phase 5 mandates CHECKPOINT cmd= exit= log entry contract" PASS
else
  check "R14-P1 Phase 5 mandates CHECKPOINT cmd= exit= log entry contract" FAIL
fi

if grep -qF 'AUDIT — cmd="' "$AGENT" && grep -qF 'EVIDENCE GAP' "$AGENT" && grep -qF 'witness log' "$AGENT"; then
  check "R14-P2 Phase 6 step 1 mandates AUDIT cmd= cross-check + EVIDENCE GAP marker against witness log" PASS
else
  check "R14-P2 Phase 6 step 1 mandates AUDIT cmd= cross-check + EVIDENCE GAP marker against witness log" FAIL
fi

if grep -qF 'Test Evidence' "$AGENT" && grep -qF 'via=' "$AGENT"; then
  check "R14-P3 Phase 6 schema includes Test Evidence section + via= non-Bash escape clause" PASS
else
  check "R14-P3 Phase 6 schema includes Test Evidence section + via= non-Bash escape clause" FAIL
fi

# Round 15 — Plugin root resolution to eliminate helper-discovery improvisation

if grep -qF '$HOME/.zensu/plugin-root' "$AGENT" && grep -qF '{PLUGIN_ROOT}' "$AGENT"; then
  check "R15-P1 Phase 0 references \$HOME/.zensu/plugin-root and {PLUGIN_ROOT}" PASS
else
  check "R15-P1 Phase 0 references \$HOME/.zensu/plugin-root and {PLUGIN_ROOT}" FAIL
fi

if grep -qF 'FATAL: plugin root unresolvable' "$AGENT"; then
  check "R15-P2 Phase 0 contains FATAL abort message when plugin-root file missing" PASS
else
  check "R15-P2 Phase 0 contains FATAL abort message when plugin-root file missing" FAIL
fi

if grep -qF 'NEVER search the filesystem to "discover" the zensu-log.sh helper' "$AGENT"; then
  check "R15-P3 Hard Bans section forbids filesystem search for zensu-log.sh" PASS
else
  check "R15-P3 Hard Bans section forbids filesystem search for zensu-log.sh" FAIL
fi

if grep -cF '$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-log.sh' "$AGENT" | grep -qE '^0$'; then
  check "R15-P4 zero literal '\$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-log.sh' invocations remain in agent" PASS
else
  CNT=$(grep -cF '$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-log.sh' "$AGENT")
  check "R15-P4 expected 0 \$CLAUDE_PLUGIN_ROOT helper calls; found $CNT" FAIL
fi

PLACEHOLDER_COUNT=$(grep -cF '{PLUGIN_ROOT}/hooks/lib/zensu-log.sh' "$AGENT")
if [ "$PLACEHOLDER_COUNT" -ge 10 ]; then
  check "R15-P5 at least 10 '{PLUGIN_ROOT}/hooks/lib/zensu-log.sh' invocations present (got $PLACEHOLDER_COUNT)" PASS
else
  check "R15-P5 expected >=10 {PLUGIN_ROOT} helper invocations; got $PLACEHOLDER_COUNT" FAIL
fi

# Fix-round 2: finding 2 — Phase 0 Step 1 uses explicit Bash invocation, not ambiguous "Read"

if grep -qF "bash -c 'cat \"\$HOME/.zensu/plugin-root\"'" "$AGENT"; then
  check "F1.a Phase 0 Step 1 uses explicit \`bash -c 'cat \"\$HOME/.zensu/plugin-root\"'\` invocation" PASS
else
  check "F1.a Phase 0 Step 1 uses explicit \`bash -c 'cat \"\$HOME/.zensu/plugin-root\"'\` invocation" FAIL
fi

if grep -qF 'trimmed output' "$AGENT"; then
  check "F1.b Phase 0 Step 1 instructs trimmed-output handling (no trailing newline)" PASS
else
  check "F1.b Phase 0 Step 1 instructs trimmed-output handling (no trailing newline)" FAIL
fi

if grep -qF 'hooks.pulseSession is not set to false' "$AGENT"; then
  check "F1.c Phase 0 Step 1 FATAL message mentions hooks.pulseSession" PASS
else
  check "F1.c Phase 0 Step 1 FATAL message mentions hooks.pulseSession" FAIL
fi

if grep -qF 'Read `$HOME/.zensu/plugin-root` and store its contents' "$AGENT"; then
  check "F1.d Phase 0 Step 1 no longer uses the legacy 'Read \`\$HOME/.zensu/plugin-root\` and store its contents' phrasing" FAIL
else
  check "F1.d Phase 0 Step 1 no longer uses the legacy 'Read \`\$HOME/.zensu/plugin-root\` and store its contents' phrasing" PASS
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
if grep -qF 'never `run_in_background`' "$AGENT" && grep -qF 'one tool call at a time' "$AGENT"; then
  check "MT3 skill mandates foreground, serial evidence runs (no parallel/background)" PASS
else
  check "MT3 skill mandates foreground, serial evidence runs (no parallel/background)" FAIL
fi
if grep -qF 'in the same turn or batch as' "$AGENT"; then
  check "MT4 skill guards --chain-done against early/parallel firing" PASS
else
  check "MT4 skill guards --chain-done against early/parallel firing" FAIL
fi
if grep -qF 'cat > .zensu/plans' "$AGENT"; then
  check "MT5 Phase 2 writes the plan via Bash heredoc (phase-gate blocks Write in UNINITIALIZED)" PASS
else
  check "MT5 Phase 2 writes the plan via Bash heredoc (phase-gate blocks Write in UNINITIALIZED)" FAIL
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

echo "----"
echo "test-tdd-manager-patches: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
