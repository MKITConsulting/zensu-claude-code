---
paths:
  - "hooks/lib/round-prepare-v1.js"
  - "hooks/lib/zensu-log.sh"
  - "hooks/lib/zensu-edit-landing.sh"
  - "hooks/post-review-tdd-delegate.sh"
  - "skills/build/references/review-chain.md"
  - "skills/self-review/SKILL.md"
  - "tests/structure/round-prepare-v1.test.js"
  - "tests/structure/test-round-prepare.sh"
---

# Fix-Round Bookkeeping (`hooks/lib/round-prepare-v1.js` + `zensu-log.sh --round-prepare`)

One routed fix round of the `/zensu:build` auto-fix loop used to cost about six model-driven
helper calls, each re-sending the whole context: the edit-landing audit, the round scope, the
ledger read, hand-written `fixed` ledger lines, aspect activation with its `ASPECT SKIPPED`
lines and a hand-made round diff. Measured in a PROJEKTPRO session on 2026-10-21 at about 600k
context tokens per call, and again in this repository's own chain on 2026-10-26. The verb does
that bookkeeping in one call.

**The verb.** `zensu-log.sh --round-prepare --round <0|N|self-review> --log <run log>
[--baseline <sha>] [--session-epoch <n>]`. The log must be a regular file directly inside the
bound project root's `.zensu/logs/`, and every call of a chain passes the `--baseline` of its
round-0 call.

- `0` runs once in step 10.2 before the first fan-out, records the round-start snapshot and logs
  `ROUND PREPARE — round 0 recorded the round-start snapshot (<n> changed files)`, the line that
  marks where round 1 begins.
- `N` writes `EDIT LANDING AUDIT STARTED — round fix-N`, runs the edit-landing audit with the
  snapshot's paths as `--dirty-before`, resolves every claim of the round, and appends the
  carried verdict lines, the audit tally, one `ROUND LANDING — <label>: <state> (files= changed=
  unchanged= unresolved= failed=)` line per claim, the `fixed` ledger lines and the `ASPECT
  SKIPPED` lines. It prints `fixed:`, `unresolved_claims:`, the open ledger, `changed_files
  (<reason>):`, `judge_changed_files:`, `spawn:` and `round_diff:`, then records the next
  snapshot.
- `self-review` runs the audit and the `fixed` lines under the marker `round self-review` and
  prints no packet lists and records no snapshot.

Every log line the module writes that the caller must act on also goes to the caller: the
carried verdict lines except `PENDING PREDICATE`, the audit tally, the `ROUND LANDING` lines and
`ROUND LEDGER UNAVAILABLE`. A line that reached only the run log reached no one who decides.

Exit 0 means prepared. Exit 1 means a claim of this round did not land in this round: no `fixed`
line is written and the previous snapshot stays, so the same round can run again after the
claim is landed or withdrawn. The stop line names each such claim with its file and outcome.
Exit 2 is a refused argument or a failed step. A refused argument is checked before anything
runs, prints a usage error on stderr and changes nothing. A failed step prints `ROUND PREPARE
STOPPED — <step>: …` and then `ROUND PREPARE FALLBACK — …`, the manual path for a verb that cannot
run at all, outside git or without node: the step 5b audit by hand, each `fixed` line after a
re-read of its fix, and the whole diff for the re-review. `_rp_stop` and the module's `fault` and
`refused` statuses print it through `_rp_fallback`, so no caller restates it.

**A withdrawal is the way out of exit 1.** `CLAIM WITHDRAWN — <label>: <file>`, or `CLAIM
WITHDRAWN — <label>` for every file of the label, counts only when it comes after the label's
first claim in the current generation, so a stale withdrawal cannot pre-empt a later claim. A
withdrawn file is left out of the label's state; a label whose every file is withdrawn is
`withdrawn`, gets no `fixed` line and is listed under `withdrawn_claims`, and its finding stays
open. The audit itself does not read withdrawals, so it still reports the claim. The stop line
names both spellings, and the label form is the only one for a claim the audit lists with no
file: a bare `WIRED` entry or an `UNVERIFIED` claim.

**A refused receipt is a failed step, whatever the audit's exit code.** The audit reports grading
first: when a claim is pending, which in a fix round it almost always is, it exits 1 even though
its receipt was refused. The module therefore reads the audit's own lines, and a `RECEIPT
REFUSED` line stops the round with exit 2 before any claim is attributed, so no `fixed` line is
written and the snapshot stays. `RP10` drives it through a `mv` stub that refuses only the
receipt, which works where a read-only directory would not: as root and on Windows.

**Why a snapshot.** A fix round runs on an uncommitted tree, so every file it touches was already
dirty when the round began. Measured in this repository's chain: with the step 5b
`--dirty-before` list the audit graded all 38 claims `PENDING PREDICATE`, and every `fixed` line
was hand-written after a manual predicate re-read. A verb that trusted `EDIT LANDED` alone would
write none in that common case. Every successful numeric round therefore records sha256 digests
of the change set in `.zensu/state/round-snapshot-<session key>.json` (`round-snapshot-v1`,
newest four rounds). The next round compares each claimed file that was dirty at its start with
that digest: changed means landed in this round, unchanged means not landed. The reviewers in
between only read, so the state after round N is the state round N+1 starts from.

**The snapshot is bound to its chain.** The document carries the work-tree top, the run log's
file name and the review generation, the number of `REVIEW BUDGET RESET` lines in that log; a
reader refuses a document without both. A snapshot of another run log answers `other-chain`, one
of an earlier generation `other-generation`, and either leaves the round unattributable. Every
entry also records the `--baseline` it was taken with, and a round called with another one
answers `other-baseline`: with a baseline the change set also lists every file committed since
it, so an entry taken without one lacks those files, and an `EDIT LANDED` claim on one of them
would land by absence although the round never touched it. A
session that ran an earlier chain keeps its session key, so without the binding a new chain could
start a round from the old chain's entry: its first fix round when round 0 did not run, and its
self-review from an old round number the new chain never reached. `--round 0`, another chain or
another generation starts a fresh document instead of merging into the old one. Fix round N
starts from entry N-1. The self-review round starts from the entry of the chain's last fix round,
the highest `R<k>` claim or `EDIT LANDING AUDIT STARTED — round fix-<k>` marker after the last
reset, because the highest entry on disk is older than that round whenever its prepare call
stopped; a missing entry is unattributable, never an older one.

**Every changed path is recorded, and a partial record never lands a claim.** Up to
`LIMITS.maxRecorded` paths are recorded, `.zensu` paths included because `--dirty-before` must
name every path the audit grades. Past `LIMITS.maxFiles` a path is recorded `unhashed`, and so is
one whose digest could not be taken (unreadable, not a regular file, over
`LIMITS.maxFileBytes`). Past `maxRecorded` the entry only counts the paths it left out in
`truncated`. An `EDIT LANDED` or `PENDING PREDICATE` claim whose start or current digest is
`unhashed` or `directory` is unresolved, and so is an `EDIT LANDED` claim for a file the start
entry lacks when that entry is truncated, because the file may have been dirty already. An
`EDIT NOT LANDED` claim lands only through the restored-file rule below, which needs a content
digest at both ends, and an `UNVERIFIED` claim never lands, so both stop the round whatever the
digests say. `absent` and a link digest are content and compare like a file.

**Attribution is by label, never by file.** `R<N>-F<n>` names `R<N>-F<n>`, `R<N>-R<k>-F<n>`
names the earlier `R<k>-F<n>`, and `SR-R<k>-F<n>` names `R<k>-F<n>` in the self-review round. A
label lands when every file line it has, withdrawals left out, landed in this round. A changed
file two labels of the round claim is unresolved for both, because one edit cannot be shown to
fix two findings. A label claimed only before the last reset is an earlier claim. One claimed on
both sides of it is judged by the files it claimed after the reset: a verdict for a file it
claimed only before belongs to the earlier claim and is skipped, and a verdict that names no file
stays unresolved, because the audit's lines for the two claims cannot be told apart. An `EDIT NOT
LANDED` claim whose file was dirty at the round's start and now differs from that digest landed:
it was restored to its committed content. Only an entry in state `routed-unfixed`, `parked` or
`deferred` gets a `fixed` line, rendered from the entry's own severity, anchor and summary and
checked with `parseLedgerLine` before it is written, so the ledger format is unchanged. The
ledger is read with the report read `/zensu:self-review` uses, so an entry carried from an
earlier generation keeps its `G<g>:` prefix, and `SR-G<g>:R<k>-F<n>` or `R<N>-G<g>:R<k>-F<n>`
names it.

**Labels follow the audit's claim grammar.** `claimOf` mirrors the anchored grammar of
`zensu-edit-landing.sh` (`.claude/rules/multi-repo-stage1.md`): an optional bracketed prefix, the
audit's verdict heads skipped, the earliest of the seven markers, a label of at most
`LABEL_TOKEN_BUDGET` (5) tokens without `'`, `"` or `|`, `(none)` for an empty label, the files up
to the first ` | `, and the bare `<step> WIRED` fallback; a file spelled `<project>/…` or `./…`
is normalized. A one-token label pattern missed every multi-token step the audit grades. A claim
logged after the round's boundary, the previous round's audit marker or the round-0 line, whose
label lacks the round's prefix is listed under `unprefixed_claims`, because no `fixed` line can
name its finding.

**The verb owns the `fixed` line.** The convergence clause of
`hooks/post-review-tdd-delegate.sh` tells the model to name each fix step after its finding id
and to append a `fixed` line by hand only for an id the verb lists under `unresolved_claims`, or
for a landed claim when it printed `ROUND LEDGER UNAVAILABLE`, after re-reading that fix. A clause
that still asked for a hand-written line once a fix lands wrote every `fixed` line twice.

**Fail-closed.** No usable snapshot: `ROUND LANDING UNAVAILABLE`, every claim of the round stays
unresolved, and no `fixed` line is written. A ledger the report read answers neither `ok` nor
`partial`: `ROUND LEDGER UNAVAILABLE` and no `fixed` line; a `partial` read writes `fixed` lines
only for the entries it could read and says so in a `ledger_note:` line. A snapshot that could not be written is an output notice, not a
stop: the round's own work is done, and the next round then finds no entry for this one and is
unattributable. With `hooks.reviewConvergence` off the verb reads no ledger,
prints `open_ledger: off (hooks.reviewConvergence is off); no fixed line was written` in every
fix round, the self-review round included, and writes no ledger line into the run log, so a
project that turned convergence off gets no ledger noise there, while `fixed: none` is never
mistaken for a ledger that was consulted. `PENDING PREDICATE` lines of earlier rounds are counted, not
carried, because they were resolved in their own round; their `EDIT NOT LANDED` and
`UNVERIFIED` lines are still carried.

**One reader per decision.** The verb reads `hooks.incrementalReviewRounds`,
`hooks.aspectActivation`, `hooks.reviewConvergence` and `hooks.reviewPanel` against the Session
Control record's project root, the root the post-review delegate reads them from, so the
delegate's `ROUND_SCOPE` and `ACTIVATION_INPUT` text and the verb's lists agree unless the config
changes inside one round. The cumulative change set comes from `zensu-edit-landing.sh
--change-set`, a read-only mode of the library that owns the step 5b enumeration: it refuses
every grading or writing operand with exit 2, exits 3 outside a git work tree and 2 on a git
fault. A path with a `.zensu` segment at any depth is dropped from the packet lists, so a
project root below the work-tree top keeps its own state out too. The verb arm also pipes the
change set through `git check-ignore --stdin` under the user's own git config, and the module
leaves every path it reports out of the packet lists and the round diff and counts them in a
`user_ignored:` line. The audit's `_el_git` sets `core.excludesFile=/dev/null` on purpose, so its
grading never depends on a personal excludes file; the change set therefore still lists an
untracked file only that file ignores, and the verb hides it from the reviewers, never from the
audit. A `check-ignore` exit above 1 is an exit-2 stop.

**Coupled sites.** The module and its unit file; the verb arm in `zensu-log.sh` and
`tests/structure/test-round-prepare.sh` (`RP0`–`RP14`); the `--change-set` mode and `CS1`–`CS6`
in `tests/structure/test-edit-landing-audit.sh`; `claimOf`, which moves with the audit's claim
grammar and its `X29`–`X33` pins in the same suite; `VERDICT` and `DIRTY_TAILS`, which read the
audit's verdict heads and both spellings of its `PENDING PREDICATE` line, the current one and
the one older run logs carry, so a reworded verdict line in `zensu-edit-landing.sh` moves them
and the verdict-line unit case; the verb sentence in all three severity arms of
`hooks/post-review-tdd-delegate.sh` and its `ROUND_SCOPE` on-variant (`I17f`, `I30b`, `I31c`);
the `fixed`-line sentences of `CONVERGENCE_CLAUSE`, which must stay clear of the `R16` needles in
`tests/structure/test-review-convergence.sh`; the reset marker `RESET` of
`review-round-scope-v1.js`, which the generation counts;
step 10.2 and the fix-round paragraph of `skills/build/references/review-chain.md` (`I8`, `I10`,
`I10a`, `I12`–`I14`, `R21b`, `R17-P5`, and the `On routed findings` check of the edit-landing
suite); the withdrawal sentence of the step 5b audit in `skills/build/references/audit.md`; the
fixed-line sentence of Phase 3 and the audit paragraph of Phase 4 in
`skills/self-review/SKILL.md`, whose budget allowlist entry moved to its new size; the unit-file
entry, the `ciStructureTests` member and the regenerated overview; `docs/review-chain.md` and
`docs/build-workflow.md`.

**Known gaps.**

- A changed file is not a fixed finding. The verb proves an edit happened in this round, the
  same evidence a hand-written `fixed` line rested on. Only `hooks.reviewPanel: full` re-checks a
  `fixed` entry, through the judge's `[NOT FIXED]` tag; the lean panel's re-review gets no ledger
  and `/zensu:self-review` takes no `fixed` entry as a candidate, so a wrong `fixed` line stays
  closed unless a later review raises the defect again.
- An edit made between a prepare call and the next round's fixes, by the user for example,
  counts toward the next round.
- A chain whose step 10.2 skipped the round-0 call, a resumed review, and the first fix round
  after a `REVIEW BUDGET RESET` have no usable snapshot; that round is disclosed as
  unattributable and its `fixed` lines stay manual. `/zensu:reset-review-limit` could record a
  fresh round 0 after its marker; it does not.
- The self-review start reads the chain's last fix round from the run log. A fix round that ran
  without the verb and logged no `R<k>` claim leaves no trace there, so the self-review would
  start from an older entry and could count that round's edits as its own.
- A withdrawal is model-authored run-log text, like the claims and the ledger. It counts only in
  the exact `CLAIM WITHDRAWN — <label>[: <file>]` spelling, and it keeps counting after the label
  is claimed again. A claim landed by the restored-file rule still carries its `EDIT NOT LANDED`
  line to the caller.
- An untracked file that only the user's global excludes file ignores is hidden from the
  reviewers but not from the snapshot: the round-start document in `.zensu/state/` holds its
  sha256 digest, which can confirm a guessed low-entropy secret wherever that directory leaks.
- `claimOf` strips `<project>/` without rebuilding the path against the project root, as the
  audit's `unredact_claim` does, so in a session whose project root sits below the work-tree top
  the reset split compares another spelling than the audit's verdict lines carry.
- A non-ASCII path reaches the module in git's quoted form (`core.quotePath`), so the packet
  lists and the snapshot carry that spelling, and a claim naming the file unquoted matches no
  snapshot entry.
- The round diff is written check-then-write: the symlink test and the redirect are two steps, so
  a link planted between them is followed. `.zensu/state/` is session-writable, as for every
  artifact there.
- The convergence clause and step 3 of the review chain still run the scope helper, the ledger
  read and aspect activation the verb already ran, so the saving is the bookkeeping, not every
  helper call.
- Every log line is one `append` call, a `bash` and a `node` start each.
- The verb's own arm for an audit exit other than 0 or 1 is driven by no check. A git fault
  stops the change-set step before the audit runs, and in a fix round every earlier claim is
  pending, so the audit exits 1 rather than 2 whenever its receipt is refused there.
- The round diff compares with `--baseline` when given and with `HEAD` otherwise, renders an
  untracked file with `git diff --no-index`, and leaves out a file deleted in the round.
- Windows is unmeasured: the suite is a `ciStructureTests` member and runs on the weekly Windows
  Safety structure shard only.

**Version: `patch`.** A new verb and a new private state file; no context-record or
workflow-state field, no strict key set a released reader knows, no hook added, removed or
re-matched, no config key and no attestation change; the ledger line format is unchanged.

**Port-relevant.** Core half: the module. Host half: the verb, the delegate sentence, the skill
text and the snapshot location. `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not
included.
