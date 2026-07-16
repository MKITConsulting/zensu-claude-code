#!/bin/bash
# Current main-thread TDD ownership contract.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SKILL="$ROOT/skills/tdd/SKILL.md"
PASS=0; FAIL=0
check() { if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }

[ ! -e "$ROOT/agents/tdd-manager.md" ] \
  && check "retired tdd-manager agent is absent" PASS \
  || check "retired tdd-manager agent is absent" FAIL
grep -qF 'Run Phases 0–6 below in this conversation' "$SKILL" \
  && grep -qF 'Do NOT spawn a `tdd-manager` subagent' "$SKILL" \
  && check "TDD skill assigns implementation to the interactive main thread" PASS \
  || check "TDD skill main-thread ownership drifted" FAIL
grep -qF 'Implementation and fixes always remain in this main thread' "$SKILL" \
  && grep -qF 'neutral workers return read-only packets' "$SKILL" \
  && check "Workflow workers are analysis-only" PASS \
  || check "Workflow worker boundary drifted" FAIL
grep -qF "subagent_type='zensu:code-reviewer'" "$SKILL" \
  && check "reviewer remains the explicit post-implementation child" PASS \
  || check "reviewer dispatch contract drifted" FAIL

echo "----"
echo "assert-agent: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
