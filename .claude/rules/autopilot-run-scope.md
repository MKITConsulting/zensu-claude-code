---
paths:
  - "hooks/lib/zensu-autopilot-state.sh"
  - "hooks/session-start-autopilot-resume.sh"
  - "skills/autopilot/**"
  - "skills/autopilot-release/**"
  - "skills/autopilot-adopt/**"
  - "tests/structure/test-autopilot-*.sh"
---

# Autopilot Run Scope (`hooks/lib/zensu-autopilot-state.sh`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

A durable Autopilot run is scoped by TWO independent axes, and confusing them is the
mistake this section exists to prevent.

- **Who may see and drive it — the OWNER session.** The active pointer is
  `.zensu/state/autopilot-active-<sha256(ownerSessionId)>.json`, built by
  `_autopilot_active_path`. `autopilot_read_active` takes the owner and filters the
  inventory by it: another session's run is not an orphan, not a hidden run, and not a
  conflict — it is invisible.
- **What it may collide on — the WORKSPACE.** The run records `workspaceRoot`, the git
  working tree it drives. `begin` refuses when any nonterminal run in the inventory holds
  the same `workspaceRoot`, REGARDLESS of owner, because that is the resource two runs
  would actually corrupt: one branch, one commit history, one pull request.

Before this split there was one pointer per project root, so two sessions sharing a project
root serialized even when they drove different worktrees, and a run left nonterminal by a
session that no longer exists blocked the project forever.

**`read-active` and `read-workspace` are two questions, and collapsing them re-opens a real
hole.** "What is MY run" is owner-scoped: the resume hook, `plan-approved-delegate.sh`, the
three `stop-chain-enforcer.sh` sites, both `post-review-tdd-delegate.sh` sites, and
`--autopilot-status`. "Does ANY session hold this working tree" is owner-INDEPENDENT and
must stay so: `_autopilot_begin_standalone_tdd_critical`,
`_autopilot_adopt_pending_review_critical`, and both fences in
`_autopilot_deferred_contention_result`, plus `_autopilot_hold_probe`, the callback
`autopilot_workspace_hold_report` runs under its OWN `_autopilot_locked_run`. All five call
`_autopilot_read_workspace_critical` DIRECTLY, and the reason DIFFERS per group —
saying "each is already inside the project lease" is false for half of them. The
two locked fences are inside it. The two contention fences deliberately read
UNLOCKED, because they are reached precisely when the lease could not be
acquired; their own header calls that a read-only proof. What holds for all four
is that none of them may take a SECOND lease acquisition. The public
`autopilot_read_workspace` is the wrapper for callers
OUTSIDE it — it takes the lease itself — and it has exactly ONE: the
`post-review-tdd-delegate.sh` preflight, which passes a single argument. **A SECOND
lease-taking public reader of the owner-independent question now exists and deliberately does
NOT route through that wrapper**: `autopilot_workspace_hold_report` needs the worker's own rc
AND the holder record, and the wrapper collapses both into one status — the exact conflation
that verb was built to remove. Say "two public readers", never "one wrapper". The Stop hook's rc=4
read was deleted when the fence began publishing its sentence, so the wrapper's preference
parameter currently has no production caller at all — S7h2 guards it for the next one. The symbol to look for is `autopilot_read_workspace`'s third
parameter, not a line number. Do NOT restate this as "there is deliberately no public
wrapper": that sentence stood here while the delegate was already calling one, and
it now contradicts the rc=4 account below in the same section. Owner-scoping that second group would let a
standalone `/zensu:tdd` chain arm underneath another session's durable run in the same tree.
The team-review identity check is a THIRD shape: it resolves the owner from the RUN record
and then asks the first question, because the pointer that must still designate that run is
its owner's, not the attesting caller's.

**The two deferred-review fences ask the owner-independent question and then WEIGH the
answer; that is not a fourth shape and it is not owner-scoping.** They still call
`_autopilot_read_workspace_critical` and a foreign run is still fully visible to them —
what changed is the CONSEQUENCE of a hold. `_autopilot_workspace_hold_blocks_adoption`
refuses on either of two independent grounds: the holder's `ownerSessionId` equals this
session (in production only reachable when the owner-keyed pointer read failed while the
run record is live, so releasing would infer completion for an active OWN generation), or
`_autopilot_deferred_work_present` reports deferred-review work. With neither, the fence
returns **6**, the code the Stop hook already treats as a normal no-work result. Every
unreadable input — an absent holder, an unparseable record, an unresolvable pending path —
answers BLOCKING, so the relaxation costs nothing fail-open. Only the FIRST fence of
`_autopilot_deferred_contention_result` takes this; its second fence stays unconditional,
because `tdd_pending_review_owned_by_other` has proven a foreign claim by the time it runs.

**`_autopilot_deferred_work_present` TRACKS `_tdd_adopt_pending_review_critical`'s "no
work" verdict; it is a HAND COPY of that ladder and must never be described as "the exact
predicate".** A bare `[ -f ]` existence test disagrees with the owner in BOTH directions and
each disagreement costs something real, which is why the copy carries three parts rather
than one. An UNSAFE marker — symlink, FIFO, directory, dangling link — is tamper evidence
the owner REFUSES on (`_tdd_path_safe … regular-or-absent`), so a bare test would relax the
fence on exactly the state the owner blocks on; the copy applies the same guard and reports
work PRESENT. A plain marker past the TTL is "no work" to the owner, which DELETES it and
returns 2 — so reporting it present rebuilds the permanent wedge, and because the fence
returns before that deleter runs, nothing would ever reap it either; the copy therefore
takes `ttl_hours` (threaded from `$4` in the locked fence and `$3` in the contention one, and passed on as the FIRST argument)
and excuses it through `_tdd_pending_file_stale`. A stale CLAIM is deliberately NOT excused,
because the owner reconciles a claim rather than dropping it. The residual divergences are
named rather than papered over, and the honest form is GENERIC because an enumeration goes
stale: any state the owner reaches only AFTER reading claim METADATA is "no work" to it and
"work present" here. Three exist today — a claim whose reconcile status is `owned`, a
`done|cancelled` claim with no queued marker, and a `done|cancelled` claim whose queued marker
is itself stale — all over-approximations that keep a refusal, never a relaxation. Note also
that the copy reads the marker under the OUTER lease only, never the pending lease that
governs it, so a marker published concurrently can read as absent. The marker is never LOST by
that: it stays queued, and the next Stop that samples it acts on it — with the tree free that
is the adoption, under a foreign hold it is the fence refusing again. What a missed sample
defers is therefore the REFUSAL, never the adoption, which is the same correction the
known-gap paragraph further down states in full; keep the three sites in step and do not
reintroduce "a later Stop adopts it", which names an outcome the held case cannot reach. The
standing fix for all of this is to export the source-selection
ladder from `zensu-tdd-phase.sh` so both modules call one predicate.

The threading is `ttl_hours` FIRST, `root` second, in both helpers — they take their two shared
operands in the same order on purpose, because both are optional with defaults and a
transposed call would produce a plausible-but-wrong anchor rather than an arity error.

**The own-run arm weighs an IDENTITY, so it must not be decided by filename sort order.**
`read-workspace` reported `inventory.find(...)` — the first nonterminal holder by sorted run
filename — and several runs can hold one tree, because a record carrying no `workspaceRoot`
holds EVERY tree in its project. A legacy foreign record sorting first would therefore
shadow the caller's own live run and flip the arm from block to release. The mode now
filters to ALL holders and accepts an optional fourth argument, a preferred
`ownerSessionId`, which both fences pass. **This does not owner-scope the question:** the
preference selects WHICH holder is reported, never WHETHER the tree is held, and with no
preference supplied the result is byte-identical to the first holder. `path_indexes` for
`read-workspace` stays `(0 1)` — the new argument is an identifier, not a path.

**What that fixed, stated because it was a shipped defect and not a hypothetical.** The
check ran BEFORE anything asked whether a deferred review existed, so a session whose own
chain was inactive (`OUTER_PRESENT=false` plus `SESSION_ACTIVE!=true` → `ADOPT_ELIGIBLE`)
was denied at Stop by a foreign run it had nothing to do with — and, because occupancy is
CONTAINMENT in both directions, by a run whose worktree merely sat below its tree. Measured
on 0.19.0 against a live consuming project: `autopilot_read_active` correctly answered
`rc=1` for the foreign session while `autopilot_adopt_pending_review` answered `rc=4`, with
no `pending-review.json` anywhere in that project. **`test-autopilot-stop-enforcer.sh` S7
PINNED that behaviour** — a foreign session's Stop was asserted to `block` — so this is a
deliberate policy change, not only a bug fix: S7 now asserts it RELEASES and still mutates
nothing, `S7d` is the discriminator that a queued deferred review restores the refusal, and
`S8g` is the control that an own active generation still fails closed. Do not "restore" S7.

**The rc=4 refusal names the holder, and that is load-bearing rather than cosmetic.** THREE
sites ON THE DEFERRED-REVIEW ADOPTION PATH produce rc=4 and all three render the existing
`_autopilot_workspace_refusal` on stderr — the locked fence, and BOTH fences of
`_autopilot_deferred_contention_result`,
including the second one, which refuses unconditionally and had been discarding the record.
State that base: `_autopilot_begin_standalone_tdd_critical` is a FOURTH caller of the same
renderer, on the standalone-begin path, and it refuses unconditionally — so a change to the
renderer reaches it too, and it passes its own session id for the same reason the three below
do.
That omission mattered precisely because the contention path is reached when the Outer lease
could not be taken, which is exactly when the hook's own lease-taking read fails too: the run
id was then named on NEITHER channel. `stop-chain-enforcer.sh`'s rc=4 arm takes the sentence the
fence PUBLISHED and performs no read of its own. It once re-read the holder here, and the rule
then was that the read had to carry `$SESSION_ID` as the holder preference — several runs can
hold one tree, and an unpreferenced read reports `holders[0]` while the fence judged a
different record, so the remedy could point at a run that is not the blocker. Publishing the
sentence removed the read and the rule with it; do not restore either from this paragraph.

**FOUR remedy texts, not one; the distinction is a safety property, and ONE site decides it.**
When the named holder is FOREIGN and ADOPTABLE the block reason names `/zensu:autopilot-adopt`
first and `/zensu:autopilot-release` second — adoption continues the run, release cancels it, and
a cancel reached for first cannot be undone — while the operator stderr line quotes BOTH audited
spellings, `zensu-log.sh --autopilot-adopt --run <id> --confirm` and
`zensu-log.sh --autopilot-release --run <id> --confirm` — one renderer, two audiences, and only
the stderr one is read by a human. A foreign holder whose PENDING stage is `TDD_RUNNING` is NOT
adoptable and takes its own text on both audiences: the adopt verb refuses that run with exit 3
before it reads any beacon, so a refusal offering adoption there sends the reader to a verb that
declines. That text says adoption is not an exit for this run, states that the session driving its
inner TDD chain may still be running, and leaves only the release — the guided form for the model,
the audited one for the operator. The pending stage is what decides it — `blocked.from` for a
BLOCKED record and the literal stage otherwise, the same test the adopt worker applies — and the
`begin` worker's twin of this sentence carries the same arm; S7v and S7m are the pins.
When it is owned by THIS session the
reason must NOT offer that command: the release worker skips its self-release guard in exactly
this state — the guard fires only while the owner pointer still designates the run, and this
arm is reachable only when that pointer read failed — so following it would cancel the
session's own live generation. The third is the unnamed fallback when the holder cannot be
read at all, and it prescribes NO release command either — ownership is unknown on that
branch, and the own-run case is the LIKELY one there, because it is reached under the same
lease contention that made the read fail. Prescribing a release would aim it at this session's
own live generation in exactly the state the renderer withholds it from. So no branch pairs a
run id with a mutating command it has not verified as foreign, and
`_autopilot_workspace_refusal` emits BOTH audited CLI spellings for the OPERATOR audience and
both slash forms, adoption first, for the MODEL audience — one
renderer, two forms, and the audience argument is what selects. The unnamed fallback's own wording is pinned by S7n, and only
by S7n. S8g used to hold it and was re-pointed at the own-run wording when the published
sentence began reaching that fixture, which left it briefly uncovered; S7n is a SOURCE pin,
because the branch is unreachable from any fixture — the fence blocks for every holder it
cannot read, and a `stateValid` record always satisfies the renderer's shape tests. It asserts
the literal quotes no `--confirm` and no `zensu-log.sh` and names both ownership
possibilities. The holder clause is emitted LAST, and the reason has changed: it originally
had to be, because its named form ended in a shell command and anything appended was copied
along with it (an earlier spelling produced `--confirm.`). The MODEL form the block reason now
carries ends in a slash-command name instead, so the ordering is retained for consistency and
to keep a future reword from reintroducing the hazard, not because it is still load-bearing.

**A SECOND copy of the foreign sentence lives in the `begin` worker mode**, emitted from the
JS when a durable begin is refused, and it is pinned in a DIFFERENT suite
(`tests/structure/test-autopilot-state-machine.sh` W3, which greps the `workspace held by
nonterminal run …` lead and the `/zensu:autopilot-release` guided form, and asserts `--confirm`
is ABSENT — do not send a maintainer looking for a needle the suite now forbids). It
carries NO own-run branch, and the reason is ORDERING rather than a missing identity: the worker
DOES have the caller's `ownerSessionId` in that mode. What keeps the text foreign-only is that
the own-run cases above it (`hiddenNonterminal`, the pointer's own nonterminal run) already
`fail(4)`, and `candidate.runId !== runId` excludes the last survivor — so no own run reaches
that branch. Those checks must stay ABOVE it; widening them would emit a foreign remedy for the
caller's own live run. S7m now compares the two byte for byte by extracting the worker's
template and rendering the helper against the same run id, so a reword of either turns that
check red; before it, the two were pinned only in separate suites and could drift silently.

**The own-vs-foreign choice belongs to the RENDERER, and putting it anywhere else fails open.**
`_autopilot_workspace_refusal` takes the caller's session id as its second argument and selects
the wording itself; every caller that can see its own run passes it. The argument is POSITIONALLY
REQUIRED and only its VALUE may be empty — the renderer refuses on `[ "$#" -eq 3 ]`, so "optional"
was the wrong word for it and a two-argument call does not fall back to a form, it refuses. An earlier
spelling decided it in `stop-chain-enforcer.sh` from a second `_autopilot_holder_owner` read,
and that read's failure mode was the dangerous one: an unresolvable owner compared UNEQUAL to
the session id and selected the FOREIGN text, so the hook offered the release command against
this session's own live generation exactly when it could not establish ownership. Worse, the
library's own stderr line still quoted that command regardless, so the withholding was
contradicted on the operator channel. One decision site, inside the renderer, removes both:
the hook now resolves two names rather than three, and its only failure mode is the unnamed
fallback. A caller that omits the id gets the foreign wording — so omitting it is the thing to
check when a new call site is added. **Two arguments, not one:** a site that renders the
holder must ALSO forward the preference to the READ that produced it. The standalone-begin
fence passed the id to the renderer and not to the read for one round, which meant it could
never emit the own-run wording and would quote a release command against whichever record
sorted first. Three reviewers found that independently; treat "renders the holder" as
implying both.

**The fence PUBLISHES its rendered sentence, and the hook prefers it over re-deriving one.**
`_autopilot_publish_workspace_refusal` sets `ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT` beside every
rc=4 render, and BOTH public entry points — `autopilot_adopt_pending_review` and
`autopilot_begin_standalone_tdd` — clear it first, so a stale sentence can never be reused.
(The name carries the library prefix on purpose, and so do the two names the adoption block
publishes — `ZENSU_AUTOPILOT_ADOPTED_PREVIOUS_OWNER` and `ZENSU_AUTOPILOT_ADOPT_OUTCOME` — because
all three are read by name across a file boundary: this one by the Stop hook, the adoption pair by
the `--autopilot-adopt` arm of `zensu-log.sh`. Only this one is DECLARED at module scope; the
adoption pair is assigned inside the verb that publishes it. The hold-report verb added two further
module-scope declarations, `_ZENSU_AP_HOLD_RECORD` and `_ZENSU_AP_HOLD_WORKER_RC`, and those carry
the underscore-private prefix deliberately: they are an intra-file callback channel read only by
`_autopilot_hold_probe` and `autopilot_workspace_hold_report`, never across a file boundary — which
is exactly what the three unprefixed names are NOT, and the house precedent for a sourced-library
global the Stop hook reads by name is `ZENSU_SAFE_VERSION_RE`.) **TWO forms are rendered from one holder.** The OPERATOR form goes to
stderr and quotes the audited `zensu-log.sh --autopilot-release --run <id> --confirm`, because a
human reads it. The MODEL form is what the block reason carries and names `/zensu:autopilot-release`
INSTEAD — `--confirm` is the consent control, so a complete invocation in a model-facing channel
routes around the only place that control exists, and a bare `zensu-log.sh` is a name a model
would resolve against the repository it is standing in. S7k pins all three shapes. This exists because the hook's own read happens AFTER the lease is released and the
worker reports `preferred || holders[0]`: a second FOREIGN run publishing in that window could
be named instead of the record the fence judged, and the rendered remedy quotes a real CANCEL.
Deriving it once, under the lease, from the judged record closes that window — and it made the
CONTENDED path strictly better, which is the measurable part: S8g now sees the run NAMED with
the own-run wording where it previously got only the unnamed fallback, because the contention
fence's unlocked read succeeds exactly when the hook's lease-taking one cannot.
`_autopilot_locked_run` runs its callback in the current shell and the Stop hook calls the
public verb without a subshell, which is what lets a variable carry it.

**The hook now takes the published sentence and NEVER re-derives one**, and the fallback that
briefly stood beside it was deleted rather than kept. Its stated trigger — "a runtime that does
not publish" — was unreachable (the plugin root is derived from the hook script itself and
re-checked, so hook and library are always one tree), while its REAL trigger was a failed render
— in which case a second read is a fresh chance to name the WRONG run, not a recovery. Deleting
it removed this file's last module-private `_autopilot_*` call: `hooks/` outside this library now
contains none. The suite still drives five private helpers directly, which is what
S7f/S7f2/S7g/S7h/S7j/S7k/S7m rest on.

Assertions inside ONE suite pin the wording — `tests/structure/test-autopilot-stop-enforcer.sh`
S7d's guided-form needle plus its assertion that `--confirm` is ABSENT — the AUDITED
`--autopilot-release --run <id> --confirm` needle moved to S7k when the block reason took the
model form, and S7k carries the `grep -qF --` guard that spelling still needs (without it grep
parses the pattern as options and the check passes vacuously, which it did),
S7d's positive assertion on the `Retrying Stop cannot clear the hold` clause — it was a
NEGATIVE assertion on a literal that existed nowhere in the tree, which could never fail and
left AC-004's no-retry-advice half unpinned — S7i's containment-case naming needle, S7k's three-shape renderer pin (operator form quotes the
audited command, model form names only the guided skill, own-run holder is offered the guided
`/zensu:autopilot-adopt` and never `/zensu:autopilot-release`)
(the release command must be ABSENT there and present for a foreign holder), S7j's negative
shape tests on both renderers, S7n's source pin on the unnamed fallback (behaviourally
unreachable, so a source pin is the only available control), S8i's end-to-end own-run pin (the run named, the release
command absent), S8g's contended own-run pin (the same property reached through the PUBLISHED
sentence rather than the hook's read), S7m's byte comparison of the `begin` worker's twin
against the renderer, and the shared `holds this working tree` lead — so rewording it
is a same-suite edit, EXCEPT for the own-run clause: S7o pins `whose run record names this session as its owner`
and `finish or repair that run` against `skills/autopilot-release/SKILL.md`, which teaches the
model to recognize that case by those literals. The needles are deliberately different: a bare
`autopilot-release` substring matches BOTH branches and would have let the named and unnamed
paths pass each other's check.

**The relaxation DISCLOSES.** `_autopilot_workspace_hold_blocks_adoption` prints one stderr
line before returning false, because rc=6 is otherwise indistinguishable from "no run held the
tree at all" and a guard that stands down invisibly is the shape this repository treats as
worse than the wedge it removes. It is not a bypass-ledger entry and must not become one: no
user-supplied switch was escaped. **The premise under that argument is UNVERIFIED and is
recorded as such:** nothing measured in this work establishes that this host surfaces
Stop-hook stderr to the user on a non-blocking exit 0. If it does not, the relaxation has no
observable at all and the disclosure argument above buys nothing — so verify it before
leaning on it, and do not restate the claim as though it were established. S7g captures that stderr separately and requires it — the
hook fixtures cannot, because `invoke()` discards stderr, so without a direct capture the line
could be deleted with every check green. **Accepted cost, named because it is not obvious:**
the line is UNRATED and the state that produces it is a steady state, not an event — an
ordinary session with no own run and no active chain reaches `ADOPT_ELIGIBLE` on every turn
end, so the disclosure repeats on every Stop for as long as the foreign run stays nonterminal.
Gating it would remove the observability it exists for; the repetition is the price — but
the price has a known, unpaid remedy and it is named here rather than left to be rediscovered:
this repository already ships the shape that keeps the observability without the noise, the
per-session band file in `user-prompt-context-nudge.sh`, which here would key on the pair
(session, holder run id) so the line prints once per hold rather than once per turn end. Not
implemented; a follow-up, not a defect.

**Two ordering rules inside the fence, both learned by having them wrong.** The ladder
has the WORK arm LAST, and every arm above it returns the same value — 0, blocking. So while a
marker exists a `blocks` result is UNATTRIBUTABLE, and a check that drives the guards then
proves nothing about any of them. State the mechanism, not the outcome: an earlier wording here
said the work arm "masks every guard above it", which has the order backwards. That is why S7f keeps only
the marker-decided arm and S7f2 re-drives every input guard, plus the claim and unsafe-marker arms, after `rm -f`. And the `root`
parameters default to `${CLAUDE_PROJECT_DIR:-}` rather than to empty — an empty value is
indistinguishable from unset to `_tdd_path_safe`, so defaulting to empty would CLEAR a correct
anchor and reinstate the nearest-existing-ancestor fallback the parameter exists to prevent.

**The library ALSO writes that sentence to stderr from inside the fence, and the redundancy
is deliberate.** They serve different consumers — operator stderr versus the model-facing
block reason — and it is the CONTENDED case that needs both: there the library renders a
NAMED line from its unlocked read while the hook's lease-taking read fails and falls back to
the unnamed remedy. Removing either loses the run id on one of the two paths. Accepted cost:
on a contended Stop the user can see the sentence twice, and the two reads are taken at
different instants.

**Version: `patch`.** Walked against §"Runtime Lineage" entry by entry: no context-record or
workflow-state schema field, no strict key set (the run schema's `STATE_KEYS` /
`STATE_KEYS_WORKSPACE` are untouched), no hook added, removed or renamed and no matcher
changed, no new config key (the fence reuses `zensu_pending_review_ttl_hours`), no
attestation change. The `read-workspace` worker mode gains an OPTIONAL fourth argument, which
is a call convention inside one installation and never a persisted shape — an older runtime
passing three args gets its previous answer. The Stop hook denies strictly LESS than before,
which cannot make state written by one runtime unreadable to the other; the capability rule
in that section is about ADDING a hook that can deny, and relaxing an existing hook's deny is
not in the list. Recorded here because this section carries FOUR `**Version.**` paragraphs: the `minor` one
describes the ORIGINAL pointer/schema change, this one the run-scope delta, a third the run
ADOPTION delta and a fourth the run-visibility delta. A releaser matching on the wrong one gets
the wrong answer. The count read THREE here and in both later paragraphs while the tree already
carried four, and the omitted one was the adoption verdict that covers a commit on this branch —
so re-derive it with `grep -n '^\*\*Version' .claude/rules/autopilot-run-scope.md` rather than
trusting any of the three numerals.

**The audience is a property of the CHANNEL, and all FOUR model-read channels are routed to
the guided form.** The fourth arrived with the `--autopilot-status` stderr disclosure; the three
original ones are named below. The two that a first pass left behind were `_autopilot_begin_standalone_tdd_critical`'s
stderr — the tool RESULT of a `zensu-log.sh --tdd-begin` a model runs — and the `begin` worker's
own `fail(4, …)` twin, surfaced by `zensu-log.sh` the same way. Both now emit
`/zensu:autopilot-release` rather than a runnable `--confirm` invocation, which cost W3 and W13
in `test-autopilot-state-machine.sh` and re-pointed S7m at the renderer's MODEL form. The
OPERATOR form survives on exactly one channel: the Stop hook's stderr, where a human reads it.
`_autopilot_publish_workspace_refusal` therefore takes the stderr audience as its third
argument, and `_autopilot_workspace_refusal` REFUSES an unrecognized audience rather than
defaulting to the permissive spelling.

**CLOSED, and recorded so it is not re-opened as a gap:** the contention fence's
foreign-holder-WITH-WORK rc=4 arm had no executed case — S8g reaches that fence through the
own-run arm and S8h through the release arm — and S8j now drives it, asserting the run is named
and no runnable cancel is quoted.

**Known gap: the `root` parameter of `_autopilot_deferred_work_present` and
`_autopilot_workspace_hold_blocks_adoption` is UNPINNED, for TWO reasons and the second is
structural.** Asserting that the fence blocks pins nothing there, because the
predicate fails closed and every failure mode gives that same answer. The discriminating shape
needs the anchor alone to decide, and an attempt at it did not reproduce that split — the marker
path is resolved through `zensu_resolve_project_dir` rather than through the symlinked component
such a fixture plants. And every fixture in that suite lives under `$TMP`, while
`_tdd_paths_safe` always trusts `${TMPDIR:-/tmp}` as an anchor, so the argument can never BE the
deciding anchor there. A discriminating check needs a fixture rooted outside both `TMPDIR` and
`HOME`. Recorded rather than papered over with a check that passes for an unestablished reason.

**Known gap: `_autopilot_deferred_work_present` tracks the MARKER half of the owner's ladder
only.** (Anchor by SYMBOL, not by line: every line reference into this file went stale within a
round while the symbol names did not.) Any claim file
at all reports work present, while the owner reads claim METADATA and answers no-work for a
claim reconciled `owned` by another session and for a `done|cancelled` claim with nothing
queued. So with the tree free those states release, and under a foreign hold they still block —
the same class of refusal this change removes, one case narrower. Direction is a retained
refusal, never a relaxation, which is why it ships; closing it needs a read-only reconciliation
status `zensu-tdd-phase.sh` does not export, which is the recorded standing fix.

**Known gap: the own-run arm is a correctness guard, not an authorization boundary.** It
decides on `ownerSessionId`, an unauthenticated field in a directory this file elsewhere
records as session-writable, and `stateValid` checks only its SHAPE — there is no MAC and no
counter over a run record. So a session can flip its OWN fence between block and relax by
editing its own record, exactly as it could already by deleting it. The holder preference
closes the ACCIDENTAL shadowing (a legacy foreign record sorting ahead of the caller's live
run); it does not close a deliberate write, and nothing here should be read as doing so.

**There is a SECOND direction, and it runs the other way.** The preference selects the holder
by `ownerSessionId`, so a co-tenant that writes ONE shape-valid record carrying a VICTIM's
owner id and a `workspaceRoot` containing the victim's tree steers that victim's fence onto the
own-run arm — and the own-run arm withholds the release command and names a run the victim can
neither see through `--autopilot-status` (which is owner-scoped) nor release. The direction is
non-destructive and it cannot make a fence RELAX: the own-run arm blocks. But it is a foreign
writer changing what another session is told, which is more than "a session can flip its own
fence", and the state directory is writable from inside any session in the project.

**Known gap: a stale marker under a held tree is never reaped.** The release arm returns
before `tdd_adopt_pending_review` runs, and that call is what owns the `rm -f` for an expired
marker. The marker is inert while stale and is reaped by the first adoption after the hold
clears, so this is a leak rather than a wedge — but the fence's own comment argues the
reaping asymmetry against the OPPOSITE choice, and it applies to the branch that shipped too.

**Known gap, accepted and named: work-presence is sampled once, unlocked, at BOTH fences.**
Scoping this to the contention path was wrong and read as if holding the Outer lease made the
locked fence immune. It does not: the Outer lease and the PENDING lease are different
resources and `_autopilot_deferred_work_present` takes neither, so
`tdd_write_pending_review` — which takes the pending lock — can publish a marker that either
fence misses. The contention fence has the sample outside its own check-prove-recheck bracket
as well, but that bracket only ever re-read OCCUPANCY, so it was never the thing that would
have covered this.

State the consequence precisely, because an earlier wording got it backwards: what is deferred
is the REFUSAL, not the adoption. A missed marker makes this Stop RELEASE; on the next Stop the
marker is visible, so the fence sees work in play and the foreign hold BLOCKS again. The marker
is never lost, and no Stop adopts anything it should not — but "a DEFERRED adoption" described
an outcome that does not occur, since a held tree is exactly where adoption does not happen.

**CONTAINMENT is pinned, and it took a real git fixture to do it.** Every other check in the
suite builds a plain `mktemp -d` project, so holder and stopper resolve the SAME workspace
key and only EQUALITY is exercised — the containment branch of `mayHoldWorkspace` is never
taken. S7i is the one that reaches it: `git init` plus `git worktree add` of a NESTED
worktree, the run begun with that worktree declared through `autopilot_begin_run`'s sixth
argument, and the Stop driven from the CONTAINING tree. It asserts both directions in that
one tree — release with nothing queued, and a refusal naming `contain_run` once a marker
exists. That is the exact shape of the reported production defect, so it is the check to
keep working if the fixture ever goes red. Note the two prerequisites it silently needs: a
usable `git worktree` (it fails loudly rather than skipping if the directory is absent) and
`autopilot_begin_run`'s workspace override, which refuses anything that is not itself a git
toplevel.

**One resolver decides the workspace for the writer and for every gate.**
`_autopilot_session_workspace` resolves cwd → git toplevel → canonical path, and falls back
to the project root when cwd is outside it. `autopilot_begin_run` and all three occupancy
gates call it. Two different spellings would make a gate silently miss the run it exists to
see. `--autopilot-begin --workspace <path>` overrides it, but only for a tree that is either the session's own resolved tree or a directory under the project root; anything else refuses with rc 3. Accepted narrowing: a git worktree OUTSIDE the project root can no longer be declared.
`workspaceRoot` is deliberately NOT a member of any `path_indexes` list in `_autopilot_node`:
it is a comparison key rather than a path the worker opens, and it may legitimately sit
outside the project root, which `_autopilot_native_project_path` rejects by design.

**The field is accepted in BOTH key shapes on purpose.** `stateValid` admits `STATE_KEYS`
and `STATE_KEYS_WORKSPACE`, and `mayHoldWorkspace` short-circuits on an ABSENT field, so a
record minted before the upgrade holds EVERY workspace in its project — not its `projectRoot`,
which is what an earlier draft of this paragraph claimed and what the deleted `workspaceOf`
fallback would have implemented. A single strict key set would make every run minted before
the upgrade invalid, `readRunInventory` fails the FIRST invalid record, and the whole project
would then fail closed — strictly worse than the wedge this work removes.

**The occupancy comparison is CONTAINMENT, not equality, and it runs in both directions.**
The key is a git toplevel resolved from the CALLING process's cwd, and the writer and the
gates are different processes: a session that begins a run from the project root and later
reaches a gate from a worktree BELOW it produces two different keys for one branch. `contains`
answers "held" whenever either tree contains the other, which also covers the git-failure
fallback — that path yields the project root while a working resolve yields the repository
toplevel above it. Equality alone reported such a pair as free, and a standalone `/zensu:tdd`
chain then armed underneath a live durable run.

**The FORWARD direction is the one that is not solved, and concurrency makes it normal.**
`begin` writes `workspaceRoot` while still declaring `schemaVersion: 1`, so an installation
WITHOUT this change reads an unknown key at a version it claims to support and rejects the
record. Two mitigations, and the residue between them is stated rather than glossed. First, the
blast radius is bounded: `read-active` now passes its owner into `readRunInventory`, which skips
a record it can prove belongs to someone else BEFORE validating it, so one session's
unreadable record no longer fails every session in the project. Anything unattributable — a
record that will not parse at all — still fails closed, because it cannot be proven to be
someone else's. Second, `begin` and `read-workspace` deliberately pass NO owner and stay strict:
they genuinely need every record. The residue: an older installation running `begin` in a
project where a newer one is live still fails closed, and that is not tested because the suite
has no second installation to run it from. The lineage rule does not cover this — it governs
Session Control record binding, not the project-local run inventory — so a MINOR release is the
only thing standing between the two.

**The `--confirm` on `--autopilot-release` is prose-backed, not consent-backed.** It is an argv
token the model can supply to itself, exactly like `zensu-session-adopt.sh --confirm`, and the
"wait for the user to say yes" control lives in `skills/autopilot-release/SKILL.md`, not in a
gate. Say so plainly rather than describing the flag as user confirmation. What bounds the
damage MECHANICALLY is that it escapes no gate and cannot forge `DONE` — the worker only ever
applies `CANCEL`. Everything else is prose: the skill tells the model to take the run id from a
refusal, but nothing enforces that, and any nonterminal run in the project is releasable by id
from an enumerable directory. Nor is liveness checked: a run whose owner session is very much
alive is cancelled just as readily. `.zensu/state/` is already writable from inside a session by
an ungated shell redirect, so the flag is not the narrowest channel to that directory either.

**The legacy pointer is adopted only by its own owner.** `autopilot-active.json` is never
written any more. When the owner-keyed pointer is absent it is read as a fallback and honored
only if the run it references belongs to the caller; a legacy pointer owned by anyone else is
ignored, and that is precisely the unwedge. `activePointerFileFor` is the one resolution ladder for callers that resolve a run's pointer FROM THE RUN RECORD — say it that way, never "the ONE resolution ladder inside the worker", which is false: `read-active` resolves its own pointer INLINE and calls neither accessor, and its legacy predicate is deliberately DIFFERENT (the referenced run must be in the owner-scoped inventory AND carry the caller's owner id, where this ladder accepts a legacy pointer on `legacy.runId === runId` alone). Two ladders, two rules, and a maintainer who edits only this one on the strength of the retired sentence leaves the verb that REPORTS a run and the verb that RETIRES its pointer disagreeing about which pointer designates it. It returns
`{file, pointer}` so a caller that must retire the pointer names the file it actually read
rather than one re-derived from the owner digest — which pointed at nothing whenever the legacy
fallback won. `activePointerFor` is a three-line derived view over it that keeps only the
pointer. Together they have SIX consumers, not the two that phrase named: `apply`, `release`,
the adopt already-owner branch, both budget modes — all of which receive the state DIRECTORY
rather than a pointer path and derive the owner from the run record — plus adopt's retire path,
the only site that takes the pair.

**`--autopilot-release` bypasses exactly one check.** It applies a real `CANCEL` under the
project lock with the ownership comparison skipped, and refuses a terminal run, a caller that
owns the run WHILE that owner pointer still designates it (a torn `begin` whose pointer never
landed stays releasable — the `fail(4)` sits inside `if (ownerPointer && ownerPointer.runId ===
runId)`), and an exhausted ledger. Provenance is the derived event id (`release-<sha256>`),
NOT a payload field: `payloadValid` requires `CANCEL` to carry the empty object, so a marked
payload would make the released run unreadable to any runtime that has not taken this change.
**No bypass-ledger entry** — the ledger records gate ESCAPES so that everything under "Gates
bypassed" is true, and this escapes no gate. Same rule, same reason, as `--chain-recover`.

**Version.** The pointer layout and the run schema both move, so this is a **`minor`** release
under "Runtime Lineage (`version_type` is load-bearing)" above. The version is never set by
hand; the release pipeline owns it.

**Run ADOPTION is release's constructive counterpart (`autopilot_adopt_run` / the `adopt`
worker mode).** A session id can change while the conversation continues —
`FRESH_SESSION_SOURCES = {startup, clear, fork}` in `claude-session-control-v1.js` mints a
fresh record for `fork`, and the same branch is reached by a resume whose record was pruned —
and ownership does not follow. The successor is then locked out three ways at once: the run is
invisible to its owner-scoped `read-active`, every event path compares the owner, and release
refuses while the previous owner's document still looks fresh, all while the workspace hold
refuses any new chain in that tree. **The takeover cannot be inferred and that is measured, not
assumed:** the SessionStart payload carries only `session_id`, `source`, `cwd`,
`hook_event_name`, `agent_id` and `agent_type` — no predecessor id — and
`relatedClaudeSessionContexts` compares two records for the same project, plugin root and
runtime digest and asserts NO descent. So the verb is human-authorised, by the same
prose-backed `--confirm` this section already records for release — and, unlike release, the
SAME command without `--confirm` is a read-only REPORT over the same ladder: it prints the
liveness verdict and what `--confirm` would do, writes nothing, and exits with the code a
confirmed run would take, so the yes the skill asks for is given knowing whether the age check
will even run. The worker takes a `report` operand and returns before every install; the shell
hands it two never-created placeholder outputs, which `writeOutput`'s pre-creation requirement
would refuse anyway, and publishes no outcome name, so the CLI announces nothing and writes no
provenance. `autopilot_adopt_run` REFUSES a mode that is neither `confirm` nor `report` with
exit 3, because the critical section treats everything but `report` as a confirmed run and a
misspelt mode would otherwise move ownership (B1, B1b and B1c).

**It writes NO event and adds NO field, and that is the whole reason it can ship as a
`patch`.** `stateValid` admits `STATE_KEYS` or `STATE_KEYS_WORKSPACE` and `eventValid` requires
`EVENT_TYPES` membership; `readRunInventory` fails the FIRST invalid record, so one new member
of either set would fail an entire project closed for every installation that predates the
change — the same FORWARD-direction hazard this section already records for `workspaceRoot`.
Only `ownerSessionId`, an existing field, takes a new value. Provenance therefore lives in the
ADOPTING session's workflow `history` under the reserved phase `AUTOPILOT_ADOPTED`, protected in
the same three entry points as `CHAIN_RECOVERED` and `RUNTIME_ADOPTED`, with the literals in two bodies (`zensu-log.sh --phase`, which holds its own literal, plus `tdd_write_phase` /
`_tdd_write_phase_critical`, which delegate theirs to `_tdd_reserved_provenance`), with `tdd_write_autopilot_adopted` in
`zensu-tdd-phase.sh` as its ONE sanctioned writer. That writer appends history and touches
neither `phase` nor `step_id`: those belong to the TDD FSM and an adoption must never move a
running chain's cursor. The provenance write is BEST-EFFORT and deliberately cannot fail the
verb — the record and the pointer already moved under the project lock, so refusing there would
report a takeover that did happen as one that did not; a failed append writes a stderr line.

**The install ORDER inside `_autopilot_adopt_critical` is crash-safety, not style — and BOTH
halves of the justification this paragraph used to give were false.** The caller pointer lands
FIRST and the run record second. A crash between them leaves the caller holding a pointer to a
run it does not yet own, and no reader FILTERS that out: `read-active` REFUSES with exit 2
(`active pointer references a run that is absent or owned by another session`) until a retry
completes the adoption. The reverse order would leave the caller owning the record with no
pointer, which the already-owner branch REPAIRS — so "a retry would never repair it" stopped
being true the moment that branch landed. BOTH orderings are therefore retry-recoverable, but they
are NOT symmetric and the asymmetry runs AGAINST the chosen one. State the record-first bound
EXACTLY, because "unconditionally" was false and the same word had drifted into the code comment
beside the installs: that torn state is repaired whenever the run is still nonterminal, still holds
the caller's tree, and the caller owns no OTHER nonterminal run — `readState`, the TERMINAL refusal
and the `mayHoldWorkspace` exit-6 refusal all sit ABOVE the already-owner branch, and the branch
itself can `fail(4)`. What it does skip is the pending-stage and liveness refusals. The
pointer-first torn state has to re-enter the whole
takeover ladder on retry and stays refused for as long as the previous owner's beacon keeps being
touched. **The order is NOT kept because its torn state is louder** — an earlier wording here said
so, and the code comment beside the installs now refutes it: a missing pointer beside an owned
nonterminal run ALSO makes `read-active` refuse with exit 2, so both torn states are equally loud.
It is kept because its ROLLBACK restores one small pointer file rather than a run record.
Reordering stays a live question this paragraph deliberately leaves open rather than settling by
omission. **A failure of the SECOND install IS rolled back now.** The prior pointer bytes are
copied beside it BEFORE the first install — so undoing it needs no allocation that could fail
after something moved — and a record-install failure restores them, or unlinks the pointer when
there were none. The refusal states which outcome held: `record install failed; the owner pointer
was rolled back and nothing moved`, or a longer line naming the pointer file when the rollback
itself failed. Only a crash between the installs, or a failed rollback, leaves the torn state
described above, and the exit-5 row in `skills/autopilot-adopt/SKILL.md` states both. A pointer
REPAIR installs no record and has nothing to roll back. **Every outcome that installs then
refreshes the adopter's OWN liveness beacon inside the lease** — `touch -c` on
`tdd-phase-<caller>.json`, through `_tdd_path_safe … regular`, disclosed when it cannot. Without
it a session whose own document was stale left the run it had just taken looking silent to the
next verb queued behind the lease — a second adopter, or a third session's release — until its
own next turn end or the CLI's best-effort provenance write. The outcome names are published only
after that refresh. The retired pointer is unlinked last, and only after the
shell re-checks the BASENAME the worker printed through `_autopilot_owner_pointer_basename_ok`,
which owns that shape rule in one place — the check used to re-spell both pointer names inline,
making a THIRD shell copy of each. It admits the `autopilot-active-<64 hex>.json`
shape — a value that reached a run record from anywhere must never name a file outside the state
directory — with the LEGACY `autopilot-active.json` admitted beside it by exact literal, because the
worker now emits the name of the file its resolution ACTUALLY read rather than one re-derived from
the owner digest (the legacy fallback made a derived name point at nothing while the pointer that
designated the run survived). A pointer left behind by a failed check does NOT go unnoticed:
`read-active` is owner-scoped, so the previous owner's own read finds a pointer to a run its
inventory skips and REFUSES with exit 2 rather than reporting no active run. That check therefore
skips the unlink and never the adoption, and it DISCLOSES on stderr rather than discarding the
`rm -f` status.

**Each verb has its OWN owner-activity window, and the split is deliberate.**
`hooks.autopilotOwnerActivityTtlHours` (default 1, bounds 0..8760) bounds adoption and
`hooks.autopilotReleaseOwnerActivityTtlHours` (default 6, bounds 0..8760) bounds release. Both
replace the borrowed `pendingReviewTtlHours`, which answers how long a deferred-review MARKER
stays meaningful and was never sized for this question. One shared key was the first design and
was wrong in the direction that matters: the two verbs answer the same liveness question with
OPPOSITE costs of being wrong — an adoption taken too early is recoverable, a cancel taken too
early is not — so a single number forced the constructive verb's one hour onto an irreversible
`CANCEL`. The liveness signal is the mtime of `.zensu/state/tdd-phase-<owner>.json`, which the
Stop hook writes at every turn end — a per-turn heartbeat, so it cannot distinguish a session that
is thinking from one that ended moments ago. `0` disables each verb's own check with an stderr
disclosure naming that verb's key. Adopt additionally treats a pointer that no longer designates
the run as abandonment evidence that owes nothing to a clock, which release does not — that
asymmetry is deliberate, because adoption is non-destructive. **Migration consequence:** before
these keys existed a deployment that tuned `pendingReviewTtlHours` — including to `0` — tuned the
release's liveness check as a side effect; that tuning no longer carries over, and
`docs/configuration.md` states what to set instead.

**Version: `patch` — this is the THIRD of FOUR verdicts in this section, and each covers a
different delta.** Walked against §"Runtime Lineage" entry by entry: no context-record or workflow-state
schema field (the provenance entry lands in `history`, whose `step`/`phase` are shape-validated
with no closed enum, and `workflow_state: "autopilot_adopted"` / `last_event: "autopilot-adopted"`
pass `validateWorkflowToken`); no strict key set moves (`STATE_KEYS`, `STATE_KEYS_WORKSPACE` and
`EVENT_TYPES` are untouched, so an older installation still reads the record); no hook added,
removed or renamed and no matcher changed; both new config keys are read permissively through
`_zensu_config_bounded_int`, never by a strict validator; no attestation change; and no
`permissionDecision` in either direction. Adding a skill is not an entry in that list. The
`patch` paragraph above covers the workspace-hold relaxation and the `minor` one covers the
original pointer/schema change — three verdicts, three deltas, and none of them covers another.
The P2 review round's changes stay inside THIS verdict rather than opening a fifth: the second
window key (read permissively), the read-only report (a call convention that writes nothing), the
pointer rollback, the beacon refresh (an mtime on the adopter's own existing document, never a
field), the stale-pointer retire on the owner exits and the repair's pending-stage refusal.

**FIVE further guards, recorded because a maintainer reading only the roster would miss them.**
The inner-chain refusal tests the PENDING stage (`state.stage === "BLOCKED" ? state.blocked.from
: state.stage`), not the literal one: `BLOCK` is legal from `TDD_RUNNING` and `RESUME` restores
`blocked.from`, so a literal test would adopt a run whose `TDD_CHAIN_DONE` the new owner could
never satisfy. A caller that already owns another nonterminal run is REFUSED with exit 4, built
from an OWNER-SCOPED `readRunInventory` — scoping NARROWS which foreign records can deny the
constructive verb project-wide while the destructive one keeps working, and does not close that
case: the adoption known-gap list below carries the residual — and evaluated BEFORE the
liveness block, because a caller-side precondition must not first be answered with "wait for the
owner to go stale". And the already-owner branch REPAIRS a pointer that is
MISSING **or that designates a run which has already FINISHED** instead of exiting 10 — say both,
because `skills/autopilot-adopt/SKILL.md`, the CLI stderr line and the workflow doc all carry the
widened form; exit 10 is reserved for the fully-owned case. The FOURTH guard lives INSIDE that
branch and is the one this paragraph omitted for a round: a caller that owns any OTHER nonterminal
run is REFUSED with exit 4 there too, because the repair installs a pointer at the caller's own key
and would otherwise orphan that run behind it — `read-active` then refuses for every consumer while
the CLI has just reported a successful repair, and the skill's own Step 3 verification cannot pass.
It is keyed on the owner-scoped INVENTORY rather than on the pointer, because `activePointerFor`
answers null on the legacy fallback whenever `autopilot-active.json` names a different run, which is
exactly the shape that most needs the refusal. B24 is the behavioural case. The FIFTH guard sits
in the same branch, ABOVE the pointer install: a record that names this session while its PENDING
stage is `TDD_RUNNING` and `tdd.sessionId` names ANOTHER session is REFUSED with exit 3 rather than
repaired, because ownership there is decided by an unauthenticated field, and a record planted
with this session's id would otherwise become this session's active run on its own say-so. B34 is
the behavioural case, with a control in which the chain is this session's own and the repair still
lands. The three successes are
separated by EXIT CODE and never by a token inside stdout — 0 a real takeover, 11 a pointer repair,
10 fully owned — because an exit code cannot be produced by a dropped write. The takeover
branch writes one line of `<retired-basename>\t<previous-owner>` whose first field is
EMPTY when there is nothing to retire, so the shell's TABLESS refusal catches a lost or short write
instead of letting it impersonate an outcome. The two OWNER exits print something else and never a
TAB: the owner pointers that ANOTHER session key still holds for this run, one basename per line,
which the shell retires through the same basename gate and discloses — a retry after an
interrupted takeover lands on one of those exits, and nothing else can re-derive those names once
the previous owner has left the record (B32). In report mode the worker prints `report:` prose on
every exit instead, and the shell installs and retires nothing. The SECOND field carries the same weight and is
checked the same way: `zensu-log.sh` gates the `AUTOPILOT_ADOPTED` provenance write on a non-empty
previous owner, so a line ending AT the tab would produce a real takeover recorded as coming from
nobody. The test that used to sit there compared the stripped value against the whole line, which
the tab guard had already made impossible, so it never fired. The CLI, not the worker, collapses 0/11/10 to a single exit 0,
naming each on stderr. An earlier design carried an in-band token (`pointer-repaired`) and was
replaced; `tests/structure/test-autopilot-adopt-cli.sh` now asserts that literal's ABSENCE, so
restoring it from an older reading of this paragraph turns B22 red.

**Known gaps carried by adoption specifically:** a run whose PENDING stage is `TDD_RUNNING` is
REFUSED rather than half-moved, so a chain whose owner is gone still needs its own repair; `ownerSessionId` remains an
unauthenticated field in a session-writable directory, so this is a guard against accidental
takeover and NOT an authorization boundary — say it that way, exactly as the own-run fence
paragraph above already does for itself; and — no longer a gap since the run-visibility change — `/zensu:doctor` now carries an
`autopilot:` row that names a held run and offers the guided adoption before the release.
**The owner-scoped inventory NARROWS, and does not close, the case in which a foreign record
denies adoption project-wide.** `readRunInventory` skips a foreign record only when `rawOwnerOf`
returns a string that differs, so an UNPARSEABLE record (it answers null) and an UNSAFE one
(`regularFile` fails first) still make `--autopilot-adopt` exit 2 for every run in the project
while `--autopilot-release --confirm` keeps working, because release builds no inventory — one
truncated or planted `autopilot-run-*.json` inverts the constructive-before-destructive
preference. Closing it is a change to `readRunInventory`'s contract with its own test round, not a
line in the verb.
**A fourth gap is the provenance's own lifetime, and it differs from both precedents.**
`CHAIN_RECOVERED` and `RUNTIME_ADOPTED` describe the SESSION, whose lifetime the workflow
document shares; `AUTOPILOT_ADOPTED` describes a RUN that outlives it, and the three full
document resets in `zensu-tdd-phase.sh` clear `history` wholesale — so the takeover record does
not survive the adopting session's next chain reset, and the run record carries none because a
new event type would fail every older installation closed. **The fifth — one key governing a
constructive verb and a destructive one — is RESOLVED:** each verb now reads its own window, so
the release kept its six hours while adoption answers within one; do not restore a shared key on
the strength of an older reading of this list. **A sixth is what adoption does NOT clear.** A COMPLETED chain leaves `tdd.chainId` and
`tdd.sessionId` naming the previous owner's session — only `toAwaitTdd` clears them — so an
adopted run at GATES, CONVERGE, FIX_FINDINGS, VALIDATE or COVER still carries a foreign chain
identity, and `session-start-autopilot-resume.sh` renders it verbatim into the directive the new
owner reads. The one consumer that BINDS it is already guarded on `stage !== 'TDD_RUNNING'`,
which the pending-stage refusal covers as a superset, so this is a misleading label rather than a
wrong binding. Clearing the pair would widen the verb past `ownerSessionId`, which is why it is
recorded instead.

**A seventh is that `readState` NORMALIZES.** It injects `effects.teamReview.provider` and
rebuilds `evidence.review` before validation, and the adopt write passes that normalized record
to `writeOutput` — so adopting a legacy record persists keys the on-disk record lacked. The REPAIR
no longer does: it installs only the pointer and discards the record temp, precisely so an
unchanged record is neither rewritten nor normalized. The "adds no field" claim is about the
CURRENT schema; against a legacy record it is a silent upgrade. Same forward-direction residue
`begin` and `apply` already carry.

**An eighth is a hand-copy the roster now names:** each shell entry point spells its OWN fallback
— `ttl_hours=1` in `autopilot_adopt_run`, `ttl_hours=6` in `autopilot_release_run` — as a copy of
its own getter's default operand, and neither falls back to the disabling `0`. B20 in
`test-autopilot-adopt-cli.sh` DERIVES each expected literal from that getter's operand rather than
pinning a number, so a changed default turns the check red instead of leaving a stale copy green.

**A ninth is Windows, and it is unverified rather than covered — but say that precisely, because
the first wording of this gap was wrong in two directions at once.** `test-autopilot-adopt-cli.sh`
has no `windows-ci.v1.json` entry — every shard there is already close to its `profileTimeoutMs`
and adding one has to be paid for by moving another suite off — so it never runs on the blocking
Windows PR shard. It IS in `ciStructureTests`, and `structureCommands()` in
`tests/run-windows-safety-shard.js` maps every such entry with no exclusion filter, so the weekly
Windows Safety structure shard DOES execute it: the honest status is "no green Windows run
reported yet", never "never runs on Windows". Separately, `adopt`'s two operand-table entries
(`projectRootIndex: 3`, `workspaceRootIndex: 6`) were pinned by nothing anywhere, which was NOT a
Windows gap at all — `test-msys-runtime-boundaries.sh` greps a source literal for every mode in
both tables and runs on POSIX, so the membership pin was always affordable. It now carries
`adopt: 3` and `adopt: 6`. What stays unverified is the RUNTIME behaviour on Windows, not the
table membership.

**A tenth is the liveness ladder itself**, and its hand-copy SHRANK rather than growing. Both
verbs now call ONE evaluation inside the worker, `ownerLiveness`, which returns a verdict —
`disabled`, `retired`, `absent`, `future`, `fresh` or `stale` — plus the age, and each verb MAPS
that verdict onto its own refusal, disclosure or permit. W19 in
`tests/structure/test-autopilot-state-machine.sh` is what holds it there: one helper, one
future-dated return, one window comparison, and two calls. What stays COPIED is the age
comparison, in a THIRD site outside the worker: `ownerLivenessClause` in
`hooks/lib/zensu-doctor-report.js` spells `verdict.ageMs < window.hours * 3600000` for adoption
and `verdict.ageMs < releaseWindow.hours * 3600000` for release, behind a `measured` flag carrying
`verdict.ageMs >= 0` — which is the worker's own `ageMs < 0` future return and its
`ageMs < ttlHours * 3600000` split, in the renderer's variable names. Both sides are JavaScript,
so extracting that one comparison into a module both require is reachable rather than blocked by
packaging, and it is the standing fix.

**The verbs still diverge, and the verdict MAPPING is where.** (1) Adoption passes
`requirePointer`, so a pointer that no longer designates the run answers `retired` and stands its
whole check down, while release has no pointer precondition at all. (2) The stand-down COUNT
follows from that: adoption discloses three — pointer retired, absent document, disabled window —
and release two. (3) The exit-7 wording differs, `ask it to hand the run over` on adoption against
`ask it to cancel` on release, and each future-dated form names its OWN key's `0` as the
off-switch. **A FORWARD-dated document now REFUSES on both verbs, and this paragraph asserted the
opposite for adoption until the P2 review round.** Adoption used to permit and disclose, on the
ground that its move is reversible. That ground did not hold: the takeover UNLINKS the live
owner's pointer, the victim's own adopt-back is refused for as long as the adopter's document
stays fresh, and the release refusal then RECOMMENDED adoption as its route — so two confirmations
could cancel a run whose owner was demonstrably live. What decides it on both verbs is the
ACCIDENTAL case: a jumped VM clock, a container skewed against a shared filesystem, an NFS mount
and an mtime-preserving restore all produce a future stamp while the owner is LIVE, while against
a deliberate writer refusing buys nothing, since deleting the beacon stands the same guard down.
Adoption reaches that arm only while the previous owner's pointer designates the run; a retired
pointer stands its check down one branch earlier. BACKDATING remains one-sided on both verbs, is
indistinguishable from an idle session, and writes no stderr line at all — so an absent
`owner liveness unchecked` line is not evidence that a clock was consulted and passed. Both age on
a filesystem MTIME, while §"Foreign-Chain Row" records the opposite decision for both of its
sibling age judgements (`updated_at` from the validated document, with NO mtime fallback, because
`.zensu/state/` is session-writable and a bare `touch -t` moves a document out of the window).
That divergence is real and unresolved; reading `updated_at` inside `ownerLiveness` with the mtime
as an explicit fallback is the standing fix. **An eleventh is stated
because the roster below would otherwise imply it is closed:** `_autopilot_adopt_critical` is now a SECOND writer of the
owner-keyed pointer, so `_autopilot_begin_critical` is no longer "the only site that writes it";
both sites carry the `_tdd_path_safe … regular-or-absent` pre-check, and `_autopilot_storage_safe`
still covers only the LEGACY pointer by name.

**Known gaps, accepted:**

- A refusal names the holding run but the release is a separate, user-confirmed step. It has
  to be: the run belongs to a session that may still be alive.
- **`OWNER_SESSION_MISMATCH` in `plan-approved-delegate.sh` is now unreachable, and the plan
  it used to refuse falls through to the standalone policy instead.** A foreign session that
  approves a plan carrying another run's `<!-- zensu-autopilot:<run> -->` marker no longer
  reaches the owner comparison, because the run is invisible to its owner-scoped read; it takes
  the standalone branch, and is asked the four-route delivery question, which now carries
  `/zensu:autopilot` and `/zensu:pilot` beside it (see §"Plan-Approval Delivery Route"), only
  while its route field reads `ask`. A `tdd` recorded for that session, a `direct` the user
  recorded explicitly with `/zensu:delivery-route --direct`, or a default configured in
  `hooks.defaultDeliveryRoute` (§"Session Delivery Route") dispatches without asking: `tdd`
  then meets the standalone `--tdd-begin` workspace fence, and `direct` meets no fence, so direct
  edits can land in a working tree the foreign run holds. The run's own state is not mutated —
  the foreign run is not touched and no binding is created — but on the `direct` path the
  workspace guarantee is lost: before the session-sticky route, the four-route question showed a
  human the re-route. A direct answer to that question is never recorded, so this path needs an
  explicit `--direct` or a configured default. The scoped fix, rendering the field as `ask` when
  the plan's marker names a run this session does not own, is recorded and not implemented.
  Restoring it needs the marker before the read, and the marker is only resolved inside the
  payload evaluator (see "Plan-Gate Payload Sources"), which reads fields by name and must
  not be duplicated in shell. The exit-6 arm and its `BLOCK_CODE` are deliberately left in
  place rather than deleted, so a future evaluator that can answer "this marker names a run
  you do not own" has its receipt waiting. What the foreign caller now gets is NOTHING: the
  branch is skipped before any payload source is resolved, so it cannot be used as an
  existence oracle either — which is what F20/F20a, F32/F32a and F45c in
  `tests/structure/test-plan-payload-fallback.sh` pin, alongside P6 in
  `tests/structure/test-autopilot-plan-delegate.sh`. Those five cases were written against
  the refusal receipt and now assert the silence instead; F45c in particular no longer pins
  an ORDERING between the ownership and origin refusals, because neither is reachable.
- **Phase 0.D's order is also what keeps Autopilot's OWN approval on the durable branch.**
  `skills/autopilot/SKILL.md` Phase 0.D creates the run with `--autopilot-begin` immediately
  before `ExitPlanMode`. Reversed, the approval finds no run at `PLANNING` and falls through to
  the standalone directive, which asks the four-route question while the route field reads `ask`
  and otherwise sends the Autopilot spec to `/zensu:tdd` or implements it directly without
  asking (§"Session Delivery Route"). `D16` in `tests/structure/test-autopilot-durable-skill.sh`
  pins the Phase 0.D sentence and that consequence as text; nothing observes the order a model
  actually takes.
- **RESOLVED — `/zensu:doctor` now carries an `autopilot:` row, and the bound is what to keep in
  view.** `autopilotRows` in `hooks/lib/zensu-doctor-report.js` renders one row per nonterminal
  run found in the record-anchored state directory — WARN, except an own run whose active pointer
  still designates it AND whose stage is not `BLOCKED`, which renders OK because it is an ordinary
  run in progress rather than a finding, naming the run id, the stage, own-vs-foreign,
  the held tree, the run document's path and the owner's silence, plus a second row counting run
  documents it could not read and a THIRD counting those it does not accept whose recorded stage
  is terminal. The second row's count deliberately EXCLUDES the third's, so the two are disjoint
  and neither is the total. Every OTHER surface stays as enumerated: the `--autopilot-begin`
  refusal, the standalone-TDD begin refusal, the deferred-review Stop refusal (which names the
  holding run whenever it can be read — including when it belongs to this session, where the guided
  `/zensu:autopilot-adopt` is offered and only the release COMMAND is withheld — and names no run
  at all when the read failed, where neither is offered because ownership is unknown), the stderr
  line the fence prints when it stands down, `/zensu:autopilot-adopt` and `/zensu:autopilot-release`. Keep this in step with the
  rc=4 account above, which is where those refusals are specified. **THREE bounds ship with the
  row and none of them is cosmetic.** It is SILENT when the project holds no run document at all,
  matching the `pending-review.json` row, so absence of the row is not evidence the tree is free —
  it is evidence no run document exists in the directory the report scanned. Its `ownKey` comes
  from `currentSessionKey()`, which is empty for every binding verdict but `bound`, and the row
  then reports the owner as not established and names NO release command — the same direction the
  refusal renderer takes when it cannot read a holder. And its stage vocabulary
  (`AUTOPILOT_STAGES` / `AUTOPILOT_TERMINAL`) is a HAND COPY of `zensu-autopilot-state.sh`'s
  `STAGES` / `TERMINAL`, which no `require` can reach because the owner is a bash file; P1na in
  `tests/structure/test-doctor.sh` is what holds the copy against its owner, and without it a
  stage added upstream would silently render every run carrying it as unreadable.

- The `SESSION_CONTEXT_UNAVAILABLE` arm in `plan-approved-delegate.sh` is defense in depth, not
  the live path: `zensu_bind_hook_session` refuses an unresolvable session earlier, so the receipt
  a caller actually sees in that state is `RUNTIME_UNAVAILABLE`. Measured by P8a-P8c in
  `tests/structure/test-autopilot-plan-delegate.sh`, which therefore pin the fail-closed DIRECTION
  (a `PLAN_GATE_BLOCKED` receipt rather than the standalone policy) and not the specific code.
- `_autopilot_storage_safe` validates the legacy pointer by name; the owner-keyed one is
  checked at each of the TWO sites that write it, `_autopilot_begin_critical` and
  `_autopilot_adopt_critical`. Reads are protected by `regularFile`, which rejects symlinks
  and hard links.

**Known gaps of the run-visibility delta, accepted and named:**

- **The renderer is a READ-side mirror of the run schema, not a consumer of it.** A whole family is
  hand-copied from `zensu-autopilot-state.sh` — the stage set, the terminal set, the run-record key
  set, the id class, the owner-silence policy, the run-filename envelope, the field and record size
  bounds, `pointerValid`'s exact pointer shape and `_autopilot_owner_key`'s sha256 rule. An
  enumeration here went stale within one review round, so this is a GREP and not a list: before
  changing any of them run
  `grep -nE 'AUTOPILOT_|autopilot[A-Z]|createHash|3600000' hooks/lib/zensu-doctor-report.js`
  — the `3600000` alternation is not decoration: the aged split's age comparison is a third
  spelling of the verbs' own arithmetic and matches none of the other three needles, so the
  sweep this paragraph prescribes could not find the copy §"A tenth is the liveness ladder
  itself" now names —
  **and `grep -nE 'CONTROL_BYTE|renderable|bound\(' hooks/lib/zensu-autopilot-state.sh`**. The
  second root is not optional and the omission was a real defect: the exit-6 release refusal
  carries its OWN inline spelling of the renderer's render-safety class plus a second copy of
  `AUTOPILOT_RENDER_MAX`'s 200, in shell, and the one-file grep this paragraph used to prescribe
  could not see it. The coupling runs in the DANGEROUS direction — the doctor row now routes a
  model to that command, so a widening on the JS side that does not reach the shell literal
  launders the withheld characters through the one command the row recommends.
  and check each hit against its owner. The needle is deliberately wider than a constant-name
  prefix, and the `autopilot[A-Z]` alternation is what covers the copies carrying no
  `AUTOPILOT_` token: the beacon filename and its `isFile`/`nlink` rule inside
  `autopilotOwnerSilence`, the exact pointer shape inside `autopilotPointerDesignates`, the
  canonicalization rule inside `autopilotCanonical`, and the whole predicate family —
  `autopilotNatural`, `autopilotSha256`, `autopilotNullableId`, `autopilotOwnerNonEmpty` — each
  character-equivalent to an owner predicate (`natural`, `sha256`, `nullableIdentifier`,
  `nonEmpty(…, 4096)`). The owner-key rule needs the bare `createHash` arm. An earlier spelling
  named THREE copies and prescribed a needle blind to the predicate family, so a maintainer
  changing the owner's `natural` got no hit naming it. Several
  are pinned — P1na, P1nm, P1nm1, P1nn and, since the `ownerWouldAccept` inputs got theirs,
  the `P1nz` family in `tests/structure/test-doctor.sh`, named as a FAMILY because every attempt
  to enumerate it here has gone stale within a round — and the pins compare
  spellings, not behaviour, so a semantic change that keeps the spelling passes. P1nz5 compares
  THREE sources rather than two: `ap_run_valid` inlines the stage-to-action table a third time,
  and a fixture that agrees with the renderer by construction cannot fail on the drift it exists
  for. The durable fix
  is to extract the run-record vocabulary into a host-neutral module and require it from BOTH
  sides; inline `node` programs in this tree already load modules by an env-supplied path, so
  "no `require` can reach a bash file" is a property of the packaging rather than a bound. It was
  not taken here because rewiring the worker's heredoc program is a change to the most heavily
  pinned code in that module and belongs in its own review.
- **`ownerWouldAccept` applies the owner's `workspaceRoot` rule, and it is NOT the renderer's own
  render-safety rule.** It mirrors `nonEmpty(value, 4096)` — string, non-empty, at most 4096, no
  C0 byte. The render check beside it is deliberately WIDER (it also refuses DEL, C1, U+2028/9, a
  relative spelling and a backtick, because that value is echoed into a row the model relays), so
  keying the glyph on it would drop out of green records the owner reads perfectly well. The field
  was omitted from the strict check for a release, and the cost was the exact inversion the check
  exists to prevent: OK plus "all checks green" over a project where `readRunInventory` fails
  every Autopilot verb closed. P1nz7 pins both directions.
- **A readably TERMINAL document never reaches the could-not-be-read row.** That row asserts the
  record "still holds its working tree", which is false for a DONE or CANCELLED one, and the
  trigger is not exotic: `AUTOPILOT_STATE_KEYS` is an EXACT key match, so the first release that
  adds a field to the owner would turn every accumulated run document in every project — the
  finished ones included — into that row, with a permanent false claim and a permanently
  suppressed green summary. `autopilotRun` reads `stage` loosely BEFORE the key-set match and
  answers a distinct sentinel, `AUTOPILOT_TERMINAL_UNSHAPED`, which the single call site consumes
  immediately. **The escape covers EVERY shape gate, not only the key-set one** — schemaVersion,
  id class, owner class and a foreign `projectRoot` included — because the row's false sentence is
  false for a terminal record whatever made it unreadable. This paragraph said the opposite for a
  release while `P1nz10` already pinned the wider behaviour, so the governing document and the
  suite asserted opposite contracts; that is the drift to check for first if the two disagree again.
  **The escape NARROWS the finding and must never delete it.** `readRunInventory` never consults
  terminality: it validates every `autopilot-run-*.json` in the directory and fails 2 on the first
  it refuses, and `begin` and `read-workspace` pass no owner and stay strict — so a DONE document
  with a foreign `projectRoot` fails every Autopilot verb closed for the WHOLE project, and this
  report is the only thing that names that state. The escaped set therefore gets a SECOND row of
  its own, carrying the claim that is true of it (the record holds no working tree, but
  `--autopilot-begin` and the workspace-occupancy check validate every document in the directory
  WITHOUT owner scoping, so it can still fail those closed) and quoting NO release command, since
  `--autopilot-release` refuses a terminal run. **Scope that clause to the unscoped verbs and no
  further**: `read-active` DOES pass an owner and `readRunInventory` skips a record it can prove
  belongs to another session before validating it, so "every Autopilot verb" is false, and it is
  false in a row the doctor skill tells the model to relay. Both rows withhold names
  through ONE implementation, `autopilotSafeNames`. P1nz8 and P1nz10 pin the escape at the key-set
  gate and at a value gate, ROW-SCOPED in both directions — absent from the false-claim row AND
  present in the true-claim one — and P1nz13 pins the second row plus its control.
- **The Windows wall clock for both grown suites is UNMEASURED.** `test-autopilot-state-machine.sh`
  runs on a blocking Windows PR shard and this change adds two git worktrees plus the `W16a`/`W16b`,
  `W31a`-`W31k` and `W32`/`W32a`-`W32d`/`W32z` families, four of which bind a Session Control record
  and invoke `zensu-log.sh`. `test-doctor.sh` is not on that shard at all but does run in the weekly
  Windows Safety structure inventory, and it gained the whole `P1na`-`P1nz` family together with
  the `P1nm1` check and the whole `P1nz` family added in the rounds that followed. **Named as ID
  FAMILIES rather than as numerals or endpoints, deliberately** — a RANGE was tried and went
  stale twice: it read `P1na`-`P1ny` while `P1nz` already existed, and then `P1nz1`-`P1nz13`
  while the tree carried `P1nz20`. An endpoint is a hand-maintained numeral wearing a range's
  clothes, and this bullet is where that keeps being rediscovered — this file's own rule about hand-maintained
  censuses applies to its own gap list, and it did not hold here: both numerals were written once
  and were wrong within the same change, reading "ten" and "eighteen" against a tree that carried 19
  and 43. A range is cheaper to keep true than a numeral, but it is NOT self-maintaining: it also
  goes stale when a check is APPENDED past its endpoint, which is exactly what happened next — the
  bullet read `P1na`-`P1ny` while `P1nz` already existed, with no rename involved. Re-grep the
  family before trusting either form.
  This repository's rule is that a ceiling comes from a green shard measurement
  and never from an estimate, so no ceiling was raised: take both figures from the next green
  Windows run and record them before adding further fixtures to either file.
- **A foreign nonterminal run permanently withholds the green summary.** The row is `WARN` and
  `line()` counts WARN toward `warnCount`, which `main()` gates "all checks green" on — so while
  any other session in this project holds a nonterminal run, `/zensu:doctor` cannot print a clean
  summary. A hold is a steady STATE, not an event, so this does not self-clear. Accepted on the
  same ground the sibling rows accept it: a held tree is real state the user should clear, and a
  row that can never affect the summary is a row people stop reading. Named here because
  §"Foreign-Chain Row" and §"Implementing-Phase Turn Counter" both record the identical cost for
  their own rows while this section said nothing, leaving the next reader to rediscover it as a
  defect. The green form of the OWN-run row exists precisely so a session's own live run does not
  pay this price.
- **The doctor row reads the owner-keyed pointer to tell an ordinary in-progress own run from the
  torn-`begin` shape.** That is a THIRD file the row opens, and its absence is treated as "no
  pointer designates this run" while an unreadable one is treated as "not established" — the row
  then keeps its WARN. The pointer digest is computed here rather than obtained from the owner, so
  `_autopilot_owner_key`'s rule is a sixth hand-copy; it is exercised behaviourally by P1ne2 and
  pinned by nothing. **It has a SECOND consumer now, with different consequences:**
  `ownerLivenessClause` calls the same predicate for a FOREIGN owner, where its three-valued
  answer selects which verbs the owner-silence clause says refuse — both, release only, or a
  hedge — so a change to its `null` semantics moves that sentence as well as the own-run glyph.
  P1nk3, P1nk3b and P1nk9 exercise the foreign digest path.

- **RESOLVED — `ownerLivenessClause`'s ARM ORDER is a contract, not layout, and it shipped wrong once.**
  The WINDOW gate runs FIRST, above every beacon-KIND arm. Since the two ladders collapsed into
  `ownerLiveness`, that gate is spelled ONCE, as the helper's first statement —
  `if (!(Number.isFinite(ttlHours) && ttlHours > 0)) return { verdict: "disabled" };`, which is
  what `P1nn` greps; quote that spelling or paraphrase it, never a bare `ttlHours > 0`, which
  occurs nowhere and sends a grep to nothing. Both verbs reach the beacon only through that
  helper — adoption additionally under its own `ownerPointerDesignatesRun` branch — and the
  POINTER is resolved above the gate in both the verb and the renderer, so at a configured `0` the
  beacon is never opened at all:
  there is no exit 2 for a file `regularFile` would refuse and no exit 7 for a future stamp.
  Judging the kind first asserted refusals no verb takes AND suppressed the `0` disclosure, on
  the row that offers an irreversible cancel, in a state needing no adversary (the documented
  off-switch plus a container clock skewed against a shared filesystem). `P1nka` and `P1nkb`
  drive `0` against an unreadable and a future beacon; `P1nk4` cannot see the order, because it
  drives `0` against an AGED beacon only.

- **RESOLVED — the exit-2 arm is stated PER VERB, and the ABSENT arm is routed through the same clause.**
  Under the window gate both verbs share, release reaches the beacon with nothing further in its
  way; adoption nests the same call one branch deeper, inside `if (ownerPointerDesignatesRun)`,
  so with the pointer retired it never opens the file and the "both verbs abort" wording is false
  for that half. Never write "release opens the beacon unconditionally" — that wording stood here
  for a round, directly below the arm-order bullet stating that at `0` neither verb opens it, and
  it has a test-comment copy beside `P1nk1` that went stale with it. `P1nk1` pins the release-only
  form with no pointer and `P1nk1c` the both-verbs form with one, together with the pointer bound
  that arm now carries. The absent arm was INLINED in `autopilotRows` and is now a branch of
  `ownerLivenessClause`, so a qualifier added to the other arms reaches it instead of leaving it
  one arm behind forever.

- **RESOLVED — `null` is not `false`, and only `null` hedges the adoption half.** `autopilotPointerDesignates`
  answers three values. `false` is a read that SUCCEEDED — the pointer is absent or names another
  run — and adoption's own verdict follows from it; `null` is a pointer that could not be read, and
  the adopt worker resolves that pointer ABOVE its window gate, so it can abort on exactly the
  states this reader maps to `null`. The absent and future-dated arms asserted an adoption verdict
  (`both verbs stand down`, `adoption permits`) without consulting the pointer at all; both now
  hedge on `null`, while `false` and `true` keep their wording. `P1nkh` and `P1nki` are the bites.

- **RESOLVED — this reader parses exactly what the owner parses, and a BOM was the counter-example.**
  `readAutopilotJson` stripped a leading U+FEFF before `JSON.parse`; the owner's `readJson` does
  not, so such a document reaches `fail(2)` there and `readRunInventory` fails the FIRST one for
  the whole project. Normalizing it here made the report greener than the tree in both directions:
  a BOM-prefixed RUN RECORD satisfied every field rule, took the OK glyph and let the summary print
  "all checks green" over a project on which no Autopilot verb runs, and a BOM-prefixed POINTER
  answered a definite `designates` verdict for a file both verbs abort on — which is the premise
  the per-verb clause rests on. The strip is gone. The rule generalizes: a mirror may be STRICTER
  than its owner and must never be laxer, because the laxer direction deletes findings rather than
  inventing them. **PARSER TOLERANCE is its own coupling class, and the roster's grep cannot see
  it**: the only carrier of this one is the ABSENCE of a line, and no constant-name scan finds a
  removed strip. `P1nks` is what holds it — a BOM-prefixed run document must land in the
  could-not-be-read row. Note also that this is deliberately NOT a file-wide rule: the settings and
  config readers in the same file tolerate a BOM on purpose, and their own fixtures pin that.

- **RESOLVED — the per-verb availability is resolved ONCE, in `autopilotRows`, and both halves of the row
  consume it.** The clause derived it privately and the foreign REMEDY did not derive it at all, so
  the row told a reader to offer `/zensu:autopilot-adopt` one sentence before the clause said
  adoption refuses that run with exit 3. Threading the inner-chain fact alone fixed one arm and
  left the class: the clause ALSO says the release aborts with exit 2 on an unsafe beacon and
  refuses with exit 7 on a future-dated one, and the remedy went on offering exactly that release.
  `ownerLivenessClause` therefore returns a RECORD — text plus a per-verb availability pair, its
  two CAUSE fields and the window it quoted — and the remedy renders from it, so the row can never name a verb its own clause
  has just said cannot act. The record carries the CAUSE and not only the fact — `releaseBlockedBy`
  and `adoptBlockedBy` — because the causes take different remedies: a first version knew only
  "both blocked" and told a reader whose adoption was refused by its inner CHAIN to repair the
  beacon, which restores the release alone, and told a reader with a future-dated stamp to restore
  a file that already was a plain regular file. Two rules travel with the shape. **The AGED arm
  SPLITS on the measured age, and an earlier revision of this paragraph forbade exactly that** — it
  read "fixes only `releaseBlockedBy`, and fixes it to null … Do not 'complete' the record there by
  comparing the age", written when the arm's wording was uniformly CONDITIONAL. It is not:
  `verdict.ageMs` is the same number the row already renders, so INSIDE the window the refusal is a
  present fact rather than a hypothesis, and the arm sets `releaseBlockedBy = 'aged'` plus, when
  the pointer designates and no chain blocks, `adoptBlockedBy = 'aged'`. OUTSIDE the window — or
  with an age that cannot be measured — the wording stays conditional and the arm blocks nothing,
  which is the case the retired rule was really about. The comparison must stay byte-for-byte the
  owner's (`ageMs >= 0 && ageMs < ttlHours * 3600000`); it is a THIRD spelling of it, and the
  hand-copy roster below now says so. An earlier wording claiming the arm "sets neither flag" was
  false for a chain-blocked run and contradicted `P1nkc`, which is the case that proves it;
  `P1nkt` is the in-window case and `P1nk3` its out-of-window twin, and the two share every clause
  literal, so only the slash commands tell them apart — which is why both carry offer positives.
  And a THIRD state is not a flag but a caveat: adoption also refuses with exit 4 while the caller
  owns another nonterminal run, which this report knows for the SCANNED set only, so it is
  appended as a sentence and never used to withhold — the scan is bounded, so withholding on it
  would be wrong in the other direction. **Making it a CAUSE was tried in one round and reverted,
  and the ground is a safety property rather than a preference**: the fact is read from a bounded
  scan of records any session in this project can write, so as a refusal one planted document
  withholds the constructive verb and leaves the irreversible cancel as the row's ONLY offer.
  Stating it as a caveat is wrong by a sentence; withholding is wrong by a cancel. The same rule
  governs `adoptUnknown`, and `skills/doctor/SKILL.md` now states it for the model too: an arm
  saying a verb REFUSES or ABORTS withholds that verb, while an arm saying its side could not be
  ESTABLISHED does not. That caveat names an exit CODE, so it is conjoined on
  `ownerWouldAccept`: a record the owner refuses makes adoption exit 2 inside `readState`, above
  the exit-4 test, and counting it would state a code the report did not establish. `P1nkc`/`P1nkd` assert the adopt command is ABSENT for a
  live inner chain; `P1nkm`/`P1nkn`/`P1nko` assert the release is absent where the clause says it
  aborts or refuses. Asserting only the clause is what let the two halves disagree.

- **Inside `zensu-autopilot-state.sh` the pending-stage idiom is THREE distinct spellings,
  not one copy repeated, and that distinction is load-bearing — do not "align" them.**
  State the FILE with the count: `zensu-doctor-report.js` carries a fourth spelling of its
  own, which the bullet below names, so an unscoped "three" reads as a tree-wide census and
  sends a maintainer looking for one copy too few. A review round counted five sites and
  proposed one shared helper; the judge pass established that they do not share a predicate.
  `stateValid`, the already-owner repair and the takeover refusal read `state.blocked.from`
  BARE. The `begin` twin guards on `workspaceHolder.blocked` being truthy and String-coerces
  the result, because it renders a holder built from a `read-workspace` result rather than a
  validated record. The workspace renderer additionally requires `RENDERABLE_STAGES.has()`,
  because a stage it cannot render must fall back to the literal one. A helper collapsing them
  would have to take that difference as a parameter, so the extraction is not free, and no
  divergence produces a wrong verdict today. Flattening the third spelling is the one that
  costs something real: it decides which arm withholds the constructive verb.

- **A further hand-copy joined the family: the PENDING-stage idiom.** `autopilotRun` returns
  `pendingStage` (`stage === 'BLOCKED' ? blocked.from : stage`, read defensively because it is
  computed before `ownerWouldAccept` has vetted the nested key sets), and the clause withholds
  the adoption half for `TDD_RUNNING` — `_autopilot_adopt_critical` refuses that with `fail(3)`
  ABOVE its whole liveness block, which is exactly what `_autopilot_release_critical`'s own
  exit-7 message already branches on when it withholds the adopt route. A row that ROUTES a user
  to `/zensu:autopilot-adopt` must not contradict the verb that declines to. `P1nkc` drives the
  literal stage and `P1nkd` the BLOCKED-from-`TDD_RUNNING` spelling.

- **RESOLVED — three forgeable inputs now DISCLOSE, symmetrically.** The rendered age is an ordinary
  filesystem mtime in `.zensu/state/`, which this file records as session-writable, so one
  `touch -t` makes a live owner read as hours-silent; the pointer whose presence the
  `designates === true` arm keys adoption's refusal on is a file any co-tenant can unlink between
  the report and the user's action; and the PENDING STAGE that withholds adoption entirely is read
  from the run document in the same directory — the one input that leaves only the irreversible
  verb on offer, so it is the last one that may read as measured fact. All three now carry a
  one-clause bound, and a FOURTH clause bounds the word "repaired" on both exit-2 arms: that
  beacon is the owning session's workflow document, deleting it is not a repair, and it produces
  the no-document state this same clause calls unbounded. The bound travels with the
  arm that PROMISES a refusal and not only with the arm that withholds one — attaching it to the
  weaker claim alone is what made the stronger one read as a guarantee. Mirroring the verbs'
  mtime read stays correct (changing only this side would desynchronize two readers of one file);
  what was missing was saying what the input is worth. `P1nk` pins the age bound, `P1nk3` the
  pointer bound, `P1nkc`/`P1nkd` the pending-stage one and `P1nkq` the repair one — name what each
  pins rather than counting, because the count moved twice while the sentence said "both".

- **NAMED FOLLOW-UP, not done here: `zensu-doctor.sh` carries the record-root re-resolve THREE
  TIMES.** The pending-review, owner-activity and release-owner-activity blocks differ only in
  four identifiers — the pinned flag,
  the getter, the rebound temp and the exported window — and the precedent for
  collapsing them is `zdoc_version_pair()` in the same file. **An earlier revision of this bullet
  declined it on a false premise**, and the correction matters because the premise was the whole
  argument: it said the parameterization needs `eval`-based indirect assignment on a bash-3.2
  target. `zdoc_version_pair()` is the counterexample sitting beside it — it takes the getter NAME
  as its first argument, calls it directly, and returns through stdout, with no `eval` anywhere,
  so a helper printing the resolved window for the caller to assign is available on bash 3.2 as it
  stands. What is left is cost, not risk: the collapse re-authors `C21b`, `C21c`, `C21d` and
  `C21e` together, on the path that EXPORTS a window the `autopilot:` row quotes beside an
  irreversible cancel, and that is still a change to take in its own review rather than inside a
  fix round whose findings are about the row's wording. **TRIGGER:** the next round that
  has to re-author those four anyway, or a fourth window needing the same re-resolution.

  **The TRIGGER FIRED in the per-verb window round and was deliberately NOT taken, which is why
  the paragraph above is amended rather than deleted.** That round supplied the third window, so
  both clauses of the old trigger were met at once. It was declined on the cost stated above and
  on this file's own rule that a change to the cancel-adjacent export path belongs in its own
  review — not inside a fix round whose findings were about wording. Recording the decline is the
  point: a fired trigger declined in SILENCE is indistinguishable from one nobody noticed, which
  is the drift this bullet exists to prevent, and the round that fired it had to re-author its
  census anyway. The trigger is restated above against FOUR, so it cannot be met again by the
  same evidence.

  Until then all three blocks are pinned: `C21c` derives the resolved-window population and now
  admits a
  GROUPED `export` (a mutant grouping the owner-activity export silently dropped it from the
  population, three windows to two, with the check green) under a floor of five, and `C21d`
  bounds its `sed` slice at 20 lines (re-indenting the block's closing `fi` grew the slice from
  16 lines to 166, where every conjunct matched unrelated lines below).

**Version for the run-visibility delta: `patch`.** This section now carries FOUR
`**Version.**` statements and a releaser matching on the wrong one gets the wrong answer, so
this one names its own scope: the `/zensu:doctor` `autopilot:` row, the public
`autopilot_workspace_hold_report` verb with the `--autopilot-status` disclosure that consumes it,
and the exit-6 wording. Walked against §"Runtime Lineage" entry by entry: no context-record or
workflow-state schema field (the row READS `autopilot-run-*.json` and the owner-keyed pointer and
writes nothing); no strict key set — `AUTOPILOT_STATE_KEYS` in the renderer is a READ-side mirror
of `STATE_KEYS`, pinned by P1nm, and rejecting a record there costs one row, never a document;
no hook added, removed or renamed and no matcher changed; no new config key (the row reuses
`zensu_autopilot_owner_activity_ttl_hours` and, since the windows split, its release twin, which
the wrapper resolves and exports as `ZDOC_OWNER_ACTIVITY_TTL_HOURS` and
`ZDOC_RELEASE_OWNER_ACTIVITY_TTL_HOURS` — it quoted `zensu_pending_review_ttl_hours` through
`ZDOC_TTL_HOURS` for one release, which promised a window neither run verb reads); no attestation
change; and no `permissionDecision` in either direction, the doctor being advisory. The new
shell verb is a call convention inside one installation — an older runtime does not have it
and nothing writes it anywhere — and it ships in the same tree as its only caller, so no
cross-version mixing arises.

- **`--autopilot-status` discloses the hold on stderr**, keeping its exit 1 and its stdout
  unchanged because SEVEN skills run this verb and parse that stdout as JSON —
  `autopilot`, `autopilot-release`, `tdd`, `pr-team-review`, `pr-fix-findings`, `self-review` and
  `reset-review-limit` — several of them failing closed on a mismatch. An earlier wording named
  `session-start-autopilot-resume.sh` here, which calls the LIBRARY's `autopilot_read_active`
  directly and never runs this CLI verb, so the rule was right and its stated cause was not. It renders through the PUBLIC
  `autopilot_workspace_hold_report`, which takes ONE leased read and prints
  `<own|foreign|unknown><TAB><sentence>` — the sentence from `_autopilot_workspace_refusal` with
  audience `model` and the ownership from the SAME record, so a lead-in can never contradict the
  sentence it introduces. Its STATUS vocabulary is the load-bearing half: 0 rendered, 1 the tree
  is PROVEN free, 5 the question could not be answered, 3 a REFUSED CALL — a bad arity, an
  unrecognized audience, or a caller-session argument that is not a session id — and TWO paths
  reach 1 rather than one: the worker's own verdict, and an absent state directory, which
  short-circuits ahead of the lease because no run document can exist without one. Every OTHER
  storage, lease or worker failure maps to 5, so an all-clear can never be printed for a check
  that did not run. That is why the probe it runs under the lease always returns 0, and why a failed render is
  remapped to 5 rather than inheriting the renderer's own 1
  — so the own-vs-foreign choice stays in the one renderer that owns it, no file
  outside the module calls an `_autopilot_*` helper, and no `--confirm` invocation reaches a
  model-read channel. That verb is the FIFTH caller of the renderer and the first that is not a
  fence; a sixth needs its audience chosen deliberately, since the argument is positionally
  required and a two-argument call refuses rather than defaulting.

**The forgeability clause is a FOUR-carrier hand copy, and it is named here because the
roster below carries its owner and not its copies.** `zensu-autopilot-state.sh` owns the
sentence as `forgeableSource` and states it three times of its own: the workspace
renderer's `forgeableStage`, the own-run withhold arm — which widens it to the chain
session as well as the stage, because that arm asserts both — and the `begin` twin, which
spells it inline because it lives in a different program. `hooks/lib/zensu-doctor-report.js`
carries the fourth as `AUTOPILOT_FORGEABLE_SOURCE`, consumed by `chainBound` and by the
adopt-remedy sentence. TWO pins hold it now and neither existed before: `S7m` compares the
twin against the renderer byte for byte, and `P1nky` in `tests/structure/test-doctor.sh`
compares the doctor's constant with the library's own and requires the live-inner-chain row
to emit it. Extracting the sentence into a host-neutral module both sides require is the
standing fix — the packaging bound is the same one the run-record vocabulary carries, and
the same remedy applies. TRIGGER: a fifth carrier, or the next change that has to reword
every carrier anyway.

Moving together with the scope: `autopilot_adopt_run` / `_autopilot_adopt_critical` and the
`adopt` worker mode with its `path_indexes=(0 1 3 5 8)` entry PLUS its `projectRootIndex: 3` and
`workspaceRootIndex: 6` entries — all THREE operand tables, as `release` has — and its
owner-pointer pre-check, the TWO module-scope
names the critical section publishes and the `--autopilot-adopt` arm of `zensu-log.sh` reads by
name — `ZENSU_AUTOPILOT_ADOPTED_PREVIOUS_OWNER` and `ZENSU_AUTOPILOT_ADOPT_OUTCOME`, the second
of which the CLI compares against the literals `adopted`, `repaired` and `already-owned` to
select its stderr line AND to gate the provenance write, so a rename there silently returns the
verb to reporting nothing and to dropping the history entry, `tdd_write_autopilot_adopted` plus the `AUTOPILOT_ADOPTED`
literal AND the reserved reason PREFIX `autopilot-adopted: `, which is a THREE-site literal —
**and this clause said FOUR while naming two sites that no longer carry it, which is worse than
an undercount: a maintainer working the roster opens `_tdd_write_phase_critical` and
`tdd_write_phase`, finds no literal, marks the roster satisfied, and never reaches the one
carrier that decides.** Since the extraction those two call `_tdd_reserved_provenance` and hold
no literal at all. The three that do are the producer in `zensu-tdd-phase.sh`, the guard in
`zensu-log.sh --phase`, and `_tdd_reserved_provenance` itself — which is the SINGLE guard-side
implementation both write functions delegate to, and which must be added to any rename together
with its `export -f` membership, a coupled site of its own: it is exported on the same line as
`_tdd_write_phase_critical`, so the two travel together and the guard can never be missing while
its subject is reachable from a child shell. That export pairing is what makes the fail-closed
`command -v` arm a belt rather than the only strap. §"Chain Shape & Rearm Receipt" records the
identical hazard for `RECOVERY_HISTORY_REASON_PREFIX`: rename the phase without the prefix and the
guards reserve a dead name while `--phase` becomes a channel to mint forged takeover provenance
again. All FOUR comparisons are matched case-INSENSITIVELY — six was the PRE-EXTRACTION count and
went stale when `_tdd_reserved_provenance` collapsed the two write functions' arms into one pair;
the surviving four are that helper's phase and reason arms plus `zensu-log.sh --phase`'s own two —
because the phase is lower-cased
downstream into `workflow_state` and `last_event` while `history` keeps it verbatim, so an exact
test admitted `AUTOPILOT_ADOPTEd`; the bracket-class spelling is deliberate (`${var^^}` needs bash
4 and this ships to macOS bash 3.2, and `tr` would put a subprocess on a guard), `zensu_autopilot_owner_activity_ttl_hours` in
`zensu-config.sh` (whose positional-literal comments no longer COUNT the getters — they said FOUR and went stale at
five — because `getter_operand`/C58 in `test-impl-stop-counter.sh` derives its population by grep
and compares each call line and its operands, never a comment's numeral), its release twin
`zensu_autopilot_release_owner_activity_ttl_hours` beside it, `skills/autopilot-adopt/SKILL.md` and
its `.claude-plugin/plugin.json` entry, the `autopilotOwnerActivityTtlHours` and
`autopilotReleaseOwnerActivityTtlHours` entries in `config.example.json` and their substantial
rows in `docs/configuration.md` — plus the DOCTOR
consumers, which a roster naming only the verbs would send a maintainer past: the wrapper's
`ZDOC_OWNER_ACTIVITY_TTL_HOURS` resolve, export and record-root re-resolution in
`hooks/lib/zensu-doctor.sh` (pinned by `C21b`, `C21c` and `C21d`) together with its release twin
`ZDOC_RELEASE_OWNER_ACTIVITY_TTL_HOURS` and that twin's own caller-pin flag (pinned by `C21e`),
and in `hooks/lib/zensu-doctor-report.js` the `OWNER_ACTIVITY_TTL_FALLBACK` /
`OWNER_ACTIVITY_TTL_MAX` mirror pair beside its `RELEASE_OWNER_ACTIVITY_TTL_FALLBACK` /
`RELEASE_OWNER_ACTIVITY_TTL_MAX` twin (pinned by `C57b` and `C57e`), **`ownerActivityWindow`** and
**`releaseOwnerActivityWindow`** — the first of which is the ONLY reader of
`ZDOC_OWNER_ACTIVITY_TTL_HOURS` and the sole producer of the adoption half's `supplied`, the flag deciding
whether the row discloses that a default was assumed; a rename driven off this roster that misses
it leaves `supplied` false forever and the row then tells every reader no window was configured in
a project that configured one, beside an irreversible cancel, with nothing failing — and
`ownerLivenessClause`, which words the
`autopilot:` row's owner-silence clause PER VERB because each verb judges its OWN window and
adoption additionally requires the owner pointer to still designate the run — then `activePointerFileFor` (the resolution ladder `activePointerFor` is now a view over —
renaming it silently returns the retire path to a re-derived basename that names nothing whenever
the legacy fallback won), `_autopilot_owner_pointer_basename_ok` (the ONE shell spelling of the basename SHAPE RULE,
extracted out of the retire path — NOT "of both pointer basenames", which this clause claimed and
which the same file refutes three times over: `_autopilot_legacy_active_path` and
`_autopilot_storage_safe` each spell `autopilot-active.json`, and `_autopilot_active_path` spells
`autopilot-active-%s.json`, so renaming a pointer on the strength of the retired wording leaves
those minting the old name while this gate refuses every basename the worker prints, and
`_autopilot_retire_unreachable` then fires on EVERY takeover), `_autopilot_retire_unreachable` (intra-file,
and its message HAND-COPIES `read-active`'s refusal sentence, which therefore has THREE carriers:
the producer, this helper, and `skills/autopilot-adopt/SKILL.md`), `_autopilot_adopt_refusal`
(intra-file; the named-refusal channel the adopt skill's stderr discriminators depend on),
`_autopilot_locked_dispatch`'s post-lock refusal line — which is NOT intra-file and was
omitted from this roster for a release: its text is quoted verbatim in
`skills/autopilot-adopt/SKILL.md`'s exit-2 row as one of the three discriminating prefixes
and pinned by literal in B28, so a reword is a three-carrier edit. It must stay VERB-NEUTRAL:
that dispatcher serves `begin`, `apply`, `release` and `adopt` alike, so naming one verb there
mislabels the other three — and it branches on an empty run id, because five callers pass one,
`_autopilot_identifier_ok` and `_autopilot_owner_identity_ok` — the latter the shell mirror of the
worker's `ownerIdentity`, the INTERSECTION predicate both persisting verbs apply, so a rename of
either half silently returns `begin` and `adopt` to disagreeing vocabularies — then
`_autopilot_owner_key`, `_autopilot_active_path`,
`_autopilot_legacy_active_path`, `autopilot_workspace_root`, `_autopilot_session_workspace`,
`_autopilot_read_workspace_critical`, `autopilot_read_workspace`,
`autopilot_workspace_hold_report` — the PUBLIC verb `hooks/lib/zensu-log.sh`'s
`--autopilot-status` branch calls by name, together with its `<kind><TAB><sentence>` wire format
and its 0/1/5/3 status vocabulary, both of which that branch parses. **TWO thin derivations were
DELETED rather than kept, and the reason generalizes:** `autopilot_workspace_hold_sentence` and
`autopilot_workspace_hold_is_own` had NO production caller anywhere in the tree, each took a
second leased read of its own, and this roster's own previous wording warned that they must never
be composed with each other because two reads can name different holders. A public verb with no
consumers, carrying a composition hazard, is a liability rather than an API — the ownership fact
lives in the report line's `<kind>` field, which is the same answer from the same read. Their
coverage moved with them: `W31a`-`W31e` now drive the report verb directly and `W31i` reads that
field, so nothing was lost. Do not reintroduce either as a convenience wrapper.
Renaming the report verb
is a cross-file edit whose failure mode is SILENT and wrong in the dangerous direction: the
caller captures the sentence in a command substitution and reads the status, so a missing
function yields 127, which the branch reports as "could not be determined" — correct only by
accident — and
`_autopilot_workspace_refusal` — which `stop-chain-enforcer.sh`'s rc=4 arm NO LONGER resolves at
all: it once resolved three names there by `declare -F`, and all three are gone (the ownership
read moved into the renderer, and the re-read fallback was deleted). What the arm now depends on
across the file boundary is the VARIABLE spelling, not a function name; the one surviving
`declare -F` in that file guards `autopilot_adopt_pending_review` and is unrelated —
`_autopilot_holder_owner`, `_autopilot_holder_run_id`, `zensu_pending_review_claim_file` (exported from
`zensu-tdd-phase.sh` so the `.claim` suffix is not re-encoded here — a drifted copy would fail
OPEN, because adoption RENAMES the marker onto the claim and a reader looking for the wrong name
would see neither file and answer "no work" while a deferred review is live; the accessor now
takes an OPTIONAL pre-resolved pending path, and the owner module's five former hand-spellings
call it, so `zensu-tdd-phase.sh` spells the suffix exactly ONCE. A SIXTH spelling survives outside
that module and belongs on this roster: `hooks/lib/session-control-core-v1.js` hardcodes the whole
filename `pending-review.json.claim`, which no accessor can reach and nothing pins against this
one) and
`_autopilot_publish_workspace_refusal` (both intra-file: the Stop
hook calls neither, so renaming either is a single-file edit), plus the module-scope
`ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT` that publisher sets — THAT spelling is what
`stop-chain-enforcer.sh`'s rc=4 arm reads across the file boundary, so renaming IT is a
cross-file edit whose failure mode is the unnamed fallback — `_autopilot_deferred_work_present`,
`_autopilot_workspace_hold_blocks_adoption` (whose pending predicate is a HAND COPY of
`_tdd_adopt_pending_review_critical`'s ladder, pinned end-to-end by S7/S7d/S7e/S7i and
arm-by-arm by S7f/S7f2/S7g, which drive it directly because no hook fixture reaches those
guards; S7h and S7h2 pin the holder preference at the private and PUBLIC read; S8i pins the own-run remedy end to end through the LOCKED
fence, and S8g reaches the same wording through the CONTENTION fence — its stub kills
`_autopilot_locked_run`, so the two cover both publish paths rather than one twice), `_autopilot_rendered_dir`, `autopilot_release_run`, the `read-active` / `read-workspace` /
`begin` / `apply` / `release` / budget worker modes with their `path_indexes`,
`projectRootIndex` and `workspaceRootIndex` entries, the worker's own second re-encoding of the
pointer name (`activePointerFor`, `OWNER_POINTER_PREFIX`, `LEGACY_POINTER_NAME`), the SEVEN hook
`read-active` call sites enumerated above, the three `ACTIVE_POINTER_HINT` probes that name both
pointer spellings, `hooks/lib/zensu-log.sh` (the `--workspace` flag, the owner-aware
`--autopilot-status`, and the `--autopilot-release` verb with its derived event id),
`skills/autopilot/SKILL.md`, `skills/autopilot-release/SKILL.md`, and the plugin manifest's
skill list. Operator-facing accounts that must move with it: `README.md`'s skill table,
`docs/tdd-manager-workflow.md` §"Autopilot run scope", the `session-start-autopilot-resume.sh`
row in `docs/configuration.md`, and — easy to miss, because the roster named only the resume
row while the deferred-review fence account lives elsewhere — the `stop-chain-enforcer.sh`
row in `docs/configuration.md` — and its `pendingReviewTtlHours` row, the ONLY written statement
anywhere that at `0` a marker of any age sustains this refusal indefinitely. The
`stop-chain-enforcer.sh` row PARAPHRASES the fence's pending-work precondition but
QUOTES all FOUR remedy spellings — `/zensu:autopilot-adopt` and `/zensu:autopilot-release`,
plus the audited `zensu-log.sh --autopilot-adopt --run <id> --confirm` and
`zensu-log.sh --autopilot-release --run <id> --confirm` — so a reword of either remedy is a
cross-file edit. Only the refusal SENTENCE itself is pinned solely by the
`test-autopilot-stop-enforcer.sh` assertions above.
`tests/structure/test-autopilot-state-machine.sh` pins the pointer, the two refusals and the
legacy fallback; `test-autopilot-adversarial-recovery.sh` X1a pins the `begin`, `read-active`,
`release` and `read-workspace` `path_indexes` literals, and B16 in
`tests/structure/test-autopilot-adopt-cli.sh` pins `adopt`'s. Between them they do NOT pin every
mode in the table — `read-run`, `apply`, `team-review-receipt-meta` and the two budget modes are
unpinned, so a change to one of those fails behaviorally or not at all.
