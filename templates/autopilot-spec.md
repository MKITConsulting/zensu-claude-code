# Spec: {Feature Title}

## What it does
{One-paragraph description of the feature in plain words.}

## Who it is for
{Primary users / consumers of the feature.}

## Who it is NOT for / Out of scope
- {Explicit non-goal or excluded audience}
- {Deferred concern}

## Success looks like
{Observable end state when the feature works.}

## Requirements
Stable `AC-###` IDs — allocated monotonically, never recycled; a dropped
criterion keeps its ID and its row is marked `(deprecated)`, never deleted or
renumbered. Each acceptance criterion is machine-checkable (verifiable by a
test, a gate assertion, or a concrete observation through the validation
driver), and Phase 1 validates exactly these rows.

| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | {machine-checkable criterion} | spec |
| AC-002 | {machine-checkable criterion} | spec |

## Manual Acceptance
(Optional. One row per active `AC-###` criterion this run's environment cannot observe, which the
user accepts as partial when approving this spec: it needs credentials, an account, a
non-loopback host or a signed build, or its driver cannot run here, or a driver fence rules the
state out (the `browser` driver blocks service workers). VALIDATE accepts a `partial`
criterion only when this table of the approved spec lists it, because the run asks no question.
The Consent cell names where and when the consent was given, never a person, an account, an
email address or an internal hostname. Omit the section when every criterion can be observed.)

| Criterion | Check a person runs before release | Why this environment cannot observe it | Consent |
|-----------|------------------------------------|----------------------------------------|---------|
| {AC-###} | {the manual check} | {credentials / account / non-loopback host / signed build / driver cannot run here / driver fence} | {consent source and date, e.g. spec approval, 2026-11-15} |

## Resolved recipe
| Seam | Command / driver |
|------|------------------|
| boot | {boot command} |
| gates | {gate commands} |
| auth | {login script or n/a} |
| validate | {driver: browser/api/cli/library/async/iac/mobile/desktop/custom} |
