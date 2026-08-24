## What

{Feature summary in plain words — what shipped and how it behaves.}

## Why

{The need this feature addresses; link the source issue/spec when one exists.}

## Acceptance criteria

One row per stable `AC-###`/`FR-###` ID taken from the feature's `## Requirements`
table. Deprecated rows stay listed (never deleted or renumbered) with status
`deprecated` and no evidence. When the feature has no usable `## Requirements`
table yet, keep the single stub row below and fill it in by hand — never ship an
empty table.

| AC | Criterion | Status | Evidence |
|----|-----------|--------|----------|
| AC-001 | {criterion} | {pass/fail/unvalidated/deprecated} | {evidence per active AC} |

## Verification

- Gates: {gate commands + results}
- Manual / live checks: {what was exercised, or none}
