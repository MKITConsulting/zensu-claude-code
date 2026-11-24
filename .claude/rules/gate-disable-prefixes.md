---
paths:
  - "tests/structure/test-gauntlet-loop-skill.sh"
  - "skills/gauntlet-loop/**"
  - "tests/structure/test-escape-wording.sh"
  - "hooks/checks/pre-bash-zensu-gate.sh"
  - "hooks/checks/pre-edit-tdd-reminder.sh"
  - "hooks/checks/pre-bash-source-write-gate.sh"
  - "hooks/lib/bash-source-write-parse.js"
  - "hooks/checks/pre-write-secret-scan.sh"
---

# Gate-Disable Prefixes (`ZENSU_*=off`), `test-gauntlet-loop-skill.sh` G12 and `test-escape-wording.sh`

_Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

**Introducing a new `ZENSU_<NAME>=off` escape means editing a skill test in the same
commit.** `tests/structure/test-gauntlet-loop-skill.sh` G12 scans `skills/gauntlet-loop/`
for any gate-disable prefix, because a prompt carrier that teaches one hands the model a
hatch that lands no bypass-ledger entry. A negative scan is only as wide as its
alternation, so G12 builds its pattern from a hardcoded `ESCAPE_STEMS` list, and its
`G12a` arm re-derives the set from `hooks/`, `docs/` and `skills/` and FAILS when the two
disagree.

That makes the coupling run in an unobvious direction: an ordinary change under `docs/`,
`hooks/` or `skills/` that adds — or removes the last occurrence of — such a literal turns a suite
named for the gauntlet-loop skill red, and the remedy is to edit `ESCAPE_STEMS`, not the
file you were working on. The message names both sets so the diagnosis is in the failure
itself, but nothing points at it from the side that changes.

It is not hypothetical. `ZENSU_REQUIREMENTS_GATE=off` arrived with the
plan-requirements completion gate and was caught on the next merge, by exactly this arm.

Two properties worth keeping when touching G12: the derivation carries the same quote
tolerance as the pattern it validates (the gates compare after shell quote removal, so
`ZENSU_CHAIN='off'` disables one at runtime and a bare `=off` derivation is blind to it),
and an EMPTY derivation is a FAIL rather than a skip — a swallowed `grep -r` failure used
to read as agreement while the control block still printed PASS.

**Not every member of this set is a gate.** `ZENSU_SESSION_LINEAGE=off` (`skills/session-trail/scripts/trail.mjs`)
refuses every session-lineage ledger write and is a PRIVACY control: it disables no gate,
widens no capability, and deliberately records **no** bypass-ledger entry — the ledger
exists so that everything rendered under "Gates bypassed" is a gate that was escaped, and
adding this would make that line false. It is in `ESCAPE_STEMS` because the set is derived
mechanically from every `ZENSU_*=off` literal under `hooks/`, `docs/` and `skills/`, and
because G12's own purpose — a prompt carrier must never TEACH one of these spellings —
applies to it exactly as it does to the gates. So membership here says something about the
SPELLING, never about what the variable does.

**State the two counts, because they are NOT the same number and the gap is the point.**
`ESCAPE_STEMS` now holds ELEVEN stems; `ZENSU_BYPASS_GATE_ALLOWLIST` in
`hooks/lib/zensu-tdd-phase.sh` holds TEN escape names plus the consented gap `acceptance-partial`,
which is no `ZENSU_*=off` spelling and so no stem, and `docs/configuration.md` §"Visible opt-outs"
stays the authoritative ledger roster. TWO stems are therefore in the set and not in the
ledger, and `ZENSU_SESSION_LINEAGE` is not the first: `ZENSU_AUTOPILOT` was already one,
because its escape is recorded as an audited `BLOCKED` transition rather than as a ledger
entry. Do not "reconcile" the two lists — they answer different questions, and a reader
who makes them agree has either ledgered something that escapes no gate or stopped G12
from covering a spelling a skill must not teach. ONE name runs the other way:
`ZENSU_TEST_WITNESS` is in the ledger allowlist and not in the set. Its gate was removed
together with the Bash witness, so no source spells its escape any more and G12a would
fail on a stem nothing derives; the allowlist keeps it because the ledger write path
filters existing entries through the allowlist, and dropping it would erase it from every
ledger an older installation wrote. `acceptance-partial` is in the allowlist and not in the
set for a different reason: it records a gap the user consented to at the terminus
(`--chain-done --accept-partial`), not an escape, and `--bypass-note` refuses it. A future
member needs its own two sentences here, and the counts above updated with it.

## Model-facing text names no escape (`tests/structure/test-escape-wording.sh`)

Agents kept proposing to switch gates off because text they read named the escape as the
hand-off. The rule, a user decision applied to the chain-closing path in v0.40.0 and then to every
runtime file: the remedy stays, and no text the model reads names an escape, as an option, a
hand-off or a prohibition. A generic prohibition that names none stays ("Do not run it, with or
without a prefix", "never offer, set or mention a way to switch the gate off"). Three kinds of text
keep naming one: a disclosure printed only after the user set the escape, an operator-facing notice
(stderr of a Stop hook that exits 0, `stop_notice`, `systemMessage`; `B4a` in
`test-stop-session-binding-recovery.sh`), and the `skills/zensu-help` routing row, which answers the
user's own question. A config key that opted a gate in may stay named as the reason it runs, never
as the switch-off: the source-write gate's `OPT_IN_NOTE` names `hooks.bashWriteGate` and leaves an
intended command to the user.

**The lint walks every runtime file.** It reads every file under `hooks/`, `skills/`, `agents/`,
`templates/` and `scripts/` and under each `plugins/<name>/` root of those names, judges message
literals in shell, JS and TS (a heredoc body and a template literal's continuation line as prose)
and every line of every other file. `docs/` is left out on purpose: the operator rows and the
escape roster live there (`docs/configuration.md` §"Visible opt-outs"). `W0` requires every tracked
file under those roots to be read (without git, at least 250 files), every root to contribute, no
symbolic link, and the anchor list: the former explicit file list and the files this rule was
applied to. A code line is exempt only through a recognized read: a `${NAME…}` or `$NAME` read (in
a shell file outside single quotes and not after a backslash, in JS and TS outside a quoted string,
where a template literal's `${NAME}` counts and its bare `$NAME` text does not), an `env.NAME` or
`env['NAME']` read, a property read outside a string literal, a whole-name literal that is compared,
assigned or looked up (`.includes`, `.indexOf`, `.has`, or an array literal before one of them), a
`tdd_record_bypass`, `tdd_record_bypass_payload` or `tdd_bypass_recorded` argument, a `__bypass__`
ledger marker, and a shell case-pattern arm. Comment lines are skipped: a line led by `#`, `//`,
`/*`, or a `*` followed by a blank, a `/` or the end of the line, except that a shell line opening
a case pattern (`*)`, `/*)`) is a case arm and is judged. The scan prints a `findings=` count and
marks each finding line, so `W1` and `W3` cannot lose a path that holds a blank or an `=`.

**The allowlists are reviewed entries, and a stale one fails.** `DISCLOSURES` holds the `escaped`
lines, the `STEM UNCHECKED` lines, the edit-landing cause and the unrecognized-value notice of both
evidence gates, each scoped to the files that print it (`hooks/lib/zensu-log.sh`,
`hooks/lib/evidence-run-v1.js`, `hooks/lib/acceptance-verify-v1.js`), because an entry exempts its
whole line. `SCOPED` holds file-scoped entries: the three operator notice forms
of `hooks/stop-chain-enforcer.sh`, the zensu-help routing row, and two value positions,
`ZENSU_BYPASS_GATE_ALLOWLIST` in `zensu-tdd-phase.sh` and the `bypassed.push` lines of
`bash-source-write-parse.js`. `W2` fails when an entry matches no shipped line, `W8` proves the
stale report, and `W3` and `W4` bite every recognizer and the file scoping on fixtures. A new
mention outside them fails `W1`: reword it, and add an entry only for a disclosure, an operator
notice or a value position, never for text the model reads as advice.

**Vocabulary, and what it leaves to the gate suites.** The names are `ZENSU_*_GATE`, `ZENSU_CHAIN`,
`ZENSU_SECRET_SCAN`, `ZENSU_TEST_WITNESS` and the two `evidence.*Gate` keys. `ZENSU_AUTOPILOT` is not
among them, because the same word opens the Autopilot protocol lines (`ZENSU_AUTOPILOT
PLAN_APPROVED …`), and neither is `ZENSU_SESSION_LINEAGE`, a privacy control session-trail offers
the user. `W9` holds the vocabulary against `ESCAPE_STEMS` of `test-gauntlet-loop-skill.sh`: every
stem there is a name here or one of those two named exclusions, and an exclusion that is no stem
any more fails. A config-key switch-off and an unnamed description of an escape are not matched, so
the suite of the gate that carried one pins its absence: `W5b` and `W218` in
`test-bash-source-write-gate.sh` the `hooks.bashWriteGate` switch-off, `B19b`, `B37b`, `B40y` and
`B61b` in `test-bash-zensu-gate.sh` the CLI gate's unnamed descriptions ("the per-command gate
escape", "one-off"), and `F1c` and `F1d` in `test-secret-scan-gate.sh` the secret scan's pointer to
its documented opt-out. No model-facing text carries an `mcpGate` or `hooks.chainEnforcer`
switch-off, so neither has a pin; `hooks.chainEnforcer` appears only in the Stop hook's operator
notice. One config-key hand-off stays in review-chain text: when the host delivers no reviewer
report, the review-packet gate asks the user whether to set `hooks.reviewPacketGate` to false
(`hooks/lib/review-gate-v1.js`, `.claude/rules/review-packet-gate.md`), a decision it leaves to the
person.

**Coupled reader and known gaps.** The scan reads shell files through `shellLines` of
`tests/structure/lib-unit-registry.js`, the unit-file driver audit's reader, and takes its heredoc
bodies as prose, so a change to that reader changes which shell lines this lint judges
(`.claude/rules/unit-file-registry.md`). Accepted limits: a name reached through a constant is
exempt as an assigned whole name (`EDIT_LANDING_ESCAPE` in `hooks/lib/review-packet-v1.js` builds a
disclosure that way, and a remedy built the same way would pass); an `env.NAME` read is exempt
anywhere on its line, a string that spells one included; lines are judged one at a time, so a
quoted string that spans lines is judged as code on its later lines; and a name built at run time
from pieces outside the shapes `W3` covers passes.

**Version: `patch`.** Deny, directive and skill wording only: no schema field, strict key set,
hook, matcher, config key or attestation moves, and every gate allows and denies what it did.
