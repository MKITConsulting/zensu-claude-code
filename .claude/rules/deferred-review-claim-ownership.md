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
Covering the locks would put a helper spawn on every hook's hot path. The per-spawn cost on
Windows is unmeasured. A longer-lived owner was rejected as well: it lets a live session hold
a claim past its lease, which changes the handoff contract, and reuse returns once that owner
exits.

**Bound.** On win32, where no identity exists, a Stop that dies between adoption and handoff
can keep its claim from another session for at most the lease. Its own session recovers the
claim on its next Stop, because its workflow state is already seeded. On linux and darwin the
stored identity rejects an impostor at once, but only while both identities can be read:
`deferredOwnerProcessIsAlive` counts a live PID as the owner when the claim stored no identity
or the current read returns null (a `/bin/ps` timeout, an unreadable `/proc/<pid>/stat`). Those
cases fall back to the win32 bound.

**Known gap: lock staleness has the same win32 hole, and it is NOT closed here.**
`artifactIsStale` and `externalArtifactNeedsRecovery` fall back to bare PID liveness when an
owner record carries no `process_start_identity`, which is always the case on win32. A lock
holder killed without releasing, whose PID a long-lived process then reuses, wedges that lock
until the impostor exits: every acquisition times out and fails closed. An age bound on
identity-less artifacts was weighed and not taken. It trades a fail-closed wedge for a
fail-open double holder whenever a legitimate hold outlives the bound.

**Follow-up for that gap.** What closes it is a win32 start identity for lock owners: a
process creation time read through a helper. Measure the per-spawn cost of that helper on a
Windows runner first, then size it with the 19 and 21 identity queries per `Stop` measured
above. The trigger is a Windows failure that reads `timed out acquiring external process lock`
(`acquireExternalProcessLock`) or `timed out acquiring per-session lock` (`withFileLock`)
while the PID in the lock's owner record belongs to an unrelated live process.
`docs/session-control.md` states the gap for operators under "Who holds an adopted review".

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
`deferred-lease-refresh` on `windows-shard-1`. That suite measured 451854 ms for its other four
cases on run 36344267696, whose windows-shard-1 job summed 1344726 ms of its 1800000 ms
envelope; `C7-renew` adds three `Stop` runs, ESTIMATED at about 100 s there. The budget of
`deferred-claim-adoption` and its position on its shard are recorded in
`.claude/rules/windows-budget-best-solution-first.md`.

**Operator-facing accounts.** The "Who holds an adopted review" paragraphs in
`docs/session-control.md` and question three of the `pendingReviewTtlHours` row in
`docs/configuration.md` restate this rule. Change them together with `deferredReviewClaimHeld`.

**Version: `patch`.** No persisted shape changed. The claim still carries `ownerPid` and
`ownerProcessStartIdentity`, no validator gained or lost a key, no hook or matcher changed,
and no attestation field moved.
