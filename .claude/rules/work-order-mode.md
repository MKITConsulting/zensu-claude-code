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
`--drain` derives the stages from the run record and the outbox file keeps only the highest rank
Zensu accepted. A stage is sent forward only, and `ready_for_merge` only by `--finish`.

**The CLI prints the backend's error code**, and the runtime reads the `--json` error line first
and the first `(status N, code X)` group second (zensu-cli PR 26). A failure without a status is
transient. The error table lives in `skills/work/references/protocol.md`.

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
`error_status` is 429, with `retry_delay_ms` turned into `reset_at`. It also sets
`CLAUDE_CODE_USE_POWERSHELL_TOOL=0` for the session, because the gate judges Bash commands only and
refuses the PowerShell tool in a bound session (`H4p`, and the gate case in `work-order-v1.test.js`);
the post case there pins that a PowerShell `zensu work ask` ends nothing, because the ask branch
reads Bash only.

**`harness/` is outside the Session Control runtime digest.** The launcher runs in the worker's
process, never inside a bound session, and it loads the digested runtime from `hooks/lib/`.

**The launcher stops its session through `scripts/process-supervisor.js`.** It is that module's
only production caller, so removing or renaming the module breaks the launcher, not only a test. `test-harness-launcher.sh` H12 drives the
module's unit file.

**Version: `minor`.** The work-order hooks can return a `permissionDecision`, and the run schema
gained `workOrder`, `ORDER_SPEC_BOUND` and `TEAM_REVIEW_IMPORTED`. The release pipeline sets the
version; never bump it by hand.

**Known gaps, accepted and named:**

- The gate reads command text; a script the session writes and then runs is not judged.
- `--review-import` trusts a marker by its digest and reads only the first part of a review.
- A nonterminal run of another order in a reused checkout still holds a new run off.
- Native Windows is unverified. The launcher's process-group handling is POSIX only, and the five
  work-order suites skip there, because Node cannot start their shell-script fake `zensu` without a
  shell. `tests/profiles/windows-native-structure.v1.json` lists all five as excluded.
- `usage` lines and the cost cap belong to slice S4, other order kinds to slice S9.
