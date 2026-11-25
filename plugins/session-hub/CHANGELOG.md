# Changelog

All notable changes to the Zensu Session Hub companion plugin, `session-hub@zensu`, are
documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this plugin adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.2] - 2026-11-25

### Fixed

- **session-trail**: Release the old session before its remaining work (#671)
- **session-trail**: Find Claude Desktop records in data folders of their own (#645)
- **hooks**: Let a linked session inherit build from desktop stores of their own (#648)
- **autopilot**: Carry a durable run through a session-trail takeover (#651)

## [1.0.1] - 2026-11-15

### Fixed

- **session-trail**: Close the linked-session gaps PR #589 deferred (#620)

## [1.0.0] - 2026-11-10

### Added

- **session-hub**: the companion plugin for the Zensu Session Hub, installed as
  `session-hub@zensu` from the `zensu` marketplace. It carries `/session-hub:session-trail`
  with list, show, takeover, handoff, adopt, release and the lineage ledger; the handover
  receipt for the Session Hub's takeover command, written by one Node hook that reads only
  `hooks.sessionHubReceipt` in `~/.zensu/config.json`; and the `usage-feed.ts` hooks module.
  Its handover contract 2 names the prefix `/session-hub:session-trail takeover `. The
  receipt, lineage and usage directories and their schema versions are the ones the Zensu
  plugin writes. It needs Claude Code 2.1.296 or newer and `node` on the `PATH`, and its
  takeover briefs state the commit rule of the Zensu plugin's opt-in source-write gate for a
  session where both plugins run. Moving a session through it needs a Zensu Session Hub
  release that reads handover contract 2; until then the Session Hub moves sessions through
  the Zensu plugin's `/zensu:session-trail`.
