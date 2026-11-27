---
paths:
  - "skills/session-trail/scripts/linked-sessions-v1.mjs"
  - "plugins/session-hub/skills/session-trail/scripts/linked-sessions-v1.mjs"
  - "skills/session-trail/scripts/trail.mjs"
  - "plugins/session-hub/skills/session-trail/scripts/trail.mjs"
  - "skills/session-trail/handover-contract.json"
  - "plugins/session-hub/skills/session-trail/handover-contract.json"
  - "skills/session-trail/SKILL.md"
  - "plugins/session-hub/skills/session-trail/SKILL.md"
  - "skills/session-trail/references/**"
  - "plugins/session-hub/skills/session-trail/references/**"
  - "tests/structure/linked-sessions-v1.test.js"
  - "tests/structure/test-session-trail-verdict.sh"
---

# Session-Trail Linked Sessions (`linkedSessions` in `trail.mjs` + `skills/session-trail/scripts/linked-sessions-v1.mjs`)

**Two copies.** `/zensu:session-trail` is PLM's frozen copy of this skill; the
`session-hub@zensu` companion carries the maintained one as `/session-hub:session-trail`.
`.claude/rules/session-hub-companion.md` says which copy each check grades.

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
`repositoryVerdicts`, `openTaskChips`, `linkedSessions` and `unreadReports` from that one read,
which keeps `TL2`'s bound of two parses of the target's record. `familyRecords` reads every
`local_*.json` in the same `<account>/<org>` folder as bytes and parses only the files that
contain `"spawnedFrom"`; a file that cannot be read or parsed counts into `SKIPPED` and into the
state's `unreadable`, and the
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
| `unplanned` | later | only on a run that carries `--linked-start`: its names leave the session out; a session they carry skips the next five rows |
| `place` | if named | its `originCwd` is missing, relative or carries a control character, so no start can be placed in its repository |
| `fork` | if named | a user fork, started only when the user names it in the plan answer |
| `presets-unread` | if named | it names a saved environment that no complete read of the record's own presets file settles and carries no `sshConfig`, and a `ccd-session-presets.json` the read reached was refused, could not be read or did not parse, a folder that holds one failed the owner and mode rule, or the read went past the own file while the Session Hub profiles folder could not be listed |
| `ledger-unread` | if named | the ledger read had a directory error, hit its record cap or refused a record, or a ledger directory of a newer schema beside it holds records or could not be inspected |
| `started-unread` | if named | the running session's own record, or a record in its folder, was refused or could not be read, no own record was found while a store entry was or while a Claude Desktop host id names the running session, or a folder that holds a store it judged failed the owner and mode rule |
| none | start | a side or task-chip session, the first `LINKED_START_CAP` (8) in creation order |
| `cap` | later | the rest, started only on a later message the user types |

Cloud and Remote Control sessions have no `local_` record in the store, so they never appear.
The list is bounded at `LINKED_LIST_MAX` (64) and says how many it leaves out.

**A refused read never turns a stay into a start.** Three stay rows read files beside the old
session's record: `ssh` reads the saved environments in `ccd-session-presets.json`, `continued`
reads the lineage ledger, and `started` reads the running session's own record and the records
beside it. A read that the owner and mode rule of `hooks/lib/desktop-store-read-v1.js` refused, a
ledger record `readEdges` refused, a ledger directory of a newer schema that holds records or could
not be inspected, a store whose folder fails that rule, or a read that could not complete leaves that
answer unknown, and an
unknown answer is an **if named** row of its own:

- `presets-unread` applies to a session that names a saved environment and carries no `sshConfig`
  while `savedPresets` reports its read incomplete: a presets file it read was refused, could not be
  read or did not parse, or the folder that holds one, the parent of its store, fails
  `realDirectory(folder, writableOnlyByCaller)`. `storeFolderVerdict` judges that folder once per
  process, before this read and before the started set below, and it counts once as a refused entry
  when it fails, because an account that can write it can delete the file or rename another file of
  the user's over it. The file is still read then, so a preset it
  names as SSH keeps its session as `ssh`, while nothing it lacks or names as local is trusted:
  `decideLinked` drops every preset an incomplete read found that is not SSH, so the brief says the
  saved environment could not be named rather than offering a name that another account could have
  pointed at another preset of the user's, and the `presets-unread` why line says the saved
  environments could not be read or could not be trusted. While the folder passes, a missing
  presets file, and a preset the read file no longer lists, leave the read complete, because a
  deleted preset is common and is not a refused read. Measured on
  one Mac on 2026-11-04: 51 of the 191 linked records that named a saved environment named one the
  file no longer listed, and all 3 records that named an SSH preset also carried `sshConfig`. On the
  same Mac on 2026-11-09 the folder that holds the presets file was `0700` and the user's own, so
  the folder check refuses nothing there.
- **A saved environment the record's own presets file does not settle is looked up beside every
  other store candidate.** The Zensu Session Hub moves an account's records into a data folder of
  its own and leaves the presets that named them in Claude's default folder, so the own file often
  lacks them. Measured on one Mac on 2026-11-18: of 667 records naming a saved environment, 59
  resolved from their own store's presets file, 451 only from another store's, 157 from none, and no
  id was described differently by two files. `savedPresets` reads the own file first and stops there
  when that read is complete and the file lists every id `linkedEnvironments` returns, the ids the
  open linked sessions name by the rule `decideLinked` reads them with, so a takeover whose own file
  names every saved environment reads what it read before, and an id no decision reads never sends
  the read further. Otherwise it also reads the presets file beside every other store candidate that
  exists and is no `SAME AS` spelling, a refused one included, because the file sits in the folder
  that holds the store and not in the store: a default store that is a symbolic link to a store
  `ZENSU_CCD_EXTRA_STORES` names is refused while Claude Desktop's own presets file stays beside it.
  Under `ZENSU_CCD_STORE` no other candidate exists. `presetsAcrossStores` in the module merges the
  reads. A complete own read wins and settles every id it lists, also over another file's different
  description of the same id (`DF2` pins the early return and `DF12`'s `e3` the merge); no other
  file can change those answers, so an incomplete read elsewhere holds none of them. An own read that
  is not complete, its folder refused or its file refused or unparsable, settles nothing and counts
  as one more description. An id nothing settles is named only when every file that lists it
  describes it alike, the rule of the Hub's `Presets::read`, and an id they describe differently is
  named by none of them, except that a description naming SSH keeps the session as `ssh` with no
  name, because that stay row exists to never start a remote session here. Every folder this read
  reaches is judged like the own one and reported with the `presets` read, and one refused folder,
  one file that was refused, could not be read or did not parse, or a Session Hub profiles folder
  that could not be listed leaves the read incomplete for every id nothing settles, because it may
  hold the description that decides. `decideLinked` takes those settled ids as `presetsSettled`
  beside `presetsComplete`. `linkedSessions.presetsUnread` lists each presets file the read reached
  that was refused or unreadable, as `{ file, state }`, and both briefs print `presetsFileNote` for
  each, so a broken file in another profile is named rather than holding sessions silently. When the
  read went past the own file while the Session Hub profiles folder could not be listed,
  `linkedSessions.presetsProfilesUnread` names that folder, `null` otherwise, and both briefs print
  `presetsProfilesNote` for it; a read the own file settled never names it, because the folder did
  not hold that read.
- **A `ZENSU_CCD_STORE` directly under a shared sticky folder such as `/tmp` reads its presets as
  unread and its started set as unknown.** The folder that holds the presets file is then that shared folder, which every account
  can write, so it fails the rule; on macOS `/tmp` is also a symbolic link to `/private/tmp`
  (measured 2026-11-09), refused for that alone. The sticky bit would stop another account from
  deleting or renaming the user's file (sticky(7)), but the rule reads the owner and the write bits
  only, and crediting the sticky bit would add a third policy to
  `hooks/lib/desktop-store-read-v1.js`, which both readers load and `L3k` pins to two, for a store
  only `ZENSU_CCD_STORE` can place there. So such a store holds every session started from a saved
  environment without `sshConfig` for its name, unless the presets file names that preset as SSH,
  which keeps it, and while a running session id exists every other session that could start as
  well; a store in a private folder below `/tmp`, such as one `mktemp -d` makes, reads normally.
  The note names `move` as the remedy for such a store, because the shared folder, or on macOS the
  real folder its link names, belongs to another account.
- **A Claude application-data folder that is a symbolic link fails the rule too**, such as one moved
  to another drive and linked back, because `realDirectory` refuses a symbolic link where a folder
  is expected. The store's real path added to `ZENSU_CCD_EXTRA_STORES`, or for a store that
  `ZENSU_CCD_STORE` names that variable set to it, makes the rule judge the real folder instead.
- **While the folder is refused, both briefs print one note that names it, its cause and the remedy
  that cause and the store's source call for**, because a remedy that fits one cause does harm under
  another. `ownedDirectoryRefusal` in `hooks/lib/desktop-store-read-v1.js` names the cause:
  `symlink`, `not-directory`, `foreign-owner`, `shared-write` or `uninspectable`.
  `storeFolderVerdict` also judges the real folder of a symbolic link, and `storeFolderRemedy` in
  the module picks the remedy from the real folder's cause for a link and from the folder's own
  otherwise:
  - `real-path`, a link whose real folder passes: name the store's real path (the real-path step
    below).
  - `chmod`, a folder the user owns that grants group or other write: remove those bits, and for a
    link then take the real-path step.
  - `move`, a folder another account owns while `ZENSU_CCD_STORE` or `ZENSU_CCD_EXTRA_STORES`
    named a store that is not Claude Desktop's own: move the store into a private folder of the
    user's own, such as one `mktemp -d` makes, and point the variable that named it there. A
    permission change on a folder another account owns is never the remedy, because on a shared
    folder such as `/tmp` it would take every other account's write access away.
  - `admin`, a folder another account owns while the store is Claude Desktop's own, whether the
    probe found it or a variable names it: never move the store, because Claude Desktop keeps
    writing there; only an administrator can give the folder back to the user's account.
  - `inspect`, a folder that is not a directory or could not be inspected: make it a directory of
    the user's own without group or other write.

  **The real-path step keeps every other store read.** `realPathStep` and `realPathJudged` in the
  module word it by how the store was named, which `storeFolderVerdict` records as `named`: a store
  `ZENSU_CCD_STORE` names takes that variable set to the store's real path, because the override is
  already the only store; a store `ZENSU_CCD_EXTRA_STORES` names takes the real path in place of its
  entry; and a discovered store takes the real path added to `ZENSU_CCD_EXTRA_STORES`, whose entries
  are probed ahead of the discovered ones, so the real path wins the `SAME AS` pairing and its folder
  is the one judged (`DF9`). Setting `ZENSU_CCD_STORE` for a discovered store would instead turn
  off every other store, the other account's profile in a Session Hub takeover included.

  **Claude Desktop's own store is decided by where it is, never by how it was named.** The
  real-path step names Claude Desktop's live store, so a source test would advise moving the very
  store those remedies named. `storeFolderVerdict` sets `desktopOwn` true for a discovered store,
  and for a named one `desktopOwnStore` compares the store with every existing candidate of
  `ccdStoreCandidates(true)`, the discovered list with both variables ignored, through
  `canonicalPair`, whose `realpathSync.native` also settles letter case on a case-insensitive
  volume (measured on macOS: `/USERS` reads as `/Users`). `storeFolderRemedy` answers `move`
  only for a named store whose `desktopOwn` is `false`, and `admin` for every other folder another
  account owns, an unknown `desktopOwn` included.

  **Each read reports the folder it judged.** The presets read judges the folder of the store that
  holds the old session's record and, once it goes past that store's file, the folder of every other
  store candidate it reads beside; the started set judges the folder of the store that holds the
  running session's record, or every store's folder when it finds none, and in a Session Hub move
  those are different profiles. `storeFolderStates` merges what the two reads returned into one entry per
  folder, each with the reads that judged it, and both briefs print one note per refused entry, so a
  note never distrusts a read that was trusted and never misses one that was not (`DF10`).
  `takeover --json` reports `linkedSessions.storeFolders`, those entries in the order the reads
  judged them, each carrying `dir`, `refused`, `cause`, `realDir`, `realStore`, `realCause`,
  `override`, `named`, `desktopOwn`, `remedy` and `reads` (`presets`, `started` or both);
  `linkedSessions.storeFolderRefused`, true while any entry is refused; and
  `linkedSessions.storeFolder`, the first refused entry or else the first one. All three are `null`
  while no read judged a folder, because the state comes from the folder verdicts that `savedPresets`
  and `startedContinuations` return beside their answers, never from the memo.
- `ledger-unread` applies to every session that no confirmed edge the read found keeps and that
  would otherwise start, while `ledgerRead()` reports a directory error, its record cap or a refused
  record. A record `readEdges` refused, whatever its reason (unreadable, not a regular file, over
  its size bound, corrupt, of another schema or malformed), may be the `confirmed` edge that keeps a
  session `continued`, so one such record holds every start, as it already blocks
  `lineage --backfill --apply`. A record that vanished between the listing and the open is not a
  refusal, and neither is a dot-file. A confirmed edge the read did find keeps its session
  `continued`. The section's ledger note in both briefs counts the refused records, names the ledger
  directory and points at `lineage --diagnose`, which lists each refused record with its reason, up
  to `LEDGER_REFUSED_SHOWN` (20), in its text and as `refusedRecords` and `refusedFiles` in its
  `--json`, because `lineage --forget` matches read edges only and cannot remove one.
  `takeover --json` carries the count as `linkedSessions.ledgerRefused`. A ledger directory of a
  newer schema beside the `v1` one that holds records counts the same way, because a newer build
  records its handovers there and this build cannot read them, and so does a schema directory that
  could not be inspected, because it may be one. `schemaLedgerCensus` in `session-lineage-v1.mjs`
  lists both kinds, the read ones in `ledgers` and the others in `unread` with `records` `null`: a
  `v<N>` directory or its `edges` that is a symbolic link or cannot be listed, and, with `version`
  `null`, the folder that holds the schema directories when it cannot be listed or it or `zensu`
  above it is a symbolic link. `takeover --json` carries every entry that is not older, read or
  not, in `linkedSessions.newerSchemaLedgers` (`version`, `dir`, `records`, `truncated`,
  `relation`), and the ledger note names each read `edges` directory with the records it holds and
  says to update the plugin, and names each other one as a directory that may hold records of a
  newer schema and could not be inspected. An empty newer directory and an older one, read or not,
  count nothing, and `newerSchemaLedgers` is `null` when no census ran: no open linked session
  carries a Claude Code session id, so no ledger read ran, or that read had a directory error, which holds
  every start on its own. `lineage --backfill --apply` stamps no record later than
  the moment it runs, the earlier of the successor's modification time and that moment, so a
  transcript modified in the future cannot mint a record the read refuses and so hold every start.
- `started-unread` applies to every session that would otherwise start while
  `startedContinuations` reports its set incomplete. It looks for the running session's record by
  `CLAUDE_CODE_SESSION_ID` among the records' `cliSessionId` values and, when none carries it, by
  the file name `CLAUDE_CODE_HOST_SESSION_ID` names among the records the walk listed, because
  Claude Desktop can run a session under a new CLI id before it writes that id into the record. The
  set is incomplete when the record found could not be read, or when it was read but its folder
  could not be listed or a record in it was refused or could not be read, since any of them may be
  a continuation the running session started. It is incomplete as well, in every branch after the
  running-session check, while the folder that holds the store fails the owner and mode rule:
  an account that can write that folder can put an older copy of the store in its place, which
  lacks the continuations the running session started since. A continuation the read did find
  still keeps its session `started`.
- **No own record found is an answer only when the store read was whole.** A refused record is
  never listed and an unparsable one never matches, so the lookup cannot tell a missing record from
  one it could not read. With no record found, the set is complete only while `CCD_REFUSED` and
  `CCD_UNREAD` are both empty: no store candidate, folder or record was refused, no folder failed to
  list, and no record was caught mid-write or failed to parse. Any of them may be the running
  session's own record, whether or not a host variable names it, so one such entry anywhere in the
  store holds every start. `savedPresets` runs after `startedContinuations`, so a refused presets
  file never counts, and `OM9` pins that order; the folder that holds it is the store's own parent
  and counts for both reads, which `OM12` pins. A session that runs outside Claude Desktop over a
  whole store reads a complete started set with nothing in it. A session that `CLAUDE_CODE_HOST_SESSION_ID`
  marks as a Claude Desktop session, through `isSafeHostSessionId`, does not: its own record exists in
  a store this run did not read, such as a data folder of its own that no variable names or a store
  `ZENSU_CCD_STORE` leaves out, so its set is unknown (`DF10`). Measured on the same Mac on 2026-11-08:
  none of the 4,357 records and 67 folders was refused, failed to parse or failed to list, so
  neither rule decided anything there.
- The **if named** rows match in the order `place`, `fork`, `presets-unread`, `ledger-unread`,
  `started-unread`, the order of the stay rows the last three stand in for. A carried plan that
  names the session skips all five, and every one of them keeps its start call.

**The run after the yes carries the plan's start set (`--linked-start`).** `takeover --force`
takes `--linked-start` with `none` or the comma-separated names of the sessions the plan answer
starts, parsed by `linkedStartNames` (only `cont-` and eight lowercase hexadecimal digits, each
name kept once, in order). `decideLinked` receives them as `planned`: a session past the six stay
rows that the names leave out is **later** with `why` `unplanned`; one they carry skips the five
**if named** rows, so a named user fork, a named session without a usable folder and a named
session behind unread saved environments, an unread ledger or an unread started set start too,
and the carried ones start in creation order while `LINKED_START_CAP` allows, the rest **later**
with `cap`. A carried session that stays keeps its
reason. Each entry carries `planned` (`true` or `false`, `null` without the flag), and the state
carries `plan: { names, unlisted }`, `unlisted` being the carried names no listed session has; the
brief names a carried session it does not start on that session's entry and the unlisted names on
one line. Without the flag the table above decides alone.

**The plan pass spells the value, and the run after the yes refuses without it.** The plan brief
(`takeover` without `--force`) names the value for a yes that changes nothing, the names it marks
start in listed order or `none`, and its lead tells the model to drop a name the user leaves out
and add an if-named session the user names. The companion's plan card, `takeover --plan`, spells
the same value line from the measured decisions, never from the rendered lines
(`.claude/rules/session-trail-plan-card.md`). The names go in
single quotes, in the value line, the
lead, step 1 of `references/takeover.md` and the flag list of `references/commands.md`, because
PowerShell passes an unquoted comma list as separate arguments: `--linked-start` then takes the
first name and the rest land among the positionals, where `takeover` reads none of them, so
without the refusal below an approved session would run as `unplanned` with its edge recorded.
`cmdTakeover` refuses a run that
carries `--linked-start` and more operands than one selector, naming every operand, before
`resolve`, which also catches a split list whose rest lands before the selector. A second
`--linked-start` is refused in `parseArgs`, through `linkedStartOperand`, because every other
operand flag keeps its last value, and for this one that would drop the names of the first. It refuses
`--linked-start` without `--force`, and refuses a `--force` run without it while a listed
session's decision is not `stays`, right after `linkedSessions` and before `recordTakeoverEdge`,
so a refused run records no edge and prints no brief. `--linked-start` is a flag of `takeover`
alone in `COMMAND_FLAGS`, and `refuseForeignFlags` reports it, which keeps `L66d`'s parse and
scope lists the same length. The plan pass still writes nothing. The handoff brief renders
neither text: its reader starts from the brief its own user confirmed, so it has no second run.
Step 4 of `references/takeover.md` gives that reader its own sentence, because the rest of the
step speaks to the carried brief: start each session the handoff brief marks start that the
user's answer did not leave out and each if-named one the answer named, as that brief's lead
says. Flow 4 of `references/handoff.md` points there.

**The Zensu Session Hub needs no follow-up for `--linked-start`.** `Catalog::decide` in
`src-tauri/src/resources/desktop_sessions/catalog.rs` mirrors the plan pass, which decides by the
table alone without the flag. The `unplanned` row exists only on the run after the yes, which the Hub
never computes: it types `takeover <session id> --all` and reads the records and the ledger
afterwards. `family_continuation` joins by the `cont-` handle and the ledger, so a session the
plan answer left out reads `Stays` there, as any session the user leaves out does.

**The Hub needs a follow-up for `presets-unread` and for `ledger-unread`, and none for
`started-unread`.** Its `remote` closure reads a `Presets` set into which
`src-tauri/src/environment_presets.rs` collapses every read failure, so `Catalog::decide` marks a
member whose presets it could not read as one that continues, where the plan pass marks it **if
named**. The mirror is a Hub change of its own: `Presets` reports whether every presets file it
found was read, and `decide` keeps a member that names a saved environment while one was not.
`decide` has no `started` row, because the Hub is not the session that runs the takeover, so
`started-unread` has nothing to mirror. The Hub reads the presets without the owner and mode check,
so a presets file or a presets folder only the plan pass refuses still decides the two apart until
the Hub adopts that check too. `Presets::read` merges the default folder's presets file with every
own folder's, so the Hub already names a saved environment that only another store lists, as the
plan pass does since it looks beyond the record's own store. The two still part on an id two files
describe differently: the Hub reads it as unknown wherever it appears, while the plan pass keeps the
description of a complete read of the record's own file and keeps a session here whose other
descriptions disagree once one of them names SSH, which the Hub marks as one that continues. No such id was measured on 2026-11-18,
so this needs no Hub follow-up until one is seen. Its ledger read, `scan` in `src-tauri/src/lineage_ledger.rs`, skips a
record it cannot read or that fails its edge checks and calls the read complete while the listing
fits its cap, so `decide` marks a member whose only confirmed edge it could not read as one that
continues, where the plan pass marks it **if named** as `ledger-unread`. That mirror is a Hub change
too: `scan` reports the read incomplete for a record it could not read or parse as an edge, while a
well-formed edge that is not `confirmed` stays no continuation. `scan` reads no ledger directory of
a newer schema either, so the mirror also reports the read incomplete while such a directory holds
records or could not be inspected.

**Every session marked start belongs to every yes.** The plan confirmation names each one by its
title, and the model never leaves one out on its own judgment: not because its own work looks
finished, since the sessions below it follow only through it, not because the new session could
finish that work, and not because each start costs its own plan confirmation. The confirmation
never offers a restart as an alternative to finishing that session's work here, and no answer
option leaves one out; a user who wants one left out names it in the answer, and a restart the
model thinks pointless costs one line that names what leaving it out costs. Two live Zensu Session
Hub moves on 2026-10-25 under 0.29.0 showed both shapes: a plan question that recommended finishing
a linked session's work in the new parent over restarting it, and a parent that restarted one of
two sessions marked start and dropped the other because its pull request was merged, which also
stranded that session's own open linked session. A session moved on its own later lands at the
top level for good, because Claude offers no way to link a session under another one. The rule
lives in `references/takeover.md` steps 1 and 4, `references/handoff.md` flows 4 and 5, and the
lead of `linkedSessionLines`, which both briefs render.

**The rule fixes the answer options, and best solution first moves into the one line.** Leaving
a session out as the first, recommended option is the shape that broke the first move. Step 1 and
the brief lead therefore say that these rules fix which answer options the confirmation offers,
and that best solution first applies to the one line, which carries the model's recommendation
marked as such with its cost; the user takes it by naming the session. The best-solution-first
block every session receives admits that: where a skill's contract fixes the set and reserves an
option for the user to name, the block governs one line instead of the set, and its per-prompt
reminder says the same. Coupled sites that move together: the block, the reminder and the
§Precedence example in `docs/best-solution-first.md`, the precedence paragraph of
`docs/architecture.md` §Best Solution First, step 1 of `references/takeover.md`, and the lead
of `linkedSessionLines` in `scripts/trail.mjs`.

**The start set is the plan's, and the script holds it.** The `--force` run reads the records
again, so on its own it could mark a session start that the plan confirmation never named (an
archived start session lets a later one past the cap, or a new record appears) and stop marking
one the plan named. Because that run carries the plan answer as `--linked-start`, step 4, flow 5
and the carried brief lead start every session the carried brief marks start and no other, and the
model never matches the two briefs by title.

**`openBelow` makes that cost visible.** `familyWalk` returns an `openBelow(run, follows)` walker
that counts the open records below an open linked session at every level, walking through archived
ones and never into a detached one, with the same `isArchived` and `isDetached` predicates as the
walk itself; its visited set keys on the run id, so a record listed twice is counted once and a
cycle of duplicate ids ends. `decideLinked` passes `follows`, which is `keptWhy`, the first six
rows of its own decision table (`no-session-id`, `self`, `btw`, `ssh`, `continued`, `started`),
answering none, so a descendant its own continuation would keep is neither counted nor descended
into, and the count is the number of sessions that follow only through it. It carries the result
as `openBelow` on every entry, and the briefs render `- open linked sessions below it: N, which
follow only through it` when it is not zero. The count changes no decision, so `Catalog::decide`
in the Zensu Session Hub needs no follow-up.

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

**The module names why a start carries or leaves out `cwd`.** `decideLinked` gives every started
entry one `cwdWhy`: `same-repository` when both verdicts are `true`, `receiver-elsewhere` when the
checkout is the old repository and `sameRepository` is `false`, `receiver-unmeasured` when it is
`null`, and `null` when the folder is unusable or not the old repository, where the checkout line
already explains the place. `startCall` leaves `cwd` out exactly for `same-repository`, and the
brief renders `LINKED_CWD_WHY[cwdWhy]` under the checkout line, so `trail.mjs` decides no place of
its own. `takeover --json` carries `cwdWhy` on each entry.

**The checkout is the repository, never a nested path.** `sameCheckout` is the `checkout` verdict
of `repositoryVerdicts` in `trail.mjs`, the one the chips use
(`.claude/rules/session-trail-open-chips.md`): the git common directory of the child's
`originCwd` against the old session's repository, the first measurable one of
`[r.wt, r.cwd, o.originCwd, o.cwd]`. A worktree anywhere on disk is the same repository, a
repository nested in the old checkout is another one, and a folder git cannot measure answers
`null`. With no measurable folder of the old session, `checkout` answers `null` without measuring
the child's folder, `linkedSessions.oldRepositoryMeasured` is `false`, and the checkout line reads
`unknown, because the repository of the session taken over could not be measured`; with a measured
old repository an unmeasurable child folder reads `unknown, because the repository of its folder
could not be measured`. The module validates the folder with `folderOf` before it asks, so git
never sees a relative or control-character value, and `repositoryOf` never measures a folder that
opens with two separators, such as a Windows network path. A nested-path comparison would count
every folder below a session rooted in a broad folder as that session's own checkout.

**The receiving repository decides the cwd, the same verdict that lists chips.** `sameRepository`
compares the folder `takeover` runs in with the old session's repository and travels as
`linkedSessions.sameRepository`. From another repository, or from a folder git places in no
repository once the old repository is measured, it is `false`, so every start passes its folder,
the old repository's sessions included, and the brief tells the user why with the
`receiver-elsewhere` line under the checkout line. `cmdHandoff` never measures its unknown
reader, so in a handoff brief every session with a usable folder carries it as `cwd`, at the cost
of one place approval per start, and one in the old repository says so with the
`receiver-unmeasured` line. `--no-git` changes no verdict, because `takeover` and
`handoff` run their git calls regardless. `preset` is the model's to add: the brief names the saved
environment from `ccd-session-presets.json` beside the record's store, or for an id that file lacks
beside the other stores read (`byAccount[<account>].presets`, the id in
`startedFromEnvironmentId`), and the model passes it only when `list_start_targets` lists a
local preset of that name, leaving `cwd` out then. A read the fail-safe paragraph counts incomplete
names no preset other than an SSH one, whose session stays.

**The takeover brief names every folder it leaves out, because a brief outlives the process that
measured it.** `sameRepository` measures the `takeover` process, while a brief written to
`TAKEOVER_TARGET` can be opened later by a session in another repository. So a start the
measurement left without `cwd` lists its folder in a `folder` block under the `same-repository`
line of `LINKED_CWD_WHY`, `it starts without cwd, because the takeover that printed this brief
ran in the old session's repository; pass its folder as cwd when this session works outside that
repository`, and the section's lead states the same rule. The text names the block by its label,
never by its position, because the module renders nothing. The omission itself stays in both carriers: `references/takeover.md`
step 4 tells the session that ran `takeover` to use the brief its `--force` run printed, and that
session starts such a session in a worktree of its own repository with no place approval.
`cmdTakeover`'s comment keeps `writes` and `continuation` out of the markdown for the same
reason; a start call cannot be left out, so the brief carries the folder and the condition
instead.

**`continuationsStartedBy` keeps a started session from being offered twice.** Without it a
second takeover run
after the starts, such as the one that serves a later message for a session marked **later**,
offers the started sessions again, because their edges exist only once their own users confirm.

**Reports not yet read.** `unreadReportsOf` takes the old session's `queuedSideSessionNotes`, the
newest `UNREAD_REPORTS_SHOWN` (8) in time order, with control characters stripped. The markdown
fences each body and clips it at `REPORT_TEXT_MAX` (4000); `takeover --json` carries it whole.

**Coupled sites.**

- `skills/session-trail/handover-contract.json` declares the capability as
  `"linkedSessions":{"contract":1,"lineage":{"directory":"zensu/session-lineage/v1/edges","schemaVersion":1},"ownDataFolders":true}`
  and leaves `takeover.contract` at 1, because a larger value makes every current Hub refuse the
  plugin. `ownDataFolders` declares that a takeover finds the old session's record in a Claude
  Desktop data folder of its own, a Session Hub profile or a store `ZENSU_CCD_EXTRA_STORES` names
  (`.claude/rules/session-trail-targeted-lookup.md`), so a Hub can promise the linked sessions of
  such a source only for a plugin that declares it. It is a field and not a larger
  `linkedSessions.contract`, because `linked_sessions_of` in the Hub's `src-tauri/src/plugin.rs`
  requires that number to be exactly 1 and reads no other field: every current Hub ignores the
  field and would drop the capability for a 2. `R3` and `R12` in `test-session-hub-receipt.sh` pin
  both lines byte for byte, and the receipt unit file checks the directory and schema against
  `ledgerPaths` and `LEDGER_SCHEMA_VERSION` and the field's value. The Hub keeps a byte copy of
  PLM's line in its own `tests/fixtures/handover-contract.json`, which owes the new field.
- Both briefs render `linkedSessionLines` and `unreadReportLines` after `openChipLines`.
  `takeover --json` carries `linkedSessions`, each entry with its `openBelow` and `planned` and the
  state with its `plan`, and `unreadReports`; the first reports the ledger read
  with `ledgerTruncated`, `ledgerError`, `schemaNewer`, `ledgerRefused` and `newerSchemaLedgers` on
  one line, as `L36b` requires for the first two, and the store folder's verdict as
  `storeFolderRefused` and `storeFolder`.
- `references/takeover.md` step 1 has the plan confirmation name the linked sessions and the yes
  run `--force` with `--linked-start`, step 0 says that run carries them, and step 4 starts what
  the carried brief marks start right after `takeover --force`, ahead of the chips and `release`.
  `references/handoff.md` flows 4 and 5, `references/commands.md` (the `takeover` row, the flag
  list and the `--force` paragraph), `references/disclosure.md` and the data-source table in
  `SKILL.md` follow. The brief's step 3 asks for the `--linked-start` value whenever a listed
  session could start.
- The record-text class lives in the module as `RECORD_CONTROL` and `recordText`, and
  `openTaskChips` uses it, so chips and linked sessions strip the same characters.
- `CCD_UNREAD` in `trail.mjs` holds what the store walk, `ccdIndex`, `ccdCandidates` and `ccdApp`
  could not read, beside `CCD_REFUSED`, and `startedContinuations` reads both when it finds no own
  record, so a new store read that can fail adds its entry to one of them. `hostNamedRecord` reads
  `CLAUDE_CODE_HOST_SESSION_ID` through `isSafeHostSessionId`, as `accountForHostSession` does.
- `storeFolderVerdict` in `trail.mjs` is the one judge of the folder that holds a store and
  memoizes its answer per store in `STORE_FOLDERS`. It answers for every probed candidate that exists
  and is no `SAME AS` spelling, a refused one included, and for nothing else: `savedPresets`, through
  `presetsBeside`, judges the folder of the store that holds the old session's record and reads that
  folder's presets file, then the folder and file of every such other candidate while the own read is
  incomplete or lacks a wanted id, and `startedContinuations` the folder of the store that holds the
  running session's record, or every accepted store's folder when it finds none; both return their
  verdicts beside their answers, `linkedSessions` merges what they returned through
  `storeFolderStates` into `storeFolders`, `storeFolderRefused` and `storeFolder`, and
  `linkedSessionLines` renders `storeFolderNote` for each refused entry, `presetsFileNote` for
  each entry of `presetsUnread` and `presetsProfilesNote` for `presetsProfilesUnread`, so
  a new reader of that folder calls it rather than `realDirectory` again and returns its verdict too. `storeFolderNote`, its cause words in `STORE_FOLDER_CAUSE` and
  `storeFolderRemedy` live in the module, where the unit file drives the remedy and every note text;
  `linkedSessionLines` passes `briefPath` to show each path. `ccdStoreCandidates(true)` is the one
  candidate list `desktopOwnStore` reads, so a discovered candidate added for the probe also counts
  as Claude Desktop's own store, and a named one never does.
- `linkedEnvironments` in the module maps the open nodes through `environmentOf`, the rule `entryOf`
  applies, so the ids `savedPresets` looks for are exactly the ids `decideLinked` reads; a change to
  that rule moves both. `presetsAcrossStores` returns `{ presets, settled }` and takes reads of the
  shape `presetsBeside` returns, so `settled` and `presetsSettled` move together.
- `ownedDirectoryRefusal` names why `realDirectory(dir, writableOnlyByCaller)` refused a folder and
  decides nothing, so the store keeps one rule. It lives in `hooks/lib/desktop-store-read-v1.js`
  beside that rule, the companion's byte copy carries it, and `storeRead()` requires it of every
  tree it loads.
- `trail.mjs` imports the module, so every test that stages `trail.mjs` in a sandbox tree copies
  it too: `mutant_path` and `cont_mutant` in `test-session-trail-verdict.sh` and the TDZ tree of
  `L46` in `test-session-trail-lineage.sh`. A line added to `trail.mjs` above `gitState`, such as
  the `--linked-start` parse branch and `linkedStartOperand`, moves the two `trail.mjs` citations
  in `docs/multi-repo-chains-spec.md` and `docs/multi-repo-chains-overview.html`, which `T36`
  checks; re-derive each one per site.

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
old session left, and a folder that opens with two separators. `CH11` reads both unknown checkout
lines and `oldRepositoryMeasured` on both sides, and `CH12` logs every git call through a `PATH`
wrapper to show that no chip or linked-session folder is measured while the old repository is
unmeasured, against a control with a measured one; it is skipped on Windows, where a shell wrapper
does not stand in for `git.exe`. The unit case `the module names why a start carries or leaves out
cwd, and the start follows that reason` drives `cwdWhy` and the start's `cwd` for each
`sameRepository` value. LS10 and LS13 pin the every-yes lead and the precedence sentence in both
briefs; LS10 also pins the plan pass's `--linked-start` lead with its single-quote sentence, its
quoted value line for the fixture, the
step 3 sentence and the absence of a retired leave-out sentence and of
the title match, and LS13 that the handoff brief names no `--linked-start`. LS14 pins the rule, the
precedence sentence and the `--linked-start` yes inside the plan-confirmation paragraph of step 1,
step 0's carry, the carried start set and the handoff reader's start rule inside the start
paragraph of step 4, the absence of the retired sentences there, and both flows of
`references/handoff.md`. LS18 pins `openBelow` with a
side question and an SSH session below the counted one, and the count line on its own entry in
both briefs. LS19 drives a `--force --no-record` run whose plan leaves out a start session and
names a user fork, a session that already continues and a name no session has: every decision,
`planned` and `plan` in `--json`, the carried brief's tally, lead, unlisted line, `unplanned` why
lines and the planned line on its own entry, the line and `plan` of a carried run whose desktop
record is missing, `--linked-start none`, the plan pass's `null` `plan`,
a `--force` run without the flag refused with and without `--json` (exit status, text, no brief and
an unchanged ledger), a value split into separate arguments with its rest after and before the
selector and a flag given twice (exit status, every operand named or the second flag refused, no
brief and an unchanged ledger), `--linked-start` without `--force`, a malformed value, the flag on
`show`, and the `references/commands.md` lines. LS20 drives a family whose listed linked sessions
all stay: its plan pass carries no `--linked-start` lead, value line or step-3 clause, and its
`--force` run needs no flag and records its edge. LS21 drives a family whose only session that
could start is a user fork: its plan pass spells `--linked-start none` and the step-3 clause, its
`--force` run without the flag is refused naming `none` with an unchanged ledger, and
`--linked-start none` marks the fork `later` as `unplanned`. The unit case `each open linked session counts the open
sessions below it that would follow through it: every level, through archived ones, never into a
detached one or one its continuation keeps, and once each` drives the count, and the four cases
`the plan names are none or a comma-separated list of cont- handles, …`, `a carried plan starts
exactly the sessions it names that can start, …`, `a carried plan counts its starts against the
cap in creation order, …` and `the names a carried plan holds that no listed session has are
reported, …` drive the parser and the carried decisions. The three cases `a session started from a
saved environment waits for the user to name it while the saved environments could not be read, …`,
`an incomplete started set keeps every session that could start from starting until the user names
it, …` and `the rows that wait for a name match in table order, …` drive the two fail-safe rows,
their order and a carried plan that names them. `OM8` and `OM9` in the owner and mode block of
`test-session-trail-verdict.sh` drive them through `trail.mjs`, POSIX hosts only: `OM8` rewrites
the LS fixture's saved environment to an SSH preset and grades it private (`stays`/`ssh`), group
writable and unparsable (`if-named`/`presets-unread`, the why line in the brief included), missing
and restored to the local preset (`start`); `OM9` adds a running-session record in a UUID-shaped
organization folder and grades it refused under the full host environment, the host id alone and
none, unparsable under the full environment and none, in a refused folder and in a folder that
cannot be listed (skipped as root), each `if-named`/`started-unread` with the why line in the
brief; a session id its record does not carry, which reads the record the host id names and keeps
the session that record started under both forms, and holds every start once a record beside it is
refused; no own record over a clean store (`start`), with a refused folder elsewhere in the store
(`started-unread`, while a found own record ignores that folder) and with a refused presets file,
which `savedPresets` reads after the started set and so leaves it complete; all against the
private control that keeps the session it started as `stays`/`started`. `OM10` and `OM11` in the
same block drive the two reads the fail-safe paragraph names for the ledger and the presets folder:
`OM10` corrupts the LS fixture's confirmed edge, which turns that session and every other one that
could start into `if-named`/`ledger-unread` with the why line in the brief, the ledger note that
counts the refused record, `ledgerRefused` and `lineage --diagnose` naming it with its reason in
both forms, and plants a record of a newer schema beside the intact ledger, which keeps the session
the read edge confirms `stays`/`continued` and holds the rest, against the intact and the restored
ledger, which carry no note and refuse nothing; `OM11` grades the folder that holds the presets
file group writable, world writable with the sticky bit and named through a symbolic link in
`ZENSU_CCD_STORE`, with the file missing or naming the local preset (`if-named`/`presets-unread`,
the refused folder counted once as skipped, the local preset's name withheld in `--json` and in the
brief), keeps `stays`/`ssh` and the name for a preset the file names as SSH in the group-writable
folder, and decides and names normally in the private folder, also named through
`ZENSU_CCD_STORE`. The unit case for `presets-unread` also
drives a preset map from an incomplete read: an SSH preset still stays and keeps its name, a local
one waits for its name and is not named. The unit cases `a saved environment the own presets file
does not list is named from the other stores, …` and `an id the other stores describe differently is
named by none of them, …` drive `presetsAcrossStores`: the own entry over a different description
and the ids it settles, an id named only by another file, one two files describe alike, inputs that
are no read or no map, and the conflict that names nothing or, with an SSH side, stays without a
name, also under an incomplete read. `an own presets file that cannot be trusted settles nothing, …`
drives an untrusted own read, which settles nothing and whose local description loses to an SSH one
elsewhere, against a trusted one whose ids `presetsSettled` lets start under an incomplete read,
and a settled list that is no `Set`. `the saved environments a takeover looks up are the ids the
decision reads, …` holds `linkedEnvironments` to the ids `decideLinked` gives a preset, and `the
presets-file note names the file, …` compares both note texts, and `the profiles-folder note names
the folder that could not be listed, …` compares that note. `DF12` in the verdict suite runs both
`trail.mjs` copies in a home of its own. A record in a profile store has linked sessions that name a
saved environment only Claude's default folder lists (named, in `--json` and on the brief's line),
one the own file describes differently from the default folder (the own name), one two other files
describe differently (unnamed, starts) and one whose other descriptions disagree with an SSH side
(stays as `ssh`, and its brief line names no start). With another store's presets file unparsable,
the sessions it could decide wait as `presets-unread`, the SSH one included because its only SSH
description is in that file, while the one the own file names still starts, and `presetsUnread` and
the brief's note name the file as `unreadable`; with the file group writable instead, the same
sessions wait and both name it as `refused`, the note with every cause the reader reports under that
state. With that store's folder group writable instead, the same sessions
wait while the SSH one stays, and the folder is reported as `storeFolders`' refused `presets` entry
and named in the brief's note; the skipped count is not graded there. With the own profile's folder
group writable, the own file settles nothing, so the session it names stays as `ssh` once another
file names its preset SSH, also for a record whose own file lists every saved environment. A
group-writable default store still has its folder's presets file read, and so does a default store
that is a symbolic link to the store `ZENSU_CCD_EXTRA_STORES` names, where only that folder lists
an SSH preset (stays) and a local one (starts named) until an unlistable Session Hub profiles folder
leaves the read incomplete (skipped as root). There `presetsProfilesUnread` names that folder and the
brief prints its note, while the case that names every preset reports `null` and no note, and an own presets file beside
that store which lists both saved environments keeps the key `null` and the sessions decided by it,
the folder still unlistable. A record whose own file names every saved environment
reads and reports no other store's file, and `ZENSU_CCD_STORE` set to the profile store names only
what that store's own file lists. Eleven planted mutants were each caught by `DF12` against the code
of this change: the store lookup limited to accepted stores, the stay line, the settled ids ignored,
the early return without the completeness check, an empty `presetsUnread`, a `presetsUnread` without
its `refused` arm, an own read trusted whatever its state, the profiles folder ignored, the profiles
folder never named, named whatever the read reached, and its note dropped. The unit case `the store-folder remedy fits its cause and
its store: …` drives `storeFolderRemedy` for every cause, both sources, a known and an unknown
`desktopOwn` and every real-folder cause of a link, and `the store-folder note names the folder, …`
compares the whole note for every remedy with and without a link, each read set and an unknown
cause. `OM12` in the same block runs the `OM9` running session against the folder that holds
the store: group writable, world writable with the sticky bit and named through a symbolic link in
`ZENSU_CCD_STORE`, with and without the running session's own record and with an own record whose
`sessionId` names no run, each `if-named`/`started-unread` while the continuation the read found
stays `started`, with the folder counted once as skipped, `storeFolderRefused` true and
`storeFolder` naming `shared-write`, `chmod`, no override, Claude Desktop's own store and both
reads; both briefs carry the whole note line, which removes the write bits of the group-writable
and the sticky folder, names the store's real path for the link to the private folder, where
`--json` reads the link, `real-path`, the override and Claude Desktop's own store, and asks for both
for a link to the group-writable folder; the takeover brief carries the why line. Where the real
path of `/tmp` belongs to another account, a store copied into a folder `mktemp -d` makes there
holds the same starts, `--json` reads `move` for an override that is not Claude Desktop's own, and
its note moves the store and changes no permission. The controls are
the private folder, also named through its real path, which decides normally with no note, the
run-less own record in the private folder, and a measured run in which no read judged the folder,
which reports `null` for both keys and prints no note; `OM9`'s why-line needle names the folder
too. `OM13` plants a record in a `v2` ledger directory beside the intact `v1` one, which holds
every session that could start as `if-named`/`ledger-unread` with the why line and a ledger note
that names the `edges` directory in the brief, keeps the session a read confirmed edge leaves
`continued` and lists the directory in `newerSchemaLedgers` with its count. On a host not running
as root, a `v2/edges` that cannot be listed holds the same starts with a `null` count and a note
that names `v2` as uninspected, and so does a folder of schema directories that cannot be listed,
with a `null` version; a `v2` that is a symbolic link to a populated directory holds them too.
Its controls are an empty `v2` directory, a populated `v0` one and the restored ledger, each with
an empty list. `L13g` in `test-session-trail-lineage.sh` backfills a successor transcript modified
two days ahead and requires its edge stamped no later than the apply with nothing refused, and
`L13g-control` requires the past successor's own modification time on the edge already written.

**Known gaps, accepted and named:**

- **Starting every session marked start is the receiving model's tool call.** The brief and the
  step make it mandatory and name the shapes that broke it, but no hook checks that the plan
  confirmation named each one or that each was started. A check that refuses a turn would add a
  hook that can deny, which is a `minor` release.
- **The carried names are the model's reading of the plan answer.** The script checks their shape
  and which listed sessions they name, never that the user approved them, so a name the model adds
  or drops changes what starts. The plan brief spells the value for a yes that changes nothing,
  which leaves the model only the user's own changes to apply.
- **The refusal counts the listed sessions only.** A session past `LINKED_LIST_MAX` that could
  start does not arm it, and the brief does not list such a session, so no run can start it from
  its brief either.
- **Two descendants can still count although they never follow.** One started from an SSH saved
  environment without `sshConfig` counts unless a listed session also names a saved environment
  and a presets file that lists its preset was read, because `linkedSessions` reads the presets only
  then and looks beyond the own file only for the ids the open sessions name; one that
  already continues elsewhere counts when the ledger read was incomplete.
- **A preset no presets file read lists leaves the read complete while every folder that holds a
  file read passes the owner and mode rule.** Its kind is unknown, so an SSH session without
  `sshConfig` started from a since-deleted preset starts; the measurement in the fail-safe
  paragraph found no SSH-preset record without `sshConfig`.
- **Any other store can hold the starts its file could decide.** A refused folder or an unreadable
  presets file beside any other store candidate, another account's profile included, leaves the read
  incomplete for every id a complete own read does not settle, so each linked session that names such
  an id and carries no `sshConfig` waits as `presets-unread`; one whose preset a complete own read
  names still starts. With the own folder refused, nothing is settled and every such session waits.
  Measured on 2026-11-18, every one of the eleven folders that held a store on that Mac was `0700`
  and the user's own, so the rule refuses nothing there.
- **A data folder whose store folder is missing is not read.** The read reaches a presets file only
  beside a store candidate that exists, so the presets of a Claude data folder whose
  `claude-code-sessions` is gone stay unread, and the ids only they describe read as listed nowhere,
  the answer of before. Whether Claude Desktop keeps a presets file without its store folder was not
  measured.
- **Nothing above the folder that holds the store is judged.** The presets read and the started set
  judge that folder, and the store and the folders below it are judged as they are entered, so an
  account that can write a folder further up could still put another folder of the user's in its
  place. Such a folder holds no record of the session taken over, so nothing starts from it, unless
  it is an older copy, which can lack the continuations the running session already started; the
  measurement in the fail-safe paragraph found the folder that holds the store `0700`.
- **A Claude application-data folder that is a symbolic link holds every start that the saved
  environments or the started set decide** until the store's real path is named, which the brief's
  note says.
- **With no own record found, one unread store entry holds every start.** A session that runs
  outside Claude Desktop, over a store with a refused or unreadable entry anywhere, waits for names
  it would have started, because that entry may be its own record. A record caught mid-write reads
  as unread for that run only; running `takeover` again settles it.
- **The host id is trusted to name the running session's record.** A process that inherits another
  session's `CLAUDE_CODE_HOST_SESSION_ID` and carries a CLI id no record holds reads that session's
  started set, which can only keep more sessions. Without a host id, a record whose `cliSessionId`
  key is escaped is still missed, the prefilter bound `.claude/rules/session-trail-targeted-lookup.md`
  names.
- **Every Claude rule above is one bundle build's reading.** The admission of a start on the
  answer turn, the record fields of a started session, the kept `name` and `title`, `use_worktree`
  without `sharedCheckout` and the place approval for `cwd` need the Hub's live checks (H11) before
  a release ships the step.
- **Whether the first message of a started session runs as a slash command is unmeasured.** The
  prompt therefore names the Skill tool too.
- **The `cont-` handle joins on eight hex digits.** Two old runs that share them would both read as
  started once one of them is.
- **The edge read covers the `v1` ledger directory only.** A directory of a newer schema that holds
  records holds every start instead of being read, and so does one the census could not inspect,
  while one of an older schema is neither read nor counted, because no build before `v1` wrote one;
  a `confirmed` tier is a claim any local process can write.
- **The census inspects without reading.** It counts the `.json` names in a newer `edges`
  directory and never opens one, so a planted name or an empty file holds every start as a real
  record would, the price of never reading a schema this build does not know.
- **The store and presets paths are verified on macOS only**; Windows and Linux are the inferred
  candidates of `ccdStoreCandidates`.
- **The receiving folder is the working directory of the `takeover` process**, not the folder
  Claude Desktop records for the session that runs it, as for the chips. A start that carries
  `cwd` lands in the right repository either way; one that leaves it out trusts that directory.
- **A start with `cwd` names a folder that may be gone.** A removed checkout cannot be measured,
  so its session starts there and Claude Desktop answers the place, which the step tells the user.
- **Every listed session's folder is measured where it lies** once a folder of the old session is
  measured, under `--no-git` and on the plan pass too. `.claude/rules/session-trail-open-chips.md`
  names that bound; only a folder that opens with two separators is skipped.
- **A reader of a written takeover brief decides its own place.** The `folder` line asks a session
  working outside the old repository to pass that folder as `cwd`, and nothing checks that it
  does; re-running `takeover` from its own folder gives it a measured brief instead.

**Version: `patch`.** Walked against `.claude/rules/runtime-lineage.md`: no context-record or
workflow-state field, no strict key set (the Hub reads the contract file permissively, and only
tests read it in this repository), no hook added, removed or renamed, no matcher, config key or
attestation change, and the edge record `session-lineage-v1.mjs` writes keeps its shape. New `--json` keys and new brief and
skill text are patch-class, as they were for the open chips; so are `linkedSessions.sameRepository`,
`linkedSessions.oldRepositoryMeasured`, each entry's `cwdWhy`, the `place` reason, the repository
verdict behind `sameCheckout` and the brief's `folder` block, and so are each entry's `openBelow`
and the every-yes text. The spec read the new contract key
and the new flow step as minor; neither is in the policy's breaking list. `--linked-start` is
`patch` on the same walk: a new flag of a skill script, a new `why` value, each entry's `planned`
and `linkedSessions.plan` are exchanged `--json` keys no strict validator reads, and nothing is
persisted. Its refusal of a `--force` run without the flag tightens one verb inside one
installation and names the flag that answers it, so a session that read the older step 1 and is
served by this build recovers on its next command; no hook can deny anything new. The two
fail-safe rows are `patch` on the same walk: `presets-unread` and `started-unread` are new `why`
values of an exchanged `--json` shape no strict validator reads, they only turn a `start` into an
**if named** decision an older brief reader already handles, and nothing is persisted. Counting
refused ledger records toward `ledger-unread` and judging the presets folder are `patch` on the
same walk: no new `why` value, config key or persisted field, both decide only through the existing
`ledger-unread` and `presets-unread` rows, and `linkedSessions.ledgerRefused` and the
`refusedRecords` and `refusedFiles` keys of `lineage --diagnose --json` are new keys of exchanged
shapes no strict validator reads. Its follow-ups are `patch` on the same walk: a ledger directory of
a newer schema, one the census could not inspect and the folder that holds the store decide only
through the existing `ledger-unread` and `started-unread` rows, `linkedSessions.newerSchemaLedgers`,
`linkedSessions.storeFolderRefused`, `linkedSessions.storeFolder`, `linkedSessions.storeFolders`
and each entry's `refused` and `named` are new keys of an exchanged shape, the `started-unread` why text changes its words and not its value, and the backfill's clamp
changes a value it persists, never the record's shape. `session-lineage-v1.mjs` gains the
read-only `schemaLedgerCensus`, behind which `otherSchemaLedgers` returns what it returned before,
and its `LEDGER_SCHEMA_VERSION`, `makeEndpoint`, `ENDPOINT_KEYS` and `buildEdge` are unchanged, so
the edge record's shape is byte for byte the same; `desktop-store-read-v1.js` gains
`ownedDirectoryRefusal`, which decides nothing. Reading the presets beside every store read is
`patch` on the same walk: it adds no `why` value or persisted field, `storeFolders` lists more
entries of its existing shape, `linkedSessions.presetsUnread` and `presetsProfilesUnread` are new
keys of an exchanged shape no strict validator reads, `presetsAcrossStores`, `linkedEnvironments`,
`presetsFileNote` and `presetsProfilesNote` are new
exports of the module and `presetsSettled` a new `decideLinked` option read permissively, and a
conflicting description only ever names nothing or keeps a session as `ssh`, an answer an older
brief reader already handles.
