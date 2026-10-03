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

**The cache is the only thing most reads consult.** `--refresh` reuses a proof younger than 24
hours and otherwise asks GitHub again. Every `gh` failure is transient: it keeps a cached proof
for up to 7 days and names the failure. A refresh that DISPROVES the pipeline removes the
cached proof. Without that removal, the `--tdd-begin` snapshot, which reads the cache only,
honoured a proof the Phase 0 refresh had just rejected. An edit to the workflow file voids the
proof through its blob hash.

**A chain keeps the runner it began with.** The `--tdd-begin` success arm writes a snapshot from
the cache, without network. The terminus, the `--scope full` refusal and the post-review
directive all resolve with `requireSnapshot`, so a switch to CI in the middle of a chain never
relaxes its terminus, while a switch to local applies at once. When a chain that chose CI closes
locally, the verdict prints `FULL SUITE — local runner | <reason> | decided by: <rank>`, because
a bare `missing` would not tell the user why the choice did not hold.

**Stores.** `$CLAUDE_PLUGIN_DATA/ci-contract/v1/` holds the cache, `clones/` and `snapshots/`,
and sits in both protected-root lists of `hooks/lib/reviewer-capability-v1.js`. The session
marker `.zensu/state/full-suite-<session key>.json` goes through `zensu_write_session_marker`,
like the delivery-route marker. A Bash redirect from the main thread can still forge any of
them, the documented residual of every plugin store.

**Tests.** `CI=true` resolves `local`, so `test-full-suite-ci.sh` unsets the CI variables and
the unit file passes a clean environment. `gh` is a PATH shim that answers canned JSON. The
suite drives real chains to `deferred-ci`, through a mid-chain switch in both directions, and
through the helper's repo and session verbs.

**Coupled sites that move together:** `skills/tdd/SKILL.md` Phase 0 step 2 and its section
"Full Suite in CI (mode-gated deltas)" (the file is capped at 433 lines); the CI fix-round
paragraph and the legend in `skills/self-review/SKILL.md`; `CLOSE_PASS_SUITE_CI`,
`AFFECTED_SUITE_STEP`, `CLOSE_SUITE_STEP`, `FULL_SUITE_ROUND_NOTE` and the `deferred-ci` legend
entry in `hooks/post-review-tdd-delegate.sh`, where `test-post-review-tdd-scope.sh` counts
`--evidence-run --scope full --if-stale` exactly once, in `FULL_SUITE_STEP`, and
`test-full-suite-ci.sh` C10, C22 and C23 refuse it in a CI chain's directives, so the CI variant
must not add one; `docs/configuration.md` §"Full Suite in CI" and
its three keys; `docs/gates.md` CI mode; discipline patch 12 in
`docs/tdd-manager-workflow.md`; `config.example.json`; the README skills table and count; the
skills list in `.claude-plugin/plugin.json`.

**Version: `patch`.** No hook added, removed or renamed, no matcher change, no
`permissionDecision`, `RECORD_KEYS` unchanged, verdict states never persisted, and the config
keys read permissively. The marker is the same class as the delivery-route marker.

**Known gaps, accepted and named:** a full-suite command the model runs by hand is not blocked;
the chain never waits for CI, so a branch may close `deferred-ci` and never reach a pull
request; this repository's CI skips the seven Promptfoo local-only suites; Autopilot gates
still run their own test gate locally; conditions are not evaluated per chain; there is no
`/zensu:doctor` row, `--status` is the visibility surface.

**Port-relevant.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were NOT included.
