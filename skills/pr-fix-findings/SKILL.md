---
name: pr-fix-findings
description: >
  [Zensu] Fix every open review comment / finding on a GitHub or GitLab pull/merge request end-to-end:
  locate the PR for the current branch (or a given number), pull the unresolved
  review threads, triage them into independent vs dependent work, implement each
  fix through the Zensu workflow (vanilla `/zensu:tdd` + review chain), fan
  independent fixes out across parallel workflows where sensible, push, resolve
  the corresponding threads on the PR, and report a summary back. Use whenever the
  user wants to address, fix, or resolve PR review feedback / review comments /
  reviewer findings, "work through the review", "fix the review notes", "resolve
  the review threads", or the slash command /zensu:pr-fix-findings. Built to run
  standalone or repeatedly under /loop until no unresolved threads remain.
---

# /zensu:pr-fix-findings

Resolve **every open review comment** on a pull/merge request: implement each fix
through the Zensu workflow, parallelize independent fixes, push, resolve the threads
on the PR/MR, and report back. Works on **GitHub or GitLab** — the forge is detected
via the VCS driver (`hooks/lib/zensu-vcs.sh`) and every git-host call goes through it.

## When to Use

- A PR has review comments / change requests you want addressed in one pass.
- You want unattended, iterative cleanup of review feedback under `/loop`.
- Reviewer left inline findings across several files and the fixes are mostly independent.

Not for: authoring a new review (use `/zensu:pr-team-review`), or planning unbuilt
work (use `/zensu:bootstrap`).

## Prerequisites

- The detected forge's CLI authenticated — `gh` (GitHub) or `glab` (GitLab). The
  driver's `--detect` reports `cliReady`; install the missing one if needed
  (e.g. `brew install glab`).
- Zensu CLI installed and authenticated (`zensu auth status`; `zensu auth login` if needed).
- The current branch has an open PR, or a PR number is supplied as an argument.

## Arguments

- `$ARGUMENTS` (optional): a PR number to target. Omitted → the PR for the current branch.

## Procedure

0. **Detect the forge (GitHub or GitLab).** Resolve the driver once:
   `ROOT="${ZENSU_CLAUDE_PLUGIN_ROOT:-}"` and verify
   `[ -n "$ROOT" ] && [ -f "$ROOT/hooks/lib/zensu-log.sh" ]` — otherwise **ABORT**
   with a FATAL message and start a fresh Claude Code session. Then
   `VCS="$ROOT/hooks/lib/zensu-vcs.sh"`, run `bash "$VCS" --detect`, and
   read `provider` + `cliReady` + `repo` from the `key=value` output.
   - `cliReady=false` → **STOP**: the detected forge's CLI is not ready. Tell the user
     to install/authenticate it — GitHub: `gh auth login`; GitLab: `glab auth login`
     (install `glab` first if missing, e.g. `brew install glab`). Do **not** fall back
     to the other forge.
   - `provider=unknown` → ask the user which forge / remote to target.
   - Otherwise carry `provider` and `repo` forward; pass `--provider <provider>` and
     `--repo-id <repo>` to every driver op below so detection runs only once.

1. **Locate the PR/MR.**
   - `bash "$VCS" --locate-pr --provider <provider> [$ARGUMENTS]` → JSON
     `{id,url,state,base,head}` (omit the argument to use the current branch's PR/MR).
   - If none exists or `state != OPEN`: stop and report. Never push to a closed/merged PR/MR.

2. **Collect unresolved feedback.**
   - `bash "$VCS" --fetch-threads --provider <provider> --repo-id <repo> <id>` → a
     normalized JSON array of UNRESOLVED threads
     `[{threadId, replyTo, path, line, body, author}]`. GitHub review threads and GitLab
     discussions map to the same shape, already filtered (`isResolved==false` /
     `resolvable && !resolved`).
   - Build a worklist of actionable items. Skip pure praise, already-addressed, and outdated-and-moot threads.

3. **Triage for parallelism.**
   - Group items by independence. Items touching disjoint files/concerns are
     independent → safe to fix in parallel. Items on the same file/region or with
     ordering dependencies → sequential.
   - When several items are independent, fan them out with the Workflow tool (one
     agent per item or cluster, `isolation: "worktree"` if they edit files
     concurrently). A single small item does not need a workflow — fix it inline.

4. **Implement each fix via the Zensu workflow.**
   - Code changes go through the Zensu vanilla workflow (`/zensu:tdd`) so the
     evidence audit + review chain run. For parallel fan-out, each agent implements
     its item and returns a structured result (files changed, what was fixed,
     residual risk).
   - After edits: run the relevant type-check / tests. Fix what you broke.

5. **Land the changes.**
   - Re-verify the PR/MR is still OPEN
     (`bash "$VCS" --pr-state --provider <provider> <id>` → `OPEN`) before pushing.
   - Commit with a Conventional Commit message referencing the addressed comments,
     push to the PR branch. Clean commit messages — no watermark / co-author lines.

6. **Resolve the threads.**
   - For each addressed thread:
     `bash "$VCS" --resolve-thread --provider <provider> --repo-id <repo> --reply "<one-line note + commit SHA>" <id> <threadId> <replyTo>`
     — this replies to the thread and resolves it (GitHub: reply to the `replyTo`
     comment + resolve the `threadId`; GitLab: the single discussion id serves as both).
   - Leave threads you could NOT resolve open, with a reply explaining why or what
     decision you need.

7. **Report back.**
   - Summary table: comment → action taken → commit → resolved?
   - Call out anything that needs a human decision, anything skipped, and the
     test / type-check results.

## Loop behaviour

When run under `/loop` (self-paced): each iteration re-fetches unresolved threads.

- If **none remain**, report "all review comments resolved" and end the loop.
- Otherwise address the next batch and continue.

Stop early and ask the user when you hit a fix that needs a product/architecture
decision, an auth error (`zensu auth login`), or a failing gate you cannot satisfy.

## Next step

When invoked standalone — not delegated by `/zensu:autopilot` or `/zensu:pilot`
— offer, once every thread is resolved and only after the user confirms, to
harden the change with `/zensu:cover`, or `/zensu:pilot` to re-probe the
feature and continue toward the release gate.
