---
name: pr-fix-findings
description: >
  [Zensu] Fix every open review comment / finding on a GitHub or GitLab pull/merge request end-to-end:
  locate the PR for the current branch (or a given URL/number), pull the unresolved
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

- `$ARGUMENTS` (optional): a PR/MR URL or number to target. Omitted → the PR for the current
  branch. Delegated mode requires the full durable PR/MR URL and parses its final number.

## Invocation modes and delegated envelope

Standalone mode keeps the interactive parallelism policy above, limited to
read-only analysis, and the ordinary next-step offer below. Delegated mode is
activated by any delegated-envelope header and requires
exactly these three contiguous lines with no intervening or additional delegated headers,
in this order and exactly once:

```text
ZENSU-DELEGATED-CALLER: autopilot
AUTOPILOT-BINDING: run=<runId> attempt=<attempt> chain=<chainId>
AUTOPILOT-STAGE: <outer-stage>
```

Require caller `autopilot`, `<outer-stage>` equal to `FIX_FINDINGS`, a positive integer
attempt, and valid durable run/chain identifiers. A partial, duplicate, malformed, or conflicting envelope is a hard error before any edit, TDD invocation, push, or forge
mutation. A non-contiguous or extended envelope fails the same way. Never reinterpret it as a standalone request, and never accept or synthesize an
`AUTOPILOT-REVIEW-OP` line for this skill.

Resolve `LOG="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh"` and set
`CURRENT_SESSION="$(CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "$LOG" --session-key)"`.
The helper must validate the immutable private Session Control binding. Read fresh
state with `CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "$LOG" --autopilot-status`. Fail closed unless `ownerSessionId` equals `CURRENT_SESSION`;
`tdd.sessionId` equals that same current session; `runId`, `tdd.attempt`, and `tdd.chainId`
equal the binding; `stage` equals both the
envelope and `FIX_FINDINGS`; and `evidence.pr.number`, `evidence.pr.url`, and
`evidence.pr.headSha` exactly identify the invoked PR and its bound head. Also require
`effects.prOpen.status == "completed"`, `effects.teamReview.status == "completed"`, and
`evidence.review.published == true` with a valid durable review marker. The review evidence
remains bound to the original reviewed head after later `PR_HEAD_UPDATED` events; do not
incorrectly require its head to equal the current fix head.

For every delegated remote guard, combine `--pr-state` with `--diff-refs`: require state is `OPEN`, the located URL/number still match `evidence.pr`, and the remote head equals `evidence.pr.headSha`. Perform this guard immediately before every remote mutation and
immediately before every push. A moved head, closed/merged PR, malformed response, or CLI
failure blocks the outer run; never ask a mid-run question or write against a successor
generation.

Every delegated provider, authentication, authorization, pagination, gate, or product
decision failure must persist `BLOCK` with a stable generation-specific event id, report
the blocker, and stop without a question. Use the closed codes `fix-provider-unknown`,
`fix-auth-unavailable`, `fix-pagination-unsafe`, `fix-gate-failed`, and
`fix-decision-required`. Standalone mode retains the explicitly labeled prompts below.

### Delegated fixing path

1. Use the driver's complete paginated thread fetch. GitHub GraphQL must exhaust
   `pageInfo.endCursor`; GitLab must consume all `--paginate --output json` pages. Treat a
   non-zero command, invalid normalized JSON, duplicate/conflicting thread identity, or
   missing/incomplete page as unsafe and fail closed on pagination. Never treat a partial
   result as an empty worklist.
2. Build one aggregate specification containing every unresolved actionable thread with
   its stable thread id, location, required behavior, and verification. If a product choice
   is genuinely required, persist `BLOCK` and report it; do not ask. If the worklist is
   empty, re-fetch once authoritatively and record `FINDINGS_CLEARED` only when it remains
   empty.
3. For a non-empty list, persist one `FIX_REQUIRED` event with the bound head and complete
   unresolved count. Then execute one aggregate bound `/zensu:tdd` fix run serially in the main task, passing `AUTOPILOT-RUN: <runId>`. Use no parallel editing agents or editing worktrees. The bound TDD chain and its self-review must finish before any landing step.
4. Run every configured gate. Commit locally, run the OPEN/current-head guard immediately
   before push, then push once. Read back the new remote head and persist the exact
   `PR_HEAD_UPDATED` transition before resolving threads; stale/unchanged heads fail closed.
5. For each addressed thread, repeat the OPEN/current-head guard immediately before the
   reply/resolve mutation. Finally perform another complete paginated thread fetch. Record
   `FINDINGS_CLEARED` only for authoritative count zero; otherwise repeat the entire
   aggregate bound loop for the remaining set.

This delegated path supersedes the standalone analysis-parallelism clauses in Procedure steps 3–4.
All other safety and reporting rules still apply.

## Procedure

0. **Detect the forge (GitHub or GitLab).** Resolve the driver once:
   `ROOT="${CLAUDE_PLUGIN_ROOT}"` — if this is empty or
   `$ROOT/hooks/lib/zensu-vcs.sh` is missing, **ABORT** with a FATAL message and
   start a fresh Claude Code session. Then `VCS="$ROOT/hooks/lib/zensu-vcs.sh"`,
   require `[ -f "$VCS" ]`, run `bash "$VCS" --detect`, and
   read `provider` + `cliReady` + `repo` from the `key=value` output.
   - `cliReady=false` → in standalone mode stop and ask the user to install/authenticate
     the detected forge CLI (GitHub: `gh auth login`; GitLab: `glab auth login`, installing
     `glab` first if missing). In delegated mode persist `BLOCK(fix-auth-unavailable)`,
     report it, and stop without asking. Do **not** fall back to the other forge.
   - `provider=unknown` → in standalone mode ask the user which forge / remote to target;
     in delegated mode persist `BLOCK(fix-provider-unknown)`, report it, and stop without
     asking.
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

3. **Triage for analysis parallelism (standalone only).**
   - Group items by independence. Neutral workers may inspect disjoint
     files/concerns in parallel and return read-only analysis packets: root cause,
     affected files, proposed tests, and constraints.
   - Workers MUST NOT edit, run `/zensu:tdd`, open workflow windows, commit, push,
     or resolve threads. Reconcile all packets in the interactive main thread;
     overlapping or ordered items are analyzed and implemented sequentially there.

4. **Implement each fix in the interactive main thread via the Zensu workflow (standalone only).**
   - Code changes go through the Zensu vanilla workflow (`/zensu:tdd`) in this
     top-level thread so the evidence audit + review chain run under `main-v1`.
     Use any worker packets only as read-only input; never delegate implementation
     or `/zensu:tdd` to a neutral child.
   - After edits: run the relevant type-check / tests. Fix what you broke.

5. **Land the changes.**
   - Re-verify the PR/MR is still OPEN
     (`bash "$VCS" --pr-state --provider <provider> <id>` → `OPEN`) before pushing. In
     delegated mode also re-read `--diff-refs` and require its head SHA to equal the fresh
     durable PR head.
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

In standalone mode only, stop early and ask the user when you hit a fix that needs a product/architecture decision, an auth error (`zensu auth login`), or a failing gate you
cannot satisfy. In delegated mode, persist `BLOCK` with the appropriate code and report the
blocker without asking a mid-run question.

## Next step

When invoked standalone — not delegated by `/zensu:autopilot` or `/zensu:pilot`
— offer, once every thread is resolved and only after the user confirms, to
harden the change with `/zensu:cover`, or `/zensu:pilot` to re-probe the
feature and continue toward the release gate.
