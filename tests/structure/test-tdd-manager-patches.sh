#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT="$PLUGIN_DIR/agents/tdd-manager.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$AGENT" ]; then
  check "agents/tdd-manager.md exists" FAIL
  echo "----"
  echo "test-tdd-manager-patches: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "agents/tdd-manager.md exists" PASS

LINES=$(wc -l <"$AGENT")
if [ "$LINES" -le 320 ]; then
  check "agent line count <= 320 (actual: $LINES)" PASS
else
  check "agent line count <= 320 (actual: $LINES)" FAIL
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

echo "----"
echo "test-tdd-manager-patches: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
