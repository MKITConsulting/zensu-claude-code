# Design: `/zensu:setup` — interactive configuration skill

**Date:** 2026-07-07
**Status:** Proposed
**Origin:** brainstorming session

## Summary

A new user-invocable skill `/zensu:setup` that onboards a user by (1) checking the
`zensu` CLI is installed and authenticated, and (2) walking the user through a
small, curated set of the most impactful Zensu plugin settings using the native
AskUserQuestion prompt UI, then writing the answers to the chosen `config.json`
(global or project-local) via a jq-free deep-merge that preserves every other key.

## What it does

- Verifies the `zensu` CLI is on `PATH` and `node` is available.
- Checks auth status (`zensu auth status`) and offers `zensu auth login` when not
  authenticated.
- Asks where to write config: global `~/.zensu/config.json` or project-local
  `<project>/.zensu/config.json`.
- Reads the current effective value of each setting so each question shows the
  current / default value.
- Presents 6 curated settings as multiple-choice questions.
- Deep-merges only the changed keys into the target file, preserving every other
  (including unknown) key.
- Prints a summary of what changed and where.

## Who it is for

- New Zensu plugin users who want a guided first-run configuration instead of
  hand-editing JSON.
- Existing users who want to flip a few high-impact settings without remembering
  key names.

## Who it is NOT for

- Users who want to configure every one of the ~19 keys — this skill is
  deliberately curated. Hand-editing the JSON remains available.
- Programmatic / headless configuration — this is an interactive skill.

## Success criteria

- Running `/zensu:setup` on a machine with no `~/.zensu/config.json` produces a
  valid config file containing only the keys the user set.
- Running it again against an existing config preserves all pre-existing keys and
  changes only what the user touches.
- Unauthenticated users are offered login; CLI-absent users still reach the config
  step (auth skipped gracefully).
- No repo convention is violated (English-only artifact, no manual version bump,
  skill registered in `plugin.json`, structure tests green).

## Out of scope / Non-goals

- No new hook, no new config key, no CLI change.
- No version bump (the release pipeline owns versioning).
- No configuration of the ~11 non-curated keys (`autoTdd`, `autoFix`,
  `autoFixIncludeSuggestions`, `combinedSummary`, `selfReview`, `intentRouter`,
  `tddReminder`, `mcpGate`, `bashWriteGate`, `pendingReviewTtlHours`,
  `context.windowSize`). They are left untouched at their current / default values.
- No `sessionBanner` toggle (excluded per user decision).
- No editing of `$ZENSU_CONFIG` full-override files.

## Curated settings (6 topics / 7 keys)

| # | Setting | Key | Type | Default |
|---|---------|-----|------|---------|
| 1 | TDD mode (vanilla ↔ strict RED→GREEN) | `hooks.tddImplementation` | bool | `false` (vanilla) |
| 2 | Review-chain enforcer | `hooks.chainEnforcer` | bool | `true` |
| 3 | Auto-fix round budget | `hooks.autoFixMaxRounds` | int 1–99 | `5` |
| 4 | Compaction nudge + threshold | `context.compactionNudge` + `context.nudgeThreshold` | bool + int 1–99 | `true` / `50` |
| 5 | SessionStart HEAD/branch context | `hooks.pulseSession` | bool | `true` |
| 6 | Log timestamp style | `logging.timestampStyle` | enum `wall`\|`relative`\|`none` | `wall` |

`hooks.pulseSession` controls only the local context banner. Server-side Pulse
tracking remains governed exclusively by the user's privacy setting.

## Approach

**Chosen — prompt-orchestration skill.** A pure `SKILL.md` (markdown, no new shell
script, no hook). It drives the flow with the native AskUserQuestion tool, computes
the merged config with a `node` one-liner (matching the existing jq-free convention
in `hooks/lib/zensu-config.sh`), and writes the file with the native Write tool.

**Rejected — interactive shell script with `read`.** Skills execute in the agent,
not an interactive TTY; `read` from stdin does not work. AskUserQuestion is the
only native question mechanism.

**Rejected — free-form JSON editor.** Contradicts the "ask the user questions"
requirement; offers no current-value display and no merge safety.

## Flow

- **P0 Preflight.** `command -v zensu`, `command -v node`. CLI missing → print
  install hint (`curl -fsSL https://zensu.dev/install.sh | sh`), continue in
  config-only mode (auth skipped). node missing → fall back to printing the
  ready-to-paste merged JSON instead of writing.
- **P1 Auth.** `zensu auth status`. If unauthenticated → ask whether to log in →
  `zensu auth login` (interactive OAuth, credential-blind). Skip cleanly if the CLI
  is absent.
- **P2 Target.** AskUserQuestion: global vs project-local. Resolve to
  `~/.zensu/config.json` or `<CLAUDE_PROJECT_DIR|pwd>/.zensu/config.json`.
- **P3 Read current.** node reads the target file (missing / malformed → `{}`), so
  each question can label the current value.
- **P4 Ask.** Two AskUserQuestion batches (≤4 each) over the 6 topics; the current /
  default value is marked. Integer settings (`autoFixMaxRounds`, `nudgeThreshold`)
  use presets plus the tool's free-text "Other". The `nudgeThreshold` question is
  only asked when `compactionNudge` is enabled.
- **P5 Write.** node deep-merges ONLY the changed keys into the target object,
  preserving all other keys; creates the parent dir + file if absent; pretty-prints
  with 2-space indent. The final file is written with the Write tool to avoid any
  Bash write-gate interaction. Integer inputs are range-validated
  (`autoFixMaxRounds` 1–99, `nudgeThreshold` 1–99); invalid input is re-asked.
- **P6 Summary.** Echo the target path and each changed key (old → new). Note that
  session-scoped hooks take effect from the next session.

## Config semantics

- Precedence (unchanged, defined in `hooks/lib/zensu-config.sh`): global → project
  overlay (deep-merge per key) → `$ZENSU_CONFIG` full override.
- The skill writes exactly one file (the chosen target). It never merges across
  files itself; it relies on the existing hook-side precedence.
- Merge preserves unknown / other keys; the skill only ever sets the keys the user
  answered.

## Error handling

- CLI absent → config-only path, explicit message.
- node absent → print merged JSON for manual paste; do not write.
- Malformed existing target → node read degrades to `{}`; warn the user and offer a
  backup (`config.json.bak`) before overwrite.
- Invalid integer → re-ask.
- Symlinked target file → refuse and report (mirror the symlink-guard caution used
  by `reset-review-limit`).

## Repo-convention compliance

- **English-only** artifact.
- **No manual version bump** — the pipeline owns `plugin.json` / `marketplace.json`
  / README badge / CHANGELOG.
- **Registration:** add `"./skills/setup"` to `plugin.json` `skills[]`.
  `marketplace.json` carries only the version, not a skill list — no change there.
- **Frontmatter:** `SKILL.md` gets YAML frontmatter (`name: setup`,
  `description: >` with trigger phrases) so it is user-invocable, matching the
  autopilot / cover / pr-* skills.

## Risks to verify during implementation

- **R1 — workflow markers / auth classification.**
  `tests/structure/test-skill-workflow-markers.sh` fails if a skill runs a `zensu`
  MUTATION command without `--workflow-begin` / `--workflow-end`. Verify
  `zensu auth login|status|logout|token` are NOT classified as mutations in
  `hooks/lib/zensu-cli-map.sh` + `hooks/lib/zensu-mcp-tools.sh`. Expected: auth is
  neutral / read → no markers needed. If it is classified as a mutation, confirm the
  correct handling before shipping.
- **R2 — write path.** Confirm writing the config file with the Write tool does not
  trip `pre-bash-source-write-gate.sh` (it inspects Bash, not the Write tool).
- **R3 — marketplace.json.** Confirm it needs no skill-list change (version-only
  advertisement).
- **R4 — structure parity tests.** Confirm any skill-directory ↔ `plugin.json`
  parity test passes after registration.

## Verification plan

- Run `tests/run-all.sh` (or the structure subset) after adding + registering the
  skill.
- Manual dry-run of the skill against a scratch `HOME` / `ZENSU_CONFIG` to confirm
  create + idempotent re-run + key preservation.
