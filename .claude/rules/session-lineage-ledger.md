---
paths:
  - "skills/session-trail/scripts/session-lineage-v1.mjs"
  - "plugins/session-hub/skills/session-trail/scripts/session-lineage-v1.mjs"
  - "tests/structure/session-lineage-v1.test.js"
  - "tests/structure/test-session-trail-lineage.sh"
---

# Session Lineage Ledger (`skills/session-trail/scripts/session-lineage-v1.mjs`)

**Two copies.** `/zensu:session-trail` is PLM's frozen copy of this skill; the
`session-hub@zensu` companion carries the maintained one as `/session-hub:session-trail`.
`.claude/rules/session-hub-companion.md` says which copy each check grades.

_Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

**Not the same "lineage" as either section above it.** §"Runtime Lineage
(`version_type` is load-bearing)" is about whether an EXECUTING PLUGIN may serve a
Session Control record it did not mint, and §"Adopting a Record Across a Lineage
Break" is the explicit exit from that refusal. This section is about a chain of
CLAUDE SESSIONS handing work to each other, has no relationship to plugin versions,
and shares no code with either. The three collide on one English word; a change to
one of them lands in none of the others.

`/zensu:session-trail` records every takeover as one edge in a **machine-wide,
multi-writer** store, and this module is the single source of truth for its schema,
its layout, its refusal table and the chain walk. It is the reason the skill has a
write channel of its own at all.
`release --apply` is the one verb that changes state outside the ledger, and it does so
through `retireAnchors` in `hooks/lib/worktree-keep-v1.js`, never by a write in
`trail.mjs`; §"Worktree Keep" owns that path.

**The store is a DIRECTORY of one record per edge, never a shared append-only file.**
Six windows write it concurrently and atomic append behaves differently on Windows
than on POSIX; an exclusive `wx` create of a uniquely named record needs no lock and
cannot interleave. `labels.json` is the one exception and lands by O_EXCL temp plus
rename — it is a read-modify-write, so **concurrent labels can still lose an update**;
the rename removes only the torn-file half of the hazard.

**Two identity routes, deliberately independent.** The account comes from the desktop
store, whose top-level directory IS the `accountUuid` (measured 2026-08-21 three ways:
`oauthAccount.accountUuid` in `~/.claude.json`, `lastKnownAccountUuid` in
`Claude/config.json`, and `ant-device-registry.json`'s key set). The window comes from
the process ancestry up to the owning `Claude.app` process. Only the macOS path is
MEASURED; the Windows and Linux candidates are probed and can win — `ccdStoreCandidates`
tries `$XDG_CONFIG_HOME/Claude` and `~/.config/Claude` there — they are UNVERIFIED, not
unreachable. Where no candidate exists the account is `null` and the ancestry still
groups by window. Beside those defaults the list takes every Zensu Session Hub profile store and
every store `ZENSU_CCD_EXTRA_STORES` names, and every accepted store is read
(`.claude/rules/session-trail-targeted-lookup.md`). `ZENSU_CCD_STORE` overrides the probe list and
is AUTHORITATIVE, and `lineage --diagnose` prints every candidate with its verdict. `storeCandidates` in
`hooks/lib/linked-session-v1.js`, which resolves a linked session's parent for the delivery route,
applies the same override rule and reads the same named and Session Hub profile stores, so a change
to any of them here moves that function too (`.claude/rules/session-delivery-route.md`).

**Session-trail reads the desktop store under the resolver's owner and mode rule.** On
every platform it refuses a symbolic link where a folder or a record is expected, a record
that is not a regular file and a record larger than 8 MiB, and off Windows also a store,
account or organization folder and a record that another uid owns or that carries a group
or other write bit, through `hooks/lib/desktop-store-read-v1.js`, the module
`hooks/lib/linked-session-v1.js` loads too. The reason is that store values steer steps no one confirms: the takeover plan pass
measures folders the records name, `isArchived` lifts the release busy gate, and the
store's account picks the saved presets and the account an edge endpoint records, so an
account folder the check refuses leaves that endpoint's account `null`. The readers, the
refusal reasons, the costs and the pins are in
`.claude/rules/session-trail-targeted-lookup.md`. The resolver answers a refusal its own
way: a refused store or folder skips its candidate, and the session answers `none`
(`no-session-store`) only when no other store passes; a refused own record answers `none`
(`own-record-refused`), while a refused parent record answers `linked` without a parent root
(`parent-record-unavailable`), so that session stays linked and inherits nothing
(`.claude/rules/session-delivery-route.md`).

**The edge's `repo` comes from the HANDED-OVER work, never from the recording
process's cwd.** The documented takeover route runs from a window in a different repo,
so deriving it from the recorder would file the edge under the taker's repo and make the
default repo-scoped `lineage` render nothing where the work lives — an empty answer
indistinguishable from "no handover happened".

**Sites that move with the schema:** the module, `trail.mjs`'s wrappers, the `v1`
segment quoted in the data-source table of `skills/session-trail/SKILL.md`, `tests/structure/session-lineage-v1.test.js`,
and the `v1` path spelled throughout `tests/structure/test-session-trail-lineage.sh`.

**THREE couplings fire in the UNOBVIOUS direction**, the same shape §"Gate-Disable
Prefixes" records for G12 — an ordinary edit elsewhere reddens a suite named for
something else, and nothing points at it from the side that changes:

- `tests/structure/test-windows-portability-guards.sh` binds
  `SESSION_LINEAGE="$ROOT/skills/session-trail/scripts/session-lineage-v1.mjs"` and
  hardcodes eight source literals out of `readBoundedFile` — both platform gates, the
  `fs.openSync` flag expression, the `fstatSync` line and both refusal returns. So
  rewording that reader, or normalising a quote style in it, reddens a suite named for
  Windows portability.
- `package.json` is asserted by four checks in `tests/structure/test-session-trail-lineage.sh`
  (`L41` the exact `c8` pin, `L41a` that the coverage run drives all three suites, `L41b`
  the include glob's quoting, `L41c-control`). So an ordinary dependency bump or npm-script
  edit reddens the session-trail lineage suite.
- The `L70` family in that same suite grades §"Takeover Destination" content, not ledger
  content, and it binds FOUR `trail.mjs` constants — not two — plus THREE `cmdAdopt` literals:
  `apply --stat` is a `CARRY_OVER` literal, `Never continue in a worktree` is
  `ADVICE_LEADS.active.present`, `This session is not archived, and the recorded directory
  is gone` is `ADVICE_LEADS.active.gone` — bound by `L70g` — and `-b 'claude/<name>-cont'`
  is `TAKE_YOUR_OWN`. `L70` and `L70g`
  additionally bind `whereAdviceLines`'s own `'<their worktree>' = `, `Replace '<their worktree>' TOGETHER WITH the quotes` — and the blanket spelling `Replace each placeholder TOGETHER WITH` is a NEGATIVE
  needle in three checks, so restoring it would
  redden them --
  and `recorded worktree (gone) = ` lines — plus three more literals: the
  unmapped-placeholder sentence, the `NOT the worktree named on the receipt line above` trap
  and the gone leg's `shown for reading, not for pasting` caution — and `L70a-src` greps both
  that renderer's source and `cmdAdopt`'s. **Two members bind SYMBOLS rather than emitted
  text, which widens the blast radius from a reword to a rename:** `L70n` takes comment-stripped
  OFFSETS out of `cmdTakeover` and `cmdAdopt` and requires every throwing render
  (`worktreeAdvice(`, `substitutionRuleLines(`, `adviceBlock(` in the first; `whereAdviceLines(`
  in the second) to precede the durable write (`recordTakeoverEdge(`, `ledgerWrite(`), so
  renaming ANY of those six — or moving a render back below its write — reddens this suite; and
  `L70o` requires the adopt receipt's ledger path to be spelled `flatPath(path.join(LEDGER_DIR`.
  So rewording any of those constants in `skills/session-trail/scripts/trail.mjs`, or
  restructuring that function, reddens a suite named for the lineage ledger. This is the
  third member.

**The DISPATCHER owns command-flag scoping, and two tables must stay key-identical.**
`parseArgs` accepts every flag for every command, so without that scoping a flag belonging
to another verb parses and is then ignored — `takeover x --forget y` records an edge and
names neither flag, and `adopt --no-record` writes the machine-wide record the flag says it
is skipping. `COMMANDS` and `COMMAND_FLAGS` sit adjacent in `trail.mjs` for that
reason: `COMMANDS` drives the routing AND the usage string, `COMMAND_FLAGS` must carry
a row for every one of its keys, and `refuseForeignFlags` fails closed on a missing row
rather than defaulting to `[]`. The unknown-command refusal stays FIRST, so a typo is
reported as a typo. Two entries are DELIBERATE accept-and-ignore, not oversights:
`--force` on `list` and `limited`, which `references/commands.md` documents as a survey rule —
`instances` emits no verdict and so refuses it. `L56h` derives both key sets from
source and compares them, so an eleventh command cannot be added to one alone;
`test-session-trail-skill.sh`'s `T16` and its `json-mode-order` guard read `COMMANDS`
and `handler(opts)`, so a change to the dispatch shape reddens BOTH — they are
part of this coupling, not collateral.

**Every disclosure has ONE owner and must reach BOTH carriers.** The defect class here
is a read that FAILED rendering exactly like a read that found nothing, one code path
over: `truncatedNote` owns the disclosure of `led.truncated`, and `renderLedgerFault`
owns `directoryError` and `schemaNewer` for the listing branch and its `--where` sibling
alike — a `--where` render that disclosed neither would still close with the `--backfill`
offer, the one line in the file that mints machine-wide guesses. The same rule binds the
walk's own bounds, `truncated` and `revisited`, which must reach the `--where` and the
listing rendering on both carriers. A new renderer calls the owner; it never writes
the sentence again. `lineage --backfill --apply` is gated on a capped read for the
reason it is gated on an unreadable record: the duplicate guard is built from that read.

**The ceiling is a BOUND on the ancestor walk, never a candidate for it.**
`ledgerPathUnlinked(dir, stopAt)` refuses a symlink at any component between `dir` and
the caller's ceiling — `lstat` declines to follow the FINAL component alone, so without
that refusal a link at `session-lineage/` or `v1/` resolves as an ordinary intermediate one
and `lineage --forget --apply` unlinks a record OUTSIDE the ledger. The ceiling ITSELF is
tested first and never lstat'ed, matching `ensureLedgerDir`, which breaks before pushing
it into its checked set. Judging it instead would make the two halves disagree about one tree:
a symlinked `~/.claude` is the ordinary shape under a dotfile manager, so the write path
would keep landing records while every read answers `ESYMLINK` and the only retraction
channel refuses forever. **All four readers of this store take the ceiling** — `readEdges`,
`removeEdgeFiles`, `readLabels` and `schemaLedgerCensus`, behind `otherSchemaLedgers` — because each one's WRITER
already refuses that tree, and a reader that did not would make read and write disagree. **Every
INTERNAL caller must thread it too**: an `updateLabels` that passes the ceiling to
`writeLabels` and omits it from its own `readLabels` makes the two halves of one
read-modify-write disagree about the same tree.
`readLabels`' guard is CONDITIONAL — with no ceiling it makes no ancestor check at all,
unlike `readEdges`, which still makes the leaf check — so an omission there is silent.
`session-lineage-v1.test.js` pins the write side, the read side, the delete side and the
discriminating case that a component BELOW a symlinked ceiling is still refused;
`test-session-trail-lineage.sh` L59a/L59b drive the same root end to end.

**Accepted residual, stated rather than implied:** `removeEdgeFiles` checks the ancestors
ONCE and each iteration then re-derives its path, so a directory component swapped for a
symlink after the guard resolves through the new link. The per-file `lstat`+`unlink` pair
is safe on its own, because `unlink` never follows a final symlink — the exposure is the
directory swap, not the leaf — and Node exposes no `unlinkat`/dirfd, so it cannot be
closed in this shape. `ensureLedgerDir` documents its own analogous check-then-create
window the same way.

**The chain walk takes ONE source of successors.** `walkChain(sessionId, source, maxHops)`
accepts an edge array or a prebuilt `indexBySource` map, never both: once an index is
supplied the array is dead, so a caller could hand it two that disagree and the walk would
follow the index silently. `chainRoots(edges)` builds its own index for the
same reason, and there a pair would be worse than dead: `edges` decides which roots exist
while the index decides where each chain goes. Deriving the array back out of a map is
rejected — flattening groups edges by source key, and the DISCOVERY ORDER of roots is
the order chains render in. Measured with the shared index
`cmdLineage` uses: n=5000 renders in 4 ms; rebuilding the index per root reproduces the
quadratic shape at 1834 ms, which is the control that keeps the first figure meaningful.

**The two ledger writes land by DIFFERENT primitives, and the difference is the
guarantee.** An edge record lands with `fs.linkSync`, which refuses a name that already
exists — that is what makes the store append-only. `labels.json` lands with
`fs.renameSync`, which replaces the whole document by design because it is a
read-modify-write. Never describe both as landing by rename: that states the opposite
guarantee for one of them. `T11b`'s write-site allowlist names `linkSync` for this
reason, and its control loop must plant one per named primitive or the branch can be
deleted with every control green.

**Sites that move with the ENDPOINT field set**, which is separate: `makeEndpoint` owns the shape and `ENDPOINT_KEYS` is derived from it rather than
hand-listed, but three PROSE copies are not derived — the persisted-field sentence in
`skills/session-trail/references/disclosure.md` and its two `--json` disclosure paragraphs. Those are
a PRIVACY claim a reader decides from, so an over-list is as wrong as an under-list;
`test-session-trail-skill.sh` T26 pins both directions, scoped to the ledger lines
because the data-sources table legitimately documents `cwd` and `title` for three
OTHER files.

**Sites that move with a new `print(JSON.stringify(` payload in `trail.mjs`:** every
one must carry `skipped: SKIPPED`, and `test-session-trail-skill.sh` T22 pins the
COUNT as well — a new payload fails that suite until the expected number is raised,
which is the registration, not an obstacle. Every payload that reports the ledger's
state must additionally carry `ledgerTruncated`, `ledgerError` and `schemaNewer`
together; `L36b` counts the first against the second so a payload cannot report two
of the three.

**Permission posture, stated because nothing enforces it.** The ledger write happens
INSIDE the node process, so no PreToolUse hook sees it: not `pre-write-secret-scan.sh`,
not `pre-edit-tdd-reminder.sh`, not the Bash source-write gate. It is the only
persistence in this skill the user never approves a Write for, its target is whatever
`--config-dir`/`CLAUDE_CONFIG_DIR` names, and what it persists includes both
endpoints' absolute worktree path and branch. `--no-record` is the opt-out, and
`lineage --forget <session> --apply` is the only way a landed record leaves. Step 0
in `skills/session-trail/references/takeover.md` states this where the decision is taken;
keep it there, not only in the Safety section of `skills/session-trail/SKILL.md`.

**The v-partition is REPORTED, not read.** `ledgerPaths` partitions the
store by `v${LEDGER_SCHEMA_VERSION}` while `classifyEdge` ALSO judges `schemaVersion`
inside a record, and the partition wins — so `SCHEMA_NEWER`/`SCHEMA_OLDER` remain
reachable only from a hand-planted record. `otherSchemaLedgers` enumerates sibling `v*`
directories, and a build whose own directory is empty beside a populated one reports a
MIGRATION instead of "No handover has been recorded yet", which would be followed by an
offer to reconstruct guesses for handovers the machine still holds as measurements, one
directory away. It does not
READ those records, and closing that still means dropping the derived segment or
teaching `readEdges` to enumerate siblings. `takeover`'s linked-session decision holds
every start while a directory of a NEWER schema holds records or could not be inspected
(`.claude/rules/session-trail-linked-sessions.md`); that is a hold, not a read.
`schemaLedgerCensus` owns the enumeration and reports both kinds, the directories it
counted and the ones it could not inspect; `otherSchemaLedgers` returns the counted
ones alone, which is what the migration disclosure of `lineage` reads.

**`recordedAt` is judged by SHAPE, not by parseability, and the two are not close.**
It is the sole ordering key at four sites — the dedupe survivor, the branch `walkChain`
prefers, the `--where` answer and the rendered order — and every one of them ranks it
as a plain string, which is only chronological for the fixed-width UTC spelling
`toISOString()` produces. A `Number.isFinite(Date.parse(...))` guard judges VALIDITY, and
measured against it: `"July 4, 2026"` parses, sorts ABOVE every real
stamp and is actually earlier; `"9999"` — the value the ordering comment itself names
as the motivating defect — is accepted; `"2026-02-31T00:00:00.000Z"` is
accepted as a February date meaning 3 March. The store is append-only and machine-wide,
so one such record wins every ordering decision permanently. `isIsoInstant` is the one
predicate, and the ordering comment beside `recordedAtKey` points at it rather than
asserting the shape it depends on. All three writers produce that spelling
(`nowStamp()` and the backfill's `toISOString()` of the earlier of the successor's
modification time and the moment it runs), and none stamps the future, so the tightening
refuses nothing this tree writes — a fourth writer that does not is refused at READ
time, which loses the record rather than mis-ordering the ledger. `L13g` pins the
backfill's clamp, because an unclamped stamp of the successor's modification time lets a
transcript modified more than a day ahead mint a record the skew bound refuses.

**A tightened field validator can make a neighbouring test vacuous.** A fixture that
passes a bare ordinal (`'1'`, `'2'`) as `recordedAt` is refused for its STAMP once the
shape is enforced, so the NUL-session-id case would keep asserting `MALFORMED` while
never reaching the guard it is named for; its fixture carries a real instant. When a
validator moves, re-read every case that asserts the same refusal reason for a
different cause.

**There is ONE display-bound family, and it is `flatPath`/`instanceId`/`sessionTag`/
`briefPath`**, for bounding the value a reader retypes as a selector. A raw
`showId(x).slice(0, 8)` is not equivalent: measured, it renders a zero-advance character
as a SPACE, so
`a<ZWSP>bcdefgh` comes out `"a bcdefg"` — seven real characters in an eight-column
field — and an ESC byte comes out `"abc [31m"`. `instanceId` strips the zero-advance
class FIRST and the ordering is the whole point. The thirteen call sites of an
8-character id render through `sessionTag`, so a `list` row and an `instances` row
name the same prefix, which is the only thing an 8-character id is for.
`test-session-trail-skill.sh` T22c pins the call-site floor and T22c-a pins that a raw
slice does not come back.

**`extractTouchedFiles` must NOT bound the path, and the reason is ORDERING rather
than trust.** Every renderer strips the worktree prefix with `rel(t.path, r.wt)`, a
string comparison against the RAW `r.wt`; a path bounded at extraction no longer
shares that prefix, so `rel` returns the absolute path and the row renders whole. It
measures worse than that: with a worktree carrying a newline the briefs emit no
`## Files the session touched` rows at all, which `test-session-trail-verdict.sh` W8
catches. All three renderers bound the value themselves — `flatPath` in
`show`, `briefPath` in both briefs — so an early bound is redundant as well as wrong.
The general rule: bind AFTER the last comparison that uses the raw spelling, never
before it.

**Deferrals this ledger carries, each accepted rather than overlooked:**

- **The confidence tier is not authenticated.** `confirmed` is a field in a JSON file
  every session on the machine can write, so it records what a WRITER CLAIMED, never
  what happened. The order gates ranking, not trust. Authenticating it means a MAC
  over the record, which is a schema change.
- **A concurrent label can still be lost.** `updateLabels` owns the whole
  read-modify-write and re-checks the file's identity plus size immediately before
  landing, and it REPORTS a failure to land instead of printing success — but it is a
  bounded retry, not a lock. Two windows can still interleave; the window is narrowed,
  not closed.
- **A window label written before incarnation keying stops resolving.** The key is
  `<pid>@<start>` (§ the `label` row in `references/commands.md`), so a bare-pid key matches
  nothing. That is the safe direction — the alternative is the label resurfacing on
  an unrelated window that inherited the number — and `label --remove <pid>` clears the
  old form, which is the only thing that can still name it.
- **Two properties are pinned at SOURCE because no behavioural check can reach them
  from a sandbox**, and each says so in its own check comment: the `msysDrivePrefix`
  routing (identity off win32 by construction) and `cmdLabel` landing through
  `updateLabels` (the loss window needs two processes interleaving). Source pins rot
  differently from behavioural ones — each carries a control that fails if its own
  scan matches nothing. **`windowOf`'s basename match is driven, not pinned at source.**
  It reads as unreachable because every fixture starts `node` from a shell, so no
  ancestor ever matches; the `window-probe` command takes the table as a parameter over
  stdin, so `L63`–`L63f` drive the rule that decides the answer, INCLUDING the negative
  case: a path that merely lives under a claude-named
  directory (`~/claude-tools/bin/watcher`) is not a window, with the same tree matching
  once the name moves into the basename. A property listed here as untestable, once a
  seam makes it testable, is a stale claim rather than a residual — check this list
  when a seam lands.
- **The record-count cap is proven COMPUTED but not proven end-to-end.** The unit suite
  plants `MAX_EDGE_RECORDS + 5` records; the shell checks prove `ledgerTruncated`
  travels on every ledger-aware payload. Nothing drives a real over-cap ledger through
  the CLI, because 20 000 files is a Windows-budget problem, not a correctness one.

**`tests/structure/test-session-trail-lineage.sh` runs on `windows-shard-8` with `timeoutMs:
600000`** in `tests/profiles/windows-ci.v1.json`, alongside other suites. The figure that
anchors the cap is run 33054489866: `PASSED session-trail-lineage (154673ms)`, 280 PASS /
0 FAIL / 4 SKIP, with every window-namespace check green and no `probe-failed` line. The suite
keeps growing, so read its own reported total rather than a numeral here, and replace these
figures from the next green Windows shard.

**Size a Windows ceiling from a GREEN wall clock on the shard**, never from the macOS time,
from a projection or from a run that measured a stalled subprocess, and never raise it
speculatively: raising it without a measurement trades a visible `TIMED_OUT` for a silent tail
truncation. A ceiling set AT the measurement is already breached — one sample is a lower bound
on a distribution, never a bound on the next run. A ceiling set from a projection is only as
good as what the samples measured. And a ceiling set far ABOVE the measurement stops being a
tripwire at all, so keep it below what a known regression costs: 600000 is 3.9x the measured
figure and deliberately BELOW the ~650 s a reintroduced probe stall would cost, so that
regression trips the cap instead of merely making CI slow. A ceiling is not portable between
two suites that share an `id`.

**A suite receives the shard's remaining budget, not its own `timeoutMs`** — the failure
§Host-Refused Reviewer Spawn records ("read the shard's remaining budget", not the suite's
`timeoutMs`): a suite that runs after its shard's envelope is spent reports `TIMED_OUT`
without being slow. Whether the cap or shard 8's envelope binds this suite depends on the
shard's other suites, so re-derive it whenever a suite joins the shard; their figures are in
`.claude/rules/windows-budget-best-solution-first.md`. A shard abort silently truncates the
tail of whichever suite is running. Moving a suite between shards is three files in one
commit — `tests/profiles/windows-ci.v1.json`, the matrix in `.github/workflows/ci.yml`, and
`expectedProfiles` in `tests/structure/windows-ci-contract.test.js` — and the contract test
fails loudly when they disagree. These caveats live here and NOT in the manifest:
`tests/run-profile.js`'s `SUITE_KEYS` rejects any key outside
`{id, runner, path, args, timeoutMs}` and aborts every Windows shard at manifest load, so a
`note` field there is a CI-wide outage rather than documentation.

**The win32 process probe is the suite's Windows cost driver.** `processTable()` in
`skills/session-trail/scripts/trail.mjs` runs `Get-CimInstance Win32_Process` and keys every
window label on the pid plus its start time; when it yields nothing, `windowKey()` answers
null, no `labels.json` window entry is written, and L32c-control, L35, L35c, L52-control, L52
and L52a fail against a file that was never created. Its known failure is a STALL, not an
error: one full suite run enters `processTable()` **115 times** (counted on macOS,
2026-08-27), so a probe that hangs to its timeout dominates the suite's Windows wall clock.
The probe timeout is therefore 5000 ms and goes DOWN, not up, when the probe stalls: a
stalling probe then stays inside ~650 s while a working one still fits. What makes it fast is
the startup-cost control in the program itself — `$PSModuleAutoLoadingPreference='None'` plus
an explicit `Import-Module CimCmdlets`, a four-column `SELECT` instead of whole instances, and
`LOCALAPPDATA` restored so the module analysis cache is not rebuilt on every start. The
`-EncodedCommand` spelling removes a real argument-mangling hazard, so keep it, but it does not
fix a stall. A probe environment without `PATH`, `windir`, `SystemDrive` or `ComSpec` —
`Get-CimInstance` reaches WMI through the provider host under `System32\Wbem` — was ruled out
as the cause, and the `PSModulePath` pin the security comment exists for stays.
**The uncompromised fix is none of these**: it is not spawning powershell.exe 115 times. A
short-TTL process-table cache in the config dir would collapse that to a handful and would pay
off for every Windows user of this CLI, not just for CI. It carries its own containment and
symlink rules, so it is named here rather than smuggled into a CI repair.

**Probe diagnostics.** `probeFault()` records the exit code, signal and first stderr line,
and `processStartTimeHealth()` renders it as `probe-failed — …`; a stall reads
`probe-failed — ETIMEDOUT signal SIGTERM`, with nothing on stderr. If the window-namespace
checks go red, read the `START TIMES` line in `lineage --diagnose` before theorising. A
diagnostic needle must match what its channel prints — the text channel prints `START TIMES`,
not `process start` — because a diagnostic whose needle is never exercised is worse than
none: it answers confidently.

**Two fixture shapes in that suite pass on POSIX and fail on Windows**, and both are
the MSYS/native split this file already documents for `bash-source-write-parse.js`.
Neither is a product defect — the product is native on both hosts — but both make
real checks fail for a reason unrelated to their subject:

- **`$$` is not a pid `process.kill(pid, 0)` can see.** Under Git Bash it is an MSYS
  pid from a different namespace, so the shell's own pid never reads as live and
  every liveness-dependent check (`L8b`, `L16`, `L24`) would fail on that premise
  rather than on its own. The suite spawns a detached node helper and takes the pid
  NODE reports, which is in the namespace the product consults on every host, and
  retires it in the EXIT trap. `L0b` is the premise check that names this instead of
  letting three checks fail opaquely — keep it.
- **A hand-written fixture record must carry the spelling production writes.** `L25`
  interpolated a shell path into an edge record while node's `process.cwd()` reports
  the native one, so repo scoping found nothing. Every path a shell writes into a
  fixture here goes through `hostpath` (`cygpath -m`), the same helper the path
  comparisons already used.

**The suite isolates by `--config-dir` and `$ZENSU_CCD_STORE`, deliberately not by
`$HOME`.** Its sibling `test-session-trail-verdict.sh` redirects the home directory
instead — and it does NOT skip itself on Windows: `trailrun` sets `USERPROFILE`
alongside `HOME` and that suite's own
V0 probe measures the PAIR, so the redirection succeeds where `os.homedir()` reads
`USERPROFILE`. §"Git Mutation Tables" says the WC block "will therefore run on
Windows", and the two paragraphs agree. Both suites
also unset `CLAUDE_CONFIG_DIR`, because `trail.mjs` honours it and `$HOME` is only a
fallback. With it exported, an invocation that does not name `--config-dir` resolves
the developer's real config root instead. A fixture read there finds no fixture
session, but not every writer needs one: `label` writes `labels.json` under the key it
is given, and `lineage --backfill --apply` mints edges from that root's own
transcripts. `takeover` without `--no-record` and `adopt` write an edge once their
selector resolves there, which `resolve()`'s substring tiers can do against a real
session, and the process names its own session through `CLAUDE_CODE_SESSION_ID`; the
L10 line sets that variable itself, so a copy of it supplies one. In the verdict suite
one `unset` above the first `trail.mjs` command covers every command the suite runs,
and it clears `ZENSU_CCD_STORE` too: the desktop-store probe honours that variable
ahead of `$HOME`, and `--config-dir` does not reach it. In the lineage suite
the unset is BELT, not the mechanism: `--config-dir` already outranks the variable in
`resolveRoots`, and the unset is what keeps that true for a check added later without
the flag. Exactly ONE invocation there omits it — the L10 case, whose whole subject is
that the variable is honoured — and `L28` pins that it stays exactly one, because a
second exemption is indistinguishable from a forgotten `env -u`.
