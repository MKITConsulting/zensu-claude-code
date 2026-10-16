---
paths:
  - "hooks/lib/session-control-core-v1.js"
  - "hooks/lib/zensu-doctor-report.js"
  - "hooks/lib/zensu-tdd-phase.sh"
  - "skills/doctor/**"
  - "tests/session-control/session-control-core-v1.test.js"
  - "tests/structure/test-doctor.sh"
---

# Lock Holder Liveness (`holderMarkerState` and the start-time rule)

Both lock kinds in `hooks/lib/session-control-core-v1.js` — the per-session lock of
`withFileLock` and the external lease of `acquireExternalProcessLock` — and every recovery
sentinel decide staleness in `artifactStaleness`, and both acquisition loops pre-check through
`externalArtifactNeedsRecovery`. The order of evidence is the contract:

1. no readable owner record: stale once the file is older than `LOCK_STALE_MS` (30 s);
2. the owner pid is dead: stale;
3. win32 only: the holder marker of the record decides, on every attempt — held means live,
   free means the holder let the lock go: it exited, or gave the lock up after its own release
   failed (below);
4. a stored start identity that can be read now (Linux, macOS): stale on a mismatch;
5. otherwise the start-time rule (below).

## The holder marker (win32)

A Node process that owns a lock in its own name (`ownerPid === process.pid`) keeps an empty
file open beside it for the whole hold: `.<lock basename>.<record token>.marker`. That covers
`withFileLock`, every recovery sentinel, and the bash 4+ coprocess keeper of `_tdd_locked_run`
(`_tdd_core_lock_keeper`, `ownerPid: process.pid`). The bash 3.2 fallback owns the lease in its
shell's name (`process.ppid`) and its Node child exits after acquiring, so it creates none, and
no Windows bash is 3.2. The marker is opened with the raw flag `0x10000000`, libuv's
`UV_FS_O_EXLOCK` (share mode 0); Node 20 does not export the constant on Windows, but the bit
reaches libuv. Measured on `windows-2022` and `windows-2025` runners with Node 20.20.2: every
other open, from any process, fails with `EBUSY`, and the file opens again 5–18 ms after the
holder is killed. No clock and no helper process takes part.

**Holder, in this order** (`createOwnedArtifact` → `openHolderMarker`): write and close the
candidate record; open the marker with `O_RDWR | O_CREAT | O_EXCL | 0x10000000`; prove the
share mode by opening the marker a second time from the same process, which must fail with
`EBUSY`; only then `linkSync` the record into place. The self-probe exists because a volume or
a Node build that ignores the share mode would make every live holder read as free: an open
that succeeds, or fails with anything but `EBUSY`, closes the descriptor and unlinks the name;
the record is published without a marker when that unlink succeeds, and otherwise the attempt
is abandoned. `EEXIST` on the fresh 192-bit token means something
else sits at that name, so the attempt is abandoned (`null`, the loop mints a new token). Any
other create error unlinks the name, because libuv can create the file and then fail; the
record is published markerless only when the name is provably free (unlinked or `ENOENT`),
otherwise the attempt is abandoned. The marker is opened after the candidate on purpose: the
parent-swap case renames the lock directory from inside the candidate open, and Windows
refuses that rename while a share-0 handle is open inside the directory.

**Release** (`removeArtifactIfSame` → `retireHolderMarker`): the record leaves through its
quarantine first; only then is the descriptor closed and the marker unlinked, with up to five
attempts 10 ms apart on `EBUSY`, `EPERM` or `EACCES`, and every remaining error ignored, so a
committed critical section never reports a failed release because of a marker. Every failure
path of the holder's own release (`releaseOwnedLock`, `withRecoverySentinel`, a
`createOwnedArtifact` that linked but did not verify) runs `abandonHolderMarker` in a `finally`:
it closes the descriptor and unlinks the marker only when the lock file no longer names the
token. While the record may still be the holder's own, the closed marker stays, reads as free,
and the next contender reclaims the record at once. A release refused before `releaseOwnedLock`
(a token, kind or pid mismatch in `releaseExternalProcessLock`) keeps the marker, because the
rightful holder may be the calling process. Descriptors are kept in `heldHolderMarkers`, keyed
by token, so a path spelled differently at release still finds its descriptor.

**Contender** (`holderMarkerState`): a read-only open. `EBUSY` is `held`; `ENOENT` or `ENOTDIR`
is `absent`; an open that succeeds on a regular, empty, single-link file is `released`; anything
else (another error, a directory, a non-empty file, a file with a second link) is `unreadable`. `held` and `released`
decide on every attempt, outside the start-time probe schedule, so a holder that exits is
reclaimed on the next poll. `absent` and `unreadable` fall through to the identity and the
start-time rule. Off win32 the state is `not-applicable` and nothing is opened.

**Recoverer** (`recoverStaleLock`, `reclaimStaleArtifact`): `recoverStaleLock` judges the record
again under the recovery sentinel; `reclaimStaleArtifact`, which reclaims the sentinel itself and
holds none, judges it immediately before `removeArtifactIfSame`. Both decide through
`artifactStaleness` alone, so a dead pid is reclaimed whatever its marker reads, and a live pid
whose marker is held is never stale. A dead holder's marker that a foreign handle still holds
open therefore does not keep its record: the record goes, and the marker stays behind as an
inert orphan (§"Residuals"). A recoverer never unlinks a marker before the record is gone: a
recovery that dies or fails between the two steps must leave the free marker beside its record,
so the next contender still reads `released`; the opposite order would leave a markerless record
that only the start-time rule can judge.

## The start-time rule (records without a usable marker)

A lock is written by its holder, so the holder existed before the record's `created_at`. A
process now holding the recorded pid whose start lies more than `OWNER_START_SKEW_MS` (1 s)
after `created_at` cannot be the holder (`liveOwnerStartedAfterRecord`). On the bash 3.2 path
the record names the shell's pid and its Node child writes `created_at`. The shell is older than
its child, so the argument holds there only while the wall clock did not step back between the
shell's start and the child's: the `created_at` clamp below bounds a record by its writer's own
start, so it does not cover a holder that did not write the record (§"Residuals"). The lower
bound comes
from `processStartLowerBoundMs`: `/proc/<pid>/stat` plus `btime` on Linux, `ps -o lstart=` on
macOS, and on win32 a `powershell.exe` read of
`[System.Diagnostics.Process]::GetProcessById(pid).StartTime` with a CIM fallback inside the
same process, `-EncodedCommand`, a pinned environment and a 5 s timeout. A start that cannot
be read counts as not replaced. A record younger than the skew is never probed. Each Node
process probes one record generation (pid plus token) at most once per
`OWNER_START_PROBE_INTERVAL_MS` (2 s), keeps a `replaced` verdict for good, and clears the cache
at `OWNER_START_PROBE_LIMIT` (256) entries. The live-pid path of `externalArtifactNeedsRecovery`
probes only on attempts 0, 20, 60, 140 and 300 (`externalIdentityProbeAttempt`): the external
lease polls every 50 ms for 200 attempts, so it probes at 0, 1, 3 and 7 s; `withFileLock` polls
every 20 ms for 500 attempts and reaches all five.

On win32 the rule now judges only records without a usable marker: records written by a runtime
from before holder markers, by a holder whose self-probe failed, by a holder whose marker create
failed on a name proven free, and records whose marker reads `unreadable`. Measured cost of the PowerShell read on run
36716394774 (`windows-2022` and `windows-2025`, 4 vCPU, Node 20.20.2), warm p50 per call:
124–204 ms through `powershell.exe` (cold 157–335 ms), 250–466 ms for `Get-CimInstance`,
179–352 ms for `pwsh`, 43–81 ms for `cscript` with WMI (one cold call took 13.3 s), 48–65 ms for
`wmic` on 2022 (absent on 2025), against 40–59 ms for a bare `node -e 0`; under four CPU burners
the PowerShell read took 0.4–7.3 s, and on one job no call returned within 30 s. `Get-Process`
in a stripped environment took 11–22 s, which is why the environment is pinned the way
`skills/session-trail/scripts/trail.mjs` pins its own probe. PID reuse came at least 1.1 s after
an exit for sequential spawns (median 4.3–8.6 s) and at least 0.4 s for parallel ones (median
2.7–4.9 s). Under Git Bash `process.ppid` names a wrapper that exits with each Node child, which
is why `_tdd_locked_run` keeps the lease in the coprocess keeper on bash 4+. Linux assumes a
`USER_HZ` of 100, which every architecture Node supports uses.

## The `created_at` clamp

`createOwnedArtifact` writes `created_at` through `lockRecordCreatedAt`:
`max(Date.now(), ceil(performance.timeOrigin))`. `nowIso` is unchanged, so context records and
workflow documents keep their plain timestamps. The OS creation time preceded
`performance.timeOrigin` by 4–33 ms in 48 of 48 samples on the same run, and the unit case `a lock
record never dates from before the process start its readers see` re-checks that premise on
every host with a start reader. So a wall clock stepped back after the writer started cannot
date a record before its writer, which, for a record written by its own holder, is the one way
the start-time rule could call a live holder replaced. The clamp protects only records that a
clamped writer wrote in its own name, and it trades that steal for a wedge: a pid reused before
the stepped-back clock passes `created_at` plus the skew is never proven replaced, because the
verdict compares two fixed instants and only its age gate reads the clock, so the record stays
until that process exits or is removed by hand (§"Residuals"). Linux derives starts from boot-relative ticks plus `btime`, so a step after the
start moves `btime`, and a forward step of more than the skew can still make a live
identity-less holder look replaced; Linux writers always store an identity, so that needs a
record written without one.

## Why a marker file

A named mutex has no core Node API and would need a helper that outlives the holder; a named
pipe needs an event loop the blocked holder does not run, and its namespace is machine-wide;
`FILE_FLAG_DELETE_ON_CLOSE` makes a dead holder's marker vanish, which reads as `absent` and
gives no positive "released" state; holding the record itself exclusively would break every
reader of the record, including the token release from another process. The persistent share-0
marker is the only option that yields a positive released state and needs nothing from the
holder after creation.

## Diagnostics

`inspectLockArtifact` returns `marker` beside the other owned-state fields, and
`zensu-doctor-report.js` keys the `autopilot lease:` row on it before the identity arms
(`.claude/rules/autopilot-lease-row.md`): `held` renders the NOT-removable live-keeper arm and
never offers removal by hand; `released` renders a removable arm of its own, which says that the
holder let the lock go: it exited, or gave it up after its own release failed, so the row never
names a reused pid as the cause; `absent` and `unreadable` add one sentence to the arm that
cannot decide, and only `unreadable` names a free marker as a way out of it, because no marker
can turn free where none exists or off win32. EBUSY proves
that some process holds the file in a conflicting mode, normally the keeper, so the rows keep
their `ps -ww -p <pid> -o args=` check. The operator account of every row is
`skills/doctor/references/autopilot-lease.md`, which the doctor skill's Phase 2 names.

## Residuals

- **Volumes that ignore share mode** (a WSL `\\wsl.localhost` path, VM shared folders,
  user-mode file systems) are unmeasured. The self-probe turns them markerless, so they keep the
  start-time residuals below rather than losing mutual exclusion.
- **Markerless records keep the start-time residuals:** a reused pid that started within the skew
  of `created_at`; a start that cannot be read; an older runtime's record written after a
  backward clock step (it never ran the clamp, and no contender-side change can close that: the
  evidence has to come from the holder); a bash 3.2 lease whose record stored no start identity,
  after a backward clock step between the shell's start and its Node child's, because the clamp
  bounds the child and not the shell; and the clamp's own wedge, a pid reused before the
  stepped-back clock passes `created_at` plus the skew, which is never proven replaced, so the
  record stays until that process exits or is removed by hand. The CIM fallback of the win32
  reader has never run in CI: the runners are administrators in Full Language mode.
- **A foreign handle that refuses read sharing** (a backup agent, a scanner) matters only while
  the recorded pid is alive. On a record whose pid a live process reused, it makes the marker read
  `held`, which keeps that record for as long as the handle stays open. A dead pid is reclaimed
  whatever its marker reads, and the marker such a handle holds stays behind as an orphan.
- **Orphan markers:** a holder killed between the record's removal and the marker's unlink; a
  foreign handle that outlasts the five unlink attempts, which includes a dead holder's marker
  such a handle still holds when a recoverer reclaims the record; a dead holder's own marker whose
  handle rundown outlasts the five unlink attempts of the recoverer that reclaimed its record,
  because a dead pid is reclaimed without waiting for its marker; a release refused after a
  foreign removal of the record; an abandoned marker whose lock file could not be read or was
  changing when its holder looked (`lockOwner` threw or found it contended), once that file is
  gone or belongs to another holder; a self-probe or create failure whose unlink failed, where the
  attempt is abandoned and its closed marker stays; and a release by token from another process
  while the acquirer still holds its marker (the acquirer keeps the file until it exits;
  production never does this, because the keeper releases in-process and the bash 3.2 owner
  creates no marker). Orphans are empty files no record names, so no verdict reads them; nothing
  sweeps them.
- **A held marker refuses every open:** on Windows `git add` of a `.zensu/state` that is not
  gitignored, and removing or renaming the worktree, fail while a hook holds a lock there. The
  evidence runner's tree fingerprint relies on `.zensu/` being gitignored and must not exclude it
  by pathspec (`.claude/rules/evidence-runner.md`).
- **Unverified on a real kernel outside CI:** the same-process `EBUSY` that the self-probe relies
  on and the non-inheritance of the marker handle, which the Windows-only unit cases below pin and
  only `windows-shard-2` executes. The non-inheritance case spawns its grandchild `detached`,
  because Node documents that option as what lets a Windows child outlive its parent, and a
  grandchild that dies with the holder would prove nothing. No case measures an orphan rate under
  Defender.

## Tests

`tests/session-control/session-control-core-v1.test.js`. Portable, with `process.platform`
faked as `win32` (`WIN32_LOCK_CHILD`), each failing on the core before this change. Three need
nothing more: `a free holder marker reclaims a young record whose owner pid is alive, without a
start-time read`; `a holder marker that is not a free empty file proves nothing, so a young live
owner keeps its lock without a start-time read`; and `a holder marker that is not a free empty
file falls through to the start-time rule, which reclaims an old record whose pid was reused`.
The last two plant a non-empty file, a directory and a second link at the marker name, and only
the last tells "falls through" from "counts as live". The rest add a share-mode model over `fs.openSync`, `closeSync`,
`unlinkSync`, `renameSync` and `linkSync` (`SHARE_MODE_MODEL`): `a held holder marker keeps a live
owner even when its start time reads as replaced`; `a dead owner is recovered even while a foreign
handle still holds its marker, and that marker stays behind inert`; `a holder marker is tested on
every attempt, …`; `a holder opens its marker exclusively before it publishes and retires it only
after its record is gone`, which orders every generation of both locks' recovery sentinels the
same way; `only a lock held by its own process creates a holder marker`; `a holder never leaves
its marker open or behind when an acquisition or a release fails`, which for both lock kinds also
replaces a recovery sentinel while it is held and fails a sentinel's post-link verification; and
`a lock record written after the wall clock stepped back never predates its writer`.
Windows-only, real processes: `the kernel holds a live holder marker against every other open,
and frees it the moment the holder dies`; `a child of the holder does not inherit its marker, so
the marker frees when the holder dies`; and the win32 arms of `external process lock inspection
reports a live holder without taking the lease` (same-process `EBUSY`) and `external process
lease token capability releases across a different process` (the residual above). `serializes
true concurrent workflow mutations without lost revisions` asserts that sixteen writers leave no
lock artifact and no marker behind: that check runs on every host, bites only on win32, where
markers exist, and measures no rate. Start-time pins: `the start-time probe re-reads a live generation at most every two seconds and
keeps a replaced verdict`, `the darwin start reader runs a pinned ps and reads its lstart line as
UTC`, and `recovers a per-session lock whose recorded identity cannot be re-read but whose owner
pid provably started after the record`. `lockDirectoryFingerprint` reads `*.marker` entries by
`lstat` only, because the test process itself holds a marker while it inspects. Doctor:
`P1le27`–`P1le31` and `P1le10b` in `tests/structure/test-doctor.sh`.

## Version: `patch`

Walked against `.claude/rules/runtime-lineage.md`: lock records gain no field and the
`lockOwner` validator is unchanged (a marker is a separate file, never a record key); no
context-record or workflow-state field, no strict key set, no hook or matcher, no config key and
no attestation field moves. Mixed lineages stay safe in both directions: an older contender
ignores markers and judges a new holder by the start-time rule as before, and a new contender
reads an older holder's record as `absent` and does the same. An older recoverer leaves the dead
holder's marker behind as an orphan. `inspectLockArtifact` gains the read-only `marker` field,
which a renderer without the arms ignores.

**Port-relevant.** Core half: the marker functions, the staleness order, the recoverer's re-test
and the clamp. Host half: the doctor row wording. `zensu-codex`, `zensu-kiro` and
`zensu-antigravity` were not included.
