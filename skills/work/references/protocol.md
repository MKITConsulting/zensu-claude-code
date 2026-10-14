# Work-order protocol

This file describes what the helper `hooks/lib/zensu-work-order.sh` and its runtime
`hooks/lib/work-order-v1.js` do. The skill body is the procedure; this file is the account behind
it.

## Work-order mode

A session is in work-order mode when all three hold:

1. `ZENSU_SESSION_TOKEN` is set. The runtime tests its presence only and never reads its value.
2. `.zensu/state/work-order/marker-<session-key-hex>.json` exists and binds this session's Session
   Control key.
3. The order's `client_session_id` maps to the same Session Control key. `--start` checks this
   before it writes the marker.

Outside work-order mode every work-order hook prints nothing and exits 0, and Autopilot behaves as it
did before.

## State files

All files live in `<project>/.zensu/state/work-order/` and end in the 64 hex digits of the session
key. Each is written to a temporary file and renamed into place.

| File | Written by | Holds |
|---|---|---|
| `marker-` | `--start` | order id, attempt, kind, repository, spec hash, plan-approval policy |
| `order-` | `--start`, `--bind-spec` | the last `zensu work get` answer |
| `lease-` | every successful renewal or event | lease seconds, last success time, recorded head, order status |
| `outbox-` | `--autopilot-begin`, `--drain` | the bound Autopilot run id and the highest stage rank Zensu accepted |
| `answers-` | renewals | answers to non-blocking questions not yet shown to the model |
| `lost-` | the first lease loss | the code that proved it; created once, never replaced |
| `ended-` | the first terminal outcome | outcome, kind, whether Zensu accepted it; created once |
| `stop-` | the Stop hook | stops in a row without a new ledger event |

## Stages

The Autopilot ledger is the outbox. Each ledger event maps to at most one stage, and only a stage of
a higher rank than the last accepted one is sent:

| Ledger | Stage |
|---|---|
| `START` | `planning` |
| `ORDER_SPEC_BOUND`, and any move to `AWAIT_TDD`, `TDD_RUNNING`, `GATES`, `CONVERGE`, `OPEN_PR` | `implementing` |
| `PR_OPENED` | `pr_open`, with the pull request URL, number, branch and full head |
| any move to `TEAM_REVIEW`, `FIX_FINDINGS`, `TEAM_REVIEW_IMPORTED` included | `reviewing` |
| any move to `VALIDATE`, `COVER` | `validating` |
| `DELIVERY_COMPLETE` | `ready_for_merge`, sent only by `--finish`, with the full head |

`PR_OPEN_REQUESTED` maps to no stage, so `pr_open` never precedes the pull request. Every stage
event carries `--client-name zensu-claude-code`, the plugin version, `--autopilot-stage`,
`--autopilot-run-id` and a `client_event_id` of `zcc-` plus 40 hex digits of a SHA-256 over the run
id and the ledger event id, so a repeated send replays instead of moving the order twice.

## Binding the spec

`--autopilot-begin --work-order <id>` stores the binding `{orderId, attempt, specHash}` in the run
record. `--bind-spec --run <id>` then reads the order again, refuses a spec that changed since
`--start`, reports `planning` and then `implementing`, and only after Zensu accepted `implementing`
records `ORDER_SPEC_BOUND`, which moves the run from `PLANNING` to `AWAIT_TDD`. An order an
earlier attempt already moved past `implementing` is bound without sending `implementing` again.
The model cannot record `ORDER_SPEC_BOUND` through `--autopilot-event`, and a work-order run refuses
`PLAN_APPROVED`.

With `plan_approval = required`, Zensu refuses `implementing` until a person approved the
implementation plan for the current spec hash. An approved attempt reads the order timeline,
takes the last `plan` artifact before the last approval of that spec hash, and compares the plan
file at that commit with the plan file in the working tree. A difference blocks the order with
`worker_error`. The run's `approvedPlanSha256` is the SHA-256 of the approved plan file; with
`plan_approval = auto` it is the order's spec hash.

## Pushing

`--push` renews the lease, refuses an order that has not reached `planning`, and pushes
`HEAD` to the current branch with `--force-with-lease=refs/heads/<branch>:<recorded head>`, where
the recorded head is the head Zensu last stored for the order (none for the first push). A remote
branch that already holds the local head is not pushed again. After the push it sends a stage event
with the current stage and `--head`, so Zensu records the new head.

Zensu accepts an order branch only when it starts with the spec's `branch_prefix` (`wo-` today) and
refuses any other with `422 invalid_branch`. The runtime names a fresh order's branch from that
prefix and the first eight characters of the order id. `--bind-spec` and `--push` refuse a working
branch without the prefix before they send anything, and stage events leave such a branch out.

`--open-pr --title <title> --body-file <path>` renews the lease, requires that Zensu recorded the
current head, and opens the pull request against the plan's integration branch, else its base
branch, through `zensu-vcs.sh`. It prints a JSON line with the URL and number. When the order names
a pull request, or the forge has an open one for the branch, it imports that one instead and adds
`imported: true`. An order whose pull request was closed or merged, or belongs to another branch, is
refused with exit 8, and nothing is opened.

## Taking over an order

A new attempt of an order that an earlier attempt worked on starts a fresh Autopilot run and takes
the rest from the order and the forge:

- `--start` releases every nonterminal Autopilot run in this project that is bound to the same order
  with a lower attempt. The release is a `CANCEL` with the event id `work-order-release-<attempt>`,
  recorded without the owner-activity check of `--autopilot-release`: Zensu claimed the order again,
  so the earlier attempt's lease is gone.
- The session continues on the order's branch, and `--push` pushes against the head Zensu recorded.
- `--open-pr` imports the order's open pull request.
- A work-order run keys its team review by the order, not by the run:
  `team-review:v1:<sha256(canonical({headSha,orderId}))>`, generated by
  `autopilot_work_order_review_operation_key` in `hooks/lib/zensu-autopilot-state.sh`. Every attempt
  can therefore recognize a review an earlier attempt published.
- `--review-import --run <id>` runs at `TEAM_REVIEW` before `TEAM_REVIEW_REQUESTED`. It reads the
  first-part review markers on the pull request through `zensu-vcs.sh --review-markers`, keeps the
  markers whose operation digest matches the order key for the marker's head, and of those the one
  whose head is the nearest ancestor of the pull request head. It records `TEAM_REVIEW_IMPORTED`
  with that marker, which moves the run to `FIX_FINDINGS` without a second publication. Without a
  match it records nothing and prints the order-bound `operationKey` the request must carry. The
  model cannot record `TEAM_REVIEW_IMPORTED` through `--autopilot-event`.

## Questions, follow-ups and the plan approval

`--ask` sends `zensu work ask` with a `client_event_id` derived from the order, the attempt, the
category and the question, so a repeat replays. When Zensu answers with the order `blocked` — a
blocking question, a scope question (`spec_change`) or any question past the order's limit
(`escalated`) — the helper writes `ended-` with a successful outcome, cancels the local run and
exits 6. `--followup` sends `zensu work followup` the same way; Zensu takes at most 20 per attempt.

`--plan-approval` needs the order at `planning` with `plan_approval = required`. It commits the plan
file when it is new or changed, pushes through the push verb, sends an artifact event of kind
`plan` with the path, the commit, a summary without markup and, for a GitHub or GitLab repository,
the blob link, then sends `--blocked plan_approval`. Zensu ends the session there; the helper
records a successful outcome.

## Work-order hooks

Outside work-order mode all three print nothing and exit 0.

- `pre-work-order-gate.sh` (every tool) denies the prompt tools, the task-chip tool, a raw
  `git push`, `gh pr create`, `glab mr create`, every merge, `zensu auth`, `zensu work event` and
  `zensu work heartbeat`, every other `zensu work` verb except `get`, `events`, `ask`, `followup`,
  `questions`, `list`, `policy get` and `repositories list`, the `zensu plan` approval verbs, and
  every command that prints, reads, unsets or overrides `ZENSU_SESSION_TOKEN`. It reads commands
  inside `bash -c`, `eval`, command substitutions and wrappers such as `env` or `sudo`. It renews
  the lease when due, and once the lease is lost or the session ended it denies every `gh`, `glab`
  and `zensu-vcs.sh` call. It never allows anything.
- `post-work-order.sh` (every tool) renews the lease when due, drains the outbox, hands pending
  answers to the model, and ends the session when a direct `zensu work ask` blocked the order.
- `stop-work-order.sh` blocks a Stop until the order reported an outcome.

The gate reads command text; a command assembled at run time, such as a script file the model wrote,
is not judged. The slot sandbox of the worker, not this gate, is the boundary.

The worker starts the session through `harness/launcher.js` (`docs/work-order-mode.md`). The
launcher renews the lease when no renewal succeeded for a third of the lease time, terminates the
session once the lease is lost, and releases the session's nonterminal Autopilot run after the
session exited.

## Errors the helpers handle

The CLI prints a backend error as `error: <message> (status <n>, code <code>)`, possibly followed by
more context on the same line or on further lines, and under `--json` adds a last stderr line
`{"error":{"status":…,"code":…,"message":…}}`. Every helper call passes `--json`. The runtime reads
the JSON line first and the first `(status …)` group of the error text second; without a code it
decides by status and, for a `409`, by one more `zensu work get`. A failure without a status — a
network, flag or validation error — is retried inside the retry budget like a missing answer.

| Answer | Handling |
|---|---|
| any `401`; the codes `stale_attempt`, `runtime_cap`, `invalid_session_token`, `session_order_mismatch`, `session_token_required`, `work_orders_disabled` at any status; `403` or `404` without a code | lease lost: write `lost-`, deny every forge write, end |
| the codes `claim_not_confirmed`, `event_in_flight`, `draining` | retry with backoff inside the retry budget |
| `429`, `5xx`, no answer | retry with backoff inside the retry budget, then exit 7 |
| `plan_approval_required` | the plan-approval path; never retried |
| `invalid_transition` on a stage | the stage is already behind the order; counted as delivered |
| `409` without a code | probe the order: an unconfirmed claim retries, a missing plan approval reads as `plan_approval_required`, anything else as `invalid_transition` |
| any other code or `4xx` | final; the helper exits 8 and names the code |

A heartbeat that fails with a final answer is treated as a lost lease, because a lease Zensu does not
renew cannot be relied on.

## Ending

`--finish` reports the outcome and writes `ended-`. Zensu ends the session itself on
`ready_for_merge` and on every block, so a later call of any session route answers `401`; the
ended marker keeps the helpers from treating that as a new failure. Every ending also cancels the
local Autopilot run, so the Autopilot Stop guard releases the session.
