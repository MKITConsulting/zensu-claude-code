# Plan-Approval Hook E2E Eval

End-to-end tests for the `PostToolUse` hook on `ExitPlanMode` that asks which
delivery route an approved plan takes — `/zensu:autopilot`, `/zensu:tdd`,
`/zensu:pilot`, or implementing directly — and routes to the chosen skill in the
main thread.

## What it tests

| Scenario | Expected behavior |
|----------|-------------------|
| Doc-only plan approved | Hook fires; Claude takes the docs-only escape-hatch and asks nothing |
| Code-change plan approved | Hook fires; Claude asks the four-route question; selecting the Zensu-workflow option by LABEL routes to `/zensu:tdd` |
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
- Test 2 asserts the `Executing via /zensu:tdd` status line in the TUI capture and
  exits as soon as it appears, so it measures the routing signal rather than the
  completed run. Selection is by option LABEL; whether the host consumes a typed
  label as a selector is UNVERIFIED here. A mis-selected route IS a named failure:
  `T2.7` and `T2.8` assert that `Executing via /zensu:autopilot` and
  `Executing via /zensu:pilot` are absent. Both are ABSENCE assertions, and
  an empty transcript satisfies an absence — so both are gated on T2.4: with no routing
  signal they are recorded as a not-graded FAIL rather than reported green over a
  run that never happened. `T1.0` and `T2.0` assert the debug log exists at all and
  gate the remaining absence assertions in their own test — `T1.5` on `T1.0`, `T2.5`
  on `T2.0` — which is what a missing `timeout` binary produces (base macOS
  ships neither `timeout` nor `gtimeout`; the runner falls back to the expect
  scripts' own `set timeout` and says so in the report, in a NOTE emitted after the
  header write, because that write is a truncating `tee`). (`tdd-manager`
  still appears in Test 1, where it is the correct negative-dispatch needle.)
- **Clause (C) — the non-interactive bar — is NOT exercised by this eval.** Both
  tests drive an INTERACTIVE session via expect, while clause (C) governs a run with
  no human to answer, so the feature's only behavioural surface does not touch that
  half of its own safety property. A headless `claude -p` case is the obvious
  addition and is deliberately NOT implemented here: the hook fires only on
  ExitPlanMode SUCCESS, this file already records that `claude -p --permission-mode
  plan` auto-denies and fires no hook, and whether any other headless permission mode
  can produce an APPROVED ExitPlanMode was not established. Until it is, clause (C)
  is covered only by `D13` in `tests/structure/test-plan-approved-delegate.sh`, which
  grades the emitted directive rather than a model's behaviour. UNVERIFIED, stated
  rather than implied.
