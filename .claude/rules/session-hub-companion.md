---
paths:
  - "plugins/session-hub/**"
  - "skills/session-trail/**"
  - ".claude-plugin/marketplace.json"
  - ".github/workflows/release-session-hub.yml"
  - ".github/scripts/session-hub-release-gate.sh"
  - ".github/scripts/bump-marketplace-entry.js"
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
that leaves the tree, and H1 holds the tree to an allowlist.

**Byte-identical copies, not a build step.** Seven files are copies of PLM files, and H4 fails
on any byte that differs: `hooks/lib/claude-path-v1.js`, `desktop-store-read-v1.js`,
`git-environment-v1.js`, `worktree-keep-v1.js`, `hooks/usage-feed.ts`,
`hooks/usage-feed-contract.json` and `skills/session-trail/scripts/session-lineage-v1.mjs`. A
change to one of those PLM files copies the file into the companion in the same commit.
`trail.mjs`, `linked-sessions-v1.mjs`, `SKILL.md`, the references, `handover-contract.json`
and the receipt module are the companion's own. The copy dropped the write-anchor feature, the
GATE probe and the Session Control core (H6), computes the keep key itself with core's
domain-separated hash (H7 compares it with `sessionKey`), and names
`/session-hub:session-trail` in every file it runs or loads (H6).

**PLM's copy is frozen, and the maintained copy is the companion's.** PLM keeps
`skills/session-trail/`, `hooks/user-prompt-session-hub-receipt.sh`,
`hooks/lib/session-hub-receipt-v1.mjs` and `hooks/usage-feed.ts` until the release that
removes them. They take fixes only, and a fix lands in both copies. PLM's
`handover-contract.json` stays contract 1 byte for byte; the companion's is contract 2 with the
prefix `/session-hub:session-trail takeover ` (R12 in `test-session-hub-receipt.sh`). The
suites grade the companion: `test-session-trail-{skill,lineage,verdict}.sh`, the unit files
they drive and `test-session-hub-{plugin,receipt,usage-feed}.sh`. PLM's copy is graded only for
what the companion removed: the write-anchor checks (`W*`, `WC*`), the PLM census in
`worktree-advice-v1.test.js` and the rows that rebind `TRAIL_MJS="$PLM_TRAIL_MJS"`. A shared
behavior that regresses in PLM's copy alone is therefore not caught. The rules for the skill
(`session-trail-*`, `takeover-destination`, `session-lineage-ledger`) name
`skills/session-trail/…`; read each as naming both copies.

**The takeover notice is PLM's.** The companion has no write gate.
`hooks/user-prompt-session-hub-takeover-notice.sh` answers the companion's raw or command-tag
takeover prompt with one `additionalContext` notice: on the main thread only, only while
`hooks.bashWriteGate` is on and neither `ZENSU_BASH_WRITE_GATE=off` nor `ZENSU_MCP_GATE=off`
is set, naming the bound Session Control root when the bind succeeds.
`test-session-hub-takeover-notice.sh` and its row in `test-user-prompt-budget.sh`, zero
characters on every other prompt, pin it.

**Changelogs and tags split by path.** Root `cliff.toml` keeps its `vX.Y.Z` `tag_pattern` and
adds `exclude_paths = ["plugins/session-hub/**"]`. `plugins/session-hub/cliff.toml` uses
`session-hub--vX.Y.Z` tags and `include_paths = ["plugins/session-hub/**"]` with the same body
and parsers (H9). A commit that touches both trees lands in both changelogs. Measured with
git-cliff 2.13.1 on a scratch history in both directions; the workflows install the action's
latest git-cliff.

**Release path: `.github/workflows/release-session-hub.yml`.**

- `prepare`, dispatched on `main`, refuses unless the current companion version is tagged. It
  bumps `plugins/session-hub/.claude-plugin/plugin.json` with `sed` and the `session-hub` entry
  with `bump-marketplace-entry.js`, prepends the git-cliff section under `## [Unreleased]` of
  `plugins/session-hub/CHANGELOG.md`, commits `chore(release): bump session-hub to X.Y.Z` on
  `release/session-hub-vX.Y.Z`, runs `.github/scripts/session-hub-release-gate.sh` against
  that commit and pushes the branch. The PR pipeline skips its suite jobs on `release/` heads,
  so this gate is the release commit's test run; the `plugin-validate` job still runs there.
- `publish` runs on a push to `main` whose head commit starts with that subject, or on a
  `publish` dispatch, which is also how the first release, 1.0.0, ships. It requires Immutable
  Releases, checks the entry and a `## [X.Y.Z] - YYYY-MM-DD` section, reruns the gate on the
  exact SHA, creates the tag only through `claude plugin tag plugins/session-hub --push`, which
  refuses unless `plugin.json` and the entry agree, and publishes the release with
  `--verify-tag --latest=false`, so PLM's release stays the repository's latest. H10 pins that
  no other step creates or pushes a tag and that the subject never starts PLM's
  `chore(release): bump version to`.
- The gate runs `claude plugin validate` on `.` and on `plugins/session-hub` with the pinned
  Claude Code in its own config directory, then the companion suites with `CLAUDE_CONFIG_DIR`
  unset. H11 holds the gate's pin, both workflow installs and the `plugin-validate` check in
  `ci.yml` to one exact version. Measured in a `node:22-bookworm` container with no
  credentials and no `~/.claude`: `npm install -g @anthropic-ai/claude-code@2.1.317`, both
  validations and `claude plugin tag --dry-run` ran without a login. That package requires
  Node 22, which is why these jobs set it up while the suites elsewhere run on Node 20.

**Order of releases.** While both plugins ship the usage feed, both copies write
`<session id>.json` under one rule, so PLM releases no later than the companion: an installed
PLM older than the companion writes by the older rule.

**Version: `patch` for PLM.** An added advisory hook, an added catalog entry, CI and docs: no
schema, strict key set, matcher, config key or attestation moves.
