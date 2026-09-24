---
paths:
  - "hooks/user-prompt-zen-mode.sh"
  - "hooks/lib/zen-anchor-v1.js"
  - "hooks/lib/zensu-zen-mode.sh"
  - "skills/zen-mode/**"
  - "evals/zen-mode-reaction/**"
  - "tests/structure/test-zen-mode.sh"
  - "tests/structure/zen-anchor-v1.test.js"
  - "tests/structure/zen-anchor-assertions.test.js"
  - "tests/structure/test-promptfoo-zen-mode.sh"
---

# zen-mode Chain-Progress Anchor (`user-prompt-zen-mode.sh` rule 6)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

Rule 6 of the zen-mode contract carries a one-line progress anchor above the closing next
step. **The hook SUPPLIES that line; the model no longer derives it.** The directive ends
with a `ZENSU CHAIN ANCHOR:` field carrying either a `Zensu: …` line to render verbatim or
the word `none`, and `none` means no Zensu chain is armed and no anchor is rendered at all.
The rule lives in the hook, the skill, the operator doc row and EVERY
`evals/zen-mode-reaction/scenarios/*.yaml`, and `tests/structure/test-zen-mode.sh` pins all
of them — the count is deliberately not written out here, because the eval roster is DERIVED
from the directory and a hand-maintained numeral is exactly what a driven loop cannot catch:
`hooks/user-prompt-zen-mode.sh` (the ACTIVE `additionalContext` directive — the
authoritative copy, re-injected every prompt), `skills/zen-mode/SKILL.md` rule 6,
`docs/configuration.md`'s `user-prompt-zen-mode.sh` hook row, and every
`evals/zen-mode-reaction/scenarios/*.yaml`, which embed the whole directive verbatim.
Z19b pins the directive carriers against each other, Z19c pins the extraction regex
across the two zen suites, Z19d pins the operator row.

**Why the model stopped deriving it.** The anchor rendered for ANY multi-turn work, so a
session that merely answered "what is this Python process?" still closed with
`Flow: ✓processes ✓identified ✓transcript ✓cause` — four invented steps that read like
evidence and described no process at all. The observed session was conducted in German and
its anchor was rendered in German; it is translated here because this repository is
English-only outside a match literal, and these words are prose rather than literals. The anchor only means something inside a
Zensu-driven development process; outside one it is decoration wearing the costume of a
progress report. Reported by the user against a real session, not theorised.

**The DECOUPLING RULE this amends — read the amendment, not just the prohibition.** An
earlier revision derived the label vocabulary from `hooks/lib/zensu-autopilot-state.sh`'s
`STAGES`, and review found that HAND-COPY already wrong in three ways: `GATES`
(unconditional) was missing while `VALIDATE`/`COVER` (gated on `state.options`) were listed,
`AWAIT_TDD` was missing too, and the four marks are linear while that machine is cyclic —
`GATES`, `CONVERGE`, `VALIDATE` and `COVER` all re-enter through `toAwaitTdd`, so a retried
stage had no defined mark. **That prohibition stands and is unchanged for `STAGES`.** What
the anchor now does is a different mechanism: a LIVE READ of an owner-EXPORTED classifier.
`hooks/lib/chain-recovery-v1.js` exports its shape literals precisely so consumers never
re-spell them — CLAUDE.md already records the `INERT_SHAPES` case where a table-driven copy
went silently wrong and the classifier-driven form caught it. `hooks/lib/zen-anchor-v1.js`
therefore maps a shape the classifier PRODUCED, holds no second copy of anything, and
answers `none` for any shape it does not map, so a shape added to `chainShape` costs an
anchor rather than producing a wrong one. **Two of its three inputs are READ from the
owner rather than restated**, and both were restated first: the FAILED mark is read from
the owner's own composed `STUCK_SHAPES` (it WAS a hand-concatenation of
`RECOVERABLE_SHAPES` / `DEAD_END_SHAPES`, which is the restated version that was replaced —
see the corrected roster bullet below, and note that a failed read now THROWS rather than
rendering `none`) (a hand-written `blocked` set had marked
`ticket-spent` and `ticket-lost` as failures under a comment claiming the owner treated
them as wedged — the owner calls neither wedged, and its own remedy for both is an
ordinary advance instruction), and the TOTAL shape set comes from the new `ALL_SHAPES`
export (the consumer's drift guard had used `NEXT_COMMAND`'s key set as a proxy for an
invariant that module never enforced). Both exports were added to `chain-recovery-v1.js`
by this change; a missing one makes the module render NO anchor rather than guess through
it. Do NOT read this as licence to copy a stage table:
`zensu-autopilot-state.sh`'s `STAGES` stays out of scope, for the cyclic-versus-linear reason
above. The worked EXAMPLE is now the real vocabulary rather than a
placeholder, which is what removes the old hazard that a model copied the example before it
obeyed the prohibition beside it. It lives in the SKILL carrier alone — the hook derives
its own at runtime and carries no example — and `Z19b` requires that line to be a token
`zen-anchor-v1.js` can actually produce, because the `shared` needle list it is otherwise
judged by deliberately holds no step name, so a renamed step used to move the module, the
hook and every eval carrier while that one line kept teaching the old words.

**The mechanism, end to end.** ONE node process does both things this hook needs from
outside the shell — the prompt text and the anchor — because it fires on every prompt of
every zen-mode session and a second spawn on that channel is not free; the anchor is only
needed once the mode has resolved to ACTIVE, which is decided before that call. It resolves
`ZENSU_PROJECT_ROOT` (the host-native spelling node needs — NOT the shell-namespace
`ZEN_ROOT` the marker paths are built from) plus the `scv1_` session key, calls
`session-control-core-v1.js`'s `readWorkflowState` (which takes that key as its `sessionId`,
exactly as `zensu-doctor-report.js` calls it), classifies with `chain-recovery-v1.js`,
renders through `zen-anchor-v1.js`, and substitutes the result into the directive's
`{{ZENSU_CHAIN_ANCHOR}}` placeholder by shell PARAMETER EXPANSION. **The read is guarded by
an `lstat` on the document that does TWO jobs**, and neither is an optimisation:
`readWorkflowState` reaches `ensureDescendantDirectory`, which CREATES the missing
components, so without a guard a per-prompt hook would mkdir `<project>/.zensu/state` in any
project that has none — and the shared reader opens before it checks that the file is
regular, which is the blocking hazard the paragraph further down states in full. The
document path is built from the owner-exported `WORKFLOW_STATE_SEGMENTS` /
`WORKFLOW_STATE_PREFIX`, so the layout is not re-spelled here; an earlier spelling used an
`existsSync` on a hand-written two-segment path, and both halves of that are retired. The
placeholder is what keeps the directive a STATIC literal in source, so Z19b, Z30 and P8 can
still extract and measure it; the eval carriers hold a rendered token instead, and both
suites compare verbatim up to the marker and then ask the module whether the token is one it
can produce. **Every fault answers `none`** — an absent, unreadable, foreign or
unclassifiable document, a document that is not a REGULAR file, a module that will not load,
a `node` that runs and fails, or a value that fails the module's own token predicate. A
missing anchor costs a line of presentation; a wrong one misreports where the session
stands. **A `node` that is ABSENT is NOT in that list**, and the distinction is not
pedantic: `zensu_bind_hook_session` already requires one, so the hook exits above this
point and injects NOTHING — zen-mode is not re-injected at all that turn. AC-005 of the
plan names "missing node" among the faults that leave the mode active, which no hook in
this plugin can satisfy; the carriers say "a `node` that runs and fails" instead.

**The token is spliced into a JSON string, so its charset is load-bearing — and it is checked
in TWO PROCESSES by FOUR readers that share no spelling.** Count processes and readers
separately, because they do not agree and an earlier wording gave one number for both -
and a later one then contradicted the bold lead in the very next sentence by counting three
processes. The module and the hook-side node program are ONE process: the hook `require`s
the module INSIDE its node child, so `anchorTokenSafe` and the hook's own regex run there
together and hold one reader each. The shell is the SECOND process, and it holds two
readers of its own — `zen_anchor_grammar_ok` and `zen_anchor_bytes_ok` — composed by a third
function, `zen_anchor_sanitized`, which is graded by `Z47` alone. Each owns a
different property — an earlier wording called the node program "the ONLY grammar reader on
that path" while the paragraph below already described a second, which is the kind of
self-contradiction this section exists to prevent. The module's `anchorTokenSafe` owns the
output SHAPE: `none`, or `Zensu:` plus mark/step pairs, and nothing else. The hook's node
program re-checks against a grammar spelled in the HOOK, which is what a swapped module
cannot change — the module blessing its own output is exactly the case that belt exists for.
The shell then reads the grammar AGAIN over the bytes that ARRIVED, which is the only reader
positioned to see a truncated write, plus the byte tests below. The shell then applies a BYTE test: a quote breaks the JSON, a
backslash changes what an escape means, and any control byte — a CR or a TAB, not only LF —
is invalid inside a JSON string and would lose the whole directive silently. Its `&`, `|`,
`$` and backtick arms are RETAINED from the `sed` era rather than needed by the current
expansion; they cost nothing, since no producible token carries them. **The shell now reads BOTH the grammar and the bytes, and the reason is a case the node
program structurally cannot see.** Its prefix arm accepted `Zensu: <arbitrary prose>`, and the
argument for that — the grammar belongs to the reader above — held only against a SWAPPED
module. It does not hold against a TRUNCATED WRITE: the child emits `anchor + "\n" + prompt`
in one call, so a child killed mid-write puts a PREFIX of an already-validated token on the
wire, after that reader has passed on the whole one. `zen_anchor_grammar_ok` is a pure-shell
field walk beside the byte test, not instead of it — the two own different properties and
neither subsumes the other. It matches the mark set as an ALTERNATION of whole strings, never
a bracket expression, because the marks are multi-byte and a bracket class over them matches
individual BYTES under a byte locale.

**The locale is PINNED, and the step-name class is spelled letter by letter — and only ONE of
the two is measured.** Say which: the collation defect below was REPRODUCED on this host, the
control-byte one was NOT, and an earlier heading here claimed "both MEASURED" over a body that
already recorded the second as unreproduced. `local LC_ALL=C` scopes the pin to the call, since bash applies an
assignment to LC_ALL immediately without an export. Written as `[a-z]` the walk accepted
`Zensu: ✓Implement`, because a `case` range follows the collation order, which interleaves the
cases in this locale. `[[:cntrl:]]` has the mirror exposure — three of the four marks carry
a byte in the C1 range 0x80-0x9F, which a single-byte ISO8859 locale classifies as a control
character (0x9C in ✓ and ✗, 0x96 in ▶, none in ·; an earlier wording said all three carried
0x9C, which is false) — but say what was and was not observed: `Z34a` did NOT reproduce that rejection under `en_SG.ISO8859-1`
on macOS, so it is a POSITIVE CONTROL on the fix's direction and the SOURCE arm `Z34` is the
only bite this half has.

**The node program carries no literal non-ASCII in its argv.** The four marks sat there as
literal UTF-8, so the grammar travelled through the argument vector as bytes above 0x7F; on a
path that is not UTF-8 clean the anchor dies silently, and only on that host — the class this
file already records for the MSYS argv namespace. `Z35` scans the WHOLE spawning function
rather than the quoted program alone, a deliberate over-reach whose only extra cost is that
comments inside that one function stay ASCII, and it has already caught em dashes later edits introduced
(the count lives in the check's own comment, which is the one carrier that moves with
them).

**EVERY fault DISCLOSES on stderr under a named class**, because `none` is also what a session
with no chain armed legitimately renders: without a line, a corrupt document, an unloadable
module and a dead child were byte-identical to ordinary healthy output on every channel, and
this repository's own rule is that a silent failure is a lie. An ABSENT document is
deliberately NOT a fault — it is the ordinary state of every project that never armed a chain,
and disclosing it would put a line on every prompt of every non-Zensu session. `Z36` is the
bite and `Z36-control` is what keeps the line off the healthy path.

**The DELIVERY of that channel is UNVERIFIED, and is recorded as such.** Nothing measured here
establishes that a `UserPromptSubmit` hook's stderr on exit 0 reaches the user, which is the
same standard §"Autopilot Run Scope" states for its own Stop-hook disclosure. If it does not,
the disclosure has no observable and the argument above buys nothing. The durable answer is a
`/zensu:doctor` row — the shape `ruleCarrierRows` already ships for the two marker-block
carriers — and it is deliberately NOT taken here.

**Two residuals travel with it, and the first was WORSE than this paragraph used to say.**
NOTHING is latched — not the child's line and not the parent's. An earlier revision described
a per-session band file latching the parent's two classes and excused the child's repetition
against it; that latch was REMOVED rather than hardened, for the three reasons the hook states
at the call site (a bare read of a session-writable path outside the watchdog, where `[ -L ]`
does not exclude the FIFO class this very change closed at the shared reader; a truncating `>`
that a hard link turns into a destroy; and a guessable value a co-tenant could pre-seed to
suppress a first disclosure). So the repetition is accepted on BOTH sides: while a fault
persists, its line prints once per prompt. Second, the child's fault classes cannot move into
`zen-anchor-v1.js` as an exported set, which is the shape this file prescribes for reason
vocabularies elsewhere — one of them exists precisely for the case where that module cannot
be loaded, so the vocabulary has to survive its absence. `Z46` pins the set instead, derived
from the assignment sites in the comment-stripped body and compared BOTH ways, so a class
added to the child REDDENS Z46 until `Z46_DECLARED` is amended, rather than being pinned
by nothing, and a class that survives only in a comment is caught. Say "reddens", never
"covered without editing the check": an edit IS owed, and the value of the derivation is
that it forces one instead of letting the class ship unpinned. The CARRIER set is derived
too — a third `*Fault` variable folded into the emission enrols itself — so only the
declared list is hand-maintained.

**The child runs under the SHARED watchdog ladder**, `zensu_run_bounded`, and the PAYLOAD
reaches it on STDIN. Three channels were tried for that one value and the first two were
wrong in different ways. An assignment written after a command word is an ordinary ARGUMENT,
so it put the verbatim user prompt into an argument vector, where `/proc/<pid>/cmdline` is
world-readable on Linux and the watchdog holds the line for the child's whole life. Exporting
fixed that and left a smaller exposure: an environment is captured by process-listing,
crash-reporting and telemetry tooling that does not capture stdin, `execve` caps a single
environment string so an oversized prompt makes the exec FAIL, and MSYS rewrites exported
variables on the way into a native binary while stdin is the one channel it never touches.
Piping is also what both sibling consumers of this same payload already do — see
`zensu-agent-context.sh` and `zensu-session.sh` — so the hook stopped being the odd one out.
The two remaining exports carry no user content: a project root and a session key. `Z41` pins
the whole contract TOTALLY rather than per name: no `NAME=value` token on the spawn line at
all, the payload piped, and every name the child reads derived from the program and required
to be exported. State THREE bounds with it. The ladder falls through to an UNBOUNDED arm when neither
`timeout` nor `gtimeout` exists, which is base macOS, so this is a deadline where the host
supplies one and nothing where it does not. Its deadline is a FIXED 5 seconds with no
parameter, and this hook is its first PER-PROMPT caller — the ladder was written for two
Stop-path children, where a five-second stall is paid once at a turn end, and it is now paid
on the way IN to every prompt of every zen-mode session. Five seconds is generous for the
work this child does and the constant was left alone deliberately, but the next caller that
needs a different one has to parameterize the ladder rather than copy it, and doing so
reaches `hooks/stop-chain-enforcer.sh` through `C49`/`C56a`. And a kill costs this caller
more than it costs those two: they lose a diagnostic, while this one loses the prompt. A killed child returns NOTHING, and what that costs is NARROWER than an earlier
wording here claimed. It said the turn loses the whole directive; it does not. An empty
capture yields an empty anchor, which the sanitizer answers `none` for, and the directive is
injected exactly as it is for any session with no chain armed. What is lost is the anchor and
the PROMPT, and the prompt is the expensive half: the off-phrase branch reads an empty string
and cannot see `zen off`, so the one in-band escape from the mode is unavailable for that turn.
Overstating it as the whole directive pointed a reader at the wrong failure. ALL THREE
modules are `lstat`ed before ANY is required, so a symlink or a non-regular file in
`hooks/lib` is refused rather than loaded — verifying and requiring one at a time did NOT
hold that property, because `zen-anchor-v1.js` requires `chain-recovery-v1.js` at top level
and so executed the sibling before its own guard ran.

**The couplings below fire in the UNOBVIOUS direction**, the same shape §"Gate-Disable
Prefixes" records for G12 — an ordinary edit elsewhere reddens a suite named for the
zen-mode hook, and nothing points at it from the side that changes. The count is
deliberately NOT written out: this same section states that rule for its eval roster,
and a first revision of this list opened "Five couplings" above seven bullets, which
is the drift the rule exists to prevent.

- Z19b DERIVES its eval carrier roster from `evals/zen-mode-reaction/scenarios`, so
  ADDING or REMOVING a scenario reddens this suite. Both halves are real only because
  the floor is taken from the count `promptfooconfig.yaml` REGISTERS: an earlier
  spelling floored on a bare absolute literal, so deleting a scenario together with its
  registration left a consistent smaller world in which nothing turned red — and this is
  the ONLY CI-run check that reads that directory, the sibling that compares against the
  config being local-only. The derivation must be able to fail LOUDLY when it derives
  NOTHING: a `registered > 0` conjunct guarded the comparison at first, so a changed
  registration spelling silently dropped the floor back to the absolute one.
- Z19b ALSO loads `hooks/lib/zen-anchor-v1.js` to derive the producible token set, so
  renaming that module or its `SHAPE_POSITION` / `anchorToken` exports reddens this suite
  AND `test-promptfoo-zen-mode.sh` P8, which derives the same set the same way. Z30 loads it
  for the same reason — it substitutes the LONGEST producible token into the template before
  measuring, because the source literal still holds the placeholder and measuring that
  understated what a session receives.
- `hooks/lib/chain-recovery-v1.js` now owes this feature FOUR exports it did not have:
  `ALL_SHAPES` (the total set the anchor's key parity is pinned against, and which
  `zen-anchor-v1.test.js` in turn pins against the literals in `chainShape`'s own source),
  `DEAD_END_SHAPES`, and `STUCK_SHAPES` — the composition the failed mark is now read from,
  which the owner already computed for its own `wedged` verdict and kept private, so the
  consumer concatenated the two subsets a second time. Removing ANY ONE of the three
  leaves the chain-recovery suite green while the zen suite goes red, but by
  DIFFERENT mechanisms, and stating the outcome alone hid that. **The roster below is the
  CORRECTED one; the previous wording was wrong twice after `stuckShapes` began reading the
  owner`s composition, and the correction below was itself wrong once more after that.**
  The load-bearing export is now `STUCK_SHAPES`, and removing it makes `anchorToken` THROW -
  `chain-recovery-v1.js: STUCK_SHAPES unavailable, refusing to guess the anchor` - for every
  shape that HAS a position. It does NOT answer `none`, which is the opposite mechanism and
  the opposite failure direction: a throw is caught by the hook and disclosed, while a
  `none` renders as an ordinary "no anchor can be justified this turn". The two inert
  shapes still answer `none`, because their falsy `SHAPE_POSITION` entry returns before the
  read is reached. Removing `DEAD_END_SHAPES` does NOT — the owner
  builds `STUCK_SHAPES` from its module-scope constants rather than from its own exports, so
  `anchorToken` stays fully functional and the zen suite reddens instead at the case named
  'the failed mark is READ from the owner', which is that export's ONLY use in the unit
  file. Removing `ALL_SHAPES` reddens the key-parity case AND the second case that asserts
  the same set — two cases, not one. (Both attributions were wrong here for a round, which
  matters in a roster whose whole purpose is to say what will catch the mistake.) The
  FOURTH is `CHAIN_OUTCOMES`, which this roster omitted for a round while the Version
  paragraph in this same section already named it as part of the change - so a maintainer
  renaming it read here that zen-mode does not depend on it. It does: `OUTCOME_POSITION` is
  DERIVED by reducing over it and THROWS AT LOAD if a row names an outcome the owner does
  not declare, and its mechanism is the fourth distinct one - the anchor keeps rendering and
  the allowlist-membership case in `zen-anchor-v1.test.js` is what reddens. Four exports,
  four different mechanisms, and only one of them silences the anchor.
- `tests/SUITE-OVERVIEW.md` carries a row per driven `node --test` file with its
  REGISTRATION count, so adding or removing a case in either zen unit file makes that
  table stale — silently, since nothing compares them. Its section 1 row for
  `tests/structure/*.test.js` deliberately reads "(count deliberately omitted)", so adding a
  unit FILE owes nothing there. An earlier wording here claimed that row carried a total and
  that the file named itself its single owner; neither statement is in that file, and a
  maintainer working from it would have gone looking for a figure that does not exist. The
  per-file row is the whole obligation.
- `tests/structure/test-best-solution-first.sh` B14/B14a/B14b pin THIS directive's SCOPE
  clause — its ranking obligation and the anti-inflation counterweight — so editing that
  clause reddens a suite named for the best-solution-first hook. Note the boundary: a
  rule-6-only edit does NOT trip B14, so the coupling is invisible until the day someone
  condenses the whole directive.
- Z19c binds `tests/structure/test-promptfoo-zen-mode.sh` and compares the
  ACTIVE-directive extraction regex SOURCE, so editing that suite reddens this one.
- Z19d greps the `docs/configuration.md` hook row and anchors on
  ``^\|\s*`user-prompt-zen-mode\.sh`\s*\|``, so rewording that row — or renaming the hook
  file — reddens this suite.
- Z29 drives `tests/structure/zen-anchor-assertions.test.js`, which derives its scenario
  roster from that same directory and pins each anchor scenario's grader COUNT and its
  pass/fail VECTOR. So adding, removing or reordering a grader inside a scenario reddens
  this suite. TWO KINDS of floor guard the unit file and they count different
  things — do not conflate them, and note that the two kinds do not move together.
  `Z29_FLOOR` lives in `test-zen-mode.sh` and counts `test()` REGISTRATIONS in the whole
  file; the per-table `floor:` values live in the unit file and count CASES inside one
  scenario. So binding a further scenario raises the registration count and no case count,
  while adding a grader to a scenario already bound does the reverse — which is why
  "raise the matching number" needs the word MATCHING. Both kinds fire on REMOVAL only, so
  raising either in the same commit that adds to it is a CONVENTION the file states in its
  own comment, not an enforcement. **Both anchor tables were LOWERED** (14 → 12 and 10 → 8)
  when the mark-derivation graders went: the cases that drove them described a decision the
  reply no longer makes. That is a deliberate lowering with its reason recorded at the
  constant, and lowering it again needs the same note. The per-table count is deliberately
  not written out here — it grew by one when the third scenario was bound, and a numeral in
  this file is exactly what nothing recomputes.
- Z31 drives `tests/structure/zen-anchor-v1.test.js`, the anchor module's own unit
  contract, with the same registration floor. Z32 drives the hook end to end against a real
  Session Control record: `none` with no chain, the implementing position with one armed,
  and — the load-bearing arm — an unreadable workflow document costing the ANCHOR and never
  the MODE.

**A THIRD fix round ran against this feature, and it changed the shape enough to be worth
stating rather than folding in.** Five reviewer perspectives found seven defects in the round-2
work itself, and four of them were in code round 2 had just written:

- **A FIFO at the SESSION MARKER forced the mode ON and then wedged the way out of it.** The
  resolution tested `[ -L ]` and `[ -f ]`, and a FIFO is neither, so control fell through to
  the CONFIGURED DEFAULT — which ships TRUE — and unreadable state IMPOSED the mode, the exact
  opposite of what this hook's header promises. The off-phrase write then opened that FIFO
  BLOCKING, so the one in-band exit wedged the session. Same blocking class this feature closed
  at the shared reader, one marker over, and it had been there all along: `[ -e ]` plus `[ ! -f ]`
  is the arm that distinguishes a present non-regular file from an absent one.
- **The off-phrase write is HARDENED, and the argument is this file's own.** A truncating `>` at
  a session-writable path is a destroy primitive aimed at whatever a HARD LINK there points at,
  which is one of the three reasons the band file was deleted 35 lines above it. It lands an
  `O_EXCL` temp and renames now. Cost is one `node` spawn on the off-phrase path only.
- **The state-directory symlink guard covers the `.zensu` component too.** Testing
  `.zensu/state` alone resolves THROUGH a symlinked `.zensu`.
- **The `workflow document` label was cleared too early**, so a stub module in `hooks/lib` whose
  export is missing passed the `lstat` guard, threw at the call, and was disclosed as a CORRUPT
  DOCUMENT — sending an operator to `.zensu/state/` for a fault in the plugin tree. `anchor
  render` is the class for everything past the read.
- **The disclosure is TWO lead-ins, not one.** `fault` costs the ANCHOR, a line of presentation.
  `payloadFault` costs the PROMPT, and with it the only in-band way out of the mode. Announcing
  the second as an unavailable anchor told the user the one thing that was still working. `Z49`
  is the executed case, and it had none before: every fixture built a payload carrying `prompt`.
- **A fault-path prompt recovery restores the escape.** Merging both jobs into one child put the
  PROMPT behind a filesystem read it never needed, so a stall destroyed it along with the anchor
  and `zen off` did nothing. A second child loads no module, opens no path and reads fd 0. It
  runs only when the first already failed — and NOT when the first was killed by the watchdog,
  because three 5 s ladders are reachable in series against a 20 s registration and the
  elapsed < 3 s gate is what holds the worst case at the header's 3 + 5 + 5 = 13 s: letting the
  recovery run after the first ladder already spent its full 5 s is what threatens the deadline,
  and a killed HOOK loses the whole directive, which is strictly worse than the anchor loss being
  repaired.
- **The sanitizer's rejection discloses, and an EMPTY value is not a rejection.** The first
  spelling reported every degraded path as `token rejected on arrival`, naming a cause that
  never occurred and sending a maintainer to compare two grammars that never ran.

Four suite checks were found unable to fail and were rewritten rather than trusted: `Z47`
grepped a bare NAME, so a trailing comment satisfied it; nothing at all pinned that the hook
still CALLS the sanitizer (`Z47a` now does — deleting the call site left four checks grading a
function nothing invokes); `Z36` asserted the lead-in and not the CLASS, so the emitted line
could drop `classes.join` entirely; and the hook's own document `lstat` was graded by nothing,
because the shared reader's `O_NONBLOCK` produces the identical observable — `Z48` pins the
ORDER instead, since the guard's second job is preventing a per-prompt `mkdir` of
`.zensu/state`. `Z32e` was byte-identical to two fail-open checks and now requires SILENCE on
stderr; `Z19b` discarded the regex FLAGS, so an added `i` widened the shipped reader invisibly.

**TWO WRITERS LAND THAT MARKER, and hardening one of them left the guarantee false.**
`hooks/lib/zensu-zen-mode.sh` is the OUT-OF-BAND remedy, and the hook NAMES it in the sentence
it prints when the in-band `zen off` escape is unavailable — so for exactly the corrupt marker
path that makes the hook decline, the user was being pointed at a writer that still carried all
three hazards: no `.zensu` component in its symlink guard, no non-regular arm (a FIFO there
hangs a plain redirect with no reader), and a truncating `>`. Both writers now carry the same
three guards and both publish by `O_EXCL` temp plus rename. **State the rename's effect
precisely**, because the `nlink !== 1` test does not do what a first comment credited it with:
`rename(2)` repoints a NAME and never truncates the linked inode, so the hard-link destroy
primitive is defused by the rename itself. **The `nlink !== 1` conjunct is GONE from BOTH
writers**, and its removal is the point rather than a detail: refusing on it defended nothing the
rename had not already closed, while one `ln` in a session-writable directory made every later
off-attempt fail, in-band and out-of-band alike — an availability regression on the only escape
from the mode, against the truncating write it replaced. Do not restore it as a "defensible
signal". The temp
suffix is random rather than the pid, because nothing reaps a temp left by a killed write and a
later invocation landing on the same pid would then fail the `O_EXCL` open and report only
`COULD NOT BE DEACTIVATED` — a one-off crash turned into a permanent refusal of the in-band exit.

**A NON-TRAVERSABLE state directory used to impose the mode too**, on the permission axis rather
than the file-type one. `test -L`, `-e` and `-f` all fail with EACCES, so the ladder fell through
to the configured default. The asymmetry that shows the ladder already knew the right answer: an
unreadable MARKER resolves OFF one arm up; only the unreadable DIRECTORY fell the wrong way.

**Round 3 shipped four of its seven fixes with no check at all**, which is the same class this
whole feature exists to close — the round that found four defects inside round 2's own code
repeated the pattern. `Z50` pins the marker guards on BOTH writers plus the rename landing,
`Z51` pins the recovery ladder and all three distinct causes, and its `124|137` arm is a
NEGATIVE one — it sets `Z51_BAD` when that literal watchdog-skip case arm is PRESENT and requires
the `-ge 124` comparison instead, because a two-value case arm names two exit codes where the
property is "the watchdog killed it". A maintainer reading this sentence as "Z51 pins the arm"
restores exactly what Z51 forbids, and `Z52` scans EVERY `node` child rather than the one function `Z35`/`Z41`/`Z46`/`Z48`
all derive from. **`Z52`'s own first spelling was the same defect it exists to catch, and CI
found it — not this suite.** It scanned the WHOLE FILE for non-ASCII, so it reported the em dash
inside the OFF directive — ordinary prose that reaches no argv — as a leak; and it did that
through `grep -nP`, a GNU extension, so the identical tree was GREEN on macOS and RED on
ubuntu. Both halves are in `node` now, bounded to each child's PROGRAM TEXT. Its argv arm walks
TOKENS and resets at every shell operator, because position is the whole property: a LEADING
`NAME=v cmd` sets an environment and appears in no argv, while the same token after a command
word is an ARGUMENT — which is the historical leak here, `zensu_run_bounded PAYLOAD="$INPUT"
node -e …` making the ladder exec `timeout 5 PAYLOAD=… node …`. Line continuations are joined
first, because the shipped spawn spans two physical lines and a per-line walk skipped the one
carrying the assignment — round 3 added two further programs outside that slice, so writing
`PAYLOAD="$INPUT" node -e ...` in the recovery child would have put the verbatim prompt back
into an argv with `Z41` green.

**A FOURTH round followed, and its three findings were ONE shape: round 3 fixed a leaf and
left the component above it, the sibling writer, and the executed case behind.**

- **The permission arm covered `.zensu/state` and not `.zensu`.** With the parent unsearchable
  every test in the ladder fails for EACCES rather than for its own reason — including that
  arm's own `[ -d "$ZEN_STATE_DIR" ]` — so control reached the configured default again and a
  recorded `{"active":false}` was ignored. The symlink arm one line above already tested both
  components and said so; the new arm did not. `Z54` drives BOTH levels and the `.zensu` level
  is the one a leaf-only arm can never catch.
- **`zensu-zen-mode.sh --status` had no equivalent arm at all**, so it reported the configured
  default — `on` — for a session the hook resolves OFF and injects nothing into. Two readers of
  one state disagreeing is the class this file forbids elsewhere, and `--status` is the surface
  a user consults exactly when the mode misbehaves.
- **Both resolution arms were source-pinned only**, in a suite that already plants a `mkfifo`
  for `Z32d` — on the workflow document, never on the marker. `Z53` and `Z54` are the executed
  cases; each was probed by deleting its arm.

**`stuckShapes` now READS the composition instead of restating it.** `chain-recovery-v1.js`
computes `STUCK_SHAPES` for its own `wedged` verdict and kept it private, so the consumer
concatenated the two exported subsets a second time. A third stuck subset added to the owner
would have been folded into `wedged` and silently omitted here, rendering a wedged chain's
running mark instead of its failed one with both suites green. The constant is exported and
consumed; verified identical to the previous concatenation before the swap.

**The shell grammar reader's truncation justification was STRONGER than what it delivers**, and
the comment now says so. Both grammars accept any number of complete mark/step pairs, so a
truncation at a field boundary or inside a step name passes both; only a cut inside a mark or
straight after one is refused. And a truncated write implies a non-zero child status, which the
parent already answers by discarding the whole capture first. What that reader genuinely owns
is the swapped-module case plus the prefix arm the byte test alone allowed.

**`Z50`'s comment strip removed SHELL comments only, and that was measured rather than argued:**
commenting out `fs.renameSync(...)` inside an embedded node program left the check green even
after its needle was anchored on a call position. It strips `//` lines too now, and its
negative arm matches ANY truncating redirect at the marker rather than one historical
`&& { printf ... }` spelling.

**Which ceiling pays for the two `node --test` drivers:** `test-zen-mode.sh` has NO
`windows-ci.v1.json` entry — it is in that profile's sibling `windows-native-structure.v1.json`
`excluded` list with a reason — so no per-suite Windows cap can be blown here, and the cost
lands on the ubuntu shard partition through `ci-shard-weights.v1.json`. That file carries an
EXPLICIT entry for this suite (a figure that happens to equal `defaultSeconds`, which is why a
first revision of this paragraph mistook it for the default), and its own note says the seconds
map was measured on one named CI run. That measurement predates both drivers: Z31 adds a
`node --test` process and Z32 adds a session registration, three hook invocations and one
`--tdd-begin` against a temp project. Treat the entry as UNREMEASURED and take a new figure
from the next green ubuntu run — the wording that file already uses for `test-doctor.sh` and
`test-autopilot-stop-enforcer.sh`. No Windows wall clock exists for it either, so say
"unmeasured", never "cheap".

**The safety carve-out rides in the SAME directive string as the anchor**, and P8 in
`test-promptfoo-zen-mode.sh` — the only full-fidelity check that the eval copies match
the hook — is `localStructureTests` and never runs in CI (`run-all.sh --ci` skips it).
Z19b therefore carries three carve-out needles applied to the whole-directive carriers
only, NOT to the `skill` carrier, which is sliced to rule 6 while the carve-out is rule 9.
Without them a reworded carve-out would leave `safety-carve-out.yaml` — the one live-model
check that a warning is never compressed — grading a directive no session receives, with
every CI suite green.

**A run-time seam exists for the carrier problem and was DECLINED, deliberately.**
`hooks/lib/rule-block-v1.js` exports `readRuleBlock`, and both
`hooks/session-start-evidence-discipline.sh` and `hooks/user-prompt-best-solution-first.sh`
consume it instead of holding a copy; `/zensu:doctor` already renders a `rule carriers:` row
for those two. Adopting it here would move the directive into a markdown block, delete Z19c
outright (neither suite would need a hand-copied extractor), and give zen-mode an operator
surface that can tell "stopped injecting" from "user turned it off" — which it currently has
none of. The cost is real on both sides: a malformed block drops the injection SILENTLY,
which for zen-mode means the mode quietly stops; every eval `spec_block` copy still needs its
own text regardless, so it removes one copy and not all of them. **And the bound that
settles it is `MAX_BLOCK`**, which `rule-block-v1.js` declares and this file must never
re-spell as a number: the Z30 floor still sits ABOVE it, so every admissible directive length
is over the shared reader's limit — but the margin NARROWED when rule 6 shrank, so re-derive
it rather than trusting this sentence. A further obstacle is new: the directive now carries a
substituted field, and a markdown block read at run time would have to carry the placeholder
and the substitution with it.

**The injection is BOUNDED, and that is what makes the figures maintainable.** `Z30` in
`tests/structure/test-zen-mode.sh` measures the emitted directive through `node`
(`String.length`, because the text carries non-ASCII marks and `${#var}` counts bytes or code
points depending on locale) and holds it one-sidedly in BOTH directions: growth past the
ceiling fails, and so does a shrink further below it than the declared headroom, because a
ceiling that has drifted away from its text has stopped being a tripwire. The rule-6 rewrite
took the directive from 2951 to 4664 characters — 57% — with nothing observing it; the
supplied-anchor rewrite then SHRANK it to **4208** (the static literal, placeholder included)
and the window was re-derived to a ceiling of 4300 with 95 of headroom. **4208 is the static
literal and 4224 is what Z30 MEASURES** — it substitutes the longest producible token for the
placeholder first — so the realized slack is 76 rather than the 92 the static figure invites,
and both pass. 4224 is also the figure the per-turn totals use.

**Known gap, accepted:** the KB/KiB totals in `docs/architecture.md` are still hand-derived
from that character count, so they age whenever the directive moves even though the count
itself is pinned. They were corrected in this change (4224 + 1756 ≈ 5980 characters per turn,
about 117 KiB over 20 turns and 351 KiB over 60). Both operands are stated in the SAME unit
on purpose: an earlier wording summed 4224 characters with the sibling's 1764-BYTE figure.

**A CLOSED chain renders NO anchor, and the two readings that preceded that are why.**
`chain-closed` maps to `null`, the same value `no-session` carries, which is how the owner
already groups them — `INERT_SHAPES` holds exactly those two.

Both earlier readings asserted something untrue. `done: 3` claimed passes: `chainShape`
answers `chain-closed` on `chainDone === true` before it looks at any ticket or round, and
the gate on it was `codeReviewDone === true || reviewRound >= 1`, where BOTH operands say a
round was ISSUED rather than that it succeeded. The classifier cannot say more —
`chainOutcome` is a workflow-state key whose vocabulary includes `max-rounds`, and
`classifyChain` does not put it on its report at all — so a chain that ran one round and
closed without converging was indistinguishable from one that passed, while the directive
publishes the tick as "a step that finished and passed". The fallback reading `done: 1`
claimed the opposite: it renders the pending mark, which that same directive publishes as
"not yet reached", for a chain that is over.

**The PERSISTENCE is what made either one more than a one-turn slip.** The workflow document
survives the terminus — the phase library treats active-plus-implComplete-plus-chainDone as a
regular state — and the hook re-resolves on EVERY prompt with no recency bound, so a closed
chain kept rendering its line over unrelated work for the rest of the session. That is
precisely the "anchor rendered for work with no Zensu process behind it" defect this whole
module exists to remove, reintroduced one shape over.

Rendering on the CLOSING turn alone would be defensible and the shape cannot express it:
`chain-closed` cannot distinguish "just closed" from "closed two hours ago". That needs a
recency signal the classifier does not supply. Mapping to `null` removed the
`unreviewedDone` rung, the `options.reviewed` parameter and the whole `reviewedFromReport`
derivation with it. `anchorToken` then took a shape and nothing else — and that contract was
RETIRED again by the outcome read below: it now accepts a shape OR the classifier report, and
`outcomePosition` reads `report.linkage` and `report.autopilot.outcome` off the latter. The
report input is deliberately MONOTONE (it can only refine a position the shape alone leaves
unmapped, never override one), which is the bound that replaced the old contract.

**KNOWN RESIDUAL of the same class, one shape over, and it is NOT fixed here.**
`awaiting-self-review` and `self-review-unbindable` are both reached from
`codeReviewDone === true`, and the bound max-round handoff states its own postcondition as
outcome `max-rounds` WITH `codeReviewDone` true. So a review that exhausted its budget
without converging still renders a ticked `review` step. Every in-vocabulary answer is worse
or larger: the pending mark would claim a review still ahead of one that is over, and the
honest mark is the failed one, which this module renders only for shapes the owner's own
stuck sets name. **This is now IMPLEMENTED for a BOUND chain and only for one**:
`outcomePosition` reads `report.autopilot.outcome` and renders the blocked mark for
`max-rounds`, taking the value off the classifier's own `autopilotLinkage` rather than adding a
field to its report. What is still open is the STANDALONE case, which carries no
`chainOutcome` anywhere the anchor can reach, so a standalone chain that exhausted its budget
still renders a ticked `review` step. Closing that needs the outcome surfaced for a standalone
chain, which is a change to the report shape and belongs in its own commit.

**Port-relevant.** The core half is `anchorToken` / `anchorTokenSafe` / `SHAPE_POSITION` /
`ANCHOR_STEPS` / `ANCHOR_NONE` / `ANCHOR_PREFIX` / the four marks / `ANCHOR_TOKEN_RE` /
`stuckShapes` / `anchorNoneIsExpected` / `producibleTokens` / `OUTCOME_DEPENDENT_SHAPES` /
`OUTCOME_POSITION` / `outcomePosition`, in `hooks/lib/zen-anchor-v1.js`, together with its ONE sibling
require — the classifier whose shapes it maps and whose composed `STUCK_SHAPES` it reads, without which
it does not load at all. `stuckShapes` is exported for its TEST SEAM alone: its optional `owner` parameter reaches
the non-array and absent-export guards AND proves the module does not fall back to
re-concatenating the two subsets, which is the property the `STUCK_SHAPES` swap turns on.
Say it that way rather than "what makes the two `return null` guards reachable" — the
EMPTY-array guard is also reached without the parameter, through a copied module beside a
stub. Production always calls it with no argument. There is deliberately NO `reviewed` input of any kind —
an earlier round carried one as a host obligation and then moved it into the module, and
mapping `chain-closed` to `null` deleted it outright; a port that reintroduces one has
reintroduced the false-completion class. The host half is NINE obligations a port must
re-decide, and the FIRST is the one a port satisfying every other still gets wrong: the CALL
SHAPE. `anchorToken` accepts either a bare shape string or the whole classifier REPORT, and
only the report carries the linkage and the outcome the two `OUTCOME_DEPENDENT_SHAPES` need.
A port that passes `report.shape` - the spelling the module's name and its `SHAPE_POSITION`
export both invite - gets `ANCHOR_NONE` for those two, so a bound chain's self-review
position never renders, and `anchorNoneIsExpected` then answers true so the port's own
disclosure stays silent as well. Classify with the owner and pass the WHOLE report. Then:
WHICH document carries
the chain and which identity names it; the MODULE TRANSPORT (this host runs `node` with its
cwd inside `hooks/lib` — the first of the two mechanisms
`test-msys-special-plugin-module-boundaries.sh` sanctions — because the second needs a
`zensu-host-path.sh` render and that is a second process on the hottest path in the plugin);
the substitution into the directive AND its own independent re-check of the token BEFORE it is
written (this host spells the grammar a second time inside its node program precisely so a
swapped module cannot both produce a bad token and bless it); the SECOND, shell-side re-check
over the bytes that ARRIVED, which is a separate obligation and not a restatement of the one
before it — the body above argues that neither subsumes the other, because only a reader
positioned after the transport can see a TRUNCATED WRITE, and a port that folds the two into
one line drops exactly the defense that argument exists for; the charset belt appropriate to
that host's transport — the module's predicate is an output-SHAPE contract, not a JSON
escaping rule, and a port with a different transport still owes its own check; the DEADLINE on
the child, which this list omitted for a release even though the body above already said the
child runs under the shared ladder — a port whose child reads a file on stalled storage and is
never bounded hangs the prompt path itself, and the ladder's own header names that residual;
the DISCLOSURE — the
fault-class vocabulary, the channel it is written to, and the decision that an ABSENT
document is not a fault, an obligation easy to miss because it lives in the host half
entirely while reading like a property of the module, and a port that omits it ships the
silence this feature exists to remove; and the operator accounts.
The pre-open guard on the document is no longer among them in the same way: it still exists
because this host's `readWorkflowState` CREATES the state directory, but the BLOCKING half
moved into the shared reader, where a port inherits it from the core rather than owing it.

**Operator-facing accounts that must move with it:** `skills/zen-mode/SKILL.md` rule 6, the
`user-prompt-zen-mode.sh` hook row in `docs/configuration.md` (pinned by Z19d, so a reword
there reddens this feature's suite), and the per-turn character and KiB totals in
`docs/architecture.md`, which are hand-derived from the measured directive length and are the
one account in this list that ages silently whenever the directive moves. They are named
individually further up as well; this bullet exists so a maintainer finds all three in one
place rather than by reading the whole section.

**The disclosure is spelled TWICE within this host, on opposite sides of a process
boundary, and that is why the lead-in has a pin of its own.** The child writes its own line
from inside the node program; the parent writes a second one for the two outcomes the child
cannot report, a watchdog kill and an unreachable `hooks/lib`. A shared constant cannot span
that boundary — the child is a single-quoted argv program with no access to a shell variable —
so the lead-in `zensu: zen-mode anchor unavailable (` exists in two languages in one file.
`Z42` pins the parent arms and `Z46` pins the child vocabulary, and `Z42b` extracts the ANCHOR
lead-in from BOTH sides of the shipped hook and requires them equal, so a reword on one side
fails rather than splitting one diagnostic into two an operator would never grep for together.
It filters each side to the anchor wording deliberately: the parent also owns a
`zensu: zen-mode prompt unavailable (` lead-in, a different fault class that must not be forced
to agree with this one. A port owes the same pin, or the same divergence. A port that
takes only the module gets a mapping with no reachable caller. `zensu-codex`, `zensu-kiro`
and `zensu-antigravity` were NOT included in this change.

**A NON-REGULAR document is refused before it is opened, and that guard is about blocking
rather than tidiness.** `.zensu/state/` is writable from inside a session and no gate covers
it while the chain is inactive, so a `mkfifo` at the workflow document's path is reachable
from in-session. `readRegularFileSnapshot` THEN opened `O_RDONLY|O_NOFOLLOW` and only
afterwards `fstat`ed for `isFile()`, with no `O_NONBLOCK`, so the open on a FIFO never
returned — and this hook fires on EVERY prompt. Past tense throughout: the flag landed in
that reader in this same change, as the paragraph below records, and stating the gap in the
present here would assert the defect still exists. That wedges the session with no escape from inside: the prompt
never reaches the model, so the off-phrase branch is never evaluated either. The hook
therefore `lstat`s the document first, and builds its path from the OWNER's newly exported
`WORKFLOW_STATE_SEGMENTS` / `WORKFLOW_STATE_PREFIX` rather than re-spelling the layout — the
export exists because `workflowStateFile` cannot serve a read-only pre-check: asking it for
the path CREATES the directory.

**THE UNCOMPROMISED FIX WAS TAKEN, and the hook-side guard is now belt rather than the
boundary.** `readRegularFileSnapshot` adds `O_NONBLOCK` to its open, guarded exactly as
`O_NOFOLLOW` already is because the constant is not defined on every build. **POSIX LEAVES
the flag UNSPECIFIED for a regular file rather than giving it no effect** — the stronger
wording stood here as the reason this was safe for that reader's other callers, and the
module retracted it in the same change. What the safety rests on is that Linux and macOS
ignore it there, plus the bounded `EAGAIN`/`EWOULDBLOCK` retry arm the read loop now
carries: 64 iterations, each pausing through the module's ONE `sleep` primitive under its
best-effort contract, so a host where the unspecified behaviour does bite degrades in
latency instead of surfacing as a corrupt-document failure. On a FIFO or device the open
returns immediately and the existing descriptor `isFile()` check rejects it. That closes the class for EVERY caller of that reader rather
than narrowing it for one — `readWorkflowStateSnapshot` and every gate that reads a workflow
document inherit it.

The earlier round declined that fix on the ground that the module is required by every gate
and needs its own regression pass. The ground was sound and the CONCLUSION did not follow,
which review named: this same change already edits that module for two exports, so the bar
was being applied inconsistently. Taking the flag is the smaller of the two remaining
options, because the alternative left a check-then-use race the writer could retry on every
prompt.

The hook's own `lstat` STAYS, for the directory-creation job it also does and as defence in
depth on the blocking one. The `timeout` on the `hooks.json` registration stays too, and its
own bound is unchanged: a killed hook emits nothing at all, so that turn loses the whole
directive — the anchor, the contract and the off-phrase branch — which is the one fault in
this file that is not routed to `none`. Whether this host lets the prompt through when a
`UserPromptSubmit` hook hits its `timeout`, and whether it kills the process group or only
the direct child, are both UNVERIFIED; nothing in this work measured either.

`Z32d` plants a real FIFO and BOUNDS the hook, reporting a block rather than
waiting for it: the first spelling used a command substitution with a background killer and,
measured against a hook with the guard removed, hung past two minutes anyway, because a
command substitution reads until every writer closes the pipe and the blocked `node` still
held it.

**ALL modules are verified before ANY is required, and the one-at-a-time spelling did not
hold the property it claimed.** `zen-anchor-v1.js` requires `chain-recovery-v1.js` at top
level, so verifying and requiring one module at a time loaded and EXECUTED the sibling on the
first `require` — before its own `lstat` could refuse it. A guard that runs after the file has
executed is not a guard. Two independent reviewers reported this in the same round.

**The substitution is parameter expansion, not `sed` — and the `sed` spelling is a DRAFT OF
THIS BRANCH, never shipped history.** Say so, because three code comments framed it as a
predecessor and a reviewer correctly reported that `main` contains no `sed` and no `existsSync`
in this hook at all: it carries no substitution, because it carries no anchor field. In that
draft the ACTIVE directive was the only one of the hook's three emissions that depended on an
external command, and nothing examined that command's exit status: an absent or failing `sed`
produced empty stdout, the model received no zen-mode context at all, and the unconditional
`exit 0` made that indistinguishable from the hook not running. Every other fault in that file
is routed to `none`; that one was routed to silence. The expansions need no process, and the
placeholder is held in a variable so it stays a literal pattern rather than a glob. The same
correction applies to the `existsSync` guard the document-path paragraph above describes as one
"this block used to carry" — it was carried by an earlier draft here, not by a release.

**The byte tests are a FUNCTION, `zen_anchor_bytes_ok`, for a coverage reason.** Name that
function and not `zen_anchor_sanitized`, which after the split contains no `case` block at
all and is the COMPOSITION `Z47` grades — the same section states that correctly further up,
and this sentence contradicted it. As
inline `case` blocks they were unreachable from every fixture — by the time they run the value
can only be `none`, a module-produced token, or empty — so all three could be deleted with the
suite green. `Z33` extracts the function from the shipped hook and drives it, with the
accepting cases first so a function that answered `none` for everything could not satisfy the
rejections.

**Known gap, accepted:** a rendered `✓review` reports what a READABLE DOCUMENT CLAIMED, never
evidence that a review ran. `validateWorkflowState` is structural — it derives
`session_id_hash` from the file's own name, there is no MAC, and `.zensu/state/` is writable
from inside the session — so a forged document can put a completion line in front of a user
this directive itself describes as working at low capacity, on every turn. The reachable
outputs are a closed set, so this is not a text-injection channel; it is a completion SIGNAL a
co-tenant writer controls. Authenticating it needs a persisted signal, which is a
workflow-state schema change and therefore a `minor`, which the `patch` walk below declines.

**Known gap, accepted:** the `ZENSU CHAIN ANCHOR: ` field is identified to the model by a
fixed, guessable literal with no per-turn binding, so the same literal in content the model
reads LATER in the turn — a repo file, a pasted diff, a fetched page — can compete with the
injected one. It occurs in this repository's own tests. The impact is a wrong assurance line,
not instruction hijack: the heredoc is quoted and the only substituted value is the
closed-vocabulary token. Binding it (a per-turn nonce in the field name, named by the
directive as the only one it may trust) is the fix and is not implemented.

**Known gap, accepted:** the anchor covers the review CHAIN only — `implement`, `review`,
`self-review`. An Autopilot run's own stages are deliberately absent, for the cyclic-versus-
linear reason stated above, so a durable run shows the inner chain's position and not the
outer run's. `classifyChain` supplies `linkage` and `autopilot`, so surfacing the run id is
available and was not taken.

**Version: `patch`.** Walked against §"Runtime Lineage (`version_type` is load-bearing)"
entry by entry: no context-record or workflow-state schema field, no strict key set, no
hook added, removed or renamed and no matcher changed, no new config key (`zenMode` and
`zenModeDefault` are pre-existing, and this change deliberately adds none), and no
attestation change. The hook's only output is `additionalContext`, which is exactly the
ADVISORY shape the hook-inventory exemption names, and it returns no `permissionDecision` in
either direction. The hook now READS the workflow document; it writes nothing to it, so no
persisted shape moves. Two later additions were walked separately and neither moves the
verdict: a `timeout` key on the existing `hooks.json` registration is not a hook added,
removed or renamed and not a matcher change, and the two new exports on
`session-control-core-v1.js` (`WORKFLOW_STATE_SEGMENTS`, `WORKFLOW_STATE_PREFIX`) are
additive — an older runtime that does not read them is unaffected, and no validator gains a
key. A THIRD group was walked the same way after the review rounds and is named here so the
verdict can be re-derived from what this paragraph lists rather than from memory: the
`O_NONBLOCK` open flag and the paced `EAGAIN` retry in `session-control-core-v1.js`, a module
every gate loads, together with its collapse to ONE `sleep` primitive taking its fault
contract as a parameter; and the four further exports on `hooks/lib/zen-anchor-v1.js`
(`anchorNoneIsExpected`, `producibleTokens`, and the outcome allowlist behind them) plus
`CHAIN_OUTCOMES` becoming frozen and exported on `chain-recovery-v1.js`. None is a listed
breaking entry — no persisted shape moves, no validator gains a key, no matcher changes and
nothing returns a `permissionDecision` — so the `patch` verdict is unchanged; only the
enumeration was short. Two things read like a breaking change here and are not, which is why
the walk is written down rather than left to be re-derived: the runtime digest DOES move,
because `manifestRuntimeEntries` folds `hooks` and `docs` in wholesale — but
`readContextInternal` measures the RECORDED root — and the directive is re-emitted from the
executing tree on every prompt, so nothing persisted crosses the upgrade. The only
per-session artefact zen-mode owns is the `{"active":true|false}` marker, whose shape is
untouched. Choosing `minor` would be actively harmful rather than merely wasteful: while the
plugin is at major `0` the minor is the breaking axis, so it would refuse every in-flight
session until the user ran `/zensu:adopt-session --confirm`.
