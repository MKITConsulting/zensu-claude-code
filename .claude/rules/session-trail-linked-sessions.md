---
paths:
  - "skills/session-trail/scripts/linked-sessions-v1.mjs"
  - "skills/session-trail/scripts/trail.mjs"
  - "skills/session-trail/handover-contract.json"
  - "skills/session-trail/SKILL.md"
  - "skills/session-trail/references/**"
  - "tests/structure/linked-sessions-v1.test.js"
  - "tests/structure/test-session-trail-verdict.sh"
---

# Session-Trail Linked Sessions (`linkedSessions` in `trail.mjs` + `skills/session-trail/scripts/linked-sessions-v1.mjs`)

**A takeover continues the old session's open linked sessions from the session that takes it
over.** A linked session is one the old session started in Claude Desktop: its record carries
`spawnedFrom` with the old session's `local_` id. Read from the Claude Desktop 2.42304.0 bundle on
2026-10-18 and not driven live: Claude links a child to its parent only inside one account's
process and offers no way to move a link, and `start_session` admits a start only on a turn its
user typed. So the session that takes over starts each linked session again with `start_session`,
in the turn its user confirms the plan, and Claude links the new one to it. Each started session
takes its old counterpart over with the same flow and confirms its own plan with its own user, so
the tree is rebuilt one level per answer.

**The records are the source.** `desktopRecordOf` reads the old session's record once and serves
`openTaskChips`, `linkedSessions` and `unreadReports` from that one read, which keeps `TL2`'s bound
of two parses of the target's record. `familyRecords` reads every `local_*.json` in the same
`<account>/<org>` folder as bytes and parses only the files that contain `"spawnedFrom"`; a file
that cannot be read or parsed counts into `SKIPPED` and into the state's `unreadable`, and the
brief says a linked session may be missing. `familyWalk` lists the children in `createdAt` order,
walks through archived ones so their open children attach to the session taken over
(`throughArchived`), never enters a `lineageDetached` one, and never lists anything below an open
child, whose own continuation handles it. A missing store, a missing record, an unreadable record,
a folder that cannot be listed and a record without a `local_` id each return `measured: false`
with a reason, and both briefs print it.

**Who starts, decided in `decideLinked`, first match wins:**

| `why` | Decision | When |
|---|---|---|
| `no-session-id` | stays | the record carries no Claude Code session id, so nothing can take it over |
| `self` | stays | it is the running session (`CLAUDE_CODE_SESSION_ID`), by its current or a prior id |
| `btw` | stays | a side question, which Claude archives once it settles |
| `ssh` | stays | `sshConfig` is set, or its saved environment is an SSH preset |
| `continued` | stays | a `confirmed` lineage edge leaves its current or a prior (`priorCliSessionIds`) id |
| `started` | stays | the running session has an open child with the handle `cont-<8 hex>` of this run |
| `place` | if named | its `originCwd` is missing, relative or carries a control character, so no start can be placed in its repository |
| `fork` | if named | a user fork, started only when the user names it in the plan answer |
| `ledger-unread` | if named | the ledger read had a directory error or hit its record cap |
| none | start | a side or task-chip session, the first `LINKED_START_CAP` (8) in creation order |
| `cap` | later | the rest, started only on a later message the user types |

Cloud and Remote Control sessions have no `local_` record in the store, so they never appear.
The list is bounded at `LINKED_LIST_MAX` (64) and says how many it leaves out.

**The start call is rendered by the script, never composed by the model.** `initiation`
`user_asked`, `context` `fresh`, `title` (the old title with control characters stripped,
collapsed to one line and cut to 59 characters, because the tool description says "Under 60
chars"), `name` `cont-` plus the first eight hex digits of the old run's UUID (the handle the Hub
joins on), `use_worktree` true, and the `prompt` and `background` texts from `startPrompt` and
`START_BACKGROUND`. `cwd` is the child's `originCwd`, left out only when `sameCheckout` and
`sameRepository` are both `true`, because a start without `cwd` runs in the folder of the session
that starts it. No `source_branch` and no `branch_name`, because a place field costs a place
approval per start. `decideLinked` asks the checkout verdict only for the sessions it lists, the
first `LINKED_LIST_MAX`.

**The checkout is the repository, never a nested path.** `sameCheckout` is the `checkout` verdict
of `repositoryVerdicts` in `trail.mjs`, the one the chips use
(`.claude/rules/session-trail-open-chips.md`): the git common directory of the child's
`originCwd` against the old session's repository, the first measurable one of
`[r.wt, r.cwd, o.originCwd, o.cwd]`. A worktree anywhere on disk is the same repository, a
repository nested in the old checkout is another one, and a folder git cannot measure answers
`null`. The module validates the folder with `folderOf` before it asks, so git never sees a relative
or control-character value, and `repositoryOf` never measures a folder that opens with two
separators, such as a Windows network path. Path nesting, the rule before this one, read only
`originCwd` on both sides and counted every folder below a session rooted in a broad folder as its
own checkout.

**The receiving repository decides the cwd, the same verdict that lists chips.** `sameRepository`
compares the folder `takeover` runs in with the old session's repository and travels as
`linkedSessions.sameRepository`. From another repository, or from a folder git places in no
repository once the old repository is measured, it is `false`, so every start passes its folder,
the old repository's sessions included, and the brief tells the user why with an
`it starts in its own folder` line under the checkout line. `cmdHandoff` never measures its
unknown reader, so in a handoff brief every session with a usable folder carries it as `cwd`, at
the cost of one place approval per start. `--no-git` changes no verdict, because `takeover` and
`handoff` run their git calls regardless. `preset` is the model's to add: the brief names the saved
environment from `ccd-session-presets.json` beside the store (`byAccount[<account>].presets`, the
id in `startedFromEnvironmentId`), and the model passes it only when `list_start_targets` lists a
local preset of that name, leaving `cwd` out then.

**The takeover brief names every folder it leaves out, because a brief outlives the process that
measured it.** `sameRepository` measures the `takeover` process, while a brief written to
`TAKEOVER_TARGET` can be opened later by a session in another repository. So a start the
measurement left without `cwd` lists its folder in a `folder` block under the line `it starts
without cwd, because the takeover that printed this brief ran in the old session's repository;
pass the folder below as cwd when this session works outside that repository`, and the section's
lead states the same rule. The omission itself stays in both carriers: `references/takeover.md`
step 4 tells the session that ran `takeover` to use the brief its `--force` run printed, and that
session starts such a session in a worktree of its own repository with no place approval.
`cmdTakeover`'s comment keeps `writes` and `continuation` out of the markdown for the same
reason; a start call cannot be left out, so the brief carries the folder and the condition
instead.

**`continuationsStartedBy` is a guard the spec did not name.** Without it a second takeover run
after the starts, such as the one that serves a later message for a session marked **later**,
offers the started sessions again, because their edges exist only once their own users confirm.

**Reports not yet read.** `unreadReportsOf` takes the old session's `queuedSideSessionNotes`, the
newest `UNREAD_REPORTS_SHOWN` (8) in time order, with control characters stripped. The markdown
fences each body and clips it at `REPORT_TEXT_MAX` (4000); `takeover --json` carries it whole.

**Coupled sites.**

- `skills/session-trail/handover-contract.json` declares the capability as
  `"linkedSessions":{"contract":1,"lineage":{"directory":"zensu/session-lineage/v1/edges","schemaVersion":1}}`
  and leaves `takeover.contract` at 1, because a larger value makes every current Hub refuse the
  plugin. `R3` in `test-session-hub-receipt.sh` pins the line byte for byte, and the receipt unit
  file checks the directory and schema against `ledgerPaths` and `LEDGER_SCHEMA_VERSION`. The Hub
  keeps a byte copy in its own `tests/fixtures/handover-contract.json`, updated in Hub step H1.
- Both briefs render `linkedSessionLines` and `unreadReportLines` after `openChipLines`.
  `takeover --json` carries `linkedSessions` and `unreadReports`; the first reports the ledger read
  with `ledgerTruncated`, `ledgerError` and `schemaNewer` on one line, as `L36b` requires.
- `references/takeover.md` step 1 has the plan confirmation name the linked sessions, and step 4
  starts them right after `takeover --force`, ahead of the chips and `release`.
  `references/handoff.md` flows 4 and 5, `references/commands.md`, `references/disclosure.md` and
  the data-source table in `SKILL.md` follow.
- The record-text class lives in the module as `RECORD_CONTROL` and `recordText`, and
  `openTaskChips` uses it, so chips and linked sessions strip the same characters.
- `trail.mjs` imports the module, so every test that stages `trail.mjs` in a sandbox tree copies
  it too: `mutant_path` and `cont_mutant` in `test-session-trail-verdict.sh` and the TDZ tree of
  `L46` in `test-session-trail-lineage.sh`. The import line moved the two `trail.mjs` citations in
  `docs/multi-repo-chains-spec.md` and `docs/multi-repo-chains-overview.html` by one line, which
  `T36` checks.

**Pins.** `tests/structure/linked-sessions-v1.test.js` drives the module, and its entry in
`tests/profiles/unit-files.v1.json` names two guards; `test-session-trail-verdict.sh` runs it as
`LS-unit`. `LS1` to `LS17` there drive `trail.mjs` against a store with every kind and real git
repositories: the read and its order, the kinds, the walk through an archived session, the detached
skip, the cap, the confirmed and provisional edges, the started guard, an unreadable record, a
missing record, the takeover brief section with the folder of every start it leaves without `cwd`
(`LS10`), the reports, the places, the handoff brief, the step order in `references/takeover.md`, a
takeover run from another repository with and without `--no-git` and from a folder in no
repository (`LS15`), a repository nested in the old checkout, a sibling worktree and a session
without a usable folder (`LS16`), and the handoff brief's places (`LS17`). `CH8` to `CH10` in the
same suite cover the linked half of the record-folder fallback, its control with no folder of the
old session left, and a folder that opens with two separators.

**Known gaps, accepted and named:**

- **Every Claude rule above is one bundle build's reading.** The admission of a start on the
  answer turn, the record fields of a started session, the kept `name` and `title`, `use_worktree`
  without `sharedCheckout` and the place approval for `cwd` need the Hub's live checks (H11) before
  a release ships the step.
- **Whether the first message of a started session runs as a slash command is unmeasured.** The
  prompt therefore names the Skill tool too.
- **The `cont-` handle joins on eight hex digits.** Two old runs that share them would both read as
  started once one of them is.
- **The edge read covers the `v1` ledger directory only**, as every other ledger read does, and a
  `confirmed` tier is a claim any local process can write.
- **The store and presets paths are verified on macOS only**; Windows and Linux are the inferred
  candidates of `ccdStoreCandidates`.
- **The receiving folder is the working directory of the `takeover` process**, not the folder
  Claude Desktop records for the session that runs it, as for the chips. A start that carries
  `cwd` lands in the right repository either way; one that leaves it out trusts that directory.
- **A start with `cwd` names a folder that may be gone.** A removed checkout cannot be measured,
  so its session starts there and Claude Desktop answers the place, which the step tells the user.
- **Every listed session's folder is measured where it lies**, under `--no-git` and on the plan
  pass too. `.claude/rules/session-trail-open-chips.md` names that bound; only a folder that opens
  with two separators is skipped.
- **A reader of a written takeover brief decides its own place.** The `folder` line asks a session
  working outside the old repository to pass that folder as `cwd`, and nothing checks that it
  does; re-running `takeover` from its own folder gives it a measured brief instead.

**Version: `patch`.** Walked against `.claude/rules/runtime-lineage.md`: no context-record or
workflow-state field, no strict key set (the Hub reads the contract file permissively, and only
tests read it in this repository), no hook added, removed or renamed, no matcher, config key or
attestation change, and `session-lineage-v1.mjs` is untouched. New `--json` keys and new brief and
skill text are patch-class, as they were for the open chips; so are `linkedSessions.sameRepository`,
the `place` reason, the repository verdict behind `sameCheckout` and the brief's `folder` block. The spec read the new contract key and
the new flow step as minor; neither is in the policy's breaking list.
