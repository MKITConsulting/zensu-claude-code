---
paths:
  - "tests/profiles/windows-ci.v1.json"
  - "tests/structure/windows-ci-contract.test.js"
  - "tests/structure/test-best-solution-first.sh"
---

# Windows Budget for `best-solution-first`

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

The suite cap was raised 300000 -> 600000, matching its siblings, but **the cap is
not the ceiling that binds** and the measurement says which one is. On the last
green run `windows-shard-4` completed in **1591 s** against its `profileTimeoutMs`
of 1800000 — roughly **209 s of headroom for the whole shard**. A suite never
receives its configured `timeoutMs`; it receives the shard's remaining budget, so
raising this number buys nothing while the shard is that close to its own ceiling.

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
`best-solution-first`, `deferred-claim-adoption` and `tdd-state-junction-safety`, near
1024 s. Re-measure both shards on the next green Windows run and replace these
figures; the headroom sentence above still describes the shard as it was.

The suite-level wall clock on Windows is still **unmeasured**; only the shard is.
The note lives here because `tests/run-profile.js`'s `SUITE_KEYS` throws on any key
outside `{id, runner, path, args, timeoutMs}`, so a `note` field in the manifest is
a CI-wide outage rather than documentation.
