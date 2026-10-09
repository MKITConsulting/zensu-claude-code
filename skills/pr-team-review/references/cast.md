# Phase A.2: persona cast and the private read lease

Read this when the Phase A.1 evidence packet is complete. Once the cast is final, build the
large-PR shards and `_leased-files.txt` as `references/scout.md` describes. This phase ends with
the lease registered, before `references/spawn.md` spawns any reviewer.

**A.2 Persona-Cast:**

Read `rules/reviewer-personas.md` for the 25-persona pool with trigger signals. Judge the diff against each persona's trigger criterion and select the personas whose criterion it meets — the file types, paths and annotations a trigger names are examples, not a closed list, so a stack or layout no example mentions still qualifies (`docs-only` is the one deliberately closed trigger). **The always-on holistic core — `coverage-audit`, `bug-hunter`, `maintainability`, `adversarial` — is cast on every code PR** (not trigger-gated), so no code PR is reviewed by specialist lenses alone; docs-only PRs stay lean (`docs-only` + `coverage-audit`).

**Repo-custom seats (discovery).** The pool is not the whole cast: a repo can define its own reviewer seats using the SAME `.claude/agents/zensu-review-*.md` convention `/zensu:tdd` consumes (see `rules/reviewer-personas.md` § Repo-custom seats). Unless `--no-custom-roles` was passed, pipe the worktree's changed paths into the activation matcher **on the main thread**:

```bash
# TRUST GUARD: discover from the BASE checkout ($REPO), NEVER $WORKTREE (the PR head).
# A PR must not inject its own reviewer seats — mirrors the overlay rule in Step 0.
git -C "$WORKTREE" diff origin/<base>...HEAD --name-only \
  | node "$ROOT/hooks/lib/persona-activation.js" "$REPO/.claude/agents"
```

Each `spawn <name>` line is a castable repo-custom seat; join it to the cast marked `(repo-custom)` with its reason (the matched activation glob, or `always-join` for a seat with no `activation:` field). Log every other verdict humanized — `PERSONA SKIPPED — <name> (no activation match | malformed)`, `PERSONA DROPPED — <name> (over cap)` — never silently omit one. If the helper itself fails (node missing, non-zero exit), log `PERSONA DISCOVERY UNAVAILABLE — <reason>` and continue with the pool only. Custom seats are capped at 5 (the helper's cap), count toward `ROLE_COUNT`, and each spawns as a confined `zensu:pr-review-worker` with the custom persona's concern injected as its focus (Phase B) — never as its own `subagent_type`.

In standalone mode, present the cast to the user before spawning; in delegated mode, log the same cast as a progress update and continue without a question:

```
Cast for PR #<n> (<X> files, <Y>+/<Z>-):
  coverage-audit  — ALWAYS (holistic core): test-coverage evaluation, uncovered files/paths
  bug-hunter      — ALWAYS (holistic core): functional-correctness pass
  maintainability — ALWAYS (holistic core): design + complexity pass
  adversarial     — ALWAYS (holistic core): anti-groupthink, feeds the Challenge Round
  ddd-tactical    — Aggregate classes + invariant docs in src/main/.../domain/
  backend-idiom   — 87 *.java files, Spring annotations detected
  persistence-db  — 6 Flyway migrations in db/migration/
  security        — Auth config + new endpoints
  rest-api        — Controller files + OpenAPI annotations
  tests-qa        — Test files present (97 @Test)
  zensu-review-fee-calc — (repo-custom) via .claude/agents/zensu-review-fee-calc.md (activation **/fee/** matched)
```

Standalone only: ask via `AskUserQuestion`: "Cast OK? [Go / Reduce / Expand / Custom]". On `Custom` → user gives comma list; the always-on holistic core (`coverage-audit`, `bug-hunter`, `maintainability`, `adversarial`) stays in regardless (re-add any the user's custom list omits — for a docs-only PR only `coverage-audit` applies). If `--roles=` arg was provided → still append the holistic core if the user left it out. Repo-custom seats (from `.claude/agents/zensu-review-*.md`) are valid ids in the `Custom` list and in `--roles=`; an explicitly named custom id is force-cast (it bypasses its activation gate), so an explicit override is never dropped by a non-matching glob. Delegated mode never calls `AskUserQuestion` here.

Before Phase B, set `PERSONA_RULES` to the fully expanded concrete path formed from the validated `ROOT`, count the final roles as `ROLE_COUNT`, and register one private read lease. Do not register a lease when `REUSE_DURABLE_PAYLOAD=true`:

```bash
CLAUDE_PLUGIN_DATA="<absolute-plugin-data>" CLAUDE_CODE_SESSION_ID="${CLAUDE_CODE_SESSION_ID}" \
  bash "$ROOT/hooks/lib/zensu-review-evidence.sh" create \
  --kind pr-review \
  --files-manifest "$WORKDIR/_leased-files.txt" \
  --safe-subtrees-manifest "$WORKDIR/_safe-subtrees.txt" \
  --name-status-file "$WORKDIR/_name-status.txt" \
  --changed-production-files-file "$WORKDIR/_changed-production-files.txt" \
  --max-workers "$ROLE_COUNT" --ttl-seconds 3600
```

Capture the single `lease_id=...` line. The helper validates the native host session, requires the `mktemp -d` workspace to remain current-user-owned mode `0700`, canonicalizes and hashes every exact file/root into private plugin data, and rejects aliases, broad/unsafe roots, duplicate active leases, malformed manifests, or a changed-production path outside `_name-status.txt`. `zensu-host-path.sh` must render the workspace into native host spelling before any manifest, evidence file, worktree path, or reviewer prompt is written; never put a Git-Bash-only `/tmp/...` path into those artifacts. Never expose the lease id or plugin-data path to a reviewer. If registration fails, stop before spawning and clean up the worktree. Always close the lease after collection and on every error path.
