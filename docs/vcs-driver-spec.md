# Spec: VCS Driver (GitHub + GitLab)

Status: **draft — not built.** Spec-first. Nothing is implemented until this is approved.

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

> **Decision — helper scope.** Default: the helper owns the **mechanical**
> ops (detect, pr-state, fetch-threads, resolve-thread, fetch-pr-ref) as thin
> subcommands so logic lives in ONE file with no cross-skill doc drift. The
> **publish** op (needs the synthesized review payload) stays in-skill, branching
> on `provider` per recipes in §7. *Alternative:* full driver-as-CLI including
> publish. **Default chosen** — publish payload is skill-specific and large;
> keeping it in-skill avoids marshalling it through argv.

### Step 2 — Driver operation set (the interface both forges satisfy)

| Op | Consumed by | GitHub | GitLab |
|----|-------------|--------|--------|
| `detect` | all | remote+probe | remote+probe |
| `locate_pr(branch\|num)` | fix, autopilot | `gh pr view` | `glab mr view --output json` |
| `pr_state(id)` | all (pre-push guard) | `gh pr view <n> --json state,mergedAt` | `glab mr view <iid> --output json` → `.state` |
| `fetch_pr_ref(id)` | team-review | `git fetch origin pull/<n>/head` | `git fetch origin merge-requests/<iid>/head` |
| `open_pr(title,body,base,head)` | autopilot | `gh pr create` | `glab mr create` |
| `fetch_threads(id)` | fix | GraphQL `reviewThreads` | REST `GET …/merge_requests/:iid/discussions` (keep `resolvable && !resolved`) |
| `fetch_inline_comments(id)` | fix | `gh api …/pulls/<n>/comments --paginate` | discussions (same call as above) |
| `post_review(id, payload)` | team-review | 1× `gh api -X POST …/pulls/<n>/reviews --input` | 1× summary note + N× inline discussions (see §7) |
| `reply_and_resolve(thread,body)` | fix | reply comment + GraphQL `resolveReviewThread` | `POST …/discussions/:id/notes` + `PUT …/discussions/:id?resolved=true` |

### Step 3 — Config schema (extends `autopilot.yaml` `vcs:` node)

```yaml
vcs:
  provider: auto        # auto | github | gitlab
  apiBase: auto         # auto | https://gitlab.example.com/api/v4  (overrides probe for self-hosted)
  prBase: main
  remote: origin        # which remote detection reads
```

`auto` runs the ladder; explicit values short-circuit it (and let CI pin the
forge without a probe).

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
  whose marker already exists. Same marker convention GitHub inline uses today.
- **`glab` gap** — `glab` has no first-class inline-discussion create; use its
  `glab api` passthrough (`glab api --method POST projects/:id/merge_requests/:iid/discussions -f …`).
- **`iid` not `number`**, and project id = **URL-encoded** `namespace/project`.

> **Decision — GitLab "approve" semantics.** Default: post the review as
> notes/discussions and set the verdict in the summary body only; do **not**
> auto-call `/approve` or `/merge`. *Alternative:* map APPROVE → `glab mr approve`.
> **Default chosen** — matches the plugin's "never auto-merge/approve" stance
> (autopilot §2, pr-team-review is advisory). Approving is a human action.

---

## 8. Credential-blind (unchanged principle)

`gh` holds the GitHub token; `glab` holds the GitLab token. The driver **never
reads or prints a token**. The only auth surface is the `*.auth status` check and
the "run `<cli> auth login`" recovery hint. Dropping Bitbucket is what preserves
this cleanly — no raw `*_TOKEN` env ever touches the model's shell.

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
