---
paths:
  - "hooks/lib/zensu-cli-version-v1.js"
  - "tests/structure/zensu-cli-version-v1.test.js"
  - "tests/structure/fixtures/zensu-cli-0.18.0-ai-work-help.json"
  - "hooks/lib/ai-work-preflight-v1.js"
  - "hooks/lib/ai-work-capture-v1.js"
  - "hooks/lib/context-auto-load-v1.js"
  - "hooks/lib/zensu-doctor.sh"
  - "hooks/lib/zensu-doctor-report.js"
  - "hooks/session-start-banner.sh"
  - "hooks/lib/work-order-v1.js"
  - "skills/setup/SKILL.md"
  - "skills/doctor/SKILL.md"
  - "skills/doctor/references/zensu-cli.md"
  - "skills/pilot/SKILL.md"
  - "docs/work-order-mode.md"
  - "docs/operations.md"
  - "docs/cli-install-update.md"
  - "tests/structure/test-setup-skill.sh"
---

# zensu-cli Version Floor (`hooks/lib/zensu-cli-version-v1.js`)

**One module owns the floor and the install commands.** `MIN_VERSION` is the oldest zensu-cli
release the plugin supports: 0.18.0, because `REQUIRED` in `hooks/lib/ai-work-preflight-v1.js`
asks for `ai-work context --feature`, `ai-work start --feature` and `--maintenance-reason`, which
0.18.0 is the first release to declare, and `hooks/lib/ai-work-capture-v1.js` runs that check
before every `begin`, so an older CLI answers `cli_incompatible` for every goal. The earlier floor,
0.10.0, came from ghost-scan pagination (zensu-monorepo#954) and wiki list pages; 0.18.0 covers
both. `REQUIRED` is the floor's lower bound, and the unit case `the floor release declares every
flag the AI-work capture preflight requires` holds it: it replays the floor release's `ai-work`
help, recorded from the release archive in
`tests/structure/fixtures/zensu-cli-0.18.0-ai-work-help.json`, through `check()` and requires
`compatible`, so a flag `REQUIRED` adds that the floor release lacks fails it, and it requires the
fixture's version line to equal `MIN_VERSION`, so raising the floor re-records the fixture from the
new floor release's binary. A second lower bound has no case: the capability probe of
`hooks/lib/context-auto-load-v1.js` needs `knowledge context-pack --agent`,
`knowledge get --context-load` and `knowledge context-search --query`, which the 0.18.0 archive
declares. `FLOOR_REASON` says that in one sentence, and the doctor's old row renders it. `INSTALL`
holds the Homebrew install and upgrade commands, `install.sh` and `install.ps1`. The doctor, the
session banner, `/zensu:setup` and the work-order refusal in `probe()` of
`hooks/lib/work-order-v1.js` read the module, and so does the AI-work capture preflight, whose
`cli_unavailable` and `cli_incompatible` guidance takes the install commands and
`INSTALL.homebrewUpgrade` from it and names the plugin's install guide by absolute path. Every prose copy
— README Install and Requirements, the `docs/operations.md` troubleshooting row, the §Update block
of `docs/cli-install-update.md`, the six skill prerequisites, `/zensu:setup`, the banner's literals
and `docs/work-order-mode.md` — is pinned to it by `P10a`-`P10e` in
`tests/structure/test-setup-skill.sh`. **Raising the floor is three edits, not one:** the constant,
a new `FLOOR_REASON` that names what the releases below the new floor get wrong, and the prose
those checks name. `P10e` then requires the new reason, word for word, in the banner, in the
README Requirements and in `/zensu:setup` Phase 0; a floor raised without a new reason keeps
telling users the previous floor's reason.

**One Homebrew upgrade spelling.** `INSTALL.homebrewUpgrade` is
`brew update && brew upgrade --cask mkitconsulting/tap/zensu`, one command that every surface
copies verbatim. `brew upgrade` runs `brew update` only once `HOMEBREW_AUTO_UPDATE_SECS` has passed
(brew(1)), so on its own it can miss a release the tap published since, and the tap-qualified name
is the one `INSTALL.homebrew` installs. The unit file pins the value, and its floor-release case
requires the preflight's refusal guidance to name it and the install guide's absolute path, and the
guidance for an absent CLI to name the three install commands.

**Warn, never block.** No gate compares the version with the floor. An older CLI still runs, but
AI-work capture refuses to begin with it: `check()` in `hooks/lib/ai-work-preflight-v1.js` reads
the CLI's `ai-work` help for the flags `REQUIRED` names and answers `cli_incompatible`, a
capability probe rather than a version check. The doctor row and the banner say what an older
release gets wrong.

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

**ghost-scan is the exception among the six skills.** Its body sits on the same allowlist at its
exact size, so its prerequisite line keeps the old line's length and names the floor and
`/zensu:doctor` instead of the commands. Moving detail from that body into `references/` is what
would make room for the full line.

**Coupled sites.** The module and its unit file; the lookup, the auth probe and the header of
`hooks/lib/zensu-doctor.sh`; `zensuCliVersionModule`, `zensuInstallClause`, `zensuVersionRow` and
the `unchecked` arm of `toolBlock` in `hooks/lib/zensu-doctor-report.js`; the CLI lines of
`hooks/session-start-banner.sh`; `skills/setup/SKILL.md` Phase 0 and Phase 1; the degradation
ladder of `skills/pilot/SKILL.md`; `skills/doctor/SKILL.md` and its `references/zensu-cli.md`;
`probe()` in `hooks/lib/work-order-v1.js`; `findBinary` in `hooks/lib/playwright-cli-version-v1.js`,
through the drift case; `REQUIRED`, `check()` and `guidance` in `hooks/lib/ai-work-preflight-v1.js`,
through the fixture case; the capability probe of `hooks/lib/context-auto-load-v1.js`, which no case holds;
the prose copies above. Tests: the unit file, driven by
`tests/structure/test-doctor.sh` (`P0zv`, `P0zw`); `P8z1`-`P8z15` there; `B16a`-`B16e` in
`tests/structure/test-session-start-banner.sh`; `P9a`-`P9d` and `P10a`-`P10e` in
`tests/structure/test-setup-skill.sh`.

**Sites outside this repository.** Four zensu-cli facts are copied here and nothing checks them
against the CLI:

- the `Not logged in` text of `zensu auth status`. This one fails open: if the CLI rewords it, a
  logged-out CLI reads as authenticated in the doctor, `/zensu:setup` and the `/zensu:pilot` ladder;
- the `ZENSU_NO_UPDATE_CHECK` name in the CLI's update check. If it is renamed, every doctor, banner
  and setup call starts the update check again, with its network call and its write of
  `version-check.json`;
- the version line format of `internal/version`. A change there reads as `unread`, which only warns;
- the `ai-work` help of zensu-cli 0.18.0 in the fixture. It proves that the floor release satisfies
  `REQUIRED`, not that a later release still declares every flag.

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
