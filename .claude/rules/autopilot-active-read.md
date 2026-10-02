---
paths:
  - "hooks/lib/zensu-autopilot-state.sh"
  - "hooks/plan-approved-delegate.sh"
  - "hooks/stop-chain-enforcer.sh"
  - "hooks/post-review-tdd-delegate.sh"
  - "hooks/session-start-autopilot-resume.sh"
  - "hooks/lib/zensu-log.sh"
  - "hooks/lib/session-reanchor-v1.js"
  - "tests/structure/lib-autopilot-lease.sh"
  - "tests/structure/test-autopilot-*.sh"
  - "tests/structure/test-post-review-outer-ownership-root.sh"
  - "tests/structure/test-deferred-review-fallback.sh"
---

# Owner-Scoped Active-Run Read (`autopilot_read_active_strict` and its callers)

`autopilot_read_active` answers whether THIS session owns an active durable run, and it ends in
`_autopilot_locked_run`. `_tdd_locked_run` returns 1 for a storage-safety failure, a failed
acquisition and a failed release, so the verb's exit 1 also means "could not look". This file
records how the strict form keeps the two apart and which caller uses which verb. The scope of
the question itself, owner-scoped versus workspace, is `.claude/rules/autopilot-run-scope.md`.

**`autopilot_read_active_strict` keeps the lease apart from the verdict.** It runs the worker
through `_autopilot_active_probe`, which always returns 0 and carries the worker's status in
`_ZENSU_AP_ACTIVE_WORKER_RC` beside the record in `_ZENSU_AP_ACTIVE_RECORD`, the same intra-file
channel shape as `_autopilot_hold_probe`. It answers 0 with the run printed, 1 when this session
provably owns no active run, 2 for an orphaned, hidden or inconsistent run, 3 for a refused call
and 5 for a lease, storage or path fault it could not resolve. Its first caller was
`hooks/lib/session-reanchor-v1.js`, which names it across the file boundary.

**A failed acquisition gets one read-only look before it answers 5.** When the probe never ran,
`_autopilot_active_read_without_lease` checks storage with `_autopilot_storage_safe`, runs the
same worker without the lease and checks storage again. It gives the locked read's answer in two
cases only: 1 when the worker answered 1, and 0 with the record when the worker printed an own
run whose stage is `DONE` or `CANCELLED`. An own nonterminal run, `BLOCKED` included, an
orphaned, hidden or inconsistent state and a worker fault all stay 5. This is the read-only proof
`_autopilot_deferred_contention_result` already takes for a saturated lease. The 1 is sound
because the worker answers 1 only when this owner has neither an active pointer nor a nonterminal
run, and every intermediate state of a begin, an adoption or a release keeps one of the two, so a
torn publication reads as 2 and stays 5. The terminal 0 is sound because a terminal run never
becomes nonterminal again, and a new run begun behind a terminal pointer is a hidden nonterminal
run until its own pointer lands, which also reads as 2. The terminal case is needed because
`_autopilot_apply_critical` and `_autopilot_release_critical` replace only the run record: a run
that reaches `DONE` or `CANCELLED` keeps its owner pointer, and every switched caller reads that
record as no active run. A held lease says nothing about THIS session, so without the look every
Stop, plan approval and post-review routing of a session that owns no active run would fail
closed for as long as any other process held the lease. A probe that ran and then failed its
release still answers 5. Storage and path faults never reach the look: they answer 5 before the
lock is tried, or one of the look's own storage checks refuses.

**Every caller of the owner-scoped read was judged by ONE test: does a lease, storage or path
fault read as exit 1 relax a guard?** Where it does, the caller uses the strict verb and fails
closed on 5. Where it does not, it keeps `autopilot_read_active`, and the reason stands here so
the lenient verb is never mistaken for an oversight. The verdicts:

- **`session-reanchor-v1.js` — strict.** A 5 refuses as `autopilot-state-unverifiable`. Under a
  held lease a session whose look proves no run, or finds only a `DONE` or `CANCELLED` one, is
  answered `none` and may re-anchor; one whose look finds a nonterminal run still refuses.
- **`plan-approved-delegate.sh` — strict.** Exit 1 selects the standalone plan policy, so a
  lease fault handed a plan owned by a `PLANNING` or `AWAIT_TDD` run to the route question, or
  with `autoTdd` off to silence, and never recorded `PLAN_APPROVED`. 5 emits
  `PLAN_GATE_BLOCKED code=ACTIVE_STATE_UNREADABLE`, whose cause says the answer is unknown
  rather than corrupt; 2 and 3 keep `CORRUPT_ACTIVE_STATE`, while storage and path faults,
  which answered 2 before, now carry the new code. In
  `tests/structure/test-autopilot-plan-delegate.sh`: `P7e` holds the lease over an own
  `PLANNING` run (the unchanged hook emitted nothing), `P7f` holds it for a session without a
  run and `P7h` for one whose own run is `CANCELLED`, and both require the standalone policy's
  question, `P7i` holds it over an own run whose pointer was removed and requires
  `ACTIVE_STATE_UNREADABLE`, and `P7g` plants unsafe storage.
- **`stop-chain-enforcer.sh`, the initial outer read — strict.** Exit 1 sets
  `OUTER_PRESENT=false`, and a session whose standalone chain is still implementing then
  reaches `outer_finish`, where `autopilot_reconcile_stop_active` reads the same fault as 1
  and releases. A lease that stayed unavailable therefore let the Stop through for a session
  that owns an active run: `S16a` measured no decision at all from the unchanged hook, and a
  block naming the run once the lease was free. 5 blocks with its own reason AHEAD of the
  "corrupt or unsafe" arm, because that arm prescribes repair or cancellation, the wrong
  remedy for a transient lock and a destructive one for a healthy run. Storage and path
  faults, which answered 2 and took that arm before, now take this one (`S16d`); both still
  block, and this reason names `/zensu:doctor` for a fault that keeps recurring. `S16c` holds
  the lease for a session without a run and `S16e` for one whose own run is `CANCELLED`, and
  both require that this arm does not fire.
- **`stop-chain-enforcer.sh`, the stale-generation re-read in `outer_finish` — strict.** It
  runs after `autopilot_increment_stop_budget_capped` answered 4, and its 1 returns without a
  decision, releasing the Stop of a run the reconcile had just proven active. 5 falls into the
  existing `-ne 1` block. `S16b` takes the lease between the budget CAS and the re-read
  through a stubbed budget verb; the unchanged hook released that Stop.
- **`stop-chain-enforcer.sh`, `outer_reload` — lenient, deliberately.** None of its three call
  sites releases on 1. The two budget-claim failure arms discard the status and block
  unconditionally, and the terminal-release race falls through to the bound-inner budget
  claim, which blocks because the failed read leaves `OUTER_JSON` empty and the exact
  `TDD_RUNNING` match then fails. The strict verb would change which block text a lease fault
  produces there, never whether the Stop blocks.
- **`post-review-tdd-delegate.sh`, the standalone preflight — strict.** Its 1 permits the
  unbound ticket claim, and the owner-independent `autopilot_read_workspace` preflight after
  it read the same fault as "free", so a standalone review claim went through while this
  session owned a nonterminal run. 5 falls into the existing `*) exit 0` arm before the claim
  and the ticket stays unconsumed. In `tests/structure/test-post-review-outer-ownership-root.sh`:
  `O2d` holds the lease over an own run (the unchanged hook claimed the ticket and routed the
  review) and requires the lease helper's own exit 0, `O2e` holds it for a session without a
  run and `O2g` for one whose own run is `CANCELLED`, and both require the claim and the
  routing, and `O2f` plants unsafe storage.
- **`post-review-tdd-delegate.sh`, the bound preflight — lenient, deliberately.** Its
  `|| exit 0` ends the hook before the claim on every non-zero status, so 1 and 5 already
  share one closed consequence.
- **`zensu-log.sh --autopilot-status` — strict.** Exit 1 is the documented "no active durable
  run": `/zensu:reset-review-limit` routes its standalone branch on it, `/zensu:self-review`
  reads it as "no owned `TDD_RUNNING` status", and the rc-1 disclosure asserts that this
  session owns no durable Autopilot run. A fault the look cannot resolve now exits 5 with its
  own stderr line and no hold report. Storage and path faults move from 2 to 5 as well; no
  skill that runs the verb branches on 2, and the one that branches on 1 sends every other
  non-zero exit to its fail-closed stop. In `tests/structure/test-autopilot-state-machine.sh`:
  `W33` holds the lease over an own run (the unchanged verb exited 1), `W34` holds it for a
  session without a run and requires exit 1 with the rc-1 disclosure, `W36` holds it over a
  `CANCELLED` own run and requires exit 0 with that record, and `W35` plants unsafe storage.
- **`session-start-autopilot-resume.sh` — lenient, deliberately.** It is advisory SessionStart
  context and guards nothing: its silence cannot release a Stop, arm a chain or approve a
  plan, each of those guards re-reads under its own lease, and the next Stop that reads the
  run re-issues its stage directive through `outer_finish`. A lease fault there costs the
  resume line, never a gate, and the model cannot tell that silence from "no run", which is
  the residual.

**Each switched caller is pinned by a check that holds the REAL project lease**, through
`tests/structure/lib-autopilot-lease.sh`: `with_autopilot_lease` runs one command inside
`core.acquireExternalProcessLock` with `lockDirectory` `<root>/.zensu/state` and
`resourcePath` `<root>/.zensu/state/autopilot`, and `autopilot_lease_hold_start` /
`autopilot_lease_hold_stop` hold it from a background process for `S16b`, which must be
contended mid-hook. A held-lease read waits out the core's bounded acquisition, 200 attempts
at 50 ms, before it answers or looks, so every such check costs at least ten seconds; about
twelve per read was measured on a loaded macOS host. The checks whose outcome a lease-free run
would share (`P7f`, `P7h`, `S16c`, `S16e`, `O2d`, `O2e`, `O2g`, `W34`, `W36`) also require an
elapsed time of at least eight seconds, so a helper that silently took no lease cannot pass them;
`P7i` needs no such bound, because a lease-free run of it answers `CORRUPT_ACTIVE_STATE`, which
the check refuses. The unsafe-storage checks
plant a directory at `<root>/.zensu/state/autopilot`, which `_autopilot_storage_safe` requires
to be a regular file or absent, and need no wait. Every fixture plugin in the Stop suite that
redefines the initial read, today the one shared by `S8g`, `S8h` and `S8j` plus those of `S8k`
and `S8i`, and the race wrappers of `S9f`, `S9g` and `S9i` name `autopilot_read_active_strict`,
because the hook no longer calls the lenient verb there; a fixture that stubs
`autopilot_read_active` now reaches only `outer_reload`. `D8` in
`tests/structure/test-deferred-review-fallback.sh` requires that its Stop is not the
unreadable-state block, so the seed-write failure it names stays the path it measures.

**Known gaps, accepted and named:**

- `autopilot_reconcile_stop_active` and `autopilot_read_workspace` also end in
  `_autopilot_locked_run`, so each still reads a lease fault as 1: `outer_finish` and the
  escape branch release on the reconcile's 1, and the post-review workspace preflight reads
  its 1 as "free". The strict initial read closes the case in which the lease is unavailable
  when the Stop begins; a lease that becomes unavailable after that read and before the
  reconcile still releases the Stop. A strict form of each verb is the fix and is NOT in this
  change.
- A lease fault that does not clear blocks every Stop and every plan approval, and fails every
  `--autopilot-status` read, of a session that OWNS a nonterminal run in that project root,
  `BLOCKED` included, or whose own state is orphaned or inconsistent, because the look answers 5
  for each of them. That is the fail-closed trade for an owned run.
  Such a fault is a live but hung holder, a lock keeper that cannot run, or a lock artifact
  that is never reclaimed: `artifactIsStale` reclaims a lock whose owner is dead, and one whose
  pid was reused only when the artifact recorded a process start identity. `processStartIdentity`
  answers null off linux and darwin, and on darwin when `/bin/ps` fails, so an artifact without
  one is never reclaimed while any process holds its pid, and it lives in `.zensu/state`, which
  the session can write. Storage and path faults still block every session in the project, as
  their 2 did before.
- `/zensu:doctor`, the remedy every refusal names, shows the run records but not the lease or
  its holder, so a lease that never clears is visible there only as runs that look healthy. A
  read-only lease row naming the artifact, its owner pid, whether that pid is alive and whether
  a start identity was recorded is the missing diagnostic and is not in this change.
- The post-review standalone preflight refuses without a word. A session whose look found its
  run, or whose storage is unsafe, keeps its ticket and gets no directive, and the next Stop's
  resume directive orders the review again. The refusal is the point for an owned run; the
  silence is the residual.
- On Windows a held-lease check costs about 35 s, not ten (run 37060398940). `W33` to `W36`
  pushed `test-autopilot-state-machine.sh` past its 900000 ms cap on `windows-shard-1`, and
  `P7e` to `P7i` raised `test-autopilot-plan-delegate.sh` on `windows-shard-5` from at most 402 s
  to as much as 549 s, so both caps rose and `deferred-lease-refresh` moved to `windows-shard-9`.
  `.claude/rules/windows-budget-best-solution-first.md` records the figures measured on run
  37064216294.

**Version: `patch`.** Walked against `.claude/rules/runtime-lineage.md` entry by entry: no
context-record or workflow-state field, no strict key set, no hook added, removed or renamed,
no matcher changed, no hook that can newly return a `permissionDecision`, no attestation
change. The new Stop block reason, the new plan-gate code and exit 5 of `--autopilot-status`
are outputs every existing consumer already treats as fail-closed, and the look answers only
what the locked read gives for the same state. The release that ships it still takes
the strictest class of every commit since the previous tag, including the re-anchor work this
change stacks on.
