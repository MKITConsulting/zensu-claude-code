# Spec: VCS Driver (GitHub + GitLab)

Status: **implemented** — Phases 1–5 shipped (see §6 "Implementation status").

## 1. What it does

Introduces a **VCS driver abstraction** so the three PR-facing capabilities —
`/zensu:pr-team-review`, `/zensu:pr-fix-findings`, and `/zensu:autopilot`'s PR
steps — work against **both GitHub and GitLab** instead of being hard-wired to
the `gh` CLI. It adds:

1. **Deterministic host detection** — figure out which forge a repo targets, and
   whether the matching CLI is available and authenticated.
2. **A driver interface** — a fixed set of VCS operations (locate PR, open PR,
   fetch threads, publish review, resolve thread) each forge implements with its
   own CLI + REST calls.
3. **Graceful degradation** where the forges genuinely differ (GitHub has one
   atomic review object; GitLab has per-discussion notes).

The change is **additive and regression-safe**: on a GitHub repo every skill
must behave byte-for-byte as it does today.

## 2. Who it is for

- Teams whose canonical remote is **GitLab** (SaaS `gitlab.com` **or**
  self-hosted / GitLab Data Center on an arbitrary host) and who want the Zensu
  PR review + fix + autopilot loop there.
- Existing **GitHub** users (cloud + GitHub Enterprise) — unchanged behavior,
  they never notice the abstraction.

## 3. Who it is NOT for

- **Bitbucket** (Cloud or Data Center) — explicitly out of scope. Its two
  editions are two different API contracts and there is no mature credential-blind
  CLI; deferred to a separate spec if ever.
- Gitea, Azure DevOps, or any other forge.
- Users who want token management handled by Zensu — auth stays owned by the
  underlying `gh` / `glab` CLIs (credential-blind, see §8).

## 4. What success looks like

1. **Zero GitHub regression** — the structure tests and existing behavior of all
   three skills pass unchanged on a GitHub remote.
2. **GitLab parity for the core loop** — on both `gitlab.com` and a self-hosted
   instance: `pr-team-review` publishes one summary note + inline discussions;
   `pr-fix-findings` fetches unresolved discussions, pushes fixes, and resolves
   them; `autopilot` opens an MR and drives its review→fix→validate loop.
3. **Detection is deterministic** — same repo always resolves to the same
   provider without asking, except the genuine unknown-self-hosted-host case,
   which asks once and persists the answer.
4. **Mismatch is loud** — "remote is GitLab but `glab` is not authenticated"
   produces a clear, actionable message and **never silently falls back** to the
   other forge.
5. **Credential-blind preserved** — the model never reads a token; auth lives in
   `gh` / `glab`.

## 5. Out of scope

Bitbucket / other forges · token storage or OAuth flows · rewriting the review
*content* logic (persona casting, debate, synthesis stay as-is — only the
*publish/fetch/resolve* I/O is abstracted) · MCP-based posting · auto-installing
a missing CLI (we detect + instruct, never install).

---

## 6. Build steps — each with its key decision + default

### Step 1 — Detection helper `hooks/lib/zensu-vcs.sh`

A deterministic shell helper (same role as `zensu-cli-map.sh`: single source of
truth, callable from any skill via Bash). Subcommand `--detect` prints a
machine-parseable block:

```
provider=github|gitlab|unknown
edition=cloud|enterprise|selfhosted   # empty when provider=unknown
apiBase=https://api.github.com | https://<host>/api/v3 | https://gitlab.com/api/v4 | https://<host>/api/v4   # empty when host unknown
repo=<owner>/<repo>            # github: owner/repo ; gitlab: url-encoded namespace/project ; empty when unknown
cliReady=true|false            # matching CLI installed AND authenticated
cliName=gh|glab                # empty when provider=unknown
cliState=ready|unauthed|missing   # distinguishes "CLI absent" from "present-but-unauthed"; drives the reconcile matrix
```

**Resolution ladder** (first hit wins):

1. Explicit `--provider` flag / `vcs.provider` in `.zensu/autopilot.yaml`.
2. **Remote URL** of the tracking remote (fallback `origin`), host extracted
   from both SSH (`git@host:path`) and HTTPS (`https://host/path`) forms:
   - `github.com`, `*.github.*`, `api.github.com` → github/cloud
   - `gitlab.com` → gitlab/cloud
   - unknown host → **API probe** (step 3)
3. **API probe** (self-hosted disambiguation) — an HTTP liveness check
   (`curl -sS -o /dev/null -w '%{http_code}' --max-time 5`) treating **200/401/403**
   as "endpoint present":
   - `https://<host>/api/v4/version` present → gitlab/selfhosted
   - `https://<host>/api/v3/meta` present → github/enterprise
   GitLab's `/api/v4/version` answers **401** unauthenticated, so a plain `-f` /
   200-only probe would false-negative a real self-hosted GitLab — hence the status
   allowlist. The probe is **SSRF-guarded**: it never fires for IP literals,
   loopback (`127.0.0.0/8`), link-local / metadata (`169.254.0.0/16`), or RFC1918
   private hosts, so a hostile repo remote cannot force a blind outbound request;
   non-probeable hosts fall through to the marker tiebreak / `unknown`.
4. **Repo-marker tiebreak** (weak): `.gitlab-ci.yml` vs `.github/workflows/`. Only
   reached when the host is non-empty and probeable — a host that cannot be parsed
   (e.g. `node` unavailable) short-circuits to `provider=unknown` rather than
   letting a cloud repo's `.github/workflows` mislabel it enterprise.
5. Still unknown → **ask once** (AskUserQuestion), then persist to
   `.zensu/autopilot.yaml`.

> **Test seams (gated).** The offline test seams `ZENSU_VCS_PROBE_RESULT` (stub the
> probe verdict) and `ZENSU_VCS_FAKE_AUTH` (stub the auth check) are honored **only
> when `ZENSU_VCS_TEST=1`** — a stray global env var can never spoof the probe/auth
> result in a real session. `ZENSU_VCS_REMOTE` / `ZENSU_VCS_PROVIDER` /
> `ZENSU_VCS_API_BASE` are legitimate ungated overrides.

**Reconcile "needed vs available".** After provider = X ("needed", from remote),
run the matching auth check — `gh auth status` / `glab auth status` — to set
`cliReady`. The skills read `cliReady`:

| State | Action |
|-------|--------|
| ready | proceed |
| CLI missing | stop, instruct install (`brew install glab`), never auto-install |
| CLI present, not authed | stop, instruct `glab auth login` (mirrors `zensu auth login` recovery) |
| needed=gitlab but only gh authed | hard error, **no fallback** |

> **Untrusted host.** `apiBase` / `repo` are derived from the repo's own remote,
> which is attacker-influenceable. Downstream consumers (Phases 2–4) MUST treat the
> emitted host as untrusted — never send a `gh` / `glab` token to a non-allowlisted
> host, and rely on the per-host token binding of `gh` / `glab` rather than a raw
> authenticated `curl <apiBase>`.

> **Decision — helper scope (superseded in Phase 3).** Original default: the helper
> owns the **mechanical** ops (detect, pr-state, fetch-threads, resolve-thread,
> fetch-pr-ref) as thin subcommands, with the **publish** op staying in-skill because
> its payload is large. **Phase 3 revised this**: publish moved into the driver too
> (`--post-review`), because the "large payload" objection dissolves once the payload is
> passed **by file path** (`--input <file>` on GitHub; a `readFileSync` in the GitLab
> planner) rather than inline argv. Keeping publish in the driver is what lets the GitLab
> loop (§7) live in ONE hermetically-testable place instead of being re-encoded in
> markdown. The skill now issues zero raw `gh`/`glab` publish calls.

### Step 2 — Driver operation set (one interface for both forges; a GitHub-only operation names its GitLab refusal)

| Op | Consumed by | GitHub | GitLab |
|----|-------------|--------|--------|
| `detect` | all | remote+probe | remote+probe |
| `conventions(repo)` | autopilot, pilot, fix, cover, implement | tracked files + `git log` | tracked files + `git log` |
| `locate_pr(branch\|num)` | fix, autopilot, pilot | `gh pr view` | `glab mr view --output json` |
| `review_summary(id)` | pilot | `gh pr view -R <host>/<repo-id> <n> --json reviewDecision,latestReviews` | `GET …/merge_requests/:iid/approvals` + `GET …/merge_requests/:iid` (`detailed_merge_status`) |
| `review_markers(id)` | pilot, work-order review import | the `zensu-review:v1` first-part markers of the PR's reviews (GraphQL) | the same markers in the MR's notes and discussions |
| `pr_state(id)` | all (pre-push guard) | `gh pr view <n> --json state,mergedAt` | `glab mr view <iid> --output json` → `.state` |
| `fetch_pr_ref(id)` | team-review | `git fetch origin pull/<n>/head` | `git fetch origin merge-requests/<iid>/head` |
| `scout_pr(num?)` | team-review | `gh pr view [<n>] --json number,url,state,title,body,headRefName,baseRefName,author,labels` | `glab mr view [<iid>] --output json` |
| `diff_refs(id)` | team-review | `gh pr view <n> --json headRefOid` (head SHA only) | MR `diff_refs` (`base_sha`/`start_sha`/`head_sha`) via `glab api …/merge_requests/:iid` |
| `open_pr(title,body,base,head)` | autopilot, pilot | `gh pr create` | `glab mr create` |
| `fetch_threads(id)` | fix | GraphQL `reviewThreads` | REST `GET …/merge_requests/:iid/discussions` (keep `resolvable && !resolved`) |
| `fetch_inline_comments(id)` | fix | `gh api …/pulls/<n>/comments --paginate` | discussions (same call as above) |
| `post_review(id, payload)` | team-review | 1× `gh api -X POST …/pulls/<n>/reviews --input` | 1× summary note + N× inline discussions (see §7) |
| `reconcile_review(id, payload, operation, head)` | team-review (Autopilot-delegated) | 1× marker-tagged `gh api -X POST …/pulls/<n>/reviews --input -`, only when no review carries the operation's marker | the parts of the summary note + N× inline discussions that no note carries yet (see Phase 3) |
| `reply_and_resolve(thread,body)` | fix | reply comment + GraphQL `resolveReviewThread` | `POST …/discussions/:id/notes` + `PUT …/discussions/:id?resolved=true` |
| `pr_diff(id)` | team-review (GitHub anchor validation), cover | `gh pr diff -R <host>/<repo-id> --color never -- <n>`, or the repo-context form without `--repo-id` | every page of `GET …/merge_requests/:iid/diffs`, rebuilt as a unified diff |
| `edit_pr_body(id, body_file)` | autopilot (body refresh) | `gh pr edit -R <host>/<repo-id> --body-file <f> -- <n>`, or the repo-context form without `--repo-id` | 1× `PUT …/merge_requests/:iid` with `{"description": …}` on stdin |
| `post_comment(id, payload)` | team-review (standalone per-comment fallback) | 1× `gh api -X POST …/pulls/<n>/comments --input` | refused: every GitLab comment is its own discussion through `post_review` |
| `fetch_review(id, review)` | team-review (verification) | `gh api …/pulls/<n>/reviews/<review>` + every page of `…/reviews/<review>/comments` | refused: GitLab has no review object |

**The GitHub host (`_zensu_vcs_gh_host`).** Every GitHub verb pins the pull request's own
host, because gh otherwise answers from `GH_HOST` or from the only host it is logged in to:
a `gh api` call ends with `--hostname <host>`, `gh pr view -R` takes `<host>/<owner>/<name>`,
and a repo-context `gh pr` call runs as `env GH_HOST=<host> GH_REPO= gh pr …`, because gh takes
the base repository from `GH_REPO` before the git remotes: measured with gh 2.101.0, a
three-part `GH_REPO` moves `gh pr view` to its own host whatever `GH_HOST` and the remote name,
and an empty one counts as unset. The host comes from the remote `--detect` reads
(`ZENSU_VCS_REMOTE`, else the remote the current branch tracks, else `origin`), through the same
`_zensu_vcs_split_url`; a tracking remote without a URL, such as the `.` of a branch that tracks
a local branch, falls back to `origin`, for `--detect` too. When that ladder selects no remote,
the verbs read every remote of the work tree and pin the host they all name, compared as
written and lowercased; remotes that name different hosts are refused with a message that names
`ZENSU_VCS_REMOTE` and `git branch --set-upstream-to`. Every GitHub verb reads the remote of the
working directory it runs in: `--repo-id` names the repository on that host and never moves the
host, so a caller runs the verbs from the pull request's work tree or sets `ZENSU_VCS_REMOTE`.
Run from another checkout, a verb pins that checkout's host or refuses. A work tree without any
remote, or a directory outside every repository, pins github.com, as `--detect --provider github`
reports the cloud edition for an empty host. The remotes come from git itself, so a directory
reached through a symlink and a bare repository read the remotes git reads. Only when git cannot
list them does a walk decide whether the directory lies inside a repository, never git failing
alone: it climbs from the physical working directory, as git does, for a `.git` entry or a bare
repository (`HEAD`, `objects` and `refs`), counts a set `GIT_DIR` as inside, and stops where
`GIT_CEILING_DIRECTORIES` stops git: measured with git 2.51.0, an entry before the first empty
one is resolved through symlinks, a later one is compared as written, and a relative one is
ignored. A work tree whose remotes git cannot read, such as one with a malformed configuration
or one `safe.directory` refuses, is therefore refused instead of pinned to github.com, and so is
a working directory whose physical path cannot be read. A remote URL that yields
no host, such as a local path, is refused. An SSH remote (scp-like, `ssh://`,
`git+ssh://`, `ssh+git://`, or a URL whose part before `://` is no valid scheme, which git
reads as scp-like) is translated through `ssh -G -- <alias>` and its `hostname` line, and
`ssh.github.com` reads as github.com; the host is lowercased and a leading `www.` is dropped.
Measured with gh 2.101.0, that is how gh itself reads the host of a remote. Before ssh runs,
the alias must be 1 to 253 characters of lowercase letters, digits, `.`, `_` and `-` that do
not start with `-`, so a `Host gh_work` alias is translated rather than refused. The host that
is pinned, the translation or else the alias, must be a valid host name (lowercase letters,
digits, `-` and `.`, labels of 1 to 63 characters that neither start nor end with `-`, at most
253 characters); any other is refused before gh runs.

**Which hosts gh may reach, and with which token.** A host is accepted when it is github.com,
the host `GH_HOST` names, or a host gh holds a stored login for: `gh config get user -h <host>`
exits 0 and prints a non-empty account name. Any other host is refused before gh runs, with a
message that names only `gh auth login --hostname <host>`. github.com and the `GH_HOST` host
run gh with the environment unchanged. A host accepted for its stored login alone runs gh with
`GH_TOKEN`, `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN` and `GITHUB_ENTERPRISE_TOKEN` set to the
empty string, which gh reads as unset, so gh authenticates that host with its own stored
token. Measured with gh 2.101.0, gh otherwise hands `GH_ENTERPRISE_TOKEN` or
`GITHUB_ENTERPRISE_TOKEN` to an enterprise host ahead of its stored token, whatever `GH_HOST`
names, and `GH_TOKEN` or `GITHUB_TOKEN` to a `*.ghe.com` host, so without the cleared
variables a token set for one host would reach the remote's host on every call. An operator
whose environment token is meant for the remote's host sets `GH_HOST` to that host in the
environment the session starts with. The refusal does not offer that route, because whoever
controls a remote chooses its host. A github.com remote keeps its behaviour, and `--detect`
keeps its classification and its `gh auth status` readiness check.

- Tests: `HD1`-`HD43` in `test-vcs-detect.sh` drive the derivation with a fake ssh, a fake gh
  and git fixtures for a local upstream, a tracked remote and an `origin` beside a remote on
  another host, remotes on different hosts, a sole remote not named `origin`, remotes on one
  host, an unreadable configuration, bare repositories, directories reached through a symlink,
  ceilings (plain, spelled through a symlink, after an empty entry, relative) and a work tree
  without a remote; `HP1`-`HP30c` in `test-vcs-pr-ops.sh`, `HS1`-`HS18` in `test-vcs-publish.sh` and
  `HR1`-`HR5` in `test-vcs-review-marker-reconcile.sh` run every GitHub verb under
  `GH_HOST=example.invalid`, against a github.com remote, a GitHub Enterprise remote gh is
  logged in to and one it is not. `HP17`, `HP17b`, `HP26`-`HP26d`, `HS9`, `HS14`, `HS14b` and
  `HR5` set all four token variables and require that no call to a host accepted for its stored
  login alone carries one; `HP18`, `HP19`, `HP26e` and `HS14c` require that github.com and the
  `GH_HOST` host keep them; `HP20`, `HP20b`, `HP27` and `HP27b` set `GH_REPO=other.example/acme/x`.
  `HP21`-`HP30c` drive `--pr-diff` and `--edit-pr-body`: `HP28` requires the diff byte for byte,
  `HP29` that a failed read prints no partial diff, and `HP30`-`HP30c` that the body file reaches
  gh and that an empty or missing one is refused before any gh call, and `EB1` that the refusal
  names itself on stderr before the login lookup of a GitHub Enterprise host. `ST1` stops a
  `--pr-diff` read with `TERM` and requires both temporary files of `_zensu_vcs_stream` gone.
  `HS10`-`HS16` drive `--post-comment` and both `--fetch-review` reads, and `HS17` and `HS18`
  require that `--post-comment` and `--post-review` refuse an empty payload file with a reason
  and post nothing. `NR1`-`NR3` in `test-vcs-publish.sh` hold the
  review normalizer to the requested review id and count each comment once across pages, and
  `GD1`-`GD4` and `GB1`-`GB4` in `test-vcs-pr-ops.sh` drive the GitLab arms with a fake glab: the
  diff rebuilt from two pages of `/diffs`, a listing refused for a missing or unsafe path, a
  non-boolean flag or a diff that is not text, a file GitLab withheld as too large or collapsed,
  and the description sent verbatim in one JSON `PUT`; `PD1` and `PD2` require that `--pr-diff`
  names its refusal of an unknown provider and of a GitLab call without `--repo-id`. `SK1` in
  `test-vcs-pr-ops.sh` fails on a `gh api` call or any `gh pr` subcommand spelled in
  `skills/pr-team-review`, `skills/autopilot`, `skills/cover`, `skills/pr-fix-findings` or
  `skills/pilot`, except the one line of `skills/autopilot/SKILL.md` that names the
  `gh pr create` that `--open-pr` runs; `SK1d` requires that exemption to match exactly one line,
  and `SK1b` and `SK1c` bite the scan on a planted `gh pr diff` and `gh pr list`. `EX1`-`EX2b`
  require that a child shell sees every function the export line names, the new verbs included. Every fake gh of those suites starts with the
  header of `tests/structure/lib-gh-host-fake.sh`, which selects the host as
  `tests/structure/fixtures/gh-api-stub.js` does (`--hostname`, else `GH_HOST`, else
  github.com, with the host of a `-R HOST/OWNER/REPO`, else of a three-part `GH_REPO`, first for
  `gh pr`),
  answers `gh config get user -h` from `FAKE_GH_LOGINS` (exit 0 with an empty answer for a host
  in `FAKE_GH_EMPTY_LOGINS`), appends the host and the names of the non-empty token variables
  of each call to `FAKE_GH_ENV_LOG`, and refuses any host other than `FAKE_GH_PR_HOST`
  (github.com by default) with `error connecting to <host>`. The dry argv checks name the pin
  as well.
- Known gaps: `--detect` classifies the host as the remote spells it: it translates no SSH
  alias, keeps letter case and a leading `www.`, and does not map `ssh.github.com`, so its
  `edition` and `apiBase` can name an alias the verbs translate, and with `--provider github`
  it reports the enterprise edition for a remote spelled `GitHub.com` or `www.github.com`, or
  an SSH remote on `ssh.github.com`, each of which the verbs pin to github.com, and it reads
  no remote when the branch tracks none and no `origin` exists, where the verbs fall back to
  remotes that agree; one normalization shared by `--detect` and the verbs is the standing
  fix. The walk does not stop at a file system boundary, where git stops unless
  `GIT_DISCOVERY_ACROSS_FILESYSTEM` is set, so a directory on another file system below a work
  tree, where git finds no repository, reads as inside one, and the verb refuses. `SK1` is a
  text scan of five skills: it does not see a call spelled another way, such as through a
  variable that holds `gh`, and `skills/session-trail/SKILL.md` and its copy in
  `plugins/session-hub/` still tell the reader to run `gh pr view <number>` by hand for a pull
  request's state; the companion plugin ships no driver, so that read needs a fix of its own in
  both copies. A verb takes no `--repo DIR`, so a caller outside the pull request's work tree has only
  `ZENSU_VCS_REMOTE`. The host carries no port, as `apiBase` carries none, so a GitHub
  Enterprise server that answers only on a non-default HTTPS port is not reached; `ssh -G`
  evaluates the user's ssh configuration, `Match exec` included, as gh does; and an alias
  whose ssh configuration `ssh -G` cannot read, such as one a `GIT_SSH_COMMAND` or
  `core.sshCommand` supplies, keeps its own name, which must then pass the host-name rule and
  hold a gh login.

### Step 3 — Config schema (extends `autopilot.yaml` `vcs:` node)

```yaml
vcs:
  provider: auto        # auto | github | gitlab
  apiBase: auto         # auto | https://gitlab.example.com/api/v4  (overrides probe for self-hosted)
  prBase: auto          # auto (the remote's default branch, else main) | <branch>
  remote: origin        # which remote detection reads
  commitStyle: auto     # auto | conventional | <a description of the style>
  attribution: auto     # auto | none | <the exact trailer line to add>
  language: auto        # auto | <language of commit and PR prose>
  prTemplate: auto      # auto | none | <path of the template to use as the PR body skeleton>
  worktreeOnly: true    # false lets autopilot build in the session's clean checkout
```

`auto` runs the ladder; explicit values short-circuit it (and let CI pin the
forge without a probe). For the convention keys, `auto` means "follow what
`--conventions` reports for this repository"; the precedence and every value are
specified in `skills/autopilot/rules/conventions.md`.

### Step 4 — Wire the three skills to the driver

- **`pr-team-review`** — replace the hard-coded `gh` scout/publish/cleanup with
  driver ops. The persona casting, debate, and synthesis phases are untouched.
  Publish degrades per §7. The detached-worktree flow uses `fetch_pr_ref`.
- **`pr-fix-findings`** — replace thread fetch + resolve with `fetch_threads` /
  `reply_and_resolve`. Triage/fix/push logic unchanged.
- **`autopilot`** — its PR-open + pre-push state-guard use `open_pr` / `pr_state`.
  It already contemplates `provider: github | gitlab` in `rules/config.md`.

### Step 5 — Tests (`tests/structure/`)

- `test-vcs-detect.sh` — table of mock remotes → expected `provider/edition`
  (ssh+https forms, `gitlab.com`, `github.com`, enterprise host with mocked
  probe, unknown host → ask path). No live network — probe is stubbed.
- `test-vcs-reconcile.sh` — the needed-vs-available matrix, incl. the hard-error
  mismatch.
- Extend the marker/structure guards so a skill can't call `gh`/`glab` directly
  outside the driver.
- `tests/integration/gitlab/` — the live tier. The structure suites above replace glab
  with a fake that encodes our model of glab and GitLab; the live suite drives the GitLab
  verbs with the real glab builds pinned in `versions.v1.json` against a disposable GitLab
  CE pinned by digest, and asserts what GitLab stored. `.github/workflows/gitlab-live.yml`
  runs it for pull requests that touch the driver and nightly, and both release stages run
  it as a gate. CI runs pinned builds only: a nightly drift check reads the release metadata
  of newer glab and GitLab releases without running them and files their pin lines in an
  issue. `tests/README.md` §"Live GitLab suite" holds the operator account.

### Implementation status

- **Phase 1 — DONE** (PR #158): `hooks/lib/zensu-vcs.sh --detect` + `test-vcs-detect.sh` / `test-vcs-reconcile.sh`.
- **Phase 2 — DONE**: mechanical PR ops on the helper + `pr-fix-findings` wired to them.
  - Subcommands: `--pr-state <id>` → `OPEN|MERGED|CLOSED`; `--locate-pr [<num>]` →
    `{id,url,state,base,head}`; `--fetch-threads <id>` → normalized unresolved-thread
    array; `--resolve-thread <id> <threadId> [<replyTo>] [--reply <text>]`.
  - Each op = an argv-builder (dry-printable via `ZENSU_VCS_PRINT_ARGV=1` under
    `ZENSU_VCS_TEST=1`) + a thin runner + a `node` normalizer. A GitHub builder first derives
    the pinned host (Step 2, "The GitHub host"): it reads the git remote, runs `ssh -G` for an
    SSH remote and `gh config get user -h` for a host other than github.com and the `GH_HOST`
    host, and prints no argv and exits 1 when it refuses the host. Live `gh` execution is
    untested; glab runs live against a disposable GitLab (Step 5). The hermetic seam is the
    argv-builder + normalizer, same stance as the Phase-1 probe; a hermetic GitHub dry run sets
    `ZENSU_VCS_REMOTE` to an HTTPS github.com remote, which runs neither ssh nor gh. Test:
    `test-vcs-pr-ops.sh`, `tests/integration/gitlab/test-vcs-gitlab-live.sh`.
  - **Normalized thread shape**: `{threadId, replyTo, path, line, body, author}`.
    `threadId` is the **resolve** handle (GitHub GraphQL thread id / GitLab discussion
    id); `replyTo` is the **reply** target (GitHub REST comment id / the same GitLab
    discussion id). Surfacing both is what bridges the resolve-handle asymmetry.
  - Ops require an explicit `--provider` (fail-loud, no silent auto-detect) and
    `--repo-id` in **API-path form** (`owner/repo` for GitHub, url-encoded
    `ns%2Fproj` for GitLab, as `--detect` emits `repo`). `id` is validated numeric,
    `threadId`/`replyTo` against a safe charset; string GraphQL vars use `gh -f`
    (raw, no `@`-file magic). GitHub `reviewThreads` is read 100 threads a page through
    `gh api graphql --paginate --slurp` on `after:$endCursor` until `hasNextPage` is false, and
    a broken or truncated page sequence fails closed (A6f-A6h and N13b in `test-vcs-pr-ops.sh`);
    GitLab discussions use `--paginate`.
- **Phase 3 — DONE**: team-review publish ops on the helper + `pr-team-review` wired to them.
  - Subcommands: `--scout-pr [<num>]` → normalized
    `{id,url,state,title,body,base,head,author,labels}`; `--fetch-pr-ref <id>` → the git
    refspec (`pull/<n>/head` / `merge-requests/<iid>/head`); `--diff-refs <id>` →
    `{base_sha,start_sha,head_sha}` (GitLab live `diff_refs`; GitHub `headRefOid` only);
    `--post-review <id> <payload>` (optional `--diff-refs-json`).
  - **GitHub publish** is one atomic
    `gh api -X POST …/pulls/<n>/reviews --input <payload> --hostname <host>`, the pre-driver
    call plus the host pin. **GitLab publish** degrades per §7 to a LOOP: one
    summary note + N inline discussions, each carrying a `position` object resolved against the
    MR diff before the first write (`base_sha`/`start_sha`/`head_sha`, `old_path` and `new_path`,
    `new_line` for an added line, `old_line` for a removed one, both for an unchanged context
    line; an anchor the diff does not contain posts as a positionless discussion) and a
    `<!-- zensu:pr<iid>:<hash> -->` idempotency marker so a re-run after a
    partial failure skips already-posted threads. The re-run reads the markers from the parsed
    bodies of the merge request's notes and discussions, never from raw response text: GitLab's
    JSON escapes their angle brackets. It counts a marker only where it opens a non-system note
    of the publishing account (`glab api user`): another account's comment, a system note or a
    marker quoted inside a note cannot suppress a part, while a note of the publishing account
    that opens with a copied marker still does. The verdict rides in the summary-note text;
    the driver NEVER calls `glab mr approve`/`merge` (§9.3). Dry mode
    (`ZENSU_VCS_PRINT_ARGV=1`) prints the ordered argv sequence (note first, then each
    discussion) — the same hermetic seam as Phases 1-2, with the same `ZENSU_VCS_REMOTE`
    for the GitHub argv. Live `gh` execution is untested; glab
    runs live against a disposable GitLab (Step 5).
    Test: `test-vcs-publish.sh`, `tests/integration/gitlab/test-vcs-gitlab-live.sh`.
  - `pr-team-review`: Step 0 resolves the driver; Phase A.1 detects the forge (repo-scoped) +
    scouts + fetches the PR/MR ref through the driver (the file list for casting stays the
    forge-agnostic worktree diff — not a forge API); Phase D publishes via `--post-review`, or via
    `--reconcile-review` when Autopilot delegates the review.
    Publish rules split into `rules/github-publish.md` (atomic) + `rules/gitlab-publish.md`
    (loop). Known limit (follow-up): multi-line range comments collapse to a single-line GitLab
    position.
  - **Delegated publish** (PR #175): `--reconcile-review --provider <p> --repo-id R --expected-head <sha>
    [--diff-refs-json J] <id> <payload> <operation-key>` (or `--operation-key K`) → one JSON line
    `{status, marker, headSha, partCount, postedCount, url, provider}`. The payload has the
    `--post-review` shape and at most 8 MiB, and is copied once into a snapshot that every later read
    checks by digest. Every part carries
    `<!-- zensu-review:v1:<sha256(operation key)>:<payload digest>:<head>:<N>:part=<i>/<N> -->`, which
    binds it to the operation key, the canonical payload digest, the expected head and the part count
    `N`: 1 on GitHub, the summary note plus one discussion per comment on GitLab. The PR/MR must be
    open at the expected head before every write and once more at the end. The verb reads every page
    of the PR's reviews or the MR's notes and discussions and posts only the parts no record carries
    yet: `present` means nothing was posted, `posted` that every part was, and `reconciled` that a
    partial GitLab review was completed; after a write it reads the inventory again and requires every
    part. A duplicate or malformed marker, or a marker of this operation with another payload, head or
    part count, fails closed before the first write. On GitLab a record that carries this operation's
    marker must also be a note of the publishing account (`glab api user`) with the planned body, note
    kind and position; without `--diff-refs-json` the verb tries up to five times, a second apart,
    until the MR reports complete diff refs. `pr-team-review` calls it only for a review Autopilot
    delegates, with the durable operation key and the bound head
    (`skills/pr-team-review/references/publish.md`); a standalone run keeps `--post-review`. Test:
    `test-vcs-review-marker-reconcile.sh` (M0-M25, I1-I15, G1-G19, L1-L24),
    `test-autopilot-full-cycle.sh`, `tests/integration/gitlab/test-vcs-gitlab-live.sh` (GL40-GL49).
- **Phase 4 — DONE**: `autopilot` wired to the driver for the PR-open + pre-push guard.
  - New subcommand: `--open-pr --provider <p> --base <b> --head <h> --title <t> --body-file <f>` →
    GitHub `gh pr create --title --body-file --base --head`; GitLab
    `glab mr create --title --description --source-branch --target-branch --yes`. GitHub body BY
    FILE (`--body-file`); GitLab body inlined by value (`--description`), title by value on both.
    Returns the PR/MR URL — normalizer prefers the `.../pull|merge_requests/<n>` URL, falls back to the
    first http URL, and strips control/ANSI bytes. Failure is propagated (non-zero rc + stderr; not
    swallowed). It infers the repo from **cwd** (caller `cd "$REPO"`) — no `--repo-id`, matching
    `scout_pr`/`pr_state`. Dry-printable (`ZENSU_VCS_PRINT_ARGV=1`); live `gh` execution untested
    (hermetic argv seam, same stance as Phases 1-3), while glab `--open-pr` runs live (Step 5). `--pr-state` (Phase 2) is REUSED for the pre-push
    guard — no new state op. Test: `test-vcs-pr-ops.sh` (open-pr assertions O1-O8),
    `tests/integration/gitlab/test-vcs-gitlab-live.sh` (GL60, GL61).
  - `autopilot`: Step 0 resolves the driver; Phase 0.A.1 detects the forge (carries
    `PROVIDER`/`REPOID`/`CLIREADY`, `cliReady=false` stop, `unknown` ask); Phase 1 step 3 opens the
    PR/MR via `--open-pr` (run from `$REPO`); the Critical-Conventions pre-push guard uses `--pr-state`.
    Pins: `test-autopilot-skill.sh` (P11a-h). Never auto-merge/approve preserved.
- **Phase 5 — DONE**: repository conventions and `pilot` wired to the driver.
  - `--conventions [--repo DIR] [--provider P] [--template PATH]` → one JSON line from
    `hooks/lib/repo-conventions-v1.js`: `provider`, `prTemplate` (the template the forge pre-fills:
    GitHub's `pull_request_template.md|.txt` in `.github/`, the root, then `docs/`, any letter case;
    GitLab's `.gitlab/merge_request_templates/Default.md`), `prTemplates` (every template found,
    `PULL_REQUEST_TEMPLATE/` directories included), `commitlint` (config files, and `package.json`
    when it carries a `commitlint` key), `ref` and `defaultBranch` (the remote's default branch the
    sample was read from, else `HEAD`), `subjects` (the 20 newest non-merge subjects),
    `conventionalShare`, `trailers` (how many of those commits carry `Co-authored-by`,
    `Signed-off-by`, `Assisted-by`), and the `contributing`, `agents` and `claude` paths. Only files
    git tracks and that are regular files reached through no symlink count. `--template` checks a
    configured template the same way, and also that its path is relative to the top level, holds
    only letters, digits, `.`, `_`, `-` and `/`, and names a `.md` or `.txt` file of at most 64 KiB;
    `prTemplate` then names it, else it is `null` and `prTemplateRefused` says why (the forge's
    template takes the same checks without `--template`). `overrides` lists the
    `.zensu/templates/*.md` files that are plain files of at most 64 KiB, tracked or not. The skills
    read a PR template or an override only from these fields (`skills/autopilot/rules/conventions.md`
    §4), so a symlinked or untracked template is never read into a PR body through them. No
    language heuristic: the model judges language and attribution from these data.
    A default branch or remote whose name holds anything but letters, digits, `.`, `_`, `-` and `/`,
    or a segment starting with `-`, reads as unknown (`defaultBranch` `null`, the sample from
    `HEAD`), and such a template name is left out of `prTemplates`, because the skills retype these
    values into shell commands. `defaultBranch` is the clone's own `refs/remotes/<remote>/HEAD`,
    which a rename on the forge leaves stale, so the skills confirm it with `git ls-remote` before
    they use it (`skills/autopilot/rules/conventions.md` §5).
    Without `--provider` the verb runs the `--detect` ladder first. Tests: the unit file
    `tests/structure/repo-conventions-v1.test.js`, driven by `test-vcs-detect.sh` (C1-C8).
  - `--review-summary --provider <p> [--repo-id R] <id>` → `{reviewed, approved, changesRequested}`.
    GitHub reads `reviewDecision` and `latestReviews`, pinned with `-R <host>/<repo-id>` to the
    repository a given `--repo-id` names on the host of the remote, as `--fetch-threads` pins it;
    GitLab reads the approvals endpoint and the
    MR's `detailed_merge_status`, and requires `--repo-id`. GitLab's `approved` is true on Enterprise
    Edition when no approval rule applies even with nobody approving, so `approved` also needs a
    non-empty `approved_by`. The GitLab answer is a mapping, not a 1:1 equivalent of `reviewDecision`:
    a review that only left discussions reads as not reviewed (its threads still count through
    `--fetch-threads`). Dry-printable; tests R1-R17 in `test-vcs-pr-ops.sh` and GL69, GL70 in
    `tests/integration/gitlab/test-vcs-gitlab-live.sh`.
  - `--locate-pr` without a number exits **3** when the forge CLI reports that the current branch has
    no PR/MR (`no pull requests found for branch` from `gh`, `no open merge request available for`
    from `glab`, both matched without regard to case because glab 1.113 and 1.122 capitalize the
    message), so "no PR yet" is told apart from an error; every other failure exits 1 with the
    forge CLI's message on stderr. Existing callers treat any status other than 0 as "not located".
    Tests L1-L6 in `test-vcs-pr-ops.sh` and GL55 in
    `tests/integration/gitlab/test-vcs-gitlab-live.sh`.
  - `--review-markers --provider <p> --repo-id R <id>` (PR #428) → the distinct first-part markers
    `<!-- zensu-review:v1:…:part=1/<N> -->` in the body fields of the PR's reviews (GitHub GraphQL,
    every page) or of the MR's notes and discussions (GitLab), one per line, and nothing when there
    is none. A failed or unparseable listing exits 1 and names the failure on stderr. `pilot` reads
    review presence from it, and a work-order run's review import uses it to recognize a review an
    earlier attempt published (`skills/work/references/protocol.md`). Tests N12-N14c and LV28 in
    `test-vcs-publish.sh`, GL56 and GL57 in `tests/integration/gitlab/test-vcs-gitlab-live.sh`.
    Known gap (follow-up): no fake-backed check drives the GitHub listing.
  - `pilot`: detection, PR lookup, review state, thread count and PR creation go through
    `--detect`, `--locate-pr`, `--review-summary`, `--review-markers`, `--fetch-threads` and
    `--open-pr`.
- **Phase 6 — DONE**: the skills' own GitHub calls behind pinned driver verbs.
  - `--pr-diff --provider <p> [--repo-id R] <id>`, `--edit-pr-body --provider <p> [--repo-id R]
    --body-file <f> <id>`, `--post-comment --provider github --repo-id R <id> <payload>` and
    `--fetch-review --provider github --repo-id R <id> <review-id>` give the skills a pinned verb
    for every GitHub call they used to run themselves. `--pr-diff` prints the diff `gh pr diff`
    serves and nothing when gh fails, and names its refusal of an unknown provider; on GitLab it
    rebuilds the unified diff from every page of `/diffs`, requires `--repo-id`, and fails closed
    on a file GitLab withheld as too large or collapsed and on an entry it cannot render.
    `--edit-pr-body` refuses an empty or missing body file with a reason before any gh or glab
    call and prints the PR/MR URL; on GitLab it requires `--repo-id` and sends
    `{"description": …}` in one JSON `PUT` on stdin. `--post-comment` and `--fetch-review` are
    GitHub-only and refuse `--provider gitlab` with a message that says why; `--post-comment`
    and `--post-review` refuse an empty payload file with a reason, so a failed payload build
    posts nothing; `--fetch-review` prints `{id,state,author,submittedAt,url,comments}`,
    `comments` counting the review's inline comments over every page. `skills/pr-team-review`
    runs them for the GitHub anchor-validation diff read (on GitLab the driver's own anchor
    preflight decides), the body-only and per-comment fallbacks, which build each request from
    the validated payload file so no path or body reaches a command line, the verification read
    and the PR-state check; `skills/autopilot/rules/pr-open.md` §4 refreshes the body with
    `--edit-pr-body`; `skills/cover` step 0.B reads a pull request's diff with the repo-context
    form on GitHub, which leaves the base repository to gh as before, and with `--repo-id` on
    GitLab. Tests: `D1`-`D4i`, `E1`-`E4h`, `HP21`-`HP30c`, `EB1`, `ST1`, `PD1`, `PD2`, `GD1`-`GD4`,
    `GB1`-`GB5`, `SK1`-`SK1d` and `EX1`-`EX2b` in `test-vcs-pr-ops.sh`; `A18`-`A19c`, `G17`-`G18f`,
    `HS10`-`HS18` and `NR1`-`NR3` in `test-vcs-publish.sh`; `GL58`-`GL59b`, `GL73` and `GL74` in
    `tests/integration/gitlab/test-vcs-gitlab-live.sh`.

---

## 7. The one real mismatch: publishing a review

GitHub has an atomic **review object** (`pulls/:n/reviews`): one call carries the
summary body + `event` (APPROVE/REQUEST_CHANGES/COMMENT) + all inline `comments[]`.

GitLab has **no batch review** — the model maps to:

1. One **summary note**: `POST …/merge_requests/:iid/notes` (the overall body).
2. N **inline discussions**: `POST …/merge_requests/:iid/discussions` with a
   `position` object requiring the diff refs
   (`base_sha` / `start_sha` / `head_sha`) fetched from
   `GET …/merge_requests/:iid/versions` (or the MR's `diff_refs`).
3. Verdict maps: REQUEST_CHANGES → summary note text + (optionally) block via a
   required-thread convention; APPROVE → `POST …/merge_requests/:iid/approve`.

Consequences to spec explicitly:

- **Not transactional** — GitLab publish is a loop; a partial failure can leave
  some discussions posted. → **Idempotency:** prefix each posted body with a
  hidden marker (`<!-- zensu:pr<iid>:<hash> -->`); on re-run, skip a discussion
  whose marker already opens a non-system note of the publishing account (Phase 3).
  Same marker convention GitHub inline uses today.
- **`glab` gap** — `glab` has no first-class inline-discussion create; use its
  `glab api` passthrough with the JSON request on stdin and an explicit content type
  (`glab api --method POST projects/:id/merge_requests/:iid/discussions --header 'Content-Type: application/json' --input -`).
  glab up to 1.122 sends an `--input` body without any Content-Type, which GitLab rejects
  with HTTP 415, and glab 1.123 and later refuse bracketed field names such as
  `-f 'position[base_sha]=…'` in a JSON body, so every GitLab JSON body write goes through
  `_zensu_vcs_gitlab_send_json`, which alone spells that argv: the POSTs through
  `_zensu_vcs_gitlab_post_json`, and the description `PUT` of `--edit-pr-body` directly
  (`GB5` counts the spelling).
- **`iid` not `number`**, and project id = **URL-encoded** `namespace/project`.

> **Decision — GitLab "approve" semantics.** Default: post the review as
> notes/discussions and set the verdict in the summary body only; do **not**
> auto-call `/approve` or `/merge`. *Alternative:* map APPROVE → `glab mr approve`.
> **Default chosen** — matches the plugin's "never auto-merge/approve" stance
> (autopilot §2, pr-team-review is advisory). Approving is a human action.

---

## 8. Credential-blind (unchanged principle)

`gh` holds the GitHub token; `glab` holds the GitLab token. The driver **never
reads or prints a token**. The auth surface is the `*.auth status` check, the
"run `<cli> auth login`" recovery hint and, for the GitHub verbs, one per-host login
lookup (§6 Step 2, "The GitHub host"): `gh config get user -h <host>` reads gh's
configuration, and the driver only checks that the account name it prints is not empty
and then discards it. For a host accepted on that lookup alone the driver runs gh with
the four GitHub token variables set to the empty string; it clears them and never reads
them. Dropping Bitbucket is what preserves this cleanly — no raw `*_TOKEN` env ever
touches the model's shell.

## 9. Resolved decisions

1. **Spec location** — stays in `docs/vcs-driver-spec.md` (tracked, English),
   committed alongside the feature branch.
2. **Self-hosted GitLab base URL** — **detected by probe** (the
   `/api/v4/version` scan, §6 step 1). `vcs.apiBase` remains an *optional*
   explicit override for locked-down CI, but is never required.
3. **GitLab approve mapping** — **notes/discussions only, never `/approve` or
   `/merge`** (§7). Approving stays a human action.
4. **Rollout order** — the detection helper + its tests land first (zero
   behavior change), then skills are wired one at a time:
   `pr-fix-findings` → `pr-team-review` → `autopilot`.

## 10. Non-goals restated

No Bitbucket. No token handling. No change to review *content* logic. No
auto-install. No auto-approve/merge.
