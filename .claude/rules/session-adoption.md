---
paths:
  - "hooks/lib/zensu-session-adopt.sh"
  - "hooks/lib/session-adopt-report-v1.js"
  - "hooks/lib/zensu-doctor-invocation.js"
  - "hooks/lib/review-evidence-sweep-v1.js"
  - "hooks/lib/zensu-safe-display-v1.js"
  - "skills/adopt-session/**"
  - "tests/structure/test-versioned-plugin-upgrade.sh"
  - "tests/structure/session-adopt-report-v1.test.js"
  - "tests/structure/review-evidence-sweep-v1.test.js"
---

# Adopting a Record Across a Lineage Break (`adoptableRecord` / `adoptContext`)

_Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

The lineage rule above judges DECLARED versions and cannot see whether the
persisted shapes actually moved. When they did not, its refusal wedges a session
the running code could read perfectly well — and every write channel is denied,
so the user cannot repair it. `adoptableRecord` / `adoptContext` in
`hooks/lib/session-control-core-v1.js` are the one explicit exit.

**The authorising axis is SCHEMA equality, not the version numbers, and that
gate closes itself.** `validateContext` already enforces the record's
`schema_version` and `validateWorkflowState` already enforces the workflow
document's `schema`, so a release that genuinely moves a persisted shape makes
one of the two unreadable and adoption declines with no new check to remember.
Do NOT replace either with an explicit version comparison — the self-closing
property is the whole design, and a hand-written check is the thing that gets
forgotten.

Six conditions are ALL required; seven refusal reasons name exactly which one
failed (condition 5 can fail as either `executing-runtime-unidentified` or
`executing-runtime-older`):
`record-unreadable`, `plugin-data-mismatch`,
`already-served`, `not-a-sibling-installation`, `executing-runtime-unidentified`,
`executing-runtime-older`, `workflow-schema-mismatch`. `plugin_data` and the
sibling bound are NOT relaxed here either — the latter is what keeps a
`--plugin-dir` checkout from adopting an installed session.

**There is deliberately NO condition on the CALLER's project root, and
`adoptableRecord` does not read `options.projectRoot` at all.** Such a condition makes
this repair unreachable in exactly the state it exists for. Two sources of
truth disagree about "the project": the record is minted from the SessionStart
**payload cwd** (`claude-session-control-v1.js`), while the adoption entry point is
handed **`CLAUDE_PROJECT_DIR`**, a literal the skill renders from the harness. A
fork whose cwd was a worktree records that worktree while the harness still reports
somewhere else — and `cd` cannot change `CLAUDE_PROJECT_DIR`, so a refusal on that condition
would name a remedy no one in that session can perform. Omitting it relaxes nothing: the anchor
is CARRIED from the record (`adoptContext` passes `verdict.context.project_root` to
`buildContext`), no write is located by the caller's value, and the bound stated in
the entry script's header — `readContext`, the sibling root, `plugin_data` — does not
include this comparison. It also keeps the module in step with itself:
`resolveHookSession` answers `projectRoot: context.project_root` under "The mutable
payload cwd is never a project authority", and such a condition would be the one place a
caller-supplied directory outranked the record. A record whose project root is GONE
is ADMITTED at condition 1 — see the paragraph below, which states that rule and its
bound once. Consequently `zensu-session-adopt.sh` does not require
`CLAUDE_PROJECT_DIR`: rendering it through `zensu-host-path.sh`, which rejects a
non-directory, would exit on an unset or deleted value before printing any
report. The recognizer still ACCEPTS the assignment — the diagnostic reads it and the
two share one set — but the shipped skill command does NOT pass it: the recognizer
holds every PATH assignment in the prefix to a rooted literal value — `ZDOC_PLAYWRIGHT_TOOLS`
is a Set-membership check, not a path one — so a harness
that rendered the placeholder empty would refuse the whole invocation over a
value nobody reads.

**Two invariants, both learned from the chain-recovery precedent:**

1. **No record field is ever added.** Provenance is a workflow `history` entry
   under the reserved phase `RUNTIME_ADOPTED`, protected in the same two guard sites as `CHAIN_RECOVERED` (`zensu-log.sh --phase`, which holds its
   own literal, and `tdd_write_phase` / `_tdd_write_phase_critical`, which delegate theirs to
   `_tdd_reserved_provenance`). A field would itself be the breaking bump this
   feature exists to survive, and would cost a `minor` — which would wedge every
   session then running.
2. **No bypass-ledger entry.** The ledger records gate ESCAPES so that everything
   under "Gates bypassed" is true. Adoption escapes no gate; it re-mints a
   record. Same rule, same reason, as `--chain-recover`.

The previous record is never overwritten — it is renamed to
`<key>.superseded-<recorded-version>.json` and stays readable, so "the record is
immutable" remains literally true. `created_at` is carried over.

**The gate channel is a SECOND recognized command, admitted on a DIFFERENT
argument.** `hooks/lib/zensu-doctor-invocation.js` admits the doctor's shape
because `zensu-doctor.sh` writes nothing. `zensu-session-adopt.sh` WRITES, so it
carries its own justification in its own header, and that header is what the
recognizer points at. Keep the recognized list at two; a third entry needs its
justification written down the same way, not a wave at either existing one.
Moving together: `RECOGNIZED` in the recognizer, `isRecognizedInvocation` (the
module main and `reviewer-capability-v1.js` both call it; `isDoctorInvocation`
stays the doctor-only predicate), and `zensu_doctor_allowed`'s contract comment.

**A SUPERSEDED installation that has been PRUNED from the plugin cache is its own
named state, `pruned-plugin-root`, and it is adoptable.** Without that state a pruned
root is a wedge: canonicalizing `context.plugin_root` unconditionally makes `readContext`
throw on an absent recorded root, `resolveIncompatibleRuntime` answers null, every gate
denies with the generic revalidation text, the doctor falls back to the `unbound` row
whose "no valid record" wording is false, `adoptableRecord` refuses `record-unreadable` —
and the Stop hook falls through to its unbounded block and LOOPS, in a session whose every
other channel is already denied. Measured on the maintainer's machine without this state:
the cache held three versions, 4101 of 7913 records named a pruned root, one
live session was wedged this way and twenty-two more were recorded on the next
two versions to be pruned.

**The reader is `readPrunedPluginRootContext`, and existence is the ONE waived
check — proven, never assumed.** `validateContext` and `readContextInternal` take
an `allowMissingPluginRoot` waiver (the twin of `allowMissingProjectRoot`; each has
exactly one opt-in caller) under which the digest re-measure and the manifest
re-read are SKIPPED — there is nothing left to measure. The reader re-applies the
shape half through `requireAbsentDirectoryPath` (control characters, absoluteness,
normalization), requires
the root's PARENT to be a real directory (a pruned installation leaves its cache
directory behind; a record naming a root under a directory that never existed is
not this state), and returns on a clean `lstat` ENOENT or on a retired remnant —
every other present root fails `still exists`.

**A retired remnant counts as pruned, because Claude Code's orphan cleanup does not
always remove the directory.** Measured on the maintainer's machine on 2026-10-20: the
0.21.1 and 0.22.0 cache directories each kept `.orphaned_at` plus leftovers
(`node_modules`, `.zensu`, `SECURITY.md`, empty skill directories) while
`.claude-plugin/` and `hooks/` were gone, and a live session minted by 0.21.1 answered
`record-unreadable`, with its Stop hook blocking the turn nine times in a row.
`retiredPluginRootState` is the one predicate: `lstat` says a real directory; the
host manifest path answers ENOENT; `.orphaned_at` reads through
`readRegularFileSnapshot` (O_NOFOLLOW, regular, single link, at most 13 bytes) and
matches `^[1-9][0-9]{12}$`. The eval provider's mode and mtime conditions are NOT
applied: a umask of 002 or a copy without timestamps would wedge real sessions, and
the marker proves the host's retirement signal, not authenticity. The bound is the
same as for an absent root: whoever can plant a marker and delete the manifest can
delete the directory, which this reader already admits, and the private records
directory stays the barrier. A remnant still carrying its manifest keeps refusing,
because a manifest-bearing tree whose digest disagrees is an integrity signal. Every
consumer reaches the remnant through `readPrunedPluginRootContext`, so the binder
modes, the deny scopes, the Stop release, the doctor's pruned row, the re-anchor
ladder and adoption need no change of their own.

**A `record-unreadable` refusal names its cause.** `recordReaderRefusals` runs the
four readers in ladder order, never throws, and returns one `{ reader, refusal }`
per reader with the core's `session-control-v1: ` prefix stripped
(`FAIL_PREFIX`). The adoption report renders one row per reader under the refusal
(`readerRefusalRows`, read behind a `typeof` guard), the doctor's unbound row points
at the report, and the hand-copied `record-unreadable` remedy in
`reviewer-capability-v1.js` and `zensu-session.sh` never claims the causes
cannot be told apart. The refusal object keeps its exact key set, which
`session-auto-adopt-v1.test.js` pins. **Version: `patch`** — one reader admits
strictly more, one read-only export is added, and no record field, strict key set,
hook, matcher, config key or attestation moves. **The cost, stated:** with the minting tree gone, `runtime_digest`
and `plugin_version` are shape-checked only and taken on the record's word. What
still binds the record: session hash, schema, principal profiles, `plugin_data`
equality, the recorded project root existing (or, in the combined state below, proven
absent), the sibling cache directory, and the workflow document's schema when it is reachable. That is why such a record is **adopted once — automatically at
the first hook contact, or by hand with `--confirm` — and never served** — serving stays
strict at every strict read site
(`resolveHookSession`, `currentClaudeSessionContext`, `zensu_resolve_project_dir`,
SessionStart resume/compact, SubagentStart), and the re-minted record is
re-verifiable again.

**One walker owns the ladder order.** `readContextLadder({ recordsDir, sessionId, host }, readers)`
walks `RECORD_READER_LADDER`, the table `recordReaderRefusals` maps over, and both take that one
request shape, which the private `recordReaderOptions` translates into the readers' own options. It
tries only the `RECORD_READERS` rungs its caller names, always in ladder order whatever order the
caller lists, stops at the first reader that admits the record and returns `{ reader, context }`, or
`null` when none does; it never throws. A request without a non-empty `host` reads nothing:
`recordReaderOptions` answers `null` for it, the walker then answers `null` and
`recordReaderRefusals` refuses every rung with `host must be a non-empty string`, so the two never
disagree about such a request. `validateContext` checks the host only when one is named, so a caller
that passed the readers' own `expectedHost` spelling would otherwise skip that check on every rung. Every caller maps the admitting reader to its own flags and refusals,
and names exactly its own rungs, so no site reads the record or measures a runtime digest more
often than those rungs require: condition 1 of `adoptableRecord` and `readRecord`
in `session-reanchor-v1.js` name all four; `restoreRootVerdict` names strict, orphaned-project-root
and orphaned-and-pruned; `resolvePrunedPluginRoot` names strict, pruned-plugin-root and
orphaned-and-pruned, because the orphan reader measures the digest of a present plugin root;
`resolveIncompatibleRuntime` names strict and orphaned-project-root. The two binder predicates name
each reader they accept and answer `null` for any other, so a rung added to their list without a
mapping stays outside the state they diagnose. Every rung is a relaxation, so
the list is an inclusion list: a new reader reaches only the callers that name it, and each of them
has to map it. The cases named for `readContextLadder`, and the case that counts the reads of the
restore verdict and of both binder predicates, sit beside the `recordReaderRefusals` cases in
`tests/session-control/session-control-core-v1.test.js`. They count record reads and plugin-tree
opens, so a site that walks a rung outside its list fails there. **Version: `patch`** — one
read-only export, and no record or workflow field, strict key set, hook, matcher, config key or
attestation moves.

**Disjoint from `incompatible-runtime` by construction, and blind to lineage on
purpose.** `resolvePrunedPluginRoot` requires the STRICT read to fail and the
relaxed read to succeed; the lineage predicate requires the strict read to succeed.
No consumer has to order the two, and the state is reachable under a compatible
lineage as well (three patch releases inside one minor while a session lives),
where the remedy is the same. The binder modes `pruned-plugin-root` /
`model-pruned-plugin-root` print the same two-field `recorded<TAB>executing` pair,
so every parser of that pair reads it unchanged — the parse sites are a GREP, stated in
the wire-format bullet below. **Sites that move together:**
the reader, the waiver and the helper in the core plus its exports;
`resolvePrunedPluginRoot` / `prunedPluginRootSession` and the mode pair in the
binder; `zensu_session_pruned_plugin_root` / `_model` and the `pruned-plugin-root`
scope of `zensu_emit_hook_session_deny` in `zensu-session.sh`; the pruned branch beside
the lineage branch, which lives ONCE — in `zensu_emit_named_bind_deny`, which all four
binding gates
(`pre-bash-zensu-gate.sh`, `pre-bash-source-write-gate.sh`,
`pre-write-secret-scan.sh`, `pre-edit-tdd-reminder.sh`; the source-write gate reaches it only
while `hooks.bashWriteGate` is `true`) call rather than spelling the
ladder themselves — and the self-worded FIFTH
denier in `reviewer-capability-v1.js` — five deniers, the same set as the lineage
state, which that file's own neighbouring comments already count as five; the FOURTH release arm in
`stop-chain-enforcer.sh` plus its block reason and final stderr, which count four
released states; the third probe in `zensu-doctor.sh` and the `pruned-plugin-root`
case of `bindingLine()`; `adoptableRecord`'s condition-1 ladder (strict → orphaned → pruned → orphaned-and-pruned),
which is one `readContextLadder` call naming all four rungs, its condition-3 skip, and the `prunedPluginRoot` field on the verdict and on the
`adoptContext` result; `PRUNED_NOTE` / `PRUNED_EXPLANATION` and the
`record-unreadable` remedy in `session-adopt-report-v1.js`; and the operator
accounts in `docs/session-control.md` §"Unbindable sessions",
`docs/build-workflow.md`'s Stop-binding paragraphs, `skills/doctor/SKILL.md`,
`skills/adopt-session/SKILL.md` — and the `stop-chain-enforcer.sh` row in
`docs/configuration.md`, which states the COUNT of released bind failures and must say
four, as the hook's own fallback does. `ADOPTION_REFUSALS` is unchanged — seven
values, so CONV-1 is untouched — and no persisted shape moved.

**Pins, and one thing Part D learned.** Part D (AC-D01…AC-D10) in
`tests/structure/test-versioned-plugin-upgrade.sh` replaced JUDGE-3, which pinned
the old boundary — do not restore it; the unit cases beside the lease-lock cases in
`tests/session-control/session-control-core-v1.test.js` drive the reader, the
helper and the ladder; `P1ad3`/`P1ad4` in `tests/structure/test-doctor.sh` pin the
row. In this state the bind fails inside the CORE, so the authoritative stderr
diagnostic is the raw `session-control-v1: context plugin root does not exist`
line rather than a binder-prefixed one, and Part D's gate helper tolerates exactly
that line where AC-C04's tolerates only the prefix. **The COMBINED state — project root
gone AND installation pruned — is adoptable.** Each single-root relaxed reader pins the
other's waiver off, so without a combined reader the record answers `record-unreadable`
and every gate denies. Condition 1 is
`strict → orphaned-project-root → pruned-plugin-root → orphaned-and-pruned`. The last
reader, `readOrphanedPrunedContext`, opts into both waivers and proves each absence through
its own test, so it waives nothing a single-root reader keeps; a retired remnant counts as
pruned there too. The verdict carries both flags, `adoptContext` re-mints around the absent
project root with provenance `no-workflow-document`, and the session lands in the ordinary
orphaned-project-root state. `restoreRootVerdict` and the re-anchor answer
`not-served-by-executing-runtime` for the record until the adoption, so the order is adopt
first, restore second, and the pruned deny scope, the gate's `PRUNED_ORPHAN_CLAUSE`, the Stop
hook's pruned release and the doctor's pruned row each say so, because the pruned predicate
cannot tell whether the project root still exists. **Version: `patch`** —
no record or workflow field, no strict key set, no hook added, removed or renamed,
no matcher change, no config key, no attestation change; every change relaxes a
deny or names a state, and the new argv modes are a call convention inside one
installation.

**A vanished recorded PROJECT root is ADMITTED at condition 1, and it is the only
disagreement that is.** Both ways the two sources of truth diverge in worktree
workflows are closed: having no condition on the caller's project root covers a cwd
that is a worktree while the harness reports elsewhere, and condition 1 reads
strictly first and falls back to `readOrphanedProjectRootContext` for a worktree later
REMOVED (`git worktree remove`, the documented cleanup in `skills/pr-team-review`
Phase E), where the strict read alone makes `readContext` throw and answer
`record-unreadable` while `/zensu:doctor` falls back to the `unbound` row. The fallback cannot widen: the orphan
reader waives exactly one check and REFUSES a root that still exists, so every other
disagreement throws in BOTH readers and still lands on `record-unreadable`. Nothing is
waived by admitting it — the workflow document lived under that root and is not reachable from this record,
the same argument that already relaxes a vanished root for a COMPATIBLE upgrade.

**That "nothing is waived" sentence is TRUE ONLY WHILE THE ROOT STAYS GONE, and the
gap is named here rather than left for the next reader to find.** The authorising axis
of adoption is SCHEMA equality, and `CLAUDE.md` calls that gate self-closing — a release
that moves a persisted shape makes the document unreadable and adoption declines with no
new check to remember. In THIS state it does not close: condition 6 is guarded by
`fs.existsSync(workflowFile)`, which is false for an absent root, so `readWorkflowState`
never runs and `workflow-schema-mismatch` is unreachable. The same predicate later in
`adoptContext` skips the `RUNTIME_ADOPTED` history entry, which invariant 1 names as the
design's ONLY provenance mechanism while invariant 2 forbids a bypass-ledger entry — so
an adoption here leaves the superseded record's filename as its only durable evidence.
Neither is a defect in the mechanism and neither is worth a control-flow change: what must
stay accurate is the CLAIM. The adoption report discloses in this branch that no workflow
document could be read, so the schema check was not performed and a document restored
later is not verified. Say "not evaluated", never "verified", and note the ORDER:
re-creating the directory BEFORE adopting is what lets condition 6 run at all.

**`readOrphanedProjectRootContext` applies THREE shape rules, and the third costs one value
class its relaxation.** Beside the unsafe-character test and `path.isAbsolute`,
`requireAbsentDirectoryPath` applies `path.resolve(value) !== value`. That reader backs
`orphanedProjectRootSession`, so a recorded `project_root` which is not a `path.resolve`
fixed point loses the relaxation entirely — the wedge this feature family exists to remove,
left in place for that one value class. The rule is kept on the read path deliberately: applying it only where
the value is written would move the refusal out of `adoptableRecord` into a throw inside
`adoptContext` and would break the AC-C14b row. Exposure is narrow because every root is
minted through `realpathSync.native`, whose POSIX output is normalized; the residual is a
win32 UNC share root, where `path.win32.resolve` appends a separator `realpathSync.native`
does not. That spelling is UNVERIFIED in both directions — no suite exercises it, so do
not record it as covered.

**A port drops its `incompatibleRuntimeSession` equivalent, named here because the roster
is what a port works from:** `hooks/lib/claude-hook-session-v1.js` neither defines nor
exports that predicate, so a port that keeps its own equivalent keeps a predicate nothing
calls.

`buildContext` takes `allowMissingProjectRoot` for the re-mint. It waives exactly the
existence check `validateContext` waives and re-applies that function's shape half
through a SHARED `requireAbsentDirectoryPath` — the orphan reader calls it too, so the
split rule has one implementation rather than two copies. No record field moves, so
invariant 1 above still holds and this stays a `patch`.

**Three things are load-bearing and easy to undo by accident.** First, the verdict
carries `orphanedProjectRoot` and `adoptContext` passes it through rather than
re-deriving it: asking the filesystem a second time would let a directory re-created
between the two reads turn a waived check into a canonicalized one. Second, the deleted
root must NOT be recreated — the provenance write is guarded by the workflow document's
own `existsSync`, so `mutateWorkflowState`, which mkdirs every missing component of
`<project>/.zensu/state`, is never reached; AC-C16 pins it. Third, the repair fixes the
LINEAGE and not the anchor: the adopted session lands in the ordinary
orphaned-project-root state, where a `zensu` CLI call, `Edit`, `Write` and `MultiEdit` still deny, and so does any Bash command the source-write gate can attribute as a write while that opt-in gate is on and no usable `CLAUDE_PROJECT_DIR` remains. The report says so before
and after `--confirm` and the doctor row says so too, because announcing an unqualified
success there sends the user into a deny they were just told was repaired.

**The DIAGNOSIS shares the fallback, and deliberately not through a fourth predicate.**
`resolveIncompatibleRuntime` takes the same strict-then-orphan fallback, so the combined
state is reported by the predicate every deny site already consults — which is what gives
all five the `incompatible-runtime` scope, whose text names `/zensu:adopt-session`,
instead of the generic "start a fresh session" that would contradict the doctor. Its
`recorded<TAB>executing` line stays TWO fields for the reason the wire-format bullet below
gives; the third fact travels on its own mode pair, `orphaned-incompatible-root` and
`model-orphaned-incompatible-root`. Do NOT relax `resolveOrphanedProjectRoot` to accept
an incompatible lineage instead: that would let an incompatible runtime SERVE a session
with no schema check and no provenance, which is what the lineage rule exists to prevent.
Re-anchoring the record to a live directory was also considered and refused — a session
may delete its own root, so a caller-named anchor would become a cross-project write
escape. That refusal covers the UNBOUNDED form and THIS state: the bounded same-repository
move that exists (`.claude/rules/session-reanchor.md`) requires the recorded root to EXIST,
so it refuses exactly the combined state this paragraph is about.

**That predicate covers two states, and that governs what the message surfaces enumerated below may say — FIVE entries, six if both doctor rows are counted separately, and that is the part
to re-check on every later edit.** `zensu_session_incompatible_runtime` is true for
two states that disagree about the one fact those surfaces assert: whether the workflow
document still exists. Anything that speaks about it must ask the third fact and branch —
`hooks/stop-chain-enforcer.sh` does, and its THREE releases say different things on purpose:
a deferral when the root is present, "not reachable from this record, and no later Stop can
enforce this chain while that directory is missing" when it is not, and a state-neutral one
claiming NEITHER when the probe could not answer. **The wording of that middle arm is
itself a rule, not a phrasing choice.** Its whole evidence base is one `ENOENT`, which a
MOVED or renamed root and an unmounted volume produce identically — so it is held to the
same standard the sibling orphan release 60 lines above it sets, and which that release's
own comment states: "not reachable", never "gone". The enforcement half must
also stay BOUNDED to while the directory is missing, which is what makes it true: re-create
the root and a later bind takes the deferral arm instead. The same standard governs every
mirror of it — `docs/session-control.md`, both doctor rows, the adoption report's
pre-confirm paragraph and its no-workflow-document NOTE, the two SKILL files
(`skills/doctor/SKILL.md`, `skills/adopt-session/SKILL.md`), and the two operator docs
(`docs/build-workflow.md` §"When the session binding itself cannot be resolved",
`docs/operations.md`'s combined-state troubleshooting row). Treat an unlisted surface
that says anything about the workflow document as unchecked, not as compliant, and keep
the skills named here rather than trusting a sweep to find them. **It
governs the POSITIVE half too**: the deferral arm's probe establishes
only that the anchor RESOLVED — nothing on that path opens the document — so that arm is
worded as reachability, never as contents. That third arm exists because the channel answers on three statuses — 0 with the
path, 3 for a live recorded root, 1 for an unavailable answer — and a caller that reads only
truthiness collapses the last two, which is precisely how a surface comes to assert a
workflow document that is gone. The others carry an unconditional clause instead, which is true in
both halves — unconditional about the root probe, while its Bash half is itself bounded to
the opt-in source-write gate being on with no usable `CLAUDE_PROJECT_DIR` left, because at the default nothing denies a Bash write there and a usable one has its writes judged against it instead: the deny scope in `zensu-session.sh`, the `.*` capability gate's own JS deny in
`reviewer-capability-v1.js`, the COMBINED doctor row, and `skills/adopt-session/SKILL.md`.
The plain lineage row is the one exception and states its clause CONDITIONALLY, on
`ZDOC_BINDING_ROOT_UNKNOWN` — it is unconditionally true only that the row must not promise
more than the probe established. The doctor is therefore in BOTH lists deliberately: it
branches to pick a row, and the row it falls back to still carries the clause whenever the
probe could not answer, because the probe can fail. The rule this feature states about itself — what the
repair does not buy is stated wherever it is offered — is what those clauses satisfy; a
surface that offers `/zensu:adopt-session` without them is a defect, not a nicety.

**FOUR re-encodings move with this**, and they do NOT share one coverage statement.
The root-status pair states its own, because it is the only member with a real pin;
the store layout states its own, in its bullet below; the wire format and the
version-shape rule are UNCHECKED and say so. Read each bullet's own coverage sentence:

- the root-status pair `ZENSU_ROOT_STATE_GONE` / `ZENSU_ROOT_STATE_PRESENT`. The shell
  constants live in `hooks/lib/zensu-session.sh`, but that file is a MIRROR, not the
  definition: the values are exit statuses produced by `hooks/lib/claude-hook-session-v1.js`,
  which sets `process.exitCode = 3` as a bare literal, and nothing compares the two sides.
  Say "mirror", or a maintainer following this entry to "change the trichotomy" edits the
  shell constant and silently degrades both consumers to their hedged arms while AC-C19
  stays green — that pin covers the CONSUMERS' spellings only, and the producer is pinned
  separately by AC-C15f with its own bare `3`. TWO consumers reach the pair by DIFFERENT routes —
  and the route is the part a reader gets wrong. `stop-chain-enforcer.sh` sources the
  owner in its PARENT shell and compares against those names directly;
  `zensu-doctor.sh` sources it only inside command substitutions, where the name is out
  of scope and reading it under `set -u` aborts the whole diagnostic, so it copies the
  VALUES out in one subshell and compares against its own `ZDOC_ROOT_STATE_*`. One
  definition, two spellings, on purpose. There is deliberately no `_UNKNOWN` member: it
  is the residual, so nothing compares against it. AC-C19 in
  `tests/structure/test-versioned-plugin-upgrade.sh` pins both MEMBERS in both files, in
  each consumer's own spelling, plus a negative needle forbidding the defaulted
  `${ZDOC_ROOT_STATE_GONE:-0}` form. That negative needle is not decoration: such a
  default puts the literal back, and a half-pinned pair reads greener than an unpinned
  one. When adding a member, pin it in both files before
  writing any comment that says both are covered.
- the `recorded<TAB>executing` wire format — one producer
  (`claude-hook-session-v1.js`) and its shell parsers, which are a GREP and not a list:
  run `grep -rnF '##*$' hooks/` and judge every hit that is not a comment. The
  shell gates reach the pair through ONE site, `zensu_emit_named_bind_deny` in
  `zensu-session.sh`, which parses it once for the lineage arm and once for the pruned
  one; `zensu-doctor.sh` and `stop-chain-enforcer.sh` are the other two files that do.
  Every parser reads `${V##*$'\t'}` for the executing half, which takes the LAST
  field: adding a third field silently redirects every one of them rather than failing.
- the version-shape rule, spelled THREE times for three different hazards —
  `ADOPTION_SAFE_VERSION_RE` in `session-control-core-v1.js` (a version reaches a
  FILENAME), `ZENSU_SAFE_VERSION_RE` in `zensu-session.sh` (a version reaches a
  JSON string and the doctor report), and `SAFE_VERSION` / `safeVersion`
  in `reviewer-capability-v1.js` (a version reaches the `.*` gate's own JSON deny
  reason, which that gate spells itself rather than through
  `zensu_emit_hook_session_deny`). Identical ALTERNATION in all three, deliberate hand-copy;
  keep them in step. `safeVersion` in `session-auto-adopt-v1.js` — the adoption notice's
  version screen, which the `.*` gate, the SessionStart adapter and the binder's stderr
  line all consume — is NOT a fourth copy: it CONSUMES the core's exported
  `ADOPTION_SAFE_VERSION_RE` and substitutes `(unreadable)`, so it is a further
  substitution SITE on the first member, not a further spelling.
  A FOURTH spelling of the same alternation lives OUTSIDE production,
  in `tests/structure/test-versioned-plugin-upgrade.sh`'s `AC-C20b` precondition, which
  re-spells it to decide whether its shared fixture still fails the shape. It holds
  nothing in lockstep and is not a member of the three — but a widening that leaves it
  behind makes that row refuse its own fixture, so it belongs on this roster and is named
  here rather than left for a grep to turn up. The CONSEQUENCE deliberately differs:
  `ADOPTION_SAFE_VERSION_RE` performs no substitution at all —
  a failing version REFUSES the adoption (`EXECUTING_UNIDENTIFIED`) — while the
  other two substitute `(unreadable)` and keep rendering. Same rule, three members,
  two outcomes. A count that moves without its enumeration is the drift this
  bullet exists to prevent — state the base or the count means nothing.

  **Coverage, per member and NOT to be confused with the `UNCHECKED` above.** TWO of the
  three members have an executed BEHAVIOURAL case in
  `tests/structure/test-versioned-plugin-upgrade.sh`: `AC-C19b` drives
  `ZENSU_SAFE_VERSION_RE` in both slots, and `AC-C20b` drives `SAFE_VERSION`/`safeVersion`
  through `pre-reviewer-capability-gate.sh`.

  **`ADOPTION_SAFE_VERSION_RE` is the exception: `AC-C09` does not drive its REFUSAL, and
  cannot.** What `AC-C09` establishes is that an installation declaring no usable version is
  refused, and it would establish exactly that with this member deleted:
  `parseRuntimeVersion` re-tests BOTH versions in the very next statement — the shape
  guard sits immediately above the `// Condition 5` comment and the two calls are that
  condition's first statements, so state the ADJACENCY and never an ordinal — and returns
  the
  IDENTICAL `ADOPTION_REFUSALS.EXECUTING_UNIDENTIFIED`, while `RUNTIME_VERSION_RE` is a
  strict SUBSET of the shape guard — an `N.N.N` whose parts are at most nine digits each
  is at most 29 characters of digits and dots and always satisfies it — so everything the
  guard refuses the parse refuses anyway. The non-string arm is covered too, by the
  `typeof` line and NOT by `exec`: `parseRuntimeVersion`
  opens with `typeof value !== 'string'` and returns `null` on the line BEFORE `exec`, so
  `exec` is never reached with a non-string at all, and coercion does not imply no match
  (`RUNTIME_VERSION_RE.exec(['0.19.0'])` coerces and DOES match). That `typeof` line is
  the only guard on the recorded version at that point, so deleting it removes that guard. MEASURED, not
  argued: with the whole `ADOPTION_SAFE_VERSION_RE` condition removed from
  `adoptableRecord` and committed, every `AC-C09` row still passed and the suite stayed
  green.

  **Redundant, and RETAINED — say both.** The redundancy is
  CONTINGENT: `verdict.recorded` is `context.plugin_version`, condition 5's parse ran on
  that same value above the single `ok: true` return, and a successful parse means the
  string IS `N.N.N`. So while that ordering holds, the value that reaches
  `<key>.superseded-<recorded-version>.json` is digits and dots, and the guard is defence
  in depth rather than the thing keeping a traversal sequence out of that filename. Move
  the parse below the return, or
  put a value there that the parse never saw, and the guard becomes load-bearing again
  with nothing announcing it. **The redundancy does NOT transfer to the two twins.**
  `ZENSU_SAFE_VERSION_RE` and `SAFE_VERSION` have no parser above them at all; they
  substitute rather than refuse, and deleting either lets a malformed version reach a
  rendered string directly. Treat this member as SOURCE-PINNABLE ONLY until a case exists
  that fails without it,
  and never claim `AC-C09` covers it on the strength of a green suite — a green suite is
  exactly what deleting it produces.

  That is per-member coverage only — the lead-in's
  `UNCHECKED` is about the CROSS-COPY lockstep pin, which still does not exist: NO check
  compares the three alternations against each other, so a one-sided widening still
  ships silently. **State that as the property and NEVER as a grep result:** the
  constant NAMES occur under `tests/` as prose in census comments, and prose is not a
  comparison. Do NOT amend `UNCHECKED` on the
  strength of this paragraph; the two
  claims are about different things, and conflating them would assert a pin the tree
  does not have. TWO further `(unreadable)` substitution SITES sit outside this
  three-member rule census and are uncovered: `hooks/stop-chain-enforcer.sh`, which
  sets BOTH slots when EITHER fails — a blanket rule, unlike the per-slot members
  above — and `safeVersion(lineage.recorded)` in `reviewer-capability-v1.js`, whose
  refusing direction needs an install tampered BEFORE the record is minted.
  `zensu-doctor.sh` is NOT among them: it consumes `ZENSU_SAFE_VERSION_RE` from the
  sourced owner and DROPS the pair rather than substituting, and `AC-C02` already
  covers its accepting direction.

  **A THIRD KIND of site is outside that count entirely, and it is the one the census
  shape cannot see: a branch that applies NO bound of its own.** `reviewer-capability-v1.js`
  emits `immutable context revalidation failed: ${error.message}` unfiltered, so an
  UNBOUNDED manifest-controlled value can reach a user-facing deny reason through a
  sibling branch that never consults the rule. It is not a substitution site, which is
  why counting substitutions misses it — and it is a different value CLASS from the three
  members, which hold VERSION strings: name it as manifest-controlled, never as "a value
  the three-member rule exists to hold to a shape".

  **State the bound on the message this can carry, or the gap reads as a wider hole
  than it is.** The thrower is
  `localManifestEntry` — in `session-control-core-v1.js`, NOT in the gate file above it —
  and its two messages differ: `${label} escapes plugin root` carries no path at all, and
  `${label} is missing: ${candidate}` carries one only AFTER `isInside(pluginRoot,
  candidate)` has passed, so that path is already proven to be under the plugin root.
  What is genuinely unbounded is the CATCH: nothing filters `error.message`, so any other
  throw on that path renders whole. Whether the catch is reachable from this thrower was
  NOT traced — say unverified, not unreachable. Named in a comment beside `AC-C20b` in
  `tests/structure/test-versioned-plugin-upgrade.sh` and in this entry.
- the review-evidence store layout, plus the ownership predicate, `LEASE_ID_RE` and
  `MAX_RECORD_BYTES` that `review-evidence-lease-v1.js` owns, which the sweep in
  `hooks/lib/review-evidence-sweep-v1.js` consumes from that owner rather than copying.
  The sweep lives outside the core because a core -> lease CALL cycles (that module
  requires the binder, which requires this core), while requiring the owner from the
  sweep is acyclic. `review-evidence-lease-v1.js` exports `LEASE_ID_RE`,
  `MAX_RECORD_BYTES`, `REVIEW_EVIDENCE_SEGMENTS`, a `leaseRecordIsOwned` predicate
  and `withLock`, and the sweep consumes those five.

  **One copy deliberately SURVIVES.** `privateEnough` in the sweep reproduces
  `ensurePrivateDirectory`'s
  mode/uid pair verbatim, because the two do different things with the same
  predicate: the owner REPAIRS with a chmod, this one may only LOOK. It is a
  read-only twin, not a consumed export — do not "align" them, and do not read "the
  sweep consumes those five" as covering it. The owner's pair lives in
  `assertPrivateDirectory`, which `ensurePrivateDirectory` runs after its chmod and the
  lock-free `leaseProgress` reader runs without one; `privateEnough` answers a boolean
  on an `lstat` it already holds, so the pair is spelled twice.

  **The cost:** the sweep is an EIGHTH host obligation,
  not part of the cross-host core half. `adoptContext` does not sweep at all
  — the adoption ENTRY POINT calls it after the record swap — so a port that takes
  only the core delta gets an adoption that never sweeps and leaves every superseded
  lease wedging the store. What the separate module buys: the function is exported and
  driven by `tests/structure/review-evidence-sweep-v1.test.js`, so its refusal arms cost
  a temp directory each instead of a full synthetic install plus a session
  lifecycle, and three return shapes the shell layer cannot reach are ordinary
  cases.

  The source `lstat`'s ENOENT branch is the silent one: it cannot tell "no
  lease was ever minted" from a layout that moved, so a layout change still makes
  the sweep a SILENT no-op. That is bounded rather than open — the layout is one
  exported constant both sides read — but it is not closed.

**Port-relevant.** The core half is `adoptableRecord` / `adoptContext` /
`executingPluginVersion` / `adoptionWorkflowStatePath` plus `ADOPTION_REFUSALS`, in
the cross-host `session-control-core-v1.js` — and also condition 1's
strict-then-orphan-then-pruned-then-combined ladder,
`readContextLadder` with its `RECORD_READER_LADDER` table and the `recordReaderOptions`
translation it shares with `recordReaderRefusals`, through which every ladder caller of
both halves walks, `readPrunedPluginRootContext`, `readOrphanedPrunedContext` with `requireOrphanedProjectRoot` and
`requirePrunedPluginRoot`, the `allowMissingPluginRoot` waiver beside it,
`requireAbsentDirectoryPath`, and `buildContext`'s SECOND parameter. That last one is the trap: a port that takes only the
enumerated core half has `adoptContext` passing a second argument to a `buildContext` that
ignores it, so `canonicalDirectory` runs on an absent path and adoption THROWS in exactly
the state the feature was written for. **`hooks/lib/zensu-safe-display-v1.js` joins
the core half**, and it is the one entry a port is likeliest to skip because it looks
cosmetic: it owns `safeDisplayValue(value, followedBy)` — the `label : value` pair-forgery
guard plus the positive letter/number/mark allowlist — it requires NOTHING, not even a node
builtin, and both report renderers consume it. **The SECOND parameter is part of the
obligation and is the easiest half to drop.** It carries what the caller will render
immediately after the value; only the POSITIONAL rules see the join, because the allowlist
judges which characters the VALUE may contain and the caller's marker is not the value's
business; and a caller's appended marker must carry ONE space, or the double-space rule
fires on every appended render and folds the disclosure exactly when it is being disclosed.
A port that implements the one-argument description gets a function that silently ignores
its second argument — unlike the `buildContext` second-parameter trap this roster already
names, which at least throws. The doctor renderer's `foldPath` is a THIRD member beside
`foldSlot` and `parentheticalWriter`: it carries the fold to the prose rows, and a port that
copies the other two re-ships the raw-interpolation defect. It is also the one deliberate
exception to the no-parentheses rule below — a prose row supplies no call-site parentheses,
so `foldPath` returns a pre-parenthesized string while `foldSlot` must not. **ONE rule, deliberately.**
A port that adds a weaker sibling rule, or houses the rule in a feature command's module
with requires of its own, re-creates a display rule in two implementations, with a load
chain behind it, inside the one tool whose job is to speak in a damaged installation.
**The two consumers require it DIFFERENTLY,
and that asymmetry is load-bearing.** The adoption report takes it at top level; the
doctor renderer keeps its require LAZY and GUARDED, because that file deliberately
has no hard sibling require — `test-doctor.sh` P1mf builds a plugin root carrying
exactly the core and that renderer, to prove a missing `chain-recovery-v1.js`
degrades to one warning row rather than killing the report, and a top-level require
makes the renderer unloadable in that tree. Its fallback NAMES ITS REASON — the row prints
`(not rendered — the display-safety module could not be loaded)` — rather than
re-authoring the fold or dropping the value silently, because two other surfaces tell
the user "/zensu:doctor names the directory" unconditionally. **The fold returns a
RECORD, not a string** — `foldSlot` answers `{text, present, ok}`, where `present` is
about the INPUT (an empty value has never produced a parenthetical) and `ok` is about
the fold. Conflating the two in one returned string forces every call
site to fold TWICE to ask both questions and makes the load-failure SENTENCE the value.
**A fold failure is stated once per ROW, never once per slot.** `parentheticalWriter`
owns that: one writer per `bindingLine()` call, with a `stated` flag closed over it. It
is not cosmetic — with the sentence substituted per slot, the two-version row would render
`(record minted by <sentence>, executing <sentence>)`, which repeats the reason, buries
the fact that BOTH values are missing, and reads as though the sentence were a version;
the combined row has three slots and would say it three times. `P1mf2` in `test-doctor.sh`
pins the COUNT, on both remaining multi-slot bindings; `P1mf1` pins that the SINGLE-slot
rendering is unchanged. **The returned string must carry no parentheses of its own**,
and that is the part to keep: the call site wraps it again in `' (' + … + ')'`, so a
parenthesized fallback renders `… no longer exists ((not rendered — …)) — …`. A port
that re-authors the fold, collapses
`present` and `ok` back into one value, states the reason per slot, or returns a
pre-parenthesized string gets one of those defects back.
`discardSupersededLeases` is NOT
among them — it lives in `hooks/lib/review-evidence-sweep-v1.js` and is the EIGHTH
host obligation enumerated below. Note that
`adoptableRecord`'s `options.projectRoot` is INERT — accepted and never read —
so a port that takes only the core delta while its own entry
script requires and host-path-renders a project-dir variable still exits
before printing any report, which is the same wedge in a different place. The two
halves move together. The host
half is TEN separate obligations, and a port that takes only the core delta gets
`adoptContext` with no reachable caller and keeps the wedge: the entry script, the
recognizer's `RECOGNIZED` entry, the doctor branch and row, the Stop release, the
deny scope at every gate that denies in this state, the skill, — easy to miss
— a binder exporting a `privateRecordsDirectory` equivalent that applies the
symlink/alias/permission/ownership checks, because the entry script resolves the
records directory through it and never by hand-joining, **and a `validateSessionId`
equivalent**, which the report module now imports from the same binder and calls
before anything derived from that id locates a file — a port that takes the entry
script and the report against a binder without it gets a TypeError inside
`buildRequest`, which is literally the failure this roster's closing sentence names, EIGHTH the sweep itself
(`hooks/lib/review-evidence-sweep-v1.js`, plus the owner exports it consumes and the
entry point's call to it) — a port that skips it re-mints the record and leaves every
superseded lease wedging the store — NINTH the third-fact channel: the
`orphaned-incompatible-root` / `model-orphaned-incompatible-root` argv pair, both
shell wrappers, and the THREE-way exit status those wrappers carry, without which a
port gets a Stop hook telling a user whose worktree is gone that their chain state
survived, and TENTH the pruned-installation surface set: the binder mode pair, the
shell wrapper pair, the deny scope, the gate branches, the Stop arm and the doctor
probe, because a port that takes the reader alone gets a record it can adopt and no
surface that tells the user so. A port works from the list, not from the paragraph, so an
obligation named only in prose is an obligation that gets skipped. A port that
copies only the script gets a TypeError rendered as the wrong refusal.
`zensu-codex`, `zensu-kiro` and `zensu-antigravity` were NOT included in this change.

**Two spellings of one root, and only Windows can tell them apart.** The sweep decides
ownership with `record.plugin_root === executingPluginRoot`, a STRING compare. Leases carry
`binding.pluginRoot`, which reached the store through the core's `canonicalDirectory` —
`fs.realpathSync.native`. The adopt call site passes the record's own `plugin_root` and so
agrees by construction; the in-place REPAIR call site receives `ZADOPT_PLUGIN_ROOT`, which
`zensu-session-adopt.sh` renders through `zensu-host-path.sh`. On win32 that renderer emits a
drive-qualified FORWARD-slash path while the native spelling uses backslashes, so an
uncanonicalized compare inverts the selector and the repair sets aside the one live lease it
has to keep, with every POSIX shard green. `repairSweepRoot` therefore canonicalizes, falling
back to the rendered value rather than throwing, because that branch owes the caller a verdict.
Anything else that hands a root to this module owes it the same canonicalization.

**`ENOENT` is not proof of absence.** `lstat` on a path
whose ancestor is a FILE answers ENOTDIR on POSIX and ENOENT on win32, so read from the errno
alone a `review-evidence` file takes the "no store here" branch and `discardSupersededLeases`
reports a clean sweep over a store it never opened. `firstNonTraversableAncestor` therefore
re-derives the answer from the components instead of the errno; it follows links on purpose,
so a symlink to a real directory stays traversable and the POSIX verdict is unchanged. It is EXPORTED for the unit layer alone
— from a POSIX host the branch is unreachable through the public entry point, so without a
direct handle the check would have no executed case anywhere. Its `path.relative` bound is
another member of the hand-copied `within()` / `isInside()` family this file tracks.

**`test-versioned-plugin-upgrade.sh` grades the LAST COMMIT, not the working tree.**
It captures `git rev-parse HEAD` and its install fixture materializes both synthetic
roots with `git ls-tree`, so every behavioral row — and the copies of
`skills/adopt-session/SKILL.md` that AC-C04 and CONV-1 read — measures the committed
revision. An uncommitted change under `hooks/` or `skills/` is therefore reported
GREEN against the previous commit. Test-file edits
DO take effect immediately, and SEVERAL rows read the working tree — the unit
drivers (`zensu-doctor-invocation`, `session-control-lineage`, the lease sweep, the
adoption report and the automatic adopter; count them by grep), the three seam pins hoisted to the front of the file so a
Windows timeout cannot drop them, the committed-tree check beside them, the
lease-gap grep, and AC-013 — each labelled `WORKING TREE, not HEAD` in place. The
count is deliberately NOT written out, matching the rule the suite states about
itself: a hand-maintained number is exactly what a driven loop cannot catch when a
row is removed. Getting that set wrong is its own hazard, in the
opposite direction: a reader who believes an uncommitted constant is invisible will
misread a pin that in fact grades it immediately. Commit first, then measure.

**The Windows wall clock of `test-versioned-plugin-upgrade.sh` is measured, and the suite
runs FIRST on `windows-shard-7`.** The 29 all-green CI runs from 38309344682 to 38432294025
(2026-10-12 and 2026-10-13) measured it at 247-480 s against its 900000 ms cap, at most 53.3%
of it. Those runs include Part C2 and Part D. It runs first because `tests/run-profile.js`
grants a suite `Math.min(suite.timeoutMs, remaining)`, where `remaining` is the shard budget
minus everything already spent: run last on a shard that uses up to 1601 s of its 1800000 ms,
as `windows-shard-2` did, a slow run of this suite surfaces as a profile abort instead of its
own `TIMED_OUT`. Nothing runs before it on shard 7, so its own cap binds first. The shard
figures and the reason for the placement are in
`.claude/rules/windows-budget-best-solution-first.md`.

Read one run as one sample. The `stop-enforcer-self-review-routing` note in
`.claude/rules/host-refused-reviewer-spawn.md` records a 29% spread across green runs of
identical content on the same runner class. Re-measure after a change that adds process runs,
and do not raise the cap without a measurement: a raise without one trades a visible
`TIMED_OUT` for a silently truncated tail. Do not write a row count here either; the suite
reports its own total. The caveat lives here and NOT in the manifest:
`tests/run-profile.js`'s `SUITE_KEYS` rejects any key outside
`{id, runner, path, args, timeoutMs}` and throws at manifest load, which aborts EVERY Windows
shard before a single suite runs.

Operator-facing accounts that must move with it: `docs/session-control.md`
"Unbindable sessions", the binding rows in `skills/doctor/SKILL.md`, and
`skills/adopt-session/SKILL.md`. `tests/structure/test-versioned-plugin-upgrade.sh`
Part C pins the named state, the doctor row, the Stop release, the Bash-matcher
allowance with its ordinary-command discrimination, the refusal truth table, the
end-to-end repair, that the reserved phase cannot be minted through `--phase`, and
that the gate's deny leaves every Session Control record byte-identical.
