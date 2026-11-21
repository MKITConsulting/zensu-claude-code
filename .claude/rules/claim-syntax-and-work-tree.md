---
paths:
  - "hooks/lib/edit-landing-claims-v1.js"
  - "hooks/lib/edit-landing-receipt-v1.js"
  - "hooks/lib/zensu-edit-landing.sh"
  - "hooks/lib/zensu-log.sh"
  - "hooks/lib/round-prepare-v1.js"
  - "hooks/lib/review-round-scope-v1.js"
  - "hooks/lib/zensu-doctor-report.js"
  - "skills/build/SKILL.md"
  - "skills/build/references/audit.md"
  - "skills/build/references/execution.md"
  - "skills/build/references/review-chain.md"
  - "skills/self-review/SKILL.md"
  - "tests/structure/edit-landing-claims-v1.test.js"
  - "tests/structure/edit-landing-scope-v1.test.js"
  - "tests/structure/test-edit-landing-audit.sh"
  - "tests/structure/test-tdd-complete-receipt-gate.sh"
---

# Claim Syntax and the Chain's Work Tree (`edit-landing-claims-v1.js` + `--work-tree`)

On 2026-10-29 an Autopilot-bound `/zensu:build` chain in a consuming repository parked as
`BLOCKED(precondition-decision-required)` at `--tdd-complete` although every edit had landed.
Two independent gaps led there, and an Autopilot-bound chain had no exit from either: the run log
is append-only, a new generation needs the outer run at `AWAIT_TDD`, and the only escape was
`ZENSU_EDIT_LANDING_GATE=off`.

1. **Ungradeable claims.** The audit split a `files:` list at every comma and graded each piece
   as a literal path, so `locales/{en,de}/settings.json` became the fragments
   `locales/{en` and `de}/settings.json`, and `locales/*/ghost.json` was a literal that never
   exists. A census over 2,640 local run logs found 231 glob tokens, 206 comma brace groups and
   about 5,000 whitespace tokens in 821 of 2,258 claim-bearing logs, no real path holding
   whitespace, and 88 real paths holding brackets (`[...slug].astro`).
2. **The nested Autopilot workspace.** The run's `workspaceRoot` was
   `<anchor>/.claude/worktrees/<name>`, a linked worktree of the anchor's own repository. The
   audit graded the anchor's change set, read relative claims against the anchor, graded claims
   inside the workspace `UNVERIFIED (foreign root)`, and the review chain enumerated the anchor.

## The claim grammar has one owner

`hooks/lib/edit-landing-claims-v1.js` is built-ins-only and owns the anchored line grammar (the
seven markers, the dash class, `LABEL_TOKEN_BUDGET`, the verdict-head skip list), the files split,
the token classes, brace expansion, glob matching, correction parsing and checking, and the
`append` pre-check. This is the standing fix `.claude/rules/multi-repo-stage1.md` named. Its CLI
has two commands, `rows` for the shell grader and `check-append` for the log writer. Consumers:
the grader and `--inventory` in `zensu-edit-landing.sh` (one `node` call replaced the bash
extraction loop), `claimOf` in `round-prepare-v1.js`, `review-round-scope-v1.js`, and
`zensu-log.sh append`.

- **Split.** Commas split only outside `{}` and `()`; nothing after the first ` | ` is part of
  the list.
- **Token classes.** `path`, `brace` (a group with a comma or a `..` range), `glob` (`*` or `?`)
  and `prose` (whitespace, or a token wrapped whole in quotes, backticks or one pair of
  parentheses, so a quoted path is never graded as a file name that holds the quotes). Brackets
  are path characters, never pattern syntax.
- **Brace.** Comma groups, integer and single-letter ranges and nesting expand to at most
  `BRACE_MEMBER_BUDGET` (256) members; every member is graded as a literal claim and must land. A
  group the module cannot expand grades `UNVERIFIED (pattern claim)`.
- **Glob.** `*` and `?` match inside a segment, `**` across segments, over
  `ls-files -co --exclude-standard` plus the graded tree's change set; the listing runs only when
  a glob row exists. Every match is graded as a literal claim. No match, or more than
  `GLOB_MATCH_BUDGET` (500), grades `UNVERIFIED (pattern claim)`. A pattern that matches nothing
  and whose literal prefix (the segments before the first `*` or `?`) lies in another root grades
  `UNVERIFIED (foreign root)` naming that root instead, because one audit run grades one root, and
  `--inventory` lists that root like an absolute claim's (`PC4`).
- **Prose.** Grades `UNVERIFIED (malformed claim)`, naming its candidates and the correction.
- **Fault.** A claim read that fails (no `node`, a module error) is an audit FAULT on the git-fault
  path: exit 2, no tally, and the earlier receipt marked nonclean with its audit scope kept
  (`RECEIPT REFUSED` when the mark cannot run). It never reports zero claims. So is a
  `rows` answer that carries a row kind the grader has no arm for: the module's exported
  `ROW_KINDS` and the grader's row-kind check name the same kinds (`CF2`, `CF3`).

**Write-time refusal.** `append` runs `check-append` for `--message` and `--message-stdin` alike
and refuses a files claim holding a brace, glob or prose token with exit 2 and nothing written,
naming each token and printing the corrected line wherever every offending token rewrites
exactly (braces expanded, a space-separated list of path-shaped words joined with commas). A
malformed `CLAIM CORRECTED` line is refused the same way. Its target check reads the run log
through a no-follow, non-blocking descriptor, and only from a regular, single-link file of at most
16 MiB; any other log skips that check and leaves it to the grader, so a FIFO at the log path
cannot stall the writer (`AP9`). A token that exists as written under
the project root or its git top passes. A missing module fails open with a stderr notice, like the
secret scan, because the grader stays the backstop.

**Corrections settle only what the grader could not.** The form is
`CLAIM CORRECTED — <label> (line <N>): <path>, … [| not claimed: <entry>, …]`. It covers prose
tokens, unexpandable patterns, and globs whose matches did not all land, which is how an
over-broad glob narrows. It counts only after line N, only when line N is a claim of that label
holding such a token, when every listed value is a `path` token and a candidate, and when every
candidate appears exactly once, listed or under `not claimed:`. Candidates: a glob's matches; for
a glob that matches nothing, any path it matches or the glob itself; for one over
`GLOB_MATCH_BUDGET`, any path it matches, with the glob itself under `not claimed:`; a prose
token's path-shaped words (a `/`, an inner `.`,
or the name of an existing or changed path), or the whole token when it has none; an unexpandable
pattern itself. Every correction is complete by construction, so the latest valid one wins
(`superseded`). Listed paths are graded and must land; each `not claimed:` entry prints
`CLAIM RETRACTED — <label> (line <N>, correction line <M>): <entry>`, which step 5b b) carries
like every non-landed line. An invalid correction prints
`CLAIM CORRECTION IGNORED — line <M>: <reason>` from the fixed `IGNORE_REASONS` vocabulary with no
author text, and counts for nothing. A literal path or a brace member can be neither corrected
nor retracted: an unlanded one stays `EDIT NOT LANDED`. The audit suggests a retraction only of a
pattern it cannot grade as written, an over-broad glob or one in another root, and that
retraction is itself a carried `CLAIM RETRACTED` line; its suggested correction for prose lists
every path-shaped word, so copying it hides nothing. A suggested correction is printed ready to
copy only when it is exact: a label or an entry the output screen would alter is printed as a
placeholder naming the run-log line to copy it from, and a prose correction is prefilled only when
it lists every candidate as the run log spells it (`MC2`, `MC3`). The three new heads sit in the module's skip list, the one list the grader and
round-prepare both read.

## Two roots, kept apart

`TOP` stays the anchor's git top for everything rooted in the session: the run log, the ledger
and convergence, the round scope's log read, the personas (the spawnable agents come from the
session's tree) and the external-review root. `WT`, the chain's work tree, carries what is about
the code: the change set and the diffs, the untracked reads, relative claims and grading, the
baseline and the snapshot digests. For a standalone chain `WT` is `TOP`.

**One resolver.** `_zensu_chain_work_tree` in `zensu-log.sh`, exposed read-only as
`zensu-log.sh --chain-work-tree`: the workflow document's Autopilot binding
(`tdd_autopilot_context`), then `autopilot_read_run`, which takes no lease, then the record's
`workspaceRoot`, then the library's `--work-tree-check`. The verb, `--round-prepare` and
`--tdd-complete` reach the binding only through `_zensu_bound_work_tree`, the lookup the evidence
runner uses (`.claude/rules/evidence-runner.md`). A standalone chain, a legacy record without
`workspaceRoot`, and a bound chain after its terminus answer the anchor's top. An unreadable
document or run record, an invalid `workspaceRoot` and a refused topology exit non-zero with the
reason and never fall back.
No state file was added, so a chain armed by an older installation resolves the same way and a
parked run needs no re-arming. The verb refuses a path holding `"`, `$`, a backtick or a
backslash, like `--project-root`, because the skills paste it into double-quoted shell source.

**The topology rule is the library's.** `--work-tree <dir>` (grade, `--change-set`,
`--inventory`) and the read-only `--work-tree-check <dir>` accept the anchor's top level and the
project root itself as the default mode; any other directory must lie strictly below the project
root, be its own `--show-toplevel`, and have the anchor's `--path-format=absolute
--git-common-dir`, the `worktreeIdentity` predicate of `session-reanchor-v1.js`. A clone, a
submodule, a subdirectory, a tree outside, a path inside `.git` and an empty value exit 2 naming
the failed condition. Check mode prints `anchor<TAB><path>` or `work-tree<TAB><path>`, and for a
refused topology also `refused<TAB><reason>` on stdout beside the stderr refusal and exit 2. Only
the topology refusals print it: a git fault, which dies as `could not be checked`, an argument
refusal and a run-log refusal print no verdict line, and the other modes never print one. Its one
consumer is `_autopilot_adopt_source_dir` in `hooks/lib/zensu-autopilot-state.sh`, which maps the
verdict and never the message; `_zensu_chain_work_tree_line` in `zensu-log.sh` and `checkWorkTree`
in `review-packet-v1.js` read stdout only on exit 0. With a
work tree the change set, relative-claim placement, `check-ignore` and the nested walks run in
`WT`; a relative claim that `WT` does not hold and that nests below the anchor, such as `WT`'s own
prefix as the packet spells it or a sibling worktree, is placed against the anchor's top instead,
because `WT`'s own `.gitignore` would otherwise exempt it as untracked by design whether or not it
landed: inside `WT` it grades there, in a sibling it grades `UNVERIFIED (foreign root)` (`WT14` to
`WT16`). With the anchor's top as the base every answer is rebuilt as an absolute path, so a
prefixed claim that a symlink leads out of the tree grades `UNVERIFIED (no work tree)` (`WT18`),
and a claim placed in `WT` keeps its whole path: it is never matched by its bare file name against
the change set (`WT17`). An anchor claim outside `WT` grades `UNVERIFIED (foreign root)` naming the anchor; the
receipt stays at the anchor's state path, gains `workTree` (project-relative, present only when
`WT` is not the anchor's top), and grade mode prints
`EDIT LANDING AUDIT ROOT — graded the chain's work tree <path>, not the anchor <path>`, a head the
extractor skips.

**`--tdd-complete`.** For a bound chain it adds the work tree's change count to the anchor's,
runs the claim inventory with `--work-tree`, and refuses a clean receipt whose `workTree` does
not name the resolved tree: an anchor-graded receipt on a work-tree chain, a receipt naming
another tree, and a work-tree receipt on a chain that works in the anchor each have their own
text. Every remedy line of a work-tree chain carries `--work-tree` and the one for a chain that
works in the anchor carries none, so following a remedy cannot loop. A work tree the resolver
cannot answer, and a change count git cannot list in either tree, refuse the verb before either
gate runs unless both gates are switched off (`WB13` to `WB16`, `WA1`).

**Counts, a deviation from the plan, measured.** The plan put the work tree into every count a
bound chain's tickets compare through `_zensu_unqualified_change_count`. Reading the call sites
showed that the unqualified marks and the `zc_` terminus path run only for chains without
Autopilot link keys, so `--tdd-complete` is the only bound count, and the helper and its other
call sites stay unchanged.

**Fix rounds.** `--round-prepare` uses `WT` for `--change-set`, the audit, `check-ignore`, the
snapshot and the round diff, and `TOP` for the ledger, the log and the round scope. The packet
lists are computed in work-tree space and printed with the prefix `<WT relative to TOP>/`
(`ZENSU_RP_PATH_PREFIX`), the diff headers through `--src-prefix`/`--dst-prefix`, while aspect
activation reads the unprefixed list: a worktree named `docs` would otherwise make every path a
documentation path. `review-round-scope-v1.js` takes `--path-prefix`, so claimed paths and
ledger anchors share one spelling. A claim or a ledger anchor that already carries the prefix, as
a reviewer reads the path, is stripped back to work-tree space (`stripPrefix`), so it lands and is
attributed like its unprefixed spelling, and the round scope adds the prefix only to a path that
does not carry it yet.

**Doctor.** `claimTopologyRow` validates the receipt's `workTree` (`auditedWorkTree`) and passes
it to the inventory, so a clean work-tree receipt no longer sits beside a foreign-root WARN, and a
`workTree` that is invalid or outside the project root renders its own WARN.

**Skills.** `/zensu:build` Phase 0 step 3 reads `{work_tree}` right after `--tdd-begin` and takes
`BASELINE_SHA` there, which moved the capture out of step 2 for every chain; step 5b passes
`--work-tree`; step 10.2 enumerates with `--change-set --work-tree`, diffs and reads in
`{work_tree}`, prefixes the packet's `changed_files` and the gate's `CHANGED-FILES`, keeps
`finding-verify --root "$TOP"`, and skips the external review import when `{work_tree}` is not
`$TOP`, because the import's root rule refuses a nested work tree. `/zensu:self-review` Phase 1
enumerates through the same `--change-set` call instead of its own copy of the recipe.
`/zensu:build` Phase 1 step 3 and `/zensu:self-review` Phase 4 run every project command as
`cd "<project dir>" && …`, where the directory is what `--chain-work-tree --project-dir` prints:
the project root, or the bound worktree's directory for it.

**Evidence and acceptance.** The evidence runner and the acceptance gate consume the same
resolver. For a bound chain `--evidence-run` runs in the worktree, and the full-suite verdict, the
acceptance runs and the acceptance records measure the combined tree of the project and the
worktree (`.claude/rules/evidence-runner.md`). A worktree the resolver cannot answer refuses
`--evidence-run` and both acceptance verbs with exit 2, and the bound terminus reads the
full-suite verdict `unavailable`.

## Coupled sites

The module and its unit file (`tests/profiles/unit-files.v1.json` holds its count); the grader,
`--inventory`, `--change-set`, `--work-tree` and `--work-tree-check` in `zensu-edit-landing.sh`;
the `append` pre-check, `_zensu_chain_work_tree`, `--chain-work-tree`, `--tdd-complete` and
`--round-prepare` in `zensu-log.sh`, whose work-tree refusals `WB0` to `WB20` and `WA1` in
`test-tdd-complete-receipt-gate.sh` pin; `stripPrefix`, `prefix` and `anchor` in
`round-prepare-v1.js`; `--path-prefix` in `review-round-scope-v1.js`; `auditedWorkTree` and
`claimTopologyRow` in `zensu-doctor-report.js`, and the topology and `NOT checked` bullets of
`skills/doctor/SKILL.md` that explain its rows (the `doctor` entry of
`test-skill-text-budget.sh` holds that body's exact size). Skill text: Phase 0 steps 2 and 3 of
`skills/build/SKILL.md` (`L5` in `test-tdd-log-path-anchor.sh`, `E10a` and `E10g` in
`test-session-reanchor.sh`, `P1` in `test-edit-landing-audit.sh`), step 5b of `audit.md` (the `S`
checks of `test-edit-landing-audit.sh`), the claim contract of `execution.md`, steps 10.2 and 3 of
`review-chain.md`, and Phase 1 of `skills/self-review/SKILL.md` (`V7` in
`test-self-review-skill.sh`, `L9` in `test-tdd-log-path-anchor.sh`, the `self-review` entry of
`test-skill-text-budget.sh`). Operator accounts: discipline patch 10, the `{project_root}`
paragraph and the `append` paragraph of `docs/build-workflow.md`, the `ZENSU_EDIT_LANDING_GATE`
row of `docs/configuration.md`, the lead-in of `docs/gates.md`, the round-prepare list and the
import-layout paragraph of `docs/review-chain.md`, and §5 of `docs/multi-repo-chains-spec.md`.

## Known gaps

- A file inside a work tree whose name holds whitespace or pattern characters cannot be claimed;
  the census found none.
- A claim on an ignored path grades `EDIT LANDED (untracked-by-design)` whether or not the file
  exists, in the anchor and in a work tree alike. The self-review weighed requiring the file to
  exist and left it out: the behaviour predates this change, and the scrub controls `X10`, `X17`
  and `X23` of `test-edit-landing-audit.sh` rely on it. The placement above keeps a claim spelled
  with the work tree's own prefix out of that exemption.
- A word with no `/`, no inner `.`, naming no existing or changed path, is no candidate, so a
  correction may leave it out (an extensionless file that was never created).
- Reviewer reads and `finding-verify` acceptance of a prefixed `.claude/worktrees/...` path follow
  from the source (`protectedAccessViolation` admits any path inside the project root that is not
  under the anchor's `.zensu`; `finding-verify-v1.js` denies only `.git` and `.zensu` segments).
- PR #485 reconciled with this change when it merged it. The audit scope it adds finds an earlier
  claim by its step and raw text rather than by position, so a correction or a glob row between
  two rounds keeps every earlier snapshot; its checkpoint receipt carries `workTree`; and
  `review-packet-v1.js create` reads the change set of the receipt's `workTree`, spelled with the
  work tree's prefix below the anchor (`.claude/rules/review-packet-gate.md`).
- Windows is unverified: `workspaceRoot` is stored native-canonical, and the library canonicalizes
  with `cd … && pwd -P`.
- No ports. `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not included.

## Version: `patch`

Walked against `.claude/rules/runtime-lineage.md`: no context-record or workflow-state field; no
strict key set (the receipt readers `_tc_receipt_verdict`, `edit-landing-receipt-v1.js` and the
doctor's `RECEIPT_SCHEMAS` ignore unknown keys); no hook or matcher change, no
`permissionDecision` and no attestation change; `append` and the gate refuse strictly more inside
one installation. The optional receipt field `workTree` is the one entry that reads close:
`requirements-table-gate.md` records that a persisted shape that moves costs a `minor`, but that
precedent changed the value domain of an existing field (`log`), which an older reader misread.
Here no existing field changes; an older gate ignores `workTree`, and a newer gate refuses an
older receipt on a work-tree chain with a re-run remedy.

## Superseded claims

On 2026-11-20 an Autopilot-bound chain in a consuming project could not pass `--chain-done`. Step
`S02` added an error code in six files and the audit certified those claims; review fix `R1-F9`
removed the code again as dead code. A certification holds only while the claimed file is
byte-identical, and a predicate proof needs a literal that holds on the current file, so the six
claims could never be proven again, and a bound chain cannot arm a new generation. The gate had no
state for an edit that landed and was then replaced on purpose.

**A supersede is a predicate proof, not a run-log line.** A `--predicates` entry takes one
optional field, `supersededBy`, in both forms:
`{"step","path","sha256","absent":[…],"supersededBy":"<later step>"}`, and
`{"step","path","missing":true,"supersededBy":"<later step>"}` for a file the later step deleted.
It never carries `present`, and the literal form needs at least one `absent` literal. A run-log
line was weighed and dropped: the proof demands evidence bound to the current bytes, reuses the
one verifier and the one persistence rule the audit has, and needs no claim grammar, row kind,
write-time check or manifest.

**When it counts.** `resolveSupersedes` in `edit-landing-receipt-v1.js` accepts the proof for a
claim `T` only when all of this holds. Every breach fails the audit with exit 2 and its own
sentence, like any invalid proof.

1. `T` is neither certified in this audit nor proven by an ordinary proof in the same document.
2. `T` has landing evidence (below).
3. A claim `B` of the `supersededBy` step names the same file and comes after the last claim of
   `T` in the run log.
4. `B` is landed in this audit: certified, or proven in the same document. There is no
   transitivity, and a step never supersedes itself.
5. The `absent` literals hold on the current bytes, or the file is missing, under the rules of
   the ordinary proof.

**Landing evidence (`landedOnce`).** `prepareClaims` grants it from two sources. Sticky: the
previous audit scope holds the claim as `certified` or `landedOnce`, and the claim's path
resolution did not move. First sight: the claim has no earlier entry, its file has an earlier
snapshot that differs from the current bytes, and every claim first seen on that file carries the
same step. The second source exists because a fix round's audit grades every dirty file
`PENDING PREDICATE`, so a fix-round claim is never certified before the terminus, and a round 2
fix that undoes a round 1 fix would otherwise wedge the same way. `--round-prepare` attributes a
round's claims by the same two-label idea, but against its own round-start snapshot, which records
every changed path, while the audit snapshots only files some claim named; the two therefore
disagree in the cases the Known gaps list. A claim without evidence cannot be superseded, and the
refusal says what the code knows: the audit scope records no landing for it.

**The recovery command names the work tree.** A terminus refusal prints `Run: <audit command>`
followed by `RECOVERY_GUIDANCE`, which names the supersede proof. An audit of another claim root
re-roots the scope (`prepareScope` drops `previous`), and with it every certification and every
landing evidence. So `auditRecoveryCommand` appends `--work-tree <project root>/<workTree>` when
the session receipt records a work tree (`boundWorkTree`), in the terminus refusal (`freshVerb`)
and in the `AUDIT SESSION REQUIRED` refusal (`sessionGate`) alike, the guidance says to keep that
operand, and a recorded work tree the command cannot carry is printed as the placeholder
`<work tree>`, which fails when run as written rather than grading the anchor. A chain that works
in the anchor prints the command as before. A git fault keeps the record. The audit validates
`--work-tree` only while git answers, so a fault run hands the checkpoint no work tree, while
`prepareScope` keeps the scope on its claim root. `checkpointScope` therefore records the work
tree that scope is bound to (`scopeWorkTree`, the claim root's path below the project root)
whenever the audit names none. A checkpoint without the key would make the command printed after
git recovers audit the anchor and re-root the scope.

**Verdict and counts.** The grader prints
`EDIT SUPERSEDED — <step>: <path>, replaced by <step2>` through `render_claim_value`, and the
claim counts toward `claims`, `landed` and `exempt_superseded`. The tally field and the receipt
key `exemptSuperseded` exist only above zero, so a chain without a supersede keeps its output and
its receipt keys, and `receiptFresh` is unchanged because a clean receipt still has
`landed === claims`. The audit scope keeps `supersededBy` and `landedOnce: true` on a claim entry
only while the claim is not certified. A later audit carries the verdict while the file's bytes
are unchanged and `B` is still certified, the rule a certification follows; a changed file needs
a fresh proof for both claims. A supersede records no bypass-ledger entry, because it escapes no
gate. Both summary renderers carry the line verbatim and mark it 🟡
(`.claude/rules/status-marker-legend.md`).

**Coupled sites.** `supersedingStep`, `resolveSupersedes`, `verifyPredicates`, `prepareClaims`,
`finishScope`, `persistedScope`, `writeScopeFlags` (the `superseded` flag file, one
`index<TAB>step` line per claim), `auditRecoveryCommand`, `boundWorkTree`, `scopeWorkTree`,
`checkpointScope` and `RECOVERY_GUIDANCE` in `edit-landing-receipt-v1.js`;
`superseded_claim`, `grade_claim`, the tally line and the receipt writer in
`zensu-edit-landing.sh`; `VERDICT_HEADS` in `edit-landing-claims-v1.js`, so a copied verdict is
never read as a claim; `AUDIT_NOTICE` in `round-prepare-v1.js`, so `--round-prepare` carries the
line; `receiptLine` in `review-packet-v1.js`, which renders `exempt_superseded=<n>` only for a
receipt that holds the key; the `unclean` remedy of `--tdd-complete` in `zensu-log.sh`. Texts:
step 5b b) and c) and step 9 of `audit.md`, the `edit_landing_evidence` definition at its four
sites (`agents/code-reviewer.md`, `agents/review-aspect.md`, `agents/review-judge.md` and step
10.2c of `skills/build/references/review-chain.md`), "Final report" in
`skills/self-review/SKILL.md` (the `self-review` entry of `test-skill-text-budget.sh` holds that
body's exact size), `COMBINED_SUMMARY_DIRECTIVE` in `hooks/post-review-tdd-delegate.sh`,
discipline patch 10, the marker paragraph and the `## What I built` row of
`docs/build-workflow.md`, the lead-in, the `## Terminal Edit-Landing Gate` section and its
"What it prints" bullet in `docs/gates.md`, and the `ZENSU_EDIT_LANDING_GATE` row of
`docs/configuration.md`.
Pins: the supersede cases and the two work-tree recovery cases (a stale receipt, a git fault) of
`tests/structure/edit-landing-scope-v1.test.js`, `E14` and `E14a` in
`test-terminal-edit-landing-gate.sh`, `S4`, `S4a` and `X29b` in `test-edit-landing-audit.sh`,
`D10c` in `test-tdd-complete-receipt-gate.sh`, one case each in the claims, round-prepare and
review-packet unit files, and both literal loops of
`evals/config-gate/test-post-review-combined-summary.sh`. No suite pins the verdict's name at
the four `edit_landing_evidence` sites or in step 9.

**Known gaps.**

- A step undone before any audit saw it land has no landing evidence and keeps its verdict: an
  edit reverted inside the implementing phase, and two steps that one audit first sees on the same
  file.
- First-sight evidence proves that the file changed between two audits while one step newly
  claimed it, not that this step's own edit changed it.
- A claim an audit first saw before its edit landed keeps an entry without evidence and never
  gains any, because first sight is granted only to a claim without an earlier entry. The
  `--round-prepare` exit-1 flow reaches it: the audit seals its receipt before the verb stops the
  round, and the re-run verb then reports the claim landed.
- A fix-round claim on a changed file that no earlier claim named gains none either: first sight
  needs an earlier snapshot, and the audit snapshots only claimed files. A test file written while
  implementing in strict mode is such a file. The verb attributes that claim as landed.
- Every claim entry an audit of an older installation wrote as uncertified carries no landing
  evidence, a claim that audit or an earlier one had certified included. A chain that was already
  refused before the update is therefore not rescued by it. That is a decision, not an oversight:
  the persisted scope holds nothing that tells a once-certified claim from one that never landed,
  and the verdict lines in the run log are model-written text the audit never reads as evidence.
- A proof reaches a claim only while the grader resolves its path. A claim spelled without a
  directory component loses it once its file is neither on disk nor in the change set
  (`normalize_claim`), so no proof entry can name it, the deletion form included. The ordinary
  `missing` proof has the same bound.
- Each claim in the four cases above keeps the exits it had before this change: a new generation
  for a standalone chain, and for a bound chain none but the gate variable. Closing them needs a
  second evidence source, for example a round-start digest of changed files no claim named, and
  the previous audit's resolved path for a claim the grader can no longer resolve.
- An ordinary proof with only `absent` literals and no `supersededBy` still passes and prints
  `EDIT LANDED` for an edit that is gone. Refusing it would break proofs that are valid today.
- `VERDICT` in `round-prepare-v1.js` reads no `EDIT SUPERSEDED` line. A claim of the round being
  prepared that an earlier audit graded superseded is carried as a notice and left out of its
  label's state, so a label whose every file is superseded gets no `ROUND LANDING` line and no
  `fixed` line from the verb.
- A fault checkpoint records a work tree only from a scope an earlier audit bound to it. The
  first audit of a work-tree chain that stops on a git fault records none, and loses nothing,
  because no certification exists yet. A checkpoint an installation without `scopeWorkTree` wrote
  stays without the key, so the command printed for it audits the anchor.
- A bound chain whose terminus refuses for a cause that no edit or proof removes, such as a claim
  that never landed, still has no exit other than the gate variable.
- Windows is unmeasured, and the ports were not included.

**Version: `patch`.** Walked against `.claude/rules/runtime-lineage.md`: no context-record or
workflow-state field, no hook, matcher, config key, `permissionDecision` or attestation change.
The receipt and the audit scope gain keys that no reader validates. The proof document is the
entry that reads close, because `verifyPredicates` rejects an unknown key. The reason behind the
strict-key-set entry is a runtime that cannot read what a session wrote, and it does not apply
here: a proof document is written for one audit call and is never session state, a newer runtime
accepts every document an older one accepted, and an older runtime that is handed the new field
refuses it with exit 2, which fails closed. An older terminus accepts a clean receipt the newer
audit wrote, because `landed === claims` holds.
