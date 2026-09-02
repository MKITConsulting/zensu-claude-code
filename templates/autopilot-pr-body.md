## What

{Feature summary in plain words — what shipped and how it behaves.}

## Why

{The need this feature addresses; link the source issue/spec when one exists.}

## Acceptance criteria

One row per stable `AC-###` ID — deprecated rows stay listed (never deleted or
renumbered) with status `⚪ deprecated` and no evidence. Each Status carries a
leading marker so the column is scannable: 🟢 pass, 🟡 partial, 🟡 unvalidated,
🔴 fail, ⚪ deprecated. The marker prefixes the word and never replaces it, and ⚪ is
bound to provenance — use it only for a row the spec already marks deprecated.

| AC | Criterion | Status | Evidence |
|----|-----------|--------|----------|
| AC-001 | {criterion} | {🟢 pass / 🟡 partial / 🟡 unvalidated / 🔴 fail / ⚪ deprecated} | {evidence per active AC} |

## Verification

- Gates: {gate commands + results}
- Validation driver: {driver + what was exercised}
- Gates bypassed during build: {list|none|UNREADABLE — …}

{Converge report note when findings were folded in, or remove this line.}
