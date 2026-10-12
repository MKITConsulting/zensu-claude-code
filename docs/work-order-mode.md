# Work-order mode

A Zensu worker runs a claimed work order in a headless Claude Code session: it starts
`claude -p "/zensu:work <order-id>"` with the session token in `ZENSU_SESSION_TOKEN`. The plugin is
the reference harness for that session. It reads the order, builds it with Autopilot, reports every
stage to Zensu and ends the session with `ready_for_merge` or a block. Nobody answers a question in
such a session, so every step that would wait for a person either goes to Zensu or ends the order.

## When the mode is on

Work-order mode is on only when all three hold:

1. `ZENSU_SESSION_TOKEN` is set. The plugin tests its presence and never reads its value.
2. The session's work-order marker exists in `.zensu/state/work-order/` and binds the session's
   Session Control key. `/zensu:work` writes it.
3. The order's `client_session_id` belongs to the same session. `/zensu:work` checks this before it
   writes the marker.

Outside work-order mode every work-order hook prints nothing and exits 0, `/zensu:autopilot` keeps
its interactive planning gate, and no `zensu work` command runs.

## What a session does

1. `/zensu:work <order-id>` checks that the installed `zensu` CLI has `zensu work`, reads the order,
   writes the marker, renews the lease and links the Pulse session to the order. An order of any kind
   other than `implement` is blocked with `worker_error`, naming the kind.
2. Autopilot runs in work-order mode (`skills/autopilot/rules/work-order.md`). The run is begun with
   `--autopilot-begin --work-order <id>`, which stores the order binding in the run record. Zensu,
   not the plan-approval gate, binds the plan: `zensu-work-order.sh --bind-spec` reports `planning`
   and `implementing`, and only after Zensu accepted `implementing` records the internal event
   `ORDER_SPEC_BOUND`, which moves the run to `AWAIT_TDD`.
3. Every push goes through `zensu-work-order.sh --push`, which renews the lease first, pushes with
   `--force-with-lease` against the head Zensu recorded for the order and reports the new head. The
   pull request opens through `--open-pr`.
4. `--drain` sends each stage the Autopilot ledger reached and Zensu has not seen, never backwards
   and each with a fixed `client_event_id`.
5. `--finish` reports `ready_for_merge` for a `DONE` run, or blocks the order with `worker_error`
   and a stated reason, and cancels the local Autopilot run.

`skills/work/references/protocol.md` lists the state files, the stage mapping and every backend
error the helpers handle.

## The Stop hook

`hooks/stop-work-order.sh` keeps a work-order session from ending without a reported outcome. It
blocks the Stop until the order reported `ready_for_merge` or a block. Three Stops in a row without a
new Autopilot ledger event end the order on its own: it reports `ready_for_merge` for a `DONE` run and
`blocked(worker_error)` for any other, then lets the session stop. A lost lease ends the session
without a report.

## Known gaps

- The installed `zensu` CLI must provide `zensu work`; until a CLI release carries it, `/zensu:work`
  refuses in one line.
- The PreToolUse and PostToolUse layers that deny prompts, raw pushes and token reads, and that
  renew the lease on tool activity, are not part of this build step yet.
