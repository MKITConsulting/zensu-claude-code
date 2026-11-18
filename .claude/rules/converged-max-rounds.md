---
paths:
  - "hooks/lib/zensu-log.sh"
  - "hooks/lib/review-ledger-v1.js"
  - "hooks/lib/zensu-autopilot-state.sh"
  - "hooks/lib/zensu-tdd-phase.sh"
  - "hooks/lib/chain-recovery-v1.js"
  - "hooks/lib/session-control-core-v1.js"
  - "hooks/lib/zensu-doctor-report.js"
  - "hooks/post-review-tdd-delegate.sh"
  - "skills/reset-review-limit/SKILL.md"
  - "skills/self-review/SKILL.md"
  - "tests/structure/review-ledger-v1.test.js"
  - "tests/structure/test-autopilot-post-review-max-rounds.sh"
  - "tests/structure/test-autopilot-state-machine.sh"
---

# Converged Max-Rounds Attempts (`_zensu_bound_convergence` + `convergence` in `review-ledger-v1.js`)

An Autopilot-bound `/zensu:build` chain that reached `hooks.autoFixMaxRounds` closed as
`max-rounds` and blocked its run with `TDD_MAX_ROUNDS` whatever the reviews had left open. Observed
on 2026-11-13: three review rounds, a self-review with no must-fix and a terminus that exited 0
still left the run `BLOCKED`, with five deferred SUGGESTION entries as the only open ledger entries.
The way out was `/zensu:reset-review-limit` and a whole new attempt, whose fresh first round
re-reviews the cumulative diff and usually reaches the cap again. The attempt now closes as
`converged`, and the run returns to its `returnStage` as after a `pass`, when the chain's findings
ledger shows no open defect.

**One owner of the decision.** The bound `--chain-done` arm in `hooks/lib/zensu-log.sh` decides,
through `_zensu_bound_convergence`, and no other site writes `converged`:

- It asks only when no `--outcome` was passed, the recorded outcome is `max-rounds`, the inner chain
  is not sealed yet (`chainDone` false in the Autopilot context) and the call carries the chain's
  claimed review ticket (`_zensu_full_suite_ticket_matches`). An explicit `--outcome max-rounds`
  skips the check, and a retry after the seal reads the sealed outcome and repeats its transition.
- `--outcome` accepts `pass`, `no-changes` and `max-rounds`. `converged` is refused with a sentence
  of its own and every other spelling, a `converged` with a trailing tab or newline included, with
  the generic one, both with exit 2 before anything is read or written, so a caller cannot assert
  convergence. The `done_fields` program refuses any other requested value again, and the sealed
  flag it hands back must read exactly `true` or `false`.
- The verdict is `convergence` in `hooks/lib/review-ledger-v1.js` (`convergenceMain` for the shell):
  `hooks.reviewConvergence` on, the session's edit-landing receipt bound to a run log through
  `receiptRunLog` of `edit-landing-receipt-v1.js`, that log's ledger, read with `report: true`,
  answering `status=ok` with no `lost` cause and no `openDefect` entry (`routed-unfixed`, `parked`,
  or `deferred` at IMPORTANT or CRITICAL), and a `FINAL REVIEW LEDGERED — R<n>` line after the last
  `REVIEW BUDGET RESET`, where `<n>` is the workflow document's `reviewRound`, the round the
  max-rounds hand-off named. `_zensu_bound_convergence` hands the document's path over as
  `ZENSU_RL_STATE`, and `reviewRoundOf` reads it through `readBoundedJson` of
  `edit-landing-receipt-v1.js`. Every other answer is `not converged`, a check that throws and a
  `node` that cannot run included, so every fault keeps the earlier behaviour.
- The terminus prints the `CONVERGENCE —` line as soon as it decides, before any gate runs, so a
  refusal that keeps the chain open still names the verdict, and after a `converged` verdict a
  `CONVERGED CLOSE —` line that names the exit below. `converged` then takes the `pass` arm: the
  terminal edit-landing gate, the bound full-suite gate and the acceptance gate all run, and their
  three lines stay byte for byte as they were, because `A0d` in
  `tests/structure/test-acceptance-gate.sh` and `T1b` in
  `tests/structure/test-terminal-edit-landing-gate.sh` match them; `T1b` also reads the
  `pass|converged)` arm label.
- `tdd_finish_autopilot_chain` seals `converged` only over a recorded `max-rounds` hand-off with
  `codeReviewDone` and the claimed ticket; `tdd_set_chain_outcome` never accepts the value.

**A converged close the pass gates refuse is a third state, and it has an exit.** A refusal keeps
the chain open with the recorded `max-rounds` outcome and the run at `TDD_RUNNING`. A refusal that
names a command to run, a record to wait for or an audit to repeat (a missing, stale or running
full-suite record, `EDIT LANDING RECEIPT STALE`) is answered that way and the terminus runs again:
the exit is not for it, because it would close an attempt that can still converge. A cause only an
edit can remove, such as a `failed` full suite, takes the self-review's one fix round. Once that
round is spent, the `CONVERGED CLOSE —` line, `MAX_LEDGER_STEP` and finalize step 1 of
`skills/self-review/SKILL.md` name the same exit: `--chain-done --outcome max-rounds`, whose arm
runs no pass gate, closes the attempt as `max-rounds` and blocks the run with `TDD_MAX_ROUNDS`,
which `/zensu:reset-review-limit` and `RESUME` handle as before. The `CONVERGED CLOSE —` line
prints on every converged decision, a successful one included, so finalize step 1 ties the exit to
its stop for a spent fix round, never to the line alone: after a successful seal the rerun is
refused (`M7d`), and the step's stale-failure rule would then withhold the report. After the exit
the report marks the converged verdict as refused by a gate, because the attempt closed as
`max-rounds` and the rerun prints no `CONVERGENCE —` line (`M11`).
Without that exit the bound Stop routes the self-review until
`INNER_REVIEW_STOP_BUDGET_EXHAUSTED`, a block the review rearm, and with it
`/zensu:reset-review-limit`, refuses.

**Why the report read, why only `status=ok`, and why the marker.** The decision reads the ledger the
way the reports read it, so an entry carried across a reset under its `G<g>:` id is judged like any
other until a qualified `fixed` line closes it. A `partial` read means a ledger line could not be
parsed. A line that could not be parsed before the last reset would vanish with its generation, so
the report read keeps the first such cause as `lost` beside `status=ok`: the `## Open` renderers keep
their status, and the decision answers `not converged`. The review that met the cap is never routed,
so nothing else ledgers it, and the marker is the hand-off's proof that its findings reached the
ledger; it is written also when that review needed no ledger line. An empty ledger, a missing marker
and a marker for another round all answer `not converged`, because a missing line is the one case in
which the ledger cannot tell open from fixed. The hand-off sends the step once and a Stop that resumes
the self-review does not repeat it, so a forgotten marker costs the attempt its converged close and
never yields a wrong one.

**The final review must reach the ledger, so the hand-off asks for it.** `MAX_LEDGER_STEP` in
`hooks/post-review-tdd-delegate.sh`, rendered only for a bound chain with `hooks.selfReview` and
`hooks.reviewConvergence` on, asks for one line per finding of that review that no ledger line,
do-not-fix annotation or `[STILL OPEN]` line covers: `routed` for CRITICAL or IMPORTANT, which makes
it a must-fix candidate of the self-review, and `deferred` for SUGGESTION. A
`[STILL OPEN] <ledger-id> covers <panel-id>` line whose panel finding is CRITICAL or IMPORTANT takes
a `parked` line for the earlier id at that severity instead, so a deferred suggestion the final review
raised again blocks the close. The step then asks for the marker, and for the terminus's
`CONVERGENCE —` line in the final report's `How I built it` line, which finalize step 2 of the
self-review skill names too. The standalone and self-review-off texts are unchanged (`MR3`, `M3a`):
a standalone hand-off still says the code-reviewer chain is marked converged, because only a bound
chain can close as `converged`, so no attempt outcome shares the word there. The bound hand-off calls
the review loop it ends (`codeReviewDone`) closed instead (`M7`), because there `converged` names an
attempt outcome. The Stop hook's self-review resume reason, the review flowchart in
`docs/architecture.md` and the opening of `skills/self-review/SKILL.md` speak of the closed loop for
every chain.

**The schema half is additive.** `converged` joined every closed outcome list: `payloadValid`,
`stateValid`, `deliveryInvariants`, the head-update rule, the Stop reconcile, the
`autopilot_finish_tdd_attempt` case and the rearm case in `zensu-autopilot-state.sh`;
`tdd_autopilot_context`, both outcome sets, the finish CAS and the hand-off completion list in
`zensu-tdd-phase.sh`; `CHAIN_SNAPSHOT_OUTCOMES` in `session-control-core-v1.js`, `CHAIN_OUTCOMES` in
`chain-recovery-v1.js` and `AUTOPILOT_TDD_OUTCOMES` in `zensu-doctor-report.js`. The transition
`TDD_RUNNING:TDD_CHAIN_DONE` is unchanged: `converged` takes its non-`max-rounds` branch to
`returnStage`. No existing edge, target or effect moved, so every stored record replays as before
(`.claude/rules/autopilot-gate-reentry.md` says why that matters). `CV4` in
`tests/structure/test-autopilot-state-machine.sh` replays a record the 0.38.0 library wrote, frozen in
`tests/structure/fixtures/autopilot-0.38.0-tdd-max-rounds/`, and `CV5` resumes it to a converged
second attempt. `CV6` scans every code line under `hooks/` that names both `pass` and `no-changes`
and requires `converged` beside them, except at the four sites that refuse it by design (the bound
`--outcome` case, its refusal sentence, the `done_fields` request check and
`tdd_set_chain_outcome`), each of which must match exactly once; a copy whose `stateValid` lacks the
value must fail it. `zen-anchor-v1.js` gets no row for the value: `converged` is written only in the
CAS that also sets `chainDone`, and the anchor's two outcome-dependent shapes are reached only while
`chainDone` is false.

**Coupled sites.** Beyond the outcome lists above: the bound arm, its `CONVERGED CLOSE —` line and
`_zensu_bound_convergence` with its `ZENSU_RL_STATE` in `zensu-log.sh`; `openDefect`,
`finalReviewLedgered`, `reviewRoundOf`, `convergence`, `convergenceMain`, `CONVERGENCE_HEAD`,
`FINAL_REVIEW_HEAD` and the `lost` cause of `ledgerState` in `review-ledger-v1.js` and their unit
cases, whose count `tests/profiles/unit-files.v1.json` holds; `MAX_LEDGER_STEP` and the closed-loop
sentence of the max-rounds hand-off in the post-review hook, which `M7`, `M10` and `MR3` pin; the
self-review resume reason of `hooks/stop-chain-enforcer.sh`, whose wording `G9d` in
`tests/structure/test-chain-terminus-zero-change-gate.sh` keeps out of the zero-change reason;
`M7` to `M14` in `tests/structure/test-autopilot-post-review-max-rounds.sh` for the terminus, the
retry after the seal (`M7c`, `M7d`), the refused spellings (`M8s`), the exit (`M11`), the marker
(`M12`), the Stop reconcile (`M13`) and the rearm (`M14`); and the operator accounts in
`docs/review-chain.md` §"Max rounds in an Autopilot-bound chain", the `autoFixMaxRounds` and
`reviewConvergence` rows of `docs/configuration.md`, the three gate statements of `docs/gates.md`
that name the gated outcomes, the self-review paragraph of `docs/build-workflow.md`, finalize steps 1
and 2 of `skills/self-review/SKILL.md`, whose body size the `self-review` entry of
`tests/structure/test-skill-text-budget.sh` holds, the `Do NOT Use For` list of
`skills/reset-review-limit/SKILL.md` and the `CHANGELOG.md` upgrade note.

**Known gaps, accepted and named:**

- A deferred CRITICAL entry blocks convergence even when its stage-3 reproduction answered
  `NOT-REPRODUCED`: the ledger keeps the severity, and the decision does not read the reproduction
  line.
- A candidate the self-review leaves unfixed records no ledger transition, so it keeps blocking: the
  attempt closes as `max-rounds`, as every bound max-rounds attempt did before this change.
- A `fixed` line proves an edit, not a fix (`.claude/rules/round-prepare.md`), and the ledger and the
  marker are model-authored run-log text in a session-writable directory, so a wrong `fixed` line, a
  marker written for a review whose findings never reached the ledger, or a forged ledger line can
  make an attempt converge. The gates a `pass` meets still run.
- A `[STILL OPEN]` line that names a carried `G<g>:` id cannot be followed: only `fixed` may carry the
  qualifier, so its `parked` line is malformed, the read answers `partial` and the attempt closes as
  `max-rounds`.
- With `hooks.selfReview` off, a bound max-rounds close stays `max-rounds`: the post-review hook
  closes the chain itself, and no later stage fixes what the last review found.
- The outcome vocabulary is still spelled at every site. `CV6` compares the lists as text and reads
  only lines that name both `pass` and `no-changes`, so a list spelled another way is not compared.
- Windows is unmeasured: the `CV` block adds lease-taking state-library calls to
  `tests/structure/test-autopilot-state-machine.sh`, which runs on a blocking Windows shard, and
  `M7` to `M14` add eight bound chains to the max-rounds suite.
- No ports: `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not included.

**Version: `minor`.** A new value in strict closed sets: `payloadValid` and `stateValid` of the run
record and the outcome sets of the workflow document. An older installation of the same lineage
refuses a run record or a workflow document that holds `converged`, and its verbs that read such a
record fail closed, the forward-incompatible direction `.claude/rules/runtime-lineage.md` assigns to
`minor`. The marker, the closed `--outcome` set and the `lost` cause move no persisted shape: the
marker is a run-log line only this terminus reads, and `lost` is a field of a returned read, never
stored. The release pipeline sets the version; never bump it by hand.
