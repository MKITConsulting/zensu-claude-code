---
paths:
  - "hooks/lib/session-adopt-report-v1.js"
  - "hooks/lib/claude-session-control-v1.js"
---

# Workflow-Baseline Repair (`workflowBaselineVerdict` / `repairWorkflowBaseline`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

**A DIFFERENT wedge from the one adoption exits, and confusing the two is the mistake
this section exists to prevent.** Adoption answers "this runtime may not SERVE the
record". This answers "this runtime serves it perfectly well, and the workflow
document the record anchors is GONE". They share a section boundary and nothing else:
adoption re-mints a record, this rebuilds a document, and neither is reachable in the
other's state.

The cause is ordinary rather than exotic: a git worktree deleted and re-created loses
`<project>/.zensu/state/tdd-phase-<key>.json`, because `.zensu/*` is gitignored, and a
COMPACTION continues the SAME session instead of minting a new one. `revalidateWorkflowState`
in `hooks/lib/reviewer-capability-v1.js` then throws on the `.*` matcher, so **every tool
denies** — Edit, Write, Bash, subagents.

**The deny is CORRECT and STAYS. Nothing here relaxes it.** Reading a deleted document
as "never active" is exactly how a session would escape an armed review chain by
deleting one file. The repair REBUILDS the document; it never waives the gate. Do not
"simplify" this into a relaxable bind failure — the two relaxable states in
§"Relaxable Bind Failures" share an argument this one does not: there NO workflow
document is reachable, so relaxing waives a dead guarantee. Here the document is
exactly what is missing, and its absence is the signal.

**THE SEAM WAS ALREADY THERE, and taking it is why the recognizer is untouched.**
`already-served` + `--confirm` is ALREADY the "the record is fine, something beside it
is wedged" path in `session-adopt-report-v1.js` (`shouldRepairInPlace`), and it swept
the lease store. The baseline is its SECOND repairable item. Consequently
`hooks/lib/zensu-doctor-invocation.js`'s recognized COMMAND SET is unchanged: the
recognized list stays at two and `RECOGNIZED.adopt.args` stays `["--confirm"]`. A new
command or a new flag would have needed its own justification written down the way that
file demands; reusing the seam needed none. Do NOT write "that file is unchanged" — its
write-class comment DID move, it is on the roster below, and this paragraph and that
roster contradicted each other about the same file for a release.

**The baseline half runs BEFORE the lease sweep**, and that is a decision rather than
layout: a wedged session cannot make a tool call until the document is back, while a
stuck lease only costs it a review. Both halves compose into ONE headline and ONE exit
code (`repairHeadline` / `repairExitCode`, both taking the baseline as an OPTIONAL
second argument so the pre-existing single-argument contract and its four unit
assertions are byte-identical). EITHER half failing exits non-zero — a rebuilt baseline
does not launder a stuck lease.

**ONLY `missing` is repairable, and the other two arms are the discrimination test.**
`classifyWorkflowBaseline` answers `present` / `missing` / `unsafe` / `unreadable`, and
the ORDER is the contract: the safety tests (symlink, hard link, non-file,
`> MAX_JSON_BYTES`) run BEFORE the parse, so tamper is reported as tamper rather than
as a document that failed to validate. `unsafe` and `unreadable` are REFUSED with their
bytes left alone — something is at that path, and rebuilding over it would destroy the
evidence and hand the session its capabilities back in the same step. A check that only
proves "a missing document is rebuilt" passes identically in a tree that rebuilds
anything it cannot read. The rows that separate them are `AC-D02` (an unreadable
document is refused and its bytes are left alone) and `AC-D07b` (a hard-linked document
keeps the generic gate wording and is offered no rebuild), both in
`test-versioned-plugin-upgrade.sh` — `AC-002` is a PLAN id and names no row in any suite,
which is what this sentence claimed for a release.

**The bind is the INVERSE of adoption's condition 3.** Adoption refuses when the
executing runtime already serves the record; this REQUIRES it. A record this runtime
may not serve is a lineage break with its own exit, and rebuilding a document under a
runtime not allowed to read the record anchoring it would be the wrong repair for the
wrong cause. `BASELINE_REFUSALS` is deliberately a SEPARATE vocabulary from
`ADOPTION_REFUSALS` — one shared set would invite a caller to render one's remedy for
the other's cause.

**Provenance is a history entry and NOT a bypass-ledger entry**, the same rule
`--chain-recover` and adoption follow, and for the same two reasons. A record or state
FIELD would be a persisted shape change, which under §"Runtime Lineage" costs a
breaking release and would wedge every session then running. And the ledger records
gate ESCAPES so that everything rendered under "Gates bypassed" is true — this escaped
no gate, because the document a gate would have read was already gone.
`BASELINE_REBUILT` and the `baseline-rebuilt: ` reason prefix are therefore reserved
beside `CHAIN_RECOVERED` and `RUNTIME_ADOPTED`, and all three are enforced at the same three
entry points: `zensu-log.sh --phase`, `tdd_write_phase` and `_tdd_write_phase_critical`. The
LITERALS live in only TWO bodies — `zensu-log.sh --phase` and `_tdd_reserved_provenance`, which
both phase-library write functions call — TWO literals each, matched case-INSENSITIVELY in both,
because the reserved-provenance extraction moved them out of the write functions. State the unit
or the number means nothing: counted as entry points it is three, counted as literal-carrying
bodies it is two, and §"Adopting a Record Across a Lineage Break" and §"Chain Shape & Rearm
Receipt" both say "two guard sites" for this SAME set, which since the extraction is also the
body count. A rename lands in those two bodies; the write functions hold no literal to find.

**And the reserved phase is evidence a heal HAPPENED, never evidence that none did.**
The entry is the feature's only disclosure, and it is erasable by exactly the session it
discloses: `initializeWorkflowState` writes the rebuilt document with `active: false`,
`pre-edit-tdd-reminder.sh` returns early while a session is not active — above its
`.zensu/state` classification — and `bash-source-write-parse.js` carries no `.zensu` rule
at all, so neither the Edit matcher nor any Bash gate covers that path. The four
reserved-phase guards stop the phase being MINTED through the plugin's verbs; nothing
stops the entry being DELETED by a direct write, and `validateWorkflowExtensions` checks
`history` structurally with no MAC and no counter. So "a forgeable provenance entry is
worse than none, because it is believed" is the right reason for reserving the phase and
is NOT a claim that the entry is tamper-evident. A real control needs a rebuild counter
in the plugin-data store — which `pre-write-plugin-data-guard.sh` defends for main-thread
file tools and `reviewer-capability-v1.js` for every other principal — compared against
the document's own `history` by `/zensu:doctor`. That is a store-layout addition rather
than a workflow-state field, so it does not cost the breaking `minor` this section
declines to pay. NOT implemented; recorded so the bound is not read as a guarantee.

**SessionStart heals the same state without a user, and the argument is not new.** The
*record exists* branch of `claude-session-control-v1.js` classified nothing and called
`readWorkflowState`, which failed the hook and repaired nothing — and no later
SessionStart could help either, because that same branch would fail again. It now
re-initializes on a clean **ENOENT only**; invalid JSON, a failed validation, a symlink
and a hard link still fail there. The justification is the one the sibling *no record*
branch already makes in its own comment: refusing creates no document, and no document
fails every stateful hook closed for the rest of the session.

**Moving together:** `BASELINE_STATES` / `BASELINE_REFUSALS` / `BASELINE_HISTORY_PHASE` /
`BASELINE_HISTORY_REASON_PREFIX` / `classifyWorkflowBaseline` / `workflowBaselineVerdict` /
`repairWorkflowBaseline` / the newly exported `adoptionWorkflowStatePath` — and FIVE more
this roster omitted for a release, every one of which has a production consumer outside
the core: `classifyWorkflowBaselineShape` and `baselineUnsafeComponent` (the adopt report
and, for the second, the doctor row), `isBaselineAlreadyPresent` with its two
`BASELINE_ALREADY_PRESENT_CODE` / `BASELINE_NOT_REPAIRABLE_CODE` constants, which travel
as ONE unit: a tree carrying the writer without the predicate reports EVERY refusal —
tamper included — as the benign race, headline "nothing to repair", exit 0, which is the
one omission here whose failure is silent. Plus `baselineComponentLadder`, the single walk
`classifyWorkflowBaselineShape` and `baselineUnsafeComponent` now share, whose two readers
deliberately disagree on the absent-component arm — all in
`session-control-core-v1.js`; the four reserved-phase guards; `baselineVerdict` /
`repairBaseline` / `baselineFault` / `leaseFault` / `renderBaselineDiagnosis` /
`renderBaselineNotes` / `survivingEvidence` plus the two-argument `repairHeadline` /
`repairExitCode` in `session-adopt-report-v1.js`; `BASELINE_MISSING_CODE` and its TWO
throw sites in `reviewer-capability-v1.js` — say two, and note that they produce THREE
tagged causes only because one sits inside a two-element directory loop; a reader
counting `baselineMissing(` finds two, and the roster said three for a release; the
`case 1)` reason in `stop-chain-enforcer.sh`; the `stateBlock` row in
`zensu-doctor-report.js` — which is ONE renderer, `ownDocumentVerdict`, called from BOTH
the `readdirSync` ENOENT branch and the populated path, because it was a hand-written row
on the populated path alone and was therefore unreachable in the shape the feature
targets; **the record-exists SessionStart branch in `claude-session-control-v1.js`**,
which consumes SIX exported core symbols (`adoptionWorkflowStatePath`,
`classifyWorkflowBaseline`, `BASELINE_STATES.MISSING`, `BASELINE_STATES.PRESENT`,
`repairWorkflowBaseline`, `isBaselineAlreadyPresent`) and is the one caller with no local
`catch` around the repair, so an untyped throw there exits the whole hook — it was
missing from this roster for a release, so a rename would have sent a maintainer to six
sites and not to the self-heal. Say `catch`, never `fail`: that branch DOES call the
module-level `fail`, and a maintainer checking the claim by grepping finds it at once; and the write-class enumerations, of which there are **FIVE** and not three:
`hooks/lib/zensu-session-adopt.sh`'s header, `hooks/lib/zensu-doctor-invocation.js`,
`reviewer-capability-v1.js`'s recognized-command comment, **`docs/session-control.md`
§"Unbindable sessions"** and **the recognized-commands intro of `docs/gates.md`**. The
adopt header is the document the PreToolUse recognizer's admission RESTS on, and the
`--confirm` baseline repair added a FOURTH write class (this session's workflow document
plus its `.zensu` ancestors, under the recorded project root) that all five enumerated as
three for a release — the two DOC carriers were still stale a full round after the three
code carriers were fixed, precisely because this roster named three. TWO of the four
classes leave the plugin-data store, the document and the history entry, and the history
entry is written on the ORDINARY adoption with no `already-served` qualifier; the
recognizer's comment called the document write "the one" that leaves the store, which was
false.
**Operator-facing accounts:** `skills/adopt-session/SKILL.md` §"Strict Scope", its
`already-served` refusal row, its "Do NOT Use For" bullet (TWO `--confirm` exceptions,
not one — the lease store AND the workflow document; routing the second to
`/zensu:doctor` is wrong, that command is read-only and cannot rebuild), its "FIVE
things are NOT clean states" list, its exit-code paragraph (EITHER half failing exits 1)
and its Response Style rule; its FRONTMATTER description, which covered only the lineage
break while the capability gate now routes a served-record session here as well; the FOUR
state rows in `skills/doctor/SKILL.md` — not two, and the pair that was missing is the one
that matters, because the UNSAFE/UNREADABLE row says `--confirm` will REFUSE while the
documented MISSING row says to run it, so a model holding only the MISSING bullet relays a
rebuild the repair declines by design — plus that file's frontmatter `session state`
clause, which reads as a complete inventory of the block and did not name this row; the
`stop-chain-enforcer.sh` row in `docs/configuration.md`, whose blocking-state list
presents itself as complete and does not name a missing workflow baseline (a state whose
record binds perfectly well);
`docs/session-control.md` §"Unbindable sessions" (as a FOURTH state that is NOT one of
the two relaxable bind failures, and whose absence from the per-gate table is stated
there rather than left to be noticed); and `docs/gates.md` §"Missing Workflow Baseline".

**Port-relevant.** The core half is `BASELINE_STATES` / `BASELINE_REFUSALS` /
`BASELINE_HISTORY_PHASE` / `BASELINE_HISTORY_REASON_PREFIX` / `classifyWorkflowBaseline` /
`workflowBaselineVerdict` / `repairWorkflowBaseline` / the newly exported
`adoptionWorkflowStatePath` — plus `classifyWorkflowBaselineShape`,
`baselineUnsafeComponent`, `baselineComponentLadder` and the
`isBaselineAlreadyPresent` + two-constant unit, which this list omitted for a release: a
port copying exactly it ships an adopt report and a doctor row calling three undefined
functions, and reports every tamper refusal as "nothing to repair" — all in the
host-neutral `session-control-core-v1.js`. The
host half is SEVEN obligations, and a port that takes only the core delta gets a writer
with no reachable caller and keeps the wedge: the adopt-report renderer and its two-argument
`repairHeadline`/`repairExitCode`, the capability-gate deny branch and its
`BASELINE_MISSING_CODE` tagging, the SessionStart adapter, the Stop `case 1)` reason, the
doctor row, the four reserved-phase guards, and — easiest to miss — the write-class
justification the host's own gate admission rests on, which the baseline repair extends.
`zensu-codex`, `zensu-kiro` and `zensu-antigravity` were NOT included in this change; each
carries its own recognizer and its own doctor against a different harness, and the
directory-component ladder in `classifyWorkflowBaseline` has to be re-decided against
whatever that host canonicalizes.

**Version: `patch`.** Walked against §"Runtime Lineage" entry by entry: no context-record
or workflow-state schema field (`BASELINE_REBUILT` is a history-entry VALUE, and
`workflowState`/`event` are shape-validated by `validateWorkflowToken`, not members of a
vocabulary); no strict key set; no hook added, removed or renamed and no matcher changed;
no new config key; no attestation change; and no change to the recognized command set or
its argument list. The capability gate's deny is a REWORDING of an existing deny, not a
new one — the shape it refuses is byte-identical.

**Known gaps, accepted and named:**

- **The rebuild is a real LOSS, not a restore.** A chain that was live when the document
  vanished is gone, and the rebuilt baseline reads "never active" because that is all a
  fresh baseline can say. Nothing in the rebuilt document says what was lost. The
  mitigations are disclosure only: the writer is unreachable without `--confirm`, the
  report lists the session-keyed evidence that survived (`pending-review.json`, its
  `.claim`, an Autopilot pointer, a reviewer-denial note) WITHOUT interpreting it, and
  every carrier states the cost beside the command. Since `baselineRebuiltRow` in
  `hooks/lib/zensu-doctor-report.js`, the provenance entry is also RENDERED — a `WARN`
  row on the PRESENT arm of the own-document verdict, which is the only state a rebuilt
  document can be in. It reads its phase token from the LOADED core rather than from a
  literal, so a rename reports a missing check instead of silently deleting the row;
  `P6r`-`P6r4` in `tests/structure/test-doctor.sh` pin the row, its cost-and-remedy
  wording, the history control and both halves of that token rule.
- **The SessionStart self-heal is not user-confirmed.** A session could delete its own
  document and wait for an automatic compaction. The history entry makes that visible —
  and since the doctor row above it is visible to a USER rather than only to a guard
  reader, which is what the disclosure argument always assumed and did not have. The
  adapter also PUSHES it: `BASELINE_HEAL_NOTICE` in
  `hooks/lib/claude-session-control-v1.js` rides the `additionalContext` the hook already
  emits, so the first reply after an automatic heal can say what was lost rather than
  waiting for someone to run the doctor. Two bounds travel with it and neither is
  cosmetic: the notice is MODEL-facing, so nothing forces the model to relay it, and it is
  APPENDED to the principal's rendered context rather than substituted for it, because that
  context is what binds the session. Blocking at Stop was weighed and REJECTED — after a
  rebuild the baseline reads "never active", so there is no armed chain left to enforce and
  a block would obstruct the common blameless case, a deleted and re-created worktree, to
  catch a rare one it cannot tell apart, the distinguishing state having been destroyed with
  the document. Nothing prevents the deletion itself. It matches the existing *no record* branch, which already
  re-registers without consent for the same reason — but say "matches", never "is
  therefore safe".
- **Windows is unverified for the in-session half — and scope that claim to the
  RECOGNIZER, not to the suite.** `zensu-doctor-invocation.js` refuses on win32 by
  design, so the repair COMMAND is unreachable there exactly as `/zensu:doctor` is; only
  the SessionStart self-heal and the doctor row apply on that host. Do NOT write "Part D
  has no Windows profile entry": that was false when it was written.
  `test-versioned-plugin-upgrade.sh` is registered in `windows-ci.v1.json`,
  `windows-native-structure.v1.json` and `windows-ci-command-catalog.v1.json`. What IS
  open there is the BUDGET: neither the `timeoutMs` nor the shard weight was re-measured
  after Part D, Part D is the file's TAIL, and a `TIMED_OUT` therefore takes exactly
  these rows. Take the figure from the next green Windows shard.
- **The doctor's directory-absent arm is NARROWED, deliberately.** When
  `<project>/.zensu/state` is absent AND no bound session key is available, the
  own-document row is WITHHELD rather than disclosed. The judge pass asked for the
  disclosure in both cases; warning there fires on every ordinary run in a fresh project
  and is the "trained away within a day" failure this file records for the
  implementing-turns row. The defect the row exists for — a green report over a session
  whose capability gate is denying every tool — requires a BOUND session, which is
  exactly the case where the key is available and the ❌ row does fire. The POPULATED
  path still discloses. `P6e`/`P6f` in `test-doctor.sh` pin both halves.
- **`verdict-unavailable` has no executed case and cannot get one from the unit layer.**
  `workflowBaselineVerdict` wraps its whole bind derivation in a try that returns a
  REFUSAL, so a caller-supplied fault lands as `record-unreadable`; the catch in
  `baselineVerdict` fires only for a throw AFTER a successful bind, which needs a real
  bound record the report unit suite does not build. Its sibling `rebuild-failed` IS
  driven from its producer. Stated rather than faked with a hand-built object.
- **`classifyWorkflowBaseline`'s `file` parameter is derivable from its other two and
  the relation is not enforced.** The directory ladder is anchored on
  `fs.realpathSync.native(projectRoot)` while the leaf is lstat'ed on the caller's own
  string, so a third caller passing a mismatched pair would have the ladder judge one
  tree and the leaf name another, silently. Both shipped callers derive it with
  `adoptionWorkflowStatePath`. Dropping the parameter is the durable fix and is NOT taken
  here, because it churns every call site and pin for no behaviour change.
- **`ownDocumentVerdict(discloseWithoutKey)` threads call-site identity through
  a boolean**, so the policy it selects lives only in a comment. Passing the directory
  state instead would read from a value that names the condition.
- **`MAX_JSON_BYTES` (core) and `MAX_PAYLOAD_BYTES` (`reviewer-capability-v1.js`) are a
  hand-copied pair with no pin.** They are equal today. Were the gate's bound lowered, a
  document between the two would be denied by the `.*` gate while the classifier answered
  PRESENT — so both the adopt report and the doctor row would call the document fine in a
  session where every tool is refused. The gate already requires the core; importing the
  bound is the fix.
- **Four arms of the directory ladder have no executed case:** the root-realpath failure,
  the component-lstat non-ENOENT errno, the `realpathSync.native(candidate) !== candidate`
  arm, and the THROW from that same component realpath — which an earlier wording of this
  bullet promised as a fourth and then listed three, in a bullet whose whole purpose is to
  bound what is unverified. `WB5a` covers the component-symlink arm and `WB1a` the non-directory
  half. The canonical arm is the one that mirrors the gate's `is not canonical` check, so
  a divergence between the two ladders would not be observed.
- **Nothing in this repository can measure `hooks/lib` coverage.** The only `c8` script in
  `package.json` includes `skills/session-trail/scripts/*.mjs`; the 80.93% / 72.63%
  figures quoted for this feature came from an ad-hoc invocation and are not reproducible
  by any command in the tree. An explicit `hooks:coverage` script is the fix. Note also
  what re-measuring would NOT have caught: the vacuous `AC-D04b` is invisible to a
  line-coverage tool, because the guard lines ARE executed.
- **`renderBaselineNotes`'s `sessionId` is currently unread.** The diagnosis's local-fault
  branch returns before the branch that lists surviving evidence, so the threading is
  dead today. It is kept because passing `""` was an active defect — `core.sessionKey`
  throws on it — rather than a neutral placeholder.
- **One `--confirm` run derives the same bind three times**, and all three
  `BASELINE_REFUSALS` members are therefore unreachable from both shipped callers — both
  reach the verdict only after the bind is already established. The obvious fix, an entry
  point taking an already-validated verdict, is REJECTED rather than pending: the second
  derivation inside `repairWorkflowBaseline` is the TOCTOU re-check, and accepting the
  caller's verdict would delete it. The cost is a repeated runtime-digest computation on
  a path that runs once per repair.
- **The evidence listing is a closed candidate set, and it is not complete.** The
  Autopilot pointer is matched by SHAPE (`autopilot-active-<64 hex>.json`) rather than by
  this session's owner hash, because that hash is not derivable from what the report
  holds. So a foreign session's pointer can be listed. It is listed, never interpreted,
  which is why that is acceptable — but do not describe the list as "this session's".
