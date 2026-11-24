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
head or that holds an uncommitted or untracked change outside `.zensu/`. `--acceptance-record --run`
and `--acceptance-status --run` refuse the same work tree with exit 1 and the same cause, so fix
that cause before you drive. Write throwaway output outside the repository or to a gitignored
path.

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
needs a run that exited 0, a `fail` one that did not. `partial` means what
`$ROOT/skills/verify-feature/rules/acceptance-consent.md` §"What `partial` means" defines: this
environment cannot observe the criterion, because it needs credentials, an account, a non-loopback
host or a signed build, or because its driver cannot run here, or because a driver fence rules
the state out (no driver has one today). Name that cause in the evidence. A
criterion you could observe but did not prove is not `partial`: drive it again. An observation that
contradicts the criterion is `fail`. What the evidence may contain, and what it must never
contain, is `$ROOT/skills/verify-feature/rules/acceptance-evidence.md` §1.

`--acceptance-status --run "$RUN_ID"` prints the state of every criterion on the current tree and
the same remedy segments as a refusal; run it before `--autopilot-validate` when in doubt.

## 3. Validate

```bash
CLAUDE_PLUGIN_DATA="…" bash "$LOG" --autopilot-validate --run "$RUN_ID"
```

- **Exit 0**: the run moved to `COVER` or `DELIVER`. Leave the loop.
- **Exit 1**: the `ACCEPTANCE —` line on stderr names every criterion that does not pass. Act on
  its segments:
  - `run:` a criterion is `missing` or `stale`: drive it again on this tree and record it.
  - `fix:` a criterion fails on this tree: persist `VALIDATION_FAILED` whose `headSha` is the
    recorded pull-request head,
    fix it through `/zensu:build` (vanilla, scoped to the failing criteria, carrying
    `AUTOPILOT-RUN: <RUN_ID>`). When the fix attempt brings the run back to `VALIDATE`, finish the
    current-head handoff of `SKILL.md` before you validate: re-run the step-2 gates, push and record
    `PR_HEAD_UPDATED`. The run is then at `FIX_FINDINGS`, and `FINDINGS_CLEARED` on the new head
    returns it to `VALIDATE`. The new head makes every record stale, so every criterion is verified
    again.
  - `accept:` every criterion that does not pass is `partial`, and the approved plan's
    `## Manual Acceptance` table lists each one. First check that each row's reason names the same
    cause category as that criterion's `partial` evidence, as
    `$ROOT/skills/verify-feature/rules/acceptance-consent.md` §"Where consent comes from" requires;
    the gate reads only the ids. When every row matches, run the verb again with `--accept-partial`
    and the comma list of ids the segment names. The ids must be exactly the open criteria. It
    records `acceptance-partial` in the run's `bypasses` list and validates the run; the
    pull-request row reads `🟡 partial` with the evidence. A row whose reason names another
    category carries no consent: take the `consent:` arm.
  - `consent:` every criterion that does not pass is `partial`, but the approved plan's
    `## Manual Acceptance` table has no row for one of them, its table could not be read, a row
    names another cause category than the criterion's `partial` evidence, or the criteria come from
    a work-order plan no person approved: no consent covers it, and this stage asks no question.
    Persist `BLOCK` with the code `validation-unresolved` and report the line.
  - A refusal without a segment (`unresolved`), an `add:` or a `restore:` segment: persist `BLOCK`
    with the code `validation-unresolved` and report the line. Only the user can add a criterion
    to an approved plan, so the decision stays with the user. A cause that names the pull-request
    head is fixed by checking out the head, then validating again, unless it says no checkout settles
    it: then block as the line says. A cause that names a dirty work tree lists its first
    changed paths: send a change that belongs to the change through the fix loop as the `fix:` arm
    does, remove what a check left behind, then validate again.
  - A refusal of `--accept-partial` itself: when every criterion passes, validate again without
    it; when the ids differ from the open criteria, the line names the difference.
- **Exit 2**: a misuse, such as a run id that is not this session's active run or a run that has
  ended, or a fault the line names, an `ACCEPTANCE — unavailable` verdict included. Never retry it
  blindly: persist `BLOCK` with `validation-unresolved` and report. One exit-2 refusal is no
  fault: a run back from a fix attempt whose pushed head is not recorded yet. Finish the handoff
  the `fix:` arm describes, then validate on the new head.

Under an advisory acceptance gate the verb discloses a refusal as `(advisory, not blocking)`,
validates the run anyway and records `acceptance-advisory` in its `bypasses` list. A cause that
names the pull-request head or a dirty work tree refuses under every gate mode. In work-order mode,
when no person approved the plan, the `ACCEPTANCE PLAN UNAPPROVED` line says so and the verb
records `acceptance-plan-unapproved` in the run's `bypasses` list before it validates.

Never offer, set or mention a way to switch the acceptance gate off, whatever the verb answers:
no person is present to decide it while this stage runs.

## 4. The pull-request table

Fill the per-AC table from `--acceptance-status --run "$RUN_ID"` on the validated head: a `pass`
row is `🟢 pass` with its evidence, a `partial` one `🟡 partial` with the reason, and a deprecated
one `⚪ deprecated` without evidence. A run that validated under the advisory gate or the switched-off
gate can still show other rows: a `missing` or `stale` one is `🟡 unvalidated`, a `fail` one
`🔴 fail` with its evidence, and a `dropped` one `🔴 fail` whose evidence cell says it was dropped. The `Gates bypassed during build:` line unions the
`--bypass-list` entries with every `bypasses[].gate` that `--autopilot-status` reports for the run.
