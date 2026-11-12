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
`pass` record on the tree that ships. Prose in `/zensu:build` step 6d and `/zensu:self-review`
cannot guarantee that, so the guarantee is a machine gate at `--chain-done`, built like the
full-suite gate (`.claude/rules/evidence-runner.md`). The one close it never sees is a
max-rounds close with `hooks.selfReview` off, see §Where it applies.

**One owner.** `acceptance-verify-v1.js` owns the record schema (`RECORD_KEYS`, an exact key
set), ids (`av1_…`), the store, the criterion and verdict state lists, retention, the chain
anchor and every display string. `zensu-log.sh` only transports: `ZENSU_AVR_*` variables kept
out of MSYS conversion, the evidence text and the gate mode as files in a temporary directory.
The tree fingerprint, git scrub, secret screen and record reader are REUSED from
`evidence-run-v1.js`, never copied. The one exception is a transport the terminus could not
prepare: the shell then prints its own `escaped` and advisory lines and its refusal (below).

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
terminus stays silent (`test-chain-terminus-zero-change-gate.sh` G1), and so does a minted
`zc_` self-review ticket on a changed tree, which the terminus refuses before either gate runs
(`G9e`). A max-rounds close with
`hooks.selfReview` off is not gated, as for the full suite: a standalone chain closes through
`tdd_mark_review_converged` without a terminus, and a bound one runs `--chain-done --outcome
max-rounds` with its output discarded. `MAX_ROUNDS_VERDICTS` in the post-review hook tells the
renderer to show both verdicts as not checked. `ZENSU_ACCEPTANCE_GATE=off` is read only after the
bound and `not-applicable` answers, so it is ledgered only where the gate applies, for a failed
preparation too, unless the module cannot be asked or the preparation stopped before the chain's
inputs (below).

**A failed preparation is decided in the verdict's order, and the module builds every line that
needs its judgment.** When the transport cannot be prepared at the terminus (an unresolvable
module, plugin data, receipt or log path, no temporary directory, or a transport write that
fails), `_zensu_acceptance_gate_unjudged` asks the module through `_zensu_avr_ask`, which runs
`main(['unjudged'])` with no transport directory. It sets every `ZENSU_AVR_*` input
`transportOptions` reads, blanking the ones this terminus did not resolve, so a value inherited
from the caller never answers for this chain, and passes the raw gate mode, the cause and
`_avr_chain_inputs` as `ZENSU_AVR_GATE_MODE`, `ZENSU_AVR_CAUSE` and `ZENSU_AVR_CHAIN_INPUTS`.
`unjudged()` builds its lines as `verdict()` does: the unknown-mode disclosure first; for a bound
chain `boundLine` with the failure in parentheses at its end; for a standalone chain whose
preparation resolved the receipt path and the edit-landing escape (`_zensu_avr_prepare` sets
`_avr_chain_inputs` only past both, because `verdictChain` reads both) `verdictChain`'s
`not-applicable` reason through `notApplicableLine`, the template `verdict()` prints, with the
failure in parentheses before `| gate:`, and no escape is recorded. It exits 0 when it decided
and 3 when it leaves the chain to the shell, printing only the disclosure then, so the shell
holds no reason, no bound sentence and no not-applicable frame. `_zensu_acceptance_gate` resets
the module path, plugin data, receipt, escape and the inputs flag before it prepares. After that
an escaped gate is ledgered and passes with `ACCEPTANCE — escaped | ZENSU_ACCEPTANCE_GATE=off
switched this check off, so no acceptance record was read (<cause>) | gate: <mode>`, an advisory
gate passes with `ACCEPTANCE — unavailable (advisory, not blocking) | <cause>, so no acceptance
record was read | gate: advisory`, each after the disclosure, and a required gate prints the
disclosure and refuses with `the chain stays open; resolve the acceptance transport fault named
above, then run --chain-done again.` and no other `ACCEPTANCE` line (`A34` to `A36`, `A46`,
`A46b`). `A39` to `A45` cover the states a check can stage that must not answer `not-applicable`:
a changed file, an index-only change, an edit-landing escape in the environment or in the ledger,
a receipt, a `git status` that fails, and a preparation that stopped before the chain's inputs
while the caller exported the inputs flag. The module's other no-answers (an invalid receipt, a
receipt whose plan is missing, a store fault on the escaped path, a work-tree probe that cannot
decide) take the same exit 3 and are driven by no check here. Every passing line prints after the
transition, so the CHAIN-END SUMMARY carries it. When the module cannot be asked (its path cannot
be resolved or it does not load; `node` is there, because the Session Control bind needs it), a
standalone chain gets neither the not-applicable answer nor the disclosure, so an escape is
ledgered and a required gate refuses where the module would have passed, which over-discloses and
never passes in silence, while a bound chain passes with no `ACCEPTANCE` line, because the bound
terminus never gates. A transport write that fails (`gate-mode`, and `evidence` for
`--acceptance-record`) stops both verbs with exit 2 and the shell's own line before the module
runs (`A33`, the fail-closed transport in `.claude/rules/evidence-runner.md`).

**Coupled sites:** `ZENSU_BYPASS_GATE_ALLOWLIST` and `tdd_bypass_recorded` in
`zensu-tdd-phase.sh`; both protected-root lists in `reviewer-capability-v1.js`;
`zensu_evidence_acceptance_gate` in `zensu-config.sh`; `_zensu_acceptance_gate_unjudged` and
`_zensu_avr_ask` in `zensu-log.sh`, whose escaped line repeats the module's escaped wording with
the cause appended (`A15` pins the module's, `A34` the shell's); `unjudged`, `notApplicableLine`
and the `unjudged` mode of `main()` in the module, which the three `unjudged` cases of
`acceptance-verify-v1.test.js` pin against `verdict()`'s own lines, while through the shell `A37`
to `A37d`, `A38` and `A38b` derive each expected line from the module's line in `A20`, `A23`,
`A26` and `A27`, and `A46` and `A46b` the disclosure from `A18`, so a reword on either side fails
there;
`SCOPES`/`TREE_SCOPES` and per-scope
retention in `evidence-run-v1.js`; the `receipt-log` call and its exit handling in
`--tdd-complete`; step 6d in `skills/build/references/audit.md`, Phase 1.5 in `references/planning.md` and step 2c in `references/review-chain.md`; the
re-verification paragraph, finalize steps and the `Acceptance` row of
`skills/self-review/SKILL.md`; `COMBINED_SUMMARY_DIRECTIVE`, `ACCEPTANCE_REVERIFY`,
`ACCEPTANCE_REFUSAL`, `MAX_ROUNDS_VERDICTS` and the self-review-off `CLOSE_PASS` in
`hooks/post-review-tdd-delegate.sh`; §Chain mode of `skills/verify-feature/SKILL.md`;
`templates/zensu-plan.md` Final Verification; `ESCAPE_STEMS` in
`tests/structure/test-gauntlet-loop-skill.sh`; the escape counts in `gate-disable-prefixes.md`,
`review-spawn-scope-sentence.md`, `docs/configuration.md` (the opt-out roster, the
`reviewSpawnScopeSentence` row and the `ZENSU_SESSION_LINEAGE` row) and the review-spawn
paragraph of `docs/build-workflow.md`; `docs/gates.md` §Acceptance Verification Gate and
its intro count; `docs/configuration.md` §Acceptance Verification and the escape row; discipline
patch 14 and the chain-end summary rows in `docs/build-workflow.md`; the verbatim-carry
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
- **The bound line for a validate option that cannot be read is driven by no check.**
  `stateValid` in `zensu-autopilot-state.sh` rejects a run record whose option is not a boolean,
  so `boundLine`'s third sentence is reached only when the run record cannot be read at all, on
  the module path and on the failed-preparation path alike; `A26`, `A27`, `A38` and `A38b` drive
  the other two.
- **A preparation that stops before the receipt path is resolved is driven by no check.** The
  Session Control bind validates `CLAUDE_PLUGIN_DATA` with the same host-path check before any
  verb runs, and on POSIX the receipt path cannot fail to resolve once the state file did, so
  neither stop can be staged. `A45` drives the one stop before the chain's inputs a POSIX run
  reaches: a log path inherited as `_avr_log` that cannot be resolved, on a ledgered edit-landing
  escape, where a module asked without the flag would answer `not-applicable`. That stop comes
  after the receipt path, so a chain with a receipt cannot show the flag's effect.
- **Every edit makes every record stale**, because the fingerprint covers the whole tree. A
  chain whose review rounds change code verifies twice, three times when self-review's fix round
  edits too. Scoping records to the paths a criterion touches is not possible without a
  per-criterion path map nobody maintains.
- **A standalone chain's fingerprint is the project root's alone.** An
  `--evidence-run --scope acceptance` run whose command starts with `cd` into a nested worktree is
  still bound to the project tree, because `chainTree` in `acceptance-verify-v1.js` compares a
  standalone chain's records with `computeTree(projectRoot)`. An edit in that worktree after the
  run leaves the record current. The full-suite gate follows the nested work tree for `full` and
  `scoped` runs (`.claude/rules/evidence-runner.md`). A chain bound to an Autopilot run whose
  `workspaceRoot` is a worktree nested below the anchor is not this gap: `zensu-log.sh` passes
  that worktree as `ZENSU_AVR_WORK_TREE`, so its records, its status and the acceptance runs it
  cites bind the combined tree of the project and the worktree, and an edit there makes them
  stale. A worktree the shared lookup cannot answer reaches the module as the transport file
  `work-tree-fault`, and the module words the refusal: after its usage checks `record()` exits 2
  with `the chain's work tree could not be determined, so no acceptance record can be bound to
  it: <cause>`, and `status()` prints the same cause as an `ACCEPTANCE STATUS — unavailable`
  summary line with exit 2, which every consumer already reads as a summary with no remedy. An
  empty or unreadable fault file is a fault with a fixed cause, and a fault file the shell could
  not write stops both verbs with exit 2 and the shell's own line before the module runs, so a
  lost cause never reads as a standalone chain (the fail-closed transport in
  `.claude/rules/evidence-runner.md`). Its terminus still answers `not-checked`, because VALIDATE
  verifies the run's criteria (`A29` to `A32` in `test-acceptance-gate.sh` and the work-tree
  fault cases of `acceptance-verify-v1.test.js`; **version `patch`**, walked in
  `.claude/rules/evidence-runner.md`).
- **Consent prompts need a person**, as in §"Browser Consent Gate": Auto mode was measured to
  reach the user, and bypass permissions and `dontAsk` deny a remote origin outside a policy. How
  a headless or SDK run resolves the prompt is unmeasured, and the gate cannot tell a person from a
  program that answers it, so unattended browser verification belongs in `dontAsk` or bypass
  permissions with a policy that names every origin it needs.
- **Windows is unverified**: neither suite is in `tests/profiles/windows-ci.v1.json`.
- **No ports.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not included.
