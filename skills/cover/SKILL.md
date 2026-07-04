---
name: cover
description: >
  Author durable, committed tests at the RIGHT level for a change — generic across any
  stack, framework, and app type. Point it at a diff, a feature, a PR, a path, or a
  described behavior and it probes the repo, decides per behavior whether a unit,
  component, integration/contract, or end-to-end test is the faithful cover (the test
  pyramid, encoded), mirrors the project's existing test conventions, and writes the
  gap-filling tests green-first — because the code already exists, each test must pass on
  first run; a first-run failure means either a bad test or a real bug, which it reports
  rather than silently patching. Reuses the Zensu review chain (five review-aspect agents +
  code-reviewer) as the quality gate and flags any surfaced bug loudly. It is the durable
  regression-net complement to /zensu:autopilot's one-shot live validation, and can persist
  autopilot's validated acceptance criteria into committed end-to-end tests via --from-acs.
  Use whenever the user wants to add or backfill tests, "write e2e tests", "cover this",
  "add regression tests", "fill the test gaps", "FE/BE/fullstack tests", a durable test net,
  or the slash command /zensu:cover.
---

# /zensu:cover

Author **durable, committed tests at the right level** for a change — generic across every
stack. Decide *unit vs component vs integration vs E2E* per behavior (the pyramid, encoded),
mirror the repo's existing test conventions, and write the gap-filling tests **green-first**.

> autopilot proves a feature works **once** (live, throwaway). `/zensu:cover` leaves a
> **permanent regression net**. You point; it covers.

## Arguments

Slash form: `/zensu:cover [<target>] [--flag=value ...]`.

| Arg | Required | Default | Notes |
|---|---|---|---|
| `<target>` | no | working diff | What to cover: a feature id (`zensu features get`), a PR number (`gh`), a path glob, or a free-text behavior. |
| `--base=<branch>` | no | `main` | Diff base for the default `git diff <base>...HEAD` scope. |
| `--level=unit\|integration\|e2e\|auto` | no | `auto` | Force a level; `auto` lets the matrix in `rules/levels.md` decide per behavior. |
| `--layer=fe\|be\|fullstack\|auto` | no | `auto` | Force the scope; `auto` follows the changed code. |
| `--from-acs` | no | off | **autopilot seam**: emit one durable E2E test per numbered AC. Source order: the AC block passed in the invocation payload (autopilot's Phase-0 ACs), else a named plan artifact, else the PR body. Implies E2E scope — overrides `--level`/`--layer`. |
| `--driver=<name>` | no | auto (probe) | Force the authoring driver (`browser`/`api`/`cli`/`async`/`iac`/`custom` — see `rules/drivers.md`). |
| `--yes` | no | off | Skip the Phase 1 test-plan approval gate (author straight from the plan). |
| `--no-review` | no | off | Skip the Phase 3 review chain. Degrades — note it in the report. |

## Prerequisites

- A git repository. The skill works **in a worktree only** — if the session is on the
  origin checkout it creates one first (see Critical Conventions).
- A test runner for each layer it will touch. The probe detects it; if a layer has none,
  the skill says so and degrades that layer rather than inventing a framework.
- `gh` CLI authenticated only when `<target>` is a PR number.
- Everything else — stacks, frameworks, existing test conventions, how the app is exercised
  — the skill **discovers itself** in Phase 0.

## When to Use

- **Standalone** — the primary use: point at a diff (or feature / PR / glob / behavior) and
  get durable tests at the right level. Replaces the ad-hoc "write me FE/BE/E2E tests where
  unit tests do not suffice, or unit tests where missing" prompt with an explicit decision.
- **autopilot's durable-test complement** — invoked as `/zensu:cover --from-acs` from
  `/zensu:autopilot --cover` to turn the acceptance criteria autopilot validates **live and
  throwaway** into **committed** end-to-end tests in the same PR.

This is a coverage skill for code that **already exists** — it is NOT `/zensu:tdd`. TDD is
red-first for code you are about to write; `/zensu:cover` is green-first for code that is
already there. If the behavior does not exist yet, use `/zensu:tdd` or `/zensu:autopilot`.
When both run over the same change (autopilot runs `/zensu:tdd` at step 1 and `/zensu:cover` at
step 6b), they are complementary, not competing: cover's **no-duplication** heuristic subtracts
the coverage tdd's per-step tests already produced and fills only the remaining gap.

## Workflow

Four phases. Track each as a task with `TaskCreate`/`TaskUpdate` so the user has a live view.

### Phase 0 — Scope & Probe  (interactive ONLY if scope/framework is ambiguous)

**0.A — Worktree.** If `git rev-parse --show-toplevel` is the origin checkout (not a
worktree under `.claude/worktrees/`), create one and continue inside it. Never author on the
origin checkout. See Critical Conventions.

**0.B — Resolve `<target>`.** Precedence: explicit `<target>` arg → else the default
`git diff <base>...HEAD` (the working change). A feature id resolves via
`zensu features get`; a PR number via `gh pr diff`; a glob selects files; free text is
matched against the diff. Produce the concrete set of changed behaviors to cover.

**0.C — Probe (per layer).** Detect stacks, test runners, existing test directories +
naming conventions, and any E2E harness — per `rules/probe.md`. Read 1–2 nearby existing
tests per layer to capture the idiom. **Mirror conventions, never impose a framework.**

**0.D — Confirm only if ambiguous.** If scope or framework is genuinely unclear, batch every
open question into one `AskUserQuestion`. If the probe is confident, stay silent — the user
sees the Phase 1 plan, not a quiz.

### Phase 1 — Gap analysis & test plan

Map each changed behavior to the level(s) and layer(s) it needs, **minus** existing coverage,
using the decision matrix and heuristics in `rules/levels.md`. Emit a **test-plan table**:

```
| Behavior | Level | Layer | Target test file | Driver | New/Existing |
```

Present it for approval unless `--yes`. This is where the "which level?" decision is made
explicit and reviewable before a line of test code is written.

### Phase 2 — Author (green-first)

For each plan item, in the project's own idiom:

1. Write the test mirroring the conventions captured in Phase 0.
2. Run it.
   - **GREEN** → keep it, then run the mutation-sensitivity spot-check from
     `rules/quality.md` (would it fail if the behavior were broken? no tautologies).
   - **RED** → triage: a **bad test** → fix and re-run; a **real bug in the code under test**
     → write it as `xfail`/skip, record the bug, and move on. **Report-only — never patch
     production here.**

Independent items across layers may fan out via parallel workflows where the probe says it is
safe (a shared test DB or fixed port serializes them).

### Phase 3 — Quality gate + review chain

1. Run the target suite green (except intentional `xfail` bug flags).
2. Apply the `rules/quality.md` gate: determinism, isolation, no over-mocking, meaningful
   assertions.
3. **Reuse the Zensu review chain** exactly like `/zensu:tdd`'s review stage — spawn the
   **five** `zensu:review-aspect` agents in one parallel batch (`conventions`, `bugs`,
   `architecture`, `tests` (emphasized), `security`) over the changed test files, merge their
   findings in this thread, consolidate through a single `zensu:code-reviewer` spawn, and fix
   the findings in-thread. `--no-review` skips this (degrade + note).

**Not TDD — no phase-gate, no deferred marker.** cover **does not arm the phase-gate** (it
never runs `--tdd-begin`) and records **no** `--pending-review` marker. It drives the review
directly in-thread as Phase 3 above, so the review is skill-driven, not Stop-hook-gated.
Driving the chain in-thread *and* leaving a `--pending-review` marker would double-review — the
next interactive Stop would re-run the whole fan-out over the same files — so do the in-thread
drive, not both. When cover runs **inside another skill's workflow** (e.g.
`/zensu:autopilot --cover`), that parent owns the single review over the combined diff and
cover only authors — it does not re-drive the chain.

### Phase 4 — Report

- **Added tests** table (level / layer / file).
- **Coverage delta** if the stack measures it.
- **Bugs surfaced** — the `xfail`/skip list, called out **loudly** (these are the "the code is
  wrong, not the test" findings; report-only by design).
- **Skipped** items and why (a layer with no runner, an unsafe-to-parallelize target).
- A one-sentence `## TL;DR` last.

## The level decision (summary — full matrix in `rules/levels.md`)

Pick the **lowest faithful level**; escalate only for real boundary/flow risk:

- Output determined by one unit's inputs, no I/O → **unit**.
- Component render / prop→DOM / user event, no real backend → **component** (FE).
- Crosses a boundary you own (repo↔DB, controller↔service, HTTP contract, adapter) →
  **integration / contract**.
- User-visible flow spanning FE→BE→persistence, or phrased as an acceptance criterion →
  **E2E** (fullstack).

Governed by five heuristics: **lowest-faithful-level**, **pyramid budget**,
**no-duplication**, **faithfulness/mutation**, and **coverage-mode inversion** (green-first).

## Reference Files

- `rules/levels.md` — the decision matrix + the five heuristics (the brain).
- `rules/probe.md` — per-layer stack / framework / convention detection.
- `rules/drivers.md` — authoring driver catalog + the `--from-acs` mapping.
- `rules/quality.md` — the test-quality gate.

## Critical Conventions

- **Worktree only.** Author in a worktree, never the origin checkout.
- **Green-first, report-only.** Tests target existing code and must pass on first run. A real
  bug is reported (as `xfail`/skip), never silently fixed — coverage and bug-fixing stay
  separate reviewable acts.
- **Mirror, do not impose.** Match the repo's existing test framework, directory layout, and
  naming. The skill adds tests that look like the ones already there.
- **Pyramid discipline.** Many unit, some integration, few E2E. E2E is reserved for critical
  flows, not every branch.
- **Credential-blind E2E.** When an end-to-end test needs a session, load it from a
  login-script artifact by path (Playwright `storageState`, a bearer-token file); never place
  a real secret in context. Same rule as autopilot's `rules/auth.md`.
- **English only.** All authored tests, comments, and docs are English.
