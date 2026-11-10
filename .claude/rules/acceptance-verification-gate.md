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
conflict with the delegated no-question rule, so the bound chain is never gated; the run's own
VALIDATE stage checks the criteria instead, through run mode (§"Autopilot run mode"). The zero-change
terminus stays silent (`test-chain-terminus-zero-change-gate.sh` G1), and so does a minted
`zc_` self-review ticket on a changed tree, which the terminus refuses before either gate runs
(`G9e`). A max-rounds close with
`hooks.selfReview` off is not gated, as for the full suite: a standalone chain closes through
`tdd_mark_review_converged` without a terminus, and a bound one runs `--chain-done --outcome
max-rounds` with its output discarded. `MAX_ROUNDS_VERDICTS` in the post-review hook tells the
renderer to show both verdicts as not checked. `ZENSU_ACCEPTANCE_GATE=off` is read only after the
bound and `not-applicable` answers, so it is ledgered only where the gate applies.

## Autopilot run mode (`--run <id>` and `--autopilot-validate`)

Autopilot's VALIDATE stage used to be self-reported: `VALIDATION_PASSED` carried only a head and
any caller could send it. It now passes only through
`zensu-log.sh --autopilot-validate --run <id> [--accept-partial]`, which applies the event itself,
and `--autopilot-event` refuses `VALIDATION_PASSED` and the two event-id namespaces the verb uses
(`validation-passed:`, `validation-bypass:`), the way `release-` is reserved.
`VALIDATION_FAILED` stays free, because failing unlocks nothing.

**The run bind.** `_zensu_run_bind` in `zensu-log.sh` serves `--acceptance-record --run`,
`--acceptance-status --run`, `--evidence-run --scope acceptance --run` and the verb. It reads the
caller's own run through `autopilot_read_active_strict` inside a command substitution, so the state
library never loads into the verb's process (the evidence runner's E22/E23 rule), requires the
named id to be that run and the run to be nonterminal, and maps the strict read's 1 to "owns no
active run" and its 5 to the unreadable-state refusal; those two, another run's id and an ended run
all exit 2, like every misuse. `--run` and `--log` exclude each other, and
`--evidence-run --run` takes `--scope acceptance` only. The run record reaches the module as the
transport file `run.json`; the work tree comes from `{"runId":"<id>"}` handed to
`_zensu_bound_work_tree` as the given context, so a run whose `workspaceRoot` is a worktree below
the anchor binds the combined tree even though no chain is open at VALIDATE.

**The criteria come from the plan the user approved.** `hooks/plan-approved-delegate.sh` stores the
exact approved bytes at `.zensu/state/autopilot-approved-plan-<sha256>.md` before it applies
`PLAN_APPROVED` on a validate-on run (`storeApprovedPlan` in `plan-payload-v1.js`: real-directory
checks, an `O_EXCL` temp at `0600`, fsync, rename, idempotent on the same digest). The name is
content-addressed, so a refused re-approval cannot replace an approved copy. A plan without an
active `AC-###` row is refused as `PLAN_CRITERIA_UNUSABLE` and the run stays at `PLANNING`; a
store that fails is `APPROVED_PLAN_STORE_FAILED`. `runChain` reads the copy through
`readApprovedPlan`, which compares the digest with `approvedPlanSha256`; a missing copy (a run
approved before this release) or a changed one is `unresolved` and names
`ZENSU_ACCEPTANCE_GATE=off` as the user's escape. A record of a run copy carries
`plan: .zensu/state/<stem>.md` (`expectedPlanRel`), and the standalone escaped-receipt path skips
run-copy stems. A work-order run reads `.zensu/plans/<order-id>.md`: when a person approved the
plan (`approvedPlanSha256` differs from `workOrder.specHash`) its digest is checked, otherwise the
verb discloses `ACCEPTANCE PLAN UNAPPROVED`. No plan gate sees a work-order plan, so
`planCriteriaRefusal` in `work-order-v1.js` takes the place of `PLAN_CRITERIA_UNUSABLE`:
`--bind-spec` of a run that validates refuses with `plan-criteria-unusable` and exit 8 while that
file carries no active `AC-###` row, reading it through the module's `planFor` and `readCriteria`,
before any stage is reported and before a person is asked to approve the plan. Without it the run
reached VALIDATE with no criterion and an `add:` remedy only the user could take. `--plan-approval`
does not repeat the check, because the protocol reaches it only after `--bind-spec` refused with
`plan-approval-required`.

**Head binding.** `runHead` requires `HEAD` of the work tree to resolve to the run's
`evidence.pr.headSha` (abbreviated heads resolve through `<head>^{commit}`) and the tree to be clean
(`hasChanges`, `.zensu` excluded), before records are read. The fingerprint is content-based, so
without this a pass recorded on an uncommitted tree that equals no commit would count. In run mode
a tree that cannot be fingerprinted refuses as `unresolved` rather than `pass-tree-unverified`.

**The whole repository, not the project root.** A run's `workspaceRoot` is the repository top, so
when the session's project root lies below it and no nested work tree is bound, run mode binds the
repository: `repositoryRoot` and `repositoryTree` in `evidence-run-v1.js` fingerprint the top with
the project root's own `.zensu` left out (the `excluded` option the external review already passes),
`runHead` checks `HEAD` and the clean tree there with the same exclusion,
`--evidence-run --scope acceptance --run` takes the same fingerprint through the transport file
`tree-mode`, and `fingerprintChanges` lists a changed path relative to the project root
(`../shared/lib.txt`). A fingerprint of the project root alone let an edit outside it, committed or
not, leave every record current. A project root that is the repository top keeps
`computeTree(projectRoot)`, so its trees do not change.

**States and exits.** A pass is `pass`; `--accept-partial` turns a verdict whose every open row is
`partial` into `partial-accepted`, a passing state, and any `fail`, `missing`, `stale` or `dropped`
row keeps it `incomplete`. The verb exits 0 after it applied `VALIDATION_PASSED`, 1 when the
acceptance verdict refused (the run stays at `VALIDATE`), and 2 for a misuse or a fault: no active
run of this session, another run, an ended run, a `--no-validate` run, a stage other than
`VALIDATE`, a run back from a fix attempt whose pushed head is not recorded yet
(`tdd.headUpdateRequired`, which `_zensu_run_bind` reads as its fifth fact; the state machine
accepts `BYPASS_RECORDED` before that guard and rejects `VALIDATION_PASSED` after it, so the verb
refuses before the module runs and before any bypass, the switched-off gate included), no PR head,
an `unavailable` verdict, an unreadable state, or an event the library rejected. `escaped` applies
`BYPASS_RECORDED {"gate":"ZENSU_ACCEPTANCE_GATE"}` first and `partial-accepted` applies
`{"gate":"acceptance-partial"}`, so the PR's `Gates bypassed during build:` line, which unions
`bypasses[].gate` from `--autopilot-status`, names it. `evidence.acceptanceGate: advisory`
discloses `(advisory, not blocking)` and validates, and the verb applies
`{"gate":"acceptance-advisory"}` first for every verdict state other than `pass`, `escaped` and
`partial-accepted`: only advisory mode lets such a state exit 0, and a run that validated with a
gap must name it in the PR. `VALIDATION_PASSED` carries the run's own durable head.

**Why the event ids carry a visit number.** A replay with the same id, type and payload exits 10
in the worker, and `_autopilot_apply_critical` answers 0, so an id derived from the head alone
would let a second VALIDATE visit at an unchanged head report success while the run stays at
`VALIDATE`. The id is `validation-passed:<visit>:<head>` (and
`validation-bypass:<gate>:<visit>:<head>`), where the visit counts the events that entered
`VALIDATE` from another stage: a retry inside one visit replays idempotently, a new visit gets a
new id.

**Coupled sites of run mode:** `runFacts`, `runChain`, `runHead`, `runOutcome`, `runVerdict`,
`runRemedies`, `isRunCopyStem`, `expectedPlanRel` and the `run.json` and `ZENSU_AVR_RUN` /
`ZENSU_AVR_ACCEPT_PARTIAL` transport in `acceptance-verify-v1.js`; `repositoryRoot`,
`repositoryTree`, the repository branch of `fingerprintChanges` and the `tree-mode` transport in
`evidence-run-v1.js`; `_zensu_run_bind`, `_zensu_active_run_json`, the `--run` arms, the
`tree-mode` write and the `--autopilot-validate` arm in `zensu-log.sh`;
the store, the two refusal codes and their `causes` in `plan-approved-delegate.sh`;
`APPROVED_PLAN_PREFIX`, `approvedPlanRelPath`, `readApprovedPlan` and `storeApprovedPlan` in
`plan-payload-v1.js`; the `## Requirements` table of `templates/autopilot-spec.md`; step 6 of
`skills/autopilot/SKILL.md` and `skills/autopilot/rules/validate.md`; the `VALIDATE_FEATURE` line of
`hooks/session-start-autopilot-resume.sh`; `planCriteriaRefusal` in `work-order-v1.js` and the
`plan-criteria-unusable` paragraph of `skills/autopilot/rules/work-order.md` §4. Pins: `V1`-`V15`
and `V7b` in `test-acceptance-gate.sh` (`V7b` the ended run, `V10` the advisory ledger entry,
`V15` the pending head update and a third visit's event ids), the run cases of
`acceptance-verify-v1.test.js`, the repository-tree case of `evidence-run-v1.test.js`,
`P17`-`P17i` in `test-autopilot-plan-delegate.sh`, `F47b` in `test-plan-payload-fallback.sh`,
`C13a` in `test-autopilot-chain-integration.sh`, `I6b`, `I9a` and `I9b` in
`test-work-order-implement.sh`, and `G7` in `test-work-order-gates.sh`, whose plan carries the
table before its first `--bind-spec`.

**Version of run mode: `minor`.** A session still holding the earlier skill text sends
`VALIDATION_PASSED` through `--autopilot-event`, which this release refuses, and a record's `plan`
gains the `.zensu/state/` value form that an earlier root's `validateRecord` reads as malformed. No
workflow-state field, run key or event type changes.

**Known gaps of run mode:** `browser`, `mobile` and `desktop` verdicts stay attested; an observed
run proves its command's exit code, not that the command checks the criterion; `.zensu/state/`,
the run record and the plugin store are writable from the session, and a direct library call
skips the CLI refusal, so this bounds accidents, not intent; every commit after validation,
`--cover` included, makes every record stale; records are per session key, so a new owner after
`/zensu:autopilot-adopt` verifies again; a run in flight across this release has no stored copy and
needs the user's escape; `--accept-partial` is available to the model, and what keeps it honest is
the 🟡 row, the evidence and the ledger entry; a work-order plan the order timeline names under
another path than `.zensu/plans/<order-id>.md` refuses as changed; and the run record travels to
the bind's node child on stdin, while `_zensu_chain_work_tree` still hands it over in an
environment variable, which a record near the 512-event bound can push past Linux's 128 KiB limit
for one variable. Windows is unmeasured.

**Coupled sites:** `ZENSU_BYPASS_GATE_ALLOWLIST` and `tdd_bypass_recorded` in
`zensu-tdd-phase.sh`; both protected-root lists in `reviewer-capability-v1.js`;
`zensu_evidence_acceptance_gate` in `zensu-config.sh`; `SCOPES`/`TREE_SCOPES` and per-scope
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
