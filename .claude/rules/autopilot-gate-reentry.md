---
paths:
  - "hooks/lib/zensu-autopilot-state.sh"
  - "hooks/session-start-autopilot-resume.sh"
  - "skills/autopilot/SKILL.md"
  - "skills/autopilot/rules/pr-open.md"
  - "skills/autopilot/rules/work-order.md"
  - "tests/structure/test-autopilot-state-machine.sh"
  - "tests/structure/test-autopilot-durable-skill.sh"
---

# Autopilot Gate Re-entry (`transition` in `hooks/lib/zensu-autopilot-state.sh`)

`PR_OPENED` accepts only the head the gates tested (`evidence.gates.headSha`). Before this
change the gates could be recorded in GATES alone, and `CONVERGENCE_FAILED` returns its fix to
CONVERGE, the one pre-PR return path that skips GATES. A convergence fix that landed a commit
therefore reached OPEN_PR with gate evidence for the commit before it, and `PR_OPENED` refused
the new head for good: run `run_8c3e58615f328a12` (zensu-session-hub, 2026-11-10) blocked as
`PR_HEAD_GATE_MISMATCH` and was cancelled by hand.

**The fix adds edges and relaxes one head comparison; no existing edge changes.** `GATES_PASSED`
and `GATES_FAILED` are also accepted in CONVERGE and in OPEN_PR. A failure stores the failed
evidence and returns the fix through `toAwaitTdd(state, "GATES")`, the path GATES already uses.
A pass in OPEN_PR stores the gate evidence for its head and moves the run to CONVERGE, so
convergence runs again on the head the PR will carry. A pass in CONVERGE stores the evidence and
does not move: the stage stays CONVERGE and its Stop budget keeps counting, because a gate event
there proves no progress. OPEN_PR refuses a gate event for the head its gate evidence already
records (`gates already recorded for this head`), so a gate run that tests nothing new cannot
cycle OPEN_PR → CONVERGE → OPEN_PR. `PR_OPENED` compares the PR head with the gate head through
`sameSha`, as every other head check of the machine does.

**Why additive only.** `semanticHistoryValid` replays every stored event through `transition`
and compares each recorded `toStage` and the derived state with the record. A changed target,
precondition or effect of an existing case would therefore turn a record that is valid today
into an invalid one, terminal records included, and `begin` and `read-workspace` read every
record of the project. Returning `CONVERGENCE_FAILED` through GATES instead was rejected for
exactly that reason: every stored record whose `TDD_CHAIN_DONE` returned to CONVERGE would stop
replaying. `GATES:GATES_PASSED` and `GATES:GATES_FAILED` keep their bodies; the new cases have
their own. The `sameSha` comparison accepts what the exact comparison accepted plus case
variants, so no stored `PR_OPENED` replays differently.

**OPEN_PR accepts gate events in both of its effect states.** In OPEN_PR the PR-open effect is
`none` or `requested`, because `PR_OPENED` completes it and leaves the stage in the same
transition. After `PR_OPEN_REQUESTED` the operation key survives the return to CONVERGE and a
fix loop: `PR_OPEN_REQUESTED` stays refused, and `PR_OPENED` with the recorded key and the newly
gated head completes the operation. Without this, a run that requested the PR, opened it on a
newer commit and then saw `PR_OPENED` refused would hit the same dead end one step later.

**The skill keeps the gate head and the PR head equal, and bounds the re-entry.**
`skills/autopilot/SKILL.md` step 2 commits before the gates run, step 2b re-runs step 2 after
each convergence fix, and step 3 only pushes and follows `skills/autopilot/rules/pr-open.md`: the
full `git rev-parse HEAD` in every event, a head check before the push that sends an ungated head
or uncommitted work outside `.zensu/` back to step 2, the takeover of a PR/MR the run already
requested, and one re-gate per open request before a `BLOCK` with `PR_HEAD_GATE_MISMATCH`. The
takeover runs `--locate-pr` before any push and blocks without pushing when that PR/MR is merged
or closed (`PR_NOT_OPEN`) or the lookup fails (`PR_LOOKUP_FAILED`); it reads the forge's
`head_sha` from `--diff-refs`, applies the body again and persists `PR_OPENED` on the recorded
key. Only local work the gates never tested goes back to step 2. A forge head that still differs
from the gated head after a bounded re-read blocks instead, because step 2 would test the head the
gates already recorded and the state machine refuses that gate event.
`skills/autopilot/rules/work-order.md` overrides step 3 for work-order mode, runs the same head
check and does not commit after the gates. A run already blocked that way recovers with
`RESUME`, `GATES_PASSED` on the current head, `CONVERGENCE_PASSED` and `PR_OPENED` on the
recorded key. The CONVERGE resume directive in `hooks/session-start-autopilot-resume.sh` says to
commit and re-run the gates when the working tree holds changes outside `.zensu/` or HEAD differs
from the gate evidence. The skill body sits on the shrink-only allowlist of
`tests/structure/test-skill-text-budget.sh`, so the detail lives in the rules file.

**The body refresh.** The PR body's `Gates bypassed during build:` line is rendered from the
plan artifact's build union, and a re-entry fix chain can change that union after the PR exists.
`rules/pr-open.md` §4 applies the body again on every push to an open PR/MR, the re-entry
included, with `gh pr edit` or `glab mr update`, because the driver has no body verb.

**Version: `minor`.** No key set, payload schema or event type moves. But an older installation
of the 0.36 lineage refuses two record shapes this change can write: the gate edges
(`CONVERGE:GATES_PASSED`, `OPEN_PR:GATES_PASSED` and their failure twins replay as "event … is
not allowed"), and a `PR_OPENED` whose head differs from the gate head only in letter case (the
payload is stored as given and the gate head in lower case, and the released replay compares
them exactly). A record carrying either fails `semanticHistoryValid` there, and every verb of
that installation that reads the record fails closed. That is the forward-incompatible direction
`.claude/rules/autopilot-run-scope.md` leaves to a `minor` release. The release pipeline sets the
version; never bump it by hand.

**Tests.** `GR1` to `GR9` in `tests/structure/test-autopilot-state-machine.sh` and `D17` in
`tests/structure/test-autopilot-durable-skill.sh`. `GR6` and `GR3` start from a frozen record:
`tests/structure/fixtures/autopilot-0.36.0-pr-head-gate-mismatch/` holds the run record and the
owner pointer the 0.36.0 library wrote for the incident's event sequence (a convergence fix,
`CONVERGENCE_PASSED`, `PR_OPEN_REQUESTED`, a refused `PR_OPENED`, `BLOCK`), with `@PROJECT_ROOT@`
in place of the two path fields, which the suite fills with the fixture project's native path.
`GR6` reads it as valid with the current library, so a change to an existing case's effect that
moves write and replay together still turns it red; `GR3` resumes it and opens the PR on the
recorded key. `GR8` pins that a gate event in CONVERGE keeps the Stop budget and `GR9` that
OPEN_PR refuses a same-head gate event. Against the released library `GR1`, `GR2`, `GR3`, `GR4`,
`GR4b`, `GR5` and `GR8` fail, `GR6` and `GR7` pass, and `GR9` passes only because that library
refuses every gate event in OPEN_PR. `D17` pins the step 2, 2b and 3 wording, the rules file's takeover and bound, and the
work-order line, with negative checks that neither step 3 nor the work-order line commits.

**Windows cost, UNMEASURED.** The GR block makes 58 lease-taking state-library calls across five
temporary projects; the frozen fixture and the snapshots shared by `GR1`/`GR2` and
`GR4`/`GR4b`/`GR7`/`GR9` keep that count down. The suite runs on the blocking `windows-shard-1`,
and `.claude/rules/windows-budget-best-solution-first.md` carries the estimate and the rule that
the next green Windows figure replaces it.

**Known gaps, accepted and named:**

- The state machine cannot see whether the gates ran: `GATES_PASSED` is a claim the skill
  records, in CONVERGE and OPEN_PR exactly as in GATES.
- Outside work-order mode the head `PR_OPENED` checks is a claim as well: the first open
  persists the local `git rev-parse HEAD`, and only the re-entry reads the forge's `head_sha`.
  Work-order mode is stronger, because its `--open-pr` refuses unless the local HEAD equals the
  head Zensu recorded at `--push`.
- The bound of one re-gate per open request is skill text. The state machine refuses only the
  progress-free repeat of the same head; a loop that mints a new commit on every pass ends at the
  rules file's bound or, failing that, at the 512-event ledger.
- The uncommitted-work check of section 1 of the rules file is skill text as well. An untracked
  file the gates leave outside `.zensu/` and outside `.gitignore` sends the run back to step 2,
  which either commits it or records the same head again, and the state machine refuses that.
- The re-read of the forge head is skill text, bounded at three reads. A forge slower than that
  blocks a run whose push did land; `RESUME` then repeats the takeover, which finds the PR/MR and
  reads the head again.
- A gate event in OPEN_PR moves the run to CONVERGE and restarts that stage's Stop budget, as
  every stage move does.
- A gate event in CONVERGE may name the head the gates already recorded; it stores the evidence
  again and changes nothing else.
- A `requested` PR-open effect can now sit through CONVERGE and a fix loop; the resume hook and
  the doctor only render its status.
- The body edit names the forge CLIs directly, because the driver has no body verb.
