# Wargame Output Structure

The shape every wargame doc follows. It exists so a mid-tier executor can run the mission blind, and so the plan is gradeable against the 8-point SUCCESS standard. Adapt the depth to the mission, but keep the skeleton — each part maps to a SUCCESS point.

Write the doc to the output path (default `wargames/NN-name.md`; see SKILL.md for path rules).

## Skeleton

```markdown
# Wargame: <mission name>

## Goal contract        ← include ONLY for /goal or prove/audit missions; see goal-contract.md
<the four-part contract>

## Recon summary
What was read/checked, read-only, and the facts it settled. Enough that the
executor inherits the context without redoing recon. Cite what you actually
read (file, URL, schema object, ZEN-XXX feature) — not assumptions.

## Moves
Numbered, in execution order. Each move:

### Move N — <imperative title>
- **Do**: the action, concrete enough to execute without a decision.
- **Expect**: exactly what you should observe if it worked. (SUCCESS 1)
- **Most likely failure**: the failure that actually tends to happen here,
  the cause it signals, and the counter-move. (SUCCESS 2)
- **Fork** (if any): if you observe <X>, take route B: <...>. A trigger, not
  a judgment call. (SUCCESS 3)

## RECON NEEDED
Assumptions recon could not settle, each with the EXACT check that settles it
and what each outcome implies. (SUCCESS 4) Omit the section only if genuinely none remain.

## Abort conditions
The moments to stop and flag rather than improvise — the states where continuing
does damage. (SUCCESS 5)

## Verification
The runs the executor performs to prove the mission worked: which run, when in
the sequence, and what PASS looks like for each. For contracted missions, these
must clear the evidence bar. (SUCCESS 6)

## Red-team record
The adversarial pass. The attack that FAILED against the plan (proof of
strength) and the attack that LANDED plus the patch it forced. For /goal
missions this is the cohort-until-parity result: rounds run, verdicts, parity
reached or not. For code/feature/audit missions, name which zensu:review-aspect
perspectives ran and what each returned. (SUCCESS 7)
```

## Notes

- **Executable blind is the bar** (SUCCESS 8). After drafting, reread as the executor: is there a single point where they'd have to stop and ask? Turn each such point into either a concrete instruction, a fork with a trigger, or a RECON NEEDED. That reread is the most valuable pass.
- **Observations must be observable.** "Expect: it works" fails the standard. "Expect: `GET /health` returns 200 with `{status:"ok"}`" passes. Anchor every Expect to something the executor can literally see.
- **Failures must be the likely ones.** Generic "it might error" is filler. Name the failure this specific move tends to hit and why.
- **Keep it lean.** A wargame is a route, not an essay. Cut prose that doesn't change what the executor does.
