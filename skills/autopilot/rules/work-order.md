# Autopilot in work-order mode

`/zensu:work` sends an `implement` order here. Work-order mode replaces Autopilot's planning gate
and its forge commands; every other rule of `/zensu:autopilot` holds. Nobody answers a question in
this session, and Zensu, not a person, approves the plan.

`$WO` and `$LOG` are the helpers `/zensu:work` resolved in its Step 0, and `<order-id>` is the
order's id. Run every helper with its leading `CLAUDE_PLUGIN_DATA="…"` assignment, exactly as
`/zensu:work` renders it, and act on its exit code as that skill's table says.

## 1. Working tree and branch

Stay in the checkout the session started in: the worker prepared it. Do not create a worktree.

- The `--start` summary names a `branch`: the order was worked on before. Fetch it and continue on
  it: `git fetch origin <branch>`, then `git checkout -B <branch> origin/<branch>`. `--start`
  already released the local Autopilot run an earlier attempt left in this checkout.
- No `branch`: create `workBranch` from the order's integration branch, else its base branch:
  `git fetch origin <base>`, then `git checkout -b <workBranch> origin/<base>`.

Resolve `$VCS` and detect the forge as Autopilot's Step 0 and 0.A.1 say. `cliReady=false` or an
unknown provider cannot be fixed here: finish with `--reason`.

## 2. Probe

Probe as Autopilot's 0.B says, with two differences:

- Use a committed `.zensu/autopilot.yaml` when one exists. Never write one in work-order mode.
- When boot or authentication would need a question, ask Zensu a non-blocking `technical_choice`
  question with the default option "deliver without live validation", then pass `--validate false`
  to the begin step, mark every acceptance criterion `🟡 unvalidated` in the pull request body, and
  state why in that body.

## 3. Plan

Write the plan to `.zensu/plans/<order-id>.md`: the spec from the order, numbered acceptance
criteria with stable `AC-###` ids, and the resolved recipe, shaped on the Autopilot spec template.
Settle every open question yourself with the safest reversible choice and record each choice in the
plan under `## Decisions`. A choice a person should see goes to Zensu as a non-blocking question
whose default option is that choice; a question the work cannot go past is a blocking one and ends
the session. Never call `ExitPlanMode`, and never add a `zensu-autopilot` marker:
Zensu binds the plan, not the plan gate.

## 4. Begin and bind

Generate a run id (`run_<random-hex>`), then begin the durable run bound to the order:

```bash
CLAUDE_PLUGIN_DATA="…" bash "$LOG" --autopilot-begin --run "$RUN_ID" --work-order "<order-id>" --cover false --validate "$VALIDATE"
CLAUDE_PLUGIN_DATA="…" bash "$WO" --bind-spec --run "$RUN_ID"
```

`--autopilot-begin` in a work-order session refuses a begin without `--work-order`, and one that
names another order.

`--bind-spec` reports `planning`, checks the order's plan-approval state, reports `implementing`
and records `ORDER_SPEC_BOUND`, which moves the run to `AWAIT_TDD`. On exit 0 continue with
Autopilot's Phase 1 step 1, the `/zensu:tdd` run with the exact `AUTOPILOT-RUN: <RUN_ID>` line.

Exit 8 with `plan-approval-required` on stderr means a person must approve the plan first. Run:

```bash
CLAUDE_PLUGIN_DATA="…" bash "$WO" --plan-approval
```

It commits `.zensu/plans/<order-id>.md` on the order branch, pushes it, attaches it to the order as
the plan artifact with its commit and a short summary, and asks for the approval. Exit 0 ends the
session successfully; a later attempt implements the approved plan. That attempt's `--bind-spec`
compares the plan file on the branch with the approved commit and blocks the order with
`worker_error` when they differ, so never edit the plan file after the approval.

Exit 6 or 4 from either step: finish once and end.

## 5. Build

Run Autopilot's Phase 1 in order. After every Autopilot event you persist, run `"$WO" --drain`.
These steps differ:

- **Every push** runs `"$WO" --push`, never `git push`. That holds inside `/zensu:pr-fix-findings`
  and in the validate loop too: where those steps push, run `--push` instead. Exit 8 from `--push`
  means the remote branch does not hold the head Zensu recorded; never force past it, finish with
  `--reason`.
- **Opening the pull request** (Phase 1 step 3): commit, run `"$WO" --push`, persist
  `PR_OPEN_REQUESTED`, then run
  `"$WO" --open-pr --title "<title>" --body-file "<absolute path>"` instead of the driver's
  `--open-pr`. Its stdout is `{"value":{"url":…,"number":…,"base":…,"branch":…,"head":…}}`; persist
  `PR_OPENED` with that number, URL and head, then run `--drain`. When the order already has an open
  pull request, the value carries `"imported":true` and names it: persist `PR_OPENED` with it all
  the same, and never open a second one.
- **The team review** (Phase 1 step 4): before `TEAM_REVIEW_REQUESTED`, run
  `"$WO" --review-import --run "$RUN_ID"`. With `"imported":true` an earlier attempt's team review
  covers this pull request and the run is already at `FIX_FINDINGS`: continue there and publish no
  second review. Otherwise persist `TEAM_REVIEW_REQUESTED` with the `operationKey` and `provider` it
  printed, not with a key from `autopilot_team_review_operation_key`: a work-order run binds its
  review to the order, so a later attempt can find it.
- **A blocker that the one rule would halt on** ends the order: finish with `--reason` and one
  plain sentence naming the blocker.

## 6. Deliver

After `DELIVERY_COMPLETE`, run `"$WO" --finish`. It reports `ready_for_merge` with the full head
and the pull request. Do not merge.
