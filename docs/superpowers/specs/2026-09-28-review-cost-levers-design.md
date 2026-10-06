# Review Cost Levers — Design

Status: approved in chat on 2026-09-28 (new defaults for everyone, released only after a measurement gate).
Target repository: `zensu-claude-code` (base `main` at `3326c5a5`, plugin 0.22.0).
Destination once implementation starts: `docs/superpowers/specs/2026-09-28-review-cost-levers-design.md`.

## 1. Problem

The Zensu-versus-vanilla benchmark (one feature of a private desktop project, results in the author's private benchmark kit)
measured the `/zensu:tdd` arm at roughly eight to nine times the cost of the plain arm and about 2.7 times its
net runtime, with no gain on the hidden acceptance tests.

| Run | Zensu | Hidden tests | Net minutes | API-equivalent USD |
|---|---|---|---|---|
| a1 | 0.21.1 | 6/6 | 274 | 96.10 |
| a2 | 0.21.1 | 5/6 | 276 | 92.84 |
| a3 | 0.22.0 | 6/6 | 251 | 108.55 |
| b1 / b2 (no Zensu) | – | 6/6, 6/6 | 103 / 94 | 13.26 / 10.49 |

Measured benefits worth keeping (Codex blind judge, recorded in the kit's benchmark analysis): rubric mean 3.54 against 3.14,
and 1.0 against 4.0 verified CRITICAL defects per run. Which part of the workflow produces them is unknown.

### 1.1 Where the cost goes

Recomputed from every transcript in `results/<run>/claude-home` at Opus 5.5 prices (USD 4 input, 20 output,
8 one-hour cache write, 0.20 cache read per million tokens). The sums match the CLI totals within 2 %.

| Run | Main thread before first review | Main thread after | Aspect agents | Judge | Code-reviewer |
|---|---|---|---|---|---|
| a1 | 11.79 | 40.82 | 34.30 | 9.54 | 1.48 |
| a2 | 11.69 | 40.47 | 28.29 | 12.65 | 1.22 |
| a3 | 12.06 | 50.35 | 37.74 | 8.48 | 1.50 |

- The implementation phase costs about as much as a whole plain run. Almost all extra cost arrives after it.
- Cache writes and cache reads are more than 90 % of the cost; model output is under 10 %. The driver is the
  number of agents and turns that re-read a large context, not what they write.
- The auto-fix loop reached its round cap in all three runs (every main transcript carries the max-rounds
  directive). Each re-review found new defects in the previous round's fixes, and no round caught the merge
  defect that failed the hidden test in a2.
- The benchmark copied the author's user-level Zensu config, which sets `hooks.autoFixIncludeSuggestions: true`
  (default `false`). The measured cost is therefore above the shipped default.

### 1.2 Defects found on the way

- **Evidence fingerprint bound to the wrong tree.** `hooks/lib/zensu-log.sh` passes
  `ZENSU_EVR_PROJECT_ROOT="${ZENSU_PROJECT_ROOT}"` and `hooks/lib/evidence-run-v1.js` fingerprints that root
  (`computeTree(projectRoot, …)` for `tree_start`, `tree_end` and the terminus verdict). When the suite runs in
  a worktree nested under the project root and ignored by it (`.claude/worktrees/` is in `.gitignore`), the
  fingerprint never changes. In a3 all six green full runs carry tree `a349fbba6eae` although the code
  changed between them. Consequence: the terminus cannot detect a stale suite, and `--if-stale` can skip a run
  that is needed.
- **Contradictory skill text.** `skills/tdd/SKILL.md` line 351 (and 426) says a fix round re-runs only its own
  scoped suites and the full suite runs once, with `--if-stale`, in the convergence branch. Line 203 (vanilla
  mode) says fix rounds keep "running the full suite through the evidence runner", and the vanilla fix
  discipline of `hooks/post-review-tdd-delegate.sh` (`FIX_DISCIPLINE_ALL`) tells every routed fix round to
  "run the full suite through the evidence runner". The experiment ran in vanilla mode and ran the full suite
  in every round.

## 2. Goals and non-goals

Goals
- Cut the post-implementation cost and time by more than half at the new defaults.
- Keep the measured benefits: hidden tests not worse, Codex rubric and verified CRITICAL count not worse
  beyond the tolerance in section 5.
- Make every CRITICAL that keeps a loop alive a verified, reproducible defect.
- Fix the evidence fingerprint and the skill contradiction.

Non-goals
- Reviewer model or effort changes. Reviewers keep inheriting the main-thread model (explicit decision).
- `/zensu:pr-team-review`, `/zensu:plan-review` and repo-custom `zensu-review-*` personas.
- Rewording the severity rubric beyond the reproduction rule.

## 3. Decisions

### D1 — One fix round, then a verification review

- The routed loop runs one fix round, then one verification review, then hands off to `/zensu:self-review`,
  which keeps its existing single fix round.
- Under the counting in `hooks/post-review-tdd-delegate.sh` (`NEXT > MAX_ROUNDS` ends the loop; a3 ran
  six reviews at the old default of 5) this is `hooks.autoFixMaxRounds` default **1**. The implementer confirms
  the count with `tests/structure/test-review-convergence.sh` before changing the default.
- The valid range stays `1..99`; setting `5` restores the old behavior.

### D2 — A CRITICAL on a re-review needs a failing test

- Applies to every re-review (round 2 and later) and to what the self-review fix round may fix. The first
  review keeps today's routing and today's Finding Verification Gate (stages 1 and 2).
- New stage 3 of the Finding Verification Gate (`/zensu:tdd` step 4c): for each re-review CRITICAL that stage 2
  graded VERIFIED, the main thread writes or extends a test that fails on the current tree and runs it through
  the evidence runner with `--scope scoped`, so a record exists.
  - `REPRODUCED` — the finding routes as today; the test stays as a regression test.
  - `NOT-REPRODUCED` — the test passes; the finding leaves the loop through the existing
    `[Deferred — do not fix]` annotation, keeps "CRITICAL (not reproduced)" in its text and CRITICAL in its
    `deferred` ledger line, and is listed under `## Open`. It is never `parked`, because a parked entry is a
    self-review must-fix.
  - `NOT-TESTABLE` — the main thread states in one line why no test can express it (for example a secret in a
    log); the finding leaves the loop the same way and is listed under `## Open` for a human, never looped.
- Stage 3 runs inside the Finding Verification Gate, so `hooks.findingVerification: false` switches it off too.
- Every stage-3 verdict is logged as `FINDING REPRODUCTION — <ledger-id> <verdict> <record-or-reason>` and
  carried into the CHAIN-END SUMMARY.
- New key `hooks.criticalReproduction` (default `true`); `false` restores today's re-review routing.

### D3 — Suggestions stay out of the fix loop

- No product change: the shipped default of `hooks.autoFixIncludeSuggestions` is already `false`.
- The author's user-level Zensu config now sets `false` (changed 2026-09-29), and the experiment image is
  rebuilt so its copied config (`build/context/zensu/config.json`) matches.
- The benchmark project tracks a project overlay that sets it back to `true` for that repository.
  Whether that overlay changes is a separate decision for that repository.

### D4 — Lean review panel

- New built-in perspectives replace the five:
  - `correctness` — today's `bugs` plus `tests`.
  - `design` — today's `architecture` plus `conventions`; formatting and lint-level style are excluded because
    the Phase 6 `--scope lint` evidence run already covers them.
  - `security` — unchanged.
- Activation (`hooks/lib/aspect-activation-v1.js`): `correctness` and `design` always spawn; `security` is skipped
  only on a documentation-only change set (same rule as today).
- First review: all activated perspectives plus the judge. Re-reviews: `correctness` only, on the round delta
  (`hooks.incrementalReviewRounds`), and no judge.
- New key `hooks.reviewPanel`: `lean` (default) or `full` (today's five perspectives and a judge every round).
  `hooks.reviewJudge: false` still disables the judge entirely.

### D5 — Evidence fingerprint and full-suite reuse

- The runner measures the directory the suite runs in: the run's `cwd`, or the target of a leading literal
  `cd <dir>` in the command. Every record already stores both. The a3 runs used the second form: the
  runner started at the project root with `cd <worktree>/<dir> && …` in `--cmd`, so a fingerprint that
  followed only the `cwd` would not have seen the worktree either.
- When `git -C <dir> rev-parse --show-toplevel` names a different work tree strictly inside the project root's
  own work tree, the fingerprint is a combined tree written with `git mktree --missing`, whose entries
  `project` and `work` are the project tree and that work tree's tree, so an edit on either side makes the
  record stale. Otherwise the fingerprint is the project root's, exactly as today: a nested project root keeps
  its subtree fingerprint, and a run from an unrelated clone never moves the fingerprint off the project. No
  record field is added and the `project_root` binding is unchanged.
- The terminus verdict derives the directory from the `command` and `cwd` of the newest full record;
  `--if-stale` derives it from the current run and passes it to the verdict as `runCwd`, because the verdict
  CLI's transport always fills `options.cwd` with the project root.
- A stale verdict lists the changed paths of both halves; a path in the nested work tree carries its location,
  for example `.claude/worktrees/wt/a.txt`.
- A record written before this fix for a nested worktree carries a project-root fingerprint. Against the combined
  fingerprint it reads `stale`, so an old record is never trusted by mistake.
- `skills/tdd/SKILL.md` line 203 is aligned with lines 351 and 426: fix rounds run their own scoped suites; the
  full suite runs once in the convergence branch with `--if-stale`, and again only in the self-review fix round.
- The fix-round directive of `hooks/post-review-tdd-delegate.sh` states the same rule in one sentence, so the
  reminder reaches the agent at the start of every routed fix round instead of after a full run has started.
  Its vanilla fix discipline says the same instead of asking for a full run. Nothing refuses a full run.
- Refined on the rebase onto 0.23.0, which added full suites in CI and already aligned the fix-round wording of
  the skill and the vanilla fix discipline. The fingerprint covers `full` and `scoped` runs, because a CI chain
  closes on its `scoped` runs; in CI mode every record is compared with the tree of its own directory, and the
  verdict reads `stale` while the directory of the newest finished run has no current record. Both max-rounds
  hand-offs run one close step: the full suite with `--if-stale` in a local chain, the affected suite in a CI
  chain. An `acceptance` run keeps the project-root fingerprint, because the acceptance gate compares it with
  the project tree. Since #354 the runner keeps the cwd only inside the project root's own work tree and runs a
  nested cwd in the project root, so a nested work tree is reached only through the leading `cd`.

## 4. Delivery

- **PR A — patch release (0.23.x):** D5. A correctness fix, independent of the rest, shipped first.
- **PR B — minor release (0.24.0):** D1, D2 and D4 with their docs and tests. Default changes are behavior
  changes, so this is `minor` under the repository's version rules.
- D3 is a local configuration change outside the repository.
- Implementation runs in a session whose anchor contains the worktree: a session started in `zensu-claude-code`,
  or a worktree nested under the session's own anchor. A session whose anchor does not contain the worktree can
  edit there, but the source-write gate refuses its commits.

## 5. Measurement gate before releasing PR B

- Build the benchmark image from the pushed PR B branch (`--build-arg ZENSU_PLUGIN_REF=<branch>`; the Dockerfile
  clones with `--branch`, which takes a branch or tag, not a commit), Rust pinned to 1.98.1, and run arm A of
  the benchmark feature twice headless (`a4`, `a5`).
- Do not re-run `scripts/prepare-context.sh`: it rebuilds the whole context from the current global
  `CLAUDE.md` and memory, which would change the experiment's constants. Edit only
  `build/context/zensu/config.json` for D3 and record the one changed checksum in `build/context.sha256`
  and in the README addendum.
- The base commit of the benchmark project tracks a project overlay `.zensu/config.json` that sets
  `autoFixIncludeSuggestions: true`, and a project overlay wins per key. The lean runs therefore pass
  `ZENSU_CONFIG=/home/node/.zensu/config.json` into the container (a new pass-through line in
  `docker/compose.yaml`), so Zensu reads only the global file there. The repository at the base commit stays
  untouched. The earlier Zensu runs A1 to A3 had the setting on through both files.
- Evaluate exactly as `a3`: `collect.sh`, `eval-checkout.sh`, `run-hidden.sh`, the suite script, `metrics.mjs`,
  the harness extractor, and the Codex blind judge with verification against a plain run.
- Release PR B only if all hold:
  - hidden tests: at most one failure across both runs (A1 to A3 had one in 18);
  - Codex rubric mean at least 3.3 (the midpoint between 3.54 and 3.14) and verified CRITICAL defects per run
    at most 2;
  - API-equivalent cost at most 50 USD per run (half of the A1 to A3 mean of 99.16) and net runtime at most
    180 minutes.
- Two runs are a small sample; the result is reported with that caveat.

## 6. Risks

- Fewer review rounds can let a real defect through. Mitigation: D2 turns re-review CRITICALs into failing
  tests, `## Open` keeps unreproduced ones visible, and section 5 checks the outcome.
- Merged perspectives can dilute attention. Mitigation: `reviewPanel: full` restores the old panel; section 5.
- A fix round's delta gets no security or design re-review. The consume-mode code-reviewer and the self-review
  still read it; `reviewPanel: full` restores the per-round panel.
- Stage 3 costs main-thread work for each re-review CRITICAL. It is bounded to re-reviews and to CRITICAL.
- The run directory follows only a leading literal `cd`. A suite reached any other way (`--manifest-path`,
  `git -C`, `pushd`, a script that changes directory) keeps the project-root fingerprint, and so does a suite
  started outside the project root's own work tree. The record's `command` and `cwd` show where it ran.

## 7. Testing

- `tests/structure/evidence-run-v1.test.js`: a suite run in a nested worktree, from its `cwd` or through a
  leading `cd`, gets a combined fingerprint of the project and that worktree; the terminus reads `stale` after
  an edit on either side and lists nested paths with their location; `--if-stale` runs after such an edit; a
  record whose tree was taken at the project root reads `stale`; the leading-`cd` reader accepts only literal
  forms; the existing nested-project-root test stays green.
- `tests/structure/test-evidence-run.sh`, `test-full-suite-gate.sh`: terminus verdicts on the nested layout.
- `tests/structure/aspect-activation-v1.test.js`: the three-perspective activation matrix and `reviewPanel: full`.
- `tests/structure/test-review-convergence.sh`, `test-post-review-*`: default round count, `criticalReproduction`
  routing, `## Open` rows for `NOT-REPRODUCED` and `NOT-TESTABLE`.
- `tests/structure/test-tdd-skill-review-fanout.sh`, `test-incremental-review-rounds.sh`, `test-review-judge.sh`:
  skill text for the lean panel, judge on the first review only, and the removed line-203 contradiction.
- Full offline suite through `tests/run-all.sh` before each PR.
