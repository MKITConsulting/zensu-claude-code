---
paths:
  - "hooks/lib/zensu-config.sh"
  - "hooks/lib/zensu-tdd-mode.sh"
  - "hooks/lib/zensu-log.sh"
  - "skills/tdd-mode/**"
  - "tests/structure/test-tdd-mode-toggle.sh"
  - "tests/structure/test-tdd-vanilla-mode.sh"
  - "hooks/lib/zensu-delivery-route.sh"
  - "hooks/lib/zensu-marker-write.sh"
---

# TDD Mode Precedence (`hooks/lib/zensu-config.sh` + `zensu-log.sh --tdd-begin`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

The strict/vanilla implementation mode is decided by a FOUR-RANK ladder, and
`hooks/lib/zensu-log.sh`'s `--tdd-begin` branch is the only place that orders all four
ranks:

1. the session marker `/zensu:tdd-mode` records (`hooks/lib/zensu-tdd-mode.sh` writes
   `<project>/.zensu/state/tdd-mode-<session-key>.json`)
2. `--tdd-begin --tdd-mode strict` — the CALLING SKILL's own default
3. `hooks.tddImplementation`
4. vanilla

**Rank 2 is escalation-only, and that removes the one downgrade spelling a gate can
see.** The value reaches the flag from a `TDD-MODE:` line in a model-read
specification, and a spec body is not always user-authored — `/zensu:pr-fix-findings`
builds one out of PR review-comment bodies. `strict` is therefore the only accepted
value; relaxing the discipline stays rank 1, the user's own action. Widening the
whitelist re-opens a downgrade channel that lands no bypass-ledger entry.

It NARROWS the channel rather than closing it: rank 1's carrier is an ordinary file in
the project tree, and NO gate covers it while the chain is inactive — not the Edit gate
(`pre-edit-tdd-reminder.sh` returns early on an inactive chain, ahead of its
`.zensu/state/` deny) and not the Bash source-write gate (`bash-source-write-parse.js`
carries no `.zensu` rule at all). Both an `Edit`/`Write` and a shell redirect therefore
reach `{"mode":"vanilla"}` ungated. The controls there are prose — "only the user
changes the mode", in `skills/tdd-mode/SKILL.md` and `skills/pr-fix-findings/SKILL.md`
— not a gate. Say so plainly, name both channels, and do not upgrade the claim:
hardening one gate would not close it.

**Rank 2 must outrank rank 3**, or the shipped `tddImplementation: false` makes every
caller default unreachable. **Rank 1 must outrank rank 2**, or a caller overrides the
user.

**No shipped skill writes a `TDD-MODE:` line.** `/zensu:pr-fix-findings` deliberately
carries no mode of its own: its fix chains resolve ranks 1, 3 and 4 like any other run,
so they are vanilla out of the box, and it strips every `TDD-MODE:` line from the
review-comment bodies it quotes. Rank 2 is reached only through a specification whose
author asks for strict.

**The two ask-hooks make the model that author for a TDD request the user typed.**
`plan-approved-delegate.sh` and `user-prompt-tdd-reminder.sh` say that an affirmation asking
for TDD (`with tdd`, `use tdd`) ensures the `/zensu:build` specification carries exactly one
`TDD-MODE: strict` line and begins with `Executing via /zensu:build (strict TDD requested)`,
and the foreign-executor notice says the same for an approval that asks for TDD. "Exactly
one" matters because Phase 0 ignores the channel when a specification carries more than one
such line. Before this, "with tdd" took the vanilla workflow in a vanilla session while the
`/zensu:tdd-mode` description claimed the same phrase for a session switch, so a user who
asked for TDD got none. The channel stays escalation-only, and the line is never recorded.
The hooks see rank 1 only through the effective mode, which does not say whether the
session's `/zensu:tdd-mode` choice or the config made a session vanilla, so the status line
says "requested": a session whose `/zensu:tdd-mode` choice is vanilla keeps the chain
vanilla, and `skills/build/references/modes.md` has the chain say so in one line and name
the switch. Telling the model before dispatch would need each hook to read the marker state
itself, which neither does. The rule is mode-independent in every carrier and a no-op
escalation in strict mode: byte-identical in both plan-gate heredocs (`P1b6`), present in
both reminder heredocs, and in `TDD_STRICT_ASK`, which both modes append to the decided
lines and the ask short line. That also keeps a TDD request working when a hook reads
`hooks.tddImplementation` from the harness root while `--tdd-begin` reads the recorded root
and the two disagree. Pinned by `D15d` and the `D46` notice helper in
`tests/structure/test-plan-approved-delegate.sh`, `P1` and `P2t` in
`tests/structure/test-tdd-vanilla-mode.sh`, the `TDD_REQUEST_LINE` checks of `R13f` and
`R13g` in `tests/structure/test-delivery-route.sh`, and the notice test in
`tests/structure/foreign-executor-v1.test.js`.

**Two sites FREEZE the resolved mode into a chain's `vanilla` flag**, and both resolve
the same ladder for every rank that exists there: `zensu-log.sh --tdd-begin` (ranks
1-4), and the Stop-hook adoption of a deferred review (`stop-chain-enforcer.sh`
`VANILLA_SEED` → `autopilot_adopt_pending_review` → `tdd_seed_deferred_review`), which
has no caller-flag carrier and therefore resolves 1 → 3 → 4. Accepted consequence: a
chain armed strict purely through rank 2 in a default-config project seeds its adopted
deferred-review generation vanilla. Everything downstream — the edit gate, the Stop legend,
`--mode` — reads the FROZEN flag and never the marker, so a mid-chain switch changes
nothing. Say "the next chain", never "this session".

**`/zensu:tdd-mode --status` is the ONE reader that consults both**, and it is not a
counter-example to the rule above — it exists to report the rule. It resolves the session
mode from the marker (ranks 1 → 3 → 4) and then reads the running chain's FROZEN flag via
`tdd_state_file` / `tdd_session_active` / `tdd_vanilla_mode`, appending a disclosure when
the two disagree. That makes it a fourth frozen-flag reader, so a change to the flag's
name, shape or accessors lands here as well as in the three above. It degrades to the
resolved-mode answer when the phase library cannot be sourced, because the source happens
after the base line is computed — a load fault loses the disclosure, never the mode.

**Effective vs configured is a deliberate split.** `plan-approved-delegate.sh`,
`user-prompt-tdd-reminder.sh` and the Stop seed call `zensu_tdd_strict_effective`
(marker over config); `session-start-banner.sh` and `session-start-primer.sh` stay on
`zensu_tdd_strict_enabled` BY DESIGN. A session with a new key has no marker yet, so an
"effective" read there would return the config anyway; a marker that a `clear` keeps under
the same key is reported by `/zensu:tdd-mode --status` and the `mode:` echo at
`--tdd-begin`, never by these two.
A directive that names a cause must name the one that actually decided: after the
switch to the effective mode, the vanilla branches may not assert
`hooks.tddImplementation=false`.

Moving together with the ladder: `zensu_tdd_mode_marker_path` / `zensu_tdd_mode_state_linked`
/ `zensu_tdd_mode_marker_state` / `zensu_tdd_mode_override` / `zensu_tdd_strict_effective`
(the single path template and parse — the writer sources
them rather than re-spelling, as zen-mode's hook, helper and doctor probe source
`zen_marker_path` and `zen_mode_resolve` from `hooks/lib/zensu-zen-shared.sh`). `zensu_tdd_mode_marker_state` owns the marker VOCABULARY —
`strict|vanilla|released|none`, four values, where `released` is a present `{"mode":"auto"}`
and `none` is absence-or-unreadable — and it is the only owner of that vocabulary, while the
PARSE is `_zensu_marker_one_line_value`, ONE bounded reader shared by every session marker
`zensu-config.sh` owns (`.claude/rules/session-delivery-route.md` names them); `zensu_tdd_mode_override` is a
total reduction over it that collapses `released|none` to `auto`, so its callers keep a
three-value contract and the two cannot drift. `zensu_tdd_mode_state_linked` is the symlink
guard for the `.zensu` / state-dir / marker triple plus an optional extra leaf, and the ONE
writer, `zensu_write_session_marker` in `hooks/lib/zensu-marker-write.sh`, calls the reader's
copy rather than spelling its own; every helper writes through it (`zensu-tdd-mode.sh`,
`zensu-delivery-route.sh`, `zensu-full-suite.sh` and `zensu-linked-session.sh`, which writes the inherited-route and
linked-session markers). It guards every marker `zensu-config.sh` owns under a name that predates the second one
(reader `zensu_delivery_route_marker_state`, helper `zensu-delivery-route.sh`); its pre-rename
re-check is
deliberately a SECOND call, because that duplication is the TOCTOU defense and collapsing the
two would remove it. A new marker value lands in the reader, in the reduction, and in
`--status`'s label set. Then `skills/pr-fix-findings/SKILL.md` step 4, which restates the
ranks its fix chains follow and strips every `TDD-MODE:` line, the `TDD-MODE:` parser
(`skills/build/SKILL.md` Phase 0 + Mandatory command protocol step 1), that same skill's
§"Vanilla Implementation Mode" in `references/modes.md`, which states the ladder a THIRD time for the model,
`skills/tdd-mode/SKILL.md`, `docs/configuration.md` (the `tddImplementation` row),
`docs/gates.md` §Activation, `docs/build-workflow.md` §Vanilla implementation mode,
and `docs/architecture.md`. The per-request TDD rule and its rank-1 exception move together
too: the TDD sub-arm of both ask-hooks and of `hooks/lib/foreign-executor-v1.js`, the
plan-gate and reminder rows of `docs/configuration.md`, the `/zensu:build` row of
`README.md`, precedence item 1 of `skills/delivery-route/SKILL.md` and of
`.claude/rules/session-delivery-route.md`, and the body note of `skills/tdd-mode/SKILL.md`.
A site left behind does not fail closed — it leaves a stale
rank list the model reads while the helper resolves a different one.

**A second site re-encodes the ORDER**, not just the ladder's prose: `--status` in
`hooks/lib/zensu-tdd-mode.sh` resolves rank 1 → 3 → 4 itself to report provenance. It
is structurally blind to rank 2, and so are the two pre-begin directive hooks — a caller
flag exists only at the moment of arming. So `--status` can answer `vanilla (config)`
while the next run whose specification carries `TDD-MODE: strict` legitimately arms strict; the `mode:` echo at
`--tdd-begin` is the only authoritative report. A new rank, or a fourth marker value,
lands in `--tdd-begin`, in `zensu_tdd_strict_effective` AND here.
`tests/structure/test-tdd-mode-toggle.sh` pins the ladder and the fail-safes;
`test-tdd-vanilla-mode.sh` E3/E3b pin that the freeze survives a marker flip.

**Known gap:** no `/zensu:doctor` row reports the marker or a chain's frozen `vanilla`
flag, so a session-scoped choice is visible only in the `--tdd-begin` echo and in
`/zensu:tdd-mode --status`. Do not claim doctor visibility until that row exists.
