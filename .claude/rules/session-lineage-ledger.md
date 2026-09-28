---
paths:
  - "skills/session-trail/scripts/session-lineage-v1.mjs"
  - "tests/structure/session-lineage-v1.test.js"
  - "tests/structure/test-session-trail-lineage.sh"
---

# Session Lineage Ledger (`skills/session-trail/scripts/session-lineage-v1.mjs`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

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
write channel at all — before it, `trail.mjs` had none, and SKILL.md said so.

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
groups by window. `ZENSU_CCD_STORE` overrides the probe list and is AUTHORITATIVE, and
`lineage --diagnose` prints every candidate with its verdict.

**The edge's `repo` comes from the HANDED-OVER work, never from the recording
process's cwd.** The documented takeover route runs from a window in a different repo,
so deriving it from the recorder filed the edge under the taker's repo and made the
default repo-scoped `lineage` render nothing where the work lives — an empty answer
indistinguishable from "no handover happened".

**Sites that move with the schema:** the module, `trail.mjs`'s wrappers, the `v1`
segment quoted in `skills/session-trail/SKILL.md`, `tests/structure/session-lineage-v1.test.js`,
and the `v1` path spelled throughout `tests/structure/test-session-trail-lineage.sh`.

**THREE couplings fire in the UNOBVIOUS direction**, the same shape §"Gate-Disable
Prefixes" records for G12 — an ordinary edit elsewhere reddens a suite named for
something else, and nothing points at it from the side that changes:

- `tests/structure/test-windows-portability-guards.sh` binds
  `SESSION_LINEAGE="$ROOT/skills/session-trail/scripts/session-lineage-v1.mjs"` and
  hardcodes eight source literals out of `readBoundedFile` — both platform gates, the
  `fs.openSync` flag expression, the `fstatSync` line and both refusal returns. So
  rewording that reader, or normalising a quote style in it, reddens a suite named for
  Windows portability. (It already did: the module carried a double-quoted `"win32"`
  beside a single-quoted one, and the pin held the inconsistency in place.)
- `package.json` is asserted by four checks in `tests/structure/test-session-trail-lineage.sh`
  (`L41` the exact `c8` pin, `L41a` that the coverage run drives all three suites, `L41b`
  the include glob's quoting, `L41c-control`). So an ordinary dependency bump or npm-script
  edit reddens the session-trail lineage suite.
- The `L70` family in that same suite grades §"Takeover Destination" content, not ledger
  content, and it binds FOUR `trail.mjs` constants — not two — plus THREE `cmdAdopt` literals:
  `apply --stat` is a `CARRY_OVER` literal, `Never continue in a worktree` is
  `ADVICE_LEADS.active.present`, `This session is not archived, and the recorded directory
  is gone` is `ADVICE_LEADS.active.gone` — bound by `L70g`, and reworded once already when
  the previous needle came from the `survivor.gone` cell and reported a correct gone-leg
  render as a failure — and `-b 'claude/<name>-cont'` is `TAKE_YOUR_OWN`. `L70` and `L70g`
  additionally bind `whereAdviceLines`'s own `'<their worktree>' = `, `Replace '<their worktree>' TOGETHER WITH the quotes` — and the retired blanket spelling `Replace each placeholder TOGETHER WITH` is now a NEGATIVE
  needle in three checks rather than a bound line, so restoring it from this roster would
  redden them --
  and `recorded worktree (gone) = ` lines — plus the three literals that carry the P1 fix, the
  unmapped-placeholder sentence, the `NOT the worktree named on the receipt line above` trap
  and the gone leg's `shown for reading, not for pasting` caution — and `L70a-src` greps both
  that renderer's source and `cmdAdopt`'s. **Two later members bind SYMBOLS rather than emitted
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
`parseArgs` accepts every flag for every command, so a flag belonging to another verb
parsed and was then ignored — `takeover x --forget y` recorded an edge and named
neither flag, and `adopt --no-record` wrote the machine-wide record the flag said it
was skipping. `COMMANDS` and `COMMAND_FLAGS` sit adjacent in `trail.mjs` for that
reason: `COMMANDS` drives the routing AND the usage string, `COMMAND_FLAGS` must carry
a row for every one of its keys, and `refuseForeignFlags` fails closed on a missing row
rather than defaulting to `[]`. The unknown-command refusal stays FIRST, so a typo is
reported as a typo. Two entries are DELIBERATE accept-and-ignore, not oversights:
`--force` on `list` and `limited`, which SKILL.md documents as a survey rule —
`instances` emits no verdict and so refuses it. `L56h` derives both key sets from
source and compares them, so an eleventh command cannot be added to one alone;
`test-session-trail-skill.sh`'s `T16` and its `json-mode-order` guard read `COMMANDS`
and `handler(opts)` and BOTH went red when the if/else chain was replaced — they are
part of this coupling, not collateral.

**Every disclosure has ONE owner and must reach BOTH carriers.** The recurring defect
in this file is a read that FAILED rendering exactly like a read that found nothing,
and it kept surviving one code path over: `truncatedNote` was added when eleven
carriers of `led.truncated` were all inside `JSON.stringify`, and `renderLedgerFault`
was added when the listing branch disclosed `directoryError` and `schemaNewer` while
its `--where` sibling disclosed neither and still closed with the `--backfill` offer,
the one line in the file that mints machine-wide guesses. Same rule for the walk's own
bounds — `truncated` and `revisited` reached the `--where` rendering and were dropped
by the listing one on both carriers. A new renderer calls the owner; it never writes
the sentence again. `lineage --backfill --apply` is gated on a capped read for the
reason it is gated on an unreadable record: the duplicate guard is built from that read.

**The ceiling is a BOUND on the ancestor walk, never a candidate for it.**
`ledgerPathUnlinked(dir, stopAt)` refuses a symlink at any component between `dir` and
the caller's ceiling — `lstat` declines to follow the FINAL component alone, so a link
at `session-lineage/` or `v1/` was resolved as an ordinary intermediate one and
`lineage --forget --apply` unlinked a record OUTSIDE the ledger. The ceiling ITSELF is
tested first and never lstat'ed, matching `ensureLedgerDir`, which breaks before pushing
it into its checked set. Judging it instead made the two halves disagree about one tree:
a symlinked `~/.claude` is the ordinary shape under a dotfile manager, so the write path
kept landing records while every read answered `ESYMLINK` and the only retraction channel
refused forever. **All four readers of this store take the ceiling** — `readEdges`,
`removeEdgeFiles`, `readLabels` and `otherSchemaLedgers` — because each one's WRITER
already refuses that tree, and a reader that did not made read and write disagree. **Every
INTERNAL caller must thread it too**, which this sentence once implied and did not check:
`updateLabels` held the ceiling, passed it to `writeLabels` and omitted it from its own
`readLabels`, so the two halves of one read-modify-write disagreed about the same tree.
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
accepts an edge array or a prebuilt `indexBySource` map. It used to take both, and once
an index was supplied the array was dead — a caller could hand it two that disagree and
the walk followed the index silently. `chainRoots(edges)` builds its own index for the
same reason, and there the pair was worse than dead: `edges` decides which roots exist
while the index decides where each chain goes. Deriving the array back out of a map is
rejected — flattening groups edges by source key, and the DISCOVERY ORDER of roots is
the order chains render in. Measured after the change, with the shared index
`cmdLineage` uses: n=5000 renders in 4 ms, against the 1669 ms recorded before R10
removed the per-root re-index; rebuilding per root still reproduces the quadratic shape
at 1834 ms, which is the control that keeps the first figure meaningful.

**The two ledger writes land by DIFFERENT primitives, and the difference is the
guarantee.** An edge record lands with `fs.linkSync`, which refuses a name that already
exists — that is what makes the store append-only. `labels.json` lands with
`fs.renameSync`, which replaces the whole document by design because it is a
read-modify-write. SKILL.md claimed both landed by rename, which describes the opposite
guarantee for one of them. `T11b`'s write-site allowlist names `linkSync` for this
reason, and its control loop must plant one per named primitive or the branch can be
deleted with every control green.

**Sites that move with the ENDPOINT field set**, which is separate and was got wrong
once: `makeEndpoint` owns the shape and `ENDPOINT_KEYS` is derived from it rather than
hand-listed, but three PROSE copies are not derived — the persisted-field sentence in
`skills/session-trail/SKILL.md` and its two `--json` disclosure paragraphs. Those are
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
`lineage --forget <session> --apply` is the only way a landed record leaves. Flow 3
step 0 in `skills/session-trail/SKILL.md` states this where the decision is taken;
keep it there, not only in that file's Safety section.

**The v-partition is now REPORTED, not read.** `ledgerPaths` still partitions the
store by `v${LEDGER_SCHEMA_VERSION}` while `classifyEdge` ALSO judges `schemaVersion`
inside a record, and the partition still wins — so `SCHEMA_NEWER`/`SCHEMA_OLDER` remain
reachable only from a hand-planted record. What changed is the CONSEQUENCE:
`otherSchemaLedgers` enumerates sibling `v*` directories, and a build whose own
directory is empty beside a populated one reports a MIGRATION instead of "No handover
has been recorded yet" — which had been followed by an offer to reconstruct guesses
for handovers the machine still held as measurements, one directory away. It does not
READ those records, and closing that still means dropping the derived segment or
teaching `readEdges` to enumerate siblings.

**`recordedAt` is judged by SHAPE, not by parseability, and the two are not close.**
It is the sole ordering key at four sites — the dedupe survivor, the branch `walkChain`
prefers, the `--where` answer and the rendered order — and every one of them ranks it
as a plain string, which is only chronological for the fixed-width UTC spelling
`toISOString()` produces. The guard was `Number.isFinite(Date.parse(...))`, which
judges VALIDITY. Measured against it: `"July 4, 2026"` parsed, sorted ABOVE every real
stamp and was actually earlier; `"9999"` — the value the ordering comment itself names
as the motivating defect — was still accepted; `"2026-02-31T00:00:00.000Z"` was
accepted as a February date meaning 3 March. The store is append-only and machine-wide,
so one such record wins every ordering decision permanently. `isIsoInstant` is the one
predicate, and the ordering comment beside `recordedAtKey` now points at it rather than
asserting the shape it depends on. All three writers already produce that spelling
(`nowStamp()` and the backfill's `new Date(mtime).toISOString()`), so the tightening
refuses nothing this tree writes — a fourth writer that does not is refused at READ
time, which loses the record rather than mis-ordering the ledger. Ported from the
parallel working copy, whose `isIsoInstant` this is.

**A tightened field validator can make a neighbouring test vacuous, and one nearly
did.** The unit fixtures passed bare ordinals (`'1'`, `'2'`) as `recordedAt`, which is
what made them readable; once the shape is enforced, the NUL-session-id case would have
been refused for its STAMP and would have kept asserting `MALFORMED` while never
reaching the guard it is named for. Its fixture carries a real instant now. When a
validator moves, re-read every case that asserts the same refusal reason for a
different cause.

**There is ONE display-bound family, and it is `flatPath`/`instanceId`/`sessionTag`/
`briefPath`.** Two grew independently — this line added a `showId(...).slice(0, 8)`
pair while the write-anchor work added the family above — and both were solving
"bound the value a reader retypes as a selector". They are not equivalent, which is
why the merge picked rather than kept both. Measured on the losing one:
`showId(x).slice(0, 8)` renders a zero-advance character as a SPACE, so
`a<ZWSP>bcdefgh` comes out `"a bcdefg"` — seven real characters in an eight-column
field — and an ESC byte comes out `"abc [31m"`. `instanceId` strips the zero-advance
class FIRST and the ordering is the whole point. `showId` is gone and its thirteen
call sites render through `sessionTag`, so a `list` row and an `instances` row still
name the same prefix, which is the only thing an 8-character id is for.
`test-session-trail-skill.sh` T22c pins the call-site floor and T22c-a pins that a raw
slice does not come back.

**`extractTouchedFiles` must NOT bound the path, and the reason is ORDERING rather
than trust.** Every renderer strips the worktree prefix with `rel(t.path, r.wt)`, a
string comparison against the RAW `r.wt`; a path bounded at extraction no longer
shares that prefix, so `rel` returns the absolute path and the row renders whole. It
was measured doing worse than that: with a worktree carrying a newline the briefs
emitted no `## Files the session touched` rows at all, and `test-session-trail-verdict.sh`
W8 is what caught it. All three renderers bound the value themselves — `flatPath` in
`show`, `briefPath` in both briefs — so the early bound was redundant as well as wrong.
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
- **A window label written before incarnation keying stops resolving.** The key is now
  `<pid>@<start>` (§ the `label` row in SKILL.md), so a bare-pid key no longer matches
  anything. That is the safe direction — the alternative is the label resurfacing on
  an unrelated window that inherited the number — and `label --remove <pid>` clears the
  old form, which is the only thing that can still name it.
- **Two properties are pinned at SOURCE because no behavioural check can reach them
  from a sandbox**, and each says so in its own check comment: the `msysDrivePrefix`
  routing (identity off win32 by construction) and `cmdLabel` landing through
  `updateLabels` (the loss window needs two processes interleaving). Source pins rot
  differently from behavioural ones — each carries a control that fails if its own
  scan matches nothing. **`windowOf`'s basename match was the third and no longer is.**
  It read as unreachable because every fixture starts `node` from a shell, so no
  ancestor ever matched — neutering the function to `return null` cost exactly one
  check. The `window-probe` command takes the table as a parameter over stdin, so
  `L63`–`L63f` now drive the rule that decides the answer, INCLUDING the negative case
  the old source pin existed for: a path that merely lives under a claude-named
  directory (`~/claude-tools/bin/watcher`) is not a window, with the same tree matching
  once the name moves into the basename. A property listed here as untestable, once a
  seam makes it testable, is a stale claim rather than a residual — check this list
  when a seam lands.
- **The record-count cap is proven COMPUTED but not proven end-to-end.** The unit suite
  plants `MAX_EDGE_RECORDS + 5` records; the shell checks prove `ledgerTruncated`
  travels on every ledger-aware payload. Nothing drives a real over-cap ledger through
  the CLI, because 20 000 files is a Windows-budget problem, not a correctness one.

**`tests/structure/test-session-trail-lineage.sh`'s Windows ceiling is MEASURED, and
the measurement is now STALE — say so rather than quoting it as headroom.** The figure
below was taken at 70 checks; the suite has grown several times over since — read its own
reported total rather than a numeral here, which has already drifted twice. The rule this section exists to
record is that the ceiling is set from the FIRST GREEN WALL CLOCK on the shard, never
estimated from the macOS time and never raised speculatively — so the number stands
until a green Windows run replaces it, and until then the 9x ratio is what new checks
are budgeted against, not the remaining percentage. The ceiling was deliberately NOT
raised in the change that more than doubled the suite: raising it without a measurement
would trade a visible `TIMED_OUT` for a silent tail truncation. And the caveat cannot
live in the manifest — `tests/run-profile.js`'s `SUITE_KEYS` rejects any key outside
`{id, runner, path, args, timeoutMs}` and aborts every Windows shard at manifest load,
so a `note` field there is a CI-wide outage rather than documentation.

It is `timeoutMs: 900000` in `tests/profiles/windows-ci.v1.json` on `windows-shard-3`.
First green-shard measurement, run 32598374524 on `win25-vs2026`: **273905 ms at 70
checks** — 30% of its own cap, against **31 s on macOS** (measured 2026-08-22, idle
machine, at 66 checks). Windows is roughly 9x slower here, which is the ratio to
budget new checks against. An earlier note in this section claimed ~4 s on macOS;
that figure predated the suite roughly doubling and was what the 900000 ceiling had
originally been reasoned against.
**THE PROJECTION HAS BEEN REPLACED BY A MEASUREMENT, and it was 28% low.** Run
32998414210, job 98273571899: `session-trail-lineage` took **893084 ms** where the
projection below said "about 700000". Keep that gap in view before trusting the next
projection — the METHOD was sound and the NUMBER was still wrong by four minutes of
Windows wall clock, which on a shard this tight is the whole margin.

**The shard budget binds FIRST and is the tighter of the two, and on that run it
BOUND.** `windows-shard-3` carries a `profileTimeoutMs` of 1800000. Its eight suites
reported 137085 + 511955 + 1238 + 11207 + 9543 + 893084 + 95894 + 140066 ms =
**1800072 ms** — the envelope, exactly. `windows-profile-lifecycle-contract` ran last
and was granted **139971 ms of its own 420000 ms cap**, then reported `TIMED_OUT`. It
was not slow; it was not paid for. That is the failure §Host-Refused Reviewer Spawn
records verbatim ("read the shard's remaining budget", not the suite's `timeoutMs`),
observed rather than predicted.

**The suite therefore moved to `windows-shard-8`, alone AT THE TIME.** It no longer is:
the `stop-enforcer-self-review-routing` rebalance recorded above later moved
`review-worker-evidence-lease` onto this shard, so shard 8 now carries TWO suites whose
run together came to roughly 265 s against the same 1800000 budget. Keep the "alone"
qualified rather than deleting the sentence — the arithmetic below is what justified
creating the shard, and it was taken when the suite really was the only member. Not to a
different neighbour: the same run's job durations were shard-1 1630 s, shard-2 1187 s, shard-3
1886 s, shard-4 1779 s, shard-5 1008 s, shard-6 1011 s, shard-7 1516 s, and 893 s does
not fit inside any of them under a 1800 s envelope. Adding a shard is what the
arithmetic left; rebalancing was not available. The move is three files in one commit —
`tests/profiles/windows-ci.v1.json`, the matrix in `.github/workflows/ci.yml`, and
`expectedProfiles` in `tests/structure/windows-ci-contract.test.js` — and the contract
test fails loudly when they disagree. **Shard 3's own eight-member accounting was wrong
in this file before that move**: it counted seven and omitted `autopilot-release-cli`
(600000), which is precisely how a headroom claim survives being false.

**The cap is 600000, and every earlier number is recorded here because each was wrong
in a different, instructive way.** 893084 of 900000 is 99.2%, and this file said so — "a single added
check can turn it red" — while the manifest shipped 900000 anyway. Run 33018717088 then
spent 900138 ms reaching 229 of 288 checks and was killed by that cap. Two samples of
byte-identical content therefore read 893084 (completed) and >900138 (killed at 79%),
and both were measuring a STALLED SUBPROCESS rather than the suite:
the win32 process probe timed out 115 times at 8000 ms, roughly 920 s of that 997 s.
The cap was then briefly 1500000, sized against a projection built on those poisoned
samples. Once the probe was fixed, run 33054489866 reported `PASSED
session-trail-lineage (154673ms)`, 280 PASS / 0 FAIL / 4 SKIP — so 1500000 was ten
times the real figure.

**Three sizing errors, three different lessons, and the middle one is the one that
generalises.** A ceiling set AT the measurement is already breached — one sample is a
lower bound on a distribution, never a bound on the next run. A ceiling set from a
projection is only as good as what the samples measured, and these measured a defect.
And a ceiling set far ABOVE the measurement stops being a tripwire at all: 600000 is
3.9x the real figure and deliberately BELOW the ~650 s a reintroduced probe stall would
cost, so that regression trips the cap instead of merely making CI slow. The cap — not
the shard — is still what binds this suite, and the reason is now arithmetic rather than
solitude: shard 8 carries a second suite (`review-worker-evidence-lease`, measured
113321 ms), and the two together came to roughly 265 s against the 1800000 profile
budget, so the shard has room to spare while 600000 remains the tighter bound. Re-derive
this if a third suite lands here; "alone" is no longer the premise.

**That measurement is also why 600000 was REJECTED for this suite, not merely not
adopted.** The parallel working copy lowered its own ceiling to 600000 on the strength
of a green run of a 70-check variant measuring 274 s. This suite is four times that
size and measured 893 s: adopting the number would have reported `TIMED_OUT` on every
Windows run. A ceiling is not portable between two suites sharing an `id`; only the
RATIO is — and the ratio under-predicted by 28%.

**The win32 process probe has NEVER passed on Windows, and that is a standing state
rather than a regression.** `processTable()` in `skills/session-trail/scripts/trail.mjs`
runs `Get-CimInstance Win32_Process` and keys every window label on the pid plus its
start time; on the runner it yields nothing, so `windowKey()` answers null, no
`labels.json` window entry is ever written, and L32c-control, L35, L35c, L52-control,
L52 and L52a fail against a file that was never created. Runs 32998414210 and
33018717088 carry those failures WORD FOR WORD, and the `-EncodedCommand` change
between them moved nothing — it removed a real argument-mangling hazard, so keep it,
but do not credit it with a fix it did not deliver. The probe's environment was
replaced wholesale and left the process without `PATH`, `windir`, `SystemDrive` or
`ComSpec`; `Get-CimInstance` reaches WMI through the provider host under
`System32\Wbem`, which nothing named. That omission was the leading suspect and did
NOT fix it, and the `PSModulePath` pin the security comment exists for is kept.

**The cause is now OBSERVED, and it is a STALL, not a failure.** `probeFault()` records
the exit code, signal and first stderr line, and `processStartTimeHealth()` renders it
as `probe-failed — …` where it used to say only `no-process-table`. Run 33052576528
answered `probe-failed — ETIMEDOUT signal SIGTERM`: powershell.exe was killed at its
timeout every single time, having written nothing to stderr. **The arithmetic closes
it.** One full suite run enters `processTable()` **115 times** (counted on macOS,
2026-08-27), so an 8000 ms stall costs 920 s — against the 997 s that run actually took.
The probe stall was very nearly the entire Windows wall clock of this suite; only about
77 s was real work, and the earlier "the cap is too small" reading was a symptom.

**Therefore the probe timeout goes DOWN, not up**, which is the opposite of the
instinct: 12000 would have put the failing case at ~1457 s against a 1500000 cap. It is
5000, so a stalling probe stays inside ~650 s while a working one still fits. What
should make it fast is the startup-cost control in the program itself —
`$PSModuleAutoLoadingPreference='None'` plus an explicit `Import-Module CimCmdlets`,
a four-column `SELECT` instead of whole instances, and `LOCALAPPDATA` restored so the
module analysis cache is not rebuilt on every start. **The uncompromised fix is none of
these**: it is not spawning powershell.exe 115 times. A short-TTL process-table cache in
the config dir would collapse that to a handful and would pay off for every Windows user
of this CLI, not just for CI. It carries its own containment and symlink rules, so it is
named here rather than smuggled into a CI repair.

**It worked.** Run 33054489866: `PASSED session-trail-lineage (154673ms)`, 280 PASS /
0 FAIL / 4 SKIP, with every window-namespace check green and no `probe-failed` line
anywhere — 997 s down to 155 s. If they ever go red again, read the `START TIMES` line
in `lineage --diagnose` before theorising: that line is the whole reason this took one
round instead of three. The L32c-control probe line that
was supposed to surface this greped for `process start` while the text channel prints
`START TIMES`, so it never matched on any platform and reported its own fallback as
though it were a finding; a diagnostic whose needle is never exercised is worse than
none, because it answers confidently.

Replace these figures from the next green Windows shard. A shard abort
truncates the tail of the second suite silently. The caveat lives here and NOT in the manifest:
`tests/run-profile.js`'s `SUITE_KEYS` rejects any key outside
`{id, runner, path, args, timeoutMs}` and aborts every Windows shard at manifest load.

**Two fixture defects in that suite were invisible on POSIX and cost a whole CI
round**, and both are the MSYS/native split this file already documents for
`bash-source-write-parse.js`. Neither was a product defect — the product is native
on both hosts — but both made real checks fail for a reason unrelated to their
subject:

- **`$$` is not a pid `process.kill(pid, 0)` can see.** Under Git Bash it is an MSYS
  pid from a different namespace, so the shell's own pid never reads as live and
  every liveness-dependent check (`L8b`, `L16`, `L24`) failed on that premise rather
  than on its own. The suite now spawns a detached node helper and takes the pid
  NODE reports, which is in the namespace the product consults on every host, and
  retires it in the EXIT trap. `L0b` is the premise check that named this on the
  first Windows run instead of letting three checks fail opaquely — keep it.
- **A hand-written fixture record must carry the spelling production writes.** `L25`
  interpolated a shell path into an edge record while node's `process.cwd()` reports
  the native one, so repo scoping found nothing. Every path a shell writes into a
  fixture here goes through `hostpath` (`cygpath -m`), the same helper the path
  comparisons already used.

**The suite isolates by `--config-dir` and `$ZENSU_CCD_STORE`, deliberately not by
`$HOME`.** Its sibling `test-session-trail-verdict.sh` redirects the home directory
instead — and it does NOT skip itself on Windows, which an earlier revision of this
paragraph claimed: `trailrun` sets `USERPROFILE` alongside `HOME` and that suite's own
V0 probe measures the PAIR, so the redirection succeeds where `os.homedir()` reads
`USERPROFILE`. §"Git Mutation Tables" says the WC block "will therefore run on
Windows", and the two paragraphs now agree. Both suites
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
