---
paths:
  - "hooks/lib/zensu-cli-version-v1.js"
  - "tests/structure/zensu-cli-version-v1.test.js"
  - "tests/structure/fixtures/zensu-cli-*-floor-help.json"
  - "tests/structure/fixtures/record-zensu-cli-floor-help.js"
  - "hooks/lib/ai-work-preflight-v1.js"
  - "hooks/lib/ai-work-capture-v1.js"
  - "hooks/lib/context-auto-load-v1.js"
  - "agents/zensu-plm.md"
  - "skills/implement/references/knowledge-context.md"
  - "tests/structure/test-knowledge-context.sh"
  - "hooks/lib/zensu-doctor.sh"
  - "hooks/lib/zensu-doctor-report.js"
  - "hooks/session-start-banner.sh"
  - "hooks/lib/work-order-v1.js"
  - "skills/setup/SKILL.md"
  - "skills/doctor/SKILL.md"
  - "skills/doctor/references/zensu-cli.md"
  - "skills/pilot/SKILL.md"
  - "skills/pulse/SKILL.md"
  - "tests/structure/test-pulse-skill.sh"
  - "docs/work-order-mode.md"
  - "docs/operations.md"
  - "docs/cli-install-update.md"
  - "tests/structure/test-setup-skill.sh"
---

# zensu-cli Version Floor (`hooks/lib/zensu-cli-version-v1.js`)

**One module owns the floor and the install commands.** `MIN_VERSION` is the oldest zensu-cli
release the plugin supports: 0.22.0, because the skills pass long free text through the file
flags `--content-file`, `--description-file`, `--candidates-file`, `--result-file`,
`--findings-file` and `--conditions-file`, which zensu-cli 0.22.0 (`d466f49`, #52) is the first
release to declare, and an older CLI refuses each such call with `unknown flag`
(`.claude/rules/skill-argument-placeholders.md`). The floor before it, 0.18.0, came from
`REQUIRED` in `hooks/lib/ai-work-preflight-v1.js`, which asks for `ai-work context --feature`,
`ai-work start --feature` and `--maintenance-reason`; `hooks/lib/ai-work-capture-v1.js` runs that
check before every `begin`, so a CLI older than 0.18.0 answers `cli_incompatible` for every goal.
The floor before that, 0.10.0, came from ghost-scan pagination (zensu-monorepo#954) and wiki list
pages. 0.22.0 covers all three. Two lower bounds have a case, and both read one fixture: the help
of the floor release, recorded from its release archive in
`tests/structure/fixtures/zensu-cli-<MIN_VERSION>-floor-help.json`. The unit case `the floor
release declares every flag the AI-work capture preflight requires` replays its `ai-work` help
through `check()` and requires `compatible`, so a flag `REQUIRED` adds that the floor release
lacks fails it; `FT8` of `tests/structure/test-skill-workflow-markers.sh` holds every free-text
flag site of the skills against the help of its command there. Both find the fixture by the
floor's name and require its version line to equal `MIN_VERSION`, so raising the floor
re-records the fixture from the new floor release's binary into the file named after the new floor:
`node tests/structure/fixtures/record-zensu-cli-floor-help.js "<archive> of the zensu-cli v<floor> release, sha256 <digest>" <zensu binary> > tests/structure/fixtures/zensu-cli-<floor>-floor-help.json`
writes the version line, the help of every `ai-work` subcommand `REQUIRED` names (the recorder
reads the exported table) and the help of every command the skills send free text to, to stdout.
`FT8` requires exactly one `zensu-cli-*-floor-help.json`, the one named after `MIN_VERSION`, so the
previous floor's fixture must go in the same change. A third lower bound has no case: the capability probe of
`hooks/lib/context-auto-load-v1.js` needs `knowledge context-pack --agent`,
`knowledge get --context-load` and `knowledge context-search --query`, which the 0.22.0 binary
declares. `FLOOR_REASON` says that in one sentence, and the doctor's old row and the banner's
old-CLI warning render it. `INSTALL` holds the Homebrew install and upgrade commands, `install.sh`
and `install.ps1`. The doctor, the session banner, `/zensu:setup` and the work-order refusal in
`probe()` of `hooks/lib/work-order-v1.js` read the module, and so does the AI-work capture
preflight, whose `cli_unavailable` and `cli_incompatible` guidance takes the install commands and
`INSTALL.homebrewUpgrade` from it and names the plugin's install guide by absolute path.

**The banner's old-CLI warning holds no copy.** The banner's lookup `node` call writes
`FLOOR_REASON`, `INSTALL.homebrewUpgrade`, `INSTALL.script` and `INSTALL.powershell` as `reason=`,
`upgrade=`, `script=` and `powershell=` lines after the lookup's own `state=`, `version=` and
`floor=` lines, and `_zensu_cli_field` reads each line back. The warning runs only when that call
reported `state=old`, so the module has always loaded by then. The missing-CLI line keeps literal
install commands, because it must print even when the module did not load.

Every prose copy — README Install and Requirements, the `docs/operations.md` troubleshooting row,
the §Update block of `docs/cli-install-update.md`, the seven skill prerequisites, `/zensu:setup`, the
banner's missing-CLI line and `docs/work-order-mode.md` — is pinned to the module by `P10a`-`P10e`
in `tests/structure/test-setup-skill.sh`. `P10a` and `P10e` also fail when the banner copies the
upgrade command or the reason again, or stops naming `INSTALL.homebrewUpgrade` or `FLOOR_REASON`;
`B16a` in `tests/structure/test-session-start-banner.sh` compares the warning the banner prints with
the module. **Raising the floor is more than the constant.** The edits that move with it: the
constant; a new `FLOOR_REASON` that names what the releases below the new floor get wrong; the
prose those checks name; the consequence sentence of `skills/doctor/references/zensu-cli.md`; the
floor fixture, re-recorded under the new name with the recorder above, and the old fixture
deleted; every skill site `FT8` then names, because a flag the new floor declares as a file form
turns its inline site into a finding; and the write-gate command tree
`tests/structure/fixtures/zensu-cli-tree.txt` with whatever `Z2` of
`tests/structure/test-zensu-cli-map-drift.sh` then names (`.claude/rules/cli-command-classification.md`).
`P10e` requires the new reason, word for word, in the README Requirements and in `/zensu:setup`
Phase 0; the banner and the doctor print it from the module. A floor raised without a new reason
keeps telling users the previous floor's reason.

**One Homebrew upgrade spelling.** `INSTALL.homebrewUpgrade` is
`brew update && brew upgrade --cask mkitconsulting/tap/zensu`, one command that every surface
names verbatim. `brew upgrade` runs `brew update` only once `HOMEBREW_AUTO_UPDATE_SECS` has passed
(brew(1)), so on its own it can miss a release the tap published since, and the tap-qualified name
is the one `INSTALL.homebrew` installs. The unit file pins the value, and its floor-release case
requires the preflight's refusal guidance to name it and the install guide's absolute path, and the
guidance for an absent CLI to name the three install commands. `P10a` proves only that the current
spelling is present, so the earlier `brew upgrade --cask zensu` could return beside it; `P10f`
fails when that spelling appears in `README.md` or in any file under `docs/`, `skills/` or `hooks/`,
and when its scan cannot read the tree. It is the only earlier spelling the history holds.
`CHANGELOG.md` keeps it as release history, and `P10f` does not read it.

**Warn, never block.** No gate compares the version with the floor. An older CLI still runs, but
every skill call that passes free text through a `-file` flag fails with `unknown flag`, which
zensu-cli reports through `markFlagParseError` with pflag's own text. Below 0.18.0 AI-work capture
also refuses to begin: `check()` in `hooks/lib/ai-work-preflight-v1.js` reads the CLI's `ai-work`
help for the flags `REQUIRED` names and answers `cli_incompatible`, a capability probe rather than
a version check. The doctor row and the banner say what an older release gets wrong, and
`skills/doctor/references/zensu-cli.md` tells the model both consequences.

**The PATH walk is a hand copy of `playwright-cli-version-v1.js`.** It walks `PATH` as the shell
does and answers `cwd-relative` without running anything when an empty or relative entry comes
before or holds `zensu`: the banner runs at every fresh session start, and a repository could plant
a `zensu` in the working directory. The unit case `the PATH walk decides as the playwright-cli probe
walk does over the same fixtures` drives both modules' `findBinary` and their cwd-relative verdicts
over one set of layouts, on POSIX only, so a change to one walk that the other does not follow
turns it red. One shared walk module is the standing fix and is not implemented: it changes the
browser consent gate's version module, which belongs in that gate's own review. The probe runs
`zensu --version` once with `ZENSU_NO_UPDATE_CHECK=1`, because the CLI starts its update check
before every command and takes `/dev/null` for a terminal; stdin and stderr are ignored, stdout goes
to a private temporary file, and a 5 s timeout sends SIGKILL. Only the first line of at most 4 KiB
is read. A `.cmd` or `.bat` shim on win32 is never run. The line is
`zensu <version> (commit <sha>, built <time>)` (zensu-cli `internal/version`); a build without
ldflags reports `dev`.

**States:** `ok`, `old` (a prerelease of the floor included), `dev`, `unread`, `absent` and
`cwd-relative`. `ZDOC_ZENSU_VERSION` and `ZDOC_ZENSU_VERSION_STATE` are re-derived unless
`ZDOC_ZENSU` is injected, the third exception group of the wrapper's `:=` convention, so the suites
that inject `ZDOC_ZENSU` keep their rows. The report renders the version row only beside an
`authed` or `present` CLI row.

**The lookup runs before any `zensu` call, and its answer decides whether one runs.** The wrapper
asks the module first (`cliMain` with `--lookup`). On `cwd-relative` it runs neither
`zensu auth status` nor `zensu --version`, sets `ZDOC_ZENSU=unchecked`, and the report renders one
row that says neither the login nor the version was checked. Running `zensu auth status` through
the shell's `PATH` there would execute the very binary the lookup refused to run. `/zensu:setup`
follows the same rule: on `cwd-relative` it skips Phase 1 (`P9d`).

**Auth.** `zensu auth status` exits 0 and prints `Not logged in. Run \`zensu auth login\`.` when no
login is stored, so the doctor counts a status as authenticated only when it exits 0 and prints no
`Not logged in`; `/zensu:setup` Phase 1 and the `/zensu:pilot` ladder say the same. The doctor runs
it with `ZENSU_NO_UPDATE_CHECK=1` and stdin from `/dev/null`. With a stored token and no recorded
user, the command decodes the identity from the token and stores it in the CLI's `hosts.json`; that
is the one write the doctor's header names.

**The doctor rows are explained in `skills/doctor/references/zensu-cli.md`.** The doctor skill body
sits on the shrink-only allowlist of `tests/structure/test-skill-text-budget.sh` at its exact size,
so the skill carries only a pointer to the reference. `P8z15` holds every row phrase against the
report and the reference, and the pointer against the skill.

**ghost-scan is the exception among the seven skills.** Its body sits on the same allowlist at its
exact size, so its prerequisite line keeps the old line's length and names the floor and
`/zensu:doctor` instead of the commands. Moving detail from that body into `references/` is what
would make room for the full line.

**Coupled sites.** The module and its unit file; the lookup, the auth probe and the header of
`hooks/lib/zensu-doctor.sh`; `zensuCliVersionModule`, `zensuInstallClause`, `zensuVersionRow` and
the `unchecked` arm of `toolBlock` in `hooks/lib/zensu-doctor-report.js`; the lookup call,
`_zensu_cli_field` and the CLI lines of `hooks/session-start-banner.sh`; `skills/setup/SKILL.md`
Phase 0 and Phase 1; the degradation
ladder of `skills/pilot/SKILL.md`; `skills/doctor/SKILL.md` and its `references/zensu-cli.md`;
`probe()` in `hooks/lib/work-order-v1.js`; `findBinary` in `hooks/lib/playwright-cli-version-v1.js`,
through the drift case; `REQUIRED`, `check()` and `guidance` in `hooks/lib/ai-work-preflight-v1.js`,
through the fixture case; the free-text flag sites of the skills, through `FT8` and the scanner
`tests/structure/lib-skill-free-text.js`, whose command list the fixture recorder
`tests/structure/fixtures/record-zensu-cli-floor-help.js` reads; the capability probe of
`hooks/lib/context-auto-load-v1.js`, which no case holds;
the prose copies above. Tests: the unit file, driven by
`tests/structure/test-doctor.sh` (`P0zv`, `P0zw`); `P8z1`-`P8z15` there; `B16a`-`B16e` in
`tests/structure/test-session-start-banner.sh`; `P9a`-`P9d` and `P10a`-`P10f` in
`tests/structure/test-setup-skill.sh`; `FT8` in `tests/structure/test-skill-workflow-markers.sh`.

**Sites outside this repository.** Eight zensu-cli facts, the last one with the backend behaviour
behind it, are copied here and nothing checks them against their source:

- the `Not logged in` text of `zensu auth status`. This one fails open: if the CLI rewords it, a
  logged-out CLI reads as authenticated in the doctor, `/zensu:setup` and the `/zensu:pilot` ladder;
- the `ZENSU_NO_UPDATE_CHECK` name in the CLI's update check. If it is renamed, every doctor, banner
  and setup call starts the update check again, with its network call and its write of
  `version-check.json`;
- the version line format of `internal/version`. A change there reads as `unread`, which only warns;
- the help of zensu-cli 0.22.0 in the floor fixture: the `ai-work` help and the help of every
  command the skills send free text to. It proves that the floor release declares what
  `REQUIRED` and the skills use, not that a later release still declares every flag;
- the value-file rules of zensu-cli 0.22.0 (`internal/cmd/valuefile.go` at `d466f49`): a `-file`
  flag refuses a missing or unreadable path, a file that is not a regular file, more than 256 KiB
  of text or 4 MiB of JSON, invalid UTF-8, a NUL byte and an empty or whitespace-only value before
  any request, strips a UTF-8 byte-order mark and trims trailing CR and LF from text. The
  file-flag sites of the skills carry no shell content check because of it. The floor fixture
  records only the two size limits, so a later release that accepted a blank file would let a
  skill send an empty value while every check stays green;
- the knowledge help of zensu-cli 0.20.1 (`knowledge search --help`, `knowledge sources --help`),
  which states the server's behaviour: search indexes each product's features, visions, journeys,
  wiki pages, feature-doc titles and links (not the linked files), mocks and design assets, plus
  Zensu's built-in documentation; a source of type external is a registration nothing indexes; and
  ranking is full-text unless the server has an embedding model, then hybrid, falling back to
  full-text when the embedding endpoint fails. The search help puts the mocks right after "but not
  the linked files", which reads as if they were excluded; the sources help lists `mock` and
  `design` among the sources Zensu syncs, which settles that they are indexed. The Knowledge
  section of `agents/zensu-plm.md` repeats these facts and
  `tests/structure/test-knowledge-context.sh` pins that wording, so the suite stays green when the
  server changes: re-read both help texts when a connector, an artifact type or a ranking mode
  ships. The trust rule there, Important Rule 14, and its copy in
  `skills/implement/references/knowledge-context.md` are unconditional on purpose, because the
  server marks the text members and agents write `internal_verified`, so a rule that exempted that
  level would invite following it. Search results spell the field `trustLevel`; `knowledge get`
  items and context-pack nodes spell it `trust_level`. The `--query` placeholders differ on
  purpose: `knowledge search` matches whole words in its full-text default, so its hint in the plm
  prompt and in the truncated-pack advice of `hooks/lib/context-auto-load-v1.js` asks for a few
  terms the artifacts use, while `knowledge context-search` takes a task description by its own
  help, so the discovery advice keeps `<specific task question>`;
- the feature list the AI-work capture preflight searches. `zensu features list --product <id> --json`
  prints, by its 0.23.0 help, all pages as one envelope `{data, total, page, perPage}`; on
  2026-11-20 it returned 339 features of the bound product, each carrying `id`, `title`, `slug`,
  `status`, `tags`, `description`, `product_id`, `deprecated_at`, `replaced_by_feature_id` and
  `lifecycle`, the fields `hooks/lib/ai-work-feature-search-v1.js` reads. The search fails open
  on a rename: a renamed `deprecated_at`, `replaced_by_feature_id` or `lifecycle` lets deprecated,
  replaced or inactive features back into the candidates, and a renamed `title` empties the list.
  The unit cases in `tests/structure/ai-work-capture.test.js` build their own lists, so re-read a
  real list when a zensu-cli release changes `features list`;
- the Pulse contract of zensu-cli 0.22.0 (`internal/cmd/pulse.go`, `printJSON` in
  `internal/cmd/factory.go`) and of the Zensu backend at `7e5a52185`
  (`backend/internal/handlers/pulse.go`, `backend/internal/services/pulse.go`, migration `000173`).
  With `--minimal-json`, `pulse start` and `pulse end` print one JSON object indented by two
  spaces that holds an `id` or `"status": "tracking_disabled"`, and they report every request error
  as `Pulse request failed` and every malformed answer as `invalid Pulse response`; without the
  flag the detailed error comes through, and a successful end prints `Ended session <id>`.
  `--changed-file` repeats, and an end without any sends an empty list, which the backend
  accepts and maps no feature to. The end refuses more than 1000 paths before it reads the tracking
  setting, answers `tracking_disabled` when the user has no privacy row or tracking is off, and
  refuses the whole list for one path that is empty, longer than 500 bytes, absolute, holds a
  backslash or a control, format, line- or paragraph-separator character, or differs from its
  `path.Clean` form, as a trailing `/` does. New accounts start with tracking off, and older rows
  keep their setting. `skills/pulse/SKILL.md`, the Pulse lines of `agents/zensu-plm.md` and the
  `/zensu:pulse` row of the README's Data & privacy table repeat these facts, and
  `tests/structure/test-pulse-skill.sh` and `C5` of `tests/structure/test-zensu-plm-arg-guidance.sh`
  pin the wording, not the facts: re-read the sources when a zensu-cli release changes a `pulse`
  command and when the backend changes a Pulse limit or the privacy default.

**Version: `patch`.** Advisory banner text, doctor rows and skill text: no schema field, key set,
hook, matcher, config key or attestation moves.

**Known gaps:**

- The version is what the binary on `PATH` prints. A wrapper script is judged by its output, and a
  shell function or alias named `zensu` is found by the shell but not by the probe, which then
  answers `absent` beside an installed CLI row.
- Native Windows is unmeasured: the fake binaries of the unit file, the doctor and the banner checks
  are POSIX only, so only the unit cases that need no binary run there, and the drift case skips.
- The banner adds one `node` start and one `zensu --version` run to every fresh session start that
  shows the banner; the cost is unmeasured.
- `docs/superpowers/specs/2026-07-07-zensu-setup-skill-design.md` keeps the curl-only hint as a dated
  design record.
- No port (`zensu-codex`, `zensu-kiro`, `zensu-antigravity`) was changed.
