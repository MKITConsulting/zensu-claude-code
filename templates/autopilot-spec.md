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

## Acceptance criteria
Stable `AC-###` IDs — allocated monotonically, never recycled; a dropped
criterion keeps its ID and is marked deprecated, never deleted or renumbered.
Each criterion is machine-checkable (verifiable by a test, a gate assertion,
or a concrete observation through the validation driver).

- AC-001: {machine-checkable criterion}
- AC-002: {machine-checkable criterion}

## Resolved recipe
| Seam | Command / driver |
|------|------------------|
| boot | {boot command} |
| gates | {gate commands} |
| auth | {login script or n/a} |
| validate | {driver: browser/api/cli/async/iac/custom} |
