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
  dir writable, canonical CAS workflow documents valid, each review chain's
  shape plus any wedged chain and its recovery command, expired pending-review
  surfaced). The only write is an explicit, user-confirmed cleanup of one
  expired pending-review.json — CAS workflow documents are never deleted. Use
  when the user asks to "diagnose zensu", "check my zensu
  setup", "why is a zensu hook/gate not firing", "zensu doctor", or the slash
  command /zensu:doctor.
---

# /zensu:doctor

Read-only health check for the Zensu plugin install. It answers the questions
that otherwise get debugged by hand: is the CLI authenticated, are the hooks
actually wired, is the config being read the way you think it is (the
quoted-boolean trap bites silently), and are the revisioned workflow documents
valid. It prints one four-block ✅/⚠️/❌ table and changes nothing — the single
exception is removal of an expired `pending-review.json` you explicitly confirm.

> One command to see why something is not firing. Nothing is changed unless you say so.

## When to Use

- The user asks to "diagnose zensu", "check my zensu setup", "run zensu doctor",
  or invokes `/zensu:doctor`.
- A hook or gate is not firing and you need to see whether it is wired,
  configured, or authenticated.
- After onboarding a new machine or switching worktrees (native project-root
  surprises, invalid CAS workflow state).
- Before a release, to confirm `plugin.json` and `marketplace.json` versions agree.

## Do NOT Use For

- Changing configuration — that is `/zensu:setup` (guided writes).
- Resetting the auto-fix round counter — that is `/zensu:reset-review-limit`.
- Any repair beyond the confirmed expired-pending-review cleanup below. Doctor diagnoses;
  it does not fix wiring, versions, or auth.

## Prerequisites

None. No MCP connection, no API key, no network. The tool probes are local
(`command -v`, `--version`, auth-status exit codes), the lockfile-backed Playwright MCP
probe validates `.mcp.json`, its manifest wiring, its integrity lock, and `npm`
without installing or executing the package, and the remaining manifest/config/state reads are local
files. A configured MCP row remains a warning until the loaded MCP tools are confirmed.

## Phase 1: Run the diagnostics

Use Claude's natively rendered `${CLAUDE_PLUGIN_ROOT}` directly.
Before invoking the helper, inspect the tools
already available in this Claude Code session — do not call the browser. Runtime readiness
requires the core operation suffixes used by `/zensu:verify-feature`: `browser_navigate`,
`browser_snapshot`, `browser_take_screenshot`, `browser_click`, `browser_type` or
`browser_fill_form`, `browser_wait_for`, `browser_console_messages`,
`browser_network_requests`, and `browser_close`. Accept each
suffix under either `mcp__playwright__*` or `mcp__plugin_zensu_playwright__*`.

Run the following as one Bash call. Replace `READY=0` with `READY=1` only when
that complete tool set is loaded. The explicit preflight intentionally does not
use `${VAR:?…}`: a missing or invalid root must still print the same standardized
doctor table fragment instead of terminating in an unformatted shell error.
Never paste the root value into shell source.

```bash
READY=0
ROOT="${CLAUDE_PLUGIN_ROOT}"
case "$ROOT" in /*) ;; *) ROOT="" ;; esac
if [ -z "$ROOT" ] || [ -L "$ROOT" ] || [ ! -d "$ROOT" ] \
  || [ -L "$ROOT/hooks/lib/zensu-doctor.sh" ] || [ ! -f "$ROOT/hooks/lib/zensu-doctor.sh" ]; then
  printf '%s\n' \
    'Zensu doctor — read-only setup diagnostics' '' 'Plugin integrity' \
    '  ❌  Session Control: plugin root unavailable or invalid — start a fresh Claude Code session' \
    '' 'Summary: 1 ❌  0 ⚠️  — resolve the ❌ items first.'
elif [ "$READY" = 1 ]; then
  CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR}" ZDOC_PLAYWRIGHT_TOOLS=ready bash "$ROOT/hooks/lib/zensu-doctor.sh"
else
  CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR}" bash "$ROOT/hooks/lib/zensu-doctor.sh"
fi
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
- **⚠️ chain: wedged chain(s)** → a review chain reached a shape no supported
  command can advance. Report it and name `/zensu:recover-chain`, which must be
  run **from the session that owns that chain** (the row prints its truncated
  session key) — this skill never recovers one on its behalf. When the row reads
  "wedged but not recoverable in place", repeat the blocker it names verbatim
  instead: an incomplete Autopilot linkage, an outstanding deferred-review claim,
  an inconsistent review-ticket slot, or a latched `selfReviewFixed` each has its
  own next step. A separate "at a dead end" row means no repair applies at all and
  a fresh `/zensu:tdd` generation is the only exit. A chain that was repaired
  earlier renders `repaired N×`.

If everything is green, say so in one line and stop — there is nothing to do.

## Phase 3: Expired pending-review cleanup (the ONLY write, always user-gated)

Canonical `tdd-phase-<scv1-session-key>.json` files are revisioned CAS workflow
documents, not leftover markers. Never delete, rename, rewrite, or enumerate
them for cleanup. Their ticket-bound `reviewRound` and `stopBlockCount` fields
are re-armed only by `/zensu:reset-review-limit` through the trusted
`zensu-log.sh --review-rearm` composite transaction.

Only when the **Session state** block explicitly reports
`pending-review.json ... expired`, you MAY offer to remove that one exact file:

1. Derive the current worktree's exact state directory without scanning:
   `${CLAUDE_PROJECT_DIR}/.zensu/state`; Claude concretizes the native project
   placeholder when this skill is loaded.
   Reject a missing directory or any symlink.
2. Set `PENDING="$STATE_DIR/pending-review.json"`. Require a regular,
   non-symlink file. Show this exact path; do not list the directory.
3. Confirm via `AskUserQuestion`: "Remove expired pending-review.json" or
   "Keep it".
4. On explicit confirmation only, run `rm -f -- "$PENDING"`. Never use a glob,
   `find`, parent traversal, or worktree discovery.
5. Non-interactive runs remain report-only.

An invalid CAS workflow document is a fail-closed diagnostic, never a cleanup
candidate. Recommend a fresh session and code-level investigation instead of
mutating it.

## Response Style

Terse and concrete. Lead with the table (verbatim), then at most two lines of
interpretation, then the cleanup offer only for an expired pending-review file.
Reference config keys and file paths exactly as the table printed them.
