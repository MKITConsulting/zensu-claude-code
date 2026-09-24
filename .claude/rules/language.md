---
paths:
  - "hooks/plan-approved-delegate.sh"
  - "hooks/user-prompt-tdd-reminder.sh"
  - "evals/zen-mode-reaction/**"
  - "tests/structure/zen-anchor-assertions.test.js"
  - "tests/structure/test-zen-mode.sh"
---

# Language

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

**English only.** All code, comments, docs, commit messages, plan files,
prompts, fixture content, and pattern alternations must be in English.

Runtime `.zensu/plans/*.md` and `.zensu/logs/*.log` are gitignored HERE
(`.gitignore` ignores `.zensu/*` except `config.json`), but they are **no longer
exempt from this rule**. Consuming repos commit them as an audit trail and may
later open-source the repository, so the plugin now writes them to be
publishable: `hooks/lib/zensu-artifact-redact-v1.js` strips absolute developer
paths at write time, and `templates/tdd-plan.md` plus `skills/tdd/SKILL.md`
Phase 2 instruct the model to author both artifacts in English. A German plan
written in a German session would land in someone else's public history — which
is exactly the harm this rule exists to prevent, whether or not the file is
tracked here. Every tracked file must be English-only, and so must every
artifact the plugin emits.

**Carve-out — verbatim user-utterance match literals.** Hook directive strings
— and verbatim citations of those literals in structure-test pins, in
README/CHANGELOG feature descriptions, and in this carve-out — may contain
non-English phrases ONLY as match literals for real user input:
the TDD-preference AND delivery-route fast-paths (e.g. `'kein tdd'`, `'mit tdd'`,
`'tdd bitte'`, `'mit autopilot'`, `'mit pilot'`)
and the generic-action literals that are explicitly NOT a preference
(e.g. `'mach mal'`, `'los gehts'`, `'jetzt umsetzen'`) in
`plan-approved-delegate.sh` / `user-prompt-tdd-reminder.sh`. They exist to
recognize what multilingual users actually type, never as prose. Since the delivery-route and TDD
arms became INTENT-judged, they now ship as EXAMPLES of real user utterances inside an intent rule
rather than as a closed match set; the permission and the bound are unchanged — they stay quoted
specimens, never directive prose. Keep these
phrase lists in lockstep across every directive variant (strict and vanilla)
— never edit one variant alone.

**Second carve-out — eval grader alternations matching MODEL output.** The same
narrow allowance extends to one further SHAPE: an alternation matched against
model PROSE whose language the product does not control. It is stated as a shape
rather than as a file-and-grader list because the list was written that way once
and was wrong in both directions within a single round — it named
`anchor-failed-step.yaml`'s failure-in-the-prose grader "and nothing else" while
the German counter-grader arms (`schritt`, `von`, `aus`) sat in that file AND in
`anchor-multi-step.yaml`, which the list excluded by name. THREE members exist
today, all under `evals/zen-mode-reaction/scenarios/`: the failure-in-the-prose
grader (`fehlgeschlag`, `fehlschlag`, `gescheitert`, `rot`, `schlägt fehl`), the
`Step N of M` counter grader, which appears in both anchor scenarios, and the
anchor-prefix grader in `contract-compliance.yaml`, whose `/^(Zensu|Run|Ablauf):/`
alternation admits the German lead-in a correct reply to a German-speaking user
carries. That third one landed while this census still read "two", which is the
same drift the paragraph above records — check by grep before relying on the
count. The reason is the same in kind
but the source is the other side of the exchange: the zen-mode directive that
scenario grades says the words around the anchor's marks follow the USER's own
language, so a correct reply to a German-speaking user is German prose. An
English-only alternation would report that correct reply as a violation, which
`evals/zen-mode-reaction/README.md` names as the one outcome an eval must never
produce. The FIXTURES carry ONE narrow allowance and no more, and stating it
as none was wrong: a canned reply that exists to EXERCISE a grader alternation
this carve-out already admits may carry that alternation's own literal, because
a fixture which cannot reach the arm it grades tests nothing. The one member is
`tests/structure/zen-anchor-assertions.test.js`, and it carries the literal in TWO
shapes, not one — an earlier wording named only the first, which would have made the
second read as a violation. The first is the canned replies its anchor-prefix cases
build from `Zensu:`, `Run:` and `Ablauf:` to drive `contract-compliance.yaml`'s
`/^(Zensu|Run|Ablauf):/`. The second is a SELECTOR: the same file filters that
scenario's assertion bodies on `.includes("Ablauf")` to find WHICH grader to bind,
so the German literal is the key rather than the input. It is admitted on the same
ground — a test that cannot locate the arm it grades tests nothing — and the
distinction is worth keeping, because a selector is not prose in either direction:
it is neither authored text nor a match against model output. A THIRD carrier sits
outside this file and outside the allowance as stated: `tests/structure/test-zen-mode.sh`
drives `Ablauf: ✓a` through the shell grammar as a NEGATIVE fixture, proving the
reader refuses the very lead-in the eval admits. It qualifies for the same reason
the canned replies do — check by grep before treating this list as closed. Every other canned reply there is English, because an
ordinary fixture is authored text rather than a match literal. Extend this
carve-out only for another grader in the same position — a pattern matched
against text whose language the product does not control — and never for prose,
a comment, or a fixture.

**The MEMBERSHIP above is enforced by nothing, and neither is any arm list.** `Z26` in
`tests/structure/test-zen-mode.sh` is what makes this checkable, and its allowance is
MECHANICAL and file-independent: it exempts a match sitting inside a `/.../` regex
literal in ANY carrier it scans, which is precisely what keeps prose, comments and
fixtures violations everywhere. So the load-bearing half is enforced and the
ENUMERATION is not — a German arm added to a grader in `safety-carve-out.yaml` would
pass the guard with this paragraph unamended, and so would a further arm in an existing
one. The SHAPE is what governs; the members named above are a census taken at one
moment, not a bound the suite holds. Check by grep before relying on it, and never
strip a German arm because this paragraph did not list its grader.
