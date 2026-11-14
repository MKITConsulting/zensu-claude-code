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
- **`add:`, `restore:`, `review:`, `tree:`, or no remedy** (`unresolved`, `unavailable`): not yours
  to verify away.
  Carry the line into your report and leave the decision to the user.
- **`accept:`, or a criterion that verification returns as `partial`** while the summary names no
  `review:` or `tree:` segment: follow §Consent below.

## Consent

`$ROOT/skills/verify-feature/rules/acceptance-consent.md` (the `ROOT` the generation guard sets)
owns what `partial` means, where consent comes from, the ONE question with its options and the
`## Manual Acceptance` row: read it before you act on an `accept:` segment or a `partial`
verdict. `partial` is never a must-fix and never spends the one fix round. Here it means:

1. **A Manual Acceptance row that file accepts, for every id the `accept:` segment names**: apply
   the rows without asking and add `--accept-partial <ids>` to the finalize step 1 `--chain-done`
   call, with exactly those ids. A row covers only its own criterion: when rows cover some of the
   ids, the others need item 2 or item 3.
2. **The user's answer in the verification report**: `/zensu:verify-feature --chain` asks when it
   finds the gap and names the answer. For an accepted criterion write its `## Manual Acceptance`
   row, then pass `--accept-partial`; carry one left open into your report.
3. **Otherwise ask the ONE question** that file names, with its options in its order.
   - After **Provide access now**, run `/zensu:verify-feature --chain --log <run-log>` again for
     those criteria.
   - After **Accept as partial**, write the criterion's `## Manual Acceptance` row, then add
     `--accept-partial <ids>` to the finalize step 1 call. The terminus records
     `acceptance-partial` in the bypass ledger and prints `ACCEPTANCE — partial-accepted` with one
     `ACCEPTANCE — accepted as partial:` line per criterion.
   - After **Leave the chain open**, do not end the turn at Phase 3. Finish Phase 4 (the fix round when
     another must-fix is due, then the finalize steps) and run the finalize step 1 terminus without
     `--accept-partial`; its refusal records the hand-off. Then carry the refusal into your report
     and end the turn. The Stop guard lets a chain whose terminus refused with user remedies only
     end its turn, and blocks again after an edit or a new review generation.
4. Never pass `--accept-partial` without consent and a row for each id it names, never name a
   criterion the `accept:` segment does not list, and never offer, set or mention a way to switch
   the acceptance gate off.
