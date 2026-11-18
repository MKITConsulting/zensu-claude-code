---
paths:
  - "hooks/lib/evidence-report-v1.js"
  - "hooks/lib/zensu-log.sh"
  - "hooks/lib/zensu-config.sh"
  - "tests/structure/evidence-report-v1.test.js"
  - "tests/structure/test-evidence-report.sh"
  - "tests/fixtures/evidence-report/**"
  - "docs/verify-feature-evidence-report-spec.md"
---

# Evidence Report Core (`hooks/lib/evidence-report-v1.js` + `zensu-log.sh --report-*`)

Build step 1 of `docs/verify-feature-evidence-report-spec.md` §9: the host-agnostic core, its six
verbs and the conformance corpus. `/zensu:verify-feature` does not call the verbs yet; that is
step 2.

**One owner, host-agnostic (AC-018).** The module owns the manifest schema (`MANIFEST_KEYS` and one
exact key set per object), the binding sidecar (`BINDING_SCHEMA`), the ids (`vr1_…`), the store
layout (`STORE_VERSION`), every fault code (`FAULT_CODES`), the renderer and retention. Its own
code reads the environment only through the `env` parameter of `main`, and only `ZENSU_ERP_*`
names there; it requires Node built-ins and five siblings, the acceptance reader, the evidence-run
reader (git scrub, tree fingerprint, run records), the Session Control core (its external process
lock), the secret patterns and the path redaction, and starts no program itself: git runs through
the evidence runner's exported `git`, its outside-a-work-tree split is that module's
`outsideWorkTree` and `workTreeTop`, and chain mode starts bash through the acceptance module's
`readCriteria` at begin and at render. The manifest's
driver enum is the module's own frozen `DRIVERS`, and the unit file pins it equal to the acceptance
module's list, so a new acceptance driver fails a test instead of widening schema v1. Every host
fact (host name, home, plugin data, project root, session key, plugin manifest) arrives as an
argument. The unit file pins all of it by reading the source.

**What a port carries.** The five direct siblings are not the whole set: their require closure,
lazy requires included, holds 14 sibling modules (measured on 2026-11-12 by walking every
`require('./…')` from the module), and chain mode also starts `zensu-plan-requirements.sh` through
the acceptance reader. A port therefore copies the module, those 14 files and the lister
unchanged, and writes only its transport. Most of the closure is chain and session machinery that
matrix mode never runs. The standing fix is a split: one sibling-free module for the schema, the
validators and the renderer, and one for the store and chain mode. It is a follow-up, not built.

**Transport.** `zensu-log.sh` writes the flags as a NUL-separated `args` file (`printf '%s\0%s\0'`)
into a temporary directory, beside stdin (at most 65537 bytes, one past the module's cap) and the
two `evidence.report` layers that `zensu_evidence_report_config_json` reads, `{user, project}`, unjudged. Paths go through
`zensu-host-path.sh`, a file as its directory plus its name, and travel in `ZENSU_ERP_*` variables
kept out of MSYS conversion. The shell refuses every flag outside its list, so no free-text flag
exists; the module refuses a flag that does not belong to the verb. Chain mode (`--log` at begin
and render) reuses `_zensu_avr_prepare` and `_zensu_avr_work_tree`, the acceptance verbs'
transport, and a work-tree fault reaches the module as the `work-tree-fault` file.
`--report-add` reads stdin only for `image`, `text` and `signal`, and list and export never do.
A transport file that is missing reads as empty; one that is oversized or cannot be read is
refused (stdin over its cap exits 1, any other fault 2), so a port whose transport writes more than
the shell's 65537 bytes never reaches a verb as empty stdin. The verbs exit 2 on a usage fault, a
flag that is unknown, repeated, missing or malformed (`usage()`), and 1 on a refusal of a
well-formed call, as `docs/configuration.md` §Evidence Reports promises.

**Store and bundle.** `<store>/<repository key>/<id>/` holds `files/<sha256>.<ext>`, then
`manifest.json` and `index.html` at render and `export.html` on export. `<id>.binding.json`
(session key, project root, the physical run directory, the draft) and the report lock sit beside the
bundle and are never published. The default store is `<plugin data>/evidence-report/v1`, and a
configured `evidence.report.dir` holds the same `v1` directory, so both stores share one layout and
a later schema version can sit beside it. The repository key is the clone's directory name plus 10
hex digits of the SHA-256 of the real `--git-common-dir`, so every worktree of one clone shares it.
Every write is temp-then-rename and refuses to replace a symlink or a non-regular file; every read
is no-follow and bounded. A rendered report is immutable, and only the session that began a report
may add to it; list and export serve any session. Add, step, render and export open a report
through one preamble, `withReport`: the lock, the binding, the owner check, the
rendered-or-not check and, except for export, the check that the binding's project root is the
session's, so a report begun in another worktree of the clone is never measured in this one.

**Locks.** A report is locked with the external process lock of `session-control-core-v1.js`
(`acquireExternalProcessLock`, `releaseExternalProcessLock`, `inspectExternalProcessLock`), keyed
by the report's binding path, so the store keeps the one lock implementation the plugin has for
processes: a holder that exited, or whose pid was reused, loses its lock at once, and a live holder
keeps it. A verb waits up to `LIMITS.lockAttempts` (200) polls of the core lock and then refuses
with exit 2; a lock entry the core cannot read, and a binding that is not a regular file, are
refused at once with exit 2. The sweep takes a report's lock without waiting (one attempt) before
it deletes the report, and spares a report whose lock is held.
`--report-begin` checks the draft size first, then holds the new report's lock while it creates the
report's directories and writes the binding, so another call's sweep never meets a half-made
report without its lock.

**Placement (AC-010)** is checked at every begin, for the default store too: outside every work
tree is fine, inside one only when `git check-ignore` reports the store ignored.

**Containment (AC-006).** The run directory must be a physical directory strictly inside the work
tree (the project root outside git) and apart from the store. Inside a work tree it must lie
outside `.git` and be ignored by git (`git check-ignore` of `<path>/`), so a capture can never be
committed and never moves the tree fingerprint that the target identity and the verdict rules read.
`--report-add --file` takes an absolute, normalized path to a regular file with one link inside it,
opened no-follow and matched by device and inode. The type is read from the content: PNG, a
lossless WebP (`VP8L`; `VP8 ` and an animation are refused), or UTF-8 text without control
characters that does not open with `<`. The caps are the protocol's 50 MiB per file and 2,000 files
per report (`LIMITS.maxFileBytes`, `LIMITS.maxFiles`), plus 64 KiB per text file and 10^8 pixels
per image. On win32 the `--run-dir` and `--file` paths are first turned into their native spelling
(`nativeSpelling`), because the transport's `zensu-host-path.sh` renders `C:/…`. The link check
there (`linkFree`) compares the given spelling with `fs.realpathSync`, which resolves links but
keeps an 8.3 short name, and ignores letter case (`samePath`); containment and the binding use
`fs.realpathSync.native`, which expands short names. A git fault other than a missing work tree
refuses `--report-begin` with exit 2 rather than taking the project root as the work tree.

**Images.** A PNG is walked chunk by chunk to `IEND` (`sniffPng`): bytes after it, a malformed or
truncated chunk, an animation (`acTL`, `fcTL`, `fdAT`) and an unknown critical chunk are refused,
and every ancillary chunk outside `PNG_IMAGE_CHUNKS` is dropped: text, EXIF, time and private
chunks. A WebP (`sniffWebp`) drops its EXIF, XMP and unknown chunks and clears the VP8X metadata
flags. The stored bytes are the cleaned ones, and the file entry keeps the captured file's digest
as `source_sha256`. A stored image that still carries a droppable chunk is refused at render
(`file.metadata`). Dropping instead of refusing keeps an ordinary capture usable while no metadata
reaches a report.

**Text screen (AC-007).** Every text field arrives on stdin and goes through one helper,
`screenSecrets`: it is refused when it carries the allow marker or holds a secret before or after
`redact`, where a secret is a match of the shared patterns or of `REPORT_SECRET_RULES`
(authorization values, a bearer token holding a digit, JWTs, credentials in a URL, session cookies
and API-key headers). It is then redacted and collapsed to one line, and the collapsed value is
screened again, because the pattern reader judges one line at a time and a key and its value on two
lines meet only after the collapse. Before `redact` runs, every spelling of the project root and
of home with two or more segments is replaced by its mark wherever it ends a path, also after a name
character such as the `@fs` of a dev-server URL and before a sentence-ending period
(`scrubOwnPaths`), because `redact` leaves both alone. An argument value (`--recipe`, a request
`--path`, a signal `--class`, the origin and route of a `consent:` line) is refused when the redaction would rewrite
it (`screenArgument`), because an argument is stored as given. A text evidence file is screened
and redacted the same way, and the stored bytes, not the captured ones, are hashed and sniffed
again: a capture that opens with a redacted path would open with `<project>` or `<home>` and read
as markup, so it is refused at add rather than at every later render. One named list,
`CHARACTER_RANGES`, builds the writer's control class, the validator's single-line class and the
text file's class.

**Validation and integrity (AC-003, AC-004).** The manifest and the binding are read schema first:
a `schema` this reader does not know is one `schema.version` fault that names it, or says that no
schema is named when the value is no schema name, and `--report-list` shows such a report as
`schema <name>`. Schema faults (`schema.*`, `manifest.*`) are reported alone; the integrity faults
(`criterion.absent`, `step.unknown-criterion`, `step.unknown-evidence`, `criterion.steps`,
`evidence.unknown-file`, `evidence.file-type`, `file.unreferenced`, `file.missing`, `file.digest`,
`file.size`, `file.type`, `file.metadata`, `criterion.no-image` and the three `verdict.*` codes)
only while the schema holds. Every fault carries a remedy, and the corpus binds codes and paths,
never message text. The module exports `FAULT_CODES`; the corpus holds a case for every code, a
case may lower the manifest cap through `limits.maxManifestBytes`, the one key its `limits` may
carry, and the unit file refuses any other key, derives its list from the export and fails on a
code the source raises outside it.

**Verdict rules.** The spec's necessary conditions: a failed criterion or a failed P0 row needs
`FAIL`, and `PASS` needs every non-deprecated criterion and every P0 row passed; otherwise `PARTIAL`
and `FAIL` are free, because the skill's verdict also weighs console, network and visual evidence.
`PASS` also needs at least one passed criterion or passed P0 row (`verdict.empty`), and in local
matrix mode a `target.tree` equal to `target.begin_tree` (`verdict.tree-changed`), which a tree
that could not be fingerprinted at begin or at render fails too, except outside git, where no
target field git measures holds a value (`targetOutsideGit`). Chain mode needs no tree rule: its
criterion states come from acceptance records bound to the tree at render, and when that tree
cannot be fingerprinted the coverage says that each criterion shows its newest record.

**Coverage (FR-006).** Chain mode calls `resolveChain` and `readCriteria` of the acceptance module
at begin, which stores the plan's `AC-###` rows in the binding, plus each row `assess` reports
dropped that the plan no longer lists, every id once, so `--report-step` refuses every other id, and
`resolveChain` and `assess` again at render. A plan renamed since begin is
refused with both plan paths. A `dropped` row (a criterion deprecated or removed while its newest
verdict is not `pass`, which the acceptance gate blocks on) takes that verdict, `fail` or
`partial`, with the cause as its note, so it blocks PASS here too; `desktop-native` maps to
`desktop`, and a record's evidence or the row's cause is the note. The acceptance module's
disclosures (`ACCEPTANCE STEM UNCHECKED`) are printed at begin and at render and join the
limitations. Matrix mode lists the `AC-###` lines of begin: no row is `missing`, a failed row makes
it `fail`, all rows passed make it `pass`, anything else `partial`, and its driver is the first UI
driver among its rows. Every coverage row, and the draft's, is built by `criterionRow`, and a
draft criterion carries `zensu`, which both modes hand on to the manifest.

**Target identity.** `--report-begin` measures the target and keeps its tree as `begin_tree`;
render measures again and keeps `begin_tree`. A changed tree adds a limitation line, and so does a
local report whose tree could not be fingerprinted at begin or at render. The page shows a
`Tree at begin` row only when the two trees differ. In chain mode the target is measured in the chain's work tree
(`ZENSU_ERP_WORK_TREE`, else the project root), and its tree is the acceptance module's
`chainTree`, the fingerprint the records bind to.

**Draft size.** Every begin, add and step serializes the manifest render would write from the
binding (the same `manifestOf` and pretty-printed JSON, the coverage the rows imply, empty
sections) and keeps `LIMITS.renderReserveBytes` (192 KiB, the largest sections a render's 64 KiB
stdin can produce) plus, in chain mode, a full note per criterion (`chainNoteReserve`) free, so a
report that took its last item still renders. The manifest cap therefore binds before 2,000 files
when every file carries a caption. `--report-begin` checks it before it creates anything: a chain
plan with more criteria than one report holds is refused with the number that fits
(`fittingCriteria`), and a matrix draft that does not fit is refused before its first item.

**Renderer (AC-008, AC-009, AC-017).** One deterministic function of the manifest and the file
bytes: fixed English strings, inline CSS, no script, no `url(`, and images only as
`files/<sha>.<ext>`, which export inlines as data URIs without links. The corpus pins every
rendering by SHA-256, and a unit case renders under another time zone and locale.

**Retention (AC-011)** runs at begin. In the calling repository alone it deletes the reports beyond
the newest `keep`, so one repository's `keep` never trims another's; then, store-wide and oldest
first, it deletes until the store fits `maxBytes`. It spares the new report, a report whose lock
another call holds (or that cannot be taken), and an unrendered report whose binding changed within
`LIMITS.openReportMs` (14 days, the idle window of the sibling stores). The size pass deletes only
when the reports it may delete can bring the store under the cap: when the spared reports alone
exceed `maxBytes` it deletes nothing for the cap and `--report-begin` names their size, so a cap the
spared reports already exceed never empties the store for no gain. `--report-add` refuses a file
that would take one report's files past `maxBytes`, because the store could never hold that
report. A report is deleted only under its own lock, taken without waiting. Names that are not
report ids, and symlinks, are left alone. A delete that fails is named in the begin's output and
retried at the next begin; it never aborts the begin that created a report.

**Config layers.** `maxBytes` and `dir` are read from the user layers only (`ZENSU_CONFIG` or
`~/.zensu/config.json`): `zensu_evidence_report_config_json` hands the
module the user and the project layer as they stand; `normalizeConfig` combines them
(`combineConfigLayers`) and discloses a project value it ignores, because the
size sweep deletes other repositories' reports and `dir` decides where every contributor's evidence
is written. `enabled` keeps a user-level `false`: a project value can switch reports off but never
on, and a project `true` the user's `false` overrides is disclosed. `keep` is merged. The layer rule
lives in the core, so a port hands its own layers and inherits it; the shell reads the user layer
through `ucfg()` and the project layer through `pcfg()` of `_ZENSU_CFG_JS`, which `cfg()` merges.

**Coupled sites.** The verb arm and `_zensu_report_native_dir` / `_zensu_report_native_file` in
`zensu-log.sh`; `zensu_evidence_report_config_json` in `zensu-config.sh`; §Evidence Reports and the
§Config Resolution Order deviation paragraph in `docs/configuration.md`, and `config.example.json`;
§6.2 to §6.11 of the spec; the corpus README; the unit file, its registry entry and
`tests/structure/test-evidence-report.sh` in `ciStructureTests`; `DRIVERS` of
`acceptance-verify-v1.js`, which the unit file pins equal to the manifest's driver enum; the exports
`git`, `outsideWorkTree`, `workTreeTop`, `computeTree`, `LIMITS`, `storeLocations`, `readRecordFile`,
`validateRecord`, `effectiveState`, `workTreeFaultCause` and `readWorkTreeFault` of `evidence-run-v1.js`;
`chainTree`, `readCriteria`, `resolveChain`, `assess`, `compareCriterionIds` and `hasChanges` of
`acceptance-verify-v1.js`; `acquireExternalProcessLock`, `releaseExternalProcessLock` and
`inspectExternalProcessLock` of `session-control-core-v1.js`; `redact` and `rootSpellings` of
`zensu-artifact-redact-v1.js`; and `scan`, `ALLOW_MARKER` and `PLACEHOLDER` of `secret-patterns.js`. A renderer change moves
every rendering digest in the corpus in the same commit, and a new fault code needs its corpus case
in the same commit.

**Version: `patch`.** A new module, new verbs, a new private store and sidecar, and a new config
subtree read permissively. No context-record or workflow-state field moves, no strict key set an
earlier reader knows changes (the manifest, the binding and the store ship for the first time, so
`begin_tree`, the `v1` directory of a configured store and the draft's `zensu` reach no released
reader), and no hook, matcher or attestation moves. The store was deliberately not added to the
protected-root lists of `reviewer-capability-v1.js`: a gate that denies more is a `minor`.

**Known gaps.**

- The store is no protected root of the reviewer capability gate, so a reviewer can read a
  report. The plugin-data guard denies Edit and Write into the default store; a configured store
  outside plugin data has no such guard.
- A PNG is stored as PNG once its metadata chunks are dropped: lossless WebP transcoding and the
  CSP measurement are step 3.
- Chain mode needs an edit-landing receipt, like the acceptance verbs.
- The sidecar and the store are session-writable files, like every plugin store: the integrity
  checks catch an altered evidence file, not a rewritten binding.
- Windows is unmeasured: four unit cases skip there (symlinks, hard links and FIFOs), while their
  portable halves run on every host, and the driver runs only on the weekly Windows Safety
  structure shard. The short-name tolerance of `linkFree` rests on how `fs.realpathSync` walks a
  path; the unit case drives its win32 branch on every host, but no Windows run has measured an
  8.3 spelling.
- A local target whose every git read failed at begin and at render reads as outside git, so its
  PASS is not refused for the missing fingerprints; the limitation line still names the gap.
- No ports were included.
