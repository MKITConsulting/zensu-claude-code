# evals/reset-review-limit

Promptfoo eval suite for the `/zensu:reset-review-limit` skill (2 scenarios).

## What's here

| Path | Role |
|---|---|
| `promptfooconfig.yaml` | Suite config — no-agent provider so the slash-command is invoked directly via the wrapper. |
| `scenarios/reset-counter-happy.yaml` | Pre-seeds two counter files at `.zensu/state/rounds-eval-sess-{A,B}.json`, invokes `/zensu:reset-review-limit`, asserts both `Removed:` lines + `Reset complete: 2 counter file(s) deleted` summary + verifies the post-reset listing is empty. |
| `scenarios/reset-counter-empty.yaml` | Idempotency probe — invokes the skill against an empty `.zensu/state/`, asserts the no-op message (`No round counter files in` or `does not exist`) appears and that the skill does NOT claim removal. |
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

Both scenarios force a strict 2- or 3-step probe via the `spec_block` so the model cannot improvise alternative paths. The asserts pin literal substrings emitted by the skill's bash recipe (`Removed: <path>`, `Reset complete: <N> counter file(s) deleted`, `No round counter files in <STATE_DIR>`), not paraphrased equivalents — so any future drift in the skill's output schema regresses the eval.

The `must-not-match` asserts in `reset-counter-empty.yaml` are anchored (`^Removed:`m) to avoid false positives if the no-op message itself ever mentions "Removed" in a descriptive sentence.
