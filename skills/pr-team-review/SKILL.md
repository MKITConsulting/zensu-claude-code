---
name: pr-team-review
description: >
  Orchestrate a multi-agent PR review on GitHub: scout the PR, auto-cast a tailored
  reviewer team from a 15-persona pool (DDD strategic/tactical, backend, persistence,
  security, REST API, tests, coverage audit, domain refiner, frontend component/UX,
  IaC, CI/CD, performance, docs), ALWAYS run an explicit test-coverage evaluation that
  flags uncovered files and paths, spawn them in parallel, run a debate + synthesis phase,
  and publish one consolidated GitHub review with inline comments + overall body via
  `gh api`. Use whenever the user wants a comprehensive multi-perspective PR review:
  triggers include "team review", "multi-agent PR review", "horde review",
  "agent-team review", "reviewer consensus", "PR debate", "publish team feedback
  to GitHub", a shared GitHub PR URL with the word "review", or the slash command
  /zensu:pr-team-review. Skill drives the workflow end-to-end and posts the result.
---

# /zensu:pr-team-review

Multi-agent PR review orchestrator. Scouts the PR, auto-casts a tailored reviewer team, runs reviews in parallel, debates, synthesises, publishes a single consolidated GitHub review.

## Arguments

Parse from the user prompt. Slash form: `/zensu:pr-team-review <pr-url> [--flag=value ...]`.

| Arg | Required | Default | Notes |
|---|---|---|---|
| `<pr-url>` | yes | — | `https://github.com/<owner>/<repo>/pull/<n>` |
| `--roles=<comma-list>` | no | auto-cast per PR (see `rules/reviewer-personas.md`) | Override the auto-cast |
| `--context=<path>[,<path>...]` | no | none | Extra reference docs (refinement wiki, glossary). Activates `domain-refiner`. |
| `--conversation=<text-or-path>` | no | none | Inline conversation context (naming debate, design decisions, screenshot OCR) |
| `--verdict=<COMMENT\|REQUEST_CHANGES\|APPROVE>` | no | `COMMENT` | Final review event |
| `--max-inline=<n>` | no | 25 | Cap on consolidated inline comments |
| `--run-coverage` | no | off | Opt-in: actually run the repo's coverage tool in the worktree for true line/branch data. Off = static mapping + ingest an existing report only (fast). |
| `--coverage-gate` | no | off | When set, uncovered changed **production** files escalate the final verdict to `REQUEST_CHANGES`. Off = coverage is reported but advisory (verdict unchanged). |

If `<pr-url>` is missing, ask the user via `AskUserQuestion`.

## Workflow

Five phases. Track each as a task with `TaskCreate`/`TaskUpdate`.

### Phase A — Scout + Persona-Cast

**A.1 Scout (read-only) + Worktree Setup:**

```bash
# 1. PR metadata
gh pr view <n> --repo <owner>/<repo> --json title,body,headRefName,baseRefName,files,additions,deletions,author,labels

# 2. Locate repo-root for <owner>/<repo>. If current CWD is not that repo, search
#    standard paths (~/IdeaProjects/<repo>, ~/code/<repo>) or ask user via AskUserQuestion.
REPO=<repo-root-absolute-path>

# 3. Verify it's a git repo
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null || { echo "not a git repo"; exit 1; }

# 4. Per-run workspace with an UNPREDICTABLE name (mktemp -d) — never a fixed
#    /tmp path. A predictable world-writable name invites a symlink / pre-creation
#    race on shared hosts. Artifacts and the worktree both live under here.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/pr<n>-review.XXXXXXXX")"
WORKTREE="$WORKDIR/wt"

# 5. Fetch PR head into a local ref; capture the head SHA (reviews API needs it)
git -C "$REPO" fetch origin pull/<n>/head:pr-<n>-review
SHA=$(git -C "$REPO" rev-parse pr-<n>-review)

# 6. Worktree at the fetched SHA, DETACHED — MAIN CHECKOUT IS NOT TOUCHED, and a
#    detached checkout never collides on the branch ref when the skill re-runs.
git -C "$REPO" worktree add --force --detach "$WORKTREE" "$SHA"

# 7. Persist env for downstream phases (inside the per-run dir)
printf 'REPO=%s\nWORKDIR=%s\nWORKTREE=%s\nSHA=%s\n' "$REPO" "$WORKDIR" "$WORKTREE" "$SHA" > "$WORKDIR/.env"

# 8. Tell the user where everything lives — the mktemp name is random by design
echo "Review workspace (artifacts + worktree): $WORKDIR"

# 9. Diff-stats from the worktree
git -C "$WORKTREE" diff origin/<base>...HEAD --stat | tail -10
```

**Critical:** never run `git checkout pr-<n>-review` in `$REPO`. That would clobber the user's WIP branch. The worktree is a separate physical checkout sharing the same `.git` — `git -C "$REPO" branch --show-current` continues to show the user's branch after worktree add.

For PRs > 50 files: launch 1-2 `Explore` subagents in parallel for deep diff inspection per main area (point them at `$WORKTREE` for file reads). Keep their reports under 400 words.

**A.2 Persona-Cast:**

Read `rules/reviewer-personas.md` for the 15-persona pool with trigger signals. Based on the diff file types + paths, select the personas whose trigger signals match. **`coverage-audit` is ALWAYS in the cast** — it is not trigger-gated; include it in every cast (docs-only included) so the guaranteed test-coverage evaluation always runs. Always present the cast to the user before spawning:

```
Cast for PR #<n> (<X> files, <Y>+/<Z>-):
  coverage-audit  — ALWAYS: test-coverage evaluation, uncovered files/paths
  ddd-tactical    — Aggregate classes + invariant docs in src/main/.../domain/
  backend-idiom   — 87 *.java files, Spring annotations detected
  persistence-db  — 6 Flyway migrations in db/migration/
  security        — Auth config + new endpoints
  rest-api        — Controller files + OpenAPI annotations
  tests-qa        — Test files present (97 @Test)
```

Ask via `AskUserQuestion`: "Cast OK? [Go / Reduce / Expand / Custom]". On `Custom` → user gives comma list; `coverage-audit` stays in regardless (re-add it if the user's custom list omits it). If `--roles=` arg was provided → still append `coverage-audit` if the user left it out.

### Phase B — Team Setup + Reviewer Spawn

```
TeamCreate team_name="pr<n>-review" description="<short>"
TaskCreate one per role + one each for Debate, Synthesis, Publish
```

Spawn all reviewers in a **single message** with multiple `Agent` tool uses (parallel):

- `subagent_type: general-purpose`
- `team_name: pr<n>-review`
- `name: <role-id>`
- `run_in_background: true`
- Prompt: derived from `rules/reviewer-personas.md` template for that role + injected context block (PR metadata, head SHA, base, `--context` paths, `--conversation` text, **`WORKTREE=<absolute-path>` for all git/grep/file reads, plus the output path `<WORKDIR>/<role>.json`**)

Every reviewer prompt MUST contain the explicit `WORKTREE` instruction:

> **Working directory for all git/grep/find/file reads: `<WORKTREE>`** (separate worktree). Use `git -C <WORKTREE> ...` or `cd <WORKTREE>` at the start of your bash calls. **Never** `cd` into the main repo at `<REPO>` — the user is working there in parallel and any `git checkout` would clobber their branch. Output JSON goes to the absolute path `<WORKDIR>/<role>.json` (outside the worktree). Refinement-context paths from `--context=` stay absolute (not relative to the worktree).

Each reviewer writes structured JSON to `$WORKDIR/<role>.json`. Schema in `rules/reviewer-personas.md` (key fields: `inline_findings[]`, `overall_notes[]`, `verdict_hint`).

Mark reviewer tasks `in_progress` with `owner=<role>`.

### Phase C — Wait + Debate

Background reviewers send idle notifications when done. Do not poll. When all idle:

1. Read every `$WORKDIR/<role>.json` (parallel `Read` calls).
2. Normalize: agents may write slightly different schemas — extract `findings`/`inline_findings` and `verdict`/`verdict_hint` defensively (handle missing keys + broken JSON; if `jq` errors on a file, read raw and parse manually).
3. Write `$WORKDIR/_debate.json` with:
   - `consensus.naming_decision` (if naming was a topic)
   - `consensus.p1_required_changes[]` (deduplicated)
   - `consensus.p2_suggestions[]` (deduplicated, capped at ~20)
   - `consensus.p3_nits[]`
   - `consensus.coverage` — the `coverage_report` from `$WORKDIR/coverage-audit.json` carried through verbatim (`coverage_source`, `summary`, `uncovered_files[]`, `partial_files[]`, `covered_files[]`). This ALWAYS exists — if the coverage-audit agent died or wrote no report, synthesize a minimal one from the diff (list changed non-test files as `uncovered` with `coverage_source: "static (fallback — coverage-audit produced no report)"`) rather than dropping the section.
   - `convergence_map` — which finding appears in multiple agents' reports
   - `consensus.verdict` — lead's recommendation. If `--coverage-gate` was passed AND `consensus.coverage.uncovered_files[]` is non-empty (production files), set the verdict to `REQUEST_CHANGES`.

Lead-driven consolidation, not a DM roundtrip. See `rules/workflow.md` § Debate Strategy.

### Phase D — Synthesis + GitHub Publish

Write `$WORKDIR/_synthesis.json` as the exact `gh api` payload:

```json
{
  "commit_id": "<head-sha>",
  "event": "<verdict>",
  "body": "<markdown overall body>",
  "comments": [
    {"path": "src/...", "line": 42, "side": "RIGHT", "body": "<markdown>"}
  ]
}
```

Overall body structure (Markdown):

```
## Multi-Agent Review — PR #<n> (<title>)

Review by N-agent team (...).

### TL;DR
<2-3 sentence summary>

### Test Coverage   <!-- MANDATORY — always render, from consensus.coverage. Never omit. -->
<coverage_source + one-line summary, e.g. "Static diff-vs-test mapping (no coverage report found). 7 changed production files, 2 uncovered.">

**Uncovered files** (no test exercises them):
- `path/to/File.ext` — <reason> (<P1|P2|P3>)

<!-- if none: "None — every changed production file is exercised by a test." · if no prod code: "N/A — no production code changed in this PR." -->

**Uncovered paths** (in otherwise-tested files):
- `path/to/File.ext`: `functionName`, `<branch/endpoint>`

<!-- if none: "None." -->

### Naming Decision   <!-- only if --conversation or DDD-strategic raised it -->
<consensus>

### Required Changes (P1)

#### 1. <Area> — <short title>
<2-4 sentence explanation>. Source: <persona-ids>.

#### 2. <Area> — <short title>
...

### Suggestions (P2)
- **<Area>**: <issue + fix in one sentence>. Source: <persona-id(s)>.
- ...

### Strengths
- ...

### Open Questions
- ...

### Recommendation
<verdict + rationale>
```

**Mandatory `### Test Coverage` section.** Render it on EVERY run from `consensus.coverage` — a fully-covered PR shows "None" under both lists, a docs-only PR shows "N/A — no production code changed". Never drop it, even when the verdict is APPROVE. When `--coverage-gate` is set and uncovered production files exist, the Recommendation must reflect `REQUEST_CHANGES` and cite the uncovered files. The coverage-audit persona's own inline findings (uncovered high-risk files/paths) flow into the inline comments like any other persona's, subject to `--max-inline`.

**HARD RULE — NO MARKDOWN TABLES** in the overall body or inline comments. GitHub's PR view squeezes wide tables into unreadable narrow columns (text wraps character-by-character). Use:
- numbered subsections (`#### 1. ... #### 2. ...`) for P1 findings
- bullet lists with bold prefixes (`- **Area**: ...`) for P2 / Strengths / Open Questions
- plain prose for everything else

Same rule applies inside inline comments — no tables. Code fences, bullet lists, bold prefixes only.

Inline findings: max `--max-inline` (default 25), sorted by path then line, P1 first. See `rules/github-publish.md` for the `gh api` call, `line`/`side` rules per file `changeType` (ADDED/MODIFIED/RENAMED), and idempotency.

Before posting, show the user the body preview + inline count.

Submit:

```bash
gh api -X POST repos/<owner>/<repo>/pulls/<n>/reviews \
  --input $WORKDIR/_synthesis.json
```

Verify:

```bash
gh api repos/<owner>/<repo>/pulls/<n>/reviews/<id>/comments | jq length
```

Return the review URL (`html_url` from the POST response) to the user.

### Phase E — Cleanup

For each teammate: `SendMessage to=<role> message={"type":"shutdown_request","reason":"review published"}`.

Remove worktree (main checkout untouched):

```bash
git -C "$REPO" worktree remove --force "$WORKTREE"
```

Keep `$WORKDIR/` (JSON artifacts) as a debug record — do not delete.

Ask the user whether to drop the local PR ref:

> Worktree removed. Delete local `pr-<n>-review` ref as well? [y/N]

Default: keep the ref (user can re-inspect or re-run). If `y`: `git -C "$REPO" branch -D pr-<n>-review`.

## Reference Files

- `rules/reviewer-personas.md` — 15-persona pool (incl. the always-on `coverage-audit`), trigger signals, prompt templates, JSON schema
- `rules/workflow.md` — phase-by-phase pitfalls + heuristics
- `rules/github-publish.md` — `gh api` reviews schema, side/line rules, fallbacks

## Critical Conventions

- **Never `git checkout` the PR ref in the main working tree.** Always use a detached worktree under an `mktemp -d` workspace (`git worktree add --force --detach "$WORKTREE" "$SHA"`). Reviewer agents `cd` into the worktree, not the main repo. The main checkout's branch and uncommitted work must stay untouched.
- **Always cast `coverage-audit` and always render the `### Test Coverage` section.** The explicit test-coverage evaluation — uncovered files + uncovered paths — is guaranteed on every run, docs-only included. Coverage is advisory (verdict unchanged) unless `--coverage-gate` is passed, which escalates to `REQUEST_CHANGES` when changed production files are uncovered. Only run the coverage tool when `--run-coverage` is passed; otherwise use static mapping + any existing report.
- Always spawn reviewers in **one** parallel batch (single message, multiple `Agent` calls). Serial spawning wastes wall-clock time.
- Always `run_in_background: true` for reviewers.
- Reviewers write to `$WORKDIR/<role>.json` (absolute path, outside the worktree). Lead reads + consolidates.
- Submit ONE review with bundled inline comments — never N single-comment reviews.
- Default verdict `COMMENT`. Only escalate to `REQUEST_CHANGES`/`APPROVE` if user explicitly asked via `--verdict=`.
- Idempotent: re-running on the same PR posts an additional review (no overwrite). Each run gets a fresh `mktemp -d` workspace + detached worktree, so a re-run never collides with a prior run's worktree or the branch ref.
- If `gh auth status` fails or the user lacks `repo` scope → stop and ask the user to fix auth before doing the review work.
