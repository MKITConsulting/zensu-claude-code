# Acceptance remedies and consent (`/zensu:self-review`)

Read this at the Phase 3 acceptance re-verification and at the Phase 4 finalize step 1 terminus
whenever an `ACCEPTANCE` summary or refusal line names a remedy. Act on its remedy segments, never
on the exit code alone. `<run-log>` is the run log the Phase 3 must-fix paragraph names.

- **`run:`**: invoke `/zensu:verify-feature` with `--chain --log <run-log>` (Skill tool,
  `skill='zensu:verify-feature'`). It drives only the criteria that are `missing`, `stale` or
  `partial`. Never drive a criterion again while it already has a `fail` on the current tree and
  nothing was edited since.
- **`fix:`**: a criterion fails on this tree. It is a must-fix candidate for the one fix round,
  exactly like a `parked` ledger entry, and so is a criterion that verification returns as `fail`.
  A fix round that edits anything makes every record stale, so pass 2 runs the re-verification
  again. A criterion that still fails after the spent round goes into your report and to the user.
- **`add:`, `restore:`, or no remedy** (`unresolved`, `unavailable`): not yours to verify away.
  Carry the line into your report and leave the decision to the user.
- **`accept:`, or a criterion that verification returns as `partial`**: follow §Consent below.

## Consent

`partial` means the criterion could be observed only in part in this environment: it needs
credentials, an account, a non-loopback host, a signed build, or a fact the drivers cannot see. No
code change turns it, so it is never a must-fix and never spends the one fix round.

1. **Consent the plan already records.** When the plan's `## Manual Acceptance` table lists the
   criterion with the user's consent, apply it without asking again: add
   `--accept-partial <ids>` to the finalize step 1 `--chain-done` call, with exactly the ids the
   `accept:` segment names.
2. **The user's answer in the verification report.** `/zensu:verify-feature --chain` asks the
   user about such a criterion when it finds the gap and names the answer in its report: apply an
   accepted criterion as the second option below says, and carry one left open into your report.
3. **Otherwise ask ONE question** that names each criterion and why it could not be observed, with
   these options in this order:
   - **Provide access now**: a visible manual login, a test account, or a service the user starts.
     Then run `/zensu:verify-feature --chain --log <run-log>` again for those criteria.
   - **Accept as partial**: add the criterion's row to the plan's `## Manual Acceptance` table
     (the check a person runs before release, why this environment cannot observe it, the
     consent), then add `--accept-partial <ids>` to the finalize step 1 call. The terminus
     records `acceptance-partial` in the bypass ledger and prints `ACCEPTANCE — partial-accepted`
     with one `ACCEPTANCE — accepted as partial:` line per criterion.
   - **Leave the chain open**: do not end the turn at Phase 3. Finish Phase 4 (the fix round when
     another must-fix is due, then the finalize steps) and run the finalize step 1 terminus without
     `--accept-partial`; its refusal records the hand-off. Then carry the refusal into your report
     and end the turn. The Stop guard lets a chain whose terminus refused with user remedies only
     end its turn, and blocks again after an edit or a new review generation.
4. Never pass `--accept-partial` without that consent or that table row, never name a criterion the
   `accept:` segment does not list, and never offer, set or mention a way to switch the acceptance
   gate off.
