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
layout, every fault code, the renderer and retention. Its own code reads the environment only
through the `env` parameter of `main`, and only `ZENSU_ERP_*` names there; it requires Node
built-ins and four siblings, the acceptance reader, the evidence-run reader (git scrub, tree
fingerprint, run records), the secret patterns and the path redaction, and starts no program
itself: git runs through the evidence runner's exported `git`, its outside-a-work-tree split is
that module's `outsideWorkTree` and `workTreeTop`, and chain mode starts bash through the
acceptance module's `readCriteria` at begin and at render. The manifest's driver enum is the
module's own frozen `DRIVERS`, and the unit file pins it equal to the acceptance module's list, so
a new acceptance driver fails a test instead of widening schema v1. Every host fact (host name, home, plugin data, project root, session key, plugin manifest)
arrives as an argument. The unit file pins all of it by reading the source, so a port copies the
file unchanged and writes only its transport.

**Transport.** `zensu-log.sh` writes the flags as a NUL-separated `args` file (`printf '%s\0%s\0'`)
into a temporary directory, beside stdin (at most 65537 bytes, one past the module's cap) and the
`evidence.report` subset that `zensu_evidence_report_config_json` reads unjudged. Paths go through
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
(session key, project root, the physical run directory, the draft) and `<id>.lock` sit beside the
bundle and are never published. The default store is `<plugin data>/evidence-report/v1`, and
`evidence.report.dir` replaces it. The repository key is the clone's directory name plus 10 hex
digits of the SHA-256 of the real `--git-common-dir`, so every worktree of one clone shares it.
Every write is temp-then-rename and refuses to replace a symlink or a non-regular file; every
read is no-follow and bounded. A rendered report is immutable, and only the session that began a
report may add to it; list and export serve any session.

**Placement (AC-010)** is checked at every begin, for the default store too: outside every work
tree is fine, inside one only when `git check-ignore` reports the store ignored.

**Containment (AC-006).** The run directory must be a physical directory strictly inside the work
tree (the project root outside git) and apart from the store. `--report-add --file` takes an
absolute, normalized path to a regular file with one link inside it, opened no-follow and matched
by device and inode. The type is read from the content: PNG, a lossless WebP (`VP8L`; `VP8 ` and
an animation are refused), or UTF-8 text without control characters that does not open with `<`.
The caps are the protocol's 50 MiB per file and 2,000 files per report (`LIMITS.maxFileBytes`,
`LIMITS.maxFiles`), plus 64 KiB per text file and 10^8 pixels per image. On win32 the
`--run-dir` and `--file` paths are first turned into their native spelling (`nativeSpelling`),
because the transport's `zensu-host-path.sh` renders `C:/…`. The link check there (`linkFree`)
compares the given spelling with `fs.realpathSync`, which resolves links but keeps an 8.3 short
name, and ignores letter case (`samePath`); containment and the binding use
`fs.realpathSync.native`, which expands short names. A git fault other than a missing work tree
refuses `--report-begin` with exit 2 rather than taking the project root as the work tree.

**Text screen (AC-007).** Every text field arrives on stdin and is refused when it carries the
allow marker or matches a secret pattern before or after `redact`; it is then redacted and
collapsed to one line, and the collapsed value is scanned again, because the pattern reader
judges one line at a time and a key and its value on two lines meet only after the collapse. The
origin and route of a `consent:` line go through the same screen. A text evidence file is
screened and redacted the same way, and the stored bytes, not the captured ones, are hashed and
sniffed again: a capture that opens with a redacted path would open with `<project>` or `<home>`
and read as markup, so it is refused at add rather than at every later render.

**Validation and integrity (AC-003, AC-004).** Schema faults (`schema.*`, `manifest.*`) are
reported alone; the integrity faults (`criterion.absent`, `step.unknown-criterion`,
`step.unknown-evidence`, `criterion.steps`, `evidence.unknown-file`, `evidence.file-type`,
`file.unreferenced`, `file.missing`, `file.digest`, `file.size`, `file.type`, `criterion.no-image`,
`verdict.contradiction`) only while the schema holds. Every fault carries a remedy, and the corpus
binds codes and paths, never message text. The verdict rule is the spec's necessary condition: a
failed criterion or a failed P0 row needs `FAIL`, and `PASS` needs every non-deprecated criterion
and every P0 row passed; otherwise `PARTIAL` and `FAIL` are free, because the skill's verdict also
weighs console, network and visual evidence.

**Coverage (FR-006).** Chain mode calls `resolveChain` and `readCriteria` of the acceptance module
at begin, which stores the plan's `AC-###` rows in the binding so `--report-step` refuses an id the
plan does not list, and `resolveChain` and `assess` again at render. A `dropped` row (a criterion
deprecated or removed while its newest verdict is not `pass`, which the acceptance gate blocks on)
takes that verdict, `fail` or `partial`, with the cause as its note, so it blocks PASS here too;
`desktop-native` maps to `desktop`, and a record's evidence or the row's cause is the note. The
acceptance module's disclosures (`ACCEPTANCE STEM UNCHECKED`) are printed at begin and at render
and join the limitations. Matrix mode lists the `AC-###` lines of begin: no row is `missing`, a
failed row makes it `fail`, all rows passed make it `pass`, anything else `partial`, and its driver
is the first UI driver among its rows. The target identity is measured at begin and again at
render, and a changed tree adds a limitation line. In chain mode it is measured in the chain's work
tree (`ZENSU_ERP_WORK_TREE`, else the project root), and its tree is the acceptance module's
`chainTree`, the fingerprint the records bind to.

**Draft size.** Every begin, add and step serializes the manifest render would write from the
binding (the same `manifestOf` and pretty-printed JSON, the coverage the rows imply, empty
sections) and keeps `LIMITS.renderReserveBytes` (192 KiB, the largest sections a render's 64 KiB
stdin can produce) plus, in chain mode, a full note per criterion free, so a report that took its
last item still renders. The manifest cap therefore binds before 2,000 files when every file
carries a caption.

**Renderer (AC-008, AC-009, AC-017).** One deterministic function of the manifest and the file
bytes: fixed English strings, inline CSS, no script, no `url(`, and images only as
`files/<sha>.<ext>`, which export inlines as data URIs without links. The corpus pins every
rendering by SHA-256, and a unit case renders under another time zone and locale.

**Retention (AC-011)** runs at begin. In the calling repository alone it deletes the reports
beyond the newest `keep`, so one repository's `keep` never trims another's; then, store-wide and
oldest first, it deletes until the store fits `maxBytes`. `maxBytes` is read from the user layers
only (`ZENSU_CONFIG` or `~/.zensu/config.json`): `zensu_evidence_report_config_json` drops a
project value and hands the module `maxBytesFromProject`, which `normalizeConfig` discloses. A
report is deleted only under its own lock, taken without waiting, so the new report, a report
whose lock another call holds (or that cannot be taken), and an unrendered report whose binding
changed within `LIMITS.openReportMs` (14 days, the idle window of the sibling stores) are spared.
Names that are not report ids, and symlinks, are left alone. A delete that fails is named in the
begin's output and retried at the next begin; it never aborts the begin that created a report.
`withLock` refuses a stale lock entry it cannot remove, a directory for one, at once with exit 2
instead of retrying without a deadline.

**Coupled sites.** The verb arm and `_zensu_report_native_dir` / `_zensu_report_native_file` in
`zensu-log.sh`; `zensu_evidence_report_config_json` in `zensu-config.sh`; §Evidence Reports in
`docs/configuration.md` and `config.example.json`; the corpus README; the unit file, its registry
entry and `tests/structure/test-evidence-report.sh` in `ciStructureTests`; `DRIVERS` of
`acceptance-verify-v1.js`, which the unit file pins equal to the manifest's driver enum; the
exports `git` and `outsideWorkTree` of `evidence-run-v1.js` and `chainTree` and `readCriteria` of
`acceptance-verify-v1.js`. A renderer change moves every
rendering digest in the corpus in the same commit.

**Version: `patch`.** A new module, new verbs, a new private store and sidecar, and a new config
subtree read permissively. No context-record or workflow-state field moves, no strict key set an
earlier reader knows changes (the manifest and the binding ship for the first time), and no hook,
matcher or attestation moves. The store was deliberately not added to the protected-root lists of
`reviewer-capability-v1.js`: a gate that denies more is a `minor`.

**Known gaps.**

- The store is no protected root of the reviewer capability gate, so a reviewer can read a
  report. The plugin-data guard denies Edit and Write into the default store; a configured store
  outside plugin data has no such guard.
- A PNG is stored as captured: WebP transcoding (`source_sha256`) and the CSP measurement are step 3.
- Chain mode needs an edit-landing receipt, like the acceptance verbs.
- The sidecar and the store are session-writable files, like every plugin store: the integrity
  checks catch an altered evidence file, not a rewritten binding.
- Windows is unmeasured: four unit cases skip there (symlinks, hard links and FIFOs), and the
  driver runs only on the weekly Windows Safety structure shard. The short-name tolerance of
  `linkFree` rests on how `fs.realpathSync` walks a path; the unit case drives its win32 branch on
  every host, but no Windows run has measured an 8.3 spelling.
- No ports were included.
