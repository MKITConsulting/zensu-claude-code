# Partial criteria and the user's consent

This file owns what `partial` means in a review chain, where consent to close a `partial`
criterion comes from, the ONE question with its options, and the `## Manual Acceptance` row.
`/zensu:verify-feature --chain`, `/zensu:build` step 6d, `/zensu:self-review` and the closing
directive of a chain without the self-review stage apply it as written.

## What `partial` means

A criterion is `partial` only when this environment cannot observe it: it needs credentials, an
account, a non-loopback host or a signed build, or the driver that observes it cannot run here
(no `playwright-cli`, no simulator). No code change turns it, so it is never a fix step. A
criterion the run could observe but did not prove is not `partial`: verify it again, or record
`fail` when what was observed contradicts it.

## Where consent comes from

1. **A Manual Acceptance row.** The plan's `## Manual Acceptance` table lists the criterion with
   the user's consent, and the row's reason names the same cause category as its `partial`
   record. Apply it without asking. A row that names another category does not cover this gap:
   ask.
2. **The user's answer to the ONE question** below, asked when the gap is found.

Nothing else is consent: not an answer about another criterion, and not a guess about what the
user would accept.

Consent binds only a chain whose terminus can take it. When the `--acceptance-status` summary or
the terminus refusal ends with `review:` or `tree:` where `accept:` would stand, a zero-change
self-review ticket or a tree the gate cannot fingerprint binds no consent: ask nothing, never pass
`--accept-partial`, and report the line.

## The ONE question

Ask ONE `AskUserQuestion` that names each criterion and why this environment cannot observe it,
with these options in this order:

- **Provide access now**: a visible manual login, a test account, a service the user starts, or
  a driver the user installs. Verify the criterion again once the user is done.
- **Accept as partial**: the criterion closes with `--accept-partial` for exactly those ids, after
  its `## Manual Acceptance` row is written.
- **Leave the chain open**: the criterion stays `partial` with its reason, and the chain stays
  open.

Never offer, set or mention a way to switch the acceptance gate off.

In chain mode, `/zensu:verify-feature` records a criterion the user cannot unblock now `partial`
with its cause. After **Provide access now** it verifies the criterion again and records that
verdict. It names the answer in its report. Whichever stage receives an **Accept as partial**
answer, from that report or from its own question, writes the row at once, `/zensu:build` step
6d included, so a later stage applies the row without asking again. The stage that closes the
chain passes `--accept-partial`.

## The Manual Acceptance row

The row takes the shape of the `## Manual Acceptance` table in the plugin's
`templates/zensu-plan.md`, publication rule included: plans are committed and may be published,
so the Consent cell names where and when the consent was given, never a person, an account, an
email address or an internal hostname. Its reason cell names the cause category of the
`partial` record, one of those this file lists, so a row written while planning matches the
record a later run writes. Write one row per accepted criterion before the `--accept-partial`
close, so the check a person owes before release reaches the plan.
