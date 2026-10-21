# Work-order mode

A Zensu worker runs a claimed work order in a headless Claude Code session: it starts
`claude -p "/zensu:work <order-id>"` with the session token in `ZENSU_SESSION_TOKEN` and the Zensu
host that issued it in `ZENSU_API_URL`. The `zensu` CLI never sends a session token to its built-in
default host, so a session without `ZENSU_API_URL`, and without a CLI config that stores the host,
stops at `--start` with exit 3. A CLI config the session can read must hold only the host, never a
login, because without the session token the CLI falls back to the stored login; `zensu auth logout`
keeps the host and removes the login. The plugin is the reference harness for that session. It reads the order, builds it with Autopilot, reports every
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
   `ORDER_SPEC_BOUND`, which moves the run to `AWAIT_TDD`. When the order needs a plan approval,
   `--plan-approval` commits and pushes the plan file, attaches it to the order as the plan artifact
   and asks for the approval, which ends the session. A later attempt binds the approved plan and
   blocks the order with `worker_error` when the plan file on the branch differs from it.
3. Every push goes through `zensu-work-order.sh --push`, which renews the lease first, pushes with
   `--force-with-lease` against the head Zensu recorded for the order and reports the new head. The
   pull request opens through `--open-pr`, which imports the order's open pull request instead of
   opening a second one.
4. `--drain` sends each stage the Autopilot ledger reached and Zensu has not seen, never backwards
   and each with a fixed `client_event_id`.
5. `--finish` reports `ready_for_merge` for a `DONE` run, or blocks the order with `worker_error`
   and a stated reason, and cancels the local Autopilot run.

`skills/work/references/protocol.md` lists the state files, the stage mapping and every backend
error the helpers handle.

## Taking over an order

When an attempt ends without an outcome, for example because its lease expired, Zensu can claim the
order again with a higher attempt number. The new session continues the order instead of starting
over:

- `--start` releases the local Autopilot run an earlier attempt of the order left in the checkout,
  so a reused checkout does not hold the new run off.
- The session works on the order's branch and pushes against the head Zensu recorded.
- `--open-pr` imports the order's open pull request. A pull request a person closed or merged is
  refused, and the session ends with a stated reason.
- A work-order run binds its team review to the order rather than to the run. Before it requests a
  team review, `--review-import` looks for a review an earlier attempt published on the pull request
  and, when it finds one for an ancestor of the current head, records it and continues with the
  findings. No second team review is published.

## Questions and follow-ups

The session asks Zensu, never a person. `--ask` sends a question with its options and the option
the session continues with. A blocking question (`spec_change` when its category is `scope`) or any
question past the order's limit (`escalated`) blocks the order and ends the session; a person's
answer requeues a question or `spec_change` block, while an escalated order waits until a person
requeues it. A non-blocking question, `scope` included, only records the assumption. `--followup`
records an idea outside the order's scope as a follow-up. Answers to this order's questions that
arrive while the session runs reach the model as context after its next tool call. So do the
decisions a person made for the whole plan, as recorded at `--start` and `--bind-spec`; a plan-wide
decision made later reaches the next session of the order, not the running one.

## The tool hooks

`hooks/pre-work-order-gate.sh` runs before every tool call. It denies the prompt tools, both
Claude Desktop session tools (`spawn_task` and `start_session`), a raw push, opening or merging a
pull request outside the helpers, `zensu auth`,
the `zensu work` and `zensu plan` verbs a worker session must not call, the usual spellings that
print, read, unset or override `ZENSU_SESSION_TOKEN` or that set, change or remove `ZENSU_API_URL`,
and `--api-url` on `zensu`. Each denial says why and, where a helper verb does the job, names it. Once the lease is lost, or while Zensu refused it and a send without an answer still waits for its replay, it also denies every forge command. It renews the lease when due
and never allows anything, so the host's own permission rules still decide every call it does not
deny.

`hooks/post-work-order.sh` runs after every tool call. It renews the lease when due, sends the
stages the Autopilot ledger reached, hands pending answers to the model, and ends the session when
a direct `zensu work ask` blocked the order.

## The Stop hook

`hooks/stop-work-order.sh` keeps a work-order session from ending without a reported outcome. It
blocks the Stop until the order reported `ready_for_merge` or a block. Three Stops in a row without a
new Autopilot ledger event end the order on its own: it reports `ready_for_merge` for a `DONE` run and
`blocked(worker_error)` for any other, then lets the session stop. A lost lease ends the session
without a report.

## The launcher and the manifest

`harness/manifest.json` tells a Zensu worker how to run this harness:

```json
{
  "harness": "zensu-claude-code",
  "contract_version": 1,
  "launcher": "harness/launcher.js",
  "supported_kinds": ["implement"]
}
```

`launcher` is relative to the plugin root and executable. The worker starts it in the checkout it
prepared, with the session token in `ZENSU_SESSION_TOKEN` and its host in `ZENSU_API_URL`:

```text
harness/launcher.js --order <order-id> --session-id <client-session-id> [--project <dir>]
  [--claude <executable>] [--permission-mode <mode>] [--settings <file>] [--mcp-config <file>]
  [--plugin-dir <dir>] [--log <file>] [-- <further claude arguments>]
```

The launcher runs `claude -p --session-id <client-session-id> --output-format stream-json
--verbose --setting-sources user --strict-mcp-config`, the slot options and the further arguments,
and the prompt `/zensu:work <order-id>`, in its own process group in the project directory, which
defaults to its working directory. Claude Code refuses `stream-json` output under `-p` without
`--verbose`.

It prints one JSON line per event on stdout and nothing else:

| Line | When |
|---|---|
| `{"event":"session_started","client_session_id":"<id>"}` | the session initialized |
| `{"event":"rate_limited","reset_at":"<time or null>"}` | Claude Code retries because of a rate limit |
| `{"event":"exited","status":"success\|failure\|cancelled","exit_code":<n>,"reason":"<code>"}` | the session ended |

`reason` appears with `failure` only: `lease_lost`, `harness_error` for a session whose result
was an error, `harness_failed` for a non-zero exit, `harness_unavailable` when `claude` could not
start. The launcher exits 0 on success, 1 on failure and 143 when it was cancelled; a usage error
or a missing session token exits 2 and prints nothing on stdout.

`SIGTERM`, `SIGINT` and `SIGHUP` cancel the session: the launcher sends `SIGTERM` to its process
group, then `SIGKILL` after the grace time. While the session runs, the launcher renews the lease
when no renewal succeeded for a third of the lease time; a lost lease writes the lease-lost marker
and terminates the session. After the session ended, the launcher releases the session's
nonterminal Autopilot run, so a reused checkout is free.

The transcript, the tool calls, the tool output and the cost stay on the host. `--log` appends the
raw output to a file there; nothing else keeps it.

## Known gaps

- The installed `zensu` CLI must provide `zensu work`, which zensu-cli 0.8.0 is the first release
  to carry; with an older CLI, `/zensu:work` refuses in one line that names zensu-cli 0.10.0,
  the oldest release the plugin supports.
- The gate reads command text. A command assembled at run time, such as a script the session
  wrote and then runs, an interpreter one-liner, or a spelling the gate does not know is not
  judged; the worker's slot sandbox, not the gate, is the boundary.
- `--start` releases only runs of the same order. A nonterminal run of another order in a reused
  checkout still holds the new run off, and the session ends with a stated reason.
- Zensu records `zensu-cli` and the CLI version as the client of every question and follow-up,
  because `zensu work ask` and `zensu work followup` take no `--client-name` in zensu-cli 0.9.0.
  Stage, artifact and block events name `zensu-claude-code` and the plugin version.
- `--review-import` trusts a review marker by its digest, which anyone who knows the order id can
  compute, and it reads only the first part of a review. A review that an earlier attempt published
  only in part is imported as if it were complete.
- Work-order mode is unverified on native Windows: the launcher's process-group handling is POSIX
  only, and the work-order suites skip on that host.
- The gate judges only Bash commands, so it refuses Claude Code's PowerShell tool in a bound
  session, and the launcher starts the session with `CLAUDE_CODE_USE_POWERSHELL_TOOL=0`. A session
  started some other way keeps the PowerShell tool as its host configures it, and every PowerShell
  command there is refused.
- The launcher prints no `usage` line and enforces no cost cap. Both belong to the worker slice.
