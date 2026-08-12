#!/bin/bash
set -u

# Structure test for the template system with repo override. Pins: the three
# plugin defaults under templates/ exist and carry their mandatory sections
# (tdd-plan: Requirements with ID/Covers, Preconditions, Cross-Layer heading,
# Status Legend, Steps header with Status+Covers, per-step Covers line, Final
# Verification; autopilot-spec: numbered stable AC-### criteria + out-of-scope
# + resolved recipe; autopilot-pr-body: per-AC table with deprecated note +
# the Gates-bypassed audit line); the resolution contract (override path
# .zensu/templates/<name>.md before the plugin default) is pinned in BOTH
# consumer skills and the docs/review-chain.md documents the wholesale-replace +
# mandatory-section contract. The inline plan block must be GONE from the tdd
# skill (the extraction is the point of this feature).

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TPL_PLAN="$PLUGIN_DIR/templates/tdd-plan.md"
TPL_SPEC="$PLUGIN_DIR/templates/autopilot-spec.md"
TPL_PR="$PLUGIN_DIR/templates/autopilot-pr-body.md"
TDD_MD="$PLUGIN_DIR/skills/tdd/SKILL.md"
AUTOPILOT_MD="$PLUGIN_DIR/skills/autopilot/SKILL.md"
REVIEW_DOC="$PLUGIN_DIR/docs/review-chain.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$TPL_PLAN" "$TPL_SPEC" "$TPL_PR" "$TDD_MD" "$AUTOPILOT_MD" "$REVIEW_DOC"; do
  if [ ! -f "$f" ]; then
    check "P0 required file exists: $f" FAIL
    echo "----"
    echo "test-templates: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "P0 three plugin templates + consumers exist" PASS

# P1 — tdd-plan.md mandatory sections
plan_pin() {
  local label="$1" needle="$2"
  if grep -qF -- "$needle" "$TPL_PLAN"; then
    check "$label" PASS
  else
    check "$label" FAIL
  fi
}
plan_pin_x() {
  local label="$1" needle="$2"
  if grep -qxF -- "$needle" "$TPL_PLAN"; then
    check "$label" PASS
  else
    check "$label" FAIL
  fi
}
plan_pin_x "P1a tdd-plan ## Requirements heading" '## Requirements'
plan_pin "P1b tdd-plan Requirements header" '| ID | Requirement | Source |'
plan_pin "P1c tdd-plan seeds an AC-### row" '| AC-001 |'
plan_pin "P1d tdd-plan seeds an FR-### row" '| FR-001 |'
plan_pin_x "P1e tdd-plan ## Preconditions heading" '## Preconditions'
plan_pin "P1f tdd-plan Preconditions header" '| Name | Type | Verification | Status | Decision |'
plan_pin_x "P1g tdd-plan Cross-Layer heading" '## Cross-Layer Value Flow Pairings'
plan_pin "P1h tdd-plan Status Legend row" '| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |'
plan_pin "P1i tdd-plan Steps header with Status+Covers" '| Step | Type | Description | Test File | Depends On | Status | Attempts | Covers |'
plan_pin "P1j tdd-plan per-step Covers line" '- **Covers**: {AC-###'
plan_pin_x "P1k tdd-plan ## Final Verification heading" '## Final Verification'

# P2 — autopilot templates
if grep -qF -- '- AC-001: {machine-checkable criterion}' "$TPL_SPEC" && grep -qiF 'never recycled' "$TPL_SPEC"; then
  check "P2a spec template seeds stable AC-### criteria" PASS
else
  check "P2a spec template seeds stable AC-### criteria" FAIL
fi
if grep -qxF '## Who it is NOT for / Out of scope' "$TPL_SPEC" && grep -qiF 'Resolved recipe' "$TPL_SPEC"; then
  check "P2b spec template carries out-of-scope + recipe sections" PASS
else
  check "P2b spec template carries out-of-scope + recipe sections" FAIL
fi
if grep -qF '| AC | Criterion | Status | Evidence |' "$TPL_PR" && grep -qiF 'deprecated' "$TPL_PR"; then
  check "P2c pr-body template carries the per-AC table + deprecated note" PASS
else
  check "P2c pr-body template carries the per-AC table + deprecated note" FAIL
fi
if grep -qF 'Gates bypassed during build:' "$TPL_PR"; then
  check "P2d pr-body template carries the bypass audit line" PASS
else
  check "P2d pr-body template carries the bypass audit line" FAIL
fi

# P3 — resolution contract in consumers
if grep -qF 'rev-parse --show-toplevel)/.zensu/templates/tdd-plan.md' "$TDD_MD" \
  && grep -qF 'when that file exists, else the plugin default' "$TDD_MD" \
  && grep -qF '${CLAUDE_PLUGIN_ROOT}/templates/tdd-plan.md' "$TDD_MD" \
  && grep -qF '`${CLAUDE_PLUGIN_ROOT}` is the active plugin installation supplied to this skill component' "$TDD_MD" \
  && ! grep -qF '${ZENSU_CLAUDE_PLUGIN_ROOT' "$TDD_MD"; then
  check "P3a tdd Phase 2 resolves override then the natively rendered plugin default" PASS
else
  check "P3a tdd Phase 2 resolves override then the natively rendered plugin default" FAIL
fi
if grep -qiE 'replaces the default wholesale' "$TDD_MD" && grep -qF 'MUST keep the mandatory sections' "$TDD_MD"; then
  check "P3b tdd documents the wholesale-replace + mandatory contract" PASS
else
  check "P3b tdd documents the wholesale-replace + mandatory contract" FAIL
fi
if ! grep -qF '# TDD Plan: {Feature Title}' "$TDD_MD"; then
  check "P3c inline plan block removed from the tdd skill" PASS
else
  check "P3c inline plan block removed from the tdd skill" FAIL
fi
if grep -qF 'rev-parse --show-toplevel)/.zensu/templates/autopilot-spec.md' "$AUTOPILOT_MD" && grep -qF 'templates/autopilot-spec.md` under the validated session plugin root' "$AUTOPILOT_MD" && grep -qF 'when that file' "$AUTOPILOT_MD" && grep -qF 'exists, else' "$AUTOPILOT_MD"; then
  check "P3d autopilot 0.C resolves the spec template" PASS
else
  check "P3d autopilot 0.C resolves the spec template" FAIL
fi
if grep -qF 'rev-parse --show-toplevel)/.zensu/templates/autopilot-pr-body.md' "$AUTOPILOT_MD" && grep -qF 'templates/autopilot-pr-body.md` under the validated session plugin root' "$AUTOPILOT_MD"; then
  check "P3e autopilot step 3 resolves the pr-body template" PASS
else
  check "P3e autopilot step 3 resolves the pr-body template" FAIL
fi

# P4 — README contract
if grep -qF '#### Templates (repo-overridable)' "$REVIEW_DOC" && grep -qF '.zensu/templates/<name>.md' "$REVIEW_DOC"; then
  check "P4a docs/review-chain.md documents names + resolution order" PASS
else
  check "P4a docs/review-chain.md documents names + resolution order" FAIL
fi
if grep -qiF 'REPLACES the default wholesale' "$REVIEW_DOC" && grep -qF 'tdd-plan.md' "$REVIEW_DOC" && grep -qF 'autopilot-spec.md' "$REVIEW_DOC" && grep -qF 'autopilot-pr-body.md' "$REVIEW_DOC"; then
  check "P4b docs/review-chain.md documents the override contract for all three" PASS
else
  check "P4b docs/review-chain.md documents the override contract for all three" FAIL
fi

echo "----"
echo "test-templates: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
