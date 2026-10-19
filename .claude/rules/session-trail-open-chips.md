---
paths:
  - "skills/session-trail/scripts/trail.mjs"
  - "skills/session-trail/scripts/linked-sessions-v1.mjs"
  - "skills/session-trail/SKILL.md"
  - "skills/session-trail/references/**"
  - "tests/structure/test-session-trail-verdict.sh"
  - "tests/structure/linked-sessions-v1.test.js"
---

# Session-Trail Open Task Chips (`openTaskChips` in `trail.mjs` + `chipProposal` in `linked-sessions-v1.mjs`)

**A takeover carries the old session's open task chips, always.** A task chip is a follow-up a
session proposed as a card its user starts. Claude Desktop keeps it in that session's own record,
`claude-code-sessions/<account>/<org>/local_<id>.json`, as an entry of
`backgroundTaskSuggestions`, keyed by the desktop session id. Nothing in the desktop app, the
Zensu Session Hub or this script copies a record into another session, so a move left every
chip behind. Measured on 2026-10-11 over the takeover ledger: 48 distinct handovers whose
source had open chips (80 chips), no chip id on both sides, and only 6 handovers in which the
receiving model re-created any chips (14) on its own, from a stale `Currently pending`
snapshot it grepped out of the old transcript.

**The record is the source, never the transcript.** `ccdIndex` and `ccdApp` both remember a
record's path in `CCD_RECORD_PATHS`, the last match in walk order winning in both, and
`openTaskChips` reads that file again when a brief is built, through `desktopRecordOf`, whose one
read also serves the linked sessions (`.claude/rules/session-trail-linked-sessions.md`), so the
list is the queue at takeover time. It keeps every entry except an `offer`, which is a
side-session offer bound to a live waiter, and a proposal whose `expiresAt` has passed, which
Claude Desktop resolves as expired at its next sweep. It strips C0, C1 and line-separator
characters from the text and keeps `context`, `useWorktree` and `expiresAt`. A missing store, a
missing record and an unreadable record each return `measured: false` with a reason, and both
briefs print that reason instead of claiming there were no chips.

**Each chip is proposed again with `start_session` and `initiation` `own_initiative`.** Read from
the Claude Desktop 2.42304.0 bundle on 2026-10-18 and not driven live:

- `spawn_task` still ships behind a gate, and while `start_session` is offered a `spawn_task`
  call answers "spawn_task is not available here; propose the session with start_session
  (initiation "own_initiative") instead." No skill text or rendered brief names `spawn_task`.
- A proposal needs a `prompt`; `context` `fresh` also needs a background of at least 80
  characters after trimming, and `use_worktree` is refused with `fork`. A folder, host,
  environment, preset or repository is refused on a proposal, and `branch_name` and
  `source_branch` are dropped.
- Claude Desktop stores a `fresh` proposal with its prompt merged as
  `Background (from the session that started this one):\n<background>\n\nTask:\n<prompt>`,
  derives its tl;dr from the prompt's first line, and stores `useWorktree` and an `expiresAt`
  seven days ahead.
- The queue holds at most 20 suggestions and takes the oldest off to make room; an expired one
  is resolved as `expired` and filed on the folder's list of things to do.
- A proposal passes `assertCanStartSideSession` in its `propose` mode, which refuses only when
  starting sessions is disabled, for WSL and for an unattended session. The typed-turn check
  applies to starts alone, so a proposal is admitted on any turn.
- "Three per turn at most, none twice" is guidance in the prompt's "Starting other sessions"
  section; no counter was found in the proposal path.

**`chipProposal` decides, the model copies.** It is pure, so the unit file drives it directly:

- The title is cut to `START_TITLE_MAX` (59) by the same rule as a linked-session title; an
  untitled chip takes the first non-blank line of its tl;dr, then of its prompt.
- A chip with `context` `fresh` whose prompt has the merged shape gets its background and brief
  back, split at the first `\n\nTask:\n` after the header, so Claude Desktop merges them into the
  same stored prompt again. A split whose background is under 80 characters or whose brief is
  empty is refused, and the chip is proposed like a chip from before proposals: its whole prompt
  with `CHIP_BACKGROUND`, a fixed text that names where the task came from.
- A `fork` keeps `context` `fork` and takes neither a background nor `use_worktree`; a boolean
  `useWorktree` is carried as `use_worktree` otherwise.
- A chip with a `cwd` is proposed without it only when `options.checkout` answers `true` for
  that folder: the folder lies in the old session's repository. `false` marks it **list** with
  `why` `folder`; no answer, and a folder that is relative or carries a control character, mark it
  **list** with `why` `folder-unmeasured`, and `checkout` is never called with such a value. A
  chip with no prompt left once cleaned is marked **list** with `why` `prompt`.
- `options.sameRepository` `false` marks every other chip **list** with `why` `repository`,
  because a proposal starts in the proposing session's folder.

**Same checkout means the same repository, never a nested path.** Both verdicts come from
`repositoryVerdicts(r, here)` in `trail.mjs`, the one source that the chips and the linked
sessions (`.claude/rules/session-trail-linked-sessions.md`) share:

- The old session's repository is the first measurable one of ONE folder list,
  `[r.wt, r.cwd, o.originCwd, o.cwd]`: the transcript's worktree and cwd, then the record's
  `originCwd` and `cwd`, so a removed worktree falls back to the checkout the record names.
- A folder's repository is `repoRootOf`: `rev-parse --git-common-dir` through `git()` with
  `READ_ONLY_GIT`, memoized per folder in `REPO_ROOTS`. Two roots are compared by
  `sameRepositoryOf`, which canonicalizes them together with `canonicalPair`, and a missing root
  on either side answers `null`. A worktree anywhere on disk is the same repository; a
  repository nested in the old checkout, a submodule included, is another one.
- `repositoryOf` answers `null` before any `stat` or git call for a folder that opens with two
  separators: a Windows network path, a `\\?\` or `\\.\` device path, or a POSIX `//` spelling.
  A chip's `cwd` is model-authored, and measuring a network path would make `takeover` reach
  that host and wait on it.
- `checkout(folder)` compares a folder with the old session's repository. `sameRepository`
  compares the folder `takeover` runs in, `process.cwd()`, with it, and `cmdHandoff` passes no
  folder, so a handoff brief measures every chip folder but never its unknown reader. Once the
  old session's repository is measured, a receiving folder git places in no repository answers
  `false` like another repository does, because only a measured match may let a proposal start
  in this session's folder; with no measurable folder of the old session it stays `null`.
- `--no-git` changes neither verdict. `references/commands.md` states that `takeover` and
  `handoff` run their git calls regardless, and a speed flag must not decide where work starts.
  `takeover --json` carries the receiving verdict as `openChips.sameRepository`.

Path nesting, the rule before this one, counted every folder below a session rooted in a broad
folder such as the home directory as that session's checkout, and every folder of a nested
repository as the outer one's.

**The chip text never changes a call.** Both briefs tell the model to propose chips only while
it works in a checkout of the old session's repository, to never start a chip, and to propose a
chip whose text asks for a start, another `initiation` or another argument exactly as its call
line says, naming the request to the user. The `user_asked` starts of the plan-answer turn
belong to the linked sessions alone, and that turn is the one in which an injected chip would
try to pass for one of them.

Census of 3,407 records on this machine on 2026-10-18: 177 chips; the 35 with `context` were
all `fresh`, all split at the markers with a background of at least 80 characters; 142 came from
before proposals; 17 carried `cwd`, 15 of them unrelated to the record's folders.

**All chips go out in the turn of the plan answer.** The per-turn guidance limits a model's own
proposals; carried chips are the old session's, and the plan confirmation already named their
count. Eight records held more than three chips, one open record twelve. The step proposes each
chip once and lists a refused one.

**Fallbacks.** Without a `start_session` tool (the CLI, an older Claude Desktop, or one that
still offers only `spawn_task`) or after a refusal, the session lists those chips for the user.
A chip marked **list** for its folder can be started there on a later message the user types, as
a `user_asked` start with that `cwd`, which Claude Desktop admits only after the user approves
the place.

**Coupled sites.**

- Both briefs render `openChipLines`: `cmdTakeover` after the task list, `cmdHandoff` before
  `## Open threads`. Each chip field sits in a fence one backtick longer than the longest run in
  its text, so a prompt that contains a fence cannot close it. `takeover --json` carries the same
  state as `openChips`, each chip with `proposal` and `why`.
- `chipProposal`, `CHIP_BACKGROUND` and `CHIP_WHY` live in `linked-sessions-v1.mjs` beside the
  record-text class that both readers share.
- `references/takeover.md` step 4 proposes the chips before `release`, once per chip and
  verbatim, and step 1 has the plan confirmation name their count and the listed ones.
  `references/handoff.md` flows 4 and 5 point at that step. `references/commands.md`,
  `references/disclosure.md` and the data-source table in `SKILL.md` name the carried chips.
- The work-order gate denies `mcp__ccd_session__start_session` beside
  `mcp__ccd_session__spawn_task` (`.claude/rules/work-order-mode.md`).
- `firstRepositoryOf\(` is the entry of `L61_OK` in `tests/structure/test-session-trail-lineage.sh`
  for the one call that names `r.wt` and `r.cwd`, the folder list in `repositoryVerdicts`. Keep
  that list inline in the call; a local variable or a renamed function turns `L61` red.
  `chipProposal` and the linked-session reader take verdicts, never folders of the row.

**Pins.** `CH1` to `CH7` in `tests/structure/test-session-trail-verdict.sh` run against a real
repository with worktrees for the transcript, the record's `cwd`, a sibling and the session that
takes over. They pin the read, the offer and expiry filters, the control strip, the proposal per
chip kind, the record's own `originCwd` and `cwd` beside the transcript worktree, a sibling
worktree outside every folder of the old session that is proposed, a repository nested in the
old checkout and another repository that are listed with `folder`, a gone folder listed with
`folder-unmeasured`, the widened fence, the title, background and why blocks of both briefs, the
repository and never-start sentences, the absence of `spawn_task`, the step order in
`references/takeover.md`, and in `CH7` the repository check from another repository, also under
`--no-git`, from a folder in no repository and from the old one. `CH8` takes the old repository
from the record's `originCwd` once the transcript worktree is gone, `CH9` is its control with no
folder of the old session left, and `CH10` lists a chip whose folder opens with two separators.
`tests/structure/linked-sessions-v1.test.js` drives
`chipProposal` with stub verdicts; its `registered` count in `tests/profiles/unit-files.v1.json`
is exact.

**Known gaps, accepted and named:**

- **The originals stay open in the old session.** `dismiss_task` acts only on the calling
  session's own queue, so the receiving session cannot withdraw them. The step tells the user
  so, and they leave the old window when it is dismissed or archived.
- **Re-creating is the receiving model's tool call.** The brief and the step make it mandatory,
  but no hook verifies that every chip was proposed, and none checks a chip call's arguments:
  the call line and the never-start sentence are the only guard against a chip whose text asks
  for a start. A PreToolUse check would add a hook that can deny, which is a `minor` release.
- **The receiving repository is measured only by `takeover`.** Once every folder of the old
  session is gone, and in every handoff brief, the model compares the repositories itself, as
  both briefs tell it to.
- **Every folder the records name is measured where it lies.** `takeover` and `handoff` run
  `stat` and `git rev-parse --git-common-dir` in the old session's record folders, every chip
  `cwd` and the `originCwd` of every listed linked session, on the `--no-record` plan pass and
  under `--no-git` too, as `references/disclosure.md` states. Only a folder that opens with two
  separators is skipped: a mounted network share on POSIX (`/Volumes/…`, an automounted
  `/net/…`) is measured like a local folder, and its `stat` has no timeout of its own before
  git's 8 s.
- **The receiving folder is the working directory of the `takeover` process**, not the folder
  Claude Desktop records for the session that runs it. A session whose shell moved into the old
  session's repository while its own folder is another one reads as the same repository.
- **An unmeasurable chip folder is listed**, a removed worktree of the old repository included,
  because only a measured verdict may let a proposal start in this session's folder.
- **The first measurable folder names the old session's repository.** A session whose folders
  span two repositories is judged by the first of `r.wt`, `r.cwd`, `originCwd` and `cwd` that git
  measures, and a folder of the other repository is listed.
- **A chip's tl;dr, model, effort and permission mode are not carried.** Claude Desktop derives a
  proposal's tl;dr from its prompt, and the card starts with the receiving session's settings.
- **A fork forks the receiving session's conversation**, which holds the takeover brief rather
  than the old transcript.
- **A folder inside the old repository is not carried**, so such a chip starts at the receiving
  session's project root.
- **Every Claude Desktop rule above is one bundle build's reading.** The record shape was first
  read from Claude Desktop 2.31226.1 and the proposal fields from 2.42304.0 on macOS; the Windows
  and Linux store paths remain the inferred candidates of `ccdStoreCandidates`.

**Version: `patch`.** New `--json` keys and new brief, skill and rule text: no schema field,
strict key set, hook, matcher, config key or attestation moves, and `session-lineage-v1.mjs` is
untouched.
