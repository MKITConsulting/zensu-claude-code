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

**PLM's copy is frozen, and the maintained copy is the companion's.** PLM keeps
`skills/session-trail/`, `hooks/user-prompt-session-hub-receipt.sh`,
`hooks/lib/session-hub-receipt-v1.mjs` and `hooks/usage-feed.ts` until the release that
removes them. They take fixes only, and a fix lands in both copies. PLM's
`handover-contract.json` stays contract 1 byte for byte; the companion's is contract 2 with the
prefix `/session-hub:session-trail takeover ` (R12 in `test-session-hub-receipt.sh`). The
suites grade the companion: `test-session-trail-{skill,lineage,verdict}.sh`, the unit files
they drive and `test-session-hub-{plugin,receipt,usage-feed}.sh`. PLM's copy is graded for what
the companion removed: the write-anchor checks (`W*`, `WC*`), the PLM census in
`worktree-advice-v1.test.js` and the rows that rebind `TRAIL_MJS="$PLM_TRAIL_MJS"`. `PL1` in
`test-session-trail-verdict.sh` runs both copies on the LS family's fixture and requires the
same `show --all --json` and `takeover --all --no-record --json`, apart from the command name and
PLM's `writes` and `continuation` keys. A shared behavior that regresses in PLM's copy alone on
another path is still not caught. The skill's description budget and argument placeholders are
graded by `test-skill-text-budget.sh` and `AP1`, which scan each `plugins/*/` root. The rules for the skill
(`session-trail-*`, `takeover-destination`, `session-lineage-ledger`) name
`skills/session-trail/…`; read each as naming both copies.

**The takeover notice is PLM's.** The companion has no write gate.
`hooks/user-prompt-session-hub-takeover-notice.sh` answers the companion's raw or command-tag
takeover prompt with one `additionalContext` notice: on the main thread only, only while
`hooks.bashWriteGate` is on and neither `ZENSU_BASH_WRITE_GATE=off` nor `ZENSU_MCP_GATE=off`
is set, naming the bound Session Control root in double quotes when the bind succeeds. When the
bind fails it sends the unbound variant instead, which names no reanchor, because
`--reanchor` needs a usable record, and points at `/zensu:doctor`.
`test-session-hub-takeover-notice.sh` and its row in `test-user-prompt-budget.sh`, zero
characters on every other prompt, pin it; N13 holds its command name, the hook's prefilter and
the receipt entry's to the companion contract's `takeover.prefix`. The notice reaches only a
prompt that carries the command: a linked session started from a brief, a takeover started
through the Skill tool and a PLM older than this change get none. So the companion's briefs carry
the rule themselves (`plmGateCaution` in `trail.mjs`, the `Commits, when Zensu PLM is installed`
line), `show` prints it as its `COMMITS` lines (`PLM_GATE_SHOW_LINES`), and
`references/takeover.md` step 3 tells the model to read `hooks.bashWriteGate` rather than the
absence of a notice.

**Changelogs and tags split by path.** Root `cliff.toml` keeps its `vX.Y.Z` `tag_pattern` and
adds `exclude_paths = ["plugins/session-hub/**"]`. `plugins/session-hub/cliff.toml` uses
`session-hub--vX.Y.Z` tags and `include_paths = ["plugins/session-hub/**"]` with the same body
and parsers (H9), its version header included: only the tag prefix that header trims may
differ. A commit that touches both trees lands in both changelogs. Measured with
git-cliff 2.13.1 on a scratch history in both directions. Both release workflows pin that version
in their git-cliff step (`version: v2.13.1`, the default of the pinned action as well), and H14
holds the pin.

**Release path: `.github/workflows/release-session-hub.yml`.**

- `prepare`, dispatched on `main`, refuses unless the current companion version is tagged and
  the release order below holds. It bumps `plugins/session-hub/.claude-plugin/plugin.json` with
  `sed` and the `session-hub` entry with `bump-marketplace-entry.js`, prepends the git-cliff
  section under `## [Unreleased]` of `plugins/session-hub/CHANGELOG.md`, commits
  `chore(release): bump session-hub to X.Y.Z` on `release/session-hub-vX.Y.Z`, runs
  `.github/scripts/session-hub-release-gate.sh` against that commit and pushes the branch.
- `publish` runs on a push to `main` whose head commit starts with that subject, or on a
  `publish` dispatch, which is also how the first release, 1.0.0, ships. Before any tag exists
  it requires Immutable Releases, checks the entry, a non-empty `## [X.Y.Z] - YYYY-MM-DD`
  section and the release order, and reruns the gate on the exact SHA. It then creates the tag
  locally through `claude plugin tag plugins/session-hub`, which refuses unless `plugin.json`
  and the entry agree, in a step that carries no token, checks that it is an annotated tag at
  that SHA, re-checks Immutable Releases, and pushes `refs/tags/session-hub--vX.Y.Z` in a step
  of its own. It publishes the release with `--verify-tag --latest=false`, so PLM's release
  stays the repository's latest, and once the release is immutable it resolves the tag again and
  fails if it no longer names that SHA. Between the push and the release the tag is mutable;
  that window is the price of tagging through `claude plugin tag`, and the last check names a
  tag moved inside it. H10 pins the order of those steps, the one tag command without `--push`
  and without a token, the two allowed pushes (the release branch and the tag), and that the
  subject never starts PLM's `chore(release): bump version to`.
- The gate runs `.github/scripts/session-hub-install-probe.sh` with its pinned Claude Code, then
  the companion suites with `CLAUDE_CONFIG_DIR` unset. The probe validates `.` and
  `plugins/session-hub`, clones the repository bare with `--no-tags`, tags `HEAD` there, adds a
  local marketplace whose `session-hub` entry points at that clone, installs the companion into
  an isolated config, requires the installed files to equal `git ls-tree` of
  `plugins/session-hub` at `HEAD`, and lands a 0600 receipt and runs `list --json` from the
  installed copy. It never touches a tag of the repository itself, so `claude plugin tag` still
  finds no local tag. `ci.yml` runs the whole gate in `plugin-validate` on every pull request,
  `release/` heads included, under Node 22 and without `npm ci`, as the release does, and the
  probe alone in `plugin-floor` with Claude Code 2.1.296, the oldest version the README names.
  H11 holds one exact version across the gate's pin, both release installs and the
  `plugin-validate` install, the floor install to the probe's argument and below that pin, and
  the README to both. Measured on macOS: the probe passed with 2.1.296 and 2.1.317, and against
  a shallow depth-1 clone with a detached `HEAD`. Measured earlier in a `node:22-bookworm`
  container with no credentials and no `~/.claude`: `npm install -g
  @anthropic-ai/claude-code@2.1.317`, both validations and `claude plugin tag --dry-run` ran
  without a login. That package requires Node 22, which is why these jobs set it up while the
  suites elsewhere run on Node 20.

**Order of releases.** While both plugins ship the usage feed, both copies write
`<session id>.json` under one rule, so PLM releases no later than the companion: an installed
PLM older than the companion writes by the older rule. `.github/scripts/session-hub-release-order.sh`
enforces it in both jobs: it takes the newest `vX.Y.Z` tag by version, ignoring pre-release
tags, and refuses unless that tag carries `hooks/usage-feed.ts` and
`hooks/usage-feed-contract.json` byte for byte as the companion's working tree and ships
`hooks/user-prompt-session-hub-takeover-notice.sh`. H14 drives it on a scratch history. So the
first companion release waits for the PLM release that ships this change.

**Version: `patch` for PLM.** An added advisory hook, an added catalog entry, CI and docs: no
schema, strict key set, matcher, config key or attestation moves.
