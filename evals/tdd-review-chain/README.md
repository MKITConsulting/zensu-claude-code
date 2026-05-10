# TDD → Review-Chain Hook E2E Eval

End-to-end tests for the `SubagentStop` hook on `zensu:tdd-manager` that
auto-invokes `@zensu:code-reviewer`.

## What it tests

| Test | Type | Asserts |
|------|------|---------|
| Structural | Offline | `hooks.json` is valid JSON; `assert-config.sh` / `assert-agent.sh` / `assert-version.sh` / `assert-changelog.sh` confirm the expected file states |
| T3 judge-pass | Offline | The hook prompt literal in `hooks/hooks.json` names `@zensu:code-reviewer`, is imperative, and is not weakened with phrases like "consider"/"if you want"/"may"/"optional" |
| T1 positive | Slow (E2E) | Spawning `zensu:tdd-manager` makes the SubagentStop hook fire AND the main agent dispatches `zensu:code-reviewer` AND the reviewer's own SubagentStop hook fires AND a review marker appears in output |
| T2 isolation | Slow (E2E) | Spawning a non-tdd-manager subagent (`zensu:zensu-plm`) does NOT fire the tdd-manager SubagentStop hook AND the reviewer is NOT dispatched |
| T4 PostToolUse probe | SKIP | Reserved for empirical PostToolUse-on-Task data collection. Currently disabled — fabricated env-var approach does not load the experiment hook. |

## Run

```bash
./evals/tdd-review-chain/run-eval.sh              # full suite (T1 + T2 ~ 5-12 min)
./evals/tdd-review-chain/run-eval.sh --self-check # offline structural + T3 only (~1 s)
```

Requires:
- `expect` (`brew install expect` on macOS — usually preinstalled)
- `claude` CLI on `$PATH`
- `node` (used inline by run-eval.sh for prompt-literal extraction)

Results land in `evals/tdd-review-chain/results/`:
- `report-<timestamp>.txt` — PASS/FAIL summary
- `t1-<timestamp>.out` / `t1-<timestamp>.debug.log` — TUI capture + Claude debug log for the positive test
- `t2-<timestamp>.out` / `t2-<timestamp>.debug.log` — same for the isolation test

## Why it's slow

T1 and T2 spawn real interactive Claude sessions. T1 in particular runs the
full `zensu:tdd-manager` cycle which can take 2–8 minutes depending on the
fixture spec. Do not run in CI without a generous budget.

## Known limits

- T4 is currently SKIP — the original design used a fabricated
  `CLAUDE_PLUGIN_ROOT_OVERRIDE` env var that Claude does not read, so the
  experiment hook never loaded and the result was always misleading. Re-enable
  once stacked `--plugin-dir` support or temp hook injection lands.
- The `tool=Agent.*code-reviewer` family of regexes assume Claude debug
  formatter keeps related fields on the same line. If the debug formatter
  changes, T1.3 / T2.3 may flip silently. Mitigation: also assert via the
  hook-prompt-literal check (T3) which is formatter-independent.
