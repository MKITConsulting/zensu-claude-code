---
paths:
  - "tests/profiles/windows-ci.v1.json"
  - "tests/structure/windows-ci-contract.test.js"
  - "tests/structure/test-best-solution-first.sh"
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
envelope, and the suite runs third with about 80 s of suites behind it. Re-measure on the
next green Windows run.

The suite-level wall clock on Windows is still **unmeasured**; only the shard is.
The note lives here because `tests/run-profile.js`'s `SUITE_KEYS` throws on any key
outside `{id, runner, path, args, timeoutMs}`, so a `note` field in the manifest is
a CI-wide outage rather than documentation.
