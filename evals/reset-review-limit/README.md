# evals/reset-review-limit

Promptfoo eval suite for the ticket-bound `/zensu:reset-review-limit` skill (2
fail-closed scope scenarios). The successful CAS path is deterministic shell
coverage in `tests/structure/test-reset-review-limit-skill.sh`; these live cases
check that a model never falls back to the pre-0.16 cross-session file scan.

## What's here

| Path | Role |
|---|---|
| `promptfooconfig.yaml` | Suite config — no-agent provider so the slash-command is invoked directly via the wrapper. |
| `scenarios/reset-counter-happy.yaml` | Sibling-containment probe: pre-seeds two decoy counters, invokes the skill without a current terminal ticket, and verifies both checksums remain unchanged. |
| `scenarios/reset-counter-empty.yaml` | Clean-session precondition probe: verifies the official getter fails closed without filesystem discovery or mutation. |
| `test-projects/empty-host/` | Minimal cloneable fixture (just `CLAUDE.md`). Each scenario writes its own `.zensu/state/` content via the Bash tool in the spec_block. |

## Gating

Real `claude --print` runs require:

- `promptfoo` (`npm install -g promptfoo`).
- `claude` CLI with a valid API key.
- The `zensu` plugin installed/loaded so `/zensu:reset-review-limit` resolves.

Without those, the structure test `tests/structure/test-promptfoo-reset-review-limit.sh` still validates the suite shape (yaml parseable, assertions present, fixture exists) — runs in plain CI.

## Running

```bash
cd evals/reset-review-limit
promptfoo eval -c promptfooconfig.yaml
```

`evaluateOptions.repeat: 3` runs each scenario 3 times against nondeterminism. `maxConcurrency: 2` keeps API load polite.

## Scenario semantics

Both scenarios pin a literal fail-closed result and prohibit legacy mutation
claims. The containment case compares checksums before and after invocation.
This deliberately validates scope behavior only: constructing a real consumed
review ticket belongs to the hermetic runtime test, not a live model fixture.
