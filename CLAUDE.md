# zensu-claude-code Repo Conventions

## Language

**English only.** All code, comments, docs, commit messages, plan files,
prompts, fixture content, and pattern alternations must be in English.

Historical `.zensu/plans/*.md` and `.zensu/logs/*.log` files from prior rounds
may contain German — they are immutable audit trail and exempt from this rule.

Future rounds (round-14 onward) must produce English-only output.

## Pull Request Workflow

**Never commit or push to a closed or merged PR's branch.** Once a PR is merged or closed, its branch is dead — additional commits there belong on a new branch with a new PR.

Before pushing any follow-up to an existing branch, verify the PR is still OPEN:

```bash
gh pr view <num> --json state,mergedAt
```

If `state` is `MERGED` or `CLOSED`:

1. `git fetch origin main`
2. Create a new branch off `origin/main`
3. Cherry-pick or re-author the change
4. Push the new branch and open a new PR

A `gh pr list --head <branch>` check is not sufficient — it does not distinguish OPEN from MERGED/CLOSED. Read the `state` field explicitly.

This applies to AI agents and humans alike. The `/create-pr` slash command's "PR already exists for this branch" guard does NOT cover the merged-branch case.
