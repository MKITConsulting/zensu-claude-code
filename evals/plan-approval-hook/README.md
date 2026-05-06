# Plan-Approval Hook E2E Eval

End-to-end tests for the `PostToolUse` hook on `ExitPlanMode` that delegates
approved plans to `zensu:tdd-manager`.

## What it tests

| Scenario | Expected behavior |
|----------|-------------------|
| Doc-only plan approved | Hook fires; Claude takes escape-hatch (no `tdd-manager`) |
| Code-change plan approved | Hook fires; Claude delegates to `zensu:tdd-manager` |
| Plan rejected | Hook does NOT fire (verified separately — `-p` mode auto-denies) |

## Why expect

`ExitPlanMode` requires interactive UI approval. `claude -p` print mode auto-denies
the tool because there is no UI to click. The eval drives a real interactive
session via `expect(1)` and feeds the approval keystroke programmatically.

## Run

```bash
./evals/plan-approval-hook/run-eval.sh
```

Requires:
- `expect` (`brew install expect` on macOS — usually preinstalled)
- `claude` CLI on `$PATH`
- Plugin enabled (script `cd`s to plugin root so `hooks/hooks.json` auto-loads)

Results land in `evals/plan-approval-hook/results/`:
- `report-<timestamp>.txt` — PASS/FAIL summary
- `doc-<timestamp>.out` — TUI capture for the doc-only test
- `doc-<timestamp>.debug.log` — Claude debug log
- `code-<timestamp>.out` / `code-<timestamp>.debug.log` — same for code test

## Why it's slow

Each test spawns a real Claude session that plans, presents the plan, and
processes the hook prompt. Wall time per test is 30–180s depending on how long
Claude spends in plan-mode research. Don't run in CI without a generous budget.

## Known limits

- Cannot script plan rejection without TTY interaction beyond what expect sends.
  Reject path is verified by docs (`PostToolUse` only fires on tool success) and
  empirically by running `claude -p --permission-mode plan` (auto-denies, no
  hook fire — see `debug-positive.log` from manual exploration).
- The "delegation path detected" assertion in Test 2 looks for `tdd-manager`
  mention in the output. Claude may take varying amounts of time to fully spawn
  the subagent; the test exits as soon as the delegation signal appears.
