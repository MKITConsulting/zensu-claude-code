---
paths:
  - "plugins/session-hub/skills/session-trail/scripts/trail.mjs"
  - "plugins/session-hub/skills/session-trail/SKILL.md"
  - "plugins/session-hub/skills/session-trail/references/takeover.md"
  - "plugins/session-hub/skills/session-trail/references/commands.md"
  - "plugins/session-hub/skills/session-trail/references/disclosure.md"
  - "plugins/session-hub/skills/session-trail/references/handoff.md"
  - "plugins/session-hub/skills/session-trail/references/gotchas.md"
  - "plugins/session-hub/skills/session-trail/scripts/autopilot-runs-v1.mjs"
  - "tests/structure/test-session-trail-verdict.sh"
  - "tests/structure/test-session-trail-skill.sh"
  - "tests/structure/test-session-trail-lineage.sh"
  - "tests/structure/test-session-hub-plugin.sh"
---

# Session-Trail Plan Card (`planCard` in `plugins/session-hub/skills/session-trail/scripts/trail.mjs`)

**One copy.** Only the companion's `/session-hub:session-trail` carries the plan pass. PLM's frozen
`/zensu:session-trail` takes fixes only (`.claude/rules/session-hub-companion.md`), so its `takeover` has no
`--plan` and its `references/takeover.md` keeps the flow of before.

**Why it exists: the wait before the plan confirmation was model time, not script time.** Measured on
2026-11-25 on one Mac over the 127 takeover runs of the 30 days before that reached an `AskUserQuestion`:

- Prompt to question: median 388 s (p25 317 s, p75 494 s). 87 % of it was model time, which followed the
  output tokens almost linearly (r = 0.975, about 100 tokens per second).
- 79 % of the wait lay after the script had printed the brief: median 284 s, 10 model round trips, 25k output
  tokens. `show` took 3 to 4 s and `takeover --no-record` 1 to 3 s.
- After the brief a run made a median of 10 Bash calls: git in 90 % of runs, process or registry checks in
  83 %, `gh` in 79 %, transcript greps in 72 %, a second `trail.mjs` call in 60 %.
- The brief was 45 to 55 kB against a largest inline tool result of 27,820 characters, so 83 % of runs piped
  or redirected the plan pass and read it back in a further round trip.
- 79 kB of references were read first: `takeover.md` in 78 % of runs, `commands.md` in 75 %,
  `disclosure.md` in 74 %.

**The decision.** `takeover <selector> --plan` prints a **plan card** in place of the brief, and the flow up
to the question is two messages at most:

1. One message reads `references/takeover.md` and runs the plan pass beside it: `takeover <selector> --plan`
   and the dry run `release <selector>`, each as a call of its own, plus the `hooks.bashWriteGate` read when
   Zensu PLM runs in the session.
2. At most one further message holds the checks the card lists, and nothing else. One check may take a
   message of its own: the `--json` run of the release dry run after a `BLOCKED` answer, with the read of
   `references/disclosure.md` that `SKILL.md` asks for before a `--json` call.

Then the model asks. Bounding the checks is sound because the card is the session's own measurement, the run
after the yes (`takeover --force`) measures everything again, and step 4 of `references/takeover.md` verifies
each remaining fact before the step that relies on it.

**The release dry run stays a command of its own.** It measures the old worktree with `git status` and its
ignored paths, which took 22 s on one worktree with a large ignored build directory (measured 2026-11-25),
and it runs beside the plan pass in the same message, so it adds no round trip. Folding it into the card
would put that wait on every plan pass and would need the release logic outside `cmdRelease`.

**What the card holds, in this order.**

- The caution `PLAN_CARD_CAUTION` as its first line, then the header: the time of the measurement, the
  session, one `- note:` line per line `resolve` printed for this run, such as the note of a selector that
  also matched the running session, and an `- incomplete:` line with the count of skipped records, which
  the closing `NOTE` line repeats.
- A block the tool renders: `## What the plan confirmation covers`, `## Checks before the question` and
  `## After the yes`. The first lists the verdict level and reason; the record disclosure with the three
  ways to decline it, or the state in which the forced run writes no record; the create line of the route,
  whether a move route exists and where the command ran when that was outside the old session's
  repository; the count of changed or untracked paths, or `not measured`; the chip tally; one line per
  listed linked session with its decision and reason; the `--linked-start` value for a yes that changes
  nothing; the Autopilot runs; the count of unread reports; and the two items it does not measure, the
  release blockers and another plugin's write rules.
- `## The old session's state`: first the sections the tool measured, each a list of bounded lines (Source,
  plan documents, task list, open task chips, linked sessions, Autopilot run records, git state), then the four
  sections of verbatim text (original objective, state at last compaction, recent instructions, what it said
  last), clipped, as data. The tool's lists come first so that a list a verbatim section imitates follows the
  real one, which the plan-document check and item 6 point into.

The card leaves out the carry-over recipe, the `worktree move` command line, the start blocks of the linked
sessions, the chip call blocks, the diffs, the list of touched files, task descriptions, report bodies and
withdrawn prompts. The brief of the `--force` run prints each of them, after the yes.

**The block above the state heading holds only what the tool computed or bounded at the source.** Every text
or path that another session, or a file in its tree, chooses is printed below that heading, which the
caution names as the boundary. Above it:

- A session id is spelled only when it matches `PLAN_CARD_ID`, the lowercase UUID shape of a Claude Code
  session id. A transcript's file stem is never validated as one, so any other id, a stem of hyphenated words
  included, is shown in the Source section, and every command spells `<selector>` in its place.
- A pull request gets a `gh pr view` line only when its address matches `PLAN_CARD_GITHUB_PR`. The line asks
  for `state,mergedAt` and never the title, which is free text of that repository, takes its `#N` label from
  the number the address ends in, because `safePr` does not hold the recorded number to the address, and
  applies only when that address names the repository the takeover continues. An address on another host
  gets a check line that names no address and no command.
- A linked session appears by its `cont-` handle, kind and decision, never by its title. The
  `--linked-start` value is built from the measured decisions (`linked.sessions`) and never read back from
  a rendered line, because the brief renders a title as a line of its own.
- An Autopilot run, and an interrupted move, appears by its run id, cut at `PLAN_CARD_RUN_ID_MAX` (48)
  characters (`planCardRunId`), its stage and its pull-request number, each bounded by shape where
  `autopilot-runs-v1.mjs` reads it, and by the route its layout allows (`planCardRunRoute`). Those shapes
  admit up to 128 characters of id and blocked code, and a relocation claim is kept whatever its owner, so a
  file in the old tree could otherwise fill the block with tokens of its own. The whole id, the pending stage,
  the blocked code and the next action (`planCardStage`), a record path, a session root, a working tree and the
  name of an unreadable file are listed under `### Autopilot run records`.
- The header notes are the `NOTE` lines `resolve` printed for this run, each collapsed to one line of at most
  600 characters (`oneLine`); a buffered line of any other shape is dropped. The notes of the linked-session
  read are the leading `_…_` lines `linkedSessionLines` prints after its heading, up to the first other line
  (`planCardLinkedNotes`), so a changed tally line can never pull a session block above the heading.

**States are reported as measured.**

- `planCardStatusPaths` asks `git status` once more when the first answer listed nothing, and the card
  prints `not measured` when that call does not answer. `gitState` folds a failed or timed-out status into
  zero paths, and `H16` holds `gitState` equal in both copies, so the card measures beside it.
- `planCardRecord` names the state in which the forced run writes no record: no `CLAUDE_CODE_SESSION_ID`,
  the running session selected, or `ZENSU_SESSION_LINEAGE=off`.
- `planCardVerdict` names `FREE` for its no-hazard sentence and the two `PROBABLY_FREE` cases for theirs;
  every other level, `BUSY` and any level added later, gets the disclosure sentence, because the doctrine's
  owner is `ADVICE` and `T18` checks level coverage against that table alone.
- Item 7 says the Autopilot runs were not measured when the old worktree is gone, because a run record lives in
  the tree that minted it and moves with it; `none found in its tree` is said only for a tree that was read.
- The move route is offered only when `repositoryVerdicts` answers `sameRepository` `true` for the folder
  the command ran in. Otherwise the route item says that the command ran outside the old session's
  repository, or that this could not be measured, and that the create line works only from a checkout of
  that repository.
- `planCardFlags` names `--repo`, `--days`, `--no-git` and `--config-dir` when the plan pass took them, and
  both follow-up commands say to pass them again. A new scan flag or global operand needs an entry there.

**Cuts and selections keep what the confirmation needs.**

- `planCardListed` lists linked sessions marked start first, then if named, later and stays, once the list
  exceeds its cap, and the cut line tallies the unlisted ones by decision. The `list_start_targets` check reads
  the listed sessions alone, so the line it points at is always printed.
- A cut chip list keeps every chip marked list, up to `PLAN_CARD_LIST_CHIPS` (20), the most the Claude
  Desktop queue holds, cuts proposals only and tallies the unlisted ones by mark (`planCardChips`), because
  item 5 has the confirmation name each chip marked list with its reason, as step 1 of
  `references/takeover.md` asks, and a run from another repository marks every chip list. Past that bound,
  which no record Claude Desktop writes reaches, item 5 counts the rest and names the `--no-record` run that
  lists them, as item 6 does for linked sessions.
- A cut list of unreadable Autopilot records names `the Autopilot run records` on the shortened line, because
  the brief lists every one; a cut list of foreign runs does not, because the brief only counts them.
- Tasks that were not completed are listed first once the list exceeds its cap, and the unlisted ones among
  them are named by id, at most `PLAN_CARD_OPEN_IDS` (40).
- `planDocSelection` is the one selection of plan documents for the brief and the card: the documents
  modified inside the session window, marked `touched during this session`, or else the three newest with
  the caveat. The card lists the plan-document check only for a marked one.
- The count of further commits comes from `g.ahead`, because `gitState` keeps 30 commits.

**The size bound is `PLAN_CARD_MAX` = 24,000 characters**, below the largest inline result measured, so the
card arrives in one tool result. `planCard` renders with the first level of `PLAN_CARD_CAPS`, four levels of
per-section caps, that fits the bound less the closing `NOTE` line (`skippedNote()`). When the last level
still exceeds it, the card is cut after the last whole line that fits and ends with `PLAN_CARD_CUT`, so card
and closing note together stay within the bound. A section the caps shortened is named on the
`_Shortened in this card: …_` line. The data note under the state heading is built after the sections, and it
points at that line and promises the fuller text of a shortened section only when the line is there. Measured
on 2026-11-25: about 16,000 characters for a real session with
a compaction summary and five long prompts. Measured on 2026-11-26 on the suite's fixtures: about 8,700 for
the LS fixture with 17 linked sessions, about 23,900 for the oversized fixture, which the second level
fits, and about 10,800 for that fixture at the last level.

**`--plan` is the companion's flag of `takeover` alone.**

- `cmdTakeover` refuses it together with `--force` as its first statement, then switches the record off, so
  `--plan --json` prints what `--no-record --json` prints.
- The card returns from an early return placed after every measurement and render and ahead of
  `recordTakeoverEdge(`. The three advice renders can throw, and `L70n` requires them ahead of the edge
  write, so the return sits below them.
- A text plan pass, `--plan` without `--json`, takes the `NOTE` lines `resolve` printed out of the output
  buffer for the card header and skips `gitDiffText`, whose four reads the card never prints. A `--json` run
  reads no plan folder, because `planDocSelection` runs only without `--json`, as PLM's copy calls
  `findPlanDocs` only after its `--json` return; otherwise an unlistable plan folder would raise `skipped` in
  one copy's payload alone.
- `parseArgs`, `COMMAND_FLAGS` and `refuseForeignFlags` each name the flag; `L66d` compares the parse count
  with the scope count.

**Coupled sites that move together.**

- The value line of the card and the one `linkedSessionLines` renders for the plan brief are two renders of
  one sentence, and `PC2` requires them equal. `planCardLinkedNotes` reads the leading `_…_` notes
  `linkedSessionLines` prints right after its heading, up to the first other line, and nothing below it.
- The create line and the move test read `worktreeAdvice` through `WORKTREE_ADVICE_COMMAND`, the way
  `whereAdviceLines` finds the move command.
- `planCardRunRoute` words the route classes of `.claude/rules/session-trail-autopilot-runs.md`: an inner
  chain, a layout or a work-order run that keeps its worktree, and an own-tree run with and without an
  offered move route. `planCardStage` renders the text of `stageText`, which `autopilot-runs-v1.mjs` keeps
  private and H4 holds byte for byte to PLM's module, so a change to that wording moves both.
- `planCardRecord` mirrors the reasons for which `recordTakeoverEdge` writes nothing.
- The `--force` refusal for a missing `--linked-start` names item 6 of the plan card beside the Linked
  sessions section of the plan brief.
- The skill texts: workflow 3, the brief bullet under Safety and the three `Read references/…` sentences of
  `SKILL.md`; the opening line, step 0 with its flags paragraph and step 1 with its two paragraphs ahead of
  the verdict paragraph and its sentence on what a yes to a card-built plan covers in
  `references/takeover.md`; the `takeover` row, the flag list and the `--no-record` paragraph of
  `references/commands.md`; the plan-card bullet, the Autopilot sentence of the `show --json` paragraph and
  the ledger-write bullet of `references/disclosure.md`. The number 24,000 in `references/takeover.md` and
  `references/commands.md` is `PLAN_CARD_MAX`, and the number 48 in the plan-card bullet is
  `PLAN_CARD_RUN_ID_MAX`; `T42` reads both from the script.
- Flow 5 of `references/handoff.md` keeps `takeover <selector> --all --no-record` as its plan pass, which
  `T23` pins, and its step 3 says that the card's bound on checks before the question does not apply to it;
  the bound sentence of `SKILL.md` names workflow 3 for the same reason.
- The four `H16` allowlist reasons in `tests/structure/test-session-hub-plugin.sh` name the plan pass.

**Constraints on the renderer, each held by an existing check.**

- Every session-derived value on an `L.push(` line goes through `briefPath(` inside its own interpolation
  (`T29`), and a line that names `r.wt`, `r.cwd`, `r.branch` or `r.title` carries one of the spellings `L61`
  admits. `planCardStatusPaths\(` is the entry of `L61_OK` in
  `tests/structure/test-session-trail-lineage.sh` for the one call that hands `r.wt` to the second status
  read. Keep that call on a line of its own, so the entry admits nothing beside it.
- `planCardLines` owns its own `const L = [];`. `cmdTakeover` holds no second one ahead of the brief's, and
  nothing new names `BRIEF_DATA_CAUTION` (`T29c`).
- No further `print(JSON.stringify(` (`T22`), `activityVerdict(` line (`T25`) or `plmGateCaution(` (`T40`),
  and no `briefShellArg(` or `adviceLeg(` in the new functions (`worktree-advice-v1.test.js`).
- The card is the fourth caller of `isUnmeasuredProbablyFree(` and the fourth text renderer of
  `QUEUE_WITHDRAWALS_UNFILTERED`. `T24e` and `T24k` count the companion's four and pin the card's call, and
  the withdrawal bullet of `references/gotchas.md` names the card among the readers of the prompt listing.
- No new `export` statement (`T24h`) and no new module: four sandboxes stage `trail.mjs` with its siblings by
  name.
- The new top-level names exist in the companion's copy alone, so `H16` compares none of them.

**Pins.** `PC1` to `PC16` in the PC family of `tests/structure/test-session-trail-verdict.sh` and `PC17` and
`PC18` in its AP family, which holds the Autopilot fixture, drive the card:

- `PC1` to `PC8`: the first line and the unchanged ledger with and without `--no-record`, the block order
  and every tool-block value with the other session's text only below the state heading, the note of the
  linked-session read under item 6, the measured sections ahead of the verbatim ones, the data note without
  its shortened clause on a card that shortened nothing and with it, right above the shortened line, on one
  that did, the absences against the plan brief of the same sessions, the size bound and the named shortened
  sections, the refusals, `--plan --json` byte for byte, the all-stay and fork-only families, the verdict line
  per level, a gone directory with its unmeasured Autopilot runs, unread desktop records and the GitHub
  pull-request check without the title.
- `PC9`: a linked-session title that opens with the value sentence, a saved environment without a name, and a
  session with no open linked session whose folder holds an unreadable record, whose `none open` item is
  followed by that note.
- `PC10`: the self-skip note and the skipped count in the header.
- `PC11`: an id that is no session id, a file name of hyphenated words included, a pull request on another
  host, a recorded number that differs from the address, the `--json` run after `BLOCKED` and the flags both
  follow-up commands name.
- `PC12`: a folder in which `git status` does not answer, an old worktree with more changed and untracked
  paths than `gitState` keeps, a plan pass run from another repository and from no repository, and the three
  states without a record, each with its forced run and an unchanged ledger.
- `PC13`: starts listed ahead of stays, open tasks ahead of completed ones, the unlisted open ids past their
  bound of 40, plan documents inside and outside the session window against the plan brief, and 40 commits
  ahead.
- `PC14`: a planted bound of 8,000 against a copy that renders the last cap level alone: the cut card is a
  prefix of whole lines of that render, it keeps the state heading and `### Source`, no further line would
  fit, and the cut line precedes the note.
- `PC15`: a logging git wrapper shows no diff of the working tree, the index or the branch and no untracked
  listing in a plan pass, and shows them for the plan brief. It is skipped on Windows.
- `PC16`: the remaining lines: the archive note, the stop cause, final and recovered, the count of withdrawn
  prompts, the truncated-read line, the count of instructions left out, the git state and the chip list named
  as shortened, a cut chip list that keeps every chip marked list and tallies the cut proposals by mark, also
  from another repository, where every chip is marked list, a planted queue bound of 4 that counts the rest
  in item 5 with the run that lists them, and the linked sessions the command itself does not list. The chip
  list is cut only at the last cap level, so that part runs the copy `PC14` plants.
- `PC17`: each Autopilot route class, a working tree that is a sentence, a run file whose name has spaces,
  a run id past `PLAN_CARD_RUN_ID_MAX`, the pending stage, blocked code and next action only below the state
  heading and, on the copy `PC14` plants, the runs and the unreadable records past the cap.
- `PC18`: an interrupted move with the exit that finishes it, and a work-order run that keeps its worktree.
- `OM10` renders the card of a session whose ledger read refused a record and requires the ledger note above
  the state heading.

`PC2-control` plants a copy whose notes reader returns nothing, `PC4-control` one without the bound and
`PC6-control` one whose plan pass keeps recording. `T42` in
`tests/structure/test-session-trail-skill.sh` pins the skill sentences, the step order and the source shape,
with ten planted controls.

**Known gaps, accepted and named.**

- **The effect on the wait is not measured yet.** No takeover has run through the new flow. Expected from
  the measured parts: about 95 s. Measure it on real moves after the companion release, with the transcript
  recipe of the baseline, as an observation and not a gate.
- **The bound is text.** No hook counts the calls a session makes before its question.
- **The card shows the head of each text.** `extractCompaction` keeps the first 8,000 characters of the last
  compaction summary, so neither the card nor the brief carries that summary's closing sections.
- **A `BLOCKED` release dry run costs a second run with `--json`**, as step 0 says, and `SKILL.md` asks for
  `references/disclosure.md` before a `--json` call.
- **A text of the old session can imitate a card heading.** The tool block comes first and the caution names
  the state heading as the boundary; the free text below it is unfenced, as in a brief. Below that heading
  the tool's lists come ahead of the verbatim sections, so the plan-document check and item 6 meet the real
  list first; a verbatim section can still imitate a list that follows it.
- **A plan pass still runs one `git diff`,** the `--stat` of `gitState`, whose output the card does not
  print. `gitState` is shared with PLM's frozen copy, so the plan pass skips only `gitDiffText`.
- **A clean old worktree costs a second `git status`,** because `gitState` cannot say whether its own call
  answered.
- **`briefPath` clips a path at 200 characters,** so the card cuts a longer record path of an Autopilot run.
  The brief after the yes names the run's route in full.
- **The hard cut keeps whole lines, not whole sections.** Measured on the oversized fixture at the last cap
  level, the block the tool renders took about 5,500 characters, and the 8,000-character cut of `PC14` fell
  in the task list. Because the measured sections come first, a hard cut drops the verbatim text before
  them, and the brief after the yes prints it.
- **The flow of PLM's frozen copy and of handoff flow 5 is unchanged.** Flow 5 keeps its own checks before
  its question, and its step 3 says that the card's bound does not apply there. Moving flow 5 onto
  `takeover --plan`, so the skill has one plan pass, is open: it re-points `T23` and handoff steps 2 to 4.
- **Every measured request ran at effort `max`**, an environment setting of the measuring machine. The
  effect of a lower effort on the wait was not measured.

**Version: `minor` for the companion** (a new flag of its skill script), released through
`.github/workflows/release-session-hub.yml`. PLM's tree does not change.
