# Multi-Repo Chains — Anchor and Declared Code Roots

**Status: proposed, and stages 2 and 3 are BLOCKED.** Nothing in this repository
implements any part of it, and stage 2 must not be implemented until the carrier
question of §6.1.1 is answered and the carrier-integrity finding of §8.1 is
resolved. Every "today" statement below was read at the cited site in the
worktree that authored this document; every "would" statement is design, not
behavior.

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
`pre-bash-source-write-gate.sh:266-275` refuses an empty recorded root outright
rather than letting the parser fall back to the payload cwd. The STATE anchor is
therefore a trusted value derived from the immutable Session Control record.
Nothing in this proposal weakens that.

Two of the consumers named in §6.3 do NOT sit on that binding: the terminus
count reads `git -C "${CLAUDE_PROJECT_DIR:-.}"` (`hooks/lib/zensu-log.sh:1270`) and
the audit's default `--project` is `${CLAUDE_PROJECT_DIR:-.}`
(`hooks/lib/zensu-edit-landing.sh:36`) — both ambient, both with a `.` fallback.
Which root that variable names in a multi-root topology, and what the fallback
means when it is unset, is an open question (§11).

**The edit-landing audit already takes a `--project` argument** — it defaults to
`CLAUDE_PROJECT_DIR` (`hooks/lib/zensu-edit-landing.sh:36`, flag at `:49`) and
enumerates the change set with `git -C "$REPO_ROOT"` (`:69-93`). But its receipt
lands at `<--project>/.zensu/state/edit-landing-<session>.json` (`:266`), while
`--tdd-complete` looks for it beside the ANCHOR's workflow document
(`hooks/lib/zensu-log.sh:696`). Running the audit once per repository therefore
writes receipts nothing reads, and each run reports the other repository's claims
as not landed, so no run can exit 0.

**The receipt gate is scoped by the anchor's change count.**
`hooks/lib/zensu-log.sh:668-670` counts `git diff --name-only HEAD` plus untracked
files under a root resolved by `zensu_resolve_project_dir()` (`:615`) — not the
ambient variable, and with the git environment scrubbed — and skips the receipt
requirement entirely at zero. A clean orchestrator therefore closes the chain with
no receipt at all. The comment at `:585` states this mirrors the `--chain-done`
dirty-tree refusal; the `--chain-done` site itself was not read for this document.

**The write gate confines Bash writes, the edit gate does not confine paths.**
Rule (B) denies at `!within(projectRoot, p)`
(`hooks/lib/bash-source-write-parse.js:817`) and rule (C) at the same predicate
for git targets (`:863`), with `projectRoot` taken from the passed
`CLAUDE_PROJECT_DIR` (`:712`). `hooks/pre-edit-tdd-reminder.sh:137-164` resolves a
relative path against the project root and then classifies it only as `state`,
`zensu`, or `other` — an absolute path outside the root is not denied there. So
`Edit`/`Write` reach a sibling repository today and Bash writes do not. Neither of
the two other hooks on the `Bash` matcher confines a path to the project root, so
neither needs changing: `pre-bash-zensu-gate.sh` carries no project-root reference
at all, and `pre-write-secret-scan.sh:84` references one only through the
orphaned-root bind predicate, never as a path check.

**The reviewer is confined to the project root.**
`protectedAccessViolation` in `hooks/lib/reviewer-capability-v1.js:319` refuses any
reviewer path input outside the root with `file access must remain inside the
immutable project root`, and `:285-291` rejects an absolute Grep/Glob pattern, a
`..` segment, and a `.zensu` segment. A reviewer cannot read a sibling repository
even when the packet names its files.

**Claims are repo-root-relative.** `skills/tdd/SKILL.md:182, :185` requires every logged
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
because no reviewer ever sees two roots at once. **If cross-root findings are not
worth a schema field and two capability grants, this is the correct answer and the
rest of this document should not be built.**

**Stage 1 alone.** Cost: a patch. It closes the TERMINUS-level silent green for
every chain, multi-root or not, and leaves the topology unsupported but honest.
It does not close the aliasing case inside the audit (§5, item 3), which needs
the §6.1 root label. It is independently valuable and does not commit to
anything below.

**This proposal.** Cost: two minor releases, a widened write gate, a widened
reviewer confinement, a new chain shape, and a permanent second code path in four
consumers. It buys one thing the alternatives cannot: a review that sees the
relation between roots.

## 4. Terminology

**Anchor** — the session's single project root, resolved exactly as today.

**Code root** — an additional repository or worktree, declared at arming time,
that this chain may write to and must audit and review. Never carries state.

**Union** — the anchor plus every code root. The only new set.

**Satellite** — an informal synonym for a code root, used in the companion pages'
visuals where "code root" reads heavily. Never used normatively.

## 5. Stage 1 — Detect and refuse (patch, no schema change)

Stage 1 ships no multi-root capability. It removes the silent green.

1. **The terminus reads the receipt's verdict, not its existence.** This is the
   larger half of the silent green and the original draft of this section missed
   it. The gate is `if [ ! -f "$_el_receipt" ]` — an existence test — and the audit
   writes its receipt *before* its own exit status is produced, carrying `clean` as
   a field rather than as a precondition for writing. An audit that reports
   `EDIT NOT LANDED` and exits non-zero therefore still satisfies the gate today.
   Stage 1 must make `--tdd-complete` accept ONLY a receipt that parses and
   records `clean: true`, and refuse every other state — `clean: false`, the
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

**Item 3 is partial by construction, and saying so is part of stage 1.** Only an
*absolute* foreign claim can be recognised without the stage-2 label. A relative
claim from a code root (`src/foo.ts`) is textually indistinguishable from an anchor
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

## 6. Stage 2 — Declared code roots (minor) — BLOCKED, see §6.1.1 and §8.1

### 6.1 Data model

One new field in the workflow document, written once by `--tdd-begin` and never
again:

```text
codeRoots: [ { label: "<slug>", path: "<canonical absolute path>" }, … ]
```

`label` is the claim prefix. Claims become `label:path/relative/to/that/root`;
the anchor's own claims keep their current unprefixed spelling, so every existing
log line stays valid and stage 1's failure mode does not fire for single-root
chains.

Absent or empty means single-root, which every chain armed before this field
existed is. Reading code must treat absence as the current behavior, never as an
error.

### 6.1.1 Provenance of the list — UNRESOLVED

**No channel has been chosen, and every obvious candidate fails §8's constraint 2.**
This is the single largest hole in the proposal, and it is stated here rather than
implied because §8 authorises two capability grants on the strength of it.

- A `--code-root <path>` flag on `--tdd-begin` does not work: that command is
  composed and typed by the model, so its argument *is* model-authored text.
- A file in the anchor's project tree does not work: the model can write it, and no
  gate covers `.zensu/state/` against a shell redirect (§8).
- A value transcribed from a user prompt does not work either: the model performs
  the transcription.

What would work is a carrier the session cannot write — the immutable Session
Control record minted at SessionStart, a plugin-data sidecar written once outside
the project tree, or an interactive confirmation at arming that the model cannot
answer on the user's behalf. Choosing between those is design work this document
does not do. Until it is done, §8 constraint 2 is an intention rather than a
property, and stage 2 must not be implemented.

### 6.2 Validation, performed once at arming

This is a capability check, not path hygiene. A path is accepted only if all of the
following hold.

**Shape.** It canonicalizes, is a directory, and is the top level of a git work
tree.

**Position.** It is not the anchor, not a parent of the anchor, not a descendant
of the anchor, not a filesystem root, and neither contains nor is contained by
any other entry. Equality alone is not enough: with `/x` and `/x/y` both
declared, a file under `/x/y` has two valid claim spellings and §6.3's merged
receipt has no rule for which root grades it, while the write-gate widening is a
no-op for the nested member because `within(anchor, p)` already holds. §10 pins
containment in both directions.

**Location.** It does not contain the user's own control surfaces — not `$HOME`,
not any directory containing `.claude/` or the plugin-data directory, and not a
directory containing another project's `.zensu/`. §3 declares `~/.claude` changes a
non-goal; without this rule a home-directory code root would make
`~/.claude/settings.json` Bash-writable, which is a file the agent would then be
able to widen its own permissions in.

**Exclusivity.** It is not the recorded `project_root` of any other live Session
Control record. The records directory is enumerable, so this is checkable. Without
it, a declared root may be another running session's anchor — and rule (B)'s own
deny message names that exact harm, "corrupts another session's working tree — the
cross-session contamination this gate prevents". The damage would be silent and
symmetric: the other session's terminus change count would then count these files
as its own.

**Bound.** The list carries at most a small fixed number of entries, so a single
slug cannot grant a monorepo-sized surface.

**`label`** is unique and matches `^[a-z][a-z0-9-]{0,31}$`. Its justification is not
a filename — §6.3 specifies exactly ONE merged receipt, so a label never reaches
one. It is the claim prefix in the run log and the path prefix in the review packet,
both read by a model, and the pattern keeps it from carrying a separator or a
traversal segment into either.

**Re-validation is deliberately NOT performed at use time.** Canonicalizing once at
arming is a TOCTOU statement: a path can be replaced by a symlink after arming and
the gate would still compare against the stored canonical string. Re-canonicalizing
on every gate decision would close that, at a per-decision `realpath` cost on the
hot path of every Bash call. This document records the risk and the choice; §10
pins the accepted behavior so a change to it is deliberate.

A rejected entry refuses the arming with the reason. It is never silently
dropped: a dropped root is a root nothing audits.

### 6.3 The consumers that read the union

| Consumer | Change | Site |
|---|---|---|
| Edit-landing | Enumerate the union; resolve each claim through its label; write ONE merged receipt beside the anchor's workflow document, carrying a per-root verdict. | `hooks/lib/zensu-edit-landing.sh`, receipt path `:266` |
| Review packet | Enumerate `changed_files` per root and emit them label-prefixed. | `skills/tdd/SKILL.md` step 10.2 |
| Write gate | Rules (B) and (C) accept a path inside ANY union member. | `hooks/lib/bash-source-write-parse.js:817`, `:863` |
| Terminus | The zero-change scoping of `--tdd-complete` and `--chain-done` counts the union, and reads the receipt's verdict (§5). | `hooks/lib/zensu-log.sh:668-670` |
| Capability confinement (stage 3) | The reviewer's root check and its protected-root set both take the union. | `hooks/lib/reviewer-capability-v1.js:319`, `:300` |

The write gate receives the union the same way it receives the anchor today —
from the hook, which reads it from the trusted record and the workflow document,
never from the parser's own environment.

### 6.4 Session transferability

`/zensu:session-trail` keeps working unchanged, because a multi-root session still
has exactly one `cwd` and one transcript. What degrades is fidelity, and one part
of it degrades dangerously.

`gitState(cwd, full)` (`skills/session-trail/scripts/trail.mjs:2059`) takes a
single path, and that path is the anchor. In this topology the anchor is clean
while the changed files sit in the code roots, so a `takeover` brief would report
no uncommitted changes for a session with a dirty tree in two other repositories.
That is the same silent-green failure as §2, relocated into the handover path.

The fix costs no schema. `trail.mjs` has exactly one write channel, the lineage ledger
(`skills/session-trail/SKILL.md:75`); it may read the anchor's workflow document,
take `codeRoots`, and call `gitState` once per union member, rendering the results
grouped by label.

Two properties stay as they are, deliberately:

- **Resume happens in the anchor, always.** The printed
  `cd <cwd> && claude --resume <id>` (`trail.mjs:2741`) already lands there.
  Resuming inside a code root would present a different `CLAUDE_PROJECT_DIR` while
  the recorded `project_root` still EXISTS, and a present-but-different root is
  never relaxed — the orphaned relaxation requires the recorded path to be absent.
  So the session would not bind as orphaned; it would simply be denied. The resume
  line must never be rewritten to a code root, however plainly the work lives there.

  The `gitState` fix above has a cost worth naming rather than calling it free:
  `trail.mjs` may run outside any session and outside every hook, so teaching it to
  read `codeRoots` makes it a second consumer of the untrusted carrier of §6.1.1,
  running `git -C` in paths that carrier names. It costs no schema; it does widen
  who trusts that list.
- **Discovery stays anchor-scoped.** `list` keeps only transcript directories
  whose name starts with the slug of the repo's main checkout
  (`skills/session-trail/SKILL.md:253`), so from a code root's repository the
  session is reachable only via `--all` or from the anchor. This is pre-existing
  behavior that multi-repo makes more consequential; this proposal does not
  change it and must not claim to.

## 7. Stage 3 — Cross-repo review (minor) — BLOCKED, see §6.1.1 and §8.1

A single additional review stage between per-root convergence and the terminus.
Each root's review chain runs to convergence exactly as today. The new stage then
runs once, reads the union, and reports only findings that are about the relation
between roots: a field or payload key added in one root with no consumer in
another, a port and its client disagreeing on shape, version skew across a
published contract. Its findings feed the ordinary fix loop in the affected root.

**Reservation on record.** Two independent reviewers argued that this stage should
be cut or deferred: it addresses cross-root contract breaks, a failure mode §1 never
states and for which no observed instance is offered, at the highest price in the
proposal — a new chain shape, a strict-key-set change that must land first, a second
capability grant, and a `minor` release — while §11 concedes the eight-consumer
estimate was never read from code. The stage is kept because cross-root findings are
the one thing per-repository chains can never produce, which is the payoff the whole
proposal exists for. The objection is recorded rather than answered: if stage 2 ships
and no cross-root break is observed, this section should be revisited before it is
built.

A cheaper first move exists and is not blocked on any of it — see §7.4.

### 7.1 Why it is mode-independent

`skills/tdd/SKILL.md:195` lists the whole review chain — fan-out, judge second
pass, Finding Verification Gate, the consuming reviewer, the self-review terminus
— among what runs exactly as written in vanilla. A reviewer reports a finding; it
does not demand a Characterization test. That demand is precisely why the
Cross-Layer Value Flow Audit cannot run in vanilla (`:198`, `:201`), and
the new stage does not inherit it.

### 7.2 The capability lease

The reviewer confinement of §2 is not opened, it is redirected. The new agent's
lease carries the union, and `protectedAccessViolation` accepts a path inside a
leased root instead of the anchor alone. Per-root reviewers keep their present,
narrower confinement — the widening belongs to one agent type, not to the class.

**Redirecting the root check alone would be a hole, not a redirect.** That function
applies two independent rules. Beyond the project-root check, its `protectedRoots`
set carries exactly one project-scoped entry, `path.join(trusted.projectRoot,
'.zensu')`. Relax the root check to the union and leave that alone, and a cross-root
reviewer may read another repository's `.zensu/state/` — workflow documents,
edit-landing receipts, reviewer-denial notes, possibly another live session's. The
pattern rule below rejects a `.zensu` segment in a Grep/Glob *pattern*, not in a
direct path input, so it does not cover this. `protectedRoots` must therefore gain a
`.zensu` entry for EVERY union member in the same change, and §10 pins the negative:
a leased reviewer is admitted into a code root's source and still refused that code
root's `.zensu`.

An alternative that removes this whole seam: hand the cross-root stage a
pre-materialized packet — paths plus extracted contents, assembled anchor-side —
so the reviewer keeps today's confinement byte-for-byte. That would leave §8 with
one capability grant instead of two and delete the open question below. It is not
chosen here only because it moves the read cost onto the main thread; it should be
weighed again before stage 3 is built.

The Grep/Glob pattern rule at `reviewer-capability-v1.js:285-291` needs a
decision this document does not make: a cross-root reviewer needs to search more
than one tree, and the present rule forbids an absolute pattern. Either the tool
call carries an explicit root selector, or the pattern rule learns the same leased
set. Deciding this by widening the pattern rule to "absolute is fine" would
remove the guard for every reviewer, which is not acceptable.

### 7.3 The chain shape cost

A stage between convergence and the terminus is a new chain shape in
`classifyChain()`. Per the repository conventions in `CLAUDE.md`, that shape and
its supported next command travel with roughly eight consumers: `--chain-status`,
`--chain-recover`, the refusal-hint renderer, `stop-chain-enforcer.sh`, the
`/zensu:doctor` renderer, the ticket issuer, the rearm writer, and the
`reviewRearm` validator in `session-control-core-v1.js`. The validator is the one
that must land first: it rejects the ENTIRE workflow document on an unexpected key
set, which fails every hook closed — strictly worse than a wedged chain. These
consumers were taken from the conventions document; the `classifyChain()`
implementation itself was not read for this document.

### 7.4 A cheaper mechanical precursor

The Phase 6 Cross-Layer Value Flow Audit already contains a diff scan for newly
added field and payload literals. It is skipped wholesale in vanilla, but its two halves are not alike:
part (a) grades the plan's Cross-Layer table, which vanilla never populates,
while part (b) only scans the diff.

Part (b) is skipped for one reason only — it lives inside the same step as part
(a). Marking Phase 6 NOT complete is not itself disqualifying: the Precondition
Drift Audit does the same (`skills/tdd/SKILL.md:410`) and runs in vanilla
(`skills/tdd/SKILL.md:202`). What part (b) DOES inherit from §7.1's argument is
its remedy: its finding text asks for a paired characterization
(`skills/tdd/SKILL.md:416`), which is a test vanilla cannot be made to produce.
So making it vanilla-safe needs two edits, not one — downgrade it to warning
level as step 6c already is (`skills/tdd/SKILL.md:418`), AND reword the finding
so it reports the unpaired literal without demanding the pairing.

That change needs no chain shape, no `reviewRearm` change, no widened lease and no
minor release, and it would surface a cross-layer literal with no consumer inside a
single root today. It is a precursor to stage 3, not a substitute — it cannot see
across roots at all — but it is the first thing to build if a cross-root signal is
wanted before stage 2 exists.

## 8. Security considerations

Two of the changes are capability grants, not configuration.

Widening rule (B)/(C) lets Bash write outside the previously bound tree. Widening
the reviewer confinement lets a read-only agent read outside it. Both are
therefore bound to the same list, and that list must satisfy all of:

1. It is written once, at arming, and is immutable for the life of the chain.
2. It is never carried by an environment variable, and never derived from
   model-authored text: not from the plan body, not from a spec, not from a review
   comment. A root the model can name is a confinement the model can leave.
3. Every entry passes §6.2 before it is admitted anywhere.
4. An entry that fails validation refuses the arming rather than being skipped.

### 8.1 Constraint 2 is NOT satisfied by the design as written

Stating this plainly, because the rest of §8 reads as settled and is not.

**The workflow document is the wrong carrier for a capability.** `validateWorkflowState`
is shape-only — the module carries no keyed integrity check of any kind, so rewriting
one field and leaving the rest verbatim validates. And the document is writable from
inside the session: `bash-source-write-parse.js` contains no `.zensu` rule at all, so
a shell redirect into `<anchor>/.zensu/state/` is *inside* `projectRoot` and rule (B)
allows it, while the Edit gate returns early on an inactive chain and its `state`
class covers only the `Edit|Write|MultiEdit` matcher — its own comment says legitimate
state writes go through Bash, "which this hook never sees".

**`vanilla` is not a valid precedent.** That flag only relaxes TDD discipline, so a
prose control ("only the user changes the mode") is proportionate. `codeRoots[]` would
be the first field read out of that document that grants filesystem write outside the
project and read capability to a confined agent — the gate reading its own boundary
from a file the gated party can rewrite.

**Consequence.** Requirement 1 above cannot be enforced on this carrier, and §6.1.1
shows no channel currently satisfies requirement 2 either. Stage 2 must not be
implemented until a carrier the session cannot write is chosen, or an integrity
mechanism over `codeRoots[]` is specified as a stage-2 precondition.

The existing inline escapes (`ZENSU_BASH_WRITE_GATE=off`,
`ZENSU_EDIT_LANDING_GATE=off`) are unchanged and keep landing their bypass-ledger
entries. Nothing here adds a new escape.

## 9. Versioning

Under the runtime-lineage rule in `CLAUDE.md`, while the plugin is at major `0`
the minor is the breaking axis, and any change to the workflow-state schema or to
a strict key set forces a minor release. `codeRoots[]` is a schema field, and the
stage 3 chain shape touches the `reviewRearm` strict key set. Stage 2 and stage 3
are therefore each a `minor`. Stage 1 adds no field and is a `patch`.

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

### Stage 2

- The truth table of §6.2, one case per rejection reason: parent-of-anchor,
  filesystem root, duplicate, control-surface location, another live session's
  project root, over the count bound, malformed label.
- A merged receipt with a per-root verdict, and the negative: a claim in root B
  that never landed fails the audit while root A is clean.
- Rule (B) and rule (C) allow inside every union member and still deny outside all
  of them. The temp carve-out must NOT stay unchanged: `TEMP_SAFE` filters only
  against the anchor today, so a temp entry containing a code root but not the
  anchor would silently exempt that whole root with no bypass-ledger entry. Pin
  that it rejects an entry containing ANY union member.
- A chain armed with no `codeRoots` behaves byte-identically to a POST-STAGE-1
  chain. The baseline matters: stage 1 deliberately changes behavior for chains
  with no `codeRoots`, so read against pre-stage-1 `main` this pin would fail. Add
  the mirror case: a document that DOES carry `codeRoots` validates and arms.
- A chain armed on the pre-`codeRoots` schema is not adoptable by the
  post-`codeRoots` runtime — designed behavior, pinned so a future reader does not
  read the decline as a regression.
- The re-validation choice of §6.2 is pinned as CURRENT behavior, so changing it is
  deliberate.
- `trail.mjs` renders per-root git state, and the resume line still names the
  anchor.

### Stage 3

- The reviewer lease admits a leased root and still refuses an unleased one, AND is
  refused that leased root's `.zensu`.
- The new chain shape appears in the shape lattice, is documented in the recovery
  skill (an existing test already enforces that every emitted shape is documented),
  and the `reviewRearm` strict key set accepts a document carrying it. The validator
  case must land first: it fails the whole document closed.
- The cross-repo stage runs and reports findings in a chain armed vanilla, asserted
  against the frozen flag rather than the session marker.

## 11. Open questions

Ordered by what they can cost. Questions 1, 2 and 4 must be resolved before any
stage-2 line of code is written; question 3 belongs to stage 3 and must be
answered before that stage is built, which §7 defers. The rest are citations to
re-verify.

1. **What carries `codeRoots[]` from the operator to arming, such that the model
   cannot author it?** §6.1.1 shows every obvious channel failing. §8's authority
   for two capability grants rests on the answer.
2. **Is the workflow document a sound carrier for a capability at all**, given it
   has no integrity check and an open Bash write channel (§8.1)? If not, stage 2
   needs an integrity mechanism as a precondition.
3. **Does `protectedRoots` travel with the union** (§7.2), or does the pre-materialized
   packet remove the seam entirely?
4. **What happens when two sessions declare overlapping roots?** §6.2 now excludes a
   live recorded project root, but nothing re-checks it if a second session arms
   afterwards.
5. The Grep/Glob pattern rule for the cross-root reviewer (§7.2) is undecided.
6. Which root `${CLAUDE_PROJECT_DIR:-.}` names for the terminus count and the audit
   default in a multi-root topology, and what the `.` fallback means when it is
   unset (§2).
7. Whether a code root should be allowed to be a worktree of the anchor's own
   repository. Nothing above forbids it, and nothing above needs it — but it is no
   longer a free choice, because the per-workspace exclusion that landed with
   `feat(autopilot): scope durable runs per owner session and per workspace`
   answers it by accident. `mayHoldWorkspace` in
   `hooks/lib/zensu-autopilot-state.sh` is containment in BOTH directions, and
   three cases were measured against the shipped predicate rather than reasoned
   about:

   - **Siblings do not collide.** With a durable run recorded on
     `<anchor>/.claude/worktrees/a`, the occupancy read answers *free* for a
     sibling worktree `b`, and *held* for `a` itself. A union whose roots are
     siblings therefore needs nothing from this proposal that it does not already
     have.
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

   The direction is fail-CLOSED, so nothing unsafe follows from leaving it as it
   is: a nested union over-blocks, never under-blocks. What does follow is that
   the nested topology is unusable without an explicit exemption — an anchor's own
   chain cannot arm an inner standalone generation in one of its own code roots —
   and any such exemption must name the union. That is the same list §6.1.1 cannot
   yet source from a channel the session may not write, so answering question 7
   "yes" costs no carve-out in the predicate; it inherits the provenance problem
   Stage 2 is already blocked on.

### Citations to re-verify

- The `--chain-done` dirty-tree refusal was inferred from the comment at
  `hooks/lib/zensu-log.sh:673`; its own implementation must be read before §6.3's
  terminus row is implemented.
- `classifyChain()` was not read; the consumer roster in §7.3 comes from the
  conventions document and must be re-derived from the code.
