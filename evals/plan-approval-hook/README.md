# Plan-Approval Hook E2E Eval

End-to-end tests for the `PostToolUse` hook on `ExitPlanMode` that asks which
delivery route an approved plan takes — `/zensu:autopilot`, `/zensu:tdd`,
`/zensu:pilot`, or implementing directly — and routes to the chosen skill in the
main thread.

## What it tests

| Scenario | Expected behavior |
|----------|-------------------|
| Doc-only plan approved | Hook fires; Claude takes the docs-only escape-hatch and asks nothing |
| Code-change plan approved | Hook fires; Claude asks the four-route question; selecting the Zensu-workflow option by LABEL records the answer (`delivery-route: tdd`) and routes to `/zensu:tdd` |
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
- `node` on `$PATH` (the runner builds the config fixture with it)
- Plugin enabled (script `cd`s to plugin root so `hooks/hooks.json` auto-loads)

Both tests run with `ZENSU_CONFIG` pointing at a fixture the runner writes into
`results/`: the config the hooks would read in the plugin root, with
`hooks.defaultDeliveryRoute` set to `"ask"`, because a configured default would answer
the route question before it is asked. Every other key carries over, a switched-off
setting included, and a `hooks.reviewerSpawnAutoAllow` that the strict reader
withdraws is written as `false`.

Test 2 answers at most one Bash permission prompt, the one for the command that
records the route answer, and declines every other prompt. A prompt declined before
the helper ran fails `T2.9`; one declined after it ends the wait before the status
line, so `T2.4` fails. The script approves only when the text from the helper's name
to the prompt's question starts with the `--tdd` verb and holds none of `;`, `&`,
`|`, backtick, `<`, `>` or `(`, so a chained, piped, redirected or substituted
command is refused, and so is a zsh glob qualifier such as `*(e:…:)` or a later tool
call. The price of refusing every `(` is that a prompt whose description holds a
parenthesis is declined too, and `T2.9` then fails although nothing unsafe was
asked. That check cannot see a second command on its own line or anything before
the helper's name. The permission box also draws the model-written description
below the command, so a description that ends in the helper's name supplies the text
the check reads, and the approved command then need not run the helper at all. A
trusted plugin tree does not bound what the model writes there, so run the eval only
where an unexpected command costs nothing, such as a disposable container or virtual
machine.

Results land in `evals/plan-approval-hook/results/`:
- `report-<timestamp>.txt` — PASS/FAIL summary
- `route-ask-<timestamp>.json` — the config fixture both tests ran with
- `route-stamp-<timestamp>` — the empty file `T2.9` compares marker times against
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
- Test 2 waits, within one 240 s budget, until the TUI capture shows both the
  `Executing via /zensu:tdd` status line and the helper's `delivery-route: tdd`
  tool-result line, in either order, and then ends the session. It measures the
  routing signal (`T2.4`) and the recorded answer (`T2.9`), not the completed run.
  `T2.9` reads the session marker the helper writes under the plugin root, newer than
  a stamp the runner writes first, rather than the transcript; the runner leaves
  every marker in place, and a live session you run in the same checkout that records
  `tdd` during the eval can satisfy `T2.9` too. Selection is by option
  LABEL; whether the host consumes a typed label as a selector is UNVERIFIED here. A
  mis-selected route IS a named failure: `T2.7` and `T2.8` assert that
  `Executing via /zensu:autopilot` and `Executing via /zensu:pilot` are absent. Both
  are ABSENCE assertions, and
  an empty transcript satisfies an absence — so both are gated on T2.4: with no routing
  signal they are recorded as a not-graded FAIL rather than reported green over a
  run that never happened. `T1.0` and `T2.0` assert the debug log exists at all and
  gate the remaining absence assertions in their own test — `T1.5` on `T1.0`, `T2.5`
  on `T2.0` — which is what a missing `timeout` binary produces (base macOS
  ships neither `timeout` nor `gtimeout`; the runner falls back to the expect
  scripts' own `set timeout` and says so in the report, in a NOTE emitted after the
  header write, because that write is a truncating `tee`). (`tdd-manager`
  still appears in Test 1, where it is the correct negative-dispatch needle.)
- The terminal repaints only the cells that change, so the space between two words
  can arrive as a cursor-position escape, which `strip_ansi` deletes: a May 2026
  capture shows `zensu-log.sh--phase` where the command read `zensu-log.sh --phase`.
  `contains` and `not_contains` therefore read each space in a needle as any run of
  blanks or none. `T2.4` and `T2.6` match a phrase whether its spaces were drawn,
  drawn as escapes or skipped, and the absence checks `T2.7` and `T2.8` see such a
  phrase too, where a literal-space needle read an escape-drawn
  `Executing via /zensu:autopilot` as absent. Every multi-word expect pattern in both
  scripts joins its words with the same `GAP`, and the doc test's hook-fired arm keeps
  waiting after it matches, so it never ends the session before the model answers.
  The Test 1 checks and `T2.1`-`T2.3` and `T2.5` read the debug log, which is plain
  text, and `T2.9` reads no transcript at all.
- A cell is also skipped when it already shows the character to be drawn, so a
  letter can go missing as well: the same capture shows `This com` and `and` on
  either side of an escape where the prompt read `This command`. A phrase drawn over
  cells that already held some of its letters can lose them; the checks rely on each
  phrase being drawn onto blank cells at least once.
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
