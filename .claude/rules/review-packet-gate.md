---
paths:
  - "hooks/lib/review-packet-v1.js"
  - "hooks/lib/review-gate-v1.js"
  - "hooks/post-review-tdd-delegate.sh"
  - "tests/structure/review-packet-v1.test.js"
  - "tests/structure/review-gate-v1.test.js"
  - "tests/structure/test-review-packet.sh"
---

# Review Packet Gate (`review-packet-v1.js create` + `review-gate-v1.js` + the post-review hook)

Before this gate, "every reviewer of a round reads the same `REVIEW PACKET v1`" and "the consume
review needs the primary judge" were prose. The model built each packet by hand, the incremental
rounds narrowed the aspects' `changed_files` while the judge kept the full list, and the consume
completion claimed its ticket whether or not a judge had run. The Copilot 0.2.1 audit (WF-008,
WF-009) found both gaps in this host's source.

**Why the gate sits at PostToolUse, not PreToolUse.** A PreToolUse deny, or an `updatedInput`
that injects the packet, would be a hook that can return a `permissionDecision`, which
`.claude/rules/runtime-lineage.md` classifies as breaking, and `pre-agent-reviewer-allow.sh` must
only grant or stay silent. The review ticket is the one thing that advances the chain, and the
post-review hook already decides whether to claim it, so refusing the claim there holds the
invariant with `additionalContext` alone. The cost is one consume-reviewer run per refusal.

**One canonical block per round.** `create` renders the block deterministically, so its sha256
identifies it, and every model-written field is an indented block scalar, so no field line can
equal a boundary line or a top-level key. Narrowing moved out of the packet: a fix round's delta
and a judge gap travel on a `review_scope:` line after the block, which `agents/review-aspect.md`
reads. The packet, and with it the judge, keeps the full cumulative change set, which is the
compensating control `.claude/rules/incremental-review-rounds.md` requires. Extraction compares
the block after removing trailing whitespace and CRLF; anything else is an exact comparison.

**What `create` binds besides the fields.** With a receipt, the baseline is the one the
edit-landing audit persisted in `auditScope.baseline`; a differing `--baseline` is refused, an
omitted one takes it, and the `change_set:` line names the source (`baseline_source=receipt`,
`argument` or `none`), because a model that forgot the baseline after a mid-run commit reviewed a
change set without the committed files. A tree whose fingerprint `computeTree` declines for a size
limit (`limited: true`) is stored as `tree: null` with `treeReason` and rendered as
`tree=unverified (<reason>)`; `scopeDifference` then compares the reason, and a git failure still
refuses. The bounds are split by what the model controls: the seven field blocks may take
`LIMITS.fieldBytes` (192 KiB) and the rendered changed-file list `LIMITS.changedListBytes`
(1 MiB), each with its own refusal, and the input and record bounds derive from the two, so a
large change set is never refused as long summaries. A successful `create` removes its `--input`
file when it lies in a `.zensu/reviews/` directory at or below the root (`removeConsumedInput`,
best effort, never a symlink or a hard-linked file), and `finding-verify-v1.js --input` removes the
findings file it graded the same way: both inputs carry model-written text, `.zensu/` is often
committed, and the ignore recipe in `docs/build-workflow.md` names `.zensu/reviews/`.

**Three receipt modes, chosen by `create` from the workflow document.** `receipt`: the step 5b
receipt is checked through `--check-receipt --allow-unclean`, and its digest is bound into the
packet record; the receipt line carries its counters, plus ` audit=incomplete` when the latest
audit did not complete, which `receiptFresh` passes under `--allow-unclean` after the root and
session checks. `escaped`: the chain's bypass ledger records `ZENSU_EDIT_LANDING_GATE`, or the
call's environment sets it to `off`, the two channels the acceptance gate also honours; no
receipt is read. `none`: the chain carries a `deferredReviewClaim` and no receipt file exists,
which is the generation `tdd_seed_deferred_review` starts. A record carries `receiptMode`, and
its `receiptSha256` is a digest exactly for `receipt` and `null` otherwise; the consume check
compares the digest for `receipt`, refuses `none` once a receipt appeared, and compares nothing
for `escaped`. A bare `<step> WIRED` entry the audit graded is stored as `auditScope.bareWired`,
and the freshness check refuses only a count that differs from it, so a fix round's bare entry
is carried as an unverified claim instead of refusing `create` until the Stop cap.

**What a record is.** One file per reviewer completion in `.zensu/state/review-gate-<key>/`,
written temp-then-rename, so a parallel fan-out needs no lock. Identity is the role for a judge
run and the report's `## Aspect:` heading otherwise; the LATEST run of an identity over every
record of the round decides, so a re-spawned aspect supersedes its mismatched run, and an identity
whose latest run predates the round's packet is refused until it runs again on the block: its
findings were merged against another block. A run without a heading has no identity. At least one
identity must have reported on the canonical block, so a consume review that skipped the whole
panel is refused rather than passed on an empty record set.

**Only the live ticket is judged.** The hook passes the consume prompt's `REVIEW-TICKET:` value
as `--ticket`, and `chainState` returns `reviewTicket`, `reviewTicketConsumed` and
`codeReviewDone`. A ticket that is not the live unconsumed one, or a chain whose code review is
already done, answers `pass not-current-ticket`, so the claim that follows refuses a duplicate or
late completion silently, as it did before the gate, instead of the gate refusing it loudly while
the current round may be healthy.

**Every remedy is a command.** `remedyCommands` renders `node <this lib>/review-packet-v1.js
show|create --root <root> --session <key>`, shell-quoted, and the create form names the seven
input fields and the `.zensu/reviews/` directory, because a remedy that names the helper without
its path or its arguments sent the model searching for it. The hook's own fallback message, for a
gate that could not check, renders the show command the same way.

**The primary judge requirement** mirrors step 4b: `hooks.reviewJudge` on, and the first review
(`reviewRound` 0) or `hooks.reviewPanel: full`. Substantive means status `completed`, a
`## Aspect: judge` heading, a `JUDGE-<n>` finding or `- (no findings)`, and no line starting with
`REVIEW PACKET INVALID`. The match is anchored at a line start because this repository's own
reviews quote that literal as data. A `judge_run: second` run never counts. The import path keeps
its documented fallback: a failed judge runs the panel, and the panel path's judge is the one
retry; two failed primary runs on one block stop the chain.

**Where the report comes from.** Measured on Claude Code 2.1.299 with a headless probe: in
`auto` permission mode the PostToolUse `tool_response` of an `Agent` call carries
`handback: "send"`, `handbackReport.text` with the report and a `content` stub that says the
report was delivered as a message; without the handback, `content` holds the text blocks.
`reportText` reads `handbackReport.text` first and treats the stub as no report.

**Background reviewers are judged by their hand-back.** The Claude desktop app runs every
subagent in the background (`.claude/rules/background-review-completion.md`), so a reviewer's
PostToolUse carries `status: "async_launched"`, an `agentId` and no report. Counting that as a run
failed every primary judge on that host, and ignoring it refused every consume review there,
because no reviewer had ever reported. So `recordObservation` stores a launch record (role, type,
packet digest and agent id, `identity: null`, `valid: null`) that `checkConsume` never counts as
a run, and `recordHandback`, which the delegate's arrival branch runs as `record --event
UserPromptSubmit` right after `match`, completes the latest launch of that agent in the round
with the report `handbackReports` in `hooks/lib/background-review-v1.js` de-indents from the
frame. A second completion for one agent is ignored, so a repeated delivery of a failed judge's
hand-back never reads as the second failure. The consume-mode reviewer is checked at its launch
with the launch prompt, before `background-review-v1.js record`, and a passing check writes a
`consume` record with the agent id and the block's digest. Its arrival is checked again with
`check --event UserPromptSubmit --agent <id>`, which takes the digest from that record and the
report from that agent's frame, so a notification-only arrival is judged on the round's records
alone. Every answer goes out in the arrival's own event, because a `UserPromptSubmit` hook that
names `PostToolUse` answers nothing. A refused arrival leaves through the delegate's EXIT trap,
which retires the background record, so the next Stop does not wait for a reviewer that has
already reported.

**Unobservable reports fail closed.** Outside auto mode the desktop app sends no hand-back, and
the notification it sends there was never measured, so the gate reads no report from it. Every
launch of the round without a completion is counted in the refusals for a missing reviewer and a
missing primary judge, which say to wait for those launches and, where the host delivers no
hand-back, to ask the user whether to set `hooks.reviewPacketGate` to `false`. The hint asks the
user rather than naming the edit, because the key is not a ledgered escape, and a model that
turned it off itself would disable the gate unrecorded. Counting a completion without its report
was rejected: it would pass a primary judge whose report nothing checked. Reading the report from
a measured notification would close the gap.

**An unreadable workflow document holds the claim silently.** `check` exits 3 when
`chainState` cannot read or validate the document, and the hook then exits without a claim and
without output. A loud refusal broke the byte-stable no-op contract that `S11a` and `S12` in
`tests/structure/test-post-review-tdd-scope.sh` hold for a malformed or foreign document. Passing
through was rejected too: the claim's own check does not read `schema` or `stopBlockCount`, so a
document the shared `workflowChainSnapshot` rejects could still be claimed without the packet
check.

**Engagement is the documented bound.** A generation engages once it has a canonical packet or a
recorded reviewer run, or when a consume prompt carries a packet block. That keeps every consume
fixture without a packet valid, and it leaves one shape unchecked: a consume prompt with no block
in a generation where no reviewer ran. The consume reviewer's own contract answers that shape with
`REVIEW PACKET INVALID`, which the gate refuses whatever the engagement.

**Every restart of the round count resets the store.** Packets and records are keyed by round
alone, so a chain whose `reviewRound` returns to 0 would judge its restarted rounds against the
closed review's packets and records, and a reviewer identity that does not run again would then
refuse the consume review as predating its round's packet. `--tdd-begin` and the deferred seed
start a generation; both `--review-rearm` arms and the `--chain-done` reopen of a minted
zero-change ticket restart the count inside one. All five reset the store. A reset that fails is
disclosed on stderr as `REVIEW GATE RESET UNAVAILABLE` and does not undo the transition, as at
`--tdd-begin`. `RP13`, `RP16a`, `RP23` and `RP23a` in `tests/structure/test-review-packet.sh` and
`G9k` in `tests/structure/test-chain-terminus-zero-change-gate.sh` pin the reset at `--tdd-begin`,
at the deferred seed, after the standalone rearm and at the reopen; no check drives the durable
rearm arm. All five call `tdd_review_gate_reset` in `hooks/lib/zensu-tdd-phase.sh`, the four
`zensu-log.sh` sites through `_zensu_review_gate_reset`.

**The deferred seed also retires the session's receipt.** A deferred generation starts already
implemented, so a receipt the session still holds belongs to an earlier generation, and its clean
verdict would close the deferred review at the terminus. `tdd_seed_deferred_review` therefore calls
`tdd_retire_edit_landing_receipt`, the one retirement `--tdd-begin` calls too, and discloses
`RECEIPT RETIREMENT UNRESOLVED` when it fails. The terminal edit-landing gate mirrors the `none`
mode: a deferred generation without a receipt closes with an `EDIT LANDING — not checked` line,
and one whose own audit wrote a receipt is judged by it (`E12`–`E12b` in
`tests/structure/test-terminal-edit-landing-gate.sh`).

**Coupled sites:** `classify` in `hooks/lib/review-gate-v1.js`, which asks `REVIEWER_TYPES` in
`hooks/lib/claude-principal-v1.js` whether a type is a confined reviewer and maps only the
unscoped name to a role, because the one-definition scan in
`tests/structure/reviewer-spawn-allow-v1.test.js` refuses a second spelling of the set, and the
`case` pre-filter near the top of `hooks/post-review-tdd-delegate.sh`, which must name the same
types, since a type it omits never reaches the gate; the three fix-round arms of `hooks/post-review-tdd-delegate.sh`, whose
`I17` needles in `tests/structure/test-incremental-review-rounds.sh` must stay at three each and
out of the convergence clause lines (`R16` in `tests/structure/test-review-convergence.sh`); step 10.2c, step 3, step 4b,
step 5 and the fix-round paragraph of `skills/build/references/review-chain.md`; the `review_scope`
paragraph of `agents/review-aspect.md` and the `merged_panel_findings` sentence of
`agents/review-judge.md`; `--check-receipt --allow-unclean` in `hooks/lib/zensu-edit-landing.sh`
and `requireClean` in `hooks/lib/edit-landing-receipt-v1.js`; the audit-mode `BARE_WIRED` count
the shell hands `scope-finish` as `ZEL_BARE_WIRED` and `gradedBareWired` beside `receiptFresh`;
`deferred`, `escaped` and the three ticket fields in `chainState`, `EDIT_LANDING_ESCAPE`, which must
spell the ledger name `ZENSU_BYPASS_GATE_ALLOWLIST` carries, and `RECEIPT_MODES`; the `--ticket`
argument of the hook's `check` call; `receiptPath`, which takes the receipt name from
`receiptFile` in `hooks/lib/edit-landing-receipt-v1.js`; `removeConsumedInput` and its call in
`jsonMain` of `hooks/lib/finding-verify-v1.js`; the store resets, which `_zensu_review_gate_reset`
in `hooks/lib/zensu-log.sh` runs at `--tdd-begin`, after both `--review-rearm` arms and in the
`--chain-done` reopen of a minted zero-change ticket, and `tdd_seed_deferred_review` in
`hooks/lib/zensu-tdd-phase.sh` runs through the same `tdd_review_gate_reset`; the deferred arm of
`_zensu_terminal_edit_landing_gate`, which reads `deferredReviewClaim` through
`tdd_deferred_review_generation`; `config.example.json`; the `reviewPacketGate` and
`incrementalReviewRounds` rows of `docs/configuration.md`; the auto-fix paragraph, the ignore
recipe and the publication-safety paragraph of `docs/build-workflow.md`; §Review Packet Gate
of `docs/gates.md`; and `docs/review-chain.md`. The background path adds `launchedAgent`,
`recordHandback`, `LAUNCHED`, `EVENTS` and the `consume` role in `hooks/lib/review-gate-v1.js`,
which takes `AGENT_ID_RE` and `handbackReports` from `hooks/lib/background-review-v1.js`, so the
frame grammar and the agent-id pattern keep one owner; `review_gate_check` and the arrival
branch's `record` call in `hooks/post-review-tdd-delegate.sh`, which runs before the
`ARRIVAL_MATCH` exit, so a fan-out reviewer's hand-back is recorded while no consume record
exists; `"reviewPacketGate":false` in `tests/structure/test-background-review.sh`, whose
fixtures carry no canonical packet; and the panel bullet of §"Background review agents" in
`docs/review-chain.md`. `RP24` to `RP26a`, `RP28a`, `RP28b`, `RP30` and `RP30a` in
`tests/structure/test-review-packet.sh` drive it through the shipped hooks, and `RP29` drives the
hook's fallback for a gate that cannot check.

**Version: `patch`.** No hook added, removed, renamed or re-matched, no `permissionDecision`, no
workflow-state or context-record field, and the config key is read permissively. The packet
input, packet record and reviewer record schemas ship for the first time, so no released reader
predates them. A session upgraded in the middle of a review round re-runs that round's reviewers
once, because its earlier runs saw no canonical packet. Reading background reviewers adds no hook
either: arrivals reach the delegate through the existing `user-prompt-review-handback.sh`, and
the record's `agentId` field and `consume` role ship with the record schema's first release.

**Known gaps:**

- A reviewer that never reports a `## Aspect:` heading has no identity, so its run neither counts
  toward the at-least-one rule nor blocks.
- The store sits in the session-writable `.zensu/state/`; a Bash write can forge a record, as for
  every plugin store.
- The `escaped` mode trusts the call's environment as the acceptance gate does, so an
  environment-only escape at `create` reaches the ledger only when the terminus runs with it too.
- A background reviewer that never hands back stays a launch record, which counts as no run, so a
  panel whose reports never arrive refuses the consume review rather than passing it.
- A prompt that carried a fan-out reviewer's frame with a packet problem and the consume
  reviewer's arrival at once would print the advice and leave the claim to the next arrival; the
  measured host sends each hand-back as its own prompt.
- While the key is on, every arrival the prompt hook passes on pays one more `node` start for the
  gate's record read.
- The hand-back shape is the one measured in the desktop app in auto mode; no live desktop run of
  a background panel through the gate exists.
- Windows is unmeasured: `tests/structure/test-review-packet.sh` runs in `ciStructureTests` only.
- `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were NOT included in this change.
