---
paths:
  - "plugins/session-hub/**"
  - "skills/session-trail/**"
  - ".claude-plugin/marketplace.json"
  - ".github/workflows/release-session-hub.yml"
  - ".github/scripts/session-hub-*.sh"
  - ".github/scripts/bump-marketplace-entry.js"
  - ".github/tools/**"
  - "LICENSE"
  - "cliff.toml"
  - "hooks/user-prompt-session-hub-takeover-notice.sh"
  - "hooks/lib/session-hub-takeover-notice-v1.js"
  - "hooks/user-prompt-session-hub-receipt.sh"
  - "hooks/lib/session-hub-receipt-v1.mjs"
  - "hooks/lib/claude-path-v1.js"
  - "hooks/lib/desktop-store-read-v1.js"
  - "hooks/lib/git-environment-v1.js"
  - "hooks/lib/worktree-keep-v1.js"
  - "hooks/usage-feed.ts"
  - "hooks/usage-feed-contract.json"
  - "tests/structure/test-session-hub-*.sh"
  - "tests/structure/test-session-trail-*.sh"
  - "tests/structure/session-hub-receipt-v1.test.js"
---

# Session Hub Companion (`plugins/session-hub/`)

**Two plugins, one repository.** `plugins/session-hub/` is `session-hub@zensu`, the plugin
the Zensu Session Hub needs: `/session-hub:session-trail`, one `UserPromptSubmit` entry that
runs `hooks/lib/session-hub-receipt-v1.mjs` in exec form, and the `hooks/usage-feed.ts`
module. Its marketplace entry is a `git-subdir` source (`url`, `path: plugins/session-hub`,
`ref: session-hub--v<version>`, no `sha`), so an install copies only that directory. It loads
nothing from PLM: `test-session-hub-plugin.sh` H5 fails on a `require`, `import` or `source`
that leaves the tree and on a `require`, `requireFromHere` or `import()` whose argument is not
a quoted literal, which the scan could not follow; H1 holds the tree to an allowlist, and H12
runs the receipt entry and `trail.mjs list --json` from a `cp -R` copy outside the repository.

**Byte-identical copies, not a build step.** Eight files are copies of PLM files, and H4 fails
on any byte that differs: the root `LICENSE`, `hooks/lib/claude-path-v1.js`,
`desktop-store-read-v1.js`, `git-environment-v1.js`, `worktree-keep-v1.js`,
`hooks/usage-feed.ts`, `hooks/usage-feed-contract.json` and
`skills/session-trail/scripts/session-lineage-v1.mjs`. The license is copied because an install
copies only the subdirectory. A change to one of those PLM files copies the file into the
companion in the same commit. `trail.mjs`, `linked-sessions-v1.mjs`, `SKILL.md`, the
references, `handover-contract.json` and the receipt module are the companion's own; H13 holds
`linked-sessions-v1.mjs` equal to PLM's once its command and plugin names are mapped back. The
copy dropped the write-anchor feature, the GATE probe and the Session Control core (H6),
computes the keep key itself with core's domain-separated hash (H7 compares it with
`sessionKey`), and names `/session-hub:session-trail` in every file it runs or loads (H6). Its
references name a PLM doc by its GitHub URL, because an installed companion carries no `docs/`
(B8 in `test-skill-text-budget.sh`).

**H16 holds the two `trail.mjs` copies together.** Every top-level function and constant both
copies define must be equal once full-line comments are removed and the command names are mapped
back, except the reviewed allowlist inside the check, each entry with its reason: the
write-anchor removal (`parseArgs`, `COMMAND_FLAGS`, `refuseForeignFlags`, `cmdShow`,
`cmdTakeover`, `cmdHandoff`), the GATE-probe removal (`canonicalPair`, `whereAdviceLines`), the
core removal (`worktreeKeepModules`, `cmdRelease`), `hostPath`, which throws so an importer can
catch a missing `claude-path-v1.js`, and `main`, which resolves the roots inside its dispatch
guard so that throw is reported like a handler's. An allowlisted name both copies hold equal
fails as stale, and a planted one-character drift fails. Imports, the claude-path loader, the
`export` statements and the entry line are not compared. A change to a shared function lands in
both copies, or its entry joins the allowlist with the reason.

**PLM's copy is frozen, and the maintained copy is the companion's.** PLM keeps
`skills/session-trail/`, `hooks/user-prompt-session-hub-receipt.sh`,
`hooks/lib/session-hub-receipt-v1.mjs` and `hooks/usage-feed.ts` until the release that
removes them. They take fixes only, and a fix lands in both copies. That removal is P4 of the
cross-repository plan, and decision D11 sets its earliest date: four weeks after the Session Hub
release of phase P2, the one that reads handover contract 2. PLM's `handover-contract.json` stays contract 1 byte for
byte; the companion's is contract 2 with the prefix `/session-hub:session-trail takeover ` (R12
in `test-session-hub-receipt.sh`). PLM's receipt module runs behind a shell hook that exits 0 on
every path; the companion's exec-form entry is total on its own: a lineage module that fails to
load, a throwing home lookup or clock and any other throw end with exit 0, no output and no
receipt, which three child-process cases in `session-hub-receipt-v1.test.js` prove. The suites
grade the companion: `test-session-trail-{skill,lineage,verdict}.sh`, the unit files they drive
and `test-session-hub-{plugin,receipt,usage-feed}.sh`. PLM's copy is graded for what the
companion removed: the write-anchor checks (`W*`, `WC*`), the PLM census in
`worktree-advice-v1.test.js` and the rows that rebind `TRAIL_MJS="$PLM_TRAIL_MJS"`. Every label
of `test-session-trail-verdict.sh` names the copy it graded, `[hub]` or `[plm]` from the
`TRAIL_MJS` it ran under and `[both]` for `PL1`, and `PL-copy` fails a label that ran under
neither. `PL1` runs both copies on the LS family's fixture and requires the same
`show --all --json` and `takeover --all --no-record --json`, apart from the command name and
PLM's `writes` and `continuation` keys. A shared behavior that regresses in PLM's copy alone on
another path is still not caught. The skill's description budget and argument placeholders are
graded by `test-skill-text-budget.sh` and `AP1`, which scan each `plugins/*/` root. The rules for
the skill (`session-trail-*`, `takeover-destination`, `session-lineage-ledger`) name
`skills/session-trail/…`; read each as naming both copies, except the write-anchor material
(`writeAnchor`, `continuationPlan`, `--anchor`, the `WRITES` and `CONTINUE` lines), which PLM's
copy alone carries.

**The takeover notice is PLM's.** The companion has no write gate.
`hooks/user-prompt-session-hub-takeover-notice.sh` answers the companion's raw or command-tag
takeover prompt with one `additionalContext` notice: on the main thread only, only while
`hooks.bashWriteGate` is on and neither `ZENSU_BASH_WRITE_GATE=off` nor `ZENSU_MCP_GATE=off`
is set, naming the bound Session Control root in double quotes when the bind succeeds and
stating that rule (A) still refuses a raw Bash overwrite of a git-tracked source file inside it.
When the bind fails it sends the unbound variant instead, which names no reanchor, because
`--reanchor` needs a usable record, and points at `/zensu:doctor`.
`test-session-hub-takeover-notice.sh` and its row in `test-user-prompt-budget.sh`, zero
characters on every other prompt, pin it; N13 holds its command name, the hook's prefilter and
the receipt entry's to the companion contract's `takeover.prefix`. The notice reaches only a
prompt that carries the command: a linked session started from a brief, a takeover started
through the Skill tool and a PLM older than this change get none. So the companion's briefs carry
the rule themselves (`plmGateCaution` in `trail.mjs`, the `Commits, when Zensu PLM is installed`
line), `show` prints it as its `COMMITS` lines (`PLM_GATE_SHOW_LINES`), and
`references/takeover.md` step 3 tells the model to read `hooks.bashWriteGate` rather than the
absence of a notice. T40 in `test-session-trail-skill.sh` pins one definition of each and the
three call sites, and PG1 to PG3 in `test-session-trail-verdict.sh` render the takeover brief,
the handoff brief and `show`, each against a planted copy without the lines. The third route of
`docs/gates.md`, the `CONTINUE` block, is PLM's alone.

**Changelogs and tags split by path.** Root `cliff.toml` keeps its `vX.Y.Z` `tag_pattern` and
adds `exclude_paths = ["plugins/session-hub/**"]`. `plugins/session-hub/cliff.toml` uses
`session-hub--vX.Y.Z` tags and `include_paths = ["plugins/session-hub/**"]` with the same body
and parsers (H9), its version header included: only the tag prefix that header trims may
differ. A commit that touches both trees lands in both changelogs. Measured with
git-cliff 2.13.1 on a scratch history in both directions. Both release workflows pin that version
in their git-cliff step (`version: v2.13.1`, the default of the pinned action as well), and H8
holds the pin.

**Release path: `.github/workflows/release-session-hub.yml`, four jobs split at the
credential.** A job that runs Claude Code, npm or git-cliff has `contents: read` and passes no
token to any step, so its actions see at most that job's read-only token; a job that pushes or
publishes has `contents: write`, installs and runs none of them, uses only `actions/checkout`
and `actions/download-artifact`, and checks what it receives against the commit it names.
Every checkout sets `persist-credentials: false`, and both pushes run with
`-c core.hooksPath=/dev/null`.

- `prepare-commit`, dispatched on `main`, computes the next version with
  `.github/scripts/session-hub-release-version.sh`, which refuses unless the current companion
  version is tagged or `supersede` is set, and refuses unless the release order below holds. It
  bumps `plugins/session-hub/.claude-plugin/plugin.json` with `sed` and the `session-hub` entry
  with `bump-marketplace-entry.js`, prepends the git-cliff section under `## [Unreleased]` of
  `plugins/session-hub/CHANGELOG.md`, commits `chore(release): bump session-hub to X.Y.Z` on
  `release/session-hub-vX.Y.Z` on top of the dispatched SHA, runs
  `.github/scripts/session-hub-release-gate.sh` against that commit and uploads it as a git
  bundle of the branch over its parent. A `dry_run` stops before the commit. `supersede: true` is
  the way out of a version that can never be published at the commit that introduced it, for
  example after a Zensu release changed the usage feed: the version script accepts it only while
  the current version has no tag and every companion tag is older,
  `.github/scripts/session-hub-release-supersede.sh` marks that version's
  `## [X.Y.Z] - YYYY-MM-DD` heading `(superseded by <next>, never published)`, so the notes
  script refuses that version from then on, and the release commit carries a `Supersedes:` line.
- `prepare-push` checks the bundle, the commit id, its parent against the dispatched SHA, the
  subject, the three changed files and the version, refuses a release branch that already
  exists on `origin`, and pushes it. It never force-pushes.
- `publish-gate` runs on a push to `main` whose head commit starts with that subject, or on a
  `publish` dispatch, which refuses `dry_run` and `supersede` and is how the first release,
  1.0.0, ships. `.github/scripts/session-hub-release-target.sh` resolves its target: the oldest
  commit of the newest run on `main`'s first-parent line whose `plugin.json` carries the
  version, so a dispatch and the push of the release commit name the same commit, and later
  companion commits are not part of the release; a push run must be that commit. The script
  checks the entry at the target field by field, writes the notes through
  `.github/scripts/session-hub-release-notes.sh`, which requires a non-empty
  `## [X.Y.Z] - YYYY-MM-DD` section, and refuses an existing tag that names another commit with
  an error that leaves it to a maintainer. The job then checks out the target, runs the release
  order and the gate there, and creates the tag through `claude plugin tag plugins/session-hub`,
  which refuses unless `plugin.json` and the entry agree. It checks that the tag is annotated
  and names the target and uploads the notes and a bundle of the tag object over the target.
- `publish` checks that the target is an ancestor of the run's SHA, rebuilds the notes from
  `git show <target>:plugins/session-hub/CHANGELOG.md` with the same notes script and refuses
  handed-on notes that differ, and checks the bundled tag's object id, type, name, message
  (`session-hub X.Y.Z`, the message `claude plugin tag` writes) and target, or for a tag that
  existed already its target. It then requires Immutable Releases through
  `.github/scripts/session-hub-require-immutable-releases.sh` with
  `IMMUTABLE_RELEASES_ADMIN_TOKEN`, pushes `refs/tags/session-hub--vX.Y.Z`, publishes the release
  with the rebuilt notes and `--verify-tag --latest=false`, so PLM's release stays the
  repository's latest, and
  once the release is immutable resolves the tag again and fails if it no longer names the
  target. Between the push and the lock the tag is mutable; that window is the price of tagging
  through `claude plugin tag`, and the last check names a tag moved inside it. PLM's
  `release.yml` keeps its own inline Immutable Releases check.

H10 pins that split: no token spelling (`GH_TOKEN`, `GITHUB_TOKEN`, `github.token`, `secrets.`)
in the workflow env or a read job, no npm, npx, `claude`, git-cliff, Node setup, install, gate or
probe script and no other action in a write job, the four checkouts without credentials, the two
allowed pushes and the job each lives in, the one tag command without `--push`, the step order of
both publishing jobs, the call of the release-target script, the `dry_run` and `supersede`
refusals and the supersede wiring, the notes rebuild and comparison, the tag-message check,
`--latest=false`, the push trigger and the prepare subject. Its mutants plant a hand-pushed tag,
a force-pushed branch, the two pushes swapped between their jobs, each token spelling in the tag
job, a token in the commit job and in the workflow env, a writable tag job, `--push`, npm,
`claude`, git-cliff and a Node setup in `publish` and the gate in `prepare-push`, another action
in `publish`, a checkout that keeps its credentials, a release marked latest, the `dry_run` and
`supersede` refusals and the supersede marking removed, the tag created before the gate, the tag
pushed before the Immutable Releases check or without it, the notes comparison removed, the notes
taken from the artifact, the tag message unread, a shorter trigger prefix and one commit with
another subject. `npx` and the install and probe scripts in a write job reach the same
`<job>-runs-tooling` check as those mutants without one of their own, and `prefix-overlap`
compares two constants with PLM's `release.yml` and has no mutant. H8 holds both order-script
runs and the git-cliff pins.

**The release scripts run on scratch histories.** H17 runs `session-hub-release-target.sh`: the
target past a later touch, after a revert and re-bump and at a merge, a pushed head that did not
introduce the version, a missing and an empty changelog section and a tag at another commit
refused, a tag at the target accepted, with mutants that skip a commit of another version and
leave the first-parent line. H18 runs `session-hub-release-version.sh` and
`session-hub-release-supersede.sh`: the bumps, the refusals of an untagged version without
`supersede`, of `supersede` for a tagged version and below a newer tag, numeric version order,
and the marking, which the notes script then refuses, with a mutant for each `supersede`
refusal. H19 runs `session-hub-require-immutable-releases.sh` against a stub `gh`: only a
setting that reads `true` passes, a disabled or unreadable setting fails with the caller's
message, and a copy without the read-failure branch loses that message.

**Claude Code installs come from lockfiles.** `.github/scripts/session-hub-install-claude-code.sh`
installs `.github/tools/claude-code` (2.1.317) or `.github/tools/claude-code-floor` (2.1.296):
each a committed manifest with one exact pin and an npm lockfile with sha512 integrity.
`.github/scripts/session-hub-claude-code-pin.sh` alone holds the list of tool directories and
reads the pin, for the installer and the probe alike. The installer runs
`npm ci --ignore-scripts` in a fresh `mktemp -d` directory, requires that the lockfile gives an
install script to `@anthropic-ai/claude-code` alone, runs that package's own `install.cjs`, and
checks `claude --version`. Measured: without that script the installed CLI reports its native
binary missing. Read in the 2.1.317 package: its `install.cjs` makes no network call and copies
the native binary from the platform package the lockfile pins. H11 pins the manifests, the lockfiles, that no file
under `.github/workflows/` or `.github/scripts/` installs a versioned Claude Code another way,
both CI callers and both release callers, the gate's `CLAUDE_CODE_TOOL`, the one pin owner and
that neither the installer nor the probe holds a list or reader of its own, the floor below the
pin and the README lines naming both, with a mutant each for an unlocked install, a second
install script, a version range and a probe that reads the pin itself.

**The gate and its probe.** The gate runs `.github/scripts/session-hub-install-probe.sh` with
`.github/tools/claude-code`, then the companion suites with `CLAUDE_CONFIG_DIR` unset. The probe
validates `.` and `plugins/session-hub`, adds the unfiltered catalog as a local marketplace and
fails when that is refused, clones the repository with `--no-local --no-tags`, runs
`claude plugin tag plugins/session-hub` in that clone and requires an annotated
`session-hub--v<version>` tag at the probed commit with the message `session-hub <version>`, the
message `publish` checks, so a pinned Claude Code that writes another message fails before a
release PR merges, installs the companion from a bare clone of it
through a local `git-subdir` marketplace into an isolated config, requires every installed file
to equal `git ls-tree` of `plugins/session-hub` at that commit by object id, and lands a 0600
receipt and runs `list --json` from the installed copy. It never tags the repository itself, so
`claude plugin tag` in the release still finds no local tag. Measured with 2.1.317:
`claude plugin tag` writes the message `session-hub X.Y.Z` and creates the local tag even when
`origin` already carries it, so the probe still tags its clone on a publish retry. H15 drives
the probe against a stub `claude` in a scratch repository: it passes a faithful install and
leaves no tag there, and refuses a dropped file, a one-byte change, another Claude Code version,
a lightweight tag, an annotated tag on another commit, an annotated tag with another message, a
refused unfiltered catalog, an entry
whose ref names another tag, an install that lands nothing, and an installed entry that lands no
receipt, prints output, leaves its receipt readable by others or names another plugin version,
each with its own error. The last three go through a `node` wrapper on the stub's `PATH`,
because the installed files must equal the committed tree. `ci.yml` runs the whole gate in `plugin-validate` on every pull request,
`release/` heads included, under Node 22, and the probe alone in `plugin-floor` with 2.1.296, the
oldest version the README names. Measured on macOS: the probe passed with 2.1.296 and 2.1.317.
Measured on 2026-11-11: Claude Code 2.1.221 and 2.1.288 validate and add the two-entry catalog,
2.1.288 installs `zensu` 0.37.0 from it, and on 2.1.296 `claude plugin tag plugins/session-hub`
in a clone creates the annotated tag `session-hub--v1.0.0` at `HEAD` and pushes nothing. Measured
earlier in a `node:22-bookworm` container with no credentials and no `~/.claude`: both
validations and `claude plugin tag --dry-run` ran without a login. That package requires Node 22,
which is why these jobs set it up while the suites elsewhere run on Node 20.

**Go-live order.** The `session-hub` entry ships in the catalog with this change (AC-001,
AC-007, D2), so from the Zensu release that ships it until `session-hub--v1.0.0` is published,
`claude plugin install session-hub@zensu` fails on a tag that does not exist. The order is:
merge, release Zensu, then dispatch `Release Session Hub` with `mode: publish` right after.
Open owner actions: that dispatch, and a tag ruleset for `refs/tags/session-hub--v*` and
`refs/tags/v*` that admits only the release workflows.

**Order of releases.** While both plugins ship the usage feed, both copies write
`<session id>.json` under one rule, so PLM releases no later than the companion: an installed
PLM older than the companion writes by the older rule. `.github/scripts/session-hub-release-order.sh`
enforces it in both `prepare-commit` and `publish-gate`: it takes the newest `vX.Y.Z` tag by
version, ignoring pre-release tags, and refuses unless that tag carries `hooks/usage-feed.ts` and
`hooks/usage-feed-contract.json` byte for byte as the companion's working tree and ships
`hooks/user-prompt-session-hub-takeover-notice.sh`. H14 drives it on a scratch history. So the
first companion release waits for the PLM release that ships this change. The order bounds
releases, not installs: a user who updates the companion and keeps an older PLM runs two writers
by different rules until PLM is updated, and the last write wins. Both writers stay, because
AC-006 keeps the schema and PLM's copy is frozen. The release that removes PLM's feed (P4) must
change the byte comparison in that script, which then finds no `hooks/usage-feed.ts` in the
newest PLM tag and refuses every companion release.

**Known gaps.** Moving a session through the companion needs a Session Hub release that reads
handover contract 2; until it exists, the Hub moves sessions through PLM's contract-1 copy. The
companion README and its 1.0.0 changelog entry say so.

**Version: `patch` for PLM.** An added advisory hook, an added catalog entry, CI and docs: no
schema, strict key set, matcher, config key or attestation moves.
