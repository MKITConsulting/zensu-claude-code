---
paths:
  - "skills/session-trail/scripts/autopilot-runs-v1.mjs"
  - "skills/session-trail/scripts/trail.mjs"
  - "skills/session-trail/references/**"
  - "plugins/session-hub/skills/session-trail/scripts/autopilot-runs-v1.mjs"
  - "plugins/session-hub/skills/session-trail/scripts/trail.mjs"
  - "plugins/session-hub/skills/session-trail/references/**"
  - "skills/autopilot-adopt/SKILL.md"
  - "tests/structure/autopilot-runs-v1.test.js"
  - "tests/structure/test-session-trail-verdict.sh"
---

# Session-Trail Autopilot Runs (`autopilot-runs-v1.mjs` + `autopilotRunsOf` in `trail.mjs`)

**Two copies.** `/zensu:session-trail` is PLM's frozen copy of this skill; the
`session-hub@zensu` companion carries the maintained one as `/session-hub:session-trail`.
`.claude/rules/session-hub-companion.md` says which copy each check grades. A fix lands in both:
the module is one of the companion's byte-identical copies (H4), and `autopilotRunsOf` is equal in
both `trail.mjs` copies (H16).

**A takeover names the old session's durable Autopilot runs, because nothing else carries them.**
On 2026-11-10 a session drove run `run_ad0149b5fdc8d879` to `TEAM_REVIEW`, hit a rate limit, was
taken over through `/zensu:session-trail` with the move route and was released. The run stopped
without a word: session-trail never read `autopilot-run-*.json`, `--autopilot-adopt` served only a
successor in the same project root, and no writer rewrote `projectRoot` or `workspaceRoot`. The
adopt half of the fix, the relocation, is in `.claude/rules/autopilot-run-scope.md`. This file is
the session-trail half.

**The reader.** `readAutopilotRuns(folders, ownerKey)` reads `<folder>/.zensu/state` for each of
`new Set([r.cwd, r.wt])`, the session's recorded directory and its worktree, because a run record
lives in the state directory of the project root that minted it. A `.zensu` or `state` that is a
symbolic link or no directory holds no run, exactly as the state library refuses such storage.
Every record a directory lists is considered, because `release` must not miss one, and the reads
stop at a byte budget instead, `RUN_READ_BUDGET_BYTES` (256 record maxima, 256 MiB across the
directories of one call): a record that would cross it is counted in `truncated`, never read, and
every carrier names that count as unread together with the remedy, removing the records of finished
runs that are no longer needed. Each record must be a regular, single-link file of at most
`RUN_RECORD_MAX_BYTES` (1 MiB), read through a no-follow, non-blocking descriptor whose `fstat`
must match the `lstat`, mirroring the state library's `guardedRead`; it must parse, carry the
`schemaVersion` the state library validates (`RUN_SCHEMA_VERSION`, 1), name the run of its file
name and name an owner.
Every other record is listed as **unreadable** with its reason, never skipped in silence. `ownerKey`
is a function, so the key is computed only when a run record exists: `autopilotRunsOf` resolves it
through `worktreeKeepModules` and `keepKeyOf`, the loader `release` already uses. PLM's copy takes
`sessionKey` from `hooks/lib/session-control-core-v1.js`, the companion computes the same `scv1_`
key itself (H7), and that key is what the state library stores as `ownerSessionId`. A key that
cannot be computed makes the whole state `measured: false`, rendered as not attributed. A run of
another owner is counted in `others`. When that owner is the running session's own key (`selfKey`,
computed the same lazy way through `selfSessionId`), the run is already carried and nothing more is
said. Every other owner's nonterminal run that classifies is listed in `foreign`: an earlier id of
the old session after a fork or a resume, or a third session. A `DONE` or `CANCELLED` run of the
old session is counted in `terminal` and named on no carrier. The reader also lists every
`autopilot-relocating-<id>.json` (`CLAIM_ENVELOPE`) through the same run-id gate, bounded read and
record checks, and keeps each nonterminal claim in `claims` whatever its owner, marked `owned` when
the old session owns it: an interrupted relocation can leave the claim as the only copy of its run,
so freeing its tree could delete the run.

**Classification.** A run is `own-tree` when its `workspaceRoot` is absent or equals its
`projectRoot`; `project-root-in-worktree` when its project root lies strictly inside its working
tree, as for a session recorded in a subdirectory of its worktree, and then `tree` names that
worktree; and `nested-workspace` otherwise, the origin-checkout layout. `innerChain` is a pending
stage of `TDD_RUNNING`, read from `blocked.from` for a `BLOCKED` run, because the adopt verb refuses
that run with exit 3. `workOrder` says that the record carries a `workOrder` member. `folder`, the directory that holds the record's state directory, names the
tree and the session root in every route text, since the recorded root may already be gone. Stage,
next action and blocked code are rendered only when they match a strict shape, and a pull request
only when its number is a positive integer of at most `PR_NUMBER_MAX` and its URL matches
`PR_URL_SHAPE`, the shape both `trail.mjs` copies spell for their own pull-request lines, and ends
in that number; it renders as the link `[#<number>](<url>)`. So no record value carries a control
character, a backtick or whitespace into a line.

**The route texts name exits that run.** The texts call the source session "the old session" and
the reader "this session", as the chips and linked-session sections do. Every cancel names
`/zensu:autopilot-release` from a session whose project root is `folder`, other than the old
session: the release verb reads only its caller root's state directory and refuses a caller that
owns the run. For the two layouts whose record moves with a worktree, `own-tree` and
`project-root-in-worktree`, the cancel works only before that worktree moves, and the texts say so;
`nested-workspace` keeps its record in place. Only an `own-tree` run that is no work-order run offers
the move route, because the adopt verb refuses a worktree relocation of a work-order run with exit
6: its plan lives in the `.zensu/plans` of its worktree. The other layouts and a work-order run say
not to move the worktree and to continue from a session rooted at `folder`. A relocation claim names
the one exit that finishes it, `/zensu:autopilot-adopt` from a session whose project root contains
`folder`, standing inside `folder`.

**Four carriers.** Both briefs render `## Autopilot run` after their linked-session reports, the
takeover before `## Recent instructions` and the handoff before `## Open threads`, and render
nothing when the tree holds no run of the session, no relocation claim, no unread record and no
foreign run; every claim gets one line naming its run, its stage and the exit that finishes the move.
`show` prints one `AUTOPILOT` line under the same rule. `show --json` and `takeover --json` carry the
whole state as `autopilotRuns`, the `foreign` and `claims` lists included. `release` pushes `autopilot-run` for
every owned nonterminal run, `autopilot-unreadable` for an unreadable record or a read cut at the
budget, `autopilot-unattributed` for an unattributed tree, `autopilot-foreign-run` for every
foreign run and `autopilot-claim` for every relocation claim, so a dry run lists them and `--apply`
exits 1. A transferred run left the tree or
changed its owner to the running session, so it no longer blocks.

**The companion's plan card is a further carrier, in the companion alone.** `takeover --plan`
(`.claude/rules/session-trail-plan-card.md`) names each owned run and each relocation claim above its state
heading by run id, cut at 48 characters, and stage, with the route `planCardRunRoute` words from the classes
above, and lists below that heading the record paths, the pending stage, blocked code and next action, the
unreadable records and each foreign run with its id, stage and record path. Its `planCardStage` renders the
text of this module's private `stageText`, so a change to that wording moves both.

**A foreign run is counted in the brief and named by `release`, and that split is the approved
contract.** AC-007 of the plan behind this change keeps runs of another owner out of the
`## Autopilot run` section, so the section only counts them, in one paragraph that says the
takeover does not carry them and that the user decides which session drives them; `show` names the
count, and the `autopilot-foreign-run` blocker names each run and stage with its route: ask the user
which session drives it, then continue it with `/zensu:autopilot-adopt` from a session whose
project root is `folder` or cancel it with `/zensu:autopilot-release` from such a session, and for
an inner chain the finish-or-cancel text. Without the blocker a fork's run in the tree let
`release --apply` hand that tree to Claude Desktop with the run inside. The companion's plan card names each
foreign run below its state heading as well, as data, because its item 7 asks the plan confirmation which
session drives them; AC-007 binds the brief's section alone.

**Slash commands only.** Every carrier names `/zensu:autopilot-adopt` and `/zensu:autopilot-release`
and never `--confirm` or `zensu-log.sh`, the rule `.claude/rules/autopilot-run-scope.md` states for
every model-read channel: a complete invocation would route around the one confirmation the guided
skills ask for. The unit file asserts it over every renderer and state.

**The adoption is the one question a takeover adds.** A takeover costs exactly one question, its
plan confirmation, but `/zensu:autopilot-adopt` can report a relocation only once the worktree has
moved, and it asks for its own yes after that report. Step 1 of `references/takeover.md` therefore
names that question in the confirmation and never lets the plan answer stand in for it, step 4
runs it after the move, and flows 4 and 5 of `references/handoff.md` carry the runs with it.

**The hand copies are pinned.** `TERMINAL_STAGES`, `RUN_RECORD_MAX_BYTES`, `RUN_ENVELOPE`,
`CLAIM_ENVELOPE`, `RUN_ID_SHAPE`, `RUN_ID_MIN`, `RUN_ID_MAX` and `RUN_SCHEMA_VERSION` copy the state
library's `TERMINAL`, `MAX_BYTES`, run-file envelope, the claim name `claimNameOf` builds,
`identifier`, its length bounds and the schema version `readState` requires; `STAGE_SHAPE` and `ACTION_SHAPE` must accept
every member of its `STAGES` and `NEXT_ACTION`. The case `the run vocabulary matches the state
library it mirrors` reads all of them but the schema version from
`hooks/lib/zensu-autopilot-state.sh`, and the schema-version case reads that one, so a one-sided
change fails there.

**Coupled sites.** The four sandboxes that stage `trail.mjs` copy the module beside it:
`mutant_path`, `cont_mutant` and the `OM` sandbox in `tests/structure/test-session-trail-verdict.sh`,
and the `TDZ` tree in `tests/structure/test-session-trail-lineage.sh`. The import line and the
`show` lines moved the two line citations of `docs/multi-repo-chains-spec.md` and
`docs/multi-repo-chains-overview.html`, which `T36` grades. The skill texts, in both copies: the
*Autopilot run* sentences of steps 1 and 4 of `references/takeover.md`, flows 4 and 5 of
`references/handoff.md`, the `show`, `handoff`, `takeover` and `release` rows of
`references/commands.md`, the `show --json` and `release` paragraphs of `references/disclosure.md`,
and the data-source row of `SKILL.md`; the companion's texts name Zensu PLM (`zensu@zensu`) as the
owner of the two slash commands. Outside the skill: the moved-tree procedure of
`skills/autopilot-adopt/SKILL.md`. Pins: the `AP` family in
`tests/structure/test-session-trail-verdict.sh`, which runs against each copy on one rebuilt real
repository with worktrees, and `AP10`, which requires both copies to render the same sections,
`AUTOPILOT` line, `autopilotRuns` and release blockers; and `tests/structure/autopilot-runs-v1.test.js`,
which imports the companion's copy and whose `registered` count and win32 skip ceiling in
`tests/profiles/unit-files.v1.json` are exact.

**Known gaps, accepted and named:**

- The folders come from the transcript. A session re-anchored to a sibling worktree, or one whose
  tree moved before the takeover ran, keeps its run where this reader does not look, and the
  carriers then say nothing. A tree that is gone holds no readable run either.
- A relocation claim lies in the tree that already moved, so it is named only when a folder the
  transcript records holds it, as for the session that ran the interrupted adoption from inside that
  tree (`AP11`). A takeover of the session that drove the run before the move reads the old path and
  finds nothing there.
- The record lives in a session-writable directory, so a planted record can make a carrier name a
  run or make `release` refuse. The adopt verb re-validates everything before it moves anything.
- The section tells the reader which route carries a run; nothing verifies that the route was
  taken. `release` is the backstop for a run that stayed behind in the old worktree only.
- `adopt`, the route that records a takeover after the fact, renders the step 4 destination advice
  but not the run section, so a takeover recorded only through `adopt` names the run when `release`
  stops for it, not before.
- Windows is unmeasured: the verdict suite runs there only in the weekly Windows Safety shard,
  and the unit file's link case skips where a symbolic link cannot be made.

**Version: `patch`.** Walked against `.claude/rules/runtime-lineage.md`: no context-record or
workflow-state field and no strict key set moves. The relocation rewrites two existing run-record
fields with values an older installation already accepts, a nested `workspaceRoot` included, and
writes no event. No hook is added, removed or re-matched, no `permissionDecision` and no attestation
changes, and no config key is added. The `--json` key and the `release` refusal are new outputs of
a skill CLI, and `skills/session-trail/scripts/session-lineage-v1.mjs` is untouched.
