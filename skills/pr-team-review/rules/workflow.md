# Workflow Details + Pitfalls

Companion to `SKILL.md`. Read on demand when a phase needs depth.

## Worktree-Isolation (critical safety property)

The skill MUST NOT switch branches in the main working tree. The user is typically working on a feature branch with uncommitted changes — a stray `git checkout pr-<n>-review` would clobber that. Worktree-isolation prevents this.

**Pattern:**

```bash
REPO=<absolute-path-to-repo-root>

# Per-run root with an UNPREDICTABLE name (mktemp -d) — never a fixed /tmp path.
# A predictable world-writable name invites a symlink / pre-creation race.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/pr<n>-review.XXXXXXXX")"
WORKTREE="$WORKDIR/wt"

# Create worktree — separate physical checkout, shared .git. DETACHED at the
# fetched SHA so a re-run's fresh worktree never collides on the branch ref.
git -C "$REPO" fetch origin pull/<n>/head:pr-<n>-review
git -C "$REPO" worktree add --force --detach "$WORKTREE" "$(git -C "$REPO" rev-parse pr-<n>-review)"
```

After `worktree add`:
- `git -C "$REPO" branch --show-current` still reports the user's WIP branch — the main checkout is untouched.
- the worktree is in DETACHED HEAD at the PR head SHA; `git -C "$WORKTREE" rev-parse HEAD` echoes that SHA.
- Both share `.git` — disk overhead is roughly the working-tree size, not double the repo.

**Reviewer prompts MUST inject `$WORKTREE`** as the working directory for all git/grep/file operations. See Phase B Spawn Pitfalls.

**Locating `$REPO`:** if the current CWD is the right repo for `<owner>/<repo>`, use that. Otherwise search `~/IdeaProjects/<repo>`, `~/code/<repo>`, `~/work/<repo>` — if none match, ask the user via `AskUserQuestion`. Never invent paths.

**Disk-space caveat:** worktree duplicates the working files (not `.git`). For repos > 1 GB warn the user before `worktree add`. `du -sh "$REPO" --exclude=.git` gives a quick estimate.

**Cleanup belongs in Phase E:** `git -C "$REPO" worktree remove --force "$WORKTREE"`. Without this, stale worktrees pile up under `/tmp/`. On crash, the user can run `git -C "$REPO" worktree prune` to clean up the bookkeeping.

## Phase A.1 — Scout Pitfalls

- **`git fetch origin pull/<n>/head:pr-<n>-review` fails with "couldn't find remote ref"**: PR is from a fork. Use `gh pr checkout <n>` inside the worktree — but that command checks out into the *current* CWD, so first `cd "$WORKTREE"` then run it. Never run `gh pr checkout` from `$REPO` root.
- **Head SHA changes between scout and publish**: Re-fetch SHA right before the publish step. The reviews API rejects stale SHAs with HTTP 422.
- **Wrong base branch**: PR JSON `baseRefName` is authoritative. Don't assume `main`/`dev` — read it.
- **Huge PR (> 200 files)**: Cap `--stat` output, use `git diff --name-only` for routing only. Don't dump full diff into agent prompts.
- **`$REPO` is not a git repo**: `git -C "$REPO" rev-parse --is-inside-work-tree` fails. Stop and ask the user for the right repo-root path.

## Phase A.2 — Persona-Cast Heuristics

Trigger detection runs against `git diff origin/<base>...pr-<n>-review --name-only`. Cast scoring:

| Signal type | Weight |
|---|---|
| Every PR (unconditional) | Forces `coverage-audit` — the always-on test-coverage evaluation |
| File-extension match | Activates persona |
| Path-prefix match (e.g. `docs/DDD/`) | Activates persona |
| Migration directory present | Forces `persistence-db` |
| New endpoint files | Forces `security` + `rest-api` |
| `--context=` flag | Forces `domain-refiner` |
| `--conversation=` mentions naming/glossary | Forces `ddd-strategic` |

Cast size sanity check: 2-8 reviewers ideal. < 2 → ask user if more breadth wanted. > 8 → ask user to trim.

For docs-only PRs (only `*.md` changes), skip multi-cast — go straight to `docs-only` single reviewer **plus `coverage-audit`** (which reports `N/A — no production code changed`) + simplified synthesis that still carries the mandatory `### Test Coverage` section.

## Coverage Evaluation (always-on)

The `coverage-audit` persona is cast on every run and its `### Test Coverage` section is mandatory (see Phase D). Operational notes:

- **Static-first is the default.** Without `--run-coverage`, do NOT build or run the suite — map changed production files to tests by name/import/symbol reference, and cross any *already-present* coverage report against the diff. This keeps the skill inside its 3-7 min read-only budget.
- **"Production file" = changed, non-test, executable source.** Exclude test files, fixtures, generated code, lockfiles, and pure docs/config from the uncovered inventory (a changed `*.md` or `*.lock` is not "uncovered code"). When in doubt, list it under `partial_files`/notes rather than as a hard `uncovered_files` entry.
- **Existing report, not a fresh run.** Step 2 reads an artifact that already exists in the checkout (CI left a `jacoco.xml`, a `coverage/lcov.info`, etc.). Finding none is normal — fall back to static, say so in `coverage_source`. Never trigger a build to *produce* one unless `--run-coverage` was passed.
- **`--run-coverage` is slow + fragile.** Reuse the `/zensu:tdd` Phase 1.5 detection (config files first). On any failure (missing tool, build break, wrong command) fall back to static and record the reason — a failed coverage run must never abort the review.
- **Honesty over precision.** Static mapping is an approximation; label it as such. A file with no matching test is `uncovered`; a file whose new public method has no test is a `partial` with that method under `uncovered_paths`.
- **Fallback if the agent dies.** If `coverage-audit.json` is missing/broken at Phase C, synthesize a minimal report from the diff (changed non-test files → `uncovered`, `coverage_source: "static (fallback)"`) so the section still renders. The guarantee is the section's presence, not the agent's liveness.

## Phase B — Spawn Pitfalls

- **Inject `$WORKTREE` into every reviewer prompt** — explicit instruction: "use `$WORKTREE` as CWD for git/grep/file reads; never `cd` into the main repo at `$REPO`". Without this, agents default to running git commands wherever and can clobber the user's branch (see Worktree-Isolation section above).
- **Parallel spawn matters**: ALL `Agent` calls in ONE message. Serial spawning wastes wall-clock time (each reviewer takes 1-2 min — parallel completes in 2 min, serial in 16 min).
- **Always `run_in_background: true`**: otherwise the main thread blocks on the first reviewer.
- **Always pass `team_name` + `name`**: required for `SendMessage` and `TaskUpdate` ownership.
- **Inject ALL context in the prompt**: the agent starts fresh with no history. Include PR metadata, head SHA, base ref, `$WORKTREE` path, `--context` paths verbatim, `--conversation` text.
- **Reference the persona template in the prompt**: don't inline the full template — the agent can `Read` `${CLAUDE_PLUGIN_ROOT}/skills/pr-team-review/rules/reviewer-personas.md` if it needs the schema.

## Phase C — Debate Strategy

**Why lead-consolidated, not DM-roundtrip:** spawning a second round (each agent reviewing the others' reports) doubles wall-clock time without doubling signal. The lead has full read access to all reports and can identify convergence/conflicts directly. Use DM-roundtrip only when:

- Reviewers explicitly contradict on a major decision (e.g., one says APPROVE, three say REQUEST_CHANGES).
- Naming/architecture decision requires multi-stakeholder buy-in beyond what the lead can adjudicate.

**Schema normalization:** reviewers may write slightly different schemas — handle defensively:

```bash
# Inspect actual keys
for f in $WORKDIR/*.json; do echo "=== $f ==="; jq 'keys' "$f" 2>&1 | head -5; done
```

Common variations:
- `findings` vs `inline_findings`
- `verdict` vs `verdict_hint`
- `severity: P1/P2/P3` vs `HIGH/MEDIUM/LOW` vs `blocker/major/minor`

Normalize during read, not before — keep the raw files for debug.

**Broken JSON:** if `jq` errors on a file, use `Read` to inspect and parse the structure manually. Common cause: agent embedded a code block containing `{` that breaks naive JSON parsers (rare with modern agents but possible).

**Convergence map:** when N agents flag the same line, that's high-signal. Merge into one inline comment citing all sources ("Convergence: backend-idiom, rest-api, tests-qa all flagged this — ..."). Increases the comment's authority + reduces duplicate noise on the PR.

## Phase D — Synthesis + Publish

**Test Coverage section (mandatory, never dropped):**

Render `### Test Coverage` in the overall body on EVERY run from `consensus.coverage` (the `coverage-audit` report carried through Phase C). Rules:
- Lead with `coverage_source` + a one-line summary so the reader knows whether the numbers are static, from an ingested report, or from a real tool run.
- List every `uncovered_files[]` entry (path — reason — risk). If empty: "None — every changed production file is exercised by a test." If `changed_production_files == 0`: "N/A — no production code changed in this PR."
- List `partial_files[]` uncovered paths under "Uncovered paths". If empty: "None."
- The section is present even when the verdict is APPROVE and even for docs-only PRs. A green coverage result is still reported explicitly — silence is not allowed.
- `--coverage-gate`: if set and `uncovered_files[]` (production) is non-empty, the verdict is `REQUEST_CHANGES` and the Recommendation cites the uncovered files. Without the flag, coverage is advisory and the verdict is unaffected.

**Inline-comment cap (`--max-inline`):**

Default 25. Strategy when consolidated findings exceed cap:
1. Always include all P1 findings.
2. Fill remaining slots with P2 findings, sorted by convergence (multi-agent first).
3. Drop P3 findings into the overall body as a "P3 Nits" bulleted list — no inline comment for those.
4. If still over cap → keep only the most actionable P2s; mention skipped P2s in overall body.

**Overall body length:** target 600-1200 words. Reviewer fatigue is real — a 5000-word body gets skimmed. Cut Strengths section to 5-7 bullets max. Cut Open Questions to 5 max.

**No tables.** GitHub PR view squeezes Markdown tables into narrow columns that wrap character-by-character — unreadable. Use numbered subsections (`#### 1. ...`) for P1 findings and bullet lists with bold prefixes (`- **Area**: ...`) for P2 / Strengths / Open Questions. Lead is responsible for the synthesis Markdown — persona reports may still use tables internally (they live in `$WORKDIR/<role>.json` and are not posted), but the synthesis MUST flatten everything to prose/bullets/headings.

**No tables in inline comments either.** Inline comments suffer the same column compression. Use code fences, bullet lists, bold prefixes only.

**Pre-publish preview:** ALWAYS show the user the overall body + inline count before posting. They may want edits. After approval, post — don't wait for explicit "go" if the user already approved the skill execution.

## Phase E — Cleanup

- Send `shutdown_request` to each teammate via `SendMessage` (response auto-terminates them).
- Don't delete `$WORKDIR/` — it's a debug artifact. macOS clears `/tmp` on reboot.
- Mark all task statuses as `completed`.
- Final message to user: review URL + one-sentence summary of verdict.

## Failure Modes

- **`gh api` POST 422 line out-of-diff**: drop the offending comment, retry POST with reduced `comments[]` array.
- **`gh api` POST 401**: tell user to `gh auth refresh`.
- **Reviewer agent dies mid-run**: TaskList shows in_progress; respawn that single agent (same name, same prompt).
- **All reviewers report APPROVE**: still post the review with `event=COMMENT` summarising strengths — user values the audit trail.
- **PR closed/merged while review runs**: detect via `gh pr view --json state`; abort gracefully, save artifacts.
- **Worktree / branch-checkout collisions** (path already exists, branch already checked out, orphaned dir): no longer occur — each run gets a fresh `mktemp -d` workspace and the worktree is DETACHED at the head SHA (it never checks out the `pr-<n>-review` branch). After a crash the worktree just lingers under its random `$WORKDIR`; `git -C "$REPO" worktree prune` clears the stale bookkeeping and the next run is unaffected.
- **Disk full while creating worktree**: detect via `df -h /tmp`; warn user and offer `--worktree-path=<custom>` (later enhancement) or proceed without worktree (degraded: read diff via `gh pr diff` only, no file-level reads).

## Performance

Typical end-to-end timing (8-reviewer cast on 100-file PR):

| Phase | Wall clock |
|---|---|
| A.1 Scout | 10-20 s |
| A.2 Persona-Cast + user confirm | 30-60 s (user-dependent) |
| B Spawn | < 5 s |
| Reviewer parallel run | 1-3 min |
| C Debate | 30-60 s (lead reads + writes) |
| D Synthesis | 30-90 s |
| D Publish | 5-10 s |
| **Total** | **3-7 min** |

Serial spawn would be 8-24 min — always parallel.
