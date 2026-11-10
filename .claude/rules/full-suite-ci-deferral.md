---
paths:
  - "hooks/lib/ci-contract-v1.js"
  - "hooks/lib/full-suite-policy-v1.js"
  - "hooks/lib/zensu-full-suite.sh"
  - "hooks/lib/zensu-full-suite-transport.sh"
  - "skills/full-suite/SKILL.md"
  - "tests/structure/full-suite-ci-v1.test.js"
  - "tests/structure/test-full-suite-ci.sh"
---

# Full Suite in CI (`ci-contract-v1.js` + `full-suite-policy-v1.js` + `/zensu:full-suite`)

A chain can leave its full suite to the repository's CI pull-request pipeline, so parallel
sessions stop saturating the machine with local full runs. The tests affected by the change
still run locally through `--scope scoped`, and the terminus closes as `deferred-ci`. A red
pull-request pipeline is possible, and the user accepted that trade explicitly.

**Three owners, one transport.** `ci-contract-v1.js` owns the CI facts: the workflow scan, the
remote proof through `gh api`, and the verification cache. `full-suite-policy-v1.js` owns the
ladder, the clone and snapshot stores, the CLI modes and every policy line.
`evidence-run-v1.js` owns `decideCi`, `ciVerdict` and the `deferred-ci` state. The shell only
transports, through `zensu-full-suite-transport.sh`. It resolves the lib DIRECTORY with
`zensu-host-path.sh` and appends the module name, because that helper accepts only
directories: a file path makes every call fail with "the full-suite policy module cannot be
resolved", and every consumer then silently stays local.

**The ladder is asymmetric.** `local` in any rank wins at once: the session marker, then the
record for this clone, then `evidence.fullSuiteRunner`. `ci` needs a `ci` choice in some rank,
no `local` anywhere, and a verified pipeline. Nothing recorded plus a verified candidate is
`ask`, which only an interactive standalone chain may put to the user. A "repository" answer is
written per clone into the plugin data directory, keyed by the git common directory, so every
worktree sees it and no feature PR carries config noise. The question never writes the
committed config. No `ZENSU_*=off` stem was added: the choice is a mode, not a gate escape, so
`ESCAPE_STEMS` and the bypass-ledger roster stay unchanged.

**Verified means the job ran, not that it passed.** A workflow under `.github/workflows/`
triggers on `pull_request`, the repository is not a fork, and a job matching the bound pattern
concluded `success` or `failure` in a completed pull-request run of the last 30 days.
`pull_request_target` never counts, because it runs the base branch's workflow. Merge-blocking
is read and shown, never required. Path filters, branch filters and the `if:` conditions of the
jobs that form the bound pattern are shown, never evaluated; when no job in the file matches the
pattern, every job's condition is shown rather than none. A process inside CI resolves `local`,
so the pipeline never defers to itself. Only GitHub.com is supported.

**The cache keeps one proof per workflow version and job.** A proof is
`cache/<key>.<blob>.<job>.json`: `<key>` is the first 40 hex digits of the sha256 of the
repository and the workflow path, `<blob>` the sha256 of the workflow file's bytes in the working
tree, `<job>` the first 16 hex digits of the sha256 of the job pattern the proof verified, and the
entry shape and `CACHE_KEYS` are unchanged. The job is part of the name because a proof counts only
for the job it verified, so two worktrees that bind different jobs to one workflow version would
otherwise overwrite each other's proof. A read takes the newest matching proof by `verifiedAt`. One slot per repository and workflow let worktrees whose workflow files differ void
each other: in a consuming repository one worktree's refresh overwrote the slot eleven minutes
before another worktree's `--tdd-begin`, which froze that chain `local`, and its terminus reads
the same cache. One file per version rather than one list per workflow, because each writer then
replaces only its own file atomically, and two refreshes cannot drop each other's proof in a
read-modify-write. `--refresh` reuses the current version's proof while it is younger than 24
hours and otherwise asks GitHub again. Every `gh` failure is transient: it keeps that proof for
up to 7 days and names the failure. A successful refresh prunes the workflow's other proofs older
than `cacheGraceMs` and keeps at most `LIMITS.maxProofsPerWorkflow` (16, a judgement) by
`verifiedAt`, never the one it wrote; an entry it cannot read is neither counted nor removed. A
refresh that DISPROVES the pipeline removes every proof of that repository and workflow, whatever
its version or job, and the legacy slot, because the disproof is a fact about the workflow on
GitHub, not about one version. The two disproofs that concern the requested job alone, that it did
not run in the recent pull-request runs or that its newest run is older than 30 days, carry
`disproves: 'job'` and remove only that job's proofs, and the legacy slot only when it holds that
job, because a worktree whose config names a job that has not run yet would otherwise void every
other worktree's proof for another job; with no job requested a read accepts any job, so such a
disproof still removes everything. Without that removal, the `--tdd-begin` snapshot honoured a proof
the Phase 0 refresh had just rejected. A version no proof covers, an edited workflow file
included, is unverified, and its reason says that the tree differs from every verified version.

**The legacy slot.** An older installation of the same lineage still reads and writes
`cache/<key>.json`, and after an update sessions of both installations run side by side on one
machine. A read falls back to that slot when it holds the current version; a write never touches
it, so an older session sees only its own installation's writes, exactly as before. A proof a read
SERVES from the slot is copied unchanged, `verifiedAt` included, to its own per-version file
(`keepProof`), in the cache read, in the refresh shortcut and in the transient-failure fallback:
otherwise a newer chain that began `ci` on the slot depended on it to its terminus, and an older
session's refresh in another worktree rewrote it and voided that chain, the very case-1 voiding
this change removes.

**A chain keeps the runner it began with, and says which.** The `--tdd-begin` success arm writes a
snapshot. It reads the cache first, and when a recorded CI choice resolves unverified there, it
resolves once more in refresh mode, with the Phase 0 semantics, before it records the runner. The
network is allowed there once because the snapshot is what the terminus honours: in a consuming
repository a session switched to a branch whose workflow file no proof covered thirteen seconds
after its Phase 0 refresh, and the cache-only snapshot froze the chain `local` although Phase 0 had
printed `ci`. The refresh costs nothing when the cache holds the version, the normal case right
after Phase 0, and a chain without a CI choice never asks. `--tdd-begin` prints the snapshot's line
after `mode:` whenever a CI choice is recorded, `full suite: ci | this chain began with the CI
runner: …` or `full suite: local | <reason> | decided by: <rank> | this chain began with the local
runner, …`, because a chain whose choice did not hold ran every phase in CI mode, as Phase 0 told
it, and then met a terminus that demanded a local full suite. ## Full Suite in CI in
`skills/build/references/modes.md` names that line as the one that activates the CI deltas. The
snapshot mode removes the session's previous snapshot before it resolves, so an interrupted
`--tdd-begin`, or one whose snapshot write fails, leaves no runner in force and the chain closes
local through the "recorded no full-suite snapshot" arm, which is what the stderr notice says; the
file is one per session key, so the previous chain's `ci` would otherwise stand for the new one.
The snapshot call runs after the three local resets of the success arm, so a network wait there
never leaves the previous generation's review-gate, workflow-wait or background-wait state behind.
`zensu-log.sh --full-suite-policy --chain` (the policy module's `chain` mode) answers the same
question the terminus asks, with `requireSnapshot`, and `/zensu:self-review` decides its CI mode
from it rather than from the plain `--full-suite-policy`, which reads the cache alone. The
terminus, the `--scope full` refusal and the post-review directive all resolve with
`requireSnapshot` and read the cache alone, so a switch to CI in the middle of a chain never
relaxes its terminus, while a switch to local applies at once. When a chain that chose CI closes
locally, the verdict prints `FULL SUITE — local runner | <reason> | decided by: <rank>`, because a
bare `missing` would not tell the user why the choice did not hold.

**Stores.** `$CLAUDE_PLUGIN_DATA/ci-contract/v1/` holds the cache, `clones/` and `snapshots/`,
and sits in both protected-root lists of `hooks/lib/reviewer-capability-v1.js`. The session
marker `.zensu/state/full-suite-<session key>.json` goes through `zensu_write_session_marker`,
like the delivery-route marker, and `SESSION_MARKERS` in `hooks/lib/session-reanchor-v1.js` moves
it to the new root on `/zensu:adopt-session --reanchor`. Renaming its path template therefore moves
that list as well, which the marker case in `tests/structure/session-reanchor-v1.test.js` enforces
by deriving the kinds from the templates, and the path `docs/configuration.md` §"Full Suite in CI"
names, plus the literals in `test-full-suite-ci.sh` and the two re-anchor suites. The chain snapshot
does not move: the re-anchor refuses while a chain holds open work, and the next `--tdd-begin`
writes a new one. A Bash redirect from the main thread can still
forge any of them, the documented residual of every plugin store.

**Tests.** `CI=true` resolves `local`, so `test-full-suite-ci.sh` unsets the CI variables and
the unit file passes a clean environment. `gh` is a PATH shim that answers canned JSON. The
suite drives real chains to `deferred-ci`, through a mid-chain switch in both directions, and
through the helper's repo and session verbs. C24 to C26 add a second worktree whose workflow file
differs and a branch switch between the refresh and `--tdd-begin`, the last two with a failing
and a healthy shim; C25 swaps the fixture file and restores it. C28 pins the order of the
`--tdd-begin` success arm, the snapshot call after the three local resets, and a mutant that moves
the call above them must fail it. C27 and C27b drive
`--full-suite-policy --chain` in a chain that began local after a mid-chain switch to CI and in
one that began `ci`. The unit file spells the proof and legacy file names a second time (`keyOf`,
`jobKeyOf`, `proofFile`, `legacyFile`), so a rename of either fails there, and its CLI cases put
the shim first on `PATH`. The stub's optional `__probe` fixture key records at every `gh` call
whether a named file exists, which is how the unit file shows the previous snapshot gone during
the begin refresh.

**Coupled sites that move together:** `skills/build/SKILL.md` Phase 0 step 2 and the section
"Full Suite in CI (mode-gated deltas)" in `skills/build/references/modes.md`; the CI fix-round
paragraph and the legend in `skills/self-review/SKILL.md`; `CLOSE_PASS_SUITE_CI`,
`AFFECTED_SUITE_STEP`, `CLOSE_SUITE_STEP`, `FULL_SUITE_ROUND_NOTE`, the CI arm of
`MAX_CLOSE_RUN` (the bound max-rounds closing run, `M6e` in
`test-autopilot-post-review-max-rounds.sh` and `C23b` in `test-full-suite-ci.sh`, which compares
its command with the rendered `AFFECTED_SUITE_STEP`) and the `deferred-ci` legend
entry in `hooks/post-review-tdd-delegate.sh`, where `test-post-review-tdd-scope.sh` counts
`--evidence-run --scope full --if-stale` exactly once, in `FULL_SUITE_STEP`, and
`test-full-suite-ci.sh` C10, C22 and C23 refuse it in a CI chain's directives, so the CI variant
must not add one; `docs/configuration.md` §"Full Suite in CI" and
its three keys; `docs/gates.md` CI mode; discipline patch 12 in
`docs/build-workflow.md`; `config.example.json`; the README skills table and count; the
skills list in `.claude-plugin/plugin.json`; `LIMITS.maxProofsPerWorkflow`, `PROOF_NAME_RE`,
`cacheName`, `jobKey` and `proofName` in `hooks/lib/ci-contract-v1.js`, whose names the unit file
spells again, and `disproves` of `jobUnverified`, which `verify` reads to remove one job's proofs; the two lines of `snapshotLines`, which the unit file and C24 to C26 match exactly, the
`--tdd-begin` print in `hooks/lib/zensu-log.sh`, and the activation sentence of ## Full Suite in
CI in `skills/build/references/modes.md`, which names them; the router cell and Phase 0 step 2 of
`skills/build/SKILL.md`, which open that section on a `full suite: ci` line from step 2 or step 3;
the `--chain` flag of `--full-suite-policy` in `zensu-log.sh`, the module's `chain` mode and the
CI-mode sentence of `skills/self-review/SKILL.md` Phase 4 that names it, whose body size the
`self-review` entry of `tests/structure/test-skill-text-budget.sh` holds; and the `__probe` key of
`tests/structure/fixtures/gh-api-stub.js`.

**R8k reads these modules too.** R8k in `tests/structure/test-delivery-route.sh` fails any file
under `hooks/` other than `zensu-config.sh` that spells a marker stem, `full-suite` included,
followed by `-` and then a character that is not a letter or digit, or by the end of the line,
because that is how a marker leaf is spelled outside the shared writer. A name in these modules
that is not the session marker keeps a letter after that dash, as `full-suite-clone-v1` and
`full-suite-snapshot-v1` do.

**Version: `patch`.** No hook added, removed or renamed, no matcher change, no
`permissionDecision`, `RECORD_KEYS` unchanged, verdict states never persisted, and the config
keys read permissively. The marker is the same class as the delivery-route marker. The
per-version proofs and the snapshot refresh are `patch` on the same walk: `CACHE_KEYS`,
`CLONE_KEYS` and `SNAPSHOT_KEYS` are unchanged and only a file name in a private store moved;
`LIMITS` gained a bound no reader validates; no hook, matcher, record field or config key moved;
and `--tdd-begin` prints one more stdout line, only when a CI choice is recorded. The job digest
in the proof name and the `disproves` field move nothing a released reader reads: the name is a
private store detail an older installation never lists, and an unverified result is never cached.
`--chain` is an additive flag of a read-only verb whose one caller ships in the same installation. An older
installation of the lineage never lists the cache directory, so it neither reads nor removes the
new files, and the newer one still reads the slot the older one writes.

**Known gaps, accepted and named:** a full-suite command the model runs by hand is not blocked;
the chain never waits for CI, so a branch may close `deferred-ci` and never reach a pull
request; this repository's CI skips the seven Promptfoo local-only suites; Autopilot gates
still run their own test gate locally; conditions are not evaluated per chain; there is no
`/zensu:doctor` row, `--status` is the visibility surface.

**Known gaps of the per-version cache and the snapshot refresh:**

- A disproof by an older installation removes only the legacy slot, so a newer session keeps its
  own version's proof, up to 24 hours in a refresh and 7 days in a cache read, until the sessions
  of the older installation end.
- The terminus reads the cache alone. A chain whose own workflow file changes in the middle of the
  chain, a merge of `main` included, closes local unless another worktree verified that version;
  the verdict names the reason.
- The proof binds the workflow file in the working tree, while a `pull_request` run takes the
  workflow from the pull request's merge commit, so a branch behind `main` is judged by a version
  CI no longer runs.
- `--tdd-begin` may ask GitHub: at most nine `gh api` calls, each bounded by `LIMITS.ghTimeoutMs`
  (20 s), and three times as many when no workflow is configured and discovery tries three
  candidates. A host without network records `local` there and prints why.
- Proofs of a workflow that no session refreshes again are never pruned; each is about 600 bytes.
- A chain bound to an Autopilot run whose worktree lies below the anchor is judged by the anchor's
  workflow file: the policy reads the session's recorded project root, never the chain's work tree,
  so the per-version binding and the begin refresh judge a file the chain's branch may not carry,
  and a branch switch in the anchor checkout in the middle of such a chain changes the version every
  cache read of the chain uses. This predates the per-version cache; the fix passes the work tree
  through the policy transport, the runner's `ciPolicyFor` and the post-review `effective` read.
- A refresh never reads the jobs of the workflow version it certifies. It certifies the version in
  the tree from the newest pull-request run in which the bound job ran, so a branch whose workflow
  drops the bound job or filters it out is certified too, at Phase 0 and at the begin refresh alike,
  and the begin line names neither the skipped newer runs nor the conditions the Phase 0 line shows.
  Answering unverified when no job of the scanned file matches the pattern would fail closed for job
  names built with `${{ }}` and for reusable-workflow jobs, so it needs its own measurement.
- `gh api` runs without `--hostname` and with the caller's environment, so `GH_HOST`, or a gh login
  only to another host, could answer the verification from another host, while `repoIdentity`
  accepts only github.com. This predates the per-version cache, and the begin refresh reaches it
  too; pinning the host means `--hostname github.com` in `ghApi` and a stub that reads the endpoint
  past a trailing flag on Windows.
- Windows is unmeasured: the new cases ran on macOS only, and no blocking Windows profile names
  `test-full-suite-ci.sh`.

**Port-relevant.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were NOT included.
