# Changelog

All notable changes to the Zensu Session Hub companion plugin, `session-hub@zensu`, are
documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this plugin adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-11-10

### Added

- **session-hub**: the companion plugin for the Zensu Session Hub, installed as
  `session-hub@zensu` from the `zensu` marketplace. It carries `/session-hub:session-trail`
  with list, show, takeover, handoff, adopt, release and the lineage ledger; the handover
  receipt for the Session Hub's takeover command, written by one Node hook that reads only
  `hooks.sessionHubReceipt` in `~/.zensu/config.json`; and the `usage-feed.ts` hooks module.
  Its handover contract 2 names the prefix `/session-hub:session-trail takeover `. The
  receipt, lineage and usage directories and their schema versions are the ones the Zensu
  plugin writes.
