---
paths:
  - "tests/integration/github/**"
  - ".github/workflows/github-live.yml"
  - ".github/workflows/release.yml"
  - "tests/structure/test-github-live-workflow.sh"
  - "tests/structure/test-promptfoo-local-only.sh"
  - "hooks/lib/zensu-vcs.sh"
---

# GitHub Live Check (`tests/integration/github/` + `.github/workflows/github-live.yml`)

GitHub is the main forge, and the team's own pull requests exercise the driver's GitHub path every
day, but only along the happy path. Re-runs, resolved threads, refused reviews and old gh releases
had fake coverage only, and the GitLab live tier showed how much a fake can hide. This tier drives
the GitHub path with real gh builds against github.com. It is not a replacement for the fakes,
which stay the fast tier on every pull request.

**Why a sandbox and not a container.** There is no disposable GitHub: GitHub Enterprise Server is a
licensed appliance. The tier therefore writes to one dedicated sandbox repository on github.com
through a GitHub App installed on that repository only, with Contents and Pull requests write and
nothing else. The sandbox is private, starts from a README commit, has Actions disabled and no
branch protection. The user owns the repository, the App and its key; an agent never creates,
reads or prints them.

**What runs.** `run.sh` validates the selection, checks with `github-token.sh --check` that the
credentials are configured before it downloads anything, takes `run.lock` in the cache directory,
installs every pinned gh build and, per build, mints an installation token, runs
`test-vcs-github-live.sh` and revokes the token. `app-token.js` signs the App JWT with the key,
asks for a token limited to the sandbox repository and to `contents: write`,
`pull_requests: write`, `metadata: read`, and refuses a token that reaches more. The token lives
only in the state directory (0700, `token` and `header` 0600), reaches gh through `GH_TOKEN` and
curl through a header file, and is masked with `::add-mask::` inside GitHub Actions. The App key
reaches the harness either as `ZENSU_GITHUB_IT_APP_KEY_FILE` (0600, refused when others can read
it) or as `ZENSU_GITHUB_IT_APP_KEY`, which `github-token.sh` writes to a 0600 file and deletes after
minting; `run.sh` strips both from the suite's environment. Local runs read
`~/.config/zensu-github-it/{app-id,private-key.pem,repo}`.

**The suite.** Each run works under its own prefix `zensu-it/<epoch>-<hex>/`: it seeds an orphan
base commit and a feature commit through the Git Data API, opens the first pull request through
the REST API and the second through `--open-pr`, and drives every verb that reaches gh:
`--detect`, `--post-review`, `--fetch-threads`, `--resolve-thread`, `--reconcile-review`,
`--diff-refs`, `--pr-state`, `--scout-pr`, `--locate-pr`, `--review-markers`, `--review-summary`
and `--open-pr`. It asserts what GitHub stored through REST and GraphQL, never through the driver
under test. Two GitHub semantics are pinned on purpose: a review with one anchor outside the diff
is refused as a whole with HTTP 422 and stores nothing (`GH10`, `GH11`), and a standalone
`--post-review` re-run adds a second review, as `skills/pr-team-review/rules/github-publish.md`
documents; idempotency is `--reconcile-review`'s job (`GH50`-`GH56`). At the end the run closes its
pull requests and deletes its branches, also after a failure or a signal, and checks that nothing
of it is left (`GH90`, `GH91`). A run killed outright leaves its prefix behind; the next run sweeps
every prefix older than six hours (`GH3`). The suite refuses with exit 2 when it is not
configured; it never passes on a skip. Before its first write it fails when GitHub reports the
repository as not private (`GH2a`), so a mistyped `repo` file or `ZENSU_GITHUB_IT_REPO` variable
cannot aim a run at a public repository where the App happens to be installed. Not covered: the `approved` and `changesRequested` arms of
`--review-summary`, because GitHub refuses an approval or a change request on a pull request by
the reviewer's own identity and the tier has one identity; GitHub Enterprise Server.

**Where it runs, and who can read the key.** The pinned lane runs for same-repository pull requests
whose diff touches `hooks/lib/zensu-vcs.sh`, `tests/integration/github/` or the workflow, nightly,
and on dispatch, which takes `pinned` or a list of pinned versions. Fork pull requests and runs
started by Dependabot get no secret, so the scope step selects no lane for them and says why in a
notice; the nightly run and the release gate cover such a change after the merge. The key is a
repository secret, so every collaborator with write access and every agent that opens a pull
request in this repository can read it; that is accepted because the App reaches the sandbox
repository only. Moving the key into an environment that only `main` may use closes that, at the
price of every pull-request run: a gh pin bump would then be verified only after its merge.
`test-promptfoo-local-only.sh` admits `secrets.ZENSU_GITHUB_IT_APP_KEY` as the one secret beside
the repository and immutable-release tokens, and `W8` pins that it reaches only the three steps
that run the harness. A red scheduled run, live or drift, comments on the open issue labelled
`github-live`, or opens one.

**Release gates.** `prepare-github-live` runs the pinned matrix against the bundled release commit
and `publish-github-live` against the published SHA, beside the GitLab gates. `skip_test_gate`
skips them like the suite shards; `prepare` and `publish` accept a skipped gate only together with
every other skipped gate, and their evidence steps read `LIVE_GITHUB_RESULT`, so
`gate: "passed"` means every gate passed (`workflow-dispatch-inputs.test.js`). The release stages
depend on github.com and the sandbox key: an outage blocks a release until it ends or a recorded
`skip_test_gate` ships it. `test-release-session-control-gate.sh` pins the fourth bundle download
this adds, and the GitLab guard pins the same `if:` expressions verbatim.

**The required check is the `GitHub live result` job**, never the live job itself: GitHub reports
a skipped job as a success, so the aggregate reads the scope and live results explicitly. The
guard executes the scope, lane, verdict, compare, issue and notify steps from the YAML against
fixtures and fakes (`W4a`-`W5d`, `W9a`-`W9j`, `W25`-`W28`, `W52`-`W62`), runs the installer, the
token minting against a local fake API and `drift.sh` against a fake curl, and pins the release
`if:` expressions verbatim (`W12`, `W14`).

**CI runs pinned builds only.** The `drift` job keeps the read-only job token, installs and runs
no gh build, and hands the token to `drift.sh` only for the GitHub API request, through curl's
stdin (`W44`), never to a download. `drift.sh` reads the newest gh release and its vendor
`gh_<version>_checksums.txt`; it fails when the newest release is older than the newest pin, when
the vendor sums of the pinned release changed, when the release is a prerelease or carries no
plain `vX.Y.Z` tag, or when the metadata do not parse. The `drift-issue` job opens, rewrites or
closes the issue labelled `github-live-drift` through its marker line
`<!-- zensu-github-drift … -->`, as the GitLab tier does.

**Pins and the floor.** `versions.v1.json` pins each gh build by sha256 per platform
(`linux_amd64` for CI from the `.tar.gz`, `darwin_arm64` for local runs from the `.zip`): the
floor 2.48.0 and the newest release. The "gh floor" paragraph of `docs/vcs-driver-spec.md` records
why the floor is 2.48.0, and `W16` fails when the oldest pin and that floor disagree. `gh-install.sh` refuses a
version or platform without a pin, a download that differs from it, and a build that reports
another version.

**Release class: `patch`.** Tests, CI and documentation only: no hook, schema, strict key set,
config key or attestation moves. `docs/vcs-driver-spec.md` is in the runtime digest, so do not edit
it while a suite is running.
