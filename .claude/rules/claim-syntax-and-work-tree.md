---
paths:
  - "hooks/lib/edit-landing-claims-v1.js"
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
  path: exit 2, no tally, any earlier receipt removed. It never reports zero claims. So is a
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
`workspaceRoot`, then the library's `--work-tree-check`. A standalone chain, or a legacy record
without `workspaceRoot`, answers the anchor's top. An unreadable document or run record, an
invalid `workspaceRoot` and a refused topology exit non-zero with the reason and never fall back.
No state file was added, so a chain armed by an older installation resolves the same way and a
parked run needs no re-arming. The verb refuses a path holding `"`, `$`, a backtick or a
backslash, like `--project-root`, because the skills paste it into double-quoted shell source.

**The topology rule is the library's.** `--work-tree <dir>` (grade, `--change-set`,
`--inventory`) and the read-only `--work-tree-check <dir>` accept the anchor's top level and the
project root itself as the default mode; any other directory must lie strictly below the project
root, be its own `--show-toplevel`, and have the anchor's `--path-format=absolute
--git-common-dir`, the `worktreeIdentity` predicate of `session-reanchor-v1.js`. A clone, a
submodule, a subdirectory, a tree outside, a path inside `.git` and an empty value exit 2 naming
the failed condition. Check mode prints `anchor<TAB><path>` or `work-tree<TAB><path>`. With a
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

## Coupled sites

The module and its unit file (`tests/profiles/unit-files.v1.json` holds its count); the grader,
`--inventory`, `--change-set`, `--work-tree` and `--work-tree-check` in `zensu-edit-landing.sh`;
the `append` pre-check, `_zensu_chain_work_tree`, `--chain-work-tree`, `--tdd-complete` and
`--round-prepare` in `zensu-log.sh`, whose work-tree refusals `WB0` to `WB16` and `WA1` in
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

- **The evidence runner and the acceptance gate do not follow the work tree.** `runDirectory` in
  `evidence-run-v1.js` moves a working directory inside a nested work tree back to the project
  root, so the `--chain-done` full suite of such a chain runs in the anchor unless its command
  opens with a literal `cd`, and acceptance records fingerprint the project root alone. The
  project commands `/zensu:build` and `/zensu:self-review` prescribe as `cd "{project_root}" && …`
  run in the anchor too. This is the first follow-up and consumes the same resolver.
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
- Open PR #485 rewrites the same library and skill texts; whichever lands second reconciles.
  Rows stay in log order and append-only, a correction's rows sit at the correction's position,
  and the receipt names the graded tree in one field, `workTree`.
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
