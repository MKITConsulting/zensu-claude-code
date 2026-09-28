---
paths:
  - "hooks/session-start-evidence-discipline.sh"
  - "hooks/user-prompt-best-solution-first.sh"
  - "hooks/lib/rule-block-v1.js"
  - "docs/evidence-discipline.md"
  - "docs/best-solution-first.md"
  - "tests/structure/test-evidence-discipline.sh"
  - "tests/structure/test-best-solution-first.sh"
---

# Marker-Block Carriers (`session-start-evidence-discipline.sh` + `user-prompt-best-solution-first.sh`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

Two hooks inject a rule read at run time from a one-line marker block under `docs/`. They share
ONE hardened reader, ONE `MAX_FILE` and ONE `MAX_BLOCK`, and they are NOT interchangeable:

- `session-start-evidence-discipline.sh` — SessionStart + SubagentStart, block in
  `docs/evidence-discipline.md`, **no opt-out flag**. Nothing silences it.
- `user-prompt-best-solution-first.sh` — UserPromptSubmit + SubagentStart, block in
  `docs/best-solution-first.md`, opt-out `hooks.bestSolutionFirst`. It additionally loads
  `zensu-config.sh`, which is its only extra refusal path.

**A THIRD consumer reads the same block, and it must never grow its own parser.**
`ruleCarrierRows` in `hooks/lib/zensu-doctor-report.js` is the operator's only signal that a
carrier stopped injecting: build-time pins govern this repository's copy, never an installed
tree, and every run-time refusal but the plugin-root mismatch is silent. It `require`s
`rule-block-v1.js` LAZILY and guarded, exactly as `reviewerDenialRows` does — a load fault costs
that row, not the whole report — and a hand-copied marker parse there would report on bytes the
hook would have refused. `RULE_CARRIERS` re-encodes the two `doc` paths and both marker pairs, so
a renamed rule file or a reworded marker lands here as well as in the hook. `RULE_REASON_TEXT`
re-encodes the module's `REASONS` values: one added there and not here renders as unrecognized
rather than as health, which is the safe direction and is deliberate. `P5a`-`P5h` in
`tests/structure/test-doctor.sh` pin that all four states — intact, suppressed by flag, refused,
and not-checked — render DIFFERENTLY from one another; a row that rendered unconditionally would
reinstate the silence it exists to remove. That suite's green fixture copies the real module and
both real docs rather than stubbing them, so it cannot go green against a parser nothing ships.

**`MAX_BLOCK` is declared twice, hand-copied once more, and bound by three checks.** The two
declarations are the hooks; the one hand copy is `tests/structure/test-best-solution-first.sh`
(a suite variable, bound by B2h). Do not spell the number anywhere else — name the constant.
The prose copy in `docs/architecture.md` was removed for exactly that reason. H4e in
`test-evidence-discipline.sh` (which reads the value out of the SIBLING file rather than
hand-copying it, and therefore fails if that file is renamed — deliberate: the alternative is a
third copy of the number), B2h in `test-best-solution-first.sh`, and the cross-carrier equality
in `test-windows-portability-guards.sh`. `MAX_FILE` is bound only by that last one, because both
per-file pins grep its declaration without the value.

**The cross-carrier comparison extracts a RANGE and its boundaries are load-bearing.** It strips
full-line comments, then selects from `const pre = fs.lstatSync(rulePath);` to the enforcement
`block.length > MAX_BLOCK`, so it covers the hardened reader, the marker-position parse and the
bound's use. Two properties keep it from going vacuous, and both were learned by probe:

1. **The end address is a substring match**, so a trailing `// … block.length > MAX_BLOCK …` on a
   code line survives the full-line strip and truncates the range. Added to BOTH carriers it kept
   the bodies equal and satisfied a bare `grep` for the needle, with both enforcements deleted and
   the suite fully green. The probe and its numbers live in the comment above the check; do not
   re-author them here. What closes it: the extracted body's LAST LINE must be the enforcement
   statement, and each literal must occur exactly ONCE per carrier — the count is what removes
   the class rather than the probed spellings, and it also covers a shadowing redeclaration
   between `const rulePath` and `const pre`, which is inside the hook's `try` block.
2. **Comment TEXT inside the range is deliberately not compared.** That is what lets the two
   carriers carry differently-worded notes on the shared constant; it also means a one-sided edit
   to an in-range comment no longer fails the check. Stated, not accidental.

**The refusal set is prose in EIGHT places and forks easily** — one shared reader, eight
restatements, and no test pins the wording. It is a hand sweep, so the roster is the control:

- `hooks/session-start-evidence-discipline.sh` (header)
- `hooks/user-prompt-best-solution-first.sh` (header)
- `docs/architecture.md` §Evidence Discipline
- `docs/architecture.md` §Best Solution First
- `docs/evidence-discipline.md`
- `docs/best-solution-first.md`
- `docs/configuration.md` — the evidence-discipline hook row
- `docs/configuration.md` — the best-solution-first hook row

The shape: an unknown event, a malformed payload, and a rule file that is absent, symlinked,
swapped between the pre-check and the open, oversized in FILE or in BLOCK, short-read, or
malformed — plus a missing `node`, and for the sibling its config
library. Every one exits `0` silently. The only branch that REPORTS a cause is a mismatched inherited
`CLAUDE_PLUGIN_ROOT`, which exits `2` on stderr; the plugin-root RESOLUTION failure a line above
it also exits `2` but prints nothing, so it is neither silent-zero nor operator-visible. A site that names only the file ceiling sends an operator
whose rule silently stopped injecting to check the file size and conclude the hook is broken. The
count above drifted once already (it read SEVEN while listing eight), which is exactly how a site
gets missed.

**A review ceiling, not a ratio.** Each suite carries a `REVIEW_CEILING` below the `MAX_BLOCK`
fail-safe so the next clause is argued rather than absorbed. The criterion is ABSOLUTE headroom,
identical on both carriers, never a preserved percentage: ratio parity hands the larger slack to
whichever block is bigger and self-erodes as the block grows.

**`REVIEW_HEADROOM` is enforced ONE-SIDEDLY, in the suite that owns the ceiling.** Each owning
suite asserts that its remaining slack — `REVIEW_CEILING` minus the measured block — never
EXCEEDS the declared headroom, and the cross-carrier arm compares the two declared headrooms so
they cannot drift apart. Both earlier shapes were wrong and are recorded so neither is retried:
deriving the ceiling from the live block over-constrained it (with both ceilings fixed it reduces
to a constraint on the two rule TEXTS' length difference that no file states, and a
one-character edit turned the guards suite red at 88 against 89), while comparing two inert
literals constrained nothing at all (raising one ceiling from 900 to 1000 left every check green
while the realized headroom became 189 against 89 — measured, both times). One-sided and
per-suite is what avoids both: block growth only shrinks the slack and stays green, and a
unilateral ceiling raise fails in the suite where the edit was made. Accepted consequence: a
block that shrinks far below its ceiling also trips it, which is correct — a ceiling that has
drifted away from its text has stopped being a tripwire.

Provenance of the number, stated because the comments call it "roughly one clause": 89 is the
remainder of the evidence carrier's pre-existing round ceiling (900 minus 811), retained rather
than re-derived, and the sibling moved from 1800 to 1741 to match it. It admits the shorter
sentences of these blocks and not the longer ones. That is a defensible policy but it is not a
measurement of a clause; re-deriving it from the two blocks' actual sentence lengths is open.

Both suites measure through `node`, not `${#var}`: bash counts bytes under `LC_ALL=C` and code
points otherwise, while the hooks compare `String.length` — UTF-16 code units — and both blocks
carry non-ASCII characters. `test-evidence-discipline.sh` passes identically under `LC_ALL=C`,
which is the claim tested rather than asserted.

`test-evidence-discipline.sh` C6 pins the one measured figure in `docs/architecture.md` — the emitted
character length — against a value it derives. C5 works the other way for the carrier population: it
FORBIDS restating the total as a literal and requires the prose to name `EXPECTED_AGENTS` and
`EXPECTED_SKILLS` instead, because a numeral there goes stale on every new skill. Both directions were
learned the hard way — C5 first pinned the numeral, and the count moved from 32 to 33 in a merge before
this branch even landed. Stated so the sentence is not read as covering the pair: the SIBLING's figures in
the same document — its emitted length and the per-turn total derived from it — are NOT pinned. The suite is absent from `tests/profiles/windows-ci.v1.json`, so it never runs on
the Windows PR shard; it IS in `ciStructureTests`, which the weekly Windows Safety structure
shards execute.
