---
paths:
  - "hooks/plan-approved-delegate.sh"
  - "hooks/user-prompt-tdd-reminder.sh"
  - "evals/plan-approval-hook/**"
  - "tests/structure/test-plan-approved-delegate.sh"
---

# Plan-Approval Delivery Route (`hooks/plan-approved-delegate.sh`, standalone branch)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

The STANDALONE branch of the plan gate asks ONE `AskUserQuestion` naming four mutually
exclusive delivery routes — `/zensu:autopilot`, `/zensu:tdd`, `/zensu:pilot`, and implementing
directly. It replaced a yes/no question about `/zensu:tdd` alone, which left the plugin's other
two delivery routes invisible at the one moment they are relevant.

A Zensu-workflow answer is remembered for the rest of the session, a configured default answers
the question without asking, and a direct, autopilot or pilot answer is never remembered. The
session marker, the `hooks.defaultDeliveryRoute` key and the resolution ladder that decide it
are in `.claude/rules/session-delivery-route.md`.

**The DURABLE branch is untouched and must stay that way.** A plan carrying a validated
`<!-- zensu-autopilot:<run> -->` marker still emits `PLAN_APPROVED` with "Do not ask another
TDD/workflow question": Autopilot has spent its single planning gate by then, and a second
question there would break that contract.

**Two prerequisites are stated INSIDE the options rather than gating them, and the reason is
that a hook cannot check either cheaply.** `/zensu:autopilot` owns its own Phase 0, which ends
in its own `ExitPlanMode`, so choosing it after an approval costs a SECOND approval round for
the spec, the `AC-###` list and the probed recipe — and it needs an authenticated forge CLI.
`/zensu:pilot` needs an authenticated `zensu` CLI plus a feature ALREADY tracked in Zensu; its
own skill sends ad-hoc work to `/zensu:tdd` instead. Both options are offered unconditionally
and carry their cost in their own description. The ground is NOT that probing is expensive —
`hooks/session-start-banner.sh` already runs `command -v zensu`, so the PRESENCE half is cheap.
It is that a conditional option set would make the gate's own "exactly these four mutually
exclusive options and no others" contract environment-dependent and therefore unpinnable, and
that the half that actually matters — whether the CLI is AUTHENTICATED and the feature already
tracked — needs a network call this hook must not make.

**Auto Mode must NEVER select `/zensu:autopilot` OR `/zensu:pilot`, and this is the one safety
property in the section.** Autopilot pushes a branch and opens a pull request; pilot commits,
opens a pull request and mutates tracked feature state behind a per-transition confirm. TWO clauses choose a route
without asking, and saying "the non-interactive one is the only place" was the overstatement
review caught: fast-path (B) also selects without asking and carries no interactivity scope of
its own, so an earlier wording in which (C) forbade only a *default* left a headless run whose
driving prompt named the route reaching it through (B). (C) therefore OVERRIDES (B) in as many
words, and forbids selection "not as a default, not by an explicit literal, and not by any
other clause". Two further guards sit in (B) for the same reason and are not cosmetic: a route
name carrying a negation REFUSES that route rather than selecting it — the bare literal
`'autopilot'` meant `"no autopilot"` contained the token tested first — and only multi-word
forms count, because in THIS repository `"fix the autopilot state machine"` is an ordinary
sentence. `D13` in `tests/structure/test-plan-approved-delegate.sh` is the pin, and it grades a
PROPERTY rather than a spelling list: it slices BOTH the (B) and the (C) clause, requires (C) to carry
EXACTLY ONE `/zensu:autopilot` mention, the prohibition and override clauses, and no dispatch
spelling; requires (C) to carry pilot's own rationale, which the never-clause needle cannot see;
requires (B) to carry the refusal guard, the open-set marker and the multi-word rule,
AND to state the refusal BEFORE the preference arms (an offset comparison, not a presence one —
without it, moving the refusal below the autopilot arm passes every check); and requires the
remainder after both clauses to tie no non-interactive run to a route. NO slice carries an emptiness arm: the composite index guard at the top makes all three
non-empty by construction and reports `SLICE_FAILED` when it cannot. **State the residual rather than the count:** no conjunct binds the counted
(C) occurrence TO the prohibition sentence, so a (C) clause that both defaults to the route and
forbids a DIFFERENT one still passes. An earlier form rejected two hand-picked spellings and
would have passed `"default to running /zensu:autopilot"`.

**The fast-path literal order is load-bearing.** `pilot` is a SUBSTRING of `autopilot`, so the
longer literal is tested first; testing the shorter one first routes an autopilot request to
the wrong skill. The directive states the order and the reason, because the matching is done by
a model reading prose and not by a regex anyone can order.

**The ORDERING rule is encoded as a judgement, not as a fixed winner**, because which route is
best depends on the plan: Autopilot leads for a whole user-visible feature meant to reach a pull
request, Pilot for work belonging to an already-tracked feature, otherwise the Zensu workflow —
and "implement directly" is never first. That last clause is what keeps the do-nothing option
out of the recommended slot, which the repository's own best-solution-first rule forbids.

**Coupled sites that move together:** both heredocs in `hooks/plan-approved-delegate.sh` — never
one alone, and the file must keep exactly TWO `cat <<'JSON'` blocks, because the parity helper in
`tests/structure/test-tdd-vanilla-mode.sh` refuses a third; that helper's `P1` needle list, which
now carries the route literals and is what makes a one-sided edit fail, plus `P1b`-`P1b7`, which
compare mode-INDEPENDENT spans byte-for-byte because presence alone cannot see an
option ADDED to one branch — `P1b`/`P1b2` the option list, `P1b3`/`P1b4` the two dispatch arms, and
`P1b5`/`P1b6`/`P1b7` the SAFETY clauses (the `(C) OVERRIDES (B)` sentence, the refusal-first block,
and the `(B)`-internal non-interactive removal guard). The safety half was unpinned until a
mutation probe measured it: on a ONE-SIDED reword of heredoc 1, `P1b` through `P1b4` all reported
PASS while `P1b5` and `P1b7` failed, and a separate reword of the refusal block failed `P1b6`.
Then `D9pre` and `D9`-`D33` in
`tests/structure/test-plan-approved-delegate.sh`, which force the strict branch as well because
the default config resolves to the vanilla one and a single capture would grade only one heredoc;
that suite ALSO grades carriers outside the hook, and the roster is an ENUMERATION rather than a
count because a count there was wrong on the day it was written: `D17` five prose carriers
(`docs/configuration.md`, `docs/architecture.md`, `README.md`, `skills/tdd/SKILL.md`,
`skills/gauntlet-loop/SKILL.md`, with an examined-carrier floor of 5), `D18`-`D20`/`D28`/`D31`-`D33`/`D38`-`D41`
the local-only eval in `evals/plan-approval-hook/` and its README (which nothing graded before, so
its two ABSENCE assertions reported the outward-facing safety property green whenever the driven
session died), and `D26`/`D27`/`D29`/`D30` the SessionStart banner. The suite's own header carries
that enumeration too, because an edit to any of those files reddens a suite named for a different
one; `hooks/session-start-banner.sh` and `tests/structure/test-session-start-banner.sh` now carry a
pointer back, which is the half this repository keeps discovering it is missing. **`D18`-`D20` and `D26` are all SOURCE or single-arm pins, and
`D29`-`D32` are what closed the two holes that left**, both measured rather than argued. The banner's
`_ZENSU_ROUTE_QUESTION_LIVE` guard has FOUR conditions today — the flag, node, the delegate hook
file, and no configured `hooks.defaultDeliveryRoute`, which `R14` in
`tests/structure/test-delivery-route.sh` grades. When it had three, only the flag arm was graded: deleting
either the `command -v node` line or the `[ -f .../plan-approved-delegate.sh ]` line left this suite,
`test-session-start-banner.sh` AND `test-tdd-vanilla-mode.sh` fully green, so `D29`/`D30` drive the
real banner with node hidden behind a stub PATH and with the delegate hook missing from a subset
plugin root. And the eval runner's absence GATE was pinned only by its presence at the call sites:
rewriting `nonempty()` to a constant `echo PASS` reinstated the exact defect `D18`/`D20` are named
for with the suite still green, so `D31` grades the helper's BEHAVIOUR and `D32` states executably
the premise the whole design rests on — that `not_contains()` is satisfied by a transcript that was
never written. The runner cannot be sourced, so both extract the one-line helpers by text.
`D29`'s stub-PATH fixture is UNVERIFIED on Windows, so it SKIPs rather than fails when it cannot be
built — and TWO budgets are unmeasured, not one: the ubuntu shard weight in
`tests/profiles/ci-shard-weights.v1.json` still reads its pre-change value, and the WEEKLY Windows
structure shard, which this suite does reach through `ciStructureTests`, has never measured
`D30`'s `cp -R` of the whole `hooks/` subtree or `D29`'s two symlink directories at all. Take both
figures in one pass from a green run rather than estimating either — the suite gained a third verdict for it, following `H10` in
`tests/structure/test-evidence-discipline.sh`, whose own stripped-PATH case declines to redden a
weekly run for a reason unrelated to the feature. Three further constraints come from that same
precedent and each was reached by getting it wrong here first: the interpreter is resolved by
ABSOLUTE path, the two stubs are built by two link loops rather than by copying one onto the other
(macOS SIGKILLs a copied signed binary), and a shell builtin — whose `command -v` answers a bare
word — is skipped instead of being linked to itself. TWO banner literals are pinned by `D29`/`D30`
and both must move with the hook: the route promise `asks which delivery route to take`, and the
bare else-branch tip, which is matched WHOLE-LINE because it is a strict PREFIX of the
`autoTdd`-off disclosure and a substring test would let the flag arm satisfy the node arm's check; and `BNR2c` in the vanilla-mode suite, which is the only check
that reaches the four-route IF-branch tip in BOTH mode variants — `D26`/`D27`/`D29`/`D30` reach the
tips too, and `D29`/`D30` are the sole grader of the bare ELSE-branch tip, while
`P8c` greps the whole banner file and is satisfied by its pre-existing Skills line; and
`hooks/user-prompt-tdd-reminder.sh` — BOTH heredocs, TDD arms only — together with `P2`, because
§Language requires these phrase lists in lockstep and this chain edited that hook's arms; that hook
is under the SAME two-heredoc constraint, since `P2` calls the same helper. Two further carriers
this chain created: `skills/pilot/SKILL.md`'s "Do NOT Use For" bullet, which PARAPHRASES option (3)'s
prerequisite and points at both heredocs as its verbatim carrier, saying to change both together —
the direction matters, because a maintainer who greps that skill for the option text finds nothing
and could "repair" it by pasting in a third copy, and the marker instruction in
`skills/autopilot/SKILL.md`, which USED to be a hand-copied PAIR (the durable-begin site and Phase
0.D). It is no longer a pair: the durable-begin site is a pure pointer plus a pre-begin
single-marker precondition, Phase 0.D holds the one authoritative statement, and `D12`-`D15` in
`tests/structure/test-autopilot-durable-skill.sh` pin exactly that — so "pinned against nothing" no
longer holds for it.

**The durable-begin ordering is PINNED by line number and the Phase 0.D `ExitPlanMode` ordering
by text, and the two entries that follow are notes ABOUT roster members rather than roster
members themselves.** `D14` in
`tests/structure/test-autopilot-durable-skill.sh` compares LINE NUMBERS: the single-marker
precondition must appear before the `--autopilot-begin --run "$RUN_ID"` command, so reversing the
two now fails rather than passing every check. The paragraph this replaces said the ordering was
"enforced by nothing" and told the reader to check it by hand; that was true until the offset
comparison landed. What `D14` does NOT see is the ordering relative to `ExitPlanMode` itself.
`D16` in the same suite pins that half as TEXT at both sites that state it: the durable-begin
block must still say the begin succeeds before `ExitPlanMode`, and the Phase 0.D sentence that
creates the durable run immediately before `ExitPlanMode`, together with every line of the
standalone fall-through a reversal causes, must stand in the Phase 0.D slice. It pins the
instruction, never the order a model takes.
`skills/autopilot/SKILL.md` Phase 0.D is on this roster for a reason that is easy to miss: it
requires `--autopilot-begin` to run IMMEDIATELY BEFORE `ExitPlanMode`, and that ordering is the
only thing putting the durable run at `PLANNING` in time for Autopilot's OWN approval to land on
the durable branch. Reverse it — a plausible refactor, "do not mint a run the user may reject" —
and Autopilot's planning gate falls through to the standalone directive. While the route field
reads `ask`, that directive re-asks the four-route question with `/zensu:autopilot` still on it —
an approval loop that did not exist before the four-route question made `/zensu:autopilot`
reachable from this gate. With a recorded or configured route it asks nothing and sends the
Autopilot spec to `/zensu:tdd` or implements it directly (`.claude/rules/session-delivery-route.md`).
`tests/structure/test-pilot-skill.sh` is on
it for a blunter reason: its `P8d` graded a WHOLE-FILE `/zensu:pilot` count against a literal,
so the primer edit turned a CI-run suite red. It is a per-heredoc assertion now, and the needle is
the FULL route clause (`PILOT_ROUTE_CLAUSE`) rather than the bare skill name: both primer heredocs
carry a pre-existing "runs via the `/zensu:pilot` conductor skill" sentence, so a bare needle stayed
satisfied after the four-route clause was deleted from BOTH heredocs — measured on a mutant, where
the bare needle reported PASS and the clause needle FAILED.

**The strip rule and its target document are pinned too, by `D12`/`D13` in that same suite.** `D12`
requires exactly one authoritative statement (`Strip the comment, never the whole line`) and zero
restatements, so the hand-copied PAIR this section used to name cannot come back; `D13` requires the
rule to name the plan CONTENT and forbids the retired `COMMENT from the incoming` spelling, which
targeted a document the gate never reads. `D15` requires the minted-then-refused wedge to name
`/zensu:autopilot-release` beside it.

Operator-facing accounts, and the list is longer than the obvious two because every surface that
described the old yes/no question became false at once: the `plan-approved-delegate.sh`,
`autoTdd`, `tddImplementation`, `session-start-banner.sh`, `session-start-primer.sh` and
`user-prompt-tdd-reminder.sh` rows in `docs/configuration.md` — the `tddImplementation` row is the
one recording that the two ask-hooks no longer share one wording; BOTH branches of `hooks/session-start-primer.sh` (whose own `P3`
parity needles now carry the route literals) and BOTH tips in `hooks/session-start-banner.sh`,
which is the ONLY user-visible surface and was the one the whole review panel missed; the "When
to Use" bullet in `skills/tdd/SKILL.md`; the two interception paragraphs in
`skills/gauntlet-loop/SKILL.md`; the Layer 2 Mermaid edge in `docs/architecture.md`; the "Just
this change" paragraph in `README.md` — BOTH the "Just this change" paragraph and the "A plan you approve
first" bullet; `evals/plan-approval-hook/` — whose expect script must
select the Zensu-workflow option BY LABEL, never by the ordinal `1`, since the ordering rule can
put the branch-pushing route in slot 1 and a blind ordinal would take it unattended — it sends
exactly two ordinals, the `1` that approves the plan and the `1` that answers the record command's
Bash permission prompt, the latter at most once and only when `record_prompt_ok` accepts that
prompt, because the first option of both prompts is always Yes (`D39` grades the guard where tclsh
exists; `D39b` pins on every host that there are exactly two ordinal sends in any spelling, the
first before the label answer and the second before the `}` that closes the guarded branch) — and whose
RUNNER must keep three properties the PR #295 review round added: every ABSENCE assertion is gated
on a positive one (`T1.5` on `T1.0`, `T2.5` on `T2.0`, `T2.7`/`T2.8` on `T2.4`) because an empty
transcript satisfies an absence — and note that `T2.5` inlines its own `grep` instead of calling
`not_contains`, which is exactly how it escaped the first sweep, so the rule is "every absence
assertion", never "every `not_contains` call"; the subprocess watchdog is a `timeout` -> `gtimeout`
-> unwrapped ladder that ANNOUNCES the unwrapped case AFTER the header write, because that write is
a truncating `tee` and a NOTE emitted above it is erased on exactly the host the fallback exists
for — base macOS ships neither binary, the runner required neither, so both `timeout N …`
invocations exited 127, `|| true` swallowed it, and the checks
that read as the outward-facing safety evidence went green over a session that never started; and
`T2.6` grades two rendered option LABELS rather than the bare phrase `implement directly`, which a
model narrating its intent also emits. That eval is local-only and never runs in CI, which is why
`D18`-`D20` and `D28` in `tests/structure/test-plan-approved-delegate.sh` grade the runner and its
README from a suite that does — and `D18` binds the ` FAIL` VERDICT token on each not-graded arm,
because a pin on the label alone let the arms be rewritten to `PASS` with the check still green.
Every needle into that README must be LINE-LOCAL: the file wraps, and a `grep -qF` over a phrase
that crosses a break can never match, which turned `D20` red for a claim that was in fact present;
and THIS
file's own §"Autopilot Run Scope" `OWNER_SESSION_MISMATCH` bullet, which describes what a foreign
caller is asked when it falls through to the standalone policy.

**NAMED FOLLOW-UP, not done here: the two heredocs carry the route text VERBATIM TWICE.** That
duplication is why `P1b`/`P1b2` must compare mode-independent spans byte-for-byte at all, and three
consecutive fix rounds each introduced a fresh defect in that duplicated clause. This file already
ships the shape that removes the class — `emit_autopilot_context` composes the durable branch's
directive from ONE string through node — so building the mode-independent span once and
interpolating the two mode-specific fragments would make a one-sided edit structurally impossible
rather than test-detected. Not done here because it re-authors `P1`/`P1b`/`P1b2` and the
"exactly TWO `cat <<'JSON'` blocks" contract and turns the byte-for-byte pins tautological — a real
control traded for a structural guarantee, which is a decision to take deliberately rather than
mid-chain. **The pin-coverage claim above is SCOPED, because an earlier revision overstated it:**
the span comparisons reach the option list, the two dispatch arms and — since the PR #295 review
round — the three safety clauses (`P1b5`-`P1b7`); everything
else in a multi-kilobyte directive is covered by presence needles plus `D13`, so the pins are far
from tautological today. **TRIGGER:** take the seam at the next round that has to re-author
`P1`/`P1b`/`P1b2` anyway, or at a fourth one-sided defect in the duplicated span.

**The TRIGGER was evaluated in the PR #295 review round and deliberately NOT fired.** That round
ADDED to `P1`'s needle list and added `P1b5`-`P1b7`; it re-authored neither `P1b` nor `P1b2`, and it
introduced no one-sided defect in the duplicated span — every directive edit landed through a
`replace_all` over an anchor verified to occur exactly twice, or as an explicit pair for the one
mode-DEPENDENT clause (`run TDD instead` / `run the workflow instead`). Recorded so the next reader
does not have to re-derive whether the condition was met: it was checked, and it was not.

**Deliberately NOT changed — the QUESTION SHAPE, not the file:** `hooks/user-prompt-tdd-reminder.sh`
keeps its yes/no question. Its TDD arms WERE edited by this chain (intent-judging, arm order, the
untrusted-input scoping), which is why it is on the coupled-sites roster above. The route choice belongs to the moment a plan is approved; re-asking it on
every prompt while no chain is active would be four options of noise.

**Port-relevant.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` carry the same plan gate
against different harnesses and were NOT included in this change. A port owns more here than a
reworded directive: its own ROUTE VOCABULARY, because `/zensu:autopilot` and `/zensu:pilot` are
skills a port may not ship at all, so copying the four-option text there would offer routes that
do not exist; whether its harness has an `AskUserQuestion` equivalent that can carry four options;
and — the one a literal-renaming port misses — whether a route can be selected NON-INTERACTIVELY
on that host, which is the premise the whole (C)-overrides-(B) safety property rests on.

**Version: `patch`.** Walked against §"Runtime Lineage" entry by entry: no context-record or
workflow-state schema field, no strict key set, no hook added, removed or renamed and no matcher
changed, no new config key (`autoTdd` is reused), no attestation change. The hook's only output is
`additionalContext` — the ADVISORY shape the hook-inventory exemption names — and it returns no
`permissionDecision` in either direction.

**Why (C) names BOTH outward-facing routes, stated as a CRITERION so a later reader can widen or
narrow it on the test rather than on a route name:** a route is barred non-interactively when it
takes an outward-facing or externally-mutating step whose only guard is a human answer. Autopilot
meets it because `skills/autopilot/SKILL.md` declares its Phase 1 "autonomous, ZERO questions", so
the branch push is unattended once the plan is approved. Pilot meets it too, and an earlier
revision of this paragraph said the opposite — that Pilot "has no unattended outward-facing step
to guard" — which is false: it offers a commit and a pull request and it mutates tracked feature
state, and the confirm that guards each transition IS an `AskUserQuestion` answer, exactly the
control a headless run cannot supply. `/zensu:tdd` meets neither half and stays selectable.

**Known gaps, accepted and named:** the four routes are prose the model follows, not a gate, so
nothing enforces that the question is asked or that the ordering rule is honoured. The SEAM is
the same one the yes/no question always had; the BLAST RADIUS is not — the old option set could
only implement locally, while the new one adds a route that pushes a branch and opens a pull
request and one that mutates external Zensu state. Neither prerequisite is verified before its option
is shown, so a user without a tracked feature can still pick Pilot and learn the answer from that
skill's own Phase 0. `/zensu:doctor` reaches this question only through the two delivery-route rows: the
Session-state `delivery route:` row names `hooks.autoTdd=false` as the switched-off half for a
BOUND session, and the Config row names it beside a configured `hooks.defaultDeliveryRoute`. An
unbound session renders the Session-state row as not checked, so there a project that set
`autoTdd:false` without a configured default still gets no doctor signal that the route question
is off; the SessionStart banner says so instead.

**The (C) safety property has NO behavioural coverage, and this is the largest named gap.** Both
cases in `evals/plan-approval-hook/` drive an INTERACTIVE session via expect, while clause (C)
governs a run with no human to answer — so the feature's only behavioural surface does not touch
the half of its own contract that keeps an unattended run out of a branch-pushing route. A headless
`claude -p` case is the obvious addition and was NOT implemented: the hook fires only on
ExitPlanMode SUCCESS, that README already records `claude -p --permission-mode plan` auto-denying
and firing no hook, and whether any other headless permission mode can produce an APPROVED
ExitPlanMode was not established. Until it is, clause (C) is covered by `D13` alone, which grades
the emitted directive rather than a model's behaviour — and `D13`'s own detection of an unattended
escalation is a spelling list, not a property, in BOTH the `(B)` and the tail slice.
