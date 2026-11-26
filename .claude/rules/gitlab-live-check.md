---
paths:
  - "tests/integration/gitlab/**"
  - ".github/workflows/gitlab-live.yml"
  - ".github/workflows/release.yml"
  - "tests/structure/test-gitlab-live-workflow.sh"
  - "hooks/lib/zensu-vcs.sh"
---

# GitLab Live Check (`tests/integration/gitlab/` + `.github/workflows/gitlab-live.yml`)

The fake-backed `test-vcs-*` suites replace glab with a script that encodes our model of glab and
GitLab. Every GitLab defect so far lived in the gap between that model and the real tools: the
HTTP 415 of an `--input` body without a Content-Type under glab up to 1.122, the bracketed
`-f position[...]` fields that glab 1.123 refuses and that glab 1.113 sends without a position,
the marker that GitLab's JSON escapes, the `resolved` field that plain comments and system notes
do not carry, and the capitalized no-merge-request message of older glab releases.
The live tier exists to close that gap. It is not a replacement for the fakes, which stay the
fast tier on every pull request.

**What runs.** `run.sh` takes `run.lock` in the cache directory for the whole run, installs every
glab version in `versions.v1.json`, starts the GitLab CE image pinned by digest, mints a root token
inside the container with `gitlab-rails runner` and runs `test-vcs-gitlab-live.sh` once per glab
version. `lib.sh` holds the defaults every script shares (cache, state, container name, label),
the one pin reader, `gitlab_it_pin`, which reads the file `ZENSU_GITLAB_IT_VERSIONS` names, and the
one fetcher, `gitlab_it_fetch`, through which `glab-install.sh` and `drift.sh` make every download.
The suite refuses with exit 2 when it is not configured; it never passes on a skip. It drives the
driver with explicit `--provider gitlab` and `--repo-id`, because the SSRF guard in
`_zensu_vcs_probeable_host` rightly refuses loopback hosts, so provider detection stays covered by
`test-vcs-detect.sh`. Every verb that reaches glab is driven: `--post-review`, `--fetch-threads`,
`--resolve-thread`, `--reconcile-review`, `--diff-refs`, `--pr-state`, `--scout-pr`, `--locate-pr`,
`--review-markers`, `--review-summary`, `--pr-diff`, `--open-pr` and `--edit-pr-body`. `--pr-diff`
rebuilds the first merge request's diff (`GL58`-`GL59b`). The second merge request, opened through
`--open-pr`, starts with resolvable discussions only (`GL64`-`GL68`); its approval then adds a
system note that `--fetch-threads` has to pass over (`GL71`, `GL72`), and `--edit-pr-body` then
rewrites its description (`GL73`, `GL74`). Not covered: the `changesRequested` arm of
`--review-summary`, which needs a second GitLab user.

**Where it runs, and why not in `tests/run-all.sh`.** A GitLab container costs a 1.2-1.6 GiB pull,
several GB of memory and minutes of boot, so it runs only where its signal pays for it:

- pull requests whose diff touches `hooks/lib/zensu-vcs.sh`, `tests/integration/gitlab/` or the
  workflow, pinned lane only. The scope step asks `git diff --name-only` with those pathspecs,
  never a pipe into `grep -q`: under `pipefail` an early-exiting reader can fail a long `printf`
  and drop the lane. The driver reads no file but `repo-conventions-v1.js`, which only
  `--conventions` loads and the live suite never calls; `W17` fails when that changes, and the
  pathspecs must then name the new file too;
- nightly, the pinned lane plus the drift job below. The `notify` job runs after every scheduled
  run and reads the results of `result`, `drift` and `drift-issue` through `env:`. A red run, live
  or drift, comments on the open issue labelled `gitlab-live`, or opens one; a green run closes
  that issue with a comment that links the run. The label, not the title, finds it, because
  anyone can open an issue with a copied title;
- both release stages, `prepare-gitlab-live` against the bundled release commit and
  `publish-gitlab-live` against the published SHA. `skip_test_gate` skips them like the suite
  shards, and `prepare` and `publish` accept a skipped gate only together with a skipped suite.
  Their evidence steps read the GitLab result too, so `gate: "passed"` means both gates passed
  (`workflow-dispatch-inputs.test.js`). `test-release-session-control-gate.sh` pins the third
  bundle download this adds.

**The required check is the `GitLab live result` job**, never the live job itself. GitHub
reports a skipped job as a success, also when an upstream job failed, so the aggregate reads
the scope result and the live result explicitly and fails a failed scope or a failed selected
lane. A pull request outside the scope gets a green aggregate with a skipped live job. The guard
executes the scope, lane and verdict steps from the YAML against fixtures (`W4a`-`W5d`,
`W9a`-`W9j`, `W24`-`W27`) and pins the release `if:` expressions verbatim (`W12`, `W14`).

**CI runs pinned builds only.** No lane runs the newest glab or `gitlab-ce:latest`: that would run
unreviewed upstream code on the runner every night. The `drift` job keeps the read-only token, downloads no archive and pulls no image. `drift.sh` reads
the newest glab release from the GitLab releases API with its vendor `checksums.txt`, and the
highest `X.Y.Z-ce.0` tag on the first page of the Docker Hub tag listing with its digest. That
page is sorted by push time and backports of older minors arrive after newer releases, so the
highest version counts, never the first listed. It fails, and the run turns red, when a newest
release is older than its pin, when the vendor checksums of the pinned glab release no longer
match the pin, or when the metadata do not parse; a pinned GitLab tag that names a new digest
is drift. The `drift-issue` job, the second job with `issues: write`, opens the issue labelled
`gitlab-live-drift` with the report's pin lines, rewrites it when its marker line
`<!-- zensu-gitlab-drift … -->` changes, and closes it when the report is empty. It runs only
after a successful drift job: a failed one hands on no report, and an empty report closes the
issue. The guard runs `drift.sh` against fixtures and the compare, drift issue and `notify` steps
with a fake `gh` (`W33`-`W60`). The cost, accepted on purpose: a release that breaks the driver surfaces in
the pull request that pins it, not on the night it ships.

**Known bugs are strict XFAIL with a signature.** `xeq` takes the fixed result and the result the
bug produces, as measured. The fixed result prints `XPASS` and fails the suite, so the fix must
turn the check back into `eq` in the same change; the bug's own result prints `XFAIL`; any third
result fails, so a regression cannot hide behind a known bug. A recorded bug also gets a plain
check that its trigger is present, so the fixed check cannot pass for want of the trigger.
`GL19` and `GL71` hold that guard for `--fetch-threads`: the merge requests carry a plain comment
and an approval's system note, neither with a resolution state. A trigger check stays after its
bug is fixed, so the `eq` that replaced the `xeq` cannot pass for want of the trigger either:
`GL19` guards `GL20`, `GL71` guards `GL72`.

**Pins.** `versions.v1.json` pins the image by digest and each glab build by sha256 per platform
(`linux_amd64` for CI, `darwin_arm64` for local runs). `glab-install.sh` refuses a version or
platform without a pin, and `gitlab-up.sh` starts only the pinned image; neither takes an
override, so a release is tried before pinning by pointing `ZENSU_GITLAB_IT_VERSIONS` at a copy of
the pin file with the drift issue's lines. A dispatch takes `pinned` or a list of pinned
versions only. A bump replaces the pin entry the drift report names and runs the matrix.

**Downloads retry within a bound.** `gitlab_it_fetch` runs curl with `-f`, `--retry 3`,
`--retry-all-errors`, `--retry-delay 5`, `--retry-max-time 120` and `--proto-redir =https`. Plain
`--retry` counts only a timeout and HTTP 408, 429, 500, 502, 503 or 504 as transient, so the
connection reset (curl exit 56) that once failed the publish gate needs `--retry-all-errors`. curl
discards a partial download before the next attempt, and the sha256 pin check still guards what
installs; `-f` keeps an HTTP error a failure once its retries are spent. No retry is scheduled once
two minutes have passed since the first attempt began, so a `Retry-After` that reaches past that
window fails at once instead of sleeping through the job timeout, and an archive download that
stalls to its 600 s `--max-time` is not retried. `--proto-redir =https` keeps every redirect hop on
HTTPS, because the checksums `drift.sh` reads become the next pin; the guard's `file://` fixtures
are never redirected, so it does not touch them. `--no-progress-meter` replaces `-s`, so each retry
leaves a warning in the job log. The polling loops and the token check in `gitlab-up.sh` and the
suite's API calls keep plain curl: they poll already, pipe their output, or must not repeat a write.
`W61` and `W62` record every curl call of `glab-install.sh` and `drift.sh` through a logging wrapper
and compare the whole command line with only the output file and the URL masked, so they fail when
a flag goes missing, an option is added anywhere, or either script calls curl itself. They pin the
flags; no suite run provokes a retry.

**Credentials and containers.** The token is written into the container as the `git` user through
stdin, never through argv, and lives on the host only in the state directory (0700, files 0600).
`gitlab-up.sh` reuses a running labelled container and reseeds its token; `gitlab-down.sh` removes
only a container labelled `dev.zensu.gitlab-it=1`. The suite's glab config sets
`check_update: false`: an old glab prints its update notice on stderr and calls gitlab.com.

**Release class: `patch`.** Tests, CI and documentation only: no hook, schema, strict key set,
config key or attestation moves.
