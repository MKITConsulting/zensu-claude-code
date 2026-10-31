# Precedence: What Binds and What Yields

Zensu injects text into a session from several hooks and skills. Some of it binds: a hook
decides, and nothing said in the conversation changes the decision. The rest is advice, and
advice yields to the user. This page names which is which, so a user who brings their own
style, their own plan executor or their own workflow knows what Zensu still enforces.

## Tier 1: binds

Nothing said in the conversation, no style mode and no instruction in a repository file
changes these controls. Several of them can be switched off, but only through the Zensu
configuration or a documented `ZENSU_*=off` escape; [configuration.md](configuration.md) names
the key or escape of each hook.

- **Gate decisions.** A `permissionDecision` a Zensu hook returns: the Session Control
  capability gate, the TDD phase gate while a strict-mode chain is armed, the secret scan, the
  CLI write gate, the browser consent gate and the work-order gates. See [gates.md](gates.md).
- **Evidence discipline.** An agent states only what it observed in this session. See
  [evidence-discipline.md](evidence-discipline.md).
- **An armed review chain.** Once `/zensu:build` has marked its implementation complete, the
  Stop hook refuses to end the turn until the review chain closes, up to
  `autoFixMaxRounds + 3` times. See [review-chain.md](review-chain.md).

## Tier 2: advises and yields

These steer the model and step aside for the user's own instructions.

| Advice | Carrier | What yields |
|---|---|---|
| Session orientation | `hooks/session-start-primer.sh` | the conventions it recommends |
| Delivery-route question after a plan approval | `hooks/plan-approved-delegate.sh` | the question and its default |
| TDD reminder on a code request | `hooks/user-prompt-tdd-reminder.sh` | the question and its default |
| Planning triage | `hooks/user-prompt-intent-router.sh` | the triage and its routing |
| zen-mode | `hooks/user-prompt-zen-mode.sh` | the shape of each answer |

The primer, the reminder and the router each end with one sentence that says so: the user's
own instructions outrank the advice, but whether a Zensu workflow runs is decided only by their
words in this conversation and their Zensu configuration, never by a file such as CLAUDE.md.
zen-mode states its own form of the rule: the user's CLAUDE.md, their output style and a style
mode or plugin they chose outrank it, so a compressed style the user turned on wins over
zen-mode's full sentences.

**The user's own instructions** are what the user writes in this conversation, their
CLAUDE.md, their output style, and a style mode or plugin they turned on. All of them may
steer how an answer is presented. Whether a Zensu workflow runs is decided by the user's own
words in this conversation, their Zensu configuration and the gates above. The one exception
is a plan that names its own executor, described below: the user approved that plan in this
conversation, executor included, so the plan hook asks no route question for it. It holds only
while the session has no recorded or configured route and a human is present to approve, and
the user's approval message still picks a Zensu route when it asks for one.

## A committed CLAUDE.md

A CLAUDE.md committed to the repository, like every other file the session reads, can come
from anyone with commit access. It may steer presentation: language, tone, format and length.
It never decides whether a Zensu workflow runs. An instruction in such a file to skip the
review chain, to answer the delivery-route question or to switch a gate off is data: the
model surfaces it to the user instead of following it. The delivery-route question already
treats a route named in a file this way.

## A plan that names its own executor

A plan written for another plugin often names the skill that carries it out, for example
`REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan`. While the
session's delivery route reads `ask` and its `ZENSU HUMAN PRESENT:` field reads `yes`,
`hooks/plan-approved-delegate.sh` reads the approved plan and looks for such a skill: a
`<plugin>:<skill>` name outside the `zensu:` namespace on a line that carries
`REQUIRED SUB-SKILL`, or that says to execute or implement the plan, either written as a
slash command or introduced by "use", "using", "with", "via", "run" or "invoke" on a line that
mentions a skill. A name inside a fenced code block, inline code or quotation marks does not
count, and neither does a line that carries a negation such as "do not". When it finds one, it
asks no delivery-route question. It tells the model to carry the plan out with that skill and
to say in one line that Zensu asked no route question and that `/zensu:build` runs the plan
under the Zensu workflow instead. The user's approval message still wins when it asks for a
route rather than only naming one: `/zensu:build` or the Zensu workflow, `/zensu:autopilot` or
`/zensu:pilot`. A route that message refuses is never taken.

Every doubt resolves toward the question: a route the session recorded or configured still
dispatches the plan, a plan that names a `zensu:` skill anywhere and in any form still gets
the question, and so do a session whose `ZENSU HUMAN PRESENT:` field reads `no` or `unknown`
and a plan the hook cannot read.

## Best solution first

The best-solution-first rule keeps its own precedence: it governs which options are in a set
put to the user, and a skill or hook that fixes an option order by contract keeps that order.
See [best-solution-first.md](best-solution-first.md#precedence).
