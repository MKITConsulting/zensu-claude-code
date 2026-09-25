# Review Severity Rubric

This file is the single source of the severity scale every `/zensu:tdd` reviewer uses. The
delimited block below is carried verbatim by `agents/review-aspect.md`,
`agents/review-judge.md` and `agents/code-reviewer.md`, and `/zensu:tdd` step 3 prepends it,
read at run time from this file, to every repo-custom persona spawn prompt.

The scale decides what the auto-fix loop routes. CRITICAL and IMPORTANT findings route by
default, SUGGESTION findings only under `hooks.autoFixIncludeSuggestions`. While
`hooks.reviewConvergence` is enabled (the default), every re-review routes only CRITICAL findings
and IMPORTANT findings that concern the previous fix pass, and defers everything else; with
`hooks.selfReview` off it keeps every IMPORTANT finding routable (see
[configuration.md](configuration.md)). An undefined scale let every reviewer promote its own
taste to IMPORTANT, and every such finding opened another full review round.

`/zensu:pr-team-review` keeps its own P1/P2/P3 scale for forge comments. The two scales answer
the same question in different vocabularies; they are not mechanically mapped.

<!-- zensu:review-severity -->
> **Severity rubric (non-negotiable).** Rate every finding by its impact on the change under review, never by effort, taste or confidence.
> - **CRITICAL** — blocks the merge: wrong behavior on a changed path, a security flaw, data loss or corruption, a broken contract or interface, a violated acceptance criterion or requirement, a crash.
> - **IMPORTANT** — should land before the merge: a robustness gap or a missing test for behavior this change adds or alters, or a maintainability defect this change introduces.
> - **SUGGESTION** — optional: style, naming, idiom, redundancy, refactoring ideas, and alternatives that work equally well.
>
> Never rate style, naming or idiom above SUGGESTION, and never lower a CRITICAL to shorten a review. When two levels fit, choose the lower one unless the evidence shows the higher impact.
<!-- /zensu:review-severity -->
