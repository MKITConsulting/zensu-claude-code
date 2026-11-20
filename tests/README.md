# tests/ — zensu plugin test suites

Two flavors:

- **Deterministic** — execute hooks/libs with crafted input and assert real state
  (exit code, emitted JSON, FSM/state files, evidence records). No API, fast, the
  primary "proof" that a hook does what it claims.
- **Live LLM** — drive real `claude --print` against the locally-loaded plugin and
  match the response with tolerant regex. Costs API credits; opt-in.

## Master runner

```bash
bash tests/run-all.sh              # deterministic only (no API)
bash tests/run-all.sh --ci         # deterministic non-Promptfoo CI contract
bash tests/run-all.sh --self-check # deterministic + live-suite skeletons (no API)
bash tests/run-all.sh --live       # deterministic + live claude --print suites (API)
```

Exit 0 iff every selected suite passes. A timestamped report lands in `tests/results/`.

## Windows contract profiles

The versioned manifest at `tests/profiles/windows-ci.v1.json` divides the
Windows-specific deterministic contracts into nine bounded profiles. Membership
is balanced by measured runtime rather than by theme, so a profile name says
which shard a suite runs in and nothing about what it covers:

```bash
node tests/run-profile.js --validate
node tests/run-profile.js windows-shard-1
node tests/run-profile.js windows-shard-2
node tests/run-profile.js windows-shard-3
node tests/run-profile.js windows-shard-4
node tests/run-profile.js windows-shard-5
node tests/run-profile.js windows-shard-6
node tests/run-profile.js windows-shard-7
node tests/run-profile.js windows-shard-8
node tests/run-profile.js windows-shard-9
```

Moving a suite between profiles is a rebalancing decision, not a semantic one.
Coverage does not depend on getting it right: the runner requires the manifest
and the audited command catalog to be a bijection, so a suite assigned to no
profile fails validation rather than silently running nowhere.

The runner validates the complete manifest and its audited command catalog
before starting any child process, binds every suite to its validated content
digest, streams suite output, and enforces both per-suite and 30-minute
per-profile deadlines. Every suite runs below a supervisor that remains alive
until the complete process tree has been terminated, including after a normal
suite exit. Child processes receive a disposable home/temp tree and a strict
operational environment allowlist; credentials, auth homes, interpreter preload
variables, and live/API modes are unavailable.

The installed-core profile runs fast Windows metadata contracts and the slower
profile-runner lifecycle contract as separate suites. The metadata suite keeps
its three-minute deadline; the lifecycle suite has a seven-minute deadline
derived from its approximately 3.5-minute native Windows baseline plus cleanup
reserve. This split preserves the full contract without allowing one slow
lifecycle test to hide which boundary exceeded its budget.

CI writes the atomic report below the private runner temp directory. A manual
run creates a random private report directory and prints its absolute path at
the end.

Pull-request CI runs all nine profiles as blocking Windows contract profiles
and uploads their provenance-bound timing reports, one artifact per profile and
run attempt. The stable `Deterministic suite (windows-latest)` check downloads
the reports of every attempt of its run, judges each profile by its newest
report, validates SHA/run consistency, that each report carries the attempt its
artifact names and that none comes from a later attempt than the check's own,
plus the exact ordered suite inventory and complete execution-contract digest,
and fails closed on a missing, failed, timed-out, or incompletely cleaned
profile. That digest binds the manifest, command catalog, runner, supervisor,
Windows Job Object helper, summarizer, complete CI workflow configuration, and
every referenced suite file. Re-running only the failed jobs can therefore turn
the check green. The check also requires the shard job's result to be
`success`, so an older report never stands in for a shard whose newest run
failed before uploading one.

The complete deterministic non-Promptfoo suite remains blocking on Ubuntu. The former
per-pull-request Windows monolith is preserved in a separate scheduled,
read-only Windows safety workflow that is weekly and manually dispatchable. Its
bounded matrix partitions the exact prior Windows canary, every non-Promptfoo
structure test, and all three deterministic non-Promptfoo offline eval runners
without duplication or loss.
Every command runs through the same bounded supervisor and Windows Job Object
cleanup used by the blocking profiles, with a 30-minute command deadline; no
individual safety job can consume the six-hour hosted-runner maximum. It no
longer extends the pull-request critical path. Outside the scheduled
`live-evals.yml` below, Promptfoo suites are local-only: no pull-request or
release gate runs Promptfoo or a model, GitHub Actions never invokes the
Promptfoo binary, a live model, config validation, nightly profiles, or release
profiles, and the CI suites start the model wrapper only in its dry-run mode or
against a stub `claude`. The Session Control and
reset-review self-checks expose a `--ci` mode that skips Promptfoo while
retaining their credential-free contract, attestation, barrier, provenance,
and deterministic wrapper selftests. Release workflows use deterministic
exact-SHA, clean-tree, and runtime-digest evidence.

`scheduled.yml` runs once a day and on manual dispatch, on Ubuntu only.
`node tests/run-clock-shift.js` runs every `tests/structure/*.test.js` with `Date`
moved forward by the `shiftDays` of `tests/profiles/clock-shift-allowlist.v1.json`,
through the `tests/lib/clock-shift.cjs` preload in `NODE_OPTIONS`, so the node CLIs a
test spawns read the same shifted clock. A fixed-date fixture that the code under test
reads on the real clock then fails there weeks before the date turns every branch red,
which pull-request CI cannot see. The run fails on a top-level test failure outside the
allowlist, on an allowlisted name that more than one top-level test carries, and on an
allowlist entry whose test passes or no longer exists. File times stay on the real clock.
A test that compares one with `Date.now()` therefore sets each time it relies on with
`fs.utimesSync`, after the last write to the file, from the clock the code reads:
`Date.now()` or the `now` the test injects. A test that needs a ctime, which no call can
set, injects a time read from a file the kernel just stamped instead. The allowlist is for
a test that can do neither. The same
command takes unit files as arguments for a local check, for example
`node tests/run-clock-shift.js tests/structure/full-suite-ci-v1.test.js`.

### Scheduled live evals

`live-evals.yml` runs once a day at 03:17 UTC and on manual dispatch, on Ubuntu only, in the
`live-evals` environment. It is an advisory canary: a red run asks for a look and never blocks a
pull request or a release. Every run installs the newest `@anthropic-ai/claude-code` release
through `.github/scripts/live-evals-install-claude-code.sh`: resolved with `npm view`, installed
with install scripts off, refused when the lockfile gives an install script to another package or
pulls a package that is not a Claude Code package on the npm registry, then set up by Claude
Code's own `install.cjs` and version-checked. Only its `claude` command goes on `PATH`. So a
Claude Code release that breaks the plugin's evals shows up the night after it ships, and the
summary names the version. The workflow installs its own dependencies on Node 22, the engine
floor of Claude Code, with `npm ci --ignore-scripts`. `.github/scripts/live-evals.sh` then runs
four steps:

- `probe` starts a run: it drops the usage ledger, notice and suite table an earlier run left in
  the results directory, then makes one tiny `claude -p` call. Without a credential it fails and
  names both secrets. When the reply is a usage-limit message it skips the suites with a warning,
  because results produced at a limit say nothing about the plugin. Any other error fails the
  step.
- `run` runs `zen-mode-reaction` and `context-nudge-reaction` through the pinned Promptfoo from
  `node_modules`, with a private Promptfoo home and telemetry and update checks off. Each
  `claude` call appends a line with its cost, tokens, turns and models to a usage ledger. Each
  suite is judged only by the ledger lines and the results file of its own Promptfoo run: an
  assertion that failed on an answer without a usage-limit message marks it failed; otherwise a
  usage limit in its ledger lines marks it inconclusive, and any other Promptfoo failure marks it
  failed. A usage limit in its ledger lines also skips the later suites, and a failed suite turns
  the run red.
- `summary` writes the Claude Code version, the model, each suite's status and the usage totals
  to the job summary.
- `scrub` copies the results into a separate upload directory and leaves out every file that
  holds a credential value, every symbolic link and every other entry that is neither a regular
  file nor a directory. It fails the step when it left a file out. When it cannot read an entry
  it writes no `scrubbed=true`, and the upload step, which runs only on that output, uploads
  nothing. The staged results and the ledger are kept for 14 days.

Setup, once, by a repository owner:

1. Create a Claude account just for this workflow. `claude setup-token` requires a Claude
   subscription (its `--help` says so). Under a subscription login `claude -p` draws from that
   subscription's usage limits, which the account then holds for the nightly alone. Whether
   those limits cover a full run is not known in advance: the summary's usage-limit column shows
   it.
2. Run `claude setup-token` and approve the request in a browser that is signed in to that
   account only, a private window for example. It prints a long-lived token. Approved in a
   browser signed in to your own account, the token would draw from your own limits.
3. Create the environment `live-evals` (Settings → Environments → New environment) and limit its
   deployment branches to `main` (Deployment branches and tags → Selected branches and tags →
   add `main`). Then store the token as its secret with
   `gh secret set CLAUDE_CODE_OAUTH_TOKEN --env live-evals` and paste the token when asked. An API
   key works instead, stored the same way as `ANTHROPIC_API_KEY`; set only one of the two.
4. Optional: `gh variable set EVAL_CLAUDE_MODEL --body haiku` sets the model for the scheduled
   runs and for a dispatch with an empty model input. Without it every session uses the account's
   default model.

Run it by hand from `main` with
`gh workflow run live-evals.yml --ref main -f suites=zen-mode-reaction -f model=haiku` (both
inputs are optional); the environment refuses a run from another branch. The suites the workflow
does not run yet stay local-only: `route-short-line-reaction` needs a user-scope `zensu@zensu`
install in the runner's Claude home, `session-control` (live, concurrency, adversarial) and
`reset-review-limit` check Claude Code 2.1.221 exactly, and `tdd-manager-pretool` still targets
the removed `zensu:tdd-manager` agent. `test-promptfoo-local-only.sh` keeps every other workflow
free of Promptfoo, the live-eval scripts and model credentials, and pins this workflow's
triggers, read-only token, environment, Node version, script-free dependency install, the three
steps that receive the credential and the upload that follows only a complete scrub, with a
planted weakening for each that must fail; `test-live-evals.sh` drives the scripts against stub
`claude`, `promptfoo` and `npm` binaries.

`playwright-cli-drift.yml` also runs once a day and on manual dispatch, on Ubuntu only, and
runs no suite. Its `drift` job keeps the read-only token and runs
`.github/scripts/playwright-cli-drift.sh`, which reads the npm registry metadata of
`@playwright/cli` with one `curl` and never installs or runs the package. When the highest
stable version there is newer than `PLAYWRIGHT_CLI_SOURCE_VERSION`, the version the browser
consent gate's parser port was measured against, the `drift-issue` job, which holds
`issues: write` and nothing else, opens or rewrites the issue labelled `playwright-cli-drift`
with the steps to re-record `tests/structure/fixtures/playwright-cli-argv.v1.json` locally,
and it closes that issue once the measured version is the newest again. A red scheduled run
comments on or opens the issue labelled `playwright-cli-drift-check`.
`test-playwright-cli-drift.sh` guards the workflow graph, runs the script against fixture
metadata and the two issue steps against a fake `gh`, and runs three mutants that its own
cases must catch.

## Suites

| Path | Kind | Covers |
|---|---|---|
| `tests/structure/test-*.sh` | deterministic | hooks, libs, skill/agent wiring, version sync, evidence runner, stop-enforcer, plan-approved, session-start, FSM gate |
| `evals/config-gate/run-eval.sh` | deterministic | pre-edit TDD gate matrix, auto-fix rounds/suggestions routing, config resolution, log-style (~60 offline tests) |
| `evals/verify-feature/run-eval.sh` | advisory live Promptfoo | `/zensu:verify-feature` local proof and remote URL-policy boundary; requires a disposable host and is intentionally excluded from `tests/run-all.sh --live` |
| `tests/e2e/` | live | `code-reviewer` agent anti-loop guardrails |
| `tests/e2e-plm/` | live | `zensu-plm` agent workflow + MCP tool sequencing |
| `tests/e2e-skills/` | live | `zensu-help` · `plan-review` · `self-review` skills + `review-aspect` agent |
| `tests/e2e-tdd/` | live | full `/zensu:build` cycle (RED→GREEN→review→self-review→done), real `node --test` |
| `tests/e2e-context-nudge/` | live | `user-prompt-context-nudge.sh` parsing a real `claude --print` session transcript (read→occupancy→threshold→`/compact` proposal) |
| `tests/structure/test-tdd-full-cycle.sh` | deterministic | the same full cycle driven through the hooks (no API) |
| `tests/integration/gitlab/` | live service (Docker) | the GitLab VCS driver against a disposable GitLab CE with real glab builds; CI runs it through `.github/workflows/gitlab-live.yml`, `tests/run-all.sh` never does |

## Running individual suites

```bash
# Deterministic (no API)
for t in tests/structure/test-*.sh; do bash "$t"; done
bash evals/config-gate/run-eval.sh --self-check

# Live (API; build fixtures first where present)
bash tests/e2e/setup-fixtures.sh        && bash tests/e2e/run.sh
bash tests/e2e-plm/setup-fixtures.sh    && bash tests/e2e-plm/run.sh
bash tests/e2e-skills/setup-fixtures.sh && bash tests/e2e-skills/run.sh
# Re-match the newest captures without re-spending: append --offline
# Validate skeleton without spawning claude:           append --self-check

# Advisory Promptfoo eval; it has no --offline/--self-check mode and grants unrestricted host access.
ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1 evals/verify-feature/run-eval.sh

# Live GitLab (Docker; a 1.2-1.6 GiB image that boots in minutes)
bash tests/integration/gitlab/run.sh                # pinned glab matrix, removes the container it started
bash tests/integration/gitlab/run.sh --keep         # keep GitLab up for repeated runs
bash tests/integration/gitlab/drift.sh              # pin lines of glab or GitLab releases past the pins; runs no build
bash tests/integration/gitlab/gitlab-down.sh        # remove a kept container
```

## Live GitLab suite

`tests/integration/gitlab/` proves what the fake-backed `test-vcs-*` suites cannot: that real
glab builds talk to a real GitLab the way the driver expects. `run.sh` installs each glab version
pinned in `versions.v1.json` (sha256 per platform), starts the pinned GitLab CE image by digest
(`gitlab-up.sh`, memory-constrained, port 8929 on 127.0.0.1), mints a throwaway root token inside
the container and runs `test-vcs-gitlab-live.sh` once per glab version. Each run seeds its own
project and merge request with an added, a removed, a context, a renamed and an out-of-diff line,
drives every verb that reaches glab (`--post-review`, `--fetch-threads`, `--resolve-thread`,
`--reconcile-review`, `--diff-refs`, `--pr-state`, `--scout-pr`, `--locate-pr`, `--review-markers`,
`--review-summary` and `--open-pr`), and asserts what GitLab stored through its API. A second
merge request, opened through `--open-pr`, starts with resolvable discussions only (`GL64`-`GL68`);
its approval then adds a system note that `--fetch-threads` has to pass over (`GL71`, `GL72`). The summary line
reads `N PASS / M FAIL / K XFAIL`.

- **Known bugs are XFAIL, strictly.** `xeq` takes the fixed result and the result the reported
  driver bug produces. The bug's result counts as `XFAIL`, the fixed result prints `XPASS` and
  fails the suite, so the fix has to turn the check back into `eq`, and any other result fails.
- **Credentials.** The token lives only in the state directory (mode 0700, files 0600) and is
  never printed. `gitlab-down.sh` removes only a container that carries the
  `dev.zensu.gitlab-it=1` label.
- **Where it runs.** Pull requests that touch `hooks/lib/zensu-vcs.sh`, this directory or the
  workflow run the pinned lane; the required check is the `GitLab live result` job. A nightly
  run repeats the pinned lane and, when it fails, comments on the open issue labelled
  `gitlab-live` or opens one. Both release stages run the pinned matrix as a gate.
- **Only pinned builds run in CI.** The nightly drift job reads the newest glab release with its
  vendor `checksums.txt` and the Docker Hub tag listing of `gitlab/gitlab-ce`, downloads no
  archive and pulls no image. When upstream released past the pins, it opens or rewrites the
  issue labelled `gitlab-live-drift` with the new pin lines, and closes it once the pins catch
  up. Adopting them is a pull request that edits `versions.v1.json`, which runs the matrix.
- **One run at a time.** `run.sh` holds `run.lock` in the cache directory, so two local runs
  cannot share the container or tear it down under each other.
- **Knobs.** `ZENSU_GITLAB_IT_CACHE` (glab builds and state), `ZENSU_GITLAB_IT_VERSIONS`
  (another pin file, the way to try a release before pinning it), `ZENSU_GITLAB_IT_CONTAINER`,
  `ZENSU_GITLAB_IT_PORT`, `ZENSU_GITLAB_IT_MEMORY` (default `4g`),
  `ZENSU_GITLAB_IT_BOOT_SECONDS`, `ZENSU_GITLAB_IT_KEEP=1` (keep the seeded project) and
  `ZENSU_GITLAB_IT_LIB` (run another driver file, for a mutation or bisect run).

## Conventions

- Deterministic tests use a `check()` helper, print `PASS`/`FAIL` per assert, end with
  `<name>: N PASS / M FAIL`, and exit non-zero on any failure.
- Live pattern files (`expected/<name>.pattern`): positive regex per line, `!`-prefix =
  negative assert, `# ` = comment. Tolerant by design (LLM output is non-deterministic).
- Generated fixtures (`*/fixtures/`) and captures (`*/results/`, `tests/results/`) are
  git-ignored; build them with each suite's `setup-fixtures.sh`.
- Deterministic non-Promptfoo suites run in CI via `--ci`. Promptfoo and live model/API
  suites remain explicitly local and opt-in, except the two that the advisory `live-evals.yml`
  runs every night (§"Scheduled live evals"). The live GitLab suite runs in CI only through
  `.github/workflows/gitlab-live.yml` and the release gates, never through `run-all.sh`.

## Live-suite notes

- **Output-style hermeticity:** the live runners prepend a *normal-mode* directive so a
  user's personal output-style plugin (e.g. `caveman`) cannot compress the section
  headings / tool names the patterns assert. Override the wording via
  `ZENSU_E2E_NORMAL_PREAMBLE`.
- **MCP auth (`e2e-plm`):** patterns are lower-bound — they assert the agent *names* the
  Zensu MCP tools it would call, which normal-mode output does even when the hosted
  `mcp.zensu.dev` server is unauthenticated. Real tool *execution* needs `ZENSU_API_KEY`
  (a headless `claude --print` cannot complete the OAuth browser flow).

## Known follow-up

The promptfoo/expect harnesses under `evals/tdd-manager/`, `evals/tdd-manager-pretool/`,
and `evals/tdd-review-chain/` still target the pre-0.4.0 `zensu:tdd-manager` subagent
(removed when TDD moved to the main thread). They are not part of the deterministic
suite or `run-all.sh`; rewriting them to the main-thread `/zensu:build` model is pending.

The automatic-context core contract runs first on `windows-shard-1` with a
60-second cap. It uses one Node process and injected CLI execution; the POSIX
wrapper process fixtures remain in the Linux gate. This small suite precedes the
existing long-running tests so it cannot be starved by their remaining budget.
