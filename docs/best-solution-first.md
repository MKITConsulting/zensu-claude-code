# Best Solution First

The rule that governs how the plugin puts a choice in front of a human: **when you
offer the user options, the option you would defend as best for them over the long run
must be among them, and it must be first.**

This is a distinct failure from getting an answer wrong. The work can be competent, the
reasoning sound, and the outcome still bad — because the decision the user was allowed
to make was framed against them. Two shapes recur, and the second is the harder one:

- **The best option is missing.** The list contains three variants of a compromise the
  agent already settled on privately. The user picks one, believes they chose, and never
  learns that a fourth option existed.
- **The best option is present but ranked low.** First position carries an implicit
  recommendation whether or not one is written down. A user skimming under time pressure
  reads the first option as the default, so demoting the strongest answer to third place
  is a recommendation against it that nobody has to defend.

Both are usually produced by an agent optimizing honestly for the wrong thing: least
effort, smallest diff, fewest new files, closest to the existing code, cheapest to
explain. Each is a real consideration. None of them is the user's interest.

## What "best" means here

Durability, maintainability, correctness, security, and the experience of the person who
ends up using the thing — measured across the product's lifetime, not across this
session. The test is not "which option is best for me to build" but "which option would
I defend to this user in six months, when the shortcut has become their problem".

Cost is not a reason to demote or omit an option. It is a reason to state the cost. An
option described as *"the durable answer; costs a schema migration and about a day"*
gives the user a real decision. The same option quietly dropped for being expensive
gives them a fake one.

## What the rule does not say

It does not say always recommend the most elaborate solution. Sometimes the best
long-term answer genuinely is to do less — to skip the tool, delete the abstraction,
leave the code alone. When that is true, it goes first, and it goes first *on the
merits*, not because it was cheapest. The rule is about honest ranking, not about
inflating scope.

It also does not license silence about a bad list. If every option in view is a
compromise, the honest move is to say so and name what the uncompromised solution would
have been, rather than let the list imply that it is complete.

## How the rule reaches every process

**`hooks/user-prompt-best-solution-first.sh`** injects the block below as
`additionalContext` on `UserPromptSubmit` — every prompt, for the whole session — and on
`SubagentStart`, so every spawned child carries it too. It reads the block out of THIS
file at run time rather than holding its own copy, so the carrier can never drift from
the canonical text.

**Why a hook and not a skill.** A skill is loaded once and its instructions fade over a
long session as the context fills with other work. That fade is precisely correlated
with the failure this rule addresses: the further into a session an agent gets, the more
it optimizes for the smallest disturbance to what already exists. A rule that weakens
exactly when it is most needed is not a rule. The `UserPromptSubmit` leg therefore fires
on every prompt with no de-bounce band — unlike `hooks/user-prompt-context-nudge.sh`,
which is correct to fire once per threshold band, because the moment an agent is about
to frame a question is not observable in advance.

**Why the file lives under `docs/`.** `manifestRuntimeEntries` in
`hooks/lib/session-control-core-v1.js` folds `hooks`, `agents`, `skills`, `docs` and
`templates` into the Session Control runtime digest, so this file is tamper-evident
within a session — the same reason `docs/evidence-discipline.md` lives there. A
top-level `rules/` directory would not be covered, which would leave the declared source
of truth the one normative surface an installed-plugin modification could change
undetected.

**Unlike evidence discipline, this rule is switchable.** It is a directive about how to
present a decision, not a correctness invariant, so it honours the standard opt-out:
`hooks.bestSolutionFirst: false` in `.zensu/config.json` silences it entirely, resolved
through `zensu_hook_enabled` like every other hook flag. Default is enabled.

The hook fails silent by construction. An unknown event, a malformed payload, a missing
`node`, or an absent, symlinked, or malformed block exits `0` with no output, so it can
never block a prompt or a subagent spawn. The plugin-root identity guard is the one
deliberate exception: a mismatched inherited `CLAUDE_PLUGIN_ROOT` refuses with exit `2`,
exactly as its sibling hooks do.

## Condensed block

The single prose line between the two markers below is the canonical injection block.
The hook reads it from here at run time.

It must stay exactly one line between the markers. The extractor takes one line, so
re-wrapping this paragraph across two markdown lines would silently truncate every
injection to its first half — the reminder would still appear, still look correct, and
carry none of the ranking rule. The closing marker is what makes that a hard failure
rather than a quiet one, and `tests/structure/test-best-solution-first.sh` B2 is what
holds it.

<!-- zensu:best-solution-first -->
> **Best solution first (option quality).** Whenever you put choices in front of the user — an `AskUserQuestion`, a numbered list, a recommendation, a trade-off summary — the option set must CONTAIN the solution you would defend as best for the end user over the long run, and that option must come FIRST and be marked as recommended. Judge "best" by durability, maintainability, correctness, security and end-user experience across the product's whole lifetime, never by what is fastest to build, cheapest to run, easiest to explain, or closest to the current code; when the strongest option costs more effort or more time, state that cost inside its description instead of demoting or omitting it. Never let a shortcut, a do-nothing option, or the smallest possible change take the first slot by default, and never present only variants of a compromise you already settled on privately. If every option you can see is a compromise, say so explicitly and name what the uncompromised solution would be, rather than letting the list imply it is complete.
<!-- /zensu:best-solution-first -->
