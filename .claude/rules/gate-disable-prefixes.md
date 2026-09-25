---
paths:
  - "tests/structure/test-gauntlet-loop-skill.sh"
  - "skills/gauntlet-loop/**"
---

# Gate-Disable Prefixes (`ZENSU_*=off`) and `test-gauntlet-loop-skill.sh` G12

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

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
`ESCAPE_STEMS` now holds TEN stems; `ZENSU_BYPASS_GATE_ALLOWLIST` in
`hooks/lib/zensu-tdd-phase.sh` holds EIGHT, and `docs/configuration.md` §"Visible opt-outs"
stays the authoritative ledger roster. TWO stems are therefore in the set and not in the
ledger, and `ZENSU_SESSION_LINEAGE` is not the first: `ZENSU_AUTOPILOT` was already one,
because its escape is recorded as an audited `BLOCKED` transition rather than as a ledger
entry. Do not "reconcile" the two lists — they answer different questions, and a reader
who makes them agree has either ledgered something that escapes no gate or stopped G12
from covering a spelling a skill must not teach. A future member needs its own two
sentences here, and the counts above updated with it.
