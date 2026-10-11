# Delegated mode: the Autopilot envelope and its durable binding

Read this right after Step 0 when the invocation carries any delegated-envelope header, and
finish the envelope and state checks before Phase A starts. The provider guard and the
OPEN/head check it describes run in Phase A.1 (`references/scout.md`), and the OPEN/head
check runs again before the reconcile call (`references/publish.md`).

The envelope is exactly the following four contiguous lines with no intervening or additional delegated headers. They appear in this order, each exactly once and with no surrounding text
on the line:

```text
ZENSU-DELEGATED-CALLER: autopilot
AUTOPILOT-BINDING: run=<runId> attempt=<attempt> chain=<chainId>
AUTOPILOT-STAGE: <outer-stage>
AUTOPILOT-REVIEW-OP: key=<operationKey> head=<headSha>
```

Require caller `autopilot`, `<outer-stage>` equal to `TEAM_REVIEW`, a positive integer
attempt, valid durable identifiers for run/chain, a `team-review:v1:` operation key with a
64-lowercase-hex suffix, and a hexadecimal head between 7 and 64 characters, matching the
durable state/helper SHA domain. If any envelope header is present, a partial, duplicate, malformed, or conflicting envelope is a hard error; non-contiguous or extended envelopes
fail identically before worktree creation or
any forge write. Never reinterpret it as standalone input.

Resolve `LOG="$ROOT/hooks/lib/zensu-log.sh"` and set
`CURRENT_SESSION="$(CLAUDE_PLUGIN_DATA="<absolute-plugin-data>" bash "$LOG" --session-key)"`.
The helper must validate the immutable private Session Control binding. Read fresh
state with `CLAUDE_PLUGIN_DATA="<absolute-plugin-data>" bash "$LOG" --autopilot-status`. Fail closed unless all of these match exactly:

- `ownerSessionId` and `tdd.sessionId` both equal `CURRENT_SESSION`; `runId`, `tdd.attempt`, and `tdd.chainId` equal the envelope binding.
- `stage` equals both the envelope stage and `TEAM_REVIEW`.
- `evidence.pr.number` and `evidence.pr.url` equal the invoked PR URL/number, and
  `evidence.pr.headSha` equals the envelope head.
- `effects.prOpen.status == "completed"` proves that the durable PR capability finished.
- `effects.teamReview.status == "requested"` and `effects.teamReview.operationKey` equals
  the envelope operation key; `effects.teamReview.provider` is exactly `github|gitlab`.

Set `BOUND_HEAD` to the validated, lowercased `evidence.pr.headSha`; it is immutable for this
delegation. Every later checkout, remote guard, marker, and receipt comparison uses this
capability-bound value.
Set `BOUND_PROVIDER` to the validated `effects.teamReview.provider`; it is equally immutable.

Validate that the operation key itself equals
`team-review:v1:<sha256(canonical({headSha,runId}))>` using the bound lowercased head and
exact run id. Then scout the remote PR from `$REPO`: it must still be `OPEN`, its URL/number
must match durable state, and its remote head must equal the bound head. Repeat this
OPEN/current-head check immediately before the reconcile call. Any mismatch blocks; never
review a successor commit under the old capability.

Delegated mode MUST NOT ask for cast confirmation, body preview, cleanup/ref deletion, or a
next-step choice. Auto-cast the mandatory team, publish without a preview pause, remove the
temporary worktree automatically, keep the local review ref, and return the structured
receipt to Autopilot.

Any delegated repository, provider, authentication, authorization, payload-snapshot, or
product-decision failure must persist `BLOCK` with a stable generation-specific event id,
report the blocker, and stop without a question. Use the closed codes
`review-repo-unavailable`, `review-provider-unknown`, `review-auth-unavailable`,
`review-provider-mismatch`, `review-payload-unsafe`, and `review-decision-required`; never turn one of these failures
into an interactive fallback. Standalone mode retains the explicitly labeled prompts of the phases.
