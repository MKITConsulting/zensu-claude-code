---
name: doctor
description: >
  [Zensu] Read-only setup diagnostics for the Zensu plugin. Runs
  hooks/lib/zensu-doctor.sh and prints a four-block ✅/⚠️/❌ table: CLI &
  tooling (zensu CLI + auth, node, the code-forge CLI gh/glab + auth resolved
  from the repo's provider, lockfile-backed Playwright MCP config/readiness), plugin integrity
  (hooks.json wired to files on disk, plugin.json ↔ marketplace.json version
  sync), config (valid JSON, the quoted-boolean trap where "true"/"false" as a
  string is silently ignored by strict === checks), and session state (state
  dir writable, stale/expired markers). The only write is an explicit,
  user-confirmed cleanup of leftover state markers — everything else is
  read-only. Use when the user asks to "diagnose zensu", "check my zensu
  setup", "why is a zensu hook/gate not firing", "zensu doctor", or the slash
  command /zensu:doctor.
---

# /zensu:doctor

Read-only health check for the Zensu plugin install. It answers the questions
that otherwise get debugged by hand: is the CLI authenticated, are the hooks
actually wired, is the config being read the way you think it is (the
quoted-boolean trap bites silently), and are there leftover state markers from a
crashed session. It prints one four-block ✅/⚠️/❌ table and changes nothing —
the single exception is a leftover-marker cleanup you explicitly confirm.

> One command to see why something is not firing. Nothing is changed unless you say so.

## When to Use

- The user asks to "diagnose zensu", "check my zensu setup", "run zensu doctor",
  or invokes `/zensu:doctor`.
- A hook or gate is not firing and you need to see whether it is wired,
  configured, or authenticated.
- After onboarding a new machine or switching worktrees (`CLAUDE_PROJECT_DIR`
  surprises, stale markers).
- Before a release, to confirm `plugin.json` and `marketplace.json` versions agree.

## Do NOT Use For

- Changing configuration — that is `/zensu:setup` (guided writes).
- Resetting the auto-fix round counter — that is `/zensu:reset-review-limit`.
- Any repair beyond the confirmed leftover-marker cleanup below. Doctor diagnoses;
  it does not fix wiring, versions, or auth.

## Prerequisites

None. No MCP connection, no API key, no network. The tool probes are local
(`command -v`, `--version`, auth-status exit codes), the lockfile-backed Playwright MCP
probe validates `.mcp.json`, its manifest wiring, its integrity lock, and `npm`
without installing or executing the package, and the remaining manifest/config/state reads are local
files. A configured MCP row remains a warning until the loaded MCP tools are confirmed.

## Phase 1: Run the diagnostics

Resolve `{PLUGIN_ROOT}` = the trimmed contents of `~/.zensu/plugin-root` (the
same value `/zensu:tdd` Phase 0 resolves). Before invoking the helper, inspect the tools
already available in this Claude Code session — do not call the browser. Runtime readiness
requires the core operation suffixes used by `/zensu:verify-feature`: `browser_navigate`,
`browser_snapshot`, `browser_take_screenshot`, `browser_click`, `browser_type` or
`browser_fill_form`, `browser_wait_for`, `browser_console_messages`,
`browser_network_requests`, and `browser_close`. Accept each
suffix under either `mcp__playwright__*` or `mcp__plugin_zensu_playwright__*`. If the complete
set is loaded, pass that signal separately; the helper still
validates this plugin's pinned MCP declaration before it can emit `ready`:

```
ZDOC_PLAYWRIGHT_TOOLS=ready bash {PLUGIN_ROOT}/hooks/lib/zensu-doctor.sh
```

Otherwise run, once:

```
bash {PLUGIN_ROOT}/hooks/lib/zensu-doctor.sh
```

The plain helper validates the integrity-locked plugin declaration and `npm` presence offline but
cannot prove that Claude loaded the MCP server, so it deliberately reports `configured` as
a warning. The tools signal alone cannot bypass declaration validation. Never inject
`ZDOC_PLAYWRIGHT=ready` directly and never infer readiness from a PATH `playwright` binary.

Print its output verbatim to the user — it is already the formatted four-block
table with a summary line. The helper always exits 0; a red ❌ is a finding in
the report, not a failed command. Do not re-render or paraphrase the table.

## Phase 2: Interpret

Briefly call out, in one or two lines, the highest-severity findings and the
concrete next step for each — but only for rows the table actually marked ⚠️/❌:

- **❌ version sync** → bump `plugin.json` and `marketplace.json` together (the
  release train owns this; see `CLAUDE.md`).
- **❌ hooks wiring: referenced but missing** → a `hooks.json` command points at a
  script that is not on disk; the hook silently never runs.
- **⚠️ config quoted boolean** → the named key is a string (`"true"`) where a real
  boolean is required; strict `=== true` ignores it, so the feature stays at its
  default. Drop the quotes (offer `/zensu:setup` to rewrite it safely).
- **⚠️ forge CLI not authenticated / not found** → authenticate or install the CLI
  the report names for the detected provider: `gh auth login` for GitHub,
  `glab auth login` for GitLab (`unknown` means no github/gitlab remote was
  detected — add one, or export `ZENSU_VCS_PROVIDER=github|gitlab` for a
  self-hosted host).
- **⚠️ zensu not authenticated** → `zensu auth login`.

If everything is green, say so in one line and stop — there is nothing to do.

## Phase 3: Leftover-marker cleanup (the ONLY write, always user-gated)

If the **Session state** block reported leftover per-session markers or an expired
`pending-review.json`, you MAY offer to remove them — under strict rules:

1. **Scope**: operate ONLY on the current worktree's state dir
   (`${TDD_STATE_DIR:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}`). NEVER run
   `git worktree list`, NEVER touch sibling `.claude/worktrees/*/.zensu/state`,
   NEVER traverse parents. If the user wants other worktrees cleaned, they invoke
   `/zensu:doctor` there.
2. **Never delete the current session's own markers.** Resolve this session's id
   (`~/.zensu` session helpers, or the `CLAUDE_SESSION_ID` the hooks use) and
   EXCLUDE `tdd-phase-<sid>.json`, `rounds-<sid>.json`, `review-pass-<sid>`, and
   `<sid>.stopblocks` for the live session. Deleting them would break the chain
   you are running in.
3. **List before you delete.** Show the exact files that would be removed and how
   many. A marker may belong to another session that is still running — when in
   doubt, prefer the expired `pending-review.json` and markers whose
   `tdd-phase-*.json` carries `chainDone: true`.
4. **Confirm via `AskUserQuestion`.** Offer "Remove N leftover marker(s)" vs
   "Keep everything". Delete ONLY on explicit confirmation, with `rm -f` on the
   listed paths (symlink-safe: skip any path that is a symlink).
5. **Non-interactive runs are report-only.** If you cannot ask (Auto Mode / no
   interactive channel), do NOT delete — state what would be cleaned and stop.

Never delete anything outside this list, and never as a side effect of Phase 1/2.

## Response Style

Terse and concrete. Lead with the table (verbatim), then at most two lines of
interpretation, then the cleanup offer only if there is something to clean.
Reference config keys and file paths exactly as the table printed them.
