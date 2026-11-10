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

The usage feed needs Claude Code 2.1.296 or newer. Installing this plugin from
the marketplace was tested with Claude Code 2.1.317.

```bash
claude plugin marketplace add MKITConsulting/zensu-claude-code
claude plugin install session-hub@zensu
```

Skip the first line when the `zensu` marketplace is already added.
`claude plugin install` installs for your user by default, so the plugin is
there in every project the Session Hub moves a session into.

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
`<config root>/zensu/session-hub/v1/usage/` already exists, where the config
root is `CLAUDE_CONFIG_DIR` when that names an absolute path and `~/.claude`
otherwise. The Session Hub creates that directory; the module never creates it,
so on a machine without the Session Hub nothing is written.

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
removes them. Each receipt hook answers only its own command, and both
usage-feed copies write the same file under the same rule.

This plugin has no write gate. While the Zensu plugin's opt-in source-write
gate is on (`hooks.bashWriteGate: true`), Zensu answers a takeover by this
plugin with one notice: the gate refuses a Bash write to a source file and
every working-tree git command whose target lies outside the session's Session
Control root. `/zensu:adopt-session --reanchor`, run from inside the worktree
the takeover works in, moves that root there; it accepts only a registered
worktree of the same repository, reports first and moves only on `--confirm`.

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

1. Actions → **Release Session Hub** → run with `mode: prepare` and a
   `version_type`. The job requires the current version to be tagged already.
   It bumps `plugins/session-hub/.claude-plugin/plugin.json` and the
   `session-hub` marketplace entry, its `version` and its `ref`, through
   `.github/scripts/bump-marketplace-entry.js`, and writes the new section of
   this changelog with git-cliff from the commits that touched
   `plugins/session-hub/` since the last companion tag. It then runs the release
   gate, `.github/scripts/session-hub-release-gate.sh`, against the release
   commit and pushes `release/session-hub-vX.Y.Z` with a link to open the pull
   request. The gate runs `claude plugin validate` on the marketplace and on
   this plugin with the pinned Claude Code, then the companion's suites.
2. Review and squash-merge that pull request.
3. The merged commit starts the `publish` job. It runs the gate again on that
   exact commit, creates the tag with
   `claude plugin tag plugins/session-hub --push`, which refuses unless
   `plugin.json` and the marketplace entry agree, and publishes an immutable
   GitHub Release whose notes are the new changelog section. It does not mark
   the release as the repository's latest, which stays the Zensu plugin's.

The first release, 1.0.0, needs no bump: run the workflow with `mode: publish`
on `main`. A publication that failed is retried the same way. Tags are created
only by this workflow.

## License

[FSL-1.1-Apache-2.0](../../LICENSE), as the rest of this repository.
