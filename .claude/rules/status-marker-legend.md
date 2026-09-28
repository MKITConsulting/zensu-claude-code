---
paths:
  - "hooks/post-review-tdd-delegate.sh"
  - "skills/self-review/**"
  - "templates/pr-body.md"
  - "templates/autopilot-pr-body.md"
  - "skills/cover/rules/drivers.md"
  - "evals/config-gate/test-post-review-combined-summary.sh"
---

# Status-Marker Legend (CHAIN-END SUMMARY + PR bodies)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

Every status and verdict cell of the chain-end report and of the plugin-opened PR body
carries a leading marker — 🟢 good, 🟡 attention, 🔴 bad, ⚪ not applicable. **The marker
PREFIXES the value and never replaces it**, which is the whole safety property: a
verbatim-carry literal (`EDIT NOT LANDED`, `UNVERIFIED (no claims logged)`, an unresolved
`PENDING PREDICATE`, the terminus's `FULL SUITE — …` verdict, `FINDING VERIFICATION DEGRADED`,
the bypass ledger's `UNREADABLE — …`) keeps its own words after its marker. Reducing one to a bare coloured
dot deletes the disclosure while keeping the colour, which is worse than having no colour
at all.

**"Keeps its own words" is NOT "byte for byte", and the difference was a real
contradiction before it was written down.** The same cells are subject to the pipe-escaping
rule — first every backslash doubled, then every pipe as a backslash-pipe — and an escaped
cell is by construction not byte-identical to its source. The two rules were both stated as
absolutes over one cell, and a model resolving that in favour of byte-identity emits an
unescaped `|`, which splits the table row and drops exactly the verdict clause the row
exists to surface. The legend now subordinates one to the other explicitly.

**⚪ is bound to PROVENANCE, never to judgement**, and it has exactly ONE admissible case:
a requirement row the plan already marks deprecated. An earlier spelling added "or a step
this project has no equivalent of", which cites no source at all and let a skipped build or
a disabled gate be spelled ⚪ — benign-looking — where the next sentence demands 🟡. The
bound matters because `skills/autopilot/SKILL.md` states that a dropped criterion "keeps its
ID and is marked deprecated", so *dropped* and *deprecated* name one observable state
through two vocabularies whose markers are opposite. An outcome merely not run is 🟡; a
requirement this session did not implement is 🔴 dropped even if it was retired mid-session.

**The `Check | Verdict` marking rule is a VALUE-SHAPE rule, not an enumeration**, and the
difference is what keeps it total. An earlier spelling listed the OUTCOME rows by name, so
a row added later stayed unclassified and unmarked with every check green — and the FACT
rationale it carried ("a title, a count and a path are not verdicts") contradicted its own
membership, because `Tests created` and `Coverage` render as counts and were nonetheless
listed as OUTCOME rows. The rule now names only the four unmarked rows — Feature, Files
modified, Plan, Log — marks everything else, and states that a count measured AGAINST a
target is a state. Two rows were added at the same time, and their extra arms are of DIFFERENT kinds:
`Finding verification` carries a NOT-RUN arm (🟡, because the gate is config-gated and a
disabled gate must never render like a clean one — the rule this repo already applies to
`reviewerSpawnPermissionCheck`), while `Gates bypassed` carries a NOT-READABLE arm, since
its value is always read and the failure mode is an unreadable ledger rather than an absent
one. Its 🟢 is bound to the literal `none` and everything else is 🔴, so a reworded ledger
constant cannot render clean.

**EIGHT CARRIERS, and a census in prose goes stale the next time one is added — so this is
a GREP, not a list: before rewording the legend or the vocabulary, run
`grep -rlE '🟢|🟡|🔴|⚪' hooks skills templates docs agents` and judge every hit.** Use `-E`;
an earlier spelling of this instruction used a BRE alternation over `🟡 unvalidated` and
`🟡 partial`, which matched NOTHING under `docs` — the operator carrier spells the set as
`🟡 attention (partial, …)` — so the one root added to reach that carrier reached nothing,
reintroducing under the fix the exact census failure this file records for the
`zensu:code-reviewer` and `scv1_` identities. The eight as of this writing:

1. `hooks/post-review-tdd-delegate.sh` — the `COMBINED_SUMMARY_DIRECTIVE` string.
2. `skills/self-review/SKILL.md` §"### Final report" — the second renderer.
3. `docs/tdd-manager-workflow.md` §"Chain-end combined summary" — the operator account.
4. `templates/pr-body.md` — the AC `Status` column.
5. `templates/autopilot-pr-body.md` — the same column, autopilot's variant.
6. `skills/autopilot/SKILL.md` — the step-3 PR-body renderer, which restates the whole
   vocabulary, AND the Phase 2 delivery invariant, which restates the `deprecated` cell. The
   invariant was missed on the first pass and shipped the unmarked spelling for a round.
7. `skills/cover/rules/drivers.md` — the one behavioural CONSUMER, which resolves ACs from
   the PR body and must match the status WORD inside the cell rather than compare the cell
   to a bare literal.
8. `docs/review-chain.md` — the OVERRIDE contract, whose mandatory-section rows for both
   PR-body templates name the marker prefix. It is what keeps a repo override from deleting
   the rule silently, so the argument two paragraphs down depends on it; it was omitted from
   the roster while both a pin and that argument already pointed at it.

Carriers 1 and 2 must carry the legend SENTENCE byte-identically;
`evals/config-gate/test-post-review-combined-summary.sh` extracts it from the hook's
DECODED `additionalContext` and from the skill and compares, with a non-empty control on
each extraction. That pin was bite-tested: a one-word reword of the skill legend turns it
red. **That pin covers the legend SENTENCE and NOTHING BELOW IT**, because `LEGEND_RE`
terminates at `takes no marker.` — so every marker-bearing rule the two carriers share
sits after it. A separate SHARED-VOCABULARY arm closes that: it asserts the deliverable
`Status` vocabulary, the `ID | Status` vocabulary and the delimited no-Requirements
fallback line in BOTH schemas, each with a non-empty control. Two properties are
load-bearing. Both schemas are whitespace-FLATTENED first, because the skill wraps the
`ID | Status` vocabulary across two physical lines while the hook carries it on one, so
an unflattened needle would fail on the skill for a reason unrelated to drift. And the
fallback needle carries its BACKTICK DELIMITERS: both carriers delimit that literal so
the model knows where the emitted line ends, the hook's copy sits inside a `$'...'`
segment where a backtick is literal, and asserting the delimited form over the RENDERED
directive therefore proves in one check that the delimiter is present AND that it was
not eaten by command substitution. Bite-tested the same way: a one-word reword on the
SKILL side alone reports 50 PASS / 1 FAIL and restoring returns it green.
**The verbatim-literal pins are PER CARRIER and the two lists legitimately differ** —
the delegate renderer carries a `Mtime audit` row that the self-review renderer does not. Both loops are
SCOPED to the summary schema, because a file-wide presence grep is satisfied by occurrences
elsewhere in the same file and cannot fail for the reason it is written for. The
orphaned-marker predicate runs over the RENDERED directive, never the hook source: the whole
directive is one physical source line whose breaks are `\n` escapes, so a source-side scan
was structurally inert for that carrier. It prints a sentinel on a clean scan, so a throw is
distinguishable from "no orphans found".

Carrier 3 is pinned by `R17-P2b` in `tests/structure/test-tdd-manager-patches.sh`; carrier 4
by `P5a2` and carrier 5 by `P2c2` in `tests/structure/test-templates.sh` (that suite binds
`TPL_PR` to the AUTOPILOT template and `TPL_PRBODY` to the shared one — easy to invert, and
this paragraph did invert it once); `P5a4` pins both templates' PROSE rule, which is the only
thing an override author reads; `P5a5` pins carrier 6 and forbids the exact spelling
``status `deprecated` `` anywhere in it — that literal is the WHOLE needle, so an unmarked
`status: deprecated` written without backticks is NOT caught, and the claim must not be
widened past it; `P8c` in `tests/structure/test-plan-requirement-ids.sh` pins
carrier 7. `P5a3` pins the override mandatory-section rows and is anchored PER ROW, because
the phrase occurs on both and a file-wide needle stays green after a one-sided deletion.

**The legend equality is asserted on carrier 1's RENDERED form**, never on its source: the
eval extracts it from the decoded `additionalContext`, so a `\'` inside the `$'…'` string
renders as `'` and compares equal to the skill's plain apostrophe. Two constraints were
claimed here and BOTH were retired for the same reason — no mechanism observes them: a
backtick is literal inside `$'…'` and inside the double-quoted re-expansion, and an
apostrophe survives the render. Keep the sentence readable in both syntaxes by convention
if you like; do not state it here as a rule the pin enforces.

**A repo override can delete the rule from carriers 4 and 5**, because
`docs/review-chain.md` states an override REPLACES a template wholesale. The marker prefix
is therefore listed among both templates' MANDATORY SECTIONS there. Do not restate the
operator doc's claim as covering override repos without it.

**Two neighbouring vocabularies are deliberately NOT reconciled.**
`hooks/lib/zensu-doctor-report.js` declares `OK = '✅'; WARN = '⚠️'; BAD = '❌'` for the same
good/attention/bad axis. They stay separate because this set has a fourth state the doctor
has no counterpart for, and because `⚠️` is an emoji-presentation sequence whose width
misaligns a table column. A later reader should not "reconcile" the two sets.

**Known gaps, accepted and named:**

- The `## Open` table carries the same evidence literals UNMARKED while the
  `Check | Verdict` cell marks them — deliberate, because every row in `## Open` is by
  definition open, and both renderers now state that exemption so it does not live only in
  the operator doc.
- The unmarked-rows rule is pinned at the INSTRUCTION level only. Whether a model actually
  renders it is model behaviour that only a live-model eval could observe, so do not claim
  the invariant is enforced.
- **Two per-requirement vocabularies exist over the same `AC-###` ids and are NOT
  reconciled:** the chain-end `ID | Status` table uses met / partial / contradicted /
  dropped / deprecated, while the PR body uses pass / partial / unvalidated / fail /
  deprecated. They answer different questions — one is plan coverage, the other is
  validation outcome — but nothing states the mapping, and `skills/converge/SKILL.md`
  carries a THIRD (met / partial / missing / contradicted, plus `deprecated — skipped`)
  with no markers at all, offered from inside the very `## Open` section this feature
  colours. Colouring converge was considered and deliberately not done here.
- The `Gates bypassed` row names the ledger's `UNREADABLE — …` prefix, whose owning
  constants are named in §"Bypass Ledger Read Contract". The row is keyed so that 🟢 is
  exclusive to the literal `none` and EVERYTHING else is 🔴, which is what makes a reworded
  constant safe — an earlier wording here claimed it "still falls to 🔴 for any named
  escape", which was false, because a reworded unreadable line is neither `none` nor a
  named escape and matched no arm at all. Recorded here rather than in that section's
  roster.

**Version: `patch`.** Walked against §"Runtime Lineage" entry by entry: no context-record or
workflow-state schema field, no strict key set, no hook added, removed or renamed and no
matcher changed, no new config key, no attestation change, and no `permissionDecision` in
either direction — the change is directive text plus template and doc prose, which that
section classifies explicitly as a `patch`.

**Port-relevant.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were NOT included.
A port owns its own renderers and its own PR-body template, so it re-decides the vocabulary
and the pins; the marker set and the provenance bound are the portable half.
