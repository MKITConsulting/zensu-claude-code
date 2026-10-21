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

**The CLI write-gate leaves `ask` and `followup` to this gate.** `pre-bash-zensu-gate.sh` calls
`zensu_work_order_hook bound`, which runs the side-effect-free `bound` verb of `work-order-v1.js`
behind the same D32 test, and when it answers `bound` the write-gate does not deny
`zensu work ask` or `zensu work followup`. Every other `zensu` mutation follows the write-gate's
ordinary rules in a work-order session: a person's decision and a work-order protocol verb are
denied even inside a skill window, but a window passes the other mutations it declares and the
inline `ZENSU_MCP_GATE=off` one-off passes any of them, because this gate refuses neither. The
deny of a person's decision in a bound session points to a work-order question, since no person
is there. `SESSION_WORK_VERBS` is exported because `test-skill-workflow-markers.sh` C5
holds the write-gate's `ZENSU_WORK_ORDER_SESSION_TOOL_NAMES` to it: a verb added to
`SESSION_WORK_VERBS` must map to a read or to one of those session tools
(`.claude/rules/cli-command-classification.md`).

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
transient only when it shows that no answer came: the CLI did not finish, printed no `error:` line,
or its line matches `NO_ANSWER_RE` (Go's `<Method> "<url>": …` transport error, `reading response
body`, `invalid … response|list`, or a network failure such as `connection refused`). Every other
status-less error the CLI printed itself is a refusal by the CLI: `classifyFailure` answers
`FINAL`, so `sendEvent` sends it once, and `cliRefusal` lets each message name the zensu CLI as the
refuser through `refusedText`, with the CLI's line in place of a status and code. `--start` exits 3
on it (after the two `SESSION_TOKEN_*` lines, which keep their own advice), the other helpers exit
8, and a refused heartbeat writes `lost-` with the code `cli_refused`. The inverse reading, a list
of refusal messages with everything else transient, was rejected: zensu-cli has dozens of
validation messages and adds more, while Go's transport error has one shape. A crash prints no
`error:` line and stays transient, with its first stderr line quoted. The error table lives in
`skills/work/references/protocol.md`.

**The gate reads a `zensu` call's words as cobra v1.10.2 does.** `zensuCommandWords` mirrors the
subcommand search of zensu-cli v0.10.0, the same rule as the CLI write-gate's parser
(`.claude/rules/cli-command-classification.md`): no group defines a flag, so every `--flag` and
every two-character `-f` without `=` takes the next word, an empty word is skipped and `--` ends
the search. `WORK_VERB_ALIASES` maps the CLI's one `zensu work` alias, `repos`, to `repositories`.
`HUMAN_PLAN_VERBS` lists every plan verb whose tool `ZENSU_HUMAN_DECISION_TOOL_NAMES` holds, and
`test-skill-workflow-markers.sh` C6 holds the two equal, as C5 does for `SESSION_WORK_VERBS`.

**No SessionStart text tells a token session to run `zensu auth login`.** While
`ZENSU_SESSION_TOKEN` is set, zensu-cli sends the session token and never the stored login
(`sessionTokenTarget`), and no person can sign in, so the primer substitutes `__ZENSU_CLI_AUTH__`
with nothing and the banner drops `_ZENSU_CLI_AUTH_HINT` and `_ZENSU_CLI_LOGIN_STEP`. The test is
the token's presence, not the bound marker, because `/zensu:work` writes the marker after the
session started, when the primer has already run. `test-session-start-banner.sh` B12d and B16f
hold both texts.

**Sites that move with the CLI and the service.** `SESSION_TOKEN_HOST_RE` and
`SESSION_TOKEN_SHAPE_RE` match the two messages of `sessionTokenTarget` in zensu-cli, and the fake's
`requireSessionToken` copies both word for word; a CLI rewording turns them into the generic exit-3
refusal while every suite stays green. `NO_ANSWER_RE` copies Go's `url.Error` shape and zensu-cli's
`reading response body` and `invalid … response` wordings: a CLI that rewords a transport failure
makes it final, so the session stops on it instead of retrying. The fake's `usage` and the
injected `cli` refusal print the CLI's own `error:` line and `--json` line. The fake's `proseViolation` ports the service's content guard, and
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
