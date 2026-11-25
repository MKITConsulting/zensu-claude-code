# Verify-Feature Evidence Report — Specification

Status: draft, 2026-11-07. Build steps 1 to 3 of §9 are implemented: the core module, its
`zensu-log.sh` verbs and the conformance corpus, the wiring that has `/zensu:verify-feature`
write a report on every run (`skills/verify-feature/rules/report.md`), and the verified lossless
WebP transcode with the viewer's Content-Security-Policy (§6.5, §6.6); nothing else described here
is. The spec plans four parts that
ship from different repositories: the plugin (this repository), its ports to other hosts, the
`zensu` CLI, and the Zensu service with its web viewer. For the CLI and the service it fixes
behavior and contract only; this repository is public, so it names no internal module of either.
Decisions 1 to 4 were taken on 2026-11-04 and decisions 5 to 8 on 2026-11-07; decision 9 is open
(§10). §12 records how far a Zensu feature's acceptance criteria reach the plugin today.

**Zensu is optional, on every host.** Every run writes its report locally without a Zensu account,
without a network and without a forge CLI. Zensu adds one optional destination: nothing in a run
waits for it, and a Zensu failure never changes a local report.

## 1. What it does

`/zensu:verify-feature` writes one evidence report for every run that creates its run directory,
whatever the verdict and whatever the drivers. The report is a bundle on the local disk: a
versioned manifest that is the source of truth, the evidence files it names, and a static
`index.html` rendered from the manifest. It shows, per acceptance criterion and per scenario,
what was exercised, what was observed and which evidence backs it, with the coverage matrix
first.

Two publish steps are optional and run only on the user's decision:

- **Review summary**, no Zensu login: one comment on the open pull request (GitHub) or merge
  request (GitLab) of the current branch, with the verdict, the coverage matrix and a few key
  images. The full report never goes to a forge.
- **Zensu upload**, Zensu login: the manifest and its evidence files, linked to the feature, its
  criteria, the commit and, when there is one, the AI-work result. The Zensu web application
  renders the report from the manifest and keeps the history of runs.

One report format serves every Zensu plugin host: Claude Code, Codex, Kiro, Antigravity and
GitHub Copilot CLI (§7). Each host keeps its reports locally; Zensu is where the reports of every
host can meet.

## 2. Who it is for

- The developer who ran the verification and needs the evidence after the conversation has moved
  on, or wants to hand it to a reviewer, a tester or a product owner.
- The reviewer on GitHub or GitLab, who sees verdict, coverage and the key screens where the merge
  is decided.
- The person accepting an AI-work result in Zensu, who sees the evidence beside the result.
  Submission is not acceptance; the report is what an acceptance decision can rest on.
- Teams without a Zensu account: the local report and the review summary need none.
- Teams on another Zensu plugin host, once its port has landed (§7).

## 3. Who it is not for

- **Not a regression suite.** A report proves one run on one tree. `/zensu:cover` writes durable
  tests.
- **Not a second verdict.** The acceptance gate (`docs/gates.md` §Acceptance Verification Gate)
  decides whether a chain closes. The report renders what the run and the gate observed and adds
  nothing to either.
- **Not a store for production data.** What a run may capture stays decided by verify-feature's
  existing boundaries: the origin boundary, the credential-blind rules, and no console or network
  output from authenticated targets. The report captures nothing those rules forbid.
- **Not a compliance archive.** No signatures, no tamper evidence, no legal retention.

## 4. What success looks like

The plugin:

| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | Every run that creates its run directory writes exactly one report, for PASS, FAIL and PARTIAL alike, including a run that stops during setup. The chat report names the report's location on a line above its final verdict line. | spec |
| AC-002 | The report's verdict, coverage counts and per-criterion states equal the chat report's. In chain mode every criterion's state equals `--acceptance-status` on the same tree at render time. | spec |
| AC-003 | The renderer refuses, naming each fault and its remedy, when an in-scope criterion is absent from the manifest, a step names an unknown criterion, a referenced file is missing or its digest differs, or the stated verdict contradicts the states (§6.4). | spec |
| AC-004 | A criterion recorded `pass` through `browser`, `mobile` or `desktop` links at least one image. Otherwise the renderer refuses and names both remedies: link an image already in the report, or record the criterion `partial`. | spec |
| AC-005 | Evidence files are copied into the report store when they are added, so deleting the run directory in Phase 4 loses nothing. The bundle references no path inside the run directory. | spec |
| AC-006 | `--report-add` accepts only a regular file inside the run's own run directory (physical path, no symlink), of an allowed type sniffed from its content, within the size caps. Anything else is refused. | spec |
| AC-007 | Every text field passes the secret screen, where a match is refused, and the path redaction of `hooks/lib/zensu-artifact-redact-v1.js` before it is written. Free text enters through stdin, never through a command-line argument. | spec |
| AC-008 | `index.html` opens from disk without a network request: it carries no script and no external URL, and every image it shows lies inside the bundle. | spec |
| AC-009 | Rendering the same manifest and files twice yields byte-identical output. | spec |
| AC-010 | The default store lies outside every git work tree. A configured store inside a work tree is refused unless git reports the path ignored. | spec |
| AC-011 | Retention keeps the newest `evidence.report.keep` reports per repository and at most `evidence.report.maxBytes` in total, deleting the oldest first. The sweep never deletes the report being written. | spec |
| AC-012 | When a lossless WebP encoder and its decoder are available and the decoded WebP equals the capture pixel for pixel, an image is stored losslessly transcoded, with the original's digest recorded. Otherwise it is stored as captured. No image is ever stored lossy or scaled, and each records its viewport and scale factor. | spec |
| AC-013 | Nothing leaves the machine unless the user asked for that publish step in this conversation or enabled it in the user-level config; a project-local `.zensu/config.json` can only switch publishing off. Before the first network call the step lists what will leave: destination, file count, file names and total size, and for a Zensu upload the tier's remaining quota. | spec |
| AC-014 | The review summary goes through the VCS driver (`hooks/lib/zensu-vcs.sh`) to the open pull request (GitHub) or merge request (GitLab) of the current branch. It re-reads the request's state immediately before posting, attaches at most `evidence.report.prImages` images and never the bundle, and contains no local path. On any other forge it stops with the cause. | spec |
| AC-015 | The Zensu upload sends the manifest, then only the files the service reports missing. An interrupted upload resumes, and publishing the same report twice changes nothing. Without a login, or with a CLI below the upload verb's floor, it stops with the remedy and changes nothing locally. | spec |
| AC-016 | Without Zensu, without `gh` or `glab` and offline, every local function works unchanged, and the report path makes no network request unless a publish step was requested. A failed or unavailable publish step leaves the local report and the run's verdict as they were. | spec |
| AC-017 | Every fixed string and heading of the report is English, and so is observation text, as acceptance evidence is today. The review summary follows the language rule of §6.10. | spec |

The ports:

| ID | Requirement | Source |
|----|-------------|--------|
| AC-018 | The core module `hooks/lib/evidence-report-v1.js` reads no host-specific environment variable and calls no host tool; every host fact enters as an argument. A port reuses the file unchanged and supplies only its transport, its capture commands and its skill text. | spec |
| AC-019 | A conformance corpus ships with the core: manifests and files, each with its expected rendering digest or its expected refusal. The plugin's suite, every port's suite and the service's validation run it and agree on every case. | spec |
| AC-020 | Every manifest names the host that produced it in `run.host`, and the service accepts a valid report from any host. Every port keeps the local report and the review summary free of any Zensu dependency. | spec |

The CLI:

| ID | Requirement | Source |
|----|-------------|--------|
| AC-021 | `zensu evidence push <bundle> --feature <id>` opens the report, uploads only the files the service lacks, finalizes, and prints the report URL; with `--json` it prints one object. A rerun after an interruption resumes, and a rerun after success changes nothing. It reads nothing outside the bundle and refuses a symlink inside it. | spec |
| AC-022 | `zensu evidence push` runs under a personal login only; an API key or a work-order session token is refused, as for AI-work capture. `zensu evidence list` and `zensu evidence get` read a feature's reports. | spec |

The Zensu service:

| ID | Requirement | Source |
|----|-------------|--------|
| AC-023 | The service accepts a file only as PNG, WebP or UTF-8 text, judged by its content, within the pixel cap and at most `maxFileBytes`, which is never below the plugin's per-file cap of 50 MiB. A report's total size is bounded only by the tenant's quota. The service never stores or serves markup from a report. | spec |
| AC-024 | Finalize verifies every file's SHA-256 and re-runs the checks of AC-003 and AC-004 on the uploaded manifest. A report that fails stays unfinalized and the answer names each fault. An open report that is not finalized within its tier's open time, at least 7 days, expires. | spec |
| AC-025 | A report is readable by the feature's readers and uploadable by the product's writers. Upload, finalize and deletion are audited. A deletion removes the report and every file no other report references. | spec |
| AC-026 | The web application lists a feature's reports newest first, shows a report with its coverage matrix first, escapes every string, and compares two reports of one feature criterion by criterion. | spec |
| AC-027 | A finalized report appears on its feature, on each requirement row its criteria name by Zensu ref, at its commit, and on the review screen of the AI-work result it names. A ref the feature does not hold is reported and left unlinked. | spec |
| AC-028 | Every cap beyond the fixed protocol caps of 50 MiB per file and 2,000 files per report is set per tier (decision 5, §10). The open answer carries the tier's caps and their current use; a refused upload names the cap it hit and the use, and the plugin relays that text unchanged. | spec |

## 5. Out of scope

- Video. Version 1 stores images and text; video needs a later schema version.
- Forges other than GitHub and GitLab, as in `docs/vcs-driver-spec.md`: Bitbucket, Gitea, Azure
  DevOps and the rest get no review summary.
- The full report as a forge attachment (decision 6).
- Uploads by API keys, CI tokens or work-order sessions (decision 8).
- Localized reports.
- Editing a rendered report, or merging the reports of several runs into one. Zensu shows the
  history of runs instead.
- Signing or tamper evidence.
- Pixel-by-pixel image comparison in the Zensu viewer. Version 1 compares criterion states and
  shows the images of matching steps side by side.

## 6. Design: the plugin

### 6.1 Lifecycle

One owner module, `hooks/lib/evidence-report-v1.js`, holds the manifest schema, the ids, the
store, the integrity checks, the renderer and the publish steps, the way
`hooks/lib/acceptance-verify-v1.js` owns its records. It is host-agnostic (§7.1).
`hooks/lib/zensu-log.sh` transports it, so every verb runs bound to the session and its project
root.

| Verb | When | Effect |
|---|---|---|
| `--report-begin` | Phase 2, right after the run directory exists | Creates the report with a `vr1_…` id and records mode, drivers and target identity. Runs the retention sweep. |
| `--report-add` | Phase 3, right after a capture was inspected | Copies one evidence file, or stores one evidence item, with its caption from stdin. |
| `--report-step` | Phase 3, when a matrix row is finished | Writes the row: title, priority, driver, criteria, expected, observed, result and evidence ids. |
| `--report-render` | Phase 5, before the chat report | Runs the integrity checks, folds in the acceptance states, writes `manifest.json` and `index.html`, prints the location. |
| `--report-list` | any time | Lists the newest reports of this repository with verdict, state and location. |
| `--report-export` | on request | Writes one HTML file with every image inlined, for sharing outside Zensu. |
| `--report-publish --to pr\|zensu` | on request, or per opt-in | §6.10. |

The chat report stays as it is. It still ends with the greppable verdict line, and the report
location is one line above it.

Every verb that takes prose reads it from stdin through a quoted heredoc, as
`--acceptance-record` does. That prose never names the browser CLI together with a
`zensu-verify-` session, because the browser consent gate refuses a command whose text names
both. The binding data, the session key, the physical run directory and the cause of a tree
`--report-begin` could not fingerprint, lives in a sidecar file beside the bundle and is never
published. Every write is atomic, a temporary file plus a rename,
and refuses symlinks, like the acceptance store. A report whose session ended before Phase 5
stays in the store, counts toward retention and is listed as `unrendered`.

### 6.2 The bundle

```
<store>/<repository key>/<report id>/
  manifest.json
  index.html
  files/<sha256>.<ext>
```

- `<store>` defaults to `$CLAUDE_PLUGIN_DATA/evidence-report/v1`, beside the acceptance store in
  `$CLAUDE_PLUGIN_DATA/acceptance-verify/v1`. The path carries no plugin version, so it survives
  plugin updates. It lies outside every work tree, it survives the removal of a worktree, and the
  plugin-data guard already denies `Edit` and `Write` there. `evidence.report.dir` moves it, and
  the configured directory holds the same `v1` directory, so `<store>` is
  `<evidence.report.dir>/v1` and both stores share one layout.
- `<repository key>` groups the reports of every worktree of one clone: the clone's directory
  name plus the first 10 hex digits of the SHA-256 of the realpath that
  `git rev-parse --git-common-dir` names. Outside git, the project root's realpath is hashed.
- Files are content-addressed, so an image added twice is stored once.

**Why outside the work tree.** A report inside a worktree is lost when the worktree is cleaned
up, and a report inside the repository is one `git add` away from its history. A prior
project-local implementation kept reports in a gitignored folder of each worktree. On
2026-11-03 the reports of five features sat inside worktrees that are removed after merge.

### 6.3 Manifest version 1

Every object has a fixed key set. A reader refuses an unknown or a missing key, and a change is a
new schema version. A reader checks `schema` first: a manifest or a binding that names a version
it does not know is one `schema.version` fault naming that version, never a list of key faults,
and `--report-list` shows the version as the report's state. No field is trusted HTML: every renderer, the plugin's and Zensu's alike,
escapes every string, and the only formatting text may carry is inline code in backticks.

```jsonc
{
  "schema": "zensu-evidence-report/v1",
  "id": "vr1_1762250400000_0123456789ab",
  "created_at": "2026-11-04T10:00:00Z",
  "rendered_at": "2026-11-04T10:20:00Z",
  "plugin_version": "<plugin version>",
  "run": {
    "host": "claude-code",
    "mode": "local",
    "attach": false,
    "chain": { "stem": "2026-11-04-1000_build-settings", "plan": ".zensu/plans/2026-11-04-1000_build-settings.md" },
    "feature": "The request as given, redacted",
    "drivers": ["browser", "api"],
    "recipe": ".zensu/runtime.yaml",
    "authenticated": false
  },
  "target": {
    "repository": "owner/name",
    "branch": "feature/settings",
    "head": "<40 hex digits>",
    "tree": "<the acceptance gate's tree fingerprint>",
    "begin_tree": "<the tree fingerprint at --report-begin>",
    "dirty": false,
    "origin": null
  },
  "verdict": "PARTIAL",
  "coverage": {
    "source": "acceptance-records",
    "criteria": [
      {
        "id": "AC-001",
        "text": "Saving a setting persists it across a reload.",
        "state": "pass",
        "driver": "browser",
        "record": "av1_…",
        "evidence_run": null,
        "zensu": { "feature": "<feature id>", "ref": "AC-001" },
        "steps": [1],
        "note": "The record's evidence text."
      }
    ]
  },
  "steps": [
    {
      "n": 1,
      "title": "AC-001 — save a setting and reload",
      "priority": "P0",
      "driver": "browser",
      "criteria": ["AC-001"],
      "result": "pass",
      "expected": "The saved value is shown after a reload.",
      "observed": "The settings page showed the saved value after a reload.",
      "evidence": ["e1", "e2"]
    }
  ],
  "evidence": {
    "e1": { "kind": "image", "file": "<sha256>", "caption": "Settings page after the reload, value shown.", "plane": "visual" },
    "e2": { "kind": "request", "method": "PUT", "path": "/api/settings", "status": 200 }
  },
  "files": {
    "<sha256>": { "name": "files/<sha256>.webp", "type": "image/webp", "bytes": 81234, "width": 1440, "height": 900, "viewport": { "width": 1440, "height": 900, "scale": 1 }, "source_sha256": "<sha256 of the captured PNG>" }
  },
  "sections": {
    "console": "clean",
    "network": "clean",
    "consent": [{ "origin": "http://127.0.0.1:5173", "route": "/settings", "decided_by": "asked" }],
    "limitations": [],
    "resources": []
  }
}
```

Field rules:

- `run.host` names the host that produced the report: lowercase letters, digits and hyphens, 2 to
  32 characters, such as `claude-code`, `codex`, `kiro`, `antigravity` or `copilot`. It is not an
  enum, so a new host needs no new schema version.
- `run.chain` is `null` outside chain mode, `run.recipe` without a recipe. `run.authenticated`
  turns `true` once any row ran signed in, through a recipe login or a visible manual login.
- `target.repository` comes from the origin remote with userinfo stripped, `null` without one.
  `target.origin` is set in remote mode only and holds scheme, host and port.
- `target.tree` is the tree measured at render and `target.begin_tree` the one measured at
  `--report-begin`; either is `null` where no tree can be fingerprinted, such as outside git. The
  page shows the begin tree only when the two differ, and in a local report a changed tree or one
  that could not be fingerprinted becomes a limitation line; a remote report verifies deployed code
  and gets none. A tree that could not be fingerprinted is named with its
  cause from a fixed vocabulary (an untracked-file limit, `git timed out`, `not a git work tree`,
  otherwise `git failed`), never with git output: the begin cause, which the binding keeps, and
  the render cause unless the target reads as outside git, that is, begin's cause is
  `not a git work tree` and neither the begin target nor the render target holds a field git
  measures, so two probes that both timed out name both causes. In chain mode the same
  vocabulary names the tree the acceptance states could not be compared with.
- `coverage.source` is `acceptance-records` in chain mode and `matrix` otherwise. `state` is one
  of `pass`, `fail`, `partial`, `missing`, `stale` and `deprecated`; `record` is `null` in matrix
  mode.
- `coverage.criteria[].zensu` names the Zensu feature and the requirement ref a criterion came
  from. It is `null` for a criterion that exists only in the plan or the request (§12).
- `steps[].result` is `pass`, `fail` or `skip`.
- `files[].viewport` holds the viewport or window size in CSS or device-independent pixels and the
  scale factor at capture. It is `null` for a text file and where the driver cannot tell.
- `rendered_at` is `null` until the report is rendered.

Evidence kinds:

| Kind | Holds | Typical drivers |
|---|---|---|
| `image` | a screenshot or pane-capture file | `browser`, `mobile`, `desktop`, a terminal UI |
| `text` | a text file of at most 64 KiB: a terminal transcript, a rendered plan, an accessibility-tree excerpt | `cli`, `library`, `iac`, `async`, `mobile`, `desktop` |
| `request` | method, path without query or fragment, and status | `browser`, `api` |
| `signal` | source, class and a bounded, sanitized message | every driver |
| `run` | an `er1_` evidence run; render copies its redacted command, exit code and duration into the manifest, never its output tail, which no limit or redaction sanitizes (`skills/verify-feature/rules/acceptance-evidence.md` §1) | the observed drivers |

Render copies what it needs from a record into the manifest, because the acceptance and
evidence-run records stay local and are swept after 14 idle days. A published manifest is
therefore complete on its own.

Each driver's primary evidence follows its planes in `skills/verify-feature/rules/drivers.md`
§3: the visual plane for `browser`, `mobile` and `desktop`, the state plane for every other
driver. A UI-driver criterion without an image needs a `note` that says why an image cannot show
it. This keeps the principle of the prior implementation: a screenshot is the rule, every other
kind of evidence the justified exception.

**A capture that exists only in the model's context cannot enter a report.** The host's
simulator and computer-use tools hand a screenshot to the model, not to a file. Every UI driver
therefore takes its evidence with a capture that writes a file beneath the run directory:
`screenshot` on the browser session, which already writes beneath the run directory's `browser/`
folder; `xcrun simctl io <udid> screenshot <file>` for a simulator;
`adb -s <serial> exec-out screencap -p` for an emulator; and a window-only capture for a desktop
app, such as `screencapture -l <window id>` on macOS. The emulator and desktop captures are
unmeasured.

### 6.4 Coverage and integrity

- **Chain mode** takes its criteria from the plan through the row parser the gate uses, and each
  state from the acceptance module's status reading at render time, reused and never copied. A
  criterion whose newest record belongs to another tree is `stale` in the report, as in the gate.
- **Standalone mode** reports from the evidence matrix. Each row is a coverage unit; criteria
  supplied with `AC-###` ids are listed with the states their rows imply.

The checks of AC-003 and AC-004 run at render. The verdict is checked against the states: a
stated `PASS` needs every in-scope criterion and every P0 row passed; any failed criterion or
failed P0 row requires `FAIL`; `PARTIAL` is refused only when something failed. A `PASS` also
needs at least one passed criterion or passed P0 row (`verdict.empty`), and in local matrix mode a
tree that was fingerprinted at `--report-begin` and at render and did not change between them
(`verdict.tree-changed`), because the rows were recorded against the begin tree; a target outside
git, where no tree, head, branch, repository or dirty state can be measured, is exempt when
`--report-begin` also found it outside git, which render reads from the binding; a target whose
work-tree probe failed at `--report-begin` is not exempt, and `--report-begin` says so at once
when it could not fingerprint a local matrix target. Chain mode needs
no such tree rule: the acceptance states it folds are already bound to the tree at render, and
when that tree cannot be fingerprinted the report says each criterion shows its newest record.
These checks are
necessary conditions, not the whole verdict rule of Phase 5, which also weighs console, network
and visual evidence.

### 6.5 Images

- The captured PNG is the source. With libwebp's `cwebp` and `dwebp` installed, `--report-add`
  transcodes it losslessly (`cwebp -quiet -lossless -exact -z 6 -metadata icc`) and records the
  PNG's digest as `source_sha256`; the PNG itself is not kept. Without the two tools the PNG is
  stored. Lossy encoding is never used, because evidence must show the pixels that were captured.
- **A WebP is stored only after it was verified.** The encoder does not refuse what it cannot
  keep: measured with libwebp 1.6.0, a PNG with a gamma of 1.0 came back with other pixels, a
  16-bit PNG was reduced to 8 bits without a message, and without `-exact` the colour under a
  fully transparent pixel was lost (Appendix A). So the core decodes the PNG itself, has `dwebp`
  decode the WebP, and compares width, height and every pixel, alpha included. It stores the WebP
  only when they are equal, the file is a still, lossless WebP without EXIF or XMP, an ICC profile
  of the PNG arrived unchanged and none was added, and the WebP is smaller than the PNG. In every
  other case, and when a tool fails, writes no file or runs past 30 seconds, the PNG is stored and
  the line `--report-add` prints ends with `PNG kept:` and the reason.
- **Which PNGs are tried.** An 8-bit truecolor PNG, with or without alpha, that is not interlaced,
  has no side longer than 16,383 pixels, the limit of a WebP, holds at most 33,554,432 pixels, and
  carries no chunk a WebP cannot hold: a palette or a transparency chunk (`PLTE`, `tRNS`), a
  background, histogram or suggested palette (`bKGD`, `hIST`, `sPLT`), colour signalling beyond a
  profile (`cICP`, `mDCV`, `cLLI`), `gAMA` or `cHRM` without `sRGB` or `iCCP`, or a `pHYs` chunk
  with unequal axes. Every other PNG is stored as PNG, and no tool is started for it; when a tool
  pair was found, its reason stands on the same line.
- **Where the tools come from.** The transport hands the caller's `PATH` to the core, which reads
  only its absolute entries, in order. The first entry that holds an executable `cwebp` decides:
  `dwebp` must sit beside it, and neither the entry nor either file may lie inside the project
  root, its work tree or the chain's work tree, so a repository never supplies the program. The
  pair is also left unused when everyone may write its directory, one of the two files or the
  directory a file really lies in, or a directory that is not sticky above one of them or above
  the entry as `PATH` spells it, because another account could then replace the program or the
  link that leads to it. Who owns the pair is not judged: a tool tree
  often belongs to another account, which then supplies every other program on `PATH` as well.
  The tools run by their resolved path, without a shell, with an empty environment and under a
  time limit, inside a private directory below the store's `scratch` directory that is removed
  afterwards. Without such a pair the add is the add of build step 2, line included, so a pair
  that was found and left unused prints no reason either.
- **Windows keeps the PNG.** The lookup answers no pair there: neither it nor the start of a tool
  with an empty environment was ever run on Windows, so the transcode stays off on that platform
  until it is measured.
- **Pixels only, no metadata.** `--report-add` walks a PNG chunk by chunk to `IEND`: bytes after
  it, a truncated chunk, an animation and an unknown critical chunk are refused, and text, EXIF,
  time and private chunks are dropped before the file is stored. A WebP drops its EXIF, XMP and
  unknown chunks the same way. The stored file is then not the captured one, so its entry keeps
  the captured file's digest as `source_sha256`. A stored image that still carries such a chunk is
  refused at render (`file.metadata`). Dropping instead of refusing keeps an ordinary capture
  usable while no metadata reaches a report.
- **Normalized at capture, never scaled afterwards.** A browser screenshot is taken at the run's
  viewport, 1440 by 900 CSS pixels at scale factor 1 by default, set once with the allowed
  `resize` command after `open`, and of the viewport only unless the criterion needs what lies
  below the fold. A criterion about responsive layout or fine detail adds captures at the
  viewport it names or with `--hires`. Device and window captures keep their native size. Each
  image records its viewport and scale factor, so the images of two runs are compared only when
  both match.
- **Display scaling is the viewer's job.** The local viewer scales an image with CSS and loads it
  lazily; Zensu derives its own thumbnails from the uploaded original (§8.3). A derived image is
  never evidence and never goes into a bundle.
- Measured on 2026-11-03 on a single-file report of 13.7 MB that embedded 44 PNG screenshots of a
  web application: the 45 PNGs of its folder total 10.4 MB, losslessly transcoded 4.8 MB. Lossy
  at quality 85 they total 3.7 MB, which this spec does not use. Base64 adds a third, so the
  single-file export of the lossless set is about 6.4 MB. One screenshot averaged 232 KB as PNG
  and 107 KB losslessly transcoded; 41 of the 45 were taken at 1440 by 900 and 4 at 2880 by 1800.
  Appendix A holds the raw numbers.
- Caps: 50 MiB per file and 2,000 files per report, checked at `--report-add`, so every file a
  report holds can also be uploaded (§8.3). A report has no size cap of its own: it is split into
  files, and only `evidence.report.maxBytes` locally and the tenant's quota in Zensu bound it.
  `--report-add` refuses a file that would take one report's files past `evidence.report.maxBytes`,
  because the store could never hold that report.
  The review summary skips an image above 10 MB, the attachment limit recorded for a GitHub free
  plan.

### 6.6 Viewer

`index.html` is static and carries no script. It opens with the verdict and the target identity,
then shows the coverage matrix, then the steps with their evidence, then signals, consent,
limitations and resources. The footer names the report id, the schema, the host and the plugin
version. Light and dark follow `prefers-color-scheme`. Images load lazily with their dimensions
set, so a large report opens fast.

`index.html` carries one Content-Security-Policy meta element, directly after its charset element:

```text
default-src 'none'; img-src 'self' file:; style-src 'sha256-<digest>'; base-uri 'none'; form-action 'none'
```

`<digest>` is the SHA-256 of the page's one `style` element, so the page's own style sheet applies
and no other style does, a `style` attribute included. `export.html` carries the same element with
`img-src data:`. The policy allows images and the page's style sheet and nothing else: no script,
no frame, no font, no media and no request to a network. `img-src` is the one directive that does
not single out the page's own files: `'self' file:` matches every local file, as the list below
says.

Measured on 2026-11-25 on `file://` in Chrome 158, Safari 27.2 and Firefox 161.0 (Appendix A): the
page under the policy loads both a PNG and a WebP from its `files` directory and applies its style
sheet, and in Chrome and Firefox its screenshot equals, pixel for pixel, the screenshot of the same
page without the element. A probe page under the policy ran no inline script and no event handler
and applied no injected style, and of the 17 or 18 kinds of request that the same page without the
element sent to a loopback witness server it sent none, in all three browsers.

**What the policy does not stop**, measured unless a line says otherwise:

- **A navigation.** A meta refresh reached the witness server in all three browsers. A link was
  not driven: no directive of this policy governs a navigation, so a link passes it by
  definition.
- **A `preconnect` hint**, which opened one connection that carried no request, in all three.
- **An image named by any other local file**, in all three. `file:` matches every `file:` URL, and
  in Chrome and Safari `'self'` alone already let such an image load. A `file:` URL with a host is
  covered as well, and on Windows such a URL may make the system contact that host; that case is
  unmeasured.
- **In Firefox, anything loaded from a local file.** Firefox 161.0 applied none of the policy's
  fetch directives to a `file:` URL: a script named by one ran, a style sheet applied and a frame
  loaded under the policy, and `img-src 'none'` did not stop a local image. Chrome and Safari
  stopped the script, the style sheet and the frame. Firefox did stop every inline script, style
  and event handler, and each of the 18 kinds of request that Appendix A counts as stopped; the
  meta refresh and the `preconnect` hint above passed it there as in the other two.

So the policy is the second line, not the first: the renderer escapes every value and writes no
image address other than `files/<sha256>.<ext>`. A page that carried foreign markup despite that
sent none of the requests Appendix A counts as stopped, in any of the three browsers on macOS,
while a meta refresh or a `preconnect` hint in it would still pass. A manifest link in all three
browsers, an icon link in Chrome and Safari, `prefetch` in Firefox and Safari, and a form submit
in Safari were not exercised. In Firefox such a page could still run a script that already lies
on the reader's disk.

`file:` stands beside `'self'` although no measured browser needs it: all three load the relative
images under `img-src 'self'` alone. It is kept because Firefox's source derives `'self'` for a
document without a host as a unique origin that matches nothing (read in `nsCSPUtils.cpp`, not
measurable while Firefox exempts local files), so a version that begins to apply the policy to
local files would otherwise hide a report's own images. It widens nothing that was measured.
Whether it stays is an open decision: dropping it gives the narrowest policy that was measured,
and doing so after a release moves every rendering digest of the conformance corpus again.

`--report-export` writes the same page with every file inlined as a `data:` URI, for a ticket
attachment or an e-mail. That is how a report is shared without Zensu.

### 6.7 Store and retention

The defaults are in §6.11. The sweep runs at `--report-begin`: by count in the calling repository
and by size across the store, oldest first. It never deletes a report another call is still
building: one whose lock is held, or an unrendered one touched within the last 14 days. The size
pass deletes only when the reports it may delete can bring the store under the cap; when the
reports it must keep hold more on their own, it deletes nothing for the cap and `--report-begin`
names their size. A report's lock is the plugin's external process lock: a live holder keeps it,
a holder that exited or whose process id was reused loses it at once, a call waits a bounded
number of attempts and then refuses, and the sweep takes a lock without waiting. `--report-begin`
holds the new report's lock from the creation of its directories until its binding is written,
so no other call's sweep can delete it half-written. A
published report counts like any other; deleting its
local copy does not touch its copy in Zensu. Each host keeps its own store (§7.1).

### 6.8 Safety

Three moments, three rules:

1. **Capture.** Unchanged. verify-feature's boundaries decide what a run may see and capture.
   Screenshots never show credentials, tokens or personal data, and console and network output is
   read only on unauthenticated targets.
2. **Write.** `--report-add` takes files only from the run directory (AC-006), and every text
   passes the secret screen and the path redaction (AC-007). The run directory must be ignored by
   the work tree that holds it and lie outside `.git`, so a capture can never be committed and never moves the tree
   fingerprint. The secret screen adds report-side rules to the shared patterns: authorization
   values, bearer tokens, JWTs, credentials in a URL, session cookies and API-key headers. An
   image needs a caption that states
   what it shows, because a screenshot filename without a description is not evidence.
3. **Publish.** Opt-in and preview (AC-013). A report with `run.authenticated: true`, or from
   remote mode, is published only after the user confirms that fact in the same turn, even when
   publishing is enabled in the config. Without a person present such a report is not published,
   and the run says so.

A rendered page also carries the Content-Security-Policy of §6.6. It is a second line behind the
renderer's escaping, and §6.6 names what it does not stop.

### 6.9 Without Zensu

Everything in §6.1 to §6.8 works without a Zensu account, without `gh` or `glab` and offline
(AC-016), and so does the review summary of §6.10, which needs only the forge's CLI. Viewing a
report means opening its `index.html`; sharing it means `--report-export` or the review summary.
No step of a run waits for Zensu, and the Zensu upload is the only step that talks to it.

### 6.10 Publishing

**Review summary** (`--report-publish --to pr`):

1. Preconditions: the VCS driver detects GitHub or GitLab with an authenticated `gh` or `glab`,
   and its `locate_pr` finds an open pull or merge request for the current branch whose head
   equals the report's `target.head`. A missing or unauthenticated CLI, another forge or another
   head stops the step with the cause; the driver never falls back to another forge. A report of
   an older commit is summarized only on explicit request, and its first line says so.
2. Immediately before posting, the step re-reads the request through the driver's `pr_state`. A
   merged or closed request gets nothing.
3. The body holds the verdict, the target identity (branch, head, tree), the coverage matrix,
   the failed and partial criteria with their notes, up to `evidence.report.prImages` images
   (failed criteria first, then P0 criteria in id order), and the Zensu link when the report was
   published there.
4. Posting goes through one new driver operation, `post_summary(id, body, images)`:
   - **GitHub:** `gh pr comment --attach '<file>#<alt text>'`, with the body referencing each
     image as `![alt](./<file>)`, which `gh` rewrites to the uploaded asset. `gh` 2.101.0
     attaches images and videos only, at most 50 files per command. Whether GitHub accepts WebP
     attachments is unmeasured; where it does not, the step decodes the image to PNG with `dwebp`,
     which ships with `cwebp`, for the upload.
   - **GitLab:** one merge-request note. Images go up through the project uploads endpoint
     (`POST /projects/:id/uploads`), which answers a Markdown link per file. Whether `glab` can
     send that multipart request is unmeasured; until step 4 of §9 measures it, the GitLab
     summary carries no images and says that the local report holds them.
5. Every publish posts a new comment or note. It names the report id, so a later run's summary
   reads as the newer one.

Language: the summary's headings are English, as is every section Zensu appends to a pull
request. Prose the step writes around the matrix follows the repository's language
(`skills/autopilot/rules/conventions.md`), and criterion text and observations are quoted from
the report as recorded.

**Zensu upload** (`--report-publish --to zensu`):

1. Preconditions: `zensu` on `PATH` at or above the version that ships `zensu evidence push`, a
   personal login, and a feature id. That version floor belongs to this step alone; the plugin's
   global `MIN_VERSION` does not move. The feature id comes from the publish request, else from
   the feature the chain is bound to, else the user is asked. It is never inferred from a folder
   or repository name.
2. The plugin calls `zensu evidence push <bundle> --feature <id> [--work-result <id>] --json` and
   nothing else. HTTP, authentication and retries live in the CLI (§8.7).
3. The CLI prints the report URL. The plugin stores that receipt in a `published.json` sidecar,
   so the manifest and its digest stay unchanged. A refusal is relayed unchanged (AC-028) and
   leaves the local report as it was (AC-016).

### 6.11 Configuration

Every key belongs to the `evidence.*` family of `docs/configuration.md`.

| Key | Default | Layers | Effect |
|---|---|---|---|
| `evidence.report.enabled` | `true` | merged; a project file can switch reports off but never on | `false` writes no report; the chat report is unchanged. |
| `evidence.report.dir` | unset, which keeps the store at `$CLAUDE_PLUGIN_DATA/evidence-report/v1` | user-level only | The store's parent: reports go to its `v1` directory. Refused inside a work tree unless git reports the path ignored. |
| `evidence.report.keep` | `30` | merged | Reports kept per repository; a begin trims only its own repository. |
| `evidence.report.maxBytes` | `2147483648` | user-level only | Size cap of the whole store. A project file cannot set it, because the sweep deletes other repositories' reports. |
| `evidence.report.webp` | `auto` | on only when every layer that sets it says `auto`; a project file can switch it off but never on | `auto` stores a PNG as a verified lossless WebP when libwebp's `cwebp` and `dwebp` are found (§6.5); `off`, and any other value, keeps the PNG. |
| `evidence.report.prImages` | `6` | merged | Images in the review summary, from 0 to 20. |
| `evidence.report.publish` | `ask` | user-level only; a project file can only set `off` | `ask` publishes only on request. `pr`, `zensu` or `pr,zensu` publish after every run, subject to rule 3 of §6.8. |

`evidence.report.publish` is read like the self-granted capabilities in §Config Resolution Order
of `docs/configuration.md`. A committed `.zensu/config.json` must not make every contributor's
screenshots leave their machine, so the project layer can withdraw publishing but never grant it.
`evidence.report.maxBytes` is read from the user layers alone for a related reason: the size sweep
deletes the reports of every repository in the store, so a committed file must not set it.
`evidence.report.dir` is read from the user layers alone because it decides where every
contributor's evidence is written, and `evidence.report.enabled` follows the `publish` rule: a
user-level `false` stands, and a project file can switch reports off but never back on. Each
ignored project value is disclosed by `--report-begin`.
`evidence.report.webp` is stricter still, because transcoding starts two programs, a capability
the plugin grants itself: it is on only when every layer that sets the key says `auto`. `off` in
the user or the project layer, and a value that is neither word, switch it off. `--report-begin`
discloses a user-level `off` that a project `auto` cannot lift, and a value that is neither word.
A configuration file that cannot be read or parsed sets nothing, as for every other key, so an
`off` in such a file does not apply until the file is repaired.

### 6.12 Versioning

- **Plugin: `patch`.** A new module, new `zensu-log.sh` verbs, a new operation in
  `hooks/lib/zensu-vcs.sh`, skill text and permissively read config keys. No hook, matcher,
  context-record or workflow-state field and no attestation moves. The acceptance and
  evidence-run record key sets stay as they are, because the manifest references their ids
  instead of extending them. The manifest is a new strict shape that no earlier installation
  reads; a later change to it is breaking and gets a new schema version.
- **Ports:** each under its own release rules; the manifest schema is shared, so a port never
  changes it alone.
- **zensu-cli:** new verbs. The plugin's global floor stays; the publish step checks its own.
- **Zensu service:** additive endpoints behind a per-organization flag.

## 7. Ports

### 7.1 One core, thin adapters

Zensu receives reports from every host, so a report must look and validate the same everywhere.
The logic therefore lives in one file, `hooks/lib/evidence-report-v1.js`, written host-agnostic
(AC-018), and each port carries an unchanged copy. The file needs Node and the sibling modules it
reuses: the acceptance reader, the evidence-run reader and secret screen, and the path redaction.
A port that lacks one of them ports it first.

What each host adapter owns:

| Part | Host adapter |
|---|---|
| Transport | the verbs of §6.1, in the host's own helper |
| Tool path | the caller's `PATH`, handed to the core with `--report-add`; without it the core starts no tool and every image stays as captured (§6.5) |
| Store root | the host's own plugin data directory; each host keeps its own store |
| Capture | the file-producing capture commands of its drivers (§6.3) |
| Skill text | the host's invocation syntax and rule files |
| Review summary | the host's VCS driver, where it has one; without one the host has no review summary |
| Zensu upload | unchanged: it is a call to the `zensu` CLI on every host |

The conformance corpus (AC-019) keeps the copies honest: every port's suite runs it, so a copy
that drifted fails in that port's suite instead of in Zensu. Every port keeps the plugin's rule
that Zensu is optional (AC-020).

### 7.2 State of the ports

Read from each port's repository on 2026-11-07:

| Port | verify-feature | Acceptance records | VCS driver | Next |
|---|---|---|---|---|
| `zensu-copilot` (GitHub Copilot CLI) | yes, as `zensu-verify-feature` | yes | yes | port the report after steps 1 to 3 of §9 |
| `zensu-antigravity` | yes | yes | yes | port the report after steps 1 to 3 of §9 |
| `zensu-codex` | no | no | no | first port verify-feature, the acceptance records and the VCS driver |
| `zensu-kiro` | no | no | no | first port verify-feature, the acceptance records and the VCS driver |

`zensu-copilot` builds from its own sources and keeps an upstream snapshot only for provenance and
parity checks, so its copy of the core is taken over by hand, as in every other port.

### 7.3 Order

1. Copilot and Antigravity, right after steps 1 to 3 of §9. Their review summary follows with
   step 4 and their Zensu upload with step 8.
2. Codex and Kiro once their verify-feature, acceptance-record and VCS-driver ports have landed.
   Those prerequisites are work of their own and not part of this spec.

## 8. The Zensu service and the CLI

This section fixes the behavior the plugin and its ports rely on. The service and its web viewer
are built in the service's repository, the CLI verbs in the `zensu` CLI's repository.

### 8.1 Contract

| Step | Request | Answer |
|---|---|---|
| Open | `POST /v1/features/{featureId}/evidence-reports` with `manifest.json`, its SHA-256 and an optional `workResultId` | `reportId`, `missing` (the file digests the service lacks), `maxFileBytes`, `limits` (the tier's caps and their current use), and for each missing file either a pre-signed upload URL or the API path to `PUT` it |
| Upload | `PUT` of one missing file, at most `maxFileBytes` | `201`, or `200` when the digest is already stored |
| Finalize | `POST /v1/evidence-reports/{reportId}/finalize` | the report URL once finalize accepted the report (§8.4); otherwise the faults |
| Read | `GET /v1/evidence-reports/{reportId}` | the manifest and short-lived URLs for its files |
| List | `GET /v1/features/{featureId}/evidence-reports` | the feature's reports, newest first, paginated |
| Delete | `DELETE /v1/evidence-reports/{reportId}` | `204` |

Every refusal names its cause: an unknown or invisible feature, a report id already finalized
with another digest, a file over `maxFileBytes`, a refused content type, a validation fault, an
exceeded quota, or an organization for which the feature is not enabled.

**Idempotent and resumable.** The same manifest digest for the same report id returns the
existing report. A different digest is a conflict, because a rendered report is immutable. A
repeated open lists only what is still missing.

### 8.2 Data

- **A report** holds its tenant, product and feature; its client id (`vr1_…`), unique per
  tenant; the validated manifest and its digest; its state, `open`, `finalized` or `expired`;
  verdict, host, repository, branch and head commit for listing; the uploader; the optional
  AI-work result; the times it was opened and finalized; and the bytes it references.
- **A file** is identified by its tenant and its SHA-256 and holds type, bytes, width, height and
  storage key. Every report of a tenant that references a digest shares the one file; that is the
  deduplication.
- **A criterion row** per report criterion holds the criterion id and its state, so a feature's
  criteria can show their latest evidence without reading manifests.

### 8.3 Storage and upload

- Files live in the service's object store under a key derived from the tenant and the digest,
  never from a name the client chose.
- An upload goes straight to the object store through a pre-signed URL where the store supports
  one, else through the API path, which streams to the store. The client never sees a store
  credential.
- Files go up one per request, so a report of any size travels in pieces of one file each.
  Evidence files have their own limit, `maxFileBytes`, 50 MiB by default and never below the
  plugin's per-file cap (§6.5). The service's general upload cap of 10 MiB per upload does not
  apply to them: a pre-signed upload goes straight to the object store, and the API path streams
  the file instead of buffering it. A report as a whole is bounded only by the tenant's quota
  (decision 5).
- The content type is judged from the bytes: PNG and WebP by their signatures, with the
  dimensions read from the header and capped at 100 million pixels, and text as UTF-8 without
  control characters other than tab and line breaks. Everything else is refused, SVG and HTML
  included.
- The manifest is at most 1 MiB and is parsed with depth and string-length limits.
- For the web application the service derives one display rendition from each uploaded image, a
  thumbnail, and no screen-sized copy: a capture normalized at the run's viewport (§6.5) already
  fits a screen, and the browser scales any other original (decision 5). A rendition is marked
  derived and never served as evidence, and the original stays downloadable unchanged.
- An open report expires after its tier's open time, at least 7 days. Until then its files count
  toward the tenant's quota; on expiry the files only it referenced are reclaimed.

### 8.4 Finalize

Finalize verifies every file's SHA-256, validates the manifest against schema version 1, and
re-runs the checks of AC-003 and AC-004. The service's implementation is its own, but its suite
runs the conformance corpus of AC-019, vendored from this repository, so the plugin and the
service accept and refuse the same reports. A case may lower the manifest cap through its
`limits.maxManifestBytes`, the one limit a case can set, and the service reads that case with it. A finalized report is immutable. Every criterion
that carries a Zensu ref is matched to the feature's requirement row of that ref; whether
finalize also sets that row's verification is decision 9.

### 8.5 The viewer in the Zensu web application

- **Feature page:** an Evidence tab that lists the feature's reports newest first, each with
  verdict, host, branch, short head, date and coverage counts.
- **Report page:** a header with verdict, target identity, host, uploader and links to the commit
  and the pull request; the coverage matrix first; then the steps with their evidence, images as
  renditions that open the unchanged original at full size, text captures monospaced, requests as
  a table; then signals, consent, limitations and resources.
- **Comparison:** two reports of one feature, criterion by criterion, so a criterion that went
  from `pass` to `fail` stands out, with the images of steps that share a title side by side when
  their viewport and scale factor match.
- **Criteria:** each requirement row a report names by ref shows the latest report's state for it
  and links to that report.
- **AI-work review:** the review screen of a result shows the reports linked to it. Accepting the
  result stays a human decision.
- **Rendering:** every string escaped, inline code the only formatting, images served through
  short-lived URLs with their declared type and `nosniff`, and alt text taken from the captions.
  No uploaded markup is ever rendered (decision 1).

### 8.6 Access, retention and quota

- Readers are the feature's readers. Uploads need write access to the product. A report is
  deleted by a product admin or its uploader.
- Upload, finalize and deletion are audited.
- A report is customer content: it is part of a data export and is removed by a deletion request.
- Two kinds of cap. Fixed for every tier, because the plugin relies on them: 50 MiB per file and
  2,000 files per report. Set per tier (decision 5):

| Cap per tier | Free | Pro | Team | Enterprise |
|---|---|---|---|---|
| Stored bytes after deduplication, per seat | 1 GiB | 1 GiB | 1 GiB | 1 GiB |
| Reports open at once, per seat | 5 | 5 | 5 | 5 |
| Open time, never below 7 days | 7 days | 7 days | 7 days | 7 days |
| Files of a finalized report that is not kept | 3 months | 6 months | 12 months | 12 months |

- Both per-seat caps are pooled across the organization, so one member can use what another
  leaves. The stored bytes count the files the tenant uploaded; derived renditions do not count,
  so the plugin can compute an upload's use from its bundle.
- A finalized report is kept when it backs an accepted AI-work result or a released revision; it
  keeps its files for as long as its feature exists. Every other finalized report loses its files
  once its tier's time has passed since it was finalized, and keeps its manifest and criterion
  rows, so the history of runs stays readable without its images. A file is reclaimed only when
  no remaining report references it, because the reports of a tenant share files (§8.2).
- The open answer reports the tier's caps and their current use, so the plugin's preview shows
  the remaining quota before the first file goes up. A refused upload names the cap it hit and
  the use.

### 8.7 The CLI

| Verb | Effect |
|---|---|
| `zensu evidence push <bundle> --feature <id> [--work-result <id>] [--json]` | open, upload what is missing, finalize; prints the report URL, or with `--json` one object holding `reportId`, `url`, `uploaded`, `reused` and `bytes` |
| `zensu evidence list --feature <id> [--json]` | the feature's reports, newest first |
| `zensu evidence get <report-id> [--json]` | one report's manifest and its file URLs |

The CLI runs under a personal login only (decision 8). It computes every digest itself, reads
nothing outside the bundle, refuses a symlink inside it, and resumes an interrupted push.

### 8.8 Rollout

- The service ships behind a per-organization flag. For an organization without it, open answers
  that the feature is not enabled, and the plugin relays that.
- Order: service and viewer, then the CLI release, then the plugin's `--to zensu`.
- Metrics: reports opened and finalized, faults per check, bytes stored, and the share of files
  deduplication saved.

## 9. Build steps

Each step names its key decisions and the default this spec takes. Steps 1 to 4 need nothing from
Zensu.

**Step 1 — Core module, verbs and conformance corpus** (plugin, `patch`).

- One host-agnostic owner, `hooks/lib/evidence-report-v1.js`, transported by `zensu-log.sh`. A
  skill-local script was rejected, because the verbs need the session binding and the acceptance
  reader.
- Ids `vr1_<13 digits>_<12 hex digits>`, like `av1_` and `er1_`.
- Strict manifest, deterministic renderer, atomic writes, symlink refusal.
- The conformance corpus under `tests/fixtures/evidence-report/v1/`: manifests and files, each
  with its expected rendering digest or its expected refusal.
- A unit file registered in `tests/profiles/unit-files.v1.json` runs the corpus and covers the
  containment of `--report-add`, the redaction and the retention.

**Step 2 — Wiring verify-feature** (plugin, `patch`).

- `skills/verify-feature/SKILL.md` may not grow, and many of its lines are pinned. It gains only
  short pointers at Phase 2, Phase 3 and Phase 5, offset by moving the description of the Phase 5
  table into a new `rules/report.md`, which carries the verbs and the capture rules.
- The capture commands per driver go into `rules/drivers.md` §8 and
  `rules/browser-verification.md` §5.
- Default: `--report-add` right after each inspected capture, never batched at the end, like the
  rule to record each criterion right after observing it.

**Step 3 — Images and viewer** (plugin, `patch`).

- Lossless WebP through `cwebp` when it and `dwebp` are installed, stored only after the decoded
  WebP equals the PNG pixel for pixel (§6.5). No test needs libwebp: the unit cases drive stand-in
  tools, and the real tools were measured once (Appendix A).
- The Content-Security-Policy meta element of §6.6, measured on `file://` in Chrome, Safari and
  Firefox (Appendix A). Every rendering digest of the conformance corpus moved with it.

**Step 4 — Review summary through the VCS driver** (plugin, `patch`).

- One new driver operation, `post_summary`, beside `locate_pr` and `pr_state` in
  `hooks/lib/zensu-vcs.sh`.
- GitHub first. Measure: whether GitHub accepts WebP attachments, and how a comment with six
  images renders in the pull-request timeline.
- GitLab: the text summary at once, images once the multipart uploads call through `glab` is
  measured.
- Follow-up: the Evidence cell of the acceptance-criteria table in `templates/pr-body.md` and
  `templates/autopilot-pr-body.md` names the step and the image per criterion, from the newest
  report for the request's head.

**Step 5 — Zensu service** (service repository).

- The data, storage, endpoints, finalize, access and audit of §8, with the conformance corpus
  vendored from this repository.
- Default: one file per request, the missing-digest protocol, a report immutable after finalize,
  open reports expiring after 7 days at the earliest, caps per tier as in §8.6, the whole feature
  behind a per-organization flag.

**Step 6 — Viewer in the Zensu web application** (service repository).

- The Evidence tab, the report page, the comparison, the criterion links and the AI-work review
  screen of §8.5.
- Default: every string escaped, no uploaded markup rendered.

**Step 7 — CLI verbs** (`zensu` CLI repository).

- `zensu evidence push`, `list` and `get` of §8.7, under a personal login only.

**Step 8 — Zensu upload in the plugin** (plugin, `patch`).

- `--report-publish --to zensu` with its CLI version floor. Service refusals are relayed
  unchanged.

**Step 9 — Ports** (each port's repository).

- Copilot and Antigravity after steps 1 to 3, their review summary with step 4 and their Zensu
  upload with step 8.
- Codex and Kiro once their prerequisites of §7.3 have landed.
- Default: an unchanged copy of the core and the corpus, plus the host adapter of §7.1.

**Step 10 — Autopilot VALIDATE** writes the same report for the evidence it captures per
criterion.

**Step 11 — Zensu requirements wiring** (service, CLI and plugin).

- The six items of §12, in their order. Steps 1 to 10 do not wait for them: until they land, a
  report's criteria carry no Zensu ref and link to no requirement row.

Dependencies: step 1 before steps 2 and 4, step 2 before steps 3 and 10; step 5 before steps 6
and 7, step 7 before step 8; step 9 after steps 1 to 3, with each port's summary after step 4 and
its upload after step 8. Step 11 runs alongside; the write-back of decision 9 needs it.

## 10. Decisions

Decisions 1 to 4 were taken on 2026-11-04 and decisions 5 to 8 on 2026-11-07. Each names what it
costs and what it rejected.

1. **Zensu viewer: native rendering from the manifest.** No code from an upload ever runs on the
   Zensu origin, runs can be compared over time, and criteria link in place. It costs a viewer in
   the Zensu web application. Rejected: serving the generated HTML from a sandboxed origin, which
   is cheaper and gives up all three.
2. **Default store: the plugin data directory.** It is guarded, lies outside every work tree and
   is kept across plugin updates. Rejected: `~/.zensu/reports`, which is easier to find in a file
   browser but puts data into the configuration directory. `--report-list` prints each report's
   location, and `evidence.report.dir` moves the store.
3. **Publishing default: `ask`, for Autopilot runs too.** An Autopilot run that opens a pull
   request publishes no images until the user asks or enables publishing in the user-level
   config. Rejected: `pr` for Autopilot runs, which publishes images before a person has looked
   at them.
4. **Language: English.** Reports follow the plugin's language rule. A team that works in another
   language reads English evidence until the viewer's fixed strings are localized, which this
   spec leaves out.
5. **Zensu caps and retention per plan tier.** Every cap beyond the fixed protocol caps is set per
   tier (§8.6): 1 GiB of stored bytes after deduplication and 5 reports open at once per seat,
   pooled across the organization, and an open time of 7 days, the same on every tier. A report
   that backs an accepted AI-work result or a released revision keeps its files for as long as its
   feature exists; every other finalized report keeps its manifest and loses its files after 3
   months on Free, 6 on Pro and 12 on Team and Enterprise. The service derives a thumbnail and no
   other rendition (§8.3). Basis (Appendix A): a report comes to about 2.1 MB on average and
   6.1 MB at most, so a developer who uploads one every working day, five times the measured
   rate, fills about half of a seat's 1 GiB in the first year on a 12-month tier and adds under
   0.1 GB a year after that. It costs a byte count per organization that the service keeps
   current as files arrive and are reclaimed, counting references because reports share files.
   Rejected: a screen-sized copy beside each thumbnail, which adds three quarters to every image
   while a normalized capture already fits a screen; and one cap per organization regardless of
   its seats, which a growing team outgrows first.
6. **Forges: a review summary on GitHub and GitLab, through the VCS driver.** These are the two
   forges the plugin's driver serves (`docs/vcs-driver-spec.md`), so every team the plugin
   reviews for gets a summary. It costs one driver operation and a GitLab measurement. Rejected:
   GitHub only, which leaves the plugin's GitLab teams without one; and the full report as a forge
   attachment, because `gh` attaches only images and videos, because GitLab and GitHub would
   differ, and because a complete evidence set in a forge reaches everyone who can read the
   repository.
7. **Ports: one unchanged core and a shared conformance corpus; one store per host; Zensu as the
   place where hosts meet.** It costs the discipline of keeping the core host-agnostic. Rejected:
   a reimplementation per port, which drifts; and a store shared across hosts, which would give up
   decision 2.
8. **Uploads under a personal login only in version 1**, as for AI-work capture. Rejected for now:
   API keys, CI tokens and work-order session tokens. A later version may let a work-order token
   upload for its own order's feature.
9. **Still open: does a report set a Zensu requirement's verification?** Recommended: yes. For
   each criterion with a Zensu ref that a finalized report decided, finalize sets the row's
   verification to `verified` or `failed` with source `agent` and a link to the report; `partial`
   leaves the row unchanged. A person can override or waive, and a later report replaces an
   earlier agent verdict but never a manual one. It costs a service write path that does not
   exist yet (§12). Rejected: only proposing a verdict for a person to confirm, which turns every
   run into review work; and never writing back, which leaves the rows unverified.

## 11. Known gaps

- **Attested evidence stays attested.** A model can attach a misleading image or write a wrong
  observation. The renderer and the service check structure, not truth.
- **The store is plugin data, not a boundary.** A Bash redirect from the main thread can forge a
  manifest, the residual of every plugin store.
- **Images are not machine-screened** for personal data. The capture rules and the preview before
  publishing carry that.
- **Encoder availability.** Without libwebp's `cwebp` and `dwebp` a report stays at PNG size, and
  so does every image whose transcode cannot be verified (§6.5). On Windows every image stays a
  PNG, because the tool lookup is switched off there until it is measured.
- **The tool pair is trusted as far as `PATH` is.** The lookup refuses a pair inside the project
  and a pair that everyone may write or replace through a directory above it. It does not judge
  who owns the pair, nor a link that a symlink chain passes through in a directory on neither
  the spelled nor the real path; a file swapped between the lookup and the start is followed,
  and a pair that was found and left unused prints no reason (§6.5).
- **The viewer's policy stops loads, not everything.** A navigation, a `preconnect` connection and
  an image from another local file pass it in every measured browser, and Firefox applies it to
  nothing that is loaded from a local file, a script included (§6.6). A manifest link, an icon
  link and `prefetch` fired in too few browsers to count as measured, and a form submit was not
  driven in Safari (Appendix A). The renderer's escaping stays the first line.
- **Equal WebP files are stored once.** Two captures that become the same WebP, as two PNGs with
  equal pixels can, share one file, and its entry keeps only the first capture's digest as
  `source_sha256`.
- **One file is at most 50 MiB.** A very long full-page screenshot at high resolution can exceed
  that and has to be taken in parts. Video, out of scope for version 1, will need multipart
  uploads.
- **Unmeasured:** WebP attachments on GitHub, the multipart uploads call through `glab`, the file
  captures for the Android emulator and for desktop windows, pre-signed uploads with digest
  enforcement on the service's object store, and Windows paths. On Windows that includes the WebP
  transcode, which is therefore switched off there, and the viewer's policy, a `file:` URL with a
  host among it; the policy was measured on macOS only.
- **A report is a snapshot.** It shows what held on its tree. The summary names head and tree, so
  a reader can tell it from the current state.
- **Codex and Kiro wait** for their verify-feature ports before they can produce a report.

## 12. Acceptance criteria from Zensu

A feature's acceptance criteria are what verify-feature has to prove, so a user who works with
Zensu expects the criteria stored on the feature to reach the run, and the run's result to flow
back. A read-only audit on 2026-11-07 found that only the storage exists:

| Link | State on 2026-11-07 |
|---|---|
| The service stores the criteria | **Exists.** A feature holds requirement rows of kind acceptance or functional, each with a stable ref (`AC-###` or `FR-###`), a state (draft, agreed, deprecated), a verification method, and a verification status (unverified, verified, failed, waived) with its source (test, manual, agent). Both kinds take their numbers from one sequence per feature, so one feature's refs can read `AC-001`, `FR-002`, `AC-003`. |
| The service accepts a verification | **Missing.** No request sets the verification status. |
| The CLI reads or writes the rows | **Missing.** No `zensu` verb reaches them. |
| The plugin imports them into the plan | **Missing.** `/zensu:implement`, `/zensu:pilot` and `/zensu:build` build the plan's `## Requirements` table without them, and no plan row keeps a feature id or a Zensu ref. |
| verify-feature verifies them | **Partial.** Chain mode verifies the plan's `AC-###` rows; a standalone run reads a feature id as free text. |
| Results flow back to Zensu | **Missing.** |

What this spec contributes: the manifest's `coverage.criteria[].zensu` field carries the feature
and the ref of every criterion that came from Zensu, finalize links those criteria to their rows
(AC-027), and decision 9 decides whether it also sets their verification.

What has to happen elsewhere, in this order:

1. **Service:** a request that sets a row's verification status with its source and the report or
   test behind it, and writes an audit entry; a waiver keeps its reason.
2. **CLI:** a `requirements` group that lists, reads, verifies and waives a feature's rows.
3. **Plugin, import:** `/zensu:implement`, `/zensu:pilot` and `/zensu:build` import a feature's
   agreed, non-deprecated rows into the plan table. A row keeps the service's ref as its id,
   because the service numbers both kinds from one sequence, and names `zensu:<feature id>` in the
   `Source` column.
4. **verify-feature:** a run given a Zensu feature id without a plan reads that feature's rows as
   its criteria.
5. **Write-back:** decision 9, through the Zensu upload of §6.10 or the CLI group of item 2.
6. **Work orders** still read the feature's older free-text criteria; they move to the rows.

None of this blocks §6. Until it lands, a report's criteria carry no Zensu ref, and the report
works with and without Zensu as before.

## Appendix A — Measurements

Of 2026-11-03:

- Sample: 14 single-file reports of one consuming web project, from 0.4 MB to 13.7 MB, as counted
  on 2026-11-07. The largest embedded 44 PNG screenshots in 13,727,808 bytes.
- The 45 PNGs of that report's folder: 10,438,759 bytes. `cwebp -lossless -z 6`: 4,796,876 bytes.
  `cwebp -q 85`: 3,654,920 bytes.
- `gh pr comment --help` of `gh` 2.101.0: `--attach` takes an image or video file, up to 50 files
  per command, and rewrites a body reference to an attached file.

Of 2026-11-07, the basis of decision 5:

- The 14 reports were written by one developer from 2026-07-20 to 2026-10-30, 4.2 a month for 3.3
  distinct work items a month. They embed 274 PNG screenshots: 19.6 per report on average, 14.5
  median, 57 at most.
- Per image over the 45 files above, 41 captured at 1440 by 900 and 4 at 2880 by 1800: 106,597
  bytes losslessly transcoded, 97,707 bytes for the 41 alone. A lossy thumbnail 320 pixels wide
  takes 5,092 bytes, 4.8 percent of that; a lossy copy at quality 85 takes 81,220 bytes,
  76 percent.
- Assuming every report mixes its images like that folder, a report stores 2.09 MB on average,
  1.55 MB median and 6.08 MB at most, thumbnails not included. Deduplication, manifests and text
  captures were not measured and are not counted.
- Per developer, with one report kept for good per work item: 82 MB a year of kept reports, plus
  the other reports inside the tier's time. At the end of the first year on a 12-month tier that
  is 0.10 GB at the measured rate and 0.53 GB at an assumed 21 uploads a month, one per working
  day.

Of 2026-11-20, the basis of the browser capture rules of build step 2, measured with playwright-cli
0.1.24, headless, on a plain session outside the consent gate, against a loopback server and with
the run config the run-config helper writes:

- A fresh browser starts with a 1280 by 720 viewport, and `resize 1440 900` sets it to 1440 by
  900 (`page.setViewportSize`).
- After that `resize`, `screenshot --hires`, which asks for the device scale, still wrote a 1440
  by 900 PNG, so the device scale factor is 1; `--full-page` wrote 1440 by 2514 for the probe page.
- The link the command prints is relative to the working directory and names a file in the run
  directory's `browser/` folder, so the skill adds it by its absolute path.

Of 2026-11-24 and 2026-11-25, the basis of build step 3, on macOS 26.7.2:

- libwebp 1.6.0 on its own (`cwebp` and `dwebp`): `cwebp -lossless -exact` followed by `dwebp`
  returned an 8-bit RGB and an 8-bit RGBA image pixel for pixel. Without `-exact` the RGBA image
  came back with other colour values under alpha 0. A PNG with `gAMA` 1.0 and neither `sRGB` nor
  `iCCP` came back with other pixels. A 16-bit PNG was written as 8 bits without a message. With
  `-metadata icc` the WebP's `ICCP` chunk held the PNG's profile byte for byte, and a PNG with
  `iCCP` and `gAMA` 1.0 came back with other pixels.
- The same tools through the core's add function: a 64 by 48 RGB PNG of 8,516 bytes was stored as
  a WebP of 862 bytes, an RGBA one of 10,084 bytes as 86, and one with an ICC profile of 8,871
  bytes as 1,424. A PNG with `sRGB` and `gAMA` 1.0 became the same WebP as the first. Kept as PNG,
  each with its reason: `gAMA` 1.0 or 2.2 without `sRGB` or `iCCP`, `iCCP` with `gAMA` 1.0 (the
  decoded WebP differed), 16-bit RGB and 8-bit grayscale. Three page captures: 1285 by 2204 from
  Chrome, 150,582 bytes to 46,082 in 170 ms; 1285 by 2204 from Firefox, 186,462 bytes to 48,108 in
  166 ms; a macOS window capture of 3384 by 2168, 463,147 bytes captured and 462,473 after its
  `eXIf`, `iDOT` and `iTXt` chunks were dropped, to 144,566 in 1.6 s. A check outside the core
  decoded every stored WebP again and found the captured pixels, and the scratch directory was
  empty afterwards.
- The viewer's policy, measured on the renderer's output: a report with one PNG and one WebP that
  the core had transcoded, opened from `file://`. Chrome 158.0.8127.37, headless, over the DevTools
  protocol. Firefox 161.0, headless, over WebDriver BiDi with a fresh profile, run from its disk
  image. Safari 27.2 (21625.2.8.18.4): pages opened in the running browser and its window captured.
  - Under the policy all three loaded both relative images and applied the page's style sheet. In
    Chrome and Firefox both images reported their natural width of 480 and the style sheet its 24
    rules, the full-page screenshot of `index.html` equalled that of the same page without the
    element pixel for pixel, and so did `export.html`; Chrome reported no policy issue for the page
    and Firefox no policy message. In Safari the window capture showed both images.
  - `img-src 'self'` without `file:` loaded the relative images in all three as well.
  - A probe block injected into the page, under the policy: no inline script, external script or
    event handler ran, and no injected `style` element or `style` attribute applied, in all three.
    A loopback witness server received none of the requests the same page without the element
    sent: 18 kinds in Chrome and in Firefox, 17 in Safari, among them a script, a style sheet, an
    `@import`, a font, a CSS background, an image, a `srcset`, an SVG image, an image input, a
    table background, an image preload, a frame, an object, an embed, a video and an audio file.
    Chrome reported 20 policy issues and Firefox 19 policy messages.
  - A `base` element that named the witness server changed nothing under the policy in all three;
    without the element both images broke and three requests reached the server.
  - A submit of an injected form, started by the driver, was refused under the policy in Chrome
    and Firefox. Safari was not driven, so it was not exercised there.
  - Not stopped in all three: a meta refresh, which reached the witness server; a `preconnect`
    hint, which opened one connection without a request, on a port of its own per browser and
    variant; and an image named by a `file:` URL in another directory.
  - Local files: with a script, a style sheet, a frame and an image named by `file:` URLs in
    another directory, Chrome and Safari stopped the script, the style sheet and the frame under
    the policy and under `img-src 'self'` alone, and loaded the image under both. Firefox ran the
    script, applied the style sheet and loaded the frame and the image under the policy, under
    `img-src 'self'` alone and under `img-src 'none'`, with no policy message.
  - Not exercised, because the probe fired in no variant: a manifest link in all three, an icon
    link in Chrome and Safari, and `prefetch` in Firefox and Safari.
  - A first Firefox run used its headless `--screenshot` mode. It captured pages before their
    images were painted, among them a page without any policy, so no figure here rests on it.
- Read, not measured: in Firefox's `nsCSPUtils.cpp`, `'self'` for a document whose address has no
  host is a unique origin that permits nothing; in Chromium's `csp_source.cc`, a source without a
  host matches by scheme alone.
- Windows was not measured: neither the transcode nor the policy.
