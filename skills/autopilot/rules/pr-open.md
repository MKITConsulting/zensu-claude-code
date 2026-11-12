# Opening the pull request (Phase 1 step 3)

Step 3 of the skill names this file. It holds the head check before the push, the events of the
open, the path for a PR/MR the run already requested, the body refresh and the bound on returning
to step 2. `$VCS`, `$LOG`, `$PROVIDER`, `$DETECT`, `$REPO` and `$BODY_FILE` are the values the skill
set in Step 0 and step 3.

## 1. The head check before the push

Every head SHA the run persists is the full `git rev-parse HEAD` value, never an abbreviation: the
state machine compares whole strings, so a short SHA never equals the full one. Before the push,
read `--autopilot-status` and compare `git rev-parse HEAD` with `evidence.gates.headSha`, then run
`git -C "$REPO" status --porcelain -- . ':(exclude,glob)**/.zensu/**'`. A different head, or any
line that status prints, is work the gates never tested, so nothing reaches the forge: return to
step 2, which commits, runs the gates on this head and records `GATES_PASSED` or `GATES_FAILED`,
then converges again. The status leaves out `.zensu/`, where the run's own plans, logs and state
change on every step.

## 2. The first open

With `effects.prOpen.status` `none`, persist `PR_OPEN_REQUESTED` with a deterministic operation
key, push, run the driver's `--open-pr`, and after success persist `PR_OPENED` with that same key,
the PR/MR number and URL, and the full current head. A failed open (auth expired, an MR already
exists on the branch, a push race) is a stop-the-world blocker (The one rule): halt and report, and
never run step 4+ against a PR/MR that was not created.

## 3. A PR/MR the run already requested

With `effects.prOpen.status` `requested`, the open may already have happened: a compaction or a
restart came between the driver call and `PR_OPENED`, or the state machine refused `PR_OPENED`.
Persist no new `PR_OPEN_REQUESTED`, which the state machine refuses, and never call `--open-pr`
again, which the forge refuses for a branch that has a PR/MR. Instead:

1. Before any push, find the PR/MR with `bash "$VCS" --locate-pr --provider "$PROVIDER"`, run
   from `$REPO`. It prints `{"id","url","state","base","head"}`, and its `head` is a branch name,
   not a commit. Act on the answer, and push only in the first and the third case:
   - Exit 0, `state` `OPEN` and `head` equal to the feature branch
     (`git -C "$REPO" rev-parse --abbrev-ref HEAD`, the `$HEAD` of step 3): push, then go on.
   - Exit 0 with `state` `MERGED` or `CLOSED`, or with `head` naming another branch: the run
     cannot carry that PR/MR on, and nothing may land on its branch. Persist `BLOCK` with code
     `PR_NOT_OPEN` and halt.
   - Exit 3: the branch has no PR/MR, so the earlier open never happened. Push, call `--open-pr`
     once, and go on as section 2 says after its push, with the recorded `operationKey`.
   - Any other exit: the lookup failed. Persist `BLOCK` with code `PR_LOOKUP_FAILED` and halt.
2. Read the commit the forge holds with `bash "$VCS" --diff-refs --provider "$PROVIDER" <id>`,
   which prints `head_sha`; GitLab also takes `--repo-id` with the `repo=` value of `$DETECT`. A
   non-zero exit is a failed lookup: persist `BLOCK` with code `PR_LOOKUP_FAILED` and halt.
   Compare `head_sha` with `git rev-parse HEAD`, the head section 1 matched with the gate
   evidence. While they differ, read it again, at most three reads in all and a few seconds
   apart, because the forge can lag behind the push. When they still differ, persist `BLOCK` with
   code `PR_HEAD_GATE_MISMATCH` and halt. Never send this mismatch back to step 2, which would
   test the head the gates already recorded, and never copy `evidence.gates.headSha` or the
   `head` branch name into the event.
3. Apply the current body to the PR/MR as section 4 says.
4. Persist `PR_OPENED` with the recorded `operationKey`, the PR/MR number and URL, and that
   `head_sha`.

## 4. Keeping the body current

The body's `Gates bypassed during build:` line comes from the plan artifact's
`Gates bypassed (build union):` line, and every fix chain can change that union. Whenever a push
reaches an open PR/MR, in the re-entry above and in steps 5 and 6, render the body again in the
order of `rules/conventions.md` §4 and apply it from `$REPO`:
`gh pr edit <id> --body-file "$BODY_FILE"` on GitHub, and
`glab mr update <id> --description "$(cat "$BODY_FILE")"` on GitLab.

## 5. The bound

Only local work the gates never tested goes back to step 2: what the head check of
section 1 finds, or a refused `PR_OPENED` while `git rev-parse HEAD` differs from
`evidence.gates.headSha`. Such work returns to step 2 once per open request. The gates then run
on it and record `GATES_PASSED` or `GATES_FAILED`; the refusal itself is not a gate failure and
records nothing. These three cases never go back to step 2:

- a refused `PR_OPENED` while the two heads are equal: the refused head is one the forge holds,
  and step 2 would only test the head the gates already recorded;
- a gate event the state machine refuses with `gates already recorded for this head`;
- a further refusal, or a further mismatch in the head check of section 1, once the run record
  that `--autopilot-status` prints holds a `GATES_PASSED` event whose `fromStage` is `OPEN_PR`
  after the latest `PR_OPEN_REQUESTED`.

Each is a stop-the-world blocker: persist `BLOCK` with code `PR_HEAD_GATE_MISMATCH` and halt.
