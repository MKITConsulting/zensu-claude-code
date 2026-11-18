---
paths:
  - "skills/session-trail/scripts/trail.mjs"
  - "plugins/session-hub/skills/session-trail/scripts/trail.mjs"
  - "hooks/lib/desktop-store-read-v1.js"
  - "plugins/session-hub/hooks/lib/desktop-store-read-v1.js"
  - "skills/session-trail/references/commands.md"
  - "plugins/session-hub/skills/session-trail/references/commands.md"
  - "skills/session-trail/scripts/linked-sessions-v1.mjs"
  - "plugins/session-hub/skills/session-trail/scripts/linked-sessions-v1.mjs"
  - "tests/structure/linked-sessions-v1.test.js"
  - "tests/structure/test-session-trail-verdict.sh"
---

# Session-Trail Targeted Lookup (`idCandidateRows`, `siblings`, `keepOwners`, `ccdApp` in `skills/session-trail/scripts/trail.mjs`)

**Two copies.** `/zensu:session-trail` is PLM's frozen copy of this skill; the
`session-hub@zensu` companion carries the maintained one as `/session-hub:session-trail`.
`.claude/rules/session-hub-companion.md` says which copy each check grades.

**A selector verb summarizes what its answer needs, not the machine.** `resolve()` used to build
the full index before it tried the exact-id tier, and `--all` drops the project-directory filter,
so every `show`, `takeover`, `handoff`, `adopt` and `release` process summarized every transcript
modified inside `--days` and JSON-parsed every Claude Desktop record. Measured on 2026-10-12 on
one machine: 2,415 transcripts (about 4.2 GiB decoded) and 3,034 records (335 MiB) per process,
27-31 s CPU and up to 931 MB RSS, and a Session-Hub takeover runs that verb sequence 4 to 6
times. After this change `show <uuid> --all --json` measured 0.34 s user CPU and 86 MB max RSS.
Two reads stay wide on purpose: every `local_*.json` is still read once as bytes, and only the
records that carry the id are parsed; plain-text `show` also reads the first 64 KiB of every
other admitted transcript to find its siblings.

**The decision, per consumer.**

- `resolve()` runs tiers 1 and 2 over `idCandidateRows`: the inventory entries whose file stem
  satisfies `matchesSessionId` or `matchesSessionIdPrefix` (6 characters or more), built through
  the same row builder and sorted by activity. Those two functions are the only definition of
  the id tiers: `idCandidateRows` filters with them and the ladder matches with them, over the
  candidate rows when there are any and over the full index otherwise. Tiers 3 to 7 always run
  over the full index, which `resolve()` builds lazily, so an id selector that settles at tier 1
  or 2 never builds it, while every other selector, the missing-selector order and the
  `no session matched` text are today's.
- `siblings()` filters the memoized index when one exists. Otherwise it reads the first
  `CWD_PROBE_BYTES` (64 KiB) of each admitted transcript and takes the first `"cwd":"…"` with a
  sticky match at the first literal occurrence, provided the line that holds it ends inside the
  window. When that line is a main-chain record of another session, the transcript is a fork, and
  the probe answers with `forkOwnCwd`, the value the row takes too
  (`.claude/rules/session-trail-fork-anchor.md`). A probe that finds a cwd and maps it to another
  worktree skips the file; a miss, an empty value, a cut value, a line that does not end inside
  the window and a fork with no own cwd fall back to the full row. Only plain-text `show` calls
  it; `show --json` returns before it. Measured on the same machine: the first cwd ends within
  64 KiB in 2,416 of 2,420 transcripts; on 2026-10-13 the line that holds it ended within 64 KiB
  in 2,561 of 2,565.
- `keepOwners()` takes the keep keys of the live anchors it must attribute and builds a row only
  for an inventory entry whose session id hashes to one of them. The caller reads the map only
  at those keys.
- `ccdApp(id)` answers one session's desktop record. One pass reads every `local_*.json` of every
  store into one reusable buffer, `RECORD_SCRATCH`, and records the files in which a
  `"cliSessionId"` key carries each id; only those files are parsed, and `settledRecord` decides
  what they answer: matches in two stores settle the id as ambiguous (`CCD_AMBIGUOUS`, no
  `CCD_RECORD_PATHS` entry), and inside one store the last match in walk order wins.
  `ccdIndex()` stays the full map for the surveys, settles every id through the same
  `settledRecord`, and reuses the same memoized file listing, so a directory that cannot be read
  is counted once and both walks write the same `CCD_RECORD_PATHS` entry.

**Coupled sites that must move together.**

- `buildIndexRow` is the ONE row builder for the full index and every targeted path, and its
  filters (window and live exception, 200-byte floor, cwd fallback, repo scope, activity cutoff)
  are the only place they exist; a filter added to a targeted path alone would let the two
  answers diverge. The row literal must stay the first `const row = {` in the file, because
  `worktree-advice-v1.test.js` locates it that way.
- A tier placed ahead of the id tiers, or a change to `matchesSessionId` or
  `matchesSessionIdPrefix`, changes which selectors the candidate rows answer.
- `worktreeOfCwd` is the one cwd-to-worktree mapping for the row, the probe and `selfIdentity`.
- `firstCwdOf` copies the first-cwd pattern of `summarize`, and its window must stay inside
  `HEAD_BYTES`, the head `readTranscript` keeps for a transcript above `FULL_READ_LIMIT`.
  Otherwise the probe can find a first cwd the row never sees and drop a real sibling. Both
  classify the line that holds the first cwd with `inheritedRecord` and answer a fork with
  `forkOwnCwd`; a probe that took a fork's first cwd as its directory would skip the fork beside
  a session in its own worktree and list it beside its parent.
- `CCD_RECORD_PATHS` has two writers, `ccdIndex` and `ccdApp`, and both write it only through
  `settledRecord`; `desktopRecordOf` calls `ccdApp`, answers `ambiguousRecordReason` with the
  stores `CCD_AMBIGUOUS` holds for an id there, and otherwise reads the path once, for `repositoryVerdicts`, `openTaskChips`,
  `linkedSessions` and `unreadReports` alike.
- `ccdAppEntry` is the one desktop-entry builder, and `ccdIndex` and `ccdApp` both call it.
  `DR3` in the verdict suite derives the stored key set from it and fails when either walk
  builds its entry another way.
- The `T22` guards in `test-session-trail-skill.sh` pin the `projectDirs`, `entries`,
  `summarize` and desktop-store `readdirSync` statements by their spelling.

**Rows are detached.** `summarize()` returns `structuredClone(out)`. A regex capture that
survives `replace`, `trim` and `slice` unchanged is a view into the whole decoded transcript, and
`INDEX_CACHE` keeps rows until exit: 76 recovered rows held 249.7 MiB after forced GC on the
measuring machine. On Node 26 those transcripts are external strings, so a retention check must
read `external` as well as `heapUsed`.

**Every desktop-store read passes the linked-session resolver's rule, from
`hooks/lib/desktop-store-read-v1.js`.** Store values steer session-trail steps no one
confirms: the takeover plan pass runs `stat` and `git` in folders the records name,
`isArchived` lifts the release busy gate, the store's account picks the saved presets behind
the `ssh` stay row and the account an edge endpoint records, and a record that is a FIFO
blocks a plain read. So session-trail applies the check `hooks/lib/linked-session-v1.js`
applies, from the same module, and defines no copy of it. On every platform it refuses a
symbolic link where a folder or a record is expected, a record that is not a regular file and a
record larger than `DESKTOP_RECORD_MAX_BYTES`; off Windows it also refuses an entry that another
account owns or that grants group or other write:

- `ccdStoreProbe` judges each store candidate that exists with
  `realDirectory(dir, writableOnlyByCaller)`, and every candidate that passes is a store the
  lookup reads (`stores`, `store` being the first of them). A refused candidate never is, and
  `lineage --diagnose` marks it `REFUSED`; when no candidate resolves, it names the permission
  fix rather than `ZENSU_CCD_STORE`, which is judged by the same rule. Every refused candidate
  counts as a refused entry, wherever it sits in the list, because the session's record could be
  in it: a session found in no accepted store reads as refused entries rather than as missing
  (`OM7`, `OM7b`). `ZENSU_CCD_STORE` stays authoritative, so a refused override leaves no store
  at all.
- `ccdRecordFiles` and `accountForHostSession` judge every folder they enter the same way, and
  refuse a symbolic link where a folder or a `local_*.json` is expected without following it.
  `ownedRegularFile` judges a record before the walk lists it and before the host-session probe
  answers with its account. `storeFolderVerdict` judges the folder that holds the store and
  `ccd-session-presets.json` the same way, once per process, before `savedPresets` trusts a missing
  file or the file's answers and before `startedContinuations` trusts the running session's started
  set, and a refused one counts once as a refused entry; `ownedDirectoryRefusal`, from the same
  module, names the cause the brief's note reports for it, and judges nothing
  (`.claude/rules/session-trail-linked-sessions.md`).
- Every record is read through `readBoundedBytes`: a regular file owned by the caller with no
  group or other write bit, judged on its `lstat` and again on the opened descriptor, opened
  with `O_NOFOLLOW` and `O_NONBLOCK`, at most `DESKTOP_RECORD_MAX_BYTES`. That covers the
  records behind `ccdIndex`, `ccdCandidates`, `ccdApp`, `desktopRecordOf` and `familyRecords`,
  and `ccd-session-presets.json` in `savedPresets`.
- `storeRecordBytes` hands the reader `RECORD_SCRATCH`, so the bytes it returns are a view the
  next read overwrites, and every caller decodes them before it reads another record. The
  resolver passes no scratch, so each of its reads gets its own buffer. A fresh buffer per
  record was measured on 2026-11-02 at about 205 MB max RSS for `show <uuid> --all --json`
  against 91 MB before the check; with the scratch buffer it measured 88 MB and 0.38 s user
  CPU, against 0.37 s before.
- A refused entry counts into `SKIPPED` once, through `CCD_REFUSED`. A session whose record was
  not read gets a reason that names the refusal: `STORE_REFUSED_REASON`,
  `RECORD_REFUSED_REASON` or `RECORDS_REFUSED_REASON`, while a missing store and a missing
  record keep their wordings. The reader returns one `refused` state for every cause, so each
  reason lists them all: the owner and write bits, the file type, the size cap and a failed
  open or read. `unreadableWhy` says `no readable` for the same reason.
- `storeRead()` loads the module lazily, only once a store candidate exists, and a tree without
  it fails with the plugin-tree-incomplete diagnostic, as `gitChildEnvironment` does.
  `mutant_path` and `cont_mutant` in the verdict suite copy it beside `trail.mjs`.

Costs, accepted: a group write bit is refused even where the group holds the user alone, as
under the umask 002 of a user-private-group setup, so such a machine shows no desktop data in
session-trail; the skipped count, `lineage --diagnose` and the brief reasons say so. The check
reads the owner and the mode bits only: write granted through an access-control list passes,
and on Windows neither is judged.
Measured on 2026-11-02 on macOS, the store, the 69 directories below it and its 4,170 records
belonged to the user with no group or other write bit, and the store held no symbolic link, so
the check refuses nothing there. `umask 022` heads `test-session-trail-verdict.sh` and
`test-session-trail-lineage.sh`, so their fixture stores pass under any runner umask. `OM0` to
`OM4` in the verdict suite pin the check, `OM0` as the control; against the code before the
check, `OM1` to `OM4` fail and the FIFO case hangs until its timeout. `OM5` pins the
plugin-tree-incomplete diagnostic and the lazy load, `OM6` a refused `ccd-session-presets.json`
in both forms, `OM7` a refused candidate passed over for a later one, `OM7b` a refused candidate
after an accepted one, which is counted too, `OM8` and `OM9` the decisions a refused presets file and a refused,
unparsable or unlisted record of the running session leave (`presets-unread` and `started-unread`,
`.claude/rules/session-trail-linked-sessions.md`), `OM10`, a ledger check that shares the block,
the refused ledger records behind `ledger-unread`, `OM11` the decisions a refused presets folder
leaves, `OM12` the started set and the note, cause and remedy a refused store folder leaves,
`OM13`, a second ledger check, a ledger directory of a newer schema and one that cannot be
inspected, and `L19b` and `L19c` in the lineage suite the
null account an edge records when the host-session probe meets a refused workspace folder, account
folder or record. `L3j`, `L3k` and `L3l` in `test-linked-session-route.sh` pin the one owner, the
named `realDirectory` policies and the scratch buffer.

**Where the stores are: Claude's default folder, every Zensu Session Hub profile and every store the
user names, and all of them are read.** A Claude Desktop launched with `--user-data-dir=<folder>`
keeps its records in `<folder>/claude-code-sessions`, and the Zensu Session Hub runs every account
that way, under `~/Library/Application Support/Zensu Session Hub/Claude-Profile/<hub account id>`.
A lookup that probed Claude's default folder alone answered "no record" for every moved session.
Measured on 2026-11-17 on the machine where three moves stranded their linked sessions: the default
store held 0 records and ten canonical profile folders held them all. `ccdStoreCandidates`
therefore lists, in this order:

- every store `ZENSU_CCD_EXTRA_STORES` names (`namedStoreCandidates`), a list split at the
  platform's path delimiter whose blank entries name none. The named stores come first, so a named
  real path wins the `SAME AS` pairing against a discovered spelling of the same store. The
  store-folder remedies rely on that order: for a discovered store whose folder is a symbolic link
  they tell the user to add the store's real path to this variable, and that store's real folder is
  then the one judged while every other store stays read (`DF9`).
- the default list;
- every Session Hub profile folder whose name is a canonical lowercase UUID (the Hub's own
  `canonical_id` rule in `src-tauri/src/data_folders.rs`), sorted, from `hubProfileFolders`. A
  stopped source Claude is still found this way: the Hub moves a session that is not running from
  its saved source (`resolve_source` in `src-tauri/src/session_move.rs` falls back to
  `Source::saved` on `error.moveNotRunning`), and two of the ten profiles had no running Claude
  when it was measured. A profiles folder that exists and cannot be listed counts once as unread in
  `ccdStoreProbe` and nowhere else; `lineage --diagnose` names it on an `UNREAD` line and as
  `profilesUnread`, and a session no read store holds then reads `PROFILES_UNREAD_REASON` rather
  than a plain miss (`DF11`).

**No store comes from a process's arguments (decision 2026-11-18).** A confined process of the same
user can start a process named `Claude`, the genuine Claude binary included, on a folder of its own
inside the home, and records planted there could make a real session ambiguous, carry chips and
linked-session start calls into a brief, or mark a live session archived, which lets `release` drop
its `source-busy` blocker. A location the Hub or Claude Desktop owns cannot be planted that way, and
a store the user names is the user's own trust decision. So a Claude Desktop on a data folder of its
own outside the Hub is read once its store is named in `ZENSU_CCD_EXTRA_STORES`, and `DF7` pins
that neither copy reads `--user-data-dir`.

Candidates are deduplicated by spelling (`distinctCandidates`), and two accepted candidates with
one real path are read once: the later one is listed `SAME AS` the first (`sameAs`), so a store
reached through a symlinked folder is not read twice and does not make every session ambiguous.
**A session id whose record two stores hold is read from neither** (`ambiguousRecordReason`, which
names the stores), because which copy is the session's own cannot be told and a guess would carry
another account's chips and linked sessions. `accountForHostSession` and `hostNamedRecord` apply
the same rule to the host session file, so the account an edge records and the running session's
own record are never taken from a copy. `ZENSU_CCD_STORE` stays the only store while it is set: no
default, profile or named store is probed as a candidate or read, and `lineage --diagnose` lists
the override alone (`DF6`). One check still looks past it on purpose: `desktopOwnStore`, which
picks the remedy for a refused folder that holds a named store, compares that store with every
discovered candidate of `ccdStoreCandidates(true)`, the profile folders included and the named
stores left out, so a profile store named through either variable keeps the remedy of Claude
Desktop's own store. That check lists the profiles folder, reads no record, counts nothing and
decides no linked session.

**The suites stay hermetic by clearing both variables.** `ZENSU_CCD_EXTRA_STORES` can name a store
outside `HOME`, so the verdict, lineage and linked-session-route suites unset it at the top beside
`ZENSU_CCD_STORE`, and every `DF` runner clears both.

**Pins.** The `DF` family in `tests/structure/test-session-trail-verdict.sh` runs under both
`trail.mjs` copies, on POSIX hosts, against a home with an empty default store, two profile stores,
a profile folder that is no UUID, a store in a folder with a space that only `ZENSU_CCD_EXTRA_STORES`
names and a store outside every candidate. It pins the probe list in text and `--json` with and
without named stores (`DF1`), a record in a profile store with its chips, linked session, preset
and report (`DF2`), a named store, its blank entries and its refusal (`DF3`), one id in two stores
with both named in the reason (`DF4`), a refused profile store (`DF5`), the override over both
variables (`DF6`), the folders that are no candidate and the absent process source (`DF7`), the
host account across stores (`DF8`), a profile folder that is a symbolic link and the additive remedy
that reads it through its real folder (`DF9`), the store folder each read judged and the started
set's branches with a running session (`DF10`, `.claude/rules/session-trail-linked-sessions.md`)
and an unlistable profiles folder (`DF11`, skipped as root). `WR4b` pins the release line for a
source in another data folder of the same account.

**Bounds, accepted and named.**

- The Session Hub profile path is the macOS one, so on Windows and Linux only the default
  candidates and the named stores are read; a Claude Desktop there on a data folder of its own needs
  its store in `ZENSU_CCD_EXTRA_STORES`.
- A Claude Desktop on a data folder of its own outside the Hub stays unread until its store is
  named: its sessions read as having no record, and a takeover run from one of its sessions holds
  every linked session that could start as `started-unread`, because the host id names a record
  no read store holds.
- A refused candidate that is another spelling of an accepted store is counted as refused,
  although the store is read through the accepted spelling; that is the fail-safe direction.
- The resolver of a linked session's delivery route, `storeCandidates` in
  `hooks/lib/linked-session-v1.js`, reads the named stores, its platform's default store and the
  Session Hub profile stores in the order `ccdStoreCandidates` probes them, but probes the profile
  path on macOS only, takes no other platform's default and refuses a relative entry; it answers an
  own record two stores hold with `none` (`own-record-ambiguous`), and counts toward that answer
  every entry under the record's name, a refused one included, where this skill counts only the
  records it accepts (`.claude/rules/session-delivery-route.md`). `L3o` in
  `tests/structure/test-linked-session-route.sh` holds the two macOS candidate lists equal.
- The SKIPPED count covers only what the command read, and `references/commands.md` says so.
  For the same reason the NOTE of plain-text `show` can count transcripts that `show --json`,
  which never probes siblings, does not read.
- The desktop prefilter finds a record only where its `"cliSessionId"` key is spelled without
  escapes; the value itself is decoded with `JSON.parse`. A serializer that escapes ASCII in a key
  would make the targeted path miss a record the full walk finds.
- A transcript that changes between the probe and the full row is judged by the probe for the
  skip decision.

**Pins.** The `TL` family in `tests/structure/test-session-trail-verdict.sh`: a read trace and a
desktop-record parse count through an `--import` preload, targeted-versus-full equivalence for
`show --json`, `takeover --json` and the SIBLINGS line, the out-of-window fallback, the prefix
ambiguity, the retention delta against a control, two desktop records carrying one id (`TL9`),
siblings the probe cannot place (`TL10`) and the read scope of `release` keep-owner attribution
(`TL11`). Against the code before this change seven of its twelve checks fail; the five that
pass are the behavior-preservation controls.

**Version: `patch`.** No schema field, strict key set, hook, matcher, config key or attestation
change; `session-lineage-v1.mjs` is untouched.
