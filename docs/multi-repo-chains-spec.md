# Multi-Repo Chains — Anchor and Declared Code Roots

**Status: stage 1 is IMPLEMENTED; stages 2 and 3 are REDESIGNED, NOT BUILT.** Stage 1 ships in
`hooks/lib/zensu-log.sh` (the terminus judges the receipt's verdict and arms the
requirement on a logged claim), `hooks/lib/zensu-edit-landing.sh` (a claim resolving
outside the audited root fails the audit and names the foreign root, plus the
read-only `--inventory` mode its two consumers share) and
`hooks/lib/zensu-doctor-report.js` (the topology row). **Which half of stage 1 is universally live is narrower than "stage 1 is implemented":** `zensu-log.sh append` redacts a run-log message before it lands, rewriting `$HOME` to `~` and the project root to `<project>`, and the audit's absolute-claim arm only ever sees a path still beginning with `/`. So a foreign root OUTSIDE every home directory and the project root — `/opt`, `/srv`, a CI checkout under `/builds` — is detected, while a SIBLING REPOSITORY UNDER `$HOME`, the topology §2's own worked example uses, is rewritten out of that shape and is not, and one under another user's home or `/root` becomes `<home>` and names no root either. See the redactor gap in `CLAUDE.md` §"Multi-Repo Stage 1".

**Stages 2 and 3 were redesigned on 2026-10-21.** The sealed carrier §6.1.1 decided on
2026-09-20 — the Session Control record, an interactive confirmation at arming, and a
containment gate on the Bash channel into the plugin-data store — is SUPERSEDED. Its
premise was that the root list widens two capability boundaries, and one of them, the Bash
source-write gate, became opt-in and off by default on 2026-10-03 (PR #368), after that
decision. The list now lives in the workflow document as a validated, model-declared
declaration, and it bounds accidents (a forgotten or wrong repository), not intent: the bar
the workflow document, the receipt and the run log already meet (§8). Stage 3's
cross-repository check becomes one review perspective inside the existing fan-out instead of
a new chain stage (§7). Nothing of stages 2 and 3 is built yet; they ship as five pull
requests behind a dark-launch switch (§9). Every "today" statement below was
read at the cited site in the worktree that authored this document; every "would"
statement is design, not behavior — EXCEPT §5, which is behavior now and says so
per item, and the two §2 paragraphs stage 1 superseded, which say so in place.

Companion pages: [the principle page](multi-repo-chains-principle.html) states the
principle in one diagram; [the overview page](multi-repo-chains-overview.html)
walks the same material visually, including the per-site findings this document
cites.

## 1. The problem

A session whose `CLAUDE_PROJECT_DIR` is an orchestrator repository, while the code
it writes lands in sibling repositories or worktrees, is served by a chain that
cannot see that code. The chain's evidence spine — the edit-landing audit, the
review packet, the terminus checks — is anchored on one project root, and the
reviewer is anchored on the same root. The result is not a refusal. It is a chain
that converges green having audited and reviewed nothing.

## 2. What is verified today

Six sites, all single-root.

**The anchor has one resolver.** `tdd_state_file()` builds
`<project_root>/.zensu/state/tdd-phase-<session>.json` from
`zensu_resolve_project_dir()` (`hooks/lib/zensu-tdd-phase.sh:144-151`), and
`pre-bash-source-write-gate.sh:264-271` refuses an empty recorded root outright,
while that opt-in gate is on, rather than letting the parser fall back to the payload cwd. The STATE anchor is
therefore a trusted value derived from the immutable Session Control record.
Nothing in this proposal weakens that.

One of the consumers named in §6.3 does NOT sit on that binding: the audit's
default `--project` is `${CLAUDE_PROJECT_DIR:-.}`
(`hooks/lib/zensu-edit-landing.sh:55`) — ambient, with a `.` fallback. The Terminus
row covers TWO sites, and neither is ambient. `--tdd-complete`'s change count
resolves its root through `zensu_resolve_project_dir()`
(`hooks/lib/zensu-log.sh:1536`) and counts through the shared helper (`:1574`),
which runs every `git` call with the discovery and config-injection variables unset
(`:89`, `:118-119`). The `--chain-done` zero-change terminus counts through the same
helper, on the
`CLAUDE_PROJECT_DIR` that `zensu-log.sh` re-exports from `zensu_resolve_project_dir()`
before any verb runs, so the `.` fallback never applies there. Which root the ambient
variable names for the audit in a multi-root topology, and what the fallback means
when it is unset, is an open question (§11).

**The edit-landing audit already takes a `--project` argument** — it defaults to
`CLAUDE_PROJECT_DIR` (`hooks/lib/zensu-edit-landing.sh:55`, flag at `:90`) and
enumerates the change set with `_el_git -C "$REPO_ROOT"` (`:241-266`). But its receipt
lands at `<--project>/.zensu/state/edit-landing-<session>.json` (`:984`), while
`--tdd-complete` looks for it beside the ANCHOR's workflow document
(`hooks/lib/zensu-log.sh:1525`). Running the audit once per repository therefore
writes receipts nothing reads, and no run can exit 0. What each run REPORTS changed
with stage 1, item 3: an ABSOLUTE claim resolving outside the audited root is now
named as a foreign root rather than reported as unresolvable, and so is a RELATIVE
claim that, joined at the repository top, lands in a work tree nested under the
anchor, while a RELATIVE claim naming a SIBLING repository's file stays
indistinguishable from an anchor claim — the gap §5 names.

**The receipt gate was scoped by the anchor's change count — SUPERSEDED by stage 1,
item 2.** As read for this document, `zensu-log.sh` counted `git diff --name-only
HEAD` plus untracked files under a root resolved by `zensu_resolve_project_dir()`
— not the ambient variable, and with the git environment scrubbed — and skipped the
receipt requirement entirely at zero, so a clean orchestrator closed the chain with
no receipt at all. It now ALSO arms on a logged claim: the run log located from
`--plan`'s stem, else the claim count the receipt itself records. A chain that
claimed nothing is still exempt, and that exemption is what keeps hermetic
chain-mechanics tests from having to fabricate a receipt. The `--chain-done`
zero-change terminus is unchanged by item 2: it still refuses on the change count
alone, which it now takes through the same scrubbed wrapper — see the paragraph above.

**The write gate confines Bash writes while it is opted in, the edit gate does not confine
paths.** Rules (A)/(B)/(C) run only when `hooks.bashWriteGate` is `true`. Rule (B) denies at `!within(projectRoot, p)`
(`hooks/lib/bash-source-write-parse.js:885`) and rule (C) at the same predicate
for git targets (`:931`), with `projectRoot` taken from the passed
`CLAUDE_PROJECT_DIR` (`:780`). `hooks/pre-edit-tdd-reminder.sh:132-160` resolves a
relative path against the project root and then classifies it only as `state`,
`zensu`, or `other` — an absolute path outside the root is not denied there. So
`Edit`/`Write` reach a sibling repository today, and Bash writes do too unless the gate is
opted in. Neither of
the two other hooks on the `Bash` matcher confines a path to the project root, so
neither needs changing: `pre-bash-zensu-gate.sh` carries no project-root reference
at all, and `pre-write-secret-scan.sh:85` references one only through the
orphaned-root bind predicate, never as a path check.

**The reviewer is confined to the project root.**
`protectedAccessViolation` in `hooks/lib/reviewer-capability-v1.js:633` refuses any
reviewer path input outside the root with `file access must remain inside the
immutable project root`, and `:594-596` rejects an absolute Grep/Glob pattern, a
`..` segment, and a `.zensu` segment. A reviewer cannot read a sibling repository
even when the packet names its files.

**Claims are repo-root-relative.** `skills/tdd/references/execution.md:9, :12` requires every logged
`WIRED — files:` / `IMPL completed — files:` list to be relative to
`git rev-parse --show-toplevel`. Across two roots `src/foo.ts` is ambiguous.

## 3. Non-goals

- Multiple equal project roots. There is exactly one anchor, and it keeps the
  Session Control record, the state directory, the run log, the workflow
  document, the phase gate and every `/zensu:doctor` row.
- Any change to `~/.claude` state, to the session registry, or to how Claude Code
  itself records a session.
- Making a code root resumable. See §6.4.
- Cross-repository commits, pushes, or a merged pull request. Each root keeps its
  own VCS lifecycle.

### 3.1 Alternatives considered

The ADR doc type in `docs/documentation-guide.md:59` asks an architectural
decision to carry "alternatives considered". That guide scopes itself to Zensu
wiki and linked feature docs rather than to repository design documents, so this
is a convention adopted rather than one owed. Its absence made stages 2 and 3
read as inevitable, which they are not.

**One ordinary chain per repository.** Cost: zero. Each repository is its own
anchor, audited and reviewed by today's unmodified code. It solves §1's stated
defect completely — nothing converges green having reviewed nothing, because
nothing is out of root. What it costs is on the operator's side: N sessions to
drive, the orchestrator's planning context split across them, no shared run log,
and — the only capability genuinely lost — no cross-root finding is reachable,
because no reviewer ever sees two roots at once. It stays the answer until stage 2
ships, and the field case of 2026-10-20 showed its price: one session per repository
for one change set, with the planning context split across them.

**Stage 1 alone.** Cost: a patch. It closes the TERMINUS-level silent green for
every chain, multi-root or not, and leaves the topology unsupported but honest.
It does not close the aliasing case inside the audit (§5, item 3), which needs
the §6.1 root label. It is independently valuable and does not commit to
anything below.

**This proposal, as redesigned on 2026-10-21.** Cost: one minor release delivered in
five pull requests, a reviewer read confinement widened to the declared roots, an
opt-in write gate that admits them, a per-root path in every consumer §6.3 lists, and
no new chain shape. It buys a chain whose evidence and review cover every repository
it touched, and a review that sees the relation between roots.

## 4. Terminology

**Anchor** — the session's single project root, resolved exactly as today.

**Code root** — an additional git work tree, declared at arming time, that this
chain may write to and must audit and review: a worktree nested under the anchor, a
symlinked sibling or a plain sibling. Never carries state.

**Label** — the slug a code root is declared under. A file in a code root is
spelled `@<label>/<path>`, relative to that root's top (§6.1).

**Union** — the anchor plus every code root. The only new set.

**Satellite** — an informal synonym for a code root, used in the companion pages'
visuals where "code root" reads heavily. Never used normatively.

## 5. Stage 1 — Detect and refuse (patch, no schema change) — IMPLEMENTED

Stage 1 ships no multi-root capability. It removes the silent green. All four items
below are behavior now; the pins are named at the end of §10.

1. **The terminus reads the receipt's verdict, not its existence.** This is the
   larger half of the silent green and the original draft of this section missed
   it. The gate WAS `if [ ! -f "$_tc_receipt" ] || [ -L "$_tc_receipt" ]` — an existence-and-not-a-symlink test — while the audit
   writes its receipt *before* its own exit status is produced, carrying `clean` as
   a field rather than as a precondition for writing, so an audit that reported
   `EDIT NOT LANDED` and exited non-zero still satisfied that gate.
   `--tdd-complete` now accepts ONLY a receipt that parses and
   records `clean: true`, and refuses every other state — `clean: false`, the
   field absent, the JSON unparseable, an unknown `schema`. The affirmative
   spelling is load-bearing: "refuse on `clean: false`" would accept a
   truncated, schema-drifted or hand-planted receipt that carries no verdict at
   all, and §8.1 establishes that the state directory is writable from inside
   the session through a shell redirect no gate covers.
2. `--tdd-complete` evaluates the receipt requirement even when the anchor's
   change count is zero, whenever the run log carries at least one
   `IMPL completed — files:` or `WIRED — files:` claim. A chain that logged
   claims has something to verify regardless of what the anchor's tree looks like.
   A chain with no claims stays exempt, as today — and that exemption is
   load-bearing for a second reason the comment beside it gives: hermetic
   chain-mechanics tests must not be forced to fabricate a receipt. §10 pins both
   sides of that boundary in one test so it cannot drift one-sided.
3. The edit-landing audit fails, rather than silently reporting "not landed", when
   a claim resolves to a path outside the audited root, and names the foreign
   root in the failure.
4. A `/zensu:doctor` row names the topology: claims logged against a root that is
   not the anchor.

**Item 3 is partial by construction, and saying so is part of stage 1.** Without
the stage-2 label a foreign claim is recognised only where the filesystem places it:
an *absolute* claim, or a relative claim that, joined at the repository top, lands
in a work tree nested under the anchor. A relative claim from a sibling code root
(`src/foo.ts`) is textually indistinguishable from an anchor
claim that never landed — and where the anchor happens to hold a dirty file at the
same repo-relative path, which `src/index.ts` or `package.json` routinely will
across sibling repositories, the foreign claim resolves against the anchor's file
and grades as landed. That is a false green *inside* the audit, in the exact
direction stage 1 exists to close. Full detection needs the root label from §6.1;
§10 pins the aliasing case as an explicit negative.

After stage 1 the chain is still single-root. The terminus no longer accepts a
receipt that records a failure, and the document no longer claims a detection it
cannot perform. One gap remains open by construction and is named rather than
implied: a relative claim that collides with a same-named file in the anchor can
still grade as landed, and only the §6.1 label closes it.

## 6. Stage 2 — Declared code roots (minor) — REDESIGNED 2026-10-21, NOT BUILT

### 6.1 Data model

One new field in the workflow document, written only by `--tdd-begin` and by no other
verb:

```text
codeRoots: [ { label: "<slug>", path: "<canonical absolute path>", top: "<work-tree top>",
               commonDir: "<git common directory>", baseline: "<HEAD sha>" | "unborn" }, … ]
```

The field is a declaration, not a capability grant: `codeRoots` in the workflow document
bounds accidents, not intent (§8.1).

`label` names the root in every carrier a model reads. A file in a code root is spelled
`@<label>/<path relative to that root's top>`; the anchor's own claims keep their
unprefixed spelling, so every existing log line stays valid and a single-root chain is
untouched. The spelling is NOT the `label:path` an earlier revision of this section
chose, for four reasons read from the code: `zensu_safe_render` escapes every `:` in a
rendered verdict line, `hooks/lib/finding-verify-v1.js` excludes `:` from the path part of a
citation, a one-letter `x:` prefix reads as a drive letter in the findings ledger and in
the external-review reader, and a `label:` prefix hides a following `.zensu` segment from
the segment checks those readers apply. An `@x/` path whose `x` is not a declared label is
an ordinary anchor path. Markdown carriers put these paths in code spans, because
`@org/team` is GitHub mention syntax. The label is also what closes the aliasing gap of
§5: a code-root file claimed under its label can no longer resolve against a same-named
file in the anchor, while a code-root file claimed without it still can.

The field is written inside `_tdd_begin_session_critical`
(`hooks/lib/zensu-tdd-phase.sh`): set when `--tdd-begin --code-root <label>=<path>` names
roots, deleted otherwise, so the standalone begin, the Autopilot-bound begin and the
deferred-review seed each start a generation with exactly the list they were given. The seed
is given none: `tdd_seed_deferred_review` carries only the session, `vanilla` and the claim,
so a review the Stop hook adopts starts single-root, a named bound (§11). `baseline` is the
root's HEAD at arming, or the commit `--code-root-baseline <label>=<sha>` names, which must be
an ancestor of that HEAD: a root declared after its work was committed needs the commit that
work started from, or its commits fall outside `<baseline>..HEAD`.

The list belongs to the reset class of `vanilla`, not to that of a counter. The resets that
clear `vanilla` delete it — `_tdd_write_clear_critical`,
`_tdd_clear_standalone_session_critical` and `_tdd_clear_autopilot_session_critical` in
`hooks/lib/zensu-tdd-phase.sh`, and `resetDeferredReviewState` in
`hooks/lib/session-control-core-v1.js` — and the two that keep `vanilla` keep it: the chain
reset `_tdd_write_chain_reset_critical`, because a chain that lost its roots mid-generation
would silently become single-root, and the `deferred-review-transfer` draft. Absent is the
ONLY single-root form — never an empty array — so a single-root document stays
byte-identical to today's. `--code-root` and `--code-root-baseline` are refused together with
the Autopilot binding flags; a multi-repo Autopilot run is out of scope (§11). The list
reaches the critical section as one validated compact-JSON argument, which changes the arity
of `autopilot_begin_standalone_tdd` (three arguments today).

The core does not judge the list. `validateWorkflowState`
(`hooks/lib/session-control-core-v1.js`) keeps every field outside its reserved set as an
extension and fails the whole document on any rule `validateWorkflowExtensions` names, so a
check there would fail every hook closed on a hand edit. `codeRoots` therefore gets no rule in
the core. Its one judge is the reader, `readCodeRoots` in `code-roots-v1`, a new module in
`hooks/lib/`: it accepts an array of at most eight objects, each carrying exactly the five
string keys above, re-checks every rule of §6.2 that a string comparison decides, and
otherwise falls back to anchor-only and says so. A hand-edited list therefore degrades a chain
to single-root, where stage 1 refuses the foreign claims it can see, instead of failing every
hook closed. That exact-key check is a strict key set of the reader, introduced by PR B (§9).
No field is added to the Session Control record, so the `SCHEMA_VERSION` question of the
superseded design does not arise.

### 6.1.1 Provenance of the list — DECIDED 2026-09-20, SUPERSEDED 2026-10-21

**The superseded decision, kept as history.** On 2026-09-20 this section chose a PAIR:
the Session Control record as the carrier, answering INTEGRITY (where the list is stored,
so the session cannot rewrite it), plus an interactive confirmation at arming, answering
PROVENANCE (where its content comes from, so it is not model-authored). It ordered three
preconditions before any stage-2 code: a containment gate on the Bash channel into the
plugin-data store, a `code_roots` field on the record, and the seal. The analysis that one
candidate answers one question and a working answer is a pair still holds; what changed is
whether the list needs an answer at that strength.

**The premise moved.** The seal existed because the list was to widen two capability
boundaries: rules (B)/(C) of the Bash source-write gate and the reviewer read confinement.
On 2026-10-03, after that decision, PR #368 made the Bash source-write gate opt-in and off
by default, and `docs/configuration.md` now calls it a convention nudge rather than a hard
boundary; blocked multi-repository layouts were one stated reason for the flip
(`.claude/rules/git-mutation-tables.md`). At the default nothing confines a main-thread
write to the anchor — on the Edit/Write matcher only the plugin-data store is contained
(`hooks/pre-write-plugin-data-guard.sh`), and `.zensu/state/` is refused while a session is
active (`hooks/pre-edit-tdd-reminder.sh`) — and the main thread reads any path. A reviewer
that may read a validated git work tree therefore holds nothing the session lacks.

**The redesign.** The list is a model-declared declaration, validated at arming (§6.2),
re-checked on every read, and bounded by the threat model of §8. It guards against
ACCIDENTS — a forgotten repository, a wrong path, a root another session owns — and not
against intent, because the workflow document, the receipt and the run log are
session-writable already (§8.1). That is the bar the evidence spine meets today; sealing
one field would not lift the chain above it. The three preconditions are therefore no
longer prerequisites of stage 2. The Bash containment gate into the plugin-data store stays
worth building on its own merits, for the records and leases it protects.

**A sealed "strict evidence" mode remains possible** on the 2026-09-20 path, for an
operator who wants intent resistance for the list. It is not specified here.

### 6.1.2 What a carrier costs today — MEASURED 2026-08-28, Edit row SUPERSEDED

**Historical since 2026-10-21.** This measurement priced the sealed carrier of §6.1.1. The
redesign stores the list in the workflow document and needs no containment gate, so nothing
below gates stage 2 any longer; it is kept because its Edit and Bash rows still describe the
plugin-data store. Below, "§6.1.1" and "the three candidates above" mean that section as it
read on 2026-08-28, which named three carriers the session could not write: (1) the immutable
Session Control record minted at SessionStart, (2) a plugin-data sidecar written once outside
the project tree, and (3) an interactive confirmation at arming that the model cannot answer on
the user's behalf. Precondition 1 is the Bash containment gate of the 2026-09-20 decision.

The three candidates above are not equally priced, and the price is not the one
§6.1.1 implies. Measured on 2026-08-28 against this repository at `a0ffb05`, on
macOS, by driving the real hooks over synthetic payloads with a real Session
Control session.

**Three PreToolUse hooks govern a `Write`, not two.** `hooks/hooks.json:5`
registers `pre-reviewer-capability-gate.sh` on the `.*` matcher
(`hooks/hooks.json:9`), beside `pre-edit-tdd-reminder.sh` and
`pre-write-secret-scan.sh` on `Edit|Write|MultiEdit`. A deny from any one of them
wins, so all three were driven. Three destinations were used — a file inside the
project, a file inside `CLAUDE_PLUGIN_DATA`, and a file in an unrelated directory
— in three chain states.

| Chain state | inside project | inside plugin data | unrelated directory |
|---|---|---|---|
| no chain armed | allow | allow | allow |
| vanilla chain armed | allow | allow | allow |
| strict chain at `RED_WRITE` | allow | allow | allow |

All nine cells are `allow` for all three hooks. **No hook on this matcher performs
a containment check of any kind.**

**Consequence for §6.1.1.** Moving the list out of the project tree buys nothing
on its own. Both file-based candidates live under `CLAUDE_PLUGIN_DATA` — the
Session Control record store is `<plugin data>/session-control/v1/` — and a
`Write` there is ungated in every measured state, including the state in which
stage 2 would READ the list, namely at arming with no chain yet armed. Candidates
1 and 2 are therefore not carriers today. They become carriers only once a
containment check exists on the Edit matcher.

**SUPERSEDED IN PART on 2026-09-20 — the Edit row has changed, and "no hook on
this matcher performs a containment check of any kind" is no longer true.**
`hooks/pre-write-plugin-data-guard.sh` has since shipped and is registered on both
`Edit|Write|MultiEdit` and `NotebookEdit` (`hooks/hooks.json`). Driven against this
repository on 2026-09-20, a `Write` naming a file under
`<plugin data>/session-control/v1/` is DENIED by that hook, with a reason that
states this section's own argument back: "a gate would end up reading its own
boundary from a file the gated party rewrote". A `Write` to an ordinary file inside
the project still allows, so the deny is containment rather than a blanket refusal.
The table above holds for the tree it was measured in and nowhere else.

**The Bash row is unchanged, and it is what precondition 1 of §6.1.1 exists for.**
Verified in source on the same date: `bash-source-write-parse.js` contains zero
occurrences of `CLAUDE_PLUGIN_DATA` or `.zensu`, and CLAUDE.md §"Plugin-Data Guard"
records the uncovered Bash channel as that guard's own first residual. **This was
NOT re-measured behaviorally, and the reason is this section's own trap one field
over:** a synthetic payload carrying no session id makes the gate fail closed on
the binding, so the deny it returns says nothing about containment. Re-measure it
with a real bound session before writing precondition 1, exactly as the paragraph
below requires a `cwd`.

**The ordering is a requirement, not a preference.** The gate first, then the
file, then the seal. Built the other way round, the list looks trustworthy and is
not, which is the exact failure §8.1 exists to name.

**That gate is itself a breaking change.** Under CLAUDE.md §"Runtime Lineage
(`version_type` is load-bearing)", adding a hook is a `patch` UNLESS it can DENY;
a hook that can refuse a tool call changes the capability set of every session an
older runtime is still serving. So the containment check costs a `minor` release
on top of whatever the carrier itself costs.

**Only candidate 3 escapes this.** An interactive confirmation at arming persists
nothing, so it needs no gate. Its cost — every arming needs a human, which ends
unattended `/zensu:autopilot` runs — is unchanged, and it is now the only
candidate whose price did not rise.

**Two limits of this measurement, stated rather than implied.** First, a strict
chain at `UNINITIALIZED` denies all three destinations, but with the phase
wording and for the unrelated directory too: that is TDD discipline, not
containment, and it lifts at `RED_WRITE` and `REFACTOR`
(`hooks/pre-edit-tdd-reminder.sh:206, :219`). Reading that deny as a boundary is the
mistake this paragraph exists to prevent. Second, the first run of this
measurement recorded a false DENY from the capability gate for every destination,
because the payload carried no `cwd`
(`hooks/lib/reviewer-capability-v1.js:291`); any re-measurement must carry one, or
it will report a containment that is not there.

### 6.2 Validation, performed once at arming

This is an accident guard over a list that grants little (§8), so it is strict about
what a mistaken path can reach and cheap at use time. The `code-roots-v1` module owns
every rule below, and the shell calls its CLI. It is not a built-ins-only module. It calls
`within` from `hooks/lib/bash-source-write-parse.js`, the containment rule that `trail.mjs`,
the plugin-data guard and the re-anchor already share. It takes the read-only prefix
`READ_ONLY_GIT` and the git environment scrub `gitEnvironment` from `git-read-only-v1`, a new
leaf module in `hooks/lib/` that requires built-ins only: `READ_ONLY_GIT` moves there from
`skills/session-trail/scripts/trail.mjs`, where it is a private constant today, and
`gitEnvironment` from `hooks/lib/evidence-run-v1.js`. The parser (PR B), the evidence runner
(PR C) and `trail.mjs` (PR D) import both from there, so no consumer keeps a copy and no
require cycles through the parser. A path is accepted only if all of the following hold.

**Shape.** It canonicalizes, is a directory, and is the top level of a git work tree.
Git is asked with `READ_ONLY_GIT` and `gitEnvironment`, because every git call into a code
root runs another repository's configuration (§8).

**Position.** It is not the anchor and not an ancestor of the anchor. It MAY be a
descendant of the anchor when it is its own work-tree top: a worktree nested under the
anchor, which is the field case this redesign answers, or an initialized submodule
checkout. A path inside a nested root belongs to the innermost work tree that contains it,
the placement stage 1 already performs through `nested_worktree_of`. Roots neither contain
nor are contained by each other, and none is a filesystem root.

**Location.** It is not `$HOME` and not an ancestor of `$HOME`; a root below `$HOME` is the
ordinary case, the field case included. It is neither equal to, nor an ancestor of, nor a
descendant of `~/.claude` (or `CLAUDE_CONFIG_DIR`), the plugin root or the plugin-data
directory. The wording of 2026-09-20, "not any directory containing `.claude/`", would have
rejected most repositories, which carry a project `.claude/` of their own. What must stay out
of reach is the operator's control surface, and marketplace clones under `~/.claude/plugins`
are git work trees too.

**Exclusivity.** Its work-tree top overlaps neither the recorded `project_root` of another
live Session Control record nor a root another live chain declared, judged by work-tree top
rather than by path equality, so a session recorded in a subdirectory of the root still
counts. Two readers of `hooks/lib/session-reanchor-v1.js` decide it, and neither needs any
knowledge of code roots. `registryClaims` lists every other live session with its working
directory and recorded project root, and `code-roots-v1` reads each one's declared roots from
the workflow state under that recorded root, so a chain anchored anywhere that declared an
overlapping root is found. `liveClaims`, called with the candidate root's own registered
worktrees, covers the other half: a live session whose working directory, recorded root or
keep anchor lies in the candidate's tree. `liveClaims` alone would miss the first case,
because it keeps only claims inside the target tree. An answer either reader cannot verify
refuses the arming, as it refuses a re-anchor. The module requires both lazily, inside the
arming check, so a consumer that only reads the list never loads them. Nor may a
durable Autopilot run hold it: the anchor's inventory is read inside
`_autopilot_begin_standalone_tdd_critical` under the lease that section already holds, and
each root's own state directory is read without a lease, because the run-scope rules forbid
taking a second one. Exclusivity is judged last, after every other rule passed, so a cheap
refusal never waits on the probe or the lease.

**Characters.** No `"`, `$`, backtick, backslash, `,`, `=`, control byte or newline. Skills
paste a root into `cd "<root>" && …`, and the review packet carries one `<label> <path>`
entry per line. On win32 the stored spelling is the forward-slash drive form `C:/…` that
`hooks/lib/zensu-host-path.sh` prints, and the rule applies after that mapping, the way
`unpastableRoot` in `hooks/lib/session-reanchor-v1.js` applies the same paste rule: a native
`\` separator is never stored and never refused.

**Case.** Comparisons fold case on darwin and win32, where the filesystem does.

**Bound.** At most eight entries, so one arming cannot grant a machine-sized surface.

**`label`** matches `^[a-z][a-z0-9-]{1,31}$` and is unique. Two characters at least, so no
label reads as a drive letter. No top-level entry of the anchor may be named `@<label>`, so
the spelling of §6.1 never shadows a real anchor path.

A rejected entry refuses the arming with its reason. It is never silently dropped: a
dropped root is a root nothing audits. Use-time re-validation covers every rule a string
comparison decides — the entry shape, characters, label, bound, position against the anchor
and against each other, and location, each compared on the stored canonical paths — which
`readCodeRoots` re-runs on every read. Shape and exclusivity read the filesystem and the live
sessions, so they are judged at arming only, and a list written by hand afterwards is not held
to them. A path replaced by a symlink after arming is therefore followed, the TOCTOU bound
this section accepted on 2026-09-20 as well, pinned as current behaviour (§10), and so is a
hand-written entry that reaches a control surface through a link or names another live
session's tree, which only the arming probe can see; §11 names that residual. A root that
vanished mid-chain surfaces as a git fault naming the root, never as a clean count.

### 6.3 The consumers that read the union

Every consumer reads the list through `readCodeRoots`, and enumerates or counts a code root
through the same module, so one module decides what changed in a root. Sites are named by
symbol rather than by line, because the stage-2 pull requests move most of these lines.

| Consumer | Change | Site |
|---|---|---|
| Change sets | Enumerate a code root with the audit's recipe for the anchor — `diff HEAD`, `<baseline>..HEAD`, untracked files, an unborn HEAD through `ls-files --cached --others` — and count the same sources through the terminus's recipe, which adds `<baseline>..HEAD` and the unborn case to what `_zensu_unqualified_change_count` counts for the anchor; never answer `unknown` for a code root: a failure is `unavailable`. The two anchor recipes differ in one flag: the audit's `_el_git` passes `-c core.excludesFile=/dev/null`, while `_tc_git` behind the count keeps the global excludes file. The module follows each for its own consumer, the enumeration the audit's and the count the terminus's, and one parity test per recipe feeds the same fixture to the module and to that shell recipe. Every declared root inside the anchor, and an untracked link inside the anchor that resolves to one, is excluded from the anchor's own diff, untracked listing and tree fingerprint, or the anchor would list the root as one untracked `<dir>/` entry and the union would never reach zero. | `code-roots-v1` (new, in `hooks/lib/`), `_zensu_unqualified_change_count` in `hooks/lib/zensu-log.sh` |
| Edit-landing audit | Read the roots from the session's workflow document (from `--session`; the two `--inventory` callers hand the document over). Grade an `@<label>/` claim against that root's change set, with `in_union`, `is_ignored` and `was_dirty_before` per root and `--dirty-before` entries in the same spelling; the per-claim `check-ignore` of `is_ignored`, which runs through `_el_git` without the read-only prefix today, goes through the module for a code-root claim. Grade a claim that resolves into a declared root under any other spelling — absolute, through an in-anchor link, or redacted to `~/…` or `<home>/…` by the run-log writer, which the audit maps back against the declared roots before it classifies — `UNVERIFIED (respell)`, naming the exact `@<label>/` spelling, so claims, round scopes, ledger anchors and the packet share one spelling. Keep the stage-1 refusal for an undeclared foreign root, with "declare it with `--code-root` and re-arm" in its remedy. The remedy names `--code-root-baseline <label>=<sha>` for work already committed in that root, because a re-arm starts a new generation whose baseline would otherwise already contain those commits. A git fault in any root is an `EDIT LANDING AUDIT FAULT` naming that root. The receipt keeps schema `edit-landing-v2` and its shape, with `clean` judged over the union, and `--inventory` stops reporting a declared root as foreign. | `hooks/lib/zensu-edit-landing.sh` |
| Change-set verbs | `zensu-log.sh --change-set` prints one `root` line per root and one `file` line per changed path: the single owner of enumeration for the review chain and self-review. `--code-roots` prints the declared list. | `hooks/lib/zensu-log.sh` |
| Terminus | The union is the anchor's answer from `_zensu_unqualified_change_count`, with the declared roots inside the anchor excluded as the change-set row requires, combined with each code root's count: any `unavailable` makes it `unavailable`, any non-zero makes it non-zero, and otherwise it is the anchor's own answer. All four callers — `--tdd-complete`, the `zc_` and the unqualified `--chain-done`, and `--code-review-done` — take it, and so do the requirements-gate scope and the bypass-ledger conditions. | `hooks/lib/zensu-log.sh` |
| Stop probe | The hook's one git probe, the implementing-phase nudge `zensu_impl_stop_nudge`, asks only the anchor's `git status` today; it counts the union inside the existing Stop deadline, a timeout counting as `unavailable`. The zero-change check itself is the terminus count of the row above, and the texts that describe it, `INNER_ZERO_CHANGE_NOTE` and the resume directive's `git diff --name-only HEAD` wording, stop naming the anchor's `git diff` alone. | `hooks/stop-chain-enforcer.sh` |
| Full suite and CI deferral | `--evidence-run --root <label>` runs in that root's top, and a record keeps deriving its root from its `cwd`, so no strict key set changes. Each declared root gets its own tree and fingerprint, and the verdict is computed per root instead of letting the newest full record pick the root. A code root's own `.zensu/config.json` contributes `evidence.fullSuiteCommand` and the runner keys only; the gate mode and every `hooks.*` key stay with the anchor. The gate requires, for the anchor and for every code root whose change count — commits since the baseline included — is non-zero, a green full record on that root's tree or a CI-deferral verdict from that root's own ladder: its clone record, its remote and workflows, and a snapshot per root in a file of its own, `<session key>.<root digest>.json` beside the anchor's `<session key>.json`, whose `projectRoot` names that root, so `SNAPSHOT_KEYS` is unchanged. Each exempted root is disclosed on its own line, and Phase 0 refreshes the CI policy per root path before arming. The close step the post-review directive renders names one `--evidence-run --root <label>` per changed code root beside the anchor's run, each with the scope its own root's ladder decides: the full suite where that root runs it locally, the affected-suite run where its CI runs it. `CLOSE_SUITE_STEP` is `FULL_SUITE_STEP` under the local runner and `AFFECTED_SUITE_STEP` under CI, and `CLOSE_PASS_SUITE_CI` names `AFFECTED_SUITE_STEP` directly, so the four change together; one anchor run would leave the per-root gate refusing the first close. | `hooks/lib/evidence-run-v1.js`, `hooks/lib/full-suite-policy-v1.js`, `hooks/lib/ci-contract-v1.js`, `hooks/post-review-tdd-delegate.sh` |
| Acceptance verification | Freshness and `hasChanges` bind to the union tree — the anchor's tree plus each code root's — so an edit in any root makes a record stale. | `hooks/lib/acceptance-verify-v1.js` |
| Review packet | `changed_files` carries the `@<label>/` paths `--change-set` prints, and a new optional `code_roots` field carries one `<label> <absolute path>` entry per line. A packet without it has no code roots and is never `REVIEW PACKET INVALID`, so a single-root packet stays as it is today, the shape that let the optional `findings_ledger` field ship as a `patch` (`agents/review-judge.md`). The reviewer agents resolve labels through it and cite `@<label>/<path>:<line>`. | `skills/tdd/references/review-chain.md`, `agents/review-aspect.md`, `agents/review-judge.md`, `agents/code-reviewer.md` |
| Capability confinement | A reviewer may read inside every declared root, read from the bound workflow document. The PLM profile `zensu-plm-readonly-v1` gets the same reads, because its `readOnlyViolation` runs the same `protectedAccessViolation`. Every declared root's `.zensu` joins the protected list of reviewers, the PLM profile and neutral subagents, and a path with a `.zensu` segment below the anchor is refused to all three whatever the list says, as is one below a declared root (§7.2). | `hooks/lib/reviewer-capability-v1.js` |
| `crossrepo` perspective | Spawned only when the chain has code roots (§7), with labels stripped before a path is classified. The reviewer contract names it: `agents/review-aspect.md` lists seven perspectives with one checklist line each and `agents/code-reviewer.md` carries checklist lines of its own, so both gain a `crossrepo` entry. The Stop enforcer's resume directive appends it for a chain with code roots, outside the two `REVIEW_PERSPECTIVES` literals that T60 and T61 of `tests/structure/test-stop-enforcer-self-review-routing.sh` pin against the activation module, so both keep pinning the single-root panels. | `hooks/lib/aspect-activation-v1.js`, `agents/review-aspect.md`, `agents/code-reviewer.md`, `hooks/stop-chain-enforcer.sh` |
| Finding verification and ledger | An absolute, `~` or symlink spelling of a path inside a declared root is mapped to `@<label>/`, so a real code-root finding is never neutralized as `out-of-root`; ledger anchors must use `@<label>/`. | `hooks/lib/finding-verify-v1.js`, `hooks/lib/review-ledger-v1.js` |
| External review import | A chain with code roots answers `status=unavailable reason=multi-root` at the import and at `--external-review --stage` and `--tree` alike, so step 3 stages no template workflow whose result the import would refuse, and the panel runs. | `hooks/lib/external-review-v1.js`, `hooks/lib/zensu-log.sh` |
| Self-review | Enumerates through `--change-set`, and its rule to stay in the current worktree admits the declared roots. | `skills/self-review/SKILL.md` |
| Persona activation | Labeled paths are filtered out, so a persona of the anchor never half-matches another repository's code. | `hooks/lib/persona-activation.js` |
| Edit gate | The state-file hardening covers every root's `.zensu/state`, and a test path is classified relative to the top of the root that owns it. | `hooks/pre-edit-tdd-reminder.sh`, `tdd_is_test_path` in `hooks/lib/zensu-tdd-phase.sh` |
| Write gate (opt-in) | While `hooks.bashWriteGate` is `true`, rules (B) and (C) accept a path inside any declared root, and `TEMP_SAFE` rejects a temp entry that contains any member of the union. Rule (A)'s `tracked()` probe, which runs `git ls-files --error-unmatch` and `rev-parse` with neither the read-only prefix nor the scrub today, takes both from `git-read-only-v1` for a path inside a code root. | `hooks/lib/bash-source-write-parse.js`, `hooks/pre-bash-source-write-gate.sh` |
| Doctor | The topology row lists the declared roots and warns only about undeclared foreign ones. | `claimTopologyRow` in `hooks/lib/zensu-doctor-report.js` |
| Session-trail | `gitState` runs once per root (§6.4). | `skills/session-trail/scripts/trail.mjs` |

The write gate's parser receives the anchor today as `CLAUDE_PROJECT_DIR`, an assignment the
hook makes in front of its own `node` call, and the hook payload on stdin
(`hooks/pre-bash-source-write-gate.sh`). The union does not follow the anchor into the
environment. The hook reads the declared roots from the workflow document and hands them to the
parser on stdin, beside the payload, and every parser invocation sets or clears them
explicitly. Stdin is the one channel the session's environment cannot pre-set and the one MSYS
never rewrites on Windows (`.claude/rules/git-mutation-tables.md`), so the parser never reads
the list from an inherited or a command environment.

### 6.4 Session transferability

`/zensu:session-trail` keeps working unchanged, because a multi-root session still
has exactly one `cwd` and one transcript. What degrades is fidelity, and one part
of it degrades dangerously.

`gitState(cwd, full)` (`skills/session-trail/scripts/trail.mjs:2831`) takes a
single path, and that path is the anchor. In this topology the anchor is clean
while the changed files sit in the code roots, so a `takeover` brief would report
no uncommitted changes for a session with a dirty tree in two other repositories.
That is the same silent-green failure as §2, relocated into the handover path.

The fix costs no schema, and it adds no write of its own. `trail.mjs`'s only write
channel of its own is the lineage ledger (`skills/session-trail/references/commands.md:46`), and its
`release --apply` verb also ends keep anchors through the worktree-keep module — it had
no write at all when this paragraph was first written, so state what the FIX costs
rather than what the script lacks. It may read the declared roots through
`readCodeRoots` and call `gitState` once per union member, rendering the results
grouped by label.

Two properties stay as they are, deliberately:

- **Resume happens in the anchor, always.** The printed
  `cd -- <cwd> && claude --resume <id>` (`trail.mjs:5019`) already lands there.
  Resuming inside a code root would present a different `CLAUDE_PROJECT_DIR` while
  the recorded `project_root` still EXISTS, and a present-but-different root is
  never relaxed — the orphaned relaxation requires the recorded path to be absent.
  So the session would not bind as orphaned; it would simply be denied. The resume
  line must never be rewritten to a code root, however plainly the work lives there.

  The `gitState` fix above has a cost worth naming rather than calling it free:
  `trail.mjs` may run outside any session and outside every hook, so teaching it to
  read `codeRoots` makes it another consumer of the model-declared list of §6.1,
  running `git -C` in paths that list names. It costs no schema; it does widen who
  trusts that list, so it reads through `readCodeRoots` and runs git with the
  read-only prefix of §6.2 like every other consumer.
- **Discovery stays anchor-scoped.** `list` keeps only transcript directories
  whose name starts with the slug of the repo's main checkout
  (`skills/session-trail/references/limits.md:12`), so from a code root's repository the
  session is reachable only via `--all` or from the anchor. This is pre-existing
  behavior that multi-repo makes more consequential; this proposal does not
  change it and must not claim to.

## 7. Stage 3 — Cross-repo review (minor) — REDESIGNED 2026-10-21 as a review perspective, NOT BUILT

The cross-repository check is one more perspective of the existing review fan-out, named
`crossrepo`, not a stage between convergence and the terminus. It reads the union and reports
only findings about the relation between roots: a field or payload key added in one root with
no consumer in another, a port and its client disagreeing on shape, version skew across a
published contract. Its findings join the merged list like any other perspective's and route
through the ordinary fix loop into the affected root.

`hooks/lib/aspect-activation-v1.js` spawns it only when it is told that the chain has code
roots (`--multi-root`), and prints nothing for it otherwise, so a single-root chain's log and
the summary lines its suite pins stay byte-identical. It joins both panels, and it runs on a
first review and on every re-review of a multi-root chain, the lean one included: a lean
re-review spawns `correctness` alone today, and the judge re-runs on a re-review only while
`hooks.reviewPanel` is `full` (`hooks/post-review-tdd-delegate.sh`), so without `crossrepo` a
lean round would have no cross-root reader at all. An imported external review is refused for
a multi-root chain anyway (§6.3), and self-review runs no perspective: after the last review
round its whole-change re-read is the only cross-root reading, a named bound (§11). The name
carries no hyphen, because the
activation suite's skip-line pattern admits none in a perspective name, and it is not
`contract`, which the external-review tests reserve as a rejected lens.

**Reservation on record, answered in part.** Two independent reviewers argued that this stage
should be cut or deferred: it addressed a failure mode §1 never states, at the highest price in
the 2026-09-20 proposal — a new chain shape, a strict-key-set change that had to land first, a
second capability grant and a `minor` release. The redesign removes that price: no chain shape,
no `reviewRearm` change, no lease. The evidence half stays unanswered. No cross-root break has
been observed yet, so the perspective has to show its value once stage 2 ships, or be dropped.

A cheaper first move exists and is not blocked on any of it — see §7.4.

### 7.1 Why it is mode-independent

`skills/tdd/references/modes.md:7` lists the whole review chain — fan-out, judge second
pass, Finding Verification Gate, the consuming reviewer, the self-review terminus
— among what runs exactly as written in vanilla. A reviewer reports a finding; it
does not demand a Characterization test. That demand is precisely why the
Cross-Layer Value Flow Audit cannot run in vanilla (`:10`, `:13`), and
the new stage does not inherit it.

### 7.2 What a reviewer may read

No lease is needed. The reviewer confinement of §2 is widened for every reviewer principal
rather than for one agent type: the gate sees only `agent_type`, so a widening confined to the
`crossrepo` agent would need a new agent type or a lease bound by `agent_id`, and reviewers of
a code root's own files need the same reads anyway. `protectedAccessViolation` admits a path
inside any declared root, read from the bound workflow document. The PLM profile
`zensu-plm-readonly-v1` shares the widening, because its `readOnlyViolation` runs the same
function; PR D pins it.

**Widening the root check alone would be a hole.** That function applies three independent
checks: root containment, the protected-path check against `protectedRoots`, and the traversal
check for Grep and Glob. Its `protectedRoots` set carries exactly one project-scoped entry,
`path.join(trusted.projectRoot, '.zensu')`. Relax the root check to the union and leave that
set alone, and a reviewer may read another repository's `.zensu/state/` — workflow documents,
edit-landing receipts, reviewer-denial notes. So every declared root's `.zensu` joins
`protectedRoots`, and the copy in `neutralViolation` as well, in PR B, before PR D widens the
reads (§9).

**The protection must not depend on the list.** A list that is absent, or one `readCodeRoots`
reduced to anchor-only, names no root, and an undeclared work tree nested under the anchor —
another live session's worktree included — is in no list at all, while the root check already
admits it because it lies inside the anchor. PR B therefore applies the `.zensu` segment rule,
which today guards only the Grep and Glob pattern fields, to the spelled and the canonical form
of every path a reviewer, the PLM profile or a neutral subagent names below the anchor,
whatever the list says, and below every declared root, so a direct read of such a `.zensu` is
refused. §10
pins both negatives: a reviewer is admitted into a code root's source and still refused that
root's `.zensu`, and a nested `.zensu` stays refused with the list absent and with a list that
fails a string rule. Outside the anchor the protection follows the list, because a reviewer
reaches a sibling root only through it; a neutral subagent, which no root check confines, keeps
the reach into an undeclared sibling's `.zensu` it has into every other repository's today.

**The Grep/Glob pattern rule needs no change, and a root is searched like the anchor.** A path
input already accepts an absolute value, which the root check then judges. The traversal check
refuses a search root that contains a protected directory or lies inside one, which is why the
anchor is searched through a subdirectory other than `.zensu` and never through its top. Once
every declared root's `.zensu` is protected, the same holds for each root: a reviewer searches a
code root through one of its subdirectories, and `searchRemedy` lists those subdirectories of
every declared root beside the anchor's (PR D). The pattern fields keep refusing an absolute
pattern, a `..` segment and a `.zensu` segment. A search rooted above a nested work tree whose
`.zensu` is in no protected set still reaches that `.zensu`, because the traversal check knows
only the entries of `protectedRoots`; §11 names that residual.

The pre-materialized packet the 2026-09-20 text weighed — paths plus extracted contents,
assembled anchor-side, so that the reviewer keeps today's confinement — is not needed, because
the read widening grants nothing the session lacks (§8).

### 7.3 No new chain shape

`chainShape` in `hooks/lib/chain-recovery-v1.js` reads only workflow flags — `active`,
`implComplete`, `chainDone`, `codeReviewDone`, the review ticket and round — and the rearm
receipt, never panel state; the fan-out happens in the main thread before the one ticketed
`zensu:code-reviewer` spawn. A perspective added inside the fan-out therefore needs no shape,
no `reviewRearm` change and no recovery-table row. A stage with durable progress of its own
between convergence and the terminus would need all three, which is why the 2026-09-20 design
paid for a shape and this one does not.

### 7.4 A cheaper mechanical precursor

The Phase 6 Cross-Layer Value Flow Audit already contains a diff scan for newly
added field and payload literals. It is skipped wholesale in vanilla, but its two halves are not alike:
part (a) grades the plan's Cross-Layer table, which vanilla never populates,
while part (b) only scans the diff.

Part (b) is skipped for one reason only — it lives inside the same step as part
(a). Marking Phase 6 NOT complete is not itself disqualifying: the Precondition
Drift Audit does the same (`skills/tdd/references/audit.md:61`) and runs in vanilla
(`skills/tdd/references/modes.md:14`). What part (b) DOES inherit from §7.1's argument is
its remedy: its finding text asks for a paired characterization
(`skills/tdd/references/audit.md:67`), which is a test vanilla cannot be made to produce.
So making it vanilla-safe needs two edits, not one — downgrade it to warning
level as step 6c already is (`skills/tdd/references/audit.md:69`), AND reword the finding
so it reports the unpaired literal without demanding the pairing.

That change needs no chain shape, no `reviewRearm` change, no widened lease and no
minor release, and it would surface a cross-layer literal with no consumer inside a
single root today. It is a precursor to stage 3, not a substitute — it cannot see
across roots at all — but it is the first thing to build if a cross-root signal is
wanted before stage 2 exists.

## 8. Security considerations

The list is a declaration, not a capability grant; §6.1.1 records why the 2026-09-20 framing
no longer holds. This section states what a mistaken or injected list can and cannot do,
because that is the bound the redesign accepts.

**What the list widens.**

1. **Reviewer reads.** Reviewers may read inside every declared root. The main thread reads the
   same files without the list, and a reviewer's output returns to the main thread, so the
   widening gives a confined agent nothing the session lacks. A direct read of every `.zensu`
   below the anchor or in a declared root stays denied, as do the protected plugin files and
   the plugin-data stores (§7.2); a search rooted above an undeclared nested work tree still
   reaches that tree's `.zensu`, a named residual (§11).
2. **The opt-in Bash gate.** While `hooks.bashWriteGate` is `true`, rules (B) and (C) accept
   the declared roots. The gate is a convention nudge by its own documentation and judges
   nothing at its default; without the widening it would make a multi-root chain unusable for
   the operators who opted in.
3. **Where evidence is gathered.** The audit, the terminus, the full-suite gate and the
   acceptance freshness look where the list points. A list that omits a repository leaves that
   repository's claims foreign, and stage 1 refuses those it can see: a claim into one under
   `$HOME` spelled by its absolute path reaches the run log as `~/…` and is not among them (the
   redactor gap of the status note above). A list that names the wrong
   repository grades its claims against that repository's change set, which is the accident the
   respell verdict and the review make visible rather than a silent green.

**What a wrong list cannot do.** It cannot name the operator's control surfaces, which §6.2
keeps out of every root at arming and `readCodeRoots` re-checks as strings on every read. A
list written by arming cannot take over another live session's anchor or another chain's root
(§6.2, exclusivity). It cannot widen any gate that confines the main thread, because none
confines a path at the default. And it cannot survive a hand edit into a shape a string rule
refuses, because `readCodeRoots` re-runs those rules on every read and falls back to
anchor-only. What a hand edit can still do is name another live session's tree, or reach a
control surface through a link, because only arming reads the filesystem and the live
sessions; while `hooks.bashWriteGate` is `true` the opt-in gate then admits Bash writes there.
§11 names that residual.

**Executing another repository's configuration.** Every git call into a code root runs that
repository's configuration — an fsmonitor hook, an index refresh, a clean filter — and the Stop
probe (§6.3) makes that happen on turn ends, with no tool call and no permission prompt. Every
git call into a code root therefore carries the read-only prefix of §6.2 —
`--no-optional-locks`, `-c core.fsmonitor=false` and `-c diff.autoRefreshIndex=false`, as
measured for `skills/session-trail/scripts/trail.mjs` — and the environment scrub. That
includes the audit's per-claim `check-ignore`, which lacks the prefix today, and rule (A)'s
`tracked()` probe, which lacks both (§6.3). A clean filter still runs under all
three, and no git flag stops it. That is a named bound (§11), the same one session-trail
carries for another session's worktree.

The requirements that still hold, restated for the redesign:

1. The list is written only at arming and stays constant for the life of the generation.
2. It is never read from an inherited or a command environment. A hook hands it to the code
   that needs it, and the opt-in Bash gate's parser receives it on stdin (§6.3).
3. Every entry passes §6.2 before it is admitted anywhere, and the rules a string comparison
   decides again on every read.
4. An entry that fails validation refuses the arming rather than being skipped.

### 8.1 Intent is out of scope, and the carrier says so

**The workflow document carries a declaration, not a capability.** `validateWorkflowState` is
shape-only: the module carries no keyed integrity check, so rewriting one field and leaving the
rest verbatim validates. The document is writable from inside the session, through a shell
redirect into `<anchor>/.zensu/state/` that no gate covers. A model that wants a
different list can therefore write one, and it can equally rewrite the receipt, the run log or
the workflow flags those same files carry. The list is held to the bar of the files around it:
it bounds accidents, not intent.

**Why that bar is accepted here.** The 2026-09-20 analysis already showed that no carrier was
intent-proof without a gate that does not exist. The Session Control record does not
authenticate its own contents either: `validateContext` checks the schema pair, a fixed list of
required fields and that `source_revision` equals `runtime_digest`, and that digest covers the
executing plugin tree, not the record's fields. Even the sealed design therefore rested
entirely on the records directory being unwritable by the session, and sealing the list alone
would have made one field intent-resistant inside a chain whose other evidence is not. An
operator who needs intent resistance needs it for the whole evidence spine, which is a
different design (§6.1.1, "strict evidence").

**`vanilla` is now a valid precedent.** The 2026-09-20 text rejected it because the list was to
be the first field read out of the workflow document that grants a capability. It grants none
any longer (§8), so a prose control is proportionate here, as it is for `vanilla`.

The existing inline escapes (`ZENSU_BASH_WRITE_GATE=off`, `ZENSU_EDIT_LANDING_GATE=off`) are
unchanged and keep landing their bypass-ledger entries. Nothing here adds a new escape.

## 9. Versioning

Under the runtime-lineage rule in `CLAUDE.md`, while the plugin is at major `0` the minor is the
breaking axis. `codeRoots` is a workflow-state field, the exact-key check of `readCodeRoots` is
a new strict key set, and refusing every root's `.zensu` and a direct read of every `.zensu`
below the anchor makes existing denies refuse more, so stage 2 is a `minor`, all of it paid in PR B. PRs C to E
change no strict key set: evidence records keep deriving their root from `cwd`, a code root's CI
snapshot is a file of its own with `SNAPSHOT_KEYS` unchanged (§6.3), the packet's `code_roots`
field is optional, the receipt keeps `edit-landing-v2`, and the `crossrepo` perspective needs no
chain shape (§7.3). Stage 1 added no field and was a `patch`.

**Delivery: five pull requests, one release.**

| PR | Scope | Class |
|---|---|---|
| A | This revision: the specification, its two companion pages, their consistency pin and the two rule files that pointed at the superseded design. | `patch` |
| B | Foundation: the `code-roots-v1` module and its leaf `git-read-only-v1`, arming, the workflow-state field, the audit, the change-set verbs, the union count in the terminus and the Stop probe, the protected `.zensu` of every root and below the anchor, the opt-in Bash gate and the doctor row. | `minor` |
| C | Evidence per root: the full suite and its close step, CI deferral and acceptance freshness. | `patch` |
| D | Review side and session-trail: the packet, reviewer and PLM reads, `crossrepo` with its resume and checklist lines, finding verification, the findings ledger, external review, self-review, persona activation and `gitState` per root. | `patch` |
| E | Enable: flip `CODE_ROOTS_ENABLED`, add the arming success cases, and document the feature for the skills, the plan template and the operator. | `patch` |

They land in that order, because C and D share lines in the review-chain reference, the
post-review directive, the self-review skill and `zensu-log.sh`, and D moves citations this
document carries. Until E flips `CODE_ROOTS_ENABLED` in `code-roots-v1`, `--tdd-begin
--code-root` refuses with "multi-repo chains are not enabled in this build", and `readCodeRoots`
answers anchor-only for every document, a hand-written list included. B, C and D test their
consumers against fixture documents that carry `codeRoots`, with the switch flipped in a fixture
copy of the plugin tree or injected into the module's unit tests, never through an environment
variable a session could set. A release cut between two of them therefore ships nothing
`--tdd-begin` can arm and nothing a consumer reads, even though this document describes the
design. The set ships as one `minor`.

## 10. Test obligations

### Stage 1

- The terminus accepts a receipt recording `clean: true` and refuses every other
  state, asserted as four cases in one test: `clean: false`, the field absent,
  unparseable JSON, and an unknown `schema`. The existing suite has no case where
  a receipt exists but does not record success, and the absent-field case is the
  one a two-valued implementation would silently accept.
- A clean anchor WITH a logged claim is gated; a clean anchor WITHOUT one is not —
  asserted in the SAME test, so the exemption boundary cannot drift one-sided. The
  test also fixes which log lines count as a claim, including whether an empty file
  list after the colon counts.
- A claim resolving outside the audited root fails the audit and the failure names
  the foreign root; an in-root claim still passes.
- The aliasing negative from §5: a relative claim naming a path that also exists
  dirty in the anchor must NOT grade as landed once the label exists, and is
  documented as ungradeable before it.
- The `/zensu:doctor` topology row renders when claims were logged against a
  non-anchor root, and not otherwise.

**Where those obligations are pinned, now that stage 1 is behavior.**
`tests/structure/test-tdd-complete-receipt-gate.sh` carries the verdict cases
(`D1`-`D7`, including the absent-field one and both accepted schema versions) and the
claim-armed scope with its exemption in ONE section (`Z1`-`Z6`, which also fixes what
counts as a claim and pins the disclosure when the run log cannot be read).
`tests/structure/test-edit-landing-audit.sh` carries the foreign-root verdict and the
in-root control (`X1`-`X5`), the aliasing negative as CURRENT behaviour (`X6`) and the
read-only inventory (the `V` family, whose write-mode refusal and its positive control
are what the doctor row's read-only contract rests on). `tests/structure/test-doctor.sh`
carries the topology row and its negatives (the `P1tp` family). Both are named as FAMILIES
rather than as ranges: an endpoint is a hand-maintained numeral wearing a range's clothes,
and both of these were appended past inside the change that wrote them. Two bounds ship with them and are not
closed by stage 1: a relative claim naming a sibling repository's file still grades
against the anchor (one into a work tree nested under the anchor is placed and
reported), and the claim-armed scope needs either `--plan` or a receipt to locate the run log — the
flag-free recovery spelling keeps the pre-stage-1 zero-change exemption.

### Stage 2

Per pull request, so that each one carries its own pins (§9).

**PR B — foundation.**

- The truth table of §6.2, one case per rejection reason: the anchor itself, an ancestor of
  the anchor, a filesystem root, a path inside a work tree that is not its top, roots that
  contain each other, `$HOME` itself and an ancestor of it, `~/.claude`, the plugin root or the
  plugin data as the root, above it or below it, a marketplace clone under `~/.claude/plugins`
  included, an overlap with another live session's work-tree top or with a root another chain
  declared while anchored outside it, a live-session answer either reader cannot verify, a
  root a durable Autopilot run
  holds, each forbidden character, a case-folded duplicate on darwin, the count bound, a
  malformed or one-letter label, an anchor entry named `@<label>`, and a `--code-root-baseline`
  commit that is not an ancestor of the root's HEAD. The positive cases are a worktree nested
  under the anchor, a symlinked sibling, a root below `$HOME`, and a native win32 root stored in
  its forward-slash drive form.
- `readCodeRoots` falls back to anchor-only, and says so, for a hand-edited document whose list
  breaks a rule a string comparison decides — an unknown or missing entry key, a control-surface
  location, a forbidden character — while the core still accepts the document, so no hook fails
  closed; and it answers anchor-only for every document while `CODE_ROOTS_ENABLED` is false. The
  use-time choice of §6.2 is pinned as current behaviour: a root replaced by a symlink after
  arming is followed, so changing that is deliberate.
- A single-root chain is byte-identical to a post-stage-1 chain. Its document carries no
  `codeRoots` key at all, so a document written before stage 2 reads as single-root and stays
  adoptable across the `minor` boundary. The mirror case: a document that carries `codeRoots`
  validates, and a new begin replaces or deletes the list. One case per reset site of §6.1: the
  three shell resets and `resetDeferredReviewState` delete the list, and the chain reset and the
  `deferred-review-transfer` draft keep it.
- The audit grades an `@<label>/` claim in its root, landed and not landed, and a claim in root
  B that never landed fails the audit while the anchor and root A are clean. A claim that
  resolves into a declared root under another spelling grades `UNVERIFIED (respell)` with the
  exact spelling, a claim the run-log writer redacted to `~/…` included; an undeclared foreign
  root keeps the stage-1 verdict; a git fault in a code root names that root and writes no
  receipt. The aliasing negative of §5 passes for an `@<label>/` claim. A root whose claimed
  work was committed before it was declared, re-armed with `--code-root-baseline`, counts those
  commits and lands those claims.
- Parity: one fixture repository, enumerated by the module and by the audit's shell recipe,
  yields the same set, an unborn HEAD and a mid-run commit included; counted by the module and
  by `_zensu_unqualified_change_count`, its uncommitted part yields the same number, a file
  ignored only by the global excludes file included.
- The union count: an unborn code root holding new files makes the union non-zero while the
  anchor answers `unknown`; a change committed since the baseline counts; a failing root makes
  the union `unavailable`; a non-ignored worktree nested under the anchor, with every root clean,
  gives a union of `0` and no `<dir>/` line in `--change-set`. `zensu_impl_stop_nudge` sees a
  change in a code root while the anchor is clean, and the Stop hook's zero-change texts name
  the union.
- Every git call into a code root carries the read-only prefix and the scrub, the audit's
  per-claim `check-ignore` and rule (A)'s `tracked()` probe included, pinned with an fsmonitor
  hook and an index mtime in the fixture, the way session-trail pins it.
- Rule (B) and rule (C) allow inside every union member and still deny outside all of them while
  the gate is on. The temp carve-out must NOT stay unchanged: `TEMP_SAFE` filters only against
  the anchor today, so a temp entry containing a code root but not the anchor would silently
  exempt that whole root with no bypass-ledger entry. Pin that it rejects an entry containing
  ANY union member. The parser takes the union from its stdin frame alone: a root named in the
  session's environment reaches no invocation, and no invocation inherits an earlier one's roots.
- A reviewer, the PLM profile and a neutral subagent are refused every declared root's `.zensu`
  and a `.zensu` nested below the anchor, the latter with the list absent and with a list that
  fails a string rule as well; the Edit gate's state-file hardening refuses every root's
  `.zensu/state`, and a nested root under a directory named `test` does not turn its files into
  test paths.
- `--tdd-begin --code-root` refuses while `CODE_ROOTS_ENABLED` is false.
- The doctor row lists the declared roots and still warns about an undeclared foreign one.
- The status literal of the three documents moves to
  `stages 2 and 3 are REDESIGNED, NOT ENABLED`, together with X7 of
  `tests/structure/test-multi-repo-doc-consistency.sh`, because merged dark code is no longer
  unbuilt.

**PR C — evidence per root.**

- `--evidence-run --root <label>` runs in that root's top and its record derives that root. An
  edit in one root after its green run makes that root stale and no other, and a nested root's
  run is no longer fingerprinted together with the anchor.
- The gate requires a green record or a CI-deferral verdict for every changed root, exempts an
  unchanged root with a disclosure line, and refuses a red, stale or missing record in any
  changed root. Records written before the change stay valid. A CI-deferred code root's snapshot
  is a file of its own that validates against `SNAPSHOT_KEYS` unchanged.
- The close step that `CLOSE_SUITE_STEP` and `CLOSE_PASS_SUITE_CI` render names one run per
  changed root under both runners, a mixed ladder included: the anchor on CI with a code root
  run locally, and the reverse.
- A code root's own configuration contributes `evidence.fullSuiteCommand` and the runner keys
  only.
- An edit in a code root makes an acceptance record stale.

**PR D — review side and session-trail.**

- A reviewer reads in a declared root, is refused an undeclared one and the declared root's
  `.zensu`. A search rooted at a declared root's top meets the traversal deny, a search through
  one of its subdirectories is admitted, and `searchRemedy` lists those subdirectories. The PLM
  profile reads a declared root and is refused its `.zensu`.
- `crossrepo` spawns with `--multi-root` and prints nothing without it, also on a lean
  re-review, and labels are stripped before a path is classified. The resume directive names it
  for a chain with code roots while T60 and T61 keep pinning the single-root panels, and both
  reviewer contracts carry its checklist line.
- A packet without `code_roots` is valid and has no code roots.
- A finding cited by an absolute path inside a declared root survives finding verification under
  its `@<label>/` spelling, and a ledger anchor into a code root without the label is refused.
- External review answers `reason=multi-root` at the import, at `--stage` and at `--tree`,
  persona activation never matches a labeled path, and self-review enumerates through
  `--change-set`.
- `trail.mjs` renders per-root git state, and the resume line still names the anchor.

**PR E — enable.**

- Arming with two roots succeeds and writes the field, and one whole chain over an anchor and two
  roots — a worktree nested under the anchor and a symlinked sibling — is run live to its
  terminus once.
- `templates/tdd-plan.md` gains the `## Code roots` table with labels only and its authoring
  rule names it, `skills/tdd/references/planning.md` tells the model to fill it with exactly the
  labels `--code-roots` prints, and a structure test pins the table and the rule.
- The status literal of the three documents moves from `stages 2 and 3 are REDESIGNED, NOT ENABLED`
  to `stages 2 and 3 are IMPLEMENTED`, together with X7 of
  `tests/structure/test-multi-repo-doc-consistency.sh`.

### Stage 3

Folded into stage 2: the `crossrepo` perspective is a PR D obligation, and no chain-shape,
`reviewRearm` or lease case exists any longer (§7.3).

## 11. Open questions

The redesign of 2026-10-21 answers the questions the 2026-09-20 text left open. They are kept
with their answers, because the answer is what a later reader needs and deleting a question
hides that it was ever open.

1. **What carries `codeRoots[]` from the operator to arming, such that the model cannot author
   it?** ANSWERED 2026-09-20 with the sealed pair of §6.1.1, SUPERSEDED 2026-10-21: the model
   authors the list, arming validates it, and the threat model of §8 bounds what a wrong list can
   do. The premise of the question — that a list the model names is a confinement the model can
   leave — no longer holds once the list widens no boundary the session keeps.
2. **Is the workflow document a sound carrier for a capability at all?** ANSWERED: no, and it
   no longer carries one. It carries a declaration held to the bar of the files around it (§8.1).
3. **Does `protectedRoots` travel with the union, or does a pre-materialized packet remove the
   seam?** ANSWERED 2026-10-21: it travels — every declared root's `.zensu` joins it, for
   reviewers, the PLM profile and neutral subagents alike, and a direct read of a `.zensu`
   below the anchor is refused whatever the list says (§7.2) — and no packet is needed.
4. **What happens when two sessions declare overlapping roots?** ANSWERED at arming: the
   exclusivity rule of §6.2 refuses a root whose work-tree top overlaps another live session's
   recorded root or another live chain's declared root. Named residuals: a plain session started
   later inside a declared root is not refused at its own SessionStart, and the chain then counts
   that session's edits as its own changes, which the review and the audit surface rather than
   hide; a list edited by hand after arming is not checked against other sessions again
   (§6.2); and a re-anchor into another chain's declared root is not refused, because
   `performReanchor` consults live sessions' working directories, recorded roots and keep
   anchors, not declared roots.
5. **The Grep/Glob pattern rule for a cross-root reviewer.** ANSWERED: unchanged. An absolute path
   input to a subdirectory of the root selects the tree, a root's top is refused as a search root
   as the anchor's top is, and the pattern fields keep refusing an absolute pattern (§7.2).
6. **Which root does `${CLAUDE_PROJECT_DIR:-.}` name for the audit default in a multi-root
   topology?** ANSWERED: still the anchor, and the skill passes `--project` explicitly anyway. The
   audit learns the code roots from the session's workflow document, never from that variable
   (§6.3).
7. **May a code root be nested under the anchor, or be a worktree of the anchor's own
   repository?** ANSWERED: yes to both, as long as it is its own work-tree top (§6.2); the field
   case of 2026-10-20 is exactly a set of worktrees nested under an orchestrator anchor. The
   Autopilot interplay measured on 2026-09-20 against `mayHoldWorkspace` in
   `hooks/lib/zensu-autopilot-state.sh`, whose containment runs in BOTH directions, stays as it
   was and stays fail-closed:

   - **Siblings do not collide.** With a durable run recorded on
     `<anchor>/.claude/worktrees/a`, the occupancy read answers *free* for a
     sibling worktree `b`, and *held* for `a` itself.
   - **Parent and child collide, in both directions.** That same run answers
     *held* for the anchor. A run recorded on the anchor answers *held* for every
     worktree beneath it, and `autopilot_begin_standalone_tdd` inside one of them
     is refused with rc 4.
   - **The tree scoping of `release` is weaker in a nested topology than in the
     flat one it was designed against.** With the anchor's owner made stale, a
     caller standing in a nested code root released the anchor's run (rc 0)
     instead of meeting the out-of-tree refusal (exit 6), because the same
     bidirectional containment qualifies a nested tree.
     `skills/autopilot-release/SKILL.md` already states that exit 6 is an accident
     guard and not an authorization boundary, so this follows the shipped contract
     rather than breaking it. It is named here because a multi-root design must
     not read exit 6 as confinement of one root's reach.

   A multi-repo Autopilot run is out of scope, and §6.2 refuses a root that a durable run
   holds, so the nested topology needs no carve-out in the predicate.
8. **Does `code_roots` on the Session Control record cost a `SCHEMA_VERSION` bump?** MOOT: the
   redesign adds no field to the record (§6.1).

**Named bounds of the redesign**, recorded here so that none is mistaken for an oversight:

- A code-root file claimed WITHOUT its label still aliases to a same-named anchor file (§6.1),
  so the claim contract makes the label mandatory for code-root files.
- A clean filter of a code root still runs during `status` and `diff` (§8).
- An unchanged code root whose tests exercise a changed root is not re-run by the full-suite
  gate; the disclosure line names every exempted root (§6.3).
- `/zensu:implement` does not link code-root files to the tracked feature, and
  `/zensu:converge` audits the anchor only.
- Adding a root mid-chain means re-arming with the full list before implementation, which starts
  a new generation; a root whose work is already committed needs `--code-root-baseline` (§6.1).
  The plan's `## Code roots` table carries labels only, because a consuming repository commits
  its plans and may publish them, and it must name exactly the labels `--code-roots` prints.
- A review the Stop hook adopts from `--pending-review` starts single-root, because
  `tdd_seed_deferred_review` carries no list (§6.1).
- Self-review runs no `crossrepo` perspective; after the last review round its whole-change
  re-read is the only cross-root reading (§7).
- A list edited by hand after arming is held only to the rules a string comparison decides. It
  can name another live session's tree, or reach a control surface through a link, and while
  `hooks.bashWriteGate` is `true` the opt-in gate then admits Bash writes there (§6.2, §8).
- A search rooted above a nested work tree whose `.zensu` is in no protected set still reaches
  that `.zensu`; a direct read of it is refused (§7.2).
- Whether the host itself prompts when a reviewer reads a sibling root outside the session
  directory is unmeasured. PR B measures it; if it prompts, `additionalDirectories` becomes a
  documented prerequisite. Nested roots sit inside the session directory.
- Multi-repo Autopilot and pilot pull requests, a multi-root external-review import and ports to
  the other hosts are out of scope.

### Citations to re-verify

- RESOLVED 2026-10-21: the `--chain-done` refusal is no longer inferred from a comment. The four
  callers of the change count were read, and §6.3 names them by symbol.
- RESOLVED 2026-10-21: `chainShape` in `hooks/lib/chain-recovery-v1.js` was read, and §7.3 rests
  on it rather than on the conventions document.
