# Zensu Session Hub companion plugin

`session-hub@zensu` is the Claude Code plugin the Zensu Session Hub needs. The
Session Hub is a macOS app that shows the five-hour and weekly limits of several
Claude accounts and moves a Claude Code session from one account or window to
another. To move a session it types a takeover command into a new session, waits
for this plugin's receipt, and it reads the limits this plugin's usage feed
writes.

The plugin holds three things and nothing else:

- `/session-hub:session-trail`, which lists the Claude Code sessions on this
  machine, shows what one is doing, takes one over, releases the old one so it
  can be archived, and traces where a session was continued across windows and
  accounts. It is the session-trail skill of the Zensu plugin without the parts
  that need Zensu.
- One `UserPromptSubmit` hook that lands a receipt when the Session Hub's
  takeover command reaches a session.
- The hooks module `hooks/usage-feed.ts`, which writes the rate-limit readings
  the Session Hub shows.

It needs no Zensu account, no `zensu` CLI and not the Zensu plugin.

## Install

The plugin needs Claude Code 2.1.296 or newer and `node` on the `PATH`. The
receipt hook runs as `node …` and `/session-hub:session-trail` runs its script
with `node`, so without it no receipt lands and the skill cannot run; Claude
Code's native installer does not put `node` there. Installing this plugin from
the marketplace was tested with Claude Code 2.1.296 and 2.1.317, and CI repeats
that install with both versions on every pull request.

```bash
claude plugin marketplace add MKITConsulting/zensu-claude-code
claude plugin install session-hub@zensu
```

Skip the first line when the `zensu` marketplace is already added.
`claude plugin install` installs for your user by default, so the plugin is
there in every project the Session Hub moves a session into.

The install works once the plugin's first release, `session-hub--v1.0.0`, is
published, which follows the Zensu release that ships this plugin's marketplace
entry. Until then the catalog names a tag that does not exist yet, and
`claude plugin install session-hub@zensu` fails.

Moving a session through this plugin also needs a Session Hub release that reads
handover contract 2, the contract this plugin declares. Until that release, the
Session Hub moves sessions through the Zensu plugin's own `/zensu:session-trail`,
as before.

Update later with:

```bash
claude plugin marketplace update zensu
claude plugin update session-hub@zensu
```

## What it writes

Every file lives on your machine under `<config root>/zensu/`, where the config
root is `~/.claude`, or `CLAUDE_CONFIG_DIR` when that is set. The plugin sends
nothing anywhere.

| Path under `<config root>/zensu/` | Written by | Content |
|---|---|---|
| `session-hub/v1/receipts/<token>.json` | The receipt hook | One receipt per takeover command: the schema version, the kind, the 32-character token from the command, the hook event, the plugin version and the time. Only your user can read it. Receipts older than seven days are removed when the next one lands |
| `session-lineage/v1/edges/*.json` | `takeover`, `adopt` and `lineage --backfill --apply` of `/session-hub:session-trail` | The lineage ledger: one record per recorded handover. It is shared by every window on the machine and append-only; `lineage --forget <session>` is the only way a record leaves |
| `session-hub/v1/usage/<session id>.json` | The usage feed | The rate-limit readings of one session, described below |

### The receipt

The hook writes a receipt only for the exact command the Session Hub types,
`/session-hub:session-trail takeover <session id> --all --receipt <token>`,
where the token is 32 hexadecimal characters. It writes nothing for any other
prompt, for a prompt a subagent sends, and when it runs from a plugin root other
than its own. It prints nothing and never blocks a prompt.

To switch the receipt off, set `hooks.sessionHubReceipt` to `false` in
`~/.zensu/config.json`:

```json
{ "hooks": { "sessionHubReceipt": false } }
```

The plugin reads only that file, never a project file or `ZENSU_CONFIG`, and
every other value or a missing file leaves the receipt on. The Zensu plugin
reads the same key for its own receipt hook.

### Usage feed

The module writes only while the directory
`<config root>/zensu/session-hub/v1/usage/` already exists as a directory and
not as a link. The config root is `CLAUDE_CONFIG_DIR`, trimmed, when it names an
absolute path, and `$HOME/.claude` when `CLAUDE_CONFIG_DIR` is unset or empty; a
relative `CLAUDE_CONFIG_DIR` writes nothing and never falls back to `$HOME`. The
Session Hub creates that directory; the module never creates it, so on a machine
without the Session Hub nothing is written.

While the directory exists, the module writes one file per Claude Code session,
`<session id>.json`, when Claude Code measures the session and the reading is
new: Claude has just answered a turn of the session, or a rate-limit window has
just moved. The time in the file is that moment, so a reading the session took
earlier never comes back under a newer time. It writes nothing when a session
starts and nothing while a session is idle, so a file keeps the time of its last
reading. The file holds the record's schema version, the session id, the time of
the reading, and for each window its name (`five_hour`, `seven_day`), the
percentage used and the reset time. It holds nothing else: no prompt, response,
title, path, project or account data. To tell an answered turn, the module reads
only how the turn ended, not its text. Each write replaces the whole file, the
file stays on your machine, and the module sends nothing anywhere. Deleting the
directory stops the feed; only a write already under way at that moment can
create it once more.

The module needs Claude Code 2.1.296 or newer and uses its early-access hooks
module API, which can change between releases. Anthropic can also switch modules
of installed plugins off at any time. The feed then writes nothing, the receipt
hook keeps running, and the Session Hub reads the limits from Claude's usage
popover as it does without the plugin.

## Next to the Zensu plugin

Both plugins can be enabled at once. The Zensu plugin still carries its own
copy of `/zensu:session-trail`, a receipt hook for `/zensu:session-trail
takeover …` and the same usage-feed module, frozen until a later Zensu release
removes them. Each receipt hook answers only its own command. Both usage-feed
copies write the same file, `<session id>.json`, and the last write wins. They
follow the same rule once the installed Zensu plugin is the release that ships
this plugin's entry or a newer one; an older installed Zensu plugin writes the
file by its older rule until you update it.

This plugin has no write gate. While the Zensu plugin's opt-in source-write
gate is on (`hooks.bashWriteGate: true`), the gate refuses a Bash write to a
source file and every working-tree git command whose target lies outside the
session's Session Control root; inside that root it still refuses a raw Bash
overwrite of a git-tracked source file. `/zensu:adopt-session --reanchor`, run from
inside the worktree the takeover works in, moves that root there; it accepts
only a registered worktree of the same repository, reports first and moves only
on `--confirm`. The takeover briefs and `show` state that rule themselves.

A Zensu release that ships it adds one notice to a takeover command typed as
`/session-hub:session-trail takeover …`, in its raw or command-tag form, while
that gate is on. In a session without a usable Session Control record the notice
says so and points at `/zensu:doctor` instead of the reanchor. A linked session
started from a takeover brief, a takeover the model starts through the Skill
tool and an older Zensu release get no notice, so a missing notice is no
evidence that the gate is off: read `hooks.bashWriteGate` in
`~/.zensu/config.json` and in the project's `.zensu/config.json`, whose value
wins.

## Remove it

```bash
claude plugin uninstall session-hub@zensu
```

The receipts, the usage files and the lineage ledger stay under
`<config root>/zensu/`. Delete `<config root>/zensu/session-hub/` to remove the
receipts and the usage files. The lineage ledger under
`<config root>/zensu/session-lineage/` is shared with the Zensu plugin's
`/zensu:session-trail`; delete it only when neither plugin needs the history.

## Release path

The companion is versioned and released on its own, with tags
`session-hub--vX.Y.Z`. The Zensu plugin keeps its `vX.Y.Z` tags. Its changelog
leaves out a commit that touches only `plugins/session-hub/`, and this
changelog lists only commits that touch it, so a commit that touches both
appears in both.

Every job that runs Claude Code, npm or git-cliff has read-only repository
permissions and passes no token to any step, so the actions in it see at most
that job's read-only token; the jobs that push a branch or a tag, or publish a
release, run none of them and check what the job before them handed on.

1. Actions → **Release Session Hub** → run with `mode: prepare` and a
   `version_type`. The `prepare-commit` job computes the next version with
   `.github/scripts/session-hub-release-version.sh`, which requires the current
   version to be tagged already unless `supersede` is set (see below), and it
   refuses unless the newest Zensu release `vX.Y.Z`
   ships this plugin's usage feed and its contract byte for byte and the
   takeover notice (`.github/scripts/session-hub-release-order.sh`). It bumps
   `plugins/session-hub/.claude-plugin/plugin.json` and the `session-hub`
   marketplace entry, its `version` and its `ref`, through
   `.github/scripts/bump-marketplace-entry.js`, and writes the new section of
   this changelog with git-cliff 2.13.1 from the commits that touched
   `plugins/session-hub/` since the last companion tag. It runs the release
   gate, `.github/scripts/session-hub-release-gate.sh`, against the release
   commit and hands that commit on as a git bundle. The `prepare-push` job
   checks the bundled commit, its parent, its subject, its three changed files
   and its version, refuses a release branch that already exists, pushes
   `release/session-hub-vX.Y.Z` and prints a link to open the pull request.
2. Review and squash-merge that pull request.
3. The merged commit starts the `publish-gate` job. Its release target, which
   `.github/scripts/session-hub-release-target.sh` resolves, is the commit on
   `main`'s first-parent line that introduced the version, so a dispatch and
   the push of the release commit release the same commit. It checks the
   marketplace entry field by field, the changelog section and the release
   order at that commit, runs the gate there and creates the tag with
   `claude plugin tag plugins/session-hub`, which refuses unless `plugin.json`
   and the marketplace entry agree. The `publish` job rebuilds the notes from
   the changelog at the target with `.github/scripts/session-hub-release-notes.sh`
   and refuses notes from `publish-gate` that differ. It checks the bundled tag
   object, its name, its type, its message and its target, requires Immutable
   Releases, pushes the tag and publishes an immutable GitHub Release whose
   notes are that rebuilt section. It checks that the locked tag still names
   the target, and it does not mark the release as the repository's latest,
   which stays the Zensu plugin's.

The gate runs `.github/scripts/session-hub-install-probe.sh` with the pinned
Claude Code: it validates the marketplace and this plugin, adds the whole
catalog as a local marketplace, tags a scratch clone with
`claude plugin tag plugins/session-hub` and requires an annotated tag at the
probed commit with the message `session-hub X.Y.Z` that the publish job checks,
installs this plugin through its `git-subdir` entry into an
isolated config, checks that every installed file equals the committed tree by
content, lands a receipt from it and runs `/session-hub:session-trail list`.
Then it runs the companion's suites. CI runs the same gate on every pull
request, and the probe alone with Claude Code 2.1.296. Each Claude Code these
jobs run is installed from a committed manifest and lockfile under
`.github/tools/`, whose exact pin `.github/scripts/session-hub-claude-code-pin.sh`
reads, with `npm ci --ignore-scripts`, followed by the package's own install
script, the only one the lockfile admits.

Zensu releases first: while both plugins ship the usage feed, an installed Zensu
older than this plugin would write it by an older rule. So the order is: merge
the change, release Zensu, then run this workflow with `mode: publish` right
after, because until `session-hub--v1.0.0` exists the catalog lists this plugin
at a tag that does not exist. The first release, 1.0.0, needs no bump. A
publish dispatch refuses `dry_run` and `supersede`, a tag that already exists
at another commit is refused, and a publication that failed is retried the same
way. When the current version can never be published at the commit that
introduced it, for example because a later Zensu release changed the usage
feed, dispatch `mode: prepare` with `supersede: true`. It is accepted only while
that version has no tag and every companion tag is older; it marks the
version's changelog section as superseded and never published, and cuts the
next version, whose section lists every companion commit since the last tag.
Tags are
created only by this workflow; a tag ruleset that admits only the release
workflows to `refs/tags/session-hub--v*` and `refs/tags/v*` is a maintainer
setting of the repository.

## License

[FSL-1.1-Apache-2.0](LICENSE), as the rest of this repository.
