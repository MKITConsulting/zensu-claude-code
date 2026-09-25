---
paths:
  - "skills/session-trail/scripts/trail.mjs"
  - "skills/session-trail/SKILL.md"
  - "tests/structure/worktree-advice-v1.test.js"
  - "tests/structure/test-session-trail-verdict.sh"
  - "tests/structure/test-session-trail-skill.sh"
---

# Takeover Destination (`worktreeAdvice` in `skills/session-trail/scripts/trail.mjs`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

**A THIRD session-trail axis, and the one most easily confused with the other two.**
§"Git Mutation Tables" tracks the WRITE-ANCHOR contract — *may I write there* — in NINE
carriers (that section enumerates nine; this clause read "six" for a release, and the phrase
wraps across two lines, which is why a line-local grep for it found nothing). §"Session Lineage Ledger" tracks a chain of sessions handing work to each
other. This one asks *will the directory still exist while I work in it*, and it shares
no code with either. All three live in the same skill; a change to one lands in none of
the others.

**The answer is now the same on every arm: a worktree of the taker's OWN.** There used
to be one exception — an already-archived session whose directory had survived was
adopted in place — and it was the worst arm to except rather than the safest. A survivor
is the tree `git worktree remove` refused on, and 37 of 40 sampled survivors were dirty,
so a takeover's first commit very often removes the condition that kept it alive.
**That is a correlation over 40 samples, and the wording has to stay one:** "close to by
construction" asserted a MECHANISM the sample does not support, and it stood here and in
`SKILL.md` while the emitted text hedged it correctly as "almost always" — a maintainer-
facing overstatement above a user-facing statement that was already right. SKILL.md §6
measures the other half of the shape: 498 of 657 archived worktree-sessions lost their
directory. The arms now decide only what to SAY, never whether to stay — an arm that
returns without a `git worktree add` line has reintroduced the defect, which is what
`WT8k` grades over a source-derived roster of all eight fixtures rather than a hand list.
`WT8L`/`WT8L2` grade the half `WT8k` cannot see: the `-b` SPELLING, in both directions.
That was the one measured routing decision the change turned on and nothing asserted it —
deleting `-b claude/<name>-cont` left every check in both suites green. The gone arm's
forbidden needle is the LONGER `add <path> -b claude/`, because its own prose legitimately
offers `-b claude/<name>-cont` as the remedy when git reports the branch already checked
out somewhere.

**ONE ALTERNATIVE exists and it is NOT an arm, which is the whole reason it took this
long to ship.** `MOVE_ALTERNATIVE` offers `git worktree move` on the PRESENT leg, and the
create recipe stays the default because it is the only route that needs no judgement from
the reader. **Everything that can change the reader's mind sits ABOVE the fenced line, and the
rule is a SHAPE rather than a count of members** — a count here went stale inside a single
review round, which is the drift this file records about itself everywhere else. Members today:
the unvetted-tree stop, the `-c core.fsmonitor=false` non-carry, the same-repository bound, the
destination-containment instruction for `<path>`, the COST, and the measured-pid line. One
fenced command is one copy button, so anything printed after it is read after it has run.

**The history is worth keeping because the claim was FALSE TWICE, in opposite directions.**
A first round moved one precondition up and left two below. A second round wrote "Three
PRECONDITIONS sit ABOVE the fenced line … Both carriers now agree" — and that was false for
the doc carrier, where the same-repository bound still sat below the fence, and false in a
second way for both carriers, where the cost and the measured pid sat below it while every
sentence arguing FOR the route sat above. Three independent reviewers found the first half and
a fourth found the second. Do not restate agreement between the carriers as a fact; state what
is graded. `T35e` grades the doc carrier by OFFSET rather than by a needle, because the
property is an ORDER and no substring can express one — it resolves the `**Before you run it:**`
bar, the `core.fsmonitor` non-carry and the same-repository bound against the command, so a
member added to the bar needs an anchor added there too or it is graded by nothing. The emitted
carrier is graded positionally by `worktree-advice-v1.test.js`, on the stop condition alone.

The move's condition is a HUMAN ATTESTATION — the reader KNOWS that session
will not be continued, after an account switch, a usage limit or an abandoned window —
and it is deliberately keyed on NO predicate at all. That is measured rather than
cautious: the run that prompted it had a registered LIVE pid on a session its human had
abandoned, so `archived`, `live` and the whole four-way ladder answer the wrong question,
and keying the route on any of them would offer it exactly where it is unsafe and withhold
it exactly where it is right. A pid is a process, not an intention. **The rule above is
unchanged and still holds** — every arm still returns a `git worktree add` line, so `WT8k`
is untouched; the move is an alternative, never a replacement.

**THE COMMAND CARRIES NO `-C`, AND THAT IS THE STRONGEST GUARANTEE THIS ROUTE HAS.** It
shipped as `git -C '<their worktree>' worktree move …` for one round. Dropping the `-C` makes
git resolve the repository from the READER's cwd instead of from inside the tree being moved,
which converts the same-repository precondition from a sentence the reader must honour into a
refusal git issues itself. MEASURED against git 2.51.0 — record the measurements, because the
review that asked for this could not make them and the next editor will not either:

- `-C` at a FOREIGN repository, moving another repository's worktree: refused, `is not a
  working tree`. With no `-C` and a cwd inside a different repository: refused identically.
  With no `-C` and a cwd that is not a repository at all: refused. With no `-C` and a cwd
  inside the taker's own worktree of the SAME repository: succeeds.
- `worktree move` **does** consult `core.fsmonitor` — a hook that ran, with a control proving
  the same hook fires on an ordinary `status` in that repository — and `-c core.fsmonitor=false`
  **suppresses** it. The round before this one shipped `Whether worktree move consults that
  config was NOT measured`; it is measured now, the flag is on the line, and the hedge is gone.
  Do not restore the hedge: `core.fsmonitor` names a command git runs FOR you.
- A RELATIVE destination is refused with `Invalid argument`. A review finding claimed it would
  silently resolve against the moved tree and produce a different directory than the create
  line one fence up. That is REFUTED for 2.51.0 — the failure is loud. The finding was right
  that the two lines resolved their operands differently and wrong about the consequence, which
  is why the measurement is recorded rather than the finding.

The cost of dropping `-C` is that the command now depends on where the reader is standing, and
that dependency is stated in the emitted text rather than left implicit. The accepted-gap
paragraph below, which frames the cross-repository hazard as answered by a SENTENCE where
`continuationPlan` answers it with a REFUSAL, is superseded for this route: git refuses it.

**THREE claims about the gate ship BOUNDED, and all three shipped UNBOUNDED first and were
then measured false.** Record them that way rather than as a list of wordings, because the
unbounded form of each is the one a later editor will reach for again. **This is a deliberate
EXCEPTION to the rule this section states below for the sibling `CARRY_OVER` recipe**,
which says this section restates neither that recipe's safety properties nor their count and
points at the two reader-facing carriers instead. The exception is narrow and it is about
FALSIFICATION rather than about content: what is recorded here is not the correct wording —
that lives in the emitted array and in SKILL.md flow 3 step 4, as the sibling rule requires —
but WHICH unbounded form was measured false and against WHICH owner. A carrier cannot hold
that; it would read as a caution about a claim it does not make. Do not extend the exception
to the correct wordings themselves, or this becomes the fourth hand-maintained copy the
sibling rule exists to prevent. (a) Rule (C) judges
BOTH operands: `bash-source-write-parse.js` keeps every pathish operand after
`worktree remove|move` and its own comment says "`move` names source and destination; both
are candidates", so taking the escape drops the containment check on the DESTINATION too —
which is why the emitted text now tells the reader to place `<path>` inside their own anchor
by hand. An earlier wording said the gate "judges it against the tree it relocates rather
than the one it lands in", which is the opposite of what the parser does. (b) The deny is
CONTAINMENT, never a construction-time property: `escapes` is
`!isTemp(p) && !within(projectRoot, p)`, and THIS repository's own mandated layout nests
every worktree under the main checkout, so a source worktree inside the taker's anchor is the
ORDINARY case and is not refused at all — `trail.mjs` even renders a named `already-contained`
state for it. "Outside the taker's anchor by construction" was false and sat in this very
section. (c) The bypass-ledger entry is CONDITIONAL: `tdd_record_bypass` writes only while
`tdd_session_active` is true and `tdd_add_bypass` returns early with no state file, so a
session-trail takeover — which normally arms no chain — records NOTHING. An unconditional
"taking it is RECORDED" told a reader that a destructive escape leaves a trail it will not
leave, which is worse than saying nothing.

**The ESCAPE is named, never SPELLED, and never PRESCRIBED — and the fourth of those was
missing for a round.** Rendering the prefix would be the shipped hatch §"Git Mutation Tables"
forbids outright, and that much was right from the start. What was wrong was "take it from
there rather than from here", which INSTRUCTS the reader to take it and contradicts
`skills/session-trail/SKILL.md` §5's own "Do not plan around the escape prefix the deny
names … do not go looking for the spelling in order to use it" — a rule that also records
that the host classifier commonly refuses the prefix, so the old wording pointed at a remedy
which usually cannot be taken. **That sentence in the parser is a cross-module dependency registered in PROSE and pinned
by nothing**: the advice asserts the deny message names an escape, the only thing making
that true is an inline string literal in `bash-source-write-parse.js`, and nothing in
`tests/` greps it. It IS registered on §"Git Mutation Tables"'s coupled-sites roster and is pinned by nothing
there; `WT8v8` asserts only the negative direction, that no arm spells the prefix.

**The SAME-BRANCH benefit is bounded to one repository.** Across two, the create line fails
harmlessly on a branch it cannot resolve while the move SUCCEEDS and relocates a foreign
repository's linked worktree into the taker's tree — `continuationPlan` refuses that case by
name, and this is the first rendered command in that file which writes to the SOURCE worktree
with no refusal standing in front of it, on brief carriers where the sibling renderer's
refusals are deliberately withheld.

**`MOVE_ALTERNATIVE` is a FUNCTION of the measured live pid, and that is not cosmetic.** As a
static array it sat ABOVE the `r.live` spread, so on the `active` and `unreadable` arms —
whose `ADVICE_LEADS` cells name no pid — a destructive relocation was offered before any line
named the registered process, which is precisely the gap `LIVE_SNAPSHOT_CAUTION` exists to
close for the READ recipe. Naming the pid inside the route was taken over the obvious reorder
because that caution's first sentence scopes itself to the carry-over below it, so moving the
route under it would have made a correct sentence introduce the wrong command. **It also has
its OWN axis** (`options.move`), not a ride on `carryOver`. State that defect STRUCTURALLY,
because the obvious wording is wrong and shipped here once: the rider did NOT invert which
caller saw the route — `cmdShow` still withholds it and `cmdAdopt` still renders it. What one
flag removed was the CHOICE, since no caller could keep the decision half while dropping the
route or the reverse; the unit case `dropping the carry-over recipe alone keeps the move
alternative` is the one that needs two axes to exist at all, and `cmdShow`'s withholding is an
independent, still-current decision recorded at that call site rather than here.

**Pins, and the ORDER of the present leg is now stated in one place** rather than spread
across four constant headers: create, then move, then the live caution, then the carry-over.
`WT8v1`/`WT8v2` grade presence on the present leg and ABSENCE on the gone one — `WT8v1`'s
needle carries the `git -C` anchor for the reason `WT8L`'s does for `-b`, and `WT8v2`'s
forbidden needle is command-shaped because the gone-leg `live` leads legitimately discuss
moving worktrees. `WT8v3`/`WT8v4` grade the attestation, `WT8v5` the cost to the other
session, `WT8v6`/`WT8v6b`/`WT8v7`/`WT8v7b` the four bounded gate-and-escape claims, and
`WT8v9` the same-repository bound. The measured pid is `WT8w1`/`WT8w2`, on its OWN stem
rather than as a fourth `WT8v7` suffix: a suffix means "sibling of the same subject" in this
file (`WT8L`/`WT8L2`, `WT8m3`-`WT8m5`), and using it as a sequential allocator is what forced
this very sentence to re-group the ids in prose. `L70` gained two conjuncts for the WHERE
head's route clause and its standing-in qualifier, `L70c-control` one asserting `worktree
move` is ABSENT from `show`'s render — without that last one, deleting `move: false` left
`show` printing the route directly above its own sentence claiming to withhold it, with every
check in both suites green — and there are TWO cross-carrier EQUALITY arms, `T35c` on the
COST sentence and `T35d`/`T35d-control` on the carry-over escape's ALTERNATIVE clause, because
each carrier's wording was pinned and their agreement was not. **Say cost, not attestation, and
say clause, not sentence.** `T35c` was written on the attestation sentence and MOVED, because
that pair is not disjoint: `WT8v3` and the `[move-attestation]` needle both carry
`only you can authorize it` byte-for-byte, so the drift arm could only fail where one of those
two already failed. The cost pair IS disjoint, and deliberately by SUBSTRING rather than by
different words — `[move-cost]` greps `mutates the other session` while `COST_NEEDLE` is the
strict superstring `it mutates the other session` — which is the relation to reproduce for any
third arm. `T35d` is that third arm and it shipped WITHOUT the relation: its needle was
byte-identical to the `[carryover-escape]` needle beside it. **State what that cost precisely,
because "neither could fail alone" was the overstatement review caught and it contradicted the
`ESCAPE_NEEDLE` paragraph in the suite itself.** The two arms read DIFFERENT carriers — the
needle greps `$STEP4`, `T35d`'s control greps the extracted advice prose — so a trail.mjs-only
deletion already separated them, firing the control while the needle passed. What the
byte-identical spelling could not separate was an edit to the DOC carrier. The repair was to
widen the `T35b` side to the JOINED THREE-CLAUSE sentence rather than to delete either,
because a one-clause needle also left the TRIGGER and the PROHIBITION deletable — a reword
keeping the closing clause turned a bar on running the recipe into an offered convenience, and
that reword is the state the widening genuinely newly covers. Both controls strip COMMENT
lines from `$ADVICE_SRC` first: that slice carries several hundred of them — no numeral here
or in the suite, because it moves on every edit to `worktreeAdvice` and a stale one reads as a
measurement — and comments in this tree quote emitted text verbatim, so "scoped to the slice,
so a comment cannot satisfy it" was false. MEASURED, against the further claim that a comment
OUTSIDE the slice carries either literal: none does. Do NOT route either control through `$ADVICE_CMDS`
instead — that extraction requires the opening quote plus TWO SPACES, which is the COMMAND
grammar, and both sentences are PROSE elements, so the control would fail unconditionally.
The MOVE route's own stop condition AND its fsmonitor disclosure — two subjects, which both
suite comments state separately and which this sentence collapsed for a round — are pinned by
the `[move-stop-condition]`,
`[move-unvetted-tree]`, `[move-fsmonitor-not-carried]` and `[move-fsmonitor-hedge]` needles on
the doc carrier and by the `WT8v10` family plus `WT8v11`/`WT8v11b` on the emitted one; it was
unpinned on BOTH for the whole chain that introduced it. **THREE separate subjects sit in that
sentence and an earlier wording ran them together, so state each on its own.** (1) The
stop-condition bar itself. (2) The move route has FIVE sibling paragraphs and FOUR of them had
needles on the doc carrier — the attestation paragraph had none until
`[move-attestation-not-a-predicate]` landed, so "its four sibling paragraphs all had needles"
described the emitted carrier and not this one; the emitted side really did have one per
sibling. (3) The bar guards the one rendered command in this flow that writes to the source
worktree with no REFUSAL STANDING in front of it — "refusal standing", never "gate refusal":
what is absent there are the renderer's own refusals, while the write gate DOES judge this
command, so naming the gate flips the claim onto the thing that applies. A fourth subject was
unpinned on both carriers until the same round and is NOT part of that sentence: the
consequence of taking the escape anyway, pinned by `WT8v7c` and
`[move-destination-containment]`. The fence SEPARATION of the create and move commands is a
unit case, and it catches the both-runs-deleted edit only — measured, deleting either prose
run alone leaves the fences split, so the ordering case beside it is what holds the leading
run. `WT8v8` loops `WT8k`'s roster — accumulated in THAT
loop rather than a second one, which saved 16 node spawns — and asserts no arm spells the
prefix. `T35b` gained needles for the SKILL.md prose, because `T35` pins the COMMAND alone
and the attestation and cost paragraphs were otherwise deletable with both suites green.
Two further unit cases pin that the survey drops the route and that the two axes are
independent. **Adding the command cost BOTH hand-maintained counters in the same change** —
`WT8_PRESENT_EXPECT` and `T35_EXPECT`, whose sum invariant this section's own roster already
names — plus `WT_UNIT_TOTAL_WANT` and the SKILL.md flow 3 step 4 mirror `T35` greps them
against. **And it moved two line-anchored citations**: `T36` caught both immediately, which
is exactly what that pin exists for. It introduces NO new placeholder — `<their worktree>`
and `<path>` were both already in the present leg's command set, so `recipePlaceholders`
returns the same SET. Claim the set and never the ORDER, and carry no ordinal: an earlier
wording here said `<their worktree>` "was already the fourth distinct token, so the same list
in the same order", which is exactly the ordinal-in-prose this file forbids elsewhere, over a
derived scanner output whose only comparing case sorts BOTH sides — so membership has an
owner and order does not. The route's prose carries `<path>` and `<name>` at column zero,
which that scanner never reads.

**Three bounds are ACCEPTED rather than closed, and each is stated where it is offered.**
(1) The cross-repository hazard is answered by a SENTENCE where this file's own precedent is a
REFUSAL — `continuationPlan` withholds its target on a `cross-repository` reason code. A
refusal here needs the caller's anchor threaded into `worktreeAdvice`, which takes only the
row, so it would change that function's contract and all four call sites. (2) The measured pid
reaches a persisted brief a DIFFERENT session opens later, so the sentence states the instant
it was written at and tells the reader to re-check rather than claiming anything about now;
the pid-in-a-brief class itself is pre-existing, through `ADVICE_LEADS.live.present` and
`LIVE_SNAPSHOT_CAUTION`. (3) `WT8w1` rests on the suite's `LIVE_PID="$$"` premise, which
§"Session Lineage Ledger" records as MEASURED FALSE under Git Bash for the sibling suite and
which no probe in this suite self-names on lapse; a lapse reports as needle failures naming
pids rather than naming the premise, and the `L0b`-style detached-node-helper probe is the
standing fix.

**`archivedAndDead` is named for what the EXPRESSION computes.** It was `safeToAdopt` —
a name that read as clearance — and then `archivedSurvivor`, which read as "the directory
survived" and needed eight lines of apology on the gone leg explaining that it means the
opposite there. The predicate carries no directory term at all
(`archived === true && !liveDespiteArchive`); the directory split happens one level down,
in `leg`. A name that has to be defended at one of its two use sites is the wrong name,
and the apology comment went with the rename rather than surviving it.

**The arm is decided ONCE, above the directory split, and both legs index `ADVICE_LEADS`.**
Lifting the three predicates was only half the job — the four-way LADDER that consumes them
was hand-written twice, in the same order, and this feature's own history is the argument:
retiring the old early return forced the identical reordering edit to be made by hand in
both places, where a one-sided version parses, renders, and is caught only if a fixture
happens to cover the affected arm. Each cell of the table is a FUNCTION, because two arms
interpolate a measured value (the live pid, and why the archive state could not be read),
and one shape is cheaper to hold than two.

**The rule has TWO halves and the second is easy to drop.** Choosing a directory settles
where COMMITTED work goes; a `git worktree add` carries nothing else. The present-directory
arms therefore also carry `CARRY_OVER`, the recipe that moves the uncommitted half out, and
the gone arms say the recipe cannot run against a path that is not readable rather than
printing one whose source is not there.

**The safety properties of that recipe are enumerated in the two reader-facing carriers,
and this section deliberately restates neither them nor their COUNT.** It used to, and that made a FOURTH hand-maintained copy of text that
already exists in the code comment above `CARRY_OVER`, in the emitted array a human reads,
and in `SKILL.md` flow 3 step 4 — a four-way agreement whose own paragraph recorded that it
had already gone stale once (it read THREE for a round after `--binary` was added, and FOUR
for a round after the quoting, the paste-unit split and the regular-files-only loop landed).
The two READER-FACING carriers are the authority: the `CARRY_OVER` rationale comment in
`skills/session-trail/scripts/trail.mjs` and `skills/session-trail/SKILL.md` flow 3 step 4,
which must agree with each other on the COUNT and on every property. `T35b` pins the
SKILL.md copy needle by needle and `WT8m3`/`WT8m4`/`WT8m5` plus
`tests/structure/worktree-advice-v1.test.js` pin the EMITTED array. State the bound with
them: no check compares the two COUNTS, and the rationale COMMENT above `CARRY_OVER` has
no pin at all — which is where three stale claims were found in one review cycle. That
agreement is held by review, not by a suite. What stays here
is the pin roster below and the gaps at the end — the parts that exist nowhere else.

**Three hand-maintained counts encode ONE fact, in TWO files, and they are related by
arithmetic nothing computes:** `WT8_PRESENT_EXPECT` and `WT8_GONE_EXPECT` in
`tests/structure/test-session-trail-verdict.sh`, and `T35_EXPECT` in
`tests/structure/test-session-trail-skill.sh`, where **`T35_EXPECT` = `WT8_PRESENT_EXPECT` +
`WT8_GONE_EXPECT`**. Adding one command to `CARRY_OVER` reddens two suites in two files, and
each failure message now names its sibling so the second edit is not a hunt. The VALUES are
deliberately not repeated in this file: they moved three times inside one review cycle and
this paragraph was stale after every one of them, which is the drift a fourth hand copy
always produces. Read them from the two suites; what this paragraph owns is the RELATION.
**They must NOT
be derived, and that is worth stating so nobody "fixes" them into vacuity:** the same
extraction that would produce the expectation also loses the two-space prefix, so a derived
expectation drops in lockstep with the defect and passes. The exactness is load-bearing;
what was missing was signposting.

**Coupled carriers, and the pin that holds them:** the advice command literals —
`TAKE_YOUR_OWN`'s, `MOVE_ALTERNATIVE`'s and the gone leg's `git worktree add` /
`git worktree move` spellings AND every `CARRY_OVER` command — are hand-restated in
`skills/session-trail/SKILL.md` flow 3 step 4, in its table and its fenced blocks. State the
roster from the EXTRACTION RANGE, never from a remembered list: `T35`'s awk runs from
`const CARRY_OVER = [` to `worktreeAdvice`'s closing brace, so every two-space literal
declared between those two anchors is a member, and this sentence named three sources while
the range already held four for a round. A FOURTH copy of the gone-leg spelling lives in `printResume` and is
OUTSIDE the extractor's range, which ends at `worktreeAdvice`'s closing brace: it is
byte-identical today and a one-sided edit to it is unpinned. `T35`/`T35-control` in `tests/structure/test-session-trail-skill.sh`
extract every two-space command literal from the first hoisted constant through the END of
`worktreeAdvice` — a RANGE, not one array, because scoping it to `CARRY_OVER` would leave
the two literals that encode the rule unpinned, and because the constants now live at module
scope while the gone leg's command is still inside the function. Its `sed` decodes the one
JavaScript escape those literals carry (`\'`, from the shell-quoted placeholders); without
that, every quoted command reads as missing from a markdown carrier that agrees with it.
**Both scans are SCOPED to flow 3 step 4.** The rationale scan always was, because `symlink`
and `mktemp` occur in unrelated passages and a whole-file grep passes while the recipe's own
rationale is gone. The COMMAND scan was not, and that made it presence-in-the-file rather
than presence-in-the-right-cell: transposing the `-b` and no-`-b` spellings between the
table's *Directory present* and *Directory gone* columns left both literals in the file, so
the model read the rule backwards with every check green — and moving the fenced recipe out
of step 4 entirely was invisible the same way. `T35-control` asserts an EXACT count, not a
floor: a floor survives deleting the `apply --stat` step from both carriers at once, which is
the edit the pin exists to stop. `T35b-control` guards both scans against an empty slice.

**`WORKTREE_ADVICE_COMMAND` / `adviceBlock` are a producer/consumer contract between one
array and THREE renderers** — `cmdTakeover` and `cmdHandoff`, which persist their output
into a brief, and `cmdAdopt`, which prints to a terminal. Do NOT restate the count as
"two briefs": that spelling was true until the `adopt` route began rendering the advice,
and it is the census drift this same section records against itself twice below. A
command line is one indented exactly two spaces; prose sits at
column zero. It is deliberately NOT a `git `-anchored rule any more — `CARRY_OVER` opens
with a `PATCH="$(mktemp …)" && …` line, and its copy loop carries `while`, `[`, `mkdir` and
`done` lines besides — and the widening cuts both ways: a prose line that acquires
a two-space lead-in becomes a COMMAND in every one of those three renderers, and in the two
that persist a file someone else opens later it is published inside a ```bash fence as well —
`cmdAdopt` renders `{ carrier: 'terminal' }`, because a terminal has no copy button. `WT8p`
grades both directions structurally rather than against a verb allowlist. Before the
extraction the two briefs disagreed about the same array — `cmdHandoff` re-fenced per line,
`cmdTakeover` fenced nothing — so a recipe was runnable in one brief and prose in the other.
Contiguous commands coalesce into ONE block, and it takes ONE PIN PER RENDERER to hold that —
TWO output pins for the two briefs, plus a SOURCE pin for the terminal carrier, whose block is
delimited by a blank line and a prompt rather than by a fence. `WT8q` drives `cmdTakeover` and `WT8q2` drives `cmdHandoff`,
which is the call
site whose own comment names it as the origin of the per-line-fencing defect. One was not
enough and that is measured, not argued: with only `WT8q`, reverting `cmdHandoff` alone
left every check in both suites green. Both render a PRESENT-leg brief, which no other
fixture here does — every other one is directory-gone, and a single isolated command cannot
show coalescing at all. `WT8r` consumes those same two renders rather than making its own,
and covers the other axis: the `r.cwdExists` prose branches in both briefs, graded against
the gone leg so it cannot pass by rendering one branch twice. **There is no longer a THIRD
split pin, and `L70e` is no longer one:** the `adopt` carrier's split is graded ONCE, at the
unit layer, by `the destructive apply is not in the same paste unit as the steps that gate it`,
and `L70e` was thinned to a source pin establishing WHICH RENDERER produced that carrier —
three `grep -qF` literals over the extracted `whereAdviceLines` body — `const body =
worktreeAdvice(row,`, `substitutionRuleLines(body,` and `adviceBlock(body,` — which pin the
IDENTITY rather than the render alone: the array is hoisted, and the rule that renderer prints
is derived from the very lines the block renders, so the same value must reach both. An earlier
wording here quoted a single `adviceBlock(worktreeAdvice(row)` needle that matches nothing in
the tree, the hoist having replaced it. That is
the claim only this layer can make, and it is source-shaped, so an output walk was the wrong
instrument for it twice over: the property is renderer-independent, and the terminal carrier
stopped carrying a markdown fence at all. `L70`'s own fence needle is the NEGATIVE one now —
`[markdown-fence-on-a-terminal-carrier]` — because `adopt` prints to stdout. The split pin for
the BRIEFS arrived as a NEW sibling check rather than as a correction to
`L70`, so a roster naming `L70` sends a maintainer to the check that does not hold the
property.

**Standing fix, named rather than taken:** the split is renderer-INDEPENDENT — it is
owned jointly by `adviceBlock`'s coalescing and by `CARRY_OVER`'s column-zero prose line
— so one pin per renderer scales linearly for a property that has one implementation.
`adviceBlock` and `worktreeAdvice` are both exported, and THAT HALF ALREADY SHIPS: the
unit case `the destructive apply is not in the same paste unit as the steps that gate it`
in `tests/structure/worktree-advice-v1.test.js` grades the split directly through
`mod.adviceBlock(mod.worktreeAdvice(...))`. What is still outstanding is THINNING the
three renderer pins to a "this carrier went through `adviceBlock`" needle — say it that
way, never "grade it once at the unit layer", or a maintainer taking the fix adds a
second copy of a test that exists.
**The fence-walk census is TWO implementations over TWO renderer pins, and it was three until
`L70e` was thinned to a source pin.** `WT8q` and `WT8q2` do NOT each carry their own awk: both
call one shared `fence_of()` in
`tests/structure/test-session-trail-verdict.sh`. `L70e` carried an inline awk of its own and no
longer does — it greps the renderer call instead, which is the claim that layer actually owns.
And the SECOND implementation sits in the destination file — `fenceOf` in
`worktree-advice-v1.test.js`, whose own comment says it mirrors `fence_of` — which a
maintainer hunting for "three per-check awk walks" to delete would never reach. The
mirror of this paragraph inside `test-session-trail-lineage.sh` carries the same
correction and moves with it.

**Operator-facing accounts that must move with it**, and the first two live in DIFFERENT
steps — bundling them under one was wrong, because `T35`'s slice is anchored on
`/^4\. \*\*Decide WHERE to continue/` and would extract a region the content sits outside
of: `skills/session-trail/SKILL.md` flow 3 **step 4** carries the `CARRY_OVER` hand-copy,
while flow 3 **step 3** carries the renderer enumeration that names three commands. Then
the `adopt <selector>` row of that file's command table, its flow 5 step 6 paragraph, its
§"What leaves the machine's project boundaries" paragraph, and the Safety section's
`--no-record` bullet — the last FOUR all describe the `adopt` route's advice, and `T38` in
`tests/structure/test-session-trail-skill.sh` now pins all four, slicing each passage on its
own anchor so a reword of the `WHERE` head or of `worktreeAdvice`'s carry-over arm fails
loudly instead of leaving them stale. The claim that nothing pinned them outlived the pin by
a round, which is the drift this roster exists to catch and did not catch in itself. The Safety bullet joined that set only when the
`--no-record` refusal's stated ground was corrected, and it was missed on the first pass.

**Coalescing is now a TWO-SIDED property, and BOTH BRIEF renderer pins assert the split as
well, the terminal carrier being graded at the unit layer instead — state the base, because "both pins" was written when there were two, and a first
correction then said "TWO of the THREE" while its own closing sentence named the third
grading it.** One
fence is one COPY BUTTON, so coalescing all four carry-over commands put the destructive
`git apply` in the same paste unit as the `grep` and the `apply --stat` that exist to gate
it — and the "these steps sit between the diff and the apply" argument is about execution
ORDER, which only holds if the human stops between the third command and the fourth. A
column-zero prose line breaks `adviceBlock`'s run, so the two READING steps still coalesce
(splitting those from each other would reintroduce the per-line fencing) while the
destructive line sits in a later fence of its own. `WT8q`/`WT8q2` grade both halves for the
two BRIEFS, because either one alone is satisfied by the shape they exist to reject. For
`cmdAdopt` the split is graded at the UNIT layer instead, and `L70e` is a source pin on the
renderer choice rather than a third fence walk — the terminal carrier renders
`{ carrier: 'terminal' }`, so there are no fence indices there to walk, and `L70`'s fence needle
is the NEGATIVE one. **The carrier is REQUIRED on both renderers and neither defaults.** They
used to default in OPPOSITE directions — `adviceBlock` rendered markdown for an absent carrier,
`substitutionRuleLines` rendered terminal — so each signature taught the wrong default for its
sibling, and both persisted-brief call sites already relied on the asymmetry. `resolveCarrier`
is the one reader and it THROWS outside `{'markdown','terminal'}`; that is safe only because
`main()` flushes before it reports, so remove that catch and the throw becomes a partial-write
hazard. Aligning the two defaults on one value was the cheaper end state and was REJECTED: it
removes the contradiction and keeps a silent fallback on the axis whose wrong value lands in a
file a different session opens, against the `_autopilot_workspace_refusal` precedent this file
already records for a positionally-required audience argument.

**`cmdShow` is the SURVEY consumer, and for a long time no check reached it.** Name the
consumers by ROLE and never by ordinal: this paragraph opened "A THIRD consumer renders
the same array" until a fourth arrived, which is the drift the heading two paragraphs up
now warns about in its own words. There are FOUR — `cmdShow` (survey), `cmdTakeover` and
`cmdHandoff` (briefs), and `cmdAdopt` (confirmation). `cmdShow` prints every
line into a survey view with a nine-space prefix and no fence; when the carry-over recipe
landed the array grew from roughly six lines to dozens, so `show` began dumping a
paste-and-run recipe into the middle of the one output whose value is that you can scan it.
TWO options now, not one, and they are separate axes deliberately:
`worktreeAdvice(r, { carryOver: false, move: false })` is what `cmdShow` passes. `carryOver`
is the DATA-MIGRATION switch and `move` is the ROUTE switch, and one flag for both meant no
caller could keep the decision half while dropping the route or the reverse — the split is
what makes `worktree-advice-v1.test.js`'s `dropping the carry-over recipe alone keeps the
move alternative` expressible at all. `cmdShow` withholds BOTH and its pointer now says so in
as many words ("TWO things are withheld here, not one … a second ROUTE"), which
`L70c-control` pins together with a needle asserting `worktree move` is absent from that
render — without that one, deleting `move: false` left `show` printing the route directly
above its own sentence claiming to withhold it, with every check green. It points at the
briefs for the rest — and at `adopt`, qualified, because that verb also writes a machine-wide
ledger edge and is therefore not a read-only route to either.
Both options are opt-OUT on purpose: the briefs are what a
human pastes from, and a new caller that forgets one gets more rather than less — which is
exactly what `cmdAdopt` wants, so it takes both defaults deliberately rather than by
omission, and its own comment now justifies each of the two separately rather than arguing
one and granting two. The `--json`
payload is deliberately NOT summarized — it is a data carrier, and every `wt_case` in the
verdict suite reads the advice through it, which is what `WT8s` grades from both sides.

**The advice surface was NOT extracted into a `worktree-advice-v1.mjs` sibling, and the
decline is recorded here so it is not re-litigated from scratch — twice already a round
reported it as recorded when it was not.** The repo's own convention for an extracted module
is exactly that shape: `session-lineage-v1.mjs` sits in the same directory with its own
`node --test` file. Three facts argue for taking it. The unit file is already NAMED
`worktree-advice-v1.test.js`, for a module that does not exist. Importing the "pure" advice
surface evaluates `claude-path-v1.js`, `bash-source-write-parse.js` and `session-lineage-v1.mjs`
at load, because they are `trail.mjs`'s own imports. And `worktreeAdvice` can reach
`process.exit` through `fail()`, RETIRED: that refusal throws today, so this argument is discharged.

What argued against taking it in the round that raised it is concrete rather than
conservative: `T35`'s extractor anchors `^const CARRY_OVER = \[`, `^function worktreeAdvice\(`,
`^\}$` and `^const WORKTREE_ADVICE_COMMAND` against `$TRAIL_MJS`, and that anchor set has
already gone dead once without a sound. Moving the constants re-points four anchors,
`T35_EXPECT`, this roster and the unit file's import in one edit.

**The trigger is a second importer of the ADVICE surface, or the next change that has to
re-point those anchors anyway.** The move carries TWO obligations: re-home `livePid` and
re-point the extractor. Replacing the `fail()` call with a thrown error is not one of them,
because that refusal throws today and `main` flushes before reporting it.
`tests/structure/prompt-listing-v1.test.js` imports `trail.mjs` too, but only the prompt
listing — `extractPrompts` and `QUEUE_DELIVERY_REACH` — and none of the advice surface, so it
does not meet this trigger. The listing's own extraction, its cost and its trigger live in
`.claude/rules/session-trail-prompt-listing.md`.

**ONE RENDERER owns the placeholder mapping and the rule that governs it**, and the rule's
placeholder set is DERIVED from the recipe it is printed beside rather than handed in.
`substitutionRuleLines` and `recipePlaceholders` in `trail.mjs` are that renderer and its
scanner, and SIX carriers consume it: `whereAdviceLines` on both legs, `continuationPlan`,
`cmdShow`'s WHERE head, and both persisted briefs. Three things about it are load-bearing and
were each learned from a defect. It takes PAIRS and emits the mapping line ITSELF, because a
caller that spells its token once in a rendered line and once in an argument is the hand-copy
the extraction existed to remove. It takes the CARRIER rather than a bare indent, because on
the two persisted MARKDOWN briefs a bare `<path>` is a well-formed HTML tag name that a
renderer or a sanitizer drops, which emptied the only sentence naming what a reader must
supply. And its sentence is SCOPED to runnable lines, because `recipePlaceholders` reads
only those: widening the scan to prose makes the quoting claim false for MORE tokens, not
fewer, since a prose occurrence is genuinely unquoted. It also carries no positional word —
`cmdShow` prints this rule and then `continuationPlan`'s, which governs a different set, and
while the text said "below" the first rule introduced the second rule's block. The unit
layer derives its expectation from the recipe arrays, never from `recipePlaceholders`:
grading the renderer against the function the renderer calls is tautological in the one
direction that matters, and it pinned a wrong set in place for a round.

**TAKEN, in the round that shipped its sibling: `adviceBlock`'s `fence` option named one
symptom of what it selects.** The two branches differ in the markdown marker AND in how a
command block is marked for a reader — a fence is a copy button, a terminal has neither — so
the axis is the CARRIER, and `{ carrier: 'markdown' | 'terminal' }` is the option that reads
as the condition rather than as one of its effects. This file already records the identical
shape against itself for `ownDocumentVerdict(discloseWithoutKey)`: a boolean threads call-site
identity through a value whose policy then lives only in a comment. It was deferred once, on the ground that the option is exported,
consumed at ONE production call site plus four in the unit file across THREE cases, and read
twice inside `adviceBlock` itself — a cross-file edit whose whole value is legibility. The
deferral said to take it when something else already had to re-author those assertions, and
that is exactly what happened: `substitutionRuleLines` grew a `carrier` option on the SAME axis,
and two options naming one axis in two vocabularies is worse than either. Both now take
`{ carrier: 'markdown' | 'terminal' }`. The earlier count in this paragraph said four call
sites and two unit cases, which was wrong in both halves.

**THE THROWING RENDER RUNS BEFORE THE DURABLE WRITE, in every verb that writes one.** Three
functions in this surface can throw — `worktreeAdvice` on an `ADVICE_LEADS` cell it cannot
resolve, and `adviceBlock` / `substitutionRuleLines` through `resolveCarrier`'s required-carrier
refusal — and two verbs write a machine-wide ledger edge. `cmdTakeover` recorded its edge at the
top of the verb and made its first `print` roughly 160 lines below, so a throw in between landed
a durable edge with an EMPTY buffer for `main()` to flush: the edge existed and the `LINEAGE`
line SKILL.md requires never appeared. **Announcing after the write is NOT the fix and was
proposed as one**: that verb has TWO carriers and the `--json` one returns before any
announcement could be reached, evaluating `worktreeAdvice(r)` inside the payload literal. The
order is inverted instead — `cmdTakeover` builds its advice arrays above `recordTakeoverEdge`,
`cmdAdopt` renders `whereAdviceLines` above `ledgerWrite` into one variable both its carriers
push — which covers all four carriers at once and makes a render fault mean NO edge lands.
`main()`'s flush-before-report is the backstop for everything downstream of the write, not the
mechanism that makes the write safe; it was the stated mechanism for a release and covered only
the text carrier. SIX comment carriers assert this contract and must move together:
`resolveCarrier`'s header, `worktreeAdvice`'s own THROW comment, `cmdTakeover`'s own
RENDERED-BEFORE-THE-WRITE comment — the one this paragraph's narrative is ABOUT, and the one
an earlier count of FOUR over five enumerated items left out — `cmdAdopt`'s two (the second of
which explicitly PRESCRIBED the old order and would have had the next round revert the fix), and
`main()`'s choke-point comment. `L70n` in `tests/structure/test-session-trail-lineage.sh` pins
the order by comment-stripped offsets. `cmdHandoff` is deliberately ungraded: it writes nothing
durable, so it has no ordering to hold.


**Known gaps, accepted and named:**

- **The rule is prose, not a gate.** Nothing stops a session working in another session's
  worktree; the source-write gate only refuses a COMMIT outside the anchor, which is the
  other axis. This change makes every rendered recommendation point at the taker's own
  worktree — it does not enforce one.
- **The carry-over's untracked half carries a hazard no git flag touches**, and it is now
  a RUNNABLE loop rather than a sentence. `ls-files --others --exclude-standard` reports a
  SYMLINK by name like any other path, so a copy follows it out of the worktree — in a
  repository you have not vetted, that is how a key or another checkout leaves its
  directory. The check is the PAIR `[ -f "$s" ] && [ ! -L "$s" ]`, and neither half is
  optional: `test -L` alone — which both carriers used to name as *the* check — is a symlink
  test offered as the implementation of a REGULAR-FILE rule, so FIFOs, device nodes and
  sockets pass it; `[ -f ]` alone FOLLOWS a symlink, which is the mirror defect and the
  obvious spelling a reader reaches for. **A HARD LINK passes BOTH halves and is an accepted
  RESIDUAL, not a case the pair closes** — MEASURED, a hard link is a second directory entry
  for a regular file. The review finding that prompted the loop, the first emitted wording and
  an earlier revision of this bullet all claimed otherwise; the two reader-facing carriers now
  state the residual and name the link-count test beside it. Every placeholder token in PROSE is wrapped in a code span, and that is a CARRIER property
rather than typography: `adviceBlock` pushes a prose line verbatim, both persisted briefs are
MARKDOWN, and `<path>` is a well-formed HTML tag name there — a renderer or a sanitizer drops
it, so a caution loses the operand it is about in the one carrier a different session opens.
`substitutionRuleLines` already owned the fix for its own tokens; the two advice constants did
not, and three of the seven bare ones were new safety prose. Two live needles carry the
backtick with them (`WT8v7c`, `WT8v10d`); the rest never quoted a token. It is emitted rather than described because prose left the reader to
  improvise a loop that word-splits on a filename with a space. It still applies to copying
  by hand, because the "do not run this at all" escape does not answer it — and that escape
  now lives in the EMITTED array too, not only in SKILL.md, since SKILL.md is read by the
  model while the array lands in the brief a human pastes from. Pinned on both carriers, by different
  suites: `T35b` covers the SKILL.md copy, and `WT8m3`/`WT8m4`/`WT8m5` plus
  `tests/structure/worktree-advice-v1.test.js` cover the EMITTED text — the one that reaches a persisted brief,
  and the one `T35` cannot see, since its extractor matches command literals and these
  cautions are the prose beside them.
- **`adviceBlock` IS exported now, and its dormant branch has an executed case.** The
  `firstPrefix`-on-a-leading-command arm is still dormant by construction — every arm opens
  with a prose sentence naming its cause — and it exists so the helper does not silently eat
  `cmdHandoff`'s `- ` bullet the first time an arm is reordered. `trail.mjs` now guards its
  CLI dispatch on being the process entry point and exports two surfaces in separate
  statements. The advice statement names `adviceBlock`, `worktreeAdvice`, `adviceLeg`,
  `whereAdviceLines`, `substitutionRuleLines`, `recipePlaceholders` and
  `WORKTREE_ADVICE_COMMAND`; the header comment above it counts them, and `T24h` holds that
  count against the statement. The prompt listing has its own statement, recorded in
  `.claude/rules/session-trail-prompt-listing.md`. Of the advice names,
  `whereAdviceLines` is NOT pure: it canonicalizes two paths through `canonicalPair` to decide
  whether the taker is standing in the source worktree, so the surface's own "plain record, no
  filesystem" criterion is stated as "reads the filesystem only to canonicalize" now. So
  `tests/structure/worktree-advice-v1.test.js` drives that branch, an empty input and a
  single-line input directly. `adviceLeg` is the ONE implementation of the present/gone
  decision, and it exists because that decision has FIVE consumers. `whereAdviceLines` is the
  fourth, deciding whether to render the placeholder mapping at all, and it was added with the
  adopt-advice route while this census still read three; `cmdAdopt` is the FIFTH and it is a
  consumer in its OWN right, naming `leg` in both its `--json` payloads so a machine consumer
  is told whether the recorded path may be substituted. Both are named because the derived
  scan attributes a site to the FUNCTION that reads the leg, and both functions now do:
  `whereAdviceLines` was extracted to module scope and exported, and `cmdAdopt` calls
  `adviceLeg` twice on its own. This census read FOUR for a round after that second call
  landed, while the derived pin in `tests/structure/worktree-advice-v1.test.js` already
  asserted the true five-set and therefore stayed green — the exact failure a hand-maintained
  count beside a derived one produces, and the second time it has happened to this list.
  `worktreeAdvice` picks
  its lead AND its body from it, `cmdShow` reads it once into a hoisted local and uses it
  twice — for its `WHERE` head and for the pointer at the recipe its survey view withholds —
  and `printResume` decides whether to print
  its own copy of the gone-leg create command. Every one of those was a hand-written
  `r.cwdExists` at some point in this feature's history, and one of them drifted INSIDE a
  single function — the lead came from `adviceLeg` while the body came from a raw
  re-derivation. Before adding a renderer that depends on the leg, grep `cwdExists`. The entry-point guard
  compares REALPATHS on both sides: an installed plugin root is routinely reached through a
  symlink, and a string compare would answer "not the entry point" for a genuine invocation,
  turning the whole CLI into a silent no-op — far worse than the import side effect it
  removes. Both unit files that import `trail.mjs` — `worktree-advice-v1.test.js` and
  `prompt-listing-v1.test.js` — are driven from `test-session-trail-verdict.sh`, because
  `tests/run-all.sh` discovers only `test-*.sh`; each case count is hand-maintained and EXACT
  there, for the same reason `T35_EXPECT` is.
- **The line-anchored citations from `docs/multi-repo-chains-*` into this skill broke THREE
  times during one change**, silently each time, because `test-multi-repo-doc-citations.sh`
  states in its own header that a citation landing on a different but still substantive line
  is invisible to it. `T36` in `tests/structure/test-session-trail-skill.sh` is the tripwire,
  and it lives in THIS skill's suite rather than in the docs' because the file that MOVES the
  target is this one. It pairs each citation with a needle naming the cited CONTENT; when it
  fails, re-derive the line and fix the doc — never weaken the needle. **Seven rows, across
  BOTH carriers**: grading only the spec was the first spelling, and it reproduced the very
  defect it was written for, since the overview HTML twins three of those citations and had
  already drifted once inside this change. One row hardcodes its own line number, because the
  spec cites `SKILL.md` twice and a generic regex cannot tell them apart — that row's regex
  moves with the citation, which fixing the doc alone does not do. It has since caught
  further drifts, from both carriers at once — the first time that class failed loudly
  instead of silently. No ordinal here on purpose: the drift count lives only in run logs,
  so a number written down would be hand-maintained and would go stale, which is the failure
  mode this file warns about elsewhere. `T36-control` derives the citation POPULATION by
  scanning both documents rather than counting its own rows, so a citation into this skill
  that no row covers fails loudly instead of being graded by nothing.
  `test-multi-repo-doc-citations.sh`'s header points here, because an editor working from
  the docs' side would naturally run that suite and a green run there says nothing about
  these citations. **Re-derive each citation PER SITE, never by pattern sweep.** A regex
  over `trail\.mjs:\d+` was used twice to update these and collapsed both HTML citations
  onto one number both times — the two `<p class="src">` lines carry no prose to key on, so
  a sweep cannot tell the `gitState` card from the `printResume` one. `T36` caught it on
  both occasions, which is the only reason this is a note rather than a shipped defect.
  A symbol-resolved citation format would remove the fragility rather than catch it, and is
  not implemented.
- **`--resume` still lands in the source worktree by design.** The printed resume line is
  unchanged, and `FRESH_SESSION_SOURCES` excludes `resume`, so a resumed session keeps the
  original anchor. `--fork-session` is the route whose anchor is the directory it starts in,
  and the only one where the own-worktree rule and the write anchor land on the same place —
  but only the HANDOFF brief and SKILL.md flow 3 step 4 name it. The takeover brief renders
  no resume line at all, so it does not, and any claim that "both briefs" name the fork is
  false. Either way it is guidance, not a mechanism.
- **The `noStore` branch of `unreadableWhy` is unreachable from `test-session-trail-verdict.sh`.**
  `$FAKE` is one directory for the whole run, and the `archive()` helper itself does the
  `mkdir -p` on the store path; its FIRST call sits in the top-level fixture-setup block,
  over two thousand lines before any WT8 fixture is graded. So the store exists by then and
  `r.ccdStore` can never read `false` there. Two wrong causes were written down before that
  one — the WT8 block's own `archive()` calls (which run AFTER the unreadable fixture is
  graded) and the W13 case's `mkdir -p` (which is real but not first) — so name the helper
  and its first call site, not a line number that moves. Pre-existing, predates this rule,
  and it means one of the two hedged wordings has no executed case anywhere.

**Version: `patch`.** Walked against §"Runtime Lineage" entry by entry so the next reader can
CHECK the claim rather than re-derive it: no context-record or workflow-state schema field —
`trail.mjs` writes neither; no strict key set — nothing here validates by exact key membership;
no hook added, removed or renamed and no matcher changed; no config key; no attestation change;
and no `permissionDecision` in either direction, this being a skill CLI rather than a hook.

**The decisive check for this feature family is the DURABLE shape, and it is clean.**
`skills/session-trail/scripts/session-lineage-v1.mjs` is untouched, so `LEDGER_SCHEMA_VERSION`,
`makeEndpoint` / `ENDPOINT_KEYS` and `buildEdge` are byte-identical: nothing an older runtime
wrote becomes unreadable, and nothing this build writes becomes unreadable to an older one.
The `--json` payloads of `adopt` are an EXCHANGED shape rather than a persisted one — produced
and consumed inside one invocation — and the `worktreeAdvice` key is read by no validator that
rejects unknown keys. State the untouched-module sentence whenever this verdict is restated:
it is the one fact that makes the walk checkable in a grep rather than by reading the diff.
