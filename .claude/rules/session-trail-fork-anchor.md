---
paths:
  - "skills/session-trail/scripts/trail.mjs"
  - "skills/session-trail/references/gotchas.md"
  - "tests/structure/test-session-trail-verdict.sh"
---

# Session-Trail Fork Anchor (`sessionAnchor`, `forkOwnCwd` and `firstCwdOf` in `skills/session-trail/scripts/trail.mjs`)

**A session's directory is the cwd of its first own record**: the first record that carries the
session's own id (the transcript's file stem, `transcriptSessionId`) and a `cwd`. For a session
that is not a fork this is the transcript's first record, the rule `references/gotchas.md` has
always stated for a session that `cd`-ed into a subdirectory, and `sessionAnchor` keeps that path
byte for byte: `firstMatch` over the read text.

**A fork opens its transcript with its parent's records.** Claude Desktop's fork and
`--fork-session` copy the parent's records into the new transcript, and the copies keep the
parent's `sessionId`, `cwd` and `gitBranch`. Observed with session 2b1e0da2 on 2026-10-13: its
first 5,696 records carried the parent's id, its own `custom-title` record followed, and its
first own record with a `cwd` named its own worktree. The first-record rule therefore resolved
the fork to its parent's worktree and branch in `show`, both briefs, `release` and the lineage
edge.

**Detection is one predicate, `inheritedRecord`, on the line that holds the first `"cwd":"`**:
the line parses, has a non-empty top-level `cwd`, a string `sessionId` that is not the
transcript's own, and `isSidechain` is not `true`. Measured on 2026-10-13 over 2,565 transcripts:
that record was the session's own in 2,253, a main-chain record of another session in 164 (the
forks), a sidechain record of another session in 146 (subagent transcripts, which hold no record
of their own and keep the first-record rule), and 2 had no cwd in the first 256 KiB. In all
2,563 that had one there, the first `"cwd":"` was a top-level key of a parseable line.

**Which signal wins, and why.**

- **The fork's own records.** They are what the session wrote, they follow the same rule as a
  session that is not a fork, and they survive the process. The branch is the last valid
  `gitBranch` from the line of the first own-id occurrence on; `cwdLast` is read from the same
  range.
- **The live registry's `cwd`, only when the fork has no own record with a `cwd`.** That is the
  existing `buildIndexRow` fallback, unchanged: `summarize` returns a null `cwd` for such a fork.
  The registry never outranks the transcript, because it names the directory the CURRENT process
  started in: for 5 of 8 live forks it named another directory than the first own record.
- **The desktop record, never.** Its `cwd` is the directory the app launches the session in: the
  main checkout when a worktree hook moves the session, and a later directory once the session
  has moved. Of 137 desktop forks with an own cwd, it disagreed with the first own record in 66,
  and `worktreePath`, often null, in 109. `forkedFromSessionId` adds nothing either: of the 156
  desktop forks with a transcript, the 143 that carry their parent's records are found by the
  predicate above, and the 13 that do not hold no record to skip.
- **A fork with neither has no recorded directory** and gets no row, like any session whose
  transcript names no `cwd`. Ten forks had no own record with a `cwd`, and none of them was live.

**`forkOwnCwd` locates the fork point by bisection, because a linear scan is too expensive.** 119
of the 164 forks exceed the 8 MiB full-read limit, and in 103 of them the first own record lies
past the 256 KiB head. A forward scan to the fork point read 2,008 MiB for those 119; the
bisection read 156 MiB, and it returned the same cwd as an exhaustive scan for all 164 forks.
It rests on two facts:

- **Construction:** the fork's id did not exist when its parent's records were written, so the
  key `"sessionId":"<own id>"` never occurs before the fork point. `forkSide` classifies the first
  complete line after a probe offset as own when it contains that key and as another session's
  when it contains a `"sessionId":"` key without it.
- **Layout, measured rather than guaranteed:** all records after the first own record are the
  fork's own. No fork had a main-chain record of another session after it. The lower bound
  moves only past a complete line classified as another session's, so the final forward scan
  from it is exact while this holds.

A window with no classifiable complete line, up to `FORK_PROBE_MAX`, only lowers the probe's
upper bound and costs reads; it never moves the lower bound. Every loop advances by at least one
byte, and an unreadable file throws into the callers' existing `SKIPPED` accounting.

**Coupled sites.**

- `sessionAnchor` feeds `summarize`'s `cwd`, `cwdLast` and `branch`, so `buildIndexRow`,
  `hydrate`, every selector verb and `endpointFromRow` see the fork's own tree with no change of
  their own.
- `firstCwdOf`, the sibling probe, classifies the same line with `inheritedRecord` and answers a
  fork with `forkOwnCwd`, so the probe and the row agree.
  `.claude/rules/session-trail-targeted-lookup.md` records the probe.
- The fork bullet in `skills/session-trail/references/gotchas.md` states the rule and the
  precedence for the model.

**Pins.** `FK0` to `FK9` in `tests/structure/test-session-trail-verdict.sh` build a git repository
with parent, fork and taker worktrees, a fork transcript that opens with the parent's records, a
live registry entry and a desktop fork record that names the parent's worktree. They cover `show
--json` (worktree, cwd, branch, git branch, `writes`, `continuation`), the `show` text lines, a
`release` dry run, the lineage edge a `takeover` records, the registry fallback, a fork with no
directory, the SIBLINGS line in both directions, and the first-record rule for a session that is
not a fork and for a subagent transcript. `FK9` drives the bisection: a transcript past the 8 MiB
limit whose fork point lies between the head and the tail, whose first own record is longer than
one read chunk, and whose tail shows only a nested worktree. Against the code before this change
eight of the ten fail; `FK0` and `FK7` are the controls.

**Bounds, accepted and named.**

- **Some desktop forks open with records under their own id.** Thirteen do; of four inspected,
  two carried copies of their parent's records under the fork's id, and in both the fork's first
  own turn ran in the directory the copied first record names, so the first-record rule names the
  right tree there. Such a fork is not detectable from its transcript, and the other nine were not
  inspected.
- **Only the directory and the branch come from the own records.** The prompt timeline, the
  touched-file list, the pull-request line and the activity read the whole transcript, inherited
  records included.
- **The layout fact above is a measurement on one machine.** A fork that wrote another session's
  main-chain record after its own could resolve to a later own record.

**Version: `patch`.** No context-record or workflow-state field, strict key set, hook, matcher,
config key or attestation changes; `--json` keeps its keys and their types; and
`skills/session-trail/scripts/session-lineage-v1.mjs` is untouched, so the ledger's endpoint shape
is byte-identical.
