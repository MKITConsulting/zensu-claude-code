# Review Severity Rubric

This file is the single source of the severity scale every `/zensu:tdd` reviewer uses. The
delimited block below is carried verbatim by `agents/review-aspect.md`,
`agents/review-judge.md` and `agents/code-reviewer.md`, and `/zensu:tdd` step 3 prepends it,
read at run time from this file, to every repo-custom persona spawn prompt.

The scale decides what the auto-fix loop routes. By default (`hooks.autoFixSeverity: critical`) only CRITICAL findings route;
every IMPORTANT finding is parked, and `/zensu:self-review` fixes it once at the end of the chain. `important` routes
CRITICAL and IMPORTANT findings, and `all`, or the legacy `hooks.autoFixIncludeSuggestions`, routes SUGGESTION findings
too. Under `important` and `all`, while `hooks.reviewConvergence` is enabled (the default), every re-review routes only
CRITICAL findings and the IMPORTANT findings the judge raised, tagged `[NOT FIXED]` or cited on code the previous fix pass
edited, and defers everything else; with `hooks.selfReview` off it keeps every IMPORTANT finding routable, under
`critical` as well (see [configuration.md](configuration.md)). While `hooks.criticalReproduction` is enabled (the default),
a CRITICAL finding of a re-review routes only when a failing test reproduces it; see `/zensu:tdd`
step 4c stage 3. An undefined scale let every reviewer promote its own
taste to IMPORTANT, and every such finding opened another full review round.

`/zensu:pr-team-review` keeps its own P1/P2/P3 scale for forge comments, and `/zensu:plan-review`
rates a plan's findings as blockers and improvements. The scales answer the same question in
different vocabularies, and nothing converts one into another; the table is a reading guide,
row by row, for anyone who meets more than one of them.

| Meaning | `/zensu:tdd` review chain | `/zensu:pr-team-review` | `/zensu:plan-review` |
|---------|---------------------------|-------------------------|----------------------|
| Must change before the merge, or before the plan is implemented | **CRITICAL** | **P1**, published as 🔴 Blocking | **blocker** (P1) |
| Should change, does not block on its own | **IMPORTANT** | **P2**, published as 🟡 Should fix | **improvement** (P2) |
| Optional | **SUGGESTION** | **P3**, a nit in the collapsed nits block, never an inline comment | a nit, listed under improvements |

The rows do not line up exactly. The PR review counts idiom as P2, while this rubric never rates
idiom above SUGGESTION. A plan review has no separate optional tier: its nits go into the
improvements list. Only this rubric decides what the auto-fix loop of a `/zensu:tdd` chain
routes.

A defect reachable only through a mode the code still supports (a fallback connection, a flag, an
environment variable, a deployment option) is still a finding. `agents/review-aspect.md` and
`agents/review-judge.md` report it with the condition that reaches it. Committed configuration that
disables the mode may lower its severity by one level, never below IMPORTANT, and never drops the
finding; that is the only case in which a defect that fits CRITICAL is rated IMPORTANT. The floor
keeps the finding fixed: by default an IMPORTANT finding is parked and `/zensu:self-review` fixes it,
while a SUGGESTION is neither routed nor a self-review candidate. A refuter in the aspect agent's verify
mode keeps such a finding `real`: the committed configuration describes one deployment, while the
code still ships the mode to every other.

<!-- zensu:review-severity -->
> **Severity rubric (non-negotiable).** Rate every finding by its impact on the change under review, never by effort, taste or confidence.
> - **CRITICAL** — blocks the merge: wrong behavior on a changed path, a security flaw, data loss or corruption, a broken contract or interface, a violated acceptance criterion or requirement, a crash.
> - **IMPORTANT** — should land before the merge: a robustness gap or a missing test for behavior this change adds or alters, or a maintainability defect this change introduces.
> - **SUGGESTION** — optional: style, naming, idiom, redundancy, refactoring ideas, and alternatives that work equally well.
>
> Never rate style, naming or idiom above SUGGESTION, and never lower a CRITICAL to shorten a review. When IMPORTANT and SUGGESTION both fit, choose SUGGESTION unless the evidence shows the higher impact; when CRITICAL and IMPORTANT both fit, choose CRITICAL.
<!-- /zensu:review-severity -->
