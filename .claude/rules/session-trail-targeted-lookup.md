---
paths:
  - "skills/session-trail/scripts/trail.mjs"
  - "plugins/session-hub/skills/session-trail/scripts/trail.mjs"
  - "hooks/lib/desktop-store-read-v1.js"
  - "plugins/session-hub/hooks/lib/desktop-store-read-v1.js"
  - "skills/session-trail/references/commands.md"
  - "plugins/session-hub/skills/session-trail/references/commands.md"
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
- `ccdApp(id)` answers one session's desktop record. One pass reads every `local_*.json` into one
  reusable buffer, `RECORD_SCRATCH`, and records the files in which a `"cliSessionId"` key carries each id; only
  those files are parsed, last match in walk order wins, and `CCD_RECORD_PATHS` gets the same
  entry the full walk writes. `ccdIndex()` stays the full map for the surveys and reuses the same
  memoized file listing, so a directory that cannot be read is counted once.

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
- `CCD_RECORD_PATHS` has two writers, `ccdIndex` and `ccdApp`, and both keep the last match in
  walk order; `desktopRecordOf` calls `ccdApp` and then reads the path once, for
  `repositoryVerdicts`, `openTaskChips`, `linkedSessions` and `unreadReports` alike.
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
  `realDirectory(dir, writableOnlyByCaller)`. A refused candidate never becomes the store, and
  `lineage --diagnose` marks it `REFUSED`; when no candidate resolves, it names the permission
  fix rather than `ZENSU_CCD_STORE`, which is judged by the same rule. A refused candidate ahead
  of the winning one also counts as a refused entry, so when a later candidate wins and holds no
  record of the session, the brief says store entries were refused rather than that the record
  is missing. A refused candidate after the winning one is never read, so it is marked but not
  counted. `ZENSU_CCD_STORE` stays authoritative, so a refused override leaves no store at all.
- `ccdRecordFiles` and `accountForHostSession` judge every folder they enter the same way, and
  refuse a symbolic link where a folder or a `local_*.json` is expected without following it.
  `ownedRegularFile` judges a record before the walk lists it and before the host-session probe
  answers with its account. `savedPresets` judges the folder that holds `ccd-session-presets.json`,
  the parent of the store, the same way before it trusts a missing file or the file's answers, and
  a refused one counts once as a refused entry
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
after the winning one, `OM8` and `OM9` the decisions a refused presets file and a refused,
unparsable or unlisted record of the running session leave (`presets-unread` and `started-unread`,
`.claude/rules/session-trail-linked-sessions.md`), `OM10`, a ledger check that shares the block,
the refused ledger records behind `ledger-unread`, `OM11` the decisions a refused presets folder
leaves, and `L19b` and `L19c` in the lineage suite the
null account an edge records when the host-session probe meets a refused workspace folder, account
folder or record. `L3j`, `L3k` and `L3l` in `test-linked-session-route.sh` pin the one owner, the
named `realDirectory` policies and the scratch buffer.

**Bounds, accepted and named.**

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
