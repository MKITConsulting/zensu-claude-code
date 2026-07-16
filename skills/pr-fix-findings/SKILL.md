---
name: pr-fix-findings
description: >
  [Zensu] Fix every open review comment / finding on a GitHub or GitLab pull/merge request end-to-end:
  locate the PR for the current branch (or a given number), pull the unresolved
  review threads, triage them into independent vs dependent work, use neutral
  workers only for parallel read-only analysis, implement every fix in the
  interactive main thread through the Zensu workflow (vanilla `/zensu:tdd` + review chain), push, resolve
  the corresponding threads on the PR, and report a summary back. Use whenever the
  user wants to address, fix, or resolve PR review feedback / review comments /
  reviewer findings, "work through the review", "fix the review notes", "resolve
  the review threads", or the slash command /zensu:pr-fix-findings. Built to run
  standalone or repeatedly under /loop until no unresolved threads remain.
---

# /zensu:pr-fix-findings

Resolve **every open review comment** on a pull/merge request: analyze independent
findings in parallel when useful, implement every fix in the main thread through
the Zensu workflow, push, resolve the threads
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

0. **Detect the forge (GitHub or GitLab).** Resolve the driver once with the
   fail-closed guard
   `ROOT="${ZENSU_CLAUDE_PLUGIN_ROOT:?FATAL: plugin root unavailable; start a fresh Claude Code session}"`,
   set `VCS="$ROOT/hooks/lib/zensu-vcs.sh"`, require `[ -f "$VCS" ]`, then run
   `bash "$VCS" --detect`, and
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

3. **Triage for analysis parallelism.**
   - Group items by independence. Neutral workers may inspect disjoint
     files/concerns in parallel and return read-only analysis packets: root cause,
     affected files, proposed tests, and constraints.
   - Workers MUST NOT edit, run `/zensu:tdd`, open workflow windows, commit, push,
     or resolve threads. Reconcile all packets in the interactive main thread;
     overlapping or ordered items are analyzed and implemented sequentially there.

4. **Implement each fix in the interactive main thread via the Zensu workflow.**
   - Code changes go through the Zensu vanilla workflow (`/zensu:tdd`) in this
     top-level thread so the evidence audit + review chain run under `main-v1`.
     Use any worker packets only as read-only input; never delegate implementation
     or `/zensu:tdd` to a neutral child.
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
