---
name: setup
description: >
  Interactive first-run configuration for the Zensu plugin. Verifies the zensu
  CLI is installed and authenticated (offers `zensu auth login` when it is not),
  asks whether to write global or project-local config, then walks the user
  through a curated set of high-impact plugin settings via AskUserQuestion and
  writes the answers to the chosen config.json with a jq-free deep-merge that
  preserves every other key. Use whenever the user wants to configure or set up
  the Zensu plugin, change their Zensu settings, onboard a new machine,
  "configure zensu", "set up zensu", "change my zensu config", or the slash
  command /zensu:setup.
---

# /zensu:setup

Guided configuration for the Zensu plugin. It checks the CLI + auth, then asks a
short set of questions and writes your answers to a `config.json` — either global
(`$HOME/.zensu/config.json`, applies everywhere) or project-local
(`<project>/.zensu/config.json`, this repo only, overriding the global per key).
Every write is a **deep-merge**: only the keys you answer are changed; everything
else already in the file is preserved untouched.

> Onboarding in one command. Nothing you did not choose is overwritten.

## Arguments

Slash form: `/zensu:setup [--global | --project]`.

| Arg | Required | Default | Notes |
|---|---|---|---|
| `--global` | no | — | Skip the target question; write to `$HOME/.zensu/config.json`. |
| `--project` | no | — | Skip the target question; write to `<project>/.zensu/config.json`. |

With no flag, the skill asks where to write in Phase 2.

## Prerequisites

- `node` on `PATH` — used for the jq-free config read + deep-merge (the plugin
  already depends on it). If absent, the skill prints the final merged JSON for you
  to paste manually instead of writing.
- Optional: the `zensu` CLI and a Zensu account for the auth step. Without the CLI,
  setup still configures local settings and skips authentication.

## What it configures (curated)

Only these high-impact keys are offered. Every other key in the file is left exactly
as it is.

| Setting | Key | Type | Default |
|---|---|---|---|
| TDD mode — vanilla vs. strict RED→GREEN | `hooks.tddImplementation` | bool | `false` (vanilla) |
| Review-chain enforcer | `hooks.chainEnforcer` | bool | `true` |
| Auto-fix round budget | `hooks.autoFixMaxRounds` | int 1–99 | `5` |
| Context compaction nudge | `context.compactionNudge` | bool | `true` |
| Compaction nudge threshold (%) | `context.nudgeThreshold` | int 1–99 | `50` |
| Pulse telemetry session | `hooks.pulseSession` | bool | `true` |
| Log timestamp style | `logging.timestampStyle` | enum `wall` \| `relative` \| `none` | `wall` |

## Phase 0 — Preflight

1. `command -v node` — if missing, do **not** write. Still gather choices in Phases
   2–4, then print the merged JSON (Phase 5 snippet) and tell the user which file to
   paste it into. Stop after that.
2. `command -v zensu` — if missing, note it and skip Phase 1; continue with config
   only.

## Phase 1 — Auth (only when the CLI is present)

Run `zensu auth status`. If it exits non-zero or reports that no host is logged in,
ask via `AskUserQuestion` whether to log in now:

- **Yes** → run `zensu auth login` (interactive browser OAuth; it auto-approves when
  a Zensu web session is already active). The login flow never exposes any credential
  to the agent.
- **No** → continue. None of the curated settings require authentication.

If already authenticated, say so and continue.

## Phase 2 — Choose the target file

If `--global` / `--project` was passed, use it. Otherwise ask via `AskUserQuestion`:

- **Global** → `TARGET="$HOME/.zensu/config.json"` (applies to every project).
- **Project-local** → `TARGET="${CLAUDE_PROJECT_DIR:-$(pwd)}/.zensu/config.json"`
  (this repo only; overrides the global value per key).

## Phase 3 — Read current values

Load the target so each question can show the current value (a missing or malformed
file is treated as `{}`):

```sh
node -e 'let o={};try{o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))}catch(e){}process.stdout.write(JSON.stringify(o,null,2))' "$TARGET"
```

For each curated key, the current value is the file value if present, else the
documented default from the table above. If the target file already exists, also open
it with the Read tool now — the Write in Phase 5 overwrites it, and Write requires a
prior read of an existing file.

## Phase 4 — Ask the questions (`AskUserQuestion`)

Ask the curated settings, marking the current value in each option. Group them into at
most two `AskUserQuestion` calls (≤4 questions each):

- **Booleans** (`tddImplementation`, `chainEnforcer`, `pulseSession`,
  `compactionNudge`) → two options (on / off), current state labelled.
- **`autoFixMaxRounds`** → presets `3` / `5` / `8` plus the free-text "Other" (accept
  any integer 1–99).
- **`nudgeThreshold`** → presets `40` / `50` / `70` plus "Other" (1–99). Ask this
  **only** when `compactionNudge` ends up enabled.
- **`timestampStyle`** → `wall` / `relative` / `none`.

Collect only the keys the user actually chooses to change into a patch object, e.g.
`{"hooks":{"tddImplementation":true,"autoFixMaxRounds":8},"context":{"compactionNudge":true,"nudgeThreshold":70},"logging":{"timestampStyle":"relative"}}`.
Validate integers before continuing: `autoFixMaxRounds` and `nudgeThreshold` must be
integers in `[1,99]`; re-ask on anything out of range.

## Phase 5 — Write (deep-merge, preserving every other key)

Compute the merged config with node — this only **reads** the target and prints the
result, so the shell writes no file:

```sh
node -e '
const fs=require("fs");
const p=process.argv[1], patch=JSON.parse(process.argv[2]);
function dm(b,o){if(o===null||typeof o!=="object"||Array.isArray(o))return o;const r=(b&&typeof b==="object"&&!Array.isArray(b))?Object.assign({},b):{};for(const k of Object.keys(o)){if(k==="__proto__"||k==="constructor"||k==="prototype")continue;r[k]=Object.prototype.hasOwnProperty.call(r,k)?dm(r[k],o[k]):o[k]}return r}
let cur={};try{cur=JSON.parse(fs.readFileSync(p,"utf8"))}catch(e){}
process.stdout.write(JSON.stringify(dm(cur,patch),null,2)+"\n");
' "$TARGET" "$PATCH_JSON"
```

`dm` mirrors the deep-merge the hooks already use in `hooks/lib/zensu-config.sh` (same
per-key recursion + prototype-pollution guard). Persist the printed JSON with the
**Write** tool (not a shell redirect — that keeps the write off the Bash write-gate).
Ensure the parent directory exists first: `mkdir -p "$(dirname "$TARGET")"`.

If `node` was missing (Phase 0), show the user this merged JSON plus the target path
and ask them to paste it in by hand.

## Phase 6 — Summary

Report:

- The exact `TARGET` path written.
- Each changed key as `key: old → new` (skip unchanged keys).
- A note that session-scoped hooks (e.g. the banner, pulse) take effect from the
  **next** Claude Code session.

## CLI commands used

| Command | Phase | Purpose |
|---|---|---|
| `zensu auth status` | 1 | Check whether a Zensu host is logged in |
| `zensu auth login` | 1 | Interactive login (only when the user opts in) |
