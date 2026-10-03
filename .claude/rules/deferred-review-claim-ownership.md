---
paths:
  - "hooks/lib/session-control-core-v1.js"
  - "hooks/lib/zensu-tdd-phase.sh"
  - "hooks/stop-chain-enforcer.sh"
  - "tests/structure/test-deferred-review-claim.sh"
  - "tests/structure/fixtures/deferred-owner-liveness-observer.js"
---

# Deferred-Review Claim Ownership (`deferredReviewClaimHeld`)

A deferred-review claim (`pending-review.json.claim`) is held by its LEASE. The recorded
owner PID is the Stop hook's own bash process (`DEFERRED_OWNER_PID`), which exits as soon as
the hook returns, so the PID carries information only while that hook still runs.

**One predicate decides.** `deferredReviewClaimHeld(claim, claimStale)` in
`hooks/lib/session-control-core-v1.js` answers for `inspectDeferredReviewOwner`, for both
checks in `retireDeferredReviewOwner`, and for the read-only `deferredReviewOwnedByOther`:

- a stale lease never holds;
- a handed-off claim (`handoffEmitted: true`) is held by its fresh lease alone. The handoff
  renews the lease in the same write that records the PID, so a live PID can only disagree
  with the lease after the lease expired, when the recorded process is gone and any live
  answer is a reused PID;
- an unacknowledged claim is held while the lease is fresh AND `deferredOwnerProcessIsAlive`
  says so. That is the in-flight window between adoption and handoff, the only one in which
  the PID means anything.

**An unlinked unacknowledged claim inspects as `unseeded` whatever its PID shows.** The
argument is a LOCK contract, not a liveness check. Assignment and seed run inside one
`_tdd_adopt_pending_review_critical` under the pending-review external lock, and
`tdd_seed_deferred_review` has no other caller. So an inspector holding that lock that sees
an unacknowledged claim no owner state links is looking at an abandoned assignment. Every
production caller of `inspectDeferredReviewOwner` holds that lock (`_tdd_locked_run "$pf"`).
A new caller outside the lock, or a seed in a critical section that does not also assign,
voids the argument, and `L3` then fails; re-derive the argument before changing that check.
`deferredReviewOwnedByOther` runs UNLOCKED and can observe a live assignment mid-section, so
its unlinked branch keeps the PID, bounded by the lease.

**Why not a win32 start identity.** Node exposes no creation time for a foreign PID, so every
query would spawn a helper (PowerShell or CIM; `wmic` is gone from current images). Measured
on darwin with a counting preload: an adopting Stop makes 19 identity queries and a
transferring Stop 21. Only 2 of them concern the claim owner; the rest are lock identities
(`withFileLock` once per Node process, `acquireExternalProcessLock` once per acquisition).
Covering the locks would put a helper spawn on every hook's hot path. Sized with the Windows
cost measured below (124–204 ms warm per call for the cheapest robust helper), a stored win32
identity would add roughly 2.4–4.3 s to every adopting or transferring Stop. A longer-lived
owner was rejected as well: it lets a live session hold a claim past its lease, which changes
the handoff contract, and reuse returns once that owner exits. The locks close their own
hole without a stored identity; see the next sections.

**Bound.** On win32, where no identity exists, a Stop that dies between adoption and handoff
can keep its claim from another session for at most the lease. Its own session recovers the
claim on its next Stop, because its workflow state is already seeded. On linux and darwin the
stored identity rejects an impostor at once, but only while both identities can be read:
`deferredOwnerProcessIsAlive` counts a live PID as the owner when the claim stored no identity
or the current read returns null (a `/bin/ps` timeout, an unreadable `/proc/<pid>/stat`). Those
cases fall back to the win32 bound.

**Lock staleness: a live holder PID that started after its record is a reused PID.** This
closes the win32 hole the locks shared with the claim. `artifactIsStale` (the per-session lock
of `withFileLock` and every recovery sentinel) and `externalArtifactNeedsRecovery` (the
external lease) still decide first by liveness and then by a stored identity wherever both
sides can be read. When no identity decides — none stored, as on every win32 record, or the
current one unreadable — `liveOwnerStartedAfterRecord` reads a LOWER BOUND for the start of
the process that now holds the PID (`processStartLowerBoundMs`: `/proc/<pid>/stat` plus `btime`
on Linux, `ps -o lstart=` on macOS, PowerShell on win32) and calls the record stale when that
bound lies more than `OWNER_START_SKEW_MS` (1 s) after the record's `created_at`. The holder
wrote `created_at` itself, so it existed before that instant; a process that started later
cannot be the holder, which proves the holder gone and its PID reused. On the bash 3.2 external
path the record names the shell's PID and its Node child writes `created_at`, and the shell is
older than its child, so the argument holds there too. The writer records nothing new.

**The helper stays off the hot path, by two gates.** A record younger than the skew is never
probed, and that costs no detection: no process can be proven to start after
`created_at + 1 s` before that instant has passed. Past the skew each Node process probes one
record generation (PID plus token) at most once per `OWNER_START_PROBE_INTERVAL_MS` (2 s) and
caches a "replaced" verdict for good, because a reused PID cannot turn back into the holder. The
external lease keeps its own probe schedule on top (attempts 0, 20, 60 and 140). An
uncontended acquisition, and contention that clears within a second, therefore spawn nothing;
a wedged lock costs one helper call before its recovery.

**Measured win32 helper cost**, on run 36716394774 (`windows-2022` and `windows-2025`, two jobs
each, 4 vCPU, Node 20.20.2), warm p50 per call: `[System.Diagnostics.Process]::GetProcessById`
through `powershell.exe` 124–204 ms (cold 157–335 ms), `Get-CimInstance Win32_Process`
250–466 ms, `pwsh` 179–352 ms, `cscript` with WMI 43–81 ms (one cold call took 13.3 s), `wmic`
48–65 ms on 2022 and absent on 2025, against 40–59 ms for a bare `node -e 0`. Under four CPU
burners the PowerShell read took 0.4–7.3 s, and on one `windows-2022` job no call under load
returned within the probe's 30 s timeout. `Get-Process` in a stripped environment took 11–22 s, so the helper pins the
environment `skills/session-trail/scripts/trail.mjs` measured for its own `powershell.exe`
probe (`LOCALAPPDATA` kept, `PSModulePath` pinned) and passes its program through
`-EncodedCommand`. It tries .NET first and falls back to CIM inside the same process, so
Constrained Language Mode or a refused `OpenProcess` costs the fallback rather than the
answer. Runners are administrators in Full Language mode, so the fallback is unmeasured. The
timeout is 5 s.

**Two more measurements from that run decide the design.** PID reuse came at least 1.1 s after
an exit for sequential spawns (median 4.3–8.6 s) and at least 0.4 s for parallel ones (median
2.7–4.9 s). Under Git Bash `process.ppid` names a wrapper that exits with each Node child (the
parent read `ESRCH` afterwards), which is why `_tdd_locked_run` holds the external lease with
the coproc keeper (`ownerPid: process.pid`) on bash 4 and later, and every Windows bash is
later. So on win32 both lock kinds are held by the Node process that acquired them. A process
can bound its own start without a helper (the OS creation time preceded
`performance.timeOrigin` by 4–33 ms in 48 of 48 samples), but `created_at` already is such a
bound, so the writer stores nothing extra.

**Bounds.**

- A reused PID whose new process started within the skew of `created_at` is not proven
  replaced and keeps the old wedge until it exits. The reuse gaps above make that window
  narrow, since the holder's death itself follows `created_at`.
- A start that cannot be read — the helper times out, both PowerShell paths are refused, `ps`
  times out — counts as "not replaced", so the live PID keeps the lock as before.
- Clocks: `created_at` is wall time. Windows and macOS keep a process start as wall time taken
  at creation, so a later clock step moves neither side. Linux derives it from boot-relative
  ticks plus the current `btime`, so a forward step of more than the skew between the write
  and the check could make a live holder without an identity look replaced. Linux writers
  always store an identity, so that needs a record written without one. Linux also assumes a
  `USER_HZ` of 100, which every architecture Node supports uses.
- The claim is unchanged: it stays lease-first, as described above.

**Diagnostics.** `observed_stop` in `tests/structure/test-deferred-review-claim.sh` preloads
`tests/structure/fixtures/deferred-owner-liveness-observer.js` into the Stop hook's Node
children. The observer records the claim's owner PID, its liveness and its image name at the
moment the core decides. C2f, C7 and C8 run their deciding Stops under it and append
`[decision-time owner PID alive: …]` to a PASS label when they saw a live owner; on Windows
that line is a direct observation of PID reuse. A liveness sample taken after the case's last
Stop cannot refute reuse, because a short-lived impostor has exited by then.

**Pins.** Unit: the reused-PID tests in `tests/session-control/session-control-core-v1.test.js`
(handed-off lease, unlinked claim, in-flight lease bound, identity impostor, unreadable current
identity, read-only probe), plus a dead owner of an unlinked claim, which pins that the probe's
unlinked branch still asks the PID. End to end: `C2f-reuse` and `C7-reuse` require the observer to have seen the planted
PID alive at decision time, and `C7-identity` covers the identity arm. `L3` walks the call
graph of `hooks/**/*.sh`: every call of `inspectDeferredReviewOwner(` or
`assignDeferredReviewClaim(`, whatever its receiver, and every seeding `tdd_begin_session`
call (a non-empty fifth argument, or a forwarded `$@`, `$*`, `${@…}` or `${name[@]}`) must be
reached only through `_tdd_locked_run "$pf"`, and a critical section that seeds must also
assign. It also fails with `uncalled:<name>` for a function on that path that no scanned line
calls, with `js-caller:<file>` for any other `hooks/**/*.js` file that calls either core entry
point, and with `seed-bypass@<where>` for a reference to `_tdd_begin_session_critical` outside
`tdd_begin_session`, because a caller the walk cannot see is a caller it cannot prove locked.
It runs the same analyzer against a violating fixture tree, whose seeds and assignment sit one
call below their critical sections as in production, and requires every detector to fire there
while a section that both seeds and assigns stays clean. The fixture exercises each
alternative of the forwarded-seed pattern once (`"${@:1}"`, `"$@"`, `"${args[@]}"`) and runs
one inspection under `_tdd_locked_run "$state_file"`, which must count as unlocked. An empty tree
must report `vacuous:0/0/0/0`, a tree without an inspection `vacuous:0/1/1/1` and a tree
without a seed `vacuous:1/1/0/1`, so each missing entry point trips the guard on its own.
`C7-renew` pins that a blocking review Stop of the owning session renews the lease. `C2c`,
`C2d`, `C4t` and `C4s-transfer` model their crashed adopter with the never-allocated PID
2147483647, not with the exited fixture shell, whose PID Windows may reuse. Every case is
registered in `tests/structure/deferred-review-claim-cases.test.js`. `C2f-reuse`, `C7-reuse`,
`C7-identity` and `L3` run in `deferred-claim-adoption` on `windows-shard-4`, `C4t` and
`C4s-transfer` in `deferred-transfer-reset` on `windows-shard-6`, and `C7-renew` in
`deferred-lease-refresh` on `windows-shard-1`, where it measured about 96 s on run 36625440255.
Two suites moved off that shard to pay for it. Those measurements, the budget of
`deferred-claim-adoption` and its position on its shard are recorded in
`.claude/rules/windows-budget-best-solution-first.md`.

**Lock pins.** Unit cases in `tests/session-control/session-control-core-v1.test.js`: the real
start reader on the running host, per-session lock recovery for an absent and for a mismatched
identity, external-lease recovery, a control that keeps a holder older than its record, and a
faked-win32 case that pins the PowerShell invocation, the age gate and the per-generation cache
on every host. The unit file runs as `session-control-core` on `windows-shard-2`, which is
where the real PowerShell path executes. The verdict reaches `/zensu:doctor` through
`inspectExternalProcessLock`, whose `startedAfterRecord` field names this cause: the inspection
case table `external process lock inspection calls an artifact stale exactly when acquisition
reclaims it` holds it against a real acquisition, and `P1le7`, `P1le10` and `P1le10b` in
`tests/structure/test-doctor.sh` hold the `autopilot lease:` row
(`.claude/rules/autopilot-lease-row.md`). Older fixtures that planted a live PID under a
`created_at` older than that process, which is the reused-PID shape itself, now plant
`created_at` at write time.

**Operator-facing accounts.** The "Who holds an adopted review" paragraphs in
`docs/session-control.md` and question three of the `pendingReviewTtlHours` row in
`docs/configuration.md` restate this rule. Change them together with `deferredReviewClaimHeld`,
and the lock paragraph there together with `liveOwnerStartedAfterRecord`.

**Version: `patch`.** No persisted shape changed in either change. The claim still carries
`ownerPid` and `ownerProcessStartIdentity`; lock records gain no field and
`process_start_identity` keeps its values, win32 writers still storing `null`; no validator
gained or lost a key, no hook or matcher changed, and no attestation field moved.
`processStartLowerBoundForPid` is a new export for the unit layer.
