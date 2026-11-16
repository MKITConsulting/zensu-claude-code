---
paths:
  - "hooks/lib/acceptance-verify-v1.js"
  - "hooks/lib/approved-plan-v1.js"
  - "hooks/plan-approved-delegate.sh"
  - "hooks/lib/zensu-log.sh"
  - "hooks/stop-chain-enforcer.sh"
  - "hooks/post-review-tdd-delegate.sh"
  - "hooks/lib/edit-landing-receipt-v1.js"
  - "hooks/lib/zensu-plan-requirements.sh"
  - "tests/structure/acceptance-verify-v1.test.js"
  - "tests/structure/test-acceptance-gate.sh"
  - "tests/structure/approved-plan-v1.test.js"
  - "skills/autopilot/rules/validate.md"
  - "skills/verify-feature/SKILL.md"
  - "skills/self-review/SKILL.md"
  - "skills/self-review/references/acceptance.md"
  - "skills/verify-feature/rules/acceptance-consent.md"
  - "skills/build/references/audit.md"
  - "hooks/session-start-autopilot-resume.sh"
  - "tests/structure/test-requirements-table-gate.sh"
  - "tests/structure/test-escape-wording.sh"
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

**One id, one criterion.** A second active row with an id already listed is a `duplicate`
(`listedRows` in `approved-plan-v1.js` collects it beside the rows), because two criteria under one
id would let one record answer for both. `readCriteria` answers `duplicate`, which the terminus and
run mode read as `unresolved`, `planCriteria` refuses it at `--tdd-complete` (advisory under an
advisory gate), the plan-approval hook refuses it as `PLAN_CRITERIA_UNUSABLE` (`listPlanCriteria`
detail `duplicate-<ids>`), and `--bind-spec` as `plan-criteria-unusable`. A deprecated row and an
active row of one id keep the active one and are no duplicate, so a dropped requirement's row can
stay in place beside the row that replaced it.

**The `## Manual Acceptance` table has the same parser.** `--list --manual-acceptance` runs the
same awk program over the `## Manual Acceptance` section instead of `## Requirements`: the same
heading and fence rules, the same id-cell reduction (emphasis, a code span, a link wrapper, a comma
list), every table in the section, and the state judged on the second visible cell, the check a
person runs. `listManualAcceptanceIds` in `approved-plan-v1.js` keeps the active `AC-###` ids and
ignores a repeated one, and `manualAcceptanceRead` in the module runs it on the bytes the gate
already holds. One rule is this mode's own: a tilde in the id cell marks the row `deprecated`,
because a struck-out consent row reads as withdrawn, while in `## Requirements` a strike mark stays
decoration and the row is verified. Both directions keep the safe side: a struck-out criterion is
still checked, and a struck-out consent covers nothing. A check cell that is still a `{…}`
placeholder carries no consent either. A plan whose fence never closes, or a lister that cannot
run, reads as a table that could not be read, which refuses `--accept-partial` with the lister's
cause and in run mode turns `accept:` into `consent:`.

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
browser follows `/zensu:verify-feature`'s credential-blind rules: it signs in only through the
run-config helper's `--login-recipe` (`.claude/rules/verify-auth-guard.md`) or visibly, never
through the autopilot catalog's own `storageState` loading (`skills/autopilot/rules/drivers.md`).

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
`/zensu:verify-feature --chain --log <run log>` command for a `missing` or `stale` criterion and
for `invalid` (`VERIFY_AGAIN_STATES`, in both modes: a `partial` criterion is one this
environment cannot observe, so driving it again changes nothing); `fix:` for a criterion that
fails on the current tree; `add:` for `no-criteria`; `restore:` for a dropped criterion; `accept:`
when every criterion that does not pass is `partial`, naming the ids, the user's consent with the
file that owns its two sources, and the `## Manual Acceptance` row (§"Standalone consent"), or in
its place `review:` on a minted `zc_` self-review ticket and `tree:` on a tree the gate cannot
fingerprint, because consent binds to neither (`partialRemedy`). `REMEDY_TEXTS` holds the wording
of both modes, so one skeleton builds every segment; run mode words `accept:` only when the
approved plan's `## Manual Acceptance` table lists every partial id, and `consent:` otherwise
(§"Autopilot run mode"). No segment names an escape. `unresolved` names its remedy in its cause, `unavailable` names none.
Every consumer acts on the segment: `/zensu:self-review`, the self-review-off `CLOSE_PASS` and
verify-feature chain mode re-verify only after `run:`, because verifying an unchanged tree again
cannot turn a `fail`, and a re-verify loop runs to the Stop cap. `partial` left `run:` because
the same environment observes it the same way again; only access the user provides, or the
user's consent, changes it.

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

## Standalone consent (`--accept-partial`), the Stop hand-off and the criteria check

Agents kept closing chains by asking the user to set `ZENSU_ACCEPTANCE_GATE=off`, and marked that
option recommended, because the plugin offered nothing between "every criterion passes" and
switching the gate off: `partial` (credentials, an account, a non-loopback host, a signed build, a
delivery fact) blocked like `fail`, its only remedy was `run:`, the remedies and the skills named
the escape as the hand-off, and a refused terminus kept the Stop blocked until the cap. User
decision (2026-11-10): such a chain closes only with the user's consent for the named criteria.

**The consented close.** `--chain-done --claimed-review-ticket <t> --accept-partial <ids>` on the
ticket-bound standalone terminus. `zensu-log.sh` validates the list through the module's
`accept-ids` mode (`parseAcceptIds`, `AC_RE`, comma list, deduplicated and sorted; exit 2 on a
malformed or empty list) and refuses with exit 1 on the zero-change terminus, with Autopilot
binding arguments and with `--outcome`, before any gate runs; `--accept-partial` without a value,
or followed by another flag, and a second `--accept-partial` exit 2 on every verb,
`--autopilot-validate` included. `standaloneVerdict` turns the verdict into `partial-accepted`
only when `consentDecision` finds, through `acceptOpenRows`, the listed ids EQUAL to the open rows
(active, not `pass`) and every one `partial` on a tree the gate can fingerprint, and finds a row
for each id in the plan's `## Manual Acceptance` table (`manualAcceptanceIds`, read through the
lister as §"One row parser" describes); otherwise it stays `incomplete` and the cause names the
difference (`covers only partial criteria, not …`, `names …, which is not open`, `leaves … open`,
`which has no row for …`, `that table could not be read (…)`). Exact-set matching is the point: consent never covers a criterion the
user was not shown. `standaloneVerdict` also refuses the ids on a minted `zc_`
self-review ticket by itself (`ZENSU_AVR_ZERO_CHANGE_TICKET`), so that rule does not rest on the
shell's refusal alone. A `partial-accepted` close prints one
`ACCEPTANCE — accepted as partial: …` line per criterion with its evidence and records
`acceptance-partial` in the session bypass ledger right after every terminus gate passed and
before the converged transition, because the ledger writer needs an active chain. The write goes
through `tdd_add_bypass` and is confirmed with `tdd_bypass_recorded`: a consent the ledger did not
take, or ids given while the verdict state did not reach the terminus, refuses with exit 1 before
the transition, so the chain stays open and the same call records the consent on a retry.
`acceptance-partial` joined `ZENSU_BYPASS_GATE_ALLOWLIST` (shape-legal; an earlier installation's
writer and reader filter it out rather than fail); it renders 🟡 alone and every escape 🔴
(`status-marker-legend.md`), and `--bypass-note` refuses it, so only the terminus writes it to
the session ledger, while `--autopilot-validate` writes it to the run's `bypasses` list. Run mode
takes the same exact id list, and its consent is the approved plan's `## Manual Acceptance` table
(§"Autopilot run mode").

**Where consent comes from.** `skills/verify-feature/rules/acceptance-consent.md` is the one owner
of what `partial` means (a criterion this environment cannot observe; one it could observe but did
not prove is verified again, or recorded `fail`), of the two sources of consent, of the ONE question
with its option order (provide access now, accept as partial, leave the chain open) and of the
`## Manual Acceptance` row. The sources are a row of the plan's optional `## Manual Acceptance`
table (`templates/zensu-plan.md`), filled at planning (Phase 1.5 "Acceptance observability" in
`skills/build/references/planning.md`) or when a gap is found, whose reason names the same cause
category as the `partial` record, and the user's answer to that question. `/zensu:build` step 6d,
`/zensu:verify-feature --chain`, `/zensu:self-review` (`references/acceptance.md`) and the
self-review-off `ACCEPTANCE_REVERIFY` directive name that file instead of restating it; step 6d, the
self-review reference and the directive still say never to offer, set or mention a way to switch
the gate off. The gate reads the table's ids, never a row's reason or the answer itself: a listed
id without a row refuses with a remedy that asks for the row, so an answer counts once its row is
written.

**The hand-off.** Without a record the Stop enforcer cannot tell "waiting on the user" from
"stalled", so a refused standalone terminus writes one. `isHandoff` answers true for an `incomplete` or
`no-criteria` verdict whose every segment is a user remedy (`USER_REMEDIES`: `accept`, `add`,
`restore`) or a `fix:` once the shell reports the fix round spent (`ZENSU_AVR_FIX_ROUND_SPENT`:
`tdd_self_review_fixed`, or `hooks.selfReview` off, because then no fix round follows the review);
`run:`, `review:`, `tree:`,
`unresolved` and `unavailable` never hand off, and neither does a verdict on a minted `zc_` ticket
(`ZENSU_AVR_ZERO_CHANGE_TICKET`) or under an advisory gate. `recordHandoff` writes
`$CLAUDE_PLUGIN_DATA/acceptance-handoff/v1/<session key>.json` (`HANDOFF_KEYS`, an exact key set,
temp then rename at `0600`) only when the shell passed the review ticket, the edit-landing and
full-suite gates passed, the review converged (`ZENSU_AVR_REVIEW_DONE`), the tree has a
fingerprint and the chain resolved, and removes it on every
other answer of the same call, a pass included. Beside the ticket and the tree the record binds the
plan (`plan` under `HANDOFF_PLAN_RE`, `plan_sha256` from `planDigest`, which reads it through
`readPlanFile` of `plan-payload-v1.js`, that module's size bound and link checks included) and
the chain's acceptance records (`records_sha256` from
`recordSetDigest`), so a plan edit or a new record, neither of which moves the tree fingerprint,
ends the hand-off; every remedy is at most `LIMITS.maxRemedyChars`. A sidecar, not a workflow-state
field, so no schema moved; the store is in both protected-root lists of
`reviewer-capability-v1.js`. `acceptance_handoff_release` in `hooks/stop-chain-enforcer.sh` runs
after the background-task wait for a standalone chain: no owned Autopilot run, no bound chain, no
adopted deferred review and no `pending-review.json.claim` in the project. While `hooks.selfReview`
is on it also requires `--code-review-done`, the mark the shell reads through `tdd_code_review_done`
for `ZENSU_AVR_REVIEW_DONE`: a terminus refused before the review converged is a stage of the chain,
not a wait on the user, so it neither writes nor honours a hand-off. With `hooks.selfReview` off the
closing directive runs the terminus without that mark, so the shell reports the review done and the
Stop guard skips the check. It hands the module the recorded project root raw, the spelling the terminus binds the
records to, because `validateRecord` compares roots exactly and a `zensu-host-path.sh` rendering
(`C:/…` under Git Bash) would make every record read as invalid. It spawns
`node` only when the file exists, and `handoffStatus` releases only for the current ticket, tree,
plan bytes and record set; the release goes through `stop_notice`, charges no Stop budget and
renders the bypass ledger, as every release path must. Any mismatch falls through to the ordinary
block. `handoffLine` screens every remedy through the evidence runner's display screen.
`--chain-status` prints the same line on stderr, so its stdout stays one JSON document.
`tdd_review_gate_reset` removes the file at every review-generation restart (`--tdd-begin`,
`--review-rearm`, a reopened `zc_` terminus, a deferred-review seed), and a failed transport
preparation removes it too. Before the terminus a report never releases the guard; this record is
the one release, and only a refused terminus writes it.

**The criteria check at `--tdd-complete`.** Without it `no-criteria` would surface only at the
terminus, after the review. `_zensu_plan_criteria_gate` runs the module's `plan-criteria` mode
(`planCriteria`, which reads criteria through `readCriteria` like the gate) inside the
requirements-table gate's usable-table arm, for a standalone chain only (`complete_ctx` `{}`):
an Autopilot plan approval already refuses `PLAN_CRITERIA_UNUSABLE`. It shares that gate's scope
and switch and follows the acceptance gate's own mode: `ZENSU_ACCEPTANCE_GATE=off` skips it, and
`evidence.acceptanceGate: advisory` completes with `ACCEPTANCE CRITERIA — advisory, not blocking`
on stderr (`ZENSU_AVR_CRITERIA_ADVISORY`). Under `advisory` a check that cannot run (no `node`, an
unresolvable module, a module fault) or cannot read the plan completes as well, with the same
prefix naming what was not judged: `unjudgedCriteria` words the read faults in the module, and
`_zensu_plan_criteria_unjudged` the faults the module cannot report. Under `required` each refuses
with `…, so the plan was NOT judged.` Its wording is the module's; the remedy asks for one
`AC-###` row per criterion and prefers criteria this environment can observe.

**Escape-free texts.** No refusal, remedy, hand-off or skill text on the chain-closing path names
`ZENSU_*_GATE`, `ZENSU_CHAIN`, `ZENSU_SECRET_SCAN` or an `evidence.*Gate` value as an option or a
prohibition. `tests/structure/test-escape-wording.sh` scans its file list (message literals in
shell and JS, every line in Markdown) against a disclosure allowlist: the `escaped` lines, the
`STEM UNCHECKED` lines, the `unresolved` cause naming a used edit-landing escape and the
unrecognized-value notice, all printed only after the user set the value. Operator-facing Stop
notices (`stop_notice`) and the gates outside the chain (`pre-bash-zensu-gate.sh`,
`pre-edit-tdd-reminder.sh`, the `ZENSU_TDD_GATE=off` sentence of Principle 3 in
`skills/build/SKILL.md`, `pre-bash-source-write-gate.sh`) are outside its list; widening it is the
follow-up.

**Coupled sites of this section:** `VERIFY_AGAIN_STATES`, `USER_REMEDIES`, `REMEDY_TEXTS`,
`HANDOFF_*`, `LIMITS.maxRemedyChars`, `remedies`, `partialRemedy`, `isHandoff`,
`parseAcceptIds`, `acceptOpenRows`, `consentDecision`, `manualAcceptanceIds`,
`manualAcceptanceRead`, `chainPlanBytes`, `planDigest`, `recordSetDigest`,
`handoffEvidence`, `recordHandoff`, `handoffStatus`, `handoffLine`, `planCriteria`,
`unjudgedCriteria` and the `accept-ids`, `handoff` and `plan-criteria` modes in
`acceptance-verify-v1.js`; the `--accept-partial` parse and refusals, `_zensu_accept_partial_ids`,
`_zensu_plan_criteria_gate`, `_zensu_plan_criteria_unjudged`, `_zensu_acceptance_handoff_line`, the
`ZENSU_AVR_ACCEPT_PARTIAL_IDS`, `_HANDOFF_TICKET`, `_GATES_PASSED`, `_FIX_ROUND_SPENT`,
`_REVIEW_DONE`, `_ZERO_CHANGE_TICKET`, `_CRITERIA_ADVISORY` and `_PLAN` transport, the confirmed
ledger write and the `--bypass-note` refusal in `zensu-log.sh`;
`zensu_acceptance_handoff_file` / `_reset`, the reset in `tdd_review_gate_reset` and the allowlist
in `zensu-tdd-phase.sh`; the `acceptance-handoff` entries of both protected-root lists in
`reviewer-capability-v1.js`;
`acceptance_handoff_release` in `hooks/stop-chain-enforcer.sh`; `CONSENT_RULE`,
`ACCEPTANCE_REVERIFY` and the summary rules of `COMBINED_SUMMARY_DIRECTIVE` in
`hooks/post-review-tdd-delegate.sh`;
`skills/self-review/SKILL.md` and `references/acceptance.md`; step 6d of `audit.md` and Phase 1.5
of `planning.md`; chain mode points 5 and 6 of `skills/verify-feature/SKILL.md` and
`rules/acceptance-consent.md`; §3 of `skills/autopilot/rules/validate.md`;
`templates/zensu-plan.md`; `docs/gates.md`, `docs/configuration.md`, `docs/build-workflow.md` and
`docs/verify-feature.md`. Pins: the consent, hand-off, segment and plan-criteria cases of
`acceptance-verify-v1.test.js`; `A0e`–`A0j` and `C1`–`C21` with `C7b` in
`test-acceptance-gate.sh`; `AC1`–`AC8` in `test-requirements-table-gate.sh`; `W0`–`W7` in
`test-escape-wording.sh`, whose quoted-name exemption admits only a whole code token, which judges
a heredoc body and a template literal's continuation line as prose rather than skipping a line
that starts with a comment marker there (`W3`, `W4`), and whose `W7` holds every remedy prefix the
run-mode `remedies` emits equal to the arms of `skills/autopilot/rules/validate.md` §3; and the
hand-off record read denials of `test-reviewer-capability-gate.sh`, which write a real record and
deny a reviewer, a neutral child and the PLM a `Read` of it.

**Version: `minor`.** A standalone `--tdd-complete` now refuses a plan the previous release
completed; the hook directives and the skills name `--chain-done --accept-partial`, which the
previous release's `zensu-log.sh` refuses as an unknown argument; and the bypass ledger's
allowlist gained a value the previous release's reader drops from its `Gates bypassed` line. No
workflow-state field and no released strict key set moved; the sidecar is a new private store
whose `HANDOFF_KEYS` no released reader knows.

**Known gaps of this section:**

- **Consent is model-relayed.** The gate cannot tell a consent the user gave from one the model
  invents, the same bound as every attested verdict; what keeps it honest is the exact-set rule,
  the 🟡 row, the `## Manual Acceptance` row and the ledger entry.
- **The hand-off is a session-writable file in plugin data**, bounded by its ticket, tree, plan and
  record-set checks; a forged one releases Stops only for the current ticket and tree, like a
  refused terminus would.
- **The claim exclusion is project-wide.** Another session's `pending-review.json.claim` in the
  same project keeps this session's waiting chain blocked until that claim is released, the same
  exclusion the background waits make (`.claude/rules/stop-background-wait.md`).
- **A bound chain never hands off**, by design, and the live check in a host session that answers
  the consent question was not run (the PR body lists it as a manual check).
- Windows is unmeasured, as for the rest of this gate.

## Autopilot run mode (`--run <id>` and `--autopilot-validate`)

A `VALIDATION_PASSED` event carries only a head, so whoever may send it decides whether a run
validated. The stage therefore passes only through
`zensu-log.sh --autopilot-validate --run <id> [--accept-partial <ids>]`, which applies the event
itself, and `--autopilot-event` refuses `VALIDATION_PASSED` and the two event-id namespaces the verb uses
(`validation-passed:`, `validation-bypass:`), the way `release-` is reserved. It refuses
`PLAN_APPROVED` too, which only the plan-approval hook records, when the user approves the plan (on a
run that validates it first stores the plan and checks its criteria), and the `plan-approved-` event-id namespace that hook writes, whatever the event type.
`VALIDATION_FAILED` stays free, because failing unlocks nothing.

**The run bind.** `_zensu_run_bind` in `zensu-log.sh` serves `--acceptance-record --run`,
`--acceptance-status --run`, `--evidence-run --scope acceptance --run` and the verb. It reads the
caller's own run through `autopilot_read_active_strict` inside a command substitution, so the state
library never loads into the verb's process (the evidence runner's E22/E23 rule), requires the
named id to be that run and the run to be nonterminal, and maps the strict read's 1 to "owns no
active run" and its 5 to the unreadable-state refusal; those two, another run's id and an ended run
all exit 2, like every misuse. It reads the run's facts through the module's `run-facts` mode,
which takes a recorded pull-request head only within the 7 to 64 hex digits of
`RECORDED_HEAD_RE`, so the shell carries no second parser of the run record; `V16` checks that the
state machine's `sha` agrees with that bound. The bind and the `--accept-partial` parse run before
the phase library is loaded, so both name the module through `_zensu_avr_module_path`, which
renders the plugin's `hooks/lib` with `zensu-host-path.sh` as `--evidence-run` does, never through
`_tdd_native_path`: the suite sources that library and exports its functions to every child, which
hid the missing function from every check but `V21` and `I9a`. `--run` and `--log` exclude each other, and
`--evidence-run --run` takes `--scope acceptance` only. The run record reaches the module as the
transport file `run.json`; the work tree comes from `{"runId":"<id>"}` handed to
`_zensu_bound_work_tree` as the given context, so a run whose `workspaceRoot` is a worktree below
the anchor binds the combined tree even though no chain is open at VALIDATE.

**The criteria come from the plan the user approved.** `hooks/plan-approved-delegate.sh` stores the
exact approved bytes at `.zensu/state/autopilot-approved-plan-<sha256>.md` before it applies
`PLAN_APPROVED` on a validate-on run (`storeApprovedPlan` in `approved-plan-v1.js`, a built-ins-only
module that requires `plan-payload-v1.js` for `readPlanFile`: real-directory checks, an `O_EXCL`
temp at `0600`, fsync, rename, idempotent on the same digest). The hook loads it behind
`plan_module_loadable`, and a plugin without it, or without the requirements lister, refuses as a
runtime fault before anything is stored. The name is
content-addressed, so a refused re-approval cannot replace an approved copy. A plan without an
active `AC-###` row is refused as `PLAN_CRITERIA_UNUSABLE` and the run stays at `PLANNING`; a
store that fails is `APPROVED_PLAN_STORE_FAILED`. The hook lists the criteria through
`listPlanCriteria` in `approved-plan-v1.js`, which runs the lister on a private temporary copy of the
bytes the store verified, never on the stored copy by path, and maps the lister's exit by number
(`PLAN_CRITERIA_CONTENT_EXITS`): 0, 3, 4 and 5 are verdicts about the plan, 5 being a plan whose code
fence never closes, so a plan without an active row is `PLAN_CRITERIA_UNUSABLE`, while any other exit,
a signal or a lister that cannot run is `PLAN_CRITERIA_UNREADABLE`, whose receipt names the lister's
answer; both criteria refusals remove the stored copy. The store answers with its own codes only
(`APPROVED_PLAN_FAILURES`), a linked, empty, oversized or unreadable copy included. `runChain` reads the
copy through `readApprovedPlan`, which compares the digest with `approvedPlanSha256`, and carries
the bytes it verified as `planBytes`, which `chainCriteria` hands to `readCriteria`: the lister
parses a private temporary copy of them, so `record`, `status` and the verdict judge the bytes
whose digest was checked, never a second read of the file, and a person-approved work-order plan
travels the same way; a missing copy (a run
approved before this release) or a changed one is `unresolved`, and the refusal reports the
cause and leaves the decision to the user without naming the escape (§"Standalone consent"). A record of a run copy carries
`plan: .zensu/state/<stem>.md` (`expectedPlanRel`), and the standalone escaped-receipt path skips
run-copy stems. A work-order run reads `.zensu/plans/<order-id>.md`: when a person approved the
plan (`approvedPlanSha256` differs from `workOrder.specHash`) its digest is checked, otherwise the
verb discloses `ACCEPTANCE PLAN UNAPPROVED`. No plan gate sees a work-order plan, so
`planCriteriaRefusal` in `work-order-v1.js` takes the place of `PLAN_CRITERIA_UNUSABLE`:
`--bind-spec` of a run that validates refuses with `plan-criteria-unusable` and exit 8 while that
file carries no active `AC-###` row, reading it through the module's `planFor` and `readCriteria`,
before any stage is reported and before a person is asked to approve the plan. A lister that cannot
judge the file refuses with `plan-criteria-unreadable` instead, whose remedy leaves the plan alone
and names `/zensu:doctor`. A plan that does not parse keeps `plan-criteria-unusable` with a remedy
of its own, to close the open code fence, and both refusals name the plan project-relative, never by
the absolute path the lister prints. Without it the run
reached VALIDATE with no criterion and an `add:` remedy only the user could take. `--plan-approval`
does not repeat the check, because the protocol reaches it only after `--bind-spec` refused with
`plan-approval-required`.

**Head binding.** `runHead` requires `HEAD` of the work tree to be the run's `evidence.pr.headSha`
and the tree to be clean (`hasChanges`, `.zensu` excluded), before records are read.
`runHeadCheck` runs it for the verdict, for `--acceptance-status --run` and for
`--acceptance-record --run`, which refuse with exit 1 and the same cause, the record before it
writes anything, so a criterion is never driven and recorded on a tree no record of which can
count. The verdict runs it before the escape and before the gate mode is read: a cause that names
the head or a dirty tree is `blocking`, which neither `ZENSU_ACCEPTANCE_GATE=off` nor the advisory
gate lifts, while the plan copy is read after the escape. A full-length
head is compared directly. An abbreviated one goes through `prCommit`: `git rev-parse
--disambiguate=<prefix>` lists objects and never ref names, and `git cat-file --batch-check` keeps
the commits among them. `rev-parse <prefix>^{commit}` resolves a branch or tag of the same name
before the object, so a branch named after the abbreviation made its tip pass as the pull-request
head (measured, `V17`). An abbreviation several commits begin with, or more than
`LIMITS.headCandidates` objects, refuses with its own cause, which tells the run to block, because
no checkout settles it, and so does a `--disambiguate` or `cat-file` call that fails. The dirty-tree refusal keeps its prefix, names the first
`LIMITS.listedChanges` changed paths, counts the rest, and sends a change that belongs to the change
through the fix loop and a check's leftovers to removal. It and the stale list share `pathList`:
both name a path relative to the project root, end in ` and N more` or ` and more`, and escape a
`|` in a file name as `\|`, so a file name cannot add a remedy segment. The fingerprint is content-based, so
without this a pass recorded on an uncommitted tree that equals no commit would count. In run mode
a tree that cannot be fingerprinted refuses as `unresolved` rather than `pass-tree-unverified`, and
`--acceptance-status --run` and `--acceptance-record --run` refuse it with exit 1 and the same cause
(`unfingerprintedCause`), the record before it writes anything. A
cited evidence run that changed the tree is refused with a remedy that names the tree its record
binds to, the project, the project and its work tree, or the repository (the `name` that
`chainTree` returns).

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

**States and exits.** A pass is `pass`; `--accept-partial <ids>` turns a verdict whose open rows
are exactly the listed ids, every one `partial`, into `partial-accepted`, a passing state, only
when `consentDecision` finds each id in the `## Manual Acceptance` table of the bytes whose digest
was checked; any `fail`, `missing`, `stale` or `dropped` row, an id the table lacks, and a
work-order plan no person approved keep it `incomplete`. User decision (2026-11-15): with no
person present, the only consent VALIDATE may apply is one the user gave by approving the plan,
so an agent never accepts a gap on its own. `runRemedyContext` hands `remedies` the table's ids,
the table's read fault and the approval, so a refusal over partial rows ends with `accept:` and
the command when the table lists each id, and with `consent:` otherwise (an id the table lacks, a
table that could not be read, a work-order plan no person approved), whose text tells the run to
block. The gate reads only the ids: `accept:` itself says the command holds only when each row's
reason names the same cause category as the criterion's `partial` record, and to block otherwise,
because no person is there to answer the one question. The run-mode `run:` segment names
`--acceptance-record --run <id>` for the criteria that are missing, stale or carry an invalid
record. The verb exits 0 after it applied `VALIDATION_PASSED`, 1 when the
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
`partial-accepted`, and only when the verdict reports the advisory gate (`verdict-mode`): any
other passing state under a required gate refuses with exit 2 and tells the run to block, because
it validates no run, and an empty `verdict-state` read-back refuses with exit 2 too. A run that
validated with a gap must name it in the PR. A work-order run whose plan no person approved also
gets `{"gate":"acceptance-plan-unapproved"}` (`verdict-plan-unapproved`) when it validates,
whatever else it records, except under the switched-off gate, which reads no plan. The fact comes
from the run record (`approvedPlanSha256` equal to `workOrder.specHash`), so it also holds when the
plan file is missing and the verdict is `unresolved` under an advisory gate. The module writes
`verdict-plan-unapproved` as `0` or `1` on every verdict, after `verdict-state` and `verdict-mode`,
and the verb reads anything else, an absent file included, as a verdict it could not read back and
refuses with exit 2; writing the flag last keeps a lost write from validating a run without its
ledger entry. `VALIDATION_PASSED` carries the
run's own durable head.

**Resume.** `hooks/session-start-autopilot-resume.sh` reads the copy of an active validate-on run
without a work-order binding through `readApprovedPlan`, required from the plugin's own `hooks/lib`
and never from the project, and when it is missing or no longer matches appends
`ZENSU_AUTOPILOT_RESUME APPROVED_PLAN_COPY_UNAVAILABLE runId=… copy=… reason=…` to its active-run
line, with a reason from `APPROVED_PLAN_FAILURES`, so the user hears of it at the next session
start rather than at VALIDATE. A module that does not load adds nothing.

**Why the event ids carry a visit number.** A replay with the same id, type and payload exits 10
in the worker, and `_autopilot_apply_critical` answers 0, so an id derived from the head alone
would let a second VALIDATE visit at an unchanged head report success while the run stays at
`VALIDATE`. The id is `validation-passed:<visit>:<head>` (and
`validation-bypass:<gate>:<visit>:<head>`), where the visit counts the events that entered
`VALIDATE` from another stage: a retry inside one visit replays idempotently, a new visit gets a
new id.

**Coupled sites of run mode:** `runFacts`, `runChain`, `runHead`, `runHeadCheck`, `prCommit`,
`gitLines`, `changeList`, `pathList`, `chainCriteria`, `unfingerprintedCause`, `runOutcome`,
`runVerdict`, `runRemedyContext`, the `run` texts of `REMEDY_TEXTS`, `consentDecision`,
`manualAcceptanceIds`, `manualAcceptanceRead`, `isRunCopyStem` (which also requires `approvedPlanStem` to rebuild the stem),
`expectedPlanRel`, the `name` and `outside` that `chainTree` returns, `LIMITS.listedChanges`,
`LIMITS.headCandidates`, the `run.json` and `ZENSU_AVR_RUN` / `ZENSU_AVR_ACCEPT_PARTIAL_IDS`
transport and the `verdict-mode` and `verdict-plan-unapproved` files in
`acceptance-verify-v1.js`; `repositoryRoot`,
`repositoryTree`, the repository branch of `fingerprintChanges` and the `tree-mode` transport in
`evidence-run-v1.js`; `_zensu_run_bind`, `_zensu_active_run_json`, `_zensu_avr_module_path`, the `--run` arms, the
`tree-mode` write and the `--autopilot-validate` arm in `zensu-log.sh`;
the store, the three refusal codes and their `causes` and the lister exit mapping in
`plan-approved-delegate.sh`; `APPROVED_PLAN_PREFIX`, `APPROVED_PLAN_FAILURES`, `approvedPlanStem`,
`approvedPlanRelPath`, `readApprovedPlan`, `storeApprovedPlan` and its `syncDirectory`, which
fsyncs the state directory after the rename on every host but win32, in `approved-plan-v1.js`; the
`PLAN_APPROVED` and `plan-approved-` refusals of `--autopilot-event` in `zensu-log.sh`; the
`## Requirements` table and the optional `## Manual Acceptance` section of
`templates/autopilot-spec.md`; step 6 of `skills/autopilot/SKILL.md`,
`skills/autopilot/rules/validate.md` and the `partial` sentence of `skills/autopilot/rules/drivers.md`;
the `VALIDATE_FEATURE` line and `planCopyNote` of `hooks/session-start-autopilot-resume.sh`;
`planCriteriaRefusal` in `work-order-v1.js` and the `plan-criteria-unusable` paragraph of
`skills/autopilot/rules/work-order.md` §4. Pins: `V1`-`V21`, `V7b`, `V13b` and `V20b` in
`test-acceptance-gate.sh` (`V7b` the ended run, `V10` the advisory ledger entry, `V13b` a run of
another session in the same project, `V15` the pending head update and a third visit's event ids,
`V16` the head bound, `V17` a branch named after an abbreviated head, `V18` an unexpected passing
state under a required gate, `V19` a copy the plan-approval hook itself stored, validated through
the records and the verb, and a tracked `.zensu/logs/` change that leaves the tree clean, and `V20`
a work-order plan no person approved, whose validation records `acceptance-plan-unapproved` before
`VALIDATION_PASSED`, `V20b` a lost `verdict-plan-unapproved` write on that run, which the verb
refuses with exit 2 before it records anything, and `V21` every run verb and
`--autopilot-validate --accept-partial` in a shell
that inherits no exported function), `R8e` and `R8f` in `test-autopilot-session-resume.sh` (the resume line for a
missing copy; no line for a run that does not validate, and the line for a tampered copy), the run
cases of
`acceptance-verify-v1.test.js` (the shadow branch, two crafted commits that share a 7-digit prefix,
the dirty-path list, the unfingerprinted status, a copy swapped after the verified read, the named
trees, the overlong head, the head remedies and the tracked `.zensu` twin of `V19` among them),
`approved-plan-v1.test.js` through `F11f` and its directory-sync case, `F47c` to `F47e` in `test-plan-payload-fallback.sh`,
`C13b` in `test-autopilot-chain-integration.sh`, `I6` in `test-work-order-implement.sh`, which
drives the state library because the CLI refuses `PLAN_APPROVED`, the repository-tree case of `evidence-run-v1.test.js`,
`P17`-`P17i` in `test-autopilot-plan-delegate.sh`, `F47b` in `test-plan-payload-fallback.sh`,
`C13a` in `test-autopilot-chain-integration.sh`, `I6b`, `I9a` and `I9b` in
`test-work-order-implement.sh`, and `G7` in `test-work-order-gates.sh`, whose plan carries the
table before its first `--bind-spec`.

**Version of run mode: `minor`.** A session still holding the earlier skill text sends
`VALIDATION_PASSED` through `--autopilot-event`, which this release refuses, and a record's `plan`
gains the `.zensu/state/` value form that an earlier root's `validateRecord` reads as malformed. No
workflow-state field, run key or event type changes. Refusing `PLAN_APPROVED` and the
`plan-approved-` namespace narrows what `--autopilot-event` accepts, which is `minor` on its own,
and ships in the same release.

**Known gaps of run mode:** `browser`, `mobile` and `desktop` verdicts stay attested; an observed
run proves its command's exit code, not that the command checks the criterion; `.zensu/state/`,
the run record and the plugin store are writable from the session, and a direct library call
skips the CLI refusal, so this bounds accidents, not intent; every commit after validation,
`--cover` included, makes every record stale; records are per session key, so a new owner after
`/zensu:autopilot-adopt` verifies again; a run in flight across this release has no stored copy,
which the resume line names, and needs the user's escape; the `## Manual Acceptance` table that
carries consent is model-written plan text the user approved, so its consent is only as careful as
that approval, while the 🟡 row, the evidence and the ledger entry keep the gap visible; a work-order plan the order timeline names under
another path than `.zensu/plans/<order-id>.md` refuses as changed; and the run record travels to
the bind's node child on stdin, while `_zensu_chain_work_tree` still hands it over in an
environment variable, which a record near the 512-event bound can push past Linux's 128 KiB limit
for one variable; and the `plan-criteria-unreadable` refusal of `--bind-spec`, a lister that cannot
judge a work-order plan, is driven only by the validating bind-spec case of `work-order-v1.test.js`
through a patched `readCriteria`, never by a real lister fault. Windows is unmeasured.

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
