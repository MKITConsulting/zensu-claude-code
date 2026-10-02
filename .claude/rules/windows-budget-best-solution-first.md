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
`expectedShardHomes` pins both homes. Runs 37056715866 (main) and 37059949647 then measured that
layout's shard 1 at 1563 and 1307 s, before the held-lease change below moved
`deferred-lease-refresh` off it.

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
every check before it passing. Its cap is now 1280000 ms. Its neighbour `deferred-lease-refresh`
moved to `windows-shard-9` and runs first there; `stop-enforcer-reviewer-denial-note` stays last
because its 1200000 ms cap is the larger one, and `expectedShardHomes` and `expectedShardTails` pin
both. `autopilot-plan-delegate` on `windows-shard-5` measured 336373 and 402285 ms without `P7e` to
`P7i` (main's run 37056715866 and run 37059949647) and 511828 ms with them on run 37060398940, so
its cap rose from 600000 to 720000 ms. Run 37064216294 measured this layout twice: attempt 1's
shard 9 failed `C7`, the Stop-deadline release that #358 keeps out of the suite, and attempt 2 was
green on all three shards.

- `windows-shard-1`: `autopilot-state-machine` took 969005 and 878950 ms, so its cap is 32% over
  the larger; the shard summed 1030 and 936 s.
- `windows-shard-9`: `deferred-lease-refresh` took 746268 and 720558 ms, and
  `stop-enforcer-reviewer-denial-note` 651087 and 594556 ms; the shard summed 1397 and 1315 s.
  `deferred-lease-refresh`'s cap rose from 900000 to 970000 ms, 30% over the larger figure like its
  siblings: 900000 was 21% over it. A run to the new cap still leaves
  `stop-enforcer-reviewer-denial-note` about 830 s against 669455 ms, its slowest run. Run
  37059949647, which carries #358's worker flag in `stop()`, measured `deferred-lease-refresh` at
  596107 ms on `windows-shard-1`, 17% under main's 718779 ms while that job ran the unchanged
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

`windows-shard-9` is now the tightest of the three. The slowest runs of its two suites sum to
1416 s, so a runner 20% slower leaves about 100 s of its envelope, and further growth there has to
move a suite off the shard rather than raise a cap. Re-measure on the next green Windows run and
replace these figures.
