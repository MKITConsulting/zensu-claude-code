---
paths:
  - "hooks/lib/acceptance-verify-v1.js"
  - "hooks/lib/edit-landing-receipt-v1.js"
  - "hooks/lib/zensu-plan-requirements.sh"
  - "tests/structure/acceptance-verify-v1.test.js"
  - "tests/structure/test-acceptance-gate.sh"
  - "skills/verify-feature/SKILL.md"
  - "skills/self-review/SKILL.md"
---

# Acceptance Verification Gate (`hooks/lib/acceptance-verify-v1.js` + `zensu-log.sh --acceptance-*` / `--chain-done`)

A standalone reviewed chain closes only when every active `AC-###` criterion of its plan has a
`pass` record on the tree that ships. Prose in `/zensu:tdd` step 6d and `/zensu:self-review`
cannot guarantee that, so the guarantee is a machine gate at `--chain-done`, built like the
full-suite gate (`.claude/rules/evidence-runner.md`). The one close it never sees is a
max-rounds close with `hooks.selfReview` off, see §Where it applies.

**One owner.** `acceptance-verify-v1.js` owns the record schema (`RECORD_KEYS`, an exact key
set), ids (`av1_…`), the store, the criterion and verdict state lists, retention, the chain
anchor and every display string. `zensu-log.sh` only transports: `ZENSU_AVR_*` variables kept
out of MSYS conversion, the evidence text and the gate mode as files in a temporary directory.
The tree fingerprint, git scrub, secret screen and record reader are REUSED from
`evidence-run-v1.js`, never copied.

**One row parser.** Criteria come from `zensu-plan-requirements.sh --list`, the same awk program
that decides whether the table is usable. It prints `<id>\t<active|deprecated|placeholder>\t<text>`
per id, a comma list expanded. The module keeps `AC-###` ids with state `active` or
`deprecated` and drops the rest, so a template placeholder row is never a criterion. Deprecated
is NARROW on purpose. The awk lowercases the Requirement cell and strips leading emphasis
characters (`*`, `_`, `~`, a backtick, a space); the rest must then start with `(deprecated)` or
`[deprecated]`, be the bare word `deprecated`, or start with `deprecated` followed by `:`, `—`,
`–` or a spaced ` - `. `Deprecated-flag handling` and `deprecated/legacy path` stay active. An
unmarked row is verified, because a broad match would let a criterion opt itself out.

**The chain anchor is the edit-landing receipt, read through ONE reader.**
`hooks/lib/edit-landing-receipt-v1.js` owns the receipt schemas, the bounded no-follow read and
`receiptRunLog`. `acceptance-verify-v1.js` requires it, and `--tdd-complete` runs it through
`main(['receipt-log'])` (exit 0 answers the log, 3 answers none); any other exit refuses
`--tdd-complete` without judging the plan, because the executing installation is not intact.
The plan is the receipt's `log` stem under `.zensu/plans/`. Every acceptance verb also takes
`--log`, whose stem must equal the receipt's. Without a receipt: an edit-landing gate escaped in
the call's environment, or recorded as escaped in the chain's bypass ledger
(`tdd_bypass_recorded` in `zensu-tdd-phase.sh`), takes the stem from `--log` (and at the
terminus from the newest record) and says so with `ACCEPTANCE STEM UNCHECKED`; a git tree with
changes is `unresolved`; a clean tree or no git is `not-applicable`, because that chain
implemented nothing a criterion could observe.

**Observed where the plugin can observe.** A driver decided by an exit code (`api`, `cli`,
`async`, `iac`, `custom`, `library`) must cite an `--evidence-run --scope acceptance`
record that completed on the current tree without changing it, and the exit code must agree
with the verdict. `partial` needs no run. UI drivers (`browser`, `mobile`, `desktop`)
are attested. The driver names are the nine ids of `skills/verify-feature/rules/drivers.md`
(`DRIVERS`), and `P10c` in `tests/structure/test-verify-feature-skill.sh` compares them with the
recipe enum. `desktop-native` (attested) and `artifact` (observed), the spellings of earlier
releases, stay accepted on write and on read (`ACCEPTED_DRIVERS`): a running session can be served
by a newer installation (§"Runtime Lineage"), so its skill text may still name them and its
records must stay readable. The `--driver` refusal names only the nine ids. **A `desktop` record
is STORED as `desktop-native` (`RECORDED_DRIVER_SPELLINGS`), and that is the lineage decision,
not a leftover.** After a `patch` update the session keeps its record, both installation roots
serve it, and a model still holding the earlier skill text calls the earlier root's
`zensu-log.sh` against the same `records/<session key>` store. Released readers check `driver` by
membership in `validateRecord`, so a stored `desktop` reads there as `unknown driver`: as the
newest record it turns the gate `invalid`, and as an older one it is dropped from `valid`, which
lets an earlier `pass` of the same criterion on the same tree stand over a newer `fail`. Storing
`desktop` itself needs a `minor` release, whose automatic adoption retires the earlier root. The
browser follows `/zensu:verify-feature`'s credential-blind rules, never the `storageState` login of
the autopilot catalog (`skills/autopilot/rules/drivers.md`).

**States.** Per criterion: `pass`, `fail`, `partial`, `missing`, `stale` (another tree, or the
criterion digest changed) and `deprecated`. A deprecated criterion whose newest record is not
`pass` is `dropped` and blocks, and so is a record id whose row was removed from the table:
`record` refuses an id the plan does not list, so such a record exists only for a removed row.
Deprecating or deleting a failing criterion never closes a chain. Gate: passing `pass`,
`pass-tree-unverified`, `not-applicable`, `not-checked`, `escaped`; refusing `incomplete`,
`no-criteria`, `unresolved`, `invalid`, `unavailable`. `flaky` discloses earlier non-pass
verdicts on the same tree. An `incomplete` line names EVERY failing criterion and gives causes
for the first `LIMITS.listedCriteria` only.

**The remedy is a segment, not the exit code.** A refusal, and the `--acceptance-status`
summary line, end with one segment per remedy that applies (`remedies`): `run:` with the full
`/zensu:verify-feature --chain --log <run log>` command for a `missing`, `stale` or `partial`
criterion and for `invalid`; `fix:` for a criterion that fails on the current tree; `add:` for
`no-criteria`; `restore:` for a dropped criterion. `unresolved` names its remedy in its cause,
`unavailable` names none. Every consumer acts on the segment: `/zensu:self-review`, the
self-review-off `CLOSE_PASS` and verify-feature chain mode re-verify only after `run:`, because
verifying an unchanged tree again cannot turn a `fail`, and a re-verify loop runs to the Stop cap.

**Where it applies.** The ticket-bound standalone terminus, evaluated TOGETHER with the
full-suite gate so one call names every refusal, after the read-only ticket pre-check. A bound
Autopilot `pass` calls it with the bound flag and the run's `validate` option and gets
`not-checked`, whose cause (`boundLine`) says whether VALIDATE verifies every criterion, the run
was started with `--no-validate`, or the option could not be read; verify-feature's questions
conflict with the delegated no-question rule, so the bound chain is never gated. The zero-change
terminus stays silent (`test-chain-terminus-zero-change-gate.sh` G1). A max-rounds close with
`hooks.selfReview` off is not gated, as for the full suite: a standalone chain closes through
`tdd_mark_review_converged` without a terminus, and a bound one runs `--chain-done --outcome
max-rounds` with its output discarded. `MAX_ROUNDS_VERDICTS` in the post-review hook tells the
renderer to show both verdicts as not checked. `ZENSU_ACCEPTANCE_GATE=off` is read only after the
bound and `not-applicable` answers, so it is ledgered only where the gate applies.

**Coupled sites:** `ZENSU_BYPASS_GATE_ALLOWLIST` and `tdd_bypass_recorded` in
`zensu-tdd-phase.sh`; both protected-root lists in `reviewer-capability-v1.js`;
`zensu_evidence_acceptance_gate` in `zensu-config.sh`; `SCOPES`/`TREE_SCOPES` and per-scope
retention in `evidence-run-v1.js`; the `receipt-log` call and its exit handling in
`--tdd-complete`; step 6d, Phase 1.5 and step 2c of `skills/tdd/SKILL.md` (the file may not grow, §"Skill Text Budget"); the
re-verification paragraph, finalize steps and the `Acceptance` row of
`skills/self-review/SKILL.md`; `COMBINED_SUMMARY_DIRECTIVE`, `ACCEPTANCE_REVERIFY`,
`ACCEPTANCE_REFUSAL`, `MAX_ROUNDS_VERDICTS` and the self-review-off `CLOSE_PASS` in
`hooks/post-review-tdd-delegate.sh`; §Chain mode of `skills/verify-feature/SKILL.md`;
`templates/tdd-plan.md` Final Verification; `ESCAPE_STEMS` in
`tests/structure/test-gauntlet-loop-skill.sh`; the escape counts in `gate-disable-prefixes.md`,
`review-spawn-scope-sentence.md`, `docs/configuration.md` (the opt-out roster, the
`reviewSpawnScopeSentence` row and the `ZENSU_SESSION_LINEAGE` row) and the review-spawn
paragraph of `docs/tdd-manager-workflow.md`; `docs/gates.md` §Acceptance Verification Gate and
its intro count; `docs/configuration.md` §Acceptance Verification and the escape row; discipline
patch 14 and the chain-end summary rows in `docs/tdd-manager-workflow.md`; the verbatim-carry
list in `status-marker-legend.md`; `docs/verify-feature.md`.

**Version: `minor`.** Every consumer's standalone chain now needs live verification to close,
and `--tdd-complete` loads a new module. No workflow-state field and no strict key set changed.
Moving the driver names to the nine verify-feature ids was a `patch`: no record key changed, every
value an earlier installation wrote or its skill text names is still accepted, and every record
this installation writes carries a spelling the released readers accept. Accepting `desktop` on
read is the half a later `minor` needs to start storing it.

**Known gaps, accepted and named:**

- **Attested verdicts are model-authored.** The gate stops forgetting and staleness, not a
  model that lies about what it saw. A Bash redirect from the main thread can forge a record,
  the residual of every plugin store.
- **An observed verdict is not bound to its criterion.** `citedRun` checks the run's id,
  session, project, scope, completion and tree, never its command. It proves that a command the
  model chose exited as recorded on this tree, and one run may back several criteria. Binding
  each run to one criterion would need the criterion id in the evidence-run record.
- **Every edit makes every record stale**, because the fingerprint covers the whole tree. A
  chain whose review rounds change code verifies twice, three times when self-review's fix round
  edits too. Scoping records to the paths a criterion touches is not possible without a
  per-criterion path map nobody maintains.
- **The fingerprint is the project root's alone.** An `--evidence-run --scope acceptance` run
  whose command starts with `cd` into a nested worktree is still bound to the project tree,
  because `acceptance-verify-v1.js` compares records with `computeTree(projectRoot)`. An edit in
  that worktree after the run leaves the record current. The full-suite gate follows the nested
  work tree for `full` and `scoped` runs (`.claude/rules/evidence-runner.md`).
- **Consent prompts in auto or headless mode are unverified host behaviour**, as in
  §"Browser Consent Gate"; unattended browser verification belongs in policy mode.
- **Windows is unverified**: neither suite is in `tests/profiles/windows-ci.v1.json`.
- **No ports.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not included.
