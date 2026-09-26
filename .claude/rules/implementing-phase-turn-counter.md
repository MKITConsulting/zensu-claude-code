---
paths:
  - "hooks/stop-chain-enforcer.sh"
  - "hooks/lib/zensu-tdd-phase.sh"
  - "hooks/lib/zensu-bounded-run.sh"
  - "tests/structure/test-impl-stop-counter.sh"
---

# Implementing-Phase Turn Counter (`hooks/stop-chain-enforcer.sh` + `zensu-tdd-phase.sh`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

`zensu_impl_stop_nudge` counts a TURN whenever a Stop ends with the chain still at
`implementing` and the worktree reporting changed source, and at or past
`hooks.implStopNudgeAfter` (default 12) it writes ONE advisory line to stderr and still
releases. **The default is a JUDGEMENT, not a measurement, and it moved once already:** at 5
it fired during ordinary work — the implementing phase of this repository's own chains ends
more than five turns with a dirty tree routinely, including the chain that built this
feature — which is exactly the "trained away within a day" failure the rejections below
exist to prevent. 12 buys headroom over a long honest implementation while still being far
short of a parked chain. Re-derive it if anyone ever measures the real distribution.
`/zensu:doctor` renders the same finding as a `WARN` chain row for chains this
session owns. It exists because the release at the `SESSION_IMPL_COMPLETE != "true"` branch
is unconditional, so a chain that never runs `--tdd-complete` is asked for no reviewer at
all — no directive, no cap, and no bypass-ledger entry, because the ledger records gate
ESCAPES and no gate is ever reached.

**Three shapes were rejected, and each rejection is load-bearing.** Warning on the shape
alone is what every legitimately mid-implementation chain looks like, so the row would fire
throughout every normal run and be trained away within a day. An AGE bound reports the
user's calendar rather than the model's behaviour — a powered-off machine, a paused session,
an overnight break and a holiday all accumulate wall clock with nothing wrong, and they
accumulate zero here. And BLOCKING is out: a long legitimate implementation genuinely spans
many turns, so a false positive may cost a line of text and must never wedge a chain.

**In their ORDINARY branch both surfaces name ONE exit, with its preconditions, and never
the zero-change terminus.**
`--tdd-complete` refuses without an edit-landing receipt and without a usable
`## Requirements` table, and BOTH gates arm on the same dirty tree the notice requires — so
naming the verb bare would hand the reader a command that refuses in the same breath. From
shape `implementing` no review ticket has ever been consumed, so `--chain-done` is the
UNQUALIFIED no-ticket terminus and a mid-run commit drives its change-count guard to zero:
offering it would teach an exit that closes a chain nothing reviewed, defeating the
guarantee this feature exists to protect.

**Say "in their ordinary branch", never "both surfaces always", because TWO branches of
the notice deliberately name NO exit** — the counter-failure branches, which fire AHEAD of the
threshold comparison. **State where they point, because an earlier revision of this paragraph
got it backwards and three operator carriers copied the error:** they point at a rendered
`zensu-log.sh --chain-status`, which reports `implStopCount` whatever its value, and they say
explicitly that the `/zensu:doctor` chain row is THRESHOLD-GATED and shows no count until
that recorded value reaches the bound. Sending a reader with a stuck counter to that row is the
one thing those branches must not do; `C28b` asserts the `chain-status` and `threshold-gated`
needles and asserts the retired "keeps reporting the last value" claim ABSENT.

**The refused-spawn branch is NOT one of them, and the correction is worth stating because
this paragraph said the opposite for a release.** It named THREE branches and described the
refusal branch as WITHHOLDING `--tdd-complete`. The reasoning was sound as far as it went —
completing while the refusal stands moves the chain into a gate the host will not let it
pass — and it was still the wrong call, for a reason the paragraph never reached:
`reviewer_spawn_denied` carries no generation or recency bound, this path never blocks so the
cap never releases it, and withholding the verb kept the chain where no ticket could be issued
and therefore no spawn attempted. Nothing could ever clear the verdict. The branch now names
the exit AND states the refusal, its kind, the observed count and the `permissions.allow` rule
beside it, so stale evidence costs a sentence rather than the chain.

**The two surfaces no longer CONTRADICT each other, and the exact strength of that claim is
the thing to keep.** The branch mints the denial note, and while a live note for the same
session key stands the doctor row ADDS a caveat naming the refusal and telling the reader to
lift the permission before taking the exit. It does NOT withhold the command. Withholding was
tried first and was wrong twice: the note is an unauthenticated file in a session-writable
directory, so withholding let anything able to write there DELETE the row's only remedy while
asserting a host refusal that never happened; and the note is minted only by a Stop that gets
past the dirty-tree and threshold gates, while the row renders off the persisted counter alone
— so a single clean-tree turn (the mid-run-commit shape this same section already records)
cleared the note and silently restored the bare recommendation. Qualifying is stable under
both: a missing note costs the caveat, never the remedy, and a planted one can only add a
caveat.

**A THIRD consequence of the same asymmetry, and it is a CONFIGURATION one:** the mint sits
past the threshold comparison while the clear is unconditional, so `hooks.implStopNudgeAfter:
0` — and every turn below the threshold — deletes a refusal note without re-recording it. The
switched-off `✅` row says only that no chain was measured; it does not say the refusal
diagnostic stopped persisting. Recorded in the `implStopNudgeAfter` row rather than fixed,
because moving the mint above the comparison would persist a diagnostic for a check the
operator switched off.

**KNOWN GAP, the residual of exactly that asymmetry.** `reviewer_denial_note_clear` runs
unconditionally at the impl-not-complete exit while the mint sits behind the nudge's own gates,
so between a clean-tree Stop and the next dirty one the caveat is absent while the refusal still
stands. The row is then the ordinary remedy — correct in form, missing a warning. The direction
is under-warning, never a wrong command, which is why it ships; closing it means probing the
transcript on every implementing Stop, which is the cost that branch's own comment declines.
**A SECOND residual travels with the clear-then-mint order, and "over-reporting" UNDERSTATES
it — three reviewers said so and they are right.** The clear at the impl-not-complete exit
unlinks the note and the mint re-stamps `detectedAtMs` with the current instant, so for the
session's own note the `stale` verdict and the reaper's age arm cannot fire FOR AS LONG AS the
session keeps ending dirty turns past the bound. Scope it that way rather than calling it
unreachable outright: once the session stops producing such turns the note is no longer
re-stamped and both arms apply normally — which is precisely the case the reaper exists for.
The conclusion is unchanged, because the window that matters is the one where the branch is
firing: while it fires, there is no recency bound on this path. The TTL is the only recency
control this feature has — the probe
itself has none — so on this path there is no recency bound at all. **Name the route, because
two successive drafts of this sentence named the wrong one.**
Ordinary convergence does not reach it — `reviewer-spawn-denial-v1.js` derives its status from
the LAST reviewer result in the tail, so a spawn that succeeds after the refusal flips the
verdict to `clear`. But neither does the cap-release or self-review route, which the previous
draft named: the re-stamping mint lives in `zensu_impl_stop_nudge`, whose single call site is
the `SESSION_IMPL_COMPLETE != "true"` exit, and a capped or self-reviewing chain has
`implComplete === true` and never reaches it. What actually reaches it is what the probe's
selector admits: ANY refused `zensu:code-reviewer` spawn anywhere in the scanned tail while
`implComplete` is false — including one from a flow that never armed a chain at all, since
`/zensu:cover` orders that spawn and states it never runs `--tdd-begin`. The CHAIN never spawns
a reviewer at `implementing`, so the self-heal is not
GUARANTEED — but it is not impossible either, and the sentence before this one is why: a flow
like `/zensu:cover` can spawn one without arming a chain, and a successful spawn there does
flip the verdict to `clear`. Say "not guaranteed", never "cannot occur", and the note is re-stamped
every dirty turn end. That is WIDER than either earlier draft, not narrower. NOT fixed here,
and the cheap fix is on record rather than left to
be rediscovered: read the existing note's `detectedAtMs` before the clear and carry it forward on
a re-mint with an unchanged `kind`, so the TTL ages the REFUSAL rather than the turn.

**Sites that move together:** `zensu_impl_receipt_exit` in `hooks/stop-chain-enforcer.sh`, the
module-scope renderer BOTH implementing-turn notices interpolate for the chain's exit — it is
module-scope for the same ORDERING reason `REVIEWER_SPAWN_ALLOW_RULE` is, since the nudge runs
from an early exit above the blocked-Stop branch and cannot see an assignment made there. It
carries the `--tdd-complete` preconditions the notice would otherwise state twice and drift on:
a CLEAN receipt verdict and a usable `## Requirements` table. `C62` pins that it has ONE owner
rather than one copy per notice and `C62a` the same for the clean-verdict instruction; neither
pins the CALL-SITE count, so a third notice added without calling it fails nothing. Then
`zensu_run_bounded` in `hooks/lib/zensu-bounded-run.sh`, the ONE
watchdog ladder for every child that reads outside the process. It was created for the two on the
Stop path — the `git status` this counter runs and the refused-spawn transcript read — and it now
also bounds callers that are not on that path at all, which is why the ladder's own header states
the CRITERION rather than a count: raising the deadline stopped being a Stop-path-only decision.
The criterion is what governs; the roster below is a census taken at one moment, kept because the
next caller needs somewhere concrete to look. Its live call sites outside the Stop hook are FIVE,
in THREE files, and both this roster and the ladder's own header enumerated fewer:
`hooks/user-prompt-zen-mode.sh` holds the merged prompt-and-anchor child, the prompt-only
recovery child and the off-phrase marker write; `hooks/lib/zensu-zen-mode.sh` holds the
out-of-band writer, which sources the ladder itself; and `hooks/lib/zensu-log.sh` holds the
`--tdd-complete` claim-inventory child. `hooks/lib/zensu-doctor.sh` is no caller: its
`playwright-cli --version` read lives in `hooks/lib/playwright-cli-version-v1.js`, which bounds
the child itself with a 5 s `SIGKILL` timeout. Recount with `grep -rn zensu_run_bounded hooks`,
skipping comments and the `command -v` guard, rather than trusting this census. Named by file and role, never by line
number, because a line number in prose goes stale silently. The deadline is a fixed, unparameterized 5 s, so the next caller needing a
different one has to find every site — which is what this roster is for. The two on the Stop
path carried hand-copied ladders and the
`gtimeout` arm reached only one of them; `C49` and `C56a` pin each call site by name, `C42`/`C42a`
pin the ladder's own arms and their order, `C56` forbids a `return` in the arm positions its
pattern can see and `C56d` requires an unwrapped `"$@"` to survive in the body — neither reads
ARM POSITION, so do not restate them as pinning "the last arm". It LIVES in `hooks/lib/` because a FURTHER consumer already exists —
`user-prompt-context-nudge.sh` reads a host-supplied transcript path with no watchdog at all —
and a helper defined in a leaf hook cannot serve it. That one is a CANDIDATE, not a caller, and
the ordinal here deliberately counts nothing: it used to read "a third consumer" while the call
sites it would be counted against had already grown past three, which is the same drift the
census sentence above now avoids by stating the criterion. Three review rounds asked for that move
before it was taken. **`hooks/user-prompt-zen-mode.sh` now WRAPS its own child** — it
sources the ladder and runs the prompt-and-anchor child through it, which is the criterion
this paragraph states rather than an ordinal; the census sentence above is the one that
counts. **What is still owed at the context-nudge site is the
WRAPPING**, one `source` line plus one call, left to its own review because it alters a second
hook's behaviour and belongs to that hook's suite. Its exposure is also WIDER than the Stop hook's and the comment
there now says so: that reader opens with a plain `openSync` after a shell `[ -f ]` in another
process, where the Stop-path reader hardens the open, so a FIFO in the TOCTOU window blocks it.
Both the watchdog and the hardened open are owed there. Then `_zensu_config_bounded_int` in
`zensu-config.sh`, which is now
the sole body behind `zensu_impl_stop_nudge_after` AND behind `zensu_autofix_max_rounds`,
`zensu_pending_review_ttl_hours`, `zensu_autopilot_owner_activity_ttl_hours` and
`zensu_autopilot_release_owner_activity_ttl_hours` — so a change to
it reaches the auto-fix budget, the pending-review TTL and both Autopilot owner-liveness windows,
three features documented in other sections entirely. The five getters are
one-line calls whose operands must stay positional literals, because `impl_getter_operand`
in `tests/structure/test-impl-stop-counter.sh` reads the default and the max straight out of
the implementing-turns call for C29 and C31. The extraction is `getter_operand`, parameterized
on getter and key, and it reaches ALL FIVE keys — say five, not two: the CONSTANT-MIRROR
pins cover four of them (`implStopNudgeAfter` through C31/C31a — C29 reads the same
operands for a BEHAVIOURAL fallback check rather than for a mirror, so it is deliberately
not one of them, which `hooks/lib/zensu-doctor-report.js` already records beside its own
constant and `hooks/lib/zensu-config.sh` beside the getter — then `pendingReviewTtlHours`
through **C57**, which pins `TTL_HOURS_FALLBACK` / `TTL_HOURS_MAX` in the doctor renderer
against the TTL getter's own operands — a pair that declared itself a mirror in prose and was
pinned nowhere until the collapse made one extractor able to hold it — and
`autopilotOwnerActivityTtlHours` through **C57b**, which holds
`OWNER_ACTIVITY_TTL_FALLBACK` / `OWNER_ACTIVITY_TTL_MAX` the same way, and
`autopilotReleaseOwnerActivityTtlHours` through **C57e**, which holds
`RELEASE_OWNER_ACTIVITY_TTL_FALLBACK` / `RELEASE_OWNER_ACTIVITY_TTL_MAX`, with **C57c** binding
each window reader to its own pair so a swap cannot keep both green — and **C57d** keeping
C57c honest, because that needle names a reader by SPELLING and a reader nothing calls still
carries one. A value-only `ownerActivityTtlHours()` accessor survived the move to
`ownerActivityWindow` with zero callers for a round, and while it stood C57c graded it: the
live resolution could have been rewritten onto the pending-review pair with every check green,
which is the exact swap C57c's own comment says it catches. C57d derives the accessor
population from the renderer's own `function <name>() {` lines and requires each to be called,
with comment lines STRIPPED first — the dead accessor was NAMED in a comment beside its
replacement, and a naive occurrence count read that prose as a call site), and **C58** reads every
getter's operands through the same extraction to drive its bound matrix. So `autoFixMaxRounds`
has no renderer mirror, but its call line is bound by the positional-literal contract too: an
operand that stops being readable there fails C58. Then
`WORKFLOW_INTEGER_EXTENSIONS` in `session-control-core-v1.js`;
the THREE closed counter key sets in `zensu-tdd-phase.sh` (`tdd_get_counter`,
`tdd_increment_counter`, and the `names` map in `_tdd_increment_counter_critical`, transition
token `impl_guard`); **the EIGHT reset sites**, which `delete` the key rather than zeroing it,
matching how those callbacks treat the Autopilot link fields — a counter that survives a re-arm
makes chain 2 of a session render "parked" on its first turn, which is exactly the false
positive the rejections above exist to avoid. **State the criterion correctly, because a first
draft got it wrong and the wrong version is what mis-scoped the search:** the roster is
"every site that ARMS a generation **plus every full document reset, wherever it lives**", NOT
"every site that touches `stopBlockCount`" (the `codeReviewDone` and `reviewRound` resets are
review-budget resets and are correctly skipped). Only two of the eight arm — `tdd_set_flag` on
`active`→true and `_tdd_begin_session_critical`; the rest are teardowns, and reading the roster
as arm-only is what left the JS twins out at first. Six live in `zensu-tdd-phase.sh`; the other
TWO are in `session-control-core-v1.js` — `resetDeferredReviewState` and the
`deferred-review-transfer` draft. **They do NOT reset the same set, and an earlier revision of
this sentence claimed they did.** `resetDeferredReviewState` clears the peer
`WORKFLOW_INTEGER_EXTENSIONS` member `autopilotAttempt`; the transfer draft touches no Autopilot
field at all — it writes `active`, `implComplete`, `chainDone`, `codeReviewDone`,
`selfReviewFixed`, the ticket pair, `reviewRound`, `stopBlockCount`, `implStopCount` and
`deferredReviewClaim`, and nothing else. The `delete` there rests on its own ground rather than
on a symmetry that does not exist: an absent key reads as `0` in all three readers.
`deferredReviewStateIsIdle` in that
same file is deliberately NOT extended: it tests `stopBlockCount === 0`, and an absent key is
not `0`, so adding this one would make every reset chain read as non-idle.
Then `zensu_impl_stop_nudge_after` in `zensu-config.sh` against `IMPL_STOP_NUDGE_FALLBACK`
/ `IMPL_STOP_NUDGE_MAX` in `zensu-doctor-report.js`, which are a hand-copy of its default and
bounds; and the `ZDOC_IMPL_STOP_NUDGE_AFTER` export in `zensu-doctor.sh` against
`implStopThreshold` — that file sources `zensu-config.sh` ONCE for every getter it resolves
(five today: the pending-review TTL, this threshold, the two owner-activity windows and the
delivery-route field, with `C21c`
deriving that population from the resolve blocks and requiring each to be a disjunct of the
single-source guard), and the count
is pinned by `C33` because it shipped as two, one inside each resolve block, while a
requirements table recorded the single-source rule as met; and **the `implStopNudgeAfter` entry
in `config.example.json`**, which this roster omitted while both sibling flag sections name
their own — that file is advertised as carrying every flag, so a rename driven off this roster
would leave it advertising a dead key; and **`chain-recovery-v1.js`**, which owns both the remedy vocabulary
and the counter's projection — `normalizeChainState` / `classifyChain` carry
`implStopCount` beside `stopBlockCount`, the doctor row reads `report.implStopCount` and
`report.nextCommand` rather than the raw document, and `--chain-status` therefore reports the
count for free. **`hooks/lib/reviewer-spawn-denial-v1.js` is a DEPENDENCY of this feature too, not only of
§"Host-Refused Reviewer Spawn".** The notice's refused-spawn branch calls
`reviewer_spawn_denied` and renders `REVIEWER_DENIAL_KIND` and `REVIEWER_DENIALS` from the
same probe, so that module's verdict vocabulary, its `status=`/`kind=`/`denials=` output
contract and the probe wrapper's memoization all reach THIS surface. The coupling is
fail-open in the direction that matters and that is the part to keep in view: the probe
leaves the verdict `none` on every failure, so a missing, unreadable or predating module
silently returns this branch to the ordinary remedy — the WRONG remedy in precisely the
state the module exists to detect. An installation older than v0.18.2 therefore gets the
ordinary notice, exactly as that section records for its own surfaces, and nothing surfaces
the skew. The Stop hook is the ONE surface that still hand-authors the remedy, because the module is
not loaded there — so the bound `--tdd-complete` spelling exists in exactly TWO places,
`shapeCommand` and `complete_cmd`. `INNER_BOUND_ARGS` in the same hook carries the identical
flag TRIPLE but only ever onto `--chain-done`, so it shares the ARGUMENTS and not the verb;
do not read it as a third `--tdd-complete` renderer. Since the round that consolidated them
the two no longer share a spelling either — they share an IMPLEMENTATION,
`zensu_autopilot_link_args`, which is the single SHELL renderer of that triple and is pinned
at exactly one site by `C45`. **That pin is file-scoped and the contract is not:**
`hooks/post-review-tdd-delegate.sh` builds the same string from its own `AUTOPILOT_*`
globals, and `hooks/lib/chain-recovery-v1.js`'s `shapeCommand` builds it in JS, where a
shell function is structurally unreachable. Two residual copies, named here rather than
implied by a claim of oneness. §"Requirements-Table Gate" keeps the
tree-wide roster of bound `--tdd-complete` spellings — consult that rather than a count here.
**A BLANK value falls back rather than disabling** — `Number('')` is `0`,
which passes the `>= 0` bound, so treating blank as absent is what keeps a wrapper fault from
silently deleting the row. **`0` emits an explicit switched-off `OK` row**, the same rule
`hooks.reviewerSpawnPermissionCheck` follows: a disabled check must never be
indistinguishable from a clean one.

**The refused-spawn branch NAMES the exit and states the refusal beside it — it does NOT
withhold the verb, and the reversal is recorded because the withholding version shipped and
looked right.** Completing while the refusal stands really does move the chain into a gate the
host will not let it pass, and every later Stop then blocks until the cap releases; that is why
withholding was chosen. What it missed is that `reviewer_spawn_denied` carries NO generation or
recency bound — it answers `blocked` for the last reviewer result anywhere in the module's
bounded transcript tail — and that on THIS surface the self-correction §"Host-Refused Reviewer
Spawn" relies on ("as soon as one spawn is attempted") cannot occur: this path never blocks, so
the cap never releases it, and withholding the verb keeps the chain where no ticket can be
issued and therefore no spawn attempted. One stale refusal pinned every later turn into the
withhold arm for the rest of the session — a state with no exit, adopted to avoid one that at
least ends at the cap. A real bound needs an arming instant to compare a transcript timestamp
against, and the workflow document carries none (`history[].ts` is optional and empty in
vanilla), so it is a schema field and a MINOR release; it is deliberately NOT paid for here.
`C27` pins the current contract and its comment records the reversal, so a later reader does not
restore the withholding from this paragraph's first sentence.

**The branch MINTS a denial note, and that is what makes the two surfaces agree.**
`reviewer_denial_note_clear` runs in the SAME `if` statement as `zensu_impl_stop_nudge`, with
`outer_finish` between them — and naming that middle call matters, because it is the one that
can set `DECISION_EMITTED` and make the nudge return before it can re-mint, so a durable
Autopilot block landing there leaves the note cleared and unminted. Without a mint here the
diagnosis died with the Stop: `reviewerDenialRows` returns early on an empty note
set and `/zensu:doctor` said nothing about the refusal, while its own implementing-turns row went
on printing `--tdd-complete`. The row now QUALIFIES `report.nextCommand` with a caveat while a live
note for its own session key exists, and NEVER withholds it — which is why `chainRows` takes the
`.zensu/state` listing and its directory as two optional trailing arguments. Withholding is what
this paragraph described for one committed revision, and restoring it from an older reading would
reinstate both defects the reversal removed: an unauthenticated note in a session-writable
directory able to delete the row's only remedy, and a single clean-tree Stop clearing the note
while the row still renders off the persisted counter. The liveness rule is shared, not copied:
`classifyDenialNote` returns `live|stale|rejected|missing` so `reviewerDenialRows` keeps its
three buckets while `ownRefusalNoteLive` tests for one, and `denialKindsAllowed` is the single
module load. `C27n` pins the mint; `C35pre`/`C35`/`C35s`/`C35r` pin the un-noted, live-note,
stale-note and shape-rejected arms, ALL FOUR of which require the command to be present.

**`REVIEWER_SPAWN_ALLOW_RULE` is module-scope for an ORDERING reason, not a style one.** Its two
consumers sit on opposite sides of the file: `DENIAL_RULE` in the blocked-Stop branch, and the
nudge, which runs from an early exit ABOVE that branch and therefore cannot see an assignment
made there — the same constraint the `complete_cmd` renderer states about `LOG_COMMAND`. The
nudge shipped one round naming no rule and no file at all. It names ONLY the user-scoped
settings path, for the reason §"Host-Refused Reviewer Spawn" gives.

**The probe excludes the plugin's own `.zensu` tree**, and that is not cosmetic: Phase 2
writes a plan and a log there unconditionally, so in any repository that tracks those
artifacts — which this repo's own artifact policy encourages — every chain would read as
dirty from its second turn and the predicate would stop discriminating. The probe is
watchdog-bounded WHEN a watchdog EXISTS — the unqualified form stood here eighty lines above
its own correction in the gap list. The ladder is `timeout`, then `gtimeout` (the spelling a
Homebrew coreutils install puts on PATH), then unbounded; on base macOS NEITHER exists, so
there the last arm is what runs. The SAME conditional applies to a second
child: the refused-spawn branch puts the transcript probe on this path too, and that read has
no deadline on the same hosts. It is the same conditional LITERALLY now — both children call
`zensu_run_bounded`, which exists because the arm added to one of two hand-copied ladders
was missing from the other, and the one left behind was the child whose own comment records
the LARGER exposure (a host-supplied transcript path that may sit on network-backed storage).
**State the CRITERION, not an ordinal — an enumeration here was written as
"a THIRD child" and was already short by one on the day it landed.** EVERY `node` child this
path spawns is unbounded on hosts without `timeout`, and the TWO the lease adds carry no
`timeout` guard on ANY host: the denial-note writer and the reaper's own scan. The counter is
what put both on this path, where they now run on every dirty turn end past the threshold — the
reaper's pre-check used to return before spawning anything, and the mint is what makes it pass
every time. It is guarded by `command -v git`, carries `--no-optional-locks` so a diagnostic
never rewrites the user's index, and takes NO pipeline, because a `| head` would replace
git's exit status with `head`'s and turn a missing repository into a clean tree. It keeps the
THREE-variable `GIT_*` scrub rather than `_tc_git`'s fifteen, deliberately: this probe gates
an advisory, not a refusal, and the finding proposing the wider list was judged a false
positive on that ground.

**Operator-facing accounts that must move with it:** the `implStopNudgeAfter` row AND the
`stop-chain-enforcer.sh` row in `docs/configuration.md`, discipline patch 13 in
`docs/tdd-manager-workflow.md` (plus the patch RANGE in `docs/gates.md`, which is a separate
file and drifts silently — but NOT that file's "bounded-counter enumeration and Mermaid node
label", which this roster named and which do not exist there: a grep for `implStopCount`,
`implStopNudgeAfter` or any counter enumeration in `docs/gates.md` returns nothing, so the
obligation pointed at content that was never in that file), and the implementing-turns bullets
plus the frontmatter `session state` clause in `skills/doctor/SKILL.md` — "the parked-chain
bullet" is what this roster said, and that name was retired on every emitted surface a round
earlier, so a maintainer navigating by it found nothing.
`tests/structure/test-impl-stop-counter.sh` pins the counter, both surfaces, the reset on
re-arm, the `.zensu` pathspec exclusion and its positive control, the non-git inertness and the
schema-membership bite; `tests/structure/test-doctor.sh` `P1mt2`/`P1mt3` pin the row's
three-way wording and its NEGATIVE terminus claim.

**Version: `minor` by policy, and the measurement is recorded beside it rather than used to
argue it away.** §"Runtime Lineage" lists "any field added" to the workflow-state schema as
breaking. Measured: `validateWorkflowExtensions` type-checks only the fields it LISTS and only
when present, so it never rejects an unknown key; `validateWorkflowToken` accepts any
`^[a-z][a-z0-9_-]{0,63}$`, so `impl_guard` passes; and `normalizeChainState` spreads unknown
keys through — an older runtime really does read a document carrying `implStopCount`. The
recommendation stays `minor` anyway: the author of a change is the wrong party to grant it its
own carve-out, and this file records that both existing carve-outs survived on argument rather
than on their author's say-so.

**The verdict is about the RELEASE, not about any single review round, and saying so matters
because a reviewer walked a later round's file list against §"Runtime Lineage" and correctly
derived `patch` from it.** The field lands in `WORKFLOW_INTEGER_EXTENSIONS`
(`session-control-core-v1.js`) and the three counter key sets (`zensu-tdd-phase.sh`); a fix
round that touches neither of those files changes no persisted shape and would score `patch`
on its own. Score the verdict against the whole diff the release ships — here, everything
since the branch point — never against the working-tree diff of the round in front of you.

**Known gaps, accepted and named:**

- **The doctor row's remedy is not RUNNABLE, while the Stop surface's is.** The row
  interpolates `report.nextCommand`, which the owning module renders as a bare
  `zensu-log.sh --tdd-complete …` — no interpreter, no path, no `CLAUDE_PLUGIN_DATA`. The
  Stop hook renders the same verb in full, for the reason its own comment gives: a flag with
  no program is not a command the reader can run. Taking the command from the owning module
  was the right dependency direction and the runnability gap travelled with it. The fix is to
  prefix module-supplied `zensu-log.sh` spellings in the RENDERER — leaving `NEXT_COMMAND`
  alone, since the module cannot know the plugin root — and it belongs to all four chain rows
  rather than this one, which is why it is not taken inside a change set already five review
  rounds deep.
- **The increment joined the WEAKER lock domain, deliberately.** `tdd_increment_counter`
  reaches `_tdd_increment_counter_critical` directly, so this write holds only the CAS lock,
  while the sibling counter on the same hook, `tdd_increment_stop_budget`, takes the EXTERNAL
  lease. The document therefore has two writer classes that do not serialise against each
  other. Taking the lease here was weighed and REJECTED: it is contended precisely on a path
  whose contract is to release immediately, so buying atomicity against a writer class nobody
  has demonstrated running concurrently with this Stop would trade a real every-turn latency
  regression for a hypothetical lost advisory count. The residual is that a lease-only writer
  restoring its own snapshot could revert this count and move `revision`, the CAS token,
  backwards. The split PREDATES this counter; what is new is that a second writer joined the
  weaker side of it. The sibling can afford the lease because its own path BLOCKS, and this
  one cannot for the same reason. `C44` pins that the decision stays recorded at the call site
  and `C46` that the `docs/configuration.md` row does not lend it `stopBlockCount`'s
  atomicity qualifier.

- **The stated packaging condition was NOT met.** The design note asks that the schema change
  travel with another one that is landing anyway; none is. It buys a `minor` of its own.
- **The Windows wall clock is UNMEASURED.** The suite is deliberately absent from
  `tests/profiles/windows-ci.v1.json`, whose shards are already close to their
  `profileTimeoutMs`, so it never runs on the blocking Windows PR shard. It IS in
  `ciStructureTests`, which `run-windows-safety-shard.js` builds the weekly Windows Safety
  structure inventory from, so it DOES run there, with no measurement yet. Say "unmeasured",
  never "POSIX only".
- **No `tests/profiles/ci-shard-weights.v1.json` entry**, so the suite is costed at
  `defaultSeconds`. That file requires a real CI figure and its own note sanctions the
  omission; add it from the first green ubuntu-latest `--ci` run rather than estimating.
- **The threshold is resolved BEFORE the session bind** and is the ONE of the five resolved
  windows that never reads the record root — the pending-review TTL and both owner-activity
  windows are re-resolved against it, and the delivery-route field is resolved from it
  directly after the bind — so it inherits the Config-block root gap the previous
  section names. **The asymmetry is real and was briefly written out of this file in error, so
  it is worth stating with its evidence:** `zensu-doctor.sh` remembers `ZDOC_TTL_PINNED` before
  the bind and, when the record root and `CLAUDE_PROJECT_DIR` differ, re-resolves the TTL from
  the record root into `ZDOC_TTL_REBOUND` unless the caller pinned it. The threshold block does
  no such thing, and says so: "Deliberately NOT re-resolved after the bind." The neighbouring
  sentence in that same comment — "Same canonical-getter rule as the TTL above, and the same
  known bound" — is about the GETTER and the pre-bind read, not about re-resolution, and reading
  it as the latter is what produced the wrong correction.
- **A blocked Stop is not a turn, and that makes the whole check INERT for a healthy durable
  Autopilot run.** `emit_block` sets `DECISION_EMITTED` and the nudge returns on it, so a Stop
  the enforcer itself refuses is neither counted nor commented on — correct semantics, and the
  reason the bound `--autopilot-run …` spelling the notice can build is reachable only for a
  chain whose outer run is already DONE, BLOCKED or CANCELLED: `outer_finish` blocks on this
  very branch for every owned non-terminal run under budget. The standalone path, which is the
  case this feature was built for, is unaffected. The guard has no behavioural coverage: the
  suite builds no durable-run fixture.
- **The own-chain row withholds the green summary for the whole time a legitimate
  implementation runs past the bound**, exactly as §"Foreign-Chain Row" records for a
  same-project sibling. The stderr notice also repeats on EVERY Stop past the bound — nothing
  latches it. Raising the default from 5 to 12 deferred that cost; it did not remove it, and
  saying otherwise would be the "trained away within a day" dynamic the rejections above name.
  **The durable fix is a discriminator, not another number**, and it is NOT implemented: demote
  the row to `OK` when the counter ADVANCED since the previous report — evidence of ongoing work
  — and keep `WARN` only when it did not, which is the parked-versus-busy distinction the row's
  own text claims to make and a turn count alone cannot. It needs somewhere to remember the
  previous reading, and the doctor is read-only by contract, so it is a design change rather
  than a tweak.
- **Counting a turn is now a freshness heartbeat for a NEIGHBOURING row.** The increment goes
  through `mutateWorkflowState`, which stamps `updated_at`, and that field is what
  `documentAgeMs` ages the foreign-open row on. So a chain being counted can no longer age out
  of another same-project session's foreign-open WARN row. The direction is defensible — an
  actively counted chain is not abandoned — but it deepens the "same-project-root sibling
  permanently withholds the green summary" gap the previous section records.
- **PARTLY CLOSED, and the remaining half is what a reader must not mistake for the whole.**
  The gap was that only the literal `0` disclosed, so a large in-range threshold suppressed the
  row silently on both surfaces — and the config carrier is writable from inside a session, so
  that was a silent off-switch for a review-integrity diagnostic with no gate escaped and
  therefore no bypass-ledger entry. `/zensu:doctor` now ALSO discloses at the getter's own
  maximum (999999), in its own row. What is NOT closed: the Stop surface has no such
  disclosure at all — it tests only `> 0` — and the doctor's arm fires at exactly 999999, so
  any value the counter will not reach in a real session still suppresses the row silently
  on both surfaces without saying so — a threshold of 5000 is as effective an off-switch as
  999999 and discloses nothing. Say it that way, never as a numeric RANGE: the default is 12
  and the row renders there, so "every value from 1 to 999998" was false. Keying BOTH surfaces
  on reachability rather than on two literals is the remaining
  fix. **Do not read the new row as closing this bullet.**
- **The watchdog fallback is unbounded, and on base macOS the fallback is the DEFAULT.** The
  ladder probes `timeout`, then `gtimeout` (the Homebrew coreutils spelling), then runs
  `git status` with no deadline at all. MEASURED on the maintainer's own host: neither binary
  exists on base macOS, so the unbounded arm is not an edge case there — it is what runs.
  **Do not describe `|| return 0` as the mitigation.** It tests an EXIT STATUS, so it degrades
  a git that returns and can do nothing about one that hangs, which is the only failure a
  watchdog exists for; an earlier wording here named it as though it covered the hang. Two
  fixes were weighed and both rejected, so this stays a stated bound rather than a TODO:
  making the probe inert without a watchdog would switch the whole diagnostic off on exactly
  the platform it was built for, and a hand-rolled background-plus-poll watchdog adds latency
  to every counted Stop plus a temp file and a killed child on a path whose contract is to
  release immediately. `C42`/`C42a` in `tests/structure/test-impl-stop-counter.sh` pin
  the ladder.
- **The probe is defeated by a mid-run commit and is scoped to the project subtree.** A chain
  that commits each turn measures a clean tree and is never counted — the same accepted hole
  §"Requirements-Table Gate" records for `--tdd-complete`. And `-- .` under `-C "$PROJECT_ROOT"`
  bounds the probe to the project, while the edit-landing audit it points at is repo-root
  anchored, so a project root nested in a larger repository can carry landed edits the audit
  sees and this probe does not.
