# Validate stage (Phase 1 step 6)

The VALIDATE stage proves that every active acceptance criterion of the plan the user approved
holds on the pull-request head. The proof is a set of acceptance records, one per criterion, and
the run leaves VALIDATE only through `--autopilot-validate`, which checks them and applies
`VALIDATION_PASSED` itself. `--autopilot-event` refuses `VALIDATION_PASSED`; `VALIDATION_FAILED`
stays yours to send.

The criteria are the `AC-###` rows of the approved plan's `## Requirements` table. The plan hook
stored that plan byte for byte under `.zensu/state/` when the user approved it, and every verb
below reads that copy, never the plan text in this conversation. In work-order mode the plan is
`.zensu/plans/<order-id>.md`.

`$LOG`, `$ROOT` and `$RUN_ID` are the ones `SKILL.md` resolved. Run every helper with its leading
`CLAUDE_PLUGIN_DATA="…"` assignment exactly as `SKILL.md` renders it.

## 1. Before you drive

Check out the pull-request head and leave the work tree clean: every record binds to the tree it
was taken on, and `--autopilot-validate` refuses a work tree whose `HEAD` is not the pull-request
head or that holds an uncommitted or untracked change outside `.zensu/`. Write throwaway output
outside the project or to a gitignored path.

## 2. Record each criterion right after you observe it

Run the resolved driver (`rules/drivers.md`) for one criterion, authenticating through the
credential-blind login script when one is configured (`rules/auth.md`), then record it before you
move on. A deprecated criterion is not driven; its row stays in the table. A driver decided by an
exit code (`api`, `cli`, `library`, `async`, `iac`, `custom`) runs its check
through the plugin, and the record cites that run:

```bash
CLAUDE_PLUGIN_DATA="…" bash "$LOG" --evidence-run --scope acceptance --run "$RUN_ID" --cmd '<check>'
CLAUDE_PLUGIN_DATA="…" bash "$LOG" --acceptance-record --run "$RUN_ID" \
  --ac AC-001 --verdict pass --driver cli --evidence-run <record id> <<'EVIDENCE'
<what the check showed>
EVIDENCE
```

A UI driver (`browser`, `mobile`, `desktop`) records what it saw, without `--evidence-run`. A pass
needs a run that exited 0, a `fail` one that did not. Record `partial` when only part of a
criterion could be observed, such as a degraded driver from the degradation ladder, and say in the
evidence which part is missing. What the evidence may contain, and what it must never contain, is
`$ROOT/skills/verify-feature/rules/acceptance-evidence.md` §1.

`--acceptance-status --run "$RUN_ID"` prints the state of every criterion on the current tree and
the same remedy segments as a refusal; run it before `--autopilot-validate` when in doubt.

## 3. Validate

```bash
CLAUDE_PLUGIN_DATA="…" bash "$LOG" --autopilot-validate --run "$RUN_ID"
```

- **Exit 0**: the run moved to `COVER` or `DELIVER`. Leave the loop.
- **Exit 1**: the `ACCEPTANCE —` line on stderr names every criterion that does not pass. Act on
  its segments:
  - `run:` a criterion is `missing`, `stale` or `partial`: drive it again on this tree and record
    it.
  - `fix:` a criterion fails on this tree: persist `VALIDATION_FAILED` with the pull-request head,
    fix it through `/zensu:build` (vanilla, scoped to the failing criteria, carrying
    `AUTOPILOT-RUN: <RUN_ID>`). When the fix attempt brings the run back to `VALIDATE`, finish the
    current-head handoff of `SKILL.md` before you validate: re-run the step-2 gates, push and record
    `PR_HEAD_UPDATED`. The run is then at `FIX_FINDINGS`, and `FINDINGS_CLEARED` on the new head
    returns it to `VALIDATE`. The new head makes every record stale, so every criterion is verified
    again.
  - `accept:` every criterion that does not pass is `partial`: run the verb again with
    `--accept-partial`. It records `acceptance-partial` in the run's `bypasses` list and validates the run;
    the pull-request row reads `🟡 partial` with the evidence.
  - A refusal without a segment (`unresolved`), an `add:` or a `restore:` segment: persist `BLOCK`
    with the code `validation-unresolved` and report the line. Only the user can add a criterion
    to an approved plan, so the decision stays with the user. A cause that names the pull-request
    head or a dirty work tree is fixed by checking out the head or cleaning the tree, then
    validating again.
- **Exit 2**: a misuse, such as a run id that is not this session's active run or a run that has
  ended, or a fault the line names, an `ACCEPTANCE — unavailable` verdict included. Never retry it
  blindly: persist `BLOCK` with `validation-unresolved` and report. One exit-2 refusal is no
  fault: a run back from a fix attempt whose pushed head is not recorded yet. Finish the handoff
  the `fix:` arm describes, then validate on the new head.

Under an advisory acceptance gate the verb discloses a refusal as `(advisory, not blocking)`,
validates the run anyway and records `acceptance-advisory` in its `bypasses` list.

Never offer, set or mention a way to switch the acceptance gate off, whatever the verb answers:
no person is present to decide it while this stage runs.

## 4. The pull-request table

Fill the per-AC table from `--acceptance-status --run "$RUN_ID"` on the validated head: a `pass`
row is `🟢 pass` with its evidence, a `partial` one `🟡 partial` with the reason, and a deprecated
one `⚪ deprecated` without evidence. The `Gates bypassed during build:` line unions the
`--bypass-list` entries with every `bypasses[].gate` that `--autopilot-status` reports for the run.
