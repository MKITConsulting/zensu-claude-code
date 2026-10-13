---
paths:
  - "skills/session-trail/scripts/trail.mjs"
  - "skills/session-trail/SKILL.md"
  - "skills/session-trail/references/**"
  - "tests/structure/test-session-trail-verdict.sh"
---

# Session-Trail Open Task Chips (`openTaskChips` in `skills/session-trail/scripts/trail.mjs`)

**A takeover carries the old session's open task chips, always.** A task chip is a follow-up
a session queued with `spawn_task`. Claude Desktop keeps it in that session's own record,
`claude-code-sessions/<account>/<org>/local_<id>.json`, as an entry of
`backgroundTaskSuggestions`, keyed by the desktop session id. Nothing in the desktop app, the
Zensu Session Hub or this script copies a record into another session, so a move left every
chip behind. Measured on 2026-10-11 over the takeover ledger: 48 distinct handovers whose
source had open chips (80 chips), no chip id on both sides, and only 6 handovers in which the
receiving model re-created any chips (14) on its own, from a stale `Currently pending`
snapshot it grepped out of the old transcript.

**The record is the source, never the transcript.** `ccdIndex` and `ccdApp` both remember a
record's path in `CCD_RECORD_PATHS`, the last match in walk order winning in both, and
`openTaskChips` reads that file again when a brief is built, so the list is the queue at
takeover time. It keeps every entry except an `offer`, which is a
side-session offer bound to a live waiter, and strips C0, C1 and line-separator characters
from the text. A missing store, a missing record and an unreadable record each return
`measured: false` with a reason, and both briefs print that reason instead of claiming there
were no chips.

**Coupled sites.**

- Both briefs render `openChipLines`: `cmdTakeover` after the task list, `cmdHandoff` before
  `## Open threads`. Each chip field sits in a fence one backtick longer than the longest run
  in its text, so a prompt that contains a fence cannot close it. `takeover --json` carries the
  same state as `openChips`.
- `references/takeover.md` step 4 makes re-creating the chips a step of every takeover, before
  `release`, once per chip and verbatim, and step 1 has the plan confirmation name their count.
  `references/handoff.md` flows 4 and 5 point at that step. `references/commands.md`,
  `references/disclosure.md` and the data-source table in `SKILL.md` name the carried chips.
- `CH1` to `CH6` in `tests/structure/test-session-trail-verdict.sh` pin the read, the offer
  filter, the control strip, the widened fence, both briefs and the step order in
  `references/takeover.md`.

**Known gaps, accepted and named:**

- **The originals stay open in the old session.** `dismiss_task` acts only on the calling
  session's own queue, so the receiving session cannot withdraw them. The step tells the user
  so, and they leave the old window when it is dismissed or archived.
- **Re-creating is the receiving model's tool call.** The brief and the step make it mandatory,
  but no hook verifies that every chip was queued.
- **The record shape is one desktop build's.** It was read from Claude Desktop 2.31226.1 on
  macOS; the Windows and Linux store paths remain the inferred candidates of `ccdStoreCandidates`.

**Version: `patch`.** A new `--json` key and new brief text: no schema field, strict key set,
hook, matcher, config key or attestation moves, and `session-lineage-v1.mjs` is untouched.
