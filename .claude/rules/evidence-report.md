---
paths:
  - "hooks/lib/evidence-report-v1.js"
  - "hooks/lib/zensu-log.sh"
  - "hooks/lib/zensu-config.sh"
  - "tests/structure/evidence-report-v1.test.js"
  - "tests/structure/test-evidence-report.sh"
  - "tests/fixtures/evidence-report/**"
  - "docs/verify-feature-evidence-report-spec.md"
  - "skills/verify-feature/rules/report.md"
  - "tests/structure/test-verify-feature-skill.sh"
  - "docs/verify-feature.md"
---

# Evidence Report Core (`hooks/lib/evidence-report-v1.js` + `zensu-log.sh --report-*`)

Build steps 1 to 3 of `docs/verify-feature-evidence-report-spec.md` §9: the host-agnostic core,
its six verbs and the conformance corpus, the wiring that has `/zensu:verify-feature` call the
verbs on every run that creates its run directory (§"The skill wiring" below), and the verified
lossless WebP transcode with the viewer's Content-Security-Policy (§"The WebP transcode" and
§"The viewer's policy" below).

**One owner, host-agnostic (AC-018).** The module owns the manifest schema (`MANIFEST_KEYS` and one
exact key set per object), the binding sidecar (`BINDING_SCHEMA`), the ids (`vr1_…`), the store
layout (`STORE_VERSION`), every fault code (`FAULT_CODES`), the renderer and retention. Its own
code reads the environment only through the `env` parameter of `main`, and only `ZENSU_ERP_*`
names there; it requires Node built-ins and five siblings, the acceptance reader, the evidence-run
reader (git scrub, tree fingerprint, run records), the Session Control core (its external process
lock), the secret patterns and the path redaction. It starts two programs itself and no other,
libwebp's `cwebp` and `dwebp`, both through the one `runTool` (§"The WebP transcode"), and it
requires no network module. Git runs through the evidence runner's exported `git`, its
outside-a-work-tree split is that module's `outsideWorkTree` and `workTreeTop`, and chain mode
starts bash through the acceptance module's `readCriteria` at begin and at render. The manifest's
driver enum is the module's own frozen `DRIVERS`, and the unit file pins it equal to the acceptance
module's list, so a new acceptance driver fails a test instead of widening schema v1. Every host
fact (host name, home, plugin data, project root, session key, plugin manifest, and the caller's
tool path that decides whether a tool is started) arrives as an argument. The unit file pins all
of it by reading the source.

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
kept out of MSYS conversion. One variable is left to that conversion on purpose:
`ZENSU_ERP_TOOL_PATH` carries the caller's `PATH` for the tool lookup, and Git Bash has to turn it
into the native list the core splits at `path.delimiter`. Nothing reads that list on win32 yet,
because the lookup answers no pair there (§"The WebP transcode"). The shell refuses every flag outside its list, so no free-text flag
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
bundle and are never published. `<store>/scratch/webp-<random>/` is the private directory of one
transcode. The default store is `<plugin data>/evidence-report/v1`, and a
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
tree is fine, inside one only when `git check-ignore` reports the store ignored. A git fault that
leaves either question open, in the work-tree probe or in the check-ignore probe, marks the answer
undetermined (`storePlacement`), and begin refuses it with exit 2, the code of an environment fault,
as it does for the run-directory probes.

**Containment (AC-006).** The run directory must be a physical directory strictly inside the work
tree (the project root outside git) and apart from the store. Inside a work tree it must lie
outside `.git` and be ignored by git (`git check-ignore` of `./<path>/`), so a capture can never be
committed and never moves the tree fingerprint that the target identity and the verdict rules read.
The refusal says that captures would move the fingerprint only for a run directory inside a tree
the report fingerprints, in the same work tree and outside that tree's `.zensu` (`fingerprinted`):
the project root, and in chain mode also the chain's fingerprint root, which is canonicalized with
`fs.realpathSync.native` and compared through `samePath`, because `fingerprintRoot` returns git's
spelling. The remedy names the run directory's parent when that parent lies below the top of the
work tree that holds the run directory, neither is nor holds the project root, is not `.zensu` at
the top of that work tree or of the project root (`isZensuRoot`), and holds nothing git tracks
and, unless it is `RUN_ROOT` at the top of that work tree or of the project root, whose other
entries are run directories (`isRunRoot`), no untracked, unignored file outside the run directory
(`ignoreTarget`), else the run directory itself when it neither is nor holds the project root, is
not that `.zensu`, and git tracks nothing under it. So a run directory directly below `.zensu`,
`RUN_ROOT` itself included, gets a line for itself, and `.zensu` itself gets the run-root remedy
below. The line it suggests is that path anchored at the work tree's top, `/` plus the spelling with
`\`, `*`, `?` and `[` escaped (`ignoreLine`), because an unanchored pattern matches a directory of
that name at any depth; a spelling with a control character gets no line. When no directory
qualifies, and for a run directory that is itself the top of a work tree, which that tree cannot
ignore, the refusal names `RUN_ROOT`, `.zensu/verify-feature-runs/` at the top of the project's
work tree, and says whether git ignores it: only an exit status of 1 from the probe asks for the
ignore line, and any other answer, such as a timeout, says that this could not be determined and
names the probe's reason. For a project outside git it names `RUN_ROOT` in the project root, which
lies outside git and needs no ignore line (`runRootRemedy`, which the `.git` refusal shares). When
`.zensu` or `RUN_ROOT` there is a symbolic link or not a directory, the remedy says so before any
probe and asks for a directory in its place or for another run directory (`runRootObstacle`):
`linkFree` refuses a run directory reached through a link, its physical path lies wherever the link
points, git's probe exits 128 there, and no directory can be created below a file. Inside git it
names the anchored line for `RUN_ROOT` alone, unless git already ignores it, because a consuming
repository commits `.zensu/plans/` and `.zensu/logs/`, and the other run directory is one of the
work tree that git ignores; outside git it is one of the project root that lies outside every git
work tree, since one inside a nested work tree is refused again unless that tree ignores it. A run
directory at or below such an entry that does not exist, because lstat answers ENOTDIR or ENOENT
through it, or that runs through the link gets the same remedy after its refusal (`runRootHint`);
one that no such entry holds, and one whose work-tree probe fails, keeps the plain refusal. It
therefore never asks to ignore the project root, a directory that holds it, a directory with a
tracked file or all of `.zensu`, never asks to ignore a run root whose probe failed, never names a
run root that no run directory can use, and never names a work tree that a project outside git
lacks.
Every check-ignore probe, the store placement and `runRootRemedy` included, goes
through `checkIgnore`, which classifies git's answer for every caller (exit 0 ignored, exit 1 not
ignored, anything else undetermined with its reason) and prefixes the spelling with `./`:
check-ignore reads a leading `:` as pathspec magic, so `:shots/` would be judged as `shots/`, and
it refuses `--literal-pathspecs` with exit 128.
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

**The WebP transcode (build step 3).** After the cleaning, `addFileEvidence` hands an `image/png`
to `transcodePng` while `evidence.report.webp` is `auto`. It answers one of three things: nothing,
when no usable tool pair exists, so the add and its line are the step-2 ones; a reason, so the PNG
is stored and the line ends with ` | PNG kept: <reason>`; or the WebP bytes, which are stored in
place of the PNG as `image/webp` with the captured file's digest as `source_sha256`, and the line
ends with ` | transcoded losslessly from a PNG of <n> bytes`. A transcode is verified, never
trusted, because the encoder does not refuse what it cannot keep: measured with libwebp 1.6.0, a
`gAMA` of 1.0 changed the decoded pixels, a 16-bit PNG was reduced to 8 bits without a message, and
without `-exact` the colour under alpha 0 was lost (spec Appendix A).

- **Lookup (`findWebpTools`).** On win32 it answers no pair before it reads the tool path: neither
  the lookup nor the start of a tool with an empty environment was ever run there, so the
  transcode stays off on that platform until it is measured. The platform is the function's third
  parameter, so a unit case drives that answer on every host. Elsewhere only absolute entries of
  the tool path count, in order. An entry without an executable regular `cwebp` is skipped
  (`toolFile`), the first entry with one decides, and `dwebp` must sit beside it.
  First-entry-decides is deliberate: a decoder from another directory may be another build, and
  the check would then verify one library with another. `trustedPair` judges the pair in two
  steps. First the places: the pair is refused when everyone may write the entry's real
  directory, a real tool file or the directory a tool really lies in (`othersMayWrite`, the
  `0o002` bit), and when a directory above one of those three directories, or above the entry as
  the tool path spells it, is writable by everyone and not sticky (`othersMayReplace`, which
  walks to the file-system root), because another account could then replace the program or a
  directory that leads to it. The spelled entry joins the walk because a symlinked entry is a
  name in its parent directory: whoever may rename entries there can point it at another tool
  directory, whose own real place then passes. A sticky directory
  above the pair passes, since only an entry's owner may rename or remove it there, and so does a
  group-writable place. Ownership is not judged on purpose: a Homebrew prefix belongs to an
  ordinary account, and a shared install to a service account, so an owner rule would switch the
  transcode off without a line for people who did nothing wrong. Then the roots: `projectRoots`
  is asked only once a pair passed the first step, because it runs git: the project root, the top
  of its work tree, and the same two for the chain's work tree. The spelled entry, its real
  directory and both real files must lie outside every root, so a link inside the project that
  points outside is refused too, and a root that cannot be determined refuses the pair. A
  repository therefore never supplies the program. The real paths come from `physicalPath`, which
  is `fs.realpathSync.native` on every platform, the reader this module uses for containment.
- **Runner (`runTool`).** `spawnSync` with the tool's real path, no shell, an empty environment,
  `stdio: 'ignore'`, `LIMITS.toolMs` (30 s) and `SIGKILL`, inside the private directory. It is the
  module's only use of `node:child_process`; the unit file pins the option block, the two call
  sites and their order by reading the source. The environment is built by `toolEnvironment`,
  not written as `{}`: Node copies `NODE_V8_COVERAGE` from its own process into a child's
  environment unless the given object has that name as an own key (measured with Node 26.13.1 on
  macOS, with the variable present at start and set at run time, and with Node 22.23.5 on Linux),
  so each name in
  `NODE_COPIED_VARIABLES` is an own key without a value. A plain `{}` would hand the tools that
  variable whenever the calling process runs under a coverage tool, and the unit case that reads
  the tools' environment would then fail under `c8`; that case sets the variable itself.
- **What is tried (`pngFacts`).** 8-bit truecolor with or without alpha, not interlaced, no side
  over `WEBP_MAX_SIDE`, at most `LIMITS.maxTranscodePixels`, only the chunks of
  `PNG_TRANSCODE_CHUNKS`, none of `PNG_SINGLE_CHUNKS` twice, a `pHYs` with equal axes, and `gAMA`
  or `cHRM` only beside `sRGB` or `iCCP`, which override them. Every other PNG answers its reason
  before a tool starts.
- **Verification.** The core decodes the PNG itself (`decodePng`: one inflate bounded by the
  expected size, the five filter types, a stream of any other length refused). `cwebp` runs with
  `WEBP_ENCODER_ARGUMENTS`. `encodedProblem` judges its output in a fixed order and names the
  first failure: it must sniff as a still, lossless WebP with nothing to drop, have the PNG's
  size, carry the PNG's ICC profile byte for byte, or none when the PNG has none
  (`webpProfiles`), and be smaller than the cleaned PNG. `dwebp -pam` then writes RGBA, and
  `pamMatches` compares it with the core's decode: it opens the file through `openForReading`,
  the no-follow, non-blocking open that `readBounded` uses too, requires a regular file of exactly the header's and the pixels' size on that descriptor, and
  reads it in blocks through `readExactly`, so a short read is no match, while `rowMatches`
  compares each row, an RGB source against alpha 255. Only a file-system error answers no match
  there; any other error reaches `transcodePng`, which keeps the PNG with `the transcode could
  not be completed`. Any difference, a tool that fails, writes no file or runs past its limit,
  and a scratch directory that cannot be made (`scratchDirectory`) each keep the PNG with a
  reason of their own.
- **Scratch.** `<store>/scratch/webp-<random>` holds `source.png`, `target.webp` and
  `decoded.pam` for one call and is removed in `finally`. `sweepScratch` removes a `webp-`
  directory older than `LIMITS.scratchStaleMs` (10 minutes) before a new one is made, which clears
  what a killed call left.
- **Config.** `combineConfigLayers` turns `webp` on only when every layer that sets it says
  `auto`. `off`, or any other value, in the user or the project layer switches it off, and
  `normalizeConfig` discloses a user-level `off` beside a project `auto` and a value that is
  neither word. The key governs a capability the plugin grants itself, starting programs, so a
  project file can withdraw it and never grant it. A configuration file that cannot be read or
  parsed sets nothing, as for every ordinary key: the shell's `rd()` hands the core an empty
  layer, so an `off` in such a file is lost and nothing is disclosed. That is the rule
  `evidence.report.enabled` follows too, and the two strict hooks keys are the only ones a
  malformed file withdraws.

**Text screen (AC-007).** Every text field arrives on stdin and goes through one helper,
`screenSecrets`: it is refused when it carries the allow marker or holds a secret before or after
`redact`, where a secret is a match of the shared patterns or of `REPORT_SECRET_RULES`
(authorization values, a bearer token holding a digit, JWTs, credentials in a URL, session cookies
and API-key headers). It is then redacted and collapsed to one line, and the collapsed value is
screened again, because the pattern reader judges one line at a time and a key and its value on two
lines meet only after the collapse. Before `redact` runs, every spelling of the project root and
of home with two or more segments is replaced by its mark wherever it ends a path, also after a name
character such as the `@fs` of a dev-server URL and before a sentence-ending period
(`scrubOwnPaths`), because `redact` leaves both alone. An argument value is stored as given, so
`screenArgument` refuses `--recipe` and a signal `--class` whenever the scrub or `redact` would
rewrite them, and a request `--path` and the origin and route of a `consent:` line only when they
name the project root or home (`namesOwnPath`): a route such as `/home` or `/Users/42/edit` is the
application's path, not a local one, and is kept. A text evidence file is screened
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
target field git measures holds a value (`targetOutsideGit`). Render hands `verdictFaults` a
context the manifest lacks, read from the binding: `beganOutsideGit`, true only when begin's
`begin_failure` is `not a git work tree` and the begin target holds no field git measures, plus
`beginFailure` and `treeFailure`, the causes the
refusal names. A target whose work-tree probe fails at render, at begin or at both is therefore
refused rather than read as outside git. A project root that left git between begin and render
never reaches the rule: its repository key changes, so render answers that no such report exists
in this repository's store. `treeCheck` classifies the tree once, for the refusal and for render's
limitation line. A port that validates a manifest alone passes no context and keeps the manifest
rule. Chain mode needs no tree rule: its
criterion states come from acceptance records bound to the tree at render, and when that tree
cannot be fingerprinted the coverage says that each criterion shows its newest record and names
the cause from the `treeFailure` vocabulary below.

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
render measures again and keeps `begin_tree`. In a local report a changed tree adds a limitation
line, and so does a tree that could not be fingerprinted at begin or at render; a remote report
verifies deployed code, so it gets no tree line. The line names the begin
cause from the binding's `begin_failure`, and the render cause unless `treeCheck` reads the target
as outside git: begin's cause is `not a git work tree` and neither the begin target nor the render
target holds a field git measures. Two probes that both timed out therefore name both causes.
`measureTarget` returns
the cause beside the target, from a fixed vocabulary (`treeFailure`: an untracked-file limit,
`git timed out`, `not a git work tree` for every answer `outsideWorkTree` reads as outside a work
tree, otherwise `git failed`), so git output, which can hold a path, never reaches a report. Once
its own probe answered inside a work tree, a tree failure `computeTree` labels `not a git work tree`
is named `git failed`, because that label then only means its own probe failed.
Begin keeps its cause in `begin_failure`, which the binding validator holds to that vocabulary and
to its begin tree, and when a local matrix target it did not find outside git could not be
fingerprinted, it prints that `--report-render` will refuse a PASS. The page shows a
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

**The viewer's policy (build step 3).** `renderHtml` writes one Content-Security-Policy meta
element directly after the charset element, from `contentPolicy`: `default-src 'none'`, `img-src`
from `IMAGE_SOURCES` (`'self' file:` for the bundle page, `data:` for the export), `style-src` with
`STYLE_SOURCE`, then `base-uri 'none'` and `form-action 'none'`. `STYLE_SOURCE` is the SHA-256 of
`STYLE`, computed when the module loads, so a style change needs no second edit; a unit case
recomputes it from the rendered page's one `style` element. The renderer writes no `style`
attribute, because the hash covers the element alone. Measured on 2026-11-25 on `file://` in
Chrome 158, Safari 27.2 and Firefox 161.0 (spec Appendix A): the page loads its relative images
and applies its style sheet under the policy, and a probe page ran no inline script and sent
none of the requests the spec counts as stopped. What it does not stop: a navigation, a `preconnect` connection, an image
from another local file, and in Firefox anything loaded from a local file, a script included,
because Firefox applied none of the fetch directives to a `file:` URL. `file:` in `img-src` is
redundant in the three measured browsers, which load the relative images under `'self'` alone. It
is kept because Firefox's source gives `'self'` no match for a document without a host, so a
version that begins to apply the policy to local files would otherwise hide a report's images.
Measure Firefox through WebDriver BiDi and never through its headless `--screenshot` mode, which
captured pages before their images were painted; that looked like a policy block and was none.

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
on, and a project `true` the user's `false` overrides is disclosed. `keep` is merged. `webp` is
fail-closed across the layers (§"The WebP transcode"). The layer rule
lives in the core, so a port hands its own layers and inherits it; the shell reads the user layer
through `ucfg()` and the project layer through `pcfg()` of `_ZENSU_CFG_JS`, which `cfg()` merges.

**The skill wiring (step 2).** `skills/verify-feature/rules/report.md` is the one owner of how the
skill calls the verbs: begin right after the run directory exists, add each capture right after
it was inspected and never in a batch, one row per matrix row, undriven rows as `skip`, render
after Phase 4, and the report format that moved out of `SKILL.md` Phase 5, which keeps three
pointers, the verdict rules and the verdict line. A begin that exits 1 or 2 leaves the run going
with its verdict unchanged and `Evidence report: none — <cause>` above the verdict line, exit 3
leaves no location line, and the skill never edits an ignore file to satisfy a remedy: the plugin
writes no consuming repository's `.gitignore`. A `verdict.*` refusal is answered with the verdict
the core's remedy opens with (`state FAIL` or `state PARTIAL`), with one exception: a criterion the
message lists as `missing` in matrix mode that the run passed gets its row first, because only a
criterion no row names can still change state; the verdict that renders is stated in the chat
report too, so the report and the chat never disagree. `criterion.no-image` is answered by linking
an inspected image through one more row, else in matrix mode by a `skip` row and PARTIAL. While a
report is begun the run drives every row in one lane (`SKILL.md` Phase 3), because `--report-add`
takes only files beneath the report's own run directory and each lane has a run directory of its
own; one report per lane, which splits a run's evidence over several reports, and a core that
accepts files from sibling lane directories, which widens the file boundary, were rejected. Only a file beneath
the run directory enters, so a host tool's in-conversation screenshot needs a file capture beside
it; the capture commands are in `rules/drivers.md` §8 and `rules/browser-verification.md` §5, and
a browser screenshot is 1440 by 900 at scale 1 after `resize` (measured, spec Appendix A). Rule
files spell `<absolute-plugin-root>` and `<absolute-plugin-data>`, which the Phase 2 pointer
defines, because only `SKILL.md` is substituted. No core change was needed.

**Coupled sites.** The verb arm and `_zensu_report_native_dir` / `_zensu_report_native_file` in
`zensu-log.sh`; `zensu_evidence_report_config_json` in `zensu-config.sh`; §Evidence Reports and the
§Config Resolution Order deviation paragraph in `docs/configuration.md`, and `config.example.json`;
§6.2 to §6.11 of the spec; the corpus README; `RUN_ROOT`, which both run-directory refusals name,
the root `skills/verify-feature/SKILL.md` Phase 2 creates run directories under and the ignore
block of `docs/build-workflow.md` lists; the unit file, its registry entry and
`tests/structure/test-evidence-report.sh` in `ciStructureTests`; `DRIVERS` of
`acceptance-verify-v1.js`, which the unit file pins equal to the manifest's driver enum; the exports
`git`, `outsideWorkTree`, `workTreeTop`, `fingerprintRoot`, `computeTree`, `LIMITS`, `storeLocations`,
`readRecordFile`, `validateRecord`, `effectiveState`, `workTreeFaultCause` and `readWorkTreeFault` of
`evidence-run-v1.js`, and the reason texts its `git`, `computeTree` and `computeFingerprint` return,
which `TREE_FAILURE_RE` reads (the untracked-file limits, `git timed out`, `not a git work tree` and
the `work tree: ` prefix), and which unit cases drive through the real functions, all but
`git timed out`;
`chainTree`, `readCriteria`, `resolveChain`, `assess`, `compareCriterionIds` and `hasChanges` of
`acceptance-verify-v1.js`; `acquireExternalProcessLock`, `releaseExternalProcessLock` and
`inspectExternalProcessLock` of `session-control-core-v1.js`; `redact` and `rootSpellings` of
`zensu-artifact-redact-v1.js`; and `scan`, `ALLOW_MARKER` and `PLACEHOLDER` of `secret-patterns.js`. A renderer change moves
every rendering digest in the corpus in the same commit, and a new fault code needs its corpus case
in the same commit. The wiring adds: `VERB_ARGUMENTS` and the report arm's flag list in
`zensu-log.sh`, which every `--report-<verb>` call in `rules/report.md`, `rules/drivers.md` and
`rules/browser-verification.md` must fit (`P11b` in `tests/structure/test-verify-feature-skill.sh`);
the opening words of the `verdict.*` remedies and the `criterion.no-image` remedy, which
`rules/report.md` §4 follows (`P11e`); begin's exit-3 line (`P11d`); `ROUTE_RE`, which admits
shell characters in a request path, so every `--path` value in the three rule files stays
single-quoted, and so does every `--recipe`, `--origin` and `--class` value, while the chain-mode
`--log` value is double-quoted like `--run-dir`, because it is an absolute path below the project
root, which `zensu-log.sh --project-root` screens for the four characters double quotes cannot
carry and which may hold an apostrophe (`P11g`);
`evaluate` of `verify-consent-v1.js`, which must keep admitting the documented `resize 1440 900`,
`screenshot` and `screenshot --full-page` calls (`P11f`); the begin, add, step and render blocks
of `rules/report.md`, which `R22` in `tests/structure/test-evidence-report.sh` runs as written and
`R22a` judges through `decide` of `verify-auth-guard-v1.js` and `evaluate`, neither of which may
deny or ask; the `criterion.no-image` and `verdict.contradiction` answers of `rules/report.md`
§4, which `R23` runs against the core; the `verify-feature` entry of
`tests/structure/test-skill-text-budget.sh`; and section 7 of `docs/verify-feature.md`, which
restates the retention defaults (`keep` 30, `maxBytes` 2 GiB, the 14-day spare of an unrendered
report), the PASS refusals with the scope of `verdict.tree-changed`, and the one-lane rule.

**Coupled sites of step 3.** `WEBP_ENCODER_ARGUMENTS` with the command line in spec §6.5 and the
unit file's `ENCODER_FLAGS`; the `PNG kept:` reasons of `pngFacts` and `transcodePng` with the unit
file's tables; `PNG_TRANSCODE_CHUNKS`, `WEBP_MAX_SIDE` and `LIMITS.maxTranscodePixels` with the
"which PNGs are tried" bullet of spec §6.5; `contentPolicy`, `IMAGE_SOURCES` and `STYLE_SOURCE`
with the policy line of spec §6.6, the bullets of `docs/verify-feature.md` section 7 and every
rendering digest of the corpus; `ZENSU_ERP_TOOL_PATH` in the report arm of `zensu-log.sh` and in
`transportOptions`, and the line citations of `zensu-log.sh` in `docs/multi-repo-chains-spec.md`
and `docs/multi-repo-chains-overview.html`, which a line added to that file shifts
(`test-multi-repo-doc-citations.sh`), and with the tool-path row of the port table in spec §7.1;
the lookup's refusals (`findWebpTools`, `trustedPair`, `othersMayWrite`, `othersMayReplace`) with
the "where the tools come from" and "Windows keeps the PNG" bullets of spec §6.5, the encoder,
tool-pair and unmeasured bullets of spec §11, the `--report-add` and `evidence.report.webp` rows
of `docs/configuration.md` and the two screenshot bullets of `docs/verify-feature.md` section 7,
and with the fixed modes the unit helper `standInTools` and the driver's stub directories set, so
a permissive umask cannot make a stand-in look writable by everyone; the `webp` rule of
`combineConfigLayers` with the `evidence.report.webp` rows of spec §6.11 and
`docs/configuration.md`, its deviation paragraph there, which counts the deviating keys, and
`config.example.json`; and in `tests/structure/test-evidence-report.sh` the `ENCODER_ONLY`
directory that leads `PATH` for the whole suite, which keeps every check independent of a libwebp
the machine may have, with `R24`, the one check that puts a tool pair first. `R24` expects the
plain add line on Git Bash, where the lookup answers no pair, and that host branch is the suite's
only native-Windows marker, which its `excluded` entry in
`tests/profiles/windows-native-structure.v1.json` records.

**Version: `patch`.** A new module, new verbs, a new private store and sidecar, and a new config
subtree read permissively. No context-record or workflow-state field moves, no strict key set an
earlier reader knows changes (the manifest, the binding and the store ship for the first time, so
`begin_tree`, the binding's `begin_failure`, the `v1` directory of a configured store and the
draft's `zensu` reach no released reader), and no hook, matcher or attestation moves. The store was deliberately not added to the
protected-root lists of `reviewer-capability-v1.js`: a gate that denies more is a `minor`. The
wiring of step 2 is `patch` on the same walk: skill text, docs and structure checks, with no
hook, matcher, schema field, key set, config key or attestation moved. Step 3 is `patch` as well:
a stored WebP uses the `image/webp` type and the `source_sha256` field the manifest and the binding
already had, so no key set moves and an installation of the same lineage that predates the
transcode reads and renders such a report; `evidence.report.webp` is read permissively; the policy
element changes a rendered page, which no reader validates; and no hook, matcher or attestation
moves. That the module now starts two programs is not on the breaking list.

**Known gaps.**

- The store is no protected root of the reviewer capability gate, so a reviewer can read a
  report. The plugin-data guard denies Edit and Write into the default store; a configured store
  outside plugin data has no such guard.
- The transcode runs the first `cwebp` and `dwebp` pair the caller's `PATH` names outside the
  project, as every tool the plugin starts by name is whatever `PATH` names. The pair is resolved
  and then started, so a file swapped in between is followed. The writability check reads three
  directories, every directory above them or above the entry as spelled, and two files, and
  judges no owner. A link that a symlink chain passes through on its way, stored in a directory
  on neither of those paths, is not judged. The verification
  bounds what a wrong encoder can store, not what a hostile program on `PATH` can do.
- A `cwebp` that was found and not accepted prints nothing: the add line is then the step-2 line,
  which the unit file and `R24` pin. Naming the rule that refused the pair, on the add line, at
  `--report-begin` or in a `/zensu:doctor` row, is an open decision. Until it is taken, section 7
  of `docs/verify-feature.md` tells a reader what the lookup requires.
- `dwebp` decodes `target.webp` by its path after the core read that file's bytes for storing, so
  the verified file and the stored bytes are two reads of one file in the call's private scratch
  directory.
- A user-level `evidence.report.webp` of `off` is lost while that configuration file cannot be
  parsed, like every setting in it. Reading an unreadable layer as `off` would need the shell to
  tell a missing file from a broken one; it is not built.
- The transcode keeps pixels and an ICC profile, nothing else: `sBIT`, a `pHYs` with equal axes,
  and `gAMA` or `cHRM` beside `sRGB` or `iCCP` are not in the WebP. The captured file's digest is.
- Two captures that become the same WebP share one file, and its entry keeps only the first
  capture's digest as `source_sha256`.
- A call that is killed leaves its scratch directory, with the capture in it, until the next
  transcode finds it older than 10 minutes. The largest image measured took 1.6 s for 7.3 million
  pixels; the 30 s limit was not measured against an image near the pixel cap.
- The viewer's policy is a second line with holes: a navigation, a `preconnect` connection and an
  image from another local file pass it in every measured browser, and Firefox applies it to
  nothing loaded from a local file, so a page that carried foreign markup could run a script that
  lies on the reader's disk there. `form-action` was exercised in Chrome and Firefox only, and a
  manifest link, an icon link and `prefetch` fired in too few browsers to count as measured.
- `file:` in `img-src` rests on a source reading, not on a measurement, and is redundant today.
  Dropping it is a one-token change that moves every rendering digest.
- Windows keeps every PNG: `findWebpTools` answers no pair there, because nothing of the
  transcode was measured on that platform: a lookup of `.exe` names, Git Bash's conversion of
  `ZENSU_ERP_TOOL_PATH`, which variables a tool started with an empty environment still receives,
  and a writability rule for its access lists. Switching the transcode on there needs those
  measurements first. The policy and a `file:` URL with a host are unmeasured on Windows too. Six
  unit cases that drive stand-in tools skip there, because a stand-in is a script with an
  interpreter line.
- Chain mode needs an edit-landing receipt, like the acceptance verbs.
- The sidecar and the store are session-writable files, like every plugin store: the integrity
  checks catch an altered evidence file, not a rewritten binding.
- Windows is unmeasured: ten unit cases skip there, four for symlinks, hard links and FIFOs,
  whose portable halves run on every host, and six for stand-in tools, and the driver runs only
  on the weekly Windows Safety structure shard. The short-name tolerance of `linkFree` rests on how `fs.realpathSync` walks a
  path; the unit case drives its win32 branch on every host, but no Windows run has measured an
  8.3 spelling.
- A manifest validated without its binding, as a port's corpus validates it, cannot tell a local
  target whose every git read failed at render from one outside git, so it accepts that PASS;
  only render, which reads `begin_failure` from the binding, refuses it unless begin found the
  target outside git.
- The wiring is skill text: no hook checks that a run began, fed or rendered its report, so a run
  that skips a verb shows only in the missing location line.
- A `desktop` row off macOS has no window-scoped file capture, so a criterion that passes through
  it links no image, and render's `criterion.no-image` rule leaves it partial in matrix mode.
- A second chain-mode pass on an unchanged tree renders every plan criterion, and render refuses a
  UI-driver `pass` whose rows in this report link no image, so the pass takes one fresh screenshot
  of each criterion it skips (`rules/report.md` section 3). Applying the rule only to criteria that
  have a row in the report being rendered is a core change, not built.
- The page labels `run.authenticated` `Manual login`, although a recipe login sets it too. Renaming
  the label moves every rendering digest of the corpus, so it waits for a core change.
- No ports were included.
