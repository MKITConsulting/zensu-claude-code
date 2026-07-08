# The Goal Contract + Cohort-Until-Parity Loop

Read this when a mission is best framed as a **goal to prove**, not just a route to plan — audits, correctness proofs, invariant checks, coverage sweeps, security reviews, "prove X can never happen." Also read it whenever the user opens with `/goal ...`.

## Why a goal contract

A wargame gives you the route. A goal contract gives you the **win condition the route must satisfy** — stated tight enough that "done" is not a judgment call. Without it, a plan drifts: the executor does *something* plausible and declares victory. The contract is the referee.

A goal contract is short. It is the header of the wargame, not a second document.

## The four parts of a contract

Every goal contract states these. If the user's `/goal` line is terse, infer the parts from it and write them out explicitly — then confirm the risky inferences with a `RECON NEEDED`.

1. **Objective + exhaustiveness** — what must be proven, and over what set. "Every mutation of X" means you first enumerate the set (every mutation path, every status, every ownership state) and then the contract binds you to *all* of it, not a sample. Name the enumeration source (schema, state machine, route table) so coverage is checkable, not vibes.

2. **Invariants to prove or break** — the specific properties that must hold, written as things you actively try to violate. "Flag anything with more than one owner, or that can have multiple write owners" is an invariant: single-writer ownership. The job is to *find a counterexample or prove none exists*, per invariant.

3. **Evidence bar** — what counts as proof. "E2E against a live schema, no mock tests" is a bar: a claim only lands if it was exercised against the real system end to end. Mocks, dry reasoning, and "should work" do not clear the bar. State the bar so a finding with weaker evidence is rejected automatically.

4. **Convergence loop** — when to stop. "Run your findings through a cohort until you have parity" defines done as *consensus across independent checks*, not one pass. See below.

## Contract format

Write the contract at the top of the wargame doc:

```markdown
## Goal contract

- **Objective**: prove <property> over <the full set>, enumerated from <source>.
- **Exhaustiveness**: <how the set is enumerated and how coverage is measured>.
- **Invariants** (each: hold or produce a counterexample):
  - INV-1: <e.g. every data point has exactly one write-owner at all times>
  - INV-2: <...>
- **Evidence bar**: <e.g. every claim exercised E2E against the live schema; no mocks; reproduction command recorded>.
- **Convergence**: cohort of independent verifiers; done at parity (see loop).
- **Out of scope**: <what this contract does NOT cover>.
```

The wargame moves below the contract are then the route that *discharges* it: recon that enumerates the set, moves that test each invariant, verification that meets the evidence bar.

## Cohort-until-parity loop

"Parity" = independent checks agree and stop surfacing new results. One reviewer proves nothing; a cohort that converges does. Use this in the refinement phase (SUCCESS point 7, strengthened).

There are two cohort backends. Pick by mission type:

### Code / feature / audit missions → reuse the Zensu review chain

When the findings are about real code — an ownership audit, a bug hunt, a correctness/security proof over a repo or a `ZEN-XXX` feature — do **not** invent ad-hoc verifiers. The plugin already ships a battle-tested cohort with a merge step:

1. **Fan out `zensu:review-aspect` ×5** in one parallel batch — one per perspective (`conventions`, `bugs`, `architecture`, `tests`, `security`). Each spawn prompt MUST name the perspective and the files under scrutiny, e.g.:
   `Perspective: security. Files changed: [internal/orders/write.go, db/schema.sql]`
   Point them at the files your findings cite. Each is read-only and returns findings for its one lens.
2. **Merge in the main thread**, then optionally run `zensu:code-reviewer` for a consolidated pass.
3. **Measure parity** against the merged set: parity holds when the perspectives agree on every finding AND a round surfaces nothing new. A new or contradicted finding = not converged → fold it in, re-point the aspects at the changed scope, run another round.

This keeps one verification machine across Zensu, lands findings in the review chain's format, and reuses the same lenses `/zensu:tdd` trusts. The five perspectives are code lenses — that is exactly why they fit code/audit missions and why the non-code path below exists.

### Non-code missions → diverse ad-hoc verifiers

When the mission has no code substrate (a tax plan, offer copy, a competitive analysis, a process design), the five code lenses do not map. Spawn a small cohort (default 3) of independent verifiers, each blind to the others, each given a distinct lens the property allows (e.g. for a tax plan: one checks legality, one checks arithmetic against the raw figures, one checks that each claim cites a real rule). Give each the contract's evidence bar and tell it to try to *break* the claim, defaulting to "refuted" when evidence is thin.

### Both backends

- Only claims that survive the cohort at parity go in the final report.
- Track rounds; if it will not converge after a sensible cap, that non-convergence is itself the finding — report it, do not fake agreement.
- Evidence-free verdicts are dropped regardless of backend.

## How it changes the SUCCESS grade

A contracted wargame must additionally satisfy:

- Coverage is measured against the enumerated set, and the doc says what fraction is covered and what is not (ties to point 4, RECON NEEDED).
- Every surviving claim cleared the stated evidence bar (strengthens point 6).
- The doc records the cohort rounds and the parity result — the attacks that failed and the patches from the ones that landed. For code missions, cite which `review-aspect` perspectives ran and what they returned (this IS point 7, made concrete).
