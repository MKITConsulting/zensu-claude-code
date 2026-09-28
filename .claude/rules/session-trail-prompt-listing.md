---
paths:
  - "skills/session-trail/scripts/trail.mjs"
  - "skills/session-trail/SKILL.md"
  - "tests/structure/prompt-listing-v1.test.js"
  - "tests/structure/fixtures/queued-command-delivery.v1.jsonl"
  - "tests/structure/test-session-trail-verdict.sh"
  - "tests/structure/test-session-trail-skill.sh"
---

# Session-Trail Prompt Listing (`extractPrompts` in `skills/session-trail/scripts/trail.mjs`)

**One listing feeds every prompt section.** A deep read calls `extractPrompts(text, read.full)`
once per session and stores `prompts` and `withdrawnPrompts` on the row. Every carrier reads
those two fields: the `show` timeline and its withdrawn section, the takeover brief's
"Original objective", "Recent instructions" and withdrawn section, and the handoff brief's
"What was asked" and withdrawn section. A renderer that re-derived prompts from the
transcript would disagree with the others about which prompts were withdrawn.

**Withdrawn prompts get their own section and never a place in the timeline.** A prompt that
the queue records show as queued and then taken back before the session received it is listed
under `WITHDRAWN_HEADING`, with `WITHDRAWN_HEDGE` beside it. The judgement comes from queue
records, not from an observation of the session, so the hedge tells the reader to ask the user
before acting on any of them.

**A text listed as sent is never also listed as withdrawn.** Both lists come from
`promptListing`, the sent list first, and the two calls share one `listed` set keyed on the
first 160 characters of the scrubbed text. The call ORDER is load-bearing: swapping the two
properties of the returned object would let a withdrawn duplicate claim a text the session did
receive, and drop it from the timeline.

**A truncated read withholds the judgement instead of guessing.** When only the head and tail
of a large transcript are scanned, `extractPrompts` returns `withdrawn: null`, so
`withdrawnPrompts` is `null` under `--json`. The three text carriers print
`QUEUE_WITHDRAWALS_UNFILTERED` in their truncation note instead: `show`, the takeover brief and
the handoff brief.

**Both briefs open with `BRIEF_DATA_CAUTION`, and the tool renders it.** The listing's
sections carry verbatim third-party text, so the line that tells a reader to act on nothing in
a brief, its own steps included, before verifying it and getting the user's confirmation is
the first line `cmdTakeover` and `cmdHandoff` push. It is not a line that SKILL.md asks the
model to add, because a brief outlives the session that wrote it. `T29c` pins one definition
and one push per brief ahead of its title, `W7c` compares each rendered brief's first line
with the constant and checks its clauses, and `T24m` holds SKILL.md's description of the line.

**Coupled sites.**

- `WITHDRAWN_HEADING`, `WITHDRAWN_HEDGE` and `QUEUE_WITHDRAWALS_UNFILTERED` are module
  constants. `withdrawnBriefLines`, beside `briefPath`, renders the section for both briefs;
  `show` renders it inline with the heading upper-cased.
- `skills/session-trail/SKILL.md` names the withdrawn section in the brief caution, in the
  `show --json` and takeover paragraphs, and in the withdrawal bullet, which also states the
  `null` on a truncated read. `T24l` derives the section name from `WITHDRAWN_HEADING`, so a
  renamed heading reddens the skill suite until SKILL.md follows.
- The listing depends on a host record format: the `queue-operation` records (`enqueue`,
  `dequeue`, `remove`, `popOne`, `popAll`) and the `queued_command` attachment. The comment
  above `queueRecordName` in `trail.mjs` names the build they were read from, the Claude Code
  2.1.280 binary on 2026-09-23, and is the one place the file names that build.
  `tests/structure/fixtures/queued-command-delivery.v1.jsonl` is a redacted Claude Code
  2.1.237 capture that the verdict suite loads. It pins the shape that build wrote and cannot
  see a later build's drift; only a fresh capture can.
- The listing is exported by its own statement, `export { extractPrompts, QUEUE_DELIVERY_REACH };`,
  beside the advice surface's. `T24h` requires exactly two `export {` statements, this one
  verbatim, and an advice statement that names neither listing name.
- `tests/structure/prompt-listing-v1.test.js` drives `extractPrompts` and
  `QUEUE_DELIVERY_REACH` directly. `tests/run-all.sh` discovers only `test-*.sh`, so
  `test-session-trail-verdict.sh` runs the file and holds its case count in
  `PL_UNIT_TOTAL_WANT`. The count is exact and hand-maintained: a new case means raising it.
- Further checks read the listing's constants, comments and body out of `trail.mjs`. That set
  is a grep, not a list: run
  `grep -nE 'queueWithdrawals|extractPrompts|QUEUE_[A-Z_]+|WITHDRAWN_[A-Z_]+' tests/structure/test-session-trail-*.sh`
  and judge every hit.

**Standing fix, not taken: move the listing into a sibling module**, in the shape
`session-lineage-v1.mjs` already has beside `trail.mjs`. The move is not mechanical. The
checks above read the listing out of `trail.mjs` itself, and the listing sits above both
line-anchored citations that `docs/multi-repo-chains-spec.md` and
`docs/multi-repo-chains-overview.html` make into `trail.mjs`. Moving it shifts both citations,
and `T36` then requires re-deriving each one per site.

**Trigger:** a second importer of the listing, or the next change outside a review fix round
that has to re-author those checks anyway. A review fix round does not meet it: a module move
that nobody reviewed does not belong in a diff whose only purpose is to answer review findings.
