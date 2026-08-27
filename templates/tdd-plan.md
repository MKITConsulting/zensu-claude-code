# TDD Plan: {Feature Title}

<!--
Authoring rules — this file is written to be COMMITTED. Consuming repos keep
.zensu/plans/ as an audit trail and may later open-source the repository.
  * English only, whatever language the session is conducted in.
  * No absolute paths: name files by their repo-root-relative path. The
    PostToolUse redactor (hooks/post-artifact-redact.sh) rewrites the roots it
    recognizes into <project> / ~ / <home>, but it cannot recognize a customer
    name, an internal hostname, or a credential pasted into the Context section.
-->

## Context
{Spec verbatim}
**Approach**: Strict Red/Green TDD | **Tech Stack**: {stack} | **Coverage**: {coverage_cmd or "SKIPPED"} @ {threshold} ({threshold_source})

## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | {acceptance criterion — machine-checkable} | spec |
| FR-001 | {functional requirement} | spec |

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| {name} | CLI/secret/endpoint/fixture | `{verify_cmd}` | present/missing | install / substitute=`{user-named}` / skip |

## Cross-Layer Value Flow Pairings
(Per Principle 2 — Cross-Layer Value Flow Pairing. Omit table body if no pairings; keep the heading so Phase 6 audit can detect absence vs zero rows.)

| Feature Step | New Value | Unchanged Layer (file / module) | Characterization Step | Seam Asserted |
|--------------|-----------|---------------------------------|------------------------|----------------|
| {step_id_A} | {field}=`{example}` | {path} | {step_id_B} | DB row / response body / persisted file / returned struct |

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts | Covers |
|------|------|-------------|-----------|------------|--------|----------|--------|

### Step {id} — {Description}
- **Covers**: {AC-###, FR-### — the requirement IDs this step implements}
- **RED**: Test `{name}` — {what}, {why fails}
- **GREEN**: {what to implement}

**Checkpoint**: `{scoped_test_cmd}` over this phase's changed files and the suites that import or invoke them + `{lint_cmd}` pass (the full suite runs in the Phase 6 audit, not here — unless the Phase 5 fallback fires)

## Final Verification
- All test suites pass
- Coverage report generated for changed files (threshold: {threshold})
