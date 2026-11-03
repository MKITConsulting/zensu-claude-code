---
paths:
  - "tests/profiles/windows-ci.v1.json"
  - "tests/structure/windows-ci-contract.test.js"
  - "tests/structure/test-best-solution-first.sh"
  - ".github/workflows/ci.yml"
  - "tests/run-profile.js"
---

# Windows Budget for `best-solution-first`

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

The suite cap was raised 300000 -> 600000, matching its siblings, but **the cap is
not the ceiling that binds** and the measurement says which one is. When that cap was
raised, `windows-shard-4` completed in **1591 s** against its `profileTimeoutMs` of
1800000 — roughly **209 s of headroom for the whole shard**. A suite never receives
its configured `timeoutMs`; it receives the shard's remaining budget, so raising a cap
buys nothing while the shard is that close to its own ceiling.

The suite is spawn-dominated — nearly every check spawns a `bash` plus a `node`,
it builds five fixture plugin trees, and it now also drives
`tests/structure/rule-block-v1.test.js` as its B0 driver. Growth here therefore has
to be paid for by moving a suite OFF that shard, not by raising a number. If the
shard starts reporting an abort, the tail of whichever suite ran last went
unverified regardless of how many checks passed before it.

**`plan-payload-path-transport` is NO LONGER a neighbour, and the prediction above
came true before it moved.** This paragraph used to name it as the second big suite
on `windows-shard-4` at a measured 714 s. On run 33968034396 it measured **874281 ms**
— a 22% swing over that figure — and the shard's first three suites summed to
1718167 ms of the 1800000 ms envelope, so `tdd-state-junction-safety` received LESS than the
remaining 81833 ms against its own 180000 ms cap and reported `TIMED_OUT`. **State that
figure as an upper bound, never as the grant.** An earlier revision wrote 81927, which is
larger than 1800000 − 1718167 and puts the shard 94 ms over its own envelope — impossible under
`tests/run-profile.js`, which starts the profile clock before the first suite while each
suite's reported `durationMs` is measured inside `executeSuite` and therefore excludes the
inter-suite overhead the profile clock keeps counting. So the grant is strictly BELOW the
subtraction, and rounding across three suites accounts for about 1.5 ms, not for 94. The
conclusion is unchanged at either value — the suite times out against its 180000 ms cap — but a
note whose purpose is to keep the sizing lesson re-derivable must not hand the next reader a
base that does not add up. The suite
was not slow; it was not paid for. `plan-payload-path-transport` moved to
`windows-shard-8`, which the contract test's own note measures at roughly 292 s of
work; moving the 180000 ms suite instead would have left this shard at 1718167 ms,
which is a budget set AT the measurement. Shard 4 now holds
`best-solution-first`, `tdd-state-junction-safety` and `deferred-claim-adoption`, in that
order. Run 36344267696 (its windows-shard-4 job was green at d0bdb9e2) measured them at
49843, 116868 and 701522 ms, 868233 ms of suite time. `deferred-claim-adoption` has since
gained the reused-PID cases and `L3`, an ESTIMATED 150 s more, and its cap rose to 1200000 ms.
It runs LAST because its cap is the largest: the three caps sum to 1980000 ms against the
1800000 ms envelope, so a slow run of it must surface as its own `TIMED_OUT` instead of
starving the suite behind it. `expectedShardTails` in `tests/structure/windows-ci-contract.test.js`
pins that position. Re-measure on the next green Windows run and replace these figures.

**The prompt-ledger change grew this suite by nine hook drives, UNMEASURED on Windows.** Its
full block moved to `SessionStart`, so `B3d` drives that leg for all five sources, `B3b` drives it
once more for the framing prefix, `B7h` drives the reminder refusal on both legs and `B9b` drives the
opt-out on it. At the roughly 1.2 s per drive the 49843 ms figure above implies for its ~42 drives,
that is about 11 s,
well inside the shard's slack; no cap moved and no suite moved. Replace the estimate with the
next green Windows run's figure.

**`windows-shard-1` paid for `C7-renew` the same way.** Run 36625440255 exhausted that shard's
envelope at 1800264 ms: `tdd-no-flock-external-lease` was granted 9579 ms and overran it, and
three suites behind it never ran. `C7-renew` itself took about 96 s of `deferred-lease-refresh`'s
739185 ms. The rest was a slow runner: the suite's other four cases took about 40% longer, and
`autopilot-state-machine` 28% longer (791429 ms), than on main's run 36622193312 (616598 ms),
whose shard 1 summed 1357 s. So the shard was already close to its envelope on a slow runner.
`autopilot-bound-payload-windows` (116728 and 128775 ms on those two runs) moved to
`windows-shard-6`, which measured 1027 and 695 s, and `deferred-review-fallback` (116501 and
99509 ms) moved to `windows-shard-8`, which measured 882 and 1083 s, ahead of its pinned tail.
`expectedShardHomes` pins both homes. Re-measure shard 1 on the next green Windows run.

**`windows-shard-1` ran out of room again, so `deferred-lease-refresh` moved off it.** On runs
36724193854, 36730717361 and 36735221114 (attempt 2) the shard's suites summed to 1630, 1621 and
1739 s of the 1800000 ms envelope. `autopilot-state-machine` measured 812203 and 830672 ms on the
first two and reported `TIMED_OUT` at its 900000 ms cap (900216 ms) on the third, with
`deferred-lease-refresh` taking 735535-780910 ms behind it. That third run had at most about 61 s
of the envelope left, so raising the cap in place would only have moved the timeout onto the suites
behind it. `deferred-lease-refresh` therefore moved, with its command and its 900000 ms cap
unchanged, to the FRONT of `windows-shard-9`. That shard's only suite,
`stop-enforcer-reviewer-denial-note`, measured 626985-713658 ms on the same runs. The cap of
`autopilot-state-machine` rose to 1280000 ms, about 42% over the figure at which it timed out. It
runs first on shard 1, so that cap now binds before the envelope: a full run to it still leaves
about 520 s for the five small suites behind it, which took 55-58 s on those runs. On the same runs
shard 1 would have measured about 867-958 s, the last a lower bound because that suite was cut off,
and shard 9 about 1363-1495 s. `stop-enforcer-reviewer-denial-note` stays LAST on shard 9 because
its 1200000 ms cap is the larger one, so an overrun of either suite surfaces as that suite's own
`TIMED_OUT` instead of starving the other. `expectedShardHomes` and `expectedShardTails` pin both
positions. Re-measure both shards on the next green Windows run.

**`post-review-self-review-handoff` on `windows-shard-5` outgrew its 720000 ms cap**, which
dates from #182 while the suite kept gaining checks. Six green runs measured it at 591568,
636796, 636930, 663856, 686575 and 695461 ms (82–97% of the cap). Run 36730717361 then
reported `TIMED_OUT` after P15, with every check before it passing, on a runner about 20%
slower than the fastest of those runs. The cap is now 900000 ms, and the SHARD pays for it:
shard 5's seven suites summed to at most 1183 s on those runs against its 1800000 ms
envelope, and the suite runs third with about 80 s of suites behind it. Its own run 37059949647
then measured the suite at 698828 ms and shard 5 at 1175 s; with `P7e` to `P7i`, run 37064216294
summed shard 5 to 1316 and 1297 s, which the held-lease paragraph below carries.

Every suite figure here is the `durationMs` that `tests/run-profile.js` reports for that suite,
which excludes the inter-suite overhead the profile clock keeps counting. The note lives here
because `tests/run-profile.js`'s `SUITE_KEYS` throws on any key outside
`{id, runner, path, args, timeoutMs}`, so a `note` field in the manifest is a CI-wide outage
rather than documentation.

**`windows-shard-1` and `windows-shard-5` paid for the held-lease Autopilot checks.** A check
that holds the real project lease waits out the core's bounded acquisition, and on Windows one
such check measured about 35 s. Run 37060398940 put three of them into `autopilot-state-machine`
(`W33`, `W34` and `W36`; `W35` between them plants unsafe storage and takes no lease): the four
checks took 110.4 s from `W32d` to `W36`, and the suite reported `TIMED_OUT` at 900328 ms with
every check before it passing. The move of `deferred-lease-refresh` to `windows-shard-9` and the
1280000 ms cap of `autopilot-state-machine`, both described above, pay for them on shard 1.
`autopilot-plan-delegate` on `windows-shard-5` measured 336373 and 402285 ms without `P7e` to
`P7i` (main's run 37056715866 and run 37059949647) and 511828 ms with them on run 37060398940, so
its cap rose from 600000 to 720000 ms. Run 37064216294 measured the moved layout with all of these
checks twice: attempt 1's shard 9 failed `C7`, the Stop-deadline release that #358 keeps out of
the suite, and attempt 2 was green on all three shards.

- `windows-shard-1`: `autopilot-state-machine` took 969005 and 878950 ms, so its cap is 32% over
  the larger; the shard summed 1030 and 936 s.
- `windows-shard-9`: `deferred-lease-refresh` took 746268 and 720558 ms, and
  `stop-enforcer-reviewer-denial-note` 651087 and 594556 ms; the shard summed 1397 and 1315 s.
  Run 37059949647, which carries #358's worker flag in `stop()`, measured `deferred-lease-refresh`
  at 596107 ms on `windows-shard-1`, 17% under main's 718779 ms while that job ran the unchanged
  shard-1 suites 16 to 27% faster: one pair, with no slowdown visible. The suite has not yet run
  with the flag on `windows-shard-9`.
- `windows-shard-5`: `autopilot-plan-delegate` took 549481 and 532611 ms, so its cap is 31% over
  the larger, and `post-review-self-review-handoff` 704709 and 687026 ms; the shard summed 1316
  and 1297 s.

The two raised shard-5 caps hold together. When `autopilot-plan-delegate` and
`post-review-self-review-handoff` both run to their caps of 720000 and 900000 ms, the four suites
behind them are left about 179 s: 180000 ms less `coverage-report-windows-paths` (at most 862 ms
measured), the inter-suite overhead and the cleanup after each timeout. Those four took at most
86624 ms across runs 37059949647, 37060398940 and 37064216294.

`windows-shard-9` is the tightest of the three. The slowest figures of its two suites, 780910 and
713658 ms on run 36735221114 (attempt 2), sum to 1495 s, so a runner 20% slower than that one
would leave at most about 7 s of the envelope. `deferred-lease-refresh`'s 900000 ms cap is 15%
over that 780910 ms. Further growth on shard 9 has to move a suite off it rather than raise a cap.
Re-measure on the next green Windows run and replace these figures.

**`windows-profile-lifecycle-contract` on `windows-shard-3` dropped from a 420000 to a 100000 ms
cap.** The suite drives `tests/structure/profile-runner.test.js`, where each nested `runProfile`
started a Windows PowerShell job helper that scanned every module on `PSModulePath`. #377 removed
that scan and lowered the test's Windows profile deadline from 60 s to 10 s. The suite measured
244395 and 229606 ms before #377 (runs 37151198067 and 37150000165) and 23621, 24220 and 25265 ms
after it (runs 37156373713, 37158951388 and 37159426509). 100000 ms is 3.96x the slowest of those
three. It also stays below what a returning scan would cost: about eight helper starts at no less
than 11.5 s each (run 37155469145) push the suite past 110 s, so that regression surfaces as this
suite's own `TIMED_OUT`. The suite still runs last on shard 3, so its timeout cannot starve a neighbour.
Re-measure on the next green Windows run and replace these figures.

**`windows-shard-2` ran out of room, so `versioned-plugin-upgrade` moved to the FRONT of
`windows-shard-7`.** On the 29 all-green runs from 38309344682 to 38432294025 (2026-10-12 and
2026-10-13), shard 2's eight suites took 928-1601 s of the 1800000 ms envelope; the slowest,
run 38419619148, left 198.6 s of it. Its two large suites took 391-703 s (`installed-wrapper`) and
247-480 s (`versioned-plugin-upgrade`). On PR #383's run 37666241244 the shard did not finish at
all (see the next paragraph). Shard 7's only suite, `stop-enforcer-self-review-routing`, took
383-630 s on the same runs, the least of any shard; the other seven shards peaked at 934-1554 s.
`versioned-plugin-upgrade` moved with its command and its 900000 ms cap unchanged. On the same
runs, shard 2 without it would have taken 682-1167 s and shard 7 with it 751-1084 s; the slowest
figures of its two suites, 479625 and 630417 ms, sum to 1110 s. `installed-wrapper` stayed on
shard 2: beside the routing suite, two 1200000 ms caps would leave either suite only 600 s after
the other ran to its cap, less than either suite's slowest figure, 703 and 630 s.
`versioned-plugin-upgrade` runs FIRST on shard 7 because the routing suite's cap is the larger
one. A run of it to its 900000 ms cap, plus the up to 45 s that ending it takes, still leaves the
routing suite about 855-900 s for its 630 s. Both suites read an exported `ZENSU_CONFIG` and keep
their state in their own temporary directories, so sharing shard 7's sandbox changes neither.
`expectedShardHomes` in `tests/structure/windows-ci-contract.test.js` pins the moved suite's home,
and `expectedShardTails` pins the routing suite as the tail of shard 7. Shard 5 is the next to
watch: run 38412632511 measured it at 1554 s, with `autopilot-plan-delegate` at 670 s of its
720000 ms cap and `post-review-self-review-handoff` at 834 s of its 900000 ms cap. Re-measure
shards 2, 5 and 7 on the next green Windows run and replace these figures.

**The job limit stayed at 35 minutes, because no workflow limit would have saved that run's
report.** On run 37666241244 the `windows-shard-2` job reached its 35-minute limit 2030 s into
the profile step, which had started after 70 s of setup. Its job record still lists the profile
step as `in_progress` with no end time, and "Record shard outcome", "Upload Windows profile
timing report" and both post steps as `pending`; the job closed five minutes after the limit,
and its log returns HTTP 404. GitHub's workflow-cancellation reference says what a working runner
does instead: it sends Ctrl-C to the cancelled step, Ctrl-Break after 7500 ms, and kills the
process tree after another 2500 ms, and the expressions reference says steps with `if: always()`
still run when a job is cancelled. The server forcibly ends whatever is still running after a
five-minute cancellation timeout, and the job closed at exactly that point, so the runner never
ended the step at all. A step-level `timeout-minutes` is enforced by that same runner, so it
would not have saved the report either, and none was added. A runner that stalled explains every
observation at once (the overrun, the step that never ended and the missing log), but nothing
proves it.

`tests/run-profile.js` itself ends a timed-out suite within about 45 s: up to two `taskkill`
attempts of at most 10 s each, a 5 s wait for the supervisor to close, a third `taskkill` of at
most 10 s with another 5 s wait, and a 5 s wait for the output streams. It writes the final
report right after that. Those bounds are event-loop timers, and they hold only while the runner
drains the step output: Node writes `process.stdout` to a Windows pipe synchronously, so a
reader that stops blocks the event loop at the next heartbeat or output line, before either
report write. With the output drained, only two things after the deadline have no time bound:
removing the profile sandbox, which on win32 makes up to 20 attempts and must also delete the
temporary tree of a suite killed before its `EXIT` trap ran, and the process exit. The job's
five-minute reserve over the envelope, which `windows-ci-contract.test.js` pins, covers the
measured rest. Across 346 green Windows shard jobs on 39 runs from 37635298476 to 38455928917,
setup took 53-161 s, the profile clock started 0-2 s after its step, and everything after the
step took 3-45 s; with the 45 s teardown that is at most 253 s of the 300 s. A working runner
that reaches the job limit anyway still ends the step and runs the `always()` steps, so the
report is uploaded either way. The defence that does not depend on the runner is headroom: a
shard that ends well inside its envelope never reaches either limit.

**`reviewer-capability-gate` on `windows-shard-2`: cap 300000 -> 480000.** Nine green pull-request
runs of 2026-10-21 and 2026-10-22 (39680170551, 39680666951, 39683120873, 39689929252, 39762775968,
39772728566, 39791463657, 39841992586, 39842477715) measured it at 152380 to 276879 ms, up to 92%
of the old cap. Run 39663189139, whose branch added three cases to the suite, was killed at
300149 ms after 403 of its 419 checks had passed and none had failed. The shard pays for the new
cap: the slowest of those nine runs, 39683120873, summed its seven suites to 1219185 ms of the
1800000 ms envelope, 275125 ms of it this suite, so a run that uses the whole new cap stays below
1424060 ms. Re-measure on the next green Windows run and replace these figures.
