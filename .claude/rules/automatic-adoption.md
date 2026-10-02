---
paths:
  - "hooks/lib/session-auto-adopt-v1.js"
  - "hooks/lib/claude-hook-session-v1.js"
  - "hooks/lib/claude-session-control-v1.js"
  - "hooks/lib/reviewer-capability-v1.js"
  - "hooks/lib/review-evidence-hook-v1.js"
  - "hooks/lib/zensu-session.sh"
  - "hooks/stop-chain-enforcer.sh"
  - "hooks/lib/session-adopt-report-v1.js"
  - "tests/structure/session-auto-adopt-v1.test.js"
  - "tests/structure/session-adopt-report-v1.test.js"
  - "tests/structure/test-versioned-plugin-upgrade.sh"
  - "hooks/lib/session-control-core-v1.js"
  - "hooks/lib/zensu-config.sh"
  - "hooks/lib/zensu-doctor-report.js"
  - "tests/structure/test-doctor.sh"
  - "skills/adopt-session/**"
---

# Automatic Adoption (`hooks/lib/session-auto-adopt-v1.js`)

The adoption described in `.claude/rules/session-adoption.md` runs on its own: the first
hook that binds a record the running installation may not serve by version, but
`adoptableRecord` admits, re-mints it. `/zensu:adopt-session --confirm` is the manual
fallback and the refusal report. Measured on 2026-09-15 across the 0.20.0 to 0.21.1
update: six sessions needed the manual step within eight minutes and every adoption
succeeded, so each deny was a false positive that cost the user a step.

## The module

ONE implementation serves every hook-side binder and the manual entry point.

- **Ladder:** `createAutoAdopter` / `adoptForHook` / `previewAdoption` /
  `autoAdoptEnabled` / `configLayers` / `AUTO_ADOPT_OUTCOMES` / `AUTO_ADOPT_REASONS` /
  `CONFIG_KEY`.
- **Rendering:** `STATE_NEUTRAL_REASONS` / `establishesNamedState` / `SAFE_TOKEN` /
  `SAFE_PROVENANCE` / `safeProvenance` / `provenanceText` / `keptName` / `leaseClause` /
  `sweepWorthReporting`, plus
  the renderers `createRenderers(core)` builds over the injected core: `safeVersion` /
  `operatorLine` / `confinedOperatorLine` / `servedSweepLine` / `doctorPointer` /
  `renderAdoptionNotice`. The module-level exports are
  the instance built over the real core, so a port that injects its own core gets renderers
  that judge against it.
- **Core support:** `ADOPTION_REFUSED_CODE`, `SUPERSEDED_EXISTS_CODE`,
  `isAdoptionRefusal`, `isSupersededRecordConflict`, `isLockTimeout`,
  `supersededRecordName` / `supersededRecordFile` (the ONE spelling of the superseded
  name; both throw on a version that fails `ADOPTION_SAFE_VERSION_RE`), the history-reason
  grammar `ADOPTION_PAIR_SEPARATOR` / `formatAdoptionPair` / `formatAdoptionReason` /
  `parseAdoptionReason` (the writer, the renderers, the binder's `ZENSU_SESSION_ADOPTED` and
  the doctor row all go through it), and `ADOPTION_PROVENANCE` (`recorded`,
  `no-workflow-document`, `unavailable`; the cause of `unavailable` travels beside it as
  `provenanceCause`).

The ladder is `adoptableRecord`, then the crash-resume check, then the opt-out, then
`adoptContext` under the per-session records lock, then `discardSupersededLeases`. The
first three rungs ARE `previewAdoption`, and `adoptForHook` starts from it, so the
read-only report, the binder's `adoption-refusal` mode and the adoption cannot disagree
about one record. The probe runs first, so `opted-out` only stands for a record that
would otherwise have been adopted. The crash-resume check is an `lstat` of
`supersededRecordFile(...)`: an interrupted adoption leaves that file behind and
`adoptContext`'s `COPYFILE_EXCL` refuses every later attempt, a dangling link included.

The preview is WRITE-FREE, and two consumers rest on that: the report's read-only path,
whose write-free premise the PreToolUse recognizer's admission of the command rests on,
and the binder's `adoption-refusal` mode. `adoptForHook` completes every SERVED answer
with the lease sweep — at probe time, under the lock, and when a lock timeout is followed
by one more probe that finds the record served — because a sibling's adoption is not
complete until its sweep ran, and the winner sweeps only after it released the lock. The
sweep is idempotent and runs against the canonical executing root, the spelling leases
record.

`adoptForHook` never throws. A typed refusal keeps its reason; a superseded-file
conflict is `REFUSED / superseded-record-exists`; a lock timeout is
`UNAVAILABLE / lock-timeout` unless the re-probe finds the record served, which is then
`ALREADY_SERVED / adopted-concurrently`; anything else is `UNAVAILABLE / adoption-failed`;
a throwing sweep is carried as `sweep-failed` rather than reverting a swapped record. The
verdict shape is fixed: every field is always present. The state fields `recorded`,
`executing`, `orphanedProjectRoot` and `prunedPluginRoot` come off the probe, because
`adoptableRecord` attaches them to refusals as well; never re-derive them. An
`already-served` probe carries `recorded: null`, because the record on disk is already
the re-minted one. The adapter passes the version it observed as `observedRecorded` on
the REQUEST, and the module is the one place that puts it on the verdict.

## Config: `hooks.sessionAutoAdopt`

Read on the adoption path only, never on a healthy bind. `configLayers` reads the
candidate files of `_ZENSU_STRICT_JS` in `hooks/lib/zensu-config.sh`: `ZENSU_CONFIG`
verbatim as one layer, else the global file (only when `HOME` is a non-empty string) and
the project overlay. The unit suite pins the two candidate sets against each other.

For this key `false` is STICKY, the combining rule `_ZENSU_STRICT_JS` applies as well: the
automatic path is off when EITHER layer says so. The overlay lives in a directory a
session can write while no chain is armed, so project-wins would let a seeded `true`
override an operator's global `false`. The two readers differ in ONE direction,
deliberately: a malformed layer WITHDRAWS the capability grant the strict shell reader
guards, while here every fault degrades to ENABLED, because the enabled state runs a
repair rather than a bypass. No shell reader consumes this key. The project overlay is
anchored on the ambient `CLAUDE_PROJECT_DIR`, as the shell readers anchor it, not on the
record's root.

The manual `--confirm` path calls `adoptForHook` with `respectOptOut: false`, so the key
switches the hooks off and never the command the user runs by hand.

## Opt-in table

`resolveHookSession(payload, environment, options)` adopts only under
`options.autoAdopt` and requires the module LAZILY inside the failure path: the sweep
requires the lease owner, which requires the binder, which requires the core, so a
top-level require cycles.

- **Opted in:** the CLI's hook-payload modes (every shell gate, the Stop hook, the consent
  hooks), `revalidateSessionContext` in `reviewer-capability-v1.js`, both halves of
  `review-evidence-hook-v1.js`, and the adapter's resume/compact and SubagentStart
  branches through `serveOrAdopt`. The evidence hook opts in for two different reasons:
  its start half shares the SubagentStart matcher with the adapter and races it, and its
  stop half runs on SubagentStop, where no adapter binds, so an adoption that fell due
  while the worker ran lands there or the worker's result is lost with its lease
  retirement.
- **Never opted in:** `model-bind` (`zensu-doctor.sh` stays write-free and no `zensu-log.sh`
  verb re-mints a record), `resolveFreshHookProject` and `bindFromModelEnvironment`.

After an adoption the binder re-reads STRICTLY. An adopted record whose project root is
gone re-throws the core's `context project root does not exist`, and the gates' orphan
ladder takes over.

## Races

`adoptContext` runs under `withFileLock` and re-checks adoptability inside it, so the
loser answers `already-served`, completes the sweep and re-reads. A timeout maps to a deny,
never to a partial adoption; `withFileLock` attaches `LOCK_TIMEOUT_CODE` and the adopter
consults `isLockTimeout` first. `AUTO-2` and `AUTO-17` hold the records lock from a third
process and require two proofs of waiting: every racer finished at or after the holder
released, and the re-minted record was written no earlier than one second before the
release. The second does not rest on the racers' run time; it reads the RECORD and not the
superseded copy, because `copyFileSync` carries the source's timestamps over on macOS.

## Denies name the token

The binder throws a typed error carrying the verdict. The `.*` gate renders it from
`error.adoption` only when the verdict establishes a named state (a reader answered and
the reason is not in `STATE_NEUTRAL_REASONS`); otherwise it falls through to its
predicate arms, and its generic deny appends the state-neutral sentence the shell generic
scope appends: the attempt lead-in, the verb and the token, then the remedy for the main
thread and `ADOPTION_CHILD_CLOSE` for any other principal. The seam pin holds that
lead-in to one spelling in the gate and two in the shell, and the remedy split to the
`callerIsMain` selector. The shell gates capture the token through the `adoption-refusal` argv
mode and pass it to `zensu_emit_hook_session_deny` as `$4`, the audience as `$5`. Entry-
level tokens beside the seven `ADOPTION_REFUSALS`: `opted-out`, `adopted-concurrently`,
`superseded-record-exists`, `not-completed`. The mode exits 1 when it cannot answer, which
the wrappers render as `(unknown)`.

`zensu_emit_named_bind_deny` has three paths below the named scopes: a state-neutral
refusal appends one sentence to the generic scope; a lost race gets the `adoption-incomplete`
scope; an empty answer leaves the scope unchanged. The Stop hook re-binds ONCE on
`adopted-concurrently` and enforces the chain in that Stop; a failed re-bind blocks as
before. The preview answers null, never `not-completed`, for a record that already serves
while the strict bind still fails, because that failure was never an adoption one. That
null is also what keeps the `orphaned-project-root` arm of the router reachable.

Token-dependent parts are hand-copied across the JS/shell boundary and pinned by the seam
pin at the front of `test-versioned-plugin-upgrade.sh`, both ways and with exact arm counts:

- **Verb:** `ADOPTION_INCOMPLETE_REASONS` render "it did not complete", everything else
  "it was REFUSED".
- **Remedy:** `ADOPTION_REFUSAL_REMEDIES` in `reviewer-capability-v1.js` against
  `_zensu_adoption_refusal_remedy` in `zensu-session.sh`.
- **Tail:** `GENERIC_ADOPTION_TAIL`, `OPTED_OUT_ADOPTION_TAIL`, `INCOMPLETE_ADOPTION_TAIL`,
  kept as constants (not a map) because the remedy pin reads every `'token': 'sentence',`
  line as a remedy arm. Remedy and tail join as `remedy; tail.` in the `.*` gate and in the
  Stop hook's four release arms. The two named shell scopes put
  `The record is NOT damaged and NOT missing;` between them, and that join is unpinned.
- **Limit clauses:** `ORPHAN_LIMIT_CLAUSE` and `PRUNED_DOWNGRADE_CLAUSE` are rendered by the
  gate's typed arm AND its fallback arms, and are spelled word for word in the
  `incompatible-runtime` and `pruned-plugin-root` scopes; the pin checks both the render
  sites and the shell text. `lineageCause` / `prunedCause` / `UNBOUND_ADOPTION_REMEDY` are
  the gate's other shared spellings.

The `opted-out` remedy tells the model to report and ask the user, never to run
`--confirm` itself. The shell side's public, shape-checked wrappers are
`zensu_session_adoption_attempt` / `_remedy` / `_tail`. The token grammar has one JS owner,
`SAFE_TOKEN`; its shell twin `ZENSU_SAFE_REFUSAL_RE` is not pinned against it. Every refusal
screen fails closed: a module that will not load screens every token out, and an empty
shell pattern refuses rather than matching everything.

**Audience.** `_zensu_deny_audience` answers `main` or `child`. A child keeps the cause, the
verb and the token and ends on `ZENSU_ADOPTION_CHILD_CLOSE`, the twin of the gate's
`ADOPTION_CHILD_CLOSE`; the `adoption-incomplete` child form ends on its own retry sentence.
An unknown principal gets `main`: a child shown the main wording still cannot run the
command, while the main thread shown the child wording loses its one in-place remedy. The
seam pin matches the gate's MAIN guard as the whole line and requires each child close to
follow its MAIN block directly; `AUTO-26` drives both audiences through the lineage
fallback arm with the adoption module removed from the executing root, and `AUTO-26b`
through the pruned fallback arm on the same root.

## Disclosure

`renderAdoptionNotice` serves the model/user channels: the gate's announcement, the
`systemMessage` of a gate deny that follows an adoption, and the adapter's `systemMessage`
plus `additionalContext`. Its closing follows the call: `denied: true` closes it on the deny
that followed the adoption rather than on "nothing else to do", and an orphaned adoption
closes on the adoption alone, because its orphan clause names a directory still to
re-create. `operatorLine` serves every process
that performed an adoption and has no such channel. The binder's `bindAndDisclose` is the
ONE bind-and-disclose policy for its CLI mode and the in-process evidence hook: it writes
the operator line under the caller's own lead-in, on the success path and when the strict
re-read then fails (`performedAdoption` reads the verdict off the error). The four screens
are `safeVersion`, `safeProvenance`, `keptName` and `leaseClause`; `provenanceText` adds
the provenance cause. `SAFE_PROVENANCE` admits no slash, because an error message is where
a path arrives. The lease clause reads the count before choosing its sentence, so a
refused sweep is never announced as "0 set aside". `doctorPointer` is conditional per
provenance: only a `recorded` adoption wrote the history entry the doctor renders.

The `.*` gate announces an adoption only when its own process performed it, on an ALLOW only
(`judgePrincipal` returns the violation and `main` decides once), with `systemMessage` for
every principal and `additionalContext` for the main thread alone. When its bind adopted
and the call is then DENIED — a missing workflow baseline, a strict re-read that no arm
relaxes, or the capability deny `judgePrincipal` returns — the deny names the adoption
after the cause (`denyAfterAdoption`: `performedDisclosure` for the reason,
`adoptionNotice` for the `systemMessage`), because with provenance `no-workflow-document`
the doctor has no entry, the kept record is otherwise the only trace, and the gate wrapper
discards stderr. The REASON follows the audience rule the adapter's model copy follows:
the main thread gets `operatorLine`, every other principal `confinedOperatorLine`, the
version pair alone. The full sentence names the superseded record, whose basename is the
session selector confined contexts withhold, and its lease clause can name
`/zensu:adopt-session --confirm`, which writes the immutable record. The `systemMessage`
is user-facing and carries the whole notice for every principal. The seam pin holds the
renderer choice, the audience expression, the bind-failure deny helper and the capability
deny to their spellings; `AUTO-27`, `AUTO-27b` and `AUTO-24` drive the main, child and
capability-deny halves.

The lease sweep of a SERVED answer — `adoptForHook` sweeps every one, after a sibling's
adoption and on every bind of a served record whose recorded project root is gone, where
no adoption happened — is disclosed only when the sweep did something a reader must hear
about: it set leases aside, was refused, or left leases stuck. `sweepWorthReporting` is
the one predicate, and `servedSweepLine` names the served record, never a sibling's
adoption, because the verdict cannot tell the two cases apart. Five surfaces carry it:
`servedSweepLine` under the binder's lead-in (`bindAndDisclose` reads it off
`binding.servedSweep` or `error.servedSweep`); the `.*` gate, whose wrapper discards
stderr, as a `systemMessage` for every principal on an allow and on a deny that follows
no adoption, plus `additionalContext` for the main thread on an allow
(`servedSweepNotice`, read off `trusted.servedSweep` or `error.servedSweep`, which
`revalidateSessionContext` re-attaches when the workflow check after the bind throws);
the adapter's failure message when the strict re-read after a served answer still fails;
the lease clause of the served notice; and the `--confirm` report's already-served arm,
which reports the sweep instead of saying nothing was changed and names a refused sweep
as refused rather than completed. `AUTO-29` drives the binder and the gate in both
directions.

On the ordinary flow a UserPromptSubmit hook binds first after `/reload-plugins`, so a SHELL
hook performs the adoption and prints nothing on allow. The user then sees it through the
binder's stderr line (delivery unverified) and the doctor's `runtimeAdoptedRow`, which
shares the provenance rows' single read (`sharedWorkflowRead`), parses the version pair
through `parseAdoptionReason` and takes the kept name from `supersededRecordName`. The
binder exports `ZENSU_SESSION_ADOPTED` (`recorded -> executing`, or empty) for the planned
install-lineage notice hook; no hook consumes it yet. Hooks that discard the binder's
output leave an adoption traceable through the doctor and the kept record alone:
`grep -rn 'zensu_bind_hook_session' hooks/` and judge every hit that redirects stderr. Six
sites discard it at the time of writing — the reviewer-spawn grant, both browser-consent
hooks, the autopilot resume hook, the worktree-keep UserPromptSubmit hook, and the
worktree-keep anchor both worktree-keep lifecycle hooks share — but that is a census; the
grep is the rule.

## Operator-facing accounts

Every surface below states what the automatic path does, and each moves with it:
`docs/session-control.md` "Unbindable sessions" (the adoption paragraph, including its
binding-hook roster and its disclosure channels, and the `.*` gate row of the per-gate
table), `docs/gates.md`, `docs/tdd-manager-workflow.md`, `docs/operations.md`, the
`hooks.sessionAutoAdopt` and Stop-hook rows of `docs/configuration.md`,
`config.example.json`, `README.md`, `skills/adopt-session/SKILL.md` (the entry-level
tokens and the deny after an adoption that landed) and `skills/doctor/SKILL.md` (the
adoption row). This is a census, and the rule is the search:

`grep -rlE 'sessionAutoAdopt|adopted automatically|automatic adoption' README.md docs skills config.example.json`

## Bounds

- It cannot move a running session onto a new version: a session keeps its install
  directory until `/reload-plugins` runs in it.
- It relaxes neither `runtimeLineageCompatible` nor `adoptableRecord`. A downgrade, a
  non-sibling checkout, a foreign store and a moved schema are refused as before.
- No bypass-ledger entry (adoption escapes no gate) and no record field (provenance is the
  `RUNTIME_ADOPTED` history entry).
- The opt-out is a session-writable config key and is not ledgered.
- The `adoption-refusal` probe is a second node spawn, on the deny path only.
- A recorded project root that is gone under a lineage this installation serves runs the
  adoption path on EVERY bind: the strict read fails, the probe's orphan read measures the
  runtime digest, `adoptForHook` runs the idempotent lease sweep, and the `.*` gate's
  relaxation then performs its own orphan read — two digest walks and one sweep per tool
  call where there was one walk. The cost is unmeasured. Memoizing the digest per process
  was declined: the core's own suite measures a tree, edits it and measures again inside
  one process.
- In that same state a refused or stuck lease store is reported on EVERY bind that sweeps
  it — the binder's stderr line, and the `.*` gate's `systemMessage` on every tool call —
  for as long as it persists. Nothing latches it: a persistent fault the user must repair
  is what the disclosure exists for, and a store the sweep finds clean stays silent.
- Not executed end to end: the `adoption-incomplete` scope through a real lost race (the
  emitter and the routing are driven with a stubbed wrapper, and the Stop re-bind with a
  stubbed session library in `AUTO-28`), and the `.*` gate rendering `lock-timeout` or
  `adoption-failed`.
- Windows is unmeasured: the upgrade suite is the last entry of `windows-shard-2`. Do not
  raise the cap before a green Windows run supplies a figure.

## Tests

`tests/structure/test-versioned-plugin-upgrade.sh` grades the LAST COMMIT. `OPT_OUT_CONFIG`
is passed PER DRIVE as a command-scoped `ZENSU_CONFIG=` prefix and never exported: a
lineage or pruned deny row added without it adopts the shared record on its first drive,
and every later row then grades a served session. `HERMETIC_CONFIG` (an empty object) is
exported so no drive reads the runner's own `$HOME/.zensu/config.json`. The default-path
rows are the `AUTO-*` family; name it as a family, never by an endpoint. The fixture-free
emitter rows run at the HEAD of Part E, so a truncated Windows run costs session-minting
rows rather than the only executed cases of the shell emitter's scopes. The report's
`main()` takes a `deps` seam (request builder, core, adopter) that its unit file drives for
the `--confirm` arms, the preview arms and the provenance branches.

## Version

`patch`: no schema field, no strict key set, no hook added or re-matched, a new key read
permissively by a new reader, no attestation change, and the gates deny strictly less.

## Port-relevant

Core half: the module's ladder with its crash-resume rung, the sticky-`false` combining
rule over the layers a host hands it, the four screens, the renderers built over the
injected core, `SAFE_TOKEN`, `STATE_NEUTRAL_REASONS` and `establishesNamedState`, plus the
core's typed errors, `ADOPTION_PROVENANCE`, the reason grammar, `supersededRecordName` /
`supersededRecordFile`, and the state `adoptableRecord` attaches to refusals. Host half:
`configLayers` (it reads this host's variable names and config layout), the opt-in table,
`bindAndDisclose` and its lead-ins, the `adoption-refusal` mode and its wrappers, the gate's
copies of verb, remedy, tail and the two limit clauses, the audience input, the token
argument of the named and generic scopes, the `adoption-incomplete` scope and the Stop
re-bind, the adapter's `serveOrAdopt`, the doctor's adoption row, and the membership of
`ZENSU_SESSION_ADOPTED` in every unset and export list of `zensu-session.sh` plus the
pre-source unset in `session-start-autopilot-resume.sh` — an export line without those
lists carries a stale pair into the next hook. `zensu-codex`, `zensu-kiro` and
`zensu-antigravity` were NOT included in this change.
