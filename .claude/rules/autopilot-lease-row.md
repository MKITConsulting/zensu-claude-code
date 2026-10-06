---
paths:
  - "hooks/lib/zensu-doctor-report.js"
  - "hooks/lib/session-control-core-v1.js"
  - "hooks/lib/zensu-tdd-phase.sh"
  - "hooks/lib/zensu-autopilot-state.sh"
  - "skills/doctor/**"
  - "tests/structure/test-doctor.sh"
  - "tests/session-control/session-control-core-v1.test.js"
---

# Autopilot Lease Row (`leaseRow` in `hooks/lib/zensu-doctor-report.js`)

`/zensu:doctor` renders the `autopilot lease:` rows for the Autopilot project lease: the
external process lock that `_autopilot_locked_run` takes through `_tdd_locked_run`, with lock
directory `<root>/.zensu/state` and resource path `<root>/.zensu/state/autopilot`. Every
Autopilot state read ends in that lease, so a lease that never clears makes those reads fail
while the run records look healthy. The rows are the diagnostic for that state.

**The rows are read-only, and that is the contract.** The row resolves the artifact through the
exported `externalProcessLockPath({ lockDirectory, resourcePath })` and judges it through
`inspectExternalProcessLock` with the same options. Neither takes the lease, writes or deletes.
The row says when an artifact is removable; the doctor never removes it, and
`skills/doctor/SKILL.md` tells the model never to offer that, because Phase 3 stays the
pending-review cleanup alone. `P1le1` in `tests/structure/test-doctor.sh` pins that the lease
block of the renderer reads nothing on its own, `P1le6` that a report leaves a removable
artifact byte-identical, and `P1le4` holds the real lease through `_autopilot_locked_run` while
the report runs, so it also proves the row reads the artifact production writes.

**The verdict is the core's, never a copy.** `inspectExternalProcessLock` in
`hooks/lib/session-control-core-v1.js` reads the lock artifact and the recovery sentinel with
`lockOwner` and judges both with `artifactStaleness`, which `artifactIsStale` wraps, so
"removable" is exactly what the next acquisition reclaims. A copy of that logic in the renderer
could drift from `lockOwner`, and a relaxed `lockOwner` would leave the copy stricter than the
core, the direction that calls a live lease removable; so the row renders only what the
inspector returns. The unit case `external process lock inspection
calls an artifact stale exactly when acquisition reclaims it` holds the verdict against a real
`acquireExternalProcessLock` for every fixture shape. The inspection states:

- `absent`, and `changing` when the file exists but `lockOwner` found it contended;
- `refused` with a `cause` of `symlink`, `irregular`, `oversized` or `unreadable`, whenever
  `lockOwner` throws. `acquireExternalProcessLock` calls `lockOwner` unguarded, so every
  acquisition fails on such an artifact, and `removeArtifactIfSame` never reclaims it. An owner
  record whose `created_at` cannot be converted to a string is one of them: it throws inside
  `lockOwner`, and the inspector returns it as refused, so it never throws out of the renderer
  (`P1le21`);
- `ownerless` with `stale` and `mtimeMs`;
- `owned` with `pid`, `alive`, `identityRecorded`, `identityCurrent`, `startedAfterRecord`,
  `createdAtMs` and `stale`. `startedAfterRecord` says that the process now holding a live pid
  provably started after the record was written, which is the second way a live owner turns
  stale (`.claude/rules/deferred-review-claim-ownership.md` §"Lock staleness"); the row names
  that cause instead of a start-identity mismatch. The token and the release digest are never
  returned.

**The row ages every artifact on the inspection's own clock.** The inspector returns
`inspectedAtMs`, sampled after both reads, and the row measures `created_at` and the owner-less
modification time against it, never against the report's start clock. A lease another hook
takes while the report runs is younger than the report, so aging it on the start clock would
render an ordinary live lease as future-dated (`P1le25`).

**The recovery sentinel is judged the same way.** While `.external-<digest>.recovery` exists,
`acquireExternalProcessLock` reclaims it or waits and never reaches the lock file, so the row
never reads "free" while a sentinel exists and renders the sentinel's own verdict beside the
lock's (`P1le22`).

**Removal by hand is named only where the core cannot decide.** A live owner without a recorded
start identity, or with one that cannot be re-read now, is reclaimed only once the process
holding that pid provably started more than a second after the record was written. Without that
proof the core never reclaims it while the pid lives, and the row says the doctor cannot
establish whether the pid is still the lock keeper. It names
what a live lock keeper looks like, and both shapes are load-bearing: under bash 4 or later
`_tdd_locked_run` runs a coprocess `node` keeper that owns the lease itself
(`ownerPid: process.pid` in `_tdd_core_lock_keeper`), and under bash 3.2 the owner is the shell
that runs `_tdd_locked_run` (`ownerPid: process.ppid`). On Windows no start identity exists, so a
lease older than 30 s lands in this arm unless its pid provably started after the record, and
its live owner there is the `node.exe` keeper. The recovery sentinel has one shape: `withRecoverySentinel` records the node process
that runs the core, under any bash. The row says removal by hand clears the artifact only when
the pid is neither shape, and it never calls that artifact removable.

**The hung remedy ends the shell that runs `_tdd_locked_run`, with every process under it.**
Under bash 4 or later the keeper runs inside a coprocess shell, so the shell that runs
`_tdd_locked_run` is the keeper's grandparent. That shell holds the write end of the keeper's
stdin, and the keeper releases the lease on `RELEASE` or at the end of its input. Ending that
shell and everything under it ends the run, and the lease clears. Ending the keeper alone lets
the next acquisition in while the shell is still inside its critical section, and ending the
coprocess shell alone releases nothing. Under bash 3.2 the owner pid is that shell itself.

**Every row that names a remedy or a removal by hand names its check first:**
`ps -ww -p <pid> -o args=`. The keeper's markers arrive as arguments after a long `node -e`
script, so a `ps` without `-ww` cuts them off, and the owner record lives in the
session-writable `.zensu/state`, so its pid and start identity are evidence, not proof. `P1le26`
pins the owner model in `hooks/lib/zensu-tdd-phase.sh` that the shapes and the remedy describe.

**The 30 s green bound is the core's `LOCK_STALE_MS`, handed over as `staleAfterMs`.** The core
has no age rule for an owned artifact. The row renders OK for a live owner whose `created_at` is
at most `staleAfterMs` old, an ordinary critical section, and WARN beyond that; 30 s is three
times the acquisition wait of 200 attempts at 50 ms. A `created_at` in the future is never green
and claims no hold time.

**Resolution failures are findings with plugin-authored causes.** `externalProcessLockBinding`
refuses a symlinked state directory and a resource path that is not a single-link regular file.
`leaseResolveCause` maps those two refusals by substring (`lock directory is unsafe`,
`lock resource is unsafe`; `P1le2` pins both in the core) and never renders the core's message.
A core without the inspector, or a row that throws, is a missing check, not an all-clear:
`stateBlock` wraps `leaseRow`, so one fault costs one row and never the report (`P1le20`,
`P1le23`).

**Coupled sites.** The core: `inspectExternalProcessLock`, `inspectLockArtifact`,
`lockArtifactRefusal`, `artifactStaleness`, `lockOwner`, `externalProcessLockBinding`,
`externalProcessLockPath`, `withRecoverySentinel`, `LOCK_OWNER_MAX_BYTES` and `LOCK_STALE_MS`.
The shell: `_autopilot_locked_run` in `hooks/lib/zensu-autopilot-state.sh`, which names the
resource path (`P1le4` holds the real lease through it), and `_tdd_locked_run` with
`_tdd_core_lock_keeper` in `hooks/lib/zensu-tdd-phase.sh`, whose owner model the keeper shapes
and the hung remedy describe (`P1le26`). The renderer:
`grep -nE '(^|[^A-Za-z_])(LEASE_|lease[A-Z])' hooks/lib/zensu-doctor-report.js`. The names use
`LEASE_` and `lease…` rather than `AUTOPILOT_` and `autopilot…` on purpose:
`.claude/rules/autopilot-run-scope.md` prescribes `grep -nE 'AUTOPILOT_|autopilot[A-Z]|…'` as the
census of run-record hand copies, and this row copies no run record. Operator account: the
`autopilot lease:` bullets and the `Session state` bullet of §"What it checks" in `skills/doctor/SKILL.md`;
`P1le24` holds every row phrase against both.

**Known gaps:**

- The owner record lives in the session-writable `.zensu/state`, so the pid, `created_at` and
  the identity are evidence, not proof. A planted record can make the row say "held by a live
  lock keeper" or "removable".
- `lockOwner` throws on an owner record whose `created_at` cannot be converted, so such a record
  wedges every acquisition instead of reading as owner-less. The row reports it as never
  reclaimed; reading it as owner-less is a change to the lock itself and belongs to the core's
  own review.
- The keeper shapes are prose the user checks by hand; the row does not read another process's
  command line.
- No refusal names this row yet.
- `leaseResolveCause` keys on the core's refusal text rather than an error code.
- Windows is unmeasured. `test-doctor.sh` runs only in the weekly Windows Safety structure
  shard, where no start identity is readable, so `P1le8` skips, and `P1le7` and `P1le10` take
  their start-time arms when `powershell.exe` answers there. The arm that cannot decide is
  pinned by a shim (`P1le10b`), because a live owner older than its record and older than 30 s
  cannot be planted cheaply.

**Version: `patch`.** Walked against `.claude/rules/runtime-lineage.md` entry by entry: no
context-record or workflow-state field, no strict key set, no hook added, removed or renamed, no
matcher change, no hook that can return a `permissionDecision`, no config key, and no
attestation change. The core gains one read-only export, and a core without it yields a
missing-check row, never a wrong verdict.

**Port-relevant.** `inspectExternalProcessLock` is core half; the row, its wording and the
keeper shapes are host half. `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not
included.
