# zensu-claude-code Repo Conventions

## Language

**English only.** All code, comments, docs, commit messages, plan files,
prompts, fixture content, and pattern alternations must be in English.

Historical `.zensu/plans/*.md` and `.zensu/logs/*.log` files from prior rounds
may contain German — they are immutable audit trail and exempt from this rule.

Future rounds (round-14 onward) must produce English-only output.

## Version Bumps

**Every plugin version bump MUST update both `.claude-plugin/plugin.json` AND `.claude-plugin/marketplace.json` in the same commit.**

The two files serve different consumers:

- `.claude-plugin/plugin.json` — manifest read by claude-code when loading the installed plugin. Defines runtime agents/skills/hooks/mcpServers.
- `.claude-plugin/marketplace.json` — advertisement read by `claude plugin marketplace update <name>` to discover which version the directory-source plugin offers. If this lags behind `plugin.json`, claude-code keeps installed plugins pinned at the older cached version and `claude plugin install <name>@<name>` reports "already installed" even after the manifest bumps.

Historical: `marketplace.json` was created at `0.2.0` (commit `a0a58b2`) and never re-bumped while `plugin.json` advanced through 0.2.x → 0.3.x. Result: every release between 0.2.0 and 0.3.15 was invisible to the directory marketplace and users running `claude plugin install zensu@zensu` could not pull the new code without uninstalling + manually clearing the cache directory. Fixed in PR #31; this convention prevents recurrence.

**Release commit checklist:**

1. `.claude-plugin/plugin.json` — `"version": "X.Y.Z"`
2. `.claude-plugin/marketplace.json` — `plugins[0].version: "X.Y.Z"` (same value)
3. `CHANGELOG.md` — new `## [X.Y.Z] - YYYY-MM-DD` section, move applicable Unreleased entries down
4. Commit subject: `chore(release): bump version to X.Y.Z`

If `marketplace.json` cannot be bumped in the same commit (e.g. forgotten and the release already shipped), open a follow-up PR titled `chore(marketplace): bump marketplace.json to X.Y.Z` and merge it before any user-side `claude plugin install <name>@<name>` attempt.

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
