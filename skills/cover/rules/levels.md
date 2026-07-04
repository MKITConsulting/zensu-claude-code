# Levels — the decision brain

How `/zensu:cover` decides, for each changed behavior, **which level of test faithfully
covers it** and **at which layer** — the part that makes the skill generic across any stack.
This encodes the old prose instruction ("FE/BE E2E where unit tests do not suffice, unit
tests where missing") as an explicit, language-agnostic decision.

## The decision matrix

Apply per changed behavior (a function, branch, component, endpoint, or flow), not per file:

| Signal about the behavior | Level | Layer |
|---|---|---|
| Output fully determined by one unit's inputs; no external I/O (pure logic, a branch, an edge case, a calculation, a validator) | **unit** | at the source (FE or BE) |
| A component's render / prop→DOM / user-event, exercised in isolation with no real backend | **component** | FE |
| Crosses a boundary you own — repo↔DB, controller↔service wiring, an HTTP request→response contract, serialization, an adapter to an external port | **integration / contract** | BE (or FE↔API) |
| A user-visible flow spanning FE→BE→persistence, or a requirement phrased as an acceptance criterion ("a user can …") | **E2E** | fullstack |

The matrix is a **starting point**; the five heuristics below arbitrate when a behavior could
sit at more than one level.

## The five heuristics

1. **Lowest-faithful-level.** Pick the cheapest level that still exercises the *real* risk.
   A pure calculation is a unit test even if it is reachable through the UI; only escalate
   when the risk genuinely lives at a boundary (→ integration) or in the cross-layer flow
   (→ E2E). Faithful first, cheap second — never so cheap the test stops exercising the risk.

2. **Pyramid budget.** Many unit, some integration, few E2E. E2E is reserved for the critical
   happy path plus the top one or two failure modes — not every branch. If a plan proposes an
   E2E test for something a unit test would catch, demote it. A fast, stable suite beats an
   exhaustive slow one.

3. **No-duplication.** Before authoring anything, scan the existing tests that already touch
   the target and only fill the **gap**. Duplicate coverage is waste and doubles maintenance.
   If existing tests already assert the behavior, record it as `Existing` in the plan and
   write nothing.

4. **Faithfulness / mutation.** Every new test must **fail if the behavior is broken**. No
   tautologies (`expect(sum(2,2)).toBe(sum(2,2))`), no asserting only that a function exists
   or was called — assert real outputs, state changes, and side effects. If mentally mutating
   the code under test would not turn the test red, the test is worthless. (Enforced by the
   spot-check in `quality.md`.)

5. **Coverage-mode inversion.** These tests cover code that **already exists**, so the cycle
   is inverted from TDD: the test must go **GREEN on first run**. A first-run **RED** is a
   signal, not progress — it means either the test is wrong (fix it) or the code is genuinely
   wrong (a real bug). Real bugs are **reported** (write the test as `xfail`/skip + flag),
   never silently patched. Coverage and bug-fixing stay separate reviewable acts.

## Gap analysis (the Phase 1 process)

Inputs:
- the set of changed behaviors (from the resolved `<target>` — a diff, feature, PR, glob, or
  described behavior),
- the existing tests that touch them (grep the test dirs the probe found),
- a coverage report if the stack produces one.

For each behavior: run the matrix → arbitrate with the heuristics → subtract existing coverage
→ emit one row of the plan table:

```
| Behavior | Level | Layer | Target test file | Driver | New/Existing |
```

The table is the reviewable artifact. It makes "which level, and why" explicit *before* any
test code is written, and it is where `--level` / `--layer` overrides are applied.

## Worked example

A change adds a `discountPercent` field: the UI form sends it, an existing service persists
it, and the checkout total reflects it.

- `discountPercent` validation (0–100, rejects negatives) → **unit** (BE validator) + **unit**
  (FE form validation) — pure input→output.
- Service persists and reads back `discountPercent` through the repository → **integration**
  (repo↔DB round-trip) — crosses a boundary you own; the unchanged persistence layer now
  carries a new field.
- "A user applies a 10% discount and sees the reduced total" → **E2E** (one flow) — user-visible,
  spans FE→BE→persistence; the single acceptance-criterion-level test.

Result: 3 unit, 1 integration, 1 E2E — a correct pyramid for one field, with the E2E reserved
for the actual user flow rather than duplicating the validator checks.
