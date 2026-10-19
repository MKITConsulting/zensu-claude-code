---
paths:
  - "hooks/lib/work-order-v1.js"
  - "hooks/lib/zensu-work-order.sh"
  - "hooks/lib/zensu-work-order-hook.sh"
  - "hooks/pre-work-order-gate.sh"
  - "hooks/post-work-order.sh"
  - "hooks/stop-work-order.sh"
  - "harness/**"
  - "skills/work/**"
  - "skills/autopilot/rules/work-order.md"
  - "docs/work-order-mode.md"
  - "tests/structure/*work-order*"
  - "tests/structure/test-harness-launcher.sh"
---

# Work-Order Mode (`hooks/lib/work-order-v1.js` + `harness/launcher.js`)

The plugin is the reference harness for Zensu work orders. The operator account is
`docs/work-order-mode.md`; the protocol account the skill reads is
`skills/work/references/protocol.md`. This file records the decisions behind them and the sites
that move together.

**The mode is inert unless all three conditions hold** (D32): `ZENSU_SESSION_TOKEN` is present,
the session's marker in `.zensu/state/work-order/` binds its Session Control key, and the order's
`client_session_id` maps to the same key. Outside it every work-order hook prints nothing and exits
0. A hook that answered `allow` there would skip the user's permission prompts, so none of them
ever allows. `test-work-order-gates.sh` G1-G3 hold the silence.

**The Autopilot ledger is the outbox.** No second store records what Zensu still has to hear;
`--drain` derives the stages from the run record and the outbox file keeps the highest rank Zensu
accepted. A stage is sent forward only, and `ready_for_merge` only by `--finish`. The one exception
is `inflight`: up to four block, `ready_for_merge` or question sends that Zensu has not answered
yet. Each enters it before its first attempt, so a renewal in another process, the launcher's
watchdog among them, finds it while the sender still retries. Every route that meets a lost lease
goes through `loseLease`, which replays them before it writes `lost-`, because after Zensu ended a
session a replay under a stored `client_event_id` is the only call it still answers. The
safe-sentence resend of a block therefore keeps the first send's `client_event_id`; a refused `422`
stores nothing. A replay without an answer keeps the send and, while the local lease lasts, writes
`leaseRefusal` into the outbox instead of `lost-`; once the lease time has run out it writes
`lost-`. The gate's forge branch denies on `leaseRefusal`, with its own reason that sends the model
to `--renew --force`, and `recordLease` clears it. `sendEvent` records the lease only for an answer
Zensu did not mark as a replay, because a replay renews nothing and must not lift the fence.
`forgeWriteVerdict` ignores it on purpose, because `--ask`, `--followup` and `--bind-spec` check it
before they resend, and a resend is a replay. Every helper verb that gets the verdict `ended` back
maps it through `endedResult`; the post-tool hook builds its own notice from the ended marker.

**The CLI prints the backend's error code**, and the runtime reads the `--json` error line first
and the first `(status N, code X)` group second (zensu-cli PR 26). A failure without a status is
transient, except at `--start`, where a CLI line matching `SESSION_TOKEN_HOST_RE` or
`SESSION_TOKEN_SHAPE_RE` exits 3. The error table lives in `skills/work/references/protocol.md`.

**Sites that move with the CLI and the service.** `SESSION_TOKEN_HOST_RE` and
`SESSION_TOKEN_SHAPE_RE` match the two messages of `sessionTokenTarget` in zensu-cli, and the fake's
`requireSessionToken` copies both word for word; a CLI rewording sends `--start` back to exit 7
while every suite stays green. The fake's `proseViolation` ports the service's content guard, and
its `redactChanges` the service's `Redact`, which backs the `invalid_url` link check.
`DEFAULT_BRANCH_PREFIX` in the runtime and `BRANCH_PREFIX` in the fake mirror the service's
work-order branch prefix, `wo-`. A change on the service side means changing the fake with it, or
the suites keep passing against behavior Zensu no longer has.

**A work-order run keys its team review by the order, not by the run**:
`team-review:v1:<sha256(canonical({headSha,orderId}))>`. A key derived from the run, as decision
13 of the S3 plan proposed, finds a review only while the order's `autopilot_run_id` still names
the run that published it; the backend overwrites that field with every accepted stage, so a third
attempt could not find the first attempt's review. The key has FOUR spellings that move together:
`workOrderReviewOperationKey` in the worker of `hooks/lib/zensu-autopilot-state.sh`, the shell
helper `autopilot_work_order_review_operation_key` there, `workOrderReviewKey` in
`hooks/lib/work-order-v1.js`, and the validation sentence in
`skills/pr-team-review/references/delegated.md`. The unit case `the order-bound review key
matches the state library helper` compares the first three; `_autopilot_team_review_payload_identity_critical`
accepts the order key only after the run key failed, so a run without `workOrder` keeps its exact
old path.

**`TEAM_REVIEW_IMPORTED` relaxes one delivery invariant, and only for work-order runs.** An
imported review's head may be an ancestor of the `PR_OPENED` head instead of equal to it, because
the earlier attempt reviewed an earlier commit of the same branch. The state machine cannot see
ancestry; `--review-import` checks it with git before it applies the event, and `zensu-log.sh`
refuses the event from `--autopilot-event`. `test-work-order-takeover.sh` T8 fails when the
exemption in `reviewBelongsToPrGeneration` is removed.

**Two release paths, one verb.** `autopilot_release_work_order_run` cancels a nonterminal run of
the same order whose attempt is lower than the one given, with the event id
`work-order-release-<attempt>`, which `zensu-log.sh --autopilot-event` reserves. `--start` passes
the current attempt; the launcher passes the current attempt plus one after the session exited.
It skips the owner-activity check of `--autopilot-release` on purpose: a higher attempt proves
that Zensu took the lease away from the earlier one.

**The launcher builds the `claude` command itself.** Claude Code 2.1.280 refuses
`-p --output-format stream-json` without `--verbose` (read from the binary), and the template in
§6.2 of the monorepo plan omits it. The launcher passes `--verbose`, `--setting-sources user` and
`--strict-mcp-config`, and prints only `session_started`, `rate_limited` and `exited`.
`rate_limited` comes from a `system/api_retry` message whose `error` is `rate_limit` or whose
`error_status` is 429, with `retry_delay_ms` turned into `reset_at`.

**`harness/` is outside the Session Control runtime digest.** The launcher runs in the worker's
process, never inside a bound session, and it loads the digested runtime from `hooks/lib/`.

**The launcher stops its session through `scripts/process-supervisor.js`.** It is that module's
only production caller, so removing or renaming the module breaks the launcher, not only a test. `test-harness-launcher.sh` H12 drives the
module's unit file.

**The gate denies both Claude Desktop session tools by name**: `mcp__ccd_session__spawn_task` and
`mcp__ccd_session__start_session` (`CHIP_TOOLS` in `hooks/lib/work-order-v1.js`), with the `chip`
reason, which names `zensu work followup <order>`. Nobody in a work order clicks a card or answers
an offer, and a session started from one runs outside the order's lease. Claude Desktop 2.42304.0
replaced the task chip with a `start_session` proposal (read from its bundle on 2026-10-18), so a
deny of `spawn_task` alone left the work skill's "never open a task chip" rule unguarded there.
Claude Desktop supplies both tools itself, so a work-order session the launcher starts with
`claude -p` has neither; the deny guards a work order bound inside a Claude Desktop session.
Adding a name to `CHIP_TOOLS` changes no matcher (the gate matches `.*`), adds no hook and moves
no schema, so it ships as a `patch`. `test-work-order-gates.sh` G4 and the gate case in
`work-order-v1.test.js` pin both names. `skills/work/references/protocol.md`, the tool-hooks
section of `docs/work-order-mode.md` and the gate row of `docs/configuration.md` name both tools
too, and no test reads those sentences, so they move with `CHIP_TOOLS` by hand.

**Version: `minor`.** The work-order hooks can return a `permissionDecision`, and the run schema
gained `workOrder`, `ORDER_SPEC_BOUND` and `TEAM_REVIEW_IMPORTED`. The release pipeline sets the
version; never bump it by hand.

**Known gaps, accepted and named:**

- The gate reads command text; a script the session writes and then runs is not judged. It reads
  each command three ways, with plain single quotes and with the ANSI-C quoting of bash and of zsh,
  so its deny set never shrinks below the plain reading; a reading the shell does not use can only
  add a deny.
- `--review-import` trusts a marker by its digest and reads only the first part of a review.
- A nonterminal run of another order in a reused checkout still holds a new run off.
- Native Windows is unverified. The launcher's process-group handling is POSIX only, and the five
  work-order suites skip there, because Node cannot start their shell-script fake `zensu` without a
  shell. `tests/profiles/windows-native-structure.v1.json` lists all five as excluded.
- `usage` lines and the cost cap belong to slice S4, other order kinds to slice S9.
