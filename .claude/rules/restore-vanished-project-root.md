---
paths:
  - "hooks/lib/session-control-core-v1.js"
  - "hooks/lib/session-adopt-report-v1.js"
  - "hooks/lib/zensu-session-adopt.sh"
  - "hooks/lib/zensu-session.sh"
  - "hooks/lib/zensu-safe-display-v1.js"
  - "hooks/lib/zensu-doctor-report.js"
  - "hooks/stop-chain-enforcer.sh"
  - "skills/adopt-session/**"
  - "tests/structure/test-restore-project-root.sh"
  - "tests/structure/restore-root-render-cases.test.js"
  - "tests/session-control/session-control-core-v1.test.js"
---

# Restoring a Vanished Recorded Project Root (`restoreRootVerdict` / `restoreWorkflowProjectRoot`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

**A THIRD wedge in this family, and the one most easily confused with the other two.**
§"Adopting a Record Across a Lineage Break" answers "this runtime may not SERVE the record".
§"Workflow-Baseline Repair" answers "it serves it fine and the workflow DOCUMENT is gone".
This one answers "it serves it fine and the DIRECTORY the record anchors is gone" — the
ordinary shape after `git worktree remove`, which `skills/session-trail/SKILL.md` measures at
**498 of 657** archived worktree-sessions. There `readContext` throws,
`readOrphanedProjectRootContext` succeeds, reads still work and every write denies.

**The destination is carried FROM the record and never from an argument, and that is the whole
safety argument.** `CLAUDE.md` records that re-anchoring a record to a CALLER-NAMED directory
was considered and REFUSED — a session may delete its own root, so a caller-named anchor would
be a cross-project write escape. Nothing here accepts one: the path is `context.project_root`,
so the anchor never MOVES and the source-write gate keeps comparing against exactly the root it
compared against before. Do NOT "generalize" this into a mode that takes a destination; that is
the refused design, not an extension of this one. State the bound as the script header does —
`CLAUDE_PLUGIN_DATA` is still a caller-supplied literal and the private records directory is
what bounds it — never as "every location is derived from the record".

**`restoreRootVerdict` is disjoint from `adoptableRecord` by CONSTRUCTION for two of the three
neighbouring states and by a CONJUNCT for the third**, and conflating those is the mistake this
paragraph exists to prevent. The strict read must FAIL and the orphan read must SUCCEED, which
excludes a healthy session and a pruned installation. A LINEAGE BREAK passes both reads —
`allowMissingProjectRoot` waives only the recorded root's existence — and is excluded one clause
later by `servesRecordedRuntime`. That is also why the remedy in the combined state is **adopt
first, restore second**, and why every surface offering it must say so.

**ONE COMPONENT AT A TIME, never `recursive: true`.** A recursive mkdir resolves intermediates
through ordinary path resolution, so a symlink planted at one between the ladder's check and the
write is FOLLOWED — re-opening the exact escape `restoreRootComponentLadder`'s realpath test
closes, and invisible to the leaf re-check because the leaf is still absent in that scenario. The
loop narrows the race rather than closing it: Node exposes no `mkdirat`. Mode is explicit
(`0o755`), not the ambient umask, because umask can only clear bits and the process cannot see
the one it inherited.

**Provenance is a reserved history phase, `PROJECT_ROOT_RESTORED`**, guarded in the same three
bodies as `CHAIN_RECOVERED` / `RUNTIME_ADOPTED` / `BASELINE_REBUILT` — `zensu-log.sh --phase`,
`tdd_write_phase`, `_tdd_write_phase_critical`. **No bypass-ledger entry**: it escapes no gate.
The entry counts what THIS run created, never what the verdict planned to create — and
when the race was lost after some of that work had landed, its reason additionally
carries `RESTORE_HISTORY_RACED_SUFFIX`, so one entry shape cannot stand for two
different outcomes.

**Moving together:** the `RESTORE_*` constants, `restoreRootRefusal`,
`isRestoreRootAlreadyPresent`, `restoreRootComponentLadder`, `restoreRootVerdict`,
`restoreWorkflowProjectRoot` and their exports in `session-control-core-v1.js`; `RESTORE_REMEDY`
/ `RESTORE_DISCLOSURE` / `RESTORE_TAMPER_NOTE` / `restoreNotRepairable` /
`restoreBaselineRows` and the THREE module-scope functions the renderer split into —
`renderRestoreVerdict`, which TAKES a verdict, `performRestore`, which owns the two
writes, and `renderRestoreOutcome`, which turns the outcome into lines — plus the
`ZADOPT_MODE` route in `session-adopt-report-v1.js`, where `main()` now resolves the
verdict itself and owns the exit code, so the renderers return `{text, code}` and
write no global. The retired single renderer was `renderRestoreRoot`; nothing in the
tree defines that name any more, so a roster naming it sends a reader nowhere; the two-literal argv parser and the five-class header in
`zensu-session-adopt.sh`; `RECOGNIZED.adopt.args` in `zensu-doctor-invocation.js`; the three
reserved-phase guard bodies; both binding rows in `zensu-doctor-report.js` PLUS the state row
this feature added there, `projectRootRestoredRow`, together with the `RESTORE_HISTORY_PHASE`
read that decides whether it can render at all and the `sharedWorkflowRead` it takes from its
sibling — and the whole provenance-slot family the hardening round added beneath both rows:
`provenanceSlot` (the writer that folds, CAPS and delimiter-checks one slot and returns a
RECORD rather than a string), `provenanceRendering` (the ROW's decision, which states a
suppression ONCE per row and renders a plugin-authored phrase rather than the empty string
a caller reads as "nothing was recorded"), `provenanceJunctionForges` (the two-character
seam window, which must never be widened to the assembled string — that reports every
honest `project-root-restored: …` as a forgery), `PROVENANCE_RENDER_MAX` with
`PROVENANCE_ELISION` (a NEW constant on purpose: `AUTOPILOT_RENDER_MAX` is hand-copied into
shell, so binding this cap to it would make a change here reach a command this file does not
own), `PROVENANCE_TIME_SUPPRESSED` / `PROVENANCE_REASON_SUPPRESSED`, and `parenthesizedPath`,
the second delimiter-bounded path renderer — `foldPath` cannot serve a call site that
supplies its own parentheses, because it returns a PRE-parenthesized sentence on a load
failure and the result is `((not rendered — …))` — say the ROW, never "both binding rows": that phrase predates this feature and a
maintainer matching on it edits neither the row nor its token — and the `P6s` family in
`tests/structure/test-doctor.sh` that grades it, named as a FAMILY because this file's own rule
is that a hand-maintained numeral goes stale on the next check added; the three gone-root
releases in `stop-chain-enforcer.sh`; **`restoreRootRealDirectory`** (the one EEXIST
discrimination, and an EXPORT, so a port obligation), **`restoreRootAlreadyPresentError`**
(the one builder for the benign race) and **`baselineProvenanceUnrecorded`** (the one
predicate for "the rebuild happened and its history entry did not", consumed by
`restoreBaselineRows`, `restoreProvenanceRows`, `renderBaselineNotes` and the SessionStart
self-heal in `claude-session-control-v1.js`. NAMED rather than counted, and the numeral is
gone on purpose: this roster has now been wrong in both directions about that one count —
it named two and pointed at THIS section for the third, and then it said three while
`restoreProvenanceRows` had already joined them. `R6i20` derives the set from the two
source files and requires every member to be named here, so a fifth consumer fails that
row rather than being counted by nobody. What they share is the
CONTRACT, not the count — and stating it as "the three" was itself the drift this paragraph
records, written two sentences after the sentence that says a fourth had already joined: each is THREE-VALUED, so a core that exports no predicate makes
every one of them DISCLOSE that the check could not be made rather than answer from a rule
of its own. Each carried a guarded fallback once; aligning those copies was not enough,
because a fallback ANSWERS where the core prescribes withholding and answers by comparing
the raw `provenance` value the core's own header forbids a consumer to compare. `R10c`
forbids the re-derivation by source, `R10g`/`R10g2` drive the withholding arm of the
SessionStart carrier, and a port that re-adds a fallback has re-created the divergence the
extraction removed); the deny texts in
`zensu-session.sh` — where the display-path bound is now the single
`zensu_safe_display_path`, which `hooks/stop-chain-enforcer.sh` CALLS rather than
re-spelling, because the two shell copies had already diverged in FAIL DIRECTION on a
retyped ceiling — and `reviewer-capability-v1.js`; and the **write-class enumeration, which is FIVE carriers and went
stale in two of them within this very change** — the adopt header, `zensu-doctor-invocation.js`,
`reviewer-capability-v1.js`'s recognized-command comment, `docs/session-control.md` and the
`docs/gates.md` intro. **Do not trust a numeral here — count by grep.** The sixth is RE-ATTRIBUTED below and
two further carriers were found, so the list that follows has three items and only two
of them are new: `zensu_doctor_invocation`'s own "five
classes" sentence in `zensu-session.sh` (NOT `zensu_doctor_allowed`, whose comment
carries no count at all — an entry that names the wrong symbol sends a maintainer
looking at the wrong function), the admission comment in
`hooks/pre-bash-source-write-gate.sh`, and the "at most `--confirm`" clause in
`hooks/pre-write-secret-scan.sh`, which is an ARGUMENT claim rather than a class
count and went stale for the same reason. Before changing the write classes, run
`grep -rnE 'classes|--confirm' hooks/ docs/ skills/ tests/` and judge every hit.
**`tests/` is in that list deliberately**: `R6c`/`R6d` in
`tests/structure/test-restore-project-root.sh` grep the literals `FIVE write classes`
and `THREE bounded exceptions`, so a maintainer who edits only the three code roots
turns a suite red with nothing naming it — the UNOBVIOUS-direction coupling this file
records for G12.

**Operator-facing accounts:** `skills/adopt-session/SKILL.md` (frontmatter, §"When to Use", the
`--restore-root` section), `skills/doctor/SKILL.md` — the two binding bullets AND the three
state bullets this feature added (the RE-CREATED row, its not-checked arm, and the frontmatter
`session state` clause, which reads as a complete inventory of the block and therefore goes
stale silently) — `docs/session-control.md` §"Unbindable sessions", `docs/gates.md`,
`docs/operations.md` and `docs/tdd-manager-workflow.md`. That bullet list is TIGHT: every other
bullet in the block follows its predecessor with no blank line, and the two blanks this feature
introduced were the only ones — one of them silently load-bearing for a slice terminator in
`test-doctor.sh`, which is why that slice now ends on the next bullet instead.

**The couplings here that fire in the UNOBVIOUS direction are stated as MEMBERS, never as
a count** — the paragraph opened "TWO" over three of them and then gained a fourth, which is
the drift this file records about its own rosters. They are `R13`, the `R12` family, `R13b`,
and the CLAUDE.md-grading `R6h`/`R6i` family — named as a FAMILY for the reason this section
states two paragraphs up about `P6s`, and because the numeric range that stood here once
ended seven rows short of the suite it claimed to enumerate; `R6i18` forbids the endpoint
form outright, so raising the number is not a way to make it green — of which `R6i5`
slices a DIFFERENT
feature's section (§"Adopting a Record Across a Lineage Break") so an edit to that port census
reddens a suite named for the project-root restore. Re-grep before trusting this list. All of
them take the shape §"Gate-Disable Prefixes"
records for G12 — an ordinary edit elsewhere reddens a suite named for the project-root
restore, and nothing points at it from the side that changes. `R13` in
`tests/structure/test-restore-project-root.sh` derives its file list from
`tests/SUITE-OVERVIEW.md` and compares every declared registration count against the file that
registers it, so adding or removing a `test()` in ANY driven `tests/structure/*.test.js`, or
reformatting that table, reddens this suite; when it was first derived rather than
hand-enumerated it found SEVEN stale counts at once. And the `R12` family grades COMMENT PROSE
inside `hooks/lib/session-control-core-v1.js` — the port roster, the benign-race builder's
comment placement, and the rule that neither carries a hand-maintained numeral — so rewording a
comment in the core reddens it too. `R13b` widens that direction again: it measures
`ls tests/structure/*.test.js` against `tests/SUITE-OVERVIEW.md`'s own rowless-file paragraph,
so ANY new unit file anywhere in the tree reddens a suite named for the project-root restore.

**Port-relevant, and the authoritative split lives at the export block rather than here.**
The core/host list for this feature is the comment above `RESTORE_ROOT_REFUSALS`'s export
in `hooks/lib/session-control-core-v1.js`; restating it here would create the second copy
this file warns about everywhere else. What belongs in THIS file is the pointer and the
one thing a port reads past: the numeral in that comment was wrong by one for a round
after `restoreRootRealDirectory` was added, which is why it now names no count at all.
The HOST half is the entry script, the recognizer's argv pair, the doctor row, the Stop
release, the deny scopes — including `zensu_safe_display_path`, which a port must place
where BOTH its emitter and its Stop hook can call it — and the operator accounts.

**Version: `patch`.** Walked entry by entry against §"Runtime Lineage": no schema field
(`PROJECT_ROOT_RESTORED` is a history VALUE), no strict key set, no hook added, removed or
renamed, no matcher change, no config key, no attestation change. The argument list of an
already-recognized command widened, which is NOT a member of the signed list — and the change
that added the whole second recognized WRITING command scored `patch` on the same reasoning.
Over-bumping costs this feature's own users: while major is `0` the minor is the breaking axis,
so a `minor` would make `servesRecordedRuntime` false for every in-flight session, and this
repair REQUIRES it.

**THE DESTINATION IS CARRIED FROM THE RECORD, AND THAT IS NOT THE SAME CLAIM AS BOUNDED.**
State both or a reader takes the first for the second. This is the first write class whose
destination is an ARBITRARY absolute path: `restoreRootComponentLadder` applies no containment
check of any kind — not `$HOME`, not a git repository, not excluding a child of the filesystem
root — and the private records directory bounds WHICH RECORD IS READ, never where the syscall
lands. The barrier paragraph in the adopt header was written for classes 1-4, whose
destinations sit inside `<plugin_data>` or inside the recorded project, so it does not cover
the class it was extended for. What IS bounded is the DEPTH: at most
`RESTORE_MAX_MISSING_COMPONENTS` components below a nearest-existing ancestor the ladder proved
real, canonical and link-free, each re-verified by realpath after it is created. A LOCATION
allowlist was weighed and REFUSED — `git worktree remove` leaves the parent in place, so a
`$HOME`-or-inside-a-git-repository rule would admit the ordinary case, but it also refuses
legitimate roots under `/opt`, `/srv` or `/Volumes` and this repository's own canonicalized
temp fixtures, and it is a policy invented at the boundary rather than derived from the record.
The barrier stays the records directory, which is what classes 1-4 rest on too — and what that
buys has to be stated PRECISELY, because "a principal able to author a record there already
holds the capability this write would grant" stood here and in the adopt header as an
overstatement. What authoring a record already confers is the CHOICE of destination: the path
comes from the record and from nowhere else, so this write adds no target a record author could
not already name. What it ADDS is the act of creating a directory outside the store, which
write access to the store does not itself perform. That residual is narrowed rather than
closed, by the depth bound above and by the ancestor-permission rule below. THREE
carriers say so — the adopt header, `RESTORE_DISCLOSURE` (which asserted the store's ownership
check as the bound outright), and `docs/gates.md` — and `R11a`/`R11b`/`R11c` pin all three.

**The nearest-existing ancestor is judged on WHO MAY WRITE IT, and that is its own refusal.**
Every other test on that component establishes WHAT it is — a real, canonical, link-free
directory — and none asks who else can change it, while the loop then plants a directory inside
it. Re-verifying each created component by realpath NARROWS the swap window and cannot close
it: Node exposes no `mkdirat`, so the name is resolved again on every syscall, and under an
ancestor a co-tenant may write that window is theirs to win. `restoreAncestorPermissionsSafe`
refuses an ancestor owned by neither the caller nor root, and one that group- or
other-writable without the sticky bit.

**THREE exported helpers carry this rule and a port needs all three; the roster named one
for a release.** `restoreAncestorPermissionsSafe` is the ANCESTOR rule above.
`restoreRootOwnerSafe` is the LEAF rule — the owner half ALONE — and it is a separate
predicate rather than a flag because the two questions differ: the recorded project root is
the DESTINATION this repair hands back, never a directory it plants a child inside, so the
swap window the write-bits half closes does not exist there. Reusing the ancestor rule at the
leaf refused the ordinary umask-002 worktree (0775, self-owned) and turned the BENIGN race
into `FAILED` / exit 1 — the defect the leaf predicate exists to remove. Three sites take the
leaf rule (the pre-loop ALREADY-RESTORED arm, the in-loop `leafNow` arm, and the `there` arm
when `component === verdict.projectRoot`); every other site takes the ancestor rule.
`restoreAncestorChainOffender` is the whole-chain walk, and its value is the TOPMOST offender
— it walks DOWN from `path.parse(dir).root` — so the renderer labels that row
`offending ancestor`, never `nearest existing`, which is what every OTHER producer of that
field carries. Its stat-failure arm fails OPEN and nothing else answers for it: the ladder
walks UP from the recorded root and stops at the nearest EXISTING component, so the ancestors
above it — exactly this walk's domain — are ones the ladder never stats. This roster is held by review rather than by a check,
for the reason the sticky paragraph above gives; `grep -n 'restoreRootOwnerSafe\|restoreAncestorChainOffender\|restoreAncestorPermissionsSafe' hooks/lib/session-control-core-v1.js`
is what settles whether it is complete. STICKY is a full exemption on purpose — `/tmp` is
writable by every user and sticky by design, and under it another user cannot rename or remove
an entry they do not own; without that exemption the repair would refuse every recorded root
under a temp directory, this repository's own fixtures included. **State what sticky buys and
no more.** It constrains `unlink` and `rename` of entries that ALREADY EXIST and says nothing
about CREATE, while every component this writer plants is one `verdict.missing` proved ABSENT
— so under a sticky ancestor a co-tenant can still win the race to the NAME, and what catches
that is the post-mkdir realpath re-verification, never this rule. This paragraph called such a swap
IMPOSSIBLE for a release, which the module's own comment beside
`restoreAncestorPermissionsSafe` already retracted in the same change set: a governing document
asserting a guarantee the code it governs denies is worse than no paragraph, because the code
comment is the one a reader checks last. Nothing pins this paragraph and nothing may: the root
conventions state that `CLAUDE.md` and `.claude/rules/` are guidance for agents rather than a
contract, and that behaviour is pinned in code and in `docs/`. The checks that once graded this
section were deleted for that reason. What survives is `R6i24`, which grades the OPERATOR
carrier — the write-bound paragraph in `docs/session-control.md` — and the module's own comment
beside `restoreAncestorPermissionsSafe`, which is where a reader checks the claim. It ABSTAINS where it cannot decide: win32 has no `process.getuid` and its mode bits
are not the access control, and a stat carrying no numeric `uid`/`mode` is the same case.
`RESTORE_ROOT_REFUSALS.UNSAFE_ANCESTOR_OWNERSHIP` is its OWN member rather than a cause folded
into `UNSAFE_ANCESTOR`: that one says the tree changed under the record and its remedy is to
inspect a link, this one says the tree is intact and its remedy is a `chmod`, so one wire value
carrying both would render the other half's remedy in every report that hit it. Moving with it:
the member, the helper, the `RESTORE_REMEDY_TABLE` entry keyed by member NAME, the refusal
enumerations in `docs/gates.md` and `skills/adopt-session/SKILL.md`, and the counts in `R7a`/`R7b`
— which are hand-maintained numerals, so an eighth member that does not reach them fails there
rather than silently. `R2j`/`R2j-control`/`R2j2` drive all three arms, and the whole block SKIPS
on win32 rather than asserting a rule that host does not have.

**THE CALLER IDENTITY IS NOT A CONJUNCT, and the route a reviewer named for exploiting that
is REFUSED — say both halves, because either one alone is misleading.** `restoreRootVerdict`
requires readable-as-orphan, `plugin_data` equality and `servesRecordedRuntime`, and nothing in
it compares `options.sessionId` against the session this process belongs to; `zensu-session-adopt.sh`
passes `CLAUDE_CODE_SESSION_ID` straight through. So the core carries no caller bind of its
own, and the protection is a BASH-CHANNEL gate rather than a check in the core. What refuses
the named shape — `CLAUDE_CODE_SESSION_ID=<foreign> CLAUDE_PLUGIN_DATA=<store> bash
.../zensu-session-adopt.sh --restore-root --confirm` from a healthy BOUND session, where the
PreToolUse recognizer's `ASSIGNMENTS` allowlist is never consulted — is `CONTROL_BINDINGS` in
`hooks/lib/bash-source-write-parse.js`, which lists `CLAUDE_CODE_SESSION_ID` and makes
`pre-bash-source-write-gate.sh` deny with `Blocked a Bash rebind of protected Session Control
input CLAUDE_CODE_SESSION_ID.` MEASURED, not argued: driving that command through the Bash
matcher in a bound session produced exactly that deny. Do NOT restate this as "the core binds
the caller", and do not delete the gate's entry on the strength of the conjunct list — the two
halves are what make the claim true together, and removing `CLAUDE_CODE_SESSION_ID` from
`CONTROL_BINDINGS` would re-open class 5 to a foreign record with nothing else standing in the
way. `R11f`/`R11g`/`R11g2` and their controls pin both clauses — NOT `R11d`/`R11e`,
which grade `zensu_safe_display_path` in an unrelated block and were cited here for a
release. A wrong pin id is worse than none: it reads as covered.

**AND THE SCOPE OF THAT REFUSAL IS NARROWER THAN THE PARAGRAPH ABOVE READS.** The gate
covers one SPELLING of one CHANNEL. `buildRequest` reads this module's own inputs from
`ZADOPT_PLUGIN_DATA`, `ZADOPT_SESSION_ID` and `ZADOPT_PLUGIN_ROOT`, and `main()` routes
on `ZADOPT_MODE` and `ZADOPT_CONFIRM` — and no `ZADOPT_*` name is in `CONTROL_BINDINGS`,
so a plain leading-assignment `ZADOPT_… node …/session-adopt-report-v1.js` needs no
quoting subtlety at all to pass `bindingFromAssignment`. A second gap is the WRAPPER
set: `WRAP` is `command builtin exec env sudo nohup nice time`, containing neither
`bash` nor `sh`, so `bash -c '<assignment> <command>'` makes `bash` token 0, the
leading-assignment loop exits immediately and no `export`/`unset` arm applies; `env` IS
covered. Both halves are DERIVED from source and neither was measured, unlike the
`CLAUDE_CODE_SESSION_ID` deny above, which was. What bounds the residual is that the
destination still comes from a record in a readable store and the write is at most
`RESTORE_MAX_MISSING_COMPONENTS` directories at mode 0755 — narrow, but not nothing.
Covering `ZADOPT_*` is its own change to `CONTROL_BINDINGS` and is NOT taken here.

**EEXIST is the ONE signal the mkdir primitive gives, and all three readings of it are decided
from EVIDENCE rather than from the component's POSITION.** Position alone got two of them
wrong. An INTERMEDIATE `EEXIST` was read as tamper — but the race the design is written for is
a `git worktree add` in another terminal, and git creates the whole chain at once, so the loop
meets it on an intermediate first and reported `FAILED … Run /zensu:doctor` for a session that
had just become completely healthy: the same wrong outcome the `ROOT_PRESENT` re-derivation was
added to prevent, one component up. And a LEAF `EEXIST` — plus the leaf `lstat` above the loop
— was read as the benign race for ANYTHING at that name, so one `ln -s /nonexistent <root>` or
a `touch` turned the fully wedged state into an exit-0 "ALREADY RESTORED" while `readContext`
still failed. The ladder is: the recorded root now real and canonical → benign race with
`created` CARRIED; else this component real and canonical and not the root → a SIBLING repair
got here first, so `continue` WITHOUT counting it, because the provenance entry counts what
this run performed; else refuse. `restoreRootRealDirectory` is the one discrimination and it is
EXPORTED, because the leaf arm sits directly below a re-derivation of the verdict and no
fixture can reach it. `realpathSync.native(x) === x` is the ladder's own whole-chain test:
equality proves transitively that nothing on the way to `x` is a link, which is why a real
leaf settles an intermediate's `EEXIST` whatever that intermediate is.

**TWO MECHANISMS REACH THE BENIGN RACE, and a reader who knows only the throw has half
the contract.** A run that lost the race having created NOTHING still throws, and
`isRestoreRootAlreadyPresent` classifies that error — the shape this section described
on its own for a release. A run that had already PLANTED components sets
`alreadyPresent`, BREAKS out of the loop, falls through to the baseline repair and
RETURNS, carrying that flag as a field of the result. It has to: every raced throw
fires above the provenance write, so the throw-only shape reported the count on stdout
while the workflow history — this feature's ONLY durable disclosure, there being no
bypass-ledger entry — recorded nothing and `/zensu:doctor` had nothing to read. The
consequence for a CALLER is that a successful return no longer means this run created
the recorded root: `performRestore` reads the field and maps it to the same `raced`
outcome the throw produces, and a caller that keys ALREADY RESTORED off the throw alone
announces a repair that did not happen. The consequence for a READER is
`RESTORE_HISTORY_RACED_SUFFIX`, `, completed by another run`, which the raced entry's
reason carries and an ordinary one must not: it is the only signal in the persisted
document that tells the two apart, which is why the `/zensu:doctor` row reads it from
the core rather than copying it. The suffix decides the PROVENANCE clause — whether the
row says another run finished the directory — and it deliberately no longer decides what
the row claims is IN there. **That half is a PRESENT-TENSE PROBE**, an `lstat` of
`<root>/.git` taken as the row renders, and the conditional shape it replaces was wrong in
BOTH directions rather than merely coarse: it keyed a claim about the filesystem on a token
in a document, so a planted stub somebody had since checked a worktree out into still read
EMPTY, while a raced entry whose directory really was empty was offered no `git worktree
add` at all. The probe answers three ways and each renders its own sentence — a repository
is present, none is, or the path could not be read — so a check that could not be made is
never an all-clear. A core that does not export the suffix still cannot tell a raced entry
from a planted one, and the row says THAT, as a missing check, while the probe's own
sentence renders beside it.

**A component SWAPPED after it was created is refused rather than traversed.** `mkdir(2)` does
not follow a symlink at the LAST component, so a planted name there fails `EEXIST` — but every
component above it resolves normally and a swap there is followed in silence. Each created
component is re-verified by realpath immediately afterwards, which is detection AFTER the fact
— the directory is already in the wrong place — but it converts a silent success report naming
the recorded path into a refusal. The swapped component is deliberately NOT pushed onto
`created`: the name resolves elsewhere, so listing it under the recorded spelling would be
false.

**`deps.mkdir` is a FILESYSTEM seam and deliberately not a verdict one.** The writer re-derives
its verdict, so a STATIC fixture cannot reach any post-verdict arm — planting a name before the
call only changes what the ladder computes. An injectable verdict would DELETE the TOCTOU
re-check the function exists to be; an injectable mkdir leaves every check in place and lets a
fake plant a name BETWEEN two iterations. It is defaulted, so every production call site is
unchanged. `R9a`-`R9e` drive the arms through it and `R9f`-`R9k` drive the discrimination
directly; `R9a` is also the first fixture anywhere to create MORE THAN ONE component, so the
loop, the `created` accumulation and the two report tails that count it finally have an
executed case.

**The benign race has ONE builder, and `R8o` pins that rather than the duplication.** It was
constructed verbatim at four sites while that row pinned
`grep -c 'code = RESTORE_ALREADY_PRESENT_CODE'` equal to 3 — the shape, not the property, and
the shape was already short by one. It now pins one tag site plus `R8o2` on the builder's
definition and its four callers, a count `R6i17` DERIVES from the core rather than reading it
out of this paragraph: it was stated three times here, was wrong in all three, and the core's
own comment said four throughout. The
failure arm also stopped using `fail()` as a builder through an intermediate `let failure`:
that shape read like ordinary flow, and if `fail()` ever stopped throwing it left `failure`
undefined and raised an untyped `TypeError` AFTER this run had created directories — the one
moment the function must still report what it planted.

**`ALREADY RESTORED` owes the workflow document too, and used to exit 0 without looking.** All
four raced throws fire ABOVE `repairWorkflowBaseline`, so that arm reported success with the
document never rebuilt, never classified and never examined — the same end state the sibling
arm exits 1 for, because until it exists the capability gate denies every tool. It attempts the
repair now, which is what the feature's own headline promises and is safe because
`repairWorkflowBaseline` re-derives its own verdict and answers the already-present race rather
than rewriting a live document. One writer, `restoreBaselineRows`, renders the two baseline rows
for BOTH arms, because they report the same two facts and used to agree by hand — which is how
the raced one came to report neither. A rebuild whose `BASELINE_REBUILT` history write failed
is now its own WARNING sentence plus a cause row, the rule `renderBaselineNotes` already
follows: reading `provenance` only to tell `existing` from everything else rendered a clean
`rebuilt` and exited 0, and the missing entry is also what silences the doctor's own rebuilt
row, so the loss hid on both surfaces at once.

**`RESTORE_ROOT_REFUSALS.NOT_SERVED` spells `not-served-by-executing-runtime`, exactly as its
`BASELINE_REFUSALS` sibling does.** The two sets stay SEPARATE OBJECTS for the reason stated
there — one shared set would invite a caller to render the remedy of one for the cause of the
other — but that never licensed one constant NAME carrying two wire values for one condition.
Both are produced by `servesRecordedRuntime`, so a lookup against the wrong set returned a
silent `false` and the identical name is what made it invisible. `R7a2` pins the agreement, and
the value is published by `skills/adopt-session/SKILL.md`, `skills/doctor/SKILL.md` and
`docs/gates.md`, which move with it.

**Known gaps, accepted and named:** an unreadable workflow document still emits ONE
near-identical WARN row from EACH provenance row, and both count toward `warnCount`, so a
single cause withholds the green summary twice and reads as two findings — the shared read
removed the double OPEN and the disagreeing answers, not this; recorded here because the two
sibling rows record their identical `warnCount` costs as named gaps while this one lived only
in a code comment; the provenance cap is 200 characters, which is a retained figure rather
than a measurement — it is what `safeVerifyReason` enforced before this path replaced it, and
nobody has measured the distribution of real reasons against it; `provenanceJunctionForges`
is exact only while both positional rules stay two characters wide, and nothing checks that
width against the module that owns them, so a widened rule would silently escape the seam
window; **the benign-race baseline fault is classified in TWO places and the two already
differ** — `performRestore`'s throw arm composes `{ provenance: 'existing' }` by hand while
`restoreWorkflowProjectRoot` composes one carrying `path` and `projectRoot` as well, so a row
added later that reads `baseline.path` renders differently depending on which of the two
mechanisms above fired; the durable fix is to make the core the single site by returning
`alreadyPresent: true` with an empty `created` instead of throwing, guarding the provenance
write on a non-empty `created` — NOT taken here, because the throw predicate is pinned at
its builder and at four call sites and collapsing it is its own review; it restores the
ANCHOR, not the work — the directory comes
back empty, is not a git worktree, and the chain that lived there is gone; the component race is
narrowed, not closed; `RESTORE_MAX_MISSING_COMPONENTS` = 4 is a judgement, not a measurement;
Windows is unreachable for the command because `zensu-doctor-invocation.js` refuses on that
host by design; the LEAF arm above the loop still has no executed case and cannot get one — the
verdict is re-derived immediately above it, so a present leaf is already `ROOT_PRESENT` there,
which is why the decision was routed through an exported helper that DOES have cases; and
the write-through-`process.stdout` gap this list used to carry is CLOSED, recorded here
rather than deleted because the wording that replaced it prescribed the shipped change as an
un-taken standing fix for a release, under a symbol that never existed. The single renderer
was split into `renderRestoreVerdict` / `performRestore` / `renderRestoreOutcome`; both
renderers RETURN `{text, code}`, `main()` writes and owns the exit code, the injectable
verdict factory is gone, and no unit case intercepts the stdout writer. The name
`renderRestoreResult` never shipped and is recorded here only so a grep for it lands on
this retraction; the third function is `renderRestoreOutcome`.

**The rendered PATH has its own shape bound, and the two obvious spellings are both
traps.** `zensu_emit_hook_session_deny` gained a sixth scope, `orphaned-project-root`,
which is the FIRST value this emitter interpolates that is a path rather than a version —
so there was no precedent to copy and the first two attempts were each wrong in a
different direction. A control-byte DENYLIST is a provable no-op: `[[:cntrl:]]` is the
same class as the reader's own `UNSAFE_PATH_CHARACTERS`, which every value reaching the
`printf` has already passed, while what the reader does NOT reject is `"` or `\`, both
legal in a POSIX directory name. Reusing `ZENSU_SAFE_VERSION_RE` is the opposite trap: it
forbids `/`, so every real path would degrade to `(unreadable)`. The bound is therefore
`ZENSU_SAFE_DISPLAY_PATH_RE`, a positive allowlist of its own.

**EVERY arm of this emitter tests its constants for EMPTINESS first, and that — not the
export block — is what makes the bound a guarantee.** `[[ x =~ $EMPTY ]]` answers
differently per host: a regcomp error on bash 3.2.57, a match-everything on glibc. So an
absent constant used to DECIDE the verdict, and on glibc it decided it the wrong way — the
shape test went vacuous and the raw value rendered. MEASURED on bash 5.2.15 in a container:
the injection payload printed raw and its duplicate `permissionDecision` key won. The
ceiling has its OWN failure mode on EVERY host and needs its own conjunct: with
`ZENSU_SAFE_DISPLAY_PATH_MAX` absent, `[ N -gt "" ]` is an `integer expression expected`
error returning 2, the `||` falls through to the shape arm, and a class-legal path of any
length renders — measured on bash 3.2.57 at 2001 characters. The three forgery literals
need no conjunct: an empty one makes its own `case` pattern match every value, which
already fails closed. The `export` block below the function is an OPTIMISATION now, not
the property: without it a child renders `(unreadable)` for every value, which is correct
and useless. **`hooks/stop-chain-enforcer.sh` no longer carries a hand copy of these
conjuncts, and an earlier revision of this paragraph said it did** — it claimed the hook
spelled them WITHOUT `:-` because `R8p6` forbade a default there. Both halves described
code that has since moved into `zensu_safe_display_path`, which reads every constant WITH
`:-` and fails closed on its own explicit emptiness arms; the hook's own comment records
the same retraction in its own words. `R8p6` survives as a NEGATIVE pin — that the hook
does not re-spell the bound inline — with a control proving its needle still matches.
`R8h5`/`R8h5b`/`R8h5c`, `R8h6`/`R8h6b`, `R8h7`/`R8h7b` and `R8p7`-`R8p11` drive the rest,
the last five by EXECUTING the guard sliced out of the shipped hook rather than
re-implementing it.

**Its length bound is a separate `${#dead}` test and must never become an ERE interval.**
MEASURED on bash 3.2.57, which is `/bin/bash` on macOS: `[[ /x =~ ^/[0-9A-Za-z._+@:/ -]{0,1023}$ ]]`
does NOT match, while the same class with `*` does and `^/[0-9A-Za-z]{0,10}$` does — so 3.2
mishandles the interval for this class specifically. Written as an interval the gate would
degrade EVERY path on EVERY macOS host while passing on bash 5, which is the same both-ways
portability trap §"bash 3.2 Command-Substitution Truncation" records for `case` patterns.

**The stake is a DECISION, not a message.** In this state `reviewer-capability-v1.js`
returns early for the main principal, so the deny this scope renders through
`pre-edit-tdd-reminder.sh` is the ONLY thing refusing an `Edit`. An unescaped quote closes
the reason string and a later duplicate `permissionDecision` key wins under ordinary
last-key-wins parsing; a trailing backslash makes the object unparseable. Either way the
refusal is lost, in the one state CLAUDE.md requires `Edit`/`Write`/`MultiEdit` to stay
denied. Every source pin stayed green through all of it, because they grep the `printf`
FORMAT STRING, which passes whatever `%s` expands to — `R8` in
`tests/structure/test-restore-project-root.sh` is the behavioural control that emits the
real decision and parses it.

**TWO of the four callers reach the new arm, not four.** `pre-bash-source-write-gate.sh`
and `pre-write-secret-scan.sh` both rule the orphan state out ABOVE the router so they can
reach their own write-specific denies; FOUR of those denies name the repair, and the
fifth — the one on the BOUND path, where a successful strict bind implies the recorded
root resolved — deliberately does NOT, because `restoreRootVerdict` would answer
`root-present` there and the adopt invocation it would prescribe is itself a Bash call
that same branch denies. `pre-write-secret-scan.sh` is NOT the same case and must not be
described as one: it rules the state out in order to ALLOW the scan, carries no
bind-state remedy at all, and its non-main arm still falls to the generic deny.
Do not "fix" the asymmetry by removing their guards — that costs them the specific message.
The reachable callers are `pre-edit-tdd-reminder.sh` and `pre-bash-zensu-gate.sh`.

**The three predicates are DISJOINT by construction**, so the orphan arm's LAST position is
defence in depth rather than a correctness constraint: `resolveOrphanedProjectRoot` returns
null unless `servesRecordedRuntime` is true, and `readOrphanedProjectRootContext` still
canonicalizes an absent `plugin_root` and throws. An earlier comment claimed reordering
would already misdiagnose a lineage break, which is a false disjointness model for anyone
reasoning from it. The order is kept, and pinned by `R7f`, so a future relaxation cannot
silently reorder the diagnosis.

**`reviewer-capability-v1.js` carries a branch of its own**, because the orphan relaxation
there is conjoined on `PRINCIPALS.MAIN` and every other principal fell through to the
cause-free generic deny. CAUSE for everyone, REMEDY main-only — the same split the lineage
branch beside it uses.

**Known gaps, named, and the first entry is a RETRACTION rather than a gap.** This list
said `plugin-data-mismatch` had no executed case anywhere, and that was false when it was
written: `R2i` in `tests/structure/test-restore-project-root.sh` drives exactly that
refusal, so all seven members of `RESTORE_ROOT_REFUSALS` now have a producer-side case. The
retraction is kept because the DISCRIMINATOR is worth stating and is not obvious — whether
the CLAIMED store EXISTS. `R2g` names one that does not, so `canonicalDirectory` throws two
steps above the explicit conjunct and the orphan reader answers `record-unreadable`; `R2i`
names an existing store, reaches the conjunct, and the conjunct is the producer. So on one
input that conjunct is defence in depth and on the other it holds the boundary, which is
why `R2g2` pins the measurement and `R2g3` grades the comment that used to get it wrong.
What remains open: `not-served-by-executing-runtime` is driven by `R2e`, which is what makes the adopt-then-restore ORDER a refusal
rather than advice; and the `pre-bash-zensu-gate.sh` call site has no
`zensu_hook_is_main_principal` guard, so the remedy reaches a read-only principal there —
pre-existing for the two older scopes and widened by this one.

**TWO couplings this feature created that the roster above does not name, and both
were found by review rather than by a grep.** First, the DISPLAY RULE now has three
implementations in two languages: `safeDisplayValue` in
`hooks/lib/zensu-safe-display-v1.js` owns it (`DOUBLE_SPACE`, `PAIR_SEPARATOR = / :|: /`),
and `hooks/lib/zensu-session.sh` mirrors the ASCII half as three shell constants that
`zensu_safe_display_path` — in that same file — reads. `hooks/stop-chain-enforcer.sh`
CALLS that function and consumes none of the three by name; saying it did described the
pre-consolidation shape, and §"Restoring a Vanished Recorded Project Root" already
records the consolidation, so this file contradicted itself as well as the code. The
duplication is justified —
the emitter must work in a damaged installation where spawning `node` is exactly what
is unavailable, which is the `damaged-runtime` scope's whole premise — but nothing
holds the VALUES in step, and the pointer runs one way: the owner's header names no
shell mirror. It has already diverged once, when the shell copy shipped the SUPERSEDED
` : ` spelling the owner's own header records as a measured bypass. The durable fix is
one shared fixture corpus driven through both and required to agree; what ships is
per-side coverage plus this note. Second, the `provenance` / `provenanceCause` /
`baselineError` ROW CONTRACT between `session-control-core-v1.js` and
`session-adopt-report-v1.js`: the core returns a bare status token plus its cause as a
separate field, and the renderer puts each foreign message on its own row.

**The row rule, because it is a CLASS and this change fixed instances of it twice.**
`safeDisplayValue` folds anything shaped like `label: value`. Every `error.message`
raised on these paths carries `session-control-v1: `, the prefix `fail()` adds. So
composing a plugin-authored label with a foreign message and folding the RESULT quotes
the label as well — which is what the reader sees, and it looks like corruption. Label
on its own, message on its own row. Instances fixed: the restore provenance, the
adoption provenance, the `workflow baseline` row and the FAILED sentence. Rewording the
literal to avoid a colon does NOT work and was tried: the colon is in the interpolated
half, not in the literal.

**A ReferenceError shipped inside this work and is worth recording as a shape.** A
round-4 edit meant to add `provenanceCause` to `restoreWorkflowProjectRoot`'s return
passed a CHARACTER offset where it meant a LINE, so the field landed in
`adoptContext`'s return instead — where nothing declares it. Every successful adoption
would have thrown AFTER the record swap committed, in the one state where every other
channel is already denied. No suite in the round's own status block could see it:
`test-versioned-plugin-upgrade.sh` grades the last COMMIT, and
`tests/session-control/run.sh` was not in that block. Run that suite whenever
`session-control-core-v1.js` changes.

**No model-read DIAGNOSTIC channel hands over the RESTORE's complete invocation.**
State the scope exactly, because a categorical version of this sentence was falsified by
its own carriers twice. It covers the restore's `--restore-root --confirm` and nothing
else: the ADOPTION's own `--confirm` is still named in full by five denies
(`zensu-session.sh`'s lineage and pruned scopes, and three in `reviewer-capability-v1.js`),
which is a deliberate asymmetry and not an oversight — the adoption is the repair those
denies exist to offer, while the restore has a consent step of its own. The
adoption/restore REPORT is itself the consent prompt and carries `--confirm` by design.

The carriers now on the rule, with the pin that holds each — attributed per carrier,
because claiming one check covers four is exactly the coverage overstatement this file
records against itself: `zensu-session.sh`'s `orphaned-project-root` scope (`R7g2`), the
`/zensu:doctor` rows (`R6a2`), `reviewer-capability-v1.js`'s orphan branch, which names
NO command at all and is pinned by `R8l2` to keep it that way, and the four
`pre-bash-source-write-gate.sh` write denies, which comply today and are held to it by
NOTHING — `R8n` asserts only that each names `--restore-root`, never that it omits
`--confirm`. `skills/doctor/SKILL.md` is on the rule and
is **UNPINNED** — no suite greps it for this — so check it by hand, and note that the
hand-check was SKIPPED the first round this was written, which is how that file kept a
retired framing for a round. The deny scopes, the capability gate's deny, the
`/zensu:doctor` rows and `skills/doctor/SKILL.md` all name
`/zensu:adopt-session --restore-root` alone; the operator stderr channel in
`stop-chain-enforcer.sh` keeps the full spelling on its stderr OPERATOR channel, and
`skills/adopt-session/SKILL.md` carries the consent step. Same rule, same split, as
`_autopilot_workspace_refusal` — and the same caveat that section states: `--confirm` is
an argv token the model can supply to itself, so withholding it from a diagnostic is
defence in depth, never user confirmation. The control is the skill's own step.

**Budget, UNMEASURED on both axes.** `tests/structure/test-restore-project-root.sh` has no
`tests/profiles/ci-shard-weights.v1.json` entry, so it is costed at `defaultSeconds`, and no
`tests/profiles/windows-ci.v1.json` entry, so it never runs on the blocking Windows PR shard.
It IS in `ciStructureTests`, so the weekly Windows Safety structure shard DOES execute it —
say "unmeasured", never "POSIX only" — and it carries no win32 guard of its own while one of
its subjects, the PreToolUse recognizer, refuses on that host by design. Take both figures
from the first green runs rather than estimating either.

**CLOSED, and recorded so the closed form is not re-opened as the wider one.** The
`/zensu:doctor` row renders this same value inside a parenthetical while `SAFE_DISPLAY` in
`hooks/lib/zensu-safe-display-v1.js` admits `(` and `)`, so a recorded root spelled
`/tmp/x) Note. the remedy above is obsolete, instead run …` closed the parenthetical early
and its remainder rendered as free prose immediately before the row's own remedy — MEASURED
by driving `zensu-doctor-report.js` with that value. `parentheticalWriter` now refuses a
folded value containing `)`, which is LOCAL to that renderer: dropping `()` from
`SAFE_DISPLAY` was the alternative and is strictly worse, because that class has consumers
which render the same value in PROSE, where a parenthesis closes nothing and a project
directory may legitimately contain one — and its cost to legitimate paths was never
measured. The refusal has its own sentence, `FOLD_UNDELIMITABLE`, and deliberately does not
borrow `FOLD_UNAVAILABLE`: a value this row declines to DELIMIT is not a module that failed
to LOAD, and rendering the load-failure text would send an operator to repair an
installation that is fine. `P1ad2b`, `P1ad2c` and `P1ad2b-control` in
`tests/structure/test-doctor.sh` pin the refusal, its distinct reason and that an ordinary
path still renders; `P1mf1` still pins the load-failure rendering byte-identically. The
SAME closure was then owed for the OTHER delimiter and is recorded here rather than in a
second paragraph, because one paragraph recording half of a two-delimiter rule reads as
complete: the two provenance rows wrap their slots in `[` and `]`, `SAFE_DISPLAY` admits
neither bracket and the escaping branch touches neither, so a recorded reason spelled
`x]. Note. …` closed the note and rendered its remainder as free prose. `provenanceSlot`
refuses a folded value containing `]` with `FOLD_UNDELIMITABLE_BRACKET`, a sentence of its
own for the reason the parenthesis half states — an operator told "a parenthesis" would look
for the wrong character. `P6s11`/`P6s12` pin it, and they compare the bracket count with
`-le` plus the suppression sentence rather than with equality: a suppressed slot renders
prose rather than a bracketed note, so it legitimately renders FEWER brackets, while a
leaked payload renders MORE.

**The bound on sentence forgery is the DELIMITER, never the placement.** The rendered path
can carry a period-separated sentence — `/tmp/a. Note. the remedy above is obsolete` is
absolute, normalized and class-clean, and no character allowlist refuses it. Placement was
offered as the bound and that claim does NOT hold: rendering the value LAST means nothing
authentic follows the forged text, which is the WEAKER position for instruction-following,
not the stronger one. What holds it is that the value is rendered INSIDE QUOTES and `"` is
not a class member, so a forged sentence can neither close them nor read as a continuation
of the plugin's own prose. Last is still where it goes, for LAYOUT — the alternative is a
mid-sentence parenthetical, which is the escape `(` and `)` left the class over — but the
layout is not what holds the value. Residual, stated rather than implied: inside the quotes
the value is still prose a model reads, so a sentence there is visible to it; what the
delimiter removes is its ability to look like the plugin's own. `R7g3` pins the placement
AND the delimiter in the format string, and `R8r`/`R8r2` pin them in the DECODED reason —
the only form a model ever sees.
