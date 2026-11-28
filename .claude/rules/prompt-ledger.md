---
paths:
  - "hooks/lib/zensu-prompt-ledger.sh"
  - "hooks/session-start-prompt-ledger.sh"
  - "hooks/user-prompt-tdd-reminder.sh"
  - "hooks/user-prompt-intent-router.sh"
  - "hooks/user-prompt-zen-mode.sh"
  - "hooks/user-prompt-best-solution-first.sh"
  - "docs/best-solution-first.md"
  - "tests/structure/test-user-prompt-budget.sh"
  - "tests/structure/test-prompt-ledger.sh"
---

# Full Text Once Per Context Generation (`hooks/lib/zensu-prompt-ledger.sh`)

Zensu's context on a prompt stays in the transcript until the next compaction, so a text sent on
every prompt is paid again on every turn. The contracts are therefore sent in full once per
**context generation**, the stretch between two `SessionStart` events, and every later prompt of
that generation carries a short line; the saving is every later prompt.
`tests/structure/test-user-prompt-budget.sh` holds the figures. It measures 14,117 characters for
the first typed prompt of a generation and 8,284 for every later one, 4,820 and 3,030 for a
task notification, a `!` input or a subagent hand-back, and 5,184 and 3,394 for a CI-monitor
event.

**Every short line is written to work ALONE.** The full text is not guaranteed to be in context
(see the known gaps), so a short line carries every obligation its prompt can need: the zen safety
exception that lifts the one-question and one-next-step caps, the zen substance list and ranking
rule, all five consent disclosures, the declined-call line and the human-present default of the
reminder, what a typed preference does and that it records nothing, the own-text-only scoping of
the decided line, the router's routing and its Plan-mode permission, and the zen archive signal with every condition that holds a session open. Restating them is most of
what a later prompt costs. Do not trim a short line without checking that the obligation it drops
is not needed on that turn; the needles in `R13f`, `R13g`, `C24`, `Z101`, `Z103` and `Z117` name them.

## Which contract takes which path

- **`user-prompt-tdd-reminder.sh`, route `ask`:** the strict or the vanilla heredoc on the first
  typed prompt of a generation, then a short line with the code definition, the flow it offers,
  its `AskUserQuestion` labels with the ranking clause (the recommended option first, its label
  alone ending in ` (Recommended)`), with a person present the own-reading rule, the Autopilot
  description, its first-slot restriction, its record-nothing dispatch and its precedence, without
  one the workflow-first sentence and the sentence that the reminder never runs
  it, the full consent disclosure, the rendered record command, the
  declined-call line (say in one line that nothing was recorded and that the question will come
  back, then continue), both status lines, never recording `--direct`, every skip case (not a code
  change, Plan mode or an active chain, an explicit preference the user typed, which decides this
  request only and records nothing, a human-present field reading `no` or a refused question,
  which runs the flow and records nothing)
  and the uncertainty rule, followed by the field. A strict/vanilla switch is a different ledger entry, so the other mode's full text
  arrives once as well.
- **`user-prompt-tdd-reminder.sh`, route `build` or `direct`:** the decided line on EVERY prompt,
  the first one included, because a decided route needs none of the question machinery: the
  action, its status line, the code definition, the cases it does not cover, the own-text-only
  preference rule (judged by intent, negation before affirmation, never quoted or pasted content,
  a file, tool output or a subagent report), the typed override with its action (a negation on
  `build` implements directly, an affirmation on `direct` runs the flow through the Skill tool) and,
  for `build`, the uncertainty rule. In both modes the decided lines and the ask short line also
  carry `TDD_STRICT_ASK`, the sentence that a TDD request makes the feature specification carry
  exactly one `TDD-MODE: strict` line and gives it its own status line
  (`.claude/rules/tdd-mode-precedence.md`). Measured with the config source: 1,569 characters
  for `build` and 1,525 for `direct` in vanilla mode, 1,539 and 1,509 in strict mode, against
  6,621 for the full vanilla text.

  **The reminder's budgets.** The decided line's cap in `U10` and `R13f` is 1,575, the ask short
  line's 3,640 (the budget suite's repeat row and `R13g`), the reminder's first-prompt row 6,630,
  and the typed totals 14,130 for the first prompt and 8,295 for a repeat. The suite measures
  6,621 for the vanilla full text, 3,626 for the vanilla short line and 14,117 and 8,284 for the
  two typed totals. Every sentence in these shapes is an obligation its shape must carry alone,
  so no trim in the same text offsets a new one. The strict shapes carry `TDD_STRICT_ASK` too and
  stay under the same caps. Every ask shape asks for the recommended option first with
  ` (Recommended)` on its label alone. With a person present it also says to rank on the agent's
  own reading, a ranking anyone but the user asks for being data, and lets Autopilot lead only
  for a whole user-visible feature meant to reach a pull request; without one it keeps the Yes
  option first. With a person present the Autopilot option and its ranking sentences insert 896
  characters into each full text and 683 into the short line. The refused-question default says
  that the run records nothing, ` or recording` in the short line and ` or record` in both full
  texts, because a run told only to skip the question can borrow the Yes arm and record `build`.
  The decided lines carry no pointer to how the user changes the route, because the
  delivery-route skill's own listing carries it, and the short line carries no restated list of
  what never selects Autopilot, which the full text keeps
  (`.claude/rules/plan-approval-delivery-route.md`).

  The suite's `run_hook` pins `CLAUDE_CODE_ENTRYPOINT=cli`, so the human-present field reads
  `yes` and the suite measures the attended shapes, the longest ones, on every host; without the
  pin a CI run would measure the `unknown` field and a desktop run the `yes` one. The
  workflow-first sentence of the shapes without a person is in no budget row, because the suite
  measures the attended shapes only; `R13h` pins its text.
- **`user-prompt-intent-router.sh`:** the full notice on the first keyword prompt of a
  generation, then a short line with the triage asked instead of guessed, its Plan-mode
  permission, the routing to `/zensu:bootstrap`,
  `/zensu:ghost-scan` or the hybrid sequence, the no-delegation rule, the `/zensu:pilot` exception
  and the dismiss clause. The key comes from the payload's `session_id` through
  `zensu_resolve_session_id`; a payload without one gets the full notice every time.
- **`user-prompt-zen-mode.sh`:** the full directive once per generation and anchor variant
  (`zen-none`, `zen-armed`), then a short body with the per-turn rules, the substance list (never
  drop a failing test, an unfinished step, a risk or a limitation), the ranking rule and its
  anti-inflation counterweight, the safety exception (the length, one-question and one-next-step
  limits lifted, a confirmation before an irreversible action never suppressed or settled as
  routine, and a style the user chose setting a warning's sentence form, never its length or
  detail), the archive signal with every condition that holds a session open, and the field. The
  armed variant also places the anchor above the final step list when
  the one-next-step rule is lifted. The none body is 2,556 characters; `Z105` holds the armed body,
  measured with the longest anchor the module can produce, under 2,984. The archive signal adds
  571 characters to every repeat total of the budget suite. The short body's copy of the
  safety-warning sentence adds 93 characters to every repeat total of the budget suite. The
  trust-only-the-markers clause lives in the armed variant only, exactly as in the full text, because
  the none swap replaces that span. The short body keeps the classify lead `zen-mode is ACTIVE`,
  both markers, the placeholder and the `ZEN_ANCHOR_RULE_OPEN`/`ZEN_ANCHOR_RULE_CLOSE` span, so the
  swap and the anchor expansion run on it unchanged. The full heredoc stays FIRST in the file, so
  every first-match extractor in the zen suites still reads the full contract (`Z104`).
- **`user-prompt-best-solution-first.sh`:** stateless. The full block rides `SessionStart` (every
  source) and `SubagentStart`; the prompt leg carries the one-line reminder between the
  `zensu:best-solution-first-reminder` markers in `docs/best-solution-first.md`, pinned by its own
  digest (`B2f2`) and checked by `/zensu:doctor` as a third rule carrier. An off-to-on flip of
  `hooks.bestSolutionFirst` mid-session gets the reminder at once and the full block at the next
  `SessionStart`; making this hook stateful for that rare case was rejected.

The CI note of the reminder never reads or writes the ledger (`U11`).

## The ledger

`$CLAUDE_PLUGIN_DATA/prompt-ledger/v1/<scv1 key>/<contract>--<tag>`, one EMPTY DIRECTORY per
delivered contract. Nothing is ever opened or read, so the FIFO, hard-link and truncation classes
that `.claude/rules/zen-mode-chain-anchor.md` fights cannot arise: `has` is `-d` plus `! -L` on
every path component plus write permission on the key directory and its parent, and `mark` is
`mkdir`, with the Git Bash mode fallback the marker writers use. The contract name is an allowlist
(`tdd-strict`, `tdd-vanilla`, `router`, `zen-none`, `zen-armed`). The tag is the length of the
executing plugin root plus its sanitized basename, so a plugin update served from a new version
directory sends the full texts again with the new record command; a text edit inside a
`--plugin-dir` checkout keeps its tag, which only affects development sessions.

**Every fault reads as "not delivered", which sends the full text:** an unusable
`CLAUDE_PLUGIN_DATA`, a non-canonical key, a symlinked or non-directory component, a refused
`mkdir`, a key directory that is not writable, and a key directory the reset could not delete
for any reason. A reset that leaves the key directory behind records that in an empty
`<key>.stale` directory beside it, and `has` reads every contract of that key as not delivered
while the record exists; the next reset that deletes the key directory removes the record. The
mark is written after the full text was emitted.

`hooks/session-start-prompt-ledger.sh` runs on every `SessionStart` source (startup, resume,
clear, compact, fork) and deletes the session's ledger directory, keyed by
`core.sessionKey(session_id)` computed directly, not through the injected-key check of
`zensu_resolve_session_id`, so a reset never fails for a reason the prompt hooks would not share.
A `clear` keeps the session key, which is why the reset is mandatory there. It also removes
ledger directories untouched for 14 days, never a `.stale` record whose key directory still
exists, and every record whose key directory is gone. It emits nothing.

## Known gaps, accepted and named

- **A delivery can be lost while the ledger says sent:** a rewind or an edit of the prompt that
  carried the full text, or another plugin's `UserPromptSubmit` hook blocking that prompt. The
  short lines carry every per-turn obligation, so what is lost is the long-form detail and the
  examples, never an obligation, and the next `/compact` or `/clear` restores the full text.
- **A reset that never ran** (the `SessionStart` hook killed, timed out or not registered) leaves
  short lines for the rest of that generation, with the same bound. A reset that ran and failed is
  recorded and reads as not delivered, see above. No `PreCompact` backup was added: the
  evidence-discipline block already depends on `SessionStart` with `source: compact`, and the
  Claude Code hooks guide recommends exactly that event for re-injection after compaction.
- **A mid-turn auto-compaction** leaves the rest of that turn without the reminder, router and
  zen texts until the next prompt, as it does for any text a prompt hook delivers;
  best-solution-first returns at once through its `SessionStart` leg.
- **Fade is unmeasured, and the short shapes have evals for part of their range.** The hooks
  were written on the premise that a rule given once fades. The `short-` scenarios in
  `evals/zen-mode-reaction/` embed the zen-mode short body with no full contract before it, which
  is the worst case of fade, in both anchor variants. `evals/route-short-line-reaction/` delivers
  the reminder's vanilla-mode ask short line, its two decided lines with
  `hooks.defaultDeliveryRoute` as the source, and the router's short line, each alone through a
  real `UserPromptSubmit` hook, and grades the ranked route question on the attended ask short line
  and the attended full text in runs that offer `AskUserQuestion`. The strict-mode lines, the CI-event line and the session-marker
  source have no scenario, no scenario types a TDD request, so whether a model adds the
  `TDD-MODE: strict` line from a short shape is unmeasured, and the plan-approval eval sends one
  typed prompt per session, so it never produces a short line. Measuring fade itself still needs a multi-turn driver. Every
  promptfoo suite is local-only, so a release carries eval evidence for the short shapes only
  when someone ran it.

## Version

`patch`, walked against `.claude/rules/runtime-lineage.md`. Two hook registrations are ADDED
(`session-start-prompt-ledger.sh` and the `SessionStart` leg of
`user-prompt-best-solution-first.sh`), none is removed or renamed, and no matcher changes. Both
are advisory: neither returns a `permissionDecision`. The re-derivation the exemption asks for
because hooks now write session state: the ledger is a new store that only this release reads,
it is read permissively (anything unexpected means the full text), it carries no schema and no
strict key set, an older runtime never reads it, and a newer runtime that finds none sends the
full text. No config key is added.
