#!/bin/bash
set -u

# Structure test for stable requirement IDs + traceable spec artifact (P1-1).
# Pins: the plugin plan template (templates/tdd-plan.md) carries a ## Requirements table with stable
# AC-###/FR-### IDs, the Steps table + step detail carry a Covers mapping, the
# never-recycle allocation rule is stated, and Phase 6 runs a warning-level
# requirements coverage cross-check; the autopilot SKILL assigns stable AC-###
# IDs in the spec phase, pins the never-recycle rule, and keys the PR-body
# checklist by AC-###; the chain-end summary directive mentions per-requirement
# status; the workflow doc documents the Requirements table; the cover skill's
# --from-acs contract emits tests keyed by active AC-### IDs. It intentionally
# does NOT assert version sync or README counts — those are owned by sibling
# tests.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TDD_MD="$PLUGIN_DIR/skills/tdd/SKILL.md"
TPL_PLAN="$PLUGIN_DIR/templates/tdd-plan.md"
AUTOPILOT_MD="$PLUGIN_DIR/skills/autopilot/SKILL.md"
SELF_REVIEW_MD="$PLUGIN_DIR/skills/self-review/SKILL.md"
COVER_MD="$PLUGIN_DIR/skills/cover/SKILL.md"
DELEGATE_SH="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
WORKFLOW_DOC="$PLUGIN_DIR/docs/tdd-manager-workflow.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$TDD_MD" "$TPL_PLAN" "$AUTOPILOT_MD" "$SELF_REVIEW_MD" "$COVER_MD" "$DELEGATE_SH" "$WORKFLOW_DOC"; do
  if [ ! -f "$f" ]; then
    check "P0 required file exists: $f" FAIL
    echo "----"
    echo "test-plan-requirement-ids: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "P0 all target files exist" PASS

# P1 — plugin plan template (templates/tdd-plan.md): Requirements table with stable IDs
# P1a uses exact-line match: backticked prose mentions of `## Requirements`
# elsewhere in the skill must not satisfy the heading pin.
if grep -qxF "## Requirements" "$TPL_PLAN"; then
  check "P1a plan template has a ## Requirements section heading" PASS
else
  check "P1a plan template has a ## Requirements section heading" FAIL
fi
PINS_TDD=(
  "P1b Requirements table header (ID / Requirement / Source)|| ID | Requirement | Source |"
  "P1c template seeds an AC-### row|| AC-001 |"
  "P1d template seeds an FR-### row|| FR-001 |"
)
for entry in "${PINS_TDD[@]}"; do
  label="${entry%%|*}"; needle="${entry#*|}"
  if grep -qF "$needle" "$TPL_PLAN"; then
    check "$label" PASS
  else
    check "$label" FAIL
  fi
done

# P2 — plugin plan template: per-step Covers traceability (Steps table column + detail line)
if grep -qF "| Step | Type | Description | Test File | Depends On | Status | Attempts | Covers |" "$TPL_PLAN"; then
  check "P2a Steps table carries a Covers column" PASS
else
  check "P2a Steps table carries a Covers column" FAIL
fi
if grep -qF -- "- **Covers**: {AC-###" "$TPL_PLAN"; then
  check "P2b step detail carries a Covers line" PASS
else
  check "P2b step detail carries a Covers line" FAIL
fi

# P3 — tdd SKILL: never-recycle allocation rule + ID adoption at the autopilot seam
if grep -qF "Requirement-ID allocation rule" "$TDD_MD" && grep -qF "NEVER reused" "$TDD_MD" && grep -qF "marked deprecated in the Requirement column" "$TDD_MD"; then
  check "P3a tdd SKILL pins the never-recycle allocation rule" PASS
else
  check "P3a tdd SKILL pins the never-recycle allocation rule" FAIL
fi
if grep -qF "adopt them verbatim" "$TDD_MD" && grep -qF "above the highest ID seen" "$TDD_MD"; then
  check "P3b tdd SKILL pins the incoming-ID adoption rule" PASS
else
  check "P3b tdd SKILL pins the incoming-ID adoption rule" FAIL
fi

# P4 — tdd SKILL Phase 6: warning-level requirements coverage cross-check
if grep -qF "Requirements Coverage Cross-Check" "$TDD_MD" && grep -qF "REQUIREMENT COVERAGE WARNING" "$TDD_MD"; then
  check "P4a Phase 6 runs the requirements coverage cross-check" PASS
else
  check "P4a Phase 6 runs the requirements coverage cross-check" FAIL
fi
if grep -qF "does NOT mark Phase 6 incomplete" "$TDD_MD"; then
  check "P4b the cross-check is warning level (not a completion blocker)" PASS
else
  check "P4b the cross-check is warning level (not a completion blocker)" FAIL
fi
if grep -qF "legacy plan" "$TDD_MD" && grep -qF "skip silently" "$TDD_MD"; then
  check "P4c legacy plans without a Requirements table skip silently" PASS
else
  check "P4c legacy plans without a Requirements table skip silently" FAIL
fi
if grep -qF "not marked deprecated" "$TDD_MD"; then
  check "P4d deprecated requirement rows are exempt from the cross-check" PASS
else
  check "P4d deprecated requirement rows are exempt from the cross-check" FAIL
fi

# P5 — autopilot SKILL: stable AC-### IDs + never-recycle + per-AC checklist
if grep -qF 'stable `AC-###` IDs' "$AUTOPILOT_MD"; then
  check "P5a autopilot spec phase assigns stable AC-### IDs" PASS
else
  check "P5a autopilot spec phase assigns stable AC-### IDs" FAIL
fi
if grep -qF "never recycled" "$AUTOPILOT_MD" && grep -qF "never delete or renumber" "$AUTOPILOT_MD"; then
  check "P5b autopilot pins the never-recycle allocation rule" PASS
else
  check "P5b autopilot pins the never-recycle allocation rule" FAIL
fi
if grep -qF "per-AC checklist table keyed" "$AUTOPILOT_MD"; then
  check "P5c PR body carries a per-AC checklist keyed by AC-###" PASS
else
  check "P5c PR body carries a per-AC checklist keyed by AC-###" FAIL
fi
if grep -qF 'every non-deprecated AC by its `AC-###` ID' "$AUTOPILOT_MD"; then
  check "P5d validation loop asserts every non-deprecated AC by its ID" PASS
else
  check "P5d validation loop asserts every non-deprecated AC by its ID" FAIL
fi
if grep -qF "until all non-deprecated ACs pass" "$AUTOPILOT_MD"; then
  check "P5e loop exit condition excludes deprecated ACs" PASS
else
  check "P5e loop exit condition excludes deprecated ACs" FAIL
fi

# P6 — chain-end summary mentions per-requirement status in BOTH template owners:
# the hook directive (selfReview off) and the self-review Final report (default path)
if grep -qF "## Requirements table" "$DELEGATE_SH" && grep -qF "AC-###/FR-###" "$DELEGATE_SH"; then
  check "P6a hook CHAIN-END SUMMARY directive covers per-requirement status" PASS
else
  check "P6a hook CHAIN-END SUMMARY directive covers per-requirement status" FAIL
fi
if grep -qF "## Requirements table" "$SELF_REVIEW_MD" && grep -qF "AC-###/FR-###" "$SELF_REVIEW_MD"; then
  check "P6b self-review Final report covers per-requirement status (default path)" PASS
else
  check "P6b self-review Final report covers per-requirement status (default path)" FAIL
fi

# P7 — workflow doc documents the Requirements table + audit cross-check + summary extension
if grep -qF "Requirements table (stable AC-###/FR-### IDs)" "$WORKFLOW_DOC"; then
  check "P7a workflow doc documents the plan Requirements table" PASS
else
  check "P7a workflow doc documents the plan Requirements table" FAIL
fi
if grep -qF "requirements coverage cross-check (warning level)" "$WORKFLOW_DOC"; then
  check "P7b workflow doc documents the warning-level cross-check" PASS
else
  check "P7b workflow doc documents the warning-level cross-check" FAIL
fi
if grep -qF "per-requirement status keyed by its stable AC-###/FR-### IDs" "$WORKFLOW_DOC"; then
  check "P7c workflow doc documents the summary's per-requirement status" PASS
else
  check "P7c workflow doc documents the summary's per-requirement status" FAIL
fi

# P8 — cover --from-acs contract is keyed by stable IDs and skips deprecated ACs,
# in BOTH owners: the SKILL.md flags row and the rules/drivers.md mapping section
if grep -qF 'per active `AC-###` ID' "$COVER_MD" && grep -qF "deprecated are skipped" "$COVER_MD"; then
  check "P8a cover SKILL --from-acs emits tests keyed by active AC-### IDs" PASS
else
  check "P8a cover SKILL --from-acs emits tests keyed by active AC-### IDs" FAIL
fi
COVER_DRIVERS_MD="$PLUGIN_DIR/skills/cover/rules/drivers.md"
if grep -qF 'per active `AC-###` ID' "$COVER_DRIVERS_MD" && grep -qF "deprecated are skipped" "$COVER_DRIVERS_MD"; then
  check "P8b cover rules/drivers.md --from-acs mapping keyed by active AC-### IDs" PASS
else
  check "P8b cover rules/drivers.md --from-acs mapping keyed by active AC-### IDs" FAIL
fi

echo "----"
echo "test-plan-requirement-ids: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
