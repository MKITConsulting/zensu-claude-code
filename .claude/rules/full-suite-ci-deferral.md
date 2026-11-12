---
paths:
  - "hooks/lib/ci-contract-v1.js"
  - "hooks/lib/full-suite-policy-v1.js"
  - "hooks/lib/zensu-full-suite.sh"
  - "hooks/lib/zensu-full-suite-transport.sh"
  - "hooks/lib/zensu-log.sh"
  - "hooks/lib/evidence-run-v1.js"
  - "hooks/post-review-tdd-delegate.sh"
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
is read and shown, never required. Path filters are evaluated only for a project root below the
repository top (§"A chain is judged by its own work tree"); otherwise they, the branch filters and
the `if:` conditions of the jobs that form the bound pattern are shown, never evaluated; when no
job in the file matches the pattern, every job's condition is shown rather than none. A process inside CI resolves `local`,
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
snapshot file is one per session key, so the previous chain's `ci` would otherwise stand for the
new one. The success arm therefore retires it before anything else of the full-suite step runs,
through `zensu_full_suite_snapshot_retire`, the policy module's `retire` mode, which needs no
temporary directory and no work-tree lookup. A snapshot call that then fails anywhere, in the
transport (no temporary directory, a `work-tree-fault` file that cannot be written) or in the
module, leaves no runner in force, and the chain closes local through the "recorded no full-suite
snapshot" arm, which is what the `FULL SUITE SNAPSHOT UNAVAILABLE` notice says; the snapshot mode
still removes the file before it resolves, so an interrupted module run leaves none either. Only a
retirement that cannot run keeps the previous snapshot, and it prints
`FULL SUITE SNAPSHOT RETIREMENT UNRESOLVED`. Retirement and snapshot call run after the three local
resets of the success arm, so a network wait there never leaves the previous generation's
review-gate, workflow-wait or background-wait state behind.
`zensu-log.sh --full-suite-policy --chain` (the policy module's `chain` mode) answers the same
question the terminus asks, with `requireSnapshot`, and `/zensu:self-review` decides its CI mode
from it rather than from the plain `--full-suite-policy`, which reads the cache alone. The
terminus, the `--scope full` refusal and the post-review directive all resolve with
`requireSnapshot` and read the cache alone, so a switch to CI in the middle of a chain never
relaxes its terminus, while a switch to local applies at once. When a chain that chose CI closes
locally, the verdict prints `FULL SUITE — local runner | <reason> | decided by: <rank>`, because a
bare `missing` would not tell the user why the choice did not hold.

**A chain is judged by its own work tree.** `verify` and `discover` read the workflow files and the
remote at the git top level of the `workTree` they are given, and of the project root without one
(`workflowTree`). That is the tree `zensu-log.sh --chain-work-tree` prints: the worktree of the
Autopilot run an open chain is bound to, and otherwise the repository top of the project root,
where GitHub reads `.github/workflows/`, so a session recorded in a subdirectory finds its
workflow too. Git's answer decides: a root git reports outside every work tree keeps itself, and
any other git failure, a `safe.directory` refusal for example, answers unverified with git's
message (`git could not place the project root in a work tree: …`, or `the chain's work tree` for
the bound tree) instead of judging the project root as if it were the top. Reading the session's
recorded project root instead judged a bound chain whose worktree lies below the anchor by a file
its branch may not carry, at the per-version binding, at the begin refresh and at every cache read,
and a branch switch in the anchor checkout in the middle of such a chain changed the version all of
them read. The remote follows the same tree, because the chain's own branch decides its upstream.

**A session below the repository top also needs path filters that let its pull requests run the
suite** (`pathFilterRefusal`). A pull request of such a session changes only files under its
prefix, so a `pull_request` path filter can keep the suite from ever running for it, while a
verified run of the job proves only that some pull request ran it. `verify` therefore answers
unverified, naming the prefix, for a trigger written in flow form, a `paths` or `paths-ignore` list
that is empty or holds `maxListValues` entries (the scan may have cut it), a `paths-ignore` list
with a negated pattern or a pattern that can match under the prefix, and a `paths` list with no
pattern that covers the whole prefix or with a negated pattern that can match under it. The
evaluator expands no glob, so it decides only what a pattern's text decides: a pattern can match
under the prefix when its literal head and `<prefix>/` are one a prefix of the other. The head is
the text before the first character of `PATTERN_SYNTAX_RE`, one character shorter when that
character is a `?`, because a `?` makes the character before it optional. `!` is one of those
characters, so a negated `paths-ignore` pattern has an empty head and can always match, while a
negated `paths` pattern is judged by the text after its `!`. A pattern covers the prefix only as
`**`, `**/*`, or a literal directory ending in `/` that contains the prefix, followed by `**` or
`**/*`. A session at the repository top skips the check.

`zensu_full_suite_policy_node` takes the bound work tree and a lookup fault as its fourth and fifth
arguments, resolves the tree with `cd … && pwd -P`, renders it through `zensu-host-path.sh`, where
a tree it cannot render becomes the fault `its path cannot be handed to node`, hands it on as
`ZENSU_FSP_WORK_TREE`, and writes the fault into the transport file `work-tree-fault`, the name
`readWorkTreeFault` of `evidence-run-v1.js` reads, so `inputsFromTransport` reads both transports
alike. `zensu-log.sh` resolves both in process for `--full-suite-policy` and for the `--tdd-begin`
snapshot through `_zensu_full_suite_work_tree`, which asks `_zensu_bound_work_tree`, the lookup
behind `--chain-work-tree`, and applies the two refusals `--chain-work-tree --project-dir` adds to
that lookup: a project directory the lookup could not derive, and a work tree or project directory
whose path holds a double quote, a dollar sign, a backtick or a backslash, are lookup faults too,
so the in-process reads and the post-review hook judge every chain alike. The post-review hook
asks `zensu-log.sh --chain-work-tree --project-dir --session` once, for an Autopilot-bound chain
only, right before its `effective` read, so a standalone review completion spawns nothing more,
and the bound max-rounds arm takes that answer as its closing-run directory instead of asking
again; a lookup that fails becomes the fault `zensu-log.sh --chain-work-tree --project-dir could
not resolve the work tree of this Autopilot-bound chain`. The runner's `ciPolicyFor` passes the
`ZENSU_EVR_WORK_TREE` and the `work-tree-fault` its own transport already carries. A lookup fault
never falls back to the anchor: `chainContract` answers unverified with `the chain's work tree
could not be resolved: <cause>`, which a recorded CI choice turns into `local`, the fail-closed
direction, and the policy line prints the cause as a segment of its own,
`… could not be resolved | work tree: <cause> | decided by: …`, under its own display bound, so a
long cause never pushes the rank out of the line. The clone record keeps keying on the git common
directory of the project
root, which every worktree of the clone shares, and the snapshot keeps its `projectRoot` check, so
no store and no key set moved. A delegated chain's Phase 0 refresh runs before `--tdd-begin` binds
it, so it judges the anchor's top level; the begin snapshot then judges the worktree and refreshes
once when no proof covers its version, and its begin line is the one that decides. The
`/zensu:full-suite` helper passes no work tree: it records a clone or session choice, and a bound
chain never asks it, so its `--status` line judges the project root's top level.

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
one that began `ci`. C29 to C30d drive Autopilot-bound chains in worktrees nested below the anchor
through `bound_begin` and `bound_review`, which C23b shares: C29 to C29d a worktree whose workflow
does not trigger on pull requests while the anchor's is verified (the begin line, `--chain`, the
post-review directive and `--evidence-run --scope full` all read `local`), C30 to C30d a worktree
whose workflow version differs, which the begin refresh verifies with its own proof, and a branch
switch in the anchor checkout to a workflow without a pull-request trigger after the begin, which
leaves `--chain`, the directive and the runner refusal `ci`. Each of the eight fails when the path
it drives reads the project root instead: C29b to C29d run over a `ci` snapshot written in place of
the begin's local one (`seed_ci_snapshot`), so none of them leans on the begin snapshot to read
`local`. C31 to C33 drive the faults. C31 writes a `ci` snapshot, moves the worktree away and puts
the `mktemp` stub of `lib-work-tree-fault-stub.sh` on `PATH`, so the begin's snapshot call fails
in the transport, and requires `--chain` to read the "recorded no full-suite snapshot" arm, which a
begin that leaves the retirement to the snapshot mode fails. C32 to C32c move the worktree away at
the begin, at `--chain` and at the post-review read and require `local` with the lookup fault
named, the last two over a `ci` snapshot. C33 counts the `node` processes the post-review hook's
lookup starts through a counting `node` shim and holds them at the measured ceiling. C34 and C35
drive the two refusals `_zensu_full_suite_work_tree` adds to the lookup, through `plain_begin`, a
bound begin without a completion: C34 a worktree whose path holds a dollar sign, C35 a session
bound in an untracked subdirectory that the worktree's branch lacks. Both require the begin line
and `--chain` to read `local` with the lookup fault named, and both fail when the function hands
the lookup's tree on unscreened. The unit cases
beside them pin `workTree` in `verify` and `discover`, the remote of the worktree's branch, a
project root below the repository top and its path filters, a git refusal named as such, the
policy, the snapshot CLI, the `retire` mode and the runner over the same layouts, and the lookup
fault with its own segment. The unit file spells the proof and legacy file names a second time
(`keyOf`, `jobKeyOf`, `proofFile`, `legacyFile`), so a rename of either fails there, and its CLI
cases put
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
`self-review` entry of `tests/structure/test-skill-text-budget.sh` holds; the `__probe` key of
`tests/structure/fixtures/gh-api-stub.js`; and the chain's work tree: `workflowTree` and the
`workTree` option of `verify` and `discover`, `chainContract` and the `workTree` name of
`inputsFromTransport`, the two trailing arguments of `zensu_full_suite_policy_node` and their
`ZENSU_FSP_WORK_TREE` exclusion, `_zensu_full_suite_work_tree` and its two callers in
`zensu-log.sh`, whose path screen spells the one `--chain-work-tree` applies a second time and
which C34 and C35 drive, the
bound-only `--chain-work-tree --project-dir --session` read before `effective` in
`hooks/post-review-tdd-delegate.sh` and the `MAX_CLOSE_DIR` that reuses it, the
`ZENSU_EVR_WORK_TREE` name in `ciPolicyFor`, and the transport file name `work-tree-fault`, which
`readWorkTreeFault` owns for both transports; `reasonText`, whose `| work tree: ` segment the unit
file and C32 to C32b match; `pathFilterRefusal`, `patternReaches`, `patternCovers` and
`PATTERN_SYNTAX_RE` beside the scanner's `filters` and `flowTrigger`, whose refusal sentences the
unit file matches; and the begin's retirement: the module's `retire` mode,
`zensu_full_suite_snapshot_retire` in the transport and its call in the `--tdd-begin` success arm,
ahead of the work-tree lookup and the snapshot call, which C31 drives.

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
new files, and the newer one still reads the slot the older one writes. Judging a chain by its own
work tree is `patch` on the same walk: `CACHE_KEYS`, `CLONE_KEYS` and `SNAPSHOT_KEYS` are unchanged
and the snapshot still records the project root; `work-tree-fault` and `ZENSU_FSP_WORK_TREE` live
for one call; no hook, matcher, record field or config key moved; and the two trailing transport
arguments are optional, so a caller that passes none reads the project root's top level. A session
whose begin and terminus ran on two installations of the lineage gets at most the stricter answer:
the terminus honours CI only when the snapshot says the chain began with it. The begin's
retirement, the path filters, the named git refusal and the work-tree segment are `patch` on the
same walk: `retire` is a new mode of the module's CLI whose one caller, the `--tdd-begin` success
arm, ships in the same installation; the path-filter check runs before the cache is read, refuses
only in the fail-closed direction, writes no proof and removes none, because it returns before any
`gh` call; and the segment changes a line only the unit file and the suite parse. No key set,
record field, hook, matcher or config key moved.

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
- The post-review read of an Autopilot-bound chain starts one `zensu-log.sh --chain-work-tree
  --project-dir` process, with its own bind and workflow-document read, on every review completion
  of such a chain, the background claim's included. It started 18 `node` processes, ten of them
  project-root verifications; since the lookup subshell memoizes the root
  (`.claude/rules/stop-latency.md`) it starts 10, measured on macOS bash 3.2.57 and Linux bash
  5.2.15, and C33 holds that ceiling. It runs before the claim's last deadline check, so on a
  slow host a background claim that it delays past its deadline defers to the next Stop or prompt
  with record and note kept, rather than being cut off after the ticket CAS; the cost is a later
  claim, never a lost one.
- `evidence.ci.workflow`, `evidence.ci.job`, `evidence.fullSuiteRunner` and
  `evidence.fullSuiteCommand` still come from the anchor checkout's `.zensu/config.json`, because
  the transport reads the config against the session's project root. A branch that edits them is
  judged by the anchor's values until the anchor checkout carries the edit.
- The path-filter check reads a pattern's text and never the tree: a `paths` list that covers the
  prefix only through a wildcard segment, such as `services/*/**` for `services/b`, reads as not
  covering it, and so does a list the scan cut at `maxListValues`, so such a session stays local
  although its pull requests would run the suite.
- A retirement that cannot run, because `node` or the plugin data directory is unavailable, keeps
  the previous chain's snapshot in force; `FULL SUITE SNAPSHOT RETIREMENT UNRESOLVED` says so, and
  a snapshot call that succeeds afterwards replaces the file, while one that fails as well leaves
  the previous chain's runner standing for this chain.
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
