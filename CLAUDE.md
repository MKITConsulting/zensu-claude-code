# zensu-claude-code Repo Conventions

## Language

**English only.** All code, comments, docs, commit messages, plan files,
prompts, fixture content, and pattern alternations must be in English.

Runtime `.zensu/plans/*.md` and `.zensu/logs/*.log` are local-only artifacts
(gitignored, never committed) — not part of the repository and exempt from this
rule. Every tracked file must be English-only.

**Carve-out — verbatim user-utterance match literals.** Hook directive strings
— and verbatim citations of those literals in structure-test pins, in
README/CHANGELOG feature descriptions, and in this carve-out — may contain
non-English phrases ONLY as match literals for real user input:
the TDD preference fast-paths (e.g. `'kein tdd'`, `'mit tdd'`, `'tdd bitte'`)
and the generic-action literals that are explicitly NOT a preference
(e.g. `'mach mal'`, `'los gehts'`, `'jetzt umsetzen'`) in
`plan-approved-delegate.sh` / `user-prompt-tdd-reminder.sh`. They exist to
recognize what multilingual users actually type, never as prose. Keep these
phrase lists in lockstep across every directive variant (strict and vanilla)
— never edit one variant alone.

## Version Bumps

**Every plugin version bump MUST update both `.claude-plugin/plugin.json` AND `.claude-plugin/marketplace.json` in the same commit.**

The two files serve different consumers:

- `.claude-plugin/plugin.json` — manifest read by claude-code when loading the installed plugin. Defines runtime agents/skills/hooks/mcpServers.
- `.claude-plugin/marketplace.json` — advertisement read by `claude plugin marketplace update <name>` to discover which version the directory-source plugin offers. If this lags behind `plugin.json`, claude-code keeps installed plugins pinned at the older cached version and `claude plugin install <name>@<name>` reports "already installed" even after the manifest bumps.

Historical: `marketplace.json` was created at `0.2.0` (commit `a0a58b2`) and never re-bumped while `plugin.json` advanced through 0.2.x → 0.3.x. Result: every release between 0.2.0 and 0.3.15 was invisible to the directory marketplace and users running `claude plugin install zensu@zensu` could not pull the new code without uninstalling + manually clearing the cache directory. Fixed in PR #31; this convention prevents recurrence.

**Releasing — automated via the `Release` workflow** (`.github/workflows/release.yml`):

1. Actions → **Release** → run with a `version_type` (`patch`/`minor`/`major`). The `prepare` job runs the deterministic test gate, computes the next version from the latest `vX.Y.Z` tag, bumps `plugin.json` + `marketplace.json` + the README badge **together** to the same value, generates a `## [X.Y.Z]` CHANGELOG section from the conventional commits since the last tag (git-cliff, `cliff.toml`), **pushes a `release/vX.Y.Z` branch**, and prints a "Compare & PR" link in the run summary. (Run with `dry_run: true` to preview the version + notes without pushing a branch.)
2. Open the PR from that link, then review + **squash-merge** it. (CI pushes the branch but does not open the PR — the org caps the workflow token for PR creation; release/tag creation only needs the per-job `contents: write`, which works.)
3. The `publish` job fires on the release commit landing on `main`, tags `main` HEAD and creates a **published** GitHub Release (notes = the new CHANGELOG section, source zip attached). Plugin **go-live is the merge itself** — the marketplace is the repo (`"source": "./"`), so users install from `main` HEAD; the tag/Release are the record, published atomically with the merge (Claude Code's plugin install ignores tags/Releases). Users pull it via `claude plugin marketplace update zensu`. The release notes were already reviewed in the bump PR body, so there is no separate draft-publish step.

The same-value invariant above is machine-enforced: the gate runs `tests/run-all.sh` (incl. the version-sync tests) before the branch is pushed. For a manual hotfix bump, follow the invariant by hand — `plugin.json` + `marketplace.json` + README badge (same value) + a new `## [X.Y.Z] - YYYY-MM-DD` CHANGELOG section + commit subject `chore(release): bump version to X.Y.Z`.

If `marketplace.json` ever lags `plugin.json` (e.g. a hand bump that forgot it), open a follow-up PR titled `chore(marketplace): bump marketplace.json to X.Y.Z` and merge it before any user-side `claude plugin install <name>@<name>` attempt.

## MCP Tool Classification (`hooks/lib/zensu-mcp-tools.sh`)

**When the Zensu MCP server gains a new tool, classify it in `hooks/lib/zensu-mcp-tools.sh` in the same change** — a state-mutating tool goes in `ZENSU_MUTATION_TOOL_NAMES`; a read/telemetry tool goes in the `zensu_is_read_tool` allowlist (`ZENSU_READ_TOOL_PREFIXES` / `ZENSU_READ_TOOL_NAMES`).

This file is the single source of truth for tool classification, consumed by two places:

- `hooks/pre-mcp-zensu-gate.sh` — the PreToolUse write-gate: allows `zensu_is_read_tool` tools ungated and default-denies everything else.
- `tests/structure/test-skill-workflow-markers.sh` — the build-time guard that fails if a skill calls a `zensu_is_mutation_tool` without the `--workflow-begin` / `--workflow-end` markers.

Consequences of forgetting a new tool:

- **New mutation tool, not added to `ZENSU_MUTATION_TOOL_NAMES`:** no security hole — the gate default-denies anything not on the read-allowlist, so it is still gated at runtime. But the skill-marker test will NOT flag a skill that calls it without the workflow markers, so a wrapper-less skill could slip through CI. **Test-coverage gap, not an open gate.**
- **New read tool, not added to the read-allowlist:** fail-closed — it is gated by default and wrongly DENIED on the main thread until added.

Invariant: `ZENSU_MUTATION_TOOL_NAMES` must stay a strict superset of every skill's `--workflow-begin --tools` declaration (a skill may only declare real mutation tools). `tests/structure/test-skill-workflow-markers.sh` pins the read/mutation classification of a representative sample.

## Pull Request Workflow

**Never commit or push to a closed or merged PR's branch.** Once a PR is merged or closed, its branch is dead — additional commits there belong on a new branch with a new PR.

**Re-check immediately before EVERY push, not once per session.** A PR can flip from OPEN to MERGED between two of your commands (the user, a teammate, or an auto-merge can land it). Treat each push as a fresh interaction:

```bash
gh pr view <num> --json state,mergedAt
```

If `state` is `MERGED` or `CLOSED`, **abort the push**:

1. `git fetch origin main`
2. Create a new branch off `origin/main`
3. Cherry-pick or re-author the change onto the new branch
4. Push the new branch and open a new PR

A `gh pr list --head <branch>` check is not sufficient — it does not distinguish OPEN from MERGED/CLOSED. Read the `state` field explicitly.

This applies to AI agents and humans alike. The `/create-pr` slash command's "PR already exists for this branch" guard does NOT cover the merged-branch case. "I just rebased ten minutes ago" is not a substitute for the check — re-run it every push.
