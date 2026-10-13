---
paths:
  - "skills/session-trail/scripts/trail.mjs"
  - "skills/session-trail/references/commands.md"
  - "tests/structure/test-session-trail-verdict.sh"
---

# Session-Trail Targeted Lookup (`idCandidateRows`, `siblings`, `keepOwners`, `ccdApp` in `skills/session-trail/scripts/trail.mjs`)

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
  sticky match at the first literal occurrence. A probe that finds it and maps it to another
  worktree skips the file; a miss, an empty value or a cut value falls back to the full row.
  Only plain-text `show` calls it; `show --json` returns before it. Measured on the same
  machine: the first cwd ends within 64 KiB in 2,416 of 2,420 transcripts.
- `keepOwners()` takes the keep keys of the live anchors it must attribute and builds a row only
  for an inventory entry whose session id hashes to one of them. The caller reads the map only
  at those keys.
- `ccdApp(id)` answers one session's desktop record. One pass reads every `local_*.json` into a
  reusable buffer and records the files in which a `"cliSessionId"` key carries each id; only
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
  Otherwise the probe can find a first cwd the row never sees and drop a real sibling.
- `CCD_RECORD_PATHS` has two writers, `ccdIndex` and `ccdApp`, and both keep the last match in
  walk order; `openTaskChips` calls `ccdApp` and then reads the path.
- The `T22` guards in `test-session-trail-skill.sh` pin the `projectDirs`, `entries`,
  `summarize` and desktop-store `readdirSync` statements by their spelling.

**Rows are detached.** `summarize()` returns `structuredClone(out)`. A regex capture that
survives `replace`, `trim` and `slice` unchanged is a view into the whole decoded transcript, and
`INDEX_CACHE` keeps rows until exit: 76 recovered rows held 249.7 MiB after forced GC on the
measuring machine. On Node 26 those transcripts are external strings, so a retention check must
read `external` as well as `heapUsed`.

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
